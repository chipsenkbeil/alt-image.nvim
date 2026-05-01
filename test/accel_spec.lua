-- test/accel_spec.lua
-- Tests for the external-tool dispatchers in sixel/_encode.lua and
-- _core/magick.lua, plus the vim.g.alt_img.magick / img2sixel
-- binary-resolution semantics. We mock vim.system + vim.fn.executable so no
-- real subprocess ever runs.

local H = require("test.helpers")

-- Stand up a controlled environment for one test:
-- - executable_for: { [name]=true|false } overrides for vim.fn.executable
-- - system_handler: function(cmd, opts) -> { code, stdout } (or nil to error)
-- - g_alt_img:    table assigned to vim.g.alt_img
-- Returns the fresh _sixel_encode module + a `calls` array recording each
-- vim.system invocation as { cmd = {...}, opts = {...} }.
local function with_mocks(executable_for, system_handler, g_alt_img)
    local saved_system = vim.system
    local saved_executable = vim.fn.executable
    local saved_g = vim.g.alt_img

    vim.fn.executable = function(name)
        local v = executable_for[name]
        if v == true then
            return 1
        end
        if v == false then
            return 0
        end
        return saved_executable(name)
    end

    local calls = {}
    vim.system = function(cmd, opts)
        table.insert(calls, { cmd = cmd, opts = opts })
        local res = system_handler and system_handler(cmd, opts) or { code = 0, stdout = "" }
        return {
            wait = function()
                return res
            end,
        }
    end

    -- Force fresh module loads so the mocks take effect through cached
    -- requires inside the dispatchers.
    package.loaded["alt-img"] = nil
    package.loaded["alt-img._core.util"] = nil
    package.loaded["alt-img._core.png"] = nil
    package.loaded["alt-img._core.magick"] = nil
    package.loaded["alt-img.sixel._encode"] = nil
    package.loaded["alt-img.sixel._libsixel"] = nil
    vim.g.alt_img = g_alt_img
    local senc = require("alt-img.sixel._encode")
    -- Belt-and-suspenders: clear the executable cache.
    require("alt-img._core.util")._reset_executable_cache()

    return senc,
        calls,
        function()
            vim.system = saved_system
            vim.fn.executable = saved_executable
            vim.g.alt_img = saved_g
        end
end

describe("_magick.binary()", function()
    local function fresh_magick(executable_for, g_alt_img)
        package.loaded["alt-img._core.util"] = nil
        package.loaded["alt-img._core.magick"] = nil
        local saved_executable = vim.fn.executable
        local saved_g = vim.g.alt_img
        vim.fn.executable = function(name)
            local v = executable_for[name]
            if v == true then
                return 1
            end
            if v == false then
                return 0
            end
            return saved_executable(name)
        end
        vim.g.alt_img = g_alt_img
        require("alt-img._core.util")._reset_executable_cache()
        return require("alt-img._core.magick"),
            function()
                vim.fn.executable = saved_executable
                vim.g.alt_img = saved_g
            end
    end

    it("returns nil when magick = false", function()
        local m, restore = fresh_magick({ magick = true, convert = true }, { magick = false })
        local ok, err = pcall(function()
            assert.is_nil(m.binary())
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("uses the configured string when executable", function()
        local m, restore = fresh_magick({ magick = true }, { magick = "magick" })
        local ok, err = pcall(function()
            assert.equals("magick", m.binary())
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("returns nil when configured string is not executable", function()
        local m, restore = fresh_magick({ ["gm-bogus"] = false }, { magick = "gm-bogus" })
        local ok, err = pcall(function()
            assert.is_nil(m.binary())
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("auto-detects magick first when nil/unset", function()
        local m, restore = fresh_magick({ magick = true, convert = true }, {})
        local ok, err = pcall(function()
            assert.equals("magick", m.binary())
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("falls back to convert when magick is missing", function()
        local m, restore = fresh_magick({ magick = false, convert = true }, {})
        local ok, err = pcall(function()
            assert.equals("convert", m.binary())
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("returns nil when neither magick nor convert is on PATH", function()
        local m, restore = fresh_magick({ magick = false, convert = false }, {})
        local ok, err = pcall(function()
            assert.is_nil(m.binary())
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("accepts a list and uses the first executable candidate", function()
        local m, restore = fresh_magick({ magick = false, convert = true }, { magick = { "magick", "convert" } })
        local ok, err = pcall(function()
            assert.equals("convert", m.binary())
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("returns nil when no list candidate is executable", function()
        local m, restore = fresh_magick(
            { ["gm-bogus"] = false, ["mogrify"] = false },
            { magick = { "gm-bogus", "mogrify" } }
        )
        local ok, err = pcall(function()
            assert.is_nil(m.binary())
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("skips non-executable candidates earlier in the list", function()
        local m, restore = fresh_magick(
            { ["gm-bogus"] = false, magick = true, convert = true },
            { magick = { "gm-bogus", "magick", "convert" } }
        )
        local ok, err = pcall(function()
            assert.equals("magick", m.binary())
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("returns nil for an empty list", function()
        local m, restore = fresh_magick({ magick = true, convert = true }, { magick = {} })
        local ok, err = pcall(function()
            assert.is_nil(m.binary())
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)
end)

describe("_libsixel.binary()", function()
    local function fresh_libsixel(executable_for, g_alt_img)
        package.loaded["alt-img._core.util"] = nil
        package.loaded["alt-img.sixel._libsixel"] = nil
        local saved_executable = vim.fn.executable
        local saved_g = vim.g.alt_img
        vim.fn.executable = function(name)
            local v = executable_for[name]
            if v == true then
                return 1
            end
            if v == false then
                return 0
            end
            return saved_executable(name)
        end
        vim.g.alt_img = g_alt_img
        require("alt-img._core.util")._reset_executable_cache()
        return require("alt-img.sixel._libsixel"),
            function()
                vim.fn.executable = saved_executable
                vim.g.alt_img = saved_g
            end
    end

    it("returns nil when img2sixel = false", function()
        local m, restore = fresh_libsixel({ img2sixel = true }, { img2sixel = false })
        local ok, err = pcall(function()
            assert.is_nil(m.binary())
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("uses the configured string when executable", function()
        local m, restore = fresh_libsixel({ img2sixel = true }, { img2sixel = "img2sixel" })
        local ok, err = pcall(function()
            assert.equals("img2sixel", m.binary())
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("returns nil when configured string is not executable", function()
        local m, restore = fresh_libsixel({ ["notreal"] = false }, { img2sixel = "notreal" })
        local ok, err = pcall(function()
            assert.is_nil(m.binary())
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("auto-detects img2sixel when nil/unset", function()
        local m, restore = fresh_libsixel({ img2sixel = true }, {})
        local ok, err = pcall(function()
            assert.equals("img2sixel", m.binary())
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("returns nil when img2sixel is not on PATH", function()
        local m, restore = fresh_libsixel({ img2sixel = false }, {})
        local ok, err = pcall(function()
            assert.is_nil(m.binary())
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("accepts a list and uses the first executable candidate", function()
        local m, restore = fresh_libsixel(
            { ["libsixel-img2sixel"] = false, img2sixel = true },
            { img2sixel = { "libsixel-img2sixel", "img2sixel" } }
        )
        local ok, err = pcall(function()
            assert.equals("img2sixel", m.binary())
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)
end)

describe("encode_sixel_dispatch", function()
    -- A trivial 1x1 fully-opaque red RGBA pixel.
    local rgba = string.char(255, 0, 0, 255)

    it("uses img2sixel when configured and available", function()
        local senc, calls, restore = with_mocks({ img2sixel = true, magick = false, convert = false }, function()
            return { code = 0, stdout = "FAKE_SIXEL_FROM_IMG2SIXEL" }
        end, { magick = false, img2sixel = "img2sixel" })
        local ok, err = pcall(function()
            local out = senc.encode_sixel_dispatch(rgba, 1, 1)
            assert.equals("FAKE_SIXEL_FROM_IMG2SIXEL", out)
            assert.equals(1, #calls)
            assert.equals("img2sixel", calls[1].cmd[1])
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("falls through to magick when img2sixel is disabled", function()
        local senc, calls, restore = with_mocks({ img2sixel = true, magick = true }, function()
            return { code = 0, stdout = "FAKE_SIXEL_FROM_MAGICK" }
        end, { img2sixel = false, magick = "magick" })
        local ok, err = pcall(function()
            local out = senc.encode_sixel_dispatch(rgba, 1, 1)
            assert.equals("FAKE_SIXEL_FROM_MAGICK", out)
            assert.equals(1, #calls)
            assert.equals("magick", calls[1].cmd[1])
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("uses convert when configured", function()
        local senc, calls, restore = with_mocks({ img2sixel = false, magick = false, convert = true }, function()
            return { code = 0, stdout = "FAKE_SIXEL_FROM_CONVERT" }
        end, { img2sixel = false, magick = "convert" })
        local ok, err = pcall(function()
            local out = senc.encode_sixel_dispatch(rgba, 1, 1)
            assert.equals("FAKE_SIXEL_FROM_CONVERT", out)
            assert.equals(1, #calls)
            assert.equals("convert", calls[1].cmd[1])
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("uses pure Lua when both tools are disabled", function()
        local senc, calls, restore = with_mocks({ img2sixel = true, magick = true, convert = true }, function()
            return { code = 0, stdout = "SHOULD_NOT_BE_USED" }
        end, { img2sixel = false, magick = false })
        local ok, err = pcall(function()
            local out = senc.encode_sixel_dispatch(rgba, 1, 1)
            assert.equals(0, #calls)
            -- Pure-Lua output starts with the DCS introducer.
            assert.matches("^\027Pq", out)
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("falls back to magick when img2sixel returns non-zero", function()
        local senc, calls, restore = with_mocks({ img2sixel = true, magick = true }, function(cmd)
            if cmd[1] == "img2sixel" then
                return { code = 1, stdout = "" }
            end
            return { code = 0, stdout = "FAKE_SIXEL_FROM_MAGICK" }
        end, { img2sixel = "img2sixel", magick = "magick" })
        local ok, err = pcall(function()
            local out = senc.encode_sixel_dispatch(rgba, 1, 1)
            assert.equals("FAKE_SIXEL_FROM_MAGICK", out)
            assert.equals(2, #calls)
            assert.equals("img2sixel", calls[1].cmd[1])
            assert.equals("magick", calls[2].cmd[1])
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("falls back to pure Lua when both tools fail", function()
        local senc, calls, restore = with_mocks({ img2sixel = true, magick = true }, function()
            return { code = 1, stdout = "" }
        end, { img2sixel = "img2sixel", magick = "magick" })
        local ok, err = pcall(function()
            local out = senc.encode_sixel_dispatch(rgba, 1, 1)
            assert.equals(2, #calls)
            assert.matches("^\027Pq", out)
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("falls back to pure Lua when neither tool is installed", function()
        local senc, calls, restore = with_mocks({ img2sixel = false, magick = false, convert = false }, function()
            return { code = 0, stdout = "NEVER" }
        end, {})
        local ok, err = pcall(function()
            local out = senc.encode_sixel_dispatch(rgba, 1, 1)
            assert.equals(0, #calls)
            assert.matches("^\027Pq", out)
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("prefers magick raw-RGBA when libz is missing", function()
        local senc, calls, restore = with_mocks({ img2sixel = true, magick = true }, function()
            return { code = 0, stdout = "RGBA_FAST_PATH" }
        end, { img2sixel = "img2sixel", magick = "magick" })
        -- Stub libz absence so the new short-circuit fires regardless of host.
        require("alt-img._core.png").has_libz = function()
            return false
        end
        local ok, err = pcall(function()
            local out = senc.encode_sixel_dispatch(rgba, 1, 1)
            assert.equals("RGBA_FAST_PATH", out)
            -- Single magick call with -size/-depth/RGBA:- args; img2sixel is skipped.
            assert.equals(1, #calls)
            local cmd = calls[1].cmd
            assert.equals("magick", cmd[1])
            local saw_rgba_input = false
            for _, a in ipairs(cmd) do
                if a == "RGBA:-" then
                    saw_rgba_input = true
                end
            end
            assert.is_true(saw_rgba_input, "expected magick to read RGBA:- from stdin")
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("falls through to PNG paths when raw-RGBA magick fails (no libz)", function()
        local senc, calls, restore = with_mocks({ img2sixel = true, magick = true }, function(cmd)
            -- First call: magick raw-RGBA (has RGBA:- arg) -> fail.
            for _, a in ipairs(cmd) do
                if a == "RGBA:-" then
                    return { code = 1, stdout = "" }
                end
            end
            -- Subsequent calls: img2sixel or magick from PNG -> succeed.
            if cmd[1] == "img2sixel" then
                return { code = 0, stdout = "PNG_LIBSIXEL" }
            end
            return { code = 0, stdout = "PNG_MAGICK" }
        end, { img2sixel = "img2sixel", magick = "magick" })
        require("alt-img._core.png").has_libz = function()
            return false
        end
        local ok, err = pcall(function()
            local out = senc.encode_sixel_dispatch(rgba, 1, 1)
            -- Raw-RGBA magick failed, then img2sixel succeeds with the PNG hop.
            assert.equals("PNG_LIBSIXEL", out)
            assert.equals(2, #calls)
            assert.equals("magick", calls[1].cmd[1])
            assert.equals("img2sixel", calls[2].cmd[1])
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)
end)

describe("magick.encode_sixel_from_rgba", function()
    -- One pixel of RGBA so the buffer length is meaningful in assertions.
    local rgba = string.char(255, 0, 0, 255)

    it("invokes magick with -size/-depth/RGBA:- when configured", function()
        local _, calls, restore = with_mocks({ img2sixel = false, magick = true }, function()
            return { code = 0, stdout = "RGBA_SIXEL" }
        end, { img2sixel = false, magick = "magick" })
        local magick = require("alt-img._core.magick")
        local ok, err = pcall(function()
            local out = magick.encode_sixel_from_rgba(rgba, 1, 1)
            assert.equals("RGBA_SIXEL", out)
            assert.equals(1, #calls)
            local cmd = calls[1].cmd
            assert.equals("magick", cmd[1])
            -- The geometry, depth and raw-input identifiers must all be present.
            local seen = {}
            for i, a in ipairs(cmd) do
                seen[a] = i
            end
            assert.is_true(seen["-size"] ~= nil, "expected -size flag")
            assert.equals("1x1", cmd[seen["-size"] + 1])
            assert.is_true(seen["-depth"] ~= nil, "expected -depth flag")
            assert.equals("8", cmd[seen["-depth"] + 1])
            assert.is_true(seen["RGBA:-"] ~= nil, "expected RGBA:- input")
            -- stdin must be the raw RGBA buffer, not a PNG.
            assert.equals(rgba, calls[1].opts.stdin)
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("returns nil when magick = false", function()
        local _, _, restore = with_mocks({ img2sixel = true, magick = true }, function()
            return { code = 0, stdout = "NEVER" }
        end, { img2sixel = false, magick = false })
        local magick = require("alt-img._core.magick")
        local ok, err = pcall(function()
            assert.is_nil(magick.encode_sixel_from_rgba(rgba, 1, 1))
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)
end)

describe("magick.crop_to_sixel", function()
    local png_bytes = "FAKEPNG"

    it("invokes magick with -crop geometry when configured", function()
        local _, calls, restore = with_mocks({ img2sixel = false, magick = true }, function()
            return { code = 0, stdout = "CROPPED_SIXEL" }
        end, { img2sixel = false, magick = "magick" })
        local magick = require("alt-img._core.magick")
        local ok, err = pcall(function()
            local out = magick.crop_to_sixel(png_bytes, 5, 7, 11, 13)
            assert.equals("CROPPED_SIXEL", out)
            assert.equals(1, #calls)
            local cmd = calls[1].cmd
            assert.equals("magick", cmd[1])
            -- Expect -crop 11x13+5+7 somewhere in the arg list.
            local found = false
            for i = 1, #cmd - 1 do
                if cmd[i] == "-crop" and cmd[i + 1] == "11x13+5+7" then
                    found = true
                end
            end
            assert.is_true(found)
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("returns nil when magick = false (caller falls back)", function()
        local _, calls, restore = with_mocks({ img2sixel = true, magick = true }, function()
            return { code = 0, stdout = "NEVER" }
        end, { img2sixel = false, magick = false })
        local magick = require("alt-img._core.magick")
        local ok, err = pcall(function()
            local out = magick.crop_to_sixel(png_bytes, 0, 0, 1, 1)
            assert.is_nil(out)
            assert.equals(0, #calls)
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("returns nil when magick is not installed", function()
        local _, _, restore = with_mocks({ img2sixel = true, magick = false, convert = false }, function()
            return { code = 0, stdout = "NEVER" }
        end, {})
        local magick = require("alt-img._core.magick")
        local ok, err = pcall(function()
            local out = magick.crop_to_sixel(png_bytes, 0, 0, 1, 1)
            assert.is_nil(out)
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)
end)

describe("magick.encode_sixel_from_png_resized", function()
    local png_bytes = "FAKEPNG"

    it("invokes magick with -sample WxH! (nearest-neighbor) when configured", function()
        local _, calls, restore = with_mocks({ img2sixel = false, magick = true }, function()
            return { code = 0, stdout = "RESIZED_SIXEL" }
        end, { img2sixel = false, magick = "magick" })
        local magick = require("alt-img._core.magick")
        local ok, err = pcall(function()
            local out = magick.encode_sixel_from_png_resized(png_bytes, 80, 24)
            assert.equals("RESIZED_SIXEL", out)
            assert.equals(1, #calls)
            local cmd = calls[1].cmd
            assert.equals("magick", cmd[1])
            local found = false
            for i = 1, #cmd - 1 do
                if cmd[i] == "-sample" and cmd[i + 1] == "80x24!" then
                    found = true
                end
            end
            assert.is_true(found, "expected -sample 80x24! in arg list")
            -- -resize would default to Lanczos, smoothing 1:1 pixel maps.
            for _, a in ipairs(cmd) do
                assert.is_true(a ~= "-resize", "must not use -resize (smoothing filter)")
            end
            assert.equals("sixel:-", cmd[#cmd])
            assert.equals(png_bytes, calls[1].opts.stdin)
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("returns nil when magick = false", function()
        local _, _, restore = with_mocks({ magick = true }, function()
            return { code = 0, stdout = "NEVER" }
        end, { magick = false })
        local magick = require("alt-img._core.magick")
        local ok, err = pcall(function()
            assert.is_nil(magick.encode_sixel_from_png_resized(png_bytes, 1, 1))
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)
end)

describe("magick.crop_resized_to_sixel", function()
    local png_bytes = "FAKEPNG"

    it("emits both -sample (nearest-neighbor) and -crop with target-space coords", function()
        local _, calls, restore = with_mocks({ img2sixel = false, magick = true }, function()
            return { code = 0, stdout = "RESIZED_CROPPED_SIXEL" }
        end, { img2sixel = false, magick = "magick" })
        local magick = require("alt-img._core.magick")
        local ok, err = pcall(function()
            -- Sample the source PNG to 80x24, then crop a 11x13 rect at +5+7.
            local out = magick.crop_resized_to_sixel(png_bytes, 80, 24, 5, 7, 11, 13)
            assert.equals("RESIZED_CROPPED_SIXEL", out)
            assert.equals(1, #calls)
            local cmd = calls[1].cmd
            assert.equals("magick", cmd[1])
            local saw_sample, saw_crop = false, false
            for i = 1, #cmd - 1 do
                if cmd[i] == "-sample" and cmd[i + 1] == "80x24!" then
                    saw_sample = true
                end
                if cmd[i] == "-crop" and cmd[i + 1] == "11x13+5+7" then
                    saw_crop = true
                end
            end
            assert.is_true(saw_sample, "expected -sample 80x24! in arg list")
            assert.is_true(saw_crop, "expected -crop 11x13+5+7 in arg list")
            for _, a in ipairs(cmd) do
                assert.is_true(a ~= "-resize", "must not use -resize (smoothing filter)")
            end
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("returns nil when magick = false", function()
        local _, _, restore = with_mocks({ magick = true }, function()
            return { code = 0, stdout = "NEVER" }
        end, { magick = false })
        local magick = require("alt-img._core.magick")
        local ok, err = pcall(function()
            assert.is_nil(magick.crop_resized_to_sixel(png_bytes, 80, 24, 0, 0, 1, 1))
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)
end)

describe("magick.crop_to_png", function()
    local png_bytes = "FAKEPNG"

    it("invokes magick with png:- when configured", function()
        local _, calls, restore = with_mocks({ img2sixel = false, magick = true }, function()
            return { code = 0, stdout = "CROPPED_PNG" }
        end, { img2sixel = false, magick = "magick" })
        local magick = require("alt-img._core.magick")
        local ok, err = pcall(function()
            local out = magick.crop_to_png(png_bytes, 1, 2, 3, 4)
            assert.equals("CROPPED_PNG", out)
            assert.equals(1, #calls)
            -- Last positional should be 'png:-'.
            local cmd = calls[1].cmd
            assert.equals("png:-", cmd[#cmd])
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)

    it("returns nil when magick = false", function()
        local _, _, restore = with_mocks({ img2sixel = true, magick = true }, function()
            return { code = 0, stdout = "NEVER" }
        end, { img2sixel = false, magick = false })
        local magick = require("alt-img._core.magick")
        local ok, err = pcall(function()
            assert.is_nil(magick.crop_to_png(png_bytes, 0, 0, 1, 1))
        end)
        restore()
        if not ok then
            error(err, 0)
        end
    end)
end)

-- Integration: a buffer-anchored placement gets cropped because its window is
-- too short. The sixel provider's fast path sees magick is on PATH and feeds
-- the original PNG through `magick - -sample WxH! -crop CWxCH+X+Y sixel:-` in
-- a single subprocess. We assert the captured emit contains the canned bytes
-- returned by our mock.
describe("accel-with-crop integration", function()
    local function read_fixture()
        local f = io.open("test/fixtures/4x4.png", "rb")
        local b = f:read("*a")
        f:close()
        return b
    end

    it("sixel provider routes a window-clipped placement through magick", function()
        local saved_system = vim.system
        local saved_executable = vim.fn.executable
        local saved_g = vim.g.alt_img

        vim.fn.executable = function(name)
            if name == "magick" then
                return 1
            end
            if name == "convert" then
                return 1
            end
            if name == "img2sixel" then
                return 0
            end
            return saved_executable(name)
        end
        local magick_calls = {}
        vim.system = function(cmd, opts)
            table.insert(magick_calls, { cmd = cmd, opts = opts })
            return {
                wait = function()
                    return { code = 0, stdout = "MAGICK_SIXEL_BYTES" }
                end,
            }
        end

        -- Reload everything under the new env.
        package.loaded["alt-img"] = nil
        package.loaded["alt-img._core.util"] = nil
        package.loaded["alt-img._core.png"] = nil
        package.loaded["alt-img._core.magick"] = nil
        package.loaded["alt-img._core.render"] = nil
        package.loaded["alt-img._core.carrier"] = nil
        package.loaded["alt-img._core.image"] = nil
        package.loaded["alt-img.sixel._encode"] = nil
        package.loaded["alt-img.sixel._libsixel"] = nil
        package.loaded["alt-img.sixel"] = nil
        vim.g.alt_img = { magick = "magick", img2sixel = false }
        require("alt-img._core.util")._reset_executable_cache()

        H.setup_capture()
        local img = require("alt-img.sixel")

        -- Build a setup that triggers cropping: small window, image taller than
        -- the visible region.
        local buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x" })
        vim.api.nvim_set_current_buf(buf)
        vim.cmd("resize 3")

        H.reset_capture()
        local id = img.set(read_fixture(), { relative = "buffer", buf = buf, row = 1, col = 1, width = 4, height = 10 })

        -- We expect magick to have been invoked at least once (either via the
        -- combined crop+encode fast path, or via encode_sixel_dispatch on the
        -- already-cropped RGBA buffer).
        local saw_magick = false
        for _, call in ipairs(magick_calls) do
            if call.cmd[1] == "magick" then
                saw_magick = true
                break
            end
        end

        -- Verify the captured emit contains our canned bytes.
        local cap = H.captured()
        local saw_canned = cap:find("MAGICK_SIXEL_BYTES", 1, true) ~= nil

        img.del(id)
        vim.cmd("resize")

        -- Restore.
        vim.system = saved_system
        vim.fn.executable = saved_executable
        vim.g.alt_img = saved_g

        assert.is_true(saw_magick, "expected magick to be invoked")
        assert.is_true(saw_canned, "expected captured emit to contain canned MAGICK_SIXEL_BYTES")
    end)
end)

-- After this spec finishes, restore deterministic defaults for any later
-- specs that share the alt-img config.
describe("accel cleanup", function()
    it("leaves magick=false, img2sixel=false for subsequent specs", function()
        vim.g.alt_img = { magick = false, img2sixel = false }
        assert.equals(false, (vim.g.alt_img or {}).magick)
        assert.equals(false, (vim.g.alt_img or {}).img2sixel)
        -- Tag H so static analyzers don't flag the import as unused.
        _ = H
    end)
end)
