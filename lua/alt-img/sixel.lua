local util = require("alt-img._core.util")
local tty = require("alt-img._core.tty")
local png = require("alt-img._core.png")
local image = require("alt-img._core.image")
local magick = require("alt-img._core.magick")
local senc = require("alt-img.sixel._encode")
local render = require("alt-img._core.render")
local lru = require("alt-img._core.lru")
local config = require("alt-img._core.config")

local M = {}

---@type table<string, boolean>
local KNOWN_SIXEL_TERMS = {
    foot = true,
    mlterm = true,
    contour = true,
}
---@type table<string, boolean>
local SUPPORTING_TERM_PROGRAMS = {
    ["iTerm.app"] = true, -- iTerm2 v3.5+ supports sixel
    ["WezTerm"] = true,
}

---@class alt-img.sixel.State
---@field data string raw PNG bytes
---@field opts vim.ui.img.Opts canonical opts
---@field id integer placement id
---@field resized_rgba string? RGBA pixel buffer after nearest-neighbor resize
---@field resized_w integer? pixel width of resized buffer
---@field resized_h integer? pixel height of resized buffer
---@field sixel_cache string? cached full-image sixel DCS
---@field sixel_cache_by_src table<string, string>? LRU map of crop key → sixel DCS
---@field sixel_cache_by_src_order string[]? LRU insertion-order keys for sixel_cache_by_src

---@type table<integer, alt-img.sixel.State>
local state = {}
---@type integer
local next_id = 1

---@return integer
local function new_id()
    local id = next_id
    next_id = next_id + 1
    return id
end

---@param opts? vim.ui.img.Opts
---@return vim.ui.img.Opts
local function canonicalize(opts)
    opts = opts or {}
    -- relative defaults: if opts.buf is set, default to 'buffer'; else 'ui'.
    local rel = opts.relative or (opts.buf ~= nil and "buffer" or "ui")
    if rel ~= "ui" and rel ~= "editor" and rel ~= "buffer" then
        error("alt-img: invalid relative " .. tostring(rel) .. " (expected 'ui', 'editor', or 'buffer')", 3)
    end
    -- buf == 0 means current buffer.
    local buf = opts.buf
    if buf == 0 then
        buf = vim.api.nvim_get_current_buf()
    end
    return {
        row = opts.row,
        col = opts.col,
        width = opts.width,
        height = opts.height,
        zindex = opts.zindex,
        relative = rel,
        buf = buf,
        pad = opts.pad,
    }
end

---For non-ui modes, derive width/height from PNG IHDR if not provided.
---Mutates opts in-place.
---@param data string raw PNG bytes
---@param opts vim.ui.img.Opts canonical opts
local function derive_dims(data, opts)
    if opts.relative == "ui" or (opts.width and opts.height) then
        return
    end
    local px_w, px_h = util.png_dimensions(data)
    util.query_cell_size()
    local cell_w, cell_h = util.cell_pixel_size()
    opts.width = opts.width or math.ceil(px_w / cell_w)
    opts.height = opts.height or math.ceil(px_h / cell_h)
end

---@param s alt-img.sixel.State
---@return string rgba, integer w, integer h
local function ensure_resized(s)
    if s.resized_rgba then
        return s.resized_rgba, s.resized_w, s.resized_h
    end
    local img = png.decode(s.data)
    local rgba, w, h = img.pixels, img.width, img.height
    local cw, ch = util.cell_pixel_size()
    if s.opts.width or s.opts.height then
        local target_w = (s.opts.width or math.ceil(w / cw)) * cw
        local target_h = (s.opts.height or math.ceil(h / ch)) * ch
        rgba, w, h = image.resize(rgba, w, h, target_w, target_h)
    end
    s.resized_rgba, s.resized_w, s.resized_h = rgba, w, h
    return rgba, w, h
end

---Return the active sixel pixel scale factor (clamped to >= 1).
---Reads config fresh on every call so runtime changes take effect.
---@return integer
local function sixel_scale()
    local s = (config.read() or {}).sixel_pixel_scale
    if type(s) == "number" then
        return math.max(1, math.floor(s))
    end
    return util.terminal_pixel_scale()
end

---Build the full-image sixel DCS for placement `s`, caching the result.
---@param s alt-img.sixel.State
---@return string sixel
local function build_sixel(s)
    if s.sixel_cache then
        return s.sixel_cache
    end
    util.query_cell_size()
    local scale = sixel_scale()

    -- magick fast path: do decode + resize + sixel-encode in one subprocess.
    -- Bypasses the pure-Lua decoder entirely, which is the dominant cost on
    -- first display when libz is missing (pure-Lua INFLATE is glacial).
    if magick.binary() then
        local out
        if s.opts.width and s.opts.height then
            local cw, ch = util.cell_pixel_size()
            out = magick.encode_sixel_from_png_resized(s.data, s.opts.width * cw * scale, s.opts.height * ch * scale)
        else
            out = magick.encode_sixel_from_png(s.data)
        end
        if out and #out > 0 then
            s.sixel_cache = out
            return s.sixel_cache
        end
    end

    -- Pure-Lua fallback: decode, optionally resize, then encode through the
    -- libsixel-or-pure-Lua dispatcher.
    local rgba, w, h = ensure_resized(s)
    if scale > 1 then
        rgba, w, h = image.resize(rgba, w, h, w * scale, h * scale)
    end
    s.sixel_cache = senc.encode_sixel_dispatch(rgba, w, h)
    return s.sixel_cache
end

---Build a sixel DCS for a sub-rectangle of the resized image.
---@param s alt-img.sixel.State
---@param src { x: integer, y: integer, w: integer, h: integer } crop rect in cell units
---@return string sixel
local function build_sixel_cropped(s, src)
    util.query_cell_size()
    local cw, ch = util.cell_pixel_size()
    local scale = sixel_scale()
    local x_px = src.x * cw * scale
    local y_px = src.y * ch * scale
    local w_px = src.w * cw * scale
    local h_px = src.h * ch * scale
    local full_w = s.opts.width * cw * scale
    local full_h = s.opts.height * ch * scale

    if magick.binary() then
        local accel = magick.crop_resized_to_sixel(s.data, full_w, full_h, x_px, y_px, w_px, h_px)
        if accel and #accel > 0 then
            return accel
        end
    end

    local rgba, w, h = ensure_resized(s)
    if scale > 1 then
        rgba, w, h = image.resize(rgba, w, h, w * scale, h * scale)
    end
    local cropped, cw_px, ch_px = image.crop_rgba(rgba, w, h, x_px, y_px, w_px, h_px)
    return senc.encode_sixel_dispatch(cropped, cw_px, ch_px)
end

---@param s alt-img.sixel.State
---@param key string crop cache key
---@return string?
local function crop_cache_get(s, key)
    s.sixel_cache_by_src = s.sixel_cache_by_src or {}
    s.sixel_cache_by_src_order = s.sixel_cache_by_src_order or {}
    return lru.get(s.sixel_cache_by_src, s.sixel_cache_by_src_order, key)
end

---@param s alt-img.sixel.State
---@param key string crop cache key
---@param value string sixel DCS bytes
local function crop_cache_put(s, key, value)
    s.sixel_cache_by_src = s.sixel_cache_by_src or {}
    s.sixel_cache_by_src_order = s.sixel_cache_by_src_order or {}
    lru.put(s.sixel_cache_by_src, s.sixel_cache_by_src_order, key, value, config.read().crop_cache_size)
end

---Build the full byte string for placement `id` at `screen_pos`. Returns nil
---when the placement is unknown. Split from emit_at so the render coordinator
---can construct payloads outside the Mode 2026 sync block.
---@param id integer
---@param screen_pos { row: integer, col: integer, src?: { x: integer, y: integer, w: integer, h: integer } }?
---@return string? bytes
local function build_at(id, screen_pos)
    local s = state[id]
    if not s then
        return nil
    end
    local opts = s.opts
    local src = screen_pos and screen_pos.src
    -- is_full: route to the cached full-image fast path. Guard against nil dims
    -- so the equality check is well-defined; if dims are missing (e.g. ui mode
    -- without explicit dims) we treat the placement as full to avoid crashing
    -- in build_sixel_cropped on `nil * cw`.
    local is_full = not src
        or not opts.width
        or not opts.height
        or (src.x == 0 and src.y == 0 and src.w == opts.width and src.h == opts.height)
    local sixel
    if is_full then
        sixel = build_sixel(s)
    else
        local key = string.format("%d,%d,%d,%d", src.x, src.y, src.w, src.h)
        local cached = crop_cache_get(s, key)
        if not cached then
            cached = build_sixel_cropped(s, src)
            crop_cache_put(s, key, cached)
        end
        sixel = cached
    end
    local cmove = string.format(
        "\027[%d;%dH",
        screen_pos and screen_pos.row or (opts.row or 1),
        screen_pos and screen_pos.col or (opts.col or 1)
    )
    return "\0277" .. "\027[?25l" .. cmove .. sixel .. "\0278" .. "\027[?25h"
end

---Build the sixel DCS payload and write it to the terminal.
---@param id integer
---@param screen_pos { row: integer, col: integer, src?: { x: integer, y: integer, w: integer, h: integer } }?
local function emit_at(id, screen_pos)
    local bytes = build_at(id, screen_pos)
    if bytes then
        util.term_send(bytes)
    end
end

---Warm the encoding cache for `id` at `src` asynchronously (no .wait()).
---on_done() fires from vim.schedule when the cache is populated or skipped.
---Falls back to synchronous build_at when magick is not on PATH.
---@param id integer
---@param src { x: integer, y: integer, w: integer, h: integer }?
---@param on_done fun()
local function precompute_async(id, src, on_done)
    local s = state[id]
    if not s or not src then
        return on_done()
    end

    if not magick.binary() then
        pcall(build_at, id, { row = 1, col = 1, src = src })
        return on_done()
    end

    local opts = s.opts
    if not opts.width or not opts.height then
        return on_done()
    end

    util.query_cell_size()
    local cw, ch = util.cell_pixel_size()
    local scale = sixel_scale()

    local is_full = src.x == 0 and src.y == 0 and src.w == opts.width and src.h == opts.height

    if is_full then
        if s.sixel_cache then
            return on_done()
        end
        magick.encode_sixel_from_png_resized_async(
            s.data,
            opts.width * cw * scale,
            opts.height * ch * scale,
            function(sixel_bytes)
                if sixel_bytes and #sixel_bytes > 0 then
                    s.sixel_cache = sixel_bytes
                end
                on_done()
            end
        )
        return
    end

    -- Cropped variant. crop_resized_to_sixel does decode + resize + crop +
    -- sixel encode in one subprocess, so no chained async dependency.
    local key = string.format("%d,%d,%d,%d", src.x, src.y, src.w, src.h)
    s.sixel_cache_by_src = s.sixel_cache_by_src or {}
    s.sixel_cache_by_src_order = s.sixel_cache_by_src_order or {}
    if s.sixel_cache_by_src[key] then
        return on_done()
    end

    local x_px = src.x * cw * scale
    local y_px = src.y * ch * scale
    local w_px = src.w * cw * scale
    local h_px = src.h * ch * scale
    local full_w = opts.width * cw * scale
    local full_h = opts.height * ch * scale

    magick.crop_resized_to_sixel_async(s.data, full_w, full_h, x_px, y_px, w_px, h_px, function(sixel_bytes)
        if sixel_bytes and #sixel_bytes > 0 then
            lru.put(s.sixel_cache_by_src, s.sixel_cache_by_src_order, key, sixel_bytes, config.read().crop_cache_size)
        end
        on_done()
    end)
end

---Closure factory: produces a position resolver for placement `id`.
---The returned function returns a list of `{ row, col, src? }` records.
---@param id integer
---@return fun(): { row: integer, col: integer, src?: { x: integer, y: integer, w: integer, h: integer } }[]
local function get_pos_for(id)
    return function()
        local s = state[id]
        if not s then
            return {}
        end
        if s.opts.relative == "ui" then
            local p = util.clip_to_bounds(
                s.opts.row or 1,
                s.opts.col or 1,
                s.opts.width or 1,
                s.opts.height or 1,
                1,
                1,
                vim.o.lines,
                vim.o.columns
            )
            return p and { p } or {}
        end
        return require("alt-img._core.carrier").get_positions(M, id) or {}
    end
end

---@param query_id integer
---@return vim.ui.img.Opts?
local function get_opts(query_id)
    return state[query_id] and state[query_id].opts
end

---@param data_or_id string|integer image bytes (string) or existing id (integer)
---@param opts? vim.ui.img.Opts
---@return integer id
function M.set(data_or_id, opts)
    vim.validate("data_or_id", data_or_id, { "string", "number" })
    vim.validate("opts", opts, "table", true)

    if type(data_or_id) == "number" then
        -- Update path
        local s = state[data_or_id]
        if not s then
            error("alt-img.sixel: unknown id " .. tostring(data_or_id), 2)
        end
        local upd = canonicalize(opts)
        if not (opts and opts.relative) then
            upd.relative = s.opts.relative
        end
        -- Capture old relative and dimensions BEFORE merge.
        local old_relative = s.opts.relative
        local old_w, old_h = s.opts.width, s.opts.height
        s.opts = vim.tbl_extend("force", s.opts, upd)
        -- If merge resulted in non-ui without explicit dims, derive from PNG IHDR.
        derive_dims(s.data, s.opts)
        -- Only invalidate encoding caches when dimensions actually changed.
        -- Position, row/col, zindex, pad, relative don't affect encoding.
        local dims_changed = s.opts.width ~= old_w or s.opts.height ~= old_h
        if dims_changed then
            s.sixel_cache = nil -- dims changed -> may need re-encode
            s.sixel_cache_by_src = nil -- crop cache also stale on size change
            s.sixel_cache_by_src_order = nil
            s.resized_rgba = nil -- width/height change invalidates cached resize
            s.resized_w = nil
            s.resized_h = nil
        end
        -- Manage carrier lifecycle across relative-mode transitions:
        --   ui → editor/buffer: register a new carrier.
        --   editor/buffer → ui: unregister the existing carrier.
        --   editor/buffer → editor/buffer: update in place (carrier.update
        --     handles kind swaps internally via unregister+re-register).
        local carrier = require("alt-img._core.carrier")
        if old_relative == "ui" and s.opts.relative ~= "ui" then
            carrier.register(M, data_or_id, s.opts)
        elseif old_relative ~= "ui" and s.opts.relative == "ui" then
            carrier.unregister(M, data_or_id)
        elseif s.opts.relative ~= "ui" then
            carrier.update(M, data_or_id, s.opts)
        end
        -- Mark dirty; the position-diff in tick() drives clearing automatically.
        render.invalidate(state[data_or_id], data_or_id)
        render.flush()
        -- Restart precompute when dims changed (cache was just invalidated).
        if dims_changed then
            require("alt-img._core.precompute").start(state[data_or_id], data_or_id, s.opts, {
                build_at = build_at,
                precompute_async = precompute_async,
            })
        end
        return data_or_id
    end

    -- New placement path
    local id = new_id()
    local opts_canonical = canonicalize(opts)
    -- If non-ui and dims missing, derive from the PNG IHDR.
    derive_dims(data_or_id, opts_canonical)
    state[id] = {
        data = data_or_id,
        opts = opts_canonical,
        id = id,
        sixel_cache_by_src = {},
        sixel_cache_by_src_order = {},
    }

    if state[id].opts.relative ~= "ui" then
        require("alt-img._core.carrier").register(M, id, state[id].opts)
    end

    render.register(state[id], id, get_pos_for(id), {
        emit_at = emit_at,
        build_at = build_at,
        get_opts = get_opts,
    })
    -- Synchronous initial paint so callers (and tests) see the image immediately.
    render.flush()
    -- Schedule background pre-encoding of cropped variants (see
    -- _core/precompute.lua) so partial-visibility scrolls don't pay
    -- the magick / img2sixel cost in the foreground.
    require("alt-img._core.precompute").start(state[id], id, opts_canonical, {
        build_at = build_at,
        precompute_async = precompute_async,
    })
    return id
end

---@param id integer
---@return vim.ui.img.Opts? opts
function M.get(id)
    local s = state[id]
    if not s then
        return nil
    end
    return vim.deepcopy(s.opts)
end

---@param id integer
---@return boolean found
function M.del(id)
    if id == math.huge then
        local any = next(state) ~= nil
        -- Capture tokens and keys before clearing state.
        local to_cancel = {}
        for k, s in pairs(state) do
            to_cancel[#to_cancel + 1] = { token = s, k = k }
        end
        for _, entry in ipairs(to_cancel) do
            require("alt-img._core.precompute").cancel(entry.token, entry.k)
            require("alt-img._core.carrier").unregister(M, entry.k)
            render.unregister(entry.token, entry.k)
        end
        state = {}
        if any then
            render.flush()
        end
        return any
    end
    if not state[id] then
        return false
    end
    local token = state[id]
    require("alt-img._core.precompute").cancel(token, id)
    require("alt-img._core.carrier").unregister(M, id)
    render.unregister(token, id)
    state[id] = nil
    render.flush()
    return true
end

---@private
---@param opts? { timeout?: integer }
---@return boolean supported
---@return string? msg
function M._supported(opts)
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
    -- DA1 probe (CSI c) — response includes ;4 if sixel supported. The
    -- internal tty.query helper is self-contained, so the probe always
    -- runs; if the terminal does not respond, we fall through to a
    -- `false` return after the timeout.
    local timeout = opts.timeout or 1000
    local done, ok, msg = false, false, nil
    tty.query("\027[c", { timeout = timeout }, function(resp)
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

vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
        M.del(math.huge)
    end,
})

return M
