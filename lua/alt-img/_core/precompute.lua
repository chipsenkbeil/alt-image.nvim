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
local active = {}

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
---  * the provider doesn't expose `_build_at`
---  * opts.width / opts.height is missing or non-numeric
---  * the variation list is empty
---@param provider table provider module (iterm2 / sixel)
---@param id any placement id
---@param opts table canonical opts (with width, height)
function M.start(provider, id, opts)
    M.cancel(provider, id)

    local cfg = _config.read() or {}
    if cfg.precompute_crops == false then
        return
    end
    if type(provider._build_at) ~= "function" then
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
    local idle_threshold_ms = cfg.precompute_idle_threshold_ms
    if type(idle_threshold_ms) ~= "number" or idle_threshold_ms < 0 then
        idle_threshold_ms = 200
    end
    local notify = cfg.precompute_notify == true

    local total = #variations
    local started_ns = vim.uv.hrtime()
    if notify then
        vim.schedule(function()
            vim.notify(
                string.format("alt-img: precomputing %d crop variants", total),
                vim.log.levels.INFO
            )
        end)
    end

    local idx = 1
    timer:start(
        interval,
        interval,
        vim.schedule_wrap(function()
            if idx > #variations then
                M.cancel(provider, id)
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
                return
            end
            -- Provider may have been removed under us (test reload, del
            -- without explicit cancel). Stop quietly.
            if type(provider._build_at) ~= "function" then
                M.cancel(provider, id)
                return
            end
            -- Throttle: defer if the user has been active recently. The
            -- variation gets retried on the next timer tick.
            if user_recently_active(idle_threshold_ms) then
                return
            end
            local src = variations[idx]
            idx = idx + 1
            -- pcall: a build error for one variation must not poison the
            -- timer or block subsequent variations.
            pcall(provider._build_at, id, { row = 1, col = 1, src = src })
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

---Test hook: force last_activity_ns to a value. Pass nil/0 to reset.
---@param ns? integer
function M._set_last_activity_ns(ns)
    last_activity_ns = ns or 0
end

return M
