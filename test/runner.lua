-- alt-img test runner. Discovers describe/it/harness blocks across the
-- test/unit and test/e2e trees, executes them, and reports pass/fail with
-- timing. Run via:
--   nvim --headless -l test/runner.lua [filter] [--unit|--e2e]
-- Filter is a Lua pattern matched against suite_name .. ":" .. block_name.

vim.opt.runtimepath:prepend(vim.uv.cwd())

local Assert = require("test.assert")
local Harness = require("test.harness")

local args = arg or {}
local filter, only_unit, only_e2e
for _, a in ipairs(args) do
    if a == "--unit" then
        only_unit = true
    elseif a == "--e2e" then
        only_e2e = true
    elseif a:sub(1, 2) ~= "--" then
        filter = a
    end
end

-- Collected blocks: { suite_name, type = "it"|"harness", name, fn }
local blocks = {}
local current_suite

local env = setmetatable({
    describe = function(name, fn)
        current_suite = name
        local ok, err = pcall(fn)
        current_suite = nil
        if not ok then
            io.stderr:write("ERROR loading describe '" .. name .. "': " .. tostring(err) .. "\n")
        end
    end,
    it = function(name, fn)
        blocks[#blocks + 1] = {
            suite = current_suite or "(no suite)",
            type = "it",
            name = name,
            fn = fn,
        }
    end,
    harness = function(name, fn)
        blocks[#blocks + 1] = {
            suite = current_suite or "(no suite)",
            type = "harness",
            name = name,
            -- Pass a fresh ctx wrapper so each harness block gets its
            -- own spawn helper. Block decides when to spawn / close.
            fn = function()
                local nvims = {}
                local ctx = {
                    spawn = function(_, opts)
                        local n = Harness.spawn(opts)
                        nvims[#nvims + 1] = n
                        return n
                    end,
                }
                local ok, err = pcall(fn, ctx)
                for _, n in ipairs(nvims) do
                    pcall(n.close, n)
                end
                if not ok then
                    error(err, 0)
                end
            end,
        }
    end,
    assert = Assert,
}, { __index = _G })

local function load_file(path)
    local chunk, err = loadfile(path)
    if not chunk then
        io.stderr:write("ERROR loading " .. path .. ": " .. tostring(err) .. "\n")
        return
    end
    if setfenv then
        setfenv(chunk, env)
    end
    local ok, run_err = pcall(chunk)
    if not ok then
        io.stderr:write("ERROR running " .. path .. ": " .. tostring(run_err) .. "\n")
    end
end

local function load_dir(dir)
    local handle = io.popen('find "' .. dir .. '" -name "*.lua" -type f 2>/dev/null | sort')
    if not handle then
        return
    end
    for path in handle:lines() do
        load_file(path)
    end
    handle:close()
end

if not only_e2e then
    load_dir("test/unit")
end
if not only_unit then
    load_dir("test/e2e")
end

-- Filter
local filtered = {}
for _, b in ipairs(blocks) do
    local label = b.suite .. ":" .. b.name
    if not filter or label:find(filter) then
        filtered[#filtered + 1] = b
    end
end

-- Execute
local pass = 0
local fail = 0
local failures = {}
local started_ns = vim.uv.hrtime()

for _, b in ipairs(filtered) do
    local label = string.format("[%s] %s :: %s", b.type, b.suite, b.name)
    local t0 = vim.uv.hrtime()
    local ok, err = pcall(b.fn)
    local elapsed_ms = (vim.uv.hrtime() - t0) / 1e6
    if ok then
        pass = pass + 1
        io.stdout:write(string.format("ok   %s (%.1fms)\n", label, elapsed_ms))
    else
        fail = fail + 1
        failures[#failures + 1] = { label = label, err = err }
        io.stdout:write(string.format("FAIL %s (%.1fms)\n      %s\n", label, elapsed_ms, tostring(err)))
    end
    io.stdout:flush()
end

local total_ms = (vim.uv.hrtime() - started_ns) / 1e6

io.stdout:write(string.format("\n%d passed, %d failed in %.0fms (%d total)\n", pass, fail, total_ms, #filtered))

if fail > 0 then
    io.stdout:write("\nFailed:\n")
    for _, f in ipairs(failures) do
        io.stdout:write("  " .. f.label .. "\n")
        io.stdout:write("    " .. tostring(f.err) .. "\n")
    end
    io.stdout:flush()
    os.exit(1)
end
io.stdout:flush()
os.exit(0)
