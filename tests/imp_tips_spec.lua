--- Informant fairness (server/imp_tips.lua, Config.Improvements), six rules
--- over the informant tip and the target's informant, each off as shipped:
--- off, nothing changes; on, each does what it says; a refusal charges
--- nothing; the money balances; nobody is named; the panel's settings apply.

local TARGET_AT = { x = 1200.0, y = -800.0, z = 30.0 }
local PRICE = { cost = 25000, account = 'bank' }

local function call(name, src, payload)
    local handler = Env.events['crimson-hitman:' .. name]
    if not handler then return { ok = false, err = 'NO SUCH HANDLER' } end
    Env.clientEvents = {}
    _G.source = src
    local fired, err = pcall(handler, payload or {})
    _G.source = nil
    if not fired then return { ok = false, err = 'THREW: ' .. tostring(err) } end
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:result' then return event.args[1] end
    end
    return nil
end

local function buy(src, c, shown)
    return call('locationTip', src, { id = c.id, shown = shown or PRICE })
end

local function bank(src) return Env.players[src].PlayerData.money.bank end

local function moneyInTheCity()
    local total = 0
    for _, p in pairs(Env.players) do
        total = total + (p.PlayerData.money.cash or 0) + (p.PlayerData.money.bank or 0)
    end
    return total
end

--- The phone notices the target (source 2) was sent since the events were
--- last cleared that say a tip was bought.
local function tipNoticesToTarget()
    local n = 0
    for _, event in ipairs(Env.clientEvents) do
        if (event.name == 'lb-phone:SendNotification' or event.name == 'crimson-hitman:notify')
            and event.target == 2 then
            local text = tostring(event.args[1] and (event.args[1].title or '')) .. ' '
                .. tostring(event.args[1] and (event.args[1].content or ''))
            if text:find('Informant tip', 1, true) or text:find('tipped off', 1, true) then n = n + 1 end
        end
    end
    return n
end

local function dump(value, out)
    out = out or {}
    if type(value) == 'table' then
        for k, v in pairs(value) do
            out[#out + 1] = tostring(k)
            dump(v, out)
        end
    else
        out[#out + 1] = tostring(value)
    end
    return table.concat(out, ' ')
end

--- A contract the hitman (source 3) holds, its target (source 2) at
--- TARGET_AT and shown it, the hitman able to pay; `anon` places it
--- anonymously.
local function taken(opts)
    opts = opts or {}
    local s = newStack()
    Config.Notifications.ParanoidAlertJitter = { min = 0, max = 0 }
    local f = fixture(s)
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 } }, anonymous = opts.anon == true,
    })
    truthy(c, 'placed')
    Env.players[3].PlayerData.money.bank = 200000
    Env.players[2].PlayerData.money.bank = 200000
    truthy(s.contracts.accept(f.hitman, c.id, opts.anonHitman == true), 'taken')
    Env.players[2]._coords = { x = TARGET_AT.x, y = TARGET_AT.y, z = TARGET_AT.z }
    Env.advance(1)
    return s, f, c
end

local function secondHitman(s, c)
    Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
        cash = 0, bank = 200000, firstname = 'Nel', lastname = 'Vey' })
    truthy(s.contracts.accept(s.identity.resolve(4), c.id, false), 'a second hitman')
end

local function view(s, c, cid)
    return s.projection.contract(s.storage.readContract(c.id), cid)
end

local IMP = Config.Improvements

--- Every test here turns rules on live: Config.Improvements and the tip's
--- own block are put back in place after each, whichever way it ends, so
--- nothing that runs next sees them on.
local function copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end
local function restoreInto(target, saved)
    for key in pairs(target) do if saved[key] == nil then target[key] = nil end end
    for key, value in pairs(saved) do
        if type(value) == 'table' and type(target[key]) == 'table' then
            restoreInto(target[key], value)
        else
            target[key] = copy(value)
        end
    end
end
local baseIt = it
local function it(name, fn)
    baseIt(name, function()
        local saved, tip = copy(Config.Improvements), copy(Config.LocationTip)
        local ok, err = pcall(fn)
        restoreInto(Config.Improvements, saved)
        restoreInto(Config.LocationTip, tip)
        if not ok then error(err, 0) end
    end)
end

describe('informant fairness, as shipped', function()
    it('ships every rule off in config.lua', function()
        local s = newStack()
        for _, name in ipairs({ 'TipWarningDelay', 'TipLimits', 'TipHoldFirst', 'InformantSecondTry',
            'TipSafeZones', 'GoDark' }) do
            eq(ConfigDefaults.Improvements[name].Enabled, false, name .. ' ships off')
            eq(Config.Improvements[name].Enabled, false, name .. ' is off')
        end
        eq(#ConfigDefaults.Improvements.TipSafeZones.Zones, 0, 'no safe zone ships')
        truthy(s.impTips, 'wired')
    end)

    it('off, a tip behaves as before: the same price, the warning at once, nothing new on the cards', function()
        local s, _, c = taken()
        local card = view(s, c, 'HITMAN01').locationTip
        falsy(card.cost or card.holdSeconds or card.mineUsed, 'nothing new on the hitman\'s card')
        local before = bank(3)
        local r = buy(3, c)
        truthy(r and r.ok, tostring(r and r.err))
        eq(bank(3), before - 25000, 'the shipped price')
        eq(tipNoticesToTarget(), 1, 'the target told at once')
        local onMe = view(s, c, 'TARGET01')
        truthy(onMe.tippedAt, 'their card says when')
        eq(onMe.goDark, nil, 'no go dark')
        eq(onMe.informantCost, nil, 'no second-try price')
        -- A second tip on it by the same hitman, after the wait: still sold.
        Env.advance(Config.LocationTip.CooldownMinutes * 60 + 1)
        truthy(buy(3, c).ok, 'a second tip by the same hitman')
    end)

    it('refuses go dark while it is off, charging nothing', function()
        local s, _, c = taken()
        truthy(buy(3, c).ok)
        local before = bank(2)
        local r = call('goDark', 2, { id = c.id, shown = { cost = 50000, account = 'bank' } })
        eq(r.err, 'feature_off')
        eq(bank(2), before)
        falsy(s.impTips.targetDark('TARGET01'))
    end)
end)

describe('the target\'s tip warning, delayed (TipWarningDelay)', function()
    it('waits a random while in the range, then tells them; the card waits and rounds', function()
        local s, _, c = taken()
        IMP.TipWarningDelay.Enabled = true
        IMP.TipWarningDelay.MinSeconds, IMP.TipWarningDelay.MaxSeconds = 120, 120
        local r = buy(3, c)
        truthy(r and r.ok, tostring(r and r.err))
        eq(tipNoticesToTarget(), 0, 'not told at once')
        eq(view(s, c, 'TARGET01').tippedAt, nil, 'nothing on their card yet')
        local boughtAt = os.time()
        Env.clientEvents = {}
        Env.advance(119)
        eq(tipNoticesToTarget(), 0, 'not before the delay')
        Env.advance(2)
        eq(tipNoticesToTarget(), 1, 'told once the delay is up')
        local at = view(s, c, 'TARGET01').tippedAt
        eq(at, boughtAt - (boughtAt % 300), 'rounded to 5 minutes')
    end)

    it('survives a restart: the warning is sent late, never lost, and once', function()
        local s, _, c = taken()
        IMP.TipWarningDelay.Enabled = true
        IMP.TipWarningDelay.MinSeconds, IMP.TipWarningDelay.MaxSeconds = 300, 300
        truthy(buy(3, c).ok)
        eq(#s.storage.readRpRows('imp_tipwarn'), 1, 'kept in the store')
        -- The process goes; the store stays. Its timers went with it.
        Env.timers = {}
        s.impTips.init({ storage = s.storage, audit = s.audit, notify = s.notify,
            contracts = s.contracts, locationTip = s.locationTip, informant = s.informant,
            projection = s.projection })
        Env.time = Env.time + 600
        Env.clientEvents = {}
        s.impTips.resume()
        Env.advance(1)
        eq(tipNoticesToTarget(), 1, 'sent late')
        eq(#s.storage.readRpRows('imp_tipwarn'), 0, 'and gone from the store')
        Env.clientEvents = {}
        Env.advance(600)
        eq(tipNoticesToTarget(), 0, 'not twice')
    end)

    it('drops the warning for a contract that ended while it waited', function()
        local s, _, c = taken()
        IMP.TipWarningDelay.Enabled = true
        IMP.TipWarningDelay.MinSeconds, IMP.TipWarningDelay.MaxSeconds = 60, 60
        truthy(buy(3, c).ok)
        local now = s.storage.readContract(c.id)
        truthy(s.storage.compareSetContractState(c.id, now.state, CH.STATE.CANCELLED), 'ended')
        -- Ended by writing the state straight to the store, its escrow left
        -- held: a fixture no release produced, so not the resource's output
        -- for the invariant run (tests/invariants.lua).
        rawset(s.storage, '__rawFixture', true)
        Env.clientEvents = {}
        Env.advance(61)
        eq(tipNoticesToTarget(), 0, 'nothing to warn of')
    end)
end)

describe('tip limits (TipLimits)', function()
    it('one per hitman: a second by the same hitman is refused, charging nothing', function()
        local s, _, c = taken()
        IMP.TipLimits.Enabled, IMP.TipLimits.OnePerHitman = true, true
        truthy(buy(3, c).ok)
        Env.advance(Config.LocationTip.CooldownMinutes * 60 + 1)
        truthy(view(s, c, 'HITMAN01').locationTip.mineUsed, 'the card says so')
        local before = bank(3)
        local r = buy(3, c)
        eq(r.err, 'limit_reached')
        truthy(r.data and r.data.perHitman, 'as theirs')
        eq(bank(3), before, 'nothing charged')
        secondHitman(s, c)
        truthy(buy(4, c).ok, 'another hitman still may')
    end)

    it('price doubling: the card quotes the real next price, an old quote is refused, capped', function()
        local s, _, c = taken()
        IMP.TipLimits.Enabled, IMP.TipLimits.OnePerHitman = true, false
        IMP.TipLimits.PriceDoubling, IMP.TipLimits.MaxCost = true, 80000
        Config.LocationTip.CooldownMinutes = 0
        eq(view(s, c, 'HITMAN01').locationTip.cost, nil, 'the first at the board\'s price')
        local city = moneyInTheCity()
        truthy(buy(3, c).ok)
        eq(view(s, c, 'HITMAN01').locationTip.cost, 50000, 'the next quoted at twice')
        local before = bank(3)
        local r = buy(3, c, PRICE)
        eq(r.err, 'terms_changed', 'the old price is refused')
        eq(r.data.cost, 50000, 'with the price now')
        eq(bank(3), before, 'nothing charged')
        truthy(buy(3, c, { cost = 50000, account = 'bank' }).ok, 'bought at the quote')
        eq(bank(3), before - 50000)
        eq(view(s, c, 'HITMAN01').locationTip.cost, 80000, 'the third capped at MaxCost')
        eq(moneyInTheCity(), city - 75000, 'what was paid, and no more, went')
    end)
end)

describe('holding a contract before a tip (TipHoldFirst)', function()
    it('refuses until held long enough, saying how long, charging nothing', function()
        local s, _, c = taken()
        IMP.TipHoldFirst.Enabled, IMP.TipHoldFirst.MinHeldMinutes = true, 10
        local card = view(s, c, 'HITMAN01').locationTip
        truthy(card.holdSeconds and card.holdSeconds > 0, 'the card says how long')
        local before = bank(3)
        local r = buy(3, c)
        eq(r.err, 'tip_hold')
        truthy(r.data.retryAfter > 0 and r.data.retryAfter <= 600, 'how long is left')
        eq(bank(3), before, 'nothing charged')
        Env.advance(600)
        truthy(buy(3, c).ok, 'held long enough')
    end)
end)

describe('the target\'s informant, a second try (InformantSecondTry)', function()
    it('prices the look-ups after the first at the percentage, quoted on the card', function()
        local s, _, c = taken({ anon = true, anonHitman = true })
        IMP.InformantSecondTry.Enabled, IMP.InformantSecondTry.SecondTryCostPercent = true, 50
        local picks = view(s, c, 'TARGET01').informantPicks
        truthy(picks and #picks >= 2, 'picks offered')
        eq(view(s, c, 'TARGET01').informantCost, nil, 'the first at the informant\'s price')
        local before = bank(2)
        local r = call('informant', 2, { id = c.id, shown = PRICE, pick = picks[1].pick })
        truthy(r and r.ok, tostring(r and r.err))
        eq(bank(2), before - 25000)
        eq(view(s, c, 'TARGET01').informantCost, 12500, 'the next quoted at half')
        local mid = bank(2)
        -- Past the informant's own allowance between two asks.
        Env.advance(Config.Cooldowns.informant.per + 1)
        local stale = call('informant', 2, { id = c.id, shown = PRICE, pick = 'placer' })
        eq(stale.err, 'terms_changed', 'the old price is refused')
        eq(bank(2), mid, 'nothing charged')
        Env.advance(Config.Cooldowns.informant.per + 1)
        local again = call('informant', 2, { id = c.id, shown = { cost = 12500, account = 'bank' },
            pick = 'placer' })
        truthy(again and again.ok, tostring(again and again.err))
        eq(bank(2), mid - 12500, 'half charged')
    end)
end)

describe('safe zones (TipSafeZones)', function()
    it('refuses a tip while the target is in one, charging nothing, saying neither why nor where', function()
        local s, _, c = taken()
        IMP.TipSafeZones.Enabled = true
        IMP.TipSafeZones.Zones = { '1210, -790, 50, Pillbox Hill Medical' }
        local before, city = bank(3), moneyInTheCity()
        local r = buy(3, c)
        eq(r.err, 'tip_cant_place')
        eq(bank(3), before, 'nothing charged')
        eq(moneyInTheCity(), city)
        local said = dump(r) .. ' ' .. dump(Env.clientEvents)
        falsy(said:find('Pillbox', 1, true), 'the zone is not named')
        falsy(said:find('Dana', 1, true) or said:find('Reyes', 1, true), 'nor the target')
        eq(tipNoticesToTarget(), 0, 'the target is not told')
        Env.players[2]._coords = { x = 1400.0, y = -800.0, z = 30.0 }
        truthy(buy(3, c).ok, 'outside it, sold')
        _ = s
    end)
end)

describe('going dark (GoDark)', function()
    local function on()
        IMP.GoDark.Enabled, IMP.GoDark.Cost, IMP.GoDark.Minutes = true, 50000, 30
    end
    local DARK = { cost = 50000, account = 'bank' }

    it('is sold only to the target, once they were told of a tip', function()
        local s, _, c = taken()
        on()
        local r = call('goDark', 2, { id = c.id, shown = DARK })
        eq(r.err, 'not_tipped', 'nobody tipped yet')
        eq(view(s, c, 'TARGET01').goDark, nil, 'not offered')
        truthy(buy(3, c).ok)
        local offer = view(s, c, 'TARGET01').goDark
        truthy(offer, 'offered')
        eq(offer.cost, 50000)
        eq(offer.untilAt, nil)
        for _, src in ipairs({ 1, 3 }) do
            local before = bank(src)
            eq(call('goDark', src, { id = c.id, shown = DARK }).err, 'not_participant')
            eq(bank(src), before)
        end
        eq(view(s, c, 'HITMAN01').goDark, nil, 'never on another\'s card')
    end)

    it('charges the quote; tips meanwhile find nothing and are given back in full', function()
        local s, _, c = taken()
        on()
        Config.LocationTip.CooldownMinutes = 0
        truthy(buy(3, c).ok)
        local city = moneyInTheCity()
        local stale = call('goDark', 2, { id = c.id, shown = { cost = 1, account = 'bank' } })
        eq(stale.err, 'terms_changed')
        eq(moneyInTheCity(), city, 'nothing charged on a stale quote')
        local before = bank(2)
        local r = call('goDark', 2, { id = c.id, shown = DARK })
        truthy(r and r.ok, tostring(r and r.err))
        eq(bank(2), before - 50000, 'paid')
        truthy(view(s, c, 'TARGET01').goDark.untilAt, 'their card says until when')
        eq(call('goDark', 2, { id = c.id, shown = DARK }).err, 'already_dark', 'not twice')
        eq(bank(2), before - 50000, 'charged once')

        local hitmanBefore, tipsBefore = bank(3), #s.storage.readLocationTips(c.id)
        local tip = buy(3, c)
        eq(tip.err, 'tip_not_found', 'the informant found nothing')
        eq(tip.data.refunded, true)
        eq(bank(3), hitmanBefore, 'given back in full')
        eq(#s.storage.readLocationTips(c.id), tipsBefore, 'nothing kept or counted')
        eq(moneyInTheCity(), city - 50000, 'only the go-dark price left the city')
        local said = dump(tip) .. ' ' .. dump(Env.clientEvents)
        falsy(said:find('Dana', 1, true) or said:find('Vic', 1, true), 'nobody named')
        s.audit.flush()
        local refunds = 0
        for _, row in ipairs(s.storage.readAudit()) do
            if row.action == 'location_tip_refunded' then refunds = refunds + 1 end
        end
        eq(refunds, 1, 'the refund audited')

        Env.advance(30 * 60 + 1)
        truthy(buy(3, c).ok, 'once the time is up, tips find them again')
    end)

    it('keeps a target dark across a restart, and charges nothing it cannot take', function()
        local s, _, c = taken()
        on()
        truthy(buy(3, c).ok)
        Env.players[2].PlayerData.money.bank = 10
        local r = call('goDark', 2, { id = c.id, shown = DARK })
        eq(r.err, 'insufficient_funds')
        eq(bank(2), 10, 'nothing charged')
        eq(#s.storage.readRpRows('imp_dark'), 0, 'nothing kept')
        Env.players[2].PlayerData.money.bank = 100000
        truthy(call('goDark', 2, { id = c.id, shown = DARK }).ok)
        s.impTips.init({ storage = s.storage, audit = s.audit, notify = s.notify,
            contracts = s.contracts, locationTip = s.locationTip, informant = s.informant,
            projection = s.projection })
        truthy(s.impTips.targetDark('TARGET01'), 'still dark after the restart')
        -- And still dark with the switch turned off: it was paid for.
        IMP.GoDark.Enabled = false
        Env.advance(Config.LocationTip.CooldownMinutes * 60 + 1)
        eq(buy(3, c).err, 'tip_not_found')
    end)
end)

describe('informant fairness in the admin panel', function()
    it('every setting is in the catalogue, the switches under Features', function()
        local s = newStack()
        local keys = {}
        for _, entry in ipairs(s.settings.CATALOGUE) do keys[entry.key] = entry end
        for name, fields in pairs(s.impTips.RULES) do
            for field in pairs(fields) do
                local key = 'Improvements.' .. name .. '.' .. field
                truthy(keys[key], key .. ' is in the panel')
                if field == 'Enabled' then
                    eq(keys[key].category, 'features', key)
                    eq(keys[key].group, keys[key].group:match('^Improvements: .+') and keys[key].group, key)
                end
            end
        end
    end)

    it('holds config.lua to its rules at the start, putting back what ships', function()
        newStack()
        IMP.GoDark.Cost, IMP.TipSafeZones.Zones = -1, { 'not a zone' }
        IMP.TipWarningDelay.MinSeconds, IMP.TipWarningDelay.MaxSeconds = 200, 100
        Config.Improvements.InformantSecondTry = nil
        local warn = {}
        require('server.imp_tips').validate(warn)
        eq(IMP.GoDark.Cost, 50000, 'the shipped price')
        eq(#IMP.TipSafeZones.Zones, 0, 'the shipped zones')
        eq(IMP.TipWarningDelay.MinSeconds, 100, 'never above the longest')
        eq(Config.Improvements.InformantSecondTry.Enabled, false, 'a missing block filled, off')
        truthy(#warn >= 3, 'each said: ' .. table.concat(warn, ' | '))
    end)

    it('applies live, and refuses a zone that does not read', function()
        local s, _, c = taken()
        truthy(s.settings.set('Improvements.TipHoldFirst.Enabled', true, 'ADMIN001'))
        truthy(s.settings.set('Improvements.TipHoldFirst.MinHeldMinutes', 30, 'ADMIN001'))
        eq(buy(3, c).err, 'tip_hold', 'in force at once')
        falsy(s.settings.set('Improvements.TipSafeZones.Zones', { 'nowhere' }, 'ADMIN001'),
            'a zone that does not read')
        truthy(s.settings.set('Improvements.TipSafeZones.Zones', { '1, 2, 30, Somewhere' }, 'ADMIN001'))
        eq(Config.Improvements.TipSafeZones.Zones[1], '1, 2, 30, Somewhere')
        falsy(s.settings.set('Improvements.GoDark.Cost', -5, 'ADMIN001'), 'a negative price')
    end)
end)
