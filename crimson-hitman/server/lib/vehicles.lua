CrimsonBoot.define('server.lib.vehicles', function() --[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                 crimson-hitman - server/lib/vehicles.lua                  ║
    ║          the vehicles.meta type a server-made vehicle is made as          ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- CreateVehicleServerSetter takes the model's type as it is in
--- vehicles.meta (automobile, bike, boat, heli, plane, submarine, trailer,
--- train), and a wrong one makes a vehicle that cannot be driven or seen
--- properly and can crash the games near it. The organisation's garage
--- (server/adapters/garage/onesync.lua) and body disposal (server/disposal.lua)
--- passed 'automobile' for every model, so a bike, boat or helicopter staff
--- approved came out broken.
---
--- The type is found the way qbx_core's own qbx.spawnVehicle finds it
--- (modules/lib.lua, 1.24): the framework's shared vehicle list
--- (exports.qbx_core:GetVehiclesByHash, through the framework adapter), and
--- for a model that list does not have, a short-lived vehicle made with the
--- server's CreateVehicle and read with GetVehicleType, then deleted. Each
--- answer is kept for the model. With neither answering, 'automobile', as
--- before.

local Vehicles = {}

--- The types CreateVehicleServerSetter takes.
local TYPES = {
    automobile = true, bike = true, boat = true, heli = true, plane = true,
    submarine = true, trailer = true, train = true,
}

--- How long the probe vehicle has to appear, in milliseconds.
local PROBE_MS = 2000

local Known = {}  -- { [model] = type }

--- The framework's shared vehicle list: the row for this model, if any.
local function FromFramework(hash)
    -- Asked for here, not at load: the garage adapter that needs this file
    -- is itself loaded by the adapter registry.
    local framework = CrimsonBoot.require('server.adapters.init').get('framework')
    if not framework or type(framework.GetVehiclesByHash) ~= 'function' then return nil end
    local ok, row = pcall(framework.GetVehiclesByHash, hash)
    local kind = ok and type(row) == 'table' and row.type or nil
    return type(kind) == 'string' and TYPES[kind] and kind or nil
end

--- A vehicle made for a moment out of sight, asked its type, and deleted.
local function Probe(hash)
    if type(CreateVehicle) ~= 'function' or type(GetVehicleType) ~= 'function' then return nil end
    local temp
    local ok, kind = pcall(function()
        temp = CreateVehicle(hash, 0.0, 0.0, -200.0, 0.0, true, true)
        local waited = 0
        while (not temp or temp == 0 or not DoesEntityExist(temp)) and waited < PROBE_MS do
            Wait(50)
            waited = waited + 50
        end
        if not temp or temp == 0 or not DoesEntityExist(temp) then return nil end
        return GetVehicleType(temp)
    end)
    if temp and temp ~= 0 then pcall(DeleteEntity, temp) end
    return ok and type(kind) == 'string' and TYPES[kind] and kind or nil
end

--- The vehicles.meta type to make this model as.
---@param model string the model name
---@return string type
function Vehicles.typeOf(model)
    if type(model) ~= 'string' or model == '' then return 'automobile' end
    if Known[model] then return Known[model] end
    local hash = GetHashKey(model)
    local kind = FromFramework(hash) or Probe(hash)
    if kind then Known[model] = kind end
    return kind or 'automobile'
end

return Vehicles
end)
