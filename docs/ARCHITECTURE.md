# alt-img.nvim architecture

> **Public API contract:** see [API.md](API.md). This document describes
> the *implementation* — schedulers, caches, autocmds — that backs the
> contract.

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
├── iterm2.lua                  -- OSC 1337 codec adapter
├── sixel.lua                   -- sixel DCS codec adapter
├── health.lua                  -- :checkhealth alt-img
├── iterm2/
│   └── health.lua              -- :checkhealth alt-img.iterm2
├── sixel/
│   ├── _encode.lua             -- pure-Lua median-cut + sixel band encoder
│   ├── _libsixel.lua           -- img2sixel binary detection / spawn
│   └── health.lua              -- :checkhealth alt-img.sixel
├── sixel/
│   ├── _chafa.lua              -- chafa subprocess for transparent-PNG sixel
│   └── …
└── _core/
    ├── provider/
    │   ├── init.lua            -- generic provider engine (state + lifecycle)
    │   └── codec.lua           -- @meta: codec interface
    ├── render.lua              -- timer + autocmds; thin coordinator
    ├── render/
    │   ├── registry.lua        -- placement table + dirty/zindex helpers
    │   ├── sync_frame.lua      -- Mode 2026 framing + two-pass emit
    │   └── types.lua           -- @meta: Position / Callbacks / Placement
    ├── carrier.lua             -- floats/extmarks for relative=editor|buffer
    ├── carrier/
    │   └── positions.lua       -- screen-position resolver
    ├── precompute.lua          -- background crop-variant warmer
    ├── activity.lua            -- last-user-activity timestamp
    ├── async.lua               -- coroutine driver for slow pure-Lua encodes
    ├── autodetect.lua          -- iterm2 vs sixel probe
    ├── cache.lua               -- on-disk encode cache (sha256-keyed, LRU-by-mtime)
    ├── cmd.lua                 -- :AltImg user-command dispatch
    ├── cell_size.lua           -- CSI 16t cell pixel-size cache
    ├── pixel_scale.lua         -- sixel logical/physical scale auto-detect
    ├── placeholder.lua         -- loading placeholder text + animation timer
    ├── clip.lua                -- viewport-clipping math
    ├── png_header.lua          -- PNG IHDR dimension parser
    ├── term_io.lua             -- nvim_ui_send wrapper
    ├── tty.lua                 -- TermResponse-based query helper
    ├── subprocess.lua          -- vim.system run / run_async helpers
    ├── magick.lua              -- magick / convert binary detection / spawn
    ├── png.lua                 -- pure-Lua PNG decode/encode + libz FFI
    ├── image.lua               -- pure-Lua RGBA resize/crop
    ├── lru.lua                 -- generic bounded LRU helpers
    ├── binary.lua              -- $PATH executable resolver
    └── config.lua              -- vim.g.alt_img reader

plugin/alt-img.lua              -- registers :AltImg, AltImgPlaceholder hl (auto-loaded)

test/                           -- automated test suite (see §15)
├── runner.lua                  -- describe/it/harness entry point
├── harness.lua                 -- spawn child nvim, msgpack-RPC + UI byte capture
├── assert.lua                  -- eq/ne/truthy/lt/gte/match/contains/fails/near
├── unit/**                     -- in-process module tests
└── e2e/**                      -- spawn-per-block black-box tests
```

The `_core/` modules are private. Callers come from `init.lua`,
`iterm2.lua`, `sixel.lua`, or the user command. The two provider modules
and the dispatcher (`init.lua`) export the public `set/get/del/_supported`
surface (see [API.md](API.md)). `init.lua` additionally exposes
`provider()` (returns the autodetect-resolved provider) for `:checkhealth`
and `:AltImg info`.

---

## 2. Component interaction

```
                user-code
                    │ vim.ui.img.set/get/del
                    ▼
   ┌──────────────────────────────────────┐
   │ provider module                       │
   │   alt-img / alt-img.iterm2 / alt-img.sixel
   │   (exports set/get/del/_supported)    │
   └────────────────┬─────────────────────┘
                    │ delegates to
                    ▼
   ┌──────────────────────────────────────┐
   │ _core/provider engine                 │
   │   • state[id] = { data, opts,         │
   │                   codec_state }       │
   │   • canonicalize / derive_dims        │
   │   • build_at / emit_at framing        │
   │   • carrier + render + precompute     │
   │     orchestration                     │
   │   • VimLeavePre cleanup autocmd       │
   └──────┬─────────────────────┬─────────┘
          │ codec.encode_*       │ register +
          │ codec.probe          │ get_pos closure
          ▼                       │
  ┌────────────────────┐          ▼
  │ codec adapter      │   ┌────────────────────┐
  │ (iterm2.lua /      │   │ _core/render        │
  │  sixel.lua)        │   │  registry + tick +  │
  │  • OSC 1337 / DCS  │   │  Mode 2026 emitter  │
  │    framing         │   └─────────┬──────────┘
  │  • per-codec cache │             │
  │    (resized RGBA,  │   ┌─────────┴──────────┐
  │    full PNG/sixel, │   │ _core/carrier       │
  │    crop LRU)       │   │  • floats / extmark │
  │  • probe sequences │   │  • positions.resolve_*
  └────────────────────┘   └────────────────────┘
                                     │
                                     ▼
                            term_io.send
                            (= nvim_ui_send)
                                     │
                                     ▼
                              terminal
                       (sixel / OSC 1337)
```

Encoders sit beneath the codec adapter:

```
codec adapter ──► magick.lua / sixel/_libsixel.lua  (subprocess via subprocess.run*)
              └► png.lua / image.lua / sixel/_encode.lua  (pure-Lua path)
```

---

## 3. Public API contract

The full contract is in [API.md](API.md). In brief:

| Function | Description |
|---|---|
| `set(data\|id, opts)` | Register or update a placement. `data` is PNG bytes; `opts` are cell-coords + relative kind. Returns the placement id. |
| `get(id)` | Return the canonical opts for an existing placement, or nil. |
| `del(id)` | Delete one placement. `del(math.huge)` deletes everything. |
| `_supported(opts)` | `@private`. Sync probe of whether the current terminal supports this provider. Used by autodetect and `:checkhealth`. |

`init.lua` (the autodetect dispatcher) additionally exposes `provider()`,
returning the resolved provider table. It's not part of the upstream
`vim.ui.img` surface — only `:checkhealth alt-img` and `:AltImg info`
call it.

The codec adapters (`iterm2.lua`, `sixel.lua`) also expose `placements()`
returning `{ [id] = opts }` for the diagnostic dump. Same justification.

Everything else — `emit_at`, `build_at`, `precompute_async`, the engine's
`state` table, the render timer, dirty-flag helpers — is closure-local in
the engine or file-local in the codec adapter. None of it appears on the
returned module table.

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
  ├─► state[id] = { data, opts, codec_state = {} }          │
  ├─► carrier.register(provider, id, opts)                  │
  │     │                                                    │
  │     ├─► relative = editor   → nvim_open_win (0×0 float)  │
  │     ├─► relative = buffer   → nvim_buf_set_extmark + virt_lines
  │     └─► relative = ui       → no carrier (anchor is screen coords)
  │                                                         │
  ├─► render.register(s, id, get_pos_for(id), { emit_at, build_at, get_opts })
  └─► render.flush()    -- run a tick synchronously          │
                            │                                │
                            ▼                                │
                       tick()  (in _core/render.lua)         │
                            │                                │
        ┌───────────────────┼───────────────────┐            │
        │  for p in registry.all():              │           │
        │      positions = p.get_pos() or {}     │           │
        │      p.next_positions = positions      │           │
        │      if positions ≠ last OR force:     │           │
        │          need_clear = true             │           │
        │          initially_dirty[++] = p       │           │
        │      elif p.redraw:                    │           │
        │          p.redraw = false  ←── ELISION │           │
        │                                                    │
        │  if nothing dirty AND no need_clear: return        │
        │                                                    │
        │  emit_set = need_clear ? all : initially_dirty     │
        │  registry.sort_by_zindex(emit_set)                 │
        └────────────────────┬───────────────────┘           │
                             ▼                                │
              sync_frame.emit(emit_set, need_clear)           │
                             │                                │
              Pass 1 (OUTSIDE sync, may yield on cache miss): │
                payloads = [ build_at(p, pos) for each p, pos ]
                p.last_positions = p.next_positions           │
                p.redraw = false                              │
                                                              │
              Pass 2 — Mode 2026 sync block:                  │
                term_io.send( "\e[?2026h" )       ──────────► │
                if need_clear: vim.cmd.mode()                 │
                  -- :mode → ex_redraw → update_screen +      │
                  --   ui_flush, so the grid clear+repaint    │
                  --   bytes hit the TTY inside this sync     │
                  --   frame, before any image bytes below    │
                for bytes in payloads:                        │
                    term_io.send(bytes)              ───────► │
                term_io.send( "\e[?2026l" )       ──────────► │
                                                              ▼
                                                    pixels paint
```

### Position-equality elision

The dirty scan distinguishes "marked dirty but didn't actually move" from
real movement. Typing fires `CursorMoved`/`TextChanged` on every keystroke;
without the elision we'd push the entire sixel/OSC payload through
`nvim_ui_send` per keystroke. With it, those autocmds are a no-op when the
placement's resolved screen position hasn't changed.

The elision is what makes the force-dirty path (§5) necessary — some
events imply the terminal compositor has wiped image cells without our
cell-coords changing.

---

## 5. Dirty events: when and how we re-emit

Three autocmd groups in `_core/render.lua`, all routing through the
registry's flag helpers:

```
                ┌────────────────────────────────────────────┐
                │ alt-img.render augroup                     │
                ├──────────────┬────────────┬────────────────┤
                │ HOT PATH     │ SYNC PATH  │ FORCE PATH     │
                │ (timer)      │ (immediate │ (timer)        │
                │              │  emit)     │                │
                │ TextChanged  │ WinScrolled BufEnter        │
                │ TextChangedI │            │ BufWinEnter    │
                │ CursorMoved  │            │ BufWritePost   │
                │ CursorMovedI │            │ WinEnter       │
                │              │            │ WinNew         │
                │              │            │ WinClosed      │
                │              │            │ WinResized     │
                │              │            │ VimResized     │
                │              │            │ VimResume      │
                │              │            │ TabEnter       │
                │              │            │ ModeChanged    │
                │              │            │ CmdlineLeave   │
                │              │            │ FocusGained    │
                │              │            │ FocusLost      │
                ├──────────────┼────────────┼────────────────┤
                │ → registry.  │ → registry.│ → registry.    │
                │   mark_all_  │   force_   │   force_all_   │
                │   dirty()    │   all_     │   dirty()      │
                │              │   dirty_   │                │
                │              │   with_    │                │
                │              │   position_│                │
                │              │   reset()  │                │
                │              │ + sync_    │                │
                │              │   frame.   │                │
                │              │   emit_    │                │
                │              │   force_   │                │
                │              │   resolve()│                │
                └──────────────┴────────────┴────────────────┘
```

| Path | What it sets | What tick() does |
|---|---|---|
| Hot | `p.redraw = true` | If positions match, flips `redraw` off without emitting (elision). |
| Sync | nulls `last_positions`, sets `force_redraw + redraw`, then runs an immediate emit | Re-emit synchronously inside the autocmd so the SYNC frame closes before nvim's post-autocmd flush. |
| Force | `force_redraw = true; redraw = true` (preserves `last_positions`) | Position-equality always sees "moved" via `force_redraw`, so a re-emit always happens. |

The hot path is for events that fire on *every keystroke* — re-emitting
every time would saturate the TTY. The sync path is the per-row blink
fix: `WinScrolled` correlates with nvim repainting cells the float /
buffer image used to occupy, evicting the corresponding terminal-side
pixels; doing the re-emit synchronously (instead of waiting up to 30 ms
for the next timer tick) keeps the scroll repaint and our image emit
inside one atomic Mode 2026 frame from the terminal's POV. The force
path is for events that correlate with a terminal-side compositor wipe
(mode changes, message-prompt dismissals, buffer/window/tab shuffling,
terminal resize, suspend/resume, macOS Space switching via FocusGained/
FocusLost): the cell coords didn't change, but the bytes are gone.

### Events with no autocmd (manual recovery only)

A few user actions fire **no autocmd at all**, so neither path catches
them:

- `:mode` (force-redraw command)
- `:redraw!`
- The terminal being externally cleared (e.g. another process inside the
  same TTY emitted an erase sequence)
- Hit-enter prompt dismissal on its own (no event fires; only the *next*
  user action resumes our autocmds)

For these, the manual escape hatch is **`:AltImg refresh`**, which calls
`render.refresh()` internally. To avoid the most common case — long
output triggering nvim's hit-enter prompt — `:AltImg info` opens a
scratch buffer rather than printing, so dismissing it with `q` fires
`WinClosed` (in the force path).

---

## 6. How we clear

We never explicitly erase image pixels at our own initiative. The terminal
compositor is responsible for evicting old image cells when something
paints over them:

1. **`relative=editor` float move**: the float's underlying buffer cells
   now show what was beneath the float. Nvim's text-grid update writes
   those cells to TTY → terminal repaints → sixel/iTerm2 pixels at those
   cells get evicted.
2. **Buffer scroll for `relative=buffer`**: the line-anchored extmark's
   resolved screen coords change. Same as above for cells the image used
   to occupy.
3. **Window layout changes / resize**: nvim full-redraws the affected
   region; cell repaints evict pixels.
4. **Mode 2026 sync block** with `vim.cmd.mode()` (when `need_clear` is
   true): nvim invalidates its grid and emits a complete repaint within
   the same atomic frame as our re-emit.

`relative=ui` placements are the corner case — there's no underlying
floating window or buffer text driving cell repaints. Their clear relies
entirely on `vim.cmd.mode()` inside the sync block.

```
Clear flow inside sync_frame.emit() when need_clear:

  Pass 1 (outside sync): callbacks.build_at(id, pos) -> bytes
                         (cache misses can spawn magick / img2sixel,
                          which yield the event loop — fine here)

  Pass 2:
  ┌─ SYNC_START ───────────────────────────────────┐
  │ vim.cmd.mode()       -- invalidate text grid   │
  │                         AND flush via ex_redraw│
  │ for bytes in payloads: term_io.send(bytes)     │
  │   (no subprocess spawns, no event-loop yields) │
  └─ SYNC_END ─────────────────────────────────────┘

       Terminal renders the SYNC frame atomically
       (or as close to atomically as Mode 2026 supports).
```

Splitting the build (Pass 1) from the emit (Pass 2) means a cache miss
that has to spawn `magick`/`img2sixel` for cropped / resized output yields
the event loop *outside* the SYNC frame. Inside the frame would risk the
terminal timing the sync block out and rendering an intermediate state.

`:mode` itself already triggers `update_screen()` + `ui_flush()` in Neovim
(`src/nvim/ex_docmd.c:ex_mode`), so the grid clear+repaint bytes land in
the TTY buffer before our image bytes — no separate `vim.cmd.redraw()`
call is needed inside the sync frame.

The order still matters: the grid bytes from `mode()` MUST land before
the image emit, otherwise the text-grid output would race past `SYNC_END`
and overwrite our pixels. `:mode`'s built-in flush is what guarantees that.

---

## 7. Caching

Cache lives in **three** layers — in-memory per-placement, in-memory
module-level, and on-disk:

```
                           set(data, opts)
                                 │
             ┌───────────────────┼───────────────────┐
             ▼                   ▼                   ▼
   ┌───────────────────┐  ┌──────────────┐  ┌───────────────────┐
   │ L1 per-placement  │  │ L2 module    │  │ L3 on-disk cache  │
   │ state[id].codec_  │  │ binary       │  │ stdpath('cache')/ │
   │ state.{...}       │  │ resolution,  │  │ alt-img/<key>.png │
   │ • full RGBA       │  │ libz FFI,    │  │ alt-img/<key>.sixel│
   │ • full PNG/sixel  │  │ probes       │  │ • full + crop     │
   │ • crop LRU        │  │              │  │ • survives session│
   │                   │  │              │  │   restart         │
   └─────────┬─────────┘  └──────────────┘  └─────────┬─────────┘
             │ miss                                   │ miss
             └───────────────► encode pipeline ◄──────┘
                                  │
                                  ▼
                          (subprocess or pure-Lua;
                           write-through to L1+L3)
```

**L1 — engine-owned per-placement record** (closure-local to
`_core/provider/init.lua`): `state[id] = { data, opts, codec_state }`.
The engine never inspects `codec_state`; it just hands the placement
to the codec on every call.

| Cache | Codec | Granularity | Invalidation |
|---|---|---|---|
| `cs.resized_rgba` (+ `_w`, `_h`) | iterm2 / sixel | one full-resize buffer | width/height change → `codec.invalidate(state)` |
| `cs.full_png` + `cs.full_png_b64` | iterm2 | one full-image PNG + base64 | width/height change |
| `cs.full_sixel` | sixel | one full-image DCS string | width/height change |
| `cs.crop_cache` (LRU) | both | per `"x,y,w,h"` cell-unit key | width/height change, LRU overflow |

LRU size is auto-derived per placement from `opts.height` via
`_core/precompute.required_lru_size()` — `2 * (height - 1)` (the exact
precompute output count) with a 64-entry floor. That makes the LRU
lossless against the precompute warm-up regardless of image size; tiny
placements stay small, very tall placements scale up. Each entry is
one encoded payload, well under 100 KB typically.

**L2 — module-level caches:**

| Cache | Module | Lifetime |
|---|---|---|
| `_executable_cache` | `_core/binary.lua` | session |
| libz FFI handles | `_core/png.lua` | module load |
| cell pixel size (CSI 16t) | `_core/cell_size.lua` | until VimResized/UIEnter |
| terminal pixel scale | `_core/pixel_scale.lua` | until VimResized/UIEnter |
| autodetect probe results | `_core/autodetect.lua` | session |

**L3 — on-disk encode cache** (`_core/cache.lua`):

Sixel DCS strings and resized/cropped PNGs are persisted under
`stdpath('cache')/alt-img/`. The cache key is
`sha256(input_sha | WxH | crop_rect)`, where `crop_rect` is `"full"` or
`"x,y,w,h"` in post-scale pixels. Encoder choice is intentionally NOT in
the key — DCS / PNG output is valid regardless of which encoder produced
it; the read side trusts what's there. Same image at the same dims hits
the cache **across nvim sessions, machines (if you sync the dir), and
between encoder paths within a codec**. The two codecs use disjoint
extensions (`.png` for iterm2, `.sixel` for sixel) so they don't read
each other's payloads.

```
   key = sha256( input-png-sha | WxH | crop_rect )
                                              │
                                              ▼
   <stdpath('cache')>/alt-img/<key>.png        ← iterm2 codec
                              <key>.sixel      ← sixel codec
   (flat layout — one directory, one file per cache entry)
```

Writes are atomic via `tmp + rename`. Eviction: write-side enforces
`max_bytes` (default 500 MB) by deleting oldest-mtime entries until under
the cap. Read-side optionally drops entries older than `max_age_days`
(no-op when nil).

Knobs (under `vim.g.alt_img.cache`): `enabled`, `dir`, `max_bytes`,
`max_age_days`. Per-process disable via `require('alt-img').cache.disable()`
without touching config or the on-disk state.

`:AltImg refresh` (→ `render.refresh()`) does NOT invalidate any of these
— it just nulls each placement's `last_positions` so the cached payload
is re-pushed through `nvim_ui_send`. Encoding caches stay warm.

---

## 8. DPI / pixel-scale auto-detection

iTerm2 and WezTerm report cell sizes via `CSI 16t` in *logical* pixels but
render sixel at *physical* (retina) pixels. So a sixel encoded at `32×64`
cell-pixels shows up at half the requested cell area on a 2× display. To
compensate, the sixel codec multiplies its target pixel dims by a "scale
factor" before handing them to magick / img2sixel / pure-Lua. The scale
factor comes from two signals (max wins):

```
                     ┌─────────────────────────────┐
                     │ pixel_scale.current()       │
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

**Fast-path short-circuit:** `pixel_scale.current()` checks `WT_SESSION`
(Windows Terminal) before any TTY round-trip and returns scale=1
immediately — Windows Terminal already reports cell pixel sizes in
*physical* pixels via CSI 16t, so there's no logical/physical split to
recover. Skipping the OSC 1337 + CSI 14t/18t probes here saves ~700 ms
of timeout-bound waiting on the first `set()`. The iterm2 codec's
`_supported()` probe (`iterm2.lua:probe`) has the same short-circuit:
Windows Terminal doesn't implement OSC 1337 inline images, so the
XTVERSION probe always times out — short-circuiting returns `false`
immediately so autodetect falls through to sixel.

**Derive-dims uses pixel_scale too.** When a caller omits `width`/`height`
in `set()`, `_core/provider/init.lua:derive_dims` computes cell-coords as
`ceil(image_px / (cell_w * pixel_scale))`. Without the multiplication,
retina iTerm2/WezTerm sixel placements come out 2× the requested cell
area because the codec re-multiplies on the way out.

The encoder pipeline only consults this for **sixel** — OSC 1337 takes
width/height in cells and does its own DPI scaling internally. But the
derive_dims fix above runs for both providers so the cell-coords are
provider-agnostic.

---

## 9. External tool acceleration

alt-img picks the cheapest available path per stage. External-tool
detection runs once per session and is cached. Disable any tool by
setting its config to anything falsy (`false` / `nil` / `{}`);
everything has a pure-Lua fallback.

```
                     vim.g.alt_img
                          │
       ┌─────────┬────────┼────────┬──────────┐
       ▼         ▼        ▼        ▼          ▼
   magick    img2sixel  chafa    libz       (cache.lua
   / convert            (sixel,  (FFI,       on-disk;
   (string |            transp.) module      see §7)
    array |             PNGs)    load-time)
    falsy)
       │
   _core/binary.resolve(cfg)
       │   • string  → resolve once
       │   • array   → first executable wins
       │   • falsy   → disabled
       ▼
   vim.fn.executable (cached)
```

magick and img2sixel are spawned via `_core/subprocess.run` /
`run_async`, both wrapping `vim.system` with a single `vim.notify_once`
debug surface and pcall protection. A missing tool or non-zero exit
returns nil and the caller falls through to the next path.

### Sixel provider (`require('alt-img.sixel')`)

| Stage | Preferred | Fallback 1 | Fallback 2 | Last resort | Notes |
|---|---|---|---|---|---|
| Full image (when `chafa` present) | `magick`-resize → `chafa` (`--format=sixels --exact-size=on --polite=on --colors=240`) | next row | — | — | Two-subprocess chain (chafa cannot pixel-resize on its own). Always tried first when `chafa` is detected because it's the only encoder that preserves PNG alpha — transparent pixels stay un-set in the output bands and the introducer is emitted with `P2=1`. |
| Full image (decode + resize + sixel-encode) | `magick` one-shot (`-sample WxH! sixel:-`) | (no libsixel one-shot for full image; falls through to pure-Lua chain) | — | pure-Lua decode → resize → quantize → encode | One subprocess, no PNG hop. Biggest single win on hosts without libz. |
| Cropped sub-rect (chafa branch) | `magick`-resize-crop → `chafa` | next row | — | — | Same two-subprocess chain as full; chafa has no crop support so magick is mandatory. |
| Cropped sub-rect | `magick` one-shot (`-sample WxH! -crop WxH+X+Y sixel:-`) | pure-Lua resize → crop → encode | — | — | Pure-Lua crop is just `string.sub` per row; the cost is the encode. |
| RGBA → sixel (no libz) | `magick` raw-RGBA (`-size WxH -depth 8 RGBA:-`) | pure-Lua quantize + encode | — | — | Skips the expensive PNG-encode hop on no-libz hosts. `img2sixel` has no raw-input mode, so it isn't tried in this branch. |
| RGBA → PNG → sixel (with libz) | `img2sixel` | `magick` PNG path | pure-Lua | — | `img2sixel` is preferred when both are present and libz is available. |
| PNG decode | libz `uncompress` (FFI) | pure-Lua INFLATE | — | — | Pure-Lua INFLATE is the slowest single component when libz is missing. |
| PNG encode | libz `compress2` (FFI) | uncompressed stored blocks | — | — | Stored-block output is ~4× the raw RGBA size; the no-libz raw-RGBA branch above exists to avoid this. |
| RGBA resize / crop | pure Lua (`string.sub` + `table.concat`) | — | — | — | Always fast enough not to need an external tool. |

The L3 disk cache (§7) intercepts the *output* of these stages, so a
warm cache hits before any encoder runs.

### iTerm2 provider (`require('alt-img.iterm2')`)

| Stage | Preferred | Fallback | Notes |
|---|---|---|---|
| Full image (decode + resize + PNG re-encode) | `magick` one-shot (`-sample WxH! png:-`) | pure-Lua decode → resize → encode | iTerm2 receives image-pixels == cell-pixels so its own scaler is a no-op (sharp output). |
| Cropped sub-rect | `magick` one-shot (`-crop WxH+X+Y png:-`) on the cached resized PNG | pure-Lua crop → encode | Crop runs against the resized PNG, not the original — keeps output identical to the pure-Lua path. |
| Base64 of payload | `vim.base64.encode` (built-in) | — | Result cached alongside the PNG. |

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

---

## 10. Provider auto-detection (`_core/autodetect.lua`)

```
require("alt-img")  -- via vim.ui.img = require("alt-img")
       │
       ▼
init.M.set / get / del   (forwarder: resolves provider on first call)
       │
       ▼ first call
autodetect.matches() ──── cached ─►  iterm2 OR sixel
       │
       ▼ on miss
matches()
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
   └─ neither → init.lua's get_instance() asserts and errors
```

The match cache is a file-local in `_core/autodetect.lua` and persists
for the session. The candidate list and probe order come from
`vim.g.alt_img.autodetect` (default `{ "iterm2", "sixel" }`); pin a
protocol by setting it to a single-entry list.

---

## 11. User commands

| Command | Source | Subcommands |
|---|---|---|
| `:AltImg` | `plugin/alt-img.lua` + `lua/alt-img/_core/cmd.lua` | `info`, `refresh`, `cache {stats\|clear [days]\|path}` |
| `:AltImgTest` | `test/manual_init.lua` (smoke-test only) | `path`, `demo`, `del`, `mouse`, `provider`, `placeholder` |

`:AltImg` is auto-loaded via the runtimepath `plugin/` folder. The smoke
test (`make smoke-test`) sources the plugin file explicitly because it
launches with `--noplugin`.

Subcommand registries are tables of `{ impl = fn, complete = fn?, desc = string }`.
Dispatcher trims the leading `AltImg[!]` from the command line, splits the
remainder, routes to the impl, and delegates completion to either
subcommand-name matching or the chosen sub's `complete` callback.

---

## 12. Mode 2026 (synchronized output)

Every emit cycle is wrapped in `\e[?2026h` … `\e[?2026l`. Honoring
terminals (iTerm2, WezTerm, Windows Terminal, foot, mlterm, kitty, recent
xterm) buffer everything between the start/end markers and apply it as
one frame, eliminating tear during the clear/repaint sequence. Terminals
that don't honor it execute the bytes as they arrive — no worse than not
having Mode 2026, since the in-block order of operations is already
chosen so the final state is correct.

Nvim's own `'termsync'` option is force-disabled within the block
(restored after) so we don't double-wrap.

---

## 13. Loading placeholders

When the codec has no fast path available (no `magick`, no `img2sixel`, no
`chafa`, no libz, and the disk cache is cold), `codec.encode_full` falls
back to the pure-Lua INFLATE → resize → quantize → sixel-encode pipeline
which can take seconds. The engine routes those calls through
`_core/async.lua` so the main event loop stays responsive.

```
provider.set(data, opts)
       │
       ▼
codec.has_cached_full(s)? ─── true ──► render.flush()  (existing sync path)
       │
       false
       ▼
state[id].codec_state.encode_handle = async.run(
    function() return codec.encode_full(s) end,    -- pure-Lua hot loops
    on_progress = …                                --   yield via
                  cs.encode_progress = p,          --   async.maybe_yield()
                  placeholder.update(provider, id, p),
    on_done     = on_encode_done(id, bytes, err))
       │
       ▼
vim.defer_fn(placeholder.delay_ms, function()
    if state[id] and state[id].codec_state.encode_handle == handle then
        placeholder.show(provider, id, opts)        -- box + spinner
    end
end)
       │
       │ (set() returns immediately)
       ▼
on_encode_done(id, bytes, err):
    if err: placeholder.set_errored(provider, id) ; vim.notify_once
    else:   placeholder.hide(provider, id)
            render.invalidate + render.flush         -- image bytes emit
```

Yield checkpoints inside the encoder hot loops:

| Stage | Cadence |
|---|---|
| `_core/png.lua` `inflate` | per deflate block |
| `_core/image.lua` `resize` | every 32 output rows |
| `sixel/_encode.lua` median-cut | per split iteration |
| `sixel/_encode.lua` band emit | per 6-row band |

Each checkpoint calls `async.maybe_yield(progress)` which yields only
when `coroutine.running()` is non-nil — synchronous callers (precompute
warmer fallback, smoke tests) take the same path with no yield overhead.

`build_at` short-circuits to `nil` while `cs.encode_handle` is set, so any
render tick that fires during a load is a no-op for that placement (no
duplicate sync encode).

Placeholder rendering is owned by `_core/placeholder.lua`:
- `show(provider, id, opts)` writes box + spinner lines into the carrier
  (`relative=editor` → existing float buffer, `relative=buffer` →
  `virt_lines` on the existing extmark, `relative=ui` → a new transient
  float opened by `carrier.register_ui_placeholder`).
- A single shared `vim.uv.new_timer` advances spinner glyphs every
  `spinner_interval_ms` (default 120 ms) across all loading placements.
- `update(provider, id, progress)` stashes phase/done/total for the
  next animation tick to compute the weighted percent caption.
- `hide(provider, id)` clears the carrier text (closes transient ui float,
  resets virt_lines, clears float buffer).
- `set_errored(provider, id)` flips the entry's caption to `! error` and
  freezes the spinner.

Position tracking during loading: `_core/render.lua`'s tick passes
`positions` to an optional `notify_positions` callback on each placement's
callbacks table; the engine's `set()` wires this to call
`placeholder.reposition(provider, id, positions)`. For `editor`/`buffer`
the placeholder text moves with its carrier (extmark, float window) for
free; for `ui` the call resizes/reposition the transient float via
`nvim_win_set_config`.

The whole subsystem is gated by `vim.g.alt_img.placeholder.enabled`. With
it disabled, async encoding still happens (slow paths still don't block);
only the visible box+spinner is suppressed.

---

## 14. Verifying behavior

- `make test` / `make test-unit` / `make test-e2e` — automated suite (§15).
- `make smoke-test` — interactive: launches nvim with `manual_init.lua`,
  then `:AltImgTest demo {ui|editor|buffer}`, `:AltImg info`, scroll
  around, switch providers via `:AltImgTest provider …`.
- `make format-check` — stylua format gate.
- `make lint` — guards the public surface (`_supported` is the only
  underscore export allowed on init/iterm2/sixel).
- `make verify-api` — diffs pinned upstream `vim.ui.img` SHAs in
  `~/projects/neovim` against API.md.
- `:checkhealth alt-img alt-img.iterm2 alt-img.sixel` — protocol probes
  + tool detection.
- `:AltImg info` — full diagnostic dump in a scratch buffer (not print,
  so no hit-enter prompt).

---

## 15. Automated test architecture

The suite has two tiers — **unit** (in-process) and **e2e** (spawn child
nvim per block) — discovered and driven by a single runner.

```
   make test
        │
        ▼
   nvim --headless -l test/runner.lua [filter] [--unit|--e2e]
        │
        │  setfenv-injected globals: describe, it, harness, assert
        │
        ▼
   discover test/unit/**.lua + test/e2e/**.lua
        │
        ▼
   collect blocks: { suite, type='it'|'harness', name, fn }
        │
        ▼
   filter (lua-pattern over "suite:name") → execute → report timing
```

**Unit (`test/unit/**`, `it()` blocks)** — exercise pure modules
in-process (async driver, placeholder compose, png libz config). Fast,
no child nvim, no event loop dependence beyond the parent's.

**E2E (`test/e2e/**`, `harness()` blocks)** — spawn a fresh headless
child nvim per block, drive it via msgpack-RPC, observe black-box.

```
                   parent nvim (runner)
                          │
                          │  ctx:spawn({ provider='sixel', config=… })
                          ▼
                   harness.spawn(opts)
                          │
                          ├─► fork child:
                          │     nvim --headless --noplugin --clean
                          │          --listen <tempname>.sock
                          │          --cmd "lua <init>"
                          │
                          │  init template:
                          │    rtp prepend $cwd
                          │    vim.g.alt_img = <merged config>
                          │    monkey-patch nvim_ui_send → push bytes
                          │      onto _G.__alt_img_test_ui_bytes
                          │    source plugin/alt-img.lua
                          │    vim.ui.img = require(<provider_mod>)
                          │
                          ├─► wait for socket → sockconnect("pipe", …, rpc=true)
                          │
                          ▼
                  test.Nvim handle
                  ┌──────────────────────────────────┐
                  │ :lua(code, ...)                  │  exec_lua
                  │ :lua_eval(expr)                  │  exec_lua "return …"
                  │ :command(cmd)                    │  nvim_command
                  │ :input(keys)                     │  nvim_input
                  │ :wait_until(pred, opts)          │  poll w/ timeout
                  │ :captured_ui_bytes()             │  read the global table
                  │ :reset_captured()                │
                  │ :placeholder_visible_in_buffer() │  scan extmarks
                  │ :placeholder_visible_in_float()  │  scan float bufs
                  │ :placeholder_visible()           │  either
                  │ :close()                         │  qa! → chanclose → jobwait
                  └──────────────────────────────────┘
```

### Black-box observation only

A test is allowed to:

- Drive the public `vim.ui.img.set / get / del` API
- Read `vim.api.nvim_buf_get_extmarks` and `nvim_list_wins` to detect
  rendered carriers (placeholder lifecycle test does this)
- Read `_G.__alt_img_test_ui_bytes` — the only test-side hook, a
  one-line monkey-patch of `vim.api.nvim_ui_send` in the child's init.
  Production code is unchanged.

A test is NOT allowed to:

- Add `_*` test hooks to production modules
- Inspect engine state directly (`provider.state`, `state[id]…`)
- Bypass the codec adapter to call internal `_core/*` functions

### Headless-friendly config defaults

The harness's default `vim.g.alt_img` includes `cell_pixel_size = { 8, 16 }`
and `sixel_pixel_scale = 2` so e2e blocks don't pay ~600 ms of CSI 16t /
OSC 1337 / CSI 14t timeouts on each spawn. Tests can override either via
the per-block config table. Provider autodetect can't probe a real
terminal in headless mode either, so each `harness()` block pins
`provider = "sixel"` (or `"iterm2"`).

### Graceful child shutdown

`Nvim:close()` runs `:qa!` via rpcrequest, swallows the expected channel
close, then `jobwait` for 500 ms before falling back to `jobstop`. This
keeps the suite quiet — a `jobstop`-driven SIGTERM exit prints to the
parent's stderr and looks like a test failure even when nothing went
wrong.

### Layout

- `test/runner.lua` — discovery + dispatch + reporting (~150 LOC)
- `test/harness.lua` — `Nvim` handle + spawn (~235 LOC)
- `test/assert.lua` — `eq`/`ne`/`truthy`/`falsy`/`gte`/`lte`/`gt`/`lt`/
  `match`/`contains`/`fails`/`near` (~100 LOC)
- `test/unit/**` — async driver, placeholder compose, png libz config
- `test/e2e/**` — harness spike, `set()` returns immediately on slow
  path, placeholder lifecycle (5 blocks)
- `test/fixtures/` — small PNG inputs

`FILTER='lua-pattern'` narrows any target — matched against
`suite_name:block_name`.
