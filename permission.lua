local common = require "core.common"

---Permission classifier for local assistant tool calls.
---
---The classifier is intentionally conservative: unknown commands/tools require
---approval, while clearly read-only project-local inspections may run
---automatically.
---@class assistant.permission
local permission = {}

local READ_ONLY_COMMANDS = {
  basename = true,
  cat = true,
  date = true,
  dirname = true,
  du = true,
  env = true,
  file = true,
  find = true,
  grep = true,
  head = true,
  id = true,
  ls = true,
  pwd = true,
  rg = true,
  sed = true,
  stat = true,
  tail = true,
  tree = true,
  uname = true,
  wc = true,
  which = true,
  whoami = true
}

local WRITE_COMMANDS = {
  ar = true,
  as = true,
  cc = true,
  clang = true,
  cmake = true,
  cp = true,
  gcc = true,
  install = true,
  ln = true,
  make = true,
  mkdir = true,
  mv = true,
  ninja = true,
  patch = true,
  perl = true,
  python = true,
  python3 = true,
  ruby = true,
  sh = true,
  tee = true,
  touch = true
}

local DESTRUCTIVE_COMMANDS = {
  chmod = true,
  chown = true,
  dd = true,
  mkfs = true,
  rm = true,
  rmdir = true,
  shred = true
}

local NETWORK_COMMANDS = {
  curl = true,
  gh = true,
  git = "subcommand",
  npm = "subcommand",
  pnpm = "subcommand",
  wget = true,
  yarn = "subcommand"
}

local GIT_READ_ONLY = {
  branch = true,
  diff = true,
  log = true,
  ls_files = true,
  rev_parse = true,
  show = true,
  status = true
}

local GIT_NETWORK = {
  clone = true,
  fetch = true,
  pull = true,
  push = true,
  submodule = true
}

local PACKAGE_NETWORK = {
  add = true,
  ci = true,
  install = true,
  publish = true,
  update = true,
  upgrade = true
}

---Normalize path.
local function normalize_path(path)
  if not path or path == "" then return nil end
  return common.normalize_path(path) or path
end

---Handle project root for.
local function project_root_for(path, roots)
  path = normalize_path(path)
  if not path then return nil end
  for _, root in ipairs(roots or {}) do
    root = normalize_path(root)
    if root and (path == root or common.path_belongs_to(path, root)) then
      return root
    end
  end
end

---Handle command shell syntax.
local function command_shell_syntax(command)
  command = tostring(command or "")
  local out = {}
  local quote
  local escaped = false
  for i = 1, #command do
    local c = command:sub(i, i)
    if escaped then
      table.insert(out, quote and " " or c)
      escaped = false
    elseif quote == '"' and c == "\\" then
      table.insert(out, " ")
      escaped = true
    elseif quote then
      if c == quote then quote = nil end
      table.insert(out, " ")
    elseif c == "'" or c == '"' then
      quote = c
      table.insert(out, " ")
    else
      table.insert(out, c)
    end
  end
  return table.concat(out), quote ~= nil
end

---Handle split at operators.
local function split_at_operators(command, syntax)
  local segments = {}
  local start = 1
  local i = 1
  while i <= #syntax do
    local two = syntax:sub(i, i + 1)
    local one = syntax:sub(i, i)
    local is_operator = two == "&&" or two == "||" or one == "|" or one == ";"
    if is_operator then
      local operator = (two == "&&" or two == "||") and two or one
      table.insert(segments, {
        text = command:sub(start, i - 1),
        operator = operator
      })
      i = i + ((two == "&&" or two == "||") and 2 or 1)
      start = i
    else
      i = i + 1
    end
  end
  table.insert(segments, { text = command:sub(start), operator = nil })
  return segments
end

---Handle split command segments.
---@param command string
---@return table[] segments
function permission.split_command_segments(command)
  local syntax, unterminated_quote = command_shell_syntax(command)
  if unterminated_quote then
    return nil, "unterminated shell quote"
  end
  local segments = split_at_operators(tostring(command or ""), syntax)
  for _, segment in ipairs(segments) do
    segment.text = (segment.text or ""):match("^%s*(.-)%s*$") or ""
  end
  return segments, nil, syntax
end

---Handle words for segment.
local function words_for_segment(segment)
  local words = {}
  for word in tostring(segment or ""):gmatch("%S+") do
    table.insert(words, word)
  end
  return words
end

---Normalize git subcommand.
local function normalize_git_subcommand(value)
  return tostring(value or ""):gsub("%-", "_")
end

---Handle command name.
local function command_name(program)
  program = tostring(program or "")
  return program:match("([^/\\]+)$") or program
end

---Handle first command words.
local function first_command_words(command)
  local segments = permission.split_command_segments(command)
  local segment = segments and segments[1] and segments[1].text or command
  local words = words_for_segment(segment)
  if words[1] then words[1] = command_name(words[1]) end
  return words
end

---Handle classify segment.
local function classify_segment(segment)
  segment = tostring(segment or ""):match("^%s*(.-)%s*$") or ""
  if segment == "" then return "unknown", "empty command segment" end
  local syntax, unterminated_quote = command_shell_syntax(segment)
  if unterminated_quote then return "unknown", "unterminated shell quote" end
  if syntax:find("[<>`$()]") then
    return "sandbox_escape", "shell redirection, substitution, or subshell syntax requires approval"
  end
  local words = words_for_segment(segment)
  local name = command_name(words[1])
  if name == "command" and words[2] == "-v" and words[3] then
    return "read_only"
  end
  if name == "pkg-config" or name == "sdl2-config" then
    return "read_only"
  end
  if name == "git" then
    local subcommand = normalize_git_subcommand(words[2])
    if GIT_READ_ONLY[subcommand] then return "read_only" end
    if GIT_NETWORK[subcommand] then return "network", "git " .. tostring(words[2] or "") .. " may access the network" end
    return "project_write", "git " .. tostring(words[2] or "") .. " may mutate repository state"
  end
  if NETWORK_COMMANDS[name] == true then
    return "network", name .. " may access the network"
  end
  if NETWORK_COMMANDS[name] == "subcommand" then
    local subcommand = normalize_git_subcommand(words[2])
    if PACKAGE_NETWORK[subcommand] then return "network", name .. " " .. tostring(words[2] or "") .. " may access the network" end
  end
  if DESTRUCTIVE_COMMANDS[name] then
    return "destructive", name .. " can delete or destructively modify files"
  end
  if READ_ONLY_COMMANDS[name] then return "read_only" end
  if WRITE_COMMANDS[name] then
    if (name == "gcc" or name == "cc" or name == "clang" or name == "make")
      and (words[2] == "--version" or words[2] == "-v")
    then
      return "read_only"
    end
    return "project_write", name .. " may create or modify files"
  end
  return "unknown", "command is not classified as read-only"
end

---Handle worse category.
local function worse_category(left, right)
  local rank = {
    read_only = 1,
    project_write = 2,
    network = 3,
    outside_project = 4,
    sandbox_escape = 5,
    destructive = 6,
    unknown = 7
  }
  if not left then return right end
  if (rank[right] or 0) > (rank[left] or 0) then return right end
  return left
end

---Handle classify command.
---@param command string
---@param cwd string|nil
---@param roots string[]|nil
---@return table classification
function permission.classify_command(command, cwd, roots)
  local segments, err, syntax = permission.split_command_segments(command)
  if not segments then
    return { category = "unknown", reason = err }
  end
  if syntax:find("[<>`$()]") then
    return {
      category = "sandbox_escape",
      reason = "shell redirection, substitution, or subshell syntax requires approval",
      segments = segments
    }
  end
  local root = project_root_for(cwd, roots)
  if cwd and cwd ~= "" and roots and #roots > 0 and not root then
    return {
      category = "outside_project",
      reason = "command cwd is outside loaded project roots",
      segments = segments
    }
  end
  local category = "read_only"
  local reasons = {}
  local previous_operator
  for _, segment in ipairs(segments) do
    if previous_operator and previous_operator ~= "&&" then
      category = worse_category(category, "sandbox_escape")
      table.insert(reasons, "only && command chains can be auto-classified as read-only")
    end
    local item_category, reason = classify_segment(segment.text)
    category = worse_category(category, item_category)
    if reason then table.insert(reasons, reason) end
    previous_operator = segment.operator
  end
  return {
    category = category,
    reason = table.concat(reasons, "; "),
    segments = segments
  }
end

---Return whether read only command.
---@param command string
---@return boolean
function permission.is_read_only_command(command)
  return permission.classify_command(command).category == "read_only"
end

---Handle command prefix.
---@param command string
---@return string|nil
function permission.command_prefix(command)
  local words = first_command_words(command)
  if not words[1] then return nil end
  local name = words[1]
  if name == "git" and words[2] then
    return "git " .. tostring(words[2])
  end
  if (name == "npm" or name == "pnpm" or name == "yarn") and words[2] then
    return name .. " " .. tostring(words[2])
  end
  if words[2] and not tostring(words[2]):match("^%-") then
    return name .. " " .. tostring(words[2])
  end
  return name
end

---Handle command matches prefix.
---@param command string
---@param prefix string
---@return boolean
function permission.command_matches_prefix(command, prefix)
  prefix = tostring(prefix or ""):match("^%s*(.-)%s*$") or ""
  if prefix == "" then return false end
  local words = first_command_words(command)
  local prefix_words = words_for_segment(prefix)
  if #prefix_words == 0 or #words < #prefix_words then return false end
  for index, word in ipairs(prefix_words) do
    if tostring(words[index] or "") ~= tostring(word) then return false end
  end
  return true
end

---Handle classify tool call.
---@param call table
---@param tool assistant.Tool.registration|nil
---@param context table|nil
---@return table classification
function permission.classify_tool_call(call, tool, context)
  call = call or {}
  local name = tostring(call.name or "")
  local args = call.arguments or {}
  context = context or {}
  if name == "exec_command" then
    return permission.classify_command(args.cmd, args.workdir or context.cwd, context.project_roots)
  end
  if name == "write_stdin" then
    return { category = "project_write", reason = "writes to an active command session" }
  end
  if tool and tool.read_only == true then
    if tool.requires_approval and tool.requires_approval(args) ~= false then
      return { category = "outside_project", reason = "read-only tool requires approval for this target" }
    end
    return { category = "read_only" }
  end
  if name == "apply_patch" then
    return { category = "project_write" }
  end
  if name == "web_fetch" or name == "web_search" or name == "web_find" then
    return { category = "network" }
  end
  return { category = "unknown", reason = "tool is not classified as read-only" }
end

---Handle requires approval.
---@param classification table|nil
---@return boolean
function permission.requires_approval(classification)
  local category = classification and classification.category or "unknown"
  return category ~= "read_only"
end

return permission
