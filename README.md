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
require (see snippet above). Two configurable surfaces:

```lua
vim.g.alt_img = {
  -- Providers `require('alt-img')` probes during autodetection, in order.
  -- First one whose `_supported()` returns true wins. Set to a single-entry
  -- list to pin a protocol; omit to use the default below.
  autodetect = { 'iterm2', 'sixel' },

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

## Commands

A single `:AltImg` command groups runtime diagnostics and control. Tab
completion lists the available subcommands.

| Subcommand | What it does |
|---|---|
| `:AltImg info` | Print a diagnostic dump: terminal env, cell pixel size, sixel pixel scale (OSC 1337 + CSI 14t/18t/16t breakdown plus the effective value), external-tool detection, and every active placement with its resolved opts and target pixel dims. The first stop when something looks wrong. |
| `:AltImg refresh` | Force every placement to re-emit on the next render tick. Use after `:mode`, `:redraw!`, or any other terminal-side wipe that has cleared image cells without alt-img noticing. Caches stay warm — no re-encoding. |

## Acceleration

alt-img picks the cheapest available path per stage. Detection runs once
per session and is cached. Disable any tool with `vim.g.alt_img.<tool> = false`.

### Sixel provider (`require('alt-img.sixel')`)

| Stage | Preferred | Fallback 1 | Fallback 2 | Last resort | Notes |
|---|---|---|---|---|---|
| Full image (decode + resize + sixel-encode) | `magick` one-shot (`-sample WxH! sixel:-`) | (no libsixel one-shot for full image; falls through to pure-Lua chain) | — | pure-Lua decode → resize → quantize → encode | One subprocess, no PNG hop. Biggest single win on hosts without libz. |
| Cropped sub-rect | `magick` one-shot (`-sample WxH! -crop WxH+X+Y sixel:-`) | pure-Lua resize → crop → encode | — | — | Pure-Lua crop is just `string.sub` per row; the cost is the encode. |
| RGBA → sixel (no libz) | `magick` raw-RGBA (`-size WxH -depth 8 RGBA:-`) | pure-Lua quantize + encode | — | — | Skips the expensive PNG-encode hop on no-libz hosts. `img2sixel` has no raw-input mode, so it isn't tried in this branch. |
| RGBA → PNG → sixel (with libz) | `img2sixel` | `magick` PNG path | pure-Lua | — | `img2sixel` is preferred when both are present and libz is available. |
| PNG decode | libz `uncompress` (FFI) | pure-Lua INFLATE | — | — | Pure-Lua INFLATE is the slowest single component when libz is missing. |
| PNG encode | libz `compress2` (FFI) | uncompressed stored blocks | — | — | Stored-block output is ~4× the raw RGBA size; the no-libz raw-RGBA branch above exists to avoid this. |
| RGBA resize / crop | pure Lua (`string.sub` + `table.concat`) | — | — | — | Always fast enough not to need an external tool. |

### iTerm2 provider (`require('alt-img.iterm2')`)

| Stage | Preferred | Fallback | Notes |
|---|---|---|---|
| Full image (decode + resize + PNG re-encode) | `magick` one-shot (`-sample WxH! png:-`) | pure-Lua decode → resize → encode | iTerm2 receives image-pixels == cell-pixels so its own scaler is a no-op (sharp output). |
| Cropped sub-rect | `magick` one-shot (`-crop WxH+X+Y png:-`) on the cached resized PNG | pure-Lua crop → encode | Crop runs against the resized PNG, not the original — keeps output identical to the pure-Lua path. |
| Base64 of payload | `vim.base64.encode` (built-in) | — | Result cached alongside the PNG. |

### Caching

Per-placement state is keyed by the id returned from `set()`. On a
position-only redraw (scroll, cursor move) the cached output is re-emitted
without re-running any encoder.

| Cache | Backend | Granularity | Eviction |
|---|---|---|---|
| `cs.resized_rgba` | both | one full-resize buffer | width / height change in `set()` |
| `cs.full_png` + `cs.full_png_b64` | iTerm2 | one full-image PNG + base64 | width / height change |
| `cs.full_sixel` | sixel | one full-image DCS string | width / height change |
| `cs.crop_cache` | both | LRU per `"x,y,w,h"` cell-unit key | width / height change or LRU overflow |

`cs` is the codec-owned scratch under `state[id].codec_state`. LRU size
defaults to 256 per placement and is configurable via
`vim.g.alt_img.crop_cache_size`. Each entry is one PNG / sixel string
for a small crop, so memory is bounded.

The warm path is essentially free for both backends — the render loop
re-emits cached bytes without re-running any encoder, and skips emission
entirely when the placement's resolved screen position has not changed.

### What is *not* accelerated (deliberate)

- **Pure-Lua sixel string manipulation** (cropping/resizing an existing
  DCS string in place). Cropping the cached resized RGBA buffer and
  re-encoding is strictly faster than parsing 6-row sixel bands back to
  pixels. When `magick` is present it does resize + crop + encode in one
  subprocess.
- **Cross-placement cache sharing.** Two `set()` calls for the same PNG
  at the same size build separate per-placement caches.
- **PNG-on-disk mtime invalidation.** `set()` takes raw bytes, not a
  path; callers re-`set()` after edits.

## Development

```sh
make smoke-test    # launches nvim with test/manual_init.lua. Then:
                   #   :AltImgTest demo {ui|editor|buffer}
                   #   :AltImgTest mouse {ui|editor|off}
                   #   :AltImgTest provider {iterm2|sixel|auto}
                   #   :AltImg info / :AltImg refresh
make format-check  # stylua format gate
make lint          # public-surface guard
make verify-api    # diff pinned upstream vim.ui.img SHAs
```

There is no automated functional test suite. Behavior verification is
manual via the smoke harness; future tests must drive the public
`vim.ui.img` API only.

## Limitations

- **tmux passthrough is not implemented.** Image escapes will be eaten or
  garbled when run inside tmux. Use a bare terminal for now.
- **No external UI / multigrid.** Carrier math assumes the default global
  grid.
- **PNG only.** Both providers require PNG input — see *Input format*
  above. Non-PNG bytes are rejected at `set()`.

## Architecture

Living docs under [`docs/`](docs/) for anyone touching the internals:

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — module layout, render-loop
  lifecycle (with ASCII timelines), dirty/refresh autocmd split, caching,
  DPI scale auto-detect, external tool dispatch.
- [`docs/ITERM2.md`](docs/ITERM2.md) — OSC 1337 sequence shape, encoding
  pipeline, sizing math.
- [`docs/SIXEL.md`](docs/SIXEL.md) — DCS sixel sequence shape, the DCS-params
  footgun, retina pixel-scale issue, pure-Lua quantizer + band encoder.

## Status

Pre-1.0. API tracks Neovim's upstream `vim.ui.img`.

## License

MIT.
