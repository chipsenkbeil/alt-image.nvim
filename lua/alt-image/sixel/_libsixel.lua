-- alt-image internal wrapper around libsixel's `img2sixel` CLI.
--
-- Resolves the binary to invoke from `vim.g.alt_image.img2sixel`:
--   - string:   use that exact binary if executable; else nil.
--   - string[]: first candidate that is executable; else nil.
--   - false:    never use img2sixel.
--   - nil / unset: auto-detect by trying `img2sixel`.

local M = {}

local _util = require('alt-image._core.util')

local DEFAULTS = { 'img2sixel' }

---Return the resolved binary name to invoke, or nil if disabled / not found.
---@return string?
function M.binary()
  return _util.resolve_binary((vim.g.alt_image or {}).img2sixel, DEFAULTS)
end

---Run a subprocess synchronously and return stdout on success, nil on fail.
---@param cmd string[]
---@param stdin string
---@return string?
local function run(cmd, stdin)
  local ok, res = pcall(function()
    return vim.system(cmd, { stdin = stdin, text = false }):wait()
  end)
  if not ok or not res or res.code ~= 0 then
    if res and res.stderr and #res.stderr > 0 then
      vim.schedule(function()
        vim.notify_once(
          ('alt-image: %s failed: %s'):format(cmd[1], res.stderr),
          vim.log.levels.DEBUG
        )
      end)
    end
    return nil
  end
  return res.stdout
end

---Pipe PNG bytes into img2sixel and return the sixel DCS string, nil on fail.
---@param png_bytes string
---@param colors integer? max palette size (img2sixel uses --colors / -p)
---@return string?
function M.encode_sixel(png_bytes, colors)
  local bin = M.binary()
  if not bin then return nil end
  local cmd = { bin }
  if colors then
    cmd[#cmd + 1] = '-p'
    cmd[#cmd + 1] = tostring(colors)
  end
  return run(cmd, png_bytes)
end

return M
