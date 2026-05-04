local M = {}

---@class alt-img._core.placeholder.BoxStyle
---@field tl string top-left corner glyph
---@field tr string top-right corner glyph
---@field bl string bottom-left corner glyph
---@field br string bottom-right corner glyph
---@field h string horizontal edge glyph
---@field v string vertical edge glyph

---@type table<string, alt-img._core.placeholder.BoxStyle>
local BOX = {
    rounded = { tl = "╭", tr = "╮", bl = "╰", br = "╯", h = "─", v = "│" },
    single = { tl = "┌", tr = "┐", bl = "└", br = "┘", h = "─", v = "│" },
    dotted = { tl = "┌", tr = "┐", bl = "└", br = "┘", h = "╌", v = "╎" },
    heavy = { tl = "┏", tr = "┓", bl = "┗", br = "┛", h = "━", v = "┃" },
}

---@type table<string, string[]>
local SPINNER = {
    braille = { "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" },
    quarter = { "◜", "◝", "◞", "◟" },
    half = { "◐", "◓", "◑", "◒" },
    bar = { "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█", "▉", "▊", "▋", "▌", "▍", "▎" },
    fade = { "░", "▒", "▓", "█", "▓", "▒" },
    classic = { "|", "/", "-", "\\" },
}

---Return the active BOX/SPINNER tables for a given config.
---@param cfg alt-img._core.PlaceholderConfig
---@return alt-img._core.placeholder.BoxStyle? box, string[] spinner_glyphs
function M.styles(cfg)
    local box = BOX[cfg.box or "rounded"] -- nil for 'none'
    local spinner = SPINNER[cfg.spinner or "braille"] or SPINNER.braille
    return box, spinner
end

---Pad `s` to `width` cells, repeating `fill` if needed. Treats each char as
---one cell (callers control content; box glyphs are 1 cell each in monospace).
---@param s string
---@param width integer
---@param fill string
---@return string
local function pad_to(s, width, fill)
    local n = vim.fn.strdisplaywidth(s)
    if n >= width then
        return s
    end
    return s .. string.rep(fill, width - n)
end

---Compose placeholder lines for the given cell rectangle.
---@param width_cells integer
---@param height_cells integer
---@param spinner_glyph string
---@param percent integer? (0-100, optional caption)
---@param errored boolean
---@param cfg alt-img._core.PlaceholderConfig
---@return string[] lines (length == height_cells when possible)
function M.compose(width_cells, height_cells, spinner_glyph, percent, errored, cfg)
    if width_cells < 1 or height_cells < 1 then
        return {}
    end
    local box, _ = M.styles(cfg)

    -- Ultra-tiny: just the spinner glyph filling whatever fits.
    if width_cells < 3 or height_cells < 1 or cfg.box == "none" or not box then
        local lines = {}
        local glyph_line = pad_to(spinner_glyph, width_cells, " ")
        for _ = 1, height_cells do
            lines[#lines + 1] = glyph_line
        end
        return lines
    end

    -- Caption text inside the box.
    local caption
    if errored then
        caption = spinner_glyph .. " ! error"
    elseif cfg.show_percent and percent then
        caption = string.format("%s %d%%", spinner_glyph, percent)
    else
        caption = spinner_glyph
    end

    -- If width is too small to fit the caption with side borders, drop the caption to glyph only.
    local caption_w = vim.fn.strdisplaywidth(caption)
    local inner_w = width_cells - 2
    if caption_w > inner_w then
        caption = spinner_glyph
        caption_w = vim.fn.strdisplaywidth(caption)
    end

    local lines = {}

    -- Top border.
    if height_cells >= 2 then
        lines[#lines + 1] = box.tl .. string.rep(box.h, inner_w) .. box.tr
    end

    -- Inner rows.
    local inner_rows = math.max(0, height_cells - 2)
    local caption_row = math.floor(inner_rows / 2) + 1 -- 1-based within inner
    for i = 1, inner_rows do
        if i == caption_row then
            local pad_left = math.floor((inner_w - caption_w) / 2)
            local pad_right = inner_w - caption_w - pad_left
            lines[#lines + 1] = box.v .. string.rep(" ", pad_left) .. caption .. string.rep(" ", pad_right) .. box.v
        else
            lines[#lines + 1] = box.v .. string.rep(" ", inner_w) .. box.v
        end
    end

    -- Bottom border.
    if height_cells >= 2 then
        lines[#lines + 1] = box.bl .. string.rep(box.h, inner_w) .. box.br
    end

    -- Edge case: height_cells == 1 → just one row with the caption.
    if height_cells == 1 then
        lines = { pad_to(caption, width_cells, " ") }
    end

    return lines
end

---Compute weighted progress percent across encode phases.
---@param progress { phase: string, done: integer?, total: integer? }?
---@return integer? percent (0-100)
function M.percent_from_progress(progress)
    if not progress then
        return nil
    end
    local weights = { inflate = 0.50, resize = 0.15, quantize = 0.10, encode = 0.25 }
    local cumulative = { inflate = 0, resize = 0.50, quantize = 0.65, encode = 0.75 }
    local w = weights[progress.phase]
    if not w then
        return nil
    end
    local frac = 0
    if progress.total and progress.total > 0 then
        frac = math.min(1, (progress.done or 0) / progress.total)
    end
    local p = (cumulative[progress.phase] + w * frac) * 100
    return math.max(0, math.min(100, math.floor(p + 0.5)))
end

---@class alt-img._core.placeholder.Entry
---@field carrier_kind 'editor'|'buffer'|'ui'
---@field bufnr integer? (editor + ui kinds)
---@field extmark_id integer? (buffer kind)
---@field extmark_bufnr integer? (buffer kind)
---@field id integer|any
---@field opts vim.ui.img.Opts
---@field spinner_index integer
---@field last_progress { phase: string, done: integer?, total: integer? }?
---@field errored boolean

---@type table<string, alt-img._core.placeholder.Entry>
local loading = {} -- keyed by tostring(provider) .. ":" .. id

local function key_for(provider, id)
    return tostring(provider) .. ":" .. tostring(id)
end

-- Highlight namespace for placeholder lines drawn into a buffer.
local PLACEHOLDER_NS = vim.api.nvim_create_namespace("alt-img._core.placeholder")

-- Existing carrier namespace name — MUST match the literal in carrier.lua line 4
-- so buffer-kind virt_lines rewrites address the same extmark id.
local CARRIER_NS_NAME = "alt-img._core.carrier"

---@type uv_timer_t?
local timer = nil

local function read_cfg()
    return require("alt-img._core.config").read().placeholder or {}
end

---Render the current spinner+caption frame for one entry into its carrier.
---@param entry alt-img._core.placeholder.Entry
local function render_one(entry)
    local cfg = read_cfg()
    local _, glyphs = M.styles(cfg)
    local glyph = glyphs[((entry.spinner_index - 1) % #glyphs) + 1]
    local percent = M.percent_from_progress(entry.last_progress)
    local w = entry.opts.width or 1
    local h = entry.opts.height or 1
    local lines = M.compose(w, h, glyph, percent, entry.errored, cfg)
    if entry.carrier_kind == "editor" or entry.carrier_kind == "ui" then
        if entry.bufnr and vim.api.nvim_buf_is_valid(entry.bufnr) then
            pcall(vim.api.nvim_buf_set_lines, entry.bufnr, 0, -1, false, lines)
            pcall(vim.api.nvim_buf_clear_namespace, entry.bufnr, PLACEHOLDER_NS, 0, -1)
            for i, _ in ipairs(lines) do
                pcall(vim.api.nvim_buf_add_highlight, entry.bufnr, PLACEHOLDER_NS, "AltImgPlaceholder", i - 1, 0, -1)
            end
        end
    elseif entry.carrier_kind == "buffer" then
        if entry.extmark_bufnr and entry.extmark_id and vim.api.nvim_buf_is_valid(entry.extmark_bufnr) then
            local virt = {}
            for _, line in ipairs(lines) do
                virt[#virt + 1] = { { line, "AltImgPlaceholder" } }
            end
            local carrier_ns = vim.api.nvim_create_namespace(CARRIER_NS_NAME)
            local pos = vim.api.nvim_buf_get_extmark_by_id(entry.extmark_bufnr, carrier_ns, entry.extmark_id, {})
            if pos and pos[1] then
                pcall(vim.api.nvim_buf_set_extmark, entry.extmark_bufnr, carrier_ns, pos[1], pos[2] or 0, {
                    id = entry.extmark_id,
                    end_row = pos[1] + 1,
                    end_col = 0,
                    virt_lines = virt,
                    virt_lines_above = false,
                    invalidate = true,
                })
            end
        end
    end
    -- Buffer/extmark writes from a timer/schedule context don't auto-flush
    -- to the TTY; force a redraw so the spinner advances without input.
    pcall(vim.cmd, "redraw")
end

local function ensure_timer()
    if timer then
        return
    end
    local cfg = read_cfg()
    timer = vim.uv.new_timer()
    local interval = cfg.spinner_interval_ms or 120
    timer:start(
        interval,
        interval,
        vim.schedule_wrap(function()
            local any = false
            for _, entry in pairs(loading) do
                any = true
                if not entry.errored then
                    entry.spinner_index = entry.spinner_index + 1
                end
                render_one(entry)
            end
            if not any and timer then
                timer:stop()
                timer:close()
                timer = nil
            end
        end)
    )
end

---Start displaying the placeholder for `(provider, id)`.
---@param provider table
---@param id integer|any
---@param opts vim.ui.img.Opts
function M.show(provider, id, opts)
    local cfg = read_cfg()
    if cfg.enabled == false then
        return
    end
    local key = key_for(provider, id)
    if loading[key] then
        return -- already showing
    end
    local entry = {
        id = id,
        opts = opts,
        spinner_index = 1,
        errored = false,
    }
    if opts.relative == "editor" then
        local carrier = require("alt-img._core.carrier")
        local c = carrier.get(provider, id)
        if not c or not c.bufnr then
            return
        end
        entry.carrier_kind = "editor"
        entry.bufnr = c.bufnr
    elseif opts.relative == "buffer" then
        local carrier = require("alt-img._core.carrier")
        local c = carrier.get(provider, id)
        if not c or not c.extmark_id or not c.bufnr then
            return
        end
        entry.carrier_kind = "buffer"
        entry.extmark_id = c.extmark_id
        entry.extmark_bufnr = c.bufnr
    elseif opts.relative == "ui" then
        local carrier = require("alt-img._core.carrier")
        local bufnr = carrier.register_ui_placeholder(provider, id, opts)
        entry.carrier_kind = "ui"
        entry.bufnr = bufnr
    else
        return
    end
    loading[key] = entry
    ensure_timer()
    render_one(entry)
end

---Update the progress for an in-flight placeholder. Called from on_progress.
---@param provider table
---@param id integer|any
---@param progress any
function M.update(provider, id, progress)
    local entry = loading[key_for(provider, id)]
    if entry then
        entry.last_progress = progress
        -- next animation tick picks up the new percent; no immediate render
    end
end

---Mark the placeholder as errored — caption switches to "! error", spinner freezes.
---@param provider table
---@param id integer|any
function M.set_errored(provider, id)
    local entry = loading[key_for(provider, id)]
    if entry then
        entry.errored = true
        render_one(entry)
    end
end

---Stop displaying the placeholder for `(provider, id)`.
---@param provider table
---@param id integer|any
function M.hide(provider, id)
    local key = key_for(provider, id)
    local entry = loading[key]
    if not entry then
        return
    end
    if entry.carrier_kind == "ui" then
        require("alt-img._core.carrier").unregister_ui_placeholder(provider, id)
    elseif entry.carrier_kind == "editor" then
        if entry.bufnr and vim.api.nvim_buf_is_valid(entry.bufnr) then
            pcall(vim.api.nvim_buf_set_lines, entry.bufnr, 0, -1, false, {})
            pcall(vim.api.nvim_buf_clear_namespace, entry.bufnr, PLACEHOLDER_NS, 0, -1)
        end
    elseif entry.carrier_kind == "buffer" then
        if entry.extmark_bufnr and entry.extmark_id and vim.api.nvim_buf_is_valid(entry.extmark_bufnr) then
            local h = entry.opts.height or 1
            local virt = {}
            for _ = 1, h do
                virt[#virt + 1] = { { "", "Normal" } }
            end
            local carrier_ns = vim.api.nvim_create_namespace(CARRIER_NS_NAME)
            local pos = vim.api.nvim_buf_get_extmark_by_id(entry.extmark_bufnr, carrier_ns, entry.extmark_id, {})
            if pos and pos[1] then
                pcall(vim.api.nvim_buf_set_extmark, entry.extmark_bufnr, carrier_ns, pos[1], pos[2] or 0, {
                    id = entry.extmark_id,
                    end_row = pos[1] + 1,
                    end_col = 0,
                    virt_lines = virt,
                    virt_lines_above = false,
                    invalidate = true,
                })
            end
        end
    end
    loading[key] = nil
    -- timer stops on the next tick when it sees an empty `loading` table
end

---Reposition the carrier for a loading placement (called from render tick).
---For editor/buffer kinds, the carrier moved on its own — no-op. For ui,
---reposition the transient float.
---@param provider table
---@param id integer|any
---@param positions { row: integer, col: integer }[]
function M.reposition(provider, id, positions)
    local entry = loading[key_for(provider, id)]
    if not entry or entry.carrier_kind ~= "ui" then
        return
    end
    if not positions or not positions[1] then
        return
    end
    local pos = positions[1]
    require("alt-img._core.carrier").update_ui_placeholder(
        provider,
        id,
        vim.tbl_extend("force", entry.opts, { row = pos.row, col = pos.col })
    )
end

return M
