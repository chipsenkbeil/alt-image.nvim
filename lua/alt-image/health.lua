-- :checkhealth alt-image
local M = {}

function M.check()
  local h = vim.health
  h.start('alt-image')

  local mod = require('alt-image')
  local ok, err = pcall(mod._provider)
  if ok then
    local p = mod._provider()
    local name = (p == require('alt-image.iterm2')) and 'iterm2' or 'sixel'
    h.ok('Detected provider: ' .. name)
  else
    h.error('No provider detected: ' .. tostring(err))
  end

  h.info('Run `:checkhealth alt-image.iterm2` and `:checkhealth alt-image.sixel` '
      .. 'for per-protocol details.')

  if vim.env.SSH_CONNECTION then
    h.warn('SSH connection detected. Inline images over SSH require terminal '
        .. 'support on your local terminal.')
  end
  if vim.env.TMUX then
    h.warn('tmux detected: tmux passthrough is NOT supported in this version '
        .. 'of alt-image.nvim. Images may not render. Tracked in README.')
  end

  -- Acceleration tooling
  local util = require('alt-image._util')
  local g = vim.g.alt_image or {}
  local accel = (g.accelerate ~= false)
  h.info('Acceleration: ' .. (accel and 'enabled' or 'disabled')
      .. ' (set vim.g.alt_image = { accelerate = false } to disable)')
  if util.have_img2sixel() then
    h.ok('img2sixel detected — sixel encoding accelerated')
  else
    h.info('img2sixel not found — falling back to convert or pure Lua')
  end
  if util.have_convert() then
    h.ok('convert (ImageMagick) detected — used for cropping and sixel fallback')
  else
    h.info('convert not found — using pure Lua for cropping and PNG encode')
  end
end

return M
