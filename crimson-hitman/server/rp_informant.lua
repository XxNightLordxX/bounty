--- The informant as a person (Config.Roleplay.InformantNpc, README
--- "Roleplay features"). Off as shipped, and off it changes nothing.
---
--- On, every informant purchase (the target's look-up, the placer's
--- look-up and the hitman's location tip) is sold only to a buyer standing
--- within Radius of the informant NPC, wherever it stands now: its own list
--- of places, model and hours, through the same rotation as the broker
--- (server/rp_places.lua). The distance is read on the server from the
--- buyer's ped. Anywhere else the purchase is refused with 'Find the
--- informant first.' before the purchase is looked at, so nothing is
--- charged and no look-up is spent.

local Util = CrimsonBoot.requireShared('util')
local Places = CrimsonBoot.require('server.rp_places')

local Informant = {}

local deps

function Informant.init(d)
    deps = d
end

function Informant.on()
    return Places.on('InformantNpc')
end

--- The purchases the NPC stands in front of, and the informant feature each
--- belongs to: one switched off is refused by its own handler, as before.
Informant.PURCHASES = {
    informant = 'Informant', placerInformant = 'PlacerInformant', locationTip = 'LocationTip',
}

---@return string|nil err
function Informant.gate(name, actor)
    local section = Informant.PURCHASES[name]
    if not section or not Informant.on() then return nil end
    if not Util.informantAnyOn(section) then return nil end
    if Places.near('informant', actor.source) then return nil end
    deps.audit.rejected('informant_not_found', actor.cid, nil, { request = name })
    return CH.ERR.FIND_INFORMANT
end

Informant.RULES = {
    Enabled = { kind = 'switch', default = false },
    Radius = { kind = 'number', min = 1, max = 100, default = 5.0 },
    Locations = { kind = 'points', default = {} },
    RotateHours = { kind = 'number', min = 1, max = 168, integer = true, default = 3 },
    Model = { kind = 'text', default = 'a_m_y_hipster_01' },
    Scenario = { kind = 'text', default = 'WORLD_HUMAN_LEANING' },
    Blip = { kind = 'switch', default = false },
}

---@param warn string[]
function Informant.validate(warn)
    Places.checkBlock('InformantNpc', Informant.RULES, warn)
    -- The broker's and informant's places set from the panel (rp_places.lua).
    Places.checkBlock('NpcPlaces', { Enabled = { kind = 'switch', default = false } }, warn)
end

return Informant
