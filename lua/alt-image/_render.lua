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
--       * Force TUI flush with `:redraw` to ensure any queued grid updates
--         (text repaint, float bg) land BEFORE our image bytes.
--       * Re-emit each dirty placement at its current pos. Update last_pos.
--   - All emission happens synchronously within the SYNC block.

local util = require('alt-image._util')

local M = {}

local SYNC_START   = '\027[?2026h'
local SYNC_END     = '\027[?2026l'
local TICK_MS      = 30

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
-- All emission happens synchronously within the SYNC block. vim.cmd('redraw')
-- forces the TUI to flush any queued grid updates (text repaint, float bg)
-- to the TTY BEFORE our image bytes, ensuring they don't race past SYNC_END
-- and overwrite the image cells.
local function tick()
  if is_drawing then return end

  -- Snapshot dirty placements; detect movement.
  local need_clear = clear_pending
  local initially_dirty = {}
  for _, p in pairs(placements) do
    if p.redraw then
      local pos = p.get_pos()
      if pos and p.last_pos
         and (pos.row ~= p.last_pos.row or pos.col ~= p.last_pos.col)
      then
        need_clear = true
      end
      initially_dirty[#initially_dirty + 1] = p
    end
  end

  if #initially_dirty == 0 and not need_clear then return end

  -- Expand to full registry if clearing.
  local emit_set
  if need_clear then
    emit_set = {}
    for _, p in pairs(placements) do emit_set[#emit_set + 1] = p end
  else
    emit_set = initially_dirty
  end

  -- Resolve current positions for the emit set.
  for _, p in ipairs(emit_set) do
    p.next_pos = p.get_pos()
  end

  -- Emit, all inside one Mode 2026 sync block.
  is_drawing = true
  util.term_send(SYNC_START)
  if need_clear then vim.cmd.mode() end
  -- Force TUI grid -> TTY flush so any queued text/float-bg paint lands
  -- BEFORE our image bytes. Without this, the float-bg or text-repaint
  -- output would race past SYNC_END and overwrite the image cells.
  vim.cmd('redraw')
  for _, p in ipairs(emit_set) do
    if p.next_pos then p.provider._emit_at(p.id, p.next_pos) end
    p.last_pos = p.next_pos
    p.redraw = false
  end
  util.term_send(SYNC_END)
  is_drawing = false
  clear_pending = false
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
-- (e.g. set() from tests). Emission completes before this returns.
function M.flush()
  tick()
end

-- Timer + autocmds -----------------------------------------------------

-- One module-level timer drives the dirty-flag scan. Set up only if we have
-- a usable vim.uv.new_timer (we do in normal Neovim).
local timer = vim.uv.new_timer()
if timer then
  timer:start(TICK_MS, TICK_MS, vim.schedule_wrap(function() tick() end))
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
