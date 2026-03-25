local M = {}

function M.setup(opts)
  M.main_buf = vim.api.nvim_get_current_buf()
  opts = opts or {}
  M.api_key = opts.api_key or ""
  local help = [[
<Leader>88: Chat Interface
1. [Visual Mode] Select lines and press <Leader>88 to open the chat window.
2. [Chat Window] Type your request and press <Leader>88 to send the prompt.

<Leader>8i: Inline Implementation
1. [Visual Mode] Select text (either code snippets or natural language instructions).
2. Press <Leader>8i to automatically complete the implementation or transform 
   the selection directly in the current buffer.]]
  vim.keymap.set("n", "<Leader>8?", function()
    if opts.dev then
      print("chat.nvim: local setup\n" .. help)
      local func_data = M.get_func_ast_data(0)
      print(vim.inspect(func_data)) -- TODO: remove later
    else
      print("chat.nvim: remote setup\n" .. help)
    end
  end, { desc = "Help" })
  vim.keymap.set("v", "<Leader>8i", function()
    M.complete_implementation()
  end, { desc = "Complete implementation" })
  vim.keymap.set("v", "<Leader>88", function()
    M.show_chat_box()
  end, { desc = "Open selected in chat box" })
  vim.keymap.set("n", "<Leader>88", M.close_chat_box, { desc = "Apply changes" })
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

  local range
  if function_node then
    local start_row, start_col, end_row, end_col = function_node:range()
    range = { start_row, start_col, end_row, end_col }
  end

  return {
    name = name or "<anonymous>",
    params = params,
    range = range,
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
    vim.notify("No query for " .. lang, vim.log.levels.WARN)
    return {}
  end

  local extractor = extractors[lang]
  if not extractor then
    vim.notify("No extractor for " .. lang, vim.log.levels.WARN)
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

function M.show_chat_box()
  -- Get selected lines
  local lines = M.get_visual_selection()

  -- Create new buffer
  local new_buf = vim.api.nvim_create_buf(false, true)

  -- Set lines into new buffer
  vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, lines)

  -- Calc window dimensions
  local width = math.min(90, vim.o.columns - 12)
  local height = math.min(60, vim.o.lines - 6)
  local row = math.floor((vim.o.lines - height - 4) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  -- Open floating window
  M.chat_win_id = vim.api.nvim_open_win(new_buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Chat Box ",
    title_pos = "center",
  })

  vim.api.nvim_set_option_value("number", true, { win = M.chat_win_id })
end

function M.safe_notify(msg)
  vim.schedule(function()
    vim.notify(msg, vim.log.levels.ERROR)
  end)
end

function M.call_api(propmt, buf, s_line, e_line, win_chat)
  -- safe encode
  local ok_encode, json = pcall(vim.json.encode, {
    contents = {
      parts = {
        text = propmt,
      },
    },
  })
  if not ok_encode then
    M.safe_notify("JSON encode failed: " .. json)
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
      M.safe_notify("Request failed: " .. (res.stderr or "unknown error"))
      return
    end

    -- safe decode
    local ok_decode, data = pcall(vim.json.decode, res.stdout)
    if not ok_decode then
      cleanup(false)
      M.safe_notify("JSON encode failed: " .. json)
      return
    end

    -- safe extract
    local text
    local ok_extract, err = pcall(function()
      text = data.candidates[1].content.parts[1].text
    end)
    if not ok_extract or not text then
      cleanup(false)
      M.safe_notify("Invalid API response structure: " .. err)
      return
    end

    if win_chat then
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
  local selected_text = table.concat(selected_lines, "\n")
  local prompt = "Implement this code & Respond with code only, do not surround code with backticks (`)! ```"
    .. selected_text
    .. "```, filetype: "
    .. vim.bo.filetype
  M.call_api(prompt, M.main_buf, M.start_line - 1, M.end_line + 1, false)
end

function M.close_chat_box()
  if M.chat_win_id then
    local chat_buf = vim.api.nvim_win_get_buf(M.chat_win_id)
    local win_buf_lines = vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)
    local win_buf_text = table.concat(win_buf_lines, "\n")
    M.call_api(win_buf_text, chat_buf, #win_buf_lines, #win_buf_lines, true)
  else
    print("chat.nvim: Select lines first")
  end
end

function M.start_spinner(buf, s_line)
  local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  local spin_index = 1
  local timer = vim.uv.new_timer()
  local row = s_line
  local ns = vim.api.nvim_create_namespace("spinner")
  vim.api.nvim_buf_set_lines(buf, row, row, false, { "" })
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

function M.flush_to_buf(source_buf, target_buf)
  local win_buf_lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
  -- start_line-1 is inclusive and 0-indexed while user TUI is 1-index
  -- end_line is exclusive because of the 0-index property
  vim.api.nvim_buf_set_lines(target_buf, M.start_line - 1, M.end_line + 1, false, win_buf_lines)
  M.start_line = nil
  M.end_line = nil
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
