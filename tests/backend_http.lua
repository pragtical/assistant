local test = require "core.test"
dofile("tests/helper.inc")
local core = require "core"
local config = require "core.config"
local http = require "core.http"
local json = require "core.json"
local common = require "core.common"
local Conversation = require "plugins.assistant.conversation"
local Agent = require "plugins.assistant.agent"
local HttpBackend = require "plugins.assistant.backend.http"
local Ollama = require "plugins.assistant.agent.ollama"
local OpenAI = require "plugins.assistant.agent.openai"
local DeepSeek = require "plugins.assistant.agent.deepseek"
local tools = require "plugins.assistant.tools"

test.describe("assistant http backend", function()
  local old_allow_any_read_path
  local old_log_raw_messages
  local old_request_timeout_ms
  local old_fetch_model_metadata
  local old_verbose_tool_calling
  local old_verbose_activity
  local old_reasoning_activity_messages
  local old_persist_reasoning_content

  test.before_each(function()
    old_allow_any_read_path = config.plugins.assistant.allow_any_read_path
    old_log_raw_messages = config.plugins.assistant.log_raw_messages
    old_request_timeout_ms = config.plugins.assistant.request_timeout_ms
    old_fetch_model_metadata = config.plugins.assistant.fetch_model_metadata
    old_verbose_tool_calling = config.plugins.assistant.verbose_tool_calling
    old_verbose_activity = config.plugins.assistant.verbose_activity
    old_reasoning_activity_messages = config.plugins.assistant.reasoning_activity_messages
    old_persist_reasoning_content = config.plugins.assistant.persist_reasoning_content
    config.plugins.assistant.allow_any_read_path = false
    config.plugins.assistant.log_raw_messages = true
    config.plugins.assistant.request_timeout_ms = 300000
    config.plugins.assistant.fetch_model_metadata = false
    config.plugins.assistant.verbose_tool_calling = false
    config.plugins.assistant.verbose_activity = false
    config.plugins.assistant.reasoning_activity_messages = true
    config.plugins.assistant.persist_reasoning_content = false
  end)

  test.after_each(function()
    config.plugins.assistant.allow_any_read_path = old_allow_any_read_path
    config.plugins.assistant.log_raw_messages = old_log_raw_messages
    config.plugins.assistant.request_timeout_ms = old_request_timeout_ms
    config.plugins.assistant.fetch_model_metadata = old_fetch_model_metadata
    config.plugins.assistant.verbose_tool_calling = old_verbose_tool_calling
    config.plugins.assistant.verbose_activity = old_verbose_activity
    config.plugins.assistant.reasoning_activity_messages = old_reasoning_activity_messages
    config.plugins.assistant.persist_reasoning_content = old_persist_reasoning_content
  end)

  local function run_background_threads_immediately()
    local old_add_background_thread = core.add_background_thread
    local old_add_thread = core.add_thread
    core.add_background_thread = function(fn)
      fn()
      return "test-thread"
    end
    core.add_thread = function(fn)
      fn()
      return "test-thread"
    end
    return function()
      core.add_background_thread = old_add_background_thread
      core.add_thread = old_add_thread
    end
  end

  test.it("reports json api errors from non-streaming requests", function()
    local old_post = http.post
    http.post = function(_, _, _, options)
      options.on_done(true, nil, {
        error = {
          message = "invalid api key"
        }
      }, { status = 401 })
    end

    local agent = Ollama({ stream = false })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local ok_result
    local err_result

    backend:send(agent, conversation, function(ok, err)
      ok_result = ok
      err_result = err
    end)

    http.post = old_post
    test.equal(ok_result, false)
    test.equal(err_result, "Chat request failed for Ollama: HTTP 401: invalid api key")
  end)

  test.it("shows a reasoning activity for non-streaming responses", function()
    local old_post = http.post
    http.post = function(_, _, _, options)
      options.on_done(true, nil, {
        choices = {
          {
            message = {
              role = "assistant",
              content = "final answer",
              reasoning_content = "first inspect, then decide"
            }
          }
        }
      }, { status = 200 })
    end

    local agent = Ollama({ stream = false })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
    end)

    http.post = old_post
    test.equal(response, "final answer")

    local reasoning_shown = false
    for _, message in ipairs(conversation.messages or {}) do
      if message.role == "activity"
        and tostring(message.message or ""):find("^Reasoning")
      then
        reasoning_shown = true
      end
    end
    test.equal(reasoning_shown, true)
  end)

  test.it("reports http status errors from streaming requests", function()
    local old_request = http.request
    http.request = function(_, _, options)
      options.on_header({ status = 400 })
      options.on_done(true, nil, nil, { status = 400 })
    end

    local agent = Ollama({ stream = true })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local ok_result
    local err_result

    backend:send(agent, conversation, function(ok, err)
      ok_result = ok
      err_result = err
    end)

    http.request = old_request
    test.equal(ok_result, false)
    test.equal(err_result, "Chat request failed for Ollama: HTTP 400: request failed")
  end)

  test.it("records transport errors from streaming requests in raw logs", function()
    local old_request = http.request
    http.request = function(_, _, options)
      options.on_header({ status = 200 })
      options.on_done(false, "socket reset", nil, { status = 200 })
    end

    local agent = Ollama({ stream = true })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local err_result

    backend:send(agent, conversation, function(_, err)
      err_result = err
    end)

    http.request = old_request
    local raw = conversation:raw_responses_text()
    test.equal(err_result, "Chat request failed for Ollama: HTTP 200: socket reset")
    test.equal(raw:find('"kind":"http-error"', 1, true) ~= nil, true)
    test.equal(raw:find('"message":"socket reset"', 1, true) ~= nil, true)
    test.equal(raw:find('"status":200', 1, true) ~= nil, true)
  end)

  test.it("explains streaming 429 responses without a parsed json body", function()
    local old_request = http.request
    http.request = function(_, _, options)
      options.on_header({ status = 429 })
      options.on_done(true, nil, nil, { status = 429 })
    end

    local agent = Ollama({ stream = true })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local err_result

    backend:send(agent, conversation, function(_, err)
      err_result = err
    end)

    http.request = old_request
    test.equal(
      err_result,
      "Chat request failed for Ollama: HTTP 429: rate limit or quota exceeded; check provider billing, usage limits, and retry later"
    )
  end)

  test.it("reports json api errors from streaming requests", function()
    local old_request = http.request
    http.request = function(_, _, options)
      options.on_header({ status = 400 })
      options.on_chunk('{"error":{"message":"model is required"}}')
      options.on_done(true, nil, nil, { status = 400 })
    end

    local agent = Ollama({ stream = true })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local err_result

    backend:send(agent, conversation, function(_, err)
      err_result = err
    end)

    http.request = old_request
    test.equal(err_result, "Chat request failed for Ollama: HTTP 400: model is required")
  end)

  test.it("streams sse events from raw http chunks", function()
    local old_request = http.request
    http.request = function(_, _, options)
      options.on_header({ status = 200 })
      options.on_chunk('data: {"choices":[{"delta":{"content":"hel"}}]}\n\n')
      options.on_chunk('data: {"choices":[{"delta":{"content":"lo"}}]}\n\n')
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = OpenAI({ stream = true })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
    end)

    http.request = old_request
    test.equal(response, "hello")
  end)

  test.it("deduplicates cumulative streamed message snapshots", function()
    local old_request = http.request
    http.request = function(_, _, options)
      options.on_header({ status = 200 })
      options.on_chunk('data: {"choices":[{"message":{"content":"I see missing pieces."}}]}\n\n')
      options.on_chunk('data: {"choices":[{"message":{"content":"I see missing pieces. Let me fix it."}}]}\n\n')
      options.on_chunk('data: {"choices":[{"message":{"content":"I see missing pieces. Let me fix it."},"finish_reason":"stop"}]}\n\n')
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = OpenAI({ stream = true })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
    end)

    http.request = old_request
    test.equal(response, "I see missing pieces. Let me fix it.")
  end)

  test.it("deduplicates repeated streamed text delta sequences", function()
    local old_request = http.request
    http.request = function(_, _, options)
      options.on_header({ status = 200 })
      local chunks = {
        "220", " passed", ",", " ", "3", " failed", ".", " Let", " me", " see", " which", " tests", " failed", "\n\n",
        "220", " passed", ",", " ", "3", " failed", ".", " Let", " me", " see", " which", " tests", " failed", "\n\n",
        "The failure is in folding."
      }
      for _, text in ipairs(chunks) do
        options.on_chunk("data: " .. json.encode({
          choices = {
            {
              delta = { content = text }
            }
          }
        }) .. "\n\n")
      end
      options.on_chunk('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n')
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = OpenAI({ stream = true })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
    end)

    http.request = old_request
    test.equal(response, "220 passed, 3 failed. Let me see which tests failed\n\nThe failure is in folding.")
  end)

  test.it("generates conversation titles with a focused side request", function()
    local old_post = http.post
    local title_payload
    http.post = function(_, _, _, options)
      title_payload = json.decode(options.body)
      options.on_done(true, nil, {
        choices = {
          {
            message = {
              content = '"Tiny SDL Tetris Game."'
            }
          }
        }
      }, { status = 200 })
    end

    local agent = Ollama({ stream = true })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local title

    backend:generate_conversation_title(agent, conversation, "Create a tiny SDL2 Tetris game.", function(ok, _, value)
      if ok then title = value end
    end)

    http.post = old_post
    test.equal(title, "Tiny SDL Tetris Game")
    test.equal(title_payload.stream, false)
    test.equal(title_payload.tools, nil)
    test.equal(title_payload.messages[2].content, "Create a tiny SDL2 Tetris game.")
  end)

  test.it("routes streamed escaped invoke text as a tool call", function()
    local old_request = http.request
    local request
    local response
    http.request = function(_, _, options)
      options.on_header({ status = 200 })
      options.on_chunk('data: {"choices":[{"delta":{"content":"&lt;function_calls&gt;\\n&lt;invoke name=\\"write\\"&gt;\\n&lt;parameter name=\\"path\\"&gt;tetris.c&lt;/parameter&gt;\\n&lt;parameter name=\\"content\\"&gt;#include &amp;lt;SDL2/SDL.h&amp;gt;\\n&lt;/parameter&gt;\\n&lt;/invoke&gt;\\n&lt;/function_calls&gt;"}}]}\n\n')
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = tools.register_agent_tools(Ollama({ stream = true }))
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "tool_call_request" then
        request = meta.request
      elseif ok and meta and meta.done then
        response = text
      end
    end)

    http.request = old_request
    test.equal(response, nil)
    test.equal(request ~= nil, true)
    test.equal(request.call.name, "write")
    test.equal(request.call.arguments.path, "tetris.c")
    test.equal(request.call.arguments.content:find("#include <SDL2/SDL.h>", 1, true) ~= nil, true)
  end)

  test.it("filters streamed private thinking tags from visible transcript", function()
    local old_request = http.request
    http.request = function(_, _, options)
      options.on_header({ status = 200 })
      options.on_chunk('data: {"choices":[{"delta":{"content":"<ant"}}]}\n\n')
      options.on_chunk('data: {"choices":[{"delta":{"content":"Thinking>hidden"}}]}\n\n')
      options.on_chunk('data: {"choices":[{"delta":{"content":"</antThinking>visible"}}]}\n\n')
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = Ollama({ stream = true })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response
    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
    end)

    http.request = old_request
    test.equal(response, "visible")
  end)

  test.it("flushes raw stream events before streaming requests finish", function()
    local old_request = http.request
    local conversation
    local raw_during_stream
    http.request = function(_, _, options)
      options.on_header({ status = 200 })
      options.on_chunk('data: {"choices":[{"delta":{"content":"hel"}}]}\n\n')
      raw_during_stream = conversation:raw_responses_text()
      options.on_chunk('data: {"choices":[{"delta":{"content":"lo"}}]}\n\n')
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = OpenAI({ stream = true })
    conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
    end)

    http.request = old_request
    test.equal(response, "hello")
    test.equal(raw_during_stream:find('"kind":"http%-stream%-event"') ~= nil, true)
    test.equal(raw_during_stream:find("hel", 1, true) ~= nil, true)
  end)

  test.it("passes configured timeout to streaming chat requests", function()
    local old_request = http.request
    local timeout_result
    http.request = function(_, _, options)
      timeout_result = options.timeout
      options.on_header({ status = 200 })
      options.on_chunk('data: {"choices":[{"delta":{"content":"ok"}}]}\n\n')
      options.on_done(true, nil, nil, { status = 200 })
    end
    config.plugins.assistant.request_timeout_ms = 450000

    local agent = OpenAI({ stream = true })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    backend:send(agent, conversation, function() end)

    http.request = old_request
    test.equal(timeout_result, 450)
  end)

  test.it("passes configured timeout to non-streaming chat requests", function()
    local old_post = http.post
    local timeout_result
    http.post = function(_, _, _, options)
      timeout_result = options.timeout
      options.on_done(true, nil, {
        choices = {
          { message = { content = "done" } }
        }
      }, { status = 200 })
    end
    config.plugins.assistant.request_timeout_ms = 420000

    local agent = Ollama({ stream = false })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    backend:send(agent, conversation, function() end)

    http.post = old_post
    test.equal(timeout_result, 420)
  end)

  test.it("refreshes ollama model metadata before chat requests when enabled", function()
    local old_post = http.post
    local old_fetch_model_metadata = config.plugins.assistant.fetch_model_metadata
    config.plugins.assistant.fetch_model_metadata = true

    local calls = {}
    http.post = function(url, _, _, options)
      table.insert(calls, url)
      if url:find("/api/show", 1, true) then
        options.on_done(true, nil, {
          parameters = "temperature 0.7\nnum_ctx 32768",
          model_info = {
            ["qwen3.context_length"] = 262144
          }
        }, { status = 200 })
      else
        options.on_done(true, nil, {
          choices = {
            { message = { content = "done" } }
          },
          usage = {
            prompt_tokens = 10,
            completion_tokens = 2,
            total_tokens = 12
          }
        }, { status = 200 })
      end
    end

    local agent = Ollama({ stream = false, model = "qwen3" })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response
    backend:send(agent, conversation, function(ok, err, text)
      test.equal(ok, true)
      test.equal(err, nil)
      response = text
    end)

    http.post = old_post
    config.plugins.assistant.fetch_model_metadata = old_fetch_model_metadata

    test.equal(#calls, 2)
    test.equal(calls[1]:find("/api/show", 1, true) ~= nil, true)
    test.equal(response, "done")
    test.equal(agent.model_metadata.context_window, 32768)
    test.equal(agent.model_metadata.model_context_window, 262144)
    test.equal(conversation.options.context, 32768)
  end)

  test.it("uses agent preferred timeout when no timeout is configured", function()
    local old_post = http.post
    local timeout_result
    http.post = function(_, _, _, options)
      timeout_result = options.timeout
      options.on_done(true, nil, {
        choices = {
          { message = { content = "done" } }
        }
      }, { status = 200 })
    end
    config.plugins.assistant.request_timeout_ms = nil

    local agent = Ollama({
      stream = false,
      model_metadata = {
        preferred_timeout_ms = 123000
      }
    })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    backend:send(agent, conversation, function() end)

    http.post = old_post
    test.equal(timeout_result, 123)
  end)

  test.it("reports provider request timeouts with the configured duration", function()
    local old_request = http.request
    http.request = function(_, _, options)
      options.on_header({ status = 200 })
      options.on_done(false, "request timed out", nil, { status = 200 })
    end
    config.plugins.assistant.request_timeout_ms = 1800000

    local agent = OpenAI({ stream = true })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local error_text
    backend:send(agent, conversation, function(ok, err)
      if not ok then error_text = err end
    end)

    http.request = old_request
    test.equal(error_text:find("timed out for", 1, true) ~= nil, true)
    test.equal(error_text:find("1800 seconds", 1, true) ~= nil, true)
    test.equal(error_text:find("HTTP 200", 1, true), nil)
  end)

  test.it("streams sse events with crlf framing", function()
    local old_request = http.request
    http.request = function(_, _, options)
      options.on_header({ status = 200 })
      options.on_chunk('data: {"type":"response.output_text.delta","delta":"hel"}\r\n\r\n')
      options.on_chunk('data: {"type":"response.output_text.delta","delta":"lo"}\r\n\r\n')
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = OpenAI({ stream = true })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
    end)

    http.request = old_request
    test.equal(response, "hello")
  end)

  test.it("reports sse error events", function()
    local old_request = http.request
    http.request = function(_, _, options)
      options.on_header({ status = 200 })
      options.on_chunk('data: {"type":"error","error":{"message":"bad stream"}}\r\n\r\n')
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = OpenAI({ stream = true })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local err_result

    backend:send(agent, conversation, function(_, err)
      err_result = err
    end)

    http.request = old_request
    test.equal(err_result, "Chat request failed for OpenAI: HTTP 200: bad stream")
  end)

  test.it("records streamed OpenAI responses reasoning as activity", function()
    local old_request = http.request
    http.request = function(_, _, options)
      options.on_header({ status = 200 })
      options.on_chunk('data: {"type":"response.reasoning_text.delta","delta":"Thinking"}\n\n')
      options.on_chunk('data: {"type":"response.output_text.delta","delta":"answer"}\n\n')
      options.on_chunk('data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}\n\n')
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = OpenAI({ stream = true })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
    end)

    http.request = old_request
    local found_reasoning = false
    for _, message in ipairs(conversation.messages) do
      if message.role == "activity"
        and message.message:find("Reasoning", 1, true)
        and message.message:find("Thinking", 1, true)
      then
        found_reasoning = true
      end
    end
    test.equal(response, "answer")
    test.equal(found_reasoning, true)
  end)

  test.it("records streamed chat reasoning deltas as activity", function()
    local old_request = http.request
    http.request = function(_, _, options)
      options.on_header({ status = 200 })
      options.on_chunk('data: {"choices":[{"delta":{"reasoning_content":"Thinking"},"finish_reason":null}]}\n\n')
      options.on_chunk('data: {"choices":[{"delta":{"content":"answer"},"finish_reason":null}]}\n\n')
      options.on_chunk('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n')
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = Ollama({ stream = true })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
    end)

    http.request = old_request
    local found_reasoning = false
    for _, message in ipairs(conversation.messages) do
      if message.role == "activity" and message.message:find("Thinking", 1, true) then
        found_reasoning = true
      end
    end
    test.equal(response, "answer")
    test.equal(found_reasoning, true)
  end)

  test.it("replays stored reasoning_content for DeepSeek by default", function()
    local agent = DeepSeek()
    local conversation = Conversation(agent, "project")
    conversation:add("assistant", "answer", {
      autosave = false,
      meta = {
        provider_reasoning_content = "private chain"
      }
    })

    local payload = agent:build_payload(conversation)
    local assistant_message
    for _, message in ipairs(payload.messages or {}) do
      if message.role == "assistant" and message.content == "answer" then
        assistant_message = message
      end
    end

    test.not_nil(assistant_message)
    test.equal(assistant_message.reasoning_content, "private chain")
  end)

  test.it("replays stored reasoning_content for explicit DeepSeek reasoning", function()
    local agent = DeepSeek({ reasoning_effort = "low" })
    local conversation = Conversation(agent, "project")
    conversation:add("assistant", "answer", {
      autosave = false,
      meta = {
        provider_reasoning_content = "private chain"
      }
    })

    local payload = agent:build_payload(conversation)
    local assistant_message
    for _, message in ipairs(payload.messages or {}) do
      if message.role == "assistant" and message.content == "answer" then
        assistant_message = message
      end
    end

    test.not_nil(assistant_message)
    test.equal(assistant_message.reasoning_content, "private chain")
  end)

  test.it("replays empty reasoning_content for DeepSeek assistant messages without captured thinking", function()
    local agent = DeepSeek()
    local conversation = Conversation(agent, "project")
    conversation:add("assistant", "answer", { autosave = false })

    local payload = agent:build_payload(conversation)
    local assistant_message
    for _, message in ipairs(payload.messages or {}) do
      if message.role == "assistant" and message.content == "answer" then
        assistant_message = message
      end
    end

    test.not_nil(assistant_message)
    test.equal(assistant_message.reasoning_content, "")
  end)

  test.it("does not replay stored reasoning_content for agents without opt-in", function()
    local agent = Ollama()
    local conversation = Conversation(agent, "project")
    conversation:add("assistant", "answer", {
      autosave = false,
      meta = {
        provider_reasoning_content = "private chain"
      }
    })

    local payload = agent:build_payload(conversation)
    local assistant_message
    for _, message in ipairs(payload.messages or {}) do
      if message.role == "assistant" and message.content == "answer" then
        assistant_message = message
      end
    end

    test.not_nil(assistant_message)
    test.equal(assistant_message.reasoning_content, nil)
  end)

  test.it("persist_reasoning_content forces replay for agents without opt-in", function()
    config.plugins.assistant.persist_reasoning_content = true
    local agent = Ollama()
    local conversation = Conversation(agent, "project")
    conversation:add("assistant", "answer", {
      autosave = false,
      meta = {
        provider_reasoning_content = "private chain"
      }
    })

    local payload = agent:build_payload(conversation)
    local assistant_message
    for _, message in ipairs(payload.messages or {}) do
      if message.role == "assistant" and message.content == "answer" then
        assistant_message = message
      end
    end

    test.not_nil(assistant_message)
    test.equal(assistant_message.reasoning_content, "private chain")
  end)

  test.it("adds empty reasoning_content for OpenAI-compatible chat agents with provider requirement", function()
    config.plugins.assistant.persist_reasoning_content = true
    local agent = Ollama()
    local conversation = Conversation(agent, "project")
    conversation:add("assistant", "answer", { autosave = false })

    local payload = agent:build_payload(conversation)
    local assistant_message
    for _, message in ipairs(payload.messages or {}) do
      if message.role == "assistant" and message.content == "answer" then
        assistant_message = message
      end
    end

    test.not_nil(assistant_message)
    test.equal(assistant_message.reasoning_content, "")
  end)

  test.it("does not add empty reasoning_content for agents without provider requirement", function()
    config.plugins.assistant.persist_reasoning_content = true
    local agent = Agent()
    local conversation = Conversation(agent, "project")
    conversation:add("assistant", "answer", { autosave = false })

    local payload = agent:build_payload(conversation)
    local assistant_message
    for _, message in ipairs(payload.messages or {}) do
      if message.role == "assistant" and message.content == "answer" then
        assistant_message = message
      end
    end

    test.not_nil(assistant_message)
    test.equal(assistant_message.reasoning_content, nil)
  end)

  test.it("returns streamed reasoning_content metadata for explicit DeepSeek reasoning", function()
    local old_request = http.request
    http.request = function(_, _, options)
      options.on_header({ status = 200 })
      options.on_chunk('data: {"choices":[{"delta":{"reasoning_content":"Thinking"},"finish_reason":null}]}\n\n')
      options.on_chunk('data: {"choices":[{"delta":{"content":"answer"},"finish_reason":null}]}\n\n')
      options.on_chunk('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n')
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = DeepSeek({ stream = true, reasoning_effort = "low" })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local reasoning_content

    backend:send(agent, conversation, function(ok, _, _, meta)
      if ok and meta and meta.done then
        reasoning_content = meta.provider_reasoning_content
      end
    end)

    http.request = old_request
    test.equal(reasoning_content, "Thinking")
  end)

  test.it("replays reasoning_content on DeepSeek tool calls by default", function()
    local agent = DeepSeek()
    local calls = {
      {
        id = "call_1",
        name = "read",
        arguments = { path = "init.lua" },
        arguments_text = '{"path":"init.lua"}',
        _assistant_provider_reasoning_content = "private chain"
      }
    }

    local provider_message = agent:tool_call_provider_message(calls, 1)

    test.not_nil(provider_message)
    test.equal(provider_message.role, "assistant")
    test.equal(provider_message.reasoning_content, "private chain")
  end)

  test.it("replays reasoning_content on explicit DeepSeek tool-call provider messages", function()
    local agent = DeepSeek({ reasoning_effort = "low" })
    local calls = {
      {
        id = "call_1",
        name = "read",
        arguments = { path = "init.lua" },
        arguments_text = '{"path":"init.lua"}',
        _assistant_provider_reasoning_content = "private chain"
      }
    }

    local provider_message = agent:tool_call_provider_message(calls, 1)

    test.not_nil(provider_message)
    test.equal(provider_message.role, "assistant")
    test.equal(provider_message.reasoning_content, "private chain")
  end)

  test.it("replays empty reasoning_content on DeepSeek tool calls without captured thinking", function()
    local agent = DeepSeek()
    local call = {
      id = "call_1",
      name = "read",
      arguments = { path = "init.lua" },
      arguments_text = '{"path":"init.lua"}'
    }
    local conversation = Conversation(agent, "project")
    conversation:add("tool_call", "read", {
      autosave = false,
      meta = {
        provider_message = agent:tool_call_provider_message({ call })
      }
    })
    conversation:add("tool_result", "done", {
      autosave = false,
      meta = {
        provider_message = agent:tool_result_provider_message(call, "done")
      }
    })

    local payload = agent:build_payload(conversation)
    local tool_call_message
    for _, message in ipairs(payload.messages or {}) do
      if message.role == "assistant" and type(message.tool_calls) == "table" then
        tool_call_message = message
      end
    end

    test.not_nil(tool_call_message)
    test.equal(tool_call_message.reasoning_content, "")
  end)

  test.it("hides streamed chat reasoning activity when disabled", function()
    config.plugins.assistant.reasoning_activity_messages = false
    local old_request = http.request
    http.request = function(_, _, options)
      options.on_header({ status = 200 })
      options.on_chunk('data: {"choices":[{"delta":{"reasoning_content":"Thinking"},"finish_reason":null}]}\n\n')
      options.on_chunk('data: {"choices":[{"delta":{"content":"answer"},"finish_reason":null}]}\n\n')
      options.on_chunk('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n')
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = Ollama({ stream = true })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response
    local statuses = {}
    local original_set_status = conversation.set_status
    conversation.set_status = function(this, status, options)
      table.insert(statuses, status)
      return original_set_status(this, status, options)
    end

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
    end)

    http.request = old_request
    local found_reasoning = false
    for _, message in ipairs(conversation.messages) do
      if message.role == "activity" and message.message:find("Thinking", 1, true) then
        found_reasoning = true
      end
    end
    test.equal(response, "answer")
    test.equal(found_reasoning, false)
    test.equal(table.concat(statuses, ","):find("reasoning", 1, true) ~= nil, true)
  end)

  test.it("hides streamed OpenAI responses reasoning activity when disabled", function()
    config.plugins.assistant.reasoning_activity_messages = false
    local old_request = http.request
    http.request = function(_, _, options)
      options.on_header({ status = 200 })
      options.on_chunk('data: {"type":"response.reasoning_text.delta","delta":"Thinking"}\n\n')
      options.on_chunk('data: {"type":"response.output_text.delta","delta":"answer"}\n\n')
      options.on_chunk('data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}\n\n')
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = OpenAI({ stream = true })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
    end)

    http.request = old_request
    local found_reasoning = false
    for _, message in ipairs(conversation.messages) do
      if message.role == "activity" and message.message:find("Thinking", 1, true) then
        found_reasoning = true
      end
    end
    test.equal(response, "answer")
    test.equal(found_reasoning, false)
  end)

  test.it("creates separate reasoning activity messages for separate streamed turns", function()
    local old_request = http.request
    local turn = 0
    http.request = function(_, _, options)
      turn = turn + 1
      options.on_header({ status = 200 })
      options.on_chunk('data: {"choices":[{"delta":{"reasoning":"Thinking ' .. turn .. '"},"finish_reason":null}]}\n\n')
      options.on_chunk('data: {"choices":[{"delta":{"content":"answer ' .. turn .. '"},"finish_reason":null}]}\n\n')
      options.on_chunk('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n')
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = Ollama({ stream = true })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()

    backend:send(agent, conversation, function() end)
    conversation:add("user", "again", { autosave = false })
    backend:send(agent, conversation, function() end)

    http.request = old_request
    local count = 0
    local found_first = false
    local found_second = false
    for _, message in ipairs(conversation.messages) do
      if message.role == "activity" and message.message:find("Reasoning", 1, true) then
        count = count + 1
        found_first = found_first or message.message:find("Thinking 1", 1, true) ~= nil
        found_second = found_second or message.message:find("Thinking 2", 1, true) ~= nil
      end
    end
    test.equal(count, 2)
    test.equal(found_first, true)
    test.equal(found_second, true)
  end)

  test.it("streams ollama openai-compatible sse chunks", function()
    local old_request = http.request
    http.request = function(_, _, options)
      options.on_header({ status = 200 })
      options.on_chunk('data: {"choices":[{"delta":{"content":"hel"},"finish_reason":null}]}\n\n')
      options.on_chunk('data: {"choices":[{"delta":{"content":"lo"},"finish_reason":null}]}\n\n')
      options.on_chunk('data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}\n\n')
      options.on_chunk('data: [DONE]\n\n')
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = Ollama({ stream = true })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response
    local usage

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then
        response = text
        usage = meta.usage
      end
    end)

    http.request = old_request
    test.equal(response, "hello")
    test.equal(usage.total_tokens, 7)
  end)

  test.it("records raw http requests and responses for raw response view", function()
    local old_post = http.post
    http.post = function(_, _, _, options)
      options.on_done(true, nil, {
        choices = {
          { message = { content = "done" } }
        }
      }, { status = 200 })
    end

    local agent = Ollama({ stream = false })
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    local backend = HttpBackend()

    backend:send(agent, conversation, function() end)

    http.post = old_post
    local raw = conversation:raw_responses_text()
    test.equal(raw:find('"kind":"http-request"', 1, true) ~= nil, true)
    test.equal(raw:find('"kind":"http-response"', 1, true) ~= nil, true)
    test.equal(raw:find('"content":"hello"', 1, true) ~= nil, true)
  end)

  test.it("locally compacts conversations through non-streaming summaries", function()
    local old_post = http.post
    local sent_body
    http.post = function(_, _, _, options)
      sent_body = json.decode(options.body)
      options.on_done(true, nil, {
        choices = {
          {
            message = {
              content = "User wants file listing. Continue from summarized state."
            }
          }
        }
      }, { status = 200 })
    end

    local agent = Ollama({ stream = false })
    local conversation = Conversation(agent, "project")
    conversation:add("user", "list files", { autosave = false })
    conversation:add("tool_call", "Tool: list", { autosave = false })
    conversation:add("tool_result", "Tool: list\nStatus: ok\nResult:\na.lua", { autosave = false })
    conversation:add("assistant", "listed files", { autosave = false })
    local backend = HttpBackend()
    local ok_result

    backend:local_compact(agent, conversation, function(ok)
      ok_result = ok
    end)

    http.post = old_post
    test.equal(ok_result, true)
    test.equal(sent_body.stream, false)
    test.equal(sent_body.messages[1].role, "system")
    test.equal(sent_body.messages[2].content:find("Compact this coding assistant conversation", 1, true) ~= nil, true)
    test.equal(#conversation.messages, 7)
    test.equal(conversation.messages[1].role, "system")
    test.equal(conversation.messages[2].role, "user")
    test.equal(conversation.messages[2].meta.environment_context, true)
    test.equal(conversation.messages[7].role, "assistant")
    test.equal(conversation.messages[7].message:find("### Conversation Compacted", 1, true) ~= nil, true)
    test.equal(conversation.local_compaction.summary, "User wants file listing. Continue from summarized state.")
    test.equal(conversation.local_compaction.message_count, 6)
    test.equal(conversation.local_compaction.trigger, "manual")
    test.not_nil(conversation.local_compaction.context_snapshot)
  end)

  test.it("does not rewrite conversations when local compaction fails", function()
    local old_post = http.post
    http.post = function(_, _, _, options)
      options.on_done(true, nil, {
        error = {
          message = "bad request"
        }
      }, { status = 400 })
    end

    local agent = Ollama()
    local conversation = Conversation(agent, "project")
    conversation:add("user", "keep me", { autosave = false })
    local backend = HttpBackend()
    local ok_result
    local err_result

    backend:local_compact(agent, conversation, function(ok, err)
      ok_result = ok
      err_result = err
    end)

    http.post = old_post
    test.equal(ok_result, false)
    test.equal(err_result:find("Conversation compaction failed", 1, true) ~= nil, true)
    test.equal(#conversation.messages, 3)
    test.equal(conversation.messages[2].meta.environment_context, true)
    test.equal(conversation.messages[3].role, "user")
    test.equal(conversation.messages[3].message, "keep me")
  end)

  test.it("executes approved chat-completions tool calls before final response", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_post = http.post
    local calls = 0
    local executed
    local second_body
    http.post = function(_, _, _, options)
      calls = calls + 1
      if calls == 1 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                content = "",
                tool_calls = {
                  {
                    id = "call_1",
                    type = "function",
                    ["function"] = {
                      name = "read",
                      arguments = '{"path":"README.md"}'
                    }
                  }
                }
              }
            }
          }
        }, { status = 200 })
      else
        second_body = json.decode(options.body)
        options.on_done(true, nil, {
          choices = {
            { message = { content = "done" } }
          },
          usage = {
            prompt_tokens = 3,
            completion_tokens = 2,
            total_tokens = 5
          }
        }, { status = 200 })
      end
    end

    local agent = Ollama({ stream = false })
    agent:register_tool("read", {
      callback = function(path)
        executed = path
        return "file contents"
      end,
      params = {
        { name = "path", type = "string" }
      }
    })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response
    local status_after_tool

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "tool_call_request" then
        backend:resolve_tool_call(agent, conversation, meta.request, "allow", function()
          status_after_tool = conversation.status
        end)
      elseif ok and meta and meta.done then
        response = text
      end
    end)

    http.post = old_post
    restore_background_threads()
    test.equal(executed, "README.md")
    test.equal(status_after_tool, "working")
    test.equal(response, "done")
    test.equal(second_body.stream, false)
    test.equal(second_body.messages[#second_body.messages].role, "tool")
    test.equal(second_body.messages[#second_body.messages].content:find("Use this result to answer", 1, true) ~= nil, true)
    test.equal(conversation.messages[#conversation.messages].role, "tool_result")
  end)

  test.it("records local tool activity in the rendered transcript", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_post = http.post
    local calls = 0
    http.post = function(_, _, _, options)
      calls = calls + 1
      if calls == 1 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                content = "",
                tool_calls = {
                  {
                    id = "call_1",
                    type = "function",
                    ["function"] = {
                      name = "exec_command",
                      arguments = '{"cmd":"make test","workdir":"project"}'
                    }
                  }
                }
              }
            }
          }
        }, { status = 200 })
      else
        options.on_done(true, nil, {
          choices = {
            { message = { content = "done" } }
          }
        }, { status = 200 })
      end
    end

    local agent = Ollama({ stream = false })
    agent:register_tool("exec_command", {
      callback = function()
        return true, "All tests passed"
      end,
      params = {
        { name = "cmd", type = "string" },
        { name = "workdir", type = "string" }
      }
    })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()

    backend:send(agent, conversation, function(ok, _, _, meta)
      if ok and meta and meta.event == "tool_call_request" then
        backend:resolve_tool_call(agent, conversation, meta.request, "allow", function() end)
      end
    end)

    http.post = old_post
    restore_background_threads()
    local markdown = conversation:to_markdown()
    test.equal(markdown:find("## Activity", 1, true), nil)
    test.equal(markdown:find("**Running command**: `make test`", 1, true) ~= nil, true)
    test.equal(markdown:find("in `project`", 1, true) ~= nil, true)
    test.equal(markdown:find("(completed)", 1, true), nil)
  end)

  test.it("shows write previews before tool approval", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_post = http.post
    local executed = false
    http.post = function(_, _, _, options)
      options.on_done(true, nil, {
        choices = {
          {
            message = {
              content = "",
              tool_calls = {
                {
                  id = "call_write",
                  type = "function",
                  ["function"] = {
                    name = "write",
                    arguments = '{"path":"preview.txt","content":"hello\\nworld\\n"}'
                  }
                }
              }
            }
          }
        }
      }, { status = 200 })
    end

    local agent = tools.register_agent_tools(Ollama({ stream = false }))
    agent.tools.write.callback = function()
      executed = true
      return true, "created: preview.txt"
    end
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local request
    local activity_markdown

    backend:send(agent, conversation, function(ok, _, _, meta)
      if ok and meta and meta.event == "activity_update" then
        activity_markdown = conversation:to_markdown()
      elseif ok and meta and meta.event == "tool_call_request" then
        request = meta.request
      end
    end)

    http.post = old_post
    restore_background_threads()
    test.equal(executed, false)
    test.equal(request and request.call and request.call.name, "write")
    test.equal(activity_markdown:find("**Adding**: `preview.txt`", 1, true) ~= nil, true)
    test.equal(activity_markdown:find("```diff", 1, true) ~= nil, true)
    test.equal(activity_markdown:find("+hello", 1, true) ~= nil, true)
  end)

  test.it("shows edit diffs before tool approval", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_post = http.post
    local executed = false
    http.post = function(_, _, _, options)
      options.on_done(true, nil, {
        choices = {
          {
            message = {
              content = "",
              tool_calls = {
                {
                  id = "call_edit",
                  type = "function",
                  ["function"] = {
                    name = "edit",
                    arguments = '{"path":"main.c","edits":[{"oldText":"old line","newText":"new line"}]}'
                  }
                }
              }
            }
          }
        }
      }, { status = 200 })
    end

    local agent = tools.register_agent_tools(Ollama({ stream = false }))
    agent.tools.edit.callback = function()
      executed = true
      return true, "Successfully replaced 1 block(s) in main.c."
    end
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local request
    local activity_markdown

    backend:send(agent, conversation, function(ok, _, _, meta)
      if ok and meta and meta.event == "activity_update" then
        activity_markdown = conversation:to_markdown()
      elseif ok and meta and meta.event == "tool_call_request" then
        request = meta.request
      end
    end)

    http.post = old_post
    restore_background_threads()
    test.equal(executed, false)
    test.equal(request and request.call and request.call.name, "edit")
    test.equal(activity_markdown:find("**Editing**: `main.c`", 1, true) ~= nil, true)
    test.equal(activity_markdown:find("```diff", 1, true) ~= nil, true)
    test.equal(activity_markdown:find("-old line", 1, true) ~= nil, true)
    test.equal(activity_markdown:find("+new line", 1, true) ~= nil, true)
  end)

  test.it("keeps failed tool activity visible in the rendered transcript", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_post = http.post
    local calls = 0
    http.post = function(_, _, _, options)
      calls = calls + 1
      if calls == 1 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                content = "",
                tool_calls = {
                  {
                    id = "call_failed",
                    type = "function",
                    ["function"] = {
                      name = "exec_command",
                      arguments = '{"cmd":"make test","workdir":"project"}'
                    }
                  }
                }
              }
            }
          }
        }, { status = 200 })
      else
        options.on_done(true, nil, {
          choices = {
            { message = { content = "done" } }
          }
        }, { status = 200 })
      end
    end

    local agent = Ollama({ stream = false })
    agent:register_tool("exec_command", {
      callback = function()
        return false, "command failed"
      end,
      params = {
        { name = "cmd", type = "string" },
        { name = "workdir", type = "string" }
      }
    })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()

    backend:send(agent, conversation, function(ok, _, _, meta)
      if ok and meta and meta.event == "tool_call_request" then
        backend:resolve_tool_call(agent, conversation, meta.request, "allow", function() end)
      end
    end)

    http.post = old_post
    restore_background_threads()
    local markdown = conversation:to_markdown()
    test.equal(markdown:find("**Running command**: `make test` in `project` (failed)", 1, true) ~= nil, true)
    test.equal(markdown:find("(completed)", 1, true), nil)
  end)

  test.it("shows apply_patch diffs in activity when verbose tool calling is disabled", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_post = http.post
    local calls = 0
    http.post = function(_, _, _, options)
      calls = calls + 1
      if calls == 1 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                content = "",
                tool_calls = {
                  {
                    id = "call_patch",
                    type = "function",
                    ["function"] = {
                      name = "apply_patch",
                      arguments = json.encode({
                        patch = "*** Begin Patch\n*** Add File: main.c\n+int main(void) { return 0; }\n*** End Patch"
                      })
                    }
                  }
                }
              }
            }
          }
        }, { status = 200 })
      else
        options.on_done(true, nil, {
          choices = {
            { message = { content = "done" } }
          }
        }, { status = 200 })
      end
    end

    local agent = Ollama({ stream = false })
    agent:register_tool("apply_patch", {
      callback = function()
        return true, "applied patch"
      end,
      params = {
        { name = "patch", type = "string" }
      }
    })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()

    backend:send(agent, conversation, function(ok, _, _, meta)
      if ok and meta and meta.event == "tool_call_request" then
        backend:resolve_tool_call(agent, conversation, meta.request, "allow", function() end)
      end
    end)

    http.post = old_post
    restore_background_threads()
    local markdown = conversation:to_markdown()
    test.equal(markdown:find("## Tool call", 1, true), nil)
    test.equal(markdown:find("```diff", 1, true) ~= nil, true)
    test.equal(markdown:find("*** Add File: main.c", 1, true) ~= nil, true)
  end)

  test.it("limits file read results in activity when verbose tool calling is disabled", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_post = http.post
    local calls = 0
    http.post = function(_, _, _, options)
      calls = calls + 1
      if calls == 1 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                content = "",
                tool_calls = {
                  {
                    id = "call_read",
                    type = "function",
                    ["function"] = {
                      name = "read",
                      arguments = '{"path":"project/main.c","offset":1,"limit":10}'
                    }
                  }
                }
              }
            }
          }
        }, { status = 200 })
      else
        options.on_done(true, nil, {
          choices = {
            { message = { content = "done" } }
          }
        }, { status = 200 })
      end
    end

    local agent = Ollama({ stream = false })
    agent:register_tool("read", {
      callback = function()
        return true, "1:first\n2:second\n3:third\n4:fourth\n5:fifth"
      end,
      params = {
        { name = "path", type = "string" },
        { name = "offset", type = "number" },
        { name = "limit", type = "number" }
      }
    })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()

    backend:send(agent, conversation, function(ok, _, _, meta)
      if ok and meta and meta.event == "tool_call_request" then
        backend:resolve_tool_call(agent, conversation, meta.request, "allow", function() end)
      end
    end)

    http.post = old_post
    restore_background_threads()
    local markdown = conversation:to_markdown()
    test.equal(markdown:find("**Reading**:", 1, true) ~= nil, true)
    test.equal(markdown:find("`project/main.c`", 1, true) ~= nil, true)
    test.equal(markdown:find("4:fourth", 1, true), nil)
    test.equal(markdown:find("truncated after 3 lines", 1, true), nil)
    test.equal(markdown:find("## Tool result", 1, true), nil)
  end)

  test.it("handles local plan update tool calls before final response", function()
    local old_post = http.post
    local calls = 0
    local second_body
    http.post = function(_, _, _, options)
      calls = calls + 1
      if calls == 1 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                content = "",
                tool_calls = {
                  {
                    id = "call_plan",
                    type = "function",
                    ["function"] = {
                      name = "update_plan",
                      arguments = json.encode({
                        explanation = "Working through the request.",
                        plan = {
                          { step = "Inspect code", status = "completed" },
                          { step = "Patch backend", status = "in_progress" },
                          { step = "Run tests", status = "pending" }
                        }
                      })
                    }
                  }
                }
              }
            }
          }
        }, { status = 200 })
      else
        second_body = json.decode(options.body)
        options.on_done(true, nil, {
          choices = {
            { message = { content = "done" } }
          }
        }, { status = 200 })
      end
    end

    local agent = tools.register_agent_tools(Ollama({ stream = false }))
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response
    local plan_activity_updates = 0

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "activity_update" then
        if conversation.messages[#conversation.messages]
          and conversation.messages[#conversation.messages].meta
          and conversation.messages[#conversation.messages].meta.plan_update
        then
          plan_activity_updates = plan_activity_updates + 1
        end
      end
      if ok and meta and meta.done then response = text end
    end)

    http.post = old_post
    test.equal(response, "done")
    test.equal(plan_activity_updates > 0, true)
    test.equal(conversation.assistant_plan.items[2].status, "in_progress")
    local plan_markdown = conversation.messages[#conversation.messages - 1].message
    test.equal(plan_markdown:find("Plan Updated", 1, true) ~= nil, true)
    test.equal(plan_markdown:find("- [x] Inspect code", 1, true) ~= nil, true)
    test.equal(plan_markdown:find("- [ ] **Patch backend** _(in progress)_", 1, true) ~= nil, true)
    test.equal(plan_markdown:find("- [ ] Run tests", 1, true) ~= nil, true)
    test.equal(second_body.messages[#second_body.messages].role, "tool")
    test.equal(second_body.messages[#second_body.messages].content:find("plan updated", 1, true) ~= nil, true)
  end)

  test.it("continues streamed local plan update tool calls before final response", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_request = http.request
    local calls = 0
    local second_body
    local function event(data)
      return "data: " .. json.encode(data) .. "\n\n"
    end
    http.request = function(_, _, options)
      calls = calls + 1
      options.on_header({ status = 200 })
      if calls == 1 then
        options.on_chunk(event({
          choices = {
            {
              delta = {
                tool_calls = {
                  {
                    index = 0,
                    id = "call_plan_stream",
                    type = "function",
                    ["function"] = {
                      name = "update_plan",
                      arguments = json.encode({
                        explanation = "Working through the request.",
                        plan = {
                          { step = "Inspect code", status = "completed" },
                          { step = "Patch backend", status = "in_progress" },
                          { step = "Run tests", status = "pending" }
                        }
                      })
                    }
                  }
                }
              },
              finish_reason = nil
            }
          }
        }))
        options.on_chunk(event({
          choices = {
            {
              delta = {},
              finish_reason = "tool_calls"
            }
          }
        }))
        options.on_done(true, nil, nil, { status = 200 })
      else
        second_body = json.decode(options.body)
        options.on_chunk(event({
          choices = {
            {
              delta = { content = "done" },
              finish_reason = nil
            }
          }
        }))
        options.on_chunk(event({
          choices = {
            {
              delta = {},
              finish_reason = "stop"
            }
          }
        }))
        options.on_done(true, nil, nil, { status = 200 })
      end
    end

    local agent = tools.register_agent_tools(Ollama({ stream = true }))
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response
    local plan_activity_updates = 0

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "activity_update" then
        if conversation.messages[#conversation.messages]
          and conversation.messages[#conversation.messages].meta
          and conversation.messages[#conversation.messages].meta.plan_update
        then
          plan_activity_updates = plan_activity_updates + 1
        end
      end
      if ok and meta and meta.done then response = text end
    end)

    http.request = old_request
    restore_background_threads()
    test.equal(calls, 2)
    test.equal(response, "done")
    test.equal(plan_activity_updates > 0, true)
    test.equal(conversation.assistant_plan.items[2].status, "in_progress")
    test.equal(second_body.messages[#second_body.messages].role, "tool")
    test.equal(second_body.messages[#second_body.messages].content:find("plan updated", 1, true) ~= nil, true)
  end)

  test.it("handles local request_user_input tool calls before final response", function()
    local old_post = http.post
    local calls = 0
    local second_body
    local requested
    http.post = function(_, _, _, options)
      calls = calls + 1
      if calls == 1 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                content = "",
                tool_calls = {
                  {
                    id = "call_question",
                    type = "function",
                    ["function"] = {
                      name = "request_user_input",
                      arguments = json.encode({
                        questions = {
                          {
                            id = "choice",
                            header = "Decision",
                            question = "Proceed?",
                            options = {
                              { label = "Yes", description = "Continue" },
                              { label = "No", description = "Stop" }
                            }
                          }
                        }
                      })
                    }
                  }
                }
              }
            }
          }
        }, { status = 200 })
      else
        second_body = json.decode(options.body)
        options.on_done(true, nil, {
          choices = {
            { message = { content = "answered" } }
          }
        }, { status = 200 })
      end
    end

    local agent = tools.register_agent_tools(Ollama({ stream = false }))
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "user_input_request" then
        requested = meta.request
        backend:resolve_user_input(agent, conversation, meta.request, true, { choice = "Yes" }, function() end)
      elseif ok and meta and meta.done then
        response = text
      end
    end)

    http.post = old_post
    test.equal(requested.questions[1].question, "Proceed?")
    test.equal(requested.questions[1].id, "choice")
    test.equal(response, "answered")
    test.equal(second_body.messages[#second_body.messages].role, "tool")
    test.equal(second_body.messages[#second_body.messages].content:find("Yes", 1, true) ~= nil, true)
    test.equal(second_body.messages[#second_body.messages].content:find("choice", 1, true) ~= nil, true)
  end)

  test.it("emits implement_plan requests in plan mode", function()
    local old_post = http.post
    http.post = function(_, _, _, options)
      options.on_done(true, nil, {
        choices = {
          {
            message = {
              role = "assistant",
              content = "## Plan\n\n1. Update the code.\n2. Run tests.",
              tool_calls = {
                {
                  id = "call_implement",
                  type = "function",
                  ["function"] = {
                    name = "implement_plan",
                    arguments = "{}"
                  }
                }
              }
            }
          }
        }
      }, { status = 200 })
    end

    local agent = tools.register_agent_tools(Ollama({ stream = false }))
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "plan"
    local backend = HttpBackend()
    local requested

    backend:send(agent, conversation, function(ok, _, _, meta)
      if ok and meta and meta.event == "implement_plan_request" then
        requested = meta.request
      end
    end)

    http.post = old_post
    test.not_nil(requested)
    test.equal(requested.title, "Implement Plan?")
    test.equal(requested.prompt:find("Implement the approved plan", 1, true) ~= nil, true)
    test.equal(conversation.status, "idle")
  end)

  test.it("auto-emits implement_plan requests for plan drafted markers", function()
    local old_post = http.post
    http.post = function(_, _, _, options)
      options.on_done(true, nil, {
        choices = {
          {
            message = {
              role = "assistant",
              content = "## Plan\n\n1. Update the code.\n2. Run tests.\n\nPlan Drafted!"
            }
          }
        }
      }, { status = 200 })
    end

    local agent = tools.register_agent_tools(Ollama({ stream = false }))
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "plan"
    local backend = HttpBackend()
    local response
    local requested

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then
        response = text
      elseif ok and meta and meta.event == "implement_plan_request" then
        requested = meta.request
      end
    end)

    http.post = old_post
    test.not_nil(requested)
    test.equal(requested.id, "plan_drafted")
    test.equal(response:find("Plan Drafted!", 1, true), nil)
    test.equal(response:find("Update the code", 1, true) ~= nil, true)
  end)

  test.it("streams chat-completions tool calls before final response", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_request = http.request
    local calls = 0
    local executed
    local first_body
    local second_body
    local function event(data)
      return "data: " .. json.encode(data) .. "\n\n"
    end
    http.request = function(_, _, options)
      calls = calls + 1
      if calls == 1 then
        first_body = json.decode(options.body)
        options.on_header({ status = 200 })
        options.on_chunk(event({
          choices = {
            {
              delta = {
                tool_calls = {
                  {
                    index = 0,
                    id = "call_1",
                    type = "function",
                    ["function"] = {
                      name = "read",
                      arguments = "{\"path\":\""
                    }
                  }
                }
              },
              finish_reason = nil
            }
          }
        }))
        options.on_chunk(event({
          choices = {
            {
              delta = {
                tool_calls = {
                  {
                    index = 0,
                    ["function"] = {
                      arguments = "README.md\"}"
                    }
                  }
                }
              },
              finish_reason = nil
            }
          }
        }))
        options.on_chunk(event({
          choices = {
            {
              delta = {},
              finish_reason = "tool_calls"
            }
          }
        }))
        options.on_done(true, nil, nil, { status = 200 })
      else
        second_body = json.decode(options.body)
        options.on_header({ status = 200 })
        options.on_chunk(event({
          choices = {
            {
              delta = { content = "done" },
              finish_reason = nil
            }
          }
        }))
        options.on_chunk(event({
          choices = {
            {
              delta = {},
              finish_reason = "stop"
            }
          },
          usage = {
            prompt_tokens = 3,
            completion_tokens = 2,
            total_tokens = 5
          }
        }))
        options.on_done(true, nil, nil, { status = 200 })
      end
    end

    local agent = Ollama({ stream = true })
    agent:register_tool("read", {
      callback = function(path)
        executed = path
        return "file contents"
      end,
      params = {
        { name = "path", type = "string" }
      }
    })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "tool_call_request" then
        backend:resolve_tool_call(agent, conversation, meta.request, "allow", function() end)
      elseif ok and meta and meta.done then
        response = text
      end
    end)

    http.request = old_request
    restore_background_threads()
    test.equal(executed, "README.md")
    test.equal(response, "done")
    test.equal(first_body.stream, true)
    test.equal(second_body.stream, true)
    test.equal(second_body.messages[#second_body.messages - 1].tool_calls[1]["function"].name, "read")
    test.equal(second_body.messages[#second_body.messages].role, "tool")
  end)

  test.it("keeps same-index streamed tool calls separate by id", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_request = http.request
    local calls = 0
    local executed = {}
    local second_body
    local function event(data)
      return "data: " .. json.encode(data) .. "\n\n"
    end
    http.request = function(_, _, options)
      calls = calls + 1
      if calls == 1 then
        options.on_header({ status = 200 })
        options.on_chunk(event({
          choices = {
            {
              delta = {
                tool_calls = {
                  {
                    index = 0,
                    id = "call_one",
                    type = "function",
                    ["function"] = {
                      name = "read",
                      arguments = json.encode({ path = "one.lua" })
                    }
                  },
                  {
                    index = 0,
                    id = "call_two",
                    type = "function",
                    ["function"] = {
                      name = "read",
                      arguments = json.encode({ path = "two.lua" })
                    }
                  }
                }
              },
              finish_reason = "tool_calls"
            }
          }
        }))
        options.on_done(true, nil, nil, { status = 200 })
      else
        second_body = json.decode(options.body)
        options.on_header({ status = 200 })
        options.on_chunk(event({
          choices = {
            {
              delta = { content = "done" },
              finish_reason = "stop"
            }
          }
        }))
        options.on_done(true, nil, nil, { status = 200 })
      end
    end

    local agent = Ollama({ stream = true })
    agent:register_tool("read", {
      callback = function(path)
        table.insert(executed, path)
        return "contents for " .. tostring(path)
      end,
      params = {
        { name = "path", type = "string" }
      }
    })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "tool_call_request" then
        backend:resolve_tool_call(agent, conversation, meta.request, "allow", function() end)
      elseif ok and meta and meta.done then
        response = text
      end
    end)

    http.request = old_request
    restore_background_threads()
    test.same(executed, { "one.lua", "two.lua" })
    test.equal(response, "done")
    local provider_calls = second_body.messages[#second_body.messages - 2].tool_calls
    test.equal(#provider_calls, 2)
    test.equal(provider_calls[1]["function"].name, "read")
    test.equal(provider_calls[2]["function"].name, "read")
    test.equal(provider_calls[1]["function"].name:find("readread", 1, true), nil)
    test.equal(second_body.messages[#second_body.messages - 1].role, "tool")
    test.equal(second_body.messages[#second_body.messages].role, "tool")
  end)

  test.it("sends fresh tool results un-compacted and compacts them after final response", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_post = http.post
    local old_compact = config.plugins.assistant.compact_tool_results
    config.plugins.assistant.compact_tool_results = true
    local calls = 0
    local second_body
    local large_result = string.rep("0123456789", 7000)
    http.post = function(_, _, _, options)
      calls = calls + 1
      if calls == 1 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                content = "",
                tool_calls = {
                  {
                    id = "call_large",
                    type = "function",
                    ["function"] = {
                      name = "read",
                      arguments = json.encode({ path = "large.txt" })
                    }
                  }
                }
              }
            }
          }
        }, { status = 200 })
      else
        second_body = json.decode(options.body)
        options.on_done(true, nil, {
          choices = {
            { message = { content = "done" } }
          }
        }, { status = 200 })
      end
    end

    local agent = Ollama({ stream = false })
    agent:register_tool("read", {
      callback = function()
        return large_result
      end,
      compact_result = function()
        return "compacted large read"
      end,
      read_only = true,
      params = {
        { name = "path", type = "string" }
      }
    })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
    end)

    http.post = old_post
    config.plugins.assistant.compact_tool_results = old_compact
    restore_background_threads()
    local fresh_tool_message = second_body.messages[#second_body.messages]
    local stored_tool_message
    for _, message in ipairs(conversation.messages) do
      if message.role == "tool_result" then
        stored_tool_message = message
        break
      end
    end

    test.equal(response, "done")
    test.equal(fresh_tool_message.role, "tool")
    test.equal(fresh_tool_message.content:find(large_result:sub(1, 100), 1, true) ~= nil, true)
    test.equal(fresh_tool_message.content:find("compacted large read", 1, true), nil)
    test.equal(stored_tool_message.meta.provider_messages[1].content:find("compacted large read", 1, true) ~= nil, true)
    test.equal(stored_tool_message.meta.deferred_tool_result, nil)
  end)

  test.it("recovers streamed string tool arguments with decoded control characters", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_request = http.request
    local calls = 0
    local received_patch
    local function event(data)
      return "data: " .. json.encode(data) .. "\n\n"
    end
    http.request = function(_, _, options)
      calls = calls + 1
      options.on_header({ status = 200 })
      if calls == 1 then
        options.on_chunk(event({
          choices = {
            {
              delta = {
                tool_calls = {
                  {
                    index = 0,
                    id = "call_patch",
                    type = "function",
                    ["function"] = {
                      name = "apply_patch",
                      arguments = "{\"patch\":\"*** Begin Patch\n*** Add File: Makefile\n+\tall:\\n*** End Patch\"}"
                    }
                  }
                }
              }
            }
          }
        }))
        options.on_chunk(event({
          choices = {
            {
              delta = {},
              finish_reason = "tool_calls"
            }
          }
        }))
      else
        options.on_chunk(event({
          choices = {
            {
              delta = { content = "done" },
              finish_reason = "stop"
            }
          }
        }))
      end
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = Ollama({ stream = true, model = "gpt-test" })
    agent:register_tool("apply_patch", {
      callback = function(patch)
        received_patch = patch
        return "patched"
      end,
      params = {
        { name = "patch", type = "string" }
      }
    })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "tool_call_request" then
        backend:resolve_tool_call(agent, conversation, meta.request, "allow", function() end)
      elseif ok and meta and meta.done then
        response = text
      end
    end)

    http.request = old_request
    restore_background_threads()
    test.equal(received_patch:find("*** Begin Patch", 1, true) ~= nil, true)
    test.equal(received_patch:find("\tall:", 1, true) ~= nil, true)
    test.equal(response, "done")
  end)

  test.it("does not capture trailing fields from unterminated streamed patch arguments", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_request = http.request
    local calls = 0
    local received_patch
    local function event(data)
      return "data: " .. json.encode(data) .. "\n\n"
    end
    http.request = function(_, _, options)
      calls = calls + 1
      options.on_header({ status = 200 })
      if calls == 1 then
        options.on_chunk(event({
          choices = {
            {
              delta = {
                tool_calls = {
                  {
                    index = 0,
                    id = "call_patch",
                    type = "function",
                    ["function"] = {
                      name = "apply_patch",
                      arguments = "{\"patch\":\"*** Begin Patch\\n*** Add File: Makefile\\n+all:\\n*** End Patch,\"path\":\"Makefile\""
                    }
                  }
                }
              }
            }
          }
        }))
        options.on_chunk(event({
          choices = {
            {
              delta = {},
              finish_reason = "tool_calls"
            }
          }
        }))
      else
        options.on_chunk(event({
          choices = {
            {
              delta = { content = "done" },
              finish_reason = "stop"
            }
          }
        }))
      end
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = Ollama({ stream = true, model = "gpt-test" })
    agent:register_tool("apply_patch", {
      callback = function(patch)
        received_patch = patch
        return "patched"
      end,
      params = {
        { name = "patch", type = "string" }
      }
    })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "tool_call_request" then
        backend:resolve_tool_call(agent, conversation, meta.request, "allow", function() end)
      elseif ok and meta and meta.done then
        response = text
      end
    end)

    http.request = old_request
    restore_background_threads()
    test.equal(received_patch, nil)
    test.equal(response, "done")
  end)

  test.it("finishes streamed plan turn when final proposed plan also includes tool calls", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_request = http.request
    local asked = false
    local executed = false
    local calls = 0
    local function event(data)
      return "data: " .. json.encode(data) .. "\n\n"
    end
    http.request = function(_, _, options)
      calls = calls + 1
      options.on_header({ status = 200 })
      options.on_chunk(event({
        choices = {
          {
            delta = {
              content = "<proposed_plan>\n# Plan\nCreate a tiny SDL2 Tetris project later.\n</proposed_plan>"
            },
            finish_reason = nil
          }
        }
      }))
      options.on_chunk(event({
        choices = {
          {
            delta = {
              tool_calls = {
                {
                  index = 0,
                  id = "call_1",
                  type = "function",
                  ["function"] = {
                    name = "list",
                    arguments = "{\"directory\":\"/tmp\",\"recursive\":true}"
                  }
                }
              }
            },
            finish_reason = nil
          }
        }
      }))
      options.on_chunk(event({
        choices = {
          {
            delta = {},
            finish_reason = "tool_calls"
          }
        },
        usage = {
          prompt_tokens = 3,
          completion_tokens = 2,
          total_tokens = 5
        }
      }))
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = tools.register_agent_tools(Ollama({ stream = true }))
    agent.tools.list.callback = function()
      executed = true
      return "unexpected"
    end
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "plan"
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "tool_call_request" then
        asked = true
      elseif ok and meta and meta.done then
        response = text
      end
    end)

    http.request = old_request
    restore_background_threads()
    test.equal(calls, 1)
    test.equal(asked, false)
    test.equal(executed, false)
    test.equal(response:find("<proposed_plan>", 1, true), nil)
    test.equal(response:find("# Plan", 1, true) ~= nil, true)
  end)

  test.it("stops streamed plan mode at a completed proposed plan split across chunks", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_request = http.request
    local asked = false
    local executed = false
    local function event(data)
      return "data: " .. json.encode(data) .. "\n\n"
    end
    http.request = function(_, _, options)
      options.on_header({ status = 200 })
      options.on_chunk(event({
        choices = {
          {
            delta = {
              content = "<proposed_"
            }
          }
        }
      }))
      options.on_chunk(event({
        choices = {
          {
            delta = {
              content = "plan>\n# Plan\nInspect only.\n</proposed_plan> extra text"
            }
          }
        }
      }))
      options.on_chunk(event({
        choices = {
          {
            delta = {
              tool_calls = {
                {
                  index = 0,
                  id = "call_1",
                  type = "function",
                  ["function"] = {
                    name = "list",
                    arguments = "{\"directory\":\"/tmp\",\"recursive\":true}"
                  }
                }
              }
            },
            finish_reason = "tool_calls"
          }
        }
      }))
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = tools.register_agent_tools(Ollama({ stream = true }))
    agent.tools.list.callback = function()
      executed = true
      return "unexpected"
    end
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "plan"
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "tool_call_request" then
        asked = true
      elseif ok and meta and meta.done then
        response = text
      end
    end)

    http.request = old_request
    restore_background_threads()
    test.equal(asked, false)
    test.equal(executed, false)
    test.equal(response:find("Inspect only.", 1, true) ~= nil, true)
    test.equal(response:find("extra text", 1, true), nil)
  end)

  test.it("finishes streamed plan mode with natural markdown plans", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_request = http.request
    local asked = false
    local function event(data)
      return "data: " .. json.encode(data) .. "\n\n"
    end
    http.request = function(_, _, options)
      options.on_header({ status = 200 })
      options.on_chunk(event({
        choices = {
          {
            delta = {
              content = "# Plan\n\nCreate `tetris.c`, add a Makefile, and verify with `make`."
                .. "\n\nShall I proceed with creating these files?"
                .. "\n\n**Ready to implement?** I'll create the files."
            }
          }
        }
      }))
      options.on_chunk(event({
        choices = {
          {
            delta = {},
            finish_reason = "stop"
          }
        },
        usage = {
          prompt_tokens = 3,
          completion_tokens = 12,
          total_tokens = 15
        }
      }))
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = tools.register_agent_tools(Ollama({ stream = true }))
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "plan"
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "tool_call_request" then
        asked = true
      elseif ok and meta and meta.done then
        response = text
      end
    end)

    http.request = old_request
    restore_background_threads()
    test.equal(asked, false)
    test.equal(response:find("# Plan", 1, true) ~= nil, true)
    test.equal(response:find("Makefile", 1, true) ~= nil, true)
    test.equal(response:find("Shall I proceed", 1, true), nil)
    test.equal(response:find("Ready to implement", 1, true), nil)
  end)

  test.it("auto-emits implement_plan requests for streamed plan drafted markers", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_request = http.request
    local function event(data)
      return "data: " .. json.encode(data) .. "\n\n"
    end
    http.request = function(_, _, options)
      options.on_header({ status = 200 })
      options.on_chunk(event({
        choices = {
          {
            delta = {
              content = "# Plan\n\nCreate `tetris.c`.\n\nPlan "
            }
          }
        }
      }))
      options.on_chunk(event({
        choices = {
          {
            delta = {
              content = "Drafted!"
            },
            finish_reason = "stop"
          }
        }
      }))
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = tools.register_agent_tools(Ollama({ stream = true }))
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "plan"
    local backend = HttpBackend()
    local response
    local requested

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then
        response = text
      elseif ok and meta and meta.event == "implement_plan_request" then
        requested = meta.request
      end
    end)

    http.request = old_request
    restore_background_threads()
    test.not_nil(requested)
    test.equal(requested.id, "plan_drafted")
    test.equal(response:find("Plan Drafted!", 1, true), nil)
    test.equal(response:find("Create `tetris.c`", 1, true) ~= nil, true)
  end)

  test.it("resets streamed response text between tool rounds", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_request = http.request
    local calls = 0
    local function event(data)
      return "data: " .. json.encode(data) .. "\n\n"
    end
    http.request = function(_, _, options)
      calls = calls + 1
      options.on_header({ status = 200 })
      if calls == 1 then
        options.on_chunk(event({
          choices = {
            {
              delta = { content = "I'll fetch it." },
              finish_reason = nil
            }
          }
        }))
        options.on_chunk(event({
          choices = {
            {
              delta = {
                tool_calls = {
                  {
                    index = 0,
                    id = "call_1",
                    type = "function",
                    ["function"] = {
                      name = "read",
                      arguments = "{\"path\":\"README.md\"}"
                    }
                  }
                }
              },
              finish_reason = nil
            }
          }
        }))
        options.on_chunk(event({
          choices = {
            {
              delta = {},
              finish_reason = "tool_calls"
            }
          }
        }))
      else
        options.on_chunk(event({
          choices = {
            {
              delta = { content = "final answer" },
              finish_reason = nil
            }
          }
        }))
        options.on_chunk(event({
          choices = {
            {
              delta = {},
              finish_reason = "stop"
            }
          }
        }))
      end
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = Ollama({ stream = true })
    agent:register_tool("read", {
      callback = function()
        return "file contents"
      end,
      params = {
        { name = "path", type = "string" }
      }
    })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local partials = {}
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.partial then
        table.insert(partials, text)
      elseif ok and meta and meta.event == "tool_call_request" then
        backend:resolve_tool_call(agent, conversation, meta.request, "allow", function() end)
      elseif ok and meta and meta.done then
        response = text
      end
    end)

    http.request = old_request
    restore_background_threads()
    test.equal(partials[1], "I'll fetch it.")
    test.equal(partials[2], "final answer")
    test.equal(response, "final answer")
  end)

  test.it("does not stream short unfinished preambles before tool calls", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_request = http.request
    local calls = 0
    local function event(data)
      return "data: " .. json.encode(data) .. "\n\n"
    end
    http.request = function(_, _, options)
      calls = calls + 1
      options.on_header({ status = 200 })
      if calls == 1 then
        options.on_chunk(event({
          choices = {
            {
              delta = { content = "Let" },
              finish_reason = nil
            }
          }
        }))
        options.on_chunk(event({
          choices = {
            {
              delta = {
                tool_calls = {
                  {
                    index = 0,
                    id = "call_1",
                    type = "function",
                    ["function"] = {
                      name = "read",
                      arguments = "{\"path\":\"README.md\"}"
                    }
                  }
                }
              },
              finish_reason = nil
            }
          }
        }))
        options.on_chunk(event({
          choices = {
            {
              delta = {},
              finish_reason = "tool_calls"
            }
          }
        }))
      else
        options.on_chunk(event({
          choices = {
            {
              delta = { content = "done" },
              finish_reason = nil
            }
          }
        }))
        options.on_chunk(event({
          choices = {
            {
              delta = {},
              finish_reason = "stop"
            }
          }
        }))
      end
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = Ollama({ stream = true })
    agent:register_tool("read", {
      callback = function()
        return "file contents"
      end,
      params = {
        { name = "path", type = "string" }
      }
    })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local partials = {}
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.partial then
        table.insert(partials, text)
      elseif ok and meta and meta.event == "tool_call_request" then
        backend:resolve_tool_call(agent, conversation, meta.request, "allow", function() end)
      elseif ok and meta and meta.done then
        response = text
      end
    end)

    http.request = old_request
    restore_background_threads()
    test.equal(partials[1], "done")
    test.equal(partials[2], nil)
    test.equal(response, "done")
  end)

  test.it("normalizes empty streamed tool arguments before follow-up requests", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_request = http.request
    local calls = 0
    local second_body
    local function event(data)
      return "data: " .. json.encode(data) .. "\n\n"
    end
    http.request = function(_, _, options)
      calls = calls + 1
      if calls == 1 then
        options.on_header({ status = 200 })
        options.on_chunk(event({
          choices = {
            {
              delta = {
                tool_calls = {
                  {
                    index = 0,
                    id = "call_empty",
                    type = "function",
                    ["function"] = {
                      name = "lookup",
                      arguments = ""
                    }
                  }
                }
              },
              finish_reason = nil
            }
          }
        }))
        options.on_chunk(event({
          choices = {
            {
              delta = {},
              finish_reason = "tool_calls"
            }
          }
        }))
        options.on_done(true, nil, nil, { status = 200 })
      else
        second_body = json.decode(options.body)
        options.on_header({ status = 200 })
        options.on_chunk(event({
          choices = {
            {
              delta = { content = "need arguments" },
              finish_reason = "stop"
            }
          }
        }))
        options.on_done(true, nil, nil, { status = 200 })
      end
    end

    local agent = Ollama({ stream = true })
    agent:register_tool("lookup", {
      callback = function(path)
        if not path then return false, "missing path" end
        return true, "created"
      end,
      params = {
        { name = "path", type = "string" },
        { name = "contents", type = "string" }
      }
    })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "tool_call_request" then
        backend:resolve_tool_call(agent, conversation, meta.request, "allow", function() end)
      elseif ok and meta and meta.done then
        response = text
      end
    end)

    http.request = old_request
    restore_background_threads()
    test.equal(response, "need arguments")
    test.equal(second_body.messages[#second_body.messages - 1].tool_calls[1]["function"].name, "lookup")
    test.equal(second_body.messages[#second_body.messages - 1].tool_calls[1]["function"].arguments, "{}")
    test.equal(second_body.messages[#second_body.messages].content:find("missing path", 1, true) ~= nil, true)
  end)

  test.it("returns denial results for rejected tool calls", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_post = http.post
    local calls = 0
    local executed = false
    http.post = function(_, _, _, options)
      calls = calls + 1
      if calls == 1 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                tool_calls = {
                  {
                    id = "call_1",
                    type = "function",
                    ["function"] = {
                      name = "read",
                      arguments = '{"path":"README.md"}'
                    }
                  }
                }
              }
            }
          }
        }, { status = 200 })
      else
        options.on_done(true, nil, {
          choices = {
            { message = { content = "denied noted" } }
          }
        }, { status = 200 })
      end
    end

    local agent = Ollama({ stream = false })
    agent:register_tool("read", {
      callback = function()
        executed = true
        return "file contents"
      end,
      params = {
        { name = "path", type = "string" }
      }
    })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "tool_call_request" then
        backend:resolve_tool_call(agent, conversation, meta.request, "deny", function() end)
      elseif ok and meta and meta.done then
        response = text
      end
    end)

    http.post = old_post
    restore_background_threads()
    test.equal(executed, false)
    test.equal(response, "denied noted")
    test.equal(conversation.messages[#conversation.messages].message:find("user denied", 1, true) ~= nil, true)
  end)

  local function denied_tool_result_for(tool_name, args, registration)
    local restore_background_threads = run_background_threads_immediately()
    local old_post = http.post
    local calls = 0
    local second_body
    local encoded_args = json.encode(args or {})
    http.post = function(_, _, _, options)
      calls = calls + 1
      if calls == 1 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                tool_calls = {
                  {
                    id = "call_1",
                    type = "function",
                    ["function"] = {
                      name = tool_name,
                      arguments = encoded_args
                    }
                  }
                }
              }
            }
          }
        }, { status = 200 })
      else
        second_body = json.decode(options.body)
        options.on_done(true, nil, {
          choices = {
            { message = { content = "denied noted" } }
          }
        }, { status = 200 })
      end
    end

    local agent_options = { stream = false }
    if registration == true and tool_name == "apply_patch" then
      agent_options.model = "gpt-test"
    end
    local agent = Ollama(agent_options)
    if registration == true then
      tools.register_agent_tools(agent)
    else
      agent:register_tool(tool_name, registration or {
        callback = function()
          return "executed"
        end,
        params = {
          { name = "path", type = "string" },
          { name = "content", type = "string" }
        }
      })
    end
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()

    backend:send(agent, conversation, function(ok, _, _, meta)
      if ok and meta and meta.event == "tool_call_request" then
        backend:resolve_tool_call(agent, conversation, meta.request, "deny", function() end)
      end
    end)

    http.post = old_post
    restore_background_threads()
    local tool_result = second_body.messages[#second_body.messages]
    return tool_result.content
  end

  test.it("nudges models away from shell file writes after rejected mutation calls", function()
    local write = denied_tool_result_for("write", {
      path = "README.md",
      content = "new"
    }, true)
    local edit = denied_tool_result_for("edit", {
      path = "README.md",
      edits = {
        { oldText = "old", newText = "new" }
      }
    }, true)
    local patch = denied_tool_result_for("apply_patch", {
      patch = "*** Begin Patch\n*** Add File: README.md\n+new\n*** End Patch"
    }, true)

    for _, content in ipairs({ write, edit, patch }) do
      test.equal(content:find("user denied tool execution", 1, true) ~= nil, true)
      test.equal(content:find("Do not retry this file change through exec_command", 1, true) ~= nil, true)
      test.equal(content:find("heredoc", 1, true) ~= nil, true)
    end
  end)

  test.it("uses custom denied_result hooks and falls back when empty", function()
    local custom = denied_tool_result_for("custom", {}, {
      callback = function()
        return "executed"
      end,
      denied_result = function()
        return "custom denial"
      end
    })
    local fallback = denied_tool_result_for("fallback", {}, {
      callback = function()
        return "executed"
      end,
      denied_result = function()
        return nil
      end
    })

    test.equal(custom:find("custom denial", 1, true) ~= nil, true)
    test.equal(fallback:find("user denied tool execution", 1, true) ~= nil, true)
  end)

  test.it("resumes rejected tool calls on a background thread", function()
    local old_add_background_thread = core.add_background_thread
    local old_add_thread = core.add_thread
    local old_post = http.post
    local background_resumes = 0
    core.add_background_thread = function(fn)
      background_resumes = background_resumes + 1
      fn()
      return "test-background-thread"
    end
    core.add_thread = function()
      error("tool continuation should not use core.add_thread")
    end
    local calls = 0
    http.post = function(_, _, _, options)
      calls = calls + 1
      if calls == 1 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                tool_calls = {
                  {
                    id = "call_1",
                    type = "function",
                    ["function"] = {
                      name = "read",
                      arguments = '{"path":"README.md"}'
                    }
                  }
                }
              }
            }
          }
        }, { status = 200 })
      else
        options.on_done(true, nil, {
          choices = {
            { message = { content = "denied noted" } }
          }
        }, { status = 200 })
      end
    end

    local agent = Ollama({ stream = false })
    agent:register_tool("read", {
      callback = function()
        return "file contents"
      end,
      params = {
        { name = "path", type = "string" }
      }
    })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "tool_call_request" then
        backend:resolve_tool_call(agent, conversation, meta.request, "deny", function() end)
      elseif ok and meta and meta.done then
        response = text
      end
    end)

    core.add_background_thread = old_add_background_thread
    core.add_thread = old_add_thread
    http.post = old_post
    test.equal(background_resumes, 1)
    test.equal(response, "denied noted")
  end)

  test.it("executes approved text-encoded local model tool calls", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_post = http.post
    local calls = 0
    local executed
    local second_body
    http.post = function(_, _, _, options)
      calls = calls + 1
      if calls == 1 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                role = "assistant",
                content = "<function=search>\n<parameter=directory>\nproject\n</parameter>\n<parameter=search_type>\nplain\n</parameter>\n<parameter=text>\n.\n</parameter>\n</function>\n</tool_call>"
              }
            }
          }
        }, { status = 200 })
      else
        second_body = json.decode(options.body)
        options.on_done(true, nil, {
          choices = {
            { message = { content = "listed files" } }
          }
        }, { status = 200 })
      end
    end

    local agent = Ollama({ stream = false })
    agent:register_tool("search", {
      callback = function(directory, text, search_type)
        executed = { directory = directory, text = text, search_type = search_type }
        return "file-a.lua\nfile-b.lua"
      end,
      params = {
        { name = "directory", type = "string" },
        { name = "text", type = "string" },
        { name = "search_type", type = "string" }
      }
    })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "tool_call_request" then
        backend:resolve_tool_call(agent, conversation, meta.request, "allow", function() end)
      elseif ok and meta and meta.done then
        response = text
      end
    end)

    http.post = old_post
    restore_background_threads()
    test.equal(executed.directory, "project")
    test.equal(executed.text, ".")
    test.equal(executed.search_type, "plain")
    test.equal(response, "listed files")
    test.equal(second_body.messages[#second_body.messages - 1].tool_calls[1]["function"].name, "search")
    test.equal(second_body.messages[#second_body.messages].role, "tool")
  end)

  test.it("rejects mutating tool calls that are unavailable in plan mode", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_post = http.post
    local calls = 0
    local executed = false
    local asked = false
    local second_body
    http.post = function(_, _, _, options)
      calls = calls + 1
      if calls == 1 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                role = "assistant",
                content = "<function=apply_patch>\n<parameter=patch>\n*** Begin Patch\n*** Add File: main.c\n+int main(void) { return 0; }\n*** End Patch\n</parameter>\n</function>"
              }
            }
          }
        }, { status = 200 })
      elseif calls == 2 then
        second_body = json.decode(options.body)
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                role = "assistant",
                content = "## Plan\n\n1. Keep planning.\n2. Switch modes before editing.\n\nPlan Drafted!"
              }
            }
          }
        }, { status = 200 })
      end
    end

    local agent = tools.register_agent_tools(Ollama({ stream = false, model = "gpt-test" }))
    agent.tools.apply_patch.callback = function()
      executed = true
      return true, "created"
    end
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "plan"
    local backend = HttpBackend()
    local response
    local requested

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "tool_call_request" then
        asked = true
      elseif ok and meta and meta.event == "implement_plan_request" then
        requested = meta.request
      elseif ok and meta and meta.done then
        response = text
      end
    end)

    http.post = old_post
    restore_background_threads()
    test.equal(asked, false)
    test.equal(executed, false)
    test.equal(calls, 2)
    test.not_nil(requested)
    test.equal(response:find("not available in the current collaboration mode", 1, true), nil)
    test.equal(response:find("Switch modes before editing", 1, true) ~= nil, true)
    test.equal(second_body.messages[#second_body.messages].role, "tool")
    test.equal(second_body.messages[#second_body.messages].content:find("call `implement_plan`", 1, true) ~= nil, true)
    local found_activity = false
    for _, message in ipairs(conversation.messages) do
      if message.role == "activity" and message.message:find("apply_patch", 1, true) then
        found_activity = true
      end
    end
    test.equal(found_activity, true)
  end)

  test.it("asks before unsafe exec_command calls in plan mode", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_post = http.post
    local executed = false
    local calls = 0
    http.post = function(_, _, _, options)
      calls = calls + 1
      if calls == 1 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                role = "assistant",
                content = "",
                tool_calls = {
                  {
                    id = "call_cmd",
                    type = "function",
                    ["function"] = {
                      name = "exec_command",
                      arguments = '{"cmd":"mkdir -p src","workdir":"project"}'
                    }
                  }
                }
              }
            }
          }
        }, { status = 200 })
      else
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                role = "assistant",
                content = "done"
              }
            }
          }
        }, { status = 200 })
      end
    end

    local agent = tools.register_agent_tools(Ollama({ stream = false }))
    agent.tools.exec_command.callback = function()
      executed = true
      return true, "created"
    end
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "plan"
    local backend = HttpBackend()
    local response
    local request

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
      if ok and meta and meta.event == "tool_call_request" then request = meta.request end
    end)

    test.equal(calls, 1)
    test.equal(executed, false)
    test.equal(response, nil)
    test.equal(request and request.call and request.call.name, "exec_command")

    backend:resolve_tool_call(agent, conversation, request, "allow", function() end)

    http.post = old_post
    restore_background_threads()
    test.equal(calls, 2)
    test.equal(executed, true)
    test.equal(response, "done")
  end)

  test.it("can approve exec_command prefixes for the session", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_post = http.post
    local executed = 0
    local calls = 0
    http.post = function(_, _, _, options)
      calls = calls + 1
      if calls == 1 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                role = "assistant",
                content = "",
                tool_calls = {
                  {
                    id = "call_cmd_1",
                    type = "function",
                    ["function"] = {
                      name = "exec_command",
                      arguments = '{"cmd":"make test","workdir":"project"}'
                    }
                  }
                }
              }
            }
          }
        }, { status = 200 })
      elseif calls == 2 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                role = "assistant",
                content = "",
                tool_calls = {
                  {
                    id = "call_cmd_2",
                    type = "function",
                    ["function"] = {
                      name = "exec_command",
                      arguments = '{"cmd":"make test VERBOSE=1","workdir":"project"}'
                    }
                  }
                }
              }
            }
          }
        }, { status = 200 })
      else
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                role = "assistant",
                content = "done"
              }
            }
          }
        }, { status = 200 })
      end
    end

    local agent = tools.register_agent_tools(Ollama({ stream = false }))
    agent.tools.exec_command.callback = function()
      executed = executed + 1
      return true, "ok"
    end
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "implementation"
    local backend = HttpBackend()
    local requests = {}
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
      if ok and meta and meta.event == "tool_call_request" then table.insert(requests, meta.request) end
    end)

    test.equal(calls, 1)
    test.equal(executed, 0)
    test.equal(#requests, 1)
    test.equal(requests[1].options[2].decision, "allow_session")

    backend:resolve_tool_call(agent, conversation, requests[1], "allow_session", function() end)

    http.post = old_post
    restore_background_threads()
    test.equal(calls, 3)
    test.equal(executed, 2)
    test.equal(#requests, 1)
    test.equal(conversation:command_prefix_approved("make test FOO=1"), true)
    test.equal(response, "done")
  end)

  test.it("can approve repeated tool calls for the session", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_post = http.post
    local executed = 0
    local calls = 0
    http.post = function(_, _, _, options)
      calls = calls + 1
      if calls == 1 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                role = "assistant",
                content = "",
                tool_calls = {
                  {
                    id = "call_write_1",
                    type = "function",
                    ["function"] = {
                      name = "write",
                      arguments = '{"path":"a.txt","content":"one\\n"}'
                    }
                  }
                }
              }
            }
          }
        }, { status = 200 })
      elseif calls == 2 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                role = "assistant",
                content = "",
                tool_calls = {
                  {
                    id = "call_write_2",
                    type = "function",
                    ["function"] = {
                      name = "write",
                      arguments = '{"path":"b.txt","content":"two\\n"}'
                    }
                  }
                }
              }
            }
          }
        }, { status = 200 })
      else
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                role = "assistant",
                content = "done"
              }
            }
          }
        }, { status = 200 })
      end
    end

    local agent = tools.register_agent_tools(Ollama({ stream = false }))
    agent.tools.write.callback = function()
      executed = executed + 1
      return true, "patched"
    end
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "implementation"
    local backend = HttpBackend()
    local requests = {}
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
      if ok and meta and meta.event == "tool_call_request" then table.insert(requests, meta.request) end
    end)

    test.equal(calls, 1)
    test.equal(executed, 0)
    test.equal(#requests, 1)
    test.equal(requests[1].options[1].decision, "allow")
    test.equal(requests[1].options[2].decision, "allow_session")
    test.equal(requests[1].options[3].decision, "deny")

    backend:resolve_tool_call(agent, conversation, requests[1], "allow_session", function() end)

    http.post = old_post
    restore_background_threads()
    test.equal(calls, 3)
    test.equal(executed, 2)
    test.equal(#requests, 1)
    test.equal(conversation:tool_approved("write"), true)
    test.equal(response, "done")
  end)

  test.it("allows simple read-only exec_command chains in plan mode", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_post = http.post
    local executed = false
    local calls = 0
    http.post = function(_, _, _, options)
      calls = calls + 1
      if calls == 1 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                role = "assistant",
                content = "",
                tool_calls = {
                  {
                    id = "call_cmd",
                    type = "function",
                    ["function"] = {
                      name = "exec_command",
                      arguments = '{"cmd":"pwd && ls -la","workdir":"project"}'
                    }
                  }
                }
              }
            }
          }
        }, { status = 200 })
      else
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                role = "assistant",
                content = "done"
              }
            }
          }
        }, { status = 200 })
      end
    end

    local agent = tools.register_agent_tools(Ollama({ stream = false }))
    agent.tools.exec_command.callback = function()
      executed = true
      return true, "/tmp\n."
    end
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "plan"
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
    end)

    http.post = old_post
    restore_background_threads()
    test.equal(calls, 2)
    test.equal(executed, true)
    test.equal(response, "done")
  end)

  test.it("allows read-only grep commands with quoted regex alternation in plan mode", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_post = http.post
    local executed = false
    local calls = 0
    http.post = function(_, _, _, options)
      calls = calls + 1
      if calls == 1 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                role = "assistant",
                content = "",
                tool_calls = {
                  {
                    id = "call_cmd",
                    type = "function",
                    ["function"] = {
                      name = "exec_command",
                      arguments = '{"cmd":"grep -n \\"F11\\\\|fullscreen\\" project/tetris.c","workdir":"project"}'
                    }
                  }
                }
              }
            }
          }
        }, { status = 200 })
      else
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                role = "assistant",
                content = "done"
              }
            }
          }
        }, { status = 200 })
      end
    end

    local agent = tools.register_agent_tools(Ollama({ stream = false }))
    agent.tools.exec_command.callback = function()
      executed = true
      return true, ""
    end
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "plan"
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
    end)

    http.post = old_post
    restore_background_threads()
    test.equal(calls, 2)
    test.equal(executed, true)
    test.equal(response, "done")
  end)

  test.it("rejects malformed local plan update tool calls", function()
    local old_post = http.post
    local calls = 0
    local second_body
    http.post = function(_, _, _, options)
      calls = calls + 1
      if calls == 1 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                content = "",
                tool_calls = {
                  {
                    id = "call_plan",
                    type = "function",
                    ["function"] = {
                      name = "update_plan",
                      arguments = json.encode({
                        explanation = "Planning.",
                        plan = {
                          { step = 1, status = "completed", description = "Inspect project" },
                          { step = 2, status = "planned", description = "Draft implementation" }
                        }
                      })
                    }
                  }
                }
              }
            }
          }
        }, { status = 200 })
      else
        second_body = json.decode(options.body)
        options.on_done(true, nil, {
          choices = {
            { message = { content = "done" } }
          }
        }, { status = 200 })
      end
    end

    local agent = tools.register_agent_tools(Ollama({ stream = false }))
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()

    backend:send(agent, conversation, function() end)

    http.post = old_post
    test.equal(conversation.assistant_plan, nil)
    test.equal(second_body.messages[#second_body.messages].role, "tool")
    test.equal(second_body.messages[#second_body.messages].content:find("plan update error", 1, true) ~= nil, true)
  end)

  test.it("finishes plan turn when final proposed plan also includes tool calls", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_post = http.post
    local executed = false
    local asked = false
    http.post = function(_, _, _, options)
      options.on_done(true, nil, {
        choices = {
          {
            message = {
              role = "assistant",
              content = "<proposed_plan>\n# Plan\nCreate a tiny SDL2 Tetris project later.\n</proposed_plan>",
              tool_calls = {
                {
                  id = "call-1",
                  type = "function",
                  ["function"] = {
                    name = "list",
                    arguments = "{\"directory\":\"/tmp\",\"recursive\":true}"
                  }
                }
              }
            }
          }
        }
      }, { status = 200 })
    end

    local agent = tools.register_agent_tools(Ollama({ stream = false }))
    agent.tools.list.callback = function()
      executed = true
      return "unexpected"
    end
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "plan"
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "tool_call_request" then
        asked = true
      elseif ok and meta and meta.done then
        response = text
      end
    end)

    http.post = old_post
    restore_background_threads()
    test.equal(asked, false)
    test.equal(executed, false)
    test.equal(response:find("<proposed_plan>", 1, true), nil)
    test.equal(response:find("# Plan", 1, true) ~= nil, true)
  end)

  test.it("does not continue plan-mode tools after a completed proposed plan exists", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_post = http.post
    local executed = false
    local asked = false
    local calls = 0
    http.post = function(_, _, _, options)
      calls = calls + 1
      options.on_done(true, nil, {
        choices = {
          {
            message = {
              role = "assistant",
              content = "",
              tool_calls = {
                {
                  id = "call-1",
                  type = "function",
                  ["function"] = {
                    name = "exec_command",
                    arguments = "{\"cmd\":\"pkg-config --cflags --libs sdl2\",\"workdir\":\"/tmp\"}"
                  }
                }
              }
            }
          }
        }
      }, { status = 200 })
    end

    local agent = tools.register_agent_tools(Ollama({ stream = false }))
    agent.tools.exec_command.callback = function()
      executed = true
      return "unexpected"
    end
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "plan"
    conversation:add("assistant", "<proposed_plan>\n# Plan\nBuild later.\n</proposed_plan>", { autosave = false })
    local backend = HttpBackend()
    local done = false

    backend:send(agent, conversation, function(ok, _, _, meta)
      if ok and meta and meta.event == "tool_call_request" then
        asked = true
      elseif ok and meta and meta.done then
        done = true
      end
    end)

    http.post = old_post
    restore_background_threads()
    test.equal(calls, 1)
    test.equal(asked, false)
    test.equal(executed, false)
    test.equal(done, true)
  end)

  test.it("auto-runs read-only tools when any read path is allowed", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_post = http.post
    local root = assistant_test_temp_path("http-readonly")
    common.rm(root, true)
    common.mkdirp(root)
    local fp = assert(io.open(root .. PATHSEP .. "outside.txt", "wb"))
    fp:write("outside\n")
    fp:close()
    config.plugins.assistant.allow_any_read_path = true
    local calls = 0
    http.post = function(_, _, _, options)
      calls = calls + 1
      if calls == 1 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                role = "assistant",
                content = "<function=list>\n<parameter=directory>\n" .. root .. "\n</parameter>\n<parameter=recursive>\nfalse\n</parameter>\n<parameter=max_results>\n20\n</parameter>\n<parameter=pattern>\n\n</parameter>\n</function>"
              }
            }
          }
        }, { status = 200 })
      else
        options.on_done(true, nil, {
          choices = {
            { message = { content = "listed" } }
          }
        }, { status = 200 })
      end
    end

    local agent = tools.register_agent_tools(Ollama({ stream = false }))
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local asked = false
    local response
    local activity_updates = 0

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "tool_call_request" then
        asked = true
      elseif ok and meta and meta.event == "activity_update" then
        activity_updates = activity_updates + 1
      elseif ok and meta and meta.done then
        response = text
      end
    end)

    http.post = old_post
    restore_background_threads()
    common.rm(root, true)
    test.equal(asked, false)
    test.equal(activity_updates >= 2, true)
    test.equal(response, "listed")
    test.equal(conversation.messages[#conversation.messages].role, "tool_result")
    test.equal(conversation.messages[#conversation.messages].message:find("outside.txt", 1, true) ~= nil, true)
  end)

  test.it("suppresses repeated identical tool calls after one execution", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_post = http.post
    local calls = 0
    local executed = 0
    local second_body
    local third_body
    http.post = function(_, _, _, options)
      calls = calls + 1
      if calls == 2 then second_body = json.decode(options.body) end
      if calls == 1 or calls == 2 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                role = "assistant",
                content = "<function=list>\n<parameter=directory>\nproject\n</parameter>\n<parameter=recursive>\ntrue\n</parameter>\n<parameter=max_results>\n100\n</parameter>\n<parameter=pattern>\n\n</parameter>\n</function>\n</tool_call>"
              }
            }
          }
        }, { status = 200 })
      else
        third_body = json.decode(options.body)
        options.on_done(true, nil, {
          choices = {
            { message = { content = "listed once" } }
          }
        }, { status = 200 })
      end
    end

    local agent = Ollama({ stream = false })
    agent:register_tool("list", {
      callback = function()
        executed = executed + 1
        return "a.lua\nb.lua"
      end,
      read_only = true,
      params = {
        { name = "directory", type = "string" },
        { name = "recursive", type = "boolean" },
        { name = "max_results", type = "number" },
        { name = "pattern", type = "string" }
      }
    })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local asked = false
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "tool_call_request" then
        asked = true
      elseif ok and meta and meta.done then
        response = text
      end
    end)

    http.post = old_post
    restore_background_threads()
    test.equal(asked, false)
    test.equal(executed, 1)
    test.equal(response, "listed once")
    test.equal(second_body.messages[#second_body.messages].role, "tool")
    test.equal(second_body.messages[#second_body.messages].content:find("Use this result to answer", 1, true) ~= nil, true)
    test.equal(third_body.messages[#third_body.messages].role, "tool")
    test.equal(
      third_body.messages[#third_body.messages].content:find("a.lua", 1, true) ~= nil,
      true
    )
    test.equal(
      third_body.messages[#third_body.messages].content:find("Repeated tool call skipped", 1, true),
      nil
    )
  end)

  test.it("returns cached results for repeated identical tool calls after an intervening different tool call", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_post = http.post
    local calls = 0
    local reads = 0
    local lists = 0
    http.post = function(_, _, _, options)
      calls = calls + 1
      if calls == 1 or calls == 3 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                role = "assistant",
                content = "<function=read>\n<parameter=path>\nproject/main.c\n</parameter>\n</function>"
              }
            }
          }
        }, { status = 200 })
      elseif calls == 2 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                role = "assistant",
                content = "<function=list>\n<parameter=directory>\nproject\n</parameter>\n<parameter=recursive>\nfalse\n</parameter>\n</function>"
              }
            }
          }
        }, { status = 200 })
      else
        options.on_done(true, nil, {
          choices = {
            { message = { content = "done" } }
          }
        }, { status = 200 })
      end
    end

    local agent = Ollama({ stream = false })
    agent:register_tool("read", {
      callback = function()
        reads = reads + 1
        return "contents " .. reads
      end,
      read_only = true,
      params = {
        { name = "path", type = "string" }
      }
    })
    agent:register_tool("list", {
      callback = function()
        lists = lists + 1
        return "main.c"
      end,
      read_only = true,
      params = {
        { name = "directory", type = "string" },
        { name = "recursive", type = "boolean", required = false }
      }
    })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then
        response = text
      end
    end)

    http.post = old_post
    restore_background_threads()
    test.equal(reads, 1)
    test.equal(lists, 1)
    test.equal(response, "done")
  end)

  test.it("treats literal regex and plain searches as repeated inspections", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_post = http.post
    local calls = 0
    local searches = 0
    http.post = function(_, _, _, options)
      calls = calls + 1
      if calls == 1 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                role = "assistant",
                content = "<function=search>\n<parameter=directory>\nproject\n</parameter>\n<parameter=text>\nold-name\n</parameter>\n<parameter=search_type>\nregex\n</parameter>\n</function>"
              }
            }
          }
        }, { status = 200 })
      elseif calls == 2 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                role = "assistant",
                content = "<function=search>\n<parameter=directory>\nproject\n</parameter>\n<parameter=text>\nold-name\n</parameter>\n<parameter=search_type>\nplain\n</parameter>\n</function>"
              }
            }
          }
        }, { status = 200 })
      else
        options.on_done(true, nil, {
          choices = {
            { message = { content = "done" } }
          }
        }, { status = 200 })
      end
    end

    local agent = Ollama({ stream = false })
    agent:register_tool("search", {
      callback = function()
        searches = searches + 1
        return "project/README.md:1:old-name"
      end,
      read_only = true,
      params = {
        { name = "directory", type = "string" },
        { name = "text", type = "string" },
        { name = "search_type", type = "string" }
      }
    })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then
        response = text
      end
    end)

    http.post = old_post
    restore_background_threads()
    test.equal(searches, 1)
    test.equal(response, "done")
  end)

  test.it("still asks before read-only tools outside project roots when any read path is disabled", function()
    local old_post = http.post
    local project_root = assistant_test_temp_path("http-project")
    local outside_root = assistant_test_temp_path("outside-project")
    http.post = function(_, _, _, options)
      options.on_done(true, nil, {
        choices = {
          {
            message = {
              role = "assistant",
              content = "<function=list>\n<parameter=directory>\n" .. outside_root .. "\n</parameter>\n</function>"
            }
          }
        }
      }, { status = 200 })
    end

    local agent = tools.register_agent_tools(Ollama({ stream = false }))
    local conversation = Conversation(agent, project_root)
    local backend = HttpBackend()
    local asked = false

    backend:send(agent, conversation, function(ok, _, _, meta)
      if ok and meta and meta.event == "tool_call_request" then
        asked = true
      end
    end)

    http.post = old_post
    test.equal(asked, true)
  end)

  test.it("rejects text-encoded legacy execute calls", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_post = http.post
    local calls = 0
    local executed
    http.post = function(_, _, _, options)
      calls = calls + 1
      if calls == 1 then
        options.on_done(true, nil, {
          choices = {
            {
              message = {
                role = "assistant",
                content = "<function=execute>\n<parameter=command>\nls -la project\n</parameter>\n</function>\n</tool_call>"
              }
            }
          }
        }, { status = 200 })
      else
        options.on_done(true, nil, {
          choices = {
            { message = { content = "command handled" } }
          }
        }, { status = 200 })
      end
    end

    local agent = Ollama({ stream = false })
    agent:register_tool("exec_command", {
      callback = function(cmd)
        executed = cmd
        return "listing"
      end,
      params = {
        { name = "cmd", type = "string" },
        { name = "workdir", type = "string" },
        { name = "yield_time_ms", type = "number" }
      }
    })
    local conversation = Conversation(agent, assistant_test_temp_path("openai-responses"))
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "tool_call_request" then
        backend:resolve_tool_call(agent, conversation, meta.request, "allow", function() end)
      elseif ok and meta and meta.done then
        response = text
      end
    end)

    http.post = old_post
    restore_background_threads()
    test.equal(executed, nil)
    test.equal(response, "command handled")
    local found_exec_command = false
    for _, message in ipairs(conversation.messages) do
      if message.meta and message.meta.call and message.meta.call.name == "exec_command" then
        found_exec_command = true
      end
    end
    test.equal(found_exec_command, false)
  end)

  test.it("continues openai responses function-call flows", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_post = http.post
    local old_request = http.request
    local calls = 0
    local first_body
    local second_body
    local post_called = false
    local function event(data)
      return "data: " .. json.encode(data) .. "\n\n"
    end
    http.post = function()
      post_called = true
    end
    http.request = function(_, _, options)
      calls = calls + 1
      if calls == 1 then
        first_body = json.decode(options.body)
        options.on_header({ status = 200 })
        options.on_chunk(event({
          type = "response.output_item.added",
          output_index = 0,
          item = {
            type = "function_call",
            id = "fc_1",
            call_id = "call_1",
            name = "lookup",
            arguments = ""
          }
        }))
        options.on_chunk(event({
          type = "response.function_call_arguments.delta",
          output_index = 0,
          item_id = "fc_1",
          delta = "{\"query\":\""
        }))
        options.on_chunk(event({
          type = "response.function_call_arguments.delta",
          output_index = 0,
          item_id = "fc_1",
          delta = "x\"}"
        }))
        options.on_chunk(event({
          type = "response.function_call_arguments.done",
          output_index = 0,
          item_id = "fc_1",
          arguments = "{\"query\":\"x\"}"
        }))
        options.on_done(true, nil, nil, { status = 200 })
      else
        second_body = json.decode(options.body)
        options.on_header({ status = 200 })
        options.on_chunk(event({
          type = "response.output_text.delta",
          delta = "answer"
        }))
        options.on_chunk(event({
          type = "response.completed",
          response = {
            usage = {
              input_tokens = 4,
              output_tokens = 2,
              total_tokens = 6
            }
          }
        }))
        options.on_done(true, nil, nil, { status = 200 })
      end
    end

    local agent = OpenAI({ stream = true })
    agent:register_tool("lookup", {
      callback = function(query)
        return "found " .. query
      end,
      params = {
        { name = "query", type = "string" }
      }
    })
    local conversation = Conversation(agent, "project")
    local backend = HttpBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "tool_call_request" then
        backend:resolve_tool_call(agent, conversation, meta.request, "allow", function() end)
      elseif ok and meta and meta.done then
        response = text
      end
    end)

    http.post = old_post
    http.request = old_request
    restore_background_threads()
    test.equal(post_called, false)
    test.equal(first_body.stream, true)
    test.equal(second_body.stream, true)
    test.equal(response, "answer")
    test.equal(second_body.input[#second_body.input - 1].type, "function_call")
    test.equal(second_body.input[#second_body.input - 1].call_id, "call_1")
    test.equal(second_body.input[#second_body.input].type, "function_call_output")
    test.equal(second_body.input[#second_body.input].call_id, "call_1")
  end)
end)
