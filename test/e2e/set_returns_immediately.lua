describe("vim.ui.img.set on slow path", function()
    harness("returns immediately even when encode is slow", function(ctx)
        local nvim = ctx:spawn({
            provider = "sixel",
            config = {
                processing = { tools = false }, -- pure-Lua only → slow encode
                -- Disable precompute so we don't have to disambiguate its
                -- coroutines from set()'s.
                precompute = { enabled = false },
                cache = { enabled = false },
                placeholder = { delay_ms = 30 },
            },
        })

        nvim:lua([[
            local f = io.open(vim.uv.cwd() .. "/test/fixtures/org-roam-logo.png", "rb")
            _G.test_data = f:read("*a")
            f:close()
            vim.api.nvim_set_current_dir(vim.uv.cwd())
        ]])

        -- set() should return within tens of ms even though the actual
        -- encode is very slow. Time the call.
        local elapsed_ms = nvim:lua_eval([[(function()
            local t0 = vim.uv.hrtime()
            _G.test_id = vim.ui.img.set(_G.test_data, { buf = 0, width = 30, height = 12 })
            return (vim.uv.hrtime() - t0) / 1e6
        end)()]])

        assert.lt(elapsed_ms, 100, "set() must return < 100 ms; got " .. elapsed_ms .. " ms")
        assert.truthy(nvim:lua_eval("type(_G.test_id) == 'number'"), "set returned an id")

        -- Cleanup before close so child doesn't keep encoding
        nvim:lua([[ vim.ui.img.del(math.huge) ]])
    end)
end)
