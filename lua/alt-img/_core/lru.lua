-- Simple bounded LRU cache helpers used by providers for crop encodings.
-- Keys are strings; values are arbitrary. Accesses move the key to the end
-- of the order list; oldest entries are evicted when size exceeds `max`.

local M = {}

-- 64 covers a long-buffer scroll without thrashing; each entry is typically
-- well under 100KB so worst-case memory per placement is bounded by ~6MB.
---@type integer
M.MAX_DEFAULT = 64

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
        -- Move key to end (most recently used).
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
---when the cache exceeds `max` (default `M.MAX_DEFAULT`).
---@param map table<string, any>
---@param order string[]
---@param key string
---@param value any
---@param max integer?
function M.put(map, order, key, value, max)
    map[key] = value
    table.insert(order, key)
    while #order > (max or M.MAX_DEFAULT) do
        local evict = table.remove(order, 1)
        map[evict] = nil
    end
end

return M
