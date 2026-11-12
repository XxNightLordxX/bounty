CrimsonBoot.define('shared.geo', function() --- Crimson Hitman System — positions and distances.
---
--- Loaded on both sides: the server through CrimsonBoot.requireShared, the
--- client from client_scripts as CrimsonGeo. Geo.position reads a player's
--- ped and is for the server only, where the server's own view of where a
--- player stands is the one that counts.

local Geo = {}

--- A number that is finite, or nil: NaN, inf and anything that is not a
--- number (or, unless `numbersOnly`, a numeric string) are nil.
---@param value any
---@param numbersOnly boolean|nil true: a string is never a number here
---@return number|nil
function Geo.finite(value, numbersOnly)
    if numbersOnly then
        if type(value) ~= 'number' then return nil end
    else
        value = tonumber(value)
    end
    if not value or value ~= value or value == math.huge or value == -math.huge then return nil end
    return value
end

--- The game's own vector types. On CfxLua, GetEntityCoords, vector3(),
--- vector4(), vec3() and coordinates sent in an event are one of these, and
--- type() answers 'vector3' (or 'vector2', 'vector4'), never 'table'; older
--- runtimes answer 'userdata'. A check for a table alone refuses every real
--- position (review 84 T1: body disposal never started in game).
local VECTOR = { vector2 = true, vector3 = true, vector4 = true, userdata = true }

--- Whether a value can be read as a point (.x, .y, .z): a table or one of
--- the game's vectors. What its axes hold is the caller's to check.
---@param v any
---@return boolean
function Geo.isPoint(v)
    return type(v) == 'table' or VECTOR[type(v)] == true
end

--- A plain { x, y, z } table (w as well for a vector4) for one of the
--- game's vectors, read once; anything else as it is. For a value about to
--- be stored, encoded or walked as a table, which a vector cannot be.
---@param v any
---@return any
function Geo.plain(v)
    local t = type(v)
    if not VECTOR[t] then return v end
    local ok, out = pcall(function()
        local o = { x = v.x, y = v.y }
        if t ~= 'vector2' then o.z = v.z end
        if t == 'vector4' then o.w = v.w end
        return o
    end)
    return ok and out or nil
end

--- The heading a point carries: .h or .heading on a table, .w on a
--- vector4, nil otherwise. A vector3 has no heading, and is never asked
--- for a field it does not have.
---@param v any
---@return number|nil
function Geo.headingOf(v)
    local t = type(v)
    if t == 'table' then return Geo.finite(v.h ~= nil and v.h or v.heading) end
    if t == 'vector4' then return Geo.finite(v.w) end
    return nil
end

--- Where the server sees a player's ped now, as the game's vector, or nil:
--- no ped (not in the world yet, gone), or a read that raised.
---@param src integer
---@return table|nil coords
function Geo.position(src)
    local ok, coords = pcall(function()
        local ped = GetPlayerPed(src)
        if not ped or ped == 0 then return nil end
        return GetEntityCoords(ped)
    end)
    return ok and coords or nil
end

--- The squared distance between two points ({ x, y, z }, a missing axis 0),
--- math.huge when either is missing. Squared so callers compare against a
--- squared radius and never pay for a square root on a hot tick.
---@param a table|nil
---@param b table|nil
---@return number
function Geo.dist2(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = (a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0), (a.z or 0) - (b.z or 0)
    return dx * dx + dy * dy + dz * dz
end

--- Whether two points are within `metres` of each other (false when either
--- is missing).
---@param a table|nil
---@param b table|nil
---@param metres number
---@return boolean
function Geo.near(a, b, metres)
    local r = tonumber(metres) or 0
    return Geo.dist2(a, b) <= r * r
end

--- The client has no module loader, so its half reaches these through a
--- global, as it does Util (CrimsonUtil).
CrimsonGeo = Geo

return Geo
end)
