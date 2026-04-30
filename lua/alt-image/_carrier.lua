-- lua/alt-image/_carrier.lua
-- Reserves screen real estate via floating windows / extmarks for placements
-- with relative != 'ui'. Layout-change autocmds delegate to the render
-- coordinator, which handles the synchronized clear+redraw across all
-- placements (carrier-tracked or not).
--
-- Provider contract: providers must expose `_emit_at(id, screen_pos)`. The
-- carrier itself does not call providers directly anymore.

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
  local w = (opts.width or 1) + 2 * pad
  local h = (opts.height or 1) + 2 * pad
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
  return vim.api.nvim_buf_set_extmark(opts.buf, NS,
    (opts.row or 1) - 1, (opts.col or 1) - 1, {
      virt_lines = virt,
      virt_lines_above = false,
    })
end

local function resolve_screen_pos(c)
  if c.kind == 'editor' then
    if not vim.api.nvim_win_is_valid(c.winid) then return nil end
    local pos = vim.api.nvim_win_get_position(c.winid)
    return { row = pos[1] + 1, col = pos[2] + 1 }
  else
    -- relative='buffer': find a window showing this buffer; use screenpos.
    local mark = vim.api.nvim_buf_get_extmark_by_id(c.bufnr, NS, c.extmark_id, {})
    if not mark or not mark[1] then return nil end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == c.bufnr then
        local sp = vim.fn.screenpos(win, mark[1] + 1, (mark[2] or 0) + 1)
        if sp.row > 0 then return { row = sp.row, col = sp.col } end
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

local function refresh_all()
  -- Layout changed; positions may have changed. Let _render do the synchronized
  -- redraw across all placements (it knows about both carrier-backed ones and
  -- relative='ui' ones, so re-emitting them all keeps the framebuffer correct).
  if next(carriers) == nil then return end
  require('alt-image._render').rerender_all()
end

-- Single debounced refresh: a burst of layout events => one redraw.
local pending = false
local function schedule_refresh()
  if pending then return end
  pending = true
  vim.schedule(function() pending = false; refresh_all() end)
end

vim.api.nvim_create_autocmd(
  { 'WinScrolled', 'WinResized', 'VimResized', 'BufWinEnter', 'TabEnter' },
  { group = AUGROUP, callback = schedule_refresh }
)

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
