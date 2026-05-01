-- test/manual_init.lua
-- Boots a minimal Neovim for `make smoke-test`.
vim.opt.runtimepath:prepend(vim.uv.cwd())
vim.opt.mouse = "a"
vim.opt.mousemoveevent = true

local altimg = require("alt-img")
vim.ui.img = altimg

local function read_fixture()
    local f = io.open("test/fixtures/4x4.png", "rb")
    local b = f:read("*a")
    f:close()
    return b
end

vim.api.nvim_create_user_command("AltImgDemo", function(o)
    local mode = o.args ~= "" and o.args or "ui"
    local data = read_fixture()
    local opts = { row = 5, col = 10, width = 4, height = 4 }
    if mode == "editor" then
        opts.relative = "editor"
    elseif mode == "buffer" then
        -- Demonstrate PR #39496 defaulting: opts.buf set => relative='buffer';
        -- buf=0 resolves to the current buffer. width/height are kept from above
        -- so the demo image stays small (otherwise they'd derive from the PNG).
        opts.buf = 0
        opts.row, opts.col = 1, 1
        opts.pad = 1
    end
    local id = vim.ui.img.set(data, opts)
    print(string.format("AltImgDemo: placed %s id=%d (run :AltImgDel %d to remove)", mode, id, id))
end, { nargs = "?" })

vim.api.nvim_create_user_command("AltImgDel", function(o)
    local arg = o.args
    if arg == "inf" or arg == "all" then
        vim.ui.img.del(math.huge)
        return
    end
    local id = tonumber(arg)
    if not id then
        print("Usage: AltImgDel <id> | AltImgDel inf")
        return
    end
    vim.ui.img.del(id)
end, { nargs = 1 })

-- Image-follows-mouse mode. Toggle on/off and switch the relative= mode
-- without removing/recreating the placement (uses set(id, opts) updates).
local mouse_state = { id = nil, mode = "ui", mapping = nil }

-- Coalesce mouse-follow updates: <MouseMove> can fire faster than the
-- synchronous render flush completes. Defer via vim.schedule and read the
-- latest mouse position lazily inside the scheduled callback. While a
-- schedule is pending, subsequent fires return early — they all collapse
-- into a single set() at the latest position.
local update_pending = false
local function update_from_mouse()
    if not mouse_state.id or update_pending then
        return
    end
    update_pending = true
    vim.schedule(function()
        update_pending = false
        if not mouse_state.id then
            return
        end
        local pos = vim.fn.getmousepos()
        local opts
        if mouse_state.mode == "ui" then
            opts = { relative = "ui", row = pos.screenrow, col = pos.screencol }
        else
            opts = { relative = "editor", row = pos.screenrow, col = pos.screencol }
        end
        vim.ui.img.set(mouse_state.id, opts)
    end)
end

local function mouse_off()
    if mouse_state.mapping then
        pcall(vim.keymap.del, "", "<MouseMove>")
        mouse_state.mapping = nil
    end
    if mouse_state.id then
        vim.ui.img.del(mouse_state.id)
        mouse_state.id = nil
    end
end

local function mouse_on(mode)
    mouse_off()
    mouse_state.mode = mode
    local data = read_fixture()
    local pos = vim.fn.getmousepos()
    mouse_state.id = vim.ui.img.set(data, {
        relative = mode,
        row = pos.screenrow > 0 and pos.screenrow or 1,
        col = pos.screencol > 0 and pos.screencol or 1,
        width = 4,
        height = 4,
    })
    vim.keymap.set("", "<MouseMove>", update_from_mouse, { silent = true, desc = "alt-img mouse-follow" })
    mouse_state.mapping = true
    print(
        "AltImgMouse: following mouse with relative="
            .. mode
            .. ". Run :AltImgMouse off to stop, or :AltImgMouse <ui|editor> to switch."
    )
end

vim.api.nvim_create_user_command("AltImgMouse", function(o)
    local arg = o.args ~= "" and o.args or "ui"
    if arg == "off" then
        mouse_off()
        return
    end
    if arg ~= "ui" and arg ~= "editor" then
        print("Usage: AltImgMouse {ui|editor|off}")
        return
    end
    mouse_on(arg)
end, {
    nargs = "?",
    complete = function()
        return { "ui", "editor", "off" }
    end,
})

-- Helper to identify the active vim.ui.img provider. When the autodetect
-- dispatcher is in use, also resolve which underlying protocol it picked
-- (only after the cache is warm — runs detection if not).
local function provider_name()
    local img = vim.ui.img
    local iterm2 = require("alt-img.iterm2")
    local sixel = require("alt-img.sixel")
    if img == iterm2 then
        return "alt-img.iterm2"
    end
    if img == sixel then
        return "alt-img.sixel"
    end
    if img == require("alt-img") then
        local ok, p = pcall(img._provider)
        if not ok or not p then
            return "alt-img (autodetect, not yet resolved)"
        end
        if p == iterm2 then
            return "alt-img (autodetect → alt-img.iterm2)"
        end
        if p == sixel then
            return "alt-img (autodetect → alt-img.sixel)"
        end
        return "alt-img (autodetect → <unknown>)"
    end
    return "<unknown>"
end

-- Force re-emit of every placement. Useful after `:mode`, `:redraw!`, or
-- any other terminal-side wipe that leaves image cells blank without
-- changing the placement's resolved screen position.
vim.api.nvim_create_user_command("AltImgRefresh", function()
    if vim.ui.img and vim.ui.img.refresh then
        vim.ui.img.refresh()
    else
        print("alt-img: vim.ui.img.refresh() not available")
    end
end, {})

vim.api.nvim_create_user_command("AltImgInfo", function()
    local util = require("alt-img._core.util")
    local lines = {
        "alt-img.nvim diagnostics",
        "==========================",
        "Terminal env:",
        string.format("  TERM           = %s", tostring(vim.env.TERM)),
        string.format("  TERM_PROGRAM   = %s", tostring(vim.env.TERM_PROGRAM)),
        string.format("  COLORTERM      = %s", tostring(vim.env.COLORTERM)),
        string.format("  TMUX           = %s", tostring(vim.env.TMUX)),
        string.format("  SSH_CONNECTION = %s", tostring(vim.env.SSH_CONNECTION)),
        "",
        "Neovim:",
        string.format("  version        = v%d.%d.%d", vim.version().major, vim.version().minor, vim.version().patch),
    }

    -- Cell pixel size — what the providers use to convert opts.width/height
    -- (in cells) to pixel dims for the encoder. Trigger a fresh CSI 16t
    -- query if we haven't asked yet so the printed value reflects the
    -- terminal's current cell metrics, not the platform default.
    pcall(util.query_cell_size)
    local cw, ch = util.cell_pixel_size()
    table.insert(lines, "")
    table.insert(lines, "Cell pixel size (CSI 16t):")
    table.insert(lines, string.format("  width  = %d px", cw))
    table.insert(lines, string.format("  height = %d px", ch))
    table.insert(lines, string.format("  queried = %s", tostring(util._cell_size_queried)))

    table.insert(lines, "")
    table.insert(lines, "Active vim.ui.img provider:")
    table.insert(lines, "  module         = " .. provider_name())

    table.insert(lines, "")
    table.insert(lines, "Per-provider _supported():")
    local i_ok, i_msg = require("alt-img.iterm2")._supported()
    local s_ok, s_msg = require("alt-img.sixel")._supported()
    table.insert(lines, string.format("  iterm2._supported() = %s, %s", tostring(i_ok), i_msg or "no message"))
    table.insert(lines, string.format("  sixel._supported()  = %s, %s", tostring(s_ok), s_msg or "no message"))

    -- External tools + PNG compression status
    local g = vim.g.alt_img or {}
    local magick = require("alt-img._core.magick").binary()
    local libsixel = require("alt-img.sixel._libsixel").binary()
    local png_encode = require("alt-img._core.png")
    table.insert(lines, "")
    table.insert(lines, "External tools:")
    table.insert(lines, string.format("  vim.g.alt_img.magick    = %s", vim.inspect(g.magick)))
    table.insert(lines, string.format("  vim.g.alt_img.img2sixel = %s", vim.inspect(g.img2sixel)))
    table.insert(lines, string.format("  resolved magick           = %s", magick or "not used"))
    table.insert(lines, string.format("  resolved img2sixel        = %s", libsixel or "not used"))
    table.insert(
        lines,
        string.format(
            "  PNG libz compression      = %s",
            png_encode.has_libz() and "active" or "fallback (stored blocks)"
        )
    )
    -- Sixel-specific: the encoder multiplies opts.width/height × cell pixels
    -- by this factor before handing to magick / img2sixel. The encoder
    -- combines two auto-detect signals (taking the larger) when the user
    -- hasn't set vim.g.alt_img.sixel_pixel_scale:
    --   1. OSC 1337 ; ReportCellSize — iTerm2/WezTerm only.
    --   2. CSI 14t/18t ÷ CSI 16t      — chafa's geometry trick.
    -- Both are shown below so it's obvious which one (if any) fired and
    -- whether they agree.
    local osc, geom = util.terminal_pixel_scale_sources()
    local final_auto = util.terminal_pixel_scale()
    local effective = (type(g.sixel_pixel_scale) == "number" and g.sixel_pixel_scale >= 1)
            and math.floor(g.sixel_pixel_scale)
        or final_auto
    table.insert(lines, string.format("  vim.g.alt_img.sixel_pixel_scale = %s", vim.inspect(g.sixel_pixel_scale)))
    table.insert(
        lines,
        string.format("  scale via OSC 1337              = %s", osc > 0 and (osc .. "×") or "no answer")
    )
    table.insert(
        lines,
        string.format("  scale via CSI 14t/18t/16t       = %s", geom > 0 and (geom .. "×") or "no signal")
    )
    table.insert(lines, string.format("  scale chosen by auto-detect     = %d×", final_auto))
    table.insert(lines, string.format("  scale actually used (effective) = %d×", effective))

    -- Active placements per provider, with their resolved opts (post-derive_dims).
    -- Useful when the displayed image looks wrong-sized — opts.width/height
    -- here are in cells, and the encoder targets opts.* × cell_pixel_size.
    local function dump_placements(provider_label, mod)
        local state = mod._state or {}
        local rows = {}
        for id, s in pairs(state) do
            rows[#rows + 1] = id
        end
        table.sort(rows)
        if #rows == 0 then
            table.insert(lines, string.format("  %s: no placements", provider_label))
            return
        end
        table.insert(lines, string.format("  %s:", provider_label))
        for _, id in ipairs(rows) do
            local s = state[id]
            local o = s.opts or {}
            table.insert(
                lines,
                string.format(
                    "    id=%d  relative=%s  row=%s col=%s  width=%s height=%s  buf=%s  → target=%s×%s px",
                    id,
                    tostring(o.relative),
                    tostring(o.row),
                    tostring(o.col),
                    tostring(o.width),
                    tostring(o.height),
                    tostring(o.buf),
                    tostring((o.width or 0) * cw),
                    tostring((o.height or 0) * ch)
                )
            )
        end
    end
    table.insert(lines, "")
    table.insert(lines, "Active placements:")
    dump_placements("alt-img.iterm2", require("alt-img.iterm2"))
    dump_placements("alt-img.sixel", require("alt-img.sixel"))

    for _, l in ipairs(lines) do
        print(l)
    end
end, {})

vim.api.nvim_create_user_command("AltImgProvider", function(o)
    local arg = o.args ~= "" and o.args or "auto"
    if arg ~= "iterm2" and arg ~= "sixel" and arg ~= "auto" then
        print("Usage: AltImgProvider {iterm2|sixel|auto}")
        return
    end

    -- Clear old placements via the currently-active provider
    pcall(function()
        vim.ui.img.del(math.huge)
    end)

    -- If mouse-follow is active, kill it (its mouse_state.id was tied to the old provider).
    pcall(function()
        vim.cmd("AltImgMouse off")
    end)

    if arg == "iterm2" then
        vim.ui.img = require("alt-img.iterm2")
    elseif arg == "sixel" then
        vim.ui.img = require("alt-img.sixel")
    else
        -- auto: reset autodetect cache + reload alt-img so detect() runs fresh
        package.loaded["alt-img"] = nil
        vim.ui.img = require("alt-img")
    end
    print("AltImgProvider: now using " .. provider_name())
end, {
    nargs = "?",
    complete = function()
        return { "iterm2", "sixel", "auto" }
    end,
})

print("alt-img.nvim smoke test ready.")
print("Try:")
print("  :AltImgDemo ui|editor|buffer")
print("  :AltImgDel <id>     (or `inf` to clear all)")
print("  :AltImgMouse ui     (image follows mouse, absolute terminal coords)")
print("  :AltImgMouse editor (image follows mouse, relative to editor)")
print("  :AltImgMouse off    (stop following)")
print("  :AltImgInfo                    (diagnostics: terminal + provider state)")
print("  :AltImgRefresh                 (force re-emit after :mode / :redraw! / external clear)")
print("  :AltImgProvider iterm2|sixel|auto  (switch vim.ui.img provider)")
print("  :checkhealth alt-img alt-img.iterm2 alt-img.sixel")
