---@class alt-img._core.Config
---@field magick? string|string[]|false  magick CLI candidate(s); false disables
---@field img2sixel? string|string[]|false  img2sixel CLI candidate(s); false disables
---@field crop_cache_size? integer  per-placement LRU max for cached crop encodings
---@field sixel_pixel_scale? integer  explicit override for sixel logical/physical scale (nil = auto)
---@field precompute_crops? boolean  background pre-encode on set()
---@field precompute_interval_ms? integer  ms between precompute steps
---@field precompute_start_delay_ms? integer  ms before first step fires
---@field precompute_idle_threshold_ms? integer  skip step if user active within this window
---@field precompute_max_concurrent? integer  max parallel async magick subprocesses
---@field precompute_notify? boolean  vim.notify on precompute start/finish

local M = {}

-- LRU sizing rule: `crop_cache_size` must be ≥ 2*(image_height_cells - 1)
-- for `precompute_crops` to be lossless; 256 fits images up to ~128 cells
-- tall. `sixel_pixel_scale` is intentionally absent so nil means
-- "auto-detect via pixel_scale.current()"; any integer wins over auto.
---@type alt-img._core.Config
local DEFAULTS = {
    magick = { "magick", "convert" },
    img2sixel = { "img2sixel" },
    crop_cache_size = 256,
    precompute_crops = true,
    precompute_interval_ms = 30,
    precompute_start_delay_ms = 500,
    precompute_idle_threshold_ms = 500,
    precompute_max_concurrent = 2,
    precompute_notify = false,
}

---Return the merged config (defaults overlaid with vim.g.alt_img).
---@return alt-img._core.Config
function M.read()
    return vim.tbl_extend("force", DEFAULTS, vim.g.alt_img or {})
end

return M
