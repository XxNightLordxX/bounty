--- Scenery peds and their map blips (CrimsonNpc): the one copy of making,
--- removing and marking a local NPC, of "is ox_target up" and of "is a
--- character loaded".
---
--- Every ped made here is local (never networked), invincible, frozen and
--- deaf to the world, and the model is let go as soon as the ped exists.
--- Model loads are capped, never an endless wait, and a model the game does
--- not have is skipped. Loaded before the files that draw NPCs
--- (client/rp_npc.lua, client/org.lua); client/missionsteps.lua, listed
--- earlier, only asks targetUp once the game is running.

CrimsonNpc = {}

--- Whether a character is loaded. qbx_core sets the bag on load and clears
--- it on unload; between the two (the character screen) nothing is drawn.
--- A game with no bag to read draws as before.
---@return boolean
function CrimsonNpc.loggedIn()
    local state = LocalPlayer and LocalPlayer.state
    if not state then return true end
    return state.isLoggedIn and true or false
end

--- Whether ox_target is started, so a zone or a ped option can be added
--- or removed (every call into it stays inside pcall).
---@return boolean
function CrimsonNpc.targetUp()
    return GetResourceState('ox_target') == 'started'
end

--- Load a model, waiting at most `waitMs`, or nil: not a string, not in
--- the game (with `checkValid`, not a valid model either), or not loaded in
--- time. The caller lets it go (SetModelAsNoLongerNeeded) once used.
---@param model string
---@param waitMs integer
---@param opts table|nil { stepMs = 50, checkValid = true }
---@return integer|nil hash
function CrimsonNpc.loadModel(model, waitMs, opts)
    opts = opts or {}
    local step = opts.stepMs or 50
    local hash = type(model) == 'string' and joaat(model) or nil
    if not hash or not IsModelInCdimage(hash) then return nil end
    if opts.checkValid ~= false and not IsModelValid(hash) then return nil end
    RequestModel(hash)
    local waited = 0
    while not HasModelLoaded(hash) and waited < waitMs do
        Wait(step)
        waited = waited + step
    end
    if not HasModelLoaded(hash) then return nil end
    return hash
end

--- Make a scenery ped from a loaded model, standing at x, y, z (its feet a
--- metre below, as the game places a ped) facing h, and let the model go.
---@param hash integer a loaded model (CrimsonNpc.loadModel)
---@param x number
---@param y number
---@param z number
---@param h number
---@param opts table|nil { scriptHost = false, ragdoll = true, scenario = string|nil }
---@return integer|nil ped
function CrimsonNpc.spawn(hash, x, y, z, h, opts)
    opts = opts or {}
    local ped = CreatePed(4, hash, x, y, z - 1.0, h, false, opts.scriptHost == true)
    SetModelAsNoLongerNeeded(hash)
    if not ped or ped == 0 then return nil end
    SetEntityInvincible(ped, true)
    FreezeEntityPosition(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    if opts.ragdoll == false then SetPedCanRagdoll(ped, false) end
    if opts.scenario and opts.scenario ~= '' then TaskStartScenarioInPlace(ped, opts.scenario, 0, true) end
    return ped
end

--- Delete a ped if it still exists.
---@param ped integer|nil
function CrimsonNpc.remove(ped)
    if ped and DoesEntityExist(ped) then DeleteEntity(ped) end
end

--- A short-range map blip at x, y, z with a sprite, a scale and a name.
---@param x number
---@param y number
---@param z number
---@param sprite integer
---@param scale number
---@param label string
---@return integer blip
function CrimsonNpc.blip(x, y, z, sprite, scale, label)
    local blip = AddBlipForCoord(x, y, z)
    SetBlipSprite(blip, sprite)
    SetBlipScale(blip, scale)
    SetBlipAsShortRange(blip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(label)
    EndTextCommandSetBlipName(blip)
    return blip
end

return CrimsonNpc
