-- lua/alt-image/init.lua
-- Top-level dispatcher. Detects which protocol the current terminal
-- supports and exposes the same set/get/del/_supported surface so that
--   vim.ui.img = require('alt-image')
-- works identically to vim.ui.img on a kitty-supporting terminal.

local M = {}

local PROVIDERS = {
  iterm2 = function() return require('alt-image.iterm2') end,
  sixel  = function() return require('alt-image.sixel')  end,
}

local DETECT_ORDER = { 'iterm2', 'sixel' }

local cached_provider = nil
local user_choice = nil

-- Public runtime config. Read by encoder dispatchers in `_sixel_encode` and
-- crop helpers in `sixel.lua` / `iterm2.lua`. Defaults: acceleration on.
M._config = { accelerate = true }

local function detect()
  if user_choice then
    return PROVIDERS[user_choice]()
  end
  for _, name in ipairs(DETECT_ORDER) do
    local p = PROVIDERS[name]()
    if p._supported({ timeout = 200 }) then
      return p
    end
  end
  error('alt-image: no supported image protocol detected. '
     .. 'Set vim.ui.img = require("alt-image.iterm2") or .sixel manually, '
     .. 'or call require("alt-image").setup({ protocol = ... }).')
end

function M._provider()
  cached_provider = cached_provider or detect()
  return cached_provider
end

function M.setup(opts)
  opts = opts or {}
  if opts.protocol then
    if not PROVIDERS[opts.protocol] then
      error('alt-image: unknown protocol ' .. tostring(opts.protocol))
    end
    user_choice = opts.protocol
    cached_provider = PROVIDERS[user_choice]()
  end
  if opts.accelerate ~= nil then
    M._config.accelerate = opts.accelerate and true or false
  end
end

-- Forward the public API. We do this lazily so the provider isn't constructed
-- until first call (avoids running detection at require-time).
function M.set(d, o) return M._provider().set(d, o) end
function M.get(id)   return M._provider().get(id)   end
function M.del(id)   return M._provider().del(id)   end

function M._supported(o)
  if user_choice then
    local ok, msg = PROVIDERS[user_choice]()._supported(o)
    if ok then return true, user_choice .. ': ' .. (msg or '') end
    return false, user_choice .. ': not supported'
  end
  for _, name in ipairs(DETECT_ORDER) do
    local p = PROVIDERS[name]()
    local ok, msg = p._supported(o)
    if ok then return true, name .. ': ' .. (msg or '') end
  end
  return false
end

return M
