-- mod-version: 3.11
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"

local HAS_NET = rawget(_G, "net") ~= nil

local Conversation = require "plugins.assistant.conversation"
local PromptView = require "plugins.assistant.promptview"
local tools = require "plugins.assistant.tools"
local agent_config = require "plugins.assistant.agent_config"
local ConversationsList = require "plugins.assistant.ui.conversationslist"
local MemoriesList = require "plugins.assistant.ui.memorieslist"
local CliBackend = require "plugins.assistant.backend.cli"
local AppServerBackend = require "plugins.assistant.backend.appserver"
local AcpBackend = require "plugins.assistant.backend.acp"
local Codex = require "plugins.assistant.agent.codex"
local Acp = require "plugins.assistant.agent.acp"
local Copilot = require "plugins.assistant.agent.copilot"
local HttpBackend = HAS_NET and require "plugins.assistant.backend.http" or nil
local AnthropicBackend = HAS_NET and require "plugins.assistant.backend.anthropic" or nil
local Ollama = HAS_NET and require "plugins.assistant.agent.ollama" or nil
local LlamaCpp = HAS_NET and require "plugins.assistant.agent.llamacpp" or nil
local Lms = HAS_NET and require "plugins.assistant.agent.lms" or nil
local OpenAI = HAS_NET and require "plugins.assistant.agent.openai" or nil
local Anthropic = HAS_NET and require "plugins.assistant.agent.anthropic" or nil
local DeepSeek = HAS_NET and require "plugins.assistant.agent.deepseek" or nil
local DeepSeekAnthropic = HAS_NET and require "plugins.assistant.agent.deepseek_anthropic" or nil

if not HAS_NET then
  core.warn(
    "Assistant: Pragtical net module is disabled; HTTP providers and web tools are unavailable."
  )
end

local AGENT_CHOICES = {
  { "Codex", "codex" },
  { "ACP", "acp" },
  { "GitHub Copilot", "copilot" }
}

if HAS_NET then
  AGENT_CHOICES = {
    { "Ollama", "ollama" },
    { "llama.cpp", "llamacpp" },
    { "LM Studio", "lms" },
    { "OpenAI", "openai" },
    { "Codex", "codex" },
    { "ACP", "acp" },
    { "GitHub Copilot", "copilot" },
    { "Anthropic", "anthropic" },
    { "DeepSeek", "deepseek" },
    { "DeepSeek Anthropic", "deepseek_anthropic" }
  }
end

config.plugins.assistant = common.merge({
  agent = HAS_NET and "ollama" or "codex",
  backend = HAS_NET and "http" or "appserver",
  agents = agent_config.defaults(),
  debug = false,
  log_protocol = false,
  log_raw_messages = true,
  verbose_tool_calling = false,
  verbose_activity = false,
  reasoning_activity_messages = true,
  persist_reasoning_content = true,
  raw_markdown_line_wrapping = true,
  compact_tool_results = false,
  compact_tool_history = false,
  generate_conversation_titles = true,
  stream = false,
  request_timeout_ms = 1800000,
  max_tool_call_rounds = 0,
  max_repeated_tool_calls = 4,
  send_max_tokens = false,
  send_max_tokens_amount = 65536,
  reasoning_effort = "low",
  fetch_model_metadata = true,
  auto_compact = true,
  auto_compact_threshold = 0.85,
  auto_compact_min_input_tokens = 50000,
  auto_compact_max_input_tokens = 200000,
  auto_compact_min_new_messages = 4,
  auto_save = true,
  prompt_height = 140,
  confirm_writes = true,
  allow_any_read_path = false,
  web_search_url = "https://search.brave.com/search",
  web_search_query_param = "q",
  web_search_results_path = "",
  web_timeout_ms = 10000,
  web_allow_hosts = {},
  config_spec = {
    name = "Assistant",
    {
      label = "Agent",
      description = "Default assistant provider.",
      path = "agent",
      type = "selection",
      default = HAS_NET and "ollama" or "codex",
      values = AGENT_CHOICES
    },
    {
      label = "Agent Settings",
      description = "Configure provider-specific model, endpoint, command, and reasoning options.",
      type = "subconfig",
      title = "Assistant Agent Settings",
      spec = agent_config.config_spec()
    },
    {
      label = "Stream Responses",
      description = "Use Server-Sent Events streaming when supported.",
      path = "stream",
      type = "toggle",
      default = false
    },
    {
      label = "Allow Any Read Path",
      description = "Allow read-only assistant tools to read outside loaded project roots without asking. Writes, patches, deletes, and commands remain project-root restricted.",
      path = "allow_any_read_path",
      type = "toggle",
      default = false
    },
    {
      label = "Web Search URL",
      description = "Optional search page or JSON endpoint used by the assistant web_search tool. Leave empty to disable web_search.",
      path = "web_search_url",
      type = "string",
      default = "https://search.brave.com/search"
    },
    {
      label = "Web Search Query Parameter",
      description = "Query parameter name used when calling the configured web search endpoint.",
      path = "web_search_query_param",
      type = "string",
      default = "q"
    },
    {
      label = "Request Timeout",
      description = "Timeout in milliseconds for assistant provider chat requests.",
      path = "request_timeout_ms",
      type = "number",
      default = 1800000
    },
    {
      label = "Max Tool Call Rounds",
      description = "Maximum model/tool continuation rounds allowed for a single assistant turn. Set to 0 to rely on manual cancellation instead of a round cap.",
      path = "max_tool_call_rounds",
      type = "number",
      default = 0,
      min = 0,
      max = 512
    },
    {
      label = "Max Repeated Tool Calls",
      description = "Maximum identical tool calls allowed in one assistant turn before stopping the turn as a loop.",
      path = "max_repeated_tool_calls",
      type = "number",
      default = 4,
      min = 1,
      max = 64
    },
    {
      label = "Send Max Tokens",
      description = "Send a max_tokens limit with OpenAI-compatible chat requests. Disabled by default so providers use their own output limits.",
      path = "send_max_tokens",
      type = "toggle",
      default = false
    },
    {
      label = "Max Tokens Amount",
      description = "The max_tokens value to send when Send Max Tokens is enabled.",
      path = "send_max_tokens_amount",
      type = "number",
      default = 65536,
      min = 1
    },
    {
      label = "Compact Tool Results",
      description = "Compact tool results before sending them back to HTTP/OpenAI-compatible models - experimental.",
      path = "compact_tool_results",
      type = "toggle",
      default = false
    },
    {
      label = "Compact Tool History",
      description = "Compact historical tool call/result messages before provider requests - experimental.",
      path = "compact_tool_history",
      type = "toggle",
      default = false
    },
    {
      label = "Reasoning Effort",
      description = "Reasoning effort sent to OpenAI Responses and supported OpenAI-compatible chat providers.",
      path = "reasoning_effort",
      type = "selection",
      default = "low",
      values = {
        { "None", "none" },
        { "Low", "low" },
        { "Medium", "medium" },
        { "High", "high" }
      }
    },
    {
      label = "Auto Compact",
      description = "Automatically compact local HTTP conversations before sending when reported context usage is near the model window.",
      path = "auto_compact",
      type = "toggle",
      default = true
    },
    {
      label = "Auto Compact Threshold",
      description = "Fraction of the model context window used before automatic local compaction runs.",
      path = "auto_compact_threshold",
      type = "number",
      default = 0.85,
      min = 0.01,
      max = 0.98
    },
    {
      label = "Auto Compact Min Input Tokens",
      description = "Minimum reported input/context tokens required before automatic local compaction can run.",
      path = "auto_compact_min_input_tokens",
      type = "number",
      default = 50000,
      min = 0
    },
    {
      label = "Auto Compact Max Input Tokens",
      description = "Reported input/context token ceiling that triggers automatic local compaction even before the context threshold is reached. Set 0 to disable.",
      path = "auto_compact_max_input_tokens",
      type = "number",
      default = 200000,
      min = 0
    },
    {
      label = "Web Timeout",
      description = "Timeout in milliseconds for assistant web tools.",
      path = "web_timeout_ms",
      type = "number",
      default = 10000,
      min = 1000,
      max = 60000
    },
    {
      label = "Debug Logging",
      description = "Log general assistant backend diagnostics for troubleshooting.",
      path = "debug",
      type = "toggle",
      default = false
    },
    {
      label = "Raw Message Logging",
      description = "Record per-conversation raw client requests and provider responses for View Raw Responses. Disable to reduce memory and disk usage.",
      path = "log_raw_messages",
      type = "toggle",
      default = true
    },
    {
      label = "Verbose Tool Calling",
      description = "Show full tool call and tool result sections in conversation transcripts.",
      path = "verbose_tool_calling",
      type = "toggle",
      default = false
    },
    {
      label = "Verbose Activity",
      description = "Show activity messages as full Activity sections instead of compact one-line summaries.",
      path = "verbose_activity",
      type = "toggle",
      default = false
    },
    {
      label = "Reasoning Activity Messages",
      description = "Show streamed reasoning and thought text as activity messages in conversation transcripts.",
      path = "reasoning_activity_messages",
      type = "toggle",
      default = true
    },
    {
      label = "Persist Reasoning Content",
      description = "Persist and resend provider reasoning_content for HTTP/OpenAI-compatible chat agents.",
      path = "persist_reasoning_content",
      type = "toggle",
      default = true
    },
    {
      label = "Raw Markdown Line Wrapping",
      description = "Visually wrap the raw markdown transcript using Pragtical's linewrapping plugin.",
      path = "raw_markdown_line_wrapping",
      type = "toggle",
      default = true
    },
    {
      label = "Generate Conversation Titles",
      description = "Generate a concise title from the first user prompt without adding the title request to conversation context.",
      path = "generate_conversation_titles",
      type = "toggle",
      default = true
    },
    {
      label = "Protocol Logging",
      description = "Log raw assistant backend requests and responses for troubleshooting.",
      path = "log_protocol",
      type = "toggle",
      default = false
    },
    {
      label = "Prompt Height",
      description = "Height in pixels for the prompt editor.",
      path = "prompt_height",
      type = "number",
      default = 140,
      min = 80,
      max = 500
    }
  }
}, config.plugins.assistant)

---Assistant plugin module.
---@alias assistant.AgentClass fun(options?: table): assistant.Agent
---@alias assistant.BackendClass fun(name?: string): assistant.Backend
---
---@class assistant
---@field agents table<string, assistant.AgentClass>
---@field backends table<string, assistant.BackendClass>
local assistant = {
  agents = {},
  backends = {}
}

---Register an assistant agent class.
---@param name string
---@param agent assistant.AgentClass
function assistant.register_agent(name, agent)
  assistant.agents[name] = agent
  PromptView.register_agent(name, agent)
end

---Remove a registered assistant agent class.
---@param name string
function assistant.unregister_agent(name)
  assistant.agents[name] = nil
  PromptView.unregister_agent(name)
end

---Configure provider-specific defaults for an assistant agent.
---@param name string Agent id, such as `"ollama"` or `"openai"`.
---@param options assistant.agent.config Agent-specific configuration values.
---@return boolean ok True when the configuration was merged.
function assistant.configure_agent(name, options)
  return agent_config.configure(name, options)
end

---Return the resolved configuration for an assistant agent.
---@param name string Agent id.
---@return assistant.agent.config? config Effective configuration, or nil for invalid names.
function assistant.get_agent_config(name)
  return agent_config.get(name)
end

---Return an agent class by name or the configured default.
---@param name string?
---@return assistant.AgentClass?
function assistant.get_agent(name)
  return assistant.agents[name or config.plugins.assistant.agent]
end

---Return the preferred available agent name.
---@return string?
local function default_agent_name()
  local preferred = config.plugins.assistant.agent
  if assistant.agents[preferred] then return preferred end
  for _, name in ipairs({ "codex", "copilot", "acp" }) do
    if assistant.agents[name] then return name end
  end
  for name in pairs(assistant.agents) do
    return name
  end
end

---Return registered assistant agents for UI selection.
---@return table[] agents Agent choices with `name`, `label`, and `default` fields.
function assistant.list_agents()
  local configured_name = default_agent_name()
  local choices = {}
  for name, cls in pairs(assistant.agents) do
    local label = name
    if type(cls) == "table" and type(cls.display_name) == "string" then
      label = cls.display_name
    elseif type(cls) == "function" or type(cls) == "table" then
      local ok, agent = pcall(function() return cls() end)
      if ok and type(agent) == "table" and type(agent.display_name) == "string" then
        label = agent.display_name
      end
    end
    table.insert(choices, {
      name = name,
      label = label,
      default = name == configured_name
    })
  end
  table.sort(choices, function(a, b)
    if a.default ~= b.default then return a.default end
    return tostring(a.label):lower() < tostring(b.label):lower()
  end)
  return choices
end

---Register a communication backend class.
---@param name string
---@param backend assistant.BackendClass
function assistant.register_backend(name, backend)
  assistant.backends[name] = backend
  PromptView.register_backend(name, backend)
end

---Return a backend class by name or the configured default.
---@param name string?
---@return assistant.BackendClass?
function assistant.get_backend(name)
  return assistant.backends[name or config.plugins.assistant.backend]
end

---Handle configured agent.
---@param name string?
---@return assistant.Agent?
local function configured_agent(name)
  local requested = name or config.plugins.assistant.agent
  local cls = assistant.get_agent(requested)
  if not cls then
    if name then
      core.error(
        "Assistant: agent '%s' is unavailable%s",
        tostring(name),
        HAS_NET and "" or " because the Pragtical net module is disabled"
      )
      return nil
    end
    requested = default_agent_name()
    cls = requested and assistant.agents[requested] or nil
  end
  if not cls then
    core.error("Assistant: no assistant agents are registered")
    return nil
  end
  local agent = cls()
  agent_config.apply(agent, config.plugins.assistant)
  return tools.register_agent_tools(agent)
end

---Handle configured backend.
---@param name string?
---@return assistant.Backend?
local function configured_backend(name)
  local cls = assistant.get_backend(name)
  if not cls then
    core.error(
      "Assistant: backend '%s' is unavailable%s",
      tostring(name or config.plugins.assistant.backend),
      HAS_NET and "" or " because the Pragtical net module is disabled"
    )
    return nil
  end
  return cls()
end

---Register an assistant tool contributed by another plugin.
---
---The spec uses the same fields as `plugins.assistant.tool`, including
---callback/build functions, schema params, approval hooks, compaction hooks,
---activity rendering hooks, and history-success detection.
---@param name string Tool name exposed to models.
---@param spec assistant.ToolSpec Full assistant tool specification.
---@return boolean ok True when the tool was registered.
function assistant.register_tool(name, spec)
  if type(name) ~= "string" or name == "" then
    core.error("Assistant: register_tool requires a tool name")
    return false
  end
  if type(spec) ~= "table" then
    core.error("Assistant: register_tool requires a tool spec for %s", name)
    return false
  end
  spec.name = name
  local ok, err = tools.register_external_tool(name, spec)
  if not ok then
    core.error("Assistant: could not register tool %s: %s", name, tostring(err))
    return false
  end
  return true
end

---Remove an assistant tool contributed by another plugin.
---@param name string Tool name previously passed to `assistant.register_tool`.
---@return boolean removed True when a registered external tool was removed.
function assistant.unregister_tool(name)
  if type(name) ~= "string" or name == "" then
    core.error("Assistant: unregister_tool requires a tool name")
    return false
  end
  return tools.unregister_external_tool(name)
end

---Open prompt view.
---@param view assistant.PromptView
---@return assistant.PromptView
local function open_prompt_view(view)
  local node = core.root_view:get_active_node_default()
  node:add_view(view)
  core.root_view.root_node:update_layout()
  view.focused_child = view.prompt
  core.set_active_view(view.prompt)
  return view
end

---Open a new assistant conversation view.
---@param agent_name string?
---@return assistant.PromptView
function assistant.start_conversation(agent_name)
  local agent = configured_agent(agent_name)
  if not agent then return end
  local backend = configured_backend(agent.backend)
  if not backend then return end
  return open_prompt_view(PromptView({ agent = agent, backend = backend }))
end

---Open a new assistant conversation after selecting an agent.
---@return assistant.PromptView?
function assistant.select_agent_new_conversation()
  local choices = assistant.list_agents()
  if #choices == 0 then
    core.error("Assistant: no agents are registered")
    return
  end
  if #choices == 1 then
    return assistant.start_conversation(choices[1].name)
  end

  local suggestions = {}
  local by_text = {}
  for _, choice in ipairs(choices) do
    local item = {
      text = choice.label,
      name = choice.name,
      info = choice.default and "Default agent" or choice.name
    }
    table.insert(suggestions, item)
    by_text[choice.name] = item
    by_text[choice.label] = item
  end

  local function matching_suggestion(text, suggestion)
    return suggestion or by_text[tostring(text or "")]
  end

  core.command_view:enter("Assistant Agent", {
    show_suggestions = true,
    typeahead = true,
    suggest = function()
      return suggestions
    end,
    validate = function(text, suggestion)
      return matching_suggestion(text, suggestion) ~= nil
    end,
    submit = function(text, suggestion)
      local item = matching_suggestion(text, suggestion)
      if item then
        assistant.start_conversation(item.name)
      end
    end
  })
end

local function conversation_suggestion_text(item)
  local title = tostring(item.title or item.name or item.preview or "Assistant Session")
  local updated = tostring(item.updated_at or item.created_at or "")
  if updated ~= "" then
    return title .. " - " .. updated
  end
  return title
end

local function conversation_suggestion_info(item)
  local parts = {}
  if item.agent and item.agent ~= "" then table.insert(parts, item.agent) end
  if item.model and item.model ~= "" then table.insert(parts, item.model) end
  if item.id and item.id ~= "" then table.insert(parts, item.id) end
  return table.concat(parts, "  ")
end

local function conversation_picker_items(project_dir)
  local suggestions = {}
  local captions = {}
  local by_text = {}
  local by_id = {}
  for index, item in ipairs(Conversation.list(project_dir)) do
    local text = conversation_suggestion_text(item)
    if by_text[text] then
      text = text .. " - " .. tostring(item.id or index)
    end
    local suggestion = {
      text = text,
      info = conversation_suggestion_info(item),
      id = item.id,
      item = item
    }
    table.insert(suggestions, suggestion)
    table.insert(captions, text)
    by_text[text] = suggestion
    if item.id and item.id ~= "" then by_id[tostring(item.id)] = suggestion end
  end
  return suggestions, captions, by_text, by_id
end

---Prompt for a saved assistant conversation and resume it.
---@param project_dir string?
function assistant.select_resume_conversation(project_dir)
  project_dir = project_dir or core.root_project().path
  local suggestions, captions, by_text, by_id = conversation_picker_items(project_dir)
  if #suggestions == 0 then
    core.warn("Assistant: no saved conversations for %s", project_dir)
    return
  end

  local function matching_suggestion(text, suggestion)
    text = tostring(text or "")
    return suggestion or by_id[text] or by_text[text]
  end

  core.command_view:enter("Assistant Session", {
    show_suggestions = true,
    typeahead = true,
    suggest = function(text)
      text = tostring(text or "")
      if text == "" then return suggestions end
      local result = {}
      for _, caption in ipairs(common.fuzzy_match(captions, text, true)) do
        table.insert(result, by_text[caption])
      end
      return result
    end,
    validate = function(text, suggestion)
      return matching_suggestion(text, suggestion) ~= nil
    end,
    submit = function(text, suggestion)
      local selected = matching_suggestion(text, suggestion)
      if selected then
        assistant.resume_conversation(selected.id, project_dir)
      end
    end
  })
end

---Open a saved assistant conversation.
---@param id string
---@param project_dir string?
---@return assistant.PromptView?
function assistant.resume_conversation(id, project_dir)
  local conversation = Conversation.load(id, project_dir or core.root_project().path)
  if not conversation then
    core.error("Assistant: could not load conversation %s", tostring(id))
    return
  end
  local agent = configured_agent(conversation.agent)
  if not agent then return end
  agent.model = conversation.model or agent.model
  conversation.backend = agent.backend
  local backend = configured_backend(agent.backend)
  if not backend then return end
  return open_prompt_view(PromptView({
    conversation = conversation,
    agent = agent,
    backend = backend
  }))
end

---Open a conversation list item.
---@param item table
---@param project_dir string?
---@return assistant.PromptView?
function assistant.open_conversation_item(item, project_dir)
  return assistant.resume_conversation(item.id, project_dir)
end

---Persist a conversation to disk.
---@param conversation assistant.Conversation?
---@return boolean?
function assistant.save_conversation(conversation)
  return conversation and conversation:save()
end

---Delete a saved conversation from disk.
---@param id string
---@param project_dir string?
---@param callback fun(deleted: boolean)?
---@return boolean deleted
function assistant.delete_conversation(id, project_dir, callback)
  project_dir = project_dir or core.root_project().path
  local deleted = Conversation.delete(id, project_dir)
  if deleted then
    core.log("Assistant: deleted conversation %s", id)
  else
    core.warn("Assistant: conversation not found: %s", id)
  end
  if callback then callback(deleted) end
  return deleted
end

---Open the saved conversation list.
---@param project_dir string?
---@return assistant.ui.ConversationsList
function assistant.list_conversations(project_dir)
  project_dir = project_dir or core.root_project().path
  local view = ConversationsList(project_dir, function(item)
    assistant.open_conversation_item(item, project_dir)
  end, function(item, delete_project_dir, callback)
    assistant.delete_conversation(item.id, delete_project_dir, callback)
  end)
  local node = core.root_view:get_active_node_default()
  node:add_view(view)
  core.root_view.root_node:update_layout()
  return view
end

---Open the saved memories list.
---@param project_dir string?
---@return assistant.ui.MemoriesList
function assistant.list_memories(project_dir)
  project_dir = project_dir or core.root_project().path
  local view = MemoriesList(project_dir, function(item, list_view)
    local editor = MemoriesList.MemoryEditor(project_dir, item, function()
      list_view:refresh()
    end)
    local node = core.root_view:get_active_node_default()
    node:add_view(editor)
    core.root_view.root_node:update_layout()
  end, function(item, delete_project_dir, callback)
    local deleted = Conversation.delete_memory(delete_project_dir, item.id)
    if deleted then
      core.log("Assistant: deleted memory %s", item.id)
    else
      core.warn("Assistant: memory not found: %s", item.id)
    end
    if callback then callback(deleted) end
  end)
  local node = core.root_view:get_active_node_default()
  node:add_view(view)
  core.root_view.root_node:update_layout()
  return view
end

---Return path relative to the active project when possible.
---@param filename string
---@return string
local function prompt_file_path(filename)
  local project = core.current_project(filename) or core.root_project()
  local info = system.get_file_info(filename)
  local is_dir = info and info.type == "dir"
  local trailing_sep = is_dir and PATHSEP or ""
  if project and common.path_belongs_to(filename, project.path) then
    return common.relative_path(project.path, filename):gsub(PATHSEP .. "$", "") .. trailing_sep
  end
  return common.home_encode(filename):gsub(PATHSEP .. "$", "") .. trailing_sep
end

---Insert selected project file path into a conversation prompt.
---@param view assistant.PromptView
---@param filename string
---@param line? integer
local function insert_project_file_path(view, filename, line)
  local text = prompt_file_path(filename)
  if line then
    text = string.format("%s:%d", text, line)
  end
  view.prompt_doc:text_input(text)
  core.set_active_view(view.prompt)
end

---Log the model list for an agent.
---@param agent_name string?
function assistant.list_models(agent_name)
  local agent = configured_agent(agent_name)
  if not agent then return end
  local backend = configured_backend(agent.backend)
  if not backend then return end
  backend:list_models(agent, function(ok, err, models)
    if not ok then
      core.error("Assistant: could not list models: %s", err or "unknown error")
      return
    end
    if not models or #models == 0 then
      core.log("Assistant: no models reported by %s", agent.display_name or agent.name)
      return
    end
    core.log("Assistant models from %s:", agent.display_name or agent.name)
    for _, model in ipairs(models) do
      core.log("  %s", model)
    end
  end)
end

if HAS_NET then
  assistant.register_agent("ollama", Ollama)
  assistant.register_agent("llamacpp", LlamaCpp)
  assistant.register_agent("lms", Lms)
  assistant.register_agent("openai", OpenAI)
end
assistant.register_agent("codex", Codex)
assistant.register_agent("acp", Acp)
assistant.register_agent("copilot", Copilot)
if HAS_NET then
  assistant.register_agent("anthropic", Anthropic)
  assistant.register_agent("deepseek", DeepSeek)
  assistant.register_agent("deepseek_anthropic", DeepSeekAnthropic)
  assistant.register_backend("http", HttpBackend)
  assistant.register_backend("anthropic", AnthropicBackend)
end
assistant.register_backend("cli", CliBackend)
assistant.register_backend("appserver", AppServerBackend)
assistant.register_backend("acp", AcpBackend)

command.add(nil, {
  ["assistant:new-conversation"] = function()
    assistant.start_conversation()
  end,

  ["assistant:select-agent-new-conversation"] = function()
    assistant.select_agent_new_conversation()
  end,

  ["assistant:list-conversations"] = function()
    assistant.list_conversations()
  end,

  ["assistant:list-models"] = function()
    assistant.list_models()
  end,

  ["assistant:resume-conversation"] = function()
    assistant.select_resume_conversation()
  end,

  ["assistant:delete-conversation"] = function()
    core.command_view:enter("Delete Assistant Session ID", {
      submit = function(id)
        assistant.delete_conversation(id, core.root_project().path)
      end
    })
  end,

  ["assistant:add-memory"] = function()
    core.command_view:enter("Assistant Memory", {
      submit = function(text)
        local item = Conversation.add_memory(core.root_project().path, "Memory", text)
        if item then
          core.log("Assistant: added memory %s", item.id)
        end
      end
    })
  end,

  ["assistant:list-memories"] = function()
    assistant.list_memories()
  end,

  ["assistant:delete-memory"] = function()
    core.command_view:enter("Delete Assistant Memory ID", {
      submit = function(id)
        if Conversation.delete_memory(core.root_project().path, id) then
          core.log("Assistant: deleted memory %s", id)
        else
          core.warn("Assistant: memory not found: %s", id)
        end
      end
    })
  end
})

command.add(PromptView.active_predicate, {
  ["assistant-conversation:send"] = function(view)
    view:submit()
  end
})

command.add(PromptView.active_predicate, {
  ["assistant-conversation:select-model"] = function(view)
    view:open_model_dialog()
  end,
  ["assistant-conversation:configure-agent"] = function(view)
    view:configure_agent()
  end,
  ["assistant-conversation:cancel"] = function(view)
    view:cancel()
  end,
  ["assistant-conversation:save"] = function(view)
    view:save_conversation()
  end,
  ["assistant-conversation:view-raw-responses"] = function(view)
    view:view_raw_responses()
  end,
  ["assistant-conversation:view-raw-markdown"] = function(view)
    view:view_raw_markdown()
  end,
  ["assistant-conversation:view-rendered-markdown"] = function(view)
    view:view_rendered_markdown()
  end,
  ["assistant-conversation:clear-prompt"] = function(view)
    view:clear_prompt()
  end,
  ["assistant-conversation:cycle-mode"] = function(view)
    view:cycle_collaboration_mode()
  end,
  ["assistant-conversation:respond-to-request"] = function(view)
    view:respond_to_pending_request()
  end,
  ["assistant-conversation:insert-file"] = function(view)
    command.perform("core:open-file", "Insert File", function(filename)
      insert_project_file_path(view, filename)
    end, true)
  end,
  ["assistant-conversation:insert-project-file"] = function(view)
    command.perform("core:find-file", "Insert Project File", function(filename, line)
      insert_project_file_path(view, filename, line)
    end)
  end,
  ["assistant-conversation:rename"] = function(view)
    core.command_view:enter("Conversation Title", {
      submit = function(title)
        view:rename_conversation(title)
      end
    })
  end
})

command.add(PromptView.compact_predicate, {
  ["assistant-conversation:compact"] = function(view)
    view:compact()
  end
})

keymap.add {
  ["ctrl+alt+a"] = "assistant:new-conversation",
  ["ctrl+shift+alt+a"] = "assistant:select-agent-new-conversation",
  ["ctrl+enter"] = "assistant-conversation:send",
  ["ctrl+return"] = "assistant-conversation:send",
  ["ctrl+m"] = "assistant-conversation:select-model",
  ["shift+tab"] = "assistant-conversation:cycle-mode",
  ["escape"] = "assistant-conversation:cancel",
  ["ctrl+alt+enter"] = "assistant-conversation:respond-to-request",
  ["ctrl+alt+return"] = "assistant-conversation:respond-to-request",
  ["ctrl+alt+u"] = "assistant-conversation:insert-file",
  ["ctrl+shift+u"] = "assistant-conversation:insert-project-file",
  ["ctrl+backspace"] = "assistant-conversation:clear-prompt"
}

return assistant
