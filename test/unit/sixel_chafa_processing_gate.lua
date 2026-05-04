describe("sixel._chafa processing gate", function()
    local function with_cfg(cfg, fn)
        local prev = vim.g.alt_img
        vim.g.alt_img = cfg
        package.loaded["alt-img._core.processing"] = nil
        package.loaded["alt-img.sixel._chafa"] = nil
        local ok, err = pcall(fn)
        vim.g.alt_img = prev
        package.loaded["alt-img._core.processing"] = nil
        package.loaded["alt-img.sixel._chafa"] = nil
        if not ok then
            error(err, 0)
        end
    end

    it("binary() returns nil when 'chafa' not in processing.tools", function()
        with_cfg({ processing = { tools = { "magick" } } }, function()
            local chafa = require("alt-img.sixel._chafa")
            assert.eq(chafa.binary(), nil)
        end)
    end)

    it("binary() returns nil when processing.tools = false", function()
        with_cfg({ processing = { tools = false } }, function()
            local chafa = require("alt-img.sixel._chafa")
            assert.eq(chafa.binary(), nil)
        end)
    end)

    it("binary() returns nil for non-existent candidate name", function()
        with_cfg({ processing = { chafa = "nonexistent_xyz_for_chafa_test" } }, function()
            local chafa = require("alt-img.sixel._chafa")
            assert.eq(chafa.binary(), nil)
        end)
    end)
end)
