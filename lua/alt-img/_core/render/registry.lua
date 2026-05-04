local M = {}

---@type table<string, alt-img._core.render.Placement>
local placements = {}
---@type boolean
local clear_pending = false

---@param token any
---@param id integer|any
---@return string
local function key(token, id)
    return tostring(token) .. ":" .. tostring(id)
end

---Compare two position lists for structural equality. Treats nil and empty
---list as equal (both mean "not visible").
---@param a? alt-img._core.render.Position[]
---@param b? alt-img._core.render.Position[]
---@return boolean
function M.positions_equal(a, b)
    if (a == nil) ~= (b == nil) then
        local list = a or b
        return #list == 0
    end
    if a == nil then
        return true
    end
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        local x, y = a[i], b[i]
        if x.row ~= y.row or x.col ~= y.col then
            return false
        end
        local sx, sy = x.src or {}, y.src or {}
        if sx.x ~= sy.x or sx.y ~= sy.y or sx.w ~= sy.w or sx.h ~= sy.h then
            return false
        end
    end
    return true
end

---@param token any opaque identity
---@param id integer
---@param get_pos fun(): alt-img._core.render.Position[]
---@param callbacks alt-img._core.render.Callbacks
function M.register(token, id, get_pos, callbacks)
    assert(
        type(callbacks) == "table" and type(callbacks.emit_at) == "function",
        "render.register requires callbacks.emit_at"
    )
    placements[key(token, id)] = {
        token = token,
        id = id,
        get_pos = get_pos,
        callbacks = callbacks,
        redraw = true,
        last_positions = nil,
    }
end

---@param token any
---@param id integer
function M.unregister(token, id)
    placements[key(token, id)] = nil
    clear_pending = true
end

---@param token any
---@param id integer
function M.invalidate(token, id)
    local p = placements[key(token, id)]
    if p then
        p.redraw = true
    end
end

---Cheap mark-dirty for hot autocmds (TextChanged, CursorMoved). The position
---equality elision in the renderer turns no-op cursor moves into zero-byte ticks.
function M.mark_all_dirty()
    for _, p in pairs(placements) do
        p.redraw = true
    end
end

---Force re-emit on the next tick even if positions are unchanged. Use when
---something OUTSIDE alt-img has wiped the terminal's image plane (mode prompt,
---:redraw!, terminal-side resize). Does NOT null last_positions: the dirty
---scan needs the "before" state to detect "image went from visible to gone".
function M.force_all_dirty()
    for _, p in pairs(placements) do
        p.force_redraw = true
        p.redraw = true
    end
end

---Force every placement to re-emit on the next tick AND null last_positions
---so position-equality fires "moved" for every one. Used for full-refresh and
---WinScrolled paths.
function M.force_all_dirty_with_position_reset()
    for _, p in pairs(placements) do
        p.force_redraw = true
        p.redraw = true
        p.last_positions = nil
    end
end

---@return alt-img._core.render.Placement[]
function M.all()
    local out = {}
    for _, p in pairs(placements) do
        out[#out + 1] = p
    end
    return out
end

---Sort the given placement list by zindex (ascending) so higher-z emits last
---and paints on top. Mutates and returns the list.
---@param set alt-img._core.render.Placement[]
---@return alt-img._core.render.Placement[]
function M.sort_by_zindex(set)
    table.sort(set, function(a, b)
        local ao = (a.callbacks.get_opts and a.callbacks.get_opts(a.id)) or {}
        local bo = (b.callbacks.get_opts and b.callbacks.get_opts(b.id)) or {}
        local az = ao.zindex or 0
        local bz = bo.zindex or 0
        if az ~= bz then
            return az < bz
        end
        return a.id < b.id
    end)
    return set
end

---@return boolean
function M.has_clear_pending()
    return clear_pending
end

function M.consume_clear_pending()
    clear_pending = false
end

---Reset all registry state. Called from render.lua on module load so a
---reload (`:Lazy reload`, package.loaded fiddling) starts clean without
---having to reset registry separately.
function M.reset()
    placements = {}
    clear_pending = false
end

return M
