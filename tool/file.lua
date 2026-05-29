local context = require "plugins.assistant.tool_context"
local Tool = require "plugins.assistant.tool"
local ImageView = require "core.imageview"
local json = require "core.json"
local common = require "core.common"

---Filesystem inspection and read-only project tools.
---@class assistant.tool.file
local filetools = {}

---Compact compact.
---@param label string
---@return fun(_: assistant.Tool, result: string): string
local function compact(label)
  return function(_, result)
    return context.compact_provider_text_result(result, label)
  end
end

---Read approval.
---@param key string
---@return fun(arguments: table): boolean
local function read_approval(key)
  return function(arguments)
    return context.read_path_requires_approval(arguments, key)
  end
end

---Return the latest user-visible prompt text for the active tool call.
---@return string|nil text
local function active_user_prompt()
  local conversation = context.active_conversation()
  if not (conversation and conversation.messages) then return nil end
  for index = #conversation.messages, 1, -1 do
    local message = conversation.messages[index]
    if message
      and message.role == "user"
      and not (message.meta and message.meta.provider_only)
      and type(message.message) == "string"
      and message.message ~= ""
    then
      return message.message
    end
  end
  return nil
end

---Return an exact replacement target from a natural-language user request.
---@param prompt string|nil
---@return string|nil target_text
local function exact_replacement_target(prompt)
  if type(prompt) ~= "string" then return nil end
  local patterns = {
    "[Ff]rom%s+`([^`]+)`%s+to%s+`([^`]+)`",
    "[Ff]rom%s+([^%s]+)%s+to%s+([^%s]+)"
  }
  for _, pattern in ipairs(patterns) do
    local old = prompt:match(pattern)
    if old and old ~= "" then return old end
  end
  return nil
end

---Return whether a search query is too broad for an exact replacement target.
---@param target_text string|nil Exact old value from the user prompt.
---@param query string|nil Search query requested by the model.
---@return boolean broad
local function broad_exact_replacement_query(target_text, query)
  if type(target_text) ~= "string" or type(query) ~= "string" then return false end
  target_text = target_text:match("^%s*(.-)%s*$") or ""
  query = query:match("^%s*(.-)%s*$") or ""
  if target_text == "" or query == "" or query == target_text then return false end
  if query:find(target_text, 1, true) then return false end
  local lower_target = target_text:lower()
  local lower_query = query:lower()
  if lower_query:find(lower_target, 1, true) then return false end
  if not lower_target:find(lower_query, 1, true) then return false end

  local basename = target_text:match("[/\\]([^/\\]+)$")
  if basename and lower_query == basename:lower() then return false end

  return true
end

---Return compact status suffix.
---@param status any
---@return string
local function status_suffix(value)
  return Tool.status_suffix(value)
end

---Return whether an activity is still waiting to run or actively running.
---@param value any
---@return boolean
local function pending_activity(value)
  return value == nil or value == "" or value == "requested" or value == "running"
end

---Return a compact target from common file arguments.
---@param call table|nil
---@return string
local function target(call)
  local args = call and call.arguments or {}
  return tostring(args.path or args.directory or args.text or args.pattern or "")
end

---Return a one-line compact file activity.
---@param label string
---@return fun(call: table|nil, status: string|nil): string
local function compact_file_activity(label)
  return function(call, status_value, _, activity_context)
    local args = call and call.arguments or {}
    local value = target(call)
    local rendered = args.directory
      and Tool.relative_path_or_ticked(value, activity_context, "target")
      or Tool.file_link_or_ticked(value, activity_context, "target")
    return "**" .. label .. "**: " .. rendered .. status_suffix(status_value)
  end
end

---Return compact mutation activity.
---@param call table|nil
---@param status_value string|nil
---@param result any
---@return string
local function compact_write_activity(call, status_value, result, activity_context)
  local args = call and call.arguments or {}
  local value = target(call)
  local exists = false
  local absolute = context.assert_project_path(args.path or value)
  if absolute then exists = system.get_file_info(absolute) ~= nil end
  local result_text = Tool.result_text(result)
  local pending = pending_activity(status_value)
  local label = (result_text:find("^created:", 1, false) or (pending and not exists))
    and "Adding"
    or "Writing"
  local line = "**" .. label .. "**: " .. Tool.file_link_or_ticked(value, activity_context, "file") .. status_suffix(status_value)
  if not pending then return line end
  local content = tostring(args.content or "")
  if content == "" then return line end
  local chunks = {}
  for text_line in (content:gsub("\r\n", "\n"):gsub("\r", "\n") .. "\n"):gmatch("(.-)\n") do
    table.insert(chunks, "+" .. text_line)
  end
  local diff = table.concat(chunks, "\n")
  if #diff > 12000 then diff = diff:sub(1, 12000) .. "\n\n... truncated for transcript ..." end
  return line .. "\n\n" .. Tool.fenced(diff, "diff")
end

---Return edits normalized to a list of replacement tables.
---@param args table
---@return table[]
local function edit_list(args)
  args = type(args) == "table" and args or {}
  local edits = args.edits
  if type(edits) ~= "table" and (args.oldText ~= nil or args.newText ~= nil) then
    edits = { { oldText = args.oldText, newText = args.newText } }
  elseif type(edits) == "table" and (edits.oldText or edits.newText) then
    edits = { edits }
  end
  return type(edits) == "table" and edits or {}
end

---Return a readable diff preview for exact edit replacements.
---@param args table
---@return string|nil
local function edit_diff(args)
  local function normalize(text)
    return tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  end
  local chunks = {}
  for index, edit in ipairs(edit_list(args)) do
    if type(edit) == "table" then
      if #chunks > 0 then table.insert(chunks, "") end
      table.insert(chunks, "@@ edit " .. tostring(index) .. " @@")
      for line in (normalize(edit.oldText) .. "\n"):gmatch("(.-)\n") do
        table.insert(chunks, "-" .. line)
      end
      for line in (normalize(edit.newText) .. "\n"):gmatch("(.-)\n") do
        table.insert(chunks, "+" .. line)
      end
    end
  end
  if #chunks == 0 then return nil end
  local text = table.concat(chunks, "\n")
  if #text > 12000 then text = text:sub(1, 12000) .. "\n\n... truncated for transcript ..." end
  return Tool.fenced(text, "diff")
end

---Return compact edit activity with replacement diff preview.
---@param call table|nil
---@param status_value string|nil
---@return string
local function compact_edit_activity(call, status_value, _, activity_context)
  local args = call and call.arguments or {}
  local value = target(call)
  local line = "**Editing**: " .. Tool.file_link_or_ticked(value, activity_context, "file") .. status_suffix(status_value)
  local diff = pending_activity(status_value) and edit_diff(args) or nil
  return diff and (line .. "\n\n" .. diff) or line
end

---Return verbose read activity with a small result preview.
---@param call table|nil
---@param status_value string|nil
---@param result any
---@return string
local function read_activity_markdown(call, status_value, result, activity_context)
  local args = call and call.arguments or {}
  local lines = {
    "Inspecting project",
    "",
    "Tool: `read`"
  }
  if args.path then table.insert(lines, "Path: " .. Tool.file_link_or_ticked(args.path, activity_context)) end
  if status_value then table.insert(lines, "Status: " .. tostring(status_value)) end
  local text = Tool.result_text(result)
  if text ~= "" then
    table.insert(lines, "")
    table.insert(lines, Tool.fenced(Tool.first_lines(text, 3), "text"))
  end
  return table.concat(lines, "\n")
end

---Return the provider tool call name.
---@param call table|nil
---@return string|nil
local function provider_call_name(call)
  local fn = type(call) == "table" and type(call["function"]) == "table" and call["function"] or nil
  return fn and fn.name or type(call) == "table" and call.name or nil
end

---Return the provider tool call id.
---@param call table|nil
---@return string
local function provider_call_id(call)
  return tostring(type(call) == "table" and (call.id or call.call_id) or "")
end

---Decode provider tool call arguments.
---@param call table|nil
---@return table
local function provider_call_arguments(call)
  if type(call) ~= "table" then return {} end
  local fn = type(call["function"]) == "table" and call["function"] or nil
  local arguments = fn and fn.arguments or call.arguments
  if type(arguments) == "table" then return arguments end
  if type(arguments) ~= "string" then return {} end
  local ok, decoded = pcall(json.decode, arguments)
  return ok and type(decoded) == "table" and decoded or {}
end

---Strip provider result boilerplate from a historical tool result.
---@param tool_name string
---@param text string
---@return string
local function unwrap_provider_result(tool_name, text)
  text = tostring(text or "")
  local prefix = "Tool `" .. tostring(tool_name or "") .. "` result:\n"
  if text:sub(1, #prefix) == prefix then
    text = text:sub(#prefix + 1)
  end
  local suffix = "\n\nUse this result to answer the user."
  local at = text:find(suffix, 1, true)
  if at then text = text:sub(1, at - 1) end
  return text
end

---Return whether a historical file inspection result was successful enough to summarize.
---@param call table|nil
---@param result_message table|string
---@return boolean
local function inspection_result_is_successful(call, result_message)
  local name = provider_call_name(call)
  if name ~= "read" and name ~= "search" and name ~= "list" and name ~= "file_info" then
    return false
  end
  local content = type(result_message) == "table"
    and (result_message.content or result_message.output)
    or result_message
  content = tostring(content or "")
  if content:find("Tool `" .. name .. "` result:", 1, true) ~= 1 then return false end
  local body = unwrap_provider_result(name, content)
  local lower = body:lower()
  return not (
    lower:find("^tool error:", 1, false)
    or lower:find("^user denied", 1, false)
    or lower:find("^missing path", 1, false)
    or lower:find("^path is outside", 1, false)
    or lower:find("^not a directory:", 1, false)
    or lower:find("^not found:", 1, false)
    or lower:find("^repeated tool call skipped", 1, false)
    or lower:find("^repeated tool call loop detected", 1, false)
    or lower:find("^repeated tool call suppressed", 1, false)
  )
end

---Return a project-relative path for compact history summaries.
---@param value any
---@param compact_context table|nil
---@return string
local function compact_path(value, compact_context)
  value = tostring(value or "")
  if value == "" then return "(unknown)" end
  local project_dir = compact_context and compact_context.project_dir
  local absolute = value
  if project_dir and project_dir ~= "" and not common.is_absolute_path(value) then
    absolute = project_dir .. PATHSEP .. value
  end
  absolute = common.normalize_path(absolute) or absolute
  if project_dir and project_dir ~= "" then
    project_dir = common.normalize_path(project_dir) or project_dir
    if absolute == project_dir then return common.basename(project_dir) end
    if common.path_belongs_to(absolute, project_dir) then
      return common.relative_path(project_dir, absolute)
    end
  end
  local relative = context.project_relative(absolute)
  return relative ~= "" and relative or value
end

---Return up to max_lines lines from text.
---@param text string
---@param max_lines integer
---@return string[]
---@return integer count
local function limited_lines(text, max_lines)
  local lines = {}
  local count = 0
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    count = count + 1
    if #lines < max_lines then table.insert(lines, line) end
  end
  return lines, count
end

---Return a concise read history line plus preview.
---@param args table
---@param result string
---@param compact_context table|nil
---@return string[]
local function compact_read_history(args, result, compact_context)
  local path = compact_path(args.path, compact_context)
  local lines, total = limited_lines(result, 12)
  local output = {
    string.format(
      "- read `%s`%s%s: %d bytes, hash %s",
      path,
      args.offset and (" from line " .. tostring(args.offset)) or "",
      args.limit and (" limit " .. tostring(args.limit)) or "",
      #result,
      context.hash_text(result)
    )
  }
  if #lines > 0 then
    table.insert(output, "  preview:")
    for _, line in ipairs(lines) do
      table.insert(output, "    " .. line)
    end
    if total > #lines then
      table.insert(output, "    ... truncated preview ...")
    end
  end
  return output
end

---Return a concise search history line plus representative matches.
---@param args table
---@param result string
---@param compact_context table|nil
---@return string[]
local function compact_search_history(args, result, compact_context)
  local original_query, narrowed_query = result:match("^Search query `([^`]+)` was narrowed to the exact old value `([^`]+)`")
  local summarized_result = result
  if narrowed_query then
    summarized_result = summarized_result:gsub("^.-\n", "", 1)
  end
  local matches, total = limited_lines(summarized_result, 8)
  local files = {}
  local seen = {}
  for line in (summarized_result .. "\n"):gmatch("(.-)\n") do
    local file = line:match("^(.-):%d+:")
    if file and not seen[file] then
      seen[file] = true
      table.insert(files, compact_path(file, compact_context))
    end
    if #files >= 12 then break end
  end
  local output = {
    narrowed_query
      and string.format(
        "- narrowed search in `%s` from `%s` to exact old value `%s` (%s): %d match line(s)",
        compact_path(args.directory, compact_context),
        tostring(original_query or args.text or ""),
        tostring(narrowed_query),
        tostring(args.search_type or "plain"),
        summarized_result:find("^No results", 1, false) and 0 or total
      )
      or string.format(
        "- searched `%s` for `%s` (%s): %d match line(s)",
        compact_path(args.directory, compact_context),
        tostring(args.text or ""),
        tostring(args.search_type or "plain"),
        result == "No results." and 0 or total
      )
  }
  if #files > 0 then
    table.insert(output, "  files: " .. table.concat(files, ", "))
  end
  if #matches > 0 and result ~= "No results." and not summarized_result:find("^No results", 1, false) then
    table.insert(output, "  first matches:")
    for _, line in ipairs(matches) do
      local file, rest = line:match("^(.-)(:%d+:.*)$")
      if file and rest then
        line = compact_path(file, compact_context) .. rest
      end
      table.insert(output, "    " .. line)
    end
  end
  return output
end

---Return a concise list history line plus representative entries.
---@param args table
---@param result string
---@param compact_context table|nil
---@return string[]
local function compact_list_history(args, result, compact_context)
  local entries, total = limited_lines(result, 20)
  local output = {
    string.format(
      "- listed `%s`%s%s: %d entr%s",
      compact_path(args.directory, compact_context),
      args.recursive and " recursively" or "",
      args.pattern and (" filtered by `" .. tostring(args.pattern) .. "`") or "",
      result == "No files." and 0 or total,
      total == 1 and "y" or "ies"
    )
  }
  if #entries > 0 and result ~= "No files." then
    table.insert(output, "  first entries:")
    for _, line in ipairs(entries) do
      table.insert(output, "    " .. compact_path(line, compact_context))
    end
  end
  return output
end

---Return a concise file_info history line.
---@param args table
---@param result string
---@param compact_context table|nil
---@return string[]
local function compact_file_info_history(args, result, compact_context)
  local lines = { "- inspected metadata for `" .. compact_path(args.path, compact_context) .. "`:" }
  for _, line in ipairs((limited_lines(result, 6))) do
    table.insert(lines, "  " .. line)
  end
  return lines
end

---Return markdown language for file context snapshots.
---@param path string|nil
---@return string
local function code_fence_language(path)
  local name = tostring(path or ""):match("[^/\\]+$") or ""
  local ext = name:match("%.([^%.]+)$")
  if name == "Makefile" or name:match("^Makefile%.") then return "make" end
  if ext == "c" or ext == "h" then return "c" end
  if ext == "lua" then return "lua" end
  if ext == "md" or ext == "markdown" then return "markdown" end
  if ext == "json" then return "json" end
  if ext == "yml" or ext == "yaml" then return "yaml" end
  if ext == "sh" then return "sh" end
  return ""
end

---Resolve a project file path for provider snapshots.
---@param compact_context table|nil
---@param path string|nil
---@return string|nil absolute
---@return string|nil relative
local function project_file_path(compact_context, path)
  path = tostring(path or "")
  if path == "" then return nil end
  local project_dir = compact_context and compact_context.project_dir
  if not project_dir or project_dir == "" then return nil end
  local root = common.normalize_path(project_dir) or project_dir
  local absolute = path
  if not common.is_absolute_path(absolute) then
    absolute = root .. PATHSEP .. absolute
  end
  absolute = common.normalize_path(absolute) or absolute
  if absolute ~= root and not common.path_belongs_to(absolute, root) then return nil end
  return absolute, common.relative_path(root, absolute)
end

---Read current file text for a provider snapshot.
---@param path string|nil
---@return string|nil
local function read_snapshot_file(path)
  local info = path and system.get_file_info(path)
  if not info or info.type ~= "file" then return nil end
  if ImageView.is_supported(path) then return nil end
  local text = context.read_file(path)
  return type(text) == "string" and text or nil
end

---Build assistant messages for compacted read snapshots.
---@param records table[]
---@return table[]|nil messages
local function build_read_snapshot_messages(records)
  if #records == 0 then return nil end
  local parts = {
    "# Current File Context",
    "",
    "Historical read tool calls were omitted from provider history. The current file contents below are the available file context. Use this content for reasoning and edits; do not re-read these files unless the user asks for fresh data or an edit fails because the file changed."
  }
  for _, record in ipairs(records) do
    table.insert(parts, "")
    table.insert(parts, "Read File: " .. record.relative)
    if record.content ~= nil then
      table.insert(parts, "```" .. code_fence_language(record.relative))
      table.insert(parts, record.content)
      table.insert(parts, "```")
    else
      table.insert(parts, "Current file content could not be read as text.")
    end
  end
  return {
    {
      role = "assistant",
      content = table.concat(parts, "\n")
    }
  }
end

---Build assistant messages for compacted non-read inspections.
---@param entries string[][]
---@return table[]|nil messages
local function build_inspection_summary_messages(entries)
  if #entries == 0 then return nil end
  local lines = {
    "# Completed File Inspections",
    "",
    "Historical search/list/metadata tool calls were omitted from provider history. These inspections already completed."
  }
  for _, entry in ipairs(entries) do
    table.insert(lines, "")
    for _, line in ipairs(entry) do table.insert(lines, line) end
  end
  return {
    {
      role = "assistant",
      content = table.concat(lines, "\n")
    }
  }
end

---Return whether a historical file mutation result was successful.
---@param call table|nil
---@param result_message table|string
---@return boolean
local function mutation_result_is_successful(call, result_message)
  local name = provider_call_name(call)
  if name ~= "write" and name ~= "edit" then return false end
  local content = type(result_message) == "table"
    and (result_message.content or result_message.output)
    or result_message
  content = tostring(content or "")
  if content:find("Tool `" .. name .. "` result:", 1, true) ~= 1 then return false end
  local body = unwrap_provider_result(name, content)
  local lower = body:lower()
  if lower:find("^tool error:", 1, false)
    or lower:find("^user denied", 1, false)
    or lower:find("^refusing ", 1, false)
    or lower:find("^could not ", 1, false)
  then
    return false
  end
  if name == "edit" then
    return body:find("^Successfully replaced %d+ block%(s%)", 1, false) ~= nil
  end
  return body:find("^created:", 1, false) ~= nil or body:find("^replaced:", 1, false) ~= nil
end

---Return a mutation label from the provider call and result.
---@param name string
---@param result string
---@return string
local function mutation_label(name, result)
  result = tostring(result or "")
  if name == "write" then
    if result:find("^created:", 1, false) then return "Added File" end
    return "Written File"
  end
  return "Edited File"
end

---Build assistant messages for compacted historical file mutations.
---@param records table[]
---@return table[]|nil messages
local function build_mutation_snapshot_messages(records)
  if #records == 0 then return nil end
  local parts = {
    "# Already Applied Changes",
    "",
    "Historical file edit/write tool calls were omitted from provider history; these file operations already happened.",
    "Use the current file content below instead of historical edit arguments or oldText values. Files listed below already exist. Do not recreate them; read them first and use edit for targeted changes only if they still need changes."
  }
  for _, record in ipairs(records) do
    table.insert(parts, "")
    table.insert(parts, record.label .. ": " .. record.relative)
    if record.content ~= nil then
      table.insert(parts, "```" .. code_fence_language(record.relative))
      table.insert(parts, record.content)
      table.insert(parts, "```")
    else
      table.insert(parts, "Current file content is already included in the current file context or could not be read as text.")
    end
  end
  return {
    {
      role = "assistant",
      content = table.concat(parts, "\n")
    }
  }
end

---Compact historical file mutation calls into current file snapshots.
---@param message table
---@param compact_context table|nil
---@param included_ids table<string, boolean>|nil
---@param result_texts table<string, string>|nil
---@return table[]|nil messages
local function compact_mutation_history(message, compact_context, included_ids, result_texts)
  if type(message) ~= "table" or type(message.tool_calls) ~= "table" then return nil end
  compact_context = compact_context or {}
  compact_context.file_read_snapshots = compact_context.file_read_snapshots or {}
  compact_context.file_mutation_snapshots = compact_context.file_mutation_snapshots or {}
  local records = {}
  for _, call in ipairs(message.tool_calls) do
    local id = provider_call_id(call)
    local name = provider_call_name(call)
    if id ~= "" and included_ids and included_ids[id] and (name == "write" or name == "edit")
      and mutation_result_is_successful(call, { content = result_texts and result_texts[id] or "" })
    then
      local args = provider_call_arguments(call)
      local absolute, relative = project_file_path(compact_context, args.path)
      if relative and not compact_context.file_mutation_snapshots[relative] then
        compact_context.file_mutation_snapshots[relative] = true
        local content = read_snapshot_file(absolute)
        compact_context.file_read_snapshots[relative] = true
        table.insert(records, {
          relative = relative,
          label = mutation_label(name, unwrap_provider_result(name, result_texts and result_texts[id] or "")),
          content = content
        })
      end
    end
  end
  return build_mutation_snapshot_messages(records)
end

---Compact historical file inspection calls into assistant-readable summaries.
---@param message table
---@param _ table|nil
---@param included_ids table<string, boolean>|nil
---@param result_texts table<string, string>|nil
---@return table[]|nil messages
local function compact_inspection_history(message, compact_context, included_ids, result_texts)
  if type(message) ~= "table" or type(message.tool_calls) ~= "table" then return nil end
  compact_context = compact_context or {}
  compact_context.file_read_snapshots = compact_context.file_read_snapshots or {}
  compact_context.file_inspection_summaries = compact_context.file_inspection_summaries or {}
  local read_records = {}
  local summary_entries = {}
  for _, call in ipairs(message.tool_calls) do
    local id = provider_call_id(call)
    local name = provider_call_name(call)
    if id ~= "" and included_ids and included_ids[id]
      and (name == "read" or name == "search" or name == "list" or name == "file_info")
      and inspection_result_is_successful(call, { content = result_texts and result_texts[id] or "" })
    then
      local args = provider_call_arguments(call)
      local result = unwrap_provider_result(name, result_texts and result_texts[id] or "")
      if name == "read" then
        local absolute, relative = project_file_path(compact_context, args.path)
        if relative and not compact_context.file_read_snapshots[relative] then
          compact_context.file_read_snapshots[relative] = true
          table.insert(read_records, {
            relative = relative,
            content = read_snapshot_file(absolute)
          })
        end
      elseif name == "search" then
        local key = name .. "\0" .. tostring(args.directory or "") .. "\0" .. tostring(args.text or "") .. "\0" .. tostring(args.search_type or "")
        if not compact_context.file_inspection_summaries[key] then
          compact_context.file_inspection_summaries[key] = true
          table.insert(summary_entries, compact_search_history(args, result, compact_context))
        end
      elseif name == "list" then
        local key = name .. "\0" .. tostring(args.directory or "") .. "\0" .. tostring(args.recursive or "") .. "\0" .. tostring(args.pattern or "")
        if not compact_context.file_inspection_summaries[key] then
          compact_context.file_inspection_summaries[key] = true
          table.insert(summary_entries, compact_list_history(args, result, compact_context))
        end
      elseif name == "file_info" then
        local key = name .. "\0" .. tostring(args.path or "")
        if not compact_context.file_inspection_summaries[key] then
          compact_context.file_inspection_summaries[key] = true
          table.insert(summary_entries, compact_file_info_history(args, result, compact_context))
        end
      end
    end
  end
  local messages = {}
  for _, snapshot in ipairs(build_read_snapshot_messages(read_records) or {}) do
    table.insert(messages, snapshot)
  end
  for _, summary in ipairs(build_inspection_summary_messages(summary_entries) or {}) do
    table.insert(messages, summary)
  end
  return #messages > 0 and messages or nil
end

local READ_MAX_LINES = 2000
local READ_MAX_BYTES = 50 * 1024
local IMAGE_MAX_DIMENSION = 1024

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

---Base64 encode binary data.
---@param data string
---@return string
local function base64_encode(data)
  data = tostring(data or "")
  local out = {}
  for i = 1, #data, 3 do
    local a = data:byte(i) or 0
    local b = data:byte(i + 1) or 0
    local c = data:byte(i + 2) or 0
    local triple = a * 65536 + b * 256 + c
    out[#out + 1] = BASE64_ALPHABET:sub(math.floor(triple / 262144) % 64 + 1, math.floor(triple / 262144) % 64 + 1)
    out[#out + 1] = BASE64_ALPHABET:sub(math.floor(triple / 4096) % 64 + 1, math.floor(triple / 4096) % 64 + 1)
    out[#out + 1] = i + 1 <= #data
      and BASE64_ALPHABET:sub(math.floor(triple / 64) % 64 + 1, math.floor(triple / 64) % 64 + 1)
      or "="
    out[#out + 1] = i + 2 <= #data
      and BASE64_ALPHABET:sub(triple % 64 + 1, triple % 64 + 1)
      or "="
    if i % (3 * 4096) == 1 then context.yield_ui() end
  end
  context.yield_ui()
  return table.concat(out)
end

---Return text field from a structured tool result.
---@param result any
---@return string
local function result_text(result)
  if type(result) == "table" then return tostring(result.text or result.message or "") end
  return tostring(result or "")
end

local function detect_line_ending(text)
  local crlf = text:find("\r\n", 1, true)
  local lf = text:find("\n", 1, true)
  if not lf then return "\n" end
  if crlf and crlf <= lf then return "\r\n" end
  return "\n"
end

local function normalize_to_lf(text)
  return tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
end

local function restore_line_endings(text, ending)
  text = tostring(text or "")
  if ending == "\r\n" then return text:gsub("\n", "\r\n") end
  return text
end

local function strip_bom(text)
  text = tostring(text or "")
  if text:sub(1, 3) == "\239\187\191" then
    return "\239\187\191", text:sub(4)
  end
  return "", text
end

local FUZZY_REPLACEMENTS = {
  ["\226\128\152"] = "'",
  ["\226\128\153"] = "'",
  ["\226\128\156"] = '"',
  ["\226\128\157"] = '"',
  ["\226\128\147"] = "-",
  ["\226\128\148"] = "-",
  ["\194\160"] = " "
}

local function next_utf8_char(text, index)
  local utf8api = _G.utf8extra
  local pattern = utf8api and utf8api.charpattern
  if pattern then
    local char = text:sub(index):match("^" .. pattern)
    if char and char ~= "" then return index + #char, char end
  end
  return index + 1, text:sub(index, index)
end

local function append_fuzzy_char(out, map, text, index)
  local next_index, char = next_utf8_char(text, index)
  table.insert(out, FUZZY_REPLACEMENTS[char] or char)
  if map then table.insert(map, { start = index, finish = next_index - 1 }) end
  return next_index
end

local function normalize_for_fuzzy_match(text, with_map)
  text = normalize_to_lf(text)
  local out = {}
  local map = with_map and {} or nil
  local line_start = 1
  local line_count = 0
  while line_start <= #text do
    local newline = text:find("\n", line_start, true)
    local line_finish = newline and (newline - 1) or #text
    local line = text:sub(line_start, line_finish)
    local trimmed = line:gsub("%s+$", "")
    local limit = line_start + #trimmed - 1
    local index = line_start
    while index <= limit do
      if with_map then
        index = append_fuzzy_char(out, map, text, index)
      else
        index = append_fuzzy_char(out, nil, text, index)
      end
    end
    if newline and newline < #text then
      table.insert(out, "\n")
      if with_map then table.insert(map, { start = newline, finish = newline }) end
    end
    line_count = line_count + 1
    if line_count % 200 == 0 then context.yield_ui() end
    if not newline then break end
    line_start = newline + 1
  end
  return table.concat(out), map
end

local function fuzzy_original_range(map, index, length)
  local first = map and map[index]
  local last = map and map[index + length - 1]
  if not first or not last then return nil end
  return first.start, last.finish - first.start + 1
end

local function count_occurrences(text, needle)
  if needle == "" then return 0 end
  local count = 0
  local index = 1
  local steps = 0
  while true do
    local found = text:find(needle, index, true)
    if not found then break end
    count = count + 1
    index = found + #needle
    steps = steps + 1
    if steps % 200 == 0 then context.yield_ui() end
  end
  return count
end

local function find_edit_match(content, old_text)
  local index = content:find(old_text, 1, true)
  if index then
    return {
      content = content,
      index = index,
      length = #old_text,
      occurrences = count_occurrences(content, old_text)
    }
  end
  local fuzzy_content, fuzzy_map = normalize_for_fuzzy_match(content, true)
  local fuzzy_old = normalize_for_fuzzy_match(old_text)
  index = fuzzy_content:find(fuzzy_old, 1, true)
  if not index then return nil end
  local original_index, original_length = fuzzy_original_range(fuzzy_map, index, #fuzzy_old)
  if not original_index then return nil end
  return {
    content = content,
    index = original_index,
    length = original_length,
    occurrences = count_occurrences(fuzzy_content, fuzzy_old)
  }
end

local function unified_diff(path, old_text, new_text)
  if old_text == new_text then return "" end
  local old_lines = context.split_lines(normalize_to_lf(old_text))
  local new_lines = context.split_lines(normalize_to_lf(new_text))
  local prefix = 1
  while prefix <= #old_lines and prefix <= #new_lines and old_lines[prefix] == new_lines[prefix] do
    prefix = prefix + 1
    if prefix % 200 == 0 then context.yield_ui() end
  end
  local old_suffix = #old_lines
  local new_suffix = #new_lines
  local suffix_steps = 0
  while old_suffix >= prefix and new_suffix >= prefix and old_lines[old_suffix] == new_lines[new_suffix] do
    old_suffix = old_suffix - 1
    new_suffix = new_suffix - 1
    suffix_steps = suffix_steps + 1
    if suffix_steps % 200 == 0 then context.yield_ui() end
  end
  local context_before = math.max(1, prefix - 3)
  local context_after_old = math.min(#old_lines, old_suffix + 3)
  local context_after_new = math.min(#new_lines, new_suffix + 3)
  local old_count = math.max(0, context_after_old - context_before + 1)
  local new_count = math.max(0, context_after_new - context_before + 1)
  local out = {
    "--- " .. path,
    "+++ " .. path,
    string.format("@@ -%d,%d +%d,%d @@", context_before, old_count, context_before, new_count)
  }
  local before_end = math.min(prefix - 1, context_after_old, context_after_new)
  for index = context_before, before_end do
    table.insert(out, " " .. (old_lines[index] or ""))
    if index % 200 == 0 then context.yield_ui() end
  end
  for index = prefix, old_suffix do
    table.insert(out, "-" .. (old_lines[index] or ""))
    if index % 200 == 0 then context.yield_ui() end
  end
  for index = prefix, new_suffix do
    table.insert(out, "+" .. (new_lines[index] or ""))
    if index % 200 == 0 then context.yield_ui() end
  end
  local after_start = math.max(old_suffix + 1, new_suffix + 1, prefix)
  local after_end = math.min(context_after_old, context_after_new)
  for index = after_start, after_end do
    table.insert(out, " " .. (old_lines[index] or new_lines[index] or ""))
    if index % 200 == 0 then context.yield_ui() end
  end
  return table.concat(out, "\n")
end

local function truncate_read_output(text, start_line, total_lines, user_limit)
  local lines = context.split_lines(text)
  local out = {}
  local bytes = 0
  local truncated = false
  local max_lines = user_limit or READ_MAX_LINES
  for index, line in ipairs(lines) do
    local line_bytes = #line + (index > 1 and 1 or 0)
    if #out >= max_lines or bytes + line_bytes > READ_MAX_BYTES then
      truncated = true
      break
    end
    table.insert(out, line)
    bytes = bytes + line_bytes
    if index % 200 == 0 then context.yield_ui() end
  end
  local output = table.concat(out, "\n")
  if text:sub(-1) == "\n" and not truncated then output = output .. "\n" end
  local end_line = start_line + #out - 1
  if truncated or start_line + #out - 1 < total_lines then
    local next_offset = math.max(start_line, end_line + 1)
    output = output .. string.format(
      "\n\n[Showing lines %d-%d of %d. Use offset=%d to continue.]",
      start_line,
      math.max(start_line, end_line),
      total_lines,
      next_offset
    )
  end
  return output
end

---Return scaled image dimensions within the configured maximum.
---@param width integer
---@param height integer
---@return integer width
---@return integer height
local function scaled_image_size(width, height)
  width = tonumber(width) or 0
  height = tonumber(height) or 0
  local max_dimension = math.max(width, height)
  if max_dimension <= IMAGE_MAX_DIMENSION then return width, height end
  local scale = IMAGE_MAX_DIMENSION / max_dimension
  return math.max(1, math.floor(width * scale + 0.5)), math.max(1, math.floor(height * scale + 0.5))
end

---Read an image file and return provider-ready attachment metadata.
---@param absolute string
---@return table|string result
local function read_image_file(absolute)
  local image, load_err = canvas.load_image(absolute)
  if not image then
    return "Could not read image file " .. absolute .. ": " .. tostring(load_err or "image load failed")
  end
  context.yield_ui()
  local original_width, original_height = image:get_size()
  local sent_width, sent_height = scaled_image_size(original_width, original_height)
  local normalized = image
  if sent_width ~= original_width or sent_height ~= original_height then
    normalized = image:scaled(sent_width, sent_height, "nearest")
    context.yield_ui()
  end
  local temp_path = string.format(
    "%s%sassistant-read-image-%08x.png",
    os.getenv("TMPDIR") or "/tmp",
    PATHSEP,
    math.random(0, 0xffffffff)
  )
  local saved, save_err = normalized:save_image(temp_path)
  if not saved then
    return "Could not normalize image file " .. absolute .. ": " .. tostring(save_err or "image save failed")
  end
  local png_data, read_err = context.read_file(temp_path)
  os.remove(temp_path)
  if not png_data then
    return "Could not read normalized image file " .. absolute .. ": " .. tostring(read_err or "temporary image read failed")
  end
  local encoded = base64_encode(png_data)
  local text = string.format(
    "Read image file %s [image/png] original %dx%d, sent %dx%d.",
    absolute,
    original_width,
    original_height,
    sent_width,
    sent_height
  )
  return {
    text = text,
    attachments = {
      {
        type = "image",
        mime_type = "image/png",
        data = encoded,
        path = absolute,
        original_width = original_width,
        original_height = original_height,
        width = sent_width,
        height = sent_height
      }
    }
  }
end

---Handle matches.
---@param line string
---@param text string
---@param search_type "plain"|"regex"|"luapattern"|string
---@return boolean
local function matches(line, text, search_type)
  if search_type == "regex" and regex then
    return regex.match(text, line) ~= nil
  elseif search_type == "luapattern" then
    return line:find(text) ~= nil
  end
  return line:find(text, 1, true) ~= nil
end

---Handle scan file.
---@param path string
---@param text string
---@param search_type string
---@param out string[]
---@return boolean?
local function scan_file(path, text, search_type, out)
  local data = context.read_file(path)
  if not data then return end
  if context.looks_binary(data) then return true end
  local line_no = 1
  for line in (data .. "\n"):gmatch("(.-)\n") do
    if matches(line, text, search_type) then
      local limited_line = context.limit_text(line, 2000)
      table.insert(out, string.format("%s:%d:%s", path, line_no, limited_line))
      if #out >= 200 then return false end
    end
    line_no = line_no + 1
    if line_no % 200 == 0 then context.yield_ui() end
  end
  return true
end

---Handle scan dir.
---@param path string
---@param text string
---@param search_type string
---@param out string[]
---@param state table?
---@return boolean
local function scan_dir(path, text, search_type, out, state)
  state = state or { count = 0 }
  for _, name in ipairs(system.list_dir(path) or {}) do
    if name ~= ".git" and name ~= ".pragtical" then
      local child = path .. PATHSEP .. name
      local info = system.get_file_info(child)
      state.count = state.count + 1
      if state.count % 50 == 0 then context.yield_ui() end
      if info and info.type == "dir" then
        if scan_dir(child, text, search_type, out, state) == false then return false end
      elseif info and info.type == "file" then
        if scan_file(child, text, search_type, out) == false then return false end
      end
    end
  end
  return true
end

local threaded_file_tool_id = 0

local function next_threaded_file_tool_id()
  threaded_file_tool_id = threaded_file_tool_id + 1
  return threaded_file_tool_id
end

local function thread_available()
  return type(thread) == "table"
    and type(thread.create) == "function"
    and type(thread.get_channel) == "function"
end

local function threaded_search_coordinator(tool_id, root, text, search_type, pathsep, workers, max_results)
  local function worker_find_in_file(tool_id, worker_id, text, search_type, max_results)
    local jobs = thread.get_channel("assistant_search_jobs_" .. tool_id .. "_" .. worker_id)
    local results = thread.get_channel("assistant_search_results_" .. tool_id .. "_" .. worker_id)
    local stop = thread.get_channel("assistant_search_stop_" .. tool_id)

    local function line_matches(line)
      if search_type == "regex" and regex then
        return regex.match(text, line) ~= nil
      elseif search_type == "luapattern" then
        return line:find(text) ~= nil
      end
      return line:find(text, 1, true) ~= nil
    end

    local function looks_binary(data)
      if type(data) ~= "string" then return false end
      if data:find("%z") then return true end
      local limit = math.min(#data, 8192)
      if limit == 0 then return false end
      local controls = 0
      for i = 1, limit do
        local byte = data:byte(i)
        if byte < 0x20 and byte ~= 0x09 and byte ~= 0x0a and byte ~= 0x0c and byte ~= 0x0d then
          controls = controls + 1
        end
      end
      return controls / limit > 0.05
    end

    local path = jobs:wait()
    while path ~= "{{stop}}" do
      if stop:first() == "stop" then break end
      local out = {}
      local handle = io.open(path, "rb")
      if handle then
        local data = handle:read("*a")
        handle:close()
        if data and not looks_binary(data) then
          local line_no = 1
          for line in (data .. "\n"):gmatch("(.-)\n") do
            if line_matches(line) then
              local limited_line = line
              if #limited_line > 2000 then
                limited_line = limited_line:sub(1, 2000) .. "...[truncated]"
              end
              table.insert(out, string.format("%s:%d:%s", path, line_no, limited_line))
              if #out >= max_results then break end
            end
            line_no = line_no + 1
          end
        end
      end
      results:push(#out > 0 and out or true)
      jobs:pop()
      path = jobs:wait()
    end
    results:push("finished")
  end

  local status = thread.get_channel("assistant_search_status_" .. tool_id)
  local stop = thread.get_channel("assistant_search_stop_" .. tool_id)
  local jobs = {}
  local worker_threads = {}
  for worker_id = 1, workers do
    jobs[worker_id] = thread.get_channel("assistant_search_jobs_" .. tool_id .. "_" .. worker_id)
    worker_threads[worker_id] = thread.create(
      "assearchw" .. tool_id .. "_" .. worker_id,
      worker_find_in_file,
      tool_id,
      worker_id,
      text,
      search_type,
      max_results
    )
  end

  local directories = { root }
  local current_worker = 1
  local scanned = 0
  while #directories > 0 and stop:first() ~= "stop" do
    local directory = table.remove(directories, 1)
    for _, name in ipairs(system.list_dir(directory) or {}) do
      if name ~= ".git" and name ~= ".pragtical" then
        local child = directory .. pathsep .. name
        local info = system.get_file_info(child)
        scanned = scanned + 1
        if info and info.type == "dir" then
          table.insert(directories, child)
        elseif info and info.type == "file" then
          jobs[current_worker]:push(child)
          current_worker = current_worker + 1
          if current_worker > workers then current_worker = 1 end
        end
      end
    end
    if scanned % 200 == 0 then
      status:clear()
      status:push(scanned)
    end
  end

  for worker_id = 1, workers do
    jobs[worker_id]:push("{{stop}}")
  end
  for _, worker in ipairs(worker_threads) do
    if worker then worker:wait() end
  end
  status:clear()
  status:push("finished")
end

local function drain_threaded_search_results(tool_id, workers, out, max_results)
  if #out >= max_results then return false, true end
  local found = false
  for worker_id = 1, workers do
    local channel = thread.get_channel("assistant_search_results_" .. tool_id .. "_" .. worker_id)
    local value = channel:first()
    while value do
      channel:pop()
      if type(value) == "table" then
        for _, line in ipairs(value) do
          if #out >= max_results then return true, true end
          table.insert(out, line)
          if #out >= max_results then return true, true end
        end
      end
      found = true
      value = channel:first()
    end
  end
  return found, false
end

local function threaded_scan_dir(path, text, search_type, out)
  if not thread_available() then return scan_dir(path, text, search_type, out) end
  local tool_id = next_threaded_file_tool_id()
  local workers = math.max(1, math.min(8, math.ceil((thread.get_cpu_count() or 2) / 2)))
  local max_results = 200
  local coordinator = thread.create(
    "assearch" .. tool_id,
    threaded_search_coordinator,
    tool_id,
    path,
    text,
    search_type,
    PATHSEP,
    workers,
    max_results
  )
  if not coordinator then return scan_dir(path, text, search_type, out) end
  local status = thread.get_channel("assistant_search_status_" .. tool_id)
  local stop = thread.get_channel("assistant_search_stop_" .. tool_id)
  local done = false
  while not done do
    local _, full = drain_threaded_search_results(tool_id, workers, out, max_results)
    if full then
      stop:push("stop")
      done = true
    end
    local value = status:first()
    if value == "finished" then
      status:pop()
      done = true
    elseif value ~= nil then
      status:pop()
    end
    context.yield_ui()
  end
  while drain_threaded_search_results(tool_id, workers, out, max_results) do
    context.yield_ui()
  end
  coordinator:wait()
  stop:clear()
  return #out < max_results
end

---List dir.
---@param path string
---@param recursive boolean
---@param pattern string?
---@param out string[]
---@param state table?
---@return boolean
local function list_dir(path, recursive, pattern, out, state)
  state = state or { count = 0, max = 500, bytes = 0, output_limit = context.OUTPUT_LIMIT }
  context.yield_ui()
  local names = system.list_dir(path) or {}
  context.yield_ui()
  for _, name in ipairs(names) do
    if name ~= ".git" and name ~= ".pragtical" then
      local child = path .. PATHSEP .. name
      local info = system.get_file_info(child)
      state.count = state.count + 1
      if state.count % 20 == 0 then context.yield_ui() end
      if not pattern or child:find(pattern, 1, true) or name:find(pattern, 1, true) then
        table.insert(out, child)
        state.bytes = (state.bytes or 0) + #child + 1
        if #out >= state.max then return false end
        if state.bytes >= (state.output_limit or context.OUTPUT_LIMIT) then
          state.truncated = "output limit"
          return false
        end
      end
      if recursive and info and info.type == "dir" then
        if list_dir(child, recursive, pattern, out, state) == false then return false end
      end
    end
  end
  return true
end

local function threaded_list_worker(tool_id, root, recursive, pattern, max_results, output_limit, pathsep)
  if pattern == false then pattern = nil end
  local output = thread.get_channel("assistant_list_results_" .. tool_id)
  local directories = { root }
  local count = 0
  local bytes = 0
  local batch = {}
  while #directories > 0 do
    local directory = table.remove(directories, 1)
    for _, name in ipairs(system.list_dir(directory) or {}) do
      if name ~= ".git" and name ~= ".pragtical" then
        local child = directory .. pathsep .. name
        local info = system.get_file_info(child)
        if not pattern or child:find(pattern, 1, true) or name:find(pattern, 1, true) then
          table.insert(batch, child)
          count = count + 1
          bytes = bytes + #child + 1
          if #batch >= 200 then
            output:push(batch)
            batch = {}
          end
          if count >= max_results or bytes >= output_limit then
            output:push(batch)
            output:push(bytes >= output_limit and "output_limit" or "max_results")
            return
          end
        end
        if recursive and info and info.type == "dir" then
          table.insert(directories, child)
        end
      end
    end
  end
  if #batch > 0 then output:push(batch) end
  output:push("finished")
end

local function threaded_list_dir(path, recursive, pattern, out, state)
  if not thread_available() then return list_dir(path, recursive, pattern, out, state) end
  local tool_id = next_threaded_file_tool_id()
  local worker = thread.create(
    "aslist" .. tool_id,
    threaded_list_worker,
    tool_id,
    path,
    recursive,
    pattern or false,
    state.max,
    state.output_limit,
    PATHSEP
  )
  if not worker then return list_dir(path, recursive, pattern, out, state) end
  local output = thread.get_channel("assistant_list_results_" .. tool_id)
  local done = false
  while not done do
    local value = output:first()
    if type(value) == "table" then
      for _, item in ipairs(value) do
        table.insert(out, item)
      end
      output:pop()
    elseif value == "output_limit" then
      state.truncated = "output limit"
      output:pop()
      done = true
    elseif value == "max_results" or value == "finished" then
      output:pop()
      done = true
    end
    context.yield_ui()
  end
  worker:wait()
  output:clear()
  return state.truncated == nil
end

---Search for text in files below a project directory.
---@param directory string
---@param text string
---@param search_type "plain"|"regex"|"luapattern"|string?
---@return string result
function filetools.search(directory, text, search_type)
  local path, err = context.assert_read_path(directory)
  if not path then return err end
  local info = system.get_file_info(path)
  if not info or info.type ~= "dir" then return "not a directory: " .. path end
  search_type = search_type or "plain"
  local narrowed_note
  if search_type == "plain" then
    local replacement_target = exact_replacement_target(active_user_prompt())
    if broad_exact_replacement_query(replacement_target, text) then
      narrowed_note = string.format(
        "Search query `%s` was narrowed to the exact old value `%s` from the user's replacement request.",
        tostring(text),
        tostring(replacement_target)
      )
      text = replacement_target
    end
  end
  local results = {}
  threaded_scan_dir(path, text or "", search_type, results)
  if #results == 0 then
    if narrowed_note then
      return narrowed_note .. "\nNo results for the exact old value."
    end
    return "No results."
  end
  local output = table.concat(results, "\n")
  if narrowed_note then
    output = narrowed_note .. "\n" .. output
  end
  return output
end

---List files and directories in a project directory.
---@param directory string
---@param recursive boolean|string?
---@param max_results number?
---@param pattern string?
---@return string result
function filetools.list(directory, recursive, max_results, pattern)
  local path, err = context.assert_read_path(directory)
  if not path then return err end
  local info = system.get_file_info(path)
  if not info or info.type ~= "dir" then return "not a directory: " .. path end
  local results = {}
  local state = {
    count = 0,
    max = tonumber(max_results) or 500,
    bytes = 0,
    output_limit = context.OUTPUT_LIMIT
  }
  threaded_list_dir(path, recursive == true or recursive == "true", context.optional_text(pattern), results, state)
  table.sort(results)
  if #results == 0 then return "No files." end
  local output = table.concat(results, "\n")
  if state.truncated then
    return context.limited(output, state.output_limit) .. string.format(
      "\n... stopped after reaching the %d byte tool output limit; narrow the directory, pattern, or max_results for more ...",
      state.output_limit
    )
  end
  return context.limited(output)
end

---Read a project file with optional 1-based offset and line limit.
---@param path string
---@param offset number|string|nil
---@param limit number|string|nil
---@return string result
function filetools.read(path, offset, limit)
  local absolute, err = context.assert_read_path(path)
  if not absolute then return err end
  context.yield_ui()
  local is_image = ImageView.is_supported(absolute)
  if is_image then
    return read_image_file(absolute)
  end
  local data, read_err = context.read_file(absolute)
  if not data then return read_err or "" end
  context.yield_ui()
  local normalized = normalize_to_lf(data)
  local all_lines = context.split_lines(normalized)
  local total_lines = #all_lines
  local start_line = math.max(1, tonumber(offset) or 1)
  if start_line > math.max(total_lines, 1) then
    return string.format("Offset %d is beyond end of file (%d lines total)", start_line, total_lines)
  end
  local requested_limit = tonumber(limit)
  local end_line = requested_limit and math.min(total_lines, start_line + math.max(0, requested_limit) - 1) or total_lines
  local selected = {}
  for index = start_line, end_line do
    table.insert(selected, all_lines[index] or "")
    if (index - start_line + 1) % 200 == 0 then context.yield_ui() end
  end
  local selected_text = table.concat(selected, "\n")
  if normalized:sub(-1) == "\n" and end_line == total_lines then selected_text = selected_text .. "\n" end
  return truncate_read_output(selected_text, start_line, total_lines, requested_limit)
end

---Write a complete project file after confirmation.
---@param path string
---@param content string
---@return boolean ok
---@return string result
function filetools.write_file(path, content)
  if context.contains_omitted_tool_argument({ path = path, content = content }) then
    return false, "refusing to write file from compacted historical placeholder content"
  end
  local absolute, err = context.assert_write_path(path, content or "")
  if not absolute then return false, err end
  local existed = system.get_file_info(absolute) ~= nil
  context.yield_ui()
  local current = context.read_file(absolute) or ""
  context.yield_ui()
  if not context.confirm("write", absolute, content or "") then
    return false, "user denied file write"
  end
  local text = tostring(content or "")
  context.yield_ui()
  local ok, write_err = context.write_file(absolute, text)
  if not ok then return false, write_err end
  context.yield_ui()
  local action = existed and "replaced" or "created"
  return true, context.edit_summary(action, absolute, current, text)
end

---Edit a project file with exact text replacements.
---@param path string
---@param edits table
---@param oldText string|nil
---@param newText string|nil
---@return boolean ok
---@return string result
function filetools.edit(path, edits, oldText, newText)
  if type(edits) ~= "table" and (oldText ~= nil or newText ~= nil) then
    edits = { { oldText = oldText, newText = newText } }
  end
  if context.contains_omitted_tool_argument({ path = path, edits = edits }) then
    return false, "refusing to edit file from compacted historical placeholder content"
  end
  if type(edits) ~= "table" then
    return false, "edit tool input is invalid. edits must contain at least one replacement."
  end
  if edits.oldText or edits.newText then edits = { edits } end
  if #edits == 0 then
    return false, "edit tool input is invalid. edits must contain at least one replacement."
  end
  local absolute, err = context.assert_write_path(path, "Edit file")
  if not absolute then return false, err end
  context.yield_ui()
  local raw, read_err = context.read_file(absolute)
  if not raw then return false, read_err or ("could not read file: " .. tostring(path)) end
  context.yield_ui()
  local bom, without_bom = strip_bom(raw)
  local ending = detect_line_ending(without_bom)
  local content = normalize_to_lf(without_bom)
  local base_content = content
  local matches = {}
  for index, edit in ipairs(edits) do
    if index % 20 == 0 then context.yield_ui() end
    if type(edit) ~= "table" then
      return false, string.format("edits[%d] must be an object.", index)
    end
    local old_text = normalize_to_lf(tostring(edit.oldText or ""))
    local new_text = normalize_to_lf(tostring(edit.newText or ""))
    if old_text == "" then
      return false, string.format("edits[%d].oldText must not be empty in %s.", index, tostring(path))
    end
    local match = find_edit_match(base_content, old_text)
    if not match then
      return false, string.format("Could not find edits[%d] in %s. The oldText must match exactly including all whitespace and newlines.", index, tostring(path))
    end
    if match.occurrences > 1 then
      return false, string.format("Found %d occurrences of edits[%d] in %s. Each oldText must be unique. Please provide more context to make it unique.", match.occurrences, index, tostring(path))
    end
    if match.content ~= base_content then
      base_content = match.content
      matches = {}
      for prior_index = 1, index - 1 do
        if prior_index % 20 == 0 then context.yield_ui() end
        local prior = edits[prior_index]
        local prior_match = find_edit_match(base_content, normalize_to_lf(tostring(prior.oldText or "")))
        if prior_match then
          table.insert(matches, {
            edit_index = prior_index,
            index = prior_match.index,
            length = prior_match.length,
            new_text = normalize_to_lf(tostring(prior.newText or ""))
          })
        end
      end
      match = find_edit_match(base_content, old_text)
    end
    table.insert(matches, {
      edit_index = index,
      index = match.index,
      length = match.length,
      new_text = new_text
    })
  end
  table.sort(matches, function(a, b) return a.index < b.index end)
  context.yield_ui()
  for index = 2, #matches do
    if index % 100 == 0 then context.yield_ui() end
    local previous = matches[index - 1]
    local current = matches[index]
    if previous.index + previous.length > current.index then
      return false, string.format("edits[%d] and edits[%d] overlap in %s. Merge them into one edit or target disjoint regions.", previous.edit_index, current.edit_index, tostring(path))
    end
  end
  local new_content = base_content
  for index = #matches, 1, -1 do
    if index % 100 == 0 then context.yield_ui() end
    local match = matches[index]
    new_content = new_content:sub(1, match.index - 1) .. match.new_text .. new_content:sub(match.index + match.length)
  end
  if new_content == base_content then
    return false, string.format("No changes made to %s. The replacements produced identical content.", tostring(path))
  end
  local final = bom .. restore_line_endings(new_content, ending)
  context.yield_ui()
  local diff = unified_diff(context.project_relative(absolute), raw, final)
  if not context.confirm("edit", absolute, diff) then
    return false, "user denied file edit"
  end
  context.yield_ui()
  local ok, write_err = context.write_file(absolute, final)
  if not ok then return false, write_err end
  context.yield_ui()
  return true, table.concat({
    string.format("Successfully replaced %d block(s) in %s.", #edits, tostring(path)),
    diff
  }, "\n")
end

---Return metadata and a content hash for a project path.
---@param path string
---@return string result
function filetools.file_info(path)
  local absolute, err = context.assert_read_path(path)
  if not absolute then return err end
  local info = system.get_file_info(absolute)
  if not info then return "not found: " .. absolute end
  local data = info.type == "file" and context.read_file(absolute) or nil
  return string.format(
    "path: %s\ntype: %s\nsize: %s\nmodified: %s\nhash: %s",
    absolute,
    tostring(info.type),
    tostring(info.size or ""),
    tostring(info.modified or ""),
    data and context.hash_text(data) or ""
  )
end

filetools.tools = {
  Tool:new({
    name = "read",
    callback = filetools.read,
    compact_result = function(call, result)
      local path = call and call.arguments and call.arguments.path
      return context.compact_provider_text_result(result_text(result), "file read: " .. tostring(path or ""))
    end,
    result_is_successful = inspection_result_is_successful,
    compact_history = compact_inspection_history,
    activity_label = function() return "Inspecting project" end,
    activity_markdown = read_activity_markdown,
    compact_activity_markdown = compact_file_activity("Reading"),
    description = "Read the contents of a file. Supports text files and images (jpg, jpeg, png, gif, webp, bmp, svg, and other Pragtical-supported image formats). Images are sent as attachments. For text files, output is truncated to 2000 lines or 50KB (whichever is hit first). Use offset/limit for large files. When you need the full file, continue with offset until complete.",
    read_only = true,
    requires_approval = read_approval("path"),
    params = {
      { name = "path", description = "Path to the file to read (relative or absolute)", type = "string" },
      { name = "offset", description = "Line number to start reading from (1-indexed)", type = "number", required = false },
      { name = "limit", description = "Maximum number of lines to read", type = "number", required = false }
    }
  }),
  Tool:new({
    name = "search",
    callback = filetools.search,
    compact_result = compact("search result"),
    result_is_successful = inspection_result_is_successful,
    compact_history = compact_inspection_history,
    activity_label = function() return "Inspecting project" end,
    compact_activity_markdown = compact_file_activity("Inspecting project"),
    description = "Search for text in a project directory. For exact replacement tasks, search the complete old value from the user first and do not broaden to substrings unless explicitly asked.",
    read_only = true,
    requires_approval = read_approval("directory"),
    params = {
      { name = "directory", description = "Directory to search.", type = "string" },
      { name = "text", description = "Text or pattern to find.", type = "string" },
      { name = "search_type", description = "Search mode.", type = "string", enum = { "plain", "regex", "luapattern" } }
    }
  }),
  Tool:new({
    name = "list",
    callback = filetools.list,
    compact_result = compact("file listing"),
    result_is_successful = inspection_result_is_successful,
    compact_history = compact_inspection_history,
    activity_label = function() return "Inspecting project" end,
    compact_activity_markdown = compact_file_activity("Inspecting project"),
    description = "List files and directories inside a project directory.",
    read_only = true,
    requires_approval = read_approval("directory"),
    params = {
      { name = "directory", description = "Directory to list.", type = "string" },
      { name = "recursive", description = "Whether to recurse into subdirectories.", type = "boolean" },
      { name = "max_results", description = "Maximum number of paths to return.", type = "number" },
      { name = "pattern", description = "Optional plain text path filter. Omit this field when no filter is needed; do not send None/null.", type = "string", required = false }
    }
  }),
  Tool:new({
    name = "file_info",
    callback = filetools.file_info,
    result_is_successful = inspection_result_is_successful,
    compact_history = compact_inspection_history,
    activity_label = function() return "Inspecting project" end,
    compact_activity_markdown = compact_file_activity("Inspecting project"),
    description = "Get project file metadata and content hash.",
    read_only = true,
    requires_approval = read_approval("path"),
    params = {
      { name = "path", description = "File or directory path to inspect.", type = "string" }
    }
  }),
  Tool:new({
    name = "write",
    callback = filetools.write_file,
    result_is_successful = mutation_result_is_successful,
    compact_history = compact_mutation_history,
    activity_label = function() return "Editing files" end,
    compact_activity_markdown = compact_write_activity,
    description = "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Automatically creates parent directories.",
    params = {
      { name = "path", description = "Path to the file to write (relative or absolute)", type = "string" },
      { name = "content", description = "Content to write to the file", type = "string" }
    }
  }),
  Tool:new({
    name = "edit",
    callback = filetools.edit,
    result_is_successful = mutation_result_is_successful,
    compact_history = compact_mutation_history,
    activity_label = function() return "Editing files" end,
    compact_activity_markdown = compact_edit_activity,
    description = "Edit a single file using exact text replacement. Every edits[].oldText must match a unique, non-overlapping region of the original file. If two changes affect the same block or nearby lines, merge them into one edit instead of emitting overlapping edits. Do not include large unchanged regions just to connect distant changes.",
    params = {
      { name = "path", description = "Path to the file to edit (relative or absolute)", type = "string" },
      {
        name = "edits",
        description = "One or more targeted replacements. Each edit is matched against the original file, not incrementally. Do not include overlapping or nested edits. If two changes touch the same block or nearby lines, merge them into one edit instead.",
        schema = {
          type = "array",
          items = {
            type = "object",
            additionalProperties = false,
            required = { "oldText", "newText" },
            properties = {
              oldText = {
                type = "string",
                description = "Exact text for one targeted replacement. It must be unique in the original file and must not overlap with any other edits[].oldText in the same call."
              },
              newText = {
                type = "string",
                description = "Replacement text for this targeted edit."
              }
            }
          }
        }
      },
      { name = "oldText", description = "Legacy single-edit exact text to replace. Prefer edits[].oldText.", type = "string", required = false },
      { name = "newText", description = "Legacy single-edit replacement text. Prefer edits[].newText.", type = "string", required = false }
    }
  })
}

return filetools
