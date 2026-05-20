local core = require "core"
local common = require "core.common"
local config = require "core.config"
local http = require "core.http"
local json = require "core.json"
local permission = require "plugins.assistant.permission"

---Shared helpers used by assistant tool implementations.
---
---This module centralizes project-root checks, write confirmation, process
---formatting, HTTP helpers, and compact display formatting so individual tool
---modules stay small.
---@class assistant.tool_context
local context = {}

context.OUTPUT_LIMIT = 128 * 1024
context.FILE_CHUNK_SIZE = 64 * 1024
context.OMITTED_TOOL_ARGUMENT_PATTERN = "^%[omitted %d+ bytes from prior tool argument `[^`]+`%]$"

local confirm_write

---Yield to Pragtical's UI loop when running inside a coroutine.
function context.yield_ui()
  if coroutine.isyieldable() then
    core.redraw = true
    coroutine.yield()
  end
end

---Normalize normalize.
---@param path string|nil
---@return string|nil
function context.normalize(path)
  if not path or path == "" then return nil end
  local absolute = path
  if not path:match("^/") and not path:match("^%a:[/\\]") then
    absolute = core.project_absolute_path(path)
  end
  return common.normalize_path(absolute) or absolute
end

---Handle project root for.
---@param path string
---@return string|nil
function context.project_root_for(path)
  path = context.normalize(path)
  if not path then return nil end
  for _, project in ipairs(core.projects or {}) do
    local root = common.normalize_path(project.path) or project.path
    if path == root or common.path_belongs_to(path, root) then
      return root
    end
  end
  return nil
end

---Handle project roots text.
---@return string
function context.project_roots_text()
  local roots = {}
  for _, project in ipairs(core.projects or {}) do
    if project.path and project.path ~= "" then
      table.insert(roots, common.normalize_path(project.path) or project.path)
    end
  end
  if #roots == 0 then return "none" end
  return table.concat(roots, ", ")
end

---Handle project roots.
---@return string[] roots
function context.project_roots()
  local roots = {}
  for _, project in ipairs(core.projects or {}) do
    if project.path and project.path ~= "" then
      table.insert(roots, common.normalize_path(project.path) or project.path)
    end
  end
  return roots
end

---Read root for.
function context.read_root_for(path)
  path = context.normalize(path)
  if not path then return nil end
  return context.project_root_for(path)
end

---Handle assert project path.
---@param path string
---@return string|nil absolute
---@return string|nil err
function context.assert_project_path(path)
  local absolute = context.normalize(path)
  if not absolute then return nil, "missing path" end
  if not context.project_root_for(absolute) then
    return nil, "path is outside loaded project roots: " .. absolute .. "\nAllowed project roots: " .. context.project_roots_text()
  end
  return absolute
end

---Handle assert read path.
---@param path string
---@return string|nil absolute
---@return string|nil err
function context.assert_read_path(path)
  local absolute = context.normalize(path)
  if not absolute then return nil, "missing path" end
  if not context.read_root_for(absolute) then
    if config.plugins.assistant and config.plugins.assistant.allow_any_read_path then
      return absolute
    end
    if context.confirm("read_path", absolute, "Read outside loaded project roots") then
      return absolute
    end
    return nil, "user denied reading outside loaded project roots: " .. absolute
  end
  return absolute
end

---Read path allowed without confirmation.
function context.read_path_allowed_without_confirmation(path)
  local absolute = context.normalize(path)
  if not absolute then return false end
  if context.read_root_for(absolute) then return true end
  local conf = config.plugins.assistant or {}
  return conf.allow_any_read_path == true
end

---Read path requires approval.
function context.read_path_requires_approval(arguments, key)
  return not context.read_path_allowed_without_confirmation(arguments and arguments[key])
end

---Read file.
---@param path string
---@return string|nil text
---@return string|nil err
function context.read_file(path)
  local fp, err = io.open(path, "rb")
  if not fp then return nil, err end
  local chunks = {}
  while true do
    local chunk = fp:read(context.FILE_CHUNK_SIZE)
    if not chunk then break end
    table.insert(chunks, chunk)
    context.yield_ui()
  end
  fp:close()
  context.yield_ui()
  return table.concat(chunks)
end

---Write file.
---@param path string
---@param text string
---@return boolean ok
---@return string|nil err
function context.write_file(path, text)
  local parent = path:match("^(.*)" .. PATHSEP .. "[^" .. PATHSEP .. "]+$")
  if parent and parent ~= "" then
    common.mkdirp(parent)
  end
  local fp, err = io.open(path, "wb")
  if not fp then return false, err end
  text = tostring(text or "")
  for index = 1, #text, context.FILE_CHUNK_SIZE do
    fp:write(text:sub(index, index + context.FILE_CHUNK_SIZE - 1))
    context.yield_ui()
  end
  fp:close()
  context.yield_ui()
  return true
end

---Return whether hash text is available.
function context.hash_text(text)
  local hash = 2166136261
  for i = 1, #text do
    hash = (hash * 16777619 + text:byte(i)) % 4294967296
    if i % 4096 == 0 then context.yield_ui() end
  end
  return string.format("%08x", hash)
end

---Handle split lines.
function context.split_lines(text)
  local lines = {}
  for line in ((text or "") .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, line)
    if #lines % 200 == 0 then context.yield_ui() end
  end
  if text and text:sub(-1) == "\n" then table.remove(lines) end
  return lines
end

---Handle optional text.
function context.optional_text(value)
  if value == nil then return nil end
  value = tostring(value)
  local normalized = value:lower():gsub("^%s+", ""):gsub("%s+$", "")
  if normalized == "" or normalized == "none" or normalized == "null" or normalized == "nil" then
    return nil
  end
  return value
end

---Handle contains omitted tool argument.
function context.contains_omitted_tool_argument(value)
  if type(value) == "string" and value:match(context.OMITTED_TOOL_ARGUMENT_PATTERN) then
    return true
  end
  if type(value) == "table"
    and type(value.prior_tool_call_summary) == "string"
    and value.omitted_content_bytes ~= nil
  then
    return true
  end
  if type(value) ~= "table" then return false end
  for _, item in pairs(value) do
    if context.contains_omitted_tool_argument(item) then return true end
  end
  return false
end

---Handle limit text.
function context.limit_text(text, limit)
  limit = tonumber(limit) or context.OUTPUT_LIMIT
  text = tostring(text or "")
  if #text <= limit then
    return text, false, 0, #text
  end
  return text:sub(1, limit) .. string.format("\n... truncated %d bytes ...", #text - limit),
    true,
    #text - limit,
    #text
end

---Handle limited.
function context.limited(text, limit)
  local output = context.limit_text(text, limit)
  return output
end

---Compact provider text result.
---@param result any
---@param label string
---@return string
function context.compact_provider_text_result(result, label)
  result = tostring(result or "")
  local limit = 48000
  if #result <= limit then return result end
  local head = result:sub(1, 32000)
  local tail = result:sub(-8000)
  return table.concat({
    tostring(label or "tool result") .. " compacted for provider context",
    "bytes: " .. tostring(#result),
    "hash: " .. context.hash_text(result),
    "",
    head,
    "",
    string.format("... omitted %d bytes from tool result ...", math.max(0, #result - #head - #tail)),
    "",
    tail
  }, "\n")
end

---Handle project relative.
function context.project_relative(path)
  local root = context.project_root_for(path)
  return root and common.relative_path(root, path) or tostring(path or "")
end

---Handle edit summary.
function context.edit_summary(action, absolute, old_text, new_text)
  old_text = tostring(old_text or "")
  new_text = tostring(new_text or "")
  local lines = {
    string.format("%s: %s", action, context.project_relative(absolute)),
    string.format("bytes: %d -> %d", #old_text, #new_text)
  }
  if old_text ~= "" then
    table.insert(lines, "old_hash: " .. context.hash_text(old_text))
  end
  table.insert(lines, "new_hash: " .. context.hash_text(new_text))
  return table.concat(lines, "\n")
end

---Handle process output.
function context.process_output(proc, max_output_tokens)
  local stdout, stderr = {}, {}
  while true do
    local out = proc:read_stdout(4096)
    if not out or out == "" then break end
    table.insert(stdout, out)
  end
  while true do
    local errout = proc:read_stderr(4096)
    if not errout or errout == "" then break end
    table.insert(stderr, errout)
  end
  local limit = tonumber(max_output_tokens) or context.OUTPUT_LIMIT
  local out_text, out_truncated, out_omitted, out_bytes = context.limit_text(table.concat(stdout), limit)
  local err_text, err_truncated, err_omitted, err_bytes = context.limit_text(table.concat(stderr), limit)
  return {
    stdout = out_text,
    stderr = err_text,
    stdout_bytes = out_bytes,
    stderr_bytes = err_bytes,
    stdout_truncated = out_truncated,
    stderr_truncated = err_truncated,
    stdout_omitted_bytes = out_omitted,
    stderr_omitted_bytes = err_omitted
  }
end

---Format process result.
function context.format_process_result(result)
  return string.format(
    "exit_code: %s\ntimed_out: %s\nwall_time_ms: %s\nsession_id: %s\nstdout_bytes: %s\nstderr_bytes: %s\nstdout_truncated: %s\nstderr_truncated: %s\nstdout:\n%s\nstderr:\n%s",
    tostring(result.exit_code),
    tostring(result.timed_out == true),
    tostring(result.wall_time_ms or ""),
    tostring(result.session_id or ""),
    tostring(result.stdout_bytes or ""),
    tostring(result.stderr_bytes or ""),
    tostring(result.stdout_truncated == true),
    tostring(result.stderr_truncated == true),
    result.stdout or "",
    result.stderr or ""
  )
end

---Handle run process.
---@param command string|string[]
---@param cwd string|nil
---@param timeout_ms integer|nil
---@return boolean ok
---@return table|string result
function context.run_process(command, cwd, timeout_ms)
  local proc, err = process.start(command, {
    cwd = cwd,
    timeout = timeout_ms or 30000,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
    stdin = process.REDIRECT_DISCARD
  })
  if not proc then
    return false, "could not start process: " .. tostring(err)
  end
  local stdout, stderr = {}, {}
  local started = system.get_time()
  while true do
    local out = proc:read_stdout(4096)
    local errout = proc:read_stderr(4096)
    if out and out ~= "" then table.insert(stdout, out) end
    if errout and errout ~= "" then table.insert(stderr, errout) end
    local code = proc:wait(0)
    if code ~= nil then
      local out_text, out_truncated, out_omitted, out_bytes = context.limit_text(table.concat(stdout))
      local err_text, err_truncated, err_omitted, err_bytes = context.limit_text(table.concat(stderr))
      return true, {
        exit_code = code,
        timed_out = false,
        wall_time_ms = math.floor((system.get_time() - started) * 1000),
        stdout = out_text,
        stderr = err_text,
        stdout_bytes = out_bytes,
        stderr_bytes = err_bytes,
        stdout_truncated = out_truncated,
        stderr_truncated = err_truncated,
        stdout_omitted_bytes = out_omitted,
        stderr_omitted_bytes = err_omitted
      }
    end
    if timeout_ms and (system.get_time() - started) * 1000 >= timeout_ms then
      proc:kill()
      local out_text, out_truncated, out_omitted, out_bytes = context.limit_text(table.concat(stdout))
      local err_text, err_truncated, err_omitted, err_bytes = context.limit_text(table.concat(stderr))
      return false, {
        exit_code = -1,
        timed_out = true,
        wall_time_ms = math.floor((system.get_time() - started) * 1000),
        stdout = out_text,
        stderr = err_text,
        stdout_bytes = out_bytes,
        stderr_bytes = err_bytes,
        stdout_truncated = out_truncated,
        stderr_truncated = err_truncated,
        stdout_omitted_bytes = out_omitted,
        stderr_omitted_bytes = err_omitted
      }
    end
    context.yield_ui()
  end
end

---Handle shell command.
function context.shell_command(command)
  local shell = os.getenv("SHELL") or "/bin/sh"
  return { shell, "-c", command }
end

---Parse url.
function context.parse_url(url)
  url = tostring(url or "")
  local protocol, host = url:match("^(https?)://([^/:?#]+)")
  if not protocol then return nil, "invalid URL: expected http:// or https://" end
  return {
    protocol = protocol,
    host = host
  }
end

---Handle urlencode.
function context.urlencode(str)
  if not str then return "" end
  return (tostring(str):gsub("([^%w%-._~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

---Handle configured web timeout.
function context.configured_web_timeout(timeout_ms)
  return (tonumber(timeout_ms) or tonumber(config.plugins.assistant.web_timeout_ms) or 10000) / 1000
end

---Handle host allowed.
function context.host_allowed(host)
  local allow = config.plugins.assistant and config.plugins.assistant.web_allow_hosts
  if type(allow) == "string" then
    for item in allow:gmatch("[^,%s]+") do
      if item == host then return true end
    end
  elseif type(allow) == "table" then
    for _, item in ipairs(allow) do
      if item == host then return true end
    end
  end
  return false
end

---Handle web request requires approval.
function context.web_request_requires_approval(arguments)
  local url = context.optional_text(arguments and (arguments.url or config.plugins.assistant.web_search_url))
  if not url then return false end
  local parsed = context.parse_url(url)
  return not (parsed and context.host_allowed(parsed.host))
end

---Handle command requires approval.
function context.command_requires_approval(arguments)
  local classification = permission.classify_command(
    arguments and arguments.command,
    arguments and arguments.cwd,
    context.project_roots()
  )
  return permission.requires_approval(classification)
end

---Normalize headers.
function context.normalize_headers(headers)
  if type(headers) == "table" then return headers end
  if type(headers) == "string" and headers ~= "" then
    local decoded = json.decode(headers)
    if type(decoded) == "table" then return decoded end
  end
  return {}
end

---Handle http request.
---@param method string
---@param url string
---@param headers table|string|nil
---@param body string|nil
---@param timeout_ms integer|nil
---@return boolean ok
---@return table|string result
function context.http_request(method, url, headers, body, timeout_ms)
  local done = false
  local cancelled = false
  local result_ok, result_err, result_body, result_info
  local timeout = context.configured_web_timeout(timeout_ms)
  local started = system.get_time()
  http.request(method, url, {
    headers = context.normalize_headers(headers),
    body = context.optional_text(body),
    decode_json = false,
    timeout = timeout,
    is_cancelled = function() return cancelled end,
    on_done = function(ok, err, result, info)
      result_ok = ok
      result_err = err
      result_body = result
      result_info = info
      done = true
    end
  })
  while not done do
    if system.get_time() - started >= timeout then
      cancelled = true
      return false, "web request timed out", nil, { url = url }
    end
    context.yield_ui()
  end
  return result_ok, result_err, result_body, result_info
end

---Format headers.
function context.format_headers(headers)
  local out = {}
  for key, value in pairs(headers or {}) do
    if type(value) == "table" then value = table.concat(value, ", ") end
    table.insert(out, tostring(key) .. ": " .. tostring(value))
  end
  table.sort(out)
  return table.concat(out, "\n")
end

---Handle extract path.
function context.extract_path(value, path)
  path = context.optional_text(path)
  if not path then return value end
  for part in path:gmatch("[^%.]+") do
    if type(value) ~= "table" then return nil end
    local index = tonumber(part)
    value = index and value[index] or value[part]
  end
  return value
end

---Handle looks like html.
function context.looks_like_html(text)
  text = tostring(text or ""):sub(1, 512):lower()
  return text:find("<!doctype%s+html")
    or text:find("<html[%s>]")
    or text:find("<head[%s>]")
    or text:find("<body[%s>]")
end

---Handle git command.
function context.git_command(...)
  return { "git", ... }
end

---Set the confirm write.
---@param callback fun(action: string, path: string, details?: string): boolean
---@return function|nil previous
function context.set_confirm_write(callback)
  local previous = confirm_write
  confirm_write = callback
  return previous
end

---Handle confirm.
---@param action string
---@param path string
---@param details string|nil
---@return boolean
function context.confirm(action, path, details)
  if confirm_write then
    return confirm_write(action, path, details)
  end
  core.warn("Assistant: tool action '%s' denied for %s; no confirmation handler installed.", action, path)
  return false
end

return context
