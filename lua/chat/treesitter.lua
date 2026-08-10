local M = {}

-- ------------------------------------------------
-- ---------- ast data extractor helpers ----------
-- ------------------------------------------------

local ts = vim.treesitter
local extractors = {}
local utils = require("chat.utils")

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

---@return table?, string?
---@param buf integer
---@param lang string
local function get_parser_root(buf, lang)
  local parser, err = ts.get_parser(buf, lang)
  if err then
    return nil, err
  end
  -- if parser == nil then
  --   return nil, "Parser not found for " .. lang
  -- end
  assert(parser ~= nil, "nil check failed on TSNode object")
  local tree = parser:parse()[1]
  return tree and tree:root(), nil
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

  if lang == "rust" then
    local sig
    sig = string.format("fn %s%s", item.name, item.params)
    if item.return_type then
      sig = sig .. " -> " .. item.return_type
    end
    if item.visibility then
      sig = item.visibility .. " " .. sig
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

  local root, err = get_parser_root(buf, lang)
  if err then
    utils.safe_notify(err, vim.log.levels.WARN)
    return {}
  end

  local query = ts.query.get(lang, "functions")
  if not query then
    utils.safe_notify("No query for " .. lang, vim.log.levels.WARN)
    return {}
  end

  local extractor = extractors[lang]
  if not extractor then
    utils.safe_notify("No extractor for " .. lang, vim.log.levels.WARN)
    return {}
  end

  local results = {}

  assert(root ~= nil, "nil check failed on TSNode object")
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
extractors.lua = function(match, query)
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
-- NOTE: Rust extractor
extractors.rust = function(match, query)
  local name, params, ret, receiver, function_node, func_type, visibility

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
    elseif cap == "visibility" then
      visibility = get_text(node)
    elseif cap == "func" or cap == "method" or cap == "closure" then
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
    visibility = visibility,
  }
end

---@return table|nil
---@param match table
---@param query table
-- NOTE: Go extractor
extractors.go = function(match, query)
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
extractors.python = function(match, query)
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
extractors.javascript = function(match, query)
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

return M
