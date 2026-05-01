-- Single source of truth for alt-img's user-facing config.
--
-- Per nvim-best-practices (lumen-oss/nvim-best-practices), the plugin works
-- out of the box without a setup() function. Users override individual fields
-- via the global table:
--
--   vim.g.alt_img = {
--     magick    = { 'magick', 'convert' },   -- string | string[] | false
--     img2sixel = 'img2sixel',               -- string | string[] | false
--   }
--
-- All fields are optional; missing fields fall back to the defaults below.
-- Read happens at call-time (not require-time) so user config can be set
-- before *or* after the plugin is loaded and still take effect.
--
-- Note: shallow merge via vim.tbl_extend, not deep merge. A deep merge would
-- index-extend arrays (e.g. user's `magick = { 'gm' }` over default
-- `{ 'magick', 'convert' }` would produce `{ 'gm', 'convert' }` instead of
-- replacing the list outright). All our config fields are scalars or arrays
-- with no nested tables, so shallow merge is correct here.

---@class altimg.Config
---@field magick? string|string[]|false
---@field img2sixel? string|string[]|false

local M = {}

---@type altimg.Config
local DEFAULTS = {
    magick = { "magick", "convert" },
    img2sixel = { "img2sixel" },
}

---Return the merged config (defaults overlaid with vim.g.alt_img).
---@return altimg.Config
function M.read()
    return vim.tbl_extend("force", DEFAULTS, vim.g.alt_img or {})
end

---Expose defaults read-only for tests / introspection.
---@return altimg.Config
function M.defaults()
    return vim.deepcopy(DEFAULTS)
end

return M
