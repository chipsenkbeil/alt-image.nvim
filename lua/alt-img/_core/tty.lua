-- Self-contained terminal-query helpers. Lifted from neovim PR #39489
-- (vim.tty.request) so the plugin does not depend on `vim.tty.*`,
-- which is only present on the fork branch on most builds.
---@class altimg._tty
local M = {}

---Send `payload` to the host terminal and listen for `TermResponse`,
---calling `on_response` for each response. Cleans up after `opts.timeout`
---ms if the callback never returns `true`.
---
---The autocmd is removed when:
---  * `on_response()` returns `true`
---  * the timeout fires (and `opts.on_timeout` is invoked, if given)
---  * the caller explicitly deletes the returned autocmd id
---
---@param payload string Sequence to send via nvim_ui_send. '' = listen only.
---@param opts? { timeout?: integer, on_timeout?: fun(), group?: integer|string }
---       - `timeout` (default 1000) ms to wait, or 0 for never.
---       - `on_timeout` optional fn called when the timeout fires.
---       - `group` augroup for the TermResponse autocmd.
---@param on_response fun(resp: string): boolean? Return true to stop.
---@return integer autocmd_id
function M.query(payload, opts, on_response)
    vim.validate("payload", payload, "string")
    vim.validate("opts", opts, "table", true)
    vim.validate("on_response", on_response, "function")

    opts = opts or {}
    local timeout = opts.timeout or 1000
    local timer ---@type uv.uv_timer_t?
    if timeout > 0 then
        timer = assert(vim.uv.new_timer())
    end

    local id = vim.api.nvim_create_autocmd("TermResponse", {
        group = opts.group,
        nested = true,
        callback = function(ev)
            local stop = on_response(ev.data.sequence)
            if stop and timer and not timer:is_closing() then
                timer:close()
            end
            return stop
        end,
    })

    if payload ~= "" then
        vim.api.nvim_ui_send(payload)
    end

    if timer then
        timer:start(timeout, 0, function()
            vim.schedule(function()
                pcall(vim.api.nvim_del_autocmd, id)
                if opts.on_timeout then
                    opts.on_timeout()
                end
            end)
            if not timer:is_closing() then
                timer:close()
            end
        end)
    end

    return id
end

return M
