describe("sixel._libsixel processing gate", function()
    local function with_cfg(cfg, fn)
        local prev = vim.g.alt_img
        vim.g.alt_img = cfg
        package.loaded["alt-img._core.processing"] = nil
        package.loaded["alt-img.sixel._libsixel"] = nil
        local ok, err = pcall(fn)
        vim.g.alt_img = prev
        package.loaded["alt-img._core.processing"] = nil
        package.loaded["alt-img.sixel._libsixel"] = nil
        if not ok then
            error(err, 0)
        end
    end

    it("binary() returns nil when 'img2sixel' not in processing.tools", function()
        with_cfg({ processing = { tools = { "magick" } } }, function()
            local libsixel = require("alt-img.sixel._libsixel")
            assert.eq(libsixel.binary(), nil)
        end)
    end)

    it("binary() returns nil when processing.tools = false", function()
        with_cfg({ processing = { tools = false } }, function()
            local libsixel = require("alt-img.sixel._libsixel")
            assert.eq(libsixel.binary(), nil)
        end)
    end)

    it("binary() returns nil for non-existent candidate name", function()
        with_cfg({ processing = { img2sixel = "nonexistent_xyz_for_libsixel_test" } }, function()
            local libsixel = require("alt-img.sixel._libsixel")
            assert.eq(libsixel.binary(), nil)
        end)
    end)
end)
