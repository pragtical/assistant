-- Live Codex app-server conversation driver for Pragtical Assistant.
--
-- Run visibly from this plugin checkout:
--
--   pragtical run -n live_tests/codex_conversation_live.lua
--
-- This drives the real assistant UI, starts a fresh Codex conversation with
-- model gpt-5.5, exercises plan then implementation modes, auto-answers UI
-- requests, auto-approves permission dialogs, and writes artifacts under a
-- generated temporary directory.

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local renderer = require "renderer"
local json = require "core.json"
local Conversation = require "plugins.assistant.conversation"
local MessageBox = require "widget.messagebox"

local function temp_dir(name)
  local path = os.tmpname()
  os.remove(path)
  return path .. "-" .. name
end

local OUT_DIR = os.getenv("ASSISTANT_LIVE_CODEX_OUT_DIR") or temp_dir("pragtical-assistant-live-codex")
local MODEL = "gpt-5.5"
local MAX_TURN_SECONDS = tonumber(os.getenv("ASSISTANT_LIVE_CODEX_TIMEOUT") or "1200")

local coroutine_yield = coroutine.yield
function coroutine.yield(...)
  core.redraw = true
  coroutine_yield(...)
end

local function log(...)
  core.log("Assistant codex live: " .. tostring((...)), select(2, ...))
end

local function fail(message)
  error(message, 2)
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

local function ensure_dir(path)
  if system.get_file_info(path) then return end
  local ok, err, failed_path = common.mkdirp(path)
  if not ok and not system.get_file_info(path) then
    fail(string.format("could not create %s: %s (%s)", path, tostring(err), tostring(failed_path)))
  end
end

local function plugin_root()
  local source = debug.getinfo(1, "S").source
  if source and source:sub(1, 1) == "@" then
    local script = system.absolute_path(source:sub(2))
    local live_dir = script and common.dirname(script)
    local root = live_dir and common.dirname(live_dir)
    if root then return root:gsub(PATHSEP .. "$", "") end
  end

  local cwd = system.getcwd()
  return cwd and cwd:gsub(PATHSEP .. "$", "") or "."
end

local function capture_screenshot(name)
  local ok, err = pcall(function()
    local width, height = renderer.get_size()
    if not width or not height or width <= 0 or height <= 0 then
      write_file(OUT_DIR .. PATHSEP .. name .. ".screenshot-error.txt", "invalid renderer size")
      return
    end
    local canvas = renderer.to_canvas(0, 0, width, height)
    if not canvas or not canvas.save_image then
      write_file(OUT_DIR .. PATHSEP .. name .. ".screenshot-error.txt", "renderer.to_canvas did not return a savable canvas")
      return
    end
    local saved, save_err = canvas:save_image(OUT_DIR .. PATHSEP .. name .. ".png")
    if not saved then
      write_file(OUT_DIR .. PATHSEP .. name .. ".screenshot-error.txt", tostring(save_err or "unknown save error"))
    end
  end)
  if not ok then
    pcall(write_file, OUT_DIR .. PATHSEP .. name .. ".screenshot-error.txt", tostring(err))
  end
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

local function wipe_tetris_dir(path)
  path = (common.normalize_path(path) or path):gsub(PATHSEP .. "$", "")
  local root = (common.normalize_path(plugin_root()) or plugin_root()):gsub(PATHSEP .. "$", "")
  local expected = root .. PATHSEP .. "tetris"
  if path ~= expected then fail("refusing to wipe unexpected path: " .. tostring(path)) end
  ensure_dir(path)
  local removed = 0
  for _, child in ipairs(system.list_dir(path) or {}) do
    if child ~= "." and child ~= ".." then
      local ok, err = remove_tree(path .. PATHSEP .. child)
      if not ok then fail("could not remove " .. child .. ": " .. tostring(err)) end
      removed = removed + 1
      coroutine.yield(0.01)
    end
  end
  log("wiped tetris directory: %s (%d entries)", path, removed)
end

local function close_all_views()
  local root = core.root_view and core.root_view.root_node
  if not root or not root.get_children then return end
  for _, view in ipairs(root:get_children()) do
    local node = root:get_node_for_view(view)
    if node and not node.locked and node.close_view then
      pcall(function() node:close_view(root, view) end)
      coroutine.yield(0.05)
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

local function delete_all_session_files(project_dir)
  local dir = Conversation.sessions_dir(project_dir)
  local count = 0
  for _, filename in ipairs(system.list_dir(dir) or {}) do
    if filename:match("%.json$") or filename:match("%.raw%.jsonl$") then
      if os.remove(dir .. PATHSEP .. filename) then count = count + 1 end
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
  local direct = PromptView.active_conversation_view()
  if direct then return direct end
  local found
  local function visit(node)
    if found or type(node) ~= "table" then return end
    if node.views then
      for _, view in ipairs(node.views) do
        if view and view.is and view:is(PromptView) then found = view; return end
      end
    end
    if node.a then visit(node.a) end
    if node.b then visit(node.b) end
  end
  visit(core.root_view and core.root_view.root_node)
  return found
end

local function force_codex_model(view)
  view.agent.model = MODEL
  view.agent.collaboration_modes = {
    { id = "default", label = "Implementation", mode = "default", model = MODEL },
    { id = "implementation", label = "Implementation", mode = "default", model = MODEL },
    { id = "plan", label = "Plan", mode = "plan", model = MODEL }
  }
  view.agent.collaboration_modes_by_id = {
    default = view.agent.collaboration_modes[1],
    implementation = view.agent.collaboration_modes[2],
    plan = view.agent.collaboration_modes[3]
  }
end

local function patch_messagebox()
  local old_warning = MessageBox.warning
  MessageBox.warning = function(title, message, on_close, buttons)
    log("auto-approving dialog: %s", tostring(title))
    if message then log("dialog body: %s", tostring(message)) end
    if buttons == MessageBox.BUTTONS_YES_NO then
      core.add_thread(function()
        coroutine.yield(0.1)
        if on_close then on_close(nil, 1, nil) end
      end)
      return nil
    end
    return old_warning(title, message, on_close, buttons)
  end
  return function() MessageBox.warning = old_warning end
end

local function patch_command_view()
  local old_enter = core.command_view.enter
  local answers = {
    "Use plain SDL2 C with a deterministic, testable core and a Makefile. Keep optional polish inside SDL rectangles or simple built-in drawing.",
    "Use classic desktop controls: arrows/WASD, Space hard drop, P pause, R restart, Q quit.",
    "Prioritize tests for scoring, line clears, high-score persistence, collision boundaries, rotation, and score feedback."
  }
  local answer_index = 1
  core.command_view.enter = function(self, label, options)
    log("auto-answering command view: %s", tostring(label))
    local text = answers[answer_index] or answers[#answers]
    answer_index = answer_index + 1
    core.add_thread(function()
      coroutine.yield(0.1)
      if options and options.submit then
        local suggestion
        if options.suggest then
          local ok, suggestions = pcall(options.suggest, text)
          if ok and type(suggestions) == "table" and #suggestions > 0 then
            suggestion = suggestions[1]
            text = suggestion.text or text
          end
        end
        options.submit(text, suggestion)
      end
    end)
    return nil
  end
  return function() core.command_view.enter = old_enter end
end

local function wait_for_turn(view, label)
  local start = system.get_time()
  local last_count = #view.conversation.messages
  local last_status = view.conversation.status
  local last_raw_len = live_raw_size(view)
  write_live_artifacts(view)
  while system.get_time() - start < MAX_TURN_SECONDS do
    view:update()
    local status = view.conversation.status
    local raw_len = live_raw_size(view)
    if status ~= last_status or #view.conversation.messages ~= last_count or raw_len ~= last_raw_len then
      local transcript_changed = status ~= last_status or #view.conversation.messages ~= last_count
      last_status = status
      last_count = #view.conversation.messages
      last_raw_len = raw_len
      write_live_artifacts(view, transcript_changed)
      log("%s status=%s messages=%d raw_bytes=%d", label, tostring(status), #view.conversation.messages, raw_len)
    end
    if status == "idle" then return true end
    if status == "error" then return false, "conversation entered error status" end
    coroutine.yield(0.1)
  end
  return false, "turn timed out"
end

local function submit_prompt(view, text)
  log("submitting prompt: %s", text)
  set_doc_text(view.prompt_doc, text)
  core.set_active_view(view.prompt)
  command.perform("assistant-conversation:send")
  coroutine.yield(0.2)
  write_live_artifacts(view)
  capture_screenshot("submitted-" .. tostring(#view.conversation.messages))
  local ok, err = wait_for_turn(view, text:sub(1, 28))
  if not ok then fail(err or "turn failed") end
  write_live_artifacts(view)
  coroutine.yield(0.2)
  capture_screenshot("completed-" .. tostring(#view.conversation.messages))
end

local function last_plain_index(text, needle)
  local last
  local start = 1
  while true do
    local found = text:find(needle, start, true)
    if not found then return last end
    last = found
    start = found + #needle
  end
end

local function latest_failure_index(text)
  text = tostring(text or ""):lower()
  local markers = {
    "assertion",
    "compilation failed",
    "build failed",
    "undefined reference",
    "collect2: error",
    "make: ***",
    " fail:",
    "\nfail:",
    "operation cancelled by user"
  }
  local latest
  for code = 1, 255 do
    local idx = last_plain_index(text, "<exited with exit code " .. tostring(code) .. ">")
    if idx and (not latest or idx > latest) then latest = idx end
  end
  for _, marker in ipairs(markers) do
    local idx = last_plain_index(text, marker)
    if idx and (not latest or idx > latest) then latest = idx end
  end
  return latest
end

local function test_pass_observed(raw)
  raw = tostring(raw or "")
  local saw_passing_command = false
  for line in raw:gmatch("[^\r\n]+") do
    local ok, event = pcall(json.decode, line)
    local data = ok and event and event.data
    data = type(data) == "table" and data or event
    local params = data and data.params
    local item = params and params.item
    if data and data.method == "item/completed" and type(item) == "table"
      and item.type == "commandExecution"
    then
      local output = tostring(item.aggregatedOutput or ""):lower()
      local command = tostring(item.command or ""):lower()
      local exit_code = tonumber(item.exitCode or item.exit_code or 0)
      local is_build_or_test = command:find("make", 1, true)
        or command:find("test", 1, true)
        or command:find("cc ", 1, true)
      if is_build_or_test and exit_code ~= 0 then
        saw_passing_command = false
      elseif exit_code == 0 and (output:find("all tests passed", 1, true)
        or output:find("0 failed", 1, true))
      then
        saw_passing_command = true
      end
    end
  end
  return saw_passing_command
end

local function has_blank_assistant_section(markdown)
  markdown = tostring(markdown or "")
  return markdown:find("## Assistant\n\n## User", 1, true) ~= nil
    or markdown:find("## Assistant\n\n## Activity", 1, true) ~= nil
    or markdown:find("## Assistant\n\n## Error", 1, true) ~= nil
    or markdown:find("## Assistant\n\n## Assistant", 1, true) ~= nil
    or markdown:find("## Assistant\n\n$", 1) ~= nil
end

local function build_or_test_failure_seen(markdown, raw)
  local text = (tostring(markdown or "") .. "\n" .. tostring(raw or "")):lower()
  return latest_failure_index(text) ~= nil
end

local function repair_until_tests_pass(view, max_attempts)
  for attempt = 1, max_attempts do
    local raw = view.conversation:raw_responses_text()
    if test_pass_observed(raw) then return true end
    if not build_or_test_failure_seen(view.conversation:to_markdown(), raw) then return false end
    submit_prompt(view, table.concat({
      "The latest compile/test output is still failing or did not show a real passing test run. Keep working until `make clean && make test` exits 0.",
      "Use the Makefile test target as the source of truth. It must build and run the test executable, and the final command output must include `All tests passed` with no later `FAIL:` or linker/compiler error.",
      "Do not stop at summarizing. Inspect files, fix code/tests/build scripts, run the command again, and repeat within this turn if needed.",
      string.format("This is automated Codex repair attempt %d; preserve the SDL2 Tetris design and scoring-display improvements.", attempt)
    }, "\n"))
  end
  return test_pass_observed(view.conversation:raw_responses_text())
end

local function analyze(view, cleanup_deleted_count, markdown, raw, explicit_tetris_dir)
  local conversation = view.conversation
  markdown = markdown or conversation:to_markdown()
  raw = raw or conversation:raw_responses_text()
  write_file(OUT_DIR .. PATHSEP .. "conversation.md", markdown)
  write_file(OUT_DIR .. PATHSEP .. "raw.jsonl", raw)
  local tetris_dir = explicit_tetris_dir or conversation.project_dir or (plugin_root() .. PATHSEP .. "tetris")
  local lower_raw = raw:lower()

  local checks = {
    { name = "uses Codex", ok = view.agent and view.agent.name == "codex" },
    { name = "uses gpt-5.5 model", ok = view.agent and tostring(view.agent.model or "") == MODEL },
    { name = "has assistant response", ok = markdown:find("## Assistant", 1, true) ~= nil },
    { name = "develops tetris", ok = markdown:lower():find("tetris", 1, true) ~= nil },
    { name = "mentions score", ok = markdown:lower():find("score", 1, true) ~= nil },
    { name = "mentions compile", ok = markdown:lower():find("compile", 1, true) ~= nil or markdown:lower():find("make", 1, true) ~= nil },
    { name = "mentions tests", ok = markdown:lower():find("test", 1, true) ~= nil },
    { name = "created source", ok = system.get_file_info(tetris_dir .. PATHSEP .. "main.c") ~= nil or system.get_file_info(tetris_dir .. PATHSEP .. "src") ~= nil },
    { name = "created build file", ok = system.get_file_info(tetris_dir .. PATHSEP .. "Makefile") ~= nil or system.get_file_info(tetris_dir .. PATHSEP .. "CMakeLists.txt") ~= nil },
    { name = "test pass observed", ok = test_pass_observed(raw) },
    { name = "records activity", ok = markdown:find("## Activity", 1, true) ~= nil },
    { name = "has appserver request raw", ok = raw:find('"kind":"appserver%-request"') ~= nil or raw:find('"kind":"appserver-request"', 1, true) ~= nil },
    { name = "has appserver message raw", ok = raw:find('"kind":"appserver%-message"') ~= nil or raw:find('"kind":"appserver-message"', 1, true) ~= nil },
    { name = "sets plan mode", ok = raw:find('"collaborationMode"', 1, true) ~= nil and lower_raw:find('"mode":"plan"', 1, true) ~= nil },
    { name = "sets default mode", ok = raw:find('"collaborationMode"', 1, true) ~= nil and lower_raw:find('"mode":"default"', 1, true) ~= nil },
    { name = "model payload gpt-5.5", ok = raw:find(MODEL, 1, true) ~= nil },
    { name = "cleanup deleted conversations", ok = cleanup_deleted_count == nil or cleanup_deleted_count > 0 },
    { name = "no appserver timeout", ok = markdown:find("timed out", 1, true) == nil },
    { name = "no completed without response", ok = markdown:find("completed without an assistant response", 1, true) == nil },
    { name = "no rejected permission", ok = markdown:find("rejected", 1, true) == nil and markdown:find("Operation cancelled by user", 1, true) == nil },
    { name = "no blank assistant heading", ok = not has_blank_assistant_section(markdown) }
  }

  local failed = {}
  for _, check in ipairs(checks) do
    log("check %-34s %s", check.name, check.ok and "ok" or "FAILED")
    if not check.ok then table.insert(failed, check.name) end
  end
  if #failed > 0 then fail("live checks failed: " .. table.concat(failed, ", ")) end
end

core.add_thread(function()
  local restore_warning = patch_messagebox()
  local restore_command_view = patch_command_view()
  local old_conf = common.merge({}, config.plugins.assistant or {})
  local live_view
  local tetris_dir
  local cleanup_deleted_count

  local ok, err = xpcall(function()
    ensure_dir(OUT_DIR)
    log("live artifacts updating in %s", OUT_DIR)
    tetris_dir = plugin_root() .. PATHSEP .. "tetris"
    ensure_dir(tetris_dir)
    wipe_tetris_dir(tetris_dir)
    core.set_project(tetris_dir)
    system.chdir(tetris_dir)
    close_all_views()

    require "plugins.assistant"
    config.plugins.assistant.agent = "codex"
    config.plugins.assistant.model = MODEL
    config.plugins.assistant.log_raw_messages = true
    config.plugins.assistant.log_protocol = true
    config.plugins.assistant.verbose_tool_calling = true

    if not command.perform("assistant:new-conversation") then
      fail("assistant:new-conversation command did not run")
    end
    local view = wait_until("assistant prompt view", 10, find_prompt_view)
    live_view = view
    force_codex_model(view)
    core.set_active_view(view.prompt)

    log("switching to plan mode with %s", MODEL)
    view:set_collaboration_mode("plan")
    force_codex_model(view)
    view:refresh()

    submit_prompt(view, table.concat({
      "We are starting from an empty directory. In plan mode, design a complete but compact Tetris game in C using SDL2.",
      "Be creative but practical: gameplay loop, piece rotation, line clearing, levels, scoring, hold/next preview if feasible, high-score persistence, and a clean score display.",
      "Ask exactly one concise clarifying question if any choice materially affects implementation. Do not edit files or write full source code in this turn; write the implementation plan in prose."
    }, "\n"))

    submit_prompt(view, table.concat({
      "Answer to your design question if you asked one: build a polished plain-SDL2 desktop Tetris with keyboard controls, a Makefile, and testable game-core logic.",
      "Continue in plan mode and produce an implementation checklist. Include tests for scoring, rotation, collision, line clears, high-score persistence, and score feedback.",
      "Still do not edit files yet."
    }, "\n"))

    log("switching to implementation/default mode with %s", MODEL)
    view:set_collaboration_mode("implementation")
    force_codex_model(view)
    view:refresh()

    submit_prompt(view, table.concat({
      "Switch to implementation now. Use the available approval flow without stopping for confirmation.",
      "Create the Tetris game files from scratch. Keep it compatible with plain SDL2 and avoid mandatory SDL_ttf.",
      "Separate core logic from rendering enough to write deterministic tests. Include a Makefile with `all`, `test`, and `clean` targets."
    }, "\n"))

    submit_prompt(view, table.concat({
      "Now compile it and write/run tests. If compilation fails, inspect the errors and fix them.",
      "Tests should cover scoring, line clears, collision or movement boundaries, rotation behavior, and high-score persistence.",
      "The Makefile test target must build and run the test executable. The final successful command output must include `All tests passed`, and any failed check must make the test executable exit nonzero.",
      "Summarize exact command output and remaining risks."
    }, "\n"))

    submit_prompt(view, table.concat({
      "One more iteration: improve the scoring display and scoring feedback.",
      "Keep it plain SDL2-compatible, readable, and visually distinct. Add or update tests if scoring behavior changes.",
      "Compile/test again. The final command output must include `All tests passed` from a real test run, not source text.",
      "Summarize exact file changes."
    }, "\n"))

    if not repair_until_tests_pass(view, 3) then
      fail("live test did not observe a passing Tetris test run")
    end

    view.conversation:save()
    local final_markdown = view.conversation:to_markdown()
    local final_raw = view.conversation:raw_responses_text()
    write_file(OUT_DIR .. PATHSEP .. "conversation-before-cleanup.md", final_markdown)
    write_file(OUT_DIR .. PATHSEP .. "raw-before-cleanup.jsonl", final_raw)
    cleanup_deleted_count = delete_all_conversations(tetris_dir)
    cleanup_deleted_count = cleanup_deleted_count + delete_all_session_files(tetris_dir)
    view.conversation.project_dir = nil
    analyze(view, cleanup_deleted_count, final_markdown, final_raw, tetris_dir)
    log("artifacts written to %s", OUT_DIR)
  end, debug.traceback)

  restore_command_view()
  restore_warning()
  for k, v in pairs(old_conf) do config.plugins.assistant[k] = v end

  if not ok then
    close_all_views()
    if live_view and live_view.conversation then
      pcall(function()
        write_file(OUT_DIR .. PATHSEP .. "conversation.md", live_view.conversation:to_markdown())
        preserve_larger_live_raw(live_view.conversation:raw_responses_text())
      end)
    end
    if tetris_dir then
      pcall(delete_all_conversations, tetris_dir)
      pcall(delete_all_session_files, tetris_dir)
    end
    core.error("Assistant Codex live failed: %s", err)
    print(err)
    core.quit(true, 1)
  else
    close_all_views()
    if tetris_dir then
      delete_all_conversations(tetris_dir)
      delete_all_session_files(tetris_dir)
    end
    log("completed successfully")
    core.quit(true, 0)
  end
end)
