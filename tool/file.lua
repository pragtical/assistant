local context = require "plugins.assistant.tool_context"
local Tool = require "plugins.assistant.tool"

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

local READ_MAX_LINES = 2000
local READ_MAX_BYTES = 50 * 1024

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

local function normalize_for_fuzzy_match(text)
  text = normalize_to_lf(text)
  local lines = {}
  local count = 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, (line:gsub("%s+$", "")))
    count = count + 1
    if count % 200 == 0 then context.yield_ui() end
  end
  if text:sub(-1) ~= "\n" then
    -- The loop above adds the final non-newline line exactly once.
  else
    table.remove(lines)
  end
  text = table.concat(lines, "\n")
  return text
    :gsub("\226\128\152", "'")
    :gsub("\226\128\153", "'")
    :gsub("\226\128\156", '"')
    :gsub("\226\128\157", '"')
    :gsub("\226\128\147", "-")
    :gsub("\226\128\148", "-")
    :gsub("\194\160", " ")
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
  local fuzzy_content = normalize_for_fuzzy_match(content)
  local fuzzy_old = normalize_for_fuzzy_match(old_text)
  index = fuzzy_content:find(fuzzy_old, 1, true)
  if not index then return nil end
  return {
    content = fuzzy_content,
    index = index,
    length = #fuzzy_old,
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
  local line_no = 1
  for line in (data .. "\n"):gmatch("(.-)\n") do
    if matches(line, text, search_type) then
      table.insert(out, string.format("%s:%d:%s", path, line_no, line))
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
  local results = {}
  scan_dir(path, text or "", search_type, results)
  if #results == 0 then return "No results." end
  return table.concat(results, "\n")
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
  list_dir(path, recursive == true or recursive == "true", context.optional_text(pattern), results, state)
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
  local absolute, err = context.assert_project_path(path)
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
  local absolute, err = context.assert_project_path(path)
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
      return context.compact_provider_text_result(result, "file read: " .. tostring(path or ""))
    end,
    description = "Read the contents of a file. For text files, output is truncated to 2000 lines or 50KB (whichever is hit first). Use offset/limit for large files. When you need the full file, continue with offset until complete.",
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
    description = "Search for text in a project directory.",
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
    description = "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Automatically creates parent directories.",
    params = {
      { name = "path", description = "Path to the file to write (relative or absolute)", type = "string" },
      { name = "content", description = "Content to write to the file", type = "string" }
    }
  }),
  Tool:new({
    name = "edit",
    callback = filetools.edit,
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
