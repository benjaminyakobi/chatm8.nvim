local M = {}

function M.setup(opts)
  opts = opts or {}
  M.api_key = opts.api_key or ""
  local help = [[
  1. Select lines and <Leader>88 to open chat box window
  2. Prompt and <Leader>88 to apply changes and close the chat box window]]
  vim.keymap.set("n", "<Leader>8?", function()
    if opts.dev then
      print("chat.nvim: local setup\n" .. help)
    else
      print("chat.nvim: remote setup\n" .. help)
    end
  end, { desc = "Help" })

  vim.keymap.set("v", "<Leader>88", function()
    M.show_chat_box()
  end, { desc = "Open selected in chat box" })
  vim.keymap.set("n", "<Leader>88", M.close_chat_box, { desc = "Apply changes" })
end

function M.show_chat_box()
  -- Get selected lines
  M.main_buf = vim.api.nvim_get_current_buf()
  local lines = {}
  lines = M.get_visual_selection()

  -- Create new buffer
  local new_buf = vim.api.nvim_create_buf(false, true)

  -- Set lines into new buffer
  vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, lines)

  -- Calc window dimensions
  local width = math.min(80, vim.o.columns - 4)
  local height = math.min(10, vim.o.lines - 4)
  local row = math.floor((vim.o.lines - height) / 2)
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

function M.close_chat_box()
  if M.chat_win_id then
    local chat_buf = vim.api.nvim_win_get_buf(M.chat_win_id)
    vim.api.nvim_buf_set_lines(M.main_buf, M.start_line - 1, M.start_line - 1, false, { "Thinking..." })
    local win_buf_lines = vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)
    local win_buf_text = table.concat(win_buf_lines, "\n")
    local json = vim.json.encode({
      contents = {
        {
          parts = {
            {
              text = "Implement this code & Respond with code only, do not surround code with backticks (`)! ```"
                .. win_buf_text
                .. "```",
            },
          },
        },
      },
    })

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
      local data = vim.json.decode(res.stdout)
      local text = data.candidates[1].content.parts[1].text
      local lines = vim.split(text, "\n")
      vim.schedule(function()
        vim.api.nvim_buf_set_lines(chat_buf, 0, -1, false, lines)
        M.flush_to_buf(chat_buf, M.main_buf)
      end)
    end)
    vim.api.nvim_win_close(M.chat_win_id, true)
    M.chat_win_id = nil
  else
    print("chat.nvim: Select lines first")
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
  M.start_line = s_line
  M.end_line = e_line
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
