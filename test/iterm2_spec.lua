local H = require('test.helpers')

describe('alt-image.iterm2 set/get/del', function()
  local img
  before_each(function()
    H.setup_capture()
    package.loaded['alt-image.iterm2'] = nil
    package.loaded['alt-image._render'] = nil
    package.loaded['alt-image._carrier'] = nil
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
    package.loaded['alt-image._render'] = nil
    package.loaded['alt-image._carrier'] = nil
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

describe('alt-image.iterm2 _supported', function()
  before_each(function()
    package.loaded['alt-image.iterm2'] = nil
  end)

  it('returns true via TERM_PROGRAM=iTerm.app fast path', function()
    H.with_env({ TERM_PROGRAM = 'iTerm.app' }, function()
      local img = require('alt-image.iterm2')
      assert.is_true(img._supported())
    end)
  end)

  it('returns true via TERM_PROGRAM=WezTerm', function()
    H.with_env({ TERM_PROGRAM = 'WezTerm' }, function()
      local img = require('alt-image.iterm2')
      assert.is_true(img._supported())
    end)
  end)

  it('returns false on unknown TERM_PROGRAM with no probe response', function()
    H.with_env({ TERM_PROGRAM = 'XYZ' }, function()
      local img = require('alt-image.iterm2')
      local ok, _ = img._supported({ timeout = 10 })
      assert.is_false(ok)
    end)
  end)
end)

describe('alt-image.iterm2 relative=editor', function()
  local img
  before_each(function()
    H.setup_capture()
    package.loaded['alt-image.iterm2'] = nil
    package.loaded['alt-image._render'] = nil
    package.loaded['alt-image._carrier'] = nil
    img = require('alt-image.iterm2')
  end)

  it('opens a floating-window carrier and emits at its screen pos', function()
    local before_wins = #vim.api.nvim_list_wins()
    local id = img.set('PNGBYTES', { relative = 'editor', row = 5, col = 10,
                                     width = 4, height = 4 })
    assert.is_true(#vim.api.nvim_list_wins() == before_wins + 1)  -- one float opened
    img.del(id)
    vim.wait(50)
    assert.is_true(#vim.api.nvim_list_wins() == before_wins)
  end)
end)

describe('alt-image.iterm2 relative=buffer', function()
  local img
  before_each(function()
    H.setup_capture()
    package.loaded['alt-image.iterm2'] = nil
    package.loaded['alt-image._render'] = nil
    package.loaded['alt-image._carrier'] = nil
    img = require('alt-image.iterm2')
  end)

  it('places an extmark with virt_lines reserving height + 2*pad rows', function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'line1', 'line2', 'line3' })
    local id = img.set('PNGBYTES', { relative = 'buffer', buf = buf,
                                     row = 1, col = 1, width = 4, height = 4,
                                     pad = 1 })
    local ns = vim.api.nvim_create_namespace('alt-image.carrier')
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    assert.is_true(#marks >= 1)
    local virt = marks[1][4].virt_lines or {}
    assert.equals(4 + 2 * 1, #virt)
    img.del(id)
  end)
end)
