-- test/manual_init.lua
-- Boots a minimal Neovim for `make smoke-test`. We launch with --noplugin
-- (see Makefile) which skips runtimepath plugin/ auto-loading, so we
-- explicitly source the production plugin file here to exercise the same
-- command-registration path real users hit.
vim.opt.runtimepath:prepend(vim.uv.cwd())
vim.opt.mouse = "a"
vim.opt.mousemoveevent = true

vim.cmd.source(vim.uv.cwd() .. "/plugin/alt-img.lua")

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

-- :AltImg info / :AltImg refresh come from plugin/alt-img.lua (sourced
-- above). Keep AltImgProvider, AltImgDemo, AltImgMouse, AltImgDel here —
-- those are smoke-test scaffolding rather than production diagnostics.

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
        if ok and p == iterm2 then
            return "alt-img (autodetect → alt-img.iterm2)"
        end
        if ok and p == sixel then
            return "alt-img (autodetect → alt-img.sixel)"
        end
        return "alt-img (autodetect)"
    end
    return "<unknown>"
end

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
print("  :AltImg info                       (diagnostics: terminal + provider state)")
print("  :AltImg refresh                    (force re-emit after :mode / :redraw! / external clear)")
print("  :AltImgProvider iterm2|sixel|auto  (switch vim.ui.img provider)")
print("  :checkhealth alt-img alt-img.iterm2 alt-img.sixel")
