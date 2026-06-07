local core = require "core"
local common = require "core.common"
local command = require "core.command"
local style = require "core.style"
local Widget = require "widget"
local Label = require "widget.label"
local Line = require "widget.line"
local ListBox = require "widget.listbox"
local MessageBox = require "widget.messagebox"
local TextBox = require "widget.textbox"
local ContextMenu = require "core.contextmenu"
local Conversation = require "plugins.assistant.conversation"

---Widget view listing saved assistant conversations for a project.
---@class assistant.ui.ConversationsList : widget
---@field project_dir string
---@field on_open fun(item: table)|nil
---@field on_delete fun(item: table)|nil
local ConversationsList = Widget:extend()

ConversationsList.context = "session"
ConversationsList.menu = ContextMenu()

---Handle truncate title.
local function truncate_title(title)
  title = tostring(title or "")
  if #title <= 30 then return title end
  return title:sub(1, 27) .. "..."
end

---Create a new instance.
---@param project_dir string
---@param on_open fun(item: table)|nil
---@param on_delete fun(item: table)|nil
function ConversationsList:new(project_dir, on_open, on_delete)
  ConversationsList.super.new(self)

  if not project_dir then
    core.add_thread(function()
      local parent = core.root_view.root_node:get_node_for_view(self)
      if parent then
        parent:close_view(core.root_view.root_node, self)
      end
    end)
    return
  end

  self.defer_draw = false
  self.border.width = 0
  self.project_dir = project_dir
  self.path = common.basename(project_dir)
  self.on_open = on_open
  self.on_delete = on_delete
  self.name = self.path .. " - Assistant Sessions"

  self.title = Label(self, "Assistant Sessions for: " .. self.path)
  self.line = Line(self, 2, style.padding.x)
  self.textbox = TextBox(self, "", "filter conversations...")

  self.list_container = Widget(self)
  self.list_container.border.width = 0
  self.list_container:set_size(200, 200)

  self.list = ListBox(self.list_container)
  self.list.border.width = 0
  self.list:enable_expand(true)
  self.list:add_column("Title")
  self.list:add_column("Updated")
  self.list:add_column("Agent")
  self.list:add_column("Model")
  self.list:add_column("ID")

  local list_on_mouse_pressed = self.list.on_mouse_pressed
  self.list.on_mouse_pressed = function(this, button, x, y, clicks)
    list_on_mouse_pressed(this, button, x, y, clicks)
    if button == "left" and clicks > 1 then
      self:open_selected()
    end
  end

  self.textbox.on_change = function(_, value)
    self.list:filter(value)
  end

  self:set_size(300, 300)
  self:show()
  self:refresh()
end

---Return the name.
function ConversationsList:get_name()
  return self.name or "Assistant Sessions"
end

---Return the selected data.
function ConversationsList:get_selected_data()
  local idx = self.list:get_selected()
  if idx then
    return self.list:get_row_data(idx)
  end
end

---Handle on mouse pressed.
function ConversationsList:on_mouse_pressed(button, x, y, clicks)
  if ConversationsList.menu.show_context_menu then
    return ConversationsList.menu:on_mouse_pressed(button, x, y, clicks)
  end
  local processed = ConversationsList.super.on_mouse_pressed(self, button, x, y, clicks)
  local handled = false
  if self.list:mouse_on_top(x, y) then
    handled = ConversationsList.menu:on_mouse_pressed(button, x, y, clicks)
  end
  return handled or processed
end

---Handle on mouse moved.
function ConversationsList:on_mouse_moved(x, y, dx, dy)
  if ConversationsList.menu:on_mouse_moved(x, y) then return true end
  return ConversationsList.super.on_mouse_moved(self, x, y, dx, dy)
end

---Add conversation.
function ConversationsList:add_conversation(item)
  local title = item.title or item.name or item.preview or "Assistant Session"
  title = truncate_title(title)
  self.list:add_row({
    style.text, title,
    ListBox.COLEND,
    style.syntax.literal, item.updated_at or item.created_at or "",
    ListBox.COLEND,
    style.syntax.keyword, item.agent or item.provider or "",
    ListBox.COLEND,
    style.syntax.string, item.model or "",
    ListBox.COLEND,
    style.dim, item.id or item.codex_thread_id or ""
  }, item)
end

---Handle refresh.
function ConversationsList:refresh()
  self.list:filter(nil)
  self.list:clear()
  self.list.rows_original = {}
  self.list.row_data_original = {}
  self.list.rows_idx_original = {}
  for _, item in ipairs(Conversation.list(self.project_dir)) do
    self:add_conversation(item)
  end
  self.list:resize_to_parent()
  core.redraw = true
end

---Remove a conversation from the visible list without reading sessions again.
---@param id string
---@return boolean removed
function ConversationsList:remove_conversation_row(id)
  id = tostring(id or "")
  if id == "" then return false end
  local filter = self.textbox:get_text()
  local source = #self.list.row_data_original > 0
    and self.list.row_data_original
    or self.list.row_data
  local items = {}
  local removed = false
  for _, item in ipairs(source) do
    if item and item.id == id then
      removed = true
    elseif item then
      table.insert(items, item)
    end
  end
  if not removed then return false end
  self.list:filter(nil)
  self.list:clear()
  self.list.rows_original = {}
  self.list.row_data_original = {}
  self.list.rows_idx_original = {}
  for _, item in ipairs(items) do
    self:add_conversation(item)
  end
  if filter and filter ~= "" then
    self.list:filter(filter)
  end
  if #self.list.rows > 0 then
    self.list:set_selected(math.min(self.list:get_selected() or 1, #self.list.rows))
  else
    self.list:set_selected(0)
  end
  self.list:resize_to_parent()
  core.redraw = true
  return true
end

---Open selected.
function ConversationsList:open_selected()
  local data = self:get_selected_data()
  if not data then return end
  if self.on_open then
    self.on_open(data)
  end
end

---Handle confirm delete selected.
function ConversationsList:confirm_delete_selected()
  local data = self:get_selected_data()
  if not data then return end
  MessageBox.warning(
    "Assistant Delete Conversation",
    {
      "Do you really want to delete this saved conversation?",
      Widget.NEWLINE,
      Widget.NEWLINE,
      "Title: " .. (data.title or "Assistant Session"),
      Widget.NEWLINE,
      "ID: " .. (data.id or ""),
      Widget.NEWLINE,
      "Project: " .. self.project_dir
    },
    function(_, button_id)
      if button_id == 1 then
        ---Remove the deleted row without re-reading every saved session.
        local function remove_after_delete(deleted)
          if deleted ~= false then
            self:remove_conversation_row(data.id)
          end
        end
        if self.on_delete then
          self.on_delete(data, self.project_dir, remove_after_delete)
        else
          remove_after_delete(Conversation.delete(data.id, self.project_dir))
        end
      end
    end,
    MessageBox.BUTTONS_YES_NO
  )
end

---Delete every saved conversation for this project and refresh the list.
---@return integer deleted
function ConversationsList:delete_all_conversations()
  local deleted = 0
  for _, item in ipairs(Conversation.list(self.project_dir)) do
    if item.id and Conversation.delete(item.id, self.project_dir) then
      deleted = deleted + 1
    end
  end
  self:refresh()
  return deleted
end

---Confirm deletion of every saved conversation.
function ConversationsList:confirm_delete_all()
  local count = #Conversation.list(self.project_dir)
  if count == 0 then return end
  MessageBox.warning(
    "Assistant Delete All Conversations",
    {
      "Do you really want to delete all saved conversations?",
      Widget.NEWLINE,
      Widget.NEWLINE,
      "Count: " .. count,
      Widget.NEWLINE,
      "Project: " .. self.project_dir
    },
    function(_, button_id)
      if button_id == 1 then
        self:delete_all_conversations()
      end
    end,
    MessageBox.BUTTONS_YES_NO
  )
end

---Draw the view contents.
function ConversationsList:draw()
  if ConversationsList.super.draw(self) then
    ConversationsList.menu:draw()
  end
end

---Update update.
function ConversationsList:update()
  if not ConversationsList.super.update(self) then return end
  local size = self:get_size()
  self.background_color = style.background
  self.title:set_position(style.padding.x, style.padding.y)
  self.title:set_label(
    "Assistant Sessions: "
      .. #self.list.rows
      .. ", Project: \""
      .. self.path
      .. "\""
  )
  self.line:set_position(0, self.title:get_bottom() + 10)
  self.line:set_size(size.x, nil)
  self.textbox:set_position(style.padding.x, self.line:get_bottom() + 5)
  self.textbox:set_size(size.x - style.padding.x * 2)
  self.list_container:set_position(style.padding.x, self.textbox:get_bottom() + 10)
  self.list_container:set_size(
    size.x - style.padding.x * 2,
    size.y - self.textbox:get_bottom()
  )
  ConversationsList.menu:update()
end

command.add(function()
  return core.active_view and core.active_view:is(ConversationsList), core.active_view
end, {
  ["assistant-conversations:open"] = function(view)
    view:open_selected()
  end,
  ["assistant-conversations:delete"] = function(view)
    view:confirm_delete_selected()
  end,
  ["assistant-conversations:delete-all"] = function(view)
    view:confirm_delete_all()
  end,
  ["assistant-conversations:refresh"] = function(view)
    view:refresh()
  end
})

ConversationsList.menu:register(
  function()
    return core.active_view
      and core.active_view:is(ConversationsList)
      and core.active_view:get_selected_data()
  end, {
    { text = "Open Conversation", command = "assistant-conversations:open" },
    ContextMenu.DIVIDER,
    { text = "Delete Conversation", command = "assistant-conversations:delete" }
  }
)

ConversationsList.menu:register(
  function()
    return core.active_view
      and core.active_view:is(ConversationsList)
  end, {
    { text = "Refresh", command = "assistant-conversations:refresh" },
    ContextMenu.DIVIDER,
    { text = "Delete All", command = "assistant-conversations:delete-all" }
  }
)

return ConversationsList
