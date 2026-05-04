---@type table<string, boolean>
local FAST_TERM_PROGRAMS = {
    ["iTerm.app"] = true,
    ["WezTerm"] = true,
}

---@class alt-img.iterm2.CropEntry
---@field png string PNG bytes for this crop
---@field b64 string base64-encoded PNG bytes for this crop

---@class alt-img.iterm2.CodecState
---@field resized_rgba string? RGBA pixel buffer after nearest-neighbor resize
---@field resized_w integer? pixel width of resized buffer
---@field resized_h integer? pixel height of resized buffer
---@field full_png string? full-image PNG bytes (post-resize)
---@field full_png_b64 string? base64-encoded full_png
---@field crop_cache table<string, alt-img.iterm2.CropEntry>? LRU map of crop key → cached PNG+b64
---@field crop_cache_order string[]? LRU insertion-order keys for crop_cache

---@param cs alt-img.iterm2.CodecState
local function ensure_caches(cs)
    cs.crop_cache = cs.crop_cache or {}
    cs.crop_cache_order = cs.crop_cache_order or {}
end

---Cache key for the placement's full resized PNG. nil if dims unknown.
---@param s alt-img._core.provider.State
---@return string?
local function png_cache_key_full(s)
    if not (s.opts.width and s.opts.height) then
        return nil
    end
    local cell_size = require("alt-img._core.cell_size")
    cell_size.query()
    local cw, ch = cell_size.current()
    local tw, th = s.opts.width * cw, s.opts.height * ch
    local cache = require("alt-img._core.cache")
    return cache.key(cache.input_sha(s), tw, th, "full")
end

---Cache key for a cropped PNG slice. nil if dims unknown.
---@param s alt-img._core.provider.State
---@param src alt-img._core.provider.SrcRect
---@return string?
local function png_cache_key_crop(s, src)
    if not (s.opts.width and s.opts.height) then
        return nil
    end
    local cell_size = require("alt-img._core.cell_size")
    cell_size.query()
    local cw, ch = cell_size.current()
    local tw, th = s.opts.width * cw, s.opts.height * ch
    local x_px, y_px = src.x * cw, src.y * ch
    local w_px, h_px = src.w * cw, src.h * ch
    local rect = string.format("%d,%d,%d,%d", x_px, y_px, w_px, h_px)
    local cache = require("alt-img._core.cache")
    return cache.key(cache.input_sha(s), tw, th, rect)
end

---Decode → resize-to-cell-pixel-grid → cache RGBA pixels for the placement.
---@param s alt-img._core.provider.State
---@return string rgba, integer w, integer h
local function ensure_resized(s)
    local cs = s.codec_state
    if cs.resized_rgba then
        return cs.resized_rgba, cs.resized_w, cs.resized_h
    end
    local cell_size = require("alt-img._core.cell_size")
    cell_size.query()
    local png = require("alt-img._core.png")
    local img = png.decode(s.data)
    local rgba, w, h = img.pixels, img.width, img.height
    local cw, ch = cell_size.current()
    if s.opts.width or s.opts.height then
        local target_w = (s.opts.width or math.ceil(img.width / cw)) * cw
        local target_h = (s.opts.height or math.ceil(img.height / ch)) * ch
        rgba, w, h = require("alt-img._core.image").resize(rgba, img.width, img.height, target_w, target_h)
    end
    cs.resized_rgba, cs.resized_w, cs.resized_h = rgba, w, h
    return rgba, w, h
end

---Encode the resized pixels back to PNG once and cache it (plus base64).
---Routes through the disk cache → magick → pure-Lua fallback chain.
---@param s alt-img._core.provider.State
---@return string png_bytes, string b64
local function ensure_full_png(s)
    local cs = s.codec_state
    if cs.full_png and cs.full_png_b64 then
        return cs.full_png, cs.full_png_b64
    end
    local cache = require("alt-img._core.cache")
    local key = png_cache_key_full(s)
    if key then
        local cached = cache.lookup(key, ".png")
        if cached then
            cs.full_png = cached
            cs.full_png_b64 = vim.base64.encode(cached)
            return cs.full_png, cs.full_png_b64
        end
    end
    local cell_size = require("alt-img._core.cell_size")
    cell_size.query()
    local magick = require("alt-img._core.magick")
    if magick.binary() and s.opts.width and s.opts.height then
        local cw, ch = cell_size.current()
        local out = magick.encode_png_resized(s.data, s.opts.width * cw, s.opts.height * ch)
        if out and #out > 0 then
            cs.full_png = out
            cs.full_png_b64 = vim.base64.encode(out)
            if key then
                cache.store(key, ".png", out)
            end
            return cs.full_png, cs.full_png_b64
        end
    end
    local rgba, w, h = ensure_resized(s)
    local png = require("alt-img._core.png")
    cs.full_png = png.encode(rgba, w, h)
    cs.full_png_b64 = vim.base64.encode(cs.full_png)
    if key then
        cache.store(key, ".png", cs.full_png)
    end
    return cs.full_png, cs.full_png_b64
end

---Crop a sub-rectangle of the resized PNG and re-encode as PNG.
---@param s alt-img._core.provider.State
---@param src alt-img._core.provider.SrcRect crop rect in cell units
---@return string png_bytes, string b64, integer cw_px, integer ch_px
local function build_png_cropped(s, src)
    local cache = require("alt-img._core.cache")
    local key = png_cache_key_crop(s, src)
    local cell_size = require("alt-img._core.cell_size")
    cell_size.query()
    local cw, ch = cell_size.current()
    local x_px, y_px = src.x * cw, src.y * ch
    local w_px, h_px = src.w * cw, src.h * ch
    if key then
        local cached = cache.lookup(key, ".png")
        if cached then
            return cached, vim.base64.encode(cached), w_px, h_px
        end
    end
    local resized_png = ensure_full_png(s)
    local magick = require("alt-img._core.magick")
    local accel = magick.crop_to_png(resized_png, x_px, y_px, w_px, h_px)
    if accel and #accel > 0 then
        if key then
            cache.store(key, ".png", accel)
        end
        return accel, vim.base64.encode(accel), w_px, h_px
    end
    local rgba, full_w, full_h = ensure_resized(s)
    local cropped, cw_px, ch_px = require("alt-img._core.image").crop_rgba(rgba, full_w, full_h, x_px, y_px, w_px, h_px)
    local png = require("alt-img._core.png")
    local png_bytes = png.encode(cropped, cw_px, ch_px)
    if key then
        cache.store(key, ".png", png_bytes)
    end
    return png_bytes, vim.base64.encode(png_bytes), cw_px, ch_px
end

---Build OSC 1337 from PNG bytes (iTerm2 inline image protocol).
---@param png_bytes string
---@param b64 string
---@param width_cells integer?
---@param height_cells integer?
---@return string
local function build_osc(png_bytes, b64, width_cells, height_cells)
    local args = {
        "size=" .. #png_bytes,
        "inline=1",
        "preserveAspectRatio=" .. ((width_cells and height_cells) and 0 or 1),
    }
    if width_cells then
        args[#args + 1] = "width=" .. width_cells
    end
    if height_cells then
        args[#args + 1] = "height=" .. height_cells
    end
    return "\027]1337;File=" .. table.concat(args, ";") .. ":" .. b64 .. "\007"
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
    if cs and cs.full_png and cs.full_png_b64 then
        return true
    end
    -- magick available means encode_full uses the subprocess fast path.
    if require("alt-img._core.magick").binary() then
        return true
    end
    if not (s.opts.width and s.opts.height) then
        return true -- no dims yet → encode_full is a no-op
    end
    local cache = require("alt-img._core.cache")
    local cell_size = require("alt-img._core.cell_size")
    cell_size.query()
    local cw, ch = cell_size.current()
    local key = cache.key(cache.input_sha(s), s.opts.width * cw, s.opts.height * ch, "full")
    return cache.lookup(key, ".png") ~= nil
end

---@param s alt-img._core.provider.State
---@param src alt-img._core.provider.SrcRect
---@return boolean
function codec.has_cached_crop(s, src)
    local cs = s.codec_state
    if cs and cs.crop_cache then
        local key = string.format("%d,%d,%d,%d", src.x, src.y, src.w, src.h)
        if cs.crop_cache[key] then
            return true
        end
    end
    if require("alt-img._core.magick").binary() then
        return true
    end
    local key = png_cache_key_crop(s, src)
    if not key then
        return true
    end
    local cache = require("alt-img._core.cache")
    return cache.lookup(key, ".png") ~= nil
end

---@param s alt-img._core.provider.State
---@return string?
function codec.encode_full(s)
    local png_bytes, b64 = ensure_full_png(s)
    return build_osc(png_bytes, b64, s.opts.width, s.opts.height)
end

---@param s alt-img._core.provider.State
---@param src alt-img._core.provider.SrcRect
---@return string?
function codec.encode_crop(s, src)
    local cs = s.codec_state
    ensure_caches(cs)
    local key = string.format("%d,%d,%d,%d", src.x, src.y, src.w, src.h)
    local lru = require("alt-img._core.lru")
    local entry = lru.get(cs.crop_cache, cs.crop_cache_order, key)
    if not entry then
        local png_bytes, b64 = build_png_cropped(s, src)
        entry = { png = png_bytes, b64 = b64 }
        lru.put(
            cs.crop_cache,
            cs.crop_cache_order,
            key,
            entry,
            require("alt-img._core.precompute").required_lru_size(s.opts)
        )
    end
    return build_osc(entry.png, entry.b64, src.w, src.h)
end

---@param s alt-img._core.provider.State
---@param on_done fun(bytes: string?)
function codec.encode_full_async(s, on_done)
    local cs = s.codec_state
    if cs.full_png and cs.full_png_b64 then
        return on_done(build_osc(cs.full_png, cs.full_png_b64, s.opts.width, s.opts.height))
    end
    local cache = require("alt-img._core.cache")
    local cache_key = png_cache_key_full(s)
    if cache_key then
        local cached = cache.lookup(cache_key, ".png")
        if cached then
            cs.full_png = cached
            cs.full_png_b64 = vim.base64.encode(cached)
            return on_done(build_osc(cs.full_png, cs.full_png_b64, s.opts.width, s.opts.height))
        end
    end
    local magick = require("alt-img._core.magick")
    if not (magick.binary() and s.opts.width and s.opts.height) then
        return on_done(nil)
    end
    local cell_size = require("alt-img._core.cell_size")
    cell_size.query()
    local cw, ch = cell_size.current()
    magick.encode_png_resized_async(s.data, s.opts.width * cw, s.opts.height * ch, function(png_bytes)
        if png_bytes and #png_bytes > 0 then
            cs.full_png = png_bytes
            cs.full_png_b64 = vim.base64.encode(png_bytes)
            if cache_key then
                cache.store(cache_key, ".png", png_bytes)
            end
            return on_done(build_osc(cs.full_png, cs.full_png_b64, s.opts.width, s.opts.height))
        end
        on_done(nil)
    end)
end

---@param s alt-img._core.provider.State
---@param src alt-img._core.provider.SrcRect
---@param on_done fun(bytes: string?)
function codec.encode_crop_async(s, src, on_done)
    local cs = s.codec_state
    ensure_caches(cs)
    local key = string.format("%d,%d,%d,%d", src.x, src.y, src.w, src.h)
    if cs.crop_cache[key] then
        local hit = cs.crop_cache[key]
        return on_done(build_osc(hit.png, hit.b64, src.w, src.h))
    end
    local cache = require("alt-img._core.cache")
    local cache_key = png_cache_key_crop(s, src)
    if cache_key then
        local cached = cache.lookup(cache_key, ".png")
        if cached then
            local entry = { png = cached, b64 = vim.base64.encode(cached) }
            local lru = require("alt-img._core.lru")
            lru.put(
                cs.crop_cache,
                cs.crop_cache_order,
                key,
                entry,
                require("alt-img._core.precompute").required_lru_size(s.opts)
            )
            return on_done(build_osc(entry.png, entry.b64, src.w, src.h))
        end
    end
    local magick = require("alt-img._core.magick")
    if not magick.binary() then
        return on_done(nil)
    end
    local cell_size = require("alt-img._core.cell_size")
    cell_size.query()
    local cw, ch = cell_size.current()

    local function do_crop()
        local x_px, y_px = src.x * cw, src.y * ch
        local w_px, h_px = src.w * cw, src.h * ch
        magick.crop_to_png_async(cs.full_png, x_px, y_px, w_px, h_px, function(cropped_png)
            if cropped_png and #cropped_png > 0 then
                local entry = { png = cropped_png, b64 = vim.base64.encode(cropped_png) }
                local lru = require("alt-img._core.lru")
                lru.put(
                    cs.crop_cache,
                    cs.crop_cache_order,
                    key,
                    entry,
                    require("alt-img._core.precompute").required_lru_size(s.opts)
                )
                if cache_key then
                    cache.store(cache_key, ".png", cropped_png)
                end
                return on_done(build_osc(entry.png, entry.b64, src.w, src.h))
            end
            on_done(nil)
        end)
    end

    if cs.full_png and #cs.full_png > 0 then
        do_crop()
    else
        magick.encode_png_resized_async(s.data, s.opts.width * cw, s.opts.height * ch, function(png_bytes)
            if not png_bytes or #png_bytes == 0 then
                return on_done(nil)
            end
            cs.full_png = png_bytes
            cs.full_png_b64 = vim.base64.encode(png_bytes)
            local full_key = png_cache_key_full(s)
            if full_key then
                cache.store(full_key, ".png", png_bytes)
            end
            do_crop()
        end)
    end
end

---@param opts? { timeout?: integer }
---@return boolean, string?
function codec.probe(opts)
    opts = opts or {}
    -- Windows Terminal does not implement the iTerm2 OSC 1337 inline image
    -- protocol. Skip the XTVERSION probe — its reply (e.g. "Microsoft.Terminal")
    -- never matches our regex, so the probe just times out at 1000+ ms on
    -- the first call into autodetect.matches() (and again on every direct
    -- iterm2._supported() in `:AltImg info`). Short-circuit instead.
    if vim.env.WT_SESSION and vim.env.WT_SESSION ~= "" then
        return false, "Windows Terminal does not implement iTerm2 inline images"
    end
    local tp = vim.env.TERM_PROGRAM
    if tp and FAST_TERM_PROGRAMS[tp] then
        return true
    end
    local timeout = opts.timeout or 1000
    local done, ok, msg = false, false, nil
    require("alt-img._core.tty").query("\027[>q", { timeout = timeout }, function(resp)
        if resp and (resp:find("iTerm2", 1, true) or resp:find("WezTerm", 1, true)) then
            ok = true
        elseif resp then
            msg = "XTVERSION response did not match iTerm2/WezTerm: " .. resp
        end
        done = true
    end)
    vim.wait(timeout + 100, function()
        return done
    end)
    return ok, msg
end

return require("alt-img._core.provider").new(codec)
