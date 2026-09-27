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
        local realWrite = s.storage.writeEscrow
        local fired = false
        s.storage.writeEscrow = function(contractId, lines)
            if not fired and lines[1] and lines[1].portion == CB.PORTION.STAKE then
                fired = true
                local ok, err
                if which == 'cancel' then
                    ok, err = s.contracts.cancel(f.creator, c.id)
                else
                    ok, err = s.bailout.buy(f.target, c.id)
                end
                print('  ' .. which .. ' ->', ok, err)
            end
            return realWrite(contractId, lines)
        end
        local ok1, err1 = s.contracts.accept(f.hunter, c.id, fee ~= nil)
        s.storage.writeEscrow = realWrite
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
        -- Charged first, before the stake, so the refusal has two things
        -- to give back, not one.
        eq(run('cancel', 1500), 10000, 'the fee for anonymity on a contract '
            .. 'the hunter never got was kept')
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

        local realWrite = s.storage.writeEscrow
        local fired, revised = false, nil
        s.storage.writeEscrow = function(contractId, lines)
            if not fired and lines[1] and lines[1].portion == CB.PORTION.STAKE then
                fired = true
                -- Past the accept's check, before its row exists: nobody
                -- holds the contract, so the edit is allowed.
                revised = s.contracts.revise(f.creator, c.id, { deadlineSeconds = 600 })
            end
            return realWrite(contractId, lines)
        end
        local ok, err = s.contracts.accept(f.hunter, c.id, false,
            { checkDisclosure = true, disclosed = 1000, shownDeadline = original })
        s.storage.writeEscrow = realWrite

        truthy(fired, 'the stake was never written')
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
