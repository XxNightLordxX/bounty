--- Review 86, server fixes: each confirmed finding outside server/org/ (and
--- the two leftovers named with them), driven through the code the game
--- runs. Every test here fails on the tree before the fix (f8e11fa) and
--- passes after it.

local Exec = require('tests.harness.mysql_exec')
local L = CrimsonBoot.requireShared('locale').t

local function has(text, needle) return tostring(text):find(needle, 1, true) ~= nil end

--- An app request as the page sends it: the reply.
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

--- A stack with a staff member (6, every ACE) and a second hitman (4).
local function staffStack()
    local s = newStack()
    local f = fixture(s)
    Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
        firstname = 'Sam', lastname = 'Steward' })
    Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
        cash = 5000, bank = 50000, firstname = 'Kit', lastname = 'Vane' })
    Env.aces[6] = { ['crimson.admin'] = true, ['crimson.developer'] = true, ['crimson.identity'] = true }
    Config.Cooldowns.admin = { per = 10, burst = 5000 }
    Config.Cooldowns.adminWrite = { per = 10, burst = 5000 }
    s.bridges.install(s)
    return s, f
end

local function ask(s, src, op, data)
    return s.panel.handle(src, { op = op, data = data or {}, __rid = 7 })
end

local function refOf(s, subject)
    local looked = ask(s, 6, 'player', { subject = subject })
    truthy(looked and looked.ok, 'looked up ' .. tostring(subject))
    return looked.data.player.ref
end

local function placed(s, f, extra)
    local req = { targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
                  reward = { baseline = { cash = 5000 } } }
    for k, v in pairs(extra or {}) do req[k] = v end
    local c, err = s.contracts.create(f.creator, req)
    truthy(c, 'placed: ' .. tostring(err))
    return c
end

--------------------------------------------------------------------------
-- C3-1 / D86-1: a 'reduced' disposal timeout splits dirty money too
--------------------------------------------------------------------------

local SPAWN = { x = 200.0, y = 200.0, z = 30.0, h = 90.0 }
local DROP = { x = 500.0, y = 500.0, z = 30.0 }
local BODY = { x = 101.0, y = 100.0, z = 30.0 }

local function fakeWorld(s)
    local W = { vehicles = {}, seq = 0 }
    s.disposal.world = {
        spawn = function(_, at)
            W.seq = W.seq + 1
            W.vehicles[7000 + W.seq] = { x = at.x, y = at.y, z = at.z }
            return 7000 + W.seq
        end,
        exists = function(v) return W.vehicles[v] ~= nil end,
        coords = function(v)
            local c = W.vehicles[v]
            return c and { x = c.x, y = c.y, z = c.z } or nil
        end,
        remove = function(v) W.vehicles[v] = nil end,
        prepare = function() return true end,
    }
    return W
end

local function at(src, p) Env.players[src]._coords = { x = p.x, y = p.y, z = p.z } end

local function dirtyOf(src)
    local n = 0
    for _, slot in ipairs(Env.players[src]._inventory or {}) do
        if slot.name == 'black_money' then n = n + (slot.count or 0) end
    end
    return n
end

--- Dirty money a contract still holds, unsettled (what arrived taken off).
local function dirtyHeld(storage, contractId)
    local n = 0
    for _, line in ipairs(storage.readEscrow(contractId) or {}) do
        if line.source == 'dirty' and line.state ~= CH.ESCROW_STATE.SETTLED then
            n = n + (line.amount or 0) - (tonumber(line.deliver_arrived) or 0)
        end
    end
    return n
end

local function disposalConfig(pct)
    Config.Completion.KillPhotos = false
    Config.Cooldowns.disposal = { per = 10, burst = 100 }
    Config.Disposal.Enabled = true
    Config.Disposal.OnTimeout = 'reduced'
    Config.Disposal.ReducedPercent = pct
    Config.Disposal.PayNowPercent = 0
end

--- A verified kill on a contract funded with `reward`, its disposal step
--- started; the hitman's and placer's dirty money before.
local function disposalKill(s, f, reward, pct)
    disposalConfig(pct)
    fakeWorld(s)
    if not Env.players[6] then
        Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
            firstname = 'Sam', lastname = 'Steward' })
    end
    Env.aces[6] = { ['crimson.admin'] = true }
    local staff = { staff = true, cid = 'ADMIN001', source = 6 }
    local places = require('server.places')
    truthy(places.set(staff, 'disposal_vehicle', { x = SPAWN.x, y = SPAWN.y, z = SPAWN.z, heading = SPAWN.h }))
    truthy(places.set(staff, 'disposal_drop', { x = DROP.x, y = DROP.y, z = DROP.z }))
    local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
        mode = CH.MODE.COMPETITIVE, reward = reward })
    truthy(c, 'placed')
    truthy(s.contracts.accept(f.hitman, c.id, false), 'taken')
    local before = { hitman = dirtyOf(3), placer = dirtyOf(1),
                     hitmanCash = Env.players[3].PlayerData.money.cash,
                     placerCash = Env.players[1].PlayerData.money.cash }
    at(3, { x = 100.0, y = 100.0, z = 30.0 })
    at(2, BODY)
    Env.players[2]._health = 140
    s.death.recordDamage(3, 2, 123456)
    Env.players[2].PlayerData.metadata.isdead = true
    s.death.onVictimReport(2)
    local ok, err = s.photo.verifyAtScene(f.hitman, c.id)
    truthy(ok, 'verified: ' .. tostring(err))
    eq(s.disposal.count(), 1, 'a disposal step')
    return c, before
end

local function runOut(s)
    Env.advance(10)
    s.disposal.tick()
    s.missionSteps.tick()
    for _ = 1, 4 do
        Env.advance(600)
        s.disposal.tick()
        s.missionSteps.tick()
    end
end

describe('R86 C3-1/D86-1: a reduced disposal timeout splits dirty money', function()
    it('dirty $5,000 at 50%: the hitman keeps $2,500 dirty, the placer gets $2,500 dirty back', function()
        local s = newStack()
        local f = fixture(s)
        local c, before = disposalKill(s, f, { baseline = { dirty = 5000 } }, 50)
        runOut(s)
        eq(s.disposal.count(), 0, 'timed out')
        s.escrow.retryPending('HITMAN01')
        s.escrow.retryPending('CREATOR1')
        eq(dirtyOf(3) - before.hitman, 2500, 'the hitman keeps ReducedPercent of the dirty money')
        eq(dirtyOf(1) - before.placer, 2500, 'the rest goes back to the placer, as dirty money')
        eq(Env.players[1].PlayerData.money.bank + Env.players[1].PlayerData.money.cash
            - before.placerCash - (Env.players[1].PlayerData.money.bank), 0, 'not as clean money')
        local owed
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.portion == CH.PORTION.OWED and line.owed_to == 'CREATOR1' then owed = line end
        end
        truthy(owed, 'an owed line for the placer')
        eq(owed.source, 'dirty', 'owed in the line\'s own money')
        eq(dirtyHeld(s.storage, c.id), 0, 'nothing left held')
    end)

    it('cash still splits as before (control)', function()
        local s = newStack()
        local f = fixture(s)
        local _, before = disposalKill(s, f, { baseline = { cash = 5000 } }, 50)
        runOut(s)
        eq(Env.players[3].PlayerData.money.cash - before.hitmanCash, 2500)
        eq(Env.players[1].PlayerData.money.cash - before.placerCash, 2500)
    end)
end)

--- Booted through main.lua on a store that outlives the process.
local function forgetServer()
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
            package.loaded[name] = nil
        end
    end
end

local function bootStore(mode)
    forgetServer()
    Env.reset()
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Natives.resetResourceStates()
    resetConfig()
    Config.Database.Mode = mode
    if mode == 'mysql' then Exec.install(Natives) end
    if mode == 'json' then Natives.files = {} end
    return require('server.main').start()
end

local function restartStore(mode, old)
    if old and old.storage then rawset(old.storage, '__rawFixture', true) end
    forgetServer()
    Env.events, Env.clientEvents, Env.notifications = {}, {}, {}
    Env.handlers, Env.threads, Env.timers, Env.commands = {}, {}, {}, {}
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Config.Database.Mode = mode
    return require('server.main').start()
end

--- From the Nth store call on, the process is gone: that call and every
--- one after it raise, as a server that died there never makes them.
local function dieAt(s, n)
    rawset(s.storage, '__rawFixture', true)
    local real, count, dead = {}, 0, false
    local names = {}
    for name, fn in pairs(s.storage) do
        if type(fn) == 'function' then names[#names + 1] = name end
    end
    for _, name in ipairs(names) do
        local fn = s.storage[name]
        real[name] = fn
        rawset(s.storage, name, function(...)
            if dead then error('the process is gone', 0) end
            count = count + 1
            if count == n then
                dead = true
                error('the process died', 0)
            end
            return fn(...)
        end)
    end
    return function()
        for name, fn in pairs(real) do rawset(s.storage, name, fn) end
        return dead
    end
end

--- What a player holds of a money source: cash, or the dirty money item.
local function purseOf(src, source)
    if source == 'cash' then return Env.players[src].PlayerData.money.cash end
    return dirtyOf(src)
end

--- What a contract still holds of a source, unsettled (what arrived taken off).
local function heldOf(storage, contractId, source)
    local n = 0
    for _, line in ipairs(storage.readEscrow(contractId) or {}) do
        if line.source == source and line.state ~= CH.ESCROW_STATE.SETTLED then
            n = n + (line.amount or 0) - (tonumber(line.deliver_arrived) or 0)
        end
    end
    return n
end

describe('R86 C3-1/D86-1 crash matrix: a reduced timeout cut at any store call', function()
    -- Cash too: a cut between an owed line's write and its stake's left a
    -- voided split that the retry after the restart took for one made
    -- (SplitTo), and the hitman was paid the whole line.
    for _, source in ipairs({ 'dirty', 'cash' }) do
        for _, mode in ipairs({ 'json', 'mysql' }) do
            it(('%s, %s: after the restart nobody is paid twice, nothing vanishes, each gets their share')
                :format(source, mode), function()
                local scanned, whole = 0, 0
                for n = 1, 400 do
                    local s = bootStore(mode)
                    local f = fixture(s)
                    local c = disposalKill(s, f, { baseline = { [source] = 5000 } }, 50)
                    local hitman0, placer0 = purseOf(3, source), purseOf(1, source)
                    local restore = dieAt(s, n)
                    pcall(runOut, s)
                    local died = restore()
                    if not died then break end
                    scanned = scanned + 1
                    local again = restartStore(mode, s)
                    disposalConfig(50)
                    fakeWorld(again)
                    for _ = 1, 6 do
                        Env.advance(600)
                        pcall(again.disposal.tick)
                        pcall(again.missionSteps.tick)
                    end
                    pcall(again.escrow.retryPending, 'HITMAN01')
                    pcall(again.escrow.retryPending, 'CREATOR1')
                    local hitman = purseOf(3, source) - hitman0
                    local placer = purseOf(1, source) - placer0
                    local left = heldOf(again.storage, c.id, source)
                    local at = ('%s %s, cut at store call %d'):format(source, mode, n)
                    truthy(hitman <= 2500, ('the hitman got %d: %s'):format(hitman, at))
                    truthy(placer <= 2500, ('the placer got %d back: %s'):format(placer, at))
                    truthy(hitman + placer <= 5000, 'paid twice: ' .. at)
                    truthy(hitman + placer + left >= 5000,
                        ('%d vanished: %s'):format(5000 - hitman - placer - left, at))
                    if left == 0 then
                        -- Nothing left for staff (a line cut mid-give is
                        -- parked by design): each has exactly their share.
                        eq(hitman, 2500, 'the hitman\'s share: ' .. at)
                        eq(placer, 2500, 'the placer\'s share: ' .. at)
                        whole = whole + 1
                    end
                end
                truthy(scanned >= 10, ('%s %s: the timeout makes store calls: %d'):format(source, mode, scanned))
                truthy(whole >= scanned // 2, ('%s %s: most cuts end settled: %d of %d')
                    :format(source, mode, whole, scanned))
                resetConfig()
                Config.Database.Mode = 'memory'
            end)
        end
    end
end)

--------------------------------------------------------------------------
-- K1: a paid handover whose read-back raises still writes its ledger
--------------------------------------------------------------------------

describe('R86 K1: a paid handover writes its ledger rows and notice when the read-back raises', function()
    it('falls back to the contract the tick read', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            reward = { baseline = { cash = 5000 }, bonus = { cash = 2500 } } })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        for _, src in ipairs({ 1, 2, 3 }) do Env.players[src]._coords = { x = 200.0, y = 200.0, z = 30.0 } end
        Env.players[2].PlayerData.metadata.ishandcuffed = true
        Config.Kidnap.PlacerConfirms = false
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        local told
        local realTell = s.notify.contractCompleted
        s.notify.contractCompleted = function(contract, ...)
            told = contract and contract.id
            return realTell(contract, ...)
        end
        local realClaim, realRead = s.contracts.claimSlot, s.storage.readContract
        s.contracts.claimSlot = function(...)
            local r = table.pack(realClaim(...))
            s.storage.readContract = function()
                s.storage.readContract = realRead
                error('connection lost', 0)
            end
            return table.unpack(r, 1, r.n)
        end
        for _ = 1, math.floor((Config.Kidnap.CountdownSeconds + 2) * 1000 / Config.Kidnap.TickMs) do
            s.kidnap.tick(Config.Kidnap.TickMs)
        end
        s.contracts.claimSlot, s.storage.readContract = realClaim, realRead
        s.notify.contractCompleted = realTell
        eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED, 'paid')
        eq(told, c.id, 'the placer is told, from the contract as the tick read it')
        eq(#(s.storage.readLedger('HITMAN01', 50) or {}), 1, 'the hitman\'s ledger row')
        eq(#(s.storage.readLedger('CREATOR1', 50) or {}), 1, 'the placer\'s ledger row')
    end)
end)

--------------------------------------------------------------------------
-- C2-1: the post-respawn protection outlasts a relog
--------------------------------------------------------------------------

describe('R86 C2-1: a relog inside PostRespawnSeconds keeps the protection', function()
    it('still protected after clearPlayer, and the stamp goes once it lapses', function()
        local s = newStack()
        Config.Completion.Fulfilment = 'either'
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        Config.Immunity.MinTargetSessionMinutes = 0
        s.death.markDead('TARGET01')
        s.death.onRevived('TARGET01')
        Env.advance(20)
        truthy((s.contracts.isImmune(f.target, {})), 'protected right after a respawn')
        s.death.clearPlayer('TARGET01')
        Env.advance(5)
        local immune, why = s.contracts.isImmune(f.target, {})
        truthy(immune, 'still protected after a relog')
        eq(why, CH.ERR.TARGET_JUST_UP)
        Env.advance(Config.Immunity.PostRespawnSeconds)
        s.death.sweep()
        eq(s.death.sinceRespawn('TARGET01'), nil, 'the stamp is let go of once it lapses')
    end)
end)

--------------------------------------------------------------------------
-- P1: a proof item taken for a claim that raised and paid nothing goes back
--------------------------------------------------------------------------

local function cardCount(src)
    local n = 0
    for _, slot in pairs(Env.players[src]._inventory) do
        if slot.name == 'id_card' then n = n + (slot.count or 1) end
    end
    return n
end

describe('R86 P1: a proof item is given back when the claim raises before anything is claimed', function()
    it('the card comes back, the contract is still open', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt from last week',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 40000 } } })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local ok, err, why = s.settings.set('Improvements.ProofItems.Enabled', true, 'ADMIN001', 'ADMIN001')
        truthy(ok, tostring(err) .. ' ' .. tostring(why))
        local inv = Env.players[3]._inventory
        inv[#inv + 1] = { name = 'id_card', count = 1, slot = 41,
            metadata = { citizenid = 'TARGET01', firstname = 'Dana', lastname = 'Reyes' } }
        local realClaim, realRead = s.contracts.claimSlot, s.storage.readContract
        local inClaim = false
        s.contracts.claimSlot = function(...)
            inClaim = true
            local r = table.pack(pcall(realClaim, ...))
            inClaim = false
            if not r[1] then error(r[2], 0) end
            return table.unpack(r, 2, r.n)
        end
        s.storage.readContract = function(id, ...)
            if inClaim then
                inClaim = false
                error('Lock wait timeout exceeded', 0)
            end
            return realRead(id, ...)
        end
        local reply = call('proofItem', 3, { id = c.id })
        s.storage.readContract, s.contracts.claimSlot = realRead, realClaim
        eq(reply and reply.ok, false, 'not paid')
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED)
        eq(cardCount(3), 1, 'the card is given back')
        Env.advance(60)
        s.contracts.retryStuckClaims()
        eq(cardCount(3), 1, 'and not taken again, nor given twice')
    end)
end)

--------------------------------------------------------------------------
-- H1 / H2: the history card's money
--------------------------------------------------------------------------

local function book(card)
    local out = {}
    for _, way in ipairs({ 'in', 'out' }) do
        for _, row in ipairs(card.money[way]) do out[way .. ':' .. row.kind] = row.amount end
    end
    return out
end

describe('R86 H1/H2: the history card counts purchases that stood', function()
    it('no refund of a tip never written as bought; going dark as money out', function()
        local s = newStack()
        local f = fixture(s)
        local c = placed(s, f)
        s.audit.financial('location_tip_bought', 'HITMAN01', c.id, { amount = 25000 })
        s.audit.financial('location_tip_refunded', 'HITMAN01', c.id, { amount = 25000 })
        s.audit.financial('go_dark_bought', 'TARGET01', c.id, { amount = 50000 })
        s.audit.flush()
        local deps = { storage = s.storage, sanctions = s.sanctions, holds = s.holds }
        local hitman = book(s.history.build(deps, 'HITMAN01', true))
        eq(hitman['out:' .. L('history.informants')], 25000, 'the tip that stood')
        for key in pairs(hitman) do
            truthy(key:sub(1, 3) ~= 'in:', 'no money in for a refunded purchase: ' .. key)
        end
        local target = book(s.history.build(deps, 'TARGET01', true))
        eq(target['out:' .. L('history.going_dark')], 50000, 'going dark is money out')
    end)
end)

--------------------------------------------------------------------------
-- C4-01: decay does not count time taken or frozen between passes
--------------------------------------------------------------------------

local function decayStack()
    local s = newStack()
    local f = fixture(s, { creatorCash = 500000, creatorBank = 200000 })
    Config.Limits.TargetCooldownAfterResolveSeconds = 0
    Config.Limits.SameCreatorSameTargetCooldownSeconds = 0
    Config.Amendments.CancelCooldownSeconds = 0
    Config.Cooldowns.create = { per = 1, burst = 1000 }
    Config.Cooldowns.accept = { per = 1, burst = 1000 }
    Config.Notifications.ParanoidAlert = false
    Config.Improvements.ContractDecay.Enabled = true
    Config.Improvements.ContractDecay.Mode = 'rise'
    return s, f
end

local function minutes(s, n) for _ = 1, n do Env.advance(60); s.impBoard.tick() end end

describe('R86 C4-01: contract decay between stepping passes', function()
    it('a contract taken between passes is not charged for the time it was held', function()
        local s, f = decayStack()
        s.impBoard.tick()
        Env.advance(300)
        local c = assert(s.contracts.create(f.creator, { targetCid = f.target.cid, reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 10000 } } }))
        minutes(s, 2)
        truthy(s.contracts.accept(f.hitman, c.id, false), 'taken')
        minutes(s, 45)
        truthy(s.contracts.abandon(f.hitman, c.id), 'walked away')
        minutes(s, 15)
        eq(s.escrow.moneyValue(c.id), 10000, 'only ~17 minutes untaken: no rise yet')
        minutes(s, 50)
        eq(s.escrow.moneyValue(c.id), 11000, 'an hour of untaken waiting: one rise')
    end)

    it('a freeze between passes is not counted', function()
        local s, f = decayStack()
        s.impBoard.tick()
        Env.advance(300)
        local c = assert(s.contracts.create(f.creator, { targetCid = f.target.cid, reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 10000 } } }))
        minutes(s, 3)
        local Holds = CrimsonBoot.require('server.holds')
        truthy(Holds.freeze('STAFF01', f.target.cid, 'test', 'Tess'))
        minutes(s, 40)
        Holds.unfreeze('STAFF01', f.target.cid, 'done')
        minutes(s, 20)
        eq(s.escrow.moneyValue(c.id), 10000, 'only ~23 minutes unheld: no rise yet')
    end)
end)

--------------------------------------------------------------------------
-- C5-1 (tip): a tip's showing and wait stand still while the contract is held
--------------------------------------------------------------------------

describe('R86 C5-1: an informant tip under the app pause', function()
    it('stays on the map, and the card keeps its showing and wait', function()
        local s = newStack()
        Config.Intel.Enabled = true
        Config.Intel.LocationTip.Enabled = true
        Config.Notifications.ParanoidAlertJitter = { min = 0, max = 0 }
        local f = fixture(s)
        local c = assert(s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } }))
        Env.players[3].PlayerData.money.bank = 200000
        truthy(s.contracts.accept(f.hitman, c.id, false))
        Env.players[2]._coords = { x = 1200.0, y = -800.0, z = 30.0 }
        local price = { cost = 25000, account = 'bank' }
        truthy(s.locationTip.buy(f.hitman, c.id, price), 'bought')
        Env.advance(60)
        Config.Holds.AppPaused = true
        s.holds.syncAppPause()
        Env.clientEvents = {}
        Env.advance(11 * 60)
        local cleared = 0
        for _, e in ipairs(Env.clientEvents) do
            local key = type(e.args[1]) == 'table' and e.args[1].key
            if e.name == 'crimson-hitman:client:StepMarkerClear' and e.target == 3
                and type(key) == 'string' and key:sub(1, 4) == 'tip:' then
                cleared = cleared + 1
            end
        end
        eq(cleared, 0, 'not taken off the map during the hold')
        local card = s.locationTip.cardFor(s.storage.readContract(c.id), 'HITMAN01') or {}
        truthy(card.secondsLeft and card.secondsLeft > 0, 'the showing stands still: ' .. tostring(card.secondsLeft))
        truthy(card.cooldownSeconds and card.cooldownSeconds > 0, 'so does the wait: ' .. tostring(card.cooldownSeconds))
        Config.Holds.AppPaused = false
        s.holds.syncAppPause()
    end)
end)

--------------------------------------------------------------------------
-- photos-keep-raise: Keep in the app with a store that does not answer
--------------------------------------------------------------------------

local Util = require('crimson-hitman.shared.util')
local JPEG = '\255\216\255\224\0\16JFIF\0\1\1\0\0\1' .. ('\0\7\255kill'):rep(40)

local function photographed()
    local s = newStack()
    Natives.files = {}
    Config.Completion.PhotoStorage = 'server'
    local f = fixture(s)
    local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
        mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
    truthy(s.contracts.accept(f.hitman, c.id, false))
    Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
    Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
    Env.players[2]._health = 140
    s.death.recordDamage(3, 2, 123456)
    Env.players[2].PlayerData.metadata.isdead = true
    s.death.onVictimReport(2)
    local token = s.photo.issue(f.hitman, c.id)
    truthy(token, 'a token')
    local ok, err = s.photo.submit(f.hitman, token, nil, 'data:image/jpeg;base64,' .. Util.toBase64(JPEG))
    truthy(ok, 'the photo: ' .. tostring(err))
    local handle = s.storage.readLedger('CREATOR1', 10)[1].photo_ref
    truthy(handle, 'the client row names the photo')
    s.bridges.install(s)
    local reply = call('openPhoto', 1, { handle = handle })
    truthy(reply and reply.ok, 'opened: ' .. tostring(reply and reply.err))
    if reply.data and reply.data.latent then
        Env.advance(1)
        _G.source = 1
        pcall(Env.events['crimson-hitman:photoArrived'], handle)
        _G.source = nil
    end
    return s, f, c, handle
end

describe('R86 photos-keep-raise: Keep with a store that raises keeps the picture', function()
    it('the record and the file meet again, and the picture is never swept', function()
        local s, _, _, handle = photographed()
        local kp = s.storage.keepPhoto
        s.storage.keepPhoto = function() error('crimson-hitman: the database did not answer within 5000 ms', 0) end
        local r = call('photoDecision', 1, { handle = handle, choice = 'keep' })
        s.storage.keepPhoto = kp
        eq(r and r.ok, false, 'the store did not answer')
        -- The client presses Keep again.
        r = call('photoDecision', 1, { handle = handle, choice = 'keep' })
        truthy(r and r.ok, 'kept: ' .. tostring(r and r.err))
        local rec = s.storage.readPhoto(handle)
        eq(rec.state, CH.PHOTO.KEPT)
        truthy(Natives.files[rec.file] ~= nil, 'the record names a file that is there: ' .. tostring(rec.file))
        s.photos.sweepFiles()
        truthy(Natives.files[rec.file] ~= nil, 'and the sweep leaves it')
        local opened = call('openPhoto', 1, { handle = handle })
        truthy(opened and opened.ok, 'the kept photo opens: ' .. tostring(opened and opened.err))
    end)

    it('a raise with no retry: the next start puts the file back where the record names it', function()
        local s, _, _, handle = photographed()
        local kp = s.storage.keepPhoto
        s.storage.keepPhoto = function() error('crimson-hitman: the database did not answer within 5000 ms', 0) end
        call('photoDecision', 1, { handle = handle, choice = 'keep' })
        s.storage.keepPhoto = kp
        local rec = s.storage.readPhoto(handle)
        s.photos.sweepFiles()
        truthy(Natives.files[rec.file] ~= nil, 'the picture is where the record says: ' .. tostring(rec.file))
    end)
end)

--------------------------------------------------------------------------
-- C9-1: an agreed change of reason is reviewed as placing is
--------------------------------------------------------------------------

describe('R86 C9-1: review mode and an agreed change of reason', function()
    require('tests.harness.roleplay').it('a low-effort reason set by agreement goes to Needs review', function()
        local s = newStack()
        local f = fixture(s)
        Config.Roleplay.ReasonQuality.Enabled = true
        Config.Roleplay.ReasonQuality.LowEffortAction = 'review'
        local handle = s.app.mintTargetHandle('CREATOR1', 'TARGET01')
        local reply = call('create', 1, { target = handle, reason = 'He owes the crew a lot of money',
            mode = CH.MODE.COMPETITIVE, reward = { slots = { { baseline = { cash = 5000 } } } }, shown = {} })
        truthy(reply and reply.ok, 'placed ' .. tostring(reply and reply.err))
        local id = reply.data.id
        truthy(s.contracts.accept(f.hitman, id, false))
        local p = call('propose', 1, { id = id, kind = CH.AMENDMENT.CHANGE_REASON,
            payload = { reason = 'rdm because he looked at me' } })
        truthy(p and p.ok, 'proposed')
        local r = call('respondAmendment', 3, { id = p.data.id, approve = true })
        truthy(r and r.ok, 'agreed')
        eq(s.storage.readContract(id).reason, 'rdm because he looked at me')
        local n = 0
        for _, item in ipairs(s.review.list(true, 50)) do
            if item.kind == 'low_effort_reason' then n = n + 1 end
        end
        eq(n, 1, 'one item for staff')
    end)
end)

--------------------------------------------------------------------------
-- E10-1: an import apply holds to the preview key for key
--------------------------------------------------------------------------

describe('R86 E10-1: settings import apply against a newer change', function()
    it('refuses when the changes are not the ones previewed, and writes nothing', function()
        local s = staffStack()
        truthy(ask(s, 6, 'setSetting', { key = 'Limits.MaxAcceptedPerHitman', value = 4 }).ok)
        local text = json.encode({ format = 'crimson-hitman-settings', version = 1, settings = {
            ['Limits.MaxAcceptedPerHitman'] = 4, ['Limits.TargetCooldownAfterResolveSeconds'] = 900 } })
        local pv = ask(s, 6, 'settingsImport', { text = text })
        truthy(pv.ok, tostring(pv.message))
        eq(#pv.data.changes, 1)
        truthy(ask(s, 6, 'setSetting', { key = 'Limits.MaxAcceptedPerHitman', value = 6 }).ok)
        truthy(ask(s, 6, 'setSetting', { key = 'Limits.TargetCooldownAfterResolveSeconds', value = 900 }).ok)
        local r = ask(s, 6, 'settingsImportApply', { text = text, expect = #pv.data.changes })
        eq(r.ok, false, 'refused')
        eq(r.message, L('settingsio.the_settings_changed_since_the_preview'))
        eq(Config.Limits.MaxAcceptedPerHitman, 6, 'the newer change stands')
    end)

    it('applies as before when nothing moved', function()
        local s = staffStack()
        local text = json.encode({ format = 'crimson-hitman-settings', version = 1, settings = {
            ['Limits.TargetCooldownAfterResolveSeconds'] = 900 } })
        local pv = ask(s, 6, 'settingsImport', { text = text })
        local r = ask(s, 6, 'settingsImportApply', { text = text, expect = #pv.data.changes })
        truthy(r.ok, tostring(r.message))
        eq(Config.Limits.TargetCooldownAfterResolveSeconds, 900)
    end)
end)

--------------------------------------------------------------------------
-- C1: json writeReview is not stored when records.json is not written
--------------------------------------------------------------------------

describe('R86 C1: a json review item the file would not take', function()
    it('is kept as unwritten, not answered as stored', function()
        local s = newStack()
        fixture(s)
        package.loaded['crimson-hitman.server.storage.json'] = nil
        Natives.files, Natives.blocked = {}, {}
        local store = require('crimson-hitman.server.storage.json')
        store.open()
        s.storage = store
        s.audit.init(store)
        s.review.init({ storage = store, escrow = s.escrow, audit = s.audit })
        s.escrow.init(store, s.audit, s.review)
        Natives.blocked['data/records.json'] = true
        local id = s.review.open({ kind = 'bailout_refund_stranded', contract_id = 'ct00000001',
            cids = { payer = 'TARGET01', creator = 'CREATOR1' }, amount = 5000, account = 'bank',
            known = { reason = 'test' } })
        eq(s.review.stateOf(id), 'unwritten', 'not in the store yet')
        Natives.blocked = {}
        s.review.retryUnwritten()
        eq(s.review.stateOf(id), 'open', 'written once the file takes it')
        truthy(has(Natives.files['data/records.json'] or '', id), 'and on disk')
        package.loaded['crimson-hitman.server.storage.json'] = nil
    end)
end)

--------------------------------------------------------------------------
-- D86-2: Staff Extend on a deadline banked past the lifetime
--------------------------------------------------------------------------

describe('R86 D86-2: Staff Extend when the deadline is past the lifetime', function()
    it('extends the lifetime that ends it, and says the time it really has', function()
        local s, f = staffStack()
        local c = placed(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local now = os.time()
        local row = s.storage.readContract(c.id)
        row.deadline_at, row.expires_at = now + 84164, now + 11621
        s.storage.writeContract(row)
        local r = ask(s, 6, 'adjustDeadline', { id = c.id, seconds = 3600, reason = 'ticket' })
        truthy(r.ok, 'extended: ' .. tostring(r.err) .. ' ' .. tostring(r.message))
        row = s.storage.readContract(c.id)
        eq(row.expires_at - now, 11621 + 3600, 'the lifetime moved by the hour')
        eq(row.deadline_at - now, 84164, 'the banked deadline stays')
        truthy(has(r.message, (L('panel.extended_by_left_before_left_now')):sub(1, 9)), tostring(r.message))
    end)
end)

--------------------------------------------------------------------------
-- F1 (garage): no keys adapter, an unlocked vehicle and a printed line
--------------------------------------------------------------------------

describe('R86 F1: the organisation garage without a keys adapter', function()
    it('leaves the vehicle unlocked', function()
        local W = require('tests.harness.org_world')
        local s = W.world({ configure = function()
            Config.Integrations.Banking = 'none'
            Config.Integrations.Keys = 'none'
            Config.Organisation.Garage = true
            Config.Organisation.GarageVehicles = { 'sultan' }
        end })
        W.crew(s)
        W.at(6, 300.0, 300.0, 30.0)
        assert(s.org.placeSpot({ staff = true, cid = 'ADMIN001', source = 6 }, { kind = 'garage', here = true }))
        W.at(13, 300.0, 300.0)
        local out = W.call('orgGarageTake', 13, { model = 'sultan' })
        eq(out.ok, true, tostring(out.err))
        local _, v = next(Env.vehicles)
        eq(v.locked, 1, 'unlocked: nobody could get keys for it')
    end)

    it('counts the keys script as needed by the garage', function()
        resetConfig()
        Config.Organisation.Enabled = true
        Config.Organisation.Garage = true
        Config.Integrations.Keys = 'none'
        eq(CrimsonBoot.requireShared('integrations').status('keys').needed, true)
        resetConfig()
    end)
end)

--------------------------------------------------------------------------
-- Leftovers: sentToOrg; the protect/suspend answers as whole sentences
--------------------------------------------------------------------------

describe('R86 leftover: suspend and protect answer in whole sentences', function()
    it('each span its own translated sentence', function()
        local s = staffStack()
        local r = ask(s, 6, 'protect', { ref = refOf(s, 2), hours = 1, reason = 'Event guest' })
        truthy(r.ok, tostring(r.message))
        eq(r.message, (L('panel.protected_hours_one')):format('Dana Reyes', 1))
        r = ask(s, 6, 'suspend', { ref = refOf(s, 1), days = 2, reason = 'Contract spam' })
        truthy(r.ok, tostring(r.message))
        truthy(has(r.message, 'for 2 days'), r.message)
        eq(r.message, (L('panel.suspended_days_many')):format(r.message:match('^(.-) is suspended'), 2))
    end)
end)

--------------------------------------------------------------------------
-- Lows
--------------------------------------------------------------------------

describe('R86 F5: inventory needed by burner phones and proof items', function()
    it('says so with the feature on', function()
        resetConfig()
        for _, k in pairs({ 'item', 'weapon', 'dirty' }) do Config.Sources[k].enabled = false end
        local I = CrimsonBoot.requireShared('integrations')
        eq(I.status('inventory').needed, false, 'nothing needs it')
        Config.Roleplay.BurnerPhone.Enabled = true
        eq(I.status('inventory').needed, true, 'burner phones')
        Config.Roleplay.BurnerPhone.Enabled = false
        Config.Improvements.ProofItems.Enabled = true
        eq(I.status('inventory').needed, true, 'proof items')
        resetConfig()
    end)
end)

describe('R86 F1 (configcheck): a named adapter not started beside a started one', function()
    it('names the setting, not an install', function()
        resetConfig()
        local I = CrimsonBoot.requireShared('integrations')
        local st = {
            kind = 'ambulance', key = 'Ambulance', choice = 'qbx_medical', valid = true,
            names = { 'sc-ambulance', 'qbx_medical' },
            detected = { { name = 'sc-ambulance', resource = 'sc-ambulance', up = true },
                         { name = 'qbx_medical', resource = 'qbx_medical', up = false } },
        }
        local names, started = I.notStarted(st)
        eq(#names, 1)
        eq(names[1], 'qbx_medical')
        eq(started, 'sc-ambulance')
        falsy(has(I.offLine(st), 'sc-ambulance /'), I.offLine(st))
    end)
end)

describe('R86 C1-1: the diagnosis names the escrow source that is off', function()
    it('weapons and money when only item escrow is off', function()
        local s = staffStack()
        Config.Sources.item.enabled = false
        local lines = s.admin.diagnose(0)
        local text = table.concat(type(lines) == 'table' and lines or {}, '\n')
        truthy(has(text, L('admin.item_escrow_is_off_players_are')), text)
        falsy(has(text, L('admin.the_app_tells_players_this_server')), 'not money only')
    end)
end)

describe('R86 B1/B-3: /cleanse with a mistyped price', function()
    it('says the price is not that, not that it changed; and refuses 1e400', function()
        local s = newStack()
        local f = fixture(s)
        s.bridges.install(s)
        local c = placed(s, f, { bailoutAmount = 15000 })
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        local said = {}
        Env.chat = {}
        local cmd = Env.commands[Config.Bailout.Command]
        truthy(cmd, 'the command')
        Env.clientEvents = {}
        cmd(2, { c.id, '14000' })
        for _, e in ipairs(Env.clientEvents) do
            if type(e.args) == 'table' then said[#said + 1] = json.encode(e.args) end
        end
        local text = table.concat(said, ' ')
        falsy(has(text, 'the price changed from'), text)
        truthy(has(text, 'the price is not'), text)
        Env.clientEvents = {}
        cmd(2, { c.id, '1e400' })
        local inf = {}
        for _, e in ipairs(Env.clientEvents) do inf[#inf + 1] = json.encode(e.args) end
        falsy(has(table.concat(inf, ' '), 'inf'), table.concat(inf, ' '))
    end)
end)

describe('R86 C3-2: /ch-diag config lists what the start put back', function()
    it('a value the start corrected is still named', function()
        local s = newStack()
        local check = CrimsonBoot.require('server.configcheck')
        check.init({ settings = s.settings })
        check.startSaid({ 'Config.Completion.PhotoMaxBytes is 10; it has to be at least 1000. Using 600000.' })
        local found = false
        for _, row in ipairs(check.findings()) do
            if has(row.text, 'PhotoMaxBytes') then found = true end
        end
        truthy(found, 'the start\'s own warning is listed')
    end)
end)

describe('R86 C3-3: the disposal start notice with part paid at once', function()
    it('says part is paid now', function()
        local s = newStack()
        local f = fixture(s)
        Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
        disposalConfig(50)
        Config.Disposal.OnTimeout = 'pay'
        local reward = { baseline = { cash = 5000 } }
        -- PayNow on before the kill.
        local real = disposalConfig
        local _ = real
        fakeWorld(s)
        Config.Disposal.PayNowPercent = 40
        Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001', firstname = 'Sam', lastname = 'Steward' })
        local staff = { staff = true, cid = 'ADMIN001', source = 6 }
        local places = require('server.places')
        truthy(places.set(staff, 'disposal_vehicle', { x = SPAWN.x, y = SPAWN.y, z = SPAWN.z, heading = SPAWN.h }))
        truthy(places.set(staff, 'disposal_drop', { x = DROP.x, y = DROP.y, z = DROP.z }))
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE, reward = reward })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        at(3, { x = 100.0, y = 100.0, z = 30.0 })
        at(2, BODY)
        Env.players[2]._health = 140
        s.death.recordDamage(3, 2, 123456)
        Env.players[2].PlayerData.metadata.isdead = true
        s.death.onVictimReport(2)
        truthy(s.photo.verifyAtScene(f.hitman, c.id))
        local found = false
        for _, n in ipairs(Natives.calls.notifications) do
            if has(n.content, 'Part of your payout is paid now') then found = true end
        end
        truthy(found, 'the start notice says part is paid now')
    end)
end)

describe('R86 C5-2/C5-3 (main): start-up wording', function()
    it('a block written as a number is said once, as the wrong kind', function()
        newStack()
        local main = require('crimson-hitman.server.main')
        Config.Intel.LocationTip = 25000
        local _, fatal = main.validateConfig(true)
        resetConfig()
        local missing, kind = 0, 0
        for _, line in ipairs(fatal or {}) do
            if has(line, 'Intel.LocationTip is missing entirely') then missing = missing + 1 end
            if has(line, 'Intel.LocationTip is a number') then kind = kind + 1 end
        end
        eq(missing, 0, 'not called missing')
        eq(kind, 1, 'said once, as a number')
    end)

    it('AllowModeSwitch as a string is quoted', function()
        newStack()
        local main = require('crimson-hitman.server.main')
        Config.Database.AllowModeSwitch = 'true'
        local _, _, warn = main.validateConfig(true)
        resetConfig()
        local quoted = false
        for _, line in ipairs(warn or {}) do
            if has(line, 'AllowModeSwitch') and has(line, '"true"') then quoted = true end
        end
        truthy(quoted, 'the string is quoted')
    end)
end)

describe('R86 C5-1 (main): an inventory probe that answers false', function()
    it('is reported as no read answering, not as nobody online', function()
        local s = newStack()
        fixture(s)
        local main = require('crimson-hitman.server.main')
        local app = CrimsonBoot.require('server.app')
        local real = app.probeInventory
        app.probeInventory = function() return false end
        local Log = CrimsonBoot.requireShared('log')
        Log.beginStart()
        pcall(main.reportIntegrations)
        app.probeInventory = real
        local text = table.concat(Log.view and (Log.view().problems or {}) or {}, '\n')
        local all = {}
        for _, line in ipairs(Env.console or {}) do all[#all + 1] = tostring(line) end
        text = text .. table.concat(all, '\n')
        local seen = false
        for _, p in ipairs(Log.summary and select(2, pcall(Log.summary)) or {}) do
            if has(p, 'no ox_inventory read') then seen = true end
        end
        truthy(seen or has(text, 'no ox_inventory read'), 'the warning is said')
    end)
end)

describe('R86 C5-2: a change of clothes brings the headshot sooner', function()
    it('re-renders a minute after the last render, keeping the old face meanwhile', function()
        local s = newStack()
        fixture(s)
        Config.Mugshot.Enabled = true
        local M = s.mugshot
        truthy(M, 'the headshots')
        M.request('TARGET01')
        local asked = 0
        for _, e in ipairs(Env.clientEvents) do if e.name == 'crimson-hitman:renderMugshot' then asked = asked + 1 end end
        eq(asked, 1, 'a first render asked')
        truthy(M.store('TARGET01', 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUg=='), 'stored')
        Env.advance(30)
        truthy(M.invalidate('TARGET01'), 'taken as a hint')
        Env.clientEvents = {}
        Env.advance(31)
        local face = M.request('TARGET01')
        truthy(face, 'the old face is still served')
        local again = 0
        for _, e in ipairs(Env.clientEvents) do if e.name == 'crimson-hitman:renderMugshot' then again = again + 1 end end
        eq(again, 1, 'asked again a minute after the last render')
    end)
end)

describe('R86 E8-2: Current undoes an own preset', function()
    it('saves the own preset\'s keys too', function()
        local s = staffStack()
        local P = s.presets or CrimsonBoot.require('server.presets')
        truthy(ask(s, 6, 'setSetting', { key = 'Relay.Enabled', value = false }).ok)
        truthy(ask(s, 6, 'presetSaveOwn', { name = 'Night' }).ok, 'saved')
        truthy(ask(s, 6, 'setSetting', { key = 'Relay.Enabled', value = true }).ok)
        local applied = ask(s, 6, 'presetApply', { name = 'Night' })
        truthy(applied.ok, tostring(applied.message))
        eq(Config.Relay.Enabled, false)
        local back = ask(s, 6, 'presetApply', { name = P.CURRENT })
        truthy(back.ok, tostring(back.message))
        eq(Config.Relay.Enabled, true, 'Current put it back')
    end)
end)

describe('R86 E8-1: panel writes that wait for recovery', function()
    it('refuses a note, a playtime, an announcement, a photo removal and alerts', function()
        local s, f = staffStack()
        local c = placed(s, f)
        s.app.ready = false
        for _, op in ipairs({ 'addNote', 'setPlaytime', 'announce', 'removePhotos', 'ackAlerts', 'testAlert' }) do
            local r = ask(s, 6, op, { id = c.id, text = 'note', hours = 1, message = 'hi' })
            eq(r.err, 'recovering', op)
        end
        s.app.ready = true
    end)
end)

describe('R86 E8-4: dispatch reaches departments added by job type', function()
    it('names the job of an officer online by type', function()
        local s = newStack()
        fixture(s)
        Env.addPlayer({ source = 9, citizenid = 'COP00001', license = 'license:cop', firstname = 'Lee', lastname = 'Law',
            job = { name = 'lspd', type = 'leo', onduty = true, grade = { level = 1 } } })
        Config.Advisory.RecipientJobTypes = { leo = true }
        local jobs = CrimsonBoot.require('server.police').jobs()
        local found = false
        for _, j in ipairs(jobs) do if j == 'lspd' then found = true end end
        truthy(found, 'lspd: ' .. table.concat(jobs, ','))
    end)
end)

describe('R86 E8-5: a release time only from the check that holds', function()
    it('asks only a check that holds the line', function()
        local Payout = CrimsonBoot.require('server.payout')
        Payout.add('disposal', { holds = function() return true end })
        Payout.add('deaddrop', { holds = function() return false end, releasesAt = function() return 12345 end })
        eq(Payout.releasesAt('X', {}), nil, 'disposal holds it and says no time')
        Payout.add('disposal', { holds = function() return false end })
        eq(Payout.releasesAt('X', {}), nil, 'the dead drop does not hold it')
        Payout.add('deaddrop', { holds = function() return true end, releasesAt = function() return 12345 end })
        eq(Payout.releasesAt('X', {}), 12345)
        Payout.add('disposal', {})
        Payout.add('deaddrop', {})
    end)
end)

describe('R86 E8-6: a manual payment in words, not the account code', function()
    it('says bank account, not "in bank"', function()
        local s = staffStack()
        local r = ask(s, 6, 'manualPay', { ref = refOf(s, 1), amount = 1000, account = 'bank', reason = 'refund for bug' })
        truthy(r.ok, tostring(r.message))
        falsy(has(r.message, 'in bank'), r.message)
        eq(r.message, (L('panel.paid_bank_to')):format(1000, r.message:match('account of (.-)%.$')))
    end)
end)

describe('R86 C10-1/C10-3/E10-2: staff reassign answers', function()
    it('a frozen hitman is said as on hold', function()
        local s, f = staffStack()
        local c = placed(s, f, { mode = CH.MODE.EXCLUSIVE })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        truthy(s.holds.freeze('ADMIN001', 'HITMAN02', 'x'))
        local ref = refOf(s, 4)
        local r = ask(s, 6, 'reassignHitman', { id = c.id, ref = ref, reason = 'ticket' })
        eq(r.err, 'hitman_frozen')
        eq(r.message, L('staff_reassign.that_hitman_is_on_hold_by'))
        local pv = ask(s, 6, 'reassignPreview', { id = c.id, ref = ref })
        eq(pv.data.refused, 'hitman_frozen')
    end)

    it('a waived stake is not refused for the stake window', function()
        local s, f = staffStack()
        local c = placed(s, f, { mode = CH.MODE.EXCLUSIVE, penaltyAmount = 1000 })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local row = s.storage.readContract(c.id)
        row.deadline_at = os.time() + 600
        s.storage.writeContract(row)
        local r = ask(s, 6, 'reassignHitman', { id = c.id, ref = refOf(s, 4), reason = 'ticket: rescue' })
        truthy(r.err ~= CH.ERR.TOO_LITTLE_TIME, 'not refused for a stake nobody puts up: ' .. tostring(r.err))
    end)

    it('a removal that fails is said as one', function()
        local s, f = staffStack()
        local c = placed(s, f, { mode = CH.MODE.EXCLUSIVE })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local real = s.staffContract.removeHitman
        s.staffContract.removeHitman = function() return false, 'not_active' end
        local r = ask(s, 6, 'reassignHitman', { id = c.id, ref = refOf(s, 4), reason = 'ticket' })
        s.staffContract.removeHitman = real
        eq(r.err, 'remove_failed')
        eq(r.message, L('staff_reassign.an_operative_could_not_be_taken'))
    end)
end)

describe('R86 C10-2: a removal record whose delete failed', function()
    it('does not bar an operative still on the contract after a restart', function()
        local s, f = staffStack()
        local c = placed(s, f, { mode = CH.MODE.EXCLUSIVE })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local hit = s.storage.readHitman(c.id, 'HITMAN01')
        local realAbandon, realDelete = s.contracts.abandon, s.storage.deleteContractStaff
        s.contracts.abandon = function() return false, CH.ERR.BUSY end
        s.storage.deleteContractStaff = function() error('database blip', 0) end
        local ok = s.staffContract.removeHitman({ cid = 'ADMIN001', name = 'Sam', source = 6 }, c.id, hit.id, 'x',
            { block = true })
        s.contracts.abandon, s.storage.deleteContractStaff = realAbandon, realDelete
        falsy(ok, 'refused')
        s.staffContract.init({ storage = s.storage, audit = s.audit, notify = s.notify,
            contracts = s.contracts, identity = s.identity })
        falsy(s.staffContract.barred(c.id, 'HITMAN01', nil), 'not barred after a start')
    end)
end)

describe('R86 E10-3: the reward preview refuses as the change does', function()
    it('off while RewardChangeMax is 0, and a lowering past it', function()
        local s, f = staffStack()
        local c = placed(s, f, { reward = { baseline = { cash = 50000 } } })
        Config.Staff.RewardChangeMax = 0
        local pv = ask(s, 6, 'rewardPreview', { id = c.id, by = 1000 })
        eq(pv.data.refused, 'reward_change_off')
        Config.Staff.RewardChangeMax = 1000
        pv = ask(s, 6, 'rewardPreview', { id = c.id, by = -5000 })
        eq(pv.data.refused, 'too_much')
    end)
end)

describe('R86 C2: the json contract count warning with Debug off', function()
    it('is printed', function()
        newStack()
        Config.Debug = false
        Config.Database.Json.WarnContractCount = 0
        package.loaded['crimson-hitman.server.storage.json'] = nil
        Natives.files, Natives.blocked = {}, {}
        local store = require('crimson-hitman.server.storage.json')
        store.open()
        store.writeContract({ id = 'ct00000001', creator_cid = 'A', target_cid = 'B',
            state = CH.STATE.ACTIVE, created_at = os.time() })
        store.save(true)
        package.loaded['crimson-hitman.server.storage.json'] = nil
        local before = #Env.console
        local again = require('crimson-hitman.server.storage.json')
        again.open()
        local said = false
        for i = before + 1, #Env.console do
            if has(Env.console[i], 'better on') then said = true end
        end
        package.loaded['crimson-hitman.server.storage.json'] = nil
        resetConfig()
        truthy(said, 'warned with Debug off')
    end)
end)

describe('R86 E14-1: the version from a JSON answer', function()
    it('reads its version field, not the first dotted number', function()
        local V = CrimsonBoot.require('server.versioncheck')
        local v = V.parse('{"rating":4.5,"version":"1.0.0"}')
        truthy(v, 'read')
        eq(v[1], 1)
        eq(v[2], 0)
        v = V.parse('{"released":"2026.11.13","tag_name":"v1.3.2"}')
        eq(v[1], 1)
        eq(v[2], 3)
        eq(v[3], 2)
        eq(V.parse('1.4.0')[2], 4, 'plain text as before')
    end)
end)

describe('R86 A-1: the stake window counts the lifetime', function()
    it('refuses a staked accept on 28 minutes of lifetime', function()
        local s = newStack()
        local f = fixture(s)
        local c = placed(s, f, { penaltyAmount = 1000 })
        local row = s.storage.readContract(c.id)
        row.expires_at = os.time() + 28 * 60
        s.storage.writeContract(row)
        local ok, err = s.contracts.accept(f.hitman, c.id, false)
        falsy(ok, 'refused')
        eq(err, CH.ERR.TOO_LITTLE_TIME)
    end)
end)
