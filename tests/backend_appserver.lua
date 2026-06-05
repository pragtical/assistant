local test = require "core.test"
dofile("tests/helper.inc")
local config = require "core.config"
local Conversation = require "plugins.assistant.conversation"
local AppServerBackend = require "plugins.assistant.backend.appserver"
local Codex = require "plugins.assistant.agent.codex"

local real_process = process
local real_assistant_config = config.plugins.assistant

local function is_codex_appserver(command)
  return type(command) == "table"
    and tostring(command[1]):match("codex$")
    and command[2] == "app-server"
end

local function fake_proc(stdout_chunks, stderr_chunks, code)
  local proc = {
    stdout_chunks = stdout_chunks or {},
    stderr_chunks = stderr_chunks or {},
    writes = {},
    code = code or 0,
    killed = false
  }
  function proc:running()
    return not self.killed
  end
  function proc:read_stdout()
    if #self.stdout_chunks == 0 then
      self.killed = true
      return ""
    end
    return table.remove(self.stdout_chunks, 1)
  end
  function proc:read_stderr()
    return table.remove(self.stderr_chunks, 1) or ""
  end
  function proc:write(data)
    table.insert(self.writes, data)
    return #data
  end
  function proc:terminate()
    self.killed = true
    return true
  end
  function proc:returncode()
    return self.code
  end
  return proc
end

local function read_file(path)
  local fp = io.open(path, "rb")
  if not fp then return nil end
  local data = fp:read("*a")
  fp:close()
  return data
end

test.describe("assistant app-server backend", function()
  test.after_each(function()
    process = real_process
    config.plugins.assistant = real_assistant_config
  end)

  test.it("writes full app-server requests after partial process writes", function()
    local proc = fake_proc()
    proc.writes = {}
    function proc:write(data)
      local n = math.min(5, #data)
      table.insert(self.writes, data:sub(1, n))
      return n
    end

    local backend = AppServerBackend()
    backend.proc = proc
    backend.next_id = 1

    local id = backend:request("test/method", { text = "abcdef" }, Codex(), nil)
    local written = table.concat(proc.writes)

    test.equal(id, 1)
    test.equal(written:sub(-1), "\n")
    test.equal(written:find('"method":"test/method"', 1, true) ~= nil, true)
    test.equal(written:find('"text":"abcdef"', 1, true) ~= nil, true)
  end)

  test.it("starts a thread and turn over persistent jsonl", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"thread":{"id":"thr_1"}}}\n',
      '{"id":3,"result":{"turn":{"id":"turn_1","status":"inProgress"}}}\n',
      '{"method":"item/agentMessage/delta","params":{"delta":"po"}}\n',
      '{"method":"item/agentMessage/delta","params":{"delta":"ng"}}\n',
      '{"method":"turn/completed","params":{"turn":{"id":"turn_1","status":"completed"}}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    agent.model = "gpt-5.3-codex"
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    local backend = AppServerBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
    end)

    coroutine.yield(0.4)

    test.equal(conversation.codex_thread_id, "thr_1")
    test.equal(response, "pong")
    test.equal(#proc.writes >= 4, true)
  end)

  test.it("handles string request/response ids", function()
    local proc = fake_proc({
      '{"id":"1","result":{}}\n',
      '{"id":"2","result":{"thread":{"id":"thr_1"}}}\n',
      '{"id":"3","result":{"turn":{"id":"turn_1","status":"inProgress"}}}\n',
      '{"method":"item/agentMessage/delta","params":{"delta":"po"}}\n',
      '{"method":"item/agentMessage/delta","params":{"delta":"ng"}}\n',
      '{"method":"turn/completed","params":{"turn":{"id":"turn_1","status":"completed"}}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    agent.model = "gpt-5.3-codex"
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    local backend = AppServerBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
    end)

    coroutine.yield(0.4)

    test.equal(conversation.codex_thread_id, "thr_1")
    test.equal(response, "pong")
    local wrote_initialize = false
    for _, write in ipairs(proc.writes) do
      if write:find('"id":1', 1, true) then wrote_initialize = true; break end
    end
    test.equal(wrote_initialize, true)
  end)

  test.it("sends configured codex reasoning effort on plain turns", function()
    local old_reasoning_effort = config.plugins.assistant.reasoning_effort
    config.plugins.assistant.reasoning_effort = "high"
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"thread":{"id":"thr_1"}}}\n',
      '{"id":3,"result":{"turn":{"id":"turn_1","status":"inProgress"}}}\n',
      '{"method":"turn/completed","params":{"turn":{"id":"turn_1","status":"completed"}}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    agent.model = "gpt-5.3-codex"
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    local backend = AppServerBackend()

    backend:send(agent, conversation, function() end)
    coroutine.yield(0.4)
    config.plugins.assistant.reasoning_effort = old_reasoning_effort

    local writes = table.concat(proc.writes)
    test.equal(writes:find('"method":"turn/start"', 1, true) ~= nil, true)
    test.equal(writes:find('"effort":"high"', 1, true) ~= nil, true)
  end)

  test.it("maps assistant none reasoning to codex minimal on plain turns", function()
    local old_reasoning_effort = config.plugins.assistant.reasoning_effort
    config.plugins.assistant.reasoning_effort = "none"
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"thread":{"id":"thr_1"}}}\n',
      '{"id":3,"result":{"turn":{"id":"turn_1","status":"inProgress"}}}\n',
      '{"method":"turn/completed","params":{"turn":{"id":"turn_1","status":"completed"}}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    local backend = AppServerBackend()

    backend:send(agent, conversation, function() end)
    coroutine.yield(0.4)
    config.plugins.assistant.reasoning_effort = old_reasoning_effort

    test.equal(table.concat(proc.writes):find('"effort":"minimal"', 1, true) ~= nil, true)
  end)

  test.it("updates conversation status from codex app-server events", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"thread":{"id":"thr_1"}}}\n',
      '{"method":"mcpServer/startupStatus/updated","params":{"name":"codex_apps","status":"starting"}}\n',
      '{"id":3,"result":{"turn":{"id":"turn_1","status":"inProgress"}}}\n',
      '{"method":"turn/started","params":{"threadId":"thr_1","turn":{"id":"turn_1","status":"inProgress"}}}\n',
      '{"method":"item/started","params":{"item":{"type":"reasoning","id":"rs_1"}}}\n',
      '{"method":"item/started","params":{"item":{"type":"webSearch","id":"ws_1"}}}\n',
      '{"method":"item/started","params":{"item":{"type":"agentMessage","id":"msg_1","text":""}}}\n',
      '{"method":"item/agentMessage/delta","params":{"delta":"ok"}}\n',
      '{"method":"turn/completed","params":{"turn":{"id":"turn_1","status":"completed"}}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    agent.model = "gpt-5.3-codex"
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    local backend = AppServerBackend()
    local statuses = {}

    local original_set_status = conversation.set_status
    conversation.set_status = function(this, status)
      table.insert(statuses, status)
      return original_set_status(this, status)
    end

    backend:send(agent, conversation, function() end)

    coroutine.yield(0.4)

    test.equal(table.concat(statuses, ","):find("starting", 1, true) ~= nil, true)
    test.equal(table.concat(statuses, ","):find("working", 1, true) ~= nil, true)
    test.equal(table.concat(statuses, ","):find("reasoning", 1, true) ~= nil, true)
    test.equal(table.concat(statuses, ","):find("searching", 1, true) ~= nil, true)
    test.equal(table.concat(statuses, ","):find("responding", 1, true) ~= nil, true)
    test.equal(conversation.status, "idle")
  end)

  test.it("renders codex file change diffs in activity messages", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"thread":{"id":"thr_1"}}}\n',
      '{"id":3,"result":{"turn":{"id":"turn_1","status":"inProgress"}}}\n',
      '{"method":"item/completed","params":{"item":{"type":"fileChange","id":"edit_1","status":"completed","changes":[{"path":"project/main.c","kind":{"type":"update"},"diff":"@@ -1 +1 @@\\n-old\\n+new"}]}}}\n',
      '{"method":"turn/completed","params":{"turn":{"id":"turn_1","status":"completed"}}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    agent.model = "gpt-5.3-codex"
    local conversation = Conversation(agent, "project")
    conversation:add("user", "edit", { autosave = false })
    local backend = AppServerBackend()

    backend:send(agent, conversation, function() end)

    coroutine.yield(0.4)

    local md = conversation:to_markdown()
    test.equal(md:find("## Activity", 1, true), nil)
    test.equal(md:find("**Editing**:", 1, true) ~= nil, true)
    test.equal(md:find("`project/main.c`", 1, true) ~= nil, true)
    test.equal(md:find("```diff", 1, true) ~= nil, true)
    test.equal(md:find("+new", 1, true) ~= nil, true)
  end)

  test.it("streams codex item plan deltas", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"thread":{"id":"thr_1"}}}\n',
      '{"id":3,"result":{"turn":{"id":"turn_1","status":"inProgress"}}}\n',
      '{"method":"item/plan/delta","params":{"delta":"Plan"}}\n',
      '{"method":"item/plan/delta","params":{"delta":" details"}}\n',
      '{"method":"turn/completed","params":{"turn":{"id":"turn_1","status":"completed"}}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    agent.model = "gpt-5.3-codex"
    local conversation = Conversation(agent, "project")
    conversation:add("user", "plan", { autosave = false })
    local backend = AppServerBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
    end)

    coroutine.yield(0.4)

    test.equal(response, "Plan details")
    test.equal(conversation.status, "idle")
  end)

  test.it("renders app-server plan updates as checkbox tasks", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"thread":{"id":"thr_1"}}}\n',
      '{"id":3,"result":{"turn":{"id":"turn_1","status":"inProgress"}}}\n',
      '{"method":"turn/plan/updated","params":{"threadId":"thr_1","turnId":"turn_1","explanation":"Working plan","plan":[{"step":"Inspect","status":"completed"},{"step":"Patch","status":"in_progress"},{"step":"Test","status":"pending"}]}}\n',
      '{"method":"turn/completed","params":{"turn":{"id":"turn_1","status":"completed"}}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local conversation = Conversation(Codex(), "project")
    conversation:add("user", "work", { autosave = false })
    local backend = AppServerBackend()
    local response

    backend:send(Codex(), conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
    end)

    coroutine.yield(0.4)

    test.equal(response:find("- [x] Inspect", 1, true) ~= nil, true)
    test.equal(response:find("- [ ] **Patch** _(in progress)_", 1, true) ~= nil, true)
    test.equal(response:find("- [ ] Test", 1, true) ~= nil, true)
  end)

  test.it("shows codex command execution details in activity messages", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"thread":{"id":"thr_1"}}}\n',
      '{"id":3,"result":{"turn":{"id":"turn_1","status":"inProgress"}}}\n',
      '{"method":"item/started","params":{"item":{"type":"commandExecution","id":"cmd_1","status":"inProgress","command":"make test","cwd":"project"}}}\n',
      '{"method":"item/completed","params":{"item":{"type":"commandExecution","id":"cmd_1","status":"completed","command":"make test","cwd":"project","exitCode":0}}}\n',
      '{"method":"turn/completed","params":{"turn":{"id":"turn_1","status":"completed"}}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    agent.model = "gpt-5.3-codex"
    local conversation = Conversation(agent, "project")
    conversation:add("user", "test", { autosave = false })
    local backend = AppServerBackend()
    local statuses = {}

    local original_set_status = conversation.set_status
    conversation.set_status = function(this, status, options)
      table.insert(statuses, status)
      return original_set_status(this, status, options)
    end

    backend:send(agent, conversation, function() end)

    coroutine.yield(0.4)

    local md = conversation:to_markdown()
    test.equal(table.concat(statuses, "\n"):find("running command: make test", 1, true) ~= nil, true)
    test.equal(table.concat(statuses, "\n"):find("\nworking\n", 1, true) ~= nil, true)
    test.equal(md:find("**Running**:", 1, true) ~= nil, true)
    test.equal(md:find("`make test`", 1, true) ~= nil, true)
    test.equal(md:find("(completed)", 1, true) ~= nil, true)
  end)

  test.it("lists codex app-server models", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"data":[{"id":"b","model":"model-b","displayName":"B"},{"id":"model-a","displayName":"A"}],"nextCursor":null}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    local backend = AppServerBackend()
    local models

    backend:list_models(agent, function(ok, _, result)
      if ok then models = result end
    end)

    coroutine.yield(0.2)

    test.same(models, { "model-a", "model-b" })
    local wrote_model_list = false
    for _, write in ipairs(proc.writes) do
      if write:find('"method":"model/list"', 1, true) then
        wrote_model_list = true
        break
      end
    end
    test.equal(wrote_model_list, true)
  end)

  test.it("tolerates malformed jsonl lines", function()
    local proc = fake_proc({
      '{oops}\n',
      '{"id":1,"result":{}}\n',
      '{bad\n',
      '{"id":2,"result":{"data":[{"id":"model-a"}],"nextCursor":null}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local backend = AppServerBackend()
    local models
    local completed
    backend:list_models(Codex(), function(ok, _, result)
      completed = ok
      if ok then models = result end
    end)

    coroutine.yield(0.3)

    test.equal(completed, true)
    test.same(models, { "model-a" })
  end)

  test.it("advertises experimental app-server capabilities on initialize", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"data":[{"model":"model-a"}],"nextCursor":null}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local backend = AppServerBackend()
    backend:list_models(Codex(), function() end)

    coroutine.yield(0.2)

    test.equal(proc.writes[1]:find('"method":"initialize"', 1, true) ~= nil, true)
    test.equal(proc.writes[1]:find('"experimentalApi":true', 1, true) ~= nil, true)
  end)

  test.it("stops active sends when turn start returns a request error", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"thread":{"id":"thr_1"}}}\n',
      '{"id":3,"error":{"message":"turn/start.collaborationMode requires experimentalApi capability","code":-32600}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    agent.model = "gpt-5.3-codex"
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "plan"
    conversation:add("user", "hello", { autosave = false })
    local backend = AppServerBackend()
    local err

    backend:send(agent, conversation, function(ok, got_err)
      if not ok then err = got_err end
    end)

    coroutine.yield(0.3)

    test.equal(err, "turn/start.collaborationMode requires experimentalApi capability")
    test.equal(backend.active, false)
    test.equal(agent:loading(), false)
    test.equal(conversation.status, "error")
  end)

  test.it("lists codex collaboration modes", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"data":[{"name":"Implementation","mode":"default","model":"gpt-5.3-codex"},{"name":"Plan","mode":"plan","model":"gpt-5.3-codex"}]}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local backend = AppServerBackend()
    local modes

    backend:list_collaboration_modes(Codex(), function(ok, _, result)
      if ok then modes = result end
    end)

    coroutine.yield(0.2)

    test.equal(modes[1].id, "default")
    test.equal(modes[2].id, "plan")
    test.equal(modes[1].label, "Implementation")
    local wrote_mode_list = false
    for _, write in ipairs(proc.writes) do
      if write:find('"method":"collaborationMode/list"', 1, true) then
        wrote_mode_list = true
        break
      end
    end
    test.equal(wrote_mode_list, true)
  end)

  test.it("sends selected collaboration mode when starting turns", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"thread":{"id":"thr_1"}}}\n',
      '{"id":3,"result":{"turn":{"id":"turn_1","status":"inProgress"}}}\n',
      '{"method":"item/completed","params":{"item":{"type":"plan","text":"Plan only"}}}\n',
      '{"method":"turn/completed","params":{"turn":{"id":"turn_1","status":"completed"}}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    agent.model = "gpt-5.3-codex"
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "plan"
    conversation:add("user", "hello", { autosave = false })
    local backend = AppServerBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
    end)

    coroutine.yield(0.4)

    test.equal(response, "Plan only")
    local wrote_mode = false
    for _, write in ipairs(proc.writes) do
      if write:find('"method":"turn/start"', 1, true)
        and write:find('"collaborationMode"', 1, true)
        and write:find('"mode":"plan"', 1, true)
        and write:find('"settings"', 1, true)
      then
        wrote_mode = true
        break
      end
    end
    test.equal(wrote_mode, true)
  end)

  test.it("keeps streamed plans separate from prior commentary", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"thread":{"id":"thr_1"}}}\n',
      '{"id":3,"result":{"turn":{"id":"turn_1","status":"inProgress"}}}\n',
      '{"method":"item/agentMessage/delta","params":{"itemId":"msg_1","delta":"Checking"}}\n',
      '{"method":"item/completed","params":{"item":{"id":"msg_1","type":"agentMessage","phase":"commentary","text":"Checking"}}}\n',
      '{"method":"item/plan/delta","params":{"itemId":"plan_1","delta":"# Plan"}}\n',
      '{"method":"item/plan/delta","params":{"itemId":"plan_1","delta":"\\n\\n- Step"}}\n',
      '{"method":"item/completed","params":{"item":{"id":"plan_1","type":"plan","text":"# Plan\\n\\n- Step"}}}\n',
      '{"method":"turn/completed","params":{"turn":{"id":"turn_1","status":"completed"}}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    agent.model = "gpt-5.3-codex"
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "plan"
    conversation:add("user", "plan", { autosave = false })
    local backend = AppServerBackend()
    local final_response
    local stream_kinds = {}
    local contaminated = false

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.stream_kind then
        stream_kinds[#stream_kinds + 1] = meta.stream_kind
        if meta.stream_kind == "plan" and tostring(text or ""):find("Checking", 1, true) then
          contaminated = true
        end
      end
      if ok and meta and meta.done then final_response = text end
    end)

    coroutine.yield(0.4)

    test.equal(final_response, "# Plan\n\n- Step")
    test.equal(contaminated, false)
    test.equal(stream_kinds[1], "assistant")
    test.equal(stream_kinds[#stream_kinds], "plan")
  end)

  test.it("updates app-server command activity instead of duplicating it", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"thread":{"id":"thr_1"}}}\n',
      '{"id":3,"result":{"turn":{"id":"turn_1","status":"inProgress"}}}\n',
      '{"method":"item/started","params":{"item":{"id":"cmd_1","type":"commandExecution","status":"inProgress","command":"make test","cwd":"project"}}}\n',
      '{"method":"item/completed","params":{"item":{"id":"cmd_1","type":"commandExecution","status":"completed","exitCode":0,"command":"make test","cwd":"project","aggregatedOutput":"ok\\n"}}}\n',
      '{"method":"item/agentMessage/delta","params":{"itemId":"msg_1","delta":"done"}}\n',
      '{"method":"turn/completed","params":{"turn":{"id":"turn_1","status":"completed"}}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    local conversation = Conversation(agent, "project")
    conversation:add("user", "run", { autosave = false })
    local backend = AppServerBackend()

    backend:send(agent, conversation, function() end)

    coroutine.yield(0.4)

    local activities = {}
    for _, message in ipairs(conversation.messages) do
      if message.role == "activity" then table.insert(activities, message) end
    end
    test.equal(#activities, 1)
    test.equal(activities[1].message:find("Status: completed", 1, true) ~= nil, true)
    test.equal(activities[1].message:find("Output:", 1, true) ~= nil, true)
    test.equal(activities[1].message:find("ok", 1, true) ~= nil, true)
  end)

  test.it("maps legacy implementation mode to default collaboration payload", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"thread":{"id":"thr_1"}}}\n',
      '{"id":3,"result":{"turn":{"id":"turn_1","status":"inProgress"}}}\n',
      '{"method":"turn/completed","params":{"turn":{"id":"turn_1","status":"completed"}}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    agent.model = "gpt-5.3-codex"
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "implementation"
    conversation:add("user", "hello", { autosave = false })
    local backend = AppServerBackend()

    backend:send(agent, conversation, function() end)

    coroutine.yield(0.4)

    local sent_default = false
    for _, write in ipairs(proc.writes) do
      if write:find('"method":"turn/start"', 1, true)
        and write:find('"collaborationMode"', 1, true)
        and write:find('"mode":"default"', 1, true)
      then
        sent_default = true
        break
      end
    end
    test.equal(sent_default, true)
  end)

  test.it("uses granular approval policy for codex turns", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"thread":{"id":"thr_1"}}}\n',
      '{"id":3,"result":{"turn":{"id":"turn_1","status":"inProgress"}}}\n',
      '{"method":"item/agentMessage/delta","params":{"delta":"ok"}}\n',
      '{"method":"turn/completed","params":{"turn":{"id":"turn_1","status":"completed"}}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    local backend = AppServerBackend()

    backend:send(agent, conversation, function() end)

    coroutine.yield(0.3)

    local wrote_policy = false
    for _, write in ipairs(proc.writes) do
      if write:find('"method":"turn/start"', 1, true)
        and write:find('"approvalPolicy"', 1, true)
        and write:find('"request_permissions":true', 1, true)
        and write:find('"sandbox_approval":true', 1, true)
      then
        wrote_policy = true
        break
      end
    end
    test.equal(wrote_policy, true)
  end)

  test.it("surfaces codex approval requests and sends decisions", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"thread":{"id":"thr_1"}}}\n',
      '{"id":3,"result":{"turn":{"id":"turn_1","status":"inProgress"}}}\n',
      '{"id":4,"method":"item/commandExecution/requestApproval","params":{"itemId":"item_1","threadId":"thr_1","turnId":"turn_1","startedAtMs":1,"command":"make test","cwd":"project","reason":"verify"}}\n',
      '{"method":"item/agentMessage/delta","params":{"delta":"ok"}}\n',
      '{"method":"turn/completed","params":{"turn":{"id":"turn_1","status":"completed"}}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    local backend = AppServerBackend()
    local requested

    backend:send(agent, conversation, function(ok, _, _, meta)
      if ok and meta and meta.event == "approval_request" then
        requested = meta.request
        backend:resolve_approval(agent, conversation, requested, "accept")
      end
    end)

    coroutine.yield(0.4)

    test.not_nil(requested)
    test.equal(requested.kind, "command")
    local wrote_decision = false
    for _, write in ipairs(proc.writes) do
      if write:find('"id":4', 1, true)
        and write:find('"decision":"accept"', 1, true)
      then
        wrote_decision = true
        break
      end
    end
    test.equal(wrote_decision, true)
  end)

  test.it("surfaces codex server request resolution events", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"thread":{"id":"thr_1"}}}\n',
      '{"id":3,"result":{"turn":{"id":"turn_1","status":"inProgress"}}}\n',
      '{"id":4,"method":"item/commandExecution/requestApproval","params":{"itemId":"item_1","threadId":"thr_1","turnId":"turn_1","command":"make test","cwd":"project","reason":"verify"}}\n',
      '{"method":"serverRequest/resolved","params":{"requestId":4}}\n',
      '{"method":"item/agentMessage/delta","params":{"delta":"ok"}}\n',
      '{"method":"turn/completed","params":{"turn":{"id":"turn_1","status":"completed"}}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    local backend = AppServerBackend()
    local resolved

    backend:send(agent, conversation, function(ok, _, _, meta)
      if ok and meta and meta.event == "approval_request" then
        backend:resolve_approval(agent, conversation, meta.request, "accept")
      elseif ok and meta and meta.event == "request_resolved" then
        resolved = meta
      end
    end)

    coroutine.yield(0.4)

    test.not_nil(resolved)
    test.equal(resolved.request_id, "4")
    test.not_nil(resolved.request)
    test.equal(resolved.request.kind, "command")
  end)

  test.it("does not treat same-id server requests as client responses", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"thread":{"id":"thr_1"}}}\n',
      '{"id":3,"method":"item/commandExecution/requestApproval","params":{"itemId":"item_1","threadId":"thr_1","turnId":"turn_1","command":"make test","cwd":"project","reason":"verify"}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    local backend = AppServerBackend()
    local requested

    backend:send(agent, conversation, function(ok, _, _, meta)
      if ok and meta and meta.event == "approval_request" then
        requested = meta.request
      end
    end)

    coroutine.yield(0.4)

    test.not_nil(requested)
    test.equal(tostring(requested.id), "3")
    test.equal(requested.kind, "command")
  end)

  test.it("does not finish a turn while an app-server approval request is pending", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"thread":{"id":"thr_1"}}}\n',
      '{"id":3,"result":{"turn":{"id":"turn_1","status":"inProgress"}}}\n',
      '{"id":4,"method":"item/commandExecution/requestApproval","params":{"itemId":"item_1","threadId":"thr_1","turnId":"turn_1","command":"make test","cwd":"project","reason":"verify"}}\n',
      '{"method":"thread/status/changed","params":{"threadId":"thr_1","status":"ready"}}\n',
      '{"method":"serverRequest/resolved","params":{"requestId":4}}\n',
      '{"method":"item/agentMessage/delta","params":{"delta":"ok"}}\n',
      '{"method":"turn/completed","params":{"turn":{"id":"turn_1","status":"completed"}}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    local backend = AppServerBackend()
    local requested
    local resolved
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "approval_request" then
        requested = meta.request
      elseif ok and meta and meta.event == "request_resolved" then
        resolved = meta
      elseif ok and meta and meta.done then
        response = text
      end
    end)

    coroutine.yield(0.5)

    test.not_nil(requested)
    test.not_nil(resolved)
    test.equal(response, "ok")
  end)

  test.it("accepts completed empty assistant messages from codex", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"thread":{"id":"thr_1"}}}\n',
      '{"id":3,"result":{"turn":{"id":"turn_1","status":"inProgress"}}}\n',
      '{"method":"item/started","params":{"item":{"type":"agentMessage","id":"msg_1","phase":"final_answer","text":""}}}\n',
      '{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"msg_1","phase":"final_answer","text":""}}}\n',
      '{"method":"turn/completed","params":{"turn":{"id":"turn_1","status":"completed"}}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    local conversation = Conversation(agent, "project")
    conversation:add("user", "ok", { autosave = false })
    local backend = AppServerBackend()
    local completed
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then
        completed = true
        response = text
      end
    end)

    coroutine.yield(0.4)

    test.equal(completed, true)
    test.equal(response, "")
    test.equal(conversation.status, "idle")
  end)

  test.it("surfaces legacy codex approval requests and sends legacy decisions", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"thread":{"id":"thr_1"}}}\n',
      '{"id":3,"result":{"turn":{"id":"turn_1","status":"inProgress"}}}\n',
      '{"id":4,"method":"execCommandApproval","params":{"callId":"call_1","conversationId":"thr_1","command":["git","init"],"cwd":"project","parsedCmd":[],"reason":"initialize repo"}}\n',
      '{"method":"item/agentMessage/delta","params":{"delta":"ok"}}\n',
      '{"method":"turn/completed","params":{"turn":{"id":"turn_1","status":"completed"}}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    local backend = AppServerBackend()
    local requested

    backend:send(agent, conversation, function(ok, _, _, meta)
      if ok and meta and meta.event == "approval_request" then
        requested = meta.request
        backend:resolve_approval(agent, conversation, requested, "accept")
      end
    end)

    coroutine.yield(0.4)

    test.not_nil(requested)
    test.equal(requested.legacy, true)
    test.equal(requested.kind, "command")
    local wrote_decision = false
    for _, write in ipairs(proc.writes) do
      if write:find('"id":4', 1, true)
        and write:find('"decision":"approved"', 1, true)
      then
        wrote_decision = true
        break
      end
    end
    test.equal(wrote_decision, true)
  end)

  test.it("supports codex tool approval requests and sends decision responses", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"thread":{"id":"thr_1"}}}\n',
      '{"id":3,"result":{"turn":{"id":"turn_1","status":"inProgress"}}}\n',
      '{"id":4,"method":"item/tool/requestApproval","params":{"itemId":"item_1","threadId":"thr_1","turnId":"turn_1","tool":"grep","args":["foo"],"reason":"run tool"}}\n',
      '{"method":"item/agentMessage/delta","params":{"delta":"ok"}}\n',
      '{"method":"turn/completed","params":{"turn":{"id":"turn_1","status":"completed"}}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    local backend = AppServerBackend()
    local requested

    backend:send(agent, conversation, function(ok, _, _, meta)
      if ok and meta and meta.event == "approval_request" then
        requested = meta.request
        backend:resolve_approval(agent, conversation, requested, "acceptForSession")
      end
    end)

    coroutine.yield(0.4)

    test.not_nil(requested)
    test.equal(requested.kind, "tool")
    local wrote_decision = false
    for _, write in ipairs(proc.writes) do
      if write:find('"id":4', 1, true)
        and write:find('"decision":"acceptForSession"', 1, true)
      then
        wrote_decision = true
        break
      end
    end
    test.equal(wrote_decision, true)
  end)

  test.it("writes app-server protocol logs to the project assistant log", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"thread":{"id":"thr_1"}}}\n',
      '{"id":3,"result":{"turn":{"id":"turn_1","status":"inProgress"}}}\n',
      '{"id":4,"method":"execCommandApproval","params":{"callId":"call_1","conversationId":"thr_1","command":["git","init"],"cwd":"project","parsedCmd":[],"reason":"initialize repo"}}\n',
      '{"method":"item/agentMessage/delta","params":{"delta":"ok"}}\n',
      '{"method":"turn/completed","params":{"turn":{"id":"turn_1","status":"completed"}}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }
    config.plugins.assistant = { log_protocol = true }

    local root = assistant_test_temp_path("protocol-log")
    local agent = Codex()
    local conversation = Conversation(agent, root)
    conversation:add("user", "hello", { autosave = false })
    local backend = AppServerBackend()

    backend:send(agent, conversation, function(ok, _, _, meta)
      if ok and meta and meta.event == "approval_request" then
        backend:resolve_approval(agent, conversation, meta.request, "accept")
      end
    end)

    coroutine.yield(0.4)

    local log = read_file(Conversation.log_path(root, "codex"))
    test.not_nil(log)
    test.equal(log:find('"direction":"request"', 1, true) ~= nil, true)
    test.equal(log:find('"method":"turn/start"', 1, true) ~= nil, true)
    test.equal(log:find('"direction":"event"', 1, true) ~= nil, true)
    test.equal(log:find('"execCommandApproval"', 1, true) ~= nil, true)
    test.equal(log:find('"direction":"response"', 1, true) ~= nil, true)
    test.equal(log:find('"decision":"approved"', 1, true) ~= nil, true)
  end)

  test.it("shows waiting status from thread active flags", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"thread":{"id":"thr_1"}}}\n',
      '{"id":3,"result":{"turn":{"id":"turn_1","status":"inProgress"}}}\n',
      '{"method":"thread/status/changed","params":{"threadId":"thr_1","status":{"type":"active","activeFlags":["waitingOnApproval"]}}}\n',
      '{"method":"item/agentMessage/delta","params":{"delta":"ok"}}\n',
      '{"method":"turn/completed","params":{"turn":{"id":"turn_1","status":"completed"}}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    local backend = AppServerBackend()
    local statuses = {}
    local original_set_status = conversation.set_status
    conversation.set_status = function(this, status)
      table.insert(statuses, status)
      return original_set_status(this, status)
    end

    backend:send(agent, conversation, function() end)

    coroutine.yield(0.4)

    test.equal(table.concat(statuses, ","):find("waiting for approval", 1, true) ~= nil, true)
  end)

  test.it("falls back to bare app-server start when process options fail", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"data":[{"model":"model-a"}],"nextCursor":null}}\n'
    })
    local attempts = 0
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function()
        attempts = attempts + 1
        if attempts < 3 then return nil, "invalid argument" end
        return proc
      end
    }

    local backend = AppServerBackend()
    local models
    backend:list_models(Codex(), function(ok, _, result)
      if ok then models = result end
    end)

    coroutine.yield(0.2)

    test.equal(attempts, 3)
    test.same(models, { "model-a" })
  end)

  test.it("falls back to shell app-server start when direct command fails", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"data":[{"model":"model-a"}],"nextCursor":null}}\n'
    })
    local last_command
    local attempts = 0
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        attempts = attempts + 1
        last_command = command
        if attempts < 4 then return nil, "invalid argument" end
        return proc
      end
    }

    local backend = AppServerBackend()
    local models
    backend:list_models(Codex(), function(ok, _, result)
      if ok then models = result end
    end)

    coroutine.yield(0.2)

    test.equal(attempts, 4)
    test.equal(type(last_command) == "table" and last_command[1] == "sh", true)
    test.equal(type(last_command) == "table" and last_command[2] == "-lc", true)
    test.equal(type(last_command) == "table" and tostring(last_command[3]):match("codex app%-server$") ~= nil, true)
    test.same(models, { "model-a" })
  end)

  test.it("starts codex thread compaction", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"ok":true}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    local conversation = Conversation(agent, "project")
    conversation.codex_thread_id = "thr_1"
    local backend = AppServerBackend()
    local compacted

    backend:compact(agent, conversation, function(ok)
      compacted = ok
    end)

    coroutine.yield(0.2)

    test.equal(compacted, true)
    local wrote_compact = false
    for _, write in ipairs(proc.writes) do
      if write:find('"method":"thread/compact/start"', 1, true)
        and write:find('"threadId":"thr_1"', 1, true)
      then
        wrote_compact = true
        break
      end
    end
    test.equal(wrote_compact, true)
  end)

  test.it("interrupts active codex turns without terminating app-server", function()
    local proc = fake_proc({})
    local backend = AppServerBackend()
    backend.proc = proc
    backend.active_thread_id = "thr_1"
    backend.active_turn_id = "turn_1"

    backend:cancel()

    test.equal(proc.killed, false)
    test.equal(backend:is_cancelled(), false)
    local wrote_interrupt = false
    for _, write in ipairs(proc.writes) do
      if write:find('"method":"turn/interrupt"', 1, true)
        and write:find('"threadId":"thr_1"', 1, true)
        and write:find('"turnId":"turn_1"', 1, true)
      then
        wrote_interrupt = true
        break
      end
    end
    test.equal(wrote_interrupt, true)
  end)

  test.it("surfaces codex request-user-input server requests and sends answers", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{"thread":{"id":"thr_1"}}}\n',
      '{"id":3,"result":{"turn":{"id":"turn_1","status":"inProgress"}}}\n',
      '{"id":4,"method":"item/tool/requestUserInput","params":{"itemId":"item_1","threadId":"thr_1","turnId":"turn_1","questions":[{"id":"choice","header":"Decision","question":"Proceed?","options":[{"label":"Yes","description":"Continue"}]}]}}\n',
      '{"method":"item/agentMessage/delta","params":{"delta":"ok"}}\n',
      '{"method":"turn/completed","params":{"turn":{"id":"turn_1","status":"completed"}}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    local backend = AppServerBackend()
    local requested
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "user_input_request" then
        requested = meta.request
        backend:resolve_user_input(agent, conversation, requested, true, { choice = "Yes" })
      elseif ok and meta and meta.done then
        response = text
      end
    end)

    coroutine.yield(0.4)

    test.not_nil(requested)
    test.equal(requested.questions[1].question, "Proceed?")
    test.equal(response, "ok")
    local wrote_answer = false
    for _, write in ipairs(proc.writes) do
      if write:find('"id":4', 1, true)
        and write:find('"answers"', 1, true)
        and write:find('"choice"', 1, true)
        and write:find('"Yes"', 1, true)
      then
        wrote_answer = true
        break
      end
    end
    test.equal(wrote_answer, true)
  end)

  test.it("renames codex provider conversations", function()
    local proc = fake_proc({
      '{"id":1,"result":{}}\n',
      '{"id":2,"result":{}}\n'
    })
    process = {
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function(command)
        test.equal(is_codex_appserver(command), true)
        return proc
      end
    }

    local agent = Codex()
    local conversation = Conversation(agent, "project")
    conversation.codex_thread_id = "thr_1"
    local backend = AppServerBackend()
    local renamed

    backend:rename_conversation(agent, conversation, "New Title", function(ok)
      renamed = ok
    end)

    coroutine.yield(0.2)

    test.equal(renamed, true)
    local wrote_rename = false
    for _, write in ipairs(proc.writes) do
      if write:find('"method":"thread/name/set"', 1, true)
        and write:find('"threadId":"thr_1"', 1, true)
        and write:find('"name":"New Title"', 1, true)
      then
        wrote_rename = true
        break
      end
    end
    test.equal(wrote_rename, true)
  end)
end)
