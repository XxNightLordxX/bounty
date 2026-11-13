CrimsonBoot.define('server.adapters.keys.qbx_vehiclekeys', function() --[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║         crimson-hitman - server/adapters/keys/qbx_vehiclekeys.lua         ║
    ║                   vehicle keys adapter: qbx_vehiclekeys                   ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- qbx_vehiclekeys: GiveKeys(source, vehicle), as qbx_core 1.24 calls it
--- itself (config/server.lua, giveVehicleKeys). Asked for the disposal
--- vehicle (server/disposal.lua) and the organisation garage's vehicles
--- (server/org/extras3.lua, server/adapters/garage/onesync.lua).

local Adapter = { resource = 'qbx_vehiclekeys', label = 'qbx_vehiclekeys' }

function Adapter.GiveKeys(...) return exports.qbx_vehiclekeys:GiveKeys(...) end

return Adapter
end)
