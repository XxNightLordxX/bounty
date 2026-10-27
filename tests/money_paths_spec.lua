--- Money that went to nobody, or to the wrong person, by paths that each
--- looked right on their own.
---
--- Every test here failed before its fix, with the figure it names.

local Exec = require('tests.harness.mysql_exec')

--- main.lua's own start on memory. `configure` runs after the config is
--- reset and before the start, as a server.cfg's config would.
local function boot(configure)
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
            package.loaded[name] = nil
        end
    end
    package.loaded['server.main'] = nil
    Env.reset()
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Natives.resetResourceStates()
    resetConfig()
    Config.Database.Mode = 'memory'
    if configure then configure() end
    local main = require('server.main')
    return main, main.start()
end

local function worth(src)
    local p = Env.players[src]
    return p.PlayerData.money.cash + p.PlayerData.money.bank
end

local function carried(src, name)
    local n = 0
    for _, e in ipairs(Env.players[src]._inventory or {}) do
        if e.name == name then n = n + (e.count or 0) end
    end
    return n
end

--- A stack whose store is the mysql backend running on the statement
--- executor, so an upsert that leaves a column off its update list behaves
--- the way the shipped default does.
local function newMysqlStack()
    local stack = newStack()
    package.loaded['crimson-hitman.server.storage.mysql'] = nil
    Exec.install(Natives)
    local store = require('crimson-hitman.server.storage.mysql')
    store.open()

    stack.audit.init(store)
    stack.escrow.init(store, stack.audit)
    stack.progression.init({ storage = store, identity = stack.identity, audit = stack.audit })
    stack.contracts.init({ storage = store, escrow = stack.escrow, identity = stack.identity,
                           audit = stack.audit, notify = stack.notify,
                           progression = stack.progression, death = stack.death })
    stack.photos.init({ storage = store, audit = stack.audit })
    stack.ledger.init({ storage = store, photos = stack.photos, notify = stack.notify })
    stack.bailout.init({ storage = store, identity = stack.identity,
                         contracts = stack.contracts, escrow = stack.escrow,
                         audit = stack.audit, notify = stack.notify, kidnap = stack.kidnap,
                         death = stack.death })
    stack.death.init({ storage = store, identity = stack.identity,
                       contracts = stack.contracts, audit = stack.audit })
    stack.amendments.init({ storage = store, identity = stack.identity,
                            contracts = stack.contracts, escrow = stack.escrow,
                            audit = stack.audit, notify = stack.notify })
    stack.storage = store
    return stack
end

--- Run `first`, and at its Nth store call run `second` to completion, the
--- way a second player's event lands while the first awaits the database.
local function interleaveAt(s, n, first, second)
    local calls, fired = 0, false
    local WATCH = {
        'compareSetContractState', 'claimEscrowLine', 'settleEscrowLine',
        'writeContract', 'writeEscrow', 'addHitman', 'updateHitman',
        'setEscrowAmount', 'advanceSlot', 'readContract', 'readEscrow',
        'readHitmen', 'readEscrowLine', 'readHitman', 'countHitmanContracts',
        'readHitmanById',
    }
    local real = {}
    for _, name in ipairs(WATCH) do
        real[name] = s.storage[name]
        s.storage[name] = function(...)
            calls = calls + 1
            if calls == n and not fired then
                fired = true
                pcall(second)
            end
            return real[name](...)
        end
    end
    local ok, err = pcall(first)
    for _, name in ipairs(WATCH) do s.storage[name] = real[name] end
    return ok, err, calls
end

--- Held on a closed contract and owed to nobody: money nothing will move.
local function stranded(s, contractId)
    local contract = s.storage.readContract(contractId)
    local out = {}
    if not (contract and CH.TERMINAL[contract.state]) then return out end
    for _, line in ipairs(s.storage.readEscrow(contractId)) do
        if line.state ~= CH.ESCROW_STATE.SETTLED and not line.owed_to then
            out[#out + 1] = ('%s %s %s'):format(line.id, line.portion, tostring(line.amount))
        end
    end
    return out
end

--- Walk every point in `first` at which `second` could land.
local function everyInterleaving(build, first, second)
    local s0, f0, c0 = build()
    local _, _, depth = interleaveAt(s0, math.huge,
        function() first(s0, f0, c0) end, function() end)

    local broken = {}
    for n = 1, depth do
        local s, f, c = build()
        interleaveAt(s, n, function() first(s, f, c) end, function() second(s, f, c) end)
        local left = stranded(s, c.id)
        if #left > 0 then
            broken[#broken + 1] = ('at store call %d, %s: %s'):format(n,
                s.storage.readContract(c.id).state, table.concat(left, '; '))
        end
    end
    return broken, depth
end

describe('a memory-mode shutdown with a buyout waiting out its delay', function()
    it('gives the target their premium back', function()
        local _, m = boot()
        local f = fixture(m)
        local c = m.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 5000 } }, bailoutAmount = 10000,
        })
        truthy(c)
        truthy(m.contracts.accept(f.hitman, c.id, false))

        local before = worth(2)
        truthy(m.bailout.buy(f.target, c.id))
        eq(before - worth(2), 10000, 'the premium is taken now and settled later')
        truthy(m.storage.readContract(c.id).bailout_queued_at, 'queued, with a hitman on it')

        Env.handlers['onResourceStop'](GetCurrentResourceName())

        eq(worth(2), before,
            'the queue lives on the contract row, which goes with the resource: '
            .. 'a premium not handed back here exists nowhere')
    end)

    it('pays the creator it was on its way to when the target has gone', function()
        local _, m = boot()
        local f = fixture(m)
        local c = m.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 5000 } }, bailoutAmount = 10000,
        })
        truthy(m.contracts.accept(f.hitman, c.id, false))
        truthy(m.bailout.buy(f.target, c.id))
        Env.removePlayer(2)

        local before = worth(1)
        Env.handlers['onResourceStop'](GetCurrentResourceName())
        eq(worth(1) - before, 15000, 'the escrow back and the premium, rather than neither')
    end)

    --- The target's refund raised after it landed (qbx_core adds the money
    --- before the hooks that can raise). Read as not paid, the premium went
    --- on to the creator as well: paid twice.
    local function boughtAndStopping(targetAddMoney)
        local _, m = boot()
        local f = fixture(m)
        local c = m.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 5000 } }, bailoutAmount = 10000,
        })
        truthy(m.contracts.accept(f.hitman, c.id, false))
        truthy(m.bailout.buy(f.target, c.id))
        local creator, target = worth(1), worth(2)
        local p = Env.players[2]
        local real = p.Functions.AddMoney
        p.Functions.AddMoney = function(...) return targetAddMoney(real, ...) end
        -- The rows, as they are written: the store goes with the stop.
        local rows, financial = {}, m.audit.financial
        m.audit.financial = function(action, actor, contractId, detail)
            rows[#rows + 1] = { action = action, actor = actor, detail = detail }
            return financial(action, actor, contractId, detail)
        end
        Env.handlers['onResourceStop'](GetCurrentResourceName())
        m.audit.financial = financial
        p.Functions.AddMoney = real
        return rows, c, worth(1) - creator, worth(2) - target
    end

    it('does not pay the creator as well when the target\'s refund raises after it lands', function()
        local _, _, creator, target = boughtAndStopping(function(real, ...)
            real(...)
            error('AddMoney hook raised', 0)
        end)
        eq(target, 10000, 'the target has their premium back')
        eq(creator, 5000, 'and the creator only their escrow, not the premium a second time')
    end)

    it('offers nobody else a refund only part of which landed, and says what did', function()
        local rows, _, creator, target = boughtAndStopping(function(real, account, _, reason)
            real(account, 4000, reason)
            error('AddMoney hook raised', 0)
        end)
        eq(target, 4000, 'part of it reached the target')
        eq(creator, 5000, 'and none of it went to the creator as well')
        local row
        for _, r in ipairs(rows) do
            if r.action == 'bailout_refund_stranded' then row = r end
        end
        truthy(row, 'staff are told')
        eq(row.detail.raised_for, 'TARGET01')
        eq(row.detail.arrived, 4000, 'with the part that arrived, so they hand over only the rest')
    end)
end)

describe('taking a stake on a contract that closes during the acceptance', function()
    it('never leaves the stake behind when the creator cancels mid-accept', function()
        local broken, depth = everyInterleaving(function()
            local s = newStack()
            local f = fixture(s)
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.EXCLUSIVE,
                reward = { baseline = { cash = 5000 } }, penaltyAmount = 2000,
            })
            return s, f, c
        end, function(s, f, c)
            s.contracts.accept(f.hitman, c.id, false)
        end, function(s, f, c)
            s.contracts.cancel(f.creator, c.id)
        end)
        truthy(depth > 5, 'the acceptance has to have points to race')
        eq(#broken, 0, 'the stake was stranded on a closed contract:\n  '
            .. table.concat(broken, '\n  '))
    end)

    it('gives the stake back and says it closed, rather than "accepted"', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 5000 } }, penaltyAmount = 2000,
        })
        local before = worth(3)
        local ok, err
        -- Store call 3 is before the hitman's row exists, so a staff void
        -- goes through (the client's own cancel waits on the key the
        -- acceptance holds); the acceptance is then reserving a closed one.
        interleaveAt(s, 3, function() ok, err = s.contracts.accept(f.hitman, c.id, false) end,
            function() s.admin.void(0, c.id, 'raced') end)
        eq(s.storage.readContract(c.id).state, CH.STATE.VOIDED)
        falsy(ok, 'accepting a contract that closed underneath is not an acceptance')
        eq(err, CH.ERR.ALREADY_SETTLED)
        eq(worth(3), before, 'and the stake is back where it came from')
        local hitman = s.storage.readHitman(c.id, 'HITMAN01')
        truthy(not hitman or hitman.state ~= 'active', 'nobody is left holding it')
    end)

    it('never leaves a second hitman\'s stake behind when the first collects the last payout', function()
        local broken = everyInterleaving(function()
            local s = newStack()
            local f = fixture(s)
            Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
                cash = 5000, bank = 5000, firstname = 'Sol', lastname = 'Vane' })
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                reward = { baseline = { cash = 5000 } }, penaltyAmount = 2000,
            })
            truthy(s.contracts.accept(f.hitman, c.id, false))
            return s, f, c
        end, function(s, _, c)
            s.contracts.accept(s.identity.resolve(4), c.id, false)
        end, function(s, _, c)
            s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        end)
        eq(#broken, 0, 'a stake was stranded on a completed contract:\n  '
            .. table.concat(broken, '\n  '))
    end)
end)

describe('adding to a reward on a contract that closes during the add', function()
    local function build()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } }, bailoutAmount = 6000,
        })
        return s, f, c
    end

    it('never strands the top-up when the target buys out mid-add', function()
        local broken = everyInterleaving(build, function(s, f, c)
            s.amendments.addEscrow(f.creator, c.id, { baseline = { cash = 3000 } })
        end, function(s, f, c)
            s.bailout.buy(f.target, c.id)
        end)
        eq(#broken, 0, 'the creator\'s top-up was stranded:\n  ' .. table.concat(broken, '\n  '))
    end)

    it('never strands a raised bonus when the target buys out mid-raise', function()
        local broken = everyInterleaving(build, function(s, f, c)
            s.amendments.improve(f.creator, c.id, CH.AMENDMENT.RAISE_BONUS, { percent = 50 })
        end, function(s, f, c)
            s.bailout.buy(f.target, c.id)
        end)
        eq(#broken, 0, 'the creator\'s bonus top-up was stranded:\n  '
            .. table.concat(broken, '\n  '))
    end)
end)

describe('giving the last collection back on the backend that ships by default', function()
    it('stops selling it on mysql, exactly as on memory', function()
        for _, which in ipairs({ 'memory', 'mysql' }) do
            local s = which == 'mysql' and newMysqlStack() or newStack()
            local f = fixture(s)
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                reward = { slots = { { baseline = { cash = 1000 } },
                                     { baseline = { cash = 2000 } } } },
            })
            truthy(c, which)
            truthy(s.contracts.accept(f.hitman, c.id, false), which)
            local proposal = s.amendments.propose(f.creator, c.id,
                CH.AMENDMENT.REDUCE_REWARD, { slot = 2 })
            truthy(proposal, which)
            local _, _, outcome = s.amendments.respond(f.hitman, proposal.id, true)
            eq(outcome, 'applied', which)

            eq(s.storage.readContract(c.id).payout_slots, 1,
                which .. ': the count comes down with the escrow')

            local _, _, result = s.contracts.claimSlot(c.id, 'HITMAN01',
                CH.FULFILMENT.ELIMINATION)
            truthy(result and result.exhausted,
                which .. ': the one collection left is the last one, so the contract '
                .. 'completes rather than asking for a kill that pays nothing')
        end
    end)
end)

describe('lowering the stake while a hitman is offline', function()
    local function lowered()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 5000 } }, penaltyAmount = 2000,
        })
        truthy(s.contracts.accept(f.hitman, c.id, false))

        local saved = Env.players[3]
        Env.removePlayer(3)
        truthy(s.amendments.improve(f.creator, c.id, CH.AMENDMENT.LOWER_PENALTY,
            { amount = 500 }))
        Env.addPlayer({ source = 3, citizenid = 'HITMAN01', license = 'license:ccc',
            cash = saved.PlayerData.money.cash, bank = saved.PlayerData.money.bank,
            firstname = 'Rook', lastname = 'Ash' })
        return s, f, c
    end

    it('forfeits only the stake the contract now names', function()
        local s, _, c = lowered()
        local before = worth(1)
        truthy(s.contracts.abandon(s.identity.resolve(3), c.id))
        eq(worth(1) - before, 500,
            'the creator lowered the penalty to 500 and was paid 2000 when they walked away')
    end)

    it('hands the difference to the hitman when they are back', function()
        local s = lowered()
        local before = worth(3)
        eq(s.escrow.retryPending('HITMAN01'), 1)
        eq(worth(3) - before, 1500, 'the difference every staker of the higher figure is owed')
    end)
end)

describe('the absolute lifetime', function()
    it('returns the stake of a hitman whose target was out of the city', function()
        local main, m = boot()
        local f = fixture(m)
        local c = m.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 5000 } }, penaltyAmount = 2000,
        })
        truthy(m.contracts.accept(f.hitman, c.id, false))
        main.expire()

        Env.advance(3600)
        Env.removePlayer(2)
        main.markPresenceChanged()
        main.expire()

        local before = worth(3)
        for _ = 1, 48 do
            Env.advance(3600)
            main.markPresenceChanged()
            main.expire()
        end
        local row = m.storage.readContract(c.id)
        eq(row.state, CH.STATE.EXPIRED)
        eq(row.resolution, 'lifetime_exceeded')
        eq(worth(3) - before, 2000,
            'the deadline was paused the whole time: this hitman did not fail, the clock did')
    end)

    it('still forfeits the stake of a hitman whose own deadline had run out', function()
        local main, m = boot()
        local f = fixture(m)
        local c = m.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 5000 } }, penaltyAmount = 2000,
        })
        truthy(m.contracts.accept(f.hitman, c.id, false))
        local row = m.storage.readContract(c.id)
        row.deadline_at = Env.time + 60
        row.expires_at = Env.time + 60
        m.storage.writeContract(row)

        local before = worth(1)
        Env.advance(61)
        main.markPresenceChanged()
        main.expire()
        eq(m.storage.readContract(c.id).state, CH.STATE.EXPIRED)
        eq(worth(1) - before, 7000, 'the escrow back and the stake of a hitman who ran out of time')
    end)
end)

describe('a payout that would not fit, for a player who is still online', function()
    it('arrives once they make room, without a relog', function()
        local main, m = boot()
        local f = fixture(m)
        local c = m.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 1000, items = { { name = 'lockpick', count = 5 } } } },
        })
        truthy(m.contracts.accept(f.hitman, c.id, false))

        Env.players[3]._inventoryFull = true
        local ok, _, result = m.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        truthy(ok)
        eq(result.pending, 1, 'the lockpicks did not fit')

        -- The app says "make room and it will be handed over".
        Env.players[3]._inventoryFull = false
        for _ = 1, 6 do
            Env.advance(10)
            main.tick()
        end
        eq(carried(3, 'lockpick'), 5, 'and it is')
        eq(#m.storage.readPending('HITMAN01'), 0, 'and nothing is left queued')
    end)
end)

--- qbx_core changes a balance in memory and writes it every five minutes,
--- while escrow is written at once. A hard crash in between came back with
--- the escrow on disk and the balance it was taken from untouched (refunded
--- later, paid twice), or a payout settled here and gone from the balance.
describe('a balance this resource moves', function()
    local function lastSave(src)
        local found
        for _, save in ipairs(Natives.calls.saves or {}) do
            if save.source == src then found = save end
        end
        return found
    end

    it('is written to the database as it moves, both ways', function()
        local _, m = boot()
        local f = fixture(m)
        Natives.calls.saves = {}
        local c = m.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c)
        local creator = lastSave(1)
        truthy(creator, 'the client\'s row is saved when the escrow is taken')
        eq(creator.cash, Env.players[1].PlayerData.money.cash, 'with the balance after it')

        truthy(m.contracts.accept(f.hitman, c.id, false))
        truthy(m.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        local hitman = lastSave(3)
        truthy(hitman, 'and the hitman\'s when they are paid')
        eq(hitman.cash, Env.players[3].PlayerData.money.cash, 'with the payout in it')
    end)

    it('is still paid when the save throws', function()
        local _, m = boot()
        local f = fixture(m)
        Natives.saveThrows = true
        local ok, c = pcall(m.contracts.create, f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 5000 } },
        })
        Natives.saveThrows = nil
        truthy(ok and c, 'a save that failed is not a payment that failed')
        eq(Env.players[1].PlayerData.money.cash, 100000 - 5000, 'and the escrow was taken once')
    end)
end)

--- The hitman put the target down and is on the way to the body with the
--- camera, or has them in hand and is counting: what closes the contract
--- underneath them now waits for it.
local PHOTO = 'https://cdn.fivemanage.com/proof.png'

--- A real kill of TARGET01 by HITMAN01, reported by the target.
local function kill(m)
    Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
    Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
    Env.players[2]._health = 140
    m.death.recordDamage(3, 2, 123456)
    Env.players[2].PlayerData.metadata.isdead = true
    eq(m.death.onVictimReport(2, 3), 1, 'the kill is the hitman\'s')
end

describe('a buyout whose delay runs out while a hitman is finishing', function()
    local function bought(opts)
        local main, m = boot()
        m.photo.loadAllowedHosts()
        local f = fixture(m)
        Env.players[2].PlayerData.money.bank = 50000
        local c = m.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 5000 }, bonus = { cash = 2500 } },
            bailoutAmount = 15000,
        })
        truthy(m.contracts.accept(f.hitman, c.id, false))
        local before = { creator = worth(1), target = worth(2), hitman = worth(3) }
        truthy(m.bailout.buy(f.target, c.id))
        eq(before.target - worth(2), 15000, 'the premium is taken now')
        if opts and opts.handover then
            for _, src in ipairs({ 1, 2, 3 }) do
                Env.players[src]._coords = { x = 300.0, y = 300.0, z = 30.0 }
            end
            Env.players[2].PlayerData.metadata.ishandcuffed = true
        end
        return main, m, f, c, before
    end

    it('waits for the photo of a kill made as it ran out, and gives the premium back', function()
        local main, m, f, c, before = bought()
        Env.advance(Config.Bailout.ProcessingDelaySeconds - 5)
        kill(m)
        local token = m.photo.issue(f.hitman, c.id)
        truthy(token)

        Env.advance(10)
        main.tick()
        local row = m.storage.readContract(c.id)
        eq(row.state, CH.STATE.ACCEPTED, 'not settled over a kill waiting for its photo')
        eq(row.bailout_attempts or 0, 0, 'and waiting on it is not a failed attempt')

        local ok, err = m.photo.submit(f.hitman, token, PHOTO)
        truthy(ok, 'the hitman finished it first, as they were told they could: ' .. tostring(err))
        m.bailout.processQueue()

        eq(m.storage.readContract(c.id).state, CH.STATE.COMPLETED)
        eq(worth(3) - before.hitman, 5000, 'the hitman is paid the baseline')
        eq(worth(2) - before.target, 0, 'the target lost the race and has the premium back')
        eq(worth(1) - before.creator, 2500, 'the client the bonus a kill does not pay, and no premium')
        falsy(m.storage.readContract(c.id).bailout_queued_at, 'nothing is left queued')
    end)

    it('waits for a handover armed as it ran out', function()
        local main, m, f, c, before = bought({ handover = true })
        Env.advance(Config.Bailout.ProcessingDelaySeconds - 10)
        truthy(m.kidnap.arm(c.id, 'HITMAN01'))
        Env.advance(12)
        main.tick()
        eq(m.storage.readContract(c.id).state, CH.STATE.ACCEPTED,
            'not closed under a handover counting down')

        local paid
        for _ = 1, Config.Kidnap.CountdownSeconds do
            local done = m.kidnap.tick(Config.Kidnap.TickMs)
            if done[1] then paid = done[1] end
        end
        truthy(paid and paid.result, 'the handover finished and paid')
        m.bailout.processQueue()
        eq(worth(3) - before.hitman, 7500, 'baseline and bonus')
        eq(worth(2) - before.target, 0, 'the premium back')
    end)

    --- The delay ran out, and the tick that settles it comes round seconds
    --- later. A kill made in that gap was held open for its photo and paid,
    --- and the target, who had bought out in time, was refunded.
    it('does not wait for a kill made after the delay ran out', function()
        local main, m, f, c, before = bought()
        Env.advance(Config.Bailout.ProcessingDelaySeconds + 3)
        kill(m)
        local token = m.photo.issue(f.hitman, c.id)
        truthy(token, 'the kill itself is real')
        m.bailout.processQueue()
        eq(m.storage.readContract(c.id).state, CH.STATE.BAILED_OUT, 'bought out, as it was due')

        local ok = m.photo.submit(f.hitman, token, PHOTO)
        falsy(ok, 'a kill after the buyout went through is not paid')
        m.bailout.processQueue()
        eq(worth(3) - before.hitman, 0, 'the hitman was too late')
        eq(worth(2) - before.target, -15000, 'the target keeps the buyout they paid for')
        eq(worth(1) - before.creator, 7500 + 15000, 'escrow and premium to the client')
    end)

    it('does not wait for a handover armed after the delay ran out', function()
        local main, m, f, c, before = bought({ handover = true })
        Env.advance(Config.Bailout.ProcessingDelaySeconds + 3)
        truthy(m.kidnap.arm(c.id, 'HITMAN01'), 'armed in the gap before the tick')
        m.bailout.processQueue()
        eq(m.storage.readContract(c.id).state, CH.STATE.BAILED_OUT,
            'not held open for a countdown begun too late')
        for _ = 1, Config.Kidnap.CountdownSeconds do m.kidnap.tick(Config.Kidnap.TickMs) end
        eq(worth(3) - before.hitman, 0, 'and it pays nothing')
        eq(worth(1) - before.creator, 7500 + 15000)
    end)

    it('settles as it always did with nothing in progress', function()
        local main, m, f, c, before = bought()
        Env.advance(Config.Bailout.ProcessingDelaySeconds + 1)
        main.tick()
        eq(m.storage.readContract(c.id).state, CH.STATE.BAILED_OUT)
        eq(worth(1) - before.creator, 7500 + 15000, 'escrow and premium to the client')
    end)

    it('does not wait for ever', function()
        local main, m, f, c, before = bought()
        local real = m.bailout.finishing
        m.bailout.finishing = function() return true end
        Env.advance(Config.Bailout.ProcessingDelaySeconds + 1)
        m.bailout.processQueue()
        eq(m.storage.readContract(c.id).state, CH.STATE.ACCEPTED)
        Env.advance(2 * Config.Completion.PhotoTokenLifetimeSeconds)
        m.bailout.processQueue()
        m.bailout.finishing = real
        eq(m.storage.readContract(c.id).state, CH.STATE.BAILED_OUT,
            'the target\'s money is already gone, and the wait is as long as a kill can wait')
        eq(worth(1) - before.creator, 7500 + 15000)
    end)
end)

describe('a deadline that runs out while a hitman is finishing', function()
    local function staked()
        local main, m = boot()
        m.photo.loadAllowedHosts()
        local f = fixture(m)
        local c = m.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 5000 } }, penaltyAmount = 2000,
        })
        truthy(m.contracts.accept(f.hitman, c.id, false))
        local row = m.storage.readContract(c.id)
        row.deadline_at = Env.time + 60
        m.storage.writeContract(row)
        main.markPresenceChanged()
        main.expire()
        return main, m, f, c
    end

    it('waits for the photo of a kill made in time, and returns the stake', function()
        local main, m, f, c = staked()
        local before = { creator = worth(1), hitman = worth(3) }
        Env.advance(55)
        kill(m)
        local token = m.photo.issue(f.hitman, c.id)
        Env.advance(10)
        main.markPresenceChanged()
        main.expire()
        eq(m.storage.readContract(c.id).state, CH.STATE.ACCEPTED,
            'not expired under a kill waiting for its photo')

        local ok, err = m.photo.submit(f.hitman, token, PHOTO)
        truthy(ok, tostring(err))
        eq(worth(3) - before.hitman, 5000 + 2000, 'the baseline, and the stake back')
        eq(worth(1) - before.creator, 0, 'the client keeps nothing of a hitman who did it in time')
    end)

    --- The pass runs on the maintenance tick, seconds after the deadline.
    --- A kill made in that gap was held open for its photo, and the stake a
    --- hitman who ran out of time forfeits went back to them.
    it('does not wait for a kill made after the deadline', function()
        local main, m, f, c = staked()
        local before = { creator = worth(1), hitman = worth(3) }
        Env.advance(65)
        kill(m)
        local token = m.photo.issue(f.hitman, c.id)
        truthy(token, 'the kill itself is real')
        Env.advance(4)
        main.markPresenceChanged()
        main.expire()
        eq(m.storage.readContract(c.id).state, CH.STATE.EXPIRED, 'expired, as it was due')

        local ok = m.photo.submit(f.hitman, token, PHOTO)
        falsy(ok, 'a kill after the deadline is not paid')
        eq(worth(3) - before.hitman, 0, 'the hitman ran out of time')
        eq(worth(1) - before.creator, 5000 + 2000, 'the escrow back and the stake forfeited')
    end)

    it('does not wait for a handover armed after the deadline', function()
        local main, m, f, c = staked()
        for _, src in ipairs({ 1, 2, 3 }) do
            Env.players[src]._coords = { x = 300.0, y = 300.0, z = 30.0 }
        end
        Env.players[2].PlayerData.metadata.ishandcuffed = true
        Env.advance(65)
        local armed, why = m.kidnap.arm(c.id, 'HITMAN01')
        falsy(armed, 'refused once the deadline has gone')
        eq(why, CH.ERR.ALREADY_SETTLED)
    end)

    it('comes back for it on the very next pass', function()
        local main, m, f, c = staked()
        Env.advance(55)
        kill(m)
        Env.advance(10)
        main.expire()
        -- The kill lapses with no photo: the next pass expires it.
        m.death.clearPending(c.id, 'HITMAN01')
        Env.advance(10)
        main.expire()
        eq(m.storage.readContract(c.id).state, CH.STATE.EXPIRED,
            'a waiting pass that skipped to the far deadline would leave it open')
    end)

    it('does not wait for ever, and then forfeits as before', function()
        local main, m, f, c = staked()
        local before = worth(1)
        local real = m.bailout.finishing
        m.bailout.finishing = function() return true end
        Env.advance(61)
        main.markPresenceChanged()
        main.expire()
        eq(m.storage.readContract(c.id).state, CH.STATE.ACCEPTED)
        Env.advance(2 * Config.Completion.PhotoTokenLifetimeSeconds)
        main.markPresenceChanged()
        main.expire()
        m.bailout.finishing = real
        eq(m.storage.readContract(c.id).state, CH.STATE.EXPIRED)
        eq(worth(1) - before, 7000, 'the escrow back and the stake of a hitman who ran out of time')
    end)

    it('never holds off the lifetime', function()
        local main, m, f, c = staked()
        local row = m.storage.readContract(c.id)
        row.expires_at = Env.time + 30
        m.storage.writeContract(row)
        Env.advance(25)
        kill(m)
        Env.advance(10)
        main.markPresenceChanged()
        main.expire()
        eq(m.storage.readContract(c.id).state, CH.STATE.EXPIRED, 'the ceiling holds whatever anyone is doing')
    end)
end)

--- The same deadline under the rule this resource ships (Completion.Fulfilment
--- = 'alive', tests/harness/shipped.lua), where no kill can complete a
--- contract: the only thing that holds an expiry off is a handover armed
--- before the deadline (Bailout.finishing, through Kidnap.armedAt).
describe('a deadline that runs out during a live handover, as this resource ships', function()
    local Shipped = require('tests.harness.shipped')

    local function handingOver()
        local main, m = boot(Shipped.apply)
        local f = fixture(m)
        local c = m.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 5000 } }, penaltyAmount = 2000,
        })
        truthy(c, 'placed')
        eq(c.fulfilment_rule, CH.FULFILMENT_RULE.ALIVE)
        truthy(m.contracts.accept(f.hitman, c.id, false))
        local row = m.storage.readContract(c.id)
        row.deadline_at = Env.time + 60
        m.storage.writeContract(row)
        main.markPresenceChanged()
        main.expire()
        for _, src in ipairs({ 1, 2, 3 }) do
            Env.players[src]._coords = { x = 300.0, y = 300.0, z = 30.0 }
        end
        Env.players[2].PlayerData.metadata.ishandcuffed = true
        -- Armed ten seconds before the deadline; the pass after it runs.
        Env.advance(50)
        truthy(m.kidnap.arm(c.id, 'HITMAN01'), 'armed in time')
        Env.advance(11)
        main.markPresenceChanged()
        main.expire()
        eq(m.storage.readContract(c.id).state, CH.STATE.ACCEPTED,
            'not expired under a handover armed before the deadline')
        return main, m, f, c
    end

    it('pays the handover armed in time, with the stake back', function()
        local before = {}
        local _, m, _, c = handingOver()
        before.creator, before.hitman = worth(1), worth(3)
        for _ = 1, math.floor(Config.Kidnap.CountdownSeconds * 1000 / Config.Kidnap.TickMs) + 1 do
            m.kidnap.tick(Config.Kidnap.TickMs)
        end
        eq(m.storage.readContract(c.id).state, CH.STATE.COMPLETED)
        eq(worth(3) - before.hitman, 5000 + 2000, 'the reward, and the stake back')
        eq(worth(1) - before.creator, 0, 'the client keeps nothing of a hitman who did it in time')
    end)

    it('expires on the next pass once that countdown breaks, and forfeits the stake', function()
        local before = {}
        local main, m, _, c = handingOver()
        before.creator, before.hitman = worth(1), worth(3)
        -- The person who placed it walks away: the handover fails.
        Env.players[1]._coords = { x = 3000.0, y = 3000.0, z = 30.0 }
        for _ = 1, 10 do m.kidnap.tick(Config.Kidnap.MaxTotalGraceMs) end
        eq(m.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'the failed handover closes nothing')
        Env.advance(10)
        main.expire()
        eq(m.storage.readContract(c.id).state, CH.STATE.EXPIRED, 'the next pass expires it')
        eq(worth(3) - before.hitman, 0, 'the hitman ran out of time')
        eq(worth(1) - before.creator, 5000 + 2000, 'the escrow back and the stake forfeited')
    end)
end)
