local test = require "core.test"
dofile("tests/helper.inc")
local common = require "core.common"
local command = require "core.command"
local core = require "core"
local keymap = require "core.keymap"
local Conversation = require "plugins.assistant.conversation"
local Ollama = require "plugins.assistant.agent.ollama"
local PromptView = require "plugins.assistant.promptview"

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

test.describe("assistant plugin init", function()
  local old_projects
  local old_active_view
  local old_open_file
  local old_find_file

  test.before_each(function()
    old_projects = core.projects
    old_active_view = core.active_view
    old_open_file = command.map["core:open-file"]
    old_find_file = command.map["core:find-file"]
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
    command.map["core:open-file"] = old_open_file
    command.map["core:find-file"] = old_find_file
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
