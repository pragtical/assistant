local test = require "core.test"
dofile("tests/helper.inc")
local common = require "core.common"
local Conversation = require "plugins.assistant.conversation"
local Ollama = require "plugins.assistant.agent.ollama"
local ConversationsList = require "plugins.assistant.ui.conversationslist"

local root = assistant_test_temp_path("conversations-list")

local function mkdirp(path)
  local info = system.get_file_info(path)
  if info and info.type == "dir" then return end
  common.mkdirp(path)
end

local function write(path, text)
  local fp = assert(io.open(path, "wb"))
  fp:write(text)
  fp:close()
end

test.describe("assistant conversations list", function()
  test.before_each(function()
    common.rm(root, true)
    mkdirp(root)
  end)

  test.it("populates saved conversations in a listbox", function()
    local conversation = Conversation(Ollama(), root)
    conversation.title = "List Me"
    conversation:add("user", "hello")
    conversation:save()

    local view = ConversationsList(root)

    test.equal(#view.list.rows, 1)
    test.equal(view.list:get_row_data(1).title, "List Me")
  end)

  test.it("truncates long conversation titles in list rows", function()
    local conversation = Conversation(Ollama(), root)
    conversation.title = "This is a very long conversation title that should be cropped"
    conversation:add("user", "hello")
    conversation:save()

    local view = ConversationsList(root)

    test.equal(view.list.rows[1][2], "This is a very long convers...")
    test.equal(view.list:get_row_data(1).title, conversation.title)
  end)

  test.it("renders saved conversations from index metadata", function()
    local conversation = Conversation(Ollama(), root)
    conversation.title = "Indexed Conversation"
    conversation:add("user", "hello")
    conversation:save()
    write(Conversation.session_path(root, conversation.id), "this is not loadable lua")

    local view = ConversationsList(root)

    test.equal(#view.list.rows, 1)
    test.equal(view.list:get_row_data(1).id, conversation.id)
    test.equal(view.list:get_row_data(1).title, "Indexed Conversation")
  end)

  test.it("can delete the selected conversation", function()
    local conversation = Conversation(Ollama(), root)
    conversation.title = "Delete Me"
    conversation:add("user", "hello")
    conversation:save()

    local view = ConversationsList(root)
    view.list:set_selected(1)
    local data = view:get_selected_data()
    test.equal(Conversation.delete(data.id, view.project_dir), true)
    test.equal(view:remove_conversation_row(data.id), true)

    test.equal(#view.list.rows, 0)
  end)

  test.it("can delete all saved conversations", function()
    local first = Conversation(Ollama(), root)
    first.title = "First"
    first:add("user", "hello")
    first:save()
    local second = Conversation(Ollama(), root)
    second.title = "Second"
    second:add("user", "hello")
    second:save()

    local view = ConversationsList(root)
    local deleted = view:delete_all_conversations()

    test.equal(deleted, 2)
    test.equal(#view.list.rows, 0)
    test.equal(#Conversation.list(root), 0)
    test.equal(system.get_file_info(Conversation.session_path(root, first.id)), nil)
    test.equal(system.get_file_info(Conversation.session_path(root, second.id)), nil)
  end)
end)
