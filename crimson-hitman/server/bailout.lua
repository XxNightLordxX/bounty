--- Contract Cleanse — the target buys out their own contract (§5, §14.17).
---
--- The premium is charged before anything else happens, and the contract
--- resolves through the normal path so the creator's escrow returns exactly
--- once. A bailout while a hitman is mid-delivery does not rug-pull them: it
--- is queued for a short processing delay first.

local Util = require_shared('util')

local Bailout = {}

local Storage, Identity, Contracts, Escrow, Audit, Notify

function Bailout.init(deps)
    Storage, Identity, Contracts, Escrow, Audit, Notify =
        deps.storage, deps.identity, deps.contracts, deps.escrow, deps.audit, deps.notify
    Bailout.kidnap = deps.kidnap
    Bailout.death = deps.death
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

--- Contracts the caller may buy out — those naming them as target.
function Bailout.available(actor)
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
            and (c.bailout_amount or 0) > 0 and Notify.shownToTarget(c) then
            out[#out + 1] = {
                id = c.id, amount = c.bailout_amount,
                queued = c.bailout_queued_at ~= nil,
            }
        end
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
        Audit.financial('bailout_refund_stranded', cid, contractId,
            { amount = amount, account = account, reason = why,
              error = raise and raise.error, arrived = raise and raise.arrived })
    end
end

--- Write a paid buyout onto the contract. The target has been charged by
--- now, and this record is the only thing that will settle or refund it.
---
--- A write that raised (a dropped connection on mysql) left the premium in
--- no pocket, no line and no queue. It may or may not have landed, as for
--- a placed contract (Contracts.create), so the store decides: there, it is
--- recorded; not there, the premium goes back and the error goes on. A read
--- that raises too decides nothing, and handing back a record that landed
--- would refund a buyout the tick then settles, so that raises with the
--- bailout_paid row saying what was taken.
local function recordPaid(contractId, fields)
    local wrote, err = pcall(Storage.setBailoutQueue, contractId, fields)
    if wrote then return end
    local payer = fields.bailout_paid_by
    Audit.financial('bailout_record_failed', payer, contractId,
        { amount = fields.bailout_paid_amount, error = tostring(err) })
    local stored = Storage.readContract(contractId)
    if stored and stored.bailout_queued_at and stored.bailout_paid_by == payer then return end
    handBack(payer, contractId, fields.bailout_paid_amount, fields.bailout_paid_account, 'unrecorded')
    error(err, 0)
end

function Bailout.buy(actor, contractId)
    contractId = Util.toId(contractId)
    if not contractId then return false, CH.ERR.INVALID_INPUT end
    if not Config.Bailout.Enabled then return false, CH.ERR.BAILOUT_OFF end

    local contract = Storage.readContract(contractId)
    if not contract then return false, CH.ERR.NOT_FOUND end
    if contract.target_cid ~= actor.cid then return false, CH.ERR.NOT_PARTICIPANT end
    -- Each of these is a different thing to do about it, so each says which.
    if contract.state ~= CH.STATE.ACTIVE and contract.state ~= CH.STATE.ACCEPTED then
        return false, CH.ERR.ALREADY_SETTLED
    end
    if (contract.bailout_amount or 0) <= 0 then return false, CH.ERR.NO_BUYOUT_PRICE end
    if contract.bailout_queued_at then return false, CH.ERR.BUYOUT_PENDING end

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
        recordPaid(contract.id, {
            bailout_queued_at = os.time(),
            bailout_paid_by = actor.cid,
            bailout_paid_amount = amount,
            bailout_paid_account = account,
            bailout_attempts = 0,
        })

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
    -- settle clears the record when it is done.
    -- Under the settle lock from the record on, so the tick cannot settle
    -- it too in between (Bailout.settle).
    local settled, why = Contracts.serialized({ 'settle:' .. tostring(contractId) }, function()
        recordPaid(contract.id, {
            bailout_queued_at = os.time() - (Config.Bailout.ProcessingDelaySeconds or 0),
            bailout_paid_by = actor.cid,
            bailout_paid_amount = amount,
            bailout_paid_account = account,
            bailout_attempts = 0,
        })
        return settleUnlocked(contractId, amount, actor.cid, account)
    end)
    -- Another settle of this contract was running: nothing of this buyout
    -- was recorded, so the charge goes back rather than vanish.
    if not settled and why == CH.ERR.BUSY then
        handBack(actor.cid, contractId, amount, account, why)
    end
    return settled, why
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
local function payOwed(contract, id, cid, amount, account, reason)
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
        } })
        Storage.queuePending(cid, contract.id, id)
        if Escrow and Escrow.noteWaiting then Escrow.noteWaiting(cid, true) end
    end
    local line = Storage.readEscrowLine(id)
    if line and line.id == id and line.state == CH.ESCROW_STATE.HELD and Escrow then
        Escrow.release(contract.id, cid, { line = id }, reason)
    end
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
        payOwed(contract, Bailout.refundLineId(contractId, contract.bailout_queued_at),
            targetCid, amount, account, 'bailout_refund')
        Audit.financial('bailout_refunded', targetCid, contractId, { amount = amount, reason = err })
        Bailout.clearQueue(contractId)
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
    payOwed(contract, Bailout.premiumLineId(contract.id), contract.creator_cid,
        amount, account, 'bailout_premium')

    Audit.financial('bailout_settled', targetCid, contractId, { amount = amount })
    Notify.toCitizen(contract.creator_cid, 'Contract closed',
        'Your target bought out the contract. Escrow and premium have been returned.',
        { bypassBudget = true })

    Bailout.clearQueue(contractId)
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
        print(('[crimson-hitman] escrow line %s: crediting %s %s raised, and only part of it '
            .. 'arrived or what did could not be read; left for staff (/ch-stuck) — check what '
            .. 'they have')
            :format(tostring(lineId), tostring(amount), tostring(line.source)))
    end
    return lineId
end

function Bailout.clearQueue(contractId)
    return Storage.setBailoutQueue(contractId, nil)
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
    Bailout.clearQueue(contract.id)
    return paidTo ~= nil
end

--- Process queued buyouts whose delay has elapsed. Driven by the main tick.
function Bailout.processQueue()
    local settled = 0
    local pending = readQueue()

    for i = 1, #pending do
        local contract = pending[i]
        if os.time() - contract.bailout_queued_at >= Config.Bailout.ProcessingDelaySeconds then
            if Bailout.settle(contract.id, contract.bailout_paid_amount,
                              contract.bailout_paid_by, contract.bailout_paid_account,
                              { retryable = true }) then
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
