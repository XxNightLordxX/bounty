--- Several organisations (plan §9 R1, Config.Organisation.SeveralOrganisations,
--- off as shipped): staff add more organisations, each its own qbx_core job,
--- roles, members, funds, places and Boss permissions, all kept by its id;
--- a citizen is a member of one at most; a player's request works on their
--- own, a staff op on the one it names (data.org), every tick on each in
--- turn. Off: only the first is read, as before.

local W = require('tests.harness.org_world')
local QbxJobs = W.QbxJobs

local function world(extra, configure)
    local s, f = W.world({ configure = function(...)
        Config.Organisation.SeveralOrganisations = true
        Config.Integrations.Banking = 'none'
        for k, v in pairs(extra or {}) do Config.Organisation[k] = v end
        if configure then configure(...) end
    end })
    W.crew(s)
    return s, f, s.org.current()
end

--- Add the second organisation, 'syndicate', through the panel.
local function second(s)
    local reply = W.ask(6, 'orgCreate', { job = 'syndicate', label = 'The Syndicate' })
    truthy(reply and reply.ok, 'added: ' .. tostring(reply and reply.message))
    return s.org.byId('syndicate')
end

local function handleFor(s, query)
    local found = s.app.handlers.searchTargets(s.identity.resolve(1), { query = query })
    return found and found[1] and found[1].handle
end

describe('several organisations switched off (as shipped)', function()
    it('ships off, with a cap of 3', function()
        resetConfig()
        eq(Config.Organisation.SeveralOrganisations, false)
        eq(Config.Organisation.MaxOrganisations, 3)
    end)

    it('reads only the first, refuses an addition in words and shows no picker', function()
        local s = W.world()
        W.crew(s)
        local reply = W.ask(6, 'orgCreate', { job = 'syndicate', label = 'The Syndicate' })
        falsy(reply.ok)
        eq(reply.err, 'org_feature_off')
        truthy(reply.message)
        local view = W.ask(6, 'orgGet', {}).data
        eq(view.several, nil)
        eq(view.orgs, nil)
        eq(#s.org.all(), 1)
        eq(W.call('orgMine', 3, {}).data.choices, nil, 'no picker for an outsider')
    end)

    it('leaves one made while on out once it is off again, and back once it is on', function()
        local s = world()
        second(s)
        Config.Organisation.SeveralOrganisations = false
        s.org.boot(true)
        eq(#s.org.all(), 1)
        eq(s.org.byId('syndicate'), nil)
        Config.Organisation.SeveralOrganisations = true
        s.org.boot(true)
        truthy(s.org.byId('syndicate'), 'read again from the store')
    end)
end)

describe('two organisations side by side', function()
    it('gives each its own job, roles and funds', function()
        local s, _, first = world()
        local org = second(s)
        truthy(org)
        truthy(QbxJobs.jobs.syndicate, 'its own qbx_core job')
        truthy(QbxJobs.jobs.hitman, 'the first kept')
        eq(QbxJobs.jobs.syndicate.label, 'The Syndicate')
        local roles = 0
        for _ in pairs(org.roles) do roles = roles + 1 end
        eq(roles, #Config.Organisation.Roles, 'the roles config.lua makes')
        eq(next(org.members), nil, 'nobody in it yet')
        truthy(W.ask(6, 'orgFundsMove', { org = 'syndicate', direction = 'deposit', amount = 3000, reason = 'seed',
            nonce = 'n1' }).ok)
        eq(s.org.Funds.balance(org), 3000)
        eq(s.org.Funds.balance(first), 0, 'the first\'s funds untouched')
        local view = W.ask(6, 'orgGet', { org = 'syndicate' }).data
        eq(view.id, 'syndicate')
        eq(view.label, 'The Syndicate')
        eq(view.balance, 3000)
        eq(#view.orgs, 2)
        eq(W.ask(6, 'orgGet', {}).data.id, 'hitman', 'none named: the first')
    end)

    it('keeps a citizen in one organisation at most', function()
        local s = world()
        second(s)
        local reply = W.ask(6, 'orgMemberHire', { org = 'syndicate', subject = 'LIEUT001', grade = 0 })
        falsy(reply.ok)
        eq(reply.err, 'org_other_org')
        truthy(W.ask(6, 'orgMemberHire', { org = 'syndicate', subject = 'CREATOR1', grade = 3 }).ok)
        eq(s.org.orgOf('CREATOR1').id, 'syndicate')
        eq(s.org.orgOf('BOSS0001').id, 'hitman')
        -- And never adopted into the other by a job change made elsewhere.
        QbxJobs.groups = QbxJobs.groups or {}
        s.org.within(s.org.byId('syndicate'), s.org.external, s.identity.resolve(11), 0)
        eq(s.org.byId('syndicate').members.BOSS0001, nil)
    end)

    it('answers each member from their own organisation', function()
        local s = world()
        second(s)
        truthy(W.ask(6, 'orgMemberHire', { org = 'syndicate', subject = 'CREATOR1', grade = 3 }).ok)
        local mine = W.call('orgMine', 1, {}).data
        eq(mine.member, true)
        eq(mine.label, 'The Syndicate')
        eq(W.call('orgMine', 11, {}).data.label, 'Crimson Contractors')
        -- A member's payload cannot point them at the other one.
        eq(W.call('orgMine', 1, { org = 'hitman' }).data.label, 'The Syndicate')
        -- The tab, the cut shown and the spots, by the member's own.
        eq(s.org.tabFor('CREATOR1', 1), 'member')
        truthy(W.ask(6, 'orgCuts', { org = 'syndicate', kind = 'payout', percent = 15 }).ok)
        eq(s.org.termsFor('CREATOR1').orgPercent, 15)
        eq(s.org.termsFor('BOSS0001').orgPercent, 0)
    end)

    it('keeps Boss permissions, places and the log apart', function()
        local s = world()
        local org = second(s)
        truthy(W.ask(6, 'bossPermsSet', { org = 'syndicate', subject = 'role', id = 3, power = 'M1', state = 'allow' }).ok)
        truthy(org.ceiling.role[3].M1)
        eq(s.org.current().ceiling.role[3] and s.org.current().ceiling.role[3].M1, nil, 'the first untouched')
        W.at(6, 500.0, 500.0)
        truthy(W.ask(6, 'placeSet', { org = 'syndicate', kind = 'office', here = true }).ok)
        local rows = 0
        for _, l in pairs(org.locations) do if l.kind == 'office' then rows = rows + 1 end end
        eq(rows, 1, 'the office is the syndicate\'s')
        for _, l in pairs(s.org.current().locations) do falsy(l.kind == 'office', 'none for the first') end
        local list = W.ask(6, 'placeList', { org = 'syndicate' }).data
        local office
        for _, k in ipairs(list.kinds) do if k.id == 'office' then office = k end end
        eq(#office.rows, 1)
        local log = W.ask(6, 'logs', { area = 'org', org = 'syndicate', limit = 100 }).data
        local actions = {}
        for _, r in ipairs(log.rows or {}) do actions[r.action] = true; eq(r.detail.org, 'syndicate') end
        truthy(actions.org_grant, 'its own grant on its log')
    end)

    it('refuses an op on an organisation that is not there', function()
        local s = world()
        second(s)
        for _, bad in ipairs({ 'nobody', 42, {}, true, ('x'):rep(40) }) do
            local reply = W.ask(6, 'orgGet', { org = bad })
            falsy(reply.ok, 'refused ' .. tostring(bad))
            truthy(reply.message)
        end
        falsy(W.ask(6, 'placeList', { org = 'nobody' }).ok)
        local r = W.call('orgMine', 3, { org = 'nobody' })
        falsy(r.ok)
    end)

    it('lets an outsider pick one and apply to it', function()
        local s = world({ ApplyAtSignupOnly = false })
        local org = second(s)
        local mine = W.call('orgMine', 3, {}).data
        eq(#mine.choices, 2)
        eq(mine.id, 'hitman')
        mine = W.call('orgMine', 3, { org = 'syndicate' }).data
        eq(mine.id, 'syndicate')
        eq(mine.label, 'The Syndicate')
        local reply = W.call('orgApply', 3, { org = 'syndicate', text = 'hire me' })
        eq(reply.ok, true, tostring(reply.err))
        local open = 0
        for _ in pairs(org.applications) do open = open + 1 end
        eq(open, 1)
        eq(next(s.org.current().applications), nil, 'nothing for the first')
        -- The open application now says which one is theirs.
        eq(W.call('orgMine', 3, {}).data.id, 'syndicate')
        eq(s.org.tabFor('HITMAN01', 3), 'applicant')
        -- A member of one may not apply to the other.
        local again = W.call('orgApply', 13, { org = 'syndicate', text = 'x' })
        falsy(again.ok)
    end)

    it('cuts a member\'s payout into their own organisation\'s funds', function()
        local s, f = world()
        second(s)
        truthy(W.ask(6, 'orgMemberHire', { org = 'syndicate', subject = 'HITMAN01', grade = 0 }).ok)
        truthy(W.ask(6, 'orgCuts', { org = 'syndicate', kind = 'payout', percent = 10 }).ok)
        local hitman = s.identity.resolve(3)
        local before = W.wealth(1)
        local c = W.place(s, f.creator)
        truthy(s.contracts.accept(hitman, c.id))
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.KIDNAPPING))
        eq(s.org.Funds.balance(s.org.byId('syndicate')), 500, 'the syndicate\'s 10%')
        eq(s.org.Funds.balance(s.org.current()), 0, 'nothing to the first')
        eq(before - W.wealth(1), 5000)
    end)

    it('holds a contract sent to one for that one\'s member only', function()
        local s = world({ OrgContracts = true })
        local org = second(s)
        truthy(W.ask(6, 'orgMemberHire', { org = 'syndicate', subject = 'HITMAN01', grade = 0 }).ok)
        local handle = handleFor(s, 'Reyes')
        local settings = s.projection.settings and s.projection.settings(s.identity.resolve(1)) or nil
        local _ = settings
        local reply = W.call('create', 1, { target = handle, reason = 'x', toOrg = 'syndicate', anonymous = false,
            reward = { slots = { { baseline = { cash = 2000 } } } }, shown = {} })
        eq(reply.ok, true, tostring(reply.err))
        local id = reply.data.id
        eq(org.settings.orgContracts[id].state, 'waiting')
        eq(s.org.current().settings.orgContracts[id], nil, 'not the first\'s')
        -- A member of the first may not take it; staff assign the syndicate's.
        local err = s.contracts.accept(s.identity.resolve(13), id)
        falsy(err, 'the first\'s member refused')
        truthy(W.ask(6, 'orgContractAssign', { org = 'syndicate', id = id,
            member = s.org.refFor('ADMIN001', 'HITMAN01') }).ok)
        truthy(s.contracts.accept(s.identity.resolve(3), id), 'its assigned member takes it')
        eq(org.settings.orgContracts[id].state, 'taken')
        -- An unknown organisation is refused before anything is placed.
        local before = W.wealth(1)
        local bad = W.call('create', 1, { target = handle, reason = 'x', toOrg = 'nobody',
            reward = { slots = { { baseline = { cash = 1000 } } } }, shown = {} })
        falsy(bad.ok)
        eq(W.wealth(1), before, 'nothing taken')
    end)

    it('keeps each channel apart', function()
        local s = world({ Channel = true })
        second(s)
        truthy(W.ask(6, 'orgMemberHire', { org = 'syndicate', subject = 'HITMAN01', grade = 0 }).ok)
        truthy(W.call('orgChannelPost', 3, { text = 'syndicate only' }).ok)
        truthy(W.call('orgChannelPost', 13, { text = 'first only' }).ok)
        local a = W.call('orgChannel', 13, {}).data
        local b = W.call('orgChannel', 3, {}).data
        local function texts(view)
            local out = {}
            for _, m in ipairs(view.rows or view.messages or {}) do out[#out + 1] = m.text or m.body end
            return table.concat(out, '|')
        end
        eq(texts(a), 'first only')
        eq(texts(b), 'syndicate only')
    end)

    it('runs the pay day of each', function()
        local s = world({ Payroll = true })
        local org = second(s)
        truthy(W.ask(6, 'orgMemberHire', { org = 'syndicate', subject = 'HITMAN01', grade = 0 }).ok)
        truthy(W.ask(6, 'orgFundsMove', { org = 'syndicate', direction = 'deposit', amount = 1000, reason = 'seed',
            nonce = 'p1' }).ok)
        truthy(W.ask(6, 'orgSalary', { org = 'syndicate', grade = 0, amount = 100 }).ok)
        s.org.payrollTick(Env.time)
        local due = org.settings.payroll.nextAt
        truthy(due, 'its own first pay day')
        local before = W.wealth(3)
        s.org.payrollTick(due + 1)
        eq(W.wealth(3) - before, 100, 'paid from its own funds')
        eq(s.org.Funds.balance(org), 900)
    end)

    it('reads both again after a restart', function()
        local s = world()
        second(s)
        truthy(W.ask(6, 'orgMemberHire', { org = 'syndicate', subject = 'HITMAN01', grade = 0 }).ok)
        s.org.boot(false)
        truthy(s.org.byId('syndicate'))
        truthy(s.org.byId('syndicate').members.HITMAN01)
        truthy(s.org.current().members.BOSS0001)
    end)

    it('stops at the cap, and refuses a job name in use or a bad one', function()
        local s = world({ MaxOrganisations = 2 })
        second(s)
        local reply = W.ask(6, 'orgCreate', { job = 'third', label = 'Third' })
        falsy(reply.ok)
        eq(reply.err, 'org_limit')
        Config.Organisation.MaxOrganisations = 3
        falsy(W.ask(6, 'orgCreate', { job = 'hitman', label = 'Again' }).ok, 'the first\'s job')
        falsy(W.ask(6, 'orgCreate', { job = 'syndicate', label = 'Again' }).ok, 'the second\'s job')
        for _, bad in ipairs({ 'Has Space', '1abc', '', 'a', ('a'):rep(40), 'x<y', 42, true }) do
            falsy(W.ask(6, 'orgCreate', { job = bad, label = 'L' }).ok, 'job ' .. tostring(bad))
        end
        for _, bad in ipairs({ '', '<b>x</b>', ('l'):rep(80), 7 }) do
            falsy(W.ask(6, 'orgCreate', { job = 'fourth', label = bad }).ok, 'label ' .. tostring(bad))
        end
        eq(#s.org.all(), 2)
        -- Only staff with the write ACE.
        falsy(W.ask(7, 'orgCreate', { job = 'fifth', label = 'Fifth' }).ok)
        falsy(s.org.create(W.boss(), { job = 'sixth', label = 'Sixth' }))
    end)

    it('takes one off only when it is empty, never the first', function()
        local s = world()
        local org = second(s)
        truthy(W.ask(6, 'orgMemberHire', { org = 'syndicate', subject = 'HITMAN01', grade = 0 }).ok)
        falsy(W.ask(6, 'orgRemove', { id = 'syndicate' }).ok, 'members still')
        falsy(W.ask(6, 'orgRemove', { id = 'hitman' }).ok, 'never the first')
        truthy(W.ask(6, 'orgMemberFire', { org = 'syndicate', subject = 'HITMAN01', reason = 'done' }).ok)
        truthy(W.ask(6, 'orgFundsMove', { org = 'syndicate', direction = 'deposit', amount = 10, reason = 'x',
            nonce = 'r1' }).ok)
        falsy(W.ask(6, 'orgRemove', { id = 'syndicate' }).ok, 'funds not empty')
        truthy(W.ask(6, 'orgFundsMove', { org = 'syndicate', direction = 'withdraw', amount = 10, reason = 'x',
            nonce = 'r2' }).ok)
        local reply = W.ask(6, 'orgRemove', { id = 'syndicate' })
        truthy(reply.ok, tostring(reply.message))
        eq(s.org.byId('syndicate'), nil)
        eq(#W.audit('org_removed'), 1)
        eq(#W.audit('org_added'), 1)
        local _ = org
    end)
end)
