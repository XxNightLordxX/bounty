--- Counter-Intelligence — the two informants (§6.1, §14.29).
---
--- The target's (Config.Informant): a target picks one operative on a
--- contract on them, or the person who placed it, and pays for one look-up.
--- The placer's (Config.PlacerInformant): the person who placed a contract
--- picks one of the operatives who took it, and pays for one look-up.
---
--- Both are a gamble, and say so: the price is paid whatever the look-up
--- finds. Whether it finds anything is a roll made here, on the server, with
--- a fresh number for every purchase that is never sent before the answer.
--- The pick is a handle this module minted for an operative's row on that
--- contract; which row it stands for never leaves the server.

local Util = CrimsonBoot.requireShared('util')

local Informant = {}

local Storage, Identity, Audit, Contracts, Notify, Bailout

--- The target's purchases. [contractId .. ':' .. buyerCid] = { purchases,
--- at, picks = { [hitmanCid | 'placer'] = { at, found, answer, label } } }
local reveals = {}

--- The placer's purchases, in the order they were made.
--- [contractId .. ':' .. placerCid] = { { hitman_cid, bought_at, revealed, alerted, seq } }
local placerBought = {}

--- The handles a contract's operatives are offered under.
--- [contractId] = { byCid = { [hitmanCid] = handle }, byHandle = { [handle] = hitmanCid } }
local handles = {}

--- Reroll locks older than this were aged by a staff timer refresh. A record
--- read back from the store after that refresh is aged the same way.
local locksAgedAt = nil

--- What every roll draws from. math.random, or what a test put in its place
--- (Informant.setRandom).
local random = math.random

--- The pick that names the person who placed the contract, on the target's
--- informant. Every other pick is an operative's handle.
local PLACER = 'placer'
local PLACER_LABEL = 'The person who placed it'

--- What a look-up that found nothing says, to each buyer.
local TARGET_MISS = 'Your informant could not find out who it is.'
local PLACER_MISS = 'Your informant could not find out who they are.'

--- The phone notice an operative a placer found out about may be sent.
local ALERT_TITLE = 'You have been found out'

function Informant.init(deps)
    Storage, Identity, Audit = deps.storage, deps.identity, deps.audit
    -- For one purchase at a time per buyer and contract (Contracts.serialized).
    Contracts = deps.contracts
    -- The operative's alert (Notify.tellOrKeep), and a refund that could not
    -- be handed back at once (Bailout.owe).
    Notify, Bailout = deps.notify, deps.bailout
    reveals, placerBought, handles = {}, {}, {}
    locksAgedAt = nil
end

--- Put a random source in place of math.random, for every roll from now on:
--- `fn(1, 100)` answers a whole number from 1 to 100. nil puts math.random
--- back. The test harness forces a roll each way with it.
---@param fn function|nil
function Informant.setRandom(fn)
    random = type(fn) == 'function' and fn or math.random
end

--- One roll against a chance in percent, with a fresh number.
---@param percent any
---@return boolean
local function roll(percent)
    local chance = math.floor(tonumber(percent) or 0)
    local drawn = tonumber(random(1, 100)) or 100
    return drawn <= chance
end

local function lockSeconds()
    return math.max(0, tonumber(Config.Informant.RerollLockMinutes) or 0) * 60
end

--------------------------------------------------------------------------
-- Operatives, by handle
--------------------------------------------------------------------------

--- The handle an operative's row on this contract is offered under, minted
--- the first time it is asked for and the same for the life of the process.
--- Random, so it says nothing of who the row is or when they took it.
---@param contractId string
---@param hitmanCid string
---@return string|nil
local function handleOf(contractId, hitmanCid)
    local book = handles[contractId]
    if not book then
        book = { byCid = {}, byHandle = {} }
        handles[contractId] = book
    end
    local handle = book.byCid[hitmanCid]
    if handle then return handle end
    for _ = 1, 8 do
        local candidate = Util.randomId('op')
        if not book.byHandle[candidate] then
            handle = candidate
            break
        end
    end
    if not handle then return nil end
    book.byCid[hitmanCid], book.byHandle[handle] = handle, hitmanCid
    return handle
end

--- The operative row a handle stands for on this contract, while they are
--- on it. nil for a handle this server never minted for it (forged, from
--- another contract, or from before a restart) and for one who has left.
---@param contractId string
---@param handle any
---@return table|nil row
local function operativeFor(contractId, handle)
    if type(handle) ~= 'string' or #handle > 64 then return nil end
    local book = handles[contractId]
    local cid = book and book.byHandle[handle]
    if not cid then return nil end
    local row = Storage.readHitman(contractId, cid)
    if not row or row.state ~= 'active' then return nil end
    return row
end

--- How an operative is called to a buyer: the alias the contract gave their
--- row ('Operative #1'), the same one the placer's card shows.
local function labelOf(row)
    return type(row.alias) == 'string' and row.alias or 'An operative'
end

--- What a look-up that found somebody tells the buyer, by RevealMode: a
--- name, or what the informant saw of them. A citizen id never.
---
--- The name as the contract recorded it when the operative is away: one
--- found while offline was answered "Unknown operative", for the full price.
---@param cid string|nil
---@param mode string|nil 'name' | 'description'
---@param knownName string|nil the name the contract holds for them
---@return table { name } or { description }
function Informant.describe(cid, mode, knownName)
    local actor = cid and Identity.byCitizenId(cid)
    if (mode or Config.Informant.RevealMode) == 'name' then
        return { name = (actor and actor.name) or knownName or 'Unknown operative' }
    end
    return {
        description = actor
            and ('Seen recently around %s'):format(actor.job and actor.job.name or 'the city')
            or 'A face you have seen before',
    }
end

--- The words an answer is shown in.
local function answerText(answer)
    return type(answer) == 'table' and (answer.name or answer.description) or nil
end

--- Whether a contract is still one an informant can be bought on.
local function live(contract)
    return contract ~= nil and (contract.state == CH.STATE.ACTIVE or contract.state == CH.STATE.ACCEPTED)
end

--- After the charge and before the roll: the contract still open, and the
--- operative (where there is one) still on it. The contract as read now, or
--- nil and why not.
local function stillOn(contractId, pick, row)
    local now = Storage.readContract(contractId)
    if not live(now) then return nil, CH.ERR.ALREADY_SETTLED end
    if row and not operativeFor(contractId, pick) then return nil, CH.ERR.OPERATIVE_GONE end
    return now
end

--- Give back a price taken for a look-up that was never made: the contract
--- ended, or the operative left, between the charge and the roll. Owed (and
--- handed over at the next login) where it cannot be paid now.
local function refund(actor, contractId, cost, account, action, why)
    if cost <= 0 then return end
    local credited = Util.credit(actor.player, account, cost)
    if not credited and Bailout and Bailout.owe then
        credited = Bailout.owe(actor.cid, contractId, cost, account, action) ~= nil
    end
    Audit.financial(action, actor.cid, contractId,
        { amount = cost, account = account, reason = why, owed = not credited or nil })
end

--------------------------------------------------------------------------
-- The target's informant (Config.Informant)
--------------------------------------------------------------------------

--- The picks a record carries, as stored (a JSON object in `answer`).
local function decodePicks(stored)
    local answer = stored.answer
    if type(answer) == 'string' and answer ~= '' then
        local ok, decoded = pcall(json.decode, answer)
        answer = ok and decoded or nil
    end
    local picks = {}
    if type(answer) == 'table' and type(answer.picks) == 'table' then
        for key, p in pairs(answer.picks) do
            if type(key) == 'string' and type(p) == 'table' then
                picks[key] = { at = tonumber(p.at) or 0, found = p.found == true,
                               answer = type(p.answer) == 'table' and p.answer or nil,
                               label = type(p.label) == 'string' and p.label or nil }
            end
        end
    end
    return picks
end

--- The buyer's record, from memory or from the store.
---
--- The store is the authority: it holds the purchase count, which picks
--- were found out (shown on their card), and when each was last asked, and
--- a restart that forgot them counted the cap from zero.
local function recordFor(contractId, cid)
    local key = contractId .. ':' .. cid
    if reveals[key] then return reveals[key] end
    if not (Storage and Storage.readReveal) then return nil end

    local stored = Storage.readReveal(contractId, cid)
    if not stored then return nil end

    local picks = decodePicks(stored)
    if locksAgedAt then
        for _, p in pairs(picks) do
            if p.at <= locksAgedAt then p.at = os.time() - (lockSeconds() + 1) end
        end
    end
    reveals[key] = { purchases = tonumber(stored.purchases) or 0,
                     at = tonumber(stored.revealed_at) or 0, picks = picks }
    return reveals[key]
end

local function remember(contractId, cid, record)
    reveals[contractId .. ':' .. cid] = record
    if Storage and Storage.writeReveal then
        Storage.writeReveal(contractId, cid, {
            revealed_at = record.at, purchases = record.purchases,
            answer = json.encode({ picks = record.picks }),
        })
    end
end

--- Remember a purchase that has been paid for and rolled, and answer it
--- whatever the store does: kept in memory all the same (remember sets it
--- first), and recorded for staff, since a restart forgets it.
local function rememberPaid(contractId, cid, record, action)
    local wrote, err = pcall(remember, contractId, cid, record)
    if not wrote then
        Audit.financial(action, cid, contractId, { error = tostring(err) })
    end
end

--- Whether this target may not use the informant at all: a member of a
--- whitelisted job, by the flag the contract recorded when it was placed or
--- by a barred job they hold now. Their buyout stays.
local function shielded(contract, actor)
    return contract.target_protected == true or (Identity.isBarred and Identity.isBarred(actor)) == true
end

local targetBuy

--- Buy one look-up from the target's informant, one purchase at a time per
--- buyer and contract (Contracts.serialized): a second tap while one runs is
--- refused as busy, before anything is read or charged.
---@param actor table
---@param contractId any
---@param shown table|nil the page's echo of the price it quoted, { cost,
--- account }; nil for a caller that is not a page, which quoted nothing
---@param pick any an operative's handle, or 'placer'
---@return boolean ok
---@return string|nil err
---@return table|nil data
function Informant.buy(actor, contractId, shown, pick)
    -- Turned off, from the admin panel or config.lua: new purchases only.
    -- A name already found stays shown.
    if not Config.Informant.Enabled then return false, CH.ERR.FEATURE_OFF end
    contractId = Util.toId(contractId)
    if not contractId then return false, CH.ERR.INVALID_INPUT end
    if type(pick) ~= 'string' or pick == '' or #pick > 64 then return false, CH.ERR.INVALID_INPUT end
    if not Contracts then return targetBuy(actor, contractId, shown, pick) end
    return Contracts.serialized({ 'informant:' .. contractId .. ':' .. tostring(actor.cid) },
        targetBuy, actor, contractId, shown, pick)
end

targetBuy = function(actor, contractId, shown, pick)
    -- The price, read once: the figure checked against the quote below is
    -- the figure charged, whatever the admin panel does in the awaits.
    local cost = math.floor(tonumber(Config.Informant.Cost) or 0)
    local account = Config.Informant.Account

    local contract = Storage.readContract(contractId)
    if not contract then return false, CH.ERR.NOT_FOUND end
    -- The target's, and only the target's: the placer has an informant of
    -- their own (Informant.placerBuy).
    if contract.target_cid ~= actor.cid then return false, CH.ERR.NOT_PARTICIPANT end
    if shielded(contract, actor) then return false, CH.ERR.INFORMANT_PROTECTED end
    if CH.TERMINAL[contract.state] then return false, CH.ERR.ALREADY_SETTLED end

    -- Who the look-up is about. Every operative on it is offered, wherever
    -- they have been; the placer only where they placed it anonymously, as
    -- a named one is already known.
    local key, row, label
    if pick == PLACER then
        if contract.anon_creator ~= true then return false, CH.ERR.PLACER_KNOWN end
        key, label = PLACER, PLACER_LABEL
    else
        row = operativeFor(contractId, pick)
        if not row then return false, CH.ERR.OPERATIVE_GONE end
        key, label = row.hitman_cid, labelOf(row)
    end

    local existing = recordFor(contractId, actor.cid)
    local asked = existing and existing.picks[key]
    if asked and asked.found then return false, CH.ERR.ALREADY_REVEALED end
    -- Asked about the same one again inside the reroll lock: the answer it
    -- got, at no charge and spending no attempt, rather than a second roll.
    if asked and (os.time() - asked.at) < lockSeconds() then
        return true, nil, { found = false, label = label, message = TARGET_MISS, repeated = true }
    end

    local purchases = existing and existing.purchases or 0
    if purchases >= math.floor(tonumber(Config.Informant.MaxPurchasesPerContract) or 0) then
        return false, CH.ERR.LIMIT_REACHED
    end

    -- The price the dialog quoted is the price charged: one raised from the
    -- admin panel while it was open is refused, with the price now.
    if shown ~= nil and cost > 0 then
        local quoted = type(shown) == 'table' and shown or {}
        if tonumber(quoted.cost) ~= cost or quoted.account ~= account then
            return false, CH.ERR.TERMS_CHANGED, { cost = cost, account = account }
        end
    end

    -- Read again with nothing between this and the charge: the state above
    -- was read before every await since.
    if not live(Storage.readContract(contractId)) then return false, CH.ERR.ALREADY_SETTLED end
    if row and not operativeFor(contractId, pick) then return false, CH.ERR.OPERATIVE_GONE end

    -- Charged last. Balance read first: RemoveMoney answers true on an empty
    -- bank, which is the account this ships pointed at.
    if not Util.charge(actor.player, account, cost) then
        return false, CH.ERR.INSUFFICIENT
    end

    -- Anything that goes before the roll gives the money back, a read that
    -- raised (a dropped connection) included.
    local read, now, gone = pcall(stillOn, contractId, pick, row)
    if not read or not now then
        refund(actor, contractId, cost, account, 'informant_refunded', read and gone or 'read_failed')
        if not read then error(now, 0) end
        return false, gone
    end

    local found = roll(Config.Informant.RevealChancePercent)
    local answer = found and (row
        and Informant.describe(row.hitman_cid, Config.Informant.RevealMode, row.hitman_name)
        or Informant.describe(now.creator_cid, Config.Informant.RevealMode, now.creator_name)) or nil

    local picks = {}
    for k, p in pairs(existing and existing.picks or {}) do picks[k] = p end
    picks[key] = { at = os.time(), found = found, answer = answer, label = label }
    rememberPaid(contractId, actor.cid, { purchases = purchases + 1, at = os.time(), picks = picks },
        'informant_unremembered')
    Audit.financial('informant_purchased', actor.cid, contractId, {
        cost = cost, pick = row and 'operative' or 'placer', hitman = row and row.hitman_cid or nil,
        outcome = found and 'revealed' or 'not_found',
    })

    -- Nobody is told either way: not the operative, not the placer.
    if not found then return true, nil, { found = false, label = label, message = TARGET_MISS } end
    local out = { found = true, label = label }
    for k, v in pairs(answer) do out[k] = v end
    return true, nil, out
end

--- What the target's informant has found out on this contract, for their
--- card, and how many look-ups they have left on it.
---
--- Kept for the contract's life, whatever Config.Informant.Enabled says: a
--- name found was paid for under the rules of the moment it was bought.
---@return table[] found { label, text }
---@return integer left
function Informant.answerFor(contractId, cid)
    local record = recordFor(contractId, cid)
    local found = {}
    for _, p in pairs(record and record.picks or {}) do
        if p.found and answerText(p.answer) then
            found[#found + 1] = { label = p.label or 'An operative', text = answerText(p.answer) }
        end
    end
    table.sort(found, function(a, b) return a.label < b.label end)
    local most = math.floor(tonumber(Config.Informant.MaxPurchasesPerContract) or 0)
    return found, math.max(0, most - (record and record.purchases or 0))
end

--- What the target may pick on this contract: every active operative, by
--- handle and alias, and the person who placed it. `known` where the answer
--- is already theirs (found before, or a placer who put their name to it),
--- which is not sold. Nothing for a target the informant is not open to.
---@param contract table
---@param cid string the target
---@param hitmen table[] the contract's rows, as the projection read them
---@return table[]|nil
function Informant.targetPicks(contract, cid, hitmen)
    if Config.Informant.Enabled ~= true or contract.target_cid ~= cid then return nil end
    if contract.target_protected == true or CH.TERMINAL[contract.state] then return nil end
    local record = recordFor(contract.id, cid)
    local picks = record and record.picks or {}
    local out = {}
    for i = 1, #hitmen do
        local h = hitmen[i]
        if h.state == 'active' then
            local handle = handleOf(contract.id, h.hitman_cid)
            if handle then
                local asked = picks[h.hitman_cid]
                out[#out + 1] = { pick = handle, label = labelOf(h),
                                  known = (asked and asked.found) == true }
            end
        end
    end
    out[#out + 1] = { pick = PLACER, label = PLACER_LABEL,
                      known = contract.anon_creator ~= true or (picks[PLACER] and picks[PLACER].found) == true,
                      named = contract.anon_creator ~= true or nil }
    return out
end

--- Age every reroll lock past its window, for the staff timer refresh.
---
--- The lock only, never the purchase count: the count is a limit on how
--- many look-ups a contract sells, not a wait.
---@return integer aged
function Informant.expireRerollLocks()
    local window = lockSeconds()
    local aged = 0
    -- Records still only in the store are aged as they are read back.
    locksAgedAt = os.time()
    for key, record in pairs(reveals) do
        for _, p in pairs(record.picks or {}) do p.at = os.time() - (window + 1) end
        local contractId, cid = key:match('^([^:]+):(.+)$')
        if contractId then pcall(remember, contractId, cid, record) end
        aged = aged + 1
    end
    return aged
end

--------------------------------------------------------------------------
-- The placer's informant (Config.PlacerInformant)
--------------------------------------------------------------------------

--- The placer's purchases on one contract, oldest first, from memory or
--- from the store, which is the authority: a restart that forgot them
--- counted the cap from zero and hid a name already paid for.
---@return table[]
local function boughtBy(contractId, cid)
    local key = contractId .. ':' .. cid
    if placerBought[key] then return placerBought[key] end
    local rows = {}
    if Storage and Storage.readPlacerInformants then
        for _, r in ipairs(Storage.readPlacerInformants(contractId, cid) or {}) do
            rows[#rows + 1] = {
                hitman_cid = r.hitman_cid, bought_at = tonumber(r.bought_at) or 0,
                -- A TINYINT(1) comes back from mysql as a number or a boolean.
                revealed = r.revealed == true or (tonumber(r.revealed) or 0) ~= 0,
                alerted = r.alerted == true or (tonumber(r.alerted) or 0) ~= 0,
                seq = tonumber(r.seq) or (#rows + 1),
            }
        end
    end
    table.sort(rows, function(a, b) return a.seq < b.seq end)
    placerBought[key] = rows
    return rows
end

--- Whether the placer already knows who this operative is: one who took it
--- under their name, or one a look-up found out.
local function placerKnows(rows, row)
    if row.anon ~= true then return true end
    for _, r in ipairs(rows) do
        if r.hitman_cid == row.hitman_cid and r.revealed then return true end
    end
    return false
end

--- Seconds until the placer may buy again on this contract, 0 now.
local function placerWait(rows)
    local last = rows[#rows]
    if not last then return 0 end
    local gap = math.max(0, tonumber(Config.PlacerInformant.CooldownMinutes) or 0) * 60
    return math.max(0, last.bought_at + gap - os.time())
end

--- The operative's phone notice: that the person who placed one of their
--- contracts has found out who they are, naming the contract as their own
--- card does (by its target) and never who placed it.
local function alertOperative(contract, hitmanCid)
    if not (Notify and Notify.tellOrKeep) then return false end
    local target = contract.target_name or 'your target'
    return Notify.tellOrKeep(hitmanCid, ALERT_TITLE,
        ('The person who placed one of your contracts has found out who you are: your contract '
            .. 'on %s.'):format(target), nil, contract.id)
end

local placerBuyUnlocked

--- Buy one look-up from the placer's informant on one operative, one
--- purchase at a time per placer and contract (Contracts.serialized).
---@param actor table
---@param contractId any
---@param shown table|nil the page's echo of the price it quoted
---@param pick any an operative's handle
---@return boolean ok
---@return string|nil err
---@return table|nil data
function Informant.placerBuy(actor, contractId, shown, pick)
    if not Config.PlacerInformant.Enabled then return false, CH.ERR.FEATURE_OFF end
    contractId = Util.toId(contractId)
    if not contractId then return false, CH.ERR.INVALID_INPUT end
    if type(pick) ~= 'string' or pick == '' or #pick > 64 then return false, CH.ERR.INVALID_INPUT end
    if not Contracts then return placerBuyUnlocked(actor, contractId, shown, pick) end
    return Contracts.serialized({ 'placerInformant:' .. contractId .. ':' .. tostring(actor.cid) },
        placerBuyUnlocked, actor, contractId, shown, pick)
end

placerBuyUnlocked = function(actor, contractId, shown, pick)
    local rules = Config.PlacerInformant
    local cost = math.floor(tonumber(rules.Cost) or 0)
    local account = rules.Account

    local contract = Storage.readContract(contractId)
    if not contract then return false, CH.ERR.NOT_FOUND end
    -- The placer's, named or anonymous, and nobody else's: never a hitman
    -- on it or its target.
    if contract.creator_cid ~= actor.cid then return false, CH.ERR.NOT_PARTICIPANT end
    if Identity.isBarred and Identity.isBarred(actor) then return false, CH.ERR.BLACKLISTED_JOB end
    if CH.TERMINAL[contract.state] then return false, CH.ERR.ALREADY_SETTLED end

    local row = operativeFor(contractId, pick)
    if not row then return false, CH.ERR.OPERATIVE_GONE end

    local rows = boughtBy(contractId, actor.cid)
    if placerKnows(rows, row) then return false, CH.ERR.ALREADY_REVEALED end
    if #rows >= math.floor(tonumber(rules.MaxPurchasesPerContract) or 0) then
        return false, CH.ERR.LIMIT_REACHED
    end
    local wait = placerWait(rows)
    if wait > 0 then
        return false, CH.ERR.INFORMANT_COOLDOWN, { minutes = math.ceil(wait / 60) }
    end

    if shown ~= nil and cost > 0 then
        local quoted = type(shown) == 'table' and shown or {}
        if tonumber(quoted.cost) ~= cost or quoted.account ~= account then
            return false, CH.ERR.TERMS_CHANGED, { cost = cost, account = account }
        end
    end

    if not live(Storage.readContract(contractId)) then return false, CH.ERR.ALREADY_SETTLED end
    if not operativeFor(contractId, pick) then return false, CH.ERR.OPERATIVE_GONE end

    if not Util.charge(actor.player, account, cost) then
        return false, CH.ERR.INSUFFICIENT
    end

    -- The contract ending or the operative leaving between the charge and
    -- the roll gives the money back: there is nobody left to look up. So
    -- does a read that raised.
    local read, now, gone = pcall(stillOn, contractId, pick, row)
    if not read or not now then
        refund(actor, contractId, cost, account, 'placer_informant_refunded',
            read and gone or 'read_failed')
        if not read then error(now, 0) end
        return false, gone
    end

    -- The roll, and only on a reveal the second: whether the operative
    -- notices. Nothing is said to them on a miss or a lost alert roll.
    local revealed = roll(rules.RevealChancePercent)
    local alerted = revealed and roll(rules.AlertChancePercent) or false

    local record = { hitman_cid = row.hitman_cid, bought_at = os.time(), revealed = revealed,
                     alerted = alerted, seq = #rows + 1 }
    rows[#rows + 1] = record
    local wrote, err = pcall(function()
        if Storage.writePlacerInformant then
            Storage.writePlacerInformant({
                contract_id = contractId, placer_cid = actor.cid, hitman_cid = row.hitman_cid,
                bought_at = record.bought_at, revealed = revealed, alerted = alerted,
                seq = record.seq,
            })
        end
    end)
    if not wrote then
        Audit.financial('placer_informant_unremembered', actor.cid, contractId,
            { error = tostring(err) })
    end
    -- To nobody: the price leaves the economy.
    Audit.financial('placer_informant_bought', actor.cid, contractId, {
        amount = cost, account = account, hitman = row.hitman_cid,
        outcome = revealed and 'revealed' or 'not_found', alerted = alerted,
    })

    if alerted then alertOperative(now, row.hitman_cid) end

    local label = labelOf(row)
    if not revealed then return true, nil, { found = false, label = label, message = PLACER_MISS } end
    local out = { found = true, label = label }
    for k, v in pairs(Informant.describe(row.hitman_cid, rules.RevealMode, row.hitman_name)) do
        out[k] = v
    end
    return true, nil, out
end

--- What the placer's card carries of their informant: the operatives they
--- may still ask about (anonymous, active, not found out), what earlier
--- look-ups found, how many they have left and how long until the next.
---
--- What was found stays, whatever Config.PlacerInformant.Enabled says; the
--- rest only while it is on.
---@param contract table
---@param cid string the placer
---@param hitmen table[]
---@return table { picks, found, left, wait }
function Informant.placerView(contract, cid, hitmen)
    local rows = boughtBy(contract.id, cid)
    local out = { found = {} }
    local byCid = {}
    for i = 1, #hitmen do byCid[hitmen[i].hitman_cid] = hitmen[i] end
    for _, r in ipairs(rows) do
        local h = byCid[r.hitman_cid]
        if r.revealed and h then
            local answer = Informant.describe(r.hitman_cid, Config.PlacerInformant.RevealMode,
                h.hitman_name)
            out.found[#out.found + 1] = { label = labelOf(h), text = answerText(answer) }
        end
    end
    if Config.PlacerInformant.Enabled ~= true or CH.TERMINAL[contract.state] then return out end
    out.picks = {}
    for i = 1, #hitmen do
        local h = hitmen[i]
        if h.state == 'active' and not placerKnows(rows, h) then
            local handle = handleOf(contract.id, h.hitman_cid)
            if handle then out.picks[#out.picks + 1] = { pick = handle, label = labelOf(h) } end
        end
    end
    local most = math.floor(tonumber(Config.PlacerInformant.MaxPurchasesPerContract) or 0)
    out.left = math.max(0, most - #rows)
    out.wait = placerWait(rows)
    return out
end

--------------------------------------------------------------------------
-- Releasing
--------------------------------------------------------------------------

--- Nothing is released when a player disconnects.
---
--- The records are the purchase counts and what was found, and a relog that
--- reset them was a free reset of the cap. They are keyed to a contract and
--- released by clearContract the moment it resolves.
---@return boolean false, always
function Informant.clearPlayer(cid)
    local _ = cid
    return false
end

function Informant.clearContract(contractId)
    local prefix = contractId .. ':'
    for key in pairs(reveals) do
        if key:sub(1, #prefix) == prefix then reveals[key] = nil end
    end
    for key in pairs(placerBought) do
        if key:sub(1, #prefix) == prefix then placerBought[key] = nil end
    end
    handles[contractId] = nil
    if Storage and Storage.clearReveals then Storage.clearReveals(contractId) end
    if Storage and Storage.clearPlacerInformants then Storage.clearPlacerInformants(contractId) end
end

return Informant
