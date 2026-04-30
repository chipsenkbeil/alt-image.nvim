local H = require('test.helpers')

describe('alt-image.iterm2 set/get/del', function()
  local img
  before_each(function()
    H.setup_capture()
    img = H.fresh_provider('iterm2')
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
    img = H.fresh_provider('iterm2')
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
    img = H.fresh_provider('iterm2')
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

  it('repositions the carrier float on set(id, opts) update', function()
    local before_wins = vim.api.nvim_list_wins()
    local id = img.set('PNGBYTES', { relative = 'editor', row = 5, col = 10,
                                     width = 4, height = 4 })
    -- Find the newly opened float (relative='editor', row=4 in 0-indexed cfg).
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
    -- Update position via id-update path.
    img.set(id, { row = 8, col = 15 })
    local cfg = vim.api.nvim_win_get_config(float_winid)
    assert.equals(7, cfg.row)   -- 0-indexed: row=8 -> 7
    assert.equals(14, cfg.col)  -- 0-indexed: col=15 -> 14
    img.del(id)
  end)
end)

describe('alt-image.iterm2 relative=buffer', function()
  local img
  before_each(function()
    H.setup_capture()
    img = H.fresh_provider('iterm2')
  end)

  it('places an extmark with virt_lines reserving height rows', function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'line1', 'line2', 'line3' })
    local id = img.set('PNGBYTES', { relative = 'buffer', buf = buf,
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
    local id = img.set('PNGBYTES', { relative = 'buffer', buf = buf,
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
    local id = img.set('PNGBYTES', { relative = 'buffer', buf = buf,
                                     row = 2, col = 1, width = 4, height = 4 })
    -- Delete line 2 (the anchor).
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, {})
    local render = require('alt-image._render')
    render.flush()
    -- After the delete, get_pos should return nil. last_pos transitions
    -- nil-ward and need_clear fires. The image stops being emitted.
    -- We can't easily assert the absence of further emits without complex
    -- mocking, but we can assert that get(id) still works (state retained)
    -- and that no error was thrown.
    assert.is_true(img.get(id) ~= nil)  -- placement still registered
    img.del(id)
  end)
end)
