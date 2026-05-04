local util = require("alt-img._core.util")
local tty = require("alt-img._core.tty")
local render = require("alt-img._core.render")
local png = require("alt-img._core.png")
local image = require("alt-img._core.image")
local magick = require("alt-img._core.magick")
local lru = require("alt-img._core.lru")
local _config = require("alt-img._core.config")

local M = {}

---@type table<string, boolean>
local FAST_TERM_PROGRAMS = {
    ["iTerm.app"] = true,
    ["WezTerm"] = true,
}

---@class alt-img.iterm2.CropEntry
---@field png string PNG bytes for this crop
---@field b64 string base64-encoded PNG bytes for this crop

---@class alt-img.iterm2.State
---@field data string raw PNG bytes
---@field opts vim.ui.img.Opts canonical opts
---@field id integer placement id
---@field resized_rgba string? RGBA pixel buffer after nearest-neighbor resize
---@field resized_w integer? pixel width of resized buffer
---@field resized_h integer? pixel height of resized buffer
---@field full_png string? full-image PNG bytes (post-resize)
---@field full_png_b64 string? base64-encoded full_png
---@field png_cache_by_src table<string, alt-img.iterm2.CropEntry>? LRU map of crop key → cached PNG+b64
---@field png_cache_by_src_order string[]? LRU insertion-order keys for png_cache_by_src

---@type table<integer, alt-img.iterm2.State>
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

---Decode the source PNG to RGBA, resize via nearest-neighbor to the cell-pixel
---area requested by opts.width/opts.height, and cache the result.
---@param s alt-img.iterm2.State
---@return string rgba, integer w, integer h
local function ensure_resized(s)
    if s.resized_rgba then
        return s.resized_rgba, s.resized_w, s.resized_h
    end
    util.query_cell_size()
    local img = png.decode(s.data)
    local rgba, w, h = img.pixels, img.width, img.height
    local cw, ch = util.cell_pixel_size()
    if s.opts.width or s.opts.height then
        local target_w = (s.opts.width or math.ceil(img.width / cw)) * cw
        local target_h = (s.opts.height or math.ceil(img.height / ch)) * ch
        rgba, w, h = image.resize(rgba, img.width, img.height, target_w, target_h)
    end
    s.resized_rgba, s.resized_w, s.resized_h = rgba, w, h
    return rgba, w, h
end

---Encode the resized RGBA buffer back to PNG once and cache it alongside its
---base64 form. Routes through magick when available and dims are known.
---@param s alt-img.iterm2.State
---@return string png_bytes, string b64
local function ensure_full_png(s)
    if s.full_png and s.full_png_b64 then
        return s.full_png, s.full_png_b64
    end
    util.query_cell_size()
    if magick.binary() and s.opts.width and s.opts.height then
        local cw, ch = util.cell_pixel_size()
        local out = magick.encode_png_resized(s.data, s.opts.width * cw, s.opts.height * ch)
        if out and #out > 0 then
            s.full_png = out
            s.full_png_b64 = vim.base64.encode(out)
            return s.full_png, s.full_png_b64
        end
    end
    local rgba, w, h = ensure_resized(s)
    s.full_png = png.encode(rgba, w, h)
    s.full_png_b64 = vim.base64.encode(s.full_png)
    return s.full_png, s.full_png_b64
end

---Crop a sub-rectangle of the resized PNG and re-encode as PNG.
---@param s alt-img.iterm2.State
---@param src { x: integer, y: integer, w: integer, h: integer } crop rect in cell units
---@return string png_bytes, string b64, integer cw_px, integer ch_px
local function build_png_cropped(s, src)
    util.query_cell_size()
    local cw, ch = util.cell_pixel_size()
    local x_px = src.x * cw
    local y_px = src.y * ch
    local w_px = src.w * cw
    local h_px = src.h * ch
    -- Fast path: crop + PNG re-encode via `convert` on the resized PNG bytes.
    -- We feed the *resized* PNG (not the original) so the accelerated path
    -- crops the same image data the pure-Lua fallback would.
    local resized_png = ensure_full_png(s)
    local accel = magick.crop_to_png(resized_png, x_px, y_px, w_px, h_px)
    if accel and #accel > 0 then
        return accel, vim.base64.encode(accel), w_px, h_px
    end
    local rgba, full_w, full_h = ensure_resized(s)
    local cropped, cw_px, ch_px = image.crop_rgba(rgba, full_w, full_h, x_px, y_px, w_px, h_px)
    local png_bytes = png.encode(cropped, cw_px, ch_px)
    return png_bytes, vim.base64.encode(png_bytes), cw_px, ch_px
end

---@param s alt-img.iterm2.State
---@param key string crop cache key
---@return alt-img.iterm2.CropEntry?
local function crop_cache_get(s, key)
    s.png_cache_by_src = s.png_cache_by_src or {}
    s.png_cache_by_src_order = s.png_cache_by_src_order or {}
    return lru.get(s.png_cache_by_src, s.png_cache_by_src_order, key)
end

---@param s alt-img.iterm2.State
---@param key string crop cache key
---@param value alt-img.iterm2.CropEntry
local function crop_cache_put(s, key, value)
    s.png_cache_by_src = s.png_cache_by_src or {}
    s.png_cache_by_src_order = s.png_cache_by_src_order or {}
    lru.put(s.png_cache_by_src, s.png_cache_by_src_order, key, value, _config.read().crop_cache_size)
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
    -- is_full: route to the original-PNG fast path. Guard against nil dims so
    -- the equality check is well-defined; if dims are missing (e.g. ui mode
    -- without explicit dims) we treat the placement as full to avoid crashing
    -- in build_png_cropped on `nil * px_per_cell`.
    local is_full = not src
        or not opts.width
        or not opts.height
        or (src.x == 0 and src.y == 0 and src.w == opts.width and src.h == opts.height)
    local data, b64, width_cells, height_cells
    if is_full then
        -- Pre-resize to the cell-pixel area via nearest-neighbor before sending
        -- so iTerm2's scaler sees a 1:1 mapping (sharp output). Data is always
        -- PNG (validated at the M.set boundary), so decode failure is a real
        -- error, not a fallback path.
        data, b64 = ensure_full_png(s)
        width_cells, height_cells = opts.width, opts.height
    else
        local key = string.format("%d,%d,%d,%d", src.x, src.y, src.w, src.h)
        local entry = crop_cache_get(s, key)
        if not entry then
            local png_bytes, b64_str = build_png_cropped(s, src)
            entry = { png = png_bytes, b64 = b64_str }
            crop_cache_put(s, key, entry)
        end
        data = entry.png
        b64 = entry.b64
        width_cells, height_cells = src.w, src.h
    end

    local args = {
        "size=" .. #data,
        "inline=1",
        "preserveAspectRatio=" .. ((width_cells and height_cells) and 0 or 1),
    }
    if width_cells then
        args[#args + 1] = "width=" .. width_cells
    end
    if height_cells then
        args[#args + 1] = "height=" .. height_cells
    end

    local cs = {
        save = "\0277",
        hide = "\027[?25l",
        move = string.format(
            "\027[%d;%dH",
            screen_pos and screen_pos.row or (opts.row or 1),
            screen_pos and screen_pos.col or (opts.col or 1)
        ),
        restore = "\0278",
        show = "\027[?25h",
    }

    local osc = "\027]1337;File=" .. table.concat(args, ";") .. ":" .. b64 .. "\007"
    return cs.save .. cs.hide .. cs.move .. osc .. cs.restore .. cs.show
end

---Build the OSC 1337 payload and write it to the terminal.
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

    local is_full = src.x == 0 and src.y == 0 and src.w == opts.width and src.h == opts.height

    if is_full then
        if s.full_png and s.full_png_b64 then
            return on_done()
        end
        magick.encode_png_resized_async(s.data, opts.width * cw, opts.height * ch, function(png_bytes)
            if png_bytes and #png_bytes > 0 then
                s.full_png = png_bytes
                s.full_png_b64 = vim.base64.encode(png_bytes)
            end
            on_done()
        end)
        return
    end

    -- Cropped variant. Need full_png cached to crop from.
    local key = string.format("%d,%d,%d,%d", src.x, src.y, src.w, src.h)
    s.png_cache_by_src = s.png_cache_by_src or {}
    s.png_cache_by_src_order = s.png_cache_by_src_order or {}
    if s.png_cache_by_src[key] then
        return on_done()
    end

    local function do_crop()
        local x_px = src.x * cw
        local y_px = src.y * ch
        local w_px = src.w * cw
        local h_px = src.h * ch
        magick.crop_to_png_async(s.full_png, x_px, y_px, w_px, h_px, function(cropped_png)
            if cropped_png and #cropped_png > 0 then
                local entry = { png = cropped_png, b64 = vim.base64.encode(cropped_png) }
                lru.put(s.png_cache_by_src, s.png_cache_by_src_order, key, entry, _config.read().crop_cache_size)
            end
            on_done()
        end)
    end

    if s.full_png and #s.full_png > 0 then
        do_crop()
    else
        magick.encode_png_resized_async(s.data, opts.width * cw, opts.height * ch, function(png_bytes)
            if not png_bytes or #png_bytes == 0 then
                return on_done()
            end
            s.full_png = png_bytes
            s.full_png_b64 = vim.base64.encode(png_bytes)
            do_crop()
        end)
    end
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
            error("alt-img.iterm2: unknown id " .. tostring(data_or_id), 2)
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
            s.png_cache_by_src = nil
            s.png_cache_by_src_order = nil
            s.resized_rgba = nil
            s.resized_w = nil
            s.resized_h = nil
            s.full_png = nil
            s.full_png_b64 = nil
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
        png_cache_by_src = {},
        png_cache_by_src_order = {},
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
    -- Schedule background pre-encoding of cropped variants so the first
    -- partial-visibility scroll doesn't pay the magick / image.encode cost
    -- in the foreground. See _core/precompute.lua.
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
    local tp = vim.env.TERM_PROGRAM
    if tp and FAST_TERM_PROGRAMS[tp] then
        return true
    end

    -- Probe via XTVERSION (CSI > q). The internal tty.query helper is
    -- self-contained, so the probe always runs; if the terminal does
    -- not respond, we fall through to a `false` return after the timeout.
    local timeout = opts.timeout or 1000
    local done, ok, msg = false, false, nil
    tty.query("\027[>q", { timeout = timeout }, function(resp)
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

vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
        M.del(math.huge)
    end,
})

return M
