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
local render  = require('alt-image._render')

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

-- Public so _render can call us. Reads state[id], emits sixel DCS at screen_pos.
function M._emit_at(id, screen_pos)
  local s = state[id]
  if not s then return end
  local sixel = build_sixel(s)
  local opts = s.opts
  local cmove = string.format('\027[%d;%dH',
                              screen_pos and screen_pos.row or (opts.row or 1),
                              screen_pos and screen_pos.col or (opts.col or 1))
  util.term_send(SYNC_START
    .. '\0277' .. '\027[?25l' .. cmove .. sixel
    .. '\0278' .. '\027[?25h' .. SYNC_END)
end

-- Closure factory: produces a position resolver for placement `id` that the
-- render coordinator can call without knowing about provider internals.
local function get_pos_for(id)
  return function()
    local s = state[id]
    if not s then return nil end
    if s.opts.relative == 'ui' then
      return { row = s.opts.row or 1, col = s.opts.col or 1 }
    end
    return require('alt-image._carrier').get_pos(M, id)
  end
end

function M.set(data_or_id, opts)
  vim.validate({
    data_or_id = { data_or_id, { 'string', 'number' } },
    opts       = { opts, 'table', true },
  })

  if type(data_or_id) == 'number' then
    -- Update path
    local s = state[data_or_id]
    if not s then error('alt-image.sixel: unknown id ' .. tostring(data_or_id), 2) end
    s.opts = vim.tbl_extend('force', s.opts, canonicalize(opts))
    s.sixel_cache = nil  -- opts changed -> may need re-encode if size changed
    render.rerender_all()
    return data_or_id
  end

  -- New placement path
  local id = new_id()
  state[id] = { data = data_or_id, opts = canonicalize(opts), id = id }

  if state[id].opts.relative ~= 'ui' then
    require('alt-image._carrier').register(M, id, state[id].opts)
  end

  render.register(M, id, get_pos_for(id))
  render.refresh()
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
    for k, _ in pairs(state) do
      require('alt-image._carrier').unregister(M, k)
      render.unregister(M, k)
    end
    state = {}
    if any then render.rerender_all() end
    return any
  end
  if not state[id] then return false end
  require('alt-image._carrier').unregister(M, id)
  render.unregister(M, id)
  state[id] = nil
  render.rerender_all()
  return true
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
