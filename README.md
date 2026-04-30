# alt-image.nvim

Drop-in alternative implementations of Neovim's `vim.ui.img` for terminals
that don't speak the kitty graphics protocol.

```lua
-- Autodetect (env-var heuristics with capability-probe fallback)
vim.ui.img = require('alt-image')

-- Force a specific protocol
vim.ui.img = require('alt-image.iterm2')   -- iTerm2 / WezTerm (OSC 1337)
vim.ui.img = require('alt-image.sixel')    -- foot, mlterm, xterm +sixel, etc.
```

After installation, `vim.ui.img` works the same as on a kitty-capable
terminal — same `set` / `get` / `del` / `_supported` surface, same opts
(`row`, `col`, `width`, `height`, `zindex`, `relative` ∈ `ui|editor|buffer`,
`buf`, `pad`).

### Configuration

Configure via `vim.g.alt_image` (read at call-time, so this can be set
either before or after `require('alt-image')`):

```lua
vim.g.alt_image = {
  -- Force a specific protocol ('iterm2' / 'sixel' / 'auto'). Default: 'auto'.
  protocol = 'auto',
  -- Use img2sixel / convert (ImageMagick) when present for faster encoding
  -- and cropping. Falls back to pure Lua. Default: true.
  accelerate = true,
}
```

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
- **Sixel: PNG only.** The sixel provider decodes input bytes to RGBA via
  the bundled pure-Lua PNG decoder, so non-PNG bytes will fail. The iTerm2
  provider base64-encodes input verbatim and passes through to the
  terminal — formats other than PNG may work depending on the terminal.

## License

MIT.
