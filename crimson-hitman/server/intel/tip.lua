--- Informant tip (Config.Intel.LocationTip): a hitman pays to learn the rough area
--- the target of their contract was in.
---
--- Not Config.Intel.Informant, which sells a target the name of a hitman. This one
--- is the other way round, and reuses its rules: the price the page showed
--- is the price charged (TERMS_CHANGED otherwise), one purchase at a time
--- per contract (Contracts.serialized), the charge last, after
--- every check, and the money goes to nobody. Unlike the informant's, a tip
--- that cannot be delivered is given back.
---
--- What is sold is an area, never a position. The target's position is read
--- here, on the server, once, at the moment of purchase; a centre is drawn
--- at a random distance of up to OFFSET_SHARE of the radius from it, in a
--- random direction, and only that centre and the radius go to the buyer's
--- game: the target is inside the circle and almost never at its middle. It
--- is a snapshot and does not follow them. Nobody else is ever sent the
--- area: not the board, the placer, another hitman, the advisory, the
--- target, or staff. The target is told someone knows their rough area
--- (Config.Intel.LocationTip.NotifyTarget), and nothing of who or where.

local Util = CrimsonBoot.requireShared('util')
local Holds = CrimsonBoot.require('server.holds')
local Log = CrimsonBoot.requireShared('log')
local Feature = CrimsonBoot.require('server.lib.feature')
local Markers = CrimsonBoot.require('server.lib.markers')
-- The one purchase engine (server/intel/engine.lua): the check, the charge,
-- the refund and the notices; this module keeps the tips and their area.
local Intel = CrimsonBoot.require('server.intel.engine')
--- This module's products (Intel.define), set below.
local TIP

local LocationTip = {}

local Storage, Identity, Audit, Notify, Contracts, Review

--- How far from the target the centre may be drawn, as a share of the
--- radius. Under 1, so the target is always inside the circle.
LocationTip.OFFSET_SHARE = 0.75

--- What the target's phone says, through the notice budget.
LocationTip.TARGET_TITLE = 'Informant tip'
LocationTip.TARGET_TEXT = 'Someone has been tipped off about your rough location. They know '
    .. 'the area you were in, not exactly where you are.'

--- Every tip bought on a contract, as the store holds them: [contractId] =
--- rows, oldest first. Read from the store once per contract per process
--- and kept in step with every write here, so a card does not cost a read.
local byContract = {}

--- [tip id] = the SetTimeout that takes the tip off its buyer's map.
local clearTimers = {}

--- Uniform [0, 1), replaceable by a test that needs a known draw.
LocationTip.random = math.random

--- The informant fairness rules (server/intel/rules.lua, Config.Intel),
--- each off as shipped. Set by init, so it is the module a test stack wired.
local IntelRules

function LocationTip.init(deps)
    Storage, Identity, Audit = deps.storage, deps.identity, deps.audit
    Notify, Contracts, Review = deps.notify, deps.contracts, deps.review
    byContract, clearTimers = {}, {}
    IntelRules = CrimsonBoot.require('server.intel.rules')
end

--- Whether new tips are sold (Config.Intel.LocationTip.Enabled, and the master
--- switch Config.Intel.Enabled), read at every use so the admin panel's
--- switches apply at once. With a contract, on that contract: one whose
--- target is on a whitelisted job reads
--- Config.TargetClasses.whitelisted.LocationTip instead. Without one,
--- whether any tip is sold at all.
---@param contract table|nil
---@return boolean
function LocationTip.enabled(contract)
    if contract == nil then return Intel.anyOn('LocationTip') end
    return Intel.on('LocationTip', contract.target_protected == true)
end

local function setting(key, fallback)
    local value = type(Config.Intel.LocationTip) == 'table' and tonumber(Config.Intel.LocationTip[key]) or nil
    return value and math.floor(value) or fallback
end

--------------------------------------------------------------------------
-- The area
--------------------------------------------------------------------------

--- The area shown for a target standing at (x, y): a centre drawn at a
--- random distance up to OFFSET_SHARE of the radius, in a random direction,
--- to the whole metre. A metre is kept back from the farthest distance so
--- that rounding to the metre can never carry the centre past it.
---@param x number
---@param y number
---@param radius number metres
---@return integer cx
---@return integer cy
function LocationTip.areaAround(x, y, radius)
    local far = math.max(0, LocationTip.OFFSET_SHARE * radius - 1)
    local distance = LocationTip.random() * far
    local angle = LocationTip.random() * 2 * math.pi
    return math.floor(x + math.cos(angle) * distance + 0.5),
        math.floor(y + math.sin(angle) * distance + 0.5)
end

--- Where the server sees this player's character, read now: x and y, or
--- nil where there is no ped or no position (a ped not yet in the world
--- reads as the middle of the map).
---@param src number
---@return number|nil x
---@return number|nil y
local function positionOf(src)
    local ok, x, y = pcall(function()
        local ped = GetPlayerPed(src)
        if not ped or ped == 0 then return nil end
        local coords = GetEntityCoords(ped)
        if not coords then return nil end
        return tonumber(coords.x), tonumber(coords.y)
    end)
    if not ok or not x or not y or x ~= x or y ~= y then return nil end
    if x == 0 and y == 0 then return nil end
    return x, y
end

--------------------------------------------------------------------------
-- The records
--------------------------------------------------------------------------

---@return table[] rows every tip on the contract, oldest first
local function rowsFor(contractId)
    local rows = byContract[contractId]
    if rows then return rows end
    rows = Storage.readLocationTips and Storage.readLocationTips(contractId) or {}
    table.sort(rows, function(a, b)
        if a.bought_at ~= b.bought_at then return a.bought_at < b.bought_at end
        return tostring(a.id) < tostring(b.id)
    end)
    byContract[contractId] = rows
    return rows
end

--- This buyer's tips on the contract: how many, the newest, and the newest
--- one still showing at `now`.
---@return integer count
---@return table|nil newest
---@return table|nil showing
local function boughtBy(contractId, cid, now)
    local count, newest, showing = 0, nil, nil
    for _, row in ipairs(rowsFor(contractId)) do
        if row.buyer_cid == cid then
            count = count + 1
            newest = row
            if (tonumber(row.expires_at) or 0) > now then showing = row end
        end
    end
    return count, newest, showing
end

--- Every tip on the contract, whoever bought it: how many, and the newest.
--- The most per contract and the wait between two are the contract's, not
--- each hitman's (Config.Intel.LocationTip.MaxPurchasesPerContract,
--- CooldownMinutes): five hitmen on one contract share the three.
---@return integer count
---@return table|nil newest
local function boughtOn(contractId)
    local rows = rowsFor(contractId)
    return #rows, rows[#rows]
end

local function forget(row)
    local rows = byContract[row.contract_id]
    if not rows then return end
    for i = #rows, 1, -1 do
        if rows[i].id == row.id then table.remove(rows, i) end
    end
end

--- Whether a contract is still one a tip can be bought or shown on, and
--- this player is still a hitman on it.
local function stillOn(contractId, cid)
    local contract = Storage.readContract(contractId)
    if not contract or (contract.state ~= CH.STATE.ACTIVE and contract.state ~= CH.STATE.ACCEPTED) then
        return false, CH.ERR.ALREADY_SETTLED
    end
    local mine = Storage.readHitman(contractId, cid)
    if not mine or mine.state ~= 'active' then return false, CH.ERR.NOT_PARTICIPANT end
    return true, nil, contract
end

--- stillOn, for a purchase: and not on hold by staff (server/holds.lua),
--- so a freeze that lands while the purchase awaits moves no money. Showing
--- a tip already bought again (LocationTip.reshow) asks stillOn alone.
local function stillBuyable(contractId, cid)
    local open, err, contract = stillOn(contractId, cid)
    if not open then return false, err end
    if Holds.on(contract, nil, 'staff') then
        return false, CH.ERR.CONTRACT_FROZEN
    end
    return true, nil, contract
end

--------------------------------------------------------------------------
-- The buyer's map
--------------------------------------------------------------------------

--- Put a tip on its buyer's map: the centre and the radius, to their game
--- alone, and nothing else.
local function deliver(src, row, now)
    Markers.show(src, 'tip:' .. row.contract_id, {
        kind = 'tip', x = tonumber(row.centre_x), y = tonumber(row.centre_y),
        radius = tonumber(row.radius),
        secondsLeft = math.max(0, (tonumber(row.expires_at) or 0) - now),
    })
end

--- Take the tip on this contract off this player's map, if they are here.
local function clearFor(cid, contractId)
    local actor = Identity.byCitizenId(cid)
    if not actor then return false end
    return Markers.clear(actor.source, 'tip:' .. contractId)
end

--- Take the tip off the map when its time runs out, unless a newer one on
--- the same contract is showing by then.
local function armClear(row)
    if clearTimers[row.id] then return end
    local left = math.max(0, (tonumber(row.expires_at) or 0) - os.time())
    clearTimers[row.id] = SetTimeout(left * 1000, function()
        clearTimers[row.id] = nil
        local ok, err = pcall(function()
            local _, _, showing = boughtBy(row.contract_id, row.buyer_cid, os.time())
            if showing then return end
            if clearFor(row.buyer_cid, row.contract_id) then
                Notify.push(row.buyer_cid, 'tip', row.contract_id)
            end
        end)
        if not ok then Log.debug(('informant tip %s: could not clear it: %s'):format(row.id, tostring(err))) end
    end)
end

local function disarm(row)
    local timer = clearTimers[row.id]
    if timer and type(ClearTimeout) == 'function' then ClearTimeout(timer) end
    clearTimers[row.id] = nil
end

--------------------------------------------------------------------------
-- Buying one
--------------------------------------------------------------------------

--- The services a purchase runs with (server/intel/engine.lua, Intel.buy):
--- this module's. A refund that cannot be credited is left for staff.
local function services()
    return { storage = Storage, audit = Audit, contracts = Contracts, review = Review }
end

--- Buy an informant tip on a contract, one purchase at a time per contract,
--- whichever hitman buys it (the limit and the wait are the contract's): a
--- second tap while one runs is refused as busy, before anything is read or
--- charged.
---@param actor table the buyer
---@param contractId any
---@param shown table|nil the page's echo of the price it quoted, { cost,
--- account }; nil for a caller that is not a page
---@return table|false result { secondsLeft, expiresAt, left, cooldownUntil }
---@return string|nil err
---@return table|nil data on a refusal
function LocationTip.buy(actor, contractId, shown)
    contractId = Util.toId(contractId)
    if not contractId then return false, CH.ERR.INVALID_INPUT end
    if not LocationTip.enabled() then return false, CH.ERR.FEATURE_OFF end
    return Intel.buy(TIP, services(), actor, contractId, shown)
end

--- The row a purchase writes, named before it is charged.
local function tipId(ctx)
    return ('%s:%s:%03d'):format(ctx.contractId, ctx.actor.cid, ctx.count + 1)
end

TIP = Intel.define('locationTip', {
    -- Read once: the figure checked against the quote is the figure charged.
    terms = function(ctx)
        ctx.cost = math.max(0, setting('Cost', 0))
        ctx.account = Config.Intel.LocationTip.Account
        ctx.radius = math.max(1, setting('RadiusMeters', 350))
        ctx.most = setting('MaxPurchasesPerContract', 0)
        ctx.wait = math.max(0, setting('CooldownMinutes', 0)) * 60
        ctx.show = math.max(1, setting('ShowMinutes', 10)) * 60
    end,
    steps = {
        -- Who may: a hitman holding the contract, and nobody else. Off for
        -- this contract (a target on a whitelisted job reads its own
        -- switch), or on hold by staff: refused before anything is charged.
        'party', 'live', 'class', 'holds',
        function(ctx)
            local now = os.time()
            ctx.now = now
            -- Held long enough (Config.Intel.HoldFirst; off as shipped).
            local hold = IntelRules.holdLeft(ctx.mine, now)
            if hold > 0 then
                return CH.ERR.TIP_HOLD, { untilAt = now + hold, retryAfter = hold }
            end
            local count, newest = boughtOn(ctx.contractId)
            ctx.count = count
            if count >= ctx.most then return CH.ERR.LIMIT_REACHED, { most = ctx.most } end
            -- One each (Config.Intel.TipLimits.OnePerHitman; off as shipped).
            if IntelRules.usedOwn((boughtBy(ctx.contractId, ctx.actor.cid, now))) then
                return CH.ERR.LIMIT_REACHED, { most = 1, perHitman = true }
            end
            local untilAt = newest and ((tonumber(newest.bought_at) or 0) + ctx.wait) or 0
            -- The wait stands still while the contract is held (the restart
            -- hold, the app pause): its end gives the time back
            -- (LocationTip.heldBack), and a tip bought meanwhile, on the wall
            -- clock's word, came before it.
            if newest and untilAt > 0 then
                local since = Holds.since(ctx.contract)
                local start = since and math.max(since, tonumber(newest.bought_at) or since)
                if start and start < untilAt and now > start then untilAt = untilAt + (now - start) end
            end
            if untilAt > now then
                return CH.ERR.TIP_COOLDOWN, { untilAt = untilAt, retryAfter = untilAt - now }
            end
            -- Each further tip dearer (TipLimits.PriceDoubling; off as
            -- shipped): the price checked against the quote, and charged.
            ctx.cost = IntelRules.tipPrice(ctx.cost, count)
            return nil
        end,
    },
    ready = function(ctx)
        -- The target in the city, where the server sees them now.
        local target = Identity.byCitizenId(ctx.contract.target_cid)
        local x, y
        if target then x, y = positionOf(target.source) end
        if not x then return CH.ERR.TIP_TARGET_AWAY end
        -- In a safe zone (Config.Intel.SafeZones; off as shipped): refused,
        -- nothing charged, never saying why or where.
        if IntelRules.inSafeZone(x, y) then
            Audit.rejected('location_tip_safe_zone', ctx.actor.cid, ctx.contractId, {})
            return CH.ERR.TIP_CANT_PLACE
        end
        ctx.x, ctx.y = x, y
        -- And the contract and this hitman read again, with nothing between
        -- this and the charge: every read above is an await on mysql.
        local open, err = stillBuyable(ctx.contractId, ctx.actor.cid)
        if not open then return err end
        return nil
    end,
    -- A purchase a crash caught after the charge is kept where its row is
    -- in the store, refunded where not (Intel.decideUnrecorded).
    intent = function(ctx) return { row = tipId(ctx) } end,
    recorded = function(contractId, _, mark)
        for _, r in ipairs(Storage.readLocationTips(contractId) or {}) do
            if r.id == mark.row then return true end
        end
        return false
    end,
    confirm = function(ctx)
        local contractId, actor, now = ctx.contractId, ctx.actor, ctx.now
        -- The target went dark (Config.Intel.GoDark): the informant finds
        -- nothing, and the price comes back in full. Nothing is kept or
        -- counted.
        if IntelRules.targetDark(ctx.contract.target_cid) then
            return false, CH.ERR.TIP_NOT_FOUND, {}, 'gone_dark', true
        end

        local cx, cy = LocationTip.areaAround(ctx.x, ctx.y, ctx.radius)
        local row = {
            id = tipId(ctx),
            contract_id = contractId, buyer_cid = actor.cid,
            bought_at = now, expires_at = now + ctx.show,
            centre_x = cx, centre_y = cy, radius = ctx.radius,
            target_told = Config.Intel.LocationTip.NotifyTarget ~= false,
        }

        -- Kept, then the contract read once more: one that ended while the
        -- row was written, or a hitman taken off it, is refunded, as is a
        -- write that raised. Nothing is delivered until all of it stands.
        local kept, why = pcall(function()
            Storage.writeLocationTip(row)
            local rows = rowsFor(contractId)
            rows[#rows + 1] = row
            return true
        end)
        local stands, refusal = false, CH.ERR.SERVER_ERROR
        if kept then
            local read, ok, err2 = pcall(stillBuyable, contractId, actor.cid)
            stands = read and ok == true
            refusal = read and err2 or CH.ERR.SERVER_ERROR
        else
            Log.debug(('informant tip on %s: the store would not keep it: %s')
                :format(contractId, tostring(why)))
        end
        if not stands then
            forget(row)
            pcall(Storage.deleteLocationTip, row.id)
            return false, refusal, nil, kept and 'contract_ended' or 'not_kept'
        end
        ctx.row = row
        return true
    end,
    deliver = function(ctx)
        local row, contract, now, actor = ctx.row, ctx.contract, ctx.now, ctx.actor
        -- Audited with what was paid and by whom; never the area or the position.
        Audit.financial('location_tip_bought', actor.cid, ctx.contractId,
            { amount = ctx.cost, account = ctx.account })

        deliver(actor.source, row, now)
        armClear(row)

        if row.target_told and Notify.locationTipped then
            -- At once, or a random while later (WarningDelay; off as shipped).
            IntelRules.warnTarget(contract, row, function()
                Intel.tell('tipped', Notify, contract, LocationTip.TARGET_TITLE, LocationTip.TARGET_TEXT)
            end)
        end
        -- A member of a whitelisted job: law enforcement is told a hitman is
        -- closing in (Config.Advisory.OnLocationTip). Never who, never where.
        Intel.tell('advisory', Notify, contract)

        return {
            secondsLeft = ctx.show, expiresAt = row.expires_at,
            left = math.max(0, ctx.most - (ctx.count + 1)),
            cooldownUntil = ctx.wait > 0 and (now + ctx.wait) or nil,
        }
    end,
})

--------------------------------------------------------------------------
-- After a restart, and on the card
--------------------------------------------------------------------------

--- Put this player's tips still showing back on their map: after the
--- resource restarts, or when they come back to the city. Only on a contract
--- still live that they still hold; the newest on each contract.
---@param actor table
---@return table result { shown = integer }
function LocationTip.reshow(actor)
    local now = os.time()
    local rows = Storage.liveLocationTips and Storage.liveLocationTips(actor.cid, now) or {}
    table.sort(rows, function(a, b)
        if a.bought_at ~= b.bought_at then return a.bought_at < b.bought_at end
        return tostring(a.id) < tostring(b.id)
    end)
    local newest = {}
    for _, row in ipairs(rows) do newest[row.contract_id] = row end
    local shown = 0
    for contractId, row in pairs(newest) do
        if stillOn(contractId, actor.cid) then
            deliver(actor.source, row, now)
            armClear(row)
            shown = shown + 1
        end
    end
    return { shown = shown }
end

--- What a hitman's own card says about tips on a contract they hold: how
--- many are left on it, when the next may be bought (both the contract's,
--- the same on every hitman's card), the one of their own showing now, and
--- whether the target is in the city to be found. Never another's area.
--- nil where the server sells none and none is showing.
---@param contract table
---@param cid string
---@return table|nil
function LocationTip.cardFor(contract, cid)
    if CH.TERMINAL[contract.state] then return nil end
    local now = os.time()
    local _, _, showing = boughtBy(contract.id, cid, now)
    local count, newest = boughtOn(contract.id)
    local on = LocationTip.enabled(contract)
    -- Off for this contract while the server sells them elsewhere: said, so
    -- the card draws no button.
    if not on and not showing then
        return LocationTip.enabled() and { off = true } or nil
    end
    local out = { off = (not on) or nil }
    if on then
        local mine = Feature.on('Intel.HoldFirst') and Storage.readHitman(contract.id, cid) or nil
        IntelRules.tipCard(out, contract, mine, count, (boughtBy(contract.id, cid, now)), now)
    end
    if showing then
        out.secondsLeft = (tonumber(showing.expires_at) or 0) - now
        out.expiresAt = tonumber(showing.expires_at)
    end
    if on then
        out.left = math.max(0, setting('MaxPurchasesPerContract', 0) - count)
        local untilAt = newest
            and ((tonumber(newest.bought_at) or 0) + math.max(0, setting('CooldownMinutes', 0)) * 60)
            or 0
        if untilAt > now then
            out.cooldownSeconds = untilAt - now
            out.cooldownUntil = untilAt
        end
        out.targetAway = Identity.byCitizenId(contract.target_cid) == nil or nil
    end
    return out
end

--- When the target of a contract was last told a tip was bought on it, for
--- their own view; nil where they were never told. Never by whom, nor where.
---@param contractId string
---@return integer|nil
function LocationTip.toldAt(contractId)
    local at
    for _, row in ipairs(rowsFor(contractId)) do
        -- A warning still waiting (WarningDelay) is not told yet.
        if (row.target_told == true or row.target_told == 1) and not IntelRules.waiting(row.id) then
            local bought = tonumber(row.bought_at)
            bought = bought and IntelRules.shownTime(bought)
            if bought and (not at or bought > at) then at = bought end
        end
    end
    return at
end

--- When a tip was last bought on this contract, whoever bought it, for the
--- whitelisted-job view's colleagues' list; nil where none was. Never by
--- whom, nor where.
---@param contractId string
---@return integer|nil
function LocationTip.lastBoughtAt(contractId)
    local at
    for _, row in ipairs(rowsFor(contractId)) do
        local bought = tonumber(row.bought_at)
        if bought and (not at or bought > at) then at = bought end
    end
    return at
end

--------------------------------------------------------------------------
-- Clearing
--------------------------------------------------------------------------

--- A hold on the contract has ended (server/holds.lua's give-back, through
--- IntelRules.heldBack): every tip on it is given the time it stood still,
--- from `from` (or when it was bought, if later) to `to`. Its showing, if
--- it was still showing when the hold began, ends that much later, and is
--- put back on its buyer's map; its wait, if it was still running, does
--- too, so the hitman held does not come back able to buy at once. Kept
--- by the store first, then here.
---@param contractId string
---@param from integer os.time()
---@param to integer os.time()
function LocationTip.heldBack(contractId, from, to)
    if not (Storage and Storage.moveLocationTip) then return end
    -- Nothing read where none is sold and none was read: a hold's end gives
    -- every live contract its time back, and as shipped tips are off.
    if not byContract[contractId] and not LocationTip.enabled() then return end
    local rows = rowsFor(contractId)
    if #rows == 0 then return end
    local wait = math.max(0, setting('CooldownMinutes', 0)) * 60
    local now = os.time()
    for _, row in ipairs(rows) do
        local bought, expires = tonumber(row.bought_at) or 0, tonumber(row.expires_at) or 0
        local start = math.max(from, bought)
        local span = to - start
        local newBought, newExpires = bought, expires
        if span > 0 then
            if start < expires then newExpires = expires + span end
            if start < bought + wait then newBought = bought + span end
        end
        if newBought ~= bought or newExpires ~= expires then
            local moved, err = pcall(Storage.moveLocationTip, row.id, newBought, newExpires)
            if moved then
                row.bought_at, row.expires_at = newBought, newExpires
                if newExpires ~= expires and newExpires > now then
                    disarm(row)
                    local buyer = Identity and Identity.byCitizenId(row.buyer_cid)
                    if buyer and stillOn(contractId, row.buyer_cid) then deliver(buyer.source, row, now) end
                    armClear(row)
                end
            else
                Log.always(('informant tip %s: the time a hold took could not be given back (%s)')
                    :format(tostring(row.id), Util.dbError(err)))
            end
        end
    end
end

--- The contract has ended: every tip on it comes off its buyer's map, and
--- its records go.
function LocationTip.clearContract(contractId)
    local rows = rowsFor(contractId)
    local told = {}
    for _, row in ipairs(rows) do
        disarm(row)
        if not told[row.buyer_cid] then
            told[row.buyer_cid] = true
            clearFor(row.buyer_cid, contractId)
        end
    end
    byContract[contractId] = nil
    -- Nothing to delete where nothing was bought: no write on every ending.
    if #rows > 0 and Storage.clearLocationTips then pcall(Storage.clearLocationTips, contractId) end
end

--- A hitman has left the contract: their tip comes off their map. The
--- records stay, so leaving and coming back neither resets the cooldown nor
--- the most per contract.
function LocationTip.hitmanLeft(contractId, cid)
    local any = false
    for _, row in ipairs(rowsFor(contractId)) do
        if row.buyer_cid == cid then
            disarm(row)
            any = true
        end
    end
    if any then clearFor(cid, contractId) end
end

return LocationTip
