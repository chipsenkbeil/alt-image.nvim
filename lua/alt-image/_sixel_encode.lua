-- alt-image sixel encoder (pure transforms).
-- Ported from chipsenkbeil/neovim:feat/MoreImgProviders
--   runtime/lua/vim/ui/img/_sixel.lua
-- Splits the encoder out from the provider so tests can exercise it directly
-- and the provider in sixel.lua stays focused on state management.

local M = {}

local band = require('bit').band -- luacheck: ignore (kept for parity / future use)
local bor = require('bit').bor
local lshift = require('bit').lshift
local ffi = require('ffi')
local buffer = require('string.buffer')

-- Suppress unused-local warning for `band` if the linter complains.
_ = band

---Median cut color quantization.
---@param colors table list of {r,g,b,key=integer}
---@param max_colors integer
---@return number[][] palette
---@return table<integer, integer> key_to_palette (packed int -> palette index)
local function _median_cut(colors, max_colors)
  local boxes = { { colors = colors } }

  -- Split boxes until we have enough
  while #boxes < max_colors do
    -- Find box with largest range to split, caching split channel
    local best_idx = 1
    local best_range = -1
    local best_ch = 1

    for i, box in ipairs(boxes) do
      if #box.colors > 1 then
        local r_min, g_min, b_min = 255, 255, 255
        local r_max, g_max, b_max = 0, 0, 0
        for _, c in ipairs(box.colors) do
          if c[1] < r_min then r_min = c[1] end
          if c[1] > r_max then r_max = c[1] end
          if c[2] < g_min then g_min = c[2] end
          if c[2] > g_max then g_max = c[2] end
          if c[3] < b_min then b_min = c[3] end
          if c[3] > b_max then b_max = c[3] end
        end
        local r_range = r_max - r_min
        local g_range = g_max - g_min
        local b_range = b_max - b_min
        local max_range, ch
        if r_range >= g_range and r_range >= b_range then
          max_range, ch = r_range, 1
        elseif g_range >= b_range then
          max_range, ch = g_range, 2
        else
          max_range, ch = b_range, 3
        end
        if max_range > best_range then
          best_range = max_range
          best_idx = i
          best_ch = ch
        end
      end
    end

    if best_range <= 0 then
      break
    end

    local box = boxes[best_idx]

    -- Sort by the cached channel and split at median
    local split_ch = best_ch
    table.sort(box.colors, function(a, b)
      return a[split_ch] < b[split_ch]
    end)

    local mid = math.floor(#box.colors / 2)
    local box1 = {}
    local box2 = {}
    for i = 1, mid do
      box1[i] = box.colors[i]
    end
    for i = mid + 1, #box.colors do
      box2[i - mid] = box.colors[i]
    end

    boxes[best_idx] = { colors = box1 }
    boxes[#boxes + 1] = { colors = box2 }
  end

  -- Compute palette as average of each box
  local palette = {}
  local key_to_palette = {}
  for i, box in ipairs(boxes) do
    local r_sum, g_sum, b_sum = 0, 0, 0
    for _, c in ipairs(box.colors) do
      r_sum = r_sum + c[1]
      g_sum = g_sum + c[2]
      b_sum = b_sum + c[3]
    end
    local n = #box.colors
    palette[i] = {
      math.floor(r_sum / n + 0.5),
      math.floor(g_sum / n + 0.5),
      math.floor(b_sum / n + 0.5),
    }
    -- Map each color in the box to this palette index
    for _, c in ipairs(box.colors) do
      key_to_palette[c.key] = i
    end
  end

  return palette, key_to_palette
end

---Quantize packed pixel colors to a palette of at most 256 colors using median cut.
---@param pixel_colors ffi.cdata* int32_t array of packed r*65536+g*256+b values (-1 = transparent)
---@param n_pixels integer total number of pixels
---@return number[][] palette (list of {r,g,b})
---@return table<integer, integer> indexed (position -> 1-based palette index, 0 = transparent)
local function _quantize_packed(pixel_colors, n_pixels)
  -- Collect unique colors using integer keys
  local unique = {}
  local unique_count = 0
  local int_key_map = {} -- packed int -> index in unique

  for i = 0, n_pixels - 1 do
    local key = pixel_colors[i]
    if key >= 0 and not int_key_map[key] then
      unique_count = unique_count + 1
      local r = math.floor(key / 65536)
      local g = math.floor(key / 256) % 256
      local b = key % 256
      int_key_map[key] = unique_count
      unique[unique_count] = { r, g, b, key = key }
    end
  end

  local palette
  local key_to_palette = {} -- packed int -> 1-based palette index

  if unique_count <= 256 then
    -- Use all unique colors directly
    palette = {}
    for i, c in ipairs(unique) do
      palette[i] = { c[1], c[2], c[3] }
      key_to_palette[c.key] = i
    end
  else
    -- Median cut quantization
    palette, key_to_palette = _median_cut(unique, 256)
  end

  -- Build indexed pixel map
  local indexed = {}
  for i = 0, n_pixels - 1 do
    local key = pixel_colors[i]
    if key >= 0 then
      indexed[i] = key_to_palette[key] or 0
    else
      indexed[i] = 0
    end
  end

  return palette, indexed
end

---Convert RGBA pixel data into a packed int32_t pixel-color array
---(r*65536 + g*256 + b, or -1 for transparent).
---@param rgba string
---@param w integer
---@param h integer
---@return ffi.cdata* pixel_colors
---@return integer n_pixels
local function _pack_pixels(rgba, w, h)
  local src = ffi.cast('const uint8_t*', rgba)
  local n_pixels = w * h
  local pixel_colors = ffi.new('int32_t[?]', n_pixels)
  for i = 0, n_pixels - 1 do
    local off = i * 4
    if src[off + 3] >= 128 then
      pixel_colors[i] = src[off] * 65536 + src[off + 1] * 256 + src[off + 2]
    else
      pixel_colors[i] = -1
    end
  end
  return pixel_colors, n_pixels
end

---Nearest-neighbor resize of RGBA pixel data using FFI.
---@param rgba string RGBA pixel data (4 bytes per pixel)
---@param src_w integer source width
---@param src_h integer source height
---@param dst_w integer destination width
---@param dst_h integer destination height
---@return string rgba, integer width, integer height
local function _resize(rgba, src_w, src_h, dst_w, dst_h)
  local src = ffi.cast('const uint8_t*', rgba)
  local dst_size = dst_w * dst_h * 4
  local dst = ffi.new('uint8_t[?]', dst_size)

  -- Pre-compute source X offsets (byte offset into source row)
  local src_x_offsets = ffi.new('int32_t[?]', dst_w)
  for x = 0, dst_w - 1 do
    src_x_offsets[x] = math.floor(x * src_w / dst_w) * 4
  end

  local dst_idx = 0
  for y = 0, dst_h - 1 do
    local src_row = src + math.floor(y * src_h / dst_h) * src_w * 4
    for x = 0, dst_w - 1 do
      local sp = src_row + src_x_offsets[x]
      dst[dst_idx] = sp[0]
      dst[dst_idx + 1] = sp[1]
      dst[dst_idx + 2] = sp[2]
      dst[dst_idx + 3] = sp[3]
      dst_idx = dst_idx + 4
    end
  end

  return ffi.string(dst, dst_size), dst_w, dst_h
end

---Quantize RGBA pixel data to a palette of at most 256 colors using median cut.
---@param rgba string RGBA pixel data
---@param w integer width in pixels
---@param h integer height in pixels
---@return number[][] palette (list of {r,g,b})
---@return table<integer, integer> indexed (position -> 1-based palette index, 0 = transparent)
local function _quantize(rgba, w, h)
  local pixel_colors, n_pixels = _pack_pixels(rgba, w, h)
  return _quantize_packed(pixel_colors, n_pixels)
end

---Encode RGBA pixel data as a sixel DCS string.
---@param rgba string RGBA pixel data
---@param w integer width in pixels
---@param h integer height in pixels
---@return string sixel DCS sequence
local function _encode_sixel(rgba, w, h)
  local pixel_colors, n_pixels = _pack_pixels(rgba, w, h)

  -- Quantize to palette
  local palette, indexed = _quantize_packed(pixel_colors, n_pixels)

  -- Build sixel output using string.buffer
  local out = buffer.new()

  -- DCS introducer with raster attributes
  out:put(string.format('\027Pq"1;1;%d;%d', w, h))

  -- Color definitions
  for i, color in ipairs(palette) do
    local r_pct = math.floor(color[1] * 100 / 255 + 0.5)
    local g_pct = math.floor(color[2] * 100 / 255 + 0.5)
    local b_pct = math.floor(color[3] * 100 / 255 + 0.5)
    out:put(string.format('#%d;2;%d;%d;%d', i - 1, r_pct, g_pct, b_pct))
  end

  -- Encode sixel bands (6 rows each) - single pass per band
  local n_bands = math.ceil(h / 6)
  -- Reusable per-band structures
  local bitmasks_by_color = {} -- color_idx -> array of bitmasks per x
  local active_colors = {}
  local active_set = {}

  for band_y = 0, n_bands - 1 do
    local y_start = band_y * 6

    -- Clear active tracking
    for i = 1, #active_colors do
      local ci = active_colors[i]
      active_set[ci] = nil
      bitmasks_by_color[ci] = nil
    end
    active_colors[0] = 0 -- use [0] as length counter
    for i = 1, #active_colors do
      active_colors[i] = nil
    end

    -- Single pass: scan all pixels in this band, build bitmasks per color per x
    for bit_row = 0, 5 do
      local y = y_start + bit_row
      if y >= h then
        break
      end
      local row_base = y * w
      local bit_val = lshift(1, bit_row)
      for x = 0, w - 1 do
        local ci = indexed[row_base + x]
        if ci ~= 0 then
          local masks = bitmasks_by_color[ci]
          if not masks then
            -- First time seeing this color in this band
            masks = ffi.new('uint8_t[?]', w)
            bitmasks_by_color[ci] = masks
            if not active_set[ci] then
              active_set[ci] = true
              local len = active_colors[0] + 1
              active_colors[0] = len
              active_colors[len] = ci
            end
          end
          masks[x] = bor(masks[x], bit_val)
        end
      end
    end

    local n_active = active_colors[0]

    -- Sort active colors for deterministic output
    if n_active > 1 then
      table.sort(active_colors, function(a, b)
        if a == nil then
          return false
        end
        if b == nil then
          return true
        end
        return a < b
      end)
    end

    -- Emit RLE for each active color
    for ai = 1, n_active do
      local color_idx = active_colors[ai]
      local masks = bitmasks_by_color[color_idx]

      -- Color select
      out:put('#', tostring(color_idx - 1))

      -- Run-length encode directly to output buffer
      local prev_ch = masks[0] + 63
      local count = 1
      for x = 1, w - 1 do
        local ch = masks[x] + 63
        if ch == prev_ch then
          count = count + 1
        else
          if count >= 4 then
            out:put(string.format('!%d%s', count, string.char(prev_ch)))
          else
            local c = string.char(prev_ch)
            for _ = 1, count do
              out:put(c)
            end
          end
          prev_ch = ch
          count = 1
        end
      end
      -- Flush last run
      if count >= 4 then
        out:put(string.format('!%d%s', count, string.char(prev_ch)))
      else
        local c = string.char(prev_ch)
        for _ = 1, count do
          out:put(c)
        end
      end

      out:put('$') -- Carriage return (same band)
    end

    out:put('-') -- New line (next band)
  end

  -- DCS terminator
  out:put('\027\\')

  return out:get()
end

---Slice an RGBA pixel buffer to a sub-rectangle.
---@param rgba string raw RGBA bytes (4 bytes/pixel, row-major)
---@param full_w_px integer original width in pixels
---@param full_h_px integer original height in pixels
---@param x_px integer left offset (pixels) of the crop
---@param y_px integer top offset (pixels) of the crop
---@param w_px integer crop width (pixels)
---@param h_px integer crop height (pixels)
---@return string cropped_rgba, integer w_px, integer h_px
function M.crop_rgba(rgba, full_w_px, full_h_px, x_px, y_px, w_px, h_px)
  -- Clamp to source bounds defensively.
  if x_px < 0 then w_px = w_px + x_px; x_px = 0 end
  if y_px < 0 then h_px = h_px + y_px; y_px = 0 end
  if x_px + w_px > full_w_px then w_px = full_w_px - x_px end
  if y_px + h_px > full_h_px then h_px = full_h_px - y_px end
  if w_px <= 0 or h_px <= 0 then return '', 0, 0 end

  -- Use FFI for fast row copy.
  local stride = full_w_px * 4
  local out = ffi.new('uint8_t[?]', w_px * h_px * 4)
  local src = ffi.cast('const uint8_t*', rgba)
  for row = 0, h_px - 1 do
    ffi.copy(out + row * w_px * 4,
             src + (y_px + row) * stride + x_px * 4,
             w_px * 4)
  end
  return ffi.string(out, w_px * h_px * 4), w_px, h_px
end

M.resize       = _resize
M.quantize     = _quantize
M.encode_sixel = _encode_sixel

-- ---------------------------------------------------------------------------
-- Acceleration dispatchers
-- ---------------------------------------------------------------------------
--
-- These wrap the pure-Lua paths above with an optional external-tool fast
-- path. The tools take PNG input on stdin, so callers that already have raw
-- RGBA must pay a single PNG re-encode hop. For the (much more common) crop
-- case we expose a separate dispatcher that hands the *original* PNG bytes
-- straight to `convert -crop` and avoids the decode -> crop -> re-encode
-- round-trip entirely.
--
-- Dispatchers read `vim.g.alt_image.accelerate` directly at call-time so
-- toggles take effect without re-requiring, and there's no module cycle.

local _util = require('alt-image._util')

local function _accelerate_enabled()
  local g = vim.g.alt_image or {}
  if g.accelerate == nil then return true end
  return g.accelerate and true or false
end

---Run a subprocess synchronously and return stdout on success, nil on fail.
---@param cmd string[]
---@param stdin string
---@return string? stdout
local function _run(cmd, stdin)
  local ok, res = pcall(function()
    return vim.system(cmd, { stdin = stdin, text = false }):wait()
  end)
  if not ok or not res or res.code ~= 0 then
    -- Surface the subprocess error once per (tool, message) pair so the user
    -- can diagnose ImageMagick policy errors etc. without spamming.
    if res and res.stderr and #res.stderr > 0 then
      vim.schedule(function()
        vim.notify_once(
          ('alt-image: %s failed: %s'):format(cmd[1], res.stderr),
          vim.log.levels.DEBUG
        )
      end)
    end
    return nil
  end
  return res.stdout
end

---Encode an RGBA buffer to a sixel DCS string, accelerated if possible.
---Priority: img2sixel -> convert -> pure Lua.
---@param rgba string
---@param w_px integer
---@param h_px integer
---@return string sixel DCS
function M.encode_sixel_dispatch(rgba, w_px, h_px)
  if _accelerate_enabled() then
    -- Both tools want PNG on stdin; encode once and try each tool.
    local png_bytes
    if _util.have_img2sixel() or _util.have_convert() then
      local png_encode = require('alt-image._png_encode')
      png_bytes = png_encode.encode(rgba, w_px, h_px)
    end
    if _util.have_img2sixel() and png_bytes then
      local out = _run({ 'img2sixel' }, png_bytes)
      if out and #out > 0 then return out end
    end
    if _util.have_convert() and png_bytes then
      local out = _run(
        { 'convert', '-', '-define', 'sixel:colors=256', 'sixel:-' },
        png_bytes)
      if out and #out > 0 then return out end
    end
  end
  return _encode_sixel(rgba, w_px, h_px)
end

---Combined crop + sixel-encode using `convert` in a single call.
---Returns nil if accel is disabled, `convert` is missing, or the subprocess
---fails — caller must fall back to its existing decode -> crop -> encode path.
---@param png_bytes string original PNG bytes
---@param x_px integer crop x offset (px)
---@param y_px integer crop y offset (px)
---@param w_px integer crop width (px)
---@param h_px integer crop height (px)
---@return string? sixel
function M.crop_and_encode_sixel(png_bytes, x_px, y_px, w_px, h_px)
  if not _accelerate_enabled() then return nil end
  if not _util.have_convert() then return nil end
  local geom = string.format('%dx%d+%d+%d', w_px, h_px, x_px, y_px)
  return _run(
    { 'convert', '-', '-crop', geom, '-define', 'sixel:colors=256', 'sixel:-' },
    png_bytes)
end

---Combined crop + PNG re-encode using `convert`. Returns nil on failure so
---the caller can fall back to pure-Lua crop + `_png_encode.encode`.
---@param png_bytes string original PNG bytes
---@param x_px integer
---@param y_px integer
---@param w_px integer
---@param h_px integer
---@return string? png
function M.crop_and_encode_png(png_bytes, x_px, y_px, w_px, h_px)
  if not _accelerate_enabled() then return nil end
  if not _util.have_convert() then return nil end
  local geom = string.format('%dx%d+%d+%d', w_px, h_px, x_px, y_px)
  return _run({ 'convert', '-', '-crop', geom, 'png:-' }, png_bytes)
end

return M
