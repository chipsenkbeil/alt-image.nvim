-- test/accel_spec.lua
-- Tests for the external-tool dispatchers in sixel/_encode.lua and
-- _core/magick.lua, plus the vim.g.alt_image.magick / img2sixel
-- binary-resolution semantics. We mock vim.system + vim.fn.executable so no
-- real subprocess ever runs.

local H = require('test.helpers')

-- Stand up a controlled environment for one test:
-- - executable_for: { [name]=true|false } overrides for vim.fn.executable
-- - system_handler: function(cmd, opts) -> { code, stdout } (or nil to error)
-- - g_alt_image:    table assigned to vim.g.alt_image
-- Returns the fresh _sixel_encode module + a `calls` array recording each
-- vim.system invocation as { cmd = {...}, opts = {...} }.
local function with_mocks(executable_for, system_handler, g_alt_image)
  local saved_system     = vim.system
  local saved_executable = vim.fn.executable
  local saved_g          = vim.g.alt_image

  vim.fn.executable = function(name)
    local v = executable_for[name]
    if v == true  then return 1 end
    if v == false then return 0 end
    return saved_executable(name)
  end

  local calls = {}
  vim.system = function(cmd, opts)
    table.insert(calls, { cmd = cmd, opts = opts })
    local res = system_handler and system_handler(cmd, opts)
                or { code = 0, stdout = '' }
    return { wait = function() return res end }
  end

  -- Force fresh module loads so the mocks take effect through cached
  -- requires inside the dispatchers.
  package.loaded['alt-image']                  = nil
  package.loaded['alt-image._core.util']       = nil
  package.loaded['alt-image._core.png']        = nil
  package.loaded['alt-image._core.magick']     = nil
  package.loaded['alt-image.sixel._encode']    = nil
  package.loaded['alt-image.sixel._libsixel']  = nil
  vim.g.alt_image = g_alt_image
  local senc = require('alt-image.sixel._encode')
  -- Belt-and-suspenders: clear the executable cache.
  require('alt-image._core.util')._reset_executable_cache()

  return senc, calls, function()
    vim.system        = saved_system
    vim.fn.executable = saved_executable
    vim.g.alt_image   = saved_g
  end
end

describe('_magick.binary()', function()
  local function fresh_magick(executable_for, g_alt_image)
    package.loaded['alt-image._core.util']   = nil
    package.loaded['alt-image._core.magick'] = nil
    local saved_executable = vim.fn.executable
    local saved_g          = vim.g.alt_image
    vim.fn.executable = function(name)
      local v = executable_for[name]
      if v == true  then return 1 end
      if v == false then return 0 end
      return saved_executable(name)
    end
    vim.g.alt_image = g_alt_image
    require('alt-image._core.util')._reset_executable_cache()
    return require('alt-image._core.magick'), function()
      vim.fn.executable = saved_executable
      vim.g.alt_image   = saved_g
    end
  end

  it('returns nil when magick = false', function()
    local m, restore = fresh_magick({ magick = true, convert = true },
                                    { magick = false })
    local ok, err = pcall(function()
      assert.is_nil(m.binary())
    end)
    restore()
    if not ok then error(err, 0) end
  end)

  it('uses the configured string when executable', function()
    local m, restore = fresh_magick({ magick = true }, { magick = 'magick' })
    local ok, err = pcall(function()
      assert.equals('magick', m.binary())
    end)
    restore()
    if not ok then error(err, 0) end
  end)

  it('returns nil when configured string is not executable', function()
    local m, restore = fresh_magick({ ['gm-bogus'] = false },
                                    { magick = 'gm-bogus' })
    local ok, err = pcall(function()
      assert.is_nil(m.binary())
    end)
    restore()
    if not ok then error(err, 0) end
  end)

  it('auto-detects magick first when nil/unset', function()
    local m, restore = fresh_magick({ magick = true, convert = true }, {})
    local ok, err = pcall(function()
      assert.equals('magick', m.binary())
    end)
    restore()
    if not ok then error(err, 0) end
  end)

  it('falls back to convert when magick is missing', function()
    local m, restore = fresh_magick({ magick = false, convert = true }, {})
    local ok, err = pcall(function()
      assert.equals('convert', m.binary())
    end)
    restore()
    if not ok then error(err, 0) end
  end)

  it('returns nil when neither magick nor convert is on PATH', function()
    local m, restore = fresh_magick({ magick = false, convert = false }, {})
    local ok, err = pcall(function()
      assert.is_nil(m.binary())
    end)
    restore()
    if not ok then error(err, 0) end
  end)
end)

describe('_libsixel.binary()', function()
  local function fresh_libsixel(executable_for, g_alt_image)
    package.loaded['alt-image._core.util']      = nil
    package.loaded['alt-image.sixel._libsixel'] = nil
    local saved_executable = vim.fn.executable
    local saved_g          = vim.g.alt_image
    vim.fn.executable = function(name)
      local v = executable_for[name]
      if v == true  then return 1 end
      if v == false then return 0 end
      return saved_executable(name)
    end
    vim.g.alt_image = g_alt_image
    require('alt-image._core.util')._reset_executable_cache()
    return require('alt-image.sixel._libsixel'), function()
      vim.fn.executable = saved_executable
      vim.g.alt_image   = saved_g
    end
  end

  it('returns nil when img2sixel = false', function()
    local m, restore = fresh_libsixel({ img2sixel = true },
                                      { img2sixel = false })
    local ok, err = pcall(function()
      assert.is_nil(m.binary())
    end)
    restore()
    if not ok then error(err, 0) end
  end)

  it('uses the configured string when executable', function()
    local m, restore = fresh_libsixel({ img2sixel = true },
                                      { img2sixel = 'img2sixel' })
    local ok, err = pcall(function()
      assert.equals('img2sixel', m.binary())
    end)
    restore()
    if not ok then error(err, 0) end
  end)

  it('returns nil when configured string is not executable', function()
    local m, restore = fresh_libsixel({ ['notreal'] = false },
                                      { img2sixel = 'notreal' })
    local ok, err = pcall(function()
      assert.is_nil(m.binary())
    end)
    restore()
    if not ok then error(err, 0) end
  end)

  it('auto-detects img2sixel when nil/unset', function()
    local m, restore = fresh_libsixel({ img2sixel = true }, {})
    local ok, err = pcall(function()
      assert.equals('img2sixel', m.binary())
    end)
    restore()
    if not ok then error(err, 0) end
  end)

  it('returns nil when img2sixel is not on PATH', function()
    local m, restore = fresh_libsixel({ img2sixel = false }, {})
    local ok, err = pcall(function()
      assert.is_nil(m.binary())
    end)
    restore()
    if not ok then error(err, 0) end
  end)
end)

describe('encode_sixel_dispatch', function()
  -- A trivial 1x1 fully-opaque red RGBA pixel.
  local rgba = string.char(255, 0, 0, 255)

  it('uses img2sixel when configured and available', function()
    local senc, calls, restore = with_mocks(
      { img2sixel = true, magick = false, convert = false },
      function() return { code = 0, stdout = 'FAKE_SIXEL_FROM_IMG2SIXEL' } end,
      { magick = false, img2sixel = 'img2sixel' })
    local ok, err = pcall(function()
      local out = senc.encode_sixel_dispatch(rgba, 1, 1)
      assert.equals('FAKE_SIXEL_FROM_IMG2SIXEL', out)
      assert.equals(1, #calls)
      assert.equals('img2sixel', calls[1].cmd[1])
    end)
    restore()
    if not ok then error(err, 0) end
  end)

  it('falls through to magick when img2sixel is disabled', function()
    local senc, calls, restore = with_mocks(
      { img2sixel = true, magick = true },
      function() return { code = 0, stdout = 'FAKE_SIXEL_FROM_MAGICK' } end,
      { img2sixel = false, magick = 'magick' })
    local ok, err = pcall(function()
      local out = senc.encode_sixel_dispatch(rgba, 1, 1)
      assert.equals('FAKE_SIXEL_FROM_MAGICK', out)
      assert.equals(1, #calls)
      assert.equals('magick', calls[1].cmd[1])
    end)
    restore()
    if not ok then error(err, 0) end
  end)

  it('uses convert when configured', function()
    local senc, calls, restore = with_mocks(
      { img2sixel = false, magick = false, convert = true },
      function() return { code = 0, stdout = 'FAKE_SIXEL_FROM_CONVERT' } end,
      { img2sixel = false, magick = 'convert' })
    local ok, err = pcall(function()
      local out = senc.encode_sixel_dispatch(rgba, 1, 1)
      assert.equals('FAKE_SIXEL_FROM_CONVERT', out)
      assert.equals(1, #calls)
      assert.equals('convert', calls[1].cmd[1])
    end)
    restore()
    if not ok then error(err, 0) end
  end)

  it('uses pure Lua when both tools are disabled', function()
    local senc, calls, restore = with_mocks(
      { img2sixel = true, magick = true, convert = true },
      function() return { code = 0, stdout = 'SHOULD_NOT_BE_USED' } end,
      { img2sixel = false, magick = false })
    local ok, err = pcall(function()
      local out = senc.encode_sixel_dispatch(rgba, 1, 1)
      assert.equals(0, #calls)
      -- Pure-Lua output starts with the DCS introducer.
      assert.matches('^\027Pq', out)
    end)
    restore()
    if not ok then error(err, 0) end
  end)

  it('falls back to magick when img2sixel returns non-zero', function()
    local senc, calls, restore = with_mocks(
      { img2sixel = true, magick = true },
      function(cmd)
        if cmd[1] == 'img2sixel' then return { code = 1, stdout = '' } end
        return { code = 0, stdout = 'FAKE_SIXEL_FROM_MAGICK' }
      end,
      { img2sixel = 'img2sixel', magick = 'magick' })
    local ok, err = pcall(function()
      local out = senc.encode_sixel_dispatch(rgba, 1, 1)
      assert.equals('FAKE_SIXEL_FROM_MAGICK', out)
      assert.equals(2, #calls)
      assert.equals('img2sixel', calls[1].cmd[1])
      assert.equals('magick',    calls[2].cmd[1])
    end)
    restore()
    if not ok then error(err, 0) end
  end)

  it('falls back to pure Lua when both tools fail', function()
    local senc, calls, restore = with_mocks(
      { img2sixel = true, magick = true },
      function() return { code = 1, stdout = '' } end,
      { img2sixel = 'img2sixel', magick = 'magick' })
    local ok, err = pcall(function()
      local out = senc.encode_sixel_dispatch(rgba, 1, 1)
      assert.equals(2, #calls)
      assert.matches('^\027Pq', out)
    end)
    restore()
    if not ok then error(err, 0) end
  end)

  it('falls back to pure Lua when neither tool is installed', function()
    local senc, calls, restore = with_mocks(
      { img2sixel = false, magick = false, convert = false },
      function() return { code = 0, stdout = 'NEVER' } end,
      {})
    local ok, err = pcall(function()
      local out = senc.encode_sixel_dispatch(rgba, 1, 1)
      assert.equals(0, #calls)
      assert.matches('^\027Pq', out)
    end)
    restore()
    if not ok then error(err, 0) end
  end)
end)

describe('magick.crop_to_sixel', function()
  local png_bytes = 'FAKEPNG'

  it('invokes magick with -crop geometry when configured', function()
    local _, calls, restore = with_mocks(
      { img2sixel = false, magick = true },
      function() return { code = 0, stdout = 'CROPPED_SIXEL' } end,
      { img2sixel = false, magick = 'magick' })
    local magick = require('alt-image._core.magick')
    local ok, err = pcall(function()
      local out = magick.crop_to_sixel(png_bytes, 5, 7, 11, 13)
      assert.equals('CROPPED_SIXEL', out)
      assert.equals(1, #calls)
      local cmd = calls[1].cmd
      assert.equals('magick', cmd[1])
      -- Expect -crop 11x13+5+7 somewhere in the arg list.
      local found = false
      for i = 1, #cmd - 1 do
        if cmd[i] == '-crop' and cmd[i + 1] == '11x13+5+7' then found = true end
      end
      assert.is_true(found)
    end)
    restore()
    if not ok then error(err, 0) end
  end)

  it('returns nil when magick = false (caller falls back)', function()
    local _, calls, restore = with_mocks(
      { img2sixel = true, magick = true },
      function() return { code = 0, stdout = 'NEVER' } end,
      { img2sixel = false, magick = false })
    local magick = require('alt-image._core.magick')
    local ok, err = pcall(function()
      local out = magick.crop_to_sixel(png_bytes, 0, 0, 1, 1)
      assert.is_nil(out)
      assert.equals(0, #calls)
    end)
    restore()
    if not ok then error(err, 0) end
  end)

  it('returns nil when magick is not installed', function()
    local _, _, restore = with_mocks(
      { img2sixel = true, magick = false, convert = false },
      function() return { code = 0, stdout = 'NEVER' } end,
      {})
    local magick = require('alt-image._core.magick')
    local ok, err = pcall(function()
      local out = magick.crop_to_sixel(png_bytes, 0, 0, 1, 1)
      assert.is_nil(out)
    end)
    restore()
    if not ok then error(err, 0) end
  end)
end)

describe('magick.crop_to_png', function()
  local png_bytes = 'FAKEPNG'

  it('invokes magick with png:- when configured', function()
    local _, calls, restore = with_mocks(
      { img2sixel = false, magick = true },
      function() return { code = 0, stdout = 'CROPPED_PNG' } end,
      { img2sixel = false, magick = 'magick' })
    local magick = require('alt-image._core.magick')
    local ok, err = pcall(function()
      local out = magick.crop_to_png(png_bytes, 1, 2, 3, 4)
      assert.equals('CROPPED_PNG', out)
      assert.equals(1, #calls)
      -- Last positional should be 'png:-'.
      local cmd = calls[1].cmd
      assert.equals('png:-', cmd[#cmd])
    end)
    restore()
    if not ok then error(err, 0) end
  end)

  it('returns nil when magick = false', function()
    local _, _, restore = with_mocks(
      { img2sixel = true, magick = true },
      function() return { code = 0, stdout = 'NEVER' } end,
      { img2sixel = false, magick = false })
    local magick = require('alt-image._core.magick')
    local ok, err = pcall(function()
      assert.is_nil(magick.crop_to_png(png_bytes, 0, 0, 1, 1))
    end)
    restore()
    if not ok then error(err, 0) end
  end)
end)

-- Integration: a buffer-anchored placement gets cropped because its window is
-- too short, the sixel provider's fast path detects PNG input + no resize
-- requested + magick available, and feeds the original PNG through
-- `magick -crop`. We assert the captured emit contains the canned bytes
-- returned by our mock.
describe('accel-with-crop integration', function()
  local function read_fixture()
    local f = io.open('test/fixtures/4x4.png', 'rb')
    local b = f:read('*a'); f:close()
    return b
  end

  it('sixel provider routes a window-clipped placement through magick', function()
    local saved_system     = vim.system
    local saved_executable = vim.fn.executable
    local saved_g          = vim.g.alt_image

    vim.fn.executable = function(name)
      if name == 'magick'    then return 1 end
      if name == 'convert'   then return 1 end
      if name == 'img2sixel' then return 0 end
      return saved_executable(name)
    end
    local magick_calls = {}
    vim.system = function(cmd, opts)
      table.insert(magick_calls, { cmd = cmd, opts = opts })
      return { wait = function()
        return { code = 0, stdout = 'MAGICK_SIXEL_BYTES' }
      end }
    end

    -- Reload everything under the new env.
    package.loaded['alt-image']                  = nil
    package.loaded['alt-image._core.util']       = nil
    package.loaded['alt-image._core.png']        = nil
    package.loaded['alt-image._core.magick']     = nil
    package.loaded['alt-image._core.render']     = nil
    package.loaded['alt-image._core.carrier']    = nil
    package.loaded['alt-image._core.image']      = nil
    package.loaded['alt-image.sixel._encode']    = nil
    package.loaded['alt-image.sixel._libsixel']  = nil
    package.loaded['alt-image.sixel']            = nil
    vim.g.alt_image = { magick = 'magick', img2sixel = false }
    require('alt-image._core.util')._reset_executable_cache()

    H.setup_capture()
    local img = require('alt-image.sixel')

    -- Build a setup that triggers cropping: small window, image taller than
    -- the visible region.
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'x' })
    vim.api.nvim_set_current_buf(buf)
    vim.cmd('resize 3')

    H.reset_capture()
    local id = img.set(read_fixture(), { relative = 'buffer', buf = buf,
                                          row = 1, col = 1,
                                          width = 4, height = 10 })

    -- We expect magick to have been invoked at least once (either via the
    -- combined crop+encode fast path, or via encode_sixel_dispatch on the
    -- already-cropped RGBA buffer).
    local saw_magick = false
    for _, call in ipairs(magick_calls) do
      if call.cmd[1] == 'magick' then saw_magick = true; break end
    end

    -- Verify the captured emit contains our canned bytes.
    local cap = H.captured()
    local saw_canned = cap:find('MAGICK_SIXEL_BYTES', 1, true) ~= nil

    img.del(id)
    vim.cmd('resize')

    -- Restore.
    vim.system        = saved_system
    vim.fn.executable = saved_executable
    vim.g.alt_image   = saved_g

    assert.is_true(saw_magick, 'expected magick to be invoked')
    assert.is_true(saw_canned,
      'expected captured emit to contain canned MAGICK_SIXEL_BYTES')
  end)
end)

-- After this spec finishes, restore deterministic defaults for any later
-- specs that share the alt-image config.
describe('accel cleanup', function()
  it('leaves magick=false, img2sixel=false for subsequent specs', function()
    vim.g.alt_image = { magick = false, img2sixel = false }
    assert.equals(false, (vim.g.alt_image or {}).magick)
    assert.equals(false, (vim.g.alt_image or {}).img2sixel)
    -- Tag H so static analyzers don't flag the import as unused.
    _ = H
  end)
end)
