---@meta

---@class alt-img._core.provider.State
---@field data string raw PNG bytes
---@field opts vim.ui.img.Opts canonical opts
---@field id integer placement id
---@field codec_state any opaque per-placement table the codec mutates for its own caches

---@class alt-img._core.provider.SrcRect
---@field x integer left edge of the crop (cells)
---@field y integer top edge of the crop (cells)
---@field w integer crop width (cells)
---@field h integer crop height (cells)

---@class alt-img._core.provider.Codec
---@field probe fun(opts?: { timeout?: integer }): boolean, string? terminal capability probe
---@field encode_full fun(state: alt-img._core.provider.State): string? sync full-image wire bytes
---@field encode_crop fun(state: alt-img._core.provider.State, src: alt-img._core.provider.SrcRect): string? sync crop wire bytes
---@field encode_full_async fun(state: alt-img._core.provider.State, on_done: fun(bytes: string?)) async cache warmer for the full image
---@field encode_crop_async fun(state: alt-img._core.provider.State, src: alt-img._core.provider.SrcRect, on_done: fun(bytes: string?)) async cache warmer for a crop
---@field invalidate fun(state: alt-img._core.provider.State) reset codec-owned caches when dims change
