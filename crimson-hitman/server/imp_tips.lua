--- Informant fairness (README, Optional features), six rules over the
--- informant tip (server/locationtip.lua) and the target's informant
--- (server/informant.lua). Each is its own block in Config.Improvements and
--- each ships off; off, it changes nothing and those modules behave as they
--- did before it.
---
---   TipWarningDelay     the target's "someone knows your rough area" notice
---                       waits a random MinSeconds..MaxSeconds. The wait is
---                       kept in the store (crimson_rp_rows, kind
---                       'imp_tipwarn'), so a restart sends it late, never
---                       loses it. Their card's time is rounded to 5 minutes.
---   TipLimits           each hitman one tip per contract, and/or each tip
---                       on a contract twice the last one's price, capped at
---                       MaxCost. On top of the tip's own limits.
---   TipHoldFirst        a tip only once the hitman has held the contract
---                       MinHeldMinutes.
---   InformantSecondTry  the target's look-ups after the first cost
---                       SecondTryCostPercent of Config.Informant.Cost.
---   TipSafeZones        no tip while the target stands in one of the zones:
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
local Log = CrimsonBoot.requireShared('log')

local ImpTips = {}

local Storage, Audit, Notify, Contracts, LocationTip, Informant

ImpTips.KIND_WARN = 'imp_tipwarn'
ImpTips.KIND_DARK = 'imp_dark'

--- The step a target's "tipped off at" is rounded down to while the warning
--- is delayed: the minute it was bought would give the delay away.
ImpTips.ROUND_SECONDS = 300

--- What a hitman is told: the target in a safe zone (never which, nor that
--- it is one), and the target gone dark.
ImpTips.CANT_PLACE = "Your informant can't place them right now."
ImpTips.NOT_FOUND = "Your informant couldn't find them."

--- The pending warnings, [tip id] = row { id, kind, contract_id, tip_id,
--- due_at }, and the timers sending them.
local pending, timers = {}, {}
--- Who has gone dark, [target cid] = row { id, kind, cid, until_at }.
local dark = {}
local loaded = false

--- Uniform [0, 1), replaceable by a test that needs a known draw.
ImpTips.random = math.random

function ImpTips.init(deps)
    Storage, Audit = deps.storage, deps.audit
    Notify, Contracts = deps.notify, deps.contracts
    LocationTip, Informant = deps.locationTip, deps.informant
    for _, timer in pairs(timers) do
        if type(ClearTimeout) == 'function' then pcall(ClearTimeout, timer) end
    end
    pending, timers, dark, loaded = {}, {}, {}, false
    if deps.projection and deps.projection.extenders then
        deps.projection.extenders.impTips = function(out, contract, viewerCid, role)
            if role == 'target' then ImpTips.targetCard(out, contract, viewerCid) end
        end
    end
end

--------------------------------------------------------------------------
-- The settings
--------------------------------------------------------------------------

--- Every block and its fields, as the start and the admin panel check them.
ImpTips.RULES = {
    TipWarningDelay = {
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
    TipHoldFirst = {
        Enabled = { kind = 'switch' },
        MinHeldMinutes = { kind = 'number', min = 0, max = 1440, integer = true },
    },
    InformantSecondTry = {
        Enabled = { kind = 'switch' },
        SecondTryCostPercent = { kind = 'number', min = 0, max = 1000, integer = true },
    },
    TipSafeZones = {
        Enabled = { kind = 'switch' },
        Zones = { kind = 'zones' },
    },
    GoDark = {
        Enabled = { kind = 'switch' },
        Cost = { kind = 'number', min = 0, max = 10000000, integer = true },
        Account = { kind = 'choice', choices = { 'bank', 'cash' } },
        Minutes = { kind = 'number', min = 1, max = 1440, integer = true },
    },
}

--- One safe zone, 'x, y, radius, name': its centre, radius and name, or nil.
---@param text any
---@return table|nil { x, y, radius, name }
function ImpTips.parseZone(text)
    if type(text) ~= 'string' or #text > 80 or text:find('[%c<>]') then return nil end
    local x, y, r, name = text:match('^%s*(%-?%d+%.?%d*)%s*,%s*(%-?%d+%.?%d*)%s*,%s*(%d+%.?%d*)%s*,%s*(.-)%s*$')
    x, y, r = tonumber(x), tonumber(y), tonumber(r)
    if not x or not r or r <= 0 or r > 5000 or not name or name == '' then return nil end
    return { x = x, y = y, radius = r, name = name }
end

local function fits(rule, value)
    if rule.kind == 'switch' then return type(value) == 'boolean' end
    if rule.kind == 'number' then
        if type(value) ~= 'number' or value ~= value then return false end
        if rule.integer and math.floor(value) ~= value then return false end
        return value >= rule.min and value <= rule.max
    end
    if rule.kind == 'choice' then
        for _, choice in ipairs(rule.choices) do if value == choice then return true end end
        return false
    end
    if type(value) ~= 'table' or #value > 50 then return false end
    for k in pairs(value) do
        if math.type(k) ~= 'integer' or k < 1 or k > #value then return false end
    end
    for _, entry in ipairs(value) do
        if not ImpTips.parseZone(entry) then return false end
    end
    return true
end

local function says(rule)
    if rule.kind == 'switch' then return 'true or false' end
    if rule.kind == 'number' then
        return ('a whole number from %d to %d'):format(rule.min, rule.max)
    end
    if rule.kind == 'choice' then return 'one of ' .. table.concat(rule.choices, ', ') end
    return "a list of 'x, y, radius, name'"
end

--- A deep copy (Util.copy, the one shared copy).
local copyOf = Util.copy

--- Fill a block config.lua has none of from the shipped one, and hold every
--- field to its rule: one that does not fit is put back to what ships, with
--- a warning naming it. Run at the start and on the admin panel's quiet
--- check of a change, as main.lua runs every other check.
---@param warn string[]
function ImpTips.validate(warn)
    if type(Config.Improvements) ~= 'table' then Config.Improvements = {} end
    local shippedRoot = type(ConfigDefaults) == 'table' and ConfigDefaults.Improvements or nil
    local names = {}
    for name in pairs(ImpTips.RULES) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local shipped = type(shippedRoot) == 'table' and type(shippedRoot[name]) == 'table'
            and shippedRoot[name] or {}
        if type(Config.Improvements[name]) ~= 'table' then Config.Improvements[name] = copyOf(shipped) end
        local block = Config.Improvements[name]
        local fields = {}
        for field in pairs(ImpTips.RULES[name]) do fields[#fields + 1] = field end
        table.sort(fields)
        for _, field in ipairs(fields) do
            local rule = ImpTips.RULES[name][field]
            if not fits(rule, block[field]) then
                local fallback = shipped[field]
                if fallback == nil then
                    if rule.kind == 'switch' then fallback = false
                    elseif rule.kind == 'zones' then fallback = {}
                    elseif rule.kind == 'choice' then fallback = rule.choices[1]
                    else fallback = rule.min end
                end
                if block[field] ~= nil then
                    warn[#warn + 1] = ('Improvements.%s.%s has to be %s. Using what ships.')
                        :format(name, field, says(rule))
                end
                block[field] = copyOf(fallback)
            end
        end
    end
    local delay = Config.Improvements.TipWarningDelay
    if delay.MinSeconds > delay.MaxSeconds then
        warn[#warn + 1] = 'Improvements.TipWarningDelay.MinSeconds is above MaxSeconds. Using MaxSeconds for both.'
        delay.MinSeconds = delay.MaxSeconds
    end
end

local function cfg(name)
    local root = type(Config.Improvements) == 'table' and Config.Improvements or {}
    return type(root[name]) == 'table' and root[name] or {}
end
ImpTips.cfg = cfg

---@return boolean
function ImpTips.on(name)
    return cfg(name).Enabled == true
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
    local okW, warns = pcall(Storage.readRpRows, ImpTips.KIND_WARN)
    local okD, darks = pcall(Storage.readRpRows, ImpTips.KIND_DARK)
    if not okW or not okD or type(warns) ~= 'table' or type(darks) ~= 'table' then return end
    loaded = true
    for _, row in ipairs(warns) do
        if row.tip_id then pending[row.tip_id] = row end
    end
    for _, row in ipairs(darks) do
        if row.cid then dark[row.cid] = row end
    end
end

--------------------------------------------------------------------------
-- F1: the target's warning, delayed
--------------------------------------------------------------------------

local function send(row)
    pending[row.tip_id] = nil
    timers[row.tip_id] = nil
    pcall(Storage.deleteRpRow, row.id)
    local ok, contract = pcall(Storage.readContract, row.contract_id)
    -- A contract that ended while the warning waited has nothing left to
    -- warn of: dropped.
    if not ok or not contract or CH.TERMINAL[contract.state] then return end
    if Notify and Notify.locationTipped and LocationTip then
        pcall(Notify.locationTipped, contract, LocationTip.TARGET_TITLE, LocationTip.TARGET_TEXT)
    end
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
function ImpTips.delayOn()
    return ImpTips.on('TipWarningDelay') and int(cfg('TipWarningDelay').MaxSeconds, 0) > 0
end

--- A tip was bought and the target is to be told. Off: `now` runs at once,
--- as before. On: the warning is kept with when it falls due, and sent then.
---@param contract table
---@param tip table the tip's row
---@param now function sends the warning at once
function ImpTips.warnTarget(contract, tip, now)
    if not ImpTips.delayOn() then return now() end
    load()
    local block = cfg('TipWarningDelay')
    local low = math.max(0, int(block.MinSeconds, 0))
    local high = math.max(low, int(block.MaxSeconds, 0))
    local wait = low + math.floor(ImpTips.random() * (high - low + 1))
    if wait > high then wait = high end
    local row = { id = ('iw:%s:%s'):format(contract.id, tostring(tip.id):match('(%d+)$') or '0'),
                  kind = ImpTips.KIND_WARN, contract_id = contract.id, tip_id = tip.id,
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
function ImpTips.waiting(tipId)
    load()
    return pending[tipId] ~= nil
end

--- The time a target's card gives for a tip: rounded down to 5 minutes
--- while the warning is delayed.
---@param at integer
---@return integer
function ImpTips.shownTime(at)
    if not ImpTips.delayOn() then return at end
    return at - (at % ImpTips.ROUND_SECONDS)
end

--- After a restart: every warning still waiting is sent when it falls due,
--- and one already past due at once.
function ImpTips.resume()
    load()
    for _, row in pairs(pending) do arm(row) end
end

--------------------------------------------------------------------------
-- F2, F3, F5: the tip's own rules
--------------------------------------------------------------------------

--- The price of the next tip on a contract that has `count` already.
---@param base integer Config.LocationTip.Cost
---@param count integer
---@return integer
function ImpTips.tipPrice(base, count)
    local block = cfg('TipLimits')
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
function ImpTips.usedOwn(ownCount)
    local block = cfg('TipLimits')
    return block.Enabled == true and block.OnePerHitman == true and ownCount >= 1
end

--- Seconds this hitman still has to hold the contract before a tip; 0 when
--- they may buy one.
---@param mine table their hitman row
---@param now integer
---@return integer
function ImpTips.holdLeft(mine, now)
    if not ImpTips.on('TipHoldFirst') then return 0 end
    local need = math.max(0, int(cfg('TipHoldFirst').MinHeldMinutes, 0)) * 60
    local since = tonumber(mine and mine.accepted_at)
    if need <= 0 or not since then return 0 end
    return math.max(0, since + need - now)
end

--- Whether a target standing at (x, y) is inside a safe zone.
---@return boolean
function ImpTips.inSafeZone(x, y)
    if not ImpTips.on('TipSafeZones') then return false end
    for _, text in ipairs(cfg('TipSafeZones').Zones or {}) do
        local zone = ImpTips.parseZone(text)
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
function ImpTips.tipCard(out, contract, mine, count, ownCount, now)
    local base = math.max(0, int(Config.LocationTip.Cost, 0))
    local price = ImpTips.tipPrice(base, count)
    if price ~= base then out.cost = price end
    local hold = ImpTips.holdLeft(mine, now)
    if hold > 0 then
        out.holdSeconds = hold
        out.holdUntil = now + hold
    end
    if ImpTips.usedOwn(ownCount) then out.mineUsed = true end
end

--------------------------------------------------------------------------
-- F4: the target's informant, after the first look-up
--------------------------------------------------------------------------

--- The price of a target's look-up after `purchases` already made.
---@param base integer Config.Informant.Cost
---@param purchases integer
---@return integer
function ImpTips.informantPrice(base, purchases)
    if not ImpTips.on('InformantSecondTry') or purchases < 1 or base <= 0 then return base end
    local percent = math.max(0, int(cfg('InformantSecondTry').SecondTryCostPercent, 100))
    -- Whole dollars, integer arithmetic (no binary fraction of money).
    return (base * percent) // 100
end

--------------------------------------------------------------------------
-- F6: going dark
--------------------------------------------------------------------------

--- Whether a target has gone dark now, and until when.
---@param cid string
---@return integer|nil untilAt
function ImpTips.darkUntil(cid)
    load()
    local row = dark[cid]
    if not row then return nil end
    local untilAt = tonumber(row.until_at) or 0
    if untilAt > os.time() then return untilAt end
    dark[cid] = nil
    if Storage and Storage.deleteRpRow then pcall(Storage.deleteRpRow, row.id) end
    return nil
end

local function goDarkTerms()
    local block = cfg('GoDark')
    return math.max(0, int(block.Cost, 0)), block.Account == 'cash' and 'cash' or 'bank',
        math.max(1, int(block.Minutes, 30))
end

--- What the target's own card adds: going dark, where it is sold to them
--- (a tip they were told of), with its terms, or until when they are dark;
--- and the price of their next look-up where it is not the board's.
---@param out table
---@param contract table
---@param cid string the target
function ImpTips.targetCard(out, contract, cid)
    if contract.target_cid ~= cid or CH.TERMINAL[contract.state] then return end
    if ImpTips.on('GoDark') and out.tippedAt then
        local cost, account, minutes = goDarkTerms()
        out.goDark = { cost = cost, account = account, minutes = minutes, untilAt = ImpTips.darkUntil(cid) }
    end
    if ImpTips.on('InformantSecondTry') and Informant and Informant.purchasesBy and out.informantPicks then
        local base = math.max(0, int(Config.Informant.Cost, 0))
        local price = ImpTips.informantPrice(base, Informant.purchasesBy(contract.id, cid))
        if price ~= base then out.informantCost = price end
    end
end

local buyDark

--- A target told of a tip on a contract on them pays to go dark: every tip
--- bought on them for Minutes finds nothing and is given back. One purchase
--- at a time per target; refused while they are dark already.
---@param actor table
---@param contractId any
---@param shown table|nil the page's echo of the price, { cost, account }
---@return table|false result { untilAt, minutes }
---@return string|nil err
---@return table|nil data
function ImpTips.goDark(actor, contractId, shown)
    if not ImpTips.on('GoDark') then return false, CH.ERR.FEATURE_OFF end
    contractId = Util.toId(contractId)
    if not contractId then return false, CH.ERR.INVALID_INPUT end
    if not Contracts then return buyDark(actor, contractId, shown) end
    return Contracts.serialized({ 'goDark:' .. tostring(actor.cid) }, buyDark, actor, contractId, shown)
end

buyDark = function(actor, contractId, shown)
    local cost, account, minutes = goDarkTerms()
    -- Not found and not theirs are the same answer.
    local contract = Storage.readContract(contractId)
    if not contract or contract.target_cid ~= actor.cid then return false, CH.ERR.NOT_PARTICIPANT end
    if CH.TERMINAL[contract.state] then return false, CH.ERR.ALREADY_SETTLED end
    if not (LocationTip and LocationTip.toldAt(contractId)) then return false, CH.ERR.NOT_TIPPED end
    local already = ImpTips.darkUntil(actor.cid)
    if already then return false, CH.ERR.ALREADY_DARK, { untilAt = already } end
    if shown ~= nil and cost > 0 then
        local quoted = type(shown) == 'table' and shown or {}
        if tonumber(quoted.cost) ~= cost or quoted.account ~= account then
            return false, CH.ERR.TERMS_CHANGED, { cost = cost, account = account }
        end
    end
    -- Read again with nothing between this and the charge.
    local now = Storage.readContract(contractId)
    if not now or CH.TERMINAL[now.state] then return false, CH.ERR.ALREADY_SETTLED end

    -- Kept first, so a charge never stands without it; dropped if the charge
    -- is refused. Counted as dark only once paid.
    local untilAt = os.time() + minutes * 60
    local row = { id = 'dk:' .. actor.cid, kind = ImpTips.KIND_DARK, cid = actor.cid, until_at = untilAt }
    local kept = pcall(Storage.writeRpRow, row)
    if not kept then return false, CH.ERR.SERVER_ERROR end
    if not Util.charge(actor.player, account, cost) then
        pcall(Storage.deleteRpRow, row.id)
        return false, CH.ERR.INSUFFICIENT, { cost = cost, account = account }
    end
    load()
    dark[actor.cid] = row
    Audit.financial('go_dark_bought', actor.cid, contractId, { amount = cost, account = account,
        minutes = minutes })
    if Notify and Notify.push then pcall(Notify.push, actor.cid, 'tip', contractId) end
    return { untilAt = untilAt, minutes = minutes }
end

--- Whether a tip bought now on this target finds nothing (they went dark).
--- A window paid for holds to its end even if the switch is turned off.
---@param targetCid string
---@return boolean
function ImpTips.targetDark(targetCid)
    return ImpTips.darkUntil(targetCid) ~= nil
end

return ImpTips
