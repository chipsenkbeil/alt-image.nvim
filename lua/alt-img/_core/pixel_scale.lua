local M = {}

---@type integer
local scale = 1
---@type boolean
local queried = false
---@type integer
local from_osc1337 = 0
---@type integer
local from_geometry = 0

-- iTerm2 OSC 1337 ReportCellSize reply: `<height>;<width>;<scale>` (points,
-- points, screen scale factor). The scale field is what we want.
---@type table<string, true>
local OSC_1337_TERM_PROGRAMS = {
    ["iTerm.app"] = true,
    ["WezTerm"] = true,
    ["mintty"] = true,
    ["Tabby"] = true,
}

---@return boolean
local function osc1337_likely_supported()
    if vim.env.KONSOLE_VERSION and vim.env.KONSOLE_VERSION ~= "" then
        return true
    end
    return OSC_1337_TERM_PROGRAMS[vim.env.TERM_PROGRAM] == true
end

---@return integer scale 0 if not applicable / no answer; else >= 1
local function query_osc1337()
    if not osc1337_likely_supported() then
        return 0
    end
    local timeout = 500
    local found = 0
    local done = false
    require("alt-img._core.tty").query("\027]1337;ReportCellSize\007", { timeout = timeout }, function(resp)
        local _h, _w, s = (resp or ""):match("ReportCellSize=([%d%.]+);([%d%.]+);([%d%.]+)")
        if s then
            local n = tonumber(s)
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

---CSI 14t (window pixels) ÷ CSI 18t (window chars) ÷ CSI 16t (cell pixels).
---When CSI 14t reports physical and CSI 16t logical, the ratio is the scale.
---@return integer scale 0 if no signal; else >= 1
local function query_geometry()
    require("alt-img._core.cell_size").query()
    local cell_w, cell_h = require("alt-img._core.cell_size").current()
    if not cell_w or cell_w <= 0 or cell_h <= 0 then
        return 0
    end

    -- 200 ms is enough for any terminal that answers CSI 14t/18t at all
    -- (responsive terminals reply in well under 50 ms over a local TTY).
    -- Terminals that don't answer used to cost us 350 ms each here for no
    -- benefit, which dominated first-render latency.
    local timeout = 200
    local win_w, win_h, cols, rows
    local done14, done18 = false, false
    local tty = require("alt-img._core.tty")

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

---Cached terminal pixel scale (1, 2, …). Combines OSC 1337 ReportCellSize
---and CSI 14t/18t × 16t geometry; takes the larger. Cleared on VimResized
---/ UIEnter so the next call re-queries.
---@return integer
function M.current()
    if not queried then
        queried = true
        -- Windows Terminal reports cell pixel sizes already in physical
        -- pixels via CSI 16t; there is no logical/physical scale split to
        -- recover. Skipping the CSI 14t/18t round-trips here avoids ~700ms
        -- of timeout-bound waiting on the first vim.ui.img.set() call,
        -- which dominates first-render latency on Windows.
        if vim.env.WT_SESSION and vim.env.WT_SESSION ~= "" then
            from_osc1337 = 0
            from_geometry = 0
            scale = 1
            return scale
        end
        from_osc1337 = query_osc1337()
        from_geometry = query_geometry()
        scale = math.max(from_osc1337, from_geometry, 1)
    end
    return scale
end

---Per-source scale values for diagnostic surface. Each is 0 when that
---source did not contribute a usable scale.
---@return integer osc1337
---@return integer geometry
function M.sources()
    M.current()
    return from_osc1337, from_geometry
end

local AUGROUP = vim.api.nvim_create_augroup("alt-img.pixel_scale", { clear = true })
vim.api.nvim_create_autocmd({ "VimResized", "UIEnter" }, {
    group = AUGROUP,
    callback = function()
        queried = false
    end,
})

return M
