describe("_core.magick processing gate", function()
    -- Clears cached state so each block sees fresh config.
    local function with_cfg(cfg, fn)
        local prev = vim.g.alt_img
        vim.g.alt_img = cfg
        package.loaded["alt-img._core.processing"] = nil
        package.loaded["alt-img._core.magick"] = nil
        local ok, err = pcall(fn)
        vim.g.alt_img = prev
        package.loaded["alt-img._core.processing"] = nil
        package.loaded["alt-img._core.magick"] = nil
        if not ok then
            error(err, 0)
        end
    end

    it("magick.binary() returns nil when 'magick' not in processing.tools", function()
        with_cfg({ processing = { tools = { "chafa" } } }, function()
            local magick = require("alt-img._core.magick")
            assert.eq(magick.binary(), nil)
        end)
    end)

    it("magick.binary() returns nil when processing.tools = false", function()
        with_cfg({ processing = { tools = false } }, function()
            local magick = require("alt-img._core.magick")
            assert.eq(magick.binary(), nil)
        end)
    end)

    it("magick.binary() returns nil for non-existent candidate name", function()
        -- Unique name avoids the binary-resolver cache from earlier tests.
        with_cfg({ processing = { magick = "nonexistent_xyz_for_magick_test" } }, function()
            local magick = require("alt-img._core.magick")
            assert.eq(magick.binary(), nil)
        end)
    end)
end)
