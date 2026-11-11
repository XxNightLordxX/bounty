--- The organisation review of the phone tab, codenames and payroll
--- (F1-F6 and the two design points):
---
---   * F1 a salary is never paid above SalaryMax, whenever staff lower it;
---   * F2 a codename never reads as any character's name, online or kept,
---     folded both sides, and always reads as a codename;
---   * F3 the name shown on a contract is the one shown when it was taken;
---   * F4 look-alike swaps are folded against the blocked words;
---   * F5 a salary debit with no marker (a stop between the debit and the
---     bank) is never paid again on a guess: audited and left for staff once;
---   * F6 a give-back that fails is audited and tried again next tick;
---   * a suspended member is not paid unless PaySuspended; a boss's salary
---     change is paid from the pay day after next; PayrollPerDayMax caps a
---     pay day's total.

local W = require('tests.harness.org_world')

local BOSS = W.boss(11, 'BOSS0001')
local RECRUIT = { cid = 'RECRUIT1', source = 13, name = 'P13' }
local DAY = 86400

local function world(opts)
    opts = opts or {}
    local s, f = W.world({ configure = function()
        Config.Integrations.Banking = 'none'
        Config.Organisation.Codenames = true
        Config.Organisation.Payroll = true
        if opts.configure then opts.configure() end
    end })
    W.crew(s)
    return s, f, s.org.current()
end

--- Seed the funds and keep the first pay day: its time.
local function due(s, org, seed)
    truthy(s.org.staffDeposit(W.STAFF, seed or 100000, 'seed', 'seed1'))
    local t0 = os.time()
    eq(s.org.payrollTick(t0), nil)
    return org.settings.payroll.nextAt
end

local function bank(src) return Env.players[src].PlayerData.money.bank end

local function audited(s, action)
    s.audit.flush()
    return s.storage.auditByAction(action, 50)
end

local function reviews(s, kind)
    local out = {}
    for _, item in ipairs(s.storage.reviewItems(true, 200) or {}) do
        if item.kind == kind then out[#out + 1] = item end
    end
    return out
end

describe('organisation review: salaries within the staff bounds (F1)', function()
    it('pays no more than SalaryMax once staff lower it under a salary already set', function()
        local s, _, org = world()
        truthy(s.org.setSalary(W.STAFF, 0, 1000))
        truthy(s.org.setLimits(W.STAFF, { SalaryMax = 50 }))
        eq(s.org.salaryOf(org, 0), 50, 'held to the new SalaryMax')
        local at = due(s, org)
        local before = bank(13)
        local out = s.org.payrollTick(at)
        eq(out.total, 50)
        eq(bank(13) - before, 50, 'paid 50, not 1000')
        eq(select(2, s.org.setSalary(W.STAFF, 0, 60)), 'org_bounds', 'staff too are held to it')
    end)
end)

describe('organisation review: codenames and names (F2, F4)', function()
    it('refuses a codename that reads as any character\'s name, online or a member, folded', function()
        local s = world()
        local function why(name)
            return select(2, s.org.setCodename(RECRUIT, nil, name))
        end
        eq(why('P7 Org'), 'org_name_taken', 'a player online who is not a member')
        eq(why('p7org'), 'org_name_taken', 'any case, no separators')
        eq(why('Dana Reyes'), 'org_name_taken', 'the fixture\'s target, online')
        eq(why('P11_'), 'org_name_taken', 'a member\'s name with a trailing separator')
        eq(why('P 11'), 'org_name_taken', 'a member\'s name with a space')
        eq(why('Pll'), 'org_name_taken', 'l for 1')
        truthy(s.org.setCodename(RECRUIT, nil, 'Viper'))
        -- Another member cannot take a look-alike of it.
        eq(select(2, s.org.setCodename({ cid = 'LIEUT001', source = 12 }, nil, 'V1per')), 'org_name_taken')
    end)

    it('refuses the name of an applicant too', function()
        local s, _, org = world()
        org.applications.app1 = { id = 'app1', cid = 'APPLY001', name = 'Mara Quill', state = 'open' }
        eq(select(2, s.org.setCodename(RECRUIT, nil, 'Mara-Quill')), 'org_name_taken')
    end)

    it('labels a codename as one wherever it stands for a name', function()
        local s = world()
        truthy(s.org.setCodename(RECRUIT, nil, 'Viper'))
        eq(s.org.shownName('RECRUIT1', 'P13 Org'), 'Viper (codename)')
    end)

    it('folds look-alike swaps against the blocked words', function()
        local s = world()
        for _, name in ipairs({ 'Po1ice', 'Admln', 'Moder8tor', 'P0LICE', 'Sta ff', '5taff', 'St4ff', 'Adm1n',
            'Pol-ice', 'Mod_erator' }) do
            eq(select(2, s.org.setCodename(RECRUIT, nil, name)), 'org_name_blocked', name)
        end
        truthy(s.org.setCodename(RECRUIT, nil, 'Kestrel'), 'an ordinary one still passes')
    end)
end)

describe('organisation review: the name kept with the contract (F3)', function()
    local function placed()
        local s, f, org = world()
        truthy(s.org.hire(W.STAFF, { cid = 'HITMAN01', name = 'Rook Ash', source = 3 }, 0))
        truthy(s.org.setCodename({ cid = 'HITMAN01', source = 3 }, nil, 'Jackdaw'))
        local c = W.place(s, f.creator)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        return s, f, org, c
    end

    local function seenByPlacer()
        local names = {}
        for _, card in ipairs(W.call('mine', 1, {}).data.created or {}) do
            for _, h in ipairs(card.hitmen or {}) do names[#names + 1] = tostring(h.name) end
        end
        return table.concat(names, ';')
    end

    it('keeps the codename shown when the member is fired', function()
        local s, _, _, c = placed()
        eq(seenByPlacer(), 'Jackdaw (codename)')
        truthy(s.org.fire(W.STAFF, 'HITMAN01', 'test'))
        eq(seenByPlacer(), 'Jackdaw (codename)', 'never the real name after')
        eq(s.org.shownName('HITMAN01', 'Rook Ash', c.id), 'Jackdaw (codename)')
        local row = s.storage.readOrgRow('splits', c.id .. ':HITMAN01')
        eq(row.shown_name, 'Jackdaw (codename)', 'kept with the contract')
    end)

    it('keeps it when the codename is changed or cleared, or codenames are turned off', function()
        local s, _, _, c = placed()
        truthy(s.org.setLimits(W.STAFF, { CodenameCooldownMinutes = 0 }))
        truthy(s.org.setCodename({ cid = 'HITMAN01', source = 3 }, nil, 'Heron'))
        eq(seenByPlacer(), 'Jackdaw (codename)', 'changed')
        truthy(s.org.setCodename({ cid = 'HITMAN01', source = 3 }, nil, false))
        eq(seenByPlacer(), 'Jackdaw (codename)', 'cleared')
        Config.Organisation.Codenames = false
        eq(s.org.shownName('HITMAN01', 'Rook Ash', c.id), 'Jackdaw (codename)', 'turned off')
    end)

    it('keeps the real name on a contract taken before the codename was set', function()
        local s, f = world()
        truthy(s.org.hire(W.STAFF, { cid = 'HITMAN01', name = 'Rook Ash', source = 3 }, 0))
        local c = W.place(s, f.creator)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        truthy(s.org.setCodename({ cid = 'HITMAN01', source = 3 }, nil, 'Jackdaw'))
        eq(s.org.shownName('HITMAN01', 'Rook Ash', c.id), 'Rook Ash', 'the codename is not tied to the name')
    end)
end)

describe('organisation review: a salary paid, then marked (F5)', function()
    it('marks a salary paid, and shows no marker in the ledger', function()
        local s, _, org = world()
        truthy(s.org.setSalary(W.STAFF, 0, 100))
        local at = due(s, org, 1000)
        truthy(s.org.payrollTick(at))
        truthy(s.org.Funds.byRef(('pay:%d:RECRUIT1:paid'):format(at)), 'the marker')
        for _, row in ipairs(s.org.Funds.ledger(org, 50)) do
            truthy(not s.org.Funds.MARKS[row.kind], 'no marker shown: ' .. tostring(row.kind))
        end
    end)

    it('leaves a debit with no marker for staff, once, and never pays it again', function()
        local s, _, org = world()
        truthy(s.org.setSalary(W.STAFF, 0, 100))
        local at = due(s, org, 1000)
        -- As though the server stopped between the debit and the bank.
        truthy(s.org.Funds.debit(org, 100, { ref = ('pay:%d:RECRUIT1'):format(at), kind = 'salary',
            actor = 'RECRUIT1' }))
        local before = bank(13)
        local out = s.org.payrollTick(at)
        eq(out.unconfirmed, 1)
        eq(bank(13) - before, 0, 'not paid on a guess')
        eq(s.org.Funds.balance(org), 900)
        eq(#audited(s, 'org_payroll_unconfirmed'), 1, 'on the record')
        local items = reviews(s, 'org_payroll_unconfirmed')
        eq(#items, 1, 'left for staff')
        eq(items[1].amount, 100)
        eq(items[1].cids.member, 'RECRUIT1')
        -- Run again (the pay day not kept): nothing more.
        org.settings.payroll.nextAt = at
        out = s.org.payrollTick(at + 5)
        eq(out.unconfirmed, 0)
        eq(#reviews(s, 'org_payroll_unconfirmed'), 1, 'once')
        eq(bank(13) - before, 0)
    end)
end)

describe('organisation review: a give-back that fails (F6)', function()
    it('audits it and gives it back on the next tick', function()
        local s, _, org = world()
        truthy(s.org.setSalary(W.STAFF, 0, 100))
        local at = due(s, org, 1000)
        local realAdd = Env.players[13].Functions.AddMoney
        Env.players[13].Functions.AddMoney = function() return false end
        local realInsert = s.storage.insertOrgRowOnce
        s.storage.insertOrgRowOnce = function(name, row)
            if tostring(row.id):find(':back', 1, true) then error('db hiccup') end
            return realInsert(name, row)
        end
        local out = s.org.payrollTick(at)
        Env.players[13].Functions.AddMoney = realAdd
        s.storage.insertOrgRowOnce = realInsert
        eq(out.failed, 1)
        eq(s.org.Funds.balance(org), 900, 'not given back yet')
        local failed = audited(s, 'org_payroll_refund_failed')
        eq(#failed, 1)
        eq(failed[1].detail.amount, 100)
        truthy(next(org.settings.payroll.refunds), 'kept to try again')
        s.org.payrollTick(at + 60)
        eq(s.org.Funds.balance(org), 1000, 'given back on the next tick')
        eq(next(org.settings.payroll.refunds), nil)
        eq(#audited(s, 'org_payroll_refunded'), 1)
        s.org.payrollTick(at + 120)
        eq(s.org.Funds.balance(org), 1000, 'once')
    end)
end)

describe('organisation review: who is paid, and when (design)', function()
    it('ships PaySuspended off and PayrollPerDayMax 0', function()
        resetConfig()
        eq(Config.Organisation.PaySuspended, false)
        eq(Config.Organisation.Limits.PayrollPerDayMax, 0)
    end)

    it('does not pay a suspended member, unless PaySuspended', function()
        local s, _, org = world()
        truthy(s.org.setSalary(W.STAFF, 0, 100))
        local at = due(s, org)
        truthy(s.org.suspend(W.STAFF, 'RECRUIT1', 24 * 20, 'test'))
        local before = bank(13)
        local out = s.org.payrollTick(at)
        eq(bank(13) - before, 0, 'not paid while suspended')
        eq(out.skipped, 1)
        local skipped = audited(s, 'org_payroll_skipped')
        eq(skipped[1].detail.why, 'suspended')
        Config.Organisation.PaySuspended = true
        s.org.payrollTick(org.settings.payroll.nextAt)
        eq(bank(13) - before, 100, 'paid with PaySuspended')
    end)

    it('pays a boss\'s salary change from the pay day after the next one, on the record', function()
        local s, _, org = world()
        W.allow(s, 3, 'P3')
        local at = due(s, org)
        local ok, _, extra = s.org.setSalary(BOSS, 0, 100)
        truthy(ok)
        eq(extra.fromPayDay, at + 7 * DAY)
        local roles = W.call('orgRoles', 11, {}).data.rows
        for _, r in ipairs(roles) do
            if r.grade == 0 then eq(r.salaryNext, 100) end
        end
        local before = bank(13)
        s.org.payrollTick(at)
        eq(bank(13) - before, 0, 'not at the next pay day')
        s.org.payrollTick(org.settings.payroll.nextAt)
        eq(bank(13) - before, 100, 'from the one after')
        eq(s.org.salaryOf(org, 0), 100)
        eq(#audited(s, 'org_salary_applied'), 1)
        eq(audited(s, 'org_salary')[1].detail.fromPayDay, at + 7 * DAY)
    end)

    it('caps a pay day\'s salaries in all at PayrollPerDayMax', function()
        local s, _, org = world()
        truthy(s.org.setSalary(W.STAFF, 3, 700))
        truthy(s.org.setSalary(W.STAFF, 2, 300))
        truthy(s.org.setSalary(W.STAFF, 0, 100))
        truthy(s.org.setLimits(W.STAFF, { PayrollPerDayMax = 1000 }))
        local at = due(s, org)
        local before = bank(13)
        local out = s.org.payrollTick(at)
        eq(out.total, 1000)
        eq(out.paid, 2)
        eq(out.skipped, 1)
        eq(bank(13) - before, 0, 'the recruit past the cap')
        eq(audited(s, 'org_payroll_skipped')[1].detail.why, 'cap')
    end)
end)
