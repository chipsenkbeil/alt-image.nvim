local M = {}

---Return the resolved binary name to invoke, or nil if disabled / not found.
---@return string?
function M.binary()
    local config = require("alt-img._core.config")
    return require("alt-img._core.binary").resolve(config.read().img2sixel)
end

---@param opts? { colors?: integer, w_px?: integer, h_px?: integer, crop?: { x: integer, y: integer, w: integer, h: integer } }
---@return string[]
local function argv(opts)
    opts = opts or {}
    local bin = M.binary()
    if not bin then
        return {}
    end
    local cmd = { bin }
    if opts.colors then
        cmd[#cmd + 1] = "-p"
        cmd[#cmd + 1] = tostring(opts.colors)
    end
    if opts.w_px then
        cmd[#cmd + 1] = "-w"
        cmd[#cmd + 1] = tostring(opts.w_px)
    end
    if opts.h_px then
        cmd[#cmd + 1] = "-h"
        cmd[#cmd + 1] = tostring(opts.h_px)
    end
    if opts.crop then
        cmd[#cmd + 1] = "-c"
        cmd[#cmd + 1] = string.format("%dx%d+%d+%d", opts.crop.w, opts.crop.h, opts.crop.x, opts.crop.y)
    end
    return cmd
end

---Pipe PNG bytes into img2sixel and return the sixel DCS string, nil on fail.
---@param png_bytes string
---@param colors integer? max palette size (img2sixel uses --colors / -p)
---@return string?
function M.encode_sixel(png_bytes, colors)
    local cmd = argv({ colors = colors })
    if #cmd == 0 then
        return nil
    end
    return require("alt-img._core.subprocess").run(cmd, png_bytes)
end

---Async counterpart to `encode_sixel`. Invokes `on_done(sixel_or_nil)` from
---the main loop when img2sixel exits. Note: img2sixel flattens PNG alpha
---against its `-B` background color (default black) before encoding, so this
---path loses transparency for alpha-bearing PNGs. Use chafa where alpha
---preservation matters.
---@param png_bytes string
---@param on_done fun(sixel: string?)
---@param colors integer?
function M.encode_sixel_async(png_bytes, on_done, colors)
    local cmd = argv({ colors = colors })
    if #cmd == 0 then
        return on_done(nil)
    end
    require("alt-img._core.subprocess").run_async(cmd, png_bytes, on_done)
end

---Decode + nearest-neighbor resize + sixel-encode in one subprocess via
---img2sixel's `-w`/`-h` pixel-resize flags. Saves the pure-Lua decode +
---resize + png-encode hops on the cold path. Same alpha caveat as
---`encode_sixel`.
---@param png_bytes string
---@param w_px integer target width in pixels
---@param h_px integer target height in pixels
---@param colors integer?
---@return string?
function M.encode_sixel_resized(png_bytes, w_px, h_px, colors)
    local cmd = argv({ colors = colors, w_px = w_px, h_px = h_px })
    if #cmd == 0 then
        return nil
    end
    return require("alt-img._core.subprocess").run(cmd, png_bytes)
end

---Async counterpart to `encode_sixel_resized`.
---@param png_bytes string
---@param w_px integer
---@param h_px integer
---@param on_done fun(sixel: string?)
---@param colors integer?
function M.encode_sixel_resized_async(png_bytes, w_px, h_px, on_done, colors)
    local cmd = argv({ colors = colors, w_px = w_px, h_px = h_px })
    if #cmd == 0 then
        return on_done(nil)
    end
    require("alt-img._core.subprocess").run_async(cmd, png_bytes, on_done)
end

---Decode + resize-to-target + crop-of-target + sixel-encode in one
---subprocess. img2sixel applies `-w`/`-h` first, then `-c`, so crop
---coordinates are in the *resized* pixel space — matching the carrier
---math the rest of the codec uses.
---@param png_bytes string original PNG bytes
---@param full_w_px integer resized full-image width in pixels
---@param full_h_px integer resized full-image height in pixels
---@param x_px integer crop x in target pixel space
---@param y_px integer crop y in target pixel space
---@param w_px integer crop width in target pixel space
---@param h_px integer crop height in target pixel space
---@param colors integer?
---@return string?
function M.crop_resized_to_sixel(png_bytes, full_w_px, full_h_px, x_px, y_px, w_px, h_px, colors)
    local cmd = argv({
        colors = colors,
        w_px = full_w_px,
        h_px = full_h_px,
        crop = { x = x_px, y = y_px, w = w_px, h = h_px },
    })
    if #cmd == 0 then
        return nil
    end
    return require("alt-img._core.subprocess").run(cmd, png_bytes)
end

---Async counterpart to `crop_resized_to_sixel`.
---@param png_bytes string
---@param full_w_px integer
---@param full_h_px integer
---@param x_px integer
---@param y_px integer
---@param w_px integer
---@param h_px integer
---@param on_done fun(sixel: string?)
---@param colors integer?
function M.crop_resized_to_sixel_async(png_bytes, full_w_px, full_h_px, x_px, y_px, w_px, h_px, on_done, colors)
    local cmd = argv({
        colors = colors,
        w_px = full_w_px,
        h_px = full_h_px,
        crop = { x = x_px, y = y_px, w = w_px, h = h_px },
    })
    if #cmd == 0 then
        return on_done(nil)
    end
    require("alt-img._core.subprocess").run_async(cmd, png_bytes, on_done)
end

return M
