--- Counter-Intelligence — Buy Informant Data (§6.1, §14.29).
---
--- Unmasks one hunter currently tracking the buyer. Selection happens
--- server-side, the response is uniform whether or not a name was found, and
--- the reveal is sticky so repeat purchases cannot enumerate the roster.

local Util = require_shared('util')

local Informant = {}

local Storage, Identity, Audit, Death

--- [contractId .. ':' .. buyerCid] = { hunterCid, at, purchases }
local reveals = {}

function Informant.init(deps)
    Storage, Identity, Audit = deps.storage, deps.identity, deps.audit
    Death = deps.death
    reveals = {}
end

--- Who may buy data on a contract: its creator, or its target.
local function authorised(contract, actor)
    return contract.creator_cid == actor.cid or contract.target_cid == actor.cid
end

--- Hunters eligible to be revealed.
---
--- A hunter who accepted and has done nothing is not tracking anyone. The
--- pool is those the server has actually seen near the target recently
--- (§6.1) — observed by the condition sampler, never claimed by anybody —
--- so the purchase names someone who is genuinely on you rather than
--- dumping the roster of everyone who pressed accept.
---
--- With the requirement switched off the pool is every active hunter, which
--- is what this did before and is left available for servers that prefer it.
local function pool(contract, actor)
    local hunters = Storage.readHunters(contract.id)
    local near = Config.Informant.RequireProximity and Death and Death.seenNear(contract.id)

    local out = {}
    for i = 1, #hunters do
        local h = hunters[i]
        if h.state == 'active' and (not near or near[h.hunter_cid]) then
            out[#out + 1] = h
        end
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
    -- Balance read first: RemoveMoney answers true on an empty bank, which
    -- is the account this ships pointed at.
    if not Util.charge(actor.player, account, cost) then
        return false, CB.ERR.INSUFFICIENT
    end
    Audit.financial('informant_purchased', actor.cid, contractId, { cost = cost })

    local candidates = pool(contract, actor)
    if #candidates == 0 then
        -- Charged anyway, and deliberately: a refund on an empty result turns
        -- the purchase into a free oracle for "is anyone hunting me?".
        --
        -- And answered in the same words as a hunter the server has no
        -- current description for, rather than with a distinct "nothing
        -- found" reply. Charging either way is only half of §14.29: the
        -- other half is that the ANSWER must not distinguish the two, or the
        -- premium buys a target a reliable server-side yes/no on whether an
        -- anonymous operative is on them right now — which is the paid
        -- oracle the charge was there to prevent.
        reveals[key] = { hunterCid = nil, at = os.time(),
                         purchases = purchases + 1, seed = existing and existing.seed }
        Audit.action('informant_revealed', actor.cid, contractId, { hunter = nil })
        return true, nil, Informant.describe(nil)
    end

    -- Selection must not be steerable. A wall clock in the formula lets the
    -- buyer pick the second they press buy and walk the roster; the seed is
    -- instead fixed per (contract, buyer) on first purchase, so a second
    -- purchase moves on deterministically rather than to a chosen target.
    local seed = existing and existing.seed
    if not seed then
        seed = 0
        for i = 1, #contractId do seed = seed + contractId:byte(i) * i end
        for i = 1, #actor.cid do seed = seed + actor.cid:byte(i) * (i * 7) end
    end

    local index = ((seed + purchases) % #candidates) + 1
    local chosen = candidates[index]

    reveals[key] = { hunterCid = chosen.hunter_cid, at = os.time(),
                     purchases = purchases + 1, seed = seed }
    Audit.action('informant_revealed', actor.cid, contractId, { hunter = chosen.hunter_cid })

    return true, nil, Informant.describe(chosen.hunter_cid)
end

--- What the buyer is shown.
---
--- One shape, whatever happened. There is no `found` flag on the wire: the
--- answer for "nobody the informant could reach" is the same answer as for
--- "somebody, whom the server cannot currently describe" — a hunter who has
--- gone offline since they were seen produces it too. So the reply carries
--- no reliable signal about whether anyone has accepted, which is what
--- §14.29 asks of it, and the app has one branch to render rather than two.
---
--- Not a fabricated name: naming somebody who is not there would be a worse
--- answer than an unhelpful one, because a target would act on it.
---
--- A citizen id is never returned in either mode — it is an internal key,
--- not something a player should be handed.
function Informant.describe(hunterCid)
    local actor = hunterCid and Identity.byCitizenId(hunterCid)

    if Config.Informant.RevealMode == 'name' then
        return { name = actor and actor.name or 'Unknown operative' }
    end

    return {
        description = actor
            and ('Seen recently around %s'):format(actor.job and actor.job.name or 'the city')
            or 'A face you have seen before',
    }
end

--- Release a player's reveals when they disconnect.
function Informant.clearPlayer(cid)
    for key, entry in pairs(reveals) do
        if key:find(':' .. cid, 1, true) or entry.hunterCid == cid then reveals[key] = nil end
    end
end

function Informant.clearContract(contractId)
    for key in pairs(reveals) do
        if key:sub(1, #contractId + 1) == contractId .. ':' then reveals[key] = nil end
    end
end

return Informant
