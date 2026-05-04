local M = {}

---@return nil
function M.check()
    local h = vim.health
    h.start("alt-img.sixel")

    local ok, msg = require("alt-img.sixel")._supported()
    if ok then
        h.ok("Sixel protocol: supported")
    else
        h.error(
            "Sixel protocol: not detected. "
                .. (
                    msg
                    or (
                        "Detection failed. Try a sixel-capable terminal "
                        .. "(Windows Terminal, iTerm.app, WezTerm, foot, mlterm, "
                        .. "contour, xterm with +sixel build), "
                        .. "or set TERM=xterm-sixel, or set "
                        .. 'or set vim.ui.img = require("alt-img.sixel") to force.'
                    )
                )
        )
    end

    if vim.env.TERM_PROGRAM == "Apple_Terminal" then
        h.warn("Apple Terminal echoes APC sequences but does not render sixel.")
    end

    if vim.env.TMUX then
        h.warn(
            "tmux detected: tmux passthrough is NOT supported in this version "
                .. "of alt-img.nvim. Images may not render. Tracked in README."
        )
    end

    -- Transparent-PNG accelerator. magick / img2sixel both flatten alpha
    -- against a background color; chafa preserves it (P2=1, no bits at
    -- transparent positions).
    local chafa = require("alt-img.sixel._chafa")
    local libsixel = require("alt-img.sixel._libsixel")
    local magick = require("alt-img._core.magick")
    if chafa.binary() then
        h.ok("chafa: " .. chafa.binary() .. " (preferred encoder for transparent PNGs)")
    elseif libsixel.binary() or magick.binary() then
        h.warn(
            "chafa: not found. With magick/img2sixel only, PNG alpha is flattened "
                .. "to the tool's background color (default black). Install chafa "
                .. "to preserve transparency, or pick a tool background that matches "
                .. "your terminal's background color."
        )
    else
        h.info(
            "chafa: not found (and no other sixel encoder configured); the pure-Lua "
                .. "encoder handles transparency correctly but is slower."
        )
    end
end

return M
