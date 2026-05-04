# alt-img.nvim

> Drop-in `vim.ui.img` for terminals without the kitty graphics protocol.

Pure-Lua iTerm2 (OSC 1337) and sixel (DCS) providers. Optionally accelerates
crop + encode through `chafa` / `magick` / `img2sixel` / `libz` when present.

```lua
vim.ui.img = require('alt-img')          -- autodetect the protocol (iterm2 or sixel)
vim.ui.img = require('alt-img.iterm2')   -- explicitly use iterm2 (e.g. iTerm2, WezTerm)
vim.ui.img = require('alt-img.sixel')    -- explicitly use sixel (e.g. foot, mlterm, xterm+sixel)
```

That's it!

After this, `vim.ui.img.set` `vim.ui.img.get`, and `vim.ui.img.del` work the
same as on a kitty-capable Neovim build.

## Demos

 <table>
    <tr>
      <td><video src="https://github.com/user-attachments/assets/d56cf170-30ab-4f95-b5b7-4a68ad86e29e" /></td>
      <td><video src="https://github.com/user-attachments/assets/87f0ba2e-a5ba-4dcf-b1ec-f81a0ad9c9fe" /></td>
      <td><video src="https://github.com/user-attachments/assets/64da2fe0-f42c-44f2-9a39-a26bd7d66bc6" /></td>
    </tr>
    <tr>
      <td align="center">iTerm2 protocol (iTerm2)</td>
      <td align="center">Sixel protocol (Windows Terminal)</td>
      <td align="center">Placeholder loading status when slow</td>
    </tr>
  </table>

## Input format

`set(data, opts)` requires `data` to be **PNG bytes** (the same contract as
upstream `vim.ui.img`). Other formats are not supported and will error at
the boundary; convert to PNG first if you need to feed in JPEG / WebP / etc.

---

## Install

Pin to the latest tagged release for stability — `master` moves and may break.

`lazy.nvim` (pinned to `v0.1.0`, recommended):

```lua
{ 
  'chipsenkbeil/alt-img.nvim', tag = 'v0.1.0', config = function()
    vim.ui.img = require('alt-img')
  end,
}
```

`lazy.nvim` (latest commit on `master`):

```lua
{ 
  'chipsenkbeil/alt-img.nvim', branch = 'master', config = function()
    vim.ui.img = require('alt-img')
  end,
}
```

`vim.pack` (pinned to `v0.1.0`, recommended):

```lua
vim.pack.add({
  { src = 'https://github.com/chipsenkbeil/alt-img.nvim', version = 'v0.1.0' },
})
vim.ui.img = require('alt-img')
```

`vim.pack` (latest commit on `master`):

```lua
vim.pack.add({ 'https://github.com/chipsenkbeil/alt-img.nvim' })
vim.ui.img = require('alt-img')
```

Works fine on neovim `0.12` and should also work on future neovim versions with
a matching API signature. 

## Configuration

No `setup()` function. Protocol choice is expressed by which module you
require (see snippet above). Everything else lives under `vim.g.alt_img`,
read at call-time so plugin-load vs. config order doesn't matter:

```lua
vim.g.alt_img = {
  -- Providers `require('alt-img')` probes during autodetection, in order.
  -- First one to be supported wins.
  autodetect = { 'iterm2', 'sixel' },

  -- Override the terminal cell pixel size as `{ width_px, height_px }`.
  --
  -- `nil` = probe via CSI 16t (default). Set explicitly when your
  -- terminal doesn't answer CSI 16t or you want to skip the ~250 ms
  -- probe timeout on first call.
  cell_pixel_size = nil,                  -- { integer, integer } | nil

  -- Sixel-only knobs to turn.
  sixel = {
    -- Override the sixel logical-vs-physical pixel scale. `nil` = auto
    -- via OSC 1337 ReportCellSize and CSI 14t / 18t / 16t geometry. Set
    -- to 1, 2, … to force a value when auto-detect misreads your
    -- terminal.
    pixel_scale = nil,                    -- integer | nil
  },

  -- External / FFI acceleration tools.
  processing = {
    -- Enabled tools, in order.
    -- Prefer chafa first (only encoder that preserves PNG alpha), then
    -- img2sixel, then magick, with the pure-Lua tail catching anything
    -- that falls through. 
    --
    -- Drop a name to disable it; set to `false` for pure-Lua only.
    tools = { 'chafa', 'img2sixel', 'magick', 'libz' },

    -- Per-tool candidate binary (or, for libz, FFI dylib) names.
    -- First entry that resolves on PATH wins.
    magick    = { 'magick', 'convert' },          -- string | string[]
    img2sixel = { 'img2sixel' },                  -- string | string[]
    chafa     = { 'chafa' },                      -- string | string[]
    libz      = { 'z', 'zlib', 'zlib1', 'libz' }, -- string | string[]
  },

  -- Background pre-encode of crop variants on `set()` so subsequent partial
  -- redraws hit warm cache. `enabled = false` disables the warmer entirely.
  precompute = {
    enabled            = true,
    interval_ms        = 30,    -- ms between successive precompute steps
    start_delay_ms     = 500,   -- ms after set() before the first step fires
    idle_threshold_ms  = 500,   -- skip next step if user typed/scrolled within this window
    notify             = false, -- vim.notify on precompute start / finish (debug aid)
  },

  -- On-disk encode cache. Sixel DCS and resized/cropped PNGs are persisted
  -- under `stdpath('cache') .. '/alt-img/'`, keyed by sha256 of input bytes
  -- + target pixel dims + crop rect.
  --
  -- The same image at the same dims hits the cache across nvim sessions,
  -- machines (if you sync the dir), and between the iterm2 and sixel codecs.
  cache = {
    enabled    = true,
    dir        = nil,                 -- string | nil  (nil = stdpath('cache') .. '/alt-img')
    max_bytes  = 500 * 1024 * 1024,   -- evict oldest-mtime entries past this on write
    max_age_days = nil,               -- integer | nil (drop entries older than this on read)
  },

  -- Loading-state placeholder. Drawn in the cell rectangle when an image takes
  -- awhile to load whether by encoding or something else.
  --
  -- This is particularly common if `libz` is unavailable and you do not have
  -- an external tool like `chafa` or `magick` to help accelerate encoding &
  -- decoding of PNGs.
  placeholder = {
    enabled              = true,
    delay_ms             = 100,         -- skip placeholder if under X milliseconds
    spinner_interval_ms  = 120,         -- spinner glyph advance cadence
    box                  = 'rounded',   -- 'rounded'|'single'|'dotted'|'heavy'|'none'
    spinner              = 'braille',   -- 'braille'|'quarter'|'half'|'bar'|'fade'|'classic'
    show_percent         = true,        -- caption '⣾ 34%' vs just '⣾'
  },
}
```

### Placeholder highlight

The placeholder uses the `AltImgPlaceholder` highlight group. Its default is
`:hi default link AltImgPlaceholder Comment`, so the box renders dim by
default. Override with:

```lua
vim.api.nvim_set_hl(0, 'AltImgPlaceholder', { fg = '#7287fd', italic = true })
```

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

Provides specific insight into a provider.

## Commands

A single `:AltImg` command groups runtime diagnostics and control. Tab
completion lists the available subcommands.

| Subcommand | What it does |
|---|---|
| `:AltImg info` | Print a diagnostic dump: terminal env, cell pixel size, sixel pixel scale (OSC 1337 + CSI 14t/18t/16t breakdown plus the effective value), external-tool detection, and every active placement with its resolved opts and target pixel dims. The first stop when something looks wrong. |
| `:AltImg refresh` | Force every placement to re-emit on the next render tick. Use after `:mode`, `:redraw!`, or any other terminal-side wipe that has cleared image cells without alt-img noticing. Caches stay warm — no re-encoding. |
| `:AltImg cache stats` | Report cache entry count, total bytes, and the resolved cache directory. |
| `:AltImg cache clear [days]` | Delete every cache entry, or only entries older than `[days]` if a non-negative integer is given. |
| `:AltImg cache path` | Echo the absolute cache directory. |

The cache is also reachable from Lua:

```lua
require('alt-img').cache.stats()                       -- { entries, bytes, dir }
require('alt-img').cache.clear()                       -- wipe everything
require('alt-img').cache.clear({ older_than_days = 7 })
require('alt-img').cache.path()                        -- absolute path
require('alt-img').cache.disable()                     -- in-process toggle (this nvim only)
require('alt-img').cache.enable()
```

## Development

```sh
make smoke-test    # launches nvim with test/manual_init.lua. Then:
                   #   :AltImgTest demo {ui|editor|buffer}
                   #   :AltImgTest mouse {ui|editor|off}
                   #   :AltImgTest provider {iterm2|sixel|auto}
                   #   :AltImg info / :AltImg refresh
make test          # full suite (unit + e2e)
make test-unit     # unit only — in-process, fast
make test-e2e      # e2e only — spawn child nvim per block
make format-check  # stylua format gate
make format        # format using stylua
make lint          # public-surface guard
```

`FILTER='lua-pattern'` narrows any of the test targets — matched against
`suite_name:block_name`.

### Test layout

- `test/unit/**` — `it()` blocks that exercise pure modules in-process
  (async driver, placeholder compose, png libz config). Fast; no child
  nvim.
- `test/e2e/**` — `harness()` blocks that spawn a fresh headless child
  nvim per block, drive it via msgpack-RPC through the public
  `vim.ui.img.set / get / del` API, and observe behavior black-box: raw
  bytes captured from `nvim_ui_send`, extmarks across all namespaces,
  floating-window buffers. No `_*` test hooks in production code.

The runner (`test/runner.lua`) discovers `describe`/`it`/`harness`
blocks via `setfenv`-injected globals and reports per-block timing.

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
