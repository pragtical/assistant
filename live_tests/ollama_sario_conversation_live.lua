rawset(_G, "ASSISTANT_LIVE_HTTP_AGENT", "ollama")
rawset(_G, "ASSISTANT_LIVE_HTTP_SCENARIO", "sario")
rawset(_G, "ASSISTANT_LIVE_HTTP_PROJECT_SUBDIR", "sario")
rawset(_G, "ASSISTANT_LIVE_HTTP_PLAN_KEYWORDS", { "sario", "side scroller", "platform" })
rawset(_G, "ASSISTANT_LIVE_HTTP_PLAN_PROMPT", [[Make a side scroller game clone of super mario bros game called Sario with a 
level similar to the first Super Marios Bros level 1 of NES, the game should be in C and using SDL2]])
rawset(_G, "ASSISTANT_LIVE_HTTP_IMPLEMENT_PROMPT", "Implement the plan.")
rawset(_G, "ASSISTANT_LIVE_HTTP_FOLLOWUP_PROMPT", "Compile it and run or describe the most relevant verification. If it fails, inspect the errors and fix them. Keep the final response concise.")
rawset(_G, "ASSISTANT_LIVE_HTTP_REQUIRED_FILES", {
  "Makefile",
  "src/main.c"
})

local source = debug.getinfo(1, "S").source
local dir = source and source:sub(1, 1) == "@" and source:match("^@(.+)/[^/]+$") or "live_tests"
dofile(dir .. "/local_http_conversation_live.lua")
