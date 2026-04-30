-- test/run.lua: in-repo busted-style harness. Run with:
--   nvim --headless --noplugin -l test/run.lua
local M = { suites = {}, current = nil, before = nil, passed = 0, failed = 0 }

function _G.describe(name, fn)
  local saved = { suite = M.current, before = M.before }
  M.current = { name = name, tests = {} }
  M.before = nil
  fn()
  table.insert(M.suites, M.current)
  M.current = saved.suite
  M.before = saved.before
end

function _G.it(name, fn)
  table.insert(M.current.tests, { name = name, fn = fn, before = M.before })
end

function _G.before_each(fn) M.before = fn end

local function deep_eq(a, b) return vim.deep_equal(a, b) end

-- Add lua/ to runtimepath so spec files can `require('alt-image.*')`.
-- Done before redefining _G.assert because vim.opt internals call assert().
local cwd = vim.uv.cwd()
vim.opt.runtimepath:prepend(cwd)
package.path = cwd .. '/?.lua;' .. cwd .. '/?/init.lua;' .. package.path

local _orig_assert = _G.assert
_G.assert = setmetatable({
  equals = function(expected, actual, msg)
    if expected ~= actual then
      error((msg or '') .. '\n  expected: ' .. vim.inspect(expected)
            .. '\n  actual:   ' .. vim.inspect(actual), 2)
    end
  end,
  same = function(expected, actual, msg)
    if not deep_eq(expected, actual) then
      error((msg or '') .. '\n  expected: ' .. vim.inspect(expected)
            .. '\n  actual:   ' .. vim.inspect(actual), 2)
    end
  end,
  matches = function(pat, s, msg)
    if type(s) ~= 'string' or not s:find(pat) then
      error((msg or '') .. ' pattern ' .. tostring(pat)
            .. ' not in ' .. vim.inspect(s), 2)
    end
  end,
  is_true  = function(v, msg) if v ~= true  then error((msg or '') .. ' want true,  got ' .. vim.inspect(v), 2) end end,
  is_false = function(v, msg) if v ~= false then error((msg or '') .. ' want false, got ' .. vim.inspect(v), 2) end end,
  is_nil   = function(v, msg) if v ~= nil   then error((msg or '') .. ' want nil,   got ' .. vim.inspect(v), 2) end end,
}, {
  __call = function(_, v, msg) return _orig_assert(v, msg) end,
  __index = _orig_assert,
})

-- Discover and load spec files.
local dir = cwd .. '/test'
local fd = vim.uv.fs_scandir(dir)
local specs = {}
while fd do
  local name, t = vim.uv.fs_scandir_next(fd)
  if not name then break end
  if t == 'file' and name:match('_spec%.lua$') then
    table.insert(specs, dir .. '/' .. name)
  end
end
table.sort(specs)
for _, path in ipairs(specs) do dofile(path) end

-- Run suites.
for _, suite in ipairs(M.suites) do
  print('# ' .. suite.name)
  for _, t in ipairs(suite.tests) do
    if t.before then pcall(t.before) end
    local ok, err = pcall(t.fn)
    if ok then
      M.passed = M.passed + 1
      print('  ok   - ' .. t.name)
    else
      M.failed = M.failed + 1
      print('  FAIL - ' .. t.name)
      print('         ' .. tostring(err):gsub('\n', '\n         '))
    end
  end
end

print(string.format('\n%d passed, %d failed', M.passed, M.failed))
os.exit(M.failed == 0 and 0 or 1)
