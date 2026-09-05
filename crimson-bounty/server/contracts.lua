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
--- The capability to end a contract. A private table, so holding it means
--- being inside this module — a boolean flag would be something any caller
--- could simply pass.
local SETTLING = {}

--- CB.TRANSITIONS and any transition out of a terminal state.
---
--- Moving a contract INTO a terminal state additionally requires the
--- settling token, which only `resolve` and `claimSlot` hold. Ending a
--- contract means settling stakes, returning the remainder and nudging the
--- parties; a path that flipped the state without doing those stranded a
--- hunter's stake once already. The token makes that mistake unreachable
--- rather than merely documented: a new path cannot end a contract without
--- going through one of the two functions that finish the job.
---@param settling table|nil the private token, for a terminal target only
---@return boolean ok
function Contracts.transition(contractId, expected, next_, reason, settling)
    if CB.TERMINAL[expected] then return false end
    if CB.TERMINAL[next_] and settling ~= SETTLING then return false end
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
    -- Read before the stakes settle, while the hunter records still say who
    -- was on this contract: they are who needs their card to change.
    local hunterCids = {}
    local hunters = Storage.readHunters(contractId)
    for i = 1, #hunters do hunterCids[#hunterCids + 1] = hunters[i].hunter_cid end

    settleStakes(contractId, contract.creator_cid, forfeitStakes)

    -- Anything still held — a top-up on a slot nobody claimed, an odd line
    -- from an amendment, the unpaid bonus on an elimination — goes back to
    -- the creator while it is still reachable.
    Escrow.release(contractId, contract.creator_cid, nil, 'unclaimed_remainder')

    -- Everyone whose card just changed. Read from storage rather than the
    -- caller's copy, so the state the app fetches is the settled one.
    local settled = Storage.readContract(contractId)
    Notify.pushParties(settled or contract, hunterCids, (settled or contract).state)

    Notify.clearContract(contractId)
    if Contracts.onResolved then Contracts.onResolved(contractId) end
    if Contracts.onChanged then Contracts.onChanged() end
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
    if Config.AntiCollusion.BlockSameAccount
        and Identity.sameAccount(targetActor.account, actor.account) then
        return false, CB.ERR.SAME_ACCOUNT
    end

    if Identity.isProtectedJob(targetActor.job) and not Config.Targeting.AllowProtectedJobTargets then
        return false, CB.ERR.TARGET_PROTECTED
    end

    -- Only the contracts these two are involved in matter here, so this asks
    -- for those rather than for the whole table.
    local contracts = Storage.contractsBy(actor.cid)
    local naming = Storage.contractsNaming(targetActor.cid)
    for i = 1, #naming do contracts[#contracts + 1] = naming[i] end

    local byCreator, byTarget = 0, 0
    local now = os.time()
    local counted = {}

    for i = 1, #contracts do
        local c = contracts[i]
        if counted[c.id] then goto continue end
        counted[c.id] = true
        if LIVE_STATES[c.state] then
            if c.creator_cid == actor.cid then byCreator = byCreator + 1 end
            if c.target_cid == targetActor.cid then byTarget = byTarget + 1 end
        else
            -- Cooldowns after a resolution, so a target cannot be re-listed
            -- the moment their last contract closes (§12.5).
            if c.target_cid == targetActor.cid and c.resolved_at then
                -- Buying your way out earns a longer breather than an
                -- ordinary resolution: otherwise a creator simply re-lists
                -- and the target pays again.
                local since = now - c.resolved_at
                local cooldown = (c.state == CB.STATE.BAILED_OUT)
                    and Config.Immunity.AfterBailoutSeconds
                    or Config.Limits.TargetCooldownAfterResolveSeconds
                if since < cooldown then
                    return false, CB.ERR.TARGET_PROTECTED
                end
                if c.creator_cid == actor.cid and since < Config.Limits.SameCreatorSameTargetCooldownSeconds then
                    return false, CB.ERR.RATE_LIMITED
                end
            end
        end
        ::continue::
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

--- Playtime, session and post-respawn immunity (§14.19, §14.39).
---
--- A check we can perform fails closed. A check we have no data for does
--- NOT: an unresolvable playtime once made every player on the server
--- immune, which silently stopped every contract and every payout. The
--- absence of a provider is a configuration problem to be reported at boot,
--- not a reason to refuse everything.
---
---@param targetActor table
---@param opts table|nil { deathAt = ms } when judging a claim on a specific death
function Contracts.isImmune(targetActor, opts)
    -- Session length is measured by this resource, so it is always known
    -- for anyone who connected while it was running.
    local session = Identity.sessionMinutes(targetActor.cid)
    if session ~= nil and session < Config.Immunity.MinTargetSessionMinutes then
        return true
    end

    local hours = Identity.playtimeHours(targetActor)
    if hours ~= nil and hours < Config.Immunity.MinTargetPlaytimeHours then
        return true
    end

    -- Someone who just got back up is not immediately fair game again:
    -- without this a multi-slot contract becomes respawn camping.
    --
    -- A claim on a death that happened BEFORE the respawn is exempt: the
    -- hunter earned it while the target was still down, and the target
    -- pressing respawn must not take it away (§7.4 proof window).
    if Death and (Config.Immunity.PostRespawnSeconds or 0) > 0 then
        local since = Death.sinceRespawn(targetActor.cid)
        if since and since < Config.Immunity.PostRespawnSeconds then
            local respawnedAgo = since
            local deathAgo = opts and opts.deathAt
                and ((Util.monotonicMs() - opts.deathAt) / 1000) or nil
            local claimPredatesRespawn = deathAgo ~= nil and deathAgo > respawnedAgo
            if not claimPredatesRespawn then return true end
        end
    end

    return false
end

--------------------------------------------------------------------------
-- Creation
--------------------------------------------------------------------------

--- Create a contract and take escrow atomically. Nothing is charged unless
--- the whole thing succeeds.
---@return table|nil contract
---@return string|nil err
--- Put an anonymity fee back after a failed creation.
---
--- The last rollback in the chain, where there is nothing else left to undo.
--- AddMoney can refuse — an account qbx_core will not credit, or a balance
--- ceiling a server has patched in — and losing the fee quietly is the one
--- thing that must not happen here: the audit row is what tells staff to
--- return it by hand.
---@param actor table
---@param contractId string
---@param anonymous boolean whether the fee was charged at all
local function refundAnonymityFee(actor, contractId, anonymous)
    local fee = Config.Anonymity.CreatorFee or 0
    if not anonymous or fee <= 0 then return true end

    local account = Config.Anonymity.FeeAccount or 'bank'
    if actor.player.Functions.AddMoney(account, fee) then return true end

    Audit.financial('anonymity_fee_refund_failed', actor.cid, contractId,
        { amount = fee, account = account })
    return false
end

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

    local bonusPercent = Util.toCount(req.bonusPercent, Config.Bonus.maxPercent) or 0

    -- The bonus is escrowed at creation like everything else, so a creator
    -- cannot promise a live-delivery premium they have not surrendered.
    local lines, slotCount
    lines, err, slotCount = Escrow.validate(actor, req.reward, bonusPercent)
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

    local contractId = Util.mintId(Storage.nextId, 'ct', Storage.readContract)
    if not contractId then
        -- Every id on offer belongs to a contract that already exists.
        -- Refusing costs this creator one attempt; writing would rewrite
        -- somebody else's contract under them.
        Audit.rejected('contract_id_exhausted', actor.cid, nil, {})
        return nil, CB.ERR.BAD_STATE
    end

    local now = os.time()
    local contract = {
        id            = contractId,
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

    -- Anonymity is free by default; where a server charges for it, the fee
    -- is taken before the escrow so a creator who cannot afford it is
    -- refused rather than half-charged (§4).
    if contract.anon_creator and (Config.Anonymity.CreatorFee or 0) > 0 then
        local account = Config.Anonymity.FeeAccount or 'bank'
        if not actor.player.Functions.RemoveMoney(account, Config.Anonymity.CreatorFee) then
            return nil, CB.ERR.INSUFFICIENT
        end
        Audit.financial('anonymity_fee', actor.cid, contract.id,
            { amount = Config.Anonymity.CreatorFee, role = 'creator' })
    end

    -- Escrow is taken before the contract is persisted, so a failure leaves
    -- no row behind at all rather than a cancelled shell that still counts
    -- against the creator's cooldowns.
    local took
    took, err = Escrow.take(actor, contract.id, lines)
    if not took then
        -- Put the anonymity fee back: nothing else was charged.
        refundAnonymityFee(actor, contract.id, contract.anon_creator)
        return nil, err
    end

    if not Storage.writeContract(contract) then
        -- The contract could not be stored, so everything taken comes back:
        -- the escrow, and the anonymity fee charged before it.
        Escrow.release(contract.id, actor.cid, nil, 'contract_write_failed')
        refundAnonymityFee(actor, contract.id, contract.anon_creator)
        return nil, CB.ERR.BAD_STATE
    end

    Audit.action('contract_created', actor.cid, contract.id, {
        target = contract.target_cid, mode = mode, anonymous = contract.anon_creator,
        reason = Config.Audit.LogReasonText and reason or nil,
    })

    if Progression then Progression.onContractPlaced(actor.cid) end

    Notify.contractCreated(contract, targetActor)

    -- A new contract can hold the earliest deadline on the server, and the
    -- expiry pass is allowed to skip ahead when it believes nothing is due.
    if Contracts.onChanged then Contracts.onChanged() end

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
        if Identity.sameAccount(contract.creator_account, actor.account) then
            return false, CB.ERR.SAME_ACCOUNT
        end
        local targetActor = Identity.byCitizenId(contract.target_cid)
        if targetActor and Identity.sameAccount(targetActor.account, actor.account) then
            return false, CB.ERR.SAME_ACCOUNT
        end
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

    -- Confirmed free before the row is written. The stake above is already
    -- taken by this point, and addHunter is a plain insert: an id in use is
    -- a duplicate-key error thrown out of here with the money gone and no
    -- hunter row to say whose it was, so nothing would ever return it.
    local hunterId = Util.mintId(Storage.nextId, 'hn', Storage.readHunterById)
    if not hunterId then
        if stake > 0 then
            Escrow.release(contractId, actor.cid,
                { portion = CB.PORTION.STAKE, staker = actor.cid }, 'hunter_id_exhausted')
        end
        if contract.mode == CB.MODE.EXCLUSIVE then
            Contracts.transition(contractId, CB.STATE.ACCEPTED, CB.STATE.ACTIVE, 'accept_failed')
        end
        Audit.rejected('hunter_id_exhausted', actor.cid, contractId, {})
        return false, CB.ERR.BAD_STATE
    end

    local record = {
        id            = hunterId,
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

    -- The anonymity fee is taken last, after the stake and the record, so
    -- there is no path where a hunter is charged for an acceptance that
    -- then fails (§4).
    if anonymous and (Config.Anonymity.HunterFee or 0) > 0 then
        local account = Config.Anonymity.FeeAccount or 'bank'
        if actor.player.Functions.RemoveMoney(account, Config.Anonymity.HunterFee) then
            Audit.financial('anonymity_fee', actor.cid, contractId,
                { amount = Config.Anonymity.HunterFee, role = 'hunter' })
        else
            -- They cannot afford to stay unnamed, so they are simply named.
            -- Refusing the whole acceptance here would mean unwinding the
            -- stake as well, for a preference rather than a requirement.
            Storage.updateHunter(record.id, { anon = false })
            record.anon = false
            Notify.toCitizen(actor.cid, 'Not anonymous',
                'You could not cover the anonymity fee, so the contract carries your name.')
        end
    end

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
---@param opts table|nil { deathAt = ms } when the claim rests on a recorded death
function Contracts.claimSlot(contractId, hunterCid, fulfilment, opts)
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
    if targetActor and Contracts.isImmune(targetActor, opts) then
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

    -- Only the two fields that changed, guarded on the slot still being the
    -- one this claim acted on. Writing back the whole contract read at the
    -- top of this function erased anything stored in between — a bailout
    -- queuing during the yielding reads above is the target's money.
    if not Storage.advanceSlot(contractId, slot) then
        -- The slot moved under this claim. The escrow for it is already
        -- released above, so this cannot be unwound — but it must not be
        -- compounded by writing a slot count nothing agrees with.
        Audit.financial('slot_advance_lost', hunterCid, contractId, { slot = slot })
    end

    -- Re-read rather than mutating the copy: on a backend that hands out
    -- references, that copy IS the stored row, and incrementing it here
    -- counted the claim twice.
    contract = Storage.readContract(contractId) or contract
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
        Contracts.transition(contractId, CB.STATE.COMPLETING, CB.STATE.COMPLETED, 'completed', SETTLING)
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
--- Whether anybody is currently hunting this contract.
---
--- The state alone does not say: a contract stays ACCEPTED after its only
--- hunter walks away, and a competitive one is ACCEPTED with any number of
--- them. What matters for taking a contract back down is whether somebody
--- is holding it right now.
---@param contractId string
---@return boolean
local function heldByAnyone(contractId)
    local hunters = Storage.readHunters(contractId)
    for i = 1, #hunters do
        if hunters[i].state == 'active' then return true end
    end
    return false
end

--- Take a contract back down and get the escrow back.
---
--- There was no way to do this. Cancelling existed only as an amendment
--- both sides had to agree to — and with nobody holding the contract there
--- is nobody to agree — or as a staff command. So a creator who thought
--- better of it watched their money sit in escrow until the deadline ran
--- out, on a contract nobody had even accepted.
---
--- Refused the moment somebody is actually hunting it. That is what escrow
--- is for: a hunter who has started work, and staked a penalty to do it,
--- cannot have the reward pulled out from under them.
---@param actor table
---@param contractId string
---@return boolean ok
---@return string|nil err
function Contracts.cancel(actor, contractId)
    contractId = Util.toId(contractId)
    if not contractId then return false, CB.ERR.INVALID_INPUT end

    local contract = Storage.readContract(contractId)
    if not contract then return false, CB.ERR.NOT_FOUND end
    if contract.creator_cid ~= actor.cid then return false, CB.ERR.NOT_PARTICIPANT end
    if CB.TERMINAL[contract.state] then return false, CB.ERR.ALREADY_SETTLED end
    if heldByAnyone(contractId) then return false, CB.ERR.BAD_STATE end

    local ok, err = Contracts.resolve(contractId, CB.STATE.CANCELLED,
        actor.cid, nil, 'cancelled_by_creator')
    if not ok then return false, err end

    Audit.financial('contract_cancelled', actor.cid, contractId, {})
    Notify.toCitizen(actor.cid, 'Contract withdrawn',
        'Nobody had taken it, so everything you put up has been returned.')
    return true
end

--- Change a contract nobody has taken.
---
--- Only while it is unclaimed: once a hunter has accepted, they accepted it
--- as written, and a change from there goes through the amendment path
--- where they get a say.
---
--- The reward is deliberately not editable here. Moving escrow around is
--- money in and out of a player's pocket, and there is already a path for
--- adding to it; a creator who wants less on the table cancels and places
--- again, which refunds in one guarded operation rather than several.
---@param actor table
---@param contractId string
---@param changes table { reason?: string, deadlineSeconds?: integer }
---@return boolean ok
---@return string|nil err
function Contracts.revise(actor, contractId, changes)
    contractId = Util.toId(contractId)
    if not contractId then return false, CB.ERR.INVALID_INPUT end
    changes = type(changes) == 'table' and changes or {}

    local contract = Storage.readContract(contractId)
    if not contract then return false, CB.ERR.NOT_FOUND end
    if contract.creator_cid ~= actor.cid then return false, CB.ERR.NOT_PARTICIPANT end
    if CB.TERMINAL[contract.state] then return false, CB.ERR.ALREADY_SETTLED end
    if heldByAnyone(contractId) then return false, CB.ERR.BAD_STATE end

    local touched = {}

    if changes.reason ~= nil then
        -- Cleaned exactly as it was when the contract was placed: the same
        -- cap, the same stripping. A second way in must not be a way past.
        local reason = Util.sanitizeText(changes.reason, 140)
        if not reason then return false, CB.ERR.INVALID_INPUT end
        contract.reason = reason
        touched[#touched + 1] = 'reason'
    end

    if changes.deadlineSeconds ~= nil then
        local seconds = Util.toPositive(changes.deadlineSeconds,
            Config.Limits.ContractLifetimeSeconds)
        if not seconds then return false, CB.ERR.INVALID_INPUT end

        -- Never past the absolute lifetime, which is what stops a contract
        -- holding escrow forever.
        local deadline = os.time() + seconds
        if contract.expires_at and deadline > contract.expires_at then
            deadline = contract.expires_at
        end
        contract.deadline_at = deadline
        touched[#touched + 1] = 'deadline'
    end

    if #touched == 0 then return false, CB.ERR.INVALID_INPUT end

    if not Storage.writeContract(contract) then return false, CB.ERR.BAD_STATE end

    Audit.action('contract_revised', actor.cid, contractId,
        { changed = table.concat(touched, ',') })
    return true
end

function Contracts.resolve(contractId, terminal, recipientCid, filter, reason)
    local contract = Storage.readContract(contractId)
    if not contract then return false, CB.ERR.NOT_FOUND end
    if CB.TERMINAL[contract.state] then return false, CB.ERR.ALREADY_SETTLED end

    if not Contracts.transition(contractId, contract.state, terminal, reason, SETTLING) then
        return false, CB.ERR.LOCKED
    end

    contract.resolved_at = os.time()
    contract.resolution = reason
    Storage.writeContract(contract)

    -- A target who outlived the contract has something to show for it.
    if Progression and (terminal == CB.STATE.BAILED_OUT or terminal == CB.STATE.EXPIRED) then
        Progression.onSurvived(contract.target_cid)
    end

    -- Pay whoever this resolution names, before anything sweeps the rest
    -- back to the creator. A general refund never touches a stake or a line
    -- already owed to someone, so the ordering here is safe either way.
    local _, result = Escrow.release(contractId, recipientCid, filter, reason)

    -- Everything else a contract ending has to do — stakes settled by why it
    -- ended, the remainder returned, the parties nudged, per-contract caches
    -- released. This used to be open-coded here, which is how the two
    -- terminal paths came to differ; there is now one of them.
    --
    -- An expiry is the hunter failing, so the creator keeps their stake.
    finalise(contractId, contract, terminal == CB.STATE.EXPIRED)

    return true, result
end

return Contracts
