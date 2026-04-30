-- test/png_encode_spec.lua
-- Round-trip tests for the pure-Lua PNG encoder. Encoded output is fed to
-- _png.decode (the existing decoder) to verify it produces a valid PNG.
local png_encode = require('alt-image._png_encode')
local png        = require('alt-image._png')

describe('_png_encode.encode', function()
  it('round-trips a 2x2 RGBA image', function()
    local rgba = string.char(
      255, 0,   0,   255,   0,   255, 0,   255,
      0,   0,   255, 255,   255, 255, 255, 255
    )
    local encoded = png_encode.encode(rgba, 2, 2)
    local img = png.decode(encoded)
    assert.equals(2, img.width)
    assert.equals(2, img.height)
    assert.equals(rgba, img.pixels)
  end)

  it('round-trips a single white pixel', function()
    local rgba = string.char(255, 255, 255, 255)
    local encoded = png_encode.encode(rgba, 1, 1)
    local img = png.decode(encoded)
    assert.equals(1, img.width)
    assert.equals(1, img.height)
    assert.equals(rgba, img.pixels)
  end)

  it('produces output starting with PNG signature', function()
    local rgba = string.char(0, 0, 0, 255)
    local encoded = png_encode.encode(rgba, 1, 1)
    assert.equals('\137PNG\r\n\26\n', encoded:sub(1, 8))
  end)

  it('round-trips a 4x4 gradient image', function()
    local bytes = {}
    for y = 0, 3 do
      for x = 0, 3 do
        bytes[#bytes + 1] = string.char(x * 16, y * 16, 0, 255)
      end
    end
    local rgba = table.concat(bytes)
    local encoded = png_encode.encode(rgba, 4, 4)
    local img = png.decode(encoded)
    assert.equals(4, img.width)
    assert.equals(4, img.height)
    assert.equals(rgba, img.pixels)
  end)

  it('round-trips an image with alpha variations', function()
    -- 2x1 image: opaque red, half-transparent blue.
    local rgba = string.char(255, 0, 0, 255,   0, 0, 255, 128)
    local encoded = png_encode.encode(rgba, 2, 1)
    local img = png.decode(encoded)
    assert.equals(rgba, img.pixels)
  end)
end)
