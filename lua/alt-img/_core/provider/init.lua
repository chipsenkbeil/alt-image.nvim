local M = {}

---@param opts? vim.ui.img.Opts
---@return vim.ui.img.Opts
local function canonicalize(opts)
    opts = opts or {}
    local rel = opts.relative or (opts.buf ~= nil and "buffer" or "ui")
    if rel ~= "ui" and rel ~= "editor" and rel ~= "buffer" then
        error("alt-img: invalid relative " .. tostring(rel) .. " (expected 'ui', 'editor', or 'buffer')", 4)
    end
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
---@param opts vim.ui.img.Opts
local function derive_dims(data, opts)
    if opts.relative == "ui" or (opts.width and opts.height) then
        return
    end
    local px_w, px_h = require("alt-img._core.png_header").dimensions(data)
    local cell_size = require("alt-img._core.cell_size")
    cell_size.query()
    local cell_w, cell_h = cell_size.current()
    opts.width = opts.width or math.ceil(px_w / cell_w)
    opts.height = opts.height or math.ceil(px_h / cell_h)
end

---@param row integer
---@param col integer
---@param payload string
---@return string
local function frame(row, col, payload)
    local move = string.format("\027[%d;%dH", row, col)
    return "\0277" .. "\027[?25l" .. move .. payload .. "\0278" .. "\027[?25h"
end

---@param src? alt-img._core.provider.SrcRect
---@param opts vim.ui.img.Opts
---@return boolean
local function is_full_rect(src, opts)
    if not src or not opts.width or not opts.height then
        return true
    end
    return src.x == 0 and src.y == 0 and src.w == opts.width and src.h == opts.height
end

---Construct a provider module backed by `codec`. The returned table exposes
---only the upstream `vim.ui.img` surface plus `_supported`.
---@param codec alt-img._core.provider.Codec
---@return table provider
function M.new(codec)
    local provider = {}

    ---@type table<integer, alt-img._core.provider.State>
    local state = {}
    local next_id = 1

    local function new_id()
        local id = next_id
        next_id = next_id + 1
        return id
    end

    ---@param id integer
    ---@param screen_pos? { row: integer, col: integer, src?: alt-img._core.provider.SrcRect }
    ---@return string?
    local function build_at(id, screen_pos)
        local s = state[id]
        if not s then
            return nil
        end
        local src = screen_pos and screen_pos.src
        local payload
        if is_full_rect(src, s.opts) then
            payload = codec.encode_full(s)
        else
            payload = codec.encode_crop(s, src)
        end
        if not payload then
            return nil
        end
        local row = (screen_pos and screen_pos.row) or (s.opts.row or 1)
        local col = (screen_pos and screen_pos.col) or (s.opts.col or 1)
        return frame(row, col, payload)
    end

    ---@param id integer
    ---@param screen_pos? { row: integer, col: integer, src?: alt-img._core.provider.SrcRect }
    local function emit_at(id, screen_pos)
        local bytes = build_at(id, screen_pos)
        if bytes then
            require("alt-img._core.term_io").send(bytes)
        end
    end

    ---Async cache warmer. Falls back to a sync build_at when codec lacks an
    ---async path (pure-Lua codecs). on_done() always fires.
    ---@param id integer
    ---@param src alt-img._core.provider.SrcRect?
    ---@param on_done fun()
    local function precompute_async(id, src, on_done)
        local s = state[id]
        if not s or not src then
            return on_done()
        end
        local opts = s.opts
        if not opts.width or not opts.height then
            return on_done()
        end
        local full = is_full_rect(src, opts)
        if full and codec.encode_full_async then
            codec.encode_full_async(s, function()
                on_done()
            end)
        elseif (not full) and codec.encode_crop_async then
            codec.encode_crop_async(s, src, function()
                on_done()
            end)
        else
            pcall(build_at, id, { row = 1, col = 1, src = src })
            on_done()
        end
    end

    ---@param id integer
    ---@return fun(): { row: integer, col: integer, src?: alt-img._core.provider.SrcRect }[]
    local function get_pos_for(id)
        return function()
            local s = state[id]
            if not s then
                return {}
            end
            if s.opts.relative == "ui" then
                local p = require("alt-img._core.clip").to_bounds(
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
            return require("alt-img._core.carrier").get_positions(provider, id) or {}
        end
    end

    ---@param query_id integer
    ---@return vim.ui.img.Opts?
    local function get_opts(query_id)
        return state[query_id] and state[query_id].opts
    end

    ---@param data_or_id string|integer
    ---@param opts? vim.ui.img.Opts
    ---@return integer id
    function provider.set(data_or_id, opts)
        vim.validate("data_or_id", data_or_id, { "string", "number" })
        vim.validate("opts", opts, "table", true)

        if type(data_or_id) == "number" then
            local s = state[data_or_id]
            if not s then
                error("alt-img: unknown id " .. tostring(data_or_id), 2)
            end
            local upd = canonicalize(opts)
            if not (opts and opts.relative) then
                upd.relative = s.opts.relative
            end
            local old_relative = s.opts.relative
            local old_w, old_h = s.opts.width, s.opts.height
            s.opts = vim.tbl_extend("force", s.opts, upd)
            derive_dims(s.data, s.opts)
            local dims_changed = s.opts.width ~= old_w or s.opts.height ~= old_h
            if dims_changed then
                codec.invalidate(s)
            end

            -- Carrier lifecycle across relative-mode transitions.
            local carrier = require("alt-img._core.carrier")
            if old_relative == "ui" and s.opts.relative ~= "ui" then
                carrier.register(provider, data_or_id, s.opts)
            elseif old_relative ~= "ui" and s.opts.relative == "ui" then
                carrier.unregister(provider, data_or_id)
            elseif s.opts.relative ~= "ui" then
                carrier.update(provider, data_or_id, s.opts)
            end

            local render = require("alt-img._core.render")
            render.invalidate(s, data_or_id)
            render.flush()

            if dims_changed then
                require("alt-img._core.precompute").start(s, data_or_id, s.opts, {
                    build_at = build_at,
                    precompute_async = precompute_async,
                })
            end
            return data_or_id
        end

        local id = new_id()
        local opts_canonical = canonicalize(opts)
        derive_dims(data_or_id, opts_canonical)
        state[id] = {
            data = data_or_id,
            opts = opts_canonical,
            id = id,
            codec_state = {},
        }
        local s = state[id]

        if s.opts.relative ~= "ui" then
            require("alt-img._core.carrier").register(provider, id, s.opts)
        end

        local render = require("alt-img._core.render")
        render.register(s, id, get_pos_for(id), {
            emit_at = emit_at,
            build_at = build_at,
            get_opts = get_opts,
        })
        render.flush()

        require("alt-img._core.precompute").start(s, id, opts_canonical, {
            build_at = build_at,
            precompute_async = precompute_async,
        })
        return id
    end

    ---@param id integer
    ---@return vim.ui.img.Opts?
    function provider.get(id)
        local s = state[id]
        if not s then
            return nil
        end
        return vim.deepcopy(s.opts)
    end

    ---Snapshot of `{ [id] = opts }` for every active placement. Used by
    ---`:AltImg info` to enumerate what each provider has open. Not part of
    ---the upstream `vim.ui.img` surface — health/diagnostic introspection.
    ---@return table<integer, vim.ui.img.Opts>
    function provider.placements()
        local out = {}
        for id, s in pairs(state) do
            out[id] = vim.deepcopy(s.opts)
        end
        return out
    end

    ---@param id integer
    ---@return boolean found
    function provider.del(id)
        local render = require("alt-img._core.render")
        local precompute = require("alt-img._core.precompute")
        local carrier = require("alt-img._core.carrier")

        if id == math.huge then
            local any = next(state) ~= nil
            local entries = {}
            for k, s in pairs(state) do
                entries[#entries + 1] = { token = s, k = k }
            end
            for _, entry in ipairs(entries) do
                precompute.cancel(entry.token, entry.k)
                carrier.unregister(provider, entry.k)
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
        precompute.cancel(token, id)
        carrier.unregister(provider, id)
        render.unregister(token, id)
        state[id] = nil
        render.flush()
        return true
    end

    ---@private
    ---@param opts? { timeout?: integer }
    ---@return boolean supported
    ---@return string? msg
    function provider._supported(opts)
        return codec.probe(opts)
    end

    vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = function()
            provider.del(math.huge)
        end,
    })

    return provider
end

return M
