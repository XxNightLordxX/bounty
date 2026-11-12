--- The player-journey review, part 1: each confirmed finding as the journey
--- that showed it, now held.
---
---   HITMAN-1     a target who quits mid-handover, or while being shot, comes
---                back without the login floor for the operative at work on
---                them; a target who crashed with nobody at work on them
---                keeps it;
---   HITMAN-2     a character relog asks again for the meeting point and the
---                informant tips (their markers come back);
---   HITMAN-3     a hitman who drops while the placer confirms keeps the
---                handover the hold already proved;
---   HITMAN-4     a hitman who drops seconds after a kill can verify it when
---                back inside its window;
---   NEWCOMER-2   a buyout refused for want of money says whether the two
---                accounts together would cover it;
---   NEWCOMER-4   a character switch tells an open page to drop what it held;
---   NEWCOMER-5   the target search marks somebody too new to be a target;
---   FAILPATHS-1  a notice on the game feed (no phone) keeps all its words;
---   FAILPATHS-2  a first headshot that never came is asked for again soon;
---   FAILPATHS-3  a handover re-arm refused for its wait says how long, and
---                why;
---   STUBS-2      a server-made vehicle is made as its model's own type;
---   EXPLOITER-2  a rumour's area stays the one first told, across restarts.
---
--- The page's halves (NEWCOMER-1/2/3/5, FAILPATHS-3, VISUAL-6) are in
--- tests/ui/run.js, "player review, part 1".

local W = require('tests.workflows.lib')
local F = require('tests.workflows.flows')
local C = W.CAST

local function src(role) return C[role].source end

local function boot(cfg)
    W.boot('memory', 'shipped', cfg)
    W.cast(W.s)
end

local function place(extra, ctx)
    local d = W.ok(src('creator'), 'create', F.placePayload(ctx or { reward = 5000 }, extra), 'place')
    return d.id
end

local function accept(id, who)
    who = who or 'hitman'
    local board = W.ok(src(who), 'list', { page = 1 })
    local found
    for _, c in ipairs(board.contracts or {}) do if c.id == id then found = c end end
    assert(found, 'the contract is on the board')
    local r = W.phone(src(who), 'accept', { id = id, anonymous = false, penaltyAmount = found.penaltyAmount or 0,
        timeLeft = found.timeLeft, shown = { hitmanFee = 0, feeAccount = 'bank',
        creatorAnonymous = found.creatorAnonymous == true, fulfilment = found.fulfilment,
        bailoutAmount = found.bailoutAmount } })
    assert(r.ok, 'accepted: ' .. tostring(r.err))
end

--- Kidnap ticks covering `seconds`.
local function passes(seconds)
    for _ = 1, math.ceil(seconds * 1000 / Config.Kidnap.TickMs) do W.s.kidnap.tick(Config.Kidnap.TickMs) end
end

local function cuffed(role) Env.players[src(role)].PlayerData.metadata.ishandcuffed = true end

--- Under 'either', with the kill verified at the scene.
local function bootEither(extra)
    boot(function()
        Config.Completion.Fulfilment = 'either'
        Config.Completion.KillPhotos = false
        if extra then extra() end
    end)
end

--- A hit the server sees land, as the death sampler and the damage event
--- record one.
local function shoot(by, victim, healthAfter)
    W.at(src(by), 100, 100, 30); W.at(src(victim), 101, 100, 30)
    Env.players[src(victim)]._health = 150
    W.sample()
    W.event('weaponDamageEvent', src(by), { weaponDamage = 50, weaponType = 453432689,
        hitGlobalIds = { 1000 + src(victim) } })
    Env.players[src(victim)]._health = healthAfter
end

local function kill(by, victim)
    by, victim = by or 'hitman', victim or 'target'
    W.at(src(by), 100, 100, 30); W.at(src(victim), 101, 100, 30)
    Env.players[src(victim)]._health = 120
    W.sample()
    W.event('weaponDamageEvent', src(by), { weaponDamage = 50, weaponType = 453432689,
        hitGlobalIds = { 1000 + src(victim) } })
    Env.players[src(victim)]._health = 0
    Env.players[src(victim)].PlayerData.metadata.isdead = true
    Env.advance(1)
    W.net(src(victim), 'crimson-hitman:iDied', src(by))
    Env.advance(2)
end

-- ============================================================================
--                              HITMAN-1
-- ============================================================================

describe('HITMAN-1: a target who quits while an operative is at work on them', function()
    it('back mid-handover: the operative arms again at once, not after the ten-minute floor', function()
        boot()
        local id = place(); accept(id)
        W.allAt(); cuffed('target')
        local r = W.phone(src('hitman'), 'armKidnap', { id = id })
        truthy(r.ok, 'armed: ' .. tostring(r.err))
        passes(25)
        W.drop(src('target')); passes(20)
        W.tick(1, 20)
        W.rejoin(src('target')); W.allAt(); cuffed('target')
        W.tick(1, 45)
        r = W.phone(src('hitman'), 'armKidnap', { id = id })
        truthy(r.ok, 'armed again 65 s after they came back: ' .. tostring(r.err))
    end)

    it('shot and gone before dying: the kill after they come back pays', function()
        bootEither()
        local id = place(); accept(id)
        shoot('hitman', 'target', 110)
        W.drop(src('target')); W.tick(1, 30); W.rejoin(src('target'))
        Env.players[src('target')]._health = 200
        Env.players[src('target')].PlayerData.metadata.isdead = false
        W.tick(1, 120)
        kill()
        local r = W.phone(src('hitman'), 'verifyKill', { id = id })
        truthy(r.ok, 'verified 2 min after the rejoin: ' .. tostring(r.err))
    end)

    it('a genuine crash with nobody at work on them keeps the login floor', function()
        boot()
        local id = place(); accept(id)
        W.drop(src('target')); W.tick(1, 30)
        W.rejoin(src('target')); W.allAt(); cuffed('target')
        W.tick(1, 45)
        local r = W.phone(src('hitman'), 'armKidnap', { id = id })
        falsy(r.ok)
        eq(r.err, CH.ERR.TARGET_JUST_ON, 'the floor, as before')
    end)

    it('the floor still applies to an operative who was not at work on them', function()
        boot()
        local id = place(); accept(id)
        W.allAt(); cuffed('target')
        truthy(W.phone(src('hitman'), 'armKidnap', { id = id }).ok)
        passes(10)
        W.drop(src('target')); W.tick(1, 20)
        W.rejoin(src('target'))
        truthy(W.s.identity.leftEngagedWith(C.target.cid, C.hitman.cid), 'the operative at work on them')
        falsy(W.s.identity.leftEngagedWith(C.target.cid, C.hitman2.cid), 'anybody else')
        local immune, why = W.s.contracts.isImmune(W.s.identity.resolve(src('target')),
            { fulfilment = CH.FULFILMENT.KIDNAPPING, hitmanCid = C.hitman2.cid })
        truthy(immune); eq(why, CH.ERR.TARGET_JUST_ON)
    end)

    it('back later than the floor itself: nothing kept, the floor applies to everybody', function()
        boot()
        local id = place(); accept(id)
        W.allAt(); cuffed('target')
        truthy(W.phone(src('hitman'), 'armKidnap', { id = id }).ok)
        passes(10)
        W.drop(src('target'))
        W.tick(1, Config.Immunity.MinTargetSessionMinutes * 60 + 60)
        W.rejoin(src('target'))
        falsy(W.s.identity.leftEngagedWith(C.target.cid, C.hitman.cid))
    end)
end)

-- ============================================================================
--                              HITMAN-2 / NEWCOMER-4
-- ============================================================================

local function blips(Client)
    local n = 0
    for _, b in pairs(Client.blips or {}) do if not b.removed then n = n + 1 end end
    return n
end

--- A character logging out and back in, without quitting the game.
local function relog(Client, who)
    Client.fire('QBCore:Client:OnPlayerUnload')
    Client.fire('qbx_core:client:playerLoggedOut')
    W.event('QBCore:Server:OnPlayerUnload', src(who))
    W.event('qbx_core:server:playerLoggedOut', src(who))
    W.pump()
    W.loaded(src(who))
    W.pump()
    Client.runThreads(); W.pump()
end

local function pushes(Client, reason)
    local n = 0
    for _, call in ipairs(Client.phone or {}) do
        local m = call.message
        if call.call == 'SendCustomAppMessage' and type(m) == 'table' and m.type == 'push' and m.reason == reason then
            n = n + 1
        end
    end
    return n
end

describe('HITMAN-2: the meeting point after a character relog', function()
    it('comes back on the map: the client asks again once the next login has the app', function()
        boot()
        local id = place()
        W.at(src('creator'), 300, 300, 30)
        local Client = W.client(src('hitman'))
        accept(id)
        truthy(W.phone(src('creator'), 'setMeeting', { id = id, x = 300, y = 300, z = 30 }).ok)
        W.pump()
        eq(blips(Client), 1, 'the meeting point is on their map')
        local asks = 0
        local real = Env.events['crimson-hitman:locationTips']
        Env.events['crimson-hitman:locationTips'] = function(...) asks = asks + 1 return real(...) end
        relog(Client, 'hitman')
        Env.events['crimson-hitman:locationTips'] = real
        eq(asks, 1, 'asked again once')
        eq(blips(Client), 1, 'drawn again')
    end)
end)

describe('NEWCOMER-4: a character switch with the app open', function()
    it('tells the page to drop what it held for the last character, once the next one has its access', function()
        boot()
        local Client = W.client(src('creator'))
        W.pump()
        eq(pushes(Client, 'access'), 0, 'the first login of the game is the page\'s own first read')
        relog(Client, 'creator')
        eq(pushes(Client, 'access'), 1, 'the page is told to read again')
        -- And only for a switch: the next access the server sends says nothing.
        Client.fire('crimson-hitman:access', true, 'full')
        eq(pushes(Client, 'access'), 1, 'nothing more')
    end)
end)

-- ============================================================================
--                              HITMAN-3 / HITMAN-4
-- ============================================================================

describe('HITMAN-3: a hitman who drops while the placer confirms', function()
    it('keeps the handover the hold proved: the placer confirms and the contract is paid', function()
        boot(function() Config.Kidnap.PlacerConfirms = true end)
        local id = place(); accept(id)
        W.allAt()
        truthy(W.phone(src('hitman'), 'armKidnap', { id = id }).ok)
        passes(32)
        W.drop(src('hitman'))
        local r = W.phone(src('creator'), 'confirmHandover', { id = id })
        truthy(r.ok, 'confirmed: ' .. tostring(r.err))
        passes(5); W.tick(1, 5)
        eq(W.contract(id).state, CH.STATE.COMPLETED, 'paid out')
    end)

    it('a countdown still being held goes with the hitman, as before', function()
        boot(function() Config.Kidnap.PlacerConfirms = true end)
        local id = place(); accept(id)
        W.allAt()
        truthy(W.phone(src('hitman'), 'armKidnap', { id = id }).ok)
        passes(10)
        W.drop(src('hitman'))
        eq(W.s.kidnap.activeCount(), 0)
    end)
end)

describe('HITMAN-4: a hitman who drops seconds after a kill', function()
    it('verifies it once back inside the window', function()
        bootEither()
        local id = place(); accept(id)
        kill()
        W.drop(src('hitman')); Env.advance(20); W.rejoin(src('hitman'))
        W.at(src('hitman'), 100, 100, 30)
        local r = W.phone(src('hitman'), 'verifyKill', { id = id })
        truthy(r.ok, 'verified: ' .. tostring(r.err))
        eq(W.contract(id).state, CH.STATE.COMPLETED)
    end)
end)

-- ============================================================================
--                              NEWCOMER-2 / NEWCOMER-5
-- ============================================================================

describe('NEWCOMER-2: a buyout the target cannot pay', function()
    local function buyout(cash, bank)
        boot()
        local id = place({}, { reward = 5000, bailout = 3000 })
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        W.tick(1)
        local money = Env.players[src('target')].PlayerData.money
        money.cash, money.bank = cash, bank
        return W.phone(src('target'), 'bailout', { id = id })
    end

    it('says when the two accounts together do not cover it', function()
        local r = buyout(0, 1000)
        falsy(r.ok); eq(r.err, CH.ERR.INSUFFICIENT)
        eq(r.data and r.data.short, true, 'short of it altogether')
    end)

    it('and not when it is only split between them', function()
        local need = buyout(0, 0).data.need
        local r = buyout(need - 1, need - 1)
        falsy(r.ok); eq(r.err, CH.ERR.INSUFFICIENT)
        falsy(r.data and r.data.short, 'enough between them')
        eq(r.data and r.data.account, 'bank_or_cash')
    end)
end)

describe('NEWCOMER-5: somebody too new to be a target, in the target search', function()
    it('is marked in the search and the browse, and a veteran is not', function()
        boot()
        local p = Env.addPlayer({ source = 21, citizenid = 'FINN0001', license = 'license:FINN0001',
            cash = 100, bank = 100, firstname = 'Finn', lastname = 'Friend', playtimeHours = 0 })
        W.everyone.FINN0001 = p
        W.loaded(21)
        local found = W.ok(src('creator'), 'searchTargets', { query = 'Finn' }, 'search')
        eq(#found, 1)
        eq(found[1].tooNew, true, 'search marks him')
        local dana = W.ok(src('creator'), 'searchTargets', { query = 'Dana' }, 'search')
        falsy(dana[1].tooNew, 'not the target who has played enough')
        local browse = W.ok(src('creator'), 'browseTargets', { scope = 'all', page = 1 }, 'browse')
        local marked = {}
        for _, row in ipairs(browse.people or {}) do marked[row.name] = row.tooNew end
        eq(marked['Finn Friend'], true, 'browse marks him')
        falsy(marked['Dana Reyes'])
        -- And what Place would answer once the login floor is past, the same.
        Env.advance(Config.Immunity.MinTargetSessionMinutes * 60 + 60)
        local _, err = W.s.contracts.create(W.s.identity.resolve(src('creator')),
            { targetCid = 'FINN0001', reason = 'a long enough reason here', mode = CH.MODE.COMPETITIVE,
              reward = { baseline = { cash = 5000 } } })
        eq(err, CH.ERR.TARGET_TOO_NEW)
    end)
end)

-- ============================================================================
--                              FAILPATHS
-- ============================================================================

describe('FAILPATHS-1: a notice on the game feed, with no phone', function()
    it('keeps every word, in pieces of 99 bytes that end on whole characters', function()
        local Client = require('tests.harness.client')
        local real = Config.Integrations.Phone
        Config.Integrations.Phone = 'none'
        Client.boot()
        Client.feed, Client.feedParts = {}, {}
        local content = 'A hitman has brought your target to you for the handover \u{2014} stay where you are, '
            .. 'within 12 m of them both, for 30 seconds. Then tap Confirm handover \u{2014} on Mine.'
        Client.fire('crimson-hitman:notify', { title = 'Handover starting', content = content })
        Config.Integrations.Phone = real
        eq(#Client.feed, 1)
        eq(Client.feed[1], 'Handover starting: ' .. content, 'nothing lost')
        local parts = Client.feedParts[1]
        truthy(parts and #parts > 1, 'in several components')
        for _, part in ipairs(parts) do
            truthy(#part <= 99, 'at most 99 bytes')
            truthy(utf8.len(part), 'whole characters: ' .. part)
        end
    end)

    it('cuts on whole characters, and no further than it must', function()
        local Util = require('crimson-hitman.shared.util')
        local text = ('a'):rep(98) .. '\u{2014}' .. 'b'
        local pieces = Util.utf8Pieces(text, 99, 10)
        eq(#pieces, 2)
        eq(pieces[1], ('a'):rep(98), 'the dash is not split')
        eq(pieces[2], '\u{2014}b')
        eq(#Util.utf8Pieces(('x'):rep(2000), 99, 10), 10, 'at most ten')
    end)
end)

describe('FAILPATHS-2: a first headshot that never came', function()
    it('is asked for again within half a minute, not five', function()
        boot()
        local function asks()
            local n = 0
            for _, e in ipairs(Env.clientEvents) do
                if e.name == 'crimson-hitman:renderMugshot' and e.target == src('target') then n = n + 1 end
            end
            return n
        end
        local M = W.s.mugshot
        M.request(C.target.cid)
        eq(asks(), 1)
        local t0, again = os.time(), nil
        for _ = 1, 40 do
            Env.advance(10)
            M.request(C.target.cid)
            if not again and asks() > 1 then again = os.time() - t0 end
        end
        truthy(again and again <= 30, 'asked again after ' .. tostring(again) .. ' s')
        truthy(asks() <= 5, 'and spaced out, not asked on every look: ' .. asks())
    end)

    it('an image already there still waits the refresh floor', function()
        boot()
        local M = W.s.mugshot
        M.request(C.target.cid)
        truthy(M.store(C.target.cid, 'data:image/png;base64,iVBORw0KGgoAAAA'))
        local before = #Env.clientEvents
        Env.advance(60)
        M.request(C.target.cid)
        for i = before + 1, #Env.clientEvents do
            falsy(Env.clientEvents[i].name == 'crimson-hitman:renderMugshot', 'not asked again inside the floor')
        end
    end)
end)

describe('FAILPATHS-3: a handover re-arm refused for its wait', function()
    it('says how long is left after a failed one, whatever the setting', function()
        boot(function() Config.Kidnap.RearmCooldownSeconds = 300 end)
        local id = place(); accept(id)
        W.allAt()
        truthy(W.phone(src('hitman'), 'armKidnap', { id = id }).ok)
        passes(1)
        W.at(src('target'), 5000, 5000, 30)
        passes(10)
        Env.advance(65)
        W.allAt()
        local r = W.phone(src('hitman'), 'armKidnap', { id = id })
        eq(r.err, CH.ERR.HANDOVER_COOLDOWN)
        truthy(r.data and r.data.retryAfter, 'a wait')
        truthy(r.data.retryAfter > 200 and r.data.retryAfter <= 300, 'about four minutes left: ' .. r.data.retryAfter)
        falsy(r.data.far)
    end)

    it('says it is the placer who was too far, and the seconds, when no handover had started', function()
        boot()
        local id = place(); accept(id)
        W.allAt()
        W.at(src('creator'), 2000, 2000, 30)
        local r = W.phone(src('hitman'), 'armKidnap', { id = id })
        eq(r.err, 'creator_too_far')
        W.allAt()
        r = W.phone(src('hitman'), 'armKidnap', { id = id })
        eq(r.err, CH.ERR.HANDOVER_COOLDOWN)
        eq(r.data and r.data.far, true)
        truthy(r.data.retryAfter >= 1 and r.data.retryAfter <= 15, 'seconds: ' .. tostring(r.data.retryAfter))
    end)
end)

-- ============================================================================
--                              STUBS-2
-- ============================================================================

describe('STUBS-2: a server-made vehicle, as its model\'s own type', function()
    it('the stub refuses a wrong type, as the game breaks one', function()
        boot()
        eq(CreateVehicleServerSetter('bati', 'automobile', 0, 0, 0, 0), 0, 'a bike made as a car')
        truthy(CreateVehicleServerSetter('bati', 'bike', 0, 0, 0, 0) ~= 0)
    end)

    it('the garage and disposal make bikes, boats and helicopters as such', function()
        boot()
        Env.badVehicles = nil
        local garage = require('server.adapters.garage.onesync')
        for model, want in pairs({ sultan = 'automobile', bati = 'bike', sanchez = 'bike',
                                   buzzard = 'heli', dinghy = 'boat' }) do
            local v = garage.spawn(model, { x = 1, y = 2, z = 3, h = 0 })
            truthy(v and v ~= 0, model .. ' made')
            eq(Env.vehicles[v].kind, want, model)
        end
        local v = W.s.disposal and W.s.disposal.world.spawn('sanchez', { x = 1, y = 2, z = 3, h = 0 })
            or require('server.disposal').world.spawn('sanchez', { x = 1, y = 2, z = 3, h = 0 })
        eq(Env.vehicles[v].kind, 'bike', 'disposal too')
        for _, rec in pairs(Env.vehicles) do falsy(rec.probe, 'no probe vehicle left behind') end
        eq(#(Env.badVehicles or {}), 0)
    end)
end)

-- ============================================================================
--                              EXPLOITER-2
-- ============================================================================

describe('EXPLOITER-2: a rumour\'s area, across restarts', function()
    local function area()
        local r = W.phone(src('hitman'), 'list', { page = 1 })
        local found
        local function walk(v, d)
            if d > 6 or type(v) ~= 'table' then return end
            for k, x in pairs(v) do
                if k == 'area' and type(x) == 'string' then found = x end
                walk(x, d + 1)
            end
        end
        walk(r and r.data, 0)
        return found
    end

    it('stays the one first told, and goes with the contract', function()
        W.boot('json', 'shipped', function()
            Config.Intel.Rumours.Enabled = true
            Config.Intel.Rumours.AreaMode = 'district'
        end)
        W.cast(W.s)
        W.at(src('target'), 200, -900, 30)
        local c = W.s.contracts.create(W.s.identity.resolve(src('creator')), { targetCid = C.target.cid,
            reason = 'Unpaid debt from the docks', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } } })
        local first = area()
        truthy(first, 'an area')
        W.at(src('target'), -150, 6350, 30)
        W.restart(W.s, true); W.tick(1)
        eq(area(), first, 'after a restart')
        W.at(src('target'), 1850, 3700, 30)
        W.restart(W.s, false); W.tick(1)
        eq(area(), first, 'after a crash')
        local key = 'rumourArea:json:' .. c.id
        truthy(GetResourceKvpString(key), 'kept')
        W.s.contracts.cancel(W.s.identity.resolve(src('creator')), c.id)
        falsy(GetResourceKvpString(key), 'forgotten once the contract resolved')
    end)
end)
