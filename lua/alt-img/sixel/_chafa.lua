local M = {}

---@return string?
function M.binary()
    local config = require("alt-img._core.config")
    return require("alt-img._core.binary").resolve(config.read().chafa)
end

---Build the chafa argv shared by sync/async entry points.
---  --format=sixels       restrict output to a sixel DCS
---  --exact-size=on       match the input PNG's pixel dimensions
---                        (without it chafa scales to terminal cells)
---  --polite=on           drop the cursor-hide/show wrapper
---  --colors=240          stay under sixel's 256-entry palette cap
---                        (chafa reserves a few slots, so 240 is the
---                        documented safe ceiling for sixel output)
---  -                     read the PNG from stdin
---@param bin string
---@return string[]
local function argv(bin)
    return {
        bin,
        "--format=sixels",
        "--exact-size=on",
        "--polite=on",
        "--colors=240",
        "-",
    }
end

---Encode a PNG byte string as a sixel DCS string. chafa preserves the alpha
---channel — transparent pixels stay un-set in the output bands and the
---introducer is emitted with P2=1, so the terminal background shows through.
---Returns nil on failure.
---@param png_bytes string
---@return string?
function M.encode_sixel(png_bytes)
    local bin = M.binary()
    if not bin then
        return nil
    end
    return require("alt-img._core.subprocess").run(argv(bin), png_bytes)
end

---Async counterpart to `encode_sixel`. Invokes `on_done(sixel_or_nil)` from
---the main loop when the subprocess exits.
---@param png_bytes string
---@param on_done fun(sixel: string?)
function M.encode_sixel_async(png_bytes, on_done)
    local bin = M.binary()
    if not bin then
        return on_done(nil)
    end
    require("alt-img._core.subprocess").run_async(argv(bin), png_bytes, on_done)
end

---Pixel-exact resize + sixel-encode. chafa itself cannot pixel-resize
---(only `--size` in cells is exposed), so when magick is available we
---chain `magick decode+resize → png:- | chafa`. With magick disabled we
---fall back to chafa on the original PNG with `--exact-size=on`, which
---preserves alpha but renders at the input PNG's pixel dims rather than
---the requested target — the caller decides whether that's acceptable.
---@param png_bytes string original PNG bytes
---@param w_px integer target width in pixels
---@param h_px integer target height in pixels
---@return string?
function M.encode_sixel_resized(png_bytes, w_px, h_px)
    local magick = require("alt-img._core.magick")
    if magick.binary() then
        local resized = magick.encode_png_resized(png_bytes, w_px, h_px)
        if resized and #resized > 0 then
            return M.encode_sixel(resized)
        end
    end
    return nil
end

---Async counterpart to `encode_sixel_resized`. Chains magick async then
---chafa async.
---@param png_bytes string
---@param w_px integer
---@param h_px integer
---@param on_done fun(sixel: string?)
function M.encode_sixel_resized_async(png_bytes, w_px, h_px, on_done)
    local magick = require("alt-img._core.magick")
    if not magick.binary() then
        return on_done(nil)
    end
    magick.encode_png_resized_async(png_bytes, w_px, h_px, function(resized)
        if not resized or #resized == 0 then
            return on_done(nil)
        end
        M.encode_sixel_async(resized, on_done)
    end)
end

---Pixel-exact resize + crop + sixel-encode. Requires magick to do the
---decode+resize+crop hop (chafa has no crop support). Returns nil when
---magick is unavailable; the caller is expected to fall back to a
---pure-Lua resize+crop+png-encode + plain `encode_sixel`.
---@param png_bytes string
---@param full_w_px integer
---@param full_h_px integer
---@param x_px integer
---@param y_px integer
---@param w_px integer
---@param h_px integer
---@return string?
function M.crop_resized_to_sixel(png_bytes, full_w_px, full_h_px, x_px, y_px, w_px, h_px)
    local magick = require("alt-img._core.magick")
    if not magick.binary() then
        return nil
    end
    local cropped = magick.crop_resized_to_png(png_bytes, full_w_px, full_h_px, x_px, y_px, w_px, h_px)
    if not cropped or #cropped == 0 then
        return nil
    end
    return M.encode_sixel(cropped)
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
function M.crop_resized_to_sixel_async(png_bytes, full_w_px, full_h_px, x_px, y_px, w_px, h_px, on_done)
    local magick = require("alt-img._core.magick")
    if not magick.binary() then
        return on_done(nil)
    end
    magick.crop_resized_to_png_async(png_bytes, full_w_px, full_h_px, x_px, y_px, w_px, h_px, function(cropped)
        if not cropped or #cropped == 0 then
            return on_done(nil)
        end
        M.encode_sixel_async(cropped, on_done)
    end)
end

return M
