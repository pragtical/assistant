---Declarative assistant tool specification.
---
---Tool modules create `Tool` instances and the registry asks each instance for
---the concrete registration table to expose on an agent.
---@class assistant.Tool
---@field name string
---@field callback function|nil
---@field build fun(self: assistant.Tool, agent: assistant.Agent, facade: table): assistant.Tool.registration|nil
---@field description string|nil
---@field params table[]|nil
---@field read_only boolean|nil
---@field requires_approval function|nil
---@field compact_result function|nil
---@field compact_provider_call function|nil
---@field compact_history function|nil
---@field result_is_successful function|nil
---@field additional_properties boolean|nil
---@field new fun(self: assistant.Tool, spec: table): assistant.Tool
---
---@class assistant.Tool.registration
---@field callback function
---@field description string|nil
---@field params table[]|nil
---@field read_only boolean|nil
---@field requires_approval function|nil
---@field compact_result function|nil
---@field compact_provider_call function|nil
---@field compact_history function|nil
---@field result_is_successful function|nil
---@field additional_properties boolean|nil
local json = require "core.json"
local jsonutil = require "plugins.assistant.jsonutil"
local history_normalizer = require "plugins.assistant.history_normalizer"

local Tool = {}
Tool.__index = Tool

Tool.ARGUMENT_STRING_LIMIT = 2048
Tool.RESULT_CONTENT_LIMIT = 48000
Tool.RESULT_HEAD_LIMIT = 32000
Tool.RESULT_TAIL_LIMIT = 8000

Tool.LARGE_ARGUMENT_KEYS = {
  content = true,
  contents = true,
  file_content = true,
  new_content = true,
  patch = true,
  text = true
}

---Clone a table recursively.
---@param value any
---@return any
function Tool.clone_table(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for key, item in pairs(value) do
    copy[key] = Tool.clone_table(item)
  end
  return copy
end

---Compact long text for provider context.
---@param text any
---@param limit integer|nil
---@return string
function Tool.compact_long_text(text, limit)
  text = tostring(text or "")
  limit = limit or Tool.RESULT_CONTENT_LIMIT
  if #text <= limit then return text end
  local omitted = #text - Tool.RESULT_HEAD_LIMIT - Tool.RESULT_TAIL_LIMIT
  if omitted < 0 then omitted = #text - limit end
  return table.concat({
    text:sub(1, Tool.RESULT_HEAD_LIMIT),
    "",
    string.format("... omitted %d bytes from prior tool result ...", math.max(0, omitted)),
    "",
    text:sub(-Tool.RESULT_TAIL_LIMIT)
  }, "\n")
end

---Compact large JSON argument string values.
---@param arguments string|nil
---@return string|nil
function Tool.compact_arguments(arguments)
  local ok, decoded = pcall(json.decode, arguments or "")
  if not ok then return arguments end
  if type(decoded) ~= "table" then return arguments end
  local changed = false
  local compacted = Tool.clone_table(decoded)
  local function visit(tbl)
    for key, value in pairs(tbl) do
      if type(value) == "table" then
        visit(value)
      elseif type(value) == "string" then
        local key_name = tostring(key)
        if Tool.LARGE_ARGUMENT_KEYS[key_name] or #value > Tool.ARGUMENT_STRING_LIMIT then
          tbl[key] = string.format("[omitted %d bytes from prior tool argument `%s`]", #value, key_name)
          changed = true
        end
      end
    end
  end
  visit(compacted)
  return changed and jsonutil.encode(compacted) or arguments
end

---Return whether a provider tool call already contains omitted arguments.
---@param call table
---@return boolean
function Tool.call_has_omitted_arguments(call)
  local fn = type(call) == "table" and type(call["function"]) == "table" and call["function"] or nil
  local arguments = fn and fn.arguments or type(call) == "table" and call.arguments or nil
  if type(arguments) ~= "string" then return false end
  local ok, decoded = pcall(json.decode, arguments)
  if not ok or type(decoded) ~= "table" then return false end
  return history_normalizer.contains_omitted_tool_argument(decoded)
end

---Compact one provider tool/function call.
---@param call table
---@return table
function Tool:compact_provider_call(call)
  local copy = Tool.clone_table(call)
  local fn = type(copy) == "table" and type(copy["function"]) == "table" and copy["function"] or nil
  if fn and type(fn.arguments) == "string" and not Tool.call_has_omitted_arguments(copy) then
    fn.arguments = Tool.compact_arguments(fn.arguments)
  elseif type(copy) == "table" and copy.type == "function_call"
    and type(copy.arguments) == "string"
    and not Tool.call_has_omitted_arguments(copy)
  then
    copy.arguments = Tool.compact_arguments(copy.arguments)
  end
  return copy
end

---Compact one provider tool result.
---@param _ table|nil
---@param result any
---@return string
function Tool:compact_result(_, result)
  return Tool.compact_long_text(result, Tool.RESULT_CONTENT_LIMIT)
end

---Return whether a tool result represents a successful historical operation.
---@return boolean
function Tool:result_is_successful()
  return false
end

---Create a new instance.
---@param spec table
---@return assistant.Tool
function Tool:new(spec)
  spec = spec or {}
  if not spec.name or spec.name == "" then
    error("tool spec requires a name")
  end
  if not spec.callback and not spec.build then
    error("tool spec requires a callback or build function: " .. tostring(spec.name))
  end
  return setmetatable(spec, self)
end

---Handle registration.
---@param agent assistant.Agent
---@param facade table
---@return assistant.Tool.registration
function Tool:registration(agent, facade)
  local registration = self.build and self:build(agent, facade) or {}
  for key, value in pairs(self) do
    if key ~= "name" and key ~= "build" then
      registration[key] = value
    end
  end
  registration.name = registration.name or self.name
  registration.compact_result = registration.compact_result or function(call, result, context)
    return Tool.compact_result(registration, call, result, context)
  end
  registration.compact_provider_call = registration.compact_provider_call or function(call, context)
    return Tool.compact_provider_call(registration, call, context)
  end
  registration.result_is_successful = registration.result_is_successful or function(call, result_message, context)
    return Tool.result_is_successful(registration, call, result_message, context)
  end
  return registration
end

---Handle register.
---@param agent assistant.Agent
---@param facade table
---@return any
function Tool:register(agent, facade)
  return agent:register_tool(self.name, self:registration(agent, facade))
end

return Tool
