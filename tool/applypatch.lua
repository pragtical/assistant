local context = require "plugins.assistant.tool_context"
local common = require "core.common"
local json = require "core.json"
local Tool = require "plugins.assistant.tool"

---Patch application tool implementation.
---
---Parses Codex-style structured patches and unified diffs, validates project
---paths, and applies file additions, updates, moves, and deletions.
---@class assistant.tool.applypatch
local applypatch = {}

---Handle strip apply patch wrapper.
local function strip_apply_patch_wrapper(patch)
  local text = tostring(patch or ""):match("^%s*(.-)%s*$")
  local fenced = text:match("^```[%w_-]*%s*\n(.-)\n```%s*$")
  if fenced then
    text = fenced:match("^%s*(.-)%s*$")
  end
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, line)
  end
  if text:sub(-1) == "\n" then table.remove(lines) end
  if #lines >= 4 then
    local marker = lines[1]:match("<<'([^']+)'%s*$")
      or lines[1]:match('<<"([^"]+)"%s*$')
      or lines[1]:match("<<([%w_%-]+)%s*$")
    if marker and lines[#lines]:match("^%s*" .. marker:gsub("([^%w])", "%%%1") .. "%s*$") then
      table.remove(lines, #lines)
      table.remove(lines, 1)
      text = table.concat(lines, "\n")
    end
  end
  local begin_at = text:find("%*%*%* Begin Patch")
  if begin_at and begin_at > 1 then
    text = text:sub(begin_at)
  end
  local end_start, end_finish = text:find("%*%*%* End Patch")
  if end_finish and end_finish < #text then
    text = text:sub(1, end_finish)
  elseif begin_at and not end_start then
    text = text .. "\n*** End Patch"
  end
  lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, line)
  end
  if text:sub(-1) == "\n" then table.remove(lines) end
  if #lines >= 4
    and (lines[1] == "<<EOF" or lines[1] == "<<'EOF'" or lines[1] == '<<"EOF"')
    and lines[#lines]:match("EOF%s*$")
  then
    table.remove(lines, #lines)
    table.remove(lines, 1)
    return table.concat(lines, "\n")
  end
  if lines[#lines] and lines[#lines]:match("^%+%*%*%* End Patch%s*$") then
    lines[#lines] = "*** End Patch"
    text = table.concat(lines, "\n")
  end
  return text
end

---Handle patch path.
local function patch_path(path)
  path = tostring(path or "")
  path = path:gsub("^a/", ""):gsub("^b/", "")
  if path == "/dev/null" then return nil end
  return path
end

---Parse hunk header.
local function parse_hunk_header(line)
  local old_start, old_count, new_start, new_count =
    line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  old_start = tonumber(old_start)
  new_start = tonumber(new_start)
  old_count = tonumber(old_count ~= "" and old_count or "1")
  new_count = tonumber(new_count ~= "" and new_count or "1")
  return old_start, old_count, new_start, new_count
end

---Handle apply file patch.
local function apply_file_patch(file_patch)
  local absolute, err = context.assert_project_path(file_patch.path)
  if not absolute then return false, err end
  local original, read_err
  if file_patch.add then
    original = ""
  else
    original, read_err = context.read_file(absolute)
    if not original then
      return false, read_err
    end
  end
  local original_lines = context.split_lines(original)
  local output = {}
  local source_index = 1
  local steps = 0
  for _, hunk in ipairs(file_patch.hunks) do
    while source_index < hunk.old_start do
      table.insert(output, original_lines[source_index] or "")
      source_index = source_index + 1
      steps = steps + 1
      if steps % 200 == 0 then context.yield_ui() end
    end
    for _, item in ipairs(hunk.lines) do
      local op, text = item.op, item.text
      if op == " " then
        if (original_lines[source_index] or "") ~= text then
          return false, "patch context mismatch in " .. file_patch.path
        end
        table.insert(output, text)
        source_index = source_index + 1
      elseif op == "-" then
        if (original_lines[source_index] or "") ~= text then
          return false, "patch removal mismatch in " .. file_patch.path
        end
        source_index = source_index + 1
      elseif op == "+" then
        table.insert(output, text)
      end
      steps = steps + 1
      if steps % 200 == 0 then context.yield_ui() end
    end
  end
  while source_index <= #original_lines do
    table.insert(output, original_lines[source_index])
    source_index = source_index + 1
    steps = steps + 1
    if steps % 200 == 0 then context.yield_ui() end
  end
  context.yield_ui()
  local next_data = table.concat(output, "\n")
  if original:sub(-1) == "\n" then next_data = next_data .. "\n" end
  if file_patch.delete then
    local ok, remove_err = os.remove(absolute)
    if not ok then return false, remove_err end
    return true
  end
  return context.write_file(absolute, next_data)
end

---Parse structured patch.
local function parse_structured_patch(patch)
  local text = tostring(patch or ""):match("^%s*(.-)%s*$")
  if not text:match("^%*%*%* Begin Patch") then return nil end
  local operations = {}
  local current
  local saw_begin = false
  local saw_end = false
  local line_no = 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    line_no = line_no + 1
    if line:match("^%*%*%* Begin Patch%s*$") then
      if saw_begin then return nil, "duplicate Begin Patch marker" end
      saw_begin = true
      if #operations > 0 or current then return nil, "duplicate Begin Patch marker" end
    elseif line:match("^%*%*%* Environment ID:%s*.+$") then
      if current or #operations > 0 then return nil, "Environment ID must appear before patch operations" end
    elseif line:match("^%*%*%* End Patch%s*$") then
      if current then
        table.insert(operations, current)
        current = nil
      end
      saw_end = true
    else
      local kind, path = line:match("^%*%*%* (Add File):%s*(.+)$")
      if not kind then kind, path = line:match("^%*%*%* (Update File):%s*(.+)$") end
      if not kind then kind, path = line:match("^%*%*%* (Delete File):%s*(.+)$") end
      if not kind then kind, path = line:match("^%*%*%* (Add File)%s+(.+)$") end
      if not kind then kind, path = line:match("^%*%*%* (Update File)%s+(.+)$") end
      if not kind then kind, path = line:match("^%*%*%* (Delete File)%s+(.+)$") end
      if kind then
        if saw_end then return nil, "operation after End Patch marker" end
        if current then table.insert(operations, current) end
        current = {
          kind = kind,
          path = path,
          lines = {}
        }
      elseif current then
        local move_to = line:match("^%*%*%* Move to:%s*(.+)$")
        if move_to then
          current.move_to = move_to
        elseif line:match("^@@") then
          table.insert(current.lines, { op = "@", text = line:match("^@@%s*(.-)%s*$") or "" })
        elseif line:match("^%*%*%* End of File%s*$") then
          table.insert(current.lines, { op = "eof", text = "" })
        elseif current.kind == "Add File" then
          if line:sub(1, 1) == "+" then
            table.insert(current.lines, { op = "+", text = line:sub(2) })
          else
            table.insert(current.lines, { op = "+", text = line })
          end
        else
          local op = line:sub(1, 1)
          if op == "+" or op == "-" or op == " " then
            table.insert(current.lines, { op = op, text = line:sub(2) })
          elseif line == "" then
            table.insert(current.lines, { op = " ", text = "" })
          else
            return nil, "invalid patch line " .. line_no .. ": " .. line
          end
        end
      elseif line:match("%S") then
        return nil, "unexpected patch line " .. line_no .. ": " .. line
      end
    end
    if line_no % 200 == 0 then context.yield_ui() end
  end
  if not saw_end then return nil, "missing End Patch marker" end
  if #operations == 0 then return nil, "patch contains no operations" end
  return operations
end

---Handle locate sequence.
local function locate_sequence(lines, sequence, start_index)
  start_index = start_index or 1
  if #sequence == 0 then return start_index end
  for index = start_index, #lines - #sequence + 1 do
    local matched = true
    for offset, expected in ipairs(sequence) do
      if (lines[index + offset - 1] or "") ~= expected then
        matched = false
        break
      end
    end
    if matched then return index end
    if index % 200 == 0 then context.yield_ui() end
  end
end

---Handle locate context line.
local function locate_context_line(lines, value, start_index)
  if not value or value == "" then return start_index or 1 end
  for index = start_index or 1, #lines do
    if lines[index] == value then return index + 1 end
    if index % 200 == 0 then context.yield_ui() end
  end
end

---Build structured chunks.
local function build_structured_chunks(operation)
  local chunks = {}
  local current = { lines = {} }
  local saw_change = false

  ---Handle flush.
  local function flush()
    if current.context ~= nil or current.eof or #current.lines > 0 then
      table.insert(chunks, current)
    end
    current = { lines = {} }
  end

  for _, item in ipairs(operation.lines or {}) do
    if item.op == "@" then
      flush()
      current.context = item.text ~= "" and item.text or nil
    elseif item.op == "eof" then
      current.eof = true
    else
      if item.op == "+" or item.op == "-" then saw_change = true end
      table.insert(current.lines, item)
    end
  end
  flush()

  if not saw_change then return nil, "Update File has no changes: " .. operation.path end
  return chunks
end

---Handle compute chunk replacement.
local function compute_chunk_replacement(original_lines, operation, chunk, line_index)
  local old_sequence = {}
  local replacement = {}
  for _, item in ipairs(chunk.lines or {}) do
    if item.op == " " or item.op == "-" then
      table.insert(old_sequence, item.text)
    end
    if item.op == " " or item.op == "+" then
      table.insert(replacement, item.text)
    end
  end

  if chunk.context then
    local context_index = locate_context_line(original_lines, chunk.context, line_index)
    if not context_index then
      return nil, "patch context not found in " .. operation.path .. ": " .. chunk.context
    end
    line_index = context_index
  end

  local found
  if #old_sequence == 0 then
    found = chunk.eof and (#original_lines + 1) or line_index
  elseif chunk.eof then
    found = #original_lines - #old_sequence + 1
    if found < line_index then
      return nil, "patch EOF context mismatch in " .. operation.path
    end
    for offset, expected in ipairs(old_sequence) do
      if (original_lines[found + offset - 1] or "") ~= expected then
        return nil, "patch EOF context mismatch in " .. operation.path
      end
    end
  else
    found = locate_sequence(original_lines, old_sequence, line_index)
  end

  if not found then
    return nil, "patch context mismatch in " .. operation.path
  end

  return {
    start = found,
    old_count = #old_sequence,
    new_lines = replacement,
    next_index = found + #old_sequence
  }
end

---Handle compute structured update.
local function compute_structured_update(original, operation)
  local lines = context.split_lines(original)
  if operation.move_to and #(operation.lines or {}) == 0 then
    return original
  end
  local chunks, chunk_err = build_structured_chunks(operation)
  if not chunks then return nil, chunk_err end

  local replacements = {}
  local line_index = 1
  for _, chunk in ipairs(chunks) do
    local replacement, err = compute_chunk_replacement(lines, operation, chunk, line_index)
    if not replacement then return nil, err end
    table.insert(replacements, replacement)
    line_index = replacement.next_index
    if #replacements % 100 == 0 then context.yield_ui() end
  end

  for index = #replacements, 1, -1 do
    local replacement = replacements[index]
    for _ = 1, replacement.old_count do
      table.remove(lines, replacement.start)
    end
    for offset, text in ipairs(replacement.new_lines) do
      table.insert(lines, replacement.start + offset - 1, text)
    end
    if index % 100 == 0 then context.yield_ui() end
  end

  local next_data = table.concat(lines, "\n")
  if next_data ~= "" and next_data:sub(-1) ~= "\n" then next_data = next_data .. "\n" end
  return next_data
end

---Handle prepare structured patch.
local function prepare_structured_patch(operations)
  local prepared = {}
  local touched = {}
  local function add_file_lines(operation)
    local lines = {}
    for _, item in ipairs(operation.lines or {}) do
      if item.op ~= "+" then return nil, "Add File accepts only added content lines in " .. operation.path end
      table.insert(lines, item.text)
    end
    if lines[1] and lines[#lines]
      and lines[1]:match("^```[%w_%-]*%s*$")
      and lines[#lines]:match("^```%s*$")
    then
      table.remove(lines, #lines)
      table.remove(lines, 1)
    end
    return lines
  end
  for _, operation in ipairs(operations) do
    local absolute, err = context.assert_project_path(operation.path)
    if not absolute then return nil, err end
    if operation.kind == "Add File" then
      if touched[absolute] then
        return nil, "multiple operations for the same file are not supported yet: " .. context.project_relative(absolute)
      end
      touched[absolute] = true
      local current = context.read_file(absolute) or ""
      local out, lines_err = add_file_lines(operation)
      if not out then return nil, lines_err end
      local next_data = table.concat(out, "\n")
      if #out > 0 then next_data = next_data .. "\n" end
      table.insert(prepared, { action = "add", path = absolute, old = current, new = next_data })
    elseif operation.kind == "Delete File" then
      if touched[absolute] then
        return nil, "multiple operations for the same file are not supported yet: " .. context.project_relative(absolute)
      end
      touched[absolute] = true
      if #(operation.lines or {}) > 0 then return nil, "Delete File does not accept body lines: " .. operation.path end
      if operation.move_to then return nil, "Delete File does not support Move to: " .. operation.path end
      local current, read_err = context.read_file(absolute)
      if not current then return nil, read_err or ("file not found: " .. context.project_relative(absolute)) end
      table.insert(prepared, { action = "delete", path = absolute, old = current })
    elseif operation.kind == "Update File" then
      local move_to
      if operation.move_to then
        local move_err
        move_to, move_err = context.assert_project_path(operation.move_to)
        if not move_to then return nil, move_err end
      end
      if touched[absolute] then
        return nil, "multiple operations for the same file are not supported yet: " .. context.project_relative(absolute)
      end
      if move_to and touched[move_to] then
        return nil, "multiple operations for the same file are not supported yet: " .. context.project_relative(move_to)
      end
      touched[absolute] = true
      if move_to then touched[move_to] = true end
      local current, read_err = context.read_file(absolute)
      if not current then return nil, read_err or ("file not found: " .. context.project_relative(absolute)) end
      local next_data, update_err = compute_structured_update(current, operation)
      if not next_data then return nil, update_err end
      table.insert(prepared, { action = "update", path = absolute, move_to = move_to, old = current, new = next_data })
    else
      return nil, "unsupported patch operation: " .. tostring(operation.kind)
    end
    context.yield_ui()
  end
  return prepared
end

---Handle apply prepared patch.
local function apply_prepared_patch(prepared)
  for _, change in ipairs(prepared or {}) do
    if change.action == "delete" then
      local ok, err = os.remove(change.path)
      if not ok then return false, err end
    elseif change.move_to and change.move_to ~= change.path then
      local ok, err = context.write_file(change.move_to, change.new or "")
      if not ok then return false, err end
      ok, err = os.remove(change.path)
      if not ok then return false, err end
    else
      local ok, err = context.write_file(change.path, change.new or "")
      if not ok then return false, err end
    end
    context.yield_ui()
  end
  return true
end

---Handle describe prepared change.
local function describe_prepared_change(change)
  local path = context.project_relative(change.path)
  if change.action == "delete" then
    return "- deleted " .. path
  end
  if change.move_to and change.move_to ~= change.path then
    return "- moved " .. path .. " -> " .. context.project_relative(change.move_to)
  end
  if change.action == "add" and tostring(change.old or "") ~= "" then
    return "- updated existing " .. path .. " via Add File (file already existed; do not recreate it again)"
  end
  if change.action == "add" then
    return "- added " .. path
  end
  return "- updated " .. path
end

---Handle describe prepared patch.
local function describe_prepared_patch(prepared)
  local lines = {
    string.format("applied patch to %d file(s)", #prepared),
    "Changed files:"
  }
  for _, change in ipairs(prepared or {}) do
    table.insert(lines, describe_prepared_change(change))
  end
  return table.concat(lines, "\n")
end

---Handle describe unified file patch.
local function describe_unified_file_patch(file_patch)
  local path = file_patch.path or file_patch.new or file_patch.old
  path = path and context.project_relative(path) or "(unknown)"
  if file_patch.delete then
    return "- deleted " .. path
  end
  if file_patch.add then
    return "- added " .. path
  end
  return "- updated " .. path
end

---Handle describe unified patch.
local function describe_unified_patch(files)
  local lines = {
    string.format("applied patch to %d file(s)", #files),
    "Changed files:"
  }
  for _, file_patch in ipairs(files or {}) do
    table.insert(lines, describe_unified_file_patch(file_patch))
  end
  return table.concat(lines, "\n")
end

---Parse unified patch.
local function parse_unified_patch(patch)
  local files = {}
  local current
  local current_hunk
  local line_no = 0
  for line in ((patch or "") .. "\n"):gmatch("(.-)\n") do
    line_no = line_no + 1
    local old = line:match("^%-%-%- (.+)$")
    local new = line:match("^%+%+%+ (.+)$")
    if old then
      current = { old = patch_path(old), hunks = {} }
      current_hunk = nil
    elseif new and current then
      current.new = patch_path(new)
      current.path = current.new or current.old
      current.add = current.old == nil and current.new ~= nil
      current.delete = current.old ~= nil and current.new == nil
      table.insert(files, current)
    elseif line:match("^@@ ") and current then
      local old_start = parse_hunk_header(line)
      if not old_start then return nil, "invalid hunk header: " .. line end
      current_hunk = { old_start = old_start, lines = {} }
      table.insert(current.hunks, current_hunk)
    elseif current_hunk and line ~= "\\ No newline at end of file" then
      local op = line:sub(1, 1)
      if op == " " or op == "+" or op == "-" then
        table.insert(current_hunk.lines, { op = op, text = line:sub(2) })
      end
    end
    if line_no % 200 == 0 then context.yield_ui() end
  end
  return files
end

---Handle apply patch.
function applypatch.apply_patch(patch)
  patch = strip_apply_patch_wrapper(patch)
  if context.contains_omitted_tool_argument(patch) then
    return false, "refusing to apply compacted historical placeholder patch"
  end
  local structured_operations, structured_parse_err = parse_structured_patch(patch)
  if structured_operations then
    local prepared, prepare_err = prepare_structured_patch(structured_operations)
    if not prepared then return false, prepare_err end
    if not context.confirm("apply_patch", "project", patch or "") then
      return false, "user denied patch application"
    end
    local ok, apply_err = apply_prepared_patch(prepared)
    if not ok then return false, apply_err end
    return true, describe_prepared_patch(prepared)
  elseif tostring(patch or ""):find("*** Begin Patch", 1, true) then
    return false, structured_parse_err or "invalid structured patch"
  end
  local files, err = parse_unified_patch(patch)
  if not files then return false, err end
  if #files == 0 then return false, "patch contains no files" end
  if not context.confirm("apply_patch", "project", patch or "") then
    return false, "user denied patch application"
  end
  for index, file_patch in ipairs(files) do
    if index % 5 == 0 then context.yield_ui() end
    local ok, apply_err = apply_file_patch(file_patch)
    if not ok then return false, apply_err end
  end
  return true, describe_unified_patch(files)
end

---Strip diff path prefixes used by unified diffs.
---@param path string|nil
---@return string|nil
local function strip_patch_path_prefix(path)
  path = tostring(path or ""):match("^%s*(.-)%s*$")
  path = path:gsub("%s+$", "")
  path = path:gsub("^a/", ""):gsub("^b/", "")
  if path == "" or path == "/dev/null" then return nil end
  return path
end

---Extract file operation events from a patch payload.
---@param patch string|nil
---@return table[] events
local function extract_patch_file_events(patch)
  local events = {}
  local pending_update
  local order = 0
  local function add_event(operation, path, current_path)
    path = strip_patch_path_prefix(path)
    current_path = strip_patch_path_prefix(current_path or path)
    if not path then return end
    order = order + 1
    table.insert(events, {
      operation = operation,
      path = path,
      current_path = current_path,
      order = order
    })
  end
  local function flush_update()
    if pending_update then
      add_event("patched", pending_update)
      pending_update = nil
    end
  end
  for line in (tostring(patch or "") .. "\n"):gmatch("(.-)\n") do
    local add_path = line:match("^%*%*%* Add File:?%s+(.+)$")
    local update_path = line:match("^%*%*%* Update File:?%s+(.+)$")
    local delete_path = line:match("^%*%*%* Delete File:?%s+(.+)$")
    local move_path = line:match("^%*%*%* Move to:?%s+(.+)$")
    local unified_path = line:match("^%+%+%+%s+(.+)$")
    if add_path then
      flush_update()
      add_event("added", add_path)
    elseif update_path then
      flush_update()
      pending_update = update_path
    elseif delete_path then
      flush_update()
      add_event("deleted", delete_path)
    elseif move_path then
      if pending_update then
        add_event("moved", pending_update, move_path)
        pending_update = nil
      else
        add_event("patched", move_path)
      end
    elseif unified_path then
      flush_update()
      add_event("patched", unified_path)
    end
  end
  flush_update()
  return events
end

---Resolve a project-relative file path for snapshots.
---@param project_dir string|nil
---@param path string|nil
---@return string|nil absolute
---@return string|nil relative
local function project_file_path(project_dir, path)
  if not project_dir or project_dir == "" then return nil end
  path = strip_patch_path_prefix(path)
  if not path then return nil end
  local root = common.normalize_path(project_dir) or project_dir
  local absolute = path
  if not absolute:match("^/") and not absolute:match("^%a:[/\\]") then
    absolute = root .. PATHSEP .. absolute
  end
  absolute = common.normalize_path(absolute) or absolute
  if absolute ~= root and not common.path_belongs_to(absolute, root) then return nil end
  return absolute, common.relative_path(root, absolute)
end

---Read a snapshot file.
---@param path string|nil
---@return string|nil
local function read_snapshot_file(path)
  local info = path and system.get_file_info(path)
  if not info or info.type ~= "file" then return nil end
  local fp = io.open(path, "rb")
  if not fp then return nil end
  local text = fp:read("*a")
  fp:close()
  return text or ""
end

---Return whether an Add File operation updated an existing path.
---@param result_text string|nil
---@param path string|nil
---@return boolean
local function add_file_updated_existing(result_text, path)
  result_text = tostring(result_text or "")
  path = tostring(path or "")
  if path == "" then return false end
  return result_text:find("updated existing " .. path .. " via Add File", 1, true) ~= nil
end

---Return markdown language for file snapshots.
---@param path string|nil
---@return string
local function code_fence_language(path)
  local name = tostring(path or ""):match("[^/\\]+$") or ""
  local ext = name:match("%.([^%.]+)$")
  if name == "Makefile" or name:match("^Makefile%.") then return "make" end
  if ext == "c" or ext == "h" then return "c" end
  if ext == "lua" then return "lua" end
  if ext == "md" or ext == "markdown" then return "markdown" end
  return ""
end

---Return label for a patch snapshot record.
---@param record table
---@return string
local function patch_snapshot_label(record)
  local operation = record and record.operation or "patched"
  local path = tostring(record and record.path or "")
  local current_path = tostring(record and record.current_path or path)
  if operation == "added" then return "Added File: " .. current_path end
  if operation == "deleted" then return "Deleted File: " .. path end
  if operation == "moved" then return "Moved File: " .. path .. " -> " .. current_path end
  return "Patched File: " .. current_path
end

---Build an assistant snapshot message from patch events.
---@param snapshot_events table[]
---@return table|nil
local function build_file_snapshot_message(snapshot_events)
  if not next(snapshot_events or {}) then return nil end
  local records = {}
  local positions = {}
  for _, record in ipairs(snapshot_events) do
    local key = tostring(record.current_path or record.path or record.order or #records + 1)
    local position = positions[key]
    if position then
      records[position] = record
    else
      positions[key] = #records + 1
      table.insert(records, record)
    end
  end
  local parts = {
    "# Already Applied Changes",
    "",
    "Historical patch details were omitted from provider history; these file operations already happened.",
    "Use the current file content below instead of historical patch arguments. Files listed below already exist unless marked deleted. Do not use Add File for listed existing files; read them first and use Update File for targeted changes only if they need changes."
  }
  local included = 0
  for _, record in ipairs(records) do
    included = included + 1
    table.insert(parts, "")
    table.insert(parts, patch_snapshot_label(record))
    if record.operation == "deleted" then
      table.insert(parts, "This file was deleted and no longer exists.")
    else
      local text = read_snapshot_file(record.absolute)
      if text ~= nil then
        table.insert(parts, "```" .. code_fence_language(record.current_path))
        table.insert(parts, text)
        table.insert(parts, "```")
      else
        table.insert(parts, "Current file content could not be read.")
      end
    end
  end
  if included == 0 then return nil end
  return {
    role = "assistant",
    content = table.concat(parts, "\n")
  }
end

---Return whether a provider call invokes apply_patch.
---@param call table
---@return boolean
local function is_apply_patch_call(call)
  local fn = type(call) == "table" and type(call["function"]) == "table" and call["function"] or nil
  return (fn and fn.name == "apply_patch") or call and call.name == "apply_patch"
end

---Extract the patch argument from a provider call.
---@param call table
---@return string|nil
local function patch_from_call(call)
  local fn = type(call) == "table" and type(call["function"]) == "table" and call["function"] or nil
  local arguments = fn and fn.arguments or type(call) == "table" and call.arguments or nil
  if type(arguments) ~= "string" then return nil end
  local ok, decoded = pcall(json.decode, arguments)
  if not ok or type(decoded) ~= "table" then return nil end
  return type(decoded.patch) == "string" and decoded.patch or nil
end

---Return whether apply_patch result succeeded.
---@param _ table|nil
---@param result_message table|string
---@return boolean
function applypatch.result_is_successful(_, result_message)
  local content = type(result_message) == "table"
    and (result_message.content or result_message.output)
    or result_message
  content = tostring(content or ""):lower()
  return content:find("applied patch", 1, true) ~= nil
end

---Compact historical apply_patch calls into current file snapshots.
---@param message table
---@param compact_context table|nil
---@param included_ids table<string, boolean>|nil
---@param result_texts table<string, string>|nil
---@return table[]|nil messages
function applypatch.compact_history(message, compact_context, included_ids, result_texts)
  if type(message) ~= "table" or type(message.tool_calls) ~= "table" then return nil end
  local events = {}
  for _, call in ipairs(message.tool_calls) do
    local id = tostring(type(call) == "table" and call.id or "")
    if is_apply_patch_call(call) and (not included_ids or included_ids[id]) then
      local patch = patch_from_call(call)
      if patch then
        for _, event in ipairs(extract_patch_file_events(patch)) do
          local result_text = result_texts and result_texts[id] or ""
          local lookup_path = event.operation == "deleted" and event.path or event.current_path
          local absolute, relative = project_file_path(compact_context and compact_context.project_dir, lookup_path)
          local old_absolute, old_relative = project_file_path(compact_context and compact_context.project_dir, event.path)
          local operation = event.operation
          if operation == "added" and add_file_updated_existing(result_text, relative or event.current_path) then
            operation = "patched"
          end
          if relative or old_relative then
            table.insert(events, {
              operation = operation,
              path = old_relative or event.path,
              current_path = relative or event.current_path,
              absolute = absolute,
              old_absolute = old_absolute,
              order = #events + 1
            })
          end
        end
      end
    end
  end
  local snapshot = build_file_snapshot_message(events)
  return snapshot and { snapshot } or nil
end

applypatch.tools = {
  Tool:new({
    name = "apply_patch",
    callback = applypatch.apply_patch,
    result_is_successful = applypatch.result_is_successful,
    compact_history = applypatch.compact_history,
    description = table.concat({
      "Apply a structured patch or unified diff to project files after user confirmation.",
      "When updating, moving, or deleting an existing file, use recent exact file context; if context is stale, summarized, omitted, or compacted, read the target with read first.",
      "If apply_patch reports a context or removal mismatch, do not retry the same patch blindly; read the current target file or exact region, then rebuild the patch.",
      "Preferred structured patch format:",
      "*** Begin Patch",
      "*** Add File: path/to/file",
      "+new file line",
      "*** Update File: path/to/file",
      "@@",
      " context line",
      "-old line",
      "+new line",
      "*** Delete File: path/to/file",
      "*** End Patch",
      "Use a colon after Add File, Update File, and Delete File. Prefer + on add-file content lines; bare add-file content is also accepted. Update hunks use leading space for context, - for removals, and + for additions."
    }, "\n"),
    params = {
      { name = "patch", description = "Structured patch or unified diff text. Structured patches must start with *** Begin Patch and end with *** End Patch.", type = "string" }
    }
  })
}

return applypatch
