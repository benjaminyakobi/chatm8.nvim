-- NOTE: gemini provider file
local M = {}

local providers = require("chat.providers")

---@return table
---@param prompt table
local function normalize_prompt(prompt)
  -- NOTE: Gemini valid roles: SYSTEM, DEVELOPER, USER, ASSISTANT
  -- Exmaple:
  --   contents = {
  --     {
  --       role = "system",
  --       parts = {
  --         { text = "You are a helpful coding assistant" },
  --       },
  --     },
  --     {
  --       role = "user",
  --       parts = {
  --         { text = "Write quicksort in Python" },
  --       },
  --     },
  --     { role = "assistant",
  --       parts = {
  --          { text = "..." }
  --       }
  --     },
  --     {
  --       role = "model",
  --       parts = {
  --         { text = "Now convert to Go" },
  --       },
  --     },
  --   }
  local contents = {}

  for _, msg in ipairs(prompt) do
    local role = msg.role
    if role == "Assistant" then
      role = "model"
    elseif role == "You" then
      role = "user"
    elseif role == "System" then
      role = "system"
    end

    table.insert(contents, {
      role = role,
      parts = {
        text = msg.text,
      },
    })
  end

  return contents
end

---@return nil
---@param prompt table
---@param callback function
function M.answer(prompt, callback)
  local body = {
    contents = normalize_prompt(prompt),
  }

  local ok_encode, json = pcall(vim.json.encode, body)
  if not ok_encode then
    callback({
      error = "JSON encode failed: " .. json,
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
        error = "Request failed: " .. (res.stderr or "unknown error"),
      })
      return
    end

    local ok_decode, data = pcall(vim.json.decode, res.stdout)

    if not ok_decode then
      callback({
        error = "JSON decode failed",
      })
      return
    end

    local ok_extract, text = pcall(function()
      return data.candidates[1].content.parts[1].text
    end)

    if not ok_extract then
      callback({
        error = "Invalid response structure",
      })
      return
    end

    callback({
      content = text,
    })
  end)
end

return M
