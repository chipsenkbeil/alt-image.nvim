-- lua/alt-image/_carrier.lua
-- Reserves screen real estate via floating windows / extmarks for placements
-- with relative != 'ui'. Owns the float/extmark lifecycle and exposes the
-- current screen position via M.get_pos. The render coordinator (_render)
-- owns redraw scheduling and dirty-flag autocmds; the carrier just keeps
-- its windows/marks consistent and evicts dangling floats on WinClosed.
--
-- Provider contract: providers must expose `_emit_at(id, screen_pos)`. The
-- carrier itself does not call providers directly.

local M = {}

local NS = vim.api.nvim_create_namespace('alt-image.carrier')
local AUGROUP = vim.api.nvim_create_augroup('alt-image.carrier', { clear = true })

-- carriers[key] = { provider = provider_module, id = provider_id,
--                   opts = opts, kind = 'editor'|'buffer',
--                   winid = ..., extmark_id = ..., bufnr = ...,
--                   last_pos = {row, col} }
local carriers = {}

local function provider_key(provider, id)
  return tostring(provider) .. ':' .. tostring(id)
end

local function size_in_cells(opts)
  local pad = opts.pad or 0
  local w = (opts.width or 1) + pad
  local h = opts.height or 1
  return w, h
end

-- Open a no-content floating window at editor (row, col), sized w x h.
local function open_editor_carrier(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  local w, h = size_in_cells(opts)
  local winid = vim.api.nvim_open_win(buf, false, {
    relative  = 'editor',
    row       = (opts.row or 1) - 1,
    col       = (opts.col or 1) - 1,
    width     = w,
    height    = h,
    focusable = false,
    style     = 'minimal',
    zindex    = opts.zindex or 50,
  })
  return winid, buf
end

local function place_buffer_extmark(opts)
  local _, h = size_in_cells(opts)
  local virt = {}
  for _ = 1, h do virt[#virt + 1] = { { '', 'Normal' } } end
  local row = (opts.row or 1) - 1
  return vim.api.nvim_buf_set_extmark(opts.buf, NS,
    row, (opts.col or 1) - 1, {
      end_row = row + 1,
      end_col = 0,
      virt_lines = virt,
      virt_lines_above = false,
      invalidate = true,
      undo_restore = false,
    })
end

local function resolve_screen_pos(c)
  if c.kind == 'editor' then
    if not vim.api.nvim_win_is_valid(c.winid) then return nil end
    local pos = vim.api.nvim_win_get_position(c.winid)
    local pad = (c.opts and c.opts.pad) or 0
    return { row = pos[1] + 1, col = pos[2] + 1 + pad }
  else
    -- relative='buffer': find a window showing this buffer; use screenpos.
    if not vim.api.nvim_buf_is_valid(c.bufnr) then return nil end
    local mark = vim.api.nvim_buf_get_extmark_by_id(c.bufnr, NS, c.extmark_id, { details = true })
    if not mark or not mark[1] then return nil end
    local details = mark[3]
    if details and details.invalid then return nil end
    local line = mark[1] + 1
    local line_count = vim.api.nvim_buf_line_count(c.bufnr)
    if line < 1 or line > line_count then return nil end
    local col  = (mark[2] or 0) + 1
    local pad = (c.opts and c.opts.pad) or 0
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == c.bufnr then
        local ok, sp = pcall(vim.fn.screenpos, win, line, col)
        if ok and sp and sp.row > 0 then
          -- The image goes in the virt_lines BELOW the anchor line, not on it.
          -- (Assumes the anchor line is one screen row tall — i.e., not wrapped.)
          return { row = sp.row + 1, col = sp.col + pad }
        end
      end
    end
    return nil
  end
end

-- Register a new placement that needs a carrier.
-- Returns initial screen_pos {row, col}, or nil if offscreen.
function M.register(provider, id, opts)
  local c = { provider = provider, id = id, opts = opts }
  if opts.relative == 'editor' then
    c.kind = 'editor'
    c.winid, c.bufnr = open_editor_carrier(opts)
  elseif opts.relative == 'buffer' then
    if not opts.buf then error('alt-image: relative=buffer requires opts.buf', 3) end
    c.kind = 'buffer'
    c.bufnr = opts.buf
    c.extmark_id = place_buffer_extmark(opts)
  else
    error('alt-image: unsupported relative ' .. tostring(opts.relative), 3)
  end
  c.last_pos = resolve_screen_pos(c)
  carriers[provider_key(provider, id)] = c
  return c.last_pos
end

-- Reposition the carrier for an existing placement. Called by providers when
-- M.set(id, opts) updates row/col/width/height/etc. Without this, carriers
-- stay where they were first opened and the resolved screen pos never moves.
function M.update(provider, id, opts)
  local key = provider_key(provider, id)
  local c = carriers[key]
  if not c then return end
  c.opts = opts
  if c.kind == 'editor' then
    if c.winid and vim.api.nvim_win_is_valid(c.winid) then
      local w, h = size_in_cells(opts)
      vim.api.nvim_win_set_config(c.winid, {
        relative  = 'editor',
        row       = (opts.row or 1) - 1,
        col       = (opts.col or 1) - 1,
        width     = w,
        height    = h,
        focusable = false,
        style     = 'minimal',
        zindex    = opts.zindex or 50,
      })
    end
  elseif c.kind == 'buffer' then
    if c.extmark_id then
      pcall(vim.api.nvim_buf_del_extmark, c.bufnr, NS, c.extmark_id)
    end
    if opts.buf then c.bufnr = opts.buf end
    c.extmark_id = place_buffer_extmark(opts)
  end
  c.last_pos = resolve_screen_pos(c)
end

function M.unregister(provider, id)
  local key = provider_key(provider, id)
  local c = carriers[key]
  if not c then return end
  if c.kind == 'editor' and c.winid and vim.api.nvim_win_is_valid(c.winid) then
    pcall(vim.api.nvim_win_close, c.winid, true)
  elseif c.kind == 'buffer' and c.extmark_id then
    pcall(vim.api.nvim_buf_del_extmark, c.bufnr, NS, c.extmark_id)
  end
  carriers[key] = nil
end

-- Public position lookup used by the render coordinator's get_pos closure
-- factories on the providers. Returns nil if the carrier is gone or offscreen.
function M.get_pos(provider, id)
  local c = carriers[provider_key(provider, id)]
  if not c then return nil end
  return resolve_screen_pos(c)
end

-- Evict dangling floats so we don't try to resolve_screen_pos against a
-- closed window. _render's autocmds will pick up the layout change and
-- re-emit remaining placements at their new positions.
vim.api.nvim_create_autocmd(
  { 'WinClosed' },
  {
    group = AUGROUP,
    callback = function(args)
      local closed = tonumber(args.match)
      for k, c in pairs(carriers) do
        if c.winid == closed then carriers[k] = nil end
      end
    end,
  }
)

return M
