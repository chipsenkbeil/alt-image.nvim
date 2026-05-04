local M = {}

---Clip an image footprint at (anchor_row, anchor_col) of size (w, h) cells
---against rectangular bounds. Returns nil if entirely outside; otherwise a
---position record `{ row, col, src = { x, y, w, h } }`. All inputs in
---1-indexed terminal cells.
---@param anchor_row integer
---@param anchor_col integer
---@param w integer
---@param h integer
---@param b_top integer
---@param b_left integer
---@param b_bottom integer
---@param b_right integer
---@return {row:integer, col:integer, src:{x:integer,y:integer,w:integer,h:integer}}|nil
function M.to_bounds(anchor_row, anchor_col, w, h, b_top, b_left, b_bottom, b_right)
    local image_top = anchor_row
    local image_bottom = anchor_row + h - 1
    local image_left = anchor_col
    local image_right = anchor_col + w - 1
    local v_top = math.max(image_top, b_top)
    local v_bottom = math.min(image_bottom, b_bottom)
    local v_left = math.max(image_left, b_left)
    local v_right = math.min(image_right, b_right)
    if v_top > v_bottom or v_left > v_right then
        return nil
    end
    return {
        row = v_top,
        col = v_left,
        src = {
            x = v_left - image_left,
            y = v_top - image_top,
            w = v_right - v_left + 1,
            h = v_bottom - v_top + 1,
        },
    }
end

return M
