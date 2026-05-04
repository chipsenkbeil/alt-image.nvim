-- test/path_dispatch_spec.lua
-- Mock-based path-verification matrix.
--
-- For every relevant combination of available tools (magick / img2sixel / libz)
-- we drive set() through the real provider code, but with vim.system,
-- vim.fn.executable, and png.has_libz stubbed so no real subprocess runs and
-- the libz code path is observable. Each test asserts which subprocesses
-- fired, in what order, with what argv shape — and which subprocesses did
-- *not* fire. Cached-redraw cases additionally assert that a second emit
-- (forced via render.refresh()) on the same screen_pos triggers zero new
-- subprocesses.

local H = require("test.helpers")

local FIXTURE = (function()
    local f = io.open("test/fixtures/4x4.png", "rb")
    local b = f:read("*a")
    f:close()
    return b
end)()

-- Set up a controlled environment for one test:
--   `tools`  : { magick=true|false, convert=true|false, img2sixel=true|false }
--   `g`      : table assigned to vim.g.alt_img (may set tools to false to disable)
--   `libz`   : true|false   override for png.has_libz
--   `system` : function(cmd, opts) -> { code, stdout } — mock vim.system result
--
-- Returns: provider module (alt-img.sixel|iterm2), `calls` array, and a
-- `restore` function that undoes the mocks. The provider is loaded fresh,
-- so module-level state is clean.
local function with_env(provider_name, tools, g, libz, system)
    local saved = {
        system = vim.system,
        executable = vim.fn.executable,
        g = vim.g.alt_img,
    }

    vim.fn.executable = function(name)
        local v = tools[name]
        if v == true then
            return 1
        end
        if v == false then
            return 0
        end
        return saved.executable(name)
    end

    local calls = {}
    vim.system = function(cmd, opts)
        table.insert(calls, { cmd = cmd, opts = opts })
        local res = (system and system(cmd, opts)) or { code = 0, stdout = "" }
        return {
            wait = function()
                return res
            end,
        }
    end

    -- Force fresh require chain so the new mocks take effect.
    package.loaded["alt-img"] = nil
    package.loaded["alt-img.iterm2"] = nil
    package.loaded["alt-img.sixel"] = nil
    package.loaded["alt-img._core.util"] = nil
    package.loaded["alt-img._core.png"] = nil
    package.loaded["alt-img._core.magick"] = nil
    package.loaded["alt-img._core.render"] = nil
    package.loaded["alt-img._core.carrier"] = nil
    package.loaded["alt-img._core.image"] = nil
    package.loaded["alt-img._core.lru"] = nil
    package.loaded["alt-img._core.config"] = nil
    package.loaded["alt-img.sixel._encode"] = nil
    package.loaded["alt-img.sixel._libsixel"] = nil

    -- Stop any precompute timers leaked from earlier tests, then disable
    -- precompute for this test so its background magick / img2sixel
    -- subprocesses don't pollute the call-counting mock below.
    pcall(function()
        require("alt-img._core.precompute").cancel_all()
    end)
    vim.g.alt_img = vim.tbl_extend("force", g or {}, { precompute_crops = false })
    require("alt-img._core.util")._reset_executable_cache()
    -- Stub png.has_libz before the providers reach for it.
    require("alt-img._core.png").has_libz = function()
        return libz
    end

    H.setup_capture()
    H.reset_capture()

    local mod = require("alt-img." .. provider_name)
    return mod,
        calls,
        function()
            vim.system = saved.system
            vim.fn.executable = saved.executable
            vim.g.alt_img = saved.g
            H.reset_capture()
        end
end

local function any_arg(cmd, want)
    for _, a in ipairs(cmd) do
        if a == want then
            return true
        end
    end
    return false
end

describe("path dispatch — sixel full image", function()
    it("s.full.A: magick+libsixel+libz → exactly 1 magick call, no libsixel", function()
        local sixel, calls, restore = with_env(
            "sixel",
            { magick = true, img2sixel = true },
            {
                magick = "magick",
                img2sixel = "img2sixel",
            },
            true,
            function()
                return { code = 0, stdout = "MAGICK_FULL_SIXEL" }
            end
        )
        local ok, err = pcall(function()
            local id = sixel.set(FIXTURE, { relative = "ui", row = 1, col = 1, width = 4, height = 4 })
            assert.equals(1, #calls, "expected exactly one subprocess on first emit")
            assert.equals("magick", calls[1].cmd[1])
            assert.is_true(any_arg(calls[1].cmd, "sixel:-"), "expected sixel:- output target")
            local saw_sample = false
            for i = 1, #calls[1].cmd - 1 do
                if calls[1].cmd[i] == "-sample" then
                    saw_sample = true
                end
            end
            assert.is_true(saw_sample, "expected -sample (nearest-neighbor) for sharp output")
            assert.is_true(
                H.captured():find("MAGICK_FULL_SIXEL", 1, true) ~= nil,
                "expected canned bytes in TTY output"
            )
            sixel.del(id)
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("s.full.B: libsixel+libz, no magick → libsixel on PNG bytes", function()
        local sixel, calls, restore = with_env(
            "sixel",
            { magick = false, img2sixel = true },
            {
                magick = false,
                img2sixel = "img2sixel",
            },
            true,
            function(cmd)
                if cmd[1] == "img2sixel" then
                    return { code = 0, stdout = "LIBSIXEL_OUT" }
                end
                return { code = 1, stdout = "" }
            end
        )
        local ok, err = pcall(function()
            local id = sixel.set(FIXTURE, { relative = "ui", row = 1, col = 1, width = 4, height = 4 })
            -- Exactly one subprocess, and it's img2sixel reading PNG from stdin.
            assert.equals(1, #calls)
            assert.equals("img2sixel", calls[1].cmd[1])
            assert.is_true(H.captured():find("LIBSIXEL_OUT", 1, true) ~= nil)
            sixel.del(id)
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("s.full.C: nothing on PATH, libz → 0 subprocesses, pure-Lua sixel emitted", function()
        local sixel, calls, restore = with_env("sixel", { magick = false, img2sixel = false }, {
            magick = false,
            img2sixel = false,
        }, true)
        local ok, err = pcall(function()
            local id = sixel.set(FIXTURE, { relative = "ui", row = 1, col = 1, width = 4, height = 4 })
            assert.equals(0, #calls)
            -- Pure-Lua DCS introducer is "\027P...q".
            assert.is_true(H.captured():find("\027P", 1, true) ~= nil)
            sixel.del(id)
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("s.full.D: magick+libsixel, no libz → magick raw-RGBA path (skip PNG hop)", function()
        -- This is the 1770da9 optimization: when libz is missing the encoder
        -- falls back to stored blocks (~4x raw size); magick can read raw
        -- RGBA from stdin and skip the hop. The sixel.lua full-image fast
        -- path runs first (encode_sixel_from_png_resized), so we expect that
        -- to handle the work in one subprocess. The dispatch-level raw-RGBA
        -- branch is exercised in accel_spec where the per-step dispatch is
        -- called directly. Here we just verify the full-image path emits
        -- exactly one magick call total.
        local sixel, calls, restore = with_env(
            "sixel",
            { magick = true, img2sixel = true },
            {
                magick = "magick",
                img2sixel = "img2sixel",
            },
            false,
            function()
                return { code = 0, stdout = "MAGICK_FAST" }
            end
        )
        local ok, err = pcall(function()
            local id = sixel.set(FIXTURE, { relative = "ui", row = 1, col = 1, width = 4, height = 4 })
            assert.equals(1, #calls)
            assert.equals("magick", calls[1].cmd[1])
            sixel.del(id)
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)
end)

describe("path dispatch — sixel cached redraw", function()
    it("s.redraw.full: second emit at same screen_pos does 0 subprocesses", function()
        local sixel, calls, restore = with_env(
            "sixel",
            { magick = true, img2sixel = true },
            {
                magick = "magick",
                img2sixel = "img2sixel",
            },
            true,
            function()
                return { code = 0, stdout = "MAGICK_FULL_SIXEL" }
            end
        )
        local ok, err = pcall(function()
            local id = sixel.set(FIXTURE, { relative = "ui", row = 1, col = 1, width = 4, height = 4 })
            local after_set = #calls
            -- Force a second emit via render.refresh(), which nulls last_positions
            -- so the render scheduler sees a position change and re-emits. The
            -- sixel_cache is populated from the first set(), so no new subprocess
            -- should be spawned.
            H.reset_capture()
            require("alt-img._core.render").refresh()
            assert.equals(after_set, #calls, "second emit must hit s.sixel_cache, not spawn magick")
            -- The captured bytes should still be the canned sixel output.
            assert.is_true(
                H.captured():find("MAGICK_FULL_SIXEL", 1, true) ~= nil,
                "expected cached sixel bytes in second emit"
            )
            sixel.del(id)
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)
end)

describe("path dispatch — iterm2 full image (Bug #1 fast path)", function()
    it("i.full.A: magick+libz → 1 magick call ending in png:-", function()
        local iterm2, calls, restore = with_env(
            "iterm2",
            { magick = true },
            {
                magick = "magick",
            },
            true,
            function()
                return { code = 0, stdout = "MAGICK_RESIZED_PNG" }
            end
        )
        local ok, err = pcall(function()
            local id = iterm2.set(FIXTURE, { relative = "ui", row = 1, col = 1, width = 4, height = 4 })
            assert.equals(1, #calls, "expected exactly one magick subprocess")
            assert.equals("magick", calls[1].cmd[1])
            assert.equals("png:-", calls[1].cmd[#calls[1].cmd], "expected png:- output target")
            local saw_sample = false
            for i = 1, #calls[1].cmd - 1 do
                if calls[1].cmd[i] == "-sample" then
                    saw_sample = true
                end
            end
            assert.is_true(saw_sample, "expected -sample (nearest-neighbor) for sharp output")
            -- Captured emit should be an OSC 1337 with base64(canned bytes).
            local seq = H.captured():match("\027%]1337;[^\007]+\007")
            assert.is_true(seq ~= nil, "expected an OSC 1337 sequence in TTY output")
            local parsed = H.parse_iterm2_seq(seq)
            assert.is_true(parsed ~= nil)
            -- vim.base64.encode of "MAGICK_RESIZED_PNG" should match the payload.
            assert.equals(vim.base64.encode("MAGICK_RESIZED_PNG"), parsed.payload)
            iterm2.del(id)
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("i.full.B: no magick, libz → 0 subprocesses, pure-Lua PNG emitted", function()
        local iterm2, calls, restore = with_env("iterm2", { magick = false }, {
            magick = false,
        }, true)
        local ok, err = pcall(function()
            local id = iterm2.set(FIXTURE, { relative = "ui", row = 1, col = 1, width = 4, height = 4 })
            assert.equals(0, #calls)
            local seq = H.captured():match("\027%]1337;[^\007]+\007")
            assert.is_true(seq ~= nil, "expected OSC 1337 from pure-Lua path")
            local parsed = H.parse_iterm2_seq(seq)
            -- Decoded payload should be a valid PNG (starts with the 8-byte signature).
            local decoded = vim.base64.decode(parsed.payload)
            assert.equals("\137PNG\r\n\26\n", decoded:sub(1, 8))
            iterm2.del(id)
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("i.full.C: no magick, no libz → 0 subprocesses, pure-Lua stored-block PNG", function()
        local iterm2, calls, restore = with_env("iterm2", { magick = false }, {
            magick = false,
        }, false)
        local ok, err = pcall(function()
            local id = iterm2.set(FIXTURE, { relative = "ui", row = 1, col = 1, width = 4, height = 4 })
            assert.equals(0, #calls)
            local seq = H.captured():match("\027%]1337;[^\007]+\007")
            assert.is_true(seq ~= nil)
            -- Output should still be a syntactically valid PNG, just larger.
            local parsed = H.parse_iterm2_seq(seq)
            local decoded = vim.base64.decode(parsed.payload)
            assert.equals("\137PNG\r\n\26\n", decoded:sub(1, 8))
            iterm2.del(id)
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)
end)

describe("path dispatch — iterm2 cached redraw", function()
    it("i.redraw.full: second emit at same screen_pos does 0 subprocesses", function()
        local iterm2, calls, restore = with_env(
            "iterm2",
            { magick = true },
            {
                magick = "magick",
            },
            true,
            function()
                return { code = 0, stdout = "MAGICK_RESIZED_PNG" }
            end
        )
        local ok, err = pcall(function()
            local id = iterm2.set(FIXTURE, { relative = "ui", row = 1, col = 1, width = 4, height = 4 })
            local after_set = #calls
            -- Force a second emit via render.refresh(), which nulls last_positions
            -- so the render scheduler sees a position change and re-emits. The
            -- full_png cache is populated from the first set(), so no new subprocess
            -- should be spawned.
            H.reset_capture()
            require("alt-img._core.render").refresh()
            assert.equals(after_set, #calls, "second emit must hit s.full_png cache, not spawn magick")
            -- The captured bytes should still be the canned PNG output (as OSC 1337).
            local seq = H.captured():match("\027%]1337;[^\007]+\007")
            assert.is_true(seq ~= nil, "expected OSC 1337 sequence in second emit")
            iterm2.del(id)
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)
end)

-- NOTE: The "crop.lru" test was dropped here. It previously exercised the
-- internal sixel_cache_by_src LRU by driving 60 distinct src-rect keys
-- via a now-removed internal helper. After Tasks 7-8, that helper is no
-- longer exported. The per-src-rect LRU property (default size 64, Bug #3)
-- cannot be driven from the public set()/get()/del() surface without faking
-- 60 different physical crop positions — which requires infrastructure (60
-- separate extmarks) disproportionate to the value of an internal-cache
-- assertion. The LRU unit is separately covered by test/lru_spec.lua; the
-- accel integration tests in accel_spec.lua cover the subprocess-dispatch
-- paths that produce the cached values.

-- Restore deterministic defaults for any later specs that share the alt-img config.
describe("path dispatch cleanup", function()
    it("leaves magick=false, img2sixel=false for subsequent specs", function()
        vim.g.alt_img = { magick = false, img2sixel = false }
        assert.equals(false, (vim.g.alt_img or {}).magick)
        assert.equals(false, (vim.g.alt_img or {}).img2sixel)
    end)
end)
