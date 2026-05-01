-- Pure-Lua PNG codec used by both providers.
--   * Decoder: handles 8-bit non-interlaced PNGs (color types 0/2/3/4/6).
--     Uses libz `uncompress` via FFI when available; falls back to a pure-Lua
--     DEFLATE inflater (fixed + dynamic Huffman, stored blocks).
--   * Encoder: emits 8-bit RGBA PNG. Uses libz `compress2` via FFI when
--     available for real DEFLATE; otherwise falls back to a stored-block
--     zlib stream (still a valid PNG, just larger wire size).
--
-- API:
--   decode(bytes) -> { width, height, pixels = rgba_string }
--   encode(rgba, width, height) -> png_bytes
--   has_libz() -> boolean (true when the encoder uses real DEFLATE)

local M = {}

local bit = require("bit")
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift

local PNG_SIGNATURE = "\137PNG\r\n\26\n"

-- =============================================================================
-- Decoder
-- =============================================================================

local _zlib_uncompress ---@type fun(data:string, expected:integer):string?
do
    local ok, ffi = pcall(require, "ffi")
    if ok then
        -- Match the encoder's lookup names below — "z" picks up libz on
        -- Linux/macOS, "zlib1"/"zlib"/"libz" cover Windows (zlib1.dll) and
        -- odd packagings. Without this, decode falls all the way back to
        -- the pure-Lua inflater, which dominates first-render latency.
        local zlib
        for _, name in ipairs({ "z", "zlib", "zlib1", "libz" }) do
            local zok, lib = pcall(ffi.load, name)
            if zok then
                zlib = lib
                break
            end
        end
        if zlib then
            pcall(
                ffi.cdef,
                [[
        int uncompress(uint8_t *dest, unsigned long *destLen,
                       const uint8_t *source, unsigned long sourceLen);
      ]]
            )
            _zlib_uncompress = function(data, expected_size)
                local dest = ffi.new("uint8_t[?]", expected_size)
                local destLen = ffi.new("unsigned long[1]", expected_size)
                local ret = zlib.uncompress(dest, destLen, data, #data)
                if ret ~= 0 then
                    return nil
                end
                return ffi.string(dest, destLen[0])
            end
        end
    end
end

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
    [257] = 3,
    [258] = 4,
    [259] = 5,
    [260] = 6,
    [261] = 7,
    [262] = 8,
    [263] = 9,
    [264] = 10,
    [265] = 11,
    [266] = 13,
    [267] = 15,
    [268] = 17,
    [269] = 19,
    [270] = 23,
    [271] = 27,
    [272] = 31,
    [273] = 35,
    [274] = 43,
    [275] = 51,
    [276] = 59,
    [277] = 67,
    [278] = 83,
    [279] = 99,
    [280] = 115,
    [281] = 131,
    [282] = 163,
    [283] = 195,
    [284] = 227,
    [285] = 258,
}
local LEN_EXTRA = {
    [257] = 0,
    [258] = 0,
    [259] = 0,
    [260] = 0,
    [261] = 0,
    [262] = 0,
    [263] = 0,
    [264] = 0,
    [265] = 1,
    [266] = 1,
    [267] = 1,
    [268] = 1,
    [269] = 2,
    [270] = 2,
    [271] = 2,
    [272] = 2,
    [273] = 3,
    [274] = 3,
    [275] = 3,
    [276] = 3,
    [277] = 4,
    [278] = 4,
    [279] = 4,
    [280] = 4,
    [281] = 5,
    [282] = 5,
    [283] = 5,
    [284] = 5,
    [285] = 0,
}

-- Distance extra bits table (codes 0-29)
local DIST_BASE = {
    [0] = 1,
    2,
    3,
    4,
    5,
    7,
    9,
    13,
    17,
    25,
    33,
    49,
    65,
    97,
    129,
    193,
    257,
    385,
    513,
    769,
    1025,
    1537,
    2049,
    3073,
    4097,
    6145,
    8193,
    12289,
    16385,
    24577,
}
local DIST_EXTRA = {
    [0] = 0,
    0,
    0,
    0,
    1,
    1,
    2,
    2,
    3,
    3,
    4,
    4,
    5,
    5,
    6,
    6,
    7,
    7,
    8,
    8,
    9,
    9,
    10,
    10,
    11,
    11,
    12,
    12,
    13,
    13,
}

-- Code length alphabet order (for dynamic Huffman)
local CL_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

local BitReader = {}
BitReader.__index = BitReader

function BitReader.new(data)
    return setmetatable({ data = data, pos = 1, bitpos = 0 }, BitReader)
end

function BitReader:read(n)
    local val = 0
    local shift = 0
    while n > 0 do
        if self.pos > #self.data then
            error("PNG: unexpected end of DEFLATE stream")
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

function BitReader:align()
    if self.bitpos > 0 then
        self.bitpos = 0
        self.pos = self.pos + 1
    end
end

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

    local bl_count = {}
    for i = 0, max_bits do
        bl_count[i] = 0
    end
    for sym = 0, max_sym do
        if lengths[sym] and lengths[sym] > 0 then
            bl_count[lengths[sym]] = bl_count[lengths[sym]] + 1
        end
    end

    local next_code = {}
    local code = 0
    for nbits = 1, max_bits do
        code = lshift(code + (bl_count[nbits - 1] or 0), 1)
        next_code[nbits] = code
    end

    local tbl = { max_bits = max_bits }
    for sym = 0, max_sym do
        local len = lengths[sym]
        if len and len > 0 then
            local c = next_code[len]
            next_code[len] = c + 1
            local rev = 0
            for _ = 1, len do
                rev = bor(lshift(rev, 1), band(c, 1))
                c = rshift(c, 1)
            end
            local step = lshift(1, len)
            while rev < lshift(1, max_bits) do
                tbl[rev] = { sym = sym, len = len }
                rev = rev + step
            end
        end
    end

    return tbl
end

local function huffman_decode(reader, tbl)
    local max_bits = tbl.max_bits
    local code = reader:read(max_bits)
    local entry = tbl[code]
    if not entry then
        error("PNG: invalid Huffman code in DEFLATE stream")
    end
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
            reader:align()
            if reader.pos + 3 > #data then
                error("PNG: truncated uncompressed block")
            end
            local len = string.byte(data, reader.pos) + lshift(string.byte(data, reader.pos + 1), 8)
            reader.pos = reader.pos + 4 -- skip len and nlen
            table.insert(out, string.sub(data, reader.pos, reader.pos + len - 1))
            out_len = out_len + len
            reader.pos = reader.pos + len
        elseif btype == 1 or btype == 2 then
            local lit_tbl, dist_tbl

            if btype == 1 then
                if not fixed_lit_tbl then
                    fixed_lit_tbl = build_huffman(FIXED_LIT_LENGTHS, 287)
                    fixed_dist_tbl = build_huffman(FIXED_DIST_LENGTHS, 31)
                end
                lit_tbl = fixed_lit_tbl
                dist_tbl = fixed_dist_tbl
            else
                local hlit = reader:read(5) + 257
                local hdist = reader:read(5) + 1
                local hclen = reader:read(4) + 4

                local cl_lengths = {}
                for i = 0, 18 do
                    cl_lengths[i] = 0
                end
                for i = 1, hclen do
                    cl_lengths[CL_ORDER[i]] = reader:read(3)
                end
                local cl_tbl = build_huffman(cl_lengths, 18)

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

            while true do
                local sym = huffman_decode(reader, lit_tbl)

                if sym < 256 then
                    table.insert(out, string.char(sym))
                    out_len = out_len + 1
                elseif sym == 256 then
                    break
                else
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
            error("PNG: invalid DEFLATE block type: " .. btype)
        end
    end

    return table.concat(out)
end

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
    assert(data:sub(1, 8) == PNG_SIGNATURE, "PNG: invalid signature")

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
        pos = pos + 12 + length

        if chunk_type == "IHDR" then
            ihdr = chunk_data
        elseif chunk_type == "PLTE" then
            plte = chunk_data
        elseif chunk_type == "tRNS" then
            trns = chunk_data
        elseif chunk_type == "IDAT" then
            table.insert(idat_chunks, chunk_data)
        elseif chunk_type == "IEND" then
            break
        end
    end

    assert(ihdr, "PNG: missing IHDR chunk")
    assert(#idat_chunks > 0, "PNG: missing IDAT chunk")

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

    assert(bit_depth == 8, "PNG: only bit depth 8 is supported, got " .. bit_depth)
    assert(interlace == 0, "PNG: interlaced PNGs are not supported")

    local bpp_map = { [0] = 1, [2] = 3, [3] = 1, [4] = 2, [6] = 4 }
    local bpp = bpp_map[color_type]
    assert(bpp, "PNG: unsupported color type: " .. color_type)

    local compressed = table.concat(idat_chunks)
    local expected_size = height * (1 + width * bpp)
    local decompressed
    if _zlib_uncompress then
        decompressed = _zlib_uncompress(compressed, expected_size)
    end
    if not decompressed then
        local raw_deflate = compressed:sub(3, -5)
        decompressed = inflate(raw_deflate)
    end

    local stride = width * bpp
    local pixels = {}
    local prev_row = {}
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

        if filter == 1 then
            for i = bpp + 1, stride do
                row[i] = band(row[i] + row[i - bpp], 0xFF)
            end
        elseif filter == 2 then
            for i = 1, stride do
                row[i] = band(row[i] + prev_row[i], 0xFF)
            end
        elseif filter == 3 then
            for i = 1, stride do
                local left = i > bpp and row[i - bpp] or 0
                row[i] = band(row[i] + math.floor((left + prev_row[i]) / 2), 0xFF)
            end
        elseif filter == 4 then
            for i = 1, stride do
                local left = i > bpp and row[i - bpp] or 0
                local up_left = i > bpp and prev_row[i - bpp] or 0
                row[i] = band(row[i] + paeth(left, prev_row[i], up_left), 0xFF)
            end
        end

        for i = 1, stride do
            table.insert(pixels, row[i])
        end
        prev_row = row
    end

    local rgba = {}
    local px_idx = 1
    if color_type == 0 then
        for _ = 1, width * height do
            local g = pixels[px_idx]
            px_idx = px_idx + 1
            table.insert(rgba, string.char(g, g, g, 255))
        end
    elseif color_type == 2 then
        for _ = 1, width * height do
            local r, g, b = pixels[px_idx], pixels[px_idx + 1], pixels[px_idx + 2]
            px_idx = px_idx + 3
            table.insert(rgba, string.char(r, g, b, 255))
        end
    elseif color_type == 3 then
        assert(plte, "PNG: color type 3 requires PLTE chunk")
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
        for _ = 1, width * height do
            local g, a = pixels[px_idx], pixels[px_idx + 1]
            px_idx = px_idx + 2
            table.insert(rgba, string.char(g, g, g, a))
        end
    elseif color_type == 6 then
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

-- =============================================================================
-- Encoder
-- =============================================================================

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

local function be32(n)
    local b1 = math.floor(n / 0x1000000) % 0x100
    local b2 = math.floor(n / 0x10000) % 0x100
    local b3 = math.floor(n / 0x100) % 0x100
    local b4 = n % 0x100
    return string.char(b1, b2, b3, b4)
end

local function le16(n)
    return string.char(n % 0x100, math.floor(n / 0x100) % 0x100)
end

local function build_chunk(typ, data)
    local crc = crc32(typ .. data)
    return be32(#data) .. typ .. data .. be32(crc)
end

---Wrap raw bytes as a zlib stored-block stream (used as the libz fallback).
local function zlib_store(raw)
    local parts = { "\120\1" } -- zlib header: 0x78, 0x01
    local n = #raw
    if n == 0 then
        parts[#parts + 1] = "\1" .. le16(0) .. le16(0xFFFF)
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

-- Try to load libz via LuaJIT FFI. On any failure (no FFI, no libz, ABI
-- mismatch, runtime error) we leave libz_compress nil and fall back to the
-- pure-Lua stored-block encoder.
local libz_compress -- function(data, level) -> string|nil

local _libz_ok = pcall(function()
    local ffi = require("ffi")
    ffi.cdef([[
    typedef unsigned long alt_img_uLongf;
    int compress2(uint8_t *dest, alt_img_uLongf *destLen,
                  const uint8_t *source, alt_img_uLongf sourceLen, int level);
  ]])
    -- Try the conventional names across platforms. "z" picks up libz.so /
    -- libz.dylib on Linux/macOS; "zlib1" / "zlib" / "libz" cover native
    -- Windows installs (zlib1.dll) and odd packagings.
    local libz
    for _, name in ipairs({ "z", "zlib", "zlib1", "libz" }) do
        local lok, lib = pcall(ffi.load, name)
        if lok then
            libz = lib
            break
        end
    end
    if not libz then
        error("libz not loadable")
    end

    libz_compress = function(data, level)
        local src_len = #data
        local dst_capacity = src_len + math.ceil(src_len / 1000) + 32
        local dst = ffi.new("uint8_t[?]", dst_capacity)
        local dst_len = ffi.new("alt_img_uLongf[1]", dst_capacity)
        local src = ffi.cast("const uint8_t*", data)
        local rc = libz.compress2(dst, dst_len, src, src_len, level or 6)
        if rc ~= 0 then
            return nil
        end
        return ffi.string(dst, dst_len[0])
    end
end)

if not _libz_ok then
    libz_compress = nil
end

local function zlib_compress(raw)
    if libz_compress then
        local out = libz_compress(raw)
        if out and #out > 0 then
            return out
        end
    end
    return zlib_store(raw)
end

---Whether the FFI libz path is active (real DEFLATE) or we're using the
---stored-block fallback. Useful for healthchecks and tests.
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
    assert(type(rgba) == "string", "png.encode: rgba must be a string")
    assert(
        #rgba == width * height * 4,
        "png.encode: rgba length mismatch (expected " .. (width * height * 4) .. ", got " .. #rgba .. ")"
    )

    local stride = width * 4
    local scanlines = {}
    for y = 0, height - 1 do
        scanlines[#scanlines + 1] = "\0" .. rgba:sub(y * stride + 1, (y + 1) * stride)
    end
    local raw = table.concat(scanlines)
    local idat_payload = zlib_compress(raw)

    local ihdr_data = be32(width) .. be32(height) .. string.char(8, 6, 0, 0, 0) -- depth=8, color=RGBA, defaults
    local ihdr = build_chunk("IHDR", ihdr_data)
    local idat = build_chunk("IDAT", idat_payload)
    local iend = build_chunk("IEND", "")

    return PNG_SIGNATURE .. ihdr .. idat .. iend
end

-- Internal helpers exposed for testing.
M._crc32 = crc32
M._adler32 = adler32

return M
