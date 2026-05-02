# iTerm2 OSC 1337 image protocol

What the `alt-img.iterm2` provider emits, why, and how the encoder pipeline
produces it. For the surrounding scheduler / cache / autocmd architecture see
[`ARCHITECTURE.md`](ARCHITECTURE.md).

---

## 1. Protocol overview

iTerm2's "Inline Images Protocol" (also implemented by WezTerm) uses an
[`OSC` (Operating System Command)] dispatch under verb `1337`:

```
ESC ] 1337 ; File = <key>=<val> [ ; <key>=<val> ]* : <base64-PNG>  BEL
```

Where:

- `<key>=<val>` pairs configure how the terminal renders the image.
- The colon (`:`) separates the param block from the payload.
- Payload is base64-encoded image bytes (we always emit PNG).
- Terminator is `BEL` (`\a`, `0x07`); some implementations also accept the
  ST (`ESC \`).

We use exactly four params: `size`, `inline`, `width`, `height`,
`preserveAspectRatio`. Example for a 4-cell × 4-cell placement:

```
\e]1337;File=size=512;inline=1;width=4;height=4;preserveAspectRatio=0:iVBORw0KGgo…\a
```

`size` is the byte count of the (un-base64'd) payload. `width` and
`height` are in **cell units** by default (the protocol allows `Npx`,
`Npx`, `auto`, percentages — we don't use those because we always do the
cell-pixel resize ourselves; see §5). `preserveAspectRatio=0` tells iTerm2
to stretch our PNG to fill the cell area exactly — we feed a PNG already
sized at `width × cell_w_px` × `height × cell_h_px`, so the stretch is a
no-op and the output is pixel-perfect.

We do **not** use `name=`, `type=`, or any extension fields.

---

## 2. Detection

`iterm2.lua:_supported(opts)` decides whether the running terminal can
display OSC 1337 images. Two signals:

```
                      _supported(opts)
                            │
              TERM_PROGRAM ∈ {iTerm.app, WezTerm}
                  ↓ yes               ↓ no
              return true              │
                                       ▼
                          XTVERSION query (CSI > q)
                              ESC [ > 0 q
                              │
                          TermResponse contains
                          "iTerm2" or "WezTerm"?
                              ↓ yes        ↓ no
                          return true    return false
```

The XTVERSION probe is the fallback path for iTerm2 builds that don't
expose `TERM_PROGRAM` (rare; e.g. when launched from a shell wrapper
that strips the env). Probe timeout defaults to 1000ms; smoke test uses
200ms.

The autodetect dispatcher (`alt-img/init.lua`) tries iterm2 before
sixel, so on iTerm2.app and WezTerm the iterm2 provider is the default
even though those terminals also support sixel.

---

## 3. Encoding pipeline

```
            user-supplied PNG bytes  (validated at boundary)
                     │
                     ▼
               provider.set
                     │
                     ▼
            ensure_full_png(state)
            ┌──────────────────────────────────────────┐
            │ if cache hit (s.full_png): return        │
            │                                          │
            │ if magick on PATH AND opts.width/height: │
            │     ┌──────────────────────────────────┐ │
            │     │ magick - -sample WxH! png:-      │ │
            │     │   one subprocess does decode +   │ │
            │     │   nearest-neighbor resize +      │ │
            │     │   PNG re-encode                  │ │
            │     └──────────────────────────────────┘ │
            │     out + base64 → cache; return         │
            │                                          │
            │ pure-Lua fallback:                       │
            │   ensure_resized(state)                  │
            │     ┌────────────────────────────────┐   │
            │     │ png.decode → image.resize      │   │
            │     │   (FFI memcpy; nearest-neighbor)│  │
            │     └────────────────────────────────┘   │
            │   png.encode  (libz or stored blocks)    │
            │   base64 (built-in vim.base64.encode)    │
            └──────────────────────────────────────────┘
                     │
                     ▼
               s.full_png + s.full_png_b64
                     │
                     ▼
            _emit_at builds OSC 1337 payload + cursor
            save/hide/restore around the move
                     │
                     ▼
             util.term_send (= nvim_ui_send)
                     │
                     ▼
                 iTerm2 / WezTerm
```

Cropped placements (when only part of the image is visible due to
window clipping) follow the same flow but call `build_png_cropped`
instead — magick crops the cached resized PNG via `magick - -crop
WxH+X+Y png:-`, falling back to pure-Lua `image.crop_rgba` +
`png.encode`.

---

## 4. Why we resize ourselves

The PNG bytes the user hands us could be any pixel size. iTerm2 will
gladly stretch arbitrary-size PNGs to fit the requested cell area, but
its scaler is bilinear — at small sizes that produces a blurry result.

By resizing the PNG to *exactly* `opts.width × cell_w` × `opts.height ×
cell_h` pixels before sending, iTerm2's stretch becomes a no-op and the
final pixels are whatever our nearest-neighbor resize produced. Crisp
1:1 cell-pixel mapping for the typical case (small UI images).

`-sample` (nearest neighbor) is the magick equivalent of our pure-Lua
`image.resize`. We deliberately avoid `-resize` because that's Lanczos
which smooths, and the two paths must produce visually identical output
(otherwise toggling magick on/off changes how images look).

The trade-off: source images larger than the cell area get downsampled
without smoothing → mild aliasing. For the small-image use case this
isn't visible; if it becomes a problem the path is to add an opt-in
`opts.filter` knob that maps to `-resize` on magick and a Lanczos
fallback in `image.lua`.

---

## 5. Sizing math

Given:

- `opts.width`, `opts.height` from `set()` (in cells; both required for
  the magick fast path)
- `cell_w_px`, `cell_h_px` from `util.cell_pixel_size()` (CSI 16t reply)

The encoder targets:

```
target_w_px = opts.width  × cell_w_px
target_h_px = opts.height × cell_h_px
```

`derive_dims` (in `iterm2.lua` and `sixel.lua`) fills `opts.width` /
`opts.height` from the source PNG's IHDR when the user didn't pass
them, dividing by cell-pixel size to land on a whole cell count.

Note: iTerm2's OSC 1337 path does **not** apply
`vim.g.alt_img.sixel_pixel_scale`. iTerm2 already accounts for retina
when interpreting cell-unit `width=` / `height=` params, so doubling
our PNG dimensions would just over-encode without changing the
displayed area. (The retina-pixel mismatch only affects sixel — see
[`SIXEL.md`](SIXEL.md) §3.)

---

## 6. Cropping

When a placement is only partially visible (window clip, scrolled out
of view via topfill, etc.), the carrier returns a `src` rect describing
the visible sub-area in cell units. The provider crops the cached
resized PNG to those cell coordinates:

```
src.x, src.y, src.w, src.h  (cells, 0-indexed within the image)
       ↓ × cell_w/h
x_px,  y_px,  w_px,  h_px   (pixels within the resized PNG)
       ↓
magick - -crop W×H+X+Y png:-      (subprocess)
       │ falls back to
       ▼
image.crop_rgba + png.encode      (pure Lua)
       │
       ▼
{ png = bytes, b64 = base64 }
       │
       ▼
LRU cache keyed by "x,y,w,h" string,
size 64 by default (vim.g.alt_img.crop_cache_size)
```

The OSC 1337 width/height fields are then set to `src.w` / `src.h`
(also cells) so iTerm2 displays the cropped PNG at exactly that cell
area.

---

## 7. Limitations / known issues

- **No tmux passthrough.** OSC 1337 sequences inside tmux get eaten
  unless tmux is built with `allow-passthrough on` and the plugin wraps
  bytes in DCS passthrough. Not implemented.
- **No Multigrid / external UI.** The carrier's
  `vim.api.nvim_win_get_position` calls assume the default global grid.
- **Width/height required for the magick fast path.** Without explicit
  dims the encoder skips the magick one-shot and uses pure-Lua decode +
  resize. Almost always the user (or `derive_dims`) sets dims, so this
  is rarely hit.
- **Animated GIFs / WebP.** Input must be PNG; the boundary check in
  `M.set` (`util.is_png_data`) rejects everything else.
