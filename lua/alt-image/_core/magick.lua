-- alt-image internal wrapper around the ImageMagick CLI (`magick` / `convert`).
-- Honors `vim.g.alt_image.magick` per the alt-image config contract — see
-- `_core/config.lua`. Returns nil from every helper on any failure so the
-- caller can fall back to the pure-Lua paths.

local M = {}

local _util = require("alt-image._core.util")
local _config = require("alt-image._core.config")

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
                vim.notify_once(("alt-image: %s failed: %s"):format(cmd[1], res.stderr), vim.log.levels.DEBUG)
            end)
        end
        return nil
    end
    return res.stdout
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
    return run({ bin, "-", "-crop", geom, "-define", def, "sixel:-" }, png_bytes)
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
    return run({ bin, "-", "-define", def, "sixel:-" }, png_bytes)
end

return M
