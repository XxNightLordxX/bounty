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
end

--- Queued buyouts live on the contract row, not in a process-local table.
--- The target has already been charged by the time one is queued, so a
--- restart during the delay window must not lose their money.
---
--- Terminal contracts are deliberately included: a hunter completing during
--- the delay is precisely the case where the premium has to be refunded, and
--- filtering those out would destroy the target's money.
local function readQueue()
    local out = {}
    local contracts = Storage.allContracts()
    for i = 1, #contracts do
        if contracts[i].bailout_queued_at then out[#out + 1] = contracts[i] end
    end
    return out
end

--- Contracts the caller may buy out — those naming them as target.
function Bailout.available(actor)
    local out = {}
    local contracts = Storage.allContracts()
    for i = 1, #contracts do
        local c = contracts[i]
        if c.target_cid == actor.cid
            and (c.state == CB.STATE.ACTIVE or c.state == CB.STATE.ACCEPTED)
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
    if not Config.Bailout.Enabled then return false, CB.ERR.BAD_STATE end

    local contract = Storage.readContract(contractId)
    if not contract then return false, CB.ERR.NOT_FOUND end
    if contract.target_cid ~= actor.cid then return false, CB.ERR.NOT_PARTICIPANT end
    if contract.state ~= CB.STATE.ACTIVE and contract.state ~= CB.STATE.ACCEPTED then
        return false, CB.ERR.BAD_STATE
    end
    if (contract.bailout_amount or 0) <= 0 then return false, CB.ERR.BAD_STATE end
    if contract.bailout_queued_at then return false, CB.ERR.BAD_STATE end

    -- A target cannot buy their way out from the floor mid-fight.
    if Config.Bailout.BlockWhileIncapacitated then
        local dead, lastStand = Identity.deathState(actor.source)
        if dead or lastStand then return false, CB.ERR.BAD_STATE end
    end

    local amount = contract.bailout_amount

    -- Debit first: the premium is taken before any state changes, so a
    -- failure here leaves the contract exactly as it was.
    -- Which account paid is remembered, so a refund goes back where it came
    -- from rather than silently laundering cash into bank money.
    local account = 'bank'
    local paid = actor.player.Functions.RemoveMoney('bank', amount)
    if not paid then
        account = 'cash'
        paid = actor.player.Functions.RemoveMoney('cash', amount)
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
        contract.bailout_queued_at = os.time()
        contract.bailout_paid_by = actor.cid
        contract.bailout_paid_amount = amount
        contract.bailout_paid_account = account
        Storage.writeContract(contract)

        Notify.toCitizen(contract.creator_cid, 'Contract challenged',
            'Your target is buying out the contract. It closes shortly.')
        return true, nil
    end

    return Bailout.settle(contractId, amount, actor.cid, account)
end

--- Close a bought-out contract: the creator gets their escrow back plus the
--- premium, and the contract resolves once.
function Bailout.settle(contractId, amount, targetCid, account)
    local contract = Storage.readContract(contractId)
    if not contract then return false, CB.ERR.NOT_FOUND end
    account = account or contract.bailout_paid_account or 'bank'

    local ok, err = Contracts.resolve(contractId, CB.STATE.BAILED_OUT, contract.creator_cid, nil, 'bailed_out')
    if not ok then
        -- The contract resolved some other way first (a hunter completed it
        -- during the delay). Refund the premium to the account it came from;
        -- if the target is offline, it is owed rather than lost.
        local target = Identity.byCitizenId(targetCid)
        if target then
            target.player.Functions.AddMoney(account, amount)
        else
            Bailout.owe(targetCid, contractId, amount, account, 'bailout_refund')
        end
        Audit.financial('bailout_refunded', targetCid, contractId, { amount = amount, reason = err })
        Bailout.clearQueue(contractId)
        return false, err
    end

    local creator = Identity.byCitizenId(contract.creator_cid)
    if creator then
        creator.player.Functions.AddMoney(account, amount)
    else
        -- Offline creator: the premium is owed, not lost. It is written as a
        -- real escrow line so the normal retry path can deliver it — a
        -- placeholder id would be read back as a missing line and dropped.
        Bailout.owe(contract.creator_cid, contractId, amount, account, 'bailout_premium')
    end

    Audit.financial('bailout_settled', targetCid, contractId, { amount = amount })
    Notify.toCitizen(contract.creator_cid, 'Contract closed',
        'Your target bought out the contract. Escrow and premium have been returned.')

    Bailout.clearQueue(contractId)
    return true
end

--- Record money owed to an offline player as a real escrow line, so
--- Escrow.retryPending can deliver it on their next login (§9.3).
function Bailout.owe(cid, contractId, amount, account, reason)
    local lineId = ('%s:owed%d'):format(contractId, os.time() % 100000)
    Storage.writeEscrow(contractId, { {
        id = lineId,
        contract_id = contractId,
        slot = 0,                       -- outside the payout slots: not claimable
        portion = CB.PORTION.BASELINE,
        source = account == 'cash' and 'cash' or 'bank',
        amount = amount,
        state = CB.ESCROW_STATE.HELD,
    } })
    Storage.queuePending(cid, contractId, lineId)
    Audit.financial('owed_queued', cid, contractId, { amount = amount, reason = reason })
    return lineId
end

function Bailout.clearQueue(contractId)
    local contract = Storage.readContract(contractId)
    if not contract then return false end
    contract.bailout_queued_at = nil
    contract.bailout_paid_by = nil
    contract.bailout_paid_amount = nil
    contract.bailout_paid_account = nil
    Storage.writeContract(contract)
    return true
end

--- Process queued buyouts whose delay has elapsed. Driven by the main tick.
function Bailout.processQueue()
    local settled = 0
    local pending = readQueue()

    for i = 1, #pending do
        local contract = pending[i]
        if os.time() - contract.bailout_queued_at >= Config.Bailout.ProcessingDelaySeconds then
            if Bailout.settle(contract.id, contract.bailout_paid_amount,
                              contract.bailout_paid_by, contract.bailout_paid_account) then
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
