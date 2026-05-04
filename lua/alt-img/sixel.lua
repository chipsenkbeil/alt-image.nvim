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
    local sixel_cfg = cfg.sixel or {}
    if type(sixel_cfg.pixel_scale) == "number" then
        return math.max(1, math.floor(sixel_cfg.pixel_scale))
    end
    return require("alt-img._core.pixel_scale").current()
end

---Cache key for the placement's full sixel output. Returns nil if dims
---aren't known yet (e.g. opts.width missing) — the disk cache is keyed by
---pixel target, not opts, so missing dims means we can't form a stable key.
---@param s alt-img._core.provider.State
---@return string? key, integer? target_w_px, integer? target_h_px
local function sixel_cache_key_full(s)
    if not (s.opts.width and s.opts.height) then
        return nil
    end
    local cell_size = require("alt-img._core.cell_size")
    cell_size.query()
    local cw, ch = cell_size.current()
    local scale = sixel_scale()
    local tw, th = s.opts.width * cw * scale, s.opts.height * ch * scale
    local cache = require("alt-img._core.cache")
    return cache.key(cache.input_sha(s), tw, th, "full"), tw, th
end

---Cache key for a cropped sixel slice. Same dim-availability constraint as
---sixel_cache_key_full.
---@param s alt-img._core.provider.State
---@param src alt-img._core.provider.SrcRect
---@return string?
local function sixel_cache_key_crop(s, src)
    if not (s.opts.width and s.opts.height) then
        return nil
    end
    local cell_size = require("alt-img._core.cell_size")
    cell_size.query()
    local cw, ch = cell_size.current()
    local scale = sixel_scale()
    local tw, th = s.opts.width * cw * scale, s.opts.height * ch * scale
    local x_px, y_px = src.x * cw * scale, src.y * ch * scale
    local w_px, h_px = src.w * cw * scale, src.h * ch * scale
    local rect = string.format("%d,%d,%d,%d", x_px, y_px, w_px, h_px)
    local cache = require("alt-img._core.cache")
    return cache.key(cache.input_sha(s), tw, th, rect)
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

---Try the priority chain (chafa→img2sixel→magick) on the *original* PNG
---with explicit pixel-target dims, so each tool does as much decode +
---resize + sixel-encode work as possible per subprocess. Returns nil if
---no tool produced output — the caller falls back to the pure-Lua RGBA
---path (which decodes/resizes in Lua then re-runs the dispatcher).
---@param s alt-img._core.provider.State
---@param target_w integer
---@param target_h integer
---@return string?
local function try_full_via_tools(s, target_w, target_h)
    local chafa = require("alt-img.sixel._chafa")
    local libsixel = require("alt-img.sixel._libsixel")
    local magick = require("alt-img._core.magick")
    if chafa.binary() then
        local out = chafa.encode_sixel_resized(s.data, target_w, target_h)
        if out and #out > 0 then
            return out
        end
    end
    if libsixel.binary() then
        local out = libsixel.encode_sixel_resized(s.data, target_w, target_h)
        if out and #out > 0 then
            return out
        end
    end
    if magick.binary() then
        local out = magick.encode_sixel_from_png_resized(s.data, target_w, target_h)
        if out and #out > 0 then
            return out
        end
    end
    return nil
end

---Same idea as `try_full_via_tools` but for a cropped slice — chafa relies
---on magick for the decode+resize+crop hop (it can't crop), img2sixel and
---magick each do everything in one subprocess.
---@param s alt-img._core.provider.State
---@param full_w integer
---@param full_h integer
---@param x_px integer
---@param y_px integer
---@param w_px integer
---@param h_px integer
---@return string?
local function try_crop_via_tools(s, full_w, full_h, x_px, y_px, w_px, h_px)
    local chafa = require("alt-img.sixel._chafa")
    local libsixel = require("alt-img.sixel._libsixel")
    local magick = require("alt-img._core.magick")
    if chafa.binary() then
        local out = chafa.crop_resized_to_sixel(s.data, full_w, full_h, x_px, y_px, w_px, h_px)
        if out and #out > 0 then
            return out
        end
    end
    if libsixel.binary() then
        local out = libsixel.crop_resized_to_sixel(s.data, full_w, full_h, x_px, y_px, w_px, h_px)
        if out and #out > 0 then
            return out
        end
    end
    if magick.binary() then
        local out = magick.crop_resized_to_sixel(s.data, full_w, full_h, x_px, y_px, w_px, h_px)
        if out and #out > 0 then
            return out
        end
    end
    return nil
end

---@param s alt-img._core.provider.State
---@return string sixel
local function build_sixel(s)
    local cs = s.codec_state
    if cs.full_sixel then
        return cs.full_sixel
    end
    local cache = require("alt-img._core.cache")
    local key = sixel_cache_key_full(s)
    if key then
        local cached = cache.lookup(key, ".sixel")
        if cached then
            cs.full_sixel = cached
            return cached
        end
    end
    local cell_size = require("alt-img._core.cell_size")
    cell_size.query()
    local cw, ch = cell_size.current()
    local scale = sixel_scale()
    if s.opts.width and s.opts.height then
        local target_w = s.opts.width * cw * scale
        local target_h = s.opts.height * ch * scale
        local tool_out = try_full_via_tools(s, target_w, target_h)
        if tool_out then
            cs.full_sixel = tool_out
            if key then
                cache.store(key, ".sixel", tool_out)
            end
            return tool_out
        end
    end
    -- No tool produced output (or no target dims known): fall back to the
    -- pure-Lua decode+resize+RGBA-dispatch tail.
    local rgba, w, h = ensure_resized(s)
    if scale > 1 then
        rgba, w, h = require("alt-img._core.image").resize(rgba, w, h, w * scale, h * scale)
    end
    cs.full_sixel = require("alt-img.sixel._encode").encode_sixel_dispatch(rgba, w, h)
    if key then
        cache.store(key, ".sixel", cs.full_sixel)
    end
    return cs.full_sixel
end

---@param s alt-img._core.provider.State
---@param src alt-img._core.provider.SrcRect
---@return string sixel
local function build_sixel_cropped(s, src)
    local cache = require("alt-img._core.cache")
    local key = sixel_cache_key_crop(s, src)
    if key then
        local cached = cache.lookup(key, ".sixel")
        if cached then
            return cached
        end
    end
    local cell_size = require("alt-img._core.cell_size")
    cell_size.query()
    local cw, ch = cell_size.current()
    local scale = sixel_scale()
    local x_px, y_px = src.x * cw * scale, src.y * ch * scale
    local w_px, h_px = src.w * cw * scale, src.h * ch * scale
    if s.opts.width and s.opts.height then
        local full_w = s.opts.width * cw * scale
        local full_h = s.opts.height * ch * scale
        local tool_out = try_crop_via_tools(s, full_w, full_h, x_px, y_px, w_px, h_px)
        if tool_out then
            if key then
                cache.store(key, ".sixel", tool_out)
            end
            return tool_out
        end
    end

    local rgba, w, h = ensure_resized(s)
    if scale > 1 then
        rgba, w, h = require("alt-img._core.image").resize(rgba, w, h, w * scale, h * scale)
    end
    local cropped, cw_px, ch_px = require("alt-img._core.image").crop_rgba(rgba, w, h, x_px, y_px, w_px, h_px)
    local out = require("alt-img.sixel._encode").encode_sixel_dispatch(cropped, cw_px, ch_px)
    if key then
        cache.store(key, ".sixel", out)
    end
    return out
end

local codec = {}

---@param s alt-img._core.provider.State
function codec.invalidate(s)
    s.codec_state = {}
end

---@param s alt-img._core.provider.State
---@return boolean
function codec.has_cached_full(s)
    local cs = s.codec_state
    if cs and cs.full_sixel then
        return true
    end
    if require("alt-img.sixel._chafa").binary() then
        return true
    end
    if require("alt-img.sixel._libsixel").binary() then
        return true
    end
    if require("alt-img._core.magick").binary() then
        return true
    end
    local key = sixel_cache_key_full(s)
    if not key then
        return true
    end
    local cache = require("alt-img._core.cache")
    return cache.lookup(key, ".sixel") ~= nil
end

---@param s alt-img._core.provider.State
---@param src alt-img._core.provider.SrcRect
---@return boolean
function codec.has_cached_crop(s, src)
    local cs = s.codec_state
    if cs and cs.crop_cache then
        local k = string.format("%d,%d,%d,%d", src.x, src.y, src.w, src.h)
        if cs.crop_cache[k] then
            return true
        end
    end
    if require("alt-img.sixel._chafa").binary() then
        return true
    end
    if require("alt-img.sixel._libsixel").binary() then
        return true
    end
    if require("alt-img._core.magick").binary() then
        return true
    end
    local key = sixel_cache_key_crop(s, src)
    if not key then
        return true
    end
    local cache = require("alt-img._core.cache")
    return cache.lookup(key, ".sixel") ~= nil
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
    local cache = require("alt-img._core.cache")
    local cache_key = sixel_cache_key_full(s)
    if cache_key then
        local cached = cache.lookup(cache_key, ".sixel")
        if cached then
            cs.full_sixel = cached
            return on_done(cached)
        end
    end
    local chafa = require("alt-img.sixel._chafa")
    local libsixel = require("alt-img.sixel._libsixel")
    local magick = require("alt-img._core.magick")

    local cell_size = require("alt-img._core.cell_size")
    cell_size.query()
    local cw, ch = cell_size.current()
    local scale = sixel_scale()
    local target_w = s.opts.width * cw * scale
    local target_h = s.opts.height * ch * scale

    local function deliver(out)
        if out and #out > 0 then
            cs.full_sixel = out
            if cache_key then
                cache.store(cache_key, ".sixel", out)
            end
            return on_done(out)
        end
        on_done(nil)
    end

    -- Priority: chafa → img2sixel → magick. First-available wins; on
    -- subprocess failure on_done(nil) lets the provider's sync fallback
    -- (build_at) try the next tool via encode_sixel_dispatch (which
    -- exercises the pure-Lua tail). Each tool gets the original PNG bytes
    -- and the explicit pixel target so it does decode + resize + sixel-
    -- encode in one subprocess (chafa needs magick as a feeder for the
    -- pixel-resize step, since chafa alone cannot pixel-resize).
    if chafa.binary() then
        return chafa.encode_sixel_resized_async(s.data, target_w, target_h, deliver)
    end
    if libsixel.binary() then
        return libsixel.encode_sixel_resized_async(s.data, target_w, target_h, deliver)
    end
    if magick.binary() then
        return magick.encode_sixel_from_png_resized_async(s.data, target_w, target_h, deliver)
    end
    on_done(nil)
end

---@param s alt-img._core.provider.State
---@param src alt-img._core.provider.SrcRect
---@param on_done fun(bytes: string?)
function codec.encode_crop_async(s, src, on_done)
    local cs = s.codec_state
    ensure_caches(cs)
    local key = string.format("%d,%d,%d,%d", src.x, src.y, src.w, src.h)
    if cs.crop_cache[key] then
        return on_done(cs.crop_cache[key])
    end
    local cache = require("alt-img._core.cache")
    local cache_key = sixel_cache_key_crop(s, src)
    if cache_key then
        local cached = cache.lookup(cache_key, ".sixel")
        if cached then
            local lru = require("alt-img._core.lru")
            lru.put(
                cs.crop_cache,
                cs.crop_cache_order,
                key,
                cached,
                require("alt-img._core.precompute").required_lru_size(s.opts)
            )
            return on_done(cached)
        end
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
            if cache_key then
                cache.store(cache_key, ".sixel", out)
            end
            return on_done(out)
        end
        on_done(nil)
    end

    if not (s.opts.width and s.opts.height) then
        return on_done(nil)
    end
    local cell_size = require("alt-img._core.cell_size")
    cell_size.query()
    local cw, ch = cell_size.current()
    local scale = sixel_scale()
    local x_px, y_px = src.x * cw * scale, src.y * ch * scale
    local w_px, h_px = src.w * cw * scale, src.h * ch * scale
    local full_w = s.opts.width * cw * scale
    local full_h = s.opts.height * ch * scale

    -- Priority: chafa → img2sixel → magick. Each tool does decode +
    -- pixel-resize + pixel-crop + sixel-encode in one subprocess (chafa
    -- requires magick as a feeder for the resize+crop step). On
    -- subprocess failure the provider falls back to sync build_at which
    -- runs the pure-Lua tail.
    if chafa.binary() then
        return chafa.crop_resized_to_sixel_async(s.data, full_w, full_h, x_px, y_px, w_px, h_px, deliver)
    end
    if libsixel.binary() then
        return libsixel.crop_resized_to_sixel_async(s.data, full_w, full_h, x_px, y_px, w_px, h_px, deliver)
    end
    if magick.binary() then
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
