# alt-image.nvim

Drop-in alternative implementations of Neovim's `vim.ui.img` for terminals
that don't speak the kitty graphics protocol.

```lua
vim.ui.img = require('alt-image')          -- autodetect
vim.ui.img = require('alt-image.iterm2')   -- iTerm2 OSC 1337
vim.ui.img = require('alt-image.sixel')    -- sixel
```

See `:help alt-image` (TBD) and `:checkhealth alt-image`.

## Status

Pre-1.0. API tracks Neovim's `vim.ui.img` post-PRs #37914, #39449, #39484,
#39496.
