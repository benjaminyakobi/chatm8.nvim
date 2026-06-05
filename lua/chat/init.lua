local M = {
  parent_win = vim.api.nvim_get_current_win(),
  prompt_thinking = false,
  chat_ns = vim.api.nvim_create_namespace("llm-chat"),
}

---@return nil
---@param opts table
function M.setup(opts)
  M.main_buf = vim.api.nvim_get_current_buf()

  local chat_setup_group = vim.api.nvim_create_augroup("llm_chat_setup", { clear = true })
  opts = opts or {}

  -- Importing modules
  M.treesitter = require("chat.treesitter")
  M.utils = require("chat.utils")
  M.history = require("chat.history")
  M.providers = require("chat.providers")

  -- setting up a provider
  M.providers.setup(opts.providers, opts.provider)

  M.open_prompt_window()

  local help = [[
<Leader>8i: Inline Implementation
  1. [Visual Mode] Select text (either code snippets or natural language instructions).
  2. Press <Leader>8i to automatically complete the implementation or transform 
     the selection directly in the current buffer.

<Leader>8c: Persistent Chat
  1. [Normal/Visual Mode] Press `<Leader>8c` to toggle a persistent chat window 
     in a split view.
  2. [Chat Window] Maintain a continuous, multi-turn conversation with the model 
     that persists across different files and buffers.
    2.1. [Layout] Two windows will open:
         - Upper window: conversation history (read-only).
         - Lower window: prompt input.
    2.2. [Navigation] Press <C-s> in Normal or Visual mode to switch between the
         history window and the prompt window.]]

  -- setting global autocmds
  vim.api.nvim_create_autocmd("WinClosed", {
    group = chat_setup_group,
    callback = function(args)
      local closed_win = tonumber(args.match)

      -- main window closed
      if closed_win ~= M.parent_win then
        return
      end

      vim.cmd("qa")
    end,
  })

  -- setting global keymaps
  vim.keymap.set("n", "<Leader>8?", function()
    if opts.dev then
      print("chat.nvim: local setup\n" .. help)
    else
      print("chat.nvim: remote setup\n" .. help)
    end
  end, { desc = "Help" })

  vim.keymap.set("v", "<Leader>8i", function()
    M.complete_implementation()
  end, { desc = "Complete implementation: Replace selection" })

  vim.keymap.set("v", "<leader>8p", function()
    -- TODO: implement single prompt floating window / vim.ui.input (VISUAL SELECTION ONLY)
    M.open_single_prompt_window()
  end, {
    desc = "Custom prompt: Replace selection",
  })

  vim.keymap.set("n", "<Leader>8c", function()
    M.toggle_persistent_chat_window()
  end, { desc = "Toggle persistent chat window" })

  vim.keymap.set("n", "<leader>8s", function()
    M.select_provider()
  end, {
    desc = "Select chat provider",
  })

  -- setting global hightlights
  vim.api.nvim_set_hl(0, "ChatUI", { fg = "#ffd57a", bold = true })
  vim.api.nvim_set_hl(0, "You", { fg = "#89b4fa", bold = true })
  vim.api.nvim_set_hl(0, "Assistant", { fg = "#a6e3a1", bold = true })
  vim.api.nvim_set_hl(0, "Error", { fg = "#d43131", bold = true })

  vim.api.nvim_set_hl(0, "PromptTitleActive", { fg = "#00ffcc", bold = true })
  vim.api.nvim_set_hl(0, "PromptTitleInactive", { fg = "#00ffcc" })

  vim.api.nvim_set_hl(0, "ChatBorderActive", { fg = "#ffd57a" }) -- bright
  vim.api.nvim_set_hl(0, "ChatBorderInactive", { fg = "#3b4261" }) -- dim

  vim.api.nvim_set_hl(0, "PromptBorderActive", { fg = "#ffd57a" })
  vim.api.nvim_set_hl(0, "PromptBorderInactive", { fg = "#3b4261" })
end

-- ---------------------------------------------
-- ------------- core buffer logic -------------
-- ---------------------------------------------

function M.select_provider()
  vim.ui.select(M.providers.list, { prompt = "Select chat provider:" }, function(choice)
    if choice then
      local lock_buf = M.unlock_buf(M.prompt_history_buf)
      M.set_provider(choice)
      lock_buf()
    end
  end)
end

---@return nil
---@param provider_name string
function M.set_provider(provider_name)
  M.providers.set(provider_name)
  local ok, provider = pcall(require, "chat.providers." .. M.providers.name)
  if not ok then
    M.utils.safe_notify("No provider found for: " .. tostring(M.providers.name), vim.log.levels.ERROR)
    return
  end
  M.provider_module = provider
  local session_provider = "Provider: " .. M.providers.current
  vim.api.nvim_buf_set_lines(M.prompt_history_buf, 2, 4, false, { session_provider, "" })
  vim.api.nvim_buf_set_extmark(M.prompt_history_buf, M.chat_ns, 2, 0, {
    hl_group = "ChatUI",
    end_col = #session_provider,
  })
  M.utils.safe_notify("chat.nvim: current provider: " .. M.providers.current, vim.log.levels.INFO)
end

---@return function
---@param buf integer
-- NOTE: RAII (Resource acquisition is initialization) pattern
function M.unlock_buf(buf)
  local prev = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true

  -- destructor
  return function()
    if prev == true then
      return
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modifiable = prev
    end
  end
end

---@return nil
function M.toggle_persistent_chat_window()
  -- if already open -> close
  if M.chat_win then
    vim.api.nvim_win_close(M.chat_win, true)
    M.chat_win = nil
    return
  end

  -- open new split
  vim.cmd("vsplit") -- or "split" for horizontal split window
  M.chat_win = vim.api.nvim_get_current_win()
  M.open_prompt_window()
end

---@return nil
---@param win integer
---@param border_hl string
---@param title_hl string
function M.set_border(win, border_hl, title_hl)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end

  vim.api.nvim_set_option_value("winhl", "FloatTitle:" .. title_hl .. ",FloatBorder:" .. border_hl, { win = win })
end

---@return nil
---@param optional_prompt_win_height integer|nil
-- TODO: ORGANIZE THIS MESSY FUNCTION
function M.set_prompt_window_conf(optional_prompt_win_height)
  -- if these two buffer not exist - do not configure windows
  if M.prompt_buf == nil or M.prompt_history_buf == nil then
    return
  end

  -- default prompt window height
  if optional_prompt_win_height == nil then
    optional_prompt_win_height = 1
  end

  -- parent size
  if not M.chat_win then
    return
  end
  local parent_width = vim.api.nvim_win_get_width(M.chat_win)
  local parent_height = vim.api.nvim_win_get_height(M.chat_win)

  -- your desired size
  local width = math.min(90, parent_width - 2)
  local height = math.min(60, parent_height)
  local input_height = math.min(15, optional_prompt_win_height)
  local chat_height = height - input_height - 4

  -- center position
  local col = math.floor((parent_width - width) / 2)
  local row = math.floor((parent_height - height) / 2)

  local history_win_conf = {
    relative = "win",
    win = M.chat_win,
    row = row,
    col = col,
    width = width,
    height = chat_height,
    style = "minimal",
    border = "rounded",
    title = " History ",
    title_pos = "center",
  }

  local prompt_win_conf = {
    relative = "win",
    win = M.chat_win,
    row = row + chat_height + 2,
    col = col,
    width = width,
    height = input_height,
    style = "minimal",
    border = "rounded",
    title = " Enter Prompt ",
    title_pos = "center",
  }

  if M.prompt_win and M.prompt_history_win and M.chat_win then -- set new sizes if windows already exist
    vim.api.nvim_win_set_config(M.prompt_win, prompt_win_conf)
    vim.api.nvim_win_set_config(M.prompt_history_win, history_win_conf)
    return -- should not continue if the windows already exist
  else -- open new windows and continue configuring them
    M.prompt_history_win = vim.api.nvim_open_win(M.prompt_history_buf, true, history_win_conf)
    M.prompt_win = vim.api.nvim_open_win(M.prompt_buf, true, prompt_win_conf)

    -- set custom options
    vim.api.nvim_set_option_value("number", true, { win = M.prompt_win })
    vim.api.nvim_set_option_value("number", true, { win = M.prompt_history_win })
    M.set_border(M.prompt_win, "PromptBorderActive", "PromptTitleActive")

    -- set cursor at the last line & start insert mode
    local last = vim.api.nvim_buf_line_count(M.prompt_buf)
    vim.api.nvim_win_set_cursor(M.prompt_win, { last, 0 })
    -- vim.cmd("startinsert")

    -- custom key maps - disabling key maps
    for _, buf in ipairs({ M.prompt_buf, M.prompt_history_buf }) do
      vim.keymap.set("v", "<Leader>8i", function()
        M.utils.safe_notify("Disabled on prompt window", vim.log.levels.INFO)
      end, { desc = "Complete implementation (Disabled)", buf = buf })
    end

    -- custom key maps - switcing between prompt & history windows keymaps
    vim.keymap.set({ "n", "v" }, "<C-s>", function()
      vim.api.nvim_set_current_win(M.prompt_history_win)
    end, { buf = M.prompt_buf })

    vim.keymap.set({ "n", "v" }, "<C-s>", function()
      vim.api.nvim_set_current_win(M.prompt_win)
    end, { buf = M.prompt_history_buf })

    local prompt_session_group = vim.api.nvim_create_augroup("llm_prompt_session", { clear = true })
    local chat_session_group = vim.api.nvim_create_augroup("llm_chat_session", { clear = true })

    -- set auto commands
    for _, buf in ipairs({ M.prompt_buf, M.prompt_history_buf }) do
      vim.api.nvim_create_autocmd("WinEnter", {
        group = prompt_session_group,
        buffer = buf,
        callback = function()
          local win = vim.api.nvim_get_current_win()
          if win == M.prompt_history_win then
            M.set_border(M.prompt_history_win, "ChatBorderActive", "PromptTitleActive")
          elseif win == M.prompt_win then
            M.set_border(M.prompt_win, "PromptBorderActive", "PromptTitleActive")
          end
        end,
      })

      vim.api.nvim_create_autocmd("WinLeave", {
        group = prompt_session_group,
        buffer = buf,
        callback = function()
          local win = vim.api.nvim_get_current_win()
          if win == M.prompt_history_win then
            M.set_border(M.prompt_history_win, "ChatBorderInactive", "PromptTitleInactive")
          elseif win == M.prompt_win then
            M.set_border(M.prompt_win, "PromptBorderInactive", "PromptTitleInactive")
          end
        end,
      })
    end

    vim.api.nvim_create_autocmd("WinClosed", {
      group = chat_session_group,
      callback = function(args)
        if
          M.chat_win == tonumber(args.match)
          or M.prompt_win == tonumber(args.match)
          or M.prompt_history_win == tonumber(args.match)
        then
          vim.api.nvim_win_close(M.prompt_win, true)
          M.prompt_win = nil
          vim.api.nvim_win_close(M.prompt_history_win, true)
          M.prompt_history_win = nil
          vim.api.nvim_win_close(M.chat_win, true)
          M.chat_win = nil
        end
      end,
    })

    vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
      group = chat_session_group,
      callback = function(args)
        if M.parent_win == tonumber(args.match) or M.chat_win == tonumber(args.match) then
          local text_height
          if M.prompt_win and vim.api.nvim_win_is_valid(M.prompt_win) then
            text_height = vim.api.nvim_win_text_height(M.prompt_win, {}).all
          end
          M.set_prompt_window_conf(text_height)
        end
      end,
    })

    -- detecting text changes to resize prompt window when needed
    local timer
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = prompt_session_group,
      buffer = M.prompt_buf,
      callback = function()
        -- cancel previous timer on every keystroke
        if timer and not timer:is_closing() then
          timer:stop()
          timer:close()
          timer = nil
        end

        -- defered resize call
        timer = vim.defer_fn(function()
          local text_height = vim.api.nvim_win_text_height(M.prompt_win, {}).all
          M.set_prompt_window_conf(math.min(15, text_height))
        end, 50)
      end,
    })
  end
end

---@return boolean
---@param table string[]
function M.is_empty(table)
  if #table == 0 then
    return true
  end
  for i = 1, #table do
    if not table[i]:match("^%s*$") then
      return false
    end
  end
  return true
end

function M.scroll_to_bottom(win, buf)
  local line = vim.api.nvim_buf_line_count(buf)
  local last = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
  vim.api.nvim_win_set_cursor(win, { line, #last })
end

---@return nil
-- TODO: ORGANIZE THIS MESSY FUNCTION
function M.open_single_prompt_window()
  print(M.count)
  local prompt_win_height = 1

  -- parent size
  -- local parent_id = vim.api.nvim_get_current_win()
  local parent_width = vim.api.nvim_win_get_width(M.parent_win)
  local parent_height = vim.api.nvim_win_get_height(M.parent_win)

  -- your desired size
  local width = math.min(60, parent_width)
  local height = math.min(60, parent_height)
  local input_height = math.min(15, prompt_win_height)

  -- center position
  local col = math.floor((parent_width - width) / 2)
  local row = math.floor((height - 15) / 2)

  local single_prompt_win_conf = {
    relative = "win",
    win = M.parent_win,
    row = row,
    col = col,
    width = width,
    height = input_height,
    style = "minimal",
    border = "rounded",
    title = " Custom Prompt (Overrides visual selection) ",
    title_pos = "center",
  }
  if not M.single_prompt_buf or not M.single_prompt_win then
    M.count = 0
    M.single_prompt_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[M.single_prompt_buf].buftype = "prompt"
    vim.bo[M.single_prompt_buf].filetype = "markdown"
    vim.bo[M.single_prompt_buf].swapfile = false
    vim.fn.prompt_setprompt(M.single_prompt_buf, "")

    -- TODO:1. center floating window
    --      2. resize based on the parent width
    --      3. call llm with custom prompt + base prompt to "return ready to paste code"

    -- callback when user presses Enter
    vim.fn.prompt_setcallback(M.single_prompt_buf, function()
      local prompt_lines = vim.api.nvim_buf_get_lines(M.single_prompt_buf, 0, -1, false)
      if M.is_empty(prompt_lines) then
        M.utils.safe_notify("Write prompt first", vim.log.levels.WARN)
        vim.api.nvim_buf_set_lines(M.single_prompt_buf, 0, -1, false, {})
        return
      end
      if M.prompt_thinking then
        M.utils.safe_notify("Wait for the previous prompt to finish", vim.log.levels.WARN)
        -- local line_count = vim.api.nvim_buf_line_count(M.prompt_buf)
        -- vim.api.nvim_buf_set_lines(M.prompt_buf, line_count - 1, line_count, false, {})
        -- M.scroll_to_bottom(M.prompt_win, M.prompt_buf)
        return
      end
      local prompt_text = table.concat(prompt_lines, "\n")
      print(prompt_text)
      vim.api.nvim_win_close(M.single_prompt_win, true)
      M.single_prompt_win = nil
      M.single_prompt_buf = nil
      -- M.append_message(M.prompt_history_buf, "You", prompt_text)
      -- M.send_prompt()
      -- vim.api.nvim_buf_set_lines(M.prompt_buf, 0, -1, false, {})
    end)
    M.single_prompt_win = vim.api.nvim_open_win(M.single_prompt_buf, true, single_prompt_win_conf)
    print(M.single_prompt_win)
    M.set_border(M.single_prompt_win, "PromptBorderActive", "PromptTitleActive")

    -- custom key maps - disabling key maps
    vim.keymap.set("v", "<Leader>8i", function()
      M.utils.safe_notify("Disabled on prompt window", vim.log.levels.INFO)
    end, { desc = "Complete implementation (Disabled)", buf = M.single_prompt_buf })

    vim.keymap.set("n", "<Leader>8c", function()
      M.utils.safe_notify("Disabled on prompt window", vim.log.levels.INFO)
    end, { desc = "Toggle persistent chat window (Disabled)", buf = M.single_prompt_buf })

    -- TODO: implement autocmds for the floating window using the below group
    -- WinLeave, WinClosed, WinEnter, TextChanged, TextChangedI
    local single_prompt_session_group = vim.api.nvim_create_augroup("llm_single_prompt_session", { clear = true })

    vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
      group = single_prompt_session_group,
      callback = function(args)
        if M.parent_win == tonumber(args.match) and M.single_prompt_win ~= nil then
          M.open_single_prompt_window()
        end
      end,
    })

    vim.api.nvim_create_autocmd("WinLeave", {
      group = single_prompt_session_group,
      buffer = M.single_prompt_buf,
      callback = function()
        local win = vim.api.nvim_get_current_win()
        if win == M.single_prompt_win then
          M.set_border(M.single_prompt_win, "ChatBorderInactive", "PromptTitleInactive")
        end
      end,
    })

    vim.api.nvim_create_autocmd("WinClosed", {
      group = single_prompt_session_group,
      callback = function(args)
        if M.chat_win == tonumber(args.match) or M.single_prompt_win == tonumber(args.match) then
          vim.api.nvim_win_close(M.single_prompt_win, true)
          M.single_prompt_win = nil
        end
      end,
    })

    return
  end
  M.count = M.count + 1
  vim.api.nvim_win_set_config(M.single_prompt_win, single_prompt_win_conf)
end

---@return nil
function M.open_prompt_window()
  if M.prompt_buf and M.prompt_history_buf then
    M.set_prompt_window_conf()
    return
  end

  -- Create new prompt buffer
  M.prompt_history_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.prompt_history_buf].filetype = "markdown"
  vim.bo[M.prompt_history_buf].swapfile = false
  local session_title = "Ephermal prompt session"
  vim.api.nvim_buf_set_lines(M.prompt_history_buf, 0, 0, false, { session_title })
  vim.api.nvim_buf_set_extmark(M.prompt_history_buf, M.chat_ns, 0, 0, {
    hl_group = "ChatUI",
    end_col = #session_title,
  })

  M.set_provider(M.providers.current)

  vim.bo[M.prompt_history_buf].modifiable = false

  M.prompt_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.prompt_buf].buftype = "prompt"
  vim.bo[M.prompt_buf].filetype = "markdown"
  vim.bo[M.prompt_buf].swapfile = false
  vim.fn.prompt_setprompt(M.prompt_buf, "")

  M.set_prompt_window_conf()

  -- callback when user presses Enter
  vim.fn.prompt_setcallback(M.prompt_buf, function()
    local prompt_lines = vim.api.nvim_buf_get_lines(M.prompt_buf, 0, -1, false)
    if M.is_empty(prompt_lines) then
      M.utils.safe_notify("Write prompt first", vim.log.levels.WARN)
      vim.api.nvim_buf_set_lines(M.prompt_buf, 0, -1, false, {})
      return
    end
    if M.prompt_thinking then
      M.utils.safe_notify("Wait for the previous prompt to finish", vim.log.levels.WARN)
      local line_count = vim.api.nvim_buf_line_count(M.prompt_buf)
      vim.api.nvim_buf_set_lines(M.prompt_buf, line_count - 1, line_count, false, {})
      M.scroll_to_bottom(M.prompt_win, M.prompt_buf)
      return
    end
    local prompt_text = table.concat(prompt_lines, "\n")
    M.append_message(M.prompt_history_buf, "You", prompt_text)
    M.send_prompt()
    vim.api.nvim_buf_set_lines(M.prompt_buf, 0, -1, false, {})
  end)
end

---@return nil
---@param prompt table
---@param buf integer
---@param s_line integer
---@param e_line integer
---@param prompt_win boolean
function M.call_api(prompt, buf, s_line, e_line, prompt_win)
  local lock_buf = M.unlock_buf(buf)
  local stop_spinner = M.start_spinner(buf, s_line)
  M.provider_module.answer(prompt, function(result)
    vim.schedule(function()
      if result.error then
        stop_spinner(false)
        lock_buf()

        if prompt_win then
          M.append_message(buf, "Error", result.error)
        else
          M.utils.safe_notify(result.error, vim.log.levels.ERROR)
        end

        return
      end

      stop_spinner(true)
      lock_buf()

      if prompt_win then
        M.append_message(buf, "Assistant", result.content, result.usage)
      else
        vim.api.nvim_buf_set_lines(buf, s_line, e_line, false, vim.split(result.content, "\n"))
        M.utils.safe_notify("chat.nvim: " .. result.usage, vim.log.levels.INFO)
      end
    end)
  end)
end

---@return nil
---@param buf integer
---@param role string
---@param text string
function M.append_message(buf, role, text, usage)
  ---@return string
  local function build_header()
    local timestamp = os.date("%d-%m-%Y %H:%M:%S")
    local header = "❯ " .. role .. " | " .. timestamp
    return header
  end

  local should_summarize = false
  if role == "You" or role == "Assistant" then
    -- NOTE: if should_summarize == true - the summarize call is after call
    -- is after the prompt history window update (bottom of this func)!
    should_summarize = M.history.add(role, text)
  end

  local lock_buf = M.unlock_buf(buf)
  local lines = vim.split(text, "\n", { plain = true })
  local header = build_header()
  local header_line = vim.api.nvim_buf_line_count(buf)
  local total_lines = { header }
  if usage then
    total_lines = { header, usage }
  end

  for _, v in ipairs(lines) do
    table.insert(total_lines, v)
  end

  for i = #total_lines, 1, -1 do
    if total_lines[i] == "" then
      table.remove(total_lines, i)
    else
      break
    end
  end
  total_lines[#total_lines + 1] = ""

  vim.api.nvim_buf_set_lines(buf, -1, -1, false, total_lines)
  vim.api.nvim_buf_set_extmark(buf, M.chat_ns, header_line, 0, {
    hl_group = role,
    end_col = #header,
  })
  if usage then
    vim.api.nvim_buf_set_extmark(buf, M.chat_ns, header_line + 1, 0, {
      hl_group = role,
      end_col = #usage,
    })
  end

  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then
    vim.api.nvim_win_set_cursor(win, {
      header_line + 1,
      0,
    })
  end
  lock_buf()

  if should_summarize == true and role == "Assistant" then
    -- NOTE: summarizing the conversation when hitting history limit
    local history_prompt = M.history.pack(
      "System",
      [[
Summarize this conversation for future context.

Keep only information that will help continue the conversation:
- the user’s current goal or task
- relevant code context (files, functions, architecture, APIs)
- important technical decisions already made
- constraints or requirements
- unresolved bugs or open questions
- assumptions established during the conversation

Do not include:
- greetings
- repeated explanations
- irrelevant details
- conversational filler

Be concise and precise.

Write the summary as clear bullet points that another engineer can immediately continue from.
        ]]
    )
    local old_history = M.history.get()
    table.insert(old_history, history_prompt)
    M.provider_module.answer(old_history, function(result)
      vim.schedule(function()
        if result.error then
          M.utils.safe_notify("chat.nvim: Failed to summarize history, " .. result.error, vim.log.levels.ERROR)
        else
          M.history.clear()
          M.history.add("System", result.content)
        end
      end)
    end)
  end
end

---@return nil
---@param buf integer
---@param text string|nil
function M.append_prompt_message(buf, text)
  local lines = {}
  if text then
    lines = vim.split(text, "\n", { plain = true })
    lines[#lines + 1] = ""
  else
    M.set_prompt_window_conf()
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then
    vim.api.nvim_win_set_cursor(win, {
      vim.api.nvim_buf_line_count(buf),
      0,
    })
  end
end

---@return string
---@param text string
function M.tag_selected_text(text)
  return "```" .. vim.bo.filetype .. "\n" .. text .. "\n```"
end

---@return nil
function M.complete_implementation()
  if M.prompt_thinking then
    M.utils.safe_notify("Wait for the previous prompt to finish", vim.log.levels.WARN)
    return
  end
  vim.api.nvim_input("<Esc>") -- exit selection mode for better ux
  local selected_lines = M.get_visual_selection()
  local func_data = M.treesitter.get_func_ast_data(0)
  local func_signatures = M.treesitter.get_func_signatures(func_data, true, true)
  local selected_text = M.tag_selected_text(table.concat(selected_lines, "\n"))
  local prompt = "Implement the following code.\n"
    .. "Respond with code only. Do NOT wrap the output in backticks.\n\n"
    .. "IMPORTANT (read carefully):\n"
    .. "- The list under 'Available function signatures' is provided strictly as reference (parameter names, types, and return shapes).\n"
    .. "- DO NOT implement, re-declare, or modify any function signatures that appear in that list. Do not output new top-level function definitions that match those signatures.\n"
    .. "- If the selected text includes a function signature with an empty body or placeholder, implement only the function body (the code inside the existing signature). Keep the original signature exactly as it appears in the file.\n"
    .. "- If the selected text already contains a full implementation for a function, do NOT change or re-declare that function.\n"
    .. "- Do not add imports, new public functions, or change the public API unless the selection clearly requires it and the change is unambiguous.\n\n"
    .. "If the task is unclear, signatures are inconsistent (e.g. duplicates with different shapes), or you cannot safely implement the requested code, do NOT implement anything. Instead return a single regular comment (in the target language) explaining what must be changed or why the task is ambiguous.\n\n"
    .. "Code (implement only what's needed inside the selection):\n"
    .. selected_text
    .. "\n\n"
    .. "Language: "
    .. vim.bo.filetype
    .. "\n\n"
    .. "Available function signatures (reference only — do NOT implement or re-declare):\n"
    .. table.concat(func_signatures, "\n")
    .. "\n\n"
    .. "Keep existing coding style and formatting. Output only code or a single clarifying comment if you cannot proceed."
  M.call_api({ M.history.pack("You", prompt) }, vim.api.nvim_get_current_buf(), M.start_line - 1, M.end_line + 1, false)
end

---@return nil
function M.send_prompt()
  if M.prompt_win then
    local win_buf_lines = vim.api.nvim_buf_get_lines(M.prompt_history_buf, 0, -1, false)
    -- local win_buf_text = table.concat(win_buf_lines, "\n")
    M.append_prompt_message(M.prompt_buf, nil)
    M.call_api(M.history.get(), M.prompt_history_buf, #win_buf_lines, -1, true)
  else
    M.utils.safe_notify("chat.nvim: Select lines first", vim.log.levels.INFO)
  end
end

---@return function
---@param buf integer
---@param row integer
function M.start_spinner(buf, row)
  M.prompt_thinking = true
  local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  local spin_index = 1
  vim.api.nvim_buf_set_lines(buf, row, row, false, { "" })
  local timer = vim.uv.new_timer()
  if not timer then
    return function() end
  end
  timer:start(
    0,
    100,
    vim.schedule_wrap(function()
      local frame = spinner[spin_index]

      M.mark_id = vim.api.nvim_buf_set_extmark(buf, M.chat_ns, row, 0, {
        id = M.mark_id, -- reuse same extmark
        virt_text = { { "Thinking " .. frame, "Comment" } },
        virt_text_pos = "eol",
      })

      spin_index = spin_index % #spinner + 1
    end)
  )

  ---@return nil
  ---@param ok boolean
  return function(ok)
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end

    if M.mark_id then
      vim.api.nvim_buf_del_extmark(buf, M.chat_ns, M.mark_id)
      M.mark_id = nil
    end
    if not ok then
      local lock_buf = M.unlock_buf(buf)
      vim.api.nvim_buf_set_lines(buf, row, row + 1, false, {})
      lock_buf()
    end
    M.prompt_thinking = false
  end
end

---@return string[]
function M.get_visual_selection()
  -- Get start and end positions
  local _, s_line, s_col, _ = unpack(vim.fn.getpos("v"))
  local _, e_line, e_col, _ = unpack(vim.fn.getpos("."))
  M.start_line = math.min(s_line, e_line)
  M.end_line = math.max(s_line, e_line)
  -- Ensure start is before end for selection logic
  if s_line > e_line or (s_line == e_line and s_col > e_col) then
    s_line, e_line = e_line, s_line
    s_col, e_col = e_col, s_col
  end

  -- This returns the selection where the end is the cursor position
  -- return vim.api.nvim_buf_get_text(0, s_line - 1, s_col - 1, e_line - 1, e_col, {})

  -- This return the selection of the whole line (not the cursor position)
  return vim.api.nvim_buf_get_lines(0, s_line - 1, e_line, false)
end

return M
