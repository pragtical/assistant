local core = require "core"
local common = require "core.common"
local config = require "core.config"
local http = require "core.http"
local json = require "core.json"
local jsonutil = require "plugins.assistant.jsonutil"
local Backend = require "plugins.assistant.backend"
local assistant_tools = require "plugins.assistant.tools"
local permission = require "plugins.assistant.permission"
local stream_state = require "plugins.assistant.stream_state"
local Tool = require "plugins.assistant.tool"

---Anthropic Messages API streaming backend.
---
---Handles Anthropic's named-SSE streaming format with content block tracking,
---tool use accumulation, thinking/reasoning deltas, and tool call approval rounds.
---@class assistant.backend.AnthropicBackend : assistant.Backend
---@field pending_tool_call table|nil
---@field pending_user_input_tool table|nil
local AnthropicBackend = Backend:extend()

---Create a new instance.
function AnthropicBackend:new()
  self.super.new(self, "anthropic")
  self.pending_tool_call = nil
  self.pending_user_input_tool = nil
end

---Handle join url.
local function join_url(base_url, endpoint)
  base_url = (base_url or ""):gsub("/+$", "")
  endpoint = endpoint or ""
  if endpoint:sub(1, 1) ~= "/" then endpoint = "/" .. endpoint end
  return base_url .. endpoint
end

---Return whether http error.
local function is_http_error(info)
  local status = info and tonumber(info.status)
  return status and (status < 200 or status >= 300)
end

---Handle extract error.
local function extract_error(result)
  if type(result) ~= "table" then
    return type(result) == "string" and result ~= "" and result or nil
  end
  local err = result.error
  if type(err) == "table" then
    return err.message or err.code or err.type
  end
  return result.message or result.error
end

---Handle decode error body.
local function decode_error_body(body)
  if not body or body == "" then return nil end
  return json.decode(body) or body
end

---Build raw error payload.
local function raw_error_payload(info, result, fallback)
  if result ~= nil then return result end
  local payload = {}
  local status = info and tonumber(info.status)
  if status then payload.status = status end
  if type(fallback) == "string" and fallback ~= "" then
    payload.message = fallback
  end
  return next(payload) and payload or nil
end

---Handle configured timeout ms.
local function configured_timeout_ms(agent)
  local timeout_ms = config.plugins
    and config.plugins.assistant
    and tonumber(config.plugins.assistant.request_timeout_ms)
  if not timeout_ms or timeout_ms <= 0 then
    timeout_ms = agent
      and agent.model_metadata
      and tonumber(agent.model_metadata.preferred_timeout_ms)
  end
  if not timeout_ms or timeout_ms <= 0 then return nil end
  return timeout_ms
end

---Return whether plan mode.
local function is_plan_mode(agent, conversation)
  return agent
    and agent.normalize_collaboration_mode
    and agent:normalize_collaboration_mode(conversation and conversation.collaboration_mode) == "plan"
end

local contains_completed_plan = stream_state.contains_completed_plan

---Handle conversation has completed plan.
local function conversation_has_completed_plan(conversation)
  for _, message in ipairs(conversation and conversation.messages or {}) do
    if message.role == "assistant" and contains_completed_plan(message.message) then
      return true
    end
  end
  return false
end

---Handle sanitize plan response.
local function sanitize_plan_response(text)
  text = tostring(text or "")
  if text == "" then return text end
  local open_tag = stream_state.OPEN_PROPOSED_PLAN_TAG
  local close_tag = stream_state.CLOSE_PROPOSED_PLAN_TAG
  local open_at = text:find(open_tag, 1, true)
  local close_at = text:find(close_tag, open_at and (open_at + #open_tag) or 1, true)
  if open_at and close_at then
    text = text:sub(open_at + #open_tag, close_at - 1)
  end
  local patterns = {
    "\n+%s*%**Ready to implement%?%**%s*.*$",
    "\n+%s*Shall I proceed[^?\n]*%?%s*$",
    "\n+%s*Should I proceed[^?\n]*%?%s*$",
    "\n+%s*Would you like me to proceed[^?\n]*%?%s*$",
    "\n+%s*Do you want me to proceed[^?\n]*%?%s*$"
  }
  for _, pattern in ipairs(patterns) do
    text = text:gsub(pattern, "")
  end
  return text:match("^%s*(.-)%s*$") or text
end

---Handle should show tool preamble.
local function should_show_tool_preamble(text)
  text = tostring(text or ""):match("^%s*(.-)%s*$") or ""
  if text == "" then return false end
  if text:find("\n") then return true end
  if text:find("[%.%!%?:]") then return true end
  return #text >= 40
end

---Handle looks like text tool call.
local function looks_like_text_tool_call(text)
  text = tostring(text or ""):match("^%s*(.-)%s*$") or ""
  if text == "" then return false end
  text = text:gsub("&lt;", "<"):gsub("&gt;", ">")
  return text:find("^<function_calls>", 1, true) ~= nil
    or text:find("^<tool_call>", 1, true) ~= nil
    or text:find("^<｜｜DSML｜｜tool_calls>", 1, true) ~= nil
    or text:find("^<||DSML||tool_calls>", 1, true) ~= nil
    or text:find("^<invoke%s+name%s*=") ~= nil
    or text:find("^<function%s*=") ~= nil
end

---Handle strip text tool call blocks.
---@param text string
---@return string
local function strip_text_tool_call_blocks(text)
  text = tostring(text or "")
  if text == "" then return "" end
  text = text:gsub("&lt;", "<"):gsub("&gt;", ">")
  text = text:gsub("<tool_call%s*>.-</tool_call%s*>", "")
  text = text:gsub("<function_calls%s*>.-</function_calls%s*>", "")
  text = text:gsub("<｜｜DSML｜｜tool_calls%s*>.-</｜｜DSML｜｜tool_calls%s*>", "")
  text = text:gsub("<||DSML||tool_calls%s*>.-</||DSML||tool_calls%s*>", "")
  text = text:gsub("<function%s*=%s*['\"]?[%w_%.%-]+['\"]?%s*>.-</function%s*>", "")
  text = text:gsub("<invoke%s+name%s*=%s*['\"]?[%w_%.%-]+['\"]?%s*>.-</invoke%s*>", "")
  return text
end

---Handle configured timeout.
local function provider_timeout(agent)
  local timeout_ms = configured_timeout_ms(agent)
  if not timeout_ms or timeout_ms <= 0 then return nil end
  return timeout_ms / 1000
end

---Handle yield ui.
local function yield_ui()
  if coroutine.isyieldable() then
    core.redraw = true
    coroutine.yield()
  end
end

---Handle stable encode.
local function stable_encode(value)
  local kind = type(value)
  if kind ~= "table" then return json.encode(value) end
  local is_array = true
  local max = 0
  local count = 0
  for key in pairs(value) do
    count = count + 1
    if count % 64 == 0 then yield_ui() end
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      is_array = false
    elseif key > max then
      max = key
    end
  end
  if is_array and max == count then
    local parts = {}
    for i = 1, max do
      table.insert(parts, stable_encode(value[i]))
      if i % 64 == 0 then yield_ui() end
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for key in pairs(value) do
    table.insert(keys, tostring(key))
    if #keys % 64 == 0 then yield_ui() end
  end
  table.sort(keys)
  local parts = {}
  for i, key in ipairs(keys) do
    table.insert(parts, json.encode(key) .. ":" .. stable_encode(value[key]))
    if i % 64 == 0 then yield_ui() end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

---Handle tool call signature.
local function literal_regex_text(text)
  text = tostring(text or "")
  return text:find("[%.%^%$%*%+%?%(%)%[%]%{%}%|\\]") == nil
end

---Return normalized arguments for repeated-call detection.
local function normalized_tool_arguments_for_signature(name, arguments)
  if type(arguments) ~= "table" then return arguments end
  local normalized = Tool.clone_table(arguments)
  if name == "search" then
    normalized.search_type = normalized.search_type or "plain"
    if normalized.search_type == "regex" and literal_regex_text(normalized.text) then
      normalized.search_type = "plain"
    end
  end
  return normalized
end

---Handle tool call signature.
local function tool_call_signature(agent, call)
  local name = call and call.name
  if agent and agent.resolve_tool_name then
    name = agent:resolve_tool_name(name)
  end
  local arguments = call and call.arguments or {}
  if type(arguments) == "string" then
    local decoded = json.decode(arguments)
    if decoded ~= nil then arguments = decoded end
  end
  arguments = normalized_tool_arguments_for_signature(name, arguments)
  return tostring(name or "unknown") .. ":" .. stable_encode(arguments)
end

---Clear a table in place.
local function clear_table(value)
  if type(value) ~= "table" then return end
  for key in pairs(value) do value[key] = nil end
end

---Return whether a completed tool call may have changed project state.
local function tool_call_may_mutate_project(agent, conversation, call)
  local name = agent and agent.resolve_tool_name
    and agent:resolve_tool_name(call and call.name)
    or call and call.name
  if name == "update_plan" or name == "request_user_input" then return false end
  if agent and agent.classify_tool_call then
    local ok, classification = pcall(agent.classify_tool_call, agent, call, conversation)
    if ok and classification and classification.category then
      return classification.category ~= "read_only"
    end
  end
  return name == "edit"
    or name == "write"
    or name == "apply_patch"
    or name == "exec_command"
    or name == "write_stdin"
    or name == "send_eof"
    or name == "interrupt_exec"
    or name == "close_exec"
end

---Add tool result.
local function add_tool_result(agent, conversation, call, result, status)
  local provider_messages = agent.tool_result_provider_messages
    and agent:tool_result_provider_messages(call, result, { compact = false })
    or { agent:tool_result_provider_message(call, result, { compact = false }) }
  local should_defer_compaction = status == "ok"
  conversation:add("tool_result", agent:tool_result_display(call, result, status), {
    meta = {
      call = call,
      status = status,
      provider_message = provider_messages[1],
      provider_messages = provider_messages,
      deferred_tool_result_compaction = should_defer_compaction or nil,
      deferred_tool_result = should_defer_compaction and result or nil
    }
  })
end

---Compact completed fresh tool results after the model has consumed them.
local function compact_deferred_tool_results(agent, conversation)
  if not (conversation and conversation.messages) then return end
  for _, message in ipairs(conversation.messages) do
    local meta = message.meta
    if meta and meta.deferred_tool_result_compaction then
      local call = meta.call
      local result = meta.deferred_tool_result
      local provider_messages = agent.tool_result_provider_messages
        and agent:tool_result_provider_messages(call, result, {
          compact = true,
          include_images = false
        })
        or { agent:tool_result_provider_message(call, result, { compact = true }) }
      meta.provider_message = provider_messages[1]
      meta.provider_messages = provider_messages
      meta.deferred_tool_result_compaction = nil
      meta.deferred_tool_result = nil
    end
  end
end

---Add activity.
local function add_activity(conversation, text, key, compact_markdown)
  text = tostring(text or "")
  if text == "" then return end
  local last = conversation:last()
  if last
    and last.role == "activity"
    and (last.message == text or (key and last.meta and last.meta.http_activity_key == key))
  then
    return
  end
  conversation:add("activity", text, {
    autosave = false,
    meta = {
      http_activity = true,
      http_activity_key = key,
      compact_activity_markdown = compact_markdown
    }
  })
end

---Handle upsert activity.
local function upsert_activity(conversation, text, key, compact_markdown)
  text = tostring(text or "")
  if text == "" then return end
  for index = #(conversation.messages or {}), 1, -1 do
    local message = conversation.messages[index]
    if message.role == "activity"
      and key
      and message.meta
      and message.meta.http_activity_key == key
    then
      if message.message ~= text then
        message.message = text
        conversation:touch()
      end
      if compact_markdown and message.meta then
        message.meta.compact_activity_markdown = compact_markdown
      end
      return
    end
  end
  add_activity(conversation, text, key, compact_markdown)
end

---Handle tool activity label.
local function tool_activity_label(call)
  local name = tostring(call and call.name or "unknown")
  if name == "exec_command"
    or name == "write_stdin"
    or name == "exec_status"
    or name == "send_eof"
    or name == "interrupt_exec"
    or name == "close_exec"
  then
    return "Running command"
  end
  if name == "apply_patch" or name == "edit" or name == "write" then return "Editing files" end
  if name == "read" or name == "list" or name == "search" then return "Inspecting project" end
  if name == "web_fetch" or name == "web_search" or name == "web_find" then return "Searching web" end
  return "Calling tool"
end

---Handle command tool text.
local function command_tool_text(call)
  local name = call and call.name
  local args = call and call.arguments or {}
  if name == "exec_command" then return args.cmd end
  if name == "exec_status" then return "poll session " .. tostring(args.session_id or "") end
  if name == "write_stdin" then return "write stdin to session " .. tostring(args.session_id or "") end
  if name == "send_eof" then return "close stdin for session " .. tostring(args.session_id or "") end
  if name == "interrupt_exec" then return "interrupt session " .. tostring(args.session_id or "") end
  if name == "close_exec" then return "close session " .. tostring(args.session_id or "") end
end

---Handle verbose tool calling.
local function verbose_tool_calling()
  local conf = config.plugins and config.plugins.assistant or {}
  return conf.verbose_tool_calling == true
end

---Return whether reasoning activity messages are enabled.
---@return boolean enabled
local function reasoning_activity_messages_enabled()
  local conf = config.plugins and config.plugins.assistant or {}
  return conf.reasoning_activity_messages ~= false
end

---Handle fenced.
local function fenced(text, language)
  return "```" .. (language or "text") .. "\n" .. tostring(text or "") .. "\n```"
end

---Handle first lines.
local function first_lines(text, max_lines)
  local lines = {}
  local count = 0
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    count = count + 1
    if #lines < max_lines then table.insert(lines, line) end
  end
  local output = table.concat(lines, "\n")
  if count > max_lines then
    output = output .. "\n... truncated after " .. tostring(max_lines) .. " lines ..."
  end
  return output
end

---Return display text for a tool result value.
---@param result any
---@return string text
local function tool_result_text(result)
  if type(result) == "table" then
    return tostring(result.text or result.message or "")
  end
  return tostring(result or "")
end

---Handle tool activity detail.
local function tool_activity_detail(name, call, status, result)
  local args = call and call.arguments or {}
  if name == "apply_patch"
    and (status == "requested" or status == "running" or result == nil or result == "")
    and type(args) == "table"
    and type(args.patch) == "string"
    and args.patch ~= ""
  then
    return fenced(args.patch, "diff")
  end
  if result ~= nil and result ~= "" then
    if name == "read" then
      return fenced(first_lines(tool_result_text(result), 3), "text")
    end
    local text = tool_result_text(result)
    if #text > 12000 then text = text:sub(1, 12000) .. "\n\n... truncated for transcript ..." end
    return fenced(text, "text")
  end
end

---Handle tool activity text.
local function tool_activity_text(agent, call, status, result, activity_context)
  local resolved = agent.resolve_tool_name and agent:resolve_tool_name(call and call.name) or (call and call.name)
  if call then call.name = resolved end
  local lines = { tool_activity_label(call) }
  table.insert(lines, "")
  table.insert(lines, "Tool: `" .. tostring(resolved or "unknown") .. "`")
  local args = call and call.arguments or {}
  if type(args) == "table" then
    if args.cmd or args.command then table.insert(lines, "Command: `" .. tostring(args.cmd or args.command) .. "`") end
    if args.workdir or args.cwd then table.insert(lines, "Cwd: `" .. tostring(args.workdir or args.cwd) .. "`") end
    if args.path then table.insert(lines, "Path: " .. Tool.file_link_or_ticked(args.path, activity_context)) end
    if args.directory then table.insert(lines, "Directory: " .. Tool.relative_path_or_ticked(args.directory, activity_context)) end
    if args.url then table.insert(lines, "URL: `" .. tostring(args.url) .. "`") end
  end
  if status then table.insert(lines, "Status: " .. tostring(status)) end
  if result ~= nil and result ~= "" and verbose_tool_calling() then
    local text = tostring(result)
    if #text > 12000 then text = text:sub(1, 12000) .. "\n\n... truncated for transcript ..." end
    table.insert(lines, "")
    table.insert(lines, fenced(text, "text"))
  elseif not verbose_tool_calling() then
    local detail = tool_activity_detail(resolved, call, status, result)
    if detail then
      table.insert(lines, "")
      table.insert(lines, detail)
    end
  end
  return table.concat(lines, "\n")
end

---Add tool activity.
local function add_tool_activity(agent, conversation, call, status, result)
  local name = call and (agent.resolve_tool_name and agent:resolve_tool_name(call.name) or call.name) or "unknown"
  if call then call.name = name end
  local id = call and (call.id or call.call_id or tool_call_signature(agent, call)) or name
  local tool = agent.tools and agent.tools[name] or nil
  local activity_context = {
    verbose_tool_calling = verbose_tool_calling(),
    project_dir = conversation and conversation.project_dir
  }
  local verbose = tool and tool.activity_markdown
    and tool.activity_markdown(call, status, result, activity_context)
    or tool_activity_text(agent, call, status, result, activity_context)
  local compact = tool and tool.compact_activity_markdown
    and tool.compact_activity_markdown(call, status, result, activity_context)
    or nil
  add_activity(conversation, verbose, "tool:" .. tostring(name) .. ":" .. tostring(status or "pending") .. ":" .. tostring(id), compact)
end

---Resume a pending backend continuation without depending on editor focus.
local function resume_in_background(pending)
  if not (pending and pending.resume) then return end
  core.add_background_thread(function()
    pending.resume()
  end)
end

---Handle max tool call rounds.
local function max_tool_call_rounds()
  local conf = config.plugins.assistant or {}
  local rounds = tonumber(conf.max_tool_call_rounds) or 0
  if rounds <= 0 then return nil end
  return math.floor(rounds)
end

---Return maximum identical tool calls allowed in one assistant turn.
local function max_repeated_tool_calls()
  local conf = config.plugins.assistant or {}
  local calls = tonumber(conf.max_repeated_tool_calls) or 4
  if calls < 1 then calls = 1 end
  return math.floor(calls)
end

---Handle raw request payload.
local function raw_request_payload(payload)
  if type(payload) ~= "table" then return payload end
  local copy = {}
  for key, value in pairs(payload) do
    copy[key] = value
  end
  if type(payload.tools) == "table" then
    local tools = {}
    for _, tool in ipairs(payload.tools) do
      local t = {}
      t.name = tool.name
      table.insert(tools, t)
    end
    copy.tools = tools
    copy.tools_summary = {
      count = #payload.tools,
      schemas_omitted = true
    }
  end
  return copy
end

---Return a stable short hash for request-audit text.
---@param text string
---@return string
local function audit_hash(text)
  text = tostring(text or "")
  local hash = 2166136261
  for index = 1, #text do
    hash = (hash * 16777619 + text:byte(index)) % 4294967296
  end
  return string.format("%08x", hash)
end

---Return a compact preview for request-audit entries.
---@param text string
---@return string
local function audit_preview(text)
  text = tostring(text or ""):gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
  if #text > 220 then text = text:sub(1, 220) .. "..." end
  return text
end

---Return the text content of a provider message.
---@param message table
---@return string
local function provider_message_text(message)
  if type(message) ~= "table" then return "" end
  local content = message.content or message.output or ""
  if type(content) == "string" then return content end
  if type(content) ~= "table" then return tostring(content or "") end
  local parts = {}
  for _, item in ipairs(content) do
    if type(item) == "table" and type(item.text) == "string" then
      table.insert(parts, item.text)
    elseif type(item) == "table" and item.type then
      table.insert(parts, "[" .. tostring(item.type) .. "]")
    end
  end
  return table.concat(parts, "\n")
end

---Return function/tool call summaries for a provider message.
---@param message table
---@return table[]
local function provider_message_tool_calls(message)
  local calls = {}
  if type(message) ~= "table" then return calls end
  if type(message.content) == "table" then
    for _, block in ipairs(message.content) do
      if type(block) == "table" and block.type == "tool_use" then
        local args = json.encode(block.input or {})
        table.insert(calls, {
          id = block.id,
          name = block.name,
          arguments_bytes = #args,
          arguments_hash = audit_hash(args),
          arguments_preview = audit_preview(args)
        })
      end
    end
  end
  return calls
end

---Build a request audit that explains what the provider will see without
---duplicating full prompts, file contents, or tool outputs.
---@param agent assistant.Agent
---@param conversation assistant.Conversation
---@param payload table
---@param round integer
---@return table
local function request_audit_payload(agent, conversation, payload, round)
  local messages = type(payload) == "table" and type(payload.messages) == "table" and payload.messages or {}
  local message_summaries = {}
  local totals = {
    messages = #messages,
    content_bytes = 0,
    tool_calls = 0,
    tool_results = 0,
    duplicate_tool_notices = 0,
    loop_warnings = 0
  }
  local tool_result_counts = {}
  for index, message in ipairs(messages) do
    local text = provider_message_text(message)
    local calls = provider_message_tool_calls(message)
    local role = tostring(type(message) == "table" and (message.role or message.type) or "")
    totals.content_bytes = totals.content_bytes + #text
    totals.tool_calls = totals.tool_calls + #calls
    if role == "user" and type(message.content) == "table" then
      for _, block in ipairs(message.content) do
        if type(block) == "table" and block.type == "tool_result" then
          totals.tool_results = totals.tool_results + 1
          local tool_name = tostring(block.content or ""):match("^Tool `([^`]+)` result:")
          if tool_name then
            tool_result_counts[tool_name] = (tool_result_counts[tool_name] or 0) + 1
          end
          if tostring(block.content or ""):find("Repeated tool call skipped", 1, true) then
            totals.duplicate_tool_notices = totals.duplicate_tool_notices + 1
          end
          if tostring(block.content or ""):find("repeated tool call loop detected", 1, true) then
            totals.loop_warnings = totals.loop_warnings + 1
          end
        end
      end
    end
    table.insert(message_summaries, {
      index = index,
      role = role,
      bytes = #text,
      hash = audit_hash(text),
      preview = audit_preview(text),
      tool_calls = #calls > 0 and calls or nil
    })
  end
  return {
    round = round or 0,
    agent = agent and agent.name,
    model = payload and payload.model or agent and agent.model,
    conversation_id = conversation and conversation.id,
    status = conversation and conversation.status,
    compact_tool_history = config.plugins.assistant.compact_tool_history == true,
    compact_tool_results = config.plugins.assistant.compact_tool_results == true,
    local_compaction = conversation and conversation.local_compaction and {
      message_count = conversation.local_compaction.message_count,
      summary_bytes = #(conversation.local_compaction.summary or "")
    } or nil,
    totals = totals,
    tool_result_counts = tool_result_counts,
    messages = message_summaries
  }
end

---Normalize plan items.
local function normalize_plan_items(items)
  if type(items) ~= "table" then return nil, "plan items must be an array" end
  local normalized = {}
  local in_progress = 0
  for _, item in ipairs(items) do
    if type(item) ~= "table" then return nil, "each plan item must be an object" end
    for key in pairs(item) do
      if key ~= "step" and key ~= "status" then
        return nil, "unsupported plan item field: " .. tostring(key)
      end
    end
    if type(item.step) ~= "string" or item.step == "" then
      return nil, "plan item is missing step"
    end
    if type(item.status) ~= "string" then
      return nil, "plan item is missing status"
    end
    local step = item.step
    local status = item.status
    if step == "" then return nil, "plan item is missing step" end
    if status ~= "pending" and status ~= "in_progress" and status ~= "completed" then
      return nil, "invalid plan status: " .. status
    end
    if status == "in_progress" then in_progress = in_progress + 1 end
    table.insert(normalized, { step = step, status = status })
  end
  if in_progress > 1 then return nil, "only one plan item can be in_progress" end
  return normalized
end

---Handle plan markdown.
local function plan_markdown(explanation, items)
  local lines = { "### Plan Updated" }
  if explanation and explanation ~= "" then
    table.insert(lines, "")
    table.insert(lines, tostring(explanation))
  end
  table.insert(lines, "")
  for _, item in ipairs(items or {}) do
    if item.status == "completed" then
      table.insert(lines, string.format("- [x] %s", item.step))
    elseif item.status == "in_progress" then
      table.insert(lines, string.format("- [ ] **%s** _(in progress)_", item.step))
    else
      table.insert(lines, string.format("- [ ] %s", item.step))
    end
  end
  return table.concat(lines, "\n")
end

---Normalize user options.
local function normalize_user_options(options)
  local result = {}
  if type(options) ~= "table" then return result end
  for _, option in ipairs(options) do
    if type(option) == "table" then
      table.insert(result, {
        label = tostring(option.label or option.value or ""),
        value = tostring(option.value or option.label or ""),
        description = option.description
      })
    else
      table.insert(result, {
        label = tostring(option),
        value = tostring(option)
      })
    end
  end
  return result
end

---Normalize user input questions.
local function normalize_user_input_questions(arguments)
  local result = {}
  if type(arguments) ~= "table" then arguments = {} end
  if type(arguments.questions) == "table" then
    for index, question in ipairs(arguments.questions) do
      if type(question) == "table" then
        local id = question.id or tostring(index)
        table.insert(result, {
          id = tostring(id),
          header = tostring(question.header or question.question or "Question"),
          question = tostring(question.question or question.header or "Assistant question"),
          options = normalize_user_options(question.options),
          allow_other = question.isOther == true or question.allow_other == true or question.allowOther == true or #normalize_user_options(question.options) == 0,
          is_secret = question.isSecret == true or question.is_secret == true
        })
      end
      if #result >= 3 then break end
    end
  end
  if #result == 0 then
    table.insert(result, {
      id = "answer",
      header = "Question",
      question = "Assistant question",
      options = {},
      allow_other = true
    })
  end
  return result
end

---Format user input tool result.
local function format_user_input_tool_result(request, answers)
  local result = { answers = {} }
  for _, question in ipairs(request and request.questions or {}) do
    local answer = answers and answers[question.id]
    local values = {}
    if type(answer) == "table" then
      values = answer.answers or answer
    elseif answer ~= nil then
      values = { tostring(answer) }
    end
    result.answers[question.id] = { answers = values }
  end
  return jsonutil.encode(result)
end

---Parse Anthropic named SSE chunk.
---
---Anthropic uses `event:` and `data:` lines separated by double newlines.
---Returns parsed events as (event_type, data) pairs via on_event callback.
---@param chunk string
---@param pending string
---@param on_event fun(event_type: string, data: string)
---@return string pending
local function parse_anthropic_sse_chunk(chunk, pending, on_event)
  pending = (pending .. chunk):gsub("\r\n", "\n")
  while true do
    local idx = pending:find("\n\n", 1, true)
    if not idx then break end
    local raw = pending:sub(1, idx - 1)
    pending = pending:sub(idx + 2)
    local event_type = "message"
    local data_lines = {}
    for line in (raw .. "\n"):gmatch("(.-)\n") do
      local ev = line:match("^event:%s?(.*)$")
      if ev then event_type = ev end
      local dv = line:match("^data:%s?(.*)$")
      if dv then table.insert(data_lines, dv) end
    end
    if #data_lines > 0 then
      on_event(event_type, table.concat(data_lines, "\n"))
    end
  end
  return pending
end

---Handle flush anthropic stream pending.
local function flush_anthropic_stream_pending(pending, on_event)
  if pending == "" then return end
  parse_anthropic_sse_chunk(pending .. "\n\n", "", on_event)
end

---Handle finalize anthropic stream tool calls.
local function finalize_anthropic_stream_tool_calls(collected)
  local indexes = {}
  for index in pairs(collected) do
    table.insert(indexes, index)
  end
  table.sort(indexes)
  local calls = {}
  for _, index in ipairs(indexes) do
    local item = collected[index]
    if item and item.name and item.name ~= "" then
      local arguments = {}
      local ok, decoded = pcall(json.decode, item.arguments_text)
      if ok and type(decoded) == "table" then arguments = decoded end
      table.insert(calls, {
        id = item.id or ("call_anthropic_" .. tostring(index)),
        name = item.name,
        arguments = arguments,
        arguments_text = item.arguments_text,
        format = "anthropic",
        raw = {
          type = "tool_use",
          id = item.id,
          name = item.name,
          input = arguments
        }
      })
    end
  end
  return calls
end

---Return whether tool payload is available.
local function has_tool_payload(agent)
  return agent
    and agent.has_capability
    and agent:has_capability("tool_calling")
    and agent.has_tools
    and agent:has_tools()
end

---Handle can parse tool calls.
local function can_parse_tool_calls(agent)
  return agent
    and agent.has_capability
    and agent:has_capability("tool_calling")
    and agent.parse_tool_calls
end

---Handle supports stream tool calls.
local function supports_stream_tool_calls(agent)
  if not (agent and agent.supports_stream_tool_calls) then return false end
  return agent:supports_stream_tool_calls() == true
end

---Handle tool allowed for mode.
local function tool_allowed_for_mode(agent, conversation, name)
  if not (agent and agent.tool_names_for_mode) then return true end
  local selected = agent:tool_names_for_mode(conversation)
  if type(selected) ~= "table" then return true end
  for _, allowed in ipairs(selected) do
    if allowed == name then return true end
  end
  return false
end

---Return whether a tool call list includes a resolved tool name.
local function calls_include_tool(agent, calls, name)
  for _, call in ipairs(calls or {}) do
    local resolved = agent and agent.resolve_tool_name and agent:resolve_tool_name(call and call.name) or (call and call.name)
    if resolved == name then return true end
  end
  return false
end

---Handle plan mode tool block reason.
local function plan_mode_tool_block_reason(call)
end

---List models.
---@param agent assistant.Agent
---@param callback fun(ok: boolean, err?: string, models?: string[])
function AnthropicBackend:list_models(agent, callback)
  self:begin_request()
  agent:set_loading(true)
  -- Anthropic has no public model listing endpoint; return curated list.
  local known_models = {
    "claude-sonnet-4-20250514",
    "claude-sonnet-4-20250514",
    "claude-3-5-sonnet-20241022",
    "claude-3-5-haiku-20241022",
    "claude-opus-4-20250514",
    "claude-3-opus-20240229",
    "claude-3-haiku-20240307"
  }
  agent:set_loading(false)
  self:finish_request()
  callback(true, nil, known_models)
end

---Handle refresh model metadata.
local function refresh_model_metadata(agent, conversation, callback)
  local conf = config.plugins and config.plugins.assistant or {}
  if conf.fetch_model_metadata == false then
    callback()
    return
  end
  if not (agent
    and agent.get_model_metadata_url
    and agent.build_model_metadata_payload
    and agent.parse_model_metadata)
  then
    callback()
    return
  end
  local model = tostring(agent.model or "")
  if model == "" or agent._assistant_metadata_model == model then
    callback()
    return
  end
  local url = join_url(agent.base_url, agent:get_model_metadata_url())
  local payload = agent:build_model_metadata_payload()
  local body = jsonutil.encode(payload)
  if conversation and conversation.append_raw_response then
    conversation:append_raw_response("anthropic-model-metadata-request", payload)
  end
  http.post(url, "application/json", nil, {
    headers = agent:get_headers(),
    body = body,
    timeout = provider_timeout(agent),
    is_cancelled = function() return false end,
    on_done = function(ok, _, result, info)
      if ok and not is_http_error(info) then
        if conversation and conversation.append_raw_response then
          conversation:append_raw_response("anthropic-model-metadata-response", result)
        end
        local metadata = agent:parse_model_metadata(result)
        if metadata then
          agent.model_metadata = common.merge(agent.model_metadata or {}, metadata)
          if conversation and conversation.options and metadata.context_window then
            conversation.options.context = metadata.context_window
          end
          agent._assistant_metadata_model = model
        end
      end
      callback()
    end
  })
end

---Handle local compact.
---@param agent assistant.Agent
---@param conversation assistant.Conversation
---@param callback fun(ok: boolean, err?: string)
function AnthropicBackend:local_compact(agent, conversation, callback)
  if not (agent and agent.has_capability and agent:has_capability("local_compact")) then
    callback(false, "agent does not support local compaction")
    return
  end
  self:begin_request()
  agent:set_loading(true)
  conversation:set_status("compacting", { autosave = false })
  local url = join_url(agent.base_url, agent.endpoint)
  local payload = agent:build_compact_payload(conversation)
  local body = jsonutil.encode(payload)
  conversation:append_raw_response("anthropic-compact-request", payload)
  http.post(url, "application/json", nil, {
    headers = agent:get_headers(),
    body = body,
    is_cancelled = function() return self:is_cancelled() end,
    on_done = function(ok, err, result, info)
      self:finish_request()
      agent:set_loading(false)
      if ok and not is_http_error(info) then
        conversation:append_raw_response("anthropic-compact-response", result)
        local summary = agent:parse_response(result)
        if summary and summary ~= "" then
          local compaction_trigger = conversation._assistant_compaction_trigger or "manual"
          conversation._assistant_compaction_trigger = nil
          conversation:record_local_compaction(summary, {
            trigger = compaction_trigger,
            usage = agent:parse_usage(result)
          })
          conversation:set_status("idle", { autosave = false })
          callback(true, nil, summary, { info = info, usage = agent:parse_usage(result) })
        else
          conversation:set_status("error", { autosave = false })
          callback(false, "compaction returned an empty summary", nil, { info = info })
        end
      else
        conversation:set_status("error", { autosave = false })
        if result ~= nil then conversation:append_raw_response("anthropic-compact-error", result) end
        callback(false, request_error("Conversation compaction", agent, info, result, err), nil, { info = info })
      end
    end
  })
end

---Handle generate conversation title.
---@param agent assistant.Agent
---@param conversation assistant.Conversation
---@param prompt string
---@param callback fun(ok: boolean, err?: string, title?: string)
function AnthropicBackend:generate_conversation_title(agent, conversation, prompt, callback)
  if not (agent and agent.build_title_payload and agent.parse_title_response) then
    if callback then callback(false, "agent does not support conversation title generation") end
    return
  end
  local url = join_url(agent.base_url, agent.endpoint)
  local payload = agent:build_title_payload(prompt)
  local body = jsonutil.encode(payload)
  if conversation and conversation.append_raw_response then
    conversation:append_raw_response("anthropic-title-request", raw_request_payload(payload))
  end
  http.post(url, "application/json", nil, {
    headers = agent:get_headers(),
    body = body,
    timeout = provider_timeout(agent),
    is_cancelled = function() return self:is_cancelled() end,
    on_done = function(ok, err, result, info)
      if ok and not is_http_error(info) then
        if conversation and conversation.append_raw_response then
          conversation:append_raw_response("anthropic-title-response", result)
        end
        local title = agent:parse_title_response(result)
        if title and title ~= "" then
          callback(true, nil, title, { info = info })
        else
          callback(false, "conversation title response was empty", nil, { info = info })
        end
      else
        if conversation and conversation.append_raw_response and result ~= nil then
          conversation:append_raw_response("anthropic-title-error", result)
        end
        callback(false, request_error("Conversation title generation", agent, info, result, err), nil, { info = info })
      end
    end
  })
end

---Handle request error.
local function request_error(action, agent, info, result, fallback)
  local status = info and tonumber(info.status)
  local details = extract_error(result) or fallback
  if type(details) == "string" and details:lower():find("timed out", 1, true) then
    local timeout_ms = configured_timeout_ms(agent)
    local timeout_text = timeout_ms and string.format(" after %.0f seconds", timeout_ms / 1000) or ""
    return string.format(
      "%s timed out for %s%s. Increase `plugins.assistant.request_timeout_ms` for slower models.",
      action,
      agent.display_name or agent.name or "agent",
      timeout_text
    )
  end
  if not details and status == 429 then
    details = "rate limit or quota exceeded; check provider billing, usage limits, and retry later"
  end
  details = details or "request failed"
  if status then
    return string.format(
      "%s failed for %s: HTTP %d: %s",
      action,
      agent.display_name or agent.name or "agent",
      status,
      details
    )
  end
  return string.format(
    "%s failed for %s: %s",
    action,
    agent.display_name or agent.name or "agent",
    details
  )
end

---Handle send.
---@param agent assistant.Agent
---@param conversation assistant.Conversation
---@param callback fun(ok: boolean, err?: string, text?: string, meta?: table)
function AnthropicBackend:send(agent, conversation, callback)
  self:begin_request()
  agent:set_loading(true)
  conversation:set_status("running", { autosave = false })
  local url = join_url(agent.base_url, agent.endpoint)
  local chunks = {}
  local usage
  local stream_error
  local tools_enabled = has_tool_payload(agent)
  local parse_tools = can_parse_tool_calls(agent)
  local tool_call_counts = {}
  local tool_result_cache = {}

  ---Compact deferred tool results after a model continuation has completed.
  local function compact_after_done()
    compact_deferred_tool_results(agent, conversation)
    if conversation and conversation.save then conversation:save() end
  end

  ---Handle fail.
  local function fail(err, info, result)
    self.pending_tool_call = nil
    self.pending_user_input_tool = nil
    self:finish_request()
    agent:set_loading(false)
    conversation:set_status("error", { autosave = false })
    local raw_error = raw_error_payload(info, result, err)
    if raw_error ~= nil then conversation:append_raw_response("anthropic-error", raw_error) end
    callback(false, err, nil, { info = info })
  end

  ---Handle finish.
  local function finish(text, info, final_usage, finish_meta)
    self.pending_tool_call = nil
    self.pending_user_input_tool = nil
    self:finish_request()
    agent:set_loading(false)
    conversation:set_status("idle", { autosave = false })
    if is_plan_mode(agent, conversation) then
      text = sanitize_plan_response(text)
    end
    local meta = common.merge({
      done = true,
      info = info,
      usage = final_usage
    }, finish_meta or {})
    callback(true, nil, text or "", meta)
    compact_after_done()
  end

  ---Handle finish plan if complete.
  local function finish_plan_if_complete()
    if is_plan_mode(agent, conversation) and conversation_has_completed_plan(conversation) then
      finish("", nil, usage)
      return true
    end
    return false
  end

  ---Handle finish blocked plan tool.
  local function finish_blocked_plan_tool(call, reason)
    local name = tostring(call and call.name or "unknown")
    local message = reason or string.format(
      "Plan mode blocked the model's `%s` tool call because that tool is not available in the current collaboration mode. Switch to Implementation mode before creating, editing, deleting, patching, formatting, or otherwise changing project files.",
      name
    )
    add_tool_activity(agent, conversation, call, "blocked", message)
    finish(message, nil, usage)
  end

  local post_once
  ---Handle request tool approval.
  local function request_tool_approval(calls, round, defer_continuation)
    if not calls_include_tool(agent, calls, "implement_plan") and finish_plan_if_complete() then return end
    local max_rounds = max_tool_call_rounds()
    if max_rounds and round >= max_rounds then
      fail(string.format(
        "tool call round limit exceeded after %d model/tool round(s); stop and ask the user how to continue",
        max_rounds
      ))
      return
    end
    callback(true, nil, nil, { event = "finalize_pending_assistant" })
    local index = 1
    local function notify_activity_update(options)
      if type(options) ~= "table" then options = nil end
      local meta = {
        event = "activity_update",
        partial = true
      }
      for key, value in pairs(options or {}) do
        meta[key] = value
      end
      callback(true, nil, nil, meta)
    end

    ---Handle ask next.
    local function ask_next()
      local call = calls[index]
      if not call then
        if finish_plan_if_complete() then return end
        agent:set_loading(true)
        conversation:set_status("working", { autosave = false })
        post_once(round + 1)
        return
      end
      local resolved_name = agent.resolve_tool_name and agent:resolve_tool_name(call.name) or call.name
      if call.invalid_arguments then
        call.name = resolved_name
        local provider_message = agent:tool_call_provider_message(calls, index)
        conversation:add("tool_call", agent:tool_call_display(call), {
          meta = {
            call = call,
            provider_message = provider_message
          }
        })
        local result = string.format(
          "malformed tool call arguments for `%s`: provider streamed invalid JSON, so the tool was not executed. This often means the response was truncated by max_tokens while generating a large tool call. Retry with smaller arguments; for existing files prefer `edit` with exact oldText/newText replacements instead of rewriting the whole file with `write`.",
          tostring(resolved_name or call.name or "tool")
        )
        if call.invalid_arguments_error and call.invalid_arguments_error ~= "" then
          result = result .. "\n\nJSON error: " .. tostring(call.invalid_arguments_error)
        end
        add_tool_activity(agent, conversation, call, "failed", result)
        add_tool_result(agent, conversation, call, result, "error")
        notify_activity_update()
        index = index + 1
        ask_next()
        return
      end
      if not tool_allowed_for_mode(agent, conversation, resolved_name) then
        call.name = resolved_name
        if is_plan_mode(agent, conversation) then
          finish_blocked_plan_tool(call)
        else
          add_tool_activity(agent, conversation, call, "blocked")
          local unavailable_message = "tool is not available in the current collaboration mode"
          add_tool_result(agent, conversation, call, unavailable_message, "error")
          index = index + 1
          ask_next()
        end
        return
      end
      call.name = resolved_name
      local plan_block_reason = is_plan_mode(agent, conversation) and plan_mode_tool_block_reason(call)
      if plan_block_reason then
        finish_blocked_plan_tool(call, plan_block_reason)
        return
      end
      if resolved_name == "implement_plan" then
        add_tool_activity(agent, conversation, call, "waiting for confirmation")
        notify_activity_update({ force_transcript = true })
        finish("", nil, usage, {
          event = "implement_plan_request",
          request = {
            id = call.id or call.call_id or tostring(index),
            title = "Implement Plan?",
            body = "The assistant has finished planning. Switch to Implementation mode and start implementing the plan now?",
            prompt = "Implement the approved plan now. Use the plan from the conversation above as the implementation specification."
          }
        })
        return
      end
      if resolved_name == "update_plan" then
        local provider_message = agent:tool_call_provider_message(calls, index)
        conversation:add("tool_call", agent:tool_call_display(call), {
          meta = {
            call = call,
            provider_message = provider_message
          },
          autosave = false
        })
        add_tool_activity(agent, conversation, call, "running")
        notify_activity_update({ force_transcript = true })
        local explanation = call.arguments and call.arguments.explanation or nil
        local items, plan_err = normalize_plan_items(call.arguments and call.arguments.plan)
        if items and explanation ~= nil and type(explanation) ~= "string" then
          items, plan_err = nil, "explanation must be a string"
        end
        if items then
          conversation.assistant_plan = {
            explanation = explanation or "",
            items = items
          }
          conversation:add("assistant", plan_markdown(conversation.assistant_plan.explanation, items), {
            meta = { plan_update = true },
            autosave = false
          })
          notify_activity_update({ force_transcript = true })
          local result = "plan updated"
          if is_plan_mode(agent, conversation) then
            result = result .. "; if the plan is decision-complete, respond next with the final Markdown plan and do not call more tools"
          end
          add_tool_result(agent, conversation, call, result, "ok")
        else
          add_tool_result(agent, conversation, call, "plan update error: " .. tostring(plan_err), "error")
        end
        notify_activity_update({ force_transcript = true })
        local continue = function()
          index = index + 1
          ask_next()
        end
        if defer_continuation then
          resume_in_background({ resume = continue })
        else
          continue()
        end
        return
      elseif resolved_name == "request_user_input" then
        call.name = resolved_name
        local provider_message = agent:tool_call_provider_message(calls, index)
        local request = {
          id = call.id or call.call_id or tostring(index),
          title = "Assistant Question",
          questions = normalize_user_input_questions(call.arguments)
        }
        conversation:add("tool_call", agent:tool_call_display(call), {
          meta = {
            call = call,
            provider_message = provider_message
          },
          autosave = false
        })
        add_tool_activity(agent, conversation, call, "waiting for input")
        conversation:set_status("waiting for user input", { autosave = false })
        agent:set_loading(false)
        self.pending_user_input_tool = {
          agent = agent,
          conversation = conversation,
          call = call,
          resume = function()
            index = index + 1
            ask_next()
          end
        }
        callback(true, nil, nil, {
          event = "user_input_request",
          request = request
        })
        return
      end
      local signature = tool_call_signature(agent, call)
      tool_call_counts[signature] = (tool_call_counts[signature] or 0) + 1
      local provider_message = agent:tool_call_provider_message(calls, index)
      conversation:add("tool_call", agent:tool_call_display(call), {
        meta = {
          call = call,
          provider_message = provider_message
        }
      })
      add_tool_activity(agent, conversation, call, "requested")
      notify_activity_update()
      if tool_call_counts[signature] > 1 then
        local cached = tool_result_cache[signature]
        if not cached and tool_call_counts[signature] > max_repeated_tool_calls() then
          local result = string.format(
            "repeated tool call loop detected: `%s` was called %d times with the same arguments in one turn. Stop inspecting and proceed with the available results, or ask the user how to continue.",
            tostring(resolved_name or call.name or "tool"),
            tool_call_counts[signature]
          )
          add_tool_activity(agent, conversation, call, "completed", result)
          add_tool_result(agent, conversation, call, result, "error")
          fail(result)
          return
        end
        local result = "repeated tool call suppressed; the same tool and arguments were already executed in this turn."
        local status = "error"
        if cached then
          status = cached.status or "ok"
          result = tostring(cached.result or "")
          if tool_call_counts[signature] > 2 then
            result = result .. "\n\nThis exact tool call has already been answered. Do not call it again; continue with the available result and provide the next useful response."
          end
          if tool_call_counts[signature] > max_repeated_tool_calls() then
            result = result .. "\n\nThe same cached tool call has repeated too many times, so this tool loop is being stopped without running the tool again. No more tool calls will be available in the next continuation; provide the final answer using the available results."
            add_tool_activity(agent, conversation, call, "completed", result)
            add_tool_result(agent, conversation, call, result, status)
            conversation:set_status("working", { autosave = false })
            agent:set_loading(true)
            post_once(round + 1, true)
            return
          end
        end
        add_tool_activity(agent, conversation, call, cached and "completed" or "failed", result)
        add_tool_result(
          agent,
          conversation,
          call,
          result,
          status
        )
        index = index + 1
        ask_next()
        return
      end
      conversation:set_status("waiting for tool approval", { autosave = false })
      agent:set_loading(false)
      self.pending_tool_call = {
        agent = agent,
        conversation = conversation,
        call = call,
        signature = signature,
        result_cache = tool_result_cache,
        tool_call_counts = tool_call_counts,
        resume = function()
          index = index + 1
          ask_next()
        end
      }
      if is_plan_mode(agent, conversation)
        and resolved_name == "exec_command"
        and agent.classify_tool_call
        and agent:classify_tool_call(call, conversation).category == "read_only"
      then
        self:resolve_tool_call(agent, conversation, { id = call.id or call.call_id or tostring(index) }, "allow", notify_activity_update)
        return
      end
      if agent.tool_requires_approval and not agent:tool_requires_approval(call) then
        self:resolve_tool_call(agent, conversation, { id = call.id or call.call_id or tostring(index) }, "allow", notify_activity_update)
        return
      end
      if resolved_name == "exec_command"
        and conversation.command_prefix_approved
        and conversation:command_prefix_approved(command_tool_text(call))
      then
        self:resolve_tool_call(agent, conversation, { id = call.id or call.call_id or tostring(index) }, "allow", notify_activity_update)
        return
      end
      if conversation.tool_approved
        and conversation:tool_approved(resolved_name)
      then
        self:resolve_tool_call(agent, conversation, { id = call.id or call.call_id or tostring(index) }, "allow", notify_activity_update)
        return
      end
      local request_options = {
        { label = "Allow", decision = "allow", description = "Run this tool call once." }
      }
      if resolved_name == "exec_command" then
        local prefix = permission.command_prefix(command_tool_text(call))
        if prefix then
          table.insert(request_options, {
            label = "Allow for session",
            decision = "allow_session",
            description = "Run this command and auto-approve later commands starting with `" .. prefix .. "`."
          })
        else
          table.insert(request_options, {
            label = "Allow for session",
            decision = "allow_session",
            description = "Run this command and auto-approve later `exec_command` calls in this conversation."
          })
        end
      else
        table.insert(request_options, {
          label = "Allow for session",
          decision = "allow_session",
          description = "Run this tool call and auto-approve later `" .. tostring(resolved_name) .. "` calls in this conversation."
        })
      end
      table.insert(request_options, {
        label = "Deny",
        decision = "deny",
        description = "Return a denial result to the assistant."
      })
      callback(true, nil, nil, {
        event = "tool_call_request",
        request = {
          id = call.id or call.call_id or tostring(index),
          call = call,
          title = "Approve tool",
          body = agent:tool_call_display(call),
          options = request_options
        }
      })
    end

    ask_next()
  end

  ---Handle send streaming.
  local function send_streaming(payload, body, round, tools_available)
    local response_info
    local pending = ""
    local error_chunks = {}
    local content_blocks = {}
    local has_streamed_tool_calls = false
    local partial_text = ""
    local reasoning_text = ""
    local last_partial_at = 0
    local last_emitted_partial = nil
    local last_reasoning_update_at = 0
    local plan_stream_state
    local reasoning_activity_key = "anthropic:reasoning:"
      .. tostring(round or 0)
      .. ":"
      .. tostring(#(conversation.messages or {}) + 1)
    local raw_stream_entries = {}
    local last_raw_flush
    local RAW_STREAM_FLUSH_COUNT = 8
    local RAW_STREAM_FLUSH_INTERVAL = 0.25

    ---Handle flush raw stream events.
    local function flush_raw_stream_events(force)
      if #raw_stream_entries == 0 then return end
      local now = system.get_time()
      if not force
        and last_raw_flush
        and #raw_stream_entries < RAW_STREAM_FLUSH_COUNT
        and now - last_raw_flush < RAW_STREAM_FLUSH_INTERVAL
      then
        return
      end
      local batch = raw_stream_entries
      raw_stream_entries = {}
      last_raw_flush = now
      conversation:append_raw_responses(batch)
    end
    ---Handle record stream event.
    local function record_stream_event(event_type, data)
      table.insert(raw_stream_entries, {
        kind = "anthropic-stream-event",
        event = event_type,
        data = data
      })
      flush_raw_stream_events(false)
    end
    ---Handle emit partial.
    local function emit_partial(force)
      if partial_text == "" then return end
      if not partial_text:find("%S") then return end
      if looks_like_text_tool_call(partial_text) then return end
      if not force and not should_show_tool_preamble(partial_text) then return end
      if has_streamed_tool_calls and force then return end
      if #partial_text < 3 and not partial_text:find("%s") then return end
      if force and partial_text == last_emitted_partial then return end
      local now = system.get_time()
      if force or now - last_partial_at >= 0.05 then
        callback(true, nil, partial_text, { partial = true })
        last_partial_at = now
        last_emitted_partial = partial_text
      end
    end
    ---Handle emit reasoning.
    local function emit_reasoning(force)
      if reasoning_text == "" then return end
      local display_reasoning = reasoning_text:match("^%s*(.-)%s*$") or ""
      if display_reasoning == "" then return end
      local now = system.get_time()
      if force or now - last_reasoning_update_at >= 0.1 then
        conversation:set_status("reasoning", { autosave = false })
        if reasoning_activity_messages_enabled() then
          upsert_activity(conversation, "Reasoning\n\n" .. display_reasoning, reasoning_activity_key)
          callback(true, nil, nil, {
            event = "activity_update",
            partial = true
          })
        end
        last_reasoning_update_at = now
      end
    end
    ---Handle apply stream event.
    local function apply_stream_event(event_type, data, emit_text)
      record_stream_event(event_type, data)
      local decoded = json.decode(data)
      if type(decoded) ~= "table" then return end

      if event_type == "message_start" then
        local msg = decoded.message
        if msg and msg.usage then
          usage = agent:parse_usage(msg.usage)
          if usage and conversation.set_usage then
            conversation:set_usage(usage)
          end
        end
        return
      end

      if event_type == "content_block_start" then
        local block = decoded.content_block or {}
        local index = decoded.index or 0
        content_blocks[index] = {
          type = block.type,
          id = block.id,
          name = block.name,
          text = "",
          arguments_text = ""
        }
        if block.type == "thinking" then
          reasoning_text = reasoning_text .. tostring(block.text or "")
          emit_reasoning(false)
        end
        return
      end

      if event_type == "content_block_delta" then
        local delta = decoded.delta or {}
        local index = decoded.index or 0
        local block = content_blocks[index]
        if delta.type == "text_delta" then
          local text = delta.text or ""
          if block then block.text = (block.text or "") .. text end
          table.insert(chunks, text)
          partial_text = partial_text .. text
          if emit_text then emit_partial(false) end
        elseif delta.type == "input_json_delta" then
          local partial = delta.partial_json or ""
          if block then block.arguments_text = (block.arguments_text or "") .. partial end
        elseif delta.type == "thinking_delta" then
          local text = delta.text or ""
          reasoning_text = reasoning_text .. text
          emit_reasoning(false)
        elseif delta.type == "signature_delta" then
          -- signature for continued thinking; ignore for display
        end
        return
      end

      if event_type == "content_block_stop" then
        local index = decoded.index or 0
        local block = content_blocks[index]
        if block and block.type == "tool_use" and block.name and block.name ~= "" then
          has_streamed_tool_calls = true
        end
        return
      end

      if event_type == "message_delta" then
        local delta = decoded.delta or {}
        local stop_reason = delta.stop_reason
        local msg_usage = decoded.usage
        if msg_usage then
          usage = agent:parse_usage(msg_usage)
          if usage and conversation.set_usage then
            conversation:set_usage(usage)
          end
        end
        if stop_reason == "end_turn" or stop_reason == "stop_sequence" then
          -- done, will be finalized on message_stop
        elseif stop_reason == "tool_use" then
          has_streamed_tool_calls = true
        end
        return
      end

      if event_type == "message_stop" then
        -- Finalize; tool calls are collected from content_blocks
        return
      end

      if event_type == "ping" then
        return
      end
    end

    http.request("POST", url, {
      method = "POST",
      headers = agent:get_headers(),
      body = body,
      timeout = provider_timeout(agent),
      is_cancelled = function() return self:is_cancelled() end,
      on_header = function(info)
        response_info = info
      end,
      on_chunk = function(chunk)
        if is_http_error(response_info) then
          table.insert(error_chunks, chunk)
          return
        end
        pending = parse_anthropic_sse_chunk(chunk, pending, function(event_type, data)
          apply_stream_event(event_type, data, true)
        end)
      end,
      on_done = function(ok, err, _, info)
        self:finish_request()
        agent:set_loading(false)
        info = info or response_info
        if ok and not is_http_error(info) then
          if pending ~= "" then
            flush_anthropic_stream_pending(pending, function(event_type, data)
              apply_stream_event(event_type, data, false)
            end)
          end
          emit_reasoning(true)
          flush_raw_stream_events(true)
          local final_text = table.concat(chunks)
          local tool_calls = {}
          if tools_available and parse_tools then
            local indexes = {}
            for index in pairs(content_blocks) do
              table.insert(indexes, index)
            end
            table.sort(indexes)
            for _, index in ipairs(indexes) do
              local block = content_blocks[index]
              if block and block.type == "tool_use" and block.name and block.name ~= "" then
                local arguments = {}
                local ok_decode, decoded = pcall(json.decode, block.arguments_text or "{}")
                if ok_decode and type(decoded) == "table" then arguments = decoded end
                local invalid_arguments = block.arguments_text
                  and block.arguments_text ~= ""
                  and not (ok_decode and type(decoded) == "table")
                table.insert(tool_calls, {
                  id = block.id or ("call_anthropic_" .. tostring(index)),
                  name = block.name,
                  arguments = arguments,
                  arguments_text = block.arguments_text or "{}",
                  invalid_arguments = invalid_arguments,
                  invalid_arguments_error = invalid_arguments and tostring(decoded) or nil,
                  format = "anthropic",
                  raw = {
                    type = "tool_use",
                    id = block.id,
                    name = block.name,
                    input = arguments
                  }
                })
              end
            end
            if #tool_calls == 0 and agent.parse_text_tool_calls then
              tool_calls = agent:parse_text_tool_calls(final_text)
            end
          end
          local final_is_completed_plan = is_plan_mode(agent, conversation)
            and final_text
            and contains_completed_plan(final_text)
          if stream_error then
            conversation:set_status("error", { autosave = false })
            conversation:append_raw_response("anthropic-stream-error", stream_error)
            callback(false, request_error("Chat request", agent, info, stream_error, err), nil, { info = info })
          elseif has_streamed_tool_calls and final_is_completed_plan then
            conversation:set_status("idle", { autosave = false })
            callback(true, nil, sanitize_plan_response(final_text), { done = true, info = info, usage = usage })
            compact_after_done()
          elseif has_streamed_tool_calls and #tool_calls > 0 then
            compact_after_done()
            chunks = {}
            partial_text = ""
            request_tool_approval(tool_calls, round or 0, true)
          elseif tool_calls and #tool_calls > 0 then
            compact_after_done()
            chunks = {}
            partial_text = ""
            request_tool_approval(tool_calls, round or 0, true)
          else
            emit_partial(true)
            conversation:set_status("idle", { autosave = false })
            if is_plan_mode(agent, conversation) then
              final_text = sanitize_plan_response(final_text)
            end
            final_text = strip_text_tool_call_blocks(final_text)
            callback(true, nil, final_text, { done = true, info = info, usage = usage })
            compact_after_done()
          end
        else
          flush_raw_stream_events(true)
          local error_body = decode_error_body(table.concat(error_chunks))
          local raw_error = raw_error_payload(info, error_body, err)
          conversation:set_status("error", { autosave = false })
          if raw_error ~= nil then conversation:append_raw_response("anthropic-error", raw_error) end
          callback(false, request_error("Chat request", agent, info, raw_error, err), nil, { info = info })
        end
      end
    })
  end

  post_once = function(round, without_tools)
    if self:is_cancelled() then
      fail("request cancelled")
      return
    end
    round = round or 0
    local payload = agent:build_payload(conversation)
    local tools_available = tools_enabled and not without_tools
    if without_tools then
      payload.tools = nil
    end
    local body = jsonutil.encode(payload)
    conversation:append_raw_response("anthropic-request", raw_request_payload(payload))
    conversation:append_raw_response("anthropic-request-audit", request_audit_payload(agent, conversation, payload, round))

    if payload.stream then
      send_streaming(payload, body, round, tools_available)
      return
    end

    http.post(url, "application/json", nil, {
      headers = agent:get_headers(),
      body = body,
      timeout = provider_timeout(agent),
      is_cancelled = function() return self:is_cancelled() end,
      on_done = function(ok, err, result, info)
        if ok and not is_http_error(info) then
          conversation:append_raw_response("anthropic-response", result)
          local tool_calls = tools_available and parse_tools and agent:parse_tool_calls(result) or {}
          local response_text = agent:parse_response(result)
          local parsed_usage = agent:parse_usage(result)
          if parsed_usage and conversation.set_usage then
            conversation:set_usage(parsed_usage)
          end
          if tool_calls and #tool_calls > 0 and is_plan_mode(agent, conversation) and contains_completed_plan(response_text) then
            finish(response_text, info, parsed_usage)
          elseif tool_calls and #tool_calls > 0 then
            compact_after_done()
            request_tool_approval(tool_calls, round, false)
          else
            response_text = strip_text_tool_call_blocks(response_text)
            finish(response_text, info, parsed_usage)
          end
        else
          fail(request_error("Chat request", agent, info, result, err), info, result or err)
        end
      end
    })
  end

  refresh_model_metadata(agent, conversation, function()
    if self:is_cancelled() then
      fail("request cancelled")
      return
    end
    post_once(0)
  end)
end

---Resolve tool call.
---@param agent assistant.Agent
---@param conversation assistant.Conversation
---@param request table
---@param decision string
---@param callback fun(ok: boolean, err?: string)
function AnthropicBackend:resolve_tool_call(agent, conversation, request, decision, callback)
  local pending = self.pending_tool_call
  if not pending or pending.conversation ~= conversation then
    if callback then callback(false, "no pending tool call") end
    return
  end
  self.pending_tool_call = nil
  local call = pending.call
  local allowed = decision == "accept" or decision == "allow"
    or decision == "allow_session"
  if not allowed then
    local result = "user denied tool execution"
    conversation:set_status("tool denied", { autosave = false })
    add_tool_activity(agent, conversation, call, "denied", result)
    add_tool_result(agent, conversation, call, result, "error")
    if callback then callback(true) end
    resume_in_background(pending)
    return
  end

  if decision == "allow_session"
    and call.name == "exec_command"
    and conversation.approve_command_prefix
  then
    local prefix = permission.command_prefix(command_tool_text(call))
    if prefix then
      conversation:approve_command_prefix(prefix)
    elseif conversation.approve_tool then
      conversation:approve_tool(call.name)
    end
  elseif decision == "allow_session"
    and conversation.approve_tool
  then
    conversation:approve_tool(call.name)
  end

  conversation:set_status("calling tool", { autosave = false })
  agent:set_loading(true)
  local cancel_epoch = self.cancel_epoch
  core.add_background_thread(function()
    local previous_confirm = assistant_tools.set_confirm_write(function()
      return true
    end)
    local protected_ok, ok, result = pcall(function()
      local previous_conversation = agent._assistant_tool_conversation
      agent._assistant_tool_conversation = conversation
      local execute_ok, tool_ok, tool_result = pcall(function()
        return agent:execute_tool(call)
      end)
      agent._assistant_tool_conversation = previous_conversation
      if not execute_ok then error(tool_ok) end
      return tool_ok, tool_result
    end)
    assistant_tools.set_confirm_write(previous_confirm)
    if not protected_ok then
      result = ok or "unknown tool exception"
      ok = false
    end
    if not ok then
      result = "tool error: " .. tostring(result or "unknown error")
    end
    if self:is_cancelled(cancel_epoch) then
      if callback then callback(false, "request cancelled") end
      return
    end
    add_tool_activity(agent, conversation, call, ok and "completed" or "failed", result)
    if pending.result_cache and pending.signature then
      if ok and tool_call_may_mutate_project(agent, conversation, call) then
        clear_table(pending.result_cache)
        clear_table(pending.tool_call_counts)
      end
      pending.result_cache[pending.signature] = {
        status = ok and "ok" or "error",
        result = result
      }
    end
    add_tool_result(agent, conversation, call, result, ok and "ok" or "error")
    conversation:set_status("working", { autosave = false })
    agent:set_loading(true)
    if callback then callback(true) end
    resume_in_background(pending)
  end)
end

---Resolve user input.
---@param agent assistant.Agent
---@param conversation assistant.Conversation
---@param request table
---@param ok boolean
---@param answers table|nil
---@param callback fun(ok: boolean, err?: string)
function AnthropicBackend:resolve_user_input(agent, conversation, request, ok, answers, callback)
  local pending = self.pending_user_input_tool
  if not pending or pending.conversation ~= conversation then
    if callback then callback(false, "no pending user input request") end
    return
  end
  self.pending_user_input_tool = nil
  local call = pending.call
  if ok then
    local result = format_user_input_tool_result(request, answers or {})
    add_tool_activity(agent, conversation, call, "answered", result)
    add_tool_result(agent, conversation, call, result, "ok")
  else
    add_tool_activity(agent, conversation, call, "cancelled", "user cancelled input request")
    add_tool_result(agent, conversation, call, "user cancelled input request", "error")
  end
  conversation:set_status("running", { autosave = false })
  agent:set_loading(true)
  if callback then callback(true) end
  if pending.resume then pending.resume() end
end

return AnthropicBackend
