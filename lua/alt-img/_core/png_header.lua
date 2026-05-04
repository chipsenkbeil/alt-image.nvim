local M = {}

local PNG_SIGNATURE = "\137PNG\r\n\26\n"

---Parse pixel dimensions from a PNG IHDR chunk. Returns nil on invalid input.
---PNG layout: 8-byte signature, 4-byte chunk length, 4-byte chunk type ("IHDR"),
---4-byte BE uint32 width, 4-byte BE uint32 height. Bytes 17..20 are width and
---bytes 21..24 are height (1-indexed).
---@param data string raw image bytes
---@return integer? width_px
---@return integer? height_px
function M.dimensions(data)
    if not data or data:sub(1, #PNG_SIGNATURE) ~= PNG_SIGNATURE then
        return nil, nil
    end
    if #data < 24 then
        return nil, nil
    end
    local function be32(off)
        return string.byte(data, off) * 0x1000000
            + string.byte(data, off + 1) * 0x10000
            + string.byte(data, off + 2) * 0x100
            + string.byte(data, off + 3)
    end
    return be32(17), be32(21)
end

return M
