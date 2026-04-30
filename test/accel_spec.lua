-- test/accel_spec.lua
-- Tests for the external-tool acceleration dispatchers in _sixel_encode.lua.
-- We mock vim.system + vim.fn.executable so no real subprocess ever runs.

local H = require('test.helpers')

-- Stand up a controlled environment for one test:
-- - executable_for: { [name]=true|false } overrides for vim.fn.executable
-- - system_handler: function(cmd, opts) -> { code, stdout } (or nil to error)
-- - accelerate:     boolean for setup({ accelerate = ... })
-- Returns the fresh _sixel_encode module + a `calls` array recording each
-- vim.system invocation as { cmd = {...}, opts = {...} }.
local function with_mocks(executable_for, system_handler, accelerate)
  local saved_system     = vim.system
  local saved_executable = vim.fn.executable

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
  require('alt-image').setup({ accelerate = accelerate })
  local senc = require('alt-image._sixel_encode')
  -- Belt-and-suspenders: clear the executable cache in case the module was
  -- already loaded transitively before our reset (e.g. via setup()).
  require('alt-image._util')._reset_executable_cache()

  return senc, calls, function()
    vim.system     = saved_system
    vim.fn.executable = saved_executable
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

-- After this spec finishes, restore deterministic defaults for any later
-- specs that share the alt-image config (defensive: setup() default is on,
-- but other specs use H.fresh_provider which forces off again).
describe('accel cleanup', function()
  it('leaves accelerate=false for subsequent specs', function()
    require('alt-image').setup({ accelerate = false })
    -- Avoid leaking mocks (with_mocks restores per-test; this is just a
    -- defensive belt-and-suspenders check).
    assert.equals(false, require('alt-image')._config.accelerate)
    -- Tag H so static analyzers don't flag the import as unused.
    _ = H
  end)
end)
