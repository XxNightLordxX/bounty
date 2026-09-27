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

--- How each hunter's last handover ended; see Kidnap.outcome below.
--- [contractId .. ':' .. hunterCid] = { outcome, reason, pending, at }
local outcomes = {}

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
    -- An anonymous client who is not in the city gets the answer a client
    -- who is in the city but not here would get (§14.32). 'party_offline'
    -- was the first thing checked, so a hunter pressing Arm anywhere, with
    -- nobody in hand, learned whether the person who paid to stay unnamed
    -- was online right now — as often as they liked, since a refusal costs
    -- nothing. Taken to the creator-distance check instead, so every earlier
    -- reason is still the one it would have been.
    local absentAnonymousClient = not creator and contract ~= nil
        and contract.anon_creator == true
    if not hunter or not target or (not creator and not absentAnonymousClient) then
        return false, 'party_offline'
    end

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

    if Util.dist2(hunterCoords, targetCoords) > r2 then return false, 'target_too_far' end
    if not creator then return false, 'creator_too_far' end

    local creatorCoords = GetEntityCoords(GetPlayerPed(creator.source))
    if Util.dist2(hunterCoords, creatorCoords) > r2 then return false, 'creator_too_far' end
    if Util.dist2(targetCoords, creatorCoords) > r2 then return false, 'creator_too_far' end

    return true
end

--- Try to arm a countdown for a hunter delivering to the creator.
---@return boolean armed
---@return string|nil err
--- When a hunter's last handover attempt on a contract failed.
--- [contractId .. ':' .. hunterCid] = os.time()
local lastFailure = {}

function Kidnap.arm(contractId, hunterCid)
    contractId = Util.toId(contractId)
    if not contractId then return false, CB.ERR.INVALID_INPUT end
    if active[key(contractId, hunterCid)] then return true end

    -- A failed handover cannot be restarted immediately. Without this a
    -- hunter whose client never turns up can re-arm in a loop and hold a
    -- target indefinitely at no cost, which is the hold with no time limit
    -- §14.25 was written about: the countdown is bounded, the retrying is
    -- what was not.
    local failedAt = lastFailure[key(contractId, hunterCid)]
    local cooldown = Config.Kidnap.RearmCooldownSeconds or 0
    if failedAt and (os.time() - failedAt) < cooldown then
        -- Its own code. This is the one refusal on the delivery path that
        -- waiting fixes, and BAD_STATE is worded "Not right now." — the same
        -- words as the contract having been cancelled underneath them.
        return false, CB.ERR.HANDOVER_COOLDOWN
    end

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

    -- The wait between payouts, for the same reason as the immunity check
    -- below: the claim at the end would be refused either way. It is ten
    -- minutes as shipped and a countdown is thirty seconds, so a hunter who
    -- had just collected could arm, hold a restrained player for the whole
    -- countdown, and be refused at the end — certain before it started.
    if Contracts.slotCoolingDown(hunter) then
        return false, CB.ERR.SLOT_COOLDOWN
    end

    local hunterActor  = Identity.byCitizenId(hunterCid)
    local targetActor  = Identity.byCitizenId(contract.target_cid)
    local creatorActor = Identity.byCitizenId(contract.creator_cid)

    local ok, reason = Kidnap.conditionsMet(contract, hunterActor, targetActor, creatorActor)
    if not ok then return false, reason end

    -- Immunity is checked here, not only at the end. The claim would be
    -- refused either way, and finding out after thirty seconds of holding
    -- someone is a waste of the hunter's time.
    if targetActor and Contracts.isImmune(targetActor,
        { fulfilment = CB.FULFILMENT.KIDNAPPING }) then
        return false, 'target_protected'
    end

    active[key(contractId, hunterCid)] = {
        contractId = contractId,
        hunterCid  = hunterCid,
        elapsedMs  = 0,
        graceUsedMs = 0,
        lastTick   = Util.monotonicMs(),
        startedAt  = Util.monotonicMs(),
    }

    -- How the PREVIOUS handover ended is not how this one ends. Kept, it
    -- was what the poller reported when this one stopped without an ending
    -- of its own (the hunter walking away): "The handover failed. You lost
    -- hold of the target", about a countdown from a minute earlier.
    outcomes[key(contractId, hunterCid)] = nil

    -- The creator has to be present for the whole countdown, so they are
    -- told the moment it starts rather than discovering it failed.
    Notify.toCitizen(contract.creator_cid, 'Handover starting',
        'An operative has your target in hand. Be there now.')

    Audit.action('kidnap_armed', hunterCid, contractId, {})
    Kidnap.start()
    return true
end

--------------------------------------------------------------------------
-- How a handover ended
--------------------------------------------------------------------------
--
-- The app polls the countdown once a second, and the moment it ends the
-- countdown is gone — so every ending looked the same to the poller: paid,
-- refused, lost hold, contract closed. It said "The handover ended. Get them
-- back to the client and try again." for all of them, including the one where
-- the hunter had just been paid.
--
-- Kept briefly and per (contract, hunter), holding only what that hunter is
-- told anyway. Nothing reads it but the hunter's own poller.

local OUTCOME_KEPT_SECONDS = 120

--- How long a countdown may sit paused behind another payout's settlement
--- lock. A settlement is a handful of storage writes; one that has held the
--- lock for this long is not going to let go.
local PAUSE_LIMIT_MS = 60000

local function remember(k, record)
    local now = os.time()
    for other, kept in pairs(outcomes) do
        if now - kept.at > OUTCOME_KEPT_SECONDS then outcomes[other] = nil end
    end
    record.at = now
    outcomes[k] = record
end

--- How this hunter's last handover on this contract ended, if it ended in
--- the last couple of minutes.
---@return table|nil { outcome = 'paid'|'refused'|'failed'|'closed', reason, pending }
function Kidnap.outcome(contractId, hunterCid)
    local record = outcomes[key(contractId, hunterCid)]
    if not record or os.time() - record.at > OUTCOME_KEPT_SECONDS then return nil end
    return { outcome = record.outcome, reason = record.reason, pending = record.pending }
end

--- What a hunter is told when a countdown that ran to the end is refused.
--- The page's own wording for each code is the fuller one; this is the phone
--- notification, which is all that reaches a hunter who has closed the app.
local REFUSED_WORDS = {
    [CB.ERR.SLOT_COOLDOWN] = 'You collected on this contract too recently for '
        .. 'another payout to count yet.',
    [CB.ERR.ALREADY_SETTLED] = 'Every payout on this contract had already been '
        .. 'collected by the time the handover finished.',
    [CB.ERR.BAD_STATE] = 'The contract closed before the handover finished.',
    [CB.ERR.TARGET_PROTECTED] = 'The target was still protected after '
        .. 'getting back up, so the handover does not count.',
    [CB.ERR.NOT_PARTICIPANT] = 'You are no longer on this contract.',
    [CB.ERR.LOCKED] = 'Another payout on this contract was being settled at '
        .. 'the same moment, and it got there first.',
}

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

    -- Walked from a snapshot of the keys. Every storage read below waits on
    -- the database in mysql mode, and while it waits another request can arm
    -- a countdown — a new key in the table being walked, which Lua leaves
    -- undefined for pairs(): entries skipped, or visited twice.
    local keys = {}
    for k in pairs(active) do keys[#keys + 1] = k end

    for _, k in ipairs(keys) do
        local state = active[k]
        if state then
            local contract = Storage.readContract(state.contractId)
            if contract and contract.state == CB.STATE.COMPLETING then
                -- Somebody else's payout holds the contract's lock, and holds it
                -- across yields: every escrow read and write inside claimSlot
                -- waits on the database. This tick is a separate thread, so it
                -- samples the contract in the middle of that. It used to treat the
                -- lock exactly like a cancellation and throw the countdown away —
                -- a hunter twenty-nine seconds into holding somebody lost it
                -- because another hunter verified a kill on the same contract.
                --
                -- Paused for this tick, neither advanced nor charged grace: the
                -- lock resolves on its own, back to accepted if payouts remain or
                -- to completed if that was the last one, and the next tick sees
                -- which.
                --
                -- Bounded all the same. A settlement that died halfway leaves the
                -- lock held until recovery runs, and a countdown paused on it
                -- would hold one of the server's handover slots until then.
                state.pausedMs = (state.pausedMs or 0) + deltaMs
                if state.pausedMs > PAUSE_LIMIT_MS then
                    active[k] = nil
                    lastFailure[k] = os.time()
                    Audit.action('kidnap_failed', state.hunterCid, state.contractId,
                        { reason = 'contract_locked' })
                    remember(k, { outcome = 'failed', reason = 'contract_locked' })
                    Notify.toCitizen(state.hunterCid, 'Handover failed',
                        'The contract was stuck settling another payout, so the '
                        .. 'handover could not finish. Staff can see why.',
                        { bypassBudget = true })
                end
            elseif not contract or contract.state ~= CB.STATE.ACCEPTED then
                active[k] = nil
                remember(k, { outcome = 'closed' })
                Notify.toCitizen(state.hunterCid, 'Handover ended',
                    'The contract closed before the handover finished.',
                    { bypassBudget = true })
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
                        -- Between here and the outcome below the countdown
                        -- is neither running nor ended: the payout is being
                        -- settled, and on mysql every step of that waits on
                        -- the database. A poll landing in that gap found no
                        -- countdown and no outcome and answered no_handover,
                        -- which the page reads as "The handover ended. Get
                        -- them back to the client and try again." — to a
                        -- hunter who was being paid at that moment.
                        remember(k, { outcome = 'settling' })
                        completions[#completions + 1] = {
                            contractId = state.contractId,
                            hunterCid  = state.hunterCid,
                            countdown  = state,
                        }
                    end
                else
                    -- One grace budget for the whole countdown, not per break:
                    -- otherwise a hunter could dip in and out indefinitely.
                    state.graceUsedMs = state.graceUsedMs + deltaMs
                    state.breaking = reason

                    if state.graceUsedMs > Config.Kidnap.MaxTotalGraceMs then
                        active[k] = nil
                        lastFailure[k] = os.time()
                        Audit.action('kidnap_failed', state.hunterCid, state.contractId, { reason = reason })

                        -- Told why, so a hunter whose client never showed up
                        -- knows that is what happened rather than assuming the
                        -- script ate their delivery.
                        --
                        -- An absent party is 'party_offline' whoever it is, never
                        -- 'creator_too_far', so a client whose game crashed used
                        -- to reach the hunter as "You lost hold of the target" —
                        -- sending them after a target who was still in their
                        -- hands. The target is checked first: if they are the one
                        -- who went, the hunter really has lost them.
                        local why
                        if reason == 'party_offline' and not targetActor then
                            why = 'The target left the city before the handover finished.'
                        elseif reason == 'party_offline' and not creatorActor then
                            why = 'Your client went offline before the handover finished.'
                        elseif reason == 'creator_too_far' then
                            why = 'Your client did not arrive in time.'
                        elseif reason == 'target_not_conscious' then
                            why = 'The target went down before the handover finished. '
                                .. 'A handover has to be alive.'
                        else
                            why = 'You lost hold of the target.'
                        end
                        remember(k, { outcome = 'failed', reason = reason })
                        Notify.toCitizen(state.hunterCid, 'Handover failed', why,
                            { bypassBudget = true })
                    end
                end
            end
        end
    end

    for i = 1, #completions do
        local done = completions[i]
        local ok, err, result = Contracts.claimSlot(done.contractId, done.hunterCid,
            CB.FULFILMENT.KIDNAPPING, { fulfilment = CB.FULFILMENT.KIDNAPPING })
        local k = key(done.contractId, done.hunterCid)

        -- The claim met another payout's settlement lock. The loop above
        -- read this contract as accepted, but every read between there and
        -- the claim yields, and another hunter's claim can take the lock in
        -- the gap: claimSlot then answers bad_state or locked. That is the
        -- momentary state the pause above exists for, met one step later —
        -- and it used to end the delivery, telling a hunter who had held
        -- somebody for the whole countdown that the contract had closed
        -- while it still had a payout on it. Put back instead, finished and
        -- paused, and claimed on a later tick; bounded by the same limit.
        if not ok and (err == CB.ERR.BAD_STATE or err == CB.ERR.LOCKED)
            and done.countdown and not active[k] then
            local now = Storage.readContract(done.contractId)
            local countdown = done.countdown
            if now and (now.state == CB.STATE.COMPLETING or now.state == CB.STATE.ACCEPTED)
                and (countdown.pausedMs or 0) <= PAUSE_LIMIT_MS
                and not active[k] then
                countdown.pausedMs = (countdown.pausedMs or 0) + deltaMs
                active[k] = countdown
                -- Running again, so no longer "being paid right now".
                outcomes[k] = nil
                done.retrying = true
            end
        end

        if done.retrying then
            done.error = err
        elseif ok then
            local contract = Storage.readContract(done.contractId)
            Ledger.record(contract, done.hunterCid, nil, CB.FULFILMENT.KIDNAPPING, result)
            Notify.contractCompleted(contract, done.hunterCid, nil)
            Audit.financial('kidnap_completed', done.hunterCid, done.contractId, { slot = result.slot })
            remember(k, { outcome = 'paid', pending = (result.pending or 0) > 0 })
            done.result = result
        else
            done.error = err

            -- A hunter who held a restrained player for the whole countdown
            -- and was then refused the payout used to be told nothing at
            -- all: this wrote a field onto a table the timer thread throws
            -- away, and there was not even an audit row. All that reached
            -- them was the app's poller finding the countdown gone and
            -- telling them to try again — on a refusal no retry can fix.
            Audit.rejected('kidnap_claim_failed', done.hunterCid, done.contractId,
                { err = err })
            remember(k, { outcome = 'refused', reason = err })
            Notify.toCitizen(done.hunterCid, 'Handover not paid',
                REFUSED_WORDS[err] or 'The handover finished but the payout '
                    .. 'could not be collected.',
                { bypassBudget = true })
        end
    end

    return completions
end

--- Progress for the app's countdown display.
function Kidnap.progress(contractId, hunterCid)
    local state = active[key(contractId, hunterCid)]
    if not state then return nil end
    return {
        -- Held at the full count: a countdown that has run its course can
        -- still be here, waiting to be paid behind another settlement.
        elapsed   = math.min(Config.Kidnap.CountdownSeconds,
                             math.floor(state.elapsedMs / 1000)),
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

--- Forget every re-arm cooldown, for the staff timer refresh.
---
--- Only the cooldown on a FAILED handover. Countdowns in progress are left
--- alone: they are a hold on a live player, and shortening one from a staff
--- command would hand the hunter a delivery they had not finished.
---@return integer cleared
function Kidnap.clearRearmCooldowns()
    local cleared = 0
    for k in pairs(lastFailure) do
        lastFailure[k] = nil
        cleared = cleared + 1
    end
    return cleared
end

--- A hunter who disconnects takes their countdowns with them.
---
--- Their re-arm cooldowns stay. Releasing them here meant a hunter refused a
--- re-arm could relog and arm again at once, which is the hold with no time
--- limit the cooldown exists to stop — the same reason RateLimit.clear
--- releases nothing on disconnect. A countdown the disconnect ended counts
--- as a failed one, for the same reason.
---
--- Nothing accumulates: a cooldown older than its own length is dropped here,
--- whoever it belongs to, and clearContract drops every one of a contract's
--- the moment it resolves.
function Kidnap.clearPlayer(cid)
    local now = os.time()
    for k, state in pairs(active) do
        if state.hunterCid == cid then
            active[k] = nil
            lastFailure[k] = now
        end
    end
    local cooldown = Config.Kidnap.RearmCooldownSeconds or 0
    for k, at in pairs(lastFailure) do
        if now - at >= cooldown then lastFailure[k] = nil end
    end
end

function Kidnap.clearContract(contractId)
    for k, state in pairs(active) do
        if state.contractId == contractId then
            active[k] = nil
            -- Resolved underneath a countdown in progress: cancelled,
            -- expired, bought out, or the last payout collected by somebody
            -- else. The hunter holding the target is the one person who
            -- needs to know, and was told nothing.
            remember(k, { outcome = 'closed' })
            Notify.toCitizen(state.hunterCid, 'Handover ended',
                'The contract closed before the handover finished.',
                { bypassBudget = true })
        end
    end
    for k in pairs(lastFailure) do
        if k:sub(1, #contractId + 1) == contractId .. ':' then lastFailure[k] = nil end
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
            -- One throw — a storage read on a connection that dropped, an
            -- inventory export raising inside the payout — ended this
            -- thread with `running` still set. No handover on the server
            -- moved again until a restart, and every one armed after it said
            -- it was armed and sat at nought. The maintenance tick and the
            -- condition sampler are wrapped for the same reason.
            local ok, err = pcall(Kidnap.tick, Config.Kidnap.TickMs)
            if not ok then
                print(('[crimson-bounty] handover tick failed: %s'):format(tostring(err)))
            end
        end
    end)
end

return Kidnap
