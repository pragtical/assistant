local test = require "core.test"
dofile("tests/helper.inc")
local ModelDialog = require "plugins.assistant.ui.modeldialog"

test.describe("assistant model dialog", function()
  test.it("selects the current model", function()
    local dialog = ModelDialog({ "model-a", "model-b" }, "model-b")

    test.equal(dialog:get_selected_model(), "model-b")
  end)

  test.it("submits the selected model", function()
    local dialog = ModelDialog({ "model-a", "model-b" }, "model-a")
    local selected
    dialog.on_submit = function(_, model)
      selected = model
    end
    dialog.list:set_selected(2)
    dialog:submit()

    test.equal(selected, "model-b")
  end)
end)
