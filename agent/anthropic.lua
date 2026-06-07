local common = require "core.common"
local json = require "core.json"
local history_normalizer = require "plugins.assistant.history_normalizer"
local Agent = require "plugins.assistant.agent"

---Anthropic Messages API agent.
---
---Handles Anthropic's content-block message format, top-level system prompt,
---tool_use/tool_result content blocks, and Anthropic-specific tool schemas.
---@class assistant.agent.Anthropic : assistant.Agent
local Anthropic = Agent:extend()

---Create a new instance.
---@param options table|nil
function Anthropic:new(options)
  options = options or {}
  options.name = options.name or "anthropic"
  options.display_name = options.display_name or "Anthropic"
  options.backend = options.backend or "anthropic"
  options.base_url = options.base_url or "https://api.anthropic.com"
  options.endpoint = options.endpoint or "/v1/messages"
  options.models_endpoint = options.models_endpoint or "/v1/models"
  options.api_format = options.api_format or "anthropic-messages"
  options.stream_format = options.stream_format or "anthropic-sse"
  options.model = options.model or "claude-sonnet-4-20250514"
  options.api_key_env = options.api_key_env or "ANTHROPIC_API_KEY"
  options.model_metadata = common.merge({
    preferred_timeout_ms = 300000,
    context_window = 200000,
    stream_tool_calls = true,
    parallel_tool_calls = false,
    reports_usage = true,
    default_max_tokens = 8192,
    max_output_tokens = 65536
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

---Return the headers.
---Anthropic uses x-api-key and anthropic-version headers.
---@return table<string, string>
function Anthropic:get_headers()
  local headers = {
    ["Content-Type"] = "application/json",
    ["anthropic-version"] = "2023-06-01"
  }
  local key = self:get_api_key()
  if key and key ~= "" then
    headers["x-api-key"] = key
  end
  return headers
end

---Return the provider request field used for output token limits.
---@return string field
function Anthropic:generation_budget_field()
  return "max_tokens"
end

---Handle generate tools info.
---Anthropic uses {name, description, input_schema} format.
---@param selected string[]|nil
---@return table[]|nil tools
function Anthropic:generate_tools_info(selected)
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
    local properties = {}
    local required = {}
    for _, param in ipairs(tool.params or {}) do
      properties[param.name] = param.schema or {
        type = param.type or "string",
        description = param.description or ""
      }
      if param.enum then properties[param.name].enum = param.enum end
      if param.required ~= false then
        table.insert(required, param.name)
      end
    end
    local input_schema = {
      type = "object",
      properties = properties
    }
    if tool.additional_properties ~= nil then
      input_schema.additionalProperties = tool.additional_properties
    end
    if #required > 0 then
      input_schema.required = required
    end
    table.insert(result, {
      name = name,
      description = tool.description or "",
      input_schema = input_schema
    })
  end
  return #result > 0 and result or nil
end

---Convert chat-format messages to Anthropic content-block format.
---
---Extracts system messages into the top-level system string and converts
---remaining messages to {role, content: [{type, text|tool_use|tool_result}]}.
---@param messages table[] Chat-format messages from parent provider_messages_for_conversation.
---@return table[] anthropic_messages
---@return string|nil system_prompt
local function convert_to_anthropic_format(agent, messages)
  local system_parts = {}
  local anthropic_messages = {}
  local pending_tool_calls = {}  -- tool_call_id -> {name, id, arguments}

  local function image_source_from_data_url(url)
    if type(url) ~= "string" then return nil end
    local media_type, data = url:match("^data:([^;,]+);base64,(.+)$")
    if not media_type or not data then return nil end
    return {
      type = "base64",
      media_type = media_type,
      data = data
    }
  end

  local function normalize_content_blocks(blocks)
    if type(blocks) ~= "table" then return blocks end
    local normalized = {}
    for _, block in ipairs(blocks) do
      if type(block) == "table" and block.type == "image_url" then
        local image_url = block.image_url
        local url = type(image_url) == "table" and image_url.url or image_url
        local source = image_source_from_data_url(url)
        if source and agent:has_capability("vision") then
          table.insert(normalized, {
            type = "image",
            source = source
          })
        end
      elseif type(block) == "table"
        and block.type == "image"
        and not agent:has_capability("vision")
      then
        -- Drop restored image blocks for providers that do not accept images.
      else
        table.insert(normalized, block)
      end
    end
    return normalized
  end

  local function is_tool_result_blocks(blocks)
    if type(blocks) ~= "table" or #blocks == 0 then return false end
    for _, block in ipairs(blocks) do
      if type(block) ~= "table" or block.type ~= "tool_result" then
        return false
      end
    end
    return true
  end

  for _, msg in ipairs(messages or {}) do
    local role = msg.role
    local content = msg.content or ""

    -- Extract system messages
    if role == "system" then
      if content ~= "" then
        table.insert(system_parts, content)
      end
    -- User messages
    elseif role == "user" then
      local blocks = {}
      -- If content is already a table (e.g., from tool_result provider_messages),
      -- use it directly
      if type(content) == "table" then
        blocks = normalize_content_blocks(content)
      else
        table.insert(blocks, { type = "text", text = tostring(content) })
      end
      local last = anthropic_messages[#anthropic_messages]
      if is_tool_result_blocks(blocks)
        and last
        and last.role == "user"
        and is_tool_result_blocks(last.content)
      then
        for _, block in ipairs(blocks) do
          table.insert(last.content, block)
        end
      else
        table.insert(anthropic_messages, {
          role = "user",
          content = blocks
        })
      end
    -- Assistant messages
    elseif role == "assistant" then
      local blocks = {}
      -- Add text content if present
      if type(content) == "table" then
        blocks = normalize_content_blocks(content)
      elseif content and content ~= "" then
        table.insert(blocks, { type = "text", text = tostring(content) })
      end
      -- Add tool_use blocks from tool_calls
      if type(msg.tool_calls) == "table" then
        for _, call in ipairs(msg.tool_calls) do
          local fn = type(call["function"]) == "table" and call["function"] or {}
          local name = fn.name or call.name
          local args_text = fn.arguments or "{}"
          local ok, args = pcall(json.decode, args_text)
          if not ok or type(args) ~= "table" then args = {} end
          local call_id = call.id or ("call_" .. tostring(#blocks + 1))
          table.insert(blocks, {
            type = "tool_use",
            id = call_id,
            name = name,
            input = args
          })
          pending_tool_calls[call_id] = { name = name, id = call_id }
        end
      end
      if #blocks > 0 then
        table.insert(anthropic_messages, {
          role = "assistant",
          content = blocks
        })
      end
    -- Tool result messages
    elseif role == "tool" then
      local tool_call_id = msg.tool_call_id or ""
      local text_content = tostring(content or "")
      local blocks = {}
      table.insert(blocks, {
        type = "tool_result",
        tool_use_id = tool_call_id,
        content = text_content
      })
      -- Merge with previous user message if it exists and is a user message
      local last = anthropic_messages[#anthropic_messages]
      if last and last.role == "user" and is_tool_result_blocks(last.content) then
        for _, block in ipairs(blocks) do
          table.insert(last.content, block)
        end
      else
        table.insert(anthropic_messages, {
          role = "user",
          content = blocks
        })
      end
    end
  end

  local function tool_use_ids(message)
    local ids = {}
    if type(message) ~= "table"
      or message.role ~= "assistant"
      or type(message.content) ~= "table"
    then
      return ids
    end
    for _, block in ipairs(message.content) do
      if type(block) == "table" and block.type == "tool_use" then
        local id = tostring(block.id or "")
        if id ~= "" then table.insert(ids, id) end
      end
    end
    return ids
  end

  local function tool_result_ids(message)
    local ids = {}
    if type(message) ~= "table"
      or message.role ~= "user"
      or type(message.content) ~= "table"
    then
      return ids
    end
    for _, block in ipairs(message.content) do
      if type(block) == "table" and block.type == "tool_result" then
        local id = tostring(block.tool_use_id or "")
        if id ~= "" then ids[id] = true end
      end
    end
    return ids
  end

  local function has_tool_result(message)
    return next(tool_result_ids(message)) ~= nil
  end

  local function all_results_present(ids, results)
    if #ids == 0 then return false end
    for _, id in ipairs(ids) do
      if not results[id] then return false end
    end
    return true
  end

  local function content_without_tool_uses(message)
    local content = {}
    if type(message) ~= "table" or type(message.content) ~= "table" then
      return content
    end
    for _, block in ipairs(message.content) do
      if not (type(block) == "table" and block.type == "tool_use") then
        table.insert(content, block)
      end
    end
    return content
  end

  local function repair_tool_adjacency(messages)
    local repaired = {}
    local index = 1
    while index <= #messages do
      local message = messages[index]
      local ids = tool_use_ids(message)
      if #ids > 0 then
        local assistant_content = {}
        local required = {}
        repeat
          for _, block in ipairs(message.content or {}) do
            table.insert(assistant_content, block)
          end
          for _, id in ipairs(tool_use_ids(message)) do
            table.insert(required, id)
          end
          index = index + 1
          message = messages[index]
          ids = tool_use_ids(message)
        until #ids == 0

        local result_content = {}
        local results = {}
        while index <= #messages and has_tool_result(messages[index]) do
          for _, block in ipairs(messages[index].content or {}) do
            if type(block) == "table" and block.type == "tool_result" then
              table.insert(result_content, block)
              local id = tostring(block.tool_use_id or "")
              if id ~= "" then results[id] = true end
            end
          end
          index = index + 1
        end

        if all_results_present(required, results) then
          table.insert(repaired, {
            role = "assistant",
            content = assistant_content
          })
          table.insert(repaired, {
            role = "user",
            content = result_content
          })
        else
          local text_content = content_without_tool_uses({
            role = "assistant",
            content = assistant_content
          })
          if #text_content > 0 then
            table.insert(repaired, {
              role = "assistant",
              content = text_content
            })
          end
        end
      elseif has_tool_result(message) then
        index = index + 1
      else
        table.insert(repaired, message)
        index = index + 1
      end
    end
    return repaired
  end

  local function enforce_tool_adjacency(messages)
    local repaired = {}
    local index = 1
    while index <= #messages do
      local message = messages[index]
      local ids = tool_use_ids(message)
      if #ids > 0 then
        local next_message = messages[index + 1]
        local results = tool_result_ids(next_message)
        if is_tool_result_blocks(next_message and next_message.content)
          and all_results_present(ids, results)
        then
          table.insert(repaired, message)
          table.insert(repaired, next_message)
          index = index + 2
        else
          local text_content = content_without_tool_uses(message)
          if #text_content > 0 then
            table.insert(repaired, {
              role = "assistant",
              content = text_content
            })
          end
          index = index + 1
        end
      elseif has_tool_result(message) then
        index = index + 1
      else
        table.insert(repaired, message)
        index = index + 1
      end
    end
    return repaired
  end

  local system_prompt = #system_parts > 0 and table.concat(system_parts, "\n\n") or nil
  return enforce_tool_adjacency(repair_tool_adjacency(anthropic_messages)), system_prompt
end

---Build payload.
---@param conversation assistant.Conversation
---@return table payload
function Anthropic:build_payload(conversation)
  local max_tokens = self:generation_budget(conversation)
    or self:context_generation_budget(conversation)
    or 8192
  local provider_messages = self:provider_messages_for_conversation(conversation)
  local anthropic_messages, system_prompt = convert_to_anthropic_format(self, provider_messages)
  local payload = {
    model = self.model,
    max_tokens = max_tokens,
    messages = anthropic_messages,
    stream = self.stream,
    temperature = self.options.temperature,
    top_p = self.options.top_p_sampling
  }
  if system_prompt then
    payload.system = system_prompt
  end
  local tools = self:has_capability("tool_calling")
    and self:generate_tools_info(self:tool_names_for_mode(conversation))
  if tools then payload.tools = tools end
  return payload
end

---Return native Anthropic response content blocks that should be replayed.
---@param result table|nil
---@return table[]|nil blocks
function Anthropic:response_content_blocks(result)
  if type(result) ~= "table" or type(result.content) ~= "table" then return nil end
  local blocks = {}
  for _, block in ipairs(result.content) do
    if type(block) == "table" then table.insert(blocks, block) end
  end
  return #blocks > 0 and blocks or nil
end

---Build compact payload.
---@param conversation assistant.Conversation
---@return table payload
function Anthropic:build_compact_payload(conversation)
  local max_tokens = 1024
  local payload = {
    model = self.model,
    max_tokens = max_tokens,
    system = "You summarize coding assistant conversations so future turns can continue with enough context.",
    messages = {
      {
        role = "user",
        content = {
          { type = "text", text = self:get_compact_prompt(conversation:to_markdown()) }
        }
      }
    },
    stream = false,
    temperature = 0.1
  }
  return payload
end

---Build title payload.
---@param prompt string
---@return table payload
function Anthropic:build_title_payload(prompt)
  return {
    model = self.model,
    max_tokens = 32,
    system = table.concat({
      "Generate a concise title for this coding conversation.",
      "Base the title only on the user's first prompt.",
      "Return only the title text.",
      "Use 3 to 8 words.",
      "Do not use quotes, Markdown, punctuation at the end, or explanatory text."
    }, "\n"),
    messages = {
      {
        role = "user",
        content = {
          { type = "text", text = tostring(prompt or "") }
        }
      }
    },
    stream = false,
    temperature = 0.1
  }
end

---Parse response.
---Extract text from Anthropic response content blocks.
---@param result table|string|nil
---@return string
function Anthropic:parse_response(result)
  if type(result) ~= "table" then return tostring(result or "") end
  local content = result.content
  if type(content) == "table" then
    local parts = {}
    for _, block in ipairs(content) do
      if type(block) == "table" and block.type == "text" then
        table.insert(parts, type(block.text) == "string" and block.text or "")
      end
    end
    if #parts > 0 then return table.concat(parts) end
  end
  return Anthropic.super.parse_response(self, result)
end

---Parse reasoning content.
---Extract thinking content blocks from a complete Anthropic response.
---@param result table|string|nil
---@return string|nil reasoning_content
function Anthropic:parse_reasoning_content(result)
  if type(result) ~= "table" then return nil end
  local content = result.content
  if type(content) == "table" then
    local parts = {}
    for _, block in ipairs(content) do
      if type(block) == "table" and block.type == "thinking" then
        local text = type(block.thinking) == "string" and block.thinking
          or (type(block.text) == "string" and block.text or "")
        if text ~= "" then table.insert(parts, text) end
      end
    end
    if #parts > 0 then return table.concat(parts, "\n") end
  end
  return Anthropic.super.parse_reasoning_content(self, result)
end

---Parse tool calls.
---Extract tool_use content blocks from Anthropic response.
---@param result table|nil
---@return table[] calls
function Anthropic:parse_tool_calls(result)
  if type(result) ~= "table" then return {} end
  local content = result.content
  if type(content) ~= "table" then return {} end
  local response_content = self:response_content_blocks(result)
  local calls = {}
  local text_blocks = {}
  for _, block in ipairs(content) do
    if type(block) == "table" and block.type == "tool_use" and block.name then
      local args = block.input or {}
      local args_text = json.encode(args)
      table.insert(calls, {
        id = block.id,
        name = block.name,
        arguments = args,
        arguments_text = args_text,
        format = "anthropic",
        raw = block,
        anthropic_content = response_content
      })
    elseif type(block) == "table" and block.type == "text" then
      table.insert(text_blocks, tostring(block.text or ""))
    end
  end
  if #calls == 0 and #text_blocks > 0 then
    return Anthropic.super.parse_text_tool_calls(self, table.concat(text_blocks))
  end
  return calls
end

---Parse usage.
---@param result table|nil
---@return table|nil usage
function Anthropic:parse_usage(result)
  if type(result) ~= "table" then return nil end
  local usage = result.usage
  if usage == nil and (result.input_tokens or result.output_tokens) then
    usage = result
  end
  if type(usage) ~= "table" then return nil end
  local input = usage.input_tokens
  local output = usage.output_tokens
  local cache_creation = usage.cache_creation_input_tokens
  local cache_read = usage.cache_read_input_tokens
  if not (input or output) then return nil end
  local total_input = (input or 0) + (cache_creation or 0) + (cache_read or 0)
  return {
    input_tokens = input,
    output_tokens = output,
    cache_creation_input_tokens = cache_creation,
    cache_read_input_tokens = cache_read,
    total_tokens = total_input + (output or 0),
    context = usage.context
  }
end

---Handle tool call provider message.
---Format tool calls as tool_use content blocks in an assistant message.
---@param calls table[]
---@param index integer|nil
---@return table|nil
function Anthropic:tool_call_provider_message(calls, index)
  local call = (calls or {})[index or 1]
  if not call then return nil end
  if type(call.anthropic_content) == "table" and (index or 1) == 1 then
    return {
      role = "assistant",
      content = call.anthropic_content
    }
  end
  if type((calls or {})[1]) == "table"
    and type((calls or {})[1].anthropic_content) == "table"
  then
    return nil
  end
  local args = call.arguments or {}
  return {
    role = "assistant",
    content = {
      {
        type = "tool_use",
        id = call.id or ("call_" .. tostring(index or 1)),
        name = call.name,
        input = args
      }
    }
  }
end

---Handle tool result provider message.
---Format tool result as a tool_result content block in a user message.
---@param call table
---@param result any
---@param options table|nil
---@return table
function Anthropic:tool_result_provider_message(call, result, options)
  local compact = not (options and options.compact == false)
  local content = compact and self:compact_tool_result(call, result) or self:tool_result_text(result)
  return {
    role = "user",
    content = {
      {
        type = "tool_result",
        tool_use_id = call.id or call.call_id or "",
        content = tostring(content)
      }
    }
  }
end

---Handle tool result provider messages.
---May include image context as additional content blocks.
---@param call table
---@param result any
---@param options table|nil
---@return table[] messages
function Anthropic:tool_result_provider_messages(call, result, options)
  local messages = { self:tool_result_provider_message(call, result, options) }
  local include_images = self:has_capability("vision")
    and not (options and options.include_images == false)
  local image_message = include_images and self:tool_result_image_context_message(call, result) or nil
  if image_message then
    -- Merge image context into the tool_result user message
    local msg = messages[1]
    if msg and msg.role == "user" and type(msg.content) == "table" then
      local image_blocks = image_message.content
      if type(image_blocks) == "table" then
        for _, block in ipairs(image_blocks) do
          table.insert(msg.content, block)
        end
      end
    end
  end
  return messages
end

---Build a provider-only image context message using Anthropic content blocks.
---@param call table
---@param result any
---@return table|nil message
function Anthropic:tool_result_image_context_message(call, result)
  if type(result) ~= "table" or type(result.attachments) ~= "table" then return nil end
  local attachment
  for _, item in ipairs(result.attachments) do
    if type(item) == "table" and item.type == "image" and item.data and item.mime_type then
      attachment = item
      break
    end
  end
  if not attachment then return nil end

  local text = string.format(
    "Image context from `%s` read result: %s [%s] %sx%s.",
    call and call.name or "tool",
    attachment.path or "",
    attachment.mime_type or "image",
    tostring(attachment.width or ""),
    tostring(attachment.height or "")
  )
  return {
    role = "user",
    content = {
      { type = "text", text = text },
      {
        type = "image",
        source = {
          type = "base64",
          media_type = attachment.mime_type,
          data = attachment.data
        }
      }
    }
  }
end

---Handle supports stream tool calls.
---@return boolean
function Anthropic:supports_stream_tool_calls()
  return true
end

return Anthropic
