local H = require("test.helpers")
local senc = require("alt-img.sixel._encode")

describe("harness", function()
    it("runs a passing test", function()
        assert.equals(1, 1)
    end)

    it("does deep equal", function()
        assert.same({ a = { b = 1 } }, { a = { b = 1 } })
    end)
end)

describe("_png", function()
    local png = require("alt-img._core.png")

    it("decodes the 4x4 fixture", function()
        local f = assert(io.open("test/fixtures/4x4.png", "rb"))
        local bytes = f:read("*a")
        f:close()
        local img = png.decode(bytes)
        assert.equals(4, img.width)
        assert.equals(4, img.height)
        -- 16 pixels x 4 bytes (RGBA) = 64 bytes of pixel data
        assert.equals(16 * 4, #img.pixels)
    end)
end)

describe("helpers", function()
    it("parses an iterm2 OSC 1337 sequence", function()
        local seq = "\027]1337;File=size=12;inline=1;width=4:aGVsbG8\007"
        local r = H.parse_iterm2_seq(seq)
        assert.same({ size = "12", inline = "1", width = "4" }, r.args)
        assert.equals("aGVsbG8", r.payload)
    end)

    it("parses a sixel DCS sequence", function()
        local seq = '\027Pq"1;1;4;4#0;2;100;0;0$-\027\\'
        local r = H.parse_sixel_seq(seq)
        assert.same({ pan = 1, pad = 1, w = 4, h = 4 }, r.raster)
        assert.same({ 100, 0, 0 }, r.palette[0])
    end)
end)

describe("_util.png_dimensions", function()
    local util = require("alt-img._core.util")

    it("parses width and height from a real PNG", function()
        local f = assert(io.open("test/fixtures/4x4.png", "rb"))
        local data = f:read("*a")
        f:close()
        local w, h = util.png_dimensions(data)
        assert.equals(4, w)
        assert.equals(4, h)
    end)

    it("returns nil for non-PNG input", function()
        local w, h = util.png_dimensions("not a png")
        assert.is_nil(w)
        assert.is_nil(h)
    end)

    it("returns nil for too-short PNG-signature input", function()
        -- Valid 8-byte signature, but truncated before the IHDR width/height.
        local data = "\137PNG\r\n\26\n" .. string.rep("\0", 4)
        local w, h = util.png_dimensions(data)
        assert.is_nil(w)
        assert.is_nil(h)
    end)
end)

describe("_util.clip_to_bounds", function()
    local util = require("alt-img._core.util")

    it("image fully inside bounds → src covers full image", function()
        local p = util.clip_to_bounds(5, 5, 4, 4, 1, 1, 24, 80)
        assert.is_not_nil(p)
        assert.equals(5, p.row)
        assert.equals(5, p.col)
        assert.equals(0, p.src.x)
        assert.equals(0, p.src.y)
        assert.equals(4, p.src.w)
        assert.equals(4, p.src.h)
    end)

    it("image extends past right → src.w shrinks, src.x = 0", function()
        -- Image 4x4 anchored at col=78 in 80-col terminal → only 3 cols visible.
        local p = util.clip_to_bounds(1, 78, 4, 4, 1, 1, 24, 80)
        assert.is_not_nil(p)
        assert.equals(0, p.src.x)
        assert.equals(0, p.src.y)
        assert.equals(3, p.src.w)
        assert.equals(4, p.src.h)
    end)

    it("image extends past bottom → src.h shrinks, src.y = 0", function()
        -- Image 4x4 anchored at row=22 in 24-row terminal → only 3 rows visible.
        local p = util.clip_to_bounds(22, 1, 4, 4, 1, 1, 24, 80)
        assert.is_not_nil(p)
        assert.equals(0, p.src.x)
        assert.equals(0, p.src.y)
        assert.equals(4, p.src.w)
        assert.equals(3, p.src.h)
    end)

    it("image extends past top → src.y > 0, src.h reduced", function()
        -- Image 4x4 anchored at row=-1 (above bounds top=1).
        local p = util.clip_to_bounds(-1, 1, 4, 4, 1, 1, 24, 80)
        assert.is_not_nil(p)
        assert.equals(1, p.row)
        assert.equals(2, p.src.y) -- 2 rows of image are above the bound
        assert.equals(0, p.src.x)
        assert.equals(4, p.src.w)
        assert.equals(2, p.src.h)
    end)

    it("image extends past left → src.x > 0, src.w reduced", function()
        -- Image 4x4 anchored at col=-1 (left of bounds left=1).
        local p = util.clip_to_bounds(1, -1, 4, 4, 1, 1, 24, 80)
        assert.is_not_nil(p)
        assert.equals(1, p.col)
        assert.equals(2, p.src.x) -- 2 cols of image are left of the bound
        assert.equals(0, p.src.y)
        assert.equals(2, p.src.w)
        assert.equals(4, p.src.h)
    end)

    it("image entirely outside bounds → returns nil", function()
        -- Anchored well past the bottom-right corner.
        assert.is_nil(util.clip_to_bounds(100, 100, 4, 4, 1, 1, 24, 80))
        -- Anchored well above the top.
        assert.is_nil(util.clip_to_bounds(-10, 1, 4, 4, 1, 1, 24, 80))
    end)
end)

describe("_core.util cell size", function()
    local tty = require("alt-img._core.tty")
    local saved_query = tty.query

    local function reload_util()
        package.loaded["alt-img._core.util"] = nil
        return require("alt-img._core.util")
    end

    after_each(function()
        tty.query = saved_query
    end)

    it("seeds defaults appropriate to the host platform", function()
        local util = reload_util()
        local w, h = util.cell_pixel_size()
        if vim.uv.os_uname().sysname == "Windows_NT" then
            assert.equals(10, w)
            assert.equals(20, h)
        else
            assert.equals(8, w)
            assert.equals(16, h)
        end
    end)

    it("updates cache when CSI 16t responds", function()
        local sent
        tty.query = function(payload, _opts, cb)
            sent = payload
            cb("\027[6;32;16t")
        end
        local util = reload_util()
        util.query_cell_size()
        assert.equals("\027[16t", sent)
        local w, h = util.cell_pixel_size()
        assert.equals(16, w)
        assert.equals(32, h)
    end)

    it("keeps defaults when the response is malformed", function()
        tty.query = function(_payload, _opts, cb)
            cb("\027[?6c") -- DA1 reply, not CSI 16t — must not match
        end
        local util = reload_util()
        util.query_cell_size()
        local w, h = util.cell_pixel_size()
        if vim.uv.os_uname().sysname == "Windows_NT" then
            assert.equals(10, w)
            assert.equals(20, h)
        else
            assert.equals(8, w)
            assert.equals(16, h)
        end
    end)

    it("fires _on_cell_size_change only when dimensions actually change", function()
        tty.query = function(_payload, _opts, cb)
            cb("\027[6;32;16t")
        end
        local util = reload_util()
        local fires = 0
        util._on_cell_size_change = function()
            fires = fires + 1
        end
        util.query_cell_size()
        assert.equals(1, fires)
        -- Second invocation: same dimensions, no change fired (and the
        -- _cell_size_queried gate also short-circuits the second call).
        util._cell_size_queried = false
        util.query_cell_size()
        assert.equals(1, fires)
    end)
end)

describe("_core.util terminal_pixel_scale", function()
    local tty = require("alt-img._core.tty")
    local saved_query = tty.query

    local function reload_util()
        package.loaded["alt-img._core.util"] = nil
        return require("alt-img._core.util")
    end

    -- Build a tty.query mock that responds to a sequence of payload patterns
    -- with canned replies. `responses` is a list of { match=pattern, reply=string }
    -- entries; first match wins. Unmatched payloads silently no-op (the
    -- caller will time out — vim.wait short timeouts in the unit tests).
    local function mock_tty_responses(responses)
        tty.query = function(payload, _opts, cb)
            for _, r in ipairs(responses) do
                if payload:match(r.match) then
                    cb(r.reply)
                    return
                end
            end
        end
    end

    after_each(function()
        tty.query = saved_query
    end)

    it("infers scale=2 when CSI 14t reports physical pixels and CSI 16t stays logical", function()
        -- Scenario: 64 cols × 32 rows window with 8×16 cells. Logical
        -- window = 512×512; on a 2× HiDPI display the terminal reports
        -- CSI 14t in physical pixels (1024×1024) while CSI 16t stays
        -- logical (8×16). The implied per-cell pixel size from 14t/18t
        -- is 16×32 — exactly 2× CSI 16t — so we infer scale=2.
        mock_tty_responses({
            -- CSI 16t reply format: ESC [ 6 ; <h> ; <w> t
            { match = "%[16t", reply = "\027[6;16;8t" },
            -- CSI 14t reply format: ESC [ 4 ; <h> ; <w> t — PHYSICAL pixels
            { match = "%[14t", reply = "\027[4;1024;1024t" },
            -- CSI 18t reply format: ESC [ 8 ; <rows> ; <cols> t
            { match = "%[18t", reply = "\027[8;32;64t" },
        })
        local util = reload_util()
        assert.equals(2, util.terminal_pixel_scale())
    end)

    it("returns 1 when window pixels and cells agree", function()
        -- Same window geometry but CSI 14t reports LOGICAL (512×512).
        -- Implied cell size = CSI 16t = no scaling.
        mock_tty_responses({
            { match = "%[16t", reply = "\027[6;16;8t" },
            { match = "%[14t", reply = "\027[4;512;512t" },
            { match = "%[18t", reply = "\027[8;32;64t" },
        })
        local util = reload_util()
        assert.equals(1, util.terminal_pixel_scale())
    end)

    it("returns 1 when CSI queries don't respond at all", function()
        tty.query = function(_payload, _opts, _cb)
            -- never responds
        end
        local util = reload_util()
        assert.equals(1, util.terminal_pixel_scale())
    end)

    it("returns 1 when CSI 14t responds but CSI 18t doesn't", function()
        mock_tty_responses({
            { match = "%[16t", reply = "\027[6;16;8t" },
            { match = "%[14t", reply = "\027[4;1024;1024t" },
            -- 18t deliberately missing
        })
        local util = reload_util()
        assert.equals(1, util.terminal_pixel_scale())
    end)

    it("ignores malformed responses and stays at 1", function()
        mock_tty_responses({
            { match = "%[14t", reply = "\027[?6c" }, -- DA1 reply, not CSI 14t
            { match = "%[16t", reply = "\027[6;16;8t" },
            { match = "%[18t", reply = "\027[8;32;64t" },
        })
        local util = reload_util()
        assert.equals(1, util.terminal_pixel_scale())
    end)

    it("queries only once and caches the result", function()
        local calls14 = 0
        tty.query = function(payload, _opts, cb)
            if payload:match("%[14t") then
                calls14 = calls14 + 1
                cb("\027[4;1024;1024t")
            elseif payload:match("%[16t") then
                cb("\027[6;16;8t")
            elseif payload:match("%[18t") then
                cb("\027[8;32;64t")
            end
        end
        local util = reload_util()
        assert.equals(2, util.terminal_pixel_scale())
        assert.equals(2, util.terminal_pixel_scale())
        assert.equals(2, util.terminal_pixel_scale())
        assert.equals(1, calls14, "CSI 14t should be queried exactly once")
    end)
end)

describe("_core.util.resolve_binary", function()
    local util = require("alt-img._core.util")

    local function with_executable(executable_for, fn)
        local saved = vim.fn.executable
        vim.fn.executable = function(name)
            local v = executable_for[name]
            if v == true then
                return 1
            end
            if v == false then
                return 0
            end
            return saved(name)
        end
        util._reset_executable_cache()
        local ok, err = pcall(fn)
        vim.fn.executable = saved
        util._reset_executable_cache()
        if not ok then
            error(err, 0)
        end
    end

    it("returns nil for nil cfg", function()
        with_executable({ magick = true }, function()
            assert.is_nil(util.resolve_binary(nil))
        end)
    end)

    it("returns nil for false cfg", function()
        with_executable({ magick = true }, function()
            assert.is_nil(util.resolve_binary(false))
        end)
    end)

    it("returns the string when executable", function()
        with_executable({ magick = true }, function()
            assert.equals("magick", util.resolve_binary("magick"))
        end)
    end)

    it("returns nil when string is not executable", function()
        with_executable({ magick = false }, function()
            assert.is_nil(util.resolve_binary("magick"))
        end)
    end)

    it("returns first executable from a list", function()
        with_executable({ magick = false, convert = true }, function()
            assert.equals("convert", util.resolve_binary({ "magick", "convert" }))
        end)
    end)

    it("returns nil when no list candidate is executable", function()
        with_executable({ magick = false, convert = false }, function()
            assert.is_nil(util.resolve_binary({ "magick", "convert" }))
        end)
    end)

    it("returns nil for an empty list", function()
        with_executable({ magick = true }, function()
            assert.is_nil(util.resolve_binary({}))
        end)
    end)
end)

describe("_core.config", function()
    local config = require("alt-img._core.config")

    local function with_g(value, fn)
        local saved = vim.g.alt_img
        vim.g.alt_img = value
        local ok, err = pcall(fn)
        vim.g.alt_img = saved
        if not ok then
            error(err, 0)
        end
    end

    it("returns full defaults when vim.g.alt_img is unset", function()
        with_g(nil, function()
            local c = config.read()
            assert.same({ "magick", "convert" }, c.magick)
            assert.same({ "img2sixel" }, c.img2sixel)
        end)
    end)

    it("user fields override defaults; missing fields fall back", function()
        with_g({ magick = false }, function()
            local c = config.read()
            assert.equals(false, c.magick)
            assert.same({ "img2sixel" }, c.img2sixel)
        end)
    end)

    it("user array replaces default array (no index merge)", function()
        -- Regression guard: a deep merge would index-extend and produce
        -- { 'gm', 'convert' } here; we want full replacement.
        with_g({ magick = { "gm" } }, function()
            assert.same({ "gm" }, config.read().magick)
        end)
    end)

    it("defaults() returns a copy, not the live table", function()
        local d = config.defaults()
        d.magick = "mutated"
        assert.same({ "magick", "convert" }, config.defaults().magick)
    end)
end)

describe("_sixel_encode", function()
    it("encodes a 4x4 solid-red RGBA buffer to a DCS sequence", function()
        -- 4x4 fully opaque red
        local rgba = string.rep(string.char(255, 0, 0, 255), 4 * 4)
        local s = senc.encode_sixel(rgba, 4, 4)
        assert.matches("^\027Pq", s)
        assert.matches("\027\\$", s)
        -- Palette must contain a red entry (close to 100;0;0 in 0-100 scale)
        assert.matches("#%d+;2;100;0;0", s)
    end)
end)
