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

  -- External tooling
  local magick   = require('alt-image._magick').binary()
  local libsixel = require('alt-image._libsixel').binary()
  if magick then
    h.ok('ImageMagick: ' .. magick)
  else
    h.info('ImageMagick: not found '
        .. '(set vim.g.alt_image.magick or install magick/convert)')
  end
  if libsixel then
    h.ok('libsixel: ' .. libsixel)
  else
    h.info('libsixel: not found '
        .. '(set vim.g.alt_image.img2sixel or install)')
  end

  -- PNG encoder compression status
  local png_encode = require('alt-image._png_encode')
  if png_encode.has_libz() then
    h.ok('PNG encoder: libz DEFLATE compression active')
  else
    h.info('PNG encoder: libz not found, falling back to stored zlib blocks')
  end
end

return M
