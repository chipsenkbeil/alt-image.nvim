describe("_core.processing", function()
    -- Clears any cached state in alt-img._core.processing so each block
    -- gets a fresh module instance under the supplied vim.g.alt_img. The
    -- module is stateless today, but reloading defends against future
    -- module-level caches silently masking config changes.
    local function with_cfg(cfg, fn)
        local prev = vim.g.alt_img
        vim.g.alt_img = cfg
        package.loaded["alt-img._core.processing"] = nil
        local ok, err = pcall(fn)
        vim.g.alt_img = prev
        package.loaded["alt-img._core.processing"] = nil
        if not ok then
            error(err, 0)
        end
    end

    it("is_enabled returns true for default tools", function()
        with_cfg({}, function()
            local p = require("alt-img._core.processing")
            assert.truthy(p.is_enabled("magick"))
            assert.truthy(p.is_enabled("img2sixel"))
            assert.truthy(p.is_enabled("chafa"))
            assert.truthy(p.is_enabled("libz"))
        end)
    end)

    it("is_enabled returns false when name not in user tools list", function()
        with_cfg({ processing = { tools = { "chafa" } } }, function()
            local p = require("alt-img._core.processing")
            assert.truthy(p.is_enabled("chafa"))
            assert.falsy(p.is_enabled("magick"))
            assert.falsy(p.is_enabled("img2sixel"))
            assert.falsy(p.is_enabled("libz"))
        end)
    end)

    it("is_enabled returns false when tools = false", function()
        with_cfg({ processing = { tools = false } }, function()
            local p = require("alt-img._core.processing")
            assert.falsy(p.is_enabled("magick"))
            assert.falsy(p.is_enabled("libz"))
        end)
    end)

    it("is_enabled returns false when tools = {}", function()
        with_cfg({ processing = { tools = {} } }, function()
            local p = require("alt-img._core.processing")
            assert.falsy(p.is_enabled("magick"))
        end)
    end)

    it("ordered_tools preserves user-specified order", function()
        with_cfg({ processing = { tools = { "magick", "chafa" } } }, function()
            local p = require("alt-img._core.processing")
            local got = p.ordered_tools({ "chafa", "img2sixel", "magick" })
            assert.eq(#got, 2)
            assert.eq(got[1], "magick")
            assert.eq(got[2], "chafa")
        end)
    end)

    it("ordered_tools filters names not in user list", function()
        with_cfg({ processing = { tools = { "magick" } } }, function()
            local p = require("alt-img._core.processing")
            local got = p.ordered_tools({ "chafa", "magick", "img2sixel" })
            assert.eq(#got, 1)
            assert.eq(got[1], "magick")
        end)
    end)

    it("ordered_tools returns empty when tools = false", function()
        with_cfg({ processing = { tools = false } }, function()
            local p = require("alt-img._core.processing")
            local got = p.ordered_tools({ "chafa", "magick" })
            assert.eq(#got, 0)
        end)
    end)

    it("candidates returns default candidate list", function()
        with_cfg({}, function()
            local p = require("alt-img._core.processing")
            local c = p.candidates("magick")
            assert.eq(c[1], "magick")
            assert.eq(c[2], "convert")
        end)
    end)

    it("candidates returns user override (string)", function()
        with_cfg({ processing = { magick = "convert" } }, function()
            local p = require("alt-img._core.processing")
            assert.eq(p.candidates("magick"), "convert")
        end)
    end)

    it("candidates merges per-tool override without losing sibling defaults", function()
        with_cfg({ processing = { magick = "convert" } }, function()
            local p = require("alt-img._core.processing")
            assert.eq(p.candidates("magick"), "convert")
            local libz = p.candidates("libz")
            assert.eq(libz[1], "z")
            assert.eq(libz[4], "libz")
        end)
    end)
end)
