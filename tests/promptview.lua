local test = require "core.test"
dofile("tests/helper.inc")
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local MessageBox = require "widget.messagebox"
local PromptView = require "plugins.assistant.promptview"
local Conversation = require "plugins.assistant.conversation"
local Agent = require "plugins.assistant.agent"
local Ollama = require "plugins.assistant.agent.ollama"
local OpenAI = require "plugins.assistant.agent.openai"
local Codex = require "plugins.assistant.agent.codex"
local Copilot = require "plugins.assistant.agent.copilot"
local AcpBackend = require "plugins.assistant.backend.acp"

test.describe("assistant prompt view", function()
  test.it("creates embedded transcript and prompt views", function()
    local agent = Ollama()
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp")
    })

    test.not_nil(view.transcript)
    test.not_nil(view.raw_transcript)
    test.not_nil(view.raw_transcript_doc)
    test.not_nil(view.prompt)
    test.not_nil(view.prompt_doc)
    test.equal(view.raw_transcript_doc.filename, "Assistant Conversation.md")
    test.equal(view.prompt_doc.filename, "Assistant Prompt.md")
    test.not_nil(view:get_state())
  end)

  test.it("reports the conversation title from embedded child views", function()
    local agent = Ollama()
    local conversation = Conversation(agent, "/tmp")
    conversation.title = "Sario Game"
    local view = PromptView({
      agent = agent,
      conversation = conversation
    })

    test.equal(view:get_name(), "Sario Game")
    test.equal(view.transcript:get_name(), "Sario Game")
    test.equal(view.raw_transcript:get_name(), "Sario Game")
    test.equal(view.prompt:get_name(), "Sario Game")
    test.equal(view.raw_transcript_doc.filename, "Assistant Conversation.md")
    test.equal(view.prompt_doc.filename, "Assistant Prompt.md")

    conversation.title = "Renamed Sario"
    view:refresh()

    test.equal(view:get_name(), "Renamed Sario")
    test.equal(view.transcript:get_name(), "Renamed Sario")
    test.equal(view.raw_transcript:get_name(), "Renamed Sario")
    test.equal(view.prompt:get_name(), "Renamed Sario")
  end)

  test.it("embedded docviews ignore scroll past end", function()
    local previous_scroll_past_end = config.scroll_past_end
    config.scroll_past_end = true

    local agent = Ollama()
    local conversation = Conversation(agent, "/tmp")
    conversation:add("user", "hello", { autosave = false })
    local view = PromptView({
      agent = agent,
      conversation = conversation
    })

    view.prompt.size.y = 400
    view.raw_transcript.size.y = 400
    view.prompt_doc:insert(1, 1, "prompt\nline")

    local function expected_size(docview)
      local _, _, _, h_scroll = docview.h_scrollbar:get_track_rect()
      return docview:get_line_height() * #docview.doc.lines + style.padding.y * 2 + h_scroll
    end

    test.equal(view.prompt:get_scrollable_size(), expected_size(view.prompt))
    test.equal(view.raw_transcript:get_scrollable_size(), expected_size(view.raw_transcript))

    config.scroll_past_end = previous_scroll_past_end
  end)

  test.it("restores copilot conversations with the ACP backend", function()
    local old_agent = config.plugins.assistant.agent
    config.plugins.assistant.agent = "ollama"

    local agent = Copilot()
    local conversation = Conversation(agent, "/tmp")
    conversation:add("user", "hello", { autosave = false })
    test.equal(conversation:save(), true)

    local restored = PromptView.from_state({
      id = conversation.id,
      project_dir = conversation.project_dir
    })

    config.plugins.assistant.agent = old_agent

    test.not_nil(restored)
    test.equal(restored.agent.name, "copilot")
    test.equal(restored.conversation.agent, "copilot")
    test.equal(restored.conversation.backend, "acp")
    test.equal(restored.backend:is(AcpBackend), true)
  end)

  test.it("activates the embedded prompt docview on click", function()
    local agent = Ollama()
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp")
    })
    view.position.x = 0
    view.position.y = 0
    view.size.x = 640
    view.size.y = 480
    view:update()

    view:on_mouse_pressed(
      "left",
      view.prompt.position.x + 4,
      view.prompt.position.y + 4,
      1
    )

    test.equal(core.active_view, view.prompt)
  end)

  test.it("routes transcript mouse clicks through markdown view", function()
    local agent = Ollama()
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp")
    })
    view.position.x = 0
    view.position.y = 0
    view.size.x = 640
    view.size.y = 480
    view:update()

    local opened
    view.transcript.get_link_at = function()
      return "https://example.com"
    end
    view.transcript.open_link = function(_, url)
      opened = url
    end

    view:on_mouse_pressed(
      "left",
      view.transcript.position.x + 4,
      view.transcript.position.y + 4,
      1
    )

    test.equal(core.active_view, view.transcript)
    test.equal(opened, "https://example.com")
  end)

  test.it("propagates transcript link cursor to root prompt view", function()
    local agent = Ollama()
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp")
    })
    view.position.x = 0
    view.position.y = 0
    view.size.x = 640
    view.size.y = 480
    view:update()

    view.transcript.get_link_at = function()
      return "https://example.com"
    end

    view:on_mouse_moved(
      view.transcript.position.x + 4,
      view.transcript.position.y + 4,
      0,
      0
    )

    test.equal(view.transcript.cursor, "hand")
    test.equal(view.cursor, "hand")

    view:on_mouse_moved(
      view.prompt.position.x + 4,
      view.prompt.position.y + 4,
      0,
      0
    )

    test.equal(view.cursor, view.prompt.cursor)
  end)

  test.it("opens raw responses in a doc view", function()
    local old_log_raw_messages = config.plugins.assistant.log_raw_messages
    config.plugins.assistant.log_raw_messages = true
    local agent = Ollama()
    local conversation = Conversation(agent, "/tmp")
    conversation:append_raw_response("event", { text = "raw" })
    local view = PromptView({
      agent = agent,
      conversation = conversation,
      backend = {}
    })
    local old_open_doc = core.root_view.open_doc
    local opened_doc
    core.root_view.open_doc = function(_, doc)
      opened_doc = doc
    end

    view:view_raw_responses()

    core.root_view.open_doc = old_open_doc
    config.plugins.assistant.log_raw_messages = old_log_raw_messages
    test.not_nil(opened_doc)
    test.equal(opened_doc:get_text(1, 1, math.huge, math.huge):find('"text":"raw"', 1, true) ~= nil, true)
  end)

  test.it("switches transcript between rendered and raw markdown views", function()
    local agent = Ollama()
    local conversation = Conversation(agent, "/tmp")
    conversation:add("user", "Question", { autosave = false })
    local view = PromptView({
      agent = agent,
      conversation = conversation,
      backend = {}
    })
    view:set_position(0, 0)
    view:set_size(640, 480)
    view:update()

    view:view_raw_markdown()
    view:update()

    test.equal(view.transcript_mode, "raw")
    test.equal(core.active_view, view.raw_transcript)
    test.equal(view:get_transcript_view(), view.raw_transcript)
    test.equal(view.raw_transcript_doc:get_text(1, 1, math.huge, math.huge):find("## User", 1, true) ~= nil, true)
    test.equal(view.raw_transcript.position.x, view.transcript.position.x)
    test.equal(view.raw_transcript.position.y, view.transcript.position.y)

    local clicked
    view.raw_transcript.on_mouse_pressed = function(_, button, x, y, clicks)
      clicked = button == "left"
        and x == view.raw_transcript.position.x + 4
        and y == view.raw_transcript.position.y + 4
        and clicks == 1
      return true
    end
    view:on_mouse_pressed(
      "left",
      view.raw_transcript.position.x + 4,
      view.raw_transcript.position.y + 4,
      1
    )
    test.equal(core.active_view, view.raw_transcript)
    test.equal(clicked, true)

    view:view_rendered_markdown()

    test.equal(view.transcript_mode, "rendered")
    test.equal(core.active_view, view.transcript)
    test.equal(view:get_transcript_view(), view.transcript)
  end)

  test.it("line-wraps raw markdown view without changing raw text", function()
    local old_enable_by_default = config.plugins.linewrapping.enable_by_default
    local old_raw_markdown_line_wrapping = config.plugins.assistant.raw_markdown_line_wrapping
    config.plugins.linewrapping.enable_by_default = false
    config.plugins.assistant.raw_markdown_line_wrapping = true

    local agent = Ollama()
    local conversation = Conversation(agent, "/tmp")
    local long_line = ("long raw markdown line "):rep(19) .. "long raw markdown line"
    conversation:add("assistant", long_line, { autosave = false })
    local view = PromptView({
      agent = agent,
      conversation = conversation,
      backend = {}
    })
    local canonical = view:get_conversation_markdown()
    view:set_position(0, 0)
    view:set_size(320, 240)
    view:update()

    view:view_raw_markdown()
    view:update()

    local raw = view.raw_transcript_doc:get_text(1, 1, math.huge, math.huge):gsub("%s+$", "")
    test.equal(raw, canonical)
    test.equal(view.raw_transcript.wrapping_enabled, true)
    test.not_nil(view.raw_transcript.wrapped_settings)
    test.equal(view.raw_transcript:get_h_scrollable_size(), 0)
    test.equal(view.prompt.wrapping_enabled, false)

    config.plugins.linewrapping.enable_by_default = old_enable_by_default
    config.plugins.assistant.raw_markdown_line_wrapping = old_raw_markdown_line_wrapping
  end)

  test.it("does not line-wrap raw markdown when disabled", function()
    local old_enable_by_default = config.plugins.linewrapping.enable_by_default
    local old_raw_markdown_line_wrapping = config.plugins.assistant.raw_markdown_line_wrapping
    config.plugins.linewrapping.enable_by_default = false
    config.plugins.assistant.raw_markdown_line_wrapping = false

    local agent = Ollama()
    local conversation = Conversation(agent, "/tmp")
    conversation:add("assistant", ("long raw markdown line "):rep(20), { autosave = false })
    local view = PromptView({
      agent = agent,
      conversation = conversation,
      backend = {}
    })
    view:set_position(0, 0)
    view:set_size(320, 240)
    view:update()

    view:view_raw_markdown()
    view:update()

    test.equal(view.raw_transcript.wrapping_enabled, false)
    test.equal(view.raw_transcript.wrapped_settings, nil)

    config.plugins.linewrapping.enable_by_default = old_enable_by_default
    config.plugins.assistant.raw_markdown_line_wrapping = old_raw_markdown_line_wrapping
  end)

  test.it("lets raw markdown docview clicks fall through to mouse keymaps", function()
    local agent = Ollama()
    local conversation = Conversation(agent, "/tmp")
    conversation:add("user", "Question", { autosave = false })
    local view = PromptView({
      agent = agent,
      conversation = conversation,
      backend = {}
    })
    view:set_position(0, 0)
    view:set_size(640, 480)
    view:update()
    view:view_raw_markdown()
    view:update()

    local handled = view:on_mouse_pressed(
      "left",
      view.raw_transcript.position.x + view.raw_transcript:get_gutter_width() + 20,
      view.raw_transcript.position.y + 20,
      1
    )

    test.equal(core.active_view, view.raw_transcript)
    test.equal(handled, nil)
  end)

  test.it("switches model from model dialog selection", function()
    local agent = Ollama()
    agent.reasoning_effort = "low"
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        list_models = function(_, _, callback)
          callback(true, nil, { "model-a", "model-b" })
        end
      }
    })

    view:open_model_dialog()
    local dialog = view.model_dialog
    dialog.list:set_selected(2)
    dialog.reasoning_select:set_selected(3)
    dialog:submit()

    test.equal(view.agent.model, "model-b")
    test.equal(view.agent.reasoning_effort, "medium")
    test.equal(view.conversation.model, "model-b")
    test.equal(view.conversation.reasoning_effort, "medium")
  end)

  test.it("shows reasoning effort next to model except none", function()
    local old_reasoning_effort = config.plugins.assistant.reasoning_effort
    config.plugins.assistant.reasoning_effort = "high"
    local agent = Ollama({ model = "model-a" })
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp")
    })

    view:refresh()
    test.equal(view.status.label:find("model%-a %(high%)") ~= nil, true)

    agent.reasoning_effort = "none"
    view:refresh()
    config.plugins.assistant.reasoning_effort = old_reasoning_effort

    test.equal(view.status.label:find("model%-a %(none%)"), nil)
    test.equal(view.status.label:find("model-a", 1, true) ~= nil, true)
  end)

  test.it("clears loading state after model list callback", function()
    local agent = Ollama()
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        list_models = function(_, _, callback)
          test.equal(agent:loading(), true)
          callback(true, nil, { "model-a" })
        end
      }
    })

    view:open_model_dialog()

    test.equal(agent:loading(), false)
  end)

  test.it("does not consume ctrl mouse wheel over embedded prompt", function()
    local agent = Ollama()
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp")
    })
    view.position.x = 0
    view.position.y = 0
    view.size.x = 640
    view.size.y = 480
    view:update()

    core.root_view.mouse.x = view.prompt.position.x + 4
    core.root_view.mouse.y = view.prompt.position.y + 4
    keymap.modkeys.ctrl = true

    local consumed = view:on_mouse_wheel(-1, 0)

    keymap.modkeys.ctrl = false

    test.equal(consumed, false)
    test.equal(view.prompt.scroll.to.y, 0)
  end)

  test.it("scrolls embedded prompt on mouse wheel without ctrl", function()
    local agent = Ollama()
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp")
    })
    view.position.x = 0
    view.position.y = 0
    view.size.x = 640
    view.size.y = 480
    view:update()

    core.root_view.mouse.x = view.prompt.position.x + 4
    core.root_view.mouse.y = view.prompt.position.y + 4

    local consumed = view:on_mouse_wheel(-1, 0)

    test.equal(consumed, true)
    test.equal(view.prompt.scroll.to.y, config.mouse_wheel_scroll)
  end)

  test.it("keeps transcript scrolled to bottom when already at bottom", function()
    local agent = Ollama()
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp")
    })
    view.position.x = 0
    view.position.y = 0
    view.size.x = 640
    view.size.y = 220
    view:update()

    for i = 1, 40 do
      view.conversation:add("assistant", "line " .. i, { autosave = false })
    end
    view:refresh()
    local bottom = math.max(0, view.transcript:get_scrollable_size() - view.transcript.size.y)
    view.transcript.scroll.y = bottom
    view.transcript.scroll.to.y = bottom

    view.conversation:add("assistant", "new line", { autosave = false })
    view:refresh()

    local next_bottom = math.max(0, view.transcript:get_scrollable_size() - view.transcript.size.y)
    test.equal(view.transcript.scroll.y, next_bottom)
  end)

  test.it("keeps raw markdown scrolled to bottom when already at bottom", function()
    local agent = Ollama()
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp")
    })
    view.position.x = 0
    view.position.y = 0
    view.size.x = 640
    view.size.y = 220
    view:update()

    for i = 1, 40 do
      view.conversation:add("assistant", "line " .. i, { autosave = false })
    end
    view:refresh()
    view:view_raw_markdown()
    view.raw_transcript:update()
    local bottom = math.max(0, view.raw_transcript:get_scrollable_size() - view.raw_transcript.size.y)
    view.raw_transcript.scroll.y = bottom
    view.raw_transcript.scroll.to.y = bottom

    view.conversation:add("assistant", "new line", { autosave = false })
    view:refresh()

    local next_bottom = math.max(0, view.raw_transcript:get_scrollable_size() - view.raw_transcript.size.y)
    test.equal(view.raw_transcript.scroll.y, next_bottom)
  end)

  test.it("appends rendered markdown when transcript only grows", function()
    local agent = Ollama()
    local conversation = Conversation(agent, "/tmp")
    conversation:add("assistant", "hello", { autosave = false })
    local view = PromptView({
      agent = agent,
      conversation = conversation
    })
    local appended
    view.transcript.append_text = function(this, text)
      appended = text
      this:set_text((this.text or "") .. text)
      return true
    end

    conversation:add("assistant", "world", { autosave = false })
    view:refresh()

    test.equal(type(appended), "string")
    test.equal(appended:find("world", 1, true) ~= nil, true)
  end)

  test.it("does not rebuild full transcript markdown for appended messages", function()
    local agent = Ollama()
    local conversation = Conversation(agent, "/tmp")
    conversation:add("assistant", "hello", { autosave = false })
    local view = PromptView({
      agent = agent,
      conversation = conversation
    })
    view:refresh()

    local rebuilds = 0
    local original_to_markdown = conversation.to_markdown
    conversation.to_markdown = function(this)
      rebuilds = rebuilds + 1
      return original_to_markdown(this)
    end

    conversation:add("user", "next prompt", { autosave = false })
    view:refresh()

    conversation.to_markdown = original_to_markdown
    test.equal(rebuilds, 0)
    test.equal(view.transcript_markdown_text:find("next prompt", 1, true) ~= nil, true)
  end)

  test.it("renders streamed assistant output as partial text", function()
    local agent = Ollama()
    local callback
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        send = function(_, _, _, cb)
          callback = cb
        end
      }
    })

    view.prompt_doc:insert(1, 1, "prompt")
    view:submit()

    local partial_text
    local appended
    local set_text = false
    view.transcript.set_partial_text = function(this, text)
      partial_text = text
      this.partial_text = text
    end
    view.transcript.append_text = function(this, text)
      appended = text
      this.text = (this.text or "") .. text
    end
    view.transcript.set_text = function()
      set_text = true
    end

    callback(true, nil, "stream-only", { partial = true })

    test.equal(partial_text, "stream-only")
    test.equal(type(appended), "string")
    test.equal(appended:find("## Assistant", 1, true) ~= nil, true)
    test.equal(set_text, false)
    test.equal(view.transcript_markdown_text:find("## Assistant", 1, true) ~= nil, true)
    test.equal(view.transcript_markdown_text:find("stream-only", 1, true), nil)
  end)

  test.it("accumulates delta-only streamed assistant output", function()
    local agent = Ollama()
    local callback
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        send = function(_, _, _, cb)
          callback = cb
        end
      }
    })

    view.prompt_doc:insert(1, 1, "prompt")
    view:submit()

    local partial_text
    view.transcript.set_partial_text = function(_, text)
      partial_text = text
    end

    callback(true, nil, "Let me ", { partial = true })
    callback(true, nil, "take a look ", { partial = true })
    callback(true, nil, "overview.", { partial = true })

    test.equal(view.pending_assistant.message, "Let me take a look overview.")
    test.equal(partial_text, "Let me take a look overview.")
  end)

  test.it("commits streamed assistant output as markdown when final", function()
    local agent = Ollama()
    local callback
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        send = function(_, _, _, cb)
          callback = cb
        end
      }
    })

    view.prompt_doc:insert(1, 1, "hello")
    view:submit()

    local partial_text
    local committed
    local final_set_text
    view.transcript.set_partial_text = function(this, text)
      partial_text = text
      this.partial_text = text
    end
    view.transcript.commit_partial_text = function(this, markdown)
      committed = markdown
      this.partial_text = nil
      this.text = (this.text or "") .. markdown
      return true
    end
    view.transcript.set_text = function(this, markdown)
      final_set_text = markdown
      this.text = markdown
    end

    callback(true, nil, "hel", { partial = true })
    callback(true, nil, "hello **world**", { done = true })

    test.equal(partial_text, "hel")
    test.equal(committed, nil)
    test.equal(type(final_set_text), "string")
    test.equal(final_set_text:find("## Assistant", 1, true) ~= nil, true)
    test.equal(final_set_text:find("hello **world**", 1, true) ~= nil, true)
    test.equal(view.pending_assistant, nil)
    test.equal(view.transcript_markdown_text:find("## Assistant", 1, true) ~= nil, true)
    test.equal(view.transcript_markdown_text:find("hello **world**", 1, true) ~= nil, true)
  end)

  test.it("redraws rendered markdown when an existing activity changes", function()
    local agent = Ollama()
    local conversation = Conversation(agent, "/tmp")
    local activity = conversation:add("activity", "Reasoning\n\nThe", { autosave = false })
    local view = PromptView({
      agent = agent,
      conversation = conversation
    })
    view:refresh()

    local appended = false
    local set_text
    view.transcript.append_text = function()
      appended = true
    end
    view.transcript.set_text = function(this, text)
      set_text = text
      this.text = text
    end

    activity.message = "Reasoning\n\nThe directory is empty."
    conversation:touch()
    view:refresh()

    test.equal(appended, false)
    test.equal(type(set_text), "string")
    test.equal(set_text:find("The directory is empty.", 1, true) ~= nil, true)
    test.equal(view.transcript_markdown_text:find("The directory is empty.", 1, true) ~= nil, true)
  end)

  test.it("does not update hidden rendered markdown while raw markdown is visible", function()
    local agent = Ollama()
    local conversation = Conversation(agent, "/tmp")
    conversation:add("assistant", "hello", { autosave = false })
    local view = PromptView({
      agent = agent,
      conversation = conversation
    })
    view:set_position(0, 0)
    view:set_size(640, 480)
    view:update()

    local rendered_updates = 0
    local raw_updates = 0
    local set_text_called = false
    local append_called = false
    view.transcript.update = function()
      rendered_updates = rendered_updates + 1
    end
    view.raw_transcript.update = function()
      raw_updates = raw_updates + 1
    end
    view.transcript.set_text = function()
      set_text_called = true
    end
    view.transcript.append_text = function()
      append_called = true
    end

    view:view_raw_markdown()
    conversation:add("assistant", "world", { autosave = false })
    view:refresh()
    view:update()

    test.equal(rendered_updates, 0)
    test.equal(raw_updates, 1)
    test.equal(set_text_called, false)
    test.equal(append_called, false)
    test.equal(view.raw_transcript_doc:get_text(1, 1, math.huge, math.huge):find("world", 1, true) ~= nil, true)
  end)

  test.it("appends raw markdown through doc mutations for wrapped views", function()
    local agent = Ollama()
    local conversation = Conversation(agent, "/tmp")
    conversation:add("assistant", "hello", { autosave = false })
    local view = PromptView({
      agent = agent,
      conversation = conversation
    })
    view:view_raw_markdown()

    local inserted = 0
    local removed = 0
    local old_insert = view.raw_transcript_doc.raw_insert
    local old_remove = view.raw_transcript_doc.raw_remove
    view.raw_transcript_doc.raw_insert = function(this, ...)
      inserted = inserted + 1
      return old_insert(this, ...)
    end
    view.raw_transcript_doc.raw_remove = function(this, ...)
      removed = removed + 1
      return old_remove(this, ...)
    end

    conversation:add("assistant", "world", { autosave = false })
    view:refresh()

    view.raw_transcript_doc.raw_insert = old_insert
    view.raw_transcript_doc.raw_remove = old_remove
    test.equal(inserted > 0, true)
    test.equal(removed, 0)
    test.equal(view.raw_transcript_doc:get_text(1, 1, math.huge, math.huge):find("world", 1, true) ~= nil, true)
  end)

  test.it("updates rendered markdown when switching back from raw markdown", function()
    local agent = Ollama()
    local conversation = Conversation(agent, "/tmp")
    conversation:add("assistant", "hello", { autosave = false })
    local view = PromptView({
      agent = agent,
      conversation = conversation
    })
    view:view_raw_markdown()
    conversation:add("assistant", "world", { autosave = false })
    view:refresh()

    local rendered_text
    view.transcript.set_text = function(this, text)
      rendered_text = text
      this.text = text
    end
    view:view_rendered_markdown()

    test.equal(rendered_text:find("world", 1, true) ~= nil, true)
    test.equal(view.transcript_mode, "rendered")
  end)

  test.it("starts loaded conversations at the transcript bottom", function()
    local agent = Ollama()
    local conversation = Conversation(agent, "/tmp")
    for i = 1, 40 do
      conversation:add("assistant", "line " .. i, { autosave = false })
    end
    local view = PromptView({
      agent = agent,
      conversation = conversation
    })
    view:set_position(0, 0)
    view:set_size(640, 220)
    view:update()

    local bottom = math.max(0, view.transcript:get_scrollable_size() - view.transcript.size.y)
    test.equal(view.transcript.scroll.y, bottom)
    test.equal(view.scroll_transcript_to_bottom_once, false)
  end)

  test.it("does not apply direct api keys to ollama by default", function()
    local old_config = config.plugins.assistant
    config.plugins.assistant = {
      agent = "ollama",
      agents = {
        ollama = {
          api_key = "openai-key",
          api_key_env = "OPENAI_API_KEY"
        }
      },
      stream = true
    }

    local view = PromptView({ agent_name = "ollama" })

    config.plugins.assistant = old_config
    test.equal(view.agent.api_key, nil)
    test.equal(view.agent.api_key_env, nil)
  end)

  test.it("applies configured keep alive for capable agents", function()
    local old_config = config.plugins.assistant
    config.plugins.assistant = {
      agent = "ollama",
      agents = {
        ollama = {
          keep_alive = "1h"
        }
      },
      stream = true
    }

    local view = PromptView({ agent_name = "ollama" })

    config.plugins.assistant = old_config
    test.equal(view.agent.keep_alive, "1h")
  end)

  test.it("registers tools for agent-name constructed conversations", function()
    local view = PromptView({ agent_name = "ollama" })

    test.not_nil(view.agent.tools.search)
    test.not_nil(view.agent.tools.exec_command)
    test.not_nil(view.agent.tools.list)
  end)

  test.it("shows context used for agents that report usage only", function()
    local agent = OpenAI({ options = { context = 100 } })
    local conversation = Conversation(agent, "/tmp")
    conversation:set_usage({ total_tokens = 35 })
    local view = PromptView({
      agent = agent,
      conversation = conversation,
      backend = {}
    })

    view:refresh()

    test.equal(view.status.label:find("35 context used", 1, true) ~= nil, true)
  end)

  test.it("updates context used from backend response usage", function()
    local agent = OpenAI({ options = { context = 100 } })
    local conversation = Conversation(agent, "/tmp")
    local view = PromptView({
      agent = agent,
      conversation = conversation,
      backend = {
        send = function(_, _, _, callback)
          callback(true, nil, "done", {
            done = true,
            usage = {
              prompt_tokens = 2501,
              completion_tokens = 99,
              total_tokens = 2600
            }
          })
        end
      }
    })

    view.prompt_doc:insert(1, 1, "hello")
    view:submit()

    test.equal(conversation:context_used(), 2600)
    test.equal(view.status.label:find("2600 context used", 1, true) ~= nil, true)
  end)

  test.it("shows context left for agents that report context", function()
    local agent = Codex()
    local conversation = Conversation(agent, "/tmp")
    conversation:set_usage({ total_tokens = 35, context = 100 })
    local view = PromptView({
      agent = agent,
      conversation = conversation,
      backend = {}
    })

    view:refresh()

    test.equal(view.status.label:find("65 context left", 1, true) ~= nil, true)
  end)

  test.it("keeps live conversation status in activity label, not header", function()
    local agent = Codex()
    agent:set_loading(true)
    local conversation = Conversation(agent, "/tmp")
    conversation:set_status("responding")
    local view = PromptView({
      agent = agent,
      conversation = conversation,
      backend = {
        ready = function() return true end,
        prepare = function(_, _, _, callback) callback(true) end
      }
    })

    view:refresh()

    test.equal(view.status.label:find("responding", 1, true), nil)
    test.equal(view.activity.label:find("Responding", 1, true) ~= nil, true)
  end)

  test.it("shows animated activity status between transcript and prompt", function()
    local agent = Codex()
    local conversation = Conversation(agent, "/tmp")
    conversation:set_status("responding")
    local view = PromptView({
      agent = agent,
      conversation = conversation,
      backend = {}
    })
    view:set_position(0, 0)
    view:set_size(640, 480)
    view:refresh()
    view:update()

    test.equal(view.activity.label:find("Responding", 1, true) ~= nil, true)
    test.equal(view.activity.position.y > view.transcript.position.y, true)
    test.equal(view.activity.position.y < view.prompt.position.y, true)
  end)

  test.it("shows animated compacting status", function()
    local agent = Ollama()
    local conversation = Conversation(agent, "/tmp")
    conversation:set_status("compacting")
    local view = PromptView({
      agent = agent,
      conversation = conversation,
      backend = {}
    })

    view:refresh()

    test.equal(view.activity.label:find("Compacting", 1, true) ~= nil, true)
    test.equal(view.activity_active, true)
  end)

  test.it("uses codex appserver backend by default", function()
    local agent = Codex()
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp")
    })

    test.equal(view.backend.name, "appserver")
  end)

  test.it("compacts conversations for capable agents", function()
    local agent = Codex()
    local compacted
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        compact = function(_, got_agent, got_conversation, callback)
          compacted = got_agent == agent and got_conversation ~= nil
          callback(true)
        end
      }
    })

    view:compact()

    test.equal(compacted, true)
  end)

  test.it("locally compacts conversations for local compact agents", function()
    local agent = Ollama()
    local compacted
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        local_compact = function(_, got_agent, got_conversation, callback)
          compacted = got_agent == agent and got_conversation ~= nil
          callback(true)
        end
      }
    })

    view:compact()

    test.equal(compacted, true)
  end)

  test.it("auto-compacts local conversations near context limit before sending", function()
    local old_auto_compact = config.plugins.assistant.auto_compact
    local old_threshold = config.plugins.assistant.auto_compact_threshold
    local old_min_new = config.plugins.assistant.auto_compact_min_new_messages
    config.plugins.assistant.auto_compact = true
    config.plugins.assistant.auto_compact_threshold = 0.5
    config.plugins.assistant.auto_compact_min_new_messages = 1

    local agent = Ollama()
    local conversation = Conversation(agent, "/tmp")
    conversation:set_usage({ total_tokens = 90, context = 100 })
    local compacted_before_send = false
    local sent_after_compaction = false
    local view = PromptView({
      agent = agent,
      conversation = conversation,
      backend = {
        local_compact = function(_, got_agent, got_conversation, callback)
          compacted_before_send = got_agent == agent and got_conversation == conversation
          got_conversation:record_local_compaction("Earlier turns summarized.")
          callback(true)
        end,
        send = function(_, got_agent, got_conversation, callback)
          sent_after_compaction = got_agent == agent
            and got_conversation == conversation
            and got_conversation.local_compaction ~= nil
          callback(true, nil, "done", { done = true })
        end
      }
    })

    view.prompt_doc:insert(1, 1, "continue")
    view:submit()

    config.plugins.assistant.auto_compact = old_auto_compact
    config.plugins.assistant.auto_compact_threshold = old_threshold
    config.plugins.assistant.auto_compact_min_new_messages = old_min_new

    test.equal(compacted_before_send, true)
    test.equal(sent_after_compaction, true)
    test.equal(view.conversation:last().message, "done")
  end)


  test.it("renames provider conversation before local title update", function()
    local agent = Codex()
    local conversation = Conversation(agent, "/tmp")
    conversation.codex_thread_id = "thr_1"
    local renamed
    local view = PromptView({
      agent = agent,
      conversation = conversation,
      backend = {
        rename_conversation = function(_, got_agent, got_conversation, title, callback)
          renamed = got_agent == agent
            and got_conversation == conversation
            and title == "New Title"
          callback(true)
        end
      }
    })

    view:rename_conversation(" New Title ")

    test.equal(renamed, true)
    test.equal(view.conversation.title, "New Title")
  end)

  test.it("generates a first-prompt title without adding title messages to context", function()
    local old_generate_titles = config.plugins.assistant.generate_conversation_titles
    config.plugins.assistant.generate_conversation_titles = true
    local agent = Ollama()
    local conversation = Conversation(agent, "/tmp")
    local title_prompt
    local sent
    local send_done
    local title_requested_after_response
    local view = PromptView({
      agent = agent,
      conversation = conversation,
      backend = {
        generate_conversation_title = function(_, got_agent, got_conversation, prompt, callback)
          title_prompt = got_agent == agent and got_conversation == conversation and prompt or nil
          title_requested_after_response = send_done == true
          callback(true, nil, "Tiny SDL Tetris")
        end,
        send = function(_, got_agent, got_conversation, callback)
          sent = got_agent == agent and got_conversation == conversation
          callback(true, nil, "partial", { done = false })
          send_done = true
          callback(true, nil, "done", { done = true })
        end
      }
    })

    view:dispatch_prompt_turn("Create a tiny SDL2 Tetris game.")

    config.plugins.assistant.generate_conversation_titles = old_generate_titles
    test.equal(title_prompt, "Create a tiny SDL2 Tetris game.")
    test.equal(sent, true)
    test.equal(title_requested_after_response, true)
    test.equal(view.conversation.title, "Tiny SDL Tetris")
    test.equal(view.name, "Tiny SDL Tetris")
    test.equal(#view.conversation.messages, 4)
    test.equal(view.conversation.messages[1].role, "system")
    test.equal(view.conversation.messages[2].role, "user")
    test.equal(view.conversation.messages[2].meta.environment_context, true)
    test.equal(view.conversation.messages[3].role, "user")
    test.equal(view.conversation.messages[4].role, "assistant")
    for _, message in ipairs(view.conversation:to_provider_messages()) do
      test.equal(tostring(message.content or ""):find("Generate a concise title", 1, true), nil)
    end
  end)

  test.it("compact predicate accepts active prompt child for capable agents", function()
    local agent = Codex()
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        compact = function() end
      }
    })

    core.active_view = view.prompt
    local ok, active = PromptView.compact_predicate()

    test.equal(ok ~= false and ok ~= nil, true)
    test.equal(active, view)
  end)

  test.it("active predicate accepts active prompt child", function()
    local agent = Ollama()
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp")
    })

    core.active_view = view.prompt
    local ok, active = PromptView.active_predicate()

    test.equal(ok, true)
    test.equal(active, view)
  end)

  test.it("toolbar buttons use assistant commands for tooltip metadata", function()
    local agent = Ollama()
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp")
    })

    test.equal(view.insert_file_button.tooltip_command, "assistant-conversation:insert-file")
    test.equal(view.insert_project_file_button.tooltip_command, "assistant-conversation:insert-project-file")
    test.equal(view.send_button.tooltip_command, "assistant-conversation:send")
    test.equal(view.model_button.tooltip_command, "assistant-conversation:select-model")
    test.equal(view.cancel_button.tooltip_command, "assistant-conversation:cancel")
    test.equal(view.compact_button.tooltip_command, "assistant-conversation:compact")
    test.equal(view.clear_button.tooltip_command, "assistant-conversation:clear-prompt")
    test.equal(view.insert_file_button.label, "")
    test.equal(view.insert_project_file_button.label, "")
    test.equal(view.send_button.label, "")
    test.equal(view.model_button.label, "")
    test.equal(view.cancel_button.label, "")
    test.equal(view.compact_button.label, "")
    test.equal(view.clear_button.label, "")
    test.equal(view.insert_file_button.icon.code, "D")
    test.equal(view.insert_project_file_button.icon.code, "L")
    test.equal(view.send_button.icon.code, ">")
    test.equal(view.model_button.icon.code, "K")
    test.equal(view.cancel_button.icon.code, "!")
    test.equal(view.compact_button.icon.code, "N")
    test.equal(view.clear_button.icon.code, "C")
  end)

  test.it("shows compact toolbar button only for capable agents", function()
    local ollama_view = PromptView({
      agent = Ollama(),
      conversation = Conversation(Ollama(), "/tmp")
    })
    ollama_view:refresh()

    local codex = Codex()
    local codex_view = PromptView({
      agent = codex,
      conversation = Conversation(codex, "/tmp")
    })
    codex_view:refresh()

    test.equal(ollama_view.compact_button:is_visible(), true)
    test.equal(codex_view.compact_button:is_visible(), true)
  end)

  test.it("shows collaboration mode selector for capable agents", function()
    local agent = Codex()
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        prepare = function(_, _, _, callback) callback(true) end,
        list_collaboration_modes = function(_, _, callback)
          callback(true, nil, {
            { id = "default", label = "Implementation", mode = "default", model = "gpt-5.3-codex" },
            { id = "plan", label = "Plan" }
          })
        end
      }
    })

    view:refresh()

    test.equal(view.mode_select:is_visible(), true)
    test.equal(view.conversation.collaboration_mode, "default")
    view.mode_select:set_selected(2)
    test.equal(view.conversation.collaboration_mode, "plan")
  end)

  test.it("keeps collaboration mode selector synced when mode is set programmatically", function()
    local agent = Codex()
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        prepare = function(_, _, _, callback) callback(true) end,
        list_collaboration_modes = function(_, _, callback)
          callback(true, nil, {
            { id = "default", label = "Implementation", mode = "default", model = "gpt-5.3-codex" },
            { id = "plan", label = "Plan" }
          })
        end
      }
    })

    view:refresh()
    view:set_collaboration_mode("plan")

    test.equal(view.conversation.collaboration_mode, "plan")
    test.equal(view.mode_select:get_selected_data(), "plan")

    view:set_collaboration_mode("implementation")

    test.equal(view.conversation.collaboration_mode, "implementation")
    test.equal(view.mode_select:get_selected_data(), "default")
  end)

  test.it("shows collaboration mode selector for generic tool agents", function()
    local agent = Ollama()
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        prepare = function(_, _, _, callback) callback(true) end
      }
    })

    view:refresh()

    test.equal(view.mode_select:is_visible(), true)
    test.equal(view.conversation.collaboration_mode, "implementation")
    view.mode_select:set_selected(2)
    test.equal(view.conversation.collaboration_mode, "plan")
  end)

  test.it("cycles collaboration modes", function()
    local agent = Ollama()
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        prepare = function(_, _, _, callback) callback(true) end
      }
    })

    view:refresh()

    test.equal(view.conversation.collaboration_mode, "implementation")
    test.equal(view:cycle_collaboration_mode(), true)
    test.equal(view.conversation.collaboration_mode, "plan")
    test.equal(view:cycle_collaboration_mode(), true)
    test.equal(view.conversation.collaboration_mode, "implementation")
  end)

  test.it("hides collaboration mode selector for agents without mode support", function()
    local agent = Agent({ capabilities = { collaboration_modes = false } })
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        prepare = function(_, _, _, callback) callback(true) end
      }
    })

    view:refresh()

    test.equal(view.mode_select:is_visible(), false)
  end)

  test.it("places collaboration mode selector before toolbar buttons", function()
    local agent = Codex()
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        prepare = function(_, _, _, callback) callback(true) end,
        list_collaboration_modes = function(_, _, callback)
          callback(true, nil, {
            { id = "default", label = "Implementation", mode = "default", model = "gpt-5.3-codex" },
            { id = "plan", label = "Plan" }
          })
        end
      }
    })
    view:set_position(0, 0)
    view:set_size(1500, 360)
    view:refresh()
    view:update()

    test.equal(view.mode_select.position.x + view.mode_select.size.x < view.model_button.position.x, true)
    test.equal(view.status.position.x + view.status.size.x < view.mode_select.position.x, true)
    test.equal(view.line.position.y > view.mode_select.position.y + view.mode_select.size.y, true)
    test.equal(view.model_button.position.y, view.mode_select.position.y)
    test.equal(view.cancel_button.position.y, view.mode_select.position.y)
    test.equal(view.compact_button.position.y, view.mode_select.position.y)
    test.equal(view.model_button.size.y + view.model_button.border.width * 2, view.mode_select.size.y + view.mode_select.border.width * 2)
    test.equal(view.cancel_button.size.y + view.cancel_button.border.width * 2, view.mode_select.size.y + view.mode_select.border.width * 2)
    test.equal(view.compact_button.size.y + view.compact_button.border.width * 2, view.mode_select.size.y + view.mode_select.border.width * 2)
  end)

  test.it("places prompt action buttons above the prompt editor on the right", function()
    local agent = Codex()
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        prepare = function(_, _, _, callback) callback(true) end,
        list_collaboration_modes = function(_, _, callback)
          callback(true, nil, {
            { id = "default", label = "Implementation", mode = "default", model = "gpt-5.3-codex" },
            { id = "plan", label = "Plan" }
          })
        end
      }
    })
    view:set_position(0, 0)
    view:set_size(1000, 480)
    view:refresh()
    view:update()

    test.equal(view.send_button.position.y + view.send_button.size.y <= view.prompt.position.y, true)
    test.equal(view.insert_file_button.position.y + view.insert_file_button.size.y <= view.prompt.position.y, true)
    test.equal(view.insert_project_file_button.position.y + view.insert_project_file_button.size.y <= view.prompt.position.y, true)
    test.equal(view.clear_button.position.y + view.clear_button.size.y <= view.prompt.position.y, true)
    test.equal(view.insert_file_button.position.x > view.activity.position.x + view.activity.size.x, true)
    test.equal(view.insert_project_file_button.position.x > view.insert_file_button.position.x + view.insert_file_button.size.x, true)
    test.equal(view.send_button.position.x > view.insert_project_file_button.position.x + view.insert_project_file_button.size.x, true)
    test.equal(view.clear_button.position.x > view.send_button.position.x + view.send_button.size.x, true)
    test.equal(view.send_button.position.y > view.line.position.y, true)
    test.equal(view.insert_file_button.position.y > view.line.position.y, true)
    test.equal(view.insert_project_file_button.position.y > view.line.position.y, true)
    test.equal(view.clear_button.position.y > view.line.position.y, true)
  end)

  test.it("compact predicate rejects agents without compact capability", function()
    local agent = Agent({ capabilities = { compact = false, local_compact = false } })
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        compact = function() end
      }
    })

    core.active_view = view
    local ok = PromptView.compact_predicate()

    test.equal(ok, false)
  end)

  test.it("ignores successful callbacks that arrive after cancellation", function()
    local agent = Codex()
    local callback
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        send = function(_, _, _, cb)
          callback = cb
        end,
        cancel = function() end
      }
    })

    view.prompt_doc:insert(1, 1, "hello")
    view:submit()
    view:cancel()

    callback(true, nil, "late response", { partial = true })

    test.equal(view.pending_assistant, nil)
    test.equal(view.conversation:last().role, "user")
  end)

  test.it("queues prompts submitted while a turn is active", function()
    local agent = Codex()
    local callbacks = {}
    local send_count = 0
    local function non_system_messages(conversation)
      local messages = {}
      for _, message in ipairs(conversation.messages or {}) do
        if message.role ~= "system" and not (message.meta and message.meta.provider_only) then
          table.insert(messages, message)
        end
      end
      return messages
    end
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        send = function(_, _, _, cb)
          send_count = send_count + 1
          callbacks[send_count] = cb
        end
      }
    })

    view.prompt_doc:insert(1, 1, "first")
    view:submit()
    view.prompt_doc:insert(1, 1, "second")
    view:submit()

    test.equal(send_count, 1)
    test.equal(#view.prompt_queue, 1)
    local messages = non_system_messages(view.conversation)
    test.equal(messages[1].message, "first")
    test.equal(messages[2], nil)
    test.equal(view.status.label:find("1 queued", 1, true) ~= nil, true)

    callbacks[1](true, nil, "first response", { done = true })

    test.equal(send_count, 2)
    test.equal(#view.prompt_queue, 0)
    messages = non_system_messages(view.conversation)
    test.equal(messages[1].message, "first")
    test.equal(messages[2].message, "first response")
    test.equal(messages[3].message, "second")

    callbacks[2](true, nil, "second response", { done = true })

    messages = non_system_messages(view.conversation)
    test.equal(messages[4].message, "second response")
  end)

  test.it("does not let queued prompts invalidate active turn callbacks", function()
    local agent = Codex()
    local callback
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        send = function(_, _, _, cb)
          callback = cb
        end
      }
    })

    view.prompt_doc:insert(1, 1, "first")
    view:submit()
    view.prompt_doc:insert(1, 1, "second")
    view:submit()
    callback(true, nil, "partial one", { partial = true })

    test.not_nil(view.pending_assistant)
    test.equal(view.pending_assistant.message, "partial one")
    test.equal(#view.prompt_queue, 1)
  end)

  test.it("clears queued prompts on cancellation", function()
    local agent = Codex()
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        send = function() end,
        cancel = function() end
      }
    })

    view.prompt_doc:insert(1, 1, "first")
    view:submit()
    view.prompt_doc:insert(1, 1, "second")
    view:submit()
    view:cancel()

    test.equal(#view.prompt_queue, 0)
    test.equal(view.active_prompt_turn, false)
  end)

  test.it("does not add assistant placeholder before provider output", function()
    local agent = Codex()
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        send = function() end
      }
    })

    view.prompt_doc:insert(1, 1, "hello")
    view:submit()

    test.equal(view.pending_assistant, nil)
    test.equal(view.conversation:last().role, "user")
    test.equal(view.conversation:to_markdown():find("## Assistant", 1, true), nil)
  end)

  test.it("does not add an empty assistant message before approval requests", function()
    local old_warning = MessageBox.warning
    MessageBox.warning = function() end

    local agent = Codex()
    local callback
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        send = function(_, _, _, cb)
          callback = cb
        end,
        resolve_approval = function() end
      }
    })

    view.prompt_doc:insert(1, 1, "hello")
    view:submit()
    callback(true, nil, nil, {
      event = "approval_request",
      request = { id = "approval-1", title = "Approve", body = "Approve?" }
    })

    MessageBox.warning = old_warning

    test.equal(view.pending_assistant, nil)
    test.equal(view.pending_approval_request.id, "approval-1")
    test.equal(view.conversation:last().role, "user")
    test.equal(view.conversation:to_markdown():find("## Assistant", 1, true), nil)
  end)

  test.it("does not add an empty assistant message before user-input requests", function()
    local old_enter = core.command_view.enter
    core.command_view.enter = function() end

    local agent = Codex()
    local callback
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        send = function(_, _, _, cb)
          callback = cb
        end,
        resolve_user_input = function() end
      }
    })

    view.prompt_doc:insert(1, 1, "hello")
    view:submit()
    callback(true, nil, nil, {
      event = "user_input_request",
      request = {
        id = "input-1",
        questions = {
          { id = "choice", question = "Choose", options = { "Yes", "No" } }
        }
      }
    })

    core.command_view.enter = old_enter

    test.equal(view.pending_assistant, nil)
    test.equal(view.pending_user_input_request.id, "input-1")
    test.equal(view.conversation:last().role, "assistant")
    test.equal(view.conversation:last().meta.user_input_prompt, true)
    local md = view.conversation:to_markdown()
    test.equal(md:find("## Assistant\n\n$", 1) == nil, true)
  end)

  test.it("refreshes controls for backend config updates without adding transcript text", function()
    local agent = Codex()
    local callback
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        send = function(_, _, _, cb)
          callback = cb
        end
      }
    })

    view.prompt_doc:insert(1, 1, "hello")
    view:submit()
    agent.model = "Auto"
    view.conversation.collaboration_mode = "plan"
    callback(true, nil, "", { event = "config_update", partial = true })

    test.equal(view.status.label:find("Auto", 1, true) ~= nil, true)
    test.equal(view.pending_assistant, nil)
    test.equal(view.conversation:last().role, "user")
  end)

  test.it("refreshes for backend activity updates without adding transcript text", function()
    local agent = Codex()
    local callback
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        send = function(_, _, _, cb)
          callback = cb
        end
      }
    })

    view.prompt_doc:insert(1, 1, "hello")
    view:submit()
    callback(true, nil, "", { event = "activity_update", partial = true })

    test.equal(view.pending_assistant, nil)
    test.equal(view.conversation:last().role, "user")
    test.equal(view.conversation:to_markdown():find("## Assistant", 1, true), nil)
  end)

  test.it("refreshes transcript text for backend activity updates", function()
    local agent = Codex()
    local callback
    local conversation = Conversation(agent, "/tmp")
    local view = PromptView({
      agent = agent,
      conversation = conversation,
      backend = {
        send = function(_, _, _, cb)
          callback = cb
        end
      }
    })

    view.prompt_doc:insert(1, 1, "hello")
    view:submit()
    conversation:add("activity", "Inspecting project\n\nTool: `read`\nPath: `/tmp/main.c`\nStatus: requested", {
      autosave = false
    })
    callback(true, nil, "", { event = "activity_update", partial = true })

    test.equal(view.transcript_markdown_text:find("**Reading**: `/tmp/main.c` (requested)", 1, true) ~= nil, true)
    test.equal(view.conversation:to_markdown():find("## Assistant", 1, true), nil)
  end)

  test.it("does not rebuild transcript for activity updates while assistant text is streaming", function()
    local agent = Codex()
    local callback
    local conversation = Conversation(agent, "/tmp")
    local view = PromptView({
      agent = agent,
      conversation = conversation,
      backend = {
        send = function(_, _, _, cb)
          callback = cb
        end
      }
    })

    local set_text_calls = 0
    local original_set_text = view.transcript.set_text
    view.transcript.set_text = function(this, text)
      set_text_calls = set_text_calls + 1
      return original_set_text(this, text)
    end

    view.prompt_doc:insert(1, 1, "hello")
    view:submit()
    callback(true, nil, "partial", { partial = true })
    set_text_calls = 0
    conversation:add("activity", "Inspecting project\n\nTool: `read`\nPath: `/tmp/main.c`\nStatus: requested", {
      autosave = false
    })
    callback(true, nil, "", { event = "activity_update", partial = true })

    test.not_nil(view.pending_assistant)
    test.equal(view.pending_assistant.message, "partial")
    test.equal(set_text_calls, 0)
  end)

  test.it("force-refreshes plan updates while assistant text is streaming", function()
    local agent = Codex()
    local callback
    local conversation = Conversation(agent, "/tmp")
    local view = PromptView({
      agent = agent,
      conversation = conversation,
      backend = {
        send = function(_, _, _, cb)
          callback = cb
        end
      }
    })

    view.prompt_doc:insert(1, 1, "hello")
    view:submit()
    callback(true, nil, "partial", { partial = true })
    conversation:add("assistant", "### Plan Updated\n\n- [x] Verify all changes\n- [x] Commit changes", {
      meta = { plan_update = true },
      autosave = false
    })
    callback(true, nil, "", {
      event = "activity_update",
      partial = true,
      force_transcript = true
    })

    test.not_nil(view.pending_assistant)
    test.equal(view.pending_assistant.message, "partial")
    test.equal(view.transcript_markdown_text:find("- [x] Verify all changes", 1, true) ~= nil, true)
    test.equal(view.transcript_markdown_text:find("- [x] Commit changes", 1, true) ~= nil, true)
  end)

  test.it("adds assistant heading when provider output arrives", function()
    local agent = Codex()
    local callback
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        send = function(_, _, _, cb)
          callback = cb
        end
      }
    })

    view.prompt_doc:insert(1, 1, "hello")
    view:submit()
    callback(true, nil, "hi", { partial = true })

    test.not_nil(view.pending_assistant)
    test.equal(view.conversation:last().role, "assistant")
    test.equal(view.conversation:last().message, "hi")
    test.equal(view.conversation:to_markdown():find("## Assistant", 1, true) ~= nil, true)
  end)

  test.it("keeps tool results before the assistant reply", function()
    local old_enter = core.command_view.enter
    core.command_view.enter = function() end

    local agent = Ollama()
    local callback
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        send = function(_, _, _, cb)
          callback = cb
        end,
        resolve_tool_call = function() end
      }
    })

    view.prompt_doc:insert(1, 1, "list files")
    view:submit()
    view.conversation:add("tool_call", "Tool: list", { autosave = false })
    callback(true, nil, nil, {
      event = "tool_call_request",
      request = {
        id = "call_1",
        title = "Approve tool",
        body = "Tool: list"
      }
    })
    view.conversation:add("tool_result", "Tool: list\nStatus: ok\nResult:\na.lua", { autosave = false })
    callback(true, nil, "listed files", { done = true })

    core.command_view.enter = old_enter

    test.equal(view.conversation.messages[2].meta.environment_context, true)
    test.equal(view.conversation.messages[3].role, "user")
    test.equal(view.conversation.messages[4].role, "tool_call")
    test.equal(view.conversation.messages[5].role, "tool_result")
    test.equal(view.conversation.messages[6].role, "assistant")
    test.equal(view.conversation.messages[6].message, "listed files")
  end)

  test.it("starts a new assistant message after streamed tool results", function()
    local old_enter = core.command_view.enter
    core.command_view.enter = function() end

    local agent = Ollama()
    local callback
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        send = function(_, _, _, cb)
          callback = cb
        end,
        resolve_tool_call = function() end
      }
    })

    view.prompt_doc:insert(1, 1, "fetch web page")
    view:submit()
    callback(true, nil, "I'll fetch it.", { partial = true })
    view.conversation:add("tool_call", "Tool: web_fetch", { autosave = false })
    callback(true, nil, nil, {
      event = "tool_call_request",
      request = {
        id = "call_1",
        title = "Approve tool",
        body = "Tool: web_fetch"
      }
    })
    view.conversation:add("tool_result", "Tool: web_fetch\nStatus: ok\nResult:\n<html>", { autosave = false })
    callback(true, nil, "# SDL3\nFinal answer", { partial = true })
    callback(true, nil, "# SDL3\nFinal answer", { done = true })

    core.command_view.enter = old_enter

    test.equal(view.conversation.messages[4].role, "assistant")
    test.equal(view.conversation.messages[4].message, "I'll fetch it.")
    test.equal(view.conversation.messages[5].role, "tool_call")
    test.equal(view.conversation.messages[6].role, "tool_result")
    test.equal(view.conversation.messages[7].role, "assistant")
    test.equal(view.conversation.messages[7].message, "# SDL3\nFinal answer")
  end)

  test.it("finalizes streamed assistant preambles before tool calls", function()
    local old_enter = core.command_view.enter
    core.command_view.enter = function() end

    local agent = Ollama()
    local callback
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        send = function(_, _, _, cb)
          callback = cb
        end,
        resolve_tool_call = function() end
      }
    })

    view.prompt_doc:insert(1, 1, "inspect")
    view:submit()
    callback(true, nil, "Let", { partial = true })
    view.conversation:add("tool_call", "Tool: read", { autosave = false })
    callback(true, nil, nil, {
      event = "tool_call_request",
      request = {
        id = "call_1",
        title = "Approve tool",
        body = "Tool: read"
      }
    })

    core.command_view.enter = old_enter

    test.equal(view.conversation.messages[4].role, "assistant")
    test.equal(view.conversation.messages[4].message, "Let")
    test.equal(view.conversation.messages[5].role, "tool_call")
    test.equal(view.conversation:to_markdown():find("## Assistant\n\nLet", 1, true) ~= nil, true)
  end)

  test.it("rebuilds streamed preamble markdown before showing tool activity", function()
    local old_enter = core.command_view.enter
    core.command_view.enter = function() end

    local agent = Ollama()
    local callback
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        send = function(_, _, _, cb)
          callback = cb
        end,
        resolve_tool_call = function() end
      }
    })

    view.prompt_doc:insert(1, 1, "inspect")
    view:submit()
    callback(true, nil, "Let me explore ", { partial = true })
    callback(true, nil, "the project ", { partial = true })
    callback(true, nil, "to give you a good overview.", { partial = true })
    view.conversation:add("tool_call", "Tool: read", { autosave = false })
    callback(true, nil, nil, {
      event = "tool_call_request",
      request = {
        id = "call_1",
        title = "Approve tool",
        body = "Tool: read"
      }
    })

    core.command_view.enter = old_enter

    local preamble = "Let me explore the project to give you a good overview."
    test.equal(view.conversation.messages[4].role, "assistant")
    test.equal(view.conversation.messages[4].message, preamble)
    test.equal(view.transcript_markdown_text:find("## Assistant\n\n" .. preamble, 1, true) ~= nil, true)
    test.equal(view.transcript_markdown_text:find("## Assistant\n\nto give you a good overview.", 1, true), nil)
  end)

  test.it("does not add an error message for cancelled requests", function()
    local agent = Codex()
    local callback
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        send = function(_, _, _, cb)
          callback = cb
        end,
        cancel = function() end
      }
    })

    view.prompt_doc:insert(1, 1, "hello")
    view:submit()

    callback(false, "request cancelled")

    test.equal(view.pending_assistant, nil)
    test.equal(view.conversation:last().role, "user")
  end)

  test.it("answers assistant user-input requests through command view suggestions", function()
    local old_enter = core.command_view.enter
    local entered_label
    core.command_view.enter = function(_, label, options)
      entered_label = label
      local suggestions = options.suggest("")
      options.submit("Yes", suggestions[1])
    end

    local agent = Codex()
    local resolved
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        resolve_user_input = function(_, got_agent, got_conversation, request, ok, answers, callback)
          resolved = {
            agent = got_agent,
            conversation = got_conversation,
            request = request,
            ok = ok,
            answers = answers
          }
          callback(true)
        end
      }
    })

    view:handle_user_input_request({
      id = "4",
      provider_id = 4,
      questions = {
        {
          id = "choice",
          header = "Decision",
          question = "Proceed?",
          options = {
            { label = "Yes", value = "Yes", description = "Continue" }
          }
        }
      }
    })

    core.command_view.enter = old_enter

    test.equal(entered_label, "Answer")
    test.equal(view.conversation:last().role, "assistant")
    test.equal(view.conversation:last().meta.user_input_prompt, true)
    test.equal(view.conversation:last().message:find("### Question", 1, true) ~= nil, true)
    test.equal(view.conversation:last().message:find("**Decision**", 1, true) ~= nil, true)
    test.equal(view.conversation:last().message:find("Proceed?", 1, true) ~= nil, true)
    test.equal(resolved.agent, agent)
    test.equal(resolved.conversation, view.conversation)
    test.equal(resolved.ok, true)
    test.equal(resolved.answers.choice, "Yes")
  end)

  test.it("shows string options for assistant user-input requests", function()
    local old_enter = core.command_view.enter
    local entered_suggestions
    core.command_view.enter = function(_, label, options)
      test.equal(label, "Answer")
      entered_suggestions = options.suggest("")
      options.submit("No", entered_suggestions[2])
    end

    local agent = Codex()
    local resolved
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        resolve_user_input = function(_, _, _, _, _, answers, callback)
          resolved = answers
          callback(true)
        end
      }
    })

    view:handle_user_input_request({
      id = "string-options",
      questions = {
        {
          id = "answer",
          header = "Question",
          question = "Proceed?",
          options = { "Yes", "No" }
        }
      }
    })

    core.command_view.enter = old_enter

    test.equal(#entered_suggestions, 2)
    test.equal(entered_suggestions[1].text, "Yes")
    test.equal(entered_suggestions[2].text, "No")
    test.equal(resolved.answer, "No")
  end)

  test.it("does not duplicate displayed user-input questions when reopened", function()
    local old_enter = core.command_view.enter
    local enter_count = 0
    core.command_view.enter = function(_, _, options)
      enter_count = enter_count + 1
      options.cancel(true)
    end

    local agent = Codex()
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        resolve_user_input = function() end
      }
    })
    local request = {
      id = "4",
      questions = {
        {
          id = "answer",
          question = "What should I do next?",
          allow_other = true
        }
      }
    }

    view:handle_user_input_request(request)
    view:respond_to_pending_request()

    core.command_view.enter = old_enter

    local displayed = 0
    for _, message in ipairs(view.conversation.messages) do
      if message.meta and message.meta.user_input_prompt then
        displayed = displayed + 1
      end
    end
    test.equal(enter_count, 2)
    test.equal(displayed, 1)
  end)

  test.it("answers assistant approval requests through a confirmation dialog", function()
    local old_warning = MessageBox.warning
    local dialog_title
    MessageBox.warning = function(title, _, callback)
      dialog_title = title
      callback(nil, 1)
    end

    local agent = Codex()
    local resolved
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        resolve_approval = function(_, got_agent, got_conversation, request, decision, callback)
          resolved = {
            agent = got_agent,
            conversation = got_conversation,
            request = request,
            decision = decision
          }
          callback(true)
        end
      }
    })

    view:handle_approval_request({
      id = "4",
      provider_id = 4,
      kind = "command",
      title = "Approve Command",
      body = "Run make test?"
    })

    MessageBox.warning = old_warning

    test.equal(dialog_title, "Approve Command")
    test.equal(resolved.agent, agent)
    test.equal(resolved.conversation, view.conversation)
    test.equal(resolved.decision, "accept")
  end)

  test.it("resolves burst approval dialogs against their original requests", function()
    local old_warning = MessageBox.warning
    local callbacks = {}
    MessageBox.warning = function(_, _, callback)
      callbacks[#callbacks + 1] = callback
    end

    local agent = Codex()
    local resolved = {}
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        resolve_approval = function(_, _, _, request, decision, callback)
          resolved[#resolved + 1] = {
            id = request.id,
            decision = decision
          }
          callback(true)
        end
      }
    })

    view:handle_approval_request({ id = "first", title = "First", body = "Approve first?" })
    view:handle_approval_request({ id = "second", title = "Second", body = "Approve second?" })
    callbacks[1](nil, 1)
    callbacks[2](nil, 2)

    MessageBox.warning = old_warning

    test.equal(#resolved, 2)
    test.equal(resolved[1].id, "first")
    test.equal(resolved[1].decision, "accept")
    test.equal(resolved[2].id, "second")
    test.equal(resolved[2].decision, "decline")
  end)

  test.it("answers assistant tool calls through command view suggestions", function()
    local old_enter = core.command_view.enter
    local entered_label
    core.command_view.enter = function(_, label, options)
      entered_label = label
      local suggestions = options.suggest("")
      options.submit("Allow", suggestions[1])
    end

    local agent = Ollama()
    local resolved
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        resolve_tool_call = function(_, got_agent, got_conversation, request, decision, callback)
          resolved = {
            agent = got_agent,
            conversation = got_conversation,
            request = request,
            decision = decision
          }
          callback(true)
        end
      }
    })

    view:handle_tool_call_request({
      id = "call_1",
      title = "Approve tool",
      body = "Tool: read\nArguments:\n{}"
    })

    core.command_view.enter = old_enter

    test.equal(entered_label, "Approve tool")
    test.equal(resolved.agent, agent)
    test.equal(resolved.conversation, view.conversation)
    test.equal(resolved.decision, "allow")
  end)

  test.it("keeps tool call pending when approval command view is cancelled", function()
    local old_enter = core.command_view.enter
    core.command_view.enter = function(_, _, options)
      options.cancel(true)
    end

    local agent = Ollama()
    local resolved = false
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        resolve_tool_call = function()
          resolved = true
        end
      }
    })
    local request = {
      id = "call_1",
      title = "Approve tool",
      body = "Tool: read\nArguments:\n{}"
    }

    view:handle_tool_call_request(request)

    core.command_view.enter = old_enter
    test.equal(resolved, false)
    test.equal(view.pending_tool_call_request, request)
  end)

  test.it("reopens pending tool requests", function()
    local old_enter = core.command_view.enter
    local enters = 0
    core.command_view.enter = function(_, _, options)
      enters = enters + 1
      if enters == 2 then
        local suggestions = options.suggest("")
        options.submit("Allow", suggestions[1])
      end
    end

    local agent = Ollama()
    local resolved
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        resolve_tool_call = function(_, _, _, request, decision, callback)
          resolved = {
            request = request,
            decision = decision
          }
          callback(true)
        end
      }
    })
    local request = {
      id = "call_1",
      title = "Approve tool",
      body = "Tool: read\nArguments:\n{}"
    }

    view:handle_tool_call_request(request)
    view:respond_to_pending_request()

    core.command_view.enter = old_enter
    test.equal(enters, 2)
    test.equal(resolved.request, request)
    test.equal(resolved.decision, "allow")
    test.equal(view.pending_tool_call_request, nil)
  end)

  test.it("shows tool call statuses in the activity label", function()
    local agent = Ollama()
    local conversation = Conversation(agent, "/tmp")
    conversation:set_status("waiting for tool approval", { autosave = false })
    local view = PromptView({
      agent = agent,
      conversation = conversation,
      backend = {}
    })

    view:refresh()

    test.equal(view.activity.label:find("Waiting for tool approval", 1, true) ~= nil, true)
  end)

  test.it("clears pending interaction requests when backend reports resolution", function()
    local agent = Codex()
    local callback
    local view = PromptView({
      agent = agent,
      conversation = Conversation(agent, "/tmp"),
      backend = {
        send = function(_, _, _, cb)
          callback = cb
        end
      }
    })

    view.prompt_doc:insert(1, 1, "hello")
    view:submit()
    view.pending_approval_request = { id = "4" }

    callback(true, nil, "", {
      partial = true,
      event = "request_resolved",
      request_id = "4"
    })

    test.equal(view.pending_approval_request, nil)
  end)
end)
