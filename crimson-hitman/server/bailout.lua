--- Contract Cleanse — the target buys out their own contract (§5, §14.17).
---
--- The premium is charged before anything else happens, and the contract
--- resolves through the normal path so the creator's escrow returns exactly
--- once. A bailout while a hitman is mid-delivery does not rug-pull them: it
--- is queued for a short processing delay first.

local Util = CrimsonBoot.requireShared('util')
local Log = CrimsonBoot.requireShared('log')

local Bailout = {}

local Storage, Identity, Contracts, Escrow, Audit, Notify, Review

function Bailout.init(deps)
    Storage, Identity, Contracts, Escrow, Audit, Notify =
        deps.storage, deps.identity, deps.contracts, deps.escrow, deps.audit, deps.notify
    -- Where a premium no rule here can settle is left for staff
    -- (server/review.lua), and the buyout whose record the store would not
    -- confirm is settled by the server itself once it answers (S12).
    Review = deps.review
    Bailout.kidnap = deps.kidnap
    Bailout.death = deps.death
    if Review and Review.DECIDERS then
        Review.DECIDERS.bailout_unrecorded = function(item) return Bailout.decideUnrecorded(item) end
    end
end

--- Leave a buyout's money for staff, where the review queue is wired.
local function leaveForStaff(spec)
    if Review then Review.open(spec) end
end

--- Queued buyouts live on the contract row, not in a process-local table.
--- The target has already been charged by the time one is queued, so a
--- restart during the delay window must not lose their money.
---
--- Terminal contracts are deliberately included: a hitman completing during
--- the delay is precisely the case where the premium has to be refunded, and
--- filtering those out would destroy the target's money.
--- Asked of the store rather than found by reading every contract there
--- has ever been. This runs on every tick, and nothing prunes terminal
--- contracts, so the old scan grew with the server's whole history rather
--- than with the number of buyouts actually in flight — which is almost
--- always none.
local function readQueue()
    if Storage.queuedBailouts then return Storage.queuedBailouts() end

    -- A backend that predates the index still answers correctly.
    local out = {}
    local contracts = Storage.allContracts()
    for i = 1, #contracts do
        if contracts[i].bailout_queued_at then out[#out + 1] = contracts[i] end
    end
    return out
end

--- True when any hitman has an armed countdown running on this contract.
function Bailout.kidnapInProgress(contractId)
    if not Bailout.kidnap then return false end
    local hitmen = Storage.readHitmen(contractId)
    for i = 1, #hitmen do
        if hitmen[i].state == 'active'
            and Bailout.kidnap.progress(contractId, hitmen[i].hitman_cid) then
            return true
        end
    end
    return false
end

--- True when a hitman on this contract is in the middle of finishing it: a
--- kill of theirs waiting for its photo, or a handover counting down. Asked
--- when a queued buyout's delay runs out, and when the deadline does.
---
--- Only for work begun by `cutoff` (os.time()), the moment the deadline or
--- the delay ran out. The pass that closes the contract runs on the
--- maintenance tick, seconds after that moment, and a kill made in the gap
--- was held open for its photo and paid: the stake a hitman who ran out of
--- time forfeits went back to them, and a target who had bought out in time
--- was refunded while the hitman was paid.
---@param contractId string
---@param cutoff integer|nil os.time() the work must have begun by
function Bailout.finishing(contractId, cutoff)
    local function inTime(at)
        return cutoff == nil or (at ~= nil and at <= cutoff)
    end
    local hitmen = Storage.readHitmen(contractId)
    for i = 1, #hitmen do
        local cid = hitmen[i].hitman_cid
        if hitmen[i].state == 'active' then
            local kill = Bailout.death and Bailout.death.getPending(contractId, cid)
            if kill and inTime(kill.wallAt) then return true end
            if Bailout.kidnap and Bailout.kidnap.progress(contractId, cid)
                and inTime(Bailout.kidnap.armedAt and Bailout.kidnap.armedAt(contractId, cid)) then
                return true
            end
        end
    end
    return false
end

--- Every live contract on the caller that they may be shown, with its
--- buyout price, 0 where none was set: what /cleanse lists. Only from
--- these does it say "Nothing is out on you.", so a contract with no price
--- is never an all-clear (On me and the whitelisted-job view list it too).
---@return table[] { id, amount, queued }
function Bailout.onTarget(actor)
    local out = {}
    -- The indexed lookup, which is the question this is asking: contracts
    -- naming this player as target. It used to read and hydrate every
    -- contract on the server and filter in Lua — on the mysql backend a
    -- 'SELECT * FROM crimson_contracts' against a 'WHERE target_cid = ?' on
    -- an indexed column. Projection.onMe has always asked it that way; this
    -- call site, which is what /cleanse runs for a player who cannot open
    -- the app at all, was missed.
    local contracts = Storage.contractsNaming(actor.cid)
    for i = 1, #contracts do
        local c = contracts[i]
        -- Not inside the alert's wait (Notify.shownToTarget), as On me does
        -- not: listed at once, a target polling this dated the placement.
        if (c.state == CH.STATE.ACTIVE or c.state == CH.STATE.ACCEPTED)
            and Notify.shownToTarget(c) then
            out[#out + 1] = {
                id = c.id, amount = tonumber(c.bailout_amount) or 0,
                queued = c.bailout_queued_at ~= nil,
            }
        end
    end
    return out
end

--- Contracts the caller may buy out: those of Bailout.onTarget with a
--- price. The purchase filter /cleanse applies before Bailout.buy, which
--- checks it all again; `shown` is onTarget's answer when the caller has
--- it already, so the store is read once.
---@param shown table[]|nil
function Bailout.available(actor, shown)
    local out = {}
    shown = shown or Bailout.onTarget(actor)
    for i = 1, #shown do
        if shown[i].amount > 0 then out[#out + 1] = shown[i] end
    end
    return out
end

--- Pay the premium and close the contract.
---@return boolean ok
---@return string|nil err
---@return boolean|nil queued paid, but waiting out the delay with a hitman on it
local settleUnlocked, deliver

--- Hand back a premium nothing of this buyout recorded, rather than let it
--- vanish. Stranded, the row says how much of it arrived when the credit
--- raised, so staff hand over only the rest.
local function handBack(cid, contractId, amount, account, why)
    local delivered, raise = deliver(cid, contractId, amount, account, 'bailout_refund')
    if not delivered then
        -- Left for staff already, by Bailout.owe: deliver fails only where
        -- the premium could be neither handed over nor put on the books,
        -- and one item for the money is all staff should be asked to pay.
        Audit.financial('bailout_refund_stranded', cid, contractId,
            { amount = amount, account = account, reason = why,
              error = raise and raise.error, arrived = raise and raise.arrived })
    end
end

--- Write a paid buyout onto the contract. The target has been charged by
--- now, and this record is the only thing that will settle or refund it.
---
--- A compare-and-set (Storage.recordBailout): only on a contract still
--- running whose queue is free. Refused, nothing was recorded and nothing
--- can land later, so the premium goes back at once and false says so.
---
--- A write that raised (a dropped connection on mysql) left the premium in
--- no pocket, no line and no queue. It may or may not have landed, as for
--- a placed contract (Contracts.create), so the store decides: there, it is
--- recorded; not there, the premium goes back and the error goes on. A read
--- that raises too decides nothing: the item made before the write (S12,
--- Review.prepare, kept on this machine on mysql) is opened, and the server
--- writes the record again once the store answers and settles it from what
--- that write says (Bailout.decideUnrecorded).
---@return boolean recorded
local function recordPaid(contractId, fields)
    local payer = fields.bailout_paid_by
    local pending = Review and Review.prepare and Review.prepare({
        kind = 'bailout_unrecorded', contract_id = contractId, cids = { payer = payer },
        amount = fields.bailout_paid_amount, account = fields.bailout_paid_account,
        known = { decide = true, fields = {
            bailout_queued_at = fields.bailout_queued_at, bailout_paid_by = payer,
            bailout_paid_amount = fields.bailout_paid_amount,
            bailout_paid_account = fields.bailout_paid_account,
        } },
    }) or nil
    local wrote, recorded = pcall(Storage.recordBailout, contractId, fields)
    if wrote then
        if pending then Review.discard(pending) end
        if recorded then return true end
        -- Another buyout is queued, or the contract closed, since it was
        -- read: the premium back where it came from.
        handBack(payer, contractId, fields.bailout_paid_amount, fields.bailout_paid_account,
            'record_refused')
        Audit.financial('bailout_refunded', payer, contractId,
            { amount = fields.bailout_paid_amount, reason = 'record_refused' })
        return false
    end
    local err = recorded
    Audit.financial('bailout_record_failed', payer, contractId,
        { amount = fields.bailout_paid_amount, error = tostring(err) })
    -- Unanswered (Storage.timedOut), the record may still land: not read
    -- back and never handed back on what the read finds, but left to the
    -- server as below.
    local read, stored
    if Storage.timedOut and Storage.timedOut(err) then
        read, stored = false, err
    else
        read, stored = pcall(Storage.readContract, contractId)
    end
    if not read then
        -- The double fault: the store would neither take the record nor
        -- say whether it had. Never decided on absence: left for the server
        -- to settle once the store answers, and listed for staff meanwhile.
        if pending then
            pending.known.error, pending.known.read_error = tostring(err), tostring(stored)
            Review.open(pending)
        else
            leaveForStaff({
                kind = 'bailout_unrecorded', contract_id = contractId, cids = { payer = payer },
                amount = fields.bailout_paid_amount, account = fields.bailout_paid_account,
                known = { error = tostring(err), read_error = tostring(stored) },
            })
        end
        error(stored, 0)
    end
    if pending then Review.discard(pending) end
    if stored and stored.bailout_queued_at and stored.bailout_paid_by == payer then return true end
    handBack(payer, contractId, fields.bailout_paid_amount, fields.bailout_paid_account, 'unrecorded')
    error(err, 0)
end

--- What a buy whose record was refused answers, from a fresh read: another
--- buyout queued, or the contract closed. The premium is back already.
---@return string err
local function refusedRecord(contractId)
    local read, now = pcall(Storage.readContract, contractId)
    if read and now and now.bailout_queued_at
        and (now.state == CH.STATE.ACTIVE or now.state == CH.STATE.ACCEPTED) then
        return CH.ERR.BUYOUT_PENDING
    end
    return CH.ERR.ALREADY_SETTLED
end

local buyUnlocked

--- Buy out a contract, one buy at a time per contract, and never beside an
--- acceptance, a cancel or a settle of it.
---
--- A buy reads the contract and its hitmen, charges, then records the
--- queue, and every read is an await on mysql. A second tap landing in one
--- of them passed the "already paid" check and charged the target again;
--- the second record wrote over the first, or landed on a contract already
--- bought out, and one premium reached nobody. And an acceptance finishing
--- in the same awaits was missed by the read of who is engaged, so a
--- hitman who had just staked was bought out from under with no delay.
--- The contract's key is the one acceptance, cancel, withdraw and the
--- agreed changes hold, and the settle key is the queue's (Bailout.settle):
--- held from before anything is read, so a buy that would meet another is
--- refused as busy before it charges anything. The rate limit on the
--- request is not what keeps this right: staff may raise it from the admin
--- panel.
---@return boolean ok
---@return string|nil err
---@return boolean|table|nil queued, or on a refusal what the page is told
function Bailout.buy(actor, contractId)
    contractId = Util.toId(contractId)
    if not contractId then return false, CH.ERR.INVALID_INPUT end
    if not Config.Bailout.Enabled then return false, CH.ERR.BAILOUT_OFF end
    return Contracts.serialized({ 'contract:' .. contractId, 'settle:' .. contractId },
        buyUnlocked, actor, contractId)
end

buyUnlocked = function(actor, contractId)
    local contract = Storage.readContract(contractId)
    if not contract then return false, CH.ERR.NOT_FOUND end
    if contract.target_cid ~= actor.cid then return false, CH.ERR.NOT_PARTICIPANT end
    -- Each of these is a different thing to do about it, so each says which.
    if contract.state ~= CH.STATE.ACTIVE and contract.state ~= CH.STATE.ACCEPTED then
        return false, CH.ERR.ALREADY_SETTLED
    end
    if (contract.bailout_amount or 0) <= 0 then return false, CH.ERR.NO_BUYOUT_PRICE end
    if contract.bailout_queued_at then return false, CH.ERR.BUYOUT_PENDING end
    -- On hold by staff (server/freeze.lua): nothing is charged.
    if Contracts and Contracts.heldByStaff and Contracts.heldByStaff(contract) then return false, CH.ERR.CONTRACT_FROZEN end

    -- A target cannot buy their way out from the floor mid-fight.
    if Config.Bailout.BlockWhileIncapacitated then
        local dead, lastStand = Identity.deathState(actor.source)
        if dead or lastStand then return false, CH.ERR.INCAPACITATED end
    end

    -- Nor out from under a handover already in progress: the hitman has the
    -- target in hand and is seconds from delivering.
    if Bailout.kidnapInProgress(contractId) then return false, CH.ERR.HANDOVER_IN_PROGRESS end

    local amount = contract.bailout_amount

    -- With a hitman already engaged, the buyout is queued rather than
    -- instant, so a hitman cannot be rug-pulled mid-delivery (§14.17).
    -- Read before the charge: a read that raised after it kept the premium
    -- with nothing recorded for it.
    local hitmen = Storage.readHitmen(contractId)
    local engaged = false
    local engagedCids = {}
    for i = 1, #hitmen do
        if hitmen[i].state == 'active' then
            engaged = true
            engagedCids[#engagedCids + 1] = hitmen[i].hitman_cid
        end
    end

    -- Debit first: the premium is taken before any state changes, so a
    -- failure here leaves the contract exactly as it was.
    -- Which account paid is remembered, so a refund goes back where it came
    -- from rather than silently laundering cash into bank money.
    local account = 'bank'
    -- Through Util.charge, which reads the balance first. RemoveMoney's
    -- return is not an affordability check: qbx_core allows bank to go
    -- negative, so this used to succeed on an empty account — a free
    -- buyout, paid to the creator out of an overdraft, and the fall-through
    -- to cash never ran either.
    local paid = Util.charge(actor.player, 'bank', amount)
    if not paid then
        account = 'cash'
        paid = Util.charge(actor.player, 'cash', amount)
    end
    -- With how much, and that it is whole from either account, so the page
    -- names the figure the server asked for (§14.18).
    if not paid then
        return false, CH.ERR.INSUFFICIENT,
            { part = 'buyout', need = amount, account = 'bank_or_cash' }
    end

    Audit.financial('bailout_paid', actor.cid, contractId, { amount = amount })

    if engaged and Config.Bailout.ProcessingDelaySeconds > 0 then
        -- Persisted, not held in memory: the target's money is already gone,
        -- so a restart inside the delay window must still settle.
        -- Through the narrow write, not writeContract. The target's money is
        -- already gone at this point, and a writeContract from any other
        -- handler holding an older copy of this row used to erase the queue
        -- on top of it: premium charged, nothing left to settle or refund it.
        if not recordPaid(contract.id, {
            bailout_queued_at = os.time(),
            bailout_paid_by = actor.cid,
            bailout_paid_amount = amount,
            bailout_paid_account = account,
            bailout_attempts = 0,
        }) then
            return false, refusedRecord(contract.id)
        end

        Notify.toCitizen(contract.creator_cid, 'Contract challenged',
            'Your target is buying out the contract. It closes shortly.')
        -- And the operatives, whom the delay is for.
        Notify.buyoutQueued(contract, engagedCids, Config.Bailout.ProcessingDelaySeconds)
        -- Said to the page, which told the target "Paid. The contract
        -- closes shortly." either way — and they are still a target here.
        return true, nil, true
    end

    -- Recorded before it is settled, as a buyout already due. The target
    -- has paid; until the premium line exists nothing else says so, and
    -- settling is a score of awaits on mysql. A crash in any of them left a
    -- contract bought out with the premium in no line, no queue and no
    -- pocket. Recorded, the next tick finishes it like a queued buyout, and
    -- settle clears the record when it is done. The settle key is this
    -- buy's from before the first read (Bailout.buy), so the tick cannot
    -- settle it too in between, and nothing here can meet it busy after
    -- the charge.
    if not recordPaid(contract.id, {
        bailout_queued_at = os.time() - (Config.Bailout.ProcessingDelaySeconds or 0),
        bailout_paid_by = actor.cid,
        bailout_paid_amount = amount,
        bailout_paid_account = account,
        bailout_attempts = 0,
    }) then
        return false, refusedRecord(contract.id)
    end
    return settleUnlocked(contractId, amount, actor.cid, account)
end

--- Put money into a player's hands, or on the books for them.
---
--- False only when neither is possible: the player is offline (or the
--- framework refused the credit) AND the store's id sequence has nothing
--- left to mint an owed line with.
---
--- Bailout.owe can return nil, and both call sites below used to discard it
--- and carry on. This is the one id-exhaustion path in the resource with a
--- player's money already in flight — Contracts.create refuses before it
--- charges anyone and Contracts.accept releases the stake — so the money
--- simply stopped existing, with an audit row the player cannot see as its
--- only trace. Util.mintId exists for the documented case of two server
--- instances sharing one database, where ids collide as a matter of course.
---
--- A credit that raised is decided by the balance either side of it
--- (Util.credit). Arrived: paid, and nothing is owed. Nothing arrived:
--- owed like a refusal, with the raise counted on the line. Part of it, or
--- no telling: owed on a line left for staff with what is known, so
--- nothing gives it again blind; a second owed line for money that had
--- already arrived paid it twice.
---@return boolean placed in their hands or on the books
---@return table|nil raise { error, arrived, before } when the credit raised
deliver = function(cid, contractId, amount, account, reason)
    local who = Identity.byCitizenId(cid)
    local raise
    if who then
        local credited, raised, arrived, before = Util.credit(who.player, account, amount)
        if credited then return true end
        if raised then raise = { error = raised, arrived = arrived, before = before } end
    end
    return Bailout.owe(cid, contractId, amount, account, reason, raise) ~= nil, raise
end

--- The id of a contract's buyout premium line. One per contract: only one
--- buyout can ever close it.
---@param contractId string
---@return string
function Bailout.premiumLineId(contractId)
    return 'prem:' .. contractId
end

--- The id of a refunded buyout's line: the contract's, and the moment that
--- buyout was recorded. A retry of one refund lands on its own line; a
--- later buyout of the same contract (the first refunded because a claim
--- held it) is recorded at a later moment and gets its own.
---@param contractId string
---@param queuedAt integer|nil the buyout's bailout_queued_at
---@return string
function Bailout.refundLineId(contractId, queuedAt)
    return ('refund:%s-%d'):format(contractId, math.floor(tonumber(queuedAt) or 0))
end

--- Owe one party a buyout's money under an id that comes from the contract,
--- and hand it over. Idempotent: see settle.
---@param metadata table|nil kept on the line: a premium's says which buyout paid it
local function payOwed(contract, id, cid, amount, account, reason, metadata)
    local existing = Storage.readEscrowLine(id)
    if not (existing and existing.id == id) then
        Storage.writeEscrow(contract.id, { {
            id = id,
            contract_id = contract.id,
            slot = 0,
            portion = CH.PORTION.OWED,
            owed_to = cid,
            source = account == 'cash' and 'cash' or 'bank',
            amount = amount,
            state = CH.ESCROW_STATE.HELD,
            metadata = metadata,
        } })
        Storage.queuePending(cid, contract.id, id)
        if Escrow and Escrow.noteWaiting then Escrow.noteWaiting(cid, true) end
    end
    local line = Storage.readEscrowLine(id)
    if line and line.id == id and line.state == CH.ESCROW_STATE.HELD and Escrow then
        Escrow.release(contract.id, cid, { line = id }, reason)
    end
end

--- What the person who placed it is told of a buyout: what came back, from
--- what is still owed to them (Contracts.owedTo), as the cancel notice words
--- it. "Escrow and premium have been returned" went to a client whose
--- pockets had no room for the goods, and to one away, whose money was only
--- queued. Kept for one who is away (Notify.tellOrKeep).
local function tellCreatorClosed(contract, amount)
    local owed, parked = 0, 0
    if Contracts.owedTo then owed, parked = Contracts.owedTo(contract.id, contract.creator_cid) end
    local premium = Notify.dollars(amount)
    local body = 'Your target bought out the contract. '
    if owed > 0 or parked > 0 then
        body = body .. ('Your escrow and the %s buyout are yours, but not all of it is in your '
            .. 'hands yet.'):format(premium)
        if owed > 0 then
            body = body .. (Identity.byCitizenId(contract.creator_cid)
                and ' %d thing(s) would not fit and are waiting for you — they arrive when you '
                    .. 'next have room.'
                or  ' %d thing(s) could not be handed over yet and arrive as soon as you can '
                    .. 'take them.'):format(owed)
        end
        if parked > 0 then
            body = body .. (' %d thing(s) could not be confirmed as handed back; staff have been '
                .. 'asked to check.'):format(parked)
        end
    else
        body = body .. ('Your escrow is back and the %s buyout was paid to you.'):format(premium)
    end
    Notify.tellOrKeep(contract.creator_cid, 'Contract closed', body, { bypassBudget = true },
        contract.id)
end

--- What the target who paid is told when the premium comes back: why, from
--- how the contract stands now, and whether the money is in their hands.
--- The refund was handed back without a word, so a target who had paid saw
--- the card vanish (or, by /cleanse, nothing at all) and money turn up.
---@param why string|nil the reason, when it is not the contract's ending
local function tellRefunded(contractId, payer, amount, lineId, why)
    if not payer then return end
    local now = Storage.readContract(contractId)
    local line = Storage.readEscrowLine(lineId)
    local lead = why
    if not lead then
        if now and now.state == CH.STATE.COMPLETED then
            lead = 'A hitman finished the contract on you before your buyout closed it'
        elseif now and CH.TERMINAL[now.state] then
            lead = 'The contract on you closed another way before your buyout went through'
        else
            lead = 'Your buyout could not be completed'
        end
    end
    local where
    if line and line.state == CH.ESCROW_STATE.SETTLED then
        where = 'is back'
    elseif line and Escrow and Escrow.parked(line) then
        where = 'could not be confirmed as handed back; staff have been asked to check it'
    else
        where = 'is on its way: it arrives as soon as you can take it'
    end
    Notify.tellOrKeep(payer, 'Buyout refunded',
        ('%s, so your %s %s.'):format(lead, Notify.dollars(amount), where),
        { bypassBudget = true }, contractId)
end

--- Close a bought-out contract: the creator gets their escrow back plus the
--- premium, and the contract resolves once.
---@param opts table|nil { retryable = true } when driven by the queue
--- One settle per contract at a time (Contracts.serialized). An instant
--- buyout is recorded as due before it settles, so the tick's processQueue
--- could settle the same buyout in its awaits: one of the two lost the
--- resolve and refunded the target a buyout they had been given, while the
--- creator was paid the premium. The loser now answers busy and the tick
--- tries again next time, when it finds the queue cleared.
function Bailout.settle(contractId, amount, targetCid, account, opts)
    return Contracts.serialized({ 'settle:' .. tostring(contractId) },
        settleUnlocked, contractId, amount, targetCid, account, opts)
end

settleUnlocked = function(contractId, amount, targetCid, account, opts)
    local contract = Storage.readContract(contractId)
    if not contract then return false, CH.ERR.NOT_FOUND end
    -- The queue read this record before another settle finished it and
    -- cleared the queue: nothing is left to settle or to refund.
    if opts and opts.retryable and not contract.bailout_queued_at then
        return false, CH.ERR.ALREADY_SETTLED
    end
    account = account or contract.bailout_paid_account or 'bank'

    -- Already bought out, with this buyout still queued: the only thing
    -- that closes a contract as BAILED_OUT is a buyout, and a second one is
    -- refused while this one is queued. So this settle closed it already and
    -- the process died before the premium was handed over and the queue
    -- cleared. Treating that as "resolved some other way" refunded the
    -- target a buyout they had been given, and the creator never saw the
    -- premium.
    -- A hitman told "it closes in two minutes unless you finish it first"
    -- who did: the kill made, its photo on the way, or the handover armed
    -- and counting. Settled over them, the photo was refused and the
    -- handover ended as closed, with the target paid out of a contract they
    -- had lost. So the queue waits for it, as it waits for a claim
    -- (LOCKED, below), and nothing is counted against the attempts. Bounded
    -- by the longest a kill waits for its photo: a kill made as the delay ran
    -- out has that long, and the target's money is already gone. Only for
    -- work begun before the delay ran out: one begun after it, before the
    -- tick came round, was too late, and waited for it paid the hitman and
    -- refunded a target who had bought out in time.
    if opts and opts.retryable and contract.bailout_queued_at
        and contract.state == CH.STATE.ACCEPTED
        and os.time() - contract.bailout_queued_at < (Config.Bailout.ProcessingDelaySeconds or 0)
            + 2 * Config.Completion.PhotoTokenLifetimeSeconds
        and Bailout.finishing(contractId,
            contract.bailout_queued_at + (Config.Bailout.ProcessingDelaySeconds or 0)) then
        return false, CH.ERR.LOCKED
    end

    local ok, err
    if contract.state == CH.STATE.BAILED_OUT and contract.bailout_queued_at then
        ok = true
    else
        ok, err = Contracts.resolve(contractId, CH.STATE.BAILED_OUT, contract.creator_cid, nil, 'bailed_out')
    end
    if not ok then
        -- LOCKED is not a resolution: the contract is mid-claim and will be
        -- either completed or back to accepted within a tick or two. Refunding
        -- here made the target buy out again for a race they did not lose, so
        -- a queued buyout waits and tries again instead.
        --
        -- Bounded, because a claim interrupted by a crash could leave a
        -- contract completing forever, and the target's money is already
        -- gone. Once the attempts run out it refunds like any other failure.
        if err == CH.ERR.LOCKED and opts and opts.retryable then
            local attempts = (contract.bailout_attempts or 0) + 1
            if attempts < (Config.Bailout.MaxSettleAttempts or 10) then
                Storage.setBailoutQueue(contract.id, {
                    bailout_queued_at = contract.bailout_queued_at,
                    bailout_paid_by = contract.bailout_paid_by,
                    bailout_paid_amount = contract.bailout_paid_amount,
                    bailout_paid_account = contract.bailout_paid_account,
                    bailout_attempts = attempts,
                })
                return false, err
            end
            Audit.financial('bailout_retries_exhausted', targetCid, contractId,
                { amount = amount, attempts = attempts })
        end

        -- The contract resolved some other way first (a hitman completed it
        -- during the delay). Refund the premium to the account it came from;
        -- if the target is offline, or the framework refuses the credit, it
        -- is owed rather than lost.
        --
        -- Once, the way the premium is paid: an owed line under an id from
        -- this buyout, cleared from the queue only after. Credited straight
        -- to the target, a queue clear that raised left the record for the
        -- next tick, which refunded it again, on every tick the clear kept
        -- failing. Now a retry finds the line and its state.
        local refundId = Bailout.refundLineId(contractId, contract.bailout_queued_at)
        payOwed(contract, refundId, targetCid, amount, account, 'bailout_refund')
        Audit.financial('bailout_refunded', targetCid, contractId, { amount = amount, reason = err })
        Bailout.clearQueue(contractId, contract.bailout_queued_at)
        tellRefunded(contractId, targetCid, amount, refundId)
        return false, err
    end

    -- The premium, once. It is written as an owed line under an id that
    -- comes from the contract, then handed over the way every owed line
    -- is: now if the creator is here, queued for them if not.
    --
    -- A settle that dies after paying and before clearing the queue looks,
    -- on the next tick, exactly like one that died before paying: bought
    -- out, still queued. Credited straight into the creator's pocket, the
    -- premium was paid again. Written under the contract's own id, the
    -- second write lands on the first line and changes nothing, and the
    -- line's state says whether it was handed over.
    --
    -- It says which buyout it was (the moment it was recorded, and by whom),
    -- so a buyout whose record the store would not confirm can tell its own
    -- premium from another's (Bailout.decideUnrecorded).
    payOwed(contract, Bailout.premiumLineId(contract.id), contract.creator_cid,
        amount, account, 'bailout_premium',
        { queued_at = contract.bailout_queued_at, paid_by = contract.bailout_paid_by })

    Audit.financial('bailout_settled', targetCid, contractId, { amount = amount })
    tellCreatorClosed(contract, amount)
    -- And the target who paid, told nothing when a queued buyout closed: an
    -- officer using /cleanse cannot open the app to see it.
    Notify.tellOrKeep(targetCid, 'Buyout complete',
        'Your buyout went through; the contract on you is closed.', { bypassBudget = true },
        contractId)

    Bailout.clearQueue(contractId, contract.bailout_queued_at)
    return true
end

--- Record money owed to an offline player as a real escrow line, so
--- Escrow.retryPending can deliver it on their next login (§9.3).
---
--- `raise` when crediting it raised (deliver), and the line carries it as
--- Escrow.deliver would have: nothing arrived is one raise, and queued as
--- usual; part of it, or no telling, is left for staff at once
--- (Escrow.parked), not queued, with what they held before and the part
--- that arrived, so a staff pay gives only the rest.
---@param raise table|nil { error, arrived, before } from Util.credit
function Bailout.owe(cid, contractId, amount, account, reason, raise)
    -- The id comes from the store's own sequence, not a truncated clock:
    -- two owes in the same second would otherwise share an id and the second
    -- would overwrite the first. And confirmed unused before it is written,
    -- because escrow is stored with ON DUPLICATE KEY UPDATE: an id already
    -- in use does not fail, it lands on top of the line that holds it and
    -- takes its money with it.
    local lineId = Util.mintId(Storage.nextId, 'owe', Storage.readEscrowLine)
    if not lineId then
        Audit.financial('owe_id_exhausted', cid, contractId, { amount = amount })
        leaveForStaff({
            kind = 'owe_id_exhausted', contract_id = contractId, cids = { owed = cid },
            amount = amount, account = account == 'cash' and 'cash' or 'bank',
            known = { reason = reason, error = raise and raise.error,
                      arrived = raise and raise.arrived },
        })
        return nil
    end

    local line = {
        id = lineId,
        contract_id = contractId,
        slot = 0,                       -- outside the payout slots: not claimable
        -- Its own portion and an explicit owner, so no general release can
        -- sweep money that is already promised to someone.
        portion = CH.PORTION.OWED,
        owed_to = cid,
        source = account == 'cash' and 'cash' or 'bank',
        amount = amount,
        state = CH.ESCROW_STATE.HELD,
    }
    local parked = false
    if raise and Escrow then
        line.deliver_raises = raise.arrived == 0 and 1 or Escrow.DELIVER_RAISE_LIMIT
        line.deliver_before = raise.before
        if raise.arrived and raise.arrived > 0 then line.deliver_arrived = raise.arrived end
        parked = Escrow.parked(line)
    end
    Storage.writeEscrow(contractId, { line })
    if not parked then
        Storage.queuePending(cid, contractId, lineId)
        if Escrow and Escrow.noteWaiting then Escrow.noteWaiting(cid, true) end
    end
    Audit.financial('owed_queued', cid, contractId, { amount = amount, reason = reason,
        error = raise and raise.error, arrived = raise and raise.arrived })
    if parked then
        Audit.financial('escrow_deliver_parked', cid, contractId, {
            line = lineId, source = line.source, amount = amount,
            raises = line.deliver_raises, unknown = true, before = line.deliver_before,
            arrived = raise.arrived, review = true,
        })
        Log.always(('escrow line %s: crediting %s %s raised, and only part of it '
            .. 'arrived or what did could not be read; left for staff (/%s) — check what '
            .. 'they have')
            :format(tostring(lineId), tostring(amount), tostring(line.source),
                tostring(Config.Admin.Commands.stuck)))
    end
    return lineId
end

--- Clear a contract's buyout queue, only while it still holds the buyout
--- recorded at `queuedAt` (Storage.clearBailout): a clear that lands late,
--- or is asked twice, never clears a later buyout. Without `queuedAt`, as
--- an older caller asks, whatever is queued.
---@param contractId string
---@param queuedAt integer|nil the buyout's bailout_queued_at
function Bailout.clearQueue(contractId, queuedAt)
    if queuedAt == nil then return Storage.setBailoutQueue(contractId, nil) end
    return Storage.clearBailout(contractId, queuedAt)
end

--- Hand a queued buyout's premium straight back, without settling it.
---
--- For a store that is about to disappear (memory mode stopping), where the
--- delay will never run out and an owed line would vanish with the tables.
--- The payer first; if they have gone, the creator it was on its way to;
--- and the audit row either way, so staff can place it by hand if nobody
--- involved was online to take it.
---@param contract table a contract row carrying the queue columns
---@param reason string
---@return boolean delivered
function Bailout.returnQueued(contract, reason)
    if not contract or not contract.bailout_queued_at then return false end

    local amount = tonumber(contract.bailout_paid_amount) or 0
    local account = contract.bailout_paid_account == 'cash' and 'cash' or 'bank'
    local payer = contract.bailout_paid_by
    local paidTo, doubt

    if amount > 0 then
        for _, cid in ipairs({ payer, contract.creator_cid }) do
            local who = cid and Identity.byCitizenId(cid)
            if who then
                local credited, raised, arrived = Util.credit(who.player, account, amount)
                if credited then
                    paidTo = cid
                    break
                end
                -- A credit that raised with some of it there, or no telling
                -- (Util.credit), is not offered to the next one as well:
                -- that paid it twice. The row says what is known.
                if raised and arrived ~= 0 then
                    doubt = { cid = cid, error = raised, arrived = arrived }
                    break
                end
            end
        end
    end

    Audit.financial(paidTo and 'bailout_refunded' or 'bailout_refund_stranded',
        payer, contract.id,
        { amount = amount, account = account, paid_to = paidTo, reason = reason,
          raised_for = doubt and doubt.cid, error = doubt and doubt.error,
          arrived = doubt and doubt.arrived, review = doubt and true or nil })
    if not paidTo and amount > 0 then
        leaveForStaff({
            kind = 'bailout_refund_stranded', contract_id = contract.id,
            cids = { payer = payer, creator = contract.creator_cid,
                     raised_for = doubt and doubt.cid or nil },
            amount = amount, account = account,
            known = { reason = reason, error = doubt and doubt.error,
                      arrived = doubt and doubt.arrived },
        })
    end
    Bailout.clearQueue(contract.id, contract.bailout_queued_at)
    return paidTo ~= nil
end

--------------------------------------------------------------------------
-- A buyout the server decides by itself
--------------------------------------------------------------------------

--- Hand a buyout's premium back to its payer under the refund line's own id
--- (idempotent), and tell them. The contract it was for ended without it,
--- or never recorded it.
local function refundBuyout(contract, fields, why)
    local payer = fields.bailout_paid_by
    local refundId = Bailout.refundLineId(contract.id, fields.bailout_queued_at)
    payOwed(contract, refundId, payer,
        fields.bailout_paid_amount, fields.bailout_paid_account, 'bailout_refund')
    Audit.financial('bailout_refunded', payer, contract.id,
        { amount = fields.bailout_paid_amount, reason = why })
    tellRefunded(contract.id, payer, fields.bailout_paid_amount, refundId,
        'Your buyout could not be completed')
end

--- Whether this buyout's premium was paid: the premium line exists and says
--- it was this buyout's (its metadata, written from this version on). nil
--- when there is one that cannot say whose it was.
local function premiumPaid(contractId, queuedAt)
    local line = Storage.readEscrowLine(Bailout.premiumLineId(contractId))
    if not line then return false end
    local mark = type(line.metadata) == 'table' and line.metadata or nil
    if not mark or mark.queued_at == nil then return nil end
    return tonumber(mark.queued_at) == tonumber(queuedAt)
end

local function decideUnlocked(item, fields)
    local contractId = item.contract_id
    if Storage.recordBailout(contractId, fields) then
        -- Recorded, or it was already: it settles as any buyout does.
        Notify.toCitizen(fields.bailout_paid_by, 'Buyout recorded',
            'Your buyout payment is on record now, and the contract closes once it settles. If '
            .. 'it ends another way first, the payment comes back to you.', { bypassBudget = true })
        return 'done', 'recorded: it settles as any buyout does'
    end
    local contract = Storage.readContract(contractId)
    if contract and (contract.state == CH.STATE.ACTIVE or contract.state == CH.STATE.ACCEPTED
        or contract.state == CH.STATE.COMPLETING) then
        -- Another buyout holds the queue, or a claim the contract: this
        -- record may still land, so it is asked again on the next tick.
        return 'wait', 'its contract is still open'
    end
    -- Closed: a terminal contract's compare-and-set never matches again, so
    -- nothing lands after this.
    local paid = premiumPaid(contractId, fields.bailout_queued_at)
    if paid then return 'done', 'it was settled: the contract was bought out by it' end
    if paid == nil and contract and contract.state == CH.STATE.BAILED_OUT then
        return 'staff', 'its contract was bought out, and the premium paid does not say by which '
            .. 'buyout'
    end
    refundBuyout(contract or { id = contractId }, fields, 'unrecorded')
    return 'done', 'its contract ended without it, so the premium was refunded to the payer'
end

--- bailout_unrecorded, settled by the server from the record the item
--- carries (S12): the record written again by its compare-and-set, then
--- settled as any buyout, waited on while its contract is open, or refunded
--- once the contract has ended without it. Under the keys a buy takes.
---@param item table a review item
---@return string verdict 'done' | 'wait' | 'staff'
---@return string note
function Bailout.decideUnrecorded(item)
    local fields = type(item.known) == 'table' and item.known.fields or nil
    local contractId = item.contract_id
    if type(fields) ~= 'table' or not fields.bailout_queued_at or not fields.bailout_paid_by
        or not contractId then
        return 'staff', 'it does not carry the buyout\'s record'
    end
    local out = table.pack(Contracts.serialized({ 'contract:' .. contractId, 'settle:' .. contractId },
        decideUnlocked, item, fields))
    if out[1] == false and out[2] == CH.ERR.BUSY then return 'wait', 'its contract is busy' end
    return table.unpack(out, 1, out.n)
end

--- When the console last said a queued buyout's settle raised, by contract.
local raiseSaidAt = {}
local RAISE_SAID_EVERY = 600

--- A queued buyout that keeps raising as it settles, past
--- Bailout.MaxSettleAttempts: decided as an unrecorded buyout is (W043). A
--- blind refund could pay a target whose buyout already closed the
--- contract. Still open: refunded and the queue cleared. Bought out with
--- this buyout's premium paid: the queue cleared. Anything else: left for
--- staff with what is known, and the queue cleared so it stops raising.
local function giveUp(contract, attempts, err)
    local now = Storage.readContract(contract.id)
    if not now or now.bailout_queued_at ~= contract.bailout_queued_at then return 'settled' end
    local fields = {
        bailout_queued_at = now.bailout_queued_at, bailout_paid_by = now.bailout_paid_by,
        bailout_paid_amount = now.bailout_paid_amount, bailout_paid_account = now.bailout_paid_account,
    }
    Audit.financial('bailout_retries_exhausted', now.bailout_paid_by, now.id,
        { amount = now.bailout_paid_amount, attempts = attempts, raised = true })
    if now.state == CH.STATE.ACTIVE or now.state == CH.STATE.ACCEPTED
        or now.state == CH.STATE.COMPLETING then
        refundBuyout(now, fields, 'settle_raised')
        Bailout.clearQueue(now.id, now.bailout_queued_at)
        return 'refunded'
    end
    if now.state == CH.STATE.BAILED_OUT and premiumPaid(now.id, now.bailout_queued_at) then
        Bailout.clearQueue(now.id, now.bailout_queued_at)
        return 'cleared'
    end
    leaveForStaff({
        kind = 'bailout_settle_raised', contract_id = now.id,
        cids = { payer = now.bailout_paid_by, creator = now.creator_cid },
        amount = now.bailout_paid_amount, account = now.bailout_paid_account,
        known = { state = now.state, attempts = attempts, error = tostring(err) },
    })
    Bailout.clearQueue(now.id, now.bailout_queued_at)
    return 'staff'
end

--- A queued buyout's settle that raised: said (at most once a contract every
--- RAISE_SAID_EVERY seconds), audited and counted on its row as a LOCKED
--- wait is, and past Bailout.MaxSettleAttempts decided (giveUp).
local function settleRaised(contract, err)
    local attempts = (tonumber(contract.bailout_attempts) or 0) + 1
    local now = os.time()
    local say = not raiseSaidAt[contract.id] or now - raiseSaidAt[contract.id] >= RAISE_SAID_EVERY
    if say then
        raiseSaidAt[contract.id] = now
        Log.always(('queued buyout on contract %s: settling it raised (%s); the other queued '
            .. 'buyouts went on, and it is tried again on the next tick (%d of %d)')
            :format(tostring(contract.id), Util.dbError(err), attempts,
                Config.Bailout.MaxSettleAttempts or 10))
    end
    pcall(Audit.financial, 'bailout_settle_raised', contract.bailout_paid_by, contract.id,
        { amount = contract.bailout_paid_amount, attempts = attempts, error = Util.dbError(err) })
    if attempts < (Config.Bailout.MaxSettleAttempts or 10) then
        pcall(Storage.setBailoutQueue, contract.id, {
            bailout_queued_at = contract.bailout_queued_at,
            bailout_paid_by = contract.bailout_paid_by,
            bailout_paid_amount = contract.bailout_paid_amount,
            bailout_paid_account = contract.bailout_paid_account,
            bailout_attempts = attempts,
        })
        return
    end
    local ran, how = pcall(Contracts.serialized,
        { 'contract:' .. contract.id, 'settle:' .. contract.id }, giveUp, contract, attempts, err)
    if not ran and say then
        Log.always(('queued buyout on contract %s: deciding it after %d raises raised too (%s); '
            .. 'it is tried again on the next tick'):format(tostring(contract.id), attempts,
            Util.dbError(how)))
    end
end

--- Process queued buyouts whose delay has elapsed. Driven by the main tick.
---
--- Each in its own pcall (W043): one whose settle kept raising aborted the
--- whole job at that item on every tick, so every buyout after it in the
--- queue never settled, and it was never refunded itself.
function Bailout.processQueue()
    local settled = 0
    local pending = readQueue()

    for i = 1, #pending do
        local contract = pending[i]
        -- One paid before the contract went on hold waits for its release
        -- (server/freeze.lua): nothing on it settles meanwhile.
        local held = Contracts and Contracts.heldByStaff and Contracts.heldByStaff(contract)
        if not held and os.time() - contract.bailout_queued_at >= Config.Bailout.ProcessingDelaySeconds then
            local ran, ok = pcall(Bailout.settle, contract.id, contract.bailout_paid_amount,
                contract.bailout_paid_by, contract.bailout_paid_account, { retryable = true })
            if not ran then
                settleRaised(contract, ok)
            elseif ok then
                settled = settled + 1
            end
        end
    end

    return settled
end

function Bailout.queuedCount()
    return #readQueue()
end

return Bailout
