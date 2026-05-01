-- Generic RGBA pixel-buffer helpers shared by both providers' resize / crop
-- pipelines. Lifted out of the sixel encoder module so iterm2 doesn't pull
-- the entire sixel quantizer into its dependency graph for these helpers.
--   * resize    — nearest-neighbor scale, used pre-encode to map source pixels
--                 onto a 1:1 cell-pixel grid (sharp output, no terminal scaling)
--   * crop_rgba — sub-rectangle slice, used by the partial-visibility pipeline
--                 before re-encoding to PNG (iterm2) or sixel DCS (sixel).

local M = {}

local ffi = require("ffi")

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

	-- Use FFI for fast row copy.
	local stride = full_w_px * 4
	local out = ffi.new("uint8_t[?]", w_px * h_px * 4)
	local src = ffi.cast("const uint8_t*", rgba)
	for row = 0, h_px - 1 do
		ffi.copy(out + row * w_px * 4, src + (y_px + row) * stride + x_px * 4, w_px * 4)
	end
	return ffi.string(out, w_px * h_px * 4), w_px, h_px
end

---Nearest-neighbor resize of an RGBA pixel buffer.
---@param rgba string raw RGBA bytes (4 bytes/pixel, row-major)
---@param src_w integer source width (pixels)
---@param src_h integer source height (pixels)
---@param dst_w integer destination width (pixels)
---@param dst_h integer destination height (pixels)
---@return string rgba, integer width, integer height
function M.resize(rgba, src_w, src_h, dst_w, dst_h)
	local src = ffi.cast("const uint8_t*", rgba)
	local dst_size = dst_w * dst_h * 4
	local dst = ffi.new("uint8_t[?]", dst_size)

	-- Pre-compute source X offsets (byte offset into source row)
	local src_x_offsets = ffi.new("int32_t[?]", dst_w)
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

return M
