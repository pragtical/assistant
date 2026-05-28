local test = require "core.test"
dofile("tests/helper.inc")
local stream_state = require "plugins.assistant.stream_state"

test.describe("assistant stream state", function()
  test.it("detects proposed plans split across deltas", function()
    local state = stream_state.PlanModeStreamState:new()

    test.equal(state:update("<proposed_"), false)
    test.equal(state:update("plan>\n# Plan"), false)
    test.equal(state:has_started(), true)
    test.equal(state:update("\nDo it later.\n</proposed_plan> trailing"), true)

    test.equal(state:is_complete(), true)
    test.equal(state:content():find("Do it later.", 1, true) ~= nil, true)
    test.equal(state:completed_text():sub(1, #"<proposed_plan>"), "<proposed_plan>")
    test.equal(state:completed_text():find("trailing", 1, true), nil)
  end)

  test.it("ignores inline mentions before the proposed plan block", function()
    local state = stream_state.PlanModeStreamState:new()

    test.equal(state:update("I will return a `<proposed_plan>` block.\n\n"), false)
    test.equal(state:has_started(), false)
    test.equal(state:update("<proposed_plan>\n# Plan\n</proposed_plan>"), true)

    test.equal(state:completed_text(), "<proposed_plan>\n# Plan\n</proposed_plan>")
    test.equal(stream_state.contains_completed_plan("Use `<proposed_plan>` then later."), false)
  end)

  test.it("wraps untagged plan text", function()
    test.equal(
      stream_state.wrap_plan("\n# Plan\nDo the work.\n"),
      "<proposed_plan>\n# Plan\nDo the work.\n</proposed_plan>"
    )
  end)

  test.it("detects and strips final plan drafted markers", function()
    local text = "# Plan\n\nDo the work.\n\nPlan Drafted!\n"
    test.equal(stream_state.contains_completed_plan(text), true)
    test.equal(stream_state.has_plan_drafted_marker(text), true)
    test.equal(stream_state.strip_plan_drafted_marker(text), "# Plan\n\nDo the work.")
    test.equal(stream_state.contains_completed_plan("Plan Drafted! then more text"), false)
  end)
end)
