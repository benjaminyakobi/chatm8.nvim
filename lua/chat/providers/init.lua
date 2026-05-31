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

  M.model = provider.model or ""
  if provider_name == "openai" and not M.model then
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
end

function M.get(name)
  local ok, provider = pcall(require, "chat.providers." .. name)

  if not ok then
    error("chat.nvim: invalid provider: .. ", name)
  end

  return provider
end

return M
