-- Verifies _core/async.lua: cancellation, error propagation, progress, completion.
-- Run with: nvim --headless -l test/scripts/async_driver.lua

vim.opt.runtimepath:append(vim.fn.fnamemodify(arg[0], ":p:h:h:h"))
local async = require("alt-img._core.async")

local function expect(label, cond, detail)
    if cond then
        print("OK  " .. label)
    else
        print("FAIL " .. label .. " — " .. tostring(detail or ""))
        os.exit(1)
    end
end

-- Test 1: completion delivers final value to on_done.
do
    local done_value = nil
    async.run(
        function()
            async.maybe_yield({ phase = "p1" })
            async.maybe_yield({ phase = "p2" })
            return "RESULT"
        end,
        nil,
        function(result, err)
            done_value = result
            _G.__t1_err = err
        end
    )
    vim.wait(500, function()
        return done_value ~= nil
    end)
    expect("completion delivers result", done_value == "RESULT", done_value)
end

-- Test 2: progress is reported for each yielded value.
do
    local progress = {}
    local done = false
    async.run(function()
        async.maybe_yield(1)
        async.maybe_yield(2)
        async.maybe_yield(3)
    end, function(p)
        progress[#progress + 1] = p
    end, function()
        done = true
    end)
    vim.wait(500, function()
        return done
    end)
    expect("progress count == 3", #progress == 3, #progress)
    expect("progress order ok", progress[1] == 1 and progress[2] == 2 and progress[3] == 3)
end

-- Test 3: cancellation halts before completion.
do
    local steps = 0
    local done = false
    local handle = async.run(
        function()
            for _ = 1, 100000 do
                steps = steps + 1
                async.maybe_yield(steps)
            end
        end,
        nil,
        function()
            done = true
        end
    )
    vim.defer_fn(function()
        handle.cancel()
    end, 10)
    vim.wait(200)
    expect("cancellation prevents completion", not done, "done=" .. tostring(done))
    expect("cancellation halts work", steps < 100000, "steps=" .. tostring(steps))
end

-- Test 4: lua error inside work_fn surfaces to on_done(nil, err).
do
    local got_err = nil
    async.run(
        function()
            async.maybe_yield(1)
            error("boom")
        end,
        nil,
        function(_, err)
            got_err = err
        end
    )
    vim.wait(500, function()
        return got_err ~= nil
    end)
    expect("error propagates to on_done", got_err and got_err:find("boom"), got_err)
end

-- Test 5: maybe_yield is a no-op outside a coroutine.
do
    local ok, err = pcall(async.maybe_yield, "main thread")
    expect("maybe_yield no-ops on main thread", ok, err)
end

print("ALL OK")
os.exit(0)
