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

local LIVE_STATES = { [CH.STATE.ACTIVE] = true, [CH.STATE.ACCEPTED] = true, [CH.STATE.COMPLETING] = true }

--- Whether a hitman row is on the contract: holding it, or part-way
--- through an acceptance that has not been confirmed yet. 'joining' is a
--- first acceptance; 'rejoining' is a hitman who walked away taking it up
--- again, kept apart so a crash can put their earlier stint back rather
--- than erase it (Contracts.recoverJoining). Either counts toward who is on
--- it — so two acceptances cannot both fit under a cap, and nobody reads the
--- contract as empty — but only an active one can be paid, forfeit a stake,
--- or be released for idling.
---@param row table|nil
---@return boolean
local function holds(row)
    return row ~= nil and (row.state == 'active' or row.state == 'joining'
        or row.state == 'rejoining')
end
Contracts.holds = holds

--- Work that must not interleave with other work on the same keys.
---
--- Every store call yields on mysql, and each request runs in its own
--- coroutine, so two requests about one contract run side by side unless
--- something stops them: two cuts to one stake each wrote their half, a
--- penalty lowered while an acceptance was staking skipped the new stake,
--- and one player's two acceptances each counted the other as not there.
--- Checking before writing cannot close that; only one at a time can. The
--- other is refused as busy rather than queued, and a crash takes every
--- key with it, so nothing is ever held across a restart.
local busy = {}

---@param keys string[]
---@param fn function
---@return any ...
function Contracts.serialized(keys, fn, ...)
    for i = 1, #keys do
        if busy[keys[i]] then return false, CH.ERR.BUSY end
    end
    for i = 1, #keys do busy[keys[i]] = true end
    local out = table.pack(pcall(fn, ...))
    for i = 1, #keys do busy[keys[i]] = nil end
    if not out[1] then error(out[2], 0) end
    return table.unpack(out, 2, out.n)
end

--- See Contracts.retryStuckJoins.
local stuckJoins = {}

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

--- CH.TRANSITIONS and any transition out of a terminal state.
---
--- Moving a contract INTO a terminal state additionally requires the
--- settling token, which only `resolve` and `claimSlot` hold. Ending a
--- contract means settling stakes, returning the remainder and nudging the
--- parties; a path that flipped the state without doing those stranded a
--- hitman's stake once already. The token makes that mistake unreachable
--- rather than merely documented: a new path cannot end a contract without
--- going through one of the two functions that finish the job.
---@param settling table|nil the private token, for a terminal target only
---@return boolean ok
function Contracts.transition(contractId, expected, next_, reason, settling)
    if CH.TERMINAL[expected] then return false end
    if CH.TERMINAL[next_] and settling ~= SETTLING then return false end
    local allowed = CH.TRANSITIONS[expected]
    if not allowed or not allowed[next_] then return false end

    local ok = Storage.compareSetContractState(contractId, expected, next_)
    if ok then
        Audit.action('state_change', nil, contractId, { from = expected, to = next_, reason = reason })
    end
    return ok
end

--- Settle every hitman's stake on a contract that is ending.
---
--- Called from every terminal path. `forfeit` is true only when the ending
--- is the hitman's failure — an expiry while they still held it.
---@param contractId string
---@param creatorCid string
---@param forfeit boolean
--- Whether this hitman's stake is the client's when the contract fails.
---
--- Only a hitman who was on it while its deadline still stood. One whose
--- acceptance landed after the deadline — in the moment between the expiry
--- pass reading the contract and resolving it — could not have failed a
--- clock that had already run out, and forfeiting their stake paid the
--- client for an acceptance the hitman was then told had been refused.
---@param hitman table|nil a hitman row
---@param contract table|nil
---@return boolean
local function stakeForfeits(hitman, contract)
    if not hitman or hitman.state ~= 'active' then return false end
    local deadline = contract and contract.deadline_at
    if deadline and hitman.accepted_at and hitman.accepted_at > deadline then return false end
    return true
end

--- What each hitman has staked and still has held, by citizen id. Read
--- before anything settles the stakes, because settling empties the lines
--- a notice has to name the figure from.
---@param contractId string
---@return table<string, integer>
local function heldStakes(contractId)
    local out = {}
    for _, line in ipairs(Storage.readEscrow(contractId) or {}) do
        if line.portion == CH.PORTION.STAKE and line.staker
            and line.state == CH.ESCROW_STATE.HELD then
            out[line.staker] = (out[line.staker] or 0) + (line.amount or 0)
        end
    end
    return out
end

--- How many of a contract's lines are owed to someone and not yet in their
--- hands: a refund their pockets had no room for, or one queued while they
--- were away. It arrives later, so "everything has been returned" is untrue
--- in exactly that case.
---@return integer
local function owedTo(contractId, cid)
    local owed = 0
    for _, line in ipairs(Storage.readEscrow(contractId) or {}) do
        if line.owed_to == cid and line.state ~= CH.ESCROW_STATE.SETTLED then
            owed = owed + 1
        end
    end
    return owed
end

---@return table[] outcomes one per hitman still on the contract:
--- { cid, stake, forfeited, owed }, for the notice that tells them
local function settleStakes(contractId, creatorCid, forfeit, contract)
    local stakes = heldStakes(contractId)
    local outcomes = {}
    local hitmen = Storage.readHitmen(contractId)
    for i = 1, #hitmen do
        local hitman = hitmen[i]
        local toCreator = forfeit and stakeForfeits(hitman, contract)
        local _, result = Escrow.release(contractId,
            toCreator and creatorCid or hitman.hitman_cid,
            { portion = CH.PORTION.STAKE, staker = hitman.hitman_cid },
            toCreator and 'penalty_forfeited' or 'stake_returned')
        -- Only a hitman still on it is told it ended. One who walked away
        -- or was released already heard about it then.
        if hitman.state == 'active' then
            outcomes[#outcomes + 1] = {
                cid = hitman.hitman_cid,
                stake = stakes[hitman.hitman_cid] or 0,
                forfeited = toCreator and true or false,
                owed = result and (result.pending or 0) > 0 or false,
            }
        end
    end
    return outcomes
end

--- Everything that must happen exactly once when a contract ends, whichever
--- path got it there. Routing every terminal transition through here is what
--- stops a new path forgetting a step — the completion path already did.
---
--- The ending is passed in rather than read back from storage: the last
--- slot's claim runs this while the contract still says COMPLETING, and
--- only moves it to COMPLETED afterwards.
---@param contractId string
---@param contract table
---@param forfeitStakes boolean
---@param ending string the terminal CH.STATE this contract is ending in
---@param winnerCid string|nil on a completion, the hitman who finished it
local function finalise(contractId, contract, forfeitStakes, ending, winnerCid)
    -- Read before the stakes settle, while the hitman records still say who
    -- was on this contract: they are who needs their card to change.
    local hitmanCids = {}
    local hitmen = Storage.readHitmen(contractId)
    for i = 1, #hitmen do hitmanCids[#hitmanCids + 1] = hitmen[i].hitman_cid end

    local stakes = settleStakes(contractId, contract.creator_cid, forfeitStakes, contract)

    -- Anything still held — a top-up on a slot nobody claimed, an odd line
    -- from an amendment, the unpaid bonus on an elimination — goes back to
    -- the creator while it is still reachable.
    Escrow.release(contractId, contract.creator_cid, nil, 'unclaimed_remainder')

    -- Everyone whose card just changed. Read from storage rather than the
    -- caller's copy, so the state the app fetches is the settled one.
    local settled = Storage.readContract(contractId)
    Notify.pushParties(settled or contract, hitmanCids, ending)

    -- A push only moves an app that is already open. An expiry took a
    -- hitman's stake, and a buyout or a rival's kill took their contract,
    -- with nothing on the phone to say so (§11.4).
    Notify.contractEnded(settled or contract, ending, stakes, {
        winnerCid = winnerCid,
        creatorOwed = ending == CH.STATE.EXPIRED and owedTo(contractId, contract.creator_cid) or 0,
    })

    Notify.clearContract(contractId, settled or contract)
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
    if not targetActor then return false, CH.ERR.NOT_FOUND end

    -- The three parties must be distinct people, not just distinct characters.
    if targetActor.cid == actor.cid then return false, CH.ERR.SELF_TARGET end
    if Config.AntiCollusion.BlockSameAccount
        and Identity.sameAccount(targetActor.account, actor.account) then
        return false, CH.ERR.SAME_ACCOUNT
    end

    if Identity.isProtected(targetActor) and not Config.Targeting.AllowProtectedJobTargets then
        return false, CH.ERR.TARGET_IS_LEO
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
                local cooldown = (c.state == CH.STATE.BAILED_OUT)
                    and Config.Immunity.AfterBailoutSeconds
                    or Config.Limits.TargetCooldownAfterResolveSeconds
                if since < cooldown then
                    return false, CH.ERR.TARGET_RECENTLY_ON
                end
                -- Its own code. This is a policy wait of hours, and sharing
                -- RATE_LIMITED with the token bucket told the creator to
                -- "slow down" about it.
                if placedByThisPlayer(c) and since < Config.Limits.SameCreatorSameTargetCooldownSeconds then
                    return false, CH.ERR.SAME_TARGET_TOO_SOON
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
            if placedByThisPlayer(c) and c.state == CH.STATE.CANCELLED and c.resolved_at
                and (now - c.resolved_at) < Config.Amendments.CancelCooldownSeconds then
                return false, CH.ERR.CANCELLED_TOO_SOON
            end
        end
    end

    if byCreator >= Config.Limits.MaxActiveContractsPerCreator then return false, CH.ERR.LIMIT_REACHED end
    if byTarget >= Config.Limits.MaxActiveContractsPerTarget then
        return false, CH.ERR.TARGET_HAS_ENOUGH
    end

    -- New and freshly-connected players are not fair game.
    local immune, why = Contracts.isImmune(targetActor)
    if immune then return false, why or CH.ERR.TARGET_PROTECTED end

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
        -- refused the hitman standing over the body, told them to wait, and
        -- let the kill expire. Quitting was already not a way out of a kill;
        -- rejoining was.
        local sessionAgo = Identity.sessionSeconds and Identity.sessionSeconds(targetActor.cid)
        if not (deathAgo ~= nil and sessionAgo ~= nil and deathAgo > sessionAgo) then
            return true, CH.ERR.TARGET_JUST_ON
        end
    end

    local hours = Identity.playtimeHours(targetActor)
    if hours ~= nil and hours < Config.Immunity.MinTargetPlaytimeHours then
        return true, CH.ERR.TARGET_TOO_NEW
    end

    -- Someone who just got back up is not immediately fair game again:
    -- without this a multi-slot contract becomes respawn camping.
    --
    -- A claim on a death that happened BEFORE the respawn is exempt: the
    -- hitman earned it while the target was still down, and the target
    -- pressing respawn must not take it away (§7.4 proof window).
    --
    -- A live delivery is exempt too, and has to be. Taking somebody alive
    -- means restraining them, and restraining them all but always means
    -- putting them down first — so this rule fired on the hitman's own
    -- doing, on nearly every kidnapping, and told them to give the target a
    -- moment while that target was cuffed in the back of their car. The
    -- rule is against re-killing someone who has just respawned; a target
    -- already in hand is not being camped, they are being carried.
    local liveDelivery = opts and opts.fulfilment == CH.FULFILMENT.KIDNAPPING
    if not liveDelivery and Death and (Config.Immunity.PostRespawnSeconds or 0) > 0 then
        local since = Death.sinceRespawn(targetActor.cid)
        if since and since < Config.Immunity.PostRespawnSeconds then
            local respawnedAgo = since
            local claimPredatesRespawn = deathAgo ~= nil and deathAgo > respawnedAgo
            if not claimPredatesRespawn then return true, CH.ERR.TARGET_JUST_UP end
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
        if CH.MONEY_ACCOUNTS[lines[i].source] then
            moneyValue = moneyValue + (lines[i].amount or 0)
        end
    end

    -- A bailout needs a clean money escrow to be a multiple of. A contract
    -- funded only in goods or only in black money cannot offer one, for the
    -- same reason an items-only contract cannot.
    if moneyValue == 0 then return 0, CH.ERR.BUYOUT_NEEDS_CLEAN end

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
--- hitman later walks away or runs out of clock.
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

--- The failure stake a hitman must put up, clamped to what the contract is
--- worth (§14.18).
---
--- The same job Contracts.clampBailout does for the premium, and missing
--- for the stake, which is the side with the worse failure mode: a bailout
--- is a target choosing to pay, while a stake is taken from a hitman the
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
        if not index then return nil, CH.ERR.INVALID_INPUT end
        return Config.Reason.Presets[index]
    end

    if mode ~= 'freetext' then return '' end

    -- Kept to one character over the limit, so a reason too long can be
    -- told from one that fits: refused, never cut (§14.30). The page's box
    -- stops at the limit, so only a request made by hand is ever over it —
    -- and a cut one was placed and paid for saying something else.
    local reason = Util.sanitizeText(req.reason, Config.Reason.MaxLength + 1)
    if not reason then return nil, CH.ERR.INVALID_INPUT end
    if utf8.len(reason) > Config.Reason.MaxLength then return nil, CH.ERR.INVALID_INPUT end
    if Util.digitCount(reason) > Config.Reason.MaxDigits then return nil, CH.ERR.INVALID_INPUT end
    for _, pattern in ipairs(Config.Reason.PatternDenylist) do
        if reason:lower():find(pattern) then return nil, CH.ERR.INVALID_INPUT end
    end
    if phoneRefuses(actor.source, reason) then
        return nil, CH.ERR.INVALID_INPUT
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

    local mode = req.mode == CH.MODE.COMPETITIVE and CH.MODE.COMPETITIVE or CH.MODE.EXCLUSIVE

    -- Clamped to the ceiling, not dropped.
    --
    -- Util.toCount returns nil for anything ABOVE its maximum, so `or 0`
    -- turned a bonus over the cap into no bonus at all — and the contract
    -- was created anyway. A creator who asked for 300% on a server capped at
    -- 200 promised a live-delivery premium, surrendered nothing for it, and
    -- was told nothing; a hitman who delivered alive was paid a bonus of
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
        if CH.MONEY_ACCOUNTS[lines[i].source] then
            penaltyEscrow = penaltyEscrow + (lines[i].amount or 0)
        end
    end
    local penalty = Contracts.clampPenalty(req.penaltyAmount, penaltyEscrow)

    local contractId = Util.mintId(Util.randomId, 'ct', Storage.readContract)
    if not contractId then
        -- Every id on offer belongs to a contract that already exists.
        -- Refusing costs this creator one attempt; writing would rewrite
        -- somebody else's contract under them.
        Audit.rejected('contract_id_exhausted', actor.cid, nil, {})
        return nil, CH.ERR.BAD_STATE
    end

    local now = os.time()
    local protectingJob = Identity.protectedBy(targetActor)
    local contract = {
        id            = contractId,
        creator_cid   = actor.cid,
        creator_account = actor.account,
        creator_name  = actor.name,
        target_cid    = targetActor.cid,
        target_name   = targetActor.name,
        target_protected = protectingJob ~= nil,
        -- The job that makes them an officer, where one does: the advisory
        -- names it, and an officer on a second job for the evening was
        -- announced to their colleagues as a mechanic.
        target_job    = (protectingJob and protectingJob.name)
                        or (targetActor.job and targetActor.job.name) or nil,
        reason        = reason,
        mode          = mode,
        state         = CH.STATE.ACTIVE,
        anon_creator  = req.anonymous == true,
        bonus_percent = bonusPercent,
        payout_slots  = slotCount,
        slots_claimed = 0,
        next_slot     = 1,
        bailout_amount = bailout,
        penalty_amount = penalty,
        created_at    = now,
        -- Rounded, so neither dates the placement to the second (§14.32).
        -- Never past the lifetime, which would be a deadline that never came.
        deadline_at   = Util.roundClock(now + math.min(Config.Limits.DefaultDeadlineSeconds,
                            Config.Limits.ContractLifetimeSeconds)),
        expires_at    = Util.roundClock(now + Config.Limits.ContractLifetimeSeconds),
        paused_ms     = 0,
    }

    -- Anonymity is free by default; where a server charges for it, the fee
    -- is taken before the escrow so a creator who cannot afford it is
    -- refused rather than half-charged (§4).
    if contract.anon_creator and (Config.Anonymity.CreatorFee or 0) > 0 then
        local account = Config.Anonymity.FeeAccount or 'bank'
        if not Util.charge(actor.player, account, Config.Anonymity.CreatorFee) then
            return nil, CH.ERR.INSUFFICIENT
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
        return nil, CH.ERR.BAD_STATE
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

--- The deadline less every pause that has ended. Ending a pause moves the
--- deadline out by exactly the time it adds to paused_ms (Storage.endPause),
--- so this changes only when somebody moves the deadline itself.
---@param contract table
---@return number|nil
local function unpausedDeadline(contract)
    if not contract.deadline_at then return nil end
    return contract.deadline_at - (contract.paused_ms or 0) / 1000
end

--- Why a stake cannot be taken on this contract's clock, or nil.
---
--- A stake on a contract about to run out is a stake handed to the client:
--- nobody can work a target in the minutes left, and the client can set a
--- contract nobody holds to run out in minutes (§14.18). And the deadline
--- is part of the terms, like the stake: brought forward since `shown`, it
--- is refused rather than staked on. A minute's slack for the clock itself.
--- Contracts that carry no stake have nothing to lose to either.
---@param contract table
---@param shown integer|nil the deadline the hitman was shown
---@return string|nil err
local function stakeTimeRefusal(contract, shown)
    if (contract.penalty_amount or 0) <= 0 or not contract.deadline_at then return nil end
    -- A paused clock has what it had when it stopped.
    local left = contract.deadline_at - (contract.paused_since or os.time())
    if left < (Config.Penalty.MinWindowMinutes or 0) * 60 then
        return CH.ERR.TOO_LITTLE_TIME
    end
    if shown and contract.deadline_at < shown - 60 then
        return CH.ERR.TERMS_CHANGED
    end
    return nil
end

--- Accept a contract. Conditional write: in exclusive mode the ACTIVE →
--- ACCEPTED transition is what reserves it, so two hitmen racing produce
--- exactly one winner (§14.34).
---@param opts table|nil { disclosed = n } the stake the page had on screen
---@return boolean ok
---@return string|nil err
local function acceptUnlocked(actor, contractId, anonymous, opts)
    local contract = Storage.readContract(contractId)
    if not contract then return false, CH.ERR.NOT_FOUND end

    -- Against THIS read, the one the stake below is charged from. The net
    -- event checked a read of its own, one await earlier, and a reprice
    -- landing between the two was charged in full.
    if opts and opts.checkDisclosure
        and not Contracts.stakeWasDisclosed(contract, opts.disclosed) then
        return false, CH.ERR.TERMS_CHANGED
    end

    if contract.state ~= CH.STATE.ACTIVE and contract.state ~= CH.STATE.ACCEPTED then
        -- Closed is not "not right now". The board drops a closed contract
        -- only on its next read, so tapping Accept on one that was cancelled,
        -- expired, bought out or completed a moment ago is the ordinary case,
        -- and it will never be acceptable again. COMPLETING is the one state
        -- here that really is momentary.
        if CH.TERMINAL[contract.state] then return false, CH.ERR.ALREADY_SETTLED end
        return false, CH.ERR.BAD_STATE
    end

    -- Past its deadline with the clock running, or past its lifetime, it is
    -- ending: the next expiry pass closes it, whatever this call does. The
    -- same test the pass applies. Accepted anyway, the stake taken here was
    -- written onto an active row the pass then found and forfeited to the
    -- client, and the hitman was told the contract had closed.
    if Contracts.isOverdue(contract, os.time()) then
        return false, CH.ERR.ALREADY_SETTLED
    end

    -- Too little time left to stake on, or less than the page showed.
    -- Refused before anything is taken.
    -- The echo is disclosure, so it goes with the stake's (stakeWasDisclosed).
    local shown = opts and opts.checkDisclosure and Config.Penalty.RequireDisclosureOnAccept
        and type(opts.shownDeadline) == 'number' and opts.shownDeadline or nil
    local timeErr = stakeTimeRefusal(contract, shown)
    if timeErr then return false, timeErr end
    -- Kept by value: on the memory store `contract` is the stored row
    -- itself, and would read whatever the deadline is moved to next.
    local checkedDeadline = unpausedDeadline(contract)

    -- A player may not take one on themselves, their own contract, or a contract
    -- created by another of their own characters (§13.1).
    if contract.target_cid == actor.cid then return false, CH.ERR.SELF_TARGET end
    if contract.creator_cid == actor.cid then return false, CH.ERR.SELF_ACCEPT end
    if Config.AntiCollusion.BlockSameAccount then
        if Identity.sameAccount(contract.creator_account, actor.account) then
            return false, CH.ERR.SAME_ACCOUNT
        end
        local targetActor = Identity.byCitizenId(contract.target_cid)
        if targetActor and Identity.sameAccount(targetActor.account, actor.account) then
            return false, CH.ERR.SAME_ACCOUNT
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
    local previous = Storage.readHitman(contractId, actor.cid)
    if holds(previous) then
        return false, CH.ERR.ALREADY_HOLDING
    end
    -- Copied out: on the in-process store `previous` IS the stored row, so
    -- reactivating it below changes these fields underneath us.
    local previousState = previous and previous.state
    local previousAnon = previous and previous.anon
    local previousAcceptedAt = previous and previous.accepted_at
    -- A row an acceptance wrote and then took back (the contract closed or
    -- was busy under it) was never a stint: nobody held the contract on it,
    -- and no fee was kept for it. It is reused for its id and alias, and
    -- otherwise counts for nothing.
    local stint = previous ~= nil and previousState ~= 'refused'

    -- Coming back cannot buy anonymity the first stint gave away. The alias
    -- and the thread are the same ones, so a creator who was shown
    -- "Operative #1 (their name)" and that operative's messages knows
    -- exactly who the anonymous Operative #1 is — and the fee used to be
    -- taken for it all the same. Named again, charged nothing, and told why.
    local renamed = false
    if stint and not previousAnon and anonymous then
        anonymous = false
        renamed = true
    end

    local held = Storage.countHitmanContracts(actor.cid, LIVE_STATES)
    if held >= Config.Limits.MaxAcceptedPerHitman then return false, CH.ERR.LIMIT_REACHED end

    local existing = Storage.readHitmen(contractId)
    local activeCount = 0
    for i = 1, #existing do
        if holds(existing[i]) then activeCount = activeCount + 1 end
        -- Released from it for sitting on it, on this character or another:
        -- taking it straight back would make the release a reset.
        if existing[i].state == 'released' and (existing[i].hitman_cid == actor.cid
            or Identity.sameAccount(existing[i].hitman_account, actor.account)) then
            return false, CH.ERR.HOLD_RELEASED
        end
    end

    -- Aliases are numbered from everyone who has ever held this contract,
    -- not from the live count: reusing "Operative #2" after someone abandons
    -- makes two different people indistinguishable in the creator's threads.
    local aliasNumber = #existing + 1

    if contract.mode == CH.MODE.EXCLUSIVE then
        -- The same fact as a full competitive contract — somebody else has
        -- it, try another or come back if they drop out — so the same code.
        -- An exclusive contract stays listed while it is held, so this is an
        -- answer hitmen read often, and "Not right now." named neither the
        -- reason nor what to do about it.
        if activeCount > 0 then return false, CH.ERR.CONTRACT_FULL end
    elseif activeCount >= Config.Limits.MaxHitmenPerContract then
        -- Not LIMIT_REACHED: that one is about what the CALLER is holding,
        -- and this is about what the contract is holding.
        return false, CH.ERR.CONTRACT_FULL
    end

    -- The anonymity fee: checked here, before anything is taken, and
    -- charged only once the acceptance is certain (below). Refused if it
    -- cannot be covered (§4: paid BEFORE anonymity is granted).
    --
    -- It was once taken last with no check first, and a hitman who could
    -- not cover it was simply named: the creator's phone said "accepted by
    -- <their name>" while the page told the hitman "Contract accepted,
    -- anonymously." Anonymity is the one thing in this resource that cannot
    -- be given back once it has been lost, so it is not something to
    -- downgrade on somebody's behalf. Then it was taken first, and a process
    -- that died in any of the awaits after it had spent the fee with no row,
    -- no line and no record that recovery could give it back from.
    --
    -- Once per contract. Coming back anonymous after an anonymous stint is
    -- the same alias and the same thread, anonymity already paid for here;
    -- charging it again bought nothing, and a hitman who could not cover
    -- the second fee was refused a contract they were already anonymous on.
    -- A refused row is not a stint, so it has paid for nothing.
    local feeAccount = Config.Anonymity.FeeAccount or 'bank'
    local paidBefore = stint and previousAnon == true
    local fee = (anonymous and not paidBefore and (Config.Anonymity.HitmanFee or 0) > 0)
        and Config.Anonymity.HitmanFee or 0

    -- The failure penalty is staked here, at acceptance, or not at all: a
    -- penalty that is only charged after a failure is a penalty the hitman
    -- can walk away from (§3.6). The hitman is told the amount before this
    -- point, and refusing to stake simply refuses the contract.
    --
    -- The fee's account is set aside first and the stake comes from
    -- whatever is left. Choosing the stake's account first took it from the
    -- bank whenever the bank covered it, and then refused a hitman whose
    -- cash could have paid the stake as short of money for the fee.
    local stake = contract.penalty_amount or 0
    local left = {
        bank = actor.player.Functions.GetMoney('bank') or 0,
        cash = actor.player.Functions.GetMoney('cash') or 0,
    }
    if fee > 0 then
        if (left[feeAccount] or 0) < fee then return false, CH.ERR.INSUFFICIENT end
        left[feeAccount] = left[feeAccount] - fee
    end
    local stakeAccount = left.bank >= stake and 'bank' or 'cash'
    if stake > 0 and (left[stakeAccount] or 0) < stake then
        return false, CH.ERR.INSUFFICIENT
    end

    local hitmanId = previous and previous.id
        or Util.mintId(Storage.nextId, 'hn', Storage.readHitmanById)
    if not hitmanId then
        Audit.rejected('hitman_id_exhausted', actor.cid, contractId, {})
        return false, CH.ERR.BAD_STATE
    end

    -- The row first, before the contract is reserved and before anything is
    -- taken. A crash after it leaves a row boot recovery can find and undo
    -- (Contracts.recoverJoining); a crash before it has taken nothing. The
    -- stake used to come first, and a crash between the two left money held
    -- against no row that nothing would ever return — and an exclusive
    -- contract reserved for nobody, refusing everyone.
    --
    -- A hitman taking the contract up again keeps their earlier stint on the
    -- row until this one is confirmed: 'rejoining' leaves its anonymity and
    -- start alone, so recovery can put back the stint a crash interrupted
    -- instead of erasing it (what anonymity it bought, and what the client
    -- already saw).
    local record
    local joinedAt = os.time()

    -- Whether THIS call is the one that advanced the contract, which is the
    -- only thing that makes reverting it safe. A broke player tapping Accept
    -- once flipped a competitive contract to `accepted` for every viewer of
    -- the board, with no hitman on it, and left it that way.
    local advanced = false
    -- The lines the stake went into, once the take has returned them.
    local stakeIds

    --- Take this acceptance back: the stake home, then the row as it was,
    --- then the reservation. In that order, so a crash part-way leaves a
    --- joining row that recovery takes back the same way, and never a stake
    --- with no row to say whose it is. By the lines the take returned; by
    --- staker only for a take that threw part-way and returned none.
    local function unwind(reason)
        if stakeIds and next(stakeIds) then
            Escrow.release(contractId, actor.cid, { lines = stakeIds }, reason)
        elseif stake > 0 then
            Escrow.release(contractId, actor.cid,
                { portion = CH.PORTION.STAKE, staker = actor.cid }, reason)
        end
        if previous then
            Storage.updateHitman(previous.id, { state = previousState,
                anon = previousAnon == true, accepted_at = previousAcceptedAt })
        elseif record then
            Storage.updateHitman(record.id, { state = 'refused', left_at = os.time() })
        end
        if advanced then
            Contracts.transition(contractId, CH.STATE.ACCEPTED, CH.STATE.ACTIVE, reason)
        end
    end

    -- Everything from here to the fee either completes or is taken back.
    -- A throw — a dropped database connection is an ordinary one — used to
    -- leave the row joining: holding the contract against everyone, while
    -- the hitman who had paid a stake for it could neither work it, abandon
    -- it nor take it again, until a restart.
    local done, ok, err, nowState = pcall(function()
        if previous then
            local joining = previousState == 'refused' and 'joining' or 'rejoining'
            Storage.updateHitman(previous.id, { state = joining })
            record = {}
            for k, v in pairs(Storage.readHitman(contractId, actor.cid) or previous) do record[k] = v end
            record.state = joining
        else
            record = {
                id            = hitmanId,
                contract_id   = contractId,
                hitman_cid    = actor.cid,
                hitman_account = actor.account,
                hitman_name   = actor.name,
                alias         = 'Operative #' .. tostring(aliasNumber),
                anon          = anonymous == true,
                accepted_at   = joinedAt,
                -- Not holding it yet: confirmed below, once the contract has
                -- been read again and found open. An ending that lands in
                -- between returns a joining hitman's stake rather than
                -- forfeiting it — they were never told they had it.
                state         = 'joining',
            }
            Storage.addHitman(record)
        end

        if contract.mode == CH.MODE.EXCLUSIVE then
            -- Reserved now that the row is there to say by whom.
            if not Contracts.transition(contractId, CH.STATE.ACTIVE, CH.STATE.ACCEPTED, 'accepted') then
                unwind('accept_locked')
                -- Closed since it was read is not "try again".
                local now = Storage.readContract(contractId)
                if now and CH.TERMINAL[now.state] then return false, CH.ERR.ALREADY_SETTLED end
                return false, CH.ERR.LOCKED
            end
            advanced = true
        end

        if stake > 0 then
            local taken, takeErr, ids = Escrow.take(actor, contractId, { {
                slot = 0, portion = CH.PORTION.STAKE, source = stakeAccount,
                amount = stake, staker = actor.cid,
            } })
            stakeIds = ids
            if not taken then
                unwind('stake_failed')
                -- A contract busy with another take is not the hitman being
                -- short of money.
                return false, takeErr == CH.ERR.LOCKED and CH.ERR.LOCKED or CH.ERR.INSUFFICIENT
            end
            Audit.financial('stake_taken', actor.cid, contractId, { amount = stake })
        end

        -- Is the contract still open, now that this hitman is on it?
        --
        -- The state was read at the top, and every store call since is a
        -- yield on mysql. A contract that closed in one of them — the
        -- creator cancelling, another hitman collecting the last payout of a
        -- competitive one, a buyout, the expiry pass — ran its settlement
        -- without this stake, so nothing would ever return it. Asked after
        -- the row and the stake, which is what makes the answer binding: an
        -- ending that has not started yet will find both when it settles
        -- stakes, and one that has started is visible here. COMPLETING is
        -- refused too, because a claim on the last payout settles stakes
        -- before it marks the contract completed.
        local now = Storage.readContract(contractId)
        local state = now and now.state
        if state ~= CH.STATE.ACTIVE and state ~= CH.STATE.ACCEPTED then
            unwind('accept_on_closed')
            Audit.rejected('accept_on_closed', actor.cid, contractId, { state = state })
            if state == CH.STATE.COMPLETING then return false, CH.ERR.LOCKED end
            return false, CH.ERR.ALREADY_SETTLED
        end

        -- And the deadline, read again now that this hitman is on it. The
        -- client could bring it in during any await before the row above
        -- existed, because nobody held the contract to stop them. This read
        -- is after the row, and a client's change is written before it looks
        -- for holders (Contracts.bringDeadlineIn), so one of the two always
        -- sees the other. Only whether it moved in: the window itself was
        -- measured above. Net of pauses, because a pause ending in the
        -- awaits pushes the deadline out by its length and would hide a cut
        -- no larger than that.
        local nowDeadline = unpausedDeadline(now)
        if stake > 0 and checkedDeadline and nowDeadline
            and nowDeadline < checkedDeadline then
            unwind('deadline_moved')
            Audit.rejected('deadline_moved', actor.cid, contractId,
                { was = checkedDeadline, now = nowDeadline })
            return false, CH.ERR.TERMS_CHANGED
        end

        -- And the penalty. The stake was taken at the figure read at the
        -- top; a reward withdrawn in the awaits since re-clamps it, and a
        -- hitman holding a stake the contract no longer asks for — or less
        -- than it now asks for — is on terms nobody agreed to.
        if (now.penalty_amount or 0) ~= stake then
            unwind('penalty_moved')
            Audit.rejected('penalty_moved', actor.cid, contractId,
                { was = stake, now = now.penalty_amount })
            return false, CH.ERR.TERMS_CHANGED
        end

        -- Confirmed, if the row is still this acceptance's. Written only
        -- where it is still joining: anything that took it off joining in
        -- the awaits — boot recovery, which refuses a joining row as the
        -- dead process's — is not silently reversed into a hold with no
        -- stake behind it.
        if not Storage.confirmHitman(record.id, anonymous == true, joinedAt) then
            unwind('accept_superseded')
            Audit.rejected('accept_superseded', actor.cid, contractId, {})
            return false, CH.ERR.BUSY
        end
        record.state, record.anon, record.accepted_at = 'active', anonymous == true, joinedAt
        -- Somebody holds it now, which is what the idle-hold sweep reads.
        heldIndex[contractId] = true

        -- The fee, now that the acceptance stands. Checked above; a balance
        -- that moved since is refused the same way, never downgraded to a
        -- name.
        if fee > 0 and not Util.charge(actor.player, feeAccount, fee) then
            unwind('anonymity_fee_failed')
            Audit.rejected('anonymity_fee_failed', actor.cid, contractId, { amount = fee })
            return false, CH.ERR.INSUFFICIENT
        end
        return true, nil, state
    end)

    if not done then
        -- Put back what can be put back, and if even that fails — the store
        -- that just threw may throw again — leave it for the maintenance tick
        -- to finish (Contracts.retryStuckJoins).
        if not pcall(unwind, 'accept_error') then stuckJoins[contractId] = true end
        error(ok, 0)
    end
    if not ok then return false, err end

    -- Competitive: advanced only now, with this hitman's stake and row in
    -- place. A no-op when somebody else already advanced it.
    if contract.mode ~= CH.MODE.EXCLUSIVE and nowState == CH.STATE.ACTIVE then
        Contracts.transition(contractId, CH.STATE.ACTIVE, CH.STATE.ACCEPTED, 'accepted')
    end

    -- Recorded once the acceptance it paid for has actually happened.
    if fee > 0 then
        Audit.financial('anonymity_fee', actor.cid, contractId,
            { amount = fee, role = 'hitman' })
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

    return true, nil, record
end

--- Accept a contract, one acceptance at a time per contract and per player.
---
--- Per contract, so a penalty change or a second acceptance cannot land in
--- the middle of this one's awaits; per player, so their two acceptances
--- each count the other against MaxAcceptedPerHitman. See acceptUnlocked.
function Contracts.accept(actor, contractId, anonymous, opts)
    contractId = Util.toId(contractId)
    if not contractId then return false, CH.ERR.INVALID_INPUT end
    return Contracts.serialized({ 'contract:' .. contractId, 'hitman:' .. tostring(actor.cid) },
        acceptUnlocked, actor, contractId, anonymous, opts)
end

--- Contracts an acceptance could not be taken back on after a throw, where
--- the taking back threw too. Finished by the maintenance tick once nothing
--- is being done to them: with every acceptance holding its contract for as
--- long as it runs, a joining row on a contract nobody holds is left over.
function Contracts.retryStuckJoins()
    local done = 0
    for contractId in pairs(stuckJoins) do
        local ran, err = Contracts.serialized({ 'contract:' .. contractId }, function()
            local contract = Storage.readContract(contractId)
            if contract then Contracts.recoverJoining(contract) end
            return true
        end)
        if ran then
            stuckJoins[contractId] = nil
            done = done + 1
        elseif err ~= CH.ERR.BUSY then
            break
        end
    end
    return done
end

--- A hitman walks away. The contract reverts to open rather than resolving,
--- and the failure penalty applies if one was staked.
function Contracts.abandon(actor, contractId)
    local contract = Storage.readContract(contractId)
    if not contract then return false, CH.ERR.NOT_FOUND end

    if CH.TERMINAL[contract.state] or contract.state == CH.STATE.COMPLETING then
        return false, CH.ERR.BAD_STATE
    end

    local hitman = Storage.readHitman(contractId, actor.cid)
    if not hitman or hitman.state ~= 'active' then return false, CH.ERR.NOT_PARTICIPANT end

    Storage.updateHitman(hitman.id, { state = 'abandoned', left_at = os.time() })

    -- Walking away from an accepted contract forfeits the stake to the
    -- creator. That is what the penalty is for.
    local stake = heldStakes(contractId)[actor.cid] or 0
    local forfeited = Escrow.release(contractId, contract.creator_cid,
        { portion = CH.PORTION.STAKE, staker = actor.cid }, 'penalty_forfeited')
    if forfeited then
        Audit.financial('stake_forfeited', actor.cid, contractId, {})
    end

    local remaining = 0
    local hitmen = Storage.readHitmen(contractId)
    for i = 1, #hitmen do
        if holds(hitmen[i]) then remaining = remaining + 1 end
    end

    -- With nobody left holding it, an exclusive contract goes back on the
    -- board. A contract mid-settlement is left alone: claimSlot owns that
    -- transition and will land it in ACCEPTED or COMPLETED itself.
    if remaining == 0 and contract.state == CH.STATE.ACCEPTED then
        if Contracts.transition(contractId, CH.STATE.ACCEPTED, CH.STATE.ACTIVE, 'abandoned') then
            -- Counted before the revert landed, so a hitman who accepted in
            -- between is holding a contract that just went back on the
            -- board — refused every claim and forfeiting their stake at
            -- expiry. Looked at again now it has, and put back if so.
            for _, row in ipairs(Storage.readHitmen(contractId) or {}) do
                if holds(row) then
                    Contracts.transition(contractId, CH.STATE.ACTIVE, CH.STATE.ACCEPTED, 'rejoined')
                    break
                end
            end
        end
    end

    if Progression then Progression.onFailed(actor.cid) end

    -- Anything holding state for this hitman on this contract is told.
    -- A handover they had armed is the one that matters: it does not pay
    -- out to somebody who walked away, but it does hold a countdown slot
    -- until the process restarts.
    if Contracts.onHitmanLeft then
        Contracts.onHitmanLeft(contractId, actor.cid, 'abandoned')
    end

    -- The client's card still said who was on it, and Edit and Withdraw
    -- stayed hidden after the last hitman walked away.
    local after = Storage.readContract(contractId) or contract
    local others = {}
    for _, row in ipairs(Storage.readHitmen(contractId) or {}) do
        if holds(row) and row.hitman_cid ~= actor.cid then others[#others + 1] = row.hitman_cid end
    end
    Notify.push(after.creator_cid, 'abandoned')
    for i = 1, #others do Notify.push(others[i], 'abandoned') end
    -- And the phone told: the client gained a stake, or their contract
    -- went back on the board, with nothing to say why.
    -- The stake read before the release: one the client is offline for is
    -- owed to them rather than settled, and is still theirs.
    Notify.hitmanLeft(after, stake, #others)

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
--- for failing to find a target who is not there. [contractId:hitmanCid].
local idleFor = {}
local lastIdleSweep = nil

--- The same, counting time without an attempt on the target: no hit landed
--- and no handover armed. [contractId:hitmanCid].
local unattemptedFor = {}

--- When a hitman last armed a handover on a contract. [contractId:hitmanCid].
local armedAt = {}

--- A handover was armed: an attempt, which keeps an exclusive hold.
function Contracts.noteAttempt(contractId, hitmanCid)
    armedAt[contractId .. ':' .. hitmanCid] = os.time()
end

--- Rebuild the index of held contracts after a restart, when contracts may already be held
--- that this process never saw accepted.
---@return integer indexed
function Contracts.reindexHolds()
    heldIndex = {}
    local n = 0
    for _, c in ipairs(Storage.allContracts()) do
        if c.state == CH.STATE.ACCEPTED or c.state == CH.STATE.COMPLETING then
            heldIndex[c.id] = true
            n = n + 1
        end
    end
    return n
end

--- Take one idle operative off an exclusive contract and put it back on the
--- board. Their stake comes back: the release is the remedy, not a fine.
---@return boolean released
local function releaseIdleHold(contractId, hitman, idleSeconds, why)
    -- Re-read: a payout or an abandonment may have moved it since the sweep
    -- read it, and a hitman being paid is not one to release.
    local contract = Storage.readContract(contractId)
    if not contract or contract.state ~= CH.STATE.ACCEPTED then return false end
    local current = Storage.readHitman(contractId, hitman.hitman_cid)
    if not current or current.state ~= 'active' then return false end

    Storage.updateHitman(current.id, { state = 'released', left_at = os.time() })

    Escrow.release(contractId, current.hitman_cid,
        { portion = CH.PORTION.STAKE, staker = current.hitman_cid }, 'stake_returned_idle')

    local remaining = 0
    for _, h in ipairs(Storage.readHitmen(contractId)) do
        if holds(h) then remaining = remaining + 1 end
    end
    if remaining == 0 then
        Contracts.transition(contractId, CH.STATE.ACCEPTED, CH.STATE.ACTIVE, 'idle_hold_released')
    end

    if Contracts.onHitmanLeft then
        Contracts.onHitmanLeft(contractId, current.hitman_cid, 'idle_hold_released')
    end

    local minutes = math.floor(idleSeconds / 60)
    Notify.toCitizen(current.hitman_cid, 'Taken off a contract',
        ('You held a contract for %d minutes without %s, so it has gone back on the '
            .. 'board. Your stake has been returned.'):format(minutes,
            why == 'no_attempt' and 'making an attempt on its target'
                or 'going near its target'),
        { bypassBudget = true })
    Notify.toCitizen(contract.creator_cid, 'Contract back on the board',
        'The operative holding your contract was not working it, so it is open again.')
    Notify.pushParties(Storage.readContract(contractId) or contract,
        { current.hitman_cid }, 'released')

    Audit.action('hold_released_idle', current.hitman_cid, contractId,
        { idle = idleSeconds, why = why or 'idle' })
    return true
end

--- Release every exclusive hold that has gone unworked for too long.
--- Driven by the maintenance tick; the clock is advanced by however long it
--- has been since the last pass, so a slow tick neither loses nor gains time.
---@return integer released
function Contracts.releaseIdleHolds()
    local window = Config.Limits.ExclusiveIdleReleaseSeconds or 0
    local attemptWindow = Config.Limits.ExclusiveAttemptWindowSeconds or 0
    local now = os.time()
    local elapsed = lastIdleSweep and math.max(0, now - lastIdleSweep) or 0
    lastIdleSweep = now
    if window <= 0 and attemptWindow <= 0 then
        idleFor, unattemptedFor = {}, {}
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
        if not c or c.state ~= CH.STATE.ACCEPTED then
            -- Resolved, or back on the board: nobody holds it now. A contract
            -- mid-settlement stays, since a failed payout lands it back here.
            if not c or c.state ~= CH.STATE.COMPLETING then heldIndex[contractId] = nil end
        elseif c.mode == CH.MODE.EXCLUSIVE then
            -- An anonymous creator's presence is not asked, as for the
            -- deadline: a release timed by it tells the holder when the
            -- client was in the city.
            -- A target in prison counts as away here too, as it does for the
            -- deadline: the hold's idle clock ran on through the sentence,
            -- and the hitman was taken off for not going near a target
            -- locked in Bolingbroke.
            local targetActor = Identity.byCitizenId(c.target_cid)
            local targetHere = targetActor ~= nil
                and not (Config.Limits.PauseWhileTargetJailed and Identity.isJailed(targetActor))
            local bothHere = (c.anon_creator == true or Identity.byCitizenId(c.creator_cid) ~= nil)
                and targetHere

            for _, h in ipairs(Storage.readHitmen(c.id)) do
                if h.state == 'active' then
                    local k = c.id .. ':' .. h.hitman_cid
                    live[k] = true

                    local engaged = Death and Death.lastEngaged
                        and Death.lastEngaged(c.id, h.hitman_cid, c.target_cid)
                    if engaged and (now - engaged) <= elapsed then
                        -- Worked since the last pass.
                        idleFor[k] = 0
                    elseif bothHere then
                        idleFor[k] = (idleFor[k] or 0) + elapsed
                    end

                    -- And an attempt: near is not enough. A target's friend
                    -- is near the target by definition, which reset the clock
                    -- above on every pass while the contract stayed frozen.
                    local hit = Death and Death.lastHit and Death.lastHit(h.hitman_cid, c.target_cid)
                    local attempt = math.max(hit or 0, armedAt[k] or 0)
                    if attempt > 0 and (now - attempt) <= elapsed then
                        unattemptedFor[k] = 0
                    elseif bothHere then
                        unattemptedFor[k] = (unattemptedFor[k] or 0) + elapsed
                    end

                    local why
                    if window > 0 and (idleFor[k] or 0) >= window then
                        why = 'idle'
                    elseif attemptWindow > 0 and (unattemptedFor[k] or 0) >= attemptWindow then
                        why = 'no_attempt'
                    end
                    if why then
                        local held = why == 'idle' and idleFor[k] or unattemptedFor[k]
                        if releaseIdleHold(c.id, h, held, why) then
                            released = released + 1
                        end
                        idleFor[k], unattemptedFor[k], armedAt[k] = nil, nil, nil
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
    for k in pairs(unattemptedFor) do
        if not live[k] then unattemptedFor[k] = nil end
    end
    for k in pairs(armedAt) do
        if not live[k] then armedAt[k] = nil end
    end

    return released
end

--------------------------------------------------------------------------
-- Slot claiming (§3.5)
--------------------------------------------------------------------------

--- Move a contract's deadline by a rule applied to its current value.
---
--- Through the guarded write, against a fresh read, and read again if it
--- moved: the deadline is also moved by the expiry pass ending a pause, and
--- a caller writing back a copy it read before its own awaits undid that —
--- or had its own change undone by the pass writing back its copy.
---@param contractId string
---@param rule fun(contract: table): integer the new deadline
---@return integer|nil deadline nil when it would not hold still
---@param attempts integer|nil how many times to try against a moving deadline
---@return integer|nil was the deadline it replaced
function Contracts.moveDeadline(contractId, rule, attempts)
    for _ = 1, attempts or 3 do
        local current = Storage.readContract(contractId)
        if not current then return nil end
        -- By value: on the memory store `current` is the row the write moves.
        local was = current.deadline_at
        local target = rule(current)
        if target == was then return target, was end
        if Storage.setDeadline(contractId, was, target) then return target, was end
    end
    return nil
end

--- The least a deadline may be left with when it is brought in: one step of
--- the clock's rounding (Util.roundClock).
local MIN_LEFT_AFTER_CUT = Util.CLOCK_STEP
Contracts.MIN_LEFT_AFTER_CUT = MIN_LEFT_AFTER_CUT

--- Move a deadline that may come forward, but never under somebody holding
--- the contract who did not agree to it.
---
--- Checking for holders first and writing after is not enough: every store
--- call is a yield on mysql, and an acceptance that wrote its row and read
--- the deadline in between confirmed against the old one, then had it cut
--- short under a stake it had just put up. So the other way round, which is
--- what an acceptance does too (Contracts.accept writes its row, then reads
--- the deadline): write, then look. Whichever of the two lands second sees
--- the other, and a deadline brought in over somebody is put back.
---@param contractId string
---@param rule fun(contract: table): integer the new deadline
---@param agreed table|nil cids that agreed to it, by cid
---@return integer|nil deadline
---@return string|nil err
function Contracts.bringDeadlineIn(contractId, rule, agreed)
    -- Never to within MIN_LEFT_AFTER_CUT of running out. The cut is in the
    -- store, where the expiry pass can see it, until the look below is done;
    -- one that left a second on the clock could expire the contract, and
    -- forfeit a stake, before it was put back.
    local tooSoon = false
    local moved, was = Contracts.moveDeadline(contractId, function(current)
        local target = rule(current)
        local from = current.paused_since or os.time()
        tooSoon = current.deadline_at ~= nil and target < current.deadline_at
            and target - from < MIN_LEFT_AFTER_CUT
        if tooSoon then return current.deadline_at end
        return target
    end)
    if tooSoon then return nil, CH.ERR.INVALID_INPUT end
    if not moved then return nil, CH.ERR.LOCKED end
    if not was or moved >= was then return moved end

    local hitmen = Storage.readHitmen(contractId)
    for i = 1, #hitmen do
        if holds(hitmen[i]) and not (agreed and agreed[hitmen[i].hitman_cid]) then
            -- By what it was cut, not to what it was: a pause ending in
            -- between moved it too, and that is not this call's to undo.
            -- And until it lands: every other writer of the deadline only
            -- ever moves it through the same guarded write, so a few more
            -- tries is all a busy contract needs.
            local cut = was - moved
            Contracts.moveDeadline(contractId, function(current)
                return (current.deadline_at or moved) + cut
            end, 10)
            return nil, CH.ERR.BAD_STATE
        end
    end
    return moved
end

--- Whether a contract's time is up: past its lifetime, or past a deadline
--- whose clock was running. A paused clock stopped at `paused_since`, so a
--- deadline that fell before the pause began is up however long the pause
--- has lasted — the pass that ends the pause will find it so.
---@param contract table
---@param now integer
---@return boolean
function Contracts.isOverdue(contract, now)
    if contract.expires_at and now > contract.expires_at then return true end
    local deadline = contract.deadline_at
    if not deadline then return false end
    return (contract.paused_since or now) > deadline
end

--- Whether this hitman collected on this contract too recently to collect
--- again. Asked by the claim and, ahead of it, by anything that makes a
--- player spend time on a claim that is certain to be refused — a handover
--- countdown holds a restrained player for thirty seconds.
---@param hitman table a hitman row
---@return boolean
function Contracts.slotCoolingDown(hitman)
    return hitman ~= nil and hitman.last_claim_at ~= nil
        and (os.time() - hitman.last_claim_at) < (Config.Limits.SlotCooldownSeconds or 0)
end

--- Claim the next unclaimed payout slot for a hitman.
---
--- This is the single point where a fulfilment turns into money. It takes the
--- contract's lock, so two hitmen completing at the same moment cannot both
--- claim the same slot (§9.7), and it releases only that slot's lines.
---
---@param contractId string
---@param hitmanCid string
---@param fulfilment string CH.FULFILMENT.*
---@return boolean ok
---@return string|nil err
---@return table|nil result
---@param opts table|nil { deathAt = ms } when the claim rests on a recorded death
function Contracts.claimSlot(contractId, hitmanCid, fulfilment, opts)
    local contract = Storage.readContract(contractId)
    if not contract then return false, CH.ERR.NOT_FOUND end
    if contract.state ~= CH.STATE.ACCEPTED then return false, CH.ERR.BAD_STATE end

    local hitman = Storage.readHitman(contractId, hitmanCid)
    if not hitman or hitman.state ~= 'active' then return false, CH.ERR.NOT_PARTICIPANT end

    -- The same hitman may not collect two slots back to back; without this a
    -- multi-slot contract is a respawn-camping machine (§3.5).
    if Contracts.slotCoolingDown(hitman) then
        return false, CH.ERR.SLOT_COOLDOWN
    end

    local slot = contract.next_slot or 1
    if slot > (contract.payout_slots or 1) then return false, CH.ERR.ALREADY_SETTLED end

    -- Eligibility is re-checked here, not just at creation: a multi-slot
    -- contract is claimed repeatedly over time, and the target's post-respawn
    -- protection has to hold for every claim (§14.39).
    local targetActor = Identity.byCitizenId(contract.target_cid)
    if targetActor and Contracts.isImmune(targetActor, opts) then
        return false, CH.ERR.TARGET_PROTECTED
    end

    -- Take the contract's lock for the duration of the settlement, so the
    -- slot cannot be claimed twice (§14.3).
    if not Contracts.transition(contractId, CH.STATE.ACCEPTED, CH.STATE.COMPLETING, 'claiming_slot') then
        return false, CH.ERR.LOCKED
    end

    -- Everything above was read before the lock was ours, and every read is
    -- an await: another claim can take the lock, pay its slot, advance
    -- next_slot and give the lock back in between. Acting on the slot read
    -- at the top paid this hitman out of a slot already settled — nothing
    -- moved, the claim reported success, and the kill, the photo token and
    -- the next ten minutes were spent on it. Read again under the lock,
    -- where nothing else can move them.
    local held = Storage.readContract(contractId)
    local fresh = Storage.readHitman(contractId, hitmanCid)
    local refusal
    if not fresh or fresh.state ~= 'active' then
        refusal = CH.ERR.NOT_PARTICIPANT
    elseif Contracts.slotCoolingDown(fresh) then
        refusal = CH.ERR.SLOT_COOLDOWN
    elseif not held or (held.next_slot or 1) > (held.payout_slots or 1) then
        refusal = CH.ERR.ALREADY_SETTLED
    end
    if refusal then
        Contracts.transition(contractId, CH.STATE.COMPLETING, CH.STATE.ACCEPTED, 'claim_refused')
        return false, refusal
    end
    contract, hitman, slot = held, fresh, held.next_slot or 1

    -- Whose each of this collection's lines is, written before any of them
    -- moves. The baseline and the bonus are released one after the other,
    -- and a process that died between the two left the bonus held and owed
    -- to nobody: recovery found the collection paid by its baseline, and
    -- swept the bonus to the client — a live delivery's premium, earned and
    -- never paid. Marked first, every line of the collection is owed to
    -- whoever this claim decided it for, and recovery queues it for them.
    local kidnap = fulfilment == CH.FULFILMENT.KIDNAPPING
    local marks = {}
    for _, line in ipairs(Storage.readEscrow(contractId) or {}) do
        if line.slot == slot and line.state == CH.ESCROW_STATE.HELD
            and not line.owed_to and not line.releasing_to then
            if line.portion == CH.PORTION.BASELINE then
                line.owed_to = hitmanCid
                marks[#marks + 1] = line
            elseif line.portion == CH.PORTION.BONUS then
                line.owed_to = kidnap and hitmanCid or contract.creator_cid
                marks[#marks + 1] = line
            end
        end
    end
    -- The marks guard a crash between the two releases below, and nothing
    -- else: a write that fails leaves the releases to go ahead as they did
    -- before marks existed. One that raised left the contract held by a
    -- claim until the next restart.
    if #marks > 0 then
        local wrote, ok = pcall(Storage.writeEscrow, contractId, marks)
        if not wrote or not ok then
            Audit.rejected('claim_marks_not_written', hitmanCid, contractId,
                { error = not wrote and tostring(ok) or nil })
        end
    end

    -- A kidnapping releases the slot's baseline and its bonus; an elimination
    -- releases the baseline only, and the bonus returns to the creator.
    local _, baseline = Escrow.release(contractId, hitmanCid, { slot = slot, portion = CH.PORTION.BASELINE }, 'payout_baseline')
    local bonus = { settled = 0, pending = 0 }
    if kidnap then
        _, bonus = Escrow.release(contractId, hitmanCid, { slot = slot, portion = CH.PORTION.BONUS }, 'payout_bonus')
    else
        Escrow.release(contractId, contract.creator_cid, { slot = slot, portion = CH.PORTION.BONUS }, 'bonus_unearned')
    end

    -- Only the two fields that changed, guarded on the slot still being the
    -- one this claim acted on. Writing back the whole contract read at the
    -- top of this function erased anything stored in between — a bailout
    -- queuing during the yielding reads above is the target's money.
    if not Storage.advanceSlot(contractId, slot) then
        -- The slot moved under this claim. The escrow for it is already
        -- released above, so this cannot be unwound — but it must not be
        -- compounded by writing a slot count nothing agrees with.
        Audit.financial('slot_advance_lost', hitmanCid, contractId, { slot = slot })
    end

    -- Re-read rather than mutating the copy: on a backend that hands out
    -- references, that copy IS the stored row, and incrementing it here
    -- counted the claim twice.
    contract = Storage.readContract(contractId) or contract
    Storage.updateHitman(hitman.id, { last_claim_at = os.time(), claims = (hitman.claims or 0) + 1 })

    -- The stake is NOT returned here. On a multi-slot contract the hitman
    -- is still on the hook for the slots that remain, and handing it back
    -- after the first claim would let them collect a payout, recover the
    -- penalty and walk away at no cost. Stakes settle when the contract
    -- ends, in finalise() and resolve().

    if Progression then Progression.onCompleted(hitmanCid, fulfilment) end

    Audit.financial('slot_claimed', hitmanCid, contractId, {
        slot = slot, fulfilment = fulfilment,
        settled = baseline.settled + bonus.settled,
        pending = baseline.pending + bonus.pending,
    })

    local exhausted = contract.next_slot > (contract.payout_slots or 1)
    if exhausted then
        -- Last slot: the contract is finished for everyone. Every other
        -- hitman's stake comes back and any unclaimed escrow returns to the
        -- creator, while the contract is still non-terminal and reachable.
        finalise(contractId, contract, false, CH.STATE.COMPLETED, hitmanCid)

        contract.resolved_at = os.time()
        contract.resolution = 'completed'
        Storage.setContractFields(contractId,
            { resolved_at = contract.resolved_at, resolution = contract.resolution })
        Contracts.transition(contractId, CH.STATE.COMPLETING, CH.STATE.COMPLETED, 'completed', SETTLING)
    else
        -- Slots remain: the contract goes back to accepted and stays live.
        Contracts.transition(contractId, CH.STATE.COMPLETING, CH.STATE.ACCEPTED, 'slot_claimed')

        -- And every party's card has just changed: which collection is on
        -- offer, how many are left, and what it pays. finalise() pushes on
        -- the last slot and nothing pushed on the ones before it, so a
        -- creator watching a three-payout contract went on being shown the
        -- first collection's money after it had been paid, and a second
        -- hitman went on competing for a slot that was gone.
        local cids = {}
        for _, row in ipairs(Storage.readHitmen(contractId) or {}) do
            if row.state == 'active' then cids[#cids + 1] = row.hitman_cid end
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
--- Whether anybody is currently working this contract.
---
--- The state alone does not say: a contract stays ACCEPTED after its only
--- hitman walks away, and a competitive one is ACCEPTED with any number of
--- them. What matters for taking a contract back down is whether somebody
--- is holding it right now.
---@param contractId string
---@return boolean
local function heldByAnyone(contractId)
    local hitmen = Storage.readHitmen(contractId)
    for i = 1, #hitmen do
        if holds(hitmen[i]) then return true end
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
--- Refused the moment somebody is actually working it. That is what escrow
--- is for: a hitman who has started work, and staked a penalty to do it,
--- cannot have the reward pulled out from under them.
---@param actor table
---@param contractId string
---@return boolean ok
---@return string|nil err
function Contracts.cancel(actor, contractId)
    contractId = Util.toId(contractId)
    if not contractId then return false, CH.ERR.INVALID_INPUT end

    local contract = Storage.readContract(contractId)
    if not contract then return false, CH.ERR.NOT_FOUND end
    if contract.creator_cid ~= actor.cid then return false, CH.ERR.NOT_PARTICIPANT end
    if CH.TERMINAL[contract.state] then return false, CH.ERR.ALREADY_SETTLED end
    if heldByAnyone(contractId) then return false, CH.ERR.CONTRACT_TAKEN end

    local ok, err = Contracts.resolve(contractId, CH.STATE.CANCELLED,
        actor.cid, nil, 'cancelled_by_creator')
    if not ok then return false, err end

    Audit.financial('contract_cancelled', actor.cid, contractId, {})

    -- What could not actually be handed back. A refund the creator's pockets
    -- had no room for is owed and retried on next login, not lost — but
    -- "everything you put up has been returned" is untrue in exactly that
    -- case, and it is the case where a player counts their money, finds it
    -- short, and reports it stolen.
    local owed = owedTo(contractId, actor.cid)

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
--- Only while it is unclaimed: once a hitman has accepted, they accepted it
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
    if not contractId then return false, CH.ERR.INVALID_INPUT end
    changes = type(changes) == 'table' and changes or {}

    local contract = Storage.readContract(contractId)
    if not contract then return false, CH.ERR.NOT_FOUND end
    if contract.creator_cid ~= actor.cid then return false, CH.ERR.NOT_PARTICIPANT end
    if CH.TERMINAL[contract.state] then return false, CH.ERR.ALREADY_SETTLED end
    if heldByAnyone(contractId) then return false, CH.ERR.CONTRACT_TAKEN end

    -- Held as values, never written onto `contract`: on the memory store it
    -- is the stored row, and a change made to it here would stand even
    -- when the deadline below is refused.
    local touched = {}
    local deadline, newReason

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
            newReason = reason
            touched[#touched + 1] = 'reason'
        end
    end

    if changes.deadlineSeconds ~= nil then
        local seconds = Util.toPositive(changes.deadlineSeconds,
            Config.Limits.ContractLifetimeSeconds)
        if not seconds then return false, CH.ERR.INVALID_INPUT end

        -- Never past the absolute lifetime, which is what stops a contract
        -- holding escrow forever. Never sooner than the least a deadline may
        -- be brought in to (Contracts.bringDeadlineIn). Rounded, like one
        -- set at creation: set from now, it dated the edit.
        deadline = Util.roundClock(os.time() + math.max(seconds, MIN_LEFT_AFTER_CUT))
        if contract.expires_at and deadline > contract.expires_at then
            deadline = contract.expires_at
        end
        touched[#touched + 1] = 'deadline'
    end

    if #touched == 0 then return false, CH.ERR.INVALID_INPUT end

    -- The clock moves only through its own writes, and first: a new
    -- deadline, set from now, that is put back if somebody took the
    -- contract while this call was deciding (Contracts.bringDeadlineIn).
    -- Refused then, reason and all, rather than half made.
    if deadline then
        local moved, moveErr = Contracts.bringDeadlineIn(contractId,
            function() return deadline end)
        if not moved then return false, moveErr end
    end
    -- The reason alone, never the row: `contract` was read before every
    -- await above, and writing it back put back whatever changed in them —
    -- the buyout and stake a reward withdrawal had just re-clamped, among
    -- others.
    if newReason ~= nil and newReason ~= contract.reason
        and not Storage.setReason(contractId, newReason) then
        return false, CH.ERR.BAD_STATE
    end

    Audit.action('contract_revised', actor.cid, contractId,
        { changed = table.concat(touched, ',') })
    return true
end

--- Take part of a reward back out of escrow.
---
--- The other half of changing a reward. Adding to one already existed
--- (Amendments.addEscrow, which works even while a hitman holds the
--- contract, because a bigger reward cannot disadvantage them). Taking
--- value back out did not exist at all: a creator who put up too much
--- could only cancel the whole contract and place it again, losing their
--- place in every cooldown that keys on target and creator.
---
--- Refused the moment somebody is actually working it, for the same reason
--- cancelling is: a hitman who has started work, and staked a penalty to do
--- it, decided on the reward as written. Reducing it from under them is
--- exactly what escrow exists to prevent, and there is no approval path
--- that makes it fair, so this does not offer one.
---
--- What comes back is what went in. Each named line is released through the
--- ordinary guarded path, so a stack of items returns with its own
--- metadata and a weapon with its own serial — never a fresh clean copy.
---
--- Three things cannot be withdrawn, whatever the client names:
---   * a hitman's stake, which is not the creator's property;
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
local function withdrawRewardUnlocked(actor, contractId, lineIds)
    local contract = Storage.readContract(contractId)
    if not contract then return false, CH.ERR.NOT_FOUND end
    if contract.creator_cid ~= actor.cid then return false, CH.ERR.NOT_PARTICIPANT end
    if CH.TERMINAL[contract.state] then return false, CH.ERR.ALREADY_SETTLED end
    if heldByAnyone(contractId) then return false, CH.ERR.CONTRACT_TAKEN end

    -- Bounded before anything is read: a client naming ten thousand ids
    -- must not become ten thousand lookups.
    if #lineIds < 1 or #lineIds > Config.Limits.MaxEscrowLines then
        return false, CH.ERR.INVALID_INPUT
    end

    local wanted = {}
    local count = 0
    for i = 1, #lineIds do
        -- toLineId, not toId: an escrow line id carries the contract id and
        -- an index joined by a colon, which toId deliberately refuses.
        local id = Util.toLineId(lineIds[i])
        if not id then return false, CH.ERR.INVALID_INPUT end
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
            if line.portion ~= CH.PORTION.BASELINE and line.portion ~= CH.PORTION.BONUS then
                return false, CH.ERR.NOT_PARTICIPANT
            end
            if line.owed_to then return false, CH.ERR.NOT_PARTICIPANT end
            if line.state ~= CH.ESCROW_STATE.HELD then return false, CH.ERR.BAD_STATE end
        end
    end

    -- An id this contract does not hold is not ignored. Silently withdrawing
    -- the subset it recognised would tell the creator their whole request
    -- succeeded while part of the reward stayed where it was.
    if matched ~= count then return false, CH.ERR.NOT_FOUND end

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
        -- a live contract offering a hitman nothing. The route in is ordinary:
        -- withdraw part of a reward with full pockets, and the line that
        -- cannot be carried is queued and marked owed.
        if line.state == CH.ESCROW_STATE.HELD and not line.owed_to
            and line.portion == CH.PORTION.BASELINE then
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
        if not Util.escrowIsEmpty(slotLines, CH.PORTION.BASELINE)
            and Util.escrowIsEmpty(after[slot] or {}, CH.PORTION.BASELINE) then
            return false, CH.ERR.INVALID_REWARD
        end
    end

    -- One release for the whole set: several would be several windows for
    -- an acceptance to land in the middle of, and several audit rows for
    -- one decision.
    --
    -- The hitman check above is not enough on its own. Every storage read
    -- between it and the money moving is a yield, and an acceptance can land
    -- in any of them — so the same question is asked again through the
    -- guard, once each line is out of `held` and can no longer be paid to
    -- anybody. At that point the answer is binding: a hitman who appeared
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

        -- Nothing at all got out: the ordinary case, and the hitman has the
        -- contract exactly as they accepted it.
        --
        -- A QUEUED line got out too. It is marked owed to the creator, and
        -- from that moment every reader of what this contract pays skips it —
        -- so counting only settled lines here answered "that did not work"
        -- to a creator whose reward had already shrunk, returned before the
        -- hitman below was told, and skipped the audit row and the re-pricing
        -- further down. Measured: a contract worth 9,500 left at 8,500, the
        -- creator told the withdrawal failed, the hitman told nothing.
        if result.settled == 0 and result.pending == 0 then
            return false, CH.ERR.CONTRACT_TAKEN
        end

        -- Something did. The guard runs per line, so an acceptance landing
        -- between two of them leaves the earlier ones already returned — a
        -- hitman holding a contract worth slightly less than the one they
        -- took. It cannot be unwound, because that money is in the
        -- creator's pocket and is rightfully theirs, so it is told rather
        -- than hidden: a hitman who finds out from a payout is a hitman who
        -- reports it as theft.
        local hitmen = Storage.readHitmen(contractId)
        for i = 1, #hitmen do
            if hitmen[i].state == 'active' then
                Notify.toCitizen(hitmen[i].hitman_cid, 'Reward changed',
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
        return false, CH.ERR.LOCKED
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

--- One withdrawal at a time per contract. Each checks that every collection
--- stays funded against lines it read before its awaits, so two at once,
--- each taking a different line off the same collection, both passed and
--- left a live contract paying nothing. The key is the one acceptance holds,
--- so an acceptance cannot land in the middle of one either.
function Contracts.withdrawReward(actor, contractId, lineIds)
    contractId = Util.toId(contractId)
    if not contractId then return false, CH.ERR.INVALID_INPUT end
    if type(lineIds) ~= 'table' then return false, CH.ERR.INVALID_INPUT end
    return Contracts.serialized({ 'contract:' .. contractId },
        withdrawRewardUnlocked, actor, contractId, lineIds)
end

--- Re-price both figures that are meant to be proportional to the escrow,
--- after some of that escrow has been taken back out.
---
--- Both clamps hold at the moment the figure is set and nowhere else, so
--- every path that removes escrow afterwards has to re-apply them or it is
--- a way round them. Fund 41,000, price the buyout at the 123,000 that
--- funding buys and the stake at 82,000, take the 40,000 back, and a
--- contract worth 1,000 charges a target 123,000 to escape and asks each
--- hitman for 82,000 to try — the uncapped transfer rails both clamps
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
        --
        -- The creator's escrow only, as creation measures it. A hitman's
        -- stake is held on the contract too, and counting it priced the
        -- buyout against the hitmen' own money: giving back a collection
        -- raised what the target paid to escape, and left the stake quoted
        -- to the next hitman at four times what the contract still paid.
        if line.state == CH.ESCROW_STATE.HELD and not line.owed_to
            and line.portion ~= CH.PORTION.STAKE and line.portion ~= CH.PORTION.OWED then
            held[#held + 1] = line
            if CH.MONEY_ACCOUNTS[line.source] then
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

    if changed then
        Storage.setContractFields(contractId, { bailout_amount = contract.bailout_amount,
            penalty_amount = contract.penalty_amount })
    end
end

---@param opts table|nil { forfeit = boolean } to say whether an expiry is
--- the hitmen' failure; by default every expiry is
function Contracts.resolve(contractId, terminal, recipientCid, filter, reason, opts)
    local contract = Storage.readContract(contractId)
    if not contract then return false, CH.ERR.NOT_FOUND end
    if CH.TERMINAL[contract.state] then return false, CH.ERR.ALREADY_SETTLED end

    local moved
    if opts and opts.dueAt and terminal == CH.STATE.EXPIRED then
        -- Expired only if still due when the state is written, not when the
        -- pass read it: an extension landing in between is kept.
        local allowed = CH.TRANSITIONS[contract.state]
        moved = allowed and allowed[terminal]
            and Storage.expireIfDue(contractId, contract.state, terminal, opts.dueAt,
                opts.byLifetime == true)
        if moved then
            Audit.action('state_change', nil, contractId,
                { from = contract.state, to = terminal, reason = reason })
        end
    else
        moved = Contracts.transition(contractId, contract.state, terminal, reason, SETTLING)
    end
    if not moved then
        return false, CH.ERR.LOCKED
    end

    contract.resolved_at = os.time()
    contract.resolution = reason
    Storage.setContractFields(contractId,
        { resolved_at = contract.resolved_at, resolution = contract.resolution })

    -- A target who outlived the contract has something to show for it.
    if Progression and (terminal == CH.STATE.BAILED_OUT or terminal == CH.STATE.EXPIRED) then
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
    -- An expiry is the hitman failing, so the creator keeps their stake.
    local forfeit = terminal == CH.STATE.EXPIRED
    if forfeit and opts and opts.forfeit == false then forfeit = false end
    finalise(contractId, contract, forfeit, terminal)

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
--- have: stakes to whoever put them up (to the creator, for a hitman still on
--- a contract that expired), the rest back to the creator.
---@param contract table
---@param forfeit boolean
---@return integer released
local function releaseUntouched(contract, forfeit)
    local released = 0
    for _, line in ipairs(Storage.readEscrow(contract.id) or {}) do
        if line.state == CH.ESCROW_STATE.HELD and not line.owed_to
            and not line.releasing_to and line.portion ~= CH.PORTION.OWED then
            local recipient = contract.creator_cid
            if line.portion == CH.PORTION.STAKE then
                local hitman = line.staker and Storage.readHitman(contract.id, line.staker)
                local keeps = forfeit and stakeForfeits(hitman, contract)
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

--- Undo acceptances a crash left part-way: rows still joining.
---
--- The hitman was never told they had the contract, so it is not theirs.
--- The stake goes back first, then the row: a first acceptance's is refused,
--- and a hitman who had walked away and was taking it up again is put back
--- to having walked away, keeping the stint they had. Refusing that row too
--- erased the stint — what anonymity it had bought, and that the client had
--- already been shown their name under the same alias. A contract nobody is
--- then left on goes back on the board, including an exclusive one this
--- acceptance had reserved.
---
--- Run at boot, and by the tick for a contract a throw left like this.
---@param contract table
---@return integer undone
function Contracts.recoverJoining(contract)
    local undone, left = 0, 0
    for _, h in ipairs(Storage.readHitmen(contract.id) or {}) do
        if h.state == 'joining' or h.state == 'rejoining' then
            Escrow.release(contract.id, h.hitman_cid,
                { portion = CH.PORTION.STAKE, staker = h.hitman_cid }, 'accept_interrupted')
            if h.state == 'rejoining' then
                Storage.updateHitman(h.id, { state = 'abandoned' })
            else
                Storage.updateHitman(h.id, { state = 'refused', left_at = os.time() })
            end
            undone = undone + 1
        elseif h.state == 'active' then
            left = left + 1
        end
    end
    if undone > 0 and left == 0 and contract.state == CH.STATE.ACCEPTED then
        Contracts.transition(contract.id, CH.STATE.ACCEPTED, CH.STATE.ACTIVE, 'accept_interrupted')
    end
    return undone
end

--- Finish a contract whose ending a crash interrupted.
---
--- Two shapes, both left behind by a process that died part-way through:
---
---   * COMPLETING with every collection already paid. The last claim had
---     advanced the slot past the end and died before closing. Putting it
---     back to ACCEPTED, as recovery did, brought back a live contract with
---     nothing left to claim, which then ran out: the hitman who had
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

    if contract.state == CH.STATE.COMPLETING
        and (contract.next_slot or 1) > (contract.payout_slots or 1) then
        releaseUntouched(contract, false)
        contract.resolved_at = contract.resolved_at or os.time()
        contract.resolution = contract.resolution or 'completed'
        Storage.setContractFields(contractId,
            { resolved_at = contract.resolved_at, resolution = contract.resolution })
        Contracts.transition(contractId, CH.STATE.COMPLETING, CH.STATE.COMPLETED,
            'completed_on_recovery', SETTLING)
        if Contracts.onResolved then Contracts.onResolved(contractId) end
        return 'completed'
    end

    if CH.TERMINAL[contract.state] then
        -- Whether an expiry forfeits is the deadline's question, asked the
        -- way the tick asked it (§3.6, §14.18). Every EXPIRED contract used
        -- to forfeit here, so a crash while ending one that had only reached
        -- its lifetime — a target out of the city, the deadline paused —
        -- handed the hitman's stake to the creator, which the same ending
        -- without the crash never does.
        local forfeit = false
        if contract.state == CH.STATE.EXPIRED then
            local at = contract.resolved_at or contract.expires_at or os.time()
            forfeit = not contract.paused_since and contract.deadline_at ~= nil
                and at > contract.deadline_at
        end
        local released = releaseUntouched(contract, forfeit)
        return released > 0 and 'released' or nil
    end

    return nil
end

return Contracts
