local context = require "plugins.assistant.tool_context"
local file = require "plugins.assistant.tool.file"
local applypatch = require "plugins.assistant.tool.applypatch"
local process = require "plugins.assistant.tool.process"
local web = require "plugins.assistant.tool.web"
local git = require "plugins.assistant.tool.git"
local misc = require "plugins.assistant.tool.misc"
local Tool = require "plugins.assistant.tool"

---Facade and registry for assistant tools.
---
---Tool implementations live in `tool/*` modules. This facade exposes their
---callbacks for tests/direct use and registers declarative tool specs with an
---agent.
---@class assistant.tools
local tools = {}
local modules = {
  misc,
  file,
  applypatch,
  process,
  web,
  git
}
local external_tools = {}

tools.set_confirm_write = context.set_confirm_write
tools.confirm = context.confirm
tools.read_path_allowed_without_confirmation = context.read_path_allowed_without_confirmation

tools.search = file.search
tools.list = file.list
tools.read = file.read
tools.file_info = file.file_info
tools.write = file.write_file
tools.edit = file.edit

tools.apply_patch = applypatch.apply_patch

tools.exec_command = process.exec_command
tools.write_stdin = process.write_stdin
tools.exec_status = process.exec_status
tools.send_eof = process.send_eof
tools.interrupt_exec = process.interrupt_exec
tools.close_exec = process.close_exec

tools.web_fetch = web.web_fetch
tools.web_search = web.web_search
tools.web_find = web.web_find

tools.git_status = git.git_status
tools.git_diff = git.git_diff

tools.time = misc.time
tools.tool_catalog = misc.tool_catalog
tools.update_plan = misc.update_plan
tools.request_user_input = misc.request_user_input

---Register an external assistant tool.
---@param name string
---@param spec assistant.ToolSpec
---@return boolean ok
---@return string|nil err
function tools.register_external_tool(name, spec)
  spec.name = name
  local tool = spec
  if getmetatable(tool) ~= Tool then
    local ok, result = pcall(function()
      return Tool:new(spec)
    end)
    if not ok then return false, result end
    tool = result
  end
  external_tools[name] = tool
  return true
end

---Remove a registered external assistant tool.
---@param name string
---@return boolean removed
function tools.unregister_external_tool(name)
  local removed = external_tools[name] ~= nil
  external_tools[name] = nil
  return removed
end

---Handle registration of agent tools.
---@param agent assistant.Agent
---@return assistant.Agent agent
function tools.register_agent_tools(agent)
  for _, module in ipairs(modules) do
    for _, tool in ipairs(module.tools or {}) do
      tool:register(agent, tools)
    end
  end
  for _, tool in pairs(external_tools) do
    tool:register(agent, tools)
  end
  return agent
end

return tools
