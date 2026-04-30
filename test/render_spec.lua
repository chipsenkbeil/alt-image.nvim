local H = require('test.helpers')

describe('alt-image._render', function()
  local render

  before_each(function()
    H.setup_capture()
    package.loaded['alt-image._render'] = nil
    render = require('alt-image._render')
  end)

  it('register + flush emits via provider._emit_at', function()
    local emitted = {}
    local fake = {
      _emit_at = function(id, pos) emitted[#emitted + 1] = { id = id, pos = pos } end,
    }
    render.register(fake, 1, function() return { row = 5, col = 10 } end)
    render.flush()
    assert.equals(1, #emitted)
    assert.equals(5, emitted[1].pos.row)
    assert.equals(10, emitted[1].pos.col)
  end)

  it('flush is a no-op when nothing is dirty', function()
    local emitted = 0
    local fake = { _emit_at = function() emitted = emitted + 1 end }
    render.register(fake, 1, function() return { row = 1, col = 1 } end)
    render.flush()             -- emits once (initial)
    assert.equals(1, emitted)
    render.flush()             -- no dirty placements, no-op
    assert.equals(1, emitted)
  end)

  it('invalidate marks the placement dirty for the next flush', function()
    local emitted = 0
    local fake = { _emit_at = function() emitted = emitted + 1 end }
    render.register(fake, 1, function() return { row = 1, col = 1 } end)
    render.flush(); assert.equals(1, emitted)
    render.invalidate(fake, 1)
    render.flush(); assert.equals(2, emitted)
  end)

  it('unregister stops emitting that placement', function()
    local emitted = 0
    local fake = { _emit_at = function() emitted = emitted + 1 end }
    render.register(fake, 1, function() return { row = 1, col = 1 } end)
    render.flush()
    render.unregister(fake, 1)
    render.invalidate(fake, 1)  -- harmless on missing placement
    render.flush()
    assert.equals(1, emitted)   -- only the initial
  end)

  it('SYNC_START is emitted at the start of a non-empty tick', function()
    local fake = { _emit_at = function() end }
    render.register(fake, 1, function() return { row = 1, col = 1 } end)
    render.flush()
    assert.matches('\027%[%?2026h', H.captured())
  end)

  it('a clear-triggering invalidate redraws ALL placements, not just the dirty one', function()
    local emitted = { [1] = 0, [2] = 0, [3] = 0 }
    local fake = {
      _emit_at = function(id, _pos) emitted[id] = (emitted[id] or 0) + 1 end,
    }
    render.register(fake, 1, function() return { row = 1, col = 1 } end)
    render.register(fake, 2, function() return { row = 2, col = 2 } end)
    render.register(fake, 3, function() return { row = 3, col = 3 } end)
    render.flush()  -- initial paint: all three emitted once
    assert.equals(1, emitted[1])
    assert.equals(1, emitted[2])
    assert.equals(1, emitted[3])
    -- Mark only id 1 dirty WITH clear flag.
    render.invalidate(fake, 1, true)
    render.flush()
    -- Because clear_pending was set, all three should have been re-emitted.
    assert.equals(2, emitted[1])
    assert.equals(2, emitted[2])
    assert.equals(2, emitted[3])
  end)
end)
