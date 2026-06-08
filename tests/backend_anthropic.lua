local test = require "core.test"
dofile("tests/helper.inc")
local http = require "core.http"
local json = require "core.json"
local Conversation = require "plugins.assistant.conversation"
local Anthropic = require "plugins.assistant.agent.anthropic"
local DeepSeekAnthropic = require "plugins.assistant.agent.deepseek_anthropic"
local AnthropicBackend = require "plugins.assistant.backend.anthropic"
local tools = require "plugins.assistant.tools"

test.describe("assistant Anthropic backend", function()
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

  local function event(name, data)
    return "event: " .. name .. "\n"
      .. "data: " .. json.encode(data) .. "\n\n"
  end

  test.it("preserves repeated streamed text delta sequences", function()
    local old_request = http.request
    http.request = function(_, _, options)
      options.on_header({ status = 200 })
      options.on_chunk(event("message_start", {
        message = {
          usage = {
            input_tokens = 10,
            output_tokens = 0
          }
        }
      }))
      options.on_chunk(event("content_block_start", {
        index = 0,
        content_block = {
          type = "text",
          text = ""
        }
      }))
      local chunks = {
        "220", " passed", ",", " ", "3", " failed", ".", " Let", " me", " see", " which", " tests", " failed", "\n\n",
        "220", " passed", ",", " ", "3", " failed", ".", " Let", " me", " see", " which", " tests", " failed", "\n\n",
        "The failure is in folding."
      }
      for _, text in ipairs(chunks) do
        options.on_chunk(event("content_block_delta", {
          index = 0,
          delta = {
            type = "text_delta",
            text = text
          }
        }))
      end
      options.on_chunk(event("content_block_stop", { index = 0 }))
      options.on_chunk(event("message_delta", {
        delta = { stop_reason = "end_turn" },
        usage = {
          input_tokens = 10,
          output_tokens = 30
        }
      }))
      options.on_chunk(event("message_stop", {}))
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = Anthropic({ stream = true })
    local conversation = Conversation(agent, "project")
    local backend = AnthropicBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
    end)

    http.request = old_request
    test.equal(
      response,
      "220 passed, 3 failed. Let me see which tests failed\n\n"
        .. "220 passed, 3 failed. Let me see which tests failed\n\n"
        .. "The failure is in folding."
    )
  end)

  test.it("preserves repeated markdown table row prefixes in text deltas", function()
    local old_request = http.request
    http.request = function(_, _, options)
      options.on_header({ status = 200 })
      options.on_chunk(event("message_start", {
        message = {
          usage = {
            input_tokens = 10,
            output_tokens = 0
          }
        }
      }))
      options.on_chunk(event("content_block_start", {
        index = 0,
        content_block = {
          type = "text",
          text = ""
        }
      }))
      local chunks = {
        "Here you go.\n\n## Critical\n\n",
        "| # | Issue | File |\n",
        "|---|-------|------|\n",
        "| **1** | Process tools | `tool/process.lua` |\n\n",
        "## Important\n\n",
        "| # | Issue | File |\n",
        "|---|-------|------|\n",
        "| **5** | Global capabilities | `agent_config.lua` |\n\n",
        "## Polish\n\n",
        "| # | Issue | File |\n",
        "|---|-------|------|\n",
        "| **9** | Default timeout | `init.lua:75` |\n",
        "| **10** | Process sessions | `tool/process.lua` |\n",
        "| **11** | JSON prefix | `jsonutil.lua` |\n",
        "| **12** | Prompt view size | `promptview.lua` |\n",
        "| **15** | Plan follow-up | `backend/http.lua` |"
      }
      for _, text in ipairs(chunks) do
        options.on_chunk(event("content_block_delta", {
          index = 0,
          delta = {
            type = "text_delta",
            text = text
          }
        }))
      end
      options.on_chunk(event("content_block_stop", { index = 0 }))
      options.on_chunk(event("message_delta", {
        delta = { stop_reason = "end_turn" },
        usage = {
          input_tokens = 10,
          output_tokens = 30
        }
      }))
      options.on_chunk(event("message_stop", {}))
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = Anthropic({ stream = true })
    local conversation = Conversation(agent, "project")
    local backend = AnthropicBackend()
    local response

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then response = text end
    end)

    http.request = old_request
    test.not_nil(response)
    test.equal(response:find("| # | Issue | File |\n|---|-------|------|\n| **5** |", 1, true) ~= nil, true)
    test.equal(response:find("| # | Issue | File |\n|---|-------|------|\n| **9** |", 1, true) ~= nil, true)
    test.equal(response:find("\n| **10** |", 1, true) ~= nil, true)
    test.equal(response:find("\n| **11** |", 1, true) ~= nil, true)
    test.equal(response:find("\n| **12** |", 1, true) ~= nil, true)
    test.equal(response:find("\n| **15** |", 1, true) ~= nil, true)
  end)

  test.it("reports malformed streamed tool arguments without executing", function()
    local old_request = http.request
    local requests = 0
    http.request = function(_, _, options)
      requests = requests + 1
      if requests == 1 then
        options.on_header({ status = 200 })
        options.on_chunk(event("message_start", {
          message = {
            usage = {
              input_tokens = 10,
              output_tokens = 0
            }
          }
        }))
        options.on_chunk(event("content_block_start", {
          index = 0,
          content_block = {
            type = "tool_use",
            id = "call_bad",
            name = "write"
          }
        }))
        options.on_chunk(event("content_block_delta", {
          index = 0,
          delta = {
            type = "input_json_delta",
            partial_json = "{\"path\":\"project/out.txt\",\"content\":\"unterminated"
          }
        }))
        options.on_chunk(event("content_block_stop", { index = 0 }))
        options.on_chunk(event("message_delta", {
          delta = { stop_reason = "max_tokens" },
          usage = {
            input_tokens = 10,
            output_tokens = 8192
          }
        }))
        options.on_chunk(event("message_stop", {}))
        options.on_done(true, nil, nil, { status = 200 })
      else
        options.on_header({ status = 200 })
        options.on_chunk(event("message_start", {
          message = {
            usage = {
              input_tokens = 20,
              output_tokens = 0
            }
          }
        }))
        options.on_chunk(event("content_block_start", {
          index = 0,
          content_block = {
            type = "text",
            text = ""
          }
        }))
        options.on_chunk(event("content_block_delta", {
          index = 0,
          delta = {
            type = "text_delta",
            text = "recovered"
          }
        }))
        options.on_chunk(event("content_block_stop", { index = 0 }))
        options.on_chunk(event("message_delta", {
          delta = { stop_reason = "end_turn" },
          usage = {
            input_tokens = 20,
            output_tokens = 1
          }
        }))
        options.on_chunk(event("message_stop", {}))
        options.on_done(true, nil, nil, { status = 200 })
      end
    end

    local agent = tools.register_agent_tools(Anthropic({ stream = true }))
    local executed = false
    agent.tools.write.callback = function()
      executed = true
      return true, "unexpected"
    end
    local conversation = Conversation(agent, "project")
    local backend = AnthropicBackend()
    local requested = false
    local final_text

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "tool_call_request" then
        requested = true
      elseif ok and meta and meta.done then
        final_text = text
      end
    end)

    http.request = old_request
    test.equal(requested, false)
    test.equal(executed, false)
    test.equal(requests, 2)
    test.equal(final_text, "recovered")

    local found_error = false
    for _, message in ipairs(conversation.messages or {}) do
      if message.role == "tool_result"
        and tostring(message.message or ""):find("malformed tool call arguments", 1, true)
      then
        found_error = true
      end
    end
    test.equal(found_error, true)
  end)

  test.it("routes deepseek DSML text tool calls instead of displaying them", function()
    local old_post = http.post
    http.post = function(_, _, _, options)
      options.on_done(true, nil, {
        role = "assistant",
        content = {
          {
            type = "text",
            text = "<｜｜DSML｜｜tool_calls>\n"
              .. "<｜｜DSML｜｜invoke name=\"write\">\n"
              .. "<parameter=path>\nproject/out.txt\n</parameter>\n"
              .. "<parameter=content>\nhello\n</parameter>\n"
              .. "</｜｜DSML｜｜invoke>\n"
              .. "</｜｜DSML｜｜tool_calls>"
          }
        }
      }, { status = 200 })
    end

    local agent = tools.register_agent_tools(Anthropic({ stream = false }))
    local conversation = Conversation(agent, "project")
    local backend = AnthropicBackend()
    local requested
    local done_text

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.event == "tool_call_request" then
        requested = meta.request
      elseif ok and meta and meta.done then
        done_text = text
      end
    end)

    http.post = old_post
    test.not_nil(requested)
    test.equal(requested.call.name, "write")
    test.equal(requested.call.arguments.path, "project/out.txt")
    test.equal(done_text, nil)
  end)

  test.it("coalesces adjacent tool uses before tool results", function()
    local agent = tools.register_agent_tools(DeepSeekAnthropic({ stream = false }))
    local conversation = Conversation(agent, "project")
    conversation:add("tool_call", "Tool: read", {
      autosave = false,
      meta = {
        provider_message = {
          role = "assistant",
          content = {
            {
              type = "tool_use",
              id = "call_read",
              name = "read",
              input = { path = "project/a.txt" }
            }
          }
        }
      }
    })
    conversation:add("tool_call", "Tool: exec_command", {
      autosave = false,
      meta = {
        provider_message = {
          role = "assistant",
          content = {
            {
              type = "tool_use",
              id = "call_exec",
              name = "exec_command",
              input = { cmd = "true" }
            }
          }
        }
      }
    })
    conversation:add("tool_result", "Tool: read\nStatus: ok", {
      autosave = false,
      meta = {
        provider_messages = {
          {
            role = "user",
            content = {
              {
                type = "tool_result",
                tool_use_id = "call_read",
                content = "file text"
              }
            }
          }
        }
      }
    })
    conversation:add("tool_result", "Tool: exec_command\nStatus: ok", {
      autosave = false,
      meta = {
        provider_messages = {
          {
            role = "user",
            content = {
              {
                type = "tool_result",
                tool_use_id = "call_exec",
                content = "exit_code: 0"
              }
            }
          }
        }
      }
    })

    local payload = agent:build_payload(conversation)
    local assistant_message
    local result_message
    for index, message in ipairs(payload.messages) do
      if message.role == "assistant" then
        assistant_message = message
        result_message = payload.messages[index + 1]
        break
      end
    end

    test.not_nil(assistant_message)
    test.not_nil(result_message)
    test.equal(result_message.role, "user")
    test.equal(assistant_message.content[1].type, "tool_use")
    test.equal(assistant_message.content[1].id, "call_read")
    test.equal(assistant_message.content[2].type, "tool_use")
    test.equal(assistant_message.content[2].id, "call_exec")
    test.equal(result_message.content[1].type, "tool_result")
    test.equal(result_message.content[1].tool_use_id, "call_read")
    test.equal(result_message.content[2].type, "tool_result")
    test.equal(result_message.content[2].tool_use_id, "call_exec")
  end)

  test.it("keeps immediate Anthropic tool result messages pure", function()
    local agent = tools.register_agent_tools(DeepSeekAnthropic({ stream = false }))
    local conversation = Conversation(agent, "project")
    conversation:add("tool_call", "Tool: read", {
      autosave = false,
      meta = {
        provider_message = {
          role = "assistant",
          content = {
            {
              type = "tool_use",
              id = "call_read",
              name = "read",
              input = { path = "project/a.txt" }
            }
          }
        }
      }
    })
    conversation:add("tool_result", "Tool: read\nStatus: ok", {
      autosave = false,
      meta = {
        provider_messages = {
          {
            role = "user",
            content = {
              { type = "text", text = "Tool result follows." },
              {
                type = "tool_result",
                tool_use_id = "call_read",
                content = "file text"
              }
            }
          }
        }
      }
    })

    local payload = agent:build_payload(conversation)
    local result_message
    for index, message in ipairs(payload.messages) do
      if message.role == "assistant" then
        result_message = payload.messages[index + 1]
        break
      end
    end

    test.not_nil(result_message)
    test.equal(result_message.role, "user")
    test.equal(#result_message.content, 1)
    test.equal(result_message.content[1].type, "tool_result")
    test.equal(result_message.content[1].tool_use_id, "call_read")
  end)

  test.it("does not merge tool results into normal user messages", function()
    local agent = tools.register_agent_tools(DeepSeekAnthropic({ stream = false }))
    local conversation = Conversation(agent, "project")
    conversation:add("user", "normal user text", { autosave = false })
    conversation:add("tool_call", "Tool: read", {
      autosave = false,
      meta = {
        provider_message = {
          role = "assistant",
          content = {
            {
              type = "tool_use",
              id = "call_read",
              name = "read",
              input = { path = "project/a.txt" }
            }
          }
        }
      }
    })
    conversation:add("tool_result", "Tool: read\nStatus: ok", {
      autosave = false,
      meta = {
        provider_messages = {
          {
            role = "user",
            content = {
              {
                type = "tool_result",
                tool_use_id = "call_read",
                content = "file text"
              }
            }
          }
        }
      }
    })

    local payload = agent:build_payload(conversation)
    local assistant_message
    local result_message
    for index, message in ipairs(payload.messages) do
      if message.role == "assistant" then
        assistant_message = message
        result_message = payload.messages[index + 1]
        break
      end
    end

    test.not_nil(assistant_message)
    test.not_nil(result_message)
    test.equal(result_message.role, "user")
    test.equal(#result_message.content, 1)
    test.equal(result_message.content[1].type, "tool_result")
    test.equal(result_message.content[1].tool_use_id, "call_read")
  end)

  test.it("replays streamed thinking blocks before tool results", function()
    local restore_background_threads = run_background_threads_immediately()
    local old_request = http.request
    local requests = 0
    local second_body
    http.request = function(_, _, options)
      requests = requests + 1
      if requests == 1 then
        options.on_header({ status = 200 })
        options.on_chunk(event("message_start", {
          message = {
            usage = {
              input_tokens = 10,
              output_tokens = 0
            }
          }
        }))
        options.on_chunk(event("content_block_start", {
          index = 0,
          content_block = {
            type = "thinking"
          }
        }))
        options.on_chunk(event("content_block_delta", {
          index = 0,
          delta = {
            type = "thinking_delta",
            thinking = "Need to inspect files."
          }
        }))
        options.on_chunk(event("content_block_delta", {
          index = 0,
          delta = {
            type = "signature_delta",
            signature = "sig-1"
          }
        }))
        options.on_chunk(event("content_block_stop", { index = 0 }))
        options.on_chunk(event("content_block_start", {
          index = 1,
          content_block = {
            type = "tool_use",
            id = "call_list",
            name = "list"
          }
        }))
        options.on_chunk(event("content_block_delta", {
          index = 1,
          delta = {
            type = "input_json_delta",
            partial_json = "{\"directory\":\"project\",\"recursive\":false,\"max_results\":5}"
          }
        }))
        options.on_chunk(event("content_block_stop", { index = 1 }))
        options.on_chunk(event("message_delta", {
          delta = { stop_reason = "tool_use" },
          usage = {
            input_tokens = 10,
            output_tokens = 20
          }
        }))
        options.on_chunk(event("message_stop", {}))
        options.on_done(true, nil, nil, { status = 200 })
      else
        second_body = json.decode(options.body)
        options.on_header({ status = 200 })
        options.on_chunk(event("message_start", {
          message = {
            usage = {
              input_tokens = 20,
              output_tokens = 0
            }
          }
        }))
        options.on_chunk(event("content_block_start", {
          index = 0,
          content_block = {
            type = "text",
            text = ""
          }
        }))
        options.on_chunk(event("content_block_delta", {
          index = 0,
          delta = {
            type = "text_delta",
            text = "done"
          }
        }))
        options.on_chunk(event("content_block_stop", { index = 0 }))
        options.on_chunk(event("message_delta", {
          delta = { stop_reason = "end_turn" },
          usage = {
            input_tokens = 20,
            output_tokens = 1
          }
        }))
        options.on_chunk(event("message_stop", {}))
        options.on_done(true, nil, nil, { status = 200 })
      end
    end

    local agent = tools.register_agent_tools(DeepSeekAnthropic({ stream = true }))
    agent.tools.list.callback = function()
      return "files"
    end
    local conversation = Conversation(agent, "project")
    local backend = AnthropicBackend()
    local done_text

    backend:send(agent, conversation, function(ok, _, text, meta)
      if ok and meta and meta.done then done_text = text end
    end)

    http.request = old_request
    restore_background_threads()
    test.equal(requests, 2)
    test.equal(done_text, "done")
    local assistant_message
    for _, message in ipairs(second_body.messages or {}) do
      if message.role == "assistant"
        and type(message.content) == "table"
        and message.content[1]
        and message.content[1].type == "thinking"
      then
        assistant_message = message
      end
    end
    test.not_nil(assistant_message)
    test.equal(assistant_message.content[1].thinking, "Need to inspect files.")
    test.equal(assistant_message.content[1].signature, "sig-1")
    test.equal(assistant_message.content[2].type, "tool_use")
  end)

  test.it("does not use thinking-only responses as generated titles", function()
    local old_post = http.post
    http.post = function(_, _, _, options)
      options.on_done(true, nil, {
        role = "assistant",
        content = {
          {
            type = "thinking",
            thinking = "Generate a concise title."
          }
        },
        stop_reason = "max_tokens"
      }, { status = 200 })
    end

    local agent = Anthropic()
    local conversation = Conversation(agent, "project")
    local backend = AnthropicBackend()
    local ok_value
    local err_value
    local title_value

    backend:generate_conversation_title(agent, conversation, "Create a game.", function(ok, err, title)
      ok_value = ok
      err_value = err
      title_value = title
    end)

    http.post = old_post
    test.equal(ok_value, false)
    test.equal(err_value, "conversation title response was empty")
    test.equal(title_value, nil)
  end)

  test.it("shows a reasoning activity for non-streaming responses", function()
    local old_post = http.post
    http.post = function(_, _, _, options)
      options.on_done(true, nil, {
        role = "assistant",
        content = {
          { type = "thinking", thinking = "inspect then answer" },
          { type = "text", text = "final answer" }
        }
      }, { status = 200 })
    end

    local agent = Anthropic({ stream = false })
    local conversation = Conversation(agent, "project")
    local backend = AnthropicBackend()
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

  test.it("surfaces mid-stream error events instead of finishing empty", function()
    local old_request = http.request
    http.request = function(_, _, options)
      options.on_header({ status = 200 })
      options.on_chunk(event("message_start", {
        message = { usage = { input_tokens = 10, output_tokens = 0 } }
      }))
      options.on_chunk(event("content_block_start", {
        index = 0,
        content_block = { type = "text", text = "" }
      }))
      options.on_chunk(event("content_block_delta", {
        index = 0,
        delta = { type = "text_delta", text = "partial" }
      }))
      options.on_chunk(event("error", {
        type = "error",
        error = { type = "overloaded_error", message = "Overloaded" }
      }))
      -- Anthropic can stop the stream after an error event without a
      -- message_stop while the HTTP status stays 200.
      options.on_done(true, nil, nil, { status = 200 })
    end

    local agent = Anthropic({ stream = true })
    local conversation = Conversation(agent, "project")
    local backend = AnthropicBackend()
    local ok_value
    local err_value
    local done_value = false

    backend:send(agent, conversation, function(ok, err, _, meta)
      if ok and meta and meta.done then
        done_value = true
      elseif not ok then
        ok_value = ok
        err_value = err
      end
    end)

    http.request = old_request
    test.equal(done_value, false)
    test.equal(ok_value, false)
    test.not_nil(err_value)
    test.not_nil(tostring(err_value):find("Overloaded", 1, true))
  end)

  test.it("does not continue plan-mode tools after a completed proposed plan exists", function()
    local old_post = http.post
    local calls = 0
    http.post = function(_, _, _, options)
      calls = calls + 1
      options.on_done(true, nil, {
        role = "assistant",
        content = {
          {
            type = "tool_use",
            id = "call-1",
            name = "exec_command",
            input = {
              cmd = "pkg-config --cflags --libs sdl2",
              workdir = "/tmp"
            }
          }
        }
      }, { status = 200 })
    end

    local agent = tools.register_agent_tools(Anthropic({ stream = false }))
    local executed = false
    agent.tools.exec_command.callback = function()
      executed = true
      return "unexpected"
    end
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "plan"
    conversation:add("assistant", "<proposed_plan>\n# Plan\nBuild later.\n</proposed_plan>", {
      autosave = false
    })
    local backend = AnthropicBackend()
    local asked = false
    local done = false

    backend:send(agent, conversation, function(ok, _, _, meta)
      if ok and meta and meta.event == "tool_call_request" then
        asked = true
      elseif ok and meta and meta.done then
        done = true
      end
    end)

    http.post = old_post
    test.equal(calls, 1)
    test.equal(asked, false)
    test.equal(executed, false)
    test.equal(done, true)
  end)
end)
