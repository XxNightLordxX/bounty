--- Informant tip (Config.LocationTip): a hitman pays to learn the rough area
--- the target of their contract was in.
---
--- Not Config.Informant, which sells a target the name of a hitman. This one
--- is the other way round, and reuses its rules: the price the page showed
--- is the price charged (TERMS_CHANGED otherwise), one purchase at a time
--- per contract and buyer (Contracts.serialized), the charge last, after
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
--- (Config.LocationTip.NotifyTarget), and nothing of who or where.

local Util = CrimsonBoot.requireShared('util')
local Log = CrimsonBoot.requireShared('log')

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

function LocationTip.init(deps)
    Storage, Identity, Audit = deps.storage, deps.identity, deps.audit
    Notify, Contracts, Review = deps.notify, deps.contracts, deps.review
    byContract, clearTimers = {}, {}
end

--- Whether new tips are sold (Config.LocationTip.Enabled, and the master
--- switch Config.InformantsEnabled), read at every use so the admin panel's
--- switches apply at once. With a contract, on that contract: one whose
--- target is on a whitelisted job reads
--- Config.InformantsWhitelistedTargets.LocationTip instead. Without one,
--- whether any tip is sold at all.
---@param contract table|nil
---@return boolean
function LocationTip.enabled(contract)
    if contract == nil then return Util.informantAnyOn('LocationTip') end
    return Util.informantOn('LocationTip', contract.target_protected == true)
end

local function setting(key, fallback)
    local value = type(Config.LocationTip) == 'table' and tonumber(Config.LocationTip[key]) or nil
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

--------------------------------------------------------------------------
-- The buyer's map
--------------------------------------------------------------------------

--- Put a tip on its buyer's map: the centre and the radius, to their game
--- alone, and nothing else.
local function deliver(src, row, now)
    TriggerClientEvent('crimson-hitman:locationTip', src, {
        id = row.contract_id, x = tonumber(row.centre_x), y = tonumber(row.centre_y),
        radius = tonumber(row.radius),
        secondsLeft = math.max(0, (tonumber(row.expires_at) or 0) - now),
    })
end

--- Take the tip on this contract off this player's map, if they are here.
local function clearFor(cid, contractId)
    local actor = Identity.byCitizenId(cid)
    if not actor then return false end
    TriggerClientEvent('crimson-hitman:locationTipClear', actor.source, { id = contractId })
    return true
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

--- Give a tip's price back. One that cannot be credited is left for staff.
local function refund(actor, account, cost, contractId, why)
    if cost <= 0 then return true end
    local credited, raised = Util.credit(actor.player, account, cost)
    if credited then
        Audit.financial('location_tip_refunded', actor.cid, contractId,
            { amount = cost, account = account, reason = why })
        return true
    end
    Audit.financial('location_tip_refund_failed', actor.cid, contractId,
        { amount = cost, account = account, reason = why, error = raised })
    if Review then
        pcall(Review.open, { kind = 'location_tip_refund_failed', contract_id = contractId,
            cids = { payer = actor.cid }, amount = cost, account = account,
            known = { reason = why, error = raised } })
    end
    return false
end

local buyUnlocked

--- Buy an informant tip on a contract, one purchase at a time per contract
--- and buyer: a second tap while one runs is refused as busy, before
--- anything is read or charged.
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
    if not Contracts then return buyUnlocked(actor, contractId, shown) end
    return Contracts.serialized({ 'locationTip:' .. contractId .. ':' .. tostring(actor.cid) },
        buyUnlocked, actor, contractId, shown)
end

buyUnlocked = function(actor, contractId, shown)
    -- Read once: the figure checked against the quote is the figure charged.
    local cost = math.max(0, setting('Cost', 0))
    local account = Config.LocationTip.Account
    local radius = math.max(1, setting('RadiusMeters', 350))
    local most = setting('MaxPurchasesPerContract', 0)
    local wait = math.max(0, setting('CooldownMinutes', 0)) * 60
    local show = math.max(1, setting('ShowMinutes', 10)) * 60

    -- Who may: a hitman holding the contract, and nobody else. Not found and
    -- not theirs are the same answer, so an id cannot be tried for whether
    -- it exists.
    local contract = Storage.readContract(contractId)
    if not contract or contract.target_cid == actor.cid then return false, CH.ERR.NOT_FOUND end
    local mine = Storage.readHitman(contractId, actor.cid)
    if not mine or mine.state ~= 'active' then return false, CH.ERR.NOT_PARTICIPANT end
    if contract.state ~= CH.STATE.ACTIVE and contract.state ~= CH.STATE.ACCEPTED then
        return false, CH.ERR.ALREADY_SETTLED
    end
    -- Off for this contract (a target on a whitelisted job reads its own
    -- switch): refused before anything is charged.
    if not LocationTip.enabled(contract) then return false, CH.ERR.FEATURE_OFF end
    -- On hold by staff (server/freeze.lua): nothing is charged.
    if Contracts and Contracts.heldByStaff and Contracts.heldByStaff(contract) then
        return false, CH.ERR.CONTRACT_FROZEN
    end

    local now = os.time()
    local count, newest = boughtBy(contractId, actor.cid, now)
    if count >= most then return false, CH.ERR.LIMIT_REACHED, { most = most } end
    local untilAt = newest and ((tonumber(newest.bought_at) or 0) + wait) or 0
    if untilAt > now then
        return false, CH.ERR.TIP_COOLDOWN, { untilAt = untilAt, retryAfter = untilAt - now }
    end

    -- The price the page quoted, as the informant's is: one raised from the
    -- admin panel while the button was armed is refused, with the price now.
    if shown ~= nil and cost > 0 then
        local quoted = type(shown) == 'table' and shown or {}
        if tonumber(quoted.cost) ~= cost or quoted.account ~= account then
            return false, CH.ERR.TERMS_CHANGED, { cost = cost, account = account }
        end
    end

    -- The target in the city, where the server sees them now.
    local target = Identity.byCitizenId(contract.target_cid)
    local x, y
    if target then x, y = positionOf(target.source) end
    if not x then return false, CH.ERR.TIP_TARGET_AWAY end

    -- And the contract and this hitman read again, with nothing between this
    -- and the charge: every read above is an await on mysql.
    local open, err = stillOn(contractId, actor.cid)
    if not open then return false, err end

    if not Util.charge(actor.player, account, cost) then
        return false, CH.ERR.INSUFFICIENT, { cost = cost, account = account }
    end

    local cx, cy = LocationTip.areaAround(x, y, radius)
    local row = {
        id = ('%s:%s:%03d'):format(contractId, actor.cid, count + 1),
        contract_id = contractId, buyer_cid = actor.cid,
        bought_at = now, expires_at = now + show,
        centre_x = cx, centre_y = cy, radius = radius,
        target_told = Config.LocationTip.NotifyTarget ~= false,
    }

    -- Kept, then the contract read once more: one that ended while the row
    -- was written, or a hitman taken off it, is refunded, as is a write that
    -- raised. Nothing is delivered until all of it stands.
    local kept, why = pcall(function()
        Storage.writeLocationTip(row)
        local rows = rowsFor(contractId)
        rows[#rows + 1] = row
        return true
    end)
    local stands, refusal = false, CH.ERR.SERVER_ERROR
    if kept then
        local read, ok, err2 = pcall(stillOn, contractId, actor.cid)
        stands = read and ok == true
        refusal = read and err2 or CH.ERR.SERVER_ERROR
    else
        Log.debug(('informant tip on %s: the store would not keep it: %s')
            :format(contractId, tostring(why)))
    end
    if not stands then
        forget(row)
        pcall(Storage.deleteLocationTip, row.id)
        refund(actor, account, cost, contractId, kept and 'contract_ended' or 'not_kept')
        return false, refusal
    end

    -- Audited with what was paid and by whom; never the area or the position.
    Audit.financial('location_tip_bought', actor.cid, contractId,
        { amount = cost, account = account })

    deliver(actor.source, row, now)
    armClear(row)

    if row.target_told and Notify.locationTipped then
        pcall(Notify.locationTipped, contract, LocationTip.TARGET_TITLE, LocationTip.TARGET_TEXT)
    end
    -- A member of a whitelisted job: law enforcement is told a hitman is
    -- closing in (Config.Advisory.OnLocationTip). Never who, never where.
    if Notify.tipAdvisory then pcall(Notify.tipAdvisory, contract) end

    return {
        secondsLeft = show, expiresAt = row.expires_at,
        left = math.max(0, most - (count + 1)),
        cooldownUntil = wait > 0 and (now + wait) or nil,
    }
end

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
--- many they have left, when the next may be bought, the one showing now,
--- and whether the target is in the city to be found. Their own rows only.
--- nil where the server sells none and none is showing.
---@param contract table
---@param cid string
---@return table|nil
function LocationTip.cardFor(contract, cid)
    if CH.TERMINAL[contract.state] then return nil end
    local now = os.time()
    local count, newest, showing = boughtBy(contract.id, cid, now)
    local on = LocationTip.enabled(contract)
    -- Off for this contract while the server sells them elsewhere: said, so
    -- the card draws no button.
    if not on and not showing then
        return LocationTip.enabled() and { off = true } or nil
    end
    local out = { off = (not on) or nil }
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
        if row.target_told == true or row.target_told == 1 then
            local bought = tonumber(row.bought_at)
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
