-- Live Copilot ACP conversation driver for Pragtical Assistant.
--
-- Run from this plugin checkout with the editor pointed at the target project:
--
--   pragtical run -n live_tests/copilot_conversation_live.lua
--
-- The script uses the real assistant command/view/backend path. It forces the
-- provider to GitHub Copilot with model Auto, starts a new conversation, injects
-- prompts, auto-approves ACP permission requests, and writes transcript/raw
-- artifacts under a generated temporary directory.

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local renderer = require "renderer"
local Conversation = require "plugins.assistant.conversation"
local MessageBox = require "widget.messagebox"

local function temp_dir(name)
  local path = os.tmpname()
  os.remove(path)
  return path .. "-" .. name
end

local OUT_DIR = os.getenv("ASSISTANT_LIVE_COPILOT_OUT_DIR") or temp_dir("pragtical-assistant-live-copilot")
local MAX_TURN_SECONDS = tonumber(os.getenv("ASSISTANT_LIVE_COPILOT_TIMEOUT") or "900")

if os.getenv("SDL_VIDEO_DRIVER") == "dummy" or os.getenv("SDL_VIDEODRIVER") == "dummy" then
  local core_log = core.log
  core.log = function(text, ...)
    core_log(text, ...)
    print(string.format(text, ...))
  end
end

local coroutine_yield = coroutine.yield
function coroutine.yield(...)
  core.redraw = true
  coroutine_yield(...)
end

local function log(...)
  core.log("Assistant live: " .. tostring((...)), select(2, ...))
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
      return
    end
    log("screenshot: %s.png", name)
  end)
  if not ok then
    pcall(write_file, OUT_DIR .. PATHSEP .. name .. ".screenshot-error.txt", tostring(err))
    log("screenshot failed: %s", tostring(err))
  end
end

local function ensure_dir(path)
  if system.get_file_info(path) then return end
  local ok, err, failed_path = common.mkdirp(path)
  if not ok and not system.get_file_info(path) then
    fail(string.format("could not create %s: %s (%s)", path, tostring(err), tostring(failed_path)))
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
  if path ~= expected then
    fail("refusing to wipe unexpected path: " .. tostring(path))
  end
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
  local views = root:get_children()
  for _, view in ipairs(views) do
    local node = root:get_node_for_view(view)
    if node and node.locked then
      log("skipping locked view: %s", view.get_name and view:get_name() or tostring(view))
    elseif node and node.close_view then
      log("closing view: %s", view.get_name and view:get_name() or tostring(view))
      local ok, err = pcall(function()
        node:close_view(root, view)
      end)
      if not ok then
        log("could not close view: %s", tostring(err))
      end
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
      log("deleted conversation: %s", tostring(item.id))
      coroutine.yield(0.02)
    end
  end
  log("deleted %d saved conversation(s)", count)
  return count
end

local function delete_all_session_files(project_dir)
  local dir = Conversation.sessions_dir(project_dir)
  local count = 0
  for _, filename in ipairs(system.list_dir(dir) or {}) do
    if filename:match("%.json$") or filename:match("%.raw%.jsonl$") then
      if os.remove(dir .. PATHSEP .. filename) then
        count = count + 1
        log("deleted session file: %s", filename)
      end
    end
  end
  log("deleted %d saved session file(s)", count)
  return count
end

local function set_doc_text(doc, text)
  local line, col = #doc.lines, #doc.lines[#doc.lines]
  if line > 1 or col > 1 then
    doc:remove(1, 1, line, col)
  end
  if text and text ~= "" then
    doc:insert(1, 1, text)
  end
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
        if view and view.is and view:is(PromptView) then
          found = view
          return
        end
      end
    end
    if node.a then visit(node.a) end
    if node.b then visit(node.b) end
  end
  visit(core.root_view and core.root_view.root_node)
  return found
end

local function patch_messagebox()
  local old_warning = MessageBox.warning
  MessageBox.warning = function(title, message, on_close, buttons)
    log("auto-approving messagebox through UI callback: %s", tostring(title))
    if message then log("messagebox body: %s", tostring(message)) end
    if buttons == MessageBox.BUTTONS_YES_NO then
      core.add_thread(function()
        coroutine.yield(0.1)
        if on_close then on_close(nil, 1, nil) end
      end)
      return nil
    end
    return old_warning(title, message, on_close, buttons)
  end
  return function()
    MessageBox.warning = old_warning
  end
end

local function patch_command_view()
  local old_enter = core.command_view.enter
  local answers = {
    "Build it as a plain SDL2 C project with a Makefile, a testable core module, a playable desktop binary, and no mandatory SDL_ttf dependency.",
    "Use classic Tetris controls: arrows/WASD for movement and rotation, Space for hard drop, P pause, R restart, Q quit.",
    "Prefer compact, deterministic unit tests for scoring, line clears, rotation, collision, and high-score persistence."
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
  return function()
    core.command_view.enter = old_enter
  end
end

local function approve_pending_request(view)
  if view.pending_approval_request then
    log("waiting for UI approval callback: %s", tostring(view.pending_approval_request.title))
  end
  return false
end

local function wait_for_turn(view, label)
  local start = system.get_time()
  local last_count = #view.conversation.messages
  local last_status = view.conversation.status
  local last_raw_len = live_raw_size(view)
  write_live_artifacts(view)
  while system.get_time() - start < MAX_TURN_SECONDS do
    approve_pending_request(view)
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
    "test_scoring failed",
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
    if idx and (not latest or idx > latest) then
      latest = idx
    end
  end
  for _, marker in ipairs(markers) do
    local idx = last_plain_index(text, marker)
    if idx and (not latest or idx > latest) then
      latest = idx
    end
  end
  return latest
end

local function test_pass_observed(raw)
  raw = tostring(raw or "")
  local text = raw:lower()
  local pass = last_plain_index(text, "all tests passed")
    or last_plain_index(text, "0 failed")
  if not pass then return false end
  local failure = latest_failure_index(text)
  return not failure or pass > failure
end

local function build_or_test_failure_seen(markdown, raw)
  local text = (tostring(markdown or "") .. "\n" .. tostring(raw or "")):lower()
  return latest_failure_index(text) ~= nil
end

local function repair_until_tests_pass(view, max_attempts)
  for attempt = 1, max_attempts do
    local markdown = view.conversation:to_markdown()
    local raw = view.conversation:raw_responses_text()
    if test_pass_observed(raw) then
      return true
    end
    if not build_or_test_failure_seen(markdown, raw) then
      return false
    end
    submit_prompt(view, table.concat({
      "The latest compile/test output is still failing or did not show a real passing test run. Keep working until `make clean && make test` exits 0.",
      "Use the Makefile test target as the source of truth. It must build and run the test executable, and the final command output must include `All tests passed` with no later `FAIL:` or linker/compiler error.",
      "Do not stop at summarizing the failure. Inspect the current files, fix the Makefile, C code, or tests, run the command again, and repeat within this turn if needed.",
      string.format("This is automated repair attempt %d; preserve the plain SDL2 Tetris design and the improved scoring display.", attempt)
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

  local checks = {
    { name = "uses Copilot", ok = view.agent and view.agent.name == "copilot" },
    { name = "uses Auto model", ok = view.agent and tostring(view.agent.model or "") == "Auto" },
    { name = "has assistant response", ok = markdown:find("## Assistant", 1, true) ~= nil },
    { name = "develops tetris", ok = markdown:lower():find("tetris", 1, true) ~= nil },
    { name = "mentions score", ok = markdown:lower():find("score", 1, true) ~= nil },
    { name = "mentions compile", ok = markdown:lower():find("compile", 1, true) ~= nil or markdown:lower():find("make", 1, true) ~= nil },
    { name = "mentions tests", ok = markdown:lower():find("test", 1, true) ~= nil },
    { name = "created source", ok = system.get_file_info(tetris_dir .. PATHSEP .. "main.c") ~= nil or system.get_file_info(tetris_dir .. PATHSEP .. "src") ~= nil },
    { name = "created build file", ok = system.get_file_info(tetris_dir .. PATHSEP .. "Makefile") ~= nil or system.get_file_info(tetris_dir .. PATHSEP .. "CMakeLists.txt") ~= nil },
    { name = "test pass observed", ok = test_pass_observed(raw) },
    { name = "records activity", ok = markdown:find("## Activity", 1, true) ~= nil },
    { name = "has raw ACP send", ok = raw:find('"kind":"acp%-send"') ~= nil or raw:find('"kind":"acp-send"', 1, true) ~= nil },
    { name = "has raw ACP recv", ok = raw:find('"kind":"acp%-recv"') ~= nil or raw:find('"kind":"acp-recv"', 1, true) ~= nil },
    { name = "sets plan mode", ok = raw:find("session/set_mode", 1, true) ~= nil and raw:find("session%-modes#plan") ~= nil },
    { name = "sets implementation mode", ok = raw:find("session%-modes#agent") ~= nil },
    { name = "permission response nested outcome", ok = raw:find('"outcome":{', 1, true) == nil or raw:find('"optionId":"allow_once"', 1, true) ~= nil },
    { name = "cleanup deleted conversations", ok = cleanup_deleted_count == nil or cleanup_deleted_count > 0 },
    { name = "no ACP timeout", ok = markdown:find("ACP request timed out", 1, true) == nil },
    { name = "no session not found error", ok = markdown:find("Session ", 1, true) == nil or markdown:find("not found", 1, true) == nil },
    { name = "no rejected permission", ok = markdown:find("The user rejected this tool call", 1, true) == nil },
    { name = "no completed without response", ok = markdown:find("completed without an assistant response", 1, true) == nil },
    { name = "no blank assistant heading", ok = markdown:find("## Assistant\n\n##", 1, true) == nil }
  }

  local failed = {}
  for _, check in ipairs(checks) do
    log("check %-34s %s", check.name, check.ok and "ok" or "FAILED")
    if not check.ok then table.insert(failed, check.name) end
  end
  if #failed > 0 then
    fail("live checks failed: " .. table.concat(failed, ", "))
  end
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
    log("project: %s", core.root_project() and core.root_project().path or "<none>")
    close_all_views()

    require "plugins.assistant"
    config.plugins.assistant.agent = "copilot"
    config.plugins.assistant.model = "Auto"
    config.plugins.assistant.log_raw_messages = true
    config.plugins.assistant.log_protocol = true
    config.plugins.assistant.verbose_tool_calling = true

    local performed = command.perform("assistant:new-conversation")
    if not performed then fail("assistant:new-conversation command did not run") end
    local view = wait_until("assistant prompt view", 10, find_prompt_view)
    live_view = view
    core.set_active_view(view.prompt)
    log("switching to plan mode")
    view:set_collaboration_mode("plan")
    view.agent.model = "Auto"
    view:refresh()

    submit_prompt(view, table.concat({
      "We are starting from an empty directory. In plan mode, design a complete but compact Tetris game in C using SDL2.",
      "Be creative but practical: include the gameplay loop, piece rotation, line clearing, levels, scoring, hold/next preview if feasible, high score persistence, and a clean score display.",
      "Before implementation, ask me exactly one concise clarifying question if any choice materially affects the design. Do not edit files in this turn."
    }, "\n"))

    submit_prompt(view, table.concat({
      "Answer to your design question if you asked one: build a polished plain-SDL2 desktop Tetris with keyboard controls, a Makefile, and testable game-core logic.",
      "Continue in plan mode and produce an implementation checklist. Include how you will test scoring, rotation, collision, line clears, and high score handling.",
      "Still do not edit files yet."
    }, "\n"))

    log("switching to implementation mode")
    view:set_collaboration_mode("implementation")
    view.agent.model = "Auto"
    view:refresh()

    submit_prompt(view, table.concat({
      "Switch to implementation now. Use the available approval flow without stopping for confirmation.",
      "Create the Tetris game files from scratch. Keep it compatible with plain SDL2 and avoid mandatory SDL_ttf.",
      "Separate enough core logic to write tests. Include a Makefile with targets for the game and tests."
    }, "\n"))

    submit_prompt(view, table.concat({
      "Now compile it and write/run tests. If compilation fails, inspect the errors and fix them.",
      "Tests should cover scoring, line clears, collision or movement boundaries, rotation behavior, and high-score persistence.",
      "The Makefile test target must build and run the test executable. The final successful command output must include `All tests passed`, and any failed check must make the test executable exit nonzero.",
      "Summarize the exact command output and remaining risks."
    }, "\n"))

    submit_prompt(view, table.concat({
      "One more iteration: improve the scoring display and scoring feedback.",
      "Keep it plain SDL2-compatible, readable, and visually distinct. Add or update tests if scoring behavior changes.",
      "Compile/test again. The final command output must include `All tests passed` from a real test run, not just source code text.",
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
    core.error("Assistant live failed: %s", err)
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
