CrimsonBoot.define('server.adapters.garage.onesync', function() --[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║             crimson-hitman - server/adapters/garage/onesync.lua           ║
    ║        garage adapter: server-made vehicles through OneSync natives       ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- The organisation's garage (server/org/extras3.lua) makes its vehicles
--- itself, on the server, as body disposal does (server/disposal.lua): the
--- FiveM server natives CreateVehicleServerSetter, SetEntityOrphanMode,
--- SetEntityRoutingBucket, SetVehicleNumberPlateText, SetVehicleDoorsLocked,
--- DoesEntityExist, GetEntityCoords and DeleteEntity (docs.fivem.net/natives,
--- server side). No garage resource's export is guessed: none of their source
--- was read. A vehicle made here is nobody's own car (no row in any garage's
--- table), so nothing can store or sell it. It answers wherever the artifact
--- has CreateVehicleServerSetter (OneSync); 'none' turns the garage off.
--- A server with its own garage script writes its own adapter beside this one
--- (docs/dev/adapters.md).

local Vehicles = CrimsonBoot.require('server.lib.vehicles')

local Adapter = { resource = 'onesync', label = 'OneSync server vehicles' }

function Adapter.detect() return type(CreateVehicleServerSetter) == 'function' end

---@return integer entity
function Adapter.spawn(model, at)
    -- As the model's own type (vehicles.meta): a bike made as an automobile
    -- is broken for everybody near it.
    return CreateVehicleServerSetter(GetHashKey(model), Vehicles.typeOf(model), at.x, at.y, at.z, at.h or 0.0)
end

--- Kept by the server whoever is near it (orphan mode 2, KeepEntity), in the
--- member's routing bucket, plated, marked and locked where a keys adapter
--- answers (Config.Integrations.Keys; it gives the keys). Without one it is
--- left unlocked, as body disposal leaves its vehicle (server/disposal.lua):
--- locked, nobody could get into it, and it still counted against
--- GarageMaxOut until GarageKeepMinutes ran out. false then, for the caller.
function Adapter.prepare(vehicle, plate, src)
    if type(SetEntityOrphanMode) == 'function' then SetEntityOrphanMode(vehicle, 2) end
    if src and type(SetEntityRoutingBucket) == 'function' and type(GetPlayerRoutingBucket) == 'function' then
        SetEntityRoutingBucket(vehicle, tonumber(GetPlayerRoutingBucket(src)) or 0)
    end
    SetVehicleNumberPlateText(vehicle, plate)
    Entity(vehicle).state:set('crimsonOrgVehicle', true, true)
    -- Asked here, not at load: the adapters are loaded by the module asked.
    local keys = CrimsonBoot.require('server.adapters.init').get('keys')
    if keys and keys.GiveKeys then
        SetVehicleDoorsLocked(vehicle, 2)
        return true
    end
    SetVehicleDoorsLocked(vehicle, 1)
    return false
end

function Adapter.exists(vehicle)
    return vehicle ~= nil and vehicle ~= 0 and DoesEntityExist(vehicle) and true or false
end

function Adapter.coords(vehicle)
    local c = GetEntityCoords(vehicle)
    return { x = c.x, y = c.y, z = c.z }
end

function Adapter.remove(vehicle) DeleteEntity(vehicle) end

return Adapter
end)
