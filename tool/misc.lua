local context = require "plugins.assistant.tool_context"
local Tool = require "plugins.assistant.tool"

---Miscellaneous assistant interaction and planning tools.
---@class assistant.tool.misc
local misctools = {}

---Return the current local time, optionally adjusted to a UTC offset.
---@param utc_offset string?
---@return boolean ok
---@return string result
function misctools.time(utc_offset)
  local now_time = os.time()
  local offset = context.optional_text(utc_offset)
  if offset then
    local sign, hour, minute = offset:match("^([%+%-])(%d%d):?(%d%d)$")
    if not sign then return false, "invalid UTC offset; expected +HH:MM or -HH:MM" end
    local seconds = (tonumber(hour) * 60 + tonumber(minute)) * 60
    if sign == "-" then seconds = -seconds end
    return true, os.date("!%Y-%m-%d %H:%M:%S", now_time + seconds) .. " UTC" .. offset
  end
  return true, os.date("%Y-%m-%d %H:%M:%S %Z", now_time)
end

---Describe available tools, optionally filtered by category and selected names.
---@param category string?
---@param selected_names string[]?
---@return boolean ok
---@return string result
function misctools.tool_catalog(category, selected_names)
  category = context.optional_text(category) and tostring(category):lower() or nil
  local selected
  if type(selected_names) == "table" then
    selected = {}
    for _, name in ipairs(selected_names) do
      selected[name] = true
    end
  end
  local groups = {
    web = {
      { "web_search", "web_search(query, limit?, timeout_ms?) - search using the configured web endpoint" },
      { "web_fetch", "web_fetch(url, method?, headers?, body?, timeout_ms?) - fetch an HTTP or HTTPS URL" },
      { "web_find", "web_find(url, pattern, plain?, timeout_ms?) - fetch a URL and return matching lines" }
    },
    files = {
      { "list", "list(directory, recursive, max_results, pattern?) - list project files and directories" },
      { "read", "read(path, offset?, limit?) - read a project file; use offset/limit for large files" },
      { "file_info", "file_info(path) - inspect file metadata and content hash" },
      { "search", "search(directory, text, search_type) - search project files" }
    },
    edit = {
      { "apply_patch", "apply_patch(patch) - apply a structured patch or unified diff. Use recent exact context for existing files; after a context mismatch, read the target and rebuild the patch." },
      { "edit", "edit(path, edits) - edit a single file using exact text replacement" },
      { "write", "write(path, content) - create or overwrite a complete file" }
    },
    shell = {
      { "exec_command", "exec_command(cmd, workdir?, shell?, login?, tty?, yield_time_ms?, max_output_tokens?) - run a command in a loaded project root" },
      { "write_stdin", "write_stdin(session_id, chars?, yield_time_ms?, max_output_tokens?) - write to an ongoing exec session" },
      { "exec_status", "exec_status(session_id, yield_time_ms?, max_output_tokens?) - poll an ongoing exec session" },
      { "send_eof", "send_eof(session_id, yield_time_ms?, max_output_tokens?) - close stdin for an ongoing exec session" },
      { "interrupt_exec", "interrupt_exec(session_id, yield_time_ms?, max_output_tokens?) - interrupt an ongoing exec session" },
      { "close_exec", "close_exec(session_id, force?, yield_time_ms?, max_output_tokens?) - terminate an ongoing exec session" }
    },
    git = {
      { "git_status", "git_status(directory) - show git status" },
      { "git_diff", "git_diff(directory, pathspec) - show git diff" }
    },
    interaction = {
      { "request_user_input", "request_user_input(questions) - ask the user structured questions" },
      { "update_plan", "update_plan(explanation?, plan) - update the visible task plan" },
      { "time", "time(utc_offset?) - return current system time" }
    }
  }
  local order = { "web", "files", "edit", "shell", "git", "interaction" }
  local lines = {
    "Available assistant tools are grouped below."
  }
  for _, name in ipairs(order) do
    if not category or category == name then
      local group_lines = {}
      for _, item in ipairs(groups[name]) do
        if not selected or selected[item[1]] then
          table.insert(group_lines, "- " .. item[2])
        end
      end
      if #group_lines > 0 then
        table.insert(lines, "")
        table.insert(lines, name .. ":")
        for _, line in ipairs(group_lines) do
          table.insert(lines, line)
        end
      end
    end
  end
  if category and not groups[category] then
    return false, "unknown tool category: " .. category
  end
  if #lines == 1 then return true, "No tools are available for that category in the current collaboration mode." end
  return true, table.concat(lines, "\n")
end

---Handle validate plan.
---@param plan table
---@return boolean ok
---@return string? errmsg
local function validate_plan(plan)
  if type(plan) ~= "table" then return false, "plan must be an array" end
  local in_progress = 0
  for _, item in ipairs(plan) do
    if type(item) ~= "table" then return false, "each plan item must be an object" end
    for key in pairs(item) do
      if key ~= "step" and key ~= "status" then
        return false, "unsupported plan item field: " .. tostring(key)
      end
    end
    if type(item.step) ~= "string" or item.step == "" then
      return false, "plan item is missing step"
    end
    if type(item.status) ~= "string" then
      return false, "plan item is missing status"
    end
    if item.status ~= "pending" and item.status ~= "in_progress" and item.status ~= "completed" then
      return false, "invalid plan status: " .. item.status
    end
    if item.status == "in_progress" then in_progress = in_progress + 1 end
  end
  if in_progress > 1 then return false, "only one plan item can be in_progress" end
  return true
end

---Validate and accept a visible task-plan update.
---@param explanation string?
---@param plan table
---@return boolean ok
---@return string result
function misctools.update_plan(explanation, plan)
  if explanation ~= nil and type(explanation) ~= "string" then
    return false, "explanation must be a string"
  end
  local ok, err = validate_plan(plan)
  if not ok then return false, err end
  return true, "plan updated"
end

---Placeholder callback resolved by the assistant UI request flow.
---@return boolean ok
---@return string result
function misctools.request_user_input()
  return false, "request_user_input must be resolved by the assistant UI"
end

misctools.tools = {
  Tool:new({
    name = "tool_catalog",
    build = function(_, agent, facade)
      return {
        callback = function(category)
          local selected = agent.tool_names_for_mode and agent:tool_names_for_mode(agent._assistant_tool_conversation)
          return facade.tool_catalog(category, selected)
        end
      }
    end,
    description = "List available assistant tool groups and tool names when a needed tool schema is not currently visible.",
    read_only = true,
    params = {
      { name = "category", description = "Optional category: web, files, edit, shell, git, interaction.", type = "string", required = false }
    }
  }),
  Tool:new({
    name = "time",
    callback = misctools.time,
    description = "Return the current system time, optionally adjusted to a UTC offset.",
    read_only = true,
    params = {
      { name = "utc_offset", description = "Optional UTC offset such as +03:00 or -04:00.", type = "string", required = false }
    }
  }),
  Tool:new({
    name = "update_plan",
    callback = misctools.update_plan,
    description = table.concat({
      "Updates the task plan.",
      "Provide an optional explanation and a list of plan items, each with a step and status.",
      "At most one step can be in_progress at a time."
    }, "\n"),
    read_only = true,
    additional_properties = false,
    params = {
      { name = "explanation", description = "Optional short explanation for the plan update.", type = "string", required = false },
      {
        name = "plan",
        schema = {
          type = "array",
          description = "The list of steps.",
          items = {
            type = "object",
            properties = {
              step = { type = "string" },
              status = { type = "string", description = "One of: pending, in_progress, completed" }
            },
            required = { "step", "status" },
            additionalProperties = false
          }
        }
      }
    }
  }),
  Tool:new({
    name = "request_user_input",
    callback = misctools.request_user_input,
    description = "Ask the user one to three structured questions and wait for their answers.",
    read_only = true,
    params = {
      {
        name = "questions",
        schema = {
          type = "array",
          description = "Questions to show the user.",
          items = {
            type = "object",
            properties = {
              id = { type = "string", description = "Stable identifier for mapping answers." },
              header = { type = "string", description = "Short header label." },
              question = { type = "string", description = "Question to show the user." },
              options = {
                type = "array",
                description = "Optional mutually exclusive choices.",
                items = {
                  type = "object",
                  properties = {
                    label = { type = "string", description = "User-facing label." },
                    description = { type = "string", description = "Choice impact or tradeoff." }
                  },
                  required = { "label", "description" }
                }
              }
            },
            required = { "id", "header", "question" }
          },
          minItems = 1,
          maxItems = 3
        }
      }
    }
  })
}

return misctools
