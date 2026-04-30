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

describe('alt-image.sixel _supported', function()
  before_each(function() package.loaded['alt-image.sixel'] = nil end)

  it('returns true when TERM matches *sixel*', function()
    H.with_env({ TERM = 'xterm-sixel' }, function()
      assert.is_true(require('alt-image.sixel')._supported())
    end)
  end)

  it('returns true for known terms (foot, mlterm, contour)', function()
    for _, t in ipairs({ 'foot', 'mlterm', 'contour' }) do
      H.with_env({ TERM = t }, function()
        package.loaded['alt-image.sixel'] = nil
        assert.is_true(require('alt-image.sixel')._supported())
      end)
    end
  end)

  it('returns false for Apple Terminal explicitly', function()
    H.with_env({ TERM_PROGRAM = 'Apple_Terminal', TERM = 'xterm-256color' }, function()
      assert.is_false(require('alt-image.sixel')._supported({ timeout = 10 }))
    end)
  end)
end)

describe('alt-image.sixel relative=editor', function()
  local img, png_bytes
  before_each(function()
    H.setup_capture()
    package.loaded['alt-image.sixel'] = nil
    img = require('alt-image.sixel')
    png_bytes = read_fixture()
  end)

  it('opens a floating-window carrier and emits at its screen pos', function()
    local before_wins = #vim.api.nvim_list_wins()
    local id = img.set(png_bytes, { relative = 'editor', row = 5, col = 10,
                                    width = 4, height = 4 })
    assert.is_true(#vim.api.nvim_list_wins() == before_wins + 1)
    img.del(id)
    vim.wait(50)
    assert.is_true(#vim.api.nvim_list_wins() == before_wins)
  end)
end)

describe('alt-image.sixel relative=buffer', function()
  local img, png_bytes
  before_each(function()
    H.setup_capture()
    package.loaded['alt-image.sixel'] = nil
    img = require('alt-image.sixel')
    png_bytes = read_fixture()
  end)

  it('places an extmark with virt_lines reserving height + 2*pad rows', function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'line1', 'line2', 'line3' })
    local id = img.set(png_bytes, { relative = 'buffer', buf = buf,
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
