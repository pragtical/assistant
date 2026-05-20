# Pragtical Assistant

**Warning: still work in progress.**

Pragtical Assistant is a Pragtical plugin for AI-assisted coding conversations.
It provides an editor-native conversation view, project-scoped context,
provider integrations, and a guarded tool layer for coding agents.

## Features

- Conversation UI with rendered Markdown transcript and Markdown prompt editor.
- Prompt helpers for inserting files or project files/directories directly into
  the conversation prompt.
- Project-local sessions, memories, raw provider logs, and protocol logs.
- Provider adapters for Ollama, llama.cpp server, LM Studio, OpenAI, Codex, ACP,
  and GitHub Copilot.
- HTTP chat and OpenAI Responses support with streaming, tool calling, local
  compaction, optional reasoning effort, model metadata refresh, and generated
  conversation titles.
- Persistent app-server/ACP style backends for agent protocols.
- Collaboration modes for planning and implementation, with different tool
  availability and approval behavior.
- Async prompt queueing and streamed transcript updates.
- Compact activity rendering by default, with optional verbose activity/tool
  transcript output for debugging.

## Tools

Registered assistant tools currently include:

- Files: `read`, `search`, `list`, `file_info`, `write`, `edit`, `apply_patch`
- Process: `exec_command`, `write_stdin`, `exec_status`, `send_eof`,
  `interrupt_exec`, `close_exec`
- Web: `web_fetch`, `web_search`, `web_find`
- Git: `git_status`, `git_diff`
- Interaction: `tool_catalog`, `time`, `update_plan`, `request_user_input`

For non-GPT implementation models, the plugin advertises `write` and `edit`.
For models whose name contains `gpt`, it advertises `apply_patch` instead of
`write` and `edit`.

## Project Context

New conversations start with a system role message for the current project.
When present, project instructions are read from `AGENTS.md`. Runtime
environment context is sent as a separate provider-only message and refreshed
before provider requests.

Project-local state is stored under:

```
.pragtical/assistant/
```

Important subdirectories and files:

- `sessions/`: saved conversations
- `memories/`: project-local assistant memories
- raw/protocol logs: per-conversation troubleshooting data when logging is
  enabled

## Configuration Highlights

The plugin is configured through `config.plugins.assistant`.

Common options:

- `agent`: default provider (`ollama`, `llamacpp`, `lms`, `openai`, `codex`,
  `acp`, or `copilot`)
- `model`, `base_url`, `api_key`, `api_key_env`
- `stream`: enable streaming responses
- `reasoning_effort`: `none`, `low`, `medium`, or `high`
- `send_max_tokens` and `send_max_tokens_amount`
- `compact_tool_results`, `compact_tool_history`, `auto_compact`
- `verbose_tool_calling`, `verbose_activity`
- `reasoning_activity_messages`
- `generate_conversation_titles`
- `confirm_writes`
- `allow_any_read_path`
- `web_search_url`, `web_search_query_param`, `web_timeout_ms`,
  `web_allow_hosts`

Local providers do not receive API keys unless their agent explicitly opts into
API key authentication.

## Commands And Keymaps

Main commands:

- `assistant:new-conversation`
- `assistant:list-conversations`
- `assistant:list-models`
- `assistant:resume-conversation`
- `assistant:delete-conversation`
- `assistant:add-memory`
- `assistant:list-memories`
- `assistant:delete-memory`

Conversation commands:

- `assistant-conversation:send`
- `assistant-conversation:cancel`
- `assistant-conversation:select-model`
- `assistant-conversation:insert-file`
- `assistant-conversation:insert-project-file`
- `assistant-conversation:cycle-mode`
- `assistant-conversation:compact`
- `assistant-conversation:view-raw-responses`
- `assistant-conversation:view-raw-markdown`
- `assistant-conversation:view-rendered-markdown`
- `assistant-conversation:respond-to-request`
- `assistant-conversation:rename`

Default keymaps:

- `ctrl+alt+a`: start a new conversation
- `ctrl+enter` / `ctrl+return`: send prompt
- `ctrl+m`: select model
- `ctrl+alt+u`: insert a file or directory path into the prompt
- `ctrl+shift+u`: insert a project file path into the prompt
- `shift+tab`: cycle collaboration mode
- `escape`: cancel the active conversation request
- `ctrl+alt+enter` / `ctrl+alt+return`: respond to a pending request
- `ctrl+backspace`: clear prompt

The prompt view also exposes file buttons above the prompt editor:

- `D`: choose any file or directory through `core:open-file`
- `L`: choose a project file through `core:find-file`

Inserted project paths are shortened to project-relative paths when possible.
Directory insertions include a trailing path separator so agents can distinguish
them from files.

## Main Files

- `init.lua`: plugin config, commands, keymaps, agent/backend registration
- `agent.lua`: shared provider behavior, payloads, tool schemas, compaction
- `conversation.lua`: messages, context, sessions, memories, markdown export
- `promptview.lua`: Widget-based assistant UI
- `tools.lua`: tool facade and registration
- `tool/`: individual tool implementations
- `tool_router.lua`: mode-specific tool selection and permission routing
- `backend/`: HTTP, CLI, app-server, and ACP backends
- `agent/`: provider adapters
- `tests/`: Pragtical test suite
- `live_tests/`: manual/live provider conversation checks

## Tests

Run the full plugin test suite from this directory with:

```sh
SDL_VIDEO_DRIVER=dummy pragtical test tests
```

Focused suites used often during tool/backend work:

```sh
SDL_VIDEO_DRIVER=dummy pragtical test tests/tools.lua
SDL_VIDEO_DRIVER=dummy pragtical test tests/agent.lua
SDL_VIDEO_DRIVER=dummy pragtical test tests/backend_http.lua
SDL_VIDEO_DRIVER=dummy pragtical test tests/backend_acp.lua
SDL_VIDEO_DRIVER=dummy pragtical test tests/promptview.lua
```

Live conversation tests are intentionally provider-dependent. Also they should
be ran without setting the SDL_VIDEO_DRIVER=dummy environment variable.
