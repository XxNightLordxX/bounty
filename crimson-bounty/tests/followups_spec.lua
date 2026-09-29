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
    s.bailout.init({ storage = store, identity = s.identity,
        contracts = s.contracts, escrow = s.escrow, audit = s.audit, notify = s.notify })
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
            truthy(s.bailout.owe('HUNTER01', c.id, 4000, 'bank', 'test'))

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
                truthy(s.bailout.owe('HUNTER01', c.id, 4000, 'bank', 'test'))
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
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { cash = 1000 } }, { baseline = { cash = 2000 } } } },
            bonusPercent = 10,
        })
        truthy(c)
        truthy(s.contracts.accept(f.hunter, c.id, false))
        local proposal = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.REDUCE_REWARD, { slot = 2 })
        truthy(proposal)

        local real = s.escrow.take
        local agreed = false
        s.escrow.take = function(...)
            if not agreed then
                agreed = true
                truthy(s.amendments.respond(f.hunter, proposal.id, true), 'the hunter agrees')
                eq(s.storage.readContract(c.id).payout_slots, 1, 'given back')
            end
            return real(...)
        end
        s.amendments.improve(f.creator, c.id, CB.AMENDMENT.RAISE_BONUS, { percent = 20 })
        s.escrow.take = real
        truthy(agreed)
        eq(s.storage.readContract(c.id).payout_slots, 1,
            'the raise wrote its copy back over the give-back')
    end)
end)

describe('a top-up that a payout lands on', function()
    --- The claim moved the slot after the top-up's lines were written and
    --- paid them out with its collection. The hand-back then found nothing
    --- to hand back, and the client was told the top-up had not gone
    --- through while the hunter had the money.
    it('mysql: is reported as added, since it was paid out', function()
        local s = mysqlStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { cash = 1000 } }, { baseline = { cash = 2000 } } } },
        })
        truthy(s.contracts.accept(f.hunter, c.id, false))
        local creatorBefore, hunterBefore = money(1), money(3)

        local real = s.storage.writeEscrow
        local claimed = false
        s.storage.writeEscrow = function(id, lines)
            local out = real(id, lines)
            if not claimed and lines[1] and lines[1].portion == CB.PORTION.BASELINE then
                claimed = true
                truthy(s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION))
            end
            return out
        end
        local ok, err = s.amendments.addEscrow(f.creator, c.id, { baseline = { cash = 5000 } })
        s.storage.writeEscrow = real
        truthy(claimed)
        eq(money(1) - creatorBefore, -5000)
        eq(money(3) - hunterBefore, 1000 + 5000, 'the collection, and the top-up with it')
        truthy(ok, 'told the top-up was refused, with a hunter holding it: ' .. tostring(err))
    end)
end)

describe('a top-up a payout queued for the hunter', function()
    --- The claim paid the new line to the hunter, but their pockets were full,
    --- so it was queued for them: still held, owed to them. The hand-back
    --- then released it to the client by name, which overrides who it is
    --- owed to, and the hunter's queued money went to the client.
    for _, slots in ipairs({ 2, 1 }) do
        it(slots .. ' collection(s): stays owed to the hunter', function()
            local s = mysqlStack()
            local f = fixture(s)
            Env.players[1].PlayerData.money.bank = 400000
            local spec = { { baseline = { cash = 1000 } } }
            if slots == 2 then spec[2] = { baseline = { cash = 2000 } } end
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
                reward = { slots = spec },
            })
            truthy(s.contracts.accept(f.hunter, c.id, false))
            local creatorBefore = money(1)
            Env.players[3]._refuseMoney = true

            local real = s.storage.writeEscrow
            local claimed = false
            s.storage.writeEscrow = function(id, lines)
                local out = real(id, lines)
                if not claimed and lines[1] and lines[1].portion == CB.PORTION.BASELINE then
                    claimed = true
                    truthy(s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION))
                end
                return out
            end
            local ok, err = s.amendments.addEscrow(f.creator, c.id, { baseline = { cash = 5000 } })
            s.storage.writeEscrow = real
            truthy(claimed)

            local topUp
            for _, line in ipairs(s.storage.readEscrow(c.id)) do
                if line.portion == CB.PORTION.BASELINE and line.amount == 5000 then topUp = line end
            end
            truthy(topUp, 'the top-up line exists')
            eq(topUp.owed_to, 'HUNTER01', 'still owed to the hunter who was paid it')
            falsy(topUp.settled_to == 'CREATOR1', 'and not handed to the client')
            eq(money(1) - creatorBefore, -5000, 'the client paid for it once')
            truthy(ok, 'and is told it went in: ' .. tostring(err))

            -- And it reaches the hunter once they can take it.
            Env.players[3]._refuseMoney = false
            s.escrow.retryPending('HUNTER01')
            eq(s.storage.readEscrowLine(topUp.id).settled_to, 'HUNTER01')
        end)
    end
end)

describe('a top-up handed back while a claim queues it', function()
    --- The hand-back checked each line before releasing it, and the release
    --- itself overrides who a line is owed to. A claim queueing the line for
    --- its hunter between the check and the release lost it to the client.
    it('mysql: leaves it with the hunter it was queued for', function()
        local s = mysqlStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { cash = 1000 } }, { baseline = { cash = 2000 } } } },
        })
        truthy(s.contracts.accept(f.hunter, c.id, false))

        -- The claim lands after the top-up is written, but pays slot 1 from
        -- the lines it read before it: the top-up is left held and unowed on
        -- a collection already paid, so the hand-back picks it.
        local realWrite = s.storage.writeEscrow
        local topUp
        s.storage.writeEscrow = function(id, lines)
            local out = realWrite(id, lines)
            if not topUp and lines[1] and lines[1].portion == CB.PORTION.BASELINE
                and lines[1].amount == 500 then
                topUp = lines[1].id
                -- Through the store's own move: a whole-row write leaves the
                -- slot counters alone, and the hand-back never ran.
                truthy(s.storage.advanceSlot(c.id, 1))
            end
            return out
        end
        -- And the racing claim queues it for the hunter just before the
        -- hand-back's release takes it: after every read the hand-back makes
        -- of it, in the await the release's own claim of the line is.
        local realClaim = s.storage.claimEscrowLine
        local queued = false
        s.storage.claimEscrowLine = function(id, from, to)
            if topUp and id == topUp and not queued then
                queued = true
                local line = s.storage.readEscrowLine(topUp)
                line.owed_to = 'HUNTER01'
                realWrite(c.id, { line })
            end
            return realClaim(id, from, to)
        end
        local ok, err = s.amendments.addEscrow(f.creator, c.id, { baseline = { cash = 500 } })
        s.storage.writeEscrow, s.storage.claimEscrowLine = realWrite, realClaim
        truthy(queued, 'the race was run')

        local line = s.storage.readEscrowLine(topUp)
        eq(line.owed_to, 'HUNTER01')
        falsy(line.settled_to == 'CREATOR1', 'handed to the client over the hunter it was queued for')
        truthy(ok, 'queued for the hunter, and the client was told it failed: ' .. tostring(err))
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
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE, bonusPercent = 10,
            reward = { slots = { { baseline = { cash = 1000 } }, { baseline = { cash = 1000 } },
                                 { baseline = { cash = 1000 } } } },
        })
        truthy(s.contracts.accept(f.hunter, c.id, false))
        return s, f, c
    end

    local function bonusHeld(s, c, slot)
        local held = 0
        for _, l in ipairs(s.storage.readEscrow(c.id)) do
            if l.slot == slot and l.portion == CB.PORTION.BONUS
                and l.state == CB.ESCROW_STATE.HELD then held = held + l.amount end
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
            CB.AMENDMENT.RAISE_BONUS, { percent = 50 })
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
                return s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
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
            truthy(s.contracts.transition(c.id, CB.STATE.ACCEPTED, CB.STATE.COMPLETING, 'claiming_slot'))
        end, function()
            if s.storage.readContract(c.id).state == CB.STATE.COMPLETING then
                s.contracts.transition(c.id, CB.STATE.COMPLETING, CB.STATE.ACCEPTED, 'claim_refused')
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
            truthy(s.contracts.transition(c.id, CB.STATE.ACCEPTED, CB.STATE.COMPLETING, 'claiming_slot'))
        end)
        falsy(ok, 'reported applied')
        eq(err, CB.ERR.BUSY)
        eq(s.storage.readContract(c.id).bonus_percent, 10, 'the percent was stored anyway')
        eq(Env.players[1].PlayerData.money.bank, before, 'and the client kept paying for it')
        for slot = 1, 3 do eq(bonusHeld(s, c, slot), 100) end
    end)

    it('does not call a raise applied when a stalled claim took only part of it', function()
        local s, f, c = placed()
        local ok, err = raiseWhile(s, c, function()
            truthy(s.contracts.transition(c.id, CB.STATE.ACCEPTED, CB.STATE.COMPLETING, 'claiming_slot'))
            -- The claim paid the collection it was on, top-up and all.
            for _, l in ipairs(s.storage.readEscrow(c.id)) do
                if l.derived and l.slot == 1 and l.amount == 400 then
                    truthy(s.storage.claimEscrowLine(l.id, CB.ESCROW_STATE.HELD, CB.ESCROW_STATE.RELEASING))
                    truthy(s.storage.settleEscrowLine(l.id, 'HUNTER01'))
                end
            end
        end)
        falsy(ok, 'reported applied with the later collections handed back')
        eq(err, CB.ERR.BUSY)
        eq(s.storage.readContract(c.id).bonus_percent, 10)
        eq(bonusHeld(s, c, 2), 100)
    end)
end)

describe('a top-up a stalled elimination has already shared out', function()
    --- The claim marks the baseline for its hunter and the bonus back to the
    --- client, since an elimination does not earn it, then stalls. The bonus
    --- going back was counted as the top-up failing, and the client was told
    --- busy while the hunter was paid the baseline.
    it('is reported made', function()
        local s = mysqlStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { bank = 1000 } }, { baseline = { bank = 2000 } } } },
        })
        truthy(s.contracts.accept(f.hunter, c.id, false))

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
                    return s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
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
            if l.portion == CB.PORTION.BASELINE and l.amount == 500 then baseline = l end
        end
        eq(baseline.settled_to, 'HUNTER01', 'the hunter was paid the top-up')
        truthy(ok, 'and the client was told: ' .. tostring(err))
        eq(before - Env.players[1].PlayerData.money.bank, 500, 'the unearned bonus came back')
    end)
end)

describe('a claim that stalls between the lines of its marks', function()
    --- On mysql the marks went out one statement a line. A top-up reading
    --- between two of them saw its baseline owed to the hunter and its bonus
    --- not yet marked back to the client: it handed the bonus back, called
    --- the top-up failed, and the claim then paid the hunter the baseline.
    it('shows the top-up all of the marks or none', function()
        local s = mysqlStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { bank = 1000 } }, { baseline = { bank = 2000 } } } },
        })
        truthy(s.contracts.accept(f.hunter, c.id, false))

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
                    return s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
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
            if l.portion == CB.PORTION.BASELINE and l.amount == 500 then baseline = l end
        end
        eq(baseline.settled_to, 'HUNTER01', 'the hunter was paid the top-up')
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
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { cash = 1000 } }, { baseline = { cash = 2000 } } } },
        })
        truthy(s.contracts.accept(f.hunter, c.id, false))

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
                    if l.amount == 500 and l.portion == CB.PORTION.BASELINE then topUp = l.id end
                end
                claim = coroutine.create(function()
                    return s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
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

        eq(s.storage.readEscrowLine(topUp).settled_to, 'HUNTER01', 'the claim paid the top-up')
        truthy(ok, 'the top-up reached the hunter and the client was told: ' .. tostring(err))
    end)
end)

describe('a handover tick that throws part-way through', function()
    --- Every finished countdown was taken out of the live set before any
    --- was claimed, and one throw ended the pass: the ones not yet claimed
    --- were in neither place, their hunters shown "being paid" for two
    --- minutes and then told to try again.
    it('pays every handover that finished, once the read comes back', function()
        local s, f, c = handover(2)
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd',
            cash = 5000, bank = 5000, firstname = 'Sol', lastname = 'Vane' })
        truthy(s.contracts.accept(s.identity.resolve(4), c.id, false))
        together()
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))
        truthy(s.kidnap.arm(c.id, 'HUNTER02'))
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
        eq(s.storage.readContract(c.id).state, CB.STATE.COMPLETED)
        local _ = f
    end)
end)
