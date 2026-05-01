-- lua/alt-img/sixel/_encode.lua
-- Pure-Lua sixel encoder (median-cut quantizer + DCS emitter) plus a small
-- dispatcher that routes through external tools (`img2sixel`, `magick`) when
-- they're available. Lives in `sixel/` because none of this is reusable by
-- the iterm2 protocol — sixel-specific output format, sixel-specific cost
-- profile.
--
-- Ported from chipsenkbeil/neovim:feat/MoreImgProviders
--   runtime/lua/vim/ui/img/_sixel.lua
-- Splits the encoder out from the provider so tests can exercise it directly
-- and the provider in sixel.lua stays focused on state management.

local M = {}

local band = require("bit").band -- luacheck: ignore (kept for parity / future use)
local bor = require("bit").bor
local lshift = require("bit").lshift
local ffi = require("ffi")
local buffer = require("string.buffer")

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
                    if c[1] < r_min then
                        r_min = c[1]
                    end
                    if c[1] > r_max then
                        r_max = c[1]
                    end
                    if c[2] < g_min then
                        g_min = c[2]
                    end
                    if c[2] > g_max then
                        g_max = c[2]
                    end
                    if c[3] < b_min then
                        b_min = c[3]
                    end
                    if c[3] > b_max then
                        b_max = c[3]
                    end
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
    local src = ffi.cast("const uint8_t*", rgba)
    local n_pixels = w * h
    local pixel_colors = ffi.new("int32_t[?]", n_pixels)
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
        out:put(string.format("#%d;2;%d;%d;%d", i - 1, r_pct, g_pct, b_pct))
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
                        masks = ffi.new("uint8_t[?]", w)
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
            out:put("#", tostring(color_idx - 1))

            -- Run-length encode directly to output buffer
            local prev_ch = masks[0] + 63
            local count = 1
            for x = 1, w - 1 do
                local ch = masks[x] + 63
                if ch == prev_ch then
                    count = count + 1
                else
                    if count >= 4 then
                        out:put(string.format("!%d%s", count, string.char(prev_ch)))
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
                out:put(string.format("!%d%s", count, string.char(prev_ch)))
            else
                local c = string.char(prev_ch)
                for _ = 1, count do
                    out:put(c)
                end
            end

            out:put("$") -- Carriage return (same band)
        end

        out:put("-") -- New line (next band)
    end

    -- DCS terminator
    out:put("\027\\")

    return out:get()
end

M.quantize = _quantize
M.encode_sixel = _encode_sixel

-- ---------------------------------------------------------------------------
-- External-tool dispatchers
-- ---------------------------------------------------------------------------
--
-- These wrap the pure-Lua paths above with optional external-tool fast paths
-- via the `_magick` and `_libsixel` modules. The tools take PNG input on
-- stdin, so callers that already have raw RGBA must pay a single PNG
-- re-encode hop. For the (much more common) crop case the magick wrapper
-- accepts the *original* PNG bytes and runs `<bin> -crop` directly, skipping
-- the decode -> crop -> re-encode round-trip.
--
-- Each call resolves the binary at call-time via the wrapper's `binary()`
-- helpers, so toggling `vim.g.alt_img.{magick,img2sixel}` takes effect
-- without re-requiring this module.

---Encode an RGBA buffer to a sixel DCS string, using external tools when
---configured. Priority: img2sixel -> magick/convert -> pure Lua.
---@param rgba string
---@param w_px integer
---@param h_px integer
---@return string sixel DCS
function M.encode_sixel_dispatch(rgba, w_px, h_px)
    local magick = require("alt-img._core.magick")
    local libsixel = require("alt-img.sixel._libsixel")
    local png = require("alt-img._core.png")
    local has_libsixel = libsixel.binary() ~= nil
    local has_magick = magick.binary() ~= nil

    -- Without libz, png.encode emits uncompressed stored-block PNGs (~raw
    -- RGBA size). The PNG hop then dominates the pipeline. magick can read
    -- raw RGBA directly via `-size WxH -depth 8 RGBA:-`, so prefer that
    -- when we can. img2sixel doesn't have an equivalent raw-input mode.
    if has_magick and not png.has_libz() then
        local out = magick.encode_sixel_from_rgba(rgba, w_px, h_px)
        if out and #out > 0 then
            return out
        end
    end

    -- Both external tools want PNG on stdin; encode once and try each in turn.
    local png_bytes
    if has_libsixel or has_magick then
        png_bytes = png.encode(rgba, w_px, h_px)
    end
    if has_libsixel and png_bytes then
        local out = libsixel.encode_sixel(png_bytes)
        if out and #out > 0 then
            return out
        end
    end
    if has_magick and png_bytes then
        local out = magick.encode_sixel_from_png(png_bytes)
        if out and #out > 0 then
            return out
        end
    end
    return _encode_sixel(rgba, w_px, h_px)
end

return M
