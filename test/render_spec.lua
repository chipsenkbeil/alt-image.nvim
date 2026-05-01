local H = require('test.helpers')

-- Helpers to build position records matching the new list-of-positions
-- contract. `pos(r, c)` returns a single-entry list at (r, c) covering a
-- 4x4 source rect.
local function pos(r, c, w, h)
  return { { row = r, col = c, src = { x = 0, y = 0, w = w or 4, h = h or 4 } } }
end

describe('alt-image._core.render', function()
  local render

  before_each(function()
    H.setup_capture()
    package.loaded['alt-image._core.render'] = nil
    render = require('alt-image._core.render')
  end)

  it('register + flush emits via provider._emit_at', function()
    local emitted = {}
    local fake = {
      _emit_at = function(id, p) emitted[#emitted + 1] = { id = id, pos = p } end,
    }
    render.register(fake, 1, function() return pos(5, 10) end)
    render.flush()
    assert.equals(1, #emitted)
    assert.equals(5, emitted[1].pos.row)
    assert.equals(10, emitted[1].pos.col)
  end)

  it('flush is a no-op when nothing is dirty', function()
    local emitted = 0
    local fake = { _emit_at = function() emitted = emitted + 1 end }
    render.register(fake, 1, function() return pos(1, 1) end)
    render.flush()             -- emits once (initial)
    assert.equals(1, emitted)
    render.flush()             -- no dirty placements, no-op
    assert.equals(1, emitted)
  end)

  it('invalidate marks the placement dirty for the next flush', function()
    local emitted = 0
    local fake = { _emit_at = function() emitted = emitted + 1 end }
    render.register(fake, 1, function() return pos(1, 1) end)
    render.flush(); assert.equals(1, emitted)
    render.invalidate(fake, 1)
    render.flush(); assert.equals(2, emitted)
  end)

  it('unregister stops emitting that placement', function()
    local emitted = 0
    local fake = { _emit_at = function() emitted = emitted + 1 end }
    render.register(fake, 1, function() return pos(1, 1) end)
    render.flush()
    render.unregister(fake, 1)
    render.invalidate(fake, 1)  -- harmless on missing placement
    render.flush()
    assert.equals(1, emitted)   -- only the initial
  end)

  it('SYNC_START is emitted at the start of a non-empty tick', function()
    local fake = { _emit_at = function() end }
    render.register(fake, 1, function() return pos(1, 1) end)
    render.flush()
    assert.matches('\027%[%?2026h', H.captured())
  end)

  it('invalidate of one placement re-emits only that placement (no clear)', function()
    local emitted = { [1] = 0, [2] = 0, [3] = 0 }
    local fake = {
      _emit_at = function(id, _p) emitted[id] = (emitted[id] or 0) + 1 end,
    }
    render.register(fake, 1, function() return pos(1, 1) end)
    render.register(fake, 2, function() return pos(2, 2) end)
    render.register(fake, 3, function() return pos(3, 3) end)
    render.flush()  -- initial paint: all three emitted once
    assert.equals(1, emitted[1])
    assert.equals(1, emitted[2])
    assert.equals(1, emitted[3])
    -- Mark only id 1 dirty. With same position, no clear is triggered;
    -- only the dirty placement should re-emit.
    render.invalidate(fake, 1)
    render.flush()
    assert.equals(2, emitted[1])
    assert.equals(1, emitted[2])
    assert.equals(1, emitted[3])
  end)

  it('position change of an invalidated placement triggers re-emit of all', function()
    local emitted = { [1] = 0, [2] = 0, [3] = 0 }
    local fake = {
      _emit_at = function(id, _p) emitted[id] = (emitted[id] or 0) + 1 end,
    }
    local pos1 = pos(1, 1)
    render.register(fake, 1, function() return pos1 end)
    render.register(fake, 2, function() return pos(2, 2) end)
    render.register(fake, 3, function() return pos(3, 3) end)
    render.flush()  -- initial paint: all three emitted once
    -- Move id 1 and invalidate. Position-diff should drive a clear, which
    -- re-emits all placements.
    pos1 = pos(9, 9)
    render.invalidate(fake, 1)
    render.flush()
    assert.equals(2, emitted[1])
    assert.equals(2, emitted[2])
    assert.equals(2, emitted[3])
  end)

  it('emits a freshly-registered placement on the first flush', function()
    local emitted = 0
    local fake = { _emit_at = function() emitted = emitted + 1 end }
    render.register(fake, 1, function() return pos(1, 1) end)
    render.flush()
    assert.equals(1, emitted)
  end)

  it('restores vim.o.termsync after a flush', function()
    local before = vim.o.termsync
    local fake = { _emit_at = function() end }
    render.register(fake, 1, function() return pos(1, 1) end)
    render.flush()
    assert.equals(before, vim.o.termsync)
  end)

  it('emits placements in zindex ascending order', function()
    local order = {}
    local fake = {
      _emit_at = function(id, _) order[#order + 1] = id end,
      get      = function(id) return ({ [10] = { zindex = 5 },
                                         [20] = { zindex = 1 },
                                         [30] = { zindex = 3 } })[id] end,
    }
    render.register(fake, 10, function() return pos(1, 1) end)
    render.register(fake, 20, function() return pos(2, 2) end)
    render.register(fake, 30, function() return pos(3, 3) end)
    render.flush()
    -- Lowest zindex emits first; highest emits last (so it paints on top).
    assert.same({ 20, 30, 10 }, order)
  end)
end)
