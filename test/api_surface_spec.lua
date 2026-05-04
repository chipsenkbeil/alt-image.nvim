local H = require("test.helpers")

describe("alt-img public API surface", function()
    local EXPECTED = { set = true, get = true, del = true, _supported = true }

    local function keys_of(m)
        local ks = {}
        for k in pairs(m) do
            ks[k] = true
        end
        return ks
    end

    before_each(function()
        package.loaded["alt-img"] = nil
        package.loaded["alt-img.iterm2"] = nil
        package.loaded["alt-img.sixel"] = nil
        package.loaded["alt-img._core.autodetect"] = nil
    end)

    it("alt-img exposes exactly { set, get, del, _supported }", function()
        H.with_env({ TERM_PROGRAM = "iTerm.app" }, function()
            package.loaded["alt-img"] = nil
            package.loaded["alt-img._core.autodetect"] = nil
            assert.same(EXPECTED, keys_of(require("alt-img")))
        end)
    end)

    it("alt-img.iterm2 exposes exactly { set, get, del, _supported }", function()
        assert.same(EXPECTED, keys_of(require("alt-img.iterm2")))
    end)

    it("alt-img.sixel exposes exactly { set, get, del, _supported }", function()
        assert.same(EXPECTED, keys_of(require("alt-img.sixel")))
    end)
end)
