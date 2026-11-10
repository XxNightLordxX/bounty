--- The one way a map marker reaches a player's game (client/missionsteps.lua,
--- CrimsonMarkers): a marker drawn or moved, and one taken off, each sent to
--- that player's game alone, never to everybody and never to the page.
---
--- Every marker the server decides on goes through here: each step of a
--- contract (server/missionsteps.lua), the handover's meeting point
--- (server/meeting.lua) and an informant tip's area (server/locationtip.lua).
--- Who is sent which, and when it comes off, stays each module's rule; this
--- is only the sending. A key names the marker on that game ('tip:<contract>',
--- 'meeting:<contract>', 'kill:<contract>', ...): a second send under the
--- same key moves it.

local Util = CrimsonBoot.requireShared('util')

local Markers = {}

Markers.SET_EVENT = 'crimson-hitman:client:StepMarker'
Markers.CLEAR_EVENT = 'crimson-hitman:client:StepMarkerClear'

--- Draw (or move) one marker on one player's map.
---@param src integer|nil the player's game; nothing is sent without one
---@param key string
---@param spec table { kind, x, y, z?, radius?, secondsLeft?, act?, ref? }
---@return boolean sent
function Markers.show(src, key, spec)
    if not src or type(key) ~= 'string' or type(spec) ~= 'table' then return false end
    local payload = Util.copy(spec)
    payload.key = key
    TriggerClientEvent(Markers.SET_EVENT, src, payload)
    return true
end

--- Take one marker off one player's map.
---@param src integer|nil
---@param key string
---@return boolean sent
function Markers.clear(src, key)
    if not src or type(key) ~= 'string' then return false end
    TriggerClientEvent(Markers.CLEAR_EVENT, src, { key = key })
    return true
end

return Markers
