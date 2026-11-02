--- The roleplay NPCs (Config.Roleplay.Rumours, Config.Roleplay.InformantNpc):
--- the broker and the informant, drawn by this game where the server says
--- each stands now (server/rp_places.lua). Off as shipped, and then nothing
--- here runs but one question to the server at start.
---
--- Each NPC is a local ped (never networked), made only while this player
--- is within DRAW_METRES of it and removed past REMOVE_METRES, so a player
--- across the map costs nothing. One distance check a second while an NPC
--- is on, none at all while both are off. The NPC is scenery: whether a
--- player stands beside it is checked by the server from their ped.

local DRAW_METRES, REMOVE_METRES = 80.0, 100.0
local MODEL_WAIT_MS = 5000

--- What the server last said: [npc] = { x, y, z, h, model, scenario, blip }.
local places = {}
--- What is drawn now: [npc] = { ped, blip, key }.
local drawn = {}

local asked = 0

local function keyOf(p)
    return ('%.1f:%.1f:%.1f:%s:%s'):format(p.x, p.y, p.z, p.model, p.scenario)
end

local function removePed(npc)
    local d = drawn[npc]
    if d and d.ped and DoesEntityExist(d.ped) then DeleteEntity(d.ped) end
    if d then d.ped = nil end
end

local function removeBlip(npc)
    local d = drawn[npc]
    if d and d.blip then RemoveBlip(d.blip) end
    if d then d.blip = nil end
end

local function removeAll()
    for npc in pairs(drawn) do
        removePed(npc)
        removeBlip(npc)
    end
    drawn = {}
end

--- Load a model with a cap on the wait, and give up on one the game has not.
local function loaded(model)
    local hash = type(model) == 'string' and joaat(model) or nil
    if not hash or not IsModelInCdimage(hash) or not IsModelValid(hash) then return nil end
    RequestModel(hash)
    local waited = 0
    while not HasModelLoaded(hash) and waited < MODEL_WAIT_MS do
        Wait(50)
        waited = waited + 50
    end
    if not HasModelLoaded(hash) then return nil end
    return hash
end

local function spawn(npc, p)
    local hash = loaded(p.model)
    if not hash then return end
    -- The model load waits: the server may have moved or taken this NPC
    -- away meanwhile (apply), or it may have been drawn already. Made only
    -- for the place it is still drawn at, so no ped is left unowned.
    local d = drawn[npc]
    if not d or d.ped or d.key ~= keyOf(p) then
        SetModelAsNoLongerNeeded(hash)
        return
    end
    local ped = CreatePed(4, hash, p.x, p.y, p.z - 1.0, p.h, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not ped or ped == 0 then return end
    SetEntityInvincible(ped, true)
    FreezeEntityPosition(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanRagdoll(ped, false)
    if p.scenario ~= '' then TaskStartScenarioInPlace(ped, p.scenario, 0, true) end
    d.ped = ped
end

local function blipFor(npc, p)
    removeBlip(npc)
    if not p.blip then return end
    local blip = AddBlipForCoord(p.x, p.y, p.z)
    SetBlipSprite(blip, npc == 'broker' and 280 or 480)
    SetBlipScale(blip, 0.8)
    SetBlipAsShortRange(blip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(npc == 'broker' and 'Broker' or 'Informant')
    EndTextCommandSetBlipName(blip)
    drawn[npc].blip = blip
end

--- Make what is drawn match what the server said.
local function apply(data)
    places = {}
    for _, npc in ipairs({ 'broker', 'informant' }) do
        local p = type(data) == 'table' and data[npc]
        if type(p) == 'table' and tonumber(p.x) and tonumber(p.y) and tonumber(p.z) then
            places[npc] = { x = p.x + 0.0, y = p.y + 0.0, z = p.z + 0.0, h = (tonumber(p.h) or 0) + 0.0,
                model = tostring(p.model or ''), scenario = tostring(p.scenario or ''), blip = p.blip == true }
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

CreateThread(function()
    Wait(5000)
    ask()
    while true do
        if next(places) == nil then
            Wait(2000)
        else
            -- One pass in a pcall: a native or a model that raises costs this
            -- pass, never the loop (and with it every NPC for the session).
            local ok, err = pcall(function()
                local me = GetEntityCoords(PlayerPedId())
                for npc, p in pairs(places) do
                    local d = drawn[npc]
                    local metres = #(me - vector3(p.x, p.y, p.z))
                    if d and not d.ped and metres < DRAW_METRES then
                        spawn(npc, p)
                    elseif d and d.ped and metres > REMOVE_METRES then
                        removePed(npc)
                    end
                end
            end)
            if not ok and CrimsonLog then CrimsonLog.debug(('roleplay NPCs: %s'):format(tostring(err))) end
            Wait(1000)
        end
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then removeAll() end
end)
