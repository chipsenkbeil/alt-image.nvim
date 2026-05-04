---@meta

---@class alt-img._core.render.Position
---@field row integer 1-indexed terminal row
---@field col integer 1-indexed terminal column
---@field src? { x: integer, y: integer, w: integer, h: integer } visible sub-rect of the source image (cells)

---@class alt-img._core.render.Callbacks
---@field emit_at fun(id: integer, pos: alt-img._core.render.Position) write the placement at `pos` to the terminal
---@field build_at? fun(id: integer, pos: alt-img._core.render.Position): string? build the wire bytes without sending (lets sync/async paths share a build)
---@field get_opts? fun(id: integer): table? returns the placement's opts table (used for zindex)

---@class alt-img._core.render.Placement
---@field token any opaque identity (any unique value)
---@field id integer placement id
---@field get_pos fun(): alt-img._core.render.Position[] resolves current screen positions
---@field callbacks alt-img._core.render.Callbacks
---@field redraw boolean dirty flag set by autocmds
---@field force_redraw? boolean force re-emit even if positions unchanged
---@field last_positions? alt-img._core.render.Position[] positions seen on the most recent emit
---@field next_positions? alt-img._core.render.Position[] positions resolved during the current tick
