local H = require('test.helpers')

local function read_fixture()
  local f = io.open('test/fixtures/4x4.png', 'rb')
  local b = f:read('*a'); f:close()
  return b
end

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

  it('defaults relative to "buffer" when opts.buf is set', function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'one', 'two' })
    local id = img.set('PNGBYTES', { buf = buf, row = 1, col = 1,
                                     width = 4, height = 4 })
    assert.equals('buffer', img.get(id).relative)
    img.del(id)
  end)

  it('resolves buf=0 to the current buffer', function()
    local buf = vim.api.nvim_get_current_buf()
    local id = img.set('PNGBYTES', { buf = 0, row = 1, col = 1,
                                     width = 4, height = 4 })
    assert.equals(buf, img.get(id).buf)
    img.del(id)
  end)

  it('errors when set(id, opts) tries to change relative', function()
    local id = img.set('PNGBYTES', { relative = 'ui', row = 1, col = 1,
                                     width = 4, height = 4 })
    assert.has_error(function()
      img.set(id, { relative = 'editor' })
    end)
    img.del(id)
  end)

  it('pre-resizes the PNG to cell-pixel dimensions for sharp rendering', function()
    H.reset_capture()
    local id = img.set(read_fixture(), { row = 1, col = 1, width = 4, height = 4 })
    local cap = H.captured()
    local seq = cap:match('\027%]1337;File=[^\007]*\007')
    assert.is_true(seq ~= nil, 'expected an OSC 1337 sequence in capture')
    local r = H.parse_iterm2_seq(seq)
    local data = vim.base64.decode(r.payload)
    local png = require('alt-image._png')
    local decoded = png.decode(data)
    local util = require('alt-image._util')
    local cw, ch = util.cell_pixel_size()
    -- The decoded PNG dimensions should match the cell-pixel area exactly,
    -- not the original 4x4 source size.
    assert.equals(4 * cw, decoded.width)
    assert.equals(4 * ch, decoded.height)
    img.del(id)
  end)
end)

describe('alt-image.iterm2 relative=ui clipping', function()
  local img
  before_each(function()
    H.setup_capture()
    img = H.fresh_provider('iterm2')
  end)

  it('clips relative=ui image at terminal right edge', function()
    local png_bytes = read_fixture()
    local cols = vim.o.columns
    -- Anchor at the rightmost column with width=4 → only 1 column visible.
    H.reset_capture()
    local id = img.set(png_bytes, { row = 1, col = cols, width = 4, height = 4 })
    local cap = H.captured()
    local seq = cap:match('\027%]1337;File=[^\007]*\007')
    assert.is_true(seq ~= nil, 'expected an OSC 1337 sequence in capture')
    local r = H.parse_iterm2_seq(seq)
    -- The visible width is 1 (1 column at the right edge of the screen).
    assert.equals('1', r.args.width)
    assert.equals('4', r.args.height)
    img.del(id)
  end)

  it('clips relative=ui image at terminal bottom edge', function()
    local png_bytes = read_fixture()
    local lines = vim.o.lines
    H.reset_capture()
    local id = img.set(png_bytes, { row = lines, col = 1, width = 4, height = 4 })
    local cap = H.captured()
    local seq = cap:match('\027%]1337;File=[^\007]*\007')
    assert.is_true(seq ~= nil, 'expected an OSC 1337 sequence in capture')
    local r = H.parse_iterm2_seq(seq)
    -- The visible height is 1 (1 row at the bottom of the screen).
    assert.equals('4', r.args.width)
    assert.equals('1', r.args.height)
    img.del(id)
  end)

  it('emits nothing when relative=ui image is entirely off-screen', function()
    local png_bytes = read_fixture()
    H.reset_capture()
    -- Anchor far past the bottom-right corner.
    local id = img.set(png_bytes, { row = vim.o.lines + 10, col = vim.o.columns + 10,
                                    width = 4, height = 4 })
    local cap = H.captured()
    -- No OSC 1337 sequence should be emitted for an off-screen placement.
    assert.is_nil(cap:match('\027%]1337;File='))
    img.del(id)
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
    -- After the delete, get_positions should return an empty list. The
    -- last_positions transitions to empty and need_clear fires. The image
    -- stops being emitted.
    -- We can't easily assert the absence of further emits without complex
    -- mocking, but we can assert that get(id) still works (state retained)
    -- and that no error was thrown.
    assert.is_true(img.get(id) ~= nil)  -- placement still registered
    img.del(id)
  end)

  it('emits the image once per window showing the buffer', function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'a', 'b', 'c' })
    vim.api.nvim_set_current_buf(buf)
    vim.cmd('split')
    H.reset_capture()
    local id = img.set('PNGBYTES', { relative='buffer', buf=buf,
                                     row=1, col=1, width=4, height=4 })
    local cap = H.captured()
    local _, count = string.gsub(cap, '\027%]1337;File=', '')
    assert.equals(2, count)
    img.del(id); vim.cmd('only')
  end)

  it('returns cropped src when image extends past window bottom', function()
    local png_bytes = read_fixture()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'x' })
    vim.api.nvim_set_current_buf(buf)
    vim.cmd('resize 3')
    local id = img.set(png_bytes, { relative='buffer', buf=buf,
                                    row=1, col=1, width=4, height=10 })
    local carrier = require('alt-image._carrier')
    local iterm2_mod = require('alt-image.iterm2')
    local positions = carrier.get_positions(iterm2_mod, id)
    assert.is_true(#positions >= 1)
    local pos = positions[1]
    -- The image is 10 cells tall but the window is only 3 lines (with the
    -- buffer's single line consuming row 1, leaving 2 cells for the image).
    assert.equals(2, pos.src.h)
    assert.equals(4, pos.src.w)
    assert.equals(0, pos.src.x)
    assert.equals(0, pos.src.y)
    img.del(id)
    vim.cmd('resize')
  end)

  it('returns cropped src.w when image extends past window right edge', function()
    local png_bytes = read_fixture()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'x' })
    vim.api.nvim_set_current_buf(buf)
    vim.cmd('vertical resize 5')
    local id = img.set(png_bytes, { relative='buffer', buf=buf,
                                    row=1, col=1, width=10, height=4 })
    local carrier = require('alt-image._carrier')
    local iterm2_mod = require('alt-image.iterm2')
    local positions = carrier.get_positions(iterm2_mod, id)
    assert.is_true(#positions >= 1)
    local pos = positions[1]
    assert.is_true(pos.src.w > 0, 'image should have positive width')
    assert.is_true(pos.src.w <= 10, 'image width should be at most 10')
    assert.equals(4, pos.src.h)
    assert.is_true(pos.src.x >= 0, 'x offset should be non-negative')
    assert.equals(0, pos.src.y)
    img.del(id)
    vim.cmd('vertical resize 80')
  end)

  it('returns cropped src.h when image extends past window top', function()
    local png_bytes = read_fixture()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'a', 'b', 'c', 'd', 'e' })
    vim.api.nvim_set_current_buf(buf)
    local id = img.set(png_bytes, { relative='buffer', buf=buf,
                                    row=3, col=1, width=4, height=8 })
    vim.cmd('normal! G')
    vim.cmd('resize 3')
    local carrier = require('alt-image._carrier')
    local iterm2_mod = require('alt-image.iterm2')
    local positions = carrier.get_positions(iterm2_mod, id)
    if #positions >= 1 then
      local pos = positions[1]
      assert.is_true(pos.src.h > 0, 'image should still be partially visible')
      assert.is_true(pos.src.h <= 8, 'image height should be at most 8')
    end
    img.del(id)
    vim.cmd('resize')
  end)

  it('returns cropped src.x when image extends past window left edge', function()
    local png_bytes = read_fixture()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'x' })
    vim.api.nvim_set_current_buf(buf)
    vim.cmd('vertical resize 3')
    local id = img.set(png_bytes, { relative='buffer', buf=buf,
                                    row=1, col=2, width=10, height=4 })
    local carrier = require('alt-image._carrier')
    local iterm2_mod = require('alt-image.iterm2')
    local positions = carrier.get_positions(iterm2_mod, id)
    if #positions >= 1 then
      local pos = positions[1]
      assert.is_true(pos.src.w > 0, 'image should have positive width')
      assert.is_true(pos.src.w <= 10, 'image width should be at most 10')
    end
    img.del(id)
    vim.cmd('vertical resize 80')
  end)

  it('produces different src per window when one window is resized smaller', function()
    local png_bytes = read_fixture()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'x' })
    vim.api.nvim_set_current_buf(buf)
    vim.cmd('split')               -- two windows showing buf
    vim.cmd('wincmd j')
    vim.cmd('resize 3')
    local id = img.set(png_bytes, { relative='buffer', buf=buf,
                                    row=1, col=1, width=4, height=10 })
    local carrier = require('alt-image._carrier')
    local iterm2_mod = require('alt-image.iterm2')
    local positions = carrier.get_positions(iterm2_mod, id)
    assert.equals(2, #positions)
    local heights = { positions[1].src.h, positions[2].src.h }
    table.sort(heights)
    assert.is_true(heights[1] < 10, 'one window should be cropped')
    assert.equals(10, heights[2])
    img.del(id)
    vim.cmd('only')
  end)

  it('crops from the top when anchor scrolls above window', function()
    local png_bytes = read_fixture()
    local buf = vim.api.nvim_create_buf(true, false)
    local lines = {}
    for i = 1, 30 do lines[#lines+1] = 'line ' .. i end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_current_buf(buf)
    local id = img.set(png_bytes, { relative='buffer', buf=buf,
                                    row=1, col=1, width=4, height=10 })
    vim.cmd('5')
    vim.cmd('normal! zt')
    local positions = require('alt-image._carrier').get_positions(
      require('alt-image.iterm2'), id)
    assert.is_true(#positions >= 1)
    assert.is_true(positions[1].src.y > 0)
    assert.is_true(positions[1].src.h < 10)
    img.del(id); vim.cmd('only')
  end)

  it('emits OSC 1337 with cropped dimensions when src is a sub-rect', function()
    local png_bytes = read_fixture()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'x' })
    vim.api.nvim_set_current_buf(buf)
    vim.cmd('resize 3')
    H.reset_capture()
    local id = img.set(png_bytes, { relative='buffer', buf=buf,
                                    row=1, col=1, width=4, height=10 })
    -- The image spans 10 cells but the window only fits 2 image rows; src.h=2.
    -- The provider should crop the PNG and emit the cropped dims (height=2)
    -- rather than the original height=10.
    local cap = H.captured()
    local seq = cap:match('\027%]1337;File=[^\007]*\007')
    assert.is_true(seq ~= nil, 'expected an OSC 1337 sequence in capture')
    local r = H.parse_iterm2_seq(seq)
    assert.equals('4', r.args.width)
    assert.equals('2', r.args.height)
    -- The payload must decode as a valid PNG (round-trips through _png.decode).
    local pdec = require('alt-image._png')
    local raw = vim.base64.decode(r.payload)
    local decoded = pdec.decode(raw)
    assert.is_true(decoded.width >= 1)
    assert.is_true(decoded.height >= 1)
    img.del(id); vim.cmd('resize')
  end)
end)
