local common = require "core.common"
local config = require "core.config"
local Agent = require "plugins.assistant.agent"

---DeepSeek OpenAI-compatible chat agent.
---@class assistant.agent.DeepSeek : assistant.Agent
local DeepSeek = Agent:extend()

local DEFAULT_REASONING_EFFORT = "low"
local DEEPSEEK_REASONING_EFFORT_VALUES = {
  low = true,
  medium = true,
  high = true,
  max = true,
  xhigh = true
}

local function sorted_keys(map)
  local keys = {}
  for key in pairs(map or {}) do
    if type(key) == "string" then table.insert(keys, key) end
  end
  table.sort(keys)
  return keys
end

local function clone_schema(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for key, item in pairs(value) do
    copy[key] = clone_schema(item)
  end
  return copy
end

local function is_empty_object_schema(schema)
  if type(schema) ~= "table" or schema.type ~= "object" then return false end
  return type(schema.properties) ~= "table" or next(schema.properties) == nil
end

local function normalize_strict_schema(schema)
  schema = clone_schema(schema or {})
  if type(schema.properties) == "table" then
    local originally_required = {}
    for _, name in ipairs(schema.required or {}) do
      originally_required[name] = true
    end
    for name, property in pairs(schema.properties) do
      if is_empty_object_schema(property) and not originally_required[name] then
        schema.properties[name] = nil
      else
        schema.properties[name] = normalize_strict_schema(property)
      end
    end
    local required = sorted_keys(schema.properties)
    schema.required = required
    schema.additionalProperties = false
  end
  if type(schema.items) == "table" then
    schema.items = normalize_strict_schema(schema.items)
  elseif schema.type == "array" then
    schema.items = { type = "string" }
  end
  if type(schema.anyOf) == "table" then
    for index, item in ipairs(schema.anyOf) do
      schema.anyOf[index] = normalize_strict_schema(item)
    end
  end
  if type(schema.oneOf) == "table" then
    for index, item in ipairs(schema.oneOf) do
      schema.oneOf[index] = normalize_strict_schema(item)
    end
  end
  return schema
end

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
  options.default_reasoning_effort = options.default_reasoning_effort or DEFAULT_REASONING_EFFORT
  options.strict_tools = options.strict_tools == true
  options.compact_implementation_tools = options.compact_implementation_tools ~= false
  options.model_metadata = common.merge({
    preferred_timeout_ms = 300000,
    context_window = 1048576,
    default_max_tokens = 8192,
    max_output_tokens = 393216,
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
    keep_reasoning_content = false
  }, options.capabilities)
  self.super.new(self, options)
  self.default_reasoning_effort = options.default_reasoning_effort
  self.strict_tools = options.strict_tools
end

---Handle provider-specific configuration.
---@param conf table
function DeepSeek:configure_provider(conf)
  if type(conf) ~= "table" then return end
  if conf.strict_tools ~= nil then
    self.strict_tools = conf.strict_tools == true
  end
  if self.strict_tools
    and self.base_url == "https://api.deepseek.com"
  then
    self.base_url = "https://api.deepseek.com/beta"
    self.endpoint = "/chat/completions"
    self.models_endpoint = "/models"
  end
end

---Return whether this agent was explicitly configured for reasoning.
---@return boolean explicit
function DeepSeek:has_explicit_reasoning_effort()
  return type(self.reasoning_effort) == "string"
    and not self.reasoning_effort_inherited
    and self.reasoning_effort:match("^%s*(.-)%s*$") ~= ""
end

---Return the configured DeepSeek reasoning effort.
---@return string|nil effort
function DeepSeek:configured_deepseek_reasoning_effort()
  if self:has_explicit_reasoning_effort() then
    local effort = self.reasoning_effort:match("^%s*(.-)%s*$")
    if DEEPSEEK_REASONING_EFFORT_VALUES[effort] then return effort end
  end
  return self.default_reasoning_effort or DEFAULT_REASONING_EFFORT
end

---Build payload.
---@param conversation assistant.Conversation
---@return table payload
function DeepSeek:build_payload(conversation)
  local payload = DeepSeek.super.build_payload(self, conversation)
  payload.reasoning_effort = self:configured_deepseek_reasoning_effort()
  return payload
end

---Handle generate tools info.
---@param selected string[]|nil
---@return table[]|nil tools
function DeepSeek:generate_tools_info(selected)
  local result = DeepSeek.super.generate_tools_info(self, selected)
  if self.strict_tools then
    for _, item in ipairs(result or {}) do
      if type(item["function"]) == "table" then
        item["function"].strict = true
        item["function"].parameters = normalize_strict_schema(item["function"].parameters)
      end
    end
  end
  return result
end

---Build title payload.
---@param prompt string
---@return table payload
function DeepSeek:build_title_payload(prompt)
  local payload = DeepSeek.super.build_title_payload(self, prompt)
  payload.reasoning_effort = self:configured_deepseek_reasoning_effort()
  return payload
end

---Return whether provider reasoning_content should be persisted and replayed.
---@return boolean
function DeepSeek:should_persist_reasoning_content()
  local conf = config.plugins and config.plugins.assistant or {}
  return conf.persist_reasoning_content == true
    or self:configured_deepseek_reasoning_effort() ~= nil
end

return DeepSeek
