local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local Widget = require "widget"
local Button = require "widget.button"
local Label = require "widget.label"
local Line = require "widget.line"
local ListBox = require "widget.listbox"
local MessageBox = require "widget.messagebox"
local TextBox = require "widget.textbox"
local ContextMenu = require "core.contextmenu"
local Conversation = require "plugins.assistant.conversation"

---Widget view listing saved assistant memories for a project.
---@class assistant.ui.MemoriesList : widget
---@field project_dir string
---@field on_open fun(item: table, view: assistant.ui.MemoriesList)|nil
---@field on_delete fun(item: table, project_dir: string, callback: fun(deleted: boolean)|nil)|nil
local MemoriesList = Widget:extend()

MemoriesList.context = "session"
MemoriesList.menu = ContextMenu()

---Truncate text for compact list display.
---@param text string|nil
---@param limit integer
---@return string
local function truncate(text, limit)
  text = tostring(text or "")
  text = text:gsub("%s+", " ")
  if #text <= limit then return text end
  return text:sub(1, limit - 3):gsub("%s+$", "") .. "..."
end

---Return doc text without trailing whitespace.
---@param doc core.doc
---@return string
local function get_doc_text(doc)
  return doc:get_text(1, 1, math.huge, math.huge):gsub("%s+$", "")
end

---Replace all doc text.
---@param doc core.doc
---@param text string|nil
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

---Return whether coordinates are inside a view rectangle.
---@param view core.view
---@param x number
---@param y number
---@return boolean
local function contains(view, x, y)
  return x >= view.position.x
    and y >= view.position.y
    and x <= view.position.x + view.size.x
    and y <= view.position.y + view.size.y
end

---Return whether only the zoom modifier is pressed.
---@return boolean
local function zoom_modifier_pressed()
  local ctrl_key = PLATFORM == "Mac OS X" and "cmd" or "ctrl"
  if not keymap.modkeys[ctrl_key] then return false end
  for key, status in pairs(keymap.modkeys) do
    if key ~= ctrl_key and status then return false end
  end
  return true
end

---Widget view for editing one memory.
---@class assistant.ui.MemoryEditor : widget
---@field project_dir string
---@field item table
---@field on_save fun(item: table)|nil
local MemoryEditor = Widget:extend()

---Create a new memory editor.
---@param project_dir string
---@param item table
---@param on_save fun(item: table)|nil
function MemoryEditor:new(project_dir, item, on_save)
  MemoryEditor.super.new(self)
  self.defer_draw = false
  self.border.width = 0
  self.project_dir = project_dir
  self.item = item or {}
  self.on_save = on_save
  self.name = "Assistant Memory - " .. (self.item.title or "Memory")

  self.title_label = Label(self, "Title")
  self.title_textbox = TextBox(self, self.item.title or "Memory", "memory title...")
  self.save_button = Button(self, "Save")
  self.save_button:set_icon(">")

  self.content_doc = Doc("Assistant Memory.md", nil, true)
  set_doc_text(self.content_doc, self.item.content or "")
  self.content = DocView(self.content_doc)
  self.content.assistant_memory_editor = self
  local editor_view = self
  function self.content:get_name()
    return editor_view:get_name()
  end

  local editor = self
  function self.save_button:on_click(pressed)
    if pressed == "left" then
      editor:save()
    end
  end

  self:set_size(500, 400)
  self:show()
end

---Return the view name.
---@return string
function MemoryEditor:get_name()
  return self.name or "Assistant Memory"
end

---Set editor content.
---@param text string
function MemoryEditor:set_content(text)
  set_doc_text(self.content_doc, text)
end

---Return editor content.
---@return string
function MemoryEditor:get_content()
  return get_doc_text(self.content_doc)
end

---Save the memory to disk.
---@return table|nil updated
function MemoryEditor:save()
  local updated = Conversation.update_memory(
    self.project_dir,
    self.item.id,
    self.title_textbox:get_text(),
    self:get_content()
  )
  if not updated then
    core.error("Assistant: could not save memory %s", self.item.id or "")
    return nil
  end
  self.item = updated
  self.name = "Assistant Memory - " .. (updated.title or "Memory")
  if self.on_save then self.on_save(updated) end
  core.log("Assistant: saved memory %s", updated.id)
  return updated
end

---Draw the memory editor.
function MemoryEditor:draw()
  if MemoryEditor.super.draw(self) then
    self.content:draw()
  end
end

---Update the memory editor layout.
function MemoryEditor:update()
  if not MemoryEditor.super.update(self) then return end
  local pos = self:get_position()
  local size = self:get_size()
  local padding = style.padding.x
  local button_gap = math.max(style.padding.x / 2, 6 * SCALE)
  local button_width = 90 * SCALE
  self.background_color = style.background
  self.title_label:set_position(padding, style.padding.y)
  self.save_button:set_size(button_width, nil)
  self.save_button:set_position(
    size.x - padding - self.save_button:get_size().x,
    self.title_label:get_bottom() + 4
  )
  self.title_textbox:set_position(padding, self.title_label:get_bottom() + 4)
  self.title_textbox:set_size(
    math.max(10, self.save_button:get_position().x - padding - button_gap)
  )
  local content_y = self.title_textbox:get_bottom() + 10
  self.content.position.x = pos.x + padding
  self.content.position.y = pos.y + content_y
  self.content.size.x = math.max(10, size.x - padding * 2)
  self.content.size.y = math.max(40, size.y - content_y - style.padding.y)
  self.content:update()
end

---Handle text input.
function MemoryEditor:on_text_input(text)
  if self.focused_child and self.focused_child.on_text_input then
    self.focused_child:on_text_input(text)
    return true
  end
  self.content:on_text_input(text)
  return true
end

---Handle IME text editing.
function MemoryEditor:on_ime_text_editing(...)
  if self.focused_child and self.focused_child.on_ime_text_editing then
    self.focused_child:on_ime_text_editing(...)
    return true
  end
  self.content:on_ime_text_editing(...)
  return true
end

---Handle mouse pressed.
function MemoryEditor:on_mouse_pressed(button, x, y, clicks)
  if contains(self.content, x, y) then
    self.focused_child = self.content
    core.set_active_view(self.content)
    keymap.on_mouse_pressed(button, x, y, clicks)
    if self.content:on_mouse_pressed(button, x, y, clicks) then
      return true
    end
    return true
  end
  if self.title_textbox:mouse_on_top(x, y) then
    self.focused_child = self.title_textbox
  end
  return MemoryEditor.super.on_mouse_pressed(self, button, x, y, clicks)
end

---Handle mouse released.
function MemoryEditor:on_mouse_released(button, x, y)
  MemoryEditor.super.on_mouse_released(self, button, x, y)
  self.content:on_mouse_released(button, x, y)
end

---Handle mouse moved.
function MemoryEditor:on_mouse_moved(x, y, dx, dy)
  local processed = MemoryEditor.super.on_mouse_moved(self, x, y, dx, dy)
  if contains(self.content, x, y) or self.content:scrollbar_dragging() then
    self.content:on_mouse_moved(x, y, dx, dy)
    self.cursor = self.content.cursor or "arrow"
  else
    self.content:on_mouse_left()
    self.cursor = "arrow"
  end
  if self.content:scrollbar_dragging() then return true end
  return processed
end

---Handle mouse left.
function MemoryEditor:on_mouse_left()
  MemoryEditor.super.on_mouse_left(self)
  self.content:on_mouse_left()
  self.cursor = "arrow"
end

---Handle mouse wheel.
function MemoryEditor:on_mouse_wheel(y, x)
  if zoom_modifier_pressed() then return false end
  local mx = core.root_view and core.root_view.mouse and core.root_view.mouse.x or 0
  local my = core.root_view and core.root_view.mouse and core.root_view.mouse.y or 0
  if keymap.modkeys["shift"] then
    x = y
    y = 0
  end
  if contains(self.content, mx, my) then
    if y and y ~= 0 then
      self.content.scroll.to.y = self.content.scroll.to.y + y * -config.mouse_wheel_scroll
    end
    if x and x ~= 0 then
      self.content.scroll.to.x = self.content.scroll.to.x + x * -config.mouse_wheel_scroll
    end
    return true
  end
  return MemoryEditor.super.on_mouse_wheel(self, y, x)
end

---Handle scale change.
function MemoryEditor:on_scale_change(...)
  MemoryEditor.super.on_scale_change(self, ...)
  self.content:on_scale_change(...)
end

---Create a new memories list.
---@param project_dir string
---@param on_open fun(item: table, view: assistant.ui.MemoriesList)|nil
---@param on_delete fun(item: table, project_dir: string, callback: fun(deleted: boolean)|nil)|nil
function MemoriesList:new(project_dir, on_open, on_delete)
  MemoriesList.super.new(self)

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
  self.name = self.path .. " - Assistant Memories"

  self.title = Label(self, "Assistant Memories for: " .. self.path)
  self.line = Line(self, 2, style.padding.x)
  self.textbox = TextBox(self, "", "filter memories...")

  self.list_container = Widget(self)
  self.list_container.border.width = 0
  self.list_container:set_size(200, 200)

  self.list = ListBox(self.list_container)
  self.list.border.width = 0
  self.list:enable_expand(true)
  self.list:add_column("Title")
  self.list:add_column("Updated")
  self.list:add_column("ID")
  self.list:add_column("Preview")

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

---Return the view name.
---@return string
function MemoriesList:get_name()
  return self.name or "Assistant Memories"
end

---Return the selected memory.
---@return table|nil
function MemoriesList:get_selected_data()
  local idx = self.list:get_selected()
  return idx and self.list:get_row_data(idx) or nil
end

---Handle mouse pressed.
function MemoriesList:on_mouse_pressed(button, x, y, clicks)
  if MemoriesList.menu.show_context_menu then
    return MemoriesList.menu:on_mouse_pressed(button, x, y, clicks)
  end
  local processed = MemoriesList.super.on_mouse_pressed(self, button, x, y, clicks)
  local handled = false
  if self.list:mouse_on_top(x, y) then
    handled = MemoriesList.menu:on_mouse_pressed(button, x, y, clicks)
  end
  return handled or processed
end

---Handle mouse moved.
function MemoriesList:on_mouse_moved(x, y, dx, dy)
  if MemoriesList.menu:on_mouse_moved(x, y) then return true end
  return MemoriesList.super.on_mouse_moved(self, x, y, dx, dy)
end

---Add a memory row.
---@param item table
function MemoriesList:add_memory(item)
  self.list:add_row({
    style.text, truncate(item.title or "Memory", 30),
    ListBox.COLEND,
    style.syntax.literal, item.updated_at or item.created_at or "",
    ListBox.COLEND,
    style.dim, item.id or "",
    ListBox.COLEND,
    style.syntax.comment, truncate(item.content or "", 60)
  }, item)
end

---Refresh the memories list.
function MemoriesList:refresh()
  self.list:filter(nil)
  self.list:clear()
  self.list.rows_original = {}
  self.list.row_data_original = {}
  self.list.rows_idx_original = {}
  for _, item in ipairs(Conversation.list_memories(self.project_dir)) do
    self:add_memory(item)
  end
  self.list:resize_to_parent()
  core.redraw = true
end

---Open selected memory.
function MemoriesList:open_selected()
  local data = self:get_selected_data()
  if not data then return end
  if self.on_open then
    self.on_open(data, self)
  end
end

---Add a new blank memory and open it.
---@return table|nil memory
function MemoriesList:add_new_memory()
  local item = Conversation.add_memory(self.project_dir, "Memory", "")
  if not item then
    core.error("Assistant: could not add memory")
    return nil
  end
  self:refresh()
  for index = 1, #self.list.rows do
    local data = self.list:get_row_data(index)
    if data and data.id == item.id then
      self.list:set_selected(index)
      break
    end
  end
  if self.on_open then
    self.on_open(item, self)
  end
  return item
end

---Confirm deletion of selected memory.
function MemoriesList:confirm_delete_selected()
  local data = self:get_selected_data()
  if not data then return end
  MessageBox.warning(
    "Assistant Delete Memory",
    {
      "Do you really want to delete this memory?",
      Widget.NEWLINE,
      Widget.NEWLINE,
      "Title: " .. (data.title or "Memory"),
      Widget.NEWLINE,
      "ID: " .. (data.id or ""),
      Widget.NEWLINE,
      "Project: " .. self.project_dir
    },
    function(_, button_id)
      if button_id == 1 then
        local function refresh_after_delete()
          self:refresh()
        end
        if self.on_delete then
          self.on_delete(data, self.project_dir, refresh_after_delete)
        else
          Conversation.delete_memory(self.project_dir, data.id)
          refresh_after_delete()
        end
      end
    end,
    MessageBox.BUTTONS_YES_NO
  )
end

---Draw the view contents.
function MemoriesList:draw()
  if MemoriesList.super.draw(self) then
    MemoriesList.menu:draw()
  end
end

---Update the memories list layout.
function MemoriesList:update()
  if not MemoriesList.super.update(self) then return end
  local size = self:get_size()
  self.background_color = style.background
  self.title:set_position(style.padding.x, style.padding.y)
  self.title:set_label(
    "Assistant Memories: "
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
  MemoriesList.menu:update()
end

command.add(function()
  return core.active_view and core.active_view:is(MemoriesList), core.active_view
end, {
  ["assistant-memories:open"] = function(view)
    view:open_selected()
  end,
  ["assistant-memories:delete"] = function(view)
    view:confirm_delete_selected()
  end,
  ["assistant-memories:add"] = function(view)
    view:add_new_memory()
  end,
  ["assistant-memories:refresh"] = function(view)
    view:refresh()
  end
})

MemoriesList.menu:register(
  function()
    return core.active_view
      and core.active_view:is(MemoriesList)
      and core.active_view:get_selected_data()
  end, {
    { text = "Open Memory", command = "assistant-memories:open" },
    ContextMenu.DIVIDER,
    { text = "Delete Memory", command = "assistant-memories:delete" }
  }
)

MemoriesList.menu:register(
  function()
    return core.active_view
      and core.active_view:is(MemoriesList)
  end, {
    { text = "Add Memory", command = "assistant-memories:add" },
    { text = "Refresh", command = "assistant-memories:refresh" }
  }
)

MemoriesList.MemoryEditor = MemoryEditor

return MemoriesList
