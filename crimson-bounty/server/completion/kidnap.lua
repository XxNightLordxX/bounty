--- Kidnapping fulfilment (§7.4, §14.23–§14.25).
---
--- One shared tick drives every armed countdown, so cost scales with the
--- number of deliveries actually in progress rather than with the number of
--- accepted contracts. Positions and states are read server-side; the hunter
--- reports nothing.

local Util = require_shared('util')

local Kidnap = {}

local Storage, Identity, Contracts, Audit, Notify, Ledger

--- [contractId .. ':' .. hunterCid] = countdown
local active = {}
local running = false

function Kidnap.init(deps)
    Storage, Identity, Contracts, Audit, Notify, Ledger =
        deps.storage, deps.identity, deps.contracts, deps.audit, deps.notify, deps.ledger
    active = {}
end

local function key(contractId, hunterCid) return contractId .. ':' .. hunterCid end

--------------------------------------------------------------------------
-- Coercion
--------------------------------------------------------------------------

--- A delivery only counts if the target is visibly under the hunter's
--- control. Walking beside a willing friend is not a kidnapping.
---
--- Any enabled detector satisfies the requirement, so servers with different
--- restraint scripts all have a working path.
---@return boolean coerced
---@return string|nil how
function Kidnap.isCoerced(hunterSource, targetSource)
    if not Config.Kidnap.RequireCoercion then return true, 'not_required' end

    local rules = Config.Kidnap.Coercion or {}

    if rules.handcuffed then
        local target = exports.qbx_core:GetPlayer(targetSource)
        local meta = target and target.PlayerData and target.PlayerData.metadata
        if meta and meta.ishandcuffed then return true, 'handcuffed' end
    end

    if rules.passengerOfHunter then
        local targetVeh = GetVehiclePedIsIn(GetPlayerPed(targetSource))
        local hunterVeh = GetVehiclePedIsIn(GetPlayerPed(hunterSource))
        if targetVeh and targetVeh ~= 0 and targetVeh == hunterVeh then
            return true, 'in_hunter_vehicle'
        end
    end

    -- Optional hook for a server's own rope / ziptie resource.
    local provider = Config.Kidnap.RestraintProvider
    if provider and GetResourceState(provider) == 'started' then
        local ok, restrained = pcall(function()
            return exports[provider]:IsRestrained(targetSource)
        end)
        if ok and restrained then return true, 'restraint_provider' end
    end

    return false
end

--------------------------------------------------------------------------
-- Arming
--------------------------------------------------------------------------

--- Conditions that must hold both to arm a countdown and to keep it running.
---@return boolean ok
---@return string|nil reason
function Kidnap.conditionsMet(contract, hunter, target, creator)
    if not hunter or not target or not creator then return false, 'party_offline' end

    -- The target must be alive and conscious for the entire delivery.
    -- Delivering a corpse is not a kidnapping (§7.4).
    if Config.Kidnap.RequireConscious
        and not Identity.isAliveAndConscious(target.source) then
        return false, 'target_not_conscious'
    end

    local coerced = Kidnap.isCoerced(hunter.source, target.source)
    if not coerced then return false, 'not_coerced' end

    local radius = Config.Kidnap.Radius
    local r2 = radius * radius
    local hunterCoords = GetEntityCoords(GetPlayerPed(hunter.source))
    local targetCoords = GetEntityCoords(GetPlayerPed(target.source))
    local creatorCoords = GetEntityCoords(GetPlayerPed(creator.source))

    if Util.dist2(hunterCoords, targetCoords) > r2 then return false, 'target_too_far' end
    if Util.dist2(hunterCoords, creatorCoords) > r2 then return false, 'creator_too_far' end
    if Util.dist2(targetCoords, creatorCoords) > r2 then return false, 'creator_too_far' end

    return true
end

--- Try to arm a countdown for a hunter delivering to the creator.
---@return boolean armed
---@return string|nil err
function Kidnap.arm(contractId, hunterCid)
    contractId = Util.toId(contractId)
    if not contractId then return false, CB.ERR.INVALID_INPUT end
    if active[key(contractId, hunterCid)] then return true end

    local count = 0
    for _ in pairs(active) do count = count + 1 end
    if count >= Config.Kidnap.MaxConcurrentCountdowns then
        -- Refuse to arm rather than shedding one already in progress: a
        -- delivery halfway through is worth more than a new one.
        return false, CB.ERR.LIMIT_REACHED
    end

    local contract = Storage.readContract(contractId)
    if not contract or contract.state ~= CB.STATE.ACCEPTED then return false, CB.ERR.BAD_STATE end

    local hunter = Storage.readHunter(contractId, hunterCid)
    if not hunter or hunter.state ~= 'active' then return false, CB.ERR.NOT_PARTICIPANT end

    local hunterActor  = Identity.byCitizenId(hunterCid)
    local targetActor  = Identity.byCitizenId(contract.target_cid)
    local creatorActor = Identity.byCitizenId(contract.creator_cid)

    local ok, reason = Kidnap.conditionsMet(contract, hunterActor, targetActor, creatorActor)
    if not ok then return false, reason end

    -- Immunity is checked here, not only at the end. The claim would be
    -- refused either way, and finding out after thirty seconds of holding
    -- someone is a waste of the hunter's time.
    if targetActor and Contracts.isImmune(targetActor) then
        return false, 'target_protected'
    end

    active[key(contractId, hunterCid)] = {
        contractId = contractId,
        hunterCid  = hunterCid,
        elapsedMs  = 0,
        graceUsedMs = 0,
        lastTick   = GetGameTimer(),
        startedAt  = GetGameTimer(),
    }

    Audit.action('kidnap_armed', hunterCid, contractId, {})
    Kidnap.start()
    return true
end

function Kidnap.cancel(contractId, hunterCid, reason)
    local k = key(contractId, hunterCid)
    if not active[k] then return false end
    active[k] = nil
    Audit.action('kidnap_cancelled', hunterCid, contractId, { reason = reason })
    return true
end

--------------------------------------------------------------------------
-- The shared tick
--------------------------------------------------------------------------

--- Advance every armed countdown by one interval. Exposed directly so the
--- test suite can drive it without a thread.
---@param deltaMs integer
---@return table completions list of { contractId, hunterCid }
function Kidnap.tick(deltaMs)
    local completions = {}

    for k, state in pairs(active) do
        local contract = Storage.readContract(state.contractId)
        if not contract or contract.state ~= CB.STATE.ACCEPTED then
            active[k] = nil
        else
            local hunterActor  = Identity.byCitizenId(state.hunterCid)
            local targetActor  = Identity.byCitizenId(contract.target_cid)
            local creatorActor = Identity.byCitizenId(contract.creator_cid)

            local ok, reason = Kidnap.conditionsMet(contract, hunterActor, targetActor, creatorActor)

            if ok then
                state.elapsedMs = state.elapsedMs + deltaMs
                state.breaking = nil

                if state.elapsedMs >= (Config.Kidnap.CountdownSeconds * 1000) then
                    active[k] = nil
                    completions[#completions + 1] = {
                        contractId = state.contractId,
                        hunterCid  = state.hunterCid,
                    }
                end
            else
                -- One grace budget for the whole countdown, not per break:
                -- otherwise a hunter could dip in and out indefinitely.
                state.graceUsedMs = state.graceUsedMs + deltaMs
                state.breaking = reason

                if state.graceUsedMs > Config.Kidnap.MaxTotalGraceMs then
                    active[k] = nil
                    Audit.action('kidnap_failed', state.hunterCid, state.contractId, { reason = reason })
                end
            end
        end
    end

    for i = 1, #completions do
        local done = completions[i]
        local ok, err, result = Contracts.claimSlot(done.contractId, done.hunterCid, CB.FULFILMENT.KIDNAPPING)
        if ok then
            local contract = Storage.readContract(done.contractId)
            Ledger.record(contract, done.hunterCid, nil, CB.FULFILMENT.KIDNAPPING, result)
            Notify.contractCompleted(contract, done.hunterCid, nil)
            Audit.financial('kidnap_completed', done.hunterCid, done.contractId, { slot = result.slot })
            done.result = result
        else
            done.error = err
        end
    end

    return completions
end

--- Progress for the app's countdown display.
function Kidnap.progress(contractId, hunterCid)
    local state = active[key(contractId, hunterCid)]
    if not state then return nil end
    return {
        elapsed   = math.floor(state.elapsedMs / 1000),
        required  = Config.Kidnap.CountdownSeconds,
        graceLeft = math.max(0, Config.Kidnap.MaxTotalGraceMs - state.graceUsedMs),
        -- The budget, so the app can show how much of it is gone rather
        -- than a bare number of milliseconds with nothing to compare it to.
        graceTotal = Config.Kidnap.MaxTotalGraceMs,
        breaking  = state.breaking,
    }
end

function Kidnap.activeCount()
    local n = 0
    for _ in pairs(active) do n = n + 1 end
    return n
end

function Kidnap.clearPlayer(cid)
    for k, state in pairs(active) do
        if state.hunterCid == cid then active[k] = nil end
    end
end

--- Start the shared thread. Idempotent: only one ever runs.
function Kidnap.start()
    if running then return end
    running = true
    CreateThread(function()
        while true do
            Wait(Config.Kidnap.TickMs)
            if Kidnap.activeCount() == 0 then
                running = false
                return
            end
            Kidnap.tick(Config.Kidnap.TickMs)
        end
    end)
end

return Kidnap
