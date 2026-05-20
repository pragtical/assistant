local core = require "core"
local common = require "core.common"
local config = require "core.config"
local json = require "core.json"
local jsonutil = require "plugins.assistant.jsonutil"
local Backend = require "plugins.assistant.backend"
local Conversation = require "plugins.assistant.conversation"
local assistant_tools = require "plugins.assistant.tools"
local tool_context = require "plugins.assistant.tool_context"
local transport = require "plugins.assistant.backend.transport"

---Agent Client Protocol backend.
---@class assistant.backend.AcpBackend : assistant.Backend
---@field transport assistant.transport|nil
---@field initialized boolean
---@field next_id integer
---@field pending table
local AcpBackend = Backend:extend()

local READ_SIZE = 1024 * 8
local WRITE_SIZE = 64 * 1024
local SEND_REQUEST_TIMEOUT = 600
local UI_UPDATE_INTERVAL = 0.08

---Handle yield ui.
local function yield_ui(delay)
  if coroutine.isyieldable() then
    core.redraw = true
    coroutine.yield(delay)
  end
end

---Handle debug log.
local function debug_log(...)
  local conf = config.plugins.assistant or {}
  if conf.debug then core.log(...) end
end

---Handle protocol log.
local function protocol_log(...)
  local conf = config.plugins.assistant or {}
  if conf.debug then core.log(...) end
end

---Handle raw logging enabled.
local function raw_logging_enabled()
  local conf = config.plugins.assistant or {}
  return conf.log_raw_messages ~= false
end

---Return whether reasoning activity messages are enabled.
---@return boolean enabled
local function reasoning_activity_messages_enabled()
  local conf = config.plugins and config.plugins.assistant or {}
  return conf.reasoning_activity_messages ~= false
end

---Append raw message.
local function append_raw_message(conversation, kind, message)
  if raw_logging_enabled() and conversation and conversation.append_raw_response then
    conversation:append_raw_response(kind, message)
  end
end

---Append protocol log.
local function append_protocol_log(agent, conversation, direction, message)
  local conf = config.plugins.assistant or {}
  if not conf.log_protocol then return end
  local project_dir = conversation and conversation.project_dir
    or (core.root_project() and core.root_project().path)
    or "."
  local dir = Conversation.logs_dir(project_dir)
  local info = system.get_file_info(dir)
  if not (info and info.type == "dir") then
    local ok, err = common.mkdirp(dir)
    if not ok then
      core.error("Assistant: could not create protocol log directory %s: %s", dir, err)
      return
    end
  end
  local path = Conversation.log_path(project_dir, agent and agent.name or "acp")
  local fp, err = io.open(path, "ab")
  if not fp then
    core.error("Assistant: could not write protocol log %s: %s", path, err)
    return
  end
  local line = jsonutil.encode({
    at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    direction = direction,
    message = message
  }) .. "\n"
  for index = 1, #line, WRITE_SIZE do
    fp:write(line:sub(index, index + WRITE_SIZE - 1))
    yield_ui()
  end
  fp:close()
end

---Parse jsonl.
local function parse_jsonl(buffer, on_message)
  while true do
    local idx = buffer:find("\n", 1, true)
    if not idx then break end
    local line = buffer:sub(1, idx - 1)
    buffer = buffer:sub(idx + 1)
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end
    if line ~= "" then
      local ok, msg = pcall(json.decode, line)
      if ok and type(msg) == "table" then
        on_message(msg)
      else
        protocol_log("Assistant ACP parse failed: %s", tostring(msg))
      end
    end
  end
  return buffer
end

---Handle request key.
local function request_key(id)
  if id == nil then return nil end
  return tostring(id)
end

---Handle response error text.
local function response_error_text(msg)
  local err = msg and msg.error
  if not err then return nil end
  if type(err) == "table" then
    local text = tostring(err.message or err.code or "request failed")
    if err.data ~= nil then
      local ok, data = pcall(jsonutil.encode, err.data)
      text = text .. ": " .. (ok and data or tostring(err.data))
    end
    return text
  end
  return tostring(err)
end

---Handle stale session error.
local function stale_session_error(text)
  text = tostring(text or ""):lower()
  return text:find("session", 1, true) ~= nil
    and text:find("not found", 1, true) ~= nil
end

---Handle capture response.
local function capture_response(state, msg)
  if msg and msg.method ~= nil then return false end
  local key = request_key(msg and msg.id)
  if not key or not state.pending[key] then return false end
  state.responses[key] = msg
  state.pending[key] = nil
  if msg.error then
    local err = response_error_text(msg)
    if state.allow_stale_session_retry and not state.did_retry_stale_session and stale_session_error(err) then
      state.stale_session = true
      state.did_retry_stale_session = true
    else
      state.error = err
    end
  end
  return true
end

---Handle project roots text.
local function project_roots_text()
  local roots = {}
  for _, project in ipairs(core.projects or {}) do
    if project.path and project.path ~= "" then
      table.insert(roots, common.normalize_path(project.path) or project.path)
    end
  end
  return #roots > 0 and table.concat(roots, ", ") or "none"
end

---Normalize path.
local function normalize_path(path, conversation)
  if not path or path == "" then return nil end
  local absolute = path
  if not path:match("^/") and not path:match("^%a:[/\\]") then
    absolute = (conversation and conversation.project_dir or ".") .. PATHSEP .. path
  end
  return common.normalize_path(absolute) or absolute
end

---Handle project root for.
local function project_root_for(path)
  for _, project in ipairs(core.projects or {}) do
    local root = common.normalize_path(project.path) or project.path
    if path == root or common.path_belongs_to(path, root) then return root end
  end
end

---Handle assert project path.
local function assert_project_path(path, conversation, read_only)
  local absolute = normalize_path(path, conversation)
  if not absolute then return nil, "missing path" end
  if project_root_for(absolute) then return absolute end
  if read_only and config.plugins.assistant and config.plugins.assistant.allow_any_read_path then
    return absolute
  end
  return nil, "path is outside loaded project roots: " .. absolute .. "\nAllowed project roots: " .. project_roots_text()
end

---Handle last user message.
local function last_user_message(conversation)
  for i = #conversation.messages, 1, -1 do
    local message = conversation.messages[i]
    if message.role == "user" then return message.message or "" end
  end
  return ""
end

---Handle shell quote.
local function shell_quote(text)
  text = tostring(text or "")
  if text:match("^[%w%._%-%/:=]+$") then return text end
  return "'" .. text:gsub("'", "'\\''") .. "'"
end

---Handle command text.
local function command_text(params)
  local command = params and (params.command or params.cmd or params.program)
  if type(command) == "table" then
    local parts = {}
    for _, part in ipairs(command) do table.insert(parts, shell_quote(part)) end
    return table.concat(parts, " ")
  end
  local args = params and params.args
  if type(args) == "table" then
    local parts = { shell_quote(command or "") }
    for _, arg in ipairs(args) do table.insert(parts, shell_quote(arg)) end
    return table.concat(parts, " ")
  end
  return tostring(command or "")
end

---Handle first text.
local function first_text(...)
  for i = 1, select("#", ...) do
    local value = select(i, ...)
    if value ~= nil and value ~= "" then return tostring(value) end
  end
end

---Add unique line.
local function add_unique_line(lines, seen, label, value)
  if value == nil or value == "" then return end
  value = tostring(value)
  local line = label and (label .. ": " .. value) or value
  if seen[line] then return end
  seen[line] = true
  table.insert(lines, line)
end

---Handle permission request body.
local function permission_request_body(params)
  local tool_call = params.toolCall or params.tool_call or {}
  local raw_input = tool_call.rawInput or tool_call.raw_input or params.rawInput or {}
  local lines = {}
  local seen = {}

  add_unique_line(lines, seen, nil, first_text(params.description, params.reason, tool_call.description))
  add_unique_line(lines, seen, "Kind", tool_call.kind or params.kind)
  add_unique_line(lines, seen, "Command", params.command or raw_input.command or raw_input.cmd)
  add_unique_line(lines, seen, "Query", raw_input.query)
  add_unique_line(lines, seen, "Path", raw_input.path or raw_input.uri)

  if type(tool_call.locations) == "table" then
    for _, location in ipairs(tool_call.locations) do
      if type(location) == "table" then
        add_unique_line(lines, seen, "Path", location.path or location.uri)
      end
    end
  elseif type(params.locations) == "table" then
    for _, location in ipairs(params.locations) do
      if type(location) == "table" then
        add_unique_line(lines, seen, "Path", location.path or location.uri)
      end
    end
  end

  if #lines == 0 then return "Approve this assistant action?" end
  return table.concat(lines, "\n")
end

---Handle approval denied.
local function approval_denied(decision)
  decision = tostring(decision or ""):lower()
  return decision == "deny"
    or decision == "denied"
    or decision == "decline"
    or decision == "reject"
    or decision == "rejected"
    or decision == "no"
    or decision == "cancel"
    or decision == "cancelled"
end

---Handle option field.
local function option_field(option, field)
  if type(option) ~= "table" then return nil end
  local value = option[field]
  return value ~= nil and tostring(value) or nil
end

---Handle option matches.
local function option_matches(option, patterns)
  local text = table.concat({
    option_field(option, "optionId") or "",
    option_field(option, "id") or "",
    option_field(option, "kind") or "",
    option_field(option, "name") or "",
    option_field(option, "value") or ""
  }, " "):lower()
  for _, pattern in ipairs(patterns) do
    if text:find(pattern, 1, true) then return true end
  end
  return false
end

---Handle approval option id.
local function approval_option_id(options, allow)
  if type(options) ~= "table" then return nil end
  local wanted = allow and { "allow", "approve", "accept" } or { "reject", "deny", "decline" }
  local avoided = allow and { "reject", "deny", "decline" } or { "allow", "approve", "accept" }
  for _, option in ipairs(options) do
    if option_matches(option, wanted) then
      return option.optionId or option.id or option.value or option.kind or option.name
    end
  end
  for _, option in ipairs(options) do
    if type(option) == "table" and not option_matches(option, avoided) then
      return option.optionId or option.id or option.value or option.kind or option.name
    end
  end
end

---Handle response text from update.
local function response_text_from_update(update)
  if type(update) ~= "table" then return nil end
  local value = update.text or update.delta or update.content or update.message
  if type(value) == "string" then return value end
  if type(value) == "table" then
    if type(value.text) == "string" then return value.text end
    local parts = {}
    for _, item in ipairs(value) do
      if type(item) == "string" then
        table.insert(parts, item)
      elseif type(item) == "table" and type(item.text) == "string" then
        table.insert(parts, item.text)
      end
    end
    if #parts > 0 then return table.concat(parts) end
  end
end

---Update kind.
local function update_kind(update)
  if type(update) ~= "table" then return nil end
  return update.sessionUpdate or update.type or update.update or update.kind
end

---Set the status.
local function set_status(conversation, status)
  if conversation.status ~= status then
    conversation:set_status(status, { autosave = false })
  end
end

---Handle emit update.
local function emit_update(callback, state, response, meta, force)
  local now = system.get_time()
  if not force and now - (state.last_ui_update or 0) < UI_UPDATE_INTERVAL then
    state.pending_response = response
    state.pending_meta = meta
    return
  end
  state.last_ui_update = now
  state.pending_response = nil
  state.pending_meta = nil
  callback(true, nil, response, meta)
end

---Handle flush ui update.
local function flush_ui_update(callback, state)
  if state.pending_meta then
    emit_update(callback, state, state.pending_response or state.response, state.pending_meta, true)
  end
end

---Return whether pending interaction is available.
local function has_pending_interaction(state)
  for _ in pairs(state.pending_requests or {}) do return true end
  return false
end

---Handle short path.
local function short_path(path)
  path = tostring(path or "")
  if path == "" then return nil end
  local home = os.getenv("HOME")
  if home and home ~= "" and (path == home or path:sub(1, #home + 1) == home .. PATHSEP) then
    path = "~" .. path:sub(#home + 1)
  end
  if #path <= 90 then return path end
  return "..." .. path:sub(-87)
end

---Handle display limited.
local function display_limited(text, limit)
  text = tostring(text or "")
  limit = limit or 12000
  if #text <= limit then return text end
  return text:sub(1, limit) .. "\n\n... truncated for transcript ..."
end

---Handle fenced.
local function fenced(text, language)
  return "```" .. (language or "text") .. "\n" .. display_limited(text) .. "\n```"
end

---Handle looks like diff.
local function looks_like_diff(text)
  text = tostring(text or "")
  return text:find("\ndiff %-%-git ", 1, false)
    or text:find("^diff %-%-git ", 1, false)
    or (text:find("\n@@", 1, true) and text:find("\n--- ", 1, true) and text:find("\n+++ ", 1, true))
end

---Handle activity path.
local function activity_path(call)
  if type(call) ~= "table" then return nil end
  local raw = call.rawInput or call.raw_input or call.input or {}
  if type(raw) == "table" and (raw.path or raw.uri) then return raw.path or raw.uri end
  if type(call.locations) == "table" then
    for _, location in ipairs(call.locations) do
      if type(location) == "table" and (location.path or location.uri) then
        return location.path or location.uri
      end
    end
  end
end

---Add activity.
local function add_activity(conversation, text, key)
  text = tostring(text or "")
  if text == "" then return end
  local last = conversation:last()
  if last
    and last.role == "activity"
    and (last.message == text or (key and last.meta and last.meta.acp_activity_key == key))
  then
    return
  end
  conversation:add("activity", text, {
    autosave = false,
    meta = {
      acp_activity = true,
      acp_activity_key = key
    }
  })
end

---Handle tool activity text.
local function tool_activity_text(update)
  local call = update.toolCall or update.tool_call or update.call or update
  local title = first_text(call.title, update.title, call.name, call.tool, "ACP tool activity")
  local lines = { title }
  local path = short_path(activity_path(call) or activity_path(update))
  if path then table.insert(lines, "Path: " .. path) end
  local status = call.status or update.status
  if status and status ~= "" then table.insert(lines, "Status: " .. tostring(status)) end
  local raw_output = call.rawOutput or call.raw_output or update.rawOutput or update.raw_output
  if type(raw_output) == "table" then
    add_unique_line(lines, {}, "Message", raw_output.message)
    add_unique_line(lines, {}, "Code", raw_output.code)
    if type(raw_output.detailedContent) == "string"
      and raw_output.detailedContent ~= ""
      and looks_like_diff(raw_output.detailedContent)
    then
      table.insert(lines, "")
      table.insert(lines, fenced(raw_output.detailedContent, "diff"))
    end
  elseif raw_output ~= nil and raw_output ~= "" then
    if looks_like_diff(raw_output) then
      table.insert(lines, "")
      table.insert(lines, fenced(raw_output, "diff"))
    else
      add_unique_line(lines, {}, "Output", raw_output)
    end
  end
  return table.concat(lines, "\n")
end

---Handle merged tool update.
local function merged_tool_update(state, update)
  local id = update.toolCallId or update.tool_call_id or update.id
  state.acp_tool_calls = state.acp_tool_calls or {}
  local prior = id and state.acp_tool_calls[tostring(id)] or nil
  if not prior then
    if id then state.acp_tool_calls[tostring(id)] = update end
    return update
  end
  local merged = common.merge({}, prior)
  merged = common.merge(merged, update)
  if id then state.acp_tool_calls[tostring(id)] = merged end
  return merged
end

---Create a new instance.
function AcpBackend:new()
  self.super.new(self, "acp")
  self.transport = nil
  self.next_id = 1
  self.initialized = false
  self.server_capabilities = {}
  self.supports_modes = false
  self.auth_methods = nil
  self.client_info = nil
  self.active_session_id = nil
  self.pending_requests = {}
  self.terminals = {}
  self.next_terminal_id = 1
end

---Stop the ACP transport and clear session state.
function AcpBackend:close()
  if self.transport then self.transport:stop() end
  self.transport = nil
  self.initialized = false
  self.server_capabilities = {}
  self.supports_modes = false
  self.auth_methods = nil
  self.client_info = nil
  self.active_session_id = nil
  self.pending_requests = {}
  self.terminals = {}
end

---Request cancellation for the active ACP session.
function AcpBackend:cancel()
  if self.active_session_id and self.transport and self.transport:is_running() then
    self:notify("session/cancel", { sessionId = self.active_session_id })
  end
  AcpBackend.super.cancel(self)
end

---Start the configured ACP transport.
---@param agent assistant.agent.Acp
---@param conversation assistant.Conversation|table?
---@return boolean ok
---@return string? errmsg
function AcpBackend:start(agent, conversation)
  if self.transport and self.transport:is_running() then return true end
  local options = {
    command = agent.command,
    transport = agent.transport or "stdio",
    host = agent.host,
    port = agent.port,
    env = agent.env,
    cwd = conversation and conversation.project_dir or (core.root_project() and core.root_project().path) or "."
  }
  self.transport = transport.new(options)
  if self.transport.startup_error then
    return false, self.transport.startup_error
  end
  local started = system.get_time()
  while self.transport:is_starting() do
    if system.get_time() - started > 10 then
      return false, "timed out starting ACP transport"
    end
    yield_ui(0.02)
  end
  if self.transport.startup_error then
    return false, self.transport.startup_error
  end
  if not self.transport:is_running() then
    return false, "ACP transport stopped"
  end
  self.next_id = 1
  return true
end

---Write one JSON-RPC message to the ACP transport.
---@param message table
---@param agent assistant.agent.Acp?
---@param conversation assistant.Conversation|table?
---@return boolean ok
---@return string? errmsg
function AcpBackend:write_message(message, agent, conversation)
  if not (self.transport and self.transport:is_running()) then
    return false, "ACP transport is not running"
  end
  local data = jsonutil.encode(message) .. "\n"
  protocol_log("Assistant ACP -> %s", data)
  append_protocol_log(agent, conversation, "send", message)
  append_raw_message(conversation, "acp-send", message)
  local total = 0
  local failures = 0
  while total < #data do
    local written, err = self.transport:write(data:sub(total + 1, total + WRITE_SIZE))
    if err then return false, err end
    written = tonumber(written) or 0
    total = total + written
    if written <= 0 then
      failures = failures + 1
      if failures > 20 then return false, "ACP write made no progress" end
      yield_ui((failures * 5) / 1000)
    else
      failures = 0
      yield_ui()
    end
  end
  return true
end

---Send a JSON-RPC request to the ACP server.
---@param method string
---@param params table?
---@param agent assistant.agent.Acp?
---@param conversation assistant.Conversation|table?
---@return integer? id
---@return string? errmsg
function AcpBackend:request(method, params, agent, conversation)
  local id = self.next_id
  self.next_id = self.next_id + 1
  local message = { jsonrpc = "2.0", id = id, method = method, params = params or {} }
  local ok, err = self:write_message(message, agent, conversation)
  if not ok then return nil, err end
  return id
end

---Send a JSON-RPC notification to the ACP server.
---@param method string
---@param params table?
---@param agent assistant.agent.Acp?
---@param conversation assistant.Conversation|table?
---@return boolean ok
---@return string? errmsg
function AcpBackend:notify(method, params, agent, conversation)
  return self:write_message({ jsonrpc = "2.0", method = method, params = params or {} }, agent, conversation)
end

---Respond to an ACP server request.
---@param id integer|string
---@param result table?
---@param error table|string?
---@param agent assistant.agent.Acp?
---@param conversation assistant.Conversation|table?
---@return boolean ok
---@return string? errmsg
function AcpBackend:respond(id, result, error, agent, conversation)
  if id == nil then return false, "ACP response has no id" end
  local message = { jsonrpc = "2.0", id = id }
  if error then
    message.error = type(error) == "table" and error or { code = -32000, message = tostring(error) }
  else
    message.result = result or {}
  end
  return self:write_message(message, agent, conversation)
end

---Handle initialize params.
local function initialize_params(agent)
  return {
    protocolVersion = 1,
    clientInfo = {
      name = "pragtical-assistant",
      title = "Pragtical Assistant",
      version = "0.1.0"
    },
    clientCapabilities = agent.client_capabilities or {
      fs = { readTextFile = true, writeTextFile = true },
      terminal = true
    }
  }
end

---Handle advertised modes.
local function advertised_modes(result)
  ---Handle mode label.
  local function mode_label(id, fallback)
    local suffix = tostring(id or ""):match("#([^#]+)$") or id
    if suffix == "agent" then return "Implementation" end
    if suffix == "plan" then return "Plan" end
    if suffix == "autopilot" then return "Autopilot" end
    return fallback or id
  end

  if type(result) == "table" and type(result.modes) == "table" then
    local available = result.modes.availableModes or result.modes.available_modes
    if type(available) == "table" then
      local out = {}
      for _, mode in ipairs(available) do
        if type(mode) == "table" then
          local id = mode.id or mode.mode or mode.name
          if id then
            table.insert(out, {
              id = id,
              label = mode_label(id, mode.name or mode.label or mode.title),
              mode = mode.mode
            })
          end
        elseif type(mode) == "string" then
          table.insert(out, { id = mode, label = mode_label(mode) })
        end
      end
      if #out > 0 then return out end
    end
  end
  local capabilities = type(result) == "table"
    and (result.agentCapabilities or result.capabilities or result.serverCapabilities)
    or nil
  local modes = capabilities and (capabilities.modes or capabilities.collaborationModes or capabilities.sessionModes)
  if type(modes) ~= "table" then return nil end
  local out = {}
  for _, mode in ipairs(modes) do
    if type(mode) == "table" then
      local id = mode.id or mode.mode or mode.name
      if id then
        table.insert(out, {
          id = id,
          label = mode_label(id, mode.label or mode.title or mode.name),
          mode = mode.mode
        })
      end
    elseif type(mode) == "string" then
      table.insert(out, { id = mode, label = mode_label(mode) })
    end
  end
  return #out > 0 and out or nil
end

---Handle flatten select options.
local function flatten_select_options(options, out)
  out = out or {}
  if type(options) ~= "table" then return out end
  for _, item in ipairs(options) do
    if type(item) == "table" then
      if type(item.options) == "table" then
        flatten_select_options(item.options, out)
      elseif item.value ~= nil then
        table.insert(out, item)
      end
    end
  end
  return out
end

---Handle option category.
local function option_category(option)
  if type(option) ~= "table" then return nil end
  local category = option.category or option.kind
  if type(category) == "table" then
    category = category.category or category.type or category.id
  end
  return category
end

---Handle model options from config.
local function model_options_from_config(config_options)
  local labels = {}
  local mapping = {}
  if type(config_options) ~= "table" then return labels, mapping end
  for _, option in ipairs(config_options) do
    if type(option) == "table"
      and option.type == "select"
      and option_category(option) == "model"
    then
      local config_id = option.id or option.configId or option.config_id
      if config_id then
        for _, value in ipairs(flatten_select_options(option.options)) do
          local raw_value = value.value or value.id
          local label = value.name or value.label or raw_value
          if raw_value ~= nil and label ~= nil and label ~= "" then
            label = tostring(label)
            table.insert(labels, label)
            mapping[label] = {
              config_id = config_id,
              value = tostring(raw_value)
            }
          end
        end
      end
    end
  end
  table.sort(labels)
  return labels, mapping
end

---Handle remember config options.
local function remember_config_options(agent, config_options)
  local labels, mapping = model_options_from_config(config_options)
  if #labels > 0 then
    agent.acp_model_options = mapping
    return labels
  end
  return {}
end

---Handle selected model option.
local function selected_model_option(agent)
  if not (agent and agent.model and agent.model ~= "") then return nil end
  local options = agent.acp_model_options
  return type(options) == "table" and options[agent.model] or nil
end

---Handle select current config option.
local function select_current_config_option(config_options, category)
  if type(config_options) ~= "table" then return nil end
  for _, option in ipairs(config_options) do
    if type(option) == "table"
      and option.type == "select"
      and option_category(option) == category
    then
      local current = option.currentValue or option.current_value or option.value
      if current ~= nil then return option, tostring(current) end
    end
  end
end

---Handle select option label.
local function select_option_label(select_option, raw_value)
  if type(select_option) ~= "table" or raw_value == nil then return nil end
  for _, option in ipairs(flatten_select_options(select_option.options)) do
    local value = option.value or option.id
    if value ~= nil and tostring(value) == tostring(raw_value) then
      return option.name or option.label or tostring(value)
    end
  end
end

---Handle mode label.
local function mode_label(mode)
  mode = tostring(mode or "")
  local suffix = mode:match("#([^#]+)$") or mode
  if suffix == "agent" or suffix == "default" or suffix == "implementation" then return "Implementation" end
  if suffix == "plan" then return "Plan" end
  if suffix == "autopilot" then return "Autopilot" end
  if suffix == "" then return "Mode" end
  return suffix:sub(1, 1):upper() .. suffix:sub(2)
end

---Handle collaboration modes from config.
local function collaboration_modes_from_config(config_options)
  local modes = {}
  if type(config_options) ~= "table" then return modes end
  for _, option in ipairs(config_options) do
    if type(option) == "table"
      and option.type == "select"
      and option_category(option) == "mode"
    then
      for _, value in ipairs(flatten_select_options(option.options)) do
        local raw_value = value.value or value.id
        if raw_value ~= nil then
          table.insert(modes, {
            id = tostring(raw_value),
            label = value.name or value.label or mode_label(raw_value)
          })
        end
      end
    end
  end
  return modes
end

---Handle sync current config.
local function sync_current_config(agent, conversation, config_options)
  remember_config_options(agent, config_options)

  local model_option, model_value = select_current_config_option(config_options, "model")
  if model_option and model_value and agent then
    local label = select_option_label(model_option, model_value)
    if label and label ~= "" then agent.model = tostring(label) end
  end

  local modes = collaboration_modes_from_config(config_options)
  if #modes > 0 and agent then
    agent.collaboration_modes = modes
    agent.collaboration_modes_by_id = agent.collaboration_modes_by_id or {}
    for _, option in ipairs(modes) do
      agent.collaboration_modes_by_id[option.id] = option
    end
  end

  local _, mode_value = select_current_config_option(config_options, "mode")
  if mode_value and conversation then
    conversation.collaboration_mode = mode_value
  end
end

---Handle text content block.
local function text_content_block(text)
  return {
    type = "text",
    text = tostring(text or "")
  }
end

---Handle auth hint.
local function auth_hint(methods)
  if type(methods) ~= "table" or #methods == 0 then return nil end
  local method = methods[1]
  if type(method) ~= "table" then return nil end
  local meta = type(method._meta) == "table" and method._meta or {}
  local terminal_auth = type(meta["terminal-auth"]) == "table" and meta["terminal-auth"] or nil
  if terminal_auth then
    local command = terminal_auth.command
    local args = terminal_auth.args
    if type(command) == "string" and command ~= "" then
      local parts = { command }
      if type(args) == "table" then
        for _, arg in ipairs(args) do table.insert(parts, tostring(arg)) end
      end
      return "Run `" .. table.concat(parts, " ") .. "`."
    end
  end
  if method.description and method.description ~= "" then
    return method.description
  end
  if method.name and method.name ~= "" then
    return method.name
  end
end

---Handle authentication error text.
local function authentication_error_text(methods)
  local hint = auth_hint(methods)
  return hint and ("Authentication required. " .. hint) or "Authentication required"
end

---Handle client-side ACP requests such as file, terminal, and permission calls.
---@param agent assistant.agent.Acp
---@param conversation assistant.Conversation
---@param msg table
---@param state table
---@param callback function
---@return boolean handled
function AcpBackend:handle_client_request(agent, conversation, msg, state, callback)
  local method = msg.method
  local params = msg.params or {}
  if method == "fs/read_text_file" or method == "fs/readTextFile" then
    local path, err = assert_project_path(params.path or params.uri, conversation, true)
    if not path then
      self:respond(msg.id, nil, err, agent, conversation)
      return true
    end
    local data, read_err = tool_context.read_file(path)
    self:respond(msg.id, read_err and nil or { content = data or "" }, read_err, agent, conversation)
    return true
  elseif method == "fs/write_text_file" or method == "fs/writeTextFile" then
    if agent:normalize_collaboration_mode(conversation.collaboration_mode) == "plan" then
      self:respond(msg.id, nil, "filesystem writes are denied in Plan mode", agent, conversation)
      return true
    end
    local path, err = assert_project_path(params.path or params.uri, conversation, false)
    if not path then
      self:respond(msg.id, nil, err, agent, conversation)
      return true
    end
    local contents = params.content or params.text or ""
    local ok, write_err = assistant_tools.write(path, contents)
    self:respond(msg.id, ok and { ok = true } or nil, write_err, agent, conversation)
    return true
  elseif method == "terminal/create" then
    if agent:normalize_collaboration_mode(conversation.collaboration_mode) == "plan" then
      self:respond(msg.id, nil, "terminal execution is denied in Plan mode", agent, conversation)
      return true
    end
    local cmd = command_text(params)
    local ok, result = assistant_tools.exec_command(
      cmd,
      params.cwd or conversation.project_dir,
      nil,
      nil,
      nil,
      params.timeout_ms or params.timeoutMs or 30000
    )
    local id = "terminal-" .. tostring(self.next_terminal_id)
    self.next_terminal_id = self.next_terminal_id + 1
    self.terminals[id] = { output = result or "", exit_code = ok and 0 or 1 }
    self:respond(msg.id, { terminalId = id, id = id }, nil, agent, conversation)
    return true
  elseif method == "terminal/output" or method == "terminal/wait_for_exit" or method == "terminal/waitForExit" then
    local id = params.terminalId or params.id
    local terminal = self.terminals[id] or { output = "", exit_code = 0 }
    self:respond(msg.id, {
      output = terminal.output,
      exitCode = terminal.exit_code,
      exited = true
    }, nil, agent, conversation)
    return true
  elseif method == "terminal/kill" or method == "terminal/release" then
    self.terminals[params.terminalId or params.id] = nil
    self:respond(msg.id, { ok = true }, nil, agent, conversation)
    return true
  elseif method == "session/request_permission" or method == "session/requestPermission" then
    local request_id = request_key(msg.id)
    local tool_call = params.toolCall or params.tool_call or {}
    local options = params.options or params.availableDecisions
    local request = {
      id = request_id,
      provider_id = msg.id,
      title = first_text(params.title, tool_call.title, params.kind, "ACP permission request"),
      description = first_text(params.description, params.reason, params.command, ""),
      body = permission_request_body(params),
      options = options,
      raw = msg,
      state = state
    }
    state.pending_requests[request_id] = request
    self.pending_requests[request_id] = { agent = agent, conversation = conversation, request = request }
    set_status(conversation, "waiting for approval")
    add_activity(conversation, "Permission requested: " .. request.title .. "\n" .. request.body, "permission:" .. tostring(request_id))
    emit_update(callback, state, state.response, {
      partial = true,
      event = "approval_request",
      request = request
    }, true)
    return true
  end
  return false
end

---Handle one ACP message or session update from the server.
---@param agent assistant.agent.Acp
---@param conversation assistant.Conversation
---@param msg table
---@param state table
---@param callback function
function AcpBackend:handle_update(agent, conversation, msg, state, callback)
  append_raw_message(conversation, "acp-recv", msg)
  append_protocol_log(agent, conversation, "recv", msg)
  if capture_response(state, msg) then return end
  if msg.id ~= nil and msg.method and self:handle_client_request(agent, conversation, msg, state, callback) then
    return
  end
  local params = msg.params or {}
  local update = params.update or params.sessionUpdate or params
  local kind = update_kind(update) or msg.method
  local usage = agent.parse_usage and agent:parse_usage(update)
  if usage then
    state.usage = usage
    conversation:set_usage(usage)
    emit_update(callback, state, state.response, {
      partial = true,
      event = "activity_update",
      usage = usage
    }, true)
  end
  if msg.method == "session/update" or msg.method == "sessionUpdate" then
    if kind == "agent_message_chunk" or kind == "agentMessageChunk" or kind == "message_chunk" then
      if not has_pending_interaction(state) then
        set_status(conversation, "responding")
      end
      local text = response_text_from_update(update)
      if text and text ~= "" then
        state.has_response = true
        state.response = state.response .. text
        emit_update(callback, state, state.response, { partial = true })
      end
    elseif kind == "plan" or kind == "plan_update" or kind == "planUpdate" then
      set_status(conversation, "reasoning")
      local text = response_text_from_update(update)
      if text and text ~= "" then
        state.response = text
        emit_update(callback, state, state.response, { partial = true }, true)
      end
    elseif kind == "agent_thought_chunk" or kind == "agentThoughtChunk" or kind == "thought" or kind == "thought_chunk" then
      set_status(conversation, "reasoning")
      local text = response_text_from_update(update)
      if text and text ~= "" and reasoning_activity_messages_enabled() then
        add_activity(conversation, "Thinking: " .. text, "thought:" .. text)
        emit_update(callback, state, state.response, {
          partial = true,
          event = "activity_update"
        }, true)
      end
    elseif kind == "tool_call" or kind == "toolCall" then
      local call = update.toolCall or update.call or update
      local id = call.toolCallId or call.tool_call_id or call.id or update.toolCallId or update.id
      if id then
        state.acp_tool_calls = state.acp_tool_calls or {}
        state.acp_tool_calls[tostring(id)] = update
      end
      if call.name or call.tool or call.arguments or call.input then
        conversation:add("tool_call", agent:tool_call_display({
          name = call.name or call.tool or "acp_tool",
          arguments = call.arguments or call.input or {},
          arguments_text = type(call.arguments) == "string" and call.arguments or jsonutil.encode(call.arguments or call.input or {})
        }), { autosave = false })
      else
        add_activity(conversation, tool_activity_text(update), "tool:" .. tostring(call.toolCallId or call.id or call.title or update.title))
      end
    elseif kind == "tool_call_update" or kind == "toolCallUpdate" then
      set_status(conversation, "working")
      local merged = merged_tool_update(state, update)
      add_activity(conversation, tool_activity_text(merged), "tool-update:" .. tostring(update.toolCallId or update.id or update.title))
    elseif kind == "session_title" or kind == "sessionTitle" then
      if update.title and update.title ~= "" then conversation.title = update.title end
    elseif kind == "available_commands_update" or kind == "availableCommandsUpdate" then
      state.available_commands = update.commands
    elseif kind == "config_option_update" or kind == "configOptionUpdate" then
      sync_current_config(agent, conversation, update.configOptions or update.config_options or update.options)
      emit_update(callback, state, state.response, {
        partial = true,
        event = "config_update"
      }, true)
    elseif kind == "current_mode_update" or kind == "currentModeUpdate" then
      if update.modeId or update.mode then conversation.collaboration_mode = update.modeId or update.mode end
    elseif kind == "done" or kind == "completed" then
      state.done = true
    end
  elseif msg.method == "session/request_permission" or msg.method == "session/requestPermission" then
    self:handle_client_request(agent, conversation, msg, state, callback)
  elseif msg.method == "error" then
    local err = params.error or msg.error
    state.error = type(err) == "table" and err.message or err or "ACP error"
  end
end

---Initialize the ACP connection if it has not been initialized yet.
---@param agent assistant.agent.Acp
---@param conversation assistant.Conversation|table
---@param state table
---@return boolean ok
---@return string? errmsg
function AcpBackend:ensure_initialized(agent, conversation, state)
  if self.initialized then return true end
  local id, err = self:request("initialize", initialize_params(agent), agent, conversation)
  if not id then return false, err end
  state.pending[tostring(id)] = true
  state.initialize_id = id
  return true
end

---Send the latest user prompt to the ACP session and stream updates.
---@param agent assistant.agent.Acp
---@param conversation assistant.Conversation
---@param callback fun(ok: boolean, errmsg?: string, response?: string, meta?: table)
function AcpBackend:send(agent, conversation, callback)
  self:begin_request()
  agent:set_loading(true)
  set_status(conversation, "starting")
  local ok, errmsg = self:start(agent, conversation)
  if not ok then
    agent:set_loading(false)
    self:finish_request()
    set_status(conversation, "error")
    callback(false, errmsg or "could not start ACP agent")
    return
  end
  core.add_thread(function()
    local buffer = ""
    local stderr = {}
    local state = {
      pending = {},
      responses = {},
      pending_requests = {},
      response = "",
      error = nil,
      done = false,
      has_response = false,
      allow_stale_session_retry = true,
      started_at = system.get_time(),
      last_activity_at = system.get_time()
    }
    local ok_init, init_err = self:ensure_initialized(agent, conversation, state)
    if not ok_init then state.error = init_err end
    local session_request_id
    local mode_request_id
    local prompt_request_id

    while self.transport and self.transport:is_running() and not self:is_cancelled() and not state.error and not state.done do
      local out = self.transport:read(READ_SIZE)
      if out and out ~= "" then
        state.last_activity_at = system.get_time()
        buffer = parse_jsonl(buffer .. out, function(msg)
          protocol_log("Assistant ACP <- %s", jsonutil.encode(msg))
          self:handle_update(agent, conversation, msg, state, callback)
        end)
        flush_ui_update(callback, state)
      end
      if state.stale_session then
        add_activity(conversation, "Previous ACP session was not found; starting a new session.", "session-recovery")
        conversation.acp_session_id = nil
        self.active_session_id = nil
        session_request_id = nil
        mode_request_id = nil
        prompt_request_id = nil
        state.model_config_request_id = nil
        state.stale_session = nil
        set_status(conversation, "starting")
      end
      local err = self.transport:read_stderr(READ_SIZE)
      if err and err ~= "" then
        state.last_activity_at = system.get_time()
        table.insert(stderr, err)
        debug_log("Assistant ACP stderr: %s", err)
      end
      if state.initialize_id and state.responses[tostring(state.initialize_id)] and not state.did_initialize then
        local response = state.responses[tostring(state.initialize_id)]
        self.initialized = true
        self.server_capabilities = response.result and (response.result.agentCapabilities or response.result.capabilities or response.result.serverCapabilities) or {}
        self.auth_methods = response.result and response.result.authMethods or nil
        local modes = advertised_modes(response.result)
        if modes then
          agent.collaboration_modes = modes
          self.supports_modes = true
        end
        state.did_initialize = true
      end
      if self.initialized and not conversation.acp_session_id and not session_request_id then
        session_request_id = self:request("session/new", {
          cwd = conversation.project_dir,
          mcpServers = jsonutil.empty_array,
          model = agent.model ~= "" and agent.model or nil
        }, agent, conversation)
        if session_request_id then
          state.pending[tostring(session_request_id)] = true
          state.last_activity_at = system.get_time()
        end
      end
      if session_request_id and state.responses[tostring(session_request_id)] and not conversation.acp_session_id then
        local result = state.responses[tostring(session_request_id)].result or {}
        conversation.acp_session_id = result.sessionId or result.session_id or result.id
        self.active_session_id = conversation.acp_session_id
        remember_config_options(agent, result.configOptions)
        local modes = advertised_modes(result)
        if modes then
          agent.collaboration_modes = modes
          self.supports_modes = true
        end
      elseif conversation.acp_session_id then
        self.active_session_id = conversation.acp_session_id
      end
      if self.active_session_id
        and not state.model_config_request_id
        and selected_model_option(agent)
      then
        local option = selected_model_option(agent)
        state.model_config_request_id = self:request("session/set_config_option", {
          sessionId = self.active_session_id,
          configId = option.config_id,
          value = option.value
        }, agent, conversation)
        if state.model_config_request_id then
          state.pending[tostring(state.model_config_request_id)] = true
          state.last_activity_at = system.get_time()
        end
      end
      if self.active_session_id
        and self.supports_modes
        and conversation.collaboration_mode
        and conversation.collaboration_mode ~= ""
        and not mode_request_id
      then
        mode_request_id = self:request("session/set_mode", {
          sessionId = self.active_session_id,
          modeId = agent:build_collaboration_mode(conversation.collaboration_mode)
        }, agent, conversation)
        if mode_request_id then
          state.pending[tostring(mode_request_id)] = true
          state.last_activity_at = system.get_time()
        end
      end
      local model_done = not state.model_config_request_id or state.responses[tostring(state.model_config_request_id)]
      local mode_done = not mode_request_id or state.responses[tostring(mode_request_id)]
      if self.active_session_id and model_done and mode_done and not prompt_request_id then
        prompt_request_id = self:request("session/prompt", {
          sessionId = self.active_session_id,
          prompt = { text_content_block(last_user_message(conversation)) }
        }, agent, conversation)
        if prompt_request_id then
          state.pending[tostring(prompt_request_id)] = true
          state.last_activity_at = system.get_time()
        end
        set_status(conversation, "working")
      end
      if prompt_request_id
        and state.responses[tostring(prompt_request_id)]
        and not has_pending_interaction(state)
      then
        state.done = true
      end
      if not has_pending_interaction(state)
        and system.get_time() - (state.last_activity_at or state.started_at) > SEND_REQUEST_TIMEOUT
      then
        state.error = string.format("ACP request timed out after %ds without activity", SEND_REQUEST_TIMEOUT)
      end
      yield_ui(0.02)
    end

    flush_ui_update(callback, state)
    agent:set_loading(false)
    self:finish_request()

    if self:is_cancelled() then
      set_status(conversation, "cancelled")
      callback(false, "request cancelled")
    elseif state.error then
      set_status(conversation, "error")
      if state.error == "Authentication required" then
        local message = authentication_error_text(self.auth_methods)
        add_activity(conversation, message, "auth-required")
        callback(false, message)
      else
        callback(false, state.error)
      end
    elseif state.response == "" and not state.has_response then
      set_status(conversation, "error")
      callback(false, "ACP session completed without an assistant response" .. (#stderr > 0 and (": " .. table.concat(stderr)) or ""))
    else
      set_status(conversation, "idle")
      callback(true, nil, state.response, {
        done = true,
        session_id = conversation.acp_session_id,
        usage = state.usage
      })
    end
  end)
end

---Resolve a pending ACP permission request.
---@param agent assistant.agent.Acp
---@param conversation assistant.Conversation
---@param request table
---@param decision string?
---@param callback fun(ok: boolean, errmsg?: string)?
function AcpBackend:resolve_approval(agent, conversation, request, decision, callback)
  if not request or request.provider_id == nil then
    if callback then callback(false, "approval request has no provider id") end
    return
  end
  local denied = approval_denied(decision)
  local option_id = approval_option_id(request.options, not denied)
  local result = option_id and {
    outcome = {
      outcome = "selected",
      optionId = option_id
    }
  } or {
    outcome = {
      outcome = denied and "cancelled" or "selected"
    }
  }
  local sent, err = self:respond(request.provider_id, result, nil, agent, conversation)
  if sent then
    self.pending_requests[request.id] = nil
    if request.state and request.state.pending_requests then
      request.state.pending_requests[request.id] = nil
    end
    if conversation then set_status(conversation, "working") end
  end
  if callback then callback(sent, err) end
end

---Resolve a pending ACP user-input request.
---@param agent assistant.agent.Acp
---@param conversation assistant.Conversation
---@param request table
---@param ok boolean
---@param answers table?
---@param callback fun(ok: boolean, errmsg?: string)?
function AcpBackend:resolve_user_input(agent, conversation, request, ok, answers, callback)
  if not request or request.provider_id == nil then
    if callback then callback(false, "user input request has no provider id") end
    return
  end
  local sent, err = self:respond(request.provider_id, {
    cancelled = ok == false,
    answers = answers or {}
  }, nil, agent, conversation)
  if sent then
    self.pending_requests[request.id] = nil
    if request.state and request.state.pending_requests then
      request.state.pending_requests[request.id] = nil
    end
    if conversation then set_status(conversation, "working") end
  end
  if callback then callback(sent, err) end
end

---List locally known ACP collaboration modes.
---@param agent assistant.agent.Acp
---@param callback fun(ok: boolean, errmsg?: string, modes?: table[])
function AcpBackend:list_collaboration_modes(agent, callback)
  callback(true, nil, agent:get_collaboration_modes())
end

---List ACP model options by starting a temporary session.
---@param agent assistant.agent.Acp
---@param callback fun(ok: boolean, errmsg?: string, models?: string[])
function AcpBackend:list_models(agent, callback)
  self:begin_request()
  agent:set_loading(true)

  local project = core.root_project() and core.root_project().path or "."
  local log_conversation = { project_dir = project }
  local ok, errmsg = self:start(agent, log_conversation)
  if not ok then
    self:finish_request()
    agent:set_loading(false)
    callback(false, errmsg or "could not start ACP agent")
    return
  end

  core.add_thread(function()
    local buffer = ""
    local state = {
      pending = {},
      responses = {},
      pending_requests = {},
      response = "",
      error = nil,
      started_at = system.get_time()
    }
    local ok_init, init_err = self:ensure_initialized(agent, log_conversation, state)
    if not ok_init then state.error = init_err end
    local session_request_id

    while self.transport and self.transport:is_running() and not self:is_cancelled() and not state.error do
      local out = self.transport:read(READ_SIZE)
      if out and out ~= "" then
        buffer = parse_jsonl(buffer .. out, function(msg)
          protocol_log("Assistant ACP <- %s", jsonutil.encode(msg))
          append_raw_message(log_conversation, "acp-recv", msg)
          append_protocol_log(agent, log_conversation, "recv", msg)
          capture_response(state, msg)
        end)
      end
      local err = self.transport:read_stderr(READ_SIZE)
      if err and err ~= "" then debug_log("Assistant ACP stderr: %s", err) end
      if state.initialize_id and state.responses[tostring(state.initialize_id)] and not state.did_initialize then
        local response = state.responses[tostring(state.initialize_id)]
        self.initialized = true
        self.server_capabilities = response.result and (response.result.agentCapabilities or response.result.capabilities or response.result.serverCapabilities) or {}
        self.auth_methods = response.result and response.result.authMethods or nil
        state.did_initialize = true
      end
      if self.initialized and not session_request_id then
        session_request_id = self:request("session/new", {
          cwd = project,
          mcpServers = jsonutil.empty_array
        }, agent, log_conversation)
        if session_request_id then state.pending[tostring(session_request_id)] = true end
      end
      if session_request_id and state.responses[tostring(session_request_id)] then
        break
      end
      if system.get_time() - state.started_at > 15 then
        state.error = "ACP model listing timed out"
      end
      yield_ui(0.02)
    end

    self:finish_request()
    agent:set_loading(false)

    if self:is_cancelled() then
      callback(false, "request cancelled")
    elseif state.error then
      callback(false, state.error == "Authentication required" and authentication_error_text(self.auth_methods) or state.error)
    else
      local response = session_request_id and state.responses[tostring(session_request_id)]
      local result = response and response.result or {}
      local models = remember_config_options(agent, result.configOptions)
      if #models == 0 then
        callback(false, "ACP session did not report model config options")
      else
        callback(true, nil, models)
      end
    end
  end)
end

return AcpBackend
