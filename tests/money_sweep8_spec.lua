--- Step 8d: the money sweep (sweep 8, M1-M11), each finding pinned by the
--- repro that showed it, with the figures varied.
---
--- M1  the funds backend is each organisation's own: a switch moves one,
---     and every other organisation's balance stays where it is kept;
---     removal checks the money under either backend; the cuts already
---     taken stay known after a switch (the follow-on).
--- M2  ledger -> Renewed-Banking makes the job's account first.
--- M3  a dead drop holds nothing while the Organisation is off.
--- M4  a cut taken on a give that never arrived is given back when the
---     line goes to its placer.
--- M7  the part of a payout handed over at the kill is cut too.
--- M8  the organisation's own gives decide by what arrived; a deposit's
---     give-back that fails is owed.
--- M9  an armory move whose put-in raised after placing is not put back.
--- M10 money moves are audited whatever LogAllActions says.
--- (M5 and M11, the crash windows, are in tests/workflows/matrix_spec.lua.)

local W = require('tests.harness.org_world')
local QbxJobs = W.QbxJobs

local STAFF = { staff = true, cid = 'ADMIN001', source = 6 }

local function ledgerSum(s, orgId)
    local sum = 0
    for _, row in ipairs(s.storage.readOrgRows('funds', orgId) or {}) do
        if row.backend == 'internal' then sum = sum + (tonumber(row.amount) or 0) end
    end
    return sum
end

local function twoOrgs(opts)
    local s = W.world({ bank = opts and opts.bank, configure = function()
        Config.Organisation.SeveralOrganisations = true
        Config.Integrations.Banking = 'auto'
    end })
    W.crew(s)
    truthy(W.ask(6, 'orgCreate', { job = 'syndicate', label = 'Syn' }).ok, 'the second organisation')
    return s, s.org.byId('hitman'), s.org.byId('syndicate')
end

describe('step 8d M1: each organisation keeps its own funds backend', function()
    it('ledger to the bank from one organisation leaves the other\'s ledger balance where it is', function()
        local s, a, b = twoOrgs()
        local Funds = s.org.Funds
        eq(Funds.backend(a), 'internal')
        truthy(W.ask(6, 'orgFundsMove', { direction = 'deposit', amount = 1400, reason = 'a', nonce = 'a1' }).ok)
        truthy(W.ask(6, 'orgFundsMove', { org = 'syndicate', direction = 'deposit', amount = 2600, reason = 'b',
            nonce = 'b1' }).ok)
        Natives.resourceStates['Renewed-Banking'] = 'started'
        local r = W.ask(6, 'orgFundsBackend', { backend = 'bank' })
        truthy(r.ok, tostring(r.message))
        eq(Funds.backend(a), 'bank', 'the one switched')
        eq(Funds.backend(b), 'internal', 'the other stays on the ledger')
        eq(QbxJobs.bank.hitman, 1400, 'its balance carried')
        eq(Funds.balance(b), 2600, 'the other\'s balance still read')
        eq(QbxJobs.bank.syndicate, nil, 'and nothing made in the bank for it')
        -- Its money still moves.
        local w = W.ask(6, 'orgFundsMove', { org = 'syndicate', direction = 'withdraw', amount = 600, reason = 'c',
            nonce = 'b2' })
        truthy(w.ok, tostring(w.message))
        eq(Funds.balance(b), 2000)
        -- A restart reads the same backends.
        Funds.init({ storage = s.storage, audit = s.audit, review = s.review })
        Funds.load(a)
        Funds.load(b)
        eq(Funds.backend(a), 'bank')
        eq(Funds.backend(b), 'internal')
        eq(Funds.balance(a), 1400)
        eq(Funds.balance(b), 2000)
    end)

    it('the bank to the ledger from one organisation leaves the other\'s bank balance in the bank', function()
        local s, a, b = twoOrgs({ bank = true })
        local Funds = s.org.Funds
        eq(Funds.backend(a), 'bank')
        truthy(W.ask(6, 'orgFundsMove', { direction = 'deposit', amount = 900, reason = 'a', nonce = 'a1' }).ok)
        truthy(W.ask(6, 'orgFundsMove', { org = 'syndicate', direction = 'deposit', amount = 4100, reason = 'b',
            nonce = 'b1' }).ok)
        truthy(W.ask(6, 'orgFundsBackend', { backend = 'internal' }).ok)
        eq(Funds.balance(a), 900, 'carried into the ledger')
        eq(QbxJobs.bank.hitman, 0)
        eq(Funds.backend(b), 'bank')
        eq(Funds.balance(b), 4100, 'the other still reads its bank account')
        eq(ledgerSum(s, 'syndicate'), 0, 'and nothing of it in the ledger')
    end)

    it('removal refuses an organisation whose other backend still holds money', function()
        local s, _, b = twoOrgs({ bank = true })
        local Funds = s.org.Funds
        truthy(W.ask(6, 'orgFundsMove', { org = 'syndicate', direction = 'deposit', amount = 3300, reason = 'b',
            nonce = 'b1' }).ok)
        -- Renewed-Banking stops; staff leave it, abandoning what it holds.
        Natives.resourceStates['Renewed-Banking'] = 'stopped'
        truthy(W.ask(6, 'orgFundsBackend', { org = 'syndicate', backend = 'internal', abandon = true }).ok)
        eq(Funds.balance(b), 0, 'the ledger holds nothing')
        Natives.resourceStates['Renewed-Banking'] = 'started'
        local ok, err = s.org.removeOrg(STAFF, 'syndicate')
        falsy(ok, 'refused while its bank account holds 3300')
        eq(err, 'org_rule')
        truthy(s.org.byId('syndicate'), 'still kept')
    end)

    it('the cuts another organisation already took stay known after a switch (follow-on)', function()
        local s, a, b = twoOrgs()
        local Funds = s.org.Funds
        truthy(Funds.credit(b, 250, { ref = 'cut:LINEB01', kind = 'cut', actor = 'RECRUIT1', reason = 'payout' }))
        eq(Funds.taken('LINEB01'), 250)
        Natives.resourceStates['Renewed-Banking'] = 'started'
        truthy(W.ask(6, 'orgFundsBackend', { backend = 'bank' }).ok)
        eq(Funds.taken('LINEB01'), 250, 'never given to the member again')
        local _ = a
    end)
end)

describe('step 8d M2: ledger to Renewed-Banking makes the job\'s account first', function()
    it('carries the balance into an account Renewed-Banking did not have', function()
        local s = W.world({ configure = function() Config.Integrations.Banking = 'auto' end })
        W.crew(s)
        local org = s.org.current()
        truthy(s.org.staffDeposit(W.STAFF, 3700, 'seed', 'm2'))
        Natives.resourceStates['Renewed-Banking'] = 'started'
        eq(QbxJobs.bank.hitman, nil, 'no account for the job')
        local r = W.ask(6, 'orgFundsBackend', { backend = 'bank' })
        truthy(r.ok, tostring(r.message))
        eq(QbxJobs.bank.hitman, 3700, 'made, and the balance carried')
        eq(s.org.Funds.balance(org), 3700)
        eq(ledgerSum(s, org.id), 0, 'nothing left in the ledger')
    end)

    it('refuses in Renewed-Banking\'s name when it will not make one, moving nothing', function()
        local s = W.world({ configure = function() Config.Integrations.Banking = 'auto' end })
        W.crew(s)
        local org = s.org.current()
        truthy(s.org.staffDeposit(W.STAFF, 1200, 'seed', 'm2b'))
        Natives.resourceStates['Renewed-Banking'] = 'started'
        local rb = Natives.exportTables['Renewed-Banking']
        local real = rb.CreateJobAccount
        rb.CreateJobAccount = function() error('Database error', 0) end
        local r = W.ask(6, 'orgFundsBackend', { backend = 'bank' })
        rb.CreateJobAccount = real
        falsy(r.ok)
        eq(r.err, 'org_no_account')
        truthy(tostring(r.message):find('Renewed-Banking', 1, true), 'the refusal names Renewed-Banking')
        eq(s.org.Funds.backend(org), 'internal')
        eq(s.org.Funds.balance(org), 1200, 'nothing moved')
    end)
end)

describe('step 8d M3: a dead drop holds nothing while the Organisation is off', function()
    it('the payout goes once the Organisation is switched off live', function()
        local s, f = W.world({ configure = function()
            Config.Integrations.Banking = 'none'
            Config.Cooldowns.create = { per = 10, burst = 100 }
            Config.Organisation.DeadDrops = true
            Config.Organisation.DeadDropMinutes = 30
        end })
        W.crew(s)
        W.allow(s, 3, 'P4')
        W.at(6, 400.0, 400.0, 30.0)
        truthy(s.org.placeSpot(STAFF, { kind = 'deaddrop', here = true }))
        truthy(W.call('orgPayoutMethod', 11, { method = 'deaddrop' }).ok)
        local c = W.place(s, f.creator)
        truthy(s.contracts.accept(s.identity.resolve(13), c.id))
        local before = W.wealth(13)
        truthy(s.contracts.claimSlot(c.id, 'RECRUIT1', CH.FULFILMENT.KIDNAPPING))
        eq(W.wealth(13) - before, 0, 'held at the drop')
        Config.Organisation.Enabled = false
        s.org.boot(true)
        Env.advance(120)
        pcall(s.escrow.retryPending, 'RECRUIT1')
        eq(W.wealth(13) - before, 5000, 'paid, not held until a restart')
    end)

    it('an organisation with a drop waiting is not removed', function()
        local s = twoOrgs()
        local b = s.org.byId('syndicate')
        b.settings.drops['C1:X'] = { contract = 'C1', cid = 'X', at = os.time(), expires = os.time() + 600 }
        local ok, err = s.org.removeOrg(STAFF, 'syndicate')
        falsy(ok)
        eq(err, 'org_rule')
    end)
end)

describe('step 8d M4: a cut on a give that never arrived goes back with the line', function()
    it('the placer gets the whole payout back, and the funds keep nothing of it', function()
        local s, f = W.world({ configure = function() Config.Integrations.Banking = 'none' end })
        W.crew(s)
        local org = s.org.current()
        truthy(s.org.hire(W.STAFF, { cid = 'HITMAN01', name = 'Rook', source = 3 }, 0))
        truthy(s.org.setCut(W.STAFF, 'payout', nil, 15))
        local hitman = s.identity.resolve(3)
        local start = W.wealth(1)
        local c = W.place(s, f.creator)
        truthy(s.contracts.accept(hitman, c.id))
        local p = Env.players[3]
        local real = p.Functions.AddMoney
        p.Functions.AddMoney = function() error('raise before the money moved', 0) end
        pcall(s.contracts.claimSlot, c.id, 'HITMAN01', CH.FULFILMENT.KIDNAPPING)
        local line
        for _, l in ipairs(s.storage.readEscrow(c.id)) do if l.owed_to == 'HITMAN01' then line = l end end
        truthy(line, 'the member\'s line')
        for _ = 1, s.escrow.DELIVER_RAISE_LIMIT + 1 do
            pcall(s.escrow.release, c.id, 'HITMAN01', { line = line.id }, 'test')
        end
        p.Functions.AddMoney = real
        eq(s.org.Funds.balance(org), 750, 'the cut was taken on the first try')
        local reply = W.ask(6, 'settle', { line = line.id, disposition = 'return' })
        truthy(reply and reply.ok, tostring(reply and reply.message))
        eq(W.wealth(1) - start, 0, 'the placer has the whole payout back')
        eq(s.org.Funds.balance(org), 0, 'the cut given back')
        eq(#W.audit('org_cut_given_back'), 1, 'on the record')
    end)
end)

describe('step 8d M7: the part of a payout handed over at the kill is cut too', function()
    it('PayNowPercent: the funds take their cut of every dollar the member is paid', function()
        local s, f = W.world({ configure = function()
            Config.Integrations.Banking = 'none'
            Config.Completion.KillPhotos = false
            Config.Cooldowns.disposal = { per = 10, burst = 100 }
            Config.Disposal.Enabled = true
            Config.Disposal.PayNowPercent = 60
        end })
        s.disposal.world = {
            spawn = function() return 7001 end, exists = function() return true end,
            coords = function() return { x = 200.0, y = 200.0, z = 30.0 } end,
            remove = function() end, prepare = function() return true end,
        }
        local places = require('server.places')
        truthy(places.set(STAFF, 'disposal_vehicle', { x = 200.0, y = 200.0, z = 30.0, heading = 90.0 }))
        truthy(places.set(STAFF, 'disposal_drop', { x = 500.0, y = 500.0, z = 30.0 }))
        W.crew(s)
        local org = s.org.current()
        truthy(s.org.hire(W.STAFF, { cid = 'HITMAN01', name = 'Rook', source = 3 }, 0))
        truthy(s.org.setCut(W.STAFF, 'payout', nil, 25))
        local hitman = s.identity.resolve(3)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 4000 } } })
        truthy(c)
        truthy(s.contracts.accept(hitman, c.id, false))
        Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
        Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
        Env.players[2]._health = 140
        s.death.recordDamage(3, 2, 123456)
        Env.players[2].PlayerData.metadata.isdead = true
        s.death.onVictimReport(2)
        local before = W.wealth(3)
        truthy(s.photo.verifyAtScene(hitman, c.id))
        eq(W.wealth(3) - before, 1800, 'the member got 2400 less its 25% cut')
        eq(s.org.Funds.balance(org), 600, 'and the funds the cut of it')
    end)
end)

describe('step 8d M8: the organisation\'s own gives decide by what arrived', function()
    local function addThenRaise(src, part)
        local p = Env.players[src]
        local real = p.Functions.AddMoney
        p.Functions.AddMoney = function(account, amount, reason)
            real(account, math.floor(amount * (part or 1)), reason)
            error('a hook raised after the credit', 0)
        end
        return function() p.Functions.AddMoney = real end
    end

    it('M8a a bonus that raised after it arrived stands, and is not given back as well', function()
        local s = W.world({ configure = function() Config.Integrations.Banking = 'none' end })
        W.crew(s)
        local org = s.org.current()
        truthy(s.org.staffDeposit(W.STAFF, 6000, 'seed', 's1'))
        local before = W.wealth(13)
        local undo = addThenRaise(13)
        local ok = s.org.bonus(W.STAFF, 'RECRUIT1', 900, 'well done', 'b8a')
        undo()
        truthy(ok, 'the bonus stands')
        eq(W.wealth(13) - before, 900)
        eq(s.org.Funds.balance(org), 5100, 'paid once, from the funds')
        local again, _, data = s.org.bonus(W.STAFF, 'RECRUIT1', 900, 'well done', 'b8a')
        truthy(again and data and data.repeated, 'a retry is the first again')
        eq(W.wealth(13) - before, 900, 'and pays nothing')
    end)

    it('M8b a salary that raised after it arrived is paid, never given back as well', function()
        local s = W.world({ configure = function()
            Config.Integrations.Banking = 'none'
            Config.Organisation.Payroll = true
        end })
        W.crew(s)
        local org = s.org.current()
        truthy(s.org.staffDeposit(W.STAFF, 6000, 'seed', 's1'))
        truthy(s.org.setSalary(W.STAFF, 0, 450))
        s.org.payrollTick(os.time())
        local b0, f0 = W.wealth(13), s.org.Funds.balance(org)
        local undo = addThenRaise(13)
        s.org.payrollTick(os.time() + 40 * 86400)
        undo()
        eq(W.wealth(13) - b0, 450, 'the recruit was paid')
        eq(W.wealth(13) - b0 + s.org.Funds.balance(org), f0, 'conserved: nothing given back as well')
    end)

    it('M8c a withdrawal of which only part arrived is left for staff, not given back', function()
        local s = W.world({ configure = function() Config.Integrations.Banking = 'none' end })
        W.crew(s)
        local org = s.org.current()
        truthy(s.org.staffDeposit(W.STAFF, 6000, 'seed', 's1'))
        W.allow(s, 2, 'C7')
        W.office(s, 0.0, 0.0)
        W.at(12, 0.0, 0.0)
        local before = W.wealth(12)
        local undo = addThenRaise(12, 0.25)
        local ok, err = s.org.withdraw(W.boss(12, 'LIEUT001'), 1200, 'rent', 'w8c')
        undo()
        falsy(ok)
        eq(err, 'org_left_for_staff')
        eq(W.wealth(12) - before, 300, 'a quarter arrived')
        eq(s.org.Funds.balance(org), 4800, 'nothing given back blind: the rest is for staff to check')
        local items = {}
        for _, item in ipairs(s.storage.reviewItems(true, 100) or {}) do
            if item.kind == 'org_funds_give_raised' then items[#items + 1] = item end
        end
        eq(#items, 1, 'left for staff')
        eq(items[1].known.arrived, 300, 'with what arrived')
        local again = s.org.withdraw(W.boss(12, 'LIEUT001'), 1200, 'rent', 'w8c')
        truthy(again, 'the same request again is answered as the first')
        eq(W.wealth(12) - before, 300, 'and pays nothing more')
    end)

    it('M8d a deposit whose give-back is refused is owed to the member, on the record', function()
        local s = W.world({ bank = true })
        W.crew(s)
        local org = s.org.current()
        W.allow(s, 2, 'C6')
        W.office(s, 0.0, 0.0)
        W.at(12, 0.0, 0.0)
        local before = W.wealth(12)
        local bank0 = QbxJobs.bank.hitman or 0
        QbxJobs.refuse.add = true
        Env.players[12]._refuseMoney = true
        local ok = s.org.deposit(W.boss(12, 'LIEUT001'), 650, 'bank', 'd8d')
        Env.players[12]._refuseMoney = nil
        QbxJobs.refuse.add = nil
        falsy(ok)
        eq(#W.audit('org_funds_deposit_refund_failed'), 1, 'on the record')
        local owed = 0
        for _, entry in ipairs(s.storage.readPending('LIEUT001') or {}) do
            local line = s.storage.readEscrowLine(entry.line_id)
            if line and line.state == CH.ESCROW_STATE.HELD then owed = owed + line.amount end
        end
        eq(owed, 650, 'owed to the member')
        pcall(s.escrow.retryPending, 'LIEUT001')
        eq(W.wealth(12) - before + (QbxJobs.bank.hitman or 0) - bank0, 0, 'given back at the next try')
        local _ = org
    end)
end)

describe('step 8d M9: an armory move whose put-in raised after placing stands', function()
    local function armoryWorld()
        local s = W.world({ configure = function()
            Config.Organisation.Armory = true
            Config.Organisation.ArmoryItems = { 'lockpick' }
            Config.Organisation.ArmoryAtOffice = false
        end })
        W.crew(s)
        return s, s.org.current()
    end
    local function count(list)
        local n = 0
        for _, sl in ipairs(list or {}) do if sl.name == 'lockpick' then n = n + sl.count end end
        return n
    end

    it('putting in: the items are in the stash, and not given back as well', function()
        local s, org = armoryWorld()
        Env.players[13]._inventory = { { name = 'lockpick', count = 5, slot = 1 } }
        local inv = Natives.exportTables['ox_inventory']
        local real = inv.AddItem
        inv.AddItem = function(self, dst, name, n, metadata)
            local r = real(self, dst, name, n, metadata)
            if type(dst) ~= 'number' then error('the sync raised after placing', 0) end
            return r
        end
        local reply = W.call('orgArmoryPut', 13, { slot = 1, count = 3 })
        inv.AddItem = real
        truthy(reply.ok, tostring(reply.message))
        local stash = Env.stashes['crimson_armory_' .. org.id]
        eq(count(Env.players[13]._inventory) + count(stash and stash._inventory), 5, 'five in the world')
        eq(count(stash and stash._inventory), 3)
    end)

    it('taking out: the items are with the member, and not put back as well', function()
        local s, org = armoryWorld()
        Env.players[13]._inventory = { { name = 'lockpick', count = 6, slot = 1 } }
        truthy(W.call('orgArmoryPut', 13, { slot = 1, count = 6 }).ok)
        truthy(s.org.armoryLimit(W.STAFF, 0, 5))
        local stash = Env.stashes['crimson_armory_' .. org.id]
        local slot = stash._inventory[1].slot
        local inv = Natives.exportTables['ox_inventory']
        local real = inv.AddItem
        inv.AddItem = function(self, dst, name, n, metadata)
            local r = real(self, dst, name, n, metadata)
            if type(dst) == 'number' then error('the sync raised after placing', 0) end
            return r
        end
        local reply = W.call('orgArmoryTake', 13, { slot = slot, count = 2 })
        inv.AddItem = real
        truthy(reply.ok, tostring(reply.message))
        eq(count(Env.players[13]._inventory) + count(stash._inventory), 6, 'six in the world')
        eq(count(Env.players[13]._inventory), 2)
    end)
end)

describe('step 8d M10: money moves are audited whatever LogAllActions says', function()
    it('a deposit, a withdrawal and a bonus by members leave their rows', function()
        local s = W.world({ configure = function()
            Config.Integrations.Banking = 'none'
            Config.Audit.LogAllActions = false
        end })
        W.crew(s)
        truthy(s.org.staffDeposit(W.STAFF, 5000, 'seed', 's1'))
        W.allow(s, 2, 'C6')
        W.allow(s, 2, 'C7')
        W.allow(s, 2, 'P2')
        W.office(s, 0.0, 0.0)
        W.at(12, 0.0, 0.0)
        local boss = W.boss(12, 'LIEUT001')
        truthy(s.org.deposit(boss, 700, 'bank', 'd1'))
        truthy(s.org.withdraw(boss, 300, 'rent', 'w1'))
        truthy(s.org.bonus(boss, 'RECRUIT1', 100, 'gj', 'b1'))
        eq(#W.audit('org_funds_deposit'), 1)
        eq(#W.audit('org_funds_withdraw'), 1)
        eq(#W.audit('org_bonus'), 1)
    end)
end)
