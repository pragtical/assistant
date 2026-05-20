local core = require "core"
local config = require "core.config"
local json = require "core.json"
local jsonutil = require "plugins.assistant.jsonutil"
local Backend = require "plugins.assistant.backend"
local Conversation = require "plugins.assistant.conversation"

---Persistent JSON-RPC app-server backend.
---@class assistant.backend.AppServerBackend : assistant.Backend
---@field proc process|nil
---@field initialized boolean
---@field next_id integer
---@field pending table
local AppServerBackend = Backend:extend()

local READ_SIZE = 1024 * 8
local WRITE_SIZE = 64 * 1024
local SEND_REQUEST_TIMEOUT = 600
local UI_UPDATE_INTERVAL = 0.08
local RAW_RESPONSE_FLUSH_INTERVAL = 0.5
local RAW_RESPONSE_FLUSH_COUNT = 25

---Handle debug log.
local function debug_log(...)
  local conf = config.plugins.assistant or {}
  if conf.debug then
    core.log(...)
  end
end

---Handle protocol log.
local function protocol_log(...)
  local conf = config.plugins.assistant or {}
  if conf.debug then
    core.log(...)
  end
end

---Write chunks.
local function write_chunks(writer, text)
  text = tostring(text or "")
  for index = 1, #text, WRITE_SIZE do
    writer(text:sub(index, index + WRITE_SIZE - 1))
    if coroutine.isyieldable() then
      core.redraw = true
      coroutine.yield()
    end
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
    local ok, err = require("core.common").mkdirp(dir)
    if not ok then
      core.error("Assistant: could not create protocol log directory %s: %s", dir, err)
      return
    end
  end
  local path = Conversation.log_path(project_dir, agent and agent.name or "appserver")
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
  write_chunks(function(chunk)
    fp:write(chunk)
  end, line)
  fp:close()
end

---Handle raw logging enabled.
local function raw_logging_enabled()
  local conf = config.plugins.assistant or {}
  return conf.log_raw_messages ~= false
end

---Append raw message.
local function append_raw_message(conversation, kind, message)
  if conversation and type(conversation.append_raw_response) == "function" then
    conversation:append_raw_response(kind, message)
  end
end

---Create a new instance.
function AppServerBackend:new()
  self.super.new(self, "appserver")
  self.proc = nil
  self.next_id = 1
  self.initialized = false
  self.last_model_response = nil
  self.active_thread_id = nil
  self.active_turn_id = nil
  self.interrupting = false
end

---Request cancellation for the active turn or terminate the backend request.
function AppServerBackend:cancel()
  if self.proc and self.proc:running() and self.active_thread_id and self.active_turn_id then
    self.interrupting = true
    self:request("turn/interrupt", {
      threadId = self.active_thread_id,
      turnId = self.active_turn_id
    })
    return
  end
  AppServerBackend.super.cancel(self)
  if self.proc and self.proc:running() then
    self.proc:terminate()
  end
end

---Stop the app-server process and clear cached request state.
function AppServerBackend:close()
  if self.proc and self.proc:running() then
    self.proc:terminate()
  end
  self.proc = nil
  self.initialized = false
  self.last_model_response = nil
  self.active_thread_id = nil
  self.active_turn_id = nil
  self.interrupting = false
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
      local ok, message = pcall(json.decode, line)
      if not ok then
        protocol_log("Assistant app-server parse failed: %s", tostring(message))
      elseif type(message) == "table" then
        on_message(message)
      end
    end
  end
  return buffer
end

---Handle request key.
local function request_key(id)
  if id == nil then return nil end
  if type(id) == "number" then return tostring(id) end
  if type(id) == "string" then return id end
  return tostring(id)
end

---Handle request id from message.
local function request_id_from_message(message)
  local params = type(message) == "table" and message.params or nil
  local request = params and type(params.request) == "table" and params.request or nil
  ---Handle present.
  local function present(value)
    if value ~= nil and value ~= "" then
      return tostring(value)
    end
  end
  return present(message and message.id)
    or present(params and params.id)
    or present(params and params.requestId)
    or present(params and params.request_id)
    or present(params and params.serverRequestId)
    or present(params and params.server_request_id)
    or present(params and params.callId)
    or present(params and params.itemId)
    or present(params and params.turnId)
    or present(params and params.threadId)
    or present(request and request.id)
    or present(request and request.requestId)
end

---Handle track request.
local function track_request(state, id)
  local key = request_key(id)
  if key then state.pending[key] = true end
  return key
end

---Handle track response.
local function track_response(state, id)
  local key = request_key(id)
  if key then return state.responses[key], key end
  return nil
end

---Handle capture response.
local function capture_response(state, msg)
  if type(msg) ~= "table" or msg.id == nil then return false, nil end
  if msg.method ~= nil then return false, nil end
  local key = request_key(msg.id)
  if not key then return false, nil end
  if state.pending[key] then
    state.responses[key] = msg
    if msg.error then
      state.error = msg.error.message or "codex app-server request failed"
    end
    return true, key
  end
  return false, key
end

---Return whether pending interaction is available.
local function has_pending_interaction(state)
  for _ in pairs(state.pending_requests or {}) do return true end
  return false
end

---Handle sandbox policy.
local function sandbox_policy(agent, conversation)
  if agent.sandbox == "read-only" then
    return { type = "readOnly" }
  elseif agent.sandbox == "danger-full-access" then
    return { type = "dangerFullAccess" }
  end
  return {
    type = "workspaceWrite",
    writableRoots = { conversation.project_dir or "." },
    networkAccess = true
  }
end

---Handle shell command.
local function shell_command(command)
  local text = table.concat(command, " ")
  if PLATFORM == "Windows" then
    return { "cmd", "/C", text }
  end
  return { "sh", "-lc", text }
end

---Handle file exists.
local function file_exists(path)
  local info = system.get_file_info(path)
  return info and info.type == "file"
end

---Resolve resolved command.
local function resolved_command(command)
  if command:find("[/\\]") then return command end
  local home = os.getenv("HOME")
  local candidates = {}
  if home and home ~= "" then
    table.insert(candidates, home .. PATHSEP .. "Applications" .. PATHSEP .. "bin" .. PATHSEP .. command)
    table.insert(candidates, home .. PATHSEP .. ".local" .. PATHSEP .. "bin" .. PATHSEP .. command)
    table.insert(candidates, home .. PATHSEP .. "bin" .. PATHSEP .. command)
  end
  table.insert(candidates, "/usr/local/bin/" .. command)
  table.insert(candidates, "/opt/homebrew/bin/" .. command)
  for _, candidate in ipairs(candidates) do
    if file_exists(candidate) then return candidate end
  end
  return command
end

---Send a JSON-RPC request to the app-server.
---@param method string
---@param params table?
---@param agent assistant.agent.Codex?
---@param conversation assistant.Conversation?
---@return integer id
function AppServerBackend:request(method, params, agent, conversation)
  local id = self.next_id
  self.next_id = self.next_id + 1
  local message = { id = id, method = method, params = params or {} }
  local encoded = jsonutil.encode(message)
  protocol_log("Assistant app-server -> %s", encoded)
  append_protocol_log(agent, conversation, "request", message)
  append_raw_message(conversation, "appserver-request", message)
  write_chunks(function(chunk)
    self.proc:write(chunk)
  end, encoded .. "\n")
  return id
end

---Send a JSON-RPC notification to the app-server.
---@param method string
---@param params table?
---@param agent assistant.agent.Codex?
---@param conversation assistant.Conversation?
function AppServerBackend:notify(method, params, agent, conversation)
  local message = { method = method, params = params or {} }
  local encoded = jsonutil.encode(message)
  protocol_log("Assistant app-server -> %s", encoded)
  append_protocol_log(agent, conversation, "notify", message)
  append_raw_message(conversation, "appserver-notify", message)
  write_chunks(function(chunk)
    self.proc:write(chunk)
  end, encoded .. "\n")
end

---Respond to an app-server request that needs client input.
---@param id string|integer
---@param result table?
---@param error table|string?
---@param agent assistant.agent.Codex?
---@param conversation assistant.Conversation?
---@return boolean ok
---@return string? errmsg
function AppServerBackend:respond(id, result, error, agent, conversation)
  if not (self.proc and self.proc:running()) then return false, "codex app-server is not running" end
  local message = { id = id }
  if error then
    message.error = type(error) == "table" and error or { message = tostring(error) }
  else
    message.result = result or {}
  end
  local encoded = jsonutil.encode(message)
  protocol_log("Assistant app-server -> %s", encoded)
  append_protocol_log(agent, conversation, "response", message)
  append_raw_message(conversation, "appserver-response", message)
  write_chunks(function(chunk)
    self.proc:write(chunk)
  end, encoded .. "\n")
  return true
end

---Start the persistent app-server process if needed.
---@param agent assistant.agent.Codex
---@param conversation assistant.Conversation|table
---@return boolean ok
---@return string? errmsg
function AppServerBackend:start_server(agent, conversation)
  if self.proc and self.proc:running() then return true end
  local command = { resolved_command(agent.command), "app-server" }
  local options = {
    cwd = conversation.project_dir or ".",
    stdin = process.REDIRECT_PIPE,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE
  }
  local proc, errmsg = process.start(command, options)
  if not proc then
    proc, errmsg = process.start(command, {
      cwd = conversation.project_dir or ".",
      stderr = process.REDIRECT_PIPE
    })
  end
  if not proc then
    proc, errmsg = process.start(shell_command(command), options)
  end
  if not proc then
    proc, errmsg = process.start(shell_command(command))
  end
  if not proc then
    return false, string.format(
      "%s while starting `%s`",
      errmsg or "could not start process",
      table.concat(command, " ")
    )
  end
  self.proc = proc
  self.next_id = 1
  self.initialized = false
  debug_log("Assistant app-server started: %s", table.concat(command, " "))
  return true
end

---Handle diagnostic message.
local function diagnostic_message(prefix, response_buffer, stderr, proc)
  local parts = { prefix }
  local err = table.concat(stderr):gsub("^%s+", ""):gsub("%s+$", "")
  if response_buffer and response_buffer ~= "" then
    table.insert(parts, "stdout=" .. response_buffer)
  end
  if err ~= "" then
    table.insert(parts, "stderr=" .. err)
  end
  if proc and proc.returncode then
    local code = proc:returncode()
    if code ~= nil then table.insert(parts, "exit=" .. tostring(code)) end
  end
  return table.concat(parts, "; ")
end

---Return true when the app-server process is running and initialized.
---@return boolean
function AppServerBackend:ready()
  return self.proc and self.proc:running() and self.initialized
end

---Handle defer until idle.
local function defer_until_idle(self, callback, timeout)
  timeout = timeout or 30
  core.add_thread(function()
    local started = system.get_time()
    while self.active and system.get_time() - started < timeout do
      coroutine.yield(0.05)
    end
    if self.active then
      callback(false, "codex app-server is busy")
      return
    end
    callback(true)
  end)
end

---Handle initialize params.
local function initialize_params()
  return {
    capabilities = {
      experimentalApi = true
    },
    clientInfo = {
      name = "pragtical-assistant",
      title = "Pragtical Assistant",
      version = "0.1.0"
    }
  }
end

---Handle wait for response.
local function wait_for_response(self, agent, method, params, callback, parse_result)
  if self.active then
    defer_until_idle(self, function(ok, err)
      if ok then
        wait_for_response(self, agent, method, params, callback, parse_result)
      else
        callback(false, err)
      end
    end)
    return
  end

  self:begin_request()
  agent:set_loading(true)

  local project = core.root_project() and core.root_project().path or "."
  local log_conversation = { project_dir = project }
  local ok, errmsg = self:start_server(agent, { project_dir = project })
  if not ok then
    self:finish_request()
    agent:set_loading(false)
    callback(false, errmsg or "could not start codex app-server")
    return
  end

  core.add_thread(function()
    local buffer = ""
    local state = {
      pending = {},
      responses = {},
      error = nil
    }
    local init_id
    if not self.initialized then
      init_id = self:request("initialize", initialize_params(), agent, log_conversation)
      track_request(state, init_id)
    end
    local request_id

    while self.proc and self.proc:running() and not self:is_cancelled() do
      local out = self.proc:read_stdout(READ_SIZE)
      if out and out ~= "" then
        buffer = parse_jsonl(buffer .. out, function(msg)
          protocol_log("Assistant app-server <- %s", jsonutil.encode(msg))
          append_protocol_log(agent, log_conversation, "event", msg)
          if capture_response(state, msg) then
            return
          elseif msg.method == "error" then
            local err = msg.params and msg.params.error or msg.error
            state.error = type(err) == "table" and err.message or err or "codex app-server error"
          end
        end)
      end

      if init_id and track_response(state, init_id) and not state.sent_initialized then
        self.initialized = true
        state.sent_initialized = true
        self:notify("initialized", {}, agent, log_conversation)
      end

      if (self.initialized or not init_id) and not request_id then
        request_id = self:request(method, params or {}, agent, log_conversation)
        track_request(state, request_id)
      end

      if state.error or (request_id and track_response(state, request_id)) then
        break
      end
      coroutine.yield(0.02)
    end

    self:finish_request()
    agent:set_loading(false)

    if self:is_cancelled() then
      callback(false, "request cancelled")
    elseif state.error then
      callback(false, state.error)
    else
      callback(true, nil, parse_result(request_id and track_response(state, request_id)))
    end
  end)
end

---Handle model names from response.
local function model_names_from_response(response)
  local models = {}
  local data = response and response.result and response.result.data
  if type(data) == "table" then
    for _, item in ipairs(data) do
      if type(item) == "table" then
        local model = item.model or item.id or item.displayName
        if model and model ~= "" then table.insert(models, model) end
      elseif type(item) == "string" and item ~= "" then
        table.insert(models, item)
      end
    end
  end
  table.sort(models)
  return models
end

---Handle collaboration modes from response.
local function collaboration_modes_from_response(response)
  local modes = {}
  local result = response and response.result or response
  local data = type(result) == "table" and (result.data or result.modes or result.collaborationModes) or nil
  if type(data) ~= "table" then data = type(result) == "table" and result or nil end
  if type(data) ~= "table" then return modes end
  for _, item in ipairs(data) do
    if type(item) == "table" then
      local id = item.id or item.mode or item.name
      if id then
        table.insert(modes, {
          id = id,
          label = item.displayName or item.title or item.label or item.name or id,
          mode = item.mode,
          model = item.model,
          reasoning_effort = item.reasoning_effort or item.reasoningEffort
        })
      end
    elseif type(item) == "string" then
      table.insert(modes, { id = item, label = item })
    end
  end
  table.sort(modes, function(a, b)
    return tostring(a.label or a.id) < tostring(b.label or b.id)
  end)
  return modes
end

---Warm up and initialize the app-server without sending a user turn.
---@param agent assistant.agent.Codex
---@param conversation assistant.Conversation
---@param callback fun(ok: boolean, errmsg?: string)?
function AppServerBackend:prepare(agent, conversation, callback)
  if self:ready() then
    if callback then callback(true) end
    return
  end
  if self.active then
    if callback then callback(false, "codex app-server is busy") end
    return
  end

  self:begin_request()
  agent:set_loading(true)
  conversation:set_status("starting")

  local ok, errmsg = self:start_server(agent, conversation)
  if not ok then
    self:finish_request()
    agent:set_loading(false)
    conversation:set_status("error")
    if callback then callback(false, errmsg or "could not start codex app-server") end
    return
  end

  core.add_thread(function()
    local buffer = ""
    local stderr = {}
    local state = {
      pending = {},
      responses = {},
      error = nil
    }

    local init_id = self:request("initialize", initialize_params(), agent, conversation)
    track_request(state, init_id)

    local started = system.get_time()
    while self.proc and self.proc:running() and not self:is_cancelled() do
      local out = self.proc:read_stdout(READ_SIZE)
      if out and out ~= "" then
        buffer = parse_jsonl(buffer .. out, function(msg)
          protocol_log("Assistant app-server <- %s", jsonutil.encode(msg)); append_protocol_log(agent, conversation, "event", msg)
          if capture_response(state, msg) then
            return
          elseif msg.method == "error" then
            local err = msg.params and msg.params.error or msg.error
            state.error = type(err) == "table" and err.message or err or "codex app-server error"
          end
        end)
      end
      local err = self.proc:read_stderr(READ_SIZE)
      if err and err ~= "" then table.insert(stderr, err) end
      if err and err ~= "" then debug_log("Assistant app-server stderr: %s", err) end

      if track_response(state, init_id) and not state.sent_initialized then
        self.initialized = true
        state.sent_initialized = true
        self:notify("initialized", {}, agent, conversation)
        break
      end

      if state.error then break end
      if system.get_time() - started > 5 then break end
      coroutine.yield(0.02)
    end

    self:finish_request()
    agent:set_loading(false)

    if self:is_cancelled() then
      conversation:set_status("cancelled")
      if callback then callback(false, "request cancelled") end
    elseif state.error then
      conversation:set_status("error")
      if callback then callback(false, state.error) end
    elseif self:ready() then
      conversation:set_status("idle")
      if callback then callback(true) end
    else
      if callback then
        callback(false, diagnostic_message(
          "codex app-server did not initialize",
          buffer,
          stderr,
          self.proc
        ))
      end
    end
  end)
end

---Handle last user message.
local function last_user_message(conversation)
  for i = #conversation.messages, 1, -1 do
    local message = conversation.messages[i]
    if message.role == "user" then return message.message or "" end
  end
  return ""
end

---Set the conversation status.
local function set_conversation_status(conversation, status)
  if conversation.status ~= status then
    conversation:set_status(status, { autosave = false })
  end
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

---Handle file change activity.
local function file_change_activity(item)
  if type(item) ~= "table" or (item.type ~= "fileChange" and item.type ~= "patch") then return nil end
  local parts = { "Editing files" }
  local changes = item.changes
  if type(changes) ~= "table" then return nil end
  local added = false
  for _, change in ipairs(changes) do
    if type(change) == "table" and type(change.diff) == "string" and change.diff ~= "" then
      local path = change.path or change.uri
      table.insert(parts, "")
      if path and path ~= "" then
        table.insert(parts, "`" .. tostring(path) .. "`")
        table.insert(parts, "")
      end
      table.insert(parts, fenced(change.diff, "diff"))
      added = true
    end
  end
  if not added then return nil end
  return table.concat(parts, "\n")
end

---Handle command text.
local function command_text(item)
  if type(item) ~= "table" then return nil end
  if type(item.command) == "string" and item.command ~= "" then return item.command end
  if type(item.commandLine) == "string" and item.commandLine ~= "" then return item.commandLine end
  if type(item.commandActions) == "table" then
    for _, action in ipairs(item.commandActions) do
      if type(action) == "table" and type(action.command) == "string" and action.command ~= "" then
        return action.command
      end
    end
  end
end

---Handle command status.
local function command_status(item)
  if type(item) ~= "table" then return nil end
  local command = command_text(item)
  if not command then return "running command" end
  return "running command: " .. command
end

---Handle command activity.
local function command_activity(item)
  if type(item) ~= "table" or (item.type ~= "commandExecution" and item.type ~= "command") then return nil end
  local command = command_text(item)
  local parts = { "Running command" }
  if command then
    table.insert(parts, "")
    table.insert(parts, "`" .. command .. "`")
  end
  if item.cwd and item.cwd ~= "" then
    table.insert(parts, "")
    table.insert(parts, "Cwd: `" .. tostring(item.cwd) .. "`")
  end
  if item.status and item.status ~= "" then
    table.insert(parts, "Status: " .. tostring(item.status))
  end
  if item.exitCode ~= nil then
    table.insert(parts, "Exit: " .. tostring(item.exitCode))
  end
  return table.concat(parts, "\n")
end

---Add activity.
local function add_activity(conversation, text, key)
  text = tostring(text or "")
  if text == "" then return end
  local last = conversation:last()
  if last
    and last.role == "activity"
    and (last.message == text or (key and last.meta and last.meta.appserver_activity_key == key))
  then
    return
  end
  conversation:add("activity", text, {
    autosave = false,
    meta = {
      appserver_activity = true,
      appserver_activity_key = key
    }
  })
end

---Compact thread.
local function compact_thread(thread)
  if type(thread) ~= "table" then return thread end
  local compacted = {}
  for key, value in pairs(thread) do
    if key ~= "turns" then compacted[key] = value end
  end
  if type(thread.turns) == "table" then
    compacted.turns = {
      omitted = true,
      count = #thread.turns
    }
  end
  return compacted
end

---Compact appserver message.
local function compact_appserver_message(message)
  if type(message) ~= "table" then return message end
  local result = message.result
  if type(result) ~= "table" or type(result.thread) ~= "table" then return message end
  local compacted = {}
  for key, value in pairs(message) do compacted[key] = value end
  compacted.result = {}
  for key, value in pairs(result) do compacted.result[key] = value end
  compacted.result.thread = compact_thread(result.thread)
  return compacted
end

---Handle queue raw response.
local function queue_raw_response(conversation, state, kind, data)
  if not raw_logging_enabled() then return end
  if not state.raw_responses then
    conversation:append_raw_response(kind, compact_appserver_message(data))
    return
  end
  table.insert(state.raw_responses, {
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    kind = kind,
    data = compact_appserver_message(data)
  })
end

---Handle flush raw responses.
local function flush_raw_responses(conversation, state, force)
  if not (state.raw_responses and #state.raw_responses > 0) then return end
  local now = system.get_time()
  if not force
    and #state.raw_responses < RAW_RESPONSE_FLUSH_COUNT
    and now - (state.last_raw_flush or 0) < RAW_RESPONSE_FLUSH_INTERVAL
  then
    return
  end
  local batch = state.raw_responses
  state.raw_responses = {}
  state.last_raw_flush = now
  conversation:append_raw_responses(batch)
end

---Handle emit update.
local function emit_update(callback, state, response, meta, force)
  local now = system.get_time()
  if not force and now - (state.last_ui_update or 0) < UI_UPDATE_INTERVAL then
    state.pending_ui_response = response
    state.pending_ui_meta = meta
    return
  end
  state.last_ui_update = now
  state.pending_ui_response = nil
  state.pending_ui_meta = nil
  callback(true, nil, response, meta)
end

---Handle flush ui update.
local function flush_ui_update(callback, state)
  if state.pending_ui_meta then
    emit_update(callback, state, state.pending_ui_response or state.response, state.pending_ui_meta, true)
  end
end

---Handle status for item.
local function status_for_item(item)
  if type(item) ~= "table" then return "working" end
  if item.type == "reasoning" then return "reasoning" end
  if item.type == "webSearch" then return "searching" end
  if item.type == "agentMessage" then return "responding" end
  if item.type == "tool" or item.type == "toolCall" or item.type == "toolExecution" then return "running command" end
  if item.type == "commandExecution" or item.type == "command" then return command_status(item) end
  if item.type == "fileChange" or item.type == "patch" then return "editing files" end
  return "working"
end

---Handle apply message.
local function apply_message(agent, conversation, msg, state, callback)
  state.last_activity_at = system.get_time()
  table.insert(state.messages, msg)
  queue_raw_response(conversation, state, "appserver-message", msg)
  if capture_response(state, msg) then
    return
  end

  if msg.method == "item/tool/requestUserInput" then
    local request = agent:normalize_user_input_request(msg)
    if request then
      if request.id ~= nil then
        state.pending_requests[tostring(request.id)] = request
      end
      set_conversation_status(conversation, "waiting for input")
      emit_update(callback, state, state.response, {
        partial = true,
        event = "user_input_request",
        request = request
      }, true)
    else
      state.error = "unsupported user input request"
    end
  elseif msg.method == "item/commandExecution/requestApproval"
    or msg.method == "item/fileChange/requestApproval"
    or msg.method == "item/permissions/requestApproval"
    or msg.method == "item/tool/requestApproval"
    or msg.method == "item/tool/call/requestApproval"
    or msg.method == "execCommandApproval"
    or msg.method == "applyPatchApproval"
  then
    local request = agent:normalize_approval_request(msg)
    if request then
      if request.id ~= nil then
        state.pending_requests[tostring(request.id)] = request
      end
      set_conversation_status(conversation, "waiting for approval")
      emit_update(callback, state, state.response, {
        partial = true,
        event = "approval_request",
        request = request
      }, true)
    else
      state.error = "unsupported approval request"
    end
  elseif msg.method == "serverRequest/resolved" then
    local request_id = request_id_from_message(msg)
    local pending_request = request_id and state.pending_requests[request_id] or nil
    if request_id and pending_request then
      state.pending_requests[request_id] = nil
    end
    emit_update(callback, state, state.response, {
      partial = true,
      event = "request_resolved",
      request_id = request_id,
      request = pending_request
    }, true)
  elseif msg.method == "thread/started" then
    local thread = msg.params and msg.params.thread
    if thread and thread.id then conversation.codex_thread_id = thread.id end
  elseif msg.method == "turn/plan/updated" then
    set_conversation_status(conversation, "reasoning")
    local params = msg.params or {}
    local plan = params.plan
    if type(plan) == "table" then
      local lines = {}
      if params.explanation and params.explanation ~= "" then
        table.insert(lines, params.explanation)
        table.insert(lines, "")
      end
      for _, item in ipairs(plan) do
        if type(item) == "table" then
          local step = tostring(item.step or "")
          if item.status == "completed" then
            table.insert(lines, string.format("- [x] %s", step))
          elseif item.status == "in_progress" then
            table.insert(lines, string.format("- [ ] **%s** _(in progress)_", step))
          else
            table.insert(lines, string.format("- [ ] %s", step))
          end
        else
          table.insert(lines, "- " .. tostring(item))
        end
      end
      state.response = table.concat(lines, "\n")
      emit_update(callback, state, state.response, { partial = true }, true)
    end
  elseif msg.method == "turn/plan/delta" or msg.method == "item/plan/delta" then
    set_conversation_status(conversation, "reasoning")
    local delta = msg.params and (msg.params.delta or msg.params.text)
    if type(delta) == "string" and delta ~= "" then
      state.has_assistant_response = true
      state.response = state.response .. delta
      emit_update(callback, state, state.response, { partial = true })
    end
  elseif msg.method == "turn/started" then
    set_conversation_status(conversation, "working")
    local turn = msg.params and msg.params.turn
    if msg.params and msg.params.threadId then state.backend.active_thread_id = msg.params.threadId end
    if turn and turn.id then
      state.backend.active_turn_id = turn.id
      state.active_turn_id = turn.id
      state.started_turn = true
    end
  elseif msg.method == "item/agentMessage/delta" then
    set_conversation_status(conversation, "responding")
    local delta = msg.params and (msg.params.delta or msg.params.text)
    if type(delta) == "string" and delta ~= "" then
      state.has_assistant_response = true
      state.response = state.response .. delta
      emit_update(callback, state, state.response, { partial = true })
    end
  elseif msg.method == "item/started" then
    local item = msg.params and msg.params.item
    set_conversation_status(conversation, status_for_item(item))
    if type(item) == "table" and (item.type == "commandExecution" or item.type == "command") then
      add_activity(conversation, command_activity(item), "command:" .. tostring(item.id or "") .. ":started")
      emit_update(callback, state, state.response, {
        partial = true,
        event = "activity_update"
      }, true)
    end
  elseif msg.method == "item/completed" then
    local item = msg.params and msg.params.item
    if type(item) == "table" and item.type == "plan" and type(item.text) == "string" then
      state.has_assistant_response = true
      state.response = item.text
      emit_update(callback, state, state.response, { partial = true }, true)
    elseif type(item) == "table" and item.type == "agentMessage" and type(item.text) == "string" then
      state.has_assistant_response = true
      state.response = item.text
      emit_update(callback, state, state.response, { partial = true }, true)
    elseif type(item) == "table" and (item.type == "fileChange" or item.type == "patch") then
      add_activity(conversation, file_change_activity(item), "file-change:" .. tostring(item.id or ""))
      emit_update(callback, state, state.response, {
        partial = true,
        event = "activity_update"
      }, true)
    elseif type(item) == "table" and (item.type == "commandExecution" or item.type == "command") then
      add_activity(conversation, command_activity(item), "command:" .. tostring(item.id or "") .. ":completed")
      if conversation.status and tostring(conversation.status):find("^running command:", 1, false) then
        set_conversation_status(conversation, "working")
      end
      emit_update(callback, state, state.response, {
        partial = true,
        event = "activity_update"
      }, true)
    end
  elseif msg.method == "item/tool/call" then
    set_conversation_status(conversation, "working")
  elseif msg.method == "item/tool/call/completed" then
    local item = msg.params and msg.params.item
    if type(item) == "table" and type(item.text) == "string" and item.text ~= "" then
      state.response = state.response .. item.text
      emit_update(callback, state, state.response, { partial = true })
    end
  elseif msg.method == "thread/tokenUsage/updated" then
    state.usage = agent:parse_usage(msg.params)
  elseif msg.method == "thread/status/changed" then
    local status = msg.params and msg.params.status
    local raw_status = status
    status = type(status) == "table" and status.type or status
    if status == "active" then
      local flags = type(raw_status) == "table" and raw_status.activeFlags or nil
      local waiting_approval = false
      local waiting_input = false
      for _, flag in ipairs(flags or {}) do
        if flag == "waitingOnApproval" then waiting_approval = true end
        if flag == "waitingOnUserInput" then waiting_input = true end
        if flag == "waitingOnToolApproval" then waiting_approval = true end
        if flag == "waitingOnToolInput" then waiting_input = true end
      end
      if waiting_approval then
        set_conversation_status(conversation, "waiting for approval")
      elseif waiting_input then
        set_conversation_status(conversation, "waiting for input")
      else
        set_conversation_status(conversation, "working")
      end
    elseif status == "interrupted" then
      state.interrupted = true
      state.done = true
      set_conversation_status(conversation, "cancelled")
    elseif status == "ready" and state.started_turn and not state.done and not has_pending_interaction(state) then
      set_conversation_status(conversation, "idle")
      state.done = true
      state.active_turn_id = nil
      state.backend.active_turn_id = nil
    elseif status == "idle" and state.started_turn and not state.done and not has_pending_interaction(state) then
      state.done = true
      set_conversation_status(conversation, "idle")
      state.active_turn_id = nil
      state.backend.active_turn_id = nil
    end
  elseif msg.method == "mcpServer/startupStatus/updated" then
    local params = msg.params or {}
    if params.status == "starting" then
      set_conversation_status(conversation, "starting")
    elseif params.status == "ready" and conversation.status == "starting" then
      set_conversation_status(conversation, "working")
    end
  elseif msg.method == "error" then
    local err = msg.params and msg.params.error or msg.error
    state.error = type(err) == "table" and err.message or err or "codex app-server error"
  elseif msg.method == "turn/completed" then
    local turn = msg.params and msg.params.turn
    if turn and turn.id then state.done_turn_id = turn.id end
    if turn and turn.status == "failed" then
      local err = turn.error
      state.error = type(err) == "table" and err.message or "codex turn failed"
    elseif turn and turn.status == "interrupted" then
      state.interrupted = true
    end
    state.backend.active_thread_id = nil
    state.backend.active_turn_id = nil
    state.backend.interrupting = false
    state.done = true
    state.active_turn_id = nil
  end
end

---Send the latest user message as an app-server turn and stream updates.
---@param agent assistant.agent.Codex
---@param conversation assistant.Conversation
---@param callback fun(ok: boolean, errmsg?: string, response?: string, meta?: table)
function AppServerBackend:send(agent, conversation, callback)
  if self.active then
    defer_until_idle(self, function(ok, err)
      if ok then
        self:send(agent, conversation, callback)
      else
        callback(false, err)
      end
    end)
    return
  end

  self:begin_request()
  agent:set_loading(true)
  conversation:set_status("starting")
  local log_conversation = conversation

  local ok, errmsg = self:start_server(agent, conversation)
  if not ok then
    self:finish_request()
    agent:set_loading(false)
    conversation:set_status("error")
    callback(false, errmsg or "could not start codex app-server")
    return
  end

  core.add_thread(function()
    local buffer = ""
    local stderr = {}
    local state = {
      pending = {},
      responses = {},
      response = "",
      usage = nil,
      error = nil,
      pending_requests = {},
      has_assistant_response = false,
      done = false,
      messages = {},
      interrupted = false,
      started_turn = false,
      active_turn_id = nil,
      started_at = system.get_time(),
      last_activity_at = system.get_time(),
      backend = self
    }

    local init_id
    if not self.initialized then
      init_id = self:request("initialize", initialize_params(), agent, log_conversation)
      track_request(state, init_id)
    end

    local thread_id
    local turn_id
    local started_turn = false

    while self.proc and self.proc:running() and not self:is_cancelled() and not state.done and not state.error do
      local out = self.proc:read_stdout(READ_SIZE)
      if out and out ~= "" then
        buffer = parse_jsonl(buffer .. out, function(msg)
          protocol_log("Assistant app-server <- %s", jsonutil.encode(compact_appserver_message(msg)))
          append_protocol_log(agent, log_conversation, "event", compact_appserver_message(msg))
          apply_message(agent, conversation, msg, state, callback)
        end)
        flush_raw_responses(conversation, state)
        flush_ui_update(callback, state)
      end
      local err = self.proc:read_stderr(READ_SIZE)
      if err and err ~= "" then table.insert(stderr, err) end
      if err and err ~= "" then
        state.last_activity_at = system.get_time()
        debug_log("Assistant app-server stderr: %s", err)
      end

      if init_id and track_response(state, init_id) and not state.sent_initialized then
        self.initialized = true
        state.sent_initialized = true
        self:notify("initialized", {}, agent, log_conversation)
      end

      if (self.initialized or not init_id) and not thread_id then
        local method = conversation.codex_thread_id and "thread/resume" or "thread/start"
        local params
        if method == "thread/resume" then
          params = {
            threadId = conversation.codex_thread_id
          }
        else
          params = {
            model = agent.model ~= "" and agent.model or nil,
            cwd = conversation.project_dir or ".",
            approvalPolicy = agent.approval_policy or "on-request",
            approvalsReviewer = "user",
            sandbox = agent:appserver_sandbox(),
            serviceName = "pragtical_assistant"
          }
        end
        thread_id = self:request(method, params, agent, conversation)
        track_request(state, thread_id)
      end

      local thread_response = thread_id and track_response(state, thread_id)
      if thread_response and not started_turn then
        local thread = thread_response.result and thread_response.result.thread
        if thread and thread.id then conversation.codex_thread_id = thread.id end
        self.active_thread_id = conversation.codex_thread_id
        local params = {
          threadId = conversation.codex_thread_id,
          input = {
            { type = "text", text = last_user_message(conversation) }
          },
          cwd = conversation.project_dir or ".",
          approvalPolicy = agent.approval_policy or "on-request",
          approvalsReviewer = "user",
          sandboxPolicy = sandbox_policy(agent, conversation),
          model = agent.model ~= "" and agent.model or nil
        }
        if conversation.collaboration_mode and conversation.collaboration_mode ~= "" then
          params.collaborationMode = agent:build_collaboration_mode(conversation.collaboration_mode)
        elseif agent.configured_appserver_reasoning_effort then
          params.effort = agent:configured_appserver_reasoning_effort()
        end
        turn_id = self:request("turn/start", params, agent, conversation)
        track_request(state, turn_id)
        started_turn = true
      end

      local turn_response = turn_id and track_response(state, turn_id)
      if turn_response and turn_response.result and turn_response.result.turn then
        local turn = turn_response.result.turn
        if turn.id then
          self.active_turn_id = turn.id
          state.active_turn_id = turn.id
          state.started_turn = true
        end
      end

      local timeout = system.get_time() - (state.last_activity_at or state.started_at)
      if state.started_turn
        and not has_pending_interaction(state)
        and timeout > SEND_REQUEST_TIMEOUT
        and not state.error
        and not state.done
      then
        if not state.interrupt_requested then
          state.interrupt_requested = true
          if self.active_thread_id and state.active_turn_id then
            self:request("turn/interrupt", {
              threadId = self.active_thread_id,
              turnId = state.active_turn_id
            }, agent, log_conversation)
          end
          state.error = string.format("codex app-server turn timed out after %.0fs without activity", timeout)
        else
          break
        end
      end

      if state.error or (state.done and not state.interrupted) then
        break
      end
      if not self.proc:running() then
        state.error = state.error or "codex app-server process stopped unexpectedly"
        break
      end
      coroutine.yield(0.02)
    end

    flush_ui_update(callback, state)
    flush_raw_responses(conversation, state, true)

    if self:is_cancelled() and self.proc and self.proc:running() then
      self.proc:terminate()
    end

    agent:set_loading(false)
    self:finish_request()

    if self:is_cancelled() then
      conversation:set_status("cancelled")
      callback(false, "request cancelled")
    elseif state.interrupted then
      conversation:set_status("cancelled")
      callback(false, "request cancelled")
    elseif state.error then
      conversation:set_status("error")
      callback(false, state.error)
    elseif state.response == "" and not state.has_assistant_response then
      conversation:set_status("error")
      callback(false, diagnostic_message(
        "codex turn completed without an assistant response; messages=" .. jsonutil.encode(state.messages),
        buffer,
        stderr,
        self.proc
      ))
    else
      conversation:set_status("idle")
      callback(true, nil, state.response, {
        done = true,
        usage = state.usage,
        thread_id = conversation.codex_thread_id
      })
    end
  end)
end

---Resolve a pending app-server user-input request.
---@param agent assistant.agent.Codex
---@param conversation assistant.Conversation
---@param request table
---@param ok boolean
---@param answers table?
---@param callback fun(ok: boolean, errmsg?: string)?
function AppServerBackend:resolve_user_input(agent, conversation, request, ok, answers, callback)
  if not request or request.provider_id == nil then
    if callback then callback(false, "user input request has no provider id") end
    return
  end
  local result
  local err
  if ok == false then
    result = agent:format_user_input_response(request, false, {})
  else
    result = agent:format_user_input_response(request, true, answers or {})
  end
  local sent, errmsg = self:respond(request.provider_id, result, err, agent, conversation)
  if sent and conversation then
    conversation:set_status("working")
  end
  if callback then callback(sent, errmsg) end
end

---Resolve a pending app-server approval request.
---@param agent assistant.agent.Codex
---@param conversation assistant.Conversation
---@param request table
---@param decision string?
---@param callback fun(ok: boolean, errmsg?: string)?
function AppServerBackend:resolve_approval(agent, conversation, request, decision, callback)
  if not request or request.provider_id == nil then
    if callback then callback(false, "approval request has no provider id") end
    return
  end
  local result = agent:format_approval_response(request, decision or "decline")
  local sent, errmsg = self:respond(request.provider_id, result, nil, agent, conversation)
  if sent and conversation then
    conversation:set_status("working")
  end
  if callback then callback(sent, errmsg) end
end

---List models reported by the app-server.
---@param agent assistant.agent.Codex
---@param callback fun(ok: boolean, errmsg?: string, models?: string[])
function AppServerBackend:list_models(agent, callback)
  self:begin_request()
  agent:set_loading(true)

  local project = core.root_project() and core.root_project().path or "."
  local log_conversation = { project_dir = project }
  local ok, errmsg = self:start_server(agent, { project_dir = project })
  if not ok then
    self:finish_request()
    agent:set_loading(false)
    callback(false, errmsg or "could not start codex app-server")
    return
  end

  core.add_thread(function()
    local buffer = ""
    local state = {
      pending = {},
      responses = {},
      error = nil
    }
    local init_id
    if not self.initialized then
      init_id = self:request("initialize", initialize_params(), agent, log_conversation)
      track_request(state, init_id)
    end
    local list_id

    while self.proc and self.proc:running() and not self:is_cancelled() do
      local out = self.proc:read_stdout(READ_SIZE)
      if out and out ~= "" then
        buffer = parse_jsonl(buffer .. out, function(msg)
          protocol_log("Assistant app-server <- %s", jsonutil.encode(msg)); append_protocol_log(agent, log_conversation, "event", msg)
          if capture_response(state, msg) then
            return
          elseif msg.method == "error" then
            local err = msg.params and msg.params.error or msg.error
            state.error = type(err) == "table" and err.message or err or "codex app-server error"
          end
        end)
      end

      if init_id and track_response(state, init_id) and not state.sent_initialized then
        self.initialized = true
        state.sent_initialized = true
        self:notify("initialized", {}, agent, log_conversation)
      end

      if (self.initialized or not init_id) and not list_id then
        list_id = self:request("model/list", {
          limit = 100,
          includeHidden = false
        }, agent, log_conversation)
        track_request(state, list_id)
      end

      if state.error or (list_id and track_response(state, list_id)) then
        break
      end
      coroutine.yield(0.02)
    end

    self:finish_request()
    agent:set_loading(false)

    if self:is_cancelled() then
      callback(false, "request cancelled")
    elseif state.error then
      callback(false, state.error)
    else
      local response = list_id and track_response(state, list_id)
      self.last_model_response = response
      local models = model_names_from_response(response)
      if #models == 0 then
        callback(false, string.format(
          "Model listing returned no models for Codex: %s",
          jsonutil.encode(response or {})
        ))
        return
      end
      callback(true, nil, models)
    end
  end)
end

---List collaboration modes reported by the app-server.
---@param agent assistant.agent.Codex
---@param callback fun(ok: boolean, errmsg?: string, modes?: table[])
function AppServerBackend:list_collaboration_modes(agent, callback)
  wait_for_response(self, agent, "collaborationMode/list", {}, function(ok, err, modes)
    if ok and (not modes or #modes == 0) then
      modes = agent:get_collaboration_modes()
    end
    callback(ok, err, modes)
  end, function(response)
    return collaboration_modes_from_response(response)
  end)
end

---Ask the app-server to compact the provider-side conversation thread.
---@param agent assistant.agent.Codex
---@param conversation assistant.Conversation
---@param callback fun(ok: boolean, errmsg?: string)?
function AppServerBackend:compact(agent, conversation, callback)
  if not conversation.codex_thread_id or conversation.codex_thread_id == "" then
    callback(false, "Codex conversation has no app-server thread to compact yet")
    return
  end
  if self.active then
    callback(false, "codex app-server is busy")
    return
  end

  self:begin_request()
  agent:set_loading(true)
  conversation:set_status("compacting")
  local log_conversation = conversation

  local ok, errmsg = self:start_server(agent, conversation)
  if not ok then
    self:finish_request()
    agent:set_loading(false)
    conversation:set_status("error")
    callback(false, errmsg or "could not start codex app-server")
    return
  end

  core.add_thread(function()
    local buffer = ""
    local stderr = {}
    local state = {
      pending = {},
      responses = {},
      error = nil
    }
    local init_id
    if not self.initialized then
      init_id = self:request("initialize", initialize_params(), agent, log_conversation)
      track_request(state, init_id)
    end
    local compact_id

    while self.proc and self.proc:running() and not self:is_cancelled() do
      local out = self.proc:read_stdout(READ_SIZE)
      if out and out ~= "" then
        buffer = parse_jsonl(buffer .. out, function(msg)
          protocol_log("Assistant app-server <- %s", jsonutil.encode(msg)); append_protocol_log(agent, log_conversation, "event", msg)
          if capture_response(state, msg) then
            return
          elseif msg.method == "error" then
            local err = msg.params and msg.params.error or msg.error
            state.error = type(err) == "table" and err.message or err or "codex app-server error"
          end
        end)
      end
      local err = self.proc:read_stderr(READ_SIZE)
      if err and err ~= "" then table.insert(stderr, err) end
      if err and err ~= "" then debug_log("Assistant app-server stderr: %s", err) end

      if init_id and track_response(state, init_id) and not state.sent_initialized then
        self.initialized = true
        state.sent_initialized = true
        self:notify("initialized", {}, agent, log_conversation)
      end

      if (self.initialized or not init_id) and not compact_id then
        compact_id = self:request("thread/compact/start", {
          threadId = conversation.codex_thread_id
        }, agent, conversation)
        track_request(state, compact_id)
      end

      if state.error or (compact_id and track_response(state, compact_id)) then
        break
      end
      coroutine.yield(0.02)
    end

    self:finish_request()
    agent:set_loading(false)

    if self:is_cancelled() then
      conversation:set_status("cancelled")
      callback(false, "request cancelled")
    elseif state.error then
      conversation:set_status("error")
      callback(false, state.error)
    elseif compact_id and track_response(state, compact_id) then
      conversation:set_status("idle")
      callback(true)
    else
      conversation:set_status("error")
      callback(false, diagnostic_message(
        "codex compaction did not return a response",
        buffer,
        stderr,
        self.proc
      ))
    end
  end)
end

---Rename the provider-side conversation thread.
---@param agent assistant.agent.Codex
---@param conversation assistant.Conversation
---@param title string
---@param callback fun(ok: boolean, errmsg?: string)?
function AppServerBackend:rename_conversation(agent, conversation, title, callback)
  if not conversation.codex_thread_id or conversation.codex_thread_id == "" then
    callback(true)
    return
  end
  if self.active then
    callback(false, "codex app-server is busy")
    return
  end

  self:begin_request()
  agent:set_loading(true)

  local ok, errmsg = self:start_server(agent, conversation)
  if not ok then
    self:finish_request()
    agent:set_loading(false)
    callback(false, errmsg or "could not start codex app-server")
    return
  end

  core.add_thread(function()
    local buffer = ""
    local stderr = {}
    local state = { pending = {}, responses = {}, error = nil }
    local init_id
    if not self.initialized then
      init_id = self:request("initialize", initialize_params(), agent, conversation)
      track_request(state, init_id)
    end
    local rename_id

    while self.proc and self.proc:running() and not self:is_cancelled() do
      local out = self.proc:read_stdout(READ_SIZE)
      if out and out ~= "" then
        buffer = parse_jsonl(buffer .. out, function(msg)
          protocol_log("Assistant app-server <- %s", jsonutil.encode(msg)); append_protocol_log(agent, conversation, "event", msg)
          if capture_response(state, msg) then
            return
          elseif msg.method == "error" then
            local err = msg.params and msg.params.error or msg.error
            state.error = type(err) == "table" and err.message or err or "codex app-server error"
          end
        end)
      end
      local err = self.proc:read_stderr(READ_SIZE)
      if err and err ~= "" then table.insert(stderr, err) end
      if err and err ~= "" then debug_log("Assistant app-server stderr: %s", err) end

      if init_id and track_response(state, init_id) and not state.sent_initialized then
        self.initialized = true
        state.sent_initialized = true
        self:notify("initialized", {}, agent, conversation)
      end

      if (self.initialized or not init_id) and not rename_id then
        rename_id = self:request("thread/name/set", {
          threadId = conversation.codex_thread_id,
          name = title
        }, agent, conversation)
        track_request(state, rename_id)
      end

      if state.error or (rename_id and track_response(state, rename_id)) then break end
      coroutine.yield(0.02)
    end

    self:finish_request()
    agent:set_loading(false)

    if self:is_cancelled() then
      callback(false, "request cancelled")
    elseif state.error then
      callback(false, state.error)
    elseif rename_id and track_response(state, rename_id) then
      callback(true)
    else
      callback(false, diagnostic_message(
        "codex thread rename did not return a response",
        buffer,
        stderr,
        self.proc
      ))
    end
  end)
end

return AppServerBackend
