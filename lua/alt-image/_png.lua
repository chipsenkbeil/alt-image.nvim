---Pure-Lua PNG decoder for neovim's image API.
---Decodes PNG files to RGBA pixel data without external dependencies.
---Only supports bit depth 8, non-interlaced PNGs.
---@class vim.ui.img._png
local M = {}

local bit = require('bit')
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift

local _zlib_uncompress ---@type fun(data:string, expected:integer):string?
do
  local ok, ffi = pcall(require, 'ffi')
  if ok then
    local zok, zlib = pcall(ffi.load, 'z')
    if zok then
      pcall(ffi.cdef, [[
        int uncompress(uint8_t *dest, unsigned long *destLen,
                       const uint8_t *source, unsigned long sourceLen);
      ]])
      _zlib_uncompress = function(data, expected_size)
        local dest = ffi.new('uint8_t[?]', expected_size)
        local destLen = ffi.new('unsigned long[1]', expected_size)
        local ret = zlib.uncompress(dest, destLen, data, #data)
        if ret ~= 0 then
          return nil
        end
        return ffi.string(dest, destLen[0])
      end
    end
  end
end

---PNG magic number
local PNG_SIGNATURE = '\137PNG\r\n\26\n'

-- DEFLATE fixed Huffman code lengths (RFC 1951 section 3.2.6)
-- Lit/len 0-143: 8 bits, 144-255: 9 bits, 256-279: 7 bits, 280-287: 8 bits
local FIXED_LIT_LENGTHS = {}
for i = 0, 143 do
  FIXED_LIT_LENGTHS[i] = 8
end
for i = 144, 255 do
  FIXED_LIT_LENGTHS[i] = 9
end
for i = 256, 279 do
  FIXED_LIT_LENGTHS[i] = 7
end
for i = 280, 287 do
  FIXED_LIT_LENGTHS[i] = 8
end

local FIXED_DIST_LENGTHS = {}
for i = 0, 31 do
  FIXED_DIST_LENGTHS[i] = 5
end

-- Length extra bits table (codes 257-285)
local LEN_BASE = {
  [257] = 3, [258] = 4, [259] = 5, [260] = 6, [261] = 7, [262] = 8,
  [263] = 9, [264] = 10, [265] = 11, [266] = 13, [267] = 15, [268] = 17,
  [269] = 19, [270] = 23, [271] = 27, [272] = 31, [273] = 35, [274] = 43,
  [275] = 51, [276] = 59, [277] = 67, [278] = 83, [279] = 99, [280] = 115,
  [281] = 131, [282] = 163, [283] = 195, [284] = 227, [285] = 258,
}
local LEN_EXTRA = {
  [257] = 0, [258] = 0, [259] = 0, [260] = 0, [261] = 0, [262] = 0,
  [263] = 0, [264] = 0, [265] = 1, [266] = 1, [267] = 1, [268] = 1,
  [269] = 2, [270] = 2, [271] = 2, [272] = 2, [273] = 3, [274] = 3,
  [275] = 3, [276] = 3, [277] = 4, [278] = 4, [279] = 4, [280] = 4,
  [281] = 5, [282] = 5, [283] = 5, [284] = 5, [285] = 0,
}

-- Distance extra bits table (codes 0-29)
local DIST_BASE = {
  [0] = 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
  257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289,
  16385, 24577,
}
local DIST_EXTRA = {
  [0] = 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8,
  9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
}

-- Code length alphabet order (for dynamic Huffman)
local CL_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

---@class vim.ui.img._png.BitReader
---@field data string
---@field pos integer byte position (1-based)
---@field bitpos integer bit offset within current byte (0-7)
local BitReader = {}
BitReader.__index = BitReader

---@param data string
---@return vim.ui.img._png.BitReader
function BitReader.new(data)
  return setmetatable({ data = data, pos = 1, bitpos = 0 }, BitReader)
end

---Read n bits from the stream (LSB first per DEFLATE spec).
---@param n integer
---@return integer
function BitReader:read(n)
  local val = 0
  local shift = 0
  while n > 0 do
    if self.pos > #self.data then
      error('PNG: unexpected end of DEFLATE stream')
    end
    local byte = string.byte(self.data, self.pos)
    local avail = 8 - self.bitpos
    local take = math.min(avail, n)
    local bits = band(rshift(byte, self.bitpos), lshift(1, take) - 1)
    val = bor(val, lshift(bits, shift))
    shift = shift + take
    n = n - take
    self.bitpos = self.bitpos + take
    if self.bitpos >= 8 then
      self.bitpos = 0
      self.pos = self.pos + 1
    end
  end
  return val
end

---Align to byte boundary.
function BitReader:align()
  if self.bitpos > 0 then
    self.bitpos = 0
    self.pos = self.pos + 1
  end
end

---Build a Huffman decode table from code lengths.
---@param lengths table<integer, integer> symbol -> code length
---@param max_sym integer maximum symbol value
---@return table decode_table
local function build_huffman(lengths, max_sym)
  local max_bits = 0
  for sym = 0, max_sym do
    if lengths[sym] and lengths[sym] > 0 and lengths[sym] > max_bits then
      max_bits = lengths[sym]
    end
  end
  if max_bits == 0 then
    return {}
  end

  -- Count code lengths
  local bl_count = {}
  for i = 0, max_bits do
    bl_count[i] = 0
  end
  for sym = 0, max_sym do
    if lengths[sym] and lengths[sym] > 0 then
      bl_count[lengths[sym]] = bl_count[lengths[sym]] + 1
    end
  end

  -- Compute starting codes
  local next_code = {}
  local code = 0
  for nbits = 1, max_bits do
    code = lshift(code + (bl_count[nbits - 1] or 0), 1)
    next_code[nbits] = code
  end

  -- Assign codes to symbols and build reverse lookup
  -- Table maps (code, length) -> symbol using a flat array indexed by bit-reversed code
  local tbl = { max_bits = max_bits }
  for sym = 0, max_sym do
    local len = lengths[sym]
    if len and len > 0 then
      local c = next_code[len]
      next_code[len] = c + 1
      -- Bit-reverse the code for LSB-first decoding
      local rev = 0
      for _ = 1, len do
        rev = bor(lshift(rev, 1), band(c, 1))
        c = rshift(c, 1)
      end
      -- Store in table: for each possible extension to max_bits
      local step = lshift(1, len)
      while rev < lshift(1, max_bits) do
        tbl[rev] = { sym = sym, len = len }
        rev = rev + step
      end
    end
  end

  return tbl
end

---Decode one symbol using a Huffman table.
---@param reader vim.ui.img._png.BitReader
---@param tbl table
---@return integer symbol
local function huffman_decode(reader, tbl)
  local max_bits = tbl.max_bits
  local code = reader:read(max_bits)
  local entry = tbl[code]
  if not entry then
    error('PNG: invalid Huffman code in DEFLATE stream')
  end
  -- Put back the extra bits we read
  local extra = max_bits - entry.len
  if extra > 0 then
    reader.bitpos = reader.bitpos - extra
    while reader.bitpos < 0 do
      reader.pos = reader.pos - 1
      reader.bitpos = reader.bitpos + 8
    end
  end
  return entry.sym
end

---Inflate (decompress) a raw DEFLATE stream.
---@param data string raw DEFLATE data (no zlib header/checksum)
---@return string decompressed data
local function inflate(data)
  local reader = BitReader.new(data)
  local out = {}
  local out_len = 0

  local fixed_lit_tbl, fixed_dist_tbl

  local bfinal = 0
  while bfinal == 0 do
    bfinal = reader:read(1)
    local btype = reader:read(2)

    if btype == 0 then
      -- Uncompressed block
      reader:align()
      if reader.pos + 3 > #data then
        error('PNG: truncated uncompressed block')
      end
      local len = string.byte(data, reader.pos) + lshift(string.byte(data, reader.pos + 1), 8)
      reader.pos = reader.pos + 4 -- skip len and nlen
      table.insert(out, string.sub(data, reader.pos, reader.pos + len - 1))
      out_len = out_len + len
      reader.pos = reader.pos + len

    elseif btype == 1 or btype == 2 then
      -- Compressed block (fixed or dynamic Huffman)
      local lit_tbl, dist_tbl

      if btype == 1 then
        if not fixed_lit_tbl then
          fixed_lit_tbl = build_huffman(FIXED_LIT_LENGTHS, 287)
          fixed_dist_tbl = build_huffman(FIXED_DIST_LENGTHS, 31)
        end
        lit_tbl = fixed_lit_tbl
        dist_tbl = fixed_dist_tbl
      else
        -- Dynamic Huffman: read code trees
        local hlit = reader:read(5) + 257
        local hdist = reader:read(5) + 1
        local hclen = reader:read(4) + 4

        -- Read code length code lengths
        local cl_lengths = {}
        for i = 0, 18 do
          cl_lengths[i] = 0
        end
        for i = 1, hclen do
          cl_lengths[CL_ORDER[i]] = reader:read(3)
        end
        local cl_tbl = build_huffman(cl_lengths, 18)

        -- Decode literal/length and distance code lengths
        local all_lengths = {}
        local total = hlit + hdist
        local idx = 0
        while idx < total do
          local sym = huffman_decode(reader, cl_tbl)
          if sym < 16 then
            all_lengths[idx] = sym
            idx = idx + 1
          elseif sym == 16 then
            local rep = reader:read(2) + 3
            local prev = all_lengths[idx - 1] or 0
            for _ = 1, rep do
              all_lengths[idx] = prev
              idx = idx + 1
            end
          elseif sym == 17 then
            local rep = reader:read(3) + 3
            for _ = 1, rep do
              all_lengths[idx] = 0
              idx = idx + 1
            end
          elseif sym == 18 then
            local rep = reader:read(7) + 11
            for _ = 1, rep do
              all_lengths[idx] = 0
              idx = idx + 1
            end
          end
        end

        local lit_lengths = {}
        for i = 0, hlit - 1 do
          lit_lengths[i] = all_lengths[i] or 0
        end
        local dist_lengths = {}
        for i = 0, hdist - 1 do
          dist_lengths[i] = all_lengths[hlit + i] or 0
        end

        lit_tbl = build_huffman(lit_lengths, hlit - 1)
        dist_tbl = build_huffman(dist_lengths, hdist - 1)
      end

      -- Decode symbols
      while true do
        local sym = huffman_decode(reader, lit_tbl)

        if sym < 256 then
          -- Literal byte
          table.insert(out, string.char(sym))
          out_len = out_len + 1
        elseif sym == 256 then
          -- End of block
          break
        else
          -- Length/distance pair
          local length = LEN_BASE[sym]
          local extra = LEN_EXTRA[sym]
          if extra > 0 then
            length = length + reader:read(extra)
          end

          local dist_sym = huffman_decode(reader, dist_tbl)
          local dist = DIST_BASE[dist_sym]
          extra = DIST_EXTRA[dist_sym]
          if extra > 0 then
            dist = dist + reader:read(extra)
          end

          -- Copy from back-reference
          -- We need to handle the case where length > dist (overlapping copy)
          local flat = table.concat(out)
          out = { flat }
          out_len = #flat
          local start = out_len - dist + 1
          local buf = {}
          for i = 1, length do
            local src_idx = start + ((i - 1) % dist)
            buf[i] = string.sub(flat, src_idx, src_idx)
          end
          local chunk = table.concat(buf)
          table.insert(out, chunk)
          out_len = out_len + length
        end
      end

    else
      error('PNG: invalid DEFLATE block type: ' .. btype)
    end
  end

  return table.concat(out)
end

---Paeth predictor function (PNG filter type 4).
---@param a integer
---@param b integer
---@param c integer
---@return integer
local function paeth(a, b, c)
  local p = a + b - c
  local pa = math.abs(p - a)
  local pb = math.abs(p - b)
  local pc = math.abs(p - c)
  if pa <= pb and pa <= pc then
    return a
  elseif pb <= pc then
    return b
  else
    return c
  end
end

---Decode a PNG file from raw bytes to RGBA pixel data.
---@param data string raw PNG file bytes
---@return {width:integer, height:integer, pixels:string}
function M.decode(data)
  -- Validate PNG signature
  assert(data:sub(1, 8) == PNG_SIGNATURE, 'PNG: invalid signature')

  -- Parse chunks
  local pos = 9
  local ihdr, plte, trns
  local idat_chunks = {}

  while pos <= #data do
    if pos + 7 > #data then
      break
    end
    local length = lshift(string.byte(data, pos), 24)
      + lshift(string.byte(data, pos + 1), 16)
      + lshift(string.byte(data, pos + 2), 8)
      + string.byte(data, pos + 3)
    local chunk_type = data:sub(pos + 4, pos + 7)
    local chunk_data = data:sub(pos + 8, pos + 7 + length)
    pos = pos + 12 + length -- length(4) + type(4) + data + crc(4)

    if chunk_type == 'IHDR' then
      ihdr = chunk_data
    elseif chunk_type == 'PLTE' then
      plte = chunk_data
    elseif chunk_type == 'tRNS' then
      trns = chunk_data
    elseif chunk_type == 'IDAT' then
      table.insert(idat_chunks, chunk_data)
    elseif chunk_type == 'IEND' then
      break
    end
  end

  assert(ihdr, 'PNG: missing IHDR chunk')
  assert(#idat_chunks > 0, 'PNG: missing IDAT chunk')

  -- Parse IHDR
  local width = lshift(string.byte(ihdr, 1), 24)
    + lshift(string.byte(ihdr, 2), 16)
    + lshift(string.byte(ihdr, 3), 8)
    + string.byte(ihdr, 4)
  local height = lshift(string.byte(ihdr, 5), 24)
    + lshift(string.byte(ihdr, 6), 16)
    + lshift(string.byte(ihdr, 7), 8)
    + string.byte(ihdr, 8)
  local bit_depth = string.byte(ihdr, 9)
  local color_type = string.byte(ihdr, 10)
  local interlace = string.byte(ihdr, 13)

  assert(bit_depth == 8, 'PNG: only bit depth 8 is supported, got ' .. bit_depth)
  assert(interlace == 0, 'PNG: interlaced PNGs are not supported')

  -- Bytes per pixel based on color type
  local bpp_map = { [0] = 1, [2] = 3, [3] = 1, [4] = 2, [6] = 4 }
  local bpp = bpp_map[color_type]
  assert(bpp, 'PNG: unsupported color type: ' .. color_type)

  -- Decompress IDAT data
  local compressed = table.concat(idat_chunks)
  local expected_size = height * (1 + width * bpp)
  local decompressed
  if _zlib_uncompress then
    decompressed = _zlib_uncompress(compressed, expected_size)
  end
  if not decompressed then
    -- Fallback: skip 2-byte zlib header (CMF + FLG) and 4-byte Adler-32 checksum
    local raw_deflate = compressed:sub(3, -5)
    decompressed = inflate(raw_deflate)
  end

  -- Unfilter scanlines
  local stride = width * bpp
  local pixels = {} -- flat array of bytes
  local prev_row = {} -- previous row bytes (for Up, Average, Paeth filters)
  for i = 1, stride do
    prev_row[i] = 0
  end

  local dpos = 1
  for _ = 1, height do
    local filter = string.byte(decompressed, dpos)
    dpos = dpos + 1

    local row = {}
    for i = 1, stride do
      row[i] = string.byte(decompressed, dpos)
      dpos = dpos + 1
    end

    -- Apply filter
    if filter == 1 then
      -- Sub
      for i = bpp + 1, stride do
        row[i] = band(row[i] + row[i - bpp], 0xFF)
      end
    elseif filter == 2 then
      -- Up
      for i = 1, stride do
        row[i] = band(row[i] + prev_row[i], 0xFF)
      end
    elseif filter == 3 then
      -- Average
      for i = 1, stride do
        local left = i > bpp and row[i - bpp] or 0
        row[i] = band(row[i] + math.floor((left + prev_row[i]) / 2), 0xFF)
      end
    elseif filter == 4 then
      -- Paeth
      for i = 1, stride do
        local left = i > bpp and row[i - bpp] or 0
        local up_left = i > bpp and prev_row[i - bpp] or 0
        row[i] = band(row[i] + paeth(left, prev_row[i], up_left), 0xFF)
      end
    end
    -- filter == 0: None (no modification needed)

    -- Store row pixels
    for i = 1, stride do
      table.insert(pixels, row[i])
    end
    prev_row = row
  end

  -- Normalize to RGBA
  local rgba = {}
  local px_idx = 1
  if color_type == 0 then
    -- Grayscale -> RGBA
    for _ = 1, width * height do
      local g = pixels[px_idx]
      px_idx = px_idx + 1
      table.insert(rgba, string.char(g, g, g, 255))
    end
  elseif color_type == 2 then
    -- RGB -> RGBA
    for _ = 1, width * height do
      local r, g, b = pixels[px_idx], pixels[px_idx + 1], pixels[px_idx + 2]
      px_idx = px_idx + 3
      table.insert(rgba, string.char(r, g, b, 255))
    end
  elseif color_type == 3 then
    -- Indexed -> RGBA (lookup PLTE, alpha from tRNS)
    assert(plte, 'PNG: color type 3 requires PLTE chunk')
    for _ = 1, width * height do
      local idx = pixels[px_idx]
      px_idx = px_idx + 1
      local pi = idx * 3 + 1
      local r = string.byte(plte, pi)
      local g = string.byte(plte, pi + 1)
      local b = string.byte(plte, pi + 2)
      local a = 255
      if trns and idx < #trns then
        a = string.byte(trns, idx + 1)
      end
      table.insert(rgba, string.char(r, g, b, a))
    end
  elseif color_type == 4 then
    -- Grayscale+Alpha -> RGBA
    for _ = 1, width * height do
      local g, a = pixels[px_idx], pixels[px_idx + 1]
      px_idx = px_idx + 2
      table.insert(rgba, string.char(g, g, g, a))
    end
  elseif color_type == 6 then
    -- RGBA -> pass through
    for _ = 1, width * height do
      local r, g, b, a = pixels[px_idx], pixels[px_idx + 1], pixels[px_idx + 2], pixels[px_idx + 3]
      px_idx = px_idx + 4
      table.insert(rgba, string.char(r, g, b, a))
    end
  end

  return {
    width = width,
    height = height,
    pixels = table.concat(rgba),
  }
end

return M
