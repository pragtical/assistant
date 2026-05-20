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
local Conversation = require "plugins.assistant.conversation"
local stream_state = require "plugins.assistant.stream_state"

local AGENT = rawget(_G, "ASSISTANT_LIVE_HTTP_AGENT") or os.getenv("ASSISTANT_LIVE_HTTP_AGENT") or "ollama"
local MODEL_OVERRIDE = rawget(_G, "ASSISTANT_LIVE_HTTP_MODEL") or os.getenv("ASSISTANT_LIVE_HTTP_MODEL")
local SCENARIO = rawget(_G, "ASSISTANT_LIVE_HTTP_SCENARIO") or os.getenv("ASSISTANT_LIVE_HTTP_SCENARIO") or "tetris"
local PROJECT_SUBDIR = rawget(_G, "ASSISTANT_LIVE_HTTP_PROJECT_SUBDIR") or os.getenv("ASSISTANT_LIVE_HTTP_PROJECT_SUBDIR") or "tetris"
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
local project_dir

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
  end
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
    { "records activity", markdown:find("## Activity", 1, true) ~= nil },
    { "mentions plan", lower:find("plan", 1, true) ~= nil },
    { "mentions implementation", lower:find("implement", 1, true) ~= nil or lower:find("file", 1, true) ~= nil },
    { "has raw http request", raw:find('"kind":"http-request"', 1, true) ~= nil },
    { "has raw http response or stream", raw:find('"kind":"http-response"', 1, true) ~= nil or raw:find('"kind":"http-stream-event"', 1, true) ~= nil },
    { "assistant transcript matches raw", transcript_ok },
    { "no backend timeout", not has_backend_timeout(markdown) }
  }
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
    local model = MODEL_OVERRIDE or (AGENT == "llamacpp" and provider.model or reported_model)

    project_dir = plugin_root() .. PATHSEP .. PROJECT_SUBDIR
    wipe_dir(project_dir)
    core.set_project(project_dir)
    system.chdir(project_dir)
    close_all_views()

    require "plugins.assistant"
    config.plugins.assistant.agent = AGENT
    config.plugins.assistant.model = model or provider.model
    config.plugins.assistant.stream = true
    config.plugins.assistant.log_raw_messages = true
    config.plugins.assistant.log_protocol = true
    config.plugins.assistant.verbose_tool_calling = true

    if not command.perform("assistant:new-conversation") then fail("assistant:new-conversation did not run") end
    view = wait_until("assistant prompt view", 10, find_prompt_view)
    view.agent.model = model or provider.model
    view:refresh()

    view:set_collaboration_mode("plan")
    submit_plan_prompt(view, PLAN_PROMPT)

    view:set_collaboration_mode("implementation")
    submit_prompt(view, IMPLEMENT_PROMPT)
    submit_until_required_files_exist(view)

    if #missing_required_files() == 0 and FOLLOWUP_PROMPT and FOLLOWUP_PROMPT ~= "" then
      submit_prompt(view, FOLLOWUP_PROMPT)
    end

    analyze(view)
    delete_all_conversations(project_dir)
    log("artifacts written to %s", OUT_DIR)
  end, debug.traceback)

  restore_command_view()
  for key, value in pairs(old_conf) do config.plugins.assistant[key] = value end
  if not ok then
    close_all_views()
    if view and view.conversation then
      pcall(write_file, OUT_DIR .. PATHSEP .. "conversation.md", view.conversation:to_markdown())
      pcall(preserve_larger_live_raw, view.conversation:raw_responses_text())
    end
    if project_dir then pcall(delete_all_conversations, project_dir) end
    core.error("Assistant %s live failed: %s", AGENT, err)
    print(err)
    core.quit(true, 1)
  else
    close_all_views()
    if project_dir then delete_all_conversations(project_dir) end
    core.quit(true, 0)
  end
end)
