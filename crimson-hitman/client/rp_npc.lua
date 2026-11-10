--- The roleplay NPCs (Config.Roleplay.Rumours, Config.Roleplay.InformantNpc):
--- the broker and the informant, drawn by this game where the server says
--- each stands now (server/rp_places.lua). Off as shipped, and then nothing
--- here runs but one question to the server at start.
---
--- Each NPC is a local ped (never networked), made only while this player
--- is within DRAW_METRES of it and removed past REMOVE_METRES, so a player
--- across the map costs nothing. One distance check a second while an NPC
--- is near, one every two seconds while every NPC is far, and no thread at
--- all while both are off: the loop ends when the server says there is
--- nothing to draw, and starts again only when it says there is (its answer
--- to the question at start, or after crimson-hitman:rpPlacesChanged). The
--- NPC is scenery: whether a player stands beside it is checked by the
--- server from their ped.

local DRAW_METRES, REMOVE_METRES = 80.0, 100.0
local MODEL_WAIT_MS = 5000

--- How often the distance is looked at: once a second while an NPC is
--- within NEAR_METRES (or drawn), so it appears before the player reaches
--- it; every two seconds while every NPC is further off, where nothing can
--- change in that time but the distance (a car at 150 km/h covers about
--- 80 m in two seconds, the margin between NEAR_METRES and DRAW_METRES);
--- With both off there is no loop to wait in (NpcLoop.start).
local NEAR_METRES = 160.0
local NEAR_WAIT_MS, FAR_WAIT_MS = 1000, 2000

--- What the server last said: [npc] = { x, y, z, h, model, scenario, blip,
--- at }, `at` the place as a vector, made once here rather than on every
--- pass of the loop.
local places = {}

--- Whether the distance loop is running. It runs only while there is a
--- place to measure, and ends on the pass that finds none.
local watching = false
local NpcLoop = {}
--- What is drawn now: [npc] = { ped, key }. The blip is CrimsonMarkers'
--- (client/missionsteps.lua), keyed 'npc:<npc>'; it stays over a logout.
local drawn = {}

local asked = 0

local function keyOf(p)
    return ('%.1f:%.1f:%.1f:%s:%s'):format(p.x, p.y, p.z, p.model, p.scenario)
end

local function removePed(npc)
    local d = drawn[npc]
    if d then
        CrimsonNpc.remove(d.ped)
        d.ped = nil
    end
end

local function removeBlip(npc)
    CrimsonMarkers.remove('npc:' .. npc)
end

local function removeAll()
    for npc in pairs(drawn) do
        removePed(npc)
        removeBlip(npc)
    end
    drawn = {}
end

--- The peds only, for a logout: the blips are the map's, and the places
--- stay, so the next character draws them again as it comes near.
local function removePeds()
    for npc in pairs(drawn) do removePed(npc) end
end

local function spawn(npc, p)
    local hash = CrimsonNpc.loadModel(p.model, MODEL_WAIT_MS)
    if not hash then return end
    -- The model load waits: the server may have moved or taken this NPC
    -- away meanwhile (apply), or it may have been drawn already. Made only
    -- for the place it is still drawn at, so no ped is left unowned.
    local d = drawn[npc]
    if not d or d.ped or d.key ~= keyOf(p) then
        SetModelAsNoLongerNeeded(hash)
        return
    end
    d.ped = CrimsonNpc.spawn(hash, p.x, p.y, p.z, p.h, { ragdoll = false, scenario = p.scenario })
end

local function blipFor(npc, p)
    removeBlip(npc)
    if not p.blip then return end
    CrimsonMarkers.set('npc:' .. npc, { kind = npc, x = p.x, y = p.y, z = p.z })
end

--- Make what is drawn match what the server said.
local function apply(data)
    places = {}
    for _, npc in ipairs({ 'broker', 'informant' }) do
        local p = type(data) == 'table' and data[npc]
        if type(p) == 'table' and tonumber(p.x) and tonumber(p.y) and tonumber(p.z) then
            local x, y, z = p.x + 0.0, p.y + 0.0, p.z + 0.0
            places[npc] = { x = x, y = y, z = z, h = (tonumber(p.h) or 0) + 0.0,
                model = tostring(p.model or ''), scenario = tostring(p.scenario or ''), blip = p.blip == true,
                at = vector3(x, y, z) }
        end
    end
    for npc in pairs(drawn) do
        if not places[npc] or drawn[npc].key ~= keyOf(places[npc]) then
            removePed(npc)
            removeBlip(npc)
            drawn[npc] = nil
        end
    end
    for npc, p in pairs(places) do
        if not drawn[npc] then
            drawn[npc] = { key = keyOf(p) }
            blipFor(npc, p)
        end
    end
    if next(places) ~= nil then NpcLoop.start() end
end

--- Ask the server where they stand, through the app's gate. Replies are
--- told apart from the app's own by the event name; this file's request
--- ids are negative, so they never meet the app's.
local function ask()
    asked = asked + 1
    TriggerServerEvent('crimson-hitman:rpPlaces', { __rid = -asked })
end

RegisterNetEvent('crimson-hitman:result', function(result)
    if type(result) ~= 'table' or result.event ~= 'rpPlaces' then return end
    -- Not answered (the server still starting, a slow-down): asked again
    -- in a minute, once per refusal.
    if not result.ok then return SetTimeout(60000, ask) end
    apply(result.data)
end)

-- An NPC moved, or staff changed one: ask again.
RegisterNetEvent('crimson-hitman:rpPlacesChanged', function()
    ask()
end)

--- One pass: draw what came near, remove what went far. Returns whether
--- anything is near enough to look again in a second. The ped and its
--- coordinates are read once a pass, and nothing is made in it but the
--- difference vectors: each place carries its own (apply).
local function pass()
    local me = GetEntityCoords(PlayerPedId())
    local inCity = CrimsonNpc.loggedIn()
    local near = false
    for npc, p in pairs(places) do
        local d = drawn[npc]
        local metres = #(me - p.at)
        if d and not d.ped and inCity and metres < DRAW_METRES then
            spawn(npc, p)
        elseif d and d.ped and (metres > REMOVE_METRES or not inCity) then
            removePed(npc)
        end
        if metres < NEAR_METRES or (d and d.ped) then near = true end
    end
    return near
end

--- Start the distance loop, unless it is running. It ends on the pass that
--- finds nothing placed (both NPCs off, or every one taken away), and the
--- next answer that places one starts it again (apply).
function NpcLoop.start()
    if watching then return end
    watching = true
    CreateThread(function()
        while next(places) ~= nil do
            -- One pass in a pcall: a native or a model that raises costs this
            -- pass, never the loop (and with it every NPC for the session).
            local ok, near = pcall(pass)
            if not ok and CrimsonLog then CrimsonLog.debug(('roleplay NPCs: %s'):format(tostring(near))) end
            Wait((near or not ok) and NEAR_WAIT_MS or FAR_WAIT_MS)
        end
        watching = false
    end)
end

--- Whether the loop is running, for the tests.
function NpcLoop.running()
    return watching
end

-- The one question at start. Nothing loops until the answer places an NPC.
CreateThread(function()
    Wait(5000)
    ask()
end)

-- Another character, or none: the peds go, and come back as the next one
-- comes near.
AddEventHandler('QBCore:Client:OnPlayerUnload', removePeds)
AddEventHandler('qbx_core:client:playerLoggedOut', removePeds)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then removeAll() end
end)

return NpcLoop
