# alt-img.nvim architecture

Reference for everything inside the `lua/alt-img/` tree: how a `set()` call
turns into pixels on the terminal, when those pixels get re-emitted, when
they get cleared, where the caches sit, and which subprocess runs where.

For the protocol-level details that the encoders actually emit, see
[`ITERM2.md`](ITERM2.md) and [`SIXEL.md`](SIXEL.md).

---

## 1. Module map

```
lua/alt-img/
├── init.lua                    -- autodetect dispatcher (vim.ui.img surface)
├── iterm2.lua                  -- OSC 1337 provider
├── sixel.lua                   -- sixel DCS provider
├── health.lua                  -- :checkhealth alt-img
├── _cmd.lua                    -- :AltImg user-command dispatch & subcommands
├── iterm2/
│   └── health.lua              -- :checkhealth alt-img.iterm2
├── sixel/
│   ├── _encode.lua             -- pure-Lua median-cut + sixel band encoder
│   ├── _libsixel.lua           -- img2sixel binary detection / spawn
│   └── health.lua              -- :checkhealth alt-img.sixel
└── _core/
    ├── render.lua              -- timer-driven dirty/emit scheduler
    ├── carrier.lua             -- floats / extmarks for relative=editor|buffer
    ├── util.lua                -- cell-pixel size, scale detection, term_send
    ├── tty.lua                 -- TermResponse-based query helper
    ├── magick.lua              -- magick / convert binary detection / spawn
    ├── png.lua                 -- pure-Lua PNG decode/encode + libz FFI
    ├── image.lua               -- pure-Lua RGBA resize/crop (FFI memcpy)
    ├── lru.lua                 -- per-placement crop cache
    └── config.lua              -- vim.g.alt_img reader

plugin/alt-img.lua              -- registers :AltImg user command (auto-loaded)
```

The `_core/` and `_cmd.lua` modules are private: callers come from
`init.lua`, `iterm2.lua`, `sixel.lua`, or the user command. The two
provider modules (`iterm2.lua`, `sixel.lua`) and the autodetect
dispatcher (`init.lua`) export the public `set/get/del/refresh/_supported`
surface.

---

## 2. Component interaction

```
                 ┌───────────────────────┐
   user-code ───►│ vim.ui.img            │
                 │   = alt-img            │  (autodetect)
                 │   | alt-img.iterm2     │
                 │   | alt-img.sixel      │
                 └─────────┬─────────────┘
                           │ set / get / del / refresh
                           ▼
            ┌─────────────────────────────────┐
            │ provider (iterm2.lua | sixel.lua) │
            │  ┌──────────────────────────────┐ │
            │  │ state[id] = {                │ │
            │  │   data, opts,                │ │
            │  │   resized_rgba,              │ │
            │  │   full_png/sixel_cache,      │ │
            │  │   crop LRU                   │ │
            │  │ }                             │ │
            │  └──────────────────────────────┘ │
            └──────┬─────────────────┬─────────┘
                   │ register +      │ register +
                   │ get_pos closure │ unregister
                   ▼                 ▼
       ┌────────────────────┐  ┌──────────────────────┐
       │ _core/carrier.lua  │  │ _core/render.lua      │
       │  • opens floats    │  │  • 30 ms timer        │
       │  • places extmarks │  │  • dirty flags        │
       │  • resolves        │  │  • position diffing   │
       │    screen rect     │  │  • Mode 2026 sync     │
       └────────┬───────────┘  └──────────┬────────────┘
                │ uses                    │ calls _emit_at
                ▼                         ▼
       ┌────────────────────┐    ┌────────────────────┐
       │  vim.fn.screenpos  │    │  provider._emit_at │
       │  winsaveview       │    │  (per placement)   │
       │  nvim_win_*        │    └─────────┬──────────┘
       └────────────────────┘              │ writes bytes
                                           ▼
                                  ┌──────────────────┐
                                  │ util.term_send   │
                                  │ = nvim_ui_send   │
                                  └────────┬─────────┘
                                           │
                                           ▼
                                  ┌──────────────────┐
                                  │ terminal         │
                                  │ (sixel / OSC1337)│
                                  └──────────────────┘
```

Encoders sit beneath the providers:

```
provider ──► magick.lua / sixel/_libsixel.lua  (subprocess spawn via vim.system)
         └► png.lua / image.lua / sixel/_encode.lua   (pure-Lua + FFI fallback)
```

---

## 3. Public API contract

| Function | Description | Source |
|---|---|---|
| `set(data\|id, opts)` | Register or update a placement. `data` is PNG bytes; `opts` are cell-coords + relative kind. Returns the placement id. | `iterm2.lua:251`, `sixel.lua:233` |
| `get(id)` | Return the canonical opts for an existing placement, or nil. | `iterm2.lua:334`, `sixel.lua:308` |
| `del(id)` | Delete one placement. `del(math.huge)` deletes everything. | `iterm2.lua:342`, `sixel.lua:316` |
| `refresh()` | Force every placement to re-emit on the next tick (nulls `last_positions`, ticks once). Used after `:mode`, `:redraw!`, terminal-side wipes. | `iterm2.lua:M.refresh`, `sixel.lua:M.refresh`, dispatched through `_core/render.lua:M.refresh` |
| `_supported(opts)` | Sync probe of whether the current terminal supports this provider. Used by the autodetect dispatcher. | `iterm2.lua:_supported`, `sixel.lua:_supported` |

Everything else (`_emit_at`, `_state`, `_provider`, `_timer`,
`_force_all_dirty`, `_query_*`) is implementation detail exposed only for
testing.

---

## 4. Rendering pipeline (set → emit)

```
user                                                   terminal
  │                                                         ▲
  │  vim.ui.img.set(png_bytes, { row=1, col=1, … })          │
  ▼                                                         │
provider.set(...)                                            │
  │                                                         │
  ├─► canonicalize(opts)        (defaults + buf=0 → curbuf) │
  ├─► derive_dims(data, opts)   (CSI 16t / IHDR-derived)    │
  ├─► state[id] = { data, opts, … }                         │
  ├─► carrier.register(M, id, opts)                         │
  │     │                                                    │
  │     ├─► relative = editor   → nvim_open_win (0×0 float)  │
  │     ├─► relative = buffer   → nvim_buf_set_extmark + virt_lines
  │     └─► relative = ui       → no carrier (anchor is screen coords)
  │                                                         │
  ├─► render.register(M, id, get_pos_for(id))                │
  └─► render.flush()    -- run a tick synchronously         │
                            │                                │
                            ▼                                │
                       tick()                                │
                            │                                │
        ┌───────────────────┼───────────────────┐            │
        │  for p in placements:                  │            │
        │      if p.redraw:                      │            │
        │          positions = p.get_pos() or {} │            │
        │          if positions ≠ last:          │            │
        │              p.next_positions = positions          │
        │              need_clear = true                     │
        │              initially_dirty[++] = p               │
        │          else:                                     │
        │              p.redraw = false   ←─── ELISION       │
        │                                                    │
        │  if nothing dirty AND no need_clear: return        │
        │                                                    │
        │  if need_clear:                                    │
        │      emit_set = ALL placements        (zindex sorted)
        │  else:                                              │
        │      emit_set = initially_dirty                     │
        └────────────────────┬───────────────────┘            │
                             ▼                                │
              Mode 2026 sync block:                           │
                term_send( "\e[?2026h" )         ───────────► │
                if need_clear: vim.cmd.mode()                 │
                vim.cmd("redraw")    -- flush text grid       │
                for p in emit_set:                            │
                    for pos in p.next_positions:              │
                        provider._emit_at(p.id, pos) ───────► │
                    p.last_positions = p.next_positions       │
                    p.redraw = false                          │
                term_send( "\e[?2026l" )         ───────────► │
                                                              ▼
                                                    pixels paint
```

### Position-equality elision (Bug #2 fix)

The dirty scan distinguishes "marked dirty but didn't actually move"
from real movement. Typing fires `CursorMoved`/`TextChanged` on every
keystroke; without the elision we'd push the entire sixel/OSC payload
through `nvim_ui_send` per keystroke. With it, those autocmds are a
no-op when the placement's resolved screen position hasn't changed.

The elision is what makes `_force_all_dirty` (§5) necessary — some
events imply the terminal compositor has wiped image cells without our
cell-coords changing.

---

## 5. Dirty events: when and how we re-emit

There are two autocmd groups in `_core/render.lua`:

```
                ┌──────────────────────────────┐
                │ alt-img.render augroup       │
                ├──────────────┬───────────────┤
                │ HOT PATH     │ FORCE PATH    │
                │              │               │
                │ TextChanged  │ BufEnter      │
                │ TextChangedI │ BufWinEnter   │
                │ CursorMoved  │ BufWritePost  │
                │ CursorMovedI │ WinEnter      │
                │ WinScrolled  │ WinNew        │
                │              │ WinClosed     │
                │              │ WinResized    │
                │              │ VimResized    │
                │              │ VimResume     │
                │              │ TabEnter      │
                │              │ ModeChanged   │
                │              │ CmdlineLeave  │
                ├──────────────┴───────────────┤
                │ → mark_all_dirty()           │
                │ → _force_all_dirty()         │
                └──────────────────────────────┘
```

| Path | What it sets | What tick() does |
|---|---|---|
| Hot (`mark_all_dirty`) | `p.redraw = true` | If positions match, flips `redraw` off without emitting (elision). |
| Force (`_force_all_dirty`) | `p.last_positions = nil; p.redraw = true` | Position-equality always sees "moved", so a re-emit always happens. |

The hot path is for events that happen on *every keystroke* (typing,
cursor blink) — re-emitting every time would saturate the TTY. The
force path is for events that correlate with a terminal-side compositor
wipe (mode changes, message-prompt dismissals, buffer/window/tab
shuffling, terminal resize, suspend/resume): the cell coords didn't
change, but the bytes are gone.

### Events with no autocmd (manual recovery only)

A few user actions fire **no autocmd at all**, so neither path catches
them:

- `:mode` (force-redraw command)
- `:redraw!`
- The terminal being externally cleared (e.g. another process inside the
  same TTY emitted an erase sequence)
- Hit-enter prompt dismissal on its own (no event fires; only the *next*
  user action resumes our autocmds)

For these, the manual escape hatch is **`:AltImg refresh`** /
`vim.ui.img.refresh()`. To avoid the most common case — long output
triggering nvim's hit-enter prompt — `:AltImg info` opens a scratch
buffer rather than printing, so the user dismisses the buffer with `q`
which fires `WinClosed` (in the force path).

---

## 6. How we clear

We never explicitly erase image pixels at our own initiative. The
terminal compositor is responsible for evicting old image cells when
something paints over them:

1. **Movement of a `relative=editor` float**: the float's underlying
   buffer cells are now showing what was beneath the float. Nvim's
   text-grid update writes those cells to TTY → terminal repaints →
   sixel/iTerm2 pixels at those cells get evicted.
2. **Buffer scroll for `relative=buffer`**: the line-anchored extmark's
   resolved screen coords change. Same as above for cells the image
   used to occupy.
3. **Window layout changes / resize**: nvim full-redraws the affected
   region; cell repaints evict pixels.
4. **Mode 2026 sync block** with `vim.cmd.mode()` (when `need_clear` is
   true): nvim invalidates its grid and emits a complete repaint within
   the same atomic frame as our re-emit.

`relative=ui` placements are the corner case — there's no underlying
floating window or buffer text driving cell repaints. Their clear
relies entirely on `vim.cmd.mode()` inside the sync block.

```
Clear flow inside tick() when need_clear:

  ┌─ SYNC_START ───────────────────────────────────┐
  │ vim.cmd.mode()      -- invalidate text grid    │
  │ vim.cmd("redraw")   -- flush text repaint to TTY│
  │ provider._emit_at() -- write image bytes        │
  └─ SYNC_END ─────────────────────────────────────┘

       Terminal renders the SYNC frame atomically
       (or as close to atomically as Mode 2026 supports).
```

The order matters: `redraw` MUST land before the image emit, otherwise
the text-grid bytes race past `SYNC_END` and overwrite our pixels.

---

## 7. Caching

Per-placement `state[id]` table on each provider holds the entire cache
hierarchy:

| Cache | Where | Granularity | Invalidation |
|---|---|---|---|
| `s.resized_rgba` (+ `_w`, `_h`) | iterm2.lua:84-96, sixel.lua:85-99 | one full-resize buffer | width/height change in `set()` |
| `s.full_png` + `s.full_png_b64` | iterm2.lua:108-130 | one full-image PNG + base64 | width/height change |
| `s.sixel_cache` | sixel.lua:111-143 | one full-image DCS string | width/height change |
| `s.png_cache_by_src` (LRU 64) | iterm2.lua:145-156 | per `"x,y,w,h"` cell-unit key | width/height change, LRU overflow |
| `s.sixel_cache_by_src` (LRU 64) | sixel.lua:175-186 | per `"x,y,w,h"` cell-unit key | width/height change, LRU overflow |

LRU size defaults to 64 and is configurable via
`vim.g.alt_img.crop_cache_size` (`_core/config.lua`). Each entry is one
encoded payload, well under 100KB typically.

Module-level caches:

| Cache | File:line | Lifetime |
|---|---|---|
| `_executable_cache` | util.lua:207-212 | session |
| libz FFI handle | png.lua:25-60, 708-746 | module |
| `_cell_size_queried` (CSI 16t) | util.lua:142-186 | until VimResized/UIEnter |
| `_terminal_pixel_scale_queried` | util.lua:200-260 | until VimResized/UIEnter |

Refresh (`vim.ui.img.refresh()`) does NOT invalidate any of these — it
just nulls each placement's `last_positions` so the cached payload is
re-pushed through `nvim_ui_send`. Encoding caches stay warm.

---

## 8. DPI / pixel-scale auto-detection

iTerm2 and WezTerm report cell sizes via `CSI 16t` in *logical* pixels
but render sixel at *physical* (retina) pixels. So a sixel encoded at
`32×64` cell-pixels shows up at half the requested cell area on a 2×
display. To compensate, the encoder multiplies its target pixel dims by
a "scale factor" before handing them to magick / img2sixel /
pure-Lua. The scale factor comes from two signals (max wins):

```
                     ┌─────────────────────────────┐
                     │ util.terminal_pixel_scale() │
                     └──────────────┬──────────────┘
                                    │
            ┌───────────────────────┼─────────────────────┐
            ▼                       ▼                     ▼
  ┌──────────────────┐    ┌─────────────────────┐    (max)
  │ OSC 1337 path    │    │ Geometry path       │
  │ ; ReportCellSize │    │ CSI 14t / 18t / 16t │
  │                  │    │                     │
  │ TERM_PROGRAM ∈ { │    │ derived_w =         │
  │  iTerm.app,      │    │   win_w_px / cols   │
  │  WezTerm,        │    │ ratio = derived_w / │
  │  mintty,         │    │   cell_w (CSI 16t)  │
  │  Tabby           │    │                     │
  │ } OR             │    │ if ratio ≥ 1.5:     │
  │ KONSOLE_VERSION  │    │   round(ratio)      │
  └──────────────────┘    └─────────────────────┘
       returns 0           returns 0 if everything
       on no answer        agrees; ≥1 otherwise
```

The OSC 1337 path is definitive when the terminal supports it (it
literally returns the screen scale factor as the third field of the
reply). The geometry path is the fallback for terminals that don't —
same trick `chafa` uses.

Manual override: `vim.g.alt_img.sixel_pixel_scale = N`. When set to a
number, both auto-detect signals are skipped.

The encoder pipeline only consults this for **sixel** because OSC 1337
takes width/height in cells and does its own DPI scaling internally.

---

## 9. External tool detection & dispatch

```
                     vim.g.alt_img
                          │
            ┌─────────────┼──────────────┐
            ▼             ▼              ▼
        magick       img2sixel       (libz FFI)
        / convert                     module-level,
        (string |                     decided once at
         array |                      require time
         false)
            │
   util.resolve_binary
            │
   util._executable (cached)
            │
   vim.fn.executable
```

Both magick and img2sixel are spawned via `vim.system(cmd, { stdin =
data, text = false }):wait()`. Each wraps in `pcall` so a missing tool
or non-zero exit returns nil and the caller falls through to the next
path.

Dispatch order per pipeline stage is documented in
[`README.md` § Acceleration](../README.md#acceleration); the short
version:

- **Sixel full image**: magick one-shot → pure-Lua → `img2sixel`/magick
  on the re-encoded PNG.
- **Sixel cropped**: magick one-shot (resize + crop + sixel-encode) →
  pure-Lua crop on the cached resized RGBA → re-encode dispatch.
- **Sixel raw-RGBA fast path**: only on no-libz hosts, magick reads
  RGBA from stdin and skips the PNG hop.
- **iTerm2 full image**: magick one-shot (resize + PNG re-encode) →
  pure-Lua decode + resize + encode + base64.
- **iTerm2 cropped**: magick crop on the cached resized PNG → pure-Lua
  crop + encode.

---

## 10. Provider auto-detection (`alt-img/init.lua`)

```
require("alt-img")  -- via vim.ui.img = require("alt-img")
       │
       ▼
alt-img.M.set / get / del / refresh
       │
       ▼ first call
M._provider() ──── cached ─►  iterm2 OR sixel
       │
       ▼ on miss
detect()
   │
   ├─ iterm2._supported({ timeout = 200 })   ──► fast term programs
   │     │                                       (TERM_PROGRAM in iTerm.app, WezTerm)
   │     │                                       fall back to XTVERSION probe
   │     ▼
   │   true → return iterm2 module
   │
   ├─ sixel._supported({ timeout = 200 })    ──► known sixel terms
   │     │                                       (foot, mlterm, contour, …)
   │     │                                       fall back to DA1 probe (`;4` → sixel)
   │     ▼
   │   true → return sixel module
   │
   └─ neither → error, ask user to require explicitly
```

The detect cache flips on `M._reset_provider_cache()` (test hook). In
production it persists for the session.

---

## 11. User commands

Two top-level commands, both following the lumen-oss subcommand pattern:

| Command | Source | Subcommands |
|---|---|---|
| `:AltImg` | `plugin/alt-img.lua` + `lua/alt-img/_cmd.lua` | `info`, `refresh` |
| `:AltImgTest` | `test/manual_init.lua` (smoke-test only) | `path`, `demo`, `del`, `mouse`, `provider` |

`:AltImg` is auto-loaded via the runtimepath plugin/ folder. The smoke
test (`make smoke-test`) sources the plugin file explicitly because it
launches with `--noplugin`.

Subcommand registries are tables of `{ impl = fn, complete = fn?,
desc = string }`. Dispatcher trims the leading `AltImg[!]` from the
command line, splits the remainder, routes to the impl, and delegates
completion to either subcommand-name matching or the chosen sub's
`complete` callback.

---

## 12. Mode 2026 (synchronized output)

Every emit cycle is wrapped in `\e[?2026h` … `\e[?2026l`. Honoring
terminals (iTerm2, WezTerm, Windows Terminal, foot, mlterm, kitty,
recent xterm) buffer everything between the start/end markers and apply
it as one frame, eliminating tear during the clear/repaint sequence.
Terminals that don't honor it execute the bytes as they arrive — which
is no worse than not having Mode 2026, since the order of operations
inside the block is already chosen so the final state is correct.

Nvim's own `'termsync'` option is force-disabled within the block
(restored after) so we don't double-wrap.

---

## 13. Verifying behavior

- `make test` (≈208 unit tests, no external deps) — pure-Lua + mock
  matrix.
- `make benchmark` — real-system sixel/iTerm2 timing across the
  dispatch matrix; writes `test/benchmark.out.md`.
- `make smoke-test` — interactive: `:AltImgTest demo buffer`, `:AltImg
  info`, scroll around, switch providers via `:AltImgTest provider …`.
- `:checkhealth alt-img alt-img.iterm2 alt-img.sixel` — protocol
  probes + tool detection.
- `:AltImg info` — full diagnostic dump in a scratch buffer (not
  print, so no hit-enter prompt).
