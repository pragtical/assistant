local test = require "core.test"
dofile("tests/helper.inc")
local common = require "core.common"
local config = require "core.config"
local json = require "core.json"
local Conversation = require "plugins.assistant.conversation"
local Agent = require "plugins.assistant.agent"
local agent_config = require "plugins.assistant.agent_config"
local Ollama = require "plugins.assistant.agent.ollama"
local LlamaCpp = require "plugins.assistant.agent.llamacpp"
local Lms = require "plugins.assistant.agent.lms"
local OpenAI = require "plugins.assistant.agent.openai"
local Anthropic = require "plugins.assistant.agent.anthropic"
local DeepSeek = require "plugins.assistant.agent.deepseek"
local DeepSeekAnthropic = require "plugins.assistant.agent.deepseek_anthropic"
local Acp = require "plugins.assistant.agent.acp"
local Codex = require "plugins.assistant.agent.codex"
local Tool = require "plugins.assistant.tool"
local tools = require "plugins.assistant.tools"
local permission = require "plugins.assistant.permission"

local snapshot_root = assistant_test_temp_path("agent-snapshot")

local function mkdirp(path)
  local info = system.get_file_info(path)
  if info and info.type == "dir" then return end
  common.mkdirp(path)
end

local function write(path, text)
  local parent = path:match("^(.*)" .. PATHSEP .. "[^" .. PATHSEP .. "]+$")
  if parent then mkdirp(parent) end
  local fp = assert(io.open(path, "wb"))
  fp:write(text)
  fp:close()
end

local function read(path)
  local fp = assert(io.open(path, "rb"))
  local text = fp:read("*a")
  fp:close()
  return text
end

local function without_environment_messages(messages)
  local result = {}
  for _, message in ipairs(messages or {}) do
    local encoded = json.encode(message)
    if not (type(encoded) == "string" and encoded:find("Runtime environment:", 1, true)) then
      table.insert(result, message)
    end
  end
  return result
end

test.describe("assistant agent", function()
  test.it("default tool compaction shortens long results", function()
    local compacted = Tool.compact_result({}, {}, string.rep("x", 60000))

    test.equal(compacted:find("omitted", 1, true) ~= nil, true)
    test.equal(#compacted < 60000, true)
  end)

  test.it("default tool compaction omits large provider call arguments", function()
    local call = {
      id = "call_1",
      type = "function",
      ["function"] = {
        name = "sample",
        arguments = json.encode({
          patch = string.rep("x", 3000),
          path = "main.c"
        })
      }
    }

    local compacted = Tool.compact_provider_call({}, call)

    test.equal(compacted["function"].arguments:find("[omitted 3000 bytes from prior tool argument `patch`]", 1, true) ~= nil, true)
    test.equal(compacted["function"].arguments:find("main.c", 1, true) ~= nil, true)
  end)

  test.it("sends raw tool results by default", function()
    local old_compact = config.plugins.assistant.compact_tool_results
    config.plugins.assistant.compact_tool_results = false

    local agent = Agent()
    agent:register_tool("read", {
      compact_result = function()
        return "compacted"
      end
    })
    local raw = "line 1\nline 2"
    local message = agent:tool_result_provider_message({
      id = "call_1",
      name = "read"
    }, raw)

    config.plugins.assistant.compact_tool_results = old_compact
    test.equal(message.content:find(raw, 1, true) ~= nil, true)
    test.equal(message.content:find("compacted", 1, true), nil)
  end)

  test.it("sanitizes tool results before sending them to providers", function()
    local agent = Agent()
    local message = agent:tool_result_provider_message({
      id = "call_1",
      name = "read"
    }, "ok" .. string.char(0) .. string.char(0xff) .. "done")

    test.equal(message.content:find(string.char(0), 1, true), nil)
    test.equal(message.content:find(string.char(0xff), 1, true), nil)
    test.equal(message.content:find("\\x00", 1, true) ~= nil, true)
    test.equal(message.content:find("<invalid-utf8>", 1, true) ~= nil, true)
  end)

  test.it("sanitizes restored provider tool result messages", function()
    local agent = Agent()
    local conversation = Conversation(agent, snapshot_root)
    local call = {
      id = "call_1",
      name = "read",
      arguments = {}
    }
    conversation:add("tool_call", "Tool: read", {
      meta = {
        provider_message = agent:tool_call_provider_message({ call })
      },
      autosave = false
    })
    conversation:add("tool_result", "display text", {
      meta = {
        provider_message = {
          role = "tool",
          tool_call_id = "call_1",
          content = "ok" .. string.char(0) .. string.char(0xff) .. "done"
        }
      },
      autosave = false
    })

    local messages = agent:provider_messages_for_conversation(conversation)
    local content
    for _, message in ipairs(messages) do
      if message.role == "tool" then
        content = message.content
      end
    end

    test.not_nil(content)
    test.equal(content:find(string.char(0), 1, true), nil)
    test.equal(content:find(string.char(0xff), 1, true), nil)
    test.equal(content:find("\\x00", 1, true) ~= nil, true)
    test.equal(content:find("<invalid-utf8>", 1, true) ~= nil, true)
  end)

  test.it("can opt back into compacted tool results", function()
    local old_compact = config.plugins.assistant.compact_tool_results
    config.plugins.assistant.compact_tool_results = true

    local agent = Agent()
    agent:register_tool("read", {
      compact_result = function()
        return "compacted"
      end
    })
    local message = agent:tool_result_provider_message({
      id = "call_1",
      name = "read"
    }, "line 1\nline 2")

    config.plugins.assistant.compact_tool_results = old_compact
    test.equal(message.content:find("compacted", 1, true) ~= nil, true)
    test.equal(message.content:find("line 1", 1, true), nil)
  end)

  test.it("adds image read attachments as provider-only chat context", function()
    local agent = Ollama()
    local conversation = Conversation(agent, snapshot_root)
    local call = {
      id = "call_image",
      name = "read",
      arguments = { path = "image.png" }
    }
    local result = {
      text = "Read image file image.png [image/png] original 2x2, sent 2x2.",
      attachments = {
        {
          type = "image",
          mime_type = "image/png",
          data = "aW1hZ2U=",
          path = "image.png",
          width = 2,
          height = 2,
          original_width = 2,
          original_height = 2
        }
      }
    }
    conversation:add("tool_call", "Tool: read", {
      meta = {
        provider_message = agent:tool_call_provider_message({ call })
      },
      autosave = false
    })
    conversation:add("tool_result", agent:tool_result_display(call, result, "ok"), {
      meta = {
        provider_messages = agent:tool_result_provider_messages(call, result)
      },
      autosave = false
    })

    local payload = agent:build_payload(conversation)
    local messages = without_environment_messages(payload.messages)
    local tool_result = messages[#messages - 1]
    local image_context = messages[#messages]

    test.equal(tool_result.role, "tool")
    test.equal(tool_result.content:find("Read image file", 1, true) ~= nil, true)
    test.equal(tool_result.content:find("aW1hZ2U=", 1, true), nil)
    test.equal(image_context.role, "user")
    test.equal(image_context.content[1].type, "text")
    test.equal(image_context.content[2].type, "image_url")
    test.equal(image_context.content[2].image_url.url, "data:image/png;base64,aW1hZ2U=")
  end)

  test.it("adds image read attachments as Anthropic image blocks", function()
    local agent = Anthropic()
    local call = {
      id = "call_image",
      name = "read",
      arguments = { path = "image.png" }
    }
    local result = {
      text = "Read image file image.png [image/png] original 2x2, sent 2x2.",
      attachments = {
        {
          type = "image",
          mime_type = "image/png",
          data = "aW1hZ2U=",
          path = "image.png",
          width = 2,
          height = 2,
          original_width = 2,
          original_height = 2
        }
      }
    }

    local messages = agent:tool_result_provider_messages(call, result)
    local content = messages[1].content

    test.equal(content[1].type, "tool_result")
    test.equal(content[2].type, "text")
    test.equal(content[3].type, "image")
    test.equal(content[3].source.type, "base64")
    test.equal(content[3].source.media_type, "image/png")
    test.equal(content[3].source.data, "aW1hZ2U=")
  end)

  test.it("omits image read attachments for agents without vision capability", function()
    local agent = DeepSeek()
    local call = {
      id = "call_image",
      name = "read",
      arguments = { path = "image.png" }
    }
    local result = {
      text = "Read image file image.png [image/png] original 2x2, sent 2x2.",
      attachments = {
        {
          type = "image",
          mime_type = "image/png",
          data = "aW1hZ2U=",
          path = "image.png",
          width = 2,
          height = 2
        }
      }
    }

    local messages = agent:tool_result_provider_messages(call, result)

    test.equal(agent:has_capability("vision"), false)
    test.equal(#messages, 1)
    test.equal(messages[1].role, "tool")
  end)

  test.it("normalizes restored image_url blocks for Anthropic payloads", function()
    local agent = Anthropic()
    local conversation = Conversation(agent, snapshot_root)
    conversation:add("user", "look", { autosave = false })
    conversation:add("tool_result", "Tool: read\nStatus: ok", {
      meta = {
        provider_messages = {
          {
            role = "user",
            content = {
              { type = "text", text = "Image context" },
              {
                type = "image_url",
                image_url = { url = "data:image/png;base64,aW1hZ2U=" }
              }
            }
          }
        }
      },
      autosave = false
    })

    local payload = agent:build_payload(conversation)
    local block = payload.messages[#payload.messages].content[2]

    test.equal(block.type, "image")
    test.equal(block.source.type, "base64")
    test.equal(block.source.media_type, "image/png")
    test.equal(block.source.data, "aW1hZ2U=")
  end)

  test.it("drops restored image blocks for DeepSeek Anthropic", function()
    local agent = DeepSeekAnthropic()
    local conversation = Conversation(agent, snapshot_root)
    conversation:add("user", "look", { autosave = false })
    conversation:add("tool_result", "Tool: read\nStatus: ok", {
      meta = {
        provider_messages = {
          {
            role = "user",
            content = {
              { type = "text", text = "Image context" },
              {
                type = "image_url",
                image_url = { url = "data:image/png;base64,aW1hZ2U=" }
              },
              {
                type = "image",
                source = {
                  type = "base64",
                  media_type = "image/png",
                  data = "aW1hZ2U="
                }
              }
            }
          }
        }
      },
      autosave = false
    })

    local payload = agent:build_payload(conversation)
    local content = payload.messages[#payload.messages].content

    test.equal(agent:has_capability("vision"), false)
    test.equal(#content, 1)
    test.equal(content[1].type, "text")
  end)

  test.it("advertises image support on the read tool", function()
    local agent = Ollama()
    tools.register_agent_tools(agent)

    local description = agent.tools.read.description

    test.equal(description:find("Supports text files and images", 1, true) ~= nil, true)
    test.equal(description:find("Images are sent as attachments", 1, true) ~= nil, true)
  end)

  test.it("adds image read attachments as OpenAI responses image context", function()
    local agent = OpenAI()
    local conversation = Conversation(agent, snapshot_root)
    local call = {
      id = "call_image",
      call_id = "call_image",
      name = "read",
      arguments = { path = "image.png" }
    }
    local result = {
      text = "Read image file image.png [image/png] original 2x2, sent 2x2.",
      attachments = {
        {
          type = "image",
          mime_type = "image/png",
          data = "aW1hZ2U=",
          path = "image.png",
          width = 2,
          height = 2,
          original_width = 2,
          original_height = 2
        }
      }
    }
    conversation:add("tool_call", "Tool: read", {
      meta = {
        provider_message = agent:tool_call_provider_message({ call })
      },
      autosave = false
    })
    conversation:add("tool_result", agent:tool_result_display(call, result, "ok"), {
      meta = {
        provider_messages = agent:tool_result_provider_messages(call, result)
      },
      autosave = false
    })

    local payload = agent:build_payload(conversation)
    local image_context = payload.input[#payload.input]

    test.equal(image_context.role, "user")
    test.equal(image_context.content[1].type, "input_text")
    test.equal(image_context.content[2].type, "input_image")
    test.equal(image_context.content[2].image_url, "data:image/png;base64,aW1hZ2U=")
  end)

  test.it("truncates large tool call displays", function()
    local agent = Agent()
    local text = agent:tool_call_display({
      name = "apply_patch",
      arguments = {
        patch = string.rep("+int main() {}\n", 1000)
      }
    })

    test.equal(text:find("Tool: apply_patch", 1, true) ~= nil, true)
    test.equal(text:find("truncated", 1, true) ~= nil, true)
  end)

  test.it("preserves trailing non-patch tool payloads before provider requests", function()
    local agent = Agent({
      compact_implementation_tools = true,
      capabilities = {
        stream_responses = true,
        tool_calling = true
      }
    })
    local conversation = Conversation(agent, "project")
    local args = json.encode({
      path = "project/main.c"
    })
    conversation:add("tool_call", "", {
      autosave = false,
      meta = {
        provider_message = {
          role = "assistant",
          content = "",
          tool_calls = {
            {
              id = "call_1",
              type = "function",
              ["function"] = {
                name = "read",
                arguments = args
              }
            }
          }
        }
      }
    })
    local large_tool_result = "Tool `read` result:\n" .. string.rep("line\n", 12000)
    conversation:add("tool_result", large_tool_result, {
      autosave = false,
      meta = {
        provider_message = {
          role = "tool",
          tool_call_id = "call_1",
          content = large_tool_result
        }
      }
    })

    local payload = agent:build_payload(conversation)
    payload.messages = without_environment_messages(payload.messages)
    test.equal(payload.messages[2].role, "assistant")
    test.equal(payload.messages[2].tool_calls[1]["function"].name, "read")
    test.equal(payload.messages[2].tool_calls[1]["function"].arguments:find("project/main.c", 1, true) ~= nil, true)
    test.equal(payload.messages[3].role, "tool")
    test.equal(payload.messages[3].content:find("Tool `read` result:", 1, true) ~= nil, true)
  end)

  test.it("omits non-trailing historical tool payloads before provider requests", function()
    local old_compact = config.plugins.assistant.compact_tool_history
    config.plugins.assistant.compact_tool_history = true

    local agent = Agent({
      compact_implementation_tools = true,
      capabilities = {
        stream_responses = true,
        tool_calling = true
      }
    })
    local conversation = Conversation(agent, "project")
    local large_source = string.rep("int main(void) { return 0; }\n", 3000)
    local args = json.encode({
      patch = "*** Begin Patch\n*** Add File: main.c\n" .. large_source:gsub("([^\n]*)\n", "+%1\n") .. "*** End Patch"
    })
    conversation:add("tool_call", "", {
      autosave = false,
      meta = {
        provider_message = {
          role = "assistant",
          content = "",
          tool_calls = {
            {
              id = "call_1",
              type = "function",
              ["function"] = {
                name = "apply_patch",
                arguments = args
              }
            }
          }
        }
      }
    })
    local large_tool_result = "Tool `read` result:\n" .. string.rep("line\n", 12000)
    conversation:add("tool_result", large_tool_result, {
      autosave = false,
      meta = {
        provider_message = {
          role = "tool",
          tool_call_id = "call_1",
          content = large_tool_result
        }
      }
    })
    conversation:add("assistant", "Done.", { autosave = false })

    local payload = agent:build_payload(conversation)
    payload.messages = without_environment_messages(payload.messages)
    config.plugins.assistant.compact_tool_history = old_compact
    test.equal(payload.messages[2].role, "assistant")
    test.equal(payload.messages[2].content:find("Added File: main.c", 1, true) ~= nil, true)
    test.equal(payload.messages[3].role, "assistant")
    test.equal(payload.messages[3].tool_calls, nil)
    test.equal(payload.messages[3].content, "Done.")
    test.equal(payload.messages[4], nil)
  end)

  test.it("replaces historical apply_patch payloads with current file snapshots", function()
    local old_compact = config.plugins.assistant.compact_tool_history
    config.plugins.assistant.compact_tool_history = true

    common.rm(snapshot_root, true)
    mkdirp(snapshot_root)
    write(snapshot_root .. PATHSEP .. "main.c", "int main(void) {\n  return 7;\n}\n")

    local agent = Agent({
      compact_implementation_tools = true,
      capabilities = {
        stream_responses = true,
        tool_calling = true
      }
    })
    local conversation = Conversation(agent, snapshot_root)
    local large_source = string.rep("int main(void) { return 0; }\n", 3000)
    local args = json.encode({
      patch = "*** Begin Patch\n*** Add File: main.c\n" .. large_source:gsub("([^\n]*)\n", "+%1\n") .. "*** End Patch"
    })
    conversation:add("tool_call", "", {
      autosave = false,
      meta = {
        provider_message = {
          role = "assistant",
          content = "",
          tool_calls = {
            {
              id = "call_snapshot",
              type = "function",
              ["function"] = {
                name = "apply_patch",
                arguments = args
              }
            }
          }
        }
      }
    })
    conversation:add("tool_result", "applied patch to 1 file(s)", {
      autosave = false,
      meta = {
        provider_message = {
          role = "tool",
          tool_call_id = "call_snapshot",
          content = "applied patch to 1 file(s)"
        }
      }
    })
    conversation:add("assistant", "Done.", { autosave = false })

    local payload = agent:build_payload(conversation)
    payload.messages = without_environment_messages(payload.messages)
    config.plugins.assistant.compact_tool_history = old_compact
    test.equal(payload.messages[2].role, "assistant")
    test.equal(payload.messages[2].content:find("# Already Applied Changes", 1, true) ~= nil, true)
    test.equal(payload.messages[2].content:find("Added File: main.c", 1, true) ~= nil, true)
    test.equal(payload.messages[2].content:find("```c\nint main", 1, true) ~= nil, true)
    test.equal(payload.messages[2].content:find("return 7", 1, true) ~= nil, true)
    test.equal(payload.messages[2].content:find("int main(void) { return 0; }", 1, true), nil)
    test.equal(payload.messages[3].role, "assistant")
    test.equal(payload.messages[3].content, "Done.")

    common.rm(snapshot_root, true)
  end)

  test.it("preserves latest completed apply_patch exchanges before continuation requests", function()
    local old_compact = config.plugins.assistant.compact_tool_history
    config.plugins.assistant.compact_tool_history = true

    common.rm(snapshot_root, true)
    mkdirp(snapshot_root)
    write(snapshot_root .. PATHSEP .. "src" .. PATHSEP .. "game.c", "int game_run(void) {\n  return 42;\n}\n")

    local agent = Agent({
      compact_implementation_tools = true,
      capabilities = {
        stream_responses = true,
        tool_calling = true
      }
    })
    local conversation = Conversation(agent, snapshot_root)
    local args = json.encode({
      patch = table.concat({
        "*** Begin Patch",
        "*** Add File: src/game.c",
        "+int game_run(void) {",
        "+  return 0;",
        "+}",
        "*** End Patch"
      }, "\n")
    })
    conversation:add("tool_call", "", {
      autosave = false,
      meta = {
        provider_message = {
          role = "assistant",
          content = "",
          tool_calls = {
            {
              id = "call_latest_patch",
              type = "function",
              ["function"] = {
                name = "apply_patch",
                arguments = args
              }
            }
          }
        }
      }
    })
    conversation:add("tool_result", "applied patch to 1 file(s)", {
      autosave = false,
      meta = {
        provider_message = {
          role = "tool",
          tool_call_id = "call_latest_patch",
          content = "Tool `apply_patch` result:\napplied patch to 1 file(s)\nChanged files:\n- added src/game.c"
        }
      }
    })
    local payload = agent:build_payload(conversation)
    payload.messages = without_environment_messages(payload.messages)
    config.plugins.assistant.compact_tool_history = old_compact
    local encoded = json.encode(payload.messages)
    test.equal(encoded:find("call_latest_patch", 1, true) ~= nil, true)
    test.equal(encoded:find("*** Add File: src/game.c", 1, true) ~= nil, true)
    test.equal(encoded:find("Tool `apply_patch` result:", 1, true) ~= nil, true)
    test.equal(encoded:find("Added File: src/game.c", 1, true), nil)
    test.equal(encoded:find("return 42", 1, true), nil)
    test.equal(payload.messages[2].role, "assistant")
    test.equal(payload.messages[2].tool_calls[1]["function"].name, "apply_patch")
    test.equal(payload.messages[3].role, "tool")
    test.equal(payload.messages[3].tool_call_id, "call_latest_patch")

    common.rm(snapshot_root, true)
  end)

  test.it("preserves failed latest apply_patch exchanges so the model can recover", function()
    local old_compact = config.plugins.assistant.compact_tool_history
    config.plugins.assistant.compact_tool_history = true

    local agent = Agent({
      compact_implementation_tools = true,
      capabilities = {
        stream_responses = true,
        tool_calling = true
      }
    })
    local conversation = Conversation(agent, snapshot_root)
    local args = json.encode({
      patch = "*** Begin Patch\n*** Add File: src/game.c\n+int game_run(void) { return 0; }\n*** End Patch"
    })
    conversation:add("tool_call", "", {
      autosave = false,
      meta = {
        provider_message = {
          role = "assistant",
          content = "",
          tool_calls = {
            {
              id = "call_failed_patch",
              type = "function",
              ["function"] = {
                name = "apply_patch",
                arguments = args
              }
            }
          }
        }
      }
    })
    conversation:add("tool_result", "error: file already exists", {
      autosave = false,
      meta = {
        provider_message = {
          role = "tool",
          tool_call_id = "call_failed_patch",
          content = "Tool `apply_patch` result:\nerror: file already exists"
        }
      }
    })

    local payload = agent:build_payload(conversation)
    payload.messages = without_environment_messages(payload.messages)
    config.plugins.assistant.compact_tool_history = old_compact
    local encoded = json.encode(payload.messages)
    test.equal(encoded:find("call_failed_patch", 1, true) ~= nil, true)
    test.equal(encoded:find("*** Add File: src/game.c", 1, true) ~= nil, true)
    test.equal(encoded:find("file already exists", 1, true) ~= nil, true)
  end)

  test.it("labels Add File overwrites as patched file snapshots", function()
    local old_compact = config.plugins.assistant.compact_tool_history
    config.plugins.assistant.compact_tool_history = true

    common.rm(snapshot_root, true)
    mkdirp(snapshot_root)
    write(snapshot_root .. PATHSEP .. "include" .. PATHSEP .. "sario.h", "#ifndef SARIO_H\n#define SARIO_H\n#endif\n")

    local agent = Agent({
      compact_implementation_tools = true,
      capabilities = {
        stream_responses = true,
        tool_calling = true
      }
    })
    local conversation = Conversation(agent, snapshot_root)
    conversation:add("tool_call", "", {
      autosave = false,
      meta = {
        provider_message = {
          role = "assistant",
          content = "",
          tool_calls = {
            {
              id = "call_overwrite",
              type = "function",
              ["function"] = {
                name = "apply_patch",
                arguments = json.encode({
                  patch = "*** Begin Patch\n*** Add File: include/sario.h\n+#ifndef SARIO_H\n+#define SARIO_H\n+#endif\n*** End Patch"
                })
              }
            }
          }
        }
      }
    })
    conversation:add("tool_result", "applied patch to 1 file(s)", {
      autosave = false,
      meta = {
        provider_message = {
          role = "tool",
          tool_call_id = "call_overwrite",
          content = table.concat({
            "Tool `apply_patch` result:",
            "applied patch to 1 file(s)",
            "Changed files:",
            "- updated existing include/sario.h via Add File (file already existed; do not recreate it again)"
          }, "\n")
        }
      }
    })
    conversation:add("assistant", "Header updated.", { autosave = false })

    local payload = agent:build_payload(conversation)
    payload.messages = without_environment_messages(payload.messages)
    config.plugins.assistant.compact_tool_history = old_compact
    local encoded = json.encode(payload.messages)
    test.equal(encoded:find("Added File: include/sario.h", 1, true), nil)
    test.equal(encoded:find("Patched File: include/sario.h", 1, true) ~= nil, true)
    test.equal(encoded:find("Do not use Add File for listed existing files", 1, true) ~= nil, true)

    common.rm(snapshot_root, true)
  end)

  test.it("summarizes compacted apply_patch operations with labels and fences", function()
    local old_compact = config.plugins.assistant.compact_tool_history
    config.plugins.assistant.compact_tool_history = true

    common.rm(snapshot_root, true)
    mkdirp(snapshot_root)
    write(snapshot_root .. PATHSEP .. "main.c", "int main(void) {\n  return 3;\n}\n")
    write(snapshot_root .. PATHSEP .. "new.lua", "return 4\n")
    write(snapshot_root .. PATHSEP .. "docs" .. PATHSEP .. "guide.md", "# Guide\n")

    local agent = Agent({
      compact_implementation_tools = true,
      capabilities = {
        stream_responses = true,
        tool_calling = true
      }
    })
    local conversation = Conversation(agent, snapshot_root)
    local args = json.encode({
      patch = table.concat({
        "*** Begin Patch",
        "*** Add File: new.lua",
        "+return 4",
        "*** Update File: main.c",
        "@@",
        "-  return 0;",
        "+  return 3;",
        "*** Update File: old.md",
        "*** Move to: docs/guide.md",
        "@@",
        "-# Old",
        "+# Guide",
        "*** Delete File: removed.c",
        "*** End Patch"
      }, "\n")
    })
    conversation:add("tool_call", "", {
      autosave = false,
      meta = {
        provider_message = {
          role = "assistant",
          content = "",
          tool_calls = {
            {
              id = "call_ops",
              type = "function",
              ["function"] = {
                name = "apply_patch",
                arguments = args
              }
            }
          }
        }
      }
    })
    conversation:add("tool_result", "applied patch to 4 file(s)", {
      autosave = false,
      meta = {
        provider_message = {
          role = "tool",
          tool_call_id = "call_ops",
          content = "applied patch to 4 file(s)"
        }
      }
    })
    conversation:add("assistant", "Done.", { autosave = false })

    local payload = agent:build_payload(conversation)
    payload.messages = without_environment_messages(payload.messages)
    config.plugins.assistant.compact_tool_history = old_compact
    local content = payload.messages[2].content
    test.equal(content:find("Added File: new.lua", 1, true) ~= nil, true)
    test.equal(content:find("```lua\nreturn 4", 1, true) ~= nil, true)
    test.equal(content:find("Patched File: main.c", 1, true) ~= nil, true)
    test.equal(content:find("```c\nint main", 1, true) ~= nil, true)
    test.equal(content:find("Moved File: old.md -> docs/guide.md", 1, true) ~= nil, true)
    test.equal(content:find("```markdown\n# Guide", 1, true) ~= nil, true)
    test.equal(content:find("Deleted File: removed.c", 1, true) ~= nil, true)
    test.equal(content:find("This file was deleted and no longer exists.", 1, true) ~= nil, true)

    common.rm(snapshot_root, true)
  end)

  test.it("summarizes captured live add-file patches as added file snapshots", function()
    local old_compact = config.plugins.assistant.compact_tool_history
    config.plugins.assistant.compact_tool_history = true

    common.rm(snapshot_root, true)
    mkdirp(snapshot_root)
    local fixture = read("live_tests/failed-apply-patch.patch")
    local paths = {
      "include/sario.h",
      "src/main.c",
      "src/game.c",
      "src/player.c",
      "src/level.c",
      "src/entities.c",
      "src/collision.c",
      "src/graphics.c",
      "src/input.c",
      "src/physics.c",
      "Makefile",
      "README.md"
    }
    for _, path in ipairs(paths) do
      write(snapshot_root .. PATHSEP .. path, "snapshot for " .. path .. "\n")
    end

    local agent = Agent({
      compact_implementation_tools = true,
      capabilities = {
        stream_responses = true,
        tool_calling = true
      }
    })
    local conversation = Conversation(agent, snapshot_root)
    conversation:add("tool_call", "", {
      autosave = false,
      meta = {
        provider_message = {
          role = "assistant",
          content = "",
          tool_calls = {
            {
              id = "call_sario",
              type = "function",
              ["function"] = {
                name = "apply_patch",
                arguments = json.encode({ patch = fixture })
              }
            }
          }
        }
      }
    })
    conversation:add("tool_result", "applied patch to 12 file(s)", {
      autosave = false,
      meta = {
        provider_message = {
          role = "tool",
          tool_call_id = "call_sario",
          content = "applied patch to 12 file(s)"
        }
      }
    })
    conversation:add("assistant", "Done.", { autosave = false })

    local payload = agent:build_payload(conversation)
    payload.messages = without_environment_messages(payload.messages)
    config.plugins.assistant.compact_tool_history = old_compact
    local content = payload.messages[2].content
    for _, path in ipairs(paths) do
      test.equal(content:find("Added File: " .. path, 1, true) ~= nil, true)
      test.equal(content:find("snapshot for " .. path, 1, true) ~= nil, true)
    end
    test.equal(content:find("*** Add File: include/sario.h", 1, true), nil)

    common.rm(snapshot_root, true)
  end)

  test.it("snapshots processed apply_patch calls before later reasoning-only tool turns", function()
    local old_compact = config.plugins.assistant.compact_tool_history
    config.plugins.assistant.compact_tool_history = true

    common.rm(snapshot_root, true)
    mkdirp(snapshot_root)
    write(snapshot_root .. PATHSEP .. "main.c", "int main(void) {\n  return 9;\n}\n")

    local agent = Agent({
      compact_implementation_tools = true,
      capabilities = {
        stream_responses = true,
        tool_calling = true
      }
    })
    local conversation = Conversation(agent, snapshot_root)
    local first_args = json.encode({
      patch = "*** Begin Patch\n*** Add File: main.c\n" .. string.rep("+int old(void) { return 0; }\n", 3000) .. "*** End Patch"
    })
    conversation:add("tool_call", "", {
      autosave = false,
      meta = {
        provider_message = {
          role = "assistant",
          content = "",
          tool_calls = {
            {
              id = "call_processed",
              type = "function",
              ["function"] = {
                name = "apply_patch",
                arguments = first_args
              }
            }
          }
        }
      }
    })
    conversation:add("tool_result", "applied patch to 1 file(s)", {
      autosave = false,
      meta = {
        provider_message = {
          role = "tool",
          tool_call_id = "call_processed",
          content = "applied patch to 1 file(s)"
        }
      }
    })
    local second_args = json.encode({
      patch = "*** Begin Patch\n*** Add File: later.c\n+int later(void) { return 1; }\n*** End Patch"
    })
    conversation:add("tool_call", "", {
      autosave = false,
      meta = {
        provider_message = {
          role = "assistant",
          content = "",
          tool_calls = {
            {
              id = "call_active",
              type = "function",
              ["function"] = {
                name = "apply_patch",
                arguments = second_args
              }
            }
          }
        }
      }
    })

    local payload = agent:build_payload(conversation)
    payload.messages = without_environment_messages(payload.messages)
    config.plugins.assistant.compact_tool_history = old_compact
    local encoded = json.encode(payload.messages)
    test.equal(encoded:find("# Already Applied Changes", 1, true) ~= nil, true)
    test.equal(encoded:find("return 9", 1, true) ~= nil, true)
    test.equal(encoded:find("int old(void) { return 0; }", 1, true), nil)
    test.equal(encoded:find("call_active", 1, true) ~= nil, true)
    test.equal(encoded:find("later.c", 1, true) ~= nil, true)

    common.rm(snapshot_root, true)
  end)

  test.it("preserves unresolved tool calls before provider requests", function()
    local agent = Agent({
      compact_implementation_tools = true,
      capabilities = {
        stream_responses = true,
        tool_calling = true
      }
    })
    local conversation = Conversation(agent, "project")
    local large_source = string.rep("int main(void) { return 0; }\n", 3000)
    local args = json.encode({
      patch = "*** Begin Patch\n*** Add File: main.c\n" .. large_source:gsub("([^\n]*)\n", "+%1\n") .. "*** End Patch"
    })
    conversation:add("tool_call", "", {
      autosave = false,
      meta = {
        provider_message = {
          role = "assistant",
          content = "",
          tool_calls = {
            {
              id = "call_unresolved",
              type = "function",
              ["function"] = {
                name = "apply_patch",
                arguments = args
              }
            }
          }
        }
      }
    })
    conversation:add("user", "continue", { autosave = false })

    local payload = agent:build_payload(conversation)
    payload.messages = without_environment_messages(payload.messages)
    test.equal(payload.messages[2].role, "assistant")
    test.equal(payload.messages[2].tool_calls[1].id, "call_unresolved")
    test.equal(payload.messages[2].tool_calls[1]["function"].arguments:find("int main", 1, true) ~= nil, true)
    test.equal(payload.messages[3].role, "tool")
    test.equal(payload.messages[3].tool_call_id, "call_unresolved")
    test.equal(payload.messages[4].role, "user")
  end)

  test.it("preserves unprocessed non-patch tool results before provider requests", function()
    local agent = Agent({
      compact_implementation_tools = true,
      capabilities = {
        stream_responses = true,
        tool_calling = true
      }
    })
    local conversation = Conversation(agent, "project")
    local args = json.encode({
      path = "project/main.c"
    })
    conversation:add("tool_call", "", {
      autosave = false,
      meta = {
        provider_message = {
          role = "assistant",
          content = "",
          tool_calls = {
            {
              id = "call_unprocessed",
              type = "function",
              ["function"] = {
                name = "read",
                arguments = args
              }
            }
          }
        }
      }
    })
    local large_tool_result = "Tool `read` result:\n" .. string.rep("created line\n", 12000)
    conversation:add("tool_result", large_tool_result, {
      autosave = false,
      meta = {
        provider_message = {
          role = "tool",
          tool_call_id = "call_unprocessed",
          content = large_tool_result
        }
      }
    })
    conversation:add("user", "continue", { autosave = false })

    local payload = agent:build_payload(conversation)
    payload.messages = without_environment_messages(payload.messages)
    test.equal(payload.messages[2].role, "assistant")
    test.equal(payload.messages[2].tool_calls[1].id, "call_unprocessed")
    test.equal(payload.messages[2].tool_calls[1]["function"].name, "read")
    test.equal(payload.messages[2].tool_calls[1]["function"].arguments:find("project/main.c", 1, true) ~= nil, true)
    test.equal(payload.messages[3].role, "tool")
    test.equal(payload.messages[3].tool_call_id, "call_unprocessed")
    test.equal(payload.messages[3].content, large_tool_result)
    test.equal(payload.messages[4].role, "user")
  end)

  test.it("compacts completed historical file inspection tool calls before provider requests", function()
    local old_compact = config.plugins.assistant.compact_tool_history
    config.plugins.assistant.compact_tool_history = true

    common.rm(snapshot_root, true)
    mkdirp(snapshot_root)
    write(snapshot_root .. PATHSEP .. "README.md", "current readme\nsecond line\n")
    write(snapshot_root .. PATHSEP .. "manifest.json", "{\"name\":\"manifest\"}\n")

    local agent = tools.register_agent_tools(Agent({
      compact_implementation_tools = true,
      capabilities = {
        stream_responses = true,
        tool_calling = true
      }
    }))
    local conversation = Conversation(agent, snapshot_root)
    local calls = {
      {
        id = "call_read",
        name = "read",
        arguments = {
          path = "README.md"
        }
      },
      {
        id = "call_search",
        name = "search",
        arguments = {
          directory = snapshot_root,
          text = "old-name",
          search_type = "plain"
        }
      },
      {
        id = "call_list",
        name = "list",
        arguments = {
          directory = snapshot_root,
          recursive = false
        }
      },
      {
        id = "call_info",
        name = "file_info",
        arguments = {
          path = "README.md"
        }
      }
    }
    conversation:add("tool_call", "", {
      autosave = false,
      meta = {
        provider_message = agent:tool_call_provider_message(calls)
      }
    })
    local results = {
      call_read = "first line\nsecond line\nthird line\n",
      call_search = snapshot_root .. "/README.md:1:old-name reference\n" .. snapshot_root .. "/manifest.json:2:old-name reference",
      call_list = snapshot_root .. "/README.md\n" .. snapshot_root .. "/manifest.json",
      call_info = "path: " .. snapshot_root .. "/README.md\ntype: file\nsize: 12\nmodified: 1\nhash: abc123"
    }
    for _, call in ipairs(calls) do
      conversation:add("tool_result", results[call.id], {
        autosave = false,
        meta = {
          provider_message = agent:tool_result_provider_message(call, results[call.id])
        }
      })
    end
    conversation:add("assistant", "Done.", { autosave = false })

    local payload = agent:build_payload(conversation)
    payload.messages = without_environment_messages(payload.messages)
    config.plugins.assistant.compact_tool_history = old_compact
    local encoded = json.encode(payload.messages)
    test.equal(encoded:find("Current File Context", 1, true) ~= nil, true)
    test.equal(encoded:find("Completed File Inspections", 1, true) ~= nil, true)
    test.equal(encoded:find("searched `", 1, true) ~= nil, true)
    test.equal(encoded:find("Read File: README.md", 1, true) ~= nil, true)
    test.equal(encoded:find("current readme", 1, true) ~= nil, true)
    test.equal(encoded:find("call_read", 1, true), nil)
    test.equal(encoded:find("Tool `read` result:", 1, true), nil)
    test.equal(payload.messages[#payload.messages].content, "Done.")
  end)

  test.it("does not summarize failed file inspection tool calls as completed inspections", function()
    local old_compact = config.plugins.assistant.compact_tool_history
    config.plugins.assistant.compact_tool_history = true

    local agent = tools.register_agent_tools(Agent({
      compact_implementation_tools = true,
      capabilities = {
        stream_responses = true,
        tool_calling = true
      }
    }))
    local conversation = Conversation(agent, snapshot_root)
    local call = {
      id = "call_failed_search",
      name = "search",
      arguments = {
        directory = snapshot_root,
        text = "old-name",
        search_type = "plain"
      }
    }
    conversation:add("tool_call", "", {
      autosave = false,
      meta = {
        provider_message = agent:tool_call_provider_message({ call })
      }
    })
    local result = "tool error: search query is too broad for this exact replacement task"
    conversation:add("tool_result", result, {
      autosave = false,
      meta = {
        provider_message = agent:tool_result_provider_message(call, result)
      }
    })
    conversation:add("assistant", "Done.", { autosave = false })

    local payload = agent:build_payload(conversation)
    payload.messages = without_environment_messages(payload.messages)
    config.plugins.assistant.compact_tool_history = old_compact
    local encoded = json.encode(payload.messages)
    test.equal(encoded:find("Completed File Inspections", 1, true), nil)
    test.equal(encoded:find("searched `", 1, true), nil)
    test.equal(encoded:find("tool error: search query is too broad", 1, true), nil)
  end)

  test.it("compacts completed historical file mutation tool calls before provider requests", function()
    local old_compact = config.plugins.assistant.compact_tool_history
    config.plugins.assistant.compact_tool_history = true

    common.rm(snapshot_root, true)
    mkdirp(snapshot_root)
    write(snapshot_root .. PATHSEP .. "main.c", "after\n")

    local agent = tools.register_agent_tools(Agent({
      compact_implementation_tools = true,
      capabilities = {
        stream_responses = true,
        tool_calling = true
      }
    }))
    local conversation = Conversation(agent, snapshot_root)
    local call = {
      id = "call_edit",
      name = "edit",
      arguments = {
        path = "main.c",
        edits = {
          {
            oldText = "before\n",
            newText = "after\n"
          }
        }
      }
    }
    conversation:add("tool_call", "", {
      autosave = false,
      meta = {
        provider_message = agent:tool_call_provider_message({ call })
      }
    })
    local result = "Successfully replaced 1 block(s) in main.c.\n--- main.c\n+++ main.c\n@@\n-before\n+after"
    conversation:add("tool_result", result, {
      autosave = false,
      meta = {
        provider_message = agent:tool_result_provider_message(call, result)
      }
    })
    conversation:add("assistant", "Done.", { autosave = false })

    local payload = agent:build_payload(conversation)
    payload.messages = without_environment_messages(payload.messages)
    config.plugins.assistant.compact_tool_history = old_compact
    local encoded = json.encode(payload.messages)
    test.equal(encoded:find("# Already Applied Changes", 1, true) ~= nil, true)
    test.equal(encoded:find("Edited File: main.c", 1, true) ~= nil, true)
    test.equal(encoded:find("after\\n", 1, true) ~= nil, true)
    test.equal(encoded:find("call_edit", 1, true), nil)
    test.equal(encoded:find("before\\n", 1, true), nil)
    test.equal(encoded:find("Tool `edit` result:", 1, true), nil)
    test.equal(payload.messages[#payload.messages].content, "Done.")
  end)

  test.it("does not keep stale read snapshots after later file mutations", function()
    local old_compact = config.plugins.assistant.compact_tool_history
    config.plugins.assistant.compact_tool_history = true

    common.rm(snapshot_root, true)
    mkdirp(snapshot_root)
    write(snapshot_root .. PATHSEP .. "README.md", "after\n")

    local agent = tools.register_agent_tools(Agent({
      compact_implementation_tools = true,
      capabilities = {
        stream_responses = true,
        tool_calling = true
      }
    }))
    local conversation = Conversation(agent, snapshot_root)
    local read_call = {
      id = "call_read_old",
      name = "read",
      arguments = { path = "README.md" }
    }
    conversation:add("tool_call", "", {
      autosave = false,
      meta = {
        provider_message = agent:tool_call_provider_message({ read_call })
      }
    })
    conversation:add("tool_result", "before\n", {
      autosave = false,
      meta = {
        provider_message = agent:tool_result_provider_message(read_call, "before\n")
      }
    })
    local edit_call = {
      id = "call_edit_after_read",
      name = "edit",
      arguments = {
        path = "README.md",
        edits = {
          {
            oldText = "before\n",
            newText = "after\n"
          }
        }
      }
    }
    conversation:add("tool_call", "", {
      autosave = false,
      meta = {
        provider_message = agent:tool_call_provider_message({ edit_call })
      }
    })
    conversation:add("tool_result", "Successfully replaced 1 block(s) in README.md.", {
      autosave = false,
      meta = {
        provider_message = agent:tool_result_provider_message(edit_call, "Successfully replaced 1 block(s) in README.md.")
      }
    })
    conversation:add("assistant", "Done.", { autosave = false })

    local payload = agent:build_payload(conversation)
    payload.messages = without_environment_messages(payload.messages)
    config.plugins.assistant.compact_tool_history = old_compact
    local encoded = json.encode(payload.messages)
    test.equal(encoded:find("Edited File: README.md", 1, true) ~= nil, true)
    test.equal(encoded:find("after\\n", 1, true) ~= nil, true)
    test.equal(encoded:find("before\\n", 1, true), nil)
    test.equal(encoded:find("Read File: README.md", 1, true) ~= nil, true)
  end)

  test.it("compacts completed historical web tool calls before provider requests", function()
    local old_compact = config.plugins.assistant.compact_tool_history
    config.plugins.assistant.compact_tool_history = true

    local agent = tools.register_agent_tools(Agent({
      compact_implementation_tools = true,
      capabilities = {
        stream_responses = true,
        tool_calling = true
      }
    }))
    local conversation = Conversation(agent, snapshot_root)
    local call = {
      id = "call_web",
      name = "web_fetch",
      arguments = {
        url = "https://example.com/large"
      }
    }
    conversation:add("tool_call", "", {
      autosave = false,
      meta = {
        provider_message = agent:tool_call_provider_message({ call })
      }
    })
    local result = "status: 200\nurl: https://example.com/large\nbody:\n" .. string.rep("huge html\n", 2000)
    conversation:add("tool_result", result, {
      autosave = false,
      meta = {
        provider_message = agent:tool_result_provider_message(call, result)
      }
    })
    conversation:add("assistant", "Done.", { autosave = false })

    local payload = agent:build_payload(conversation)
    payload.messages = without_environment_messages(payload.messages)
    config.plugins.assistant.compact_tool_history = old_compact
    local encoded = json.encode(payload.messages)
    test.equal(encoded:find("# Prior Web Lookups", 1, true) ~= nil, true)
    test.equal(encoded:find("https://example.com/large", 1, true) ~= nil, true)
    test.equal(encoded:find("call_web", 1, true), nil)
    test.equal(encoded:find("huge html\\nhuge html\\nhuge html\\nhuge html\\nhuge html\\nhuge html", 1, true), nil)
    test.equal(payload.messages[#payload.messages].content, "Done.")
  end)

  test.it("repairs missing tool outputs before provider requests", function()
    local agent = Agent({
      capabilities = {
        stream_responses = true,
        tool_calling = true
      }
    })
    local conversation = Conversation(agent, "project")
    conversation:add("tool_call", "", {
      autosave = false,
      meta = {
        provider_message = {
          role = "assistant",
          content = "",
          tool_calls = {
            {
              id = "call_missing",
              type = "function",
              ["function"] = {
                name = "read",
                arguments = '{"path":"project/main.c"}'
              }
            }
          }
        }
      }
    })

    local payload = agent:build_payload(conversation)
    payload.messages = without_environment_messages(payload.messages)

    test.equal(payload.messages[2].tool_calls[1].id, "call_missing")
    test.equal(payload.messages[3].role, "tool")
    test.equal(payload.messages[3].tool_call_id, "call_missing")
    test.equal(payload.messages[3].content:find("aborted", 1, true) ~= nil, true)
  end)

  test.it("refuses to execute write tools with compacted placeholders", function()
    local agent = Agent()
    local called = false
    agent:register_tool("apply_patch", {
      callback = function()
        called = true
        return true, "applied"
      end,
      params = {
        { name = "patch", type = "string" }
      }
    })

    local ok, result = agent:execute_tool({
      name = "apply_patch",
      arguments = {
        patch = "[omitted 42 bytes from prior tool argument `patch`]"
      }
    })

    test.equal(ok, false)
    test.equal(called, false)
    test.equal(result:find("placeholder", 1, true) ~= nil, true)

    ok, result = agent:execute_tool({
      name = "apply_patch",
      arguments = {
        prior_tool_call_summary = "Historical `apply_patch` call had large content omitted from provider history.",
        omitted_content_bytes = 417
      }
    })

    test.equal(ok, false)
    test.equal(called, false)
    test.equal(result:find("placeholder", 1, true) ~= nil, true)
  end)

  test.it("refuses empty apply_patch calls before invoking the tool", function()
    local agent = Agent()
    local called = false
    agent:register_tool("apply_patch", {
      callback = function()
        called = true
        return false, "patch contains no files"
      end,
      params = {
        { name = "patch", type = "string" }
      }
    })

    local ok, result = agent:execute_tool({
      name = "apply_patch",
      arguments = {}
    })

    test.equal(ok, false)
    test.equal(called, false)
    test.equal(result:find("missing patch argument", 1, true) ~= nil, true)
  end)

  test.it("narrows broad substring searches for exact replacement prompts", function()
    local core = require "core"
    local root = assistant_test_temp_path("exact-replacement-search")
    mkdirp(root)
    write(root .. PATHSEP .. "README.md", "old-org/old-repo\nold-org\n")

    local old_projects = core.projects
    core.projects = { { path = root } }

    local agent = tools.register_agent_tools(Agent())
    local conversation = Conversation(agent, root)
    conversation:add(
      "user",
      "update all references on this project from old-org/old-repo to new-org/new-repo",
      { autosave = false }
    )
    agent._assistant_tool_conversation = conversation

    local ok, result = agent:execute_tool({
      name = "search",
      arguments = {
        directory = root,
        text = "old-org",
        search_type = "plain"
      }
    })

    test.equal(ok, true)
    test.equal(result:find("was narrowed to the exact old value", 1, true) ~= nil, true)
    test.equal(result:find("README.md", 1, true) ~= nil, true)
    test.equal(result:find("README.md:2:old%-org") ~= nil, false)

    ok, result = agent:execute_tool({
      name = "search",
      arguments = {
        directory = root,
        text = "Old-Org",
        search_type = "plain"
      }
    })

    test.equal(ok, true)
    test.equal(result:find("was narrowed to the exact old value", 1, true) ~= nil, true)

    ok, result = agent:execute_tool({
      name = "search",
      arguments = {
        directory = root,
        text = "old-org/old-repo",
        search_type = "plain"
      }
    })

    agent._assistant_tool_conversation = nil
    core.projects = old_projects

    test.equal(ok, true)
    test.equal(result:find("README.md", 1, true) ~= nil, true)
  end)

  test.it("classifies read-only and unsafe shell commands", function()
    test.equal(permission.classify_command("pwd && ls -la").category, "read_only")
    test.equal(permission.classify_command("grep -n \"F11\\|fullscreen\" tetris.c").category, "read_only")
    test.equal(permission.classify_command("mkdir -p src").category, "project_write")
    test.equal(permission.classify_command("rm -rf src").category, "destructive")
    test.equal(permission.classify_command("pwd | tee out.txt").category, "sandbox_escape")
    test.equal(permission.classify_command("cat $(pwd)/file").category, "sandbox_escape")
    test.equal(permission.command_prefix("make test"), "make test")
    test.equal(permission.command_matches_prefix("make test VERBOSE=1", "make test"), true)
    test.equal(permission.command_matches_prefix("make clean", "make test"), false)
  end)

  test.it("uses permission classifier for exec_command approval", function()
    local agent = tools.register_agent_tools(Agent({
      capabilities = {
        tool_calling = true
      }
    }))

    test.equal(agent:tool_requires_approval({
      name = "exec_command",
      arguments = {
        cmd = "pwd && ls -la"
      }
    }), false)
    test.equal(agent:tool_requires_approval({
      name = "exec_command",
      arguments = {
        cmd = "mkdir -p src"
      }
    }), true)
  end)

  test.it("uses explicit loopback default for ollama", function()
    local agent = Ollama()
    test.equal(agent.base_url, "http://127.0.0.1:11434")
    test.equal(agent.endpoint, "/v1/chat/completions")
    test.equal(agent.models_endpoint, "/v1/models")
    test.equal(agent.stream_format, "sse")
    test.equal(agent.keep_alive, "-1")
    test.equal(agent.capabilities.reports_usage, true)
    test.equal(agent.capabilities.stream_responses, true)
    test.equal(agent.capabilities.tool_calling, true)
    test.equal(agent.capabilities.keep_alive, true)
    test.equal(agent.capabilities.local_compact, true)
    test.equal(agent:has_capability("reports_usage"), true)
    test.equal(agent:has_capability("stream_responses"), true)
    test.equal(agent:has_capability("tool_calling"), true)
    test.equal(agent:has_capability("keep_alive"), true)
    test.equal(agent:has_capability("local_compact"), true)
  end)

  test.it("configures keep alive only for capable agents", function()
    local capable = Agent({
      capabilities = {
        keep_alive = true,
        stream_responses = true
      }
    })
    capable:configure({ keep_alive = "1h", stream = true })
    test.equal(capable.keep_alive, "1h")
    test.equal(capable.stream, true)

    local incapable = Agent({
      capabilities = {
        keep_alive = false,
        stream_responses = true
      }
    })
    incapable:configure({ keep_alive = "1h", stream = true })
    test.equal(incapable.keep_alive, nil)
    test.equal(incapable.stream, true)
  end)

  test.it("applies configured capability overrides", function()
    local agent = tools.register_agent_tools(DeepSeek())
    agent_config.apply(agent, {
      stream = false,
      agents = {
        deepseek = {
          capabilities = {
            tool_calling = false
          }
        }
      }
    })

    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    local payload = agent:build_payload(conversation)

    test.equal(agent:has_capability("tool_calling"), false)
    test.equal(agent.model_metadata.stream_tool_calls, false)
    test.equal(payload.tools, nil)
  end)

  test.it("enables streaming capability for compatible agents", function()
    test.equal(Ollama():has_capability("stream_responses"), true)
    test.equal(LlamaCpp():has_capability("stream_responses"), true)
    test.equal(Lms():has_capability("stream_responses"), true)
    test.equal(OpenAI():has_capability("stream_responses"), true)
    test.equal(Codex():has_capability("stream_responses"), true)
  end)

  test.it("enables tool calling capability for openai-compatible agents", function()
    test.equal(Ollama():has_capability("tool_calling"), true)
    test.equal(LlamaCpp():has_capability("tool_calling"), true)
    test.equal(Lms():has_capability("tool_calling"), true)
    test.equal(OpenAI():has_capability("tool_calling"), true)
    test.equal(Codex():has_capability("tool_calling"), false)
  end)

  test.it("enables local compaction for openai-compatible agents", function()
    test.equal(Ollama():has_capability("local_compact"), true)
    test.equal(LlamaCpp():has_capability("local_compact"), true)
    test.equal(Lms():has_capability("local_compact"), true)
    test.equal(OpenAI():has_capability("local_compact"), true)
    test.equal(Codex():has_capability("local_compact"), false)
  end)

  test.it("requires assistant reasoning_content for openai-compatible chat agents", function()
    test.equal(Ollama():has_capability("require_assistant_reasoning_content"), true)
    test.equal(LlamaCpp():has_capability("require_assistant_reasoning_content"), true)
    test.equal(Lms():has_capability("require_assistant_reasoning_content"), true)
    test.equal(DeepSeek():has_capability("require_assistant_reasoning_content"), true)
    test.equal(OpenAI():has_capability("require_assistant_reasoning_content"), false)
    test.equal(Codex():has_capability("require_assistant_reasoning_content"), false)
  end)

  test.it("records model metadata for http agents", function()
    test.equal(Lms().model_metadata.preferred_timeout_ms, 1800000)
    test.equal(LlamaCpp().model_metadata.stream_tool_calls, true)
    test.equal(Ollama().model_metadata.reports_usage, true)
    test.equal(OpenAI().model_metadata.preferred_timeout_ms, 300000)
    test.equal(OpenAI().model_metadata.context_window > 100000, true)
  end)

  test.it("configures deepseek defaults", function()
    local agent = DeepSeek()
    local headers = agent:get_headers()

    test.equal(agent.name, "deepseek")
    test.equal(agent.display_name, "DeepSeek")
    test.equal(agent.backend, "http")
    test.equal(agent.base_url, "https://api.deepseek.com")
    test.equal(agent.endpoint, "/v1/chat/completions")
    test.equal(agent.models_endpoint, "/v1/models")
    test.equal(agent.model, "deepseek-chat")
    test.equal(agent.api_key_env, "DEEPSEEK_API_KEY")
    test.equal(agent.default_reasoning_effort, "low")
    test.equal(agent.model_metadata.context_window, 1048576)
    test.equal(agent.model_metadata.max_output_tokens, 393216)
    test.equal(agent.capabilities.reports_usage, true)
    test.equal(agent.capabilities.stream_responses, true)
    test.equal(agent.capabilities.tool_calling, true)
    test.equal(agent.capabilities.local_compact, true)
    test.equal(agent.capabilities.keep_reasoning_content, false)
    test.equal(agent.capabilities.require_assistant_reasoning_content, true)
    test.equal(headers["Content-Type"], "application/json")
  end)

  test.it("uses default deepseek openai reasoning unless explicitly configured", function()
    local old_reasoning_effort = config.plugins.assistant.reasoning_effort
    local old_persist_reasoning_content = config.plugins.assistant.persist_reasoning_content
    config.plugins.assistant.reasoning_effort = "high"
    config.plugins.assistant.persist_reasoning_content = false

    local agent = DeepSeek()
    local conversation = Conversation(agent, "/tmp")
    conversation:add("user", "hello", { autosave = false })
    local payload = agent:build_payload(conversation)
    local title_payload = agent:build_title_payload("hello")
    local persist = agent:should_persist_reasoning_content()

    config.plugins.assistant.reasoning_effort = old_reasoning_effort
    config.plugins.assistant.persist_reasoning_content = old_persist_reasoning_content

    test.equal(payload.reasoning_effort, "low")
    test.equal(title_payload.reasoning_effort, "low")
    test.equal(persist, true)
  end)

  test.it("builds deepseek openai payloads with explicit reasoning effort", function()
    local agent = DeepSeek({ reasoning_effort = "low" })
    local conversation = Conversation(agent, "/tmp")
    conversation:add("user", "hello", { autosave = false })
    local payload = agent:build_payload(conversation)

    test.equal(payload.reasoning_effort, "low")
    test.equal(agent:should_persist_reasoning_content(), true)
  end)

  test.it("falls back to default deepseek openai reasoning when effort is none", function()
    local old_persist_reasoning_content = config.plugins.assistant.persist_reasoning_content
    config.plugins.assistant.persist_reasoning_content = false

    local agent = DeepSeek({ reasoning_effort = "none" })
    local conversation = Conversation(agent, "/tmp")
    conversation:add("user", "hello", { autosave = false })
    local payload = agent:build_payload(conversation)
    local persist = agent:should_persist_reasoning_content()

    config.plugins.assistant.persist_reasoning_content = old_persist_reasoning_content

    test.equal(payload.reasoning_effort, "low")
    test.equal(persist, true)
  end)

  test.it("supports deepseek openai max reasoning efforts", function()
    local agent = DeepSeek({ reasoning_effort = "xhigh" })
    local conversation = Conversation(agent, "/tmp")
    conversation:add("user", "hello", { autosave = false })
    local payload = agent:build_payload(conversation)

    test.equal(payload.reasoning_effort, "xhigh")
  end)

  test.it("enables deepseek strict tool validation mode", function()
    local agent = tools.register_agent_tools(DeepSeek())
    agent_config.apply(agent, {
      stream = false,
      agents = {
        deepseek = {
          strict_tools = true
        }
      }
    })
    local conversation = Conversation(agent, "/tmp")
    conversation:add("user", "hello", { autosave = false })
    local payload = agent:build_payload(conversation)

    test.equal(agent.base_url, "https://api.deepseek.com/beta")
    test.equal(agent.endpoint, "/chat/completions")
    test.equal(agent.models_endpoint, "/models")
    test.equal(payload.tools[1]["function"].strict, true)
  end)

  test.it("normalizes deepseek strict tool schemas", function()
    local agent = DeepSeek({ strict_tools = true })
    agent:register_tool("sample", {
      callback = function() end,
      params = {
        { name = "required_value", type = "string" },
        { name = "optional_value", type = "string", required = false },
        {
          name = "mode",
          type = "string",
          enum = { "fast", "safe" },
          required = false
        },
        {
          name = "tags",
          type = "array",
          required = false
        },
        {
          name = "headers",
          type = "object",
          required = false
        },
        {
          name = "nested",
          required = false,
          schema = {
            type = "object",
            properties = {
              name = { type = "string" },
              note = { type = "string" }
            },
            required = { "name" }
          }
        }
      }
    })

    local schema = agent:generate_tools_info()[1]["function"].parameters
    test.same(schema.required, { "mode", "nested", "optional_value", "required_value", "tags" })
    test.equal(schema.additionalProperties, false)
    test.equal(schema.properties.headers, nil)
    test.same(schema.properties.optional_value.type, "string")
    test.same(schema.properties.mode.type, "string")
    test.same(schema.properties.mode.enum, { "fast", "safe" })
    test.same(schema.properties.tags.items.type, "string")
    test.same(schema.properties.nested.type, "object")
    test.same(schema.properties.nested.required, { "name", "note" })
    test.equal(schema.properties.nested.additionalProperties, false)
    test.same(schema.properties.nested.properties.note.type, "string")
  end)

  test.it("forces deepseek openai reasoning persistence from config", function()
    local old_persist_reasoning_content = config.plugins.assistant.persist_reasoning_content
    config.plugins.assistant.persist_reasoning_content = true

    local agent = DeepSeek({ reasoning_effort = "none" })
    local persist = agent:should_persist_reasoning_content()

    config.plugins.assistant.persist_reasoning_content = old_persist_reasoning_content

    test.equal(persist, true)
  end)

  test.it("configures deepseek anthropic defaults", function()
    local agent = DeepSeekAnthropic()
    local headers = agent:get_headers()

    test.equal(agent.name, "deepseek_anthropic")
    test.equal(agent.display_name, "DeepSeek Anthropic")
    test.equal(agent.backend, "anthropic")
    test.equal(agent.base_url, "https://api.deepseek.com/anthropic")
    test.equal(agent.endpoint, "/v1/messages")
    test.equal(agent.models_endpoint, "/v1/models")
    test.equal(agent.model, "deepseek-v4-pro")
    test.equal(agent.api_key_env, "DEEPSEEK_API_KEY")
    test.equal(agent.api_format, "anthropic-messages")
    test.equal(agent.stream_format, "anthropic-sse")
    test.equal(agent.default_reasoning_effort, "low")
    test.equal(agent.model_metadata.context_window, 1048576)
    test.equal(agent.model_metadata.max_output_tokens, 393216)
    test.equal(agent.capabilities.reports_usage, true)
    test.equal(agent.capabilities.stream_responses, true)
    test.equal(agent.capabilities.tool_calling, true)
    test.equal(agent.capabilities.local_compact, true)
    test.equal(headers["Content-Type"], "application/json")
    test.equal(headers["anthropic-version"], "2023-06-01")
  end)

  test.it("uses default deepseek anthropic reasoning unless explicitly configured", function()
    local old_reasoning_effort = config.plugins.assistant.reasoning_effort
    config.plugins.assistant.reasoning_effort = "high"

    local agent = DeepSeekAnthropic()
    local conversation = Conversation(agent, "/tmp")
    conversation:add("user", "hello", { autosave = false })
    local payload = agent:build_payload(conversation)

    config.plugins.assistant.reasoning_effort = old_reasoning_effort

    test.equal(payload.model, "deepseek-v4-pro")
    test.equal(payload.thinking.type, "enabled")
    test.equal(payload.thinking.budget_tokens, nil)
    test.equal(payload.output_config.effort, "low")
  end)

  test.it("disables deepseek anthropic thinking for title generation", function()
    local agent = DeepSeekAnthropic()
    local payload = agent:build_title_payload("hello")

    test.equal(payload.thinking.type, "disabled")
    test.equal(payload.output_config, nil)
  end)

  test.it("builds deepseek anthropic payloads with explicit thinking effort", function()
    local agent = DeepSeekAnthropic({ reasoning_effort = "high" })
    local conversation = Conversation(agent, "/tmp")
    conversation:add("user", "hello", { autosave = false })
    local payload = agent:build_payload(conversation)

    test.equal(payload.model, "deepseek-v4-pro")
    test.equal(payload.thinking.type, "enabled")
    test.equal(payload.thinking.budget_tokens, nil)
    test.equal(payload.output_config.effort, "high")
  end)

  test.it("disables deepseek anthropic thinking when explicit reasoning effort is none", function()
    local agent = DeepSeekAnthropic({ reasoning_effort = "none" })
    local conversation = Conversation(agent, "/tmp")
    conversation:add("user", "hello", { autosave = false })
    local payload = agent:build_payload(conversation)

    test.equal(payload.thinking.type, "disabled")
    test.equal(payload.output_config, nil)
  end)

  test.it("parses deepseek anthropic DSML text tool calls", function()
    local agent = DeepSeekAnthropic()
    local calls = agent:parse_tool_calls({
      content = {
        {
          type = "text",
          text = "<｜｜DSML｜｜tool_calls>\n"
            .. "<｜｜DSML｜｜invoke name=\"write\">\n"
            .. "<parameter=path>\n/tmp/demo.txt\n</parameter>\n"
            .. "<parameter=content>\nhello\n</parameter>\n"
            .. "</｜｜DSML｜｜invoke>\n"
            .. "</｜｜DSML｜｜tool_calls>"
        }
      }
    })

    test.equal(#calls, 1)
    test.equal(calls[1].name, "write")
    test.equal(calls[1].arguments.path, "/tmp/demo.txt")
    test.equal(calls[1].arguments.content, "hello")
  end)

  test.it("keeps replayed deepseek anthropic thinking by default", function()
    local agent = DeepSeekAnthropic()
    local conversation = Conversation(agent, "/tmp")
    conversation:add("tool_call", "tool", {
      meta = {
        provider_message = {
          role = "assistant",
          content = {
            { type = "thinking", thinking = "private", signature = "sig" },
            { type = "tool_use", id = "call_1", name = "list", input = {} }
          }
        }
      },
      autosave = false
    })
    conversation:add("tool_result", "result", {
      meta = {
        provider_messages = {
          {
            role = "user",
            content = {
              { type = "tool_result", tool_use_id = "call_1", content = "ok" }
            }
          }
        }
      },
      autosave = false
    })

    local payload = agent:build_payload(conversation)

    test.equal(payload.thinking.type, "enabled")
    test.equal(payload.output_config.effort, "low")
    test.equal(payload.messages[2].content[1].type, "thinking")
  end)

  test.it("strips replayed deepseek anthropic thinking when reasoning is disabled", function()
    local agent = DeepSeekAnthropic({ reasoning_effort = "none" })
    local conversation = Conversation(agent, "/tmp")
    conversation:add("tool_call", "tool", {
      meta = {
        provider_message = {
          role = "assistant",
          content = {
            { type = "thinking", thinking = "private", signature = "sig" },
            { type = "tool_use", id = "call_1", name = "list", input = {} }
          }
        }
      },
      autosave = false
    })
    conversation:add("tool_result", "result", {
      meta = {
        provider_messages = {
          {
            role = "user",
            content = {
              { type = "tool_result", tool_use_id = "call_1", content = "ok" }
            }
          }
        }
      },
      autosave = false
    })

    local payload = agent:build_payload(conversation)

    test.equal(payload.thinking.type, "disabled")
    test.equal(payload.output_config, nil)
    test.equal(payload.messages[2].content[1].type, "tool_use")
  end)

  test.it("parses anthropic usage objects from stream events", function()
    local usage = Anthropic():parse_usage({
      input_tokens = 10,
      output_tokens = 5,
      cache_creation_input_tokens = 2,
      cache_read_input_tokens = 3,
      context = 1000
    })

    test.equal(usage.input_tokens, 10)
    test.equal(usage.output_tokens, 5)
    test.equal(usage.cache_creation_input_tokens, 2)
    test.equal(usage.cache_read_input_tokens, 3)
    test.equal(usage.total_tokens, 20)
    test.equal(usage.context, 1000)
  end)

  test.it("replays native anthropic assistant content only once for multi-tool turns", function()
    local agent = Anthropic()
    local calls = agent:parse_tool_calls({
      content = {
        { type = "thinking", thinking = "private", signature = "sig" },
        { type = "text", text = "checking" },
        { type = "tool_use", id = "call_1", name = "list", input = { directory = "." } },
        { type = "tool_use", id = "call_2", name = "git_status", input = { directory = "." } }
      }
    })

    test.equal(#calls, 2)
    local first = agent:tool_call_provider_message(calls, 1)
    local second = agent:tool_call_provider_message(calls, 2)

    test.not_nil(first)
    test.equal(first.role, "assistant")
    test.equal(#first.content, 4)
    test.equal(first.content[1].type, "thinking")
    test.equal(first.content[3].id, "call_1")
    test.equal(first.content[4].id, "call_2")
    test.equal(second, nil)
  end)

  test.it("merges adjacent native anthropic tool results after multi-tool turns", function()
    local agent = Anthropic()
    local conversation = Conversation(agent, "/tmp")
    conversation:add("user", "hello", { autosave = false })
    conversation:add("tool_call", "list", {
      meta = {
        provider_message = {
          role = "assistant",
          content = {
            { type = "text", text = "checking" },
            { type = "tool_use", id = "call_1", name = "list", input = {} },
            { type = "tool_use", id = "call_2", name = "git_status", input = {} }
          }
        }
      },
      autosave = false
    })
    conversation:add("tool_result", "list result", {
      meta = {
        provider_messages = {
          {
            role = "user",
            content = {
              { type = "tool_result", tool_use_id = "call_1", content = "files" }
            }
          }
        }
      },
      autosave = false
    })
    conversation:add("tool_call", "git_status", { autosave = false })
    conversation:add("tool_result", "git result", {
      meta = {
        provider_messages = {
          {
            role = "user",
            content = {
              { type = "tool_result", tool_use_id = "call_2", content = "clean" }
            }
          }
        }
      },
      autosave = false
    })

    local payload = agent:build_payload(conversation)
    local assistant_index
    for index, message in ipairs(payload.messages) do
      if message.role == "assistant" then
        assistant_index = index
        break
      end
    end

    test.not_nil(assistant_index)
    local assistant_message = payload.messages[assistant_index]
    local result_message = payload.messages[assistant_index + 1]
    test.equal(assistant_message.role, "assistant")
    test.equal(#assistant_message.content, 3)
    test.equal(result_message.role, "user")
    test.equal(#result_message.content, 2)
    test.equal(result_message.content[1].tool_use_id, "call_1")
    test.equal(result_message.content[2].tool_use_id, "call_2")
  end)

  test.it("tracks loading state", function()
    local agent = Ollama()
    test.equal(agent:loading(), false)
    agent:set_loading(true)
    test.equal(agent:loading(), true)
    agent:set_loading(false)
    test.equal(agent:loading(), false)
  end)

  test.it("uses direct api keys in headers", function()
    local agent = Ollama({ api_key = "secret-token" })
    test.equal(agent:get_api_key(), "secret-token")
    test.equal(agent:get_headers().Authorization, "Bearer secret-token")
  end)

  test.it("keeps runtime environment out of role message", function()
    local agent = Agent()
    local message = agent:get_role_message("project")
    test.equal(message:find("You are Pragma, a coding assistant working in the project", 1, true) ~= nil, true)
    test.equal(message:find("Pragtical project", 1, true), nil)
    test.equal(message:find("Runtime environment:", 1, true), nil)
  end)

  test.it("renders runtime environment context messages", function()
    local agent = Agent()
    local message = agent:environment_context_message("project")

    test.equal(message.role, "user")
    test.equal(message.meta.environment_context, true)
    test.equal(message.meta.provider_only, true)
    test.equal(message.content:find("Runtime environment:", 1, true) ~= nil, true)
    test.equal(message.content:find(" - cwd: project", 1, true) ~= nil, true)
    test.equal(message.content:find(" - shell:", 1, true) ~= nil, true)
    test.equal(message.content:find(" - current_date:", 1, true) ~= nil, true)
    test.equal(message.content:find(" - timezone:", 1, true) ~= nil, true)
    test.equal(message.content:find(" - platform: " .. tostring(PLATFORM), 1, true) ~= nil, true)
    test.equal(message.content:find(" - architecture: " .. tostring(ARCH), 1, true) ~= nil, true)
    test.equal(message.content:find(" - path_separator: " .. tostring(PATHSEP), 1, true) ~= nil, true)
    test.not_nil(message.meta.environment_snapshot.hash)
  end)

  test.it("builds layered context fragments for role messages", function()
    local agent = Agent()
    local fragments = agent:build_context_fragments("project", "Follow AGENTS.", {
      { title = "Preference", content = "Use tests." }
    })
    local ids = {}
    for _, fragment in ipairs(fragments) do
      table.insert(ids, fragment.id)
    end

    test.same(ids, { "base", "permissions", "project_instructions" })
    test.equal(fragments[2].content:find("Tool safety:", 1, true) ~= nil, true)
    test.equal(agent:get_role_message("project", "Follow AGENTS.", {
      { title = "Preference", content = "Use tests." }
    }):find("Follow AGENTS.", 1, true) ~= nil, true)
    test.equal(agent:get_role_message("project", "Follow AGENTS.", {
      { title = "Preference", content = "Use tests." }
    }):find("Use tests.", 1, true), nil)
  end)

  test.it("returns callback payloads from successful boolean tool results", function()
    local agent = Agent()
    agent:register_tool("example", {
      callback = function()
        return true, "tool output"
      end,
      params = {}
    })

    local ok, result = agent:execute_tool({ name = "example", arguments = {} })

    test.equal(ok, true)
    test.equal(result, "tool output")
  end)

  test.it("preserves nil slots when passing optional tool arguments", function()
    local agent = Agent()
    local captured = {}
    agent:register_tool("example", {
      callback = function(first, second, third)
        captured = { first = first, second = second, third = third }
        return true, "tool output"
      end,
      params = {
        { name = "first", type = "string" },
        { name = "second", type = "string", optional = true },
        { name = "third", type = "string", optional = true }
      }
    })

    local ok, result = agent:execute_tool({
      name = "example",
      arguments = {
        first = "one",
        third = "three"
      }
    })

    test.equal(ok, true)
    test.equal(result, "tool output")
    test.equal(captured.first, "one")
    test.equal(captured.second, nil)
    test.equal(captured.third, "three")
  end)

  test.it("decodes executable arguments from streamed argument text", function()
    local agent = Agent()
    local captured
    agent:register_tool("apply_patch", {
      callback = function(patch)
        captured = patch
        return true, "applied"
      end,
      params = {
        { name = "patch", type = "string" }
      }
    })

    local ok, result = agent:execute_tool({
      id = "call_1",
      name = "apply_patch",
      arguments = {},
      arguments_text = json.encode({
        patch = "*** Begin Patch\n*** Add File: hello.txt\n+hello\n*** End Patch"
      })
    })

    test.equal(ok, true)
    test.equal(result, "applied")
    test.equal(captured:find("*** Begin Patch", 1, true) ~= nil, true)
  end)

  test.it("uses compact tool results for provider messages", function()
    local old_compact = config.plugins.assistant.compact_tool_results
    config.plugins.assistant.compact_tool_results = true

    local agent = tools.register_agent_tools(Ollama())
    local large = string.rep("0123456789", 6000)
    local message = agent:tool_result_provider_message({
      id = "call_1",
      name = "read",
      arguments = {
        path = "big.txt"
      }
    }, large)

    config.plugins.assistant.compact_tool_results = old_compact
    test.equal(message.content:find("file read: big.txt compacted for provider context", 1, true) ~= nil, true)
    test.equal(message.content:find("hash:", 1, true) ~= nil, true)
    test.equal(#message.content < #large, true)
  end)

  test.it("uses compact tool results for OpenAI response outputs", function()
    local old_compact = config.plugins.assistant.compact_tool_results
    config.plugins.assistant.compact_tool_results = true

    local agent = tools.register_agent_tools(OpenAI())
    local large = string.rep("abcdef", 9000)
    local message = agent:tool_result_provider_message({
      id = "fc_1",
      call_id = "call_1",
      name = "read",
      arguments = {
        path = "big.txt"
      }
    }, large)

    config.plugins.assistant.compact_tool_results = old_compact
    test.equal(message.type, "function_call_output")
    test.equal(message.output:find("file read: big.txt compacted for provider context", 1, true) ~= nil, true)
    test.equal(#message.output < #large, true)
  end)

  test.it("does not map legacy write-file tool aliases", function()
    local agent = Agent({ name = "test" })
    agent:register_tool("apply_patch", {
      callback = function() return "applied" end,
      params = {
        { name = "patch", type = "string" }
      }
    })

    local ok, result = agent:execute_tool({
      name = "write_file",
      arguments = {
        path = "tetris.c",
        file_content = "int main(void) { return 0; }"
      }
    })

    test.equal(ok, false)
    test.equal(result, "unknown tool: write_file")
  end)

  test.it("builds ollama openai-compatible chat payloads", function()
    local old_reasoning_effort = config.plugins.assistant.reasoning_effort
    config.plugins.assistant.reasoning_effort = "low"

    local agent = Ollama({ model = "model-a", keep_alive = "30m" })
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })

    local payload = agent:build_payload(conversation)
    payload.input = without_environment_messages(payload.input)
    config.plugins.assistant.reasoning_effort = old_reasoning_effort

    test.equal(payload.model, "model-a")
    test.equal(payload.keep_alive, "30m")
    test.equal(payload.temperature, agent.options.temperature)
    test.equal(payload.top_p, agent.options.top_p_sampling)
    test.equal(payload.stream_options.include_usage, true)
    test.equal(payload.messages[#payload.messages].role, "user")
    test.equal(payload.messages[#payload.messages].content, "hello")
    test.equal(payload.reasoning_effort, "low")
  end)

  test.it("applies reasoning effort only to opted-in chat agents", function()
    local old_reasoning_effort = config.plugins.assistant.reasoning_effort
    config.plugins.assistant.reasoning_effort = "high"

    local ollama = Ollama({ model = "model-a" })
    local llamacpp = LlamaCpp({ model = "model-a" })
    local ollama_payload = ollama:build_payload(Conversation(ollama, "project"))
    local llamacpp_payload = llamacpp:build_payload(Conversation(llamacpp, "project"))

    config.plugins.assistant.reasoning_effort = old_reasoning_effort
    test.equal(ollama_payload.reasoning_effort, "high")
    test.equal(llamacpp_payload.reasoning_effort, nil)
  end)

  test.it("omits invalid reasoning effort values from chat payloads", function()
    local old_reasoning_effort = config.plugins.assistant.reasoning_effort
    config.plugins.assistant.reasoning_effort = "invalid"

    local agent = Ollama({ model = "model-a" })
    local payload = agent:build_payload(Conversation(agent, "project"))

    config.plugins.assistant.reasoning_effort = old_reasoning_effort
    test.equal(payload.reasoning_effort, nil)
  end)

  test.it("omits max_tokens from chat requests by default", function()
    local agent = LlamaCpp({ model = "model-a" })
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })

    local payload = agent:build_payload(conversation)

    test.equal(payload.max_tokens, nil)
  end)

  test.it("sends configured max_tokens amount when enabled", function()
    local old_send = config.plugins.assistant.send_max_tokens
    local old_amount = config.plugins.assistant.send_max_tokens_amount
    config.plugins.assistant.send_max_tokens = true
    config.plugins.assistant.send_max_tokens_amount = 8192

    local agent = LlamaCpp({ model = "model-a" })
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })

    local payload = agent:build_payload(conversation)

    config.plugins.assistant.send_max_tokens = old_send
    config.plugins.assistant.send_max_tokens_amount = old_amount
    test.equal(payload.max_tokens, 8192)
  end)

  test.it("budgets max_tokens from context when enabled without an amount", function()
    local old_send = config.plugins.assistant.send_max_tokens
    local old_amount = config.plugins.assistant.send_max_tokens_amount
    config.plugins.assistant.send_max_tokens = true
    config.plugins.assistant.send_max_tokens_amount = nil

    local agent = LlamaCpp({ model = "model-a" })
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    conversation:set_usage({
      total_tokens = 15000,
      context = 16384
    })

    local near_limit_payload = agent:build_payload(conversation)

    config.plugins.assistant.send_max_tokens = old_send
    config.plugins.assistant.send_max_tokens_amount = old_amount
    test.equal(near_limit_payload.max_tokens, 128)
  end)

  test.it("scales Anthropic max_tokens from large context", function()
    local old_send = config.plugins.assistant.send_max_tokens
    local old_amount = config.plugins.assistant.send_max_tokens_amount
    config.plugins.assistant.send_max_tokens = false
    config.plugins.assistant.send_max_tokens_amount = nil

    local agent = DeepSeekAnthropic()
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    conversation:set_usage({
      total_tokens = 87157,
      context = 1048576
    })

    local payload = agent:build_payload(conversation)

    config.plugins.assistant.send_max_tokens = old_send
    config.plugins.assistant.send_max_tokens_amount = old_amount
    test.equal(payload.max_tokens, 393216)
  end)

  test.it("caps configured max_tokens to provider output limits", function()
    local old_send = config.plugins.assistant.send_max_tokens
    local old_amount = config.plugins.assistant.send_max_tokens_amount
    config.plugins.assistant.send_max_tokens = true
    config.plugins.assistant.send_max_tokens_amount = 100000

    local agent = Ollama({
      model_metadata = {
        max_output_tokens = 65536
      }
    })
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })

    local payload = agent:build_payload(conversation)

    config.plugins.assistant.send_max_tokens = old_send
    config.plugins.assistant.send_max_tokens_amount = old_amount
    test.equal(payload.max_tokens, 65536)
  end)

  test.it("uses max_output_tokens for OpenAI responses output limits", function()
    local old_send = config.plugins.assistant.send_max_tokens
    local old_amount = config.plugins.assistant.send_max_tokens_amount
    config.plugins.assistant.send_max_tokens = true
    config.plugins.assistant.send_max_tokens_amount = 4096

    local agent = OpenAI({ model = "model-a" })
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    local payload = agent:build_payload(conversation)
    local compact_payload = agent:build_compact_payload(conversation)

    config.plugins.assistant.send_max_tokens = old_send
    config.plugins.assistant.send_max_tokens_amount = old_amount
    test.equal(payload.max_output_tokens, 4096)
    test.equal(payload.max_tokens, nil)
    test.equal(payload.max_completion_tokens, nil)
    test.equal(compact_payload.max_output_tokens, 4096)
  end)

  test.it("uses max_completion_tokens for OpenAI chat output limits", function()
    local old_send = config.plugins.assistant.send_max_tokens
    local old_amount = config.plugins.assistant.send_max_tokens_amount
    config.plugins.assistant.send_max_tokens = true
    config.plugins.assistant.send_max_tokens_amount = 2048

    local agent = OpenAI({ model = "model-a", api_format = "chat" })
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })
    local payload = agent:build_payload(conversation)

    config.plugins.assistant.send_max_tokens = old_send
    config.plugins.assistant.send_max_tokens_amount = old_amount
    test.equal(payload.max_completion_tokens, 2048)
    test.equal(payload.max_tokens, nil)
    test.equal(payload.max_output_tokens, nil)
  end)

  test.it("only sends tool schemas for tool-capable agents", function()
    local agent = Agent({ capabilities = { tool_calling = false } })
    agent:register_tool("read", {
      description = "Read file",
      params = {
        { name = "path", type = "string" }
      }
    })
    local conversation = Conversation(agent, "project")
    local payload = agent:build_payload(conversation)
    test.equal(payload.tools, nil)

    local ollama = Ollama()
    ollama:register_tool("read", {
      description = "Read file",
      params = {
        { name = "path", type = "string" }
      }
    })
    payload = ollama:build_payload(Conversation(ollama, "project"))
    test.equal(payload.tools[1].type, "function")
    test.equal(payload.tools[1]["function"].name, "read")
  end)

  test.it("omits optional tool parameters from required schema fields", function()
    local agent = Agent({ capabilities = { tool_calling = true } })
    agent:register_tool("x", {
      callback = function() end,
      params = {
        { name = "required_value", type = "string" },
        { name = "optional_value", type = "string", required = false }
      }
    })

    local schema = agent:generate_tools_info()[1]["function"].parameters
    test.same(schema.required, { "required_value" })
    test.not_nil(schema.properties.optional_value)
  end)

  test.it("omits required schema field when every tool parameter is optional", function()
    local agent = Agent({ capabilities = { tool_calling = true } })
    agent:register_tool("time", {
      callback = function() end,
      params = {
        { name = "utc_offset", type = "string", required = false }
      }
    })

    local schema = agent:generate_tools_info()[1]["function"].parameters

    test.equal(schema.required, nil)
    test.not_nil(schema.properties.utc_offset)
  end)

  test.it("omits required schema field for optional-only OpenAI tools", function()
    local agent = OpenAI()
    agent:register_tool("time", {
      callback = function() end,
      params = {
        { name = "utc_offset", type = "string", required = false }
      }
    })

    local schema = agent:generate_tools_info()[1].parameters

    test.equal(schema.required, nil)
    test.not_nil(schema.properties.utc_offset)
  end)

  test.it("uses reference-compatible update_plan schema", function()
    local agent = tools.register_agent_tools(Ollama({ stream = false }))
    local tool
    for _, item in ipairs(agent:generate_tools_info() or {}) do
      if item["function"].name == "update_plan" then
        tool = item["function"]
        break
      end
    end

    local schema = tool.parameters
    test.equal(tool.description:find("before the final response", 1, true) ~= nil, true)
    test.same(schema.required, { "plan" })
    test.equal(schema.additionalProperties, false)
    test.not_nil(schema.properties.explanation)
    test.equal(schema.properties.plan.type, "array")
    test.equal(schema.properties.plan.items.additionalProperties, false)
    test.same(schema.properties.plan.items.required, { "step", "status" })
  end)

  test.it("keeps built-in tool schemas aligned with callback defaults", function()
    local agent = tools.register_agent_tools(Ollama({ stream = false }))
    local generated = {}
    for _, item in ipairs(agent:generate_tools_info() or {}) do
      generated[item["function"].name] = item["function"].parameters
    end

    local function required_for(name)
      test.not_nil(generated[name])
      local required = {}
      for _, field in ipairs(generated[name].required or {}) do
        required[field] = true
      end
      return required
    end

    test.same(generated.search.required, { "directory", "text" })
    local search_required = required_for("search")
    test.equal(search_required.search_type, nil)
    test.same(generated.search.properties.search_type.enum, { "plain", "regex", "luapattern" })

    test.same(generated.list.required, { "directory" })
    local list_required = required_for("list")
    test.equal(list_required.recursive, nil)
    test.equal(list_required.max_results, nil)
    test.equal(list_required.pattern, nil)

    test.same(generated.git_diff.required, { "directory" })
    test.equal(required_for("git_diff").pathspec, nil)

    test.same(generated.edit.required, { "path", "edits" })
    test.equal(required_for("edit").oldText, nil)
    test.equal(required_for("edit").newText, nil)
    test.same(generated.edit.properties.edits.items.required, { "oldText", "newText" })

    local prefix_rule = generated.exec_command.properties.prefix_rule
    test.equal(prefix_rule.type, "array")
    test.equal(prefix_rule.items.type, "string")
    test.equal(required_for("exec_command").prefix_rule, nil)
  end)

  test.it("sends compact default tool schemas for web requests", function()
    local agent = tools.register_agent_tools(Ollama({ stream = false }))
    local conversation = Conversation(agent, "project")
    conversation:add("user", "give me information from the web about sdl3", { autosave = false })

    local payload = agent:build_payload(conversation)
    local names = {}
    for _, item in ipairs(payload.tools or {}) do
      names[item["function"].name] = true
    end

    test.equal(names.web_search, true)
    test.equal(names.web_fetch, true)
    test.equal(names.web_find, true)
    test.equal(names.tool_catalog, nil)
    test.equal(names.add_file, nil)
    test.equal(names.apply_patch, nil)
    test.equal(names.edit, true)
    test.equal(names.write, true)
    test.equal(names.exec_command, true)
    test.equal(names.write_stdin, true)
    test.equal(names.update_plan, true)
    test.equal(names.search_memory, true)
    test.equal(names.remember, true)
    test.equal(names.forget, true)
    test.equal(names.run_command, nil)
    test.equal(names.list, true)
    test.equal(#payload.tools <= 22, true)
  end)

  test.it("sends all registered tool schemas for file creation requests", function()
    local agent = tools.register_agent_tools(Ollama({ stream = false }))
    local conversation = Conversation(agent, "project")
    conversation:add("user", "write a tetris game in a file called main.c", { autosave = false })

    local payload = agent:build_payload(conversation)
    local names = {}
    for _, item in ipairs(payload.tools or {}) do
      names[item["function"].name] = true
    end

    test.equal(names.add_file, nil)
    test.equal(names.apply_patch, nil)
    test.equal(names.edit, true)
    test.equal(names.write, true)
    test.equal(names.read, true)
    test.equal(names.tool_catalog, nil)
    test.equal(names.web_search, true)
  end)

  test.it("filters mutating tools and injects instructions in generic plan mode", function()
    local agent = tools.register_agent_tools(Ollama({ stream = false }))
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "plan"
    conversation:add("user", "plan a refactor", { autosave = false })

    local payload = agent:build_payload(conversation)
    local names = {}
    for _, item in ipairs(payload.tools or {}) do
      names[item["function"].name] = true
    end

    test.equal(payload.messages[1].content:find("Collaboration mode: Plan", 1, true) ~= nil, true)
    test.equal(payload.messages[1].content:find("until the host switches", 1, true) ~= nil, true)
    test.equal(payload.messages[1].content:find("Explore first, ask second", 1, true) ~= nil, true)
    test.equal(payload.messages[1].content:find("Markdown plan", 1, true) ~= nil, true)
    test.equal(payload.messages[1].content:find("Plan Drafted!", 1, true) ~= nil, true)
    test.equal(payload.messages[1].content:find("must call implement_plan", 1, true) ~= nil, true)
    test.equal(payload.messages[1].content:find("call implement_plan in the same turn", 1, true) ~= nil, true)
    test.equal(names.read, true)
    test.equal(names.search, true)
    test.equal(names.update_plan, nil)
    test.equal(names.implement_plan, true)
    test.equal(names.ask_user, nil)
    test.equal(names.request_user_input, true)
    test.equal(names.exec_command, true)
    test.equal(names.run_command, nil)
    test.equal(names.apply_patch, nil)
    test.equal(names.add_file, nil)
    test.equal(names.replace_file, nil)
    test.equal(names.file_insert, nil)
    test.equal(names.file_remove, nil)
  end)

  test.it("uses compact coding tools for local implementation mode", function()
    local agent = tools.register_agent_tools(Ollama({ stream = false }))
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "implementation"
    conversation:add("user", "implement the plan", { autosave = false })

    local payload = agent:build_payload(conversation)
    local names = {}
    for _, item in ipairs(payload.tools or {}) do
      names[item["function"].name] = true
    end

    test.equal(payload.messages[1].content:find("Collaboration mode: Implementation", 1, true) ~= nil, true)
    test.equal(payload.messages[1].content:find("Use edit for precise changes", 1, true) ~= nil, true)
    test.equal(names.apply_patch, nil)
    test.equal(names.edit, true)
    test.equal(names.write, true)
    test.equal(names.add_file, nil)
    test.equal(names.file_insert, nil)
    test.equal(names.file_remove, nil)
    test.equal(names.replace_file, nil)
    test.equal(names.exec_command, true)
    test.equal(names.write_stdin, true)
    test.equal(names.update_plan, true)
    test.equal(names.implement_plan, nil)
    test.equal(names.run_command, nil)
    test.equal(names.read, true)
    test.equal(names.web_search, true)
    test.equal(names.tool_catalog, nil)
  end)

  test.it("uses compact coding tools in generic implementation mode", function()
    local agent = tools.register_agent_tools(Agent({
      capabilities = {
        tool_calling = true,
        stream_responses = true,
        collaboration_modes = true
      }
    }))
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "implementation"
    conversation:add("user", "implement the plan", { autosave = false })

    local payload = agent:build_payload(conversation)
    local names = {}
    for _, item in ipairs(payload.tools or {}) do
      names[item["function"].name] = true
    end

    test.equal(names.apply_patch, nil)
    test.equal(names.edit, true)
    test.equal(names.write, true)
    test.equal(names.add_file, nil)
    test.equal(names.exec_command, true)
    test.equal(names.write_stdin, true)
    test.equal(names.run_command, nil)
    test.equal(names.read, true)
    test.equal(names.web_search, true)
    test.equal(names.tool_catalog, nil)
  end)

  test.it("parses chat completions responses", function()
    local agent = Ollama()
    local text = agent:parse_response({
      choices = {
        { message = { content = "done" } }
      }
    })
    test.equal(text, "done")
  end)

  test.it("parses text-encoded tool calls from local models", function()
    local agent = Ollama()
    local calls = agent:parse_tool_calls({
      choices = {
        {
          message = {
            content = "<function=search>\n<parameter=directory>\nproject\n</parameter>\n<parameter=search_type>\nplain\n</parameter>\n<parameter=text>\n.\n</parameter>\n</function>\n</tool_call>"
          }
        }
      }
    })

    test.equal(#calls, 1)
    test.equal(calls[1].name, "search")
    test.equal(calls[1].arguments.directory, "project")
    test.equal(calls[1].arguments.search_type, "plain")
    test.equal(calls[1].arguments.text, ".")
    test.equal(calls[1].raw["function"].name, "search")
  end)

  test.it("parses text-encoded tool calls with wrapper and spaced tags", function()
    local agent = Ollama()
    local calls = agent:parse_tool_calls({
      choices = {
        {
          message = {
            content = "<tool_call>\n<function = \"search\">\n<parameter = \"directory\">\n/project\n</parameter>\n<parameter = \"search_type\">\nplain\n</parameter>\n<parameter = \"text\">\n.\n</parameter>\n</function>\n</tool_call>"
          }
        }
      }
    })

    test.equal(#calls, 1)
    test.equal(calls[1].name, "search")
    test.equal(calls[1].arguments.directory, "/project")
    test.equal(calls[1].arguments.search_type, "plain")
    test.equal(calls[1].arguments.text, ".")
  end)

  test.it("parses escaped invoke tool calls from local models", function()
    local agent = Ollama()
    local calls = agent:parse_tool_calls({
      choices = {
        {
          message = {
            content = table.concat({
              "&lt;function_calls&gt;",
              "&lt;invoke name=\"apply_patch\"&gt;",
              "&lt;parameter name=\"patch\"&gt;*** Begin Patch\n*** Add File: tetris.c\n+#include &amp;lt;SDL2/SDL.h&amp;gt;\n*** End Patch&lt;/parameter&gt;",
              "&lt;/invoke&gt;",
              "&lt;/function_calls&gt;"
            }, "\n")
          }
        }
      }
    })

    test.equal(#calls, 1)
    test.equal(calls[1].name, "apply_patch")
    test.equal(calls[1].arguments.patch:find("#include <SDL2/SDL.h>", 1, true) ~= nil, true)
  end)

  test.it("parses openai-compatible token usage", function()
    local agent = OpenAI()
    local usage = agent:parse_usage({
      usage = {
        prompt_tokens = 10,
        completion_tokens = 5,
        total_tokens = 15,
        model_context_window = 1000
      },
      modelContextWindow = 2000
    })

    test.equal(usage.input_tokens, 10)
    test.equal(usage.output_tokens, 5)
    test.equal(usage.total_tokens, 15)
    test.equal(usage.context, 1000)
  end)

  test.it("parses stream delta events", function()
    local agent = Ollama()
    local text, done = agent:parse_stream_event('{"message":{"content":"x"},"done":false}')
    test.equal(text, "x")
    test.equal(done, false)
  end)

  test.it("parses ollama native usage", function()
    local agent = Ollama()
    local usage = agent:parse_usage({
      prompt_eval_count = 8,
      eval_count = 3,
      model_info = {
        ["llama.context_length"] = 4096
      }
    })

    test.equal(usage.input_tokens, 8)
    test.equal(usage.output_tokens, 3)
    test.equal(usage.total_tokens, 11)
    test.equal(usage.context, 4096)
  end)

  test.it("parses ollama show metadata for allocated context", function()
    local agent = Ollama()
    local metadata = agent:parse_model_metadata({
      parameters = "temperature 0.7\nnum_ctx 32768",
      model_info = {
        ["qwen3.context_length"] = 262144
      }
    })

    test.equal(metadata.context_window, 32768)
    test.equal(metadata.allocated_context_window, 32768)
    test.equal(metadata.model_context_window, 262144)
  end)

  test.it("parses ollama native model list responses", function()
    local agent = Ollama()
    local models = agent:parse_models_response({
      models = {
        { name = "b" },
        { name = "a" }
      }
    })
    test.same(models, { "a", "b" })
  end)

  test.it("parses ollama openai-compatible model list responses", function()
    local agent = Ollama()
    local models = agent:parse_models_response({
      data = {
        { id = "model-b" },
        { id = "model-a" }
      }
    })
    test.same(models, { "model-a", "model-b" })
  end)

  test.it("parses openai-compatible model list responses", function()
    local Agent = require "plugins.assistant.agent"
    local agent = Agent({ name = "openai", model = "x" })
    local models = agent:parse_models_response({
      data = {
        { id = "model-b" },
        { id = "model-a" }
      }
    })
    test.same(models, { "model-a", "model-b" })
  end)

  test.it("configures llama.cpp defaults", function()
    local agent = LlamaCpp()
    test.equal(agent.base_url, "http://127.0.0.1:8080")
    test.equal(agent.endpoint, "/v1/chat/completions")
    test.equal(agent.models_endpoint, "/v1/models")
    test.equal(agent.model, "local-model")
    test.equal(agent.capabilities.reports_usage, true)
    test.equal(agent.capabilities.stream_responses, true)
    test.equal(agent.capabilities.tool_calling, true)
    test.equal(agent.capabilities.local_compact, true)
  end)

  test.it("configures lm studio defaults", function()
    local agent = Lms()
    test.equal(agent.base_url, "http://127.0.0.1:1234")
    test.equal(agent.endpoint, "/v1/chat/completions")
    test.equal(agent.models_endpoint, "/v1/models")
    test.equal(agent.model, "local-model")
    test.equal(agent.capabilities.reports_usage, true)
    test.equal(agent.capabilities.stream_responses, true)
    test.equal(agent.capabilities.tool_calling, true)
    test.equal(agent.capabilities.local_compact, true)
  end)

  test.it("configures openai defaults", function()
    local agent = OpenAI()
    test.equal(agent.base_url, "https://api.openai.com")
    test.equal(agent.endpoint, "/v1/responses")
    test.equal(agent.api_format, "responses")
    test.equal(agent.models_endpoint, "/v1/models")
    test.equal(agent.api_key_env, "OPENAI_API_KEY")
    test.equal(agent.capabilities.reports_usage, true)
    test.equal(agent.capabilities.stream_responses, true)
    test.equal(agent.capabilities.tool_calling, true)
    test.equal(agent.capabilities.local_compact, true)
    test.equal(agent:has_capability("reports_usage"), true)
  end)

  test.it("builds openai responses payloads", function()
    local old_reasoning_effort = config.plugins.assistant.reasoning_effort
    config.plugins.assistant.reasoning_effort = "low"

    local agent = OpenAI({ model = "model-a" })
    local conversation = Conversation(agent, "project")
    conversation:add("user", "hello", { autosave = false })

    local payload = agent:build_payload(conversation)
    config.plugins.assistant.reasoning_effort = old_reasoning_effort

    test.equal(payload.model, "model-a")
    test.equal(payload.messages, nil)
    test.equal(payload.input[#payload.input].role, "user")
    test.equal(payload.input[#payload.input].content, "hello")
    test.equal(type(payload.instructions), "string")
    test.equal(payload.reasoning.effort, "low")
  end)

  test.it("builds openai responses payloads with configured reasoning effort", function()
    local old_reasoning_effort = config.plugins.assistant.reasoning_effort
    config.plugins.assistant.reasoning_effort = "none"

    local agent = OpenAI({ model = "model-a" })
    local conversation = Conversation(agent, "project")
    local payload = agent:build_payload(conversation)

    config.plugins.assistant.reasoning_effort = "medium"
    local medium_payload = agent:build_payload(conversation)
    config.plugins.assistant.reasoning_effort = "high"
    local compact_payload = agent:build_compact_payload(conversation)
    config.plugins.assistant.reasoning_effort = old_reasoning_effort

    test.equal(payload.reasoning.effort, "none")
    test.equal(medium_payload.reasoning.effort, "medium")
    test.equal(compact_payload.reasoning.effort, "high")
  end)

  test.it("omits invalid reasoning effort values from openai responses payloads", function()
    local old_reasoning_effort = config.plugins.assistant.reasoning_effort
    config.plugins.assistant.reasoning_effort = ""

    local agent = OpenAI({ model = "model-a" })
    local conversation = Conversation(agent, "project")
    local empty_payload = agent:build_payload(conversation)

    config.plugins.assistant.reasoning_effort = "invalid"
    local invalid_payload = agent:build_compact_payload(conversation)
    config.plugins.assistant.reasoning_effort = old_reasoning_effort

    test.equal(empty_payload.reasoning, nil)
    test.equal(invalid_payload.reasoning, nil)
  end)

  test.it("repairs missing OpenAI responses tool outputs before provider requests", function()
    local agent = OpenAI({ model = "model-a" })
    local conversation = Conversation(agent, "project")
    conversation:add("tool_call", "", {
      autosave = false,
      meta = {
        provider_message = {
          type = "function_call",
          id = "fc_1",
          call_id = "call_1",
          name = "read",
          arguments = '{"path":"project/main.c"}'
        }
      }
    })

    local payload = agent:build_payload(conversation)
    local function_call
    local function_output
    for _, item in ipairs(payload.input) do
      if item.type == "function_call" then function_call = item end
      if item.type == "function_call_output" then function_output = item end
    end

    test.equal(function_call.type, "function_call")
    test.equal(function_output.type, "function_call_output")
    test.equal(function_output.call_id, "call_1")
    test.equal(function_output.output:find("aborted", 1, true) ~= nil, true)
  end)

  test.it("filters tools and injects instructions for OpenAI plan mode", function()
    local agent = tools.register_agent_tools(OpenAI({ model = "model-a" }))
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "plan"
    conversation:add("user", "plan this", { autosave = false })

    local payload = agent:build_payload(conversation)
    local names = {}
    for _, item in ipairs(payload.tools or {}) do
      names[item.name] = true
    end

    test.equal(payload.instructions:find("Collaboration mode: Plan", 1, true) ~= nil, true)
    test.equal(payload.instructions:find("until the host switches", 1, true) ~= nil, true)
    test.equal(payload.instructions:find("Explore first, ask second", 1, true) ~= nil, true)
    test.equal(payload.instructions:find("call implement_plan in the same turn", 1, true) ~= nil, true)
    test.equal(names.read, true)
    test.equal(names.update_plan, nil)
    test.equal(names.implement_plan, true)
    test.equal(names.exec_command, true)
    test.equal(names.run_command, nil)
    test.equal(names.apply_patch, nil)
    test.equal(names.add_file, nil)
  end)

  test.it("advertises apply_patch instead of edit and write for gpt models", function()
    local agent = tools.register_agent_tools(OpenAI({ model = "gpt-4.1" }))
    local conversation = Conversation(agent, "project")
    conversation.collaboration_mode = "implementation"
    conversation:add("user", "implement this", { autosave = false })

    local payload = agent:build_payload(conversation)
    local names = {}
    for _, item in ipairs(payload.tools or {}) do
      names[item.name or item["function"].name] = true
    end

    test.equal(payload.instructions:find("Use apply_patch for file creation", 1, true) ~= nil, true)
    test.equal(names.apply_patch, true)
    test.equal(names.edit, nil)
    test.equal(names.write, nil)
    test.equal(names.read, true)
  end)

  test.it("parses openai responses output", function()
    local agent = OpenAI()
    local text = agent:parse_response({
      output = {
        {
          type = "message",
          content = {
            { type = "output_text", text = "done" }
          }
        }
      }
    })

    test.equal(text, "done")
  end)

  test.it("parses openai responses stream events", function()
    local agent = OpenAI()
    local text, done = agent:parse_stream_event(
      '{"type":"response.output_text.delta","delta":"x"}'
    )
    test.equal(text, "x")
    test.equal(done, false)

    local _, completed = agent:parse_stream_event('{"type":"response.completed","response":{"usage":{"input_tokens":2,"output_tokens":3}}}')
    test.equal(completed, true)
  end)

  test.it("supports streamed tool calls for openai responses", function()
    local agent = OpenAI()
    test.equal(agent:supports_stream_tool_calls(), true)
  end)

  test.it("parses openai responses streamed function-call items", function()
    local agent = OpenAI()
    local deltas = agent:parse_stream_tool_call_deltas(json.encode({
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

    test.equal(#deltas, 1)
    test.equal(deltas[1].index, 0)
    test.equal(deltas[1].id, "fc_1")
    test.equal(deltas[1].call_id, "call_1")
    test.equal(deltas[1].name, "lookup")
    test.equal(deltas[1].format, "responses")
  end)

  test.it("parses openai responses streamed function-call arguments", function()
    local agent = OpenAI()
    local deltas = agent:parse_stream_tool_call_deltas(json.encode({
      type = "response.function_call_arguments.delta",
      output_index = 0,
      item_id = "fc_1",
      delta = "{\"query\":\""
    }))
    test.equal(deltas[1].arguments, "{\"query\":\"")

    deltas = agent:parse_stream_tool_call_deltas(json.encode({
      type = "response.function_call_arguments.done",
      output_index = 0,
      item_id = "fc_1",
      arguments = "{\"query\":\"x\"}"
    }))
    test.equal(deltas[1].final_arguments, "{\"query\":\"x\"}")
  end)

  test.it("ignores openai responses lifecycle stream events", function()
    local agent = OpenAI()
    local text, done = agent:parse_stream_event(
      '{"type":"response.created","response":{"id":"resp_1"}}'
    )

    test.equal(text, nil)
    test.equal(done, false)
  end)

  test.it("configures codex app-server defaults", function()
    local agent = Codex()
    test.equal(agent.backend, "appserver")
    test.equal(agent.command, "codex")
    test.equal(agent.sandbox, "workspace-write")
    test.equal(agent:appserver_sandbox(), "workspace-write")
    test.equal(agent.capabilities.reports_usage, true)
    test.equal(agent.capabilities.reports_context, true)
    test.equal(agent.capabilities.compact, true)
    test.equal(agent.capabilities.local_compact, false)
    test.equal(agent.capabilities.delete_conversation, false)
    test.equal(agent.capabilities.list_conversations, false)
    test.equal(agent.capabilities.rename_conversation, true)
    test.equal(agent.capabilities.collaboration_modes, true)
    test.equal(agent.capabilities.user_input_requests, true)
    test.equal(agent.capabilities.approval_requests, true)
    test.equal(agent.capabilities.stream_responses, true)
    test.equal(agent.approval_policy.granular.request_permissions, true)
    test.equal(agent.approval_policy.granular.sandbox_approval, true)
    test.equal(agent:has_capability("compact"), true)
  end)

  test.it("parses ACP token usage updates", function()
    local agent = Acp()
    local usage = agent:parse_usage({
      tokenUsage = {
        modelContextWindow = 258400,
        total = {
          inputTokens = 900000,
          outputTokens = 10000,
          totalTokens = 910000
        },
        last = {
          inputTokens = 30000,
          outputTokens = 1000,
          totalTokens = 31000
        }
      }
    })
    local conversation = Conversation({ agent = "acp" })
    conversation:set_usage(usage)

    test.equal(usage.total_tokens, 31000)
    test.equal(usage.cumulative_total_tokens, 910000)
    test.equal(conversation:context_left(), 227400)
  end)

  test.it("normalizes codex user input requests", function()
    local agent = Codex()
    local request = agent:normalize_user_input_request({
      id = 9,
      method = "item/tool/requestUserInput",
      params = {
        itemId = "item_1",
        threadId = "thr_1",
        turnId = "turn_1",
        questions = {
          {
            id = "choice",
            header = "Decision",
            question = "Proceed?",
            options = {
              { label = "Yes", value = "Y", description = "Continue" },
              { label = "No", value = "N", description = "Stop" }
            }
          }
        }
      }
    })

    test.equal(request.provider_id, 9)
    test.equal(request.questions[1].id, "choice")
    test.equal(request.questions[1].question, "Proceed?")
    test.equal(request.questions[1].options[1].label, "Yes")
    test.equal(request.questions[1].options[1].value, "Y")

    local response = agent:format_user_input_response(request, true, { choice = "Yes" })
    test.same(response, {
      answers = {
        choice = {
          answers = { "Yes" }
        }
      }
    })
  end)

  test.it("normalizes codex user input option values", function()
    local agent = Codex()
    local request = agent:normalize_user_input_request({
      id = 10,
      method = "item/tool/requestUserInput",
      params = {
        itemId = "item_2",
        threadId = "thr_1",
        turnId = "turn_1",
        questions = {
          {
            id = "choice",
            header = "Pick",
            options = {
              { id = "a", value = "opt-a", label = "Option A" },
              "Option B"
            }
          }
        }
      }
    })

    test.equal(request.questions[1].options[1].value, "opt-a")
    test.equal(request.questions[1].options[2].value, "Option B")
  end)

  test.it("normalizes codex approval requests", function()
    local agent = Codex()
    local request = agent:normalize_approval_request({
      id = 12,
      method = "item/commandExecution/requestApproval",
      params = {
        itemId = "item_1",
        threadId = "thr_1",
        turnId = "turn_1",
        command = "make test",
        cwd = "project",
        reason = "Need to verify changes"
      }
    })

    test.equal(request.provider_id, 12)
    test.equal(request.kind, "command")
    test.equal(request.body:find("make test", 1, true) ~= nil, true)
    test.same(agent:format_approval_response(request, "accept"), {
      decision = "accept"
    })
  end)

  test.it("formats codex permission approval responses", function()
    local agent = Codex()
    local request = agent:normalize_approval_request({
      id = 13,
      method = "item/permissions/requestApproval",
      params = {
        itemId = "item_1",
        threadId = "thr_1",
        turnId = "turn_1",
        cwd = "project",
        permissions = {
          network = { enabled = true }
        }
      }
    })

    test.equal(request.kind, "permissions")
    test.same(agent:format_approval_response(request, "acceptForSession"), {
      permissions = {
        network = { enabled = true }
      },
      scope = "session"
    })
    test.same(agent:format_approval_response(request, "decline"), {
      permissions = {},
      scope = "turn"
    })
  end)

  test.it("normalizes codex collaboration mode strings", function()
    local agent = Codex()
    agent.collaboration_modes_by_id = {
      plan = { id = "plan", mode = "plan", label = "Plan" }
    }
    local default_mode = agent:build_collaboration_mode("implementation")
    local plan_mode = agent:build_collaboration_mode("plan")
    test.equal(default_mode.mode, "default")
    test.equal(plan_mode.mode, "plan")
  end)

  test.it("uses explicit codex model over collaboration mode defaults", function()
    local agent = Codex({ model = "gpt-5.5" })
    agent.collaboration_modes_by_id = {
      plan = { id = "plan", mode = "plan", label = "Plan", model = "gpt-5.3-codex" }
    }

    local plan_mode = agent:build_collaboration_mode("plan")

    test.equal(plan_mode.mode, "plan")
    test.equal(plan_mode.settings.model, "gpt-5.5")
  end)

  test.it("maps configured reasoning effort for codex app-server", function()
    local old_reasoning_effort = config.plugins.assistant.reasoning_effort
    local agent = Codex()

    config.plugins.assistant.reasoning_effort = "none"
    test.equal(agent:configured_appserver_reasoning_effort(), "minimal")
    config.plugins.assistant.reasoning_effort = "low"
    test.equal(agent:configured_appserver_reasoning_effort(), "low")
    config.plugins.assistant.reasoning_effort = "medium"
    test.equal(agent:configured_appserver_reasoning_effort(), "medium")
    config.plugins.assistant.reasoning_effort = "high"
    test.equal(agent:configured_appserver_reasoning_effort(), "high")
    config.plugins.assistant.reasoning_effort = "invalid"
    test.equal(agent:configured_appserver_reasoning_effort(), nil)

    config.plugins.assistant.reasoning_effort = old_reasoning_effort
  end)

  test.it("applies configured codex reasoning to collaboration modes without overrides", function()
    local old_reasoning_effort = config.plugins.assistant.reasoning_effort
    config.plugins.assistant.reasoning_effort = "low"
    local agent = Codex()
    agent.collaboration_modes_by_id = {
      plan = { id = "plan", mode = "plan", label = "Plan" },
      review = {
        id = "review",
        mode = "default",
        label = "Review",
        reasoning_effort = "medium"
      }
    }

    local plan_mode = agent:build_collaboration_mode("plan")
    local review_mode = agent:build_collaboration_mode("review")
    config.plugins.assistant.reasoning_effort = old_reasoning_effort

    test.equal(plan_mode.settings.reasoning_effort, "low")
    test.equal(review_mode.settings.reasoning_effort, "medium")
  end)

  test.it("parses codex app-server context usage", function()
    local agent = Codex()
    local usage = agent:parse_usage({
      tokenUsage = {
        modelContextWindow = 1000,
        last = {
          inputTokens = 10,
          outputTokens = 5,
          totalTokens = 15
        },
        total = {
          inputTokens = 200,
          outputTokens = 50,
          totalTokens = 250
        }
      }
    })

    test.equal(usage.total_tokens, 15)
    test.equal(usage.cumulative_total_tokens, 250)
    test.equal(usage.context, 1000)
  end)

  test.it("uses codex last-turn usage for context left", function()
    local agent = Codex()
    local usage = agent:parse_usage({
      tokenUsage = {
        modelContextWindow = 258400,
        total = {
          inputTokens = 1037578,
          outputTokens = 19477,
          totalTokens = 1057055
        },
        last = {
          inputTokens = 40431,
          outputTokens = 627,
          totalTokens = 41058
        }
      }
    })
    local conversation = Conversation({ agent = "codex" })
    conversation:set_usage(usage)

    test.equal(usage.total_tokens, 41058)
    test.equal(usage.cumulative_total_tokens, 1057055)
    test.equal(conversation:context_left(), 217342)
  end)
end)
