-- Verifies pure composition logic of _core/placeholder.lua.
-- Run with: nvim --headless -l test/scripts/placeholder_compose.lua

vim.opt.runtimepath:append(vim.fn.fnamemodify(arg[0], ":p:h:h:h"))
local p = require("alt-img._core.placeholder")

local function expect(label, cond, detail)
    if cond then
        print("OK  " .. label)
    else
        print("FAIL " .. label .. " — " .. tostring(detail or ""))
        os.exit(1)
    end
end

local cfg = { box = "rounded", spinner = "braille", show_percent = true }

-- Composition: 16x6, 50%, braille.
do
    local lines = p.compose(16, 6, "⣾", 50, false, cfg)
    expect("6 lines for height=6", #lines == 6, #lines)
    expect("top border starts with rounded TL", lines[1]:sub(1, 3) == "╭", lines[1])
    expect("bottom border starts with rounded BL", lines[6]:sub(1, 3) == "╰", lines[6])
    -- Caption row should contain the spinner + percent.
    local has_caption = false
    for _, line in ipairs(lines) do
        if line:find("⣾") and line:find("50%%") then
            has_caption = true
        end
    end
    expect("caption present", has_caption, table.concat(lines, "\n"))
end

-- Tiny box: 2x1.
do
    local lines = p.compose(2, 1, "⣾", nil, false, cfg)
    expect("tiny: 1 line", #lines == 1, #lines)
end

-- box='none' falls through to glyph-only.
do
    local lines = p.compose(10, 4, "⣾", 25, false, vim.tbl_extend("force", cfg, { box = "none" }))
    expect("none: no border chars", not lines[1]:find("╭"), lines[1])
    expect("none: 4 rows", #lines == 4, #lines)
end

-- error caption.
do
    local lines = p.compose(16, 4, "⣾", 50, true, cfg)
    local has_err = false
    for _, line in ipairs(lines) do
        if line:find("error") then
            has_err = true
        end
    end
    expect("error caption visible", has_err, table.concat(lines, "\n"))
end

-- progress percent.
expect("percent_from_progress nil → nil", p.percent_from_progress(nil) == nil)
expect("percent inflate done=0 total=1 → 0", p.percent_from_progress({ phase = "inflate", done = 0, total = 1 }) == 0)
expect(
    "percent encode done=total → 100",
    p.percent_from_progress({ phase = "encode", done = 100, total = 100 }) == 100
)
expect(
    "percent resize half → ~58",
    math.abs(p.percent_from_progress({ phase = "resize", done = 1, total = 2 }) - 58) <= 1
)

print("ALL OK")
os.exit(0)
