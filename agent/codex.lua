local common = require "core.common"
local Agent = require "plugins.assistant.agent"

---Agent adapter for the app-server protocol.
---@class assistant.agent.Codex : assistant.Agent
---@field public command string
---@field public sandbox string
---@field public approval_policy table
local Codex = Agent:extend()

local CODEX_REASONING_EFFORT = {
  none = "minimal",
  low = "low",
  medium = "medium",
  high = "high"
}

---Create a new instance.
---@param options table?
function Codex:new(options)
  options = options or {}
  options.name = options.name or "codex"
  options.display_name = options.display_name or "Codex"
  options.backend = options.backend or "appserver"
  options.model = options.model or ""
  options.capabilities = common.merge({
    reports_usage = true,
    reports_context = true,
    compact = true,
    delete_conversation = false,
    list_conversations = false,
    rename_conversation = true,
    collaboration_modes = true,
    user_input_requests = true,
    approval_requests = true,
    stream_responses = true
  }, options.capabilities)
  self.super.new(self, options)
  self.command = options.command or "codex"
  self.sandbox = options.sandbox or "workspace-write"
  self.approval_policy = options.approval_policy or {
    granular = {
      mcp_elicitations = true,
      request_permissions = true,
      rules = true,
      sandbox_approval = true,
      skill_approval = true
    }
  }
end

---Handle configure provider.
---@param conf table
function Codex:configure_provider(conf)
  if conf.codex_command and conf.codex_command ~= "" then
    self.command = conf.codex_command
  end
end

---Handle appserver sandbox.
---@return "read-only"|"workspace-write"|"danger-full-access"
function Codex:appserver_sandbox()
  if self.sandbox == "read-only" then return "read-only" end
  if self.sandbox == "danger-full-access" then return "danger-full-access" end
  return "workspace-write"
end

---Return the collaboration modes.
---@return table[]
function Codex:get_collaboration_modes()
  return self.collaboration_modes or {
    { id = "default", label = "Implementation", mode = "default" },
    { id = "plan", label = "Plan", mode = "plan" }
  }
end

---Normalize collaboration mode.
---@param value any
---@return string?
local function normalize_collaboration_mode(value)
  if type(value) ~= "string" then return nil end
  value = value:gsub("^%s+", ""):gsub("%s+$", "")
  value = value:lower()
  if value == "implementation" then return "default" end
  return value
end

---Build collaboration mode.
---@param mode string|table?
---@return table?
function Codex:build_collaboration_mode(mode)
  if not mode or mode == "" then return nil end
  local option = self.collaboration_modes_by_id and self.collaboration_modes_by_id[mode] or nil
  if type(mode) == "table" then
    option = mode
    mode = mode.id or mode.label
  end
  local kind = (type(option) == "table" and option.mode) or normalize_collaboration_mode(mode)
  if type(kind) ~= "string" or kind == "" then
    return nil
  end

  local settings = {}
  local model = self.model
  if (not model or model == "") and type(option) == "table" then
    model = option.model
  end
  if model and model ~= "" then settings.model = model end
  local reasoning_effort = (type(option) == "table" and option.reasoning_effort)
    or (type(option) == "table" and option.settings and option.settings.reasoning_effort)
    or self:configured_appserver_reasoning_effort()
  if reasoning_effort and reasoning_effort ~= "" then settings.reasoning_effort = reasoning_effort end
  if type(option) == "table" and type(option.settings) == "table" then
    for k, v in pairs(option.settings) do
      if settings[k] == nil then settings[k] = v end
    end
  end

  return {
    mode = kind,
    settings = settings
  }
end

---Return the configured reasoning effort for Codex app-server fields.
---@return string|nil effort
function Codex:configured_appserver_reasoning_effort()
  local effort = self:configured_reasoning_effort()
  return effort and CODEX_REASONING_EFFORT[effort] or nil
end

---Parse usage.
---@param result table
---@return table?
function Codex:parse_usage(result)
  if type(result) ~= "table" then return nil end
  local usage = result.usage or result
  local context = result.model_context_window or result.modelContextWindow
  local cumulative
  if type(result.tokenUsage) == "table" then
    cumulative = result.tokenUsage.total
    usage = result.tokenUsage.last or result.tokenUsage.total or result.tokenUsage
    context = result.tokenUsage.modelContextWindow or context
  end
  if type(usage) ~= "table" then return nil end
  local input = usage.input_tokens or usage.inputTokens
  local output = usage.output_tokens or usage.outputTokens
  local total = usage.total_tokens or usage.totalTokens
  if not total and (input or output) then
    total = (input or 0) + (output or 0)
  end
  if not (input or output or total) then return nil end
  return {
    input_tokens = input,
    output_tokens = output,
    total_tokens = total,
    cached_input_tokens = usage.cached_input_tokens or usage.cachedInputTokens,
    reasoning_output_tokens = usage.reasoning_output_tokens or usage.reasoningOutputTokens,
    cumulative_input_tokens = cumulative and (cumulative.input_tokens or cumulative.inputTokens),
    cumulative_output_tokens = cumulative and (cumulative.output_tokens or cumulative.outputTokens),
    cumulative_total_tokens = cumulative and (cumulative.total_tokens or cumulative.totalTokens),
    cumulative_cached_input_tokens = cumulative and (cumulative.cached_input_tokens or cumulative.cachedInputTokens),
    cumulative_reasoning_output_tokens = cumulative
      and (cumulative.reasoning_output_tokens or cumulative.reasoningOutputTokens),
    context = context
  }
end

---Handle first present.
---@return any
local function first_present(...)
  local values = { ... }
  for _, value in ipairs(values) do
    if value ~= nil and value ~= "" then
      return value
    end
  end
end

---Normalize request id.
---@param message table?
---@param params table?
---@return string?
local function normalize_request_id(message, params)
  return first_present(
    message and message.id,
    params and params.id,
    params and params.callId,
    params and params.conversationId,
    params and params.itemId,
    params and params.threadId,
    params and params.turnId,
    params and params.requestId
  )
end

---Handle available decisions.
---@param params table?
---@return table?
local function available_decisions(params)
  if type(params) ~= "table" then return nil end
  return params.availableDecisions or params.available_decisions
end

---Handle command action context.
---@param params table?
---@return table?
local function command_action_context(params)
  if type(params) ~= "table" then return nil end
  return params.proposedExecpolicyAmendment
    or params.proposedExecPolicyAmendment
    or params.proposed_execpolicy_amendment
    or params.proposed_exec_policy_amendment
end

---Normalize user input request.
---@param message table
---@return table?
function Codex:normalize_user_input_request(message)
  if type(message) ~= "table" or message.method ~= "item/tool/requestUserInput" then
    return nil
  end
  local params = message.params or {}
  local questions = {}
  for index, question in ipairs(params.questions or {}) do
    if type(question) == "table" then
      local options = {}
      for _, option in ipairs(question.options or {}) do
        if type(option) == "table" then
          local label = option.label or option.description
          local value = option.value
          if value == nil then
            value = option.valueId or option.id or option.label
          end
          value = tostring(value or "")
          if label and label ~= "" then
            table.insert(options, {
              label = label,
              value = value,
              description = option.description or ""
            })
          end
        elseif type(option) == "string" then
          table.insert(options, {
            label = option,
            value = option,
            description = ""
          })
        end
      end
      table.insert(questions, {
        id = question.id or tostring(index),
        header = question.header,
        question = question.question or question.header or "Assistant question",
        options = options,
        allow_other = question.isOther == true or #options == 0,
        is_secret = question.isSecret == true
      })
    end
  end
  if #questions == 0 then return nil end
  local request_id = normalize_request_id(message, params)
  return {
    id = request_id,
    provider_id = request_id,
    item_id = params.itemId,
    thread_id = params.threadId,
    turn_id = params.turnId,
    questions = questions
  }
end

---Format user input response.
---@param request table
---@param _ any
---@param answers table?
---@return table
function Codex:format_user_input_response(request, _, answers)
  local result = { answers = {} }
  local questions = request and request.questions or {}
  for _, question in ipairs(questions) do
    local answer = answers and answers[question.id]
    local values = {}
    if type(answer) == "table" then
      values = answer.answers or answer
    elseif answer ~= nil then
      values = { tostring(answer) }
    end
    result.answers[question.id] = { answers = values }
  end
  return result
end

---Handle path text.
---@param value any
---@return string
local function path_text(value)
  if type(value) == "string" then return value end
  if type(value) == "table" then
    return value.path
      or value.pattern
      or (value.value and (value.value.path or value.value.kind or value.value.subpath))
      or value.kind
      or value.type
      or ""
  end
  return ""
end

---Handle permissions summary.
---@param permissions table?
---@return string
local function permissions_summary(permissions)
  if type(permissions) ~= "table" then return "" end
  local lines = {}
  local fs = permissions.fileSystem or permissions.file_system
  if type(fs) == "table" then
    for _, entry in ipairs(fs.entries or {}) do
      if type(entry) == "table" then
        table.insert(lines, string.format(
          "%s: %s",
          tostring(entry.access or "access"),
          path_text(entry.path)
        ))
      end
    end
    for _, path in ipairs(fs.read or {}) do table.insert(lines, "read: " .. path_text(path)) end
    for _, path in ipairs(fs.write or {}) do table.insert(lines, "write: " .. path_text(path)) end
  end
  local network = permissions.network
  if type(network) == "table" and network.enabled ~= nil then
    table.insert(lines, "network: " .. tostring(network.enabled))
  end
  return table.concat(lines, "\n")
end

---Handle join lines.
---@param parts any[]
---@return string
local function join_lines(parts)
  local lines = {}
  for _, part in ipairs(parts) do
    if part and part ~= "" then table.insert(lines, part) end
  end
  return table.concat(lines, "\n")
end

---Normalize approval request.
---@param message table
---@return table?
function Codex:normalize_approval_request(message)
  if type(message) ~= "table" then return nil end
  local params = message.params or {}
  local method = message.method
  if method == "item/commandExecution/requestApproval" or method == "item/tool/requestApproval" then
    local kind = method == "item/tool/requestApproval" and "tool" or "command"
    local request_id = normalize_request_id(message, params)
    return {
      id = request_id,
      provider_id = request_id,
      call_id = params.callId,
      kind = kind,
      title = "Approve Command",
      body = join_lines({
        params.reason or "Codex wants to run a command.",
        params.command and ("\nCommand:\n" .. tostring(params.command)) or nil,
        params.cwd and ("\nDirectory:\n" .. tostring(params.cwd)) or nil,
        params.callId and ("\nCall ID:\n" .. tostring(params.callId)) or nil
      }, "\n"),
      raw = params,
      available_decisions = available_decisions(params),
      proposed_execpolicy_amendment = command_action_context(params),
      command_actions = params.commandActions,
      network_approval_context = params.networkApprovalContext,
      item_id = params.itemId,
      thread_id = params.threadId,
      turn_id = params.turnId
    }
  elseif method == "execCommandApproval" then
    local command = params.command
    if type(command) == "table" then command = table.concat(command, " ") end
    local request_id = normalize_request_id(message, params)
    return {
      id = request_id,
      provider_id = request_id,
      call_id = params.callId,
      legacy = true,
      kind = "command",
      title = "Approve Command",
      body = join_lines({
        params.reason or "Codex wants to run a command.",
        command and ("\nCommand:\n" .. command) or nil,
        params.cwd and ("\nDirectory:\n" .. tostring(params.cwd)) or nil
      }),
      raw = params,
      available_decisions = available_decisions(params),
      proposed_execpolicy_amendment = command_action_context(params),
      command_actions = params.commandActions,
      network_approval_context = params.networkApprovalContext,
      item_id = params.itemId,
      thread_id = params.threadId,
      turn_id = params.turnId
    }
  elseif method == "item/fileChange/requestApproval" then
    local request_id = normalize_request_id(message, params)
    return {
      id = request_id,
      provider_id = request_id,
      call_id = params.callId,
      kind = "file_change",
      title = "Approve File Change",
      body = join_lines({
        params.reason or "Codex wants to modify files.",
        params.grantRoot and ("\nWritable root:\n" .. tostring(params.grantRoot)) or nil
      }, "\n"),
      raw = params,
      available_decisions = available_decisions(params),
      additional_permissions = params.additionalPermissions,
      item_id = params.itemId,
      thread_id = params.threadId,
      turn_id = params.turnId
    }
  elseif method == "applyPatchApproval" then
    local changes = {}
    for path, change in pairs(params.fileChanges or {}) do
      if type(change) == "table" then
        table.insert(changes, string.format("%s: %s", tostring(change.type or "change"), tostring(path)))
      end
    end
    table.sort(changes)
    local request_id = normalize_request_id(message, params)
    return {
      id = request_id,
      provider_id = request_id,
      call_id = params.callId,
      legacy = true,
      kind = "file_change",
      title = "Approve File Change",
      body = join_lines({
        params.reason or "Codex wants to modify files.",
        params.grantRoot and ("\nWritable root:\n" .. tostring(params.grantRoot)) or nil,
        #changes > 0 and ("\nFiles:\n" .. table.concat(changes, "\n")) or nil
      }),
      raw = params,
      available_decisions = available_decisions(params),
      additional_permissions = params.additionalPermissions,
      item_id = params.itemId,
      thread_id = params.threadId,
      turn_id = params.turnId
    }
  elseif method == "item/tool/call/requestApproval" then
    local request_id = normalize_request_id(message, params)
    return {
      id = request_id,
      provider_id = request_id,
      call_id = params.callId,
      kind = "tool_call",
      title = "Approve Tool Call",
      body = join_lines({
        params.reason or "Codex wants to run a tool.",
        params.cwd and ("\nDirectory:\n" .. tostring(params.cwd)) or nil
      }),
      raw = params,
      available_decisions = available_decisions(params),
      additional_permissions = params.additionalPermissions,
      item_id = params.itemId,
      thread_id = params.threadId,
      turn_id = params.turnId
    }
  elseif method == "item/permissions/requestApproval" then
    local request_id = normalize_request_id(message, params)
    local summary = permissions_summary(params.permissions)
    return {
      id = request_id,
      provider_id = request_id,
      call_id = params.callId,
      kind = "permissions",
      title = "Approve Permissions",
      body = join_lines({
        params.reason or "Codex is requesting additional permissions.",
        params.cwd and ("\nDirectory:\n" .. tostring(params.cwd)) or nil,
        summary ~= "" and ("\nPermissions:\n" .. summary) or nil
      }, "\n"),
      raw = params,
      available_decisions = available_decisions(params),
      additional_permissions = params.additionalPermissions,
      item_id = params.itemId,
      thread_id = params.threadId,
      turn_id = params.turnId
    }
  end
end

---Format approval response.
---@param request table
---@param decision string?
---@return table
function Codex:format_approval_response(request, decision)
  decision = decision or "decline"
  local mapped = {
    acceptOnce = "accept",
    acceptOnceForSession = "acceptForSession",
    accept_for_session = "acceptForSession",
    accept_for_turn = "accept",
    acceptForSession = "acceptForSession",
    accept = "accept",
    acceptWithExecpolicyAmendment = "acceptWithExecpolicyAmendment",
    decline = "decline",
    cancel = "decline",
    denied = "decline",
    deny = "decline"
  }
  decision = mapped[tostring(decision)] or "decline"
  if request.legacy then
    if decision == "accept" then
      return { decision = "approved" }
    elseif decision == "acceptForSession" then
      return { decision = "approved_for_session" }
    elseif decision == "acceptOnce" then
      return { decision = "abort" }
    end
    return { decision = "denied" }
  end
  if request.kind == "permissions" then
    local permissions = request.raw and request.raw.permissions or request.raw and request.raw.permissionProfile or {}
    if decision == "accept" then
      return {
        permissions = permissions,
        scope = "turn"
      }
    elseif decision == "acceptForSession" then
      return {
        permissions = permissions,
        scope = decision == "acceptForSession" and "session" or "turn"
      }
    end
    return {
      permissions = {},
      scope = "turn"
    }
  end
  if decision ~= "accept"
    and decision ~= "acceptForSession"
    and decision ~= "acceptWithExecpolicyAmendment"
    and decision ~= "decline"
    and decision ~= "cancel"
  then
    decision = "decline"
  end
  if decision == "acceptWithExecpolicyAmendment" and request.kind == "command" then
    local raw = request.raw or {}
    return {
      decision = decision,
      commandActions = request.command_actions,
      proposedExecpolicyAmendment = request.proposed_execpolicy_amendment,
      networkApprovalContext = request.network_approval_context,
      additionalPermissions = request.additional_permissions,
      availableDecisions = request.available_decisions
    }
  end
  return {
    decision = decision
  }
end

return Codex
