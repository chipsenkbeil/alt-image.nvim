local H = require("test.helpers")

-- Helpers to build position records matching the new list-of-positions
-- contract. `pos(r, c)` returns a single-entry list at (r, c) covering a
-- 4x4 source rect.
local function pos(r, c, w, h)
    return { { row = r, col = c, src = { x = 0, y = 0, w = w or 4, h = h or 4 } } }
end

describe("alt-img._core.render", function()
    local render

    before_each(function()
        H.setup_capture()
        package.loaded["alt-img._core.render"] = nil
        render = require("alt-img._core.render")
    end)

    it("register + flush emits via provider._emit_at", function()
        local emitted = {}
        local fake = {
            _emit_at = function(id, p)
                emitted[#emitted + 1] = { id = id, pos = p }
            end,
        }
        render.register(fake, 1, function()
            return pos(5, 10)
        end)
        render.flush()
        assert.equals(1, #emitted)
        assert.equals(5, emitted[1].pos.row)
        assert.equals(10, emitted[1].pos.col)
    end)

    it("flush is a no-op when nothing is dirty", function()
        local emitted = 0
        local fake = {
            _emit_at = function()
                emitted = emitted + 1
            end,
        }
        render.register(fake, 1, function()
            return pos(1, 1)
        end)
        render.flush() -- emits once (initial)
        assert.equals(1, emitted)
        render.flush() -- no dirty placements, no-op
        assert.equals(1, emitted)
    end)

    it("invalidate without movement does not re-emit", function()
        -- Re-pushing the entire sixel/OSC payload on every CursorMoved
        -- /TextChanged when the placement hasn't actually moved is the
        -- dominant per-keystroke cost. The render loop should clear the
        -- dirty flag and skip emission when the resolved positions match
        -- last_positions.
        local emitted = 0
        local fake = {
            _emit_at = function()
                emitted = emitted + 1
            end,
        }
        render.register(fake, 1, function()
            return pos(1, 1)
        end)
        render.flush() -- initial paint
        assert.equals(1, emitted)
        render.invalidate(fake, 1)
        render.flush()
        assert.equals(1, emitted) -- no re-emit, position unchanged
        -- A second invalidate also does not re-emit.
        render.invalidate(fake, 1)
        render.flush()
        assert.equals(1, emitted)
    end)

    it("invalidate followed by a movement re-emits", function()
        local emitted = 0
        local p = pos(1, 1)
        local fake = {
            _emit_at = function()
                emitted = emitted + 1
            end,
        }
        render.register(fake, 1, function()
            return p
        end)
        render.flush()
        assert.equals(1, emitted)
        p = pos(5, 5)
        render.invalidate(fake, 1)
        render.flush()
        assert.equals(2, emitted)
    end)

    it("unregister stops emitting that placement", function()
        local emitted = 0
        local fake = {
            _emit_at = function()
                emitted = emitted + 1
            end,
        }
        render.register(fake, 1, function()
            return pos(1, 1)
        end)
        render.flush()
        render.unregister(fake, 1)
        render.invalidate(fake, 1) -- harmless on missing placement
        render.flush()
        assert.equals(1, emitted) -- only the initial
    end)

    it("SYNC_START is emitted at the start of a non-empty tick", function()
        local fake = { _emit_at = function() end }
        render.register(fake, 1, function()
            return pos(1, 1)
        end)
        render.flush()
        assert.matches("\027%[%?2026h", H.captured())
    end)

    it("SYNC_END is emitted even when _emit_at throws", function()
        -- If a provider's _emit_at raises, the terminal must not be left
        -- stuck in Mode 2026: SYNC_END has to land before the error
        -- propagates, otherwise the next tick nests a fresh SYNC_START
        -- on top of the still-open frame.
        --
        -- Cleanup discipline: the placement stays registered on rethrow
        -- (tick() rethrows before clearing redraw/last_positions). The
        -- background timer holds a closure over this module's placements
        -- table, so we must (a) unregister, AND (b) gate the throw behind
        -- a flag so any timer callback already queued by vim.schedule_wrap
        -- won't fire `error` after the test asserts have passed.
        local arm_throw = true
        local fake = {
            _emit_at = function()
                if arm_throw then
                    error("provider boom")
                end
            end,
        }
        render.register(fake, 1, function()
            return pos(1, 1)
        end)
        local ok = pcall(render.flush)
        arm_throw = false
        render.unregister(fake, 1)
        assert.is_false(ok)
        local out = H.captured()
        assert.matches("\027%[%?2026h", out)
        assert.matches("\027%[%?2026l", out)
    end)

    it("invalidate of one placement without movement does not disturb peers", function()
        local emitted = { [1] = 0, [2] = 0, [3] = 0 }
        local fake = {
            _emit_at = function(id, _p)
                emitted[id] = (emitted[id] or 0) + 1
            end,
        }
        render.register(fake, 1, function()
            return pos(1, 1)
        end)
        render.register(fake, 2, function()
            return pos(2, 2)
        end)
        render.register(fake, 3, function()
            return pos(3, 3)
        end)
        render.flush() -- initial paint: all three emitted once
        assert.equals(1, emitted[1])
        assert.equals(1, emitted[2])
        assert.equals(1, emitted[3])
        -- Mark only id 1 dirty. Same position -> no movement, no clear, no
        -- re-emit anywhere.
        render.invalidate(fake, 1)
        render.flush()
        assert.equals(1, emitted[1])
        assert.equals(1, emitted[2])
        assert.equals(1, emitted[3])
    end)

    it("position change of an invalidated placement triggers re-emit of all", function()
        local emitted = { [1] = 0, [2] = 0, [3] = 0 }
        local fake = {
            _emit_at = function(id, _p)
                emitted[id] = (emitted[id] or 0) + 1
            end,
        }
        local pos1 = pos(1, 1)
        render.register(fake, 1, function()
            return pos1
        end)
        render.register(fake, 2, function()
            return pos(2, 2)
        end)
        render.register(fake, 3, function()
            return pos(3, 3)
        end)
        render.flush() -- initial paint: all three emitted once
        -- Move id 1 and invalidate. Position-diff should drive a clear, which
        -- re-emits all placements.
        pos1 = pos(9, 9)
        render.invalidate(fake, 1)
        render.flush()
        assert.equals(2, emitted[1])
        assert.equals(2, emitted[2])
        assert.equals(2, emitted[3])
    end)

    it("_build_at runs before SYNC_START; bytes term_send'd after", function()
        -- Two-pass emission: providers that expose _build_at should have it
        -- called *outside* the Mode 2026 sync block, and the returned bytes
        -- term_send'd inside the block. Verify by checking the relative
        -- order of (a) the _build_at callback firing and (b) SYNC_START
        -- hitting nvim_ui_send.
        local events = {}
        local fake = {
            _build_at = function(_, _)
                events[#events + 1] = "build"
                return "PAYLOAD"
            end,
            -- Required by the fallback path; should NOT be called when
            -- _build_at is present.
            _emit_at = function()
                events[#events + 1] = "emit_at"
            end,
        }
        -- Hook nvim_ui_send to record SYNC_START / SYNC_END / payload events.
        local orig_send = vim.api.nvim_ui_send
        vim.api.nvim_ui_send = function(s)
            if s == "\027[?2026h" then
                events[#events + 1] = "sync_start"
            elseif s == "\027[?2026l" then
                events[#events + 1] = "sync_end"
            elseif s == "PAYLOAD" then
                events[#events + 1] = "payload"
            end
            orig_send(s)
        end
        local ok, err = pcall(function()
            render.register(fake, 1, function()
                return pos(1, 1)
            end)
            render.flush()
        end)
        vim.api.nvim_ui_send = orig_send
        assert.is_true(ok, ok and "" or tostring(err))
        -- Required ordering: build → sync_start → payload → sync_end.
        assert.same({ "build", "sync_start", "payload", "sync_end" }, events)
        render.unregister(fake, 1)
    end)

    it("falls back to _emit_at inside sync when provider lacks _build_at", function()
        -- Legacy contract: providers that only expose _emit_at still work.
        -- The emit happens inside the sync block (no pre-build), so the
        -- _emit_at call lands BETWEEN sync_start and sync_end.
        local events = {}
        local fake = {
            _emit_at = function()
                events[#events + 1] = "emit_at"
                vim.api.nvim_ui_send("LEGACY")
            end,
        }
        local orig_send = vim.api.nvim_ui_send
        vim.api.nvim_ui_send = function(s)
            if s == "\027[?2026h" then
                events[#events + 1] = "sync_start"
            elseif s == "\027[?2026l" then
                events[#events + 1] = "sync_end"
            elseif s == "LEGACY" then
                events[#events + 1] = "payload"
            end
            orig_send(s)
        end
        local ok, err = pcall(function()
            render.register(fake, 1, function()
                return pos(1, 1)
            end)
            render.flush()
        end)
        vim.api.nvim_ui_send = orig_send
        assert.is_true(ok, ok and "" or tostring(err))
        -- Fallback ordering: sync_start → emit_at (which sends "payload") → sync_end.
        assert.same({ "sync_start", "emit_at", "payload", "sync_end" }, events)
        render.unregister(fake, 1)
    end)

    it("WinScrolled refreshes w_lines so screenpos-based get_pos works", function()
        -- Regression: with virt_lines extmarks (carrier's relative=buffer
        -- mode), Neovim's WinScrolled autocmd fires before update_screen
        -- recomputes w_lines. screenpos() returns row=0 in that window,
        -- so a get_pos closure that consults it would see "off-screen"
        -- and tick would short-circuit with no emit. mark_all_dirty_and_
        -- flush forces :redraw before tick reads positions, so screenpos
        -- works correctly.
        vim.cmd("enew")
        for i = 1, 50 do
            vim.fn.setline(i, "line " .. i)
        end
        local NS = vim.api.nvim_create_namespace("test-bug2-staleness")
        local virt = {}
        for i = 1, 20 do
            virt[i] = { { "", "Normal" } }
        end
        local mark_id = vim.api.nvim_buf_set_extmark(0, NS, 27, 0, {
            end_row = 28,
            end_col = 0,
            virt_lines = virt,
            virt_lines_above = false,
        })

        vim.fn.cursor(28, 1)
        vim.fn.winrestview({ topline = 23 })
        vim.cmd("redraw")

        local emitted = 0
        local fake = {
            _emit_at = function()
                emitted = emitted + 1
            end,
        }
        -- get_pos consults screenpos — it returns {} when the line is
        -- "off-screen" per stale w_lines.
        render.register(fake, 1, function()
            local sp = vim.fn.screenpos(0, 28, 1)
            if sp.row == 0 then
                return {}
            end
            return { { row = sp.row + 1, col = sp.col, src = { x = 0, y = 0, w = 4, h = 4 } } }
        end)
        render.flush()
        assert.equals(1, emitted)

        -- Change topline WITHOUT calling :redraw. With virt_lines, the
        -- next screenpos call would return row=0 until something forces
        -- update_screen.
        vim.fn.winrestview({ topline = 21 })
        assert.equals(0, vim.fn.screenpos(0, 28, 1).row, "screenpos must be stale to exercise the bug")

        -- Fire WinScrolled. mark_all_dirty_and_flush should run :redraw
        -- before tick, so the get_pos closure sees a fresh non-zero row
        -- and tick emits.
        vim.api.nvim_exec_autocmds("WinScrolled", { group = "alt-img.render" })
        assert.equals(2, emitted)

        render.unregister(fake, 1)
        vim.api.nvim_buf_del_extmark(0, NS, mark_id)
    end)

    it("WinScrolled re-emits even when no placement's position changed", function()
        -- Regression: every scroll triggers nvim to repaint cells the
        -- images overlap (status line, scrolled cells, the float carrier's
        -- empty cells), evicting terminal-side image pixels. Even when
        -- our resolved positions stay identical, we MUST re-emit on
        -- WinScrolled — otherwise the image cells stay blank until
        -- something else (mouse move, layout change) re-triggers emit.
        local emitted = 0
        local fake = {
            _emit_at = function()
                emitted = emitted + 1
            end,
        }
        render.register(fake, 1, function()
            return pos(5, 10)
        end)
        render.flush() -- initial paint
        assert.equals(1, emitted)
        -- Position stays put across WinScrolled; force-mark must re-emit anyway.
        vim.api.nvim_exec_autocmds("WinScrolled", { group = "alt-img.render" })
        assert.equals(2, emitted)
        render.unregister(fake, 1)
    end)

    it("WinScrolled emits synchronously, not on the next timer tick", function()
        -- WinScrolled is on the sync-emit autocmd path: firing it should
        -- re-emit moved placements before the autocmd returns, not wait
        -- up to TICK_MS (30ms) for the timer.
        local emitted = 0
        local fake = {
            _emit_at = function()
                emitted = emitted + 1
            end,
        }
        local pos1 = pos(5, 10)
        render.register(fake, 1, function()
            return pos1
        end)
        render.flush() -- initial paint
        assert.equals(1, emitted)
        -- Move and fire WinScrolled. The handler should mark dirty AND
        -- flush in the same call — observable as the emit count incrementing
        -- before nvim_exec_autocmds returns.
        pos1 = pos(7, 10)
        vim.api.nvim_exec_autocmds("WinScrolled", { group = "alt-img.render" })
        assert.equals(2, emitted)
        render.unregister(fake, 1)
    end)

    it("emits a freshly-registered placement on the first flush", function()
        local emitted = 0
        local fake = {
            _emit_at = function()
                emitted = emitted + 1
            end,
        }
        render.register(fake, 1, function()
            return pos(1, 1)
        end)
        render.flush()
        assert.equals(1, emitted)
    end)

    it("restores vim.o.termsync after a flush", function()
        local before = vim.o.termsync
        local fake = { _emit_at = function() end }
        render.register(fake, 1, function()
            return pos(1, 1)
        end)
        render.flush()
        assert.equals(before, vim.o.termsync)
    end)

    it("refresh re-emits every placement even with unchanged positions", function()
        -- After `:mode` or any external clear, image bytes are gone from the
        -- terminal even though our last_positions still match next_positions.
        -- The position-elision in tick() would skip the re-emit; refresh()
        -- nulls last_positions so the next tick treats every placement as
        -- moved and re-emits the cached payload.
        local emitted = { [1] = 0, [2] = 0 }
        local fake = {
            _emit_at = function(id)
                emitted[id] = (emitted[id] or 0) + 1
            end,
        }
        render.register(fake, 1, function()
            return pos(1, 1)
        end)
        render.register(fake, 2, function()
            return pos(5, 5)
        end)
        render.flush() -- initial paint
        assert.equals(1, emitted[1])
        assert.equals(1, emitted[2])
        -- Mark dirty without movement → no re-emit.
        render.invalidate(fake, 1)
        render.flush()
        assert.equals(1, emitted[1])
        assert.equals(1, emitted[2])
        -- refresh() should re-emit both.
        render.refresh()
        assert.equals(2, emitted[1])
        assert.equals(2, emitted[2])
    end)

    it("_force_all_dirty re-emits even when positions are unchanged", function()
        -- The autocmd group registers _force_all_dirty for events that
        -- correlate with a terminal-side screen wipe (ModeChanged,
        -- CmdlineLeave, WinResized, …). Unlike mark_all_dirty, it nulls
        -- last_positions so the position-equality elision in tick()
        -- always sees "moved" and re-emits — needed to recover after
        -- :AltImg info's hit-enter prompt is dismissed.
        local emitted = 0
        local fake = {
            _emit_at = function()
                emitted = emitted + 1
            end,
        }
        render.register(fake, 1, function()
            return pos(1, 1)
        end)
        render.flush()
        assert.equals(1, emitted)
        -- Same position, plain invalidate: no re-emit (Bug #2 elision).
        render.invalidate(fake, 1)
        render.flush()
        assert.equals(1, emitted)
        -- Force-dirty: re-emit even though position is unchanged.
        render._force_all_dirty()
        render.flush()
        assert.equals(2, emitted)
    end)

    it("emits placements in zindex ascending order", function()
        local order = {}
        local fake = {
            _emit_at = function(id, _)
                order[#order + 1] = id
            end,
            get = function(id)
                return ({ [10] = { zindex = 5 }, [20] = { zindex = 1 }, [30] = { zindex = 3 } })[id]
            end,
        }
        render.register(fake, 10, function()
            return pos(1, 1)
        end)
        render.register(fake, 20, function()
            return pos(2, 2)
        end)
        render.register(fake, 30, function()
            return pos(3, 3)
        end)
        render.flush()
        -- Lowest zindex emits first; highest emits last (so it paints on top).
        assert.same({ 20, 30, 10 }, order)
    end)
end)
