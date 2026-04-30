# alt-image.nvim

Drop-in alternative implementations of Neovim's `vim.ui.img` for terminals
that don't speak the kitty graphics protocol.

```lua
-- Autodetect (env-var heuristics with capability-probe fallback)
vim.ui.img = require('alt-image')

-- Force a specific protocol
vim.ui.img = require('alt-image.iterm2')   -- iTerm2 / WezTerm (OSC 1337)
vim.ui.img = require('alt-image.sixel')    -- foot, mlterm, xterm +sixel, etc.

-- Or via setup
require('alt-image').setup({ protocol = 'iterm2' })  -- override autodetect
vim.ui.img = require('alt-image')
```

After installation, `vim.ui.img` works the same as on a kitty-capable
terminal — same `set` / `get` / `del` / `_supported` surface, same opts
(`row`, `col`, `width`, `height`, `zindex`, `relative` ∈ `ui|editor|buffer`,
`buf`, `pad`).

## Healthchecks

```vim
:checkhealth alt-image
:checkhealth alt-image.iterm2
:checkhealth alt-image.sixel
```

## Development

```sh
make test         # unit tests, headless, no deps
make smoke-test   # interactive: :AltImageDemo ui|editor|buffer
                  # plus :AltImageMouse ui|editor|off (image follows mouse)
```

## Status

Pre-1.0. API tracks Neovim's `vim.ui.img` post-PRs #37914, #39449, #39484,
#39496.

## Limitations / TODO

- **tmux passthrough is not supported.** Running inside tmux requires
  passthrough escape wrapping (and multipart for >64KiB iTerm2 payloads);
  neither is implemented. Image escapes will reach tmux and be eaten or
  passed through inconsistently. Use the plugin in a bare terminal for now.
- **No external UI / multigrid support.** Carrier coordinate math assumes
  the default global UI grid.
- **PNG only.** Both protocols can in principle take other formats, but
  sixel needs decoded RGBA so this plugin ships PNG decode only.

## License

MIT.
