--- Proof items (Config.Improvements.ProofItems, README, Optional
--- features). Off as shipped, and off it changes nothing.
---
--- On, a hitman may finish a contract a kill completes (Fulfilment 'either')
--- by handing the person who placed it an item taken from the target: an
--- ox_inventory item (Item, 'id_card' as shipped) whose metadata field
--- (MetadataKey, 'citizenid' as shipped, as qbx_idcard writes it) names the
--- target. The hitman taps Hand over proof standing beside the placer.
---
--- Everything is read on the server: the contract and the hitman's place on
--- it, where both players stand (within HandoverRadius of each other, from
--- their peds), and the item in the hitman's own inventory with the
--- target's citizen id in its metadata. Nothing the page sends but the
--- contract's id is used. An anonymous placer who is not in the city is
--- refused exactly as one standing too far away, so the hitman learns
--- nothing about whether they are online.
---
--- The item is taken first (the hitman's side of the exchange), then the
--- payout is claimed as a verified kill is (Contracts.claimSlot, as an
--- elimination), recorded as its own outcome (CH.FULFILMENT.PROOF): no EMS
--- re-listing, witness report or city news, and the Ledger says proof. A
--- claim refused gives the item back, exactly as it was
--- taken; the item is used up only by a payout, so one id card never pays
--- two collections. With ox_inventory not started the feature does nothing.

local Util = CrimsonBoot.requireShared('util')
local Holds = CrimsonBoot.require('server.holds')
local Bridge = CrimsonBoot.require('server.lib.bridge')
local Geo = CrimsonBoot.requireShared('geo')
local Log = CrimsonBoot.requireShared('log')
local Feature = CrimsonBoot.require('server.lib.feature')

--- This feature's block of config (server/lib/feature.lua reads and checks it).
local BLOCK = 'Improvements.ProofItems'

local Proof = {}

local deps

--- One handover per contract and hitman at a time.
local working = {}

function Proof.init(d)
    deps = d
    working = {}
end

Proof.RULES = {
    Enabled = { kind = 'switch', default = false },
    Item = { kind = 'text', default = 'id_card' },
    MetadataKey = { kind = 'text', default = 'citizenid' },
    HandoverRadius = { kind = 'number', min = 1, max = 50, default = 3.0 },
}

---@param warn string[]
function Proof.validate(warn)
    Feature.check(BLOCK, Proof.RULES, warn)
end

--- What the page is told: nothing while it is off, else the item's name and
--- the distance, for the button and its words.
---@return table|nil
function Proof.forPage()
    if not Feature.on(BLOCK) then return nil end
    return { item = tostring(Feature.block(BLOCK).Item or 'id_card'),
             radius = tonumber(Feature.block(BLOCK).HandoverRadius) or 3.0 }
end

--- A player's routing bucket, or nil when the server cannot say: nil is
--- never anybody's bucket, so an unanswered read refuses (as the kidnap
--- handover's does, server/completion/kidnap.lua).
local function bucketOf(src)
    local ok, bucket = pcall(GetPlayerRoutingBucket, src)
    return ok and tonumber(bucket) or nil
end

--- The slot holding an item that names the target, or nil. Searched by the
--- metadata value (ox_inventory's Search), then each slot's field checked
--- here as well: Search matches by value, not by key.
---@return table|nil slot
---@return boolean read false when the inventory could not be read
local function proofSlot(actor, item, key, targetCid)
    local ok, slots = Bridge.call('ox_inventory', 'Search', actor.source, 'slots', item, { [key] = targetCid })
    if not ok then return nil, false end
    for _, slot in pairs(type(slots) == 'table' and slots or {}) do
        if type(slot) == 'table' and type(slot.metadata) == 'table'
            and slot.metadata[key] == targetCid and (tonumber(slot.count) or 1) >= 1 then
            return slot, true
        end
    end
    return nil, true
end

--- Give the item back after a claim that did not pay. Audited either way.
local function giveBack(actor, contractId, item, slot, why)
    local ok, gave = Bridge.call('ox_inventory', 'AddItem', actor.source, item, 1, slot.metadata)
    if ok and gave then
        deps.audit.action('proof_item_returned', actor.cid, contractId, { item = item, reason = why })
    else
        deps.audit.financial('proof_item_not_returned', actor.cid, contractId,
            { item = item, reason = why })
        Log.always(('a proof item (%s) taken for contract %s could not be given back after the '
            .. 'claim was refused (%s)'):format(item, tostring(contractId), tostring(why)))
    end
end

--- Hand over the proof item and claim the next payout.
---@param actor table resolved from the event source
---@param rawId any the contract
---@return boolean ok
---@return string|nil err
---@return table|nil result the claim's own answer
function Proof.handover(actor, rawId)
    if not Feature.on(BLOCK) then return false, CH.ERR.FEATURE_OFF end
    if not Bridge.started('ox_inventory') then return false, CH.ERR.FEATURE_OFF end
    local contractId = Util.toId(rawId)
    if not contractId then return false, CH.ERR.INVALID_INPUT end

    local Storage, Contracts = deps.storage, deps.contracts
    local contract = Storage.readContract(contractId)
    if not contract then return false, CH.ERR.NOT_FOUND end
    local hitman = Storage.readHitman(contractId, actor.cid)
    if not hitman or hitman.state ~= 'active' then return false, CH.ERR.NOT_PARTICIPANT end
    if contract.state ~= CH.STATE.ACCEPTED then return false, CH.ERR.BAD_STATE end
    -- Only where a kill completes it: a contract placed for a live delivery
    -- is never paid for anything else (Contracts.claimSlot says so too).
    if Util.fulfilmentRule(contract) == CH.FULFILMENT_RULE.ALIVE then
        return false, CH.ERR.KILL_NOT_ALLOWED
    end
    if Holds.on(contract, nil, 'staff') then return false, CH.ERR.CONTRACT_FROZEN end
    -- On hold for the restart, or the whole app paused: the claim below
    -- would be refused anyway, so the item is never taken to be given back.
    if Holds.on(nil, nil, 'restart') then return false, CH.ERR.RESTART_HOLD end
    if Holds.on(nil, nil, 'app') then return false, CH.ERR.APP_PAUSED end
    if Contracts.slotCoolingDown(hitman) then return false, CH.ERR.SLOT_COOLDOWN end

    -- The item first, before anybody's whereabouts are looked at: a hitman
    -- without the card is told only that, whoever stands beside them, so
    -- the answer can never be used to find out who the placer is or
    -- whether they are online (too far for the placer, missing for anyone).
    local item = tostring(Feature.block(BLOCK).Item or 'id_card')
    local key = tostring(Feature.block(BLOCK).MetadataKey or 'citizenid')
    local slot, read = proofSlot(actor, item, key, contract.target_cid)
    if not read then return false, CH.ERR.FEATURE_OFF end
    if not slot then return false, CH.ERR.PROOF_MISSING end

    -- Beside the placer, by where the server sees both, in one routing
    -- bucket: two players in two apartment shells stand at the same
    -- coordinates and are nowhere near each other. An anonymous placer away
    -- from the city, or in another instance, reads as one too far away.
    local radius = tonumber(Feature.block(BLOCK).HandoverRadius) or 3.0
    local creator = deps.identity.byCitizenId(contract.creator_cid)
    local bucket = bucketOf(actor.source)
    local together = creator ~= nil and bucket ~= nil and bucketOf(creator.source) == bucket
    local here = together and Geo.position(actor.source)
    local there = together and Geo.position(creator.source)
    if not here or not there or Geo.dist2(here, there) > radius * radius then
        return false, CH.ERR.PROOF_TOO_FAR, { radius = radius }
    end

    local busy = contractId .. ':' .. actor.cid
    if working[busy] then return false, CH.ERR.BUSY end
    working[busy] = true

    -- The hitman's side first: the very slot found above, by its metadata.
    local took, removed = Bridge.call('ox_inventory', 'RemoveItem', actor.source, item, 1, slot.metadata, slot.slot)
    if not took or not removed then
        working[busy] = nil
        deps.audit.rejected('proof_item_not_taken', actor.cid, contractId, { item = item })
        return false, CH.ERR.PROOF_MISSING
    end

    -- Paid as an elimination, recorded as what it is (CH.FULFILMENT.PROOF):
    -- a card handed over, not a kill anybody saw, so what runs after the
    -- claim (EMS re-listing, the witness report, city news) does not take
    -- it for one, and the Ledger says proof.
    local ran, ok, err, result = pcall(Contracts.claimSlot, contractId, actor.cid,
        CH.FULFILMENT.ELIMINATION, { outcome = CH.FULFILMENT.PROOF })
    working[busy] = nil
    if not ran then
        -- The maintenance tick finishes a claim that raised
        -- (Contracts.retryStuckClaims); the item stays spent on it.
        deps.audit.financial('proof_item_claim_raised', actor.cid, contractId, { item = item })
        error(ok, 0)
    end
    if not ok then
        giveBack(actor, contractId, item, slot, err)
        deps.audit.rejected('proof_item_claim_failed', actor.cid, contractId, { reason = err })
        return false, err, result
    end

    deps.audit.financial('proof_item_completed', actor.cid, contractId,
        { item = item, slot = result and result.slot })
    local readOk, now = pcall(Storage.readContract, contractId)
    local after = readOk and now or contract
    local wrote, ledgerErr = pcall(deps.ledger.record, after, actor.cid, nil,
        CH.FULFILMENT.PROOF, result)
    if not wrote then
        pcall(deps.audit.financial, 'ledger_write_failed', actor.cid, contractId,
            { error = tostring(ledgerErr) })
        Log.always(('contract %s was paid by a proof item, and writing its ledger rows raised: %s')
            :format(tostring(contractId), Util.dbError(ledgerErr)))
    end
    local told, tellErr = pcall(deps.notify.contractCompleted, after, actor.cid, { item = true }, result,
        { receipt = true })
    if not told then
        Log.debug(('telling the placer contract %s was fulfilled raised: %s')
            :format(tostring(contractId), Util.dbError(tellErr)))
    end
    return true, nil, result
end

return Proof
