local core = require "core"
local common = require "core.common"
local permission = require "plugins.assistant.permission"

---Selects and classifies assistant tools for collaboration modes.
---@class assistant.tool_router
local tool_router = {}

local PLAN_TOOL_NAMES = {
  file_info = true,
  git_diff = true,
  git_status = true,
  list = true,
  read = true,
  request_user_input = true,
  exec_command = true,
  exec_status = true,
  search = true,
  time = true,
  tool_catalog = true,
  web_fetch = true,
  web_find = true,
  web_search = true
}

local IMPLEMENTATION_TOOL_NAMES = {
  edit = true,
  exec_command = true,
  file_info = true,
  git_diff = true,
  git_status = true,
  list = true,
  read = true,
  request_user_input = true,
  search = true,
  close_exec = true,
  exec_status = true,
  interrupt_exec = true,
  send_eof = true,
  update_plan = true,
  write = true,
  write_stdin = true
}

local BUILTIN_TOOL_NAMES = {
  apply_patch = true,
  edit = true,
  exec_command = true,
  exec_status = true,
  file_info = true,
  git_diff = true,
  git_status = true,
  list = true,
  read = true,
  request_user_input = true,
  search = true,
  close_exec = true,
  interrupt_exec = true,
  send_eof = true,
  time = true,
  tool_catalog = true,
  update_plan = true,
  web_fetch = true,
  web_find = true,
  web_search = true,
  write = true,
  write_stdin = true
}

---Handle project roots.
---@param conversation assistant.Conversation|nil
---@return string[] roots
function tool_router.project_roots(conversation)
  local roots = {}
  for _, project in ipairs(core.projects or {}) do
    if project.path and project.path ~= "" then
      table.insert(roots, common.normalize_path(project.path) or project.path)
    end
  end
  if conversation and conversation.project_dir and conversation.project_dir ~= "" then
    local root = common.normalize_path(conversation.project_dir) or conversation.project_dir
    local found = false
    for _, item in ipairs(roots) do
      if item == root then
        found = true
        break
      end
    end
    if not found then table.insert(roots, root) end
  end
  return roots
end

---Handle selected names.
local function selected_names(tools, allowed)
  local names = {}
  for name in pairs(allowed or {}) do
    if tools[name] then table.insert(names, name) end
  end
  for name in pairs(tools or {}) do
    if not BUILTIN_TOOL_NAMES[name] then table.insert(names, name) end
  end
  table.sort(names)
  return names
end

---Return whether the active model should receive GPT-oriented editing tools.
---@param agent assistant.Agent
---@return boolean
local function model_is_gpt(agent)
  local model = tostring(agent and agent.model or ""):lower()
  return model:find("gpt", 1, true) ~= nil
end

---Return implementation tools adjusted for the active model family.
---@param agent assistant.Agent
---@return table<string, boolean>
local function implementation_tool_names(agent)
  local allowed = {}
  for name, value in pairs(IMPLEMENTATION_TOOL_NAMES) do
    allowed[name] = value
  end
  if model_is_gpt(agent) then
    allowed.apply_patch = true
    allowed.edit = nil
    allowed.write = nil
  else
    allowed.apply_patch = nil
    allowed.edit = true
    allowed.write = true
  end
  return allowed
end

---Handle tool names for mode.
---@param agent assistant.Agent
---@param conversation assistant.Conversation|nil
---@return string[]|nil names
function tool_router.tool_names_for_mode(agent, conversation)
  local mode = agent:normalize_collaboration_mode(conversation and conversation.collaboration_mode)
  if mode == "plan" then
    return selected_names(agent.tools or {}, PLAN_TOOL_NAMES)
  end
  if mode == "implementation" or mode == nil then
    return selected_names(agent.tools or {}, implementation_tool_names(agent))
  end
end

---Handle classify tool call.
---@param agent assistant.Agent
---@param call table
---@param conversation assistant.Conversation|nil
---@return table classification
function tool_router.classify_tool_call(agent, call, conversation)
  local name = agent:resolve_tool_name(call and call.name)
  return permission.classify_tool_call({
    name = name,
    arguments = call and call.arguments or {}
  }, agent.tools and agent.tools[name or ""], {
    cwd = call and call.arguments and (call.arguments.workdir or call.arguments.cwd),
    project_roots = tool_router.project_roots(conversation)
  })
end

---Handle tool requires approval.
---@param agent assistant.Agent
---@param call table
---@param conversation assistant.Conversation|nil
---@return boolean
function tool_router.tool_requires_approval(agent, call, conversation)
  local name = agent:resolve_tool_name(call and call.name)
  local tool = agent.tools and agent.tools[name or ""]
  if not tool then return true end
  local classification = tool_router.classify_tool_call(agent, call, conversation)
  if classification and classification.category then
    return permission.requires_approval(classification)
  end
  if tool.requires_approval then
    return tool.requires_approval(call.arguments or {}) ~= false
  end
  return tool.read_only ~= true
end

return tool_router
