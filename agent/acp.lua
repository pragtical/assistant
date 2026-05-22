local common = require "core.common"
local Agent = require "plugins.assistant.agent"

---Agent adapter for ACP-compatible providers.
---@class assistant.agent.Acp : assistant.Agent
---@field public command string[]|table
---@field public transport "stdio"|"tcp"|string
---@field public host string?
---@field public port integer?
---@field public env table?
---@field public client_capabilities table
local Acp = Agent:extend()

---Create a new instance.
---@param options table?
function Acp:new(options)
  options = options or {}
  options.name = options.name or "acp"
  options.display_name = options.display_name or "ACP"
  options.backend = options.backend or "acp"
  options.model = options.model or ""
  options.capabilities = common.merge({
    reports_usage = true,
    reports_context = true,
    compact = false,
    delete_conversation = false,
    list_conversations = true,
    rename_conversation = false,
    collaboration_modes = true,
    user_input_requests = true,
    approval_requests = true,
    stream_responses = true,
    tool_calling = false
  }, options.capabilities)
  Agent.new(self, options)
  self.command = options.command or {}
  self.transport = options.transport or "stdio"
  self.host = options.host
  self.port = options.port
  self.env = options.env
  self.client_capabilities = common.merge({
    fs = {
      readTextFile = true,
      writeTextFile = true
    },
    terminal = true
  }, options.client_capabilities or {})
end

---Handle configure provider.
---@param conf table
function Acp:configure_provider(conf)
  if type(conf.command) == "table" then
    self.command = conf.command
  elseif conf.command and conf.command ~= "" then
    self.command = { conf.command }
  end
  if conf.transport and conf.transport ~= "" then
    self.transport = conf.transport
  end
  if conf.host and conf.host ~= "" then
    self.host = conf.host
  end
  if conf.port and tonumber(conf.port) and tonumber(conf.port) > 0 then
    self.port = tonumber(conf.port)
  end
end

---Return the collaboration modes.
---@return table[]
function Acp:get_collaboration_modes()
  return self.collaboration_modes or {
    { id = "implementation", label = "Implementation" },
    { id = "plan", label = "Plan" }
  }
end

---Handle mode suffix.
---@param mode any
---@return string
local function mode_suffix(mode)
  mode = tostring(mode or "")
  return mode:match("#([^#]+)$") or mode
end

---Handle semantic mode.
---@param mode any
---@return string?
local function semantic_mode(mode)
  local suffix = mode_suffix(mode)
  if suffix == "agent" or suffix == "default" then return "implementation" end
  if suffix == "plan" then return "plan" end
  if suffix == "autopilot" then return "autopilot" end
  if mode == "implementation" then return "implementation" end
  return mode ~= "" and mode or nil
end

---Handle find advertised mode.
---@param agent assistant.agent.Acp
---@param wanted string
---@return string?
local function find_advertised_mode(agent, wanted)
  local modes = agent and agent.collaboration_modes
  if type(modes) ~= "table" then return nil end
  for _, option in ipairs(modes) do
    local id = type(option) == "table" and (option.id or option.mode or option.name) or option
    if semantic_mode(id) == wanted then return id end
  end
end

---Build collaboration mode.
---@param mode string|table?
---@return string|table|nil
function Acp:build_collaboration_mode(mode)
  local semantic = semantic_mode(mode)
  local advertised = semantic and find_advertised_mode(self, semantic) or nil
  if advertised then return advertised end

  local option = self.collaboration_modes_by_id and self.collaboration_modes_by_id[mode] or nil
  if type(option) == "table" then
    return option.id or option.mode or mode
  end

  if semantic == "implementation" then
    return "implementation"
  end
  if semantic == "plan" then
    return "plan"
  end
  if semantic == "autopilot" then
    return "autopilot"
  end
  return mode
end

---Normalize collaboration mode.
---@param mode string|table?
---@return string?
function Acp:normalize_collaboration_mode(mode)
  if type(mode) == "table" then
    mode = mode.id or mode.mode or mode.name
  end
  return semantic_mode(mode)
end

---Parse usage.
---@param result table
---@return table?
function Acp:parse_usage(result)
  if type(result) ~= "table" then return nil end
  local usage = result.usage or result.tokenUsage or result.token_usage or result
  local context = result.modelContextWindow
    or result.model_context_window
    or result.contextWindow
    or result.context_window
    or result.context
  local cumulative
  if type(result.tokenUsage) == "table" then
    cumulative = result.tokenUsage.total
    usage = result.tokenUsage.last or result.tokenUsage.total or result.tokenUsage
    context = result.tokenUsage.modelContextWindow or result.tokenUsage.contextWindow or context
  elseif type(result.token_usage) == "table" then
    cumulative = result.token_usage.total
    usage = result.token_usage.last or result.token_usage.total or result.token_usage
    context = result.token_usage.model_context_window or result.token_usage.context_window or context
  end
  if type(usage) ~= "table" then return nil end
  local input = usage.input_tokens or usage.inputTokens or usage.prompt_tokens or usage.promptTokens
  local output = usage.output_tokens or usage.outputTokens or usage.completion_tokens or usage.completionTokens
  local total = usage.total_tokens or usage.totalTokens
  if not total and (input or output) then
    total = (input or 0) + (output or 0)
  end
  if not (input or output or total) then return nil end
  return {
    input_tokens = input,
    output_tokens = output,
    total_tokens = total,
    cumulative_input_tokens = cumulative and (cumulative.input_tokens or cumulative.inputTokens),
    cumulative_output_tokens = cumulative and (cumulative.output_tokens or cumulative.outputTokens),
    cumulative_total_tokens = cumulative and (cumulative.total_tokens or cumulative.totalTokens),
    context = context
  }
end

return Acp
