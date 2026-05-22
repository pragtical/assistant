-- Shared visible live conversation driver for local HTTP agents.
--
-- Wrappers set ASSISTANT_LIVE_HTTP_AGENT and then dofile this file.
-- Run visibly, for example:
--
--   pragtical run -n live_tests/ollama_conversation_live.lua

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local http = require "core.http"
local json = require "core.json"
local jsonutil = require "plugins.assistant.jsonutil"
local Conversation = require "plugins.assistant.conversation"
local stream_state = require "plugins.assistant.stream_state"

local AGENT = rawget(_G, "ASSISTANT_LIVE_HTTP_AGENT") or os.getenv("ASSISTANT_LIVE_HTTP_AGENT") or "ollama"
local MODEL_OVERRIDE = rawget(_G, "ASSISTANT_LIVE_HTTP_MODEL") or os.getenv("ASSISTANT_LIVE_HTTP_MODEL")
local USE_CONFIG_MODEL = rawget(_G, "ASSISTANT_LIVE_HTTP_USE_CONFIG_MODEL") == true
  or os.getenv("ASSISTANT_LIVE_HTTP_USE_CONFIG_MODEL") == "1"
local SCENARIO = rawget(_G, "ASSISTANT_LIVE_HTTP_SCENARIO") or os.getenv("ASSISTANT_LIVE_HTTP_SCENARIO") or "tetris"
local PROJECT_SUBDIR = rawget(_G, "ASSISTANT_LIVE_HTTP_PROJECT_SUBDIR") or os.getenv("ASSISTANT_LIVE_HTTP_PROJECT_SUBDIR") or "tetris"
local PROJECT_DIR_OVERRIDE = rawget(_G, "ASSISTANT_LIVE_HTTP_PROJECT_DIR") or os.getenv("ASSISTANT_LIVE_HTTP_PROJECT_DIR")
local SINGLE_PROMPT = rawget(_G, "ASSISTANT_LIVE_HTTP_SINGLE_PROMPT") or os.getenv("ASSISTANT_LIVE_HTTP_SINGLE_PROMPT")
local PRESERVE_PROJECT_CONVERSATIONS = rawget(_G, "ASSISTANT_LIVE_HTTP_PRESERVE_PROJECT_CONVERSATIONS") == true
  or os.getenv("ASSISTANT_LIVE_HTTP_PRESERVE_PROJECT_CONVERSATIONS") == "1"
local function temp_dir(name)
  local path = os.tmpname()
  os.remove(path)
  return path .. "-" .. name
end

local OUT_DIR = rawget(_G, "ASSISTANT_LIVE_HTTP_OUT_DIR")
  or os.getenv("ASSISTANT_LIVE_HTTP_OUT_DIR")
  or temp_dir("pragtical-assistant-live-" .. AGENT .. (SCENARIO ~= "tetris" and ("-" .. SCENARIO) or ""))
local MAX_TURN_SECONDS = tonumber(os.getenv("ASSISTANT_LIVE_HTTP_TIMEOUT") or "3600")
local MAX_NO_PROGRESS_SECONDS = tonumber(os.getenv("ASSISTANT_LIVE_HTTP_NO_PROGRESS_TIMEOUT") or "900")
local PLAN_PROMPT = rawget(_G, "ASSISTANT_LIVE_HTTP_PLAN_PROMPT") or "Create a tiny SDL2 Tetris game."
local IMPLEMENT_PROMPT = rawget(_G, "ASSISTANT_LIVE_HTTP_IMPLEMENT_PROMPT") or "Implement the plan."
local FOLLOWUP_PROMPT = rawget(_G, "ASSISTANT_LIVE_HTTP_FOLLOWUP_PROMPT")
if FOLLOWUP_PROMPT == nil then
  FOLLOWUP_PROMPT = "Improve the scoring display conceptually or in code, then run or describe the most relevant verification. Keep the final response concise."
end
local CONTINUE_PROMPT = rawget(_G, "ASSISTANT_LIVE_HTTP_CONTINUE_PROMPT")
  or os.getenv("ASSISTANT_LIVE_HTTP_CONTINUE_PROMPT")
  or "Continue implementing the plan. Focus on creating the missing required project files before verification."
local MAX_CONTINUE_TURNS = tonumber(os.getenv("ASSISTANT_LIVE_HTTP_MAX_CONTINUE_TURNS") or "6")
local PLAN_DOMAIN_KEYWORDS = rawget(_G, "ASSISTANT_LIVE_HTTP_PLAN_KEYWORDS") or { "tetris" }
local REQUIRED_FILES = rawget(_G, "ASSISTANT_LIVE_HTTP_REQUIRED_FILES") or {}
local EXPECTED_MENTIONS = rawget(_G, "ASSISTANT_LIVE_HTTP_EXPECTED_MENTIONS") or {}
local project_dir
local external_project = PROJECT_DIR_OVERRIDE ~= nil and PROJECT_DIR_OVERRIDE ~= ""

local defaults = {
  ollama = {
    base_url = "http://127.0.0.1:11434",
    model = "llama3.1"
  },
  lms = {
    base_url = "http://127.0.0.1:1234",
    model = "local-model"
  },
  llamacpp = {
    base_url = "http://127.0.0.1:8080",
    model = "local-model"
  }
}

local coroutine_yield = coroutine.yield
function coroutine.yield(...)
  core.redraw = true
  coroutine_yield(...)
end

local function log(...)
  core.log("Assistant " .. AGENT .. " live: " .. tostring((...)), select(2, ...))
end

local function fail(message)
  error(message, 2)
end

local function ensure_dir(path)
  if system.get_file_info(path) then return end
  local ok, err = common.mkdirp(path)
  if not ok and not system.get_file_info(path) then
    fail("could not create " .. path .. ": " .. tostring(err))
  end
end

local function write_file(path, text)
  local fp, err = io.open(path, "wb")
  if not fp then fail("could not write " .. path .. ": " .. tostring(err)) end
  fp:write(text or "")
  fp:close()
end

local function append_file(path, text)
  local fp, err = io.open(path, "ab")
  if not fp then fail("could not append " .. path .. ": " .. tostring(err)) end
  fp:write(text or "")
  fp:close()
end

local function write_skip_artifacts(reason)
  ensure_dir(OUT_DIR)
  local text = "# Assistant Session\n\n## Skipped\n\n" .. tostring(reason or "live server unavailable") .. "\n"
  write_file(OUT_DIR .. PATHSEP .. "conversation.md", text)
  write_file(OUT_DIR .. PATHSEP .. "raw.jsonl", "")
  write_file(OUT_DIR .. PATHSEP .. "skip.txt", tostring(reason or "") .. "\n")
end

local function plugin_root()
  local source = debug.getinfo(1, "S").source
  if source and source:sub(1, 1) == "@" then
    return common.dirname(common.dirname(system.absolute_path(source:sub(2))))
  end
  return system.getcwd()
end

local function remove_tree(path)
  local info = system.get_file_info(path)
  if not info then return true end
  if info.type == "dir" then
    for _, child in ipairs(system.list_dir(path) or {}) do
      if child ~= "." and child ~= ".." then
        local ok, err = remove_tree(path .. PATHSEP .. child)
        if not ok then return nil, err end
      end
    end
    return os.remove(path)
  end
  return os.remove(path)
end

local function wipe_dir(path)
  ensure_dir(path)
  local normalized = (common.normalize_path(path) or path):gsub(PATHSEP .. "$", "")
  local expected = ((common.normalize_path(plugin_root()) or plugin_root()):gsub(PATHSEP .. "$", "")) .. PATHSEP .. PROJECT_SUBDIR
  if normalized ~= expected then fail("refusing to wipe unexpected path: " .. tostring(path)) end
  for _, child in ipairs(system.list_dir(path) or {}) do
    if child ~= "." and child ~= ".." then
      local ok, err = remove_tree(path .. PATHSEP .. child)
      if not ok then fail("could not remove " .. child .. ": " .. tostring(err)) end
      coroutine.yield(0.01)
    end
  end
end

local function close_all_views()
  local root = core.root_view and core.root_view.root_node
  if not root or not root.get_children then return end
  for _, view in ipairs(root:get_children()) do
    local node = root:get_node_for_view(view)
    if node and not node.locked and node.close_view then
      pcall(function() node:close_view(root, view) end)
      coroutine.yield(0.03)
    end
  end
  if root.update_layout then root:update_layout() end
end

local function delete_all_conversations(project_dir)
  local count = 0
  for _, item in ipairs(Conversation.list(project_dir) or {}) do
    if item.id and Conversation.delete(item.id, project_dir) then
      count = count + 1
      coroutine.yield(0.02)
    end
  end
  return count
end

local function set_doc_text(doc, text)
  local line, col = #doc.lines, #doc.lines[#doc.lines]
  if line > 1 or col > 1 then doc:remove(1, 1, line, col) end
  if text and text ~= "" then doc:insert(1, 1, text) end
  doc:set_selection(#doc.lines, #doc.lines[#doc.lines])
end

local function wait_until(label, timeout, predicate)
  local start = system.get_time()
  while system.get_time() - start < timeout do
    local result = predicate()
    if result then return result end
    coroutine.yield(0.05)
  end
  fail("timed out waiting for " .. label)
end

local function append_live_raw_artifact(view)
  local conversation = view and view.conversation
  if not conversation then return 0 end
  if not view.live_artifact_raw_started then
    write_file(OUT_DIR .. PATHSEP .. "raw.jsonl", "")
    view.live_artifact_raw_started = true
    view.live_artifact_raw_offset = 0
  end
  local path = Conversation.raw_responses_path(conversation.project_dir, conversation.id)
  local fp = io.open(path, "rb")
  if not fp then return view.live_artifact_raw_offset or 0 end
  local size = fp:seek("end") or 0
  local offset = view.live_artifact_raw_offset or 0
  if size < offset then offset = 0 end
  if size > offset then
    fp:seek("set", offset)
    while true do
      local chunk = fp:read(64 * 1024)
      if not chunk or chunk == "" then break end
      append_file(OUT_DIR .. PATHSEP .. "raw.jsonl", chunk)
      coroutine.yield(0)
    end
    view.live_artifact_raw_offset = size
  end
  fp:close()
  return size
end

local function live_raw_size(view)
  local conversation = view and view.conversation
  if not conversation then return 0 end
  local path = Conversation.raw_responses_path(conversation.project_dir, conversation.id)
  local fp = io.open(path, "rb")
  if not fp then return view.live_artifact_raw_offset or 0 end
  local size = fp:seek("end") or 0
  fp:close()
  return size
end

local write_diagnostic_artifacts

local function write_live_artifacts(view, include_markdown)
  if not (view and view.conversation) then return end
  append_live_raw_artifact(view)
  if include_markdown ~= false then
    local markdown = view.conversation:to_markdown()
    if markdown ~= view.live_artifact_markdown then
      write_file(OUT_DIR .. PATHSEP .. "conversation.md", markdown)
      view.live_artifact_markdown = markdown
    end
    local raw = view.conversation:raw_responses_text()
    write_file(OUT_DIR .. PATHSEP .. "raw.jsonl", raw)
    view.live_artifact_raw_started = true
    view.live_artifact_raw_offset = #raw
    write_diagnostic_artifacts(view)
  end
end

local function decode_raw_entries(raw)
  local entries = {}
  for line in tostring(raw or ""):gmatch("[^\r\n]+") do
    local ok, entry = pcall(json.decode, line)
    if ok and type(entry) == "table" then table.insert(entries, entry) end
  end
  return entries
end

local function append_tool_call(calls, source, name, arguments)
  if type(name) ~= "string" or name == "" then return end
  table.insert(calls, {
    source = source,
    name = name,
    arguments = arguments
  })
end

local function collect_tool_calls_from_payload(calls, source, payload)
  if type(payload) ~= "table" then return end
  local choices = payload.choices
  if type(choices) == "table" then
    for _, choice in ipairs(choices) do
      local message = choice.message or {}
      local delta = choice.delta or {}
      for _, container in ipairs({ message, delta }) do
        if type(container.tool_calls) == "table" then
          for _, call in ipairs(container.tool_calls) do
            local fn = type(call) == "table" and type(call["function"]) == "table" and call["function"] or {}
            append_tool_call(calls, source, fn.name or call.name, fn.arguments or call.arguments)
          end
        end
      end
    end
  end
  local output = payload.output
  if type(output) == "table" then
    for _, item in ipairs(output) do
      if type(item) == "table" and (item.type == "function_call" or item.name or item.arguments) then
        append_tool_call(calls, source, item.name, item.arguments)
      end
    end
  end
end

local function compact_json(value)
  local ok, encoded = pcall(jsonutil.encode, value)
  return ok and encoded or tostring(value)
end

local function tool_loop_key(call)
  local name = call and call.name
  if name ~= "read" and name ~= "search" and name ~= "list" and name ~= "file_info" then
    return nil
  end
  local args = call.arguments
  if type(args) == "string" then
    local ok, decoded = pcall(json.decode, args)
    args = ok and decoded or args
  end
  if type(args) ~= "table" then
    return name .. ":" .. tostring(args or "")
  end
  return table.concat({
    name,
    tostring(args.path or ""),
    tostring(args.directory or ""),
    tostring(args.text or ""),
    tostring(args.pattern or ""),
    tostring(args.query or "")
  }, ":")
end

local function request_audit_summary(entries)
  local lines = {
    "# Request And Agent Behavior Analysis",
    "",
    "This file is generated from `http-request-audit` raw log entries and streamed tool calls.",
    ""
  }
  local audits = {}
  for _, entry in ipairs(entries) do
    if entry.kind == "http-request-audit" and type(entry.data) == "table" then
      table.insert(audits, entry.data)
    end
  end
  table.insert(lines, string.format("Total audited requests: %d", #audits))
  table.insert(lines, "")

  local previous_tool_results = {}
  local previous_duplicates = 0
  for index, audit in ipairs(audits) do
    local totals = audit.totals or {}
    table.insert(lines, string.format(
      "## Request %d",
      index
    ))
    table.insert(lines, "")
    table.insert(lines, string.format(
      "- round: %s",
      tostring(audit.round or "")
    ))
    table.insert(lines, string.format(
      "- model: %s",
      tostring(audit.model or "")
    ))
    table.insert(lines, string.format(
      "- messages: %s",
      tostring(totals.messages or 0)
    ))
    table.insert(lines, string.format(
      "- content_bytes: %s",
      tostring(totals.content_bytes or 0)
    ))
    table.insert(lines, string.format(
      "- tool_calls_in_request: %s",
      tostring(totals.tool_calls or 0)
    ))
    table.insert(lines, string.format(
      "- tool_results_in_request: %s",
      tostring(totals.tool_results or 0)
    ))
    table.insert(lines, string.format(
      "- duplicate_tool_notices: %s",
      tostring(totals.duplicate_tool_notices or 0)
    ))
    table.insert(lines, string.format(
      "- loop_warnings: %s",
      tostring(totals.loop_warnings or 0)
    ))
    if audit.local_compaction then
      table.insert(lines, string.format(
        "- local_compaction: first %s message(s), summary_bytes=%s",
        tostring(audit.local_compaction.message_count or ""),
        tostring(audit.local_compaction.summary_bytes or "")
      ))
    end
    table.insert(lines, string.format(
      "- compact_tool_history: %s",
      tostring(audit.compact_tool_history == true)
    ))
    table.insert(lines, string.format(
      "- compact_tool_results: %s",
      tostring(audit.compact_tool_results == true)
    ))

    if type(audit.tool_result_counts) == "table" then
      local counts = {}
      for name, count in pairs(audit.tool_result_counts) do
        table.insert(counts, tostring(name) .. "=" .. tostring(count))
      end
      table.sort(counts)
      if #counts > 0 then
        table.insert(lines, "- tool_result_counts: " .. table.concat(counts, ", "))
      end
    end

    local duplicate_delta = tonumber(totals.duplicate_tool_notices or 0) - previous_duplicates
    if duplicate_delta > 0 then
      table.insert(lines, string.format(
        "- observation: %d repeated tool result notice(s) are present in this request.",
        duplicate_delta
      ))
    end
    previous_duplicates = tonumber(totals.duplicate_tool_notices or 0) or previous_duplicates

    local current_tool_results = tonumber(totals.tool_results or 0) or 0
    if index > 1 and current_tool_results > (previous_tool_results[index - 1] or 0) then
      table.insert(lines, "- observation: tool result history grew before this request.")
    end
    previous_tool_results[index] = current_tool_results

    local big = {}
    for _, message in ipairs(audit.messages or {}) do
      if tonumber(message.bytes or 0) >= 48000 then
        table.insert(big, string.format(
          "  - #%s %s %s bytes hash=%s preview=%s",
          tostring(message.index or ""),
          tostring(message.role or ""),
          tostring(message.bytes or ""),
          tostring(message.hash or ""),
          tostring(message.preview or "")
        ))
      end
    end
    if #big > 0 then
      table.insert(lines, "- large provider messages:")
      for _, line in ipairs(big) do table.insert(lines, line) end
    end

    local calls = {}
    for _, message in ipairs(audit.messages or {}) do
      for _, call in ipairs(message.tool_calls or {}) do
        table.insert(calls, string.format(
          "  - message #%s: %s args=%s bytes hash=%s",
          tostring(message.index or ""),
          tostring(call.name or ""),
          tostring(call.arguments_bytes or 0),
          tostring(call.arguments_hash or "")
        ))
      end
    end
    if #calls > 0 then
      table.insert(lines, "- provider tool calls included:")
      for _, line in ipairs(calls) do table.insert(lines, line) end
    end

    table.insert(lines, "")
  end
  return table.concat(lines, "\n")
end

function write_diagnostic_artifacts(view)
  if not (view and view.conversation) then return end
  local raw = view.conversation:raw_responses_text()
  local entries = decode_raw_entries(raw)
  local request_blocks = {}
  local tool_calls = {}
  for _, entry in ipairs(entries) do
    if entry.kind == "http-request" then
      table.insert(request_blocks, jsonutil.encode(entry.data, { prettify = true }))
    elseif entry.kind == "http-response" then
      collect_tool_calls_from_payload(tool_calls, entry.kind, entry.data)
    elseif entry.kind == "http-stream-event" and type(entry.data) == "string" and entry.data ~= "[DONE]" then
      local ok, decoded = pcall(json.decode, entry.data)
      if ok then collect_tool_calls_from_payload(tool_calls, entry.kind, decoded) end
    end
  end
  write_file(OUT_DIR .. PATHSEP .. "requests-pretty.jsonl", table.concat(request_blocks, "\n\n") .. (#request_blocks > 0 and "\n" or ""))

  local tool_lines = {}
  local diagnostics = {}
  local inspect_counts = {}
  local since_mutation = {}
  for _, call in ipairs(tool_calls) do
    table.insert(tool_lines, jsonutil.encode(call, { prettify = true }))
    if call.name == "write" or call.name == "edit" or call.name == "apply_patch" then
      since_mutation = {}
    else
      local key = tool_loop_key(call)
      if key then
        inspect_counts[key] = (inspect_counts[key] or 0) + 1
        since_mutation[key] = (since_mutation[key] or 0) + 1
        if since_mutation[key] == 3 then
          table.insert(diagnostics, string.format(
            "Repeated inspection without intervening mutation: %s (%d total)",
            key,
            inspect_counts[key]
          ))
        end
      end
    end
  end
  write_file(OUT_DIR .. PATHSEP .. "tool-calls.jsonl", table.concat(tool_lines, "\n") .. (#tool_lines > 0 and "\n" or ""))
  if #diagnostics == 0 then
    table.insert(diagnostics, "No repeated inspection loop detected.")
  end
  write_file(OUT_DIR .. PATHSEP .. "loop-diagnostics.txt", table.concat(diagnostics, "\n") .. "\n")
  write_file(OUT_DIR .. PATHSEP .. "request-analysis.md", request_audit_summary(entries))
end

local function preserve_larger_live_raw(raw)
  raw = raw or ""
  local path = OUT_DIR .. PATHSEP .. "raw.jsonl"
  local existing = read_file(path) or ""
  if #raw >= #existing then
    write_file(path, raw)
  end
end

local function find_prompt_view()
  local PromptView = require "plugins.assistant.promptview"
  return PromptView.active_conversation_view()
end

local function get_json(url, timeout)
  local done, ok, result, info
  http.get(url, nil, {
    on_done = function(done_ok, _, done_result, done_info)
      done = true
      ok = done_ok
      result = done_result
      info = done_info
    end
  })
  local start = system.get_time()
  while not done and system.get_time() - start < timeout do coroutine.yield(0.05) end
  if not done or not ok or (info and tonumber(info.status) and tonumber(info.status) >= 400) then
    return nil
  end
  return result
end

local function first_model(base_url)
  local result = get_json(base_url:gsub("/+$", "") .. "/v1/models", 4)
  local data = result and (result.data or result.models)
  if type(data) ~= "table" then return nil end
  for _, model in ipairs(data) do
    if type(model) == "table" then return model.id or model.name or model.model end
    if type(model) == "string" then return model end
  end
end

local function normalize_compare_text(text)
  text = tostring(text or "")
    :gsub("</?proposed_plan>", " ")
    :gsub("%s+", " ")
  return text:match("^%s*(.-)%s*$") or ""
end

local function append_response_content(parts, data)
  if type(data) ~= "table" then return end
  local choices = data.choices
  if type(choices) == "table" then
    for _, choice in ipairs(choices) do
      local message = choice.message or {}
      local delta = choice.delta or {}
      if type(message.content) == "string" then table.insert(parts, message.content) end
      if type(delta.content) == "string" then table.insert(parts, delta.content) end
    end
  end
  local output = data.output
  if type(output) == "table" then
    for _, item in ipairs(output) do
      if type(item) == "table" and type(item.content) == "table" then
        for _, content in ipairs(item.content) do
          if type(content) == "table" and type(content.text) == "string" then
            table.insert(parts, content.text)
          end
        end
      end
    end
  end
end

local function raw_assistant_text(raw)
  local parts = {}
  for line in tostring(raw or ""):gmatch("[^\r\n]+") do
    local ok, entry = pcall(json.decode, line)
    if not ok then entry = nil end
    if type(entry) == "table" then
      if entry.kind == "http-response" then
        append_response_content(parts, entry.data)
      elseif entry.kind == "http-stream-event" and type(entry.data) == "string" and entry.data ~= "[DONE]" then
        local decoded_ok, decoded = pcall(json.decode, entry.data)
        append_response_content(parts, decoded_ok and decoded or nil)
      end
    end
  end
  return normalize_compare_text(table.concat(parts))
end

local function transcript_matches_raw(conversation, raw)
  local raw_text = raw_assistant_text(raw)
  if raw_text == "" then return false, "raw assistant text is empty" end
  for _, message in ipairs(conversation.messages or {}) do
    if message.role == "assistant"
      and not (message.meta and (message.meta.plan_update or message.meta.local_compaction_notice))
    then
      local text = normalize_compare_text(message.message)
      if text ~= "" and not raw_text:find(text, 1, true) then
        return false, "assistant transcript text missing from raw provider events: " .. text:sub(1, 120)
      end
    end
  end
  return true
end

local function patch_command_view()
  local old_enter = core.command_view.enter
  core.command_view.enter = function(self, label, options)
    log("auto-answering command view: %s", tostring(label))
    core.add_thread(function()
      coroutine.yield(0.1)
      local suggestion
      if options and options.suggest then
        local ok, suggestions = pcall(options.suggest, "")
        if ok and type(suggestions) == "table" and #suggestions > 0 then suggestion = suggestions[1] end
      end
      local text = suggestion and suggestion.text or "Use a compact SDL2 C implementation with deterministic tests."
      if options and options.submit then options.submit(text, suggestion) end
    end)
  end
  return function() core.command_view.enter = old_enter end
end

local function wait_for_turn(view, label, before_count)
  local started = system.get_time()
  local last_progress = started
  local last_status
  local last_messages = #view.conversation.messages
  local last_raw_len = live_raw_size(view)
  local saw_start = false
  write_live_artifacts(view)
  while system.get_time() - started < MAX_TURN_SECONDS do
    view:update()
    local status = view.conversation.status
    local messages = #view.conversation.messages
    local raw_len = live_raw_size(view)
    if status ~= last_status or messages ~= last_messages or raw_len ~= last_raw_len then
      local transcript_changed = status ~= last_status or messages ~= last_messages
      last_progress = system.get_time()
      last_messages = messages
      last_raw_len = raw_len
      write_live_artifacts(view, transcript_changed)
    end
    if status ~= "idle" or (view.agent and view.agent.loading and view.agent:loading()) then
      saw_start = true
    end
    if messages >= before_count + 2 then
      saw_start = true
    end
    if status ~= last_status then
      last_status = status
      log("%s status=%s messages=%d raw_bytes=%d", label, tostring(status), messages, raw_len)
    end
    if saw_start and status == "idle" and not (view.agent and view.agent.loading and view.agent:loading()) then
      return true
    end
    if status == "error" then return false, "conversation entered error status" end
    if saw_start and system.get_time() - last_progress > MAX_NO_PROGRESS_SECONDS then
      return false, string.format(
        "turn made no transcript/protocol progress for %.0fs while status=%s messages=%d raw_bytes=%d",
        MAX_NO_PROGRESS_SECONDS,
        tostring(status),
        messages,
        raw_len
      )
    end
    coroutine.yield(0.1)
  end
  return false, "turn timed out"
end

local function submit_prompt(view, text)
  log("submitting prompt: %s", text)
  local before_count = #view.conversation.messages
  set_doc_text(view.prompt_doc, text)
  core.set_active_view(view.prompt)
  command.perform("assistant-conversation:send")
  coroutine.yield(0.2)
  write_live_artifacts(view)
  local ok, err = wait_for_turn(view, text:sub(1, 30), before_count)
  if not ok then fail(err or "turn failed") end
  write_live_artifacts(view)
end

local function missing_required_files()
  local missing = {}
  if not project_dir then return missing end
  for _, relative_path in ipairs(REQUIRED_FILES) do
    local path = project_dir .. PATHSEP .. tostring(relative_path):gsub("/", PATHSEP)
    if not system.get_file_info(path) then
      table.insert(missing, tostring(relative_path))
    end
  end
  return missing
end

local function submit_until_required_files_exist(view)
  if #REQUIRED_FILES == 0 then return end
  for turn = 1, MAX_CONTINUE_TURNS do
    local missing = missing_required_files()
    if #missing == 0 then return end
    submit_prompt(view, CONTINUE_PROMPT .. "\n\nMissing required files: " .. table.concat(missing, ", "))
  end
end

local function has_completed_plan(view)
  for _, message in ipairs(view.conversation.messages or {}) do
    if message.role == "assistant" then
      local text = tostring(message.message or "")
      if stream_state.contains_completed_plan(text) then
        local body = text
          :gsub("</?proposed_plan>", " ")
          :gsub("<[^>]+>", " ")
          :gsub("%s+", " ")
        if body:find("%a[%a%-]+%s+%a[%a%-]+%s+%a[%a%-]+") then
          return true
        end
      end
      local lower = text:lower()
      local has_plan_shape = lower:find("plan", 1, true) ~= nil
        or lower:find("implementation", 1, true) ~= nil
        or lower:find("build", 1, true) ~= nil
      local has_domain = lower:find("sdl2", 1, true) ~= nil
      for _, keyword in ipairs(PLAN_DOMAIN_KEYWORDS) do
        if lower:find(tostring(keyword):lower(), 1, true) ~= nil then
          has_domain = true
          break
        end
      end
      local has_actionable_steps = lower:find("makefile", 1, true) ~= nil
        or lower:find("controls", 1, true) ~= nil
        or lower:find("scoring", 1, true) ~= nil
        or lower:find("physics", 1, true) ~= nil
        or lower:find("level", 1, true) ~= nil
      if has_plan_shape and has_domain and has_actionable_steps then
        return true
      end
    end
  end
  return false
end

local function submit_plan_prompt(view, text)
  submit_prompt(view, text)
  if not has_completed_plan(view) then
    fail("plan mode did not produce a completed implementation plan")
  end
end

local function analyze(view)
  local markdown = view.conversation:to_markdown()
  local raw = view.conversation:raw_responses_text()
  local transcript_ok, transcript_err = transcript_matches_raw(view.conversation, raw)
  write_file(OUT_DIR .. PATHSEP .. "conversation.md", markdown)
  write_file(OUT_DIR .. PATHSEP .. "raw.jsonl", raw)
  if not transcript_ok then
    write_file(OUT_DIR .. PATHSEP .. "conversation-raw-mismatch.txt", transcript_err)
  end
  local lower = markdown:lower()
  local function has_backend_timeout(text)
    text = tostring(text or ""):lower()
    return text:find("chat request timed out", 1, true) ~= nil
      or text:find("request timed out for", 1, true) ~= nil
      or text:find("timed out for " .. AGENT, 1, true) ~= nil
      or text:find("turn timed out", 1, true) ~= nil
      or text:find("http request timed out", 1, true) ~= nil
  end
  local checks = {
    { "uses selected agent", view.agent and view.agent.name == AGENT },
    { "has assistant output", markdown:find("## Assistant", 1, true) ~= nil },
    { "has raw http request", raw:find('"kind":"http-request"', 1, true) ~= nil },
    { "has raw http response or stream", raw:find('"kind":"http-response"', 1, true) ~= nil or raw:find('"kind":"http-stream-event"', 1, true) ~= nil },
    { "assistant transcript matches raw", transcript_ok },
    { "no backend timeout", not has_backend_timeout(markdown) }
  }
  if SINGLE_PROMPT and SINGLE_PROMPT ~= "" then
    for _, expected in ipairs(EXPECTED_MENTIONS) do
      local needle = tostring(expected or ""):lower()
      if needle ~= "" then
        table.insert(checks, {
          "mentions " .. needle,
          lower:find(needle, 1, true) ~= nil
        })
      end
    end
  else
    table.insert(checks, { "records activity", markdown:find("## Activity", 1, true) ~= nil })
    table.insert(checks, { "mentions plan", lower:find("plan", 1, true) ~= nil })
    table.insert(checks, { "mentions implementation", lower:find("implement", 1, true) ~= nil or lower:find("file", 1, true) ~= nil })
  end
  for _, relative_path in ipairs(REQUIRED_FILES) do
    local path = project_dir and (project_dir .. PATHSEP .. tostring(relative_path):gsub("/", PATHSEP))
    table.insert(checks, {
      "created " .. tostring(relative_path),
      path and system.get_file_info(path) ~= nil
    })
  end
  if #REQUIRED_FILES > 0 then
    table.insert(checks, {
      "no missing makefile build failure",
      lower:find("no targets specified and no makefile found", 1, true) == nil
    })
  end
  local failed = {}
  for _, check in ipairs(checks) do
    log("check %-28s %s", check[1], check[2] and "ok" or "FAILED")
    if not check[2] then table.insert(failed, check[1]) end
  end
  if #failed > 0 then fail("live checks failed: " .. table.concat(failed, ", ")) end
end

core.add_thread(function()
  local restore_command_view = patch_command_view()
  local old_conf = common.merge({}, config.plugins.assistant or {})
  local view
  local ok, err = xpcall(function()
	    local provider = defaults[AGENT]
	    if not provider then fail("unknown local HTTP live agent: " .. tostring(AGENT)) end
	    ensure_dir(OUT_DIR)
	    os.remove(OUT_DIR .. PATHSEP .. "conversation-raw-mismatch.txt")
	    log("live artifacts updating in %s", OUT_DIR)
    local reported_model = first_model(provider.base_url)
    if not reported_model then
      local reason = string.format("no reachable %s server at %s", AGENT, provider.base_url)
      log("skipping: %s", reason)
      print("Assistant " .. AGENT .. " live skipped: " .. reason)
      write_skip_artifacts(reason)
      core.quit(true, 0)
      return
    end
    local model
    if not USE_CONFIG_MODEL then
      model = MODEL_OVERRIDE or (AGENT == "llamacpp" and provider.model or reported_model)
    end

    project_dir = external_project
      and system.absolute_path(common.home_expand(PROJECT_DIR_OVERRIDE))
      or (plugin_root() .. PATHSEP .. PROJECT_SUBDIR)
    if not project_dir or project_dir == "" then fail("could not resolve live project directory") end
    if not external_project then wipe_dir(project_dir) end
    core.set_project(project_dir)
    system.chdir(project_dir)
    close_all_views()

    local assistant = require "plugins.assistant"
    config.plugins.assistant.agent = AGENT
    if not USE_CONFIG_MODEL then
      assistant.configure_agent(AGENT, { model = model or provider.model })
    end
    config.plugins.assistant.stream = true
    config.plugins.assistant.log_raw_messages = true
    config.plugins.assistant.log_protocol = true
    config.plugins.assistant.verbose_tool_calling = true
    if rawget(_G, "ASSISTANT_LIVE_HTTP_COMPACT_TOOL_HISTORY") ~= nil then
      config.plugins.assistant.compact_tool_history = rawget(_G, "ASSISTANT_LIVE_HTTP_COMPACT_TOOL_HISTORY") == true
    end
    if rawget(_G, "ASSISTANT_LIVE_HTTP_COMPACT_TOOL_RESULTS") ~= nil then
      config.plugins.assistant.compact_tool_results = rawget(_G, "ASSISTANT_LIVE_HTTP_COMPACT_TOOL_RESULTS") == true
    end

    if not command.perform("assistant:new-conversation") then fail("assistant:new-conversation did not run") end
    view = wait_until("assistant prompt view", 10, find_prompt_view)
    if not USE_CONFIG_MODEL then
      view.agent.model = model or provider.model
    end
    view:refresh()

    view:set_collaboration_mode("implementation")
    if SINGLE_PROMPT and SINGLE_PROMPT ~= "" then
      submit_prompt(view, SINGLE_PROMPT)
    else
      view:set_collaboration_mode("plan")
      submit_plan_prompt(view, PLAN_PROMPT)

      view:set_collaboration_mode("implementation")
      submit_prompt(view, IMPLEMENT_PROMPT)
      submit_until_required_files_exist(view)

      if #missing_required_files() == 0 and FOLLOWUP_PROMPT and FOLLOWUP_PROMPT ~= "" then
        submit_prompt(view, FOLLOWUP_PROMPT)
      end
    end

    analyze(view)
    if not PRESERVE_PROJECT_CONVERSATIONS then delete_all_conversations(project_dir) end
    log("artifacts written to %s", OUT_DIR)
  end, debug.traceback)

  restore_command_view()
  for key, value in pairs(old_conf) do config.plugins.assistant[key] = value end
  if not ok then
    close_all_views()
    if view and view.conversation then
      pcall(write_file, OUT_DIR .. PATHSEP .. "conversation.md", view.conversation:to_markdown())
      pcall(preserve_larger_live_raw, view.conversation:raw_responses_text())
      pcall(write_diagnostic_artifacts, view)
    end
    if project_dir and not PRESERVE_PROJECT_CONVERSATIONS then pcall(delete_all_conversations, project_dir) end
    core.error("Assistant %s live failed: %s", AGENT, err)
    print(err)
    core.quit(true, 1)
  else
    close_all_views()
    if project_dir and not PRESERVE_PROJECT_CONVERSATIONS then delete_all_conversations(project_dir) end
    core.quit(true, 0)
  end
end)
