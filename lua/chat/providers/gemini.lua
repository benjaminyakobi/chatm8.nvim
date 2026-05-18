-- NOTE: gemini provider file
local M = {}

local providers = require("chat.providers")

---@return nil
---@param prompt string
---@param callback function
function M.answer(prompt, callback)
  local body = {
    contents = {
      parts = {
        text = prompt,
      },
    },
  }

  local ok_encode, json = pcall(vim.json.encode, body)
  if not ok_encode then
    callback({
      error = "chat.nvim: JSON encode failed: " .. json,
    })
    return
  end

  vim.system({
    "curl",
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent",
    "-H",
    "Content-Type: application/json",
    "-H",
    "x-goog-api-key: " .. providers.api_key,
    "-X",
    "POST",
    "-d",
    json,
  }, { text = true }, function(res)
    if res.code ~= 0 then
      callback({
        error = "chat.nvim: Request failed: " .. (res.stderr or "unknown error"),
      })
      return
    end

    local ok_decode, data = pcall(vim.json.decode, res.stdout)

    if not ok_decode then
      callback({
        error = "chat.nvim: JSON decode failed",
      })
      return
    end

    local ok_extract, text = pcall(function()
      return data.candidates[1].content.parts[1].text
    end)

    if not ok_extract then
      callback({
        error = "chat.nvim: Invalid response structure",
      })
      return
    end

    callback({
      content = text,
    })
  end)
end

return M
