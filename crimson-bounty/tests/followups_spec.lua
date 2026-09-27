--- Regressions in the last round of fixes, each found by following a change
--- to the next reader of what it wrote.

local Exec = require('crimson-bounty.tests.harness.mysql_exec')

--- A full stack whose every module talks to the mysql backend, the one that
--- ships by default. The memory store keeps whatever it is handed, so a
--- column the upsert refuses to update is saved there and nowhere else.
local function mysqlStack()
    local s = newStack()
    Exec.install(Natives)
    package.loaded['crimson-bounty.server.storage.mysql'] = nil
    local store = require('crimson-bounty.server.storage.mysql')
    store.open()
    s.audit.init(store)
    s.escrow.init(store, s.audit)
    s.progression.init({ storage = store, identity = s.identity, audit = s.audit })
    s.contracts.init({ storage = store, escrow = s.escrow, identity = s.identity,
        audit = s.audit, notify = s.notify, progression = s.progression, death = s.death })
    s.ledger.init(store)
    s.death.init({ storage = store, identity = s.identity, contracts = s.contracts, audit = s.audit })
    s.kidnap.init({ storage = store, identity = s.identity, contracts = s.contracts,
        audit = s.audit, notify = s.notify, ledger = s.ledger })
    s.amendments.init({ storage = store, identity = s.identity, contracts = s.contracts,
        escrow = s.escrow, audit = s.audit, notify = s.notify })
    s.projection.init({ storage = store, identity = s.identity, escrow = s.escrow,
        kidnap = s.kidnap, mugshot = s.mugshot, progression = s.progression })
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
                targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
                reward = { slots = { { baseline = { cash = 1000 } }, { baseline = { cash = 2000 } },
                                     { baseline = { cash = 3000 } } } },
                penaltyAmount = 500,
            })
            truthy(c, 'placed')
            truthy(s.contracts.accept(f.hunter, c.id, false))
            local proposal = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.REDUCE_REWARD, { slot = 3 })
            truthy(proposal, 'proposed')
            truthy(s.amendments.respond(f.hunter, proposal.id, true))

            eq(s.storage.readContract(c.id).payout_slots, 2, 'the upsert discarded the new '
                .. 'count, so the emptied collection stayed on sale')

            local before = money(3)
            truthy(s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION))
            Env.advance(Config.Limits.SlotCooldownSeconds + 1)
            truthy(s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION))

            eq(s.storage.readContract(c.id).state, CB.STATE.COMPLETED, 'the contract went on '
                .. 'offering a collection worth nothing, holding the hunter\'s stake behind it')
            eq(money(3) - before, 3500, 'both funded collections, and the stake back')
        end)
    end
end)

describe('coming back to a contract', function()
    it('cannot buy anonymity a named first stint already gave away', function()
        local s = newStack()
        local f = fixture(s)
        Config.Anonymity.HunterFee = 1000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(s.contracts.accept(f.hunter, c.id, false), 'the first stint, named')
        local seen = s.projection.contract(s.storage.readContract(c.id), 'CREATOR1').hunters[1]
        eq(seen.name, 'Rook Ash')
        truthy(s.contracts.abandon(f.hunter, c.id))

        local before = money(3)
        Natives.calls.notifications = {}
        truthy(s.contracts.accept(f.hunter, c.id, true), 'back, asking to be anonymous')

        eq(before - money(3), 0, 'charged for anonymity the creator can see straight through: '
            .. 'the same alias and the same thread they were shown with a name')
        local now = s.projection.contract(s.storage.readContract(c.id), 'CREATOR1').hunters[1]
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
        Config.Anonymity.HunterFee = 1000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        local start = money(3)
        truthy(s.contracts.accept(f.hunter, c.id, true))
        eq(start - money(3), 1000, 'the first stint pays for it')
        truthy(s.contracts.abandon(f.hunter, c.id))

        -- Nothing left to pay a second fee with.
        Env.players[3].PlayerData.money.cash, Env.players[3].PlayerData.money.bank = 0, 0
        local ok, err = s.contracts.accept(f.hunter, c.id, true)
        truthy(ok, 'refused a contract they were already anonymous on: ' .. tostring(err))
        falsy(s.projection.contract(s.storage.readContract(c.id), 'CREATOR1').hunters[1].name,
            'and still anonymous')
    end)

    it('tells the page what the server recorded', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(s.contracts.accept(f.hunter, c.id, false))
        truthy(s.contracts.abandon(f.hunter, c.id))
        truthy(s.contracts.accept(f.hunter, c.id, true), 'back, asking to be anonymous')
        eq(s.projection.contract(s.storage.readContract(c.id), 'HUNTER01').myAnonymous, false,
            'the page said "accepted, anonymously" from the button that was pressed')
        local settings = s.projection.listing('HUNTER01', 1).settings
        eq(settings.anonymityFees.hunter, Config.Anonymity.HunterFee)
        eq(settings.messageMaxLength, Config.Relay.MaxLength)
    end)

    it('may still come back anonymous after an anonymous stint', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(s.contracts.accept(f.hunter, c.id, true))
        truthy(s.contracts.abandon(f.hunter, c.id))
        truthy(s.contracts.accept(f.hunter, c.id, true))
        falsy(s.projection.contract(s.storage.readContract(c.id), 'CREATOR1').hunters[1].name)
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
        targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE, reward = { slots = list },
    })
    truthy(s.contracts.accept(f.hunter, c.id, false))
    together()
    return s, f, c
end

describe('a handover that finishes while another payout holds the lock', function()
    it('is paid once the lock lets go, not refused as closed', function()
        local s, f, c = handover(2)
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))
        ticks(s, Config.Kidnap.CountdownSeconds - 1)

        -- The final tick reads the contract as accepted. By the claim's own
        -- read, another hunter's settlement has the lock: on mysql every
        -- read yields, and another handler runs in the gap.
        local real = s.storage.readContract
        local reads = 0
        s.storage.readContract = function(id)
            reads = reads + 1
            if reads == 2 then
                s.storage.compareSetContractState(id, CB.STATE.ACCEPTED, CB.STATE.COMPLETING)
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
        falsy(s.kidnap.outcome(c.id, 'HUNTER01'), 'the delivery was ended')

        -- The other settlement lets go with a payout left.
        truthy(s.contracts.transition(c.id, CB.STATE.COMPLETING, CB.STATE.ACCEPTED, 'slot_claimed'))
        local before = money(3)
        ticks(s, 2)

        eq(s.storage.readContract(c.id).next_slot, 2, 'and it is paid')
        eq(money(3) - before, 1000)
        eq(s.kidnap.outcome(c.id, 'HUNTER01').outcome, 'paid')
    end)

    it('is still refused when the contract really did close', function()
        local s, f, c = handover(1)
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))
        ticks(s, Config.Kidnap.CountdownSeconds - 1)
        local real = s.storage.readContract
        local reads = 0
        s.storage.readContract = function(id)
            reads = reads + 1
            if reads == 2 then
                -- Closed for real, through the path that settles its escrow.
                truthy(s.contracts.resolve(id, CB.STATE.CANCELLED, 'CREATOR1', nil, 'test'))
            end
            return real(id)
        end
        s.kidnap.tick(Config.Kidnap.TickMs)
        s.storage.readContract = real
        eq(s.kidnap.activeCount(), 0)
        eq(s.kidnap.outcome(c.id, 'HUNTER01').outcome, 'refused')
    end)
end)

describe('a handover re-armed and then walked away from', function()
    it('is not reported as the one before it', function()
        local s, f, c = handover(1)
        s.bridges.install(s)
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))
        Env.players[2].PlayerData.metadata.ishandcuffed = false
        ticks(s, 5)
        eq(s.kidnap.outcome(c.id, 'HUNTER01').outcome, 'failed', 'the first one failed')

        Env.advance(Config.Kidnap.RearmCooldownSeconds + 1)
        Env.players[2].PlayerData.metadata.ishandcuffed = true
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))
        ticks(s, 3)
        truthy(s.contracts.abandon(f.hunter, c.id))

        local answer = s.app.handlers.kidnapProgress(f.hunter, { id = c.id })
        falsy(type(answer) == 'table' and answer.done, 'the poller told a hunter who had just '
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
            truthy(s.contracts.accept(f.hunter, c.id, false))
            Env.players[3]._inventoryFull = true
            truthy(s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION))
            eq(#s.storage.readPending('HUNTER01'), #names, 'every stack owed')
            Env.advance(1)
            truthy(s.escrow.owe('HUNTER01', c.id, 4000, 'bank', 'test'))

            local before = Env.players[3].PlayerData.money.bank
            for _ = 1, 3 do s.escrow.retryPending('HUNTER01') end
            eq(Env.players[3].PlayerData.money.bank - before, 4000,
                'the same goods were tried on every pass and the money behind them never was')
            eq(#s.storage.readPending('HUNTER01'), #names, 'and the goods are still owed')
        end)
    end
end)

describe('the handover countdown thread', function()
    --- Nothing wrapped the tick, so one error killed the thread with its
    --- running flag still set, and Kidnap.start never made another.
    it('keeps counting after one tick throws', function()
        local s, f, c = handover(1)
        local before = #Env.threads
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))
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
        local outcome = s.kidnap.outcome(c.id, 'HUNTER01')
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
        truthy(s.contracts.accept(f.hunter, c.id, false))
        Env.players[3]._inventoryFull = true
        truthy(s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION))
        eq(#s.storage.readPending('HUNTER01'), 1, 'owed, and queued')
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
            if ok and not fired and to == CB.ESCROW_STATE.RELEASING then
                fired = true
                -- The login's pass, in the tick's wait.
                s.escrow.retryPending('HUNTER01')
            end
            return ok
        end
        s.escrow.retryWaiting(function() return true end)
        s.storage.claimEscrowLine = real
        truthy(fired)
        eq(#s.storage.readPending('HUNTER01'), 1,
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
                truthy(s.escrow.owe('HUNTER01', c.id, 4000, 'bank', 'test'))
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
