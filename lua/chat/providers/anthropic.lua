-- NOTE: anthropic provider
local M = {}

local providers = require("chat.providers")

---@return table|nil, table|nil
---@param prompt table
local function normalize_prompt(prompt)
  -- NOTE: Anthropic valid roles: USER, ASSISTANT, SYSTEM (top level only!)
  -- Exmaple:
  -- body = {
  --   system = "system prompt....",
  --   messages = {
  --     { role = "user", content = "Write quicksort in Python" },
  --     { role = "assistant", content = "..." },
  --     { role = "user", content = "Now convert to Go" },
  --     }
  -- }
  local system_prompt = nil
  local messages = {}

  -- Preserve order; system messages become a single system string.
  -- If multiple system messages exist, we join them with newlines.
  for _, msg in ipairs(prompt) do
    if msg.role == "Assistant" then
      table.insert(messages, {
        role = "assistant",
        content = msg.content,
      })
    elseif msg.role == "You" then
      table.insert(messages, {
        role = "user",
        content = msg.content,
      })
    elseif msg.role == "System" then
      if system_prompt and system_prompt ~= "" then
        system_prompt = system_prompt .. "\n" .. msg.content
      else
        system_prompt = msg.content
      end
    end
  end

  return system_prompt, messages
end

---@return nil
---@param prompt table
---@param callback function
function M.answer(prompt, callback)
  local system_prompt, messages = normalize_prompt(prompt)
  local body = {
    model = providers.model,
    max_tokens = providers.max_tokens or 1024,
    messages = messages,
  }

  -- NOTE:system prompt should be "top level prompt"
  --      the messages table should contain "user" & assistant message only
  if system_prompt and system_prompt ~= "" then
    body.system = system_prompt
  end

  local ok_encode, json = pcall(vim.json.encode, body)
  if not ok_encode then
    callback({
      error = "JSON encode failed: " .. json,
    })
    return
  end

  vim.system({
    "curl",
    "https://api.anthropic.com/v1/messages",
    "-H",
    "Content-Type: application/json",
    -- Anthropic requires a special header in addition to the API key:
    "-H",
    "x-api-key: " .. providers.api_key,
    -- Required by Anthropic for messages API:
    "-H",
    "anthropic-version: 2023-06-01",
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
      if not data.content then
        callback({
          error = "Missing data.content",
        })
      end

      local parts = {}
      for _, item in ipairs(data.content) do
        if item.type == "text" and item.text then
          table.insert(parts, item.text)
        end
      end

      return table.concat(parts, "")
    end)

    local ok_usage, usage = pcall(function()
      return data.usage
    end)

    if not ok_extract or not ok_usage then
      -- keep your original behavior: try to surface error.message
      callback({
        error = (data and data.error and data.error.message) or "Unknown error",
      })
      return
    end

    -- Claude usage fields are typically:
    -- input_tokens, output_tokens
    local prompt_count = tostring((usage and (usage.input_tokens or usage.prompt_tokens)) or 0)
    local completion_count = tostring((usage and (usage.output_tokens or usage.completion_tokens)) or 0)

    callback({
      content = text,
      usage = "Prompt Tokens: " .. prompt_count .. " | Completion Tokens: " .. completion_count,
    })
  end)
end

return M
