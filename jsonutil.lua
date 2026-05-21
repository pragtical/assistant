local core_json = require "core.json"

---JSON encoder helpers for assistant session/provider payloads.
---
---The stock JSON encoder is still used for pretty output; this module adds a
---yielding compact encoder and an explicit empty-array marker.
---@class assistant.jsonutil
local jsonutil = {}
jsonutil.empty_array = setmetatable({}, { __jsonutil_empty_array = true })

local YIELD_EVERY = 64

local escape_char_map = {
  ["\\"] = "\\",
  ["\""] = "\"",
  ["\b"] = "b",
  ["\f"] = "f",
  ["\n"] = "n",
  ["\r"] = "r",
  ["\t"] = "t"
}

---Handle maybe yield.
local function maybe_yield(state)
  state.count = (state.count or 0) + 1
  if state.count % (state.yield_every or YIELD_EVERY) == 0 and coroutine.isyieldable() then
    coroutine.yield()
  end
end

---Handle escape char.
local function escape_char(c)
  return "\\" .. (escape_char_map[c] or string.format("u%04x", c:byte()))
end

---Handle encode string.
local function encode_string(value)
  if value == core_json.null then return "null" end
  local flag = core_json.number_flag
  if type(flag) == "string"
    and #value > #flag
    and value:sub(1, #flag) == flag
  then
    return value:sub(#flag + 1)
  end
  return '"' .. value:gsub('[%z\1-\31\\"]', escape_char) .. '"'
end

local encode_value

---Return whether empty array marker.
local function is_empty_array_marker(value)
  local mt = getmetatable(value)
  return mt and mt.__jsonutil_empty_array == true
end

---Handle encode table.
local function encode_table(value, state, stack)
  if is_empty_array_marker(value) then return "[]" end
  if stack[value] then error("circular reference") end
  stack[value] = true
  local result = {}
  if rawget(value, 1) ~= nil or next(value) == nil then
    local count = 0
    for key in pairs(value) do
      if type(key) ~= "number" then
        error("invalid table: mixed or invalid key types")
      end
      count = count + 1
      maybe_yield(state)
    end
    if count ~= #value then error("invalid table: sparse array") end
    for _, item in ipairs(value) do
      result[#result + 1] = encode_value(item, state, stack)
    end
    stack[value] = nil
    return #result > 0 and ("[" .. table.concat(result, ",") .. "]") or "{}"
  end
  for key, item in pairs(value) do
    if type(key) ~= "string" then
      error("invalid table: mixed or invalid key types")
    end
    result[#result + 1] = encode_string(key) .. ":" .. encode_value(item, state, stack)
  end
  stack[value] = nil
  return "{" .. table.concat(result, ",") .. "}"
end

encode_value = function(value, state, stack)
  maybe_yield(state)
  local kind = type(value)
  if kind == "nil" then return "null" end
  if kind == "string" then return encode_string(value) end
  if kind == "number" then
    if value ~= value or value <= -math.huge or value >= math.huge then
      error("unexpected number value '" .. tostring(value) .. "'")
    end
    return string.format("%.14g", value)
  end
  if kind == "boolean" then return tostring(value) end
  if kind == "table" then return encode_table(value, state, stack) end
  error("unexpected type '" .. kind .. "'")
end

---Handle encode.
---@param value any
---@param options table|boolean|nil
---@return string
function jsonutil.encode(value, options)
  if options == true or (type(options) == "table" and options.prettify) then
    return core_json.encode(value, true)
  end
  local state = type(options) == "table" and options or {}
  return encode_value(value, state, {})
end

return jsonutil
