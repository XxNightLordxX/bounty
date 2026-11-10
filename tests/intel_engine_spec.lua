--- The one Intel engine (server/intel/engine.lua): every paid look-up (the
--- target's informant, the placer's informant, the hitman's tip and going
--- dark) is checked, charged, confirmed, refunded and delivered by the same
--- path. Held here: the switches (Intel.on), the check's steps and their
--- order, the purchase matrix (who may buy which), the refund at every
--- point after the charge (a refusal, a read that raised, a staff hold that
--- landed in the awaits) with each product's own audit and fallback, and
--- that nothing is charged before every check has passed.

local Util = require('crimson-hitman.shared.util')

local function intel() return require('server.intel.engine') end

local function bank(src) return Env.players[src].PlayerData.money.bank end

--- Every player's money and every contract's escrow, summed.
local function total(s)
    local sum = 0
    for _, p in pairs(Env.players) do sum = sum + p.PlayerData.money.cash + p.PlayerData.money.bank end
    for _, c in ipairs(s.storage.allContracts()) do sum = sum + s.escrow.moneyValue(c.id) end
    return sum
end

local function auditRows(s, action)
    s.audit.flush()
    local out = {}
    for _, row in ipairs(s.storage.readAudit()) do
        if row.action == action then out[#out + 1] = row end
    end
    return out
end

local function view(s, c, cid)
    return s.projection.contract(s.storage.readContract(c.id), cid)
end

--- A contract on the target (2), placed anonymously by the creator (1),
--- taken anonymously by the hitman (3), the target standing in the city,
--- everybody able to pay, every product on and every roll a hit.
local function stack()
    local s = newStack()
    Config.Notifications.ParanoidAlertJitter = { min = 0, max = 0 }
    local f = fixture(s)
    local c = assert(s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 } }, anonymous = true,
    }))
    truthy(s.contracts.accept(f.hitman, c.id, true), 'taken')
    for i = 1, 3 do Env.players[i].PlayerData.money.bank = 200000 end
    Env.players[2]._coords = { x = 1200.0, y = -800.0, z = 30.0 }
    Config.Intel.GoDark.Enabled = true
    s.informant.setRandom(function() return 1 end)
    Env.advance(5)
    return s, f, c
end

local function quote(block)
    return { cost = Config.Intel[block].Cost, account = Config.Intel[block].Account }
end

--- Each product, bought the way its handler buys it: answers (result, err, data).
local BUY = {
    informant = function(s, f, c, who)
        local pick
        for _, p in ipairs(view(s, c, 'TARGET01').informantPicks or {}) do
            if p.pick ~= 'placer' then pick = p.pick end
        end
        local ok, err, data = s.informant.buy(who or f.target, c.id, quote('Informant'), pick or 'op_none')
        return ok and data or false, err, data
    end,
    placerInformant = function(s, f, c, who)
        local picks = view(s, c, 'CREATOR1').placerInformantPicks or {}
        local pick = picks[1] and picks[1].pick or 'op_none'
        local ok, err, data = s.informant.placerBuy(who or f.creator, c.id, quote('PlacerInformant'), pick)
        return ok and data or false, err, data
    end,
    locationTip = function(s, f, c, who)
        return s.locationTip.buy(who or f.hitman, c.id, quote('LocationTip'))
    end,
    goDark = function(s, f, c, who)
        -- Sold only to a target told of a tip: one bought first.
        if not s.locationTip.toldAt(c.id) then
            assert(s.locationTip.buy(f.hitman, c.id, quote('LocationTip')))
        end
        return s.intelRules.goDark(who or f.target, c.id, quote('GoDark'))
    end,
}

--- The buyer of each product, by fixture role.
local BUYER = { informant = 'target', placerInformant = 'creator', locationTip = 'hitman', goDark = 'target' }
--- Each product's refund action.
local REFUNDED = {
    informant = 'informant_refunded', placerInformant = 'placer_informant_refunded',
    locationTip = 'location_tip_refunded', goDark = 'go_dark_refunded',
}
local SOURCE = { creator = 1, target = 2, hitman = 3 }

--- Run `fn` with the charge watched: `after()` runs once, the moment the
--- engine's charge has taken the money, before anything reads again.
local function onCharge(after, fn)
    local real = Util.charge
    local fired = false
    Util.charge = function(...)
        local ok = real(...)
        if ok and not fired then
            fired = true
            after()
        end
        return ok
    end
    local out = table.pack(pcall(fn))
    Util.charge = real
    if not out[1] then error(out[2], 0) end
    return table.unpack(out, 2, out.n)
end

-- ============================================================================
--                              THE SWITCHES
-- ============================================================================

describe('Intel switches (Intel.on)', function()
    it('sells a look-up only with the master switch, its own and its class\'s all on', function()
        newStack()
        local I = intel()
        for _, section in ipairs({ 'Informant', 'PlacerInformant', 'LocationTip' }) do
            Config.Intel.Enabled, Config.Intel[section].Enabled = true, true
            Config.TargetClasses.default[section], Config.TargetClasses.whitelisted[section] = true, false
            truthy(I.on(section, false), section .. ': every switch on')
            falsy(I.on(section, true), section .. ': not for the class whose switch is off')
            truthy(I.anyOn(section), section .. ': on for some target')
            Config.Intel.Enabled = false
            falsy(I.on(section, false), section .. ': the master switch off beats the rest')
            falsy(I.anyOn(section))
            Config.Intel.Enabled = true
            Config.Intel[section].Enabled = false
            falsy(I.on(section, false), section .. ': its own switch off')
            Config.Intel[section].Enabled = 'true'
            falsy(I.on(section, false), section .. ': anything but true is off')
        end
        Config.Intel = nil
        falsy(I.on('Informant', false), 'no Intel section sells nothing')
    end)

    it('ships the master switch on and every product, rule and extra off', function()
        local file = require('tests.harness.shipped').fromFile()
        eq(file.Intel.Enabled, true)
        for _, name in ipairs({ 'Informant', 'PlacerInformant', 'LocationTip', 'WarningDelay', 'TipLimits',
            'HoldFirst', 'SecondTry', 'SafeZones', 'GoDark', 'InPerson', 'Rumours' }) do
            eq(file.Intel[name].Enabled, false, name .. ' ships off')
            eq(ConfigDefaults.Intel[name].Enabled, false, name .. ' ships off in defaults.lua')
        end
        -- One section: none of the old homes is left.
        eq(file.InformantsEnabled, nil)
        eq(file.Informant, nil)
        eq(file.PlacerInformant, nil)
        eq(file.LocationTip, nil)
        for _, old in ipairs({ 'TipWarningDelay', 'TipLimits', 'TipHoldFirst', 'InformantSecondTry',
            'TipSafeZones', 'GoDark' }) do
            eq(file.Improvements[old], nil, 'Improvements.' .. old .. ' moved')
        end
        eq(file.Roleplay.Rumours, nil)
        eq(file.Roleplay.InformantNpc, nil)
    end)
end)

-- ============================================================================
--                              THE CHECK
-- ============================================================================

describe('the Intel check (Intel.check)', function()
    it('runs the product\'s steps in its order and answers the first refusal', function()
        newStack()
        local I = intel()
        local ran = {}
        local product = I.define('informant', {
            steps = {
                function() ran[#ran + 1] = 'a' end,
                function() ran[#ran + 1] = 'b'; return 'first_refusal', { n = 1 } end,
                function() ran[#ran + 1] = 'c'; return 'never' end,
            },
        })
        local err, data = I.check(product, { actor = { cid = 'X' }, contract = {} })
        eq(err, 'first_refusal')
        eq(data.n, 1)
        eq(table.concat(ran), 'ab', 'nothing after the first refusal')
    end)

    it('draws party, holds, open, live and class from one set', function()
        local s, f, c = stack()
        local I = intel()
        local contract = s.storage.readContract(c.id)
        local svc = { storage = s.storage }
        local function party(name, actor)
            return I.STEPS.party({ actor = actor, contract = contract, contractId = c.id, svc = svc },
                I.PRODUCTS[name])
        end
        local stranger = { cid = 'STRANGER' }
        -- The purchase matrix: who may buy which, by their part in the contract.
        local matrix = {
            informant = { target = true }, placerInformant = { creator = true },
            locationTip = { hitman = true }, goDark = { target = true },
        }
        for name, allowed in pairs(matrix) do
            for role, actor in pairs({ creator = f.creator, target = f.target, hitman = f.hitman,
                stranger = stranger }) do
                if allowed[role] then
                    eq(party(name, actor), nil, name .. ': ' .. role .. ' may buy')
                else
                    eq(party(name, actor), CH.ERR.NOT_PARTICIPANT, name .. ': ' .. role .. ' may not')
                end
            end
        end
        local ctx = { contract = contract }
        eq(I.STEPS.open(ctx), nil)
        eq(I.STEPS.live(ctx), nil)
        eq(I.STEPS.holds(ctx), nil)
        truthy(s.holds.freeze('ADMIN', 'TARGET01', 'test', 'Target'))
        eq(I.STEPS.holds({ contract = s.storage.readContract(c.id) }), CH.ERR.CONTRACT_FROZEN)
        eq(I.STEPS.open({ contract = { state = CH.STATE.COMPLETED } }), CH.ERR.ALREADY_SETTLED)
        eq(I.STEPS.live({ contract = { state = CH.STATE.COMPLETED } }), CH.ERR.ALREADY_SETTLED)
        Config.TargetClasses.default.Informant = false
        eq(I.STEPS.class({ contract = contract }, I.PRODUCTS.informant), CH.ERR.FEATURE_OFF)
    end)

    it('holds a quote to the price now, and passes a free purchase or no quote', function()
        local I = intel()
        truthy(I.quoteHolds(nil, 500, 'bank'), 'no page, no quote')
        truthy(I.quoteHolds({}, 0, 'bank'), 'free')
        truthy(I.quoteHolds({ cost = 500, account = 'bank' }, 500, 'bank'))
        falsy(I.quoteHolds({ cost = 400, account = 'bank' }, 500, 'bank'), 'a price that moved')
        falsy(I.quoteHolds({ cost = 500, account = 'cash' }, 500, 'bank'), 'an account that moved')
        falsy(I.quoteHolds('500', 500, 'bank'), 'not a quote')
    end)
end)

-- ============================================================================
--                              THE PURCHASE
-- ============================================================================

describe('the Intel purchase (Intel.buy)', function()
    --- A product of the test's own, over the stack's services.
    local function made(s, parts)
        local I = intel()
        local base = {
            terms = function(ctx) ctx.cost, ctx.account = 1000, 'bank' end,
            steps = { 'party' },
            confirm = function() return true end,
            deliver = function() return { done = true } end,
        }
        for k, v in pairs(parts or {}) do base[k] = v end
        return I.define('informant', base), { storage = s.storage, audit = s.audit, bailout = s.bailout,
            contracts = s.contracts }
    end

    it('charges last, after the check, the quote and the last read', function()
        local s, f, c = stack()
        local I = intel()
        local order = {}
        local product, svc = made(s, {
            steps = { 'party', function() order[#order + 1] = 'check' end },
            ready = function() order[#order + 1] = 'ready:' .. bank(2) end,
            confirm = function() order[#order + 1] = 'confirm:' .. bank(2); return true end,
        })
        local result = I.buy(product, svc, f.target, c.id, { cost = 1000, account = 'bank' })
        eq(result.done, true)
        eq(table.concat(order, ','), 'check,ready:200000,confirm:199000', 'the charge between ready and confirm')
    end)

    it('charges nothing on any refusal before the charge', function()
        local s, f, c = stack()
        local I = intel()
        local money = total(s)
        local product, svc = made(s)
        eq(select(2, I.buy(product, svc, f.creator, c.id, nil)), CH.ERR.NOT_PARTICIPANT, 'the party step')
        eq(select(2, I.buy(product, svc, f.target, 'no_such', nil)), CH.ERR.NOT_PARTICIPANT, 'no contract')
        local _, err, data = I.buy(product, svc, f.target, c.id, { cost = 1, account = 'bank' })
        eq(err, CH.ERR.TERMS_CHANGED)
        eq(data.cost, 1000)
        product = made(s, { ready = function() return 'not_ready', { why = 1 } end })
        eq(select(2, I.buy(product, svc, f.target, c.id, nil)), 'not_ready')
        local undone = 0
        product = made(s, { uncharged = function() undone = undone + 1 end, sayTerms = true })
        Env.players[2].PlayerData.money.bank = 10
        local _, short, terms = I.buy(product, svc, f.target, c.id, nil)
        eq(short, CH.ERR.INSUFFICIENT)
        eq(terms.cost, 1000, 'the price said where the product says it')
        eq(undone, 1, 'what ready kept is undone')
        Env.players[2].PlayerData.money.bank = 200000
        eq(total(s), money + (200000 - 200000), 'nothing charged')
    end)

    it('answers a repeat without a sale', function()
        local s, f, c = stack()
        local I = intel()
        local product, svc = made(s, { steps = { 'party', function(ctx) ctx.answer = { repeated = true } end } })
        local before = bank(2)
        eq(I.buy(product, svc, f.target, c.id, nil).repeated, true)
        eq(bank(2), before, 'free')
    end)

    it('gives the price back on a refusal after the charge, once, under the product\'s action', function()
        local s, f, c = stack()
        local I = intel()
        local product, svc = made(s, { confirm = function() return false, 'went_away', { x = 1 }, 'gone', true end })
        local before = bank(2)
        local result, err, data = I.buy(product, svc, f.target, c.id, nil)
        eq(result, false)
        eq(err, 'went_away')
        eq(data.refunded, true, 'said where the product says it')
        eq(bank(2), before, 'given back')
        local rows = auditRows(s, 'informant_refunded')
        eq(#rows, 1)
    end)

    it('gives the price back when a read after the charge raises, then raises', function()
        local s, f, c = stack()
        local I = intel()
        local product, svc = made(s, { confirm = function() error('dropped connection') end })
        local before = bank(2)
        local ok, raised = pcall(I.buy, product, svc, f.target, c.id, nil)
        falsy(ok)
        truthy(tostring(raised):find('dropped connection', 1, true))
        eq(bank(2), before, 'given back')
        eq(#auditRows(s, 'informant_refunded'), 1)
    end)

    it('owes a refund it cannot credit (owe), or leaves it for staff (review)', function()
        local I = intel()
        local audited, owed, opened = {}, {}, {}
        local svc = {
            audit = { financial = function(action, cid, id, data) audited[#audited + 1] = { action, data } end },
            bailout = { owe = function(cid, id, amount, account, action) owed[#owed + 1] = action; return 'owed1' end },
            review = { open = function(row) opened[#opened + 1] = row end },
        }
        local offline = { cid = 'GONE', player = nil }
        local ctx = { actor = offline, contractId = 'c1', cost = 500, account = 'bank', svc = svc }
        truthy(I.refund(ctx, I.PRODUCTS.informant, 'why'), 'owed counts as given back')
        eq(owed[1], 'informant_refunded')
        eq(audited[1][1], 'informant_refunded')
        eq(audited[1][2].owed, nil, 'owed through the buyout path, so not marked unpaid')
        falsy(I.refund(ctx, I.PRODUCTS.locationTip, 'why'), 'the tip leaves it for staff')
        eq(audited[2][1], 'location_tip_refund_failed')
        eq(opened[1].kind, 'location_tip_refund_failed')
        eq(opened[1].amount, 500)
        svc.bailout.owe = function() error('the store is down') end
        falsy(I.refund(ctx, I.PRODUCTS.goDark, 'why'), 'an owe that raised is not owed')
        eq(audited[3][1], 'go_dark_refunded')
        truthy(I.refund({ actor = offline, cost = 0, svc = svc }, I.PRODUCTS.goDark, 'free'), 'nothing to give')
        eq(#audited, 3, 'a free one writes nothing')
    end)
end)

-- ============================================================================
--                              EVERY PRODUCT, EVERY POINT
-- ============================================================================

describe('every Intel product refunds at every point after the charge', function()
    for _, name in ipairs({ 'informant', 'placerInformant', 'locationTip', 'goDark' }) do
        it(name .. ': sold to its buyer, and to nobody else, charging nobody else', function()
            local s, f, c = stack()
            if name == 'goDark' then assert(s.locationTip.buy(f.hitman, c.id, quote('LocationTip'))) end
            for role, actor in pairs({ creator = f.creator, target = f.target, hitman = f.hitman }) do
                if role ~= BUYER[name] then
                    local money = total(s)
                    local result, err = BUY[name](s, f, c, actor)
                    falsy(result, name .. ' refused to the ' .. role)
                    truthy(err == CH.ERR.NOT_PARTICIPANT or err == CH.ERR.OPERATIVE_GONE
                        or err == CH.ERR.BLACKLISTED_JOB, name .. ' / ' .. role .. ': ' .. tostring(err))
                    eq(total(s), money, name .. ': nothing charged to the ' .. role)
                end
            end
            local before = bank(SOURCE[BUYER[name]])
            local result, err = BUY[name](s, f, c)
            truthy(result, name .. ' sold to its buyer: ' .. tostring(err))
            truthy(bank(SOURCE[BUYER[name]]) < before or Config.Intel[({ informant = 'Informant',
                placerInformant = 'PlacerInformant', locationTip = 'LocationTip', goDark = 'GoDark' })[name]].Cost == 0,
                name .. ': charged')
        end)

        it(name .. ': a staff hold landing in the awaits refunds in full', function()
            local s, f, c = stack()
            if name == 'goDark' then assert(s.locationTip.buy(f.hitman, c.id, quote('LocationTip'))) end
            local src = SOURCE[BUYER[name]]
            local before, money = bank(src), total(s)
            local result, err = onCharge(function()
                truthy(s.holds.freeze('ADMIN', 'TARGET01', 'test', 'Target'))
            end, function() return BUY[name](s, f, c) end)
            falsy(result)
            eq(err, CH.ERR.CONTRACT_FROZEN)
            eq(bank(src), before, 'given back')
            eq(total(s), money, 'no money made or lost')
            eq(#auditRows(s, REFUNDED[name]), 1, 'refunded once, under its own action')
        end)

        it(name .. ': the contract ending in the awaits refunds in full', function()
            local s, f, c = stack()
            if name == 'goDark' then assert(s.locationTip.buy(f.hitman, c.id, quote('LocationTip'))) end
            local src = SOURCE[BUYER[name]]
            local before = bank(src)
            local real = s.storage.readContract
            local charged = false
            local result, err = onCharge(function() charged = true end, function()
                s.storage.readContract = function(id, ...)
                    local row = real(id, ...)
                    if charged and row and row.id == c.id then
                        local copy = {}
                        for k, v in pairs(row) do copy[k] = v end
                        copy.state = CH.STATE.CANCELLED
                        return copy
                    end
                    return row
                end
                local out = table.pack(BUY[name](s, f, c))
                s.storage.readContract = real
                return table.unpack(out, 1, out.n)
            end)
            falsy(result)
            truthy(err == CH.ERR.ALREADY_SETTLED or err == CH.ERR.SERVER_ERROR, tostring(err))
            eq(bank(src), before, 'given back')
            eq(#auditRows(s, REFUNDED[name]), 1)
        end)

        it(name .. ': a read that raises after the charge refunds in full', function()
            local s, f, c = stack()
            if name == 'goDark' then assert(s.locationTip.buy(f.hitman, c.id, quote('LocationTip'))) end
            local src = SOURCE[BUYER[name]]
            local before = bank(src)
            local real = s.storage.readContract
            local charged = false
            local ok = pcall(onCharge, function() charged = true end, function()
                s.storage.readContract = function(id, ...)
                    if charged then error('dropped connection') end
                    return real(id, ...)
                end
                local out = table.pack(pcall(BUY[name], s, f, c))
                s.storage.readContract = real
                if not out[1] then error(out[2], 0) end
                return table.unpack(out, 2, out.n)
            end)
            local _ = ok
            s.storage.readContract = real
            eq(bank(src), before, 'given back, whether it answered or raised')
            eq(#auditRows(s, REFUNDED[name]), 1)
        end)
    end

    it('locationTip: a target gone dark finds nothing and gives the tip back, saying so', function()
        local s, f, c = stack()
        assert(s.locationTip.buy(f.hitman, c.id, quote('LocationTip')))
        assert(s.intelRules.goDark(f.target, c.id, quote('GoDark')))
        Env.advance(Config.Intel.LocationTip.CooldownMinutes * 60 + 1)
        local before = bank(3)
        local result, err, data = s.locationTip.buy(f.hitman, c.id, quote('LocationTip'))
        falsy(result)
        eq(err, CH.ERR.TIP_NOT_FOUND)
        eq(data.refunded, true)
        eq(bank(3), before)
        eq(#auditRows(s, 'location_tip_refunded'), 1)
    end)

    it('says nothing of who placed it, who is after them, or where the target stands', function()
        local s, f, c = stack()
        for _, name in ipairs({ 'locationTip', 'placerInformant' }) do
            local result = BUY[name](s, f, c)
            truthy(result, name)
            for k, v in pairs(result) do
                local text = tostring(k) .. '=' .. tostring(v)
                falsy(text:find('CREATOR1', 1, true) or text:find('TARGET01', 1, true)
                    or text:find('HITMAN01', 1, true), name .. ' answers no citizen id: ' .. text)
                falsy(text:find('1200', 1, true), name .. ' answers no position: ' .. text)
            end
        end
    end)
end)

-- ============================================================================
--                              ONE ADMIN SCREEN GROUP
-- ============================================================================

describe('Intel in the admin panel', function()
    it('every Intel setting sits in the one Intel screen group', function()
        local s = newStack()
        local found = 0
        for _, entry in ipairs(s.settings.CATALOGUE) do
            if entry.key:find('^Intel%.') then
                found = found + 1
                eq(s.settings.areaOf(entry), 'intel', entry.key .. ' in Intel')
                truthy(entry.group == 'Intel prices' or tostring(entry.group):find('^Intel: '), entry.key)
            end
        end
        truthy(found >= 60, 'every Intel setting listed: ' .. found)
    end)
end)
