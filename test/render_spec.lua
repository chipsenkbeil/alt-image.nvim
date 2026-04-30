local H = require('test.helpers')

describe('alt-image._render', function()
  before_each(function()
    H.setup_capture()
    package.loaded['alt-image._render'] = nil
  end)

  it('refresh is a no-op when no placements registered', function()
    local r = require('alt-image._render')
    r.refresh()
    assert.equals('', H.captured())
  end)

  it('rerender_all emits SYNC_START and SYNC_END even when registry is empty', function()
    -- This is intentional: del() unregisters placements, then calls
    -- rerender_all() to clear leftover pixels. So the sync wrappers must
    -- still fire on an empty registry.
    local r = require('alt-image._render')
    r.rerender_all()
    local cap = H.captured()
    assert.matches('\027%[%?2026h', cap)
    assert.matches('\027%[%?2026l', cap)
  end)

  it('register and unregister manage the placement registry', function()
    local r = require('alt-image._render')
    local emitted = false
    local fake_provider = { _emit_at = function() emitted = true end }
    r.register(fake_provider, 1, function() return { row = 1, col = 1 } end)
    r.refresh()
    assert.is_true(emitted)
    r.unregister(fake_provider, 1)
    emitted = false
    r.refresh()
    assert.is_false(emitted)
  end)
end)
