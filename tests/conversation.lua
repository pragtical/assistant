local test = require "core.test"
dofile("tests/helper.inc")
local common = require "core.common"
local config = require "core.config"
local Conversation = require "plugins.assistant.conversation"
local Ollama = require "plugins.assistant.agent.ollama"

local root = assistant_test_temp_path("conversation")

local function mkdirp(path)
  local info = system.get_file_info(path)
  if info and info.type == "dir" then return end
  common.mkdirp(path)
end

local function write(path, text)
  local fp = assert(io.open(path, "wb"))
  fp:write(text)
  fp:close()
end

test.describe("assistant conversation", function()
  local old_log_raw_messages
  local old_verbose_tool_calling
  local old_verbose_activity

  test.before_each(function()
    old_log_raw_messages = config.plugins.assistant.log_raw_messages
    old_verbose_tool_calling = config.plugins.assistant.verbose_tool_calling
    old_verbose_activity = config.plugins.assistant.verbose_activity
    config.plugins.assistant.log_raw_messages = true
    config.plugins.assistant.verbose_tool_calling = false
    config.plugins.assistant.verbose_activity = false
    common.rm(root, true)
    mkdirp(root)
  end)

  test.after_each(function()
    config.plugins.assistant.log_raw_messages = old_log_raw_messages
    config.plugins.assistant.verbose_tool_calling = old_verbose_tool_calling
    config.plugins.assistant.verbose_activity = old_verbose_activity
  end)

  test.it("starts with coding assistant project context", function()
    write(root .. PATHSEP .. "AGENTS.md", "Use local project rules.")
    Conversation.add_memory(root, "Rule", "Prefer small patches.")

    local agent = Ollama()
    local conversation = Conversation(agent, root)

    test.equal(conversation.messages[1].role, "system")
    test.equal(conversation.messages[2].role, "user")
    test.equal(conversation.messages[2].meta.environment_context, true)
    test.equal(conversation.messages[2].meta.provider_only, true)
    test.equal(conversation.messages[1].message:find("coding assistant", 1, true) ~= nil, true)
    test.equal(conversation.messages[1].message:find("Runtime environment:", 1, true), nil)
    test.equal(conversation.messages[2].message:find("Runtime environment:", 1, true) ~= nil, true)
    test.equal(conversation.messages[2].message:find(" - cwd: " .. root, 1, true) ~= nil, true)
    test.equal(conversation.messages[1].message:find("Use local project rules.", 1, true) ~= nil, true)
    test.equal(conversation.messages[1].message:find("Prefer small patches.", 1, true) ~= nil, true)
    test.not_nil(conversation.context_snapshot)
    test.not_nil(conversation.environment_context)
    test.equal(conversation.context_snapshot.fragments[1].id, "base")
  end)

  test.it("updates memory content without changing its id", function()
    local item = Conversation.add_memory(root, "Old Rule", "Prefer old patches.")

    local updated = Conversation.update_memory(root, item.id, "New Rule", "Prefer focused patches.")
    local memories = Conversation.list_memories(root)

    test.equal(updated.id, item.id)
    test.equal(updated.title, "New Rule")
    test.equal(updated.content, "Prefer focused patches.")
    test.equal(memories[1].id, item.id)
    test.equal(memories[1].title, "New Rule")
    test.equal(memories[1].content, "Prefer focused patches.")
  end)

  test.it("sends hidden environment context to providers before user prompts", function()
    local agent = Ollama()
    local conversation = Conversation(agent, root)
    conversation:add("user", "hello", { autosave = false })

    local markdown = conversation:to_markdown()
    local messages = conversation:to_provider_messages()

    test.equal(markdown:find("Runtime environment:", 1, true), nil)
    test.equal(messages[1].role, "system")
    test.equal(messages[2].role, "user")
    test.equal(messages[2].content:find("Runtime environment:", 1, true) ~= nil, true)
    test.equal(messages[3].role, "user")
    test.equal(messages[3].content, "hello")
  end)

  test.it("does not duplicate unchanged environment context", function()
    local agent = Ollama()
    local conversation = Conversation(agent, root)
    local count = #conversation.messages

    test.equal(conversation:refresh_environment_context(agent), false)
    test.equal(#conversation.messages, count)
  end)

  test.it("appends changed environment context before the active user prompt", function()
    local agent = Ollama()
    local first_snapshot = agent.environment_context_snapshot
    local calls = 0
    agent.environment_context_snapshot = function(this, project_dir)
      calls = calls + 1
      local snapshot = first_snapshot(this, project_dir)
      if calls > 1 then
        snapshot.current_date = "2099-01-01"
        snapshot.hash = snapshot.hash .. ":changed"
      end
      return snapshot
    end
    local conversation = Conversation(agent, root)
    conversation:add("user", "hello", { autosave = false })

    test.equal(conversation:refresh_environment_context(agent), true)

    local messages = conversation:to_provider_messages()
    test.equal(messages[#messages - 1].content:find("2099-01-01", 1, true) ~= nil, true)
    test.equal(messages[#messages].content, "hello")
    test.equal(conversation.environment_context.current_date, "2099-01-01")
  end)

  test.it("refreshes project context when AGENTS.md changes before provider requests", function()
    write(root .. PATHSEP .. "AGENTS.md", "Initial rule.")
    local agent = Ollama()
    local conversation = Conversation(agent, root)
    local first_snapshot = conversation.context_snapshot

    write(root .. PATHSEP .. "AGENTS.md", "Updated rule.")
    local payload = agent:build_payload(conversation)

    test.equal(payload.messages[1].content:find("Updated rule.", 1, true) ~= nil, true)
    test.equal(conversation.messages[1].message:find("Updated rule.", 1, true) ~= nil, true)
    test.equal(conversation.context_snapshot.fragments[3].hash ~= first_snapshot.fragments[3].hash, true)
  end)

  test.it("does not refresh unchanged project context", function()
    write(root .. PATHSEP .. "AGENTS.md", "Stable rule.")
    local agent = Ollama()
    local conversation = Conversation(agent, root)
    local updated_at = conversation.updated_at

    test.equal(conversation:refresh_context(agent), false)
    test.equal(conversation.updated_at, updated_at)
  end)

  test.it("saves, lists, loads, and deletes project-local sessions", function()
    local conversation = Conversation(Ollama(), root)
    conversation:add("user", "hello")
    conversation.title = "Saved Session"
    test.equal(conversation:save(), true)

    local list = Conversation.list(root)
    test.equal(#list, 1)
    test.equal(list[1].title, "Saved Session")

    local loaded = Conversation.load(conversation.id, root)
    test.not_nil(loaded)
    test.equal(loaded.messages[3].message, "hello")
    test.not_nil(loaded.environment_context)

    conversation.collaboration_mode = "plan"
    conversation:approve_command_prefix("make test")
    conversation:approve_tool("apply_patch")
    conversation:save()
    loaded = Conversation.load(conversation.id, root)
    test.equal(loaded.collaboration_mode, "plan")
    test.not_nil(loaded.context_snapshot)
    test.equal(loaded:command_prefix_approved("make test VERBOSE=1"), true)
    test.equal(loaded:tool_approved("apply_patch"), true)
    test.equal(loaded:tool_approved("exec_command"), false)

    test.equal(Conversation.delete(conversation.id, root), true)
    test.equal(#Conversation.list(root), 0)
  end)

  test.it("stores raw responses beside the session", function()
    local conversation = Conversation(Ollama(), root)
    test.equal(conversation:append_raw_response("event", { text = "raw" }), true)

    local text = conversation:raw_responses_text()
    test.equal(text:find('"kind":"event"', 1, true) ~= nil, true)
    test.equal(text:find('"text":"raw"', 1, true) ~= nil, true)

    conversation:save()
    test.equal(system.get_file_info(Conversation.raw_responses_path(root, conversation.id)) ~= nil, true)
    test.equal(Conversation.delete(conversation.id, root), true)
    test.equal(system.get_file_info(Conversation.raw_responses_path(root, conversation.id)), nil)
  end)

  test.it("renders apply_patch tool calls as diffs instead of raw JSON", function()
    config.plugins.assistant.verbose_tool_calling = true
    local conversation = Conversation(Ollama(), root)
    conversation:add("tool_call", "Tool: apply_patch", {
      autosave = false,
      meta = {
        call = {
          name = "apply_patch",
          arguments = {
            patch = "*** Begin Patch\n*** Add File: main.c\n+int main() {}\n*** End Patch"
          }
        }
      }
    })

    local markdown = conversation:message_to_markdown(conversation.messages[#conversation.messages])
    test.equal(markdown:find("```diff", 1, true) ~= nil, true)
    test.equal(markdown:find("*** Add File: main.c", 1, true) ~= nil, true)
    test.equal(markdown:find("+int main() {}", 1, true) ~= nil, true)
    test.equal(markdown:find('"patch"', 1, true), nil)
  end)

  test.it("skips raw response storage when raw logging is disabled", function()
    config.plugins.assistant.log_raw_messages = false
    local conversation = Conversation(Ollama(), root)

    test.equal(conversation:append_raw_response("event", { text = "raw" }), false)
    test.equal(conversation:raw_responses_text(), "")
    test.equal(system.get_file_info(Conversation.raw_responses_path(root, conversation.id)), nil)
  end)

  test.it("renders non-system messages as markdown", function()
    local conversation = Conversation(Ollama(), root)
    conversation:add("user", "Question")
    conversation:add("assistant", "Answer")

    local md = conversation:to_markdown()
    test.equal(md:find("## User", 1, true) ~= nil, true)
    test.equal(md:find("## Assistant", 1, true) ~= nil, true)
  end)

  test.it("renders activity messages but keeps them out of provider context", function()
    local conversation = Conversation(Ollama(), root)
    conversation:add("user", "Question", { autosave = false })
    conversation:add("activity", "Thinking: checking files", { autosave = false })

    local md = conversation:to_markdown()
    local messages = conversation:to_provider_messages()

    test.equal(md:find("## Activity", 1, true), nil)
    test.equal(md:find("**Thinking**: checking files", 1, true) ~= nil, true)
    test.equal(messages[#messages].role, "user")
  end)

  test.it("renders verbose activity messages when configured", function()
    config.plugins.assistant.verbose_activity = true
    local conversation = Conversation(Ollama(), root)
    conversation:add("activity", "Thinking: checking files", { autosave = false })

    local md = conversation:to_markdown()
    test.equal(md:find("## Activity", 1, true) ~= nil, true)
    test.equal(md:find("Thinking: checking files", 1, true) ~= nil, true)
  end)

  test.it("renders reasoning activity as a reasoning section", function()
    local conversation = Conversation(Ollama(), root)
    conversation:add("activity", "Reasoning\n\nThe directory is empty.", { autosave = false })

    local md = conversation:to_markdown()
    test.equal(md:find("## Reasoning\n\nThe directory is empty.", 1, true) ~= nil, true)
  end)

  test.it("renders apply_patch tool calls with diff fences", function()
    config.plugins.assistant.verbose_tool_calling = true
    local conversation = Conversation(Ollama(), root)
    conversation:add("tool_call", "Tool: apply_patch\nArguments:\n{}", {
      meta = {
        call = {
          name = "apply_patch",
          arguments = {
            patch = "--- a/main.c\n+++ b/main.c\n@@ -1 +1 @@\n-old\n+new"
          }
        }
      },
      autosave = false
    })

    local md = conversation:to_markdown()

    test.equal(md:find("```diff", 1, true) ~= nil, true)
    test.equal(md:find("--- a/main.c", 1, true) ~= nil, true)
    test.equal(md:find("+new", 1, true) ~= nil, true)
  end)

  test.it("hides tool sections from markdown unless verbose tool calling is enabled", function()
    local conversation = Conversation(Ollama(), root)
    conversation:add("tool_call", "Tool: apply_patch\nArguments:\n{}", {
      meta = {
        call = {
          name = "apply_patch",
          arguments = {
            patch = "--- a/main.c\n+++ b/main.c\n@@ -1 +1 @@\n-old\n+new"
          }
        }
      },
      autosave = false
    })
    conversation:add("tool_result", "Tool: apply_patch\nStatus: ok\nResult:\napplied", {
      autosave = false
    })
    conversation:add("activity", "Editing files", { autosave = false })

    local md = conversation:to_markdown()
    test.equal(md:find("## Tool call", 1, true), nil)
    test.equal(md:find("## Tool result", 1, true), nil)
    test.equal(md:find("## Activity", 1, true), nil)
    test.equal(md:find("**Editing files**", 1, true) ~= nil, true)

    config.plugins.assistant.verbose_tool_calling = true
    md = conversation:to_markdown()
    test.equal(md:find("## Tool call", 1, true) ~= nil, true)
    test.equal(md:find("## Tool result", 1, true) ~= nil, true)
    test.equal(md:find("```diff", 1, true) ~= nil, true)
  end)

  test.it("removes pending message entries", function()
    local conversation = Conversation(Ollama(), root)
    local entry = conversation:add("assistant", "", { autosave = false })

    test.equal(conversation:remove(entry), true)
    test.equal(conversation:last().role, "user")
    test.equal(conversation:last().meta.environment_context, true)
  end)

  test.it("does not send empty assistant placeholders to providers", function()
    local conversation = Conversation(Ollama(), root)
    conversation:add("user", "Question", { autosave = false })
    conversation:add("assistant", "", { autosave = false })

    local messages = conversation:to_provider_messages()
    test.equal(messages[#messages].role, "user")
    test.equal(messages[#messages].content, "Question")
  end)

  test.it("does not send assistant tool preambles back to providers", function()
    local conversation = Conversation(Ollama(), root)
    conversation:add("user", "Implement it", { autosave = false })
    conversation:add("assistant", "I need to create the missing files.", { autosave = false })
    conversation:add("tool_call", "Tool: apply_patch", {
      meta = {
        provider_message = {
          role = "assistant",
          tool_calls = {
            {
              id = "call_patch",
              type = "function",
              ["function"] = {
                name = "apply_patch",
                arguments = "{\"patch\":\"*** Begin Patch\\n*** Add File: a.txt\\n+x\\n*** End Patch\"}"
              }
            }
          }
        }
      },
      autosave = false
    })
    conversation:add("tool_result", "applied patch to 1 file(s)", {
      meta = {
        provider_message = {
          role = "tool",
          tool_call_id = "call_patch",
          content = "applied patch to 1 file(s)"
        }
      },
      autosave = false
    })

    local messages = conversation:to_provider_messages()
    local found_preamble = false
    local found_tool_call = false
    for _, message in ipairs(messages) do
      if message.role == "assistant" and message.content == "I need to create the missing files." then
        found_preamble = true
      end
      if message.role == "assistant" and type(message.tool_calls) == "table" then
        found_tool_call = true
      end
    end
    test.equal(found_preamble, false)
    test.equal(found_tool_call, true)
  end)

  test.it("does not send local error messages to providers", function()
    local conversation = Conversation(Ollama(), root)
    conversation:add("user", "Question", { autosave = false })
    conversation:add("error", "HTTP 400", { autosave = false })

    local messages = conversation:to_provider_messages()
    test.equal(messages[#messages].role, "user")
    test.equal(messages[#messages].content, "Question")
  end)

  test.it("shows user input prompts locally without sending them to providers", function()
    local conversation = Conversation(Ollama(), root)
    conversation:add("user", "Question", { autosave = false })
    conversation:add("assistant", "### Question\n\nProceed?", {
      meta = { user_input_prompt = true },
      autosave = false
    })

    local markdown = conversation:to_markdown()
    local messages = conversation:to_provider_messages()
    test.equal(markdown:find("Proceed?", 1, true) ~= nil, true)
    test.equal(messages[#messages].role, "user")
    test.equal(messages[#messages].content, "Question")
  end)

  test.it("keeps transcript while sending compact summary plus new turns", function()
    local conversation = Conversation(Ollama(), root)
    conversation:add("user", "Old question", { autosave = false })
    conversation:add("assistant", "Old answer", { autosave = false })
    conversation:record_local_compaction("Old conversation summarized.")
    conversation:add("user", "New question", { autosave = false })

    local messages = conversation:to_provider_messages()
    test.equal(#conversation.messages, 6)
    test.equal(conversation.messages[5].message:find("### Conversation Compacted", 1, true) ~= nil, true)
    test.equal(conversation:to_markdown():find("Old question", 1, true) ~= nil, true)
    test.equal(messages[1].role, "system")
    test.equal(messages[2].role, "assistant")
    test.equal(messages[2].content:find("### Compacted Conversation Summary", 1, true) ~= nil, true)
    test.equal(messages[2].content:find("Old conversation summarized", 1, true) ~= nil, true)
    test.equal(messages[3].role, "user")
    test.equal(messages[3].content:find("Runtime environment:", 1, true) ~= nil, true)
    test.equal(messages[4].role, "user")
    test.equal(messages[4].content, "New question")
  end)

  test.it("keeps active task plan in provider context after compaction", function()
    local conversation = Conversation(Ollama(), root)
    conversation.assistant_plan = {
      explanation = "Ship the feature.",
      items = {
        { status = "completed", step = "Inspect code" },
        { status = "in_progress", step = "Patch backend" },
        { status = "pending", step = "Run tests" }
      }
    }
    conversation:add("user", "Old question", { autosave = false })
    conversation:add("assistant", "### Plan Updated\n\n- [x] Inspect code\n- [ ] **Patch backend** _(in progress)_\n- [ ] Run tests", {
      meta = { plan_update = true },
      autosave = false
    })
    conversation:record_local_compaction("Old conversation summarized.")
    conversation:add("user", "Continue", { autosave = false })

    local messages = conversation:to_provider_messages()
    test.equal(messages[2].role, "system")
    test.equal(messages[2].content:find("Current task plan", 1, true) ~= nil, true)
    test.equal(messages[2].content:find("- [x] Inspect code", 1, true) ~= nil, true)
    test.equal(messages[2].content:find("- [ ] Patch backend (in progress)", 1, true) ~= nil, true)
    test.equal(messages[2].content:find("- [ ] Run tests", 1, true) ~= nil, true)
  end)

  test.it("omits completed task plan from provider context", function()
    local conversation = Conversation(Ollama(), root)
    conversation.assistant_plan = {
      items = {
        { status = "completed", step = "Inspect code" },
        { status = "completed", step = "Run tests" }
      }
    }
    conversation:add("user", "Done?", { autosave = false })

    local messages = conversation:to_provider_messages()
    local found = false
    for _, message in ipairs(messages) do
      if tostring(message.content or ""):find("Current task plan", 1, true) then
        found = true
      end
    end
    test.equal(found, false)
  end)

  test.it("persists local compaction metadata", function()
    local conversation = Conversation(Ollama(), root)
    conversation:add("user", "Old question", { autosave = false })
    conversation:record_local_compaction("Persisted summary.")

    local loaded = Conversation.load(conversation.id, root)
    test.not_nil(loaded)
    test.equal(loaded.local_compaction.summary, "Persisted summary.")
    test.equal(loaded.local_compaction.message_count, 3)
    test.equal(loaded.local_compaction.version, 2)
    test.equal(loaded.local_compaction.strategy, "local_summary")
    test.not_nil(loaded.local_compaction.context_snapshot)
  end)

  test.it("tracks context left from provider usage", function()
    local conversation = Conversation(Ollama(), root)
    conversation.options.context = 100
    conversation:set_usage({ total_tokens = 25 })

    test.equal(conversation:context_left(), 75)
  end)

  test.it("prefers context reported by provider usage", function()
    local conversation = Conversation(Ollama(), root)
    conversation.options.context = 100
    conversation:set_usage({ total_tokens = 25, context = 1000 })

    test.equal(conversation:context_left(), 975)
    test.equal(conversation.options.context, 1000)
  end)
end)
