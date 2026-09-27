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

--- Contracts somebody has accepted, so the idle-hold sweep reads those and
--- not the whole table. Filled on acceptance and rebuilt once at boot
--- (Contracts.reindexHolds); one no longer held drops out on the next sweep.
local heldIndex = {}

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
        return false, CB.ERR.TARGET_IS_LEO
    end

    -- Only the contracts these two are involved in matter here, so this asks
    -- for those rather than for the whole table.
    local contracts = Storage.contractsBy(actor.cid)

    -- And the ones this player placed on their other characters. Every
    -- creator-side limit below — how many they may have open, the wait
    -- before naming the same person again, the wait after cancelling — was
    -- counted per character, so /relog onto a second character on the same
    -- licence reset all three: the two-hour wait on re-listing one victim
    -- became the thirty minutes everybody waits (§14.7).
    if actor.account and Storage.contractsByAccount then
        local alsoMine = Storage.contractsByAccount(actor.account) or {}
        for i = 1, #alsoMine do contracts[#contracts + 1] = alsoMine[i] end
    end

    local naming = Storage.contractsNaming(targetActor.cid)
    for i = 1, #naming do contracts[#contracts + 1] = naming[i] end

    --- Whether this contract was placed by this player, on any character.
    local function placedByThisPlayer(c)
        return c.creator_cid == actor.cid
            or Identity.sameAccount(c.creator_account, actor.account)
    end

    local byCreator, byTarget = 0, 0
    local now = os.time()
    local counted = {}

    for i = 1, #contracts do
        local c = contracts[i]
        if counted[c.id] then goto continue end
        counted[c.id] = true
        if LIVE_STATES[c.state] then
            if placedByThisPlayer(c) then byCreator = byCreator + 1 end
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
                    return false, CB.ERR.TARGET_RECENTLY_ON
                end
                -- Its own code. This is a policy wait of hours, and sharing
                -- RATE_LIMITED with the token bucket told the creator to
                -- "slow down" about it.
                if placedByThisPlayer(c) and since < Config.Limits.SameCreatorSameTargetCooldownSeconds then
                    return false, CB.ERR.SAME_TARGET_TOO_SOON
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
            if placedByThisPlayer(c) and c.state == CB.STATE.CANCELLED and c.resolved_at
                and (now - c.resolved_at) < Config.Amendments.CancelCooldownSeconds then
                return false, CB.ERR.CANCELLED_TOO_SOON
            end
        end
    end

    if byCreator >= Config.Limits.MaxActiveContractsPerCreator then return false, CB.ERR.LIMIT_REACHED end
    if byTarget >= Config.Limits.MaxActiveContractsPerTarget then
        return false, CB.ERR.TARGET_HAS_ENOUGH
    end

    -- New and freshly-connected players are not fair game.
    local immune, why = Contracts.isImmune(targetActor)
    if immune then return false, why or CB.ERR.TARGET_PROTECTED end

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
--- @return boolean immune
--- @return string|nil why an ERR code naming which rule, for the player
function Contracts.isImmune(targetActor, opts)
    -- Session length is measured by this resource, so it is always known
    -- for anyone who connected while it was running.
    local deathAgo = opts and opts.deathAt
        and ((Util.monotonicMs() - opts.deathAt) / 1000) or nil

    local session = Identity.sessionMinutes(targetActor.cid)
    if session ~= nil and session < Config.Immunity.MinTargetSessionMinutes then
        -- Except a claim on a death from before this session began. A target
        -- who quit while dead and came straight back started a new session,
        -- and the floor — ten minutes, against a proof window of one —
        -- refused the hunter standing over the body, told them to wait, and
        -- let the kill expire. Quitting was already not a way out of a kill;
        -- rejoining was.
        local sessionAgo = Identity.sessionSeconds and Identity.sessionSeconds(targetActor.cid)
        if not (deathAgo ~= nil and sessionAgo ~= nil and deathAgo > sessionAgo) then
            return true, CB.ERR.TARGET_JUST_ON
        end
    end

    local hours = Identity.playtimeHours(targetActor)
    if hours ~= nil and hours < Config.Immunity.MinTargetPlaytimeHours then
        return true, CB.ERR.TARGET_TOO_NEW
    end

    -- Someone who just got back up is not immediately fair game again:
    -- without this a multi-slot contract becomes respawn camping.
    --
    -- A claim on a death that happened BEFORE the respawn is exempt: the
    -- hunter earned it while the target was still down, and the target
    -- pressing respawn must not take it away (§7.4 proof window).
    --
    -- A live delivery is exempt too, and has to be. Taking somebody alive
    -- means restraining them, and restraining them all but always means
    -- putting them down first — so this rule fired on the hunter's own
    -- doing, on nearly every kidnapping, and told them to give the target a
    -- moment while that target was cuffed in the back of their car. The
    -- rule is against re-killing someone who has just respawned; a target
    -- already in hand is not being camped, they are being carried.
    local liveDelivery = opts and opts.fulfilment == CB.FULFILMENT.KIDNAPPING
    if not liveDelivery and Death and (Config.Immunity.PostRespawnSeconds or 0) > 0 then
        local since = Death.sinceRespawn(targetActor.cid)
        if since and since < Config.Immunity.PostRespawnSeconds then
            local respawnedAgo = since
            local claimPredatesRespawn = deathAgo ~= nil and deathAgo > respawnedAgo
            if not claimPredatesRespawn then return true, CB.ERR.TARGET_JUST_UP end
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
    if Util.credit(actor.player, account, fee) then return true end

    Audit.financial('anonymity_fee_refund_failed', actor.cid, contractId,
        { amount = fee, account = account })
    return false
end

--- The phone's own word blacklist, where this build has one.
---
--- lb-phone ships its server code escrowed and its export surface has moved
--- across releases, so indexing an export that is not there throws — and
--- both call sites are inside handlers, which makes that not a degraded
--- feature but every contract refused with server_error and every message
--- the same. The resource states this rule in two places and enforced it
--- only on the client.
---
--- Open rather than closed when the export is missing: refusing everything
--- would be the same outage with a tidier message, and the rules this
--- resource owns — the length cap, the digit cap, the pattern denylist —
--- are applied either way. Which build this is gets reported at startup.
---@param source integer
---@param text string
---@return boolean blocked
local function phoneRefuses(source, text)
    local ok, blocked = pcall(function()
        return exports['lb-phone']:ContainsBlacklistedWord(source, text)
    end)
    return ok and blocked == true
end

--- The buyout premium, against the escrow it is a multiple of.
---
--- Clamped rather than rejected: a creator who types a silly number gets
--- the ceiling, not a silently disabled bailout.
---
--- The clamp is the whole thing that stops a bailout being an uncapped,
--- untaxed transfer rail between two cooperating players (§14.16), so it
--- has to hold for as long as the price does — not only at the moment it
--- is set. Taking the escrow back out after the fact left a price that was
--- a multiple of money no longer there: fund 90,010, price it at the 270,030
--- ceiling, withdraw the 90,000, and collect 270,040 from the target having
--- staked 10. Every way the escrow can change answers to this.
---
--- Clean money only. The target buys their way out with cash or bank, so
--- those are the only accounts the buyout can charge; counting black money
--- towards the ceiling let a creator fund in a currency worth a fraction of
--- its face value and extract a multiple of that face value in real money.
---@param requested any what the creator asked for
---@param lines table[] escrow lines to measure against
---@return integer bailout
---@return string|nil err
function Contracts.clampBailout(requested, lines)
    if not Config.Bailout.Enabled or not requested then return 0 end

    local bailout = Util.toPositive(requested) or 0
    if bailout <= 0 then return 0 end

    local moneyValue = 0
    for i = 1, #lines do
        if CB.MONEY_ACCOUNTS[lines[i].source] then
            moneyValue = moneyValue + (lines[i].amount or 0)
        end
    end

    -- A bailout needs a clean money escrow to be a multiple of. A contract
    -- funded only in goods or only in black money cannot offer one, for the
    -- same reason an items-only contract cannot.
    if moneyValue == 0 then return 0, CB.ERR.INVALID_INPUT end

    local min = math.floor(moneyValue * Config.Bailout.MinMultiplier)
    local max = math.floor(moneyValue * Config.Bailout.MaxMultiplier)
    if bailout < min then bailout = min end
    if bailout > max then bailout = max end
    if bailout > Config.Bailout.AbsoluteMax then bailout = Config.Bailout.AbsoluteMax end
    return bailout
end

--- Is the stake this caller agreed to the stake on the contract (§14.18)?
---
--- Disclosure that is not binding is disclosure with a race in it: the
--- figure is read off the board, the creator reprices a contract nobody
--- holds, and Accept charges the new one. Every other repricing a player
--- can meet is fixed by looking again; this one is not, because the stake
--- is taken the moment Accept is tapped and forfeits to that creator if the
--- hunter later walks away or runs out of clock.
---
--- Asked at the net event rather than inside Contracts.accept, because it
--- is a property of what a client sent, not of the operation: an admin
--- path or a test driving the module directly is not a page that was shown
--- a figure.
---
--- Only where a stake exists. A contract with none has nothing to disclose,
--- so a page that predates this is refused nothing.
---@param contract table
---@param disclosed any what the client says it had on screen
---@return boolean
function Contracts.stakeWasDisclosed(contract, disclosed)
    if not Config.Penalty.RequireDisclosureOnAccept then return true end
    if not contract or (contract.penalty_amount or 0) <= 0 then return true end
    return Util.toCount(disclosed, Config.MaxContractValue) == contract.penalty_amount
end

--- The failure stake a hunter must put up, clamped to what the contract is
--- worth (§14.18).
---
--- The same job Contracts.clampBailout does for the premium, and missing
--- for the stake, which is the side with the worse failure mode: a bailout
--- is a target choosing to pay, while a stake is taken from a hunter the
--- moment they tap Accept and forfeits to the creator if they later abandon
--- or run out of clock. Bounded only by Config.MaxContractValue, a contract
--- advertising a $1,000 reward could carry a $1,000,000 stake — a transfer
--- rail of exactly the kind the bailout clamp exists to close.
---
--- Clamped silently, as §14.18 asks, rather than refused: a creator who
--- names too large a figure gets the largest one this contract can carry.
---@param requested any
---@param moneyValue integer the §9.1 money escrow value
---@return integer
function Contracts.clampPenalty(requested, moneyValue)
    local penalty = Util.toPositive(requested) or 0
    if penalty <= 0 then return 0 end

    local max = Config.Penalty.MaxAmount or 0
    local fraction = Config.Penalty.MaxFractionOfEscrow
    if fraction then
        local relative = math.floor((moneyValue or 0) * fraction)
        if relative < max then max = relative end
    end

    if penalty > max then penalty = max end
    return penalty
end

--- The reason a contract carries, decided the same way wherever it is set.
---
--- Placing one and editing one both put text in front of every player on
--- the board, so both answer to the same rules: the mode the operator
--- chose, the length they set, the patterns they banned, and the words the
--- phone refuses.
---
--- They did not. revise ran one of the four checks, against a length
--- written into the code rather than the configured one, and did not look
--- at the mode at all — so the Edit button was a way to put a link, a
--- phone number or a slur on the board, and to write free text on a server
--- whose operator had switched free text off. The comment there claimed
--- the opposite: "a second way in must not be a way past".
---
---@return string|nil reason  '' where the server stores none
---@return string|nil err
local function reasonFor(actor, req)
    local mode = Config.Reason.Mode

    if mode == 'preset' then
        local index = Util.toPositive(req.reasonPreset, #Config.Reason.Presets)
        if not index then return nil, CB.ERR.INVALID_INPUT end
        return Config.Reason.Presets[index]
    end

    if mode ~= 'freetext' then return '' end

    local reason = Util.sanitizeText(req.reason, Config.Reason.MaxLength)
    if not reason then return nil, CB.ERR.INVALID_INPUT end
    if Util.digitCount(reason) > Config.Reason.MaxDigits then return nil, CB.ERR.INVALID_INPUT end
    for _, pattern in ipairs(Config.Reason.PatternDenylist) do
        if reason:lower():find(pattern) then return nil, CB.ERR.INVALID_INPUT end
    end
    if phoneRefuses(actor.source, reason) then
        return nil, CB.ERR.INVALID_INPUT
    end
    return reason
end

--- The same rules, for the third way a reason can change: an agreed
--- change_reason amendment. It checked length and digits only, so a creator
--- could propose a link, an invite or a handle and agree to it themselves on
--- any contract nobody had taken — and put free text on the board of a
--- server whose operator had switched free text off.
Contracts.reasonFor = reasonFor

function Contracts.create(actor, req)
    local targetActor = Identity.byCitizenId(req.targetCid)
    local ok, err = Contracts.canCreate(actor, targetActor)
    if not ok then return nil, err end

    local reason, reasonErr = reasonFor(actor, req)
    if reasonErr then return nil, reasonErr end

    local mode = req.mode == CB.MODE.COMPETITIVE and CB.MODE.COMPETITIVE or CB.MODE.EXCLUSIVE

    -- Clamped to the ceiling, not dropped.
    --
    -- Util.toCount returns nil for anything ABOVE its maximum, so `or 0`
    -- turned a bonus over the cap into no bonus at all — and the contract
    -- was created anyway. A creator who asked for 300% on a server capped at
    -- 200 promised a live-delivery premium, surrendered nothing for it, and
    -- was told nothing; a hunter who delivered alive was paid a bonus of
    -- zero. The bailout premium three lines below is clamped for exactly
    -- this reason, with a comment saying so.
    local bonusPercent = Util.toCount(req.bonusPercent, Config.Bonus.maxPercent)
    if not bonusPercent then
        bonusPercent = Util.toCount(req.bonusPercent) and Config.Bonus.maxPercent or 0
    end

    -- The bonus is escrowed at creation like everything else, so a creator
    -- cannot promise a live-delivery premium they have not surrendered.
    local lines, slotCount
    lines, err, slotCount = Escrow.validate(actor, req.reward, bonusPercent)
    if not lines then return nil, err end

    local bailout, bailoutErr = Contracts.clampBailout(req.bailoutAmount, lines)
    if bailoutErr then return nil, bailoutErr end

    -- The stake is clamped against the same figure, for the same reason.
    local penaltyEscrow = 0
    for i = 1, #lines do
        if CB.MONEY_ACCOUNTS[lines[i].source] then
            penaltyEscrow = penaltyEscrow + (lines[i].amount or 0)
        end
    end
    local penalty = Contracts.clampPenalty(req.penaltyAmount, penaltyEscrow)

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
        penalty_amount = penalty,
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
        if not Util.charge(actor.player, account, Config.Anonymity.CreatorFee) then
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
---@param opts table|nil { disclosed = n } the stake the page had on screen
---@return boolean ok
---@return string|nil err
function Contracts.accept(actor, contractId, anonymous, opts)
    contractId = Util.toId(contractId)
    if not contractId then return false, CB.ERR.INVALID_INPUT end

    local contract = Storage.readContract(contractId)
    if not contract then return false, CB.ERR.NOT_FOUND end

    -- Against THIS read, the one the stake below is charged from. The net
    -- event checked a read of its own, one await earlier, and a reprice
    -- landing between the two was charged in full.
    if opts and opts.checkDisclosure
        and not Contracts.stakeWasDisclosed(contract, opts.disclosed) then
        return false, CB.ERR.TERMS_CHANGED
    end

    if contract.state ~= CB.STATE.ACTIVE and contract.state ~= CB.STATE.ACCEPTED then
        -- Closed is not "not right now". The board drops a closed contract
        -- only on its next read, so tapping Accept on one that was cancelled,
        -- expired, bought out or completed a moment ago is the ordinary case,
        -- and it will never be acceptable again. COMPLETING is the one state
        -- here that really is momentary.
        if CB.TERMINAL[contract.state] then return false, CB.ERR.ALREADY_SETTLED end
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

    -- A previous stint on this contract is not a reason to refuse. Walking
    -- away puts the contract back on the board (§12.4), listed to this
    -- player exactly as to everyone else — and this refused on the mere
    -- existence of their old row, so the Accept button was dead for the one
    -- player it was guaranteed to be shown to, answered "Not right now."
    -- for the rest of the contract's life.
    --
    -- The old row is taken up again rather than a second one written. It
    -- carries the wait between payouts and the alias: a fresh row would
    -- have made walking away and coming back the way to skip the ten-minute
    -- wait between collections, and would have given the creator's threads
    -- a second name for the same person.
    local previous = Storage.readHunter(contractId, actor.cid)
    if previous and previous.state == 'active' then
        return false, CB.ERR.ALREADY_HOLDING
    end
    -- Copied out: on the in-process store `previous` IS the stored row, so
    -- reactivating it below changes these fields underneath us.
    local previousState = previous and previous.state
    local previousAnon = previous and previous.anon

    -- Coming back cannot buy anonymity the first stint gave away. The alias
    -- and the thread are the same ones, so a creator who was shown
    -- "Operative #1 (their name)" and that operative's messages knows
    -- exactly who the anonymous Operative #1 is — and the fee used to be
    -- taken for it all the same. Named again, charged nothing, and told why.
    local renamed = false
    if previous and not previous.anon and anonymous then
        anonymous = false
        renamed = true
    end

    local held = Storage.countHunterContracts(actor.cid, LIVE_STATES)
    if held >= Config.Limits.MaxAcceptedPerHunter then return false, CB.ERR.LIMIT_REACHED end

    local existing = Storage.readHunters(contractId)
    local activeCount = 0
    for i = 1, #existing do
        if existing[i].state == 'active' then activeCount = activeCount + 1 end
        -- Released from it for sitting on it, on this character or another:
        -- taking it straight back would make the release a reset.
        if existing[i].state == 'released' and (existing[i].hunter_cid == actor.cid
            or Identity.sameAccount(existing[i].hunter_account, actor.account)) then
            return false, CB.ERR.HOLD_RELEASED
        end
    end

    -- Aliases are numbered from everyone who has ever held this contract,
    -- not from the live count: reusing "Operative #2" after someone abandons
    -- makes two different people indistinguishable in the creator's threads.
    local aliasNumber = #existing + 1

    -- Whether THIS call is the one that advanced the contract, which is the
    -- only thing that makes reverting it safe. The undo below used to test
    -- the mode instead, so an exclusive acceptance was put back and a
    -- competitive one was not — and every step after this can still fail.
    -- A broke player tapping Accept flipped a competitive contract to
    -- `accepted` for every viewer of the board, with no hunter on it and
    -- huntersActive still zero, and left it that way.
    local advanced = false

    if contract.mode == CB.MODE.EXCLUSIVE then
        -- The same fact as a full competitive contract — somebody else has
        -- it, try another or come back if they drop out — so the same code.
        -- An exclusive contract stays listed while it is held, so this is an
        -- answer hunters read often, and "Not right now." named neither the
        -- reason nor what to do about it.
        if activeCount > 0 then return false, CB.ERR.CONTRACT_FULL end
        if not Contracts.transition(contractId, CB.STATE.ACTIVE, CB.STATE.ACCEPTED, 'accepted') then
            return false, CB.ERR.LOCKED
        end
        advanced = true
    else
        -- Not LIMIT_REACHED: that one is about what the CALLER is holding,
        -- and this is about what the contract is holding.
        if activeCount >= Config.Limits.MaxHuntersPerContract then
            return false, CB.ERR.CONTRACT_FULL
        end
        -- Not advanced here. A competitive contract is advanced only once
        -- this hunter's stake and row exist (below), so there is never an
        -- advance to put back: putting one back after another hunter had
        -- joined on the strength of it left that hunter holding an ACTIVE
        -- contract that refused every claim and forfeited their stake at
        -- expiry.
    end

    -- The anonymity fee, before anything else is taken, and a refusal if it
    -- cannot be paid (§4: charged BEFORE anonymity is granted).
    --
    -- It used to be taken last, and a hunter who could not cover it was
    -- simply named: the acceptance went through, the creator's phone said
    -- "accepted by <their name>", and the page — which only saw a successful
    -- reply — told the hunter "Contract accepted, anonymously." Anonymity is
    -- the one thing in this resource that cannot be given back once it has
    -- been lost, so it is not something to downgrade on somebody's behalf.
    -- Every refusal from here on puts the fee back.
    --
    -- Once per contract. Coming back anonymous after an anonymous stint is
    -- the same alias and the same thread, anonymity already paid for here;
    -- charging it again bought nothing, and a hunter who could not cover
    -- the second fee was refused a contract they were already anonymous on.
    local feeAccount = Config.Anonymity.FeeAccount or 'bank'
    local paidBefore = previousAnon == true
    local fee = (anonymous and not paidBefore and (Config.Anonymity.HunterFee or 0) > 0)
        and Config.Anonymity.HunterFee or 0
    if fee > 0 and not Util.charge(actor.player, feeAccount, fee) then
        if advanced then
            Contracts.transition(contractId, CB.STATE.ACCEPTED, CB.STATE.ACTIVE, 'fee_failed')
        end
        return false, CB.ERR.INSUFFICIENT
    end
    local function refundFee()
        if fee <= 0 then return end
        if not Util.credit(actor.player, feeAccount, fee) then
            Audit.financial('anonymity_fee_refund_failed', actor.cid, contractId,
                { amount = fee, account = feeAccount, role = 'hunter' })
        end
    end

    -- The failure penalty is staked here, at acceptance, or not at all: a
    -- penalty that is only charged after a failure is a penalty the hunter
    -- can walk away from (§3.6). The hunter is told the amount before this
    -- point, and refusing to stake simply refuses the contract.
    local stake = contract.penalty_amount or 0
    local stakeIds
    if stake > 0 then
        local account = (actor.player.Functions.GetMoney('bank') or 0) >= stake and 'bank' or 'cash'
        if (actor.player.Functions.GetMoney(account) or 0) < stake then
            -- Undo the state change this call made, in either mode.
            if advanced then
                Contracts.transition(contractId, CB.STATE.ACCEPTED, CB.STATE.ACTIVE, 'stake_failed')
            end
            refundFee()
            return false, CB.ERR.INSUFFICIENT
        end

        local ok, takeErr, ids = Escrow.take(actor, contractId, { {
            slot = 0, portion = CB.PORTION.STAKE, source = account,
            amount = stake, staker = actor.cid,
        } })
        stakeIds = ids
        if not ok then
            if advanced then
                Contracts.transition(contractId, CB.STATE.ACCEPTED, CB.STATE.ACTIVE, 'stake_failed')
            end
            refundFee()
            -- A contract busy with another take is not the hunter being
            -- short of money.
            return false, takeErr == CB.ERR.LOCKED and CB.ERR.LOCKED or CB.ERR.INSUFFICIENT
        end
        Audit.financial('stake_taken', actor.cid, contractId, { amount = stake })
    end

    -- Confirmed free before the row is written. The stake above is already
    -- taken by this point, and addHunter is a plain insert: an id in use is
    -- a duplicate-key error thrown out of here with the money gone and no
    -- hunter row to say whose it was, so nothing would ever return it.
    local hunterId = previous and previous.id
        or Util.mintId(Storage.nextId, 'hn', Storage.readHunterById)
    if not hunterId then
        if stake > 0 then
            Escrow.release(contractId, actor.cid,
                { portion = CB.PORTION.STAKE, staker = actor.cid }, 'hunter_id_exhausted')
        end
        if advanced then
            Contracts.transition(contractId, CB.STATE.ACCEPTED, CB.STATE.ACTIVE, 'accept_failed')
        end
        refundFee()
        Audit.rejected('hunter_id_exhausted', actor.cid, contractId, {})
        return false, CB.ERR.BAD_STATE
    end

    local record
    if previous then
        Storage.updateHunter(previous.id, { state = 'active', anon = anonymous == true })
        record = Storage.readHunter(contractId, actor.cid) or previous
        record.state, record.anon = 'active', anonymous == true
    else
        record = {
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
    end

    -- Is the contract still open, now that this hunter is on it?
    --
    -- The state was read at the top, and every store call since is a yield
    -- on mysql. A contract that closed in one of them — the creator
    -- cancelling an exclusive contract this call had just moved to accepted
    -- (no hunter row existed yet, so the cancel saw nobody on it), another
    -- hunter collecting the last payout of a competitive one, a buyout, the
    -- expiry pass — ran its settlement before this hunter existed, so
    -- nothing ever returned the stake taken above. It sat `held` on a closed
    -- contract with nothing that would move it, and the hunter was told they
    -- had accepted.
    --
    -- Asked only after the row is written, which is what makes the answer
    -- binding: an ending that has not started yet will find this hunter
    -- when it settles stakes, and one that has started is visible here.
    -- COMPLETING is refused too, because a claim on the last payout settles
    -- stakes before it marks the contract completed.
    local now = Storage.readContract(contractId)
    local nowState = now and now.state
    if nowState ~= CB.STATE.ACTIVE and nowState ~= CB.STATE.ACCEPTED then
        if previous then
            Storage.updateHunter(previous.id, { state = previousState, anon = previousAnon == true })
        else
            Storage.updateHunter(record.id, { state = 'withdrawn', left_at = os.time() })
        end
        if stakeIds and next(stakeIds) then
            Escrow.release(contractId, actor.cid, { lines = stakeIds }, 'accept_on_closed')
        end
        refundFee()
        Audit.rejected('accept_on_closed', actor.cid, contractId, { state = nowState })
        if nowState == CB.STATE.COMPLETING then return false, CB.ERR.LOCKED end
        return false, CB.ERR.ALREADY_SETTLED
    end

    -- Competitive: advanced only now, with this hunter's stake and row in
    -- place. A no-op when somebody else already advanced it.
    if contract.mode ~= CB.MODE.EXCLUSIVE and nowState == CB.STATE.ACTIVE then
        Contracts.transition(contractId, CB.STATE.ACTIVE, CB.STATE.ACCEPTED, 'accepted')
    end

    -- Recorded once the acceptance it paid for has actually happened.
    if fee > 0 then
        Audit.financial('anonymity_fee', actor.cid, contractId,
            { amount = fee, role = 'hunter' })
    elseif renamed then
        Notify.toCitizen(actor.cid, 'Not anonymous',
            'The client already knows you by name on this contract, so you are '
            .. 'back on it under your name. You were not charged for anonymity.')
    end

    -- Start watching the target's health now, so damage claimed against
    -- them from this point can be corroborated (§14.2).
    if Death then
        local targetActor = Identity.byCitizenId(contract.target_cid)
        if targetActor then Death.watch(targetActor.cid, targetActor.source) end
    end

    Audit.action('contract_accepted', actor.cid, contractId, { anonymous = record.anon })
    Notify.contractAccepted(contract, record, activeCount + 1)

    -- Somebody holds it now, which is what the idle-hold sweep reads.
    heldIndex[contractId] = true

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
        if Contracts.transition(contractId, CB.STATE.ACCEPTED, CB.STATE.ACTIVE, 'abandoned') then
            -- Counted before the revert landed, so a hunter who accepted in
            -- between is holding a contract that just went back on the
            -- board — refused every claim and forfeiting their stake at
            -- expiry. Looked at again now it has, and put back if so.
            for _, row in ipairs(Storage.readHunters(contractId) or {}) do
                if row.state == 'active' then
                    Contracts.transition(contractId, CB.STATE.ACTIVE, CB.STATE.ACCEPTED, 'rejoined')
                    break
                end
            end
        end
    end

    if Progression then Progression.onFailed(actor.cid) end

    -- Anything holding state for this hunter on this contract is told.
    -- A handover they had armed is the one that matters: it does not pay
    -- out to somebody who walked away, but it does hold a countdown slot
    -- until the process restarts.
    if Contracts.onHunterLeft then
        Contracts.onHunterLeft(contractId, actor.cid, 'abandoned')
    end

    Audit.action('contract_abandoned', actor.cid, contractId, {})
    return true
end

--------------------------------------------------------------------------
-- An exclusive hold nobody is working (§14.8)
--------------------------------------------------------------------------
--
-- An exclusive contract is one operative's alone, the client cannot cancel
-- it while it is held, and nobody else can take it. So a target's friend
-- could accept the contract on them and simply sit on it — nowhere near the
-- target, costing nothing on a contract with no stake — and it stayed frozen
-- until its deadline ran out, which pauses whenever either party logs off.
-- The client's only answer to "Cancel" was "Not right now."

--- Seconds each holder has gone without working the contract, counted only
--- while its client and target are both in the city — nobody is released
--- for failing to find a target who is not there. [contractId:hunterCid].
local idleFor = {}
local lastIdleSweep = nil

--- Rebuild the index of held contracts after a restart, when contracts may already be held
--- that this process never saw accepted.
---@return integer indexed
function Contracts.reindexHolds()
    heldIndex = {}
    local n = 0
    for _, c in ipairs(Storage.allContracts()) do
        if c.state == CB.STATE.ACCEPTED or c.state == CB.STATE.COMPLETING then
            heldIndex[c.id] = true
            n = n + 1
        end
    end
    return n
end

--- Take one idle operative off an exclusive contract and put it back on the
--- board. Their stake comes back: the release is the remedy, not a fine.
---@return boolean released
local function releaseIdleHold(contractId, hunter, idleSeconds)
    -- Re-read: a payout or an abandonment may have moved it since the sweep
    -- read it, and a hunter being paid is not one to release.
    local contract = Storage.readContract(contractId)
    if not contract or contract.state ~= CB.STATE.ACCEPTED then return false end
    local current = Storage.readHunter(contractId, hunter.hunter_cid)
    if not current or current.state ~= 'active' then return false end

    Storage.updateHunter(current.id, { state = 'released', left_at = os.time() })

    Escrow.release(contractId, current.hunter_cid,
        { portion = CB.PORTION.STAKE, staker = current.hunter_cid }, 'stake_returned_idle')

    local remaining = 0
    for _, h in ipairs(Storage.readHunters(contractId)) do
        if h.state == 'active' then remaining = remaining + 1 end
    end
    if remaining == 0 then
        Contracts.transition(contractId, CB.STATE.ACCEPTED, CB.STATE.ACTIVE, 'idle_hold_released')
    end

    if Contracts.onHunterLeft then
        Contracts.onHunterLeft(contractId, current.hunter_cid, 'idle_hold_released')
    end

    local minutes = math.floor(idleSeconds / 60)
    Notify.toCitizen(current.hunter_cid, 'Taken off a contract',
        ('You held a contract for %d minutes without going near its target, so it '
            .. 'has gone back on the board. Your stake has been returned.'):format(minutes),
        { bypassBudget = true })
    Notify.toCitizen(contract.creator_cid, 'Contract back on the board',
        'The operative holding your contract was not working it, so it is open again.')
    Notify.pushParties(Storage.readContract(contractId) or contract,
        { current.hunter_cid }, 'released')

    Audit.action('hold_released_idle', current.hunter_cid, contractId,
        { idle = idleSeconds })
    return true
end

--- Release every exclusive hold that has gone unworked for too long.
--- Driven by the maintenance tick; the clock is advanced by however long it
--- has been since the last pass, so a slow tick neither loses nor gains time.
---@return integer released
function Contracts.releaseIdleHolds()
    local window = Config.Limits.ExclusiveIdleReleaseSeconds or 0
    local now = os.time()
    local elapsed = lastIdleSweep and math.max(0, now - lastIdleSweep) or 0
    lastIdleSweep = now
    if window <= 0 then
        idleFor = {}
        return 0
    end

    local released = 0
    local live = {}

    -- The contracts somebody has taken, from the index rather than a walk of
    -- the table: this runs every ten seconds for the life of the server, and
    -- almost every contract that exists is not being held.
    --
    -- Walked from a snapshot of the keys: every read below waits on the
    -- database in mysql mode, and an acceptance landing in that wait adds a
    -- key to the table being walked, which pairs() leaves undefined.
    local ids = {}
    for contractId in pairs(heldIndex) do ids[#ids + 1] = contractId end

    for _, contractId in ipairs(ids) do
        local c = Storage.readContract(contractId)
        if not c or c.state ~= CB.STATE.ACCEPTED then
            -- Resolved, or back on the board: nobody holds it now. A contract
            -- mid-settlement stays, since a failed payout lands it back here.
            if not c or c.state ~= CB.STATE.COMPLETING then heldIndex[contractId] = nil end
        elseif c.mode == CB.MODE.EXCLUSIVE then
            -- An anonymous creator's presence is not asked, as for the
            -- deadline: a release timed by it tells the holder when the
            -- client was in the city.
            local bothHere = (c.anon_creator == true or Identity.byCitizenId(c.creator_cid) ~= nil)
                and Identity.byCitizenId(c.target_cid) ~= nil

            for _, h in ipairs(Storage.readHunters(c.id)) do
                if h.state == 'active' then
                    local k = c.id .. ':' .. h.hunter_cid
                    live[k] = true

                    local engaged = Death and Death.lastEngaged
                        and Death.lastEngaged(c.id, h.hunter_cid, c.target_cid)
                    if engaged and (now - engaged) <= elapsed then
                        -- Worked since the last pass.
                        idleFor[k] = 0
                    elseif bothHere then
                        idleFor[k] = (idleFor[k] or 0) + elapsed
                    end

                    if (idleFor[k] or 0) >= window then
                        if releaseIdleHold(c.id, h, idleFor[k]) then
                            released = released + 1
                        end
                        idleFor[k] = nil
                    end
                end
            end
        end
    end

    -- Holds that ended some other way are forgotten, so this is bounded by
    -- the exclusive contracts that are held right now.
    for k in pairs(idleFor) do
        if not live[k] then idleFor[k] = nil end
    end

    return released
end

--------------------------------------------------------------------------
-- Slot claiming (§3.5)
--------------------------------------------------------------------------

--- Whether this hunter collected on this contract too recently to collect
--- again. Asked by the claim and, ahead of it, by anything that makes a
--- player spend time on a claim that is certain to be refused — a handover
--- countdown holds a restrained player for thirty seconds.
---@param hunter table a hunter row
---@return boolean
function Contracts.slotCoolingDown(hunter)
    return hunter ~= nil and hunter.last_claim_at ~= nil
        and (os.time() - hunter.last_claim_at) < (Config.Limits.SlotCooldownSeconds or 0)
end

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
    if Contracts.slotCoolingDown(hunter) then
        return false, CB.ERR.SLOT_COOLDOWN
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

    -- Everything above was read before the lock was ours, and every read is
    -- an await: another claim can take the lock, pay its slot, advance
    -- next_slot and give the lock back in between. Acting on the slot read
    -- at the top paid this hunter out of a slot already settled — nothing
    -- moved, the claim reported success, and the kill, the photo token and
    -- the next ten minutes were spent on it. Read again under the lock,
    -- where nothing else can move them.
    local held = Storage.readContract(contractId)
    local fresh = Storage.readHunter(contractId, hunterCid)
    local refusal
    if not fresh or fresh.state ~= 'active' then
        refusal = CB.ERR.NOT_PARTICIPANT
    elseif Contracts.slotCoolingDown(fresh) then
        refusal = CB.ERR.SLOT_COOLDOWN
    elseif not held or (held.next_slot or 1) > (held.payout_slots or 1) then
        refusal = CB.ERR.ALREADY_SETTLED
    end
    if refusal then
        Contracts.transition(contractId, CB.STATE.COMPLETING, CB.STATE.ACCEPTED, 'claim_refused')
        return false, refusal
    end
    contract, hunter, slot = held, fresh, held.next_slot or 1

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

        -- And every party's card has just changed: which collection is on
        -- offer, how many are left, and what it pays. finalise() pushes on
        -- the last slot and nothing pushed on the ones before it, so a
        -- creator watching a three-payout contract went on being shown the
        -- first collection's money after it had been paid, and a second
        -- hunter went on competing for a slot that was gone.
        local cids = {}
        for _, row in ipairs(Storage.readHunters(contractId) or {}) do
            if row.state == 'active' then cids[#cids + 1] = row.hunter_cid end
        end
        Notify.pushParties(contract, cids, 'slot_claimed')
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

    -- What could not actually be handed back. A refund the creator's pockets
    -- had no room for is owed and retried on next login, not lost — but
    -- "everything you put up has been returned" is untrue in exactly that
    -- case, and it is the case where a player counts their money, finds it
    -- short, and reports it stolen.
    local owed = 0
    for _, line in ipairs(Storage.readEscrow(contractId)) do
        if line.owed_to == actor.cid and line.state ~= CB.ESCROW_STATE.SETTLED then
            owed = owed + 1
        end
    end

    Notify.toCitizen(actor.cid, 'Contract withdrawn', owed > 0
        and ('Nobody had taken it. Most of what you put up is back; %d thing(s) '
             .. 'would not fit and are waiting for you — they arrive when you '
             .. 'next have room.'):format(owed)
        or 'Nobody had taken it, so everything you put up has been returned.',
        { bypassBudget = true })
    return true, nil, { owed = owed }
end

--- Change a contract nobody has taken.
---
--- Only while it is unclaimed: once a hunter has accepted, they accepted it
--- as written, and a change from there goes through the amendment path
--- where they get a say.
---
--- The reward is not editable here, because moving escrow is money in and
--- out of a player's pocket and belongs on a path built for it:
--- Amendments.addEscrow puts more up, and Contracts.withdrawReward takes
--- part of it back. This changes only what the contract says.
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

    if changes.reason ~= nil or changes.reasonPreset ~= nil then
        -- Through the same function placing one goes through, so the two
        -- cannot drift apart again.
        local reason, reasonErr = reasonFor(actor, changes)
        if reasonErr then return false, reasonErr end

        -- Where the server stores no reason there is nothing here to
        -- change. The app's Edit dialog sends the field whatever the mode
        -- is, so refusing the whole request over it would make the deadline
        -- it arrived with unchangeable too — which is what happened.
        if Config.Reason.Mode ~= 'off' then
            contract.reason = reason
            touched[#touched + 1] = 'reason'
        end
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

--- Take part of a reward back out of escrow.
---
--- The other half of changing a reward. Adding to one already existed
--- (Amendments.addEscrow, which works even while a hunter holds the
--- contract, because a bigger reward cannot disadvantage them). Taking
--- value back out did not exist at all: a creator who put up too much
--- could only cancel the whole contract and place it again, losing their
--- place in every cooldown that keys on target and creator.
---
--- Refused the moment somebody is actually hunting it, for the same reason
--- cancelling is: a hunter who has started work, and staked a penalty to do
--- it, decided on the reward as written. Reducing it from under them is
--- exactly what escrow exists to prevent, and there is no approval path
--- that makes it fair, so this does not offer one.
---
--- What comes back is what went in. Each named line is released through the
--- ordinary guarded path, so a stack of items returns with its own
--- metadata and a weapon with its own serial — never a fresh clean copy.
---
--- Three things cannot be withdrawn, whatever the client names:
---   * a hunter's stake, which is not the creator's property;
---   * a line already owed to a named person, which is theirs;
---   * a line that is not `held` — settling and settled lines are already
---     on their way to somebody.
---
--- And a slot that was funded stays funded: emptying a slot's baseline
--- would leave a collection that pays nothing, which is refused at
--- creation and is refused here for the same reason.
---@param actor table
---@param contractId string
---@param lineIds string[] escrow line ids to hand back
---@return boolean ok
---@return string|nil err
---@return table|nil result
function Contracts.withdrawReward(actor, contractId, lineIds)
    contractId = Util.toId(contractId)
    if not contractId then return false, CB.ERR.INVALID_INPUT end
    if type(lineIds) ~= 'table' then return false, CB.ERR.INVALID_INPUT end

    local contract = Storage.readContract(contractId)
    if not contract then return false, CB.ERR.NOT_FOUND end
    if contract.creator_cid ~= actor.cid then return false, CB.ERR.NOT_PARTICIPANT end
    if CB.TERMINAL[contract.state] then return false, CB.ERR.ALREADY_SETTLED end
    if heldByAnyone(contractId) then return false, CB.ERR.BAD_STATE end

    -- Bounded before anything is read: a client naming ten thousand ids
    -- must not become ten thousand lookups.
    if #lineIds < 1 or #lineIds > Config.Limits.MaxEscrowLines then
        return false, CB.ERR.INVALID_INPUT
    end

    local wanted = {}
    local count = 0
    for i = 1, #lineIds do
        -- toLineId, not toId: an escrow line id carries the contract id and
        -- an index joined by a colon, which toId deliberately refuses.
        local id = Util.toLineId(lineIds[i])
        if not id then return false, CB.ERR.INVALID_INPUT end
        -- A repeated id is not an extra withdrawal; it is the same line
        -- named twice. Counted once so the totals below stay honest.
        if not wanted[id] then
            wanted[id] = true
            count = count + 1
        end
    end

    local lines = Storage.readEscrow(contractId)

    -- Which of the named ids this contract actually holds, and whether each
    -- is the creator's to take back.
    local matched = 0
    for i = 1, #lines do
        local line = lines[i]
        if wanted[line.id] then
            matched = matched + 1
            if line.portion ~= CB.PORTION.BASELINE and line.portion ~= CB.PORTION.BONUS then
                return false, CB.ERR.NOT_PARTICIPANT
            end
            if line.owed_to then return false, CB.ERR.NOT_PARTICIPANT end
            if line.state ~= CB.ESCROW_STATE.HELD then return false, CB.ERR.BAD_STATE end
        end
    end

    -- An id this contract does not hold is not ignored. Silently withdrawing
    -- the subset it recognised would tell the creator their whole request
    -- succeeded while part of the reward stayed where it was.
    if matched ~= count then return false, CB.ERR.NOT_FOUND end

    -- Every slot that is funded now must still be funded afterwards.
    -- Checked per slot rather than across the contract: a contract whose
    -- first collection is fully paid out has no held lines on that slot at
    -- all, and requiring one would refuse an ordinary withdrawal from the
    -- slot still being competed for.
    local before, after = {}, {}
    for i = 1, #lines do
        local line = lines[i]
        -- `owed_to` excluded, as every other reader of "what this contract
        -- pays" excludes it: Escrow.moneyValue, Escrow.goodsIn, the general
        -- release filter and Projection.rewardLines. A line promised to one
        -- named person is already spoken for, so counting it as funding meant
        -- a creator could take out the last line that actually pays and leave
        -- a live contract offering a hunter nothing. The route in is ordinary:
        -- withdraw part of a reward with full pockets, and the line that
        -- cannot be carried is queued and marked owed.
        if line.state == CB.ESCROW_STATE.HELD and not line.owed_to
            and line.portion == CB.PORTION.BASELINE then
            local slot = line.slot or 1
            before[slot] = before[slot] or {}
            before[slot][#before[slot] + 1] = line
            if not wanted[line.id] then
                after[slot] = after[slot] or {}
                after[slot][#after[slot] + 1] = line
            end
        end
    end

    for slot, slotLines in pairs(before) do
        if not Util.escrowIsEmpty(slotLines, CB.PORTION.BASELINE)
            and Util.escrowIsEmpty(after[slot] or {}, CB.PORTION.BASELINE) then
            return false, CB.ERR.INVALID_REWARD
        end
    end

    -- One release for the whole set: several would be several windows for
    -- an acceptance to land in the middle of, and several audit rows for
    -- one decision.
    --
    -- The hunter check above is not enough on its own. Every storage read
    -- between it and the money moving is a yield, and an acceptance can land
    -- in any of them — so the same question is asked again through the
    -- guard, once each line is out of `held` and can no longer be paid to
    -- anybody. At that point the answer is binding: a hunter who appeared
    -- gets the line put straight back, with nothing moved and nothing to
    -- unwind. Cancelling is safe from this by accident, because its state
    -- change is itself a compare-and-set; this has no state change to hide
    -- behind.
    local raced = false
    local ok, result = Escrow.release(contractId, actor.cid,
        { lines = wanted }, 'reward_reduced', function()
            if heldByAnyone(contractId) then
                raced = true
                return false
            end
            return true
        end)

    if raced then
        -- Somebody accepted while this was in flight. Every line the guard
        -- reached is back where it was.
        Audit.action('reward_reduce_raced', actor.cid, contractId,
            { lines = count, settled = result.settled, pending = result.pending })

        -- Nothing at all got out: the ordinary case, and the hunter has the
        -- contract exactly as they accepted it.
        --
        -- A QUEUED line got out too. It is marked owed to the creator, and
        -- from that moment every reader of what this contract pays skips it —
        -- so counting only settled lines here answered "that did not work"
        -- to a creator whose reward had already shrunk, returned before the
        -- hunter below was told, and skipped the audit row and the re-pricing
        -- further down. Measured: a contract worth 9,500 left at 8,500, the
        -- creator told the withdrawal failed, the hunter told nothing.
        if result.settled == 0 and result.pending == 0 then
            return false, CB.ERR.BAD_STATE
        end

        -- Something did. The guard runs per line, so an acceptance landing
        -- between two of them leaves the earlier ones already returned — a
        -- hunter holding a contract worth slightly less than the one they
        -- took. It cannot be unwound, because that money is in the
        -- creator's pocket and is rightfully theirs, so it is told rather
        -- than hidden: a hunter who finds out from a payout is a hunter who
        -- reports it as theft.
        local hunters = Storage.readHunters(contractId)
        for i = 1, #hunters do
            if hunters[i].state == 'active' then
                Notify.toCitizen(hunters[i].hunter_cid, 'Reward changed',
                    'The client was reducing the reward as you accepted this '
                    .. 'contract. Part of it was already withdrawn. Check what '
                    .. 'it pays now before you go to work.',
                    { bypassBudget = true })
            end
        end
    end

    -- Nothing moved: something else claimed the lines between the check
    -- above and here. A queued line DID move — it is owed to the creator and
    -- out of the pot — so it falls through to the audit row and the
    -- re-pricing below. It used to return success from here and skip both,
    -- which left no financial record of escrow leaving and left the buyout
    -- priced against money the contract no longer held: the transfer rail
    -- the comment below describes, reopened for any withdrawal that could
    -- not be handed over on the spot.
    if not ok and result.settled == 0 and result.pending == 0 then
        return false, CB.ERR.LOCKED
    end

    Audit.financial('reward_reduced', actor.cid, contractId,
        { lines = count, settled = result.settled, pending = result.pending })

    -- The buyout price is a multiple of the escrow, so it moves with it.
    --
    -- Without this the clamp held only at the moment the price was set, and
    -- this is the one path that takes escrow back out afterwards: fund
    -- 90,010, price the buyout at the 270,030 ceiling, withdraw the 90,000,
    -- and the target still pays 270,030 to a creator holding 10. That is
    -- exactly the uncapped, untaxed transfer rail between two cooperating
    -- players the clamp exists to prevent, reopened by a door added later.
    --
    -- Re-clamped rather than refused: the withdrawal is legitimate, and a
    -- creator who takes their money back should get a smaller buyout, not
    -- an error.
    Contracts.reclampToEscrow(contractId, actor.cid)

    return true, nil, result
end

--- Re-price both figures that are meant to be proportional to the escrow,
--- after some of that escrow has been taken back out.
---
--- Both clamps hold at the moment the figure is set and nowhere else, so
--- every path that removes escrow afterwards has to re-apply them or it is
--- a way round them. Fund 41,000, price the buyout at the 123,000 that
--- funding buys and the stake at 82,000, take the 40,000 back, and a
--- contract worth 1,000 charges a target 123,000 to escape and asks each
--- hunter for 82,000 to try — the uncapped transfer rails both clamps
--- exist to close, reopened by doors added later.
---
--- There are two such doors: withdrawReward, and the reduce_reward
--- amendment, which releases a whole unclaimed slot. The bailout was
--- re-clamped on the first and neither figure on the second.
---
--- Only what the NEXT player is quoted moves. A stake already put up is its
--- own escrow line and that line is the source of truth for what it is
--- worth, so nobody who has already accepted is repriced.
---@param contractId string
---@param actorCid string|nil whose action caused it, for the audit
function Contracts.reclampToEscrow(contractId, actorCid)
    local contract = Storage.readContract(contractId)
    if not contract then return end

    local held, heldMoney = {}, 0
    for _, line in ipairs(Storage.readEscrow(contractId) or {}) do
        -- And here too, for the same reason and with a sharper cost: this is
        -- what re-prices the buyout and the failure stake against what the
        -- contract still holds. Counting a queued line left the target being
        -- charged a price set against money the contract no longer pays.
        if line.state == CB.ESCROW_STATE.HELD and not line.owed_to then
            held[#held + 1] = line
            if CB.MONEY_ACCOUNTS[line.source] then
                heldMoney = heldMoney + (line.amount or 0)
            end
        end
    end

    local changed = false

    if (contract.bailout_amount or 0) > 0 then
        local clamped = Contracts.clampBailout(contract.bailout_amount, held)
        if clamped ~= contract.bailout_amount then
            contract.bailout_amount = clamped
            changed = true
            Audit.financial('bailout_reclamped', actorCid, contractId, { to = clamped })
        end
    end

    if (contract.penalty_amount or 0) > 0 then
        local clamped = Contracts.clampPenalty(contract.penalty_amount, heldMoney)
        if clamped ~= contract.penalty_amount then
            contract.penalty_amount = clamped
            changed = true
            Audit.financial('penalty_reclamped', actorCid, contractId, { to = clamped })
        end
    end

    if changed then Storage.writeContract(contract) end
end

---@param opts table|nil { forfeit = boolean } to say whether an expiry is
--- the hunters' failure; by default every expiry is
function Contracts.resolve(contractId, terminal, recipientCid, filter, reason, opts)
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
    local forfeit = terminal == CB.STATE.EXPIRED
    if forfeit and opts and opts.forfeit == false then forfeit = false end
    finalise(contractId, contract, forfeit)

    return true, result
end

--------------------------------------------------------------------------
-- Restart recovery (§10.4)
--------------------------------------------------------------------------

--- Hand over what an ending interrupted by a crash never reached.
---
--- Only lines nobody has tried to pay: still `held`, owed to nobody, and
--- with no `releasing_to`. A line that was mid-release when the process died
--- carries the name it was going to and may already have been paid, so it is
--- left exactly where recovery puts it — logged for staff. Everything else is
--- the ending's own unfinished business, released the way the ending would
--- have: stakes to whoever put them up (to the creator, for a hunter still on
--- a contract that expired), the rest back to the creator.
---@param contract table
---@param forfeit boolean
---@return integer released
local function releaseUntouched(contract, forfeit)
    local released = 0
    for _, line in ipairs(Storage.readEscrow(contract.id) or {}) do
        if line.state == CB.ESCROW_STATE.HELD and not line.owed_to
            and not line.releasing_to and line.portion ~= CB.PORTION.OWED then
            local recipient = contract.creator_cid
            if line.portion == CB.PORTION.STAKE then
                local hunter = line.staker and Storage.readHunter(contract.id, line.staker)
                local keeps = forfeit and hunter and hunter.state == 'active'
                recipient = keeps and contract.creator_cid or line.staker
            end
            if recipient then
                Escrow.release(contract.id, recipient, { line = line.id }, 'recovered_after_restart')
                released = released + 1
            end
        end
    end
    return released
end

--- Finish a contract whose ending a crash interrupted.
---
--- Two shapes, both left behind by a process that died part-way through:
---
---   * COMPLETING with every collection already paid. The last claim had
---     advanced the slot past the end and died before closing. Putting it
---     back to ACCEPTED, as recovery did, brought back a live contract with
---     nothing left to claim, which then ran out: the hunter who had
---     collected everything had their stake forfeited to the creator, and the
---     target was credited with surviving it.
---
---   * A terminal contract still holding escrow. `resolve` moves the state
---     first and the money after, so a crash in between left the creator's
---     escrow — and any stake — on a closed contract that nothing ever
---     releases again, and that no staff tool reported.
---@param contractId string
---@return string|nil what 'completed' | 'released' | nil when nothing was done
function Contracts.recoverEnded(contractId)
    local contract = Storage.readContract(contractId)
    if not contract then return nil end

    if contract.state == CB.STATE.COMPLETING
        and (contract.next_slot or 1) > (contract.payout_slots or 1) then
        releaseUntouched(contract, false)
        contract.resolved_at = contract.resolved_at or os.time()
        contract.resolution = contract.resolution or 'completed'
        Storage.writeContract(contract)
        Contracts.transition(contractId, CB.STATE.COMPLETING, CB.STATE.COMPLETED,
            'completed_on_recovery', SETTLING)
        if Contracts.onResolved then Contracts.onResolved(contractId) end
        return 'completed'
    end

    if CB.TERMINAL[contract.state] then
        local released = releaseUntouched(contract, contract.state == CB.STATE.EXPIRED)
        return released > 0 and 'released' or nil
    end

    return nil
end

return Contracts
