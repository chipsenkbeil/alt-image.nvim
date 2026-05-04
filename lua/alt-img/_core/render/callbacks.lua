---@meta

---@class alt-img._core.render.Callbacks
---@field emit_at fun(id: integer, pos: alt-img._core.render.Position)
---@field build_at? fun(id: integer, pos: alt-img._core.render.Position): string?
---@field get_opts? fun(id: integer): table?
