-- alt-image internal utilities
-- Ported from chipsenkbeil/neovim:feat/MoreImgProviders
--   runtime/lua/vim/ui/img/_util.lua
---@class vim.ui.img._util
---@field private _cell_width_px integer
---@field private _cell_height_px integer
---@field private _cell_size_queried boolean
---@field private _on_cell_size_change? fun(w: integer, h: integer)
local M = {
  _cell_width_px = 8,
  _cell_height_px = 16,
  _cell_size_queried = false,
  _on_cell_size_change = nil,
}

---Check if image data is PNG format.
---@param data string
---@return boolean
function M.is_png_data(data)
  ---PNG magic number for format validation
  local PNG_SIGNATURE = '\137PNG\r\n\26\n'

  return data and data:sub(1, #PNG_SIGNATURE) == PNG_SIGNATURE
end

---Parse pixel dimensions from a PNG IHDR chunk. Returns nil on invalid input.
---PNG layout: 8-byte signature, 4-byte chunk length, 4-byte chunk type ("IHDR"),
---4-byte BE uint32 width, 4-byte BE uint32 height. Bytes 17..20 are width and
---bytes 21..24 are height (1-indexed).
---@param data string raw image bytes
---@return integer? width_px
---@return integer? height_px
function M.png_dimensions(data)
  if not M.is_png_data(data) then return nil, nil end
  if #data < 24 then return nil, nil end
  local function be32(off)
    return string.byte(data, off)     * 0x1000000
         + string.byte(data, off + 1) * 0x10000
         + string.byte(data, off + 2) * 0x100
         + string.byte(data, off + 3)
  end
  return be32(17), be32(21)
end

---Check if running in remote environment (SSH).
---@return boolean
function M.is_remote()
  return vim.env.SSH_CLIENT ~= nil or vim.env.SSH_CONNECTION ~= nil
end

---Send data to terminal using nvim_ui_send.
---tmux is NOT supported in this version (see README). Inside tmux, escape
---sequences will reach tmux unwrapped and likely be garbled or eaten.
---@param data string
function M.term_send(data)
  vim.api.nvim_ui_send(data)
end

---Load image data from file synchronously
---@return string data
function M.load_image_data(file)
  local fd, stat_err = vim.uv.fs_open(file, 'r', 0)
  if not fd then
    error('failed to open file: ' .. (stat_err or 'unknown error'))
  end

  local stat = vim.uv.fs_fstat(fd)
  if not stat then
    vim.uv.fs_close(fd)
    error('failed to get file stats')
  end

  local data = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)

  if not data then
    error('failed to read file data')
  end

  return data
end

---Return the cached cell pixel dimensions.
---@return integer width, integer height
function M.cell_pixel_size()
  return M._cell_width_px, M._cell_height_px
end

---Query cell pixel dimensions synchronously via TIOCGWINSZ ioctl.
---Updates cached values immediately. Falls back to 8x16 defaults on failure.
---@private
M._query_cell_size_ioctl = (function()
  local ffi = require('ffi')

  pcall(
    ffi.cdef,
    [[
    struct nvim_img_winsize {
      unsigned short ws_row;
      unsigned short ws_col;
      unsigned short ws_xpixel;
      unsigned short ws_ypixel;
    };
    int open(const char *path, int flags);
    int close(int fd);
    int ioctl(int fd, unsigned long request, ...);
  ]]
  )

  -- TIOCGWINSZ: Linux uses 0x5413, BSD-derived systems (macOS, FreeBSD, etc.) use 0x40087468
  local TIOCGWINSZ = (vim.uv.os_uname().sysname == 'Linux') and 0x5413 or 0x40087468
  local STDERR_FILENO = 2

  return function()
    -- Use stderr (fd 2) directly rather than opening /dev/tty, because
    -- Neovim's server process may not have a controlling terminal (setsid)
    -- but stderr is still connected to the terminal pty.
    ---@type {ws_xpixel:integer, ws_ypixel:integer, ws_col:integer, ws_row:integer}
    local ws = ffi.new('struct nvim_img_winsize')
    local rc = ffi.C.ioctl(STDERR_FILENO, TIOCGWINSZ, ws) ---@type integer

    if rc < 0 then
      return
    end

    if ws.ws_xpixel == 0 or ws.ws_ypixel == 0 or ws.ws_col == 0 or ws.ws_row == 0 then
      return
    end

    local new_w = math.floor(ws.ws_xpixel / ws.ws_col)
    local new_h = math.floor(ws.ws_ypixel / ws.ws_row)

    if new_w <= 0 or new_h <= 0 then
      return
    end

    local changed = new_w ~= M._cell_width_px or new_h ~= M._cell_height_px
    M._cell_width_px = new_w
    M._cell_height_px = new_h

    if changed and M._on_cell_size_change then
      M._on_cell_size_change(new_w, new_h)
    end
  end
end)()

---Query the terminal for cell pixel dimensions (synchronous via ioctl).
---Values are available immediately after this call.
function M.query_cell_size()
  if M._cell_size_queried then
    return
  end
  M._cell_size_queried = true

  M._query_cell_size_ioctl()

  -- Re-query on terminal resize (cell size may change with font/window changes).
  -- Registered once since query_cell_size() guards with _cell_size_queried.
  vim.api.nvim_create_autocmd('VimResized', {
    callback = function()
      M._query_cell_size_ioctl()
    end,
  })
end

M.generate_id = (function()
  local bit = require('bit')
  local NVIM_PID_BITS = 10

  local nvim_pid = 0
  local cnt = 30

  ---Generate unique ID for this Neovim instance
  ---@return integer id
  return function()
    -- Generate a unique ID for this nvim instance (10 bits)
    if nvim_pid == 0 then
      local pid = vim.fn.getpid()
      nvim_pid = bit.band(bit.bxor(pid, bit.rshift(pid, 5), bit.rshift(pid, NVIM_PID_BITS)), 0x3FF)
    end

    cnt = cnt + 1
    return bit.bor(bit.lshift(nvim_pid, 24 - NVIM_PID_BITS), cnt)
  end
end)()

return M
