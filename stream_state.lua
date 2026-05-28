---Helpers for tracking streamed assistant response state.
---@class assistant.stream_state
local stream_state = {}

---Incrementally detects a completed proposed plan block in plan mode streams.
---@class assistant.stream_state.PlanModeStreamState
---@field text string
---@field open_at integer|nil
---@field close_at integer|nil
---@field completed_text_end integer|nil
---@field completed boolean
local PlanModeStreamState = {}
PlanModeStreamState.__index = PlanModeStreamState

local OPEN_TAG = "<proposed_plan>"
local CLOSE_TAG = "</proposed_plan>"
local PLAN_DRAFTED_MARKER = "Plan Drafted!"

---Handle trim.
local function trim(text)
  return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

---Handle find plan open.
local function find_plan_open(text, start)
  start = start or 1
  while true do
    local at = text:find(OPEN_TAG, start, true)
    if not at then return nil end
    local before = at > 1 and text:sub(at - 1, at - 1) or ""
    local after_at = at + #OPEN_TAG
    local after = after_at <= #text and text:sub(after_at, after_at) or ""
    local starts_block = before == "" or before == "\n" or before:match("%s")
    local ends_tag = after == "" or after == "\n" or after:match("%s")
    if starts_block and ends_tag and before ~= "`" and after ~= "`" then
      return at
    end
    start = at + #OPEN_TAG
  end
end

---Create a new instance.
---@return assistant.stream_state.PlanModeStreamState
function PlanModeStreamState:new()
  return setmetatable({
    text = "",
    open_at = nil,
    close_at = nil,
    completed_text_end = nil,
    completed = false
  }, self)
end

---Update update.
---@param delta string
---@return boolean completed
function PlanModeStreamState:update(delta)
  delta = tostring(delta or "")
  if delta == "" then return self.completed end
  self.text = self.text .. delta
  self.open_at = self.open_at or find_plan_open(self.text)
  if self.open_at then
    self.close_at = self.close_at or self.text:find(CLOSE_TAG, self.open_at + #OPEN_TAG, true)
  end
  self.completed = self.open_at ~= nil and self.close_at ~= nil
  if self.completed and not self.completed_text_end then
    self.completed_text_end = self.close_at + #CLOSE_TAG - 1
  end
  return self.completed
end

---Return whether started is available.
---@return boolean
function PlanModeStreamState:has_started()
  return self.open_at ~= nil
end

---Return whether complete.
---@return boolean
function PlanModeStreamState:is_complete()
  return self.completed == true
end

---Handle content.
---@return string|nil
function PlanModeStreamState:content()
  if not self.open_at then return nil end
  local content_start = self.open_at + #OPEN_TAG
  local content_end = self.close_at and self.close_at - 1 or #self.text
  return self.text:sub(content_start, content_end)
end

---Handle completed text.
---@return string|nil
function PlanModeStreamState:completed_text()
  if not self.completed_text_end then return nil end
  local start_at = self.open_at or 1
  return self.text:sub(start_at, self.completed_text_end)
end

---Handle wrapped text.
---@return string|nil
function PlanModeStreamState:wrapped_text()
  local completed = self:completed_text()
  if completed then return completed end
  local text = trim(self.text)
  if text == "" then return nil end
  return OPEN_TAG .. "\n" .. text .. "\n" .. CLOSE_TAG
end

stream_state.PlanModeStreamState = PlanModeStreamState
stream_state.OPEN_PROPOSED_PLAN_TAG = OPEN_TAG
stream_state.CLOSE_PROPOSED_PLAN_TAG = CLOSE_TAG
stream_state.PLAN_DRAFTED_MARKER = PLAN_DRAFTED_MARKER

---Handle contains completed plan.
---@param text string
---@return boolean
function stream_state.contains_completed_plan(text)
  text = tostring(text or "")
  local trimmed = trim(text)
  return trimmed:sub(-#PLAN_DRAFTED_MARKER) == PLAN_DRAFTED_MARKER
    or (find_plan_open(text) ~= nil and text:find(CLOSE_TAG, 1, true) ~= nil)
end

---Return whether text ends with the plan drafted marker.
---@param text string
---@return boolean
function stream_state.has_plan_drafted_marker(text)
  local trimmed = trim(text)
  return trimmed:sub(-#PLAN_DRAFTED_MARKER) == PLAN_DRAFTED_MARKER
end

---Strip the plan drafted marker from the end of text.
---@param text string
---@return string
function stream_state.strip_plan_drafted_marker(text)
  text = tostring(text or "")
  if not stream_state.has_plan_drafted_marker(text) then return text end
  local trimmed = trim(text)
  trimmed = trimmed:sub(1, #trimmed - #PLAN_DRAFTED_MARKER)
  return trim(trimmed)
end

---Handle wrap plan.
---@param text string
---@return string|nil
function stream_state.wrap_plan(text)
  local state = PlanModeStreamState:new()
  state:update(text)
  return state:wrapped_text()
end

return stream_state
