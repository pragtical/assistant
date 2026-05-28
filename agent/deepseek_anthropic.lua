local common = require "core.common"
local Anthropic = require "plugins.assistant.agent.anthropic"

---DeepSeek Anthropic-compatible Messages API agent.
---@class assistant.agent.DeepSeekAnthropic : assistant.agent.Anthropic
local DeepSeekAnthropic = Anthropic:extend()

local DEFAULT_REASONING_EFFORT = "low"
local DEEPSEEK_ANTHROPIC_REASONING_EFFORT_VALUES = {
  low = true,
  medium = true,
  high = true
}

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
  options.default_reasoning_effort = options.default_reasoning_effort or DEFAULT_REASONING_EFFORT
  options.model_metadata = common.merge({
    preferred_timeout_ms = 300000,
    context_window = 1048576,
    stream_tool_calls = true,
    parallel_tool_calls = false,
    reports_usage = true,
    default_max_tokens = 8192,
    max_output_tokens = 393216
  }, options.model_metadata)
  options.capabilities = common.merge({
    reports_usage = true,
    collaboration_modes = true,
    stream_responses = true,
    tool_calling = true,
    local_compact = true,
    vision = false
  }, options.capabilities)
  Anthropic.super.new(self, options)
  self.default_reasoning_effort = options.default_reasoning_effort
end

---Return whether this agent has an explicit reasoning effort setting.
---@return boolean
function DeepSeekAnthropic:has_explicit_reasoning_effort()
  return type(self.reasoning_effort) == "string"
    and not self.reasoning_effort_inherited
    and self.reasoning_effort:match("^%s*(.-)%s*$") ~= ""
end

---Return the configured DeepSeek Anthropic reasoning effort.
---@return string|nil effort
function DeepSeekAnthropic:configured_deepseek_reasoning_effort()
  if self:has_explicit_reasoning_effort() then
    local effort = self.reasoning_effort:match("^%s*(.-)%s*$")
    if effort == "none" then return nil end
    if DEEPSEEK_ANTHROPIC_REASONING_EFFORT_VALUES[effort] then return effort end
  end
  return self.default_reasoning_effort or DEFAULT_REASONING_EFFORT
end

---Return the reasoning effort that should be shown in the UI.
---@return string|nil
function DeepSeekAnthropic:display_reasoning_effort()
  return self:configured_deepseek_reasoning_effort()
end

---Return whether a payload replays provider thinking blocks.
---@param payload table
---@return boolean
local function payload_replays_thinking(payload)
  for _, message in ipairs(payload.messages or {}) do
    if type(message.content) == "table" then
      for _, block in ipairs(message.content) do
        if type(block) == "table" and block.type == "thinking" then
          return true
        end
      end
    end
  end
  return false
end

---Remove provider thinking blocks from replayed Anthropic messages.
---@param payload table
local function strip_replayed_thinking(payload)
  for _, message in ipairs(payload.messages or {}) do
    if type(message.content) == "table" then
      local content = {}
      for _, block in ipairs(message.content) do
        if not (type(block) == "table" and block.type == "thinking") then
          table.insert(content, block)
        end
      end
      message.content = content
    end
  end
end

---Build payload.
---@param conversation assistant.Conversation
---@return table payload
function DeepSeekAnthropic:build_payload(conversation)
  local payload = DeepSeekAnthropic.super.build_payload(self, conversation)
  local reasoning_effort = self:configured_deepseek_reasoning_effort()
  if reasoning_effort and reasoning_effort ~= "none" then
    payload.output_config = { effort = reasoning_effort }
    payload.thinking = { type = "enabled" }
  else
    if payload_replays_thinking(payload) then
      strip_replayed_thinking(payload)
    end
    payload.thinking = { type = "disabled" }
  end
  return payload
end

---Build title payload.
---@param prompt string
---@return table payload
function DeepSeekAnthropic:build_title_payload(prompt)
  local payload = DeepSeekAnthropic.super.build_title_payload(self, prompt)
  payload.thinking = { type = "disabled" }
  payload.output_config = nil
  return payload
end

return DeepSeekAnthropic
