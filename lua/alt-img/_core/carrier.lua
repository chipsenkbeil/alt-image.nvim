---Reserves screen real estate via floating windows / extmarks for placements
---with relative != 'ui'. Owns the float/extmark lifecycle and exposes the
---current screen positions via M.get_positions. The render coordinator
---(_render) owns redraw scheduling and dirty-flag autocmds; the carrier just
---keeps its windows/marks consistent and evicts dangling floats on WinClosed.
---
---Provider contract: providers register with _core/render at set() time
---by passing a callbacks table { emit_at, build_at?, get_opts? }. The
---carrier never calls providers directly — render holds the refs and
---invokes them.
---
---Position contract: positions are returned as a *list* of records of the
---shape `{ row, col, src = { x, y, w, h } }`. The list is empty (not nil)
---when nothing is currently visible. `src` describes the rect of the source
---image (in image cells) that should be rendered at (row, col). For images
---fully visible within window/terminal bounds, src covers the entire image
---and providers use the cached full encoding. For partially-visible images,
---the carrier tightens src to the visible sub-rect and providers crop +
---re-encode before emitting.
local M = {}

---@type integer
local NS = vim.api.nvim_create_namespace("alt-img._core.carrier")

---@type integer
local AUGROUP = vim.api.nvim_create_augroup("alt-img._core.carrier", { clear = true })

---@class alt-img._core.Carrier
---@field id integer
---@field provider table
---@field opts table
---@field kind 'editor'|'buffer'
---@field winid integer
---@field extmark_id integer
---@field bufnr integer
---@field last_positions {row:integer, col:integer, src:{x:integer, y:integer, w:integer, h:integer}}[]
---@type table<string, alt-img._core.Carrier>
local carriers = {}

---@param provider table
---@param id integer|any
---@return string
local function provider_key(provider, id)
    return tostring(provider) .. ":" .. tostring(id)
end

---@param opts table
---@return integer w
---@return integer h
local function size_in_cells(opts)
    local pad = opts.pad or 0
    local w = (opts.width or 1) + pad
    local h = opts.height or 1
    return w, h
end

---@param opts table
---@return integer winid
---@return integer bufnr
local function open_editor_carrier(opts)
    local buf = vim.api.nvim_create_buf(false, true)
    local w, h = size_in_cells(opts)
    local winid = vim.api.nvim_open_win(buf, false, {
        relative = "editor",
        row = (opts.row or 1) - 1,
        col = (opts.col or 1) - 1,
        width = w,
        height = h,
        focusable = false,
        style = "minimal",
        zindex = opts.zindex or 50,
    })
    return winid, buf
end

---@param opts table
---@return integer extmark_id
local function place_buffer_extmark(opts)
    local _, h = size_in_cells(opts)
    local virt = {}
    for _ = 1, h do
        virt[#virt + 1] = { { "", "Normal" } }
    end
    local row = (opts.row or 1) - 1
    return vim.api.nvim_buf_set_extmark(opts.buf, NS, row, (opts.col or 1) - 1, {
        end_row = row + 1,
        end_col = 0,
        virt_lines = virt,
        virt_lines_above = false,
        invalidate = true,
        -- undo_restore left at default (true) so 'u' after 'dd' brings the
        -- image back: dd hides the mark (invalid=true), undo restores it.
        -- get_positions checks details.invalid to treat hidden marks as off-screen.
    })
end

---@param c alt-img._core.Carrier
---@return alt-img._core.render.Position[]
local function resolve_screen_positions(c)
    -- If editor type, we grab the floating window to determine the position
    if c.kind == "editor" then
        if not vim.api.nvim_win_is_valid(c.winid) then
            return {}
        end

        local util = require("alt-img._core.util")
        local pos = vim.api.nvim_win_get_position(c.winid)
        local pad = (c.opts and c.opts.pad) or 0
        local anchor_row = pos[1] + 1
        local anchor_col = pos[2] + 1 + pad
        local w = c.opts.width or 1
        local h = c.opts.height or 1
        local p = util.clip_to_bounds(anchor_row, anchor_col, w, h, 1, 1, vim.o.lines, vim.o.columns)
        return p and { p } or {}
    end

    -- Otherwise, we're a buffer type, and that means iterating ALL windows showing this buffer
    -- Use screenpos(win, line, col) for each. One entry per visible window,clipped to that window's inner bounds.
    if not vim.api.nvim_buf_is_valid(c.bufnr) then
        return {}
    end

    local mark = vim.api.nvim_buf_get_extmark_by_id(c.bufnr, NS, c.extmark_id, { details = true })
    if not mark or not mark[1] then
        return {}
    end

    local details = mark[3]
    if details and details.invalid then
        return {}
    end

    local anchor_line = mark[1] + 1
    local line_count = vim.api.nvim_buf_line_count(c.bufnr)
    if anchor_line < 1 or anchor_line > line_count then
        return {}
    end

    local col = (mark[2] or 0) + 1
    local pad = (c.opts and c.opts.pad) or 0
    local img_w = c.opts.width or 1
    local img_h = c.opts.height or 1
    local out = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == c.bufnr then
            -- Window inner bounds (1-indexed terminal cells).
            local wpos = vim.api.nvim_win_get_position(win)
            local win_top = wpos[1] + 1
            local win_left = wpos[2] + 1
            local win_bottom = win_top + vim.api.nvim_win_get_height(win) - 1
            local win_right = win_left + vim.api.nvim_win_get_width(win) - 1

            -- Read scroll state to detect partial-top-visibility via topfill: when
            -- the anchor line has scrolled just above the window, its virt_lines
            -- can still be partially rendered as `topfill` filler rows at the top
            -- of the window. screenpos() reports row=0 for the off-screen anchor,
            -- so we have to compute the visible sub-rect from topfill ourselves.
            local view_ok, view = pcall(vim.api.nvim_win_call, win, vim.fn.winsaveview)
            local topline = (view_ok and view and view.topline) or 1
            local topfill = (view_ok and view and view.topfill) or 0

            local image_anchor_row, image_anchor_col, src_y_offset, src_h_max
            if anchor_line >= topline then
                -- Anchor is at or below topline: should be visible (resolve via
                -- screenpos, which respects wraps, folds, signcolumn, etc.).
                local sp_ok, sp = pcall(vim.fn.screenpos, win, anchor_line, col)

                if sp_ok and sp and sp.row > 0 then
                    image_anchor_row = sp.row + 1 -- first virt_line below anchor
                    image_anchor_col = sp.col + pad
                    src_y_offset = 0
                    src_h_max = img_h
                end
            elseif anchor_line == topline - 1 and topfill > 0 then
                -- Anchor is just above topline; its virt_lines are partially visible
                -- as `topfill` filler rows at the top of the window. The bottom
                -- `min(topfill, img_h)` rows of the image render at win_top onward.
                -- Approximation/caveat: if other extmarks above topline ALSO
                -- contribute to topfill, this over-attributes rows to our image.
                -- For alt-img's typical one-image-per-buffer use it's fine.
                local visible = math.min(topfill, img_h)
                local skipped = img_h - visible
                image_anchor_row = win_top

                -- Probe screenpos for a known-visible line at our column to pick up
                -- signcolumn/number offsets. topline is always visible.
                local probe_ok, probe = pcall(vim.fn.screenpos, win, topline, col)
                local probe_col = (probe_ok and probe and probe.col and probe.col > 0) and probe.col or win_left
                image_anchor_col = probe_col + pad
                src_y_offset = skipped
                src_h_max = visible
            end

            if image_anchor_row then
                local util = require("alt-img._core.util")
                local p = util.clip_to_bounds(
                    image_anchor_row,
                    image_anchor_col,
                    img_w,
                    src_h_max,
                    win_top,
                    win_left,
                    win_bottom,
                    win_right
                )

                if p then
                    -- clip_to_bounds operates on the (possibly already top-skipped)
                    -- sub-image of height src_h_max; combine its returned src.y with
                    -- the topfill-induced skip so the provider crops at the correct
                    -- offset within the *original* image.
                    p.src.y = p.src.y + src_y_offset
                    out[#out + 1] = p
                end
            end
        end
    end

    return out
end

---@param provider table
---@param id integer|any
---@param opts table
---@return alt-img._core.render.Position[]
function M.register(provider, id, opts)
    local c = { provider = provider, id = id, opts = opts }
    if opts.relative == "editor" then
        c.kind = "editor"
        c.winid, c.bufnr = open_editor_carrier(opts)
    elseif opts.relative == "buffer" then
        if not opts.buf then
            error("alt-img: relative=buffer requires opts.buf", 3)
        end
        c.kind = "buffer"
        c.bufnr = opts.buf
        c.extmark_id = place_buffer_extmark(opts)
    else
        error("alt-img: unsupported relative " .. tostring(opts.relative), 3)
    end
    c.last_positions = resolve_screen_positions(c)
    carriers[provider_key(provider, id)] = c
    return c.last_positions
end

---@param provider table
---@param id integer|any
---@param opts table
---@return alt-img._core.render.Position[]
function M.update(provider, id, opts)
    local key = provider_key(provider, id)
    local c = carriers[key]
    if not c then
        return {}
    end

    -- If relative mode changed (e.g. editor → buffer), tear down the old
    -- carrier kind and re-register with the new one rather than trying to
    -- update in place. This keeps each carrier kind's internal state
    -- (winid vs extmark_id) consistent.
    local new_kind = opts.relative == "editor" and "editor" or "buffer"
    if new_kind ~= c.kind then
        M.unregister(provider, id)
        M.register(provider, id, opts)
        return carriers[key] and carriers[key].last_positions or {}
    end

    c.opts = opts
    if c.kind == "editor" then
        if c.winid and vim.api.nvim_win_is_valid(c.winid) then
            local w, h = size_in_cells(opts)
            vim.api.nvim_win_set_config(c.winid, {
                relative = "editor",
                row = (opts.row or 1) - 1,
                col = (opts.col or 1) - 1,
                width = w,
                height = h,
                focusable = false,
                style = "minimal",
                zindex = opts.zindex or 50,
            })
        end
    elseif c.kind == "buffer" then
        -- TODO: Can we just use vim.api.nvim_buf_set_extmark to update it
        --       instead of deleting and recreating?
        if c.extmark_id then
            pcall(vim.api.nvim_buf_del_extmark, c.bufnr, NS, c.extmark_id)
        end
        if opts.buf then
            c.bufnr = opts.buf
        end
        c.extmark_id = place_buffer_extmark(opts)
    end

    c.last_positions = resolve_screen_positions(c)
    return c.last_positions
end

---@param provider table
---@param id integer|any
function M.unregister(provider, id)
    local key = provider_key(provider, id)
    local c = carriers[key]
    if not c then
        return
    end
    if c.kind == "editor" and c.winid and vim.api.nvim_win_is_valid(c.winid) then
        pcall(vim.api.nvim_win_close, c.winid, true)
    elseif c.kind == "buffer" and c.extmark_id then
        pcall(vim.api.nvim_buf_del_extmark, c.bufnr, NS, c.extmark_id)
    end
    carriers[key] = nil
end

---@param provider table
---@param id integer|any
---@return alt-img._core.render.Position[]
function M.get_positions(provider, id)
    local c = carriers[provider_key(provider, id)]
    if not c then
        return {}
    end
    return resolve_screen_positions(c)
end

vim.api.nvim_create_autocmd({ "WinClosed" }, {
    group = AUGROUP,
    callback = function(args)
        local closed = tonumber(args.match)
        for k, c in pairs(carriers) do
            if c.winid == closed then
                carriers[k] = nil
            end
        end
    end,
})

return M
