---@type table?
local instance = nil

---Returns the cached provider, picking it from the autodetect matches
---on first call. Errors if no candidate is supported.
---@return table provider
local function get_instance()
    if not instance then
        local autodetect = require("alt-img._core.autodetect")
        for _, m in ipairs(autodetect.matches()) do
            if m.ok then
                instance = m.provider
                break
            end
        end
        assert(instance, "alt-img: no supported image protocol detected")
    end
    return instance
end

local M = {}

---On-disk cache surface. Persists encoded sixel DCS / iterm2 PNG payloads
---across nvim sessions, keyed by sha256 of the input bytes plus target
---dimensions and crop rect. See `:AltImg cache` for the user command.
M.cache = setmetatable({}, {
    __index = function(_, k)
        return require("alt-img._core.cache")[k]
    end,
})

---Resolved provider used by the autodetect dispatch. Forces the resolution
---if not yet cached. Used by `:checkhealth alt-img` and the manual smoke
---harness to identify which provider is in play.
---@return table provider
function M.provider()
    return get_instance()
end

---@param data_or_id string|integer image bytes (string) or existing id (integer)
---@param opts? vim.ui.img.Opts
---@return integer id
function M.set(data_or_id, opts)
    return get_instance().set(data_or_id, opts)
end

---@param id integer
---@return vim.ui.img.Opts? opts
function M.get(id)
    return get_instance().get(id)
end

---@param id integer
---@return boolean found
function M.del(id)
    return get_instance().del(id)
end

---@private
---@param opts? { timeout?: integer }
---@return boolean supported
---@return string? msg
function M._supported(opts)
    local autodetect = require("alt-img._core.autodetect")
    local matches = autodetect.matches(opts)
    for _, m in ipairs(matches) do
        if m.ok then
            return true
        end
    end
    local msgs = {}
    for _, m in ipairs(matches) do
        if m.msg then
            table.insert(msgs, m.name .. ": " .. m.msg)
        end
    end
    if #msgs > 0 then
        return false, table.concat(msgs, "; ")
    end
    return false
end

return M
