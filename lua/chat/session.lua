-- NOTE: this file manages chat sessions

local Session = {}

Session.__index = Session -- class

---@return metatable
function Session.new() -- constructor
  local ts = os.time()
  return setmetatable({
    id = ts,
    created_at = ts,
    updated_at = ts,
    title = "New Chat",
    messages = {},
  }, Session)
end

function Session:add(role, content)
  table.insert(self.messages, {
    role = role,
    content = content,
  })

  self.updated_at = os.time()
end

return Session
