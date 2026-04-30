local H = require('test.helpers')

local function read_fixture()
  local f = io.open('test/fixtures/4x4.png', 'rb')
  local b = f:read('*a'); f:close()
  return b
end

describe('alt-image.sixel set/get/del', function()
  local img, png_bytes
  before_each(function()
    H.setup_capture()
    package.loaded['alt-image.sixel'] = nil
    img = require('alt-image.sixel')
    png_bytes = read_fixture()
  end)

  it('emits a DCS sixel sequence on set', function()
    local id = img.set(png_bytes, { row = 1, col = 1, width = 4, height = 4 })
    assert.is_true(type(id) == 'number')
    local raw = H.captured():match('\027P[^\027]*\027\\')
    local r = H.parse_sixel_seq(raw)
    assert.is_true(r ~= nil)
    assert.is_true(r.raster.w > 0 and r.raster.h > 0)
    assert.is_true(next(r.palette) ~= nil)
  end)

  it('get returns canonicalized opts; nil for missing id', function()
    local id = img.set(png_bytes, { row = 2, col = 3, width = 4, height = 4 })
    assert.same({ row = 2, col = 3, width = 4, height = 4, relative = 'ui' }, img.get(id))
    assert.is_nil(img.get(99999))
  end)

  it('update by id partial-merges and reuses id', function()
    local id = img.set(png_bytes, { row = 2, col = 3, width = 4, height = 4 })
    H.reset_capture()
    local id2 = img.set(id, { row = 5 })
    assert.equals(id, id2)
    assert.same({ row = 5, col = 3, width = 4, height = 4, relative = 'ui' }, img.get(id))
  end)

  it('del returns true then false; del(math.huge) clears all', function()
    local id = img.set(png_bytes, {})
    assert.is_true(img.del(id))
    assert.is_false(img.del(id))
    img.set(png_bytes, {}); img.set(png_bytes, {})
    assert.is_true(img.del(math.huge))
    assert.is_false(img.del(math.huge))
  end)
end)
