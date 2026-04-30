-- lua/alt-image/iterm2.lua
-- iTerm2 OSC 1337 image protocol provider, drop-in for vim.ui.img.
-- Ported from chipsenkbeil/neovim:feat/MoreImgProviders
--   runtime/lua/vim/ui/img/_iterm2.lua

local util = require('alt-image._util')

local M = {}

local SYNC_START = '\027[?2026h'
local SYNC_END   = '\027[?2026l'

-- Per-id placement state. state[id] = { data = bytes, opts = canonical_opts }
local state = {}
local next_id = 1

local function new_id()
  local id = next_id
  next_id = next_id + 1
  return id
end

local function canonicalize(opts)
  opts = opts or {}
  return {
    row      = opts.row,
    col      = opts.col,
    width    = opts.width,
    height   = opts.height,
    zindex   = opts.zindex,
    relative = opts.relative or 'ui',
    buf      = opts.buf,
    pad      = opts.pad,
  }
end

local function emit(data, opts)
  -- relative='ui' only in this task. Carrier modes added in Tasks 11-12.
  local b64 = vim.base64.encode(data)
  local args = {
    'size=' .. #data,
    'inline=1',
    'preserveAspectRatio=' .. ((opts.width and opts.height) and 0 or 1),
  }
  if opts.width  then args[#args + 1] = 'width='  .. opts.width  end
  if opts.height then args[#args + 1] = 'height=' .. opts.height end

  local cursor_save    = '\0277'
  local cursor_hide    = '\027[?25l'
  local cursor_move    = string.format('\027[%d;%dH', opts.row or 1, opts.col or 1)
  local cursor_restore = '\0278'
  local cursor_show    = '\027[?25h'

  local osc = '\027]1337;File=' .. table.concat(args, ';') .. ':' .. b64 .. '\007'
  util.term_send(SYNC_START
    .. cursor_save .. cursor_hide .. cursor_move
    .. osc
    .. cursor_restore .. cursor_show
    .. SYNC_END)
end

function M.set(data_or_id, opts)
  vim.validate({
    data_or_id = { data_or_id, { 'string', 'number' } },
    opts       = { opts, 'table', true },
  })

  if type(data_or_id) == 'number' then
    local s = state[data_or_id]
    if not s then error('alt-image.iterm2: unknown id ' .. tostring(data_or_id), 2) end
    s.opts = vim.tbl_extend('force', s.opts, canonicalize(opts))
    emit(s.data, s.opts)
    return data_or_id
  end

  local id = new_id()
  state[id] = { data = data_or_id, opts = canonicalize(opts) }
  emit(state[id].data, state[id].opts)
  return id
end

function M.get(id)
  local s = state[id]
  if not s then return nil end
  return vim.deepcopy(s.opts)
end

function M.del(id)
  if id == math.huge then
    local any = next(state) ~= nil
    state = {}
    if any then vim.cmd.mode() end  -- force TUI redraw to clear pixels
    return any
  end
  if not state[id] then return false end
  state[id] = nil
  vim.cmd.mode()
  return true
end

function M._supported(_opts)
  -- placeholder; real implementation in Task 7
  return false
end

return M
