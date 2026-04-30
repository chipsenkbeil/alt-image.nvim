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
local lru     = require('alt-image._lru')

local M = {}

local KNOWN_SIXEL_TERMS = {
  foot = true, mlterm = true, contour = true,
}
local SUPPORTING_TERM_PROGRAMS = {
  ['iTerm.app'] = true,  -- iTerm2 v3.5+ supports sixel
  ['WezTerm']   = true,
}

-- state[id] = { data = bytes, opts = canonical_opts, sixel_cache = string|nil,
--               sixel_cache_by_src = { [key]=string }, id = id }
local state = {}
local next_id = 1

local function new_id() local id = next_id; next_id = next_id + 1; return id end

local function canonicalize(opts)
  opts = opts or {}
  -- relative defaults: if opts.buf is set, default to 'buffer'; else 'ui'.
  local rel = opts.relative or (opts.buf ~= nil and 'buffer' or 'ui')
  if rel ~= 'ui' and rel ~= 'editor' and rel ~= 'buffer' then
    error('alt-image: invalid relative ' .. tostring(rel)
       .. " (expected 'ui', 'editor', or 'buffer')", 3)
  end
  -- buf == 0 means current buffer.
  local buf = opts.buf
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  return {
    row      = opts.row,
    col      = opts.col,
    width    = opts.width,
    height   = opts.height,
    zindex   = opts.zindex,
    relative = rel,
    buf      = buf,
    pad      = opts.pad,
  }
end

---For non-ui modes, derive width/height from PNG IHDR if not provided.
---Mutates opts in-place.
---@param data string raw image bytes
---@param opts table canonical opts
local function derive_dims(data, opts)
  if opts.relative == 'ui' or (opts.width and opts.height) then return end
  if type(data) ~= 'string' then return end
  local px_w, px_h = util.png_dimensions(data)
  if not px_w then return end
  util.query_cell_size()
  local cell_w, cell_h = util.cell_pixel_size()
  opts.width  = opts.width  or math.ceil(px_w / cell_w)
  opts.height = opts.height or math.ceil(px_h / cell_h)
end

local function ensure_resized(s)
  if s.resized_rgba then return s.resized_rgba, s.resized_w, s.resized_h end
  local img = png.decode(s.data)
  local rgba, w, h = img.pixels, img.width, img.height
  local cw, ch = util.cell_pixel_size()
  if s.opts.width or s.opts.height then
    local target_w = (s.opts.width  or math.ceil(w / cw)) * cw
    local target_h = (s.opts.height or math.ceil(h / ch)) * ch
    rgba, w, h = senc.resize(rgba, w, h, target_w, target_h)
  end
  s.resized_rgba, s.resized_w, s.resized_h = rgba, w, h
  return rgba, w, h
end

local function build_sixel(s)
  if s.sixel_cache then return s.sixel_cache end
  util.query_cell_size()
  local rgba, w, h = ensure_resized(s)
  s.sixel_cache = senc.encode_sixel_dispatch(rgba, w, h)
  return s.sixel_cache
end

-- Build a sixel DCS for a sub-rectangle of the source image. The src record
-- describes the crop in image cells; we use the cached resized buffer, slice
-- out the requested sub-rectangle, and encode. When `convert` is available
-- and the placement has not been resized, we feed the original PNG straight
-- to `convert -crop` and skip the decode/crop/re-encode round-trip.
local function build_sixel_cropped(s, src)
  util.query_cell_size()
  local cw, ch = util.cell_pixel_size()
  local x_px = src.x * cw
  local y_px = src.y * ch
  local w_px = src.w * cw
  local h_px = src.h * ch

  -- Fast path: if no resize was requested, feed the original PNG to convert.
  -- We can detect "no resize" by comparing the resized dims to the PNG's
  -- IHDR dims. ensure_resized only resizes when opts.width/height is set
  -- *and* would change the image dims; otherwise it returns the decoded buf.
  local can_use_png_fast_path = type(s.data) == 'string'
                                and util.is_png_data(s.data)
                                and not s.opts.width
                                and not s.opts.height
  if can_use_png_fast_path then
    local accel = senc.crop_and_encode_sixel(s.data, x_px, y_px, w_px, h_px)
    if accel and #accel > 0 then return accel end
  end

  local rgba, w, h = ensure_resized(s)
  local cropped, cw_px, ch_px = senc.crop_rgba(rgba, w, h, x_px, y_px, w_px, h_px)
  return senc.encode_sixel_dispatch(cropped, cw_px, ch_px)
end

local function crop_cache_get(s, key)
  s.sixel_cache_by_src = s.sixel_cache_by_src or {}
  s.sixel_cache_by_src_order = s.sixel_cache_by_src_order or {}
  return lru.get(s.sixel_cache_by_src, s.sixel_cache_by_src_order, key)
end

local function crop_cache_put(s, key, value)
  s.sixel_cache_by_src = s.sixel_cache_by_src or {}
  s.sixel_cache_by_src_order = s.sixel_cache_by_src_order or {}
  lru.put(s.sixel_cache_by_src, s.sixel_cache_by_src_order, key, value)
end

-- Public so _render can call us. Reads state[id], emits sixel DCS at screen_pos.
function M._emit_at(id, screen_pos)
  local s = state[id]
  if not s then return end
  local opts = s.opts
  local src = screen_pos and screen_pos.src
  -- is_full: route to the cached full-image fast path. Guard against nil dims
  -- so the equality check is well-defined; if dims are missing (e.g. ui mode
  -- without explicit dims) we treat the placement as full to avoid crashing
  -- in build_sixel_cropped on `nil * cw`.
  local is_full = (not src)
                  or (not opts.width) or (not opts.height)
                  or (src.x == 0 and src.y == 0
                      and src.w == opts.width and src.h == opts.height)
  local sixel
  if is_full then
    sixel = build_sixel(s)
  else
    local key = string.format('%d,%d,%d,%d', src.x, src.y, src.w, src.h)
    local cached = crop_cache_get(s, key)
    if not cached then
      cached = build_sixel_cropped(s, src)
      crop_cache_put(s, key, cached)
    end
    sixel = cached
  end
  local cmove = string.format('\027[%d;%dH',
                              screen_pos and screen_pos.row or (opts.row or 1),
                              screen_pos and screen_pos.col or (opts.col or 1))
  util.term_send('\0277' .. '\027[?25l' .. cmove .. sixel
    .. '\0278' .. '\027[?25h')
end

-- Closure factory: produces a position resolver for placement `id` that the
-- render coordinator can call without knowing about provider internals.
-- Returns a list of position records `{ row, col, src = { x, y, w, h } }`,
-- possibly empty. For ui-mode, a single full-image src is emitted. For
-- editor/buffer modes, the carrier may shrink src to clip against window
-- bounds, and split into multiple entries (one per visible window).
local function get_pos_for(id)
  return function()
    local s = state[id]
    if not s then return {} end
    if s.opts.relative == 'ui' then
      local p = util.clip_to_bounds(
        s.opts.row or 1, s.opts.col or 1,
        s.opts.width or 1, s.opts.height or 1,
        1, 1, vim.o.lines, vim.o.columns
      )
      return p and { p } or {}
    end
    return require('alt-image._carrier').get_positions(M, id) or {}
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
    -- v1: don't support relative-changing updates. Preserve original relative
    -- on partial-merge so canonicalize's default of 'ui' doesn't clobber it.
    local upd = canonicalize(opts)
    if not (opts and opts.relative) then upd.relative = s.opts.relative end
    -- Explicit guard: if caller tries to change relative, error out.
    if opts and opts.relative and opts.relative ~= s.opts.relative then
      error(string.format(
        'alt-image.sixel: cannot change relative on update (was %s, got %s); del and re-create instead',
        s.opts.relative, opts.relative), 2)
    end
    s.opts = vim.tbl_extend('force', s.opts, upd)
    s.sixel_cache = nil  -- opts changed -> may need re-encode if size changed
    s.sixel_cache_by_src = nil  -- crop cache also stale on opts change
    s.sixel_cache_by_src_order = nil
    s.resized_rgba = nil  -- width/height change invalidates cached resize
    s.resized_w = nil
    s.resized_h = nil
    -- If merge resulted in non-ui without explicit dims, derive from PNG IHDR.
    derive_dims(s.data, s.opts)
    -- For carrier-managed placements, reposition the carrier so the resolved
    -- screen pos reflects the new opts (otherwise the float stays put).
    if s.opts.relative ~= 'ui' then
      require('alt-image._carrier').update(M, data_or_id, s.opts)
    end
    -- Mark dirty; the position-diff in tick() drives clearing automatically.
    render.invalidate(M, data_or_id)
    render.flush()
    return data_or_id
  end

  -- New placement path
  local id = new_id()
  local opts_canonical = canonicalize(opts)
  -- If non-ui and dims missing, derive from the PNG IHDR.
  derive_dims(data_or_id, opts_canonical)
  state[id] = { data = data_or_id, opts = opts_canonical, id = id,
                sixel_cache_by_src = {} }

  if state[id].opts.relative ~= 'ui' then
    require('alt-image._carrier').register(M, id, state[id].opts)
  end

  render.register(M, id, get_pos_for(id))
  -- Synchronous initial paint so callers (and tests) see the image immediately.
  render.flush()
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
    if any then render.flush() end
    return any
  end
  if not state[id] then return false end
  require('alt-image._carrier').unregister(M, id)
  render.unregister(M, id)
  state[id] = nil
  render.flush()
  return true
end

function M._supported(opts)
  opts = opts or {}
  if vim.env.TERM_PROGRAM == 'Apple_Terminal' then
    return false, 'Apple Terminal does not support sixel'
  end
  if vim.env.WT_SESSION then
    return true, 'WT_SESSION (Windows Terminal)'
  end
  local tp = vim.env.TERM_PROGRAM
  if tp and SUPPORTING_TERM_PROGRAMS[tp] then
    return true, 'TERM_PROGRAM=' .. tp
  end
  local term = vim.env.TERM or ''
  if term:find('sixel', 1, true) or KNOWN_SIXEL_TERMS[term] then
    return true, 'TERM=' .. term
  end
  -- DA1 probe (CSI c) — response includes ;4 if sixel supported. When
  -- vim.tty is absent on stable Neovim, we skip the probe entirely.
  local timeout = opts.timeout or 1000
  local done, ok, msg = false, false, nil
  if vim.tty and vim.tty.query_csi then
    vim.tty.query_csi('\027[c', { timeout = timeout }, function(resp)
      if resp and resp:find(';4', 1, true) then
        ok, msg = true, resp
      end
      done = true
    end)
    vim.wait(timeout + 100, function() return done end)
  end
  return ok, msg
end

return M
