--- Money that went to nobody, or to the wrong person, by paths that each
--- looked right on their own.
---
--- Every test here failed before its fix, with the figure it names.

local Exec = require('crimson-hitman.tests.harness.mysql_exec')

local function boot()
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
                         audit = stack.audit, notify = stack.notify, kidnap = stack.kidnap })
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
