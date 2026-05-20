rawset(_G, "ASSISTANT_LIVE_HTTP_AGENT", "llamacpp")
local source = debug.getinfo(1, "S").source
local dir = source and source:sub(1, 1) == "@" and source:match("^@(.+)/[^/]+$") or "live_tests"
dofile(dir .. "/local_http_conversation_live.lua")
