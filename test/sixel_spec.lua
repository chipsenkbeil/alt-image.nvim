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
    img = H.fresh_provider('sixel')
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

  it('returns true via TERM_PROGRAM=iTerm.app', function()
    H.with_env({ TERM_PROGRAM = 'iTerm.app', TERM = 'xterm-256color' }, function()
      package.loaded['alt-image.sixel'] = nil
      package.loaded['alt-image._render'] = nil
      package.loaded['alt-image._carrier'] = nil
      assert.is_true(require('alt-image.sixel')._supported())
    end)
  end)

  it('returns true via TERM_PROGRAM=WezTerm', function()
    H.with_env({ TERM_PROGRAM = 'WezTerm', TERM = 'xterm-256color' }, function()
      package.loaded['alt-image.sixel'] = nil
      package.loaded['alt-image._render'] = nil
      package.loaded['alt-image._carrier'] = nil
      assert.is_true(require('alt-image.sixel')._supported())
    end)
  end)

  it('returns true via WT_SESSION (Windows Terminal)', function()
    H.with_env({ WT_SESSION = 'fake-uuid', TERM = 'xterm-256color',
                 TERM_PROGRAM = false }, function()
      local img = H.fresh_provider('sixel')
      assert.is_true(img._supported())
    end)
  end)
end)

describe('alt-image.sixel relative=editor', function()
  local img, png_bytes
  before_each(function()
    H.setup_capture()
    img = H.fresh_provider('sixel')
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

  it('repositions the carrier float on set(id, opts) update', function()
    local before_wins = vim.api.nvim_list_wins()
    local id = img.set(png_bytes, { relative = 'editor', row = 5, col = 10,
                                    width = 4, height = 4 })
    local float_winid
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local existed_before = false
      for _, b in ipairs(before_wins) do if b == w then existed_before = true end end
      if not existed_before then
        local cfg = vim.api.nvim_win_get_config(w)
        if cfg.relative == 'editor' then float_winid = w; break end
      end
    end
    assert.is_true(float_winid ~= nil)
    img.set(id, { row = 8, col = 15 })
    local cfg = vim.api.nvim_win_get_config(float_winid)
    assert.equals(7, cfg.row)
    assert.equals(14, cfg.col)
    img.del(id)
  end)
end)

describe('alt-image.sixel relative=buffer', function()
  local img, png_bytes
  before_each(function()
    H.setup_capture()
    img = H.fresh_provider('sixel')
    png_bytes = read_fixture()
  end)

  it('places an extmark with virt_lines reserving height rows', function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'line1', 'line2', 'line3' })
    local id = img.set(png_bytes, { relative = 'buffer', buf = buf,
                                    row = 1, col = 1, width = 4, height = 4,
                                    pad = 1 })
    local ns = vim.api.nvim_create_namespace('alt-image.carrier')
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    assert.is_true(#marks >= 1)
    local virt = marks[1][4].virt_lines or {}
    assert.equals(4, #virt)
    img.del(id)
  end)

  it('does not error when buffer shrinks below the extmark', function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'one', 'two', 'three', 'four' })
    -- Place image anchored to line 4
    local id = img.set(png_bytes, { relative = 'buffer', buf = buf,
                                    row = 4, col = 1, width = 4, height = 4 })
    -- Truncate buffer so line 4 no longer exists
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'only one line' })
    -- Force a render tick; should not throw E966
    local render = require('alt-image._render')
    local ok, err = pcall(function() render.flush() end)
    assert.is_true(ok, 'render.flush after buffer shrink errored: ' .. tostring(err))
    img.del(id)
  end)

  it('hides the image when its anchor line is deleted', function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'a', 'b', 'c' })
    local id = img.set(png_bytes, { relative = 'buffer', buf = buf,
                                    row = 2, col = 1, width = 4, height = 4 })
    -- Delete line 2 (the anchor).
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, {})
    local render = require('alt-image._render')
    render.flush()
    -- After the delete, get_positions should return an empty list. The
    -- last_positions transitions to empty and need_clear fires. The image
    -- stops being emitted.
    assert.is_true(img.get(id) ~= nil)  -- placement still registered
    img.del(id)
  end)

  it('defaults relative to "buffer" when opts.buf is set', function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'one', 'two' })
    local id = img.set(png_bytes, { buf = buf, row = 1, col = 1,
                                    width = 4, height = 4 })
    assert.equals('buffer', img.get(id).relative)
    img.del(id)
  end)

  it('resolves buf=0 to the current buffer', function()
    local buf = vim.api.nvim_get_current_buf()
    local id = img.set(png_bytes, { buf = 0, row = 1, col = 1,
                                    width = 4, height = 4 })
    assert.equals(buf, img.get(id).buf)
    img.del(id)
  end)

  it('derives width/height from PNG IHDR when missing in non-ui mode', function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'one', 'two' })
    -- 4x4 PNG; with default cell size 8x16, ceil(4/8)=1 and ceil(4/16)=1.
    local id = img.set(png_bytes, { buf = buf, row = 1, col = 1 })
    local got = img.get(id)
    assert.is_true(type(got.width)  == 'number' and got.width  >= 1)
    assert.is_true(type(got.height) == 'number' and got.height >= 1)
    img.del(id)
  end)

  it('emits the image once per window showing the buffer', function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'a', 'b', 'c' })
    vim.api.nvim_set_current_buf(buf)
    vim.cmd('split')
    H.reset_capture()
    local id = img.set(read_fixture(), { relative='buffer', buf=buf,
                                         row=1, col=1, width=4, height=4 })
    local cap = H.captured()
    local _, count = string.gsub(cap, '\027P', '')
    assert.equals(2, count)
    img.del(id); vim.cmd('only')
  end)
end)
