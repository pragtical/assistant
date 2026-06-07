local common = require "core.common"
local Agent = require "plugins.assistant.agent"

---llama.cpp server OpenAI-compatible chat agent.
---@class assistant.agent.LlamaCpp : assistant.Agent
local LlamaCpp = Agent:extend()

---Create a new instance.
---@param options table|nil
function LlamaCpp:new(options)
  options = options or {}
  options.name = options.name or "llamacpp"
  options.display_name = options.display_name or "llama.cpp"
  options.backend = options.backend or "http"
  options.base_url = options.base_url or "http://127.0.0.1:8080"
  options.endpoint = options.endpoint or "/v1/chat/completions"
  options.model = options.model or "local-model"
  options.compact_implementation_tools = options.compact_implementation_tools ~= false
  options.model_metadata = common.merge({
    preferred_timeout_ms = 1800000,
    context_window = 16384,
    default_max_tokens = 8192,
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
    require_assistant_reasoning_content = true
  }, options.capabilities)
  self.super.new(self, options)
end

return LlamaCpp
