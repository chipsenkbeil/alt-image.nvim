local M = {}

---@type integer
local last_activity_ns = 0

local AUGROUP = vim.api.nvim_create_augroup("alt-img._core.activity", { clear = true })

local function stamp()
    last_activity_ns = vim.uv.hrtime()
end

vim.api.nvim_create_autocmd({
    "CursorMoved",
    "CursorMovedI",
    "TextChanged",
    "TextChangedI",
    "WinScrolled",
    "ModeChanged",
    "InsertEnter",
    "InsertLeave",
}, { group = AUGROUP, callback = stamp })

pcall(vim.api.nvim_create_autocmd, "MouseMove", { group = AUGROUP, callback = stamp })

---Return the hrtime() of the most recent user-visible event, or 0 if none yet.
---@return integer
function M.last_ns()
    return last_activity_ns
end

---True if the user has been active within `threshold_ms` milliseconds.
---Returns false when threshold is 0/nil/negative or no event seen yet.
---@param threshold_ms? number
---@return boolean
function M.recent_within(threshold_ms)
    if not threshold_ms or threshold_ms <= 0 then
        return false
    end
    if last_activity_ns == 0 then
        return false
    end
    return (vim.uv.hrtime() - last_activity_ns) < threshold_ms * 1e6
end

return M
