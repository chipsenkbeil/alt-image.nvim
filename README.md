# alt-image.nvim

> Drop-in `vim.ui.img` for terminals without the kitty graphics protocol.

Pure-Lua iTerm2 (OSC 1337) and sixel (DCS) providers. Autodetects what your
terminal supports. Optionally accelerates crop + encode through `magick` /
`img2sixel` when present.

```lua
vim.ui.img = require('alt-image')
```

That's it. After this, `vim.ui.img.set / get / del` works the same as on a
kitty-capable Neovim build.

---

## Install

`lazy.nvim`:

```lua
{ 'chipsenkbeil/alt-image.nvim', config = function()
    vim.ui.img = require('alt-image')
  end,
}
```

`vim.pack`:

```lua
vim.pack.add({ 'https://github.com/chipsenkbeil/alt-image.nvim' })
vim.ui.img = require('alt-image')
```

Requires Neovim with the `vim.ui.img` API surface (PRs #37914, #39449, #39484,
#39496). LuaJIT FFI is used for fast pixel ops; `libz` is picked up
automatically when present for real DEFLATE PNG output.

## Configuration

No `setup()` function. Override individual fields via `vim.g.alt_image`;
anything you don't set keeps its default. Read at call-time, so order of
plugin load vs. config doesn't matter.

```lua
vim.g.alt_image = {
  -- Which protocol to use. 'auto' picks via env-var fast paths, then a
  -- terminal capability probe.
  protocol = 'auto',                    -- 'auto' | 'iterm2' | 'sixel'

  -- ImageMagick CLI for fast crop + (re)encode. Accepts a single binary
  -- name, an ordered list of candidates (first executable wins), or `false`
  -- to disable the path entirely. Falls through to pure-Lua otherwise.
  magick = { 'magick', 'convert' },     -- string | string[] | false

  -- libsixel CLI for fast sixel encoding. Same shape.
  img2sixel = { 'img2sixel' },          -- string | string[] | false
}
```

To force a specific protocol without reading config:

```lua
vim.ui.img = require('alt-image.iterm2')   -- iTerm2 / WezTerm (OSC 1337)
vim.ui.img = require('alt-image.sixel')    -- foot, mlterm, xterm+sixel, …
```

## Health

```vim
:checkhealth alt-image
```

Reports the active provider, probes both protocols (✓ / ✗), and lists
external-tool detection — runs in ~400ms worst case.

```vim
:checkhealth alt-image.iterm2
:checkhealth alt-image.sixel
```

…drill into a single protocol.

## Acceleration

Crop + (re)encode is the hot path during scroll / mouse-follow. alt-image
ships pure-Lua implementations of everything — PNG decode/encode (with libz
DEFLATE when available), nearest-neighbor resize, RGBA crop, sixel encode
with median-cut quantization — so it works with zero external deps.

When `magick` (IM7) or `convert` (IM6) is on PATH, crops on the iTerm2 path
become a single `magick - -crop WxH+X+Y png:-` subprocess. When `img2sixel`
or `magick` is on PATH, sixel encode delegates to whichever is faster on
your system. Detection is cached; toggle off per-tool with
`vim.g.alt_image.<tool> = false`.

## Development

```sh
make test         # 150 unit tests, headless, no external deps
make smoke-test   # interactive: :AltImageDemo ui|editor|buffer
                  #              :AltImageMouse ui|editor|off
                  #              :AltImageProvider iterm2|sixel|auto
```

## Limitations

- **tmux passthrough is not implemented.** Image escapes will be eaten or
  garbled when run inside tmux. Use a bare terminal for now.
- **No external UI / multigrid.** Carrier math assumes the default global
  grid.
- **Sixel decodes PNG only.** Bytes are decoded via the bundled pure-Lua
  PNG decoder; other formats fail. iTerm2 passes input bytes through
  verbatim, so non-PNG may work depending on terminal support.

## Status

Pre-1.0. API tracks Neovim's upstream `vim.ui.img`.

## License

MIT.
