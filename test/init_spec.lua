local H = require("test.helpers")

local function read_fixture()
    local f = io.open("test/fixtures/4x4.png", "rb")
    local b = f:read("*a")
    f:close()
    return b
end

describe("alt-img init", function()
    local saved_g
    before_each(function()
        package.loaded["alt-img"] = nil
        package.loaded["alt-img.iterm2"] = nil
        package.loaded["alt-img.sixel"] = nil
        saved_g = vim.g.alt_img
        vim.g.alt_img = nil
    end)

    after_each(function()
        vim.g.alt_img = saved_g
        package.loaded["alt-img"] = nil
        package.loaded["alt-img.iterm2"] = nil
        package.loaded["alt-img.sixel"] = nil
    end)

    it("picks iterm2 when TERM_PROGRAM=iTerm.app", function()
        H.with_env({ TERM_PROGRAM = "iTerm.app" }, function()
            local m = require("alt-img")
            assert.equals(require("alt-img.iterm2"), m._provider())
        end)
    end)

    it("picks sixel when TERM matches sixel", function()
        H.with_env({ TERM_PROGRAM = false, TERM = "xterm-sixel" }, function()
            local m = require("alt-img")
            assert.equals(require("alt-img.sixel"), m._provider())
        end)
    end)

    it("forwards set/get/del to chosen provider", function()
        H.with_env({ TERM_PROGRAM = "iTerm.app" }, function()
            H.setup_capture()
            local m = require("alt-img")
            local id = m.set(read_fixture(), { row = 1, col = 1 })
            assert.is_true(type(id) == "number")
            assert.same({ row = 1, col = 1, relative = "ui" }, m.get(id))
            assert.is_true(m.del(id))
        end)
    end)

    it("rejects non-PNG data at the boundary", function()
        H.with_env({ TERM_PROGRAM = "iTerm.app" }, function()
            local m = require("alt-img")
            local ok, err = pcall(m.set, "not a png", { row = 1, col = 1 })
            assert.is_false(ok)
            assert.matches("PNG", tostring(err))
        end)
    end)
end)
