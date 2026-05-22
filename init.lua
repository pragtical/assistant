-- mod-version: 3.10.1
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"

local Conversation = require "plugins.assistant.conversation"
local PromptView = require "plugins.assistant.promptview"
local tools = require "plugins.assistant.tools"
local ConversationsList = require "plugins.assistant.ui.conversationslist"
local MemoriesList = require "plugins.assistant.ui.memorieslist"
local HttpBackend = require "plugins.assistant.backend.http"
local CliBackend = require "plugins.assistant.backend.cli"
local AppServerBackend = require "plugins.assistant.backend.appserver"
local AcpBackend = require "plugins.assistant.backend.acp"
local Ollama = require "plugins.assistant.agent.ollama"
local LlamaCpp = require "plugins.assistant.agent.llamacpp"
local Lms = require "plugins.assistant.agent.lms"
local OpenAI = require "plugins.assistant.agent.openai"
local Codex = require "plugins.assistant.agent.codex"
local Acp = require "plugins.assistant.agent.acp"
local Copilot = require "plugins.assistant.agent.copilot"

config.plugins.assistant = common.merge({
  agent = "ollama",
  backend = "http",
  model = "",
  base_url = "",
  api_key = "",
  api_key_env = "",
  codex_command = "",
  acp_command = "",
  acp_transport = "stdio",
  acp_host = "127.0.0.1",
  acp_port = 0,
  copilot_command = "",
  keep_alive = "-1",
  debug = false,
  log_protocol = false,
  log_raw_messages = true,
  verbose_tool_calling = false,
  verbose_activity = false,
  reasoning_activity_messages = true,
  raw_markdown_line_wrapping = true,
  compact_tool_results = false,
  compact_tool_history = false,
  generate_conversation_titles = true,
  stream = true,
  request_timeout_ms = 1800000,
  max_tool_call_rounds = 0,
  max_repeated_tool_calls = 4,
  send_max_tokens = false,
  send_max_tokens_amount = 65536,
  reasoning_effort = "low",
  fetch_model_metadata = true,
  auto_compact = true,
  auto_compact_threshold = 0.85,
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
      default = "ollama",
      values = {
        { "Ollama", "ollama" },
        { "llama.cpp", "llamacpp" },
        { "LM Studio", "lms" },
        { "OpenAI", "openai" },
        { "Codex", "codex" },
        { "ACP", "acp" },
        { "GitHub Copilot", "copilot" }
      }
    },
    {
      label = "Model",
      description = "Model name sent to the provider. Leave empty for provider default.",
      path = "model",
      type = "string"
    },
    {
      label = "Base URL",
      description = "Provider base URL. Leave empty for provider default.",
      path = "base_url",
      type = "string"
    },
    {
      label = "API Key",
      description = "Provider API key. Leave empty to use the environment variable instead.",
      path = "api_key",
      type = "string"
    },
    {
      label = "API key environment variable",
      description = "Environment variable containing the API key, if needed.",
      path = "api_key_env",
      type = "string"
    },
    {
      label = "Codex Command",
      description = "Path to the codex executable. Leave empty to search PATH and common user bin directories.",
      path = "codex_command",
      type = "string"
    },
    {
      label = "ACP Command",
      description = "Command for generic ACP agents. Presets may ignore this.",
      path = "acp_command",
      type = "string"
    },
    {
      label = "ACP Transport",
      description = "Transport for generic ACP agents.",
      path = "acp_transport",
      type = "selection",
      default = "stdio",
      values = {
        { "stdio", "stdio" },
        { "tcp", "tcp" }
      }
    },
    {
      label = "ACP Host",
      description = "Host for TCP ACP agents.",
      path = "acp_host",
      type = "string",
      default = "127.0.0.1"
    },
    {
      label = "ACP Port",
      description = "Port for TCP ACP agents.",
      path = "acp_port",
      type = "number",
      default = 0
    },
    {
      label = "Copilot Command",
      description = "Path to the GitHub Copilot executable. Leave empty to use `copilot --acp --stdio`.",
      path = "copilot_command",
      type = "string"
    },
    {
      label = "Keep Alive",
      description = "Only applies to agents that support keep-alive. Controls how long capable providers keep models loaded after requests. Use -1 to keep loaded indefinitely, 0 to unload immediately, or durations like 30s, 1m, 30m, 1h.",
      path = "keep_alive",
      type = "string",
      default = "-1"
    },
    {
      label = "Stream Responses",
      description = "Use Server-Sent Events streaming when supported.",
      path = "stream",
      type = "toggle",
      default = true
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
      min = 0.5,
      max = 0.98
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
end

---Remove a registered assistant agent class.
---@param name string
function assistant.unregister_agent(name)
  assistant.agents[name] = nil
end

---Return an agent class by name or the configured default.
---@param name string?
---@return assistant.AgentClass?
function assistant.get_agent(name)
  return assistant.agents[name or config.plugins.assistant.agent]
end

---Return registered assistant agents for UI selection.
---@return table[] agents Agent choices with `name`, `label`, and `default` fields.
function assistant.list_agents()
  local configured_name = config.plugins.assistant.agent
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

---Return a backend class by name or the configured default.
---@param name string?
---@return assistant.BackendClass?
function assistant.get_backend(name)
  return assistant.backends[name or config.plugins.assistant.backend]
end

---Handle configured agent.
---@param name string?
---@return assistant.Agent
local function configured_agent(name)
  local cls = assistant.get_agent(name)
  local agent = cls and cls() or Ollama()
  local conf = config.plugins.assistant
  agent:configure(conf)
  return tools.register_agent_tools(agent)
end

---Handle configured backend.
---@param name string?
---@return assistant.Backend
local function configured_backend(name)
  local cls = assistant.get_backend(name)
  return cls and cls() or HttpBackend()
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
  local backend = configured_backend(agent.backend)
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
  agent.model = conversation.model or agent.model
  conversation.backend = agent.backend
  return open_prompt_view(PromptView({
    conversation = conversation,
    agent = agent,
    backend = configured_backend(agent.backend)
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
  local backend = configured_backend(agent.backend)
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

assistant.register_agent("ollama", Ollama)
assistant.register_agent("llamacpp", LlamaCpp)
assistant.register_agent("lms", Lms)
assistant.register_agent("openai", OpenAI)
assistant.register_agent("codex", Codex)
assistant.register_agent("acp", Acp)
assistant.register_agent("copilot", Copilot)
assistant.register_backend("http", HttpBackend)
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
    core.command_view:enter("Assistant Session ID", {
      submit = function(id)
        assistant.resume_conversation(id)
      end
    })
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
