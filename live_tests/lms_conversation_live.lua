rawset(_G, "ASSISTANT_LIVE_HTTP_AGENT", "lms")
rawset(_G, "ASSISTANT_LIVE_HTTP_MODEL", "qwen3.6-35b-a3b@q4_k_s")
local source = debug.getinfo(1, "S").source
local dir = source and source:sub(1, 1) == "@" and source:match("^@(.+)/[^/]+$") or "live_tests"
dofile(dir .. "/local_http_conversation_live.lua")
