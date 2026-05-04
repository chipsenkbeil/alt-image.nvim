-- Provider auto-selection: probes candidates and caches results.

local M = {}

---@type alt-img._core.autodetect.Match[]?
local cache = nil

---@class alt-img._core.autodetect.Match
---@field name string
---@field provider table
---@field ok boolean
---@field msg string?

---Probes every candidate provider in priority order and returns the
---results. Caches on first call; subsequent calls return the same list.
---Order/contents come from `vim.g.alt_img.autodetect`.
---@param opts? { timeout?: integer }
---@return alt-img._core.autodetect.Match[]
function M.matches(opts)
    if cache then
        return cache
    end
    cache = {}
    local cfg = require("alt-img._core.config").read()
    for _, name in ipairs(cfg.autodetect) do
        local provider = require("alt-img." .. name)
        local ok, msg = provider._supported(opts)
        table.insert(cache, { name = name, provider = provider, ok = ok, msg = msg })
    end
    return cache
end

return M
