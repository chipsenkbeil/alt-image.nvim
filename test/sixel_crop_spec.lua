-- test/sixel_crop_spec.lua
-- Tests for the pure crop_rgba helper in _core/image.lua.
local image = require('alt-image._core.image')

describe('_core.image.crop_rgba', function()
  -- Build a 4x4 RGBA where pixel (x,y) = (x*16, y*16, 0, 255).
  local function build_4x4()
    local bytes = {}
    for y = 0, 3 do
      for x = 0, 3 do
        bytes[#bytes+1] = string.char(x * 16, y * 16, 0, 255)
      end
    end
    return table.concat(bytes)
  end

  it('returns full image when crop matches source dims', function()
    local rgba = build_4x4()
    local out, w, h = image.crop_rgba(rgba, 4, 4, 0, 0, 4, 4)
    assert.equals(4, w); assert.equals(4, h)
    assert.equals(rgba, out)
  end)

  it('crops top: rows 1..3 of original', function()
    local rgba = build_4x4()
    local out, w, h = image.crop_rgba(rgba, 4, 4, 0, 1, 4, 3)
    assert.equals(4, w); assert.equals(3, h)
    -- First pixel of cropped is original (0, 1).
    assert.equals(string.char(0, 16, 0, 255), out:sub(1, 4))
  end)

  it('crops left: cols 1..3 of original', function()
    local rgba = build_4x4()
    local out, w, h = image.crop_rgba(rgba, 4, 4, 1, 0, 3, 4)
    assert.equals(3, w); assert.equals(4, h)
    -- First pixel of cropped is original (1, 0).
    assert.equals(string.char(16, 0, 0, 255), out:sub(1, 4))
  end)

  it('crops right: cols 0..2 of original', function()
    local rgba = build_4x4()
    local out, w, h = image.crop_rgba(rgba, 4, 4, 0, 0, 3, 4)
    assert.equals(3, w); assert.equals(4, h)
    -- Last pixel of first row is original (2, 0).
    assert.equals(string.char(32, 0, 0, 255), out:sub(9, 12))
  end)

  it('crops bottom: rows 0..2 of original', function()
    local rgba = build_4x4()
    local out, w, h = image.crop_rgba(rgba, 4, 4, 0, 0, 4, 3)
    assert.equals(4, w); assert.equals(3, h)
    -- Last row of cropped is row 2 of original; first pixel is (0, 2).
    assert.equals(string.char(0, 32, 0, 255), out:sub(33, 36))
  end)

  it('crops all four sides simultaneously', function()
    local rgba = build_4x4()
    local out, w, h = image.crop_rgba(rgba, 4, 4, 1, 1, 2, 2)
    assert.equals(2, w); assert.equals(2, h)
    -- First pixel of cropped is original (1, 1).
    assert.equals(string.char(16, 16, 0, 255), out:sub(1, 4))
  end)

  it('clamps out-of-range crop to source bounds', function()
    local rgba = build_4x4()
    local out, w, h = image.crop_rgba(rgba, 4, 4, 0, 0, 10, 10)
    assert.equals(4, w); assert.equals(4, h)
    assert.equals(rgba, out)
  end)
end)
