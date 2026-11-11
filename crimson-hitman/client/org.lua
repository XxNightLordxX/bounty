--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                     crimson-hitman - client/org.lua                       ║
    ║    The hitman organisation's places: ox_target spots and their NPCs       ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- What the server sends this player only (crimson-hitman:orgSpots, from
--- server/org/init.lua): the sign-up spots for everybody, the office,
--- meeting spots, NPCs and places for members. With the organisation off
--- nothing is sent, and nothing here runs: no thread, no zone, no ped.
---
--- Each spot is an ox_target sphere zone (ox_target draws and checks it
--- itself, only when the player looks at it), and its option asks the
--- server, which checks where it sees the player before it answers. An NPC
--- spot's ped is local, made only within DrawMetres and removed past
--- REMOVE_EXTRA metres more, by the one NPC distance loop (client/npc.lua), a pass a second while one is
--- near and every two seconds while all are far, and no loop at all with no
--- NPC spot. Everything goes on a logout and at the resource's stop.

local REMOVE_EXTRA = 20.0
local MODEL_WAIT_MS = 5000

local OrgSpots = {}

--- The spots last sent: [id] = { id, kind, label, at, radius, blip, npc }
local Spots = {}
--- What the server last sent, as sent: drawn again when the target script
--- comes back (it forgets every zone and option at its stop).
local Last = nil
--- What is drawn: zones [id] = ox_target zone id, peds [id]. The blips are
--- CrimsonMarkers' (client/missionsteps.lua), keyed 'org:<id>'.
local Zones, Peds = {}, {}
local Draw, Model = 40.0, 'g_m_m_armboss_01'

local Npc, Geo = CrimsonNpc, CrimsonGeo
local targetUp = Npc.targetUp

local function removePed(id)
    local ped = Peds[id]
    if ped and DoesEntityExist(ped) and targetUp() then
        pcall(function() CrimsonNpc.target().removeLocalEntity(ped) end)
    end
    Npc.remove(ped)
    Peds[id] = nil
end

--- Everything drawn, gone.
local function clearAll()
    for id in pairs(Peds) do removePed(id) end
    for id, zone in pairs(Zones) do
        if targetUp() then pcall(function() CrimsonNpc.target().removeZone(zone, true) end) end
        Zones[id] = nil
    end
    CrimsonMarkers.removePrefix('org:')
end

local function option(spot)
    return {
        name = 'crimson_org_' .. spot.id,
        label = spot.label,
        icon = spot.kind == 'signup' and 'fa-solid fa-clipboard' or 'fa-solid fa-user-secret',
        distance = spot.radius + 1.5,
        onSelect = function() TriggerServerEvent('crimson-hitman:orgUse', spot.id) end,
    }
end

local function addZone(spot)
    if not targetUp() then return end
    local ok, zone = pcall(function()
        return CrimsonNpc.target().addSphereZone({
            coords = spot.at, radius = spot.radius, debug = false, options = { option(spot) },
        })
    end)
    if ok and zone then Zones[spot.id] = zone end
end

local function addBlip(spot)
    CrimsonMarkers.set('org:' .. spot.id, { kind = spot.kind == 'office' and 'org_office' or 'org_spot',
        x = spot.at.x, y = spot.at.y, z = spot.at.z, name = spot.label })
end

local function spawn(spot)
    local hash = Npc.loadModel(Model, MODEL_WAIT_MS, { stepMs = 100, checkValid = false })
    if not hash then return end
    -- The load waits up to MODEL_WAIT_MS: a logout, or a push that moved or
    -- dropped this spot, may have come meanwhile, and a ped made now would
    -- stand there with nothing left to remove it.
    if Spots[spot.id] ~= spot or Peds[spot.id] or not Npc.loggedIn() then
        SetModelAsNoLongerNeeded(hash)
        return
    end
    local ped = Npc.spawn(hash, spot.at.x, spot.at.y, spot.at.z, spot.h or 0.0, { scriptHost = true })
    if not ped then return end
    Peds[spot.id] = ped
    if targetUp() then
        pcall(function() CrimsonNpc.target().addLocalEntity(ped, { option(spot) }) end)
    end
end

--- One pass over the NPC spots: whether one is near enough to look again
--- in a second.
local function pass()
    local me = GetEntityCoords(PlayerPedId())
    local inCity = Npc.loggedIn()
    local near = false
    for id, spot in pairs(Spots) do
        if spot.npc then
            local metres = #(me - spot.at)
            if not Peds[id] and inCity and metres < Draw then
                spawn(spot)
            elseif Peds[id] and (metres > Draw + REMOVE_EXTRA or not inCity) then
                removePed(id)
            end
            if metres < Draw * 2 or Peds[id] then near = true end
        end
    end
    return near
end

local function anyNpc()
    for _, spot in pairs(Spots) do if spot.npc then return true end end
    return false
end

--- The distance loop (CrimsonNpc.watch, shared with the roleplay NPCs),
--- only while there is an NPC spot.
function OrgSpots.start()
    CrimsonNpc.watch('org', pass, anyNpc)
end

--- Whether the NPC loop is running for these spots, for the tests.
function OrgSpots.running() return CrimsonNpc.watching('org') end

--- Take what the server sent, type-checked: it is a server-wide event name.
---@param data table { spots = { { id, kind, label, x, y, z, h, radius, blip } }, draw, model }
function OrgSpots.apply(data)
    clearAll()
    Spots = {}
    if type(data) ~= 'table' or type(data.spots) ~= 'table' then return end
    Draw = math.max(5.0, math.min(200.0, tonumber(data.draw) or 40.0))
    if type(data.model) == 'string' and data.model:match('^[%w_]+$') then Model = data.model end
    for i = 1, math.min(#data.spots, 100) do
        local s = data.spots[i]
        local x, y, z = type(s) == 'table' and Geo.finite(s.x), type(s) == 'table' and Geo.finite(s.y),
            type(s) == 'table' and Geo.finite(s.z)
        if x and y and z and type(s.id) == 'string' and #s.id <= 48 and type(s.kind) == 'string' then
            local spot = {
                id = s.id, kind = s.kind, label = type(s.label) == 'string' and s.label:sub(1, 64) or s.kind,
                at = vector3(x, y, z), h = tonumber(s.h) or 0.0,
                radius = math.max(0.5, math.min(50.0, tonumber(s.radius) or 2.0)),
                npc = s.kind == 'npc',
            }
            Spots[spot.id] = spot
            if not spot.npc then addZone(spot) end
            if s.blip == true then addBlip(spot) end
        end
    end
    if anyNpc() then OrgSpots.start() end
end

RegisterNetEvent('crimson-hitman:orgSpots', function(data)
    Last = data
    OrgSpots.apply(data)
end)

-- Another character, or none: everything goes; the server sends the next
-- character's spots when it loads.
AddEventHandler('QBCore:Client:OnPlayerUnload', function() Last = nil; OrgSpots.apply(nil) end)
AddEventHandler('qbx_core:client:playerLoggedOut', function() Last = nil; OrgSpots.apply(nil) end)

-- The target script (ox_target) restarted, or started after this resource:
-- the zones and ped options it was given are gone with it, so its stop
-- forgets them and its start draws the last spots sent again.
AddEventHandler('onClientResourceStop', function(resource)
    if not CrimsonIntegrations.isResourceOf('target', resource) then return end
    Zones = {}
end)
AddEventHandler('onClientResourceStart', function(resource)
    if not CrimsonIntegrations.isResourceOf('target', resource) or Last == nil then return end
    OrgSpots.apply(Last)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then clearAll() end
end)

return OrgSpots
