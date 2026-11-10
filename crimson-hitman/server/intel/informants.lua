--- Counter-Intelligence — the two informants (§6.1, §14.29).
---
--- The target's (Config.Intel.Informant): a target picks one operative on a
--- contract on them, or the person who placed it, and pays for one look-up.
--- The placer's (Config.Intel.PlacerInformant): the person who placed a contract
--- picks one of the operatives who took it, and pays for one look-up.
---
--- Both are a gamble, and say so: the price is paid whatever the look-up
--- finds. Whether it finds anything is a roll made here, on the server, with
--- a fresh number for every purchase that is never sent before the answer.
--- The pick is a handle this module minted for an operative's row on that
--- contract; which row it stands for never leaves the server.

local Util = CrimsonBoot.requireShared('util')
local Holds = CrimsonBoot.require('server.holds')
-- The one purchase engine (server/intel/engine.lua): the check, the charge,
-- the refund and the notices; this module keeps what the look-ups find.
local Intel = CrimsonBoot.require('server.intel.engine')
--- This module's products (Intel.define), set below.
local TARGET_LOOKUP, PLACER_LOOKUP

local Informant = {}

local Storage, Identity, Audit, Contracts, Notify, Bailout

--- The target's purchases. [contractId .. ':' .. buyerCid] = { purchases,
--- at, picks = { [hitmanCid | 'placer'] = { at, found, answer, label } } }
local reveals = {}

--- The buyers the store holds no record for yet, by the same key: read
--- once, not on every card. A target's Mine asked the store twice for each
--- contract on them (the card's answers and its picks), and all but a few
--- have never bought anything. Gone the moment one is remembered, and with
--- the contract (clearContract).
local noRecord = {}

--- The placer's purchases, in the order they were made.
--- [contractId .. ':' .. placerCid] = { { hitman_cid, bought_at, revealed, alerted, seq } }
local placerBought = {}

--- Purchases paid for whose store write failed, written again by the tick
--- (Informant.retryUnsaved) so the purchase count and the cooldown survive a
--- restart. Target records by key; the placer's rows as they were to be
--- written. [contractId .. ':' .. cid] = true, and { row, ... }
local unsavedReveals, unsavedPlacer = {}, {}

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
    unsavedReveals, unsavedPlacer = {}, {}
    noRecord = {}
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
    return math.max(0, tonumber(Config.Intel.Informant.RerollLockMinutes) or 0) * 60
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

--- Whether the target is already shown this operative's name: one who took
--- the contract under it, while Config.TargetClasses.default.ShowOperativeNames is on.
--- One who took it anonymously never is.
local function namedToTarget(contract, row)
    return row.anon ~= true and Util.targetRule('ShowOperativeNames', contract.target_protected == true)
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
    if (mode or Config.Intel.Informant.RevealMode) == 'name' then
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
local live = Intel.isLive

--- After the charge and before the roll: the contract still open, not held
--- by staff (Holds.on, 'staff': no money moves on one that is, so it is
--- asked on every read again before and after the charge, and a freeze that
--- lands in the awaits refunds), and the operative (where there is one)
--- still on it. The contract as read now, or nil and why not.
local function stillOn(contractId, pick, row)
    local now = Storage.readContract(contractId)
    if not live(now) then return nil, CH.ERR.ALREADY_SETTLED end
    if Holds.on(now, nil, 'staff') then return nil, CH.ERR.CONTRACT_FROZEN end
    if row and not operativeFor(contractId, pick) then return nil, CH.ERR.OPERATIVE_GONE end
    return now
end

--- The services a purchase runs with (server/intel/engine.lua, Intel.buy):
--- this module's, so a test that starts it over another store moves it alone.
local function services()
    return { storage = Storage, audit = Audit, contracts = Contracts, bailout = Bailout }
end

--- The last read before the charge, and the one after it (the engine gives
--- the price back on a refusal there, or a read that raised).
local function readyOn(ctx)
    local _, err = stillOn(ctx.contractId, ctx.extra, ctx.row)
    return err
end
local function confirmOn(ctx)
    local now, gone = stillOn(ctx.contractId, ctx.extra, ctx.row)
    if not now then return false, gone, nil, gone end
    ctx.now = now
    return true
end

--------------------------------------------------------------------------
-- The target's informant (Config.Intel.Informant)
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
    if noRecord[key] then return nil end
    if not (Storage and Storage.readReveal) then return nil end

    local stored = Storage.readReveal(contractId, cid)
    if not stored then
        -- Not if one was remembered while the store was asked (mysql waits).
        if not reveals[key] then noRecord[key] = true end
        return reveals[key]
    end

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
    noRecord[contractId .. ':' .. cid] = nil
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
        unsavedReveals[contractId .. ':' .. cid] = true
        Audit.financial(action, cid, contractId, { error = tostring(err) })
    else
        unsavedReveals[contractId .. ':' .. cid] = nil
    end
end

--- Whether this target counts as a member of a whitelisted job for the
--- informant: by the flag the contract recorded when it was placed, or by a
--- barred job they hold now. Sold to them only while
--- Config.TargetClasses.whitelisted.Informant is on; their buyout stays.
local function shielded(contract, actor)
    return contract.target_protected == true or (Identity.isBarred and Identity.isBarred(actor)) == true
end

--- Buy one look-up from the target's informant, one purchase at a time per
--- buyer and contract (the engine's lock): a second tap while one runs is
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
    -- Its own switch, or the master switch over all three (Intel.on):
    -- off for every target, civilian and whitelisted-job alike. Which of
    -- the two applies is decided once the contract is read (the class step).
    if not Intel.anyOn('Informant') then return false, CH.ERR.FEATURE_OFF end
    contractId = Util.toId(contractId)
    if not contractId then return false, CH.ERR.INVALID_INPUT end
    if type(pick) ~= 'string' or pick == '' or #pick > 64 then return false, CH.ERR.INVALID_INPUT end
    local result, err, data = Intel.buy(TARGET_LOOKUP, services(), actor, contractId, shown, pick)
    if not result then return false, err, data end
    return true, nil, result
end

TARGET_LOOKUP = Intel.define('informant', {
    -- The price, read once: the figure checked against the quote is the
    -- figure charged, whatever the admin panel does in the awaits.
    terms = function(ctx)
        ctx.cost = math.floor(tonumber(Config.Intel.Informant.Cost) or 0)
        ctx.account = Config.Intel.Informant.Account
    end,
    -- The switch for this target: a member of a whitelisted job reads
    -- Config.TargetClasses.whitelisted.Informant, refused as before
    -- (informant_protected) while it is off; anybody else the general one.
    protected = function(ctx) return shielded(ctx.contract, ctx.actor) end,
    offErr = function(_, protected)
        return protected and CH.ERR.INFORMANT_PROTECTED or CH.ERR.FEATURE_OFF
    end,
    steps = {
        -- The target's, and only the target's: the placer has an informant
        -- of their own (Informant.placerBuy).
        'party', 'holds', 'class', 'open',
        -- Who the look-up is about. Every operative on it is offered,
        -- wherever they have been; the placer only where they placed it
        -- anonymously, as a named one is already known.
        function(ctx)
            local contract, pick = ctx.contract, ctx.extra
            if pick == PLACER then
                if contract.anon_creator ~= true then return CH.ERR.PLACER_KNOWN end
                ctx.key, ctx.label = PLACER, PLACER_LABEL
                return nil
            end
            local row = operativeFor(ctx.contractId, pick)
            if not row then return CH.ERR.OPERATIVE_GONE end
            -- One already shown to them by name, as a named placer is.
            if namedToTarget(contract, row) then return CH.ERR.OPERATIVE_KNOWN end
            ctx.row, ctx.key, ctx.label = row, row.hitman_cid, labelOf(row)
            return nil
        end,
        -- What they asked before, and the cap.
        function(ctx)
            local existing = recordFor(ctx.contractId, ctx.actor.cid)
            ctx.existing = existing
            local asked = existing and existing.picks[ctx.key]
            if asked and asked.found then return CH.ERR.ALREADY_REVEALED end
            -- Asked about the same one again inside the reroll lock: the
            -- answer it got, at no charge and spending no attempt, rather
            -- than a second roll.
            if asked and (os.time() - asked.at) < lockSeconds() then
                ctx.answer = { found = false, label = ctx.label, message = TARGET_MISS, repeated = true }
                return nil
            end
            ctx.purchases = existing and existing.purchases or 0
            if ctx.purchases >= math.floor(tonumber(Config.Intel.Informant.MaxPurchasesPerContract) or 0) then
                return CH.ERR.LIMIT_REACHED
            end
            return nil
        end,
        -- A later look-up at its own price (Config.Intel.SecondTry; off as
        -- shipped, the same price): the figure quoted on the card, checked
        -- and charged.
        function(ctx)
            ctx.cost = CrimsonBoot.require('server.intel.rules').informantPrice(ctx.cost, ctx.purchases)
            return nil
        end,
    },
    -- Read again with nothing between this and the charge: the state above
    -- was read before every await since.
    ready = readyOn,
    confirm = confirmOn,
    deliver = function(ctx)
        local row, now, actor, contractId = ctx.row, ctx.now, ctx.actor, ctx.contractId
        local found = roll(Config.Intel.Informant.RevealChancePercent)
        local answer = found and (row
            and Informant.describe(row.hitman_cid, Config.Intel.Informant.RevealMode, row.hitman_name)
            or Informant.describe(now.creator_cid, Config.Intel.Informant.RevealMode, now.creator_name)) or nil

        local picks = {}
        for k, p in pairs(ctx.existing and ctx.existing.picks or {}) do picks[k] = p end
        picks[ctx.key] = { at = os.time(), found = found, answer = answer, label = ctx.label }
        rememberPaid(contractId, actor.cid, { purchases = ctx.purchases + 1, at = os.time(), picks = picks },
            'informant_unremembered')
        Audit.financial('informant_purchased', actor.cid, contractId, {
            cost = ctx.cost, pick = row and 'operative' or 'placer', hitman = row and row.hitman_cid or nil,
            outcome = found and 'revealed' or 'not_found',
        })

        -- Nobody is told either way: not the operative, not the placer.
        if not found then return { found = false, label = ctx.label, message = TARGET_MISS } end
        local out = { found = true, label = ctx.label }
        for k, v in pairs(answer) do out[k] = v end
        return out
    end,
})

--- What the target's informant has found out on this contract, for their
--- card, and how many look-ups they have left on it.
---
--- Kept for the contract's life, whatever Config.Intel.Informant.Enabled says: a
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
    local most = math.floor(tonumber(Config.Intel.Informant.MaxPurchasesPerContract) or 0)
    return found, math.max(0, most - (record and record.purchases or 0))
end

--- How many look-ups this target has bought on this contract (their card's
--- price for the next, server/intel/rules.lua).
---@return integer
function Informant.purchasesBy(contractId, cid)
    local record = recordFor(contractId, cid)
    return record and record.purchases or 0
end

--- What the target may pick on this contract: every active operative, by
--- handle and alias, and the person who placed it. `known` where the answer
--- is already theirs (found before, a placer who put their name to it, or
--- an operative who took it under theirs while names are shown to the
--- target), which is not sold; `named` for the last two, where the label
--- carries the name. Nothing for a target the informant is not open to.
---@param contract table
---@param cid string the target
---@param hitmen table[] the contract's rows, as the projection read them
---@param protected boolean|nil read as on a whitelisted job whatever the
--- contract recorded (a target barred by a job held now); nil reads the flag
---@return table[]|nil
function Informant.targetPicks(contract, cid, hitmen, protected)
    if contract.target_cid ~= cid or CH.TERMINAL[contract.state] then return nil end
    -- A target on a whitelisted job by the contract's flag reads
    -- Config.TargetClasses.whitelisted.Informant; anybody else the
    -- general switch.
    if protected == nil then protected = contract.target_protected == true end
    if not Intel.on('Informant', protected) then return nil end
    local record = recordFor(contract.id, cid)
    local picks = record and record.picks or {}
    local out = {}
    for i = 1, #hitmen do
        local h = hitmen[i]
        if h.state == 'active' then
            local handle = handleOf(contract.id, h.hitman_cid)
            if handle then
                local asked = picks[h.hitman_cid]
                local named = namedToTarget(contract, h) and type(h.hitman_name) == 'string'
                out[#out + 1] = { pick = handle,
                                  label = named and (labelOf(h) .. ' (' .. h.hitman_name .. ')')
                                      or labelOf(h),
                                  known = named or (asked and asked.found) == true,
                                  named = named or nil }
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
-- The placer's informant (Config.Intel.PlacerInformant)
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
    local gap = math.max(0, tonumber(Config.Intel.PlacerInformant.CooldownMinutes) or 0) * 60
    return math.max(0, last.bought_at + gap - os.time())
end

--- The operative's phone notice: that the person who placed one of their
--- contracts has found out who they are, naming the contract as their own
--- card does (by its target) and never who placed it.
local function alertOperative(contract, hitmanCid)
    if not (Notify and Notify.tellOrKeep) then return false end
    local target = contract.target_name or 'your target'
    return Intel.tell('foundOut', Notify, hitmanCid, ALERT_TITLE,
        ('The person who placed one of your contracts has found out who you are: your contract '
            .. 'on %s.'):format(target), contract.id)
end

--- Buy one look-up from the placer's informant on one operative, one
--- purchase at a time per placer and contract (the engine's lock).
---@param actor table
---@param contractId any
---@param shown table|nil the page's echo of the price it quoted
---@param pick any an operative's handle
---@return boolean ok
---@return string|nil err
---@return table|nil data
function Informant.placerBuy(actor, contractId, shown, pick)
    -- Off for every target; which switch applies to this contract is read
    -- with it (the class step).
    if not Intel.anyOn('PlacerInformant') then return false, CH.ERR.FEATURE_OFF end
    contractId = Util.toId(contractId)
    if not contractId then return false, CH.ERR.INVALID_INPUT end
    if type(pick) ~= 'string' or pick == '' or #pick > 64 then return false, CH.ERR.INVALID_INPUT end
    local result, err, data = Intel.buy(PLACER_LOOKUP, services(), actor, contractId, shown, pick)
    if not result then return false, err, data end
    return true, nil, result
end

PLACER_LOOKUP = Intel.define('placerInformant', {
    terms = function(ctx)
        ctx.cost = math.floor(tonumber(Config.Intel.PlacerInformant.Cost) or 0)
        ctx.account = Config.Intel.PlacerInformant.Account
    end,
    steps = {
        -- The placer's, named or anonymous, and nobody else's: never a
        -- hitman on it or its target. On a contract on a whitelisted job,
        -- Config.TargetClasses.whitelisted.PlacerInformant decides it; on
        -- any other, the general switch.
        'party', 'class',
        function(ctx)
            if Identity.isBarred and Identity.isBarred(ctx.actor) then return CH.ERR.BLACKLISTED_JOB end
            return nil
        end,
        'holds', 'open',
        function(ctx)
            local row = operativeFor(ctx.contractId, ctx.extra)
            if not row then return CH.ERR.OPERATIVE_GONE end
            local rows = boughtBy(ctx.contractId, ctx.actor.cid)
            if placerKnows(rows, row) then return CH.ERR.ALREADY_REVEALED end
            if #rows >= math.floor(tonumber(Config.Intel.PlacerInformant.MaxPurchasesPerContract) or 0) then
                return CH.ERR.LIMIT_REACHED
            end
            local wait = placerWait(rows)
            if wait > 0 then
                return CH.ERR.INFORMANT_COOLDOWN, { minutes = math.ceil(wait / 60) }
            end
            ctx.row, ctx.rows = row, rows
            return nil
        end,
    },
    ready = readyOn,
    -- The contract ending or the operative leaving between the charge and
    -- the roll gives the money back: there is nobody left to look up. So
    -- does a read that raised.
    confirm = confirmOn,
    deliver = function(ctx)
        local rules, row, rows, actor, contractId = Config.Intel.PlacerInformant, ctx.row, ctx.rows,
            ctx.actor, ctx.contractId
        -- The roll, and only on a reveal the second: whether the operative
        -- notices. Nothing is said to them on a miss or a lost alert roll.
        local revealed = roll(rules.RevealChancePercent)
        local alerted = revealed and roll(rules.AlertChancePercent) or false

        local record = { hitman_cid = row.hitman_cid, bought_at = os.time(), revealed = revealed,
                         alerted = alerted, seq = #rows + 1 }
        rows[#rows + 1] = record
        local stored = {
            contract_id = contractId, placer_cid = actor.cid, hitman_cid = row.hitman_cid,
            bought_at = record.bought_at, revealed = revealed, alerted = alerted,
            seq = record.seq,
        }
        local wrote, err = pcall(function()
            if Storage.writePlacerInformant then Storage.writePlacerInformant(stored) end
        end)
        if not wrote then
            -- Kept to be written again on the tick: only in memory, a restart
            -- counted the cap from zero and forgot the wait.
            unsavedPlacer[#unsavedPlacer + 1] = stored
            Audit.financial('placer_informant_unremembered', actor.cid, contractId,
                { error = tostring(err) })
        end
        -- To nobody: the price leaves the economy.
        Audit.financial('placer_informant_bought', actor.cid, contractId, {
            amount = ctx.cost, account = ctx.account, hitman = row.hitman_cid,
            outcome = revealed and 'revealed' or 'not_found', alerted = alerted,
        })

        if alerted then alertOperative(ctx.now, row.hitman_cid) end

        local label = labelOf(row)
        if not revealed then return { found = false, label = label, message = PLACER_MISS } end
        local out = { found = true, label = label }
        for k, v in pairs(Informant.describe(row.hitman_cid, rules.RevealMode, row.hitman_name)) do
            out[k] = v
        end
        return out
    end,
})

--- What the placer's card carries of their informant: the operatives they
--- may still ask about (anonymous, active, not found out), what earlier
--- look-ups found, how many they have left and how long until the next.
---
--- What was found stays, whatever Config.Intel.PlacerInformant.Enabled says; the
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
            local answer = Informant.describe(r.hitman_cid, Config.Intel.PlacerInformant.RevealMode,
                h.hitman_name)
            out.found[#out.found + 1] = { label = labelOf(h), text = answerText(answer) }
        end
    end
    if not Intel.on('PlacerInformant', contract.target_protected == true)
        or CH.TERMINAL[contract.state] then return out end
    out.picks = {}
    for i = 1, #hitmen do
        local h = hitmen[i]
        if h.state == 'active' and not placerKnows(rows, h) then
            local handle = handleOf(contract.id, h.hitman_cid)
            if handle then out.picks[#out.picks + 1] = { pick = handle, label = labelOf(h) } end
        end
    end
    local most = math.floor(tonumber(Config.Intel.PlacerInformant.MaxPurchasesPerContract) or 0)
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

--- The operatives this target's informant found out by name on this
--- contract, for the hit on the hitman (server/rp_protection.lua,
--- Config.Roleplay.HitOnHitman): their citizen id stays on the server, and
--- the caller hands the page a target handle for each. Never the placer,
--- and never one found only by description: placing a contract on them
--- would name them on its card, which the look-up did not.
---@param contractId string
---@param cid string the target who bought the look-ups
---@return table[] { cid, label, name }
function Informant.revealedOperatives(contractId, cid)
    local record = recordFor(contractId, cid)
    local out = {}
    for pick, p in pairs(record and record.picks or {}) do
        if pick ~= PLACER and p.found and type(p.answer) == 'table' and type(p.answer.name) == 'string'
            and p.answer.name ~= 'Unknown operative' then
            out[#out + 1] = { cid = pick, label = p.label or 'An operative', name = p.answer.name }
        end
    end
    table.sort(out, function(a, b) return a.label < b.label end)
    return out
end

--- Write again every purchase the store would not take when it was made:
--- the tick's job, as the bodyguard rows are. Answers how many are written.
---@return integer written
function Informant.retryUnsaved()
    local written = 0
    for key in pairs(unsavedReveals) do
        local record = reveals[key]
        local contractId, cid = key:match('^([^:]+):(.+)$')
        if not record or not contractId then
            unsavedReveals[key] = nil
        elseif pcall(remember, contractId, cid, record) then
            unsavedReveals[key] = nil
            written = written + 1
        end
    end
    if #unsavedPlacer > 0 and Storage and Storage.writePlacerInformant then
        local left = {}
        for i = 1, #unsavedPlacer do
            if pcall(Storage.writePlacerInformant, unsavedPlacer[i]) then
                written = written + 1
            else
                left[#left + 1] = unsavedPlacer[i]
            end
        end
        unsavedPlacer = left
    end
    return written
end

function Informant.clearContract(contractId)
    local prefix = contractId .. ':'
    for key in pairs(reveals) do
        if key:sub(1, #prefix) == prefix then reveals[key] = nil end
    end
    for key in pairs(unsavedReveals) do
        if key:sub(1, #prefix) == prefix then unsavedReveals[key] = nil end
    end
    local kept = {}
    for i = 1, #unsavedPlacer do
        if unsavedPlacer[i].contract_id ~= contractId then kept[#kept + 1] = unsavedPlacer[i] end
    end
    unsavedPlacer = kept
    for key in pairs(noRecord) do
        if key:sub(1, #prefix) == prefix then noRecord[key] = nil end
    end
    for key in pairs(placerBought) do
        if key:sub(1, #prefix) == prefix then placerBought[key] = nil end
    end
    handles[contractId] = nil
    if Storage and Storage.clearReveals then Storage.clearReveals(contractId) end
    if Storage and Storage.clearPlacerInformants then Storage.clearPlacerInformants(contractId) end
end

return Informant
