local util = require('alt-image._util')

describe('harness', function()
  it('runs a passing test', function()
    assert.equals(1, 1)
  end)

  it('does deep equal', function()
    assert.same({ a = { b = 1 } }, { a = { b = 1 } })
  end)
end)

describe('_util', function()
  it('query_csi falls back when vim.tty absent', function()
    local saved = rawget(vim, 'tty')
    rawset(vim, 'tty', nil)
    local done = false
    util.query_csi('whatever', { timeout = 10 }, function(r) done = (r == nil) end)
    vim.wait(50, function() return done end)
    assert.is_true(done)
    rawset(vim, 'tty', saved)
  end)
end)
