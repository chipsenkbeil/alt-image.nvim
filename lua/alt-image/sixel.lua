-- lua/alt-image/sixel.lua
-- Sixel image protocol provider, drop-in for vim.ui.img.
-- Ported from chipsenkbeil/neovim:feat/MoreImgProviders
--   runtime/lua/vim/ui/img/_sixel.lua
--
-- Decodes the input bytes (PNG only in v1) to RGBA, optionally resizes to
-- the requested cell dims, runs the encoder, caches the result per-placement,
-- and emits the DCS sequence.

local util    = require('alt-image._util')
local png     = require('alt-image._png')
local senc    = require('alt-image._sixel_encode')
local carrier = require('alt-image._carrier')

local M = {}

local SYNC_START = '\027[?2026h'
local SYNC_END   = '\027[?2026l'

local KNOWN_SIXEL_TERMS = {
  foot = true, mlterm = true, contour = true,
}

-- state[id] = { data = bytes, opts = canonical_opts, sixel_cache = string|nil, id = id }
local state = {}
local next_id = 1

local function new_id() local id = next_id; next_id = next_id + 1; return id end

local function canonicalize(opts)
  opts = opts or {}
  local rel = opts.relative or 'ui'
  if rel ~= 'ui' and rel ~= 'editor' and rel ~= 'buffer' then
    error('alt-image: invalid relative ' .. tostring(rel)
       .. " (expected 'ui', 'editor', or 'buffer')", 3)
  end
  return {
    row      = opts.row,
    col      = opts.col,
    width    = opts.width,
    height   = opts.height,
    zindex   = opts.zindex,
    relative = rel,
    buf      = opts.buf,
    pad      = opts.pad,
  }
end

local function build_sixel(s)
  if s.sixel_cache then return s.sixel_cache end
  local img = png.decode(s.data)
  local rgba, w, h = img.pixels, img.width, img.height
  if s.opts.width or s.opts.height then
    util.query_cell_size()
    local cw, ch = util.cell_pixel_size()
    local tw = (s.opts.width  or math.ceil(w / cw)) * cw
    local th = (s.opts.height or math.ceil(h / ch)) * ch
    rgba, w, h = senc.resize(rgba, w, h, tw, th)
  end
  s.sixel_cache = senc.encode_sixel(rgba, w, h)
  return s.sixel_cache
end

local function emit_at(s, screen_pos)
  local sixel = build_sixel(s)
  local opts = s.opts
  local cmove = string.format('\027[%d;%dH',
                              screen_pos and screen_pos.row or (opts.row or 1),
                              screen_pos and screen_pos.col or (opts.col or 1))
  util.term_send(
    SYNC_START
    .. '\0277' .. '\027[?25l' .. cmove
    .. sixel
    .. '\0278' .. '\027[?25h' .. SYNC_END
  )
end

local function emit(s)
  if s.opts.relative == 'ui' then emit_at(s, nil); return end
  local pos = carrier.register(M, s.id, s.opts)
  if pos then emit_at(s, pos) end
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
    s.id = data_or_id
    emit(s)
    return data_or_id
  end
  local id = new_id()
  state[id] = { data = data_or_id, opts = canonicalize(opts), id = id }
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
    for k, _ in pairs(state) do carrier.unregister(M, k) end
    state = {}
    if any then vim.cmd.mode() end
    return any
  end
  if not state[id] then return false end
  carrier.unregister(M, id)
  state[id] = nil
  vim.cmd.mode()
  return true
end

-- Called by the carrier when the carrier moves (scroll/resize).
function M._reemit(id, screen_pos)
  local s = state[id]
  if not s then return end
  emit_at(s, screen_pos)
end

function M._supported(opts)
  opts = opts or {}
  if vim.env.TERM_PROGRAM == 'Apple_Terminal' then
    return false, 'Apple Terminal does not support sixel'
  end
  local term = vim.env.TERM or ''
  if term:find('sixel', 1, true) or KNOWN_SIXEL_TERMS[term] then
    return true, 'TERM=' .. term
  end
  -- DA1 probe (CSI c) — response includes ;4 if sixel supported.
  local done, ok, msg = false, false, nil
  util.query_csi('\027[c', { timeout = opts.timeout or 1000 }, function(resp)
    if resp and resp:find(';4', 1, true) then
      ok, msg = true, resp
    end
    done = true
  end)
  vim.wait((opts.timeout or 1000) + 100, function() return done end)
  return ok, msg
end

return M
