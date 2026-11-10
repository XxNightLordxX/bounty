--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                  crimson-hitman - client/missionsteps.lua                 ║
    ║       The map markers for each step of a contract, drawn in one place     ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- One marker system for every step (server/missionsteps.lua decides who is
--- sent which): the informant tip's circle and the meeting point (both set
--- from client/main.lua, from their own events), the kill to verify, the
--- handover circle, a guard's pin, and body disposal's body, vehicle spawn
--- and drop-off (crimson-hitman:client:StepMarker / StepMarkerClear). Each is
--- a fixed point the server sent this game alone; the page is never sent
--- one. A body or drop-off marker carries an ox_target sphere at the spot,
--- whose option asks the server, which checks where it sees the player and
--- the vehicle. No thread, no loop: blips and zones are made when a marker
--- arrives and removed when it goes, at a logout and at the resource's stop.
--- The places that are not steps of a contract keep their own blips: the
--- broker and informant NPCs (client/rp_npc.lua) and the organisation's
--- spots (client/org.lua).

CrimsonMarkers = {}

--- How each kind looks. Sprites and colours are GTA's blip ids (check them in
--- game; docs/in-game-checklist.md). `area` adds a see-through circle of the
--- marker's radius under it; `shortRange` shows it only near the player.
local STYLES = {
    tip              = { sprite = 1,   colour = 1,  scale = 0.8, name = 'Informant tip', area = true, alpha = 90 },
    meeting          = { sprite = 162, colour = 5,  scale = 0.9, name = 'Meeting point' },
    kill             = { sprite = 303, colour = 1,  scale = 0.9, name = 'Kill to verify' },
    handover         = { sprite = 161, colour = 17, scale = 0.8, name = 'Handover', area = true, alpha = 80 },
    guard            = { sprite = 487, colour = 3,  scale = 0.9, name = 'Protection meeting pin' },
    disposal_body    = { sprite = 310, colour = 40, scale = 0.9, name = 'Body to collect' },
    disposal_vehicle = { sprite = 67,  colour = 40, scale = 0.9, name = 'Disposal vehicle' },
    disposal_drop    = { sprite = 274, colour = 40, scale = 1.0, name = 'Body drop-off' },
}
CrimsonMarkers.STYLES = STYLES

--- The kinds the server's step event may draw: never the tip or meeting
--- point (their own events) or the places (their own modules).
local SENT_KINDS = {
    kill = true, handover = true, guard = true,
    disposal_body = true, disposal_vehicle = true, disposal_drop = true,
}

local ACTIONS = {
    load = { label = 'Load the body', icon = 'fa-solid fa-truck-ramp-box' },
    drop = { label = 'Drop off the body', icon = 'fa-solid fa-dolly' },
}

--- What is drawn: [key] = { x, y, z, blips = { handle, ... }, zone, gen }.
local Drawn = {}
local Gen = 0

local MAX_KEY = 64

local function RemoveZone(zone)
    if zone and CrimsonNpc.targetUp() then pcall(function() exports.ox_target:removeZone(zone, true) end) end
end

--- Take one marker off the map.
---@param key string
function CrimsonMarkers.remove(key)
    local entry = Drawn[key]
    if not entry then return end
    Drawn[key] = nil
    for _, blip in ipairs(entry.blips) do
        if blip and DoesBlipExist(blip) then RemoveBlip(blip) end
    end
    RemoveZone(entry.zone)
end

--- Take off every marker whose key starts with this.
---@param prefix string
function CrimsonMarkers.removePrefix(prefix)
    local keys = {}
    for key in pairs(Drawn) do
        if key:sub(1, #prefix) == prefix then keys[#keys + 1] = key end
    end
    for i = 1, #keys do CrimsonMarkers.remove(keys[i]) end
end

--- Every marker off: a logout, another character, the resource's stop.
function CrimsonMarkers.clearAll()
    local keys = {}
    for key in pairs(Drawn) do keys[#keys + 1] = key end
    for i = 1, #keys do CrimsonMarkers.remove(keys[i]) end
end

--- Where a marker is, for Set GPS: { x, y }, or nil.
---@param key string
function CrimsonMarkers.get(key)
    local entry = Drawn[key]
    if not entry then return nil end
    return { x = entry.x, y = entry.y }
end

--- How many are drawn, for the tests.
function CrimsonMarkers.count()
    local n = 0
    for _ in pairs(Drawn) do n = n + 1 end
    return n
end

local function Named(blip, name)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(name)
    EndTextCommandSetBlipName(blip)
end

local function AddZone(entry, spec)
    local action = ACTIONS[spec.act]
    if not action or not entry.z or not CrimsonNpc.targetUp() or type(spec.ref) ~= 'string' then return end
    local ref, act = spec.ref, spec.act
    local ok, zone = pcall(function()
        return exports.ox_target:addSphereZone({
            coords = vector3(entry.x, entry.y, entry.z), radius = 2.5, debug = false,
            options = { {
                name = 'crimson_disposal_' .. act, label = action.label, icon = action.icon, distance = 3.0,
                onSelect = function()
                    TriggerServerEvent('crimson-hitman:disposalAct', { action = act, id = ref })
                end,
            } },
        })
    end)
    if ok and zone then entry.zone = zone end
end

--- Draw (or move) one marker.
---@param key string
---@param spec table { kind, x, y, z?, radius?, secondsLeft?, name?, act?, ref? }
---@return boolean drawn
function CrimsonMarkers.set(key, spec)
    if type(key) ~= 'string' or #key == 0 or #key > MAX_KEY or type(spec) ~= 'table' then return false end
    local style = STYLES[spec.kind]
    local x, y = CrimsonGeo.finite(spec.x), CrimsonGeo.finite(spec.y)
    if not style or not x or not y then return false end
    local radius = CrimsonGeo.finite(spec.radius)
    local seconds = CrimsonGeo.finite(spec.secondsLeft)
    if style.area and (not radius or radius <= 0) then return false end
    if seconds ~= nil and seconds <= 0 then return false end
    CrimsonMarkers.remove(key)

    local blips = {}
    if style.area then
        local area = AddBlipForRadius(x + 0.0, y + 0.0, 0.0, math.min(radius, 2000.0) + 0.0)
        SetBlipColour(area, style.colour)
        SetBlipAlpha(area, style.alpha or 90)
        blips[#blips + 1] = area
    end
    local centre = AddBlipForCoord(x + 0.0, y + 0.0, 0.0)
    SetBlipSprite(centre, style.sprite)
    SetBlipColour(centre, style.colour)
    SetBlipScale(centre, style.scale)
    SetBlipAsShortRange(centre, style.shortRange == true)
    local name = type(spec.name) == 'string' and spec.name ~= '' and spec.name:sub(1, 64) or style.name or key
    Named(centre, name)
    blips[#blips + 1] = centre

    Gen = Gen + 1
    local entry = { x = x, y = y, z = CrimsonGeo.finite(spec.z), blips = blips, gen = Gen }
    Drawn[key] = entry
    AddZone(entry, spec)
    -- Off by itself when its time runs out, should the server's word not
    -- arrive: only this one, not a newer marker under the same key.
    if seconds then
        SetTimeout(math.floor(seconds * 1000), function()
            if Drawn[key] == entry then CrimsonMarkers.remove(key) end
        end)
    end
    return true
end

-- ============================================================================
--                              NET EVENTS
-- ============================================================================

--- A step marker from the server, to this game alone.
RegisterNetEvent('crimson-hitman:client:StepMarker', function(data)
    if type(data) ~= 'table' or type(data.key) ~= 'string' or not data.key:match('^[%w_:%-]+$') then return end
    if not SENT_KINDS[data.kind] then return end
    local spec = { kind = data.kind, x = data.x, y = data.y, z = data.z, radius = data.radius,
        act = (data.act == 'load' or data.act == 'drop') and data.act or nil,
        ref = type(data.ref) == 'string' and data.ref:match('^[%w_%-]+$') and data.ref:sub(1, 32) or nil }
    CrimsonMarkers.set(data.key, spec)
end)

RegisterNetEvent('crimson-hitman:client:StepMarkerClear', function(data)
    if type(data) ~= 'table' or type(data.key) ~= 'string' then return end
    CrimsonMarkers.remove(data.key)
end)

-- Another character, or none: their markers are not this one's. The server
-- sends them again when the app asks (MissionSteps.reshow).
AddEventHandler('QBCore:Client:OnPlayerUnload', function() CrimsonMarkers.clearAll() end)
AddEventHandler('qbx_core:client:playerLoggedOut', function() CrimsonMarkers.clearAll() end)
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    CrimsonMarkers.clearAll()
end)

return CrimsonMarkers
