--- Persistence, restart and recovery, on the backends that persist.
---
--- Every other suite runs a process that never stops. These boot the real
--- main.lua on json and on the executing mysql simulator, kill it at a chosen
--- point — no onResourceStop, no close(), no tick flush, which is what a
--- crash or a txAdmin restart is — and boot it again on the same disk.

local Exec = require('crimson-bounty.tests.harness.mysql_exec')

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
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            penaltyAmount = penalty,
            reward = { slots = { { baseline = { cash = 1000 } },
                                 { baseline = { cash = 40000 } } } },
        })
        truthy(c, 'a contract with two collections')
        truthy(s.contracts.accept(f.hunter, c.id), 'a hunter')
        local p = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.REDUCE_REWARD, { slot = 2 })
        truthy(p, 'propose giving collection 2 back')
        truthy(s.amendments.respond(f.hunter, p.id, true), 'agreed')
        return main, s, f, c
    end

    for _, mode in ipairs({ 'memory', 'json', 'mysql' }) do
        it(mode .. ': one collection fewer, and the last real one closes it', function()
            local _, s, f, c = givenBack(mode)
            eq(s.storage.readContract(c.id).payout_slots, 1,
                mode .. ': the given-back collection is still on sale')
            truthy(s.contracts.claimSlot(c.id, f.hunter.cid, CB.FULFILMENT.ELIMINATION, {}))
            eq(s.storage.readContract(c.id).state, CB.STATE.COMPLETED,
                mode .. ': the only collection left was paid and the contract stayed open')
        end)
    end

    it('mysql: the hunter who collected it all keeps their stake', function()
        local main, s, f, c = givenBack('mysql', 500)
        local before = money(3)
        truthy(s.contracts.claimSlot(c.id, f.hunter.cid, CB.FULFILMENT.ELIMINATION, {}))
        Env.advance(4 * 3600)
        main.tick()
        eq(money(3) - before, 1000 + 500,
            'left open on an empty collection, the contract ran out and the stake of '
            .. 'the hunter who had collected everything it paid went to the creator')
    end)
end)

describe('a claim landing while another handler holds a copy of the contract', function()
    --- On mysql every read is an await, and eight handlers read the row, work,
    --- and write the whole row back. next_slot was in that write, so a claim
    --- landing in between was undone: the collection just paid went back on
    --- sale and the next hunter to kill the target for it was paid nothing.
    for _, mode in ipairs({ 'memory', 'json', 'mysql' }) do
        it(mode .. ': the collection stays claimed', function()
            local _, s = boot(mode)
            local f = fixture(s)
            Env.players[1].PlayerData.money.bank = 400000
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
                penaltyAmount = 2000,
                reward = { slots = { { baseline = { cash = 10000 } },
                                     { baseline = { cash = 20000 } } } },
            })
            truthy(c)
            truthy(s.contracts.accept(f.hunter, c.id))
            Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd',
                cash = 5000, bank = 5000 })
            truthy(s.contracts.accept(s.identity.resolve(4), c.id))

            -- The creator lowers the stake. It reads the contract, then
            -- adjusts each hunter's stake line — an await apiece — and then
            -- writes the contract back. HUNTER01's kill is claimed in the
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
                    truthy(s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION, {}))
                end
                return realSet(...)
            end
            truthy(s.amendments.improve(f.creator, c.id, CB.AMENDMENT.LOWER_PENALTY, { amount = 1000 }))
            s.storage.setEscrowAmount = realSet
            truthy(claimed, 'the interleaving has to happen, or this measures nothing')

            local slot = s.storage.readContract(c.id).next_slot
            eq(slot, 2, mode .. ': the collection HUNTER01 was paid for is back on sale')

            local before = money(4)
            truthy(s.contracts.claimSlot(c.id, 'HUNTER02', CB.FULFILMENT.ELIMINATION, {}))
            -- The second collection, and the 1,000 stake that comes back
            -- because this claim finishes the contract.
            eq(money(4) - before, 20000 + 1000, mode .. ': HUNTER02 was paid out of an empty slot')
        end)
    end
end)

describe('a crash right after an acceptance (json)', function()
    --- The stake is flushed at once; the hunter row rode the debounce. A
    --- process that died inside the flush interval came back with the stake
    --- on disk and no hunter it belonged to: nothing returns a stake without
    --- its row, and the exclusive contract refused everybody as locked.
    it('keeps the hunter row the stake hangs on', function()
        local _, s = boot('json')
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 10000 } }, penaltyAmount = 2000,
        })
        truthy(c)
        truthy(s.contracts.accept(f.hunter, c.id))

        local _, s2 = restart('json', s)
        local hunters = s2.storage.readHunters(c.id)
        eq(#hunters, 1, 'the stake survived and the hunter who put it up did not')
        eq(hunters[1].hunter_cid, 'HUNTER01')

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
            eq(s2.storage.readContract(c.id).state, CB.STATE.CANCELLED)
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
        it(mode .. ': a stake left on a closed contract goes back to its hunter', function()
            local _, s = boot(mode)
            local f = fixture(s)
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
                reward = { baseline = { cash = 10000 } }, penaltyAmount = 2000,
            })
            truthy(c)
            truthy(s.contracts.accept(f.hunter, c.id))
            local before = money(3)

            -- Staff void it; the process dies before any line moves.
            s.escrow.release = function() error('process killed') end
            falsy(pcall(s.admin.void, 0, c.id, 'x'))

            local _, s2 = restart(mode, s)
            eq(s2.storage.readContract(c.id).state, CB.STATE.VOIDED)
            eq(money(3) - before, 2000, 'the stake went back to the hunter who put it up')
        end)
    end
end)

describe('a crash between paying the last collection and closing', function()
    --- Recovery put every COMPLETING contract back to ACCEPTED. One whose
    --- last collection was already paid came back live with nothing left to
    --- claim, then ran out: the hunter who had collected everything lost
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
            truthy(s.contracts.accept(f.hunter, c.id))
            local before = money(3)

            s.progression.onCompleted = function() error('process killed') end
            falsy(pcall(s.contracts.claimSlot, c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION, {}))
            eq(money(3) - before, 10000, 'the collection was paid before the crash')

            local main2, s2 = restart(mode, s)
            eq(s2.storage.readContract(c.id).state, CB.STATE.COMPLETED,
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
    --- hunter to kill the target for it was paid out of an empty slot.
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': the next kill pays the next collection', function()
            local _, s = boot(mode)
            local f = fixture(s)
            Env.players[1].PlayerData.money.bank = 400000
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
                reward = { slots = { { baseline = { cash = 10000 } },
                                     { baseline = { cash = 20000 } } } },
            })
            truthy(c)
            truthy(s.contracts.accept(f.hunter, c.id))
            Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd' })
            truthy(s.contracts.accept(s.identity.resolve(4), c.id))

            local before = money(3)
            s.storage.advanceSlot = function() error('process killed') end
            falsy(pcall(s.contracts.claimSlot, c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION, {}))
            eq(money(3) - before, 10000, 'the first collection was paid before the crash')

            local _, s2 = restart(mode, s)
            local row = s2.storage.readContract(c.id)
            eq(row.state, CB.STATE.ACCEPTED)
            eq(row.next_slot, 2, mode .. ': the paid collection is back on sale')

            local second = money(4)
            truthy(s2.contracts.claimSlot(c.id, 'HUNTER02', CB.FULFILMENT.ELIMINATION, {}))
            eq(money(4) - second, 20000, 'HUNTER02 was paid out of an empty slot')
            eq(s2.storage.readContract(c.id).state, CB.STATE.COMPLETED)
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
            truthy(s.contracts.accept(f.hunter, c.id))
            local creatorBefore, targetBefore = money(1), money(2)
            truthy(s.bailout.buy(f.target, c.id), 'queued behind the engaged hunter')

            Env.advance(200)
            s.escrow.deliver = function() error('process killed') end
            falsy(pcall(s.bailout.processQueue))

            local main2, s2 = restart(mode, s)
            for _ = 1, 3 do Env.advance(20) main2.tick() end

            local row = s2.storage.readContract(c.id)
            eq(row.state, CB.STATE.BAILED_OUT)
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

describe('server downtime and the deadline', function()
    --- Every contract's clock pauses while either party is offline. While the
    --- server is down everybody is, but a contract nobody had paused only
    --- started pausing at the first tick after the boot — so the downtime was
    --- charged to the deadline, and one that fell due inside it expired the
    --- moment both parties were back, forfeiting the hunter's stake.
    local function nearlyDue(mode)
        local main, s = boot(mode)
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 10000 } }, penaltyAmount = 2000,
        })
        truthy(c)
        truthy(s.contracts.accept(f.hunter, c.id))
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
        eq(s.storage.readContract(c.id).state, CB.STATE.ACCEPTED)
    end)

    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': so does the server being down for half an hour', function()
            local _, s, _, c = nearlyDue(mode)
            local hunterBefore = money(3)

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

            eq(s2.storage.readContract(c.id).state, CB.STATE.ACCEPTED,
                mode .. ': the contract ran out during a restart')
            eq(money(3), hunterBefore, 'and nothing was forfeited')
        end)
    end
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
            truthy(s.contracts.accept(f.hunter, c.id))

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

        it(mode .. ': the ceiling still counts what was bought before', function()
            local _, s = boot(mode)
            Config.Informant.RequireProximity = false
            local f = fixture(s)
            Env.players[2].PlayerData.money.bank = 500000
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x',
                reward = { baseline = { cash = 10000 } },
            })
            truthy(s.contracts.accept(f.hunter, c.id))

            local lock = Config.Informant.RerollLockMinutes * 60 + 1
            for _ = 1, Config.Informant.MaxPurchasesPerContract do
                truthy(s.informant.buy(f.target, c.id))
                Env.advance(lock)
            end
            local before = money(2)

            local _, s2 = restart(mode, s)
            local ok, err = s2.informant.buy(s2.identity.resolve(2), c.id)
            falsy(ok, 'a restart reset the ceiling')
            eq(err, CB.ERR.LIMIT_REACHED)
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
        truthy(s.contracts.accept(f.hunter, c.id))
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
    --- two-hundredth event and /cb-stuck could not see a stuck release.
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

    it('mysql: /cb-stuck finds an interrupted release on a busy contract', function()
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
        local real = s.storage.writeAudit
        local pushed = false
        s.storage.writeAudit = function(entry)
            if not pushed then
                pushed = true
                s.audit.financial('escrow_settle_lost', 'HUNTER01', 'ctX', { line = 'ctX:1' })
            end
            return real(entry)
        end
        s.audit.financial('first', 'A', 'ctX', {})
        s.audit.financial('second', 'A', 'ctX', {})
        s.audit.flush()
        s.storage.writeAudit = real
        s.audit.flush()

        local seen = {}
        for _, row in ipairs(s.storage.auditForContract('ctX', 100)) do
            seen[row.action] = (seen[row.action] or 0) + 1
        end
        eq(seen.escrow_settle_lost, 1, 'the row pushed during the flush was lost')
        eq(seen.first, 1, 'and nothing was written twice')
    end)
end)
