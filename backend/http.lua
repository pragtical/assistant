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

---HTTP backend for OpenAI-compatible chat and Responses providers.
---@class assistant.backend.HttpBackend : assistant.Backend
---@field pending_tool_call table|nil
---@field pending_user_input_tool table|nil
local HttpBackend = Backend:extend()

---Create a new instance.
function HttpBackend:new()
  self.super.new(self, "http")
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

---Handle should show tool preamble.
local function should_show_tool_preamble(text)
  text = tostring(text or ""):match("^%s*(.-)%s*$") or ""
  if text == "" then return false end
  if text:find("\n") then return true end
  if text:find("[%.%!%?:]") then return true end
  return #text >= 40
end

local PRIVATE_THINKING_TAGS = {
  ["<antThinking>"] = "</antThinking>",
  ["<thinking>"] = "</thinking>",
  ["<think>"] = "</think>"
}

---Handle private tag prefix at end.
local function private_tag_prefix_at_end(text)
  local max_keep = math.min(#text, 20)
  for length = max_keep, 1, -1 do
    local suffix = text:sub(#text - length + 1)
    for tag in pairs(PRIVATE_THINKING_TAGS) do
      if tag:sub(1, length) == suffix then return suffix end
    end
  end
  return nil
end

---Handle filter private thinking delta.
local function filter_private_thinking_delta(state, text)
  text = tostring(text or "")
  if text == "" then return "" end
  state.buffer = tostring(state.buffer or "") .. text
  local pending = state.buffer
  state.buffer = ""
  local output = {}
  while pending ~= "" do
    if state.close_tag then
      local close_at = pending:find(state.close_tag, 1, true)
      if not close_at then return table.concat(output) end
      pending = pending:sub(close_at + #state.close_tag)
      state.close_tag = nil
    else
      local first_at, first_open, first_close
      for open_tag, close_tag in pairs(PRIVATE_THINKING_TAGS) do
        local at = pending:find(open_tag, 1, true)
        if at and (not first_at or at < first_at) then
          first_at = at
          first_open = open_tag
          first_close = close_tag
        end
      end
      if first_at then
        table.insert(output, pending:sub(1, first_at - 1))
        pending = pending:sub(first_at + #first_open)
        state.close_tag = first_close
      else
        local keep = private_tag_prefix_at_end(pending)
        if keep then
          table.insert(output, pending:sub(1, #pending - #keep))
          state.buffer = keep
        else
          table.insert(output, pending)
        end
        pending = ""
      end
    end
  end
  return table.concat(output)
end

---Handle looks like text tool call.
local function looks_like_text_tool_call(text)
  text = tostring(text or ""):match("^%s*(.-)%s*$") or ""
  if text == "" then return false end
  text = text:gsub("&lt;", "<"):gsub("&gt;", ">")
  return text:find("^<function_calls>", 1, true) ~= nil
    or text:find("^<tool_call>", 1, true) ~= nil
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
  text = text:gsub("<function%s*=%s*['\"]?[%w_%.%-]+['\"]?%s*>.-</function%s*>", "")
  text = text:gsub("<invoke%s+name%s*=%s*['\"]?[%w_%.%-]+['\"]?%s*>.-</invoke%s*>", "")
  return text
end

---Parse text tool calls.
local function parse_text_tool_calls(agent, content)
  if not (agent and agent.parse_tool_calls) then return {} end
  return agent:parse_tool_calls({
    choices = {
      {
        message = {
          role = "assistant",
          content = content
        }
      }
    }
  })
end

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
  text = stream_state.strip_plan_drafted_marker(text)
  return text:match("^%s*(.-)%s*$") or text
end

---Handle request error.
local function request_error(action, agent, info, result, fallback)
  local status = info and tonumber(info.status)
  local details = extract_error(result) or fallback
  if type(details) == "string" and details:lower():find("timed out", 1, true) then
    local timeout_ms = configured_timeout_ms(agent)
    local timeout_text = timeout_ms and string.format(" after %.0f seconds", timeout_ms / 1000) or ""
    return string.format(
      "%s timed out for %s%s. Increase `plugins.assistant.request_timeout_ms` for slower local models.",
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

---Parse sse chunk.
local function parse_sse_chunk(chunk, pending, on_event)
  pending = (pending .. chunk):gsub("\r\n", "\n")
  while true do
    local idx = pending:find("\n\n", 1, true)
    if not idx then break end
    local raw = pending:sub(1, idx - 1)
    pending = pending:sub(idx + 2)
    local data = {}
    for line in (raw .. "\n"):gmatch("(.-)\n") do
      local value = line:match("^data:%s?(.*)$")
      if value then table.insert(data, value) end
    end
    if #data > 0 then on_event(table.concat(data, "\n")) end
  end
  return pending
end

---Parse jsonl chunk.
local function parse_jsonl_chunk(chunk, pending, on_event)
  pending = pending .. chunk
  while true do
    local idx = pending:find("\n", 1, true)
    if not idx then break end
    local line = pending:sub(1, idx - 1)
    pending = pending:sub(idx + 1)
    if line:sub(-1) == "\r" then
      line = line:sub(1, -2)
    end
    if line ~= "" then on_event(line) end
  end
  return pending
end

---Parse stream chunk.
local function parse_stream_chunk(agent, chunk, pending, on_event)
  if agent.stream_format == "jsonl" then
    return parse_jsonl_chunk(chunk, pending, on_event)
  end
  return parse_sse_chunk(chunk, pending, on_event)
end

---Handle flush stream pending.
local function flush_stream_pending(agent, pending, on_event)
  if pending == "" then return end
  if agent.stream_format == "jsonl" then
    parse_jsonl_chunk(pending .. "\n", "", on_event)
  else
    parse_sse_chunk(pending .. "\n\n", "", on_event)
  end
end

local RAW_STREAM_FLUSH_COUNT = 8
local RAW_STREAM_FLUSH_INTERVAL = 0.25

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

---Handle provider timeout.
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

---Return whether reasoning_content should be stored for this agent.
local function should_persist_reasoning_content(agent)
  return agent
    and agent.should_persist_reasoning_content
    and agent:should_persist_reasoning_content()
end

---Attach provider reasoning_content to the first tool call in an assistant call group.
local function attach_reasoning_content_to_calls(agent, calls, reasoning)
  if not should_persist_reasoning_content(agent) then return end
  if type(reasoning) ~= "string" or reasoning == "" then return end
  if type(calls) ~= "table" or type(calls[1]) ~= "table" then return end
  calls[1]._assistant_provider_reasoning_content = reasoning
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

---Return the status that should be persisted in transcript activity.
---@param status string|nil
---@return string|nil status
---@return boolean skip
local function persisted_tool_activity_status(status)
  status = tostring(status or "")
  if status == "" or status == "requested" then return nil, false end
  if status == "completed"
    or status == "answered"
    or status == "running"
    or status == "waiting for confirmation"
    or status == "waiting for input"
  then
    return nil, true
  end
  return status, false
end

---Add tool activity.
local function add_tool_activity(agent, conversation, call, status, result)
  local name = call and (agent.resolve_tool_name and agent:resolve_tool_name(call.name) or call.name) or "unknown"
  if call then call.name = name end
  local persisted_status, skip = persisted_tool_activity_status(status)
  if skip then return end
  status = persisted_status
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
  upsert_activity(conversation, verbose, "tool:" .. tostring(name) .. ":" .. tostring(id), compact)
end

---Resume a pending backend continuation without depending on editor focus.
local function resume_in_background(pending)
  if not (pending and pending.resume) then return end
  core.add_background_thread(function()
    pending.resume()
  end)
end

---Append stream tool calls.
local function append_stream_tool_calls(collected, deltas)
  for _, delta in ipairs(deltas or {}) do
    local index = delta.index or delta.item_id or 0
    local item = collected[index]
    if not item then
      item = {
        index = index,
        order = tonumber(delta.index),
        id = delta.id,
        call_id = delta.call_id,
        item_id = delta.item_id,
        format = delta.format,
        type = delta.type or "function",
        name = "",
        arguments_text = ""
      }
      collected[index] = item
    end
    item.id = delta.id or item.id
    item.call_id = delta.call_id or item.call_id
    item.item_id = delta.item_id or item.item_id
    item.format = delta.format or item.format
    item.order = tonumber(delta.index) or item.order
    item.type = delta.type or item.type or "function"
    if delta.name and delta.name ~= "" then
      if delta.format == "responses" then
        item.name = delta.name
      else
        item.name = item.name .. delta.name
      end
    end
    if delta.final_arguments ~= nil then
      item.arguments_text = delta.final_arguments
    elseif delta.arguments and delta.arguments ~= "" then
      item.arguments_text = item.arguments_text .. delta.arguments
    end
  end
end

---Handle unescape json stringish.
local function unescape_json_stringish(text)
  text = tostring(text or "")
  return (text:gsub("\\u(%x%x%x%x)", function(hex)
      local value = tonumber(hex, 16)
      if value and value < 128 then return string.char(value) end
      return "\\u" .. hex
    end)
    :gsub('\\"', '"')
    :gsub("\\\\", "\\")
    :gsub("\\/", "/")
    :gsub("\\b", "\b")
    :gsub("\\f", "\f")
    :gsub("\\n", "\n")
    :gsub("\\r", "\r")
    :gsub("\\t", "\t"))
end

---Handle extract string argument.
local function extract_string_argument(arguments_text, key)
  local marker = '"' .. key .. '"'
  local at = tostring(arguments_text or ""):find(marker, 1, true)
  if not at then return nil end
  local colon = arguments_text:find(":", at + #marker, true)
  if not colon then return nil end
  local quote = arguments_text:find('"', colon + 1, true)
  if not quote then return nil end
  local index = quote + 1
  local escaped = false
  while index <= #arguments_text do
    local char = arguments_text:sub(index, index)
    if escaped then
      escaped = false
    elseif char == "\\" then
      escaped = true
    elseif char == '"' then
      return unescape_json_stringish(arguments_text:sub(quote + 1, index - 1))
    end
    index = index + 1
  end
  if key == "patch" then
    return unescape_json_stringish(arguments_text:sub(quote + 1))
  end
end

---Handle decode stream tool arguments.
local function decode_stream_tool_arguments(arguments_text)
  local ok, arguments = pcall(json.decode, arguments_text)
  if not ok then arguments = nil end
  if type(arguments) == "table" then return arguments end
  arguments = {}
  for _, key in ipairs({ "patch", "contents", "text", "path", "cmd", "workdir" }) do
    local value = extract_string_argument(arguments_text, key)
    if value ~= nil then arguments[key] = value end
  end
  return next(arguments) and arguments or {}
end

---Handle finalize stream tool calls.
local function finalize_stream_tool_calls(collected)
  local indexes = {}
  for index in pairs(collected) do
    table.insert(indexes, index)
  end
  table.sort(indexes, function(a, b)
    local item_a = collected[a]
    local item_b = collected[b]
    local order_a = item_a and item_a.order
    local order_b = item_b and item_b.order
    if order_a and order_b and order_a ~= order_b then return order_a < order_b end
    if order_a and not order_b then return true end
    if order_b and not order_a then return false end
    return tostring(a) < tostring(b)
  end)
  local calls = {}
  for _, index in ipairs(indexes) do
    local item = collected[index]
    if item and item.name and item.name ~= "" then
      local arguments = decode_stream_tool_arguments(item.arguments_text)
      local id = item.id or ("call_stream_" .. tostring(index))
      local format = item.format == "responses" and "responses" or "chat-stream"
      local raw
      if format == "responses" then
        raw = {
          type = "function_call",
          id = id,
          call_id = item.call_id or id,
          name = item.name,
          arguments = item.arguments_text
        }
      else
        raw = {
          id = id,
          type = item.type or "function",
          ["function"] = {
            name = item.name,
            arguments = item.arguments_text
          }
        }
      end
      table.insert(calls, {
        id = item.id or ("call_stream_" .. tostring(index)),
        call_id = item.call_id,
        name = item.name,
        arguments = arguments,
        arguments_text = item.arguments_text,
        format = format,
        raw = raw
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

---Handle summarize tool schema.
local function summarize_tool_schema(tool)
  if type(tool) ~= "table" then return tool end
  if tool["function"] then
    return {
      type = tool.type,
      ["function"] = {
        name = tool["function"].name
      }
    }
  end
  return {
    type = tool.type,
    name = tool.name
  }
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
      table.insert(tools, summarize_tool_schema(tool))
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
  if type(message.tool_calls) == "table" then
    for _, call in ipairs(message.tool_calls) do
      local fn = type(call) == "table" and type(call["function"]) == "table" and call["function"] or {}
      local args = tostring(fn.arguments or "")
      table.insert(calls, {
        id = call.id,
        name = fn.name,
        arguments_bytes = #args,
        arguments_hash = audit_hash(args),
        arguments_preview = audit_preview(args)
      })
    end
  elseif message.type == "function_call" then
    local args = tostring(message.arguments or "")
    table.insert(calls, {
      id = message.call_id or message.id,
      name = message.name,
      arguments_bytes = #args,
      arguments_hash = audit_hash(args),
      arguments_preview = audit_preview(args)
    })
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
    if role == "tool" or role == "function_call_output" then
      totals.tool_results = totals.tool_results + 1
      local tool_name = text:match("^Tool `([^`]+)` result:")
      if tool_name then
        tool_result_counts[tool_name] = (tool_result_counts[tool_name] or 0) + 1
      end
      if text:find("Repeated tool call skipped", 1, true) then
        totals.duplicate_tool_notices = totals.duplicate_tool_notices + 1
      end
      if text:find("repeated tool call loop detected", 1, true) then
        totals.loop_warnings = totals.loop_warnings + 1
      end
    end
    table.insert(message_summaries, {
      index = index,
      role = role,
      bytes = #text,
      hash = audit_hash(text),
      preview = audit_preview(text),
      tool_call_id = type(message) == "table" and (message.tool_call_id or message.call_id) or nil,
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

---List models.
---@param agent assistant.Agent
---@param callback fun(ok: boolean, err?: string, models?: string[])
function HttpBackend:list_models(agent, callback)
  self:begin_request()
  agent:set_loading(true)
  local url = join_url(agent.base_url, agent:get_models_url())
  http.get(url, nil, {
    headers = agent:get_headers(),
    is_cancelled = function() return self:is_cancelled() end,
    on_done = function(ok, err, result, info)
      agent:set_loading(false)
      self:finish_request()
      if ok and not is_http_error(info) then
        callback(true, nil, agent:parse_models_response(result), { info = info })
      else
        callback(false, request_error("Model listing", agent, info, result, err), nil, { info = info })
      end
    end
  })
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
    conversation:append_raw_response("http-model-metadata-request", payload)
  end
  http.post(url, "application/json", nil, {
    headers = agent:get_headers(),
    body = body,
    timeout = provider_timeout(agent),
    is_cancelled = function() return false end,
    on_done = function(ok, _, result, info)
      if ok and not is_http_error(info) then
        if conversation and conversation.append_raw_response then
          conversation:append_raw_response("http-model-metadata-response", result)
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
function HttpBackend:local_compact(agent, conversation, callback)
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
  conversation:append_raw_response("http-compact-request", payload)
  http.post(url, "application/json", nil, {
    headers = agent:get_headers(),
    body = body,
    is_cancelled = function() return self:is_cancelled() end,
    on_done = function(ok, err, result, info)
      self:finish_request()
      agent:set_loading(false)
      if ok and not is_http_error(info) then
        conversation:append_raw_response("http-compact-response", result)
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
        if result ~= nil then conversation:append_raw_response("http-compact-error", result) end
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
function HttpBackend:generate_conversation_title(agent, conversation, prompt, callback)
  if not (agent and agent.build_title_payload and agent.parse_title_response) then
    if callback then callback(false, "agent does not support conversation title generation") end
    return
  end
  local url = join_url(agent.base_url, agent.endpoint)
  local payload = agent:build_title_payload(prompt)
  local body = jsonutil.encode(payload)
  if conversation and conversation.append_raw_response then
    conversation:append_raw_response("http-title-request", raw_request_payload(payload))
  end
  http.post(url, "application/json", nil, {
    headers = agent:get_headers(),
    body = body,
    timeout = provider_timeout(agent),
    is_cancelled = function() return self:is_cancelled() end,
    on_done = function(ok, err, result, info)
      if ok and not is_http_error(info) then
        if conversation and conversation.append_raw_response then
          conversation:append_raw_response("http-title-response", result)
        end
        local title = agent:parse_title_response(result)
        if title and title ~= "" then
          callback(true, nil, title, { info = info })
        else
          callback(false, "conversation title response was empty", nil, { info = info })
        end
      else
        if conversation and conversation.append_raw_response and result ~= nil then
          conversation:append_raw_response("http-title-error", result)
        end
        callback(false, request_error("Conversation title generation", agent, info, result, err), nil, { info = info })
      end
    end
  })
end

---Handle send.
---@param agent assistant.Agent
---@param conversation assistant.Conversation
---@param callback fun(ok: boolean, err?: string, text?: string, meta?: table)
function HttpBackend:send(agent, conversation, callback)
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
    if raw_error ~= nil then conversation:append_raw_response("http-error", raw_error) end
    callback(false, err, nil, { info = info })
  end

  ---Handle finish.
  local function finish(text, info, final_usage, finish_meta)
    finish_meta = finish_meta or {}
    local auto_implement_plan = finish_meta.auto_implement_plan == true
    finish_meta.auto_implement_plan = nil
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
    if auto_implement_plan then
      callback(true, nil, nil, {
        event = "implement_plan_request",
        request = {
          id = "plan_drafted",
          title = "Implement Plan?",
          body = "The assistant has finished planning. Switch to Implementation mode and start implementing the plan now?",
          prompt = "Implement the approved plan now. Use the plan from the conversation above as the implementation specification."
        }
      })
    end
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
  local function continue_after_plan_tool_block(call, reason, continue)
    local name = tostring(call and call.name or "unknown")
    local message = reason or string.format(
      "Plan mode blocked the model's `%s` tool call because that tool is not available in the current collaboration mode. Present the implementation plan and call `implement_plan` to ask the user whether to switch to Implementation mode before creating, editing, deleting, patching, formatting, or otherwise changing project files.",
      name
    )
    add_tool_activity(agent, conversation, call, "blocked", message)
    add_tool_result(agent, conversation, call, message, "error")
    continue()
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
      if not tool_allowed_for_mode(agent, conversation, resolved_name) then
        call.name = resolved_name
        if is_plan_mode(agent, conversation) then
          local provider_message = agent:tool_call_provider_message(calls, index)
          conversation:add("tool_call", agent:tool_call_display(call), {
            meta = {
              call = call,
              provider_message = provider_message
            },
            autosave = false
          })
          continue_after_plan_tool_block(call, nil, function()
            index = index + 1
            ask_next()
          end)
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
        local provider_message = agent:tool_call_provider_message(calls, index)
        conversation:add("tool_call", agent:tool_call_display(call), {
          meta = {
            call = call,
            provider_message = provider_message
          },
          autosave = false
        })
        continue_after_plan_tool_block(call, plan_block_reason, function()
          index = index + 1
          ask_next()
        end)
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
    local streamed_tool_calls = {}
    local has_streamed_tool_calls = false
    local raw_stream_entries = {}
    local last_raw_flush
    local partial_text = ""
    local reasoning_text = ""
    local last_partial_at = 0
    local last_emitted_partial = nil
    local last_reasoning_update_at = 0
    local private_thinking_state = {}
    local plan_stream_state
    local reasoning_activity_key = "http:reasoning:"
      .. tostring(round or 0)
      .. ":"
      .. tostring(#(conversation.messages or {}) + 1)
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
    local function record_stream_event(data)
      table.insert(raw_stream_entries, {
        kind = "http-stream-event",
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
      local display_reasoning = strip_text_tool_call_blocks(reasoning_text)
      display_reasoning = display_reasoning:match("^%s*(.-)%s*$") or ""
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
    local function apply_stream_event(data, emit_text)
      record_stream_event(data)
      local text, done, event_usage, event_error, event_meta = agent:parse_stream_event(data)
      usage = event_usage or usage
      if event_usage and conversation.set_usage then
        conversation:set_usage(event_usage)
      end
      stream_error = event_error or stream_error
      if type(event_meta) == "table"
        and event_meta.type == "reasoning_delta"
        and type(event_meta.text) == "string"
        and event_meta.text ~= ""
      then
        reasoning_text = reasoning_text .. event_meta.text
        emit_reasoning(false)
      end
      if type(text) == "string" and text ~= "" then
        text = filter_private_thinking_delta(private_thinking_state, text)
      end
      if type(text) == "string" and text ~= "" then
        local accept_text = true
        if plan_stream_state then
          local was_started = plan_stream_state:has_started()
          local was_complete = plan_stream_state:is_complete()
          plan_stream_state:update(text)
          if was_complete then
            accept_text = false
          elseif was_started then
            accept_text = true
          elseif plan_stream_state:has_started() then
            text = plan_stream_state.text:sub(plan_stream_state.open_at)
            accept_text = true
          else
            accept_text = false
          end
        end
        if accept_text then
          table.insert(chunks, text)
          partial_text = partial_text .. text
        end
        if emit_text then emit_partial(false) end
      end
      if tools_available
        and parse_tools
        and agent.parse_stream_tool_call_deltas
        and not (plan_stream_state and plan_stream_state:is_complete())
      then
        local deltas = agent:parse_stream_tool_call_deltas(data)
        if deltas and #deltas > 0 then
          if not has_streamed_tool_calls then
            if should_show_tool_preamble(partial_text) then
              emit_partial(true)
              callback(true, nil, nil, { event = "finalize_pending_assistant" })
            end
          end
          has_streamed_tool_calls = true
          append_stream_tool_calls(streamed_tool_calls, deltas)
        end
      end
      if done then
        self:finish_request()
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
        pending = parse_stream_chunk(agent, chunk, pending, function(data)
          apply_stream_event(data, true)
        end)
      end,
      on_done = function(ok, err, _, info)
        self:finish_request()
        agent:set_loading(false)
        info = info or response_info
        if ok and not is_http_error(info) then
          if pending ~= "" then
            flush_stream_pending(agent, pending, function(data)
              apply_stream_event(data, false)
            end)
          end
          emit_reasoning(true)
          flush_raw_stream_events(true)
          local plan_completed = plan_stream_state and plan_stream_state:is_complete()
          local final_text = plan_completed
            and plan_stream_state:completed_text()
            or (
              plan_stream_state
              and not has_streamed_tool_calls
              and (plan_stream_state.text:match("^%s*(.-)%s*$") or "")
            )
            or table.concat(chunks)
          final_text = final_text or table.concat(chunks)
          local text_tool_calls = {}
          if tools_available and parse_tools and not has_streamed_tool_calls then
            text_tool_calls = parse_text_tool_calls(agent, final_text)
            if #text_tool_calls == 0 and looks_like_text_tool_call(reasoning_text) then
              text_tool_calls = parse_text_tool_calls(agent, reasoning_text)
            end
          end
          local final_is_completed_plan = is_plan_mode(agent, conversation)
            and final_text
            and contains_completed_plan(final_text)
          local final_should_auto_implement = final_is_completed_plan
            and not calls_include_tool(agent, text_tool_calls, "implement_plan")
          if stream_error then
            conversation:set_status("error", { autosave = false })
            conversation:append_raw_response("http-stream-error", stream_error)
            callback(false, request_error("Chat request", agent, info, stream_error, err), nil, { info = info })
          elseif has_streamed_tool_calls and final_is_completed_plan then
            local calls = finalize_stream_tool_calls(streamed_tool_calls)
            if calls_include_tool(agent, calls, "implement_plan") then
              compact_after_done()
              chunks = {}
              attach_reasoning_content_to_calls(agent, calls, reasoning_text)
              request_tool_approval(calls, round or 0, true)
            else
              finish(final_text, info, usage, {
                provider_reasoning_content = should_persist_reasoning_content(agent)
                  and reasoning_text ~= ""
                  and reasoning_text
                  or nil,
                auto_implement_plan = true
              })
            end
          elseif has_streamed_tool_calls and not plan_completed then
            compact_after_done()
            chunks = {}
            local calls = finalize_stream_tool_calls(streamed_tool_calls)
            attach_reasoning_content_to_calls(agent, calls, reasoning_text)
            request_tool_approval(calls, round or 0, true)
          elseif text_tool_calls and #text_tool_calls > 0 and not final_should_auto_implement then
            compact_after_done()
            chunks = {}
            partial_text = ""
            attach_reasoning_content_to_calls(agent, text_tool_calls, reasoning_text)
            request_tool_approval(text_tool_calls, round or 0, true)
          elseif final_should_auto_implement or (plan_stream_state and plan_completed and final_text and final_text ~= "") then
            finish(final_text, info, usage, {
              provider_reasoning_content = should_persist_reasoning_content(agent)
                and reasoning_text ~= ""
                and reasoning_text
                or nil,
              auto_implement_plan = final_should_auto_implement
            })
          else
            emit_partial(true)
            finish(final_text, info, usage, {
              provider_reasoning_content = should_persist_reasoning_content(agent)
                and reasoning_text ~= ""
                and reasoning_text
                or nil
            })
          end
        else
          flush_raw_stream_events(true)
          local error_body = decode_error_body(table.concat(error_chunks))
          local raw_error = raw_error_payload(info, error_body, err)
          conversation:set_status("error", { autosave = false })
          if raw_error ~= nil then conversation:append_raw_response("http-error", raw_error) end
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
    if tools_available then
      payload.parallel_tool_calls = false
      if payload.stream and not supports_stream_tool_calls(agent) then
        payload.stream = false
      end
    elseif without_tools then
      payload.tools = nil
      payload.tool_choice = nil
      payload.parallel_tool_calls = nil
    end
    local body = jsonutil.encode(payload)
    conversation:append_raw_response("http-request", raw_request_payload(payload))
    conversation:append_raw_response("http-request-audit", request_audit_payload(agent, conversation, payload, round))

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
          conversation:append_raw_response("http-response", result)
          local tool_calls = tools_available and parse_tools and agent:parse_tool_calls(result) or {}
          local response_text = agent:parse_response(result)
          local reasoning_content = should_persist_reasoning_content(agent)
            and agent.parse_reasoning_content
            and agent:parse_reasoning_content(result)
            or nil
          local parsed_usage = agent:parse_usage(result)
          if parsed_usage and conversation.set_usage then
            conversation:set_usage(parsed_usage)
          end
          local response_is_completed_plan = is_plan_mode(agent, conversation)
            and contains_completed_plan(response_text)
          if tool_calls and #tool_calls > 0 and response_is_completed_plan then
            if calls_include_tool(agent, tool_calls, "implement_plan") then
              compact_after_done()
              attach_reasoning_content_to_calls(agent, tool_calls, reasoning_content)
              request_tool_approval(tool_calls, round, false)
            else
              finish(response_text, info, parsed_usage, {
                provider_reasoning_content = reasoning_content,
                auto_implement_plan = true
              })
            end
          elseif tool_calls and #tool_calls > 0 then
            compact_after_done()
            attach_reasoning_content_to_calls(agent, tool_calls, reasoning_content)
            request_tool_approval(tool_calls, round, false)
          else
            finish(response_text, info, parsed_usage, {
              provider_reasoning_content = reasoning_content,
              auto_implement_plan = response_is_completed_plan
            })
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
function HttpBackend:resolve_tool_call(agent, conversation, request, decision, callback)
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
function HttpBackend:resolve_user_input(agent, conversation, request, ok, answers, callback)
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

return HttpBackend
