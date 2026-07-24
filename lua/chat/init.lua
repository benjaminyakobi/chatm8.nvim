local M = {}
local state = {} -- NOTE: being initialized inside M.setup()
local imports = {} -- NOTE: being initialized inside M.setup()

---@return string
---@param messages ChatMessage[]
---@param cb function
local function summarize(messages, cb)
  local summarize_prompt = state.active_session:pack(
    "You",
    [[ Summarize this conversation for future context.

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

      Write the summary as clear bullet points that another engineer can immediately continue from. ]],
    os.time()
  )
  table.insert(messages, summarize_prompt)
  local text
  state.provider_module.answer(messages, function(result)
    vim.schedule(function()
      if result.error then
        cb(nil, result.error)
        return
      end

      cb(result.content, nil)
    end)
  end)
  return text
end

---@return nil
---@param s_line integer
---@param e_line integer
local function set_total_token_usage(s_line, e_line)
  local ttu = "Total Token Usage: " .. state.active_session.total_token_usage
  -- vim.api.nvim_buf_set_lines(state.prompt_history_buf, s_line, e_line, false, { ttu, "" })
  vim.api.nvim_buf_set_lines(state.prompt_history_buf, 2, 4, false, { ttu, "" })

  vim.api.nvim_buf_set_extmark(state.prompt_history_buf, state.chat_ns, s_line, 0, {
    hl_group = "ChatUI",
    end_col = #ttu,
  })
end

---@return nil
---@param role string
---@param text string
---@param timestamp integer
---@param token_usage string?
---@param total_token_usage integer?
local function add_to_session(role, text, timestamp, token_usage, total_token_usage)
  if role ~= "You" and role ~= "Assistant" and role ~= "Error" then
    return
  end
  state.active_session:add(role, text, timestamp, token_usage, total_token_usage)
  imports.storage.save_session(state.active_session)
end

---@return nil
---@param buf integer
---@param role string
---@param text string
---@param timestamp integer
---@param token_usage string?
---@param total_token_usage integer?
local function add_to_chat_window(buf, role, text, timestamp, token_usage, total_token_usage)
  if role ~= "You" and role ~= "Assistant" and role ~= "Error" then
    return
  end

  ---@return string
  local function build_header()
    local human_ts = os.date("%d-%m-%Y %H:%M:%S", timestamp)
    local header = "❯ " .. role .. " | " .. human_ts
    return header
  end

  local lock_buf = imports.utils.unlock_buf(buf)
  -- TODO: update total token usage line (number 2)
  set_total_token_usage(2, 3)
  local lines = vim.split(text, "\n", { plain = true })
  local header = build_header()
  local header_line = vim.api.nvim_buf_line_count(buf)
  local total_lines = { header }
  if token_usage then
    total_lines = { header, token_usage }
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
  vim.api.nvim_buf_set_extmark(buf, state.chat_ns, header_line, 0, {
    hl_group = role,
    end_col = #header,
  })
  if token_usage then
    vim.api.nvim_buf_set_extmark(buf, state.chat_ns, header_line + 1, 0, {
      hl_group = role,
      end_col = #token_usage,
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
end

---@return nil
local function maybe_summarize()
  local start_idx, end_idx = state.active_session:next_chunk_to_summarize()
  if start_idx and end_idx and not state.summarize_in_progress then
    state.summarize_in_progress = true
    local messages = vim.list_slice(state.active_session:get_messages(), start_idx, end_idx)
    summarize(messages, function(summary, err)
      if err then
        imports.utils.safe_notify("chatm8.nvim: Failed to summarize history, " .. err, vim.log.levels.ERROR)
        return
      end

      state.active_session:add_summary(start_idx, end_idx, summary)
      imports.storage.save_session(state.active_session)
      state.summarize_in_progress = false
    end)
  end
end

---@return nil
---@param buf integer
---@param role string
---@param text string
---@param timestamp integer
---@param token_usage string?
---@param total_token_usage integer?
local function append_message(buf, role, text, timestamp, token_usage, total_token_usage)
  add_to_session(role, text, timestamp, token_usage, total_token_usage)
  add_to_chat_window(buf, role, text, timestamp, token_usage, total_token_usage)
  maybe_summarize()
end

---@return nil
---@param prompt table
---@param buf integer
---@param s_line integer
---@param e_line integer
---@param prompt_win boolean
local function call_api(prompt, buf, s_line, e_line, prompt_win)
  local lock_buf = imports.utils.unlock_buf(buf)
  local stop_spinner = imports.utils.start_spinner(buf, s_line, state.chat_ns)
  state.prompt_thinking = true
  state.provider_module.answer(prompt, function(result)
    vim.schedule(function()
      if result.error then
        stop_spinner(false)
        lock_buf()

        if prompt_win then
          append_message(buf, "Error", result.error, os.time())
        else
          imports.utils.safe_notify(result.error, vim.log.levels.ERROR)
        end
        state.prompt_thinking = false
        return
      end

      stop_spinner(true)
      lock_buf()
      state.prompt_thinking = false

      if prompt_win then
        append_message(buf, "Assistant", result.content, os.time(), result.usage, result.total_usage)
      else
        vim.api.nvim_buf_set_lines(buf, s_line, e_line, false, vim.split(result.content, "\n"))
        imports.utils.safe_notify("chatm8.nvim: " .. result.usage, vim.log.levels.INFO)
      end
    end)
  end)
end

---@return nil
local function send_prompt()
  if state.prompt_win then
    local win_buf_lines = vim.api.nvim_buf_get_lines(state.prompt_history_buf, 0, -1, false)
    call_api(state.active_session:build_context(), state.prompt_history_buf, #win_buf_lines, -1, true)
  else
    imports.utils.safe_notify("chatm8.nvim: Select lines first", vim.log.levels.INFO)
  end
end

---@return nil
---@param provider_name string
---@param s_line integer
---@param e_line integer
local function set_provider(buf, provider_name, s_line, e_line)
  imports.providers.set(provider_name)
  local ok, provider = pcall(require, "chat.providers." .. imports.providers.name)
  if not ok then
    imports.utils.safe_notify("No provider found for: " .. tostring(imports.providers.name), vim.log.levels.ERROR)
    return
  end
  state.provider_module = provider
  local session_provider = "Provider: " .. imports.providers.current
  vim.api.nvim_buf_set_lines(buf, 4, 6, false, { session_provider, "" })
  vim.api.nvim_buf_set_extmark(buf, state.chat_ns, 4, 0, {
    hl_group = "ChatUI",
    end_col = #session_provider,
  })
  imports.utils.safe_notify("chatm8.nvim: current provider: " .. imports.providers.current, vim.log.levels.INFO)
end

---@return nil
local function select_provider()
  vim.ui.select(imports.providers.list, { prompt = "Select chat provider" }, function(choice)
    if choice then
      local lock_buf = imports.utils.unlock_buf(state.prompt_history_buf)
      set_provider(state.prompt_history_buf, choice, 4, 5)
      lock_buf()
    end
  end)
end

---@return nil
local function complete_implementation()
  if state.prompt_thinking then
    imports.utils.safe_notify("Wait for the previous prompt to finish", vim.log.levels.WARN)
    return
  end
  vim.api.nvim_input("<Esc>") -- exit selection mode for better ux
  local selected_lines, start_line, end_line = imports.utils.get_visual_selection()
  state.start_line, state.end_line = start_line, end_line
  local func_data = imports.treesitter.get_func_ast_data(0)
  local func_signatures = imports.treesitter.get_func_signatures(func_data, true, true)
  local selected_text = imports.utils.tag_selected_text(table.concat(selected_lines, "\n"))
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
  call_api(
    { state.active_session:pack("You", prompt, os.time()) },
    vim.api.nvim_get_current_buf(),
    state.start_line - 1,
    state.end_line + 1,
    false
  )
end

---@return nil
local function open_single_prompt_window()
  -- parent size
  local parent_width = vim.api.nvim_win_get_width(state.parent_win)
  local parent_height = vim.api.nvim_win_get_height(state.parent_win)

  -- your desired size
  local width = math.min(90, parent_width)
  local height = math.min(60, parent_height)

  -- center position
  local col = math.floor((parent_width - width) / 2)
  local row = math.floor((height - 15) / 2)

  local single_prompt_win_conf = {
    relative = "win",
    win = state.parent_win,
    row = row,
    col = col,
    width = width,
    height = 15, -- NOTE: default max size
    style = "minimal",
    border = "rounded",
    title = " Custom Prompt (Overrides visual selection) ",
    title_pos = "center",
    zindex = 101,
  }
  -- NOTE: storing current buf number before opening the float window
  local current_buf = vim.api.nvim_get_current_buf()

  if state.single_prompt_buf and state.single_prompt_win then
    single_prompt_win_conf.height =
      math.min(single_prompt_win_conf.height, vim.api.nvim_win_text_height(state.single_prompt_win, {}).all)
    vim.api.nvim_win_set_config(state.single_prompt_win, single_prompt_win_conf)
  else
    local selected_text
    local selected_lines, start_line, end_line = imports.utils.get_visual_selection()
    state.start_line, state.end_line = start_line, end_line

    local func_data = imports.treesitter.get_func_ast_data(current_buf)
    local func_signatures = imports.treesitter.get_func_signatures(func_data, true, true)

    if imports.utils.is_empty(selected_lines) then
      selected_text = table.concat(selected_lines, "\n")
    else
      selected_text = imports.utils.tag_selected_text(table.concat(selected_lines, "\n"))
    end

    local tagged_selected_lines = vim.split(selected_text, "\n")
    single_prompt_win_conf.height = math.min(single_prompt_win_conf.height, #tagged_selected_lines)

    state.single_prompt_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.single_prompt_buf].buftype = "prompt"
    vim.bo[state.single_prompt_buf].filetype = "markdown"
    vim.bo[state.single_prompt_buf].swapfile = false
    vim.fn.prompt_setprompt(state.single_prompt_buf, "")
    vim.api.nvim_buf_set_lines(state.single_prompt_buf, 0, -1, false, tagged_selected_lines)

    -- callback when user presses Enter
    vim.fn.prompt_setcallback(state.single_prompt_buf, function()
      local prompt_lines = vim.api.nvim_buf_get_lines(state.single_prompt_buf, 0, -1, false)
      if imports.utils.is_empty(prompt_lines) then
        imports.utils.safe_notify("Write prompt first", vim.log.levels.WARN)
        vim.api.nvim_buf_set_lines(state.single_prompt_buf, 0, -1, false, {})
        return
      end

      if state.prompt_thinking then
        imports.utils.safe_notify("Wait for the previous prompt to finish", vim.log.levels.WARN)
        return
      end

      local prompt_text = table.concat(prompt_lines, "\n")
      local prompt = "Modify the selected code according to the user's instructions.\n"
        .. "Respond with code only. Do NOT wrap the output in backticks.\n"
        .. "Do NOT include explanations, notes, comments, markdown, or any text outside the replacement code.\n\n"
        .. "IMPORTANT (read carefully):\n"
        .. "- Return only the code that should replace the selected text.\n"
        .. "- Preserve the surrounding file's style, formatting, naming conventions, and language idioms.\n"
        .. "- Do not add unrelated refactors, cleanups, or stylistic changes.\n"
        .. "- Keep existing APIs, function signatures, types, and behavior unchanged unless the user's instructions explicitly require otherwise.\n"
        .. "- If the selection is only part of a function body, return only the replacement body code.\n"
        .. "- If the selection is a complete function, class, block, or expression, return the complete replacement for that selection.\n"
        .. "- Do not add placeholder code, TODO comments, or unfinished implementations.\n\n"
        .. "If the user's instructions are ambiguous, impossible, or require information not present in the selection, return a single regular comment (in the target language) explaining what is missing.\n\n"
        .. "User instructions:\n"
        .. prompt_text
        .. "\n\n"
        .. "Language: "
        .. vim.bo[state.parent_buf].filetype
        .. "\n\n"
        .. "Available function signatures (reference only — do NOT implement or re-declare):\n"
        .. table.concat(func_signatures, "\n")
        .. "\n\n"
        .. "Keep existing coding style and formatting. Output only code or a single clarifying comment if you cannot proceed."

      call_api(
        { state.active_session:pack("You", prompt, os.time()) },
        current_buf,
        state.start_line - 1,
        state.end_line + 1,
        false
      )

      vim.api.nvim_win_close(state.single_prompt_win, true)
    end)

    -- Creating backdrop buf & win to block mouse clicks
    local backdrop_buf = vim.api.nvim_create_buf(false, true)
    local backdrop_win = vim.api.nvim_open_win(backdrop_buf, false, {
      relative = "win",
      win = state.parent_win,
      row = 0,
      col = 0,
      width = parent_width,
      height = parent_height,
      style = "minimal",
      focusable = false,
      zindex = 100,
    })
    vim.wo[backdrop_win].winblend = 30

    -- Opening the prompt window
    state.single_prompt_win = vim.api.nvim_open_win(state.single_prompt_buf, true, single_prompt_win_conf)
    imports.utils.set_border(state.single_prompt_win, "PromptBorderActive", "PromptTitleActive")

    -- custom key maps - disabling key maps
    vim.keymap.set("v", "<Leader>8i", function()
      vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "n", false)
      imports.utils.safe_notify("Disabled on prompt window", vim.log.levels.INFO)
    end, { desc = "Complete implementation (Disabled)", buf = state.single_prompt_buf })

    vim.keymap.set("n", "<Leader>8c", function()
      imports.utils.safe_notify("Disabled on prompt window", vim.log.levels.INFO)
    end, { desc = "Toggle persistent chat window (Disabled)", buf = state.single_prompt_buf })

    vim.keymap.set("v", "<Leader>8p", function()
      vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "n", false)
      imports.utils.safe_notify("Disabled on prompt window", vim.log.levels.INFO)
    end, { desc = "Custom prompt: Replace selection (Disabled)", buf = state.single_prompt_buf })

    vim.keymap.set({ "n", "i" }, "<Leader>8p", function()
      vim.api.nvim_set_current_win(state.single_prompt_win)
    end, { desc = "Focus custom prompt window", buf = state.parent_buf })

    local single_prompt_session_group = vim.api.nvim_create_augroup("llm_single_prompt_session", { clear = true })

    -- detecting prompt window enter
    vim.api.nvim_create_autocmd("WinEnter", {
      group = single_prompt_session_group,
      buffer = state.single_prompt_buf,
      callback = function()
        local win = vim.api.nvim_get_current_win()
        if win == state.single_prompt_win then
          imports.utils.set_border(state.single_prompt_win, "PromptBorderActive", "PromptTitleActive")
        end
      end,
    })

    -- detecting prompt window close
    vim.api.nvim_create_autocmd("WinClosed", {
      group = single_prompt_session_group,
      buffer = state.single_prompt_buf,
      callback = function(args)
        if state.single_prompt_win == tonumber(args.match) then
          state.single_prompt_win = nil
          state.single_prompt_buf = nil
          vim.api.nvim_win_close(backdrop_win, true)
          vim.api.nvim_buf_delete(backdrop_buf, {})
          pcall(vim.api.nvim_clear_autocmds, { group = single_prompt_session_group })
          vim.keymap.del({ "n", "i" }, "<Leader>8p", { buf = state.parent_buf })
        end
      end,
    })

    -- detecting text changes to resize prompt window when needed
    local timer
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = single_prompt_session_group,
      buffer = state.single_prompt_buf,
      callback = function()
        -- cancel previous timer on every keystroke
        if timer and not timer:is_closing() then
          timer:stop()
          timer:close()
          timer = nil
        end

        -- defered resize call
        timer = vim.defer_fn(function()
          open_single_prompt_window()
        end, 50)
      end,
    })

    -- detecting resize events to resize the prompt window
    vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
      group = single_prompt_session_group,
      buffer = state.single_prompt_buf,
      callback = function(args)
        if state.parent_win == tonumber(args.match) and state.single_prompt_win ~= nil then
          open_single_prompt_window()
        end
      end,
    })

    -- detecting leaving the window to color the window border
    vim.api.nvim_create_autocmd("WinLeave", {
      group = single_prompt_session_group,
      buffer = state.single_prompt_buf,
      callback = function()
        local win = vim.api.nvim_get_current_win()
        if win == state.single_prompt_win then
          imports.utils.set_border(state.single_prompt_win, "ChatBorderInactive", "PromptTitleInactive")
        end
      end,
    })

    imports.utils.mouse_guard(state.single_prompt_win, state.single_prompt_buf)
  end
end

---@return nil
---@param optional_prompt_win_height integer|nil
local function set_prompt_window_conf(optional_prompt_win_height)
  -- if these two buffer not exist - do not configure windows
  if state.prompt_buf == nil or state.prompt_history_buf == nil then
    return
  end

  -- default prompt window height
  optional_prompt_win_height = optional_prompt_win_height or 1

  -- parent size
  if not state.chat_win then
    return
  end
  -- parent size
  local parent_width = vim.api.nvim_win_get_width(state.chat_win)
  local parent_height = vim.api.nvim_win_get_height(state.chat_win)

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
    win = state.chat_win,
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
    win = state.chat_win,
    row = row + chat_height + 2,
    col = col,
    width = width,
    height = input_height,
    style = "minimal",
    border = "rounded",
    title = " Enter Prompt ",
    title_pos = "center",
  }

  if state.prompt_win and state.prompt_history_win then
    vim.api.nvim_win_set_config(state.prompt_win, prompt_win_conf)
    vim.api.nvim_win_set_config(state.prompt_history_win, history_win_conf)
  else -- open new windows and continue configuring them
    state.prompt_history_win = vim.api.nvim_open_win(state.prompt_history_buf, true, history_win_conf)
    state.prompt_win = vim.api.nvim_open_win(state.prompt_buf, true, prompt_win_conf)

    -- set custom options
    vim.api.nvim_set_option_value("number", true, { win = state.prompt_win })
    vim.api.nvim_set_option_value("number", true, { win = state.prompt_history_win })
    imports.utils.set_border(state.prompt_win, "PromptBorderActive", "PromptTitleActive")

    -- set cursor at the last line & start insert mode
    local last = vim.api.nvim_buf_line_count(state.prompt_buf)
    vim.api.nvim_win_set_cursor(state.prompt_win, { last, 0 })

    -- custom key maps - disabling key maps
    for _, buf in ipairs({ state.prompt_buf, state.prompt_history_buf }) do
      vim.keymap.set("v", "<Leader>8i", function()
        imports.utils.safe_notify("Disabled on prompt window", vim.log.levels.INFO)
      end, { desc = "Complete implementation (Disabled)", buf = buf })
    end

    -- custom key maps - switcing between prompt & history windows keymaps
    vim.keymap.set({ "n", "v" }, "<C-s>", function()
      vim.api.nvim_set_current_win(state.prompt_history_win)
    end, { buf = state.prompt_buf })

    vim.keymap.set({ "n", "v" }, "<C-s>", function()
      vim.api.nvim_set_current_win(state.prompt_win)
    end, { buf = state.prompt_history_buf })

    -- set auto commands
    local prompt_session_group = vim.api.nvim_create_augroup("llm_prompt_session", { clear = true })
    local chat_session_group = vim.api.nvim_create_augroup("llm_chat_session", { clear = true })

    for _, buf in ipairs({ state.prompt_buf, state.prompt_history_buf }) do
      vim.api.nvim_create_autocmd("WinEnter", {
        group = prompt_session_group,
        buffer = buf,
        callback = function()
          local win = vim.api.nvim_get_current_win()
          if win == state.prompt_history_win then
            imports.utils.set_border(state.prompt_history_win, "ChatBorderActive", "PromptTitleActive")
          elseif win == state.prompt_win then
            imports.utils.set_border(state.prompt_win, "PromptBorderActive", "PromptTitleActive")
          end
        end,
      })

      vim.api.nvim_create_autocmd("WinLeave", {
        group = prompt_session_group,
        buffer = buf,
        callback = function()
          local win = vim.api.nvim_get_current_win()
          if win == state.prompt_history_win then
            imports.utils.set_border(state.prompt_history_win, "ChatBorderInactive", "PromptTitleInactive")
          elseif win == state.prompt_win then
            imports.utils.set_border(state.prompt_win, "PromptBorderInactive", "PromptTitleInactive")
          end
        end,
      })
    end

    vim.api.nvim_create_autocmd("WinClosed", {
      group = chat_session_group,
      callback = function(args)
        if
          state.chat_win == tonumber(args.match)
          or state.prompt_win == tonumber(args.match)
          or state.prompt_history_win == tonumber(args.match)
        then
          vim.api.nvim_win_close(state.prompt_win, true)
          state.prompt_win = nil
          vim.api.nvim_win_close(state.prompt_history_win, true)
          state.prompt_history_win = nil
          vim.api.nvim_win_close(state.chat_win, true)
          state.chat_win = nil
          if state.single_prompt_win then
            open_single_prompt_window()
          end
        end
      end,
    })

    vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
      group = chat_session_group,
      callback = function(args)
        if state.parent_win == tonumber(args.match) or state.chat_win == tonumber(args.match) then
          local text_height
          if state.prompt_win and vim.api.nvim_win_is_valid(state.prompt_win) then
            text_height = vim.api.nvim_win_text_height(state.prompt_win, {}).all
          end
          set_prompt_window_conf(text_height)
        end
      end,
    })

    -- detecting text changes to resize prompt window when needed
    local timer
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = prompt_session_group,
      buffer = state.prompt_buf,
      callback = function()
        -- cancel previous timer on every keystroke
        if timer and not timer:is_closing() then
          timer:stop()
          timer:close()
          timer = nil
        end

        -- defered resize call
        timer = vim.defer_fn(function()
          local text_height = vim.api.nvim_win_text_height(state.prompt_win, {}).all
          set_prompt_window_conf(math.min(15, text_height))
        end, 50)
      end,
    })
  end
end

---@return nil
local function init_prompt_history_buf()
  local lock_buf = imports.utils.unlock_buf(state.prompt_history_buf)
  local session_title = "Persistent session: " .. state.active_session.title
  vim.api.nvim_buf_set_lines(state.prompt_history_buf, 0, -1, false, {})
  vim.api.nvim_buf_set_lines(state.prompt_history_buf, 0, 1, false, { session_title, "" })
  set_total_token_usage(2, 3)
  set_provider(state.prompt_history_buf, imports.providers.current, 4, 5)

  vim.api.nvim_buf_set_extmark(state.prompt_history_buf, state.chat_ns, 0, 0, {
    hl_group = "ChatUI",
    end_col = #session_title,
  })
  lock_buf()
end

---@return nil
local function open_prompt_window()
  if state.prompt_buf and state.prompt_history_buf then
    set_prompt_window_conf()
    return
  end

  -- Configure buffers and windows
  state.prompt_history_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.prompt_history_buf].filetype = "markdown"
  vim.bo[state.prompt_history_buf].swapfile = false
  vim.bo[state.prompt_history_buf].modifiable = false
  init_prompt_history_buf()

  state.prompt_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.prompt_buf].buftype = "prompt"
  vim.bo[state.prompt_buf].filetype = "markdown"
  vim.bo[state.prompt_buf].swapfile = false
  vim.fn.prompt_setprompt(state.prompt_buf, "")

  -- callback when user presses Enter
  vim.fn.prompt_setcallback(state.prompt_buf, function()
    local prompt_lines = vim.api.nvim_buf_get_lines(state.prompt_buf, 0, -1, false)
    if imports.utils.is_empty(prompt_lines) then
      imports.utils.safe_notify("Write prompt first", vim.log.levels.WARN)
      vim.api.nvim_buf_set_lines(state.prompt_buf, 0, -1, false, {})
      return
    end
    if state.prompt_thinking then
      imports.utils.safe_notify("Wait for the previous prompt to finish", vim.log.levels.WARN)
      local line_count = vim.api.nvim_buf_line_count(state.prompt_buf)
      vim.api.nvim_buf_set_lines(state.prompt_buf, line_count - 1, line_count, false, {})
      imports.utils.scroll_to_bottom(state.prompt_win, state.prompt_buf)
      return
    end
    local prompt_text = table.concat(prompt_lines, "\n")
    append_message(state.prompt_history_buf, "You", prompt_text, os.time())
    send_prompt()
    vim.api.nvim_buf_set_lines(state.prompt_buf, 0, -1, false, {})
  end)
end

---@return nil
local function toggle_persistent_chat_window()
  -- if already open -> close
  if state.chat_win then
    vim.api.nvim_win_close(state.chat_win, true)
    state.chat_win = nil
    return
  end

  -- open new split
  vim.cmd("vsplit") -- or "split" for horizontal split window
  state.chat_win = vim.api.nvim_get_current_win()
  open_prompt_window()
end

---@return nil
---@param operations table<string, function>
---@param op_keys table<string>
local function select_automated_operation(operations, op_keys)
  vim.ui.select(op_keys, { prompt = "Select automated operation" }, function(choice)
    if choice then
      local fn = operations[choice]
      if fn then
        fn()
      else
        imports.utils.safe_notify("chatm8.nvim: Invalid operation", vim.log.levels.ERROR)
      end
    end
  end)
end

---@return table<string>[] titles, table<string, string> map
local function process_session_list()
  ---@type table<string, string>, table<string>
  local sessions_title_sorted, sessions_title_id_map = imports.storage.list_sessions()

  return sessions_title_sorted, sessions_title_id_map
end

---@return nil
local function new_session()
  state.active_session = imports.session:new()
  init_prompt_history_buf()
  imports.utils.safe_notify("chatm8.nvim: Started new session", vim.log.levels.INFO)
end

---@return nil
local function delete_session()
  ---@type table<string, string>, table<string>
  local session_titles, sessions_title_id_map = process_session_list()

  vim.ui.select(session_titles, { prompt = "Select session to delete" }, function(choice)
    if choice then
      if sessions_title_id_map[choice] == state.active_session.id then
        imports.utils.safe_notify("chatm8.nvim: Impossible to delete active session", vim.log.levels.WARN)
        return
      end
      local session_id = sessions_title_id_map[choice]
      if session_id then
        ---@type boolean, string?
        local ok, err = imports.storage.delete_session(session_id)
        if not ok then
          imports.utils.safe_notify("chatm8.nvim: " .. err, vim.log.levels.ERROR)
          return
        end
        imports.utils.safe_notify("chatm8.nvim: Deleted " .. choice, vim.log.levels.INFO)
      else
        imports.utils.safe_notify("chatm8.nvim: Invalid session", vim.log.levels.ERROR)
      end
    end
  end)
end

---@return nil
local function load_session()
  ---@type table<string, string>, table<string>
  local session_titles, sessions_title_id_map = process_session_list()

  vim.ui.select(session_titles, { prompt = "Select session to load" }, function(choice)
    if choice then
      local session_id = sessions_title_id_map[choice]
      if session_id then
        ---@type Session?, string?
        local session, err = imports.storage.load_session(session_id)
        if err then
          imports.utils.safe_notify("chatm8.nvim: " .. err, vim.log.levels.ERROR)
        elseif not session then
          imports.utils.safe_notify("chatm8.nvim: Failed to retrieve session", vim.log.levels.ERROR)
        else
          -- NOTE: first load the sesion and init prompt history window after
          -- to update the upper section of the chat window also
          state.active_session = state.active_session:from_table(session)
          init_prompt_history_buf()
          for _, msg in ipairs(session.messages) do
            local role = msg.role
            local content = msg.content
            local timestamp = msg.timestamp
            local token_usage = msg.token_usage
            add_to_chat_window(state.prompt_history_buf, role, content, timestamp, token_usage)
          end
          imports.utils.safe_notify("chatm8.nvim: Loaded " .. choice, vim.log.levels.INFO)
        end
      else
        imports.utils.safe_notify("chatm8.nvim: Invalid session", vim.log.levels.ERROR)
      end
    end
  end)
end

---@return nil
---@param opts table
function M.setup(opts)
  local chat_setup_group = vim.api.nvim_create_augroup("llm_chat_setup", { clear = true })
  opts = opts or {}

  -- Importing modules
  imports.treesitter = require("chat.treesitter")
  imports.utils = require("chat.utils")
  imports.providers = require("chat.providers")
  imports.storage = require("chat.storage")
  imports.session = require("chat.session")

  -- setting up a provider
  imports.providers.setup(opts.providers, opts.provider)

  -- initializing state
  state = {
    parent_buf = vim.api.nvim_get_current_buf(),
    parent_win = vim.api.nvim_get_current_win(),
    prompt_thinking = false,
    summarize_in_progress = false,
    chat_ns = vim.api.nvim_create_namespace("llm-chat"),
    active_session = imports.session:new(),
    help = [[
<Leader>8i: Inline Implementation
  1. [Visual Mode] Select text (either code snippets or natural language instructions).
  2. Press <Leader>8i to automatically complete the implementation or transform 
     the selection directly in the current buffer.

<Leader>8p: Single Prompt (Custom on Selection)
  1. [Visual Mode] Select text and press `<Leader>8p` to open a single prompt window.
  2. [Prompt Customization] Write a custom prompt template for this request.
  3. [Replace Selection] The model response replaces the selected text in the buffer.

<Leader>8o: Select Automated Operation
  1. [Visual Mode] Select text and press `<Leader>8o` to open an operation menu.
  2. Choose one of the available automated operations in the list.
  3. [Replace Selection] The selected operation runs on the selected text and replaces
     the selection with the model response.

<Leader>8c: Persistent Chat
  1. [Normal/Visual Mode] Press `<Leader>8c` to toggle a persistent chat window
     in a split view.
  2. [Chat Window] Maintain a continuous, multi-turn conversation with the model
     that persists across different files and buffers.
  2.0. [Session] This session is persistent: it can be load again with `<Leader>8l`.
    2.1. [Layout] Two windows will open:
         - Upper window: conversation history (read-only).
         - Lower window: prompt input.
    2.2. [Navigation] Press <C-s> in Normal or Visual mode to switch between the
         history window and the prompt window.

<Leader>8s: LLM Provider Selection
  1. Press `<Leader>8s` to open a provider selection menu.
  2. Choose the active LLM provider (e.g., OpenAI / Anthropic, depending on your setup).
  3. [Scope] The selected provider becomes the default for all subsequent Leader-8 features
     (e.g., `<Leader>8i` inline implementation, `<Leader>8p` single prompt, and `<Leader>8c` chat).
  4. [Persistence] The selection is saved for the current Neovim session.

<Leader>8l: Load Old Sessions
  1. [Normal Mode] Press `<Leader>8l` to open a list of previously saved chat sessions.
  2. Select a session to load its conversation history into the chat window.
  3. [Restore] The loaded session becomes the active context, letting you resume a
     past conversation across files and buffers.

<Leader>8d: Delete Old Sessions
  1. [Normal Mode] Press `<Leader>8d` to open a list of previously saved chat sessions.
  2. Select a session to delete it permanently.

<Leader>8n: Start New Session
  1. [Normal Mode] Press `<Leader>8n` to start a new session.
]],
  }

  open_prompt_window()

  -- setting global autocmds
  vim.api.nvim_create_autocmd("WinClosed", {
    group = chat_setup_group,
    callback = function(args)
      local closed_win = tonumber(args.match)

      -- main window closed
      if closed_win ~= state.parent_win then
        return
      end

      vim.cmd("qa")
    end,
  })

  -- setting global keymaps
  vim.keymap.set("n", "<Leader>8?", function()
    if opts.dev then
      print("chatm8.nvim: local setup\n" .. state.help)
    else
      print("chatm8.nvim: remote setup\n" .. state.help)
    end
  end, { desc = "Help" })

  vim.keymap.set("v", "<Leader>8i", function()
    complete_implementation()
  end, { desc = "Complete implementation: Replace selection" })

  vim.keymap.set("v", "<leader>8p", function()
    open_single_prompt_window()
  end, {
    desc = "Custom prompt: Replace selection",
  })

  vim.keymap.set("v", "<Leader>8o", function()
    ---@type table<string, function>
    local operations = {
      ["Complete implementation"] = complete_implementation,
      ["Custom prompt"] = open_single_prompt_window,
    }
    ---@type table<string>
    local op_keys = {}
    for key, _ in pairs(operations) do
      table.insert(op_keys, key)
    end
    select_automated_operation(operations, op_keys)
  end, { desc = "Select automated operation: Replace Selection" })

  vim.keymap.set("n", "<Leader>8c", function()
    toggle_persistent_chat_window()
  end, { desc = "Toggle persistent chat window" })

  vim.keymap.set("n", "<leader>8s", function()
    select_provider()
  end, {
    desc = "Select chat provider",
  })

  vim.keymap.set("n", "<leader>8l", function()
    load_session()
  end, {
    desc = "Load old sessions",
  })

  vim.keymap.set("n", "<leader>8d", function()
    delete_session()
  end, {
    desc = "Delete old sessions",
  })

  vim.keymap.set("n", "<leader>8n", function()
    new_session()
  end, {
    desc = "Start new session",
  })

  -- custom key maps including overrides
  vim.keymap.set("n", "<C-w>l", function()
    local cur = vim.api.nvim_get_current_win()

    -- If we're in the parent split, jump to the float.
    if cur == state.parent_win and state.prompt_win and vim.api.nvim_win_is_valid(state.prompt_win) then
      vim.api.nvim_set_current_win(state.prompt_win)
      return
    end

    -- Otherwise perform the normal <C-w>l
    vim.cmd("wincmd l")
  end)

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

return M
