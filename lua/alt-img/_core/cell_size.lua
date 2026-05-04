local M = {}

-- Defaults when CSI 16t is unavailable: Unix inherits X11/VGA 8x16; Windows
-- Terminal's Cascadia Mono is closer to 10x20. CSI 16t responses supersede.
local default_w, default_h = (function()
    if vim.uv.os_uname().sysname == "Windows_NT" then
        return 10, 20
    end
    return 8, 16
end)()

---@type integer
local cell_w = default_w
---@type integer
local cell_h = default_h
---@type boolean
local queried = false

---Return the cached cell pixel dimensions.
---@return integer width, integer height
function M.current()
    return cell_w, cell_h
end

local function query_csi16t()
    -- 250 ms is enough for any terminal that answers CSI 16t at all; the
    -- defaults above are good fallbacks if the probe times out.
    local timeout = 250
    local done = false
    require("alt-img._core.tty").query("\027[16t", { timeout = timeout }, function(resp)
        local h, w = resp:match("^\027%[6;(%d+);(%d+)t$")
        if h and w then
            local new_w, new_h = tonumber(w), tonumber(h)
            if new_w and new_h and new_w > 0 and new_h > 0 then
                cell_w, cell_h = new_w, new_h
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

---Synchronously query the terminal for cell pixel dimensions via CSI 16t.
---Cached; cleared on VimResized / UIEnter so the next call re-queries.
function M.query()
    if queried then
        return
    end
    queried = true
    query_csi16t()
end

local AUGROUP = vim.api.nvim_create_augroup("alt-img.cell_size", { clear = true })
vim.api.nvim_create_autocmd({ "VimResized", "UIEnter" }, {
    group = AUGROUP,
    callback = function()
        queried = false
    end,
})

return M
