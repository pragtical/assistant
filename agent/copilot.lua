local Acp = require "plugins.assistant.agent.acp"

---ACP agent adapter for GitHub Copilot.
---@class assistant.agent.Copilot : assistant.agent.Acp
local Copilot = Acp:extend()

---Create a new instance.
---@param options table?
function Copilot:new(options)
  options = options or {}
  options.name = options.name or "copilot"
  options.display_name = options.display_name or "GitHub Copilot"
  options.command = options.command or { "copilot", "--acp", "--stdio" }
  options.transport = options.transport or "stdio"
  Acp.new(self, options)
end

---Handle configure provider.
---@param conf table
function Copilot:configure_provider(conf)
  if conf.command and conf.command ~= "" then
    self.command = { conf.command, "--acp", "--stdio" }
  else
    Acp.configure_provider(self, conf)
  end
end

return Copilot
