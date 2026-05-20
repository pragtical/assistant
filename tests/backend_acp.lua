local test = require "core.test"
dofile("tests/helper.inc")
local config = require "core.config"
local Conversation = require "plugins.assistant.conversation"
local AcpBackend = require "plugins.assistant.backend.acp"
local Copilot = require "plugins.assistant.agent.copilot"

local real_process = process

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
    if #self.stdout_chunks == 0 then return "" end
    return table.remove(self.stdout_chunks, 1)
  end
  function proc:read_stderr()
    return ""
  end
  function proc:write(data)
    table.insert(self.writes, data)
    return #data
  end
  function proc:kill()
    self.killed = true
  end
  return proc
end

local function install_process(proc)
  process = {
    REDIRECT_PIPE = real_process.REDIRECT_PIPE,
    start = function(command)
      test.same(command, { "copilot", "--acp", "--stdio" })
      return proc
    end
  }
end

test.describe("assistant ACP backend", function()
  local old_reasoning_activity_messages

  test.before_each(function()
    old_reasoning_activity_messages = config.plugins.assistant.reasoning_activity_messages
    config.plugins.assistant.reasoning_activity_messages = true
  end)

  test.after_each(function()
    process = real_process
    config.plugins.assistant.reasoning_activity_messages = old_reasoning_activity_messages
  end)

  test.it("creates a session and streams ACP message chunks", function()
    local proc = fake_proc({
      '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}\n',
      '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1"}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"type":"agent_message_chunk","text":"po"}}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"type":"agent_message_chunk","text":"ng"}}}\n',
      '{"jsonrpc":"2.0","id":3,"result":{}}\n'
    })
    install_process(proc)

    local agent = Copilot()
    agent.collaboration_modes_by_id = {
      implementation = { id = "implementation", label = "Implementation" }
    }
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    local backend = AcpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
    end)

    coroutine.yield(0.4)

    test.equal(conversation.acp_session_id, "session-1")
    test.equal(response, "pong")
    test.equal(table.concat(proc.writes):find('"method":"initialize"', 1, true) ~= nil, true)
    test.equal(table.concat(proc.writes):find('"method":"session/prompt"', 1, true) ~= nil, true)
    test.equal(table.concat(proc.writes):find('"prompt":[{', 1, true) ~= nil, true)
    test.equal(table.concat(proc.writes):find('"text":"hello"', 1, true) ~= nil, true)
    test.equal(table.concat(proc.writes):find('"mcpServers":[]', 1, true) ~= nil, true)
  end)

  test.it("streams Copilot ACP content text chunks", function()
    local proc = fake_proc({
      '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}\n',
      '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1"}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello"}}}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":" there"}}}}\n',
      '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}\n'
    })
    install_process(proc)

    local agent = Copilot()
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    local backend = AcpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
    end)

    coroutine.yield(0.4)

    test.equal(response, "hello there")
  end)

  test.it("records ACP token usage updates for context left", function()
    local proc = fake_proc({
      '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}\n',
      '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1"}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"token_usage_update","tokenUsage":{"modelContextWindow":1000,"total":{"totalTokens":2500},"last":{"inputTokens":120,"outputTokens":30,"totalTokens":150}}}}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ok"}}}}\n',
      '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}\n'
    })
    install_process(proc)

    local agent = Copilot()
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    local backend = AcpBackend()
    local usage

    backend:send(agent, conversation, function(ok, _, _, meta)
      if ok and meta and meta.usage then usage = meta.usage end
    end)

    coroutine.yield(0.4)

    test.equal(usage.total_tokens, 150)
    test.equal(usage.cumulative_total_tokens, 2500)
    test.equal(conversation:context_left(), 850)
  end)

  test.it("surfaces Copilot ACP permission tool call details and selected option", function()
    local proc = fake_proc({
      '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}\n',
      '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1"}}\n',
      '{"jsonrpc":"2.0","id":100,"method":"session/request_permission","params":{"sessionId":"session-1","options":[{"kind":"allow_once","optionId":"allow_once","name":"Allow once"},{"kind":"allow_always","optionId":"allow_always","name":"Always allow"},{"kind":"reject_once","optionId":"reject_once","name":"Deny"}],"toolCall":{"toolCallId":"call-1","locations":[{"path":"external/session-state/session-1/plan.md"}],"kind":"read","title":"Access paths outside trusted directories","rawInput":{"path":"external/session-state/session-1/plan.md"},"status":"pending"}}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ok"}}}}\n',
      '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}\n'
    })
    install_process(proc)

    local agent = Copilot()
    local conversation = Conversation(agent, "project")
    conversation:add("user", "plan this", { autosave = false })
    local backend = AcpBackend()
    local requested

    backend:send(agent, conversation, function(ok, _, _, meta)
      if ok and meta and meta.event == "approval_request" then
        requested = meta.request
        backend:resolve_approval(agent, conversation, requested, "accept")
      end
    end)
    coroutine.yield(0.4)

    test.equal(requested.title, "Access paths outside trusted directories")
    test.equal(requested.body:find("Kind: read", 1, true) ~= nil, true)
    test.equal(requested.body:find("external/session-state/session-1/plan.md", 1, true) ~= nil, true)
    test.equal(#requested.options, 3)
    test.equal(backend.pending_requests[requested.id], nil)
    test.equal(requested.state.pending_requests[requested.id], nil)
    local writes = table.concat(proc.writes)
    test.equal(writes:find('"outcome":{', 1, true) ~= nil, true)
    test.equal(writes:find('"outcome":"selected"', 1, true) ~= nil, true)
    test.equal(writes:find('"optionId":"allow_once"', 1, true) ~= nil, true)
  end)

  test.it("does not finish a turn while a permission request is pending", function()
    local proc = fake_proc({
      '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}\n',
      '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1"}}\n',
      '{"jsonrpc":"2.0","id":100,"method":"session/request_permission","params":{"sessionId":"session-1","options":[{"kind":"allow_once","optionId":"allow_once","name":"Allow once"},{"kind":"reject_once","optionId":"reject_once","name":"Deny"}],"toolCall":{"toolCallId":"call-1","kind":"execute","title":"Run tests","rawInput":{"command":"make test"},"status":"pending"}}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"done"}}}}\n',
      '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}\n'
    })
    install_process(proc)

    local agent = Copilot()
    local conversation = Conversation(agent, "project")
    conversation:add("user", "run tests", { autosave = false })
    local backend = AcpBackend()
    local requested
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "approval_request" then
        requested = meta.request
      elseif ok and meta and meta.done then
        response = text
      end
    end)
    coroutine.yield(0.4)

    test.equal(requested.title, "Run tests")
    test.equal(response, nil)
    test.equal(conversation.status, "waiting for approval")

    backend:resolve_approval(agent, conversation, requested, "accept")
    coroutine.yield(0.4)

    test.equal(response, "done")
    test.equal(conversation.status, "idle")
  end)

  test.it("does not treat same-id permission requests as prompt responses", function()
    local proc = fake_proc({
      '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}\n',
      '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1"}}\n',
      '{"jsonrpc":"2.0","id":3,"method":"session/request_permission","params":{"sessionId":"session-1","options":[{"kind":"allow_once","optionId":"allow_once","name":"Allow once"},{"kind":"reject_once","optionId":"reject_once","name":"Deny"}],"toolCall":{"toolCallId":"call-1","kind":"edit","title":"Edit file","rawInput":{"path":"test.c"},"status":"pending"}}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"fixed"}}}}\n',
      '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}\n'
    })
    install_process(proc)

    local agent = Copilot()
    local conversation = Conversation(agent, "project")
    conversation:add("user", "fix it", { autosave = false })
    local backend = AcpBackend()
    local requested
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "approval_request" then
        requested = meta.request
      elseif ok and meta and meta.done then
        response = text
      end
    end)
    coroutine.yield(0.4)

    test.equal(requested.title, "Edit file")
    test.equal(response, nil)
    test.equal(conversation.status, "waiting for approval")

    backend:resolve_approval(agent, conversation, requested, "accept")
    coroutine.yield(0.4)

    test.equal(response, "fixed")
    test.equal(conversation.status, "idle")
  end)

  test.it("records Copilot ACP thoughts and tool activity in the transcript", function()
    local proc = fake_proc({
      '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}\n',
      '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1"}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"Planning score display improvements"}}}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"tool_call","toolCallId":"call-1","kind":"read","title":"Viewing project/main.c","rawInput":{"path":"project/main.c"},"status":"pending"}}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"tool_call_update","toolCallId":"call-1","title":"Viewing project/main.c","status":"completed"}}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"done"}}}}\n',
      '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}\n'
    })
    install_process(proc)

    local agent = Copilot()
    local conversation = Conversation(agent, "project")
    conversation:add("user", "improve score", { autosave = false })
    local backend = AcpBackend()

    backend:send(agent, conversation, function() end)
    coroutine.yield(0.4)

    local md = conversation:to_markdown()
    test.equal(md:find("## Activity", 1, true), nil)
    test.equal(md:find("**Thinking**: Planning score display improvements", 1, true) ~= nil, true)
    test.equal(md:find("Viewing project/main.c", 1, true) ~= nil, true)
    test.equal(md:find("`project/main.c`", 1, true) ~= nil, true)
    test.equal(md:find("(completed)", 1, true) ~= nil, true)
  end)

  test.it("hides Copilot ACP thought activity when disabled but keeps tool activity", function()
    config.plugins.assistant.reasoning_activity_messages = false
    local proc = fake_proc({
      '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}\n',
      '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1"}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"Planning score display improvements"}}}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"tool_call","toolCallId":"call-1","kind":"read","title":"Viewing project/main.c","rawInput":{"path":"project/main.c"},"status":"pending"}}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"tool_call_update","toolCallId":"call-1","title":"Viewing project/main.c","status":"completed"}}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"done"}}}}\n',
      '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}\n'
    })
    install_process(proc)

    local agent = Copilot()
    local conversation = Conversation(agent, "project")
    conversation:add("user", "improve score", { autosave = false })
    local backend = AcpBackend()
    local statuses = {}
    local original_set_status = conversation.set_status
    conversation.set_status = function(this, status, options)
      table.insert(statuses, status)
      return original_set_status(this, status, options)
    end

    backend:send(agent, conversation, function() end)
    coroutine.yield(0.4)

    local md = conversation:to_markdown()
    test.equal(md:find("Thinking: Planning score display improvements", 1, true), nil)
    test.equal(md:find("Viewing project/main.c", 1, true) ~= nil, true)
    test.equal(md:find("(completed)", 1, true) ~= nil, true)
    test.equal(table.concat(statuses, ","):find("reasoning", 1, true) ~= nil, true)
  end)

  test.it("records failed Copilot ACP tool update messages", function()
    local proc = fake_proc({
      '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}\n',
      '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1"}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"tool_call","toolCallId":"call-1","kind":"read","title":"Creating plan.md","rawInput":{"path":"project/plan.md"},"status":"pending"}}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"tool_call_update","toolCallId":"call-1","status":"failed","rawOutput":{"message":"The user rejected this tool call.","code":"rejected"}}}}\n',
      '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}\n'
    })
    install_process(proc)

    local agent = Copilot()
    local conversation = Conversation(agent, "project")
    conversation:add("user", "plan", { autosave = false })
    local backend = AcpBackend()

    backend:send(agent, conversation, function() end)
    coroutine.yield(0.4)

    local md = conversation:to_markdown()
    test.equal(md:find("Creating plan.md", 1, true) ~= nil, true)
    test.equal(md:find("(failed)", 1, true) ~= nil, true)
  end)

  test.it("renders Copilot ACP file edit diffs in activity messages", function()
    local proc = fake_proc({
      '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}\n',
      '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1"}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"tool_call","toolCallId":"call-1","kind":"edit","title":"Editing main.c","rawInput":{"path":"project/main.c"},"status":"pending"}}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"tool_call_update","toolCallId":"call-1","status":"completed","rawOutput":{"detailedContent":"diff --git a/main.c b/main.c\\n--- a/main.c\\n+++ b/main.c\\n@@ -1 +1 @@\\n-old\\n+new"}}}}\n',
      '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}\n'
    })
    install_process(proc)

    local agent = Copilot()
    local conversation = Conversation(agent, "project")
    conversation:add("user", "edit", { autosave = false })
    local backend = AcpBackend()

    backend:send(agent, conversation, function() end)
    coroutine.yield(0.4)

    local md = conversation:to_markdown()
    test.equal(md:find("## Activity", 1, true), nil)
    test.equal(md:find("**Editing main.c**:", 1, true) ~= nil, true)
    test.equal(md:find("```diff", 1, true) ~= nil, true)
    test.equal(md:find("diff --git a/main.c b/main.c", 1, true) ~= nil, true)
    test.equal(md:find("+new", 1, true) ~= nil, true)
  end)

  test.it("lists models from ACP session config options", function()
    local proc = fake_proc({
      '{"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{}}}\n',
      '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1","configOptions":[{"id":"model","type":"select","category":"model","currentValue":"b","options":[{"name":"Model B","value":"b"},{"name":"Model A","value":"a"}]}]}}\n'
    })
    install_process(proc)

    local agent = Copilot()
    local backend = AcpBackend()
    local models

    backend:list_models(agent, function(ok, _, result)
      if ok then models = result end
    end)
    coroutine.yield(0.4)

    test.same(models, { "Model A", "Model B" })
    test.same(agent.acp_model_options["Model A"], {
      config_id = "model",
      value = "a"
    })
    test.equal(table.concat(proc.writes):find('"mcpServers":[]', 1, true) ~= nil, true)
  end)

  test.it("reports ACP error data with invalid params", function()
    local proc = fake_proc({
      '{"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{}}}\n',
      '{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"Invalid params","data":{"expected":"array","path":"mcpServers"}}}\n'
    })
    install_process(proc)

    local agent = Copilot()
    local backend = AcpBackend()
    local errmsg

    backend:list_models(agent, function(ok, err)
      if not ok then errmsg = err end
    end)
    coroutine.yield(0.4)

    test.equal(errmsg:find("Invalid params", 1, true) ~= nil, true)
    test.equal(errmsg:find("mcpServers", 1, true) ~= nil, true)
  end)

  test.it("sets selected ACP model before sending a prompt", function()
    local proc = fake_proc({
      '{"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{}}}\n',
      '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1","configOptions":[{"id":"model","type":"select","category":"model","currentValue":"a","options":[{"name":"Model B","value":"b"},{"name":"Model A","value":"a"}]}]}}\n',
      '{"jsonrpc":"2.0","id":3,"result":{"configOptions":[]}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"type":"agent_message_chunk","text":"ok"}}}\n',
      '{"jsonrpc":"2.0","id":4,"result":{}}\n'
    })
    install_process(proc)

    local agent = Copilot()
    agent.model = "Model B"
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    local backend = AcpBackend()

    backend:send(agent, conversation, function() end)
    coroutine.yield(0.4)

    local writes = table.concat(proc.writes)
    test.equal(writes:find('"method":"session/set_config_option"', 1, true) ~= nil, true)
    test.equal(writes:find('"configId":"model"', 1, true) ~= nil, true)
    test.equal(writes:find('"value":"b"', 1, true) ~= nil, true)
  end)

  test.it("syncs ACP model and mode config updates into the conversation", function()
    local agent_mode = "https://agentclientprotocol.com/protocol/session-modes#agent"
    local plan_mode = "https://agentclientprotocol.com/protocol/session-modes#plan"
    local proc = fake_proc({
      '{"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{}}}\n',
      '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1","configOptions":[{"id":"model","type":"select","category":"model","currentValue":"gpt-5.4","options":[{"name":"Auto","value":"auto"},{"name":"GPT-5.4","value":"gpt-5.4"}]}]}}\n',
      '{"jsonrpc":"2.0","id":3,"result":{}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"config_option_update","configOptions":[{"id":"model","type":"select","category":"model","currentValue":"auto","options":[{"name":"Auto","value":"auto"},{"name":"GPT-5.4","value":"gpt-5.4"}]},{"id":"mode","type":"select","category":"mode","currentValue":"' .. plan_mode .. '","options":[{"name":"Agent","value":"' .. agent_mode .. '"},{"name":"Plan","value":"' .. plan_mode .. '"}]}]}}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ok"}}}}\n',
      '{"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}\n'
    })
    install_process(proc)

    local agent = Copilot()
    agent.model = "Auto"
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    local backend = AcpBackend()
    local saw_config_update = false

    backend:send(agent, conversation, function(ok, _, _, meta)
      if ok and meta and meta.event == "config_update" then
        saw_config_update = true
      end
    end)
    coroutine.yield(0.4)

    test.equal(saw_config_update, true)
    test.equal(agent.model, "Auto")
    test.equal(conversation.collaboration_mode, plan_mode)
    test.equal(#agent.collaboration_modes, 2)
    local writes = table.concat(proc.writes)
    test.equal(writes:find('"method":"session/set_config_option"', 1, true) ~= nil, true)
    test.equal(writes:find('"value":"auto"', 1, true) ~= nil, true)
  end)

  test.it("adds an authentication recovery hint to ACP authentication errors", function()
    local proc = fake_proc({
      '{"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{},"authMethods":[{"name":"Login","_meta":{"terminal-auth":{"command":"copilot","args":["login"]}}}]}}\n',
      '{"jsonrpc":"2.0","id":2,"error":{"code":-32001,"message":"Authentication required"}}\n'
    })
    install_process(proc)

    local agent = Copilot()
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    local backend = AcpBackend()
    local errmsg

    backend:send(agent, conversation, function(ok, err)
      if not ok then errmsg = err end
    end)
    coroutine.yield(0.4)

    test.equal(errmsg, "Authentication required. Run `copilot login`.")
    local md = conversation:to_markdown()
    test.equal(md:find("## Activity", 1, true), nil)
    test.equal(md:find("Run `copilot login`.", 1, true) ~= nil, true)
  end)

  test.it("creates a fresh ACP session when a persisted session is missing after restart", function()
    local proc = fake_proc({
      '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}\n',
      '{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"Session stale-session not found"}}\n',
      '{"jsonrpc":"2.0","id":3,"result":{"sessionId":"session-2"}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-2","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"continued"}}}}\n',
      '{"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}\n'
    })
    install_process(proc)

    local agent = Copilot()
    local conversation = Conversation(agent, "project")
    conversation.acp_session_id = "stale-session"
    conversation:add("user", "continue", { autosave = false })
    local backend = AcpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
    end)
    coroutine.yield(0.4)

    local writes = table.concat(proc.writes)
    test.equal(response, "continued")
    test.equal(conversation.acp_session_id, "session-2")
    test.equal(conversation:to_markdown():find("Previous ACP session was not found", 1, true) ~= nil, true)
    test.equal(writes:find('"sessionId":"stale-session"', 1, true) ~= nil, true)
    test.equal(writes:find('"method":"session/new"', 1, true) ~= nil, true)
    test.equal(writes:find('"sessionId":"session-2"', 1, true) ~= nil, true)
  end)

  test.it("sends session mode when the ACP server advertises modes", function()
    local proc = fake_proc({
      '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"sessionModes":[{"id":"plan","label":"Plan"}]}}}\n',
      '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1"}}\n',
      '{"jsonrpc":"2.0","id":3,"result":{}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"type":"agent_message_chunk","text":"ok"}}}\n',
      '{"jsonrpc":"2.0","id":4,"result":{}}\n'
    })
    install_process(proc)

    local agent = Copilot()
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "plan"
    conversation:add("user", "plan this", { autosave = false })
    local backend = AcpBackend()

    backend:send(agent, conversation, function() end)
    coroutine.yield(0.4)

    local writes = table.concat(proc.writes)
    test.equal(writes:find('"method":"session/set_mode"', 1, true) ~= nil, true)
    test.equal(writes:find('"modeId":"plan"', 1, true) ~= nil, true)
  end)

  test.it("maps generic implementation mode to advertised ACP agent mode", function()
    local agent_mode = "https://agentclientprotocol.com/protocol/session-modes#agent"
    local plan_mode = "https://agentclientprotocol.com/protocol/session-modes#plan"
    local proc = fake_proc({
      '{"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{"sessionModes":["' .. agent_mode .. '","' .. plan_mode .. '"]}}}\n',
      '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1"}}\n',
      '{"jsonrpc":"2.0","id":3,"result":{}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"type":"agent_message_chunk","text":"ok"}}}\n',
      '{"jsonrpc":"2.0","id":4,"result":{}}\n'
    })
    install_process(proc)

    local agent = Copilot()
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "implementation"
    conversation:add("user", "hello", { autosave = false })
    local backend = AcpBackend()

    backend:send(agent, conversation, function() end)
    coroutine.yield(0.4)

    local writes = table.concat(proc.writes)
    test.equal(writes:find('"method":"session/set_mode"', 1, true) ~= nil, true)
    test.equal(writes:find('"modeId":"' .. agent_mode .. '"', 1, true) ~= nil, true)
  end)

  test.it("denies mutating ACP filesystem requests in plan mode", function()
    local proc = fake_proc({
      '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}\n',
      '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1"}}\n',
      '{"jsonrpc":"2.0","id":"server-write","method":"fs/writeTextFile","params":{"path":"denied.txt","content":"no"}}\n',
      '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"type":"agent_message_chunk","text":"ok"}}}\n',
      '{"jsonrpc":"2.0","id":3,"result":{}}\n'
    })
    install_process(proc)

    local agent = Copilot()
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "plan"
    conversation:add("user", "inspect only", { autosave = false })
    local backend = AcpBackend()

    backend:send(agent, conversation, function() end)
    coroutine.yield(0.4)

    local writes = table.concat(proc.writes)
    test.equal(writes:find('"id":"server-write"', 1, true) ~= nil, true)
    test.equal(writes:find('filesystem writes are denied in Plan mode', 1, true) ~= nil, true)
  end)
end)
