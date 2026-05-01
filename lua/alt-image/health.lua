-- :checkhealth alt-image
-- Top-level report. Probes both protocols (iterm2, sixel) so the user can see
-- at a glance which ones the current terminal can render. Drill-down checks
-- `:checkhealth alt-image.iterm2` and `:checkhealth alt-image.sixel` print
-- the same per-protocol detail in isolation.
local M = {}

local PROTOCOLS = { 'iterm2', 'sixel' }

local function active_provider_line(h)
  local mod    = require('alt-image')
  local config = require('alt-image._core.config')
  local proto  = config.read().protocol

  if proto ~= 'auto' then
    h.ok(string.format('Active provider: %s (forced via vim.g.alt_image.protocol)', proto))
    return
  end

  -- protocol is 'auto'. Run detection to report what _provider() picks.
  -- Wrap in pcall: if no terminal supports either, _provider() throws.
  local ok, p = pcall(mod._provider)
  if ok then
    local name
    for _, n in ipairs(PROTOCOLS) do
      if p == require('alt-image.' .. n) then name = n; break end
    end
    h.ok(string.format('Active provider: %s (autodetected)', name or '?'))
  else
    h.error(string.format('Active provider: none detected (%s)', tostring(p)))
  end
end

local function probe_protocols(h)
  h.start('alt-image: protocols')
  for _, name in ipairs(PROTOCOLS) do
    local p = require('alt-image.' .. name)
    local supported, msg = p._supported({ timeout = 200 })
    if supported then
      h.ok(string.format('%s: supported%s', name,
        msg and (' (' .. msg .. ')') or ''))
    else
      h.error(string.format('%s: not detected%s', name,
        msg and (' — ' .. msg) or ''))
    end
  end
end

local function tooling(h)
  h.start('alt-image: external tools')

  local magick = require('alt-image._core.magick').binary()
  if magick then
    h.ok('ImageMagick: ' .. magick)
  else
    h.info('ImageMagick: not found '
        .. '(set vim.g.alt_image.magick or install magick/convert)')
  end

  local libsixel = require('alt-image.sixel._libsixel').binary()
  if libsixel then
    h.ok('libsixel: ' .. libsixel)
  else
    h.info('libsixel: not found '
        .. '(set vim.g.alt_image.img2sixel or install)')
  end

  local png = require('alt-image._core.png')
  if png.has_libz() then
    h.ok('PNG encoder: libz DEFLATE compression active')
  else
    h.info('PNG encoder: libz not found, falling back to stored zlib blocks')
  end
end

local function environment(h)
  -- Only emit the section header if something is worth saying so we don't
  -- create empty sections in the report under the common case.
  local notes = {}
  if vim.env.SSH_CONNECTION then
    notes[#notes + 1] = { 'warn',
      'SSH connection detected. Inline images over SSH require terminal '
      .. 'support on your local terminal.' }
  end
  if vim.env.TMUX then
    notes[#notes + 1] = { 'warn',
      'tmux detected: tmux passthrough is NOT supported in this version '
      .. 'of alt-image.nvim. Images may not render. Tracked in README.' }
  end
  if vim.env.TERM_PROGRAM == 'Apple_Terminal' then
    notes[#notes + 1] = { 'warn',
      'Apple Terminal echoes APC sequences but does not render sixel.' }
  end
  if #notes == 0 then return end

  h.start('alt-image: environment')
  for _, n in ipairs(notes) do h[n[1]](n[2]) end
end

function M.check()
  local h = vim.health
  h.start('alt-image')
  active_provider_line(h)
  probe_protocols(h)
  tooling(h)
  environment(h)
end

return M
