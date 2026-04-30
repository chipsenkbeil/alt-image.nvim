-- test/accel_spec.lua
-- Tests for the external-tool acceleration dispatchers in _sixel_encode.lua.
-- We mock vim.system + vim.fn.executable so no real subprocess ever runs.

local H = require('test.helpers')

-- Stand up a controlled environment for one test:
-- - executable_for: { [name]=true|false } overrides for vim.fn.executable
-- - system_handler: function(cmd, opts) -> { code, stdout } (or nil to error)
-- - accelerate:     boolean for vim.g.alt_image.accelerate
-- Returns the fresh _sixel_encode module + a `calls` array recording each
-- vim.system invocation as { cmd = {...}, opts = {...} }.
local function with_mocks(executable_for, system_handler, accelerate)
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
  -- requires inside the dispatcher.
  package.loaded['alt-image']               = nil
  package.loaded['alt-image._util']         = nil
  package.loaded['alt-image._sixel_encode'] = nil
  package.loaded['alt-image._png_encode']   = nil
  vim.g.alt_image = { accelerate = accelerate }
  local senc = require('alt-image._sixel_encode')
  -- Belt-and-suspenders: clear the executable cache.
  require('alt-image._util')._reset_executable_cache()

  return senc, calls, function()
    vim.system        = saved_system
    vim.fn.executable = saved_executable
    vim.g.alt_image   = saved_g
  end
end

describe('encode_sixel_dispatch', function()
  -- A trivial 1x1 fully-opaque red RGBA pixel.
  local rgba = string.char(255, 0, 0, 255)

  it('uses img2sixel when available and accelerate=true', function()
    local senc, calls, restore = with_mocks(
      { img2sixel = true, convert = false },
      function() return { code = 0, stdout = 'FAKE_SIXEL_FROM_IMG2SIXEL' } end,
      true)
    local ok, err = pcall(function()
      local out = senc.encode_sixel_dispatch(rgba, 1, 1)
      assert.equals('FAKE_SIXEL_FROM_IMG2SIXEL', out)
      assert.equals(1, #calls)
      assert.equals('img2sixel', calls[1].cmd[1])
    end)
    restore()
    if not ok then error(err, 0) end
  end)

  it('falls through to convert when img2sixel is absent', function()
    local senc, calls, restore = with_mocks(
      { img2sixel = false, convert = true },
      function() return { code = 0, stdout = 'FAKE_SIXEL_FROM_CONVERT' } end,
      true)
    local ok, err = pcall(function()
      local out = senc.encode_sixel_dispatch(rgba, 1, 1)
      assert.equals('FAKE_SIXEL_FROM_CONVERT', out)
      assert.equals(1, #calls)
      assert.equals('convert', calls[1].cmd[1])
    end)
    restore()
    if not ok then error(err, 0) end
  end)

  it('uses pure Lua when accelerate=false', function()
    local senc, calls, restore = with_mocks(
      { img2sixel = true, convert = true },
      function() return { code = 0, stdout = 'SHOULD_NOT_BE_USED' } end,
      false)
    local ok, err = pcall(function()
      local out = senc.encode_sixel_dispatch(rgba, 1, 1)
      assert.equals(0, #calls)
      -- Pure-Lua output starts with the DCS introducer.
      assert.matches('^\027Pq', out)
    end)
    restore()
    if not ok then error(err, 0) end
  end)

  it('falls back to convert when img2sixel returns non-zero', function()
    local senc, calls, restore = with_mocks(
      { img2sixel = true, convert = true },
      function(cmd)
        if cmd[1] == 'img2sixel' then return { code = 1, stdout = '' } end
        return { code = 0, stdout = 'FAKE_SIXEL_FROM_CONVERT' }
      end,
      true)
    local ok, err = pcall(function()
      local out = senc.encode_sixel_dispatch(rgba, 1, 1)
      assert.equals('FAKE_SIXEL_FROM_CONVERT', out)
      assert.equals(2, #calls)
      assert.equals('img2sixel', calls[1].cmd[1])
      assert.equals('convert',   calls[2].cmd[1])
    end)
    restore()
    if not ok then error(err, 0) end
  end)

  it('falls back to pure Lua when both tools fail', function()
    local senc, calls, restore = with_mocks(
      { img2sixel = true, convert = true },
      function() return { code = 1, stdout = '' } end,
      true)
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
      { img2sixel = false, convert = false },
      function() return { code = 0, stdout = 'NEVER' } end,
      true)
    local ok, err = pcall(function()
      local out = senc.encode_sixel_dispatch(rgba, 1, 1)
      assert.equals(0, #calls)
      assert.matches('^\027Pq', out)
    end)
    restore()
    if not ok then error(err, 0) end
  end)
end)

describe('crop_and_encode_sixel', function()
  local png_bytes = 'FAKEPNG'

  it('invokes convert with -crop geometry when accelerate=true', function()
    local senc, calls, restore = with_mocks(
      { img2sixel = false, convert = true },
      function() return { code = 0, stdout = 'CROPPED_SIXEL' } end,
      true)
    local ok, err = pcall(function()
      local out = senc.crop_and_encode_sixel(png_bytes, 5, 7, 11, 13)
      assert.equals('CROPPED_SIXEL', out)
      assert.equals(1, #calls)
      local cmd = calls[1].cmd
      assert.equals('convert', cmd[1])
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

  it('returns nil when accelerate=false (caller falls back)', function()
    local senc, calls, restore = with_mocks(
      { img2sixel = true, convert = true },
      function() return { code = 0, stdout = 'NEVER' } end,
      false)
    local ok, err = pcall(function()
      local out = senc.crop_and_encode_sixel(png_bytes, 0, 0, 1, 1)
      assert.is_nil(out)
      assert.equals(0, #calls)
    end)
    restore()
    if not ok then error(err, 0) end
  end)

  it('returns nil when convert is unavailable', function()
    local senc, _, restore = with_mocks(
      { img2sixel = true, convert = false },
      function() return { code = 0, stdout = 'NEVER' } end,
      true)
    local ok, err = pcall(function()
      local out = senc.crop_and_encode_sixel(png_bytes, 0, 0, 1, 1)
      assert.is_nil(out)
    end)
    restore()
    if not ok then error(err, 0) end
  end)
end)

describe('crop_and_encode_png', function()
  local png_bytes = 'FAKEPNG'

  it('invokes convert with png:- when accelerate=true', function()
    local senc, calls, restore = with_mocks(
      { img2sixel = false, convert = true },
      function() return { code = 0, stdout = 'CROPPED_PNG' } end,
      true)
    local ok, err = pcall(function()
      local out = senc.crop_and_encode_png(png_bytes, 1, 2, 3, 4)
      assert.equals('CROPPED_PNG', out)
      assert.equals(1, #calls)
      -- Last positional should be 'png:-'.
      local cmd = calls[1].cmd
      assert.equals('png:-', cmd[#cmd])
    end)
    restore()
    if not ok then error(err, 0) end
  end)

  it('returns nil when accelerate=false', function()
    local senc, _, restore = with_mocks(
      { img2sixel = true, convert = true },
      function() return { code = 0, stdout = 'NEVER' } end,
      false)
    local ok, err = pcall(function()
      assert.is_nil(senc.crop_and_encode_png(png_bytes, 0, 0, 1, 1))
    end)
    restore()
    if not ok then error(err, 0) end
  end)
end)

-- Integration: a buffer-anchored placement gets cropped because its window is
-- too short, the sixel provider's fast path detects PNG input + no resize
-- requested + convert available, and feeds the original PNG through
-- `convert -crop`. We assert the captured emit contains the canned bytes
-- returned by our mock convert.
describe('accel-with-crop integration', function()
  local function read_fixture()
    local f = io.open('test/fixtures/4x4.png', 'rb')
    local b = f:read('*a'); f:close()
    return b
  end

  it('sixel provider routes a window-clipped placement through convert', function()
    local saved_system     = vim.system
    local saved_executable = vim.fn.executable
    local saved_g          = vim.g.alt_image

    vim.fn.executable = function(name)
      if name == 'convert'   then return 1 end
      if name == 'img2sixel' then return 0 end
      return saved_executable(name)
    end
    local convert_calls = {}
    vim.system = function(cmd, opts)
      table.insert(convert_calls, { cmd = cmd, opts = opts })
      return { wait = function()
        return { code = 0, stdout = 'CONVERT_SIXEL_BYTES' }
      end }
    end

    -- Reload everything under the new env.
    package.loaded['alt-image']               = nil
    package.loaded['alt-image._util']         = nil
    package.loaded['alt-image._sixel_encode'] = nil
    package.loaded['alt-image._png_encode']   = nil
    package.loaded['alt-image.sixel']         = nil
    package.loaded['alt-image._render']       = nil
    package.loaded['alt-image._carrier']      = nil
    vim.g.alt_image = { accelerate = true }
    require('alt-image._util')._reset_executable_cache()

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

    -- We expect convert to have been invoked at least once (either via the
    -- combined crop+encode fast path, or via encode_sixel_dispatch on the
    -- already-cropped RGBA buffer).
    local saw_convert = false
    for _, call in ipairs(convert_calls) do
      if call.cmd[1] == 'convert' then saw_convert = true; break end
    end

    -- Verify the captured emit contains our canned bytes.
    local cap = H.captured()
    local saw_canned = cap:find('CONVERT_SIXEL_BYTES', 1, true) ~= nil

    img.del(id)
    vim.cmd('resize')

    -- Restore.
    vim.system        = saved_system
    vim.fn.executable = saved_executable
    vim.g.alt_image   = saved_g

    assert.is_true(saw_convert, 'expected convert to be invoked')
    assert.is_true(saw_canned,
      'expected captured emit to contain canned CONVERT_SIXEL_BYTES')
  end)
end)

-- After this spec finishes, restore deterministic defaults for any later
-- specs that share the alt-image config.
describe('accel cleanup', function()
  it('leaves accelerate=false for subsequent specs', function()
    vim.g.alt_image = { accelerate = false }
    assert.equals(false, (vim.g.alt_image or {}).accelerate)
    -- Tag H so static analyzers don't flag the import as unused.
    _ = H
  end)
end)
