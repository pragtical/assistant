local core = require "core"
local json = require "core.json"
local Backend = require "plugins.assistant.backend"

---One-shot subprocess backend for CLI-style agents.
---@class assistant.backend.CliBackend : assistant.Backend
---@field proc process|nil
local CliBackend = Backend:extend()

local READ_SIZE = 1024 * 8

---Create a new instance.
function CliBackend:new()
  self.super.new(self, "cli")
  self.proc = nil
end

---Cancel the active CLI process if one is running.
function CliBackend:cancel()
  CliBackend.super.cancel(self)
  if self.proc and self.proc:running() then
    self.proc:terminate()
  end
end

---Parse jsonl.
local function parse_jsonl(buffer, on_event)
  while true do
    local idx = buffer:find("\n", 1, true)
    if not idx then break end
    local line = buffer:sub(1, idx - 1)
    buffer = buffer:sub(idx + 1)
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end
    if line ~= "" then
      local event = json.decode(line)
      if type(event) == "table" then
        on_event(event)
      end
    end
  end
  return buffer
end

---Handle collect event.
local function collect_event(agent, conversation, event, state, callback)
  conversation:append_raw_response("cli-event", event)
  if event.type == "thread.started" and event.thread_id then
    conversation.codex_thread_id = event.thread_id
  elseif event.type == "item.completed" and type(event.item) == "table" then
    local item = event.item
    if item.type == "agent_message" and item.text then
      state.response = item.text
      callback(true, nil, state.response, { partial = true })
    end
  elseif event.type == "turn.completed" then
    state.usage = agent:parse_usage(event)
  elseif event.type == "error" then
    state.error = event.message or event.error or "cli request failed"
  end
end

---Handle send.
---@param agent assistant.Agent
---@param conversation assistant.Conversation
---@param callback fun(ok: boolean, err?: string, text?: string, meta?: table)
function CliBackend:send(agent, conversation, callback)
  self:begin_request()
  agent:set_loading(true)
  conversation:set_status("running")

  if not agent.build_command then
    self:finish_request()
    agent:set_loading(false)
    conversation:set_status("error")
    callback(false, "agent does not implement CLI command building")
    return
  end

  local command = agent:build_command(conversation)
  conversation:append_raw_response("cli-request", { command = command })
  local proc, errmsg = process.start(command, {
    cwd = conversation.project_dir or ".",
    stdin = process.REDIRECT_DISCARD,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE
  })
  self.proc = proc
  if not proc then
    self:finish_request()
    agent:set_loading(false)
    conversation:set_status("error")
    callback(false, errmsg or "could not start CLI agent")
    return
  end

  core.add_background_thread(function()
    local stdout = ""
    local stderr = {}
    local state = { response = "" }

    while proc:running() and not self:is_cancelled() do
      local out = proc:read_stdout(READ_SIZE)
      if out and out ~= "" then
        stdout = parse_jsonl(stdout .. out, function(event)
          collect_event(agent, conversation, event, state, callback)
        end)
      end
      local err = proc:read_stderr(READ_SIZE)
      if err and err ~= "" then table.insert(stderr, err) end
      coroutine.yield(0.02)
    end

    if self:is_cancelled() and proc:running() then
      proc:terminate()
    end

    local out = proc:read_stdout(READ_SIZE)
    while out and out ~= "" do
      stdout = parse_jsonl(stdout .. out, function(event)
        collect_event(agent, conversation, event, state, callback)
      end)
      out = proc:read_stdout(READ_SIZE)
    end
    local err = proc:read_stderr(READ_SIZE)
    while err and err ~= "" do
      table.insert(stderr, err)
      err = proc:read_stderr(READ_SIZE)
    end

    self.proc = nil
    self:finish_request()
    agent:set_loading(false)

    local code = proc:returncode()
    if self:is_cancelled() then
      conversation:set_status("cancelled")
      callback(false, "request cancelled")
    elseif state.error or (code and code ~= 0) then
      conversation:set_status("error")
      callback(false, state.error or table.concat(stderr):gsub("^%s+", ""):gsub("%s+$", "") or "cli request failed")
    else
      conversation:set_status("idle")
      callback(true, nil, state.response or "", {
        done = true,
        usage = state.usage,
        thread_id = conversation.codex_thread_id
      })
    end
  end)
end

---List models.
---@param agent assistant.Agent
---@param callback fun(ok: boolean, err?: string, models?: string[])
function CliBackend:list_models(_, callback)
  callback(false, "CLI backend does not expose model listing")
end

return CliBackend
