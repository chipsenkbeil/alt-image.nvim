-- Simple bounded LRU cache helpers used by providers for crop encodings.
-- Keys are strings; values are arbitrary. Accesses move the key to the end
-- of the order list; oldest entries are evicted when size exceeds `max`.

local M = {}

M.MAX_DEFAULT = 16

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

function M.put(map, order, key, value, max)
    map[key] = value
    table.insert(order, key)
    while #order > (max or M.MAX_DEFAULT) do
        local evict = table.remove(order, 1)
        map[evict] = nil
    end
end

return M
