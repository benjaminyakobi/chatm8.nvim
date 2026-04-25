vim.api.nvim_create_user_command("Greet", function()
  -- Easy Reloading
  package.loaded["chat"] = nil

  require("chat").setup({})
end, {})
