local H = require("test.helpers")

describe("alt-img._core.precompute enumeration", function()
    local precompute

    before_each(function()
        package.loaded["alt-img._core.precompute"] = nil
        precompute = require("alt-img._core.precompute")
    end)

    it("enumerates 2*(H-1) vertical variations", function()
        -- For W=8, H=12 (the user's example): 11 top crops + 11 bottom crops = 22.
        local v = precompute._enumerate_variations(8, 12)
        assert.equals(22, #v)
    end)

    it("top variations cover y=0, h=1..H-1 with full width", function()
        local v = precompute._enumerate_variations(8, 5)
        -- First H-1 = 4 entries are top crops.
        assert.equals(4, #v / 2)
        for i = 1, 4 do
            local s = v[i]
            assert.equals(0, s.x)
            assert.equals(0, s.y)
            assert.equals(8, s.w)
            assert.equals(i, s.h)
        end
    end)

    it("bottom variations cover y=H-N..H-1, h=N", function()
        local v = precompute._enumerate_variations(8, 5)
        -- Last H-1 = 4 entries are bottom crops.
        for n = 1, 4 do
            local s = v[4 + n] -- index after the 4 top crops
            assert.equals(0, s.x)
            assert.equals(5 - n, s.y) -- H - N
            assert.equals(8, s.w)
            assert.equals(n, s.h) -- N rows tall
        end
    end)

    it("returns empty list for height 1 (nothing to crop)", function()
        local v = precompute._enumerate_variations(8, 1)
        assert.equals(0, #v)
    end)

    it("returns empty list for invalid dims", function()
        assert.equals(0, #precompute._enumerate_variations(nil, 5))
        assert.equals(0, #precompute._enumerate_variations(5, nil))
        assert.equals(0, #precompute._enumerate_variations(0, 5))
        assert.equals(0, #precompute._enumerate_variations(5, 0))
        assert.equals(0, #precompute._enumerate_variations(-1, 5))
    end)
end)

describe("alt-img._core.precompute scheduling", function()
    local precompute
    local saved_alt_img

    before_each(function()
        saved_alt_img = vim.g.alt_img
        package.loaded["alt-img._core.precompute"] = nil
        package.loaded["alt-img._core.config"] = nil
        precompute = require("alt-img._core.precompute")
    end)

    after_each(function()
        vim.g.alt_img = saved_alt_img
    end)

    -- Helper: poll until predicate returns true or timeout (ms) elapses.
    -- Uses vim.wait so timer callbacks (vim.schedule_wrap) actually fire.
    local function wait_until(predicate, timeout)
        return vim.wait(timeout or 5000, predicate, 5)
    end

    it("calls _build_at for every variation, then stops", function()
        local calls = {}
        local fake = {
            _build_at = function(id, screen_pos)
                table.insert(calls, { id = id, src = screen_pos.src })
            end,
        }
        precompute.start(fake, 1, { width = 4, height = 4 })

        -- Expect 2*(4-1) = 6 calls eventually.
        wait_until(function() return #calls == 6 end, 2000)
        assert.equals(6, #calls)
        -- Timer should self-cancel after the last variation.
        wait_until(function() return not precompute._is_active(fake, 1) end, 500)
        assert.is_false(precompute._is_active(fake, 1))
    end)

    it("cancel stops further work mid-flight", function()
        local calls = 0
        local fake = {
            _build_at = function() calls = calls + 1 end,
        }
        precompute.start(fake, 1, { width = 4, height = 100 }) -- 198 variations
        -- Let a couple of calls happen, then cancel.
        wait_until(function() return calls >= 2 end, 500)
        local at_cancel = calls
        precompute.cancel(fake, 1)
        assert.is_false(precompute._is_active(fake, 1))
        -- Wait briefly; calls should not advance after cancel.
        vim.wait(100, function() return false end)
        assert.equals(at_cancel, calls)
    end)

    it("does nothing when precompute_crops is false", function()
        vim.g.alt_img = { precompute_crops = false }
        local calls = 0
        local fake = { _build_at = function() calls = calls + 1 end }
        precompute.start(fake, 1, { width = 4, height = 4 })
        vim.wait(100, function() return false end)
        assert.equals(0, calls)
        assert.is_false(precompute._is_active(fake, 1))
    end)

    it("does nothing when provider has no _build_at", function()
        local fake = { _emit_at = function() end } -- legacy provider
        precompute.start(fake, 1, { width = 4, height = 4 })
        assert.is_false(precompute._is_active(fake, 1))
    end)

    it("does nothing for missing dims", function()
        local fake = { _build_at = function() end }
        precompute.start(fake, 1, { width = nil, height = 4 })
        assert.is_false(precompute._is_active(fake, 1))
        precompute.start(fake, 1, { width = 4, height = nil })
        assert.is_false(precompute._is_active(fake, 1))
        precompute.start(fake, 1, nil)
        assert.is_false(precompute._is_active(fake, 1))
    end)

    it("skips work while user is recently active (throttle)", function()
        local calls = 0
        local fake = { _build_at = function() calls = calls + 1 end }
        -- Simulate "user just hit a key" — well within the default 200 ms threshold.
        precompute._set_last_activity_ns(vim.uv.hrtime())
        precompute.start(fake, 1, { width = 4, height = 4 })
        -- Even after multiple timer fires, no work should land while we
        -- keep updating last_activity_ns inside the threshold window.
        local function refresh_activity()
            precompute._set_last_activity_ns(vim.uv.hrtime())
        end
        local deadline = vim.uv.now() + 250
        while vim.uv.now() < deadline do
            refresh_activity()
            vim.wait(20, function() return false end)
        end
        assert.equals(0, calls)
        -- Now go idle: stop refreshing and let the threshold lapse.
        precompute._set_last_activity_ns(0) -- "never active"
        wait_until(function() return calls == 6 end, 2000)
        assert.equals(6, calls)
    end)

    it("respects precompute_idle_threshold_ms = 0 (throttle off)", function()
        vim.g.alt_img = { precompute_idle_threshold_ms = 0 }
        local calls = 0
        local fake = { _build_at = function() calls = calls + 1 end }
        -- Mark recently active — but threshold=0 means "never throttle."
        precompute._set_last_activity_ns(vim.uv.hrtime())
        precompute.start(fake, 1, { width = 4, height = 4 })
        wait_until(function() return calls == 6 end, 2000)
        assert.equals(6, calls)
    end)

    it("emits vim.notify on start + complete when precompute_notify is true", function()
        vim.g.alt_img = { precompute_notify = true }
        local notifications = {}
        local orig_notify = vim.notify
        vim.notify = function(msg, level)
            notifications[#notifications + 1] = { msg = msg, level = level }
        end
        local fake = { _build_at = function() end }
        precompute._set_last_activity_ns(0)
        precompute.start(fake, 1, { width = 4, height = 4 })
        wait_until(function()
            return #notifications >= 2
        end, 2000)
        vim.notify = orig_notify
        assert.is_true(#notifications >= 2)
        assert.matches("precomputing 6 crop variants", notifications[1].msg)
        assert.matches("precompute done", notifications[#notifications].msg)
    end)

    it("does NOT notify when precompute_notify is false (default)", function()
        local notifications = 0
        local orig_notify = vim.notify
        vim.notify = function() notifications = notifications + 1 end
        local fake = { _build_at = function() end }
        precompute._set_last_activity_ns(0)
        precompute.start(fake, 1, { width = 4, height = 4 })
        wait_until(function() return not precompute._is_active(fake, 1) end, 2000)
        vim.notify = orig_notify
        assert.equals(0, notifications)
    end)

    it("start() cancels prior precompute for the same (provider, id)", function()
        local calls_first = 0
        local fake_first = { _build_at = function() calls_first = calls_first + 1 end }
        precompute.start(fake_first, 1, { width = 4, height = 50 }) -- 98 variations
        wait_until(function() return calls_first >= 1 end, 500)
        -- Restart with new dims; prior timer should be canceled.
        local calls_second = 0
        local fake_second = { _build_at = function() calls_second = calls_second + 1 end }
        precompute.start(fake_second, 1, { width = 4, height = 4 }) -- 6 variations
        wait_until(function() return calls_second == 6 end, 2000)
        assert.equals(6, calls_second)
        -- The first fake's call count should be bounded (timer was canceled
        -- when start() was called again on the same key). It's possible a
        -- callback was already in-flight when start() ran, so allow some
        -- slack — just assert it didn't run all 98.
        assert.is_true(calls_first < 50, "expected prior precompute to be canceled, got " .. calls_first)
    end)
end)
