local M = {}

---Return the resolved binary name to invoke, or nil if disabled / not found.
---@return string?
function M.binary()
    local config = require("alt-img._core.config")
    return require("alt-img._core.binary").resolve(config.read().magick)
end

local function run(cmd, stdin)
    return require("alt-img._core.subprocess").run(cmd, stdin)
end

local function run_async(cmd, stdin, on_done)
    require("alt-img._core.subprocess").run_async(cmd, stdin, on_done)
end

---Strip magick's `ESC P 0;0;0 q` DCS params down to `ESC P q` (img2sixel's
---shape). magick's P1=0 selects 2:1 pixel-aspect under the VT3xx convention,
---which iTerm2's decoder honors and the encoded raster attribute does not
---override — terminals end up scaling the image vertically. Removing the
---params makes them fall back to the raster attribute and render at the
---requested square-pixel size.
---@param sixel string?
---@return string?
local function normalize_sixel_introducer(sixel)
    if not sixel or #sixel == 0 then
        return sixel
    end
    return (sixel:gsub("^\027P[%d;]+q", "\027Pq", 1))
end

---Crop a PNG sub-rectangle and re-emit as PNG. Returns nil on failure.
---@param png_bytes string original PNG bytes
---@param x_px integer
---@param y_px integer
---@param w_px integer
---@param h_px integer
---@return string?
function M.crop_to_png(png_bytes, x_px, y_px, w_px, h_px)
    local bin = M.binary()
    if not bin then
        return nil
    end
    local geom = string.format("%dx%d+%d+%d", w_px, h_px, x_px, y_px)
    return run({ bin, "-", "-crop", geom, "png:-" }, png_bytes)
end

---Encode an existing PNG byte string as a sixel DCS string. Returns nil on
---failure.
---@param png_bytes string
---@param colors integer? max palette size (default 256)
---@return string?
function M.encode_sixel_from_png(png_bytes, colors)
    local bin = M.binary()
    if not bin then
        return nil
    end
    local def = "sixel:colors=" .. tostring(colors or 256)
    return normalize_sixel_introducer(run({ bin, "-", "-define", def, "sixel:-" }, png_bytes))
end

---Encode a raw RGBA pixel buffer as a sixel DCS string. Returns nil on failure.
---Skips the PNG encode/decode hop — the PNG path is dominated by encoder cost
---when libz is unavailable (the encoder falls back to uncompressed stored
---blocks), which is precisely when this entry point is preferable.
---@param rgba string raw 8-bit RGBA bytes (length == w_px * h_px * 4)
---@param w_px integer
---@param h_px integer
---@param colors integer? max palette size (default 256)
---@return string?
function M.encode_sixel_from_rgba(rgba, w_px, h_px, colors)
    local bin = M.binary()
    if not bin then
        return nil
    end
    local size = string.format("%dx%d", w_px, h_px)
    local def = "sixel:colors=" .. tostring(colors or 256)
    return normalize_sixel_introducer(
        run({ bin, "-size", size, "-depth", "8", "RGBA:-", "-define", def, "sixel:-" }, rgba)
    )
end

---Decode + nearest-neighbor resize + sixel-encode in one magick subprocess.
---Uses `-sample` (raw pixel sampling, no filtering) so output matches the
---pure-Lua `image.resize` path — sharp pixels, no smoothing. magick's
---default `-resize` uses Lanczos which produces blurry output for the 1:1
---cell-pixel mapping the providers expect.
---@param png_bytes string original PNG bytes
---@param w_px integer target width in pixels
---@param h_px integer target height in pixels
---@param colors integer? max palette size (default 256)
---@return string?
function M.encode_sixel_from_png_resized(png_bytes, w_px, h_px, colors)
    local bin = M.binary()
    if not bin then
        return nil
    end
    local geom = string.format("%dx%d!", w_px, h_px)
    local def = "sixel:colors=" .. tostring(colors or 256)
    return normalize_sixel_introducer(run({ bin, "-", "-sample", geom, "-define", def, "sixel:-" }, png_bytes))
end

---Decode + nearest-neighbor resize + PNG re-encode in one magick subprocess.
---Mirrors `encode_sixel_from_png_resized` for the iTerm2 OSC 1337 payload:
---one process does decode + sample-resize + PNG output, so the pure-Lua
---decoder/resizer/encoder are bypassed. `-sample` (not `-resize`) keeps
---the output byte-identical in shape to the pure-Lua nearest-neighbor
---path so iTerm2 sees a 1:1 cell-pixel mapping (sharp output).
---@param png_bytes string original PNG bytes
---@param w_px integer target width in pixels
---@param h_px integer target height in pixels
---@return string?
function M.encode_png_resized(png_bytes, w_px, h_px)
    local bin = M.binary()
    if not bin then
        return nil
    end
    local geom = string.format("%dx%d!", w_px, h_px)
    return run({ bin, "-", "-sample", geom, "png:-" }, png_bytes)
end

---Decode + resize-to-target + crop-of-target + PNG re-encode in one
---subprocess. Useful as a feeder for chafa, which can decode + sixel-encode
---but cannot pixel-resize or crop on its own. Crop coords are in *resized*
---pixel space, matching the carrier math elsewhere in the codec.
---@param png_bytes string
---@param full_w_px integer
---@param full_h_px integer
---@param x_px integer
---@param y_px integer
---@param w_px integer
---@param h_px integer
---@return string?
function M.crop_resized_to_png(png_bytes, full_w_px, full_h_px, x_px, y_px, w_px, h_px)
    local bin = M.binary()
    if not bin then
        return nil
    end
    local sample = string.format("%dx%d!", full_w_px, full_h_px)
    local crop = string.format("%dx%d+%d+%d", w_px, h_px, x_px, y_px)
    return run({ bin, "-", "-sample", sample, "-crop", crop, "png:-" }, png_bytes)
end

---Async: decode + resize + crop + PNG re-encode. Invokes
---`on_done(png_or_nil)` from the main loop when the subprocess exits.
---@param png_bytes string
---@param full_w_px integer
---@param full_h_px integer
---@param x_px integer
---@param y_px integer
---@param w_px integer
---@param h_px integer
---@param on_done fun(png: string?)
function M.crop_resized_to_png_async(png_bytes, full_w_px, full_h_px, x_px, y_px, w_px, h_px, on_done)
    local bin = M.binary()
    if not bin then
        return on_done(nil)
    end
    local sample = string.format("%dx%d!", full_w_px, full_h_px)
    local crop = string.format("%dx%d+%d+%d", w_px, h_px, x_px, y_px)
    run_async({ bin, "-", "-sample", sample, "-crop", crop, "png:-" }, png_bytes, on_done)
end

---Decode + resize-to-target + crop-of-target + sixel-encode in one magick
---subprocess. The crop coordinates are in *target* pixel space (after the
---resize), matching the providers' carrier math which works in cell-pixel
---units of the resized image. Resize uses `-sample` (nearest-neighbor) for
---the same reason as `encode_sixel_from_png_resized`.
---@param png_bytes string original PNG bytes
---@param full_w_px integer resized full-image width in pixels
---@param full_h_px integer resized full-image height in pixels
---@param x_px integer crop x in target pixel space
---@param y_px integer crop y in target pixel space
---@param w_px integer crop width in target pixel space
---@param h_px integer crop height in target pixel space
---@param colors integer? max palette size (default 256)
---@return string?
function M.crop_resized_to_sixel(png_bytes, full_w_px, full_h_px, x_px, y_px, w_px, h_px, colors)
    local bin = M.binary()
    if not bin then
        return nil
    end
    local sample = string.format("%dx%d!", full_w_px, full_h_px)
    local crop = string.format("%dx%d+%d+%d", w_px, h_px, x_px, y_px)
    local def = "sixel:colors=" .. tostring(colors or 256)
    return normalize_sixel_introducer(
        run({ bin, "-", "-sample", sample, "-crop", crop, "-define", def, "sixel:-" }, png_bytes)
    )
end

---Async: decode + resize + PNG re-encode. Invokes `on_done(png_or_nil)` from
---the main loop when the subprocess exits.
---@param png_bytes string
---@param w_px integer target width in pixels
---@param h_px integer target height in pixels
---@param on_done fun(png: string?)
---@return nil
function M.encode_png_resized_async(png_bytes, w_px, h_px, on_done)
    local bin = M.binary()
    if not bin then
        return on_done(nil)
    end
    local geom = string.format("%dx%d!", w_px, h_px)
    run_async({ bin, "-", "-sample", geom, "png:-" }, png_bytes, on_done)
end

---Async: crop a PNG sub-rectangle. Invokes `on_done(cropped_png_or_nil)`.
---@param png_bytes string
---@param x_px integer
---@param y_px integer
---@param w_px integer
---@param h_px integer
---@param on_done fun(png: string?)
---@return nil
function M.crop_to_png_async(png_bytes, x_px, y_px, w_px, h_px, on_done)
    local bin = M.binary()
    if not bin then
        return on_done(nil)
    end
    local geom = string.format("%dx%d+%d+%d", w_px, h_px, x_px, y_px)
    run_async({ bin, "-", "-crop", geom, "png:-" }, png_bytes, on_done)
end

---Async: decode + resize + sixel-encode. Invokes `on_done(sixel_dcs_or_nil)`.
---@param png_bytes string
---@param w_px integer target width in pixels
---@param h_px integer target height in pixels
---@param on_done fun(sixel: string?)
---@param colors integer? max palette size (default 256)
---@return nil
function M.encode_sixel_from_png_resized_async(png_bytes, w_px, h_px, on_done, colors)
    local bin = M.binary()
    if not bin then
        return on_done(nil)
    end
    local geom = string.format("%dx%d!", w_px, h_px)
    local def = "sixel:colors=" .. tostring(colors or 256)
    run_async({ bin, "-", "-sample", geom, "-define", def, "sixel:-" }, png_bytes, function(out)
        on_done(normalize_sixel_introducer(out))
    end)
end

---Async: decode + resize-to-target + crop-of-target + sixel-encode in one
---subprocess. Invokes `on_done(sixel_dcs_or_nil)`.
---@param png_bytes string original PNG bytes
---@param full_w_px integer resized full-image width in pixels
---@param full_h_px integer resized full-image height in pixels
---@param x_px integer crop x in target pixel space
---@param y_px integer crop y in target pixel space
---@param w_px integer crop width in target pixel space
---@param h_px integer crop height in target pixel space
---@param on_done fun(sixel: string?)
---@param colors integer? max palette size (default 256)
---@return nil
function M.crop_resized_to_sixel_async(png_bytes, full_w_px, full_h_px, x_px, y_px, w_px, h_px, on_done, colors)
    local bin = M.binary()
    if not bin then
        return on_done(nil)
    end
    local sample = string.format("%dx%d!", full_w_px, full_h_px)
    local crop = string.format("%dx%d+%d+%d", w_px, h_px, x_px, y_px)
    local def = "sixel:colors=" .. tostring(colors or 256)
    run_async({ bin, "-", "-sample", sample, "-crop", crop, "-define", def, "sixel:-" }, png_bytes, function(out)
        on_done(normalize_sixel_introducer(out))
    end)
end

return M
