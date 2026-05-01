-- Single source of truth for alt-img's user-facing config.
--
-- Per nvim-best-practices (lumen-oss/nvim-best-practices), the plugin works
-- out of the box without a setup() function. Users override individual fields
-- via the global table:
--
--   vim.g.alt_img = {
--     magick             = { 'magick', 'convert' },   -- string | string[] | false
--     img2sixel          = 'img2sixel',               -- string | string[] | false
--     crop_cache_size    = 64,                        -- integer (LRU max per placement)
--     sixel_pixel_scale  = 1,                         -- integer (multiply sixel encode dims)
--   }
--
-- `sixel_pixel_scale` exists because iTerm2's sixel renderer treats sixel
-- pixels as PHYSICAL (retina) pixels — so a 32x64 sixel on a 2x display
-- shows up at 16x32 logical pixels, not the 4x4 cells the encoder asked
-- for. Setting this to 2 on retina iTerm2 doubles the encoded sixel
-- dimensions so the rendered output fills the requested cell area.
-- Other sixel terminals (foot, mlterm, contour, WT, WezTerm) render at
-- 1 sixel-pixel = 1 logical-pixel and keep this at the default 1.
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
---@field crop_cache_size? integer
---@field sixel_pixel_scale? integer

local M = {}

---@type altimg.Config
local DEFAULTS = {
    magick = { "magick", "convert" },
    img2sixel = { "img2sixel" },
    crop_cache_size = 64,
    sixel_pixel_scale = 1,
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
