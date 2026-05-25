-- NOTE: openai provider
local M = {}

local providers = require("chat.providers")

---@return table
---@param prompt table
local function normalize_prompt(prompt)
  -- NOTE: OpenAI valid roles: SYSTEM, DEVELOPER, USER, ASSISTANT
  -- Exmaple:
  --   messages = {
  --     { role = "system", content = "You are a helpful coding assistant" },
  --     { role = "user", content = "Write quicksort in Python" },
  --     { role = "assistant", content = "..." },
  --     { role = "user", content = "Now convert to Go" },
  --     }
  local contents = {}

  for _, msg in ipairs(prompt) do
    local role = msg.role
    if role == "Assistant" then
      role = "assistant"
    elseif role == "You" then
      role = "user"
    elseif role == "System" then
      role = "system"
    end

    table.insert(contents, {
      role = role,
      content = msg.text,
    })
  end

  return contents
end

---@return nil
---@param prompt table
---@param callback function
function M.answer(prompt, callback)
  local body = {
    model = providers.openai_model,
    messages = normalize_prompt(prompt),
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

---@return nil
---@param prompt_history table
---@param callback function
function M.summarize_conversation(prompt_history, callback)
  local body = {
    model = providers.openai_model,
    messages = normalize_prompt(prompt_history),
  }

  local ok_encode, json = pcall(vim.json.encode, body)
  if not ok_encode then
    callback({
      error = "chat.nvim: Failed to summarize history, JSON encode failed: " .. json,
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
        error = "chat.nvim: Failed to summarize history, Request failed: " .. (res.stderr or "unknown error"),
      })
      return
    end

    local ok_decode, data = pcall(vim.json.decode, res.stdout)

    if not ok_decode then
      callback({
        error = "chat.nvim: Failed to summarize history, JSON decode failed",
      })
      return
    end

    local ok_extract, text = pcall(function()
      return data.choices[1].message.content
    end)

    if not ok_extract then
      callback({
        error = "chat.nvim: Failed to summarize history, Invalid response structure",
      })
      return
    end

    callback({
      content = text,
    })
  end)
end

return M
