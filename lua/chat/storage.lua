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
