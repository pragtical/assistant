local jsonutil = require "plugins.assistant.jsonutil"

---Provider-history repair utilities.
---
---These functions keep tool-call ordering valid for chat-completions and
---OpenAI Responses histories, especially after cancellation or compaction.
---@class assistant.history_normalizer
local normalizer = {}

---Handle clone.
local function clone(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do
    result[key] = clone(item)
  end
  return result
end

---Handle assistant tool call ids.
local function assistant_tool_call_ids(message)
  local ids = {}
  if type(message) ~= "table" or type(message.tool_calls) ~= "table" then return ids end
  for _, call in ipairs(message.tool_calls) do
    local id = type(call) == "table" and call.id
    if id and id ~= "" then table.insert(ids, tostring(id)) end
  end
  return ids
end

---Return whether tool output is available.
local function has_tool_output(messages, call_id)
  for _, message in ipairs(messages) do
    if type(message) == "table"
      and message.role == "tool"
      and tostring(message.tool_call_id or "") == tostring(call_id)
    then
      return true
    end
  end
  return false
end

---Handle pending call ids.
local function pending_call_ids(messages)
  local pending = {}
  for _, message in ipairs(messages) do
    if type(message) == "table" and type(message.tool_calls) == "table" then
      for _, call_id in ipairs(assistant_tool_call_ids(message)) do
        pending[call_id] = true
      end
    elseif type(message) == "table" and message.role == "tool" then
      local call_id = tostring(message.tool_call_id or "")
      if call_id ~= "" then pending[call_id] = nil end
    end
  end
  return pending
end

---Handle aborted tool message.
local function aborted_tool_message(call_id)
  return {
    role = "tool",
    tool_call_id = call_id,
    content = "Tool call did not complete; it was aborted before a result was recorded."
  }
end

---Normalize chat messages.
---@param messages table[]
---@return table[] messages
function normalizer.normalize_chat_messages(messages)
  local output = {}
  local known_calls = {}
  for _, message in ipairs(messages or {}) do
    if type(message) == "table" then
      if type(message.tool_calls) == "table" then
        local copy = clone(message)
        table.insert(output, copy)
        for _, call_id in ipairs(assistant_tool_call_ids(copy)) do
          known_calls[call_id] = true
        end
      elseif message.role == "tool" then
        local call_id = tostring(message.tool_call_id or "")
        if call_id ~= "" and known_calls[call_id] then
          table.insert(output, clone(message))
        end
      else
        table.insert(output, clone(message))
      end
    end
  end

  local missing = pending_call_ids(output)
  if next(missing) then
    local repaired = {}
    for _, message in ipairs(output) do
      table.insert(repaired, message)
      for _, call_id in ipairs(assistant_tool_call_ids(message)) do
        if missing[call_id] and not has_tool_output(output, call_id) then
          table.insert(repaired, aborted_tool_message(call_id))
        end
      end
    end
    output = repaired
  end
  return output
end

---Handle response call id.
local function response_call_id(item)
  return tostring(item and (item.call_id or item.id) or "")
end

---Handle response output id.
local function response_output_id(item)
  return tostring(item and item.call_id or "")
end

---Normalize response items.
---@param items table[]
---@return table[] items
function normalizer.normalize_response_items(items)
  local output = {}
  local known_calls = {}
  for _, item in ipairs(items or {}) do
    if type(item) == "table" then
      if item.type == "function_call" then
        local copy = clone(item)
        table.insert(output, copy)
        local call_id = response_call_id(copy)
        if call_id ~= "" then known_calls[call_id] = true end
      elseif item.type == "function_call_output" then
        local call_id = response_output_id(item)
        if call_id ~= "" and known_calls[call_id] then
          table.insert(output, clone(item))
        end
      else
        table.insert(output, clone(item))
      end
    end
  end

  local seen_outputs = {}
  for _, item in ipairs(output) do
    if type(item) == "table" and item.type == "function_call_output" then
      local call_id = response_output_id(item)
      if call_id ~= "" then seen_outputs[call_id] = true end
    end
  end

  local repaired = {}
  for _, item in ipairs(output) do
    table.insert(repaired, item)
    if type(item) == "table" and item.type == "function_call" then
      local call_id = response_call_id(item)
      if call_id ~= "" and not seen_outputs[call_id] then
        table.insert(repaired, {
          type = "function_call_output",
          call_id = call_id,
          output = "Tool call did not complete; it was aborted before a result was recorded."
        })
      end
    end
  end
  return repaired
end

local PLACEHOLDER_PATTERN = "^%[omitted %d+ bytes from prior tool argument `[^`]+`%]$"

---Return whether omitted tool argument.
---@param value any
---@return boolean
function normalizer.is_omitted_tool_argument(value)
  return type(value) == "string" and value:match(PLACEHOLDER_PATTERN) ~= nil
end

---Return whether summary arguments.
local function is_summary_arguments(value)
  return type(value) == "table"
    and type(value.prior_tool_call_summary) == "string"
    and value.omitted_content_bytes ~= nil
end

---Handle contains omitted tool argument.
---@param value any
---@return boolean
function normalizer.contains_omitted_tool_argument(value)
  if normalizer.is_omitted_tool_argument(value) then return true end
  if is_summary_arguments(value) then return true end
  if type(value) ~= "table" then return false end
  for _, item in pairs(value) do
    if normalizer.contains_omitted_tool_argument(item) then return true end
  end
  return false
end

---Handle encode summary arguments.
---@param call_name string
---@param arguments table
---@return string
function normalizer.encode_summary_arguments(call_name, arguments)
  arguments = type(arguments) == "table" and arguments or {}
  local path = arguments.path or arguments.file or arguments.filename
  local bytes = 0
  for _, key in ipairs({ "contents", "content", "file_content", "new_content", "patch", "text" }) do
    if type(arguments[key]) == "string" and #arguments[key] > bytes then
      bytes = #arguments[key]
    end
  end
  return jsonutil.encode({
    prior_tool_call_summary = string.format(
      "Historical `%s` call had large content omitted from provider history.",
      tostring(call_name or "tool")
    ),
    path = path,
    omitted_content_bytes = bytes > 0 and bytes or nil
  })
end

return normalizer
