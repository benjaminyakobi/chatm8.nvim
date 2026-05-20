-- NOTE: managing canonical provider-agnostic history
local M = {}

local history = {}

function M.get()
  return vim.deepcopy(history)
end

function M.clear()
  history = {}
end

function M.add(role, message)
  -- TODO: impelment
end

return M
