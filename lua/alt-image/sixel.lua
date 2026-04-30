-- lua/alt-image/sixel.lua
-- Sixel image protocol provider, drop-in for vim.ui.img.
-- Ported from chipsenkbeil/neovim:feat/MoreImgProviders
--   runtime/lua/vim/ui/img/_sixel.lua
--
-- Decodes the input bytes (PNG only in v1) to RGBA, optionally resizes to
-- the requested cell dims, runs the encoder, caches the result per-placement,
-- and emits the DCS sequence.

local util = require('alt-image._util')
local png  = require('alt-image._png')
local senc = require('alt-image._sixel_encode')

local M = {}

local SYNC_START = '\027[?2026h'
local SYNC_END   = '\027[?2026l'

-- state[id] = { data = bytes, opts = canonical_opts, sixel_cache = string|nil }
local state = {}
local next_id = 1

local function new_id() local id = next_id; next_id = next_id + 1; return id end

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

local function build_sixel(s)
  if s.sixel_cache then return s.sixel_cache end
  local img = png.decode(s.data)
  local rgba, w, h = img.pixels, img.width, img.height
  if s.opts.width or s.opts.height then
    local cw, ch = util.cell_pixel_size()
    local tw = (s.opts.width  or math.ceil(w / cw)) * cw
    local th = (s.opts.height or math.ceil(h / ch)) * ch
    rgba, w, h = senc.resize(rgba, w, h, tw, th)
  end
  s.sixel_cache = senc.encode_sixel(rgba, w, h)
  return s.sixel_cache
end

local function emit(s)
  local sixel = build_sixel(s)
  local opts = s.opts
  local cmove = string.format('\027[%d;%dH', opts.row or 1, opts.col or 1)
  util.term_send(
    SYNC_START
    .. '\0277' .. '\027[?25l' .. cmove
    .. sixel
    .. '\0278' .. '\027[?25h' .. SYNC_END
  )
end

function M.set(data_or_id, opts)
  vim.validate({
    data_or_id = { data_or_id, { 'string', 'number' } },
    opts       = { opts, 'table', true },
  })
  if type(data_or_id) == 'number' then
    local s = state[data_or_id]
    if not s then error('alt-image.sixel: unknown id ' .. tostring(data_or_id), 2) end
    s.opts = vim.tbl_extend('force', s.opts, canonicalize(opts))
    s.sixel_cache = nil  -- opts changed -> may need re-encode if size changed
    emit(s)
    return data_or_id
  end
  local id = new_id()
  state[id] = { data = data_or_id, opts = canonicalize(opts) }
  emit(state[id])
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
    if any then vim.cmd.mode() end
    return any
  end
  if not state[id] then return false end
  state[id] = nil
  vim.cmd.mode()
  return true
end

function M._supported(_opts) return false end  -- replaced in Task 10

return M
