--- Bounty Cleanse — the target buys out their own contract (§5, §14.17).
---
--- The premium is charged before anything else happens, and the contract
--- resolves through the normal path so the creator's escrow returns exactly
--- once. A bailout while a hunter is mid-delivery does not rug-pull them: it
--- is queued for a short processing delay first.

local Util = require_shared('util')

local Bailout = {}

local Storage, Identity, Contracts, Escrow, Audit, Notify

--- [contractId] = { at, targetCid, amount }
local queued = {}

function Bailout.init(deps)
    Storage, Identity, Contracts, Escrow, Audit, Notify =
        deps.storage, deps.identity, deps.contracts, deps.escrow, deps.audit, deps.notify
    queued = {}
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
                queued = queued[c.id] ~= nil,
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
    if queued[contractId] then return false, CB.ERR.BAD_STATE end

    -- A target cannot buy their way out from the floor mid-fight.
    if Config.Bailout.BlockWhileIncapacitated then
        local dead, lastStand = Identity.deathState(actor.source)
        if dead or lastStand then return false, CB.ERR.BAD_STATE end
    end

    local amount = contract.bailout_amount

    -- Debit first: the premium is taken before any state changes, so a
    -- failure here leaves the contract exactly as it was.
    local paid = actor.player.Functions.RemoveMoney('bank', amount)
    if not paid then
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
        queued[contractId] = { at = os.time(), targetCid = actor.cid, amount = amount }
        Notify.toCitizen(contract.creator_cid, 'Contract challenged',
            'Your target is buying out the contract. It closes shortly.')
        return true, nil
    end

    return Bailout.settle(contractId, amount, actor.cid)
end

--- Close a bought-out contract: the creator gets their escrow back plus the
--- premium, and the contract resolves once.
function Bailout.settle(contractId, amount, targetCid)
    local contract = Storage.readContract(contractId)
    if not contract then return false, CB.ERR.NOT_FOUND end

    local ok, err = Contracts.resolve(contractId, CB.STATE.BAILED_OUT, contract.creator_cid, nil, 'bailed_out')
    if not ok then
        -- The contract resolved some other way first (a hunter completed it
        -- during the delay). Refund the premium: they paid for nothing.
        local target = Identity.byCitizenId(targetCid)
        if target then target.player.Functions.AddMoney('bank', amount) end
        Audit.financial('bailout_refunded', targetCid, contractId, { amount = amount, reason = err })
        queued[contractId] = nil
        return false, err
    end

    local creator = Identity.byCitizenId(contract.creator_cid)
    if creator then
        creator.player.Functions.AddMoney('bank', amount)
    else
        -- Offline creator: the premium is owed, not lost.
        Storage.queuePending(contract.creator_cid, contractId, 'premium:' .. contractId)
    end

    Audit.financial('bailout_settled', targetCid, contractId, { amount = amount })
    Notify.toCitizen(contract.creator_cid, 'Contract closed',
        'Your target bought out the contract. Escrow and premium have been returned.')

    queued[contractId] = nil
    return true
end

--- Process queued buyouts whose delay has elapsed. Driven by the main tick.
function Bailout.processQueue()
    local settled = 0
    for contractId, entry in pairs(queued) do
        if os.time() - entry.at >= Config.Bailout.ProcessingDelaySeconds then
            if Bailout.settle(contractId, entry.amount, entry.targetCid) then
                settled = settled + 1
            end
        end
    end
    return settled
end

function Bailout.queuedCount()
    local n = 0
    for _ in pairs(queued) do n = n + 1 end
    return n
end

return Bailout
