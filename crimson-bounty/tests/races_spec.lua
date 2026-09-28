--- Interleavings: two things happening to one contract at the same moment.
---
--- On the mysql backend every store call yields, and net events, the tick and
--- player drops each run as their own coroutine. Each test here injects the
--- second actor into the gap a real await leaves, through a wrapped storage
--- call, and asserts on what is left afterwards. Each failed before its fix.

-- Diagnostics the reproductions print while they run; quiet in the suite.
local function print() end
local function say() end

local function addHunter2()
    Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd',
        cash = 5000, bank = 5000, firstname = 'Sol', lastname = 'Vane' })
end

local function money(src)
    local p = Env.players[src]
    return (p.PlayerData.money.cash or 0) + (p.PlayerData.money.bank or 0)
end

local function stakeLines(s, cid)
    local out = {}
    for _, l in ipairs(s.storage.readEscrow(cid)) do
        if l.portion == CB.PORTION.STAKE then out[#out + 1] = l end
    end
    return out
end

describe('RACE F1: two hunters accept a competitive contract at once', function()
    _G.F1BODY = function(make) return function()
        local s = make()
        local f = fixture(s)
        addHunter2()
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } }, penaltyAmount = 1000,
        })
        truthy(c, 'contract')
        eq(c.penalty_amount, 1000)

        local h2 = s.identity.resolve(4)
        local realWrite = s.storage.writeEscrow
        local fired = false
        s.storage.writeEscrow = function(contractId, lines)
            if not fired and lines[1] and lines[1].portion == CB.PORTION.STAKE then
                fired = true
                -- Hunter 2's accept lands between hunter 1 allocating the
                -- line id and writing it.
                local ok2, err2 = s.contracts.accept(h2, c.id, false)
                print('  second accept ->', ok2, err2)
            end
            return realWrite(contractId, lines)
        end
        local ok1, err1 = s.contracts.accept(f.hunter, c.id, false)
        s.storage.writeEscrow = realWrite
        print('  first accept ->', ok1, err1)

        local active = 0
        for _, h in ipairs(s.storage.readHunters(c.id)) do
            if h.state == 'active' then active = active + 1 end
        end
        print('  active hunters:', active, ' hunter1 money', money(3), ' hunter2 money', money(4))
        local lines = stakeLines(s, c.id)
        local total = 0
        for _, l in ipairs(lines) do
            print('  stake line', l.id, 'staker', l.staker, 'amount', l.amount, 'state', l.state)
            total = total + l.amount
        end
        print('  charged', (10000 - money(3)) + (10000 - money(4)), 'escrowed', total)
        eq(total, (10000 - money(3)) + (10000 - money(4)),
            'every stake charged is held in escrow')
    end end
    it('keeps both stakes (memory)', F1BODY(function() return newStack() end))
end)

describe('RACE F2: a contract resolves while a hunter is mid-accept', function()
    -- A cancel lands before the hunter's row exists: once it does, somebody
    -- is on the contract and the client can no longer cancel it outright.
    -- A buyout lands inside the stake itself, after the row.
    local function run(which, fee)
        local s = newStack()
        local f = fixture(s)
        if fee then Config.Anonymity.HunterFee = fee end
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 5000 } }, penaltyAmount = 1000,
            bailoutAmount = 5000,
        })
        truthy(c)
        local function land()
            local ok, err
            if which == 'cancel' then
                ok, err = s.contracts.cancel(f.creator, c.id)
            else
                ok, err = s.bailout.buy(f.target, c.id)
            end
            print('  ' .. which .. ' ->', ok, err)
        end
        local realWrite, realCount = s.storage.writeEscrow, s.storage.countHunterContracts
        local fired = false
        s.storage.countHunterContracts = function(...)
            if which == 'cancel' and not fired then fired = true land() end
            return realCount(...)
        end
        s.storage.writeEscrow = function(contractId, lines)
            if which ~= 'cancel' and not fired and lines[1]
                and lines[1].portion == CB.PORTION.STAKE then
                fired = true
                land()
            end
            return realWrite(contractId, lines)
        end
        local ok1, err1 = s.contracts.accept(f.hunter, c.id, fee ~= nil)
        s.storage.writeEscrow, s.storage.countHunterContracts = realWrite, realCount
        truthy(fired, 'the ' .. which .. ' never landed')
        falsy(ok1, 'accepted a contract that closed underneath')
        eq(err1, CB.ERR.ALREADY_SETTLED)
        print('  accept ->', ok1, err1, ' state', s.storage.readContract(c.id).state)
        for _, l in ipairs(stakeLines(s, c.id)) do
            print('  stake line', l.id, 'state', l.state, 'amount', l.amount)
        end
        print('  hunter money', money(3), '(started 10000)')
        return money(3)
    end
    it('gives the stake back when the creator cancels mid-accept', function()
        eq(run('cancel'), 10000, 'the stake was left held on a cancelled contract')
    end)
    it('gives the stake back when the target buys out mid-accept', function()
        eq(run('bailout'), 10000, 'the stake was left held on a bought-out contract')
    end)
    it('gives the anonymity fee back with the stake', function()
        eq(run('cancel', 1500), 10000, 'the fee for anonymity on a contract '
            .. 'the hunter never got was kept')
    end)

    it('refuses a cancel that lands once the hunter is on it, and the acceptance stands', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 5000 } }, penaltyAmount = 1000,
        })
        local realWrite = s.storage.writeEscrow
        local cancelled
        s.storage.writeEscrow = function(contractId, lines)
            if cancelled == nil and lines[1] and lines[1].portion == CB.PORTION.STAKE then
                cancelled = s.contracts.cancel(f.creator, c.id) or false
            end
            return realWrite(contractId, lines)
        end
        local ok = s.contracts.accept(f.hunter, c.id, false)
        s.storage.writeEscrow = realWrite
        eq(cancelled, false, 'cancelled out from under a hunter part-way through accepting')
        truthy(ok, 'and the acceptance stands')
        eq(s.storage.readContract(c.id).state, CB.STATE.ACCEPTED)
        eq(money(3), 9000, 'with its stake held')
    end)
end)

describe('RACE F4: two hunters claim at once on a two-payout contract', function()
    it('does not consume the second kill for nothing', function()
        local s = newCopyingStack()
        local f = fixture(s)
        addHunter2()
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { cash = 1000 } },
                                 { baseline = { cash = 2000 } } } },
        })
        truthy(c)
        local h2 = s.identity.resolve(4)
        truthy(s.contracts.accept(f.hunter, c.id, false))
        truthy(s.contracts.accept(h2, c.id, false))

        local realReadHunter = s.storage.readHunter
        local fired = false
        s.storage.readHunter = function(cid, who)
            if not fired and who == 'HUNTER02' then
                fired = true
                local ok, err, res = s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
                print('  hunter1 claim ->', ok, err, res and res.settled)
            end
            return realReadHunter(cid, who)
        end
        local before = money(4)
        local ok, err, res = s.contracts.claimSlot(c.id, 'HUNTER02', CB.FULFILMENT.ELIMINATION)
        s.storage.readHunter = realReadHunter
        print('  hunter2 claim ->', ok, err, res and res.slot, res and res.settled)
        local row = s.storage.readContract(c.id)
        print('  next_slot', row.next_slot, 'claimed', row.slots_claimed, 'state', row.state,
              ' hunter2 gained', money(4) - before)
        if ok then
            truthy(money(4) - before > 0, 'a claim reported as paid paid the hunter nothing')
        end
    end)
end)

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

local function deepCopy(v)
    if type(v) ~= 'table' then return v end
    local o = {}
    for k, x in pairs(v) do o[k] = deepCopy(x) end
    return o
end

describe('RACE F3: the expiry pass writes back rows it read before it yielded', function()
    it('does not undo a payout claimed while the pass was running', function()
        local main, m = boot()
        local f = fixture(m)
        Env.addPlayer({ source = 5, citizenid = 'TARGET02', license = 'license:eee',
            cash = 1000, bank = 1000, firstname = 'Ola', lastname = 'Quinn' })

        -- A: overdue, both parties online, so the pass expires it.
        local a = m.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        -- B: two payouts, held by a hunter.
        local b = m.contracts.create(f.creator, {
            targetCid = 'TARGET02', reason = 'y', mode = CB.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { cash = 1000 } },
                                 { baseline = { cash = 2000 } } } },
        })
        truthy(a and b, 'two contracts')
        truthy(m.contracts.accept(f.hunter, b.id, false))
        local rowA = m.storage.readContract(a.id)
        rowA.deadline_at = Env.time - 1
        m.storage.writeContract(rowA)

        -- B's target logs off (killed and quit): B's clock pauses on the
        -- next pass, which writes the pause marker.
        Env.players[5] = nil
        Env.byCitizen['TARGET02'] = nil

        -- Reads return copies, as a database does.
        local realAll = m.storage.allContracts
        m.storage.allContracts = function() return deepCopy(realAll()) end

        -- The hunter's kill on B is verified while the pass is busy
        -- expiring A.
        -- The expiry's own state write, which is where the pass yields.
        local realExpire = m.storage.expireIfDue
        local fired = false
        m.storage.expireIfDue = function(id, expected, next_, ...)
            if not fired and id == a.id and next_ == CB.STATE.EXPIRED then
                fired = true
                local ok, err, res = m.contracts.claimSlot(b.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
                print('  claim on B during the pass ->', ok, err, res and res.settled)
                print('  B next_slot right after the claim', m.storage.readContract(b.id).next_slot)
            end
            return realExpire(id, expected, next_, ...)
        end

        local expired = main.expire()
        m.storage.expireIfDue = realExpire
        truthy(fired, 'the claim ran inside the pass')
        m.storage.allContracts = realAll
        print('  pass expired', expired)
        local rowB = deepCopy(m.storage.readContract(b.id))
        print('  B after the pass: next_slot', rowB.next_slot, 'slots_claimed', rowB.slots_claimed,
              'paused_since', rowB.paused_since)

        -- Ten minutes later the hunter kills the target again.
        Env.time = Env.time + 700
        local before = money(3)
        local ok, err, res = m.contracts.claimSlot(b.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
        print('  second claim ->', ok, err, res and res.slot, res and res.settled, 'paid', money(3) - before)

        eq(rowB.next_slot, 2, 'the pass put the payout counter back')
    end)
end)

--- The whole stack on the executing MySQL simulator.
function _G.mysqlStack()
    local stack = newStack()
    local Exec = require('crimson-bounty.tests.harness.mysql_exec')
    Exec.install(Natives)
    package.loaded['crimson-bounty.server.storage.mysql'] = nil
    local store = require('crimson-bounty.server.storage.mysql')
    store.open()

    stack.audit.init(store)
    stack.escrow.init(store, stack.audit)
    stack.progression.init({ storage = store, identity = stack.identity, audit = stack.audit })
    stack.contracts.init({ storage = store, escrow = stack.escrow, identity = stack.identity,
                           audit = stack.audit, notify = stack.notify,
                           progression = stack.progression, death = stack.death })
    stack.ledger.init(store)
    stack.bailout.init({ storage = store, identity = stack.identity,
                         contracts = stack.contracts, escrow = stack.escrow,
                         audit = stack.audit, notify = stack.notify, kidnap = stack.kidnap })
    stack.death.init({ storage = store, identity = stack.identity,
                       contracts = stack.contracts, audit = stack.audit })
    stack.amendments.init({ storage = store, identity = stack.identity,
                            contracts = stack.contracts, escrow = stack.escrow,
                            audit = stack.audit, notify = stack.notify })
    stack.informant.init({ storage = store, identity = stack.identity,
                           audit = stack.audit, death = stack.death })
    stack.projection.init({ storage = store, identity = stack.identity,
                            escrow = stack.escrow, kidnap = stack.kidnap,
                            mugshot = stack.mugshot, progression = stack.progression })
    stack.kidnap.init({ storage = store, identity = stack.identity, contracts = stack.contracts,
                        audit = stack.audit, notify = stack.notify, ledger = stack.ledger })
    stack.storage = store
    return stack
end

describe('F5: giving the last collection back, on the mysql backend', function()
    it('leaves the contract with one collection fewer', function()
        local s = mysqlStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { cash = 1000 } },
                                 { baseline = { cash = 40000 } } } },
        })
        truthy(c, 'contract')
        eq(s.storage.readContract(c.id).payout_slots, 2)
        truthy(s.contracts.accept(f.hunter, c.id), 'a hunter')

        local proposal = s.amendments.propose(f.creator, c.id,
            CB.AMENDMENT.REDUCE_REWARD, { slot = 2 })
        truthy(proposal, 'proposed')
        local ok, err, outcome = s.amendments.respond(f.hunter, proposal.id, true)
        print('  respond ->', ok, err, outcome)
        local row = s.storage.readContract(c.id)
        print('  payout_slots after', row.payout_slots, 'creator bank', Env.players[1].PlayerData.money.bank)

        local before = money(3)
        local okc = s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION, {})
        print('  first claim', okc, 'paid', money(3) - before, 'state', s.storage.readContract(c.id).state)
        eq(row.payout_slots, 1, 'mysql kept the given-back collection on sale')
    end)
end)

describe('RACE F6: two hunters agree to the same proposal at once', function()
    it('counts both answers', function()
        local s = newCopyingStack()
        local f = fixture(s)
        addHunter2()
        local h2 = s.identity.resolve(4)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(s.contracts.accept(f.hunter, c.id, false))
        truthy(s.contracts.accept(h2, c.id, false))
        local deadline = s.storage.readContract(c.id).deadline_at

        local proposal = s.amendments.propose(f.creator, c.id,
            CB.AMENDMENT.SHORTEN_DEADLINE, { seconds = 600 })
        truthy(proposal, 'proposed')

        local realWrite = s.storage.writeAmendment
        local fired = false
        local h2ok, h2err
        s.storage.writeAmendment = function(a)
            if not fired then
                fired = true
                local outcome
                h2ok, h2err, outcome = s.amendments.respond(h2, proposal.id, true)
                print('  hunter2 agrees ->', h2ok, h2err, outcome)
            end
            return realWrite(a)
        end
        local ok, err, outcome = s.amendments.respond(f.hunter, proposal.id, true)
        s.storage.writeAmendment = realWrite
        print('  hunter1 agrees ->', ok, err, outcome)
        -- Only a player who was TOLD their answer did not land answers again.
        if not h2ok then
            local ok3, err3, out3 = s.amendments.respond(h2, proposal.id, true)
            print('  hunter2 was refused, answers again ->', ok3, err3, out3)
        end

        local stored = s.storage.readAmendment(proposal.id)
        local who = {}
        for cid in pairs(stored.approvals) do who[#who + 1] = cid end
        table.sort(who)
        print('  stored outcome', stored.outcome, 'approvals', table.concat(who, ','),
              'deadline moved by', deadline - s.storage.readContract(c.id).deadline_at)
        -- Everyone has agreed; it should have applied.
        eq(stored.outcome, 'applied', 'both hunters agreed and the change never applied')
    end)
end)

describe('RACE F7: a broke hunter backs out of an advance another hunter joined on', function()
    it('does not leave a held competitive contract open', function()
        local s = newStack()
        local f = fixture(s)
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd',
            cash = 0, bank = 50000, firstname = 'Sol', lastname = 'Vane' })
        local h2 = s.identity.resolve(4)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 50000 } }, penaltyAmount = 20000,
        })
        truthy(c)
        eq(c.penalty_amount, 20000)

        local realCas = s.storage.compareSetContractState
        local fired = false
        local inX = true
        s.storage.compareSetContractState = function(id, expected, next_)
            local r = realCas(id, expected, next_)
            -- HUNTER01 (10,000 to their name) has just advanced the
            -- contract; HUNTER02 reads it before HUNTER01 finds they cannot
            -- cover the stake and puts the advance back.
            if inX and not fired and r and expected == CB.STATE.ACTIVE
                and next_ == CB.STATE.ACCEPTED then
                fired = true
                inX = false
                local ok, err = s.contracts.accept(h2, c.id, false)
                print('  hunter2 accept (inside) ->', ok, err)
                inX = true
            end
            return r
        end
        local ok, err = s.contracts.accept(f.hunter, c.id, false)
        inX = false
        s.storage.compareSetContractState = realCas
        print('  hunter1 accept ->', ok, err)
        if not fired then
            local ok2, err2 = s.contracts.accept(h2, c.id, false)
            print('  hunter2 accept (after) ->', ok2, err2)
        end

        local row = s.storage.readContract(c.id)
        local active = {}
        for _, h in ipairs(s.storage.readHunters(c.id)) do
            if h.state == 'active' then active[#active + 1] = h.hunter_cid end
        end
        print('  state', row.state, 'active hunters', table.concat(active, ','))
        local stateBeforeClaim = row.state

        -- HUNTER02 kills the target.
        local okc, errc = s.contracts.claimSlot(c.id, 'HUNTER02', CB.FULFILMENT.ELIMINATION)
        print('  hunter2 claim ->', okc, errc)
        eq(stateBeforeClaim, CB.STATE.ACCEPTED, 'a contract with a hunter on it went back to open')
    end)
end)

describe("RACE F1 on mysql", function()
    it("keeps both stakes (mysql)", F1BODY(function() return mysqlStack() end))
end)


describe('RACE F7b: the last hunter walks away while another accepts', function()
    it('does not leave a held competitive contract open', function()
        local s = newCopyingStack()
        local f = fixture(s)
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd',
            cash = 5000, bank = 5000, firstname = 'Sol', lastname = 'Vane' })
        local h2 = s.identity.resolve(4)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(s.contracts.accept(f.hunter, c.id, false))

        local realCas = s.storage.compareSetContractState
        local fired = false
        s.storage.compareSetContractState = function(id, expected, next_)
            if not fired and expected == CB.STATE.ACCEPTED and next_ == CB.STATE.ACTIVE then
                fired = true
                -- HUNTER02's accept lands between HUNTER01 counting nobody
                -- left and the revert to open.
                local ok, err = s.contracts.accept(h2, c.id, false)
                say('  hunter2 accept ->', ok, err)
            end
            return realCas(id, expected, next_)
        end
        local ok, err = s.contracts.abandon(f.hunter, c.id)
        s.storage.compareSetContractState = realCas
        say('  hunter1 abandon ->', ok, err)
        local row = s.storage.readContract(c.id)
        local active = {}
        for _, h in ipairs(s.storage.readHunters(c.id)) do
            if h.state == 'active' then active[#active + 1] = h.hunter_cid end
        end
        say('  state', row.state, 'active', table.concat(active, ','))
        local okc, errc = s.contracts.claimSlot(c.id, 'HUNTER02', CB.FULFILMENT.ELIMINATION)
        say('  hunter2 claim ->', okc, errc)
        eq(row.state, CB.STATE.ACCEPTED, 'a contract with a hunter on it went back to open')
    end)
end)

describe('RACE F8: the stake is repriced between the disclosure check and the charge', function()
    it('charges only the stake the hunter was shown', function()
        local s = newCopyingStack()
        local f = fixture(s)
        Env.players[3].PlayerData.money.bank = 50000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 20000 } }, penaltyAmount = 1000,
        })
        truthy(c)
        eq(c.penalty_amount, 1000)

        local realRead = s.storage.readContract
        local reads, fired = 0, false
        s.storage.readContract = function(id)
            reads = reads + 1
            -- The handler's own read (1) passed the disclosure check; the
            -- creator reprices before Contracts.accept reads it (2).
            if reads == 1 and not fired then
                fired = true
                s.storage.readContract = realRead
                local p = s.amendments.propose(f.creator, c.id,
                    CB.AMENDMENT.RAISE_PENALTY, { amount = 30000 })
                say('  creator proposes a 30,000 stake ->', p and p.id)
                local ok, err, outcome = s.amendments.respond(f.creator, p.id, true)
                say('  creator agrees with themselves ->', ok, err, outcome,
                    'stake now', realRead(c.id).penalty_amount)
                s.storage.readContract = function(x) reads = reads + 1 return realRead(x) end
            end
            return realRead(id)
        end
        local before = Env.players[3].PlayerData.money.bank + Env.players[3].PlayerData.money.cash
        local result, err = s.app.handlers.accept(f.hunter, { id = c.id, penaltyAmount = 1000 })
        s.storage.readContract = realRead
        local after = Env.players[3].PlayerData.money.bank + Env.players[3].PlayerData.money.cash
        say('  accept with 1,000 on screen ->', result and 'ok' or 'refused', err,
            'charged', before - after)
        truthy(before - after <= 1000, 'the hunter was charged a stake they were never shown')
    end)
end)

describe('two takes on one contract at the same moment', function()
    it('refuses the second while the first is still writing, and charges nothing for it', function()
        -- The lock on its own. The read-back check behind it catches the
        -- same collision a second way, so the pair can only be told apart
        -- by asking the lock directly.
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c)
        local realWrite = s.storage.writeEscrow
        local inner
        s.storage.writeEscrow = function(contractId, lines)
            if not inner then
                inner = { s.escrow.take(f.creator, c.id, { {
                    slot = 1, portion = CB.PORTION.BASELINE, source = 'cash', amount = 100,
                } }) }
            end
            return realWrite(contractId, lines)
        end
        local before = Env.players[1].PlayerData.money.cash
        local ok = s.escrow.take(f.creator, c.id, { {
            slot = 1, portion = CB.PORTION.BASELINE, source = 'cash', amount = 200,
        } })
        s.storage.writeEscrow = realWrite
        truthy(ok, 'the first take stands')
        falsy(inner[1], 'a second take ran inside the first and could share its line id')
        eq(inner[2], CB.ERR.LOCKED)
        eq(Env.players[1].PlayerData.money.cash, before - 200, 'only the first was charged')
    end)
end)

--- The deadline brought in around a staked acceptance.
---
--- A stake forfeits to the client at the deadline, and the client can move
--- the deadline of a contract nobody holds. Each side checked the other
--- before its own write — revise looked for holders, then wrote; accept read
--- the deadline, then wrote its row — so with an await between check and
--- write on either side, both could pass and a hunter ended up holding a
--- stake on a contract with minutes left that they had never been shown.
local function deadlineRace(make)
    local s = make()
    local f = fixture(s)
    Env.players[3].PlayerData.money.bank = 50000
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.EXCLUSIVE,
        reward = { baseline = { cash = 20000 } }, penaltyAmount = 1000,
    })
    truthy(c)
    return s, f, c, s.storage.readContract(c.id).deadline_at
end

local function holding(s, c)
    for _, h in ipairs(s.storage.readHunters(c.id)) do
        if h.state == 'active' or h.state == 'joining' then return h end
    end
end

describe('RACE F9: the client brings the deadline in while a hunter is staking', function()
    local function run(make) return function()
        local s, f, c, original = deadlineRace(make)
        local before = money(3)

        local realCount = s.storage.countHunterContracts
        local fired, revised = false, nil
        s.storage.countHunterContracts = function(...)
            if not fired then
                fired = true
                -- Past the accept's check, before its row exists: nobody
                -- holds the contract, so the edit is allowed.
                revised = s.contracts.revise(f.creator, c.id, { deadlineSeconds = 600 })
            end
            return realCount(...)
        end
        local ok, err = s.contracts.accept(f.hunter, c.id, false,
            { checkDisclosure = true, disclosed = 1000, shownDeadline = original })
        s.storage.countHunterContracts = realCount

        truthy(fired, 'the edit never landed')
        truthy(revised, 'nobody held it yet, so the edit itself stands')
        falsy(ok, 'the hunter was left staked on ten minutes they were never shown')
        eq(err, CB.ERR.TERMS_CHANGED)
        eq(money(3), before, 'and the stake came back')
        falsy(holding(s, c), 'and nobody holds the contract')
        eq(s.storage.readContract(c.id).state, CB.STATE.ACTIVE, 'which is open again')
    end end
    it('refuses the acceptance (memory)', run(newStack))
    it('refuses the acceptance (copying)', run(newCopyingStack))
    it('refuses the acceptance (mysql)', run(mysqlStack))
end)

describe('RACE F9b: the client edits once the staking hunter\'s row exists', function()
    local function run(make) return function()
        local s, f, c, original = deadlineRace(make)
        local realWrite = s.storage.writeEscrow
        local revised, why
        s.storage.writeEscrow = function(contractId, lines)
            if revised == nil and lines[1] and lines[1].portion == CB.PORTION.STAKE then
                revised, why = s.contracts.revise(f.creator, c.id, { deadlineSeconds = 600 })
            end
            return realWrite(contractId, lines)
        end
        local ok, err = s.contracts.accept(f.hunter, c.id, false,
            { checkDisclosure = true, disclosed = 1000, shownDeadline = original })
        s.storage.writeEscrow = realWrite
        falsy(revised, 'the deadline was cut under a hunter part-way through staking')
        eq(why, CB.ERR.CONTRACT_TAKEN)
        truthy(ok, tostring(err))
        eq(s.storage.readContract(c.id).deadline_at, original, 'on the deadline they were shown')
    end end
    it('refuses the edit (memory)', run(newStack))
    it('refuses the edit (mysql)', run(mysqlStack))
end)

describe('RACE F10: a hunter takes the contract while the client is editing its deadline', function()
    local function run(make) return function()
        local s, f, c, original = deadlineRace(make)

        local realSet = s.storage.setDeadline
        local fired, accepted = false, nil
        s.storage.setDeadline = function(...)
            if not fired then
                fired = true
                -- Past revise's look for holders, before its write.
                accepted = s.contracts.accept(f.hunter, c.id, false,
                    { checkDisclosure = true, disclosed = 1000, shownDeadline = original })
            end
            return realSet(...)
        end
        local ok, err = s.contracts.revise(f.creator, c.id, { deadlineSeconds = 600 })
        s.storage.setDeadline = realSet

        truthy(fired, 'the deadline was never written')
        truthy(accepted, 'the acceptance saw the deadline it was shown, and stands')
        falsy(ok, 'the edit cut the deadline under a hunter who had staked on it')
        eq(err, CB.ERR.BAD_STATE)
        eq(s.storage.readContract(c.id).deadline_at, original,
            'the deadline the hunter accepted is the one they hold')
        truthy(holding(s, c), 'and they still hold it')
    end end
    it('puts the deadline back (memory)', run(newStack))
    it('puts the deadline back (copying)', run(newCopyingStack))
    it('puts the deadline back (mysql)', run(mysqlStack))
end)

describe('RACE F11: a hunter takes the contract while a solo shortening is applied', function()
    local function run(make) return function()
        local s, f, c, original = deadlineRace(make)

        local realSet = s.storage.setDeadline
        local fired, accepted = false, nil
        s.storage.setDeadline = function(...)
            if not fired then
                fired = true
                accepted = s.contracts.accept(f.hunter, c.id, false,
                    { checkDisclosure = true, disclosed = 1000, shownDeadline = original })
            end
            return realSet(...)
        end
        -- Nobody else is on it, so the creator's own proposal is applied
        -- as it is made.
        s.amendments.propose(f.creator, c.id,
            CB.AMENDMENT.SHORTEN_DEADLINE, { seconds = 9000 })
        s.storage.setDeadline = realSet

        truthy(fired, 'the deadline was never written')
        truthy(accepted, 'the acceptance stands')
        eq(s.storage.readContract(c.id).deadline_at, original,
            'shortened under a hunter who never agreed to it')
        truthy(holding(s, c), 'and they still hold it')
    end end
    it('puts the deadline back (memory)', run(newStack))
    it('puts the deadline back (copying)', run(newCopyingStack))
    it('puts the deadline back (mysql)', run(mysqlStack))
end)

describe('a deadline brought in with nobody else on the contract', function()
    it('is brought in, from the edit and from a solo proposal alike', function()
        local s, f, c, original = deadlineRace(newStack)
        truthy(s.contracts.revise(f.creator, c.id, { deadlineSeconds = 3600 }))
        local edited = s.storage.readContract(c.id).deadline_at
        truthy(edited < original, 'the edit did nothing')

        s.amendments.propose(f.creator, c.id,
            CB.AMENDMENT.SHORTEN_DEADLINE, { seconds = 600 })
        eq(s.storage.readContract(c.id).deadline_at, edited - 600,
            'the proposal did nothing')
    end)

    it('is brought in over a hunter who agreed to it', function()
        local s, f, c, original = deadlineRace(newStack)
        truthy(s.contracts.accept(f.hunter, c.id, false,
            { checkDisclosure = true, disclosed = 1000, shownDeadline = original }))
        local p = s.amendments.propose(f.creator, c.id,
            CB.AMENDMENT.SHORTEN_DEADLINE, { seconds = 600 })
        truthy(p and p.id)
        local ok, err, outcome = s.amendments.respond(f.hunter, p.id, true)
        truthy(ok, tostring(err))
        eq(outcome, 'applied')
        eq(s.storage.readContract(c.id).deadline_at, original - 600)
    end)
end)

--- RACE F12: an edit writing back the row it read.
---
--- revise read the contract, awaited its checks and the deadline's own
--- writes, then wrote the whole row back. A reward withdrawal landing in
--- those awaits re-clamps the buyout and the stake to the smaller escrow,
--- and the write put the old ceilings back: a buyout worth three times a
--- reward that had been taken out, which the target and the client could
--- use to move money between them.
describe('RACE F12: an edit lands on a reward being withdrawn', function()
    local function placed(make)
        local s = make()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 }, bonus = { cash = 2500 } },
            bailoutAmount = 999999, penaltyAmount = 999999,
        })
        truthy(c)
        local bonus
        for _, l in ipairs(s.storage.readEscrow(c.id)) do
            if l.portion == CB.PORTION.BONUS then bonus = l.id end
        end
        truthy(bonus, 'a bonus line to withdraw')
        return s, f, c, bonus
    end

    local function run(make, hookName, changes) return function()
        local s, f, c, bonus = placed(make)
        local before = s.storage.readContract(c.id)

        local real = s.storage[hookName]
        local fired, clamped = false, nil
        s.storage[hookName] = function(...)
            if not fired then
                fired = true
                truthy(s.contracts.withdrawReward(f.creator, c.id, { bonus }))
                clamped = s.storage.readContract(c.id)
            end
            return real(...)
        end
        local ok, err = s.contracts.revise(f.creator, c.id, changes)
        s.storage[hookName] = real

        truthy(fired, 'the withdrawal never landed')
        truthy(ok, tostring(err))
        truthy(clamped.bailout_amount < before.bailout_amount, 'the fixture re-clamps')
        local after = s.storage.readContract(c.id)
        eq(after.bailout_amount, clamped.bailout_amount,
            'the edit put back a buyout ceiling for a reward that was taken out')
        eq(after.penalty_amount, clamped.penalty_amount,
            'and the stake ceiling with it')
    end end

    it('keeps the re-clamp under a deadline edit (copying)',
        run(newCopyingStack, 'setDeadline', { deadlineSeconds = 7200 }))
    it('keeps the re-clamp under a deadline edit (mysql)',
        run(mysqlStack, 'setDeadline', { deadlineSeconds = 7200 }))
    it('keeps the re-clamp under a reason edit (copying)',
        run(newCopyingStack, 'readHunters', { reason = 'Owes money' }))
    it('keeps the re-clamp under a reason edit (mysql)',
        run(mysqlStack, 'readHunters', { reason = 'Owes money' }))
end)

--- RACE F13: a pause ends while a hunter is staking, and the client cuts.
---
--- Ending a pause pushes the deadline out by the pause's length. The check
--- after the hunter's row compared the deadline itself, so a cut no bigger
--- than the pause that ended in the same awaits was invisible to it.
describe('RACE F13: a pause ends and the client cuts while a hunter is staking', function()
    local function run(make) return function()
        local s, f, c = deadlineRace(make)
        local now = os.time()
        s.storage.setDeadline(c.id, nil, now - 1500)
        truthy(s.storage.startPause(c.id, now - 3600))
        -- Thirty-five minutes on the stopped clock: enough to stake on.
        local shown = s.storage.readContract(c.id).deadline_at
        local before = money(3)

        local realCount = s.storage.countHunterContracts
        local fired = false
        s.storage.countHunterContracts = function(...)
            if not fired then
                fired = true
                truthy(s.storage.endPause(c.id, now - 3600, 3600), 'the pause ends')
                truthy(s.contracts.revise(f.creator, c.id, { deadlineSeconds = 60 }),
                    'nobody holds it yet, so the cut stands')
            end
            return realCount(...)
        end
        local ok, err = s.contracts.accept(f.hunter, c.id, false,
            { checkDisclosure = true, disclosed = 1000, shownDeadline = shown })
        s.storage.countHunterContracts = realCount

        truthy(fired, 'the cut never landed')
        falsy(ok, 'staked on minutes the hunter was never shown')
        eq(err, CB.ERR.TERMS_CHANGED)
        eq(money(3), before, 'and the stake came back')
        falsy(holding(s, c), 'and nobody holds the contract')
    end end
    it('refuses the acceptance (memory)', run(newStack))
    it('refuses the acceptance (copying)', run(newCopyingStack))
    it('refuses the acceptance (mysql)', run(mysqlStack))
end)

--- A cut sits in the store until the look for holders is done, where the
--- expiry pass can see it. One leaving a second could end the contract,
--- forfeiting a stake, before it was put back.
describe('a deadline brought in', function()
    it('is never brought within five minutes by an edit', function()
        local s, f, c = deadlineRace(newStack)
        truthy(s.contracts.revise(f.creator, c.id, { deadlineSeconds = 1 }))
        truthy(s.storage.readContract(c.id).deadline_at - os.time() >= 300,
            'an edit left the contract seconds from expiring')
    end)

    it('is refused, not written, when a rule would leave under five minutes', function()
        local s, _, c, original = deadlineRace(newStack)
        local moved, err = s.contracts.bringDeadlineIn(c.id, function()
            return os.time() + 299
        end)
        falsy(moved)
        eq(err, CB.ERR.INVALID_INPUT)
        eq(s.storage.readContract(c.id).deadline_at, original, 'and nothing moved')
        truthy(s.contracts.bringDeadlineIn(c.id, function() return os.time() + 300 end),
            'five minutes is allowed')
    end)

    it('leaves the reason alone when the edit is refused', function()
        -- On the memory store the row read is the stored row: a reason set on
        -- it stood even though the edit it came with was refused.
        local s, f, c, original = deadlineRace(newStack)
        local realSet = s.storage.setDeadline
        local fired = false
        s.storage.setDeadline = function(...)
            if not fired then
                fired = true
                truthy(s.contracts.accept(f.hunter, c.id, false,
                    { checkDisclosure = true, disclosed = 1000, shownDeadline = original }))
            end
            return realSet(...)
        end
        local ok = s.contracts.revise(f.creator, c.id,
            { deadlineSeconds = 600, reason = 'Something else entirely' })
        s.storage.setDeadline = realSet
        falsy(ok)
        eq(s.storage.readContract(c.id).reason, 'x', 'refused, reason and all')
    end)

    it('is put back even when the deadline keeps moving under it', function()
        -- Three moves landing between the put-back's reads used to leave the
        -- cut in place under the hunter it had just been refused over.
        local s, f, c, original = deadlineRace(newStack)
        local realSet = s.storage.setDeadline
        local calls = 0
        s.storage.setDeadline = function(id, expected, deadline)
            calls = calls + 1
            if calls == 1 then
                truthy(s.contracts.accept(f.hunter, c.id, false,
                    { checkDisclosure = true, disclosed = 1000, shownDeadline = original }))
            elseif calls >= 2 and calls <= 4 then
                -- An extension lands first, each time: the guard misses.
                local row = s.storage.readContract(id)
                realSet(id, nil, row.deadline_at + 1)
            end
            return realSet(id, expected, deadline)
        end
        local ok = s.contracts.revise(f.creator, c.id, { deadlineSeconds = 600 })
        s.storage.setDeadline = realSet
        falsy(ok)
        truthy(s.storage.readContract(c.id).deadline_at >= original,
            'the cut stayed under a hunter who never agreed to it')
    end)
end)

--- Nothing sent to a viewer says when an anonymous contract was placed
--- (§14.32). The mysql store minted ids from the clock to the second, which
--- went to every viewer next to the rounded deadline.
describe('the id of a contract', function()
    local function placedAt(make, offset)
        math.randomseed(4242)
        local s = make()
        local f = fixture(s)
        Env.time = Env.time + offset
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', anonymous = true,
            reward = { baseline = { cash = 1000 } },
        })
        truthy(c)
        return s, f, c
    end

    it('does not depend on when it was placed', function()
        for _, make in ipairs({ newStack, mysqlStack }) do
            local _, _, a = placedAt(make, 0)
            local _, _, b = placedAt(make, 12345)
            eq(a.id, b.id, 'the id changed with the clock')
            truthy(a.id:match('^ct[a-z0-9]+$') and #a.id >= 8, 'a well-formed id: ' .. a.id)
        end
    end)

    it('does not date a proposal either', function()
        for _, make in ipairs({ newStack, mysqlStack }) do
            local s, f, c = placedAt(make, 17)
            truthy(s.contracts.accept(f.hunter, c.id, false))
            math.randomseed(99)
            local p = s.amendments.propose(f.creator, c.id,
                CB.AMENDMENT.SHORTEN_DEADLINE, { seconds = 600 })
            truthy(p)
            eq(p.expires_at % 300, 0, 'the expiry dates the proposal to the second')
            truthy(p.expires_at >= os.time() + Config.Amendments.ProposalExpirySeconds,
                'and never gives less time than it promises')
            local s2, f2, c2 = placedAt(make, 17)
            truthy(s2.contracts.accept(f2.hunter, c2.id, false))
            Env.time = Env.time + 777
            math.randomseed(99)
            local p2 = s2.amendments.propose(f2.creator, c2.id,
                CB.AMENDMENT.SHORTEN_DEADLINE, { seconds = 600 })
            eq(p2.id, p.id, 'the proposal id changed with the clock')
        end
    end)
end)

--------------------------------------------------------------------------
-- A hunter part-way through accepting, and everything that can land on them
--------------------------------------------------------------------------

local function staked(make, penalty, mode)
    local s = make()
    local f = fixture(s)
    Env.players[3].PlayerData.money.bank = 50000
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'x', mode = mode or CB.MODE.COMPETITIVE,
        reward = { baseline = { cash = 20000 } }, penaltyAmount = penalty or 2000,
    })
    truthy(c)
    return s, f, c
end

local function stakeHeld(s, c, cid)
    local total = 0
    for _, l in ipairs(s.storage.readEscrow(c.id)) do
        if l.portion == CB.PORTION.STAKE and l.staker == cid and l.state == CB.ESCROW_STATE.HELD then
            total = total + (l.amount or 0)
        end
    end
    return total
end

--- Run `second` once, just after the acceptance's row lands.
local function afterRow(s, second)
    local real, out, fired = s.storage.addHunter, nil, false
    s.storage.addHunter = function(...)
        local r = table.pack(real(...))
        -- Marked before the call: the second request may write a row too.
        if not fired then fired = true out = table.pack(second()) end
        return table.unpack(r, 1, r.n)
    end
    return function()
        s.storage.addHunter = real
        if not out then return nil end
        return table.unpack(out, 1, out.n)
    end
end

describe('RACE F14: the penalty changes while a hunter is part-way through accepting', function()
    local function run(make) return function()
        local s, f, c = staked(make, 2000)
        local done = afterRow(s, function()
            return s.amendments.improve(f.creator, c.id, CB.AMENDMENT.LOWER_PENALTY, { amount = 500 })
        end)
        local ok, err = s.contracts.accept(f.hunter, c.id, false,
            { checkDisclosure = true, disclosed = 2000 })
        local lowered, why = done()
        truthy(ok, tostring(err))
        falsy(lowered, 'the cut skipped the stake being taken')
        eq(why, CB.ERR.BUSY)
        eq(stakeHeld(s, c, 'HUNTER01'), s.storage.readContract(c.id).penalty_amount,
            'a hunter holding a stake the contract does not ask for')
    end end
    it('refuses the cut as busy (memory)', run(newStack))
    it('refuses the cut as busy (mysql)', run(mysqlStack))

    it('does not apply a raise alone under a hunter who is joining', function()
        local s, f, c = staked(newStack, 500)
        local done = afterRow(s, function()
            return s.amendments.propose(f.creator, c.id, CB.AMENDMENT.RAISE_PENALTY, { amount = 2000 })
        end)
        truthy(s.contracts.accept(f.hunter, c.id, false))
        local p = done()
        falsy(p and p.outcome == 'applied', 'applied, agreed by nobody else, under a staked hunter')
        eq(s.storage.readContract(c.id).penalty_amount, 500)
        eq(stakeHeld(s, c, 'HUNTER01'), 500)
    end)
end)

describe('RACE F15: one player\'s two acceptances at once', function()
    it('never leaves them over MaxAcceptedPerHunter', function()
        local s = newStack()
        local f = fixture(s)
        Config.Limits.MaxAcceptedPerHunter = 1
        Env.addPlayer({ source = 6, citizenid = 'TARGET02', license = 'license:t2',
            firstname = 'Tia', lastname = 'Orr' })
        local x = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            mode = CB.MODE.COMPETITIVE, reward = { baseline = { cash = 1000 } } })
        local y = s.contracts.create(f.creator, { targetCid = 'TARGET02', reason = 'x',
            mode = CB.MODE.COMPETITIVE, reward = { baseline = { cash = 1000 } } })
        truthy(x and y)
        local done = afterRow(s, function() return s.contracts.accept(f.hunter, y.id, false) end)
        truthy(s.contracts.accept(f.hunter, x.id, false))
        falsy(done(), 'the second counted the first as not there')
        eq(s.storage.countHunterContracts('HUNTER01', { active = true, accepted = true }), 1)
    end)
end)

describe('RACE F16: a throw part-way through accepting', function()
    it('takes the acceptance back rather than leave it joining', function()
        local s, f, c = staked(newStack, 1000, CB.MODE.EXCLUSIVE)
        local before = money(3)
        local armed, thrown = false, false
        local realAdd, realRead = s.storage.addHunter, s.storage.readContract
        s.storage.addHunter = function(...) armed = true return realAdd(...) end
        s.storage.readContract = function(...)
            if armed and not thrown then thrown = true error('connection lost', 0) end
            return realRead(...)
        end
        local ok = pcall(s.contracts.accept, f.hunter, c.id, false)
        s.storage.addHunter, s.storage.readContract = realAdd, realRead
        truthy(thrown, 'the throw never happened')
        falsy(ok, 'the throw is still an error to the caller')
        local row = s.storage.readHunter(c.id, 'HUNTER01')
        falsy(row and (row.state == 'joining' or row.state == 'active'),
            'left on the contract: ' .. tostring(row and row.state))
        eq(money(3), before, 'and the stake is back')
        eq(s.storage.readContract(c.id).state, CB.STATE.ACTIVE, 'and the contract open')
        truthy(s.contracts.accept(f.hunter, c.id, false), 'so it can be taken again')
    end)

    it('takes it back when the fee charge throws, rather than leave an unpaid anonymous hunter', function()
        local s, f, c = staked(newStack, 1000)
        Config.Anonymity.HunterFee = 1500
        local before = money(3)
        local fns = f.hunter.player.Functions
        local realRemove = fns.RemoveMoney
        fns.RemoveMoney = function(account, amount, ...)
            if amount == 1500 then error('framework refused', 0) end
            return realRemove(account, amount, ...)
        end
        local ok = pcall(s.contracts.accept, f.hunter, c.id, true)
        fns.RemoveMoney = realRemove
        falsy(ok)
        local row = s.storage.readHunter(c.id, 'HUNTER01')
        falsy(row and row.state == 'active', 'anonymous on the contract without paying for it')
        eq(money(3), before, 'and the stake came back')
    end)

    it('is finished by the tick when taking it back throws too', function()
        local s, f, c = staked(newStack, 1000)
        local before = money(3)
        local armed, broken = false, false
        local realAdd, realRead, realRelease = s.storage.addHunter, s.storage.readContract,
            s.storage.claimEscrowLine
        s.storage.addHunter = function(...) armed = true return realAdd(...) end
        s.storage.readContract = function(...)
            if armed and not broken then broken = true error('connection lost', 0) end
            return realRead(...)
        end
        -- The store stays down for the taking back as well.
        s.storage.claimEscrowLine = function(...)
            if broken and armed then error('connection lost', 0) end
            return realRelease(...)
        end
        falsy(pcall(s.contracts.accept, f.hunter, c.id, false))
        armed = false
        s.storage.addHunter, s.storage.readContract, s.storage.claimEscrowLine =
            realAdd, realRead, realRelease
        truthy(s.contracts.retryStuckJoins() >= 1, 'nothing left to finish it')
        local row = s.storage.readHunter(c.id, 'HUNTER01')
        falsy(row and (row.state == 'joining' or row.state == 'active'), tostring(row and row.state))
        eq(money(3), before, 'and the stake is back')
    end)
end)

describe('the anonymity fee and the stake from different accounts', function()
    it('takes the stake from cash when the bank only covers the fee', function()
        local s, f, c = staked(newStack, 1000)
        Config.Anonymity.HunterFee, Config.Anonymity.FeeAccount = 500, 'bank'
        Env.players[3].PlayerData.money.bank = 1000
        Env.players[3].PlayerData.money.cash = 5000
        local ok, err = s.contracts.accept(f.hunter, c.id, true)
        truthy(ok, 'refused with 6,000 on hand for 1,500 owed: ' .. tostring(err))
        eq(Env.players[3].PlayerData.money.bank, 500, 'the fee from the bank')
        eq(Env.players[3].PlayerData.money.cash, 4000, 'the stake from cash')
    end)
end)

describe('RACE F17: two cuts to one stake at once', function()
    it('lets one through and answers the other busy', function()
        local s, f, c = staked(mysqlStack, 2000)
        truthy(s.contracts.accept(f.hunter, c.id, false))
        local real, second, fired = s.storage.setEscrowAmount, nil, false
        s.storage.setEscrowAmount = function(...)
            if not fired then
                fired = true
                second = table.pack(s.amendments.improve(f.creator, c.id,
                    CB.AMENDMENT.LOWER_PENALTY, { amount = 1000 }))
            end
            return real(...)
        end
        truthy(s.amendments.improve(f.creator, c.id, CB.AMENDMENT.LOWER_PENALTY, { amount = 500 }))
        s.storage.setEscrowAmount = real
        falsy(second[1], 'two cuts on one stake side by side')
        eq(second[2], CB.ERR.BUSY)
        eq(stakeHeld(s, c, 'HUNTER01'), 500)
    end)
end)

describe('boot recovery of a stake cut it finds half made', function()
    local function split(stakeAmount, was, now)
        local s = newStack()
        local stake = { id = 'ct00000009:1', contract_id = 'ct00000009', slot = 0,
            portion = CB.PORTION.STAKE, staker = 'HUNTER01', source = 'bank',
            amount = stakeAmount, state = CB.ESCROW_STATE.HELD }
        local owed = { id = 'owe00000009', contract_id = 'ct00000009', slot = 0,
            portion = CB.PORTION.OWED, owed_to = 'HUNTER01', source = 'bank',
            amount = was - now, state = CB.ESCROW_STATE.HELD,
            metadata = { splitFrom = stake.id, stakeWas = was, stakeNow = now } }
        s.storage.writeEscrow('ct00000009', { stake, owed })
        s.escrow.recoverOwed(s.storage.readEscrow('ct00000009'))
        return s, owed.id
    end

    it('pays the split that lowered the stake', function()
        local s, id = split(1000, 2000, 1000)
        eq(#s.storage.readPending('HUNTER01'), 1)
        eq(s.storage.readEscrowLine(id).amount, 1000)
    end)

    it('voids the split whose stake was never lowered', function()
        local s, id = split(2000, 2000, 1000)
        eq(#s.storage.readPending('HUNTER01'), 0)
        eq(s.storage.readEscrowLine(id).amount, 0)
    end)

    it('pays neither way a split whose stake another cut moved', function()
        -- Two cuts from 2,000: this one to 500 lost its guard to one to
        -- 1,000. The stake has moved, but not by this split.
        local s, id = split(1000, 2000, 500)
        eq(#s.storage.readPending('HUNTER01'), 0, 'paid as well as the cut that won')
        eq(s.storage.readEscrowLine(id).amount, 1500, 'left for staff, not destroyed')
    end)
end)

describe('a stake cut whose owed half is voided underneath it', function()
    it('puts the stake back rather than lose the difference', function()
        local s, f, c = staked(newStack, 2000)
        truthy(s.contracts.accept(f.hunter, c.id, false))
        local afterStake = money(3)
        local real = s.storage.setEscrowAmount
        local voided = false
        s.storage.setEscrowAmount = function(id, state, amount, expected)
            if not voided then
                voided = true
                -- Boot recovery reading the owed line as a split that never
                -- happened, while this cut is between its two writes.
                for _, l in ipairs(s.storage.readEscrow(c.id)) do
                    if l.portion == CB.PORTION.OWED then
                        s.escrow.recoverOwed({ l })
                    end
                end
            end
            return real(id, state, amount, expected)
        end
        s.amendments.improve(f.creator, c.id, CB.AMENDMENT.LOWER_PENALTY, { amount = 500 })
        s.storage.setEscrowAmount = real
        local owedLive = 0
        for _, l in ipairs(s.storage.readEscrow(c.id)) do
            if l.portion == CB.PORTION.OWED and l.state == CB.ESCROW_STATE.HELD then
                owedLive = owedLive + (l.amount or 0)
            end
        end
        eq(stakeHeld(s, c, 'HUNTER01') + owedLive + (money(3) - afterStake), 2000,
            'the hunter\'s 2,000 is no longer all accounted for')
    end)
end)

describe('RACE F18: a claim lands on the collection being given back', function()
    local function run(make) return function()
        local s = make()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            penaltyAmount = 500,
            reward = { slots = { { baseline = { cash = 1000 } }, { baseline = { cash = 2000 } } } },
        })
        truthy(s.contracts.accept(f.hunter, c.id, false))
        local p = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.REDUCE_REWARD, { slot = 2 })
        truthy(p)
        local real, fired = s.storage.reduceSlots, false
        s.storage.reduceSlots = function(...)
            if not fired then
                fired = true
                truthy(s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION, {}))
            end
            return real(...)
        end
        s.amendments.respond(f.hunter, p.id, true)
        s.storage.reduceSlots = real
        local after = s.storage.readContract(c.id)
        truthy((after.next_slot or 1) <= (after.payout_slots or 1)
            or after.state == CB.STATE.COMPLETED,
            ('left selling collection %d of %d'):format(after.next_slot or 1, after.payout_slots or 1))
        Env.advance((Config.Limits.SlotCooldownSeconds or 0) + 1)
        truthy(after.state == CB.STATE.COMPLETED
            or s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION, {}),
            'the second collection can still be paid')
    end end
    it('does not strand the contract (memory)', run(newStack))
    it('does not strand the contract (mysql)', run(mysqlStack))
end)

describe('RACE F19: a delivery lands on a bonus raise', function()
    local function run(make) return function()
        local s = make()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            bonusPercent = 10,
            reward = { slots = { { baseline = { cash = 1000 } }, { baseline = { cash = 1000 } } } },
        })
        truthy(s.contracts.accept(f.hunter, c.id, false))
        local real, fired = s.storage.writeEscrow, false
        s.storage.writeEscrow = function(contractId, lines)
            local r = table.pack(real(contractId, lines))
            if not fired and lines[1] and lines[1].portion == CB.PORTION.BONUS and lines[1].derived then
                fired = true
                truthy(s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.KIDNAPPING, {}))
            end
            return table.unpack(r, 1, r.n)
        end
        local ok, err = s.amendments.improve(f.creator, c.id, CB.AMENDMENT.RAISE_BONUS, { percent = 20 })
        s.storage.writeEscrow = real
        truthy(fired, 'the delivery never landed')
        local slot2 = 0
        for _, l in ipairs(s.storage.readEscrow(c.id)) do
            if l.slot == 2 and l.portion == CB.PORTION.BONUS and l.state == CB.ESCROW_STATE.HELD then
                slot2 = slot2 + l.amount
            end
        end
        local percent = s.storage.readContract(c.id).bonus_percent
        if ok then
            eq(percent, 20)
            eq(slot2, 200, 'the card says 20% while collection 2 holds the old bonus')
        else
            eq(percent, 10, 'refused, yet the new percent was stored: ' .. tostring(err))
            eq(slot2, 100)
        end
    end end
    it('keeps the card and the escrow the same (memory)', run(newStack))
    it('keeps the card and the escrow the same (mysql)', run(mysqlStack))
end)

describe('more of the acceptance, pinned', function()
    it('keeps a proposal open when an answer is busy, so it can be given again', function()
        local s, f, c = staked(newStack, 2000)
        truthy(s.contracts.accept(f.hunter, c.id, false))
        local p = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.CHANGE_MODE,
            { mode = CB.MODE.EXCLUSIVE })
        truthy(p and p.outcome == 'open')
        -- The hunter agrees while the client's penalty cut holds the contract.
        local real, fired, answer = s.storage.setEscrowAmount, false, nil
        s.storage.setEscrowAmount = function(...)
            if not fired then
                fired = true
                answer = table.pack(s.amendments.respond(f.hunter, p.id, true))
            end
            return real(...)
        end
        truthy(s.amendments.improve(f.creator, c.id, CB.AMENDMENT.LOWER_PENALTY, { amount = 500 }))
        s.storage.setEscrowAmount = real
        local ok, err, outcome = table.unpack(answer, 1, answer.n)
        falsy(ok)
        eq(err, CB.ERR.BUSY)
        eq(outcome, 'busy')
        eq(s.storage.readAmendment(p.id).outcome, 'open', 'failed for good over an instant')
    end)

    it('does not confirm a row something else took back in the meantime', function()
        local s, f, c = staked(newStack, 1000)
        local before = money(3)
        local real, fired = s.storage.writeEscrow, false
        s.storage.writeEscrow = function(contractId, lines)
            local r = table.pack(real(contractId, lines))
            if not fired and lines[1] and lines[1].portion == CB.PORTION.STAKE then
                fired = true
                -- Recovery takes the joining row back as left over.
                s.contracts.recoverJoining(s.storage.readContract(c.id))
            end
            return table.unpack(r, 1, r.n)
        end
        local ok = s.contracts.accept(f.hunter, c.id, false)
        s.storage.writeEscrow = real
        falsy(ok, 'told they hold it')
        local row = s.storage.readHunter(c.id, 'HUNTER01')
        falsy(row and row.state == 'active', 'holding the contract with no stake behind it')
        eq(money(3), before, 'and nothing of theirs is held')
    end)

    it('refuses a stake taken at a penalty re-clamped in the awaits', function()
        -- On mysql, where the acceptance's read is a copy the re-clamp does
        -- not reach.
        local s, f = staked(mysqlStack, 0)
        local c2 = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'y', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 }, bonus = { cash = 2500 } },
            penaltyAmount = 999999,
        })
        truthy(c2)
        local bonus
        for _, l in ipairs(s.storage.readEscrow(c2.id)) do
            if l.portion == CB.PORTION.BONUS then bonus = l.id end
        end
        local shown = s.storage.readContract(c2.id).penalty_amount
        -- A withdrawal can no longer land inside an acceptance (both hold
        -- the contract), so the re-price is written directly: the re-read
        -- is the backstop for any path that re-prices without the lock.
        local real, fired = s.storage.countHunterContracts, false
        s.storage.countHunterContracts = function(...)
            if not fired then
                fired = true
                s.storage.setContractFields(c2.id, { penalty_amount = shown - 1000 })
            end
            return real(...)
        end
        local before = money(3)
        local ok, err = s.contracts.accept(f.hunter, c2.id, false,
            { checkDisclosure = true, disclosed = shown })
        s.storage.countHunterContracts = real
        truthy(fired, 'the re-price never landed')
        truthy(s.storage.readContract(c2.id).penalty_amount < shown, 'the fixture re-prices')
        falsy(ok, 'staked at a penalty the contract no longer asks for')
        eq(err, CB.ERR.TERMS_CHANGED)
        eq(money(3), before)
    end)

    it('does not let a withdrawal land inside an acceptance', function()
        local s, f = staked(mysqlStack, 0)
        local c2 = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'y', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 }, bonus = { cash = 2500 } },
            penaltyAmount = 999999,
        })
        truthy(c2)
        local bonus
        for _, l in ipairs(s.storage.readEscrow(c2.id)) do
            if l.portion == CB.PORTION.BONUS then bonus = l.id end
        end
        local shown = s.storage.readContract(c2.id).penalty_amount
        local real, answer = s.storage.countHunterContracts, nil
        s.storage.countHunterContracts = function(...)
            if not answer then
                answer = table.pack(s.contracts.withdrawReward(f.creator, c2.id, { bonus }))
            end
            return real(...)
        end
        local ok, err = s.contracts.accept(f.hunter, c2.id, false,
            { checkDisclosure = true, disclosed = shown })
        s.storage.countHunterContracts = real
        truthy(answer)
        falsy(answer[1])
        eq(answer[2], CB.ERR.BUSY, 'the client is told to try again')
        truthy(ok, tostring(err))
        eq(s.storage.readContract(c2.id).penalty_amount, shown, 'and nothing was re-priced')
    end)

    it('does not count a returned top-up as a paid collection', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE, bonusPercent = 10,
            reward = { slots = { { baseline = { cash = 1000 } }, { baseline = { cash = 1000 } } } },
        })
        truthy(s.amendments.improve(f.creator, c.id, CB.AMENDMENT.RAISE_BONUS, { percent = 20 }))
        for _, l in ipairs(s.storage.readEscrow(c.id)) do
            if l.slot == 2 and l.derived then
                s.escrow.release(c.id, f.creator.cid, { line = l.id }, 'test_returned')
            end
        end
        local extra = s.escrow.bonusTopUp(c.id, 20, 30)
        local onTwo = false
        for _, l in ipairs(extra) do if l.slot == 2 then onTwo = true end end
        truthy(onTwo, 'a collection nobody has been paid for was treated as paid')
    end)

    it('does not top up a collection the payout queued for its hunter', function()
        -- Paid, but held: the hunter's pockets were full, so the baseline
        -- is owed to them. No later claim reaches a bonus added beside it,
        -- so topping it up locked the client's money away until the end.
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE, bonusPercent = 10,
            reward = { slots = { { baseline = { cash = 1000 } }, { baseline = { cash = 1000 } } } },
        })
        truthy(s.contracts.accept(f.hunter, c.id, false))
        Env.players[3]._refuseMoney = true
        truthy(s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION))
        Env.players[3]._refuseMoney = false
        eq(s.storage.readContract(c.id).next_slot, 2)

        local before = money(1)
        truthy(s.amendments.improve(f.creator, c.id, CB.AMENDMENT.RAISE_BONUS, { percent = 50 }))
        eq(before - money(1), 400, 'only the collection still to come is topped up')
        for _, l in ipairs(s.storage.readEscrow(c.id)) do
            falsy(l.slot == 1 and l.derived and l.state == CB.ESCROW_STATE.HELD and not l.owed_to,
                'a new bonus line on the collection already paid')
        end
    end)

    it('does not top up a baseline on its way back to the client', function()
        -- Withdrawn, but queued: the client's pockets were full. It is owed
        -- to them and no longer the contract's to pay, so a bonus beside it
        -- was money locked away until the contract ended.
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE, bonusPercent = 10,
            reward = { slots = { { baseline = { cash = 1000, bank = 1000 } } } },
        })
        local bankLine
        for _, l in ipairs(s.storage.readEscrow(c.id)) do
            if l.portion == CB.PORTION.BASELINE and l.source == 'bank' then bankLine = l.id end
        end
        Env.players[1]._refuseMoney = true
        truthy(s.contracts.withdrawReward(f.creator, c.id, { bankLine }))
        Env.players[1]._refuseMoney = false
        eq(s.storage.readEscrowLine(bankLine).owed_to, 'CREATOR1', 'queued back to the client')

        local extra = s.escrow.bonusTopUp(c.id, 10, 50, 1)
        for _, l in ipairs(extra) do
            falsy(l.source == 'bank', 'a bonus on a baseline the client is being given back')
        end
        eq(#extra, 1, 'the cash baseline, which the contract still pays')
    end)

    it('prices two raises one after the other, not both from the same start', function()
        -- Both read 10%, both took their top-up: 40 points of escrow for a
        -- bonus shown at 20 or 30.
        local s = mysqlStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE, bonusPercent = 10,
            reward = { slots = { { baseline = { cash = 1000 } } } },
        })
        local real, second = s.storage.readEscrow, nil
        s.storage.readEscrow = function(...)
            if not second then
                second = table.pack(s.amendments.improve(f.creator, c.id,
                    CB.AMENDMENT.RAISE_BONUS, { percent = 30 }))
            end
            return real(...)
        end
        s.amendments.improve(f.creator, c.id, CB.AMENDMENT.RAISE_BONUS, { percent = 20 })
        s.storage.readEscrow = real
        falsy(second[1], 'the second raise ran inside the first')
        eq(second[2], CB.ERR.BUSY)
        local bonus = s.escrow.moneyValue(c.id, { portion = CB.PORTION.BONUS })
        eq(bonus, math.floor(1000 * s.storage.readContract(c.id).bonus_percent / 100),
            'the bonus held is the bonus shown')
    end)

    it('never leaves one player over the cap when the second lands before the first row', function()
        local s = newStack()
        local f = fixture(s)
        Config.Limits.MaxAcceptedPerHunter = 1
        Env.addPlayer({ source = 6, citizenid = 'TARGET02', license = 'license:t2',
            firstname = 'Tia', lastname = 'Orr' })
        local x = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            mode = CB.MODE.COMPETITIVE, reward = { baseline = { cash = 1000 } } })
        local y = s.contracts.create(f.creator, { targetCid = 'TARGET02', reason = 'x',
            mode = CB.MODE.COMPETITIVE, reward = { baseline = { cash = 1000 } } })
        local real, fired, second = s.storage.readHunters, false, nil
        s.storage.readHunters = function(...)
            if not fired then
                fired = true
                second = s.contracts.accept(f.hunter, y.id, false)
            end
            return real(...)
        end
        local first = s.contracts.accept(f.hunter, x.id, false)
        s.storage.readHunters = real
        falsy(first and second, 'both passed a cap of one')
        eq(s.storage.countHunterContracts('HUNTER01', { active = true, accepted = true }), 1)
    end)
end)

describe('proposals while a hunter is part-way on', function()
    it('are not applied alone over a joining row that was left behind', function()
        local s, f, c = staked(newStack, 0)
        s.storage.addHunter({ id = 'hnstuck01', contract_id = c.id, hunter_cid = 'HUNTER01',
            hunter_account = 'license:ccc', alias = 'Operative #1', anon = false,
            accepted_at = os.time(), state = 'joining' })
        local p = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.CHANGE_REASON,
            { reason = 'Something else' })
        truthy(p)
        eq(p.outcome, 'open', 'applied as agreed by nobody else, over a hunter on the contract')
    end)

    it('closes a solo proposal that was busy, so it can be made again', function()
        local s, f, c = staked(newStack, 2000)
        local real, fired, p = s.storage.setContractFields, false, nil
        s.storage.setContractFields = function(...)
            if not fired then
                fired = true
                p = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.RAISE_PENALTY, { amount = 3000 })
            end
            return real(...)
        end
        truthy(s.amendments.improve(f.creator, c.id, CB.AMENDMENT.LOWER_PENALTY, { amount = 1000 }))
        s.storage.setContractFields = real
        truthy(p, 'the proposal was never made')
        eq(p.outcome, 'failed')
        eq(p.error, CB.ERR.BUSY)
        eq(s.storage.readAmendment(p.id).outcome, 'failed',
            'left open, with nobody else who could ever answer it')
        truthy(s.amendments.propose(f.creator, c.id, CB.AMENDMENT.RAISE_PENALTY, { amount = 3000 }),
            'and it can be made again')
    end)
end)

describe('RACE F20: the tick settles an instant buyout alongside buy()', function()
    local function run(order) return function()
        local s = newStack()
        local f = fixture(s)
        Env.players[2].PlayerData.money.bank = 100000
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            mode = CB.MODE.COMPETITIVE, reward = { baseline = { cash = 10000 } }, bailoutAmount = 15000 })
        local creator, target = money(1), money(2)
        local real, fired = s.storage.setBailoutQueue, false
        local queued
        s.storage.setBailoutQueue = function(...)
            local r = table.pack(real(...))
            if not fired then
                fired = true
                if order == 'during' then s.bailout.processQueue() else
                    local row = s.storage.readContract(c.id)
                    queued = { bailout_paid_amount = row.bailout_paid_amount,
                        bailout_paid_by = row.bailout_paid_by, bailout_paid_account = row.bailout_paid_account }
                end
            end
            return table.unpack(r, 1, r.n)
        end
        s.bailout.buy(f.target, c.id)
        s.storage.setBailoutQueue = real
        if order == 'after' then
            -- The tick read the record before buy() finished, and settles now.
            s.bailout.settle(c.id, queued.bailout_paid_amount, queued.bailout_paid_by,
                queued.bailout_paid_account, { retryable = true })
        end
        s.bailout.processQueue()
        eq(target - money(2), 15000, 'the target was refunded a buyout they got')
        eq(money(1) - creator, 25000)
    end end
    it('while buy() is settling', run('during'))
    it('after buy() has settled', run('after'))
end)

describe('RACE F21: a write-back of a stale contract after a re-clamp', function()
    local function run(make) return function()
        local s = make()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            mode = CB.MODE.COMPETITIVE, bailoutAmount = 999999, penaltyAmount = 999999,
            reward = { baseline = { cash = 5000 }, bonus = { cash = 2500 } } })
        local bonus
        for _, l in ipairs(s.storage.readEscrow(c.id)) do
            if l.portion == CB.PORTION.BONUS then bonus = l.id end
        end
        -- A re-price landing while the raise is in its awaits. A withdrawal
        -- can no longer be it (both hold the contract), so it is written
        -- directly: the point is that the raise does not write back the
        -- figures it read before it.
        local real, fired, clamped = s.storage.readEscrow, false, nil
        s.storage.readEscrow = function(...)
            if not fired then
                fired = true
                truthy(s.contracts.withdrawReward(f.creator, c.id, { bonus }) == false,
                    'the withdrawal waits its turn')
                s.storage.setContractFields(c.id, { bailout_amount = 12345 })
                clamped = s.storage.readContract(c.id).bailout_amount
            end
            return real(...)
        end
        s.amendments.improve(f.creator, c.id, CB.AMENDMENT.RAISE_BONUS, { percent = 10 })
        s.storage.readEscrow = real
        truthy(fired)
        eq(s.storage.readContract(c.id).bailout_amount, clamped,
            'a stale copy put the buyout ceiling back')
    end end
    it('keeps the re-clamp (copying)', run(newCopyingStack))
    it('keeps the re-clamp (mysql)', run(mysqlStack))
end)

describe('two withdrawals from one collection at once', function()
    --- Each checked that the collection stayed funded against lines it read
    --- before its awaits. Two at once, each taking a different line off the
    --- same collection, both passed and left a live contract paying $0.
    it('lets one through and tells the other it was busy', function()
        local s = mysqlStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 1000, bank = 2000 } }, bonusPercent = 0,
        })
        truthy(c)
        local cashLine, bankLine
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.portion == CB.PORTION.BASELINE and line.source == 'cash' then cashLine = line.id end
            if line.portion == CB.PORTION.BASELINE and line.source == 'bank' then bankLine = line.id end
        end
        truthy(cashLine and bankLine)

        -- The second is sent while the first is waiting on its read of the
        -- escrow, which is where the two used to see each other's line as
        -- still there.
        local real = s.storage.readEscrow
        local second
        s.storage.readEscrow = function(...)
            if not second then
                second = table.pack(s.contracts.withdrawReward(f.creator, c.id, { bankLine }))
            end
            return real(...)
        end
        local ok, err = s.contracts.withdrawReward(f.creator, c.id, { cashLine })
        s.storage.readEscrow = real

        truthy(ok, tostring(err))
        truthy(second)
        falsy(second[1], 'the second ran inside the first')
        eq(second[2], CB.ERR.BUSY)
        truthy(s.escrow.moneyValue(c.id) > 0, 'the live collection still pays something')
    end)
end)
