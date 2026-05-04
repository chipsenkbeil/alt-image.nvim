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
#39496). Pure Lua — runs on both LuaJIT and PUC. `libz` is picked up via
LuaJIT FFI when available for real DEFLATE PNG (with a stored-block
fallback when it isn't).

## Configuration

No `setup()` function. Protocol choice is expressed by which module you
require (see snippet above). Everything else lives under `vim.g.alt_img`,
read at call-time so plugin-load vs. config order doesn't matter:

```lua
vim.g.alt_img = {
  -- Providers `require('alt-img')` probes during autodetection, in order.
  -- First one whose `_supported()` returns true wins. Set to a single-entry
  -- list to pin a protocol.
  autodetect = { 'iterm2', 'sixel' },

  -- ImageMagick CLI for fast crop + (re)encode. Single name, an ordered
  -- list of candidates (first executable wins), or `false` to disable.
  magick = { 'magick', 'convert' },     -- string | string[] | false

  -- libsixel CLI for fast sixel encoding. Same shape as `magick`.
  img2sixel = { 'img2sixel' },          -- string | string[] | false

  -- Override the sixel logical-vs-physical pixel scale. `nil` = auto-detect
  -- via OSC 1337 ReportCellSize and CSI 14t / 18t / 16t geometry. Set to
  -- 1, 2, … to force a value when auto-detect misreads your terminal.
  sixel_pixel_scale = nil,              -- integer | nil

  -- Background pre-encode of crop variants on `set()` so subsequent partial
  -- redraws hit warm cache. `false` disables the warmer entirely.
  precompute_crops = true,

  -- Idle ms between successive precompute steps.
  precompute_interval_ms = 30,

  -- Delay after `set()` before the first precompute step fires.
  precompute_start_delay_ms = 500,

  -- Skip the next step if the user has typed / scrolled within this window.
  precompute_idle_threshold_ms = 500,

  -- vim.notify on precompute start / finish (debug aid).
  precompute_notify = false,
}
```

The crop LRU sizes itself per-placement from the image's height (it holds
exactly the precompute output, `2 * (height - 1)` entries, with a 64-entry
floor). Async `magick` parallelism scales with `vim.uv.available_parallelism()`
(1 on a single-core box, 2 otherwise). Neither needs a knob.

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

## Commands

A single `:AltImg` command groups runtime diagnostics and control. Tab
completion lists the available subcommands.

| Subcommand | What it does |
|---|---|
| `:AltImg info` | Print a diagnostic dump: terminal env, cell pixel size, sixel pixel scale (OSC 1337 + CSI 14t/18t/16t breakdown plus the effective value), external-tool detection, and every active placement with its resolved opts and target pixel dims. The first stop when something looks wrong. |
| `:AltImg refresh` | Force every placement to re-emit on the next render tick. Use after `:mode`, `:redraw!`, or any other terminal-side wipe that has cleared image cells without alt-img noticing. Caches stay warm — no re-encoding. |

## Development

```sh
make smoke-test    # launches nvim with test/manual_init.lua. Then:
                   #   :AltImgTest demo {ui|editor|buffer}
                   #   :AltImgTest mouse {ui|editor|off}
                   #   :AltImgTest provider {iterm2|sixel|auto}
                   #   :AltImg info / :AltImg refresh
make format-check  # stylua format gate
make format        # format using stylua
make lint          # public-surface guard
```

There is no automated functional test suite. Behavior verification is
manual via the smoke harness; future tests must drive the public
`vim.ui.img` API only.

## Limitations

- **tmux passthrough is not implemented.** Image escapes will be eaten or
  garbled when run inside tmux. Use a bare terminal for now.
- **No external UI / multigrid.** Carrier math assumes the default global grid.
- **PNG only.** Matching what you see in neovim core.

## Architecture

Living docs under [`docs/`](docs/) for anyone touching the internals:

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — module layout, render-loop
  lifecycle (with ASCII timelines), dirty/refresh autocmd split, caching,
  DPI scale auto-detect, external tool acceleration (magick / img2sixel
  dispatch tables and pure-Lua fallbacks).
- [`docs/ITERM2.md`](docs/ITERM2.md) — OSC 1337 sequence shape, encoding
  pipeline, sizing math.
- [`docs/SIXEL.md`](docs/SIXEL.md) — DCS sixel sequence shape, the DCS-params
  footgun, retina pixel-scale issue, pure-Lua quantizer + band encoder.

## Status

Pre-1.0. API tracks Neovim's upstream `vim.ui.img`.

## License

MIT.
