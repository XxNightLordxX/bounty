--- Review of e8ccb70 (review-x): each test here failed on the code before
--- its fix.
---
---   F1  a cut of the reward landed on a line a running claim had already
---       marked as the hitman's (owed_to), or in an await after a claim
---       started: the hitman was paid the reduced figure, the placer the cut.
---   F2  a disposal step whose hitman stayed away stood for ever, and kept
---       its target off the board the whole time (relistHold).
---   F3  a disposal vehicle lost and then a relog was made again as a
---       'rejoin', never counted against MaxRespawns: free vehicles.
---   F4  a hitman staff assign was accepted named: the placer saw their name.
---   F5  Reassign took the operatives off, forfeiting their stakes and
---       barring them, before the acceptance it then failed; the preview
---       passed what the op refused.
---   F6  a placer could decline every handover for ever; an answer landing
---       after the tick closed the window was reported as done.
---   F7  the disposal vehicle was left to OneSync's default orphan mode, in
---       bucket 0, with a guessable sequential plate.

local Exec = require('tests.harness.mysql_exec')

local function money(src)
    local p = Env.players[src]
    if not p then return 0 end
    local m = p.PlayerData.money
    return m.cash + m.bank
end

--------------------------------------------------------------------------
-- The panel stack (staff_reward_spec's)
--------------------------------------------------------------------------

local function people()
    Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
        cash = 5000, bank = 50000, firstname = 'Kit', lastname = 'Vane' })
    Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
        firstname = 'Sam', lastname = 'Steward' })
    Env.aces[6] = { ['crimson.admin'] = true }
    Config.Cooldowns.admin = { per = 10, burst = 500 }
    Config.Cooldowns.adminWrite = { per = 10, burst = 500 }
end

local function stack()
    local s = newStack()
    local f = fixture(s)
    people()
    s.bridges.install(s)
    return s, f
end

local function ask(s, src, op, data)
    return s.panel.handle(src, { op = op, data = data or {}, __rid = 7 })
end

local function place(s, f, extra)
    local req = { targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
                  reward = { baseline = { cash = 5000 } } }
    for k, v in pairs(extra or {}) do req[k] = v end
    local c, err = s.contracts.create(f.creator, req)
    truthy(c, 'placed: ' .. tostring(err))
    return c
end

local function lookedUp(s, subject)
    local reply = ask(s, 6, 'player', { subject = subject })
    truthy(reply and reply.ok, 'looked up: ' .. tostring(reply and reply.message))
    return reply.data.player.ref
end

local function forgetServerModules()
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
            package.loaded[name] = nil
        end
    end
end

local function boot(mode)
    forgetServerModules()
    Env.reset()
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Natives.resetResourceStates()
    resetConfig()
    Config.Database.Mode = mode
    if mode == 'mysql' then Exec.install(Natives) end
    if mode == 'json' then Natives.files = {} end
    local main = require('server.main')
    return main.start()
end

--------------------------------------------------------------------------
-- F1
--------------------------------------------------------------------------

describe('review-x F1: a lower reward never cuts what a claim already owes', function()
    for _, mode in ipairs({ 'memory', 'json', 'mysql' }) do
        it('leaves a line a claim marked for its hitman whole, on ' .. mode, function()
            local s = boot(mode)
            local f = fixture(s)
            people()
            local c = place(s, f)
            truthy(s.contracts.accept(f.hitman, c.id, false))
            local hitmanBefore, placerBefore = money(3), money(1)
            -- The claim's marks land in the change's awaits: between the
            -- owed split being written and the cut.
            local real, fired = s.storage.writeEscrow, false
            s.storage.writeEscrow = function(contractId, lines)
                local out = table.pack(real(contractId, lines))
                for _, line in ipairs(lines or {}) do
                    local mark = type(line.metadata) == 'table' and line.metadata or nil
                    if not fired and line.portion == CH.PORTION.OWED and mark and mark.reward then
                        fired = true
                        local claimed = s.storage.readEscrowLine(mark.splitFrom)
                        claimed.owed_to = 'HITMAN01'
                        real(contractId, { claimed })
                    end
                end
                return table.unpack(out, 1, out.n)
            end
            local reply = ask(s, 6, 'rewardChange', { id = c.id, by = -2500, reason = 'r' })
            s.storage.writeEscrow = real
            truthy(fired, 'the claim marked the line mid-change')
            falsy(reply.ok, 'not lowered under a claim')
            -- And the claim's release, after the change.
            s.escrow.release(c.id, 'HITMAN01', { slot = 1, portion = CH.PORTION.BASELINE }, 'payout_baseline')
            eq(money(3), hitmanBefore + 5000, 'the hitman is paid what the claim owed them')
            eq(money(1), placerBefore, 'nothing of it to the placer')
        end)
    end

    it('stops at a claim that starts in the change\'s awaits', function()
        local s, f = stack()
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local placerBefore = money(1)
        local real, held = s.escrow.moneyValue, false
        s.escrow.moneyValue = function(...)
            if not held then
                held = true
                s.escrow.holdClaim(c.id)
            end
            return real(...)
        end
        local reply = ask(s, 6, 'rewardChange', { id = c.id, by = -2500, reason = 'r' })
        s.escrow.moneyValue = real
        s.escrow.letClaim(c.id)
        truthy(held)
        falsy(reply.ok, 'a claim began: nothing cut')
        eq(reply.err, 'claim_running')
        eq(s.escrow.moneyValue(c.id), 5000, 'the reward stands')
        eq(money(1), placerBefore)
    end)
end)

--------------------------------------------------------------------------
-- Disposal (disposal_spec's world)
--------------------------------------------------------------------------

local SPAWN = { x = 200.0, y = 200.0, z = 30.0, h = 90.0 }
local DROP = { x = 500.0, y = 500.0, z = 30.0 }
local BODY = { x = 101.0, y = 100.0, z = 30.0 }

local function fakeWorld(s)
    local W = { vehicles = {}, seq = 0, removed = 0, made = 0, plates = {} }
    s.disposal.world = {
        spawn = function(model, at)
            W.seq, W.made = W.seq + 1, W.made + 1
            local id = 7000 + W.seq
            W.vehicles[id] = { x = at.x, y = at.y, z = at.z, model = model }
            return id
        end,
        exists = function(v) return W.vehicles[v] ~= nil end,
        coords = function(v)
            local c = W.vehicles[v]
            return c and { x = c.x, y = c.y, z = c.z } or nil
        end,
        remove = function(v)
            if W.vehicles[v] then W.removed = W.removed + 1 end
            W.vehicles[v] = nil
        end,
        keep = function() end,
        prepare = function(v, plate, src)
            W.vehicles[v].plate, W.vehicles[v].keys = plate, src
            W.plates[#W.plates + 1] = plate
            return true
        end,
    }
    function W.only()
        local id, n = nil, 0
        for k in pairs(W.vehicles) do id, n = k, n + 1 end
        return id, n
    end
    return W
end

local function at(src, p) Env.players[src]._coords = { x = p.x, y = p.y, z = p.z } end
local function rejoin(src, saved)
    Env.players[src] = saved
    Env.byCitizen[saved.PlayerData.citizenid] = src
end

local function setup(config, anonymous)
    local s = newStack()
    local f = fixture(s)
    s.bridges.install(s)
    Config.Completion.KillPhotos = false
    Config.Cooldowns.disposal = { per = 10, burst = 100 }
    Config.Disposal.Enabled = true
    for k, v in pairs(config or {}) do Config.Disposal[k] = v end
    local W = fakeWorld(s)
    Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
        firstname = 'Sam', lastname = 'Steward' })
    Env.aces[6] = { ['crimson.admin'] = true }
    local staff = { staff = true, cid = 'ADMIN001', source = 6 }
    local places = require('server.places')
    truthy(places.set(staff, 'disposal_vehicle', { x = SPAWN.x, y = SPAWN.y, z = SPAWN.z, heading = SPAWN.h }))
    truthy(places.set(staff, 'disposal_drop', { x = DROP.x, y = DROP.y, z = DROP.z }))
    local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 } } })
    truthy(c, 'placed')
    if anonymous then Config.TargetClasses.default.AllowAnonymousHitman = true end
    truthy(s.contracts.accept(f.hitman, c.id, anonymous == true), 'taken')
    at(3, { x = 100.0, y = 100.0, z = 30.0 })
    at(2, BODY)
    Env.players[2]._health = 140
    s.death.recordDamage(3, 2, 123456)
    Env.players[2].PlayerData.metadata.isdead = true
    s.death.onVictimReport(2)
    truthy(s.photo.verifyAtScene(f.hitman, c.id), 'verified')
    eq(s.disposal.count(), 1, 'a step')
    return s, f, c, W
end

local function tick(s, seconds)
    Env.advance(seconds or 10)
    s.disposal.tick()
end

local function leave(s)
    local saved = Env.players[3]
    s.bridges.onPlayerDropped(s, 'HITMAN01')
    Env.removePlayer(3)
    return saved
end

local function another(s)
    Env.addPlayer({ source = 5, citizenid = 'PLACER02', license = 'license:p2', cash = 50000, bank = 50000,
        firstname = 'Pat', lastname = 'Two' })
    Env.players[2].PlayerData.metadata.isdead = false
    s.death.onRevived('TARGET01')
    Env.advance(3600)
    return s.contracts.create(s.identity.resolve(5), { targetCid = 'TARGET01', reason = 'again',
        reward = { baseline = { cash = 1000 } } })
end

describe('review-x F2: a disposal step stands no longer than MaxHoldMinutes of real time', function()
    it('ships at 120 minutes', function()
        eq(require('tests.harness.shipped').fromFile().Disposal.MaxHoldMinutes, 120)
        eq(ConfigDefaults.Disposal.MaxHoldMinutes, 120)
    end)

    it('times out while the hitman is away, and lets the target be listed again', function()
        local s, f, c = setup({ OnTimeout = 'refund' })
        local placer = money(1)
        tick(s, 10)
        local saved = leave(s)
        for _ = 1, 13 do tick(s, 600) end
        eq(s.disposal.count(), 0, 'timed out away, past 120 real minutes')
        eq(money(1), placer + 5000, 'as OnTimeout says: back to the placer')
        local again, err = another(s)
        truthy(again, 'the target may be listed again: ' .. tostring(err))
        rejoin(3, saved)
    end)

    it('stops naming the target past the cap even while staff hold the step', function()
        local s = setup()
        truthy(s.holds.freeze('ADMIN001', 'HITMAN01', 'test'))
        for _ = 1, 13 do tick(s, 600) end
        eq(s.disposal.count(), 1, 'a held step is not timed out')
        local again, err = another(s)
        truthy(again, 'but no longer shields its target: ' .. tostring(err))
    end)
end)

describe('review-x F3: every respawn not caused by the resource itself is counted', function()
    it('a lost vehicle and a relog is a respawn, at most MaxRespawns', function()
        local s, f, c, W = setup({ MaxRespawns = 1 })
        eq(W.made, 1)
        for _ = 1, 4 do
            local id = W.only()
            if id then W.vehicles[id] = nil end
            local saved = leave(s)
            tick(s, 10)
            rejoin(3, saved)
            tick(s, 10)
        end
        eq(W.made, 2, 'one respawn, then no more')
        for _, row in ipairs(s.storage.readRpRows('disposal')) do eq(row.respawns, 1) end
    end)

    it('a vehicle this resource took away on leaving is made again, not counted', function()
        local s, f, c, W = setup({ MaxRespawns = 0 })
        for _ = 1, 3 do
            local saved = leave(s)
            tick(s, 10)
            rejoin(3, saved)
            tick(s, 10)
        end
        eq(W.made, 4, 'made again each time they came back')
        local _, n = W.only()
        eq(n, 1)
    end)
end)

describe('review-x F7: the disposal vehicle as FiveM keeps entities', function()
    it('random, unpredictable plates, never one another step\'s vehicle has', function()
        local s, f, c, W = setup()
        for _ = 1, 6 do truthy(s.disposal.respawn('ADMIN001', c.id)) end
        local seen = {}
        for _, plate in ipairs(W.plates) do
            eq(#plate, 8, plate)
            truthy(plate:match('^CH[%u%d]+$'), plate)
            falsy(plate:match('^CHD%d%d%d%d$'), 'not a sequence: ' .. plate)
            falsy(seen[plate], 'never twice: ' .. plate)
            seen[plate] = true
        end
    end)

    it('keeps the vehicle whoever is in scope (orphan mode 2), in the hitman\'s routing bucket', function()
        local s = newStack()
        fixture(s)
        local saved = {}
        for _, name in ipairs({ 'SetEntityOrphanMode', 'SetEntityRoutingBucket', 'GetEntityRoutingBucket',
            'SetVehicleNumberPlateText', 'Entity', 'SetVehicleDoorsLocked' }) do saved[name] = _G[name] end
        local orphan, bucket, plate = {}, {}, {}
        _G.SetEntityOrphanMode = function(v, m) orphan[v] = m end
        _G.SetEntityRoutingBucket = function(v, b) bucket[v] = b end
        _G.GetEntityRoutingBucket = function(v) return bucket[v] or 0 end
        _G.SetVehicleNumberPlateText = function(v, p) plate[v] = p end
        _G.Entity = function() return { state = { set = function() end } } end
        _G.SetVehicleDoorsLocked = function() end
        Env.players[3]._bucket = 7
        local ok, err = pcall(s.disposal.world.prepare, 9001, 'CHABCDEF', 3)
        truthy(ok, tostring(err))
        eq(orphan[9001], 2, 'KeepEntity')
        eq(bucket[9001], 7, 'the hitman\'s bucket')
        eq(plate[9001], 'CHABCDEF')
        _G.SetEntityOrphanMode = nil
        local guarded, why = pcall(s.disposal.world.prepare, 9002, 'CHABCDEG', 3)
        truthy(guarded, 'an artifact without the native: ' .. tostring(why))
        for name, fn in pairs(saved) do _G[name] = fn end
        Env.players[3]._bucket = nil
    end)
end)

--------------------------------------------------------------------------
-- F4, F5: Reassign
--------------------------------------------------------------------------

describe('review-x F4: a hitman staff assign is anonymous unless staff choose otherwise', function()
    local function assigned(data)
        local s, f = stack()
        Config.TargetClasses.default.AllowAnonymousHitman = true
        Config.Anonymity.HitmanFee = 500
        local c = place(s, f, { mode = CH.MODE.EXCLUSIVE })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local before = money(4)
        local payload = { id = c.id, ref = lookedUp(s, 4), reason = 'r', block = true, returnStake = false }
        for k, v in pairs(data or {}) do payload[k] = v end
        local reply = ask(s, 6, 'reassignHitman', payload)
        truthy(reply.ok, tostring(reply.message))
        local card = s.projection.contract(s.storage.readContract(c.id), 'CREATOR1')
        return s, c, card, before
    end

    it('the panel\'s own payload: anonymous, no fee, never named to the placer', function()
        local s, c, card, before = assigned()
        eq(s.storage.readHitman(c.id, 'HITMAN02').anon, true)
        eq(card.hitmen[1].name, nil, 'the placer does not see their name')
        eq(money(4), before, 'no anonymity fee for staff\'s choice')
    end)

    it('named only when staff choose it; carry keeps what they chose before', function()
        local s, c, card = assigned({ identity = 'named' })
        eq(card.hitmen[1].name, 'Kit Vane')
        local _, c2, card2 = assigned({ identity = 'carry' })
        eq(card2.hitmen[1].name, nil, 'no stint of their own: anonymous')
    end)
end)

describe('review-x F5: Reassign asks every check before anybody comes off, and undoes a late refusal', function()
    local function staked()
        local s, f = stack()
        Config.Staff.ReassignStake = 'charge'
        local c = place(s, f, { mode = CH.MODE.EXCLUSIVE, penaltyAmount = 2000 })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        return s, f, c
    end

    it('a broke hitman: the preview and the op refuse alike, and nothing moves', function()
        local s, f, c = staked()
        Env.players[4].PlayerData.money.cash, Env.players[4].PlayerData.money.bank = 0, 0
        local placer = money(1)
        local ref = lookedUp(s, 4)
        local preview = ask(s, 6, 'reassignPreview', { id = c.id, ref = ref })
        eq(preview.data.refused, CH.ERR.INSUFFICIENT, 'the preview says it')
        local reply = ask(s, 6, 'reassignHitman', { id = c.id, ref = ref, reason = 'r' })
        eq(reply.err, CH.ERR.INSUFFICIENT, 'the same refusal')
        eq(s.storage.readHitman(c.id, 'HITMAN01').state, 'active', 'still on it')
        falsy(s.staffContract.barred(c.id, 'HITMAN01'), 'not barred')
        eq(money(1), placer, 'no stake forfeited')
    end)

    it('refused after the removals: everybody back on it with their stake, no bar kept', function()
        local s, f, c = staked()
        local placer = money(1)
        local ref = lookedUp(s, 4)
        local real = s.staffContract.removeHitman
        s.staffContract.removeHitman = function(...)
            local out = table.pack(real(...))
            -- The new hitman's money moves in the awaits after the check.
            Env.players[4].PlayerData.money.cash, Env.players[4].PlayerData.money.bank = 0, 0
            return table.unpack(out, 1, out.n)
        end
        local reply = ask(s, 6, 'reassignHitman', { id = c.id, ref = ref, reason = 'r' })
        s.staffContract.removeHitman = real
        eq(reply.err, 'not_assigned')
        truthy(tostring(reply.message):find('put back on it', 1, true), tostring(reply.message))
        eq(s.storage.readHitman(c.id, 'HITMAN01').state, 'active', 'put back')
        falsy(s.staffContract.barred(c.id, 'HITMAN01'), 'the bar lifted')
        eq(money(1), placer, 'the stake did not go to the placer')
        local held = 0
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.portion == CH.PORTION.STAKE and line.staker == 'HITMAN01'
                and line.state == CH.ESCROW_STATE.HELD then held = held + line.amount end
        end
        eq(held, 2000, 'their stake still held for them')
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'still theirs')
    end)

    it('a reassignment that stands hands the held stake over as the removal chose', function()
        local s, f, c = staked()
        local placer, old = money(1), money(3)
        local reply = ask(s, 6, 'reassignHitman', { id = c.id, ref = lookedUp(s, 4), reason = 'r' })
        truthy(reply.ok, tostring(reply.message))
        eq(money(1), placer + 2000, 'forfeited to the placer, as a walk-away')
        eq(money(3), old)
        local s2, f2, c2 = staked()
        local old2 = money(3)
        truthy(ask(s2, 6, 'reassignHitman', { id = c2.id, ref = lookedUp(s2, 4), reason = 'r',
            returnStake = true }).ok)
        eq(money(3), old2 + 2000, 'returned to them')
    end)
end)

--------------------------------------------------------------------------
-- F6: the placer's declines
--------------------------------------------------------------------------

describe('review-x F6: a placer\'s declines are capped, and a late answer is not reported as done', function()
    local Shipped = require('tests.harness.shipped')
    local AT = { x = 200.0, y = 200.0, z = 30.0 }

    local function placed(configure)
        local s = Shipped.newStack()
        Config.Kidnap.PlacerConfirms = true
        if configure then configure() end
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        truthy(c, 'placed')
        truthy(s.contracts.accept(f.hitman, c.id, false), 'taken')
        s.bridges.install(s)
        for _, src in ipairs({ 1, 2, 3 }) do Env.players[src]._coords = { x = AT.x, y = AT.y, z = AT.z } end
        return s, f, c
    end
    local function ticks(s, n) for _ = 1, n do s.kidnap.tick(Config.Kidnap.TickMs) end end
    local function full() return math.floor(Config.Kidnap.CountdownSeconds * 1000 / Config.Kidnap.TickMs) end
    local function window() return math.floor(Config.Kidnap.ConfirmSeconds * 1000 / Config.Kidnap.TickMs) end

    it('ships at 2', function()
        eq(Shipped.fromFile().Kidnap.MaxDeclines, 2)
    end)

    it('pays the handover after MaxDeclines declines without asking the placer', function()
        local s, f, c = placed()
        local before = money(3)
        for i = 1, 2 do
            truthy(s.kidnap.arm(c.id, 'HITMAN01'), 'armed ' .. i)
            ticks(s, full())
            local ok = s.kidnap.answer(c.id, 'CREATOR1', false)
            truthy(ok, 'declined ' .. i)
            Env.advance(Config.Kidnap.RearmCooldownSeconds + 1)
        end
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED)
        truthy(s.kidnap.arm(c.id, 'HITMAN01'), 'armed a third time')
        ticks(s, full() + 2)
        eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED, 'paid without a word')
        eq(money(3), before + 5000)
    end)

    it('a window left to run out counts too', function()
        local s, f, c = placed()
        for i = 1, 2 do
            truthy(s.kidnap.arm(c.id, 'HITMAN01'), 'armed ' .. i)
            ticks(s, full() + window() + 1)
            Env.advance(Config.Kidnap.RearmCooldownSeconds + 1)
        end
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        ticks(s, full() + 2)
        eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED)
    end)

    for _, case in ipairs({ { missed = 'rearm', yes = true }, { missed = 'pay', yes = false } }) do
        it(('answers no_handover when the tick closed the window in its awaits (%s, %s)')
            :format(case.missed, case.yes and 'confirm' or 'decline'), function()
            local s, f, c = placed(function() Config.Kidnap.ConfirmMissed = case.missed end)
            truthy(s.kidnap.arm(c.id, 'HITMAN01'))
            ticks(s, full())
            local real, inside = s.holds.on, false
            s.holds.on = function(...)
                local out = table.pack(real(...))
                if not inside then
                    inside = true
                    ticks(s, window() + 1)
                end
                return table.unpack(out, 1, out.n)
            end
            local ok, err, data = s.kidnap.answer(c.id, 'CREATOR1', case.yes)
            s.holds.on = real
            truthy(inside, 'the tick ran in the answer\'s await')
            falsy(ok, 'not answered as done: ' .. tostring(data and (data.confirmed or data.declined)))
            eq(err, CH.ERR.NO_HANDOVER)
        end)
    end
end)

--------------------------------------------------------------------------
-- The admin panel review (review-admin): its server halves
--------------------------------------------------------------------------

describe('admin review F1: a diagnosis by lookup handle names no citizen id without the identity ACE', function()
    it('scrubs the report and its later lines for staff without crimson.identity', function()
        local s = newStack()
        fixture(s)
        people()
        Env.addPlayer({ source = 8, citizenid = 'IDENT001', license = 'license:IDENT001',
            firstname = 'Ida', lastname = 'Dent' })
        Env.aces[8] = { ['crimson.admin'] = true, ['crimson.identity'] = true }
        local function run(src)
            local looked = ask(s, src, 'player', { subject = 1 })
            truthy(looked and looked.ok, 'looked up')
            Env.clientEvents = {}
            local reply = ask(s, src, 'diag', { ref = looked.data.player.ref })
            truthy(reply and reply.ok, 'ran: ' .. tostring(reply and reply.message))
            local text = table.concat(reply.data.lines, '\n')
            for _, e in ipairs(Env.clientEvents) do
                if e.name == 'crimson-hitman:adminPush' and type(e.args[1]) == 'table' then
                    text = text .. '\n' .. tostring(e.args[1].line)
                    eq(e.args[1].ref, looked.data.player.ref, 'a push names the handle it was run for')
                end
            end
            return text, reply
        end
        local hidden, reply = run(6)
        falsy(hidden:find('CREATOR1', 1, true), 'no citizen id: ' .. hidden)
        truthy(hidden:find('identity:', 1, true), 'the identity line is still there')
        truthy(reply.data.ref, 'the answer names the handle')
        local whole = run(8)
        truthy(whole:find('CREATOR1', 1, true), 'whole with the identity ACE')
    end)
end)

describe('admin review F3: a disposal step held through an anonymous party is not shown held', function()
    it('shows held only through a party the staff member may see', function()
        local s = setup(nil, true)
        Env.addPlayer({ source = 8, citizenid = 'IDENT001', license = 'license:IDENT001',
            firstname = 'Ida', lastname = 'Dent' })
        Env.aces[8] = { ['crimson.admin'] = true, ['crimson.identity'] = true }
        Config.Cooldowns.admin = { per = 10, burst = 500 }
        local function held(src)
            local reply = ask(s, src, 'disposalList')
            truthy(reply and reply.ok)
            return reply.data.steps[1].held
        end
        truthy(s.holds.freeze('ADMIN001', 'HITMAN01', 'test'))
        eq(held(6), false, 'held only through the anonymous hitman: not said without the identity ACE')
        eq(held(8), true, 'said with it')
        truthy(s.holds.unfreeze('ADMIN001', 'HITMAN01', 'done'))
        truthy(s.holds.freeze('ADMIN001', 'TARGET01', 'test'))
        eq(held(6), true, 'through the target, whom every reader sees')
        truthy(s.holds.unfreeze('ADMIN001', 'TARGET01', 'done'))
        Config.Holds.AppPaused = true
        s.holds.syncAppPause()
        eq(held(6), true, 'the app pause names nobody')
        Config.Holds.AppPaused = false
        s.holds.syncAppPause()
    end)
end)
