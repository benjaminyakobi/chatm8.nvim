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
