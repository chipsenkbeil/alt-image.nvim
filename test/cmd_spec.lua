-- test/cmd_spec.lua
-- Coverage for the production `:AltImg` user command (lua/alt-img/_cmd.lua).
-- We verify dispatch routing, completion behavior, and that info_lines()
-- returns a non-empty diagnostic dump even when vim.ui.img isn't set.

local function fresh_cmd()
    package.loaded["alt-img._cmd"] = nil
    return require("alt-img._cmd")
end

local function with_notify_capture(fn)
    local saved = vim.notify
    local seen = {}
    vim.notify = function(msg, level, _opts)
        seen[#seen + 1] = { msg = msg, level = level }
    end
    local ok, err = pcall(fn, seen)
    vim.notify = saved
    if not ok then
        error(err, 0)
    end
end

describe("alt-img._cmd dispatch", function()
    it("known subcommand is invoked with the args after the subcommand name", function()
        local cmd = fresh_cmd()
        local got
        cmd.subcommands.fake = {
            impl = function(args, opts)
                got = { args = args, opts = opts }
            end,
        }
        cmd.dispatch({ fargs = { "fake", "a", "b" } })
        cmd.subcommands.fake = nil
        assert.same({ "a", "b" }, got.args)
    end)

    it("missing subcommand surfaces a usage hint via vim.notify", function()
        local cmd = fresh_cmd()
        with_notify_capture(function(seen)
            cmd.dispatch({ fargs = {} })
            assert.is_true(#seen >= 1)
            assert.matches("Usage: :AltImg", seen[1].msg)
        end)
    end)

    it("unknown subcommand notifies an error and lists known names", function()
        local cmd = fresh_cmd()
        with_notify_capture(function(seen)
            cmd.dispatch({ fargs = { "definitely-not-a-subcommand" } })
            assert.is_true(#seen >= 1)
            assert.matches("unknown subcommand", seen[1].msg)
            assert.matches("info", seen[1].msg)
            assert.matches("refresh", seen[1].msg)
            assert.equals(vim.log.levels.ERROR, seen[1].level)
        end)
    end)
end)

describe("alt-img._cmd completion", function()
    it("returns matching subcommand names when the user is still typing", function()
        local cmd = fresh_cmd()
        local out = cmd.complete("in", "AltImg in", #"AltImg in")
        assert.same({ "info" }, out)
    end)

    it("returns all subcommands when the lead is empty", function()
        local cmd = fresh_cmd()
        local out = cmd.complete("", "AltImg ", #"AltImg ")
        -- Sorted: info, refresh
        assert.same(cmd.subcommand_names(), out)
    end)

    it("returns empty when the subcommand is locked in and has no completions", function()
        local cmd = fresh_cmd()
        local out = cmd.complete("", "AltImg info ", #"AltImg info ")
        assert.same({}, out)
    end)

    it("delegates to the subcommand's complete callback when present", function()
        local cmd = fresh_cmd()
        cmd.subcommands.fake = {
            impl = function() end,
            complete = function(_lead)
                return { "alpha", "beta" }
            end,
        }
        local out = cmd.complete("", "AltImg fake ", #"AltImg fake ")
        cmd.subcommands.fake = nil
        assert.same({ "alpha", "beta" }, out)
    end)
end)

describe("alt-img._cmd info", function()
    it("info_lines() returns a non-empty diagnostic dump", function()
        local cmd = fresh_cmd()
        local lines = cmd.info_lines()
        assert.is_true(#lines > 5)
        -- Spot-check the headers we promise users will see.
        local joined = table.concat(lines, "\n")
        assert.matches("alt%-img.nvim diagnostics", joined)
        assert.matches("Terminal env", joined)
        assert.matches("Cell pixel size", joined)
        assert.matches("scale via OSC 1337", joined)
        assert.matches("scale via CSI 14t/18t/16t", joined)
        assert.matches("scale actually used", joined)
        assert.matches("Active placements", joined)
    end)

    it("info_lines() handles vim.ui.img being unset", function()
        local saved = vim.ui.img
        vim.ui.img = nil
        local cmd = fresh_cmd()
        local ok, err = pcall(function()
            local lines = cmd.info_lines()
            assert.is_true(#lines > 0)
            assert.matches("vim.ui.img not set", table.concat(lines, "\n"))
        end)
        vim.ui.img = saved
        if not ok then
            error(err, 0)
        end
    end)
end)

describe("alt-img._cmd refresh", function()
    it("calls vim.ui.img.refresh() when available", function()
        local cmd = fresh_cmd()
        local saved = vim.ui.img
        local called = false
        vim.ui.img = {
            refresh = function()
                called = true
            end,
        }
        cmd.dispatch({ fargs = { "refresh" } })
        vim.ui.img = saved
        assert.is_true(called)
    end)

    it("notifies a warning when vim.ui.img has no refresh()", function()
        local cmd = fresh_cmd()
        local saved = vim.ui.img
        vim.ui.img = {} -- no refresh function
        with_notify_capture(function(seen)
            cmd.dispatch({ fargs = { "refresh" } })
            vim.ui.img = saved
            assert.is_true(#seen >= 1)
            assert.matches("refresh", seen[1].msg)
            assert.equals(vim.log.levels.WARN, seen[1].level)
        end)
    end)
end)
