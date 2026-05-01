-- lua/alt-img/iterm2.lua
-- iTerm2 OSC 1337 image protocol provider, drop-in for vim.ui.img.
-- Ported from chipsenkbeil/neovim:feat/MoreImgProviders
--   runtime/lua/vim/ui/img/_iterm2.lua

local util = require("alt-img._core.util")
local tty = require("alt-img._core.tty")
local render = require("alt-img._core.render")
local png = require("alt-img._core.png")
local image = require("alt-img._core.image")
local magick = require("alt-img._core.magick")
local lru = require("alt-img._core.lru")

local M = {}

local FAST_TERM_PROGRAMS = {
    ["iTerm.app"] = true,
    ["WezTerm"] = true,
}

-- Per-id placement state.
-- state[id] = { data = bytes, opts = canonical_opts, id = id,
--               decoded_rgba = string|nil, decoded_w = int|nil, decoded_h = int|nil,
--               full_png = string|nil, full_png_b64 = string|nil,
--               png_cache_by_src = { [key]={ png=string, b64=string } },
--               png_cache_by_src_order = { key, ... } }
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

---Decode the source PNG to RGBA, resize via nearest-neighbor to the cell-pixel
---area requested by opts.width/opts.height, and cache the result. Mirrors
---sixel.lua's ensure_resized so iTerm2 receives a 1:1 pixel mapping (image
---dims == cell area in pixels) and renders sharply instead of relying on the
---terminal's smooth scaling.
---@param s table placement state
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

---Encode the resized RGBA buffer back to PNG once and cache it, alongside its
---base64 form. This is the data we send via OSC 1337 for the full-image fast
---path; the terminal sees image pixel dims that match the cell-pixel area
---exactly, so its built-in scaling becomes a no-op. The base64 cache avoids
---paying `vim.base64.encode` on every emit (non-trivial for large images
---under mouse-follow).
---@param s table placement state
---@return string png_bytes, string b64
local function ensure_full_png(s)
    if s.full_png and s.full_png_b64 then
        return s.full_png, s.full_png_b64
    end
    local rgba, w, h = ensure_resized(s)
    s.full_png = png.encode(rgba, w, h)
    s.full_png_b64 = vim.base64.encode(s.full_png)
    return s.full_png, s.full_png_b64
end

---Crop a sub-rectangle of the resized PNG and re-encode as PNG. Also returns
---the base64-encoded form so callers (and the per-src LRU) can cache both
---together — base64 is paid once, not on every emit.
---@param s table placement state
---@param src table { x, y, w, h } in cell units
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

local function crop_cache_get(s, key)
    s.png_cache_by_src = s.png_cache_by_src or {}
    s.png_cache_by_src_order = s.png_cache_by_src_order or {}
    return lru.get(s.png_cache_by_src, s.png_cache_by_src_order, key)
end

local function crop_cache_put(s, key, value)
    s.png_cache_by_src = s.png_cache_by_src or {}
    s.png_cache_by_src_order = s.png_cache_by_src_order or {}
    lru.put(s.png_cache_by_src, s.png_cache_by_src_order, key, value)
end

-- Public so _render can call us. Reads state[id], emits OSC 1337 at screen_pos.
function M._emit_at(id, screen_pos)
    local s = state[id]
    if not s then
        return
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
    util.term_send(cs.save .. cs.hide .. cs.move .. osc .. cs.restore .. cs.show)
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
        error("alt-img.iterm2: data must be a PNG byte string (matches vim.ui.img)", 2)
    end

    if type(data_or_id) == "number" then
        -- Update path
        local s = state[data_or_id]
        if not s then
            error("alt-img.iterm2: unknown id " .. tostring(data_or_id), 2)
        end
        -- v1: don't support relative-changing updates (carrier kind would need
        -- to be re-created). Preserve the original relative on partial-merge so
        -- canonicalize's default of 'ui' doesn't clobber 'editor'/'buffer'.
        local upd = canonicalize(opts)
        if not (opts and opts.relative) then
            upd.relative = s.opts.relative
        end
        -- Explicit guard: if caller tries to change relative, error out.
        if opts and opts.relative and opts.relative ~= s.opts.relative then
            error(
                string.format(
                    "alt-img.iterm2: cannot change relative on update (was %s, got %s); del and re-create instead",
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
            s.png_cache_by_src = nil
            s.png_cache_by_src_order = nil
            s.resized_rgba = nil
            s.resized_w = nil
            s.resized_h = nil
            s.full_png = nil
            s.full_png_b64 = nil
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
        png_cache_by_src = {},
        png_cache_by_src_order = {},
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

function M._supported(opts)
    opts = opts or {}
    local tp = vim.env.TERM_PROGRAM
    if tp and FAST_TERM_PROGRAMS[tp] then
        return true, "TERM_PROGRAM=" .. tp
    end

    -- Probe via XTVERSION (CSI > q). The internal tty.query helper is
    -- self-contained, so the probe always runs; if the terminal does
    -- not respond, we fall through to a `false` return after the timeout.
    local timeout = opts.timeout or 1000
    local done, ok, msg = false, false, nil
    tty.query("\027[>q", { timeout = timeout }, function(resp)
        if resp and (resp:find("iTerm2", 1, true) or resp:find("WezTerm", 1, true)) then
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
