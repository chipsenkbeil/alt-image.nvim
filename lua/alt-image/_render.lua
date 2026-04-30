-- lua/alt-image/_render.lua
-- Shared rendering coordinator. Owns the placement registry, the synchronized
-- clear+redraw, and the post-redraw refresh hook.
--
-- Why this exists:
--   Terminal image protocols (iTerm2 OSC 1337 + sixel DCS) paint pixels into
--   the terminal framebuffer at absolute screen coordinates. Neovim doesn't
--   know those pixels exist. Anything that paints those cells (scroll, redraw
--   from a carrier float's bg, etc.) overwrites the image. The fix is:
--     - Wrap clear-and-redraw in Mode 2026 synchronized output (rerender_all),
--       so when something invalidates the framebuffer (scroll/move/delete),
--       we clear the framebuffer and re-emit before the user sees a flicker.
--     - Hook nvim_set_decoration_provider's on_end so after every Neovim
--       redraw cycle, we re-emit (without clearing) — re-painting any image
--       cells Neovim just wrote over.
local util = require('alt-image._util')

local M = {}

local SYNC_START = '\027[?2026h'
local SYNC_END   = '\027[?2026l'
local NS = vim.api.nvim_create_namespace('alt-image.render')

-- placements[key] = { provider = mod, id = number, get_pos = fn() -> {row,col}|nil }
local placements = {}
local function key(provider, id) return tostring(provider) .. ':' .. tostring(id) end

function M.register(provider, id, get_pos)
  placements[key(provider, id)] = { provider = provider, id = id, get_pos = get_pos }
end

function M.unregister(provider, id)
  placements[key(provider, id)] = nil
end

local function emit_all_unsynced()
  for _, p in pairs(placements) do
    local pos = p.get_pos()
    if pos then p.provider._emit_at(p.id, pos) end
  end
end

local pending_rerender = false

-- Synchronized clear + re-emit. Use on update/delete so old pixels don't trail.
function M.rerender_all()
  if pending_rerender then return end
  pending_rerender = true
  local old_termsync = vim.o.termsync
  vim.o.termsync = false
  util.term_send(SYNC_START)
  vim.cmd.mode()
  -- :redraw synchronously flushes Neovim's TUI grid to the TTY. Without
  -- this, our nvim_ui_send-based emit below can race ahead of the text
  -- repaint and end up overwritten when the TUI eventually flushes.
  vim.cmd('redraw')
  emit_all_unsynced()
  util.term_send(SYNC_END)
  vim.o.termsync = old_termsync
  pending_rerender = false
end

-- Re-emit only. Use after Neovim has already painted (redraw cycle done).
-- Called by on_end to re-paint any image cells Neovim just wrote over.
function M.refresh()
  if next(placements) == nil then return end
  emit_all_unsynced()
end

local refresh_scheduled = false
vim.api.nvim_set_decoration_provider(NS, {
  on_end = function()
    if next(placements) == nil or refresh_scheduled then return end
    refresh_scheduled = true
    vim.schedule(function()
      refresh_scheduled = false
      M.refresh()
    end)
  end,
})

return M
