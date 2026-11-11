--- The organisation's payroll (Config.Organisation.Payroll, plan R10, off
--- as shipped):
---
---   * off: no pay day is kept, the tick does nothing, Set salaries says so;
---   * a salary per role, set by a boss holding P3 within SalaryMax and the
---     staff maximum for that role, never for their own rank;
---   * pay day: every member paid their role's salary from the funds to
---     their bank, the funds falling by exactly what the members gained;
---     one the funds cannot cover skipped, told and audited, the rest paid;
---   * cheap: until the pay day one comparison, no store read or write;
---   * restart-safe: a pay day half done is never paid twice, a pay day
---     kept across a restart on every backend, missed periods not paid over.

local W = require('tests.harness.org_world')
local QbxJobs = W.QbxJobs
local Exec = require('tests.harness.mysql_exec')

local BOSS = W.boss(11, 'BOSS0001')
local DAY = 86400

local function world(opts)
    opts = opts or {}
    local s, f = W.world({ configure = function(stack, fx)
        Config.Integrations.Banking = 'none'
        if opts.on ~= false then Config.Organisation.Payroll = true end
        if opts.configure then opts.configure(stack, fx) end
    end })
    W.crew(s)
    return s, f, s.org.current()
end

local function banks()
    local out = {}
    for _, src in ipairs({ 11, 12, 13 }) do out[src] = Env.players[src].PlayerData.money.bank end
    return out
end

local function phoned(cid)
    local n = 0
    for _, e in ipairs(Env.clientEvents or {}) do
        if e.name == 'crimson-hitman:notify' or Natives.isNotice(e) then n = n + 1 end
    end
    local _ = cid
    return n
end

local function forget()
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
            package.loaded[name] = nil
        end
    end
end

describe('payroll switched off (as shipped)', function()
    it('ships off, and its tick keeps no pay day and pays nobody', function()
        resetConfig()
        eq(Config.Organisation.Payroll, false)
        eq(Config.Organisation.PayrollDays, 7)
        local s, _, org = world({ on = false })
        eq(s.org.payrollTick(os.time() + 30 * DAY), nil)
        eq(org.settings.payroll.nextAt, nil, 'no pay day kept')
        local ok, err = s.org.setSalary(W.STAFF, 0, 100)
        falsy(ok)
        eq(err, 'org_feature_off')
    end)

    it('says so to a boss through the phone, with words', function()
        local s = world({ on = false })
        W.allow(s, 3, 'P3')
        local reply = W.call('orgSalary', 11, { grade = 0, amount = 10 })
        eq(reply.err, 'org_feature_off')
        truthy(reply.data and reply.data.message, 'worded')
    end)
end)

describe('salaries', function()
    it('lets a boss with Set salaries pay a role below them, within the bounds', function()
        local s, _, org = world()
        W.allow(s, 3, 'P3')
        truthy(s.org.setSalary(BOSS, 0, 500))
        -- A boss's change waits for the pay day after the next one.
        eq(s.org.salaryOf(org, 0), 0)
        eq(s.org.pendingSalary(org, 0).amount, 500)
        local ok, err, extra = s.org.setSalary(BOSS, 0, 1001)
        falsy(ok)
        eq(err, 'org_bounds', 'over SalaryMax (1000)')
        eq(extra.max, 1000, 'the bound is said')
        eq(select(2, s.org.setSalary(BOSS, 3, 10)), 'org_rank', 'not their own rank')
        eq(select(2, s.org.setSalary(BOSS, 9, 10)), 'org_not_found')
        eq(select(2, s.org.setSalary(BOSS, 0, -1)), 'invalid_input')
        eq(select(2, s.org.setSalary(BOSS, 0, 1.5)), 'invalid_input')
        -- Staff's own maximum for a role caps it further, for bosses and staff.
        truthy(s.org.setSalary(W.STAFF, 0, 500))
        eq(s.org.salaryOf(org, 0), 500, 'staff\'s at once')
        truthy(s.org.setSalaryMax(W.STAFF, 0, 200))
        eq(select(2, s.org.setSalary(BOSS, 0, 300)), 'org_bounds')
        eq(s.org.salaryOf(org, 0), 200, 'what was set before is paid within the new maximum')
        eq(select(2, s.org.setSalary(W.STAFF, 0, 300)), 'org_bounds', 'staff too, while the role has one')
        truthy(s.org.setSalaryMax(W.STAFF, 0, false))
        truthy(s.org.setSalary(W.STAFF, 0, 300))
        eq(select(2, s.org.setSalaryMax(BOSS, 0, 900)), 'org_no_power', 'the maximum is staff\'s')
        s.audit.flush()
        local audit = s.storage.auditByAction('org_salary', 10)
        truthy(#audit >= 2, 'on the record')
    end)

    it('refuses a boss without the power, and one away from nothing', function()
        local s = world()
        eq(select(2, s.org.setSalary(BOSS, 0, 10)), 'org_no_power')
        eq(select(2, s.org.setSalary({ cid = 'NOBODY01', source = 99 }, 0, 10)), 'org_not_member')
    end)

    it('shows a member their salary and a boss each role\'s', function()
        local s = world()
        W.allow(s, 3, 'P3')
        truthy(s.org.setSalary(W.STAFF, 0, 250))
        local mine = W.call('orgMine', 13, {}).data
        eq(mine.payroll.salary, 250)
        local roles = W.call('orgRoles', 11, {}).data.rows
        local recruit
        for _, r in ipairs(roles) do if r.grade == 0 then recruit = r end end
        eq(recruit.salary, 250)
        eq(recruit.salaryMax, 1000)
    end)

    it('takes hostile payloads without moving anything', function()
        local s, _, org = world()
        W.allow(s, 3, 'P3')
        for _, payload in ipairs({ { grade = 0, amount = '500' }, { grade = 0, amount = 1e300 },
            { grade = 0, amount = 0 / 0 }, { grade = 'x', amount = 5 }, { grade = 0, amount = { 5 } },
            { grade = 0 }, 'nonsense', 12 }) do
            local reply = W.call('orgSalary', 11, payload)
            truthy(reply, 'answered')
            if reply.ok then
                eq(s.org.pendingSalary(org, 0).amount, 500, 'only a string the server read as 500')
            end
        end
        local _ = org
    end)
end)

describe('pay day', function()
    local function due(s, org, members)
        truthy(s.org.staffDeposit(W.STAFF, members or 100000, 'seed', 'seed1'))
        local t0 = os.time()
        eq(s.org.payrollTick(t0), nil, 'the first tick only keeps the first pay day')
        eq(org.settings.payroll.nextAt, t0 + 7 * DAY)
        return t0 + 7 * DAY
    end

    it('pays every member their role\'s salary from the funds, the funds falling by what they gain', function()
        local s, _, org = world()
        truthy(s.org.setSalary(W.STAFF, 0, 100))
        truthy(s.org.setSalary(W.STAFF, 2, 300))
        truthy(s.org.setSalary(W.STAFF, 3, 700))
        local at = due(s, org)
        local before, funds = banks(), s.org.Funds.balance(org)
        eq(s.org.payrollTick(at - 1), nil, 'not before the pay day')
        eq(s.org.Funds.balance(org), funds)
        Env.clientEvents = {}
        local out = s.org.payrollTick(at)
        eq(out.paid, 3)
        eq(out.skipped, 0)
        eq(out.total, 1100)
        local after = banks()
        eq(after[13] - before[13], 100)
        eq(after[12] - before[12], 300)
        eq(after[11] - before[11], 700)
        -- The invariant: what left the funds is what the members gained.
        local gained = (after[11] - before[11]) + (after[12] - before[12]) + (after[13] - before[13])
        eq(funds - s.org.Funds.balance(org), gained, 'conserved')
        truthy(phoned() >= 1, 'members told')
        eq(org.settings.payroll.nextAt, at + 7 * DAY, 'the next pay day kept')
        eq(s.org.payrollTick(at + 60), nil, 'once per pay day')
        s.audit.flush()
        local run = s.storage.auditByAction('org_payroll_run', 5)[1]
        eq(run.detail.paid, 3)
    end)

    it('skips, tells and audits a salary the funds cannot cover, and still pays the rest', function()
        local s, _, org = world()
        truthy(s.org.setSalary(W.STAFF, 3, 900))
        truthy(s.org.setSalary(W.STAFF, 0, 50))
        local at = due(s, org, 950)
        W.allow(s, 3, 'C8')
        local before = banks()
        local out = s.org.payrollTick(at)
        eq(out.paid, 2, 'boss 900 then recruit 50 fit in 950')
        truthy(s.org.setSalary(W.STAFF, 2, 10))
        local at2 = org.settings.payroll.nextAt
        Env.clientEvents = {}
        out = s.org.payrollTick(at2)
        -- 0 left: the boss's 900 and the lieutenant's 10 and recruit's 50 are all short.
        eq(out.paid, 0)
        eq(out.skipped, 3)
        eq(s.org.Funds.balance(org), 0, 'never below zero')
        truthy(phoned() >= 1, 'the unpaid are told')
        s.audit.flush()
        local skipped = s.storage.auditByAction('org_payroll_skipped', 10)
        eq(#skipped, 3)
        eq(skipped[1].detail.why, 'short')
        local after = banks()
        eq(after[11] - before[11], 900)
        eq(after[13] - before[13], 50)
    end)

    it('gives the funds back when the bank will not take a salary', function()
        local s, _, org = world()
        truthy(s.org.setSalary(W.STAFF, 0, 100))
        local at = due(s, org, 1000)
        local real = Env.players[13].Functions.AddMoney
        Env.players[13].Functions.AddMoney = function() return false end
        local out = s.org.payrollTick(at)
        Env.players[13].Functions.AddMoney = real
        eq(out.failed, 1)
        eq(s.org.Funds.balance(org), 1000, 'given back')
    end)

    it('never pays a pay day twice when it was half done (a crash before the pay day was kept)', function()
        local s, _, org = world()
        truthy(s.org.setSalary(W.STAFF, 0, 100))
        truthy(s.org.setSalary(W.STAFF, 2, 100))
        local at = due(s, org)
        local before = banks()
        truthy(s.org.payrollTick(at))
        -- As though the process died before the next pay day was written.
        org.settings.payroll.nextAt = at
        local out = s.org.payrollTick(at + 5)
        eq(out.paid, 0, 'nobody paid again')
        local after = banks()
        eq(after[13] - before[13], 100)
        eq(after[12] - before[12], 100)
    end)

    it('does not pay missed pay days over after a long outage', function()
        local s, _, org = world()
        truthy(s.org.setSalary(W.STAFF, 0, 100))
        local at = due(s, org)
        local before = banks()
        local late = at + 30 * DAY
        truthy(s.org.payrollTick(late))
        eq(org.settings.payroll.nextAt, late + 7 * DAY, 'one period from now')
        eq(s.org.payrollTick(late + 1), nil)
        eq(banks()[13] - before[13], 100, 'paid once')
    end)

    it('reads and writes nothing until the pay day', function()
        local s, _, org = world()
        truthy(s.org.setSalary(W.STAFF, 0, 100))
        local at = due(s, org)
        local reads = 0
        local real = s.storage.writeOrgRow
        s.storage.writeOrgRow = function(...) reads = reads + 1; return real(...) end
        for i = 1, 50 do s.org.payrollTick(at - 1000 + i) end
        s.storage.writeOrgRow = real
        eq(reads, 0, 'one comparison a tick')
    end)

    it('is run from the maintenance tick, as a money job', function()
        local src = io.open('crimson-hitman/server/main.lua'):read('a')
        truthy(src:find("job('org.payroll', modules.org.payrollTick)", 1, true), 'on the tick')
        truthy(src:find("['org.payroll'] = true", 1, true), 'its failure said like money at risk')
    end)
end)

describe('payroll across a restart', function()
    for _, mode in ipairs({ 'memory', 'json', 'mysql' }) do
        it('keeps the pay day and pays nobody twice on ' .. mode, function()
            forget()
            Env.reset()
            resetConfig()
            Config.Database.Mode = mode
            if mode == 'mysql' then Exec.install(Natives) end
            if mode == 'json' then Natives.files = {} end
            QbxJobs.install()
            Natives.convars['qbx:max_jobs_per_player'] = '3'
            W.player(6, 'ADMIN001')
            W.player(11, 'BOSS0001')
            W.player(13, 'RECRUIT1')
            Config.Organisation.Enabled = true
            Config.Organisation.Payroll = true
            Config.Integrations.Banking = 'none'
            local modules = require('server.main').start()
            local org = modules.org
            local STAFF = { staff = true, cid = 'ADMIN001' }
            assert(org.hire(STAFF, { cid = 'BOSS0001', name = 'Boss', source = 11 }, 3))
            assert(org.hire(STAFF, { cid = 'RECRUIT1', name = 'Recruit', source = 13 }, 0))
            assert(org.staffDeposit(STAFF, 5000, 'seed', 's1'))
            assert(org.setSalary(STAFF, 0, 400))
            local t0 = os.time()
            org.payrollTick(t0)
            local at = org.current().settings.payroll.nextAt
            eq(at, t0 + 7 * DAY)
            local bank = Env.players[13].PlayerData.money.bank
            truthy(org.payrollTick(at))
            eq(Env.players[13].PlayerData.money.bank - bank, 400)
            local function again()
                if mode == 'memory' then
                    org.init({ storage = modules.storage, identity = modules.identity, audit = modules.audit,
                        notify = modules.notify, escrow = modules.escrow, contracts = modules.contracts })
                    org.boot()
                    return org
                end
                pcall(modules.storage.flush)
                pcall(modules.storage.close)
                forget()
                return require('server.main').start().org
            end
            local org2 = again()
            eq(org2.current().settings.payroll.nextAt, at + 7 * DAY, 'the next pay day kept')
            eq(org2.current().settings.payroll.salary['0'], 400, 'the salary kept')
            eq(org2.payrollTick(at + 10), nil, 'nothing paid again')
            eq(Env.players[13].PlayerData.money.bank - bank, 400)
            eq(org2.Funds.balance(org2.current()), 4600, 'the funds kept')
            forget()
        end)
    end
end)
