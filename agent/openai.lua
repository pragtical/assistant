local common = require "core.common"
local history_normalizer = require "plugins.assistant.history_normalizer"
local Agent = require "plugins.assistant.agent"

---OpenAI Responses API agent.
---@class assistant.agent.OpenAI : assistant.Agent
local OpenAI = Agent:extend()

---Create a new instance.
---@param options table|nil
function OpenAI:new(options)
  options = options or {}
  options.name = options.name or "openai"
  options.display_name = options.display_name or "OpenAI"
  options.backend = options.backend or "http"
  options.base_url = options.base_url or "https://api.openai.com"
  options.endpoint = options.endpoint or "/v1/responses"
  options.models_endpoint = options.models_endpoint or "/v1/models"
  options.api_format = options.api_format or "responses"
  options.model = options.model or "gpt-4.1"
  options.api_key_env = options.api_key_env or "OPENAI_API_KEY"
  options.model_metadata = common.merge({
    preferred_timeout_ms = 300000,
    context_window = 1047576,
    stream_tool_calls = true,
    parallel_tool_calls = false,
    reports_usage = true
  }, options.model_metadata)
  options.capabilities = common.merge({
    reports_usage = true,
    collaboration_modes = true,
    stream_responses = true,
    tool_calling = true,
    local_compact = true,
    vision = true
  }, options.capabilities)
  self.super.new(self, options)
end

---Handle response content from message.
local function response_content_from_message(message)
  local content = message and message.content
  if type(content) == "string" then return content end
  if type(content) ~= "table" then return nil end
  local parts = {}
  for _, item in ipairs(content) do
    if type(item) == "table" then
      table.insert(parts, item.text or item.value or "")
    elseif type(item) == "string" then
      table.insert(parts, item)
    end
  end
  return table.concat(parts)
end

---Handle response arguments text.
local function response_arguments_text(call)
  local json = require "core.json"
  local text = call and call.arguments_text
  if type(text) == "string" and text ~= "" and type(json.decode(text)) == "table" then
    return text
  end
  return json.encode(call and call.arguments or {})
end

---Build payload.
---@param conversation assistant.Conversation
---@return table payload
function OpenAI:build_payload(conversation)
  local max_tokens = self:generation_budget(conversation)
  local input = {}
  local instructions = nil
  local provider_messages = history_normalizer.normalize_response_items(
    self:provider_messages_for_conversation(conversation)
  )
  for _, message in ipairs(provider_messages) do
    if message.role == "system" then
      instructions = instructions
        and (instructions .. "\n\n" .. (message.content or ""))
        or (message.content or "")
    else
      table.insert(input, message)
    end
  end
  local payload = {
    model = self.model,
    input = input,
    instructions = instructions,
    stream = self.stream,
    temperature = self.options.temperature,
    top_p = self.options.top_p_sampling
  }
  local tools = self:has_capability("tool_calling")
    and self:generate_tools_info(self:tool_names_for_mode(conversation))
  if tools then payload.tools = tools end
  local reasoning_effort = self:configured_reasoning_effort()
  if reasoning_effort then payload.reasoning = { effort = reasoning_effort } end
  if max_tokens then payload[self:generation_budget_field()] = max_tokens end
  return payload
end

---Build compact payload.
---@param conversation assistant.Conversation
---@return table payload
function OpenAI:build_compact_payload(conversation)
  local max_tokens = self:generation_budget(conversation)
  local payload = {
    model = self.model,
    input = {
      {
        role = "user",
        content = self:get_compact_prompt(conversation:to_markdown())
      }
    },
    instructions = "You summarize coding assistant conversations so future turns can continue with enough context.",
    stream = false,
    temperature = 0.1,
    top_p = self.options.top_p_sampling
  }
  local reasoning_effort = self:configured_reasoning_effort()
  if reasoning_effort then payload.reasoning = { effort = reasoning_effort } end
  if max_tokens then payload[self:generation_budget_field()] = max_tokens end
  return payload
end

---Build title payload.
---@param prompt string
---@return table payload
function OpenAI:build_title_payload(prompt)
  return {
    model = self.model,
    input = {
      {
        role = "user",
        content = tostring(prompt or "")
      }
    },
    instructions = table.concat({
      "Generate a concise title for this coding conversation.",
      "Base the title only on the user's first prompt.",
      "Return only the title text.",
      "Use 3 to 8 words.",
      "Do not use quotes, Markdown, punctuation at the end, or explanatory text."
    }, "\n"),
    stream = false,
    temperature = 0.1,
    top_p = self.options.top_p_sampling,
    max_output_tokens = 32
  }
end

---Return the provider request field used for output token limits.
---@return string field
function OpenAI:generation_budget_field()
  if self.api_format == "responses" then return "max_output_tokens" end
  return "max_completion_tokens"
end

---Handle generate tools info.
---@param selected string[]|nil
---@return table[]|nil tools
function OpenAI:generate_tools_info(selected)
  local result = {}
  local names = {}
  if type(selected) == "table" then
    for _, name in ipairs(selected) do
      if self.tools[name] then table.insert(names, name) end
    end
  else
    for name in pairs(self.tools) do table.insert(names, name) end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local tool = self.tools[name]
    table.insert(result, {
      type = "function",
      name = name,
      description = tool.description or "",
      parameters = self:tool_parameters_schema(tool)
    })
  end
  return #result > 0 and result or nil
end

---Parse response.
---@param result table|string|nil
---@return string
function OpenAI:parse_response(result)
  if type(result) ~= "table" then return tostring(result or "") end
  if result.output_text then return result.output_text end
  local output = result.output
  if type(output) == "table" then
    local parts = {}
    for _, item in ipairs(output) do
      if type(item) == "table" and item.type == "message" then
        table.insert(parts, response_content_from_message(item))
      elseif type(item) == "table" and (item.text or item.content) then
        table.insert(parts, item.text or response_content_from_message(item))
      end
    end
    if #parts > 0 then return table.concat(parts) end
  end
  return OpenAI.super.parse_response(self, result)
end

---Parse tool calls.
---@param result table|nil
---@return table[] calls
function OpenAI:parse_tool_calls(result)
  if type(result) ~= "table" then return {} end
  local calls = {}
  for _, item in ipairs(result.output or {}) do
    if type(item) == "table" and item.type == "function_call" and item.name then
      local args = {}
      local args_text = item.arguments or ""
      if type(args_text) == "string" then
        local decoded = require("core.json").decode(args_text)
        if type(decoded) == "table" then args = decoded end
      elseif type(args_text) == "table" then
        args = args_text
        args_text = require("core.json").encode(args_text)
      end
      table.insert(calls, {
        id = item.id,
        call_id = item.call_id,
        name = item.name,
        arguments = args,
        arguments_text = args_text,
        format = "responses",
        raw = item
      })
    end
  end
  return calls
end

---Handle tool call provider message.
---@param calls table[]
---@param index integer|nil
---@return table|nil
function OpenAI:tool_call_provider_message(calls, index)
  local call = (calls or {})[index or 1]
  if not call then return nil end
  return {
    type = "function_call",
    id = call.id,
    call_id = call.call_id or call.id,
    name = call.name,
    arguments = response_arguments_text(call)
  }
end

---Handle tool result provider message.
---@param call table
---@param result any
---@param options table|nil
---@return table
function OpenAI:tool_result_provider_message(call, result, options)
  local compact = not (options and options.compact == false)
  return {
    type = "function_call_output",
    call_id = call.call_id or call.id,
    output = compact and self:compact_tool_result(call, result) or self:tool_result_text(result)
  }
end

---Parse stream event.
---@param data string|nil
---@return string|nil text
---@return boolean done
---@return table|nil usage
---@return table|string|nil error
---@return table|nil event
function OpenAI:parse_stream_event(data)
  if not data or data == "" or data == "[DONE]" then return nil, data == "[DONE]" end
  local json = require "core.json"
  local decoded = json.decode(data)
  if type(decoded) ~= "table" then return nil, false end
  if decoded.type == "error" or decoded.error then
    return nil, true, nil, decoded.error or decoded
  end
  local usage = self:parse_usage(decoded)
  if decoded.type == "response.reasoning_text.delta"
    or decoded.type == "response.reasoning_summary_text.delta"
  then
    return nil, false, usage, nil, {
      type = "reasoning_delta",
      text = decoded.delta or ""
    }
  end
  if decoded.type == "response.output_text.delta" then
    return decoded.delta, false, usage
  end
  if decoded.type == "response.completed" then
    return nil, true, self:parse_usage(decoded.response) or usage
  end
  if decoded.type == "response.failed" then
    return nil, true, usage
  end
  if type(decoded.type) == "string" and decoded.type:match("^response%.") then
    return nil, false, usage
  end
  return OpenAI.super.parse_stream_event(self, data)
end

---Parse stream tool call deltas.
---@param data string|nil
---@return table[] deltas
---@return boolean done
function OpenAI:parse_stream_tool_call_deltas(data)
  if self.api_format ~= "responses" then
    return OpenAI.super.parse_stream_tool_call_deltas(self, data)
  end
  if not data or data == "" or data == "[DONE]" then return {}, data == "[DONE]" end
  local json = require "core.json"
  local decoded = json.decode(data)
  if type(decoded) ~= "table" then return {}, false end

  if decoded.type == "response.output_item.added" then
    local item = decoded.item
    if type(item) == "table" and item.type == "function_call" and item.name then
      return {
        {
          index = decoded.output_index or item.output_index or item.index or item.id,
          item_id = item.id,
          id = item.id,
          call_id = item.call_id,
          type = "function_call",
          format = "responses",
          name = item.name,
          arguments = item.arguments
        }
      }, false
    end
    return {}, false
  end

  if decoded.type == "response.function_call_arguments.delta" then
    return {
      {
        index = decoded.output_index or decoded.item_id,
        item_id = decoded.item_id,
        format = "responses",
        arguments = decoded.delta or ""
      }
    }, false
  end

  if decoded.type == "response.function_call_arguments.done" then
    local delta = {
      index = decoded.output_index or decoded.item_id,
      item_id = decoded.item_id,
      format = "responses"
    }
    if decoded.arguments ~= nil then
      delta.final_arguments = decoded.arguments
    end
    return { delta }, false
  end

  return {}, decoded.type == "response.completed"
end

---Handle supports stream tool calls.
---@return boolean
function OpenAI:supports_stream_tool_calls()
  return true
end

return OpenAI
