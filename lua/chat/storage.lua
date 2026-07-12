-- NOTE: this module should handle saving/loading sessions to/from disk

local uv = vim.uv or vim.loop

local M = {}

local ROOT_DIR = vim.fn.stdpath("data") .. "/chatm8"
local SESSIONS_DIR = ROOT_DIR .. "/sessions"
local INDEX_PATH = SESSIONS_DIR .. "/index.json"

---@class SessionInfo
---@field id integer
---@field title string
---@field filename string
---@field created_at integer
---@field updated_at integer

---@return nil
-- NOTE: ensure sessions directory and index.json exists
local function ensure_dirs()
  vim.fn.mkdir(SESSIONS_DIR, "p") -- make dir if not exists already

  if uv.fs_stat(INDEX_PATH) then -- do nothing if already exists
    return
  end

  local MODE_644 = 420 -- 0644 = rw-r--r--
  -- open INDEX_PATH for writing (truncate/create), erroring if it fails
  local fd = assert(uv.fs_open(INDEX_PATH, "w", MODE_644))
  uv.fs_write(fd, "[]", -1) -- write empty array
  uv.fs_close(fd) -- close fd after write
end

---@return string
---@param filename string
-- NOTE: returns full path of a session
local function session_path(filename)
  return SESSIONS_DIR .. "/" .. filename
end

---@return SessionInfo[]
-- NOTE: returns the content of index.json
local function read_index()
  ensure_dirs()

  local stat = uv.fs_stat(INDEX_PATH)
  if not stat then -- return empty table, index.json not exists
    return {}
  end

  local MODE_666 = 438 -- 0638 = rw-rw-rw-
  local fd = assert(uv.fs_open(INDEX_PATH, "r", MODE_666))
  local json = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)

  ---@type boolean, SessionInfo[]?
  local ok, index = pcall(vim.json.decode, json)
  if not ok then -- return empty table, error reading index.json
    return {}
  end

  ---@cast index SessionInfo[]
  return index
end

-- TODO: implelemt
-- ---@param session Session
-- function M.save_session(session) end
--
-- TODO: implelemt
-- ---@param id integer
-- function M.load_session(id) end
--
-- TODO: implelemt
-- ---@param id integer
-- function M.delete_session(id) end
--
-- TODO: implelemt
-- function M.list_sessions() end

return M
