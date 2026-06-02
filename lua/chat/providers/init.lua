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
        .. "  provider = 'gemini',\n"
        .. "  providers = {\n"
        .. "    gemini = {\n"
        .. "      api_key = 'your_api_key',\n"
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
        .. "  provider = 'gemini',\n"
        .. "  providers = {\n"
        .. "    gemini = {\n"
        .. "      api_key = 'your_api_key',\n"
        .. "    },\n"
        .. "  },\n"
        .. "})"
    )
  end

  M.models = provider.models or {}
  if provider_name == "openai" and not M.models then
    error(
      "chat.nvim: missing model for openai provider `"
        .. tostring(provider_name)
        .. "`.\n\n"
        .. "Example:\n"
        .. "require('chat').setup({\n"
        .. "  provider = 'openai',\n"
        .. "  providers = {\n"
        .. "    openai = {\n"
        .. "      api_key = 'your_api_key',\n"
        .. "      model = 'gpt-5-mini',\n"
        .. "    },\n"
        .. "  },\n"
        .. "})"
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
end

function M.set(name)
  M.current = name
  local parts = vim.split(name, " ")
  local provider_name = parts[1]
  M.api_key = M.map[provider_name].api_key
  M.model = parts[2]
end

function M.get(name)
  local parts = vim.split(name, " ")

  local provider_name = parts[1]
  M.model = parts[2]
  local ok, provider = pcall(require, "chat.providers." .. provider_name)

  if not ok then
    error("chat.nvim: invalid provider: .. ", name)
  end

  return provider
end

return M
