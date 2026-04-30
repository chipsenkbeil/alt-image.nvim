local H = require('test.helpers')

describe('alt-image.iterm2 set/get/del', function()
  local img
  before_each(function()
    H.setup_capture()
    package.loaded['alt-image.iterm2'] = nil
    img = require('alt-image.iterm2')
  end)

  it('set returns an id and emits an OSC 1337 sequence', function()
    local id = img.set('PNGBYTES', { row = 1, col = 1, width = 4, height = 4 })
    assert.is_true(type(id) == 'number')
    local r = H.parse_iterm2_seq(H.captured():match('\027%]1337;File=[^\007]*\007'))
    assert.equals('1', r.args.inline)
    assert.equals('4', r.args.width)
    assert.equals('4', r.args.height)
    assert.equals('0', r.args.preserveAspectRatio)  -- both dims given
  end)

  it('preserveAspectRatio=1 when only one dim given', function()
    img.set('PNGBYTES', { row = 1, col = 1, width = 4 })
    local r = H.parse_iterm2_seq(H.captured():match('\027%]1337;File=[^\007]*\007'))
    assert.equals('1', r.args.preserveAspectRatio)
  end)

  it('get returns opts; nil for missing id', function()
    local id = img.set('PNGBYTES', { row = 2, col = 3, width = 4, height = 4 })
    assert.same({ row = 2, col = 3, width = 4, height = 4, relative = 'ui' }, img.get(id))
    assert.is_nil(img.get(99999))
  end)

  it('update by id partial-merges opts and reuses id', function()
    local id = img.set('PNGBYTES', { row = 2, col = 3, width = 4, height = 4 })
    H.reset_capture()
    local id2 = img.set(id, { row = 5 })
    assert.equals(id, id2)
    assert.same({ row = 5, col = 3, width = 4, height = 4, relative = 'ui' }, img.get(id))
  end)

  it('del returns true the first time, false thereafter; get -> nil', function()
    local id = img.set('PNGBYTES', {})
    assert.is_true(img.del(id))
    assert.is_false(img.del(id))
    assert.is_nil(img.get(id))
  end)
end)

describe('alt-image.iterm2 del(math.huge)', function()
  local img
  before_each(function()
    H.setup_capture()
    package.loaded['alt-image.iterm2'] = nil
    img = require('alt-image.iterm2')
  end)

  it('clears all placements', function()
    local a = img.set('A', {}); local b = img.set('B', {})
    assert.is_true(img.del(math.huge))
    assert.is_nil(img.get(a))
    assert.is_nil(img.get(b))
    assert.is_false(img.del(math.huge))  -- nothing left
  end)
end)
