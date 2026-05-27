local core = require "core"
local Conversation = require "plugins.assistant.conversation"
local Tool = require "plugins.assistant.tool"
local context = require "plugins.assistant.tool_context"

---Project-local memory tools.
---@class assistant.tool.memory
local memorytools = {}

local DEFAULT_TITLE = "Memory"
local SEARCH_LIMIT = 20

local function optional_text(value)
  if value == nil then return nil end
  value = tostring(value)
  if value == "" then return nil end
  return value
end

local function project_dir()
  local conversation = context.active_conversation()
  if conversation and conversation.project_dir and conversation.project_dir ~= "" then
    return conversation.project_dir
  end
  local project = core.root_project and core.root_project()
  return project and project.path or "."
end

local function refresh_active_conversation(agent)
  local conversation = context.active_conversation()
  if not conversation then return end
  if agent and conversation.refresh_context then
    conversation:refresh_context(agent)
    return
  end
  conversation.memories = Conversation.list_memories(conversation.project_dir)
  conversation:touch()
  conversation:save()
end

local function list_project_memories()
  return Conversation.list_memories(project_dir())
end

local function find_memory(id)
  id = optional_text(id)
  if not id then return nil end
  for index, item in ipairs(list_project_memories()) do
    if index % 25 == 0 then context.yield_ui() end
    if item.id == id then return item end
  end
end

local function collapse_preview(text, limit)
  text = tostring(text or ""):gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
  limit = limit or 240
  if #text <= limit then return text end
  return text:sub(1, limit - 3) .. "..."
end

local function memory_metadata_lines(item, verb)
  local lines = {
    verb or "Memory",
    "id: " .. tostring(item.id or ""),
    "title: " .. tostring(item.title or ""),
    "created_at: " .. tostring(item.created_at or ""),
    "updated_at: " .. tostring(item.updated_at or "")
  }
  return lines
end

local function memory_full_text(item, verb)
  local lines = memory_metadata_lines(item, verb)
  table.insert(lines, "")
  table.insert(lines, "content:")
  table.insert(lines, Tool.fenced(item.content or "", "text"))
  return table.concat(lines, "\n")
end

local function matches_query(item, query)
  if not query then return true end
  query = query:lower()
  local haystack = table.concat({
    tostring(item.id or ""),
    tostring(item.title or ""),
    tostring(item.content or "")
  }, "\n"):lower()
  return haystack:find(query, 1, true) ~= nil
end

---Search or list project-local assistant memories.
---@param query string|nil
---@return boolean ok
---@return string result
function memorytools.search_memory(query)
  query = optional_text(query)
  local memories = list_project_memories()
  local lines = {}
  local matched = 0
  local shown = 0
  for index, item in ipairs(memories) do
    if index % 25 == 0 then context.yield_ui() end
    if matches_query(item, query) then
      matched = matched + 1
      if shown < SEARCH_LIMIT then
        shown = shown + 1
        table.insert(lines, string.format(
          "- id: %s\n  title: %s\n  updated_at: %s\n  created_at: %s\n  preview: %s",
          tostring(item.id or ""),
          tostring(item.title or ""),
          tostring(item.updated_at or ""),
          tostring(item.created_at or ""),
          collapse_preview(item.content)
        ))
      end
    end
  end
  context.yield_ui()
  if matched == 0 then
    return true, query and ("No memories matched query: " .. query) or "No memories are stored for this project."
  end
  local header = query
    and string.format("Found %d matching project memories. Showing %d.", matched, math.min(matched, SEARCH_LIMIT))
    or string.format("Found %d project memories. Showing %d most recent.", matched, math.min(matched, SEARCH_LIMIT))
  if matched > SEARCH_LIMIT then
    header = header .. string.format(" %d omitted.", matched - SEARCH_LIMIT)
  end
  table.insert(lines, 1, header)
  return true, table.concat(lines, "\n")
end

---Create, retrieve, or update a project-local assistant memory.
---@param id string|nil
---@param title string|nil
---@param value string|nil
---@param agent assistant.Agent|nil
---@return boolean ok
---@return string result
function memorytools.remember(id, title, value, agent)
  id = optional_text(id)
  title = optional_text(title)
  if not id then
    local item, err = Conversation.add_memory(project_dir(), title or DEFAULT_TITLE, value ~= nil and tostring(value) or "")
    if not item then return false, tostring(err or "could not create memory") end
    refresh_active_conversation(agent)
    return true, memory_full_text(item, "Memory created")
  end

  local existing = find_memory(id)
  if not existing then return false, "memory not found: " .. id end
  if value == nil then
    return true, memory_full_text(existing, "Memory")
  end

  local updated, err = Conversation.update_memory(project_dir(), id, title or existing.title or DEFAULT_TITLE, tostring(value))
  if not updated then return false, tostring(err or ("could not update memory: " .. id)) end
  refresh_active_conversation(agent)
  return true, memory_full_text(updated, "Memory updated")
end

---Forget a project-local assistant memory.
---@param id string
---@param agent assistant.Agent|nil
---@return boolean ok
---@return string result
function memorytools.forget(id, agent)
  id = optional_text(id)
  if not id then return false, "missing memory id" end
  local existing = find_memory(id)
  if not existing then return false, "memory not found: " .. id end
  local ok, err = Conversation.delete_memory(project_dir(), id)
  if not ok then return false, tostring(err or ("could not delete memory: " .. id)) end
  refresh_active_conversation(agent)
  return true, table.concat(memory_metadata_lines(existing, "Memory deleted"), "\n")
end

memorytools.tools = {
  Tool:new({
    name = "search_memory",
    callback = memorytools.search_memory,
    description = table.concat({
      "Search project-local assistant memories, or list recent memories when query is omitted.",
      "Use this before updating or deleting a memory when you do not know its exact id.",
      "Results include id, title, timestamps, and a compact content preview."
    }, "\n"),
    read_only = true,
    params = {
      { name = "query", description = "Optional case-insensitive query matched against id, title, and content.", type = "string", required = false }
    },
    compact_activity_markdown = function(_, status)
      return "**Searching memory**:" .. Tool.status_suffix(status)
    end
  }),
  Tool:new({
    name = "remember",
    build = function(_, agent, facade)
      return {
        callback = function(id, title, value)
          return facade.remember(id, title, value, agent)
        end
      }
    end,
    description = table.concat({
      "Create, retrieve, or update a project-local assistant memory.",
      "Call remember() with title and value to create a memory. Call remember(id) to retrieve full content.",
      "Call remember(id, title, value) to update content and optionally retitle the memory.",
      "Use this only for stable user preferences, project conventions, durable decisions, or recurring facts.",
      "Do not store secrets, transient command output, one-off task state, or facts already obvious from project files."
    }, "\n"),
    read_only = true,
    requires_approval = function(args)
      args = args or {}
      return optional_text(args.id) == nil or args.value ~= nil
    end,
    params = {
      { name = "id", description = "Existing memory id. Omit to create a new memory.", type = "string", required = false },
      { name = "title", description = "Title for a new memory, or replacement title when updating with value.", type = "string", required = false },
      { name = "value", description = "Memory content to create or update. Omit when retrieving an existing memory by id.", type = "string", required = false }
    },
    compact_activity_markdown = function(_, status)
      return "**Updating memory**:" .. Tool.status_suffix(status)
    end
  }),
  Tool:new({
    name = "forget",
    build = function(_, agent, facade)
      return {
        callback = function(id)
          return facade.forget(id, agent)
        end
      }
    end,
    description = table.concat({
      "Delete an exact project-local assistant memory by id.",
      "Use this when the user asks to forget something, or when a stored memory is wrong, obsolete, superseded, or no longer applicable.",
      "Use search_memory first when you do not know the exact memory id."
    }, "\n"),
    read_only = true,
    requires_approval = function()
      return true
    end,
    params = {
      { name = "id", description = "Exact memory id to delete.", type = "string" }
    },
    compact_activity_markdown = function(_, status)
      return "**Forgetting memory**:" .. Tool.status_suffix(status)
    end
  })
}

return memorytools
