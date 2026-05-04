local M = {}

---Return the resolved binary name to invoke, or nil if disabled / not found.
---@return string?
function M.binary()
    local config = require("alt-img._core.config")
    return require("alt-img._core.binary").resolve(config.read().img2sixel)
end

---@param colors integer?
---@return string[]
local function argv(colors)
    local bin = M.binary()
    if not bin then
        return {}
    end
    local cmd = { bin }
    if colors then
        cmd[#cmd + 1] = "-p"
        cmd[#cmd + 1] = tostring(colors)
    end
    return cmd
end

---Pipe PNG bytes into img2sixel and return the sixel DCS string, nil on fail.
---@param png_bytes string
---@param colors integer? max palette size (img2sixel uses --colors / -p)
---@return string?
function M.encode_sixel(png_bytes, colors)
    local cmd = argv(colors)
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
    local cmd = argv(colors)
    if #cmd == 0 then
        return on_done(nil)
    end
    require("alt-img._core.subprocess").run_async(cmd, png_bytes, on_done)
end

return M
