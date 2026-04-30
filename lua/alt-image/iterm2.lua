-- lua/alt-image/iterm2.lua
-- iTerm2 OSC 1337 image protocol provider, drop-in for vim.ui.img.
-- Ported from chipsenkbeil/neovim:feat/MoreImgProviders
--   runtime/lua/vim/ui/img/_iterm2.lua

local util    = require('alt-image._util')
local render  = require('alt-image._render')

local M = {}

local SYNC_START = '\027[?2026h'
local SYNC_END   = '\027[?2026l'

local FAST_TERM_PROGRAMS = {
  ['iTerm.app'] = true,
  ['WezTerm']   = true,
}

-- Per-id placement state. state[id] = { data = bytes, opts = canonical_opts, id = id }
local state = {}
local next_id = 1

local function new_id()
  local id = next_id
  next_id = next_id + 1
  return id
end

local function canonicalize(opts)
  opts = opts or {}
  local rel = opts.relative or 'ui'
  if rel ~= 'ui' and rel ~= 'editor' and rel ~= 'buffer' then
    error('alt-image: invalid relative ' .. tostring(rel)
       .. " (expected 'ui', 'editor', or 'buffer')", 3)
  end
  return {
    row      = opts.row,
    col      = opts.col,
    width    = opts.width,
    height   = opts.height,
    zindex   = opts.zindex,
    relative = rel,
    buf      = opts.buf,
    pad      = opts.pad,
  }
end

-- Public so _render can call us. Reads state[id], emits OSC 1337 at screen_pos.
function M._emit_at(id, screen_pos)
  local s = state[id]
  if not s then return end
  local data, opts = s.data, s.opts

  local b64 = vim.base64.encode(data)
  local args = {
    'size=' .. #data,
    'inline=1',
    'preserveAspectRatio=' .. ((opts.width and opts.height) and 0 or 1),
  }
  if opts.width  then args[#args + 1] = 'width='  .. opts.width  end
  if opts.height then args[#args + 1] = 'height=' .. opts.height end

  local cs = {
    save    = '\0277',
    hide    = '\027[?25l',
    move    = string.format('\027[%d;%dH',
                            screen_pos and screen_pos.row or (opts.row or 1),
                            screen_pos and screen_pos.col or (opts.col or 1)),
    restore = '\0278',
    show    = '\027[?25h',
  }

  local osc = '\027]1337;File=' .. table.concat(args, ';') .. ':' .. b64 .. '\007'
  util.term_send(SYNC_START .. cs.save .. cs.hide .. cs.move
    .. osc .. cs.restore .. cs.show .. SYNC_END)
end

-- Closure factory: produces a position resolver for placement `id` that the
-- render coordinator can call without knowing about provider internals.
local function get_pos_for(id)
  return function()
    local s = state[id]
    if not s then return nil end
    if s.opts.relative == 'ui' then
      return { row = s.opts.row or 1, col = s.opts.col or 1 }
    end
    return require('alt-image._carrier').get_pos(M, id)
  end
end

function M.set(data_or_id, opts)
  vim.validate({
    data_or_id = { data_or_id, { 'string', 'number' } },
    opts       = { opts, 'table', true },
  })

  if type(data_or_id) == 'number' then
    -- Update path
    local s = state[data_or_id]
    if not s then error('alt-image.iterm2: unknown id ' .. tostring(data_or_id), 2) end
    -- v1: don't support relative-changing updates (carrier kind would need
    -- to be re-created). Preserve the original relative on partial-merge so
    -- canonicalize's default of 'ui' doesn't clobber 'editor'/'buffer'.
    local upd = canonicalize(opts)
    if not (opts and opts.relative) then upd.relative = s.opts.relative end
    s.opts = vim.tbl_extend('force', s.opts, upd)
    -- For carrier-managed placements, reposition the carrier so the resolved
    -- screen pos reflects the new opts (otherwise the float stays put).
    if s.opts.relative ~= 'ui' then
      require('alt-image._carrier').update(M, data_or_id, s.opts)
    end
    render.rerender_all()
    return data_or_id
  end

  -- New placement path
  local id = new_id()
  state[id] = { data = data_or_id, opts = canonicalize(opts), id = id }

  if state[id].opts.relative ~= 'ui' then
    require('alt-image._carrier').register(M, id, state[id].opts)
  end

  render.register(M, id, get_pos_for(id))
  render.refresh()
  return id
end

function M.get(id)
  local s = state[id]
  if not s then return nil end
  return vim.deepcopy(s.opts)
end

function M.del(id)
  if id == math.huge then
    local any = next(state) ~= nil
    for k, _ in pairs(state) do
      require('alt-image._carrier').unregister(M, k)
      render.unregister(M, k)
    end
    state = {}
    if any then render.rerender_all() end
    return any
  end
  if not state[id] then return false end
  require('alt-image._carrier').unregister(M, id)
  render.unregister(M, id)
  state[id] = nil
  render.rerender_all()
  return true
end

function M._supported(opts)
  opts = opts or {}
  local tp = vim.env.TERM_PROGRAM
  if tp and FAST_TERM_PROGRAMS[tp] then
    return true, 'TERM_PROGRAM=' .. tp
  end

  -- Probe via XTVERSION (CSI > q). Polyfilled util returns nil if not
  -- supported on this Neovim build, in which case we default to false.
  local done, ok, msg = false, false, nil
  util.query_csi('\027[>q', { timeout = opts.timeout or 1000 }, function(resp)
    if resp and (resp:find('iTerm2', 1, true)
              or resp:find('WezTerm', 1, true)) then
      ok, msg = true, resp
    end
    done = true
  end)
  vim.wait((opts.timeout or 1000) + 100, function() return done end)
  return ok, msg
end

return M
