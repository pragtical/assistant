local common = require "core.common"
local Agent = require "plugins.assistant.agent"

---DeepSeek OpenAI-compatible chat agent.
---@class assistant.agent.DeepSeek : assistant.Agent
local DeepSeek = Agent:extend()

---Create a new instance.
---@param options table|nil
function DeepSeek:new(options)
  options = options or {}
  options.name = options.name or "deepseek"
  options.display_name = options.display_name or "DeepSeek"
  options.backend = options.backend or "http"
  options.base_url = options.base_url or "https://api.deepseek.com"
  options.endpoint = options.endpoint or "/v1/chat/completions"
  options.models_endpoint = options.models_endpoint or "/v1/models"
  options.model = options.model or "deepseek-chat"
  options.api_key_env = options.api_key_env or "DEEPSEEK_API_KEY"
  options.compact_implementation_tools = options.compact_implementation_tools ~= false
  options.model_metadata = common.merge({
    preferred_timeout_ms = 300000,
    context_window = 65536,
    default_max_tokens = 8192,
    max_output_tokens = 8192,
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
    keep_reasoning_content = true
  }, options.capabilities)
  self.super.new(self, options)
end

return DeepSeek
