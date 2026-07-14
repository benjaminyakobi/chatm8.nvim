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

----------------------------------
-- Private Helper Functions
----------------------------------

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

---@return nil
---@param index SessionInfo[]
-- NOTE: write index to index.json file
local function write_index(index)
  local json = vim.json.encode(index)

  local MODE_644 = 420 -- 0644 = rw-r--r--
  local fd = assert(uv.fs_open(INDEX_PATH, "w", MODE_644))
  uv.fs_write(fd, json, -1) -- write new index to file
  uv.fs_close(fd) -- close fd after write
end

---@return SessionInfo?, integer?
---@param id integer
---@param index SessionInfo[]
-- NOTE: return entry and its index if exists in the index, otherwise nil
local function find_entry(id, index)
  for i, entry in ipairs(index) do
    if id == entry.id then
      return entry, i
    end
  end
end

----------------------------------
-- Public API
----------------------------------

---@return boolean, string?
---@param session Session
-- NOTE: success: return true, failure: return false, error message
function M.save_session(session)
  ensure_dirs()

  session.updated_at = os.time()

  local filename = string.format("%d.json", session.id)
  local ok, json = pcall(vim.json.encode, session)
  if not ok then -- failed to save session
    return false, "failed to save session, encode error"
  end

  -- NOTE: save session to file
  local MODE_644 = 420 -- 0644 = rw-r--r--
  local fd, err = uv.fs_open(session_path(filename), "w", MODE_644)
  if not fd then
    return false, err
  end
  uv.fs_write(fd, json, -1)
  uv.fs_close(fd)

  -- NOTE: write entry to index.json
  local index = read_index()
  local entry = find_entry(session.id, index)

  if entry then
    entry.updated_at = session.updated_at
  else
    table.insert(index, {
      id = session.id,
      filename = filename,
      title = session.title,
      created_at = session.created_at,
      updated_at = session.updated_at,
    })
  end

  table.sort(index, function(a, b)
    return a.updated_at > b.updated_at
  end)

  write_index(index)

  return true
end

-- ---@return Session?, string?
-- ---@param id integer
-- NOTE: sucess: return session, failure: return nil, error message
-- function M.load_session(id) end

-- ---@return boolean, string?
-- ---@param id integer
-- NOTE: success: return true, failure: return false, error message
-- function M.delete_session(id) end

---@return SessionInfo[]
-- NOTE: return SessionInfo[]
function M.list_sessions()
  return read_index()
end

return M
