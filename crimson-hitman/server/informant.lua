--- Counter-Intelligence — Buy Informant Data (§6.1, §14.29).
---
--- Unmasks one hitman currently tracking the buyer. Selection happens
--- server-side, the response is uniform whether or not a name was found, and
--- the reveal is sticky so repeat purchases cannot enumerate the roster.

local Util = CrimsonBoot.requireShared('util')

local Informant = {}

local Storage, Identity, Audit, Death, Contracts

--- [contractId .. ':' .. buyerCid] = { hitmanCid, at, purchases }
local reveals = {}

--- Reroll locks older than this were aged by a staff timer refresh. A record
--- read back from the store after that refresh is aged the same way.
local locksAgedAt = nil

--- os.time() this process started: the condition sampler's record of who
--- has been near a target (Death.seenNear) starts empty here.
local startedAt = nil

function Informant.init(deps)
    Storage, Identity, Audit = deps.storage, deps.identity, deps.audit
    Death = deps.death
    -- For one purchase at a time per buyer and contract (Informant.buy).
    Contracts = deps.contracts
    reveals = {}
    locksAgedAt = nil
    startedAt = os.time()
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
    -- The answer given at the time, kept with the reveal. Kept in memory
    -- only, a restart inside the reroll lock turned the free repeat back
    -- into a fresh look at who was online.
    local answer
    if type(stored.answer) == 'table' then
        answer = stored.answer
    elseif type(stored.answer) == 'string' and stored.answer ~= '' then
        local ok, decoded = pcall(json.decode, stored.answer)
        if ok and type(decoded) == 'table' then answer = decoded end
    end
    reveals[key] = {
        hitmanCid = stored.hitman_cid, at = at,
        purchases = tonumber(stored.purchases) or 0, seed = tonumber(stored.seed),
        answer = answer,
    }
    return reveals[key]
end

local function remember(contractId, cid, record)
    reveals[contractId .. ':' .. cid] = record
    if Storage and Storage.writeReveal then
        Storage.writeReveal(contractId, cid, {
            hitman_cid = record.hitmanCid, revealed_at = record.at,
            purchases = record.purchases, seed = record.seed,
            answer = type(record.answer) == 'table' and json.encode(record.answer) or nil,
        })
    end
end

--- Remember a purchase that has been paid for, and answer it whatever the
--- store does. The buyer has been charged by now, and this is the one
--- purchase never refunded: a write that raised answered server_error for
--- a name already paid for. Kept in memory all the same (remember sets it
--- first), so a repeat inside the lock is free on this process; recorded
--- for staff, since a restart forgets it.
local function rememberPaid(contractId, cid, record)
    local wrote, err = pcall(remember, contractId, cid, record)
    if not wrote then
        Audit.financial('informant_unremembered', cid, contractId, { error = tostring(err) })
    end
end

--- Who may buy data on a contract: its creator, or its target.
local function authorised(contract, actor)
    return contract.creator_cid == actor.cid or contract.target_cid == actor.cid
end

--- Hitmen eligible to be revealed.
---
--- A hitman who accepted and has done nothing is not tracking anyone. The
--- pool is those the server has actually seen near the target recently
--- (§6.1) — observed by the condition sampler, never claimed by anybody —
--- so the purchase names someone who is genuinely on you rather than
--- dumping the roster of everyone who pressed accept.
---
--- With the requirement switched off the pool is every active hitman, which
--- is what this did before and is left available for servers that prefer it.
local function pool(contract, actor)
    local hitmen = Storage.readHitmen(contract.id)
    local near = Config.Informant.RequireProximity and Death and Death.seenNear(contract.id)

    -- A creator already sees every operative who chose to be named, in the
    -- roster on their own card. Drawing one of those spent a purchase that is
    -- never refunded — one of only MaxPurchasesPerContract — on a name that
    -- was already on their screen, while the anonymous operative the purchase
    -- exists to unmask (§6.1, §14.29) stayed hidden. The target sees no
    -- roster at all, so for them every operative is unknown.
    local buyerSeesNamed = contract.creator_cid == actor.cid

    -- And only one the server can describe now. A hitman seen near the
    -- target who has since left the city is answered "Unknown operative"
    -- (describe), and landing on one paid the fee for that while another
    -- seen one was online. Leaving them out says nothing new: with only
    -- offline ones the answer is that same "Unknown operative".
    local out = {}
    for i = 1, #hitmen do
        local h = hitmen[i]
        if h.state == 'active' and (not near or near[h.hitman_cid])
            and not (buyerSeesNamed and not h.anon)
            and Identity.byCitizenId(h.hitman_cid) ~= nil then
            out[#out + 1] = h
        end
    end
    return out
end

--- Seconds until the sampler has watched for a whole window since this
--- process started, while the pool is the hitmen it has seen; 0 otherwise.
---
--- Its record is kept in memory only, so a restart forgets who had been
--- near the target, and a purchase in the window after it paid the fee for
--- "Unknown operative", locked in for the reroll lock. Refused uncharged
--- instead, on a contract that was already placed when this process
--- started: one placed since has had every acceptance on it watched from
--- the start. Never by who has been seen: a refusal only when nobody had
--- been near would tell any buyer, for nothing, what the purchase sells.
---@param contract table
---@return integer seconds
local function warming(contract)
    if not Config.Informant.RequireProximity or not startedAt then return 0 end
    if (tonumber(contract.created_at) or 0) >= startedAt then return 0 end
    local window = (tonumber(Config.Informant.ProximityWindowMinutes) or 10) * 60
    return math.max(0, startedAt + window - os.time())
end

local buyUnlocked

--- Buy informant data, one purchase at a time per buyer and contract.
---
--- The record that makes a repeat free is read, then the fee taken, then
--- the record written, and every read is an await on mysql: a second tap
--- landing in between found no record and was charged again for the same
--- sticky reveal, counted once. A second purchase while one is running is
--- refused as busy, before anything is read or charged.
---@return boolean ok
---@return string|nil err
---@return table|nil data
function Informant.buy(actor, contractId)
    contractId = Util.toId(contractId)
    if not contractId then return false, CH.ERR.INVALID_INPUT end
    -- Turned off, from the admin panel or config.lua: new purchases only.
    -- A name already bought stays shown.
    if not Config.Informant.Enabled then return false, CH.ERR.FEATURE_OFF end
    -- Unkeyed only where no contracts module was wired in (Informant.init).
    if not Contracts then return buyUnlocked(actor, contractId) end
    return Contracts.serialized({ 'informant:' .. contractId .. ':' .. tostring(actor.cid) },
        buyUnlocked, actor, contractId)
end

buyUnlocked = function(actor, contractId)
    local contract = Storage.readContract(contractId)
    if not contract then return false, CH.ERR.NOT_FOUND end
    if not authorised(contract, actor) then return false, CH.ERR.NOT_PARTICIPANT end

    -- A contract that is over has nobody tracking anybody.
    --
    -- Checked here, before the charge, because this is the one purchase in
    -- the resource that is deliberately never refunded: an empty result costs
    -- the premium on purpose (§14.29), so that the fee cannot become a free
    -- oracle for "is anyone after me?". That makes a missing state check
    -- more expensive here than anywhere else — a tap on a card that had not
    -- been redrawn yet took the money for information about a contract that
    -- no longer existed, and nothing gave it back.
    if CH.TERMINAL[contract.state] then return false, CH.ERR.ALREADY_SETTLED end

    local existing = recordFor(contractId, actor.cid)

    -- A sticky reveal: buying again inside the lock returns the same name
    -- rather than rolling for another, so the purchase cannot be used to
    -- enumerate every hitman for a fee.
    if existing and (os.time() - existing.at) < (Config.Informant.RerollLockMinutes * 60) then
        -- The answer given when they were revealed, not a fresh look. Asked
        -- again, it said whether that hitman was online right now — free,
        -- every few minutes, for the whole lock: a presence oracle on an
        -- anonymous hitman. After a restart the lock has run out (locksAgedAt),
        -- so nothing needs this across one.
        return true, nil, existing.answer or Informant.describe(existing.hitmanCid)
    end

    local purchases = existing and existing.purchases or 0
    if purchases >= Config.Informant.MaxPurchasesPerContract then
        return false, CH.ERR.LIMIT_REACHED
    end

    -- Just after a restart, nothing is sold that the restart made worthless.
    local wait = warming(contract)
    if wait > 0 then
        return false, CH.ERR.INFORMANT_WARMING, { minutes = math.ceil(wait / 60) }
    end

    -- Who could be named, before anything is charged: the read is an await
    -- on mysql and raises on a dropped connection, and one that raised after
    -- the charge kept the fee with nothing recorded for it, so every retry
    -- was charged again.
    local candidates = pool(contract, actor)

    -- And the contract read again, with nothing between this and the
    -- charge. The state checked above was read before every await since,
    -- and a contract that ended in one of them was still sold. Only an open
    -- one, as for a buyout: a contract being paid out (COMPLETING) is
    -- ending too.
    local now = Storage.readContract(contractId)
    if not now or (now.state ~= CH.STATE.ACTIVE and now.state ~= CH.STATE.ACCEPTED) then
        return false, CH.ERR.ALREADY_SETTLED
    end

    local cost = Config.Informant.Cost
    local account = Config.Informant.Account
    -- Balance read first: RemoveMoney answers true on an empty bank, which
    -- is the account this ships pointed at.
    if not Util.charge(actor.player, account, cost) then
        return false, CH.ERR.INSUFFICIENT
    end
    Audit.financial('informant_purchased', actor.cid, contractId, { cost = cost })

    if #candidates == 0 then
        -- Charged anyway, and deliberately: a refund on an empty result turns
        -- the purchase into a free oracle for "is anyone after me?".
        --
        -- And answered in the same words as a hitman the server has no
        -- current description for, rather than with a distinct "nothing
        -- found" reply. Charging either way is only half of §14.29: the
        -- other half is that the ANSWER must not distinguish the two, or the
        -- premium buys a target a reliable server-side yes/no on whether an
        -- anonymous operative is on them right now — which is the paid
        -- oracle the charge was there to prevent.
        local answer = Informant.describe(nil)
        rememberPaid(contractId, actor.cid, { hitmanCid = nil, at = os.time(),
                         purchases = purchases + 1, seed = existing and existing.seed, answer = answer })
        Audit.action('informant_revealed', actor.cid, contractId, { hitman = nil })
        return true, nil, answer
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

    -- Not the one already named, while there is anybody else: a second
    -- purchase that named the same hitman again was paid for nothing, and
    -- left the other hidden.
    if existing and existing.hitmanCid and #candidates > 1 then
        local others = {}
        for _, h in ipairs(candidates) do
            if h.hitman_cid ~= existing.hitmanCid then others[#others + 1] = h end
        end
        if #others > 0 then candidates = others end
    end

    local index = ((seed + purchases) % #candidates) + 1
    local chosen = candidates[index]

    local answer = Informant.describe(chosen.hitman_cid)
    rememberPaid(contractId, actor.cid, { hitmanCid = chosen.hitman_cid, at = os.time(),
                     purchases = purchases + 1, seed = seed, answer = answer })
    Audit.action('informant_revealed', actor.cid, contractId, { hitman = chosen.hitman_cid })

    return true, nil, answer
end

--- The answer this buyer was last given on this contract, for their card.
---
--- The stored answer, never a fresh look, so carrying it on every read says
--- nothing the purchase did not already say: it is not the presence oracle a
--- free re-ask would be. The paid answer used to exist only in a notice that
--- cleared itself after four seconds, and a buyer who looked away had paid
--- the premium for a name they could no longer read.
---
--- Only inside the reroll lock, the window in which buying again gives the
--- same answer anyway. Kept on the card for the contract's life, it went on
--- reading "Informant: <name>" long after that operative had walked away
--- and somebody else had taken it, and a target acting on it watched the
--- wrong person. Bounded by time alone: asking whether that hitman is still
--- on it would make the card a free presence and departure oracle.
---@return table|nil answer { name } or { description }
function Informant.answerFor(contractId, cid)
    local record = recordFor(contractId, cid)
    if not record then return nil end
    if (os.time() - record.at) >= (Config.Informant.RerollLockMinutes or 0) * 60 then
        return nil
    end
    return record.answer
end

--- What the buyer is shown.
---
--- One shape, whatever happened. There is no `found` flag on the wire: the
--- answer for "nobody the informant could reach" is the same answer as for
--- "somebody, whom the server cannot currently describe" — a hitman who has
--- gone offline since they were seen produces it too. So the reply carries
--- no reliable signal about whether anyone has accepted, which is what
--- §14.29 asks of it, and the app has one branch to render rather than two.
---
--- Not a fabricated name: naming somebody who is not there would be a worse
--- answer than an unhelpful one, because a target would act on it.
---
--- A citizen id is never returned in either mode — it is an internal key,
--- not something a player should be handed.
function Informant.describe(hitmanCid)
    local actor = hitmanCid and Identity.byCitizenId(hitmanCid)

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
--- many hitmen a fee can uncover, not a wait, and clearing it would turn
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
--- name — and counted purchases from zero, so the ceiling on how many hitmen
--- one contract's fees may uncover was bypassed by rejoining. On the one
--- purchase in the resource that is never refunded.
---
--- RateLimit.clear already refuses to reset on disconnect for exactly this
--- reason. Clearing on the REVEALED hitman's disconnect bought nothing either:
--- describe() already answers "Unknown operative" for a hitman who has gone
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
