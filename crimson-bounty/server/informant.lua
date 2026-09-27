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

--- Reroll locks older than this were aged by a staff timer refresh. A record
--- read back from the store after that refresh is aged the same way.
local locksAgedAt = nil

function Informant.init(deps)
    Storage, Identity, Audit = deps.storage, deps.identity, deps.audit
    Death = deps.death
    reveals = {}
    locksAgedAt = nil
end

--- The buyer's record, from memory or from the store.
---
--- The store is the authority: this record is the reroll lock and the
--- purchase count, and a restart that forgot them made the next purchase
--- charge the fee again for the same name and count the ceiling from zero —
--- on the one purchase in the resource that is never refunded.
local function recordFor(contractId, cid)
    local key = contractId .. ':' .. cid
    if reveals[key] then return reveals[key] end
    if not (Storage and Storage.readReveal) then return nil end

    local stored = Storage.readReveal(contractId, cid)
    if not stored then return nil end

    local at = tonumber(stored.revealed_at) or 0
    if locksAgedAt and at <= locksAgedAt then
        at = os.time() - ((Config.Informant.RerollLockMinutes or 0) * 60 + 1)
    end
    reveals[key] = {
        hunterCid = stored.hunter_cid, at = at,
        purchases = tonumber(stored.purchases) or 0, seed = tonumber(stored.seed),
    }
    return reveals[key]
end

local function remember(contractId, cid, record)
    reveals[contractId .. ':' .. cid] = record
    if Storage and Storage.writeReveal then
        Storage.writeReveal(contractId, cid, {
            hunter_cid = record.hunterCid, revealed_at = record.at,
            purchases = record.purchases, seed = record.seed,
        })
    end
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

    -- A creator already sees every operative who chose to be named, in the
    -- roster on their own card. Drawing one of those spent a purchase that is
    -- never refunded — one of only MaxPurchasesPerContract — on a name that
    -- was already on their screen, while the anonymous operative the purchase
    -- exists to unmask (§6.1, §14.29) stayed hidden. The target sees no
    -- roster at all, so for them every operative is unknown.
    local buyerSeesNamed = contract.creator_cid == actor.cid

    local out = {}
    for i = 1, #hunters do
        local h = hunters[i]
        if h.state == 'active' and (not near or near[h.hunter_cid])
            and not (buyerSeesNamed and not h.anon) then
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

    -- A contract that is over has nobody tracking anybody.
    --
    -- Checked here, before the charge, because this is the one purchase in
    -- the resource that is deliberately never refunded: an empty result costs
    -- the premium on purpose (§14.29), so that the fee cannot become a free
    -- oracle for "is anyone hunting me?". That makes a missing state check
    -- more expensive here than anywhere else — a tap on a card that had not
    -- been redrawn yet took the money for information about a contract that
    -- no longer existed, and nothing gave it back.
    if CB.TERMINAL[contract.state] then return false, CB.ERR.ALREADY_SETTLED end

    local existing = recordFor(contractId, actor.cid)

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
        remember(contractId, actor.cid, { hunterCid = nil, at = os.time(),
                         purchases = purchases + 1, seed = existing and existing.seed })
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

    remember(contractId, actor.cid, { hunterCid = chosen.hunter_cid, at = os.time(),
                     purchases = purchases + 1, seed = seed })
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
--- Age every reroll lock past its window, for the staff timer refresh.
---
--- The lock only, never the purchase count: the count is a limit on how
--- many hunters a fee can uncover, not a wait, and clearing it would turn
--- the refresh into a way to buy the whole roster.
---@return integer aged
function Informant.expireRerollLocks()
    local window = (Config.Informant.RerollLockMinutes or 0) * 60
    local aged = 0
    -- Records still only in the store are aged as they are read back.
    locksAgedAt = os.time()
    for key, reveal in pairs(reveals) do
        reveal.at = os.time() - (window + 1)
        local contractId, cid = key:match('^([^:]+):(.+)$')
        if contractId then remember(contractId, cid, reveal) end
        aged = aged + 1
    end
    return aged
end

--- Nothing is released when a player disconnects.
---
--- This used to delete the buyer's reveal record, which is the record that
--- carries both the reroll lock and the purchase count. So a relog was a free
--- reset of both: the next purchase found no record, skipped the sticky early
--- return that makes a repeat purchase free, charged the fee again for the same
--- name — and counted purchases from zero, so the ceiling on how many hunters
--- one contract's fees may uncover was bypassed by rejoining. On the one
--- purchase in the resource that is never refunded.
---
--- RateLimit.clear already refuses to reset on disconnect for exactly this
--- reason. Clearing on the REVEALED hunter's disconnect bought nothing either:
--- describe() already answers "Unknown operative" for a hunter who has gone
--- offline since they were seen.
---
--- Nothing accumulates without it: reveals are keyed to a contract and
--- released by clearContract the moment the contract resolves.
---@return boolean false, always
function Informant.clearPlayer(cid)
    local _ = cid
    return false
end

function Informant.clearContract(contractId)
    for key in pairs(reveals) do
        if key:sub(1, #contractId + 1) == contractId .. ':' then reveals[key] = nil end
    end
    if Storage and Storage.clearReveals then Storage.clearReveals(contractId) end
end

return Informant
