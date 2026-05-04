local H = require("test.helpers")

describe("alt-img (autodetect)", function()
    before_each(function()
        package.loaded["alt-img"] = nil
        package.loaded["alt-img._core.autodetect"] = nil
        package.loaded["alt-img.iterm2"] = nil
        package.loaded["alt-img.sixel"] = nil
    end)

    it("module M has exactly four entries", function()
        local img = require("alt-img")
        local keys = {}
        for k in pairs(img) do
            keys[k] = true
        end
        assert.same({ set = true, get = true, del = true, _supported = true }, keys)
    end)

    it("_supported returns true on iTerm2", function()
        H.with_env({ TERM_PROGRAM = "iTerm.app" }, function()
            package.loaded["alt-img"] = nil
            package.loaded["alt-img._core.autodetect"] = nil
            local img = require("alt-img")
            assert.is_true(img._supported({ timeout = 50 }))
        end)
    end)

    it("_supported returns false with optional msg on no-protocol terminals", function()
        H.with_env({ TERM_PROGRAM = false, TERM = "dumb", TMUX = false, KITTY_WINDOW_ID = false }, function()
            package.loaded["alt-img"] = nil
            package.loaded["alt-img._core.autodetect"] = nil
            local img = require("alt-img")
            local ok, _msg = img._supported({ timeout = 50 })
            assert.is_false(ok)
            -- msg may or may not be set depending on whether providers
            -- emitted one — both shapes are contract-compliant.
        end)
    end)
end)
