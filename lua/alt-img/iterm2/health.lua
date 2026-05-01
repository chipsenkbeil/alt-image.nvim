-- :checkhealth alt-img.iterm2
local M = {}

function M.check()
    local h = vim.health
    h.start("alt-img.iterm2")

    local ok, msg = require("alt-img.iterm2")._supported()
    if ok then
        h.ok("iTerm2 OSC 1337 protocol: supported" .. (msg and (" (" .. msg .. ")") or ""))
    else
        h.error(
            "iTerm2 OSC 1337 protocol: not detected. "
                .. "Set TERM_PROGRAM, or use a terminal that responds to XTVERSION "
                .. "(\\033[>q) with iTerm2/WezTerm."
        )
    end

    if vim.env.TMUX then
        h.warn(
            "tmux detected: tmux passthrough is NOT supported in this version "
                .. "of alt-img.nvim. Images may not render. Tracked in README."
        )
    end
end

return M
