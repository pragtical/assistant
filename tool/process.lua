local core = require "core"
local context = require "plugins.assistant.tool_context"
local Tool = require "plugins.assistant.tool"

---Process and terminal interaction tool implementations.
---@class assistant.tool.process
local processtools = {}

---Compact compact.
---@param label string
---@return fun(_: assistant.Tool, result: string): string
local function compact(label)
  return function(_, result)
    return context.compact_provider_text_result(result, label)
  end
end

---Return display text for a process/session tool call.
---@param call table|nil
---@return string
local function command_text(call)
  local name = call and call.name
  local args = call and call.arguments or {}
  if name == "exec_command" then return tostring(args.cmd or "") end
  if name == "exec_status" then return "poll session " .. tostring(args.session_id or "") end
  if name == "write_stdin" then return "write stdin to session " .. tostring(args.session_id or "") end
  if name == "send_eof" then return "close stdin for session " .. tostring(args.session_id or "") end
  if name == "interrupt_exec" then return "interrupt session " .. tostring(args.session_id or "") end
  if name == "close_exec" then return "close session " .. tostring(args.session_id or "") end
  return tostring(args.cmd or args.command or "")
end

---Format process tool activity.
---@param call table|nil
---@param status string|nil
---@return string
local function process_compact_activity(call, status)
  local args = call and call.arguments or {}
  local command = command_text(call)
  local cwd = tostring(args.workdir or args.cwd or "")
  local line = "**Running command**: " .. (Tool.ticked(command) ~= "" and Tool.ticked(command) or "`command`")
  if cwd ~= "" then line = line .. " in " .. Tool.ticked(cwd) end
  return line .. Tool.status_suffix(status)
end

local process_sessions = {}
local next_process_session_id = 1

local function conversation_session_id(conversation)
  return conversation and conversation.id or nil
end

---Handle session for.
---@param session_id integer|string
---@return integer? session_id
---@return table|string session
local function session_for(session_id)
  session_id = tonumber(session_id)
  local session = session_id and process_sessions[session_id]
  if not session then return nil, nil, "unknown exec session id: " .. tostring(session_id) end
  return session_id, session
end

---Handle poll session.
---@param session_id integer
---@param session table
---@param yield_time_ms number?
---@param max_output_tokens number?
---@return boolean ok
---@return string result
local function poll_session(session_id, session, yield_time_ms, max_output_tokens)
  local proc = session.proc
  local started = system.get_time()
  local wait_ms = tonumber(yield_time_ms) or 250
  while true do
    local code = proc:wait(0)
    if code ~= nil then
      process_sessions[session_id] = nil
      local output = context.process_output(proc, max_output_tokens)
      output.exit_code = code
      output.timed_out = false
      output.wall_time_ms = math.floor((system.get_time() - session.started) * 1000)
      output.session_id = session_id
      return true, context.format_process_result(output)
    end
    if (system.get_time() - started) * 1000 >= wait_ms then
      local output = context.process_output(proc, max_output_tokens)
      output.exit_code = ""
      output.timed_out = false
      output.wall_time_ms = math.floor((system.get_time() - session.started) * 1000)
      output.session_id = session_id
      return true, context.format_process_result(output)
    end
    context.yield_ui()
  end
end

---Run a shell command and either return its completed output or an ongoing
---session id when it is still running after `yield_time_ms`.
---@param cmd string
---@param workdir string?
---@param shell string?
---@param login boolean?
---@param tty boolean?
---@param yield_time_ms number?
---@param max_output_tokens number?
---@return boolean ok
---@return string result
function processtools.exec_command(cmd, workdir, shell, login, tty, yield_time_ms, max_output_tokens)
  local path, err = context.assert_project_path(workdir or (core.root_project() and core.root_project().path) or ".")
  if not path then return false, err end
  if not context.confirm("exec_command", path, cmd or "") then
    return false, "user denied command execution"
  end
  local command = context.shell_command(cmd or "")
  if context.optional_text(shell) then
    command = { tostring(shell), login == false and "-c" or "-lc", tostring(cmd or "") }
  end
  local proc, start_err = process.start(command, {
    cwd = path,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
    stdin = process.REDIRECT_PIPE
  })
  if not proc then return false, "could not start process: " .. tostring(start_err) end
  local started = system.get_time()
  local wait_ms = tonumber(yield_time_ms) or 10000
  while true do
    local code = proc:wait(0)
    if code ~= nil then
      local output = context.process_output(proc, max_output_tokens)
      output.exit_code = code
      output.timed_out = false
      output.wall_time_ms = math.floor((system.get_time() - started) * 1000)
      return true, context.format_process_result(output)
    end
    if (system.get_time() - started) * 1000 >= wait_ms then
      local output = context.process_output(proc, max_output_tokens)
      local session_id = next_process_session_id
      next_process_session_id = next_process_session_id + 1
      process_sessions[session_id] = {
        proc = proc,
        started = started,
        cwd = path,
        command = cmd or "",
        tty = tty == true,
        conversation_id = conversation_session_id(context.active_conversation())
      }
      output.exit_code = ""
      output.timed_out = false
      output.wall_time_ms = math.floor((system.get_time() - started) * 1000)
      output.session_id = session_id
      return true, context.format_process_result(output)
    end
    context.yield_ui()
  end
end

---Write stdin to an existing process session and poll its output.
---@param session_id integer|string
---@param chars string?
---@param yield_time_ms number?
---@param max_output_tokens number?
---@return boolean ok
---@return string result
function processtools.write_stdin(session_id, chars, yield_time_ms, max_output_tokens)
  local session, err
  session_id, session, err = session_for(session_id)
  if not session_id then return false, err end
  local proc = session.proc
  local text = tostring(chars or "")
  if text ~= "" then
    local ok, err = proc:write(text)
    if not ok then return false, "could not write stdin: " .. tostring(err) end
  end
  return poll_session(session_id, session, yield_time_ms, max_output_tokens)
end

---Poll an existing process session without writing to it.
---@param session_id integer|string
---@param yield_time_ms number?
---@param max_output_tokens number?
---@return boolean ok
---@return string result
function processtools.exec_status(session_id, yield_time_ms, max_output_tokens)
  local session, err
  session_id, session, err = session_for(session_id)
  if not session_id then return false, err end
  return poll_session(session_id, session, yield_time_ms, max_output_tokens)
end

---Close stdin for an existing process session and poll its output.
---@param session_id integer|string
---@param yield_time_ms number?
---@param max_output_tokens number?
---@return boolean ok
---@return string result
function processtools.send_eof(session_id, yield_time_ms, max_output_tokens)
  local session, err
  session_id, session, err = session_for(session_id)
  if not session_id then return false, err end
  local ok, close_err = session.proc:close_stream(process.STREAM_STDIN)
  if not ok then return false, "could not close stdin: " .. tostring(close_err) end
  return poll_session(session_id, session, yield_time_ms, max_output_tokens)
end

---Send an interrupt signal to an existing process session.
---@param session_id integer|string
---@param yield_time_ms number?
---@param max_output_tokens number?
---@return boolean ok
---@return string result
function processtools.interrupt_exec(session_id, yield_time_ms, max_output_tokens)
  local session, err
  session_id, session, err = session_for(session_id)
  if not session_id then return false, err end
  local ok, interrupt_err = session.proc:interrupt()
  if not ok then return false, "could not interrupt process: " .. tostring(interrupt_err) end
  return poll_session(session_id, session, yield_time_ms, max_output_tokens)
end

---Terminate or kill an existing process session.
---@param session_id integer|string
---@param force boolean|string?
---@param yield_time_ms number?
---@param max_output_tokens number?
---@return boolean ok
---@return string result
function processtools.close_exec(session_id, force, yield_time_ms, max_output_tokens)
  local session, err
  session_id, session, err = session_for(session_id)
  if not session_id then return false, err end
  local ok, close_err
  if force == true or force == "true" then
    ok, close_err = session.proc:kill()
  else
    ok, close_err = session.proc:terminate()
  end
  if not ok then return false, "could not close process: " .. tostring(close_err) end
  local poll_ok, result = poll_session(session_id, session, yield_time_ms, max_output_tokens)
  if process_sessions[session_id] and not (force == true or force == "true") then
    session.proc:kill()
    return poll_session(session_id, session, yield_time_ms, max_output_tokens)
  end
  return poll_ok, result
end

---Close all process sessions associated with a conversation.
---@param conversation assistant.Conversation|nil
---@return integer closed_count
function processtools.close_conversation_sessions(conversation)
  local id = conversation_session_id(conversation)
  if not id then return 0 end
  local closed = 0
  for session_id, session in pairs(process_sessions) do
    if session.conversation_id == id then
      if session.proc and session.proc.kill then
        session.proc:kill()
      end
      process_sessions[session_id] = nil
      closed = closed + 1
    end
  end
  return closed
end

processtools.tools = {
  Tool:new({
    name = "exec_command",
    callback = processtools.exec_command,
    compact_result = compact("command output"),
    activity_label = function() return "Running command" end,
    compact_activity_markdown = process_compact_activity,
    description = "Runs a command in a loaded project root, returning output or a session_id for ongoing interaction.",
    requires_approval = function(arguments)
      return context.command_requires_approval({
        command = arguments and arguments.cmd,
        cwd = arguments and arguments.workdir
      })
    end,
    params = {
      { name = "cmd", description = "Shell command to execute.", type = "string" },
      { name = "workdir", description = "Optional working directory; defaults to the project root.", type = "string", required = false },
      { name = "shell", description = "Shell binary to launch.", type = "string", required = false },
      { name = "login", description = "Whether to run shell with login semantics.", type = "boolean", required = false },
      { name = "tty", description = "Whether to request TTY-compatible behavior.", type = "boolean", required = false },
      { name = "yield_time_ms", description = "How long to wait for output before returning a session_id.", type = "number", required = false },
      { name = "max_output_tokens", description = "Maximum output bytes to return before truncating.", type = "number", required = false },
      { name = "sandbox_permissions", description = "Optional permission request hint.", type = "string", required = false },
      { name = "justification", description = "Optional reason for elevated permissions.", type = "string", required = false },
      { name = "prefix_rule", description = "Optional command prefix tokens for session approval.", type = "array", required = false }
    }
  }),
  Tool:new({
    name = "write_stdin",
    callback = processtools.write_stdin,
    compact_result = compact("command output"),
    activity_label = function() return "Running command" end,
    compact_activity_markdown = process_compact_activity,
    description = "Writes characters to an existing exec_command session and returns recent output.",
    read_only = true,
    params = {
      { name = "session_id", description = "Identifier of the running exec session.", type = "number" },
      { name = "chars", description = "Bytes to write to stdin; omit or send empty text to poll.", type = "string", required = false },
      { name = "yield_time_ms", description = "How long to wait for output before yielding.", type = "number", required = false },
      { name = "max_output_tokens", description = "Maximum output bytes to return before truncating.", type = "number", required = false }
    }
  }),
  Tool:new({
    name = "exec_status",
    callback = processtools.exec_status,
    compact_result = compact("command output"),
    activity_label = function() return "Running command" end,
    compact_activity_markdown = process_compact_activity,
    description = "Poll an existing exec_command session and return recent output.",
    read_only = true,
    params = {
      { name = "session_id", description = "Identifier of the running exec session.", type = "number" },
      { name = "yield_time_ms", description = "How long to wait for output before returning.", type = "number", required = false },
      { name = "max_output_tokens", description = "Maximum output bytes to return before truncating.", type = "number", required = false }
    }
  }),
  Tool:new({
    name = "send_eof",
    callback = processtools.send_eof,
    compact_result = compact("command output"),
    activity_label = function() return "Running command" end,
    compact_activity_markdown = process_compact_activity,
    description = "Close stdin for an existing exec_command session and return recent output.",
    read_only = true,
    params = {
      { name = "session_id", description = "Identifier of the running exec session.", type = "number" },
      { name = "yield_time_ms", description = "How long to wait for output before returning.", type = "number", required = false },
      { name = "max_output_tokens", description = "Maximum output bytes to return before truncating.", type = "number", required = false }
    }
  }),
  Tool:new({
    name = "interrupt_exec",
    callback = processtools.interrupt_exec,
    compact_result = compact("command output"),
    activity_label = function() return "Running command" end,
    compact_activity_markdown = process_compact_activity,
    description = "Interrupt an existing exec_command session and return recent output.",
    read_only = true,
    params = {
      { name = "session_id", description = "Identifier of the running exec session.", type = "number" },
      { name = "yield_time_ms", description = "How long to wait for output before returning.", type = "number", required = false },
      { name = "max_output_tokens", description = "Maximum output bytes to return before truncating.", type = "number", required = false }
    }
  }),
  Tool:new({
    name = "close_exec",
    callback = processtools.close_exec,
    compact_result = compact("command output"),
    activity_label = function() return "Running command" end,
    compact_activity_markdown = process_compact_activity,
    description = "Terminate an existing exec_command session and return recent output.",
    read_only = true,
    params = {
      { name = "session_id", description = "Identifier of the running exec session.", type = "number" },
      { name = "force", description = "Kill instead of terminate when true.", type = "boolean", required = false },
      { name = "yield_time_ms", description = "How long to wait for output before returning.", type = "number", required = false },
      { name = "max_output_tokens", description = "Maximum output bytes to return before truncating.", type = "number", required = false }
    }
  })
}

return processtools
