local test = require "core.test"
dofile("tests/helper.inc")
local json = require "core.json"
local jsonutil = require "plugins.assistant.jsonutil"

test.describe("assistant json utilities", function()
  test.it("matches core json encoding for request payloads", function()
    local payload = {
      model = "test",
      stream = false,
      messages = {
        { role = "system", content = "hello" },
        { role = "user", content = "quote \" slash \\" }
      },
      tools = {
        {
          type = "function",
          ["function"] = {
            name = "list",
            parameters = {
              type = "object",
              required = { "directory" },
              properties = {
                directory = { type = "string" }
              }
            }
          }
        }
      }
    }

    test.equal(json.decode(jsonutil.encode(payload)).model, "test")
    test.equal(json.decode(jsonutil.encode(payload)).messages[2].content, "quote \" slash \\")
  end)

  test.it("yields while encoding large tables", function()
    local payload = { messages = {} }
    for i = 1, 300 do
      payload.messages[i] = { role = "user", content = "message " .. i }
    end
    local yields = 0
    local thread = coroutine.create(function()
      return jsonutil.encode(payload, { yield_every = 8 })
    end)
    while coroutine.status(thread) ~= "dead" do
      local ok = coroutine.resume(thread)
      test.equal(ok, true)
      if coroutine.status(thread) ~= "dead" then yields = yields + 1 end
    end
    test.equal(yields > 0, true)
  end)

  test.it("can encode an explicit empty array", function()
    local encoded = jsonutil.encode({
      mcpServers = jsonutil.empty_array
    })
    test.equal(encoded, "{\"mcpServers\":[]}")
  end)

  test.it("core json can encode and decode payloads", function()
    local payload = { messages = {} }
    for i = 1, 120 do
      payload.messages[i] = { role = "user", content = "message " .. i }
    end

    local encoded = json.encode(payload)
    local decoded = json.decode(encoded)
    test.equal(decoded.messages[120].content, "message 120")
  end)
end)
