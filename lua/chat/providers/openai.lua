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
  local system_prompt = nil
  local contents = {}

  for _, msg in ipairs(prompt) do
    if msg.role == "Assistant" then
      table.insert(contents, {
        role = "assistant",
        content = msg.content,
      })
    elseif msg.role == "You" then
      table.insert(contents, {
        role = "user",
        content = msg.content,
      })
    elseif msg.role == "system" then
      if system_prompt and system_prompt ~= "" then
        system_prompt = system_prompt .. "\n" .. msg.content
      else
        system_prompt = msg.content
      end
    end
  end

  -- NOTE: returning single system prompt instead of multiple
  if system_prompt then
    return {
      {
        role = "system",
        content = system_prompt,
      },
      unpack(contents),
    }
  end
  return contents
end

---@return nil
---@param prompt table
---@param callback function
function M.answer(prompt, callback)
  local messages = normalize_prompt(prompt)
  local body = {
    model = providers.model,
    messages = messages,
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
      return data.choices[1].message.content
    end)

    local ok_usage, usage = pcall(function()
      return data.usage
    end)

    if not ok_extract or not ok_usage then
      callback({
        error = data.error.message,
      })
      return
    end

    local prompt_count = tostring((usage and usage.prompt_tokens) or 0)
    local completion_count = tostring((usage and usage.completion_tokens) or 0)

    callback({
      content = text,
      usage = "Prompt Tokens: " .. prompt_count .. " | Completion Tokens: " .. completion_count,
    })
  end)
end

return M
