local core = require "core"
local config = require "core.config"

---Per-agent provider configuration.
---@class assistant.agent.config
---@field model? string Default model for this agent.
---@field base_url? string HTTP base URL for HTTP-compatible agents.
---@field api_key? string Direct API key value for providers that support it.
---@field api_key_env? string Environment variable containing an API key.
---@field command? string|string[] Provider command or executable path.
---@field transport? string ACP transport, such as `"stdio"` or `"tcp"`.
---@field host? string ACP TCP host.
---@field port? integer ACP TCP port.
---@field keep_alive? string Provider keep-alive value for capable agents.
---@field reasoning_effort? "none"|"low"|"medium"|"high" Agent reasoning effort.

local agent_config = {}

local REASONING_EFFORT_VALUES = {
  { "Default", "" },
  { "None", "none" },
  { "Low", "low" },
  { "Medium", "medium" },
  { "High", "high" }
}

local DEFAULTS = {
  ollama = {
    model = "llama3.1",
    base_url = "http://127.0.0.1:11434",
    keep_alive = "-1"
  },
  llamacpp = {
    model = "local-model",
    base_url = "http://127.0.0.1:8080"
  },
  lms = {
    model = "local-model",
    base_url = "http://127.0.0.1:1234"
  },
  openai = {
    model = "gpt-4.1",
    base_url = "https://api.openai.com",
    api_key_env = "OPENAI_API_KEY"
  },
  codex = {
    model = "",
    command = "codex"
  },
  acp = {
    model = "",
    command = {},
    transport = "stdio",
    host = "127.0.0.1",
    port = 0
  },
  copilot = {
    model = "",
    command = "copilot"
  },
  anthropic = {
    model = "claude-sonnet-4-20250514",
    base_url = "https://api.anthropic.com",
    api_key_env = "ANTHROPIC_API_KEY"
  },
  deepseek = {
    model = "deepseek-chat",
    base_url = "https://api.deepseek.com",
    api_key_env = "DEEPSEEK_API_KEY"
  }
}

local AGENT_SPECS = {
  {
    key = "ollama",
    name = "Ollama",
    fields = {
      { label = "Model", path = "model", type = "string", default = DEFAULTS.ollama.model },
      { label = "Base URL", path = "base_url", type = "string", default = DEFAULTS.ollama.base_url },
      { label = "Keep Alive", path = "keep_alive", type = "string", default = DEFAULTS.ollama.keep_alive },
      { label = "Reasoning Effort", path = "reasoning_effort", type = "selection", values = REASONING_EFFORT_VALUES }
    }
  },
  {
    key = "llamacpp",
    name = "llama.cpp",
    fields = {
      { label = "Model", path = "model", type = "string", default = DEFAULTS.llamacpp.model },
      { label = "Base URL", path = "base_url", type = "string", default = DEFAULTS.llamacpp.base_url },
      { label = "Reasoning Effort", path = "reasoning_effort", type = "selection", values = REASONING_EFFORT_VALUES }
    }
  },
  {
    key = "lms",
    name = "LM Studio",
    fields = {
      { label = "Model", path = "model", type = "string", default = DEFAULTS.lms.model },
      { label = "Base URL", path = "base_url", type = "string", default = DEFAULTS.lms.base_url },
      { label = "Reasoning Effort", path = "reasoning_effort", type = "selection", values = REASONING_EFFORT_VALUES }
    }
  },
  {
    key = "openai",
    name = "OpenAI",
    fields = {
      { label = "Model", path = "model", type = "string", default = DEFAULTS.openai.model },
      { label = "Base URL", path = "base_url", type = "string", default = DEFAULTS.openai.base_url },
      { label = "API Key Environment", path = "api_key_env", type = "string", default = DEFAULTS.openai.api_key_env },
      { label = "API Key", path = "api_key", type = "string" },
      { label = "Reasoning Effort", path = "reasoning_effort", type = "selection", values = REASONING_EFFORT_VALUES }
    }
  },
  {
    key = "codex",
    name = "Codex",
    fields = {
      { label = "Model", path = "model", type = "string", default = DEFAULTS.codex.model },
      { label = "Command", path = "command", type = "string", default = DEFAULTS.codex.command },
      { label = "Reasoning Effort", path = "reasoning_effort", type = "selection", values = REASONING_EFFORT_VALUES }
    }
  },
  {
    key = "acp",
    name = "ACP",
    fields = {
      { label = "Model", path = "model", type = "string", default = DEFAULTS.acp.model },
      { label = "Command", path = "command", type = "list_strings", default = DEFAULTS.acp.command },
      { label = "Transport", path = "transport", type = "selection", default = DEFAULTS.acp.transport, values = {
        { "stdio", "stdio" },
        { "tcp", "tcp" }
      } },
      { label = "Host", path = "host", type = "string", default = DEFAULTS.acp.host },
      { label = "Port", path = "port", type = "number", default = DEFAULTS.acp.port, min = 0, max = 65535 },
      { label = "Reasoning Effort", path = "reasoning_effort", type = "selection", values = REASONING_EFFORT_VALUES }
    }
  },
  {
    key = "copilot",
    name = "GitHub Copilot",
    fields = {
      { label = "Model", path = "model", type = "string", default = DEFAULTS.copilot.model },
      { label = "Command", path = "command", type = "string", default = DEFAULTS.copilot.command },
      { label = "Reasoning Effort", path = "reasoning_effort", type = "selection", values = REASONING_EFFORT_VALUES }
    }
  },
  {
    key = "anthropic",
    name = "Anthropic",
    fields = {
      { label = "Model", path = "model", type = "string", default = DEFAULTS.anthropic.model },
      { label = "Base URL", path = "base_url", type = "string", default = DEFAULTS.anthropic.base_url },
      { label = "API Key Environment", path = "api_key_env", type = "string", default = DEFAULTS.anthropic.api_key_env },
      { label = "API Key", path = "api_key", type = "string" },
      { label = "Reasoning Effort", path = "reasoning_effort", type = "selection", values = REASONING_EFFORT_VALUES }
    }
  },
  {
    key = "deepseek",
    name = "DeepSeek",
    fields = {
      { label = "Model", path = "model", type = "string", default = DEFAULTS.deepseek.model },
      { label = "Base URL", path = "base_url", type = "string", default = DEFAULTS.deepseek.base_url },
      { label = "API Key Environment", path = "api_key_env", type = "string", default = DEFAULTS.deepseek.api_key_env },
      { label = "API Key", path = "api_key", type = "string" },
      { label = "Reasoning Effort", path = "reasoning_effort", type = "selection", values = REASONING_EFFORT_VALUES }
    }
  }
}

---Deep-copy a table value.
---@generic T
---@param value T
---@return T
local function clone(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do
    result[key] = clone(item)
  end
  return result
end

---Merge tables recursively without mutating inputs.
---@param ... table?
---@return table
local function deep_merge(...)
  local result = {}
  local args = table.pack(...)
  for index = 1, args.n do
    local source = args[index]
    if source ~= nil then
      assert(type(source) == "table", string.format("argument %d must be a table", index))
      for key, value in pairs(source) do
        if type(value) == "table" then
          result[key] = deep_merge(type(result[key]) == "table" and result[key] or {}, value)
        else
          result[key] = value
        end
      end
    end
  end
  return result
end

---Return default per-agent configuration.
---@return table<string, assistant.agent.config>
function agent_config.defaults()
  return clone(DEFAULTS)
end

---Return a generated settings spec for built-in assistant agents.
---@return settings.config_spec spec
function agent_config.config_spec()
  local sections = {}
  for _, spec in ipairs(AGENT_SPECS) do
    local options = {}
    for _, field in ipairs(spec.fields) do
      local option = clone(field)
      option.path = spec.key .. "." .. field.path
      table.insert(options, option)
    end
    table.insert(sections, {
      name = spec.name,
      options = options
    })
  end
  return {
    name = "Assistant Agent Settings",
    path_prefix = "agents",
    sections = sections
  }
end

---Merge options into the configured table for an agent.
---@param name string
---@param options assistant.agent.config
---@return boolean ok
function agent_config.configure(name, options)
  if type(name) ~= "string" or name == "" then
    core.error("Assistant: configure_agent requires an agent name")
    return false
  end
  if type(options) ~= "table" then
    core.error("Assistant: configure_agent requires a config table for %s", tostring(name))
    return false
  end
  local conf = config.plugins.assistant
  conf.agents = type(conf.agents) == "table" and conf.agents or {}
  conf.agents[name] = deep_merge(conf.agents[name] or {}, options)
  return true
end

---Resolve effective configuration for an agent.
---@param name string
---@param conf table?
---@return assistant.agent.config
function agent_config.resolve(name, conf)
  conf = conf or config.plugins.assistant or {}
  local agents = type(conf.agents) == "table" and conf.agents or {}
  local resolved = deep_merge(DEFAULTS[name] or {}, type(agents[name]) == "table" and agents[name] or {})
  if resolved.reasoning_effort == nil or resolved.reasoning_effort == "" then
    resolved.reasoning_effort = conf.reasoning_effort
  end
  resolved.stream = conf.stream
  return resolved
end

---Apply effective per-agent configuration to an agent instance.
---@param agent assistant.Agent
---@param conf table?
---@return assistant.Agent agent
function agent_config.apply(agent, conf)
  return agent:configure(agent_config.resolve(agent.name, conf))
end

---Return a resolved agent config for inspection.
---@param name string
---@return assistant.agent.config?
function agent_config.get(name)
  if type(name) ~= "string" or name == "" then return nil end
  local conf = config.plugins.assistant or {}
  local agents = type(conf.agents) == "table" and conf.agents or {}
  if DEFAULTS[name] == nil and type(agents[name]) ~= "table" then return nil end
  return agent_config.resolve(name)
end

---Return a generated settings spec for a single agent.
---@param agent_name string
---@return settings.config_spec|nil spec
function agent_config.get_agent_spec(agent_name)
  if type(agent_name) ~= "string" or agent_name == "" then return nil end
  for _, spec in ipairs(AGENT_SPECS) do
    if spec.key == agent_name then
      local options = {}
      for _, field in ipairs(spec.fields) do
        local option = clone(field)
        option.path = agent_name .. "." .. field.path
        table.insert(options, option)
      end
      return {
        name = spec.name,
        path_prefix = "agents",
        table.unpack(options)
      }
    end
  end
  return nil
end

return agent_config
