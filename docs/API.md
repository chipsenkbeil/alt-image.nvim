# alt-img.nvim public API contract

What `require('alt-img')`, `require('alt-img.iterm2')`, and
`require('alt-img.sixel')` expose, and how that surface stays bound to
upstream Neovim's `vim.ui.img`. For the protocol-level details, see
[`ITERM2.md`](ITERM2.md) and [`SIXEL.md`](SIXEL.md). For the scheduler
and cache architecture, see [`ARCHITECTURE.md`](ARCHITECTURE.md).

This is THE contract. The plugin's public surface mirrors upstream
`vim.ui.img` byte-for-byte; nothing exposed by alt-img is allowed to
exceed what this document describes.

---

## 1. Source of truth

The contract is whatever `~/projects/neovim/runtime/lua/vim/ui/img.lua`
exposes at the pinned commits below.

| Source | SHA |
|---|---|
| `runtime/lua/vim/ui/img.lua` (master) | `77a27076e8` |
| PR #39496 — `relative=editor`/`relative=buffer`/`pad`/`buf` | `416a3127ae` |

When upstream master moves:

1. Bump the SHA in this document.
2. Run `git -C ~/projects/neovim diff <old-sha>..<new-sha> -- runtime/lua/vim/ui/img.lua`.
3. Update §2/§3/§4 below to reflect any contract changes.
4. Re-run the enforcement checks in §6 (the surface test, `make lint`, `make verify-api`).

PR #39496 is the project owner's open PR. When the SHA bumps, repeat
the same procedure pointed at that branch.

---

## 2. Public surface

Each of `require('alt-img')`, `require('alt-img.iterm2')`, and
`require('alt-img.sixel')` returns a module table with **exactly four
entries**:

| Name | Signature | Visibility |
|---|---|---|
| `set` | `(data_or_id: string\|integer, opts?: vim.ui.img.Opts) -> integer` | public |
| `get` | `(id: integer) -> vim.ui.img.Opts?` | public |
| `del` | `(id: integer) -> boolean` | public |
| `_supported` | `(opts?: { timeout?: integer }) -> boolean, string?` | `@private` |

Nothing else is exposed. No `refresh`, no `_state`, no `_provider`, no
`_emit_at` / `_build_at` / `_precompute_async` on these modules. The
`api_surface_spec.lua` test (§6) enforces this.

### `set(data_or_id, opts) -> integer`

When `data_or_id` is a **string**, displays the image bytes at the
position given by `opts` and returns a fresh integer id.

When `data_or_id` is an **integer** (a previously returned id), updates
the image with new `opts`, merging via `vim.tbl_extend('force',
existing, opts)`. Any field can change (including `relative`); the
provider handles whatever rework the change implies.

`opts` is validated with `vim.validate('data_or_id', x, { 'string',
'number' })` and `vim.validate('opts', x, 'table', true)`. Provider-level
validation of `data` happens inside the provider's encode path, not at
the public boundary.

### `get(id) -> vim.ui.img.Opts?`

Returns `vim.deepcopy(opts)` for the placement, or `nil` if no
placement with that id is registered.

### `del(id) -> boolean`

Removes the placement with id `id`. When `id == math.huge`, removes
all placements. Returns `true` if anything was removed, `false`
otherwise.

### `_supported(opts) -> boolean, string?`

`@private`. Probes whether the host terminal supports image display.

- On **success**, returns `(true)` with no second value.
- On **failure**, returns `(false, msg?)` where `msg` is human-readable
  detail when the terminal responded but not with an OK signal.

Two callers:

1. The autodetect dispatcher in `lua/alt-img/_core/autodetect.lua`,
   which iterates candidate providers.
2. The per-provider health files (`lua/alt-img/iterm2/health.lua`,
   `lua/alt-img/sixel/health.lua`) for `:checkhealth`.

---

## 3. `vim.ui.img.Opts` shape

Every field is optional. Quoted from upstream PR #39496:

| Field | Type | Semantics |
|---|---|---|
| `row` | `integer` | starting row (1-indexed); buffer row if `buf` set, else editor-relative |
| `col` | `integer` | starting column (1-indexed); buffer col if `buf` set, else editor-relative |
| `width` | `integer` | width in cells |
| `height` | `integer` | height in cells |
| `zindex` | `integer` | stacking order (higher = on top) |
| `buf` | `integer` | buffer to anchor image inline (0 = current buffer) |
| `pad` | `integer` | blank cells before image in inline mode |
| `relative` | `'ui' \| 'editor' \| 'buffer'` | positioning mode: `ui` = terminal-native absolute (default), `editor` = floating window, `buffer` = inline extmark (requires `buf`) |

---

## 4. Update-path semantics

`set(id, opts)` does `vim.tbl_extend('force', existing, opts)`. There
is **no** restriction on which fields can change. In particular,
`relative` may change between `ui`, `editor`, and `buffer` on an
existing placement — the provider performs the carrier reset silently.

---

## 5. Lifecycle hooks

A `VimLeavePre` autocmd calls `M.del(math.huge)` so terminals don't
keep image bytes around after Neovim exits. Each provider installs its
own.

---

## 6. Enforcement

Three guards keep this contract from drifting:

1. **`test/api_surface_spec.lua`** — enumerates `pairs(M)` for each of
   the three public modules and asserts the key set is exactly
   `{ set, get, del, _supported }`.
2. **`make lint`** — greps `lua/alt-img/init.lua`,
   `lua/alt-img/iterm2.lua`, `lua/alt-img/sixel.lua` for `M\._[a-z_]+`
   patterns; the only allowed match is `_supported`.
3. **`make verify-api`** — diffs the function signatures and Opts
   fields quoted in this document against the pinned upstream SHAs in
   `~/projects/neovim`.

---

## 7. What is private and how it's hidden

- Top-level files (`init.lua`, `iterm2.lua`, `sixel.lua`, `health.lua`)
  are the only files at `lua/alt-img/`.
- Provider implementation (state, canonicalize, derive_dims, emit_at,
  build_at, the `_supported` probe) lives as **Lua locals** at file
  scope inside `iterm2.lua` and `sixel.lua` — never on `M`.
- Cross-cutting infra lives under `_core/`. The `_` prefix marks the
  folder private; files inside don't need underscores.
- Provider-specific subroutines that are too large for the surface
  file live under `iterm2/` or `sixel/` with a `_` prefix
  (e.g. `sixel/_encode.lua`).
- Tests are integration tests: drive `set/get/del`, capture bytes via
  `test/helpers.lua`'s `H.setup_capture`, parse via
  `H.parse_iterm2_seq` / `H.parse_sixel_seq`. They do **not** reach
  into provider state or call internal helpers.
