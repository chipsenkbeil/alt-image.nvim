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

return M
