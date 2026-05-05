local M = {
  chat_buf = nil,
  prompt_buf = nil,
  prompt_thinking = false,
  extractors = {},
  chat_ns = vim.api.nvim_create_namespace("llm-chat"),
  groups = {
    prompt_session = vim.api.nvim_create_augroup("llm_prompt_session", { clear = true }),
    chat_session = vim.api.nvim_create_augroup("llm_chat_session", { clear = true }),
  },
}

---@return nil
---@param opts table
function M.setup(opts)
  M.main_buf = vim.api.nvim_get_current_buf()
  opts = opts or {}
  M.api_key = opts.api_key or ""
  local help = [[
<Leader>8p: Prompt Interface
  1. [Visual Mode] Select text (either code snippets or natural language 
     instructions) and press <Leader>8p to open the prompt window.
  2. [Layout] Two windows will open:
     - Upper window: conversation history (read-only).
     - Lower window: prompt input.
  3. [Navigation] Press <C-s> in Normal or Visual mode to switch between the
     history window and the prompt window.

<Leader>8i: Inline Implementation
  1. [Visual Mode] Select text (either code snippets or natural language instructions).
  2. Press <Leader>8i to automatically complete the implementation or transform 
     the selection directly in the current buffer.

<Leader>8c: Persistent Chat
  1. [Normal/Visual Mode] Press `<Leader>8c` to toggle a persistent chat window 
     in a split view.
  2. [Chat Window] Maintain a continuous, multi-turn conversation with the model 
     that persists across different files and buffers.]]

  vim.keymap.set("n", "<Leader>8?", function()
    if opts.dev then
      print("chat.nvim: local setup\n" .. help)
    else
      print("chat.nvim: remote setup\n" .. help)
    end
  end, { desc = "Help" })

  vim.keymap.set("v", "<Leader>8i", function()
    M.complete_implementation()
  end, { desc = "Complete implementation" })

  vim.keymap.set("v", "<Leader>8p", function()
    M.open_prompt_window()
  end, { desc = "Open prompt window" })

  vim.keymap.set("n", "<Leader>8c", function()
    M.toggle_persistent_chat_window()
  end, { desc = "Toggle persistent chat window" })

  -- setting global hightlights
  vim.api.nvim_set_hl(0, "You", { fg = "#89b4fa", bold = true })
  vim.api.nvim_set_hl(0, "Assistant", { fg = "#a6e3a1", bold = true })
  vim.api.nvim_set_hl(0, "Error", { fg = "#d43131", bold = true })

  vim.api.nvim_set_hl(0, "PromptTitleActive", { fg = "#00ffcc", bold = true })
  vim.api.nvim_set_hl(0, "PromptTitleInactive", { fg = "#00ffcc" })

  vim.api.nvim_set_hl(0, "ChatBorderActive", { fg = "#ff8800" }) -- bright
  vim.api.nvim_set_hl(0, "ChatBorderInactive", { fg = "#3b4261" }) -- dim

  vim.api.nvim_set_hl(0, "PromptBorderActive", { fg = "#ff8800" })
  vim.api.nvim_set_hl(0, "PromptBorderInactive", { fg = "#3b4261" })
end

-- ------------------------------------------------
-- ---------- ast data extractor helpers ----------
-- ------------------------------------------------

local ts = vim.treesitter

---@return string|nil
---@param node table
local function get_text(node)
  if type(node) == "table" then
    node = node[1]
  end
  if not node then
    return nil
  end
  return ts.get_node_text(node, 0)
end

---@return table|nil
---@param buf integer
---@param lang string
local function get_parser_root(buf, lang)
  local parser = ts.get_parser(buf, lang)
  if not parser then
    return
  end
  local tree = parser:parse()[1]
  return tree and tree:root()
end

---@return table
---@param node table
local function normalize_node(node)
  if type(node) == "table" then
    return node[1]
  end
  return node
end

---@return string
---@param lang string
---@param item table
local function build_signature(lang, item)
  if lang == "lua" then
    return string.format("function %s%s", item.name, item.params)
  end

  if lang == "go" then
    local sig

    if item.receiver then
      sig = string.format("func %s %s%s", item.receiver, item.name, item.params)
    elseif item.anonymous then
      sig = string.format("func%s", item.params)
    else
      sig = string.format("func %s%s", item.name, item.params)
    end

    if item.return_type then
      sig = sig .. " " .. item.return_type
    end

    return sig
  end

  if lang == "python" then
    local sig
    if item.receiver then
      sig = string.format("%s.%s%s", item.receiver, item.name, item.params)
    elseif item.anonymous then
      sig = string.format("lambda %s", item.params)
    elseif item.type == "assignment" then
      sig = string.format("def %s(%s)", item.name, item.params)
    else
      sig = string.format("def %s%s", item.name, item.params)
    end

    if item.return_type then
      sig = sig .. " -> " .. item.return_type
    end

    return sig
  end

  if lang == "javascript" then
    local sig
    if item.anonymous then
      sig = string.format("function%s%s", item.name, item.params)
    else
      sig = string.format("function %s%s", item.name, item.params)
    end
    return sig
  end

  return ""
end

---@return boolean
---@param node table
local function is_function_node(node)
  if not node then
    return false
  end
  local t = node:type()

  return t == "function_declaration"
    or t == "function_definition" -- Lua
    or t == "method_decleration" -- Go - declEration (known typo related to parsers)
    or t == "method_declaration" -- Go - declAration (known typo related to parsers)
    or t == "func_literal" -- Go
end

---@return boolean
---@param node table
local function is_function_nested(node)
  local parent = node

  while parent do
    parent = parent:parent()
    if parent and is_function_node(parent) then
      return true
    end
  end

  return false
end

---@return string[]
---@param func_data table
---@param exclude_nested boolean
---@param exclude_anonymous boolean
function M.get_func_signatures(func_data, exclude_nested, exclude_anonymous)
  local signatures = {}
  for _, item in ipairs(func_data) do
    if (item.nested == true and exclude_nested == true) or (item.anonymous and exclude_anonymous == true) then
      -- continue, skip this item
    else
      table.insert(signatures, item.signature)
    end
  end
  return signatures
end

---@return table
---@param buf integer
function M.get_func_ast_data(buf)
  buf = buf or 0
  local lang = vim.bo[buf].filetype

  local root = get_parser_root(buf, lang)
  if not root then
    return {}
  end

  local query = ts.query.get(lang, "functions")
  if not query then
    M.safe_notify("No query for " .. lang, vim.log.levels.WARN)
    return {}
  end

  local extractor = M.extractors[lang]
  if not extractor then
    M.safe_notify("No extractor for " .. lang, vim.log.levels.WARN)
    return {}
  end

  local results = {}

  for _, match in query:iter_matches(root, buf) do
    local item = extractor(match, query)
    if item then
      item.lang = lang
      item.signature = build_signature(lang, item)
      table.insert(results, item)
    end
  end

  return results
end

-- -----------------------------------------
-- ---------- ast data extractors ----------
-- -----------------------------------------

---@return table|nil
---@param match table
---@param query table
-- NOTE: Lua extractor
M.extractors.lua = function(match, query)
  local name, params, function_node, func_type

  for i, cap in ipairs(query.captures) do
    local node = match[i]

    if cap == "name" then
      name = get_text(node)
    elseif cap == "params" then
      params = get_text(node)
    elseif cap == "func" or cap == "anonymous_function" then
      function_node = node
    end
  end

  if not params then
    return nil
  end

  function_node = normalize_node(function_node)
  local is_nested = is_function_nested(function_node)

  local range
  if function_node then
    local start_row, start_col, end_row, end_col = function_node:range()
    range = { start_row, start_col, end_row, end_col }
    func_type = function_node:type()
  end

  return {
    type = func_type,
    name = name or "",
    params = params,
    range = range,
    nested = is_nested,
    anonymous = name == nil or name == "",
  }
end

---@return table|nil
---@param match table
---@param query table
-- NOTE: Go extractor
M.extractors.go = function(match, query)
  local name, params, ret, receiver, function_node, func_type

  for i, cap in ipairs(query.captures) do
    local node = match[i]

    if cap == "name" then
      name = get_text(node)
    elseif cap == "params" then
      params = get_text(node)
    elseif cap == "return" then
      ret = get_text(node)
    elseif cap == "receiver" then
      receiver = get_text(node)
    elseif cap == "func" or cap == "method" or cap == "anonymous_function" then
      function_node = node
    end
  end

  if not params then
    return nil
  end

  function_node = normalize_node(function_node)
  local is_nested = is_function_nested(function_node)

  local range
  if function_node then
    local start_row, start_col, end_row, end_col = function_node:range()
    range = { start_row, start_col, end_row, end_col }
    func_type = function_node:type()
  end

  return {
    type = func_type,
    name = name or "",
    params = params,
    return_type = ret,
    receiver = receiver,
    range = range,
    nested = is_nested,
    anonymous = name == nil or name == "",
  }
end

---@return table|nil
---@param match table
---@param query table
-- NOTE: python extractor
M.extractors.python = function(match, query)
  local name, params, function_node, return_type, func_type

  for i, cap in ipairs(query.captures) do
    local node = match[i]

    if cap == "name" then
      name = get_text(node)
    elseif cap == "params" then
      params = get_text(node)
    elseif cap == "func" then
      function_node = node
    elseif cap == "return" then
      return_type = get_text(node)
    end
  end

  function_node = normalize_node(function_node)
  local is_nested = is_function_nested(function_node)

  if not function_node then
    return nil
  end

  local range
  if function_node then
    local start_row, start_col, end_row, end_col = function_node:range()
    range = { start_row, start_col, end_row, end_col }
    func_type = function_node:type()
  end

  return {
    type = func_type,
    name = name or "",
    params = params or "()",
    return_type = return_type,
    receiver = nil, -- TODO: add receiver (class name, etc.)
    range = range,
    nested = is_nested,
    anonymous = name == nil or name == "",
  }
end

---@return table|nil
---@param match table
---@param query table
-- NOTE: JavaScript extractor
M.extractors.javascript = function(match, query)
  local name, params, function_node, func_type

  for i, cap in ipairs(query.captures) do
    local node = match[i]

    if cap == "name" then
      name = get_text(node)
    elseif cap == "params" then
      params = get_text(node)
    elseif cap == "func" then
      function_node = node
    end
  end

  function_node = normalize_node(function_node)
  local is_nested = is_function_nested(function_node)

  if not function_node then
    return nil
  end

  local range
  if function_node then
    local start_row, start_col, end_row, end_col = function_node:range()
    range = { start_row, start_col, end_row, end_col }
    func_type = function_node:type()
  end

  return {
    type = func_type,
    name = name or "",
    params = params or "()",
    return_type = nil,
    receiver = nil, -- TODO: add receiver (class name, etc.)
    range = range,
    nested = is_nested,
    anonymous = name == nil or name == "",
  }
end

-- ---------------------------------------------
-- ------------- core buffer logic -------------
-- ---------------------------------------------

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

---@return integer
function M.ensure_persistent_chat_window_setup()
  -- checking if valid buffer alreay exist
  if M.chat_buf and vim.api.nvim_buf_is_valid(M.chat_buf) then
    return M.chat_buf
  end

  -- create new scracth buffer
  M.chat_buf = vim.api.nvim_create_buf(false, true)

  -- set buffer options
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = M.chat_buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = M.chat_buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = M.chat_buf })
  vim.api.nvim_set_option_value("buflisted", true, { buf = M.chat_buf })
  vim.api.nvim_set_option_value("filetype", "chat", { buf = M.chat_buf })

  -- set first line
  if vim.api.nvim_buf_line_count(M.chat_buf) == 1 then
    vim.api.nvim_buf_set_lines(M.chat_buf, 0, -1, false, { "Chat session started" })
  end

  -- detecting window close with `:q` or other autocmd commands
  vim.api.nvim_create_autocmd("WinClosed", {
    group = M.groups.chat_session,
    buffer = M.chat_buf,
    callback = function(args)
      local closed_win = tonumber(args.match)
      if M.chat_win and closed_win == M.chat_win then
        vim.api.nvim_win_close(M.chat_win, true)
        M.chat_win = nil
        if M.prompt_buf then
          M.set_prompt_window_conf(#vim.api.nvim_buf_get_lines(M.prompt_buf, 0, -1, false))
        end
      end
    end,
  })

  return M.chat_buf
end

---@return nil
function M.toggle_persistent_chat_window()
  M.ensure_persistent_chat_window_setup()

  -- if already open -> close
  if M.chat_win and vim.api.nvim_buf_is_valid(M.chat_buf) then
    vim.api.nvim_win_close(M.chat_win, true)
    M.chat_win = nil
    if M.prompt_buf then
      M.set_prompt_window_conf(#vim.api.nvim_buf_get_lines(M.prompt_buf, 0, -1, false))
    end
    return
  end

  -- disabled key maps
  vim.keymap.set("v", "<Leader>8p", function()
    M.safe_notify("Disabled on chat window", vim.log.levels.INFO)
  end, { desc = "Open prompt window (Disabled)", buf = M.chat_buf })

  vim.keymap.set("v", "<Leader>8i", function()
    M.safe_notify("Disabled on chat window", vim.log.levels.INFO)
  end, { desc = "Complete implementation (Disabled)", buf = M.chat_buf })

  -- open new split
  vim.cmd("vsplit") -- or "split" for horizontal split window
  M.chat_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.chat_win, M.chat_buf)
  if M.prompt_buf then
    M.set_prompt_window_conf(#vim.api.nvim_buf_get_lines(M.prompt_buf, 0, -1, false))
  end
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
  local parent_width = vim.api.nvim_win_get_width(M.parent_win)
  local parent_height = vim.api.nvim_win_get_height(M.parent_win)

  -- your desired size
  local width = math.min(90, parent_width - 12)
  local height = math.min(60, parent_height - 8)
  local input_height = math.min(15, optional_prompt_win_height)
  local chat_height = height - input_height

  -- center position
  local col = math.floor((parent_width - width) / 2)
  local row = math.floor((parent_height - height) / 2)

  local history_win_conf = {
    relative = "win",
    win = M.parent_win,
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
    win = M.parent_win,
    row = row + chat_height + 2,
    col = col,
    width = width,
    height = input_height,
    style = "minimal",
    border = "rounded",
    title = " Enter Prompt ",
    title_pos = "center",
  }

  if M.prompt_win and M.prompt_history_win then -- set new sizes if windows already exist
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
    vim.cmd("startinsert")

    -- custom key maps - disabling key maps
    for _, buf in ipairs({ M.prompt_buf, M.prompt_history_buf }) do
      vim.keymap.set("v", "<Leader>8p", function()
        M.safe_notify("Disabled on prompt window", vim.log.levels.INFO)
      end, { desc = "Open prompt window (Disabled)", buf = buf })

      vim.keymap.set("v", "<Leader>8i", function()
        M.safe_notify("Disabled on prompt window", vim.log.levels.INFO)
      end, { desc = "Complete implementation (Disabled)", buf = buf })

      vim.keymap.set("n", "<Leader>8c", function()
        M.safe_notify("Disabled on prompt window", vim.log.levels.INFO)
      end, { desc = "Toggle persistent chat window (Disabled)", buf = buf })
    end

    -- custom key maps - switcing between prompt & history windows keymaps
    vim.keymap.set({ "n", "v" }, "<C-s>", function()
      vim.api.nvim_set_current_win(M.prompt_history_win)
    end, { buf = M.prompt_buf })

    vim.keymap.set({ "n", "v" }, "<C-s>", function()
      vim.api.nvim_set_current_win(M.prompt_win)
    end, { buf = M.prompt_history_buf })

    -- set auto commands
    for _, buf in ipairs({ M.prompt_buf, M.prompt_history_buf }) do
      vim.api.nvim_create_autocmd("WinEnter", {
        group = M.groups.prompt_session,
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
        group = M.groups.prompt_session,
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

      -- detecting window close with `:q` or other autocmd commands
      vim.api.nvim_create_autocmd("WinClosed", {
        group = M.groups.prompt_session,
        buffer = buf,
        callback = function(args)
          if M.prompt_win == tonumber(args.match) or M.prompt_history_win == tonumber(args.match) then
            vim.api.nvim_win_close(M.prompt_win, true)
            M.prompt_win = nil
            M.prompt_buf = nil
            vim.api.nvim_win_close(M.prompt_history_win, true)
            M.prompt_history_win = nil
            M.prompt_history_buf = nil
          end
        end,
      })
    end
    -- detecting text changes to resize prompt window when needed
    local timer
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = M.groups.prompt_session,
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
function M.open_prompt_window()
  M.parent_win = vim.api.nvim_get_current_win()
  -- Get selected lines
  local lines = M.get_visual_selection()
  if M.is_empty(lines) then
    M.safe_notify("Must select non-empty lines", vim.log.levels.WARN)
    vim.api.nvim_input("<Esc>") -- exit selection mode for better ux
    return
  end

  -- Create new prompt buffer
  M.prompt_history_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.prompt_history_buf].bufhidden = "wipe"
  vim.bo[M.prompt_history_buf].filetype = "markdown"
  vim.bo[M.prompt_history_buf].swapfile = false
  vim.api.nvim_buf_set_lines(M.prompt_history_buf, 0, 0, false, {
    "Prompt session started",
  })
  vim.bo[M.prompt_history_buf].modifiable = false

  M.prompt_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.prompt_buf].buftype = "prompt"
  vim.bo[M.prompt_buf].bufhidden = "wipe"
  vim.bo[M.prompt_buf].filetype = "markdown"
  vim.bo[M.prompt_buf].swapfile = false
  vim.fn.prompt_setprompt(M.prompt_buf, "")

  -- Set lines into new buffer
  local selected_text = M.tag_selected_text(table.concat(lines, "\n"))
  M.append_prompt_message(M.prompt_buf, selected_text)

  M.set_prompt_window_conf(#vim.split(selected_text, "\n", { plain = true }) + 1)

  -- callback when user presses Enter
  vim.fn.prompt_setcallback(M.prompt_buf, function()
    local prompt_lines = vim.api.nvim_buf_get_lines(M.prompt_buf, 0, -1, false)
    if M.is_empty(prompt_lines) then
      M.safe_notify("Write prompt first", vim.log.levels.WARN)
      vim.api.nvim_buf_set_lines(M.prompt_buf, 0, -1, false, {})
      return
    end
    if M.prompt_thinking then
      M.safe_notify("Wait for the previous prompt to finish", vim.log.levels.WARN)
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
---@param msg string
---@param lvl vim.log.levels
function M.safe_notify(msg, lvl)
  vim.schedule(function()
    vim.notify(msg, lvl)
  end)
end

---@return nil
---@param prompt string
---@param buf integer
---@param s_line integer
---@param e_line integer
---@param prompt_win boolean
function M.call_api(prompt, buf, s_line, e_line, prompt_win)
  -- safe encode
  local ok_encode, json = pcall(vim.json.encode, {
    contents = {
      parts = {
        text = prompt,
      },
    },
  })
  if not ok_encode then
    if prompt_win then
      M.append_message(buf, "Error", "JSON encode failed: " .. json)
    else
      M.safe_notify("JSON encode failed: " .. json, vim.log.levels.ERROR)
    end
    return
  end

  local lock_buf = M.unlock_buf(buf)
  local stop_spinner = M.start_spinner(buf, s_line)
  vim.system({
    "curl",
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent",
    "-H",
    "Content-Type: application/json",
    "-H",
    "x-goog-api-key: " .. M.api_key,
    "-X",
    "POST",
    "-d",
    json,
  }, { text = true }, function(res)
    ---@return nil
    ---@param ok boolean
    local function cleanup(ok)
      vim.schedule(function()
        stop_spinner(ok)
        lock_buf()
        M.start_line = nil
        M.end_line = nil
        vim.api.nvim_input("<Esc>") -- exiting visual mode
      end)
    end

    -- ensuring request success
    if res.code ~= 0 then
      cleanup(false)
      if prompt_win then
        M.append_message(buf, "Error", "Request failed: " .. (res.stderr or "unknown error"))
      else
        M.safe_notify("Request failed: " .. (res.stderr or "unknown error"), vim.log.levels.ERROR)
      end
      return
    end

    -- safe decode
    local ok_decode, data = pcall(vim.json.decode, res.stdout)
    if not ok_decode then
      cleanup(false)
      if prompt_win then
        M.append_message(buf, "Error", "JSON encode failed: " .. json)
      else
        M.safe_notify("JSON encode failed: " .. json, vim.log.levels.ERROR)
      end
      return
    end

    -- safe extract
    local text
    local ok_extract, err = pcall(function()
      text = data.candidates[1].content.parts[1].text
    end)
    if not ok_extract or not text then
      cleanup(false)
      if prompt_win then
        M.append_message(buf, "Error", "Invalid API response structure: " .. err)
      else
        M.safe_notify("Invalid API response structure: " .. err, vim.log.levels.ERROR)
      end
      return
    end

    cleanup(true)
    if prompt_win then
      M.append_message(buf, "Assistant", text)
    else
      local lines = vim.split(text, "\n")
      vim.schedule(function()
        vim.api.nvim_buf_set_lines(buf, s_line, e_line, false, lines)
      end)
    end
  end)
end

---@return nil
---@param buf integer
---@param role string
---@param text string
function M.append_message(buf, role, text)
  ---@return string
  local function build_header()
    local timestamp = os.date("%d-%m-%Y %H:%M:%S")
    local header = "❯ " .. role .. " | " .. timestamp
    return header
  end

  vim.schedule(function()
    local lock_buf = M.unlock_buf(buf)
    local total_lines, header, header_line
    local lines = vim.split(text, "\n", { plain = true })
    header = build_header()
    header_line = vim.api.nvim_buf_line_count(buf)
    total_lines = { header }

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

    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
      vim.api.nvim_win_set_cursor(win, {
        header_line + 1,
        0,
      })
    end
    lock_buf()
  end)
end

---@return nil
---@param buf integer
---@param text string|nil
function M.append_prompt_message(buf, text)
  vim.schedule(function()
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
  end)
end

---@return string
---@param text string
function M.tag_selected_text(text)
  return "```" .. vim.bo.filetype .. "\n" .. text .. "\n```"
end

---@return nil
function M.complete_implementation()
  if M.prompt_thinking then
    M.safe_notify("Wait for the previous prompt to finish", vim.log.levels.WARN)
    return
  end
  vim.api.nvim_input("<Esc>") -- exit selection mode for better ux
  local selected_lines = M.get_visual_selection()
  local func_data = M.get_func_ast_data(0)
  local func_signatures = M.get_func_signatures(func_data, true, true)
  local selected_text = M.tag_selected_text(table.concat(selected_lines, "\n"))
  local prompt = "Implement the following code.\n"
    .. "Respond with code only. Do NOT wrap the output in backticks.\n\n"
    .. "Code:\n"
    .. selected_text
    .. "\n\n"
    .. "Language: "
    .. vim.bo.filetype
    .. "\n\n"
    .. "Available function signatures:\n"
    .. table.concat(func_signatures, "\n")
    .. "\n\n"
    .. "If something looks incorrect (e.g., duplicate function signatures) or or if the task is unclear, do NOT implement the code.\n"
    .. "Instead, return a regular comment (under the code) explaining what should be changed."
  M.call_api(prompt, M.main_buf, M.start_line - 1, M.end_line + 1, false)
end

---@return nil
function M.send_prompt()
  if M.prompt_win then
    local win_buf_lines = vim.api.nvim_buf_get_lines(M.prompt_history_buf, 0, -1, false)
    local win_buf_text = table.concat(win_buf_lines, "\n")
    M.append_prompt_message(M.prompt_buf, nil)
    M.call_api(win_buf_text, M.prompt_history_buf, #win_buf_lines, -1, true)
  else
    M.safe_notify("chat.nvim: Select lines first", vim.log.levels.INFO)
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
