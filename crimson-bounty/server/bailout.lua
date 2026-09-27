--- Bounty Cleanse — the target buys out their own contract (§5, §14.17).
---
--- The premium is charged before anything else happens, and the contract
--- resolves through the normal path so the creator's escrow returns exactly
--- once. A bailout while a hunter is mid-delivery does not rug-pull them: it
--- is queued for a short processing delay first.

local Util = require_shared('util')

local Bailout = {}

local Storage, Identity, Contracts, Escrow, Audit, Notify

function Bailout.init(deps)
    Storage, Identity, Contracts, Escrow, Audit, Notify =
        deps.storage, deps.identity, deps.contracts, deps.escrow, deps.audit, deps.notify
    Bailout.kidnap = deps.kidnap
end

--- Queued buyouts live on the contract row, not in a process-local table.
--- The target has already been charged by the time one is queued, so a
--- restart during the delay window must not lose their money.
---
--- Terminal contracts are deliberately included: a hunter completing during
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

--- True when any hunter has an armed countdown running on this contract.
function Bailout.kidnapInProgress(contractId)
    if not Bailout.kidnap then return false end
    local hunters = Storage.readHunters(contractId)
    for i = 1, #hunters do
        if hunters[i].state == 'active'
            and Bailout.kidnap.progress(contractId, hunters[i].hunter_cid) then
            return true
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
        if (c.state == CB.STATE.ACTIVE or c.state == CB.STATE.ACCEPTED)
            and (c.bailout_amount or 0) > 0 then
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
function Bailout.buy(actor, contractId)
    contractId = Util.toId(contractId)
    if not contractId then return false, CB.ERR.INVALID_INPUT end
    if not Config.Bailout.Enabled then return false, CB.ERR.BAILOUT_OFF end

    local contract = Storage.readContract(contractId)
    if not contract then return false, CB.ERR.NOT_FOUND end
    if contract.target_cid ~= actor.cid then return false, CB.ERR.NOT_PARTICIPANT end
    -- Each of these is a different thing to do about it, so each says which.
    if contract.state ~= CB.STATE.ACTIVE and contract.state ~= CB.STATE.ACCEPTED then
        return false, CB.ERR.ALREADY_SETTLED
    end
    if (contract.bailout_amount or 0) <= 0 then return false, CB.ERR.NO_BUYOUT_PRICE end
    if contract.bailout_queued_at then return false, CB.ERR.BUYOUT_PENDING end

    -- A target cannot buy their way out from the floor mid-fight.
    if Config.Bailout.BlockWhileIncapacitated then
        local dead, lastStand = Identity.deathState(actor.source)
        if dead or lastStand then return false, CB.ERR.INCAPACITATED end
    end

    -- Nor out from under a handover already in progress: the hunter has the
    -- target in hand and is seconds from delivering.
    if Bailout.kidnapInProgress(contractId) then return false, CB.ERR.HANDOVER_IN_PROGRESS end

    local amount = contract.bailout_amount

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
    if not paid then return false, CB.ERR.INSUFFICIENT end

    Audit.financial('bailout_paid', actor.cid, contractId, { amount = amount })

    -- With a hunter already engaged, the buyout is queued rather than
    -- instant, so a hunter cannot be rug-pulled mid-delivery (§14.17).
    local hunters = Storage.readHunters(contractId)
    local engaged = false
    for i = 1, #hunters do
        if hunters[i].state == 'active' then engaged = true end
    end

    if engaged and Config.Bailout.ProcessingDelaySeconds > 0 then
        -- Persisted, not held in memory: the target's money is already gone,
        -- so a restart inside the delay window must still settle.
        -- Through the narrow write, not writeContract. The target's money is
        -- already gone at this point, and a writeContract from any other
        -- handler holding an older copy of this row used to erase the queue
        -- on top of it: premium charged, nothing left to settle or refund it.
        Storage.setBailoutQueue(contract.id, {
            bailout_queued_at = os.time(),
            bailout_paid_by = actor.cid,
            bailout_paid_amount = amount,
            bailout_paid_account = account,
            bailout_attempts = 0,
        })

        Notify.toCitizen(contract.creator_cid, 'Contract challenged',
            'Your target is buying out the contract. It closes shortly.')
        return true, nil
    end

    -- Recorded before it is settled, as a buyout already due. The target
    -- has paid; until the premium line exists nothing else says so, and
    -- settling is a score of awaits on mysql. A crash in any of them left a
    -- contract bought out with the premium in no line, no queue and no
    -- pocket. Recorded, the next tick finishes it like a queued buyout, and
    -- settle clears the record when it is done.
    Storage.setBailoutQueue(contract.id, {
        bailout_queued_at = os.time() - (Config.Bailout.ProcessingDelaySeconds or 0),
        bailout_paid_by = actor.cid,
        bailout_paid_amount = amount,
        bailout_paid_account = account,
        bailout_attempts = 0,
    })
    return Bailout.settle(contractId, amount, actor.cid, account)
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
local function deliver(cid, contractId, amount, account, reason)
    local who = Identity.byCitizenId(cid)
    if who and Util.credit(who.player, account, amount) then return true end
    return Bailout.owe(cid, contractId, amount, account, reason) ~= nil
end

--- The id of a contract's buyout premium line. One per contract: only one
--- buyout can ever close it.
---@param contractId string
---@return string
function Bailout.premiumLineId(contractId)
    return 'prem:' .. contractId
end

--- Owe the creator the premium and hand it over. Idempotent: see settle.
local function payPremium(contract, amount, account)
    local id = Bailout.premiumLineId(contract.id)
    local existing = Storage.readEscrowLine(id)
    if not (existing and existing.id == id) then
        Storage.writeEscrow(contract.id, { {
            id = id,
            contract_id = contract.id,
            slot = 0,
            portion = CB.PORTION.OWED,
            owed_to = contract.creator_cid,
            source = account == 'cash' and 'cash' or 'bank',
            amount = amount,
            state = CB.ESCROW_STATE.HELD,
        } })
        Storage.queuePending(contract.creator_cid, contract.id, id)
        if Escrow and Escrow.noteWaiting then Escrow.noteWaiting(contract.creator_cid, true) end
    end
    local line = Storage.readEscrowLine(id)
    if line and line.id == id and line.state == CB.ESCROW_STATE.HELD and Escrow then
        Escrow.release(contract.id, contract.creator_cid, { line = id }, 'bailout_premium')
    end
end

--- Close a bought-out contract: the creator gets their escrow back plus the
--- premium, and the contract resolves once.
---@param opts table|nil { retryable = true } when driven by the queue
function Bailout.settle(contractId, amount, targetCid, account, opts)
    local contract = Storage.readContract(contractId)
    if not contract then return false, CB.ERR.NOT_FOUND end
    account = account or contract.bailout_paid_account or 'bank'

    -- Already bought out, with this buyout still queued: the only thing
    -- that closes a contract as BAILED_OUT is a buyout, and a second one is
    -- refused while this one is queued. So this settle closed it already and
    -- the process died before the premium was handed over and the queue
    -- cleared. Treating that as "resolved some other way" refunded the
    -- target a buyout they had been given, and the creator never saw the
    -- premium.
    local ok, err
    if contract.state == CB.STATE.BAILED_OUT and contract.bailout_queued_at then
        ok = true
    else
        ok, err = Contracts.resolve(contractId, CB.STATE.BAILED_OUT, contract.creator_cid, nil, 'bailed_out')
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
        if err == CB.ERR.LOCKED and opts and opts.retryable then
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

        -- The contract resolved some other way first (a hunter completed it
        -- during the delay). Refund the premium to the account it came from;
        -- if the target is offline, it is owed rather than lost.
        -- A refusal is the same situation as being offline: the money has
        -- not been delivered. AddMoney returns false for an account
        -- qbx_core will not credit, and a server with a balance ceiling
        -- refuses on exactly the payouts that matter most.
        if not deliver(targetCid, contractId, amount, account, 'bailout_refund') then
            -- Nowhere to put it and nobody to hand it to. Audited under its
            -- own name, with everything a server owner needs to place it by
            -- hand: the alternative is a player who paid for a buyout,
            -- never got it, and has no way to find out why.
            Audit.financial('bailout_refund_stranded', targetCid, contractId,
                { amount = amount, account = account, reason = err })
        end
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
    payPremium(contract, amount, account)

    Audit.financial('bailout_settled', targetCid, contractId, { amount = amount })
    Notify.toCitizen(contract.creator_cid, 'Contract closed',
        'Your target bought out the contract. Escrow and premium have been returned.',
        { bypassBudget = true })

    Bailout.clearQueue(contractId)
    return true
end

--- Record money owed to an offline player as a real escrow line, so
--- Escrow.retryPending can deliver it on their next login (§9.3).
function Bailout.owe(cid, contractId, amount, account, reason)
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

    Storage.writeEscrow(contractId, { {
        id = lineId,
        contract_id = contractId,
        slot = 0,                       -- outside the payout slots: not claimable
        -- Its own portion and an explicit owner, so no general release can
        -- sweep money that is already promised to someone.
        portion = CB.PORTION.OWED,
        owed_to = cid,
        source = account == 'cash' and 'cash' or 'bank',
        amount = amount,
        state = CB.ESCROW_STATE.HELD,
    } })
    Storage.queuePending(cid, contractId, lineId)
    if Escrow and Escrow.noteWaiting then Escrow.noteWaiting(cid, true) end
    Audit.financial('owed_queued', cid, contractId, { amount = amount, reason = reason })
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
    local paidTo

    if amount > 0 then
        for _, cid in ipairs({ payer, contract.creator_cid }) do
            local who = cid and Identity.byCitizenId(cid)
            if who and Util.credit(who.player, account, amount) then
                paidTo = cid
                break
            end
        end
    end

    Audit.financial(paidTo and 'bailout_refunded' or 'bailout_refund_stranded',
        payer, contract.id,
        { amount = amount, account = account, paid_to = paidTo, reason = reason })
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
