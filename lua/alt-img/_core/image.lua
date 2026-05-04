local M = {}

---Slice an RGBA pixel buffer to a sub-rectangle. Pure-Lua: each output row
---is one `string.sub`; rows join with `table.concat`. The crop sizes alt-img
---hits (cell-pixel rectangles, typically a few KB) keep this well under
---per-frame budgets even without FFI.
---@param rgba string raw RGBA bytes (4 bytes/pixel, row-major)
---@param full_w_px integer original width in pixels
---@param full_h_px integer original height in pixels
---@param x_px integer left offset (pixels) of the crop
---@param y_px integer top offset (pixels) of the crop
---@param w_px integer crop width (pixels)
---@param h_px integer crop height (pixels)
---@return string cropped_rgba, integer w_px, integer h_px
function M.crop_rgba(rgba, full_w_px, full_h_px, x_px, y_px, w_px, h_px)
    if x_px < 0 then
        w_px = w_px + x_px
        x_px = 0
    end
    if y_px < 0 then
        h_px = h_px + y_px
        y_px = 0
    end
    if x_px + w_px > full_w_px then
        w_px = full_w_px - x_px
    end
    if y_px + h_px > full_h_px then
        h_px = full_h_px - y_px
    end
    if w_px <= 0 or h_px <= 0 then
        return "", 0, 0
    end

    local stride = full_w_px * 4
    local rows = {}
    for row = 0, h_px - 1 do
        local off = (y_px + row) * stride + x_px * 4
        rows[#rows + 1] = rgba:sub(off + 1, off + w_px * 4)
    end
    return table.concat(rows), w_px, h_px
end

---Nearest-neighbor resize of an RGBA pixel buffer. Pure-Lua: precompute
---per-x source byte offsets, then build each dest row by collecting
---per-pixel slices into a table and concatenating. Slower than the FFI
---path, but only the deep fallback (no magick) hits this; magick's
---`-sample` does the same nearest-neighbor mapping in one subprocess.
---@param rgba string raw RGBA bytes (4 bytes/pixel, row-major)
---@param src_w integer source width (pixels)
---@param src_h integer source height (pixels)
---@param dst_w integer destination width (pixels)
---@param dst_h integer destination height (pixels)
---@return string rgba, integer width, integer height
function M.resize(rgba, src_w, src_h, dst_w, dst_h)
    local src_x_offsets = {}
    for x = 0, dst_w - 1 do
        src_x_offsets[x + 1] = math.floor(x * src_w / dst_w) * 4
    end

    local src_stride = src_w * 4
    local rows = {}
    local pixel_slots = {}
    for y = 0, dst_h - 1 do
        local src_row_off = math.floor(y * src_h / dst_h) * src_stride
        for x = 1, dst_w do
            local off = src_row_off + src_x_offsets[x]
            pixel_slots[x] = rgba:sub(off + 1, off + 4)
        end
        rows[#rows + 1] = table.concat(pixel_slots)
    end
    return table.concat(rows), dst_w, dst_h
end

return M
