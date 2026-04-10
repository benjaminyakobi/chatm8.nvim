local M = { chat_buf = nil, prompt_buf = nil }

function M.setup(opts)
  M.main_buf = vim.api.nvim_get_current_buf()
  opts = opts or {}
  M.api_key = opts.api_key or ""
  local help = [[
<Leader>8p: Prompt Interface
1. [Visual Mode] Select text (either code snippets or natural language instructions) and press <Leader>8p to open the prompt window.
2. [Prompt Window] Type your prompt and press <Leader>8p to send the prompt.

<Leader>8i: Inline Implementation
1. [Visual Mode] Select text (either code snippets or natural language instructions).
2. Press <Leader>8i to automatically complete the implementation or transform 
   the selection directly in the current buffer.

<Leader>8c: Persistent Chat
1. [Normal/Visual Mode] Press `<Leader>8c` to toggle a persistent chat window in a split view.
2. [Chat Window] Maintain a continuous, multi-turn conversation with the model that persists across different files and buffers.]]

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
end

-- ---------- ast data extractor helpers ----------

local ts = vim.treesitter

local function get_text(node)
  if type(node) == "table" then
    node = node[1]
  end
  if not node then
    return nil
  end
  return ts.get_node_text(node, 0)
end

local function get_parser_root(buf, lang)
  local parser = ts.get_parser(buf, lang)
  if not parser then
    return
  end
  local tree = parser:parse()[1]
  return tree and tree:root()
end

local function normalize_node(node)
  if type(node) == "table" then
    return node[1]
  end
  return node
end

local function build_signature(lang, item)
  if lang == "lua" then
    return string.format("function %s%s", item.name, item.params)
  end

  if lang == "go" then
    local sig

    if item.receiver then
      sig = string.format("func %s %s%s", item.receiver, item.name, item.params)
    else
      sig = string.format("func %s%s", item.name, item.params)
    end

    if item.return_type then
      sig = sig .. " " .. item.return_type
    end

    return sig
  end

  if lang == "python" then
    local sig = string.format("def %s%s", item.name, item.params)
    if item.receiver then
      sig = string.format("def %s %s%s", item.receiver, item.name, item.params)
    else
      sig = string.format("def %s%s", item.name, item.params)
    end

    if item.receiver then
      sig = item.receiver .. "." .. sig
    end

    if item.return_type then
      sig = sig .. " -> " .. item.return_type
    end

    return sig
  end

  if lang == "javascript" then
    local sig = string.format("function %s%s", item.name, item.params)
    return sig
  end
end

local function is_function_node(node)
  if not node then
    return false
  end
  local t = node:type()

  return t == "function_declaration"
    or t == "function_definition" -- Lua
    or t == "method_decleration" -- Go
    or t == "func_literal" -- Go
end

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

function M.get_func_signatures(func_data, nested)
  local signatures = {}
  for _, item in ipairs(func_data) do
    if item.nested == nested then
      table.insert(signatures, item.signature)
    end
  end
  return signatures
end

-- ---------- ast data extractors ----------

local extractors = {}

-- NOTE: Lua extractor
extractors.lua = function(match, query)
  local name, params, function_node

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
  end

  return {
    name = name or "<anonymous>",
    params = params,
    range = range,
    nested = is_nested,
  }
end

-- NOTE: Go extractor
extractors.go = function(match, query)
  local name, params, ret, receiver, function_node

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
  end

  return {
    name = name or "<anonymous>",
    params = params,
    return_type = ret,
    receiver = receiver,
    range = range,
    nested = is_nested,
  }
end

-- NOTE: python extractor
extractors.python = function(match, query)
  local name, params, function_node, return_type
  local kind = "function"

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

  -- Detect lambda
  if function_node:type() == "lambda" then
    kind = "anonymous"
  end

  -- Range
  local range
  if function_node then
    local start_row, start_col, end_row, end_col = function_node:range()
    range = { start_row, start_col, end_row, end_col }
  end

  return {
    name = name or "<anonymous>",
    params = params or "()",
    return_type = return_type,
    receiver = nil, -- TODO: add receiver (class name, etc.)
    kind = kind,
    range = range,
    nested = is_nested,
  }
end

-- NOTE: JavaScript extractor
extractors.javascript = function(match, query)
  local name, params, function_node
  local kind = "function"

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

  local node_type = function_node:type()

  -- Detect function kind
  if node_type == "arrow_function" then
    kind = "anonymous"
  elseif node_type == "method_definition" then
    kind = "method"
  elseif node_type == "function_expression" and not name then
    kind = "anonymous"
  end

  -- Range
  local range
  if function_node then
    local start_row, start_col, end_row, end_col = function_node:range()
    range = { start_row, start_col, end_row, end_col }
  end

  return {
    name = name or "<anonymous>",
    params = params or "()",
    return_type = nil,
    receiver = nil, -- TODO: add receiver (class name, etc.)
    kind = kind,
    range = range,
    nested = is_nested,
  }
end

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

  local extractor = extractors[lang]
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
    callback = function(args)
      local closed_win = tonumber(args.match)
      if M.chat_win and closed_win == M.chat_win then
        M.chat_win = nil
      end
    end,
  })

  return M.chat_buf
end

function M.toggle_persistent_chat_window()
  M.ensure_persistent_chat_window_setup()

  -- if already open -> close
  if M.chat_win and vim.api.nvim_buf_is_valid(M.chat_buf) then
    vim.api.nvim_win_close(M.chat_win, true)
    M.chat_win = nil
    M.set_prompt_window_conf()
    return
  end

  -- open new split
  vim.cmd("vsplit") -- or "split"
  M.chat_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.chat_win, M.chat_buf)
  M.set_prompt_window_conf()
end

function M.set_prompt_window_conf()
  if M.prompt_buf == nil then
    return
  end
  -- parent size
  local parent_width = vim.api.nvim_win_get_width(M.parent_win)
  local parent_height = vim.api.nvim_win_get_height(M.parent_win)

  -- your desired size
  local width = math.min(90, parent_width - 12)
  local height = math.min(60, parent_height - 6)

  -- center position
  local col = math.floor((parent_width - width) / 2)
  local row = math.floor((parent_height - height) / 2)
  local win_conf = {
    relative = "win",
    win = M.parent_win,
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Chat Box ",
    title_pos = "center",
  }
  if M.prompt_win then
    vim.api.nvim_win_set_config(M.prompt_win, win_conf)
  else
    M.prompt_win = vim.api.nvim_open_win(M.prompt_buf, true, win_conf)
  end
end

function M.open_prompt_window()
  M.parent_win = vim.api.nvim_get_current_win()
  -- Get selected lines
  local lines = M.get_visual_selection()

  -- Create new prompt buffer
  M.prompt_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.prompt_buf].buftype = "prompt"
  vim.bo[M.prompt_buf].bufhidden = "wipe"
  vim.bo[M.prompt_buf].swapfile = false
  vim.fn.prompt_setprompt(M.prompt_buf, "❯ ")

  -- Set lines into new buffer
  vim.api.nvim_buf_set_lines(M.prompt_buf, 0, -1, false, lines)

  M.set_prompt_window_conf()

  vim.api.nvim_set_option_value("number", true, { win = M.prompt_win })

  -- callback when user presses Enter
  vim.fn.prompt_setcallback(M.prompt_buf, function()
    M.send_prompt()
  end)

  -- start insert mode automatically
  vim.cmd("startinsert")

  -- block escape leaving insert
  vim.keymap.set("i", "<C-c>", "<Nop>", { buffer = M.prompt_buf })
  vim.keymap.set("i", "<C-[>", "<Nop>", { buffer = M.prompt_buf })

  -- detecting window close with `:q` or other autocmd commands
  vim.api.nvim_create_autocmd("WinClosed", {
    callback = function(args)
      local closed_win = tonumber(args.match)
      if M.prompt_win and closed_win == M.prompt_win then
        M.prompt_win = nil
        vim.api.nvim_buf_delete(M.prompt_buf, { force = false })
        M.prompt_buf = nil
      end
    end,
  })
end

function M.safe_notify(msg, lvl)
  vim.schedule(function()
    vim.notify(msg, lvl)
  end)
end

function M.call_api(propmt, buf, s_line, e_line, prompt_win)
  -- safe encode
  local ok_encode, json = pcall(vim.json.encode, {
    contents = {
      parts = {
        text = propmt,
      },
    },
  })
  if not ok_encode then
    M.safe_notify("JSON encode failed: " .. json, vim.log.levels.ERROR)
    return
  end

  local timer, ns = M.start_spinner(buf, s_line)
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
    local function cleanup(ok)
      vim.schedule(function()
        M.stop_spinner(buf, timer, ns, M.mark_id)
        M.start_line = nil
        M.end_line = nil
        vim.api.nvim_input("<Esc>") -- exiting visual mode
        if not ok then
          -- removing spinner row
          vim.api.nvim_buf_set_lines(buf, s_line, s_line + 1, false, {})
        end
      end)
    end

    -- ensuring request success
    if res.code ~= 0 then
      cleanup(false)
      M.safe_notify("Request failed: " .. (res.stderr or "unknown error"), vim.log.levels.ERROR)
      return
    end

    -- safe decode
    local ok_decode, data = pcall(vim.json.decode, res.stdout)
    if not ok_decode then
      cleanup(false)
      M.safe_notify("JSON encode failed: " .. json, vim.log.levels.ERROR)
      return
    end

    -- safe extract
    local text
    local ok_extract, err = pcall(function()
      text = data.candidates[1].content.parts[1].text
    end)
    if not ok_extract or not text then
      cleanup(false)
      M.safe_notify("Invalid API response structure: " .. err, vim.log.levels.ERROR)
      return
    end

    if prompt_win then
      text = "\nResponse:\n" .. text
    end
    local lines = vim.split(text, "\n")
    vim.schedule(function()
      cleanup(true)
      vim.api.nvim_buf_set_lines(buf, s_line, e_line, false, lines)
    end)
  end)
end

function M.complete_implementation()
  local selected_lines = M.get_visual_selection()
  local func_data = M.get_func_ast_data(0)
  local func_signatures = M.get_func_signatures(func_data, false)
  local selected_text = table.concat(selected_lines, "\n")
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

function M.send_prompt()
  if M.prompt_win then
    local win_buf_lines = vim.api.nvim_buf_get_lines(M.prompt_buf, 0, -1, false)
    local win_buf_text = table.concat(win_buf_lines, "\n")
    M.call_api(win_buf_text, M.prompt_buf, #win_buf_lines, #win_buf_lines, true)
  else
    print("chat.nvim: Select lines first")
  end
end

function M.start_spinner(buf, row)
  local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  local spin_index = 1
  local ns = vim.api.nvim_create_namespace("spinner")
  vim.api.nvim_buf_set_lines(buf, row, row, false, { "" })
  local timer = vim.uv.new_timer()
  if not timer then
    return nil, ns
  end
  timer:start(
    0,
    100,
    vim.schedule_wrap(function()
      local frame = spinner[spin_index]

      M.mark_id = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
        id = M.mark_id, -- reuse same extmark
        virt_text = { { "Thinking " .. frame, "Comment" } },
        virt_text_pos = "eol",
      })

      spin_index = spin_index % #spinner + 1
    end)
  )
  return timer, ns
end

function M.stop_spinner(buf, timer, ns, mark)
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end

  if mark then
    vim.api.nvim_buf_del_extmark(buf, ns, mark)
    mark = nil
  end
end

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
