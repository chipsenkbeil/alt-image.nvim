describe("harness spike", function()
    harness("spawned child runs and captures ui bytes", function(ctx)
        local nvim = ctx:spawn({ config = {} })

        -- Verify the child loaded alt-img and the public surface exists
        local has_set = nvim:lua_eval("type(vim.ui.img.set) == 'function'")
        assert.truthy(has_set, "child has vim.ui.img.set")

        -- Send raw bytes via nvim_ui_send and confirm capture sees them
        nvim:lua([[ vim.api.nvim_ui_send("HELLO_HARNESS") ]])
        local captured = nvim:captured_ui_bytes()
        assert.match(captured, "HELLO_HARNESS", "ui_send bytes captured")

        -- reset_captured clears the buffer
        nvim:reset_captured()
        assert.eq(nvim:captured_ui_bytes(), "", "buffer cleared")

        -- Subsequent send is captured cleanly
        nvim:lua([[ vim.api.nvim_ui_send("AFTER_RESET") ]])
        assert.eq(nvim:captured_ui_bytes(), "AFTER_RESET")
    end)
end)
