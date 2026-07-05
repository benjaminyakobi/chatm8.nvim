-- NOTE: this file manages chat sessions

local SUMMARY_CHUNK_SIZE = 2

local SYSTEM_PROMPT = [[
You are a senior software engineer and technical mentor.

You write clean, practical, production-ready code and explain technical ideas clearly.

Your strengths include:
- software architecture and design
- backend engineering
- debugging and root-cause analysis
- performance optimization
- developer tooling
- APIs and integrations
- Neovim and editor plugin development
- Python, Lua, Go, JavaScript, and systems programming

When answering:
- prioritize correctness and practical solutions
- explain the reasoning behind decisions
- prefer simple and maintainable code over clever code
- point out trade-offs when multiple approaches exist
- include concrete code examples when useful
- keep explanations concise unless the user asks for detail
- preserve the user's coding style and existing architecture when possible
- avoid unnecessary rewrites

For debugging:
- identify the most likely root cause first
- mention edge cases and common pitfalls
- suggest the smallest useful fix before proposing larger refactors

For code review:
- focus on correctness, readability, maintainability, and performance
- be direct and constructive

Assume the user is an experienced developer and avoid over-explaining basics unless asked.

If something is ambiguous, state assumptions clearly and continue with the most practical answer.

Prefer answers that fit naturally into an editor workflow.
When showing code changes, keep them minimal and easy to paste into a file.
  ]]

---@class ChatMessage
---@field role string
---@field content string

---@class SummaryChunk
---@field start_idx integer
---@field end_idx integer
---@field content string

---@class Session
---@field id integer
---@field created_at integer
---@field updated_at integer
---@field title string
---@field messages ChatMessage[]
---@field summaries SummaryChunk[]
local Session = {}

Session.__index = Session

---@return Session
function Session.new() -- session class constructor
  local ts = os.time()

  ---@type Session
  local self = setmetatable({
    id = ts,
    created_at = ts,
    updated_at = ts,
    title = "New Chat",
    messages = {},
    summaries = {},
  }, Session)
  self:add("System", SYSTEM_PROMPT)

  return self
end

---@return table
---@param role string
---@param content string
function Session:pack(role, content)
  return {
    role = role,
    content = content,
  }
end

---@return nil
---@param role string
---@param content string
function Session:add(role, content)
  table.insert(self.messages, self:pack(role, content))

  self.updated_at = os.time()
end

---@return ChatMessage[]
function Session:get_messages()
  return vim.deepcopy(self.messages)
end

---@return ChatMessage[]
function Session:build_context()
  local context = {}

  -- Always keep the system prompt.
  table.insert(context, vim.deepcopy(self.messages[1]))

  -- Insert all completed summaries.
  for _, summary in ipairs(self.summaries) do
    table.insert(context, {
      role = "System",
      content = ("Summary of messages %d-%d:\n\n%s"):format(summary.start_idx, summary.end_idx, summary.content),
    })
  end

  -- Find the first message not covered by summaries.
  local first_unsummarized = 2

  if #self.summaries > 0 then
    first_unsummarized = self.summaries[#self.summaries].end_idx + 1
  end

  -- Append every unsummarized message.
  for i = first_unsummarized, #self.messages do
    table.insert(context, vim.deepcopy(self.messages[i]))
  end

  return context
end

---@return integer?, integer?
function Session:next_chunk_to_summarize()
  local start = 2

  if #self.summaries > 0 then
    start = self.summaries[#self.summaries].end_idx + 1
  end

  local finish = start + SUMMARY_CHUNK_SIZE - 1
  -- Only summarize complete chunks.
  if finish > #self.messages then
    return nil
  end

  return start, finish
end

---@param start_idx integer
---@param end_idx integer
---@param content string
function Session:add_summary(start_idx, end_idx, content)
  assert(start_idx <= end_idx, "Invalid summary range")

  local last = self.summaries[#self.summaries]

  if last then
    assert(start_idx == last.end_idx + 1, "Summary chunks must be contiguous")
  end

  table.insert(self.summaries, {
    start_idx = start_idx,
    end_idx = end_idx,
    content = content,
  })

  self.updated_at = os.time()
end

return Session
