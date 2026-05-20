local test = require "core.test"
dofile("tests/helper.inc")
local ModelDialog = require "plugins.assistant.ui.modeldialog"

test.describe("assistant model dialog", function()
  test.it("selects the current model", function()
    local dialog = ModelDialog({ "model-a", "model-b" }, "model-b", "medium")

    test.equal(dialog:get_selected_model(), "model-b")
    test.equal(dialog:get_selected_reasoning_effort(), "medium")
  end)

  test.it("submits the selected model", function()
    local dialog = ModelDialog({ "model-a", "model-b" }, "model-a", "low")
    local selected
    local selected_reasoning
    dialog.on_submit = function(_, model, reasoning_effort)
      selected = model
      selected_reasoning = reasoning_effort
    end
    dialog.list:set_selected(2)
    dialog.reasoning_select:set_selected(4)
    dialog:submit()

    test.equal(selected, "model-b")
    test.equal(selected_reasoning, "high")
  end)
end)
