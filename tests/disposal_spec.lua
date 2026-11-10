--- Body disposal (server/disposal.lua, Config.Disposal): a verified kill
--- pays once the body is dropped off.
---
--- Off as shipped, and off nothing changes: the kill pays at once, nothing
--- is read, written or sent. On, the payout waits in escrow owed to the
--- hitman, the vehicle is made at the staff spot with keys for the hitman
--- alone, the body is loaded and dropped off only where the server sees the
--- hitman and the vehicle, and the payout follows at the drop-off. Every
--- timeout option, the holds that stop its clock, a drop and a rejoin, a
--- restart on every store, hostile payloads, the staff ops and the EMS rule,
--- with the money conserved through every path.

local Exec = require('tests.harness.mysql_exec')

local SPAWN = { x = 200.0, y = 200.0, z = 30.0, h = 90.0 }
local DROP = { x = 500.0, y = 500.0, z = 30.0 }
local BODY = { x = 101.0, y = 100.0, z = 30.0 }
local STEP_EVENT, CLEAR_EVENT = 'crimson-hitman:client:StepMarker', 'crimson-hitman:client:StepMarkerClear'

--- A world the server's vehicle calls go to: [entity] = { x, y, z, plate, keys }.
local function fakeWorld(s)
    local W = { vehicles = {}, seq = 0, removed = 0, made = 0 }
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
        prepare = function(v, plate, src)
            W.vehicles[v].plate, W.vehicles[v].keys = plate, src
            return true
        end,
    }
    function W.only()
        local id, n = nil, 0
        for k in pairs(W.vehicles) do id, n = k, n + 1 end
        return id, n
    end
    function W.move(p)
        local id = W.only()
        W.vehicles[id].x, W.vehicles[id].y, W.vehicles[id].z = p.x, p.y, p.z
    end
    return W
end

local function at(src, p) Env.players[src]._coords = { x = p.x, y = p.y, z = p.z } end

--- A player who left, back in the city as they were.
local function rejoin(src, saved)
    Env.players[src] = saved
    Env.byCitizen[saved.PlayerData.citizenid] = src
end
local function cash(src) return Env.players[src].PlayerData.money.cash end

--- Every player's money, and what the contracts still hold.
local function total(s)
    local sum = 0
    for _, p in pairs(Env.players) do sum = sum + p.PlayerData.money.cash + p.PlayerData.money.bank end
    for _, c in ipairs(s.storage.allContracts()) do
        for _, line in ipairs(s.storage.readEscrow(c.id) or {}) do
            if CH.MONEY_SOURCES[line.source] and line.source ~= 'dirty' and line.state ~= CH.ESCROW_STATE.SETTLED then
                sum = sum + (line.amount or 0) - (tonumber(line.deliver_arrived) or 0)
            end
        end
    end
    return sum
end

local function staffAt(s)
    if not Env.players[6] then
        Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
            firstname = 'Sam', lastname = 'Steward' })
        Env.aces[6] = { ['crimson.admin'] = true }
    end
    local staff = { staff = true, cid = 'ADMIN001', source = 6 }
    local places = require('server.places')
    truthy(places.set(staff, 'disposal_vehicle', { x = SPAWN.x, y = SPAWN.y, z = SPAWN.z, heading = SPAWN.h }))
    truthy(places.set(staff, 'disposal_drop', { x = DROP.x, y = DROP.y, z = DROP.z }))
end

--- A contract taken by the hitman (3) and its target (2) killed by them,
--- standing over the body. Not verified yet.
local function killed(s, f, reward)
    local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
        reward = reward or { baseline = { cash = 5000 }, bonus = { cash = 1000 } } })
    truthy(c, 'placed')
    truthy(s.contracts.accept(f.hitman, c.id, false), 'taken')
    at(3, { x = 100.0, y = 100.0, z = 30.0 })
    at(2, BODY)
    Env.players[2]._health = 140
    s.death.recordDamage(3, 2, 123456)
    Env.players[2].PlayerData.metadata.isdead = true
    s.death.onVictimReport(2)
    truthy(s.death.getPending(c.id, 'HITMAN01'), 'a kill to verify')
    return c
end

--- The stack, with disposal on (unless opts.off), its spots set, a kill
--- made and (unless opts.unverified) verified at the scene.
local function setup(opts)
    opts = opts or {}
    local s = opts.stack or newStack()
    local f = opts.f or fixture(s)
    Config.Completion.KillPhotos = false
    Config.Cooldowns.disposal = { per = 10, burst = 100 }
    if not opts.off then Config.Disposal.Enabled = true end
    for k, v in pairs(opts.config or {}) do Config.Disposal[k] = v end
    local W = fakeWorld(s)
    if not opts.noSpots then staffAt(s) end
    local before = total(s)
    local c = killed(s, f, opts.reward)
    if not opts.unverified then
        Env.clientEvents = {}
        local ok, err = s.photo.verifyAtScene(f.hitman, c.id)
        truthy(ok, 'verified: ' .. tostring(err))
    end
    return s, f, c, W, before
end

local function act(src, action, id)
    _G.source = src
    local ok, err = pcall(Env.events['crimson-hitman:disposalAct'], { action = action, id = id })
    _G.source = nil
    truthy(ok, 'the net event must not raise: ' .. tostring(err))
end

--- The step markers each player was sent since the events were emptied:
--- [src] = { key = kind }; and the clears, [src] = { key = true }.
local function sent()
    local set, cleared = {}, {}
    for _, e in ipairs(Env.clientEvents) do
        if e.name == STEP_EVENT then
            set[e.target] = set[e.target] or {}
            set[e.target][e.args[1].key] = e.args[1]
        elseif e.name == CLEAR_EVENT then
            cleared[e.target] = cleared[e.target] or {}
            cleared[e.target][e.args[1].key] = true
        end
    end
    return set, cleared
end

local function tick(s, seconds)
    Env.advance(seconds or 10)
    s.disposal.tick()
    s.missionSteps.tick()
end

local function load(s, f, c, W)
    at(3, BODY)
    W.move({ x = BODY.x + 3, y = BODY.y, z = BODY.z })
    act(3, 'load', c.id)
end

local function dropOff(s, f, c, W)
    at(3, DROP)
    W.move({ x = DROP.x + 2, y = DROP.y, z = DROP.z })
    act(3, 'drop', c.id)
end

local function stepRow(s, c)
    for _, row in ipairs(s.storage.readRpRows('disposal')) do
        if row.contract_id == c.id then return row end
    end
    return nil
end

--------------------------------------------------------------------------
-- As shipped
--------------------------------------------------------------------------

describe('body disposal as shipped', function()
    it('ships off, in config.lua and defaults.lua, with every knob safe', function()
        local shipped = require('tests.harness.shipped').fromFile()
        eq(shipped.Disposal.Enabled, false)
        eq(ConfigDefaults.Disposal.Enabled, false)
        eq(shipped.Disposal.OnTimeout, 'pay', 'a timeout pays the hitman anyway')
        eq(shipped.Disposal.PayNowPercent, 0, 'all at the drop-off')
        eq(next(shipped.Disposal.VehicleSpawn), nil, 'no spot until staff set one')
    end)

    it('off: a verified kill pays at once, nothing is read, written, made or sent', function()
        local s = newStack()
        local f = fixture(s)
        local reads = 0
        local real = s.storage.readRpRows
        s.storage.readRpRows = function(kind, ...)
            if kind == 'disposal' or kind == 'map_place' then reads = reads + 1 end
            return real(kind, ...)
        end
        local W = fakeWorld(s)
        Config.Completion.KillPhotos = false
        local c = killed(s, f)
        local before = cash(3)
        Env.clientEvents = {}
        truthy(s.photo.verifyAtScene(f.hitman, c.id))
        eq(cash(3), before + 5000, 'paid at once')
        for _ = 1, 3 do s.missionSteps.tick() end
        s.storage.readRpRows = real
        eq(reads, 0, 'disposal read nothing')
        eq(s.disposal.count(), 0)
        eq(W.made, 0, 'no vehicle')
        local set = sent()
        eq(next(set), nil, 'no marker sent to anybody')
        eq(#s.storage.readRpRows('disposal'), 0)
        -- And the hooks it chains answer as before it.
        falsy(s.escrow.holdBack('HITMAN01', { portion = CH.PORTION.BASELINE, contract_id = c.id, slot = 1 }))
    end)

    it('on, with no spot set: the kill pays at once and the console says why, once', function()
        local s, f, c, W = setup({ noSpots = true })
        eq(s.disposal.count(), 0)
        eq(W.made, 0)
        truthy(cash(3) >= 10000, 'paid at once')
    end)
end)

--------------------------------------------------------------------------
-- What starts a step
--------------------------------------------------------------------------

describe('what starts a disposal', function()
    it('a verified kill: the payout waits in escrow, owed to the hitman, and conserved', function()
        local s, f, c, W, before = setup()
        eq(cash(3), 5000, 'nothing handed over yet')
        eq(s.disposal.count(), 1)
        eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED, 'the claim stands')
        local owed = 0
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.owed_to == 'HITMAN01' and line.state == CH.ESCROW_STATE.HELD then owed = owed + line.amount end
        end
        eq(owed, 5000, 'owed to the hitman')
        eq(total(s), before, 'conserved')
        local row = stepRow(s, c)
        truthy(row, 'kept in the store')
        eq(row.stage, 'body')
        eq(row.body.x, BODY.x, 'at the body the server recorded')
        local id, n = W.only()
        eq(n, 1, 'one vehicle')
        eq(W.vehicles[id].x, SPAWN.x, 'at the spawn spot')
        eq(W.vehicles[id].keys, 3, 'keys for the hitman alone')
        eq(W.vehicles[id].model, 'romero')
    end)

    it('never a proof item, never a handover, never on an alive-only contract', function()
        local s, f, c = setup({ unverified = true })
        local ok = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION,
            { outcome = CH.FULFILMENT.PROOF })
        truthy(ok, 'claimed as a proof item')
        eq(s.disposal.count(), 0, 'no disposal for a proof item')
        truthy(cash(3) >= 10000, 'paid at once')
        s.disposal.onClaim({ id = 'ct00000099', next_slot = 1, fulfilment_rule = 'either' }, 'HITMAN01',
            CH.FULFILMENT.KIDNAPPING)
        eq(s.disposal.count(), 0, 'no disposal for a live handover')
        s.disposal.onClaim({ id = c.id, next_slot = 1, fulfilment_rule = 'alive' }, 'HITMAN01',
            CH.FULFILMENT.ELIMINATION)
        eq(s.disposal.count(), 0, 'nor where only a live handover counts')
    end)

    it('a refused claim leaves no step behind', function()
        local s, f, c = setup({ unverified = true })
        s.freeze.freeze('ADMIN001', 'HITMAN01', 'test')
        local ok = s.photo.verifyAtScene(f.hitman, c.id)
        falsy(ok, 'refused on hold')
        eq(s.disposal.count(), 0)
        eq(#s.storage.readRpRows('disposal'), 0)
    end)
end)

--------------------------------------------------------------------------
-- The whole step
--------------------------------------------------------------------------

describe('a disposal from the kill to the drop-off', function()
    it('marks each step for the hitman alone, loads only with the vehicle there, pays at the drop-off', function()
        Env.reset()
        local s = newStack()
        local f = fixture(s)
        Env.addPlayer({ source = 4, citizenid = 'BYSTAND1', license = 'license:by', firstname = 'Bea', lastname = 'S' })
        local _, _, c, W, before = setup({ stack = s, f = f })
        local set = sent()
        truthy(set[3] and set[3]['disposal_body:' .. c.id], 'the body marked for the hitman')
        truthy(set[3]['disposal_vehicle:' .. c.id], 'and the vehicle\'s spawn spot')
        eq(set[3]['disposal_body:' .. c.id].act, 'load')
        falsy(set[1] or set[2] or set[4], 'nothing to the placer, the target or a bystander')

        -- Without the vehicle beside the body: refused.
        at(3, BODY)
        Env.clientEvents = {}
        act(3, 'load', c.id)
        eq(stepRow(s, c).stage, 'body', 'not loaded without the vehicle')
        -- Away from the body: refused.
        W.move({ x = BODY.x + 2, y = BODY.y, z = BODY.z })
        at(3, { x = 150.0, y = 150.0, z = 30.0 })
        act(3, 'load', c.id)
        eq(stepRow(s, c).stage, 'body', 'not loaded from afar')
        -- Somebody else: refused.
        at(4, BODY)
        act(4, 'load', c.id)
        eq(stepRow(s, c).stage, 'body', 'not loaded by a bystander')

        Env.clientEvents = {}
        load(s, f, c, W)
        eq(stepRow(s, c).stage, 'loaded')
        local set2, cleared = sent()
        truthy(cleared[3] and cleared[3]['disposal_body:' .. c.id], 'the body marker goes')
        truthy(set2[3] and set2[3]['disposal_drop:' .. c.id], 'the drop-off marker comes')
        eq(set2[3]['disposal_drop:' .. c.id].x, DROP.x)

        -- Drop-off from the wrong place, or without the vehicle: refused.
        at(3, { x = 400.0, y = 400.0, z = 30.0 })
        act(3, 'drop', c.id)
        eq(cash(3), 5000, 'not from afar')
        at(3, DROP)
        act(3, 'drop', c.id)
        eq(cash(3), 5000, 'not without the vehicle')

        Env.clientEvents = {}
        dropOff(s, f, c, W)
        eq(cash(3), 10000, 'paid at the drop-off')
        eq(s.disposal.count(), 0)
        eq(stepRow(s, c), nil, 'gone from the store')
        eq(total(s), before, 'conserved')
        local _, cleared2 = sent()
        truthy(cleared2[3] and cleared2[3]['disposal_drop:' .. c.id], 'the drop-off marker goes')
        local _, n = W.only()
        eq(n, 1, 'the vehicle stays a moment, to get out')
        Env.advance(11)
        local _, after = W.only()
        eq(after, 0, 'then it is taken away')
        -- And twice is nothing.
        act(3, 'drop', c.id)
        eq(cash(3), 10000, 'paid once')
    end)

    it('pays the part set aside at the kill, and the rest at the drop-off', function()
        local s, f, c, W, before = setup({ config = { PayNowPercent = 40 } })
        eq(cash(3), 5000 + 2000, '40% at the kill')
        eq(total(s), before)
        load(s, f, c, W)
        dropOff(s, f, c, W)
        eq(cash(3), 10000, 'the rest at the drop-off')
        eq(total(s), before, 'conserved')
    end)
end)

--------------------------------------------------------------------------
-- Timeouts
--------------------------------------------------------------------------

describe('when the time runs out', function()
    local function runOut(s)
        tick(s, 10)
        for _ = 1, 4 do tick(s, 600) end
    end

    it('pays anyway as shipped', function()
        local s, f, c, W, before = setup()
        runOut(s)
        eq(s.disposal.count(), 0)
        eq(cash(3), 10000, 'paid anyway')
        eq(total(s), before)
        local _, n = W.only()
        eq(n, 0, 'the vehicle goes at once')
    end)

    it('reduced: the hitman keeps the share, the rest goes back to the placer', function()
        local s, f, c, W, before = setup({ config = { OnTimeout = 'reduced', ReducedPercent = 30 } })
        local placer = cash(1)
        runOut(s)
        eq(cash(3), 5000 + 1500, '30% kept')
        eq(cash(1), placer + 3500, 'the rest back to the placer')
        eq(total(s), before, 'conserved')
    end)

    it('refund: all of it back to the placer, nothing left owed to the hitman', function()
        local s, f, c, W, before = setup({ config = { OnTimeout = 'refund' } })
        local placer = cash(1)
        runOut(s)
        eq(cash(3), 5000, 'nothing to the hitman')
        eq(cash(1), placer + 5000, 'back to the placer')
        eq(total(s), before)
        eq(#s.storage.readPending('HITMAN01'), 0, 'nothing queued for the hitman')
        s.escrow.retryPending('HITMAN01')
        eq(cash(3), 5000, 'and nothing later either')
    end)

    it('refund to a placer who is away: owed to them, paid at their login', function()
        local s, f, c, W, before = setup({ config = { OnTimeout = 'refund' } })
        local placer = cash(1)
        local saved = Env.players[1]
        Env.removePlayer(1)
        runOut(s)
        rejoin(1, saved)
        s.escrow.retryPending('CREATOR1')
        eq(cash(1), placer + 5000)
        eq(total(s), before)
    end)

    it('counts only the hitman\'s time in the city, and says a band, never the figure', function()
        local s, f, c = setup()
        local said = {}
        for _, n in ipairs(Natives.calls.notifications) do said[#said + 1] = tostring(n.content) end
        local text = table.concat(said, '\n')
        truthy(text:find('plenty of time', 1, true), text)
        falsy(text:find('1800', 1, true) or text:find('30 minutes', 1, true), 'no exact figure')
        eq(s.disposal.band(9 * 60), 'between 5 and 10 minutes')
        eq(s.disposal.band(60), 'under 5 minutes')
        local saved = Env.players[3]
        tick(s, 10)
        tick(s, 10)
        s.bridges.onPlayerDropped(s, 'HITMAN01')
        Env.removePlayer(3)
        for _ = 1, 5 do tick(s, 600) end
        eq(s.disposal.count(), 1, 'the clock stood while they were away')
        rejoin(3, saved)
        local list = s.disposal.list()
        eq(list[1].secondsLeft, 1800 - 10, 'exact for staff')
    end)
end)

--------------------------------------------------------------------------
-- Holds
--------------------------------------------------------------------------

describe('a disposal on hold', function()
    local function heldWith(hold, release)
        local s, f, c, W = setup()
        tick(s, 10)
        local spent = s.disposal.list()[1].spent
        hold(s)
        for _ = 1, 3 do tick(s, 600) end
        eq(s.disposal.count(), 1, 'not timed out on hold')
        eq(s.disposal.list()[1].spent, spent, 'the clock stood still')
        local _, n = W.only()
        eq(n, 1, 'the vehicle kept')
        load(s, f, c, W)
        eq(stepRow(s, c).stage, 'body', 'nothing done with the body on hold')
        release(s)
        load(s, f, c, W)
        eq(stepRow(s, c).stage, 'loaded', 'and done once it lifts')
        dropOff(s, f, c, W)
        eq(cash(3), 10000)
    end

    it('a staff freeze on the hitman', function()
        heldWith(function(s) truthy(s.freeze.freeze('ADMIN001', 'HITMAN01', 'test')) end,
            function(s) truthy(s.freeze.unfreeze('ADMIN001', 'HITMAN01', 'done')) end)
    end)

    it('the app pause', function()
        heldWith(function(s)
            Config.Staff.AppPaused = true
            s.freeze.syncAppPause()
            truthy(s.freeze.appPaused(), 'paused')
        end, function(s)
            Config.Staff.AppPaused = false
            s.freeze.syncAppPause()
        end)
    end)

    it('the restart hold', function()
        heldWith(function(s)
            Config.Restart.PauseBeforeSeconds = 1800
            truthy(s.freeze.scheduledRestart({ secondsRemaining = 600 }))
        end, function(s)
            s.freeze.releaseRestart()
        end)
    end)
end)

--------------------------------------------------------------------------
-- The vehicle and the hitman
--------------------------------------------------------------------------

describe('the disposal vehicle', function()
    it('goes when the hitman leaves, and is made again and the markers drawn when they are back', function()
        local s, f, c, W = setup()
        s.bridges.install(s)
        local saved = Env.players[3]
        s.bridges.onPlayerDropped(s, 'HITMAN01')
        Env.removePlayer(3)
        local _, n = W.only()
        eq(n, 0, 'taken away')
        tick(s, 10)
        rejoin(3, saved)
        Env.clientEvents = {}
        tick(s, 10)
        local _, back = W.only()
        eq(back, 1, 'made again')
        _G.source = 3
        Env.events['crimson-hitman:locationTips']({ __rid = 1 })
        _G.source = nil
        local set = sent()
        truthy(set[3] and set[3]['disposal_body:' .. c.id], 'the body drawn again')
        eq(stepRow(s, c).respawns, 0, 'a rejoin is not a respawn')
    end)

    it('is taken back to the spawn spot when abandoned, at most MaxRespawns times', function()
        local s, f, c, W = setup({ config = { MaxRespawns = 1, AbandonMinutes = 1 } })
        local id = W.only()
        at(3, { x = SPAWN.x + 2, y = SPAWN.y, z = SPAWN.z })
        tick(s, 10)
        truthy(s.disposal.runtime(stepRow(s, c).id).reached, 'reached')
        W.move({ x = 2000.0, y = 2000.0, z = 30.0 })
        at(3, { x = 2000.0 + 400, y = 2000.0, z = 30.0 })
        tick(s, 10)
        tick(s, 70)
        local now = W.only()
        truthy(now ~= id, 'a new one')
        eq(W.vehicles[now].x, SPAWN.x, 'at the spawn spot')
        eq(stepRow(s, c).respawns, 1)
        -- Destroyed now: not made again past the most.
        W.vehicles[now] = nil
        tick(s, 10)
        local _, n = W.only()
        eq(n, 0, 'not past MaxRespawns')
        truthy(s.disposal.respawn('ADMIN001', c.id), 'staff can always make it again')
        local _, again = W.only()
        eq(again, 1)
    end)

    it('goes at the stop, and the step stays in the store', function()
        local s, f, c, W = setup()
        s.disposal.stop()
        local _, n = W.only()
        eq(n, 0)
        truthy(stepRow(s, c))
    end)
end)

--------------------------------------------------------------------------
-- The EMS rule
--------------------------------------------------------------------------

describe('a body being disposed of', function()
    it('cannot be listed again until it is dropped off, and a revive changes nothing', function()
        local s, f, c, W = setup()
        Env.addPlayer({ source = 5, citizenid = 'PLACER02', license = 'license:p2', cash = 50000, bank = 50000,
            firstname = 'Pat', lastname = 'Two' })
        local other = s.identity.resolve(5)
        Env.players[2].PlayerData.metadata.isdead = false
        s.death.onRevived('TARGET01')
        Env.advance(3600)
        local again, err = s.contracts.create(other, { targetCid = 'TARGET01', reason = 'again',
            reward = { baseline = { cash = 1000 } } })
        falsy(again, 'not while their body is being disposed of')
        eq(err, CH.ERR.TARGET_RECOVERING)
        eq(s.disposal.count(), 1, 'the revive did not end the step')
        load(s, f, c, W)
        dropOff(s, f, c, W)
        eq(cash(3), 10000)
        local later = s.contracts.create(other, { targetCid = 'TARGET01', reason = 'again',
            reward = { baseline = { cash = 1000 } } })
        truthy(later, 'listed again after the drop-off')
    end)
end)

--------------------------------------------------------------------------
-- Switched off, hostile payloads, staff
--------------------------------------------------------------------------

describe('disposal switched off mid-step', function()
    it('finishes and pays every step at the next tick', function()
        local s, f, c, W, before = setup()
        Config.Disposal.Enabled = false
        tick(s, 10)
        eq(s.disposal.count(), 0)
        eq(cash(3), 10000)
        eq(total(s), before)
        local _, n = W.only()
        eq(n, 0)
    end)
end)

describe('hostile requests', function()
    it('change nothing and never raise', function()
        local s, f, c, W = setup()
        at(3, BODY)
        W.move(BODY)
        local fire = Env.events['crimson-hitman:disposalAct']
        for _, payload in ipairs({ nil, 'load', 42, {}, { action = 'load' }, { action = 'eat', id = c.id },
            { action = 'load', id = 'x' }, { action = 'load', id = ('a'):rep(500) },
            { action = { 'load' }, id = c.id }, { action = 'load', id = 'ct99999999' } }) do
            _G.source = 3
            local ok, err = pcall(fire, payload)
            _G.source = nil
            truthy(ok, tostring(err))
        end
        _G.source = 0
        truthy(pcall(fire, { action = 'load', id = c.id }))
        _G.source = 2
        truthy(pcall(fire, { action = 'load', id = c.id }))
        _G.source = 1
        truthy(pcall(fire, { action = 'load', id = c.id }))
        _G.source = nil
        eq(stepRow(s, c).stage, 'body', 'nobody but the hitman, and not from a bad payload')
        Config.Cooldowns.disposal = { per = 60, burst = 1 }
        s.ratelimit.resetAll()
        act(3, 'load', c.id)
        eq(stepRow(s, c).stage, 'loaded', 'the hitman loads')
    end)

    it('rate-limits the hitman', function()
        local s, f, c, W = setup()
        Config.Cooldowns.disposal = { per = 600, burst = 1 }
        s.ratelimit.resetAll()
        load(s, f, c, W)
        eq(stepRow(s, c).stage, 'loaded', 'the one allowed')
        dropOff(s, f, c, W)
        eq(stepRow(s, c).stage, 'loaded', 'refused once the bucket is spent')
        eq(cash(3), 5000, 'nothing paid meanwhile')
    end)
end)

describe('the staff ops', function()
    local function ask(src, op, data)
        Env.clientEvents = {}
        _G.source = src
        local fired, err = pcall(Env.events['crimson-hitman:admin'], { op = op, data = data or {}, __rid = 7 })
        _G.source = nil
        truthy(fired, tostring(err))
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:adminResult' then return event.args[1] end
        end
        return nil
    end

    it('set the spots (typed or Use my position), list, skip and make the vehicle again', function()
        local s, f, c, W, before = setup()
        s.bridges.install(s)
        Config.Cooldowns.admin = { per = 10, burst = 500 }
        Config.Cooldowns.adminWrite = { per = 10, burst = 500 }
        Env.addPlayer({ source = 7, citizenid = 'READER01', license = 'license:R', firstname = 'R', lastname = 'D' })
        Env.aces[7] = { command = true }
        at(6, { x = 321.0, y = 654.0, z = 31.0 })
        local r = ask(6, 'placeSet', { kind = 'disposal_drop', here = true })
        truthy(r.ok, tostring(r.message))
        eq(s.disposal.spot('drop').x, 321.0, 'where staff stand, read by the server')
        eq(ask(6, 'placeSet', { kind = 'moon', x = 1, y = 1, z = 1 }).ok, false)
        eq(ask(6, 'placeSet', { kind = 'disposal_drop', x = 1e9, y = 1, z = 1 }).ok, false, 'off the map')
        eq(ask(6, 'placeSet', { kind = 'disposal_drop', x = 'a', y = 1, z = 1 }).ok, false)
        truthy(ask(6, 'placeSet', { kind = 'disposal_drop', x = DROP.x, y = DROP.y, z = DROP.z }).ok)
        local my = ask(6, 'placeMyPosition', {})
        eq(my.data.x, 321.0)
        local list = ask(7, 'disposalList', {})
        truthy(list.ok, 'staff with a read ACE may read')
        eq(#list.data.steps, 1)
        eq(list.data.steps[1].contract, c.id)
        eq(list.data.steps[1].hitman, nil, 'who the hitman is only with the identity ACE')
        eq(ask(7, 'disposalSkip', { id = c.id }).ok, false, 'but not write')
        eq(ask(3, 'disposalList', {}).ok, false, 'and a player is refused')
        truthy(ask(6, 'disposalRespawn', { id = c.id }).ok)
        eq(W.removed, 1, 'the old one taken away')
        eq(ask(6, 'disposalSkip', { id = 'ct99999999' }).ok, false)
        truthy(ask(6, 'disposalSkip', { id = c.id }).ok)
        eq(cash(3), 10000, 'paid')
        eq(total(s), before)
        local dropRow = require('server.places').rows('disposal_drop')[1]
        truthy(ask(6, 'placeRemove', { id = dropRow.id }).ok)
        eq(s.disposal.spot('drop'), nil)
    end)
end)

--------------------------------------------------------------------------
-- Every store, booted through main.lua, and a restart mid-step
--------------------------------------------------------------------------

local function forget()
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
            package.loaded[name] = nil
        end
    end
end

local function boot(mode)
    forget()
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

local function restart(mode, old)
    if old and old.storage then rawset(old.storage, '__rawFixture', true) end
    forget()
    Env.events, Env.clientEvents, Env.notifications = {}, {}, {}
    Env.handlers, Env.threads, Env.timers, Env.commands = {}, {}, {}, {}
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Config.Database.Mode = mode
    local main = require('server.main')
    return main.start()
end

describe('body disposal in every store', function()
    for _, mode in ipairs({ 'memory', 'json', 'mysql' }) do
        it(mode .. ': from the kill to the drop-off, conserved', function()
            local s = boot(mode)
            local f = fixture(s)
            local _, _, c, W, before = setup({ stack = s, f = f })
            eq(cash(3), 5000)
            load(s, f, c, W)
            dropOff(s, f, c, W)
            eq(cash(3), 10000, mode .. ': paid at the drop-off')
            eq(total(s), before, mode .. ': conserved')
            eq(#s.storage.readRpRows('disposal'), 0)
        end)
    end

    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': a restart mid-step keeps the payout held, the stage and the spots', function()
            local s = boot(mode)
            local f = fixture(s)
            local _, _, c, W, before = setup({ stack = s, f = f })
            load(s, f, c, W)
            tick(s, 10)
            tick(s, 120)
            local spent = stepRow(s, c).spent
            truthy(spent >= 0)
            s.disposal.stop()
            local again = restart(mode, s)
            Config.Disposal.Enabled = true
            Config.Completion.KillPhotos = false
            Config.Cooldowns.disposal = { per = 10, burst = 100 }
            local W2 = fakeWorld(again)
            Env.advance(3600)
            again.escrow.retryPending('HITMAN01')
            eq(cash(3), 5000, mode .. ': still held after the restart')
            again.disposal.tick()
            again.disposal.tick()
            eq(again.disposal.count(), 1)
            eq(again.disposal.list()[1].stage, 'loaded', 'the stage kept')
            truthy(again.disposal.list()[1].secondsLeft > 1800 - 200, 'the downtime not counted')
            local _, n = W2.only()
            eq(n, 1, 'the vehicle made again')
            eq(again.disposal.spot('drop').x, DROP.x, 'the spots kept')
            dropOff(again, f, c, W2)
            eq(cash(3), 10000, mode .. ': paid after the restart')
            eq(total(again), before, 'conserved')
        end)
    end
end)
