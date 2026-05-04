---@class alt-img._core.Config
---@field autodetect? string[]  provider names autodetect probes, in order; first supported wins
---@field magick? string|string[]|false  magick CLI candidate(s); false disables
---@field img2sixel? string|string[]|false  img2sixel CLI candidate(s); false disables
---@field sixel_pixel_scale? integer  explicit override for sixel logical/physical scale (nil = auto)
---@field precompute_crops? boolean  background pre-encode on set()
---@field precompute_interval_ms? integer  ms between precompute steps
---@field precompute_start_delay_ms? integer  ms before first step fires
---@field precompute_idle_threshold_ms? integer  skip step if user active within this window
---@field precompute_notify? boolean  vim.notify on precompute start/finish

local M = {}

-- `sixel_pixel_scale` is intentionally absent so nil means "auto-detect
-- via pixel_scale.current()"; any integer wins over auto.
---@type alt-img._core.Config
local DEFAULTS = {
    autodetect = { "iterm2", "sixel" },
    magick = { "magick", "convert" },
    img2sixel = { "img2sixel" },
    precompute_crops = true,
    precompute_interval_ms = 30,
    precompute_start_delay_ms = 500,
    precompute_idle_threshold_ms = 500,
    precompute_notify = false,
}

---Return the merged config (defaults overlaid with vim.g.alt_img).
---@return alt-img._core.Config
function M.read()
    return vim.tbl_extend("force", DEFAULTS, vim.g.alt_img or {})
end

return M
