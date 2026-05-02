# Sixel DCS image protocol

What the `alt-img.sixel` provider emits, the legacy/quirk minefield around
it, and how the encoder pipeline produces something that displays the same
on iTerm2, WezTerm, foot, mlterm, contour, and Windows Terminal. For the
surrounding scheduler / cache architecture see
[`ARCHITECTURE.md`](ARCHITECTURE.md).

---

## 1. Sequence shape

Sixel images are wrapped in a [`DCS`] (Device Control String):

```
ESC P  P1 ; P2 ; P3  q  RASTER  PALETTE  BANDS  ESC \
```

Where:

- `P1`, `P2`, `P3` are DCS params (covered in §2 — they're a footgun).
- `q` marks "this DCS payload is sixel" (xterm convention).
- `RASTER` is `"pan;pad;w;h"`: pixel aspect numerator/denominator and
  output pixel dimensions.
- `PALETTE` is one or more `#index;2;R;G;B` color register definitions
  in 0-100 percent space (`2` = RGB color space).
- `BANDS` is the actual pixel data — see §6.
- Terminator is `ESC \` (ST). Some emitters use `BEL`; we always use ST.

Annotated example (a 32×64 sixel with 4 colors, 2 horizontal bands):

```
\eP q "1;1;32;64                              ← raster: square pixels, 32×64 px
#0;2;100;0;0                                  ← color #0 = RGB(100%, 0%, 0%) red
#1;2;0;100;0                                  ← color #1 = green
#2;2;0;0;100                                  ← color #2 = blue
#3;2;100;0;100                                ← color #3 = magenta
#0!16~#1!16~                                  ← band 1: 16 cols red, 16 cols green
-                                             ← band separator (next 6-row band)
#2!16~#3!16~                                  ← band 2: 16 cols blue, 16 cols magenta
\e\\                                          ← ST (terminator)
```

`!N~` is RLE: `~` = sixel byte 0x7E = "all 6 vertical pixels in this
column set"; `!16` repeats it 16 times. Each band is 6 pixels tall × `w`
pixels wide. For `64` total pixels of height, you get 11 bands (with
the last one partial).

---

## 2. The DCS-params footgun

The three params after `ESC P` are an interpretation minefield:

- `P1` — pixel aspect ratio. Per the legacy VT3xx convention,
  `P1 = 0` (or `1`) means "default 2:1 vertical aspect". `P1 = 7,8,9`
  means "1:1 (square pixels)".
- `P2` — background color handling. `0` = use pixels as-is.
- `P3` — horizontal grid size (almost never honored; treat as 0).

The trouble: most modern encoders ignore P1 and emit a `"pan;pad;w;h"`
**raster attribute** right after the `q` to specify the actual aspect.
The raster wins on most terminals — **except iTerm2**, which honors `P1`
verbatim and ignores the raster's pan/pad. So a sixel that says

```
\e P 0;0;0 q "1;1;32;64 ...
```

renders as 32×64 px on every terminal *except* iTerm2, which renders it
at 32×128 px (because `P1=0` says "each pixel is 2× vertically").

`magick` emits `\eP0;0;0q` by default. `img2sixel` (and our pure-Lua
encoder) emit `\ePq` with no DCS params, which falls through to the
raster on every terminal. We post-process magick's output to strip its
DCS params:

```
function magick_normalize(s)
    -- Replace "ESC P <digits>;<digits>;<digits> q" with "ESC P q"
    -- so terminals (notably iTerm2) honor the raster `"pan;pad;w;h`
    -- instead of P1.
    return (s:gsub("^\027P[%d;]+q", "\027Pq", 1))
end
```

Applied in `_core/magick.lua` to every magick-produced sixel string.
See `fix(sixel): strip magick's DCS params so iTerm2 honors raster
aspect` (commit `95bbab0`).

---

## 3. Pixel scale on retina (the size mystery)

Even with §2 fixed, sixel can render at the **wrong size** on iTerm2
and WezTerm in a HiDPI environment. Reason:

- `CSI 16t` (cell pixel size) replies in **logical** pixels. iTerm2 on
  retina returns `8×16` even though the actual render uses `16×32`
  physical pixels per cell.
- iTerm2's sixel renderer uses **physical** pixels for sixel pixel
  dimensions.

Net effect: a sixel encoded at `cell_w × opts.width = 32×64 logical px`
displays at `32×64 physical px = 16×32 logical px = 2×2 cells` on a 2×
display, instead of the requested 4×4 cells.

Detection: see [`ARCHITECTURE.md` §8](ARCHITECTURE.md#8-dpi--pixel-scale-auto-detection).
The encoder multiplies its sixel target dims by
`util.terminal_pixel_scale()`:

```
target_w_px = opts.width  × cell_w_px × scale
target_h_px = opts.height × cell_h_px × scale
```

where `scale ∈ {1, 2, 3, …}` is the max of two signals (OSC 1337
`ReportCellSize` for iTerm2/WezTerm/Mintty/Konsole/Tabby; CSI 14t/18t/16t
geometry for everyone else). User can force a specific value with
`vim.g.alt_img.sixel_pixel_scale`.

iTerm2's OSC 1337 path doesn't need this — it interprets `width=N` /
`height=N` cell-unit fields with retina-awareness internally — so the
scale only affects sixel.

---

## 4. Detection

`sixel.lua:_supported(opts)` decides whether the running terminal can
display sixel:

```
                      _supported(opts)
                            │
              TERM_PROGRAM == "Apple_Terminal"
                  ↓ yes
              return false (Apple Terminal has no sixel support)
                            │
                            ▼
              WT_SESSION env set?
                  ↓ yes
              return true (Windows Terminal)
                            │
                            ▼
              TERM_PROGRAM ∈ {iTerm.app(3.5+), WezTerm}?
                  ↓ yes
              return true
                            │
                            ▼
              TERM contains "sixel" OR TERM ∈ {foot, mlterm, contour}?
                  ↓ yes
              return true
                            │
                            ▼
              DA1 probe (CSI c)
                  reply contains ";4"?
                  ↓ yes        ↓ no
                return true   return false
```

DA1 (`ESC [ c`) is the universal "what features do you support" probe.
Sixel-capable terminals include `4` (sixel) in the response feature
list. Probe timeout defaults to 1000ms; smoke test 200ms.

---

## 5. Encoding pipeline

```
            user-supplied PNG bytes
                     │
                     ▼
               provider.set
                     │
                     ▼
              build_sixel(state)
            ┌─────────────────────────────────────────┐
            │ if cache hit (s.sixel_cache): return    │
            │                                         │
            │ scale = sixel_scale()  -- §3            │
            │                                         │
            │ if magick on PATH AND opts.width/height:│
            │     ┌───────────────────────────────┐   │
            │     │ magick - -sample WxH! \       │   │
            │     │   -define sixel:colors=256 \  │   │
            │     │   sixel:-                     │   │
            │     │ → magick_normalize (§2)       │   │
            │     └───────────────────────────────┘   │
            │     out → cache; return                 │
            │                                         │
            │ pure-Lua fallback:                      │
            │   ensure_resized(state)                 │
            │     ┌─────────────────────────────┐     │
            │     │ png.decode → image.resize   │     │
            │     │   (libz FFI or stored block;│     │
            │     │   nearest-neighbor)         │     │
            │     └─────────────────────────────┘     │
            │   if scale > 1: image.resize × scale    │
            │   senc.encode_sixel_dispatch(rgba, w, h)│
            └─────────────────────────────────────────┘
                     │
                     ▼
                s.sixel_cache
                     │
                     ▼
            _emit_at: cursor save/hide → CUP move →
            sixel bytes → cursor restore/show
                     │
                     ▼
             util.term_send (= nvim_ui_send)
                     │
                     ▼
              terminal renders pixels
```

The pure-Lua dispatch (`senc.encode_sixel_dispatch`) tries multiple
encoders in priority order:

```
encode_sixel_dispatch(rgba, w, h)
  │
  ├─ if magick AND no libz:
  │    magick - -size WxH -depth 8 RGBA:- -define sixel:colors=256 sixel:-
  │    (skip the PNG hop entirely — png.encode would fall back to
  │     uncompressed stored blocks otherwise; commit 1770da9)
  │
  ├─ encode RGBA → PNG  (libz compress2 OR stored blocks)
  │
  ├─ if libsixel (img2sixel) on PATH:
  │    img2sixel < png_bytes
  │
  ├─ if magick on PATH:
  │    magick - -define sixel:colors=256 sixel:-
  │
  └─ pure-Lua: median-cut quantize + sixel band encode
       (sixel/_encode.lua)
```

---

## 6. Pure-Lua encoder internals

`sixel/_encode.lua` is a fallback when no external binary is available.
It does:

1. **Quantization (median-cut)** down to a configurable palette
   (default 256). Pixels are packed into a u32 RGBA array via FFI for
   the inner loop. Buckets recursively split on the longest channel
   range.
2. **Sixel band emission**. For each 6-row band (top-to-bottom, the
   sixel format's atomic vertical unit):
   - For each color in the palette, build a bitmask per output column
     (1-bit-per-pixel × 6 vertical pixels = one sixel byte: `0x3F` ⊕
     base `0x3F`).
   - RLE-compress runs of identical bytes via `!N~` syntax.
   - Emit `#color`-select then the run.
   - End the band with `-` (line feed); the last band uses `$` if it's
     a partial band.

Output starts with `\ePq"1;1;w;h` so it doesn't need normalization (no
DCS params). Performance on a 444×431 RGBA buffer is comparable to
magick (~700 ms vs ~750 ms; see `test/benchmark.out.md`) — JIT-friendly
loops compete favorably with the subprocess fork+exec overhead at this
size.

---

## 7. Cropping

```
src.x, src.y, src.w, src.h  (cells, 0-indexed within the image)
       ↓ × cell_w/h × scale
x_px,  y_px,  w_px,  h_px   (pixels in target space)
full_w_px, full_h_px         (full-image target dims, also × scale)
       ↓
magick - -sample FULLxFULL! -crop WxH+X+Y \
    -define sixel:colors=256 sixel:-       (one subprocess)
    → magick_normalize
       │ falls back to
       ▼
ensure_resized → image.resize (× scale) →
image.crop_rgba → senc.encode_sixel_dispatch
       │
       ▼
sixel string cached in
s.sixel_cache_by_src[ "x,y,w,h" ]   (LRU 64)
```

There is NO pure-Lua path that mutates an existing sixel string in
place. Cropping a sixel-encoded image requires parsing the bands back
to pixels, which is strictly slower than cropping the cached resized
RGBA buffer and re-encoding. The crop path always works in RGBA-or-
magick space.

---

## 8. Limitations / known issues

- **Apple Terminal**: no sixel support, period. `_supported` returns
  false on `TERM_PROGRAM=Apple_Terminal`.
- **No tmux passthrough.** Sixel DCS sequences inside tmux need to be
  wrapped in another DCS passthrough sequence; not implemented.
- **256-color palette default.** `vim.g.alt_img.sixel_colors` is *not*
  currently exposed — magick is told `sixel:colors=256` and the
  pure-Lua quantizer hardcodes the same. Open opt-in if a use case
  appears.
- **Pixel-scale auto-detect requires CSI/OSC support.** Terminals that
  ignore both OSC 1337 ReportCellSize and CSI 14t/18t will get
  `scale = 1`. If that produces a wrong size, fall back to
  `vim.g.alt_img.sixel_pixel_scale = N`.
- **No animated sixel.** Each `set()` produces a single frame; the
  protocol supports cursor positioning + repeated emits but we don't
  use it.
