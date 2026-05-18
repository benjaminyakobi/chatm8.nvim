-- NOTE: openai provider file NOT TESTED YET!
local M = {}

local providers = require("chat.providers")

---@return nil
---@param prompt string
---@param callback function
function M.answer(prompt, callback)
  local body = {
    model = "gpt-5-mini", -- FIX: should come from the configuration setup

    messages = {
      {
        role = "user",
        content = prompt,
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
    "https://api.openai.com/v1/chat/completions",
    "-H",
    "Content-Type: application/json",
    "-H",
    "Authorization: Bearer " .. providers.api_key,
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
      return data.choices[1].message.content
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
