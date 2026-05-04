local M = {}

---Run `work_fn` as a coroutine, yielding to the event loop between steps.
---Each `coroutine.yield(progress)` reschedules a `vim.defer_fn(0, …)` resume
---— so timers (spinner animation), input, and redraws all run between
---resumes.
---
---`work_fn` returns the final result when the coroutine ends. Yielded
---values are progress records (typed by callers).
---@param work_fn fun(): any
---@param on_progress? fun(progress: any)
---@param on_done fun(result: any|nil, err: string|nil)
---@return { cancel: fun() }
function M.run(work_fn, on_progress, on_done)
    local co = coroutine.create(work_fn)
    local cancelled = false
    local function step()
        if cancelled then
            return
        end
        local ok, val = coroutine.resume(co)
        if not ok then
            return on_done(nil, val)
        end
        if coroutine.status(co) == "dead" then
            return on_done(val)
        end
        if on_progress then
            on_progress(val)
        end
        vim.defer_fn(step, 0)
    end
    -- First step on next tick so set() can return before any encode work.
    vim.defer_fn(step, 0)
    return {
        cancel = function()
            cancelled = true
        end,
    }
end

---Yield `progress` if currently inside a coroutine; no-op when called from
---the main thread. Pure-Lua encoder hot loops use this so the same code
---path serves both async and sync callers — no `_yieldable` siblings.
---@param progress any
function M.maybe_yield(progress)
    if coroutine.running() then
        coroutine.yield(progress)
    end
end

return M
