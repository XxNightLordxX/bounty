--- Persistence, restart and recovery, on the backends that persist.
---
--- Every other suite runs a process that never stops. These boot the real
--- main.lua on json and on the executing mysql simulator, kill it at a chosen
--- point — no onResourceStop, no close(), no tick flush, which is what a
--- crash or a txAdmin restart is — and boot it again on the same disk.

local Exec = require('crimson-hitman.tests.harness.mysql_exec')

local function money(src)
    local m = Env.players[src].PlayerData.money
    return m.cash + m.bank
end

local function forgetServerModules()
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
            package.loaded[name] = nil
        end
    end
end

--- A fresh server on an empty store.
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
    return main, main.start()
end

--- The same server after the process died: module state gone, the disk and
--- the players (who reconnect) kept.
---
--- The dead process's store is marked as no longer the resource's output.
--- Its in-memory tables hold the state at the moment it died, which is
--- mid-operation by construction, and the invariant monitor audits every
--- store it has ever seen at the end of each test.
---@param old table the stack of the process that died
local function restart(mode, old)
    if old and old.storage then rawset(old.storage, '__rawFixture', true) end
    forgetServerModules()
    Env.events, Env.clientEvents, Env.notifications = {}, {}, {}
    Env.handlers, Env.threads, Env.timers, Env.commands = {}, {}, {}, {}
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Config.Database.Mode = mode
    local main = require('server.main')
    return main, main.start()
end

describe('giving the last collection back, on every backend', function()
    --- The count coming down was invisible to mysql: payout_slots was listed
    --- as immutable in the upsert, from before a collection could be given
    --- back. On the backend most servers run, the emptied collection stayed
    --- on sale and the contract never closed on its last real payout.
    local function givenBack(mode, penalty)
        local main, s = boot(mode)
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        Env.players[3].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            penaltyAmount = penalty,
            reward = { slots = { { baseline = { cash = 1000 } },
                                 { baseline = { cash = 40000 } } } },
        })
        truthy(c, 'a contract with two collections')
        truthy(s.contracts.accept(f.hitman, c.id), 'a hitman')
        local p = s.amendments.propose(f.creator, c.id, CH.AMENDMENT.REDUCE_REWARD, { slot = 2 })
        truthy(p, 'propose giving collection 2 back')
        truthy(s.amendments.respond(f.hitman, p.id, true), 'agreed')
        return main, s, f, c
    end

    for _, mode in ipairs({ 'memory', 'json', 'mysql' }) do
        it(mode .. ': one collection fewer, and the last real one closes it', function()
            local _, s, f, c = givenBack(mode)
            eq(s.storage.readContract(c.id).payout_slots, 1,
                mode .. ': the given-back collection is still on sale')
            truthy(s.contracts.claimSlot(c.id, f.hitman.cid, CH.FULFILMENT.ELIMINATION, {}))
            eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED,
                mode .. ': the only collection left was paid and the contract stayed open')
        end)
    end

    it('mysql: the hitman who collected it all keeps their stake', function()
        local main, s, f, c = givenBack('mysql', 500)
        local before = money(3)
        truthy(s.contracts.claimSlot(c.id, f.hitman.cid, CH.FULFILMENT.ELIMINATION, {}))
        Env.advance(4 * 3600)
        main.tick()
        eq(money(3) - before, 1000 + 500,
            'left open on an empty collection, the contract ran out and the stake of '
            .. 'the hitman who had collected everything it paid went to the creator')
    end)
end)

describe('a claim landing while another handler holds a copy of the contract', function()
    --- On mysql every read is an await, and eight handlers read the row, work,
    --- and write the whole row back. next_slot was in that write, so a claim
    --- landing in between was undone: the collection just paid went back on
    --- sale and the next hitman to kill the target for it was paid nothing.
    for _, mode in ipairs({ 'memory', 'json', 'mysql' }) do
        it(mode .. ': the collection stays claimed', function()
            local _, s = boot(mode)
            local f = fixture(s)
            Env.players[1].PlayerData.money.bank = 400000
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                penaltyAmount = 2000,
                reward = { slots = { { baseline = { cash = 10000 } },
                                     { baseline = { cash = 20000 } } } },
            })
            truthy(c)
            truthy(s.contracts.accept(f.hitman, c.id))
            Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
                cash = 5000, bank = 5000 })
            truthy(s.contracts.accept(s.identity.resolve(4), c.id))

            -- The creator lowers the stake. It reads the contract, then
            -- adjusts each hitman's stake line — an await apiece — and then
            -- writes the contract back. HITMAN01's kill is claimed in the
            -- first of those awaits.
            --
            -- (This used to raise the bonus instead. A top-up landing on a
            -- collection being paid is now refused and handed back, so that
            -- path never reaches the write this is about.)
            local realSet = s.storage.setEscrowAmount
            local claimed = false
            s.storage.setEscrowAmount = function(...)
                if not claimed then
                    claimed = true
                    s.storage.setEscrowAmount = realSet
                    truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION, {}))
                end
                return realSet(...)
            end
            truthy(s.amendments.improve(f.creator, c.id, CH.AMENDMENT.LOWER_PENALTY, { amount = 1000 }))
            s.storage.setEscrowAmount = realSet
            truthy(claimed, 'the interleaving has to happen, or this measures nothing')

            local slot = s.storage.readContract(c.id).next_slot
            eq(slot, 2, mode .. ': the collection HITMAN01 was paid for is back on sale')

            local before = money(4)
            truthy(s.contracts.claimSlot(c.id, 'HITMAN02', CH.FULFILMENT.ELIMINATION, {}))
            -- The second collection, and the 1,000 stake that comes back
            -- because this claim finishes the contract.
            eq(money(4) - before, 20000 + 1000, mode .. ': HITMAN02 was paid out of an empty slot')
        end)
    end
end)

describe('a crash right after an acceptance (json)', function()
    --- The stake is flushed at once; the hitman row rode the debounce. A
    --- process that died inside the flush interval came back with the stake
    --- on disk and no hitman it belonged to: nothing returns a stake without
    --- its row, and the exclusive contract refused everybody as locked.
    it('keeps the hitman row the stake hangs on', function()
        local _, s = boot('json')
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 10000 } }, penaltyAmount = 2000,
        })
        truthy(c)
        truthy(s.contracts.accept(f.hitman, c.id))

        local _, s2 = restart('json', s)
        local hitmen = s2.storage.readHitmen(c.id)
        eq(#hitmen, 1, 'the stake survived and the hitman who put it up did not')
        eq(hitmen[1].hitman_cid, 'HITMAN01')

        -- And walking away hands the stake over as it should.
        local creatorBefore = money(1)
        truthy(s2.contracts.abandon(s2.identity.resolve(3), c.id))
        eq(money(1) - creatorBefore, 2000, 'the forfeited stake reached the creator')
    end)
end)

describe('a crash in the middle of an ending', function()
    --- resolve() moves the state first and the money after. A crash between
    --- the two left the creator's escrow on a closed contract that nothing
    --- ever released again, and that no staff tool reported.
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': hands back what was never touched, and reports the rest', function()
            local _, s = boot(mode)
            local f = fixture(s)
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x',
                reward = { baseline = { cash = 10000, bank = 5000 } },
            })
            truthy(c)
            local before = money(1)

            -- The process dies handing over the first line.
            s.escrow.deliver = function() error('process killed') end
            falsy(pcall(s.contracts.cancel, f.creator, c.id))

            local _, s2 = restart(mode, s)
            eq(s2.storage.readContract(c.id).state, CH.STATE.CANCELLED)
            eq(money(1) - before, 5000,
                'the line nobody had started to pay is back with the creator')

            -- The one caught mid-release may already have been paid: it is
            -- left for staff, and staff are told.
            local stuck = s2.admin.interrupted()
            eq(#stuck, 1, 'the interrupted line is reported')
            truthy(s2.admin.settleLine(0, stuck[1].line, 'pay'))
            eq(money(1) - before, 15000, 'and settling it pays the creator')
        end)
    end

    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': a stake left on a closed contract goes back to its hitman', function()
            local _, s = boot(mode)
            local f = fixture(s)
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                reward = { baseline = { cash = 10000 } }, penaltyAmount = 2000,
            })
            truthy(c)
            truthy(s.contracts.accept(f.hitman, c.id))
            local before = money(3)

            -- Staff void it; the process dies before any line moves.
            s.escrow.release = function() error('process killed') end
            falsy(pcall(s.admin.void, 0, c.id, 'x'))

            local _, s2 = restart(mode, s)
            eq(s2.storage.readContract(c.id).state, CH.STATE.VOIDED)
            eq(money(3) - before, 2000, 'the stake went back to the hitman who put it up')
        end)
    end
end)

describe('a crash while a contract runs out', function()
    --- Recovery forfeited every stake on an EXPIRED contract, where the
    --- ending itself forfeits only when the deadline ran out: reaching the
    --- lifetime while the target was away gives the stake back.
    local function held(mode)
        local main, s = boot(mode)
        Config.Limits.ExclusiveIdleReleaseSeconds = 0
        Config.Limits.ExclusiveAttemptWindowSeconds = 0
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 10000 } }, penaltyAmount = 2000,
        })
        truthy(c)
        truthy(s.contracts.accept(f.hitman, c.id))
        main.tick()
        return main, s, f, c
    end

    local function dies(main, s)
        s.escrow.release = function() error('process killed') end
        falsy(pcall(main.expire), 'the ending was interrupted')
    end

    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': the lifetime, with the target away, still gives the stake back', function()
            local main, s, _, c = held(mode)
            local before = money(3)
            local target = Env.players[2]
            Env.removePlayer(2)
            main.markPresenceChanged()
            main.expire()
            truthy(s.storage.readContract(c.id).paused_since, 'the deadline is paused')

            Env.advance(Config.Limits.ContractLifetimeSeconds + 360)
            main.markPresenceChanged()
            dies(main, s)
            Env.players[2] = target
            Env.byCitizen['TARGET01'] = 2

            local _, s2 = restart(mode, s)
            eq(s2.storage.readContract(c.id).state, CH.STATE.EXPIRED)
            eq(money(3) - before, 2000,
                'a crash handed the creator a stake the same ending gives back')
        end)

        it(mode .. ': the deadline running out still forfeits it', function()
            local main, s, _, c = held(mode)
            local before = money(3)
            Env.advance(Config.Limits.DefaultDeadlineSeconds + 360)
            main.markPresenceChanged()
            dies(main, s)

            local _, s2 = restart(mode, s)
            eq(s2.storage.readContract(c.id).state, CH.STATE.EXPIRED)
            eq(money(3) - before, 0, 'a hitman who let the clock run out keeps no stake')
        end)
    end
end)

describe('a crash between paying the last collection and closing', function()
    --- Recovery put every COMPLETING contract back to ACCEPTED. One whose
    --- last collection was already paid came back live with nothing left to
    --- claim, then ran out: the hitman who had collected everything lost
    --- their stake to the creator, and the target was credited with
    --- surviving it.
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': the contract is finished, not reopened', function()
            local _, s = boot(mode)
            local f = fixture(s)
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x',
                reward = { baseline = { cash = 10000 } }, penaltyAmount = 2000,
            })
            truthy(c)
            truthy(s.contracts.accept(f.hitman, c.id))
            local before = money(3)

            s.progression.onCompleted = function() error('process killed') end
            falsy(pcall(s.contracts.claimSlot, c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION, {}))
            eq(money(3) - before, 10000, 'the collection was paid before the crash')

            local main2, s2 = restart(mode, s)
            eq(s2.storage.readContract(c.id).state, CH.STATE.COMPLETED,
                mode .. ': a paid-out contract came back as live')
            eq(money(3) - before, 12000, 'and the stake came back with it')

            Env.advance(4 * 3600)
            main2.tick()
            eq(money(3) - before, 12000, 'nothing forfeits it later')
            eq(s2.storage.readStats('TARGET01').survived or 0, 0,
                'the target did not survive a contract that was completed on them')
        end)
    end
end)

describe('a crash between paying a collection and moving the slot on', function()
    --- Put back to ACCEPTED on the collection it had just paid, the next
    --- hitman to kill the target for it was paid out of an empty slot.
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': the next kill pays the next collection', function()
            local _, s = boot(mode)
            local f = fixture(s)
            Env.players[1].PlayerData.money.bank = 400000
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                reward = { slots = { { baseline = { cash = 10000 } },
                                     { baseline = { cash = 20000 } } } },
            })
            truthy(c)
            truthy(s.contracts.accept(f.hitman, c.id))
            Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd' })
            truthy(s.contracts.accept(s.identity.resolve(4), c.id))

            local before = money(3)
            s.storage.advanceSlot = function() error('process killed') end
            falsy(pcall(s.contracts.claimSlot, c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION, {}))
            eq(money(3) - before, 10000, 'the first collection was paid before the crash')

            local _, s2 = restart(mode, s)
            local row = s2.storage.readContract(c.id)
            eq(row.state, CH.STATE.ACCEPTED)
            eq(row.next_slot, 2, mode .. ': the paid collection is back on sale')

            local second = money(4)
            truthy(s2.contracts.claimSlot(c.id, 'HITMAN02', CH.FULFILMENT.ELIMINATION, {}))
            eq(money(4) - second, 20000, 'HITMAN02 was paid out of an empty slot')
            eq(s2.storage.readContract(c.id).state, CH.STATE.COMPLETED)
        end)
    end
end)

describe('a crash while a queued buyout is being settled', function()
    --- The contract was already BAILED_OUT when the process came back, and
    --- the queue read that as "resolved some other way first": the target
    --- was refunded a buyout they had been given, and the creator never saw
    --- the premium.
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': the creator gets the premium the target paid', function()
            local _, s = boot(mode)
            local f = fixture(s)
            Env.players[2].PlayerData.money.bank = 100000
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x',
                reward = { baseline = { cash = 10000 } }, bailoutAmount = 15000,
            })
            truthy(c)
            truthy(s.contracts.accept(f.hitman, c.id))
            local creatorBefore, targetBefore = money(1), money(2)
            truthy(s.bailout.buy(f.target, c.id), 'queued behind the engaged hitman')

            Env.advance(200)
            s.escrow.deliver = function() error('process killed') end
            falsy(pcall(s.bailout.processQueue))

            local main2, s2 = restart(mode, s)
            for _ = 1, 3 do Env.advance(20) main2.tick() end

            local row = s2.storage.readContract(c.id)
            eq(row.state, CH.STATE.BAILED_OUT)
            falsy(row.bailout_queued_at, 'the queue is cleared')
            eq(money(2) - targetBefore, -15000, 'the target paid for the buyout they got')
            eq(money(1) - creatorBefore, 15000,
                'the creator has the premium (the escrow line caught mid-release is '
                .. 'left for staff)')

            local stuck = s2.admin.interrupted()
            eq(#stuck, 1, 'and staff are told about the line')
            truthy(s2.admin.settleLine(0, stuck[1].line, 'pay'))
            eq(money(1) - creatorBefore, 25000, 'which then reaches the creator')
        end)
    end
end)

describe('a crash after a queued buyout paid the premium', function()
    --- Paid and not yet cleared from the queue looks, on the next tick,
    --- exactly like not paid: bought out, still queued. The premium was
    --- paid again.
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': the creator is paid it once', function()
            local _, s = boot(mode)
            local f = fixture(s)
            Env.players[2].PlayerData.money.bank = 100000
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x',
                reward = { baseline = { cash = 10000 } }, bailoutAmount = 15000,
            })
            truthy(c)
            truthy(s.contracts.accept(f.hitman, c.id))
            local creatorBefore, targetBefore = money(1), money(2)
            truthy(s.bailout.buy(f.target, c.id), 'queued behind the engaged hitman')

            Env.advance(200)
            s.bailout.clearQueue = function() error('process killed') end
            falsy(pcall(s.bailout.processQueue))

            local main2, s2 = restart(mode, s)
            for _ = 1, 3 do Env.advance(20) main2.tick() end

            falsy(s2.storage.readContract(c.id).bailout_queued_at, 'the queue is cleared')
            eq(money(2) - targetBefore, -15000)
            eq(money(1) - creatorBefore, 10000 + 15000,
                'the escrow back and the premium, and the premium once')
        end)
    end
end)

describe('server downtime and the deadline', function()
    --- Every contract's clock pauses while either party is offline. While the
    --- server is down everybody is, but a contract nobody had paused only
    --- started pausing at the first tick after the boot — so the downtime was
    --- charged to the deadline, and one that fell due inside it expired the
    --- moment both parties were back, forfeiting the hitman's stake.
    local function nearlyDue(mode)
        local main, s = boot(mode)
        -- About the deadline, not about an idle hold: this operative never
        -- goes near the target, which after half an hour would put the
        -- exclusive contract back on the board (§14.8) and measure that
        -- instead.
        Config.Limits.ExclusiveIdleReleaseSeconds = 0
        Config.Limits.ExclusiveAttemptWindowSeconds = 0
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 10000 } }, penaltyAmount = 2000,
        })
        truthy(c)
        truthy(s.contracts.accept(f.hitman, c.id))
        main.tick()
        -- Ten minutes left, both parties online the whole time.
        Env.advance(Config.Limits.DefaultDeadlineSeconds - 600)
        main.tick()
        return main, s, f, c
    end

    it('logging off for half an hour pauses it (the rule being held to)', function()
        local main, s, _, c = nearlyDue('json')
        local target = Env.players[2]
        Env.removePlayer(2)
        main.markPresenceChanged()
        main.expire()
        Env.advance(1800)
        Env.players[2] = target
        Env.byCitizen['TARGET01'] = 2
        main.markPresenceChanged()
        main.expire()
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED)
    end)

    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': so does the server being down for half an hour', function()
            local _, s, _, c = nearlyDue(mode)
            local hitmanBefore = money(3)

            local away = {}
            for src, p in pairs(Env.players) do away[src] = p end
            for src in pairs(away) do Env.removePlayer(src) end
            Env.advance(1800)

            local main2, s2 = restart(mode, s)
            main2.tick()
            for src, p in pairs(away) do
                Env.players[src] = p
                Env.byCitizen[p.PlayerData.citizenid] = src
            end
            main2.markPresenceChanged()
            Env.advance(60)
            main2.tick()

            eq(s2.storage.readContract(c.id).state, CH.STATE.ACCEPTED,
                mode .. ': the contract ran out during a restart')
            eq(money(3), hitmanBefore, 'and nothing was forfeited')
        end)
    end
end)

describe('an anonymous client away from the city', function()
    --- The deadline paused for the creator as for the target, so it moved
    --- on by exactly how long an anonymous creator was away, and every
    --- viewer is sent it: when they logged off and when they came back, to
    --- the second, on a contract that exists to keep them unknown (§14.32).
    local function placed(anonymous)
        local main, s = boot('memory')
        -- The deadline, not an idle hold: nobody here goes near the target.
        Config.Limits.ExclusiveIdleReleaseSeconds = 0
        Config.Limits.ExclusiveAttemptWindowSeconds = 0
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', anonymous = anonymous,
            reward = { baseline = { cash = 10000 } }, penaltyAmount = 2000,
        })
        truthy(c)
        truthy(s.contracts.accept(f.hitman, c.id))
        main.tick()
        return main, s, f, c
    end

    local function away(main, src, seconds)
        local p = Env.players[src]
        Env.removePlayer(src)
        main.markPresenceChanged()
        main.expire()
        Env.advance(seconds)
        Env.players[src] = p
        Env.byCitizen[p.PlayerData.citizenid] = src
        main.markPresenceChanged()
        main.expire()
    end

    local function shown(s, c)
        return s.projection.contract(s.storage.readContract(c.id), 'HITMAN01').deadline
    end

    it('does not move the deadline anyone is shown', function()
        local main, s, _, c = placed(true)
        local before = shown(s, c)
        truthy(before)
        away(main, 1, 137 * 60)
        eq(shown(s, c), before, 'the deadline moved by exactly how long the client was gone')
    end)

    it('still moves it for a named client', function()
        local main, s, _, c = placed(false)
        local before = shown(s, c)
        away(main, 1, 1800)
        eq(shown(s, c) - before, 1800)
    end)

    it('still moves it for a target who is away', function()
        local main, s, _, c = placed(true)
        local before = shown(s, c)
        away(main, 2, 1800)
        eq(shown(s, c) - before, 1800, 'the hitman cannot work a target who is not here')
    end)

    it('runs out on time while the client is away', function()
        local main, s, _, c = placed(true)
        Env.removePlayer(1)
        main.markPresenceChanged()
        main.tick()
        Env.advance(Config.Limits.DefaultDeadlineSeconds + 360)
        main.tick()
        eq(s.storage.readContract(c.id).state, CH.STATE.EXPIRED)
    end)
end)

describe('an idle exclusive hold, on the running server', function()
    --- The release is one of the maintenance jobs. Every other test of it
    --- calls the function directly, which says nothing about whether the
    --- server ever does.
    it('is put back on the board by the tick, with the stake returned', function()
        local main, s = boot('memory')
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 10000 } }, penaltyAmount = 2000,
        })
        truthy(c)
        truthy(s.contracts.accept(f.hitman, c.id))
        -- Nowhere near the target, with both parties in the city.
        Env.players[3]._coords = { x = 5000.0, y = 5000.0, z = 0.0 }
        local before = money(3)

        main.tick()
        for _ = 1, math.ceil(Config.Limits.ExclusiveIdleReleaseSeconds / 60) + 1 do
            Env.advance(60)
            main.tick()
        end

        eq(s.storage.readContract(c.id).state, CH.STATE.ACTIVE,
            'the running server never let go of a hold nobody was working')
        eq(s.storage.readHitman(c.id, 'HITMAN01').state, 'released')
        eq(money(3) - before, 2000, 'and the stake came back')
    end)
end)

describe('informant data across a restart', function()
    --- The reveal record is the reroll lock and the purchase count. Held only
    --- in memory, a restart charged the fee again for the same name and
    --- counted the ceiling from zero — on the one purchase in the resource
    --- that is never refunded.
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': buying again inside the lock is not charged again', function()
            local _, s = boot(mode)
            Config.Informant.RequireProximity = false
            local f = fixture(s)
            Env.players[2].PlayerData.money.bank = 200000
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x',
                reward = { baseline = { cash = 10000 } },
            })
            truthy(s.contracts.accept(f.hitman, c.id))

            local before = money(2)
            local ok, _, data = s.informant.buy(f.target, c.id)
            truthy(ok)
            eq(data.name, 'Rook Ash')

            Env.advance(300)
            local _, s2 = restart(mode, s)
            local again, _, data2 = s2.informant.buy(s2.identity.resolve(2), c.id)
            truthy(again)
            eq(data2.name, 'Rook Ash', 'the same name, as inside the lock')
            eq(before - money(2), Config.Informant.Cost, 'one purchase, one fee')
        end)

        it(mode .. ': a repeat inside the lock gives the answer given then, not a fresh look', function()
            -- Kept in memory only, a restart made the free repeat a new
            -- read of whether the hitman was in the city: a presence check
            -- for nothing, as often as the buyer liked.
            local _, s = boot(mode)
            Config.Informant.RequireProximity = false
            local f = fixture(s)
            Env.players[2].PlayerData.money.bank = 200000
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x',
                reward = { baseline = { cash = 10000 } },
            })
            truthy(s.contracts.accept(f.hitman, c.id))
            local ok, _, data = s.informant.buy(f.target, c.id)
            truthy(ok)

            Env.advance(300)
            local _, s2 = restart(mode, s)
            Env.removePlayer(3)
            local again, _, data2 = s2.informant.buy(s2.identity.resolve(2), c.id)
            truthy(again)
            eq(json.encode(data2), json.encode(data),
                'the repeat read the hitman afresh and said whether they were here')
        end)

        it(mode .. ': the answer stays on the buyer\'s card for the lock, and only theirs', function()
            -- It lived only in a notice that cleared itself in four seconds,
            -- on the one purchase that is never refunded.
            local _, s = boot(mode)
            Config.Informant.RequireProximity = false
            local f = fixture(s)
            Env.players[2].PlayerData.money.bank = 200000
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x',
                reward = { baseline = { cash = 10000 } },
            })
            truthy(s.contracts.accept(f.hitman, c.id))
            truthy(s.informant.buy(f.target, c.id))

            local _, s2 = restart(mode, s)
            local row = s2.projection.contract(s2.storage.readContract(c.id), 'TARGET01')
            eq(row.informantAnswer, 'Rook Ash', 'the stored answer, after a restart')
            local theirs = s2.projection.contract(s2.storage.readContract(c.id), 'CREATOR1')
            eq(theirs.informantAnswer, nil, 'the client bought nothing and is told nothing')

            -- Only while a repeat purchase would give it anyway: after the
            -- lock that operative may be long gone, and the card said not.
            Env.advance(Config.Informant.RerollLockMinutes * 60)
            row = s2.projection.contract(s2.storage.readContract(c.id), 'TARGET01')
            eq(row.informantAnswer, nil, 'a stale name stayed on the card after the lock')
        end)

        it(mode .. ': the ceiling still counts what was bought before', function()
            local _, s = boot(mode)
            Config.Informant.RequireProximity = false
            local f = fixture(s)
            Env.players[2].PlayerData.money.bank = 500000
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x',
                reward = { baseline = { cash = 10000 } },
            })
            truthy(s.contracts.accept(f.hitman, c.id))

            local lock = Config.Informant.RerollLockMinutes * 60 + 1
            for _ = 1, Config.Informant.MaxPurchasesPerContract do
                truthy(s.informant.buy(f.target, c.id))
                Env.advance(lock)
            end
            local before = money(2)

            local _, s2 = restart(mode, s)
            local ok, err = s2.informant.buy(s2.identity.resolve(2), c.id)
            falsy(ok, 'a restart reset the ceiling')
            eq(err, CH.ERR.LIMIT_REACHED)
            eq(money(2), before, 'and charged for it')
        end)
    end
end)

describe('memory mode stopping with a buyout waiting out its delay', function()
    --- The premium was taken when the target paid and lived only on the
    --- contract row, so it went with the tables — on the mode whose config
    --- promises to release everything on shutdown rather than lose it.
    it('gives the target their premium back', function()
        local _, s = boot('memory')
        local f = fixture(s)
        Env.players[2].PlayerData.money.bank = 100000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 10000 } }, bailoutAmount = 15000,
        })
        truthy(c)
        truthy(s.contracts.accept(f.hitman, c.id))
        local before = money(2)
        truthy(s.bailout.buy(f.target, c.id))
        truthy(s.storage.readContract(c.id).bailout_queued_at, 'queued, or this measures nothing')

        Env.handlers['onResourceStop'](GetCurrentResourceName())
        eq(money(2), before, 'the premium went with the tables')
    end)
end)

describe('the staff view of a busy contract', function()
    --- mysql returned the OLDEST rows up to the limit, where the other
    --- backends return the newest. A relay conversation writes a row per
    --- message, so on a busy contract the timeline stopped at its
    --- two-hundredth event and /ch-stuck could not see a stuck release.
    for _, mode in ipairs({ 'memory', 'json', 'mysql' }) do
        it(mode .. ': the timeline ends at the latest row', function()
            local _, s = boot(mode)
            for i = 1, 250 do
                s.storage.writeAudit({ ts = 1700000000 + i, kind = 'conduct',
                    action = 'a' .. i, contract_id = 'ct1', detail = {} })
            end
            local rows = s.storage.auditForContract('ct1', 200)
            eq(#rows, 200)
            eq(rows[1].action, 'a51', mode .. ': oldest first')
            eq(rows[#rows].action, 'a250', mode .. ': and the newest is in it')
        end)
    end

    it('mysql: /ch-stuck finds an interrupted release on a busy contract', function()
        local _, s = boot('mysql')
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 10000 } },
        })
        for _ = 1, 250 do s.audit.rejected('noise', 'X', c.id, {}) end
        s.audit.flush()
        s.escrow.deliver = function() error('process killed') end
        falsy(pcall(s.contracts.cancel, f.creator, c.id))

        local _, s2 = restart('mysql', s)
        local stuck = s2.admin.interrupted()
        eq(#stuck, 1, 'the interrupted line is reported')
        truthy(s2.admin.settleLine(0, stuck[1].line, 'return'), 'and staff can settle it')
    end)
end)

describe('audit rows written while a flush waits on the database', function()
    --- The loop's bounds were fixed when it started and head/tail were reset
    --- afterwards, so a row pushed during an await was never written and
    --- never counted as dropped.
    it('are written by the next flush', function()
        local _, s = boot('mysql')
        local real, realBatch = s.storage.writeAudit, s.storage.writeAuditBatch
        local pushed = false
        local function during()
            if not pushed then
                pushed = true
                s.audit.financial('escrow_settle_lost', 'HITMAN01', 'ctX', { line = 'ctX:1' })
            end
        end
        s.storage.writeAudit = function(entry) during() return real(entry) end
        -- mysql writes a flush a batch at a time, and the await is the batch's.
        s.storage.writeAuditBatch = function(entries) during() return realBatch(entries) end
        s.audit.financial('first', 'A', 'ctX', {})
        s.audit.financial('second', 'A', 'ctX', {})
        s.audit.flush()
        s.storage.writeAudit, s.storage.writeAuditBatch = real, realBatch
        truthy(pushed, 'a row was pushed while the flush waited')
        s.audit.flush()

        local seen = {}
        for _, row in ipairs(s.storage.auditForContract('ctX', 100)) do
            seen[row.action] = (seen[row.action] or 0) + 1
        end
        eq(seen.escrow_settle_lost, 1, 'the row pushed during the flush was lost')
        eq(seen.first, 1, 'and nothing was written twice')
    end)

    --- At a stop nothing waits. The stop handler runs as a coroutine, an
    --- await yields it until the database answers, and before it answers
    --- this resource's Lua is torn down. The flush on the way out wrote its
    --- first row, yielded on it, and every queued row behind it was lost on
    --- every restart.
    it('mysql: every row queued at a stop reaches the database, with nothing waiting', function()
        local _, s = boot('mysql')
        for i = 1, 5 do s.audit.financial('stop_row_' .. i, 'A', 'ctStop', {}) end

        -- An await at a stop never comes back.
        local methods = { MySQL.query, MySQL.insert, MySQL.update, MySQL.scalar }
        local saved = {}
        for i, method in ipairs(methods) do
            saved[i] = method.await
            method.await = function() coroutine.yield('waiting on the database') end
        end
        local stop = coroutine.create(function()
            Env.handlers['onResourceStop'](GetCurrentResourceName())
        end)
        local ok, err = coroutine.resume(stop)
        for i, method in ipairs(methods) do method.await = saved[i] end
        truthy(ok, tostring(err))

        local seen = 0
        for _, row in pairs(Exec.tables.crimson_audit or {}) do
            if tostring(row.action):find('^stop_row_') then seen = seen + 1 end
        end
        eq(seen, 5, 'every queued row is in the table, not only the first')
    end)
end)

describe('an acceptance and the anonymity fee, when something goes wrong', function()
    --- The fee was taken first, before the stake, the row and the re-read,
    --- all of which wait on the store: a process that died in any of them
    --- had spent the fee with no row, no line and nothing recovery could
    --- give it back from.
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': a crash part-way through costs no fee', function()
            local _, s = boot(mode)
            local f = fixture(s)
            Config.Anonymity.HitmanFee = 1500
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                reward = { baseline = { cash = 10000 } }, penaltyAmount = 1000,
            })
            truthy(c)
            local before = money(3)
            s.escrow.take = function() error('process killed') end
            falsy(pcall(s.contracts.accept, f.hitman, c.id, true))

            restart(mode, s)
            eq(money(3), before, 'the fee went with the process')
        end)
    end

    --- A refused acceptance left its row withdrawn but marked anonymous, and
    --- the fee is charged once per contract: the next anonymous acceptance
    --- read that row as paid-for anonymity and charged nothing.
    it('charges the fee after an acceptance that was refused', function()
        local _, s = boot('memory')
        local f = fixture(s)
        Config.Anonymity.HitmanFee = 1500
        Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
            cash = 5000, bank = 20000, firstname = 'Sol', lastname = 'Vane' })
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { cash = 1000 } }, { baseline = { cash = 1000 } } } },
            penaltyAmount = 1000,
        })
        truthy(s.contracts.accept(f.hitman, c.id, false))

        -- Another hitman's claim holds the contract while this one writes
        -- its row, and lets go afterwards with a payout left.
        local real = s.storage.addHitman
        s.storage.addHitman = function(row)
            local out = real(row)
            s.contracts.transition(c.id, CH.STATE.ACCEPTED, CH.STATE.COMPLETING, 'claiming_slot')
            return out
        end
        local second = s.identity.resolve(4)
        local before = money(4)
        local ok, err = s.contracts.accept(second, c.id, true)
        s.storage.addHitman = real
        falsy(ok)
        eq(err, CH.ERR.LOCKED)
        eq(money(4), before, 'a refused acceptance costs nothing')
        truthy(s.contracts.transition(c.id, CH.STATE.COMPLETING, CH.STATE.ACCEPTED, 'slot_claimed'))

        truthy(s.contracts.accept(second, c.id, true))
        eq(before - money(4), 1000 + 1500, 'anonymity given without the fee ever being kept')
    end)
end)

describe('an acceptance as the deadline runs out', function()
    --- Accepted anyway, the stake went onto an active row that the expiry
    --- pass found and forfeited to the client, and the hitman was told the
    --- contract had closed.
    local function due()
        local main, s = boot('memory')
        -- A stake this close to the deadline is refused outright now (the
        -- minimum window); off here, to keep measuring what lies under it on
        -- a server that turns it off.
        Config.Penalty.MinWindowMinutes = 0
        Config.Limits.ExclusiveIdleReleaseSeconds = 0
        Config.Limits.ExclusiveAttemptWindowSeconds = 0
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 10000 } }, penaltyAmount = 2000,
        })
        truthy(c)
        main.tick()
        return main, s, f, c
    end

    it('is refused, and charged nothing, once the deadline has passed', function()
        local _, s, f, c = due()
        Env.advance(Config.Limits.DefaultDeadlineSeconds + 305)
        local before = money(3)
        local ok, err = s.contracts.accept(f.hitman, c.id, false)
        falsy(ok, 'accepted a contract whose time was up')
        eq(err, CH.ERR.ALREADY_SETTLED)
        eq(money(3), before)
    end)

    it('does not forfeit a stake whose acceptance the deadline cut short', function()
        -- Exactly on the deadline when the acceptance is checked, one second
        -- past it while its row is written, and the pass runs in that wait:
        -- the row was on the contract "before" the deadline, and its stake
        -- was forfeited to an acceptance the hitman was told had failed.
        local main, s, f, c = due()
        local deadline = s.storage.readContract(c.id).deadline_at
        Env.advance(deadline - os.time())
        local realAdd = s.storage.addHitman
        s.storage.addHitman = function(row)
            local out = realAdd(row)
            Env.advance(1)
            main.markPresenceChanged()
            main.expire()
            return out
        end
        local before = money(3)
        local ok, err = s.contracts.accept(f.hitman, c.id, false)
        s.storage.addHitman = realAdd
        falsy(ok)
        eq(err, CH.ERR.ALREADY_SETTLED)
        eq(s.storage.readContract(c.id).state, CH.STATE.EXPIRED)
        eq(money(3), before, 'refused, and the stake paid to the client all the same')
    end)

    it('returns the stake of a hitman who joined after the deadline, when it then expires', function()
        -- Open when checked, the deadline passing while the row is written,
        -- and the pass only running after the acceptance has gone through:
        -- the hitman is on it, but joined a clock that had already run out.
        local main, s, f, c = due()
        Env.advance(s.storage.readContract(c.id).deadline_at - os.time() - 2)
        local realRead = s.storage.readHitmanById
        local moved = false
        s.storage.readHitmanById = function(id)
            if not moved then moved = true; Env.advance(5) end
            return realRead(id)
        end
        local before = money(3)
        truthy(s.contracts.accept(f.hitman, c.id, false), 'open when it was read again')
        s.storage.readHitmanById = realRead
        eq(before - money(3), 2000, 'staked')
        main.markPresenceChanged()
        main.expire()
        eq(s.storage.readContract(c.id).state, CH.STATE.EXPIRED)
        eq(money(3), before, 'forfeited to a deadline that had passed before they joined')
    end)

    it('does not forfeit a stake taken after the deadline passed', function()
        local main, s, f, c = due()
        -- Seconds left when the acceptance starts; gone by the time its row
        -- is written, and the expiry pass runs in that same wait.
        Env.advance(s.storage.readContract(c.id).deadline_at - os.time() - 2)
        local realRead = s.storage.readHitmanById
        local moved = false
        s.storage.readHitmanById = function(id)
            if not moved then moved = true; Env.advance(5) end
            return realRead(id)
        end
        local realAdd = s.storage.addHitman
        s.storage.addHitman = function(row)
            local out = realAdd(row)
            main.markPresenceChanged()
            main.expire()
            return out
        end
        local before = money(3)
        local ok, err = s.contracts.accept(f.hitman, c.id, false)
        s.storage.readHitmanById, s.storage.addHitman = realRead, realAdd
        falsy(ok)
        eq(err, CH.ERR.ALREADY_SETTLED)
        eq(s.storage.readContract(c.id).state, CH.STATE.EXPIRED)
        eq(money(3), before, 'refused, and the stake paid to the client all the same')
    end)
end)

describe('a crash while the client lowers the penalty', function()
    --- The stake was lowered first and the owed difference minted after it,
    --- two awaits apart; a process that died between them lost the
    --- difference to nobody. The owed line is written first now, and boot
    --- settles whichever side of the stake's write the crash fell.
    local function heldBy(s, cid)
        local total = 0
        for _, c in ipairs(s.storage.allContracts()) do
            for _, l in ipairs(s.storage.readEscrow(c.id)) do
                local mine = (l.portion == CH.PORTION.STAKE and l.staker == cid and not l.owed_to)
                    or l.owed_to == cid
                if mine and (l.state == CH.ESCROW_STATE.HELD or l.state == CH.ESCROW_STATE.RELEASING) then
                    total = total + (l.amount or 0)
                end
            end
        end
        return total
    end

    for _, mode in ipairs({ 'json', 'mysql' }) do
        for _, at in ipairs({ 'owed line written', 'stake lowered' }) do
            it(mode .. ': dying after the ' .. at .. ' loses nothing', function()
                local _, s = boot(mode)
                local f = fixture(s)
                local c = s.contracts.create(f.creator, {
                    targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                    reward = { baseline = { cash = 10000 } }, penaltyAmount = 2000,
                })
                truthy(c)
                truthy(s.contracts.accept(f.hitman, c.id, false))
                local hitman = Env.players[3]
                Env.removePlayer(3)
                local before = hitman.PlayerData.money.cash + hitman.PlayerData.money.bank
                    + heldBy(s, 'HITMAN01')

                if at == 'owed line written' then
                    local real = s.storage.writeEscrow
                    s.storage.writeEscrow = function(id, lines)
                        local out = real(id, lines)
                        if lines[1] and lines[1].portion == CH.PORTION.OWED then
                            error('process killed')
                        end
                        return out
                    end
                else
                    local real = s.storage.setEscrowAmount
                    s.storage.setEscrowAmount = function(...)
                        local out = real(...)
                        if out then error('process killed') end
                        return out
                    end
                end
                falsy(pcall(s.amendments.improve, f.creator, c.id, CH.AMENDMENT.LOWER_PENALTY,
                    { amount = 500 }), 'the process died')

                local _, s2 = restart(mode, s)
                Env.players[3] = hitman
                Env.byCitizen['HITMAN01'] = 3
                s2.escrow.retryPending('HITMAN01')

                local after = hitman.PlayerData.money.cash + hitman.PlayerData.money.bank
                    + heldBy(s2, 'HITMAN01')
                eq(after, before, mode .. ': the hitman\'s money and stake, before and after')
                if at == 'stake lowered' then
                    eq(heldBy(s2, 'HITMAN01'), 500, 'the stake at its new figure, the rest paid')
                else
                    eq(heldBy(s2, 'HITMAN01'), 2000, 'the stake untouched, nothing owed for it')
                end
            end)
        end
    end
end)

describe('a crash between paying a handover\'s baseline and its bonus', function()
    --- Recovery counted the collection paid by its baseline and swept the
    --- bonus, held and owed to nobody, to the client.
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': the hitman still gets the bonus they earned', function()
            local _, s = boot(mode)
            local f = fixture(s)
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x',
                reward = { baseline = { cash = 10000 }, bonus = { cash = 5000 } },
            })
            truthy(c)
            truthy(s.contracts.accept(f.hitman, c.id))
            local hitmanBefore, creatorBefore = money(3), money(1)

            local real = s.escrow.release
            s.escrow.release = function(id, who, filter, reason)
                if type(filter) == 'table' and filter.portion == CH.PORTION.BONUS then
                    error('process killed')
                end
                return real(id, who, filter, reason)
            end
            falsy(pcall(s.contracts.claimSlot, c.id, 'HITMAN01', CH.FULFILMENT.KIDNAPPING))

            local main2, s2 = restart(mode, s)
            s2.escrow.retryPending('HITMAN01')
            main2.tick()
            eq(money(3) - hitmanBefore, 15000, 'the baseline and the bonus')
            eq(money(1) - creatorBefore, 0, 'none of it to the client')
            eq(s2.storage.readContract(c.id).state, CH.STATE.COMPLETED)
        end)
    end
end)

describe('an extension while the expiry pass ends a pause', function()
    --- The pass re-read the row, then wrote the whole of it back one await
    --- later, over an extension made in that await: the hitman lost the time
    --- the client had just given them.
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': both the pause and the extension count', function()
            local main, s = boot(mode)
            Config.Limits.ExclusiveIdleReleaseSeconds = 0
            Config.Limits.ExclusiveAttemptWindowSeconds = 0
            local f = fixture(s)
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x',
                reward = { baseline = { cash = 10000 } },
            })
            truthy(c)
            truthy(s.contracts.accept(f.hitman, c.id))
            local before = s.storage.readContract(c.id).deadline_at
            -- The target leaves: the pass starts a pause.
            local target = Env.players[2]
            Env.removePlayer(2)
            main.markPresenceChanged()
            main.expire()
            truthy(s.storage.readContract(c.id).paused_since, 'paused')
            Env.advance(600)
            Env.players[2] = target
            Env.byCitizen['TARGET01'] = 2

            local real = s.storage.readContract
            local extended = false
            s.storage.readContract = function(id)
                local row = real(id)
                if id == c.id and not extended and row and row.paused_since then
                    extended = true
                    truthy(s.amendments.improve(f.creator, c.id, CH.AMENDMENT.EXTEND_DEADLINE,
                        { seconds = 3600 }), 'the client extends it')
                end
                return row
            end
            main.markPresenceChanged()
            main.expire()
            s.storage.readContract = real
            truthy(extended)

            local after = s.storage.readContract(c.id)
            falsy(after.paused_since, 'the pause ended')
            eq(after.deadline_at - before, 600 + 3600,
                mode .. ': the pass wrote its copy over the extension')
        end)
    end
end)

describe('an extension landing as the expiry pass decides', function()
    --- The pass read the contract overdue, the client extended it in the
    --- await after, and the pass expired it on its read all the same —
    --- forfeiting the stake of the hitman the time was given to.
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': the extended contract is not expired', function()
            local main, s = boot(mode)
            Config.Limits.ExclusiveIdleReleaseSeconds = 0
            Config.Limits.ExclusiveAttemptWindowSeconds = 0
            local f = fixture(s)
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x',
                reward = { baseline = { cash = 10000 } }, penaltyAmount = 2000,
            })
            truthy(c)
            truthy(s.contracts.accept(f.hitman, c.id))
            main.tick()
            Env.advance(Config.Limits.DefaultDeadlineSeconds + 305)
            local hitmanBefore = money(3)

            local real = s.storage.readContract
            local extended = false
            s.storage.readContract = function(id)
                local row = real(id)
                if id == c.id and not extended then
                    extended = true
                    truthy(s.amendments.improve(f.creator, c.id, CH.AMENDMENT.EXTEND_DEADLINE,
                        { seconds = 3600 }), 'the client extends it')
                end
                return row
            end
            main.markPresenceChanged()
            main.expire()
            s.storage.readContract = real
            truthy(extended)

            eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED,
                mode .. ': expired on a read taken before the extension')
            eq(money(3), hitmanBefore, 'and the stake is still theirs')
        end)
    end
end)

describe('a crash part-way through an acceptance', function()
    --- The row is written before the acceptance is confirmed. A process
    --- that died between the two left a hitman on the contract who had been
    --- told nothing — holding an exclusive contract nobody else could take.
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': is undone at boot, stake back and the contract open again', function()
            local _, s = boot(mode)
            local f = fixture(s)
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.EXCLUSIVE,
                reward = { baseline = { cash = 10000 } }, penaltyAmount = 2000,
            })
            truthy(c)
            local before = money(3)
            local realAdd = s.storage.addHitman
            s.storage.addHitman = function(row)
                realAdd(row)
                error('process killed')
            end
            falsy(pcall(s.contracts.accept, f.hitman, c.id, false))

            local _, s2 = restart(mode, s)
            eq(money(3), before, 'the stake came back')
            eq(s2.storage.readContract(c.id).state, CH.STATE.ACTIVE, 'on the board again')
            eq(s2.storage.readHitman(c.id, 'HITMAN01').state, 'refused')
            truthy(s2.contracts.accept(s2.identity.resolve(3), c.id, false),
                'and can be taken, by them or anyone')
        end)
    end
end)

describe('an extension written while the expiry pass ends a pause', function()
    --- The extension reads the deadline, adds to it and writes it back. The
    --- pass ending a pause in between moved the deadline on by the pause,
    --- and an unguarded write of the figure read before it took that away.
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': keeps the pause as well as the extension', function()
            local main, s = boot(mode)
            Config.Limits.ExclusiveIdleReleaseSeconds = 0
            Config.Limits.ExclusiveAttemptWindowSeconds = 0
            local f = fixture(s)
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x',
                reward = { baseline = { cash = 10000 } },
            })
            truthy(s.contracts.accept(f.hitman, c.id))
            local before = s.storage.readContract(c.id).deadline_at
            local target = Env.players[2]
            Env.removePlayer(2)
            main.markPresenceChanged()
            main.expire()
            Env.advance(600)
            Env.players[2] = target
            Env.byCitizen['TARGET01'] = 2

            local real = s.storage.setDeadline
            local once = false
            s.storage.setDeadline = function(...)
                if not once then
                    once = true
                    main.markPresenceChanged()
                    main.expire()
                end
                return real(...)
            end
            truthy(s.amendments.improve(f.creator, c.id, CH.AMENDMENT.EXTEND_DEADLINE,
                { seconds = 3600 }))
            s.storage.setDeadline = real
            truthy(once)
            eq(s.storage.readContract(c.id).deadline_at - before, 600 + 3600,
                mode .. ': one of the two was written over')
        end)
    end
end)

--------------------------------------------------------------------------
-- Crashes part-way, and the boot after them
--------------------------------------------------------------------------

--- Kill the process at the first store call `when` picks. That call goes
--- through, and every store call after it throws: a process that has died
--- writes nothing more, and nothing it meant to do next — an unwind, a
--- retry — happens. The next boot finds the store as it stood.
---@param s table the stack
---@param when fun(name: string, ...): boolean
local function killAt(s, when)
    local dead = false
    for name, fn in pairs(s.storage) do
        if type(fn) == 'function' then
            s.storage[name] = function(...)
                if dead then error('process dead', 0) end
                local out = table.pack(fn(...))
                if when(name, ...) then
                    dead = true
                    error('process killed', 0)
                end
                return table.unpack(out, 1, out.n)
            end
        end
    end
end

local function addHitman2()
    Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
        cash = 5000, bank = 5000, firstname = 'Sol', lastname = 'Vane' })
end

local function holders(s, contractId)
    local out = {}
    for _, h in ipairs(s.storage.readHitmen(contractId)) do out[h.hitman_cid] = h end
    return out
end

describe('a crash part-way through accepting', function()
    it('mysql: stake written, row not yet: the contract is takeable again and the stake is back', function()
        local _, s = boot('mysql')
        local f = fixture(s)
        addHitman2()
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 10000 } }, penaltyAmount = 2000,
        })
        truthy(c)
        local before = money(3)
        killAt(s, function(name, _, lines)
            return name == 'writeEscrow' and type(lines) == 'table' and lines[1] ~= nil
                and lines[1].portion == CH.PORTION.STAKE
        end)
        falsy(pcall(s.contracts.accept, f.hitman, c.id, false))

        local _, s2 = restart('mysql', s)
        eq(s2.storage.readContract(c.id).state, CH.STATE.ACTIVE,
            'reserved for nobody, it refused everyone')
        eq(money(3), before, 'and the stake came back')
        truthy(s2.contracts.accept(s2.identity.resolve(4), c.id, false),
            'somebody else can take it')
    end)

    it('mysql: a row left joining while another hitman\'s claim held the contract is taken back', function()
        local _, s = boot('mysql')
        local f = fixture(s)
        addHitman2()
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 10000 } }, penaltyAmount = 500,
        })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local before = money(4)
        killAt(s, function(name, row)
            if name == 'addHitman' and type(row) == 'table' and row.hitman_cid == 'HITMAN02' then
                -- HITMAN01's claim takes the contract as the row lands.
                s.storage.compareSetContractState(c.id, CH.STATE.ACCEPTED, CH.STATE.COMPLETING)
                return true
            end
            return false
        end)
        falsy(pcall(s.contracts.accept, s.identity.resolve(4), c.id, false))

        local _, s2 = restart('mysql', s)
        local row = holders(s2, c.id).HITMAN02
        truthy(row, 'the row was written')
        falsy(row.state == 'joining',
            'left joining: holding a place, and its hitman could neither take it, leave it nor work it')
        eq(money(4), before, 'and nothing of theirs is held')
        truthy(s2.contracts.accept(s2.identity.resolve(4), c.id, false), 'they can take it now')
    end)

    for _, firstAnon in ipairs({ false, true }) do
        it(('mysql: a crash as a hitman takes it up again keeps their %s first stint')
            :format(firstAnon and 'anonymous' or 'named'), function()
            local _, s = boot('mysql')
            Config.Anonymity.HitmanFee = 1500
            local f = fixture(s)
            Env.players[3].PlayerData.money.bank = 20000
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                reward = { baseline = { cash = 10000 } }, penaltyAmount = 1000,
            })
            truthy(s.contracts.accept(f.hitman, c.id, firstAnon))
            truthy(s.contracts.abandon(f.hitman, c.id))
            killAt(s, function(name, _, fields)
                return name == 'updateHitman' and type(fields) == 'table'
                    and (fields.state == 'joining' or fields.state == 'rejoining')
            end)
            falsy(pcall(s.contracts.accept, f.hitman, c.id, true))

            local _, s2 = restart('mysql', s)
            Config.Anonymity.HitmanFee = 1500
            local row = holders(s2, c.id).HITMAN01
            eq(row.state, 'abandoned', 'the earlier stint was erased')
            local before = money(3)
            truthy(s2.contracts.accept(s2.identity.resolve(3), c.id, true))
            local anon = holders(s2, c.id).HITMAN01.anon
            eq(anon == true or anon == 1, firstAnon,
                firstAnon and 'the paid-for anonymity was lost'
                or 'made anonymous under the alias the client already saw named')
            eq(before - money(3), 1000,
                'charged for anonymity it already had, or that hides nothing')
        end)
    end
end)

describe('a crash part-way through paying a collection', function()
    --- Caught after its recipient was written, which is just before the
    --- give: whether the money moved cannot be told at the next start. It
    --- was put back owed and given again by the next login's retry; it is
    --- left for staff, at the first boot rather than the one after, and
    --- their pay gives it once.
    it('mysql: an owed collection caught mid-release is left for staff at the first boot', function()
        local _, s = boot('mysql')
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 10000 } },
        })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local before = money(3)
        killAt(s, function(name, _, lines)
            return name == 'writeEscrow' and type(lines) == 'table' and lines[1] ~= nil
                and lines[1].portion == CH.PORTION.BASELINE and lines[1].releasing_to ~= nil
        end)
        falsy(pcall(s.contracts.claimSlot, c.id, f.hitman.cid, CH.FULFILMENT.ELIMINATION, {}))

        local _, s2 = restart('mysql', s)
        for _ = 1, 3 do s2.escrow.retryPending(f.hitman.cid) end
        eq(money(3) - before, 0, 'not given again blind')
        local stuck = s2.admin.interrupted()
        eq(#stuck, 1, 'listed for staff at the first boot')
        eq(stuck[1].intended, f.hitman.cid)
        truthy(s2.admin.settleLine(0, stuck[1].line, 'pay'))
        s2.escrow.retryPending(f.hitman.cid)
        eq(money(3) - before, 10000, 'and paid once by staff')
    end)
end)

describe('a crash part-way through an instant buyout', function()
    it('mysql: the premium the target paid reaches the client', function()
        local main, s = boot('mysql')
        local f = fixture(s)
        Env.players[2].PlayerData.money.bank = 100000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 10000 } }, bailoutAmount = 15000,
        })
        truthy(c)
        local creator, target = money(1), money(2)
        killAt(s, function(name, _, _, next_)
            return name == 'compareSetContractState' and next_ == CH.STATE.BAILED_OUT
        end)
        falsy(pcall(s.bailout.buy, f.target, c.id))

        local main2, s2 = restart('mysql', s)
        for _ = 1, 3 do Env.advance(10); main2.tick() end
        s2.escrow.retryPending(f.creator.cid)
        eq(s2.storage.readContract(c.id).state, CH.STATE.BAILED_OUT)
        eq(target - money(2), 15000, 'the target paid')
        eq(money(1) - creator, 10000 + 15000,
            'the escrow came back, and the premium was in no line, no queue and no pocket')
    end)
end)

describe('requests while boot recovery is running', function()
    it('mysql: are answered busy, and change nothing', function()
        local _, s = boot('mysql')
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 10000 } }, penaltyAmount = 1000,
        })
        truthy(c)

        -- A player's accept arrives while recovery is reading the escrow.
        local realRun, reply = Exec.run, nil
        Exec.run = function(sql, params)
            if reply == nil and type(sql) == 'string'
                and sql:find('FROM crimson_escrow WHERE contract_id') then
                reply = false
                local fire = Env.events['crimson-hitman:accept']
                if fire then
                    Env.clientEvents = {}
                    _G.source = 3
                    pcall(fire, { id = c.id, anonymous = false, penaltyAmount = 1000 })
                    _G.source = nil
                    for _, e in ipairs(Env.clientEvents) do
                        if e.name == 'crimson-hitman:result' then reply = e.args[1] end
                    end
                end
            end
            return realRun(sql, params)
        end
        local ok, _, s2 = pcall(restart, 'mysql', s)
        Exec.run = realRun
        truthy(ok)
        truthy(type(reply) == 'table', 'the request got no answer at all')
        falsy(reply.ok, 'accepted while recovery was deciding what the crash had left')
        eq(reply.err, CH.ERR.BUSY)
        eq(#s2.storage.readHitmen(c.id), 0, 'and nobody is on the contract')

        -- And once recovery is done, the same request goes through.
        Env.clientEvents = {}
        _G.source = 3
        Env.events['crimson-hitman:accept']({ id = c.id, anonymous = false, penaltyAmount = 1000 })
        _G.source = nil
        local after
        for _, e in ipairs(Env.clientEvents) do
            if e.name == 'crimson-hitman:result' then after = e.args[1] end
        end
        truthy(after and after.ok, 'still refused once the server had started: '
            .. tostring(after and after.err))
    end)

    it('mysql: a death reported while recovery runs is acted on once it has finished', function()
        local _, s = boot('mysql')
        local f = fixture(s)
        truthy(s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 10000 } },
        }))
        local realRun, fired, handled = Exec.run, false, false
        Exec.run = function(sql, params)
            if not fired and type(sql) == 'string'
                and sql:find('FROM crimson_escrow WHERE contract_id') then
                fired = true
                local death = package.loaded['server.completion.death']
                local real = death and death.onVictimReport
                if death then death.onVictimReport = function(...) handled = true return real(...) end end
                local fire = Env.events['crimson-hitman:iDied']
                _G.source = 2
                if fire then pcall(fire, 3) end
                _G.source = nil
                if death then death.onVictimReport = real end
            end
            return realRun(sql, params)
        end
        local ok = pcall(restart, 'mysql', s)
        Exec.run = realRun
        truthy(ok)
        truthy(fired, 'recovery never read the escrow')
        falsy(handled, 'a kill was settled while recovery was still deciding what the crash left')

        -- Held, not dropped: the client reports a death once, and nothing
        -- else opens the kill a photo has to prove.
        local death = package.loaded['server.completion.death']
        local real, later = death.onVictimReport, false
        death.onVictimReport = function(...) later = true return real(...) end
        Env.advance(2)
        death.onVictimReport = real
        truthy(later, 'the report made during recovery was never handled')
    end)
end)

describe('a crash inside boot recovery itself', function()
    it('mysql: the joining hitman still gets their stake back on the boot after', function()
        local _, s = boot('mysql')
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 10000 } }, penaltyAmount = 2000,
        })
        local before = money(3)
        killAt(s, function(name, _, lines)
            return name == 'writeEscrow' and type(lines) == 'table' and lines[1] ~= nil
                and lines[1].portion == CH.PORTION.STAKE
        end)
        falsy(pcall(s.contracts.accept, f.hitman, c.id, false))

        -- The next boot dies at recovery's first write for that acceptance,
        -- whichever it is.
        local realRun, dead = Exec.run, false
        Exec.run = function(sql, params)
            if dead then error('process dead', 0) end
            local out = realRun(sql, params)
            if type(sql) == 'string' and (sql:find('UPDATE crimson_hitmen SET state')
                or sql:find('UPDATE crimson_escrow SET state')) then
                dead = true
                error('process killed', 0)
            end
            return out
        end
        falsy(pcall(restart, 'mysql', s))
        Exec.run = realRun

        local _, s3 = restart('mysql', s)
        eq(money(3), before, 'the stake was left held against a row already refused')
        eq(s3.storage.readContract(c.id).state, CH.STATE.ACTIVE)
    end)
end)

describe('queued payments across a restart', function()
    it('mysql: one queued in the same second after a restart does not replace another', function()
        local _, s = boot('mysql')
        s.storage.queuePending('HITMAN01', 'ct000000001', 'owe00000001')
        local _, s2 = restart('mysql', s)
        s2.storage.queuePending('HITMAN01', 'ct000000001', 'owe00000002')
        eq(#s2.storage.readPending('HITMAN01'), 2,
            'the sequence started again at boot, and the second landed on the first')
    end)
end)

--- sc-police keeps a prisoner's remaining sentence in the 'injail' metadata.
--- A target in prison is as far out of a hitman's reach as one who has
--- logged off, and the deadline ran on through their sentence: a hitman
--- could stake, have the target jailed out from under them, and lose the
--- stake without the target ever being in the city to find.
describe('a target in prison', function()
    local function held(mode)
        local main, s = boot(mode)
        Config.Limits.ExclusiveIdleReleaseSeconds = 0
        Config.Limits.ExclusiveAttemptWindowSeconds = 0
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 10000 } }, penaltyAmount = 2000,
        })
        truthy(c)
        truthy(s.contracts.accept(f.hitman, c.id))
        main.markPresenceChanged()
        main.expire()
        return main, s, f, c
    end

    local function jail(minutes)
        Env.players[2].PlayerData.metadata.injail = minutes
        -- And inside the prison, where a real sentence puts them.
        local zone = Config.Limits.JailZone
        Env.players[2]._coords = { x = zone.x + 10.0, y = zone.y - 10.0, z = 45.0 }
    end

    for _, mode in ipairs({ 'memory', 'mysql' }) do
        it(mode .. ': stops the deadline while they serve, and moves it on after', function()
            local main, s, _, c = held(mode)
            local before = s.storage.readContract(c.id).deadline_at
            jail(30)
            main.markPresenceChanged()
            main.expire()
            truthy(s.storage.readContract(c.id).paused_since, 'paused while in prison')

            Env.advance(1800)
            jail(0)
            main.markPresenceChanged()
            main.expire()
            local after = s.storage.readContract(c.id)
            falsy(after.paused_since, 'running again once released')
            eq(after.deadline_at - before, 1800, 'moved on by the time served')
        end)

        it(mode .. ': does not expire the contract while they are inside', function()
            local main, s, _, c = held(mode)
            local before = money(3)
            jail(600)
            -- Seen going in, as the metadata hook makes sure it is.
            main.markPresenceChanged()
            main.expire()
            Env.advance(Config.Limits.DefaultDeadlineSeconds + 360)
            main.markPresenceChanged()
            main.expire()
            local row = s.storage.readContract(c.id)
            eq(row.state, CH.STATE.ACCEPTED, 'the hitman still holds it')
            eq(money(3), before, 'and nothing was forfeited')
        end)
    end

    it('notices a release without a player arriving', function()
        -- Only a player coming or going wakes the pass early, and a release
        -- from prison is neither: the pause ran on to the longest skip.
        local main, s, _, c = held('memory')
        jail(5)
        main.markPresenceChanged()
        main.expire()
        truthy(s.storage.readContract(c.id).paused_since)

        Env.advance(61)
        jail(0)
        main.expire()
        falsy(s.storage.readContract(c.id).paused_since, 'resumed within a minute')
    end)

    it('wakes the pass when the sentence is written', function()
        local main, s, _, c = held('memory')
        main.expire()
        jail(30)
        local handler = Env.handlers['qbx_core:server:onSetMetaData']
        truthy(handler, 'listening for metadata writes')
        handler('injail', 0, 30, 2)
        main.expire()
        truthy(s.storage.readContract(c.id).paused_since,
            'paused at once, not at the next scheduled pass')
    end)

    it('does not run a full pass for every month a sentence counts down', function()
        -- sc-police writes the sentence every thirty seconds for every
        -- inmate; a pass on each write was the table read the skip saves.
        local main, s, _, c = held('memory')
        main.expire()
        jail(30)
        local handler = Env.handlers['qbx_core:server:onSetMetaData']
        handler('injail', 31, 30, 2)
        main.expire()
        falsy(s.storage.readContract(c.id).paused_since,
            'a countdown write is not somebody going in or coming out')
    end)

    --- sc-police lets a client write its own sentence. A target who sends
    --- one from the city, and never goes near the prison, is not in it.
    it('does not stop the clock for a sentence served outside the prison', function()
        local main, s, _, c = held('memory')
        Env.players[2].PlayerData.metadata.injail = 99999
        Env.players[2]._coords = { x = 0.0, y = 0.0, z = 0.0 }
        main.markPresenceChanged()
        main.expire()
        falsy(s.storage.readContract(c.id).paused_since, 'a sentence the target wrote for themselves')
        Env.advance(Config.Limits.DefaultDeadlineSeconds + 360)
        main.markPresenceChanged()
        main.expire()
        eq(s.storage.readContract(c.id).state, CH.STATE.EXPIRED, 'and the deadline still ends it')
    end)

    it('does not count a prison with no zone configured', function()
        local main, s, _, c = held('memory')
        Config.Limits.JailZone = nil
        Env.players[2].PlayerData.metadata.injail = 30
        Env.players[2]._coords = { x = 1693.3, y = 2569.5, z = 45.0 }
        main.markPresenceChanged()
        main.expire()
        falsy(s.storage.readContract(c.id).paused_since)
    end)

    it('does not turn an expiry into a pause after the deadline has gone', function()
        local main, s, _, c = held('memory')
        local before = money(3)
        Env.advance(Config.Limits.DefaultDeadlineSeconds + 360)
        jail(600)
        main.markPresenceChanged()
        main.expire()
        eq(s.storage.readContract(c.id).state, CH.STATE.EXPIRED)
        eq(money(3), before, 'the stake is not handed back by a sentence written late')
    end)

    it('runs the clock on as before when the setting is off', function()
        local main, s, _, c = held('memory')
        Config.Limits.PauseWhileTargetJailed = false
        jail(600)
        Env.advance(Config.Limits.DefaultDeadlineSeconds + 360)
        main.markPresenceChanged()
        main.expire()
        eq(s.storage.readContract(c.id).state, CH.STATE.EXPIRED)
    end)
end)

--- A new contract's escrow is written before its row. A crash between the
--- two left the reward in lines whose contract does not exist: Recover walks
--- contracts, so it never saw them, and the client's money was gone.
describe('a crash between taking a new contract\'s escrow and storing it', function()
    --- A live contract with a hitman's stake on it, then a second contract
    --- whose placing dies once its escrow is written.
    local function crashed(mode)
        local main, s = boot(mode)
        local f = fixture(s)
        local live = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 10000 } }, penaltyAmount = 2000,
        })
        truthy(live)
        truthy(s.contracts.accept(f.hitman, live.id, false))
        local before, hitman = money(1), money(3)
        killAt(s, function(name, contractId)
            return name == 'writeEscrow' and contractId ~= live.id
        end)
        falsy(pcall(s.contracts.create, f.creator, {
            targetCid = 'TARGET01', reason = 'y', reward = { baseline = { bank = 7000 } },
        }))
        eq(money(1), before - 7000, 'the crash came after the charge')
        return main, s, live, before, hitman
    end

    local function heldOn(s, contractId)
        local out = {}
        for _, l in ipairs(s.storage.readEscrow(contractId)) do
            if l.state == CH.ESCROW_STATE.HELD then out[#out + 1] = l.amount end
        end
        table.sort(out)
        return table.concat(out, ',')
    end

    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': the client gets it back once, and a live contract keeps its own', function()
            local _, s, live, before, hitman = crashed(mode)

            local _, s2 = restart(mode, s)
            eq(money(1), before, 'the reward of a contract never stored was not handed back')
            eq(#s2.storage.orphanEscrow(), 0)
            eq(heldOn(s2, live.id), '2000,10000', 'the live contract\'s escrow was touched')
            eq(s2.storage.readContract(live.id).state, CH.STATE.ACCEPTED)

            local _, s3 = restart(mode, s2)
            eq(money(1), before, 'handed back a second time')
            eq(money(3), hitman)
            eq(heldOn(s3, live.id), '2000,10000')
        end)

        it(mode .. ': a client who is offline is owed it, and paid it once at login', function()
            local _, s, _, before = crashed(mode)
            local creator = Env.players[1]
            Env.removePlayer(1)

            local _, s2 = restart(mode, s)
            local _, s3 = restart(mode, s2)
            eq(#s3.storage.readPending('CREATOR1'), 1, 'owed once, however many boots')

            Env.players[1], Env.byCitizen.CREATOR1 = creator, 1
            eq(s3.escrow.retryPending('CREATOR1'), 1)
            eq(money(1), before)
            local _, s4 = restart(mode, s3)
            eq(s4.escrow.retryPending('CREATOR1'), 0)
            eq(money(1), before, 'paid twice')
        end)
    end

    it('mysql: dying while handing it back leaves it for staff, and it is paid once', function()
        local _, s, _, before = crashed('mysql')

        -- The first boot dies once it has written whom the line is going to.
        local realRun, dead = Exec.run, false
        Exec.run = function(sql, params)
            if dead then error('process dead', 0) end
            local out = realRun(sql, params)
            if type(sql) == 'string' and sql:find('INSERT INTO crimson_escrow') then
                dead = true
                error('process killed', 0)
            end
            return out
        end
        falsy(pcall(restart, 'mysql', s))
        Exec.run = realRun

        local _, s3 = restart('mysql', s)
        eq(money(1), before - 7000, 'paid on although it may already have been')
        local stuck = s3.admin.interrupted()
        eq(#stuck, 1, 'not reported to staff')
        truthy(s3.admin.settleLine(0, stuck[1].line, 'return'))
        eq(money(1), before)
        restart('mysql', s3)
        eq(money(1), before, 'paid twice')
    end)

    --- Memory holds nothing across a restart, so the boot's sweep is run on
    --- the same process. The store refuses the contract write and the read
    --- after it, which is the one way a running server gets here.
    local function refused(main, s, f, req)
        local realWrite, realRead, down = s.storage.writeContract, s.storage.readContract, false
        s.storage.writeContract = function()
            down = true
            error('mysql: connection lost', 0)
        end
        s.storage.readContract = function(id)
            if down then error('mysql: connection lost', 0) end
            return realRead(id)
        end
        falsy(pcall(s.contracts.create, f.creator, req))
        s.storage.writeContract, s.storage.readContract = realWrite, realRead
    end

    it('memory: the sweep hands it back once, the weapon as it was', function()
        local main, s = boot('memory')
        local f = fixture(s, { creatorInventory = {
            { name = 'WEAPON_PISTOL', count = 1, slot = 3,
              metadata = { serial = 'ABC123', registered = 'Vic Marlowe' } },
        } })
        local live = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 10000 } },
        })
        truthy(live)
        local before = money(1)
        refused(main, s, f, { targetCid = 'TARGET01', reason = 'y', anonymous = true,
            reward = { baseline = { bank = 7000,
                weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } } } })
        eq(money(1), before - 7000)

        main.recover()
        eq(money(1), before)
        local pistol
        for _, slot in ipairs(Env.players[1]._inventory) do
            if slot.name == 'WEAPON_PISTOL' then pistol = slot end
        end
        eq(pistol and pistol.metadata.registered, 'Vic Marlowe',
            'the client\'s own weapon came back with their name taken off')
        eq(heldOn(s, live.id), '10000')

        main.recover()
        main.tick()
        eq(money(1), before, 'handed back a second time')
    end)

    it('memory: a contract being placed is not swept from under itself', function()
        local _, s = boot('memory')
        local f = fixture(s)
        local before = money(1)
        local realWrite, swept = s.storage.writeContract, nil
        s.storage.writeContract = function(contract)
            -- Its escrow is written and its row is not yet.
            if swept == nil then swept = s.contracts.recoverNeverPlaced() end
            return realWrite(contract)
        end
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { bank = 7000 } },
        })
        s.storage.writeContract = realWrite
        truthy(c)
        eq(swept, 0, 'the sweep took the escrow of a contract still being placed')
        eq(money(1), before - 7000)
        eq(heldOn(s, c.id), '7000')
    end)

    it('memory: the tick hands back the reward and the anonymity fee once the store answers', function()
        local main, s = boot('memory')
        local f = fixture(s)
        Config.Anonymity.CreatorFee = 500
        local before = money(1)
        refused(main, s, f, { targetCid = 'TARGET01', reason = 'y', anonymous = true,
            reward = { baseline = { bank = 7000 } } })
        eq(money(1), before - 7500, 'the fee and the reward were both taken')

        main.tick()
        eq(money(1), before, 'not handed back while the server ran')
        main.tick()
        main.recover()
        eq(money(1), before, 'handed back a second time')
    end)

    --- Lines written before they said whose they were. Staff were told at
    --- every boot, with a fresh audit row each time, and no command could
    --- list or settle them.
    it('memory: a line that names nobody is listed for staff, logged once, and goes where they say', function()
        local main, s = boot('memory')
        local f = fixture(s)
        local live = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        truthy(live)
        local before = money(1)
        s.storage.writeEscrow('ct00000099', { { id = 'ct00000099:1', contract_id = 'ct00000099',
            slot = 1, portion = CH.PORTION.BASELINE, source = 'bank', amount = 700,
            state = CH.ESCROW_STATE.HELD } })

        main.recover()
        main.tick()
        main.recover()
        main.tick()
        eq(#s.storage.auditByAction('escrow_orphaned', 100), 1, 'logged again at every boot')

        local stuck = s.admin.interrupted()
        eq(#stuck, 1, '/ch-stuck does not list it')
        eq(stuck[1].line, 'ct00000099:1')
        truthy(stuck[1].orphan)

        eq(select(2, s.admin.settleLine(0, 'ct00000099:1', 'return')), CH.ERR.NOT_FOUND)
        eq(select(2, s.admin.settleLine(0, 'ct00000099:1', 'pay', 'CREATOR1')), CH.ERR.INVALID_INPUT)
        eq(select(2, s.admin.settleLine(0, live.id .. ':1', 'return', 'HITMAN01')),
            CH.ERR.INVALID_INPUT, 'a typed citizen id took a line from the client it names')

        truthy(s.admin.settleLine(0, 'ct00000099:1', 'return', 'CREATOR1'))
        eq(money(1), before + 700)
        eq(#s.admin.interrupted(), 0)
        local rows = s.storage.auditByAction('admin_settle_line', 10)
        eq(rows[#rows].detail.recipient, 'CREATOR1')
        truthy(rows[#rows].detail.named_by_staff)
    end)
end)


--- Modes do not share data. A server switched from json to mysql — which
--- the json store itself suggests once it is busy — or tried on memory for
--- a test started empty: every open contract invisible, the escrow taken
--- for it with it, nothing returning it and nothing saying so.
describe('changing storage mode', function()
    local function placed(s, f)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { bank = 50000 } },
        })
        truthy(c, 'a contract holding the client\'s money')
        return c
    end

    it('json to mysql: refuses to start while the json store holds money', function()
        local _, s = boot('json')
        local c = placed(s, fixture(s))
        local before = Natives.files['data/contracts/' .. c.id .. '.json']
        Exec.install(Natives)
        local ok, err = pcall(restart, 'mysql', s)
        falsy(ok, 'an empty mysql store over money held in json is not a start')
        truthy(tostring(err):find('json mode: 1 escrow line', 1, true), tostring(err))
        truthy(tostring(err):find('AllowModeSwitch', 1, true), 'and says how to start anyway')
        eq(Natives.files['data/contracts/' .. c.id .. '.json'], before, 'the json store is untouched')
    end)

    it('json to memory: the same, and AllowModeSwitch starts it anyway, saying so', function()
        local _, s = boot('json')
        placed(s, fixture(s))
        falsy(pcall(restart, 'memory', s), 'memory mode refuses too')

        Config.Database.AllowModeSwitch = true
        local ok, _, s2 = pcall(restart, 'memory', s)
        truthy(ok, 'with the switch allowed it starts')
        truthy(s2 and s2.contracts, 'wired')
        truthy(table.concat(Env.console, ' '):find('AllowModeSwitch is on', 1, true),
            'and warns that what the other mode holds is not visible from here')
    end)

    it('json to mysql: a json store holding nothing owed is no reason to refuse', function()
        local _, s = boot('json')
        local f = fixture(s)
        local c = placed(s, f)
        truthy(s.contracts.cancel(f.creator, c.id), 'cancelled, the money back')
        Exec.install(Natives)
        local ok, err = pcall(restart, 'mysql', s)
        truthy(ok, tostring(err))
    end)

    it('mysql to json: refuses while the crimson tables hold money', function()
        local _, s = boot('mysql')
        placed(s, fixture(s))
        Natives.resourceStates['oxmysql'] = 'started'
        local ok, err = pcall(restart, 'json', s)
        falsy(ok, 'an empty json store over money held in mysql is not a start')
        truthy(tostring(err):find('mysql mode: 1 escrow line', 1, true), tostring(err))
    end)

    it('json: a server without oxmysql running is not asked about mysql', function()
        local _, s = boot('mysql')
        placed(s, fixture(s))
        Natives.resourceStates['oxmysql'] = nil
        local ok, err = pcall(restart, 'json', s)
        truthy(ok, tostring(err))
    end)
end)

--- The usual update is to delete the resource folder and extract the new
--- one. In json mode that took data/ with it, and the store started empty
--- without a word: it looked exactly like a first install.
describe('a json store whose folder was replaced', function()
    it('refuses to start empty where this server has run it before', function()
        local _, s = boot('json')
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        truthy(s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { bank = 50000 } } }))

        -- A new folder: the files gone, the server's own KVP store kept.
        local old = Natives.files
        Natives.files = {}
        Natives.kvp[Natives.files] = Natives.kvp[old]
        local ok, err = pcall(restart, 'json', s)
        falsy(ok, 'an empty folder on a server that ran the store is not a first install')
        truthy(tostring(err):find('replacing the resource folder', 1, true), tostring(err))
        truthy(tostring(err):find('crimson_hitman_new_store', 1, true), 'and says how to start empty')
        eq(Natives.files['data/store.json'], nil, 'nothing was written in its place')

        -- Put back, it starts with the contract.
        Natives.files = old
        local back, _, s3 = pcall(restart, 'json', s)
        truthy(back, 'the old data/ put back, it starts')
        eq(#s3.storage.allContracts(), 1, 'with the contract and its escrow')
    end)

    it('starts empty on purpose with the console convar, and on a server that never ran it', function()
        local _, s = boot('json')
        local old = Natives.files
        Natives.files = {}
        Natives.kvp[Natives.files] = Natives.kvp[old]
        Natives.convars['crimson_hitman_new_store'] = '1'
        local ok, err = pcall(restart, 'json', s)
        Natives.convars['crimson_hitman_new_store'] = nil
        truthy(ok, tostring(err))
        truthy(table.concat(Env.console, ' '):find('Unset it now', 1, true), 'and says to unset it')

        -- A new server: new folder, nothing in its KVP store.
        Natives.files = {}
        local fresh, freshErr = pcall(restart, 'json', s)
        truthy(fresh, tostring(freshErr))
    end)
end)

--- A restart of this resource with players still connected. The login
--- events that run the readiness pass came and went before it was
--- listening, and the framework does not fire them again: a payout queued
--- for a connected player waited for a relog, however much room they made.
describe('a payout queued for a player still connected through a restart', function()
    local function carried(src, name)
        local n = 0
        for _, slot in ipairs(Env.players[src]._inventory or {}) do
            if slot.name == name then n = n + slot.count end
        end
        return n
    end

    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': arrives once they make room, without a relog', function()
            local _, s = boot(mode)
            local f = fixture(s)
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.EXCLUSIVE,
                reward = { baseline = { cash = 1000, items = { { name = 'lockpick', count = 5 } } } },
            })
            truthy(s.contracts.accept(f.hitman, c.id, false))
            Env.players[3]._inventoryFull = true
            local ok, _, result = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
            truthy(ok)
            eq(result.pending, 1, 'the lockpicks did not fit')

            local main2, s2 = restart(mode, s)
            Env.players[3]._inventoryFull = false
            for _ = 1, 6 do
                Env.advance(10)
                main2.tick()
            end
            eq(carried(3, 'lockpick'), 5, 'handed over after the restart')
            eq(#s2.storage.readPending('HITMAN01'), 0, 'and nothing is left queued')
        end)
    end
end)

local function lockpicks(src)
    local n = 0
    for _, e in ipairs(Env.players[src]._inventory or {}) do
        if e.name == 'lockpick' then n = n + (e.count or 0) end
    end
    return n
end

--- The process died between a give and the settle that records it. The
--- next start put the line back to held with its queue entry still there,
--- and the next login's retry gave it again: 2 lockpicks became 4. A give
--- that may have happened is never given again (§14.12): it is left for
--- staff.
describe('a give that landed just before the process died', function()
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': is left for staff at the next start, not given again at the next login', function()
            local _, s = boot(mode)
            local f = fixture(s)
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                reward = { baseline = { cash = 1000, items = { { name = 'lockpick', count = 2 } } } },
            })
            truthy(c)
            truthy(s.contracts.accept(f.hitman, c.id, false))
            Env.players[3]._inventoryFull = true
            truthy(s.contracts.claimSlot(c.id, f.hitman.cid, CH.FULFILMENT.ELIMINATION, {}))
            Env.players[3]._inventoryFull = false
            eq(lockpicks(3), 0, 'owed: their pockets were full')

            -- The login's retry gives it, and the process dies before the
            -- line is recorded as settled.
            s.storage.settleEscrowLine = function() error('process killed', 0) end
            falsy(pcall(s.escrow.retryPending, f.hitman.cid))
            eq(lockpicks(3), 2, 'it arrived')

            local _, s2 = restart(mode, s)
            for _ = 1, 3 do s2.escrow.retryPending(f.hitman.cid) end
            eq(lockpicks(3), 2, 'and was not given a second time')

            local stuck = s2.admin.interrupted()
            eq(#stuck, 1, 'listed for staff')
            eq(stuck[1].why, 'interrupted')
            eq(stuck[1].intended, f.hitman.cid)
            truthy(s2.admin.settleLine(0, stuck[1].line, 'delivered'))
            eq(lockpicks(3), 2, 'settled as delivered, giving nothing')
            eq(#s2.admin.interrupted(), 0)
        end)
    end
end)

--- /ch-stuck found a line caught mid-release only through the log's
--- release_interrupted row. Once the log let it go, the line was listed
--- nowhere: held, kept with its contract for ever, and seen by nobody.
describe('a line caught mid-release, past the log\'s retention', function()
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': is still listed for staff, from the escrow itself', function()
            local _, s = boot(mode)
            local f = fixture(s)
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                reward = { baseline = { cash = 5000 } },
            })
            truthy(c)
            local before = money(1)
            -- Voided by staff: paying the client back, the process dies
            -- between the credit and the settle.
            s.storage.settleEscrowLine = function() error('process killed', 0) end
            falsy(pcall(s.admin.void, 0, c.id, 'test'))
            eq(money(1) - before, 5000, 'the credit landed')

            local _, s2 = restart(mode, s)
            eq(#s2.admin.interrupted(), 1, 'listed after the restart')

            s2.audit.flush()
            Env.time = Env.time + (math.max(Config.Audit.RetentionDays,
                Config.Audit.ContractRetentionDays) + 1) * 86400
            s2.storage.prune()
            -- The json log ages its rows out as the next one is written.
            s2.audit.action('after_retention', nil, nil, {})
            s2.audit.flush()
            for _, row in ipairs(s2.storage.readAudit(1000)) do
                falsy(row.action == 'release_interrupted', 'the log still has the row')
            end

            local _, s3 = restart(mode, s2)
            local stuck = s3.admin.interrupted()
            eq(#stuck, 1, 'still listed once the log has let its rows go')
            eq(stuck[1].intended, f.creator.cid)
            truthy(s3.storage.readContract(c.id), 'the contract is kept while it holds the line')
            truthy(s3.admin.settleLine(0, stuck[1].line, 'delivered'))
            eq(money(1) - before, 5000, 'paid once')
        end)

        --- Put back to held by an older version, which left it only in the log.
        it(mode .. ': is left for staff the same way when an older version put it back', function()
            local _, s = boot(mode)
            local f = fixture(s)
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                reward = { baseline = { cash = 5000 } },
            })
            truthy(c)
            local line = s.storage.readEscrow(c.id)[1]
            truthy(s.storage.claimEscrowLine(line.id, CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING))
            line = s.storage.readEscrowLine(line.id)
            line.releasing_to = f.creator.cid
            s.storage.writeEscrow(c.id, { line })
            truthy(s.storage.claimEscrowLine(line.id, CH.ESCROW_STATE.RELEASING, CH.ESCROW_STATE.HELD))

            local _, s2 = restart(mode, s)
            local stored = s2.storage.readEscrowLine(line.id)
            truthy(s2.escrow.parked(stored), 'left for staff')
            eq(stored.owed_to, f.creator.cid, 'owed to whom it was going')
            local stuck = s2.admin.interrupted()
            eq(#stuck, 1, 'and listed from the escrow, with no row in the log')
            eq(stuck[1].why, 'interrupted')
        end)

        --- Owed and queued as well: it looked like any owed line, so only one
        --- owed to nobody was left for staff, and the next login gave this
        --- one again. A held line names whom a give was going to only while
        --- that give may have happened.
        it(mode .. ': is left for staff when an older version put back an owed one', function()
            local _, s = boot(mode)
            local f = fixture(s)
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                reward = { baseline = { cash = 5000 } },
            })
            truthy(c)
            truthy(s.contracts.accept(f.hitman, c.id, false))
            local hitman = Env.players[3]
            Env.removePlayer(3)
            truthy(s.contracts.claimSlot(c.id, f.hitman.cid, CH.FULFILMENT.ELIMINATION, {}))
            local line = s.storage.readEscrow(c.id)[1]
            eq(line.owed_to, f.hitman.cid, 'owed: they were away')
            eq(line.releasing_to, nil, 'a give that moved nothing names nobody')
            eq(#s.storage.readPending(f.hitman.cid), 1)
            -- What an older version left when it put it back mid-give.
            line = s.storage.readEscrowLine(line.id)
            line.releasing_to = f.hitman.cid
            s.storage.writeEscrow(c.id, { line })

            local _, s2 = restart(mode, s)
            Env.players[3], Env.byCitizen[f.hitman.cid] = hitman, 3
            local before = money(3)
            for _ = 1, 3 do s2.escrow.retryPending(f.hitman.cid) end
            eq(money(3), before, 'given again at the next login')
            truthy(s2.escrow.parked(s2.storage.readEscrowLine(line.id)), 'left for staff')
            local stuck = s2.admin.interrupted()
            eq(#stuck, 1)
            eq(stuck[1].intended, f.hitman.cid)
        end)
    end
end)

--- Kill the process just before its n-th store call from here on (of those
--- `counts` picks, or of all): that call and every one after it throw, and
--- whatever ran before it, a credit or an AddItem included, has happened.
--- Stepping n from 1 dies at every boundary of a sequence, until it is
--- one past the end: then nothing dies, and the sequence has finished.
---@param store table the storage module
---@param n integer
---@param counts fun(name: string, ...): boolean|nil
---@return fun(): boolean died whether it was killed
local function killBefore(store, n, counts)
    -- Mid-operation by construction, like any process that died; and the
    -- invariant monitor's own reads are not calls of the process to count.
    rawset(store, '__rawFixture', true)
    local seen, dead = 0, false
    for name, fn in pairs(store) do
        if type(fn) == 'function' then
            store[name] = function(...)
                if not dead and (counts == nil or counts(name, ...)) then
                    seen = seen + 1
                    dead = seen >= n
                end
                if dead then error('process killed', 0) end
                return fn(...)
            end
        end
    end
    return function() return dead end
end

--- Boot again on the same disk, with that boot killed by killBefore.
---@return boolean finished the boot ran to its end
local function restartKilledBefore(mode, old, n, counts)
    if old and old.storage then rawset(old.storage, '__rawFixture', true) end
    forgetServerModules()
    Env.events, Env.clientEvents, Env.notifications = {}, {}, {}
    Env.handlers, Env.threads, Env.timers, Env.commands = {}, {}, {}, {}
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Config.Database.Mode = mode
    local died = killBefore(require('server.storage.' .. mode), n, counts)
    pcall(require('server.main').start)
    return not died()
end

--- The store calls that read or write one escrow line.
local function touching(contractId, lineId)
    return function(name, a, b)
        if name == 'readEscrow' then return a == contractId end
        if name == 'claimEscrowLine' or name == 'settleEscrowLine' or name == 'readEscrowLine' then
            return a == lineId
        end
        if name == 'writeEscrow' and a == contractId and type(b) == 'table' then
            for _, l in ipairs(b) do
                if l.id == lineId then return true end
            end
        end
        return false
    end
end

--- Boot recovery put a line it found mid-give back to held, and only then
--- left it for staff. A boot that died between the two (or whose park
--- raised) left it held, owed, queued and not parked, like any owed line:
--- the next login gave it again, 2 lockpicks became 4, and /ch-stuck listed
--- nothing. Each boot dies at every boundary of what recovery does to the line.
describe('a boot that dies while leaving a line for staff', function()
    local function givenAndDied(mode)
        local _, s = boot(mode)
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 1000, items = { { name = 'lockpick', count = 2 } } } },
        })
        truthy(c)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        Env.players[3]._inventoryFull = true
        truthy(s.contracts.claimSlot(c.id, f.hitman.cid, CH.FULFILMENT.ELIMINATION, {}))
        Env.players[3]._inventoryFull = false
        local line
        for _, l in ipairs(s.storage.readEscrow(c.id)) do
            if l.item == 'lockpick' then line = l end
        end
        eq(line.owed_to, f.hitman.cid, 'owed: their pockets were full')

        -- The login's retry gives it, and the process dies before the line
        -- is recorded as settled.
        s.storage.settleEscrowLine = function() error('process killed', 0) end
        falsy(pcall(s.escrow.retryPending, f.hitman.cid))
        eq(lockpicks(3), 2, 'it arrived')
        return s, f, c, line
    end

    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': is never left to be given again, wherever recovery dies', function()
            local kills = 0
            for n = 1, 12 do
                local s, f, c, line = givenAndDied(mode)
                local finished = restartKilledBefore(mode, s, n, touching(c.id, line.id))
                local _, s3 = restart(mode, s)
                for _ = 1, 3 do s3.escrow.retryPending(f.hitman.cid) end
                eq(lockpicks(3), 2, ('recovery died before its call %d on the line, and the '
                    .. 'next login gave it again'):format(n))
                local stuck = s3.admin.interrupted()
                eq(#stuck, 1, ('died before call %d: not listed for staff'):format(n))
                eq(stuck[1].intended, f.hitman.cid)
                truthy(s3.admin.settleLine(0, stuck[1].line, 'delivered'))
                eq(lockpicks(3), 2)
                if finished then break end
                kills = kills + 1
            end
            truthy(kills >= 3, 'recovery has to have boundaries to die at')
        end)

        --- The same for a contract that was never placed (returnNeverPlaced):
        --- its client was away at the first start and owed the hand-back,
        --- and the login's retry gave it as the process died.
        it(mode .. ': a never-placed contract\'s hand-back is not given again either', function()
            local kills = 0
            for n = 1, 12 do
                local _, s = boot(mode)
                local f = fixture(s)
                local before = money(1)
                killAt(s, function(name) return name == 'writeEscrow' end)
                falsy(pcall(s.contracts.create, f.creator, {
                    targetCid = 'TARGET01', reason = 'y', reward = { baseline = { bank = 7000 } },
                }))
                eq(money(1), before - 7000, 'the crash came after the charge')
                local creator = Env.players[1]
                Env.removePlayer(1)
                local _, s2 = restart(mode, s)
                local line = s2.storage.orphanEscrow()[1]
                truthy(line, 'owed to the client, who was away')
                eq(line.owed_to, f.creator.cid)

                Env.players[1], Env.byCitizen[f.creator.cid] = creator, 1
                s2.storage.settleEscrowLine = function() error('process killed', 0) end
                falsy(pcall(s2.escrow.retryPending, f.creator.cid))
                eq(money(1), before, 'it arrived')

                local finished = restartKilledBefore(mode, s2, n, touching(line.contract_id, line.id))
                local _, s4 = restart(mode, s2)
                for _ = 1, 3 do s4.escrow.retryPending(f.creator.cid) end
                eq(money(1), before, ('recovery died before its call %d on the line, and the '
                    .. 'next login gave it again'):format(n))
                local stuck = s4.admin.interrupted()
                eq(#stuck, 1, ('died before call %d: not listed for staff'):format(n))
                eq(stuck[1].intended, f.creator.cid)
                truthy(s4.admin.settleLine(0, stuck[1].line, 'delivered'))
                eq(money(1), before)
                if finished then break end
                kills = kills + 1
            end
            truthy(kills >= 3, 'recovery has to have boundaries to die at')
        end)
    end
end)

--- A payout whose give raised three times with nothing arriving, left for
--- staff. Its hitman's AddMoney raises before anything moves.
local function parkedPayout(mode)
    local _, s = boot(mode)
    local f = fixture(s)
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 } },
    })
    truthy(c)
    truthy(s.contracts.accept(f.hitman, c.id, false))
    local hitman, creator = money(3), money(1)
    local p = Env.players[3]
    local real = p.Functions.AddMoney
    p.Functions.AddMoney = function() error('AddMoney hook raised', 0) end
    truthy(s.contracts.claimSlot(c.id, f.hitman.cid, CH.FULFILMENT.ELIMINATION, {}))
    for _ = 1, 3 do s.escrow.retryPending(f.hitman.cid) end
    p.Functions.AddMoney = real
    local line = s.storage.readEscrow(c.id)[1]
    truthy(s.escrow.parked(line), 'left for staff')
    eq(line.owed_to, f.hitman.cid)
    eq(money(3), hitman, 'nothing arrived')
    return s, f, c, line, hitman, creator
end

local function auditRows(s, action)
    local out = {}
    for _, row in ipairs(s.storage.auditByAction(action, 100) or {}) do out[#out + 1] = row end
    return out
end

--- Staff hand a parked payout back to the client, and the process dies part
--- of the way. Parked to whom it was owed before rather than whom the return
--- was crediting, /ch-stuck named the hitman, delivered and pay answered
--- locked, a second return paid the client 10,000, and after the log let its
--- row go a pay gave the hitman 5,000 as well: 10,000 out of a 5,000 line.
describe('a staff return the server stops part-way', function()
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': is left owed to whom it was returning to, and settled once', function()
            local kills = 0
            for n = 1, 20 do
                local s, f, _, line, hitman, creator = parkedPayout(mode)
                local died = killBefore(s.storage, n)
                pcall(s.admin.settleLine, 0, line.id, 'return')

                local _, s2 = restart(mode, s)
                local arrived = money(1) - creator
                if s2.storage.readEscrowLine(line.id).state ~= CH.ESCROW_STATE.SETTLED then
                    -- What staff do: check the client, then settle it.
                    local stuck = s2.admin.interrupted()
                    eq(#stuck, 1, ('died before call %d: not listed for staff'):format(n))
                    if arrived == 5000 then
                        eq(stuck[1].intended, f.creator.cid, ('died before call %d, after the '
                            .. 'credit: owed to whom it was being returned to'):format(n))
                        local settled, why = s2.admin.settleLine(0, line.id, 'delivered')
                        truthy(settled, ('died before call %d: delivered refused (%s)')
                            :format(n, tostring(why)))
                    else
                        eq(arrived, 0)
                        truthy(s2.admin.settleLine(0, line.id, 'return'))
                    end
                end
                eq(money(1) - creator, 5000, ('died before call %d: not handed back once')
                    :format(n))
                eq(money(3), hitman, 'and none of it paid to the hitman')
                eq(select(2, s2.admin.settleLine(0, line.id, 'pay')), CH.ERR.ALREADY_SETTLED)
                eq(money(3), hitman, 'nor by a pay after it')

                if not died() then
                    -- Finished, and the process went straight after.
                    eq(#auditRows(s2, 'admin_settle_line'), 1, 'the return was not logged')
                    break
                end
                kills = kills + 1
            end
            truthy(kills >= 6, 'a return has to have boundaries to die at')
        end)

        --- After the log has let the row go, a pay still goes nowhere but
        --- to whom the line is owed.
        it(mode .. ': is never paid to the hitman once the log has let it go', function()
            local s, f, _, line, hitman, creator = parkedPayout(mode)
            -- Dies between the client's credit and the settle.
            s.storage.settleEscrowLine = function() error('process killed', 0) end
            local _, settled = pcall(s.admin.settleLine, 0, line.id, 'return')
            falsy(settled, 'not settled')
            eq(money(1) - creator, 5000, 'the credit landed')

            local _, s2 = restart(mode, s)
            s2.audit.flush()
            Env.time = Env.time + (math.max(Config.Audit.RetentionDays,
                Config.Audit.ContractRetentionDays) + 1) * 86400
            s2.storage.prune()
            s2.audit.action('after_retention', nil, nil, {})
            s2.audit.flush()
            eq(#auditRows(s2, 'release_interrupted'), 0, 'the log still has the row')

            local _, s3 = restart(mode, s2)
            eq(s3.storage.readEscrowLine(line.id).owed_to, f.creator.cid)
            Env.removePlayer(1)
            local ok, note = s3.admin.settleLine(0, line.id, 'pay')
            truthy(ok)
            eq(note, 'queued', 'to the client it is owed to')
            eq(money(3), hitman, 'the hitman was paid the line the client already had')
        end)

        --- Left for staff by a restart mid-give to the hitman, and again by a
        --- return whose credit to the client raised part-way: owed to the
        --- client now, while the log's row from the restart still names the
        --- hitman. Who it went to was read from that row first, so delivered
        --- and pay were refused on a line /ch-stuck said was the client's.
        it(mode .. ': is settled to whom it is owed now, not whom the log first named', function()
            local _, s = boot(mode)
            local f = fixture(s)
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                reward = { baseline = { cash = 5000 } },
            })
            truthy(c)
            truthy(s.contracts.accept(f.hitman, c.id, false))
            local away = Env.players[3]
            Env.removePlayer(3)
            truthy(s.contracts.claimSlot(c.id, f.hitman.cid, CH.FULFILMENT.ELIMINATION, {}))
            Env.players[3], Env.byCitizen[f.hitman.cid] = away, 3
            local hitman, creator = money(3), money(1)

            -- The login's retry names the hitman, and the process dies
            -- before anything is given.
            killAt(s, function(name, _, lines)
                return name == 'writeEscrow' and type(lines) == 'table' and lines[1] ~= nil
                    and lines[1].releasing_to == f.hitman.cid
            end)
            falsy(pcall(s.escrow.retryPending, f.hitman.cid))
            local _, s2 = restart(mode, s)
            s2.audit.flush()
            local line = s2.storage.readEscrow(c.id)[1]
            truthy(s2.escrow.parked(line), 'left for staff')
            eq(#auditRows(s2, 'release_interrupted'), 1, 'and the log names the hitman')

            -- Nothing reached the hitman, so staff hand it back; the client's
            -- credit raises with 2,000 of it there.
            local p = Env.players[1]
            local real = p.Functions.AddMoney
            p.Functions.AddMoney = function(account, _, reason)
                real(account, 2000, reason)
                error('AddMoney hook raised', 0)
            end
            s2.admin.settleLine(0, line.id, 'return')
            p.Functions.AddMoney = real
            local stored = s2.storage.readEscrowLine(line.id)
            truthy(s2.escrow.parked(stored), 'left for staff again')
            eq(stored.owed_to, f.creator.cid)
            eq(s2.admin.interrupted()[1].intended, f.creator.cid)

            local settled, why = s2.admin.settleLine(0, line.id, 'pay')
            truthy(settled, 'refused: ' .. tostring(why))
            eq(money(1) - creator, 5000, 'the rest to the client it is owed to')
            eq(money(3), hitman, 'and nothing to the hitman')
        end)
    end
end)

--- A staff 'delivered' gives nothing, and its only record was a row in the
--- audit queue: a crash inside the flush interval left a settled line that
--- reached nobody, and nothing saying why.
describe('a staff delivered the server stops part-way', function()
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': is recorded on the line itself, wherever it dies', function()
            local kills = 0
            for n = 1, 12 do
                local s, _, _, line, hitman = parkedPayout(mode)
                Env.addPlayer({ source = 7, citizenid = 'STAFF001', license = 'license:st' })
                local died = killBefore(s.storage, n)
                pcall(s.admin.settleLine, 7, line.id, 'delivered')

                local _, s2 = restart(mode, s)
                local stored = s2.storage.readEscrowLine(line.id)
                if stored.state ~= CH.ESCROW_STATE.SETTLED then
                    truthy(s2.escrow.parked(stored), ('died before call %d: no longer left for '
                        .. 'staff'):format(n))
                    eq(#s2.admin.interrupted(), 1)
                    truthy(s2.admin.settleLine(7, line.id, 'delivered'))
                    stored = s2.storage.readEscrowLine(line.id)
                end
                eq(stored.state, CH.ESCROW_STATE.SETTLED)
                eq(stored.settled_by_staff, 'delivered', ('died before call %d: settled with '
                    .. 'nothing given, and nothing on the line says why'):format(n))
                eq(stored.settled_staff, 'STAFF001', 'and by whom')
                truthy(tonumber(stored.settled_at), 'and when')
                eq(money(3), hitman, 'nothing given')

                if not died() then
                    eq(#auditRows(s2, 'admin_settle_line'), 1, 'the log lost it with the process')
                    break
                end
                kills = kills + 1
            end
            truthy(kills >= 2, 'a delivered has to have boundaries to die at')
        end)
    end
end)

--- A buyout handed back (another settle held the contract) whose credit
--- raised with part of it there, and no id left to owe the rest under: the
--- row staff are told by said nothing of the part that arrived, so a hand
--- refund of all of it overpaid by that part.
describe('a buyout hand-back stranded part-way', function()
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': says how much of it arrived', function()
            local _, s = boot(mode)
            local f = fixture(s)
            Env.players[2].PlayerData.money.bank = 100000
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                reward = { baseline = { cash = 5000 } }, bailoutAmount = 15000,
            })
            truthy(c)
            local before = money(2)
            local p = Env.players[2]
            local real = p.Functions.AddMoney
            p.Functions.AddMoney = function(account, _, reason)
                real(account, 6000, reason)
                error('AddMoney hook raised', 0)
            end
            local realNext = s.storage.nextId
            s.storage.nextId = function(prefix)
                if prefix == 'owe' then return nil end
                return realNext(prefix)
            end
            local ok, why = s.contracts.serialized({ 'settle:' .. c.id }, function()
                return s.bailout.buy(f.target, c.id)
            end)
            p.Functions.AddMoney = real
            falsy(ok, 'another settle held it')
            eq(why, CH.ERR.BUSY)
            eq(money(2), before - 15000 + 6000, 'part of it back')

            -- The tick's flush, to the disk.
            s.audit.flush()
            s.storage.flush()
            local _, s2 = restart(mode, s)
            local rows = auditRows(s2, 'bailout_refund_stranded')
            eq(#rows, 1, 'staff are told')
            eq(rows[1].detail.arrived, 6000, 'with the part that arrived, so they hand over '
                .. 'only the rest')
        end)
    end
end)

--- A login retry that finds the pockets still full gives nothing, and it
--- left the line naming whom it was going to: what a restart leaves for
--- staff as a give that may have happened. Every payout still owed at a
--- restart would have waited for staff instead of the player's next login.
describe('a login retry that gives nothing, then a restart', function()
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': is given at the next login, once, wherever it dies', function()
            local kills = 0
            for n = 1, 20 do
                local _, s = boot(mode)
                local f = fixture(s)
                local c = s.contracts.create(f.creator, {
                    targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                    reward = { baseline = { cash = 1000, items = { { name = 'lockpick', count = 2 } } } },
                })
                truthy(c)
                truthy(s.contracts.accept(f.hitman, c.id, false))
                Env.players[3]._inventoryFull = true
                truthy(s.contracts.claimSlot(c.id, f.hitman.cid, CH.FULFILMENT.ELIMINATION, {}))

                -- The login's retry, with no room yet, dies at call n.
                local died = killBefore(s.storage, n)
                pcall(s.escrow.retryPending, f.hitman.cid)
                Env.players[3]._inventoryFull = false

                local _, s2 = restart(mode, s)
                for _ = 1, 3 do s2.escrow.retryPending(f.hitman.cid) end
                local stuck = s2.admin.interrupted()
                if #stuck > 0 then
                    -- Caught naming the hitman before it was known that
                    -- nothing moved: left for staff, whose pay gives it.
                    eq(lockpicks(3), 0, ('died before call %d: given and left for staff')
                        :format(n))
                    truthy(s2.admin.settleLine(0, stuck[1].line, 'pay'))
                end
                eq(lockpicks(3), 2, ('died before call %d: not given once'):format(n))
                if not died() then
                    eq(#stuck, 0, 'a give that moved nothing was left for staff')
                    break
                end
                kills = kills + 1
            end
            truthy(kills >= 4, 'a retry has to have boundaries to die at')
        end)
    end
end)

--- A login retry whose credit raised with 2,000 of a 5,000 payout there,
--- and the process died before the line recorded it: the next start left
--- it for staff knowing nothing of the 2,000, and `pay` gave the hitman
--- 7,000 from a 5,000 line. A balance across a restart cannot say what
--- arrived, so staff check, and give exactly what is missing.
describe('a give the server stopped after part of it arrived', function()
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': is flagged for staff, and paid exactly the rest', function()
            local _, s = boot(mode)
            local f = fixture(s)
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                reward = { baseline = { cash = 5000 } },
            })
            truthy(c)
            truthy(s.contracts.accept(f.hitman, c.id, false))
            local away = Env.players[3]
            Env.removePlayer(3)
            truthy(s.contracts.claimSlot(c.id, f.hitman.cid, CH.FULFILMENT.ELIMINATION, {}))
            Env.players[3], Env.byCitizen[f.hitman.cid] = away, 3
            local hitman = money(3)

            -- The login's retry: 2,000 is credited and the hook raises, and
            -- the process dies before the line records what arrived.
            local p = Env.players[3]
            local real = p.Functions.AddMoney
            p.Functions.AddMoney = function(account, _, reason)
                real(account, 2000, reason)
                error('AddMoney hook raised', 0)
            end
            killBefore(s.storage, 1, function(name, _, lines)
                return name == 'writeEscrow' and type(lines) == 'table' and lines[1] ~= nil
                    and lines[1].deliver_before ~= nil
            end)
            falsy(pcall(s.escrow.retryPending, f.hitman.cid))
            p.Functions.AddMoney = real
            eq(money(3) - hitman, 2000, 'part of it arrived')

            local _, s2 = restart(mode, s)
            s2.audit.flush()
            local line = s2.storage.readEscrow(c.id)[1]
            truthy(s2.escrow.parked(line), 'left for staff')
            eq(line.deliver_arrived, nil, 'knowing nothing of what arrived')

            Env.commands = {}
            require('crimson-hitman.server.bridges').installCommands(s2)
            Env.chat = {}
            Env.aces[3] = { ['crimson.admin'] = true }
            truthy(pcall(Env.commands[Config.Admin.Commands.stuck], 3, {}))
            local out = {}
            for _, row in ipairs(Env.chat) do out[#out + 1] = row.text end
            out = table.concat(out, '\n')
            truthy(out:find(('check what they received, then pay the rest with /%s %s pay <amount>')
                :format(Config.Admin.Commands.settle, line.id), 1, true), out)

            -- What staff do: find 2,000 there, and give the 3,000 missing.
            truthy(s2.admin.settleLine(0, line.id, 'pay', '3000'))
            eq(money(3) - hitman, 5000, 'the line, once')
            for _ = 1, 3 do s2.escrow.retryPending(f.hitman.cid) end
            eq(money(3) - hitman, 5000)
            eq(select(2, s2.admin.settleLine(0, line.id, 'pay')), CH.ERR.ALREADY_SETTLED)

            local _, s3 = restart(mode, s2)
            local stored = s3.storage.readEscrowLine(line.id)
            eq(stored.state, CH.ESCROW_STATE.SETTLED)
            eq(tonumber(stored.deliver_arrived), 2000, 'the part staff found is on the line')
            local rows = auditRows(s3, 'admin_settle_line')
            eq(#rows, 1)
            eq(rows[1].detail.amount, 3000, 'and the amount in the log')
        end)
    end
end)

--- Staff settling a payout left for staff reset its raise count before the
--- release claimed it, and a raise in between (a dropped connection) left it
--- held, owed, queued for nobody and no longer left for staff: given by
--- nothing, and listed by nothing, until the next restart.
describe('a staff pay that raises before its release claims the line', function()
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': leaves it left for staff and listed, and pays it once', function()
            local s, f, _, line, hitman = parkedPayout(mode)
            local claim = s.storage.claimEscrowLine
            s.storage.claimEscrowLine = function() error('connection lost', 0) end
            local ran, ok, err = pcall(s.admin.settleLine, 0, line.id, 'pay')
            s.storage.claimEscrowLine = claim
            truthy(ran, 'answered rather than raised: ' .. tostring(ok))
            falsy(ok)
            eq(err, 'raised')

            truthy(s.escrow.parked(s.storage.readEscrowLine(line.id)), 'still left for staff')
            eq(#s.admin.interrupted(), 1, 'and listed')
            for _ = 1, 3 do s.escrow.retryPending(f.hitman.cid) end
            eq(money(3), hitman, 'given by nothing meanwhile')
            truthy(s.admin.settleLine(0, line.id, 'pay'))
            eq(money(3) - hitman, 5000, 'paid once')
        end)
    end
end)

--- Two staff settle one line left for staff, and on mysql the second's
--- read is an await before its claim. A pays 3,000 to a hitman who is away
--- (queued, 2,000 counted as already with them); B's `pay 1000`, read
--- before A's settle, claimed the queued line and counted 4,000 as arrived:
--- the hitman got 1,000 of the 3,000 A found missing, and B's row said the
--- line owed 5,000 when it owed 3,000.
describe('two staff settling one line left for staff at once', function()
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': the one read before the other queued it is refused, and moves nothing', function()
            local s, f, c, line, hitman = parkedPayout(mode)
            local away = Env.players[3]
            Env.removePlayer(3)

            local claim, fired, first = s.storage.claimEscrowLine, false, nil
            s.storage.claimEscrowLine = function(id, from, to)
                if not fired and from == CH.ESCROW_STATE.HELD then
                    fired = true
                    first = { s.admin.settleLine(0, line.id, 'pay', '3000') }
                end
                return claim(id, from, to)
            end
            local ok, err, whose = s.admin.settleLine(0, line.id, 'pay', '1000')
            s.storage.claimEscrowLine = claim
            truthy(fired, 'A never landed between B\'s read and its claim')
            truthy(first[1])
            eq(first[2], 'queued', 'A: queued for the hitman, who is away')
            falsy(ok, 'B is refused')
            eq(err, 'already_queued')
            eq(whose, f.hitman.cid)
            eq(tonumber(s.storage.readEscrowLine(line.id).deliver_arrived), 2000,
                'what A found already with them, and nothing on top')

            Env.players[3], Env.byCitizen[f.hitman.cid] = away, 3
            for _ = 1, 3 do s.escrow.retryPending(f.hitman.cid) end
            eq(money(3) - hitman, 3000, 'the 3,000 A found missing, once')

            local _, s2 = restart(mode, s)
            eq(s2.storage.readEscrowLine(line.id).state, CH.ESCROW_STATE.SETTLED)
            eq(#auditRows(s2, 'admin_settle_line'), 2, 'both asked, on the record')
            local refused, given
            for _, row in ipairs(auditRows(s2, 'admin_settle_result')) do
                if row.detail.refused then refused = row else given = row end
            end
            truthy(refused, 'B\'s refusal is on the record')
            eq(refused.detail.refused, 'queued')
            eq(refused.detail.owed, 3000, 'what the line owed as B claimed it')
            eq(given.detail.owed, 5000, 'and as A claimed it')
            eq(given.detail.given, 0, 'A gave nothing then: the hitman was away')
            local _ = c
        end)
    end
end)

--- The settle's row was written after the release returned, so a process
--- that died inside the release took with it the only record that staff
--- had settled the line, and for how much.
describe('a staff pay the server stops inside its release', function()
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': is on the record from before anything moved', function()
            local s, _, _, line, hitman = parkedPayout(mode)
            Env.addPlayer({ source = 7, citizenid = 'STAFF001', license = 'license:st' })
            killBefore(s.storage, 1, function(name) return name == 'settleEscrowLine' end)
            pcall(s.admin.settleLine, 7, line.id, 'pay', '5000')
            eq(money(3) - hitman, 5000, 'given before the process died')

            local _, s2 = restart(mode, s)
            local rows = auditRows(s2, 'admin_settle_line')
            eq(#rows, 1, 'the log lost it with the process')
            eq(rows[1].actor_cid, 'STAFF001')
            eq(rows[1].detail.amount, 5000)
            eq(rows[1].detail.owed, 5000)

            truthy(s2.escrow.parked(s2.storage.readEscrowLine(line.id)), 'left for staff')
            eq(#s2.admin.interrupted(), 1, 'and listed')
            truthy(s2.admin.settleLine(0, line.id, 'delivered'))
            eq(money(3) - hitman, 5000, 'once')
        end)
    end
end)

--- A release that raised after its claim (here qbx_core's lookup inside
--- Escrow.deliver) left its line `releasing`: no login retry takes a line
--- another pass has, nothing settles or puts it back until the next start,
--- and /ch-stuck listed nothing.
describe('a line a raise left releasing on the running server', function()
    for _, mode in ipairs({ 'memory', 'json', 'mysql' }) do
        it(mode .. ': is listed once nothing holds it, and settled once', function()
            local _, s = boot(mode)
            local f = fixture(s)
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                reward = { baseline = { cash = 5000 } },
            })
            truthy(c)
            truthy(s.contracts.accept(f.hitman, c.id, false))
            local line = s.storage.readEscrow(c.id)[1]
            local hitman = money(3)

            local qbx = exports.qbx_core
            local real, during = qbx.GetPlayerByCitizenId, nil
            qbx.GetPlayerByCitizenId = function()
                during = s.admin.interrupted(0)
                error('qbx_core raised', 0)
            end
            local ran = pcall(s.escrow.release, c.id, f.hitman.cid, { line = line.id }, 'test')
            qbx.GetPlayerByCitizenId = real
            falsy(ran, 'the release raised')
            truthy(during, 'the release reached the give')
            eq(#during, 0, 'not listed while its release still holds it')
            eq(s.storage.readEscrowLine(line.id).state, CH.ESCROW_STATE.RELEASING)

            local rows = s.admin.interrupted(0)
            eq(#rows, 1, 'listed once nothing holds it')
            eq(rows[1].line, line.id)
            eq(rows[1].why, 'releasing')
            eq(rows[1].intended, f.hitman.cid)
            falsy(s.escrow.inFlight(line.id), 'held by nothing')

            for _ = 1, 3 do s.escrow.retryPending(f.hitman.cid) end
            eq(money(3), hitman, 'given by nothing meanwhile')

            -- Nothing reached them (the raise came looking them up), so pay.
            truthy(s.admin.settleLine(0, line.id, 'pay'))
            eq(money(3) - hitman, 5000)
            eq(s.storage.readEscrowLine(line.id).state, CH.ESCROW_STATE.SETTLED)
            eq(#s.admin.interrupted(0), 0)
        end)
    end
end)

--- Staff `delivered` claimed its line outside the set of claims in flight.
--- A `pay` landing while it waited on the store found the line `releasing`
--- with nothing seeming to hold it, put that live claim back as a stuck line
--- (Escrow.parkStuck), and paid it: 5,000 given for a payout staff had just
--- found already with the hitman. Where the pay's give ran while the
--- delivered settled, both staff were told the line was settled.
describe('a staff delivered racing a staff pay', function()
    for _, mode in ipairs({ 'memory', 'json', 'mysql' }) do
        it(mode .. ': the pay landing inside the delivered\'s claim is refused', function()
            local s, _, _, line, hitman = parkedPayout(mode)
            local claim, fired, paid = s.storage.claimEscrowLine, false, nil
            s.storage.claimEscrowLine = function(id, from, to)
                local out = claim(id, from, to)
                if not fired and id == line.id and from == CH.ESCROW_STATE.HELD then
                    fired = true
                    paid = { s.admin.settleLine(0, line.id, 'pay') }
                end
                return out
            end
            local ok, err = s.admin.settleLine(0, line.id, 'delivered')
            s.storage.claimEscrowLine = claim
            truthy(fired, 'the pay never landed inside the delivered')
            falsy(paid[1], 'the pay went ahead under the delivered\'s claim')
            eq(paid[2], CH.ERR.LOCKED)
            truthy(ok, tostring(err))
            eq(money(3), hitman, 'given for a payout staff found already there')
            local stored = s.storage.readEscrowLine(line.id)
            eq(stored.state, CH.ESCROW_STATE.SETTLED)
            eq(stored.settled_by_staff, 'delivered')
            falsy(s.escrow.inFlight(line.id))
            s.audit.flush()
            eq(#auditRows(s, 'escrow_settle_lost'), 0)
        end)

        it(mode .. ': a pay whose give would run while the delivered settles is refused', function()
            local s, _, _, line, hitman = parkedPayout(mode)
            local p = Env.players[3]
            local add, claim = p.Functions.AddMoney, s.storage.claimEscrowLine
            local a, b
            s.storage.claimEscrowLine = function(id, from, to)
                local out = claim(id, from, to)
                if coroutine.running() == a and id == line.id and from == CH.ESCROW_STATE.HELD then
                    coroutine.yield('claimed')
                end
                return out
            end
            p.Functions.AddMoney = function(...)
                if coroutine.running() == b then coroutine.yield('giving') end
                return add(...)
            end
            local delivered, paid
            a = coroutine.create(function() delivered = { s.admin.settleLine(0, line.id, 'delivered') } end)
            b = coroutine.create(function() paid = { s.admin.settleLine(0, line.id, 'pay') } end)
            local ranA, stepA = coroutine.resume(a)
            local ranB, stepB = coroutine.resume(b)
            local ranA2, stepA2 = coroutine.resume(a)
            local ranB2, stepB2 = true, nil
            if coroutine.status(b) ~= 'dead' then ranB2, stepB2 = coroutine.resume(b) end
            s.storage.claimEscrowLine, p.Functions.AddMoney = claim, add
            truthy(ranA, tostring(stepA))
            eq(stepA, 'claimed', 'the delivered never reached its claim')
            truthy(ranB, tostring(stepB))
            truthy(ranA2, tostring(stepA2))
            truthy(ranB2, tostring(stepB2))
            eq(coroutine.status(a), 'dead')
            eq(coroutine.status(b), 'dead')

            truthy(delivered[1], tostring(delivered[2]))
            falsy(paid[1], 'both staff were told the line was settled')
            eq(paid[2], CH.ERR.LOCKED)
            eq(money(3), hitman, 'nothing given for a payout called delivered')
            local stored = s.storage.readEscrowLine(line.id)
            eq(stored.state, CH.ESCROW_STATE.SETTLED)
            eq(stored.settled_by_staff, 'delivered')
            s.audit.flush()
            eq(#auditRows(s, 'escrow_settle_lost'), 0)
        end)
    end
end)

--- A write-ahead split voided at boot (Escrow.recoverOwed) was claimed
--- outside the set of claims in flight, so /ch-stuck listed it as stuck
--- `releasing` while it was being settled, and a /ch-settle put it back.
describe('a split voided while staff look at it', function()
    for _, mode in ipairs({ 'memory', 'json', 'mysql' }) do
        it(mode .. ': is held in flight, and settled', function()
            local _, s = boot(mode)
            local stake = { id = 'ct00000009:1', contract_id = 'ct00000009', slot = 0,
                portion = CH.PORTION.STAKE, staker = 'HITMAN01', source = 'bank',
                amount = 2000, state = CH.ESCROW_STATE.HELD }
            local owed = { id = 'owe00000009', contract_id = 'ct00000009', slot = 0,
                portion = CH.PORTION.OWED, owed_to = 'HITMAN01', source = 'bank',
                amount = 1000, state = CH.ESCROW_STATE.HELD,
                metadata = { splitFrom = stake.id, stakeWas = 2000, stakeNow = 1000 } }
            s.storage.writeEscrow('ct00000009', { stake, owed })

            local claim, during = s.storage.claimEscrowLine, nil
            s.storage.claimEscrowLine = function(id, from, to)
                local out = claim(id, from, to)
                if not during and id == owed.id and from == CH.ESCROW_STATE.HELD then
                    during = { listed = s.admin.interrupted(0), inFlight = s.escrow.inFlight(id),
                               parked = s.escrow.parkStuck(id) }
                end
                return out
            end
            s.escrow.recoverOwed(s.storage.readEscrow('ct00000009'))
            s.storage.claimEscrowLine = claim
            truthy(during, 'the split was never claimed')
            truthy(during.inFlight, 'claimed outside the set of claims in flight')
            eq(#during.listed, 0, 'listed as stuck while it was being settled')
            falsy(during.parked, 'put back under its own claim')
            local stored = s.storage.readEscrowLine(owed.id)
            eq(stored.state, CH.ESCROW_STATE.SETTLED)
            eq(stored.amount, 0)
            falsy(s.escrow.inFlight(owed.id))
            eq(#s.storage.readPending('HITMAN01'), 0)
        end)
    end
end)

--- claimSlot owes a collection's lines to the hitman before its release
--- claims them. In that moment /ch-stuck listed the payout as owed and in
--- no retry queue, and a staff `return` landing there handed the hitman's
--- 5,000 to the client while the claim reported success. Outside it, a
--- `return` on a payout that only lost its queue entry did the same.
describe('a staff settle of a payout its claim has just owed', function()
    local function claimable(mode)
        local _, s = boot(mode)
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        return s, f, c, s.storage.readEscrow(c.id)[1]
    end

    for _, mode in ipairs({ 'memory', 'json', 'mysql' }) do
        it(mode .. ': is not left for staff while the claim runs, and nothing is handed back', function()
            local s, f, c, line = claimable(mode)
            local hitman, creator = money(3), money(1)
            local write, during = s.storage.writeEscrow, nil
            s.storage.writeEscrow = function(id, lines)
                local out = write(id, lines)
                if not during and id == c.id and type(lines) == 'table' and lines[1]
                    and lines[1].id == line.id and lines[1].owed_to == f.hitman.cid then
                    during = {
                        state = s.storage.readContract(c.id).state,
                        listed = s.admin.interrupted(0),
                        returned = { s.admin.settleLine(0, line.id, 'return') },
                        delivered = { s.admin.settleLine(0, line.id, 'delivered') },
                        paid = { s.admin.settleLine(0, line.id, 'pay') },
                    }
                end
                return out
            end
            local ok, err = s.contracts.claimSlot(c.id, f.hitman.cid, CH.FULFILMENT.ELIMINATION, {})
            s.storage.writeEscrow = write
            truthy(during, 'nothing landed between the claim owing the payout and paying it')
            eq(during.state, CH.STATE.COMPLETING)
            truthy(ok, tostring(err))
            eq(money(1), creator, 'the hitman\'s payout was handed back to the client')
            falsy(during.returned[1])
            eq(during.returned[2], CH.ERR.LOCKED)
            eq(#during.listed, 0, '/ch-stuck listed a payout its claim was about to pay')
            falsy(during.delivered[1])
            eq(during.delivered[2], CH.ERR.LOCKED)
            falsy(during.paid[1])
            eq(during.paid[2], CH.ERR.LOCKED)
            eq(money(3) - hitman, 5000, 'paid by its claim')
            eq(s.storage.readEscrowLine(line.id).state, CH.ESCROW_STATE.SETTLED)
        end)

        it(mode .. ': one that lost its queue entry is paid to its hitman, never handed back', function()
            local s, f, c, line = claimable(mode)
            local hitman, creator = money(3), money(1)
            local away = Env.players[3]
            Env.removePlayer(3)
            truthy(s.contracts.claimSlot(c.id, f.hitman.cid, CH.FULFILMENT.ELIMINATION, {}))
            local entries = s.storage.readPending(f.hitman.cid)
            eq(#entries, 1, 'queued for the hitman, who is away')
            s.storage.clearPending(entries[1].id)

            local rows = s.admin.interrupted(0)
            eq(#rows, 1)
            eq(rows[1].why, 'unqueued')
            local ok, err, whose = s.admin.settleLine(0, line.id, 'return')
            falsy(ok, 'an earned payout handed back to the client')
            eq(err, 'pay_only')
            eq(whose, f.hitman.cid)
            ok, err = s.admin.settleLine(0, line.id, 'delivered')
            falsy(ok, 'settled as delivered with nothing given')
            eq(err, 'pay_only')
            eq(money(1), creator)

            local paid, note, why = s.admin.settleLine(0, line.id, 'pay')
            truthy(paid)
            eq(note, 'queued')
            eq(why, 'away')
            Env.players[3], Env.byCitizen[f.hitman.cid] = away, 3
            s.escrow.retryPending(f.hitman.cid)
            eq(money(3) - hitman, 5000, 'given to the hitman at their login')
            eq(money(1), creator)
            eq(s.storage.readEscrowLine(line.id).state, CH.ESCROW_STATE.SETTLED)
            local _ = c
        end)
    end
end)

--- A contract a throw left unplaced is handed back by the tick
--- (Contracts.retryStuckCreates). Its lines found `releasing` were put back
--- as stuck whatever held them, so a staff return giving one at that moment
--- had its claim put back under it: given, left for staff, and paid again
--- by the next settle.
describe('a never-placed contract handed back while a staff return gives it', function()
    for _, mode in ipairs({ 'memory', 'json', 'mysql' }) do
        it(mode .. ': leaves the live claim alone, and it is given once', function()
            local _, s = boot(mode)
            local f = fixture(s)
            local before = money(1)
            local writeContract, readContract = s.storage.writeContract, s.storage.readContract
            local armed = false
            s.storage.writeContract = function() armed = true; error('connection lost', 0) end
            s.storage.readContract = function(...)
                if armed then armed = false; error('connection lost', 0) end
                return readContract(...)
            end
            falsy(pcall(s.contracts.create, f.creator, {
                targetCid = 'TARGET01', reason = 'y', reward = { baseline = { bank = 7000 } },
            }))
            s.storage.writeContract, s.storage.readContract = writeContract, readContract
            eq(money(1), before - 7000, 'taken')
            local line = s.storage.orphanEscrow()[1]
            truthy(line, 'held for a contract never placed')

            local p = Env.players[1]
            local add, fired = p.Functions.AddMoney, false
            p.Functions.AddMoney = function(...)
                if not fired then
                    fired = true
                    s.contracts.retryStuckCreates()
                end
                return add(...)
            end
            local ok, err = s.admin.settleLine(0, line.id, 'return')
            p.Functions.AddMoney = add
            truthy(fired, 'the hand-back never ran during the give')
            truthy(ok, tostring(err))
            eq(money(1), before, 'given back once')
            local stored = s.storage.readEscrowLine(line.id)
            eq(stored.state, CH.ESCROW_STATE.SETTLED, 'its claim was put back under it')
            falsy(s.escrow.parked(stored))
            eq(#s.admin.interrupted(0), 0, 'left for staff to pay again')
            s.audit.flush()
            eq(#auditRows(s, 'escrow_settle_lost'), 0)
        end)
    end
end)

--- A payout whose give the server stopped: its line `releasing`, naming the
--- hitman, with nothing given (a raise right after the line named them), and
--- its contract left COMPLETING. What a crash at that point leaves on disk,
--- and on the running server a line no call holds any more.
local function stoppedGiving(mode)
    local main, s = boot(mode)
    local f = fixture(s)
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 } },
    })
    truthy(c)
    truthy(s.contracts.accept(f.hitman, c.id, false))
    local line = s.storage.readEscrow(c.id)[1]
    local write = s.storage.writeEscrow
    s.storage.writeEscrow = function(id, lines)
        local out = write(id, lines)
        if type(lines) == 'table' and lines[1] and lines[1].id == line.id and lines[1].releasing_to then
            s.storage.writeEscrow = write
            error('process killed', 0)
        end
        return out
    end
    local hitman = money(3)
    falsy(pcall(s.contracts.claimSlot, c.id, f.hitman.cid, CH.FULFILMENT.ELIMINATION, {}))
    s.storage.writeEscrow = write
    local stored = s.storage.readEscrowLine(line.id)
    eq(stored.state, CH.ESCROW_STATE.RELEASING)
    eq(stored.releasing_to, f.hitman.cid)
    falsy(s.escrow.inFlight(line.id))
    eq(money(3), hitman, 'nothing given')
    return main, s, f, c, line, hitman
end

--- Staff commands are registered before boot recovery runs, and on mysql it
--- waits on the store at every step. A `/ch-settle <line> pay` typed while it
--- had read a line `releasing` and not yet put it back put the line back
--- itself (Escrow.parkStuck: nothing in flight held it), and gave it; recovery
--- then put back the pay's live claim from what it had read, queued it again,
--- and the hitman's login gave it a second time: 10,000 from a 5,000 line,
--- while staff were told "Line settled". json and mysql boot again on the
--- same disk; memory, which keeps nothing across a boot, runs recovery as the
--- boot does (App.ready down until it has finished) on the stack it has.
describe('a staff settle typed while boot recovery runs', function()
    for _, mode in ipairs({ 'memory', 'json', 'mysql' }) do
        it(mode .. ': is refused until recovery has finished, and the line is paid once', function()
            local main, s, f, c, line, hitman = stoppedGiving(mode)

            local store, app
            if mode == 'memory' then
                store, app = s.storage, s.app
            else
                rawset(s.storage, '__rawFixture', true)
                forgetServerModules()
                Env.events, Env.clientEvents, Env.notifications = {}, {}, {}
                Env.handlers, Env.threads, Env.timers, Env.commands = {}, {}, {}, {}
                Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
                Config.Database.Mode = mode
                store = require('server.storage.' .. mode)
            end

            local claim, settle = store.claimEscrowLine, store.settleEscrowLine
            local a, b, s2
            store.claimEscrowLine = function(id, from, to)
                if coroutine.running() == a and id == line.id and from == CH.ESCROW_STATE.RELEASING then
                    coroutine.yield('putting back')
                end
                return claim(id, from, to)
            end
            store.settleEscrowLine = function(...)
                if coroutine.running() == b then coroutine.yield('settling') end
                return settle(...)
            end
            a = coroutine.create(function()
                if mode == 'memory' then
                    app.ready = false
                    main.recover()
                    app.ready = true
                    s2 = s
                else
                    s2 = require('server.main').start()
                end
            end)
            b = coroutine.create(function()
                Env.commands[Config.Admin.Commands.settle](0, { line.id, 'pay' })
                Env.commands[Config.Admin.Commands.void](0, { c.id, 'during recovery' })
                Env.commands[Config.Admin.Commands.stuck](0, {})
            end)

            local ranA, stepA = coroutine.resume(a)
            Env.console = {}
            local ranB, stepB = coroutine.resume(b)
            local said = table.concat(Env.console, '\n')
            local ranA2, stepA2 = coroutine.resume(a)
            local ranB2, stepB2 = true, nil
            if coroutine.status(b) ~= 'dead' then ranB2, stepB2 = coroutine.resume(b) end
            store.claimEscrowLine, store.settleEscrowLine = claim, settle
            truthy(ranA, tostring(stepA))
            eq(stepA, 'putting back', 'recovery never reached the line')
            truthy(ranB, tostring(stepB))
            truthy(ranA2, tostring(stepA2))
            truthy(ranB2, tostring(stepB2))
            eq(coroutine.status(a), 'dead')
            truthy(s2, 'the boot finished')

            local _, recovering = said:gsub('Still recovering from the restart', '')
            eq(recovering, 3, 'settle, void and stuck all wait for recovery: ' .. said)
            falsy(said:find('Line settled', 1, true), said)
            eq(money(3), hitman, 'nothing given while recovery ran')

            -- The hitman's login, then staff settle whatever is listed.
            s2.escrow.retryPending(f.hitman.cid)
            local rows = s2.admin.interrupted(0)
            eq(#rows, 1, 'left for staff')
            eq(rows[1].line, line.id)
            truthy(s2.admin.settleLine(0, line.id, 'pay'))
            for _ = 1, 3 do s2.escrow.retryPending(f.hitman.cid) end
            eq(money(3) - hitman, 5000, 'the line, once')
            eq(s2.storage.readEscrowLine(line.id).state, CH.ESCROW_STATE.SETTLED)
            s2.audit.flush()
            eq(#auditRows(s2, 'escrow_settle_lost'), 0)
        end)
    end
end)

--- And should one run anyway: recovery puts a line back only through the
--- claims in flight (Escrow.putBackStuck), holding it while it does. A staff
--- pay that put the line back and claimed it before recovery reached it
--- keeps its claim, and the give it made is the only one; one landing while
--- recovery puts it back is refused as locked. Put back from recovery's own
--- read instead, the pay's live claim went back to held under it: its settle
--- was lost, and the line was given again. Run on the running stack, where
--- nothing holds staff back (App.ready).
describe('boot recovery and a staff pay on the same line', function()
    for _, mode in ipairs({ 'memory', 'json', 'mysql' }) do
        for _, order in ipairs({ 'pay first', 'recovery first' }) do
            it(mode .. ', ' .. order .. ': neither undoes the other, and the line is paid once', function()
                local main, s, f, _, line, hitman = stoppedGiving(mode)
                local claim, settle = s.storage.claimEscrowLine, s.storage.settleEscrowLine
                local a, b
                -- Pay first: recovery runs whole while the pay waits to
                -- settle. Recovery first: the pay lands while recovery waits
                -- to put the line back.
                s.storage.claimEscrowLine = function(id, from, to)
                    if order == 'recovery first' and coroutine.running() == a and id == line.id
                        and from == CH.ESCROW_STATE.RELEASING then
                        coroutine.yield('putting back')
                    end
                    return claim(id, from, to)
                end
                s.storage.settleEscrowLine = function(...)
                    if coroutine.running() == b then coroutine.yield('settling') end
                    return settle(...)
                end
                a = coroutine.create(function() main.recover() end)
                b = coroutine.create(function() s.admin.settleLine(0, line.id, 'pay') end)
                local first, second = b, a
                if order == 'recovery first' then first, second = a, b end
                local steps = {}
                for _, co in ipairs({ first, second, first, second }) do
                    if coroutine.status(co) ~= 'dead' then
                        local ran, step = coroutine.resume(co)
                        truthy(ran, tostring(step))
                        steps[#steps + 1] = step
                    end
                end
                s.storage.claimEscrowLine, s.storage.settleEscrowLine = claim, settle
                eq(coroutine.status(a), 'dead')
                eq(coroutine.status(b), 'dead')
                eq(steps[1], order == 'pay first' and 'settling' or 'putting back',
                    'the interleaving has to happen, or this measures nothing')

                -- The hitman's logins, then staff pay whatever is listed.
                for _ = 1, 3 do s.escrow.retryPending(f.hitman.cid) end
                for _, row in ipairs(s.admin.interrupted(0)) do s.admin.settleLine(0, row.line, 'pay') end
                for _ = 1, 3 do s.escrow.retryPending(f.hitman.cid) end
                eq(money(3) - hitman, 5000, 'the line, once')
                eq(s.storage.readEscrowLine(line.id).state, CH.ESCROW_STATE.SETTLED)
                s.audit.flush()
                eq(#auditRows(s, 'escrow_settle_lost'), 0, 'a pay\'s claim put back under it')
            end)
        end
    end
end)

--- A held line owed to nobody on a live contract is that contract's own: the
--- collection a hitman is about to claim. /ch-settle handed it back to the
--- client on request, with or without a claim running, and the claim then
--- succeeded paying the hitman nothing.
describe('a staff settle of a line of a live contract', function()
    local function accepted(mode)
        local _, s = boot(mode)
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        return s, f, c, s.storage.readEscrow(c.id)[1]
    end

    for _, mode in ipairs({ 'memory', 'json', 'mysql' }) do
        it(mode .. ': is refused on an accepted contract, which /ch-void closes', function()
            local s, f, c, line = accepted(mode)
            local creator, hitman = money(1), money(3)
            for _, how in ipairs({ 'return', 'pay', 'delivered' }) do
                local ok, err, which = s.admin.settleLine(0, line.id, how)
                falsy(ok, how .. ' on a line of a live contract')
                eq(err, 'live', how)
                eq(which, c.id)
            end
            eq(money(1), creator, 'the hitman\'s collection handed back to the client')

            Env.console = {}
            Env.commands[Config.Admin.Commands.settle](0, { line.id, 'return' })
            local said = table.concat(Env.console, '\n')
            truthy(said:find(('/%s %s'):format(Config.Admin.Commands.void, c.id), 1, true), said)

            truthy(s.contracts.claimSlot(c.id, f.hitman.cid, CH.FULFILMENT.ELIMINATION, {}))
            eq(money(3) - hitman, 5000, 'its claim pays it')
            eq(money(1), creator)
        end)

        -- Anywhere between the claim taking the contract and reading its
        -- escrow; and, on mysql, which hands out copies, up to writing the
        -- marks (memory and json mark the stored line as they read it).
        local points = mode == 'mysql' and { 'readEscrow', 'writeEscrow' } or { 'readEscrow' }
        for _, at in ipairs(points) do
            it(mode .. ': is refused racing the claim (' .. at .. '), and the claim pays it', function()
                local s, f, c, line = accepted(mode)
                local creator, hitman = money(1), money(3)
                local real, during = s.storage[at], nil
                s.storage[at] = function(id, ...)
                    if not during and id == c.id then
                        local now = s.storage.readContract(c.id)
                        if now and now.state == CH.STATE.COMPLETING then
                            during = { state = now.state,
                                       owed = s.storage.readEscrowLine(line.id).owed_to }
                            during.returned = { s.admin.settleLine(0, line.id, 'return') }
                        end
                    end
                    return real(id, ...)
                end
                local ok, err, result = s.contracts.claimSlot(c.id, f.hitman.cid,
                    CH.FULFILMENT.ELIMINATION, {})
                s.storage[at] = real
                truthy(during, 'nothing landed while the claim held the contract')
                eq(during.owed, nil, 'before the claim owed it to the hitman')
                falsy(during.returned[1], 'handed back under the claim')
                eq(during.returned[2], 'live')
                truthy(ok, tostring(err))
                eq(result.settled, 1)
                eq(money(3) - hitman, 5000, 'its claim pays the hitman')
                eq(money(1), creator)
                eq(s.storage.readEscrowLine(line.id).state, CH.ESCROW_STATE.SETTLED)
            end)
        end
    end
end)

--- A claim whose release raised after owing the payout (its queue entry for
--- a hitman who is away, here) leaves the contract COMPLETING until the next
--- start. Read as a claim still paying it, the payout was listed by nothing
--- and /ch-settle answered locked while telling staff to look in /ch-stuck.
describe('a claim that raised after owing its payout', function()
    for _, mode in ipairs({ 'memory', 'json', 'mysql' }) do
        it(mode .. ': is listed as a stalled claim, and pay settles it once', function()
            local _, s = boot(mode)
            local f = fixture(s)
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                reward = { baseline = { cash = 5000 } },
            })
            truthy(c)
            truthy(s.contracts.accept(f.hitman, c.id, false))
            local creator, hitman = money(1), money(3)
            local away = Env.players[3]
            Env.removePlayer(3)
            local queue = s.storage.queuePending
            s.storage.queuePending = function() error('connection lost', 0) end
            falsy(pcall(s.contracts.claimSlot, c.id, f.hitman.cid, CH.FULFILMENT.ELIMINATION, {}))
            s.storage.queuePending = queue
            eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETING, 'left mid-claim')
            local line = s.storage.readEscrow(c.id)[1]
            eq(line.state, CH.ESCROW_STATE.HELD)
            eq(line.owed_to, f.hitman.cid)
            eq(#s.storage.readPending(f.hitman.cid), 0, 'in no queue')

            local rows = s.admin.interrupted(0)
            eq(#rows, 1, 'listed for staff')
            eq(rows[1].line, line.id)
            eq(rows[1].why, 'stalled_claim')
            Env.console = {}
            Env.commands[Config.Admin.Commands.stuck](0, {})
            local said = table.concat(Env.console, '\n')
            truthy(said:find('stalled claim', 1, true), said)
            truthy(said:find(('only /%s %s pay settles it'):format(Config.Admin.Commands.settle, line.id),
                1, true), said)
            falsy(said:find('arrival unknown', 1, true), said)

            -- Nothing of it was given: neither handed back nor called delivered.
            for _, how in ipairs({ 'return', 'delivered' }) do
                local ok, err, whose = s.admin.settleLine(0, line.id, how)
                falsy(ok, how)
                eq(err, 'pay_only', how)
                eq(whose, f.hitman.cid)
            end

            local ok, note, why = s.admin.settleLine(0, line.id, 'pay')
            truthy(ok, tostring(note))
            eq(note, 'queued')
            eq(why, 'away')
            eq(#s.admin.interrupted(0), 0)
            Env.players[3], Env.byCitizen[f.hitman.cid] = away, 3
            for _ = 1, 3 do s.escrow.retryPending(f.hitman.cid) end
            eq(money(3) - hitman, 5000, 'given once, at their login')
            eq(money(1), creator)
            eq(s.storage.readEscrowLine(line.id).state, CH.ESCROW_STATE.SETTLED)
        end)
    end
end)
