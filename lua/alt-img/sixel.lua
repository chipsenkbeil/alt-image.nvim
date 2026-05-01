-- lua/alt-img/sixel.lua
-- Sixel image protocol provider, drop-in for vim.ui.img.
-- Ported from chipsenkbeil/neovim:feat/MoreImgProviders
--   runtime/lua/vim/ui/img/_sixel.lua
--
-- Input is required to be PNG bytes — we match the upstream vim.ui.img
-- contract. Decode, optional resize, sixel-encode, cache per-placement, and
-- emit the DCS sequence. When `magick` is on PATH we route the entire
-- decode + resize + sixel-encode through one subprocess so the pure-Lua
-- decoder/inflater is bypassed (matters most when libz is missing).

local util = require("alt-img._core.util")
local tty = require("alt-img._core.tty")
local png = require("alt-img._core.png")
local image = require("alt-img._core.image")
local magick = require("alt-img._core.magick")
local senc = require("alt-img.sixel._encode")
local render = require("alt-img._core.render")
local lru = require("alt-img._core.lru")
local _config = require("alt-img._core.config")

local M = {}

local KNOWN_SIXEL_TERMS = {
    foot = true,
    mlterm = true,
    contour = true,
}
local SUPPORTING_TERM_PROGRAMS = {
    ["iTerm.app"] = true, -- iTerm2 v3.5+ supports sixel
    ["WezTerm"] = true,
}

-- state[id] = { data = bytes, opts = canonical_opts, sixel_cache = string|nil,
--               sixel_cache_by_src = { [key]=string }, id = id }
local state = {}
local next_id = 1

local function new_id()
    local id = next_id
    next_id = next_id + 1
    return id
end

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
---Mutates opts in-place. Data is guaranteed PNG by the boundary check in
---M.set, so we read the IHDR unconditionally.
---@param data string raw PNG bytes
---@param opts table canonical opts
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

-- Read sixel_pixel_scale fresh on each build so toggling it in vim.g
-- without restarting takes effect on the next render. Clamp to >= 1.
local function sixel_scale()
    local s = (_config.read() or {}).sixel_pixel_scale or 1
    if type(s) ~= "number" or s < 1 then
        return 1
    end
    return math.floor(s)
end

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

-- Build a sixel DCS for a sub-rectangle of the resized image. `src` is in
-- cell units; the carrier math operates in resized-target pixel space, so
-- the magick fast path uses `-sample WxH! -crop CWxCH+X+Y` to do everything
-- in one subprocess and skip the pure-Lua decode/resize/crop chain.
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

local function crop_cache_get(s, key)
    s.sixel_cache_by_src = s.sixel_cache_by_src or {}
    s.sixel_cache_by_src_order = s.sixel_cache_by_src_order or {}
    return lru.get(s.sixel_cache_by_src, s.sixel_cache_by_src_order, key)
end

local function crop_cache_put(s, key, value)
    s.sixel_cache_by_src = s.sixel_cache_by_src or {}
    s.sixel_cache_by_src_order = s.sixel_cache_by_src_order or {}
    lru.put(s.sixel_cache_by_src, s.sixel_cache_by_src_order, key, value, _config.read().crop_cache_size)
end

-- Public so _render can call us. Reads state[id], emits sixel DCS at screen_pos.
function M._emit_at(id, screen_pos)
    local s = state[id]
    if not s then
        return
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
    util.term_send("\0277" .. "\027[?25l" .. cmove .. sixel .. "\0278" .. "\027[?25h")
end

-- Closure factory: produces a position resolver for placement `id` that the
-- render coordinator can call without knowing about provider internals.
-- Returns a list of position records `{ row, col, src = { x, y, w, h } }`,
-- possibly empty. For ui-mode, a single full-image src is emitted. For
-- editor/buffer modes, the carrier may shrink src to clip against window
-- bounds, and split into multiple entries (one per visible window).
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

function M.set(data_or_id, opts)
    vim.validate({
        data_or_id = { data_or_id, { "string", "number" } },
        opts = { opts, "table", true },
    })
    if type(data_or_id) == "string" and not util.is_png_data(data_or_id) then
        error("alt-img.sixel: data must be a PNG byte string (matches vim.ui.img)", 2)
    end

    if type(data_or_id) == "number" then
        -- Update path
        local s = state[data_or_id]
        if not s then
            error("alt-img.sixel: unknown id " .. tostring(data_or_id), 2)
        end
        -- v1: don't support relative-changing updates. Preserve original relative
        -- on partial-merge so canonicalize's default of 'ui' doesn't clobber it.
        local upd = canonicalize(opts)
        if not (opts and opts.relative) then
            upd.relative = s.opts.relative
        end
        -- Explicit guard: if caller tries to change relative, error out.
        if opts and opts.relative and opts.relative ~= s.opts.relative then
            error(
                string.format(
                    "alt-img.sixel: cannot change relative on update (was %s, got %s); del and re-create instead",
                    s.opts.relative,
                    opts.relative
                ),
                2
            )
        end
        -- Capture old dimensions BEFORE merge so we can detect if they actually changed.
        local old_w, old_h = s.opts.width, s.opts.height
        s.opts = vim.tbl_extend("force", s.opts, upd)
        -- If merge resulted in non-ui without explicit dims, derive from PNG IHDR.
        derive_dims(s.data, s.opts)
        -- Only invalidate encoding caches when dimensions actually changed.
        -- Position, row/col, zindex, pad, relative (ui-mode only) don't affect encoding.
        if s.opts.width ~= old_w or s.opts.height ~= old_h then
            s.sixel_cache = nil -- dims changed -> may need re-encode
            s.sixel_cache_by_src = nil -- crop cache also stale on size change
            s.sixel_cache_by_src_order = nil
            s.resized_rgba = nil -- width/height change invalidates cached resize
            s.resized_w = nil
            s.resized_h = nil
        end
        -- For carrier-managed placements, reposition the carrier so the resolved
        -- screen pos reflects the new opts (otherwise the float stays put).
        if s.opts.relative ~= "ui" then
            require("alt-img._core.carrier").update(M, data_or_id, s.opts)
        end
        -- Mark dirty; the position-diff in tick() drives clearing automatically.
        render.invalidate(M, data_or_id)
        render.flush()
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

    render.register(M, id, get_pos_for(id))
    -- Synchronous initial paint so callers (and tests) see the image immediately.
    render.flush()
    return id
end

function M.get(id)
    local s = state[id]
    if not s then
        return nil
    end
    return vim.deepcopy(s.opts)
end

function M.del(id)
    if id == math.huge then
        local any = next(state) ~= nil
        for k, _ in pairs(state) do
            require("alt-img._core.carrier").unregister(M, k)
            render.unregister(M, k)
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
    require("alt-img._core.carrier").unregister(M, id)
    render.unregister(M, id)
    state[id] = nil
    render.flush()
    return true
end

-- Force every registered placement to re-emit on the next render tick.
-- Use after `:mode`, `:redraw!`, terminal-side clears, or any other event
-- that has wiped image bytes from the terminal compositor without an
-- accompanying nvim grid update. The position-equality elision in the
-- render loop otherwise assumes those pixels are still there.
function M.refresh()
    render.refresh()
end

function M._supported(opts)
    opts = opts or {}
    if vim.env.TERM_PROGRAM == "Apple_Terminal" then
        return false, "Apple Terminal does not support sixel"
    end
    if vim.env.WT_SESSION then
        return true, "WT_SESSION (Windows Terminal)"
    end
    local tp = vim.env.TERM_PROGRAM
    if tp and SUPPORTING_TERM_PROGRAMS[tp] then
        return true, "TERM_PROGRAM=" .. tp
    end
    local term = vim.env.TERM or ""
    if term:find("sixel", 1, true) or KNOWN_SIXEL_TERMS[term] then
        return true, "TERM=" .. term
    end
    -- DA1 probe (CSI c) — response includes ;4 if sixel supported. The
    -- internal tty.query helper is self-contained, so the probe always
    -- runs; if the terminal does not respond, we fall through to a
    -- `false` return after the timeout.
    local timeout = opts.timeout or 1000
    local done, ok, msg = false, false, nil
    tty.query("\027[c", { timeout = timeout }, function(resp)
        if resp and resp:find(";4", 1, true) then
            ok, msg = true, resp
        end
        done = true
    end)
    vim.wait(timeout + 100, function()
        return done
    end)
    return ok, msg
end

-- Expose state for testing only.
M._state = state

return M
