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

-- ---------------------------------------------------------------------------
-- Image source for :AltImgTest demo / mouse. Defaults to the vendored 4x4
-- fixture; `:AltImgTest path /path/to/img.png` swaps it for any PNG on disk.
-- ---------------------------------------------------------------------------

local DEFAULT_FIXTURE = vim.uv.cwd() .. "/test/fixtures/4x4.png"
local image_path = nil ---@type string?

local function resolved_image_path()
    return image_path or DEFAULT_FIXTURE
end

local function read_image()
    local path = resolved_image_path()
    local f, err = io.open(path, "rb")
    if not f then
        error("AltImgTest: failed to read " .. path .. ": " .. (err or "unknown"))
    end
    local data = f:read("*a")
    f:close()
    return data
end

-- ---------------------------------------------------------------------------
-- Mouse-follow plumbing. Same behavior as the previous :AltImgMouse, just
-- callable via :AltImgTest mouse {ui|editor|off}.
-- ---------------------------------------------------------------------------

local mouse_state = { id = nil, mode = "ui", mapping = nil }

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
    local pos = vim.fn.getmousepos()
    mouse_state.id = vim.ui.img.set(read_image(), {
        relative = mode,
        row = pos.screenrow > 0 and pos.screenrow or 1,
        col = pos.screencol > 0 and pos.screencol or 1,
        width = 4,
        height = 4,
    })
    vim.keymap.set("", "<MouseMove>", update_from_mouse, { silent = true, desc = "alt-img mouse-follow" })
    mouse_state.mapping = true
    print(
        "AltImgTest: mouse-follow on with relative="
            .. mode
            .. ". `:AltImgTest mouse off` to stop, or `:AltImgTest mouse {ui|editor}` to switch."
    )
end

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

-- ---------------------------------------------------------------------------
-- :AltImgTest subcommand registry — mirrors the lumen-oss best-practices
-- pattern used by `:AltImg` in plugin/alt-img.lua. Smoke-test scaffolding
-- only; production diagnostics live under `:AltImg`.
-- ---------------------------------------------------------------------------

local subs = {}

subs.path = {
    desc = "Show or set the PNG used by :AltImgTest demo / mouse.",
    impl = function(args)
        if #args == 0 then
            print(
                "AltImgTest: image source = " .. resolved_image_path() .. (image_path and "" or "  (default fixture)")
            )
            return
        end
        local arg = args[1]
        if arg == "default" or arg == "reset" then
            image_path = nil
            print("AltImgTest: image source reset to default fixture (" .. DEFAULT_FIXTURE .. ")")
            return
        end
        local p = vim.fn.expand(arg)
        if vim.fn.filereadable(p) ~= 1 then
            vim.notify("AltImgTest: not readable: " .. p, vim.log.levels.ERROR)
            return
        end
        image_path = p
        print("AltImgTest: image source = " .. p)
    end,
    complete = function(arg_lead)
        -- File completion handles relative/absolute/`~/` correctly via getcompletion.
        local out = vim.fn.getcompletion(arg_lead, "file")
        -- "default" / "reset" are valid bare strings too — surface them.
        for _, kw in ipairs({ "default", "reset" }) do
            if kw:find("^" .. vim.pesc(arg_lead)) then
                out[#out + 1] = kw
            end
        end
        return out
    end,
}

subs.demo = {
    desc = "Place the current image in {ui|editor|buffer} mode.",
    impl = function(args)
        local mode = args[1] or "ui"
        if mode ~= "ui" and mode ~= "editor" and mode ~= "buffer" then
            vim.notify("Usage: :AltImgTest demo {ui|editor|buffer}", vim.log.levels.ERROR)
            return
        end
        local opts = { row = 5, col = 10, width = 4, height = 4 }
        if mode == "editor" then
            opts.relative = "editor"
        elseif mode == "buffer" then
            -- buf=0 resolves to current buffer; relative='buffer' is implied.
            -- width/height stay set so the demo image stays small (otherwise
            -- they'd derive from the PNG IHDR).
            opts.buf = 0
            opts.row, opts.col = 1, 1
            opts.pad = 1
        end
        local id = vim.ui.img.set(read_image(), opts)
        print(string.format("AltImgTest demo: placed %s id=%d  (`:AltImgTest del %d` to remove)", mode, id, id))
    end,
    complete = function(arg_lead)
        local out = {}
        for _, m in ipairs({ "ui", "editor", "buffer" }) do
            if m:find("^" .. vim.pesc(arg_lead)) then
                out[#out + 1] = m
            end
        end
        return out
    end,
}

subs.del = {
    desc = "Remove a placement by id, or `inf` / `all` for everything.",
    impl = function(args)
        local arg = args[1]
        if not arg then
            vim.notify("Usage: :AltImgTest del {<id>|inf|all}", vim.log.levels.ERROR)
            return
        end
        if arg == "inf" or arg == "all" then
            vim.ui.img.del(math.huge)
            return
        end
        local id = tonumber(arg)
        if not id then
            vim.notify("AltImgTest: not a valid id: " .. arg, vim.log.levels.ERROR)
            return
        end
        vim.ui.img.del(id)
    end,
    complete = function(arg_lead)
        local out = {}
        for _, kw in ipairs({ "inf", "all" }) do
            if kw:find("^" .. vim.pesc(arg_lead)) then
                out[#out + 1] = kw
            end
        end
        return out
    end,
}

subs.mouse = {
    desc = "Image-follows-mouse. {ui|editor|off}.",
    impl = function(args)
        local arg = args[1] or "ui"
        if arg == "off" then
            mouse_off()
            return
        end
        if arg ~= "ui" and arg ~= "editor" then
            vim.notify("Usage: :AltImgTest mouse {ui|editor|off}", vim.log.levels.ERROR)
            return
        end
        mouse_on(arg)
    end,
    complete = function(arg_lead)
        local out = {}
        for _, m in ipairs({ "ui", "editor", "off" }) do
            if m:find("^" .. vim.pesc(arg_lead)) then
                out[#out + 1] = m
            end
        end
        return out
    end,
}

subs.provider = {
    desc = "Force a specific vim.ui.img provider {iterm2|sixel|auto}.",
    impl = function(args)
        local arg = args[1] or "auto"
        if arg ~= "iterm2" and arg ~= "sixel" and arg ~= "auto" then
            vim.notify("Usage: :AltImgTest provider {iterm2|sixel|auto}", vim.log.levels.ERROR)
            return
        end
        pcall(function()
            vim.ui.img.del(math.huge)
        end)
        -- Mouse-follow id was tied to the old provider; clear it.
        mouse_off()
        if arg == "iterm2" then
            vim.ui.img = require("alt-img.iterm2")
        elseif arg == "sixel" then
            vim.ui.img = require("alt-img.sixel")
        else
            package.loaded["alt-img"] = nil
            vim.ui.img = require("alt-img")
        end
        print("AltImgTest: provider = " .. provider_name())
    end,
    complete = function(arg_lead)
        local out = {}
        for _, p in ipairs({ "iterm2", "sixel", "auto" }) do
            if p:find("^" .. vim.pesc(arg_lead)) then
                out[#out + 1] = p
            end
        end
        return out
    end,
}

local function sub_names()
    local out = {}
    for k in pairs(subs) do
        out[#out + 1] = k
    end
    table.sort(out)
    return out
end

vim.api.nvim_create_user_command("AltImgTest", function(opts)
    local fargs = opts.fargs or {}
    local sub = fargs[1]
    if not sub then
        vim.notify("Usage: :AltImgTest <" .. table.concat(sub_names(), "|") .. ">", vim.log.levels.INFO)
        return
    end
    local entry = subs[sub]
    if not entry then
        vim.notify(
            string.format("AltImgTest: unknown subcommand `%s`. Try one of: %s", sub, table.concat(sub_names(), ", ")),
            vim.log.levels.ERROR
        )
        return
    end
    local rest = {}
    for i = 2, #fargs do
        rest[#rest + 1] = fargs[i]
    end
    entry.impl(rest, opts)
end, {
    nargs = "*",
    desc = "alt-img.nvim smoke-test scaffolding (path, demo, del, mouse, provider)",
    complete = function(arg_lead, line, _pos)
        local trimmed = (line or ""):gsub("^%s*AltImgTest!?%s*", "")
        local args = vim.split(trimmed, "%s+", { trimempty = true })
        local has_trailing_space = trimmed:match("%s$") ~= nil
        local completing_sub = (#args == 0) or (#args == 1 and not has_trailing_space)
        if completing_sub then
            local out = {}
            for _, name in ipairs(sub_names()) do
                if name:find("^" .. vim.pesc(arg_lead)) then
                    out[#out + 1] = name
                end
            end
            return out
        end
        local entry = subs[args[1]]
        if entry and entry.complete then
            return entry.complete(arg_lead) or {}
        end
        return {}
    end,
})

print("alt-img.nvim smoke test ready.")
print("Try:")
print("  :AltImgTest path /path/to/img.png   (set the image used by demo / mouse)")
print("  :AltImgTest path                    (show current image source)")
print("  :AltImgTest path default            (reset to test/fixtures/4x4.png)")
print("  :AltImgTest demo {ui|editor|buffer} (place a static image)")
print("  :AltImgTest del {<id>|inf|all}      (remove a placement)")
print("  :AltImgTest mouse {ui|editor|off}   (image follows mouse)")
print("  :AltImgTest provider {iterm2|sixel|auto} (force a provider)")
print("  :AltImg info                        (production diagnostics)")
print("  :AltImg refresh                     (force re-emit)")
print("  :checkhealth alt-img alt-img.iterm2 alt-img.sixel")
