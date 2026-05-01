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

alt-img picks the cheapest available path per stage. Detection runs once
per session and is cached. Disable any tool with `vim.g.alt_img.<tool> = false`.

### Sixel provider (`require('alt-img.sixel')`)

| Stage | Preferred | Fallback 1 | Fallback 2 | Last resort | Notes |
|---|---|---|---|---|---|
| Full image (decode + resize + sixel-encode) | `magick` one-shot (`-sample WxH! sixel:-`) | (no libsixel one-shot for full image; falls through to pure-Lua chain) | — | pure-Lua decode → resize → quantize → encode | One subprocess, no PNG hop. Biggest single win on hosts without libz. |
| Cropped sub-rect | `magick` one-shot (`-sample WxH! -crop WxH+X+Y sixel:-`) | pure-Lua resize → crop → encode | — | — | Pure-Lua crop is fast (FFI memcpy); the cost is the encode. |
| RGBA → sixel (no libz) | `magick` raw-RGBA (`-size WxH -depth 8 RGBA:-`) | pure-Lua quantize + encode | — | — | Skips the expensive PNG-encode hop on no-libz hosts. `img2sixel` has no raw-input mode, so it isn't tried in this branch. |
| RGBA → PNG → sixel (with libz) | `img2sixel` | `magick` PNG path | pure-Lua | — | `img2sixel` is preferred when both are present and libz is available. |
| PNG decode | libz `uncompress` (FFI) | pure-Lua INFLATE | — | — | Pure-Lua INFLATE is the slowest single component when libz is missing. |
| PNG encode | libz `compress2` (FFI) | uncompressed stored blocks | — | — | Stored-block output is ~4× the raw RGBA size; the no-libz raw-RGBA branch above exists to avoid this. |
| RGBA resize / crop | pure-Lua + FFI memcpy | — | — | — | Always fast enough not to need an external tool. |

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
| `s.resized_rgba` | both | one full-resize buffer | width / height change in `set()` |
| `s.full_png` + `s.full_png_b64` | iTerm2 | one full-image PNG + base64 | width / height change |
| `s.sixel_cache` | sixel | one full-image DCS string | width / height change |
| `s.png_cache_by_src` | iTerm2 | LRU per `"x,y,w,h"` cell-unit key | width / height change or LRU overflow |
| `s.sixel_cache_by_src` | sixel | LRU per `"x,y,w,h"` cell-unit key | width / height change or LRU overflow |

LRU size defaults to 64 per placement and is configurable via
`vim.g.alt_img.crop_cache_size`. Each entry is one PNG / sixel string for
a small crop, so memory is bounded.

### Approximate impact

Numbers below come from `make benchmark` against
`~/Pictures/org-roam-logo.png` (444×431 RGBA, 85KB) emitted at 80×30
cells (~640×480 px target) — **see `test/benchmark.out.md` for the full
table** and reproduce with `make benchmark FIXTURE=/path/to/your.png`.
Cold = first emit on a fresh placement; warm = re-emit with the encoded
payload cached.

| Path | Cold | Warm | Subprocesses | Payload | Notes |
|---|---|---|---|---|---|
| sixel + magick | ~750 ms | <0.1 ms | 1 | 97 KB | One subprocess; resize + quantize + encode in C. |
| sixel + img2sixel + libz | ~690 ms | <0.1 ms | 1 | 197 KB | Pure-Lua decode + resize, then libsixel encode. |
| sixel pure-Lua + libz | ~710 ms | <0.1 ms | 0 | 99 KB | Quantize + encode dominate; competitive with magick at this size. |
| sixel pure-Lua, no libz | ~2400 ms | <0.1 ms | 0 | 99 KB | Pure-Lua INFLATE dominates; the raw-RGBA fast path bypasses it. |
| sixel + magick, no libz | ~750 ms | <0.1 ms | 1 | 97 KB | Magick reads RGBA from stdin; PNG hop avoided. |
| iterm2 + magick | ~680 ms | <0.1 ms | 1 | 108 KB | One subprocess; libz inside magick handles compression. |
| iterm2 + libz, no magick | ~650 ms | <0.1 ms | 0 | 108 KB | Pure-Lua decode + resize + encode. |
| iterm2, no libz | ~2400 ms | <0.3 ms | 0 | **1.6 MB** | Encoder falls back to stored blocks; payload ~15× larger. |
| sixel cropped + magick | ~690 ms | <0.1 ms | 1 | 23 KB | Resize + crop + sixel-encode in one subprocess. |
| iterm2 cropped + magick | ~720 ms | <0.1 ms | 2 | 31 KB | One magick call to resize + one to crop the cached PNG. |

The warm path is essentially free for both backends — the render loop
re-emits cached bytes without re-running any encoder, and skips emission
entirely when the placement's resolved screen position has not changed.

For sub-megapixel images, pure-Lua + libz is competitive with the magick
fast path: subprocess fork+exec overhead is comparable to the Lua hot
loops. Magick wins decisively on no-libz hosts (single subprocess vs
~3× slower pure-Lua INFLATE) and on larger images where its C inner
loops outpace LuaJIT.

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
