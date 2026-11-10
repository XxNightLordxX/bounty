--- The organisation's money (server/org/funds.lua, Org.cutFor and the
--- escrow payout hook): the funds in this resource's ledger or in
--- Renewed-Banking's society account, never moved by an amount that is not
--- a whole number above zero (Renewed-Banking itself takes a negative one);
--- deposits, withdrawals and bonuses inside their bounds, once per request;
--- and cuts frozen at acceptance, taken once per escrow line as it is paid,
--- so what was escrowed is what the member and the funds received.

local W = require('tests.harness.org_world')
local QbxJobs = W.QbxJobs

local BOSS = W.boss(11, 'BOSS0001')

local function world(opts)
    local s, f = W.world(opts)
    W.crew(s)
    return s, f, s.org.current()
end

local function moneyBoss(s)
    for _, code in ipairs({ 'C6', 'C7', 'C8', 'P2', 'C1', 'C2', 'C3', 'C4', 'C5' }) do W.allow(s, 3, code) end
    W.office(s)
    W.at(11, 100.0, 100.0)
end

describe('the internal ledger', function()
    it('moves a deposit, a withdrawal and a bonus, each inside its bound', function()
        local s, _, org = world({ configure = function() Config.Organisation.Funds = 'internal' end })
        moneyBoss(s)
        local before = W.wealth(11)
        truthy(s.org.deposit(BOSS, 2000, 'bank', 'd1'))
        eq(s.org.Funds.balance(org), 2000)
        eq(W.wealth(11), before - 2000)
        local ok, err = s.org.withdraw(BOSS, 3000, 'rent', 'w1')
        eq(err, 'org_short', 'not more than the balance')
        truthy(s.org.withdraw(BOSS, 500, 'rent', 'w2'))
        eq(s.org.Funds.balance(org), 1500)
        eq(W.wealth(11), before - 1500)
        truthy(s.org.bonus(BOSS, 'LIEUT001', 300, 'good job', 'b1'))
        eq(s.org.Funds.balance(org), 1200)
        ok, err = s.org.bonus(BOSS, 'BOSS0001', 10, 'me', 'b2')
        eq(err, 'org_self', 'no bonus to themselves')
        falsy(ok)
        local view = W.call('orgFunds', 11, {})
        eq(view.data.balance, 1200)
        eq(view.data.bank, false)
        eq(#view.data.rows, 3)
        eq(view.data.rows[1].actor, nil, 'a boss is not shown who')
    end)

    it('moves each request once, by its nonce', function()
        local s, _, org = world({ configure = function() Config.Organisation.Funds = 'internal' end })
        moneyBoss(s)
        truthy(s.org.deposit(BOSS, 1000, 'cash', 'same'))
        local ok, _, extra = s.org.deposit(BOSS, 1000, 'cash', 'same')
        truthy(ok)
        eq(extra.repeated, true)
        eq(s.org.Funds.balance(org), 1000, 'once')
        truthy(s.org.withdraw(BOSS, 100, 'x', 'w'))
        truthy(s.org.withdraw(BOSS, 100, 'x', 'w'))
        eq(s.org.Funds.balance(org), 900)
    end)

    it('refuses an amount that is not a whole number above zero, whatever its type', function()
        local s, _, org = world({ configure = function() Config.Organisation.Funds = 'internal' end })
        moneyBoss(s)
        for _, bad in ipairs({ -100, 0, 1.5, '12abc', 0 / 0, math.huge, -math.huge, 1e12, {}, true }) do
            falsy(s.org.deposit(BOSS, bad, 'bank'), 'deposit ' .. tostring(bad))
            falsy(s.org.withdraw(BOSS, bad, 'r'), 'withdraw ' .. tostring(bad))
            falsy(s.org.bonus(BOSS, 'LIEUT001', bad, 'r'), 'bonus ' .. tostring(bad))
            falsy(s.org.staffDeposit(W.STAFF, bad, 'r'), 'staff deposit ' .. tostring(bad))
        end
        eq(s.org.Funds.balance(org), 0)
    end)

    it('holds a boss to WithdrawMax, WithdrawPerDay, BonusMax and BonusPerDay; staff to none', function()
        local s, _, org = world({ configure = function() Config.Organisation.Funds = 'internal' end })
        moneyBoss(s)
        truthy(s.org.staffDeposit(W.STAFF, 500000, 'seed', 's1'))
        truthy(s.org.setLimits(W.STAFF, { WithdrawMax = 1000, WithdrawPerDay = 1500, BonusMax = 200, BonusPerDay = 300 }))
        eq(select(2, s.org.withdraw(BOSS, 1001, 'x')), 'org_bounds')
        truthy(s.org.withdraw(BOSS, 1000, 'x'))
        eq(select(2, s.org.withdraw(BOSS, 600, 'x')), 'org_limit')
        eq(select(2, s.org.bonus(BOSS, 'LIEUT001', 201, 'x')), 'org_bounds')
        truthy(s.org.bonus(BOSS, 'LIEUT001', 200, 'x'))
        eq(select(2, s.org.bonus(BOSS, 'LIEUT001', 200, 'x')), 'org_limit')
        truthy(s.org.withdraw(W.STAFF, 100000, 'staff'))
        eq(s.org.Funds.balance(org), 500000 - 1000 - 200 - 100000)
        Env.advance(86400)
        truthy(s.org.withdraw(BOSS, 1000, 'tomorrow'), 'a day later')
    end)

    it('gives the money back when the pocket refuses it', function()
        local s, _, org = world({ configure = function() Config.Organisation.Funds = 'internal' end })
        moneyBoss(s)
        truthy(s.org.staffDeposit(W.STAFF, 1000, 'seed'))
        Env.players[11]._refuseMoney = true
        falsy(s.org.withdraw(BOSS, 400, 'x'))
        eq(s.org.Funds.balance(org), 1000, 'back in the funds')
        Env.players[11]._refuseMoney = nil
        truthy(s.org.withdraw(BOSS, 400, 'x'))
        eq(s.org.Funds.balance(org), 600)
    end)

    it('needs the office to withdraw, and C8 to see the funds', function()
        local s = world({ configure = function() Config.Organisation.Funds = 'internal' end })
        W.allow(s, 3, 'C7')
        W.office(s)
        W.at(11, 900.0, 900.0)
        eq(select(2, s.org.withdraw(BOSS, 1, 'x')), 'org_office')
        eq(W.call('orgFunds', 11, {}).err, 'org_no_power')
    end)
end)

describe('Renewed-Banking\'s society account', function()
    it('holds the funds, with its history, and refuses nothing it is not asked', function()
        local s, _, org = world({ bank = true })
        moneyBoss(s)
        eq(QbxJobs.bank.hitman, 0, 'the account made')
        truthy(s.org.deposit(BOSS, 2500, 'bank', 'd'))
        eq(QbxJobs.bank.hitman, 2500)
        eq(s.org.Funds.balance(org), 2500)
        truthy(s.org.withdraw(BOSS, 1000, 'rent', 'w'))
        eq(QbxJobs.bank.hitman, 1500)
        truthy(#QbxJobs.transactions >= 2, 'its history written')
        eq(QbxJobs.transactions[1].kind, 'deposit')
        eq(QbxJobs.transactions[2].kind, 'withdraw')
        eq(select(2, s.org.withdraw(BOSS, 5000, 'x')), 'org_short', 'it refuses a shortfall')
        eq(QbxJobs.bank.hitman, 1500)
    end)

    it('never hands it a negative amount, which it would take', function()
        local s = world({ bank = true })
        moneyBoss(s)
        -- Its own quirk, shown: it moves the balance the other way.
        exports['Renewed-Banking']:addAccountMoney('hitman', -50)
        eq(QbxJobs.bank.hitman, -50)
        QbxJobs.bank.hitman = 0
        QbxJobs.calls = {}
        falsy(s.org.deposit(BOSS, -100, 'bank'))
        falsy(s.org.withdraw(BOSS, -100, 'x'))
        falsy(s.org.staffDeposit(W.STAFF, -100, 'x'))
        eq(QbxJobs.count('addAccountMoney'), 0, 'never asked')
        eq(QbxJobs.count('removeAccountMoney'), 0)
        eq(QbxJobs.bank.hitman, 0)
    end)

    it('gives a deposit back, and writes no row, when the account refuses it', function()
        local s, _, org = world({ bank = true })
        moneyBoss(s)
        QbxJobs.refuse.add = true
        local before = W.wealth(11)
        falsy(s.org.deposit(BOSS, 700, 'bank', 'x'))
        eq(W.wealth(11), before, 'given back')
        eq(#s.org.Funds.ledger(org, 50), 0, 'no row')
        QbxJobs.refuse.add = nil
        truthy(s.org.deposit(BOSS, 700, 'bank', 'x'), 'the same request goes through later')
        eq(QbxJobs.bank.hitman, 700)
    end)
end)

describe('cuts', function()
    local function member(s, grade)
        truthy(s.org.hire(W.STAFF, { cid = 'HITMAN01', name = 'Rook', source = 3 }, grade or 0))
        return s.identity.resolve(3)
    end

    it('takes the frozen cut out of the payout, and the books balance', function()
        local s, f, org = world({ configure = function() Config.Organisation.Funds = 'internal' end })
        local hitman = member(s)
        truthy(s.org.setCut(W.STAFF, 'payout', nil, 10))
        local creatorBefore, hitmanBefore = W.wealth(1), W.wealth(3)
        local c = W.place(s, f.creator)
        truthy(s.contracts.accept(hitman, c.id))
        -- Changed after the acceptance: the contract keeps 10%.
        truthy(s.org.setCut(W.STAFF, 'payout', nil, 30))
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.KIDNAPPING))
        local paid = W.wealth(3) - hitmanBefore
        local funds = s.org.Funds.balance(org)
        eq(paid, 4500, 'the member received 90%')
        eq(funds, 500, 'the funds 10%')
        eq(creatorBefore - W.wealth(1), paid + funds, 'escrowed = paid to the member + paid to the funds')
        s.audit.flush()
        local cut = s.storage.auditByAction('org_cut', 10)[1]
        truthy(cut, 'the cut on the record')
        eq(cut.detail.amount, 500)
        eq(cut.detail.percent, 10)
        truthy(cut.detail.line, 'with its line')
    end)

    it('takes a role\'s and a member\'s own cut, within the bounds, and 0 always', function()
        local s, _, org = world()
        moneyBoss(s)
        member(s, 0)
        truthy(s.org.setCut(BOSS, 'payout', nil, 5))
        truthy(s.org.setCut(BOSS, 'role', 0, 20))
        eq(s.org.payoutPercent(org, org.members.HITMAN01), 20, 'the role\'s')
        truthy(s.org.setCut(BOSS, 'member', 'HITMAN01', 0))
        eq(s.org.payoutPercent(org, org.members.HITMAN01), 0, 'the member\'s, and 0 is always allowed')
        local ok, err, extra = s.org.setCut(BOSS, 'payout', nil, 26)
        eq(err, 'org_bounds', 'past CutMaxPercent')
        eq(extra.max, 25)
        falsy(ok)
        eq(select(2, s.org.setCut(BOSS, 'role', 3, 5)), 'org_rank', 'not their own role')
        eq(select(2, s.org.setCut(BOSS, 'member', 'BOSS0001', 5)), 'org_self')
        truthy(s.org.setCut(W.STAFF, 'payout', nil, 40), 'staff up to the total cap')
        eq(select(2, s.org.setCut(W.STAFF, 'payout', nil, 41)), 'org_bounds')
        truthy(s.org.setCut(BOSS, 'member', 'HITMAN01', false), 'cleared')
        eq(select(2, s.org.setCut(BOSS, 'payout', nil, false)), 'invalid_input', 'the organisation\'s is a number')
    end)

    it('takes a cut once per line, however often the payout is tried', function()
        local s, f, org = world({ configure = function() Config.Organisation.Funds = 'internal' end })
        local hitman = member(s)
        truthy(s.org.setCut(W.STAFF, 'payout', nil, 20))
        local c = W.place(s, f.creator)
        truthy(s.contracts.accept(hitman, c.id))
        local line = { id = c.id .. ':test', contract_id = c.id, portion = CH.PORTION.BASELINE, source = 'cash',
            amount = 1000 }
        Env.players[3]._refuseMoney = true
        falsy(s.escrow.deliver('HITMAN01', line), 'the pocket refuses')
        eq(s.org.Funds.balance(org), 200, 'the cut taken')
        eq(s.escrow.stillOwed(line), 800, 'and still owed to the member is the rest')
        Env.players[3]._refuseMoney = nil
        local before = W.wealth(3)
        truthy(s.escrow.deliver('HITMAN01', line))
        eq(W.wealth(3) - before, 800)
        truthy(s.escrow.deliver('HITMAN01', { id = line.id, contract_id = c.id, portion = 'baseline',
            source = 'cash', amount = 1000 }) ~= nil)
        eq(s.org.Funds.balance(org), 200, 'never twice')
    end)

    it('cuts a stake a member wins, never their own, and a premium paid to a member', function()
        local s, f, org = world({ configure = function() Config.Organisation.Funds = 'internal' end })
        local hitman = member(s)
        truthy(s.org.setCut(W.STAFF, 'stake', nil, 10))
        truthy(s.org.setCut(W.STAFF, 'buyout', nil, 5))
        local c = W.place(s, f.creator)
        truthy(s.contracts.accept(hitman, c.id))
        local before = W.wealth(3)
        truthy(s.escrow.deliver('HITMAN01', { id = c.id .. ':own', contract_id = c.id, portion = 'stake',
            staker = 'HITMAN01', source = 'bank', amount = 1000 }))
        eq(W.wealth(3) - before, 1000, 'their own stake back whole')
        truthy(s.escrow.deliver('HITMAN01', { id = c.id .. ':won', contract_id = c.id, portion = 'stake',
            staker = 'SOMEONE1', source = 'bank', amount = 1000 }))
        eq(W.wealth(3) - before, 1900, 'a stake won, less 10%')
        truthy(s.escrow.deliver('HITMAN01', { id = 'prem:' .. c.id, contract_id = c.id, portion = 'owed',
            source = 'bank', amount = 2000 }))
        eq(W.wealth(3) - before, 1900 + 1900, 'a premium, less 5%')
        eq(s.org.Funds.balance(org), 100 + 100)
        truthy(s.escrow.deliver('HITMAN01', { id = c.id .. ':owed', contract_id = c.id, portion = 'owed',
            source = 'bank', amount = 300 }))
        eq(s.org.Funds.balance(org), 200, 'anything else, a staff payment or a refund, is never cut')
    end)

    it('cuts nobody without a frozen split, and nothing while off', function()
        local s, f, org = world({ configure = function() Config.Organisation.Funds = 'internal' end })
        truthy(s.org.setCut(W.STAFF, 'payout', nil, 25))
        local c = W.place(s, f.creator)
        truthy(s.contracts.accept(f.hitman, c.id), 'a non-member')
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.KIDNAPPING))
        eq(s.org.Funds.balance(org), 0)
        Config.Organisation.Enabled = false
        eq(s.org.cutFor('BOSS0001', { id = 'z', contract_id = c.id, portion = 'baseline', amount = 100, source = 'cash' }), 0)
    end)

    it('conserves money across many contracts, cuts and members', function()
        local s, f, org = world({ configure = function() Config.Organisation.Funds = 'internal' end })
        Config.Limits.MaxActiveContractsPerCreator = 100
        Config.Limits.SameCreatorSameTargetCooldownSeconds = 0
        local hitman = member(s)
        local paidTotal, escrowedTotal = 0, 0
        for i = 1, 6 do
            truthy(s.org.setCut(W.STAFF, 'payout', nil, (i * 7) % 41))
            W.player(40 + i, ('TGTX%04d'):format(i))
            local reward = 1000 + i * 337
            local before1, before3 = W.wealth(1), W.wealth(3)
            local c = W.place(s, f.creator, ('TGTX%04d'):format(i), { reward = { baseline = { cash = reward } } })
            truthy(c, 'placed ' .. i)
            truthy(s.contracts.accept(hitman, c.id))
            truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.KIDNAPPING))
            escrowedTotal = escrowedTotal + (before1 - W.wealth(1))
            paidTotal = paidTotal + (W.wealth(3) - before3)
        end
        eq(escrowedTotal, paidTotal + s.org.Funds.balance(org), 'every dollar escrowed is the member\'s or the funds\'')
    end)
end)
