local H = require("test.helpers")

describe("alt-img._core.autodetect", function()
    before_each(function()
        package.loaded["alt-img._core.autodetect"] = nil
        package.loaded["alt-img.iterm2"] = nil
        package.loaded["alt-img.sixel"] = nil
    end)

    it("returns iterm2 ok when TERM_PROGRAM is iTerm.app", function()
        H.with_env({ TERM_PROGRAM = "iTerm.app" }, function()
            package.loaded["alt-img._core.autodetect"] = nil
            local autodetect = require("alt-img._core.autodetect")
            local matches = autodetect.matches({ timeout = 50 })
            assert.equals("iterm2", matches[1].name)
            assert.is_true(matches[1].ok)
            assert.equals(require("alt-img.iterm2"), matches[1].provider)
        end)
    end)

    it("probes both candidates in priority order", function()
        H.with_env({ TERM_PROGRAM = "iTerm.app" }, function()
            package.loaded["alt-img._core.autodetect"] = nil
            local autodetect = require("alt-img._core.autodetect")
            local matches = autodetect.matches({ timeout = 50 })
            assert.equals(2, #matches)
            assert.equals("iterm2", matches[1].name)
            assert.equals("sixel", matches[2].name)
        end)
    end)

    it("caches probe results across calls", function()
        H.with_env({ TERM_PROGRAM = "iTerm.app" }, function()
            package.loaded["alt-img._core.autodetect"] = nil
            local autodetect = require("alt-img._core.autodetect")
            local first = autodetect.matches({ timeout = 50 })
            local second = autodetect.matches({ timeout = 50 })
            assert.equals(first, second)
        end)
    end)

    it("returns ok=false rows when no provider supports", function()
        H.with_env({ TERM_PROGRAM = false, TERM = "dumb", TMUX = false, KITTY_WINDOW_ID = false }, function()
            package.loaded["alt-img._core.autodetect"] = nil
            local autodetect = require("alt-img._core.autodetect")
            local matches = autodetect.matches({ timeout = 50 })
            for _, m in ipairs(matches) do
                assert.is_false(m.ok)
            end
        end)
    end)
end)
