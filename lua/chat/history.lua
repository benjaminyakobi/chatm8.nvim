-- NOTE: managing canonical provider-agnostic history
local M = {}

local history = {}

---@return table
function M.get()
  return vim.deepcopy(history)
end

---@return nil
function M.clear()
  history = {}
end

---@return table
---@param role string
---@param text string
function M.pack(role, text)
  return {
    role = role,
    text = text,
  }
end

---@return boolean
---@param role string
---@param text string
function M.add(role, text)
  table.insert(history, M.pack(role, text))

  return #history > 3
  -- while #history > 50 do
  --   table.remove(history, 1)
  -- end
end

return M
