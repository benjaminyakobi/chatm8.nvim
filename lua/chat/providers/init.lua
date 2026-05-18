local M = {}

---@return nil
---@param opts table
function M.setup(opts)
  -- Collecting api_key from the config
  local provider = opts.providers and opts.providers[opts.provider]

  if not provider then
    error(
      "chat.nvim: invalid provider `"
        .. tostring(opts.provider)
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
        .. tostring(opts.provider)
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

  M.openai_model = provider.model
  if not provider.model then
    error(
      "chat.nvim: missing model for openai provider `"
        .. tostring(opts.provider)
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

  M.openai_model = provider.model
end

function M.get(name)
  local ok, provider = pcall(require, "chat.providers." .. name)

  if not ok then
    error("chat.nvim: invalid provider: .. ", name)
  end

  return provider
end

return M
