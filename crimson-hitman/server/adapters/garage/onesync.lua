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

local Adapter = { resource = 'onesync', label = 'OneSync server vehicles' }

function Adapter.detect() return type(CreateVehicleServerSetter) == 'function' end

---@return integer entity
function Adapter.spawn(model, at)
    return CreateVehicleServerSetter(GetHashKey(model), 'automobile', at.x, at.y, at.z, at.h or 0.0)
end

--- Kept by the server whoever is near it (orphan mode 2, KeepEntity), in the
--- member's routing bucket, plated, marked and locked (the keys adapter gives
--- the keys).
function Adapter.prepare(vehicle, plate, src)
    if type(SetEntityOrphanMode) == 'function' then SetEntityOrphanMode(vehicle, 2) end
    if src and type(SetEntityRoutingBucket) == 'function' and type(GetPlayerRoutingBucket) == 'function' then
        SetEntityRoutingBucket(vehicle, tonumber(GetPlayerRoutingBucket(src)) or 0)
    end
    SetVehicleNumberPlateText(vehicle, plate)
    Entity(vehicle).state:set('crimsonOrgVehicle', true, true)
    SetVehicleDoorsLocked(vehicle, 2)
    return true
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
