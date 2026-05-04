---@type table<string, boolean>
local KNOWN_SIXEL_TERMS = {
    foot = true,
    mlterm = true,
    contour = true,
}
---@type table<string, boolean>
local SUPPORTING_TERM_PROGRAMS = {
    ["iTerm.app"] = true,
    ["WezTerm"] = true,
}

---@class alt-img.sixel.CodecState
---@field resized_rgba string? RGBA pixel buffer after nearest-neighbor resize
---@field resized_w integer? pixel width of resized buffer
---@field resized_h integer? pixel height of resized buffer
---@field full_sixel string? cached full-image sixel DCS
---@field crop_cache table<string, string>? LRU map of crop key → sixel DCS
---@field crop_cache_order string[]? LRU insertion-order keys for crop_cache

---@param cs alt-img.sixel.CodecState
local function ensure_caches(cs)
    cs.crop_cache = cs.crop_cache or {}
    cs.crop_cache_order = cs.crop_cache_order or {}
end

---Active sixel pixel scale (clamped to >= 1). Reads config fresh so runtime
---changes take effect.
---@return integer
local function sixel_scale()
    local cfg = require("alt-img._core.config").read() or {}
    if type(cfg.sixel_pixel_scale) == "number" then
        return math.max(1, math.floor(cfg.sixel_pixel_scale))
    end
    return require("alt-img._core.pixel_scale").current()
end

---@param s alt-img._core.provider.State
---@return string rgba, integer w, integer h
local function ensure_resized(s)
    local cs = s.codec_state
    if cs.resized_rgba then
        return cs.resized_rgba, cs.resized_w, cs.resized_h
    end
    local png = require("alt-img._core.png")
    local img = png.decode(s.data)
    local rgba, w, h = img.pixels, img.width, img.height
    local cw, ch = require("alt-img._core.cell_size").current()
    if s.opts.width or s.opts.height then
        local target_w = (s.opts.width or math.ceil(w / cw)) * cw
        local target_h = (s.opts.height or math.ceil(h / ch)) * ch
        rgba, w, h = require("alt-img._core.image").resize(rgba, w, h, target_w, target_h)
    end
    cs.resized_rgba, cs.resized_w, cs.resized_h = rgba, w, h
    return rgba, w, h
end

---@param s alt-img._core.provider.State
---@return string sixel
local function build_sixel(s)
    local cs = s.codec_state
    if cs.full_sixel then
        return cs.full_sixel
    end
    local scale = sixel_scale()
    local rgba, w, h = ensure_resized(s)
    if scale > 1 then
        rgba, w, h = require("alt-img._core.image").resize(rgba, w, h, w * scale, h * scale)
    end
    cs.full_sixel = require("alt-img.sixel._encode").encode_sixel_dispatch(rgba, w, h)
    return cs.full_sixel
end

---@param s alt-img._core.provider.State
---@param src alt-img._core.provider.SrcRect
---@return string sixel
local function build_sixel_cropped(s, src)
    local cell_size = require("alt-img._core.cell_size")
    cell_size.query()
    local cw, ch = cell_size.current()
    local scale = sixel_scale()
    local x_px, y_px = src.x * cw * scale, src.y * ch * scale
    local w_px, h_px = src.w * cw * scale, src.h * ch * scale

    local rgba, w, h = ensure_resized(s)
    if scale > 1 then
        rgba, w, h = require("alt-img._core.image").resize(rgba, w, h, w * scale, h * scale)
    end
    local cropped, cw_px, ch_px = require("alt-img._core.image").crop_rgba(rgba, w, h, x_px, y_px, w_px, h_px)
    return require("alt-img.sixel._encode").encode_sixel_dispatch(cropped, cw_px, ch_px)
end

local codec = {}

---@param s alt-img._core.provider.State
function codec.invalidate(s)
    s.codec_state = {}
end

---@param s alt-img._core.provider.State
---@return string
function codec.encode_full(s)
    return build_sixel(s)
end

---@param s alt-img._core.provider.State
---@param src alt-img._core.provider.SrcRect
---@return string
function codec.encode_crop(s, src)
    local cs = s.codec_state
    ensure_caches(cs)
    local key = string.format("%d,%d,%d,%d", src.x, src.y, src.w, src.h)
    local lru = require("alt-img._core.lru")
    local cached = lru.get(cs.crop_cache, cs.crop_cache_order, key)
    if not cached then
        cached = build_sixel_cropped(s, src)
        lru.put(
            cs.crop_cache,
            cs.crop_cache_order,
            key,
            cached,
            require("alt-img._core.precompute").required_lru_size(s.opts)
        )
    end
    return cached
end

---Pre-resize the placement's RGBA to its cell-pixel grid (scale-aware) and
---return PNG bytes ready for chafa/img2sixel/magick. nil on encode failure.
---@param s alt-img._core.provider.State
---@return string? png_bytes
local function build_full_png(s)
    local rgba, w, h = ensure_resized(s)
    local scale = sixel_scale()
    if scale > 1 then
        rgba, w, h = require("alt-img._core.image").resize(rgba, w, h, w * scale, h * scale)
    end
    return require("alt-img._core.png").encode(rgba, w, h)
end

---@param s alt-img._core.provider.State
---@param on_done fun(bytes: string?)
function codec.encode_full_async(s, on_done)
    local cs = s.codec_state
    if cs.full_sixel then
        return on_done(cs.full_sixel)
    end
    if not (s.opts.width and s.opts.height) then
        return on_done(nil)
    end
    local chafa = require("alt-img.sixel._chafa")
    local libsixel = require("alt-img.sixel._libsixel")
    local magick = require("alt-img._core.magick")

    local function deliver(out)
        if out and #out > 0 then
            cs.full_sixel = out
            return on_done(out)
        end
        on_done(nil)
    end

    -- Priority: chafa → img2sixel → magick. First-available wins; on
    -- subprocess failure on_done(nil) lets the provider's sync fallback
    -- (build_at) try the next tool via encode_sixel_dispatch.
    if chafa.binary() then
        local png_bytes = build_full_png(s)
        if not png_bytes then
            return on_done(nil)
        end
        return chafa.encode_sixel_async(png_bytes, deliver)
    end
    if libsixel.binary() then
        local png_bytes = build_full_png(s)
        if not png_bytes then
            return on_done(nil)
        end
        return libsixel.encode_sixel_async(png_bytes, deliver)
    end
    if magick.binary() then
        local cell_size = require("alt-img._core.cell_size")
        cell_size.query()
        local cw, ch = cell_size.current()
        local scale = sixel_scale()
        return magick.encode_sixel_from_png_resized_async(
            s.data,
            s.opts.width * cw * scale,
            s.opts.height * ch * scale,
            deliver
        )
    end
    on_done(nil)
end

---@param s alt-img._core.provider.State
---@param src alt-img._core.provider.SrcRect
---@param on_done fun(bytes: string?)
---Pre-resize and crop the placement's RGBA, then PNG-encode the cropped
---rectangle ready for chafa/img2sixel. nil on encode failure.
---@param s alt-img._core.provider.State
---@param src alt-img._core.provider.SrcRect
---@return string? png_bytes
local function build_crop_png(s, src)
    local cell_size = require("alt-img._core.cell_size")
    cell_size.query()
    local cw, ch = cell_size.current()
    local scale = sixel_scale()
    local x_px, y_px = src.x * cw * scale, src.y * ch * scale
    local w_px, h_px = src.w * cw * scale, src.h * ch * scale
    local rgba, w, h = ensure_resized(s)
    if scale > 1 then
        rgba, w, h = require("alt-img._core.image").resize(rgba, w, h, w * scale, h * scale)
    end
    local cropped, cw_px, ch_px =
        require("alt-img._core.image").crop_rgba(rgba, w, h, x_px, y_px, w_px, h_px)
    return require("alt-img._core.png").encode(cropped, cw_px, ch_px)
end

function codec.encode_crop_async(s, src, on_done)
    local cs = s.codec_state
    ensure_caches(cs)
    local key = string.format("%d,%d,%d,%d", src.x, src.y, src.w, src.h)
    if cs.crop_cache[key] then
        return on_done(cs.crop_cache[key])
    end

    local chafa = require("alt-img.sixel._chafa")
    local libsixel = require("alt-img.sixel._libsixel")
    local magick = require("alt-img._core.magick")

    local function deliver(out)
        if out and #out > 0 then
            local lru = require("alt-img._core.lru")
            lru.put(
                cs.crop_cache,
                cs.crop_cache_order,
                key,
                out,
                require("alt-img._core.precompute").required_lru_size(s.opts)
            )
            return on_done(out)
        end
        on_done(nil)
    end

    -- Priority: chafa → img2sixel → magick. Same fallback semantics as
    -- encode_full_async: on_done(nil) routes the provider to sync build_at,
    -- which uses encode_sixel_dispatch (which chains the same tools plus
    -- the pure-Lua tail).
    if chafa.binary() then
        local png_bytes = build_crop_png(s, src)
        if not png_bytes then
            return on_done(nil)
        end
        return chafa.encode_sixel_async(png_bytes, deliver)
    end
    if libsixel.binary() then
        local png_bytes = build_crop_png(s, src)
        if not png_bytes then
            return on_done(nil)
        end
        return libsixel.encode_sixel_async(png_bytes, deliver)
    end
    if magick.binary() then
        local cell_size = require("alt-img._core.cell_size")
        cell_size.query()
        local cw, ch = cell_size.current()
        local scale = sixel_scale()
        local x_px, y_px = src.x * cw * scale, src.y * ch * scale
        local w_px, h_px = src.w * cw * scale, src.h * ch * scale
        local full_w = s.opts.width * cw * scale
        local full_h = s.opts.height * ch * scale
        return magick.crop_resized_to_sixel_async(s.data, full_w, full_h, x_px, y_px, w_px, h_px, deliver)
    end
    on_done(nil)
end

---@param opts? { timeout?: integer }
---@return boolean, string?
function codec.probe(opts)
    opts = opts or {}
    if vim.env.TERM_PROGRAM == "Apple_Terminal" then
        return false, "Apple Terminal does not support sixel"
    end
    if vim.env.WT_SESSION then
        return true
    end
    local tp = vim.env.TERM_PROGRAM
    if tp and SUPPORTING_TERM_PROGRAMS[tp] then
        return true
    end
    local term = vim.env.TERM or ""
    if term:find("sixel", 1, true) or KNOWN_SIXEL_TERMS[term] then
        return true
    end
    local timeout = opts.timeout or 1000
    local done, ok, msg = false, false, nil
    require("alt-img._core.tty").query("\027[c", { timeout = timeout }, function(resp)
        if resp and resp:find(";4", 1, true) then
            ok = true
        elseif resp then
            msg = "DA1 response did not indicate sixel support: " .. resp
        end
        done = true
    end)
    vim.wait(timeout + 100, function()
        return done
    end)
    return ok, msg
end

return require("alt-img._core.provider").new(codec)
