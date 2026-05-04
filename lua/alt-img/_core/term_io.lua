local M = {}

---Send raw bytes to the terminal via nvim_ui_send. tmux is NOT supported in
---this version (see README); inside tmux escapes reach tmux unwrapped and
---will likely be garbled or eaten.
---@param data string
function M.send(data)
    vim.api.nvim_ui_send(data)
end

return M
