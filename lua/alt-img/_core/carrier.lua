local M = {}

---@type integer
local NS = vim.api.nvim_create_namespace("alt-img._core.carrier")

---@type integer
local AUGROUP = vim.api.nvim_create_augroup("alt-img._core.carrier", { clear = true })

---@class alt-img._core.carrier.Carrier
---@field id integer placement id
---@field provider table provider that registered this carrier
---@field opts table canonical opts at register/update time
---@field kind 'editor'|'buffer' which carrier flavor is in use
---@field winid integer floating-window id (editor kind)
---@field extmark_id integer extmark id reserving virt_lines (buffer kind)
---@field bufnr integer host buffer (both kinds)
---@type table<string, alt-img._core.carrier.Carrier>
local carriers = {}

---@param provider table
---@param id integer|any
---@return string
local function provider_key(provider, id)
    return tostring(provider) .. ":" .. tostring(id)
end

---@param opts table
---@return integer w, integer h
local function size_in_cells(opts)
    local pad = opts.pad or 0
    local w = (opts.width or 1) + pad
    local h = opts.height or 1
    return w, h
end

---@param opts table
---@return integer winid, integer bufnr
local function open_editor_carrier(opts)
    local buf = vim.api.nvim_create_buf(false, true)
    local w, h = size_in_cells(opts)
    local winid = vim.api.nvim_open_win(buf, false, {
        relative = "editor",
        row = (opts.row or 1) - 1,
        col = (opts.col or 1) - 1,
        width = w,
        height = h,
        focusable = false,
        style = "minimal",
        zindex = opts.zindex or 50,
    })
    return winid, buf
end

---@param opts table
---@return integer extmark_id
local function place_buffer_extmark(opts)
    local _, h = size_in_cells(opts)
    local virt = {}
    for _ = 1, h do
        virt[#virt + 1] = { { "", "Normal" } }
    end
    local row = (opts.row or 1) - 1
    return vim.api.nvim_buf_set_extmark(opts.buf, NS, row, (opts.col or 1) - 1, {
        end_row = row + 1,
        end_col = 0,
        virt_lines = virt,
        virt_lines_above = false,
        invalidate = true,
        -- undo_restore stays default (true) so 'u' after 'dd' brings the image
        -- back: dd hides the mark (invalid=true), undo restores it. The
        -- positions resolver checks details.invalid and treats hidden marks
        -- as off-screen.
    })
end

---@param c alt-img._core.carrier.Carrier
---@return alt-img._core.render.Position[]
local function resolve(c)
    local positions = require("alt-img._core.carrier.positions")
    if c.kind == "editor" then
        return positions.resolve_editor(c)
    end
    return positions.resolve_buffer(c, NS)
end

---@param provider table
---@param id integer|any
---@param opts table
function M.register(provider, id, opts)
    local c = { provider = provider, id = id, opts = opts }
    if opts.relative == "editor" then
        c.kind = "editor"
        c.winid, c.bufnr = open_editor_carrier(opts)
    elseif opts.relative == "buffer" then
        if not opts.buf then
            error("alt-img: relative=buffer requires opts.buf", 3)
        end
        c.kind = "buffer"
        c.bufnr = opts.buf
        c.extmark_id = place_buffer_extmark(opts)
    else
        error("alt-img: unsupported relative " .. tostring(opts.relative), 3)
    end
    carriers[provider_key(provider, id)] = c
end

---@param provider table
---@param id integer|any
---@param opts table
function M.update(provider, id, opts)
    local c = carriers[provider_key(provider, id)]
    if not c then
        return
    end

    -- Relative mode change (editor → buffer, etc.): tear down and re-register
    -- so each carrier kind's internal state stays consistent.
    local new_kind = opts.relative == "editor" and "editor" or "buffer"
    if new_kind ~= c.kind then
        M.unregister(provider, id)
        M.register(provider, id, opts)
        return
    end

    c.opts = opts
    if c.kind == "editor" then
        if c.winid and vim.api.nvim_win_is_valid(c.winid) then
            local w, h = size_in_cells(opts)
            vim.api.nvim_win_set_config(c.winid, {
                relative = "editor",
                row = (opts.row or 1) - 1,
                col = (opts.col or 1) - 1,
                width = w,
                height = h,
                focusable = false,
                style = "minimal",
                zindex = opts.zindex or 50,
            })
        end
    elseif c.kind == "buffer" then
        if c.extmark_id then
            pcall(vim.api.nvim_buf_del_extmark, c.bufnr, NS, c.extmark_id)
        end
        if opts.buf then
            c.bufnr = opts.buf
        end
        c.extmark_id = place_buffer_extmark(opts)
    end
end

---@param provider table
---@param id integer|any
function M.unregister(provider, id)
    local key = provider_key(provider, id)
    local c = carriers[key]
    if not c then
        return
    end
    if c.kind == "editor" and c.winid and vim.api.nvim_win_is_valid(c.winid) then
        pcall(vim.api.nvim_win_close, c.winid, true)
    elseif c.kind == "buffer" and c.extmark_id then
        pcall(vim.api.nvim_buf_del_extmark, c.bufnr, NS, c.extmark_id)
    end
    carriers[key] = nil
end

---@param provider table
---@param id integer|any
---@return alt-img._core.render.Position[]
function M.get_positions(provider, id)
    local c = carriers[provider_key(provider, id)]
    if not c then
        return {}
    end
    return resolve(c)
end

vim.api.nvim_create_autocmd({ "WinClosed" }, {
    group = AUGROUP,
    callback = function(args)
        local closed = tonumber(args.match)
        for k, c in pairs(carriers) do
            if c.winid == closed then
                carriers[k] = nil
            end
        end
    end,
})

return M
