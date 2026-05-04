describe("placeholder lifecycle on slow path", function()
    local function set_image(nvim)
        nvim:lua([[
            local f = io.open(vim.uv.cwd() .. "/test/fixtures/org-roam-logo.png", "rb")
            local data = f:read("*a")
            f:close()
            vim.ui.img.set(data, { buf = 0, width = 30, height = 12 })
        ]])
    end

    harness("placeholder appears within delay_ms during slow encode", function(ctx)
        local nvim = ctx:spawn({
            provider = "sixel",
            config = {
                magick = false,
                img2sixel = false,
                chafa = false,
                libz = false,
                precompute = { enabled = false },
                cache = { enabled = false },
                placeholder = { enabled = true, delay_ms = 30, spinner_interval_ms = 50 },
            },
        })
        set_image(nvim)
        nvim:wait_until(function()
            return nvim:placeholder_visible()
        end, { timeout_ms = 1000, msg = "placeholder never appeared after delay_ms" })
        nvim:lua([[ vim.ui.img.del(math.huge) ]])
    end)

    harness("placeholder hides + image emits after encode completes", function(ctx)
        local nvim = ctx:spawn({
            provider = "sixel",
            config = {
                magick = false,
                img2sixel = false,
                chafa = false,
                libz = false,
                precompute = { enabled = false },
                cache = { enabled = false },
                placeholder = { enabled = true, delay_ms = 30, spinner_interval_ms = 50 },
            },
        })
        set_image(nvim)
        -- Wait for image bytes (sixel DCS or OSC 1337 magic) to appear
        nvim:wait_until(function()
            local b = nvim:captured_ui_bytes()
            -- sixel DCS prefix: ESC P ... q
            -- OSC 1337 prefix: ESC ] 1337 ;
            return b:find("\27P") ~= nil or b:find("\27%]1337") ~= nil
        end, { timeout_ms = 60000, msg = "image bytes never emitted" })
        -- Placeholder should be gone after image emits
        nvim:wait_until(function()
            return not nvim:placeholder_visible()
        end, { timeout_ms = 2000, msg = "placeholder never cleared after image emit" })
        nvim:lua([[ vim.ui.img.del(math.huge) ]])
    end)

    harness("placeholder disabled → no placeholder ever shown", function(ctx)
        local nvim = ctx:spawn({
            provider = "sixel",
            config = {
                magick = false,
                img2sixel = false,
                chafa = false,
                libz = false,
                precompute = { enabled = false },
                cache = { enabled = false },
                placeholder = { enabled = false },
            },
        })
        set_image(nvim)
        -- Wait briefly to give the deferred placeholder a chance — it
        -- shouldn't fire since enabled=false.
        vim.wait(300)
        assert.falsy(nvim:placeholder_visible(), "placeholder visible despite enabled=false")
        nvim:lua([[ vim.ui.img.del(math.huge) ]])
    end)
end)

describe("placeholder cancellation matrix", function()
    local function set_slow(nvim)
        nvim:lua([[
            local f = io.open(vim.uv.cwd() .. "/test/fixtures/org-roam-logo.png", "rb")
            local data = f:read("*a")
            f:close()
            _G.test_id = vim.ui.img.set(data, { buf = 0, width = 30, height = 12 })
        ]])
    end

    harness("del(id) during encode hides placeholder", function(ctx)
        local nvim = ctx:spawn({
            provider = "sixel",
            config = {
                magick = false,
                img2sixel = false,
                chafa = false,
                libz = false,
                precompute = { enabled = false },
                cache = { enabled = false },
                placeholder = { enabled = true, delay_ms = 30 },
            },
        })
        set_slow(nvim)
        nvim:wait_until(function()
            return nvim:placeholder_visible()
        end, { timeout_ms = 1000, msg = "placeholder never appeared" })
        nvim:lua([[ vim.ui.img.del(_G.test_id) ]])
        nvim:wait_until(function()
            return not nvim:placeholder_visible()
        end, { timeout_ms = 1000, msg = "placeholder still visible after del" })
    end)

    harness("del(math.huge) during encode hides placeholder", function(ctx)
        local nvim = ctx:spawn({
            provider = "sixel",
            config = {
                magick = false,
                img2sixel = false,
                chafa = false,
                libz = false,
                precompute = { enabled = false },
                cache = { enabled = false },
                placeholder = { enabled = true, delay_ms = 30 },
            },
        })
        set_slow(nvim)
        nvim:wait_until(function()
            return nvim:placeholder_visible()
        end, { timeout_ms = 1000 })
        nvim:lua([[ vim.ui.img.del(math.huge) ]])
        nvim:wait_until(function()
            return not nvim:placeholder_visible()
        end, { timeout_ms = 1000, msg = "placeholder still visible after del all" })
    end)
end)
