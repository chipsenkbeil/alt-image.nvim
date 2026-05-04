describe("_core.placeholder compose", function()
    local p = require("alt-img._core.placeholder")
    local cfg = { box = "rounded", spinner = "braille", show_percent = true }

    it("renders a 16x6 rounded box with caption", function()
        local lines = p.compose(16, 6, "⣾", 50, false, cfg)
        assert.eq(#lines, 6, "6 rows for height=6")
        assert.match(lines[1], "^╭", "top border starts with rounded TL")
        assert.match(lines[6], "^╰", "bottom border starts with rounded BL")
        local has_caption = false
        for _, line in ipairs(lines) do
            if line:find("⣾") and line:find("50%%") then
                has_caption = true
            end
        end
        assert.truthy(has_caption, "caption row contains glyph + percent")
    end)

    it("handles tiny 2x1 placement", function()
        local lines = p.compose(2, 1, "⣾", nil, false, cfg)
        assert.eq(#lines, 1)
    end)

    it("box='none' falls through to glyph-only fill", function()
        local lines = p.compose(10, 4, "⣾", 25, false, vim.tbl_extend("force", cfg, { box = "none" }))
        assert.eq(#lines, 4)
        assert.falsy(lines[1]:find("╭"), "no border chars when box=none")
    end)

    it("error caption visible when errored=true", function()
        local lines = p.compose(16, 4, "⣾", 50, true, cfg)
        local has_err = false
        for _, line in ipairs(lines) do
            if line:find("error") then
                has_err = true
            end
        end
        assert.truthy(has_err)
    end)
end)

describe("_core.placeholder percent_from_progress", function()
    local p = require("alt-img._core.placeholder")

    it("nil progress returns nil", function()
        assert.eq(p.percent_from_progress(nil), nil)
    end)

    it("inflate done=0 total=1 returns 0", function()
        assert.eq(p.percent_from_progress({ phase = "inflate", done = 0, total = 1 }), 0)
    end)

    it("encode done=total returns 100", function()
        assert.eq(p.percent_from_progress({ phase = "encode", done = 100, total = 100 }), 100)
    end)

    it("resize half returns ~58 (cumulative weighting)", function()
        local pct = p.percent_from_progress({ phase = "resize", done = 1, total = 2 })
        assert.near(pct, 58, 1)
    end)
end)
