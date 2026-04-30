-- lua/alt-image/_render.lua
-- Timer-driven, position-diff-based rendering coordinator.
--
-- Why this exists:
--   Terminal image protocols (iTerm2 OSC 1337 + sixel DCS) paint pixels into
--   the terminal framebuffer at absolute screen coordinates. Neovim doesn't
--   know those pixels exist, so anything that writes those cells (scroll,
--   redraw from a carrier float's bg, etc.) overwrites the image.
--
-- Design (modeled after PR #31399, with per-placement last_pos):
--   - One vim.uv timer at 30ms interval drives a `tick` callback.
--   - Autocmds (broadly) mark placements as `redraw=true` (dirty flag).
--   - On each tick:
--       * If nothing dirty, fast no-op.
--       * Otherwise, for each dirty placement, compute current screen pos.
--         If pos differs from `last_pos`, mark `need_clear`.
--       * Wrap in Mode 2026 synchronized output. If need_clear or a queued
--         clear (from unregister), do `vim.cmd.mode()` to clear framebuffer.
--       * Re-emit each dirty placement at its current pos. Update last_pos.
--       * Defer SYNC_END by 30ms so the redraw has time to land before the
--         terminal exits sync mode.
--   - `is_drawing` re-entry guard prevents overlapping ticks during the
--     deferred SYNC_END window.

local util = require('alt-image._util')

local M = {}

local SYNC_START   = '\027[?2026h'
local SYNC_END     = '\027[?2026l'
local TICK_MS      = 30
local DEFER_END_MS = 30

-- placements[key] = { provider, id, get_pos, redraw, last_pos }
local placements = {}
local clear_pending = false
local is_drawing = false

local function key(provider, id) return tostring(provider) .. ':' .. tostring(id) end

local function pos_eq(a, b)
  if a == nil and b == nil then return true end
  if a == nil or b == nil then return false end
  return a.row == b.row and a.col == b.col
end

-- The core scheduler step: re-emit all dirty placements, clearing the
-- framebuffer first if anything moved or unregistered.
--
-- `sync` mode (used by flush()) does the whole thing inline so callers can
-- chain emissions back-to-back. The default async mode defers SYNC_END by
-- 30ms so the terminal has time to flush the redraw before exiting sync mode.
local function tick(sync)
  if is_drawing then return end

  -- Collect dirty placements.
  local dirty = {}
  for _, p in pairs(placements) do
    if p.redraw then dirty[#dirty + 1] = p end
  end

  if #dirty == 0 then
    -- Idle path. If something cleared but no placements remain dirty, we
    -- still want a clear to happen (e.g. the last placement was unregistered).
    if clear_pending then
      is_drawing = true
      util.term_send(SYNC_START)
      vim.cmd.mode()
      if sync then
        util.term_send(SYNC_END)
        is_drawing = false
        clear_pending = false
      else
        vim.defer_fn(function()
          util.term_send(SYNC_END)
          is_drawing = false
          clear_pending = false
        end, DEFER_END_MS)
      end
    end
    return
  end

  -- Compute new positions and decide whether we need a framebuffer clear.
  local need_clear = false
  local resolved = {}
  for _, p in ipairs(dirty) do
    local pos = p.get_pos()
    resolved[p] = pos
    if not pos_eq(pos, p.last_pos) then need_clear = true end
  end

  is_drawing = true
  util.term_send(SYNC_START)
  if need_clear or clear_pending then
    vim.cmd.mode()
  end

  for _, p in ipairs(dirty) do
    local pos = resolved[p]
    if pos then p.provider._emit_at(p.id, pos) end
    p.last_pos = pos
    p.redraw = false
  end

  if sync then
    util.term_send(SYNC_END)
    is_drawing = false
    clear_pending = false
  else
    vim.defer_fn(function()
      util.term_send(SYNC_END)
      is_drawing = false
      clear_pending = false
    end, DEFER_END_MS)
  end
end

-- Public ---------------------------------------------------------------

function M.register(provider, id, get_pos)
  placements[key(provider, id)] = {
    provider = provider,
    id       = id,
    get_pos  = get_pos,
    redraw   = true,
    last_pos = nil,
  }
end

function M.unregister(provider, id)
  if placements[key(provider, id)] then
    placements[key(provider, id)] = nil
    clear_pending = true
  end
end

function M.invalidate(provider, id, also_clear)
  local p = placements[key(provider, id)]
  if p then p.redraw = true end
  if also_clear then clear_pending = true end
end

-- Synchronously run a tick. Used by callers that need immediate emission
-- (e.g. set() from tests). Unlike the timer-driven path, this does not
-- defer SYNC_END by 30ms — emission completes before this returns.
function M.flush()
  tick(true)
end

-- Timer + autocmds -----------------------------------------------------

-- One module-level timer drives the dirty-flag scan. Set up only if we have
-- a usable vim.uv.new_timer (we do in normal Neovim).
local timer = vim.uv.new_timer()
if timer then
  timer:start(TICK_MS, TICK_MS, vim.schedule_wrap(tick))
end

local AUGROUP = vim.api.nvim_create_augroup('alt-image.render', { clear = true })

local function mark_all_dirty()
  for _, p in pairs(placements) do p.redraw = true end
end

vim.api.nvim_create_autocmd({
  'BufEnter', 'BufWinEnter', 'BufWritePost',
  'TextChanged', 'TextChangedI',
  'CursorMoved', 'CursorMovedI',
  'WinScrolled', 'WinResized', 'VimResized', 'VimResume',
  'WinEnter', 'WinNew', 'TabEnter', 'WinClosed',
  'ModeChanged', 'CmdlineLeave',
}, {
  group = AUGROUP,
  callback = mark_all_dirty,
})

return M
