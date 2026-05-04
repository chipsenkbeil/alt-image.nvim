local M = {}

local bit = require("bit")
local bor = bit.bor
local lshift = bit.lshift

---Median cut color quantization.
---@param colors table list of {r,g,b,key=integer}
---@param max_colors integer
---@return number[][] palette
---@return table<integer, integer> key_to_palette (packed int -> palette index)
local function _median_cut(colors, max_colors)
    local boxes = { { colors = colors } }

    -- Split boxes until we have enough
    while #boxes < max_colors do
        require("alt-img._core.async").maybe_yield({ phase = "quantize", done = #boxes, total = max_colors })
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
---@param pixel_colors integer[] 0-indexed array of packed r*65536+g*256+b values (-1 = transparent)
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

---Convert RGBA pixel data into a packed pixel-color Lua array
---(r*65536 + g*256 + b, or -1 for transparent). 0-indexed for parity with
---the rest of this module's pixel arithmetic.
---@param rgba string
---@param w integer
---@param h integer
---@return integer[] pixel_colors
---@return integer n_pixels
local function _pack_pixels(rgba, w, h)
    local n_pixels = w * h
    local pixel_colors = {}
    local sb = string.byte
    for i = 0, n_pixels - 1 do
        local off = i * 4 + 1
        local r, g, b, a = sb(rgba, off, off + 3)
        if a >= 128 then
            pixel_colors[i] = r * 65536 + g * 256 + b
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

---Append an RLE run for `mask_char` of length `count` to `out`.
---@param out string[]
---@param mask_char integer
---@param count integer
local function emit_run(out, mask_char, count)
    if count >= 4 then
        out[#out + 1] = string.format("!%d%s", count, string.char(mask_char))
    else
        local c = string.char(mask_char)
        for _ = 1, count do
            out[#out + 1] = c
        end
    end
end

---Encode RGBA pixel data as a sixel DCS string. Pure Lua: no LuaJIT FFI,
---no string.buffer. Hot path callers should prefer the magick / img2sixel
---dispatchers in `encode_sixel_dispatch`; this is the deep fallback.
---@param rgba string RGBA pixel data
---@param w integer width in pixels
---@param h integer height in pixels
---@return string sixel DCS sequence
local function _encode_sixel(rgba, w, h)
    local pixel_colors, n_pixels = _pack_pixels(rgba, w, h)
    local palette, indexed = _quantize_packed(pixel_colors, n_pixels)

    local out = {}
    -- P2=1 leaves 0-bit pixels untouched, so transparent regions show
    -- the terminal background. Default (P2=0) lets some terminals (Windows
    -- Terminal) fill them with palette `#0`, which varies per-crop because
    -- it's whichever opaque color `_pack_pixels` happens to scan first.
    out[#out + 1] = string.format('\027P0;1;0q"1;1;%d;%d', w, h)

    for i, color in ipairs(palette) do
        local r_pct = math.floor(color[1] * 100 / 255 + 0.5)
        local g_pct = math.floor(color[2] * 100 / 255 + 0.5)
        local b_pct = math.floor(color[3] * 100 / 255 + 0.5)
        out[#out + 1] = string.format("#%d;2;%d;%d;%d", i - 1, r_pct, g_pct, b_pct)
    end

    local n_bands = math.ceil(h / 6)
    -- Per-band scratch reused via clear-on-entry. `active_colors` keeps its
    -- fill count in slot [0]; the rest of the array carries 1..count.
    local bitmasks_by_color = {}
    local active_colors = { [0] = 0 }
    local active_set = {}

    for band_y = 0, n_bands - 1 do
        require("alt-img._core.async").maybe_yield({ phase = "encode", done = band_y, total = n_bands })
        local y_start = band_y * 6

        for i = 1, active_colors[0] do
            local ci = active_colors[i]
            active_set[ci] = nil
            bitmasks_by_color[ci] = nil
            active_colors[i] = nil
        end
        active_colors[0] = 0

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
                        masks = {}
                        for mx = 0, w - 1 do
                            masks[mx] = 0
                        end
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

        if n_active > 1 then
            -- Restrict the sort to the populated 1..n_active range so trailing
            -- nils from prior bands don't confuse the comparator.
            local sortable = {}
            for i = 1, n_active do
                sortable[i] = active_colors[i]
            end
            table.sort(sortable)
            for i = 1, n_active do
                active_colors[i] = sortable[i]
            end
        end

        for ai = 1, n_active do
            local color_idx = active_colors[ai]
            local masks = bitmasks_by_color[color_idx]

            out[#out + 1] = "#" .. tostring(color_idx - 1)

            local prev_ch = masks[0] + 63
            local count = 1
            for x = 1, w - 1 do
                local ch = masks[x] + 63
                if ch == prev_ch then
                    count = count + 1
                else
                    emit_run(out, prev_ch, count)
                    prev_ch = ch
                    count = 1
                end
            end
            emit_run(out, prev_ch, count)

            out[#out + 1] = "$"
        end

        out[#out + 1] = "-"
    end

    out[#out + 1] = "\027\\"
    return table.concat(out)
end

---Encode an RGBA buffer to a sixel DCS string. Priority chain:
---chafa → img2sixel (libsixel) → magick/convert → pure-Lua `_encode_sixel`.
---chafa is preferred because it's the only external encoder that preserves
---PNG alpha (P2=1, no bits at transparent positions); the others flatten
---alpha against a background color (default black). The pure-Lua tail also
---preserves alpha. External tools all want PNG on stdin, so RGBA input pays
---one png.encode hop unless we fall through to the magick raw-RGBA fast
---path (only worth taking when chafa and libsixel are both unavailable).
---@param rgba string
---@param w_px integer
---@param h_px integer
---@return string sixel DCS
function M.encode_sixel_dispatch(rgba, w_px, h_px)
    local png = require("alt-img._core.png")
    local chafa = require("alt-img.sixel._chafa")
    local libsixel = require("alt-img.sixel._libsixel")
    local magick = require("alt-img._core.magick")

    local has_chafa = chafa.binary() ~= nil
    local has_libsixel = libsixel.binary() ~= nil
    local has_magick = magick.binary() ~= nil

    -- Magick raw-RGBA fast path: when libz is missing png.encode emits stored
    -- (uncompressed) blocks, so the PNG hop dominates. Only worth taking when
    -- magick is the only subprocess tool we'd reach — chafa/libsixel both
    -- need PNG anyway, so once we've paid png.encode they're cheaper to chain.
    if has_magick and not has_chafa and not has_libsixel and not png.has_libz() then
        local out = magick.encode_sixel_from_rgba(rgba, w_px, h_px)
        if out and #out > 0 then
            return out
        end
    end

    local png_bytes
    if has_chafa or has_libsixel or has_magick then
        png_bytes = png.encode(rgba, w_px, h_px)
    end
    if has_chafa and png_bytes then
        local out = chafa.encode_sixel(png_bytes)
        if out and #out > 0 then
            return out
        end
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
