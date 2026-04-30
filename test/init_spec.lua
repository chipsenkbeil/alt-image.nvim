local H = require('test.helpers')

describe('alt-image init', function()
  before_each(function()
    package.loaded['alt-image']        = nil
    package.loaded['alt-image.iterm2'] = nil
    package.loaded['alt-image.sixel']  = nil
  end)

  it('picks iterm2 when TERM_PROGRAM=iTerm.app', function()
    H.with_env({ TERM_PROGRAM = 'iTerm.app' }, function()
      local m = require('alt-image')
      assert.equals(require('alt-image.iterm2'), m._provider())
    end)
  end)

  it('picks sixel when TERM matches sixel', function()
    H.with_env({ TERM_PROGRAM = false, TERM = 'xterm-sixel' }, function()
      local m = require('alt-image')
      assert.equals(require('alt-image.sixel'), m._provider())
    end)
  end)

  it('setup({protocol=...}) overrides autodetect', function()
    H.with_env({ TERM_PROGRAM = 'iTerm.app' }, function()
      local m = require('alt-image')
      m.setup({ protocol = 'sixel' })
      assert.equals(require('alt-image.sixel'), m._provider())
    end)
  end)

  it('forwards set/get/del to chosen provider', function()
    H.with_env({ TERM_PROGRAM = 'iTerm.app' }, function()
      H.setup_capture()
      local m = require('alt-image')
      local id = m.set('PNGBYTES', { row = 1, col = 1 })
      assert.is_true(type(id) == 'number')
      assert.same({ row = 1, col = 1, relative = 'ui' }, m.get(id))
      assert.is_true(m.del(id))
    end)
  end)
end)
