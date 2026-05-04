local M = {}

---Retrieve a value from the LRU map, promoting the key to most-recently-used.
---@param map table<string, any>|nil
---@param order string[]
---@param key string
---@return any value nil if missing
function M.get(map, order, key)
    if not map then
        return nil
    end
    local v = map[key]
    if v then
        for i, k in ipairs(order) do
            if k == key then
                table.remove(order, i)
                break
            end
        end
        table.insert(order, key)
    end
    return v
end

---Insert or update a key/value pair, evicting least-recently-used entries
---when the cache exceeds `max`.
---@param map table<string, any>
---@param order string[]
---@param key string
---@param value any
---@param max integer
function M.put(map, order, key, value, max)
    map[key] = value
    table.insert(order, key)
    while #order > max do
        local evict = table.remove(order, 1)
        map[evict] = nil
    end
end

return M
