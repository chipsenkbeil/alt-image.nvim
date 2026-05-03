-- Timer-driven, position-diff-based rendering coordinator.
--
-- Why this exists:
--   Terminal image protocols (iTerm2 OSC 1337 + sixel DCS) paint pixels into
--   the terminal framebuffer at absolute screen coordinates. Neovim doesn't
--   know those pixels exist, so anything that writes those cells (scroll,
--   redraw from a carrier float's bg, etc.) overwrites the image.
--
-- Design (modeled after PR #31399, with per-placement last_positions):
--   - One vim.uv timer at 30ms interval drives a `tick` callback.
--   - Autocmds (broadly) mark placements as `redraw=true` (dirty flag).
--   - On each tick:
--       * If nothing dirty, fast no-op.
--       * Otherwise, for each dirty placement, compute current screen
--         positions (a *list*, possibly empty). If the list differs from
--         `last_positions`, mark `need_clear`.
--       * Wrap in Mode 2026 synchronized output. If need_clear or a queued
--         clear (from unregister), do `vim.cmd.mode()` to clear framebuffer.
--         `:mode` itself calls update_screen()+ui_flush() (see neovim
--         src/nvim/ex_docmd.c:ex_mode), so the grid clear+repaint lands in
--         the TTY buffer before we emit image bytes — no extra :redraw
--         needed.
--       * Re-emit each dirty placement at every position in its list. Update
--         last_positions.
--   - All emission happens synchronously within the SYNC block.

local util = require("alt-img._core.util")

local M = {}

local SYNC_START = "\027[?2026h"
local SYNC_END = "\027[?2026l"
local TICK_MS = 30

-- placements[key] = { provider, id, get_pos, redraw, last_positions, next_positions }
-- where last_positions / next_positions are lists of `{row, col, src}` records.
local placements = {}
local clear_pending = false
local is_drawing = false

local function key(provider, id)
    return tostring(provider) .. ":" .. tostring(id)
end

-- Compare two position lists for structural equality. Treats nil and empty
-- list as equal (both mean "not visible"). Handles the new `src` rect.
local function positions_equal(a, b)
    if (a == nil) ~= (b == nil) then
        -- one is nil, the other is a list. They're equal only if the list is empty.
        local list = a or b
        return #list == 0
    end
    if a == nil then
        return true
    end
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        local x, y = a[i], b[i]
        if x.row ~= y.row or x.col ~= y.col then
            return false
        end
        local sx, sy = x.src or {}, y.src or {}
        if sx.x ~= sy.x or sx.y ~= sy.y or sx.w ~= sy.w or sx.h ~= sy.h then
            return false
        end
    end
    return true
end

-- The core scheduler step: re-emit all dirty placements, clearing the
-- framebuffer first if anything moved or unregistered.
--
-- All emission happens synchronously within the SYNC block. When need_clear,
-- `vim.cmd.mode()` invalidates Neovim's grid AND immediately runs ex_redraw
-- → update_screen() → ui_flush(), so the grid clear+repaint bytes land in
-- the TTY buffer before our image bytes — no separate `:redraw` required.
-- When need_clear is false, we don't dirty Neovim's grid in this tick, so
-- there's nothing to flush before emitting.
local function tick()
    if is_drawing then
        return
    end

    -- Snapshot dirty placements; detect movement.
    --
    -- A placement that is dirty but whose resolved positions are identical
    -- to last tick's gets its dirty flag cleared without entering
    -- `initially_dirty`. Re-pushing many KB of sixel/OSC bytes on every
    -- CursorMoved/TextChanged is the dominant per-keystroke cost during
    -- typing, and the terminal cells haven't been touched if the position
    -- and dims didn't change. If something else in this tick triggers
    -- `need_clear` (a peer placement moved, an unregister landed), the
    -- registry-expand branch below pulls every placement back in, so a
    -- genuine framebuffer wipe still gets covered.
    local need_clear = clear_pending
    local initially_dirty = {}
    for _, p in pairs(placements) do
        if p.redraw then
            local positions = p.get_pos() or {}
            p.next_positions = positions
            if not positions_equal(positions, p.last_positions) then
                need_clear = true
                initially_dirty[#initially_dirty + 1] = p
            else
                p.redraw = false
            end
        end
    end

    if #initially_dirty == 0 and not need_clear then
        return
    end

    -- Expand to full registry if clearing.
    local emit_set
    if need_clear then
        emit_set = {}
        for _, p in pairs(placements) do
            emit_set[#emit_set + 1] = p
        end
    else
        emit_set = initially_dirty
    end

    -- Sort emit_set by zindex (ascending) so higher-z emits last and paints on top.
    table.sort(emit_set, function(a, b)
        local ao = (a.provider.get and a.provider.get(a.id)) or {}
        local bo = (b.provider.get and b.provider.get(b.id)) or {}
        local az = ao.zindex or 0
        local bz = bo.zindex or 0
        if az ~= bz then
            return az < bz
        end
        return a.id < b.id -- stable tiebreak
    end)

    -- Resolve current positions for any placement in the emit set that didn't
    -- already have its next_positions computed in the dirty scan above (i.e.,
    -- non-dirty placements pulled in by need_clear).
    for _, p in ipairs(emit_set) do
        if not p.redraw then
            p.next_positions = p.get_pos() or {}
        end
    end

    -- Emit, all inside one Mode 2026 sync block.
    is_drawing = true
    local old_termsync = vim.o.termsync
    vim.o.termsync = false
    local ok, err = pcall(function()
        util.term_send(SYNC_START)
        if need_clear then
            -- :mode internally calls ex_redraw → update_screen → ui_flush,
            -- so the grid clear+repaint hits the TTY buffer synchronously,
            -- inside this sync frame, before any image bytes below.
            vim.cmd.mode()
        end
        for _, p in ipairs(emit_set) do
            for _, pos in ipairs(p.next_positions or {}) do
                p.provider._emit_at(p.id, pos)
            end
            p.last_positions = p.next_positions
            p.redraw = false
        end
    end)

    -- SYNC_END must run even if the emit body above errored — otherwise the
    -- terminal stays in Mode 2026 and subsequent ticks nest fresh SYNC_STARTs
    -- inside the still-open frame.
    util.term_send(SYNC_END)
    vim.o.termsync = old_termsync
    is_drawing = false
    clear_pending = false
    if not ok then
        error(err)
    end
end

-- Public ---------------------------------------------------------------

function M.register(provider, id, get_pos)
    placements[key(provider, id)] = {
        provider = provider,
        id = id,
        get_pos = get_pos,
        redraw = true,
        last_positions = nil,
    }
end

function M.unregister(provider, id)
    if placements[key(provider, id)] then
        placements[key(provider, id)] = nil
        clear_pending = true
    end
end

function M.invalidate(provider, id)
    local p = placements[key(provider, id)]
    if p then
        p.redraw = true
    end
end

-- Force every placement to re-emit on the next tick — even if its resolved
-- screen position hasn't changed. Use when something OUTSIDE alt-img has
-- wiped the terminal's image plane: `:mode`, `:redraw!`, an external clear,
-- a terminal-side resize race, etc. The position-equality elision in tick()
-- (which keeps mouse/typing from re-pushing every tick) treats stale image
-- bytes as "still there"; this clears that assumption by nulling each
-- placement's last_positions, so the next tick sees a movement and re-emits.
function M.refresh()
    for _, p in pairs(placements) do
        p.last_positions = nil
        p.redraw = true
    end
    tick()
end

-- Synchronously run a tick. Used by callers that need immediate emission
-- (e.g. set() from tests). Emission completes before this returns.
function M.flush()
    tick()
end

-- Timer + autocmds -----------------------------------------------------

-- One module-level timer drives the dirty-flag scan. Set up only if we have
-- a usable vim.uv.new_timer (we do in normal Neovim). Exposed as M._timer
-- so the benchmark harness (test/benchmark.lua) can stop it; otherwise
-- `vim.system():wait()` yields the event loop and lets the timer's tick
-- spawn extra subprocesses inside the benchmark's timing window, polluting
-- `subprocess_count` measurements.
local timer = vim.uv.new_timer()
if timer then
    timer:start(
        TICK_MS,
        TICK_MS,
        vim.schedule_wrap(function()
            tick()
        end)
    )
end
M._timer = timer

local AUGROUP = vim.api.nvim_create_augroup("alt-img.render", { clear = true })

-- Cheap mark: just set the dirty flag. Tick still applies the position-
-- equality elision so typing/cursor-movement that doesn't actually move
-- a placement re-emits zero bytes. Used for hot autocmds (TextChanged,
-- CursorMoved).
local function mark_all_dirty()
    for _, p in pairs(placements) do
        p.redraw = true
    end
end

-- Synchronous-emit path: mark dirty AND tick immediately so our SYNC
-- frame closes before nvim's post-autocmd grid flush. With this, the
-- scroll-redraw bytes (which evict image cells the float / extmark
-- overlapped) and our image re-emit bytes land in the SAME atomic
-- terminal frame: vim.cmd.mode() inside tick() drains nvim's grid
-- through ui_flush, so both the scroll repaint and the image emit are
-- inside our \e[?2026h…\e[?2026l boundary. Without this, every
-- WinScrolled would leave a 1–30 ms gap between nvim's flush frame
-- (text scrolled, images evicted) and our timer-driven re-emit frame —
-- pacing one visible blink per row scrolled.
--
-- Fast-event guard: vim.cmd.mode() can't run inside fast events. Fall
-- back to vim.schedule (next loop iteration) when we're in one — still
-- faster than waiting for the 30 ms timer, and crash-free.
local function mark_all_dirty_and_flush()
    for _, p in pairs(placements) do
        p.redraw = true
    end
    if vim.in_fast_event() then
        vim.schedule(tick)
    else
        tick()
    end
end

-- Force mark: also nulls last_positions so the position-equality check
-- in tick() always sees "moved" and re-emits, even when nothing visible
-- has changed. Used for autocmds that correlate with a terminal-side
-- screen wipe (mode transitions, message-prompt dismissal, buffer /
-- window shuffling, terminal resize, resume from suspend). Without
-- this, dismissing :AltImg info's hit-enter prompt would leave images
-- gone until the user manually ran :AltImg refresh.
M._force_all_dirty = function()
    for _, p in pairs(placements) do
        p.last_positions = nil
        p.redraw = true
    end
end

vim.api.nvim_create_autocmd({
    -- Hot path: fires on every keystroke. Position-equality elision in
    -- tick() turns no-op cursor/text changes into zero-byte ticks, so
    -- the timer-driven cadence keeps typing responsive.
    "TextChanged",
    "TextChangedI",
    "CursorMoved",
    "CursorMovedI",
}, {
    group = AUGROUP,
    callback = mark_all_dirty,
})

vim.api.nvim_create_autocmd({
    -- Sync-emit path: every WinScrolled correlates with nvim repainting
    -- cells the float / buffer image used to occupy, evicting the
    -- corresponding terminal-side image pixels. Re-emit synchronously so
    -- our SYNC frame closes before nvim's natural post-autocmd flush —
    -- both the scroll repaint and the image re-emit land in one atomic
    -- terminal frame, eliminating the per-row blink.
    "WinScrolled",
}, {
    group = AUGROUP,
    callback = mark_all_dirty_and_flush,
})

vim.api.nvim_create_autocmd({
    -- Likely-wipe path: events that often correlate with the terminal
    -- compositor evicting image cells (full redraws, mode prompts,
    -- buffer/window shuffling, resize). Force re-emit regardless of
    -- position-equality — image bytes may be gone even though our
    -- last_positions still match next_positions.
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
        M._force_all_dirty()
    end,
})

return M
