-- lua/alt-image/init.lua
-- Top-level dispatcher. Detects which protocol the current terminal
-- supports and exposes the same set/get/del/_supported surface so that
--   vim.ui.img = require('alt-image')
-- works identically to vim.ui.img on a kitty-supporting terminal.
--
-- Configuration: see `_core/config.lua`. Users override individual fields via
-- `vim.g.alt_image = { ... }`; defaults are baked into the plugin per the
-- nvim-best-practices "no setup() function required" pattern.

local M = {}

local config = require('alt-image._core.config')

local PROVIDERS = {
  iterm2 = function() return require('alt-image.iterm2') end,
  sixel  = function() return require('alt-image.sixel')  end,
}

local DETECT_ORDER = { 'iterm2', 'sixel' }

local cached_provider = nil

local function detect()
  local proto = config.read().protocol
  if proto ~= 'auto' then
    if not PROVIDERS[proto] then
      error('alt-image: unknown protocol ' .. tostring(proto))
    end
    return PROVIDERS[proto]()
  end
  for _, name in ipairs(DETECT_ORDER) do
    local p = PROVIDERS[name]()
    if p._supported({ timeout = 200 }) then
      return p
    end
  end
  error('alt-image: no supported image protocol detected. '
     .. 'Set vim.ui.img = require("alt-image.iterm2") or .sixel manually, '
     .. 'or set vim.g.alt_image = { protocol = "iterm2" } (or "sixel").')
end

function M._provider()
  cached_provider = cached_provider or detect()
  return cached_provider
end

-- Test helper: clear the cached provider so a subsequent _provider() call
-- redetects from current env / vim.g.alt_image.
function M._reset_provider_cache()
  cached_provider = nil
end

-- Forward the public API. We do this lazily so the provider isn't constructed
-- until first call (avoids running detection at require-time).
function M.set(d, o) return M._provider().set(d, o) end
function M.get(id)   return M._provider().get(id)   end
function M.del(id)   return M._provider().del(id)   end

function M._supported(o)
  local proto = config.read().protocol
  if proto ~= 'auto' then
    if not PROVIDERS[proto] then return false end
    local ok, msg = PROVIDERS[proto]()._supported(o)
    if ok then return true, proto .. ': ' .. (msg or '') end
    return false, proto .. ': not supported'
  end
  for _, name in ipairs(DETECT_ORDER) do
    local p = PROVIDERS[name]()
    local ok, msg = p._supported(o)
    if ok then return true, name .. ': ' .. (msg or '') end
  end
  return false
end

return M
