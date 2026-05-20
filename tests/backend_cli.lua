local test = require "core.test"
dofile("tests/helper.inc")
local Conversation = require "plugins.assistant.conversation"
local CliBackend = require "plugins.assistant.backend.cli"
local Agent = require "plugins.assistant.agent"

local real_process = process

local function fake_proc(stdout_chunks, stderr_chunks, code)
  local proc = {
    stdout_chunks = stdout_chunks or {},
    stderr_chunks = stderr_chunks or {},
    code = code or 0,
    killed = false
  }
  function proc:running()
    return #self.stdout_chunks > 0 or #self.stderr_chunks > 0
  end
  function proc:read_stdout()
    return table.remove(self.stdout_chunks, 1) or ""
  end
  function proc:read_stderr()
    return table.remove(self.stderr_chunks, 1) or ""
  end
  function proc:write(data)
    self.stdin = (self.stdin or "") .. data
    return #data
  end
  function proc:close_stream()
    self.stdin_closed = true
    return true
  end
  function proc:returncode()
    return self.code
  end
  function proc:terminate()
    self.killed = true
  end
  return proc
end

test.describe("assistant cli backend", function()
  test.after_each(function()
    process = real_process
  end)

  test.it("parses generic cli jsonl events", function()
    local proc = fake_proc({
      '{"type":"thread.started","thread_id":"thread-1"}\n' ..
      '{"type":"item.completed","item":{"type":"agent_message","text":"pong"}}\n' ..
      '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}\n'
    })
    process = {
      REDIRECT_DISCARD = real_process.REDIRECT_DISCARD,
      REDIRECT_PIPE = real_process.REDIRECT_PIPE,
      start = function()
        return proc
      end
    }

    local CliAgent = Agent:extend()
    function CliAgent:new()
      self.super.new(self, {
        name = "cli-test",
        display_name = "CLI Test",
        backend = "cli",
        model = ""
      })
    end
    function CliAgent:build_command()
      return { "cli-test" }
    end

    local agent = CliAgent()
    local conversation = Conversation(agent, "/tmp")
    conversation:add("user", "hello", { autosave = false })
    local backend = CliBackend()
    local done_response
    local done_usage

    backend:send(agent, conversation, function(ok, _, response, meta)
      if ok and meta and meta.done then
        done_response = response
        done_usage = meta.usage
      end
    end)

    coroutine.yield(0.05)

    test.equal(conversation.codex_thread_id, "thread-1")
    test.equal(done_response, "pong")
    test.equal(done_usage.total_tokens, 12)
  end)
end)
