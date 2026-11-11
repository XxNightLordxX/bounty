--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║      crimson-hitman - server/adapters/progression/sc-blackmarket.lua      ║
    ║                    progression adapter: sc-blackmarket                    ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- sc-blackmarket ships escrowed: AddTrust(citizenid, amount) is the call
--- this resource has always made (Config.Record.Progression.Resource, as
--- it was), not read from its source.

local Adapter = { resource = 'sc-blackmarket', label = 'sc-blackmarket' }

function Adapter.AddTrust(...) return exports['sc-blackmarket']:AddTrust(...) end

return Adapter
