local common = require "core.common"
local Agent = require "plugins.assistant.agent"

---LM Studio OpenAI-compatible chat agent.
---@class assistant.agent.Lms : assistant.Agent
local Lms = Agent:extend()

---Create a new instance.
---@param options table|nil
function Lms:new(options)
  options = options or {}
  options.name = options.name or "lms"
  options.display_name = options.display_name or "LM Studio"
  options.backend = options.backend or "http"
  options.base_url = options.base_url or "http://127.0.0.1:1234"
  options.endpoint = options.endpoint or "/v1/chat/completions"
  options.model = options.model or "local-model"
  options.compact_implementation_tools = options.compact_implementation_tools ~= false
  options.model_metadata = common.merge({
    preferred_timeout_ms = 1800000,
    context_window = 16384,
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

return Lms
