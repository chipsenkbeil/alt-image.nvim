local H = require('test.helpers')
local senc = require('alt-image.sixel._encode')

describe('harness', function()
  it('runs a passing test', function()
    assert.equals(1, 1)
  end)

  it('does deep equal', function()
    assert.same({ a = { b = 1 } }, { a = { b = 1 } })
  end)
end)

describe('_png', function()
  local png = require('alt-image._core.png')

  it('decodes the 4x4 fixture', function()
    local f = assert(io.open('test/fixtures/4x4.png', 'rb'))
    local bytes = f:read('*a'); f:close()
    local img = png.decode(bytes)
    assert.equals(4, img.width)
    assert.equals(4, img.height)
    -- 16 pixels x 4 bytes (RGBA) = 64 bytes of pixel data
    assert.equals(16 * 4, #img.pixels)
  end)
end)

describe('helpers', function()
  it('parses an iterm2 OSC 1337 sequence', function()
    local seq = '\027]1337;File=size=12;inline=1;width=4:aGVsbG8\007'
    local r = H.parse_iterm2_seq(seq)
    assert.same({ size = '12', inline = '1', width = '4' }, r.args)
    assert.equals('aGVsbG8', r.payload)
  end)

  it('parses a sixel DCS sequence', function()
    local seq = '\027Pq"1;1;4;4#0;2;100;0;0$-\027\\'
    local r = H.parse_sixel_seq(seq)
    assert.same({ pan = 1, pad = 1, w = 4, h = 4 }, r.raster)
    assert.same({ 100, 0, 0 }, r.palette[0])
  end)
end)

describe('_util.png_dimensions', function()
  local util = require('alt-image._core.util')

  it('parses width and height from a real PNG', function()
    local f = assert(io.open('test/fixtures/4x4.png', 'rb'))
    local data = f:read('*a'); f:close()
    local w, h = util.png_dimensions(data)
    assert.equals(4, w)
    assert.equals(4, h)
  end)

  it('returns nil for non-PNG input', function()
    local w, h = util.png_dimensions('not a png')
    assert.is_nil(w)
    assert.is_nil(h)
  end)

  it('returns nil for too-short PNG-signature input', function()
    -- Valid 8-byte signature, but truncated before the IHDR width/height.
    local data = '\137PNG\r\n\26\n' .. string.rep('\0', 4)
    local w, h = util.png_dimensions(data)
    assert.is_nil(w)
    assert.is_nil(h)
  end)
end)

describe('_util.clip_to_bounds', function()
  local util = require('alt-image._core.util')

  it('image fully inside bounds → src covers full image', function()
    local p = util.clip_to_bounds(5, 5, 4, 4, 1, 1, 24, 80)
    assert.is_not_nil(p)
    assert.equals(5, p.row)
    assert.equals(5, p.col)
    assert.equals(0, p.src.x)
    assert.equals(0, p.src.y)
    assert.equals(4, p.src.w)
    assert.equals(4, p.src.h)
  end)

  it('image extends past right → src.w shrinks, src.x = 0', function()
    -- Image 4x4 anchored at col=78 in 80-col terminal → only 3 cols visible.
    local p = util.clip_to_bounds(1, 78, 4, 4, 1, 1, 24, 80)
    assert.is_not_nil(p)
    assert.equals(0, p.src.x)
    assert.equals(0, p.src.y)
    assert.equals(3, p.src.w)
    assert.equals(4, p.src.h)
  end)

  it('image extends past bottom → src.h shrinks, src.y = 0', function()
    -- Image 4x4 anchored at row=22 in 24-row terminal → only 3 rows visible.
    local p = util.clip_to_bounds(22, 1, 4, 4, 1, 1, 24, 80)
    assert.is_not_nil(p)
    assert.equals(0, p.src.x)
    assert.equals(0, p.src.y)
    assert.equals(4, p.src.w)
    assert.equals(3, p.src.h)
  end)

  it('image extends past top → src.y > 0, src.h reduced', function()
    -- Image 4x4 anchored at row=-1 (above bounds top=1).
    local p = util.clip_to_bounds(-1, 1, 4, 4, 1, 1, 24, 80)
    assert.is_not_nil(p)
    assert.equals(1, p.row)
    assert.equals(2, p.src.y)  -- 2 rows of image are above the bound
    assert.equals(0, p.src.x)
    assert.equals(4, p.src.w)
    assert.equals(2, p.src.h)
  end)

  it('image extends past left → src.x > 0, src.w reduced', function()
    -- Image 4x4 anchored at col=-1 (left of bounds left=1).
    local p = util.clip_to_bounds(1, -1, 4, 4, 1, 1, 24, 80)
    assert.is_not_nil(p)
    assert.equals(1, p.col)
    assert.equals(2, p.src.x)  -- 2 cols of image are left of the bound
    assert.equals(0, p.src.y)
    assert.equals(2, p.src.w)
    assert.equals(4, p.src.h)
  end)

  it('image entirely outside bounds → returns nil', function()
    -- Anchored well past the bottom-right corner.
    assert.is_nil(util.clip_to_bounds(100, 100, 4, 4, 1, 1, 24, 80))
    -- Anchored well above the top.
    assert.is_nil(util.clip_to_bounds(-10, 1, 4, 4, 1, 1, 24, 80))
  end)
end)

describe('_sixel_encode', function()
  it('encodes a 4x4 solid-red RGBA buffer to a DCS sequence', function()
    -- 4x4 fully opaque red
    local rgba = string.rep(string.char(255, 0, 0, 255), 4 * 4)
    local s = senc.encode_sixel(rgba, 4, 4)
    assert.matches('^\027Pq', s)
    assert.matches('\027\\$', s)
    -- Palette must contain a red entry (close to 100;0;0 in 0-100 scale)
    assert.matches('#%d+;2;100;0;0', s)
  end)
end)
