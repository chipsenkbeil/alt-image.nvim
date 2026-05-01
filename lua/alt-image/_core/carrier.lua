-- lua/alt-image/_core/carrier.lua
-- Reserves screen real estate via floating windows / extmarks for placements
-- with relative != 'ui'. Owns the float/extmark lifecycle and exposes the
-- current screen positions via M.get_positions. The render coordinator
-- (_render) owns redraw scheduling and dirty-flag autocmds; the carrier just
-- keeps its windows/marks consistent and evicts dangling floats on WinClosed.
--
-- Provider contract: providers must expose `_emit_at(id, screen_pos)`. The
-- carrier itself does not call providers directly.
--
-- Position contract: positions are returned as a *list* of records of the
-- shape `{ row, col, src = { x, y, w, h } }`. The list is empty (not nil)
-- when nothing is currently visible. `src` describes the rect of the source
-- image (in image cells) that should be rendered at (row, col). For images
-- fully visible within window/terminal bounds, src covers the entire image
-- and providers use the cached full encoding. For partially-visible images,
-- the carrier tightens src to the visible sub-rect and providers crop +
-- re-encode before emitting.

local util = require('alt-image._core.util')

local M = {}

local NS = vim.api.nvim_create_namespace('alt-image.carrier')
local AUGROUP = vim.api.nvim_create_augroup('alt-image.carrier', { clear = true })

-- carriers[key] = { provider = provider_module, id = provider_id,
--                   opts = opts, kind = 'editor'|'buffer',
--                   winid = ..., extmark_id = ..., bufnr = ...,
--                   last_positions = { {row, col, src}, ... } }
local carriers = {}

local function provider_key(provider, id)
  return tostring(provider) .. ':' .. tostring(id)
end

local function size_in_cells(opts)
  local pad = opts.pad or 0
  local w = (opts.width or 1) + pad
  local h = opts.height or 1
  return w, h
end

-- Open a no-content floating window at editor (row, col), sized w x h.
local function open_editor_carrier(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  local w, h = size_in_cells(opts)
  local winid = vim.api.nvim_open_win(buf, false, {
    relative  = 'editor',
    row       = (opts.row or 1) - 1,
    col       = (opts.col or 1) - 1,
    width     = w,
    height    = h,
    focusable = false,
    style     = 'minimal',
    zindex    = opts.zindex or 50,
  })
  return winid, buf
end

local function place_buffer_extmark(opts)
  local _, h = size_in_cells(opts)
  local virt = {}
  for _ = 1, h do virt[#virt + 1] = { { '', 'Normal' } } end
  local row = (opts.row or 1) - 1
  return vim.api.nvim_buf_set_extmark(opts.buf, NS,
    row, (opts.col or 1) - 1, {
      end_row = row + 1,
      end_col = 0,
      virt_lines = virt,
      virt_lines_above = false,
      invalidate = true,
      -- undo_restore left at default (true) so 'u' after 'dd' brings the
      -- image back: dd hides the mark (invalid=true), undo restores it.
      -- get_positions checks details.invalid to treat hidden marks as off-screen.
    })
end

-- Returns a list of screen positions where the placement is currently
-- visible. Empty list means "nothing visible right now" (the placement may
-- still be registered). For 'buffer' carriers, returns one entry per window
-- showing the buffer.
--
-- For 'buffer' kind, the image footprint is clipped against each window's
-- inner bounds: `src` describes the visible sub-rectangle of the source image
-- (in image cells), and (row, col) is the upper-left of the visible portion
-- on the terminal grid. Providers re-encode at the cropped dims.
--
-- For 'editor' kind, bounds remain permissive (src covers full image, no
-- terminal edge clipping); this is a known limitation.
local function resolve_screen_positions(c)
  if c.kind == 'editor' then
    if not vim.api.nvim_win_is_valid(c.winid) then return {} end
    local pos = vim.api.nvim_win_get_position(c.winid)
    local pad = (c.opts and c.opts.pad) or 0
    local anchor_row = pos[1] + 1
    local anchor_col = pos[2] + 1 + pad
    local w = c.opts.width or 1
    local h = c.opts.height or 1
    local p = util.clip_to_bounds(
      anchor_row, anchor_col, w, h,
      1, 1, vim.o.lines, vim.o.columns
    )
    return p and { p } or {}
  else
    -- relative='buffer': iterate ALL windows showing this buffer; use
    -- screenpos(win, line, col) for each. One entry per visible window,
    -- clipped to that window's inner bounds.
    if not vim.api.nvim_buf_is_valid(c.bufnr) then return {} end
    local mark = vim.api.nvim_buf_get_extmark_by_id(c.bufnr, NS, c.extmark_id, { details = true })
    if not mark or not mark[1] then return {} end
    local details = mark[3]
    if details and details.invalid then return {} end
    local anchor_line = mark[1] + 1
    local line_count = vim.api.nvim_buf_line_count(c.bufnr)
    if anchor_line < 1 or anchor_line > line_count then return {} end
    local col  = (mark[2] or 0) + 1
    local pad = (c.opts and c.opts.pad) or 0
    local img_w = c.opts.width  or 1
    local img_h = c.opts.height or 1
    local out = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == c.bufnr then
        -- Window inner bounds (1-indexed terminal cells).
        local wpos        = vim.api.nvim_win_get_position(win)
        local win_top     = wpos[1] + 1
        local win_left    = wpos[2] + 1
        local win_bottom  = win_top  + vim.api.nvim_win_get_height(win) - 1
        local win_right   = win_left + vim.api.nvim_win_get_width(win)  - 1

        -- Read scroll state to detect partial-top-visibility via topfill: when
        -- the anchor line has scrolled just above the window, its virt_lines
        -- can still be partially rendered as `topfill` filler rows at the top
        -- of the window. screenpos() reports row=0 for the off-screen anchor,
        -- so we have to compute the visible sub-rect from topfill ourselves.
        local view_ok, view = pcall(vim.api.nvim_win_call, win, vim.fn.winsaveview)
        local topline = (view_ok and view and view.topline) or 1
        local topfill = (view_ok and view and view.topfill) or 0

        local image_anchor_row, image_anchor_col, src_y_offset, src_h_max

        if anchor_line >= topline then
          -- Anchor is at or below topline: should be visible (resolve via
          -- screenpos, which respects wraps, folds, signcolumn, etc.).
          local sp_ok, sp = pcall(vim.fn.screenpos, win, anchor_line, col)
          if sp_ok and sp and sp.row > 0 then
            image_anchor_row = sp.row + 1   -- first virt_line below anchor
            image_anchor_col = sp.col + pad
            src_y_offset     = 0
            src_h_max        = img_h
          end
        elseif anchor_line == topline - 1 and topfill > 0 then
          -- Anchor is just above topline; its virt_lines are partially visible
          -- as `topfill` filler rows at the top of the window. The bottom
          -- `min(topfill, img_h)` rows of the image render at win_top onward.
          -- Approximation/caveat: if other extmarks above topline ALSO
          -- contribute to topfill, this over-attributes rows to our image.
          -- For alt-image's typical one-image-per-buffer use it's fine.
          local visible = math.min(topfill, img_h)
          local skipped = img_h - visible
          image_anchor_row = win_top
          -- Probe screenpos for a known-visible line at our column to pick up
          -- signcolumn/number offsets. topline is always visible.
          local probe_ok, probe = pcall(vim.fn.screenpos, win, topline, col)
          local probe_col = (probe_ok and probe and probe.col and probe.col > 0)
            and probe.col or win_left
          image_anchor_col = probe_col + pad
          src_y_offset     = skipped
          src_h_max        = visible
        end
        -- else: anchor and all virt_lines are off-screen; no position.

        if image_anchor_row then
          local p = util.clip_to_bounds(
            image_anchor_row, image_anchor_col,
            img_w, src_h_max,
            win_top, win_left, win_bottom, win_right
          )
          if p then
            -- clip_to_bounds operates on the (possibly already top-skipped)
            -- sub-image of height src_h_max; combine its returned src.y with
            -- the topfill-induced skip so the provider crops at the correct
            -- offset within the *original* image.
            p.src.y = p.src.y + src_y_offset
            out[#out + 1] = p
          end
        end
      end
    end
    return out
  end
end

-- Register a new placement that needs a carrier.
-- Returns the initial list of screen positions (possibly empty).
function M.register(provider, id, opts)
  local c = { provider = provider, id = id, opts = opts }
  if opts.relative == 'editor' then
    c.kind = 'editor'
    c.winid, c.bufnr = open_editor_carrier(opts)
  elseif opts.relative == 'buffer' then
    if not opts.buf then error('alt-image: relative=buffer requires opts.buf', 3) end
    c.kind = 'buffer'
    c.bufnr = opts.buf
    c.extmark_id = place_buffer_extmark(opts)
  else
    error('alt-image: unsupported relative ' .. tostring(opts.relative), 3)
  end
  c.last_positions = resolve_screen_positions(c)
  carriers[provider_key(provider, id)] = c
  return c.last_positions
end

-- Reposition the carrier for an existing placement. Called by providers when
-- M.set(id, opts) updates row/col/width/height/etc. Without this, carriers
-- stay where they were first opened and the resolved screen pos never moves.
-- Returns the updated list of screen positions (possibly empty).
function M.update(provider, id, opts)
  local key = provider_key(provider, id)
  local c = carriers[key]
  if not c then return {} end
  c.opts = opts
  if c.kind == 'editor' then
    if c.winid and vim.api.nvim_win_is_valid(c.winid) then
      local w, h = size_in_cells(opts)
      vim.api.nvim_win_set_config(c.winid, {
        relative  = 'editor',
        row       = (opts.row or 1) - 1,
        col       = (opts.col or 1) - 1,
        width     = w,
        height    = h,
        focusable = false,
        style     = 'minimal',
        zindex    = opts.zindex or 50,
      })
    end
  elseif c.kind == 'buffer' then
    if c.extmark_id then
      pcall(vim.api.nvim_buf_del_extmark, c.bufnr, NS, c.extmark_id)
    end
    if opts.buf then c.bufnr = opts.buf end
    c.extmark_id = place_buffer_extmark(opts)
  end
  c.last_positions = resolve_screen_positions(c)
  return c.last_positions
end

function M.unregister(provider, id)
  local key = provider_key(provider, id)
  local c = carriers[key]
  if not c then return end
  if c.kind == 'editor' and c.winid and vim.api.nvim_win_is_valid(c.winid) then
    pcall(vim.api.nvim_win_close, c.winid, true)
  elseif c.kind == 'buffer' and c.extmark_id then
    pcall(vim.api.nvim_buf_del_extmark, c.bufnr, NS, c.extmark_id)
  end
  carriers[key] = nil
end

-- Public position lookup used by the render coordinator's get_pos closure
-- factories on the providers. Returns a list (possibly empty) of position
-- records `{ row, col, src = { x, y, w, h } }`. Never returns nil.
function M.get_positions(provider, id)
  local c = carriers[provider_key(provider, id)]
  if not c then return {} end
  return resolve_screen_positions(c)
end

-- Evict dangling floats so we don't try to resolve_screen_positions against a
-- closed window. _render's autocmds will pick up the layout change and
-- re-emit remaining placements at their new positions.
vim.api.nvim_create_autocmd(
  { 'WinClosed' },
  {
    group = AUGROUP,
    callback = function(args)
      local closed = tonumber(args.match)
      for k, c in pairs(carriers) do
        if c.winid == closed then carriers[k] = nil end
      end
    end,
  }
)

return M
