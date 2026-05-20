local core = require "core"
local style = require "core.style"
local Button = require "widget.button"
local Dialog = require "widget.dialog"
local Label = require "widget.label"
local Line = require "widget.line"
local ListBox = require "widget.listbox"
local MessageBox = require "widget.messagebox"
local TextBox = require "widget.textbox"
local Widget = require "widget"

---Model selection dialog used by assistant conversation views.
---@class assistant.ui.ModelDialog : widget.dialog
---@field models string[]
---@field current_model string|nil
---@field on_submit fun(self: assistant.ui.ModelDialog, model: string)
local ModelDialog = Dialog:extend()

---Create a new instance.
---@param models string[]
---@param current_model string|nil
function ModelDialog:new(models, current_model)
  ModelDialog.super.new(self, "Assistant Model")

  self.type_name = "plugins.assistant.ui.ModelDialog"
  self.models = models or {}
  self.current_model = current_model

  self.model_label = Label(self.panel, "Model")
  self.filter_textbox = TextBox(self.panel, "", "filter models...")

  self.list_container = Widget(self.panel)
  self.list_container.border.width = 0
  self.list_container:set_size(500 * SCALE, 240 * SCALE)

  self.list = ListBox(self.list_container)
  self.list.border.width = 0
  self.list:enable_expand(true)
  self.list:add_column("Model")

  self.line = Line(self.panel, 1, style.padding.x)
  self.ok = Button(self.panel, "OK")
  self.ok:set_icon(">")
  self.cancel = Button(self.panel, "Cancel")
  self.cancel:set_icon("C")

  for _, model in ipairs(self.models) do
    self:add_model(model)
  end
  self:select_model(current_model)

  local this = self
  self.filter_textbox.on_change = function(_, value)
    this.list:filter(value)
    this:select_model(this.current_model)
    if #this.list.rows > 0 and not this.list:get_selected() then
      this.list:set_selected(1)
    end
  end

  local list_on_mouse_pressed = self.list.on_mouse_pressed
  self.list.on_mouse_pressed = function(list, button, x, y, clicks)
    list_on_mouse_pressed(list, button, x, y, clicks)
    if button == "left" and clicks > 1 then
      this:submit()
    end
  end

  ---Handle on click.
  function self.ok:on_click()
    this:submit()
  end

  ---Handle on click.
  function self.cancel:on_click()
    this:on_close()
  end
end

---Add model.
---@param model string
function ModelDialog:add_model(model)
  if not model or model == "" then return end
  self.list:add_row({ style.text, model }, model)
end

---Handle select model.
---@param model string|nil
function ModelDialog:select_model(model)
  if not model then
    if #self.list.rows > 0 then self.list:set_selected(1) end
    return
  end
  for idx = 1, #self.list.rows do
    if self.list:get_row_data(idx) == model then
      self.list:set_selected(idx)
      return
    end
  end
  if #self.list.rows > 0 then self.list:set_selected(1) end
end

---Return the selected model.
---@return string|nil
function ModelDialog:get_selected_model()
  local idx = self.list:get_selected()
  return idx and self.list:get_row_data(idx) or nil
end

---Submit the current selection or prompt.
function ModelDialog:submit()
  local model = self:get_selected_model()
  if not model then
    MessageBox.error("Assistant Model", "Select a model.")
    return
  end
  self:on_submit(model)
  self:on_close()
end

---Handle on submit.
---@param model string
function ModelDialog:on_submit(model) end

---Handle on close.
function ModelDialog:on_close()
  ModelDialog.super.on_close(self)
  self:destroy()
end

---Update size position.
function ModelDialog:update_size_position()
  ModelDialog.super.update_size_position(self)

  local padding = style.padding.x / 2
  local width = math.max(520 * SCALE, core.root_view.size.x * 0.35)
  local height = math.max(360 * SCALE, core.root_view.size.y * 0.42)
  self:set_size(width, height)
  local panel_height = self.panel:get_height()

  self.model_label:set_position(padding, 0)
  self.filter_textbox:set_position(padding, self.model_label:get_bottom() + style.padding.y / 2)
  self.filter_textbox:set_size(width - style.padding.x, self.filter_textbox:get_real_height())

  local buttons_y = panel_height - self.ok:get_height() - (style.padding.y / 2)
  self.line:set_position(0, buttons_y - style.padding.y)

  self.list_container:set_position(padding, self.filter_textbox:get_bottom() + style.padding.y)
  self.list_container:set_size(
    width - style.padding.x,
    math.max(120 * SCALE, self.line.position.y - self.list_container.position.y - style.padding.y)
  )
  self.list:resize_to_parent()

  self.ok:set_position(padding, buttons_y)
  self.cancel:set_position(self.ok:get_right() + style.padding.x, buttons_y)

  self.close:set_position(
    self.size.x - self.close.size.x - (style.padding.x / 2),
    style.padding.y / 2
  )
end

return ModelDialog
