local M = {}

---@class alt-img._core.cache.Config
---@field enabled boolean
---@field dir string  resolved absolute path
---@field max_bytes integer
---@field max_age_days integer? nil = no age cap

---@type boolean? per-process disable, set by M.disable()
local proc_disabled = nil

---Resolve effective config: vim.g.alt_img.cache merged onto defaults, with
---the per-process disable flag applied.
---@return alt-img._core.cache.Config
local function read_config()
    local g = (vim.g.alt_img and vim.g.alt_img.cache) or {}
    local enabled = g.enabled
    if enabled == nil then
        enabled = true
    end
    if proc_disabled then
        enabled = false
    end
    local dir = g.dir
    if type(dir) ~= "string" or dir == "" then
        dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "alt-img")
    end
    local max_bytes = (type(g.max_bytes) == "number" and g.max_bytes > 0) and g.max_bytes or (500 * 1024 * 1024)
    local max_age_days = (type(g.max_age_days) == "number" and g.max_age_days >= 0) and g.max_age_days or nil
    return {
        enabled = enabled and true or false,
        dir = dir,
        max_bytes = max_bytes,
        max_age_days = max_age_days,
    }
end

---@return string absolute cache directory (may not exist yet)
function M.path()
    return read_config().dir
end

---@return boolean
function M.is_enabled()
    return read_config().enabled
end

---Disable the cache for this nvim process only. Doesn't touch config or
---on-disk state. Survives until the process exits or M.enable() is called.
function M.disable()
    proc_disabled = true
end

function M.enable()
    proc_disabled = nil
end

---Hash the (input-sha, target-dims, crop-rect) tuple to a fixed-length hex
---filename stem. Encoder choice is intentionally NOT in the key — cached
---DCS / PNG output is valid regardless of which encoder produced it; the
---read side blindly trusts what's there.
---@param input_sha string sha256 hex of the input PNG bytes
---@param target_w integer pixel width of the resized full image
---@param target_h integer pixel height of the resized full image
---@param crop_rect string "full" or "x,y,w,h" (pixel coords after scale)
---@return string  64 hex chars
function M.key(input_sha, target_w, target_h, crop_rect)
    return vim.fn.sha256(string.format("%s|%dx%d|%s", input_sha, target_w, target_h, crop_rect))
end

---@param dir string
local function mkdir_p(dir)
    if vim.uv.fs_stat(dir) then
        return
    end
    local parent = vim.fs.dirname(dir)
    if parent and parent ~= dir and parent ~= "" then
        mkdir_p(parent)
    end
    pcall(vim.uv.fs_mkdir, dir, 493) -- 0755
end

---Read a cache entry. Returns nil on miss, on age-cap expiry, or on any
---I/O error (cache misses are silent — callers always have a fallback).
---@param key string filename stem returned by M.key
---@param ext string ".sixel" or ".png"
---@return string?
function M.lookup(key, ext)
    local cfg = read_config()
    if not cfg.enabled then
        return nil
    end
    local path = vim.fs.joinpath(cfg.dir, key .. ext)
    local stat = vim.uv.fs_stat(path)
    if not stat then
        return nil
    end
    if cfg.max_age_days then
        local age_s = os.time() - (stat.mtime.sec or 0)
        if age_s > cfg.max_age_days * 86400 then
            pcall(vim.uv.fs_unlink, path)
            return nil
        end
    end
    local fd = vim.uv.fs_open(path, "r", 0)
    if not fd then
        return nil
    end
    local data = vim.uv.fs_read(fd, stat.size or 0, 0)
    vim.uv.fs_close(fd)
    return data
end

---Iterate cache directory once; returns { path, mtime, size } per file.
---@param dir string
---@return { path: string, mtime: integer, size: integer }[]
local function scan(dir)
    local out = {}
    local h = vim.uv.fs_scandir(dir)
    if not h then
        return out
    end
    while true do
        local name, ftype = vim.uv.fs_scandir_next(h)
        if not name then
            break
        end
        if ftype ~= "directory" then
            local path = vim.fs.joinpath(dir, name)
            local stat = vim.uv.fs_stat(path)
            if stat then
                out[#out + 1] = { path = path, mtime = stat.mtime.sec or 0, size = stat.size or 0 }
            end
        end
    end
    return out
end

---Lazy LRU eviction by mtime. Called after every successful write — only
---walks the dir when total exceeds the cap.
---@param cfg alt-img._core.cache.Config
local function maybe_evict(cfg)
    local entries = scan(cfg.dir)
    local total = 0
    for _, e in ipairs(entries) do
        total = total + e.size
    end
    if total <= cfg.max_bytes then
        return
    end
    table.sort(entries, function(a, b)
        return a.mtime < b.mtime
    end)
    for _, e in ipairs(entries) do
        if total <= cfg.max_bytes then
            break
        end
        if vim.uv.fs_unlink(e.path) then
            total = total - e.size
        end
    end
end

---Write an entry atomically (tmp + rename). Silent no-op on disabled cache,
---empty data, or any I/O failure (the codec already has the bytes in memory).
---@param key string
---@param ext string
---@param data string
function M.store(key, ext, data)
    local cfg = read_config()
    if not cfg.enabled then
        return
    end
    if not data or #data == 0 then
        return
    end
    mkdir_p(cfg.dir)
    local final = vim.fs.joinpath(cfg.dir, key .. ext)
    local tmp = final .. "." .. tostring(vim.uv.os_getpid and vim.uv.os_getpid() or "tmp") .. ".tmp"
    local fd = vim.uv.fs_open(tmp, "w", 420) -- 0644
    if not fd then
        return
    end
    local ok = pcall(vim.uv.fs_write, fd, data, 0)
    vim.uv.fs_close(fd)
    if not ok then
        pcall(vim.uv.fs_unlink, tmp)
        return
    end
    -- libuv's fs_rename uses MoveFileEx with REPLACE_EXISTING on Windows
    -- (libuv ≥ 1.16) and rename(2) on POSIX. If it ever fails on a target
    -- that already exists, unlink-then-rename is the documented fallback.
    if not pcall(vim.uv.fs_rename, tmp, final) then
        pcall(vim.uv.fs_unlink, final)
        if not pcall(vim.uv.fs_rename, tmp, final) then
            pcall(vim.uv.fs_unlink, tmp)
            return
        end
    end
    maybe_evict(cfg)
end

---@return { entries: integer, bytes: integer, dir: string }
function M.stats()
    local cfg = read_config()
    local entries = scan(cfg.dir)
    local bytes = 0
    for _, e in ipairs(entries) do
        bytes = bytes + e.size
    end
    return { entries = #entries, bytes = bytes, dir = cfg.dir }
end

---Clear the cache. Pass `older_than_days` to keep recent entries.
---@param opts? { older_than_days?: integer }
---@return { entries_removed: integer, bytes_removed: integer }
function M.clear(opts)
    opts = opts or {}
    local cfg = read_config()
    local entries = scan(cfg.dir)
    local removed, bytes_removed = 0, 0
    local cutoff = nil
    if type(opts.older_than_days) == "number" and opts.older_than_days >= 0 then
        cutoff = os.time() - opts.older_than_days * 86400
    end
    for _, e in ipairs(entries) do
        if not cutoff or e.mtime < cutoff then
            if vim.uv.fs_unlink(e.path) then
                removed = removed + 1
                bytes_removed = bytes_removed + e.size
            end
        end
    end
    return { entries_removed = removed, bytes_removed = bytes_removed }
end

---Hex sha256 of the input PNG bytes for a placement, memoized on
---`s.codec_state`. Re-computed after `codec.invalidate(s)` clears the
---scratch table — sha256 over a few hundred KB is sub-millisecond.
---@param s alt-img._core.provider.State
---@return string  64 hex chars
function M.input_sha(s)
    local cs = s.codec_state
    if not cs.input_sha then
        cs.input_sha = vim.fn.sha256(s.data)
    end
    return cs.input_sha
end

return M
