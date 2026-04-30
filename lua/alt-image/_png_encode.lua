-- alt-image PNG encoder (pure transforms).
-- Emits a valid 8-bit RGBA PNG. When LuaJIT FFI + libz are available we run
-- payloads through zlib's `compress2` for real DEFLATE compression; otherwise
-- we fall back to zlib stored (uncompressed) blocks. The fallback path keeps
-- the encoder usable on hosts without libz, at the cost of larger wire size.
--
-- PNG layout:
--   8-byte signature, then chunks: IHDR, IDAT, IEND.
--   Each chunk: 4-byte BE length, 4-byte type, length-byte data, 4-byte BE CRC32
--   computed over (type + data).
--
-- IDAT contents are a zlib stream (header + DEFLATE blocks + Adler-32) over
-- filtered scanlines. Each scanline is one filter byte (0 = "None") followed
-- by width*4 RGBA bytes.

local M = {}

local bit = require('bit')

local PNG_SIGNATURE = '\137PNG\r\n\26\n'

-- Precomputed CRC32 table (poly 0xEDB88320, the reflected/zlib variant).
local crc32_table = {}
for i = 0, 255 do
  local c = i
  for _ = 1, 8 do
    c = (c % 2 == 1) and bit.bxor(0xEDB88320, bit.rshift(c, 1)) or bit.rshift(c, 1)
  end
  crc32_table[i] = c
end

local function crc32(s)
  local c = 0xFFFFFFFF
  for i = 1, #s do
    local b = string.byte(s, i)
    c = bit.bxor(crc32_table[bit.band(bit.bxor(c, b), 0xFF)], bit.rshift(c, 8))
  end
  return bit.bxor(c, 0xFFFFFFFF)
end

local function adler32(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + string.byte(s, i)) % 65521
    b = (b + a) % 65521
  end
  return b * 65536 + a
end

---Pack a non-negative integer as 4-byte big-endian.
---@param n integer
---@return string
local function be32(n)
  -- Use math.floor + modulo (avoid bit ops on values > 2^31 for safety).
  local b1 = math.floor(n / 0x1000000) % 0x100
  local b2 = math.floor(n / 0x10000) % 0x100
  local b3 = math.floor(n / 0x100) % 0x100
  local b4 = n % 0x100
  return string.char(b1, b2, b3, b4)
end

---Pack a non-negative integer as 2-byte little-endian.
---@param n integer
---@return string
local function le16(n)
  return string.char(n % 0x100, math.floor(n / 0x100) % 0x100)
end

---Build a single PNG chunk: 4-byte BE length + type + data + 4-byte BE CRC32.
---@param typ string 4-byte chunk type
---@param data string chunk data (may be empty)
---@return string chunk_bytes
local function build_chunk(typ, data)
  local crc = crc32(typ .. data)
  return be32(#data) .. typ .. data .. be32(crc)
end

---Wrap raw bytes as zlib stored-block stream.
--- - 2-byte zlib header (0x78 0x01).
--- - One or more stored blocks, each: 1-byte flag (BFINAL on last, BTYPE=00),
---   2-byte LE LEN, 2-byte LE NLEN (= ones-complement of LEN), raw payload.
---   Max LEN per block is 65535; we chunk for defensive correctness on large
---   inputs, even though typical RGBA scanlines fit in one block.
--- - 4-byte BE Adler-32 of the *uncompressed* payload.
---@param raw string uncompressed data
---@return string zlib_bytes
local function zlib_store(raw)
  local parts = { '\120\1' }  -- 0x78, 0x01
  local n = #raw
  if n == 0 then
    -- Empty stream still needs an empty final stored block.
    parts[#parts + 1] = '\1' .. le16(0) .. le16(0xFFFF)
  else
    local pos = 1
    while pos <= n do
      local remaining = n - pos + 1
      local block_len = remaining > 65535 and 65535 or remaining
      local is_final = (pos + block_len - 1 == n)
      parts[#parts + 1] = string.char(is_final and 1 or 0)
      parts[#parts + 1] = le16(block_len)
      parts[#parts + 1] = le16(bit.band(bit.bxor(block_len, 0xFFFF), 0xFFFF))
      parts[#parts + 1] = raw:sub(pos, pos + block_len - 1)
      pos = pos + block_len
    end
  end
  parts[#parts + 1] = be32(adler32(raw))
  return table.concat(parts)
end

-- Try to load libz via LuaJIT FFI. On success, `libz_compress(data, level)`
-- returns a complete zlib stream (header + DEFLATE + Adler-32) suitable for
-- direct use as IDAT contents. On any failure (no FFI, no libz on the loader
-- path, ABI mismatch, runtime error) we leave it nil and fall through to the
-- pure-Lua stored-block encoder.
local libz_compress  -- function(data, level) -> string|nil

local _libz_ok = pcall(function()
  local ffi = require('ffi')
  ffi.cdef[[
    typedef unsigned long alt_image_uLongf;
    int compress2(uint8_t *dest, alt_image_uLongf *destLen,
                  const uint8_t *source, alt_image_uLongf sourceLen, int level);
  ]]
  local libz = ffi.load('z')

  libz_compress = function(data, level)
    local src_len = #data
    -- compress2 docs: dest buffer must be at least sourceLen +
    -- sourceLen/1000 + 12 bytes; we pad an extra 32 for the zlib header / safety.
    local dst_capacity = src_len + math.ceil(src_len / 1000) + 32
    local dst = ffi.new('uint8_t[?]', dst_capacity)
    local dst_len = ffi.new('alt_image_uLongf[1]', dst_capacity)
    local src = ffi.cast('const uint8_t*', data)
    local rc = libz.compress2(dst, dst_len, src, src_len, level or 6)
    if rc ~= 0 then return nil end
    return ffi.string(dst, dst_len[0])
  end
end)

if not _libz_ok then libz_compress = nil end

---Compress raw bytes using libz when available, falling back to a pure-Lua
---stored-block zlib stream. Either way the return value is a valid zlib stream
---ready to drop into a PNG IDAT chunk.
---@param raw string uncompressed data
---@return string zlib_bytes
local function zlib_compress(raw)
  if libz_compress then
    local out = libz_compress(raw)
    if out and #out > 0 then return out end
  end
  return zlib_store(raw)
end

---Whether the FFI libz path is active. Useful for healthchecks and tests
---that want to assert "real" DEFLATE compression vs the fallback.
---@return boolean
function M.has_libz()
  return libz_compress ~= nil
end

---Encode an 8-bit RGBA pixel buffer as a PNG byte string.
---@param rgba string raw RGBA bytes (4 bytes/pixel, row-major), length = width*height*4
---@param width integer
---@param height integer
---@return string png_bytes
function M.encode(rgba, width, height)
  assert(type(rgba) == 'string', 'png_encode.encode: rgba must be a string')
  assert(#rgba == width * height * 4,
         'png_encode.encode: rgba length mismatch (expected '
         .. (width * height * 4) .. ', got ' .. #rgba .. ')')

  -- Build filtered scanlines: filter byte 0 ("None") + raw row bytes.
  local stride = width * 4
  local scanlines = {}
  for y = 0, height - 1 do
    scanlines[#scanlines + 1] = '\0' .. rgba:sub(y * stride + 1, (y + 1) * stride)
  end
  local raw = table.concat(scanlines)
  local idat_payload = zlib_compress(raw)

  local ihdr_data = be32(width) .. be32(height)
                  .. string.char(8, 6, 0, 0, 0)  -- depth=8, color=RGBA, defaults
  local ihdr = build_chunk('IHDR', ihdr_data)
  local idat = build_chunk('IDAT', idat_payload)
  local iend = build_chunk('IEND', '')

  return PNG_SIGNATURE .. ihdr .. idat .. iend
end

-- Internal helpers exposed for testing.
M._crc32 = crc32
M._adler32 = adler32

return M
