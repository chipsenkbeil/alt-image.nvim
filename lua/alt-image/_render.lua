-- lua/alt-image/_render.lua
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
--       * Force TUI flush with `:redraw` to ensure any queued grid updates
--         (text repaint, float bg) land BEFORE our image bytes.
--       * Re-emit each dirty placement at every position in its list. Update
--         last_positions.
--   - All emission happens synchronously within the SYNC block.

local util = require('alt-image._util')

local M = {}

local SYNC_START   = '\027[?2026h'
local SYNC_END     = '\027[?2026l'
local TICK_MS      = 30

-- placements[key] = { provider, id, get_pos, redraw, last_positions, next_positions }
-- where last_positions / next_positions are lists of `{row, col, src}` records.
local placements = {}
local clear_pending = false
local is_drawing = false

local function key(provider, id) return tostring(provider) .. ':' .. tostring(id) end

-- Compare two position lists for structural equality. Treats nil and empty
-- list as equal (both mean "not visible"). Handles the new `src` rect.
local function positions_equal(a, b)
  if (a == nil) ~= (b == nil) then
    -- one is nil, the other is a list. They're equal only if the list is empty.
    local list = a or b
    return #list == 0
  end
  if a == nil then return true end
  if #a ~= #b then return false end
  for i = 1, #a do
    local x, y = a[i], b[i]
    if x.row ~= y.row or x.col ~= y.col then return false end
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
      local positions = p.get_pos() or {}
      if not positions_equal(positions, p.last_positions) then
        need_clear = true
      end
      p.next_positions = positions
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

  -- Sort emit_set by zindex (ascending) so higher-z emits last and paints on top.
  table.sort(emit_set, function(a, b)
    local ao = (a.provider.get and a.provider.get(a.id)) or {}
    local bo = (b.provider.get and b.provider.get(b.id)) or {}
    local az = ao.zindex or 0
    local bz = bo.zindex or 0
    if az ~= bz then return az < bz end
    return a.id < b.id  -- stable tiebreak
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
    if need_clear then vim.cmd.mode() end
    -- Force TUI grid -> TTY flush so any queued text/float-bg paint lands
    -- BEFORE our image bytes. Without this, the float-bg or text-repaint
    -- output would race past SYNC_END and overwrite the image cells.
    vim.cmd('redraw')
    for _, p in ipairs(emit_set) do
      for _, pos in ipairs(p.next_positions or {}) do
        p.provider._emit_at(p.id, pos)
      end
      p.last_positions = p.next_positions
      p.redraw = false
    end
    util.term_send(SYNC_END)
  end)
  vim.o.termsync = old_termsync
  is_drawing = false
  clear_pending = false
  if not ok then error(err) end
end

-- Public ---------------------------------------------------------------

function M.register(provider, id, get_pos)
  placements[key(provider, id)] = {
    provider       = provider,
    id             = id,
    get_pos        = get_pos,
    redraw         = true,
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
  if p then p.redraw = true end
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
