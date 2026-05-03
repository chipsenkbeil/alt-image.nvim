-- Background pre-computation of cropped variants for image placements.
--
-- Why this exists:
--   When an image scrolls partially out of view, the carrier's get_pos
--   returns a `src` rect describing the visible sub-image. The provider
--   crops + re-encodes for that exact rect on the first emit and caches
--   the result. The first scroll into a new clip state therefore spends
--   one magick / img2sixel subprocess invocation (10–50 ms typical) — a
--   hiccup the user feels while scrolling.
--
--   This module pre-fills the per-placement crop cache by calling
--   `provider._build_at(id, { src = ... })` for the variants the
--   carrier is likely to ask for, in a background timer that yields
--   between iterations. By the time the user scrolls into one of those
--   states, the cache is warm and the emit path just `term_send`s the
--   pre-built bytes.
--
-- Variations enumerated (vertical-only):
--   * Top crops:    src = { x=0, y=0,        w=W, h=N } for N = 1 .. H-1
--   * Bottom crops: src = { x=0, y=H-N,      w=W, h=N } for N = 1 .. H-1
--
--   Total: 2*(H-1) entries. The full image (h=H) is already cached on
--   the provider's "is_full" fast path and doesn't need a per-src entry.
--
--   Width-clipping (`src.w < W`, image extending past `win_right`) is
--   not enumerated. It's rare, would explode the variation count to
--   O(W*H), and the on-demand encode path still handles it correctly
--   on the first scroll into that state.
--
-- Cache sizing:
--   The provider's per-placement crop cache is a fixed-size LRU
--   (`crop_cache_size`, default 256). For lossless precompute the LRU
--   must hold ≥ 2*(H-1) entries — i.e. images taller than ~128 cells
--   need a larger `crop_cache_size`. Past that limit, precompute still
--   runs but late variants evict early ones, defeating the cache-warm
--   purpose.
--
-- Activity throttle:
--   Each variation runs on the main Lua thread (the provider's
--   `_build_at` calls into pure-Lua decoders / `vim.system():wait()` for
--   magick). To avoid competing with scroll/typing for cycles, the
--   timer callback skips itself if the user has been active within the
--   last `precompute_idle_threshold_ms` milliseconds (CursorMoved,
--   TextChanged, WinScrolled, mode changes, …). The skipped variations
--   retry on the next tick. Set the threshold to 0 to disable
--   throttling.
--
-- Notifications:
--   `vim.g.alt_img.precompute_notify = true` emits a vim.notify on
--   start (with the variation count) and on completion (with elapsed
--   wall time). Useful for diagnosing whether perceived editor lag
--   correlates with background precompute work. Off by default.
--
-- Disable:
--   `vim.g.alt_img.precompute_crops = false` skips scheduling. Existing
--   behaviour (encode-on-demand on first scroll) restored.
--
-- Cancellation:
--   start() cancels any prior precompute for the same (provider, id)
--   before scheduling new work. del() and dim-change paths in the
--   providers call cancel() explicitly.

local _config = require("alt-img._core.config")

local M = {}

-- Active precompute timers, keyed by tostring(provider) .. ":" .. tostring(id).
--
-- Stashed on _G so the table survives `package.loaded[...] = nil` reloads
-- (used heavily in tests). Without this, an old timer's closure holds a
-- stale local `active` reference and keeps firing — the new module's
-- cancel() can't stop it because it operates on a fresh-empty `active`.
-- The stale timer would then keep calling vim.system, hitting whatever
-- mock the current test installed — corrupting subprocess-count
-- assertions in unrelated specs.
local active = _G._altimg_precompute_active or {}
_G._altimg_precompute_active = active

-- Activity tracking: `last_activity_ns` is the result of `vim.uv.hrtime()`
-- at the time of the most recent user-visible event (cursor move, text
-- change, scroll, mode change). The precompute timer compares this
-- against the current time to decide whether to defer the next variation.
local last_activity_ns = 0

local AUGROUP = vim.api.nvim_create_augroup("alt-img.precompute", { clear = true })
vim.api.nvim_create_autocmd({
    "CursorMoved",
    "CursorMovedI",
    "TextChanged",
    "TextChangedI",
    "WinScrolled",
    "ModeChanged",
    "InsertEnter",
    "InsertLeave",
}, {
    group = AUGROUP,
    callback = function()
        last_activity_ns = vim.uv.hrtime()
    end,
})

-- MouseMove deserves a separate hook because (a) it isn't always present
-- in the user's setup (only fires when 'mousemoveevent' is on), and (b)
-- it's the most acutely-affected event when precompute monopolizes the
-- main thread — a stuttering mouse-follow image is the symptom users
-- notice first. Stamp activity on every mouse move so precompute pauses
-- for the duration of a drag.
pcall(vim.api.nvim_create_autocmd, "MouseMove", {
    group = AUGROUP,
    callback = function()
        last_activity_ns = vim.uv.hrtime()
    end,
})

local function key(provider, id)
    return tostring(provider) .. ":" .. tostring(id)
end

local function user_recently_active(threshold_ms)
    if not threshold_ms or threshold_ms <= 0 then
        return false
    end
    if last_activity_ns == 0 then
        return false -- never marked active yet
    end
    local idle_ns = vim.uv.hrtime() - last_activity_ns
    return idle_ns < threshold_ms * 1e6
end

-- Build the list of vertical-only crop variations for an image of (W, H)
-- cells. Exposed for tests; not part of the public API.
function M._enumerate_variations(w, h)
    local out = {}
    if type(w) ~= "number" or type(h) ~= "number" or w < 1 or h < 1 then
        return out
    end
    -- Top crops (image extends past win_bottom — visible portion is the
    -- top N rows): src = { x=0, y=0, w=W, h=N } for N = 1 .. H-1.
    for sh = 1, h - 1 do
        out[#out + 1] = { x = 0, y = 0, w = w, h = sh }
    end
    -- Bottom crops (image partially scrolled above topline via topfill —
    -- visible portion is the bottom N rows): src = { x=0, y=H-N, w=W,
    -- h=N } for N = 1 .. H-1.
    for sh = 1, h - 1 do
        out[#out + 1] = { x = 0, y = h - sh, w = w, h = sh }
    end
    return out
end

---Cancel any active precompute for (provider, id). Safe to call when
---no precompute is scheduled.
---@param provider table
---@param id any
function M.cancel(provider, id)
    local k = key(provider, id)
    local timer = active[k]
    if timer then
        if not timer:is_closing() then
            timer:stop()
            timer:close()
        end
        active[k] = nil
    end
end

---Schedule background precomputation of vertical crop variations for the
---placement at (provider, id) with the given canonical opts (must
---include numeric .width and .height). Cancels any existing precompute
---for this placement first. No-op when:
---  * `vim.g.alt_img.precompute_crops` is false
---  * the provider exposes neither `_precompute_async` nor `_build_at`
---  * opts.width / opts.height is missing or non-numeric
---  * the variation list is empty
---
---When the provider exposes `_precompute_async`, magick subprocesses
---spawn in parallel (up to `precompute_max_concurrent`) and the main
---thread stays free during the wait. Falls back to synchronous
---`_build_at` (one variant per timer tick) when async isn't available
---— mostly the case for non-magick configs where the build path is
---pure-Lua and CPU-bound on the main thread.
---@param provider table provider module (iterm2 / sixel)
---@param id any placement id
---@param opts table canonical opts (with width, height)
function M.start(provider, id, opts)
    M.cancel(provider, id)

    local cfg = _config.read() or {}
    if cfg.precompute_crops == false then
        return
    end
    local has_async = type(provider._precompute_async) == "function"
    local has_sync = type(provider._build_at) == "function"
    if not has_async and not has_sync then
        return
    end

    local variations = M._enumerate_variations(opts and opts.width, opts and opts.height)
    if #variations == 0 then
        return
    end

    local timer = vim.uv.new_timer()
    if not timer then
        return
    end
    active[key(provider, id)] = timer

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
    local max_concurrent = cfg.precompute_max_concurrent
    if type(max_concurrent) ~= "number" or max_concurrent < 1 then
        max_concurrent = 2
    end
    local notify = cfg.precompute_notify == true

    local total = #variations
    local started_ns = vim.uv.hrtime()
    if notify then
        vim.schedule(function()
            vim.notify(
                string.format(
                    "alt-img: precomputing %d crop variants (%s)",
                    total,
                    has_async and "async" or "sync"
                ),
                vim.log.levels.INFO
            )
        end)
    end

    local timer_key = key(provider, id)
    local idx = 1
    local in_flight = 0
    local done_count = 0

    -- `active[timer_key] == timer` is the canonical "still alive" check.
    -- M.cancel and a restart via M.start both replace or clear that
    -- entry, so any callback that fires after cancellation just bows out.
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
                vim.notify(
                    string.format(
                        "alt-img: precompute done (%d variants, %.0f ms wall)",
                        total,
                        elapsed_ms
                    ),
                    vim.log.levels.INFO
                )
            end
        end
    end

    timer:start(
        start_delay_ms,
        interval,
        vim.schedule_wrap(function()
            if active[timer_key] ~= timer then
                return -- cancelled or replaced
            end
            -- Throttle: defer dispatches if the user has been active
            -- recently. In-flight subprocesses keep running in the
            -- background; we just don't start new ones.
            if user_recently_active(idle_threshold_ms) then
                return
            end

            if has_async then
                -- Dispatch up to max_concurrent. Each subprocess runs in
                -- a separate OS process; the main thread is only briefly
                -- busy at dispatch + completion-callback dispatch.
                while in_flight < max_concurrent and idx <= total do
                    local src = variations[idx]
                    idx = idx + 1
                    in_flight = in_flight + 1
                    local ok = pcall(provider._precompute_async, id, src, function()
                        in_flight = in_flight - 1
                        done_count = done_count + 1
                        maybe_finish()
                    end)
                    if not ok then
                        -- pcall swallowed the error before _precompute_async
                        -- registered its callback. Tally manually.
                        in_flight = in_flight - 1
                        done_count = done_count + 1
                        maybe_finish()
                    end
                end
            else
                -- Sync fallback (no async path): one per tick to avoid
                -- long blocks.
                if idx > total then
                    maybe_finish()
                    return
                end
                local src = variations[idx]
                idx = idx + 1
                pcall(provider._build_at, id, { row = 1, col = 1, src = src })
                done_count = done_count + 1
                maybe_finish()
            end
        end)
    )
end

---Test hook: returns true if (provider, id) currently has an active
---precompute timer.
---@param provider table
---@param id any
---@return boolean
function M._is_active(provider, id)
    return active[key(provider, id)] ~= nil
end

---Stop ALL active precompute timers regardless of (provider, id) key.
---Intended for test setup — provider modules are reloaded across
---test specs and stale timer closures (holding a stale provider /
---vim.system reference) would otherwise keep firing during unrelated
---tests and pollute subprocess-count assertions.
function M.cancel_all()
    for k, timer in pairs(active) do
        if timer and not timer:is_closing() then
            timer:stop()
            timer:close()
        end
        active[k] = nil
    end
end

---Test hook: force last_activity_ns to a value. Pass nil/0 to reset.
---@param ns? integer
function M._set_last_activity_ns(ns)
    last_activity_ns = ns or 0
end

return M
