-- test/manual_init.lua
-- Boots a minimal Neovim for `make smoke-test`.
vim.opt.runtimepath:prepend(vim.uv.cwd())
vim.opt.mouse = 'a'
vim.opt.mousemoveevent = true

local altimg = require('alt-image')
vim.ui.img = altimg

local function read_fixture()
  local f = io.open('test/fixtures/4x4.png', 'rb')
  local b = f:read('*a'); f:close()
  return b
end

vim.api.nvim_create_user_command('AltImageDemo', function(o)
  local mode = o.args ~= '' and o.args or 'ui'
  local data = read_fixture()
  local opts = { row = 5, col = 10, width = 4, height = 4 }
  if mode == 'editor' then
    opts.relative = 'editor'
  elseif mode == 'buffer' then
    -- Demonstrate PR #39496 defaulting: opts.buf set => relative='buffer';
    -- buf=0 resolves to the current buffer. width/height are kept from above
    -- so the demo image stays small (otherwise they'd derive from the PNG).
    opts.buf = 0
    opts.row, opts.col = 1, 1
    opts.pad = 1
  end
  local id = vim.ui.img.set(data, opts)
  print(string.format('AltImageDemo: placed %s id=%d (run :AltImageDel %d to remove)',
                      mode, id, id))
end, { nargs = '?' })

vim.api.nvim_create_user_command('AltImageDel', function(o)
  local arg = o.args
  if arg == 'inf' or arg == 'all' then
    vim.ui.img.del(math.huge)
    return
  end
  local id = tonumber(arg)
  if not id then
    print('Usage: AltImageDel <id> | AltImageDel inf'); return
  end
  vim.ui.img.del(id)
end, { nargs = 1 })

-- Image-follows-mouse mode. Toggle on/off and switch the relative= mode
-- without removing/recreating the placement (uses set(id, opts) updates).
local mouse_state = { id = nil, mode = 'ui', mapping = nil }

-- Coalesce mouse-follow updates: <MouseMove> can fire faster than the
-- synchronous render flush completes. Defer via vim.schedule and read the
-- latest mouse position lazily inside the scheduled callback. While a
-- schedule is pending, subsequent fires return early — they all collapse
-- into a single set() at the latest position.
local update_pending = false
local function update_from_mouse()
  if not mouse_state.id or update_pending then return end
  update_pending = true
  vim.schedule(function()
    update_pending = false
    if not mouse_state.id then return end
    local pos = vim.fn.getmousepos()
    local opts
    if mouse_state.mode == 'ui' then
      opts = { relative = 'ui', row = pos.screenrow, col = pos.screencol }
    else
      opts = { relative = 'editor', row = pos.screenrow, col = pos.screencol }
    end
    vim.ui.img.set(mouse_state.id, opts)
  end)
end

local function mouse_off()
  if mouse_state.mapping then
    pcall(vim.keymap.del, '', '<MouseMove>')
    mouse_state.mapping = nil
  end
  if mouse_state.id then
    vim.ui.img.del(mouse_state.id)
    mouse_state.id = nil
  end
end

local function mouse_on(mode)
  mouse_off()
  mouse_state.mode = mode
  local data = read_fixture()
  local pos = vim.fn.getmousepos()
  mouse_state.id = vim.ui.img.set(data, {
    relative = mode,
    row = pos.screenrow > 0 and pos.screenrow or 1,
    col = pos.screencol > 0 and pos.screencol or 1,
    width = 4, height = 4,
  })
  vim.keymap.set('', '<MouseMove>', update_from_mouse,
    { silent = true, desc = 'alt-image mouse-follow' })
  mouse_state.mapping = true
  print('AltImageMouse: following mouse with relative=' .. mode
     .. '. Run :AltImageMouse off to stop, or :AltImageMouse <ui|editor> to switch.')
end

vim.api.nvim_create_user_command('AltImageMouse', function(o)
  local arg = o.args ~= '' and o.args or 'ui'
  if arg == 'off' then mouse_off(); return end
  if arg ~= 'ui' and arg ~= 'editor' then
    print("Usage: AltImageMouse {ui|editor|off}"); return
  end
  mouse_on(arg)
end, {
  nargs = '?',
  complete = function() return { 'ui', 'editor', 'off' } end,
})

-- Helper to identify the active vim.ui.img provider
local function provider_name()
  local img = vim.ui.img
  if img == require('alt-image.iterm2') then return 'alt-image.iterm2' end
  if img == require('alt-image.sixel')  then return 'alt-image.sixel'  end
  if img == require('alt-image')        then return 'alt-image (autodetect)' end
  return '<unknown>'
end

vim.api.nvim_create_user_command('AltImageInfo', function()
  local lines = {
    'alt-image.nvim diagnostics',
    '==========================',
    'Terminal env:',
    string.format('  TERM           = %s', tostring(vim.env.TERM)),
    string.format('  TERM_PROGRAM   = %s', tostring(vim.env.TERM_PROGRAM)),
    string.format('  COLORTERM      = %s', tostring(vim.env.COLORTERM)),
    string.format('  TMUX           = %s', tostring(vim.env.TMUX)),
    string.format('  SSH_CONNECTION = %s', tostring(vim.env.SSH_CONNECTION)),
    '',
    'Neovim:',
    string.format('  version        = v%d.%d.%d',
      vim.version().major, vim.version().minor, vim.version().patch),
    string.format('  vim.tty        = %s',
      vim.tty and 'present' or 'absent (probes skipped)'),
    string.format('  query_csi      = %s',
      (vim.tty and type(vim.tty.query_csi) == 'function') and 'available' or 'not available'),
    '',
    'Active vim.ui.img provider:',
    '  module         = ' .. provider_name(),
    '',
    'Per-provider _supported():',
  }
  local i_ok, i_msg = require('alt-image.iterm2')._supported()
  local s_ok, s_msg = require('alt-image.sixel')._supported()
  table.insert(lines, string.format('  iterm2._supported() = %s, %s',
    tostring(i_ok), i_msg or 'no message'))
  table.insert(lines, string.format('  sixel._supported()  = %s, %s',
    tostring(s_ok), s_msg or 'no message'))

  -- External-tool acceleration status
  local util = require('alt-image._util')
  local g = vim.g.alt_image or {}
  local accel = (g.accelerate ~= false)
  table.insert(lines, '')
  table.insert(lines, 'Acceleration:')
  table.insert(lines, string.format('  accelerate     = %s',
    tostring(accel)))
  table.insert(lines, string.format('  img2sixel      = %s',
    util.have_img2sixel() and 'detected' or 'not found'))
  table.insert(lines, string.format('  convert        = %s',
    util.have_convert() and 'detected' or 'not found'))

  for _, l in ipairs(lines) do print(l) end
end, {})

vim.api.nvim_create_user_command('AltImageProvider', function(o)
  local arg = o.args ~= '' and o.args or 'auto'
  if arg ~= 'iterm2' and arg ~= 'sixel' and arg ~= 'auto' then
    print('Usage: AltImageProvider {iterm2|sixel|auto}')
    return
  end

  -- Clear old placements via the currently-active provider
  pcall(function() vim.ui.img.del(math.huge) end)

  -- If mouse-follow is active, kill it (its mouse_state.id was tied to the old provider).
  pcall(function() vim.cmd('AltImageMouse off') end)

  if arg == 'iterm2' then
    vim.ui.img = require('alt-image.iterm2')
  elseif arg == 'sixel' then
    vim.ui.img = require('alt-image.sixel')
  else
    -- auto: reset autodetect cache + reload alt-image so detect() runs fresh
    package.loaded['alt-image'] = nil
    vim.ui.img = require('alt-image')
  end
  print('AltImageProvider: now using ' .. provider_name())
end, {
  nargs = '?',
  complete = function() return { 'iterm2', 'sixel', 'auto' } end,
})

print('alt-image.nvim smoke test ready.')
print('Try:')
print('  :AltImageDemo ui|editor|buffer')
print('  :AltImageDel <id>     (or `inf` to clear all)')
print('  :AltImageMouse ui     (image follows mouse, absolute terminal coords)')
print('  :AltImageMouse editor (image follows mouse, relative to editor)')
print('  :AltImageMouse off    (stop following)')
print('  :AltImageInfo                    (diagnostics: terminal + provider state)')
print('  :AltImageProvider iterm2|sixel|auto  (switch vim.ui.img provider)')
print('  :checkhealth alt-image alt-image.iterm2 alt-image.sixel')
