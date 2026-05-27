local common = require "core.common"
local Anthropic = require "plugins.assistant.agent.anthropic"

---DeepSeek Anthropic-compatible Messages API agent.
---@class assistant.agent.DeepSeekAnthropic : assistant.agent.Anthropic
local DeepSeekAnthropic = Anthropic:extend()

---Create a new instance.
---@param options table|nil
function DeepSeekAnthropic:new(options)
  options = options or {}
  options.name = options.name or "deepseek_anthropic"
  options.display_name = options.display_name or "DeepSeek Anthropic"
  options.backend = options.backend or "anthropic"
  options.base_url = options.base_url or "https://api.deepseek.com/anthropic"
  options.endpoint = options.endpoint or "/v1/messages"
  options.models_endpoint = options.models_endpoint or "/v1/models"
  options.api_format = options.api_format or "anthropic-messages"
  options.stream_format = options.stream_format or "anthropic-sse"
  options.model = options.model or "deepseek-v4-pro"
  options.api_key_env = options.api_key_env or "DEEPSEEK_API_KEY"
  options.model_metadata = common.merge({
    preferred_timeout_ms = 300000,
    context_window = 65536,
    stream_tool_calls = true,
    parallel_tool_calls = false,
    reports_usage = true,
    default_max_tokens = 8192,
    max_output_tokens = 8192
  }, options.model_metadata)
  options.capabilities = common.merge({
    reports_usage = true,
    collaboration_modes = true,
    stream_responses = true,
    tool_calling = true,
    local_compact = true
  }, options.capabilities)
  Anthropic.super.new(self, options)
end

---Build payload.
---@param conversation assistant.Conversation
---@return table payload
function DeepSeekAnthropic:build_payload(conversation)
  local payload = DeepSeekAnthropic.super.build_payload(self, conversation)
  local reasoning_effort = self:configured_reasoning_effort()
  if reasoning_effort then
    payload.output_config = { effort = reasoning_effort }
    if reasoning_effort == "none" then
      payload.thinking = { type = "disabled" }
    else
      payload.thinking = {
        type = "enabled",
        budget_tokens = 1024
      }
    end
  end
  return payload
end

return DeepSeekAnthropic
