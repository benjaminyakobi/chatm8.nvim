local M = {}

---@return nil
---@param msg string
---@param lvl vim.log.levels
function M.safe_notify(msg, lvl)
  vim.schedule(function()
    vim.notify(msg, lvl)
  end)
end

---@return string
---@param text string
function M.tag_selected_text(text)
  return "```" .. vim.bo.filetype .. "\n" .. text .. "\n```"
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
---@param win integer
---@param buf integer
function M.scroll_to_bottom(win, buf)
  local line = vim.api.nvim_buf_line_count(buf)
  local last = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
  vim.api.nvim_win_set_cursor(win, { line, #last })
end

---@return nil
---@param prompt_win integer
---@param buf integer
-- NOTE: local function to disable mouse clicks outside the prompt window
function M.mouse_guard(prompt_win, buf)
  local function handle()
    local m = vim.fn.getmousepos()

    if m.winid ~= prompt_win then
      vim.api.nvim_set_current_win(prompt_win)
      return true
    end
    return false
  end

  local mouse_mappings = {
    "<LeftMouse>",
    "<RightMouse>",
    "<MiddleMouse>",
    "<LeftDrag>",
    "<LeftRelease>",
    "<ScrollWheelUp>",
    "<ScrollWheelDown>",
  }

  for _, key in ipairs(mouse_mappings) do
    vim.keymap.set({ "n", "i" }, key, function()
      handle()
    end, { silent = true, noremap = true, buf = buf })
  end
end

return M
