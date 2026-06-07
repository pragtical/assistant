local test = require "core.test"
dofile("tests/helper.inc")
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local Conversation = require "plugins.assistant.conversation"
local MemoriesList = require "plugins.assistant.ui.memorieslist"

local root = assistant_test_temp_path("memories-list")

local function mkdirp(path)
  local info = system.get_file_info(path)
  if info and info.type == "dir" then return end
  common.mkdirp(path)
end

test.describe("assistant memories list", function()
  test.before_each(function()
    common.rm(root, true)
    mkdirp(root)
  end)

  test.it("populates saved memories in a listbox", function()
    local item = Conversation.add_memory(root, "List Me", "Remember this.")

    local view = MemoriesList(root)

    test.equal(#view.list.rows, 1)
    test.equal(view.list:get_row_data(1).id, item.id)
    test.equal(view.list:get_row_data(1).title, "List Me")
  end)

  test.it("truncates long memory titles and previews in list rows", function()
    local title = "This is a very long memory title that should be cropped"
    local content = "This is a long memory body that should be compacted for the list preview column."
    Conversation.add_memory(root, title, content)

    local view = MemoriesList(root)

    test.equal(view.list.rows[1][2], "This is a very long memory...")
    test.equal(view.list.rows[1][11], "This is a long memory body that should be compacted for t...")
    test.equal(view.list:get_row_data(1).title, title)
    test.equal(view.list:get_row_data(1).content, nil)
  end)

  test.it("can delete the selected memory", function()
    Conversation.add_memory(root, "Delete Me", "temporary")

    local view = MemoriesList(root)
    view.list:set_selected(1)
    local data = view:get_selected_data()
    test.equal(Conversation.delete_memory(view.project_dir, data.id), true)
    test.equal(view:remove_memory_row(data.id), true)

    test.equal(#view.list.rows, 0)
  end)

  test.it("can delete all saved memories", function()
    local first = Conversation.add_memory(root, "First", "one")
    local second = Conversation.add_memory(root, "Second", "two")

    local view = MemoriesList(root)
    local deleted = view:delete_all_memories()

    test.equal(deleted, 2)
    test.equal(#view.list.rows, 0)
    test.equal(#Conversation.list_memories(root), 0)
    test.equal(system.get_file_info(Conversation.memory_path(root, first.id)), nil)
    test.equal(system.get_file_info(Conversation.memory_path(root, second.id)), nil)
  end)

  test.it("opens the selected memory through its callback", function()
    local item = Conversation.add_memory(root, "Open Me", "content")
    local opened
    local opened_from_view
    local view = MemoriesList(root, function(data, list_view)
      opened = data
      opened_from_view = list_view
    end)
    view.list:set_selected(1)

    view:open_selected()

    test.equal(opened.id, item.id)
    test.equal(opened_from_view, view)
  end)

  test.it("adds a blank memory and opens it through its callback", function()
    local opened
    local opened_from_view
    local view = MemoriesList(root, function(data, list_view)
      opened = data
      opened_from_view = list_view
    end)

    local item = view:add_new_memory()
    local listed = Conversation.list_memories(root)

    test.equal(item.id, listed[1].id)
    test.equal(item.title, "Memory")
    test.equal(item.content, "")
    test.equal(opened.id, item.id)
    test.equal(opened_from_view, view)
    test.equal(#view.list.rows, 1)
    test.equal(view:get_selected_data().id, item.id)
  end)

  test.it("saves edited memory title and content", function()
    local item = Conversation.add_memory(root, "Old", "old content")
    local saved
    local editor = MemoriesList.MemoryEditor(root, item, function(updated)
      saved = updated
    end)

    editor.title_textbox:set_text("New")
    editor:set_content("new content")
    local updated = editor:save()
    local listed = Conversation.list_memories(root)

    test.equal(updated.id, item.id)
    test.equal(saved.id, item.id)
    test.equal(listed[1].title, "New")
    test.equal(listed[1].content, "new content")
  end)

  test.it("loads full memory content when opening indexed row data", function()
    local item = Conversation.add_memory(root, "Indexed", "full content")
    local view = MemoriesList(root)
    local data = view.list:get_row_data(1)

    test.equal(data.id, item.id)
    test.equal(data.content, nil)

    local editor = MemoriesList.MemoryEditor(root, data)

    test.equal(editor.item.id, item.id)
    test.equal(editor:get_content(), "full content")
  end)

  test.it("reports the parent editor title from the embedded docview", function()
    local item = Conversation.add_memory(root, "Named", "content")
    local editor = MemoriesList.MemoryEditor(root, item)

    test.equal(editor.content:get_name(), editor:get_name())
  end)

  test.it("positions the embedded editor docview below the title field", function()
    local item = Conversation.add_memory(root, "Position", "content")
    local editor = MemoriesList.MemoryEditor(root, item)
    editor:set_position(100, 200)
    editor:set_size(600, 500)

    editor:update()

    test.equal(editor.content.position.x, editor.position.x + style.padding.x)
    test.equal(
      editor.content.position.y > editor.position.y + editor.title_textbox:get_bottom(),
      true
    )
    test.equal(editor.content.size.y > 0, true)
  end)

  test.it("moves the embedded content caret on mouse clicks", function()
    local item = Conversation.add_memory(root, "Click", "first\nsecond")
    local editor = MemoriesList.MemoryEditor(root, item)
    editor:set_position(100, 200)
    editor:set_size(600, 500)
    editor:update()

    local x = editor.content.position.x + editor.content:get_gutter_width() + 8
    local y = editor.content.position.y + style.font:get_height() / 2
    editor:on_mouse_pressed("left", x, y, 1)
    local line = select(1, editor.content.doc:get_selection())

    test.equal(core.active_view, editor.content)
    test.equal(line, 1)
  end)

  test.it("does not consume ctrl mouse wheel over embedded content editor", function()
    local item = Conversation.add_memory(root, "Wheel", "content")
    local editor = MemoriesList.MemoryEditor(root, item)
    editor:set_position(100, 200)
    editor:set_size(600, 500)
    editor:update()

    core.root_view.mouse.x = editor.content.position.x + 4
    core.root_view.mouse.y = editor.content.position.y + 4
    keymap.modkeys.ctrl = true

    local consumed = editor:on_mouse_wheel(-1, 0)

    keymap.modkeys.ctrl = false

    test.equal(consumed, false)
    test.equal(editor.content.scroll.to.y, 0)
  end)

  test.it("scrolls embedded content editor on mouse wheel without ctrl", function()
    local item = Conversation.add_memory(root, "Wheel", "content")
    local editor = MemoriesList.MemoryEditor(root, item)
    editor:set_position(100, 200)
    editor:set_size(600, 500)
    editor:update()

    core.root_view.mouse.x = editor.content.position.x + 4
    core.root_view.mouse.y = editor.content.position.y + 4

    local consumed = editor:on_mouse_wheel(-1, 0)

    test.equal(consumed, true)
    test.equal(editor.content.scroll.to.y, config.mouse_wheel_scroll)
  end)
end)
