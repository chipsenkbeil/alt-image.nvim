-- :checkhealth alt-image.sixel
local M = {}

function M.check()
  local h = vim.health
  h.start('alt-image.sixel')

  local ok, msg = require('alt-image.sixel')._supported()
  if ok then
    h.ok('Sixel protocol: supported' .. (msg and (' (' .. msg .. ')') or ''))
  else
    h.error('Sixel protocol: not detected. '
         .. (msg or 'Detection failed. Try a sixel-capable terminal '
                 .. '(iTerm.app, WezTerm, foot, mlterm, contour, xterm +sixel), '
                 .. 'or set TERM=xterm-sixel, or call '
                 .. 'require("alt-image").setup({ protocol = "sixel" }) to force.'))
  end

  if vim.env.TERM_PROGRAM == 'Apple_Terminal' then
    h.warn('Apple Terminal echoes APC sequences but does not render sixel.')
  end

  if vim.env.TMUX then
    h.warn('tmux detected: tmux passthrough is NOT supported in this version '
        .. 'of alt-image.nvim. Images may not render. Tracked in README.')
  end
end

return M
