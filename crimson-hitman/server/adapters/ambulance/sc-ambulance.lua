CrimsonBoot.define('server.adapters.ambulance.sc-ambulance', function() --[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║        crimson-hitman - server/adapters/ambulance/sc-ambulance.lua        ║
    ║                      ambulance adapter: sc-ambulance                      ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- sc-ambulance ships escrowed: its server exports IsDead(source) and
--- IsLaststand(source) are the ones this resource has always asked (they
--- were the first of the death-state providers before step 5a), not read from
--- its source. Its defibrillator event (sc-ambulance:server:UseDefib) is
--- listened for in server/bridges.lua.

local Adapter = { resource = 'sc-ambulance', label = 'sc-ambulance' }

--- Dead and in last stand, as two booleans. May raise.
---@param src integer
---@return boolean dead, boolean lastStand
function Adapter.deathState(src)
    local dead = exports['sc-ambulance']:IsDead(src)
    local lastStand = exports['sc-ambulance']:IsLaststand(src)
    return dead, lastStand
end

return Adapter
end)
