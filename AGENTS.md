# AGENTS.md

Guidance for coding agents working on the Pragtical Assistant plugin.

## Project Overview

This repository contains a Pragtical plugin for AI-assisted coding
conversations. The plugin integrates AI providers into the editor, renders
conversation history with `core.markdownview`, edits prompts through a
Markdown-highlighted `core.docview`, uses the Widget library for interface
controls, and communicates with providers through pluggable communication
backends.

Current provider support includes HTTP chat providers such as Ollama,
llama.cpp server, LM Studio, and OpenAI, Codex through its persistent
app-server JSONL interface, generic ACP agents, and GitHub Copilot through its
ACP interface. Treat HTTP/OpenAI-compatible agents and ACP/app-server agents as
different adapter families.

## Important Files

- `init.lua` wires plugin configuration, commands, keymaps, agents, and
  backend registration.
- `agent.lua` defines the shared agent/provider interface.
- `backend/init.lua` defines the communication backend base.
- `backend/http.lua` is the HTTP transport backend.
- `backend/appserver.lua` is the persistent Codex app-server backend.
- `backend/cli.lua` is the one-shot process backend kept for CLI-style agents.
- `conversation.lua` stores ordered messages, project instructions, memories,
  and project-local session persistence.
- `promptview.lua` defines the Widget-based assistant view with a top
  transcript `MarkdownView` and bottom prompt `DocView`.
- `tools.lua` is the tool facade and registration entrypoint.
- `tool/` contains individual tool implementations and the shared tool
  abstraction in `tool/init.lua`.
- `tool_router.lua` selects tools for collaboration modes and routes tool
  permission checks.
- `agent/ollama.lua`, `agent/llamacpp.lua`, `agent/lms.lua`,
  `agent/openai.lua`, `agent/codex.lua`, `agent/acp.lua`, and
  `agent/copilot.lua` define provider defaults.
- `tests/` contains Pragtical tests run with `pragtical test tests`.
- `live_tests/` contains manual/live provider conversation checks. These may
  write raw request/response artifacts and should not be treated as sanitized
  fixtures.

## Pragtical Integration

Use Pragtical APIs instead of ad hoc UI or networking:

- Use `core.http.request` and `core.http.sse` for HTTP calls.
- Use `require "core.json"` for API JSON and saved session files.
- Use `core.markdownview` for transcript rendering.
- Use `core.docview` with a memory-backed `.md` document for prompt editing.
- Use the Widget library for labels, buttons, dialogs, and other interface
  controls. For reference or local development, clone
  `https://github.com/pragtical/widget`.
- Widget-based views already extend `core.view`; prefer `Widget:extend()` for
  interface-heavy views.
- When embedding non-widget views such as `MarkdownView` or `DocView`, assign
  their rectangles and forward draw/update/input explicitly.
- Use `core.command`, `core.keymap`, and `core.config` following existing plugin
  patterns.
- Use `core.add_thread` or `core.add_background_thread` for asynchronous work.

For upstream Pragtical examples, clone
`https://github.com/pragtical/pragtical` and inspect
`data/plugins/settings.lua` and `data/plugins/projectsearch.lua` in that
checkout. For SCM and LSP integration patterns, clone
`https://github.com/pragtical/scm` and inspect `ui/`, and clone
`https://github.com/pragtical/lsp` and inspect `ui/`.

## Context And Persistence

Every new conversation must begin with a system prompt that instructs the model
to act as a coding assistant for the current project.

The assistant should read the current project root `AGENTS.md` when present and
include it in the conversation context. Assistant memories are project-local and
stored in:

```text
.pragtical/assistant/memories/
```

Conversation sessions are project-local JSON files stored in:

```text
.pragtical/assistant/sessions/
```

Runtime environment context is sent as a separate provider-only context message
and should remain separate from the main system role message.

Do not persist secrets or transient HTTP/process handles in saved sessions.
Raw provider logs and live-test artifacts may contain prompts, paths, provider
payloads, and generated code; treat them as local debug artifacts unless they
have been reviewed and sanitized. The global `api_key` setting is intended for
agents that declare an API key environment variable, such as OpenAI. Do not send
that key to local providers like Ollama unless the provider explicitly opts into
API key authentication.

## Backend Model

Agents and communication backends are separate layers. Agents define provider
defaults and request/response behavior. Backends define how communication
happens.

`backend/init.lua` is the shared communication backend base, similar in spirit
to `backend/init.lua` from a `https://github.com/pragtical/scm` clone.
`backend/http.lua` handles URL-based providers.
`backend/appserver.lua` starts `codex app-server` as a persistent JSONL
JSON-RPC process, initializes the client, starts or resumes Codex threads,
starts turns, streams `item/agentMessage/delta`, and persists Codex thread ids
on conversations. `backend/acp.lua` manages ACP transports, sessions, model and
mode config, permission requests, tool activity, and client-side file/terminal
requests. `backend/cli.lua` starts one-shot subprocesses for agents that
explicitly provide a command builder. Process/stdin backends should follow
`server.lua` from a `https://github.com/pragtical/lsp` clone and the upstream
Pragtical `docs/api/process.lua` reference from a
`https://github.com/pragtical/pragtical` clone, especially for partial writes,
framed reads, stderr draining, cancellation, and process cleanup.

## Tools

Registered assistant tools currently include:

- Files: `read`, `search`, `list`, `file_info`, `write`, `edit`, `apply_patch`
- Process: `exec_command`, `write_stdin`, `exec_status`, `send_eof`,
  `interrupt_exec`, `close_exec`
- Web: `web_fetch`, `web_search`, `web_find`
- Git: `git_status`, `git_diff`
- Interaction: `tool_catalog`, `time`, `update_plan`, `request_user_input`

Do not reintroduce legacy tool aliases such as `read_file`, `read_file_range`,
`write_file_contents`, `run_terminal_command`, `list_files`, or `time_now`.
For non-GPT implementation models, prefer advertising `write` and `edit`; for
models whose name contains `gpt`, advertise `apply_patch` instead.

## Tool Safety

Read-only tools may run directly. Any tool that creates, edits, deletes, or
executes project content must require explicit user confirmation before it runs.

Tool paths must stay inside loaded project roots unless the user explicitly
changes the policy. Return clear tool errors instead of silently doing nothing.
Read-only tools may ask before accessing paths outside loaded project roots
unless `allow_any_read_path` is explicitly enabled.

## Testing And Verification

Before finishing behavior changes:

- Run a Lua syntax/load check for edited files where possible.
- Run `pragtical test tests` from this plugin root when tests are added.
- Use `SDL_VIDEO_DRIVER=dummy pragtical test tests` in headless environments.
- Manually verify that a conversation view opens, the transcript renders
  markdown, the prompt editor highlights Markdown syntax, prompt submission
  appends user text, provider output streams into the transcript, session
  save/resume works, and cancellation stops pending requests.

Keep edits scoped and preserve Lua annotations when changing public plugin
interfaces.
