local M = {}

---@type table<string, vim.uv.Timer>
local active = {}

---Cap on parallel async magick spawns. ImageMagick is internally
---multi-threaded (one process already uses ~nproc threads), so two
---parallel spawns hide one process's startup behind the other's compute
---without doubling thread pressure beyond what the OS handles cleanly.
---On a single-core box, drop to one to avoid head-of-line blocking.
---@return integer
local function default_max_concurrent()
    local n = vim.uv.available_parallelism()
    if not n or n <= 1 then
        return 1
    end
    return 2
end

---@param token any
---@param id integer|any
---@return string
local function key(token, id)
    return tostring(token) .. ":" .. tostring(id)
end

---@class alt-img._core.precompute.Variation
---@field x integer left edge of the crop (always 0 for vertical-only crops)
---@field y integer top edge of the crop in cell rows
---@field w integer width of the crop in cells
---@field h integer height of the crop in cells

---Vertical-only crop variations for an image of (W, H) cells: top crops
---{x=0,y=0,w=W,h=N} and bottom crops {x=0,y=H-N,w=W,h=N} for N=1..H-1.
---@param w integer
---@param h integer
---@return alt-img._core.precompute.Variation[]
local function enumerate_variations(w, h)
    local out = {}
    if type(w) ~= "number" or type(h) ~= "number" or w < 1 or h < 1 then
        return out
    end
    for sh = 1, h - 1 do
        out[#out + 1] = { x = 0, y = 0, w = w, h = sh }
    end
    for sh = 1, h - 1 do
        out[#out + 1] = { x = 0, y = h - sh, w = w, h = sh }
    end
    return out
end

---LRU capacity needed to hold the precompute output for a placement of
---`opts.height` cells. `2 * (h - 1)` is the exact variant count; floor at
---64 so tiny placements still absorb a few one-off viewport-clip crops.
---@param opts? { height?: integer }
---@return integer
function M.required_lru_size(opts)
    local h = opts and opts.height or 0
    if type(h) ~= "number" or h < 1 then
        h = 1
    end
    return math.max(64, 2 * (h - 1))
end

---Cancel any active precompute for (token, id). Safe to call when
---no precompute is scheduled.
---@param token any opaque identity
---@param id integer
function M.cancel(token, id)
    local k = key(token, id)
    local timer = active[k]
    if timer then
        if not timer:is_closing() then
            timer:stop()
            timer:close()
        end
        active[k] = nil
    end
end

---Schedule background precompute of vertical crop variations. Cancels any
---prior precompute for this (token, id) first. No-op when
---`precompute_crops` is false, opts is missing dims, the variation list is
---empty, or callbacks exposes neither `precompute_async` nor `build_at`.
---Async path runs up to `default_max_concurrent()` magick subprocesses in
---parallel (auto-derived from `vim.uv.available_parallelism()`); sync
---fallback runs one variant per tick.
---@param token any opaque identity (matches what render.register received)
---@param id integer placement id
---@param opts table canonical opts (with width, height)
---@param callbacks { build_at?: fun(id: integer, pos: table): string?, precompute_async?: fun(id: integer, src: table, on_done: fun()) }
function M.start(token, id, opts, callbacks)
    M.cancel(token, id)
    callbacks = callbacks or {}

    local cfg = require("alt-img._core.config").read() or {}
    if cfg.precompute_crops == false then
        return
    end
    local has_async = type(callbacks.precompute_async) == "function"
    local has_sync = type(callbacks.build_at) == "function"
    if not has_async and not has_sync then
        return
    end

    local variations = enumerate_variations(opts and opts.width, opts and opts.height)
    if #variations == 0 then
        return
    end

    local timer = vim.uv.new_timer()
    if not timer then
        return
    end
    active[key(token, id)] = timer

    local interval = cfg.precompute_interval_ms
    if type(interval) ~= "number" or interval < 1 then
        interval = 30
    end
    local start_delay_ms = cfg.precompute_start_delay_ms
    if type(start_delay_ms) ~= "number" or start_delay_ms < 0 then
        start_delay_ms = 500
    end
    local idle_threshold_ms = cfg.precompute_idle_threshold_ms
    if type(idle_threshold_ms) ~= "number" or idle_threshold_ms < 0 then
        idle_threshold_ms = 500
    end
    local max_concurrent = default_max_concurrent()
    local notify = cfg.precompute_notify == true

    local total = #variations
    local started_ns = vim.uv.hrtime()
    if notify then
        vim.notify(
            string.format("alt-img: precomputing %d crop variants (%s)", total, has_async and "async" or "sync"),
            vim.log.levels.INFO
        )
    end

    local timer_key = key(token, id)
    local idx = 1
    local in_flight = 0
    local done_count = 0

    -- `active[timer_key] == timer` is the "still alive" check; M.cancel and
    -- a restart via M.start both invalidate it so post-cancel callbacks bow out.
    local function maybe_finish()
        if active[timer_key] ~= timer then
            return
        end
        if done_count >= total then
            if not timer:is_closing() then
                timer:stop()
                timer:close()
            end
            active[timer_key] = nil
            if notify then
                local elapsed_ms = (vim.uv.hrtime() - started_ns) / 1e6
                local function do_notify()
                    vim.notify(
                        string.format("alt-img: precompute done (%d variants, %.0f ms wall)", total, elapsed_ms),
                        vim.log.levels.INFO
                    )
                end
                -- vim.notify from a fast-event ctx errors via nvim_echo.
                if vim.in_fast_event() then
                    vim.schedule(do_notify)
                else
                    do_notify()
                end
            end
        end
    end

    timer:start(
        start_delay_ms,
        interval,
        vim.schedule_wrap(function()
            if active[timer_key] ~= timer then
                return
            end
            if require("alt-img._core.activity").recent_within(idle_threshold_ms) then
                return
            end

            if has_async then
                while in_flight < max_concurrent and idx <= total do
                    local src = variations[idx]
                    idx = idx + 1
                    in_flight = in_flight + 1
                    local ok = pcall(callbacks.precompute_async, id, src, function()
                        in_flight = in_flight - 1
                        done_count = done_count + 1
                        maybe_finish()
                    end)
                    if not ok then
                        in_flight = in_flight - 1
                        done_count = done_count + 1
                        maybe_finish()
                    end
                end
            else
                if idx > total then
                    maybe_finish()
                    return
                end
                local src = variations[idx]
                idx = idx + 1
                pcall(callbacks.build_at, id, { row = 1, col = 1, src = src })
                done_count = done_count + 1
                maybe_finish()
            end
        end)
    )
end

return M
