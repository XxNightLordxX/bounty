--- Contract lifecycle: creation, acceptance, state machine, limits.
---
--- Every transition goes through Contracts.transition, which is a guarded
--- compare-and-set against the stored state (§9.7, §9.10). Two actions racing
--- on one contract cannot both win.

local Util = require_shared('util')

local Contracts = {}

local Storage, Escrow, Identity, Audit, Notify, Progression, Death

function Contracts.init(deps)
    Storage     = deps.storage
    Escrow      = deps.escrow
    Identity    = deps.identity
    Audit       = deps.audit
    Notify      = deps.notify
    Progression = deps.progression
    Death       = deps.death
end

local LIVE_STATES = { [CB.STATE.ACTIVE] = true, [CB.STATE.ACCEPTED] = true, [CB.STATE.COMPLETING] = true }

--------------------------------------------------------------------------
-- State machine
--------------------------------------------------------------------------

--- Move a contract between states, rejecting any transition not declared in
--- CB.TRANSITIONS and any transition out of a terminal state.
---@return boolean ok
function Contracts.transition(contractId, expected, next_, reason)
    if CB.TERMINAL[expected] then return false end
    local allowed = CB.TRANSITIONS[expected]
    if not allowed or not allowed[next_] then return false end

    local ok = Storage.compareSetContractState(contractId, expected, next_)
    if ok then
        Audit.action('state_change', nil, contractId, { from = expected, to = next_, reason = reason })
    end
    return ok
end

--- Settle every hunter's stake on a contract that is ending.
---
--- Called from every terminal path. `forfeit` is true only when the ending
--- is the hunter's failure — an expiry while they still held it.
---@param contractId string
---@param creatorCid string
---@param forfeit boolean
local function settleStakes(contractId, creatorCid, forfeit)
    local hunters = Storage.readHunters(contractId)
    for i = 1, #hunters do
        local hunter = hunters[i]
        local toCreator = forfeit and hunter.state == 'active'
        Escrow.release(contractId,
            toCreator and creatorCid or hunter.hunter_cid,
            { portion = CB.PORTION.STAKE, staker = hunter.hunter_cid },
            toCreator and 'penalty_forfeited' or 'stake_returned')
    end
end

--- Everything that must happen exactly once when a contract ends, whichever
--- path got it there. Routing every terminal transition through here is what
--- stops a new path forgetting a step — the completion path already did.
---@param contractId string
---@param contract table
---@param forfeitStakes boolean
local function finalise(contractId, contract, forfeitStakes)
    settleStakes(contractId, contract.creator_cid, forfeitStakes)

    -- Anything still held — a top-up on a slot nobody claimed, an odd line
    -- from an amendment — goes back to the creator while it is still
    -- reachable.
    Escrow.release(contractId, contract.creator_cid, nil, 'unclaimed_remainder')

    Notify.clearContract(contractId)
    if Contracts.onResolved then Contracts.onResolved(contractId) end
end

--------------------------------------------------------------------------
-- Eligibility
--------------------------------------------------------------------------

--- All the reasons a contract may not be created, checked server-side before
--- a single coin moves (§13.1, §12.5).
---@return boolean ok
---@return string|nil err
function Contracts.canCreate(actor, targetActor)
    if not targetActor then return false, CB.ERR.NOT_FOUND end

    -- The three parties must be distinct people, not just distinct characters.
    if targetActor.cid == actor.cid then return false, CB.ERR.SELF_TARGET end
    if Config.AntiCollusion.BlockSameAccount and targetActor.account == actor.account then
        return false, CB.ERR.SAME_ACCOUNT
    end

    if Identity.isProtectedJob(targetActor.job) and not Config.Targeting.AllowProtectedJobTargets then
        return false, CB.ERR.TARGET_PROTECTED
    end

    local contracts = Storage.allContracts()
    local byCreator, byTarget = 0, 0
    local now = os.time()

    for i = 1, #contracts do
        local c = contracts[i]
        if LIVE_STATES[c.state] then
            if c.creator_cid == actor.cid then byCreator = byCreator + 1 end
            if c.target_cid == targetActor.cid then byTarget = byTarget + 1 end
        else
            -- Cooldowns after a resolution, so a target cannot be re-listed
            -- the moment their last contract closes (§12.5).
            if c.target_cid == targetActor.cid and c.resolved_at then
                local since = now - c.resolved_at
                if since < Config.Limits.TargetCooldownAfterResolveSeconds then
                    return false, CB.ERR.TARGET_PROTECTED
                end
                if c.creator_cid == actor.cid and since < Config.Limits.SameCreatorSameTargetCooldownSeconds then
                    return false, CB.ERR.RATE_LIMITED
                end
            end
        end
    end

    -- Cancelling and re-listing is otherwise free, which makes the board
    -- spammable without ever paying anything (§12.4).
    if Config.Amendments.CancelCooldownSeconds > 0 then
        for i = 1, #contracts do
            local c = contracts[i]
            if c.creator_cid == actor.cid and c.state == CB.STATE.CANCELLED and c.resolved_at
                and (now - c.resolved_at) < Config.Amendments.CancelCooldownSeconds then
                return false, CB.ERR.RATE_LIMITED
            end
        end
    end

    if byCreator >= Config.Limits.MaxActiveContractsPerCreator then return false, CB.ERR.LIMIT_REACHED end
    if byTarget >= Config.Limits.MaxActiveContractsPerTarget then return false, CB.ERR.TARGET_PROTECTED end

    -- New and freshly-connected players are not fair game.
    if Contracts.isImmune(targetActor) then return false, CB.ERR.TARGET_PROTECTED end

    return true
end

--- Playtime and session immunity (§14.19). Fails closed: an unresolvable
--- playtime counts as below every minimum.
function Contracts.isImmune(targetActor)
    local hours = targetActor.player and targetActor.player._playtimeHours
    local session = targetActor.player and targetActor.player._sessionMinutes

    if hours == nil or session == nil then
        return Config.Immunity.FailClosed
    end
    if hours < Config.Immunity.MinTargetPlaytimeHours then return true end
    if session < Config.Immunity.MinTargetSessionMinutes then return true end
    return false
end

--------------------------------------------------------------------------
-- Creation
--------------------------------------------------------------------------

--- Create a contract and take escrow atomically. Nothing is charged unless
--- the whole thing succeeds.
---@return table|nil contract
---@return string|nil err
function Contracts.create(actor, req)
    local targetActor = Identity.byCitizenId(req.targetCid)
    local ok, err = Contracts.canCreate(actor, targetActor)
    if not ok then return nil, err end

    local reason
    if Config.Reason.Mode == 'preset' then
        local index = Util.toPositive(req.reasonPreset, #Config.Reason.Presets)
        if not index then return nil, CB.ERR.INVALID_INPUT end
        reason = Config.Reason.Presets[index]
    elseif Config.Reason.Mode == 'freetext' then
        reason = Util.sanitizeText(req.reason, Config.Reason.MaxLength)
        if not reason then return nil, CB.ERR.INVALID_INPUT end
        if Util.digitCount(reason) > Config.Reason.MaxDigits then return nil, CB.ERR.INVALID_INPUT end
        for _, pattern in ipairs(Config.Reason.PatternDenylist) do
            if reason:lower():find(pattern) then return nil, CB.ERR.INVALID_INPUT end
        end
        local blocked = exports['lb-phone']:ContainsBlacklistedWord(actor.source, reason)
        if blocked then return nil, CB.ERR.INVALID_INPUT end
    else
        reason = ''
    end

    local mode = req.mode == CB.MODE.COMPETITIVE and CB.MODE.COMPETITIVE or CB.MODE.EXCLUSIVE

    local lines, slotCount
    lines, err, slotCount = Escrow.validate(actor, req.reward)
    if not lines then return nil, err end

    -- Bailout premium is clamped to a multiple of the money escrow so it
    -- cannot become an uncapped transfer rail between two players (§14.16).
    -- The premium is clamped, not rejected: a creator who types a silly
    -- number gets the ceiling, not a silently disabled bailout. The clamp is
    -- what stops the bailout becoming an uncapped transfer rail (§14.16).
    local bailout = 0
    if Config.Bailout.Enabled and req.bailoutAmount then
        bailout = Util.toPositive(req.bailoutAmount) or 0
        if bailout > 0 then
            local moneyValue = 0
            for i = 1, #lines do
                if CB.MONEY_SOURCES[lines[i].source] then moneyValue = moneyValue + lines[i].amount end
            end
            -- A bailout needs a money escrow to be a multiple of; an
            -- items-only contract cannot offer one.
            if moneyValue == 0 then return nil, CB.ERR.INVALID_INPUT end

            local min = math.floor(moneyValue * Config.Bailout.MinMultiplier)
            local max = math.floor(moneyValue * Config.Bailout.MaxMultiplier)
            if bailout < min then bailout = min end
            if bailout > max then bailout = max end
            if bailout > Config.Bailout.AbsoluteMax then bailout = Config.Bailout.AbsoluteMax end
        end
    end

    local bonusPercent = Util.toCount(req.bonusPercent, Config.Bonus.maxPercent) or 0

    local now = os.time()
    local contract = {
        id            = Storage.nextId('ct'),
        creator_cid   = actor.cid,
        creator_account = actor.account,
        creator_name  = actor.name,
        target_cid    = targetActor.cid,
        target_name   = targetActor.name,
        target_protected = Identity.isProtectedJob(targetActor.job),
        target_job    = targetActor.job and targetActor.job.name or nil,
        reason        = reason,
        mode          = mode,
        state         = CB.STATE.ACTIVE,
        anon_creator  = req.anonymous == true,
        bonus_percent = bonusPercent,
        payout_slots  = slotCount,
        slots_claimed = 0,
        next_slot     = 1,
        bailout_amount = bailout,
        penalty_amount = Util.toCount(req.penaltyAmount, Config.MaxContractValue) or 0,
        created_at    = now,
        deadline_at   = now + Config.Limits.DefaultDeadlineSeconds,
        expires_at    = now + Config.Limits.ContractLifetimeSeconds,
        paused_ms     = 0,
    }

    -- Escrow is taken before the contract is persisted, so a failure leaves
    -- no row behind at all rather than a cancelled shell that still counts
    -- against the creator's cooldowns.
    local took
    took, err = Escrow.take(actor, contract.id, lines)
    if not took then return nil, err end

    if not Storage.writeContract(contract) then
        -- The contract could not be stored, so the escrow must come back.
        Escrow.release(contract.id, actor.cid, nil, 'contract_write_failed')
        return nil, CB.ERR.BAD_STATE
    end

    Audit.action('contract_created', actor.cid, contract.id, {
        target = contract.target_cid, mode = mode, anonymous = contract.anon_creator,
        reason = Config.Audit.LogReasonText and reason or nil,
    })

    if Progression then Progression.onContractPlaced(actor.cid) end

    Notify.contractCreated(contract, targetActor)
    return contract
end

--------------------------------------------------------------------------
-- Acceptance
--------------------------------------------------------------------------

--- Accept a contract. Conditional write: in exclusive mode the ACTIVE →
--- ACCEPTED transition is what reserves it, so two hunters racing produce
--- exactly one winner (§14.34).
---@return boolean ok
---@return string|nil err
function Contracts.accept(actor, contractId, anonymous)
    contractId = Util.toId(contractId)
    if not contractId then return false, CB.ERR.INVALID_INPUT end

    local contract = Storage.readContract(contractId)
    if not contract then return false, CB.ERR.NOT_FOUND end
    if contract.state ~= CB.STATE.ACTIVE and contract.state ~= CB.STATE.ACCEPTED then
        return false, CB.ERR.BAD_STATE
    end

    -- A player may not hunt themselves, their own contract, or a contract
    -- created by another of their own characters (§13.1).
    if contract.target_cid == actor.cid then return false, CB.ERR.SELF_TARGET end
    if contract.creator_cid == actor.cid then return false, CB.ERR.SELF_ACCEPT end
    if Config.AntiCollusion.BlockSameAccount then
        if contract.creator_account == actor.account then return false, CB.ERR.SAME_ACCOUNT end
        local targetActor = Identity.byCitizenId(contract.target_cid)
        if targetActor and targetActor.account == actor.account then return false, CB.ERR.SAME_ACCOUNT end
    end

    if Storage.readHunter(contractId, actor.cid) then return false, CB.ERR.BAD_STATE end

    local held = Storage.countHunterContracts(actor.cid, LIVE_STATES)
    if held >= Config.Limits.MaxAcceptedPerHunter then return false, CB.ERR.LIMIT_REACHED end

    local existing = Storage.readHunters(contractId)
    local activeCount = 0
    for i = 1, #existing do
        if existing[i].state == 'active' then activeCount = activeCount + 1 end
    end

    -- Aliases are numbered from everyone who has ever held this contract,
    -- not from the live count: reusing "Operative #2" after someone abandons
    -- makes two different people indistinguishable in the creator's threads.
    local aliasNumber = #existing + 1

    if contract.mode == CB.MODE.EXCLUSIVE then
        if activeCount > 0 then return false, CB.ERR.BAD_STATE end
        if not Contracts.transition(contractId, CB.STATE.ACTIVE, CB.STATE.ACCEPTED, 'accepted') then
            return false, CB.ERR.LOCKED
        end
    else
        if activeCount >= Config.Limits.MaxHuntersPerContract then return false, CB.ERR.LIMIT_REACHED end
        if contract.state == CB.STATE.ACTIVE then
            Contracts.transition(contractId, CB.STATE.ACTIVE, CB.STATE.ACCEPTED, 'accepted')
        end
    end

    -- The failure penalty is staked here, at acceptance, or not at all: a
    -- penalty that is only charged after a failure is a penalty the hunter
    -- can walk away from (§3.6). The hunter is told the amount before this
    -- point, and refusing to stake simply refuses the contract.
    local stake = contract.penalty_amount or 0
    if stake > 0 then
        local account = (actor.player.Functions.GetMoney('bank') or 0) >= stake and 'bank' or 'cash'
        if (actor.player.Functions.GetMoney(account) or 0) < stake then
            -- Undo the state change made for an exclusive acceptance.
            if contract.mode == CB.MODE.EXCLUSIVE then
                Contracts.transition(contractId, CB.STATE.ACCEPTED, CB.STATE.ACTIVE, 'stake_failed')
            end
            return false, CB.ERR.INSUFFICIENT
        end

        local ok = Escrow.take(actor, contractId, { {
            slot = 0, portion = CB.PORTION.STAKE, source = account,
            amount = stake, staker = actor.cid,
        } })
        if not ok then
            if contract.mode == CB.MODE.EXCLUSIVE then
                Contracts.transition(contractId, CB.STATE.ACCEPTED, CB.STATE.ACTIVE, 'stake_failed')
            end
            return false, CB.ERR.INSUFFICIENT
        end
        Audit.financial('stake_taken', actor.cid, contractId, { amount = stake })
    end

    local record = {
        id            = Storage.nextId('hn'),
        contract_id   = contractId,
        hunter_cid    = actor.cid,
        hunter_account = actor.account,
        hunter_name   = actor.name,
        alias         = 'Operative #' .. tostring(aliasNumber),
        anon          = anonymous == true,
        accepted_at   = os.time(),
        state         = 'active',
    }
    Storage.addHunter(record)

    -- Start watching the target's health now, so damage claimed against
    -- them from this point can be corroborated (§14.2).
    if Death then
        local targetActor = Identity.byCitizenId(contract.target_cid)
        if targetActor then Death.watch(targetActor.cid, targetActor.source) end
    end

    Audit.action('contract_accepted', actor.cid, contractId, { anonymous = record.anon })
    Notify.contractAccepted(contract, record, activeCount + 1)

    return true, nil, record
end

--- A hunter walks away. The contract reverts to open rather than resolving,
--- and the failure penalty applies if one was staked.
function Contracts.abandon(actor, contractId)
    local contract = Storage.readContract(contractId)
    if not contract then return false, CB.ERR.NOT_FOUND end

    if CB.TERMINAL[contract.state] or contract.state == CB.STATE.COMPLETING then
        return false, CB.ERR.BAD_STATE
    end

    local hunter = Storage.readHunter(contractId, actor.cid)
    if not hunter or hunter.state ~= 'active' then return false, CB.ERR.NOT_PARTICIPANT end

    Storage.updateHunter(hunter.id, { state = 'abandoned', left_at = os.time() })

    -- Walking away from an accepted contract forfeits the stake to the
    -- creator. That is what the penalty is for.
    local forfeited = Escrow.release(contractId, contract.creator_cid,
        { portion = CB.PORTION.STAKE, staker = actor.cid }, 'penalty_forfeited')
    if forfeited then
        Audit.financial('stake_forfeited', actor.cid, contractId, {})
    end

    local remaining = 0
    local hunters = Storage.readHunters(contractId)
    for i = 1, #hunters do
        if hunters[i].state == 'active' then remaining = remaining + 1 end
    end

    -- With nobody left holding it, an exclusive contract goes back on the
    -- board. A contract mid-settlement is left alone: claimSlot owns that
    -- transition and will land it in ACCEPTED or COMPLETED itself.
    if remaining == 0 and contract.state == CB.STATE.ACCEPTED then
        Contracts.transition(contractId, CB.STATE.ACCEPTED, CB.STATE.ACTIVE, 'abandoned')
    end

    if Progression then Progression.onFailed(actor.cid) end

    Audit.action('contract_abandoned', actor.cid, contractId, {})
    return true
end

--------------------------------------------------------------------------
-- Slot claiming (§3.5)
--------------------------------------------------------------------------

--- Claim the next unclaimed payout slot for a hunter.
---
--- This is the single point where a fulfilment turns into money. It takes the
--- contract's lock, so two hunters completing at the same moment cannot both
--- claim the same slot (§9.7), and it releases only that slot's lines.
---
---@param contractId string
---@param hunterCid string
---@param fulfilment string CB.FULFILMENT.*
---@return boolean ok
---@return string|nil err
---@return table|nil result
function Contracts.claimSlot(contractId, hunterCid, fulfilment)
    local contract = Storage.readContract(contractId)
    if not contract then return false, CB.ERR.NOT_FOUND end
    if contract.state ~= CB.STATE.ACCEPTED then return false, CB.ERR.BAD_STATE end

    local hunter = Storage.readHunter(contractId, hunterCid)
    if not hunter or hunter.state ~= 'active' then return false, CB.ERR.NOT_PARTICIPANT end

    -- The same hunter may not collect two slots back to back; without this a
    -- multi-slot contract is a respawn-camping machine (§3.5).
    if hunter.last_claim_at and (os.time() - hunter.last_claim_at) < Config.Limits.SlotCooldownSeconds then
        return false, CB.ERR.RATE_LIMITED
    end

    local slot = contract.next_slot or 1
    if slot > (contract.payout_slots or 1) then return false, CB.ERR.ALREADY_SETTLED end

    -- Eligibility is re-checked here, not just at creation: a multi-slot
    -- contract is claimed repeatedly over time, and the target's post-respawn
    -- protection has to hold for every claim (§14.39).
    local targetActor = Identity.byCitizenId(contract.target_cid)
    if targetActor and Contracts.isImmune(targetActor) then
        return false, CB.ERR.TARGET_PROTECTED
    end

    -- Take the contract's lock for the duration of the settlement, so the
    -- slot cannot be claimed twice (§14.3).
    if not Contracts.transition(contractId, CB.STATE.ACCEPTED, CB.STATE.COMPLETING, 'claiming_slot') then
        return false, CB.ERR.LOCKED
    end

    -- A kidnapping releases the slot's baseline and its bonus; an elimination
    -- releases the baseline only, and the bonus returns to the creator.
    local _, baseline = Escrow.release(contractId, hunterCid, { slot = slot, portion = CB.PORTION.BASELINE }, 'payout_baseline')
    local bonus = { settled = 0, pending = 0 }
    if fulfilment == CB.FULFILMENT.KIDNAPPING then
        _, bonus = Escrow.release(contractId, hunterCid, { slot = slot, portion = CB.PORTION.BONUS }, 'payout_bonus')
    else
        Escrow.release(contractId, contract.creator_cid, { slot = slot, portion = CB.PORTION.BONUS }, 'bonus_unearned')
    end

    contract.slots_claimed = (contract.slots_claimed or 0) + 1
    contract.next_slot = slot + 1
    Storage.writeContract(contract)
    Storage.updateHunter(hunter.id, { last_claim_at = os.time(), claims = (hunter.claims or 0) + 1 })

    -- The stake is NOT returned here. On a multi-slot contract the hunter
    -- is still on the hook for the slots that remain, and handing it back
    -- after the first claim would let them collect a payout, recover the
    -- penalty and walk away at no cost. Stakes settle when the contract
    -- ends, in finalise() and resolve().

    if Progression then Progression.onCompleted(hunterCid, fulfilment) end

    Audit.financial('slot_claimed', hunterCid, contractId, {
        slot = slot, fulfilment = fulfilment,
        settled = baseline.settled + bonus.settled,
        pending = baseline.pending + bonus.pending,
    })

    local exhausted = contract.next_slot > (contract.payout_slots or 1)
    if exhausted then
        -- Last slot: the contract is finished for everyone. Every other
        -- hunter's stake comes back and any unclaimed escrow returns to the
        -- creator, while the contract is still non-terminal and reachable.
        finalise(contractId, contract, false)

        contract.resolved_at = os.time()
        contract.resolution = 'completed'
        Storage.writeContract(contract)
        Contracts.transition(contractId, CB.STATE.COMPLETING, CB.STATE.COMPLETED, 'completed')
    else
        -- Slots remain: the contract goes back to accepted and stays live.
        Contracts.transition(contractId, CB.STATE.COMPLETING, CB.STATE.ACCEPTED, 'slot_claimed')
    end

    return true, nil, {
        slot = slot,
        remaining = math.max(0, (contract.payout_slots or 1) - contract.slots_claimed),
        exhausted = exhausted,
        settled = baseline.settled + bonus.settled,
        pending = baseline.pending + bonus.pending,
    }
end

--------------------------------------------------------------------------
-- Resolution
--------------------------------------------------------------------------

--- Resolve a contract to a terminal state and release escrow exactly once.
--- Every terminal path goes through here so no path can forget the release.
---@param contractId string
---@param terminal string
---@param recipientCid string who receives the escrow
---@param filter table|string|nil
---@param reason string
function Contracts.resolve(contractId, terminal, recipientCid, filter, reason)
    local contract = Storage.readContract(contractId)
    if not contract then return false, CB.ERR.NOT_FOUND end
    if CB.TERMINAL[contract.state] then return false, CB.ERR.ALREADY_SETTLED end

    if not Contracts.transition(contractId, contract.state, terminal, reason) then
        return false, CB.ERR.LOCKED
    end

    contract.resolved_at = os.time()
    contract.resolution = reason
    Storage.writeContract(contract)

    -- Stakes resolve by why the contract ended: an expiry is the hunter
    -- failing, so the creator keeps it; anything else returns it.
    local hunters = Storage.readHunters(contractId)
    for i = 1, #hunters do
        local hunter = hunters[i]
        local toCreator = (terminal == CB.STATE.EXPIRED) and hunter.state == 'active'
        Escrow.release(contractId,
            toCreator and contract.creator_cid or hunter.hunter_cid,
            { portion = CB.PORTION.STAKE, staker = hunter.hunter_cid },
            toCreator and 'penalty_forfeited' or 'stake_returned')
    end

    -- A target who outlived the contract has something to show for it.
    if Progression and (terminal == CB.STATE.BAILED_OUT or terminal == CB.STATE.EXPIRED) then
        Progression.onSurvived(contract.target_cid)
    end

    -- Per-contract caches are released here rather than growing for the
    -- life of the process.
    Notify.clearContract(contractId)
    if Contracts.onResolved then Contracts.onResolved(contractId) end

    local _, result = Escrow.release(contractId, recipientCid, filter, reason)

    -- Anything the winner did not take (the unpaid bonus on an elimination,
    -- for instance) goes back to the creator rather than staying locked up.
    if filter ~= nil then
        Escrow.release(contractId, contract.creator_cid, nil, reason .. '_remainder')
    end

    return true, result
end

return Contracts
