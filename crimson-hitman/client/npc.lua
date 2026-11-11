--- Scenery peds (CrimsonNpc): the one copy of making and removing a local
--- NPC, of "is ox_target up" and of "is a
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
    return CrimsonIntegrations.has('target')
end

--- The target adapter answering now (client/adapters/target/,
--- Config.Integrations.Target), or nil. Its calls go inside pcall.
---@return table|nil
function CrimsonNpc.target()
    return CrimsonIntegrations.get('target')
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

-- ============================================================================
--                              THE DISTANCE LOOP
-- ============================================================================
-- One loop for every file that draws NPCs (client/rp_npc.lua's broker and
-- informant, client/org.lua's organisation spots): a pass a second while
-- one of them says something is near or drawn, every two seconds while all
-- are far, and no thread at all while none has an NPC placed. Each was a
-- loop of its own, so a member near both ran two. Nothing is made per pass
-- here; each owner's pass reads the ped's coordinates once.

local NEAR_WAIT_MS, FAR_WAIT_MS = 1000, 2000

--- The owners watching: [name] = { pass = fun(): boolean near, active = fun(): boolean }
local Watchers = {}
local looping = false

local function loop()
    while true do
        local near = false
        for name, w in pairs(Watchers) do
            if not w.active() then
                Watchers[name] = nil
            else
                -- One pass in a pcall: a native or a model that raises costs
                -- this pass, never the loop (and with it every NPC).
                local ok, isNear = pcall(w.pass)
                if not ok and CrimsonLog then
                    CrimsonLog.debug(('NPCs (%s): %s'):format(name, tostring(isNear)))
                end
                if isNear or not ok then near = true end
            end
        end
        if next(Watchers) == nil then break end
        Wait(near and NEAR_WAIT_MS or FAR_WAIT_MS)
    end
    looping = false
end

--- Watch an owner's NPCs with the one distance loop, started if it is not
--- running. `pass` draws what came near and removes what went far, and says
--- whether anything is near; `active` says whether the owner has an NPC
--- placed, and the owner leaves the loop on the first pass it has none.
---@param name string
---@param pass fun(): boolean
---@param active fun(): boolean
function CrimsonNpc.watch(name, pass, active)
    Watchers[name] = { pass = pass, active = active }
    if looping then return end
    looping = true
    CreateThread(loop)
end

--- Whether the loop is watching an owner's NPCs.
---@param name string
---@return boolean
function CrimsonNpc.watching(name)
    return looping and Watchers[name] ~= nil
end

return CrimsonNpc
