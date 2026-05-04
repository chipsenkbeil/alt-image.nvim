---@class alt-img._core.processing.Config
---@field tools? string[]|false  enabled tools, in order; falsy = pure-Lua only
---@field magick? string|string[]  candidate binary names; first executable wins
---@field img2sixel? string|string[]  candidate binary names; first executable wins
---@field chafa? string|string[]  candidate binary names; first executable wins
---@field libz? string|string[]  FFI dylib names; first loadable wins

local M = {}

-- Order of `tools` IS the sixel encoder dispatch order. Adding a new tool
-- means appending it here AND adding a sibling key for its candidate
-- binary names.
---@type alt-img._core.processing.Config
local DEFAULTS = {
    tools = { "chafa", "img2sixel", "magick", "libz" },
    chafa = { "chafa" },
    img2sixel = { "img2sixel" },
    libz = { "z", "zlib", "zlib1", "libz" },
    magick = { "magick", "convert" },
}

---Read the merged processing slice. Subsystem owns its own merge so a
---user setting one key doesn't obliterate sibling defaults.
---@return alt-img._core.processing.Config
function M.read()
    local user = (vim.g.alt_img and vim.g.alt_img.processing) or {}
    return vim.tbl_extend("force", DEFAULTS, user)
end

---@param name string
---@return boolean
function M.is_enabled(name)
    local tools = M.read().tools
    if type(tools) ~= "table" then
        return false
    end
    for _, n in ipairs(tools) do
        if n == name then
            return true
        end
    end
    return false
end

---Filter `names` by the enabled tools list, preserving user-specified order.
---`ordered_tools({'chafa','img2sixel','magick'})` with
---`tools = {'magick','chafa'}` returns `{'magick','chafa'}`.
---@param names string[]
---@return string[]
function M.ordered_tools(names)
    local allowed = {}
    for _, n in ipairs(names) do
        allowed[n] = true
    end
    local out = {}
    local tools = M.read().tools
    if type(tools) ~= "table" then
        return out
    end
    for _, n in ipairs(tools) do
        if allowed[n] then
            out[#out + 1] = n
        end
    end
    return out
end

---Candidate binary (or FFI dylib) names for the named tool.
---@param name string
---@return string|string[]|nil
function M.candidates(name)
    return M.read()[name]
end

return M
