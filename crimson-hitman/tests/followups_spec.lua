--- Regressions in the last round of fixes, each found by following a change
--- to the next reader of what it wrote.

local Exec = require('crimson-hitman.tests.harness.mysql_exec')

--- A full stack whose every module talks to the mysql backend, the one that
--- ships by default. The memory store keeps whatever it is handed, so a
--- column the upsert refuses to update is saved there and nowhere else.
local function mysqlStack()
    local s = newStack()
    Exec.install(Natives)
    package.loaded['crimson-hitman.server.storage.mysql'] = nil
    local store = require('crimson-hitman.server.storage.mysql')
    store.open()
    s.audit.init(store)
    s.escrow.init(store, s.audit)
    s.progression.init({ storage = store, identity = s.identity, audit = s.audit })
    s.contracts.init({ storage = store, escrow = s.escrow, identity = s.identity,
        audit = s.audit, notify = s.notify, progression = s.progression, death = s.death })
    s.photos.init({ storage = store, audit = s.audit })
    s.ledger.init({ storage = store, photos = s.photos, notify = s.notify })
    s.bailout.init({ storage = store, identity = s.identity,
        contracts = s.contracts, escrow = s.escrow, audit = s.audit, notify = s.notify })
    s.death.init({ storage = store, identity = s.identity, contracts = s.contracts, audit = s.audit })
    s.kidnap.init({ storage = store, identity = s.identity, contracts = s.contracts,
        audit = s.audit, notify = s.notify, ledger = s.ledger })
    s.amendments.init({ storage = store, identity = s.identity, contracts = s.contracts,
        escrow = s.escrow, audit = s.audit, notify = s.notify })
    s.projection.init({ storage = store, identity = s.identity, escrow = s.escrow,
        kidnap = s.kidnap, mugshot = s.mugshot, progression = s.progression,
        notify = s.notify })
    s.storage = store
    return s
end

local function money(src)
    local m = Env.players[src].PlayerData.money
    return m.cash + m.bank
end

describe('giving back the last collection, on every backend', function()
    for _, which in ipairs({ 'memory', 'mysql' }) do
        it(which .. ': the count comes down, and the contract ends after the last funded one', function()
            local s = which == 'mysql' and mysqlStack() or newStack()
            local f = fixture(s)
            Env.players[1].PlayerData.money.bank = 400000
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                reward = { slots = { { baseline = { cash = 1000 } }, { baseline = { cash = 2000 } },
                                     { baseline = { cash = 3000 } } } },
                penaltyAmount = 500,
            })
            truthy(c, 'placed')
            truthy(s.contracts.accept(f.hitman, c.id, false))
            local proposal = s.amendments.propose(f.creator, c.id, CH.AMENDMENT.REDUCE_REWARD, { slot = 3 })
            truthy(proposal, 'proposed')
            truthy(s.amendments.respond(f.hitman, proposal.id, true))

            eq(s.storage.readContract(c.id).payout_slots, 2, 'the upsert discarded the new '
                .. 'count, so the emptied collection stayed on sale')

            local before = money(3)
            truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
            Env.advance(Config.Limits.SlotCooldownSeconds + 1)
            truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))

            eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED, 'the contract went on '
                .. 'offering a collection worth nothing, holding the hitman\'s stake behind it')
            eq(money(3) - before, 3500, 'both funded collections, and the stake back')
        end)
    end
end)

describe('coming back to a contract', function()
    it('cannot buy anonymity a named first stint already gave away', function()
        local s = newStack()
        local f = fixture(s)
        Config.Anonymity.HitmanFee = 1000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(s.contracts.accept(f.hitman, c.id, false), 'the first stint, named')
        local seen = s.projection.contract(s.storage.readContract(c.id), 'CREATOR1').hitmen[1]
        eq(seen.name, 'Rook Ash')
        truthy(s.contracts.abandon(f.hitman, c.id))

        local before = money(3)
        Natives.calls.notifications = {}
        truthy(s.contracts.accept(f.hitman, c.id, true), 'back, asking to be anonymous')

        eq(before - money(3), 0, 'charged for anonymity the creator can see straight through: '
            .. 'the same alias and the same thread they were shown with a name')
        local now = s.projection.contract(s.storage.readContract(c.id), 'CREATOR1').hitmen[1]
        eq(now.alias, seen.alias)
        eq(now.name, 'Rook Ash', 'named, as they already were')

        local told = false
        for _, note in ipairs(Natives.calls.notifications) do
            if note.title == 'Not anonymous' then told = true end
        end
        truthy(told, 'and told why')
    end)

    it('is not charged twice for anonymity on the same contract', function()
        local s = newStack()
        local f = fixture(s)
        Config.Anonymity.HitmanFee = 1000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        local start = money(3)
        truthy(s.contracts.accept(f.hitman, c.id, true))
        eq(start - money(3), 1000, 'the first stint pays for it')
        truthy(s.contracts.abandon(f.hitman, c.id))

        -- Nothing left to pay a second fee with.
        Env.players[3].PlayerData.money.cash, Env.players[3].PlayerData.money.bank = 0, 0
        local ok, err = s.contracts.accept(f.hitman, c.id, true)
        truthy(ok, 'refused a contract they were already anonymous on: ' .. tostring(err))
        falsy(s.projection.contract(s.storage.readContract(c.id), 'CREATOR1').hitmen[1].name,
            'and still anonymous')
    end)

    it('tells the page what the server recorded', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        truthy(s.contracts.abandon(f.hitman, c.id))
        truthy(s.contracts.accept(f.hitman, c.id, true), 'back, asking to be anonymous')
        eq(s.projection.contract(s.storage.readContract(c.id), 'HITMAN01').myAnonymous, false,
            'the page said "accepted, anonymously" from the button that was pressed')
        local settings = s.projection.listing('HITMAN01', 1).settings
        eq(settings.anonymityFees.hitman, Config.Anonymity.HitmanFee)
        eq(settings.messageMaxLength, Config.Relay.MaxLength)
    end)

    it('may still come back anonymous after an anonymous stint', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(s.contracts.accept(f.hitman, c.id, true))
        truthy(s.contracts.abandon(f.hitman, c.id))
        truthy(s.contracts.accept(f.hitman, c.id, true))
        falsy(s.projection.contract(s.storage.readContract(c.id), 'CREATOR1').hitmen[1].name)
    end)
end)

local AT = { x = 200.0, y = 200.0, z = 30.0 }
local function together()
    for _, src in ipairs({ 1, 2, 3, 4 }) do
        if Env.players[src] then Env.players[src]._coords = { x = AT.x, y = AT.y, z = AT.z } end
    end
    Env.players[2].PlayerData.metadata.ishandcuffed = true
end

local function ticks(s, seconds)
    for _ = 1, math.ceil((seconds * 1000) / Config.Kidnap.TickMs) do
        s.kidnap.tick(Config.Kidnap.TickMs)
    end
end

local function handover(slots)
    local s = newStack()
    local f = fixture(s)
    Env.players[1].PlayerData.money.bank = 400000
    local list = {}
    for i = 1, slots do list[i] = { baseline = { cash = 1000 * i } } end
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE, reward = { slots = list },
    })
    truthy(s.contracts.accept(f.hitman, c.id, false))
    together()
    return s, f, c
end

describe('a handover that finishes while another payout holds the lock', function()
    it('is paid once the lock lets go, not refused as closed', function()
        local s, f, c = handover(2)
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        ticks(s, Config.Kidnap.CountdownSeconds - 1)

        -- The final tick reads the contract as accepted. By the claim's own
        -- read, another hitman's settlement has the lock: on mysql every
        -- read yields, and another handler runs in the gap.
        local real = s.storage.readContract
        local reads = 0
        s.storage.readContract = function(id)
            reads = reads + 1
            if reads == 2 then
                s.storage.compareSetContractState(id, CH.STATE.ACCEPTED, CH.STATE.COMPLETING)
            end
            return real(id)
        end
        Natives.calls.notifications = {}
        s.kidnap.tick(Config.Kidnap.TickMs)
        s.storage.readContract = real

        for _, note in ipairs(Natives.calls.notifications) do
            truthy(note.title ~= 'Handover not paid', 'told "' .. tostring(note.content)
                .. '" about a contract that still had a payout on it')
        end
        falsy(s.kidnap.outcome(c.id, 'HITMAN01'), 'the delivery was ended')

        -- The other settlement lets go with a payout left.
        truthy(s.contracts.transition(c.id, CH.STATE.COMPLETING, CH.STATE.ACCEPTED, 'slot_claimed'))
        local before = money(3)
        ticks(s, 2)

        eq(s.storage.readContract(c.id).next_slot, 2, 'and it is paid')
        eq(money(3) - before, 1000)
        eq(s.kidnap.outcome(c.id, 'HITMAN01').outcome, 'paid')
    end)

    it('is still refused when the contract really did close', function()
        local s, f, c = handover(1)
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        ticks(s, Config.Kidnap.CountdownSeconds - 1)
        local real = s.storage.readContract
        local reads = 0
        s.storage.readContract = function(id)
            reads = reads + 1
            if reads == 2 then
                -- Closed for real, through the path that settles its escrow.
                truthy(s.contracts.resolve(id, CH.STATE.CANCELLED, 'CREATOR1', nil, 'test'))
            end
            return real(id)
        end
        s.kidnap.tick(Config.Kidnap.TickMs)
        s.storage.readContract = real
        eq(s.kidnap.activeCount(), 0)
        eq(s.kidnap.outcome(c.id, 'HITMAN01').outcome, 'refused')
    end)
end)

describe('a handover re-armed and then walked away from', function()
    it('is not reported as the one before it', function()
        local s, f, c = handover(1)
        s.bridges.install(s)
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        Env.players[2].PlayerData.metadata.ishandcuffed = false
        ticks(s, 5)
        eq(s.kidnap.outcome(c.id, 'HITMAN01').outcome, 'failed', 'the first one failed')

        Env.advance(Config.Kidnap.RearmCooldownSeconds + 1)
        Env.players[2].PlayerData.metadata.ishandcuffed = true
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        ticks(s, 3)
        truthy(s.contracts.abandon(f.hitman, c.id))

        local answer = s.app.handlers.kidnapProgress(f.hitman, { id = c.id })
        falsy(type(answer) == 'table' and answer.done, 'the poller told a hitman who had just '
            .. 'walked away that a handover from a minute earlier had failed')
    end)
end)

describe('owed goods that will not fit, with money queued behind them', function()
    --- A pass tries MaxRetriesPerLogin entries and an entry that cannot be
    --- handed over stays where it was. The mysql store returns the queue
    --- oldest first, so the same goods were tried on every pass and a buyout
    --- premium queued after them was never reached, however many times the
    --- player logged in.
    for _, which in ipairs({ 'memory', 'mysql' }) do
        it(which .. ': the money is reached', function()
            local s = which == 'mysql' and mysqlStack() or newStack()
            local names, inventory = {}, {}
            for i = 1, Config.PendingEscrow.MaxRetriesPerLogin + 1 do
                names[i] = 'goods' .. i
                inventory[i] = { name = names[i], count = 1 }
            end
            local f = fixture(s, { creatorInventory = inventory })
            local items = {}
            for i = 1, #names do items[i] = { name = names[i], count = 1 } end
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', reward = { baseline = { items = items } },
            })
            truthy(c, 'placed')
            truthy(s.contracts.accept(f.hitman, c.id, false))
            Env.players[3]._inventoryFull = true
            truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
            eq(#s.storage.readPending('HITMAN01'), #names, 'every stack owed')
            Env.advance(1)
            truthy(s.bailout.owe('HITMAN01', c.id, 4000, 'bank', 'test'))

            local before = Env.players[3].PlayerData.money.bank
            for _ = 1, 3 do s.escrow.retryPending('HITMAN01') end
            eq(Env.players[3].PlayerData.money.bank - before, 4000,
                'the same goods were tried on every pass and the money behind them never was')
            eq(#s.storage.readPending('HITMAN01'), #names, 'and the goods are still owed')
        end)
    end
end)

describe('the handover countdown thread', function()
    --- Nothing wrapped the tick, so one error killed the thread with its
    --- running flag still set, and Kidnap.start never made another.
    it('keeps counting after one tick throws', function()
        local s, f, c = handover(1)
        local before = #Env.threads
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        eq(#Env.threads - before, 1, 'arming started the countdown thread')

        local realWait, realRead, realPrint = _G.Wait, s.storage.readContract, _G.print
        local thrown = false
        _G.Wait = coroutine.yield
        _G.print = function() end
        s.storage.readContract = function(id)
            if not thrown then
                thrown = true
                error('mysql: connection lost')
            end
            return realRead(id)
        end
        local co = coroutine.create(Env.threads[#Env.threads])
        for _ = 1, Config.Kidnap.CountdownSeconds + 5 do
            if coroutine.status(co) == 'dead' then break end
            coroutine.resume(co)
        end
        _G.Wait, s.storage.readContract, _G.print = realWait, realRead, realPrint

        truthy(thrown, 'the read failed once')
        local outcome = s.kidnap.outcome(c.id, 'HITMAN01')
        eq(outcome and outcome.outcome, 'paid',
            'one failed read stopped every handover on the server for good')
        local _ = f
    end)
end)

describe('two retry passes for one player at once', function()
    --- The tick's online retry and a login's run side by side, and a
    --- release sweep can be mid-delivery too. One pass cleared the queue
    --- entry of a line the other was holding; the other's delivery then
    --- failed, put the line back owed, and nothing queued it again.
    local function owedGoods(s)
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { items = { { name = 'lockpick', count = 2 } } } },
        })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        Env.players[3]._inventoryFull = true
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        eq(#s.storage.readPending('HITMAN01'), 1, 'owed, and queued')
        return f, c
    end

    local function lockpicks()
        local n = 0
        for _, slot in ipairs(Env.players[3]._inventory) do
            if slot.name == 'lockpick' then n = n + slot.count end
        end
        return n
    end

    it('does not lose the queue entry of a line the other pass holds', function()
        local s = mysqlStack()
        owedGoods(s)
        local real = s.storage.claimEscrowLine
        local fired = false
        s.storage.claimEscrowLine = function(id, from, to)
            local ok = real(id, from, to)
            if ok and not fired and to == CH.ESCROW_STATE.RELEASING then
                fired = true
                -- The login's pass, in the tick's wait.
                s.escrow.retryPending('HITMAN01')
            end
            return ok
        end
        s.escrow.retryWaiting(function() return true end)
        s.storage.claimEscrowLine = real
        truthy(fired)
        eq(#s.storage.readPending('HITMAN01'), 1,
            'the entry was cleared under a delivery that then failed')

        Env.players[3]._inventoryFull = false
        for _ = 1, 3 do
            Env.advance(31)
            s.escrow.retryWaiting(function() return true end)
        end
        eq(lockpicks(), 2, 'made room, and the goods never came')
    end)

    it('does not forget a player something was queued for while it ran', function()
        local s = mysqlStack()
        local _, c = owedGoods(s)
        Env.players[3]._inventoryFull = false
        local real = s.storage.readPending
        local calls = 0
        s.storage.readPending = function(cid)
            local answer = real(cid)
            calls = calls + 1
            if calls == 2 then
                -- Answered before this lands: a buyout premium owed to them.
                truthy(s.bailout.owe('HITMAN01', c.id, 4000, 'bank', 'test'))
            end
            return answer
        end
        s.escrow.retryWaiting(function() return true end)
        s.storage.readPending = real
        eq(lockpicks(), 2, 'the first delivery')

        local before = Env.players[3].PlayerData.money.bank
        for _ = 1, 3 do
            Env.advance(31)
            s.escrow.retryWaiting(function() return true end)
        end
        eq(Env.players[3].PlayerData.money.bank - before, 4000,
            'online the whole time, and left for a relog')
    end)
end)

describe('an agreed give-back while the client raises the bonus', function()
    --- The raise writes back a copy of the contract read before its own
    --- awaits. payout_slots was in the mysql upsert, so the count the
    --- give-back had just lowered was written back over it and the emptied
    --- collection went back on sale.
    it('mysql: the count stays down', function()
        local s = mysqlStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { cash = 1000 } }, { baseline = { cash = 2000 } } } },
            bonusPercent = 10,
        })
        truthy(c)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local proposal = s.amendments.propose(f.creator, c.id, CH.AMENDMENT.REDUCE_REWARD, { slot = 2 })
        truthy(proposal)

        local real = s.escrow.take
        local agreed = false
        s.escrow.take = function(...)
            if not agreed then
                agreed = true
                -- One change to the contract at a time (Amendments.apply):
                -- the give-back waits for the raise rather than running
                -- inside it.
                local ok, err, outcome = s.amendments.respond(f.hitman, proposal.id, true)
                falsy(ok, 'the give-back ran inside the raise')
                eq(err, CH.ERR.BUSY)
                eq(outcome, 'busy')
            end
            return real(...)
        end
        s.amendments.improve(f.creator, c.id, CH.AMENDMENT.RAISE_BONUS, { percent = 20 })
        s.escrow.take = real
        truthy(agreed)
        truthy(s.amendments.respond(f.hitman, proposal.id, true), 'the hitman agrees again')
        eq(s.storage.readContract(c.id).payout_slots, 1, 'given back')
        s.amendments.improve(f.creator, c.id, CH.AMENDMENT.RAISE_BONUS, { percent = 30 })
        eq(s.storage.readContract(c.id).payout_slots, 1,
            'the raise wrote its copy back over the give-back')
    end)
end)

describe('a top-up that a payout lands on', function()
    --- The claim moved the slot after the top-up's lines were written and
    --- paid them out with its collection. The hand-back then found nothing
    --- to hand back, and the client was told the top-up had not gone
    --- through while the hitman had the money.
    it('mysql: is reported as added, since it was paid out', function()
        local s = mysqlStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { cash = 1000 } }, { baseline = { cash = 2000 } } } },
        })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local creatorBefore, hitmanBefore = money(1), money(3)

        -- The top-up's own write, which a take makes insert-if-absent.
        local real = s.storage.insertEscrow
        local claimed = false
        s.storage.insertEscrow = function(id, lines)
            local out = real(id, lines)
            if not claimed and lines[1] and lines[1].portion == CH.PORTION.BASELINE then
                claimed = true
                truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
            end
            return out
        end
        local ok, err = s.amendments.addEscrow(f.creator, c.id, { baseline = { cash = 5000 } })
        s.storage.insertEscrow = real
        truthy(claimed)
        eq(money(1) - creatorBefore, -5000)
        eq(money(3) - hitmanBefore, 1000 + 5000, 'the collection, and the top-up with it')
        truthy(ok, 'told the top-up was refused, with a hitman holding it: ' .. tostring(err))
    end)
end)

describe('a top-up a payout queued for the hitman', function()
    --- The claim paid the new line to the hitman, but their pockets were full,
    --- so it was queued for them: still held, owed to them. The hand-back
    --- then released it to the client by name, which overrides who it is
    --- owed to, and the hitman's queued money went to the client.
    for _, slots in ipairs({ 2, 1 }) do
        it(slots .. ' collection(s): stays owed to the hitman', function()
            local s = mysqlStack()
            local f = fixture(s)
            Env.players[1].PlayerData.money.bank = 400000
            local spec = { { baseline = { cash = 1000 } } }
            if slots == 2 then spec[2] = { baseline = { cash = 2000 } } end
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                reward = { slots = spec },
            })
            truthy(s.contracts.accept(f.hitman, c.id, false))
            local creatorBefore = money(1)
            Env.players[3]._refuseMoney = true

            local real = s.storage.insertEscrow
            local claimed = false
            s.storage.insertEscrow = function(id, lines)
                local out = real(id, lines)
                if not claimed and lines[1] and lines[1].portion == CH.PORTION.BASELINE then
                    claimed = true
                    truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
                end
                return out
            end
            local ok, err = s.amendments.addEscrow(f.creator, c.id, { baseline = { cash = 5000 } })
            s.storage.insertEscrow = real
            truthy(claimed)

            local topUp
            for _, line in ipairs(s.storage.readEscrow(c.id)) do
                if line.portion == CH.PORTION.BASELINE and line.amount == 5000 then topUp = line end
            end
            truthy(topUp, 'the top-up line exists')
            eq(topUp.owed_to, 'HITMAN01', 'still owed to the hitman who was paid it')
            falsy(topUp.settled_to == 'CREATOR1', 'and not handed to the client')
            eq(money(1) - creatorBefore, -5000, 'the client paid for it once')
            truthy(ok, 'and is told it went in: ' .. tostring(err))

            -- And it reaches the hitman once they can take it.
            Env.players[3]._refuseMoney = false
            s.escrow.retryPending('HITMAN01')
            eq(s.storage.readEscrowLine(topUp.id).settled_to, 'HITMAN01')
        end)
    end
end)

describe('a top-up handed back while a claim queues it', function()
    --- The hand-back checked each line before releasing it, and the release
    --- itself overrides who a line is owed to. A claim queueing the line for
    --- its hitman between the check and the release lost it to the client.
    it('mysql: leaves it with the hitman it was queued for', function()
        local s = mysqlStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { cash = 1000 } }, { baseline = { cash = 2000 } } } },
        })
        truthy(s.contracts.accept(f.hitman, c.id, false))

        -- The claim lands after the top-up is written, but pays slot 1 from
        -- the lines it read before it: the top-up is left held and unowed on
        -- a collection already paid, so the hand-back picks it.
        local realWrite, realInsert = s.storage.writeEscrow, s.storage.insertEscrow
        local topUp
        s.storage.insertEscrow = function(id, lines)
            local out = realInsert(id, lines)
            if not topUp and lines[1] and lines[1].portion == CH.PORTION.BASELINE
                and lines[1].amount == 500 then
                topUp = lines[1].id
                -- Through the store's own move: a whole-row write leaves the
                -- slot counters alone, and the hand-back never ran.
                truthy(s.storage.advanceSlot(c.id, 1))
            end
            return out
        end
        -- And the racing claim queues it for the hitman just before the
        -- hand-back's release takes it: after every read the hand-back makes
        -- of it, in the await the release's own claim of the line is.
        local realClaim = s.storage.claimEscrowLine
        local queued = false
        s.storage.claimEscrowLine = function(id, from, to)
            if topUp and id == topUp and not queued then
                queued = true
                local line = s.storage.readEscrowLine(topUp)
                line.owed_to = 'HITMAN01'
                realWrite(c.id, { line })
            end
            return realClaim(id, from, to)
        end
        local ok, err = s.amendments.addEscrow(f.creator, c.id, { baseline = { cash = 500 } })
        s.storage.insertEscrow, s.storage.claimEscrowLine = realInsert, realClaim
        truthy(queued, 'the race was run')

        local line = s.storage.readEscrowLine(topUp)
        eq(line.owed_to, 'HITMAN01')
        falsy(line.settled_to == 'CREATOR1', 'handed to the client over the hitman it was queued for')
        truthy(ok, 'queued for the hitman, and the client was told it failed: ' .. tostring(err))
    end)
end)

describe('a bonus raise landing while a claim is paying', function()
    --- A claim part-way through was read as a closed contract: every top-up
    --- went back, the later collections' included, while the raise was
    --- reported applied. Read by its slot instead, the next collection's
    --- top-up went back, since a claim moves the slot on before it lets go,
    --- and a refused claim's collection lost its own. The raise waits for the
    --- claim to finish, and decides on what it did.
    local function placed()
        local s = mysqlStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE, bonusPercent = 10,
            reward = { slots = { { baseline = { cash = 1000 } }, { baseline = { cash = 1000 } },
                                 { baseline = { cash = 1000 } } } },
        })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        return s, f, c
    end

    local function bonusHeld(s, c, slot)
        local held = 0
        for _, l in ipairs(s.storage.readEscrow(c.id)) do
            if l.slot == slot and l.portion == CH.PORTION.BONUS
                and l.state == CH.ESCROW_STATE.HELD then held = held + l.amount end
        end
        return held
    end

    --- Raise to 50% with `during` run once the top-ups are written, and the
    --- server's Wait standing in for time passing while the raise waits.
    local function raiseWhile(s, c, during, onWait)
        local realTake, realWait = s.escrow.take, _G.Wait
        local raced = false
        s.escrow.take = function(actor, id, lines)
            local a, b, d = realTake(actor, id, lines)
            if not raced and lines[1] and lines[1].derived then
                raced = true
                during()
            end
            return a, b, d
        end
        _G.Wait = function() if onWait then onWait() end end
        local ok, err = s.amendments.improve(s.identity.byCitizenId('CREATOR1'), c.id,
            CH.AMENDMENT.RAISE_BONUS, { percent = 50 })
        s.escrow.take, _G.Wait = realTake, realWait
        truthy(raced, 'the race was run')
        return ok, err
    end

    it('keeps the later collections\' top-ups when the claim pays and moves on', function()
        local s, f, c = placed()
        -- The claim pays slot 1 and has moved the slot on, but not let go.
        local claim
        local realAdvance = s.storage.advanceSlot
        s.storage.advanceSlot = function(...)
            local r = realAdvance(...)
            if coroutine.running() == claim then coroutine.yield() end
            return r
        end
        local ok, err = raiseWhile(s, c, function()
            claim = coroutine.create(function()
                return s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
            end)
            coroutine.resume(claim)
        end, function()
            if claim and coroutine.status(claim) == 'suspended' then coroutine.resume(claim) end
        end)
        s.storage.advanceSlot = realAdvance
        truthy(ok, tostring(err))

        local row = s.storage.readContract(c.id)
        eq(row.next_slot, 2, 'the claim paid')
        eq(row.bonus_percent, 50)
        eq(bonusHeld(s, c, 2), 500, 'collection 2 is shown 50% and escrowed at 10%')
        eq(bonusHeld(s, c, 3), 500)
    end)

    it('keeps the collection a refused claim was on', function()
        local s, f, c = placed()
        local ok, err = raiseWhile(s, c, function()
            truthy(s.contracts.transition(c.id, CH.STATE.ACCEPTED, CH.STATE.COMPLETING, 'claiming_slot'))
        end, function()
            if s.storage.readContract(c.id).state == CH.STATE.COMPLETING then
                s.contracts.transition(c.id, CH.STATE.COMPLETING, CH.STATE.ACCEPTED, 'claim_refused')
            end
        end)
        truthy(ok, tostring(err))
        for slot = 1, 3 do
            eq(bonusHeld(s, c, slot), 500, 'collection ' .. slot .. ' is underfunded')
        end
    end)

    it('hands the raise back whole and says busy when the claim stalls', function()
        local s, f, c = placed()
        local before = Env.players[1].PlayerData.money.bank
        local ok, err = raiseWhile(s, c, function()
            truthy(s.contracts.transition(c.id, CH.STATE.ACCEPTED, CH.STATE.COMPLETING, 'claiming_slot'))
        end)
        falsy(ok, 'reported applied')
        eq(err, CH.ERR.BUSY)
        eq(s.storage.readContract(c.id).bonus_percent, 10, 'the percent was stored anyway')
        eq(Env.players[1].PlayerData.money.bank, before, 'and the client kept paying for it')
        for slot = 1, 3 do eq(bonusHeld(s, c, slot), 100) end
    end)

    it('does not call a raise applied when a stalled claim took only part of it', function()
        local s, f, c = placed()
        local ok, err = raiseWhile(s, c, function()
            truthy(s.contracts.transition(c.id, CH.STATE.ACCEPTED, CH.STATE.COMPLETING, 'claiming_slot'))
            -- The claim paid the collection it was on, top-up and all.
            for _, l in ipairs(s.storage.readEscrow(c.id)) do
                if l.derived and l.slot == 1 and l.amount == 400 then
                    truthy(s.storage.claimEscrowLine(l.id, CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING))
                    truthy(s.storage.settleEscrowLine(l.id, 'HITMAN01'))
                end
            end
        end)
        falsy(ok, 'reported applied with the later collections handed back')
        eq(err, CH.ERR.BUSY)
        eq(s.storage.readContract(c.id).bonus_percent, 10)
        eq(bonusHeld(s, c, 2), 100)
    end)
end)

describe('a top-up a stalled elimination has already shared out', function()
    --- The claim marks the baseline for its hitman and the bonus back to the
    --- client, since an elimination does not earn it, then stalls. The bonus
    --- going back was counted as the top-up failing, and the client was told
    --- busy while the hitman was paid the baseline.
    it('is reported made', function()
        local s = mysqlStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { bank = 1000 } }, { baseline = { bank = 2000 } } } },
        })
        truthy(s.contracts.accept(f.hitman, c.id, false))

        local claim, paused = nil, false
        local realWrite = s.storage.writeEscrow
        s.storage.writeEscrow = function(id, lines)
            local out = realWrite(id, lines)
            -- The claim's marks written, and nothing released yet.
            if claim and coroutine.running() == claim and not paused then
                paused = true
                coroutine.yield()
            end
            return out
        end
        local realTake = s.escrow.take
        local started = false
        s.escrow.take = function(actor, id, lines)
            local a, b, d = realTake(actor, id, lines)
            if not started then
                started = true
                claim = coroutine.create(function()
                    return s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
                end)
                coroutine.resume(claim)
            end
            return a, b, d
        end
        local before = Env.players[1].PlayerData.money.bank
        local ok, err = s.amendments.addEscrow(f.creator, c.id,
            { baseline = { bank = 500 }, bonus = { bank = 300 } })
        s.escrow.take = realTake
        truthy(paused, 'the claim stalled with its marks written')
        coroutine.resume(claim)
        s.storage.writeEscrow = realWrite

        local baseline
        for _, l in ipairs(s.storage.readEscrow(c.id)) do
            if l.portion == CH.PORTION.BASELINE and l.amount == 500 then baseline = l end
        end
        eq(baseline.settled_to, 'HITMAN01', 'the hitman was paid the top-up')
        truthy(ok, 'and the client was told: ' .. tostring(err))
        eq(before - Env.players[1].PlayerData.money.bank, 500, 'the unearned bonus came back')
    end)
end)

describe('an escrow write that raises', function()
    --- On MySQL a statement can raise rather than return false, and a take
    --- that raised after the money had moved kept it with nothing held for
    --- it; a claim whose marks raised was left holding the contract.
    it('gives a creator their money back', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 10000
        local real = s.storage.writeEscrow
        s.storage.writeEscrow = function() error('Column id cannot be null', 0) end
        local c, err = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { bank = 5000 } } })
        s.storage.writeEscrow = real
        falsy(c, 'placed with no escrow behind it')
        truthy(err)
        falsy(err == CH.ERR.LOCKED, 'told somebody else got there first')
        eq(Env.players[1].PlayerData.money.bank, 10000, 'the creator was charged')
    end)

    it('does not refund a write that landed before the error', function()
        -- A connection that drops after the commit: refunded blind, the
        -- creator was paid back and the stored lines returned to them again.
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 10000
        local real = s.storage.writeEscrow
        s.storage.writeEscrow = function(...)
            real(...)
            error('connection lost', 0)
        end
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { bank = 5000 } } })
        s.storage.writeEscrow = real
        truthy(c, 'the stored escrow was thrown away')
        eq(Env.players[1].PlayerData.money.bank, 5000, 'charged once, and not refunded')
        eq(#s.storage.readEscrow(c.id), 1)
    end)

    it('does not refund a transaction that landed but answered false', function()
        -- oxmysql's transaction answers false for a commit whose
        -- acknowledgement was lost, where a single statement raises.
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 20000
        local real = s.storage.writeEscrow
        s.storage.writeEscrow = function(...)
            real(...)
            return false
        end
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = { slots = { { baseline = { bank = 5000 } }, { baseline = { bank = 5000 } } } } })
        s.storage.writeEscrow = real
        truthy(c, 'the stored escrow was thrown away')
        eq(Env.players[1].PlayerData.money.bank, 10000, 'charged once, and not refunded')
    end)

    it('does not leave a claim holding the contract', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 10000
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { bank = 5000 } } })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local hitmanBefore = Env.players[3].PlayerData.money.bank
        local real = s.storage.writeEscrow
        local raised = false
        s.storage.writeEscrow = function(...)
            if not raised then raised = true; error('lost connection', 0) end
            return real(...)
        end
        local ok, err = pcall(s.contracts.claimSlot, c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        s.storage.writeEscrow = real
        truthy(raised, 'the marks were written')
        truthy(ok, 'the claim threw: ' .. tostring(err))
        falsy(s.storage.readContract(c.id).state == CH.STATE.COMPLETING, 'the contract is stuck')
        eq(Env.players[3].PlayerData.money.bank - hitmanBefore, 5000, 'and the hitman was paid')
    end)

    it('names what it charged when the read after it raises too', function()
        -- The same outage refuses the read that decides whether the write
        -- landed. Refunding then pays a copy that did land back twice, so it
        -- is not refunded blind, but the raise used to leave with the money
        -- taken and nothing to say what or where.
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 10000
        local realWrite, realRead = s.storage.writeEscrow, s.storage.readEscrow
        local down = false
        s.storage.writeEscrow = function() down = true error('mysql: connection lost', 0) end
        s.storage.readEscrow = function(...)
            if down then error('mysql: connection lost', 0) end
            return realRead(...)
        end
        local ran = pcall(s.contracts.create, f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { bank = 5000 } } })
        s.storage.writeEscrow, s.storage.readEscrow = realWrite, realRead
        truthy(down, 'the write was reached')
        falsy(ran, 'told the creator it was placed')
        s.audit.flush()
        local named
        for _, row in ipairs(s.storage.readAudit()) do
            if row.action == 'escrow_take_unverified' then named = row end
        end
        truthy(named, 'nothing tells staff what was taken')
        local line = named.detail.lines[1]
        eq(line.source, 'bank')
        eq(line.amount, 5000)
        truthy(line.id, 'and under which id to look for it')
    end)

    it('keeps a hitman\'s stake whole when a read after the charge raises', function()
        -- The ids were read after the stake was charged, and a read that
        -- raised there kept the stake with no line for it.
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 20000 } }, penaltyAmount = 2000 })
        truthy(c)
        local before = money(3)
        local realRead = s.storage.readEscrow
        local raised = false
        s.storage.readEscrow = function(...)
            if not raised and money(3) < before then
                raised = true
                error('mysql: connection lost', 0)
            end
            return realRead(...)
        end
        pcall(s.contracts.accept, f.hitman, c.id, false)
        s.storage.readEscrow = realRead
        truthy(raised, 'no read came after the charge')
        local held = 0
        for _, l in ipairs(s.storage.readEscrow(c.id)) do
            if l.portion == CH.PORTION.STAKE and l.state == CH.ESCROW_STATE.HELD then
                held = held + l.amount
            end
        end
        eq(money(3) + held, before, 'the stake was taken with nothing held for it')
    end)
end)

describe('a contract write that raises', function()
    --- Escrow is taken first and the contract written after it. Every
    --- backend answers that write true or raises, so the refund behind a
    --- false never ran, and a raise left the reward in lines nothing owns.
    it('gives the creator their money back', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 10000
        local real = s.storage.writeContract
        s.storage.writeContract = function() error('mysql: connection lost', 0) end
        local ran, c = pcall(s.contracts.create, f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { bank = 5000 } } })
        s.storage.writeContract = real
        truthy(ran, 'the raise escaped: ' .. tostring(c))
        falsy(c, 'placed with no contract stored')
        eq(Env.players[1].PlayerData.money.bank, 10000, 'the reward went into lines nothing owns')
    end)

    it('keeps a contract that landed before the error', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 10000
        local real = s.storage.writeContract
        local raised = false
        s.storage.writeContract = function(...)
            real(...)
            if not raised then raised = true error('connection lost', 0) end
            return true
        end
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { bank = 5000 } } })
        s.storage.writeContract = real
        truthy(c, 'a stored contract was refunded under its hitmen')
        eq(Env.players[1].PlayerData.money.bank, 5000, 'charged once, and not refunded')
        eq(#s.storage.readEscrow(c.id), 1)
    end)
end)

describe('a claim that stalls between the lines of its marks', function()
    --- On mysql the marks went out one statement a line. A top-up reading
    --- between two of them saw its baseline owed to the hitman and its bonus
    --- not yet marked back to the client: it handed the bonus back, called
    --- the top-up failed, and the claim then paid the hitman the baseline.
    it('shows the top-up all of the marks or none', function()
        local s = mysqlStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { bank = 1000 } }, { baseline = { bank = 2000 } } } },
        })
        truthy(s.contracts.accept(f.hitman, c.id, false))

        -- The claim stalls after its first write to escrow: after one line
        -- of its marks, if they go one statement a line.
        local claim, paused = nil, false
        local realQuery, realTx = MySQL.query, MySQL.transaction
        local function stallAfter(fn)
            return { await = function(sql, params)
                local out = fn.await(sql, params)
                local text = type(sql) == 'string' and sql or ''
                if type(sql) == 'table' then text = sql[1] and (sql[1].query or sql[1][1]) or '' end
                if claim and coroutine.running() == claim and not paused
                    and text:find('INSERT INTO crimson_escrow') then
                    paused = true
                    coroutine.yield()
                end
                return out
            end }
        end
        local realTake = s.escrow.take
        local started = false
        s.escrow.take = function(actor, id, lines)
            local a, b, d = realTake(actor, id, lines)
            if not started then
                started = true
                MySQL.query, MySQL.transaction = stallAfter(realQuery), stallAfter(realTx)
                claim = coroutine.create(function()
                    return s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
                end)
                coroutine.resume(claim)
            end
            return a, b, d
        end
        local before = Env.players[1].PlayerData.money.bank
        local ok, err = s.amendments.addEscrow(f.creator, c.id,
            { baseline = { bank = 500 }, bonus = { bank = 300 } })
        s.escrow.take = realTake
        truthy(paused, 'the claim stalled in its marks')
        coroutine.resume(claim)
        MySQL.query, MySQL.transaction = realQuery, realTx

        local baseline
        for _, l in ipairs(s.storage.readEscrow(c.id)) do
            if l.portion == CH.PORTION.BASELINE and l.amount == 500 then baseline = l end
        end
        eq(baseline.settled_to, 'HITMAN01', 'the hitman was paid the top-up')
        truthy(ok, 'and the client was told: ' .. tostring(err))
        eq(before - Env.players[1].PlayerData.money.bank, 500)
    end)
end)

describe('a top-up the claim it waited on paid out', function()
    it('is reported made, not locked', function()
        local s = mysqlStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { cash = 1000 } }, { baseline = { cash = 2000 } } } },
        })
        truthy(s.contracts.accept(f.hitman, c.id, false))

        -- The claim holds the contract and has not yet read what to pay.
        local claim, paused = nil, false
        local realReadEscrow = s.storage.readEscrow
        s.storage.readEscrow = function(id)
            if claim and coroutine.running() == claim and not paused then
                paused = true
                coroutine.yield()
            end
            return realReadEscrow(id)
        end
        local realTake, realWait = s.escrow.take, _G.Wait
        local topUp
        s.escrow.take = function(actor, id, lines)
            local a, b, d = realTake(actor, id, lines)
            if not topUp and lines[1] and lines[1].amount == 500 then
                for _, l in ipairs(realReadEscrow(c.id)) do
                    if l.amount == 500 and l.portion == CH.PORTION.BASELINE then topUp = l.id end
                end
                claim = coroutine.create(function()
                    return s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
                end)
                coroutine.resume(claim)
            end
            return a, b, d
        end
        local resumed = false
        _G.Wait = function()
            if claim and not resumed and coroutine.status(claim) == 'suspended' then
                resumed = true
                coroutine.resume(claim)
            end
        end
        local ok, err = s.amendments.addEscrow(f.creator, c.id, { baseline = { cash = 500 } })
        s.escrow.take, _G.Wait, s.storage.readEscrow = realTake, realWait, realReadEscrow
        truthy(resumed, 'the claim was waited on')

        eq(s.storage.readEscrowLine(topUp).settled_to, 'HITMAN01', 'the claim paid the top-up')
        truthy(ok, 'the top-up reached the hitman and the client was told: ' .. tostring(err))
    end)
end)

describe('a handover tick that throws part-way through', function()
    --- Every finished countdown was taken out of the live set before any
    --- was claimed, and one throw ended the pass: the ones not yet claimed
    --- were in neither place, their hitmen shown "being paid" for two
    --- minutes and then told to try again.
    it('pays every handover that finished, once the read comes back', function()
        local s, f, c = handover(2)
        Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
            cash = 5000, bank = 5000, firstname = 'Sol', lastname = 'Vane' })
        truthy(s.contracts.accept(s.identity.resolve(4), c.id, false))
        together()
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        truthy(s.kidnap.arm(c.id, 'HITMAN02'))
        ticks(s, Config.Kidnap.CountdownSeconds - 1)

        local before1, before2 = money(3), money(4)
        local real = s.storage.readContract
        local reads = 0
        s.storage.readContract = function(id)
            reads = reads + 1
            if reads == 3 then error('mysql: connection lost') end
            return real(id)
        end
        local realPrint = _G.print
        _G.print = function() end
        local ok = pcall(s.kidnap.tick, Config.Kidnap.TickMs)
        s.storage.readContract = real
        truthy(ok, 'the throw is contained')
        ticks(s, 2)
        _G.print = realPrint

        eq((money(3) - before1) + (money(4) - before2), 1000 + 2000,
            'both handovers paid, one collection each')
        eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED)
        local _ = f
    end)
end)

describe('endings reach the phone, not only an open app', function()
    --- Every phone notification one player was sent, by server id.
    local function told(src)
        local out = {}
        for _, event in ipairs(Env.clientEvents) do
            if Natives.isNotice(event) and event.target == src then
                out[#out + 1] = event.args[1]
            end
        end
        return out
    end

    local function staked(mode)
        local s = newStack()
        local f = fixture(s)
        Env.players[3].PlayerData.money.bank = 50000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = mode or CH.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 5000 } }, penaltyAmount = 2000,
        })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        Env.clientEvents = {}
        return s, f, c
    end

    it('tells the hitman their stake went at expiry, and the client it is theirs', function()
        local s, _, c = staked()
        truthy(s.contracts.resolve(c.id, CH.STATE.EXPIRED, 'CREATOR1', nil, 'expired'))
        local hitman, creator = told(3), told(1)
        eq(#hitman, 1)
        eq(hitman[1].title, 'Contract expired')
        truthy(hitman[1].content:find('$2000 stake went to the person who placed the contract',
            1, true), hitman[1].content)
        eq(#creator, 1)
        truthy(creator[1].content:find("operative's $2000 stake is yours", 1, true), creator[1].content)
    end)

    it('keeps the notice for a hitman who was offline and gives it at login', function()
        local s, _, c = staked()
        Env.removePlayer(3)
        truthy(s.contracts.resolve(c.id, CH.STATE.EXPIRED, 'CREATOR1', nil, 'expired'))
        eq(#told(3), 0, 'nobody there to tell')
        Env.addPlayer({ source = 3, citizenid = 'HITMAN01', license = 'license:ccc',
            firstname = 'Rook', lastname = 'Ash' })
        s.bridges.onPlayerReady(s, 3)
        local titles = {}
        for _, note in ipairs(told(3)) do titles[note.title] = true end
        truthy(titles['Contract expired'], 'told on next login')
    end)

    it('tells the hitman, and not the client twice, when staff void it', function()
        local s, _, c = staked()
        truthy(s.admin.void(0, c.id, 'test'))
        eq(#told(1), 1, 'the client keeps the one notice void already sends')
        local hitman = told(3)
        eq(#hitman, 1)
        truthy(hitman[1].content:find('Staff closed your contract', 1, true))
        truthy(hitman[1].content:find('$2000 stake has been returned', 1, true))
    end)

    it('tells a competitive loser, not the winner, and says completed', function()
        local s, _, c = staked(CH.MODE.COMPETITIVE)
        Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
            cash = 5000, bank = 50000, firstname = 'Sol', lastname = 'Vane' })
        truthy(s.contracts.accept(s.identity.resolve(4), c.id, false))
        Env.clientEvents = {}
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        local loser = told(4)
        eq(#loser, 1)
        truthy(loser[1].content:find('Another operative finished', 1, true))
        for _, note in ipairs(told(3)) do
            truthy(note.title ~= 'Contract closed', 'the winner has the result already')
        end
    end)

    it('tells the client an operative walked away and the stake is theirs', function()
        local s, f, c = staked()
        truthy(s.contracts.abandon(f.hitman, c.id))
        local creator = told(1)
        eq(#creator, 1)
        eq(creator[1].title, 'Operative walked away')
        truthy(creator[1].content:find('Their $2000 stake is yours. It is back on the board.', 1, true),
            creator[1].content)
    end)

    --- Minutes of an idle hold: the sampler and the sweep, once a minute.
    local function idle(s, minutes)
        s.contracts.releaseIdleHolds()
        for _ = 1, minutes do
            Env.advance(60)
            s.death.watchTargets(s.storage.allContracts())
            s.contracts.releaseIdleHolds()
        end
    end
    local IDLE = math.ceil(Config.Limits.ExclusiveIdleReleaseSeconds / 60) + 1

    local function titled(list, title)
        for _, note in ipairs(list) do
            if note.title == title then return note end
        end
        return nil
    end

    --- W020: the notice went through toCitizen, which drops it for anybody
    --- away, and a hitman's clock runs while they sleep.
    it('keeps the idle release for a hitman who was away, and names the stake that went', function()
        local s, _, c = staked()
        Env.removePlayer(3)
        idle(s, IDLE)
        eq(s.storage.readHitman(c.id, 'HITMAN01').state, 'released')
        local client = titled(told(1), 'Contract back on the board')
        truthy(client and client.content:find('Their $2000 stake is yours.', 1, true),
            client and client.content)
        Env.addPlayer({ source = 3, citizenid = 'HITMAN01', license = 'license:ccc',
            firstname = 'Rook', lastname = 'Ash' })
        Env.clientEvents = {}
        s.bridges.onPlayerReady(s, 3)
        local note = titled(told(3), 'Taken off a contract')
        truthy(note, 'told on next login')
        truthy(note.content:find('Your $2000 stake went to the person who placed it.', 1, true),
            note.content)
    end)

    it('names no stake on the release of a hitman who staked nothing', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        Env.players[3]._coords = { x = 5000.0, y = 5000.0, z = 0.0 }
        Env.clientEvents = {}
        idle(s, IDLE)
        local note = titled(told(3), 'Taken off a contract')
        truthy(note, 'told')
        falsy(note.content:find('stake', 1, true), 'money that never existed: ' .. note.content)
    end)

    --- W069: only the person who pressed the last Agree heard anything.
    it('tells every party of a contract called off by agreement, with the amounts', function()
        local s, f, c = staked()
        local p = s.amendments.propose(f.hitman, c.id, CH.AMENDMENT.WITHDRAW, {})
        truthy(p and p.outcome == 'open')
        Env.clientEvents = {}
        truthy(s.amendments.respond(f.creator, p.id, true))
        eq(s.storage.readContract(c.id).state, CH.STATE.CANCELLED)
        local client = titled(told(1), 'Contract called off')
        truthy(client and client.content:find('Everything you put up has been returned.', 1, true),
            client and client.content)
        local hitman = titled(told(3), 'Contract called off')
        truthy(hitman and hitman.content:find('Your $2000 stake has been returned.', 1, true),
            hitman and hitman.content)
        s.audit.flush()
        eq(#s.storage.auditByAction('amendment_applied', 10), 1, 'and on the record')
    end)

    --- W070: a change refused as it went in reached the last person to
    --- agree as "ran out", and those who agreed earlier heard nothing.
    it('tells the last to agree that it no longer applies, and everyone who agreed before', function()
        local s, f, c = staked(CH.MODE.COMPETITIVE)
        local p = s.amendments.propose(f.creator, c.id, CH.AMENDMENT.CHANGE_MODE,
            { mode = CH.MODE.EXCLUSIVE })
        truthy(p and p.outcome == 'open', 'one operative on it: exclusive fits')
        Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
            cash = 5000, bank = 50000, firstname = 'Sol', lastname = 'Vane' })
        local second = s.identity.resolve(4)
        truthy(s.contracts.accept(second, c.id, false))
        local _, _, waiting = s.amendments.respond(f.hitman, p.id, true)
        eq(waiting, 'pending')
        Env.clientEvents = {}
        _G.source = 4
        Env.events['crimson-hitman:respondAmendment']({ id = p.id, approve = true, __rid = 7 })
        _G.source = nil
        local reply
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:result' then reply = event.args[1] end
        end
        falsy(reply.ok)
        eq(reply.err, CH.ERR.INVALID_INPUT, 'two hold it now')
        eq(reply.data and reply.data.outcome, 'failed', 'said as agreed and refused, not as lapsed')
        truthy(titled(told(1), 'Change not made'), 'the client who proposed it')
        truthy(titled(told(3), 'Change not made'), 'and the operative who agreed first')
    end)

    it('answers a proposal that ran out with its own code', function()
        local s, f, c = staked()
        local p = s.amendments.propose(f.creator, c.id, CH.AMENDMENT.CHANGE_REASON,
            { reason = 'Something else' })
        truthy(p)
        Env.advance(Config.Amendments.ProposalExpirySeconds + 600)
        local ok, err = s.amendments.respond(f.hitman, p.id, true)
        falsy(ok)
        eq(err, CH.ERR.PROPOSAL_EXPIRED)
    end)

    --- W080: Withdraw after an operative took it and walked away said
    --- "Nobody had taken it", and nothing said every client now waits.
    it('tells a client who withdraws after a walk-away that it had been taken', function()
        local s, f, c = staked()
        truthy(s.contracts.abandon(f.hitman, c.id))
        local card = s.projection.contract(s.storage.readContract(c.id), 'CREATOR1')
        eq(card.everTaken, true, 'the creator card says so')
        Env.clientEvents = {}
        truthy(s.contracts.cancel(f.creator, c.id))
        local note = titled(told(1), 'Contract withdrawn')
        truthy(note and note.content:find('The operative who took it walked away', 1, true),
            note and note.content)
        truthy(note.content:find(('Nobody can place a contract on Dana Reyes for %d minutes now.')
            :format(Config.Limits.TargetCooldownAfterResolveSeconds // 60), 1, true), note.content)
    end)

    --- W071: the proposer's own decline is a take-back, and the other side
    --- is told it was withdrawn rather than the proposer "declined".
    it('tells the other side a proposal was taken back', function()
        local s, f, c = staked()
        local p = s.amendments.propose(f.creator, c.id, CH.AMENDMENT.CANCEL, {})
        truthy(p and p.outcome == 'open')
        Env.clientEvents = {}
        truthy(s.amendments.respond(f.creator, p.id, false))
        truthy(titled(told(3), 'Change withdrawn'), 'the operative it was put to')
        falsy(titled(told(1), 'Change declined'), 'nobody declined it')
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED)
    end)
end)

--- lb-phone keeps a notification in the phone's list only when its server
--- export is given a phone number; its client export, which every notice
--- went through, shows a popup that is never saved. A receipt, a target's
--- alert or a stake forfeited was gone once it faded, and a notice kept for
--- a player's next login reached them before their phone had loaded.
describe('a notification is kept on the phone', function()
    local function sent(src)
        local saved, popups = {}, {}
        for _, event in ipairs(Env.clientEvents) do
            if event.target == src and event.name == 'lb-phone:SendNotification' then
                saved[#saved + 1] = event
            elseif event.target == src and event.name == 'crimson-hitman:notify' then
                popups[#popups + 1] = event
            end
        end
        return saved, popups
    end

    it('goes through lb-phone\'s server export, by the player\'s number', function()
        local s = newStack()
        fixture(s)
        Env.clientEvents = {}
        eq(s.notify.toCitizen('CREATOR1', 'Contract accepted', 'Taken.'), true)
        local saved, popups = sent(1)
        eq(#saved, 1, 'saved on their phone')
        eq(#popups, 0, 'and not raised a second time by their client')
        eq(saved[1].number, '555-1')
        eq(saved[1].args[1].app, 'crimson-hitman')
        eq(saved[1].args[1].title, 'Contract accepted')
        eq(saved[1].args[1].content, 'Taken.')
    end)

    --- What a notice kept for the next login meets: the player is back,
    --- choosing a character or a spawn, and lb-phone has not loaded their
    --- phone yet.
    it('waits for a phone that has not loaded yet, and saves it there', function()
        local s = newStack()
        fixture(s)
        Natives.unequipped = { [1] = true }
        local realWait, waited = _G.Wait, 0
        _G.Wait = function()
            waited = waited + 1
            if waited == 3 then Natives.unequipped = nil end   -- the phone loads
        end
        Env.clientEvents = {}
        local ok, err = pcall(s.notify.toCitizen, 'CREATOR1', 'Outstanding payment', 'Paid.')
        _G.Wait = realWait
        truthy(ok, tostring(err))
        local saved, popups = sent(1)
        eq(#saved, 1, 'saved, once the phone was there')
        eq(saved[1].number, '555-1')
        eq(#popups, 0)
        eq(waited, 3)
    end)

    --- lb-phone answers a citizen id with the phone they last had equipped,
    --- which may be in somebody else's pocket: a notice saved there tells
    --- whoever holds it what this player is part of.
    it('asks for the phone the player has equipped, never by citizen id', function()
        local s = newStack()
        fixture(s)
        local phone = exports['lb-phone']
        local real, asked = phone.GetEquippedPhoneNumber, {}
        phone.GetEquippedPhoneNumber = function(self, who)
            asked[#asked + 1] = who
            return real(self, who)
        end
        Natives.unequipped = { [1] = true }
        local ok, err = pcall(function()
            s.notify.toCitizen('CREATOR1', 'Contract accepted', 'Taken.')
            Natives.unequipped = nil
            s.notify.toCitizen('CREATOR1', 'Contract accepted', 'Taken.')
        end)
        phone.GetEquippedPhoneNumber = real
        truthy(ok, tostring(err))
        truthy(#asked > 0)
        for _, who in ipairs(asked) do eq(who, 1, 'asked by server id only') end
    end)

    it('tells nobody when the player leaves while it waits, whoever gets their server id', function()
        local s = newStack()
        fixture(s)
        Natives.unequipped = { [1] = true }
        local realWait = _G.Wait
        _G.Wait = function()
            if Env.players[1] and Env.players[1].PlayerData.citizenid == 'CREATOR1' then
                Env.removePlayer(1)
                Env.addPlayer({ source = 1, citizenid = 'NEWCOMER', license = 'license:zzz',
                    firstname = 'New', lastname = 'Comer' })
                Natives.unequipped = nil
            end
        end
        Env.clientEvents = {}
        local ok, err = pcall(s.notify.toCitizen, 'CREATOR1', 'Contract accepted', 'Taken.')
        _G.Wait = realWait
        truthy(ok, tostring(err))
        local saved, popups = sent(1)
        eq(#saved + #popups, 0, 'nothing reached the newcomer on that server id')
    end)

    it('raises the popup at once where lb-phone cannot be asked for the number', function()
        local s = newStack()
        fixture(s)
        local phone = exports['lb-phone']
        local real = phone.GetEquippedPhoneNumber
        phone.GetEquippedPhoneNumber = function() error('no such export') end
        local realWait, waited = _G.Wait, 0
        _G.Wait = function() waited = waited + 1 end
        Env.clientEvents = {}
        local ok, err = pcall(s.notify.toCitizen, 'CREATOR1', 'Contract accepted', 'Taken.')
        phone.GetEquippedPhoneNumber, _G.Wait = real, realWait
        truthy(ok, tostring(err))
        local saved, popups = sent(1)
        eq(#saved, 0)
        eq(#popups, 1)
        eq(waited, 0, 'not waited for: there is nothing to wait for')
    end)

    it('falls back to the client\'s popup wherever lb-phone cannot take it', function()
        local cases = {
            { 'lb-phone is not started', function() Natives.resourceStates['lb-phone'] = 'stopped' end },
            { 'this build has no server export', function() Natives.noServerNotification = true end },
            { 'lb-phone says no', function() Natives.notificationRefused = true end },
            { 'the player has no phone equipped, however long it waits',
              function() Natives.unequipped = { [1] = true } end },
        }
        for _, case in ipairs(cases) do
            local s = newStack()
            fixture(s)
            case[2]()
            Env.clientEvents = {}
            eq(s.notify.toCitizen('CREATOR1', 'Contract accepted', 'Taken.'), true, case[1])
            local saved, popups = sent(1)
            eq(#saved, 0, case[1])
            eq(#popups, 1, case[1] .. ': the popup, as before')
            eq(popups[1].args[1].title, 'Contract accepted', case[1])
        end
    end)

    it('keeps the budget and the mute exactly as they were', function()
        local s = newStack()
        fixture(s)
        Env.clientEvents = {}
        eq(s.notify.toCitizen('CREATOR1', 'Contract message', 'x', { muted = true }), false,
            'a muted thread is charged and not sent')
        local saved, popups = sent(1)
        eq(#saved + #popups, 0, 'by neither route')

        local allowed = Config.Notifications.MaxPerRecipientPerMinute
        for i = 1, allowed - 1 do
            truthy(s.notify.toCitizen('CREATOR1', 'n' .. i, 'x'), 'within the budget: ' .. i)
        end
        eq(s.notify.toCitizen('CREATOR1', 'over', 'x'), false, 'past it, the muted one included')
        saved, popups = sent(1)
        eq(#saved, allowed - 1, 'one fewer than the budget: the mute spent one')
        eq(#popups, 0)
        eq(s.notify.toCitizen('CREATOR1', 'receipt', 'x', { bypassBudget = true }), true,
            'a receipt still goes')
        eq(s.notify.toCitizen('NOBODY01', 'gone', 'x'), false, 'and nobody offline is told')
    end)

    it('sends it in a thread of its own, so a settlement never waits on lb-phone', function()
        local s = newStack()
        fixture(s)
        local real = _G.Citizen
        local queued = {}
        _G.Citizen = { CreateThreadNow = function(fn) queued[#queued + 1] = fn end }
        Env.clientEvents = {}
        local ok, answered = pcall(s.notify.toCitizen, 'CREATOR1', 'Contract accepted', 'Taken.')
        _G.Citizen = real
        truthy(ok, tostring(answered))
        eq(answered, true)
        local saved, popups = sent(1)
        eq(#saved + #popups, 0, 'nothing reached lb-phone outside the thread')
        eq(#queued, 1)
        queued[1]()
        saved = sent(1)
        eq(#saved, 1, 'and the thread sends it')
    end)
end)

describe('/ch-contracts', function()
    it('lists ids, and leaves anonymous parts to staff who may unmask', function()
        local s = newStack()
        local f = fixture(s)
        local open = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 5000 } } })
        -- One live contract per player on one target: the first has run out
        -- before the second is placed, and its creator's own wait is over.
        truthy(s.contracts.resolve(open.id, CH.STATE.EXPIRED, 'CREATOR1', nil, 'expired'))
        Env.time = Env.time + Config.Limits.SameCreatorSameTargetCooldownSeconds + 60
        local anon = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'y', anonymous = true,
            reward = { baseline = { cash = 5000 } } })
        truthy(open and anon, 'both placed')

        Env.aces[7] = { command = true }
        Env.addPlayer({ source = 7, citizenid = 'STAFF001', license = 'license:st' })
        local rows = s.admin.contractsOf(7, 1)
        eq(#rows, 1, 'the anonymous one is not shown to them')
        eq(rows[1].id, open.id)
        eq(rows[1].role, 'client')

        Env.aces[7] = { command = true, ['crimson.identity'] = true }
        rows = s.admin.contractsOf(7, 'CREATOR1')
        eq(#rows, 2)
        eq(rows[1].id, anon.id, 'newest first')
        eq(#s.admin.contractsOf(0, 2), 2, 'and both are listed under the target')
    end)
end)

describe('a buyout whose queue write raises', function()
    --- The target is charged first, and the queue record is the only thing
    --- that settles or refunds it. A write that raised kept the premium in
    --- no pocket, line or queue; a clear that raised after a refund left the
    --- record for the next tick, which refunded it again.
    local function placed(s, f, engaged)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } },
            bailoutAmount = 5000 })
        truthy(c)
        if engaged then truthy(s.contracts.accept(f.hitman, c.id, false)) end
        return c
    end

    for _, engaged in ipairs({ true, false }) do
        it(('hands the premium back when nothing was written (%s)')
            :format(engaged and 'queued' or 'instant'), function()
            local s = newStack()
            local f = fixture(s)
            local c = placed(s, f, engaged)
            local before = money(2)
            local real = s.storage.setBailoutQueue
            s.storage.setBailoutQueue = function() error('mysql: connection lost', 0) end
            local ran = pcall(s.bailout.buy, f.target, c.id)
            s.storage.setBailoutQueue = real
            falsy(ran, 'told the target it was paid')
            eq(money(2), before, 'the premium went with the raise')
            falsy(s.storage.readContract(c.id).bailout_queued_at)
            eq(s.storage.readContract(c.id).state, engaged and CH.STATE.ACCEPTED or CH.STATE.ACTIVE)
        end)
    end

    it('keeps a record that landed before the error', function()
        local s = newStack()
        local f = fixture(s)
        local c = placed(s, f, true)
        local before = money(2)
        local real = s.storage.setBailoutQueue
        s.storage.setBailoutQueue = function(...)
            real(...)
            error('connection lost', 0)
        end
        local ok = s.bailout.buy(f.target, c.id)
        s.storage.setBailoutQueue = real
        truthy(ok, 'a recorded buyout was refused')
        eq(before - money(2), 5000, 'charged once, and not refunded')
        truthy(s.storage.readContract(c.id).bailout_queued_at, 'and it is still queued')
    end)

    it('refunds once when the clear after a refund raises', function()
        local s = newStack()
        local f = fixture(s)
        local c = placed(s, f, true)
        local before = money(2)
        truthy(s.bailout.buy(f.target, c.id))
        -- The hitman finishes it during the delay, so the buyout is refunded.
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        Env.advance(Config.Bailout.ProcessingDelaySeconds + 1)

        local real = s.storage.setBailoutQueue
        local raised = false
        s.storage.setBailoutQueue = function(id, fields)
            if fields == nil and not raised then
                raised = true
                error('mysql: lock wait timeout', 0)
            end
            return real(id, fields)
        end
        pcall(s.bailout.processQueue)
        s.storage.setBailoutQueue = real
        truthy(raised, 'the clear was reached')
        s.bailout.processQueue()
        s.bailout.processQueue()
        eq(money(2), before, 'the refund was paid more than once')
        falsy(s.storage.readContract(c.id).bailout_queued_at)
    end)
end)
