# alt-img.nvim

> Drop-in `vim.ui.img` for terminals without the kitty graphics protocol.

Pure-Lua iTerm2 (OSC 1337) and sixel (DCS) providers. Optionally accelerates
crop + encode through `magick` / `img2sixel` when present.

```lua
vim.ui.img = require('alt-img')          -- autodetect
vim.ui.img = require('alt-img.iterm2')   -- iTerm2 / WezTerm (OSC 1337)
vim.ui.img = require('alt-img.sixel')    -- foot, mlterm, xterm+sixel, …
```

That's it. After this, `vim.ui.img.set / get / del` works the same as on a
kitty-capable Neovim build.

## Input format

`set(data, opts)` requires `data` to be **PNG bytes** (the same contract as
upstream `vim.ui.img`). Other formats are not supported and will error at
the boundary; convert to PNG first if you need to feed in JPEG / WebP / etc.

---

## Install

`lazy.nvim`:

```lua
{ 'chipsenkbeil/alt-img.nvim', config = function()
    vim.ui.img = require('alt-img')
  end,
}
```

`vim.pack`:

```lua
vim.pack.add({ 'https://github.com/chipsenkbeil/alt-img.nvim' })
vim.ui.img = require('alt-img')
```

Requires Neovim with the `vim.ui.img` API surface (PRs #37914, #39449, #39484,
#39496). LuaJIT FFI is used for fast pixel ops; `libz` is picked up
automatically when present for real DEFLATE PNG output.

## Configuration

No `setup()` function. Protocol choice is expressed by which module you
require (see snippet above). The only configurable surface is the optional
external-tool acceleration:

```lua
vim.g.alt_img = {
  -- ImageMagick CLI for fast crop + (re)encode. Accepts a single binary
  -- name, an ordered list of candidates (first executable wins), or `false`
  -- to disable the path entirely. Falls through to pure-Lua otherwise.
  magick = { 'magick', 'convert' },     -- string | string[] | false

  -- libsixel CLI for fast sixel encoding. Same shape.
  img2sixel = { 'img2sixel' },          -- string | string[] | false
}
```

Read at call-time, so order of plugin load vs. config doesn't matter.

## Health

```vim
:checkhealth alt-img
```

Reports the active provider, probes both protocols (✓ / ✗), and lists
external-tool detection — runs in ~400ms worst case.

```vim
:checkhealth alt-img.iterm2
:checkhealth alt-img.sixel
```

…drill into a single protocol.

## Acceleration

Crop + (re)encode is the hot path during scroll / mouse-follow. alt-img
ships pure-Lua implementations of everything — PNG decode/encode (with libz
DEFLATE when available), nearest-neighbor resize, RGBA crop, sixel encode
with median-cut quantization — so it works with zero external deps.

When `magick` (IM7) or `convert` (IM6) is on PATH, crops on the iTerm2 path
become a single `magick - -crop WxH+X+Y png:-` subprocess. When `img2sixel`
or `magick` is on PATH, sixel encode delegates to whichever is faster on
your system. Detection is cached; toggle off per-tool with
`vim.g.alt_img.<tool> = false`.

## Development

```sh
make test         # 150 unit tests, headless, no external deps
make smoke-test   # interactive: :AltImgDemo ui|editor|buffer
                  #              :AltImgMouse ui|editor|off
                  #              :AltImgProvider iterm2|sixel|auto
```

## Limitations

- **tmux passthrough is not implemented.** Image escapes will be eaten or
  garbled when run inside tmux. Use a bare terminal for now.
- **No external UI / multigrid.** Carrier math assumes the default global
  grid.
- **PNG only.** Both providers require PNG input — see *Input format*
  above. Non-PNG bytes are rejected at `set()`.

## Status

Pre-1.0. API tracks Neovim's upstream `vim.ui.img`.

## License

MIT.
