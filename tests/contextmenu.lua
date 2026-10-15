dofile("tests/helper.inc")
local core = require "core"
local command = require "core.command"
local config = require "core.config"
local RootView = require "core.rootview"
local DocView = require "core.docview"
local Doc = require "core.doc"
local View = require "core.view"
local Conversation = require "plugins.assistant.conversation"
local Ollama = require "plugins.assistant.agent.ollama"
local PromptView = require "plugins.assistant.promptview"
local ConversationsList = require "plugins.assistant.ui.conversationslist"
local MemoriesList = require "plugins.assistant.ui.memorieslist"
local test = require "core.test"

test.describe("Assistant floating transcript menus", function()
  test.before_each(function(context)
    context.root, context.active = core.root_view, core.active_view
    context.last, context.next = core.last_active_view, core.next_active_view
    context.transitions = config.transitions
    context.transcript_items = { table.unpack(PromptView.transcript_menu.itemset) }
    context.test_action = command.map["assistant-floating-test:action"]
    core.root_view = RootView()
    core.root_view.root_node.is_primary_node = true
    core.root_view.size.x, core.root_view.size.y = 900, 600
    core.active_view = core.root_view.root_node.active_view
    config.transitions = false
    local agent = Ollama()
    context.view = PromptView {
      agent = agent, backend = {},
      conversation = Conversation(agent, "/tmp/pragtical-assistant-floating-project")
    }
    core.root_view.root_node:add_view(context.view)
    core.root_view:update()
    core.root_view:update()
  end)
  test.after_each(function(context)
    PromptView.transcript_menu:hide()
    PromptView.raw_transcript_menu:hide()
    PromptView.transcript_menu.itemset = context.transcript_items
    command.map["assistant-floating-test:action"] = context.test_action
    if context.list_menu then
      context.list_menu:hide()
      context.list_menu.itemset = context.list_items
    end
    if core.root_view.cancel_mouse_capture then core.root_view:cancel_mouse_capture() end
    core.root_view, core.active_view = context.root, context.active
    core.last_active_view, core.next_active_view = context.last, context.next
    config.transitions = context.transitions
  end)

  for _, Class in ipairs { ConversationsList, MemoriesList } do
    test.test(Class == ConversationsList and "conversation list menu updates and draws once"
      or "memory list menu updates and draws once", function(context)
      if not View.set_floating then test.skip_now("requires floating views") end
      local view = Class("/tmp/pragtical-assistant-floating-project")
      core.root_view.root_node:add_view(view)
      core.root_view:update()
      local menu = Class.menu
      context.list_menu, context.list_items = menu, menu.itemset
      menu.itemset = {}
      command.add(nil, { ["assistant-floating-test:action"] = function() end })
      menu:register(nil, { { text = "Audit", command = "assistant-floating-test:action" } })
      test.ok(menu:show(100, 150))
      local updates, draws = 0, 0
      local update, draw = menu.update, menu.draw
      menu.update = function(self) updates = updates + 1; return update(self) end
      menu.draw = function() draws = draws + 1 end
      core.root_view:update()
      renderer.begin_frame(core.window)
      local ok, err = pcall(core.root_view.draw, core.root_view)
      renderer.end_frame()
      menu.update, menu.draw = update, draw
      test.ok(ok, err)
      test.equal(updates, 1); test.equal(draws, 1)
    end)
  end

  for _, raw in ipairs { false, true } do
    test.test((raw and "raw" or "rendered") .. " transcript menu updates and draws once", function(context)
      if not View.set_floating then test.skip_now("requires floating view registry") end
      local view = context.view
      view.transcript_mode = raw and "raw" or "rendered"
      core.set_active_view(view:get_transcript_view())
      local menu = raw and PromptView.raw_transcript_menu or PromptView.transcript_menu
      test.ok(menu:show_items({ { text = "Audit", command = function() end } }, 100, 150))
      local updates, draws = 0, 0
      local update, draw = menu.update, menu.draw
      menu.update = function(self) updates = updates + 1; return update(self) end
      menu.draw = function() draws = draws + 1 end
      core.root_view:update()
      renderer.begin_frame(core.window)
      local ok, err = pcall(core.root_view.draw, core.root_view)
      renderer.end_frame()
      menu.update, menu.draw = update, draw
      test.ok(ok, err)
      test.equal(updates, 1); test.equal(draws, 1)
      core.root_view.root_node:add_view(DocView(Doc()))
      core.root_view:update()
      test.not_ok(menu.show_context_menu)
    end)
  end

  test.test("right click opens at the transcript and clicking its action works", function(context)
    if not View.set_floating then test.skip_now("requires floating views") end
    local view = context.view
    local performed = 0
    command.add(nil, { ["assistant-floating-test:action"] = function() performed = performed + 1 end })
    local menu = PromptView.transcript_menu
    menu:register(nil, { { text = "Audit", command = "assistant-floating-test:action" } })
    local transcript = view.transcript
    local x, y = transcript.position.x + 20, transcript.position.y + 20
    core.root_view:on_mouse_pressed("right", x, y, 1)
    core.root_view:on_mouse_released("right", x, y)
    core.root_view:update()
    test.ok(menu.show_context_menu)
    test.equal(core.active_view, transcript)
    local row_x, row_y, row_h
    for _, item, ix, iy, iw, ih in menu:each_item() do
      if item.text == "Audit" then row_x, row_y, row_h = ix + 10, iy, ih end
    end
    test.not_nil(row_x)
    core.root_view:on_mouse_moved(row_x, row_y + row_h / 2, 0, 0)
    core.root_view:on_mouse_pressed("left", row_x, row_y + row_h / 2, 1)
    test.equal(performed, 1)
    test.not_ok(menu.show_context_menu)
  end)
end)
