local M = {}

---@return nil
---@param opts table
function M.setup(opts)
  -- Collecting api_key from the config
  M.api_key = opts.providers[opts.provider].api_key

  if not M.api_key then
    M.safe_notify(
      "chat.nvim: Missing API key. Please set `api_key` in your setup configuration.\nExample:\nrequire('chat').setup({ api_key = 'your_key' })",
      vim.log.levels.ERROR
    )
    M.api_key = ""
  end
end

return M
