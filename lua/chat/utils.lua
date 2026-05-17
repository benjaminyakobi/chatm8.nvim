local M = {}

---@return nil
---@param msg string
---@param lvl vim.log.levels
function M.safe_notify(msg, lvl)
  vim.schedule(function()
    vim.notify(msg, lvl)
  end)
end

return M
