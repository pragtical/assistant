local test = require "core.test"
local core = require "core"
local json = require "core.json"

local real_process = process

local function is_codex_appserver(command)
  return type(command) == "table"
    and tostring(command[1]):match("codex$")
    and command[2] == "app-server"
end

local function fake_proc(stdout_chunks)
  local proc = {
    stdout_chunks = stdout_chunks or {},
    writes = {},
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
    return ""
  end
  function proc:write(data)
    table.insert(self.writes, data)
    return #data
  end
  function proc:terminate()
    self.killed = true
    return true
  end
  return proc
end

local function parse_jsonl(buffer, messages)
  while true do
    local idx = buffer:find("\n", 1, true)
    if not idx then break end
    local line = buffer:sub(1, idx - 1)
    buffer = buffer:sub(idx + 1)
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end
    if line ~= "" then
      local ok, message = pcall(json.decode, line)
      if ok and type(message) == "table" then
        table.insert(messages, message)
      else
        table.insert(messages, { decode_error = tostring(message), raw = line })
      end
    end
  end
  return buffer
end

local function write_json(proc, message)
  proc:write(json.encode(message) .. "\n")
end

local function collect_codex_models()
  local proc, errmsg = process.start({ "codex", "app-server" }, {
    cwd = core.root_project() and core.root_project().path or ".",
    stdin = process.REDIRECT_PIPE,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE
  })
  if not proc then return nil, errmsg or "could not start codex app-server" end

  local stdout = ""
  local stderr = {}
  local messages = {}
  local init_done = false
  local listed = false
  local list_response

  write_json(proc, {
    id = 1,
    method = "initialize",
    params = {
      capabilities = {
        experimentalApi = true
      },
      clientInfo = {
        name = "pragtical-assistant-live-test",
        title = "Pragtical Assistant Live Test",
        version = "0.1.0"
      }
    }
  })

  local started = system.get_time()
  while proc:running() and system.get_time() - started < 8 do
    local out = proc:read_stdout(1024 * 8)
    if out and out ~= "" then
      stdout = parse_jsonl(stdout .. out, messages)
    end
    local err = proc:read_stderr(1024 * 8)
    if err and err ~= "" then table.insert(stderr, err) end

    for _, message in ipairs(messages) do
      if message.id == 1 and not init_done then
        init_done = true
        write_json(proc, { method = "initialized", params = {} })
        write_json(proc, {
          id = 2,
          method = "model/list",
          params = { limit = 100, includeHidden = false }
        })
      elseif message.id == 2 then
        list_response = message
      end
    end

    if list_response then break end
    coroutine.yield(0.02)
  end

  if proc:running() then proc:terminate() end

  if not list_response then
    return nil, string.format(
      "no model/list response; stdout=%s stderr=%s",
      json.encode(messages),
      table.concat(stderr)
    )
  end
  if list_response.error then
    return nil, string.format("model/list error: %s", json.encode(list_response.error))
  end

  local data = list_response.result and list_response.result.data
  return data, string.format("response=%s stderr=%s", json.encode(list_response), table.concat(stderr))
end

local function collect_codex_turn()
  local proc, errmsg = process.start({ "codex", "app-server" }, {
    cwd = core.root_project() and core.root_project().path or ".",
    stdin = process.REDIRECT_PIPE,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE
  })
  if not proc then return nil, errmsg or "could not start codex app-server" end

  local stdout = ""
  local stderr = {}
  local messages = {}
  local initialized = false
  local thread_started = false
  local turn_started = false
  local done = false
  local response = ""

  write_json(proc, {
    id = 1,
    method = "initialize",
    params = {
      capabilities = {
        experimentalApi = true
      },
      clientInfo = {
        name = "pragtical-assistant-live-test",
        title = "Pragtical Assistant Live Test",
        version = "0.1.0"
      }
    }
  })

  local seen = 0
  local started = system.get_time()
  while proc:running() and system.get_time() - started < 90 do
    local out = proc:read_stdout(1024 * 8)
    if out and out ~= "" then
      stdout = parse_jsonl(stdout .. out, messages)
    end
    local err = proc:read_stderr(1024 * 8)
    if err and err ~= "" then table.insert(stderr, err) end

    for i = seen + 1, #messages do
      local message = messages[i]
      if message.id == 1 and not initialized then
        initialized = true
        write_json(proc, { method = "initialized", params = {} })
        write_json(proc, {
          id = 2,
          method = "thread/start",
          params = {
            model = "gpt-5.3-codex",
            cwd = core.root_project() and core.root_project().path or ".",
            approvalPolicy = "never",
            sandbox = "workspace-write",
            serviceName = "pragtical_assistant_live_test"
          }
        })
      elseif message.id == 2 and not thread_started then
        local thread = message.result and message.result.thread
        if thread and thread.id then
          thread_started = thread.id
          write_json(proc, {
            id = 3,
            method = "turn/start",
            params = {
              threadId = thread.id,
              input = {
                { type = "text", text = "Reply with exactly: pong" }
              },
              cwd = core.root_project() and core.root_project().path or ".",
              approvalPolicy = "never",
              sandboxPolicy = {
                type = "workspaceWrite",
                writableRoots = { core.root_project() and core.root_project().path or "." },
                networkAccess = true
              },
              model = "gpt-5.3-codex"
            }
          })
        end
      elseif message.id == 3 then
        turn_started = true
      elseif message.method == "item/agentMessage/delta" then
        local params = message.params or {}
        response = response .. (params.delta or params.text or "")
      elseif message.method == "item/completed" then
        local item = message.params and message.params.item
        if type(item) == "table" and item.type == "agentMessage" and type(item.text) == "string" then
          response = item.text
        end
      elseif message.method == "turn/completed" then
        done = true
      end
    end
    seen = #messages

    if done then break end
    coroutine.yield(0.02)
  end

  if proc:running() then proc:terminate() end
  return response, string.format(
    "initialized=%s thread=%s turn=%s done=%s messages=%s stderr=%s",
    tostring(initialized),
    tostring(thread_started),
    tostring(turn_started),
    tostring(done),
    json.encode(messages),
    table.concat(stderr)
  )
end

test.describe("assistant live install", function()
  test.after_each(function()
    process = real_process
  end)

  test.it("loads installed assistant modules", function()
    local assistant = require "plugins.assistant"
    local Codex = require "plugins.assistant.agent.codex"
    local AppServerBackend = require "plugins.assistant.backend.appserver"

    test.equal(type(assistant), "table")
    test.equal(type(Codex), "table")
    test.equal(type(AppServerBackend), "table")

    local agent = Codex()
    test.equal(agent.backend, "appserver")
  end)

  test.it("lists Codex models through installed app-server backend", function()
    local AppServerBackend = require "plugins.assistant.backend.appserver"
    local Codex = require "plugins.assistant.agent.codex"

    local proc = fake_proc({
      '{"id":1,"result":{"userAgent":"test","platformFamily":"unix","platformOs":"linux"}}\n',
      '{"id":2,"result":{"data":[{"id":"gpt-5.4","model":"gpt-5.4","displayName":"GPT-5.4"},{"id":"gpt-5.4-mini","displayName":"GPT-5.4 Mini"}],"nextCursor":null}}\n'
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
    backend:list_models(Codex(), function(ok, err, result)
      if not ok then test.fail(err or "model list failed") end
      models = result
    end)

    coroutine.yield(0.2)

    test.same(models, { "gpt-5.4", "gpt-5.4-mini" })

    local initialized = false
    local listed = false
    for _, write in ipairs(proc.writes) do
      if write:find('"method":"initialized"', 1, true) then
        initialized = true
      elseif write:find('"method":"model/list"', 1, true) then
        listed = true
      end
    end
    test.equal(initialized, true)
    test.equal(listed, true)
  end)

  test.it("can probe real Codex app-server model output", function()
    test.skip_if(
      os.getenv("ASSISTANT_LIVE_CODEX") ~= "1",
      "set ASSISTANT_LIVE_CODEX=1 to run the real codex app-server probe"
    )

    local data, details = collect_codex_models()
    if os.getenv("ASSISTANT_LIVE_CODEX_DUMP") == "1" then
      print(details)
    end
    test.equal(type(data), "table", details)
    test.equal(#data > 0, true, details)
  end)

  test.it("can probe real Codex app-server turn output", function()
    test.skip_if(
      os.getenv("ASSISTANT_LIVE_CODEX_TURN") ~= "1",
      "set ASSISTANT_LIVE_CODEX_TURN=1 to run the real codex app-server turn probe"
    )

    local response, details = collect_codex_turn()
    print(details)
    test.equal(type(response), "string", details)
    test.equal(response ~= "", true, details)
  end)
end)
