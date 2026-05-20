local test = require "core.test"
dofile("tests/helper.inc")
local common = require "core.common"
local config = require "core.config"
local http = require "core.http"
local json = require "core.json"
local tool_context = require "plugins.assistant.tool_context"
local tools = require "plugins.assistant.tools"
local Ollama = require "plugins.assistant.agent.ollama"

local root = assistant_test_temp_path("tools")

local function mkdirp(path)
  local info = system.get_file_info(path)
  if info and info.type == "dir" then return end
  common.mkdirp(path)
end

local function write(path, text)
  local fp = assert(io.open(path, "wb"))
  fp:write(text)
  fp:close()
end

local function read_fixture(path)
  local fp = assert(io.open(path, "rb"))
  local text = fp:read("*a")
  fp:close()
  return text
end

local function shell_quote(path)
  return "'" .. tostring(path):gsub("'", [["'"']]) .. "'"
end

local function system_base64(path)
  local handle = assert(io.popen("base64 " .. shell_quote(path) .. " | tr -d '\\n'", "r"))
  local output = handle:read("*a")
  local ok = handle:close()
  test.ok(ok, "system base64 command failed")
  return output
end

test.describe("assistant tools", function()
  local old_allow_any_read_path
  local old_web_search_url
  local old_web_search_query_param
  local old_web_search_results_path
  local old_web_timeout_ms
  local old_web_allow_hosts
  local old_http_request
  local old_yield_ui

  test.before_each(function()
    old_allow_any_read_path = config.plugins.assistant.allow_any_read_path
    old_web_search_url = config.plugins.assistant.web_search_url
    old_web_search_query_param = config.plugins.assistant.web_search_query_param
    old_web_search_results_path = config.plugins.assistant.web_search_results_path
    old_web_timeout_ms = config.plugins.assistant.web_timeout_ms
    old_web_allow_hosts = config.plugins.assistant.web_allow_hosts
    old_http_request = http.request
    old_yield_ui = tool_context.yield_ui
    config.plugins.assistant.allow_any_read_path = false
    config.plugins.assistant.web_search_url = ""
    config.plugins.assistant.web_search_query_param = "q"
    config.plugins.assistant.web_search_results_path = ""
    config.plugins.assistant.web_timeout_ms = 10000
    config.plugins.assistant.web_allow_hosts = {}
    common.rm(root, true)
    mkdirp(root)
    write(root .. PATHSEP .. "sample.txt", "alpha\nbeta\n")
    core.projects = {
      {
        path = root,
        absolute_path = function(_, path)
          if path:match("^/") then return path end
          return root .. PATHSEP .. path
        end
      }
    }
  end)

  test.it("registers activity renderers for exposed tools", function()
    local agent = tools.register_agent_tools(Ollama())
    local read_tool = agent.tools.read
    local exec_tool = agent.tools.exec_command
    local patch_tool = agent.tools.apply_patch
    local edit_tool = agent.tools.edit
    local write_tool = agent.tools.write

    test.equal(type(read_tool.activity_markdown), "function")
    test.equal(type(read_tool.compact_activity_markdown), "function")
    test.equal(
      read_tool.compact_activity_markdown({ arguments = { path = "main.c" } }, "completed", ""),
      "**Reading**: `main.c` (completed)"
    )
    test.equal(
      exec_tool.compact_activity_markdown({ name = "exec_command", arguments = { cmd = "make test", workdir = "project" } }, "running", ""),
      "**Running command**: `make test` in `project` (running)"
    )
    test.equal(
      patch_tool.compact_activity_markdown({ arguments = { patch = "*** Begin Patch\n*** Update File: main.c\n@@\n-old\n+new\n*** End Patch" } }, "completed", ""),
      "**Patching**: `main.c` (completed)"
    )
    local edit_activity = edit_tool.compact_activity_markdown({
      arguments = {
        path = "main.c",
        edits = {
          { oldText = "old line", newText = "new line" }
        }
      }
    }, "requested", "")
    test.equal(edit_activity:find("**Editing**: `main.c` (requested)", 1, true) ~= nil, true)
    test.equal(edit_activity:find("```diff", 1, true) ~= nil, true)
    test.equal(edit_activity:find("-old line", 1, true) ~= nil, true)
    test.equal(edit_activity:find("+new line", 1, true) ~= nil, true)
    local completed_edit_activity = edit_tool.compact_activity_markdown({
      arguments = {
        path = "main.c",
        edits = {
          { oldText = "old line", newText = "new line" }
        }
      }
    }, "completed", "")
    test.equal(completed_edit_activity, "**Editing**: `main.c` (completed)")

    local add_activity = write_tool.compact_activity_markdown({
      arguments = {
        path = "new.c",
        content = "int main(void) {\n  return 0;\n}\n"
      }
    }, "requested", "")
    test.equal(add_activity:find("**Adding**: `new.c` (requested)", 1, true) ~= nil, true)
    test.equal(add_activity:find("```diff", 1, true) ~= nil, true)
    test.equal(add_activity:find("+int main(void) {", 1, true) ~= nil, true)

    local write_activity = write_tool.compact_activity_markdown({
      arguments = {
        path = "sample.txt",
        content = "replacement\n"
      }
    }, "requested", "")
    test.equal(write_activity:find("**Writing**: `sample.txt` (requested)", 1, true) ~= nil, true)
    test.equal(write_activity:find("+replacement", 1, true) ~= nil, true)

    local completed_write_activity = write_tool.compact_activity_markdown({
      arguments = {
        path = "sample.txt",
        content = "replacement\n"
      }
    }, "completed", "replaced: sample.txt")
    test.equal(completed_write_activity, "**Writing**: `sample.txt` (completed)")
  end)

  test.after_each(function()
    config.plugins.assistant.allow_any_read_path = old_allow_any_read_path
    config.plugins.assistant.web_search_url = old_web_search_url
    config.plugins.assistant.web_search_query_param = old_web_search_query_param
    config.plugins.assistant.web_search_results_path = old_web_search_results_path
    config.plugins.assistant.web_timeout_ms = old_web_timeout_ms
    config.plugins.assistant.web_allow_hosts = old_web_allow_hosts
    http.request = old_http_request
    tool_context.yield_ui = old_yield_ui
    tools.set_confirm_write(nil)
  end)

  test.it("reads project files", function()
    test.equal(read_fixture(root .. PATHSEP .. "sample.txt"), "alpha\nbeta\n")
  end)

  test.it("reads project files with offset and limit", function()
    write(root .. PATHSEP .. "long.txt", "one\ntwo\nthree\nfour\n")
    local result = tools.read(root .. PATHSEP .. "long.txt", 2, 2)
    test.equal(result:find("two", 1, true) ~= nil, true)
    test.equal(result:find("three", 1, true) ~= nil, true)
    test.equal(result:find("one", 1, true), nil)
    test.equal(result:find("Use offset=4 to continue", 1, true) ~= nil, true)
  end)

  test.it("reports read offsets beyond end of file", function()
    local result = tools.read(root .. PATHSEP .. "sample.txt", 99)
    test.equal(result:find("beyond end of file", 1, true) ~= nil, true)
  end)

  test.it("reads supported image files as structured attachments", function()
    local image_path = root .. PATHSEP .. "sample.png"
    local image = canvas.new(2, 2, { 255, 0, 0, 255 }, true)
    local saved, save_err = image:save_image(image_path)
    test.ok(saved, save_err)

    local result = tools.read(image_path)

    test.equal(type(result), "table")
    test.equal(result.text:find("Read image file", 1, true) ~= nil, true)
    test.equal(result.attachments[1].mime_type, "image/png")
    test.equal(result.attachments[1].original_width, 2)
    test.equal(result.attachments[1].original_height, 2)
    test.equal(result.attachments[1].width, 2)
    test.equal(result.attachments[1].height, 2)
    test.equal(type(result.attachments[1].data), "string")
    test.equal(#result.attachments[1].data > 0, true)
  end)

  test.it("encodes jpeg image attachments as correct base64 png data", function()
    local image_path = root .. PATHSEP .. "space.jpg"
    write(image_path, read_fixture("tests" .. PATHSEP .. "space.jpg"))
    local result = tools.read(image_path)
    local attachment = result.attachments[1]

    local image = assert(canvas.load_image(image_path))
    local scaled = image:scaled(1024, 576, "nearest")
    local expected_path = root .. PATHSEP .. "expected-space.png"
    local saved, save_err = scaled:save_image(expected_path)
    test.ok(saved, save_err)

    test.equal(type(result), "table")
    test.equal(attachment.mime_type, "image/png")
    test.equal(attachment.original_width, 3840)
    test.equal(attachment.original_height, 2160)
    test.equal(attachment.width, 1024)
    test.equal(attachment.height, 576)
    test.equal(attachment.data:sub(1, 11), "iVBORw0KGgo")
    test.equal(attachment.data, system_base64(expected_path))
  end)

  test.it("reports image load failures as text results", function()
    local image_path = root .. PATHSEP .. "broken.png"
    write(image_path, "not a png")
    local original_load_image = canvas.load_image
    canvas.load_image = function()
      return nil, "decode failed"
    end

    local result = tools.read(image_path)

    canvas.load_image = original_load_image
    test.equal(type(result), "string")
    test.equal(result:find("Could not read image file", 1, true) ~= nil, true)
    test.equal(result:find("decode failed", 1, true) ~= nil, true)
  end)

  test.it("writes project files after confirmation", function()
    tools.set_confirm_write(function(action, path)
      return action == "write" and path:find("created.txt", 1, true) ~= nil
    end)

    local ok, result = tools.write("nested/created.txt", "hello\n")

    test.equal(ok, true)
    test.equal(result:find("created: nested/created.txt", 1, true) ~= nil, true)
    test.equal(read_fixture(root .. PATHSEP .. "nested" .. PATHSEP .. "created.txt"), "hello\n")
  end)

  test.it("edits project files with exact text replacements", function()
    tools.set_confirm_write(function(action)
      return action == "edit"
    end)

    local ok, result = tools.edit("sample.txt", {
      { oldText = "alpha", newText = "ALPHA" },
      { oldText = "beta", newText = "BETA" }
    })

    test.equal(ok, true)
    test.equal(result:find("Successfully replaced 2 block", 1, true) ~= nil, true)
    test.equal(read_fixture(root .. PATHSEP .. "sample.txt"), "ALPHA\nBETA\n")
  end)

  test.it("rejects ambiguous edit replacements", function()
    write(root .. PATHSEP .. "dupes.txt", "same\nsame\n")
    tools.set_confirm_write(function() return true end)

    local ok, result = tools.edit("dupes.txt", {
      { oldText = "same", newText = "other" }
    })

    test.equal(ok, false)
    test.equal(result:find("occurrences", 1, true) ~= nil, true)
  end)

  test.it("preserves crlf line endings when editing", function()
    write(root .. PATHSEP .. "crlf.txt", "one\r\ntwo\r\n")
    tools.set_confirm_write(function() return true end)

    local ok = tools.edit("crlf.txt", {
      { oldText = "two", newText = "TWO" }
    })

    test.equal(ok, true)
    test.equal(read_fixture(root .. PATHSEP .. "crlf.txt"), "one\r\nTWO\r\n")
  end)

  test.it("cooperatively yields during new read write and edit tools", function()
    local yields = 0
    tool_context.yield_ui = function()
      yields = yields + 1
    end
    tools.set_confirm_write(function() return true end)

    local lines = {}
    for i = 1, 450 do
      lines[i] = "line " .. i
    end
    write(root .. PATHSEP .. "large.txt", table.concat(lines, "\n") .. "\n")

    local read_result = tools.read("large.txt", 1, 450)
    local write_ok = tools.write("written.txt", table.concat(lines, "\n") .. "\n")
    local edit_ok = tools.edit("large.txt", {
      { oldText = "line 225", newText = "line two-two-five" }
    })

    test.equal(read_result:find("line 450", 1, true) ~= nil, true)
    test.equal(write_ok, true)
    test.equal(edit_ok, true)
    test.equal(yields > 0, true)
  end)

  test.it("searches project files", function()
    local results = tools.search(root, "beta")
    test.equal(results:find("sample.txt", 1, true) ~= nil, true)
  end)

  test.it("lists project files", function()
    local results = tools.list(root, false, 20)
    test.equal(results:find("sample.txt", 1, true) ~= nil, true)
  end)

  test.it("treats null-like list file patterns as empty", function()
    local results = tools.list(root, false, 20, "None")
    test.equal(results:find("sample.txt", 1, true) ~= nil, true)
  end)

  test.it("limits large recursive file listings by output size", function()
    local long_dir = root .. PATHSEP .. "deep"
    mkdirp(long_dir)
    for i = 1, 2200 do
      write(long_dir .. PATHSEP .. string.format("very-long-generated-file-name-%03d.txt", i), "x\n")
    end

    local results = tools.list(root, true, 5000)

    test.equal(results:find("stopped after reaching", 1, true) ~= nil, true)
    test.equal(#results < 135000, true)
  end)

  test.it("asks before read-only tools access outside project roots", function()
    local parent = root .. "-parent"
    local child = parent .. PATHSEP .. "assistant"
    common.rm(parent, true)
    mkdirp(child)
    write(parent .. PATHSEP .. "parent.txt", "parent\n")
    core.projects = {
      {
        path = child,
        absolute_path = function(_, path)
          if path:match("^/") then return path end
          return child .. PATHSEP .. path
        end
      }
    }

    local requested
    tools.set_confirm_write(function(action, path)
      requested = { action = action, path = path }
      return true
    end)
    local results = tools.list(parent, false, 20)
    test.equal(results:find("parent.txt", 1, true) ~= nil, true)
    test.equal(read_fixture(parent .. PATHSEP .. "parent.txt"), "parent\n")
    test.equal(requested.action, "read_path")
    test.equal(requested.path, parent)
    tools.set_confirm_write(nil)

    tools.set_confirm_write(function() return true end)
    local ok, err = tools.write(parent .. PATHSEP .. "parent.txt", "changed\n")
    test.equal(ok, false)
    test.equal(err:find("outside loaded project roots", 1, true) ~= nil, true)
    tools.set_confirm_write(nil)
    common.rm(parent, true)
  end)

  test.it("denies read-only tools outside project roots without confirmation", function()
    local outside = root .. "-outside"
    common.rm(outside, true)
    mkdirp(outside)
    write(outside .. PATHSEP .. "outside.txt", "outside\n")
    tools.set_confirm_write(nil)

    local result = tools.read(outside .. PATHSEP .. "outside.txt")
    test.equal(result:find("user denied reading outside loaded project roots", 1, true) ~= nil, true)
    common.rm(outside, true)
  end)

  test.it("allows read-only tools outside project roots when configured", function()
    local outside = root .. "-outside"
    common.rm(outside, true)
    mkdirp(outside)
    write(outside .. PATHSEP .. "outside.txt", "outside\n")
    config.plugins.assistant.allow_any_read_path = true
    local requested = false
    tools.set_confirm_write(function()
      requested = true
      return false
    end)

    local result = tools.read(outside .. PATHSEP .. "outside.txt")
    local listing = tools.list(outside, false, 20)

    test.equal(result, "outside\n")
    test.equal(listing:find("outside.txt", 1, true) ~= nil, true)
    test.equal(requested, false)
    common.rm(outside, true)
  end)

  test.it("reads file slices", function()
    local results = tools.read(root .. PATHSEP .. "sample.txt", 2, 1)
    test.equal(results, "beta\n")
  end)

  test.it("reports file info and writes file contents", function()
    local info = tools.file_info(root .. PATHSEP .. "sample.txt")
    local hash = info:match("hash:%s*(%x+)")
    test.not_nil(hash)
    tools.set_confirm_write(function() return true end)
    local ok, result = tools.write(root .. PATHSEP .. "sample.txt", "new\n")
    test.equal(ok, true)
    test.equal(result:find("replaced:", 1, true) ~= nil, true)
    test.equal(result:find("old_hash:", 1, true) ~= nil, true)
    test.equal(read_fixture(root .. PATHSEP .. "sample.txt"), "new\n")
    tools.set_confirm_write(nil)
  end)

  test.it("writes new file contents", function()
    tools.set_confirm_write(function() return true end)
    local ok, result = tools.write(root .. PATHSEP .. "created.txt", "new\n")
    test.equal(ok, true)
    test.equal(result:find("created:", 1, true) ~= nil, true)
    test.equal(read_fixture(root .. PATHSEP .. "created.txt"), "new\n")
  end)

  test.it("refuses compacted placeholders for file writes", function()
    tools.set_confirm_write(function() return true end)
    local ok, result = tools.write(root .. PATHSEP .. "sample.txt", "[omitted 42 bytes from prior tool argument `contents`]")
    test.equal(ok, false)
    test.equal(result:find("compacted historical placeholder", 1, true) ~= nil, true)
  end)

  test.it("applies unified diff patches", function()
    tools.set_confirm_write(function() return true end)
    local ok, result = tools.apply_patch([[
--- a/sample.txt
+++ b/sample.txt
@@ -1,2 +1,2 @@
 alpha
-beta
+gamma
]])
    test.equal(ok, true)
    test.equal(result:find("applied patch", 1, true) ~= nil, true)
    test.equal(read_fixture(root .. PATHSEP .. "sample.txt"), "alpha\ngamma\n")
    tools.set_confirm_write(nil)
  end)

  test.it("applies structured add update and delete patches", function()
    write(root .. PATHSEP .. "remove.txt", "delete me\n")
    tools.set_confirm_write(function() return true end)
    local ok, result = tools.apply_patch([[
*** Begin Patch
*** Add File: added.txt
+created
*** Update File: sample.txt
@@
 alpha
-beta
+delta
*** Delete File: remove.txt
*** End Patch
]])
    test.equal(ok, true)
    test.equal(result:find("applied patch", 1, true) ~= nil, true)
    test.equal(read_fixture(root .. PATHSEP .. "sample.txt"), "alpha\ndelta\n")
    test.equal(read_fixture(root .. PATHSEP .. "added.txt"), "created\n")
    test.equal(system.get_file_info(root .. PATHSEP .. "remove.txt"), nil)
  end)

  test.it("accepts structured patch operation headers without colons", function()
    tools.set_confirm_write(function() return true end)
    local ok, result = tools.apply_patch([[
*** Begin Patch
*** Add File no-colon.txt
+created
*** End Patch
]])
    test.equal(ok, true)
    test.equal(result:find("applied patch", 1, true) ~= nil, true)
    test.equal(read_fixture(root .. PATHSEP .. "no-colon.txt"), "created\n")
  end)

  test.it("accepts bare add-file content from live model patches", function()
    tools.set_confirm_write(function() return true end)
    local ok, result = tools.apply_patch([[
*** Begin Patch
*** Add File: Makefile
# Sario - Super Mario Bros Clone
# Makefile for building with SDL2

CC = gcc
CFLAGS = -Wall -Wextra -g -std=c11
LDFLAGS = $(shell pkg-config --libs sdl2)
CFLAGS += $(shell pkg-config --cflags sdl2)

SRCDIR = src
OBJDIR = obj
BINDIR = bin

SOURCES = $(SRCDIR)/main.c \
          $(SRCDIR)/game.c \
          $(SRCDIR)/input.c

OBJECTS = $(patsubst $(SRCDIR)/%.c,$(OBJDIR)/%.o,$(SOURCES))
TARGET = $(BINDIR)/sario

.PHONY: all clean run

all: $(TARGET)

$(TARGET): $(OBJECTS) | $(BINDIR)
	$(CC) $(CFLAGS) -o $@ $(OBJECTS) $(LDFLAGS)

$(OBJDIR)/%.o: $(SRCDIR)/%.c | $(OBJDIR)
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -rf $(OBJDIR) $(BINDIR)

run: $(TARGET)
	./$(TARGET)

*** Add File: include/input.h
#ifndef SARIO_INPUT_H
#define SARIO_INPUT_H

#include "common.h"

typedef struct Input {
    bool left;
    bool right;
    bool jump;
    bool run;
    bool quit;
} Input;

void input_update(Input *input, const Uint8 *keys);
Input input_get(const Uint8 *keys);

#endif // SARIO_INPUT_H

*** End Patch
]])
    test.equal(ok, true)
    test.equal(result:find("applied patch to 2 file", 1, true) ~= nil, true)
    test.equal(read_fixture(root .. PATHSEP .. "Makefile"):find("Sario %- Super Mario Bros Clone") ~= nil, true)
    test.equal(read_fixture(root .. PATHSEP .. "include" .. PATHSEP .. "input.h"):find("typedef struct Input", 1, true) ~= nil, true)
  end)

  test.it("accepts live model add-file patches missing the end marker", function()
    tools.set_confirm_write(function() return true end)
    local ok, result = tools.apply_patch([[
*** Begin Patch
*** Add File: src/game.h
+/*
+ * Sario - Super Mario Bros Clone
+ * Core game definitions and constants
+ */
+
+#ifndef SARIO_GAME_H
+#define SARIO_GAME_H
+
+#include <SDL2/SDL.h>
+
+#define SCREEN_WIDTH      256
+#define SCREEN_HEIGHT     240
+#define RENDER_SCALE      3
+#define WINDOW_WIDTH      (SCREEN_WIDTH * RENDER_SCALE)
+#define WINDOW_HEIGHT     (SCREEN_HEIGHT * RENDER_SCALE)
+#define TILE_SIZE         16
+
+typedef enum {
+    STATE_TITLE,
+    STATE_PLAYING,
+    STATE_GAME_OVER,
+    STATE_WIN
+} GameState;
+
+typedef struct Input {
+    int left;
+    int right;
+    int jump;
+    int run;
+    int start;
+} Input;
+
+int rect_collide(float x1, int w1, float y1, int h1,
+                 float x2, int w2, float y2, int h2);
+
+#endif /* SARIO_GAME_H */
]])
    test.equal(ok, true)
    test.equal(result:find("applied patch", 1, true) ~= nil, true)
    test.equal(read_fixture(root .. PATHSEP .. "src" .. PATHSEP .. "game.h"):find("SARIO_GAME_H", 1, true) ~= nil, true)
  end)

  test.it("accepts the captured failed live apply_patch fixture", function()
    tools.set_confirm_write(function() return true end)
    local patch = read_fixture("live_tests/failed-apply-patch.patch")
    local ok, result = tools.apply_patch(patch)
    test.equal(ok, true)
    test.equal(result:find("applied patch", 1, true) ~= nil, true)
    test.equal(read_fixture(root .. PATHSEP .. "include" .. PATHSEP .. "sario.h"):find("SARIO_H", 1, true) ~= nil, true)
    test.equal(read_fixture(root .. PATHSEP .. "src" .. PATHSEP .. "main.c"):find("int main", 1, true) ~= nil, true)
    test.equal(read_fixture(root .. PATHSEP .. "README.md"):find("# Sario", 1, true) ~= nil, true)
  end)

  test.it("accepts structured patch wrappers and environment headers", function()
    tools.set_confirm_write(function() return true end)
    local ok, result = tools.apply_patch([[
<<'EOF'
*** Begin Patch
*** Environment ID: test
*** Add File: wrapped.txt
+created
*** End Patch
EOF
]])
    test.equal(ok, true)
    test.equal(result:find("applied patch", 1, true) ~= nil, true)
    test.equal(read_fixture(root .. PATHSEP .. "wrapped.txt"), "created\n")
  end)

  test.it("accepts structured patches in common model wrappers", function()
    tools.set_confirm_write(function() return true end)
    local ok, result = tools.apply_patch([[
Here is the patch:

```patch
*** Begin Patch
*** Add File: fenced.txt
+created
*** End Patch
```
]])
    test.equal(ok, true)
    test.equal(result:find("applied patch", 1, true) ~= nil, true)
    test.equal(read_fixture(root .. PATHSEP .. "fenced.txt"), "created\n")
  end)

  test.it("creates parent directories for structured add files", function()
    tools.set_confirm_write(function() return true end)
    local ok = tools.apply_patch([[
*** Begin Patch
*** Add File: nested/dir/created.txt
+created
*** End Patch
]])
    test.equal(ok, true)
    test.equal(read_fixture(root .. PATHSEP .. "nested" .. PATHSEP .. "dir" .. PATHSEP .. "created.txt"), "created\n")
  end)

  test.it("lets structured add files replace existing files", function()
    write(root .. PATHSEP .. "existing.txt", "old\n")
    tools.set_confirm_write(function() return true end)
    local ok = tools.apply_patch([[
*** Begin Patch
*** Add File: existing.txt
+new
*** End Patch
]])
    test.equal(ok, true)
    test.equal(read_fixture(root .. PATHSEP .. "existing.txt"), "new\n")
  end)

  test.it("uses structured chunk context to disambiguate repeated lines", function()
    write(root .. PATHSEP .. "repeat.txt", "one\nsame\nold\nsame\nold\n")
    tools.set_confirm_write(function() return true end)
    local ok = tools.apply_patch([[
*** Begin Patch
*** Update File: repeat.txt
@@ same
-old
+new
*** End Patch
]])
    test.equal(ok, true)
    test.equal(read_fixture(root .. PATHSEP .. "repeat.txt"), "one\nsame\nnew\nsame\nold\n")
  end)

  test.it("honors structured EOF anchors", function()
    write(root .. PATHSEP .. "tail.txt", "alpha\nbeta\nalpha\n")
    tools.set_confirm_write(function() return true end)
    local ok = tools.apply_patch([[
*** Begin Patch
*** Update File: tail.txt
-alpha
+omega
*** End of File
*** End Patch
]])
    test.equal(ok, true)
    test.equal(read_fixture(root .. PATHSEP .. "tail.txt"), "alpha\nbeta\nomega\n")
  end)

  test.it("moves structured update files", function()
    write(root .. PATHSEP .. "move.txt", "alpha\nbeta\n")
    tools.set_confirm_write(function() return true end)
    local ok = tools.apply_patch([[
*** Begin Patch
*** Update File: move.txt
*** Move to: moved/renamed.txt
@@
-beta
+gamma
*** End Patch
]])
    test.equal(ok, true)
    test.equal(system.get_file_info(root .. PATHSEP .. "move.txt"), nil)
    test.equal(read_fixture(root .. PATHSEP .. "moved" .. PATHSEP .. "renamed.txt"), "alpha\ngamma\n")
  end)

  test.it("supports structured move-only updates", function()
    write(root .. PATHSEP .. "rename.txt", "alpha\n")
    tools.set_confirm_write(function() return true end)
    local ok = tools.apply_patch([[
*** Begin Patch
*** Update File: rename.txt
*** Move to: renamed/only.txt
*** End Patch
]])
    test.equal(ok, true)
    test.equal(system.get_file_info(root .. PATHSEP .. "rename.txt"), nil)
    test.equal(read_fixture(root .. PATHSEP .. "renamed" .. PATHSEP .. "only.txt"), "alpha\n")
  end)

  test.it("accepts empty structured add files", function()
    tools.set_confirm_write(function() return true end)
    local ok, result = tools.apply_patch([[
*** Begin Patch
*** Add File: empty.txt
*** End Patch
]])
    test.equal(ok, true)
    test.equal(result:find("applied patch", 1, true) ~= nil, true)
    test.equal(read_fixture(root .. PATHSEP .. "empty.txt"), "")
  end)

  test.it("rejects empty structured update patches", function()
    tools.set_confirm_write(function() return true end)
    local ok, err = tools.apply_patch([[
*** Begin Patch
*** Update File: sample.txt
@@
 alpha
 beta
*** End Patch
]])
    test.equal(ok, false)
    test.equal(err, "Update File has no changes: sample.txt")
  end)

  test.it("runs approved commands in project directories", function()
    tools.set_confirm_write(function(action)
      return action == "exec_command"
    end)
    local ok, result = tools.exec_command("printf assistant", root, nil, nil, nil, 5000, 5000)
    test.equal(ok, true)
    test.equal(result:find("exit_code: 0", 1, true) ~= nil, true)
    test.equal(result:find("wall_time_ms:", 1, true) ~= nil, true)
    test.equal(result:find("stdout_bytes:", 1, true) ~= nil, true)
    test.equal(result:find("stdout_truncated: false", 1, true) ~= nil, true)
    test.equal(result:find("assistant", 1, true) ~= nil, true)
    tools.set_confirm_write(nil)
  end)

  test.it("runs exec command sessions and writes stdin", function()
    tools.set_confirm_write(function(action)
      return action == "exec_command"
    end)
    local ok, result = tools.exec_command("read line; echo got:$line", root, nil, nil, nil, 1, 5000)
    test.equal(ok, true)
    local session_id = tonumber(result:match("session_id:%s*(%d+)"))
    test.not_nil(session_id)

    ok, result = tools.write_stdin(session_id, "hello\n", 1000, 5000)
    test.equal(ok, true)
    test.equal(result:find("exit_code: 0", 1, true) ~= nil, true)
    test.equal(result:find("got:hello", 1, true) ~= nil, true)
  end)

  test.it("polls and closes exec command sessions", function()
    tools.set_confirm_write(function(action)
      return action == "exec_command"
    end)
    local ok, result = tools.exec_command("cat", root, nil, nil, nil, 1, 5000)
    test.equal(ok, true)
    local session_id = tonumber(result:match("session_id:%s*(%d+)"))
    test.not_nil(session_id)

    ok, result = tools.write_stdin(session_id, "pending\n", 50, 5000)
    test.equal(ok, true)
    test.equal(result:find("pending", 1, true) ~= nil, true)
    test.equal(result:find("session_id: " .. tostring(session_id), 1, true) ~= nil, true)

    ok, result = tools.exec_status(session_id, 50, 5000)
    test.equal(ok, true)
    test.equal(result:find("session_id: " .. tostring(session_id), 1, true) ~= nil, true)

    ok, result = tools.send_eof(session_id, 1000, 5000)
    test.equal(ok, true)
    test.equal(result:find("exit_code: 0", 1, true) ~= nil, true)
    tools.set_confirm_write(nil)
  end)

  test.it("interrupts and closes exec command sessions", function()
    tools.set_confirm_write(function(action)
      return action == "exec_command"
    end)
    local ok, result = tools.exec_command("sleep 30", root, nil, nil, nil, 1, 5000)
    test.equal(ok, true)
    local session_id = tonumber(result:match("session_id:%s*(%d+)"))
    test.not_nil(session_id)

    ok, result = tools.interrupt_exec(session_id, 250, 5000)
    test.equal(ok, true)
    if result:find("exit_code:%s*\n") then
      ok, result = tools.close_exec(session_id, true, 1000, 5000)
      test.equal(ok, true)
    end
    test.equal(result:find("session_id: " .. tostring(session_id), 1, true) ~= nil, true)
    tools.set_confirm_write(nil)
  end)

  test.it("reports allowed roots when command cwd is outside project roots", function()
    local ok, result = tools.exec_command("printf assistant", root .. "-outside", nil, nil, nil, 5000, 5000)
    test.equal(ok, false)
    test.equal(result:find("outside loaded project roots", 1, true) ~= nil, true)
    test.equal(result:find(root, 1, true) ~= nil, true)
  end)

  test.it("fetches web URLs after approval", function()
    local requested
    http.request = function(method, url, options)
      requested = { method = method, url = url, headers = options.headers, timeout = options.timeout }
      options.on_done(true, nil, "hello\n", { status = 200, headers = { ["content-type"] = "text/plain" }, url = url })
    end
    tools.set_confirm_write(function(action, path, details)
      requested = { action = action, path = path, details = details }
      return action == "web_request"
    end)

    local ok, result = tools.web_fetch("https://example.com/page")

    test.equal(ok, true)
    test.equal(result:find("status: 200", 1, true) ~= nil, true)
    test.equal(result:find("hello", 1, true) ~= nil, true)
  end)

  test.it("skips web approval for allowlisted hosts", function()
    local asked = false
    local fetched
    config.plugins.assistant.web_allow_hosts = { "example.com" }
    http.request = function(method, url, options)
      fetched = { method = method, url = url }
      options.on_done(true, nil, "allowed", { status = 200, headers = {}, url = url })
    end
    tools.set_confirm_write(function()
      asked = true
      return false
    end)

    local ok, result = tools.web_fetch("https://example.com/page")

    test.equal(ok, true)
    test.equal(fetched.method, "GET")
    test.equal(result:find("allowed", 1, true) ~= nil, true)
    test.equal(asked, false)
  end)

  test.it("denies web URLs without approval", function()
    http.request = function()
      error("web request should not run")
    end
    tools.set_confirm_write(function(action)
      return action ~= "web_request"
    end)

    local ok, result = tools.web_fetch("https://example.com/page")

    test.equal(ok, false)
    test.equal(result:find("user denied web request", 1, true) ~= nil, true)
  end)

  test.it("reports web HTTP errors", function()
    config.plugins.assistant.web_allow_hosts = { "example.com" }
    http.request = function(_, url, options)
      options.on_done(true, nil, "not found", { status = 404, headers = {}, url = url })
    end

    local ok, result = tools.web_fetch("https://example.com/missing")

    test.equal(ok, false)
    test.equal(result:find("HTTP 404", 1, true) ~= nil, true)
    test.equal(result:find("not found", 1, true) ~= nil, true)
  end)

  test.it("searches a configured web endpoint", function()
    local requested_url
    config.plugins.assistant.web_search_url = "https://search.example/api"
    config.plugins.assistant.web_search_query_param = "query"
    config.plugins.assistant.web_search_results_path = "results"
    config.plugins.assistant.web_allow_hosts = { "search.example" }
    http.request = function(_, url, options)
      requested_url = url
      options.on_done(true, nil, json.encode({
        results = {
          { title = "One", url = "https://one.example", snippet = "Alpha" },
          { title = "Two", url = "https://two.example", snippet = "Beta" }
        }
      }), { status = 200, headers = {}, url = url })
    end

    local ok, result = tools.web_search("hello world", 1)

    test.equal(ok, true)
    test.equal(requested_url:find("query=hello%20world", 1, true) ~= nil, true)
    test.equal(result:find("One", 1, true) ~= nil, true)
    test.equal(result:find("Two", 1, true) == nil, true)
  end)

  test.it("extracts results from configured html search pages", function()
    config.plugins.assistant.web_search_url = "https://search.example/html"
    config.plugins.assistant.web_search_query_param = "q"
    config.plugins.assistant.web_search_results_path = "results"
    config.plugins.assistant.web_allow_hosts = { "search.example" }
    http.request = function(_, url, options)
      options.on_done(true, nil, table.concat({
        "<!doctype html><html><head><title>Search</title></head><body>",
        "<a href=\"/url?q=https%3A%2F%2Fone.example%2Fdocs&amp;sa=U\"><h3>One &amp; Docs</h3></a>",
        "<a href=\"https://duckduckgo.com/l/?uddg=https%3A%2F%2Ftwo.example%2Fguide\">Two Guide</a>",
        "<a href=\"#top\">Skip</a>",
        "</body></html>"
      }), {
        status = 200,
        headers = { ["content-type"] = "text/html" },
        url = url
      })
    end

    local ok, result = tools.web_search("hello world", 1)

    test.equal(ok, true)
    test.equal(result:find("One & Docs", 1, true) ~= nil, true)
    test.equal(result:find("https://one.example/docs", 1, true) ~= nil, true)
    test.equal(result:find("Two Guide", 1, true) == nil, true)
    test.equal(result:find("<!doctype html>", 1, true), nil)
  end)

  test.it("returns raw html when search result extraction fails", function()
    config.plugins.assistant.web_search_url = "https://search.example/html"
    config.plugins.assistant.web_search_query_param = "q"
    config.plugins.assistant.web_allow_hosts = { "search.example" }
    http.request = function(_, url, options)
      options.on_done(true, nil, "<!doctype html><html><body><p>raw results page</p></body></html>", {
        status = 200,
        headers = { ["content-type"] = "text/html" },
        url = url
      })
    end

    local ok, result = tools.web_search("hello world", 1)

    test.equal(ok, true)
    test.equal(result:find("Raw HTML follows", 1, true) ~= nil, true)
    test.equal(result:find("<!doctype html>", 1, true) ~= nil, true)
    test.equal(result:find("raw results page", 1, true) ~= nil, true)
  end)

  test.it("finds text in fetched web bodies", function()
    config.plugins.assistant.web_allow_hosts = { "example.com" }
    http.request = function(_, url, options)
      options.on_done(true, nil, "alpha\nneedle beta\n", { status = 200, headers = {}, url = url })
    end

    local ok, result = tools.web_find("https://example.com/page", "needle")

    test.equal(ok, true)
    test.equal(result, "2:needle beta")
  end)

  test.it("returns current system time", function()
    local ok, result = tools.time("+03:00")

    test.equal(ok, true)
    test.equal(result:find("UTC+03:00", 1, true) ~= nil, true)
  end)

  test.it("lists the assistant tool catalog", function()
    local ok, result = tools.tool_catalog("edit")

    test.equal(ok, true)
    test.equal(result:find("apply_patch", 1, true) ~= nil, true)
    test.equal(result:find("after a context mismatch", 1, true) ~= nil, true)
    test.equal(result:find("add_file", 1, true), nil)
    test.equal(result:find("web_search", 1, true), nil)
  end)

  test.it("filters the assistant tool catalog to selected tool names", function()
    local ok, result = tools.tool_catalog(nil, {
      "list",
      "read",
      "exec_command",
      "request_user_input",
      "update_plan"
    })

    test.equal(ok, true)
    test.equal(result:find("exec_command", 1, true) ~= nil, true)
    test.equal(result:find("request_user_input", 1, true) ~= nil, true)
    test.equal(result:find("add_file", 1, true), nil)
    test.equal(result:find("apply_patch", 1, true), nil)
  end)

  test.it("denies writes without confirmation", function()
    tools.set_confirm_write(nil)
    local ok = tools.write(root .. PATHSEP .. "new.txt", "text")
    test.equal(ok, false)
  end)
end)
