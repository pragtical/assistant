local core = require "core"
local common = require "core.common"
local config = require "core.config"
local json = require "core.json"
local jsonutil = require "plugins.assistant.jsonutil"
local history_normalizer = require "plugins.assistant.history_normalizer"
local Tool = require "plugins.assistant.tool"
local tool_context = require "plugins.assistant.tool_context"
local tool_router = require "plugins.assistant.tool_router"
local Object = require "core.object"
local unpack = table.unpack or unpack

---Provider-level behavior for assistant conversations.
---
---Agents describe provider capabilities, request payloads, response parsing,
---tool schemas, and provider-history shaping. Communication is intentionally
---handled by backend modules.
---@class assistant.Agent : core.object
---@field name string Stable provider id.
---@field display_name string Human-readable provider name.
---@field version string Provider adapter version.
---@field backend string Backend id used to communicate with this provider.
---@field base_url string HTTP base URL for HTTP-compatible providers.
---@field endpoint string Chat or responses endpoint.
---@field models_endpoint string Model-list endpoint.
---@field api_format string Provider API format, usually `"chat"` or `"responses"`.
---@field stream_format string Streaming format used by the backend.
---@field model string Active provider model id.
---@field api_key_env string|nil Environment variable used for an API key.
---@field api_key string|nil Direct API key value.
---@field stream boolean Whether streaming responses are enabled.
---@field capabilities table<string, boolean>
---@field collaboration_modes table[]|nil
---@field compact_implementation_tools boolean
---@field tools table<string, assistant.Tool.registration>
---@field options table<string, any>
---@field model_metadata table<string, any>
---@field super core.object
local Agent = Object:extend()

local REASONING_EFFORT_VALUES = {
  none = true,
  low = true,
  medium = true,
  high = true
}

---Create a new instance.
---@param options table|nil Agent configuration and provider defaults.
function Agent:new(options)
  options = options or {}
  local explicit_context = options.options
    and options.options.context ~= nil
  self.name = options.name or "generic"
  self.display_name = options.display_name or self.name
  self.version = options.version or "0.1"
  self.backend = options.backend or "http"
  self.base_url = options.base_url or "http://localhost:11434"
  self.endpoint = options.endpoint or "/v1/chat/completions"
  self.models_endpoint = options.models_endpoint or "/v1/models"
  self.api_format = options.api_format or "chat"
  self.stream_format = options.stream_format or "sse"
  self.model = options.model or "default"
  self.api_key_env = options.api_key_env
  self.api_key = options.api_key
  self.stream = options.stream ~= false
  self.reasoning_effort = options.reasoning_effort
  self.reasoning_effort_inherited = options.reasoning_effort_inherited == true
  self.capabilities = common.merge({
    reports_usage = false,
    reports_context = false,
    compact = false,
    delete_conversation = false,
    list_conversations = false,
    rename_conversation = false,
    collaboration_modes = false,
    user_input_requests = false,
    approval_requests = false,
    stream_responses = false,
    tool_calling = false,
    keep_alive = false,
    local_compact = false,
    keep_reasoning_content = false
  }, options.capabilities or {})
  self.collaboration_modes = options.collaboration_modes
  self.compact_implementation_tools = options.compact_implementation_tools == true
  self.tools = {}
  self._loading = false
  self.options = common.merge({
    context = 16384,
    temperature = 0.2,
    top_k_sampling = 40,
    repeat_penalty = 1.1,
    min_p_sampling = 0.05,
    top_p_sampling = 0.95
  }, options.options or {})
  self.model_metadata = common.merge({
    context_window = self.options.context,
    stream_tool_calls = self.capabilities.stream_responses == true
      and self.capabilities.tool_calling == true,
    parallel_tool_calls = false,
    reports_usage = self.capabilities.reports_usage == true,
    preferred_timeout_ms = nil,
    default_max_tokens = nil,
    max_output_tokens = nil,
    chat_reasoning_effort = false
  }, options.model_metadata or {})
  if not explicit_context and self.model_metadata.context_window then
    self.options.context = self.model_metadata.context_window
  end
end

---Return whether capability is available.
---@param name string
---@return boolean
function Agent:has_capability(name)
  return self.capabilities and self.capabilities[name] == true
end

---Hook for provider-specific config fields.
---@param conf table
function Agent:configure_provider(_) end

---Handle configure.
---@param conf table|nil User/plugin configuration.
---@return assistant.Agent self
function Agent:configure(conf)
  conf = conf or {}
  local supports_api_key = self.api_key_env and self.api_key_env ~= ""
  if conf.model and conf.model ~= "" then self.model = conf.model end
  if conf.base_url and conf.base_url ~= "" then self.base_url = conf.base_url end
  if supports_api_key and conf.api_key and conf.api_key ~= "" then
    self.api_key = conf.api_key
  end
  if supports_api_key and conf.api_key_env and conf.api_key_env ~= "" then
    self.api_key_env = conf.api_key_env
  end
  if self:has_capability("keep_alive") and conf.keep_alive and conf.keep_alive ~= "" then
    self.keep_alive = conf.keep_alive
  end
  if type(conf.capabilities) == "table" then
    self.capabilities = common.merge(self.capabilities or {}, conf.capabilities)
  end
  if type(conf.tool_calling) == "boolean" then
    self.capabilities.tool_calling = conf.tool_calling
  end
  self.model_metadata.stream_tool_calls = self.capabilities.stream_responses == true
    and self.capabilities.tool_calling == true
  self.model_metadata.reports_usage = self.capabilities.reports_usage == true
  if conf.reasoning_effort ~= nil then
    self.reasoning_effort = conf.reasoning_effort
  end
  self.reasoning_effort_inherited = conf.reasoning_effort_inherited == true
  self.stream = conf.stream ~= false and self:has_capability("stream_responses")
  self:configure_provider(conf)
  return self
end

---Return the collaboration modes.
---@return table[] modes
function Agent:get_collaboration_modes()
  return self.collaboration_modes or {
    { id = "implementation", label = "Implementation" },
    { id = "plan", label = "Plan" }
  }
end

---Build collaboration mode.
---@param mode string|table|nil
---@return table|nil
function Agent:build_collaboration_mode(mode)
  return mode
end

---Normalize collaboration mode.
---@param mode string|table|nil
---@return string
function Agent:normalize_collaboration_mode(mode)
  if type(mode) == "table" then
    mode = mode.id or mode.mode or mode.name
  end
  mode = tostring(mode or "")
  if mode == "default" then return "implementation" end
  if mode == "" then return nil end
  return mode
end

---Handle clone table.
local function clone_table(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for key, item in pairs(value) do
    copy[key] = clone_table(item)
  end
  return copy
end

---Return whether hash text is available.
local function hash_text(text)
  text = tostring(text or "")
  local hash = 2166136261
  for i = 1, #text do
    hash = (hash * 16777619 + text:byte(i)) % 4294967296
  end
  return string.format("%08x", hash)
end

---Handle tool call has omitted arguments.
local function tool_call_has_omitted_arguments(call)
  local fn = type(call) == "table" and type(call["function"]) == "table" and call["function"] or nil
  if not fn or type(fn.arguments) ~= "string" then return false end
  local ok, decoded = pcall(json.decode, fn.arguments)
  if not ok or type(decoded) ~= "table" then return false end
  return history_normalizer.contains_omitted_tool_argument(decoded)
end

---Handle omit omitted tool calls.
local function omit_omitted_tool_calls(message)
  if type(message) ~= "table" or message.role ~= "assistant" or type(message.tool_calls) ~= "table" then
    return message
  end
  local omitted_ids = {}
  for _, call in ipairs(message.tool_calls) do
    if tool_call_has_omitted_arguments(call) then
      local id = tostring(call.id or "")
      if id ~= "" then omitted_ids[id] = true end
    end
  end
  if not next(omitted_ids) then return message end
  return {
    omitted_tool_call_ids = omitted_ids,
    omit_provider_message = true
  }
end

---Return provider tool call id.
---@param call table
---@return string
local function provider_tool_call_id(call)
  return tostring(type(call) == "table" and (call.id or call.call_id) or "")
end

---Return provider tool call name.
---@param call table
---@return string|nil
local function provider_tool_call_name(call)
  if type(call) ~= "table" then return nil end
  local fn = type(call["function"]) == "table" and call["function"] or nil
  return fn and fn.name or call.name
end

---Remove completed tool calls from an assistant provider message.
---@param message table
---@param completed_ids table<string, boolean>
---@return table|nil
local function remove_completed_tool_calls(message, completed_ids)
  if type(message) ~= "table" or type(message.tool_calls) ~= "table" then return message end
  local remaining = {}
  for _, call in ipairs(message.tool_calls) do
    local id = provider_tool_call_id(call)
    if id == "" or not completed_ids[id] then
      table.insert(remaining, clone_table(call))
    end
  end
  local content = message.content
  if #remaining == 0 and (content == nil or content == "") then return nil end
  local copy = clone_table(message)
  if #remaining > 0 then
    copy.tool_calls = remaining
  else
    copy.tool_calls = nil
  end
  return copy
end

---Handle trailing tool exchange indexes.
local function trailing_tool_exchange_indexes(messages)
  local preserve = {}
  if type(messages) ~= "table" or #messages == 0 then return preserve end

  local last = messages[#messages]
  if type(last) == "table" and type(last.tool_calls) == "table" then
    preserve[#messages] = true
    return preserve
  end

  local index = #messages
  while index >= 1 do
    local message = messages[index]
    if type(message) == "table" and message.role == "tool" then
      preserve[index] = true
      index = index - 1
    else
      break
    end
  end

  local tool_call_message = messages[index]
  if type(tool_call_message) == "table" and type(tool_call_message.tool_calls) == "table" then
    preserve[index] = true
    return preserve
  end

  return {}
end

---Handle unresolved tool call indexes.
local function unresolved_tool_call_indexes(messages)
  local tool_results = {}
  if type(messages) ~= "table" then return {} end

  for _, message in ipairs(messages) do
    if type(message) == "table" and message.role == "tool" then
      local id = tostring(message.tool_call_id or "")
      if id ~= "" then tool_results[id] = true end
    end
  end

  local preserve = {}
  for index, message in ipairs(messages) do
    if type(message) == "table" and type(message.tool_calls) == "table" then
      for _, call in ipairs(message.tool_calls) do
        local id = tostring(type(call) == "table" and call.id or "")
        if id ~= "" and not tool_results[id] then
          preserve[index] = true
          break
        end
      end
    end
  end
  return preserve
end

---Handle unprocessed tool result indexes.
local function unprocessed_tool_result_indexes(messages)
  local preserve = {}
  if type(messages) ~= "table" then return preserve end

  local tool_call_indexes = {}
  for index, message in ipairs(messages) do
    if type(message) == "table" and type(message.tool_calls) == "table" then
      for _, call in ipairs(message.tool_calls) do
        local id = tostring(type(call) == "table" and call.id or "")
        if id ~= "" then tool_call_indexes[id] = index end
      end
    end
  end

  local has_later_assistant = false
  for index = #messages, 1, -1 do
    local message = messages[index]
    if type(message) == "table" and message.role == "assistant" then
      has_later_assistant = true
    elseif type(message) == "table" and message.role == "tool" and not has_later_assistant then
      preserve[index] = true
      local call_index = tool_call_indexes[tostring(message.tool_call_id or "")]
      if call_index then preserve[call_index] = true end
    end
  end

  return preserve
end

---Resolve a registered tool for a provider call.
---@param call table
---@return assistant.Tool.registration|nil tool
function Agent:tool_for_provider_call(call)
  local name = self:resolve_tool_name(provider_tool_call_name(call))
  local tool = self.tools[name or ""]
  if tool then return tool end
  if name == "apply_patch" then
    local ok, applypatch = pcall(require, "plugins.assistant.tool.applypatch")
    if ok and type(applypatch) == "table" then
      return {
        name = "apply_patch",
        compact_provider_call = function(provider_call, compact_context)
          return Tool.compact_provider_call({ name = "apply_patch" }, provider_call, compact_context)
        end,
        result_is_successful = applypatch.result_is_successful,
        compact_history = applypatch.compact_history
      }
    end
  end
  return nil
end

---Compact one provider tool call through its registered tool.
---@param call table
---@param compact_context table
---@return table call
function Agent:compact_provider_call(call, compact_context)
  local tool = self:tool_for_provider_call(call)
  if tool and tool.compact_provider_call then
    local ok, compacted = pcall(tool.compact_provider_call, call, compact_context)
    if ok and type(compacted) == "table" then return compacted end
  end
  return Tool.compact_provider_call(tool or {}, call, compact_context)
end

---Compact one provider message through registered tools.
---@param message table
---@param compact_context table
---@return table message
function Agent:compact_provider_message(message, compact_context)
  if type(message) ~= "table" then return message end
  local copy = Tool.clone_table(message)
  if type(copy.tool_calls) == "table" then
    for index, call in ipairs(copy.tool_calls) do
      copy.tool_calls[index] = self:compact_provider_call(call, compact_context)
    end
  end
  if copy.type == "function_call" then
    copy = self:compact_provider_call(copy, compact_context)
  end
  if copy.role == "tool" and type(copy.content) == "string" then
    copy.content = Tool.compact_long_text(copy.content)
  end
  if copy.type == "function_call_output" and type(copy.output) == "string" then
    copy.output = Tool.compact_long_text(copy.output)
  end
  return copy
end

---Return successful historical tool result maps.
---@param messages table[]
---@param compact_context table
---@return table<string, boolean> ids
---@return table<string, string> texts
local function successful_tool_result_maps(agent, messages, compact_context)
  local calls_by_id = {}
  for _, message in ipairs(messages or {}) do
    if type(message) == "table" and type(message.tool_calls) == "table" then
      for _, call in ipairs(message.tool_calls) do
        local id = provider_tool_call_id(call)
        if id ~= "" then calls_by_id[id] = call end
      end
    elseif type(message) == "table" and message.type == "function_call" then
      local id = provider_tool_call_id(message)
      if id ~= "" then calls_by_id[id] = message end
    end
  end

  local ids = {}
  local texts = {}
  for _, message in ipairs(messages or {}) do
    if type(message) == "table" and (message.role == "tool" or message.type == "function_call_output") then
      local id = tostring(message.tool_call_id or message.call_id or "")
      local call = calls_by_id[id]
      local tool = call and agent:tool_for_provider_call(call)
      if id ~= "" and tool and tool.result_is_successful then
        local ok, successful = pcall(tool.result_is_successful, call, message, compact_context)
        if ok and successful then
          ids[id] = true
          texts[id] = tostring(message.content or message.output or "")
        end
      end
    end
  end
  return ids, texts
end

---Return provider messages after optional historical tool compaction.
---@param messages table[] Provider message list built from a conversation.
---@param conversation assistant.Conversation|nil Source conversation.
---@return table[] messages
function Agent:compact_provider_messages(messages, conversation)
  local conf = config.plugins and config.plugins.assistant or {}
  if conf.compact_tool_history ~= true then return messages end
  if not self.compact_implementation_tools then return messages end
  local compact_context = {
    project_dir = conversation and conversation.project_dir,
    conversation = conversation,
    agent = self
  }
  local compacted = {}
  local skipped_tool_result_ids = {}
  local tool_result_ids, tool_result_texts = successful_tool_result_maps(self, messages, compact_context)
  local preserve_indexes = trailing_tool_exchange_indexes(messages)
  for index in pairs(unresolved_tool_call_indexes(messages)) do
    preserve_indexes[index] = true
  end
  for index in pairs(unprocessed_tool_result_indexes(messages)) do
    preserve_indexes[index] = true
  end
  local function compact_history_for(message, included_ids)
    local inserted_ids = {}
    local inserted = false
    local tools_seen = {}
    for _, call in ipairs(type(message) == "table" and message.tool_calls or {}) do
      local id = provider_tool_call_id(call)
      if id ~= "" and included_ids[id] then
        local tool = self:tool_for_provider_call(call)
        if tool and tool.compact_history and not tools_seen[tool] then
          tools_seen[tool] = true
          local ok, snapshots = pcall(tool.compact_history, message, compact_context, included_ids, tool_result_texts)
          if ok and type(snapshots) == "table" then
            for _, snapshot in ipairs(snapshots) do
              if type(snapshot) == "table" then
                table.insert(compacted, snapshot)
                inserted = true
              end
            end
          end
        end
      end
    end
    if inserted then
      for id in pairs(included_ids) do inserted_ids[id] = true end
    end
    return inserted_ids, inserted
  end
  for index, message in ipairs(messages or {}) do
    local compacted_message
    local completed_ids = {}
    local completed_count = 0
    if type(message) == "table" and type(message.tool_calls) == "table" then
      for _, call in ipairs(message.tool_calls) do
        local id = provider_tool_call_id(call)
        if id ~= "" and tool_result_ids[id] then
          completed_ids[id] = true
          completed_count = completed_count + 1
        end
      end
    end
    if preserve_indexes[index] then
      compacted_message = clone_table(message)
    elseif completed_count > 0 then
      local inserted_ids, inserted = compact_history_for(message, completed_ids)
      for id in pairs(inserted_ids) do
        skipped_tool_result_ids[id] = true
      end
      if inserted then
        compacted_message = remove_completed_tool_calls(message, inserted_ids)
      else
        compacted_message = omit_omitted_tool_calls(self:compact_provider_message(message, compact_context))
      end
    else
      compacted_message = omit_omitted_tool_calls(self:compact_provider_message(message, compact_context))
    end
    if type(compacted_message) == "table" and compacted_message.omitted_tool_call_ids then
      for id in pairs(compacted_message.omitted_tool_call_ids) do
        skipped_tool_result_ids[id] = true
      end
      if compacted_message.omit_provider_message then
        local all_ids = {}
        if type(message) == "table" and type(message.tool_calls) == "table" then
          for _, call in ipairs(message.tool_calls) do
            local id = provider_tool_call_id(call)
            if id ~= "" then all_ids[id] = true end
          end
        end
        compact_history_for(message, all_ids)
      end
      if not compacted_message.omit_provider_message then
        compacted_message.omitted_tool_call_ids = nil
        table.insert(compacted, compacted_message)
      end
    elseif compacted_message ~= nil then
      local skip_tool_result = type(compacted_message) == "table"
        and compacted_message.role == "tool"
        and skipped_tool_result_ids[tostring(compacted_message.tool_call_id or "")]
      if not skip_tool_result then
        table.insert(compacted, compacted_message)
      end
    end
  end
  return compacted
end

---Return the mode instructions.
---@param conversation assistant.Conversation|nil
---@return string|nil
function Agent:get_mode_instructions(conversation)
  local mode = self:normalize_collaboration_mode(conversation and conversation.collaboration_mode)
  if mode == "plan" then
    return table.concat({
      "Collaboration mode: Plan.",
      "In this mode, do not create, edit, delete, patch, format, build, install, or otherwise mutate project files.",
      "Durable assistant memory updates may be made only when appropriate and after approval.",
      "You may use read-only terminal inspection commands when the plan depends on local environment details.",
      "Do not ask the user before using clearly read-only inspection commands such as `ls`, `pwd`, `git status`, `find`, `stat`, or `pkg-config --exists`.",
      "Do not imply that you are implementing now; phrase the response as a plan for later implementation.",
      "Use read-only inspection tools to ground your plan before asking questions.",
      "Use request_user_input only for choices that materially change the plan and cannot be answered from the project.",
      "Do not write implementation code, full source files, patches, or long code blocks in Plan mode; describe intended files, interfaces, behavior, tests, and risks in prose or concise pseudocode only.",
      "When the plan is decision-complete, respond with one Markdown plan that another engineer or agent can implement directly.",
      "After presenting a decision-complete plan, use implement_plan if available to ask whether to switch to Implementation mode and start the work.",
      "Choose reasonable defaults instead of asking for confirmation when the user's request is clear.",
      "Do not include private reasoning markup in user-visible responses.",
      "Do not ask whether to proceed in prose."
    }, "\n")
  end
  if mode == "implementation" then
    local model = tostring(self.model or ""):lower()
    local uses_gpt_tools = model:find("gpt", 1, true) ~= nil
    local edit_instructions = uses_gpt_tools and {
      "Use apply_patch for file creation, edits, and deletions.",
      "When updating, moving, or deleting an existing file with apply_patch, use recent exact file context. If the available context is stale, summarized, omitted, or compacted, read the target file or exact region first.",
      "If apply_patch fails with a context or removal mismatch, do not retry the same patch blindly; read the current target file or exact region, then rebuild the patch from that fresh content."
    } or {
      "Use edit for precise changes to existing files. Each edits[].oldText must match a unique, non-overlapping region of the original file.",
      "Use write only for new files or complete rewrites.",
      "Use read to inspect exact current file content before editing when context may be stale, summarized, omitted, or compacted."
    }
    local lines = {
      "Collaboration mode: Implementation.",
      "Carry out the user's requested implementation using the available tools.",
      "When the user asks to replace or update a specific string, repository slug, URL, symbol, or path, keep the scope to that exact value and obvious direct variants unless the user explicitly asks to broaden it.",
      "For exact replacement tasks, first search for the complete old value exactly as given. Do not search for or edit broader substrings, adjacent product names, workflow names, comments, or dependency/tooling URLs unless they also contain the complete old value or the user explicitly requests that broader rename.",
      "For local project editing tasks, prefer local inspection tools. Use web tools only when the user asks for current external information or local project context is insufficient.",
    }
    for _, line in ipairs(edit_instructions) do table.insert(lines, line) end
    table.insert(lines, "Use exec_command for shell commands, exec_status to poll, write_stdin to send input, send_eof to close stdin, interrupt_exec to interrupt, and close_exec to terminate an ongoing command session.")
    table.insert(lines, "If the transcript contains a proposed plan and the user asks to implement it, treat that plan as the implementation specification unless the user changes direction.")
    table.insert(lines, "Do not include private reasoning markup in user-visible responses.")
    return table.concat(lines, "\n")
  end
end

---Handle provider messages for conversation.
---@param conversation assistant.Conversation
---@return table[] messages
function Agent:provider_messages_for_conversation(conversation)
  if conversation and conversation.refresh_context then
    conversation:refresh_context(self)
  end
  if conversation and conversation.refresh_environment_context then
    conversation:refresh_environment_context(self)
  end
  local messages = history_normalizer.normalize_chat_messages(
    self:compact_provider_messages(conversation:to_provider_messages(), conversation)
  )
  if not self:should_persist_reasoning_content() then
    for _, message in ipairs(messages) do
      if type(message) == "table" then
        message.reasoning_content = nil
      end
    end
  end
  local instructions = self:get_mode_instructions(conversation)
  if not instructions or instructions == "" then return messages end
  local result = {}
  local inserted = false
  for _, message in ipairs(messages) do
    if message.role == "system" and not inserted then
      local copy = common.merge({}, message)
      copy.content = table.concat({ copy.content or "", instructions }, "\n\n")
      table.insert(result, copy)
      inserted = true
    else
      table.insert(result, message)
    end
  end
  if not inserted then
    table.insert(result, 1, { role = "system", content = instructions })
  end
  return result
end

---Return display/provider text from a tool result.
---@param result any
---@return string
function Agent:tool_result_text(result)
  if type(result) == "table" then
    return tostring(result.text or result.message or "")
  end
  return tostring(result or "")
end

---Handle tool names for mode.
---@param conversation assistant.Conversation|nil
---@return string[]|nil names
function Agent:tool_names_for_mode(conversation)
  return tool_router.tool_names_for_mode(self, conversation)
end

---Normalize user input request.
---@param request table
---@return table
function Agent:normalize_user_input_request(request)
  return request
end

---Format user input response.
---@param answers table|nil
---@return table
function Agent:format_user_input_response(_, _, answers)
  return answers or {}
end

---Normalize approval request.
---@param request table
---@return table
function Agent:normalize_approval_request(request)
  return request
end

---Format approval response.
---@param decision string
---@return table|string
function Agent:format_approval_response(_, decision)
  return decision or {}
end

---Handle register tool.
---@param name string
---@param options assistant.Tool.registration
function Agent:register_tool(name, options)
  self.tools[name] = options
end

---Handle unregister tool.
---@param name string
function Agent:unregister_tool(name)
  self.tools[name] = nil
end

---Set the loading.
---@param value boolean
function Agent:set_loading(value)
  self._loading = value and true or false
end

---Handle loading.
---@return boolean
function Agent:loading()
  return self._loading == true
end

---Handle sorted tool names.
local function sorted_tool_names(tools, selected)
  local names = {}
  if type(selected) == "table" then
    for _, name in ipairs(selected) do
      if tools[name] then table.insert(names, name) end
    end
  else
    for name in pairs(tools) do
      table.insert(names, name)
    end
  end
  table.sort(names)
  return names
end

---Handle tool parameters schema.
---@param tool assistant.Tool.registration
---@return table schema
function Agent:tool_parameters_schema(tool)
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
  local parameters = {
    type = "object",
    properties = properties
  }
  if tool.additional_properties ~= nil then
    parameters.additionalProperties = tool.additional_properties
  end
  if #required > 0 then
    parameters.required = required
  end
  return parameters
end

---Handle generate tools info.
---@param selected string[]|nil
---@return table[]|nil tools
function Agent:generate_tools_info(selected)
  local result = {}
  for _, name in ipairs(sorted_tool_names(self.tools, selected)) do
    local tool = self.tools[name]
    table.insert(result, {
      type = "function",
      ["function"] = {
        name = name,
        description = tool.description or "",
        parameters = self:tool_parameters_schema(tool)
      }
    })
  end
  return #result > 0 and result or nil
end

---Return whether tools is available.
---@return boolean
function Agent:has_tools()
  return next(self.tools) ~= nil
end

---Return the api key.
---@return string|nil
function Agent:get_api_key()
  if self.api_key and self.api_key ~= "" then return self.api_key end
  if self.api_key_env and self.api_key_env ~= "" then
    return os.getenv(self.api_key_env)
  end
end

---Return the headers.
---@return table<string, string>
function Agent:get_headers()
  local headers = {
    ["Content-Type"] = "application/json"
  }
  local key = self:get_api_key()
  if key and key ~= "" then
    headers.Authorization = "Bearer " .. key
  end
  return headers
end

---Return a snapshot of the current runtime environment.
---@param project_dir string|nil
---@return table snapshot
function Agent:environment_context_snapshot(project_dir)
  project_dir = project_dir or (core.root_project() and core.root_project().path) or "."
  local platform = rawget(_G, "PLATFORM") or "unknown"
  local arch = rawget(_G, "ARCH") or "unknown"
  local pathsep = rawget(_G, "PATHSEP") or package.config:sub(1, 1)
  local shell = os.getenv("SHELL") or os.getenv("COMSPEC") or "/bin/sh"
  local project_roots = {}
  for _, project in ipairs(core.projects or {}) do
    if project.path and project.path ~= "" then
      table.insert(project_roots, tostring(project.path))
    end
  end
  local snapshot = {
    agent = self.name,
    project_dir = tostring(project_dir),
    cwd = tostring(project_dir),
    shell = tostring(shell),
    current_date = os.date("%Y-%m-%d"),
    timezone = os.getenv("TZ") or os.date("%Z"),
    platform = tostring(platform),
    architecture = tostring(arch),
    path_separator = tostring(pathsep),
    project_roots = project_roots
  }
  snapshot.hash = hash_text(table.concat({
    snapshot.agent or "",
    snapshot.project_dir or "",
    snapshot.cwd or "",
    snapshot.shell or "",
    snapshot.current_date or "",
    snapshot.timezone or "",
    snapshot.platform or "",
    snapshot.architecture or "",
    snapshot.path_separator or "",
    table.concat(snapshot.project_roots or {}, "\n")
  }, "\n"))
  return snapshot
end

---Render a runtime environment snapshot for model context.
---@param snapshot table|nil
---@return string message
function Agent:render_environment_context(snapshot)
  snapshot = snapshot or self:environment_context_snapshot()
  local lines = {
    "Runtime environment:",
    " - cwd: " .. tostring(snapshot.cwd or snapshot.project_dir or "."),
    " - shell: " .. tostring(snapshot.shell or ""),
    " - current_date: " .. tostring(snapshot.current_date or ""),
    " - timezone: " .. tostring(snapshot.timezone or ""),
    " - platform: " .. tostring(snapshot.platform or ""),
    " - architecture: " .. tostring(snapshot.architecture or ""),
    " - path_separator: " .. tostring(snapshot.path_separator or "")
  }
  local roots = snapshot.project_roots or {}
  if #roots > 0 then
    table.insert(lines, " - project_roots: " .. table.concat(roots, ", "))
  end
  return table.concat(lines, "\n")
end

---Return a provider-only runtime environment context message.
---@param project_dir string|nil
---@return table message
function Agent:environment_context_message(project_dir)
  local snapshot = self:environment_context_snapshot(project_dir)
  return {
    role = "user",
    content = self:render_environment_context(snapshot),
    meta = {
      contextual = true,
      environment_context = true,
      provider_only = true,
      environment_snapshot = snapshot
    }
  }
end

---Return the environment message.
---@return string
function Agent:get_environment_message()
  return self:render_environment_context(self:environment_context_snapshot())
end

---Build context fragments.
---@param project_dir string|nil
---@param project_instructions string|nil
---@param memories table[]|nil
---@return table[] fragments
function Agent:build_context_fragments(project_dir, project_instructions, memories)
  project_dir = project_dir or (core.root_project() and core.root_project().path) or "."
  local fragments = {
    {
      id = "base",
      content = table.concat({
        "You are Pragma, a coding assistant working in the project at `" .. project_dir .. "`.",
        "Help the user inspect, modify, and verify code in this project.",
        "Be precise, practical, and oriented toward changes that fit the existing codebase.",
        "Use project context and available tools when needed. Explain important decisions clearly.",
        "Project memories are durable notes for this project: use search_memory before updating or deleting a memory when you do not know its id.",
        "Use remember only for stable user preferences, project conventions, durable decisions, or recurring facts that should affect future sessions.",
        "Do not store secrets, transient command output, one-off task state, or facts already obvious from project files.",
        "Use forget when the user says a memory is wrong, obsolete, superseded, or no longer applicable."
      }, "\n")
    },
    {
      id = "permissions",
      content = table.concat({
        "Tool safety:",
        "- Read-only inspection tools may run without confirmation when their target is inside the active project.",
        "- Commands and tools that create, edit, delete, build, install, access the network, or leave the project require approval.",
        "- Plan mode may inspect and ask questions, but must not change project files."
      }, "\n")
    }
  }
  if project_instructions and project_instructions ~= "" then
    table.insert(fragments, {
      id = "project_instructions",
      content = "Project AGENTS.md instructions:\n" .. project_instructions
    })
  end
  if memories and #memories > 0 then
    local memory_text = {}
    for _, item in ipairs(memories) do
      table.insert(memory_text, "- " .. tostring(item.title or item.id or "Memory") .. ": " .. tostring(item.content or ""))
    end
    table.insert(fragments, {
      id = "memories",
      content = "Project assistant memories:\n" .. table.concat(memory_text, "\n")
    })
  end
  return fragments
end

---Handle context snapshot.
---@param project_dir string
---@param project_instructions string|nil
---@param memories table[]|nil
---@return table snapshot
function Agent:context_snapshot(project_dir, project_instructions, memories)
  local fragments = self:build_context_fragments(project_dir, project_instructions, memories)
  local snapshot = {
    agent = self.name,
    model = self.model,
    project_dir = project_dir,
    fragments = {}
  }
  for _, fragment in ipairs(fragments) do
    local content = fragment.content or ""
    table.insert(snapshot.fragments, {
      id = fragment.id,
      bytes = #content,
      hash = hash_text(content)
    })
  end
  return snapshot
end

---Return the role message.
---@param project_dir string
---@param project_instructions string|nil
---@param memories table[]|nil
---@return string
function Agent:get_role_message(project_dir, project_instructions, memories)
  local parts = {}
  for _, fragment in ipairs(self:build_context_fragments(project_dir, project_instructions, memories)) do
    table.insert(parts, fragment.content)
  end
  return table.concat(parts, "\n\n")
end

---Build payload.
---@param conversation assistant.Conversation
---@return table payload
function Agent:build_payload(conversation)
  local max_tokens = self:generation_budget(conversation)
  local payload = {
    model = self.model,
    messages = self:provider_messages_for_conversation(conversation),
    stream = self.stream,
    temperature = self.options.temperature,
    top_p = self.options.top_p_sampling
  }
  if self.model_metadata and self.model_metadata.chat_reasoning_effort then
    local reasoning_effort = self:configured_reasoning_effort()
    if reasoning_effort then payload.reasoning_effort = reasoning_effort end
  end
  if max_tokens then payload[self:generation_budget_field()] = max_tokens end
  if payload.stream and self:has_capability("reports_usage") then
    payload.stream_options = { include_usage = true }
  end
  local tools = self:has_capability("tool_calling")
    and self:generate_tools_info(self:tool_names_for_mode(conversation))
  if tools then payload.tools = tools end
  return payload
end

---Handle configured reasoning effort.
---@return string|nil
function Agent:configured_reasoning_effort()
  local conf = config.plugins and config.plugins.assistant or {}
  local value = self.reasoning_effort
  if value == nil then value = conf.reasoning_effort end
  if type(value) ~= "string" then return nil end
  value = value:match("^%s*(.-)%s*$")
  if value == "" or not REASONING_EFFORT_VALUES[value] then return nil end
  return value
end

---Return the reasoning effort that should be shown in the UI.
---@return string|nil
function Agent:display_reasoning_effort()
  return self:configured_reasoning_effort()
end

---Return whether provider reasoning_content should be persisted and replayed.
---@return boolean
function Agent:should_persist_reasoning_content()
  local conf = config.plugins and config.plugins.assistant or {}
  return conf.persist_reasoning_content == true
    or self:has_capability("keep_reasoning_content")
end

---Return the provider request field used for output token limits.
---@return string field
function Agent:generation_budget_field()
  return "max_tokens"
end

---Return the generation budget derived from remaining context.
---@param conversation assistant.Conversation|nil
---@return integer|nil
function Agent:context_generation_budget(conversation)
  local usage = conversation and conversation.usage or nil
  local context = tonumber(usage and (usage.context or usage.model_context_window))
    or tonumber(conversation and conversation.options and conversation.options.context)
    or tonumber(self.model_metadata and self.model_metadata.context_window)
  local used = tonumber(usage and usage.total_tokens)
  if not (context and used and context > used) then return nil end

  local remaining = context - used
  local reserve = math.max(256, math.floor(context * 0.1))
  local budget = math.max(128, remaining - reserve)
  local fraction = tonumber(self.options.output_context_fraction)
    or tonumber(self.model_metadata and self.model_metadata.output_context_fraction)
  if not (fraction and fraction > 0 and fraction <= 1) then fraction = 0.5 end
  budget = math.min(budget, math.floor(context * fraction))

  local cap = tonumber(self.model_metadata and self.model_metadata.max_output_tokens)
  if cap and cap > 0 then budget = math.min(budget, cap) end
  return math.max(1, math.floor(budget))
end

---Handle generation budget.
---@param conversation assistant.Conversation|nil
---@return integer|nil
function Agent:generation_budget(conversation)
  local cap = tonumber(self.model_metadata and self.model_metadata.max_output_tokens)
  local explicit = tonumber(self.options.max_tokens)
  if explicit and explicit > 0 then
    if cap and cap > 0 then explicit = math.min(explicit, cap) end
    return math.floor(explicit)
  end
  local conf = config.plugins and config.plugins.assistant or {}
  if conf.send_max_tokens ~= true then return nil end
  explicit = tonumber(conf.send_max_tokens_amount)
  if explicit and explicit > 0 then
    if cap and cap > 0 then explicit = math.min(explicit, cap) end
    return math.floor(explicit)
  end
  local context_budget = self:context_generation_budget(conversation)
  if context_budget then return context_budget end
  local default = tonumber(self.model_metadata and self.model_metadata.default_max_tokens)
  if default and default > 0 then
    if cap and cap > 0 then default = math.min(default, cap) end
    return math.floor(default)
  end
end

---Return the compact prompt.
---@param conversation_markdown string
---@return string
function Agent:get_compact_prompt(conversation_markdown)
  return table.concat({
    "Compact this coding assistant conversation into a concise continuation summary.",
    "Preserve user goals, decisions made, files/tools/results mentioned, current state, and open tasks.",
    "Write only the summary. Do not answer the conversation.",
    "",
    conversation_markdown or ""
  }, "\n")
end

---Build compact payload.
---@param conversation assistant.Conversation
---@return table payload
function Agent:build_compact_payload(conversation)
  return {
    model = self.model,
    messages = {
      {
        role = "system",
        content = "You summarize coding assistant conversations so future turns can continue with enough context."
      },
      {
        role = "user",
        content = self:get_compact_prompt(conversation:to_markdown())
      }
    },
    stream = false,
    temperature = 0.1,
    top_p = self.options.top_p_sampling
  }
end

---Build title payload.
---@param prompt string
---@return table payload
function Agent:build_title_payload(prompt)
  local payload = {
    model = self.model,
    messages = {
      {
        role = "system",
        content = table.concat({
          "Generate a concise title for this coding conversation.",
          "Base the title only on the user's first prompt.",
          "Return only the title text.",
          "Use 3 to 8 words.",
          "Do not use quotes, Markdown, punctuation at the end, or explanatory text."
        }, "\n")
      },
      {
        role = "user",
        content = tostring(prompt or "")
      }
    },
    stream = false,
    temperature = 0.1,
    top_p = self.options.top_p_sampling,
    max_tokens = 32
  }
  if self.model_metadata and self.model_metadata.chat_reasoning_effort then
    payload.reasoning_effort = "none"
  end
  return payload
end

---Parse title response.
---@param result table|string|nil
---@return string|nil title
function Agent:parse_title_response(result)
  local title = self:parse_response(result)
  title = tostring(title or "")
    :gsub("[\r\n]+", " ")
    :gsub("^%s+", "")
    :gsub("%s+$", "")
    :gsub('^["`]+', "")
    :gsub('["`]+$', "")
    :gsub("[%.,;:%!%?]+$", "")
  title = title:gsub("%s+", " ")
  if title == "" then return nil end
  if #title > 80 then
    title = title:sub(1, 80):gsub("%s+%S*$", ""):gsub("%s+$", "")
  end
  return title ~= "" and title or nil
end

---Handle decode arguments.
local function decode_arguments(arguments)
  if type(arguments) == "table" then return arguments, jsonutil.encode(arguments) end
  if type(arguments) ~= "string" then return {}, "" end
  local ok, decoded = pcall(json.decode, arguments)
  if not ok then decoded = nil end
  return type(decoded) == "table" and decoded or {}, arguments
end

---Handle arguments have tool params.
local function arguments_have_tool_params(arguments, params)
  if type(arguments) ~= "table" then return false end
  for _, param in ipairs(params or {}) do
    if arguments[param.name] ~= nil then return true end
  end
  return false
end

---Handle ensure executable arguments.
local function ensure_executable_arguments(call, tool)
  if type(call) ~= "table" then return end
  if arguments_have_tool_params(call.arguments, tool and tool.params) then return end
  local decoded = decode_arguments(call.arguments_text)
  if arguments_have_tool_params(decoded, tool and tool.params) then
    call.arguments = decoded
  end
end

---Handle valid arguments text.
local function valid_arguments_text(text)
  if type(text) ~= "string" or text == "" then return nil end
  local ok, decoded = pcall(json.decode, text)
  if not ok then return nil end
  if type(decoded) ~= "table" then return nil end
  return text
end

---Handle tool arguments text.
local function tool_arguments_text(call)
  return valid_arguments_text(call and call.arguments_text)
    or jsonutil.encode(call and call.arguments or {})
end

---Handle chat provider tool call.
local function chat_provider_tool_call(call)
  local raw = call and call.raw or {}
  local raw_fn = type(raw["function"]) == "table" and raw["function"] or {}
  return {
    id = raw.id or call.id,
    type = raw.type or "function",
    ["function"] = {
      name = raw_fn.name or call.name,
      arguments = tool_arguments_text(call)
    }
  }
end

---Handle trim.
local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

---Handle decode xml entities.
local function decode_xml_entities(text)
  if type(text) ~= "string" or text == "" then return text end
  for _ = 1, 2 do
    text = text
      :gsub("&amp;", "&")
      :gsub("&lt;", "<")
      :gsub("&gt;", ">")
      :gsub("&quot;", '"')
      :gsub("&#39;", "'")
      :gsub("&apos;", "'")
  end
  return text
end

---Handle insert text tool call.
local function insert_text_tool_call(parsed, name, body)
  local arguments = {}
  for key, value in body:gmatch("<parameter%s*=%s*['\"]?([%w_%.%-]+)['\"]?%s*>(.-)</parameter%s*>") do
    arguments[key] = trim(value)
  end
  for key, value in body:gmatch("<parameter%s+name%s*=%s*['\"]?([%w_%.%-]+)['\"]?%s*>(.-)</parameter%s*>") do
    arguments[key] = trim(value)
  end
  local id = string.format("call_text_%d", #parsed + 1)
  local arguments_text = jsonutil.encode(arguments)
  table.insert(parsed, {
    id = id,
    name = name,
    arguments = arguments,
    arguments_text = arguments_text,
    format = "chat-text",
    raw = {
      id = id,
      type = "function",
      ["function"] = {
        name = name,
        arguments = arguments_text
      }
    }
  })
end

---Parse text tool calls.
local function parse_text_tool_calls(content)
  local parsed = {}
  if type(content) ~= "string" or content == "" then return parsed end
  content = decode_xml_entities(content)
  content = content
    :gsub("<｜｜DSML｜｜tool_calls%s*>", "<tool_call>")
    :gsub("</｜｜DSML｜｜tool_calls%s*>", "</tool_call>")
    :gsub("<||DSML||tool_calls%s*>", "<tool_call>")
    :gsub("</||DSML||tool_calls%s*>", "</tool_call>")
    :gsub("<｜｜DSML｜｜invoke%s+", "<invoke ")
    :gsub("</｜｜DSML｜｜invoke%s*>", "</invoke>")
    :gsub("<||DSML||invoke%s+", "<invoke ")
    :gsub("</||DSML||invoke%s*>", "</invoke>")
  for body in content:gmatch("<tool_call%s*>(.-)</tool_call%s*>") do
    for name, function_body in body:gmatch("<function%s*=%s*['\"]?([%w_%.%-]+)['\"]?%s*>(.-)</function%s*>") do
      insert_text_tool_call(parsed, name, function_body)
    end
    for name, invoke_body in body:gmatch("<invoke%s+name%s*=%s*['\"]?([%w_%.%-]+)['\"]?%s*>(.-)</invoke%s*>") do
      insert_text_tool_call(parsed, name, invoke_body)
    end
  end
  content = content:gsub("<tool_call%s*>.-</tool_call%s*>", "")
  for name, body in content:gmatch("<function%s*=%s*['\"]?([%w_%.%-]+)['\"]?%s*>(.-)</function%s*>") do
    insert_text_tool_call(parsed, name, body)
  end
  for name, body in content:gmatch("<invoke%s+name%s*=%s*['\"]?([%w_%.%-]+)['\"]?%s*>(.-)</invoke%s*>") do
    insert_text_tool_call(parsed, name, body)
  end
  return parsed
end

---Parse text-encoded tool calls.
---@param content string|nil
---@return table[] calls
function Agent:parse_text_tool_calls(content)
  return parse_text_tool_calls(content)
end

---Parse tool calls.
---@param result table|nil
---@return table[] calls
function Agent:parse_tool_calls(result)
  if type(result) ~= "table" then return {} end
  local choice = result.choices and result.choices[1]
  local message = choice and choice.message
  local calls = message and message.tool_calls
  if type(calls) ~= "table" then
    return self:parse_text_tool_calls(message and message.content)
  end
  local parsed = {}
  for _, call in ipairs(calls) do
    local fn = type(call) == "table" and call["function"] or nil
    local name = fn and fn.name
    if name and name ~= "" then
      local args, args_text = decode_arguments(fn.arguments)
      table.insert(parsed, {
        id = call.id,
        name = name,
        arguments = args,
        arguments_text = args_text,
        format = "chat",
        raw = call
      })
    end
  end
  if #parsed == 0 then
    return self:parse_text_tool_calls(message and message.content)
  end
  return parsed
end

---Parse stream tool call deltas.
---@param data string|nil
---@return table[] deltas
---@return boolean done
function Agent:parse_stream_tool_call_deltas(data)
  if not data or data == "" or data == "[DONE]" then return {}, data == "[DONE]" end
  local decoded = json.decode(data)
  if type(decoded) ~= "table" then return {}, false end
  local choice = decoded.choices and decoded.choices[1]
  local delta = choice and choice.delta
  local calls = delta and delta.tool_calls
  if type(calls) ~= "table" then
    return {}, choice and choice.finish_reason == "tool_calls"
  end
  local parsed = {}
  for i, call in ipairs(calls) do
    local fn = type(call) == "table" and call["function"] or nil
    table.insert(parsed, {
      index = call.index or i - 1,
      id = call.id,
      type = call.type,
      name = fn and fn.name,
      arguments = fn and fn.arguments
    })
  end
  return parsed, choice and choice.finish_reason == "tool_calls"
end

---Handle supports stream tool calls.
---@return boolean
function Agent:supports_stream_tool_calls()
  return true
end

---Handle tool call display.
---@param call table
---@return string
function Agent:tool_call_display(call)
  local name = call and call.name or "unknown"
  local arguments = call and call.arguments_text
  if type(arguments) ~= "string" or arguments == "" then
    arguments = jsonutil.encode(call and call.arguments or {})
  end
  if #arguments > 8000 then
    arguments = arguments:sub(1, 8000) .. "\n\n... truncated for display ..."
  end
  return string.format(
    "Tool: %s\nArguments:\n%s",
    name,
    arguments
  )
end

---Handle tool result display.
---@param call table
---@param result any
---@param status string|nil
---@return string
function Agent:tool_result_display(call, result, status)
  result = self:tool_result_text(result)
  if #result > 12000 then
    result = result:sub(1, 12000) .. "\n\n... truncated for display ..."
  end
  return string.format(
    "Tool: %s\nStatus: %s\nResult:\n%s",
    call and call.name or "unknown",
    status or "ok",
    result
  )
end

---Compact tool result.
---@param call table
---@param result any
---@return string
function Agent:compact_tool_result(call, result)
  local text_result = self:tool_result_text(result)
  local conf = config.plugins and config.plugins.assistant or {}
  if conf.compact_tool_results ~= true then
    return text_result
  end
  local name = self:resolve_tool_name(call and call.name)
  local tool = self.tools[name or ""]
  if tool and tool.compact_result then
    local ok, compacted = pcall(tool.compact_result, call or {}, result, {
      agent = self,
      tool = tool
    })
    if ok and compacted ~= nil then return tostring(compacted) end
  end
  return Tool.compact_result(tool or {}, call or {}, text_result)
end

---Build a provider-only image context message for a structured tool result.
---@param call table
---@param result any
---@return table|nil message
function Agent:tool_result_image_context_message(call, result)
  if type(result) ~= "table" or type(result.attachments) ~= "table" then return nil end
  local attachment
  for _, item in ipairs(result.attachments) do
    if type(item) == "table" and item.type == "image" and item.data and item.mime_type then
      attachment = item
      break
    end
  end
  if not attachment then return nil end
  local image_url = self:image_url_for_attachment(attachment)
  local text = string.format(
    "Image context from `%s` read result: %s [%s] %sx%s.",
    call and call.name or "tool",
    attachment.path or "",
    attachment.mime_type or "image",
    tostring(attachment.width or ""),
    tostring(attachment.height or "")
  )
  if self.api_format == "responses" then
    return {
      role = "user",
      content = {
        { type = "input_text", text = text },
        { type = "input_image", image_url = image_url }
      }
    }
  end
  return {
    role = "user",
    content = {
      { type = "text", text = text },
      { type = "image_url", image_url = { url = image_url } }
    }
  }
end

---Build the image URL value expected by this provider.
---@param attachment table Image attachment with MIME type and base64 data.
---@return string image_url
function Agent:image_url_for_attachment(attachment)
  return string.format("data:%s;base64,%s", attachment.mime_type, attachment.data)
end

---Handle tool call provider message.
---@param calls table[]
---@param index integer|nil
---@return table|nil
function Agent:tool_call_provider_message(calls, index)
  if index and index ~= 1 then return nil end
  local tool_calls = {}
  for _, call in ipairs(calls or {}) do
    table.insert(tool_calls, chat_provider_tool_call(call))
  end
  local message = {
    role = "assistant",
    content = "",
    tool_calls = tool_calls
  }
  local reasoning = calls
    and calls[1]
    and calls[1]._assistant_provider_reasoning_content
  if type(reasoning) == "string"
    and reasoning ~= ""
    and self:should_persist_reasoning_content()
  then
    message.reasoning_content = reasoning
  end
  return message
end

---Handle tool result provider message.
---@param call table
---@param result any
---@param options table|nil
---@return table
function Agent:tool_result_provider_message(call, result, options)
  local name = call and call.name or "unknown"
  local compact = not (options and options.compact == false)
  local content = compact and self:compact_tool_result(call, result) or self:tool_result_text(result)
  return {
    role = "tool",
    tool_call_id = call.id,
    content = string.format(
      "Tool `%s` result:\n%s\n\nUse this result to answer the user. Do not call `%s` again with the same arguments unless the user asks for a fresh run or the result is insufficient.",
      name,
      content,
      name
    )
  }
end

---Handle tool result provider messages.
---@param call table
---@param result any
---@param options table|nil
---@return table[] messages
function Agent:tool_result_provider_messages(call, result, options)
  local messages = { self:tool_result_provider_message(call, result, options) }
  local include_images = not (options and options.include_images == false)
  local image_message = include_images and self:tool_result_image_context_message(call, result) or nil
  if image_message then table.insert(messages, image_message) end
  return messages
end

---Resolve tool name.
---@param name string
---@return string
function Agent:resolve_tool_name(name)
  if self.tools[name or ""] then return name end
  return name
end

---Execute tool.
---@param call table
---@return boolean ok
---@return string result
function Agent:execute_tool(call)
  local name = self:resolve_tool_name(call.name)
  local tool = self.tools[name or ""]
  if not tool or not tool.callback then
    return false, "unknown tool: " .. tostring(call.name)
  end
  call.name = name
  ensure_executable_arguments(call, tool)
  if name == "apply_patch"
    and history_normalizer.contains_omitted_tool_argument(call.arguments)
  then
    return false, "refusing to execute write tool with compacted historical placeholder content"
  end
  if (name == "edit" or name == "write")
    and history_normalizer.contains_omitted_tool_argument(call.arguments)
  then
    return false, "refusing to execute write tool with compacted historical placeholder content"
  end
  if name == "apply_patch" then
    local patch = call.arguments and call.arguments.patch
    if type(patch) ~= "string" or patch == "" then
      return false, "apply_patch missing patch argument; read the current target file or region, then send a complete patch"
    end
  end
  local args = {}
  local count = #(tool.params or {})
  for index, param in ipairs(tool.params or {}) do
    local value = call.arguments and call.arguments[param.name]
    args[index] = value
  end
  local ok, result, output = pcall(function()
    return tool_context.with_active_conversation(self._assistant_tool_conversation, function()
      return tool.callback(unpack(args, 1, count))
    end)
  end)
  if not ok then return false, result end
  if result == false then return false, output or "tool failed" end
  if result == true and output ~= nil then return true, output end
  return true, result ~= nil and result or ""
end

---Handle tool requires approval.
---@param call table
---@return boolean
function Agent:tool_requires_approval(call)
  return tool_router.tool_requires_approval(self, call, self._assistant_tool_conversation)
end

---Handle classify tool call.
---@param call table
---@param conversation assistant.Conversation|nil
---@return table classification
function Agent:classify_tool_call(call, conversation)
  return tool_router.classify_tool_call(self, call, conversation or self._assistant_tool_conversation)
end

---Return the models url.
---@return string
function Agent:get_models_url()
  return self.models_endpoint or "/v1/models"
end

---Parse models response.
---@param result table|nil
---@return string[] models
function Agent:parse_models_response(result)
  local models = {}
  if type(result) ~= "table" then return models end
  local data = result.data or result.models
  if type(data) == "table" then
    for _, item in ipairs(data) do
      if type(item) == "table" then
        table.insert(models, item.id or item.name or item.model)
      elseif type(item) == "string" then
        table.insert(models, item)
      end
    end
  end
  table.sort(models)
  return models
end

---Parse response.
---@param result table|string|nil
---@return string
function Agent:parse_response(result)
  if type(result) ~= "table" then return tostring(result or "") end
  local choice = result.choices and result.choices[1]
  if choice and choice.message then
    return choice.message.content or ""
  end
  if result.message then
    return result.message.content or result.message
  end
  if result.response then return result.response end
  if result.content then return result.content end
  return ""
end

---Parse provider reasoning_content from a complete response.
---@param result table|string|nil
---@return string|nil reasoning_content
function Agent:parse_reasoning_content(result)
  if type(result) ~= "table" then return nil end
  local choice = result.choices and result.choices[1]
  local message = choice and choice.message
  if type(message) == "table" then
    local reasoning = message.reasoning_content
      or message.reasoning
      or message.reasoning_text
    if type(reasoning) == "string" and reasoning ~= "" then return reasoning end
  end
  local msg = result.message
  if type(msg) == "table" then
    local reasoning = msg.reasoning_content or msg.reasoning or msg.reasoning_text
    if type(reasoning) == "string" and reasoning ~= "" then return reasoning end
  end
  return nil
end

---Parse usage.
---@param result table|nil
---@return table|nil usage
function Agent:parse_usage(result)
  if type(result) ~= "table" then return nil end
  local usage = result.usage or result.metrics
  if type(usage) ~= "table" then return nil end
  local input = usage.prompt_tokens
    or usage.input_tokens
    or usage.prompt_eval_count
    or usage.prompt_tokens_count
  local output = usage.completion_tokens
    or usage.output_tokens
    or usage.eval_count
    or usage.completion_tokens_count
  local total = usage.total_tokens or usage.totalTokens or usage.tokens
  if not total and (input or output) then
    total = (input or 0) + (output or 0)
  end
  if not (input or output or total) then return nil end
  return {
    input_tokens = input,
    output_tokens = output,
    total_tokens = total,
    context = usage.context
      or usage.context_window
      or usage.contextWindow
      or usage.model_context_window
      or usage.modelContextWindow
      or result.context
      or result.context_window
      or result.contextWindow
      or result.model_context_window
      or result.modelContextWindow
  }
end

---Parse stream event.
---@param data string|nil
---@return string|nil text
---@return boolean done
---@return table|nil usage
---@return table|string|nil error
---@return table|nil event
function Agent:parse_stream_event(data)
  if not data or data == "" or data == "[DONE]" then return nil, data == "[DONE]" end
  local json = require "core.json"
  local decoded = json.decode(data)
  if type(decoded) ~= "table" then return nil, false end
  if decoded.type == "error" or decoded.error then
    return nil, true, nil, decoded.error or decoded
  end
  local usage = self:parse_usage(decoded)
  local choice = decoded.choices and decoded.choices[1]
  if choice and choice.delta then
    local reasoning = choice.delta.reasoning_content
      or choice.delta.reasoning
      or choice.delta.reasoning_text
    if type(reasoning) == "string" and reasoning ~= "" then
      return nil, choice.finish_reason ~= nil, usage, nil, {
        type = "reasoning_delta",
        text = reasoning
      }
    end
    return choice.delta.content, choice.finish_reason ~= nil, usage
  end
  if choice and choice.message then
    return choice.message.content, choice.finish_reason ~= nil, usage
  end
  if decoded.message then
    return decoded.message.content, decoded.done == true, usage
  end
  if decoded.response then
    return decoded.response, decoded.done == true, usage
  end
  return nil, decoded.done == true, usage
end

return Agent
