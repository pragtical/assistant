local core = require "core"
local context = require "plugins.assistant.tool_context"
local Tool = require "plugins.assistant.tool"

---Git inspection tool implementations.
---@class assistant.tool.git
local gittools = {}

---Compact compact.
---@param label string
---@return fun(_: assistant.Tool, result: string): string
local function compact(label)
  return function(_, result)
    return context.compact_provider_text_result(result, label)
  end
end

---Read approval.
---@param key string
---@return fun(arguments: table): boolean
local function read_approval(key)
  return function(arguments)
    return context.read_path_requires_approval(arguments, key)
  end
end

---Return short branch and working-tree status for a project directory.
---@param directory string?
---@return string result
function gittools.git_status(directory)
  local path, err = context.assert_read_path(directory or (core.root_project() and core.root_project().path) or ".")
  if not path then return err end
  local ok, result = context.run_process(context.git_command("status", "--short", "--branch", "--", "."), path, 10000)
  if not ok then return type(result) == "table" and result.stderr or result end
  return result.stdout ~= "" and result.stdout or result.stderr
end

---Return the current git diff for a project directory.
---@param directory string?
---@param pathspec string?
---@return string result
function gittools.git_diff(directory, pathspec)
  local path, err = context.assert_read_path(directory or (core.root_project() and core.root_project().path) or ".")
  if not path then return err end
  local command = pathspec and pathspec ~= ""
    and context.git_command("diff", "--", pathspec)
    or context.git_command("diff", "--", ".")
  local ok, result = context.run_process(command, path, 10000)
  if not ok then return type(result) == "table" and result.stderr or result end
  return result.stdout ~= "" and result.stdout or "No diff."
end

gittools.tools = {
  Tool:new({
    name = "git_status",
    callback = gittools.git_status,
    description = "Show git branch and working tree status for a project directory.",
    read_only = true,
    requires_approval = read_approval("directory"),
    params = {
      { name = "directory", description = "Project directory.", type = "string" }
    }
  }),
  Tool:new({
    name = "git_diff",
    callback = gittools.git_diff,
    compact_result = compact("git diff"),
    description = "Show git diff for a project directory, optionally limited to one path.",
    read_only = true,
    requires_approval = read_approval("directory"),
    params = {
      { name = "directory", description = "Project directory.", type = "string" },
      { name = "pathspec", description = "Optional pathspec to diff.", type = "string", required = false }
    }
  })
}

return gittools
