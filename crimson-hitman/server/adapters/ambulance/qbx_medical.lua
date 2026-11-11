--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║        crimson-hitman - server/adapters/ambulance/qbx_medical.lua         ║
    ║                      ambulance adapter: qbx_medical                       ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- Read from qbx_medical (server/main.lua, client/main.lua): its IsDead and
--- IsLaststand are client exports, and its server says nothing of death,
--- so there is no deathState here. It writes the isdead / inlaststand
--- metadata qbx_core keeps, and that is what the server reads
--- (Identity.deathState). Registered so the client knows a medical
--- resource decides when a player is dead (client/main.lua).

local Adapter = { resource = 'qbx_medical', label = 'qbx_medical' }

return Adapter
