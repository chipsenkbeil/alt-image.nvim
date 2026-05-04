local M = {}

---@param bin string
---@param stderr string
local function notify_failure(bin, stderr)
    if stderr and #stderr > 0 then
        vim.schedule(function()
            vim.notify_once(("alt-img: %s failed: %s"):format(bin, stderr), vim.log.levels.DEBUG)
        end)
    end
end

---Run a subprocess synchronously and return stdout on success, nil on fail.
---Surfaces stderr once via vim.notify_once on failure.
---@param cmd string[]
---@param stdin string
---@return string? stdout
function M.run(cmd, stdin)
    local ok, res = pcall(function()
        return vim.system(cmd, { stdin = stdin, text = false }):wait()
    end)
    if not ok or not res or res.code ~= 0 then
        if res then
            notify_failure(cmd[1], res.stderr)
        end
        return nil
    end
    return res.stdout
end

---Run a subprocess asynchronously. Invokes `on_done(stdout|nil)` from the main
---loop when the subprocess exits.
---@param cmd string[]
---@param stdin string
---@param on_done fun(stdout: string?)
function M.run_async(cmd, stdin, on_done)
    local ok = pcall(function()
        vim.system(cmd, { stdin = stdin, text = false }, function(obj)
            if obj.code ~= 0 or not obj.stdout or #obj.stdout == 0 then
                notify_failure(cmd[1], obj.stderr)
                on_done(nil)
            else
                on_done(obj.stdout)
            end
        end)
    end)
    if not ok then
        on_done(nil)
    end
end

return M
