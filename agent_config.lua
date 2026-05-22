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

return agent_config
