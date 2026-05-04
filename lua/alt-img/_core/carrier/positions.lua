local M = {}

---@class alt-img._core.carrier.Carrier
---@field id integer
---@field provider table
---@field opts table
---@field kind 'editor'|'buffer'
---@field winid integer
---@field extmark_id integer
---@field bufnr integer

---@param c alt-img._core.carrier.Carrier
---@return alt-img._core.render.Position[]
function M.resolve_editor(c)
    if not vim.api.nvim_win_is_valid(c.winid) then
        return {}
    end
    local pos = vim.api.nvim_win_get_position(c.winid)
    local pad = (c.opts and c.opts.pad) or 0
    local anchor_row = pos[1] + 1
    local anchor_col = pos[2] + 1 + pad
    local w = c.opts.width or 1
    local h = c.opts.height or 1
    local p = require("alt-img._core.clip").to_bounds(anchor_row, anchor_col, w, h, 1, 1, vim.o.lines, vim.o.columns)
    return p and { p } or {}
end

---Resolve where this anchor renders inside `win`. Returns nil if the
---anchor is fully off-screen for that window. The `topfill` branch handles
---partial top-visibility: when the anchor line scrolled just above topline,
---its virt_lines render as filler rows at the top of the window;
---screenpos() reports row=0 for the off-screen anchor, so we have to
---compute the visible sub-rect from topfill ourselves.
---@param win integer window id
---@param anchor_line integer 1-indexed buffer line of the extmark
---@param col integer 1-indexed column
---@param topline integer
---@param topfill integer
---@param img_h integer image height in cells
---@param pad integer
---@param win_top integer window top row (1-indexed)
---@param win_left integer window left col (1-indexed)
---@return integer? image_anchor_row
---@return integer? image_anchor_col
---@return integer? src_y_offset
---@return integer? src_h_max
local function compute_buffer_anchor(win, anchor_line, col, topline, topfill, img_h, pad, win_top, win_left)
    if anchor_line >= topline then
        local sp_ok, sp = pcall(vim.fn.screenpos, win, anchor_line, col)
        if sp_ok and sp and sp.row > 0 then
            -- first virt_line below anchor
            return sp.row + 1, sp.col + pad, 0, img_h
        end
        return nil
    end
    if anchor_line == topline - 1 and topfill > 0 then
        -- Approximation: if other extmarks above topline ALSO contribute to
        -- topfill, this over-attributes rows to our image. For alt-img's
        -- typical one-image-per-buffer use it's fine.
        local visible = math.min(topfill, img_h)
        local skipped = img_h - visible
        local probe_ok, probe = pcall(vim.fn.screenpos, win, topline, col)
        local probe_col = (probe_ok and probe and probe.col and probe.col > 0) and probe.col or win_left
        return win_top, probe_col + pad, skipped, visible
    end
    return nil
end

---@param c alt-img._core.carrier.Carrier
---@param ns integer namespace owning the extmark
---@return alt-img._core.render.Position[]
function M.resolve_buffer(c, ns)
    if not vim.api.nvim_buf_is_valid(c.bufnr) then
        return {}
    end
    local mark = vim.api.nvim_buf_get_extmark_by_id(c.bufnr, ns, c.extmark_id, { details = true })
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
    local clip = require("alt-img._core.clip")

    local out = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == c.bufnr then
            local wpos = vim.api.nvim_win_get_position(win)
            local win_top = wpos[1] + 1
            local win_left = wpos[2] + 1
            local win_bottom = win_top + vim.api.nvim_win_get_height(win) - 1
            local win_right = win_left + vim.api.nvim_win_get_width(win) - 1

            local view_ok, view = pcall(vim.api.nvim_win_call, win, vim.fn.winsaveview)
            local topline = (view_ok and view and view.topline) or 1
            local topfill = (view_ok and view and view.topfill) or 0

            local image_anchor_row, image_anchor_col, src_y_offset, src_h_max =
                compute_buffer_anchor(win, anchor_line, col, topline, topfill, img_h, pad, win_top, win_left)

            if image_anchor_row then
                local p = clip.to_bounds(
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
                    -- clip operates on the (possibly already top-skipped) sub-image
                    -- of height src_h_max; combine its returned src.y with the
                    -- topfill-induced skip so the provider crops at the correct
                    -- offset within the *original* image.
                    p.src.y = p.src.y + src_y_offset
                    out[#out + 1] = p
                end
            end
        end
    end
    return out
end

return M
