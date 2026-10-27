--- The informant tip (server/locationtip.lua, Config.LocationTip): a hitman
--- holding a live contract buys the rough area its target was in. Who may
--- buy, what it costs and when nothing is charged, the area itself, who is
--- told what, who is never sent the area, the clears, the store in all three
--- backends, a restart, and the client's blips.

local Exec = require('tests.harness.mysql_exec')
local Client = require('tests.harness.client')

--- Where the server sees the target when a tip is bought.
local TARGET_AT = { x = 1200.0, y = -800.0, z = 30.0 }
local PRICE = { cost = 25000, account = 'bank' }

--- Fire a net event as a client does, gate and rate limit and all, and
--- return the reply the page would receive. Env.clientEvents keeps what the
--- call sent.
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

--- Everything in a value, keys and values, as one string to search.
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

local function eventsNamed(name, target)
    local out = {}
    for _, event in ipairs(Env.clientEvents) do
        if event.name == name and (target == nil or event.target == target) then
            out[#out + 1] = event
        end
    end
    return out
end

--- The phone notices one player was sent by the last call: { title, content }.
local function noticesTo(src)
    local out = {}
    for _, event in ipairs(Env.clientEvents) do
        if (event.name == 'lb-phone:SendNotification' or event.name == 'crimson-hitman:notify')
            and event.target == src then
            out[#out + 1] = event.args[1]
        end
    end
    return out
end

local function bank(src) return Env.players[src].PlayerData.money.bank end

--- Every player's money, cash and bank, summed: what conservation counts.
local function moneyInTheCity()
    local total = 0
    for _, p in pairs(Env.players) do
        total = total + (p.PlayerData.money.cash or 0) + (p.PlayerData.money.bank or 0)
    end
    return total
end

local function distance(a, x, y)
    return math.sqrt((a.x - x) ^ 2 + (a.y - y) ^ 2)
end

--- A contract the hitman (source 3) holds, its target (source 2) standing at
--- TARGET_AT, shown to the target at once, the hitman able to pay.
local function taken(opts)
    opts = opts or {}
    local s = newStack()
    Config.Notifications.ParanoidAlertJitter = opts.jitter or { min = 0, max = 0 }
    local f = fixture(s, { targetJob = opts.targetJob })
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 } },
    })
    truthy(c, 'placed')
    Env.players[3].PlayerData.money.bank = opts.hitmanBank or 100000
    truthy(s.contracts.accept(f.hitman, c.id, false), 'taken')
    Env.players[2]._coords = { x = TARGET_AT.x, y = TARGET_AT.y, z = TARGET_AT.z }
    if opts.bridges then s.bridges.install(s) end
    return s, f, c
end

--- A known draw for the area: the centre three fifths of the way out, at
--- a quarter turn. The real draw is held to its rules below.
local function steadyDraw(s)
    local seq, i = { 0.6, 0.25 }, 0
    s.locationTip.random = function()
        i = i + 1
        return seq[(i - 1) % #seq + 1]
    end
end

--------------------------------------------------------------------------
-- Buying one
--------------------------------------------------------------------------

describe('an informant tip, bought', function()
    it('charges once, sends the buyer the area and nothing else, and the target is inside it', function()
        local s, _, c = taken()
        steadyDraw(s)
        local before, city = bank(3), moneyInTheCity()
        local r = buy(3, c)
        truthy(r and r.ok, 'bought: ' .. tostring(r and r.err))
        eq(bank(3), before - 25000, 'charged once, from the bank')
        eq(moneyInTheCity(), city - 25000, 'the money went to nobody')
        eq(r.data.secondsLeft, 600, 'shown for ShowMinutes')
        eq(r.data.left, 2, 'two more on this contract')
        falsy(r.data.x or r.data.y or r.data.centre, 'the reply carries no area')

        local sent = eventsNamed('crimson-hitman:locationTip')
        eq(#sent, 1, 'one tip sent')
        eq(sent[1].target, 3, 'to the buyer\'s game alone')
        local tip = sent[1].args[1]
        local keys = {}
        for k in pairs(tip) do keys[#keys + 1] = k end
        table.sort(keys)
        eq(table.concat(keys, ','), 'id,radius,secondsLeft,x,y', 'the centre and the radius only')
        eq(tip.id, c.id)
        eq(tip.radius, 350)
        local d = distance(TARGET_AT, tip.x, tip.y)
        truthy(d <= 350, 'the target is inside the circle: ' .. d)
        truthy(d <= 0.75 * 350, 'at most three quarters of the radius away: ' .. d)
        truthy(d > 1, 'and the centre is not on the target: ' .. d)
        eq(s.storage.readLocationTips(c.id)[1].centre_x, tip.x, 'kept as sent')
    end)

    it('draws the centre within three quarters of the radius, the target always inside', function()
        local s = taken()
        math.randomseed(7)
        s.locationTip.random = math.random
        local near, far, sum = 0, 0, 0
        for _ = 1, 2000 do
            local x, y = s.locationTip.areaAround(TARGET_AT.x, TARGET_AT.y, 350)
            local d = distance(TARGET_AT, x, y)
            truthy(d <= 0.75 * 350, 'never past three quarters: ' .. d)
            if d < 0.05 * 350 then near = near + 1 end
            if d > 0.5 * 350 then far = far + 1 end
            sum = sum + d
        end
        truthy(near < 0.08 * 2000, 'almost never at the middle: ' .. near)
        truthy(far > 0.2 * 2000, 'often well off it: ' .. far)
        truthy(sum / 2000 > 0.3 * 350, 'on average a long way off it')
    end)

    it('audits what was paid and by whom, and never a position', function()
        local s, _, c = taken()
        steadyDraw(s)
        truthy(buy(3, c).ok)
        local tip = eventsNamed('crimson-hitman:locationTip')[1].args[1]
        s.audit.flush()
        local rows = s.storage.auditByAction('location_tip_bought', 10)
        eq(#rows, 1, 'one row')
        eq(rows[1].actor_cid, 'HITMAN01', 'the buyer')
        eq(rows[1].contract_id, c.id, 'the contract')
        eq(rows[1].detail.amount, 25000, 'the amount')
        for key in pairs(rows[1].detail) do
            truthy(key == 'amount' or key == 'account', 'only what was paid: ' .. tostring(key))
        end
        local text = dump(rows[1])
        for _, needle in ipairs({ tostring(tip.x), tostring(tip.y), '1200', '-800' }) do
            falsy(text:find(needle, 1, true), 'no position in the audit row: ' .. text)
        end
    end)
end)

--------------------------------------------------------------------------
-- Refused, with nothing charged
--------------------------------------------------------------------------

describe('an informant tip refused, nothing charged', function()
    --- Refused, uncharged, nothing kept, nothing sent.
    local function refused(s, c, src, r, code)
        truthy(r and not r.ok, 'refused')
        eq(r.err, code)
        eq(#eventsNamed('crimson-hitman:locationTip'), 0, 'no area sent')
        eq(#s.storage.readLocationTips(c.id), 0, 'nothing kept')
        local _ = src
    end

    it('while the server sells none', function()
        local s, _, c = taken()
        Config.LocationTip.Enabled = false
        local before = bank(3)
        refused(s, c, 3, buy(3, c), CH.ERR.FEATURE_OFF)
        eq(bank(3), before)
    end)

    it('to the target, to the placer, and to anybody not on it', function()
        local s, _, c = taken()
        Env.addPlayer({ source = 4, citizenid = 'BYSTAND1', bank = 100000 })
        local banks = { [1] = bank(1), [2] = bank(2), [4] = bank(4) }
        Env.players[2].PlayerData.money.bank = 100000
        banks[2] = 100000
        refused(s, c, 2, buy(2, c), CH.ERR.NOT_FOUND)
        refused(s, c, 1, buy(1, c), CH.ERR.NOT_PARTICIPANT)
        refused(s, c, 4, buy(4, c), CH.ERR.NOT_PARTICIPANT)
        for src, was in pairs(banks) do eq(bank(src), was, 'source ' .. src .. ' charged nothing') end
    end)

    it('to a hitman on a barred job, at the gate', function()
        local s, _, c = taken()
        Env.players[3].PlayerData.job = { name = 'police', type = 'leo', onduty = true }
        local before = bank(3)
        local r = buy(3, c)
        truthy(r and not r.ok)
        eq(r.err, CH.ERR.BLACKLISTED_JOB)
        eq(bank(3), before)
        eq(#s.storage.readLocationTips(c.id), 0)
    end)

    it('while the target is not in the city', function()
        local s, _, c = taken()
        Env.removePlayer(2)
        local before = bank(3)
        refused(s, c, 3, buy(3, c), CH.ERR.TIP_TARGET_AWAY)
        eq(bank(3), before)
    end)

    it('at a price that moved since the button showed it, saying the price now', function()
        local s, _, c = taken()
        local before = bank(3)
        local r = buy(3, c, { cost = 20000, account = 'bank' })
        refused(s, c, 3, r, CH.ERR.TERMS_CHANGED)
        eq(r.data.cost, 25000)
        eq(r.data.account, 'bank')
        eq(bank(3), before)
    end)

    it('to a hitman who cannot pay', function()
        local s, _, c = taken({ hitmanBank = 1000 })
        local r = buy(3, c)
        refused(s, c, 3, r, CH.ERR.INSUFFICIENT)
        eq(bank(3), 1000, 'not overdrawn')
    end)

    it('to a hitman who walked away, and on a contract that has ended', function()
        local s, f, c = taken()
        truthy(s.contracts.abandon(f.hitman, c.id))
        local before = bank(3)
        refused(s, c, 3, buy(3, c), CH.ERR.NOT_PARTICIPANT)
        eq(bank(3), before)

        local s2, _, c2 = taken()
        s2.contracts.resolve(c2.id, CH.STATE.CANCELLED, 'CREATOR1', nil, 'test_ended')
        local before2 = bank(3)
        local r = buy(3, c2)
        truthy(r and not r.ok, 'refused on an ended contract')
        eq(bank(3), before2)
        eq(#s2.storage.readLocationTips(c2.id), 0)
    end)

    it('for an id that is not one', function()
        local s, _, c = taken()
        local r = call('locationTip', 3, { id = { 'not', 'an', 'id' }, shown = PRICE })
        eq(r.err, CH.ERR.INVALID_INPUT)
        eq(#s.storage.readLocationTips(c.id), 0)
    end)

    it('in its own rate-limit bucket', function()
        local s, _, c = taken()
        Config.Cooldowns.locationTip = { per = 3600, burst = 1 }
        truthy(buy(3, c).ok)
        Env.advance(700)
        local before = bank(3)
        local r = buy(3, c)
        eq(r.err, CH.ERR.RATE_LIMITED, 'its own bucket, spent')
        eq(bank(3), before)
        truthy(s.ratelimit.check(s.identity.resolve(3), 'informant'),
            'the informant\'s bucket is a different one')
    end)
end)

--------------------------------------------------------------------------
-- Twice at once, and the contract ending in the middle
--------------------------------------------------------------------------

describe('an informant tip under a double tap and a contract ending', function()
    it('charges once when the second tap lands while the first is running', function()
        local s, f, c = taken()
        local real, fired, inner = s.storage.readHitman, false, nil
        s.storage.readHitman = function(...)
            if not fired then
                fired = true
                inner = table.pack(s.locationTip.buy(f.hitman, c.id, PRICE))
            end
            return real(...)
        end
        local before = bank(3)
        local result, err = s.locationTip.buy(f.hitman, c.id, PRICE)
        s.storage.readHitman = real
        truthy(result, tostring(err))
        truthy(fired, 'the second tap landed inside the first')
        eq(inner[2], CH.ERR.BUSY, 'refused as busy')
        eq(bank(3), before - 25000, 'charged once')
        eq(#s.storage.readLocationTips(c.id), 1, 'one tip kept')
    end)

    it('gives the money back when the contract ends while it is being kept', function()
        local s, f, c = taken()
        local real = s.storage.writeLocationTip
        s.storage.writeLocationTip = function(row)
            real(row)
            -- The contract ends in the await the write is on mysql.
            s.contracts.resolve(c.id, CH.STATE.CANCELLED, 'CREATOR1', nil, 'test_ended')
            return true
        end
        local before, city = bank(3), moneyInTheCity()
        Env.clientEvents = {}
        local result, err = s.locationTip.buy(f.hitman, c.id, PRICE)
        s.storage.writeLocationTip = real
        falsy(result, 'not delivered')
        eq(err, CH.ERR.ALREADY_SETTLED)
        eq(bank(3), before, 'refunded in full')
        -- The reward the placer put up came home with the ending; the tip's
        -- price came home to the hitman; nothing else moved.
        eq(moneyInTheCity(), city + 5000, 'and nothing lost')
        eq(#eventsNamed('crimson-hitman:locationTip'), 0, 'nothing sent')
        eq(#s.storage.readLocationTips(c.id), 0, 'nothing kept')
        s.audit.flush()
        eq(#s.storage.auditByAction('location_tip_refunded', 10), 1, 'the refund recorded')
        eq(#s.storage.auditByAction('location_tip_bought', 10), 0, 'and no purchase')
    end)

    it('gives the money back when the store will not keep it', function()
        local s, f, c = taken()
        local real = s.storage.writeLocationTip
        s.storage.writeLocationTip = function() error('the database went away') end
        local before = bank(3)
        local result, err = s.locationTip.buy(f.hitman, c.id, PRICE)
        s.storage.writeLocationTip = real
        falsy(result)
        eq(err, CH.ERR.SERVER_ERROR)
        eq(bank(3), before, 'refunded')
        eq(#s.storage.readLocationTips(c.id), 0)
    end)

    it('leaves a refund that cannot be credited for staff', function()
        local s, f, c = taken()
        local real = s.storage.writeLocationTip
        s.storage.writeLocationTip = function() error('the database went away') end
        Env.players[3]._refuseMoney = true
        local before = bank(3)
        falsy(s.locationTip.buy(f.hitman, c.id, PRICE))
        s.storage.writeLocationTip = real
        Env.players[3]._refuseMoney = nil
        eq(bank(3), before - 25000, 'the credit was refused')
        local open = s.review.list(false, 10)
        local found
        for _, item in ipairs(open) do
            if item.kind == 'location_tip_refund_failed' then found = item end
        end
        truthy(found, 'left for staff')
        eq(found.amount, 25000)
    end)
end)

--------------------------------------------------------------------------
-- The wait between two, and the most on one contract
--------------------------------------------------------------------------

describe('informant tips over time', function()
    it('waits CooldownMinutes between two, and sells at most three', function()
        local s, f, c = taken()
        truthy(buy(3, c).ok)
        local before = bank(3)
        local r = buy(3, c)
        eq(r.err, CH.ERR.TIP_COOLDOWN, 'too soon')
        eq(r.data.untilAt, os.time() + 600, 'says until when')
        eq(bank(3), before, 'nothing charged')

        local card = s.projection.contract(s.storage.readContract(c.id), 'HITMAN01').locationTip
        eq(card.left, 2)
        eq(card.cooldownSeconds, 600, 'the card says the wait')
        eq(card.secondsLeft, 600, 'and the tip showing')

        Env.advance(601)
        truthy(buy(3, c).ok, 'the second')
        Env.advance(601)
        truthy(buy(3, c).ok, 'the third')
        Env.advance(601)
        before = bank(3)
        r = buy(3, c)
        eq(r.err, CH.ERR.LIMIT_REACHED, 'no fourth')
        eq(bank(3), before)
        eq(s.projection.contract(s.storage.readContract(c.id), 'HITMAN01').locationTip.left, 0)
        local _ = f
    end)

    it('does not reset the wait or the count when the hitman leaves and comes back', function()
        local s, f, c = taken()
        truthy(buy(3, c).ok)
        truthy(s.contracts.abandon(f.hitman, c.id))
        local back = s.contracts.accept(f.hitman, c.id, false)
        if not back then return end  -- a server that refuses a quick retake has nothing to reset
        local r = buy(3, c)
        eq(r.err, CH.ERR.TIP_COOLDOWN, 'still waiting')
    end)
end)

--------------------------------------------------------------------------
-- The target
--------------------------------------------------------------------------

describe('the target of an informant tip', function()
    local TEXT = 'Someone has been tipped off about your rough location. They know the area '
        .. 'you were in, not exactly where you are.'

    it('is told at once through the notice budget, never by whom or where', function()
        local s, _, c = taken()
        steadyDraw(s)
        truthy(buy(3, c).ok)
        local tip = eventsNamed('crimson-hitman:locationTip')[1].args[1]
        local notices = noticesTo(2)
        eq(#notices, 1, 'one notice')
        eq(notices[1].content, TEXT)
        for _, event in ipairs(Env.clientEvents) do
            if event.target == 2 then
                local text = dump(event.args)
                for _, needle in ipairs({ 'Rook', 'Ash', 'HITMAN01', 'Operative', tostring(tip.x),
                    tostring(tip.y), '1200', '-800' }) do
                    falsy(text:find(needle, 1, true), 'the target is never sent ' .. needle)
                end
            end
        end
        local card = s.projection.onMe('TARGET01')[1]
        eq(card.tippedAt, os.time(), 'On me says when')
        falsy(card.locationTip, 'and nothing of the tip itself')
    end)

    it('spends the notice budget, kept past it rather than dropped', function()
        local s, _, c = taken()
        Config.Notifications.MaxPerRecipientPerMinute = 0
        truthy(buy(3, c).ok)
        eq(#noticesTo(2), 0, 'past the budget: not now')
        local count, titles = s.notify.waitingFor('TARGET01')
        eq(count, 1, 'kept for when the minute opens')
        eq(titles[1], 'Informant tip')
    end)

    it('is not told inside the wait before the contract is shown to them, but after it', function()
        local s, _, c = taken({ jitter = { min = 300, max = 300 } })
        truthy(buy(3, c).ok)
        eq(#noticesTo(2), 0, 'not before On me shows the contract')
        eq(#s.projection.onMe('TARGET01'), 0, 'which does not show it yet')
        Env.clientEvents = {}
        Env.advance(301)
        local told = 0
        for _, notice in ipairs(noticesTo(2)) do
            if notice.content == TEXT then told = told + 1 end
        end
        eq(told, 1, 'told once it is shown')
    end)

    it('is told nothing with NotifyTarget off', function()
        local s, _, c = taken()
        Config.LocationTip.NotifyTarget = false
        truthy(buy(3, c).ok)
        eq(#noticesTo(2), 0)
        eq(s.projection.onMe('TARGET01')[1].tippedAt, nil)
    end)

    it('on a barred job, sees it on the whitelisted-job view', function()
        local s, _, c = taken({ targetJob = { name = 'police', type = 'leo', onduty = true } })
        truthy(c)
        truthy(buy(3, c).ok)
        local view = s.projection.whitelistedView('TARGET01',
            { name = 'police', type = 'leo', onduty = true })
        eq(#view.onYou, 1)
        eq(view.onYou[1].tippedAt, os.time())
        local keys = {}
        for k in pairs(view.onYou[1]) do keys[#keys + 1] = k end
        for _, k in ipairs(keys) do
            truthy(s.projection.WHITELISTED_KEYS.entry[k] or s.projection.WHITELISTED_KEYS.own[k],
                'a key the view may carry: ' .. k)
        end
    end)
end)

--------------------------------------------------------------------------
-- Nobody but the buyer is sent the area
--------------------------------------------------------------------------

describe('who is sent an informant tip\'s area', function()
    it('nobody but the buyer: not the board, the placer, another hitman or the target', function()
        local s, f, c = taken()
        steadyDraw(s)
        Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
            bank = 100000, firstname = 'Sly', lastname = 'Fox' })
        truthy(s.contracts.accept(s.identity.resolve(4), c.id, false), 'a second hitman')
        truthy(buy(3, c).ok)
        local tip = eventsNamed('crimson-hitman:locationTip')[1].args[1]
        local needles = { tostring(tip.x), tostring(tip.y) }

        local function clean(value, who)
            local text = dump(value)
            for _, needle in ipairs(needles) do
                falsy(text:find(needle, 1, true), who .. ' is sent the area')
            end
        end
        for _, cid in ipairs({ 'CREATOR1', 'HITMAN02', 'TARGET01', 'HITMAN01' }) do
            local board = s.projection.listing(cid, 1)
            clean(board, 'the board, to ' .. cid)
            for _, row in ipairs(board.contracts) do falsy(row.locationTip, 'no tip on the board') end
        end
        local placer = s.projection.mine('CREATOR1')[1]
        clean(placer, 'the placer')
        falsy(placer.locationTip or placer.tippedAt, 'the placer is told nothing of it')
        local other = s.projection.accepted('HITMAN02')[1]
        clean(other, 'the other hitman')
        falsy(other.locationTip and other.locationTip.secondsLeft, 'the other hitman has none showing')
        eq(other.locationTip.left, 3, 'and counts only their own')
        clean(s.projection.onMe('TARGET01'), 'the target')
        local mine = s.projection.accepted('HITMAN01')[1]
        clean(mine, 'the buyer\'s own card')
        eq(mine.locationTip.secondsLeft, 600, 'the buyer\'s card says it is showing')

        for _, event in ipairs(Env.clientEvents) do
            if not (event.name == 'crimson-hitman:locationTip' and event.target == 3) then
                clean(event.args, event.name .. ' to ' .. tostring(event.target))
            end
        end
        local _ = f
    end)

    it('to staff without crimson.identity, only that a hitman bought one', function()
        local s, _, c = taken({ bridges = true })
        steadyDraw(s)
        Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001' })
        Env.addPlayer({ source = 8, citizenid = 'UNMASK01', license = 'license:UNMASK01' })
        Env.aces[6] = { ['crimson.admin'] = true }
        Env.aces[8] = { ['crimson.admin'] = true, ['crimson.identity'] = true }
        Config.Cooldowns.admin = { per = 10, burst = 500 }
        truthy(buy(3, c).ok)
        local tip = eventsNamed('crimson-hitman:locationTip')[1].args[1]

        local function logs(src)
            Env.clientEvents = {}
            _G.source = src
            Env.events['crimson-hitman:admin']({ op = 'logs',
                data = { action = 'location_tip', limit = 10 }, __rid = 1 })
            _G.source = nil
            for _, event in ipairs(Env.clientEvents) do
                if event.name == 'crimson-hitman:adminResult' then return event.args[1] end
            end
        end
        local plain = logs(6)
        truthy(plain and plain.ok, 'answered')
        eq(#plain.data.rows, 1)
        eq(plain.data.rows[1].actor, 'a hitman', 'never which operative')
        eq(plain.data.rows[1].detail.said, 'a hitman bought an informant tip')
        local text = dump(plain)
        falsy(text:find('HITMAN01', 1, true) or text:find('Operative', 1, true), 'nobody named')
        falsy(text:find(tostring(tip.x), 1, true), 'no area')

        local named = logs(8)
        eq(named.data.rows[1].actor, 'HITMAN01', 'with crimson.identity, who')
        falsy(dump(named):find(tostring(tip.x), 1, true), 'and still no area')
    end)
end)

--------------------------------------------------------------------------
-- Off the map, and back on it after a restart
--------------------------------------------------------------------------

describe('an informant tip coming off the map', function()
    it('when its time runs out, the server says so', function()
        local s, _, c = taken({ bridges = true })
        truthy(buy(3, c).ok)
        Env.clientEvents = {}
        Env.advance(599)
        eq(#eventsNamed('crimson-hitman:locationTipClear', 3), 0, 'not yet')
        Env.advance(2)
        local cleared = eventsNamed('crimson-hitman:locationTipClear', 3)
        eq(#cleared, 1, 'cleared once its time is up')
        eq(cleared[1].args[1].id, c.id)
        eq(s.projection.accepted('HITMAN01')[1].locationTip.secondsLeft, nil, 'and off the card')
    end)

    it('when the contract ends, with its records', function()
        local s, _, c = taken({ bridges = true })
        truthy(buy(3, c).ok)
        Env.clientEvents = {}
        s.contracts.resolve(c.id, CH.STATE.CANCELLED, 'CREATOR1', nil, 'test_ended')
        eq(#eventsNamed('crimson-hitman:locationTipClear', 3), 1, 'off the buyer\'s map')
        eq(#s.storage.readLocationTips(c.id), 0, 'its records gone')
    end)

    it('when the hitman leaves the contract, its record kept', function()
        local s, f, c = taken({ bridges = true })
        truthy(buy(3, c).ok)
        Env.clientEvents = {}
        truthy(s.contracts.abandon(f.hitman, c.id))
        eq(#eventsNamed('crimson-hitman:locationTipClear', 3), 1, 'off their map')
        eq(#s.storage.readLocationTips(c.id), 1, 'the record stays, for the wait and the count')
        Env.clientEvents = {}
        Env.advance(601)
        eq(#eventsNamed('crimson-hitman:locationTipClear', 3), 0, 'its timer went with it')
    end)

    it('comes back on the buyer\'s map after a restart while it has time left', function()
        local s, f, c = taken()
        steadyDraw(s)
        truthy(buy(3, c).ok)
        local first = eventsNamed('crimson-hitman:locationTip')[1].args[1]
        Env.advance(120)
        -- A fresh process over the same store: nothing in memory.
        s.locationTip.init({ storage = s.storage, identity = s.identity, audit = s.audit,
            notify = s.notify, contracts = s.contracts, review = s.review })
        local r = call('locationTips', 3, {})
        truthy(r and r.ok, tostring(r and r.err))
        eq(r.data.shown, 1)
        local again = eventsNamed('crimson-hitman:locationTip', 3)
        eq(#again, 1, 'sent again')
        eq(again[1].args[1].x, first.x, 'the same area')
        eq(again[1].args[1].y, first.y)
        eq(again[1].args[1].secondsLeft, 480, 'for the time it has left')
        eq(#eventsNamed('crimson-hitman:locationTip', 2), 0, 'to nobody else')

        r = call('locationTips', 2, {})
        eq(r.data.shown, 0, 'the target asking gets nothing')
        Env.advance(481)
        r = call('locationTips', 3, {})
        eq(r.data.shown, 0, 'nothing once it has run out')
        local _ = f
    end)
end)

--------------------------------------------------------------------------
-- The store
--------------------------------------------------------------------------

describe('informant tips in every store', function()
    local function row(id, contractId, buyer, at, expires)
        return { id = id, contract_id = contractId, buyer_cid = buyer, bought_at = at,
                 expires_at = expires, centre_x = 1000, centre_y = -900, radius = 350,
                 target_told = true }
    end

    local function backends()
        package.loaded['crimson-hitman.server.storage.memory'] = nil
        package.loaded['crimson-hitman.server.storage.json'] = nil
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        Natives.files = {}
        local memory = require('crimson-hitman.server.storage.memory')
        local jsonStore = require('crimson-hitman.server.storage.json')
        memory.open()
        jsonStore.open()
        Exec.install(Natives)
        local mysqlStore = require('crimson-hitman.server.storage.mysql')
        mysqlStore.open()
        return { memory = memory, json = jsonStore, mysql = mysqlStore }
    end

    it('writes, reads, lists the live ones, and clears, the same in all three', function()
        for name, store in pairs(backends()) do
            store.writeLocationTip(row('ct00000001:HITMAN01:001', 'ct00000001', 'HITMAN01', 100, 700))
            store.writeLocationTip(row('ct00000001:HITMAN01:002', 'ct00000001', 'HITMAN01', 800, 1400))
            store.writeLocationTip(row('ct00000002:HITMAN01:001', 'ct00000002', 'HITMAN01', 900, 1500))
            store.writeLocationTip(row('ct00000001:HITMAN02:001', 'ct00000001', 'HITMAN02', 850, 1450))
            local rows = store.readLocationTips('ct00000001')
            eq(#rows, 3, name .. ': every tip on the contract')
            eq(rows[1].id, 'ct00000001:HITMAN01:001', name .. ': oldest first')
            eq(tonumber(rows[1].centre_x), 1000, name .. ': the centre kept')
            eq(tonumber(rows[1].radius), 350, name)
            truthy(rows[1].target_told == true or rows[1].target_told == 1, name .. ': told')
            local live = store.liveLocationTips('HITMAN01', 1000)
            eq(#live, 2, name .. ': the buyer\'s, still showing')
            store.deleteLocationTip('ct00000001:HITMAN01:002')
            eq(#store.readLocationTips('ct00000001'), 2, name .. ': one refunded, gone')
            store.clearLocationTips('ct00000001')
            eq(#store.readLocationTips('ct00000001'), 0, name .. ': cleared with its contract')
            eq(#store.readLocationTips('ct00000002'), 1, name .. ': another contract\'s kept')
        end
    end)

    it('survives a restart in json and mysql', function()
        local stores = backends()
        stores.json.writeLocationTip(row('ct00000001:HITMAN01:001', 'ct00000001', 'HITMAN01', 100, 900))
        stores.json.close()
        package.loaded['crimson-hitman.server.storage.json'] = nil
        local json2 = require('crimson-hitman.server.storage.json')
        json2.open()
        eq(#json2.liveLocationTips('HITMAN01', 200), 1, 'json: kept across a restart')

        stores.mysql.writeLocationTip(row('ct00000001:HITMAN01:001', 'ct00000001', 'HITMAN01', 100, 900))
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local mysql2 = require('crimson-hitman.server.storage.mysql')
        mysql2.open()
        eq(#mysql2.liveLocationTips('HITMAN01', 200), 1, 'mysql: kept across a restart')
        eq(tonumber(mysql2.readLocationTips('ct00000001')[1].centre_y), -900)
    end)
end)

--------------------------------------------------------------------------
-- The client
--------------------------------------------------------------------------

describe('an informant tip on the client', function()
    local function shown()
        local area, centre
        for _, blip in pairs(Client.blips) do
            if blip.kind == 'radius' then area = blip else centre = blip end
        end
        return area, centre
    end

    it('draws a see-through red circle and a named centre, and takes both off when told', function()
        Env.reset()
        Client.boot()
        truthy(Client.fire('crimson-hitman:locationTip',
            { id = 'ct00000001', x = 1234, y = -568, radius = 350, secondsLeft = 600 }))
        local area, centre = shown()
        truthy(area, 'a radius blip')
        eq(area.radius, 350.0)
        eq(area.x, 1234.0)
        eq(area.colour, 1, 'red')
        truthy(area.alpha > 0 and area.alpha < 255, 'see-through')
        truthy(centre, 'a centre blip')
        eq(centre.name, 'Informant tip')
        eq(centre.y, -568.0)

        Client.fire('crimson-hitman:locationTipClear', { id = 'ct00000001' })
        eq(next(Client.blips), nil, 'both removed')
        truthy(Client.blipsMade[1].removed and Client.blipsMade[2].removed)
    end)

    it('sets the GPS on the centre, and tells the page nothing of where', function()
        Env.reset()
        Client.boot()
        Client.fire('crimson-hitman:locationTip',
            { id = 'ct00000001', x = 1234, y = -568, radius = 350, secondsLeft = 600 })
        local marked, real = {}, _G.SetNewWaypoint
        _G.SetNewWaypoint = function(x, y) marked[#marked + 1] = { x = x, y = y } end
        Client.nuiCall('crimson:tipGps', { id = 'ct00000001' })
        eq(#marked, 1)
        eq(marked[1].x, 1234.0)
        eq(marked[1].y, -568.0)
        eq(Client.answer.ok, true)
        eq(Client.answer.data, nil, 'nothing of where to the page')
        eq(#Client.toServer, 0, 'nothing asked of the server')

        Client.fire('crimson-hitman:locationTipClear', { id = 'ct00000001' })
        Client.nuiCall('crimson:tipGps', { id = 'ct00000001' })
        _G.SetNewWaypoint = real
        eq(#marked, 1, 'nothing marked once it is gone')
        eq(Client.answer.err, 'no_tip')
    end)

    it('takes it off by itself when its time runs out, and replaces an older one', function()
        Env.reset()
        Client.boot()
        Client.fire('crimson-hitman:locationTip',
            { id = 'ct00000001', x = 10, y = 20, radius = 350, secondsLeft = 60 })
        Client.fire('crimson-hitman:locationTip',
            { id = 'ct00000001', x = 30, y = 40, radius = 350, secondsLeft = 600 })
        local count = 0
        for _ in pairs(Client.blips) do count = count + 1 end
        eq(count, 2, 'one circle and one centre: the older pair went')
        local area = shown()
        eq(area.x, 30.0, 'the newer one')
        Client.runTimeouts()
        eq(next(Client.blips), nil, 'gone once the time is up')
    end)

    it('ignores what is not a tip, and leaves nothing after a restart', function()
        Env.reset()
        Client.boot()
        Client.fire('crimson-hitman:locationTip', 'not a table')
        Client.fire('crimson-hitman:locationTip', { id = 'ct00000001', x = 'a', y = 2, radius = 3,
            secondsLeft = 60 })
        eq(next(Client.blips), nil, 'nothing drawn')
        Client.fire('crimson-hitman:locationTip',
            { id = 'ct00000001', x = 1, y = 2, radius = 350, secondsLeft = 60 })
        truthy(Client.fire('onResourceStop', 'crimson-hitman'))
        eq(next(Client.blips), nil, 'cleared as the resource stops')
    end)

    it('asks for the tips still showing once the app is theirs', function()
        Env.reset()
        Client.boot()
        Client.fire('crimson-hitman:access', true, 'full')
        local asked = false
        for _, sent in ipairs(Client.toServer) do
            if sent.name == 'crimson-hitman:locationTips' then asked = true end
        end
        truthy(asked, 'asked the server')
    end)
end)

--------------------------------------------------------------------------
-- The admin panel
--------------------------------------------------------------------------

describe('informant tips in the admin panel', function()
    it('lists the switches under Features and the figures under Limits, kept like the others', function()
        local s, _, c = taken()
        local view = s.settings.view()
        local features, limits = {}, {}
        for _, row in ipairs(view.features) do features[row.key] = row end
        for _, row in ipairs(view.limits) do limits[row.key] = row end
        for _, key in ipairs({ 'LocationTip.Enabled', 'LocationTip.NotifyTarget' }) do
            truthy(features[key], key .. ' is a switch under Features')
            eq(features[key].group, 'Informant tip')
        end
        for _, key in ipairs({ 'LocationTip.Cost', 'LocationTip.RadiusMeters', 'LocationTip.ShowMinutes',
            'LocationTip.CooldownMinutes', 'LocationTip.MaxPurchasesPerContract',
            'Cooldowns.locationTip.per', 'Cooldowns.locationTip.burst' }) do
            truthy(limits[key], key .. ' is under Limits')
        end

        truthy(s.settings.set('LocationTip.Cost', 30000, 'ADMIN001', 'ADMIN001'))
        eq(Config.LocationTip.Cost, 30000, 'in force at once')
        eq(s.storage.readSettings()['LocationTip.Cost'].value, 30000, 'and kept')
        eq(s.projection.listing('HITMAN01', 1).settings.locationTip.cost, 30000,
            'and quoted by the button')
        local r = buy(3, c)
        eq(r.err, CH.ERR.TERMS_CHANGED, 'a page still quoting the old price is refused')

        falsy(s.settings.set('LocationTip.RadiusMeters', 20, 'ADMIN001'),
            'an area too small to search is refused')
        eq(Config.LocationTip.RadiusMeters, 350)
        truthy(s.settings.set('LocationTip.Enabled', false, 'ADMIN001'))
        eq(buy(3, c).err, CH.ERR.FEATURE_OFF, 'switched off at once')
    end)
end)

--------------------------------------------------------------------------
-- Law enforcement told when the target is on a whitelisted job
--------------------------------------------------------------------------

describe('an informant tip on a member of a whitelisted job', function()
    local OFFICER = { name = 'police', type = 'leo', onduty = true }

    --- A contract on an officer, held by the hitman, with a colleague online.
    local function onOfficer()
        local s, f, c = taken({ targetJob = { name = 'sheriff', type = 'leo', onduty = true } })
        Env.addPlayer({ source = 20, citizenid = 'OFFICER1', license = 'license:o1',
            job = OFFICER, firstname = 'Ada', lastname = 'Kane' })
        return s, f, c
    end

    local function tipBulletins()
        local out = {}
        for _, note in ipairs(Natives.calls.notifications) do
            if tostring(note.title):find('TIP', 1, true) then out[#out + 1] = note end
        end
        return out
    end

    local function tipDispatches()
        local out = {}
        for _, call in ipairs(Natives.calls.dispatch) do
            if tostring(call.unique_id):find('-tip', 1, true) then out[#out + 1] = call end
        end
        return out
    end

    it('tells law enforcement and dispatch a hitman is closing in, never who or where', function()
        local s, _, c = onOfficer()
        steadyDraw(s)
        truthy(buy(3, c).ok, 'bought')
        local notes = tipBulletins()
        eq(#notes, 1, 'the colleague is told, not the targeted officer again')
        truthy(notes[1].content:find('has been tipped off about', 1, true))
        truthy(notes[1].content:find('closing in', 1, true))
        truthy(notes[1].content:find(c.target_name, 1, true), 'names the target')
        local calls = tipDispatches()
        eq(#calls, 1, 'one dispatch call')
        eq(calls[1].unique_id, 'ch-' .. c.id .. '-tip')
        local said = dump(notes) .. ' ' .. dump(calls)
        for _, hidden in ipairs({ 'HITMAN01', 'license:ccc', '1200', '-800', 'radius' }) do
            falsy(said:find(hidden, 1, true), 'never carries ' .. hidden)
        end
        local hitman = Env.players[3].PlayerData.charinfo
        falsy(said:find(hitman.lastname, 1, true), 'never the hitman\'s name')
    end)

    it('says nothing to law enforcement for a civilian target', function()
        local _, _, c = taken()
        Env.addPlayer({ source = 20, citizenid = 'OFFICER1', license = 'license:o1',
            job = OFFICER, firstname = 'Ada', lastname = 'Kane' })
        truthy(buy(3, c).ok)
        eq(#tipBulletins(), 0)
        eq(#tipDispatches(), 0)
    end)

    it('sends none with OnLocationTip off, or with the advisory off', function()
        for _, off in ipairs({ 'OnLocationTip', 'Enabled' }) do
            local _, _, c = onOfficer()
            Config.Advisory[off] = false
            truthy(buy(3, c).ok, 'bought with ' .. off .. ' off')
            eq(#tipBulletins(), 0, off .. ' off: no bulletin')
            eq(#tipDispatches(), 0, off .. ' off: no dispatch')
            Config.Advisory[off] = true
        end
    end)

    it('shows on a colleague\'s whitelisted-job view, with when and nothing more', function()
        local s, _, c = onOfficer()
        eq(s.projection.whitelistedView('OFFICER1', OFFICER).colleagues[1].tipAdvisedAt, nil,
            'nothing before a tip')
        truthy(buy(3, c).ok)
        local entry = s.projection.whitelistedView('OFFICER1', OFFICER).colleagues[1]
        truthy(entry, 'listed')
        eq(entry.tipAdvisedAt, os.time() - (os.time() % CrimsonBoot.requireShared('util').CLOCK_STEP))
        for k in pairs(entry) do
            truthy(s.projection.WHITELISTED_KEYS.entry[k], 'a key the view may carry: ' .. k)
        end
        Config.Advisory.OnLocationTip = false
        eq(s.projection.whitelistedView('OFFICER1', OFFICER).colleagues[1].tipAdvisedAt, nil,
            'not while those bulletins are off')
        Config.Advisory.OnLocationTip = true
    end)

    it('is a panel switch, and its dispatch call is cleared with the contract', function()
        local s, _, c = onOfficer()
        truthy(s.settings.set('Advisory.OnLocationTip', false, 'ADMIN001'))
        eq(Config.Advisory.OnLocationTip, false)
        truthy(s.settings.set('Advisory.OnLocationTip', true, 'ADMIN001'))
        truthy(buy(3, c).ok)
        Natives.calls.dispatchCleared = {}
        local before = #Env.threads
        s.notify.clearContract(c.id, s.storage.readContract(c.id))
        for i = before + 1, #Env.threads do Env.threads[i]() end
        local cleared = {}
        for _, call in ipairs(Natives.calls.dispatchCleared) do cleared[call.uid] = true end
        truthy(cleared['ch-' .. c.id .. '-tip'], 'the tip bulletin comes off the MDT')
    end)
end)
