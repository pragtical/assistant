local test = require "core.test"
dofile("tests/helper.inc")
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local core = require "core"
local keymap = require "core.keymap"
local settings = require "plugins.settings"
local Conversation = require "plugins.assistant.conversation"
local Ollama = require "plugins.assistant.agent.ollama"
local PromptView = require "plugins.assistant.promptview"
local agent_config = require "plugins.assistant.agent_config"

local assistant = dofile("init.lua")

local root = assistant_test_temp_path("assistant-init")

local function mkdirp(path)
  local info = system.get_file_info(path)
  if info and info.type == "dir" then return end
  common.mkdirp(path)
end

local function has_value(values, expected)
  for _, value in ipairs(values or {}) do
    if value == expected then return true end
  end
  return false
end

local function find_option(options, label)
  for _, option in ipairs(options or {}) do
    if option.label == label then return option end
  end
end

local function find_section(sections, name)
  for _, section in ipairs(sections or {}) do
    if section.name == name then return section end
  end
end

test.describe("assistant plugin init", function()
  local old_projects
  local old_active_view
  local old_open_file
  local old_find_file
  local old_core_error
  local old_command_view_enter
  local old_agent_config
  local old_agents_config
  local old_start_conversation

  test.before_each(function()
    old_projects = core.projects
    old_active_view = core.active_view
    old_open_file = command.map["core:open-file"]
    old_find_file = command.map["core:find-file"]
    old_core_error = core.error
    old_command_view_enter = core.command_view.enter
    old_agent_config = config.plugins.assistant.agent
    old_agents_config = config.plugins.assistant.agents
    config.plugins.assistant.agents = {}
    old_start_conversation = assistant.start_conversation
    assistant.unregister_tool("external_test_tool")
    assistant.unregister_tool("external_invalid_tool")
    assistant.unregister_agent("external_agent")
    common.rm(root, true)
    mkdirp(root .. PATHSEP .. "src")
    core.projects = {
      {
        path = root,
        absolute_path = function(_, path)
          if common.is_absolute_path(path) then return path end
          return root .. PATHSEP .. path
        end,
        path_belongs_to = function(_, filename)
          return common.path_belongs_to(filename, root)
        end
      }
    }
  end)

  test.after_each(function()
    core.projects = old_projects
    core.set_active_view(old_active_view)
    core.error = old_core_error
    core.command_view.enter = old_command_view_enter
    config.plugins.assistant.agent = old_agent_config
    config.plugins.assistant.agents = old_agents_config
    assistant.start_conversation = old_start_conversation
    command.map["core:open-file"] = old_open_file
    command.map["core:find-file"] = old_find_file
    assistant.unregister_tool("external_test_tool")
    assistant.unregister_tool("external_invalid_tool")
    assistant.unregister_agent("external_agent")
    common.rm(root, true)
  end)

  test.it("binds ctrl+shift+u to insert project file command", function()
    test.equal(
      has_value(keymap.get_bindings("assistant-conversation:insert-project-file"), "ctrl+shift+u"),
      true
    )
  end)

  test.it("binds ctrl+alt+u to insert file command", function()
    test.equal(
      has_value(keymap.get_bindings("assistant-conversation:insert-file"), "ctrl+alt+u"),
      true
    )
  end)

  test.it("focuses the prompt editor when opening a conversation", function()
    local view = assistant.start_conversation("ollama")

    test.not_nil(view)
    test.equal(view.focused_child, view.prompt)
    test.equal(core.active_view, view.prompt)
  end)

  test.it("lists registered agents with configured default first", function()
    config.plugins.assistant.agent = "openai"
    assistant.register_agent("external_agent", function()
      return Ollama({ name = "external_agent", display_name = "External Agent" })
    end)

    local choices = assistant.list_agents()
    test.equal(#choices >= 8, true)
    test.equal(choices[1].name, "openai")
    test.equal(choices[1].default, true)

    local found_external = false
    for _, choice in ipairs(choices) do
      if choice.name == "external_agent" then
        found_external = choice.label == "External Agent"
        break
      end
    end
    test.equal(found_external, true)
  end)

  test.it("exposes per-agent settings as a subconfig", function()
    local option = find_option(config.plugins.assistant.config_spec, "Agent Settings")

    test.not_nil(option)
    test.equal(option.type, settings.type.SUBCONFIG)
    test.equal(option.title, "Assistant Agent Settings")
    test.not_nil(option.spec)
    test.equal(option.spec.path_prefix, "agents")

    local ollama = find_section(option.spec.sections, "Ollama")
    local openai = find_section(option.spec.sections, "OpenAI")
    local acp = find_section(option.spec.sections, "ACP")
    local deepseek_anthropic = find_section(option.spec.sections, "DeepSeek Anthropic")

    test.not_nil(ollama)
    test.not_nil(openai)
    test.not_nil(acp)
    test.not_nil(deepseek_anthropic)
    test.equal(find_option(ollama.options, "Model").path, "ollama.model")
    test.equal(find_option(ollama.options, "Base URL").path, "ollama.base_url")
    test.equal(find_option(openai.options, "API Key Environment").path, "openai.api_key_env")
    test.equal(find_option(acp.options, "Transport").path, "acp.transport")
    test.equal(find_option(deepseek_anthropic.options, "Base URL").path, "deepseek_anthropic.base_url")
  end)

  test.it("generates built-in agent config sections", function()
    local spec = agent_config.config_spec()

    test.equal(spec.name, "Assistant Agent Settings")
    test.equal(spec.path_prefix, "agents")
    test.equal(#spec.sections, 10)
    test.not_nil(find_section(spec.sections, "llama.cpp"))
    test.not_nil(find_section(spec.sections, "LM Studio"))
    test.not_nil(find_section(spec.sections, "GitHub Copilot"))
    test.not_nil(find_section(spec.sections, "DeepSeek Anthropic"))
  end)

  test.it("keeps new conversation command on configured default agent", function()
    config.plugins.assistant.agent = "ollama"
    local started_agent
    local old_start = assistant.start_conversation
    assistant.start_conversation = function(agent_name)
      started_agent = agent_name or config.plugins.assistant.agent
      return true
    end

    command.perform("assistant:new-conversation")

    assistant.start_conversation = old_start
    test.equal(started_agent, "ollama")
  end)

  test.it("configures per-agent provider options programmatically", function()
    assistant.configure_agent("ollama", {
      model = "configured-ollama",
      base_url = "http://127.0.0.1:19999",
      keep_alive = "1h",
      reasoning_effort = "medium"
    })
    assistant.configure_agent("openai", {
      model = "configured-openai",
      base_url = "https://example.invalid",
      api_key_env = "ASSISTANT_TEST_KEY"
    })

    local ollama_view = assistant.start_conversation("ollama")
    local openai_view = assistant.start_conversation("openai")

    test.equal(ollama_view.agent.model, "configured-ollama")
    test.equal(ollama_view.agent.base_url, "http://127.0.0.1:19999")
    test.equal(ollama_view.agent.keep_alive, "1h")
    test.equal(ollama_view.agent:configured_reasoning_effort(), "medium")
    test.equal(openai_view.agent.model, "configured-openai")
    test.equal(openai_view.agent.base_url, "https://example.invalid")
    test.equal(openai_view.agent.api_key_env, "ASSISTANT_TEST_KEY")
  end)

  test.it("ignores removed flat provider config keys", function()
    local conf = config.plugins.assistant
    conf["model"] = "flat-model"
    conf["base_url"] = "https://flat.invalid"
    conf["keep_alive"] = "2h"

    local view = assistant.start_conversation("ollama")

    conf["model"] = nil
    conf["base_url"] = nil
    conf["keep_alive"] = nil
    test.equal(view.agent.model, "llama3.1")
    test.equal(view.agent.base_url, "http://127.0.0.1:11434")
    test.equal(view.agent.keep_alive, "-1")
  end)

  test.it("reports invalid per-agent configuration without throwing", function()
    local errors = {}
    core.error = function(format, ...)
      table.insert(errors, string.format(format, ...))
    end

    test.equal(assistant.configure_agent(nil, {}), false)
    test.equal(assistant.configure_agent("ollama"), false)
    test.equal(#errors, 2)
    test.equal(errors[1]:find("requires an agent name", 1, true) ~= nil, true)
    test.equal(errors[2]:find("requires a config table", 1, true) ~= nil, true)
  end)

  test.it("applies per-agent command and transport options", function()
    assistant.configure_agent("codex", {
      command = "codex-test",
      model = "gpt-test",
      reasoning_effort = "high"
    })
    assistant.configure_agent("acp", {
      command = "acp-test",
      transport = "tcp",
      host = "127.0.0.2",
      port = 7777
    })
    assistant.configure_agent("copilot", {
      command = "copilot-test"
    })

    local codex = assistant.start_conversation("codex").agent
    local acp = assistant.start_conversation("acp").agent
    local copilot = assistant.start_conversation("copilot").agent

    test.equal(codex.command, "codex-test")
    test.equal(codex.model, "gpt-test")
    test.equal(codex:configured_reasoning_effort(), "high")
    test.equal(acp.command[1], "acp-test")
    test.equal(acp.transport, "tcp")
    test.equal(acp.host, "127.0.0.2")
    test.equal(acp.port, 7777)
    test.equal(copilot.command[1], "copilot-test")
    test.equal(copilot.command[2], "--acp")
    test.equal(copilot.command[3], "--stdio")
  end)

  test.it("reports missing net for tcp transport", function()
    local old_net = rawget(_G, "net")
    rawset(_G, "net", nil)

    local TcpTransport = dofile("backend/transport/tcp.lua")
    local transport = TcpTransport({
      transport = "tcp",
      host = "127.0.0.1",
      port = 7777
    })

    rawset(_G, "net", old_net)

    test.equal(transport.startup_error, "tcp transport requires the Pragtical net module")
    test.equal(transport:is_starting(), false)
  end)

  test.it("opens agent picker for optional new conversation selection", function()
    local entered_label
    local entered_options
    core.command_view.enter = function(_, label, options)
      entered_label = label
      entered_options = options
    end

    command.perform("assistant:select-agent-new-conversation")

    test.equal(entered_label, "Assistant Agent")
    test.not_nil(entered_options)
    local suggestions = entered_options.suggest("")
    test.equal(#suggestions >= 2, true)
    test.equal(entered_options.validate("ollama"), true)
    test.equal(entered_options.validate("missing-agent"), false)
  end)

  test.it("starts selected agent from optional new conversation picker", function()
    local started_agent
    local old_start = assistant.start_conversation
    assistant.start_conversation = function(agent_name)
      started_agent = agent_name
      return true
    end
    core.command_view.enter = function(_, _, options)
      local suggestions = options.suggest("")
      local selected
      for _, suggestion in ipairs(suggestions) do
        if suggestion.name == "openai" then
          selected = suggestion
          break
        end
      end
      options.submit(selected.text, selected)
    end

    command.perform("assistant:select-agent-new-conversation")

    assistant.start_conversation = old_start
    test.equal(started_agent, "openai")
  end)

  test.it("populates resume conversation picker from indexed conversations", function()
    local conversation = Conversation(Ollama(), root)
    conversation.title = "Resume Me"
    conversation:add("user", "hello")
    conversation:save()
    local entered_label
    local entered_options
    core.command_view.enter = function(_, label, options)
      entered_label = label
      entered_options = options
    end

    command.perform("assistant:resume-conversation")

    test.equal(entered_label, "Assistant Session")
    test.not_nil(entered_options)
    test.equal(entered_options.show_suggestions, true)
    test.equal(entered_options.typeahead, true)
    local suggestions = entered_options.suggest("")
    test.equal(#suggestions, 1)
    test.equal(suggestions[1].id, conversation.id)
    test.equal(suggestions[1].text:find("Resume Me", 1, true) ~= nil, true)
    test.equal(entered_options.validate(conversation.id), true)
  end)

  test.it("resumes the selected conversation from the picker", function()
    local conversation = Conversation(Ollama(), root)
    conversation.title = "Pick Me"
    conversation:add("user", "hello")
    conversation:save()
    local resumed_id
    local resumed_project_dir
    local old_resume = assistant.resume_conversation
    assistant.resume_conversation = function(id, project_dir)
      resumed_id = id
      resumed_project_dir = project_dir
    end
    core.command_view.enter = function(_, _, options)
      local selected = options.suggest("Pick")[1]
      options.submit(selected.text, selected)
    end

    command.perform("assistant:resume-conversation")

    assistant.resume_conversation = old_resume
    test.equal(resumed_id, conversation.id)
    test.equal(resumed_project_dir, root)
  end)

  test.it("registers external tools for new assistant agents", function()
    local ok = assistant.register_tool("external_test_tool", {
      description = "External test tool.",
      read_only = true,
      params = {
        { name = "value", type = "string", description = "Value.", required = true }
      },
      callback = function(args)
        return true, "value: " .. tostring(args.value)
      end,
      compact_result = function()
        return "compact result"
      end,
      activity_markdown = function()
        return "**External**: ok"
      end,
      compact_activity_markdown = function()
        return "**External compact**: ok"
      end,
      result_is_successful = function()
        return true
      end
    })

    test.equal(ok, true)
    local view = assistant.start_conversation("ollama")
    local tool = view.agent.tools.external_test_tool
    test.not_nil(tool)
    test.equal(tool.description, "External test tool.")
    test.equal(tool.read_only, true)
    test.equal(tool.callback({ value = "abc" }), true)
    local _, result = tool.callback({ value = "abc" })
    test.equal(result, "value: abc")
    test.equal(tool.compact_result({}, "raw", {}), "compact result")
    test.equal(tool.activity_markdown({}, "completed", nil, {}), "**External**: ok")
    test.equal(tool.compact_activity_markdown({}, "completed", nil, {}), "**External compact**: ok")
    test.equal(tool.result_is_successful({}, nil, {}), true)

    view.conversation.collaboration_mode = "plan"
    test.equal(has_value(view.agent:tool_names_for_mode(view.conversation), "external_test_tool"), true)
    view.conversation.collaboration_mode = "implementation"
    test.equal(has_value(view.agent:tool_names_for_mode(view.conversation), "external_test_tool"), true)
  end)

  test.it("unregisters external tools for new assistant agents", function()
    test.equal(assistant.register_tool("external_test_tool", {
      description = "External test tool.",
      read_only = true,
      callback = function()
        return true, "ok"
      end
    }), true)
    test.equal(assistant.unregister_tool("external_test_tool"), true)

    local view = assistant.start_conversation("ollama")
    test.equal(view.agent.tools.external_test_tool, nil)
  end)

  test.it("reports invalid external tool registrations without throwing", function()
    local errors = {}
    core.error = function(format, ...)
      table.insert(errors, string.format(format, ...))
    end

    test.equal(assistant.register_tool(nil, {}), false)
    test.equal(assistant.register_tool("external_invalid_tool"), false)
    test.equal(assistant.register_tool("external_invalid_tool", { description = "missing callback" }), false)
    test.equal(#errors, 3)
    test.equal(errors[1]:find("requires a tool name", 1, true) ~= nil, true)
    test.equal(errors[2]:find("requires a tool spec", 1, true) ~= nil, true)
    test.equal(errors[3]:find("could not register tool external_invalid_tool", 1, true) ~= nil, true)

    local view = assistant.start_conversation("ollama")
    test.equal(view.agent.tools.external_invalid_tool, nil)
  end)

  test.it("inserts selected project file path into prompt", function()
    local view = PromptView({
      agent = Ollama(),
      conversation = Conversation(Ollama(), root)
    })
    core.set_active_view(view.prompt)
    view.prompt_doc:insert(1, 1, "open ")
    view.prompt_doc:set_selection(1, math.huge)

    local picker_label
    command.map["core:find-file"] = {
      predicate = function() return true end,
      perform = function(label, callback)
        picker_label = label
        callback(root .. PATHSEP .. "src" .. PATHSEP .. "main.lua", 42)
      end
    }

    command.perform("assistant-conversation:insert-project-file")

    test.equal(picker_label, "Insert Project File")
    test.equal(view.prompt_doc:get_text(1, 1, math.huge, math.huge), "open src/main.lua:42")
    test.equal(core.active_view, view.prompt)
  end)

  test.it("inserts selected file path into prompt", function()
    local view = PromptView({
      agent = Ollama(),
      conversation = Conversation(Ollama(), root)
    })
    core.set_active_view(view.prompt)
    view.prompt_doc:insert(1, 1, "read ")
    view.prompt_doc:set_selection(1, math.huge)

    local picker_label
    local allow_directories
    command.map["core:open-file"] = {
      predicate = function() return true end,
      perform = function(label, callback, allow_dirs)
        picker_label = label
        allow_directories = allow_dirs
        callback(root .. PATHSEP .. "src" .. PATHSEP .. "main.lua")
      end
    }

    command.perform("assistant-conversation:insert-file")

    test.equal(picker_label, "Insert File")
    test.equal(allow_directories, true)
    test.equal(view.prompt_doc:get_text(1, 1, math.huge, math.huge), "read src/main.lua")
    test.equal(core.active_view, view.prompt)
  end)

  test.it("adds trailing separator when inserting selected directory path", function()
    local view = PromptView({
      agent = Ollama(),
      conversation = Conversation(Ollama(), root)
    })
    core.set_active_view(view.prompt)
    view.prompt_doc:insert(1, 1, "inspect ")
    view.prompt_doc:set_selection(1, math.huge)

    command.map["core:open-file"] = {
      predicate = function() return true end,
      perform = function(_, callback)
        callback(root .. PATHSEP .. "src")
      end
    }

    command.perform("assistant-conversation:insert-file")

    test.equal(view.prompt_doc:get_text(1, 1, math.huge, math.huge), "inspect src" .. PATHSEP)
    test.equal(core.active_view, view.prompt)
  end)
end)
