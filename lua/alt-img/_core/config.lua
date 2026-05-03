-- Single source of truth for alt-img's user-facing config.
--
-- Per nvim-best-practices (lumen-oss/nvim-best-practices), the plugin works
-- out of the box without a setup() function. Users override individual fields
-- via the global table:
--
--   vim.g.alt_img = {
--     magick                = { 'magick', 'convert' },   -- string | string[] | false
--     img2sixel             = 'img2sixel',               -- string | string[] | false
--     crop_cache_size       = 256,                       -- integer (LRU max per placement)
--     sixel_pixel_scale     = nil,                       -- integer override; nil = auto
--     precompute_crops      = true,                      -- background pre-encode on set()
--     precompute_interval_ms = 30,                       -- ms between precompute steps
--   }
--
-- `sixel_pixel_scale` exists because iTerm2 (and a few others, e.g.
-- WezTerm) report cell sizes in LOGICAL pixels via CSI 16t but render
-- sixel at PHYSICAL pixels — so a 32x64 sixel on a 2x display shows up
-- at 16x32 logical pixels, not the 4x4 cells the encoder asked for.
-- When unset (the default), the sixel encoder discovers the scale by
-- comparing CSI 14t (window pixels) ÷ CSI 18t (window characters)
-- against CSI 16t (cell pixels): if the implied per-cell size is
-- meaningfully larger than CSI 16t reports, the ratio is the scale.
-- Same approach chafa uses; works on every modern terminal. Setting
-- an integer here forces a specific multiplier and skips the auto-
-- detect.
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
---@field precompute_crops? boolean
---@field precompute_interval_ms? integer

local M = {}

---@type altimg.Config
local DEFAULTS = {
    magick = { "magick", "convert" },
    img2sixel = { "img2sixel" },
    -- LRU max for the per-placement cropped-encoding cache. Must be ≥
    -- 2*(image_height_cells - 1) for `precompute_crops` to be lossless;
    -- 256 is enough for images up to ~128 cells tall (typical embedded
    -- images are well under that).
    crop_cache_size = 256,
    -- Background pre-compute of cropped variants on placement creation.
    -- See _core/precompute.lua. Disable with `precompute_crops = false`
    -- if the foreground encode-on-demand cost is preferable to the
    -- background magick / img2sixel work.
    precompute_crops = true,
    precompute_interval_ms = 30,
    -- sixel_pixel_scale is intentionally absent so callers can detect
    -- "user did not set this" (nil) and fall back to auto-detect via
    -- util.terminal_pixel_scale(). An explicit integer in vim.g.alt_img
    -- wins.
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
