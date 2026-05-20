local Object = require "core.object"

---Abstract communication backend for assistant agents.
---
---Backends own transport, cancellation, provider turn execution, and any
---provider-specific continuation flow. Agents own payload parsing/building.
---@class assistant.Backend : core.object
---@field name string
---@field cancelled boolean
---@field active boolean
---@field super core.object
local Backend = Object:extend()

---Create a new instance.
---@param name string|nil
function Backend:new(name)
  self.name = name or "backend"
  self.cancelled = false
  self.active = false
end

---Request cancellation of the current provider operation.
function Backend:cancel()
  self.cancelled = true
end

---Return whether cancelled.
---@return boolean
function Backend:is_cancelled()
  return self.cancelled
end

---Mark a new provider request as active and clear cancellation state.
function Backend:begin_request()
  self.cancelled = false
  self.active = true
end

---Mark the current provider request as finished.
function Backend:finish_request()
  self.active = false
end

---Read ready.
---@return boolean
function Backend:ready()
  return false
end

---Handle prepare.
---@param agent assistant.Agent
---@param conversation assistant.Conversation
---@param callback fun(ok: boolean, err?: string)
function Backend:prepare(_, _, callback)
  if callback then callback(true) end
end

---Handle send.
---@param agent assistant.Agent
---@param conversation assistant.Conversation
---@param callback fun(ok: boolean, err?: string, text?: string, meta?: table)
function Backend:send(agent, conversation, callback)
  callback(false, "backend not implemented")
end

---List models.
---@param agent assistant.Agent
---@param callback fun(ok: boolean, err?: string, models?: string[])
function Backend:list_models(agent, callback)
  callback(false, "model listing not implemented")
end

---Compact compact.
---@param agent assistant.Agent
---@param conversation assistant.Conversation
---@param callback fun(ok: boolean, err?: string)
function Backend:compact(_, _, callback)
  callback(false, "conversation compaction not implemented")
end

---Handle local compact.
---@param agent assistant.Agent
---@param conversation assistant.Conversation
---@param callback fun(ok: boolean, err?: string)
function Backend:local_compact(_, _, callback)
  callback(false, "local conversation compaction not implemented")
end

---Delete conversation.
---@param agent assistant.Agent
---@param conversation assistant.Conversation
---@param callback fun(ok: boolean, err?: string)
function Backend:delete_conversation(_, _, callback)
  callback(false, "conversation deletion not implemented")
end

---List conversations.
---@param agent assistant.Agent
---@param project_dir string
---@param callback fun(ok: boolean, err?: string, conversations?: table[])
function Backend:list_conversations(_, _, callback)
  callback(false, "conversation listing not implemented")
end

---Handle restore conversation.
---@param agent assistant.Agent
---@param conversation assistant.Conversation
---@param callback fun(ok: boolean, err?: string)
function Backend:restore_conversation(_, _, callback)
  callback(false, "conversation restore not implemented")
end

---Handle rename conversation.
---@param agent assistant.Agent
---@param conversation assistant.Conversation
---@param title string
---@param callback fun(ok: boolean, err?: string)
function Backend:rename_conversation(_, _, _, callback)
  callback(false, "conversation rename not implemented")
end

---Handle generate conversation title.
---@param agent assistant.Agent
---@param conversation assistant.Conversation
---@param prompt string
---@param callback fun(ok: boolean, err?: string, title?: string)
function Backend:generate_conversation_title(_, _, _, callback)
  if callback then callback(false, "conversation title generation not implemented") end
end

---List collaboration modes.
---@param agent assistant.Agent
---@param callback fun(ok: boolean, err?: string, modes?: table[])
function Backend:list_collaboration_modes(agent, callback)
  callback(true, nil, agent:get_collaboration_modes())
end

---Resolve user input.
---@param agent assistant.Agent
---@param conversation assistant.Conversation
---@param request table
---@param ok boolean
---@param answers table|nil
---@param callback fun(ok: boolean, err?: string)
function Backend:resolve_user_input(_, _, _, _, _, callback)
  if callback then callback(false, "user input resolution not implemented") end
end

---Resolve approval.
---@param agent assistant.Agent
---@param conversation assistant.Conversation
---@param request table
---@param decision string
---@param callback fun(ok: boolean, err?: string)
function Backend:resolve_approval(_, _, _, _, callback)
  if callback then callback(false, "approval resolution not implemented") end
end

---Resolve tool call.
---@param agent assistant.Agent
---@param conversation assistant.Conversation
---@param request table
---@param decision string
---@param callback fun(ok: boolean, err?: string)
function Backend:resolve_tool_call(_, _, _, _, callback)
  if callback then callback(false, "tool call resolution not implemented") end
end

return Backend
