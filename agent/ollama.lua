local common = require "core.common"
local Agent = require "plugins.assistant.agent"

---Ollama OpenAI-compatible chat agent.
---@class assistant.agent.Ollama : assistant.Agent
local Ollama = Agent:extend()

---Create a new instance.
---@param options table|nil
function Ollama:new(options)
  options = options or {}
  options.name = options.name or "ollama"
  options.display_name = options.display_name or "Ollama"
  options.backend = options.backend or "http"
  options.base_url = options.base_url or "http://127.0.0.1:11434"
  options.endpoint = options.endpoint or "/v1/chat/completions"
  options.models_endpoint = options.models_endpoint or "/v1/models"
  options.stream_format = options.stream_format or "sse"
  options.model = options.model or "llama3.1"
  options.keep_alive = options.keep_alive or "-1"
  options.compact_implementation_tools = options.compact_implementation_tools ~= false
  options.model_metadata = common.merge({
    preferred_timeout_ms = 1800000,
    context_window = 16384,
    max_output_tokens = 65536,
    chat_reasoning_effort = true,
    stream_tool_calls = true,
    parallel_tool_calls = false,
    reports_usage = true
  }, options.model_metadata)
  options.capabilities = common.merge({
    reports_usage = true,
    collaboration_modes = true,
    stream_responses = true,
    tool_calling = true,
    keep_alive = true,
    local_compact = true,
    vision = true
  }, options.capabilities)
  self.super.new(self, options)
  self.keep_alive = options.keep_alive
end

---Build payload.
---@param conversation assistant.Conversation
---@return table payload
function Ollama:build_payload(conversation)
  local payload = Ollama.super.build_payload(self, conversation)
  payload.keep_alive = self.keep_alive
  return payload
end

---Parse models response.
---@param result table|nil
---@return string[] models
function Ollama:parse_models_response(result)
  return Ollama.super.parse_models_response(self, result)
end

---Return the model metadata url.
---@return string
function Ollama:get_model_metadata_url()
  return "/api/show"
end

---Build model metadata payload.
---@return table payload
function Ollama:build_model_metadata_payload()
  return {
    model = self.model,
    verbose = false
  }
end

---Parse num ctx.
local function parse_num_ctx(parameters)
  if type(parameters) ~= "string" then return nil end
  return tonumber(parameters:match("num_ctx%s+(%d+)"))
end

---Parse context length.
local function parse_context_length(model_info)
  if type(model_info) ~= "table" then return nil end
  local direct = tonumber(model_info.context_length)
  if direct then return direct end
  for key, value in pairs(model_info) do
    if type(key) == "string" and key:match("%.context_length$") then
      local number = tonumber(value)
      if number then return number end
    end
  end
end

---Parse model metadata.
---@param result table|nil
---@return table|nil metadata
function Ollama:parse_model_metadata(result)
  if type(result) ~= "table" then return nil end
  local allocated_context = parse_num_ctx(result.parameters)
  local context_window = allocated_context or parse_context_length(result.model_info)
  if not context_window then return nil end
  return {
    context_window = context_window,
    allocated_context_window = allocated_context,
    model_context_window = parse_context_length(result.model_info)
  }
end

---Parse usage.
---@param result table|nil
---@return table|nil usage
function Ollama:parse_usage(result)
  if type(result) ~= "table" then return nil end
  local input = result.prompt_eval_count
  local output = result.eval_count
  if not (input or output) then
    return Ollama.super.parse_usage(self, result)
  end
  return {
    input_tokens = input,
    output_tokens = output,
    total_tokens = (input or 0) + (output or 0),
    context = result.context
      or result.context_window
      or result.contextWindow
      or result.model_context_window
      or result.modelContextWindow
      or (type(result.model_info) == "table" and (
        result.model_info["llama.context_length"]
        or result.model_info["general.context_length"]
        or result.model_info.context_length
      ))
  }
end

return Ollama
