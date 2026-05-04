describe("_core.png libz config", function()
    -- Note: libz binding is lazy-init + cached on first use within an nvim
    -- session. These tests share a single nvim, so they only assert
    -- behavior reachable from the current state — they don't try to flip
    -- libz on/off mid-session.

    it("decodes the same PNG identically with libz on and off", function()
        local f = io.open("test/fixtures/org-roam-logo.png", "rb")
        assert.truthy(f, "fixture present")
        local data = f:read("*a")
        f:close()

        -- Default config: whatever libz state the runner started with.
        package.loaded["alt-img._core.png"] = nil
        local png_default = require("alt-img._core.png")
        local img_default = png_default.decode(data)

        -- Force pure-Lua via processing.tools = false + module reload.
        local prev = vim.g.alt_img
        vim.g.alt_img = vim.tbl_extend("force", prev or {}, { processing = { tools = false } })
        package.loaded["alt-img._core.png"] = nil
        package.loaded["alt-img._core.processing"] = nil
        local png_no_libz = require("alt-img._core.png")
        assert.falsy(png_no_libz.has_libz(), "tools=false → has_libz() returns false")
        local img_no_libz = png_no_libz.decode(data)

        assert.eq(img_no_libz.width, img_default.width)
        assert.eq(img_no_libz.height, img_default.height)
        assert.eq(#img_no_libz.pixels, #img_default.pixels)
        -- Pixel-perfect match: pure-Lua INFLATE is a strict implementation
        -- of RFC 1951; output must be byte-identical to libz output.
        assert.eq(img_no_libz.pixels, img_default.pixels)

        -- Restore + reload for downstream tests
        vim.g.alt_img = prev
        package.loaded["alt-img._core.png"] = nil
        package.loaded["alt-img._core.processing"] = nil
    end)

    it("custom libz candidate as string is accepted", function()
        local prev = vim.g.alt_img
        vim.g.alt_img = vim.tbl_extend("force", prev or {}, { processing = { libz = "nonexistent_libz" } })
        package.loaded["alt-img._core.png"] = nil
        package.loaded["alt-img._core.processing"] = nil
        local png = require("alt-img._core.png")
        -- Single-string non-loadable name → no FFI binding, but module loads
        assert.falsy(png.has_libz(), "non-loadable name → has_libz false")
        vim.g.alt_img = prev
        package.loaded["alt-img._core.png"] = nil
        package.loaded["alt-img._core.processing"] = nil
    end)
end)
