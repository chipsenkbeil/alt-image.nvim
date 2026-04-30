local H = require('test.helpers')

describe('alt-image init', function()
  local saved_g
  before_each(function()
    package.loaded['alt-image']        = nil
    package.loaded['alt-image.iterm2'] = nil
    package.loaded['alt-image.sixel']  = nil
    saved_g = vim.g.alt_image
    vim.g.alt_image = nil
  end)

  after_each(function()
    vim.g.alt_image = saved_g
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

  it('vim.g.alt_image.protocol overrides autodetect', function()
    H.with_env({ TERM_PROGRAM = 'iTerm.app' }, function()
      vim.g.alt_image = { protocol = 'sixel' }
      local m = require('alt-image')
      assert.equals(require('alt-image.sixel'), m._provider())
    end)
  end)

  it('protocol="auto" still autodetects', function()
    H.with_env({ TERM_PROGRAM = 'iTerm.app' }, function()
      vim.g.alt_image = { protocol = 'auto' }
      local m = require('alt-image')
      assert.equals(require('alt-image.iterm2'), m._provider())
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
