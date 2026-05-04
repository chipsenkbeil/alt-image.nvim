local M = {}

local SYNC_START = "\027[?2026h"
local SYNC_END = "\027[?2026l"

---@type boolean
local is_drawing = false

---@return boolean
function M.is_drawing()
    return is_drawing
end

---Run `body(term_io)` wrapped in a Mode 2026 frame with `termsync` disabled.
---SYNC_END always runs (even on error) so the terminal can't get stuck mid-frame.
---@param body fun(term_io: { send: fun(data: string) })
local function with_sync_frame(body)
    local term_io = require("alt-img._core.term_io")
    local old_termsync = vim.o.termsync
    vim.o.termsync = false
    local ok, err = pcall(function()
        term_io.send(SYNC_START)
        body(term_io)
    end)
    term_io.send(SYNC_END)
    vim.o.termsync = old_termsync
    if not ok then
        error(err)
    end
end

---Build payloads outside the SYNC frame. Cache misses here can spawn magick
---/ img2sixel via vim.system():wait() and yield the event loop — fine outside
---the sync block, dangerous inside it. Updates last_positions / redraw in
---lockstep with "we resolved a payload" so a build error doesn't desync.
---@param emit_set alt-img._core.render.Placement[]
---@return { bytes?: string, callbacks?: alt-img._core.render.Callbacks, id?: integer, pos?: alt-img._core.render.Position }[]
local function build_payloads(emit_set)
    local payloads = {}
    for _, p in ipairs(emit_set) do
        for _, pos in ipairs(p.next_positions or {}) do
            if p.callbacks.build_at then
                local bytes = p.callbacks.build_at(p.id, pos)
                if bytes then
                    payloads[#payloads + 1] = { bytes = bytes }
                end
            else
                payloads[#payloads + 1] = { callbacks = p.callbacks, id = p.id, pos = pos }
            end
        end
        p.last_positions = p.next_positions
        p.redraw = false
    end
    return payloads
end

---Two-pass emit: build payloads outside SYNC (where event-loop yields are
---safe), then term_send inside SYNC (where they are not). Sets is_drawing for
---the duration so a 30 ms timer tick can't spawn a re-entrant build.
---@param emit_set alt-img._core.render.Placement[]
---@param need_clear boolean
function M.emit(emit_set, need_clear)
    is_drawing = true
    local payloads = build_payloads(emit_set)
    with_sync_frame(function(term_io)
        if need_clear then
            -- :mode internally calls ex_redraw → update_screen → ui_flush, so
            -- the grid clear+repaint hits the TTY buffer synchronously, before
            -- any image bytes below.
            vim.cmd.mode()
        end
        for _, item in ipairs(payloads) do
            if item.bytes then
                term_io.send(item.bytes)
            else
                item.callbacks.emit_at(item.id, item.pos)
            end
        end
    end)
    is_drawing = false
end

---Synchronous-emit path for WinScrolled. Differs from emit() because
---WinScrolled fires BEFORE nvim's scroll redraw recomputes w_lines; for
---buffer placements with virt_lines, screenpos() returns row=0 until
---update_screen runs. So we force :mode INSIDE our SYNC frame, then read
---positions, build, and emit — all atomic. Build runs inside SYNC here,
---unlike emit()'s split: typical scroll cache-misses fit well under
---terminal Mode 2026 buffer timeouts.
function M.emit_force_resolve(registry)
    is_drawing = true
    with_sync_frame(function(term_io)
        vim.cmd.mode()
        for _, p in ipairs(registry.sort_by_zindex(registry.all())) do
            local positions = p.get_pos() or {}
            for _, pos in ipairs(positions) do
                if p.callbacks.build_at then
                    local bytes = p.callbacks.build_at(p.id, pos)
                    if bytes then
                        term_io.send(bytes)
                    end
                else
                    p.callbacks.emit_at(p.id, pos)
                end
            end
            p.last_positions = positions
            p.redraw = false
        end
    end)
    is_drawing = false
end

return M
