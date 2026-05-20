local test = require "core.test"
dofile("tests/helper.inc")
local common = require "core.common"
local config = require "core.config"
local tools = require "plugins.assistant.tools"

local root = assistant_test_temp_path("applypatch")

local function mkdirp(path)
  local info = system.get_file_info(path)
  if info and info.type == "dir" then return end
  common.mkdirp(path)
end

local function write(path, text)
  local parent = path:match("^(.*)" .. PATHSEP .. "[^" .. PATHSEP .. "]+$")
  if parent and parent ~= "" then mkdirp(parent) end
  local fp = assert(io.open(path, "wb"))
  fp:write(text)
  fp:close()
end

local function read(path)
  local fp = assert(io.open(path, "rb"))
  local text = fp:read("*a")
  fp:close()
  return text
end

local function read_fixture(path)
  local fp = assert(io.open(path, "rb"))
  local text = fp:read("*a")
  fp:close()
  return text
end

local function exists(path)
  return system.get_file_info(path) ~= nil
end

local function path(name)
  return root .. PATHSEP .. name:gsub("/", PATHSEP)
end

local function apply_ok(patch)
  tools.set_confirm_write(function(action)
    return action == "apply_patch"
  end)
  local ok, result = tools.apply_patch(patch)
  test.equal(ok, true)
  test.equal(result:find("applied patch", 1, true) ~= nil, true)
  return result
end

local function apply_fail(patch)
  tools.set_confirm_write(function(action)
    return action == "apply_patch"
  end)
  local ok, result = tools.apply_patch(patch)
  test.equal(ok, false)
  return result
end

test.describe("assistant apply_patch", function()
  local old_allow_any_read_path

  test.before_each(function()
    old_allow_any_read_path = config.plugins.assistant.allow_any_read_path
    config.plugins.assistant.allow_any_read_path = false
    common.rm(root, true)
    mkdirp(root)
    write(path("sample.txt"), "alpha\nbeta\ngamma\n")
    core.projects = {
      {
        path = root,
        absolute_path = function(_, value)
          if value:match("^/") then return value end
          return root .. PATHSEP .. value
        end
      }
    }
  end)

  test.after_each(function()
    config.plugins.assistant.allow_any_read_path = old_allow_any_read_path
    tools.set_confirm_write(nil)
  end)

  test.it("applies structured add files with plus-prefixed content", function()
    apply_ok([[
*** Begin Patch
*** Add File: added.txt
+one
+two
*** End Patch
]])
    test.equal(read(path("added.txt")), "one\ntwo\n")
  end)

  test.it("applies structured add files with bare content and parent directories", function()
    apply_ok([[
*** Begin Patch
*** Add File: nested/bare.txt
first
  indented
	tabbed
*** End Patch
]])
    test.equal(read(path("nested/bare.txt")), "first\n  indented\n\ttabbed\n")
  end)

  test.it("replaces existing files with structured add files", function()
    write(path("replace.txt"), "old\n")
    local result = apply_ok([[
*** Begin Patch
*** Add File: replace.txt
+new
*** End Patch
]])
    test.equal(read(path("replace.txt")), "new\n")
    test.equal(result:find("updated existing replace.txt", 1, true) ~= nil, true)
  end)

  test.it("reports changed files after structured patches", function()
    local result = apply_ok([[
*** Begin Patch
*** Add File: report.txt
+hello
*** Update File: sample.txt
@@
 alpha
-beta
+changed
 gamma
*** End Patch
]])
    test.equal(result:find("Changed files:", 1, true) ~= nil, true)
    test.equal(result:find("- added report.txt", 1, true) ~= nil, true)
    test.equal(result:find("- updated sample.txt", 1, true) ~= nil, true)
  end)

  test.it("creates empty structured add files", function()
    apply_ok([[
*** Begin Patch
*** Add File: empty.txt
*** End Patch
]])
    test.equal(read(path("empty.txt")), "")
  end)

  test.it("applies structured updates with default context", function()
    apply_ok([[
*** Begin Patch
*** Update File: sample.txt
@@
 alpha
-beta
+delta
 gamma
*** End Patch
]])
    test.equal(read(path("sample.txt")), "alpha\ndelta\ngamma\n")
  end)

  test.it("applies structured insertion-only chunks", function()
    apply_ok([[
*** Begin Patch
*** Update File: sample.txt
@@
+zero
*** End Patch
]])
    test.equal(read(path("sample.txt")), "zero\nalpha\nbeta\ngamma\n")
  end)

  test.it("applies multiple structured update chunks in order", function()
    write(path("multi.txt"), "one\ntwo\nthree\nfour\n")
    apply_ok([[
*** Begin Patch
*** Update File: multi.txt
@@
-one
+ONE
@@
-three
+THREE
*** End Patch
]])
    test.equal(read(path("multi.txt")), "ONE\ntwo\nTHREE\nfour\n")
  end)

  test.it("uses structured context anchors to update repeated text", function()
    write(path("repeat.txt"), "same\nold\nsame\nold\n")
    apply_ok([[
*** Begin Patch
*** Update File: repeat.txt
@@ same
-old
+new
*** End Patch
]])
    test.equal(read(path("repeat.txt")), "same\nnew\nsame\nold\n")
  end)

  test.it("uses structured EOF anchors", function()
    write(path("tail.txt"), "alpha\nbeta\nalpha\n")
    apply_ok([[
*** Begin Patch
*** Update File: tail.txt
-alpha
+omega
*** End of File
*** End Patch
]])
    test.equal(read(path("tail.txt")), "alpha\nbeta\nomega\n")
  end)

  test.it("moves and updates files in a structured patch", function()
    write(path("move.txt"), "alpha\nbeta\n")
    apply_ok([[
*** Begin Patch
*** Update File: move.txt
*** Move to: moved/renamed.txt
@@
-beta
+gamma
*** End Patch
]])
    test.equal(exists(path("move.txt")), false)
    test.equal(read(path("moved/renamed.txt")), "alpha\ngamma\n")
  end)

  test.it("moves files without changing content", function()
    write(path("rename.txt"), "alpha\n")
    apply_ok([[
*** Begin Patch
*** Update File: rename.txt
*** Move to: moved/only.txt
*** End Patch
]])
    test.equal(exists(path("rename.txt")), false)
    test.equal(read(path("moved/only.txt")), "alpha\n")
  end)

  test.it("deletes files in a structured patch", function()
    write(path("delete.txt"), "remove\n")
    apply_ok([[
*** Begin Patch
*** Delete File: delete.txt
*** End Patch
]])
    test.equal(exists(path("delete.txt")), false)
  end)

  test.it("applies mixed structured add update delete operations", function()
    write(path("remove.txt"), "remove\n")
    local result = apply_ok([[
*** Begin Patch
*** Add File: added.txt
+created
*** Update File: sample.txt
@@
-beta
+changed
*** Delete File: remove.txt
*** End Patch
]])
    test.equal(result:find("applied patch to 3 file", 1, true) ~= nil, true)
    test.equal(read(path("added.txt")), "created\n")
    test.equal(read(path("sample.txt")), "alpha\nchanged\ngamma\n")
    test.equal(exists(path("remove.txt")), false)
  end)

  test.it("accepts structured headers without colons", function()
    apply_ok([[
*** Begin Patch
*** Add File no-colon.txt
+created
*** End Patch
]])
    test.equal(read(path("no-colon.txt")), "created\n")
  end)

  test.it("accepts environment headers and heredoc wrappers", function()
    apply_ok([[
<<'PATCH'
*** Begin Patch
*** Environment ID: local-test
*** Add File: wrapped.txt
+created
*** End Patch
PATCH
]])
    test.equal(read(path("wrapped.txt")), "created\n")
  end)

  test.it("accepts fenced patches embedded in prose", function()
    apply_ok([[
Here is the patch:

```patch
*** Begin Patch
*** Add File: fenced.txt
+created
*** End Patch
```
]])
    test.equal(read(path("fenced.txt")), "created\n")
  end)

  test.it("strips markdown fences wrapped around add-file bodies", function()
    apply_ok([[
*** Begin Patch
*** Add File: fenced-body.c
```c
#include <stdio.h>

int main(void) {
  return 0;
}
```
*** Add File: plain-body.c
```c
int value(void) {
  return 1;
}
```
*** End Patch
]])
    test.equal(read(path("fenced-body.c")), "#include <stdio.h>\n\nint main(void) {\n  return 0;\n}\n")
    test.equal(read(path("plain-body.c")), "int value(void) {\n  return 1;\n}\n")
  end)

  test.it("accepts structured patches missing the end marker", function()
    apply_ok([[
*** Begin Patch
*** Add File: missing-end.txt
+created
]])
    test.equal(read(path("missing-end.txt")), "created\n")
  end)

  test.it("accepts captured final +End Patch marker", function()
    apply_ok([[
*** Begin Patch
*** Add File: captured.txt
+created
+*** End Patch
]])
    test.equal(read(path("captured.txt")), "created\n")
  end)

  test.it("applies the captured failed live fixture", function()
    local result = apply_ok(read_fixture("live_tests/failed-apply-patch.patch"))
    test.equal(result:find("applied patch to 12 file", 1, true) ~= nil, true)
    test.equal(read(path("include/sario.h")):find("SARIO_H", 1, true) ~= nil, true)
    test.equal(read(path("src/main.c")):find("int main", 1, true) ~= nil, true)
  end)

  test.it("applies unified diff updates", function()
    apply_ok([[
--- a/sample.txt
+++ b/sample.txt
@@ -1,3 +1,3 @@
 alpha
-beta
+delta
 gamma
]])
    test.equal(read(path("sample.txt")), "alpha\ndelta\ngamma\n")
  end)

  test.it("applies unified diff additions", function()
    apply_ok([[
--- /dev/null
+++ b/unified-added.txt
@@ -0,0 +1,2 @@
+one
+two
]])
    test.equal(read(path("unified-added.txt")), "one\ntwo\n")
  end)

  test.it("lets unified diff additions replace existing targets", function()
    write(path("unified-replace.txt"), "old\n")
    apply_ok([[
--- /dev/null
+++ b/unified-replace.txt
@@ -0,0 +1 @@
+new
]])
    test.equal(read(path("unified-replace.txt")), "new\n")
  end)

  test.it("applies unified diff deletions", function()
    write(path("unified-delete.txt"), "gone\n")
    apply_ok([[
--- a/unified-delete.txt
+++ /dev/null
@@ -1 +0,0 @@
-gone
]])
    test.equal(exists(path("unified-delete.txt")), false)
  end)

  test.it("preserves no-newline unified update behavior", function()
    write(path("nonewline.txt"), "alpha")
    apply_ok([[
--- a/nonewline.txt
+++ b/nonewline.txt
@@ -1 +1 @@
-alpha
+beta
\ No newline at end of file
]])
    test.equal(read(path("nonewline.txt")), "beta")
  end)

  test.it("denies patch application when confirmation is rejected", function()
    tools.set_confirm_write(function()
      return false
    end)
    local ok, err = tools.apply_patch([[
*** Begin Patch
*** Add File: denied.txt
+created
*** End Patch
]])
    test.equal(ok, false)
    test.equal(err, "user denied patch application")
    test.equal(exists(path("denied.txt")), false)
  end)

  test.it("rejects compacted historical placeholders", function()
    local err = apply_fail("[omitted 42 bytes from prior tool argument `patch`]")
    test.equal(err:find("compacted historical placeholder", 1, true) ~= nil, true)
  end)

  test.it("rejects empty or non-patch input", function()
    test.equal(apply_fail(""), "patch contains no files")
    test.equal(apply_fail("not a patch"), "patch contains no files")
  end)

  test.it("rejects structured patches without operations", function()
    test.equal(apply_fail([[
*** Begin Patch
*** End Patch
]]), "patch contains no operations")
  end)

  test.it("rejects duplicate structured begin markers", function()
    test.equal(apply_fail([[
*** Begin Patch
*** Begin Patch
*** Add File: duplicate.txt
+created
*** End Patch
]]), "duplicate Begin Patch marker")
  end)

  test.it("rejects unexpected structured lines outside operations", function()
    local err = apply_fail([[
*** Begin Patch
unexpected
*** End Patch
]])
    test.equal(err:find("unexpected patch line", 1, true) ~= nil, true)
  end)

  test.it("rejects structured updates without changes", function()
    test.equal(apply_fail([[
*** Begin Patch
*** Update File: sample.txt
@@
 alpha
 beta
*** End Patch
]]), "Update File has no changes: sample.txt")
  end)

  test.it("rejects stale structured context", function()
    local err = apply_fail([[
*** Begin Patch
*** Update File: sample.txt
@@
-missing
+new
*** End Patch
]])
    test.equal(err, "patch context mismatch in sample.txt")
  end)

  test.it("rejects missing update files", function()
    local err = apply_fail([[
*** Begin Patch
*** Update File: missing.txt
@@
+new
*** End Patch
]])
    test.equal(err:find("No such file", 1, true) ~= nil or err:find("cannot open", 1, true) ~= nil, true)
  end)

  test.it("rejects missing delete files", function()
    local err = apply_fail([[
*** Begin Patch
*** Delete File: missing.txt
*** End Patch
]])
    test.equal(err:find("No such file", 1, true) ~= nil or err:find("cannot open", 1, true) ~= nil, true)
  end)

  test.it("rejects delete bodies and moves", function()
    local err = apply_fail([[
*** Begin Patch
*** Delete File: sample.txt
+body
*** End Patch
]])
    test.equal(err, "Delete File does not accept body lines: sample.txt")

    err = apply_fail([[
*** Begin Patch
*** Delete File: sample.txt
*** Move to: deleted.txt
*** End Patch
]])
    test.equal(err, "Delete File does not support Move to: sample.txt")
  end)

  test.it("rejects multiple operations for the same file", function()
    local err = apply_fail([[
*** Begin Patch
*** Add File: same.txt
+one
*** Add File: same.txt
+two
*** End Patch
]])
    test.equal(err:find("multiple operations for the same file", 1, true) ~= nil, true)
  end)

  test.it("rejects paths outside loaded project roots", function()
    local err = apply_fail([[
*** Begin Patch
*** Add File: ]] .. ".." .. [[/outside.txt
+bad
*** End Patch
]])
    test.equal(err:find("outside loaded project roots", 1, true) ~= nil, true)
  end)

  test.it("rejects unified patches with invalid hunk headers", function()
    local err = apply_fail([[
--- a/sample.txt
+++ b/sample.txt
@@ bad header
-alpha
+beta
]])
    test.equal(err:find("invalid hunk header", 1, true) ~= nil, true)
  end)

  test.it("rejects stale unified context", function()
    local err = apply_fail([[
--- a/sample.txt
+++ b/sample.txt
@@ -1,1 +1,1 @@
-missing
+new
]])
    test.equal(err:find("patch removal mismatch", 1, true) ~= nil, true)
  end)
end)
