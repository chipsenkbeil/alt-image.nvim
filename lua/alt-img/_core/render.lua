local registry = require("alt-img._core.render.registry")
local sync_frame = require("alt-img._core.render.sync_frame")

-- Reset on every require so reloads (`:Lazy reload`, package.loaded fiddling)
-- start from an empty registry. No-op on first load.
registry.reset()

local M = {}

local TICK_MS = 30

---Core scheduler step. Re-emits all dirty placements, clearing the framebuffer
---first if anything moved or unregistered.
local function tick()
    if sync_frame.is_drawing() then
        return
    end

    -- Always read positions, regardless of the redraw dirty flag. Some state
    -- changes (line-deletion invalidating an extmark) don't reliably fire the
    -- autocmds that mark dirty; without the unconditional read, stale image
    -- bytes would linger on the terminal.
    local need_clear = registry.has_clear_pending()
    local initially_dirty = {}
    for _, p in ipairs(registry.all()) do
        local positions = p.get_pos() or {}
        p.next_positions = positions
        if not registry.positions_equal(positions, p.last_positions) or p.force_redraw then
            need_clear = true
            initially_dirty[#initially_dirty + 1] = p
            p.force_redraw = false
        elseif p.redraw then
            -- False alarm (typing/cursor move that didn't shift our anchor).
            p.redraw = false
        end
    end

    if #initially_dirty == 0 and not need_clear then
        return
    end

    local emit_set
    if need_clear then
        emit_set = registry.all()
    else
        emit_set = initially_dirty
    end
    registry.sort_by_zindex(emit_set)

    -- Resolve next_positions for placements pulled in by need_clear that
    -- weren't in the dirty scan.
    for _, p in ipairs(emit_set) do
        if not p.redraw then
            p.next_positions = p.get_pos() or {}
        end
    end

    sync_frame.emit(emit_set, need_clear)
    registry.consume_clear_pending()
end

-- Public ---------------------------------------------------------------

---@param token any opaque identity
---@param id integer
---@param get_pos fun(id: integer): table[]
---@param callbacks alt-img._core.render.Callbacks
function M.register(token, id, get_pos, callbacks)
    registry.register(token, id, get_pos, callbacks)
end

---@param token any
---@param id integer
function M.unregister(token, id)
    registry.unregister(token, id)
end

---@param token any
---@param id integer
function M.invalidate(token, id)
    registry.invalidate(token, id)
end

---Force every placement to re-emit on the next tick — even if its resolved
---screen position hasn't changed. Use when something OUTSIDE alt-img has
---wiped the terminal's image plane (`:mode`, `:redraw!`, external clear,
---resume from suspend).
function M.refresh()
    registry.force_all_dirty_with_position_reset()
    tick()
end

---Synchronously run a tick. Used by callers that need immediate emission.
function M.flush()
    tick()
end

local timer = vim.uv.new_timer()
if timer then
    timer:start(TICK_MS, TICK_MS, vim.schedule_wrap(tick))
end

local AUGROUP = vim.api.nvim_create_augroup("alt-img.render", { clear = true })

vim.api.nvim_create_autocmd({
    -- Hot path: fires on every keystroke. The position-equality elision in
    -- tick() turns no-op moves into zero-byte ticks.
    "TextChanged",
    "TextChangedI",
    "CursorMoved",
    "CursorMovedI",
}, {
    group = AUGROUP,
    callback = function()
        registry.mark_all_dirty()
    end,
})

-- WinScrolled: nvim repaints the cells the float / buffer image used to
-- occupy, evicting terminal-side image pixels. Re-emit synchronously inside
-- one Mode 2026 frame so scroll repaint and image re-emit land atomically,
-- eliminating the per-row blink.
vim.api.nvim_create_autocmd("WinScrolled", {
    group = AUGROUP,
    callback = function()
        registry.force_all_dirty_with_position_reset()
        if vim.in_fast_event() then
            vim.schedule(tick)
            return
        end
        if sync_frame.is_drawing() then
            return
        end
        sync_frame.emit_force_resolve(registry)
        registry.consume_clear_pending()
    end,
})

vim.api.nvim_create_autocmd({
    -- Likely-wipe path: events that often correlate with the terminal
    -- compositor evicting image cells (mode prompts, buffer/window shuffling,
    -- resize). Force re-emit regardless of position-equality.
    "BufEnter",
    "BufWinEnter",
    "BufWritePost",
    "WinEnter",
    "WinNew",
    "WinClosed",
    "WinResized",
    "VimResized",
    "VimResume",
    "TabEnter",
    "ModeChanged",
    "CmdlineLeave",
}, {
    group = AUGROUP,
    callback = function()
        registry.force_all_dirty()
    end,
})

return M
