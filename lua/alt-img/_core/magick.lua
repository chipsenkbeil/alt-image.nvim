-- alt-img internal wrapper around the ImageMagick CLI (`magick` / `convert`).
-- Honors `vim.g.alt_img.magick` per the alt-img config contract — see
-- `_core/config.lua`. Returns nil from every helper on any failure so the
-- caller can fall back to the pure-Lua paths.

local M = {}

local _util = require("alt-img._core.util")
local _config = require("alt-img._core.config")

---Return the resolved binary name to invoke, or nil if disabled / not found.
---@return string?
function M.binary()
    return _util.resolve_binary(_config.read().magick)
end

---Run a subprocess synchronously and return stdout on success, nil on fail.
---Surfaces stderr to the user once via vim.notify_once so ImageMagick policy
---errors etc. are visible, without spamming.
---@param cmd string[]
---@param stdin string
---@return string? stdout
local function run(cmd, stdin)
    local ok, res = pcall(function()
        return vim.system(cmd, { stdin = stdin, text = false }):wait()
    end)
    if not ok or not res or res.code ~= 0 then
        if res and res.stderr and #res.stderr > 0 then
            vim.schedule(function()
                vim.notify_once(("alt-img: %s failed: %s"):format(cmd[1], res.stderr), vim.log.levels.DEBUG)
            end)
        end
        return nil
    end
    return res.stdout
end

---Normalize magick's sixel DCS introducer so it matches `img2sixel`'s
---output, and what most sixel terminals actually render correctly.
---
---magick emits `ESC P 0;0;0 q ...` — explicit DCS params with P1=0. Per
---the VT3xx convention, P1=0 selects the default 2:1 pixel-aspect ratio,
---so terminals that honor that field (notably iTerm2's sixel decoder)
---scale the image vertically and ignore the raster `"pan;pad;w;h`
---override that magick emits right after. Stripping the DCS params
---collapses the introducer to `ESC P q ...` (img2sixel's shape), which
---makes terminals fall back to the raster attribute and render at the
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

---Crop a PNG sub-rectangle and emit as a sixel DCS string. Returns nil on
---failure.
---@param png_bytes string
---@param x_px integer
---@param y_px integer
---@param w_px integer
---@param h_px integer
---@param colors integer? max palette size (default 256)
---@return string?
function M.crop_to_sixel(png_bytes, x_px, y_px, w_px, h_px, colors)
    local bin = M.binary()
    if not bin then
        return nil
    end
    local geom = string.format("%dx%d+%d+%d", w_px, h_px, x_px, y_px)
    local def = "sixel:colors=" .. tostring(colors or 256)
    return normalize_sixel_introducer(run({ bin, "-", "-crop", geom, "-define", def, "sixel:-" }, png_bytes))
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

return M
