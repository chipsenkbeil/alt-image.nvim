local util = require('alt-image._util')
local H = require('test.helpers')
local senc = require('alt-image._sixel_encode')

describe('harness', function()
  it('runs a passing test', function()
    assert.equals(1, 1)
  end)

  it('does deep equal', function()
    assert.same({ a = { b = 1 } }, { a = { b = 1 } })
  end)
end)

describe('_util', function()
  it('query_csi falls back synchronously when vim.tty absent', function()
    local saved = rawget(vim, 'tty')
    rawset(vim, 'tty', nil)
    local done = false
    util.query_csi('whatever', { timeout = 10 }, function(r) done = (r == nil) end)
    assert.is_true(done)  -- synchronous; no vim.wait needed
    rawset(vim, 'tty', saved)
  end)
end)

describe('_png', function()
  local png = require('alt-image._png')

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
