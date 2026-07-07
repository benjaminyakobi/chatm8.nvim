local M = {}

---@return nil
---@param opts_providers table
---@param provider_name string
function M.setup(opts_providers, provider_name)
  local provider = opts_providers and opts_providers[provider_name]

  if not provider then
    error(
      "chat.nvim: invalid provider `"
        .. tostring(provider_name)
        .. "`.\n\n"
        .. "Example:\n"
        .. "require('chat').setup({\n"
        .. "  provider = 'openai',\n"
        .. "  providers = {\n"
        .. "    openai = {\n"
        .. "      api_key = 'your_api_key',\n"
        .. "      models = {'gpt-5-nano', 'gpt-5-mini', 'gpt-5'},\n"
        .. "    },\n"
        .. "  },\n"
        .. "})"
    )
  end

  M.api_key = provider.api_key

  if not M.api_key then
    error(
      "chat.nvim: missing api_key for provider `"
        .. tostring(provider_name)
        .. "`.\n\n"
        .. "Example:\n"
        .. "require('chat').setup({\n"
        .. "  provider = 'openai',\n"
        .. "  providers = {\n"
        .. "    openai = {\n"
        .. "      api_key = 'your_api_key',\n"
        .. "      models = {'gpt-5-nano', 'gpt-5-mini', 'gpt-5'},\n"
        .. "    },\n"
        .. "  },\n"
        .. "})"
    )
  end

  M.models = provider.models or {}
  if not M.models then
    error(
      "chat.nvim: missing models for openai provider `"
        .. tostring(provider_name)
        .. "`.\n\n"
        .. "Example:\n"
        .. "require('chat').setup({\n"
        .. "  provider = 'openai',\n"
        .. "  providers = {\n"
        .. "    openai = {\n"
        .. "      api_key = 'your_api_key',\n"
        .. "      models = {'gpt-5-nano', 'gpt-5-mini', 'gpt-5'},\n"
        .. "    },\n"
        .. "  },\n"
        .. "})"
    )
  end

  M.max_tokens = provider.max_tokens
  if provider_name == "anthropic" and not M.max_tokens then
    M.max_tokens = 1024
    vim.notify(
      "chat.nvim: missing max_tokens for anthropic provider, using default of 1024"
        .. "`.\n\n"
        .. "Example:\n"
        .. "require('chat').setup({\n"
        .. "  provider = 'anthropic',\n"
        .. "  providers = {\n"
        .. "    anthropic = {\n"
        .. "      api_key = 'your_api_key',\n"
        .. "      max_tokens = 25000,\n"
        .. "      models = {'claude-opus-4-6', 'claude-opus-4-8'},\n"
        .. "    },\n"
        .. "  },\n"
        .. "})",
      vim.log.levels.WARN
    )
  end

  -- NOTE: process the `models` field to create list of available providers
  M.map = {}
  M.list = {}

  for p_name, p_obj in pairs(opts_providers) do
    local provider_models = p_obj.models
    M.map[p_name] = { api_key = p_obj.api_key }
    if not provider_models then
      table.insert(M.map[p_name], p_name)
      table.insert(M.list, p_name)
    else
      for _, model in ipairs(provider_models) do
        table.insert(M.map[p_name], p_name .. " " .. model)
        table.insert(M.list, p_name .. " " .. model)
      end
    end
  end
  table.sort(M.list)

  M.current = M.map[provider_name][1]
  M.name = provider_name
end

---@return nil
---@param name string
function M.set(name)
  M.current = name
  local parts = vim.split(name, " ")
  M.name = parts[1]
  M.api_key = M.map[M.name].api_key
  M.model = parts[2]
end

return M
