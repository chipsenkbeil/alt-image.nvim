-- test/benchmark.lua
-- Real-system benchmark for the dispatch matrix. Spawns real magick /
-- img2sixel subprocesses and uses real libz where available.
--
-- Each case lists its required tools; missing tools mark the case as SKIP
-- rather than failing the run. Output is a Markdown table written to
-- test/benchmark.out.md and printed to stdout.
--
-- Usage:
--   make benchmark                          -- default fixture
--   make benchmark FIXTURE=/path/to.png     -- override
--
-- The default fixture is ~/Pictures/org-roam-logo.png; falls back to the
-- vendored test/fixtures/org-roam-logo.png if the user's home copy is
-- missing.

io.stdout:setvbuf("line")

local cwd = vim.uv.cwd()
vim.opt.runtimepath:prepend(cwd)
package.path = cwd .. "/?.lua;" .. cwd .. "/?/init.lua;" .. package.path

-- ----------------------------------------------------------------------
-- Fixture resolution
-- ----------------------------------------------------------------------
local function read_file(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local data = f:read("*a")
    f:close()
    return data
end

local fixture_path = os.getenv("FIXTURE")
if not fixture_path or fixture_path == "" then
    local home = os.getenv("HOME") or ""
    local candidates = {
        home .. "/Pictures/org-roam-logo.png",
        cwd .. "/test/fixtures/org-roam-logo.png",
    }
    for _, p in ipairs(candidates) do
        if read_file(p) then
            fixture_path = p
            break
        end
    end
end
local fixture_data = fixture_path and read_file(fixture_path)
if not fixture_data then
    io.stderr:write("benchmark: no fixture found; pass FIXTURE=/path/to.png\n")
    os.exit(1)
end

-- ----------------------------------------------------------------------
-- Capture + monitor wrappers
-- ----------------------------------------------------------------------
local _saved_ui_send = vim.api.nvim_ui_send
local _captured_bytes = 0
local function capture_install()
    _captured_bytes = 0
    vim.api.nvim_ui_send = function(s)
        _captured_bytes = _captured_bytes + #s
    end
end
local function capture_uninstall()
    vim.api.nvim_ui_send = _saved_ui_send
end

local _saved_system = vim.system
local _sys_count = 0
local function counted_system_install()
    _sys_count = 0
    vim.system = function(cmd, opts)
        _sys_count = _sys_count + 1
        return _saved_system(cmd, opts)
    end
end
local function counted_system_uninstall()
    vim.system = _saved_system
end

-- ----------------------------------------------------------------------
-- libz toggle (monkey-patches ffi.load to fail; only png.lua reaches for
-- it, so other FFI users keep working).
-- ----------------------------------------------------------------------
local _ffi = require("ffi")
local _saved_ffi_load = _ffi.load
local function disable_libz()
    _ffi.load = function(name)
        error("libz disabled for benchmark: ffi.load(" .. tostring(name) .. ")")
    end
end
local function enable_libz()
    _ffi.load = _saved_ffi_load
end

-- ----------------------------------------------------------------------
-- Fresh module loader. Reloads all alt-img modules under the given env so
-- detection runs from scratch.
-- ----------------------------------------------------------------------
local function fresh(provider_name, g_alt_img, no_libz)
    -- Stop any previous render timer before unloading; otherwise the timer
    -- keeps firing tick() against now-stale state.
    local old_render = package.loaded["alt-img._core.render"]
    if old_render and old_render._timer then
        pcall(function()
            old_render._timer:stop()
            old_render._timer:close()
        end)
    end

    for k, _ in pairs(package.loaded) do
        if k:match("^alt%-img") then
            package.loaded[k] = nil
        end
    end
    vim.g.alt_img = g_alt_img or {}
    if no_libz then
        disable_libz()
    else
        enable_libz()
    end
    -- png.lua decides libz at require time, so it must be required AFTER
    -- the ffi.load patch is in place.
    local png = require("alt-img._core.png")
    require("alt-img._core.util")._reset_executable_cache()
    -- Stop the new render timer too — vim.system():wait() yields the event
    -- loop, and a tick mid-wait would spawn extra subprocesses inside our
    -- timing window. The benchmark drives _emit_at directly.
    local render = require("alt-img._core.render")
    if render._timer then
        pcall(function()
            render._timer:stop()
        end)
    end
    return require("alt-img." .. provider_name), png
end

-- ----------------------------------------------------------------------
-- Stats
-- ----------------------------------------------------------------------
local function median_mad(xs)
    local s = {}
    for i, v in ipairs(xs) do
        s[i] = v
    end
    table.sort(s)
    local mid = math.floor(#s / 2) + 1
    local med = s[mid]
    local devs = {}
    for i, v in ipairs(s) do
        devs[i] = math.abs(v - med)
    end
    table.sort(devs)
    local mad = devs[math.floor(#devs / 2) + 1]
    return med, mad
end

local function hrtime_ms()
    return tonumber(vim.uv.hrtime()) / 1e6
end

-- ----------------------------------------------------------------------
-- Benchmark cases
-- ----------------------------------------------------------------------
local OPTS_FULL = { relative = "ui", row = 1, col = 1, width = 80, height = 30 }
local SCREEN_FULL = { row = 1, col = 1, src = { x = 0, y = 0, w = 80, h = 30 } }
local SCREEN_CROP = { row = 1, col = 1, src = { x = 10, y = 5, w = 40, h = 15 } }

local CASES = {
    {
        tag = "s.full.magick",
        provider = "sixel",
        g = { magick = "magick", img2sixel = false },
        requires = { "magick" },
        screen_pos = SCREEN_FULL,
    },
    {
        tag = "s.full.libsixel",
        provider = "sixel",
        g = { magick = false, img2sixel = "img2sixel" },
        requires = { "img2sixel" },
        screen_pos = SCREEN_FULL,
    },
    {
        tag = "s.full.lua_libz",
        provider = "sixel",
        g = { magick = false, img2sixel = false },
        screen_pos = SCREEN_FULL,
    },
    {
        tag = "s.full.lua_no_libz",
        provider = "sixel",
        g = { magick = false, img2sixel = false },
        no_libz = true,
        screen_pos = SCREEN_FULL,
    },
    {
        tag = "s.full.magick_no_libz",
        provider = "sixel",
        g = { magick = "magick", img2sixel = false },
        no_libz = true,
        requires = { "magick" },
        screen_pos = SCREEN_FULL,
    },
    {
        tag = "s.crop.magick",
        provider = "sixel",
        g = { magick = "magick", img2sixel = false },
        requires = { "magick" },
        screen_pos = SCREEN_CROP,
    },
    {
        tag = "s.crop.lua",
        provider = "sixel",
        g = { magick = false, img2sixel = false },
        screen_pos = SCREEN_CROP,
    },
    {
        tag = "i.full.magick",
        provider = "iterm2",
        g = { magick = "magick" },
        requires = { "magick" },
        screen_pos = SCREEN_FULL,
    },
    { tag = "i.full.libz", provider = "iterm2", g = { magick = false }, screen_pos = SCREEN_FULL },
    {
        tag = "i.full.no_libz",
        provider = "iterm2",
        g = { magick = false },
        no_libz = true,
        screen_pos = SCREEN_FULL,
    },
    {
        tag = "i.crop.magick",
        provider = "iterm2",
        g = { magick = "magick" },
        requires = { "magick" },
        screen_pos = SCREEN_CROP,
    },
    { tag = "i.crop.lua", provider = "iterm2", g = { magick = false }, screen_pos = SCREEN_CROP },
}

local N = 5
local WARMUP = 2

-- ----------------------------------------------------------------------
-- Per-case driver
-- ----------------------------------------------------------------------
local function check_skip(case)
    for _, tool in ipairs(case.requires or {}) do
        if vim.fn.executable(tool) ~= 1 then
            return "missing " .. tool
        end
    end
    return nil
end

local function run_case(case)
    local skip = check_skip(case)
    if skip then
        return { tag = case.tag, skip = skip }
    end

    -- We measure the cold path as: fresh placement state + first _emit_at.
    -- We measure warm as a second _emit_at on the same screen_pos (cache hit).
    -- subprocess_count and payload_bytes come from the cold run.

    capture_install()
    counted_system_install()

    local cold_times = {}
    local warm_ms, sub_count, payload_bytes = nil, nil, nil

    local function one_iter()
        local provider = fresh(case.provider, case.g, case.no_libz)
        -- Suppress the synchronous initial paint inside set() so we can
        -- isolate the first _emit_at. Easiest way: temporarily replace
        -- render.flush with a no-op, then call _emit_at directly.
        local render = require("alt-img._core.render")
        local saved_flush = render.flush
        render.flush = function() end

        local id = provider.set(fixture_data, OPTS_FULL)
        _captured_bytes = 0
        _sys_count = 0

        local t0 = hrtime_ms()
        provider._emit_at(id, case.screen_pos)
        local t1 = hrtime_ms()

        local cold_payload = _captured_bytes
        local cold_subs = _sys_count
        _captured_bytes = 0
        _sys_count = 0

        -- Warm: same screen_pos again.
        local w0 = hrtime_ms()
        provider._emit_at(id, case.screen_pos)
        local w1 = hrtime_ms()

        provider.del(id)
        render.flush = saved_flush
        return (t1 - t0), (w1 - w0), cold_subs, cold_payload
    end

    -- Warmup runs (discarded) so JIT / dyld / disk caches stabilize.
    for _ = 1, WARMUP do
        one_iter()
    end

    for i = 1, N do
        local cold, warm, subs, payload = one_iter()
        cold_times[i] = cold
        if i == 1 then
            warm_ms = warm
            sub_count = subs
            payload_bytes = payload
        end
    end

    counted_system_uninstall()
    capture_uninstall()
    enable_libz() -- always restore even if a case forced it off

    local cold_med, cold_mad = median_mad(cold_times)
    return {
        tag = case.tag,
        cold_ms = cold_med,
        cold_mad = cold_mad,
        warm_ms = warm_ms,
        subprocess_count = sub_count,
        payload_bytes = payload_bytes,
    }
end

-- ----------------------------------------------------------------------
-- Output
-- ----------------------------------------------------------------------
local function format_row(r)
    if r.skip then
        return string.format("| `%s` | SKIP — %s | | | | |", r.tag, r.skip)
    end
    return string.format(
        "| `%s` | %.2f ± %.2f | %.2f | %d | %d | |",
        r.tag,
        r.cold_ms,
        r.cold_mad,
        r.warm_ms,
        r.subprocess_count,
        r.payload_bytes
    )
end

local results = {}
print(string.format("# alt-img.nvim benchmark"))
print(string.format("fixture: %s (%d bytes)", fixture_path, #fixture_data))
print(string.format("iterations: N=%d (after %d-iter warmup)", N, WARMUP))
print()

local rows = { "| tag | cold ms (med ± mad) | warm ms | subprocesses | payload bytes | notes |" }
rows[#rows + 1] = "|---|---|---|---|---|---|"
for _, case in ipairs(CASES) do
    print("# " .. case.tag)
    local r = run_case(case)
    results[#results + 1] = r
    rows[#rows + 1] = format_row(r)
    print(rows[#rows])
end

print()
print(table.concat(rows, "\n"))

-- Persist for README inclusion.
local out_path = cwd .. "/test/benchmark.out.md"
local fh = io.open(out_path, "w")
fh:write("<!-- auto-generated by `make benchmark`; do not hand-edit -->\n")
fh:write(string.format("fixture: %s (%d bytes)\n", fixture_path, #fixture_data))
fh:write(string.format("iterations: N=%d (after %d-iter warmup)\n\n", N, WARMUP))
fh:write(table.concat(rows, "\n"))
fh:write("\n")
fh:close()
print()
print("wrote " .. out_path)

os.exit(0)
