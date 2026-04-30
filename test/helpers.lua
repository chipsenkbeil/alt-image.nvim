-- test/helpers.lua
local H = {}

-- Replace nvim_ui_send to capture all emitted sequences into _G.data.
function H.setup_capture()
  _G.data = {}
  H._orig_ui_send = H._orig_ui_send or vim.api.nvim_ui_send
  vim.api.nvim_ui_send = function(s)
    _G.data[#_G.data + 1] = s
  end
end

function H.captured()
  return table.concat(_G.data or {})
end

function H.reset_capture()
  _G.data = {}
end

function H.restore_capture()
  if H._orig_ui_send then
    vim.api.nvim_ui_send = H._orig_ui_send
    H._orig_ui_send = nil
  end
  _G.data = nil
end

-- Parse a single OSC 1337 sequence. Returns { args = {k=v}, payload = b64 }.
-- Format: \027]1337;File=k=v;k=v:<payload>\007
function H.parse_iterm2_seq(s)
  local body = s:match('^\027%]1337;File=(.-)\007$')
  if not body then return nil, 'not an OSC 1337 File sequence' end
  local kvs, payload = body:match('^(.-):(.*)$')
  if not kvs then kvs, payload = body, '' end
  local args = {}
  for kv in vim.gsplit(kvs, ';', { plain = true }) do
    local k, v = kv:match('^([^=]+)=(.*)$')
    if k then args[k] = v end
  end
  return { args = args, payload = payload }
end

-- Parse a sixel DCS sequence: \027Pq"pan;pad;w;h<palette+bands>\027\\
function H.parse_sixel_seq(s)
  local body = s:match('\027P(.-)\027\\')
  if not body then return nil, 'not a DCS sequence' end
  -- 'q' marks sixel; the substring after 'q' starts with optional raster attrs.
  local sixel = body:match('^[%d;]*q(.*)$')
  if not sixel then return nil, 'not a sixel DCS' end
  local out = { palette = {}, raster = nil, bands = sixel }
  local pan, pad, w, h, rest = sixel:match('^"(%d+);(%d+);(%d+);(%d+)(.*)$')
  if pan then
    out.raster = { pan = tonumber(pan), pad = tonumber(pad),
                   w = tonumber(w),     h = tonumber(h) }
    sixel = rest
  end
  for idx, r, g, b in sixel:gmatch('#(%d+);2;(%d+);(%d+);(%d+)') do
    out.palette[tonumber(idx)] = { tonumber(r), tonumber(g), tonumber(b) }
  end
  return out
end

-- Reset all alt-image module loads and require the named provider fresh.
-- Use in spec before_each blocks to avoid stale state across tests.
--
-- External tools (img2sixel / magick / convert) are disabled here so existing
-- specs that inspect raw sixel/PNG bytes stay deterministic regardless of
-- which external tools happen to be installed on the test host. The dedicated
-- external-tools spec opts back in explicitly.
function H.fresh_provider(name)
  package.loaded['alt-image']           = nil
  package.loaded['alt-image.iterm2']    = nil
  package.loaded['alt-image.sixel']     = nil
  package.loaded['alt-image._render']   = nil
  package.loaded['alt-image._carrier']  = nil
  package.loaded['alt-image._magick']   = nil
  package.loaded['alt-image._libsixel'] = nil
  vim.g.alt_image = { magick = false, img2sixel = false }   -- pure-Lua paths
  pcall(function() require('alt-image._util')._reset_executable_cache() end)
  return require('alt-image.' .. name)
end

-- Mock the env vars / TERM_PROGRAM for detection tests.
-- Use the value `false` to *unset* an env var for the duration of `fn`.
function H.with_env(vars, fn)
  local saved = {}
  for k, v in pairs(vars) do
    saved[k] = vim.env[k]
    if v == false then vim.env[k] = nil else vim.env[k] = v end
  end
  local ok, err = pcall(fn)
  for k, _ in pairs(vars) do vim.env[k] = saved[k] end
  if not ok then error(err, 2) end
end

return H
