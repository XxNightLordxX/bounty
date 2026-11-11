CrimsonBoot.define('server.intel.rules', function() --- The Intel rules (Config.Intel, README "Intel"): five rules over the
--- informant tip (server/intel/tip.lua) and the target's informant
--- (server/intel/informants.lua), and going dark, the counter-product sold
--- through the engine (server/intel/engine.lua). Each is its own block in
--- Config.Intel and each ships off; off, it changes nothing and those
--- products behave as they did before it.
---
---   WarningDelay        the target's "someone knows your rough area" notice
---                       waits a random MinSeconds..MaxSeconds. The wait is
---                       kept in the store (crimson_rp_rows, kind
---                       'imp_tipwarn'), so a restart sends it late, never
---                       loses it. Their card's time is rounded to 5 minutes.
---   TipLimits           each hitman one tip per contract, and/or each tip
---                       on a contract twice the last one's price, capped at
---                       MaxCost. On top of the tip's own limits.
---   HoldFirst           a tip only once the hitman has held the contract
---                       MinHeldMinutes.
---   SecondTry           the target's look-ups after the first cost
---                       SecondTryCostPercent of Config.Intel.Informant.Cost.
---   SafeZones           no tip while the target stands in one of the zones:
---                       refused before any charge, in words that say
---                       neither why nor where.
---   GoDark              a target told of a tip pays to go dark for Minutes:
---                       every tip bought on them meanwhile finds nothing and
---                       is given back in full. Kept in the store (kind
---                       'imp_dark').
---
--- Every price here is read on the server, quoted on the card the page
--- draws, and checked against the page's echo before anything is charged
--- (TERMS_CHANGED otherwise), as the modules it extends do.

local Util = CrimsonBoot.requireShared('util')
local Holds = CrimsonBoot.require('server.holds')
local Log = CrimsonBoot.requireShared('log')
local Db = CrimsonBoot.require('server.lib.db')
local Feature = CrimsonBoot.require('server.lib.feature')
local L = CrimsonBoot.requireShared('locale').t
-- The one purchase engine (server/intel/engine.lua): going dark is bought
-- through it, and every notice here sent through it.
local Intel = CrimsonBoot.require('server.intel.engine')
--- This module's products (Intel.define), set below.
local DARK

local IntelRules = {}

local Storage, Audit, Notify, Contracts, LocationTip, Informant, Bailout

IntelRules.KIND_WARN = 'imp_tipwarn'
IntelRules.KIND_DARK = 'imp_dark'

--- The step a target's "tipped off at" is rounded down to while the warning
--- is delayed: the minute it was bought would give the delay away.
IntelRules.ROUND_SECONDS = 300

--- What a hitman is told: the target in a safe zone (never which, nor that
--- it is one), and the target gone dark.
IntelRules.CANT_PLACE = L('intel_rules.your_informant_cant_place_them_right')
IntelRules.NOT_FOUND = L('intel_rules.your_informant_couldnt_find_them')

--- The pending warnings, [tip id] = row { id, kind, contract_id, tip_id,
--- due_at }, and the timers sending them.
local pending, timers = {}, {}
--- Who has gone dark, [target cid] = row { id, kind, cid, until_at, bought_at,
--- contract_id }.
local dark = {}
local loaded = false
--- The time holds took, given back before this module was started
--- (IntelRules.heldBack from the restart hold's give-back at the start, which
--- runs before IntelRules.init): { contractId, from, to }, applied by init.
local heldQueue = {}
local heldOver

--- Uniform [0, 1), replaceable by a test that needs a known draw.
IntelRules.random = math.random

function IntelRules.init(deps)
    Storage, Audit = deps.storage, deps.audit
    Notify, Contracts = deps.notify, deps.contracts
    LocationTip, Informant = deps.locationTip, deps.informant
    Bailout = deps.bailout
    for _, timer in pairs(timers) do
        if type(ClearTimeout) == 'function' then pcall(ClearTimeout, timer) end
    end
    pending, timers, dark, loaded = {}, {}, {}, false
    if deps.projection and deps.projection.extenders then
        deps.projection.extenders.intelRules = function(out, contract, viewerCid, role)
            if role == 'target' then IntelRules.targetCard(out, contract, viewerCid) end
        end
    end
    -- What the start's give-back asked for before this was started.
    local waiting = heldQueue
    heldQueue = {}
    for i = 1, #waiting do
        local gave, err = pcall(IntelRules.heldBack, waiting[i][1], waiting[i][2], waiting[i][3])
        if not gave then
            Log.always(('contract %s: the paid windows the restart hold took could not be given back (%s)')
                :format(tostring(waiting[i][1]), Util.dbError(err)))
        end
    end
end

--------------------------------------------------------------------------
-- The settings
--------------------------------------------------------------------------

--- One safe zone, 'x, y, radius, name': its centre, radius and name, or nil.
---@param text any
---@return table|nil { x, y, radius, name }
function IntelRules.parseZone(text)
    if type(text) ~= 'string' or #text > 80 or text:find('[%c<>]') then return nil end
    local x, y, r, name = text:match('^%s*(%-?%d+%.?%d*)%s*,%s*(%-?%d+%.?%d*)%s*,%s*(%d+%.?%d*)%s*,%s*(.-)%s*$')
    x, y, r = tonumber(x), tonumber(y), tonumber(r)
    if not x or not r or r <= 0 or r > 5000 or not name or name == '' then return nil end
    return { x = x, y = y, radius = r, name = name }
end

--- Every block and its fields, as the start and the admin panel check them.
IntelRules.RULES = {
    WarningDelay = {
        Enabled = { kind = 'switch' },
        MinSeconds = { kind = 'number', min = 0, max = 3600, integer = true },
        MaxSeconds = { kind = 'number', min = 0, max = 3600, integer = true },
    },
    TipLimits = {
        Enabled = { kind = 'switch' },
        OnePerHitman = { kind = 'switch' },
        PriceDoubling = { kind = 'switch' },
        MaxCost = { kind = 'number', min = 0, max = 10000000, integer = true },
    },
    HoldFirst = {
        Enabled = { kind = 'switch' },
        MinHeldMinutes = { kind = 'number', min = 0, max = 1440, integer = true },
    },
    SecondTry = {
        Enabled = { kind = 'switch' },
        SecondTryCostPercent = { kind = 'number', min = 0, max = 1000, integer = true },
    },
    SafeZones = {
        Enabled = { kind = 'switch' },
        Zones = { kind = 'list', each = IntelRules.parseZone, says = L('intel_rules.a_list_of_x_y_radius') },
    },
    GoDark = {
        Enabled = { kind = 'switch' },
        Cost = { kind = 'number', min = 0, max = 10000000, integer = true },
        Account = { kind = 'choice', choices = { 'bank', 'cash' } },
        Minutes = { kind = 'number', min = 1, max = 1440, integer = true },
    },
}

--- Fill a block config.lua has none of from the shipped one, and hold every
--- field to its rule: one that does not fit is put back to what ships, with
--- a warning naming it. Run at the start and on the admin panel's quiet
--- check of a change, as main.lua runs every other check.
---@param warn string[]
function IntelRules.validate(warn)
    local names = {}
    for name in pairs(IntelRules.RULES) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        Feature.check('Intel.' .. name, IntelRules.RULES[name], warn)
    end
    local delay = Config.Intel.WarningDelay
    if delay.MinSeconds > delay.MaxSeconds then
        warn[#warn + 1] = L('intel_rules.intel_warningdelay_minseconds_is_above_maxseconds')
        delay.MinSeconds = delay.MaxSeconds
    end
end

local function int(value, fallback)
    local n = tonumber(value)
    if not n or n ~= n then return fallback end
    return math.floor(n)
end

--------------------------------------------------------------------------
-- The store
--------------------------------------------------------------------------

--- Read the pending warnings and the dark targets once, at the start or
--- the first use; a read that raises is tried again at the next use.
local function load()
    if loaded or not Storage or not Storage.readRpRows then return end
    local okW, warns = pcall(Storage.readRpRows, IntelRules.KIND_WARN)
    local okD, darks = pcall(Storage.readRpRows, IntelRules.KIND_DARK)
    if not okW or not okD or type(warns) ~= 'table' or type(darks) ~= 'table' then return end
    loaded = true
    for _, row in ipairs(warns) do
        if row.tip_id then pending[row.tip_id] = row end
    end
    for _, row in ipairs(darks) do
        -- A row still pending was written for a purchase that never
        -- finished (IntelRules.goDark): its charge was refused or never made,
        -- or the write that confirms it did not go through and the price
        -- was given back. Nobody paid for it, so nobody is dark by it.
        if row.pending then
            pcall(Storage.deleteRpRow, row.id)
        elseif row.cid then
            dark[row.cid] = row
        end
    end
end

--------------------------------------------------------------------------
-- F1: the target's warning, delayed
--------------------------------------------------------------------------

--- Send one waiting warning, then take it out of the store: in that order,
--- so a stop between the two sends it again after the restart rather than
--- never. Taken out of memory first, so this process sends it once.
local function send(row)
    pending[row.tip_id] = nil
    timers[row.tip_id] = nil
    local ok, contract = pcall(Storage.readContract, row.contract_id)
    -- A contract that ended while the warning waited has nothing left to
    -- warn of: dropped. One that could not be read is kept for the next
    -- start, as a warning is never lost.
    if not ok then return end
    if contract and not CH.TERMINAL[contract.state] and Notify and Notify.locationTipped and LocationTip then
        Intel.tell('tipped', Notify, contract, LocationTip.TARGET_TITLE, LocationTip.TARGET_TEXT)
    end
    pcall(Storage.deleteRpRow, row.id)
end

local function arm(row)
    if timers[row.tip_id] then return end
    local left = math.max(0, (tonumber(row.due_at) or 0) - os.time())
    timers[row.tip_id] = SetTimeout(left * 1000, function()
        local ok, err = pcall(send, row)
        if not ok then Log.debug(('tip warning %s: %s'):format(tostring(row.id), tostring(err))) end
    end)
end

--- Whether the warning is delayed now.
---@return boolean
function IntelRules.delayOn()
    return Feature.on('Intel.WarningDelay') and int(Feature.block('Intel.WarningDelay').MaxSeconds, 0) > 0
end

--- A tip was bought and the target is to be told. Off: `now` runs at once,
--- as before. On: the warning is kept with when it falls due, and sent then.
---@param contract table
---@param tip table the tip's row
---@param now function sends the warning at once
function IntelRules.warnTarget(contract, tip, now)
    if not IntelRules.delayOn() then return now() end
    load()
    local block = Feature.block('Intel.WarningDelay')
    local low = math.max(0, int(block.MinSeconds, 0))
    local high = math.max(low, int(block.MaxSeconds, 0))
    local wait = low + math.floor(IntelRules.random() * (high - low + 1))
    if wait > high then wait = high end
    local row = { id = ('iw:%s:%s'):format(contract.id, tostring(tip.id):match('(%d+)$') or '0'),
                  kind = IntelRules.KIND_WARN, contract_id = contract.id, tip_id = tip.id,
                  due_at = os.time() + wait }
    local kept = pcall(Storage.writeRpRow, row)
    if not kept then
        -- Never lost: a warning the store would not keep goes now.
        return now()
    end
    pending[tip.id] = row
    arm(row)
end

--- Whether a tip's warning is still waiting to be sent.
function IntelRules.waiting(tipId)
    load()
    return pending[tipId] ~= nil
end

--- The time a target's card gives for a tip: rounded down to 5 minutes
--- while the warning is delayed.
---@param at integer
---@return integer
function IntelRules.shownTime(at)
    if not IntelRules.delayOn() then return at end
    return at - (at % IntelRules.ROUND_SECONDS)
end

--- After a restart: every warning still waiting is sent when it falls due,
--- and one already past due at once.
function IntelRules.resume()
    load()
    for _, row in pairs(pending) do arm(row) end
end

--------------------------------------------------------------------------
-- F2, F3, F5: the tip's own rules
--------------------------------------------------------------------------

--- The price of the next tip on a contract that has `count` already.
---@param base integer Config.Intel.LocationTip.Cost
---@param count integer
---@return integer
function IntelRules.tipPrice(base, count)
    local block = Feature.block('Intel.TipLimits')
    if block.Enabled ~= true or block.PriceDoubling ~= true or base <= 0 then return base end
    local cap = math.max(base, int(block.MaxCost, base))
    local price = base
    for _ = 1, math.max(0, count) do
        price = price * 2
        if price >= cap then return cap end
    end
    return price
end

--- Whether this hitman has had their one tip on the contract.
---@param ownCount integer their tips on it
---@return boolean
function IntelRules.usedOwn(ownCount)
    local block = Feature.block('Intel.TipLimits')
    return block.Enabled == true and block.OnePerHitman == true and ownCount >= 1
end

--- Seconds this hitman still has to hold the contract before a tip; 0 when
--- they may buy one.
---@param mine table their hitman row
---@param now integer
---@return integer
function IntelRules.holdLeft(mine, now)
    if not Feature.on('Intel.HoldFirst') then return 0 end
    local need = math.max(0, int(Feature.block('Intel.HoldFirst').MinHeldMinutes, 0)) * 60
    local since = tonumber(mine and mine.accepted_at)
    if need <= 0 or not since then return 0 end
    return math.max(0, since + need - now)
end

--- Whether a target standing at (x, y) is inside a safe zone.
---@return boolean
function IntelRules.inSafeZone(x, y)
    if not Feature.on('Intel.SafeZones') then return false end
    for _, text in ipairs(Feature.block('Intel.SafeZones').Zones or {}) do
        local zone = IntelRules.parseZone(text)
        if zone and (x - zone.x) ^ 2 + (y - zone.y) ^ 2 <= zone.radius ^ 2 then return true end
    end
    return false
end

--- What the hitman's own card adds: the next tip's price where it is not the
--- price the board quotes, the wait before they may buy one, and that they
--- have had their one.
---@param out table the card's locationTip
---@param contract table
---@param mine table|nil their hitman row
---@param count integer tips on the contract
---@param ownCount integer theirs
---@param now integer
function IntelRules.tipCard(out, contract, mine, count, ownCount, now)
    local base = math.max(0, int(Config.Intel.LocationTip.Cost, 0))
    local price = IntelRules.tipPrice(base, count)
    if price ~= base then out.cost = price end
    local hold = IntelRules.holdLeft(mine, now)
    if hold > 0 then
        out.holdSeconds = hold
        out.holdUntil = now + hold
    end
    if IntelRules.usedOwn(ownCount) then out.mineUsed = true end
end

--------------------------------------------------------------------------
-- F4: the target's informant, after the first look-up
--------------------------------------------------------------------------

--- The price of a target's look-up after `purchases` already made.
---@param base integer Config.Intel.Informant.Cost
---@param purchases integer
---@return integer
function IntelRules.informantPrice(base, purchases)
    if not Feature.on('Intel.SecondTry') or purchases < 1 or base <= 0 then return base end
    local percent = math.max(0, int(Feature.block('Intel.SecondTry').SecondTryCostPercent, 100))
    -- Whole dollars, integer arithmetic (no binary fraction of money).
    return (base * percent) // 100
end

--------------------------------------------------------------------------
-- F6: going dark
--------------------------------------------------------------------------

--- Until when a go-dark window that has run out on the wall clock still
--- stands, because the contract it was bought on is on hold now (a staff
--- freeze, the restart hold, the app pause) or a hold on it is being
--- released, its time not given back yet; nil when it does not. Read only
--- for a window past its end.
---@param row table
---@param now integer
---@return integer|nil
heldOver = function(row, now)
    if not (Storage and row.contract_id) then return nil end
    local read, contract = pcall(Storage.readContract, row.contract_id)
    if not read or not contract or CH.TERMINAL[contract.state] then return nil end
    local untilAt = tonumber(row.until_at) or 0
    if Holds.releasing() then return now + 1 end
    local since = Holds.since(contract)
    if not since then return nil end
    local start = math.max(since, tonumber(row.bought_at) or since)
    if start >= untilAt then return nil end
    return untilAt + math.max(0, now - start)
end

--- Whether a target has gone dark now, and until when.
---@param cid string
---@return integer|nil untilAt
function IntelRules.darkUntil(cid)
    load()
    local row = dark[cid]
    if not row then return nil end
    local now = os.time()
    local untilAt = tonumber(row.until_at) or 0
    if untilAt > now then return untilAt end
    -- Run out on the wall clock while the contract it was bought on is on
    -- hold: it stands still with the hold, whose end gives the time back
    -- (IntelRules.heldBack). Dark until then, and kept.
    local held = heldOver(row, now)
    if held then return held end
    dark[cid] = nil
    if Storage and Storage.deleteRpRow then pcall(Storage.deleteRpRow, row.id) end
    return nil
end

--- A hold on a contract has ended (server/holds.lua, giveBack): the
--- go-dark window bought on it, and the tips on it (LocationTip.heldBack),
--- given the time it stood still, from `from` (or when it was bought, if
--- later) to `to`. Only a window still running when the hold began.
--- Before this module is started (the restart hold's give-back at the
--- start), kept for init.
---@param contractId string
---@param from integer os.time()
---@param to integer os.time()
function IntelRules.heldBack(contractId, from, to)
    from, to = tonumber(from), tonumber(to)
    if not (contractId and from and to) or to <= from then return end
    if not Storage then
        heldQueue[#heldQueue + 1] = { contractId, from, to }
        return
    end
    load()
    local minutes = math.max(1, int(Feature.block('Intel.GoDark').Minutes, 30))
    for _, row in pairs(dark) do
        if row.contract_id == contractId then
            local untilAt = tonumber(row.until_at) or 0
            local start = math.max(from, tonumber(row.bought_at) or (untilAt - minutes * 60))
            if start < untilAt and to > start then
                row.until_at = untilAt + (to - start)
                Db.try('go dark: the time a hold took could not be kept (%s)', Storage.writeRpRow, row)
            end
        end
    end
    if LocationTip and LocationTip.heldBack then LocationTip.heldBack(contractId, from, to) end
end

local function goDarkTerms()
    local block = Feature.block('Intel.GoDark')
    return math.max(0, int(block.Cost, 0)), block.Account == 'cash' and 'cash' or 'bank',
        math.max(1, int(block.Minutes, 30))
end

--- What the target's own card adds: going dark, where it is sold to them
--- (a tip they were told of), with its terms, or until when they are dark;
--- and the price of their next look-up where it is not the board's.
---@param out table
---@param contract table
---@param cid string the target
function IntelRules.targetCard(out, contract, cid)
    if contract.target_cid ~= cid or CH.TERMINAL[contract.state] then return end
    -- Sold only while tips on this contract are (LocationTip.enabled: the
    -- master switch, its own, and a whitelisted-job target's): with tips
    -- switched off it hid the target from nobody, and was charged all the
    -- same. A window already paid for is still shown to its end, whichever
    -- switch is off now: it holds whatever the switches say (targetDark).
    local untilAt = IntelRules.darkUntil(cid)
    if Feature.on('Intel.GoDark') and out.tippedAt and LocationTip and LocationTip.enabled(contract) then
        local cost, account, minutes = goDarkTerms()
        out.goDark = { cost = cost, account = account, minutes = minutes, untilAt = untilAt }
    elseif untilAt then
        out.goDark = { untilAt = untilAt }
    end
    if Feature.on('Intel.SecondTry') and Informant and Informant.purchasesBy and out.informantPicks then
        local base = math.max(0, int(Config.Intel.Informant.Cost, 0))
        local price = IntelRules.informantPrice(base, Informant.purchasesBy(contract.id, cid))
        if price ~= base then out.informantCost = price end
    end
end

--- The services a purchase runs with (server/intel/engine.lua, Intel.buy):
--- this module's. A refund that cannot be credited is owed (and handed
--- over at the next login).
local function services()
    return { storage = Storage, audit = Audit, contracts = Contracts, bailout = Bailout }
end

--- A target told of a tip on a contract on them pays to go dark: every tip
--- bought on them for Minutes finds nothing and is given back. One purchase
--- at a time per target; refused while they are dark already.
---@param actor table
---@param contractId any
---@param shown table|nil the page's echo of the price, { cost, account }
---@return table|false result { untilAt, minutes }
---@return string|nil err
---@return table|nil data
function IntelRules.goDark(actor, contractId, shown)
    if not Feature.on('Intel.GoDark') then return false, CH.ERR.FEATURE_OFF end
    contractId = Util.toId(contractId)
    if not contractId then return false, CH.ERR.INVALID_INPUT end
    return Intel.buy(DARK, services(), actor, contractId, shown)
end

--- Tips switched off on this contract (the master switch, their own, or a
--- whitelisted-job target's): nobody can buy one, so going dark hides them
--- from nothing.
local function tipsSold(contract)
    if not (LocationTip and LocationTip.enabled(contract)) then return CH.ERR.FEATURE_OFF end
    return nil
end

DARK = Intel.define('goDark', {
    terms = function(ctx)
        ctx.cost, ctx.account, ctx.minutes = goDarkTerms()
    end,
    steps = {
        -- Theirs, still open, and not on hold by staff (server/holds.lua):
        -- no money moves on it. Refused before anything is charged.
        'party', 'open', 'holds',
        function(ctx) return tipsSold(ctx.contract) end,
        function(ctx)
            if not LocationTip.toldAt(ctx.contractId) then return CH.ERR.NOT_TIPPED end
            local already = IntelRules.darkUntil(ctx.actor.cid)
            if already then return CH.ERR.ALREADY_DARK, { untilAt = already } end
            return nil
        end,
    },
    ready = function(ctx)
        local contractId, actor = ctx.contractId, ctx.actor
        -- Read again with nothing between this and the charge.
        local now = Storage.readContract(contractId)
        if not now or CH.TERMINAL[now.state] then return CH.ERR.ALREADY_SETTLED end
        local off = tipsSold(now)
        if off then return off end
        if Holds.on(now, nil, 'staff') then return CH.ERR.CONTRACT_FROZEN end

        -- Kept first as pending, so a charge never stands without a row;
        -- then charged; then confirmed. A pending row darkens nobody, here
        -- or after a restart (load drops it): written as the purchase
        -- itself, a write that raised but landed late left the target dark
        -- for nothing once the server restarted. Counted as dark only once
        -- paid and confirmed.
        local untilAt = os.time() + ctx.minutes * 60
        local row = { id = 'dk:' .. actor.cid, kind = IntelRules.KIND_DARK, cid = actor.cid, until_at = untilAt,
                      bought_at = os.time(), contract_id = contractId, pending = true }
        local kept = pcall(Storage.writeRpRow, row)
        if not kept then
            pcall(Storage.deleteRpRow, row.id)
            return CH.ERR.SERVER_ERROR
        end
        ctx.row, ctx.untilAt = row, untilAt
        return nil
    end,
    uncharged = function(ctx) pcall(Storage.deleteRpRow, ctx.row.id) end,
    -- A purchase a crash caught after the charge is kept where its window
    -- was confirmed, refunded where it is still pending or gone
    -- (Intel.decideUnrecorded; load drops the pending row).
    intent = function(ctx) return { row = ctx.row.id, at = ctx.row.bought_at } end,
    recorded = function(_, _, mark)
        for _, r in ipairs(Storage.readRpRows(IntelRules.KIND_DARK) or {}) do
            if r.id == mark.row and not r.pending and tonumber(r.bought_at) == tonumber(mark.at) then
                return true
            end
        end
        return false
    end,
    confirm = function(ctx)
        local row = ctx.row
        -- And read once more: the row's write and the charge are awaits on
        -- mysql, and a staff hold or an ending that landed in them moves no
        -- money. The window is dropped and the price given back, once.
        local read, after = pcall(Storage.readContract, ctx.contractId)
        local refusal
        if not read then
            refusal = CH.ERR.SERVER_ERROR
        elseif not after or CH.TERMINAL[after.state] then
            refusal = CH.ERR.ALREADY_SETTLED
        elseif Holds.on(after, nil, 'staff') then
            refusal = CH.ERR.CONTRACT_FROZEN
        end
        if not refusal then
            -- Confirmed: the purchase stands from here. A confirm that
            -- raised may still land, so the row is taken away as well as the
            -- price given back; one landing after the delete is the store's
            -- own ordering, and leaves at most the window it was written for.
            row.pending = nil
            if not Db.try('go dark: the purchase could not be kept by the store (%s); the price is given back',
                Storage.writeRpRow, row) then
                refusal = CH.ERR.SERVER_ERROR
            end
        end
        if refusal then
            pcall(Storage.deleteRpRow, row.id)
            return false, refusal, nil, refusal
        end
        return true
    end,
    deliver = function(ctx)
        local row, actor = ctx.row, ctx.actor
        load()
        dark[actor.cid] = row
        Audit.financial('go_dark_bought', actor.cid, ctx.contractId, { amount = ctx.cost, account = ctx.account,
            minutes = ctx.minutes })
        if Notify then Intel.tell('push', Notify, actor.cid, 'tip', ctx.contractId) end
        return { untilAt = ctx.untilAt, minutes = ctx.minutes }
    end,
})
--- The most go-dark rows one prune takes out of the store.
IntelRules.PRUNES_PER_PASS = 25

--- Take out of the store the go-dark windows that have passed (the board's
--- minute, record.tick). darkUntil drops one only when somebody asks
--- about that target again, and once the contract it was bought on had
--- ended nobody did: the row was kept for good. A window still running is
--- kept, whatever became of the contract: it was paid for. From memory, so
--- a pass with nothing past its time reads and writes nothing, and at most
--- PRUNES_PER_PASS deletes a pass. Runs with the switch off too.
---@return integer pruned
function IntelRules.prune()
    -- Loaded at the start (IntelRules.resume); a start whose read raised is
    -- tried again here, or the windows from before it were never pruned.
    if not loaded then load() end
    if not loaded or next(dark) == nil then return 0 end
    local now, gone = os.time(), {}
    for cid, row in pairs(dark) do
        -- Not one standing still with a hold on its contract (heldOver).
        if (tonumber(row.until_at) or 0) <= now and not heldOver(row, now) then
            gone[#gone + 1] = cid
            if #gone >= IntelRules.PRUNES_PER_PASS then break end
        end
    end
    for i = 1, #gone do
        local row = dark[gone[i]]
        dark[gone[i]] = nil
        if Storage and Storage.deleteRpRow then pcall(Storage.deleteRpRow, row.id) end
    end
    return #gone
end

--- Whether a tip bought now on this target finds nothing (they went dark).
--- A window paid for holds to its end even if the switch is turned off.
---@param targetCid string
---@return boolean
function IntelRules.targetDark(targetCid)
    return IntelRules.darkUntil(targetCid) ~= nil
end

return IntelRules
end)
