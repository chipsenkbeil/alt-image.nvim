-- Harness lib: spawn a child nvim, drive it via msgpack-RPC, capture
-- raw UI bytes from nvim_ui_send.
--
-- All observation is black-box from alt-img's perspective: the child
-- nvim runs the unmodified plugin source; only the public vim.ui.img
-- surface plus standard vim.api state inspection drive + observe it.
-- The lone exception is a one-line monkey-patch of vim.api.nvim_ui_send
-- in the child's init (a *test-process* hook, not production), which
-- forwards bytes to a global table for later readback.

local M = {}

---@class test.Nvim
---@field _job_id integer
---@field _chan integer
---@field _sock string
local Nvim = {}
Nvim.__index = Nvim

local INIT_TEMPLATE = [[
vim.opt.runtimepath:prepend(%q)
vim.g.alt_img = %s

-- Test-process hook: capture every nvim_ui_send call into a global table
-- that the harness reads via rpcrequest. Not visible to alt-img source.
_G.__alt_img_test_ui_bytes = {}
do
    local orig = vim.api.nvim_ui_send
    vim.api.nvim_ui_send = function(bytes)
        _G.__alt_img_test_ui_bytes[#_G.__alt_img_test_ui_bytes + 1] = bytes
        return orig(bytes)
    end
end

vim.cmd.source(%q .. "/plugin/alt-img.lua")
vim.ui.img = require(%q)
]]

---Spawn a fresh child nvim and connect via msgpack-RPC.
---@param opts? { config?: table, runtimepath?: string, provider?: string }
---  provider: 'sixel' | 'iterm2' | 'alt-img' (autodetect, default).
---  In a headless child, autodetect can't probe a real terminal, so
---  pin a specific provider for e2e tests via `provider = "sixel"`.
---@return test.Nvim
function M.spawn(opts)
    opts = opts or {}
    local sock = vim.fn.tempname() .. ".sock"
    local rtp = opts.runtimepath or vim.uv.cwd()
    local provider_mod = "alt-img"
    if opts.provider == "sixel" then
        provider_mod = "alt-img.sixel"
    elseif opts.provider == "iterm2" then
        provider_mod = "alt-img.iterm2"
    end
    -- Bypass terminal probes by default so headless tests don't pay
    -- ~600ms of CSI/OSC timeouts. Tests can override either knob.
    local default_config = {
        cell_pixel_size = { 8, 16 },
        sixel_pixel_scale = 2,
    }
    local merged_config = vim.tbl_extend("force", default_config, opts.config or {})
    local init_lua = string.format(INIT_TEMPLATE, rtp, vim.inspect(merged_config), rtp, provider_mod)

    local cmd = {
        "nvim",
        "--headless",
        "--noplugin",
        "-n",
        "--clean",
        "--listen",
        sock,
        "--cmd",
        "lua " .. init_lua,
    }

    local job_id = vim.fn.jobstart(cmd, {
        rpc = false,
        on_stderr = function(_, lines)
            for _, l in ipairs(lines) do
                if l ~= "" then
                    io.stderr:write("[child stderr] " .. l .. "\n")
                end
            end
        end,
    })
    if job_id <= 0 then
        error("harness: jobstart failed (" .. tostring(job_id) .. ")")
    end

    if not vim.wait(3000, function()
        return vim.uv.fs_stat(sock) ~= nil
    end, 20) then
        vim.fn.jobstop(job_id)
        error("harness: child socket never appeared at " .. sock)
    end

    local chan = vim.fn.sockconnect("pipe", sock, { rpc = true })
    if chan == 0 then
        vim.fn.jobstop(job_id)
        error("harness: sockconnect failed for " .. sock)
    end

    return setmetatable({ _job_id = job_id, _chan = chan, _sock = sock }, Nvim)
end

---Run Lua in the child. Args become `select(1, ...)` etc.
---@param code string
function Nvim:lua(code, ...)
    return vim.rpcrequest(self._chan, "nvim_exec_lua", code, { ... })
end

---Run a Lua expression in the child and return its value.
---@param expr string
---@return any
function Nvim:lua_eval(expr)
    return vim.rpcrequest(self._chan, "nvim_exec_lua", "return " .. expr, {})
end

---@param cmd string
function Nvim:command(cmd)
    return vim.rpcrequest(self._chan, "nvim_command", cmd)
end

---@param keys string
function Nvim:input(keys)
    return vim.rpcrequest(self._chan, "nvim_input", keys)
end

---Poll until predicate returns truthy, or timeout.
---@param predicate fun(): any
---@param opts? { timeout_ms?: integer, interval_ms?: integer, msg?: string }
function Nvim:wait_until(predicate, opts)
    opts = opts or {}
    local timeout = opts.timeout_ms or 1000
    local interval = opts.interval_ms or 20
    local deadline = vim.uv.now() + timeout
    while vim.uv.now() < deadline do
        if predicate() then
            return
        end
        vim.wait(interval)
    end
    error("wait_until timed out after " .. timeout .. "ms: " .. (opts.msg or "predicate never became true"), 2)
end

---Concatenate every byte sent via nvim_ui_send in the child since spawn
---(or since reset_captured()).
---@return string
function Nvim:captured_ui_bytes()
    return self:lua_eval("table.concat(_G.__alt_img_test_ui_bytes or {})")
end

function Nvim:reset_captured()
    self:lua("_G.__alt_img_test_ui_bytes = {}")
end

---True iff any extmark across any namespace on any buffer in the child
---has virt_lines containing the placeholder box-drawing characters.
---@return boolean
function Nvim:placeholder_visible_in_buffer()
    return self:lua_eval([[(function()
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_valid(buf) then
                for _, ns in pairs(vim.api.nvim_get_namespaces()) do
                    local ok, marks = pcall(vim.api.nvim_buf_get_extmarks, buf, ns, 0, -1, { details = true })
                    if ok then
                        for _, m in ipairs(marks) do
                            local virt = m[4] and m[4].virt_lines
                            if virt then
                                for _, line in ipairs(virt) do
                                    for _, chunk in ipairs(line) do
                                        local s = chunk[1] or ""
                                        if s:find("╭") or s:find("│") or s:find("⣾")
                                           or s:find("⣽") or s:find("⣻") or s:find("⢿") then
                                            return true
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        return false
    end)()]])
end

---True iff any floating window's buffer contains placeholder glyphs.
---@return boolean
function Nvim:placeholder_visible_in_float()
    return self:lua_eval([[(function()
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            local cfg = vim.api.nvim_win_get_config(win)
            if cfg.relative ~= "" then
                local buf = vim.api.nvim_win_get_buf(win)
                local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
                if ok then
                    for _, l in ipairs(lines) do
                        if l:find("╭") or l:find("⣾") or l:find("⣽")
                           or l:find("⣻") or l:find("⢿") then
                            return true
                        end
                    end
                end
            end
        end
        return false
    end)()]])
end

---Convenience: either source.
---@return boolean
function Nvim:placeholder_visible()
    return self:placeholder_visible_in_buffer() or self:placeholder_visible_in_float()
end

function Nvim:close()
    -- Graceful shutdown: ask the child to :qa! first so it exits with
    -- code 0 instead of catching SIGTERM. The rpcrequest will fail once
    -- the child closes the channel mid-call — that's expected, swallow.
    pcall(vim.rpcrequest, self._chan, "nvim_command", "qa!")
    pcall(vim.fn.chanclose, self._chan)
    -- Wait briefly for the process to exit cleanly; jobstop only if it
    -- didn't oblige.
    if vim.fn.jobwait({ self._job_id }, 500)[1] == -1 then
        pcall(vim.fn.jobstop, self._job_id)
    end
    if self._sock and vim.uv.fs_stat(self._sock) then
        pcall(vim.uv.fs_unlink, self._sock)
    end
end

return M
