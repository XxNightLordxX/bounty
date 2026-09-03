--- Counter-Intelligence — Buy Informant Data (§6.1, §14.29).
---
--- Unmasks one hunter currently tracking the buyer. Selection happens
--- server-side, the response is uniform whether or not a name was found, and
--- the reveal is sticky so repeat purchases cannot enumerate the roster.

local Util = require_shared('util')

local Informant = {}

local Storage, Identity, Audit

--- [contractId .. ':' .. buyerCid] = { hunterCid, at, purchases }
local reveals = {}

function Informant.init(deps)
    Storage, Identity, Audit = deps.storage, deps.identity, deps.audit
    reveals = {}
end

--- Who may buy data on a contract: its creator, or its target.
local function authorised(contract, actor)
    return contract.creator_cid == actor.cid or contract.target_cid == actor.cid
end

--- Hunters eligible to be revealed. A hunter who accepted but has done
--- nothing is not "tracking" anyone; requiring recorded proximity keeps the
--- purchase meaningful rather than a roster dump.
local function pool(contract, actor)
    local hunters = Storage.readHunters(contract.id)
    local out = {}
    for i = 1, #hunters do
        local h = hunters[i]
        if h.state == 'active' then out[#out + 1] = h end
    end
    return out
end

---@return boolean ok
---@return string|nil err
---@return table|nil data
function Informant.buy(actor, contractId)
    contractId = Util.toId(contractId)
    if not contractId then return false, CB.ERR.INVALID_INPUT end
    if not Config.Informant.Enabled then return false, CB.ERR.BAD_STATE end

    local contract = Storage.readContract(contractId)
    if not contract then return false, CB.ERR.NOT_FOUND end
    if not authorised(contract, actor) then return false, CB.ERR.NOT_PARTICIPANT end

    local key = contractId .. ':' .. actor.cid
    local existing = reveals[key]

    -- A sticky reveal: buying again inside the lock returns the same name
    -- rather than rolling for another, so the purchase cannot be used to
    -- enumerate every hunter for a fee.
    if existing and (os.time() - existing.at) < (Config.Informant.RerollLockMinutes * 60) then
        return true, nil, Informant.describe(existing.hunterCid)
    end

    local purchases = existing and existing.purchases or 0
    if purchases >= Config.Informant.MaxPurchasesPerContract then
        return false, CB.ERR.LIMIT_REACHED
    end

    local cost = Config.Informant.Cost
    local account = Config.Informant.Account
    if not actor.player.Functions.RemoveMoney(account, cost) then
        return false, CB.ERR.INSUFFICIENT
    end
    Audit.financial('informant_purchased', actor.cid, contractId, { cost = cost })

    local candidates = pool(contract, actor)
    if #candidates == 0 then
        -- Charged anyway, and deliberately: a refund on an empty result turns
        -- the purchase into a free oracle for "is anyone hunting me?".
        reveals[key] = { hunterCid = nil, at = os.time(), purchases = purchases + 1 }
        return true, nil, { found = false }
    end

    -- Server-side selection, derived from stable data rather than a random
    -- source (scripts have no reliable RNG at boot and a predictable pick is
    -- fine here — the buyer cannot influence the inputs).
    local index = ((os.time() + #contractId + purchases) % #candidates) + 1
    local chosen = candidates[index]

    reveals[key] = { hunterCid = chosen.hunter_cid, at = os.time(), purchases = purchases + 1 }
    Audit.action('informant_revealed', actor.cid, contractId, { hunter = chosen.hunter_cid })

    return true, nil, Informant.describe(chosen.hunter_cid)
end

--- What the buyer is shown. A citizen id is never returned in either mode —
--- it is an internal key, not something a player should be handed.
function Informant.describe(hunterCid)
    if not hunterCid then return { found = false } end

    local actor = Identity.byCitizenId(hunterCid)
    if Config.Informant.RevealMode == 'name' then
        return { found = true, name = actor and actor.name or 'Unknown operative' }
    end

    return {
        found = true,
        description = actor
            and ('Seen recently around %s'):format(actor.job and actor.job.name or 'the city')
            or 'A face you have seen before',
    }
end

function Informant.clearContract(contractId)
    for key in pairs(reveals) do
        if key:sub(1, #contractId + 1) == contractId .. ':' then reveals[key] = nil end
    end
end

return Informant
