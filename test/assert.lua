-- Minimal assertion library for the alt-img test runner. Each assertion
-- raises a Lua error with a descriptive message on failure; the runner
-- catches and reports.

local M = {}

local function fail(msg, detail)
    if detail then
        error(msg .. " (" .. tostring(detail) .. ")", 3)
    end
    error(msg, 3)
end

local function fmt(v)
    if type(v) == "string" then
        return string.format("%q", v)
    end
    return tostring(v)
end

function M.eq(a, b, msg)
    if a ~= b then
        fail((msg or "values differ") .. ": expected " .. fmt(b) .. ", got " .. fmt(a))
    end
end

function M.ne(a, b, msg)
    if a == b then
        fail((msg or "values match unexpectedly") .. ": both = " .. fmt(a))
    end
end

function M.truthy(v, msg)
    if not v then
        fail((msg or "expected truthy") .. ": got " .. fmt(v))
    end
end

function M.falsy(v, msg)
    if v then
        fail((msg or "expected falsy") .. ": got " .. fmt(v))
    end
end

function M.gte(a, b, msg)
    if not (a >= b) then
        fail((msg or "expected gte") .. ": " .. fmt(a) .. " >= " .. fmt(b))
    end
end

function M.lte(a, b, msg)
    if not (a <= b) then
        fail((msg or "expected lte") .. ": " .. fmt(a) .. " <= " .. fmt(b))
    end
end

function M.gt(a, b, msg)
    if not (a > b) then
        fail((msg or "expected gt") .. ": " .. fmt(a) .. " > " .. fmt(b))
    end
end

function M.lt(a, b, msg)
    if not (a < b) then
        fail((msg or "expected lt") .. ": " .. fmt(a) .. " < " .. fmt(b))
    end
end

function M.match(s, pattern, msg)
    if type(s) ~= "string" or not s:find(pattern) then
        fail((msg or "pattern not found") .. ": pattern " .. fmt(pattern) .. " in " .. fmt(s))
    end
end

function M.contains(t, v, msg)
    if type(t) ~= "table" then
        fail((msg or "expected table") .. ": got " .. type(t))
    end
    for _, item in pairs(t) do
        if item == v then
            return
        end
    end
    fail((msg or "value not in table") .. ": looking for " .. fmt(v))
end

function M.fails(fn, msg)
    local ok, _err = pcall(fn)
    if ok then
        fail((msg or "expected fn to error") .. " but it returned normally")
    end
end

function M.near(a, b, tolerance, msg)
    if math.abs(a - b) > tolerance then
        fail((msg or "values not within tolerance") .. ": |" .. fmt(a) .. " - " .. fmt(b) .. "| > " .. fmt(tolerance))
    end
end

return M
