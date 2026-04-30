-- lua/alt-image/iterm2.lua
-- iTerm2 OSC 1337 image protocol provider, drop-in for vim.ui.img.
-- Ported from chipsenkbeil/neovim:feat/MoreImgProviders
--   runtime/lua/vim/ui/img/_iterm2.lua

local util       = require('alt-image._util')
local render     = require('alt-image._render')
local png        = require('alt-image._png')
local senc       = require('alt-image._sixel_encode')   -- for crop_rgba helper
local png_encode = require('alt-image._png_encode')

local M = {}

local FAST_TERM_PROGRAMS = {
  ['iTerm.app'] = true,
  ['WezTerm']   = true,
}

-- Per-id placement state.
-- state[id] = { data = bytes, opts = canonical_opts, id = id,
--               decoded_rgba = string|nil, decoded_w = int|nil, decoded_h = int|nil,
--               png_cache_by_src = { [key]=string },
--               png_cache_by_src_order = { key, ... } }
local state = {}
local next_id = 1

local function new_id()
  local id = next_id
  next_id = next_id + 1
  return id
end

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
---@param data string raw image bytes (may not be PNG; we no-op if not)
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

---Decode the source PNG to RGBA once and cache on the placement state.
---Unlike sixel, we don't resize: iTerm2's protocol scales via the width=N/
---height=M cell args itself. We only need the original RGBA for cropping.
---@param s table placement state
---@return string rgba, integer w, integer h
local function ensure_decoded(s)
  if s.decoded_rgba then return s.decoded_rgba, s.decoded_w, s.decoded_h end
  local img = png.decode(s.data)
  s.decoded_rgba, s.decoded_w, s.decoded_h = img.pixels, img.width, img.height
  return s.decoded_rgba, s.decoded_w, s.decoded_h
end

---Crop the source image to a sub-rectangle and re-encode as PNG.
---@param s table placement state
---@param src table { x, y, w, h } in cell units
---@return string png_bytes, integer cw_px, integer ch_px
local function build_png_cropped(s, src)
  util.query_cell_size()
  local rgba, w, h = ensure_decoded(s)
  local cw, ch = util.cell_pixel_size()
  -- Map cell-unit src -> pixel-unit crop. The image's pixel dimensions are the
  -- decoded dims; we approximate "the image as it would render at opts.width
  -- x opts.height cells" by mapping a fraction of the source. This mirrors
  -- the sixel path's intent: crop in image-cell space.
  local opts = s.opts
  local full_w_cells = opts.width  or math.ceil(w / cw)
  local full_h_cells = opts.height or math.ceil(h / ch)
  -- Convert cell coords in target render to source pixel coords.
  local px_per_cell_x = w / full_w_cells
  local px_per_cell_y = h / full_h_cells
  local x_px = math.floor(src.x * px_per_cell_x + 0.5)
  local y_px = math.floor(src.y * px_per_cell_y + 0.5)
  local w_px = math.floor(src.w * px_per_cell_x + 0.5)
  local h_px = math.floor(src.h * px_per_cell_y + 0.5)
  if w_px < 1 then w_px = 1 end
  if h_px < 1 then h_px = 1 end
  -- Fast path: if convert is available and accel is on, do crop + PNG
  -- re-encode in a single subprocess call. Falls back to pure Lua on nil.
  if util.is_png_data(s.data) then
    local accel = senc.crop_and_encode_png(s.data, x_px, y_px, w_px, h_px)
    if accel and #accel > 0 then
      -- Returned PNG dims may differ slightly due to clamping in convert;
      -- the caller only cares about the resulting cell counts (src.w/h).
      return accel, w_px, h_px
    end
  end
  local cropped, cw_px, ch_px = senc.crop_rgba(rgba, w, h, x_px, y_px, w_px, h_px)
  return png_encode.encode(cropped, cw_px, ch_px), cw_px, ch_px
end

local CROP_CACHE_MAX = 16

local function crop_cache_get(s, key)
  s.png_cache_by_src = s.png_cache_by_src or {}
  s.png_cache_by_src_order = s.png_cache_by_src_order or {}
  local v = s.png_cache_by_src[key]
  if v then
    -- Move key to end (most recently used).
    for i, k in ipairs(s.png_cache_by_src_order) do
      if k == key then table.remove(s.png_cache_by_src_order, i); break end
    end
    table.insert(s.png_cache_by_src_order, key)
  end
  return v
end

local function crop_cache_put(s, key, value)
  s.png_cache_by_src = s.png_cache_by_src or {}
  s.png_cache_by_src_order = s.png_cache_by_src_order or {}
  s.png_cache_by_src[key] = value
  table.insert(s.png_cache_by_src_order, key)
  while #s.png_cache_by_src_order > CROP_CACHE_MAX do
    local evict = table.remove(s.png_cache_by_src_order, 1)
    s.png_cache_by_src[evict] = nil
  end
end

-- Public so _render can call us. Reads state[id], emits OSC 1337 at screen_pos.
function M._emit_at(id, screen_pos)
  local s = state[id]
  if not s then return end
  local opts = s.opts
  local src = screen_pos and screen_pos.src
  -- is_full: route to the original-PNG fast path. Guard against nil dims so
  -- the equality check is well-defined; if dims are missing (e.g. ui mode
  -- without explicit dims) we treat the placement as full to avoid crashing
  -- in build_png_cropped on `nil * px_per_cell`.
  local is_full = (not src)
                  or (not opts.width) or (not opts.height)
                  or (src.x == 0 and src.y == 0
                      and src.w == opts.width and src.h == opts.height)
  local data, width_cells, height_cells
  if is_full then
    data = s.data
    width_cells, height_cells = opts.width, opts.height
  else
    local key = string.format('%d,%d,%d,%d', src.x, src.y, src.w, src.h)
    local cached = crop_cache_get(s, key)
    if not cached then
      cached = build_png_cropped(s, src)
      crop_cache_put(s, key, cached)
    end
    data = cached
    width_cells, height_cells = src.w, src.h
  end

  local b64 = vim.base64.encode(data)
  local args = {
    'size=' .. #data,
    'inline=1',
    'preserveAspectRatio=' .. ((width_cells and height_cells) and 0 or 1),
  }
  if width_cells  then args[#args + 1] = 'width='  .. width_cells  end
  if height_cells then args[#args + 1] = 'height=' .. height_cells end

  local cs = {
    save    = '\0277',
    hide    = '\027[?25l',
    move    = string.format('\027[%d;%dH',
                            screen_pos and screen_pos.row or (opts.row or 1),
                            screen_pos and screen_pos.col or (opts.col or 1)),
    restore = '\0278',
    show    = '\027[?25h',
  }

  local osc = '\027]1337;File=' .. table.concat(args, ';') .. ':' .. b64 .. '\007'
  util.term_send(cs.save .. cs.hide .. cs.move
    .. osc .. cs.restore .. cs.show)
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
      return { {
        row = s.opts.row or 1,
        col = s.opts.col or 1,
        src = { x = 0, y = 0, w = s.opts.width or 1, h = s.opts.height or 1 },
      } }
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
    if not s then error('alt-image.iterm2: unknown id ' .. tostring(data_or_id), 2) end
    -- v1: don't support relative-changing updates (carrier kind would need
    -- to be re-created). Preserve the original relative on partial-merge so
    -- canonicalize's default of 'ui' doesn't clobber 'editor'/'buffer'.
    local upd = canonicalize(opts)
    if not (opts and opts.relative) then upd.relative = s.opts.relative end
    -- Explicit guard: if caller tries to change relative, error out.
    if opts and opts.relative and opts.relative ~= s.opts.relative then
      error(string.format(
        'alt-image.iterm2: cannot change relative on update (was %s, got %s); del and re-create instead',
        s.opts.relative, opts.relative), 2)
    end
    s.opts = vim.tbl_extend('force', s.opts, upd)
    -- opts changed -> any cached crop may be stale; drop the LRU and decoded
    -- buffer (the latter only matters if data ever changed, but cheap to drop).
    s.png_cache_by_src = nil
    s.png_cache_by_src_order = nil
    s.decoded_rgba = nil
    s.decoded_w = nil
    s.decoded_h = nil
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
                png_cache_by_src = {}, png_cache_by_src_order = {} }

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
  local tp = vim.env.TERM_PROGRAM
  if tp and FAST_TERM_PROGRAMS[tp] then
    return true, 'TERM_PROGRAM=' .. tp
  end

  -- Probe via XTVERSION (CSI > q). When vim.tty is absent on stable Neovim,
  -- we skip the probe entirely and fall through to a `false` return.
  local timeout = opts.timeout or 1000
  local done, ok, msg = false, false, nil
  if vim.tty and vim.tty.query_csi then
    vim.tty.query_csi('\027[>q', { timeout = timeout }, function(resp)
      if resp and (resp:find('iTerm2', 1, true)
                or resp:find('WezTerm', 1, true)) then
        ok, msg = true, resp
      end
      done = true
    end)
    vim.wait(timeout + 100, function() return done end)
  end
  return ok, msg
end

return M
