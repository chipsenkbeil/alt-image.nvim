-- Subcommand implementations for the production `:AltImg` user command.
-- Layout follows the lumen-oss nvim-best-practices pattern: a single
-- top-level command dispatches to entries in `M.subcommands`, each
-- carrying an `impl` (and optional `complete`) callback. The plugin
-- script in `plugin/alt-img.lua` is the only auto-loaded file; this
-- module is `require()`d lazily by the dispatcher so plugin startup
-- stays cheap.

local M = {}

---@class altimg.Subcommand
---@field impl fun(args:string[], opts:table)
---@field complete? fun(arg_lead:string):string[]
---@field desc? string

-- Resolve a friendly name for the active vim.ui.img provider, including
-- the underlying choice when the autodetect dispatcher is in use. Falls
-- back to a `<not active>` string when the user hasn't loaded any of our
-- providers — `:AltImg info` still prints something useful in that case.
local function provider_name()
    local img = vim.ui.img
    if not img then
        return "<vim.ui.img not set>"
    end
    local ok_iterm2, iterm2 = pcall(require, "alt-img.iterm2")
    local ok_sixel, sixel = pcall(require, "alt-img.sixel")
    if ok_iterm2 and img == iterm2 then
        return "alt-img.iterm2"
    end
    if ok_sixel and img == sixel then
        return "alt-img.sixel"
    end
    local ok_dispatcher, dispatcher = pcall(require, "alt-img")
    if ok_dispatcher and img == dispatcher then
        local ok, p = pcall(dispatcher._provider)
        if not ok or not p then
            return "alt-img (autodetect, not yet resolved)"
        end
        if ok_iterm2 and p == iterm2 then
            return "alt-img (autodetect → alt-img.iterm2)"
        end
        if ok_sixel and p == sixel then
            return "alt-img (autodetect → alt-img.sixel)"
        end
        return "alt-img (autodetect → <unknown>)"
    end
    return "<unknown vim.ui.img provider>"
end

---Append a per-placement listing of `mod._state` to `lines`. Used by
---`info` to surface what each provider has open and what its resolved
---opts → target pixel dims look like.
---@param lines string[]
---@param label string
---@param mod table provider module exposing `_state`
---@param cw integer cell width in pixels
---@param ch integer cell height in pixels
local function dump_placements(lines, label, mod, cw, ch)
    local state = (mod and mod._state) or {}
    local ids = {}
    for id, _ in pairs(state) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    if #ids == 0 then
        lines[#lines + 1] = string.format("  %s: no placements", label)
        return
    end
    lines[#lines + 1] = string.format("  %s:", label)
    for _, id in ipairs(ids) do
        local o = state[id].opts or {}
        lines[#lines + 1] = string.format(
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
    end
end

---Build the diagnostic dump as a list of lines so callers (the user
---command, tests, future hover-buffer integrations) can format it as
---they like.
---@return string[]
function M.info_lines()
    local util = require("alt-img._core.util")
    local g = vim.g.alt_img or {}

    local lines = {
        "alt-img.nvim diagnostics",
        "==========================",
        "Terminal env:",
        string.format("  TERM            = %s", tostring(vim.env.TERM)),
        string.format("  TERM_PROGRAM    = %s", tostring(vim.env.TERM_PROGRAM)),
        string.format("  COLORTERM       = %s", tostring(vim.env.COLORTERM)),
        string.format("  TMUX            = %s", tostring(vim.env.TMUX)),
        string.format("  KONSOLE_VERSION = %s", tostring(vim.env.KONSOLE_VERSION)),
        string.format("  SSH_CONNECTION  = %s", tostring(vim.env.SSH_CONNECTION)),
        "",
        "Neovim:",
        string.format("  version         = v%d.%d.%d", vim.version().major, vim.version().minor, vim.version().patch),
    }

    pcall(util.query_cell_size)
    local cw, ch = util.cell_pixel_size()
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Cell pixel size (CSI 16t):"
    lines[#lines + 1] = string.format("  width  = %d px", cw)
    lines[#lines + 1] = string.format("  height = %d px", ch)
    lines[#lines + 1] = string.format("  queried = %s", tostring(util._cell_size_queried))

    lines[#lines + 1] = ""
    lines[#lines + 1] = "Active vim.ui.img provider:"
    lines[#lines + 1] = "  module          = " .. provider_name()

    lines[#lines + 1] = ""
    lines[#lines + 1] = "Per-provider _supported():"
    local i_ok, i_msg = require("alt-img.iterm2")._supported()
    local s_ok, s_msg = require("alt-img.sixel")._supported()
    lines[#lines + 1] = string.format("  iterm2._supported() = %s, %s", tostring(i_ok), i_msg or "no message")
    lines[#lines + 1] = string.format("  sixel._supported()  = %s, %s", tostring(s_ok), s_msg or "no message")

    local magick = require("alt-img._core.magick").binary()
    local libsixel = require("alt-img.sixel._libsixel").binary()
    local png = require("alt-img._core.png")
    lines[#lines + 1] = ""
    lines[#lines + 1] = "External tools:"
    lines[#lines + 1] = string.format("  vim.g.alt_img.magick    = %s", vim.inspect(g.magick))
    lines[#lines + 1] = string.format("  vim.g.alt_img.img2sixel = %s", vim.inspect(g.img2sixel))
    lines[#lines + 1] = string.format("  resolved magick         = %s", magick or "not used")
    lines[#lines + 1] = string.format("  resolved img2sixel      = %s", libsixel or "not used")
    lines[#lines + 1] =
        string.format("  PNG libz compression    = %s", png.has_libz() and "active" or "fallback (stored blocks)")

    -- sixel pixel scale: explicit override + per-source auto-detect breakdown +
    -- the value the encoder will actually multiply by.
    local osc, geom = util.terminal_pixel_scale_sources()
    local final_auto = util.terminal_pixel_scale()
    local effective = (type(g.sixel_pixel_scale) == "number" and g.sixel_pixel_scale >= 1)
            and math.floor(g.sixel_pixel_scale)
        or final_auto
    lines[#lines + 1] = string.format("  vim.g.alt_img.sixel_pixel_scale = %s", vim.inspect(g.sixel_pixel_scale))
    lines[#lines + 1] =
        string.format("  scale via OSC 1337              = %s", osc > 0 and (osc .. "×") or "no answer")
    lines[#lines + 1] =
        string.format("  scale via CSI 14t/18t/16t       = %s", geom > 0 and (geom .. "×") or "no signal")
    lines[#lines + 1] = string.format("  scale chosen by auto-detect     = %d×", final_auto)
    lines[#lines + 1] = string.format("  scale actually used (effective) = %d×", effective)

    lines[#lines + 1] = ""
    lines[#lines + 1] = "Active placements:"
    dump_placements(lines, "alt-img.iterm2", require("alt-img.iterm2"), cw, ch)
    dump_placements(lines, "alt-img.sixel", require("alt-img.sixel"), cw, ch)

    return lines
end

---@type table<string, altimg.Subcommand>
-- Open a scratch buffer in a horizontal split below, populate it with
-- `lines`, mark non-modifiable, and bind `q` to close. We use a buffer
-- instead of print() so the diagnostic dump never triggers nvim's
-- hit-enter prompt — and therefore never causes the terminal-side full
-- redraw that wipes our image cells. Closing the split fires WinClosed,
-- which the render loop's force-dirty autocmd group already covers, so
-- placements re-emit naturally.
local function open_scratch(title, lines)
    local buf = vim.api.nvim_create_buf(false, true) -- listed=false, scratch=true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
    vim.bo[buf].filetype = "altimginfo"
    pcall(vim.api.nvim_buf_set_name, buf, title)
    -- Cap the split height so a long dump doesn't claim the whole screen.
    local height = math.min(#lines + 1, math.max(10, math.floor(vim.o.lines * 0.5)))
    vim.cmd("botright " .. height .. "new")
    vim.api.nvim_win_set_buf(0, buf)
    vim.wo.wrap = false
    vim.wo.number = false
    vim.wo.relativenumber = false
    vim.wo.signcolumn = "no"
    vim.keymap.set(
        "n",
        "q",
        "<cmd>close<cr>",
        { buffer = buf, nowait = true, silent = true, desc = "close alt-img info" }
    )
    vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
end

M.subcommands = {
    info = {
        desc = "Open a scratch buffer with runtime diagnostics (terminal env, cell size, scale, active placements). `q` to close.",
        impl = function()
            open_scratch("alt-img://info", M.info_lines())
        end,
    },
    refresh = {
        desc = "Force every placement to re-emit (use after :mode, :redraw!, external clears).",
        impl = function()
            local img = vim.ui.img
            if img and img.refresh then
                img.refresh()
            else
                vim.notify("alt-img: vim.ui.img.refresh() not available", vim.log.levels.WARN)
            end
        end,
    },
}

---Sorted list of subcommand names, for completion and help text.
---@return string[]
function M.subcommand_names()
    local out = {}
    for name in pairs(M.subcommands) do
        out[#out + 1] = name
    end
    table.sort(out)
    return out
end

---Dispatch entry point called from the :AltImg user command.
---@param opts table The opts table Neovim passes to nvim_create_user_command callbacks.
function M.dispatch(opts)
    local fargs = opts.fargs or {}
    local sub = fargs[1]
    if not sub then
        local names = table.concat(M.subcommand_names(), ", ")
        vim.notify("Usage: :AltImg <subcommand>\nAvailable: " .. names, vim.log.levels.INFO)
        return
    end
    local entry = M.subcommands[sub]
    if not entry then
        vim.notify(
            string.format(
                "AltImg: unknown subcommand `%s`. Try one of: %s",
                sub,
                table.concat(M.subcommand_names(), ", ")
            ),
            vim.log.levels.ERROR
        )
        return
    end
    local rest = {}
    for i = 2, #fargs do
        rest[#rest + 1] = fargs[i]
    end
    entry.impl(rest, opts)
end

---Completion callback. When the user is still typing the subcommand
---name, suggest matching subcommand names. Once a subcommand has been
---chosen, delegate to its `complete` callback if present.
---@param arg_lead string
---@param line string Full command line up to cursor.
---@return string[]
function M.complete(arg_lead, line, _pos)
    -- Strip the leading `AltImg` token (with optional `!`) and any space.
    local trimmed = (line or ""):gsub("^%s*AltImg!?%s*", "")
    local args = vim.split(trimmed, "%s+", { trimempty = true })
    local has_trailing_space = trimmed:match("%s$") ~= nil
    local completing_sub = (#args == 0) or (#args == 1 and not has_trailing_space)
    if completing_sub then
        local out = {}
        for _, name in ipairs(M.subcommand_names()) do
            if name:find("^" .. vim.pesc(arg_lead)) then
                out[#out + 1] = name
            end
        end
        return out
    end
    local entry = M.subcommands[args[1]]
    if entry and entry.complete then
        return entry.complete(arg_lead) or {}
    end
    return {}
end

return M
