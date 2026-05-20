package.path = "./?.lua;./?/init.lua;" .. package.path

local assistant_test_temp_counter = 0

rawset(_G, "assistant_test_temp_path", function(name)
  assistant_test_temp_counter = assistant_test_temp_counter + 1
  local path = os.tmpname()
  os.remove(path)
  return path .. "-" .. tostring(assistant_test_temp_counter) .. "-" .. name
end)

package.preload["plugins.assistant.agent"] = function()
  return dofile("agent.lua")
end

package.preload["plugins.assistant.agent.ollama"] = function()
  return dofile("agent/ollama.lua")
end

package.preload["plugins.assistant.agent.llamacpp"] = function()
  return dofile("agent/llamacpp.lua")
end

package.preload["plugins.assistant.agent.lms"] = function()
  return dofile("agent/lms.lua")
end

package.preload["plugins.assistant.agent.openai"] = function()
  return dofile("agent/openai.lua")
end

package.preload["plugins.assistant.agent.codex"] = function()
  return dofile("agent/codex.lua")
end

package.preload["plugins.assistant.agent.acp"] = function()
  return dofile("agent/acp.lua")
end

package.preload["plugins.assistant.agent.copilot"] = function()
  return dofile("agent/copilot.lua")
end

package.preload["plugins.assistant.backend"] = function()
  return dofile("backend/init.lua")
end

package.preload["plugins.assistant.backend.http"] = function()
  return dofile("backend/http.lua")
end

package.preload["plugins.assistant.backend.cli"] = function()
  return dofile("backend/cli.lua")
end

package.preload["plugins.assistant.backend.appserver"] = function()
  return dofile("backend/appserver.lua")
end

package.preload["plugins.assistant.backend.acp"] = function()
  return dofile("backend/acp.lua")
end

package.preload["plugins.assistant.backend.transport"] = function()
  return dofile("backend/transport/init.lua")
end

package.preload["plugins.assistant.backend.transport.stdio"] = function()
  return dofile("backend/transport/stdio.lua")
end

package.preload["plugins.assistant.backend.transport.tcp"] = function()
  return dofile("backend/transport/tcp.lua")
end

package.preload["plugins.assistant.conversation"] = function()
  return dofile("conversation.lua")
end

package.preload["plugins.assistant.promptview"] = function()
  return dofile("promptview.lua")
end

package.preload["plugins.assistant.ui.conversationslist"] = function()
  return dofile("ui/conversationslist.lua")
end

package.preload["plugins.assistant.ui.modeldialog"] = function()
  return dofile("ui/modeldialog.lua")
end

package.preload["plugins.assistant.tools"] = function()
  return dofile("tools.lua")
end

package.preload["plugins.assistant.stream_state"] = function()
  return dofile("stream_state.lua")
end

package.preload["plugins.assistant.tool_router"] = function()
  return dofile("tool_router.lua")
end
