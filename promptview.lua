local core = require "core"
local command = require "core.command"
local config = require "core.config"
local ContextMenu = require "core.contextmenu"
local keymap = require "core.keymap"
local style = require "core.style"
local Widget = require "widget"
local Button = require "widget.button"
local Label = require "widget.label"
local Line = require "widget.line"
local MessageBox = require "widget.messagebox"
local SelectBox = require "widget.selectbox"
local Doc = require "core.doc"
local DocView = require "core.docview"
local MarkdownView = require "core.markdownview"
local Conversation = require "plugins.assistant.conversation"
local tools = require "plugins.assistant.tools"
local HttpBackend = require "plugins.assistant.backend.http"
local AppServerBackend = require "plugins.assistant.backend.appserver"
local CliBackend = require "plugins.assistant.backend.cli"
local AcpBackend = require "plugins.assistant.backend.acp"
local ModelDialog = require "plugins.assistant.ui.modeldialog"
local Ollama = require "plugins.assistant.agent.ollama"
local LlamaCpp = require "plugins.assistant.agent.llamacpp"
local Lms = require "plugins.assistant.agent.lms"
local OpenAI = require "plugins.assistant.agent.openai"
local Codex = require "plugins.assistant.agent.codex"
local Acp = require "plugins.assistant.agent.acp"
local Copilot = require "plugins.assistant.agent.copilot"

---Main assistant conversation UI.
---
---`PromptView` embeds a rendered transcript, raw transcript view, prompt
---editor, toolbar controls, backend turn dispatch, and pending approval/input
---dialogs.
---@class assistant.PromptView : widget
---@field agent assistant.Agent
---@field backend assistant.Backend
---@field conversation assistant.Conversation
---@field prompt_doc core.doc
---@field prompt_view core.docview
---@field transcript_view core.markdownview
---@field raw_transcript_view core.docview
---@field pending_tool_call_request table|nil
---@field pending_user_input_request table|nil
---@field pending_approval_request table|nil
local PromptView = Widget:extend()

local STREAMING_TRANSCRIPT_REFRESH_INTERVAL = 0.05

PromptView.context = "session"
PromptView.transcript_menu = ContextMenu()
PromptView.raw_transcript_menu = ContextMenu()

local DEFAULT_AGENT_CLASSES = {
  ollama = Ollama,
  llamacpp = LlamaCpp,
  lms = Lms,
  openai = OpenAI,
  codex = Codex,
  acp = Acp,
  copilot = Copilot
}

---Return the text.
local function get_text(doc)
  return doc:get_text(1, 1, math.huge, math.huge):gsub("%s+$", "")
end

---Set the doc text.
local function set_doc_text(doc, text)
  text = text or ""
  local line, col = #doc.lines, #doc.lines[#doc.lines]
  if line > 1 or col > 1 then
    doc:remove(1, 1, line, col)
  end
  if text ~= "" then
    doc:insert(1, 1, text)
  end
  doc:reset_syntax()
  doc:set_selection(#doc.lines, #doc.lines[#doc.lines])
  doc:clear_undo_redo()
  doc:clean()
end

---Handle contains.
local function contains(view, x, y)
  return x >= view.position.x
    and y >= view.position.y
    and x <= view.position.x + view.size.x
    and y <= view.position.y + view.size.y
end

---Handle view is at bottom.
local function view_is_at_bottom(view)
  local max_scroll = math.max(0, view:get_scrollable_size() - view.size.y)
  local y = math.max(view.scroll.y or 0, view.scroll.to.y or 0)
  return max_scroll <= 1 or y >= max_scroll - 2
end

---Handle scroll view to bottom.
local function scroll_view_to_bottom(view)
  if view.ensure_layout then view:ensure_layout() end
  local max_scroll = math.max(0, view:get_scrollable_size() - view.size.y)
  view.scroll.to.y = max_scroll
  view.scroll.y = max_scroll
end

---Handle widget width.
local function widget_width(widget)
  return widget:get_size().x + widget.border.width * 2
end

---Handle widget height.
local function widget_height(widget)
  return widget:get_size().y + widget.border.width * 2
end

---Handle configure icon button.
local function configure_icon_button(button, icon)
  button:set_icon(icon)
  button.padding.x = button.padding.x / 2
  button.padding.y = button.padding.y / 5
end

---Handle mode id.
local function mode_id(mode)
  return type(mode) == "table" and (mode.id or mode.name or mode.mode) or mode
end

---Normalize normalized mode id.
local function normalized_mode_id(mode)
  mode = tostring(mode or ""):lower()
  if mode == "implementation" then return "default" end
  return mode
end

---Handle mode matches.
local function mode_matches(row_data, selected)
  return row_data == selected
    or normalized_mode_id(row_data) == normalized_mode_id(selected)
end

---Handle mode label.
local function mode_label(mode)
  if type(mode) == "table" then
    return mode.label or mode.displayName or mode.title or mode.name or mode.id or ""
  end
  return tostring(mode or "")
end

---Return whether only the zoom modifier is pressed.
local function zoom_modifier_pressed()
  local ctrl_key = PLATFORM == "Mac OS X" and "cmd" or "ctrl"
  if not keymap.modkeys[ctrl_key] then return false end
  for key, status in pairs(keymap.modkeys) do
    if key ~= ctrl_key and status then return false end
  end
  return true
end

local ACTIVE_STATUSES = {
  loading = true,
  starting = true,
  running = true,
  working = true,
  reasoning = true,
  searching = true,
  responding = true,
  ["waiting for input"] = true,
  ["waiting for approval"] = true,
  ["waiting for tool approval"] = true,
  ["calling tool"] = true,
  compacting = true,
  ["running command"] = true,
  ["editing files"] = true
}

local STATUS_LABELS = {
  loading = "Loading",
  starting = "Starting",
  running = "Working",
  working = "Working",
  reasoning = "Reasoning",
  searching = "Searching",
  responding = "Responding",
  ["waiting for input"] = "Waiting for input",
  ["waiting for approval"] = "Waiting for approval",
  ["waiting for tool approval"] = "Waiting for tool approval",
  ["calling tool"] = "Calling tool",
  compacting = "Compacting",
  ["tool denied"] = "Tool denied",
  ready = "Ready",
  idle = "Idle",
  cancelled = "Cancelled",
  error = "Error",
  ["running command"] = "Running command",
  ["editing files"] = "Editing files"
}

---Handle animated status label.
local function animated_status_label(status)
  status = status or "idle"
  local label = STATUS_LABELS[status] or tostring(status):gsub("^%l", string.upper)
  local active = ACTIVE_STATUSES[status]
    or tostring(status):find("^running command:", 1, false) ~= nil
  if active then
    local dots = (math.floor(system.get_time() * 2) % 4)
    return label .. string.rep(".", dots), true
  end
  return label, false
end

---Handle make agent.
local function make_agent(name)
  local cls = DEFAULT_AGENT_CLASSES[name or "ollama"] or Ollama
  local agent = cls()
  local conf = config.plugins.assistant or {}
  return tools.register_agent_tools(agent:configure(conf))
end

---Handle make backend.
local function make_backend(name)
  if name == "appserver" then return AppServerBackend() end
  if name == "cli" then return CliBackend() end
  if name == "acp" then return AcpBackend() end
  return HttpBackend()
end

---Return the model label with reasoning effort when it should be visible.
---@param agent assistant.Agent
---@return string label
local function model_reasoning_label(agent)
  local model = tostring(agent and agent.model or "")
  local effort = agent and agent.configured_reasoning_effort and agent:configured_reasoning_effort()
  if model ~= "" and effort and effort ~= "none" then
    return string.format("%s (%s)", model, effort)
  end
  return model
end

---Create a new instance.
---@param options table
function PromptView:new(options)
  PromptView.super.new(self, nil, false)
  self.type_name = "plugins.assistant.promptview"
  self.defer_draw = false
  self.border.width = 0
  self.agent = options and options.agent or make_agent(options and options.agent_name)
  self.backend = options and options.backend or make_backend(self.agent.backend)
  self.conversation = options and options.conversation or Conversation(self.agent)
  if self.conversation.reasoning_effort ~= nil then
    self.agent.reasoning_effort = self.conversation.reasoning_effort
  end
  self.name = self.conversation.title or "Assistant"
  self.pending_assistant = nil
  self.pending_user_input_request = nil
  self.pending_approval_request = nil
  self.pending_tool_call_request = nil
  self.submit_generation = 0
  self.prompt_queue = {}
  self.active_prompt_turn = false
  self.focused_child = nil
  self.transcript_mode = "rendered"
  self.scroll_transcript_to_bottom_once = true
  self.transcript_markdown_text = self.conversation:to_markdown()
  self.transcript_snapshot = self:make_transcript_snapshot()

  self.title = Label(self, self:get_name())
  self.status = Label(self, "")
  self.mode_select = SelectBox(self, "Mode")
  self.activity = Label(self, "")
  self.insert_file_button = Button(self)
  configure_icon_button(self.insert_file_button, "D")
  self.insert_project_file_button = Button(self)
  configure_icon_button(self.insert_project_file_button, "L")
  self.send_button = Button(self)
  configure_icon_button(self.send_button, ">")
  self.model_button = Button(self)
  configure_icon_button(self.model_button, "K")
  self.cancel_button = Button(self)
  configure_icon_button(self.cancel_button, "!")
  self.compact_button = Button(self)
  configure_icon_button(self.compact_button, "N")
  self.clear_button = Button(self)
  configure_icon_button(self.clear_button, "C")
  self.line = Line(self, 2, style.padding.x)

  self.transcript = MarkdownView({
    text = self.transcript_markdown_text,
    title = self:get_name()
  })
  self.raw_transcript_doc = Doc("Assistant Conversation.md", nil, true)
  set_doc_text(self.raw_transcript_doc, self.transcript_markdown_text)
  self.raw_transcript = DocView(self.raw_transcript_doc)

  self.prompt_doc = Doc("Assistant Prompt.md", nil, true)
  self.prompt = DocView(self.prompt_doc)
  self.prompt.assistant_prompt_view = self
  self.transcript.assistant_prompt_view = self
  self.raw_transcript.assistant_prompt_view = self
  local prompt_view = self
  local function get_prompt_view_name()
    return prompt_view:get_name()
  end
  self.prompt.get_name = get_prompt_view_name
  self.transcript.get_name = get_prompt_view_name
  self.raw_transcript.get_name = get_prompt_view_name
  self:sync_child_view_titles()

  self:reset_collaboration_modes(self.agent:get_collaboration_modes())
  if not self.conversation.collaboration_mode then
    self.conversation.collaboration_mode = self.mode_select:get_selected_data()
  end
  local this = self
  ---Handle on change.
  function self.mode_select:on_change()
    this:set_collaboration_mode(this.mode_select:get_selected_data())
  end

  local buttons = {
    {
      widget = self.insert_file_button,
      tooltip = "Insert file or directory",
      command = "assistant-conversation:insert-file"
    },
    {
      widget = self.insert_project_file_button,
      tooltip = "Insert project file",
      command = "assistant-conversation:insert-project-file"
    },
    {
      widget = self.send_button,
      tooltip = "Send prompt",
      command = "assistant-conversation:send"
    },
    {
      widget = self.model_button,
      tooltip = "Select model",
      command = "assistant-conversation:select-model"
    },
    {
      widget = self.cancel_button,
      tooltip = "Cancel active request",
      command = "assistant-conversation:cancel"
    },
    {
      widget = self.compact_button,
      tooltip = "Compact conversation",
      command = "assistant-conversation:compact"
    },
    {
      widget = self.clear_button,
      tooltip = "Clear prompt",
      command = "assistant-conversation:clear-prompt"
    }
  }
  for _, item in ipairs(buttons) do
    item.widget:set_tooltip(item.tooltip, item.command)
    item.widget.on_click = function(_, pressed)
      if pressed == "left" then
        command.perform(item.command)
      end
    end
  end

  self:set_size(600, 500)
  self:show()
  self:prepare_backend()
  self:refresh_collaboration_modes()
end

---Return the name.
---@return string
function PromptView:get_name()
  return self.conversation and self.conversation.title or "Assistant"
end

---Sync the conversation title reported by embedded child views.
function PromptView:sync_child_view_titles()
  local title = self:get_name()
  self.name = title
  if self.title then
    self.title:set_label(title)
  end
  if self.transcript then
    self.transcript.title = title
  end
end

---Return the state.
---@return table
function PromptView:get_state()
  if not self.conversation then return nil end
  self.conversation:save()
  return {
    id = self.conversation.id,
    project_dir = self.conversation.project_dir
  }
end

---Handle from state.
---@param state table
---@return assistant.PromptView|nil
function PromptView.from_state(state)
  if not (state and state.id and state.project_dir) then return nil end
  local conversation = Conversation.load(state.id, state.project_dir)
  if not conversation then return nil end
  local agent = make_agent(conversation.agent)
  agent.model = conversation.model or agent.model
  agent.reasoning_effort = conversation.reasoning_effort
  conversation.backend = agent.backend
  return PromptView({
    conversation = conversation,
    agent = agent,
    backend = make_backend(agent.backend)
  })
end

---Handle try close.
function PromptView:try_close(do_close)
  if self.backend and self.backend.close then
    self.backend:close()
  elseif self.backend and self.backend.cancel then
    self.backend:cancel()
  end
  PromptView.super.try_close(self, do_close)
end

---Return the display status.
function PromptView:get_display_status()
  local status = self.conversation.status or "idle"
  if status == "idle" and self.agent.loading and self.agent:loading() then
    status = "loading"
  elseif status == "idle" and self.backend and self.backend.ready and self.backend:ready() then
    status = "ready"
  end
  return status
end

---Return the transcript view.
function PromptView:get_transcript_view()
  return self.transcript_mode == "raw" and self.raw_transcript or self.transcript
end

---Handle reset collaboration modes.
function PromptView:reset_collaboration_modes(modes)
  modes = modes or {}
  self.agent.collaboration_modes_by_id = {}
  local old_on_change = self.mode_select.on_change
  self.mode_select.on_change = function() end
  self.mode_select.list:clear()
  self.mode_select:set_label("Mode")
  for _, mode in ipairs(modes) do
    local id = mode_id(mode)
    if id and id ~= "" then
      self.agent.collaboration_modes_by_id[id] = mode
      self.mode_select:add_option(mode_label(mode), id)
    end
  end
  local selected = 1
  for idx = 2, #self.mode_select.list.rows do
    if mode_matches(self.mode_select.list:get_row_data(idx), self.conversation.collaboration_mode) then
      selected = idx - 1
      break
    end
  end
  if #self.mode_select.list.rows > 1 then
    self.mode_select:set_selected(selected)
  else
    self.mode_select:set_selected(0)
  end
  self.mode_select.on_change = old_on_change
end

---Set the collaboration mode.
function PromptView:set_collaboration_mode(mode)
  if not mode or mode == "" then return end
  self.conversation.collaboration_mode = mode
  local old_on_change = self.mode_select.on_change
  self.mode_select.on_change = function() end
  for idx = 2, #self.mode_select.list.rows do
    if mode_matches(self.mode_select.list:get_row_data(idx), mode) then
      self.mode_select:set_selected(idx - 1)
      break
    end
  end
  self.mode_select.on_change = old_on_change
  self.conversation:touch()
  self.conversation:save()
  self:refresh()
end

---Handle cycle collaboration mode.
function PromptView:cycle_collaboration_mode()
  if not self.mode_select:is_visible() then return false end
  local count = math.max(0, #self.mode_select.list.rows - 1)
  if count <= 1 then return false end
  local selected = self.mode_select:get_selected()
  local next_selected = selected + 1
  if next_selected > count then next_selected = 1 end
  self.mode_select:set_selected(next_selected)
  return true
end

---Handle refresh collaboration modes.
function PromptView:refresh_collaboration_modes()
  if not self.agent:has_capability("collaboration_modes") then return end
  if not (self.backend and self.backend.list_collaboration_modes) then return end
  self.backend:list_collaboration_modes(self.agent, function(ok, err, modes)
    if not ok then
      core.warn("Assistant: could not list collaboration modes: %s", err or "unknown error")
      return
    end
    self:reset_collaboration_modes(modes)
    self:refresh()
  end)
end

---Handle sync raw transcript.
function PromptView:sync_raw_transcript()
  local markdown = self:get_conversation_markdown()
  local previous = get_text(self.raw_transcript_doc)
  if previous ~= ""
    and markdown:sub(1, #previous) == previous
    and markdown ~= previous
  then
    self.raw_transcript_doc:insert(
      #self.raw_transcript_doc.lines,
      #self.raw_transcript_doc.lines[#self.raw_transcript_doc.lines],
      markdown:sub(#previous + 1)
    )
    self.raw_transcript_doc:clean()
    return
  end
  set_doc_text(self.raw_transcript_doc, markdown)
end

---Handle view raw markdown.
function PromptView:view_raw_markdown()
  local follow_bottom = view_is_at_bottom(self.transcript)
  self:sync_raw_transcript()
  self.transcript_mode = "raw"
  self.focused_child = self.raw_transcript
  if follow_bottom then
    scroll_view_to_bottom(self.raw_transcript)
  end
  core.set_active_view(self.raw_transcript)
  core.redraw = true
end

---Handle view rendered markdown.
function PromptView:view_rendered_markdown()
  self.transcript:set_text(get_text(self.raw_transcript_doc))
  self.transcript_markdown_text = self.transcript.text or get_text(self.raw_transcript_doc)
  self.transcript_mode = "rendered"
  self.focused_child = self.transcript
  core.set_active_view(self.transcript)
  core.redraw = true
end

---Update transcript.
function PromptView:update_transcript(markdown)
  markdown = markdown or ""
  local previous = self.transcript_markdown_text or ""
  if markdown == previous then return end

  local appended = false
  local force_set = self.force_transcript_set
  self.force_transcript_set = nil
  if not force_set
    and self.transcript_mode == "rendered"
    and self.transcript.append_text
    and previous ~= ""
    and markdown:sub(1, #previous) == previous
  then
    self.transcript:append_text(markdown:sub(#previous + 1))
    appended = true
  end

  if not appended and self.transcript_mode == "rendered" then
    self.transcript:set_text(markdown)
  end
  self.transcript_markdown_text = markdown
  if self.pending_transcript_snapshot then
    self.transcript_snapshot = self.pending_transcript_snapshot
    self.pending_transcript_snapshot = nil
  end
end

---Update the rendered transcript while an assistant response is streaming.
---@return boolean handled
function PromptView:update_streaming_transcript()
  if self.transcript_mode ~= "rendered"
    or not (self.transcript and self.transcript.set_partial_text)
    or not self.pending_assistant
  then
    return false
  end

  local now = system.get_time()
  self.pending_streaming_transcript_text = self.pending_assistant.message or ""
  local force_sentence_flush = self.pending_streaming_transcript_text:find("[%.%!%?]%s*$") ~= nil
  if self.last_streaming_transcript_refresh
    and now - self.last_streaming_transcript_refresh < STREAMING_TRANSCRIPT_REFRESH_INTERVAL
    and not force_sentence_flush
  then
    return true
  end

  self:flush_streaming_transcript()
  return true
end

---Append the assistant heading before temporary streamed text.
---@return boolean appended
function PromptView:ensure_streaming_assistant_heading()
  if self.streaming_assistant_heading_committed
    or not self.pending_assistant
    or self.transcript_mode ~= "rendered"
    or not (self.transcript and self.transcript.append_text)
  then
    return false
  end

  local previous = self.transcript_markdown_text or ""
  local heading = "## Assistant\n\n"
  local markdown = (previous ~= "" and "\n\n" or "") .. heading
  self.streaming_assistant_base_markdown = previous
  self.transcript:append_text(markdown)
  self.transcript_markdown_text = previous .. markdown
  -- The rendered view now contains a temporary assistant heading, but the
  -- streamed body is held by MarkdownView as partial text rather than in
  -- transcript_markdown_text. Do not cache a normal conversation snapshot here:
  -- it would claim the cached markdown already contains the pending assistant
  -- body and later incremental refreshes could append only a tail fragment.
  self.transcript_snapshot = nil
  self.force_transcript_set = true
  self.pending_transcript_snapshot = nil
  self.streaming_assistant_heading_committed = true
  return true
end

---Flushes buffered streamed assistant text to the rendered transcript.
function PromptView:flush_streaming_transcript()
  if self.transcript_mode ~= "rendered"
    or not (self.transcript and self.transcript.set_partial_text)
    or not self.pending_streaming_transcript_text
  then
    return
  end

  if self.streaming_transcript_follow_bottom == nil then
    self.streaming_transcript_follow_bottom = view_is_at_bottom(self.transcript)
  end

  self:ensure_streaming_assistant_heading()
  self.transcript:set_partial_text(self.pending_streaming_transcript_text)
  self.pending_streaming_transcript_text = nil
  self.last_streaming_transcript_refresh = system.get_time()
  if self.streaming_transcript_follow_bottom then
    scroll_view_to_bottom(self.transcript)
  end
end

---Commit a completed assistant response to the rendered transcript.
---@param assistant_message table
function PromptView:commit_streaming_transcript(assistant_message)
  if self.transcript_mode ~= "rendered"
    or not (self.transcript and self.transcript.commit_partial_text)
  then
    return
  end

  local markdown = self.conversation and self.conversation:message_to_markdown(assistant_message)
  if not markdown then
    return
  end

  local previous = self.transcript_markdown_text or ""
  local appended_markdown
  if self.streaming_assistant_heading_committed then
    previous = self.streaming_assistant_base_markdown or ""
    appended_markdown = (previous ~= "" and "\n\n" or "") .. markdown
  else
    appended_markdown = (previous ~= "" and "\n\n" or "") .. markdown
  end
  local final_markdown = previous .. appended_markdown
  local follow_bottom = view_is_at_bottom(self.transcript)
  if self.streaming_assistant_heading_committed then
    if self.transcript.clear_partial_text then
      self.transcript:clear_partial_text()
    end
    self.transcript:set_text(final_markdown)
  else
    self.transcript:commit_partial_text(appended_markdown)
  end
  self.transcript_markdown_text = final_markdown
  self.transcript_snapshot = self:make_transcript_snapshot()
  self.pending_transcript_snapshot = nil
  self.pending_streaming_transcript_text = nil
  self.streaming_transcript_follow_bottom = nil
  self.streaming_assistant_heading_committed = nil
  self.streaming_assistant_base_markdown = nil
  self.last_streaming_transcript_refresh = nil
  if follow_bottom then
    scroll_view_to_bottom(self.transcript)
  end
end

---Refresh toolbar, status, and mode controls without rebuilding transcript text.
function PromptView:refresh_controls()
  self:sync_child_view_titles()
  local status = self:get_display_status()
  local parts = {
    self.agent.display_name or self.agent.name,
    model_reasoning_label(self.agent)
  }
  if self.agent:has_capability("reports_usage") then
    if self.agent:has_capability("reports_context") then
      local left = self.conversation:context_left()
      if left then table.insert(parts, string.format("%d context left", left)) end
    else
      local used = self.conversation:context_used()
      if used then table.insert(parts, string.format("%d context used", used)) end
    end
  end
  local queued = #(self.prompt_queue or {})
  if queued > 0 then
    table.insert(parts, string.format("%d queued", queued))
  end
  self.status:set_label(table.concat(parts, " / "))
  local activity, active = animated_status_label(status)
  self.activity:set_label(activity)
  if self.agent:has_capability("compact") or self.agent:has_capability("local_compact") then
    self.compact_button:show()
  else
    self.compact_button:hide()
  end
  if self.agent:has_capability("collaboration_modes") then
    self.mode_select:show()
  else
    self.mode_select:hide()
  end
  core.redraw = true
  self.activity_active = active
end

---Handle make transcript snapshot.
function PromptView:make_transcript_snapshot()
  local messages = self.conversation and self.conversation.messages or {}
  local last = messages[#messages]
  local visible_count = 0
  for _, msg in ipairs(messages) do
    if msg.role ~= "system" and not (msg.meta and msg.meta.provider_only) then
      visible_count = visible_count + 1
    end
  end
  return {
    title = self.conversation and self.conversation.title,
    count = #messages,
    visible_count = visible_count,
    last = last,
    last_role = last and last.role,
    last_message = last and last.message or nil,
    last_markdown = self.conversation and self.conversation:message_to_markdown(last) or nil
  }
end

---Return the conversation markdown.
function PromptView:get_conversation_markdown()
  local conversation = self.conversation
  if not conversation then return "" end
  local cached = self.transcript_markdown_text
  local snapshot = self.transcript_snapshot
  local messages = conversation.messages or {}
  if cached and snapshot and snapshot.title == conversation.title then
    if snapshot.visible_count > 0 and #messages == snapshot.count + 1 then
      local markdown = conversation:message_to_markdown(messages[#messages])
      if markdown then
        self.pending_transcript_snapshot = self:make_transcript_snapshot()
        return cached .. "\n\n" .. markdown
      end
    elseif #messages == snapshot.count then
      local last = messages[#messages]
      if last
        and last == snapshot.last
        and last.role == snapshot.last_role
        and type(last.message) == "string"
        and type(snapshot.last_message) == "string"
        and last.message:sub(1, #snapshot.last_message) == snapshot.last_message
      then
        local current_markdown = conversation:message_to_markdown(last)
        if last.role == "assistant"
          and type(current_markdown) == "string"
          and type(snapshot.last_markdown) == "string"
          and current_markdown:sub(1, #snapshot.last_markdown) == snapshot.last_markdown
        then
          local delta = current_markdown:sub(#snapshot.last_markdown + 1)
          if delta ~= "" then
            self.pending_transcript_snapshot = self:make_transcript_snapshot()
            return cached .. delta
          end
          return cached
        elseif last.message ~= snapshot.last_message then
          self.force_transcript_set = true
          self.pending_transcript_snapshot = self:make_transcript_snapshot()
          return conversation:to_markdown()
        end
        return cached
      end
    end
  end
  self.force_transcript_set = true
  local markdown = conversation:to_markdown()
  self.pending_transcript_snapshot = self:make_transcript_snapshot()
  return markdown
end

---Handle refresh.
function PromptView:refresh()
  self:sync_child_view_titles()
  local transcript_view = self:get_transcript_view()
  local follow_bottom = view_is_at_bottom(transcript_view)
  self:update_transcript(self:get_conversation_markdown())
  if self.transcript_mode == "raw" then
    self:sync_raw_transcript()
  end
  if follow_bottom then
    scroll_view_to_bottom(transcript_view)
  end
  self:refresh_controls()
end

---Handle prepare backend.
function PromptView:prepare_backend()
  if not (self.backend and self.backend.prepare) then return end
  self.backend:prepare(self.agent, self.conversation, function(ok, err)
    if not ok and err and err ~= "codex app-server is busy" then
      core.warn("Assistant: could not prepare %s backend: %s",
        self.agent.display_name or self.agent.name,
        err
      )
    end
    self:refresh()
  end)
  self:refresh()
end

---Return whether active prompt turn is available.
function PromptView:has_active_prompt_turn()
  return self.active_prompt_turn == true
    or (self.agent and self.agent.loading and self.agent:loading())
    or self.pending_user_input_request ~= nil
    or self.pending_approval_request ~= nil
    or self.pending_tool_call_request ~= nil
end

---Handle queue prompt.
function PromptView:queue_prompt(text)
  text = tostring(text or "")
  if text == "" then return false end
  table.insert(self.prompt_queue, text)
  self:refresh()
  return true
end

---Handle drain prompt queue.
function PromptView:drain_prompt_queue()
  if self:has_active_prompt_turn() then return false end
  local text = table.remove(self.prompt_queue, 1)
  if not text then
    self:refresh()
    return false
  end
  self:dispatch_prompt_turn(text)
  return true
end

---Submit the current selection or prompt.
function PromptView:submit()
  local text = get_text(self.prompt_doc)
  if text == "" then return end
  set_doc_text(self.prompt_doc, "")
  if self:has_active_prompt_turn() then
    self:queue_prompt(text)
    return
  end
  self:dispatch_prompt_turn(text)
end

---Handle dispatch prompt turn.
---@param text string
function PromptView:dispatch_prompt_turn(text)
  text = tostring(text or "")
  if text == "" then return end
  self.submit_generation = (self.submit_generation or 0) + 1
  local generation = self.submit_generation
  self.active_prompt_turn = true
  local first_user_prompt = true
  for _, message in ipairs(self.conversation.messages or {}) do
    if message.role == "user" and not (message.meta and message.meta.provider_only) then
      first_user_prompt = false
      break
    end
  end
  self.conversation:add("user", text)
  self:refresh()
  local title_prompt_after_first_response = first_user_prompt and text or nil

  ---Handle should auto compact.
  local function should_auto_compact()
    local conf = config.plugins.assistant or {}
    if conf.auto_compact == false then return false end
    if not (self.agent
      and self.agent:has_capability("local_compact")
      and self.backend
      and self.backend.local_compact)
    then
      return false
    end
    local usage = self.conversation and self.conversation.usage or nil
    local total = tonumber(usage and usage.total_tokens)
    local context = tonumber(usage and (usage.context or usage.model_context_window))
      or tonumber(self.conversation and self.conversation.options and self.conversation.options.context)
      or tonumber(self.agent and self.agent.model_metadata and self.agent.model_metadata.context_window)
    if not (total and context and context > 0) then return false end
    local threshold = tonumber(conf.auto_compact_threshold) or 0.85
    if total / context < threshold then return false end
    local min_new = tonumber(conf.auto_compact_min_new_messages) or 4
    local compacted_at = tonumber(self.conversation.local_compaction and self.conversation.local_compaction.message_count) or 0
    return #self.conversation.messages - compacted_at >= min_new
  end

  ---Handle ensure pending assistant.
  local function ensure_pending_assistant()
    if not self.pending_assistant then
      self.pending_assistant = self.conversation:add("assistant", "", { autosave = false })
    end
    return self.pending_assistant
  end
  ---Merge a partial assistant response that may be either accumulated text or a delta.
  ---@param current string
  ---@param incoming string
  ---@return string
  local function merge_partial_response(current, incoming)
    current = tostring(current or "")
    incoming = tostring(incoming or "")
    if current == "" or incoming == "" then
      return incoming ~= "" and incoming or current
    end
    if incoming:sub(1, #current) == current then
      return incoming
    end
    if current:sub(-#incoming) == incoming then
      return current
    end
    return current .. incoming
  end
  ---Handle finalize pending assistant.
  local function finalize_pending_assistant(force)
    if self.pending_assistant and (force or self.pending_assistant.message == "") then
      self.conversation:remove(self.pending_assistant)
    end
    self.pending_assistant = nil
    self.pending_streaming_transcript_text = nil
    self.streaming_transcript_follow_bottom = nil
    self.streaming_assistant_heading_committed = nil
    self.streaming_assistant_base_markdown = nil
    self.last_streaming_transcript_refresh = nil
    if self.transcript and self.transcript.clear_partial_text then
      self.transcript:clear_partial_text()
    end
  end
  ---Handle response.
  local function handle_response(ok, err, response, meta)
    if generation ~= self.submit_generation then return end
    if ok and meta and meta.event == "user_input_request" and meta.request then
      finalize_pending_assistant()
      self:handle_user_input_request(meta.request)
      self:refresh()
      return
    end
    if ok and meta and meta.event == "approval_request" and meta.request then
      finalize_pending_assistant()
      self:handle_approval_request(meta.request)
      self:refresh()
      return
    end
    if ok and meta and meta.event == "tool_call_request" and meta.request then
      finalize_pending_assistant()
      self:handle_tool_call_request(meta.request)
      self:refresh()
      return
    end
    if ok and meta and meta.event == "finalize_pending_assistant" then
      finalize_pending_assistant()
      self:refresh()
      return
    end
    if ok and meta and meta.event == "discard_pending_assistant" then
      finalize_pending_assistant(true)
      self:refresh()
      return
    end
    if ok and meta and meta.event == "request_resolved" then
      local request_id = meta.request_id and tostring(meta.request_id) or nil
      if self.pending_user_input_request
        and (not request_id or tostring(self.pending_user_input_request.id) == request_id)
      then
        self.pending_user_input_request = nil
      end
      if self.pending_approval_request
        and (not request_id or tostring(self.pending_approval_request.id) == request_id)
      then
        self.pending_approval_request = nil
      end
      if self.pending_tool_call_request
        and (not request_id or tostring(self.pending_tool_call_request.id) == request_id)
      then
        self.pending_tool_call_request = nil
      end
      self:refresh()
      return
    end
    if ok and meta and meta.event == "config_update" then
      self:reset_collaboration_modes(self.agent:get_collaboration_modes())
      self:refresh()
      return
    end
    if ok and meta and meta.event == "activity_update" then
      if meta.force_transcript then
        self:refresh()
      elseif self.pending_assistant or self.pending_streaming_transcript_text then
        self:refresh_controls()
      else
        self:refresh()
      end
      return
    end
    if ok then
      if meta and meta.done and (response == nil or response == "") and not self.pending_assistant then
        self.conversation:save()
        self.active_prompt_turn = false
        if title_prompt_after_first_response then
          self:generate_conversation_title_from_first_prompt(title_prompt_after_first_response, true)
          title_prompt_after_first_response = nil
        end
        self:refresh()
        self:drain_prompt_queue()
        return
      end
      ensure_pending_assistant()
      if meta and meta.partial and not meta.done then
        self.pending_assistant.message = merge_partial_response(self.pending_assistant.message, response)
      else
        self.pending_assistant.message = response or ""
      end
      if meta and meta.usage then
        self.conversation:set_usage(meta.usage)
      end
      self.conversation:touch()
      if meta and meta.done then
        self:commit_streaming_transcript(self.pending_assistant)
        self.pending_assistant = nil
        self.conversation:save()
        self.active_prompt_turn = false
        if title_prompt_after_first_response then
          self:generate_conversation_title_from_first_prompt(title_prompt_after_first_response, true)
          title_prompt_after_first_response = nil
        end
      elseif self:update_streaming_transcript() then
        return
      end
    else
      if err == "request cancelled" then
        if self.pending_assistant and self.pending_assistant.message == "" then
          self.conversation:remove(self.pending_assistant)
        end
        self.pending_assistant = nil
        self.pending_streaming_transcript_text = nil
        self.streaming_transcript_follow_bottom = nil
        self.streaming_assistant_heading_committed = nil
        self.streaming_assistant_base_markdown = nil
        self.last_streaming_transcript_refresh = nil
        if self.transcript and self.transcript.clear_partial_text then
          self.transcript:clear_partial_text()
        end
        self.active_prompt_turn = false
        self:refresh()
        return
      end
      if self.pending_assistant and self.pending_assistant.message == "" then
        self.conversation:remove(self.pending_assistant)
      end
      self.conversation:add("error", err or "request failed")
      self.pending_assistant = nil
      self.pending_streaming_transcript_text = nil
      self.streaming_transcript_follow_bottom = nil
      self.streaming_assistant_heading_committed = nil
      self.streaming_assistant_base_markdown = nil
      self.last_streaming_transcript_refresh = nil
      if self.transcript and self.transcript.clear_partial_text then
        self.transcript:clear_partial_text()
      end
      self.active_prompt_turn = false
    end
    self:refresh()
    if (not ok) or (meta and meta.done) then
      self:drain_prompt_queue()
    end
  end
  ---Handle send after optional compaction.
  local function send_after_optional_compaction()
    if generation ~= self.submit_generation then return end
    self.backend:send(self.agent, self.conversation, handle_response)
  end
  if should_auto_compact() then
    self.conversation._assistant_compaction_trigger = "auto"
    self.backend:local_compact(self.agent, self.conversation, function(ok, err)
      if generation ~= self.submit_generation then return end
      self.conversation._assistant_compaction_trigger = nil
      if not ok then
        core.error("Assistant: automatic compaction failed: %s", err or "unknown error")
      end
      self:refresh()
      send_after_optional_compaction()
    end)
    self:refresh()
    return
  end
  send_after_optional_compaction()
end

---Handle generate conversation title from first prompt.
function PromptView:generate_conversation_title_from_first_prompt(prompt, first_user_prompt)
  local conf = config.plugins.assistant or {}
  if conf.generate_conversation_titles == false then return end
  if not first_user_prompt then return end
  if not (self.backend and self.backend.generate_conversation_title) then return end
  if not (self.conversation and self.conversation.title == "Assistant Session") then return end

  local conversation = self.conversation
  self.backend:generate_conversation_title(self.agent, conversation, prompt, function(ok, err, title)
    if self.conversation ~= conversation then return end
    if not ok then
      if conf.debug then
        core.error("Assistant: could not generate conversation title: %s", err or "unknown error")
      end
      return
    end
    if conversation.title == "Assistant Session" then
      self:rename_conversation(title)
    end
  end)
end

---Handle suggestion matches text.
local function suggestion_matches_text(suggestions, text)
  text = tostring(text or "")
  for _, suggestion in ipairs(suggestions or {}) do
    if suggestion.text == text then return suggestion end
  end
end

---Handle user input question markdown.
local function user_input_question_markdown(question)
  local parts = { "### Question" }
  local header = question and question.header or nil
  local text = question and question.question or nil
  if header and header ~= "" then
    table.insert(parts, "")
    table.insert(parts, "**" .. tostring(header) .. "**")
  end
  if text and text ~= "" then
    table.insert(parts, "")
    table.insert(parts, tostring(text))
  elseif not (header and header ~= "") then
    table.insert(parts, "")
    table.insert(parts, "Assistant question")
  end
  return table.concat(parts, "\n")
end

---Normalize normalized user input options.
local function normalized_user_input_options(options)
  local result = {}
  if type(options) ~= "table" then return result end
  for _, option in ipairs(options) do
    if type(option) == "table" then
      table.insert(result, {
        label = tostring(option.label or option.value or ""),
        value = tostring(option.value or option.label or ""),
        description = option.description
      })
    else
      table.insert(result, {
        label = tostring(option),
        value = tostring(option)
      })
    end
  end
  return result
end

---Handle user input request.
---@param request table
function PromptView:handle_user_input_request(request)
  if not (self.backend and self.backend.resolve_user_input) then
    core.warn("Assistant: current backend cannot resolve assistant input requests")
    return
  end
  self.pending_user_input_request = request
  local questions = request.questions or {}
  local answers = {}

  ---Handle finish.
  local function finish(ok)
    local active_request = self.pending_user_input_request
    self.pending_user_input_request = nil
    if not active_request then
      self:refresh()
      return
    end
    self.backend:resolve_user_input(
      self.agent,
      self.conversation,
      active_request,
      ok,
      ok and answers or {},
      function(success, err)
        if not success then
          core.error("Assistant: could not answer assistant input request: %s", err or "unknown error")
        end
        self:refresh()
      end
    )
    self:refresh()
  end

  ---Handle ask.
  local function ask(index)
    local question = questions[index]
    if not question then
      finish(true)
      return
    end
    request.displayed_question_indexes = request.displayed_question_indexes or {}
    if not request.displayed_question_indexes[index] then
      request.displayed_question_indexes[index] = true
      self.conversation:add("assistant", user_input_question_markdown(question), {
        meta = { user_input_prompt = true },
        autosave = false
      })
      self:refresh()
    end
    local suggestions = {}
    for _, option in ipairs(normalized_user_input_options(question.options)) do
      table.insert(suggestions, {
        text = option.label or option.value or "",
        option = option,
        info = option.description
      })
    end
    core.command_view:enter("Answer", {
      show_suggestions = #suggestions > 0,
      typeahead = #suggestions > 0,
      suggest = function()
        return suggestions
      end,
      validate = function(text, suggestion)
        if suggestion then return true end
        if question.allow_other or #suggestions == 0 then
          return tostring(text or "") ~= ""
        end
        return suggestion_matches_text(suggestions, text) ~= nil
      end,
      submit = function(text, suggestion)
        suggestion = suggestion or suggestion_matches_text(suggestions, text)
        if suggestion and suggestion.option then
          answers[question.id] = suggestion.option.value or suggestion.option.label or suggestion.text
        else
          answers[question.id] = tostring(text or "")
        end
        ask(index + 1)
    end,
    cancel = function(explicit)
      if explicit then
        core.warn("Assistant: input request is still pending; run assistant-conversation:respond-to-request to answer it.")
        self:refresh()
      end
    end
  })
  end

  ask(1)
end

---Handle approval request.
---@param request table
function PromptView:handle_approval_request(request)
  if not (self.backend and self.backend.resolve_approval) then
    core.warn("Assistant: current backend cannot resolve approval requests")
    return
  end
  self.pending_approval_request = request
  local request_id = request.id and tostring(request.id) or nil
  MessageBox.warning(
    request.title or "Assistant Approval",
    request.body or "Approve this assistant action?",
    function(_, button_id)
      if self.pending_approval_request
        and (not request_id or tostring(self.pending_approval_request.id) == request_id)
      then
        self.pending_approval_request = nil
      end
      local decision = button_id == 1 and "accept" or "decline"
      self.backend:resolve_approval(
        self.agent,
        self.conversation,
        request,
        decision,
        function(ok, err)
          if not ok then
            core.error("Assistant: could not answer approval request: %s", err or "unknown error")
          end
          self:refresh()
        end
      )
      self:refresh()
    end,
    MessageBox.BUTTONS_YES_NO
  )
end

---Handle tool call request.
---@param request table
function PromptView:handle_tool_call_request(request)
  if not (self.backend and self.backend.resolve_tool_call) then
    core.warn("Assistant: current backend cannot resolve tool calls")
    return
  end
  self.pending_tool_call_request = request
  local suggestions = {}
  if type(request.options) == "table" then
    for _, option in ipairs(request.options) do
      if type(option) == "table" then
        table.insert(suggestions, {
          text = option.label or option.text or option.decision,
          decision = option.decision or option.value,
          info = option.description or option.info
        })
      end
    end
  end
  if #suggestions == 0 then
    suggestions = {
      { text = "Allow", decision = "allow", info = "Execute the requested tool." },
      { text = "Deny", decision = "deny", info = "Return a denial result to the assistant." }
    }
  end
  core.command_view:enter("Approve tool", {
    show_suggestions = true,
    typeahead = true,
    suggest = function()
      return suggestions
    end,
    validate = function(text, suggestion)
      return suggestion ~= nil or suggestion_matches_text(suggestions, text) ~= nil
    end,
    submit = function(text, suggestion)
      suggestion = suggestion or suggestion_matches_text(suggestions, text)
      local active_request = self.pending_tool_call_request
      self.pending_tool_call_request = nil
      if not active_request then
        self:refresh()
        return
      end
      self.backend:resolve_tool_call(
        self.agent,
        self.conversation,
        active_request,
        suggestion and suggestion.decision or "deny",
        function(ok, err)
          if not ok then
            core.error("Assistant: could not answer tool call request: %s", err or "unknown error")
          end
          self:refresh()
        end
      )
      self:refresh()
    end,
    cancel = function(explicit)
      if not explicit then return end
      self.pending_tool_call_request = self.pending_tool_call_request or request
      core.warn("Assistant: tool request is still pending; run assistant-conversation:respond-to-request to answer it.")
      self:refresh()
    end
  })
end

---Handle respond to pending request.
function PromptView:respond_to_pending_request()
  if self.pending_tool_call_request then
    self:handle_tool_call_request(self.pending_tool_call_request)
    return true
  end
  if self.pending_user_input_request then
    self:handle_user_input_request(self.pending_user_input_request)
    return true
  end
  if self.pending_approval_request then
    self:handle_approval_request(self.pending_approval_request)
    return true
  end
  core.warn("Assistant: no pending request to answer")
  return false
end

---Cancel the active operation.
function PromptView:cancel()
  if self.backend then self.backend:cancel() end
  self.submit_generation = (self.submit_generation or 0) + 1
  self.conversation:set_status("cancelled")
  self.pending_assistant = nil
  self.active_prompt_turn = false
  self.prompt_queue = {}
  self.pending_user_input_request = nil
  self.pending_approval_request = nil
  self.pending_tool_call_request = nil
  self.pending_streaming_transcript_text = nil
  self.streaming_transcript_follow_bottom = nil
  self.streaming_assistant_heading_committed = nil
  self.streaming_assistant_base_markdown = nil
  self.last_streaming_transcript_refresh = nil
  if self.transcript and self.transcript.clear_partial_text then
    self.transcript:clear_partial_text()
  end
  self:refresh()
end

---Handle save conversation.
function PromptView:save_conversation()
  if self.conversation:save() then
    core.log("Assistant: saved conversation %s", self.conversation.id)
  end
end

---Handle view raw responses.
function PromptView:view_raw_responses()
  local text = self.conversation:raw_responses_text()
  if text == "" then
    text = "No raw responses have been recorded for this conversation.\n"
  end
  local filename = string.format(
    "%s Raw Responses.jsonl",
    self.conversation.title or "Assistant Session"
  )
  local doc = Doc(filename, Conversation.raw_responses_path(self.conversation.project_dir, self.conversation.id), true)
  set_doc_text(doc, text)
  doc:reset_syntax()
  core.root_view:open_doc(doc)
end

---Handle clear prompt.
function PromptView:clear_prompt()
  set_doc_text(self.prompt_doc, "")
end

---Handle rename conversation.
function PromptView:rename_conversation(title)
  title = tostring(title or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if title == "" then return end

  ---Handle apply local.
  local function apply_local()
    self.conversation.title = title
    self.name = title
    self.conversation:touch()
    self.conversation:save()
    self:refresh()
  end

  if self.agent:has_capability("rename_conversation")
    and self.backend
    and self.backend.rename_conversation
    and self.conversation.codex_thread_id
    and self.conversation.codex_thread_id ~= ""
  then
    self.backend:rename_conversation(self.agent, self.conversation, title, function(ok, err)
      if ok then
        apply_local()
      else
        core.error("Assistant: could not rename provider conversation: %s", err or "unknown error")
      end
    end)
    self:refresh()
    return
  end

  apply_local()
end

---Compact compact.
function PromptView:compact()
  local native_compact = self.agent
    and self.agent:has_capability("compact")
    and self.backend
    and self.backend.compact
  local local_compact = self.agent
    and self.agent:has_capability("local_compact")
    and self.backend
    and self.backend.local_compact
  if not (native_compact or local_compact) then
    core.warn("Assistant: current agent does not support conversation compaction")
    return
  end
  local compact = native_compact and self.backend.compact or self.backend.local_compact
  compact(self.backend, self.agent, self.conversation, function(ok, err)
    if ok then
      core.log("Assistant: compacted conversation %s", self.conversation.id)
    else
      core.error("Assistant: could not compact conversation: %s", err or "unknown error")
    end
    self:refresh()
  end)
  self:refresh()
end

---Handle active conversation view.
function PromptView.active_conversation_view()
  local view = core.active_view
  if view and view.assistant_prompt_view then
    view = view.assistant_prompt_view
  end
  if view and view.is and view:is(PromptView) then
    return view
  end
end

---Handle active predicate.
function PromptView.active_predicate()
  local view = PromptView.active_conversation_view()
  return view ~= nil, view
end

---Compact predicate.
function PromptView.compact_predicate()
  local view = PromptView.active_conversation_view()
  local native_compact = view
    and view.agent
    and view.agent:has_capability("compact")
    and view.backend
    and view.backend.compact
  local local_compact = view
    and view.agent
    and view.agent:has_capability("local_compact")
    and view.backend
    and view.backend.local_compact
  return view
    and (native_compact or local_compact)
    and not view.agent:loading(),
    view
end

---Open model dialog.
function PromptView:open_model_dialog()
  self.agent:set_loading(true)
  self:refresh()
  self.backend:list_models(self.agent, function(ok, err, models)
    self.agent:set_loading(false)
    self:refresh()
    if not ok then
      core.error("Assistant: could not list models: %s", err or "unknown error")
      return
    end
    if not models or #models == 0 then
      core.warn("Assistant: no models reported by %s", self.agent.display_name or self.agent.name)
      return
    end
    local dialog = ModelDialog(models, self.agent.model, self.agent:configured_reasoning_effort())
    self.model_dialog = dialog
    dialog.on_submit = function(_, model, reasoning_effort)
      self.agent.model = model
      self.agent.reasoning_effort = reasoning_effort
      self.conversation.model = model
      self.conversation.reasoning_effort = reasoning_effort
      self.conversation:touch()
      self.conversation:save()
      self:refresh()
    end
    dialog:show()
  end)
end

---Update update.
function PromptView:update()
  if not PromptView.super.update(self) then return end
  local pos = self:get_position()
  local size = self:get_size()
  local padding = style.padding.x
  local toolbar_y = style.padding.y
  local left = padding
  local right = size.x - padding
  self.title:set_label(self:get_name())
  self.mode_select:update_size_position()

  local button_gap = math.max(style.padding.x / 2, 6 * SCALE)
  local mode_select_h = self.mode_select:is_visible() and widget_height(self.mode_select) or 0
  if mode_select_h > 0 then
    self.model_button:set_size(nil, mode_select_h)
    self.cancel_button:set_size(nil, mode_select_h)
    self.compact_button:set_size(nil, mode_select_h)
  end
  local button_h = math.max(
    widget_height(self.model_button),
    widget_height(self.cancel_button),
    self.compact_button:is_visible() and widget_height(self.compact_button) or 0,
    mode_select_h
  )
  local title_h = widget_height(self.title)
  local toolbar_h = math.max(button_h, title_h)
  local title_y = toolbar_y + math.max(0, (toolbar_h - title_h) / 2)
  local button_y = toolbar_y + math.max(0, (toolbar_h - button_h) / 2)

  local x = right
  if self.compact_button:is_visible() then
    x = x - widget_width(self.compact_button)
    self.compact_button:set_position(x, button_y)
    x = x - button_gap
  end
  x = x - widget_width(self.cancel_button)
  self.cancel_button:set_position(x, button_y)
  x = x - button_gap - widget_width(self.model_button)
  self.model_button:set_position(x, button_y)

  self.title:set_position(left, title_y)
  local status_x = self.title:get_right() + padding
  self.status:set_position(status_x, title_y)
  if self.mode_select:is_visible() then
    local available = x - status_x - padding
    local mode_w = math.min(220 * SCALE, math.max(110 * SCALE, available * 0.45))
    self.mode_select:set_size(mode_w)
    self.mode_select:update_size_position()
    local mode_x = x - mode_w - button_gap
    self.mode_select:set_position(mode_x, button_y)
    self.status:set_size(math.max(0, mode_x - status_x - padding), title_h)
  else
    self.status:set_size(math.max(0, x - status_x - padding), title_h)
  end

  self.line:set_position(0, toolbar_y + toolbar_h + style.padding.y)
  self.line:set_size(size.x, nil)
  local prompt_height = (config.plugins.assistant and config.plugins.assistant.prompt_height) or 140
  local activity_height = math.max(
    widget_height(self.activity),
    widget_height(self.insert_file_button),
    widget_height(self.insert_project_file_button),
    widget_height(self.send_button),
    widget_height(self.clear_button),
    style.padding.y * 2
  )
  local top = self.line:get_bottom() + style.padding.y
  local bottom_padding = style.padding.y
  local bottom = size.y - bottom_padding
  local prompt_y = bottom - prompt_height
  local activity_y = prompt_y - activity_height - style.padding.y
  local transcript_height = math.max(40, activity_y - top - style.padding.y)

  self.transcript.position.x = pos.x + left
  self.transcript.position.y = pos.y + top
  self.transcript.size.x = math.max(10, size.x - padding * 2)
  self.transcript.size.y = transcript_height
  self.raw_transcript.position.x = self.transcript.position.x
  self.raw_transcript.position.y = self.transcript.position.y
  self.raw_transcript.size.x = self.transcript.size.x
  self.raw_transcript.size.y = self.transcript.size.y

  local clear_x = right - widget_width(self.clear_button)
  local clear_y = activity_y + math.max(0, (activity_height - widget_height(self.clear_button)) / 2)
  self.clear_button:set_position(clear_x, clear_y)

  local send_x = clear_x - button_gap - widget_width(self.send_button)
  local send_y = activity_y + math.max(0, (activity_height - widget_height(self.send_button)) / 2)
  self.send_button:set_position(send_x, send_y)

  local project_file_x = send_x - button_gap - widget_width(self.insert_project_file_button)
  local project_file_y = activity_y + math.max(0, (activity_height - widget_height(self.insert_project_file_button)) / 2)
  self.insert_project_file_button:set_position(project_file_x, project_file_y)

  local file_x = project_file_x - button_gap - widget_width(self.insert_file_button)
  local file_y = activity_y + math.max(0, (activity_height - widget_height(self.insert_file_button)) / 2)
  self.insert_file_button:set_position(file_x, file_y)

  self.activity:set_position(left, activity_y + math.max(0, (activity_height - widget_height(self.activity)) / 2))
  self.activity:set_size(math.max(10, file_x - left - padding), widget_height(self.activity))

  self.prompt.position.x = pos.x + left
  self.prompt.position.y = pos.y + prompt_y
  self.prompt.size.x = math.max(10, size.x - padding * 2)
  self.prompt.size.y = prompt_height

  local activity, active = animated_status_label(self:get_display_status())
  self.activity:set_label(activity)
  if active then core.redraw = true end
  if self.pending_streaming_transcript_text then
    local last = self.last_streaming_transcript_refresh or 0
    if system.get_time() - last >= STREAMING_TRANSCRIPT_REFRESH_INTERVAL then
      self:flush_streaming_transcript()
    end
  end
  self:get_transcript_view():update()
  if self.scroll_transcript_to_bottom_once then
    scroll_view_to_bottom(self:get_transcript_view())
    self.scroll_transcript_to_bottom_once = false
  end
  self.prompt:update()
  self.mode_select:update()
  PromptView.transcript_menu:update()
  PromptView.raw_transcript_menu:update()
end

---Draw the view contents.
function PromptView:draw()
  if PromptView.super.draw(self) then
    self:get_transcript_view():draw()
    self.prompt:draw()
    PromptView.transcript_menu:draw()
    PromptView.raw_transcript_menu:draw()
  end
end

---Handle on text input.
function PromptView:on_text_input(text)
  self.prompt:on_text_input(text)
  return true
end

---Handle on ime text editing.
function PromptView:on_ime_text_editing(...)
  self.prompt:on_ime_text_editing(...)
  return true
end

---Handle on mouse pressed.
function PromptView:on_mouse_pressed(button, x, y, clicks)
  if PromptView.transcript_menu.show_context_menu then
    return PromptView.transcript_menu:on_mouse_pressed(button, x, y, clicks)
  end
  if PromptView.raw_transcript_menu.show_context_menu then
    return PromptView.raw_transcript_menu:on_mouse_pressed(button, x, y, clicks)
  end
  if self.mode_select:is_visible() and self.mode_select:mouse_on_top(x, y) then
    return PromptView.super.on_mouse_pressed(self, button, x, y, clicks)
  end
  local transcript_view = self:get_transcript_view()
  if contains(self.prompt, x, y) then
    self.focused_child = self.prompt
    core.set_active_view(self.prompt)
    if self.prompt:on_mouse_pressed(button, x, y, clicks) then
      return true
    end
    return
  elseif contains(transcript_view, x, y) then
    self.focused_child = transcript_view
    core.set_active_view(transcript_view)
    if button == "right" then
      local menu = self.transcript_mode == "raw" and PromptView.raw_transcript_menu or PromptView.transcript_menu
      local handled = menu:on_mouse_pressed(button, x, y, clicks)
      if handled then return true end
    end
    if transcript_view:on_mouse_pressed(button, x, y, clicks) then
      return true
    end
    if self.transcript_mode ~= "raw" then
      return true
    end
    return
  end
  if PromptView.super.on_mouse_pressed(self, button, x, y, clicks) then
    return true
  end
end

---Handle on mouse released.
function PromptView:on_mouse_released(button, x, y)
  PromptView.super.on_mouse_released(self, button, x, y)
  self.prompt:on_mouse_released(button, x, y)
  self:get_transcript_view():on_mouse_released(button, x, y)
end

---Handle on mouse moved.
function PromptView:on_mouse_moved(x, y, dx, dy)
  if PromptView.transcript_menu:on_mouse_moved(x, y) then return true end
  if PromptView.raw_transcript_menu:on_mouse_moved(x, y) then return true end
  local transcript_view = self:get_transcript_view()
  local processed = PromptView.super.on_mouse_moved(self, x, y, dx, dy)
  if contains(self.prompt, x, y) or self.prompt:scrollbar_dragging() then
    self.prompt:on_mouse_moved(x, y, dx, dy)
    self.cursor = self.prompt.cursor or "arrow"
  else
    self.prompt:on_mouse_left()
  end
  if contains(transcript_view, x, y) or transcript_view:scrollbar_dragging() then
    transcript_view:on_mouse_moved(x, y, dx, dy)
    if contains(transcript_view, x, y)
      and transcript_view.get_link_at
      and transcript_view:get_link_at(x, y)
    then
      transcript_view.cursor = "hand"
    end
    self.cursor = transcript_view.cursor or "arrow"
  else
    transcript_view:on_mouse_left()
  end
  if not (contains(self.prompt, x, y) or contains(transcript_view, x, y)) then
    self.cursor = "arrow"
  end
  if self.prompt:scrollbar_dragging() or transcript_view:scrollbar_dragging() then
    return true
  end
  return processed
end

---Handle on mouse left.
function PromptView:on_mouse_left()
  PromptView.super.on_mouse_left(self)
  self.prompt:on_mouse_left()
  self.transcript:on_mouse_left()
  self.raw_transcript:on_mouse_left()
  self.cursor = "arrow"
end

---Handle on mouse wheel.
function PromptView:on_mouse_wheel(y, x)
  if zoom_modifier_pressed() then return false end
  local mx = core.root_view and core.root_view.mouse and core.root_view.mouse.x or 0
  local my = core.root_view and core.root_view.mouse and core.root_view.mouse.y or 0
  local transcript_view = self:get_transcript_view()
  if keymap.modkeys["shift"] then
    x = y
    y = 0
  end
  if contains(self.prompt, mx, my) then
    if y and y ~= 0 then
      self.prompt.scroll.to.y = self.prompt.scroll.to.y + y * -config.mouse_wheel_scroll
    end
    if x and x ~= 0 then
      self.prompt.scroll.to.x = self.prompt.scroll.to.x + x * -config.mouse_wheel_scroll
    end
    return true
  end
  if contains(transcript_view, mx, my) then
    if y and y ~= 0 then
      transcript_view.scroll.to.y = transcript_view.scroll.to.y + y * -config.mouse_wheel_scroll
    end
    if x and x ~= 0 then
      transcript_view.scroll.to.x = transcript_view.scroll.to.x + x * -config.mouse_wheel_scroll
    end
    return true
  end
  return PromptView.super.on_mouse_wheel(self, y, x)
end

---Handle on scale change.
function PromptView:on_scale_change(...)
  PromptView.super.on_scale_change(self, ...)
  self.prompt:on_scale_change(...)
  self.transcript:on_scale_change(...)
  self.raw_transcript:on_scale_change(...)
end

---Handle on touch pressed.
function PromptView:on_touch_pressed(...)
  PromptView.super.on_touch_pressed(self, ...)
  self.prompt:on_touch_pressed(...)
  self:get_transcript_view():on_touch_pressed(...)
end

---Handle on touch released.
function PromptView:on_touch_released(...)
  PromptView.super.on_touch_released(self, ...)
  self.prompt:on_touch_released(...)
  self:get_transcript_view():on_touch_released(...)
end

---Handle on touch moved.
function PromptView:on_touch_moved(...)
  PromptView.super.on_touch_moved(self, ...)
  self.prompt:on_touch_moved(...)
  self:get_transcript_view():on_touch_moved(...)
end

PromptView.transcript_menu:register(
  function()
    local view = PromptView.active_conversation_view()
    if not view then return nil end
    return view.focused_child == view.transcript and view or nil
  end, {
    { text = "View Raw Markdown", command = "assistant-conversation:view-raw-markdown" },
    { text = "View Raw Responses", command = "assistant-conversation:view-raw-responses" }
  }
)

PromptView.raw_transcript_menu:register(
  function()
    local view = PromptView.active_conversation_view()
    if not view then return nil end
    return view.focused_child == view.raw_transcript and view or nil
  end, {
    { text = "View Rendered", command = "assistant-conversation:view-rendered-markdown" },
    { text = "View Raw Responses", command = "assistant-conversation:view-raw-responses" }
  }
)

return PromptView
