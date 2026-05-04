local M = {}

---@type table<string, boolean>
local cache = {}

---@param name string
---@return boolean
local function executable(name)
    if cache[name] == nil then
        cache[name] = vim.fn.executable(name) == 1
    end
    return cache[name]
end

---Resolve a config value to a binary name we should invoke, or nil if none
---is usable.
---  - falsy (`false` / `nil`) → nil (tool path disabled).
---  - `string`                → that exact binary if executable, else nil.
---  - `string[]`              → first executable candidate, else nil.
---@param cfg string|string[]|false|nil
---@return string?
function M.resolve(cfg)
    if not cfg then
        return nil
    end
    if type(cfg) == "string" then
        return executable(cfg) and cfg or nil
    end
    if type(cfg) == "table" then
        for _, name in ipairs(cfg) do
            if executable(name) then
                return name
            end
        end
    end
    return nil
end

return M
