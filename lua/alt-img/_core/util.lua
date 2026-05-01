-- alt-img internal utilities
-- Ported from chipsenkbeil/neovim:feat/MoreImgProviders
--   runtime/lua/vim/ui/img/_util.lua

local tty = require("alt-img._core.tty")

-- Cell pixel-size fallback defaults, used only when the CSI 16t query
-- fails to elicit a response. Unix terminals inherit the X11/VGA 8x16
-- fixed-font convention; Windows Terminal's Cascadia Mono ~12pt is
-- closer to 10x20. Modern terminals respond to CSI 16t and the queried
-- value supersedes these immediately.
local _default_w, _default_h = (function()
    if vim.uv.os_uname().sysname == "Windows_NT" then
        return 10, 20
    end
    return 8, 16
end)()

---@class altimg._util
---@field private _cell_width_px integer
---@field private _cell_height_px integer
---@field private _cell_size_queried boolean
---@field private _on_cell_size_change? fun(w: integer, h: integer)
local M = {
    _cell_width_px = _default_w,
    _cell_height_px = _default_h,
    _cell_size_queried = false,
    _on_cell_size_change = nil,
}

---Clip an image footprint at (anchor_row, anchor_col) of size (w, h) cells
---against rectangular bounds. Returns nil if entirely outside; otherwise a
---position record `{ row, col, src = { x, y, w, h } }`.
---
---All inputs in 1-indexed terminal cells.
---@param anchor_row integer
---@param anchor_col integer
---@param w integer
---@param h integer
---@param b_top integer
---@param b_left integer
---@param b_bottom integer
---@param b_right integer
---@return {row:integer, col:integer, src:{x:integer,y:integer,w:integer,h:integer}}|nil
function M.clip_to_bounds(anchor_row, anchor_col, w, h, b_top, b_left, b_bottom, b_right)
    local image_top = anchor_row
    local image_bottom = anchor_row + h - 1
    local image_left = anchor_col
    local image_right = anchor_col + w - 1
    local v_top = math.max(image_top, b_top)
    local v_bottom = math.min(image_bottom, b_bottom)
    local v_left = math.max(image_left, b_left)
    local v_right = math.min(image_right, b_right)
    if v_top > v_bottom or v_left > v_right then
        return nil
    end
    return {
        row = v_top,
        col = v_left,
        src = {
            x = v_left - image_left,
            y = v_top - image_top,
            w = v_right - v_left + 1,
            h = v_bottom - v_top + 1,
        },
    }
end

---Check if image data is PNG format.
---@param data string
---@return boolean
function M.is_png_data(data)
    ---PNG magic number for format validation
    local PNG_SIGNATURE = "\137PNG\r\n\26\n"

    return data and data:sub(1, #PNG_SIGNATURE) == PNG_SIGNATURE
end

---Parse pixel dimensions from a PNG IHDR chunk. Returns nil on invalid input.
---PNG layout: 8-byte signature, 4-byte chunk length, 4-byte chunk type ("IHDR"),
---4-byte BE uint32 width, 4-byte BE uint32 height. Bytes 17..20 are width and
---bytes 21..24 are height (1-indexed).
---@param data string raw image bytes
---@return integer? width_px
---@return integer? height_px
function M.png_dimensions(data)
    if not M.is_png_data(data) then
        return nil, nil
    end
    if #data < 24 then
        return nil, nil
    end
    local function be32(off)
        return string.byte(data, off) * 0x1000000
            + string.byte(data, off + 1) * 0x10000
            + string.byte(data, off + 2) * 0x100
            + string.byte(data, off + 3)
    end
    return be32(17), be32(21)
end

---Check if running in remote environment (SSH).
---@return boolean
function M.is_remote()
    return vim.env.SSH_CLIENT ~= nil or vim.env.SSH_CONNECTION ~= nil
end

---Send data to terminal using nvim_ui_send.
---tmux is NOT supported in this version (see README). Inside tmux, escape
---sequences will reach tmux unwrapped and likely be garbled or eaten.
---@param data string
function M.term_send(data)
    vim.api.nvim_ui_send(data)
end

---Load image data from file synchronously
---@return string data
function M.load_image_data(file)
    local fd, stat_err = vim.uv.fs_open(file, "r", 0)
    if not fd then
        error("failed to open file: " .. (stat_err or "unknown error"))
    end

    local stat = vim.uv.fs_fstat(fd)
    if not stat then
        vim.uv.fs_close(fd)
        error("failed to get file stats")
    end

    local data = vim.uv.fs_read(fd, stat.size, 0)
    vim.uv.fs_close(fd)

    if not data then
        error("failed to read file data")
    end

    return data
end

---Return the cached cell pixel dimensions.
---@return integer width, integer height
function M.cell_pixel_size()
    return M._cell_width_px, M._cell_height_px
end

---Query the terminal for cell pixel dimensions via CSI 16t.
---Synchronously waits up to 500ms for the response. Updates cached
---values on success; on failure (no response, terminal does not
---support CSI 16t) the platform defaults remain.
---@private
function M._query_cell_size_csi16t()
    local timeout = 500
    local done = false
    tty.query("\027[16t", { timeout = timeout }, function(resp)
        -- Response: ESC [ 6 ; <height_px> ; <width_px> t
        local h, w = resp:match("^\027%[6;(%d+);(%d+)t$")
        if h and w then
            local new_w, new_h = tonumber(w), tonumber(h)
            if new_w and new_h and new_w > 0 and new_h > 0 then
                local changed = new_w ~= M._cell_width_px or new_h ~= M._cell_height_px
                M._cell_width_px = new_w
                M._cell_height_px = new_h
                if changed and M._on_cell_size_change then
                    M._on_cell_size_change(new_w, new_h)
                end
            end
            done = true
            return true
        end
        return false
    end)
    vim.wait(timeout + 100, function()
        return done
    end)
end

---Query the terminal for cell pixel dimensions (synchronous via CSI 16t).
---Values are available immediately after this call. Cache is invalidated
---on VimResized and UIEnter so the next call re-queries.
function M.query_cell_size()
    if M._cell_size_queried then
        return
    end
    M._cell_size_queried = true
    M._query_cell_size_csi16t()
end

-- Sixel pixel-scale tracking. Some terminals (iTerm2, WezTerm, …) report
-- cell sizes in LOGICAL pixels via CSI 16t but render sixel at PHYSICAL
-- pixels — so a sixel encoded at the cell pixel size renders at half
-- the requested area on a 2x retina display. We derive a scale factor
-- two ways and take the larger:
--
--   1. OSC 1337 ; ReportCellSize  — iTerm2/WezTerm reply with the screen
--      scale factor as the third field. Definitive when the terminal
--      supports it.
--   2. CSI 14t / CSI 18t / CSI 16t — same trick chafa uses. When CSI 14t
--      is reported in PHYSICAL pixels but CSI 16t in LOGICAL (foot,
--      mlterm on HiDPI X11/Wayland), the ratio reveals the scale.
--      Stays at 1 on terminals that report consistently — including
--      iTerm2/WezTerm, which is why we need (1) for them.
M._terminal_pixel_scale = 1
M._terminal_pixel_scale_queried = false
-- Per-source scale values for diagnostic surface. Either may be 0 to
-- mean "no answer / not applicable on this terminal".
M._scale_from_osc1337 = 0
M._scale_from_geometry = 0

-- Terminals known to implement iTerm2's `OSC 1337 ; ReportCellSize`. Reply
-- format is `<height>;<width>;<scale>` where height/width are in POINTS
-- (logical pixels) and scale is the screen scale factor — what we want.
-- Sources: iTerm2 docs (origin), WezTerm docs (full IIP compat),
-- Mintty/Konsole/Tabby (IIP support).
local OSC_1337_REPORT_CELL_SIZE_TERM_PROGRAMS = {
    ["iTerm.app"] = true,
    ["WezTerm"] = true,
    ["mintty"] = true,
    ["Tabby"] = true,
}

---@private
---@return boolean
local function osc1337_terminal_likely_supported()
    -- Konsole doesn't always set TERM_PROGRAM but does set KONSOLE_VERSION.
    if vim.env.KONSOLE_VERSION and vim.env.KONSOLE_VERSION ~= "" then
        return true
    end
    return OSC_1337_REPORT_CELL_SIZE_TERM_PROGRAMS[vim.env.TERM_PROGRAM] == true
end

---@private
---@return integer scale 0 if not applicable / no answer; otherwise >= 1
function M._query_scale_osc1337()
    if not osc1337_terminal_likely_supported() then
        return 0
    end
    local timeout = 500
    local found = 0
    local done = false
    tty.query("\027]1337;ReportCellSize\007", { timeout = timeout }, function(resp)
        local _h, _w, scale = (resp or ""):match("ReportCellSize=([%d%.]+);([%d%.]+);([%d%.]+)")
        if scale then
            local n = tonumber(scale)
            if n and n >= 1 then
                found = math.floor(n)
            end
            done = true
            return true
        end
        return false
    end)
    vim.wait(timeout + 100, function()
        return done
    end)
    return found
end

---CSI 14t (window in pixels) ÷ CSI 18t (window in chars) ÷ CSI 16t (cell
---pixels). When the terminal reports CSI 14t physical and CSI 16t logical,
---the ratio is the scale. When everything agrees, returns 0 (no scale
---required from this signal).
---@private
---@return integer scale 0 if no signal; otherwise >= 1
function M._query_scale_geometry_xtwinops()
    M.query_cell_size()
    local cell_w, cell_h = M.cell_pixel_size()
    if not cell_w or cell_w <= 0 or cell_h <= 0 then
        return 0
    end

    local timeout = 300
    local win_w, win_h, cols, rows
    local done14, done18 = false, false

    tty.query("\027[14t", { timeout = timeout }, function(resp)
        local h, w = (resp or ""):match("^\027%[4;(%d+);(%d+)t$")
        if h and w then
            win_h, win_w = tonumber(h), tonumber(w)
            done14 = true
            return true
        end
        return false
    end)
    vim.wait(timeout + 50, function()
        return done14
    end)
    if not (win_w and win_h) then
        return 0
    end

    tty.query("\027[18t", { timeout = timeout }, function(resp)
        local r, c = (resp or ""):match("^\027%[8;(%d+);(%d+)t$")
        if r and c then
            rows, cols = tonumber(r), tonumber(c)
            done18 = true
            return true
        end
        return false
    end)
    vim.wait(timeout + 50, function()
        return done18
    end)
    if not (cols and rows and cols > 0 and rows > 0) then
        return 0
    end

    local derived_w = win_w / cols
    local derived_h = win_h / rows
    local ratio = math.min(derived_w / cell_w, derived_h / cell_h)
    if ratio >= 1.5 then
        return math.max(1, math.floor(ratio + 0.5))
    end
    return 0
end

---Return the cached terminal pixel scale factor (1, 2, …). Combines
---OSC 1337 ReportCellSize (iTerm2/WezTerm) and CSI 14t/18t × 16t
---geometry; takes the larger. Caches until VimResized/UIEnter invalidates.
---@return integer
function M.terminal_pixel_scale()
    if not M._terminal_pixel_scale_queried then
        M._terminal_pixel_scale_queried = true
        M._scale_from_osc1337 = M._query_scale_osc1337()
        M._scale_from_geometry = M._query_scale_geometry_xtwinops()
        local best = math.max(M._scale_from_osc1337, M._scale_from_geometry, 1)
        M._terminal_pixel_scale = best
    end
    return M._terminal_pixel_scale
end

---Return the per-source scale values (for diagnostic surface). Each is
---0 when the source did not contribute a usable scale.
---@return integer osc1337 0 = not applicable / no answer
---@return integer geometry 0 = no signal
function M.terminal_pixel_scale_sources()
    -- Drive a query if it hasn't fired yet so this returns meaningful values.
    M.terminal_pixel_scale()
    return M._scale_from_osc1337, M._scale_from_geometry
end

-- Invalidate the cache on resize / UI re-attach. The augroup pattern
-- with `clear = true` keeps reloads (tests, :Lazy reload) from stacking
-- duplicate handlers.
local AUGROUP = vim.api.nvim_create_augroup("alt-img.util", { clear = true })
vim.api.nvim_create_autocmd({ "VimResized", "UIEnter" }, {
    group = AUGROUP,
    callback = function()
        M._cell_size_queried = false
        M._terminal_pixel_scale_queried = false
    end,
})

-- Cached executable lookups for external tools (magick, convert, img2sixel).
-- The cache survives the life of the Neovim session; tests that mock
-- `vim.fn.executable` call `_reset_executable_cache()` to invalidate it.
local _executable_cache = {}

---Return true if `name` is on $PATH, caching the result.
---@param name string
---@return boolean
function M._executable(name)
    if _executable_cache[name] == nil then
        _executable_cache[name] = vim.fn.executable(name) == 1
    end
    return _executable_cache[name]
end

---Reset the cached executable lookups (test hook).
function M._reset_executable_cache()
    for k in pairs(_executable_cache) do
        _executable_cache[k] = nil
    end
end

---Resolve a config value to a binary name we should invoke, or nil if none
---is usable. Pure function — defaults belong in `_core/config.lua`, not here.
---
---Accepted shapes:
---  - falsy (`false` / `nil`) → returns nil (tool path disabled).
---  - `string`                → that exact binary if executable, else nil.
---  - `string[]`              → first candidate that is executable, else nil.
---
---@param cfg string|string[]|false|nil
---@return string?
function M.resolve_binary(cfg)
    if not cfg then
        return nil
    end
    if type(cfg) == "string" then
        return M._executable(cfg) and cfg or nil
    end
    if type(cfg) == "table" then
        for _, name in ipairs(cfg) do
            if M._executable(name) then
                return name
            end
        end
    end
    return nil
end

M.generate_id = (function()
    local bit = require("bit")
    local NVIM_PID_BITS = 10

    local nvim_pid = 0
    local cnt = 30

    ---Generate unique ID for this Neovim instance
    ---@return integer id
    return function()
        -- Generate a unique ID for this nvim instance (10 bits)
        if nvim_pid == 0 then
            local pid = vim.fn.getpid()
            nvim_pid = bit.band(bit.bxor(pid, bit.rshift(pid, 5), bit.rshift(pid, NVIM_PID_BITS)), 0x3FF)
        end

        cnt = cnt + 1
        return bit.bor(bit.lshift(nvim_pid, 24 - NVIM_PID_BITS), cnt)
    end
end)()

return M
