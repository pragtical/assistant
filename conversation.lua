local core = require "core"
local common = require "core.common"
local config = require "core.config"
local jsonutil = require "plugins.assistant.jsonutil"
local permission = require "plugins.assistant.permission"
local Tool = require "plugins.assistant.tool"
local Object = require "core.object"

---Project-local assistant conversation state and persistence.
---
---A conversation owns the ordered transcript, project context snapshot,
---provider usage, local compaction metadata, raw provider logs, and session
---approval state. It also converts the local transcript to provider messages
---and rendered Markdown.
---@class assistant.Conversation : core.object
---@field id string
---@field title string
---@field project_dir string
---@field agent string
---@field backend string
---@field model string|nil
---@field collaboration_mode string|nil
---@field local_compaction table|nil
---@field assistant_plan table|nil
---@field codex_thread_id string|nil
---@field acp_session_id string|nil
---@field options table
---@field status string
---@field usage table|nil
---@field approved_command_prefixes string[]
---@field approved_tools string[]
---@field messages table[]
---@field project_instructions string|nil
---@field memories table[]
---@field context_snapshot table|nil
---@field environment_context table|nil
---@field super core.object
local Conversation = Object:extend()
local FILE_CHUNK_SIZE = 64 * 1024

Conversation.SESSION_SUBDIR = ".pragtical" .. PATHSEP .. "assistant" .. PATHSEP .. "sessions"
Conversation.MEMORY_SUBDIR = ".pragtical" .. PATHSEP .. "assistant" .. PATHSEP .. "memories"
Conversation.LOG_SUBDIR = ".pragtical" .. PATHSEP .. "assistant" .. PATHSEP .. "logs"

local VALID_ROLES = {
  system = true,
  assistant = true,
  user = true,
  activity = true,
  tool_call = true,
  tool_result = true,
  error = true
}

---Handle now.
local function now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

---Handle yield ui.
local function yield_ui()
  if coroutine.isyieldable() then
    core.redraw = true
    coroutine.yield()
  end
end

---Read file.
local function read_file(path)
  local fp = io.open(path, "rb")
  if not fp then return nil end
  local chunks = {}
  while true do
    local chunk = fp:read(FILE_CHUNK_SIZE)
    if not chunk then break end
    table.insert(chunks, chunk)
    yield_ui()
  end
  fp:close()
  yield_ui()
  return table.concat(chunks)
end

---Write file.
local function write_file(path, text)
  local fp, err = io.open(path, "wb")
  if not fp then return false, err end
  text = tostring(text or "")
  for index = 1, #text, FILE_CHUNK_SIZE do
    fp:write(text:sub(index, index + FILE_CHUNK_SIZE - 1))
    yield_ui()
  end
  fp:close()
  yield_ui()
  return true
end

---Load a Lua file that returns a table.
---@param path string
---@return table|nil value
local function load_table(path)
  if not system.get_file_info(path) then return nil end
  local chunk, err = loadfile(path, "t", {})
  if not chunk then
    core.error("Assistant: could not load %s: %s", path, err)
    return nil
  end
  local ok, value = pcall(chunk)
  if not ok then
    core.error("Assistant: could not read %s: %s", path, value)
    return nil
  end
  if type(value) ~= "table" then return nil end
  return value
end

---Write a Lua file that returns a serialized table.
---@param path string
---@param value table
---@return boolean
local function write_table(path, value)
  return write_file(path, "return " .. common.serialize(value, {
    pretty = true,
    sort = true
  }))
end

---Handle sanitize id.
local function sanitize_id(text)
  text = tostring(text or ""):gsub("[^%w%._%-]", "-")
  text = text:gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
  return text ~= "" and text or nil
end

---Handle make id.
local function make_id()
  return string.format(
    "%s-%06x",
    os.date("!%Y%m%d%H%M%S"),
    math.random(0, 0xffffff)
  )
end

---Handle project dir or default.
local function project_dir_or_default(project_dir)
  if project_dir and project_dir ~= "" then
    return common.normalize_path(project_dir) or project_dir
  end
  return core.root_project() and core.root_project().path or "."
end

---Handle mkdirp.
local function mkdirp(path)
  local info = system.get_file_info(path)
  if info and info.type == "dir" then return true end
  local ok, err = common.mkdirp(path)
  if not ok then
    core.error("Assistant: could not create directory %s: %s", path, err)
  end
  return ok
end

---Handle split lines.
local function split_lines(text)
  local lines = {}
  local count = 0
  for line in ((text or "") .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, line)
    count = count + 1
    if count % 200 == 0 then yield_ui() end
  end
  return lines
end

---Handle markdown quote.
local function markdown_quote(text)
  local lines = split_lines(text)
  for i, line in ipairs(lines) do
    lines[i] = "> " .. line
  end
  return table.concat(lines, "\n")
end

---Handle display limited.
local function display_limited(text, limit)
  text = tostring(text or "")
  limit = limit or 12000
  if #text <= limit then return text end
  return text:sub(1, limit) .. "\n\n... truncated for transcript ..."
end

---Handle fenced.
local function fenced(text, language)
  text = display_limited(text)
  return "```" .. (language or "text") .. "\n" .. text .. "\n```"
end

---Handle apply patch markdown.
local function apply_patch_markdown(msg)
  local call = msg.meta and msg.meta.call
  local patch = call and call.arguments and call.arguments.patch
  if call and call.name == "apply_patch" and type(patch) == "string" and patch ~= "" then
    return table.concat({
      "## Tool call",
      "",
      "Tool: `apply_patch`",
      "",
      "Arguments:",
      "",
      fenced(patch, "diff")
    }, "\n")
  end
end

---Handle verbose tool calling.
local function verbose_tool_calling()
  local conf = config.plugins and config.plugins.assistant or {}
  return conf.verbose_tool_calling == true
end

---Return whether activity messages should render as full sections.
---@return boolean
local function verbose_activity()
  local conf = config.plugins and config.plugins.assistant or {}
  return conf.verbose_activity == true
end

---Return the first captured field from an activity body.
---@param text string
---@param name string
---@return string|nil
local function activity_field(text, name)
  return tostring(text or ""):match("\n" .. name .. ":%s*`([^`\n]+)`")
    or tostring(text or ""):match("^" .. name .. ":%s*`([^`\n]+)`")
    or tostring(text or ""):match("\n" .. name .. ":%s*([^\n]+)")
    or tostring(text or ""):match("^" .. name .. ":%s*([^\n]+)")
end

---Return the first fenced diff block in an activity body.
---@param text string
---@return string|nil
local function activity_diff(text)
  return tostring(text or ""):match("```diff\n.-\n```")
end

---Return the first backticked line after an activity heading.
---@param text string
---@return string|nil
local function activity_first_ticked_line(text)
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    local value = line:match("^`([^`]+)`%s*$")
    if value then return value end
  end
end

---Append a status suffix.
---@param status string|nil
---@return string
local function activity_status(status)
  status = tostring(status or "")
  return status ~= "" and " (" .. status .. ")" or ""
end

---Wrap an activity target in backticks, or link existing files.
---@param value string|nil
---@param fallback string
---@param project_dir string|nil
---@return string
local function activity_target(value, fallback, project_dir)
  value = tostring(value or "")
  return Tool.file_link_or_ticked(value, { project_dir = project_dir }, fallback)
end

---Return fallback compact Markdown for an activity message.
---@param msg table
---@param project_dir string|nil
---@return string
local function compact_activity_markdown(msg, project_dir)
  local text = tostring(msg and msg.message or "")
  if text == "" then return nil end
  if msg.meta and msg.meta.compact_activity_markdown then
    return tostring(msg.meta.compact_activity_markdown)
  end

  local reasoning = text:match("^Reasoning%s*\n\n(.*)$")
  if reasoning then return "## Reasoning\n\n" .. reasoning end
  if not text:find("\n", 1, true) and text:match("^[%w%s]+$") then return "**" .. text .. "**" end

  local status = activity_field(text, "Status")
  local tool = activity_field(text, "Tool")
  local command = activity_field(text, "Command") or activity_first_ticked_line(text)
  local cwd = activity_field(text, "Cwd")
  local path = activity_field(text, "Path") or activity_first_ticked_line(text)
  local url = activity_field(text, "URL")
  local diff = activity_diff(text)

  if text:find("^Running command", 1, false) then
    if tool then
      local line = "**Running command**: " .. Tool.ticked(command or "command")
      if cwd and cwd ~= "" then line = line .. " in " .. Tool.ticked(cwd) end
      return line .. activity_status(status)
    end
    return "**Running**: " .. Tool.ticked(command or "command") .. activity_status(status)
  end

  if text:find("^Editing files", 1, false) then
    local label = tool and "**Patching**: " or "**Editing**: "
    local line = label .. activity_target(path, "file", project_dir) .. activity_status(status)
    return diff and (line .. "\n\n" .. diff) or line
  end

  if text:find("^Inspecting project", 1, false) then
    if tool == "read" then
      return "**Reading**: " .. activity_target(path, "path", project_dir) .. activity_status(status)
    end
    local target = path or activity_field(text, "Directory") or activity_field(text, "Query")
    local directory = activity_field(text, "Directory")
    local rendered = directory
      and Tool.relative_path_or_ticked(target, { project_dir = project_dir }, "target")
      or activity_target(target, "target", project_dir)
    return "**Inspecting project**: " .. rendered .. activity_status(status)
  end

  if text:find("^Searching web", 1, false) then
    return "**Searching web**: " .. tostring(url or "web") .. activity_status(status)
  end

  if text:find("^Calling tool", 1, false) then
    if tool == "time" then return "**Checking Time**:" .. activity_status(status) end
    return "**Calling " .. tostring(tool or "tool") .. "**:" .. activity_status(status)
  end

  local title = text:match("^([^\n]+)\n.+$")
  if title and (path or status) and not title:find(": ", 1, true) then
    local target = path and path ~= "" and (" " .. activity_target(path, "file", project_dir)) or ""
    local line = "**" .. title .. "**:" .. target .. activity_status(status)
    return diff and (line .. "\n\n" .. diff) or line
  end

  local thinking = text:match("^Thinking:%s*(.*)$")
  if thinking then return "**Thinking**: " .. thinking end

  local permission_title, permission_body = text:match("^Permission requested:%s*([^\n]+)\n?(.*)$")
  if permission_title then
    local command_text = tostring(permission_body or ""):match("`([^`]+)`")
    if command_text then return "**Permission requested**: Run `" .. command_text .. "`" end
    return "**Permission requested**: " .. permission_title
  end

  local first, rest = text:match("^([^\n:]+):%s*(.*)$")
  if first and rest and rest ~= "" then return "**" .. first .. "**: " .. rest end
  first, rest = text:match("^([^\n]+)\n\n(.*)$")
  if first and rest and rest ~= "" then return "**" .. first .. "**: " .. rest end
  return "**Activity**: " .. text
end

---Handle sessions dir.
---@param project_dir string|nil
---@return string
function Conversation.sessions_dir(project_dir)
  return project_dir_or_default(project_dir) .. PATHSEP .. Conversation.SESSION_SUBDIR
end

---Handle memories dir.
---@param project_dir string|nil
---@return string
function Conversation.memories_dir(project_dir)
  return project_dir_or_default(project_dir) .. PATHSEP .. Conversation.MEMORY_SUBDIR
end

---Handle logs dir.
---@param project_dir string|nil
---@return string
function Conversation.logs_dir(project_dir)
  return project_dir_or_default(project_dir) .. PATHSEP .. Conversation.LOG_SUBDIR
end

---Handle session path.
---@param project_dir string|nil
---@param id string
---@return string
function Conversation.session_path(project_dir, id)
  return Conversation.sessions_dir(project_dir) .. PATHSEP .. assert(sanitize_id(id), "invalid session id") .. ".lua"
end

---Handle raw responses path.
---@param project_dir string|nil
---@param id string
---@return string
function Conversation.raw_responses_path(project_dir, id)
  return Conversation.sessions_dir(project_dir) .. PATHSEP .. assert(sanitize_id(id), "invalid session id") .. ".raw.jsonl"
end

---Handle log path.
---@param project_dir string|nil
---@param name string
---@return string
function Conversation.log_path(project_dir, name)
  return Conversation.logs_dir(project_dir) .. PATHSEP .. assert(sanitize_id(name), "invalid log name") .. ".log"
end

---Handle memory path.
---@param project_dir string|nil
---@param id string
---@return string
function Conversation.memory_path(project_dir, id)
  return Conversation.memories_dir(project_dir) .. PATHSEP .. assert(sanitize_id(id), "invalid memory id") .. ".lua"
end

---Read project instructions.
---@param project_dir string|nil
---@return string|nil
function Conversation.read_project_instructions(project_dir)
  return read_file(project_dir_or_default(project_dir) .. PATHSEP .. "AGENTS.md")
end

---List memories.
---@param project_dir string|nil
---@return table[] memories
function Conversation.list_memories(project_dir)
  local dir = Conversation.memories_dir(project_dir)
  local result = {}
  for _, filename in ipairs(system.list_dir(dir) or {}) do
    if filename:match("%.lua$") then
      local decoded = load_table(dir .. PATHSEP .. filename)
      if type(decoded) == "table" then
        table.insert(result, decoded)
      end
    end
  end
  table.sort(result, function(a, b)
    return tostring(a.updated_at or a.created_at or "") > tostring(b.updated_at or b.created_at or "")
  end)
  return result
end

---Add memory.
---@param project_dir string|nil
---@param title string
---@param content string
---@return table|nil memory
function Conversation.add_memory(project_dir, title, content)
  project_dir = project_dir_or_default(project_dir)
  if not mkdirp(Conversation.memories_dir(project_dir)) then return nil end
  local item = {
    id = make_id(),
    title = title or "Memory",
    content = content or "",
    created_at = now(),
    updated_at = now()
  }
  local ok = write_table(Conversation.memory_path(project_dir, item.id), item)
  return ok and item or nil
end

local function truncate_title(text, limit)
  text = tostring(text or ""):gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
  limit = limit or 80
  if #text <= limit then return text end
  return text:sub(1, limit - 3) .. "..."
end

local function compaction_memory_title(conversation)
  local title = truncate_title(conversation.title or "Conversation", 72)
  if title == "" then title = "Conversation" end
  return "Compacted Conversation: " .. title
end

local function compaction_memory_content(conversation, compaction)
  return table.concat({
    "Conversation: " .. tostring(conversation.title or conversation.id or "Conversation"),
    "Conversation ID: " .. tostring(conversation.id or ""),
    "Trigger: " .. tostring(compaction.trigger or "manual"),
    "Compacted at: " .. tostring(compaction.created_at or now()),
    "Messages summarized: " .. tostring(compaction.source_message_count or compaction.message_count or 0),
    "",
    tostring(compaction.summary or "")
  }, "\n")
end

---Store or update the project memory that mirrors the latest compaction.
---@return table|nil memory
function Conversation:store_local_compaction_memory()
  if not (self.local_compaction and self.local_compaction.summary ~= "") then return nil end
  local title = compaction_memory_title(self)
  local content = compaction_memory_content(self, self.local_compaction)
  local memory_id = self.local_compaction.memory_id
  local memory
  if memory_id then
    memory = Conversation.update_memory(self.project_dir, memory_id, title, content)
  end
  if not memory then
    for _, item in ipairs(Conversation.list_memories(self.project_dir)) do
      local meta = item.meta or {}
      if meta.local_compaction_conversation_id == self.id then
        memory = Conversation.update_memory(self.project_dir, item.id, title, content)
        break
      end
    end
  end
  if not memory then
    memory = Conversation.add_memory(self.project_dir, title, content)
  end
  if memory then
    memory.meta = memory.meta or {}
    memory.meta.local_compaction_conversation_id = self.id
    memory.meta.local_compaction = true
    memory.meta.local_compaction_trigger = self.local_compaction.trigger or "manual"
    write_table(Conversation.memory_path(self.project_dir, memory.id), memory)
    self.local_compaction.memory_id = memory.id
    self.memories = Conversation.list_memories(self.project_dir)
  end
  return memory
end

---Update memory.
---@param project_dir string|nil
---@param id string
---@param title string
---@param content string
---@return table|nil memory
function Conversation.update_memory(project_dir, id, title, content)
  project_dir = project_dir_or_default(project_dir)
  id = sanitize_id(id)
  if not id then return nil end
  local path = Conversation.memory_path(project_dir, id)
  local decoded = load_table(path)
  if type(decoded) ~= "table" then return nil end
  decoded.id = id
  decoded.title = title or decoded.title or "Memory"
  decoded.content = content or decoded.content or ""
  decoded.created_at = decoded.created_at or now()
  decoded.updated_at = now()
  local ok = write_table(path, decoded)
  return ok and decoded or nil
end

---Delete memory.
---@param project_dir string|nil
---@param id string
---@return boolean
function Conversation.delete_memory(project_dir, id)
  local path = Conversation.memory_path(project_dir, id)
  if system.get_file_info(path) then
    os.remove(path)
    return true
  end
  return false
end

---Create a new instance.
---@param agent assistant.Agent|nil
---@param project_dir string|nil
function Conversation:new(agent, project_dir)
  self.id = make_id()
  self.title = "Assistant Session"
  self.project_dir = project_dir_or_default(project_dir)
  self.agent = agent and agent.name or "generic"
  self.backend = agent and agent.backend or "http"
  self.model = agent and agent.model or nil
  self.reasoning_effort = agent and agent.reasoning_effort or nil
  self.collaboration_mode = nil
  self.local_compaction = nil
  self.assistant_plan = nil
  self.environment_context = nil
  self.codex_thread_id = nil
  self.acp_session_id = nil
  self.options = agent and common.merge({}, agent.options or {}) or {}
  self.status = "idle"
  self.usage = nil
  self.approved_command_prefixes = {}
  self.approved_tools = {}
  self.messages = {}
  self.created_at = now()
  self.updated_at = self.created_at
  self.project_instructions = Conversation.read_project_instructions(self.project_dir)
  self.memories = Conversation.list_memories(self.project_dir)
  self.context_snapshot = agent and agent.context_snapshot
    and agent:context_snapshot(self.project_dir, self.project_instructions)
    or nil
  if agent and agent.get_role_message then
    self:add("system", agent:get_role_message(self.project_dir, self.project_instructions), { autosave = false })
  end
  self:refresh_environment_context(agent, { force = true, autosave = false })
end

---Refresh the conversation update timestamp.
function Conversation:touch()
  self.updated_at = now()
end

---Handle snapshots equal.
local function snapshots_equal(left, right)
  if type(left) ~= "table" or type(right) ~= "table" then return false end
  if left.agent ~= right.agent
    or left.model ~= right.model
    or left.project_dir ~= right.project_dir
  then
    return false
  end
  local left_fragments = left.fragments or {}
  local right_fragments = right.fragments or {}
  if #left_fragments ~= #right_fragments then return false end
  for index, left_fragment in ipairs(left_fragments) do
    local right_fragment = right_fragments[index]
    if not right_fragment
      or left_fragment.id ~= right_fragment.id
      or left_fragment.bytes ~= right_fragment.bytes
      or left_fragment.hash ~= right_fragment.hash
    then
      return false
    end
  end
  return true
end

---Handle environment snapshots equal.
---@param left table|nil
---@param right table|nil
---@return boolean equal
local function environment_snapshots_equal(left, right)
  if type(left) ~= "table" or type(right) ~= "table" then return false end
  if left.hash and right.hash then return left.hash == right.hash end
  return left.agent == right.agent
    and left.project_dir == right.project_dir
    and left.cwd == right.cwd
    and left.shell == right.shell
    and left.current_date == right.current_date
    and left.timezone == right.timezone
    and left.platform == right.platform
    and left.architecture == right.architecture
    and left.path_separator == right.path_separator
end

---Handle refresh context.
---@param agent assistant.Agent|nil
---@return boolean changed
function Conversation:refresh_context(agent)
  if not (agent and agent.context_snapshot and agent.get_role_message) then return false end
  local project_instructions = Conversation.read_project_instructions(self.project_dir)
  local memories = Conversation.list_memories(self.project_dir)
  local snapshot = agent:context_snapshot(self.project_dir, project_instructions)
  local role_message = agent:get_role_message(self.project_dir, project_instructions)
  local current_system_message
  for _, message in ipairs(self.messages or {}) do
    if message.role == "system" then
      current_system_message = message
      break
    end
  end
  if snapshots_equal(self.context_snapshot, snapshot)
    and current_system_message
    and current_system_message.message == role_message
  then
    self.project_instructions = project_instructions
    self.memories = memories
    self.context_snapshot = snapshot
    return false
  end

  self.project_instructions = project_instructions
  self.memories = memories
  self.context_snapshot = snapshot
  for _, message in ipairs(self.messages or {}) do
    if message.role == "system" then
      message.message = role_message
      self:touch()
      self:save()
      return true
    end
  end
  table.insert(self.messages, 1, {
    role = "system",
    message = role_message,
    created_at = now()
  })
  self:touch()
  self:save()
  return true
end

---Refresh runtime environment context.
---@param agent assistant.Agent|nil
---@param options table|nil
---@return boolean changed
function Conversation:refresh_environment_context(agent, options)
  if not (agent and agent.environment_context_message) then return false end
  local message = agent:environment_context_message(self.project_dir)
  local meta = message.meta or {}
  local snapshot = meta.environment_snapshot
  if not (options and options.force)
    and environment_snapshots_equal(self.environment_context, snapshot)
  then
    return false
  end

  local entry = {
    role = message.role or "user",
    message = message.content or "",
    meta = meta,
    created_at = now()
  }
  local insert_at = #self.messages + 1
  local last = self.messages[#self.messages]
  if last
    and last.role == "user"
    and not (last.meta and (last.meta.contextual or last.meta.provider_only))
  then
    insert_at = #self.messages
  end
  table.insert(self.messages, insert_at, entry)
  self.environment_context = snapshot
  self:touch()
  if not (options and options.autosave == false) then
    self:save()
  end
  return true
end

---Add add.
---@param role string
---@param message string
---@param options table|nil
---@return table entry
function Conversation:add(role, message, options)
  assert(VALID_ROLES[role], "invalid assistant message role: " .. tostring(role))
  local entry = {
    role = role,
    message = message or "",
    meta = options and options.meta or nil,
    created_at = now()
  }
  table.insert(self.messages, entry)
  self:touch()
  if not (options and options.autosave == false) then
    self:save()
  end
  return entry
end

---Handle last.
---@return table|nil
function Conversation:last()
  return self.messages[#self.messages]
end

---Handle remove.
---@param entry table
---@return boolean removed
function Conversation:remove(entry)
  for i, item in ipairs(self.messages) do
    if item == entry then
      table.remove(self.messages, i)
      self:touch()
      return true
    end
  end
  return false
end

---Return the provider tool call id from a transcript message.
---@param msg table|nil
---@return string|nil
local function tool_call_id(msg)
  local meta = msg and msg.meta or nil
  local call = meta and meta.call or nil
  local id = call and call.id
  if id and id ~= "" then return tostring(id) end
  local provider = meta and meta.provider_message or nil
  for _, block in ipairs(type(provider) == "table" and type(provider.content) == "table" and provider.content or {}) do
    if type(block) == "table" and block.id and block.id ~= "" then
      return tostring(block.id)
    end
    if type(block) == "table" and block.tool_use_id and block.tool_use_id ~= "" then
      return tostring(block.tool_use_id)
    end
  end
end

---Return unresolved tool call ids.
---@return table<string, boolean> ids
function Conversation:unresolved_tool_call_ids()
  local calls = {}
  local results = {}
  for _, msg in ipairs(self.messages or {}) do
    local id = tool_call_id(msg)
    if id and msg.role == "tool_call" then
      calls[id] = true
    elseif id and msg.role == "tool_result" then
      results[id] = true
    end
  end
  for id in pairs(results) do
    calls[id] = nil
  end
  return calls
end

---Return whether transcript has unresolved tool calls.
---@return boolean
function Conversation:has_unresolved_tool_calls()
  return next(self:unresolved_tool_call_ids()) ~= nil
end

---Drop unresolved tool calls and their pending activity messages.
---@param options table|nil
---@return integer removed
function Conversation:drop_unresolved_tool_calls(options)
  local unresolved = self:unresolved_tool_call_ids()
  if not next(unresolved) then return 0 end
  local removed = 0
  for index = #self.messages, 1, -1 do
    local msg = self.messages[index]
    local id = tool_call_id(msg)
    local drop = id and unresolved[id] and msg.role == "tool_call"
    if not drop and msg.role == "activity" then
      local key = msg.meta and msg.meta.http_activity_key
      for call_id in pairs(unresolved) do
        if type(key) == "string" and key:find(call_id, 1, true) then
          drop = true
          break
        end
      end
    end
    if drop then
      table.remove(self.messages, index)
      removed = removed + 1
    end
  end
  if removed > 0 then
    self:touch()
    if not (options and options.autosave == false) then
      self:save()
    end
  end
  return removed
end

---Remove all transcript messages and persist the empty session.
function Conversation:clear()
  self.messages = {}
  self:touch()
  self:save()
end

---Handle record local compaction.
---@param summary string
---@param metadata table|nil
function Conversation:record_local_compaction(summary, metadata)
  local cutoff = #self.messages
  metadata = type(metadata) == "table" and metadata or {}
  self.local_compaction = {
    version = 2,
    summary = tostring(summary or ""),
    created_at = now(),
    message_count = cutoff,
    source_message_count = metadata.source_message_count or cutoff,
    retained_message_count = metadata.retained_message_count or 0,
    strategy = metadata.strategy or "local_summary",
    trigger = metadata.trigger,
    usage = metadata.usage,
    context_snapshot = self.context_snapshot
  }
  self:store_local_compaction_memory()
  self:add("assistant", table.concat({
    "### Conversation Compacted",
    "",
    "Future requests will use the compacted summary plus new turns. The original transcript remains visible here."
  }, "\n"), {
    meta = {
      local_compaction_notice = true
    },
    autosave = false
  })
  self:touch()
  self:save()
end

---Set the status.
---@param status string
---@param options table|nil
function Conversation:set_status(status, options)
  self.status = status
  self:touch()
  if not (options and options.autosave == false) then
    self:save()
  end
end

---Set the usage.
---@param usage table|nil
function Conversation:set_usage(usage)
  self.usage = usage
  if usage and usage.context then
    self.options.context = usage.context
  end
  self:touch()
end

---Handle context left.
---@return integer|nil
function Conversation:context_left()
  local context = tonumber(self.usage and (self.usage.context or self.usage.model_context_window))
    or tonumber(self.options and self.options.context)
  local total = tonumber(self.usage and self.usage.total_tokens)
  if not (context and total) then return nil end
  return math.max(0, context - total)
end

---Handle context used.
---@return integer|nil
function Conversation:context_used()
  return tonumber(self.usage and self.usage.total_tokens)
end

---Handle active plan message.
local function active_plan_message(plan)
  if type(plan) ~= "table" or type(plan.items) ~= "table" then return nil end
  local has_open_item = false
  local lines = {
    "Current task plan.",
    "This plan is still active; continue using it as task state until every item is completed.",
    "Before your final response, if the task is complete, call update_plan with every item marked completed."
  }
  if type(plan.explanation) == "string" and plan.explanation ~= "" then
    table.insert(lines, "")
    table.insert(lines, plan.explanation)
  end
  table.insert(lines, "")
  for _, item in ipairs(plan.items) do
    if type(item) == "table" and type(item.step) == "string" then
      local status = tostring(item.status or "pending")
      if status ~= "completed" then has_open_item = true end
      local marker = status == "completed" and "[x]" or "[ ]"
      local suffix = status == "in_progress" and " (in progress)" or ""
      table.insert(lines, string.format("- %s %s%s", marker, item.step, suffix))
    end
  end
  if not has_open_item then return nil end
  return table.concat(lines, "\n")
end

---Handle message to markdown.
---@param msg table
---@return string|nil
function Conversation:message_to_markdown(msg)
  if not msg or msg.role == "system" then return nil end
  if msg.meta and msg.meta.provider_only then return nil end
  if (msg.role == "tool_call" or msg.role == "tool_result") and not verbose_tool_calling() then
    return nil
  end
  if msg.role == "tool_call" then
    local markdown = apply_patch_markdown(msg)
    if markdown then return markdown end
  end
  if msg.role == "activity" and not verbose_activity() then
    return compact_activity_markdown(msg, self.project_dir)
  end
  local label = msg.role:gsub("_", " "):gsub("^%l", string.upper)
  if msg.role == "error" or msg.role == "tool_call" or msg.role == "tool_result" then
    return "## " .. label .. "\n\n" .. fenced(msg.message, "text")
  end
  return "## " .. label .. "\n\n" .. (msg.message or "")
end

---Handle to markdown.
---@return string markdown
function Conversation:to_markdown()
  local parts = { "# " .. (self.title or "Assistant Session") }
  for i, msg in ipairs(self.messages) do
    local markdown = self:message_to_markdown(msg)
    if markdown then table.insert(parts, markdown) end
    if i % 50 == 0 then yield_ui() end
  end
  if #parts == 1 then
    table.insert(parts, markdown_quote("Start a prompt below to begin."))
  end
  yield_ui()
  return table.concat(parts, "\n\n")
end

---Handle to provider messages.
---@return table[] messages
function Conversation:to_provider_messages()
  local messages = {}
  local compaction = self.local_compaction
  local cutoff = compaction and tonumber(compaction.message_count)
  local assistant_before_tool_call = {}
  for i, msg in ipairs(self.messages) do
    if msg.role == "assistant"
      and not (msg.meta and (msg.meta.plan_update or msg.meta.user_input_prompt or msg.meta.local_compaction_notice))
    then
      local next_msg = self.messages[i + 1]
      if next_msg and next_msg.role == "tool_call" then
        assistant_before_tool_call[i] = true
      end
    end
  end
  for i, msg in ipairs(self.messages) do
    local role = msg.role
    if role == "tool_result" then role = "tool" end
    local content = msg.message or ""
    local include = true
    if cutoff and msg.role ~= "system" and i <= cutoff then
      include = false
    end
    if msg.meta and msg.meta.environment_context then
      include = true
    end
    if msg.meta and msg.meta.local_compaction_notice then
      include = false
    end
    if msg.meta and msg.meta.user_input_prompt then
      include = false
    end
    if msg.role == "activity" then
      include = false
    end
    if assistant_before_tool_call[i] then
      include = false
    end
    if include and msg.role == "tool_call" and msg.meta and msg.meta.provider_message then
      table.insert(messages, msg.meta.provider_message)
    elseif include and msg.role == "tool_result" and msg.meta and msg.meta.provider_messages then
      for _, provider_message in ipairs(msg.meta.provider_messages) do
        table.insert(messages, provider_message)
      end
    elseif include and msg.role == "tool_result" and msg.meta and msg.meta.provider_message then
      table.insert(messages, msg.meta.provider_message)
    elseif include
      and role ~= "tool_call"
      and role ~= "error"
      and not (role == "assistant" and content == "")
    then
      local provider_message = { role = role, content = msg.message or "" }
      if role == "assistant"
        and msg.meta
        and type(msg.meta.provider_reasoning_content) == "string"
        and msg.meta.provider_reasoning_content ~= ""
      then
        provider_message.reasoning_content = msg.meta.provider_reasoning_content
      end
      table.insert(messages, provider_message)
    end
    if i % 50 == 0 then yield_ui() end
  end
  if compaction and compaction.summary and compaction.summary ~= "" then
    local insert_at = #messages + 1
    for i, msg in ipairs(messages) do
      if msg.role ~= "system" then
        insert_at = i
        break
      end
    end
    table.insert(messages, insert_at, {
      role = "assistant",
      content = "### Compacted Conversation Summary\n\n" .. compaction.summary
    })
  end
  local plan_message = active_plan_message(self.assistant_plan)
  if plan_message then
    local insert_at = #messages + 1
    for i, msg in ipairs(messages) do
      if msg.role ~= "system" then
        insert_at = i
        break
      end
    end
    table.insert(messages, insert_at, {
      role = "system",
      content = plan_message
    })
  end
  return messages
end

---Handle to state.
---@return table state
function Conversation:to_state()
  return {
    version = 1,
    id = self.id,
    title = self.title,
    project_dir = self.project_dir,
    agent = self.agent,
    backend = self.backend,
    model = self.model,
    reasoning_effort = self.reasoning_effort,
    collaboration_mode = self.collaboration_mode,
    local_compaction = self.local_compaction,
    assistant_plan = self.assistant_plan,
    codex_thread_id = self.codex_thread_id,
    acp_session_id = self.acp_session_id,
    options = self.options,
    usage = self.usage,
    approved_command_prefixes = self.approved_command_prefixes,
    approved_tools = self.approved_tools,
    status = self.status,
    messages = self.messages,
    created_at = self.created_at,
    updated_at = self.updated_at,
    project_instructions_loaded = self.project_instructions ~= nil,
    memories_loaded = #self.memories,
    context_snapshot = self.context_snapshot,
    environment_context = self.environment_context
  }
end

---Handle from state.
---@param state table
---@return assistant.Conversation|nil
function Conversation.from_state(state)
  if type(state) ~= "table" then return nil end
  local conversation = Conversation()
  conversation.id = state.id or make_id()
  conversation.title = state.title or "Assistant Session"
  conversation.project_dir = project_dir_or_default(state.project_dir)
  conversation.agent = state.agent or "generic"
  conversation.backend = state.backend or "http"
  conversation.model = state.model
  conversation.reasoning_effort = state.reasoning_effort
  conversation.collaboration_mode = state.collaboration_mode
  conversation.local_compaction = state.local_compaction
  conversation.assistant_plan = state.assistant_plan
  conversation.codex_thread_id = state.codex_thread_id
  conversation.acp_session_id = state.acp_session_id
  conversation.options = state.options or {}
  conversation.usage = state.usage
  conversation.approved_command_prefixes = state.approved_command_prefixes or {}
  conversation.approved_tools = state.approved_tools or {}
  conversation.status = state.status or "idle"
  conversation.messages = state.messages or {}
  conversation.created_at = state.created_at or now()
  conversation.updated_at = state.updated_at or conversation.created_at
  conversation.project_instructions = Conversation.read_project_instructions(conversation.project_dir)
  conversation.memories = Conversation.list_memories(conversation.project_dir)
  conversation.context_snapshot = state.context_snapshot
  conversation.environment_context = state.environment_context
  return conversation
end

---Handle approve command prefix.
---@param prefix string
---@return boolean
function Conversation:approve_command_prefix(prefix)
  prefix = tostring(prefix or ""):match("^%s*(.-)%s*$") or ""
  if prefix == "" then return false end
  self.approved_command_prefixes = self.approved_command_prefixes or {}
  for _, item in ipairs(self.approved_command_prefixes) do
    if item == prefix then return true end
  end
  table.insert(self.approved_command_prefixes, prefix)
  table.sort(self.approved_command_prefixes)
  self:touch()
  self:save()
  return true
end

---Handle command prefix approved.
---@param command string
---@return boolean
---@return string|nil prefix
function Conversation:command_prefix_approved(command)
  for _, prefix in ipairs(self.approved_command_prefixes or {}) do
    if permission.command_matches_prefix(command, prefix) then
      return true, prefix
    end
  end
  return false
end

---Handle approve tool.
---@param name string
---@return boolean
function Conversation:approve_tool(name)
  name = tostring(name or ""):match("^%s*(.-)%s*$") or ""
  if name == "" then return false end
  self.approved_tools = self.approved_tools or {}
  for _, item in ipairs(self.approved_tools) do
    if item == name then return true end
  end
  table.insert(self.approved_tools, name)
  table.sort(self.approved_tools)
  self:touch()
  self:save()
  return true
end

---Handle tool approved.
---@param name string
---@return boolean
function Conversation:tool_approved(name)
  name = tostring(name or ""):match("^%s*(.-)%s*$") or ""
  if name == "" then return false end
  for _, item in ipairs(self.approved_tools or {}) do
    if item == name then return true end
  end
  return false
end

---Handle save.
---@return boolean
function Conversation:save()
  if not self.project_dir then return false end
  if not mkdirp(Conversation.sessions_dir(self.project_dir)) then return false end
  local path = Conversation.session_path(self.project_dir, self.id)
  return write_table(path, self:to_state())
end

---Append raw response.
---@param kind string
---@param data any
---@return boolean
function Conversation:append_raw_response(kind, data)
  return self:append_raw_responses({
    {
      kind = kind or "response",
      data = data
    }
  })
end

---Append raw responses.
---@param entries table[]
---@return boolean
function Conversation:append_raw_responses(entries)
  local conf = config.plugins.assistant or {}
  if conf.log_raw_messages == false then return false end
  if not self.project_dir then return false end
  if not mkdirp(Conversation.sessions_dir(self.project_dir)) then return false end
  local path = Conversation.raw_responses_path(self.project_dir, self.id)
  local fp, err = io.open(path, "ab")
  if not fp then
    core.error("Assistant: could not append raw response %s: %s", path, err)
    return false
  end
  local created_at = now()
  for _, entry in ipairs(entries or {}) do
    local line = jsonutil.encode({
      created_at = entry.created_at or created_at,
      conversation_id = self.id,
      agent = self.agent,
      backend = self.backend,
      model = self.model,
      kind = entry.kind or "response",
      data = entry.data
    }) .. "\n"
    for index = 1, #line, FILE_CHUNK_SIZE do
      fp:write(line:sub(index, index + FILE_CHUNK_SIZE - 1))
      yield_ui()
    end
  end
  fp:close()
  return true
end

---Handle raw responses text.
---@return string
function Conversation:raw_responses_text()
  local path = Conversation.raw_responses_path(self.project_dir, self.id)
  return read_file(path) or ""
end

---Handle load.
---@param id string
---@param project_dir string|nil
---@return assistant.Conversation|nil
function Conversation.load(id, project_dir)
  local path = Conversation.session_path(project_dir, id)
  local decoded = load_table(path)
  if type(decoded) ~= "table" then return nil end
  decoded.project_dir = decoded.project_dir or project_dir
  return Conversation.from_state(decoded)
end

---List list.
---@param project_dir string|nil
---@return table[] sessions
function Conversation.list(project_dir)
  local dir = Conversation.sessions_dir(project_dir)
  local result = {}
  for _, filename in ipairs(system.list_dir(dir) or {}) do
    if filename:match("%.lua$") then
      local decoded = load_table(dir .. PATHSEP .. filename)
      if type(decoded) == "table" then
        table.insert(result, decoded)
      end
    end
  end
  table.sort(result, function(a, b)
    return tostring(a.updated_at or "") > tostring(b.updated_at or "")
  end)
  return result
end

---Delete delete.
---@param id string
---@param project_dir string|nil
---@return boolean
function Conversation.delete(id, project_dir)
  local path = Conversation.session_path(project_dir, id)
  if system.get_file_info(path) then
    os.remove(path)
    local raw_path = Conversation.raw_responses_path(project_dir, id)
    if system.get_file_info(raw_path) then
      os.remove(raw_path)
    end
    return true
  end
  return false
end

return Conversation
