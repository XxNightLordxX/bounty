CrimsonBoot.define('server.completion.kidnap', function() --- Kidnapping fulfilment (§7.4, §14.23–§14.25).
---
--- One shared tick drives every armed countdown, so cost scales with the
--- number of deliveries actually in progress rather than with the number of
--- accepted contracts. Positions and states are read server-side; the hitman
--- reports nothing.

local Util = CrimsonBoot.requireShared('util')
local Holds = CrimsonBoot.require('server.holds')
local Geo = CrimsonBoot.requireShared('geo')
local Words = CrimsonBoot.requireShared('words')
local Log = CrimsonBoot.requireShared('log')
local Integrations = CrimsonBoot.require('server.adapters.init')
local Bridge = CrimsonBoot.require('server.lib.bridge')
local L = CrimsonBoot.requireShared('locale').t

--- The adapters answering now (server/adapters/): nil while none does.
local function Framework() return Integrations.get('framework') end

local Kidnap = {}

local Storage, Identity, Contracts, Audit, Notify, Ledger

--- [contractId .. ':' .. hitmanCid] = countdown
local active = {}
local running = false

--- How each hitman's last handover ended; see Kidnap.outcome below.
--- [contractId .. ':' .. hitmanCid] = { outcome, reason, pending, parked, at }
local outcomes = {}

--- How many handovers each contract's placer has declined, or left to run
--- out under ConfirmMissed 'rearm' (Config.Kidnap.MaxDeclines): [contractId]
--- = count. In memory: a restart ends every handover with the resource.
local declines = {}

function Kidnap.init(deps)
    Storage, Identity, Contracts, Audit, Notify, Ledger =
        deps.storage, deps.identity, deps.contracts, deps.audit, deps.notify, deps.ledger
    active = {}
    declines = {}
end

--- Whether this contract's placer has used every decline they get
--- (Config.Kidnap.MaxDeclines, 2 as shipped; 0 = no limit): the next
--- handover held for its countdown then pays without asking them.
---@param contractId string
---@return boolean
function Kidnap.declinesUsed(contractId)
    local most = math.floor(tonumber(Config.Kidnap.MaxDeclines) or 0)
    return most > 0 and (declines[contractId] or 0) >= most
end

local function key(contractId, hitmanCid) return contractId .. ':' .. hitmanCid end

--- A player's routing bucket, or nil when the server cannot say: nil is
--- never anybody's bucket, so an unanswered read refuses rather than
--- counts as together.
---@param src number
---@return integer|nil
local function bucketOf(src)
    local ok, bucket = pcall(GetPlayerRoutingBucket, src)
    return ok and tonumber(bucket) or nil
end

--------------------------------------------------------------------------
-- Coercion
--------------------------------------------------------------------------

--- A delivery only counts if the target is visibly under the hitman's
--- control. Walking beside a willing friend is not a kidnapping.
---
--- Any enabled detector satisfies the requirement, so servers with different
--- restraint scripts all have a working path.
---@return boolean coerced
---@return string|nil how
function Kidnap.isCoerced(hitmanSource, targetSource)
    if not Config.Kidnap.RequireCoercion then return true, 'not_required' end

    local rules = Config.Kidnap.Coercion or {}

    if rules.handcuffed then
        local target = Framework().GetPlayer(targetSource)
        local meta = target and target.PlayerData and target.PlayerData.metadata
        if meta and meta.ishandcuffed then return true, 'handcuffed' end
    end

    if rules.passengerOfHitman then
        local targetVeh = GetVehiclePedIsIn(GetPlayerPed(targetSource))
        local hitmanVeh = GetVehiclePedIsIn(GetPlayerPed(hitmanSource))
        if targetVeh and targetVeh ~= 0 and targetVeh == hitmanVeh then
            return true, 'in_hitman_vehicle'
        end
    end

    -- Optional hook for a server's own rope / ziptie resource.
    -- A resource name; GetResourceState takes nothing else.
    local provider = Config.Kidnap.RestraintProvider
    if type(provider) == 'string' then
        -- Called by name (Bridge.call: only while it is started; a raise
        -- said once a minute).
        local ok, restrained = Bridge.call(provider, 'IsRestrained', targetSource)
        if ok and restrained then return true, 'restraint_provider' end
    end

    return false
end

--------------------------------------------------------------------------
-- Arming
--------------------------------------------------------------------------

--- Conditions that must hold both to arm a countdown and to keep it running.
---
--- `radius` is the one a running countdown was armed with (its state's), and
--- Config.Kidnap.Radius to arm one. The panel tells staff a countdown keeps
--- the radius it was armed with, and the samples read the config every
--- time: narrowed live, every handover in progress was out of range at once,
--- spent its one grace budget, and failed.
---@param radius number|nil metres; Config.Kidnap.Radius when nil
---@return boolean ok
---@return string|nil reason
function Kidnap.conditionsMet(contract, hitman, target, creator, radius)
    -- An anonymous client who is not in the city gets the answer a client
    -- who is in the city but not here would get (§14.32). 'party_offline'
    -- was the first thing checked, so a hitman pressing Arm anywhere, with
    -- nobody in hand, learned whether the person who paid to stay unnamed
    -- was online right now — as often as they liked, since a refusal costs
    -- nothing. Taken to the creator-distance check instead, so every earlier
    -- reason is still the one it would have been.
    local absentAnonymousClient = not creator and contract ~= nil
        and contract.anon_creator == true
    if not hitman or not target or (not creator and not absentAnonymousClient) then
        return false, 'party_offline'
    end

    -- The target must be alive and conscious for the entire delivery.
    -- Delivering a corpse is not a kidnapping (§7.4). Under the health floor
    -- is its own reason: they are neither, and the hitman can see it.
    --
    -- On a contract placed under 'alive' the check is not the operator's to
    -- switch off. A handover is the only way it completes, so with
    -- RequireConscious or RejectDead off a hitman could kill the target,
    -- cuff the body (the medical resource raises it at full health, over
    -- any floor) or put it in their car, and be paid the whole reward for
    -- the one thing the rule exists to stop. Those switches loosen only
    -- contracts a kill completes anyway.
    local aliveOnly = contract ~= nil
        and Util.fulfilmentRule(contract) == CH.FULFILMENT_RULE.ALIVE
    if Config.Kidnap.RequireConscious or aliveOnly then
        local alive, why = Identity.isAliveAndConscious(target.source, aliveOnly)
        if not alive then return false, why or 'target_not_conscious' end
    end

    local coerced = Kidnap.isCoerced(hitman.source, target.source)
    if not coerced then return false, 'not_coerced' end

    -- One instance (routing bucket) for all of them. Three players in three
    -- apartment shells stand at the same coordinates and are nowhere near
    -- each other, so the distances below say nothing across buckets. The
    -- person who placed it in another one is not here, said as the absent
    -- or distant placer is (creator_too_far), so it tells nobody whether an
    -- anonymous one is online.
    local hitmanBucket = bucketOf(hitman.source)
    if hitmanBucket == nil or bucketOf(target.source) ~= hitmanBucket then
        return false, 'not_together'
    end

    radius = tonumber(radius) or Config.Kidnap.Radius
    local r2 = radius * radius
    local hitmanCoords = GetEntityCoords(GetPlayerPed(hitman.source))
    local targetCoords = GetEntityCoords(GetPlayerPed(target.source))

    if Geo.dist2(hitmanCoords, targetCoords) > r2 then return false, 'target_too_far' end
    if not creator then return false, 'creator_too_far' end
    if bucketOf(creator.source) ~= hitmanBucket then return false, 'creator_too_far' end

    local creatorCoords = GetEntityCoords(GetPlayerPed(creator.source))
    if Geo.dist2(hitmanCoords, creatorCoords) > r2 then return false, 'creator_too_far' end
    if Geo.dist2(targetCoords, creatorCoords) > r2 then return false, 'creator_too_far' end

    return true
end

--- Try to arm a countdown for a hitman delivering to the creator.
---@return boolean armed
---@return string|nil err
--- When a hitman's last handover attempt on a contract failed.
--- [contractId .. ':' .. hitmanCid] = os.time()
local lastFailure = {}
--- When a hitman's last arm on a contract was refused for the person who
--- placed it not being there (creator_too_far): [key] = os.time(). Armed
--- again at once, that refusal and its success said, a step at a time while
--- walking past people, which of them was the anonymous placer. So it waits
--- too: Config.Kidnap.RearmCooldownSeconds, at most FAR_RETRY_SECONDS.
local lastFar = {}
local FAR_RETRY_SECONDS = 15

function Kidnap.arm(contractId, hitmanCid)
    contractId = Util.toId(contractId)
    if not contractId then return false, CH.ERR.INVALID_INPUT end
    if active[key(contractId, hitmanCid)] then return true end

    -- A failed handover cannot be restarted immediately. Without this a
    -- hitman whose client never turns up can re-arm in a loop and hold a
    -- target indefinitely at no cost, which is the hold with no time limit
    -- §14.25 was written about: the countdown is bounded, the retrying is
    -- what was not.
    local failedAt = lastFailure[key(contractId, hitmanCid)]
    local cooldown = Config.Kidnap.RearmCooldownSeconds or 0
    if failedAt and (os.time() - failedAt) < cooldown then
        -- Its own code. This is the one refusal on the delivery path that
        -- waiting fixes, and BAD_STATE is worded "Not right now." — the same
        -- words as the contract having been cancelled underneath them.
        return false, CH.ERR.HANDOVER_COOLDOWN
    end
    local farAt = lastFar[key(contractId, hitmanCid)]
    if farAt and (os.time() - farAt) < math.min(cooldown, FAR_RETRY_SECONDS) then
        return false, CH.ERR.HANDOVER_COOLDOWN
    end

    local count = 0
    for _ in pairs(active) do count = count + 1 end
    if count >= Config.Kidnap.MaxConcurrentCountdowns then
        -- Refuse to arm rather than shedding one already in progress: a
        -- delivery halfway through is worth more than a new one.
        return false, CH.ERR.LIMIT_REACHED
    end

    local contract = Storage.readContract(contractId)
    if not contract or contract.state ~= CH.STATE.ACCEPTED then return false, CH.ERR.BAD_STATE end
    -- Past its deadline it is ending, as an acceptance is told. The expiry
    -- waits for a handover already counting (ExpireContracts), not for one
    -- started after the time ran out.
    if Contracts.isOverdue(contract, os.time()) then return false, CH.ERR.ALREADY_SETTLED end

    local hitman = Storage.readHitman(contractId, hitmanCid)
    if not hitman or hitman.state ~= 'active' then return false, CH.ERR.NOT_PARTICIPANT end

    -- On hold by staff (server/holds.lua): the payout at the end would be
    -- refused, so nobody is held for it.
    if Holds.on(contract, nil, 'staff') then return false, CH.ERR.CONTRACT_FROZEN end
    -- Every contract is on the restart hold (Holds.scheduledRestart): a
    -- countdown armed now could not finish before the restart.
    if Holds.on(nil, nil, 'restart') then return false, CH.ERR.RESTART_HOLD end

    -- The wait between payouts, for the same reason as the immunity check
    -- below: the claim at the end would be refused either way. It is ten
    -- minutes as shipped and a countdown is thirty seconds, so a hitman who
    -- had just collected could arm, hold a restrained player for the whole
    -- countdown, and be refused at the end — certain before it started.
    if Contracts.slotCoolingDown(hitman) then
        return false, CH.ERR.SLOT_COOLDOWN
    end

    local hitmanActor  = Identity.byCitizenId(hitmanCid)
    local targetActor  = Identity.byCitizenId(contract.target_cid)
    local creatorActor = Identity.byCitizenId(contract.creator_cid)

    local radius = Config.Kidnap.Radius
    local ok, reason = Kidnap.conditionsMet(contract, hitmanActor, targetActor, creatorActor, radius)
    if not ok then
        if reason == 'creator_too_far' then lastFar[key(contractId, hitmanCid)] = os.time() end
        return false, reason
    end
    lastFar[key(contractId, hitmanCid)] = nil

    -- Immunity is checked here, not only at the end. The claim would be
    -- refused either way, and finding out after thirty seconds of holding
    -- someone is a waste of the hitman's time.
    --
    -- Which rule, too. A live delivery is exempt from the post-respawn one,
    -- so a refusal here is never that, and "they only just got up" was the
    -- one thing it could not be.
    if targetActor then
        local immune, why = Contracts.isImmune(targetActor,
            { fulfilment = CH.FULFILMENT.KIDNAPPING })
        if immune then return false, why or CH.ERR.TARGET_PROTECTED end
    end

    active[key(contractId, hitmanCid)] = {
        contractId = contractId,
        hitmanCid  = hitmanCid,
        elapsedMs  = 0,
        graceUsedMs = 0,
        lastTick   = Util.monotonicMs(),
        startedAt  = Util.monotonicMs(),
        -- On the clock deadlines are kept in (Kidnap.armedAt).
        armedAt    = os.time(),
        -- What every sample measures against, whatever staff change it to
        -- meanwhile (Kidnap.conditionsMet).
        radius     = radius,
        -- The other two parties, for the record a drop mid-handover leaves
        -- (Kidnap.partyDropped): a disconnect reads nothing from the store.
        targetCid  = contract.target_cid,
        creatorCid = contract.creator_cid,
        -- Whether the placer confirms before it pays (Config.Kidnap
        -- .PlacerConfirms), as it was when armed: switched meanwhile, a
        -- handover keeps the rule it started under.
        confirm    = Config.Kidnap.PlacerConfirms == true,
    }

    -- How the PREVIOUS handover ended is not how this one ends. Kept, it
    -- was what the poller reported when this one stopped without an ending
    -- of its own (the hitman walking away): "The handover failed. You lost
    -- hold of the target", about a countdown from a minute earlier.
    outcomes[key(contractId, hitmanCid)] = nil

    -- The creator has to be present for the whole countdown, so they are
    -- told the moment it starts rather than discovering it failed, and how
    -- close to stand: "Be there now" did not say where "there" ended.
    Notify.toCitizen(contract.creator_cid, L('completion_kidnap.handover_starting'),
        (L('completion_kidnap.a_hitman_has_brought_your_target'))
            :format(Words.metres(tonumber(radius) or Config.Kidnap.Radius), tonumber(Config.Kidnap.CountdownSeconds) or 0,
                Config.Kidnap.PlacerConfirms == true and (L('completion_kidnap.then_tap_confirm_handover_on_your')) or ''))
    -- And their card, which counts it down (Projection: handoverLeft).
    Notify.push(contract.creator_cid, 'handover', contractId)

    Audit.action('kidnap_armed', hitmanCid, contractId, {})
    -- An attempt on the target, which is what keeps an exclusive hold.
    if Contracts.noteAttempt then Contracts.noteAttempt(contractId, hitmanCid) end
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
-- the hitman had just been paid.
--
-- Kept briefly and per (contract, hitman), holding only what that hitman is
-- told anyway. Nothing reads it but the hitman's own poller.

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

--- How this hitman's last handover on this contract ended, if it ended in
--- the last couple of minutes.
---@return table|nil { outcome = 'paid'|'refused'|'failed'|'closed', reason, pending, parked }
function Kidnap.outcome(contractId, hitmanCid)
    local record = outcomes[key(contractId, hitmanCid)]
    if not record or os.time() - record.at > OUTCOME_KEPT_SECONDS then return nil end
    return { outcome = record.outcome, reason = record.reason, pending = record.pending,
             parked = record.parked }
end

--- What a hitman is told when a countdown that ran to the end is refused.
--- The page's own wording for each code is the fuller one; this is the phone
--- notification, which is all that reaches a hitman who has closed the app.
local REFUSED_WORDS = {
    [CH.ERR.SLOT_COOLDOWN] = L('completion_kidnap.you_collected_on_this_contract_too'),
    [CH.ERR.ALREADY_SETTLED] = L('completion_kidnap.every_payout_on_this_contract_had'),
    [CH.ERR.BAD_STATE] = L('completion_kidnap.the_contract_closed_before_the_handover'),
    -- A live delivery skips the post-respawn rule, so getting back up is
    -- never the reason here: only being new to the session or the city.
    [CH.ERR.TARGET_JUST_ON] = L('completion_kidnap.the_target_had_only_just_come'),
    [CH.ERR.TARGET_TOO_NEW] = L('completion_kidnap.the_target_is_too_new_to'),
    [CH.ERR.TARGET_PROTECTED] = L('completion_kidnap.the_target_was_protected_from_contracts'),
    [CH.ERR.NOT_PARTICIPANT] = L('completion_kidnap.you_are_no_longer_on_this'),
    [CH.ERR.LOCKED] = L('completion_kidnap.another_payout_on_this_contract_was'),
    -- Staff put it on hold while the payout was being settled
    -- (server/holds.lua). Plain, and never which party it is about.
    [CH.ERR.CONTRACT_FROZEN] = L('completion_kidnap.this_contract_is_on_hold_by'),
}

--- The person who placed the contract, told a handover they were asked to
--- stay for did not finish. They were told at the arm to stay where they
--- were for the countdown, and nothing told them when it failed: they stood
--- there, or walked off thinking it had paid. What they can see anyway, and
--- nothing about the hitman beyond that.
---@param state table the countdown
local function tellPlacerStopped(state)
    if not state.creatorCid then return end
    pcall(Notify.toCitizen, state.creatorCid, L('completion_kidnap.handover_stopped'),
        (L('completion_kidnap.the_handover_did_not_finish_so'))
            :format(Words.metres(tonumber(state.radius) or Config.Kidnap.Radius), tonumber(Config.Kidnap.CountdownSeconds) or 0),
        { bypassBudget = true })
end

function Kidnap.cancel(contractId, hitmanCid, reason)
    local k = key(contractId, hitmanCid)
    if not active[k] then return false end
    active[k] = nil
    Audit.action('kidnap_cancelled', hitmanCid, contractId, { reason = reason })
    -- Stopped by a staff freeze (Holds.freeze): the hitman's page is told
    -- it is on hold, not that the handover ended for no reason.
    if reason == 'on_hold' then
        remember(k, { outcome = 'refused', reason = CH.ERR.CONTRACT_FROZEN })
    end
    return true
end

--------------------------------------------------------------------------
-- The shared tick
--------------------------------------------------------------------------

--- Advance every armed countdown by one interval. Exposed directly so the
--- test suite can drive it without a thread.
---@param deltaMs integer
---@return table completions list of { contractId, hitmanCid }
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
            -- Each countdown on its own. One throw — a read on a connection
            -- that dropped — used to end the whole pass, and every countdown
            -- after it waited on a pass that never came to it.
            local stepped, stepError = pcall(function()
            local contract = Storage.readContract(state.contractId)
            if contract and contract.state == CH.STATE.ACCEPTED
                and Holds.on(nil, nil, 'restart') then
                -- The restart hold (Holds.scheduledRestart): stood still,
                -- neither advanced nor charged grace, so it cannot finish
                -- during it. One already running when the hold began goes
                -- on once it is released; a restart ends it with the
                -- resource, as any restart does.
                state.breaking = nil
            elseif contract and contract.state == CH.STATE.COMPLETING then
                -- Somebody else's payout holds the contract's lock, and holds it
                -- across yields: every escrow read and write inside claimSlot
                -- waits on the database. This tick is a separate thread, so it
                -- samples the contract in the middle of that. It used to treat the
                -- lock exactly like a cancellation and throw the countdown away —
                -- a hitman twenty-nine seconds into holding somebody lost it
                -- because another hitman verified a kill on the same contract.
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
                    Audit.action('kidnap_failed', state.hitmanCid, state.contractId,
                        { reason = 'contract_locked' })
                    remember(k, { outcome = 'failed', reason = 'contract_locked' })
                    Notify.toCitizen(state.hitmanCid, L('completion_kidnap.handover_failed'),
                        L('completion_kidnap.the_contract_was_stuck_settling_another'),
                        { bypassBudget = true })
                    tellPlacerStopped(state)
                end
            elseif not contract or contract.state ~= CH.STATE.ACCEPTED then
                active[k] = nil
                if not contract or CH.TERMINAL[contract.state] then declines[state.contractId] = nil end
                remember(k, { outcome = 'closed' })
                Notify.toCitizen(state.hitmanCid, L('completion_kidnap.handover_ended'),
                    L('completion_kidnap.the_contract_closed_before_the_handover'),
                    { bypassBudget = true })
            elseif state.confirmLeftMs then
                -- The hold is done and waits on the placer's word
                -- (Kidnap.answer): nothing is sampled any more, the hold
                -- being what proves the handover. Paid once confirmed; at
                -- the end of the window, by Config.Kidnap.ConfirmMissed.
                -- The window stands still on the restart hold (above) and
                -- while the app is paused (Config.Holds.AppPaused), as every
                -- clock does.
                if not state.confirmed and not Holds.on(nil, nil, 'app') then
                    state.confirmLeftMs = state.confirmLeftMs - deltaMs
                end
                if not state.confirmed and state.confirmLeftMs <= 0 then
                    if Config.Kidnap.ConfirmMissed == 'pay' then
                        state.confirmed = 'timeout'
                        Audit.action('kidnap_confirm_timeout', state.hitmanCid, state.contractId, { paid = true })
                    else
                        Kidnap.notConfirmed(k, state, 'timeout')
                    end
                end
                if state.confirmed and active[k] == state then
                    active[k] = nil
                    remember(k, { outcome = 'settling' })
                    completions[#completions + 1] = {
                        contractId = state.contractId, hitmanCid = state.hitmanCid,
                        countdown = state, slot = contract.next_slot or 1,
                    }
                end
            else
                local hitmanActor  = Identity.byCitizenId(state.hitmanCid)
                local targetActor  = Identity.byCitizenId(contract.target_cid)
                local creatorActor = Identity.byCitizenId(contract.creator_cid)

                local ok, reason = Kidnap.conditionsMet(contract, hitmanActor, targetActor,
                    creatorActor, state.radius)

                if ok then
                    state.elapsedMs = state.elapsedMs + deltaMs
                    state.breaking = nil

                    -- Declined (or left to run out) as many times as the
                    -- placer may (Config.Kidnap.MaxDeclines): this one pays
                    -- as if confirmed, and both are told it did.
                    if state.elapsedMs >= (Config.Kidnap.CountdownSeconds * 1000)
                        and state.confirm and not state.confirmed and Kidnap.declinesUsed(state.contractId) then
                        state.confirmed = 'declines_used'
                        Audit.action('kidnap_declines_used', state.hitmanCid, state.contractId,
                            { declines = declines[state.contractId] })
                        pcall(Notify.toCitizen, state.creatorCid, L('completion_kidnap.handover_paid'),
                            L('completion_kidnap.you_have_declined_this_contracts_handovers'),
                            { bypassBudget = true })
                    end

                    if state.elapsedMs >= (Config.Kidnap.CountdownSeconds * 1000)
                        and state.confirm and not state.confirmed then
                        -- Held long enough; now the placer's word.
                        Kidnap.awaitConfirm(state)
                    elseif state.elapsedMs >= (Config.Kidnap.CountdownSeconds * 1000) then
                        active[k] = nil
                        -- Between here and the outcome below the countdown
                        -- is neither running nor ended: the payout is being
                        -- settled, and on mysql every step of that waits on
                        -- the database. A poll landing in that gap found no
                        -- countdown and no outcome and answered no_handover,
                        -- which the page reads as "The handover ended. Get
                        -- them back to the client and try again." — to a
                        -- hitman who was being paid at that moment.
                        remember(k, { outcome = 'settling' })
                        completions[#completions + 1] = {
                            contractId = state.contractId,
                            hitmanCid  = state.hitmanCid,
                            countdown  = state,
                            -- Which collection it is for, so a claim that
                            -- throws can be told apart from one that paid.
                            slot       = contract.next_slot or 1,
                        }
                    end
                else
                    -- One grace budget for the whole countdown, not per break:
                    -- otherwise a hitman could dip in and out indefinitely.
                    state.graceUsedMs = state.graceUsedMs + deltaMs
                    state.breaking = reason

                    if state.graceUsedMs > Config.Kidnap.MaxTotalGraceMs then
                        active[k] = nil
                        lastFailure[k] = os.time()
                        Audit.action('kidnap_failed', state.hitmanCid, state.contractId, { reason = reason })

                        -- Told why, so a hitman whose client never showed up
                        -- knows that is what happened rather than assuming the
                        -- script ate their delivery.
                        --
                        -- An absent party is 'party_offline' whoever it is, never
                        -- 'creator_too_far', so a client whose game crashed used
                        -- to reach the hitman as "You lost hold of the target" —
                        -- sending them after a target who was still in their
                        -- hands. The target is checked first: if they are the one
                        -- who went, the hitman really has lost them.
                        --
                        -- The person who placed the contract by that name, with
                        -- the distance they had to keep: "your client" named
                        -- somebody a hitman may never have been told about. An
                        -- absent anonymous one fails as creator_too_far, and its
                        -- words say "online and within" so as not to say which.
                        local why
                        if reason == 'party_offline' and not targetActor then
                            why = L('completion_kidnap.the_target_left_the_city_before')
                        elseif reason == 'party_offline' and not creatorActor then
                            why = (L('completion_kidnap.the_person_who_placed_this_contract')):format(Words.metres(tonumber(state.radius) or Config.Kidnap.Radius))
                        elseif reason == 'creator_too_far' then
                            why = (L('completion_kidnap.the_person_who_placed_this_contract_2')):format(Words.metres(tonumber(state.radius) or Config.Kidnap.Radius))
                        elseif reason == 'target_not_conscious' then
                            why = L('completion_kidnap.the_target_went_down_before_the')
                            -- Where nothing but a handover pays, what still does.
                            if Util.fulfilmentRule(contract) == CH.FULFILMENT_RULE.ALIVE then
                                why = why .. L('completion_kidnap.killing_them_does_not_count_once')
                            end
                        elseif reason == 'target_too_hurt' then
                            why = L('completion_kidnap.the_target_got_too_badly_hurt')
                        elseif reason == 'not_together' then
                            why = L('completion_kidnap.you_and_the_target_were_not')
                        else
                            why = L('completion_kidnap.you_lost_hold_of_the_target')
                        end
                        remember(k, { outcome = 'failed', reason = reason })
                        Notify.toCitizen(state.hitmanCid, L('completion_kidnap.handover_failed'), why,
                            { bypassBudget = true })
                        tellPlacerStopped(state)
                    end
                end
            end
            end)
            if not stepped then
                Log.debug(('handover countdown %s failed: %s')
                    :format(tostring(k), tostring(stepError)))
            end
        end
    end

    for i = 1, #completions do
        local done = completions[i]
        local settled, settleError = pcall(function()
        local ok, err, result = Contracts.claimSlot(done.contractId, done.hitmanCid,
            CH.FULFILMENT.KIDNAPPING, { fulfilment = CH.FULFILMENT.KIDNAPPING })
        local k = key(done.contractId, done.hitmanCid)

        -- The claim met another payout's settlement lock. The loop above
        -- read this contract as accepted, but every read between there and
        -- the claim yields, and another hitman's claim can take the lock in
        -- the gap: claimSlot then answers bad_state or locked. That is the
        -- momentary state the pause above exists for, met one step later —
        -- and it used to end the delivery, telling a hitman who had held
        -- somebody for the whole countdown that the contract had closed
        -- while it still had a payout on it. Put back instead, finished and
        -- paused, and claimed on a later tick; bounded by the same limit.
        if not ok and (err == CH.ERR.BAD_STATE or err == CH.ERR.LOCKED)
            and done.countdown and not active[k] then
            local now = Storage.readContract(done.contractId)
            local countdown = done.countdown
            if now and (now.state == CH.STATE.COMPLETING or now.state == CH.STATE.ACCEPTED)
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
            -- Paid is recorded first: what follows is bookkeeping, and a
            -- throw in it must not read as a claim that failed. Held for
            -- room apart from left for staff (Escrow.parked), which no retry
            -- gives and making room does nothing for.
            remember(k, { outcome = 'paid', pending = (result.pending or 0) > 0,
                          parked = (result.parked or 0) > 0 })
            done.result = result
            -- Each step on its own. One pcall around all of them meant a
            -- ledger write that raised dropped the client's notice and the
            -- financial row too, and said nothing of it anywhere.
            local read, contract = pcall(Storage.readContract, done.contractId)
            if not read then
                Log.always(('handover %s was paid, and reading its contract back raised: %s')
                    :format(tostring(k), Util.dbError(contract)))
                contract = nil
            end
            local wrote, ledgerErr = pcall(Ledger.record, contract, done.hitmanCid, nil,
                CH.FULFILMENT.KIDNAPPING, result)
            if not wrote then
                pcall(Audit.financial, 'ledger_write_failed', done.hitmanCid, done.contractId,
                    { error = tostring(ledgerErr) })
                Log.always(('handover %s was paid, and writing its ledger rows raised: %s')
                    :format(tostring(k), Util.dbError(ledgerErr)))
            end
            -- The client's notice, and the hitman's receipt: the paid
            -- ending was the one that sent the hitman nothing, and the
            -- countdown is when the phone is most likely put away.
            pcall(Notify.contractCompleted, contract, done.hitmanCid, nil, result,
                { receipt = true })
            pcall(Audit.financial, 'kidnap_completed', done.hitmanCid, done.contractId,
                { slot = result.slot })
        else
            done.error = err

            -- A hitman who held a restrained player for the whole countdown
            -- and was then refused the payout used to be told nothing at
            -- all: this wrote a field onto a table the timer thread throws
            -- away, and there was not even an audit row. All that reached
            -- them was the app's poller finding the countdown gone and
            -- telling them to try again — on a refusal no retry can fix.
            Audit.rejected('kidnap_claim_failed', done.hitmanCid, done.contractId,
                { err = err })
            remember(k, { outcome = 'refused', reason = err })
            Notify.toCitizen(done.hitmanCid, L('completion_kidnap.handover_not_paid'),
                REFUSED_WORDS[err] or L('completion_kidnap.the_handover_finished_but_the_payout'),
                { bypassBudget = true })
        end
        end)
        if not settled then
            -- The claim threw. Whether it took effect is read from the
            -- contract: still accepted, on the collection this handover was
            -- for, and it never happened — the countdown goes back, paused,
            -- and is claimed on a later pass. Anything else is left for
            -- staff and the hitman is told, rather than dropped: the
            -- countdown was already out of `active`, and a throw here used
            -- to lose it with the page showing "being paid" for two minutes.
            local k = key(done.contractId, done.hitmanCid)
            Log.always(('handover claim %s failed: %s')
                :format(tostring(k), tostring(settleError)))
            local readOk, now = pcall(Storage.readContract, done.contractId)
            local untouched = readOk and now and now.state == CH.STATE.ACCEPTED
                and (now.next_slot or 1) == done.slot
            local countdown = done.countdown
            if untouched and countdown and not active[k]
                and (countdown.pausedMs or 0) <= PAUSE_LIMIT_MS then
                countdown.pausedMs = (countdown.pausedMs or 0) + deltaMs
                active[k] = countdown
                outcomes[k] = nil
                done.retrying = true
            else
                remember(k, { outcome = 'refused', reason = 'error' })
                pcall(Audit.rejected, 'kidnap_claim_error', done.hitmanCid, done.contractId,
                    { err = tostring(settleError) })
                -- The maintenance tick finishes a claim that raised within a
                -- minute (Contracts.retryStuckClaims): a collection it paid is
                -- credited and receipted, and one it did not is open again.
                pcall(Notify.toCitizen, done.hitmanCid, L('completion_kidnap.handover_not_paid'),
                    L('completion_kidnap.the_handover_finished_but_the_payout_2'),
                    { bypassBudget = true })
            end
        end
    end

    return completions
end

--- Progress for the app's countdown display.
function Kidnap.progress(contractId, hitmanCid)
    local state = active[key(contractId, hitmanCid)]
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
        -- The distance this countdown measures against (the one it was
        -- armed with), so the page can say how close the person who placed
        -- the contract has to be when that is what is slipping.
        radius    = state.radius,
        -- Held long enough, and waiting on the placer's Confirm handover
        -- (Config.Kidnap.PlacerConfirms): roughly how long they have left.
        awaitingConfirm = state.confirmLeftMs ~= nil or nil,
        confirmLeft = state.confirmLeftMs and Kidnap.roughSeconds(state.confirmLeftMs) or nil,
    }
end

--------------------------------------------------------------------------
-- The placer's Confirm handover (Config.Kidnap.PlacerConfirms)
--------------------------------------------------------------------------

--- Seconds, rounded up to the next five, of a window in milliseconds.
---@param ms number
---@return integer
function Kidnap.roughSeconds(ms)
    local s = math.max(0, math.ceil((tonumber(ms) or 0) / 1000))
    return math.ceil(s / 5) * 5
end

--- The window a placer has to confirm, in seconds (Config.Kidnap
--- .ConfirmSeconds), at least 10.
local function confirmWindow()
    return math.max(10, math.floor(tonumber(Config.Kidnap.ConfirmSeconds) or 60))
end

--- A countdown held long enough on a contract its placer confirms: the
--- window opens, the placer's card shows Confirm handover (Projection:
--- handoverConfirm) and their phone says so, and the hitman is told it
--- waits on that. Neither is told who the other is.
---@param state table the countdown
function Kidnap.awaitConfirm(state)
    state.confirmLeftMs = confirmWindow() * 1000
    state.breaking = nil
    Audit.action('kidnap_awaiting_confirm', state.hitmanCid, state.contractId, {})
    pcall(Notify.toCitizen, state.creatorCid, L('completion_kidnap.confirm_handover'),
        (L('completion_kidnap.the_hold_is_done_tap_confirm')):format(confirmWindow()),
        { bypassBudget = true })
    pcall(Notify.push, state.creatorCid, 'handover', state.contractId)
    pcall(Notify.toCitizen, state.hitmanCid, L('completion_kidnap.handover_held'),
        L('completion_kidnap.held_long_enough_the_person_who'), { bypassBudget = true })
end

--- A handover its placer declined, or did not confirm in time (and
--- Config.Kidnap.ConfirmMissed is 'rearm'): nothing is paid, the contract
--- stays open, and the hitman may arm again after Config.Kidnap
--- .RearmCooldownSeconds, as after any failed handover. The hitman reads
--- the same words either way.
---@param k string the countdown's key
---@param state table
---@param why string 'declined' | 'timeout'
function Kidnap.notConfirmed(k, state, why)
    if active[k] ~= state then return end
    active[k] = nil
    lastFailure[k] = os.time()
    declines[state.contractId] = (declines[state.contractId] or 0) + 1
    Audit.action('kidnap_not_confirmed', state.hitmanCid, state.contractId,
        { reason = why, declines = declines[state.contractId] })
    remember(k, { outcome = 'failed', reason = 'not_confirmed' })
    pcall(Notify.toCitizen, state.hitmanCid, L('completion_kidnap.handover_not_confirmed'),
        L('completion_kidnap.the_person_who_placed_this_contract_3'), { bypassBudget = true })
    pcall(Notify.toCitizen, state.creatorCid, L('completion_kidnap.handover_not_confirmed'),
        why == 'declined' and L('completion_kidnap.you_declined_the_handover_nothing_was')
            or L('completion_kidnap.the_handover_was_not_confirmed_in'),
        { bypassBudget = true })
    pcall(Notify.push, state.creatorCid, 'handover', state.contractId)
end

--- The placer's answer: Confirm handover (yes) or Decline, on the handover
--- waiting longest on their word on this contract. Only the contract's
--- placer is answered anything but not found, so nobody else learns that a
--- handover is running. Refused while staff hold it (frozen) and, for a
--- confirm, during the restart hold, when the payout would be refused.
---@param contractId any
---@param cid string the asker
---@param yes boolean
---@return boolean ok
---@return string|nil err
---@return table|nil data { confirmed } | { declined }
function Kidnap.answer(contractId, cid, yes)
    contractId = Util.toId(contractId)
    if not contractId then return false, CH.ERR.INVALID_INPUT end
    local contract = Storage.readContract(contractId)
    if not contract or contract.creator_cid ~= cid then return false, CH.ERR.NOT_FOUND end
    local pick, pickKey
    for k, state in pairs(active) do
        if state.contractId == contractId and state.confirmLeftMs and not state.confirmed
            and (not pick or state.confirmLeftMs < pick.confirmLeftMs) then
            pick, pickKey = state, k
        end
    end
    if not pick then return false, CH.ERR.NO_HANDOVER end
    if Holds.on(contract, nil, 'staff') then return false, CH.ERR.CONTRACT_FROZEN end
    if yes and Holds.on(nil, nil, 'restart') then return false, CH.ERR.RESTART_HOLD end
    -- The hold (Holds) is a read, and the tick runs in its awaits: a window
    -- it closed meanwhile (run out, rearmed or paid) is not answered as if
    -- it were still open.
    if active[pickKey] ~= pick or not pick.confirmLeftMs or pick.confirmed then
        return false, CH.ERR.NO_HANDOVER
    end
    if not yes then
        Kidnap.notConfirmed(pickKey, pick, 'declined')
        return true, nil, { declined = true }
    end
    pick.confirmed = true
    Audit.action('kidnap_confirmed', cid, contractId, {})
    return true, nil, { confirmed = true }
end

--- What the placer's card shows of a handover waiting on their word:
--- roughly how long is left to confirm, or nil. Never which operative.
---@param contractId string
---@return integer|nil
function Kidnap.placerConfirm(contractId)
    local least
    for _, state in pairs(active) do
        if state.contractId == contractId and state.confirmLeftMs and not state.confirmed then
            if not least or state.confirmLeftMs < least then least = state.confirmLeftMs end
        end
    end
    if not least then return nil end
    return math.max(5, Kidnap.roughSeconds(least))
end


--- What the person who placed it is shown of a handover running on their
--- contract: roughly how long they still have to hold still, in seconds,
--- rounded up to the next five, or nil with none running. The longest one
--- left if several are. Never which operative, how far anybody is, or the
--- grace: they stand there, and this is only how long.
---@param contractId string
---@return integer|nil secondsLeft
function Kidnap.placerLeft(contractId)
    local required = tonumber(Config.Kidnap.CountdownSeconds) or 0
    local most
    for _, state in pairs(active) do
        if state.contractId == contractId then
            local left = math.max(0, required - math.floor(state.elapsedMs / 1000))
            if not most or left > most then most = left end
        end
    end
    if not most then return nil end
    return math.ceil(most / 5) * 5
end

--- When this hitman's running countdown on this contract was armed, on
--- os.time(), or nil when none is running. Asked by Bailout.finishing, which
--- holds a closing contract open only for a handover armed in time.
function Kidnap.armedAt(contractId, hitmanCid)
    local state = active[key(contractId, hitmanCid)]
    return state and state.armedAt or nil
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
--- command would hand the hitman a delivery they had not finished.
---@return integer cleared
function Kidnap.clearRearmCooldowns()
    local cleared = 0
    for k in pairs(lastFailure) do
        lastFailure[k] = nil
        cleared = cleared + 1
    end
    lastFar = {}
    return cleared
end

--- A hitman who disconnects takes their countdowns with them.
---
--- Their re-arm cooldowns stay. Releasing them here meant a hitman refused a
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
        if state.hitmanCid == cid then
            active[k] = nil
            lastFailure[k] = now
            -- A countdown ended this way left only its kidnap_armed row, so
            -- nothing on the record said how it ended.
            Audit.action('kidnap_cancelled', cid, state.contractId, { reason = 'hitman_dropped' })
        end
    end
    local cooldown = Config.Kidnap.RearmCooldownSeconds or 0
    for k, at in pairs(lastFailure) do
        if now - at >= cooldown then lastFailure[k] = nil end
    end
    for k, at in pairs(lastFar) do
        if now - at >= FAR_RETRY_SECONDS then lastFar[k] = nil end
    end
end

--- Record a party leaving the city in the middle of a handover, for staff
--- (spec §14.42): whose countdown, which party, and how far it had run. A
--- target or a client who dropped at second 28 left only kidnap_failed
--- { party_offline }, which said neither who went nor when. A record and no
--- more: whether it was combat-logging is a ruling staff make from it, and
--- an automatic penalty would punish a real crash. Called before anything
--- is cleared (Bridges.onPlayerDropped), once per countdown and party.
---@param cid string the player who dropped
---@return integer recorded
function Kidnap.partyDropped(cid)
    local recorded = 0
    for _, state in pairs(active) do
        local role = (state.hitmanCid == cid and 'hitman')
            or (state.targetCid == cid and 'target')
            or (state.creatorCid == cid and 'placer') or nil
        state.dropped = state.dropped or {}
        if role and not state.dropped[cid] then
            state.dropped[cid] = true
            Audit.action('kidnap_party_dropped', cid, state.contractId, {
                role = role, elapsedMs = state.elapsedMs, graceUsedMs = state.graceUsedMs,
            })
            recorded = recorded + 1
        end
    end
    return recorded
end

function Kidnap.clearContract(contractId)
    for k, state in pairs(active) do
        if state.contractId == contractId then
            active[k] = nil
            -- Resolved underneath a countdown in progress: cancelled,
            -- expired, bought out, or the last payout collected by somebody
            -- else. The hitman holding the target is the one person who
            -- needs to know, and was told nothing.
            remember(k, { outcome = 'closed' })
            Notify.toCitizen(state.hitmanCid, L('completion_kidnap.handover_ended'),
                L('completion_kidnap.the_contract_closed_before_the_handover'),
                { bypassBudget = true })
        end
    end
    for k in pairs(lastFailure) do
        if k:sub(1, #contractId + 1) == contractId .. ':' then lastFailure[k] = nil end
    end
    for k in pairs(lastFar) do
        if k:sub(1, #contractId + 1) == contractId .. ':' then lastFar[k] = nil end
    end
end

--- When the shared thread last finished a pass (os.time()), and whether it
--- is running at all: /ch-diag's loops line.
local lastPass = nil

---@return integer|nil at the last finished pass, nil before the first
---@return boolean running whether a countdown keeps the thread going
function Kidnap.lastPassAt()
    return lastPass, running == true
end

--- Start the shared thread. Idempotent: only one ever runs.
function Kidnap.start()
    if running then return end
    running = true
    CreateThread(function()
        local last = Util.monotonicMs()
        while true do
            Wait(Config.Kidnap.TickMs)
            if Kidnap.activeCount() == 0 then
                running = false
                return
            end
            -- Advanced by the time since the last pass, not by TickMs: a
            -- pass that waited on the database (each reads its contract)
            -- made every countdown run slow by however long it waited. At
            -- least TickMs, and at most three of them, so a hitch of the
            -- whole server is not counted as time held.
            local now = Util.monotonicMs()
            local tick = Config.Kidnap.TickMs
            local delta = math.max(tick, math.min(now - last, tick * 3))
            last = now
            -- One throw — a storage read on a connection that dropped, an
            -- inventory export raising inside the payout — ended this
            -- thread with `running` still set. No handover on the server
            -- moved again until a restart, and every one armed after it said
            -- it was armed and sat at nought. The maintenance tick and the
            -- condition sampler are wrapped for the same reason.
            local ok, err = pcall(Kidnap.tick, delta)
            lastPass = os.time()
            if not ok then
                Log.debug(('handover tick failed: %s'):format(tostring(err)))
            end
        end
    end)
end

return Kidnap
end)
