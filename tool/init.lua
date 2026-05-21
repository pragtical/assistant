---Declarative assistant tool specification.
---
---Tool modules create `Tool` instances and the registry asks each instance for
---the concrete registration table to expose on an agent.
---@class assistant.Tool
---@field name string
---@field callback function|nil
---@field build fun(self: assistant.Tool, agent: assistant.Agent, facade: table): assistant.Tool.registration|nil
---@field description string|nil
---@field params table[]|nil
---@field read_only boolean|nil
---@field requires_approval function|nil
---@field compact_result function|nil
---@field compact_provider_call function|nil
---@field compact_history function|nil
---@field activity_label function|nil
---@field activity_markdown function|nil
---@field compact_activity_markdown function|nil
---@field result_is_successful function|nil
---@field additional_properties boolean|nil
---@field new fun(self: assistant.Tool, spec: table): assistant.Tool
---
---@class assistant.Tool.registration
---@field callback function
---@field description string|nil
---@field params table[]|nil
---@field read_only boolean|nil
---@field requires_approval function|nil
---@field compact_result function|nil
---@field compact_provider_call function|nil
---@field compact_history function|nil
---@field activity_label function|nil
---@field activity_markdown function|nil
---@field compact_activity_markdown function|nil
---@field result_is_successful function|nil
---@field additional_properties boolean|nil
local core = require "core"
local json = require "core.json"
local common = require "core.common"
local jsonutil = require "plugins.assistant.jsonutil"
local history_normalizer = require "plugins.assistant.history_normalizer"

local Tool = {}
Tool.__index = Tool

Tool.ARGUMENT_STRING_LIMIT = 2048
Tool.RESULT_CONTENT_LIMIT = 48000
Tool.RESULT_HEAD_LIMIT = 32000
Tool.RESULT_TAIL_LIMIT = 8000

Tool.LARGE_ARGUMENT_KEYS = {
  content = true,
  contents = true,
  file_content = true,
  new_content = true,
  patch = true,
  text = true
}

---Wrap text in a Markdown code fence.
---@param text any
---@param language string|nil
---@return string
function Tool.fenced(text, language)
  return "```" .. (language or "text") .. "\n" .. tostring(text or "") .. "\n```"
end

---Return a concise display form for a status.
---@param status any
---@return string
function Tool.status_suffix(status)
  status = tostring(status or "")
  return status ~= "" and " (" .. status .. ")" or ""
end

---Return a backticked value, or an empty string when missing.
---@param value any
---@return string
function Tool.ticked(value)
  value = tostring(value or "")
  return value ~= "" and "`" .. value .. "`" or ""
end

---Escape a Markdown link label.
---@param value any
---@return string
function Tool.markdown_link_label(value)
  return tostring(value or ""):gsub("\\", "\\\\"):gsub("%[", "\\["):gsub("%]", "\\]")
end

---Return an absolute path candidate for a display path.
---@param value string
---@param context table|nil
---@return string
function Tool.absolute_path(value, context)
  value = tostring(value or "")
  if value == "" then return value end
  if common.is_absolute_path(value) then
    return common.normalize_path(value) or value
  end
  local project_dir = context and context.project_dir
  if type(project_dir) == "string" and project_dir ~= "" then
    return common.normalize_path(project_dir .. PATHSEP .. value) or (project_dir .. PATHSEP .. value)
  end
  local root = core.root_project and core.root_project()
  if root then
    local absolute = core.project_absolute_path(value)
    return common.normalize_path(absolute) or absolute
  end
  return common.normalize_path(value) or value
end

---Return whether a path points to an existing file.
---@param path string
---@return boolean
function Tool.is_file_path(path)
  local info = system.get_file_info(path)
  return info and info.type == "file" or false
end

---Return a project-relative path for a file path when possible.
---@param value string
---@param absolute string
---@param context table|nil
---@return string|nil
function Tool.project_relative_file_path(value, absolute, context)
  value = tostring(value or "")
  absolute = tostring(absolute or "")
  if value == "" then return nil end
  if not common.is_absolute_path(value) then return value end
  local roots = {}
  if context and type(context.project_dir) == "string" and context.project_dir ~= "" then
    table.insert(roots, context.project_dir)
  end
  for _, project in ipairs(core.projects or {}) do
    if type(project) == "table" and type(project.path) == "string" and project.path ~= "" then
      table.insert(roots, project.path)
    end
  end
  for _, root in ipairs(roots) do
    root = common.normalize_path(root) or root
    if absolute == root or common.path_belongs_to(absolute, root) then
      return common.relative_path(root, absolute)
    end
  end
  return nil
end

---Return a Markdown link for existing files, otherwise a backticked path.
---@param value any
---@param context table|nil
---@param fallback string|nil
---@param label string|nil
---@return string
function Tool.file_link_or_ticked(value, context, fallback, label)
  value = tostring(value or "")
  if value == "" then return Tool.ticked(fallback or "file") end
  local absolute = Tool.absolute_path(value, context)
  if absolute ~= "" and Tool.is_file_path(absolute) then
    local relative = Tool.project_relative_file_path(value, absolute, context)
    local target = relative or absolute
    return "[" .. Tool.markdown_link_label(label or relative or value) .. "](<" .. target .. ">)"
  end
  return Tool.ticked(label or value)
end

---Return a backticked path with project-relative display when possible.
---@param value any
---@param context table|nil
---@param fallback string|nil
---@return string
function Tool.relative_path_or_ticked(value, context, fallback)
  value = tostring(value or "")
  if value == "" then return Tool.ticked(fallback or "path") end
  local absolute = Tool.absolute_path(value, context)
  local relative = Tool.project_relative_file_path(value, absolute, context)
  if relative == "." then
    relative = common.basename(absolute)
  end
  return Tool.ticked(relative or value)
end

---Return a text field from a structured tool result.
---@param result any
---@return string
function Tool.result_text(result)
  if type(result) == "table" then
    return tostring(result.text or result.message or "")
  end
  return tostring(result or "")
end

---Return the first lines from a text value.
---@param text any
---@param max_lines integer
---@return string
function Tool.first_lines(text, max_lines)
  local lines = {}
  local count = 0
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    count = count + 1
    if #lines < max_lines then table.insert(lines, line) end
  end
  local output = table.concat(lines, "\n")
  if count > max_lines then
    output = output .. "\n... truncated after " .. tostring(max_lines) .. " lines ..."
  end
  return output
end

---Return a compact activity detail for a result.
---@param result any
---@return string|nil
function Tool.compact_result_detail(result)
  local text = Tool.result_text(result)
  if text == "" then return nil end
  if #text > 12000 then text = text:sub(1, 12000) .. "\n\n... truncated for transcript ..." end
  return Tool.fenced(text, "text")
end

---Clone a table recursively.
---@param value any
---@return any
function Tool.clone_table(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for key, item in pairs(value) do
    copy[key] = Tool.clone_table(item)
  end
  return copy
end

---Compact long text for provider context.
---@param text any
---@param limit integer|nil
---@return string
function Tool.compact_long_text(text, limit)
  text = tostring(text or "")
  limit = limit or Tool.RESULT_CONTENT_LIMIT
  if #text <= limit then return text end
  local omitted = #text - Tool.RESULT_HEAD_LIMIT - Tool.RESULT_TAIL_LIMIT
  if omitted < 0 then omitted = #text - limit end
  return table.concat({
    text:sub(1, Tool.RESULT_HEAD_LIMIT),
    "",
    string.format("... omitted %d bytes from prior tool result ...", math.max(0, omitted)),
    "",
    text:sub(-Tool.RESULT_TAIL_LIMIT)
  }, "\n")
end

---Compact large JSON argument string values.
---@param arguments string|nil
---@return string|nil
function Tool.compact_arguments(arguments)
  local ok, decoded = pcall(json.decode, arguments or "")
  if not ok then return arguments end
  if type(decoded) ~= "table" then return arguments end
  local changed = false
  local compacted = Tool.clone_table(decoded)
  local function visit(tbl)
    for key, value in pairs(tbl) do
      if type(value) == "table" then
        visit(value)
      elseif type(value) == "string" then
        local key_name = tostring(key)
        if Tool.LARGE_ARGUMENT_KEYS[key_name] or #value > Tool.ARGUMENT_STRING_LIMIT then
          tbl[key] = string.format("[omitted %d bytes from prior tool argument `%s`]", #value, key_name)
          changed = true
        end
      end
    end
  end
  visit(compacted)
  return changed and jsonutil.encode(compacted) or arguments
end

---Return whether a provider tool call already contains omitted arguments.
---@param call table
---@return boolean
function Tool.call_has_omitted_arguments(call)
  local fn = type(call) == "table" and type(call["function"]) == "table" and call["function"] or nil
  local arguments = fn and fn.arguments or type(call) == "table" and call.arguments or nil
  if type(arguments) ~= "string" then return false end
  local ok, decoded = pcall(json.decode, arguments)
  if not ok or type(decoded) ~= "table" then return false end
  return history_normalizer.contains_omitted_tool_argument(decoded)
end

---Compact one provider tool/function call.
---@param call table
---@return table
function Tool:compact_provider_call(call)
  local copy = Tool.clone_table(call)
  local fn = type(copy) == "table" and type(copy["function"]) == "table" and copy["function"] or nil
  if fn and type(fn.arguments) == "string" and not Tool.call_has_omitted_arguments(copy) then
    fn.arguments = Tool.compact_arguments(fn.arguments)
  elseif type(copy) == "table" and copy.type == "function_call"
    and type(copy.arguments) == "string"
    and not Tool.call_has_omitted_arguments(copy)
  then
    copy.arguments = Tool.compact_arguments(copy.arguments)
  end
  return copy
end

---Compact one provider tool result.
---@param _ table|nil
---@param result any
---@return string
function Tool:compact_result(_, result)
  return Tool.compact_long_text(result, Tool.RESULT_CONTENT_LIMIT)
end

---Return the default activity label for this tool.
---@param _ table|nil
---@param _ string|nil
---@param _ any
---@param _ table|nil
---@return string
function Tool:activity_label(_, _, _, _)
  return "Calling tool"
end

---Return the default verbose activity body for this tool.
---@param call table|nil
---@param status string|nil
---@param result any
---@param context table|nil
---@return string
function Tool:activity_markdown(call, status, result, context)
  local label = self.activity_label and self.activity_label(call, status, result, context)
    or Tool.activity_label(self, call, status, result, context)
  local lines = { label, "", "Tool: `" .. tostring(self.name or (call and call.name) or "unknown") .. "`" }
  local args = call and call.arguments or {}
  if type(args) == "table" then
    if args.cmd or args.command then table.insert(lines, "Command: `" .. tostring(args.cmd or args.command) .. "`") end
    if args.workdir or args.cwd then table.insert(lines, "Cwd: `" .. tostring(args.workdir or args.cwd) .. "`") end
    if args.path then table.insert(lines, "Path: " .. Tool.file_link_or_ticked(args.path, context)) end
    if args.directory then table.insert(lines, "Directory: " .. Tool.relative_path_or_ticked(args.directory, context)) end
    if args.url then table.insert(lines, "URL: `" .. tostring(args.url) .. "`") end
  end
  if status then table.insert(lines, "Status: " .. tostring(status)) end
  if result ~= nil and result ~= "" then
    table.insert(lines, "")
    table.insert(lines, Tool.compact_result_detail(result) or "")
  end
  return table.concat(lines, "\n")
end

---Return compact activity Markdown for this tool.
---@param _ table|nil
---@param status string|nil
---@param _ any
---@param _ table|nil
---@return string
function Tool:compact_activity_markdown(_, status, _, _)
  return "**Calling " .. tostring(self.name or "tool") .. "**:" .. Tool.status_suffix(status)
end

---Return whether a tool result represents a successful historical operation.
---@return boolean
function Tool:result_is_successful()
  return false
end

---Create a new instance.
---@param spec table
---@return assistant.Tool
function Tool:new(spec)
  spec = spec or {}
  if not spec.name or spec.name == "" then
    error("tool spec requires a name")
  end
  if not spec.callback and not spec.build then
    error("tool spec requires a callback or build function: " .. tostring(spec.name))
  end
  return setmetatable(spec, self)
end

---Handle registration.
---@param agent assistant.Agent
---@param facade table
---@return assistant.Tool.registration
function Tool:registration(agent, facade)
  local registration = self.build and self:build(agent, facade) or {}
  for key, value in pairs(self) do
    if key ~= "name" and key ~= "build" then
      registration[key] = value
    end
  end
  registration.name = registration.name or self.name
  registration.compact_result = registration.compact_result or function(call, result, context)
    return Tool.compact_result(registration, call, result, context)
  end
  registration.compact_provider_call = registration.compact_provider_call or function(call, context)
    return Tool.compact_provider_call(registration, call, context)
  end
  registration.activity_label = registration.activity_label or function(call, status, result, context)
    return Tool.activity_label(registration, call, status, result, context)
  end
  registration.activity_markdown = registration.activity_markdown or function(call, status, result, context)
    return Tool.activity_markdown(registration, call, status, result, context)
  end
  registration.compact_activity_markdown = registration.compact_activity_markdown or function(call, status, result, context)
    return Tool.compact_activity_markdown(registration, call, status, result, context)
  end
  registration.result_is_successful = registration.result_is_successful or function(call, result_message, context)
    return Tool.result_is_successful(registration, call, result_message, context)
  end
  return registration
end

---Handle register.
---@param agent assistant.Agent
---@param facade table
---@return any
function Tool:register(agent, facade)
  return agent:register_tool(self.name, self:registration(agent, facade))
end

return Tool
