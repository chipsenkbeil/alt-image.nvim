describe("_core.async", function()
    local async = require("alt-img._core.async")

    it("delivers final result to on_done", function()
        local got
        async.run(
            function()
                async.maybe_yield({ phase = "p1" })
                async.maybe_yield({ phase = "p2" })
                return "RESULT"
            end,
            nil,
            function(result)
                got = result
            end
        )
        vim.wait(500, function()
            return got ~= nil
        end)
        assert.eq(got, "RESULT")
    end)

    it("fires on_progress per yield with same value", function()
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
        assert.eq(#progress, 3, "progress count")
        assert.eq(progress[1], 1)
        assert.eq(progress[2], 2)
        assert.eq(progress[3], 3)
    end)

    it("cancellation halts before completion", function()
        local TOTAL = 100000
        local steps = 0
        local done = false
        local handle = async.run(
            function()
                for _ = 1, TOTAL do
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
        end, 20)
        vim.wait(200)
        assert.falsy(done, "on_done must not fire after cancel")
        assert.lt(steps, TOTAL, "work must halt before completion")
    end)

    it("error inside work_fn surfaces to on_done(nil, err)", function()
        local got_err
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
        assert.match(tostring(got_err), "boom")
    end)

    it("maybe_yield is a no-op outside a coroutine", function()
        -- pcall to verify no error raised
        local ok, _ = pcall(async.maybe_yield, "main thread")
        assert.truthy(ok, "maybe_yield from main thread must not error")
    end)
end)
