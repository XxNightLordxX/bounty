--- The hitman organisation's core (server/org/, Config.Organisation):
---
---   * off, as shipped: no job registered, no row read or written on any
---     backend, no export called, every request answered org_off, the
---     board and acceptance exactly as before;
---   * on: the job registered once from this resource's table (CreateJobs,
---     never bankAuth, isboss only with QbxBossFlag), every online player
---     brought in step after a late start, the convar and start-order
---     warnings said once;
---   * members hired, moved and fired online and away (AddPlayerToJob,
---     SetPlayerPrimaryJob, RemovePlayerFromJob), and qbx_core's refusals
---     ('max_jobs', 'job_missing_grade') refusing the change here;
---   * a job change made elsewhere adopted or put back;
---   * the accept gate: members only, duty, a suspension, role rules;
---   * everything kept across a restart on memory's shape, json and mysql.

local W = require('tests.harness.org_world')
local QbxJobs = W.QbxJobs
local Exec = require('tests.harness.mysql_exec')

local function forget()
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
            package.loaded[name] = nil
        end
    end
end

describe('the organisation switched off (as shipped)', function()
    it('ships off, with every switch of its own off', function()
        resetConfig()
        eq(Config.Organisation.Enabled, false)
        eq(Config.Organisation.RequireJobToAccept, false)
        eq(Config.Organisation.AcceptNeedsPower, false)
        eq(Config.Organisation.OnDutyOnly, false)
        eq(Config.Organisation.QbxBossFlag, false)
    end)

    it('registers no job, calls no export and writes no row', function()
        local s = W.world({ off = true })
        eq(#QbxJobs.calls, 0, 'no qbx_core or Renewed-Banking call')
        eq(next(s.storage._raw().org), nil, 'no organisation row')
        eq(s.org.current(), nil)
        eq(s.org.termsFor('HITMAN01'), nil)
    end)

    it('answers every phone request org_off, unread', function()
        local s = W.world({ off = true })
        local _ = s
        for _, entry in ipairs(require('server.org.boss_ops').LIST) do
            local reply = W.call(entry.name, 11, { member = 'x', grade = 1, amount = 5 })
            truthy(reply, entry.name .. ' answered')
            if entry.name == 'orgMine' then
                eq(reply.ok, true)
                eq(reply.data.enabled, false, 'orgMine says it is off')
            else
                eq(reply.err, 'org_off', entry.name)
            end
        end
        eq(#QbxJobs.calls, 0)
    end)

    it('answers every staff write org_off and the read says it is off', function()
        local s = W.world({ off = true })
        local _ = s
        for op, level in pairs(require('server.org.staff_ops').OPS) do
            local reply = W.ask(6, op, {})
            truthy(reply, op .. ' answered')
            if op == 'orgGet' then
                eq(reply.ok, true)
                eq(reply.data.enabled, false)
            elseif level == 'write' and op ~= 'orgMemberHire' then
                falsy(reply.ok, op .. ' refused')
            end
        end
        eq(#QbxJobs.calls, 0)
    end)

    it('leaves accepting and paying out exactly as before', function()
        local s, f = W.world({ off = true })
        local c = W.place(s, f.creator)
        truthy(c, 'placed')
        local before = W.wealth(3)
        truthy(s.contracts.accept(f.hitman, c.id))
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.KIDNAPPING))
        eq(W.wealth(3) - before, 5000, 'the whole reward')
        eq(next(s.storage._raw().org), nil, 'still no organisation row')
        local reply = W.call('list', 3, {})
        eq(reply.ok, true)
        eq(reply.data.orgTerms, nil, 'no cut on the board')
    end)

    it('sends mysql nothing about the organisation at a start or a tick while off', function()
        forget()
        Env.reset()
        resetConfig()
        Config.Database.Mode = 'mysql'
        Exec.install(Natives)
        local main = require('server.main')
        main.start()
        local before = #Exec.statements
        main.tick()
        local touched = 0
        for i = 1, #Exec.statements do
            local sql = Exec.statements[i]
            if sql:find('crimson_org') and not sql:find('^CREATE TABLE') and not sql:find('information_schema')
                and not sql:find('^ALTER') then
                touched = touched + 1
            end
        end
        eq(touched, 0, 'no statement reads or writes an organisation table')
        truthy(#Exec.statements >= before, 'the tick ran')
        forget()
    end)
end)

describe('the job in qbx_core', function()
    it('registers the job once, from the table, before anything else', function()
        local s = W.world()
        eq(QbxJobs.count('CreateJobs'), 1)
        local job = QbxJobs.jobs.hitman
        truthy(job, 'hitman registered')
        eq(job.label, 'Crimson Contractors')
        eq(job.type, 'hitman')
        eq(job.grades[3].name, 'Boss')
        eq(job.grades[0].name, 'Recruit')
        for _, g in pairs(job.grades) do
            falsy(g.bankAuth, 'never bankAuth: the bank screen would bypass every rule')
            falsy(g.isboss, 'isboss only with QbxBossFlag')
        end
        local org = s.org.current()
        eq(org.roles[3].is_boss, true, 'the boss flag is the table\'s own')
    end)

    it('marks boss roles isboss only with QbxBossFlag', function()
        W.world({ configure = function() Config.Organisation.QbxBossFlag = true end })
        eq(QbxJobs.jobs.hitman.grades[3].isboss, true)
        falsy(QbxJobs.jobs.hitman.grades[2].isboss)
    end)

    it('brings an online member back in step after a late start', function()
        local s = W.world()
        W.crew(s)
        -- A restart in which qbx_core forgot the job (it was registered late).
        QbxJobs.groups.BOSS0001 = nil
        Env.players[11].PlayerData.jobs = {}
        Env.players[11].PlayerData.job = { name = 'hitman', label = 'Civilian', grade = { level = 0 }, onduty = false }
        QbxJobs.calls = {}
        s.org.boot()
        eq(QbxJobs.groups.BOSS0001.hitman, 3, 'the boss is in the job at grade 3 again')
        truthy(QbxJobs.count('SetPlayerPrimaryJob') >= 1, 'and the primary job set again, label and all')
        eq(Env.players[11].PlayerData.job.label, 'Crimson Contractors')
    end)

    it('tells qbx_core of a role created, re-paid and deleted', function()
        local s = W.world()
        truthy(s.org.roleCreate(W.STAFF, { grade = 5, name = 'consigliere', label = 'Consigliere', pay = 40 }))
        eq(QbxJobs.jobs.hitman.grades[5].name, 'Consigliere')
        truthy(s.org.rolePay(W.STAFF, 5, 75))
        eq(QbxJobs.jobs.hitman.grades[5].payment, 75)
        truthy(s.org.roleDelete(W.STAFF, 5))
        eq(QbxJobs.jobs.hitman.grades[5], nil)
        truthy(s.org.rename(W.STAFF, 'The Firm'))
        eq(QbxJobs.jobs.hitman.label, 'The Firm')
    end)

    it('warns once about qbx:cleanPlayerGroups, group management and one job a player', function()
        local log = require('crimson-hitman.shared.log')
        W.world({ configure = function()
            Natives.convars['qbx:cleanPlayerGroups'] = 'true'
            Natives.convars['qbx:enableGroupManagement'] = 'true'
            Natives.convars['qbx:max_jobs_per_player'] = '1'
        end })
        local view = log.view()
        local text = json.encode(view)
        truthy(text:find('cleanPlayerGroups', 1, true), 'cleanPlayerGroups said')
        truthy(text:find('enableGroupManagement', 1, true), 'group management said')
        truthy(text:find('max_jobs_per_player', 1, true), 'one job a player said')
        local s = W.world({ configure = function() Natives.convars['qbx:cleanPlayerGroups'] = 'true' end })
        local lines = 0
        for _, line in ipairs(Env.console or {}) do
            if tostring(line):find('cleanPlayerGroups', 1, true) then lines = lines + 1 end
        end
        s.org.boot()
        local after = 0
        for _, line in ipairs(Env.console or {}) do
            if tostring(line):find('cleanPlayerGroups', 1, true) then after = after + 1 end
        end
        eq(after, lines, 'said once, not at every boot')
    end)

    it('warns that Renewed-Banking started first, and makes the account', function()
        W.world({ bank = true })
        truthy(QbxJobs.count('CreateJobAccount') == 1, 'the account made once')
        local text = json.encode(require('crimson-hitman.shared.log').view())
        truthy(text:find('Renewed-Banking started before', 1, true), 'the start order said')
    end)
end)

describe('members', function()
    it('hires online, primary job and all, and fires', function()
        local s = W.world()
        truthy(s.org.hire(W.STAFF, { cid = 'BOSS0001', name = 'P11', source = 11 }, 3))
        eq(QbxJobs.groups.BOSS0001.hitman, 3)
        eq(Env.players[11].PlayerData.job.name, 'hitman', 'primary (SetPrimaryOnHire)')
        eq(Env.players[11].PlayerData.job.onduty, true, 'defaultDuty')
        truthy(s.org.fire(W.STAFF, 'BOSS0001', 'gone'))
        eq(QbxJobs.groups.BOSS0001.hitman, nil)
        eq(Env.players[11].PlayerData.job.name, 'unemployed')
        eq(s.org.current().members.BOSS0001, nil)
    end)

    it('hires and moves a member who is away, by citizen id', function()
        local s = W.world()
        Env.characters.AWAY0001 = true
        truthy(s.org.hire(W.STAFF, { cid = 'AWAY0001', name = 'Away' }, 1))
        eq(QbxJobs.groups.AWAY0001.hitman, 1, 'player_groups written for them')
        truthy(s.org.setRole(W.STAFF, 'AWAY0001', 2))
        eq(QbxJobs.groups.AWAY0001.hitman, 2)
        truthy(s.org.fire(W.STAFF, 'AWAY0001', 'left'))
        eq(QbxJobs.groups.AWAY0001.hitman, nil)
    end)

    it('refuses a hire qbx_core refuses, and keeps nothing', function()
        local s = W.world()
        Natives.convars['qbx:max_jobs_per_player'] = '1'
        Env.players[12].PlayerData.job = { name = 'mechanic', label = 'Mechanic', grade = { level = 0 } }
        local ok, err, extra = s.org.hire(W.STAFF, { cid = 'LIEUT001', name = 'P12', source = 12 }, 0)
        falsy(ok)
        eq(err, 'org_refused')
        eq(extra.qbx, 'max_jobs', 'qbx_core\'s own code')
        eq(s.org.current().members.LIEUT001, nil)
        local none = s.org.hire(W.STAFF, { cid = 'NOBODY99', name = 'x' }, 0)
        falsy(none, 'player_not_found')
        falsy(s.org.hire(W.STAFF, { cid = 'RECRUIT1', name = 'x', source = 13 }, 9), 'no such role')
    end)

    it('adopts a job given elsewhere, and a removal', function()
        local s = W.world()
        -- /setjob from another resource: qbx_core changes, fires its event.
        Env.exports = nil
        exports.qbx_core:AddPlayerToJob('RECRUIT1', 'hitman', 1)
        eq(s.org.current().members.RECRUIT1.grade, 1, 'adopted at grade 1')
        exports.qbx_core:RemovePlayerFromJob('RECRUIT1', 'hitman')
        eq(s.org.current().members.RECRUIT1, nil, 'and taken out')
        s.audit.flush()
        truthy(#(s.storage.auditByAction('org_external_adopted', 10) or {}) >= 2)
    end)

    it('puts a change made elsewhere back with ExternalChanges = revert', function()
        local s = W.world({ configure = function() Config.Organisation.ExternalChanges = 'revert' end })
        W.crew(s)
        exports.qbx_core:AddPlayerToJob('RECRUIT1', 'hitman', 3)
        eq(QbxJobs.groups.RECRUIT1.hitman, 0, 'back at the table\'s grade')
        eq(s.org.current().members.RECRUIT1.grade, 0)
        exports.qbx_core:AddPlayerToJob('TARGET01', 'hitman', 0)
        eq(QbxJobs.groups.TARGET01.hitman, nil, 'a stranger taken out again')
    end)

    it('brings a member in step at login', function()
        local s = W.world()
        W.crew(s)
        QbxJobs.groups.LIEUT001 = nil
        Env.players[12].PlayerData.jobs = {}
        Env.events['local:QBCore:Server:PlayerLoaded'](Env.players[12])
        eq(QbxJobs.groups.LIEUT001.hitman, 2)
    end)
end)

describe('the staff panel\'s member ops', function()
    it('hires the player a lookup found, by its handle, and moves and fires by the roster\'s', function()
        local s = W.world()
        local found = W.ask(6, 'player', { subject = 3 })
        truthy(found and found.ok, 'looked up')
        local reply = W.ask(6, 'orgMemberHire', { ref = found.data.player.ref, grade = 1 })
        eq(reply.ok, true, tostring(reply.message))
        eq(s.org.current().members.HITMAN01.grade, 1)
        eq(W.ask(6, 'orgMemberHire', { ref = 'p999_1' }).err, 'stale_lookup', 'a handle never given')
        eq(W.ask(6, 'orgMemberHire', { subject = 'Rook Ash' }).err, CH.ERR.INVALID_INPUT, 'never a name')
        local view = W.ask(6, 'orgGet', {})
        local ref
        for _, m in ipairs(view.data.members) do if m.grade == 1 then ref = m.ref end end
        eq(W.ask(6, 'orgMemberRole', { member = ref, grade = 2 }).ok, true)
        eq(W.ask(6, 'orgMemberOverride', { member = ref, power = 'M1', state = 'grant', codename = 'Ghost',
            locked = true }).ok, true)
        eq(s.org.current().members.HITMAN01.codename, 'Ghost')
        eq(W.ask(6, 'orgMemberFire', { member = ref }).ok, false, 'a reason is required')
        eq(W.ask(6, 'orgMemberFire', { member = ref, reason = 'done' }).ok, true)
        eq(s.org.current().members.HITMAN01, nil)
        eq(W.ask(7, 'orgMemberHire', { ref = found.data.player.ref }).err, 'not_allowed', 'a reader may not')
        s.audit.flush()
        local hired = s.storage.auditByAction('org_member_hired', 10)[1]
        eq(hired.detail.by, 'staff')
        local audit = W.ask(6, 'orgAudit', {})
        eq(audit.ok, true)
        truthy(#audit.data.rows >= 4, 'the organisation\'s log')
        eq(audit.data.rows[1].by, 'a staff member', 'without IdentityAce, no citizen id')
    end)

    it('registers the job again from the panel (Create / sync job)', function()
        local s = W.world()
        local _ = s
        QbxJobs.calls = {}
        local reply = W.ask(6, 'orgSetup', {})
        eq(reply.ok, true, tostring(reply.message))
        eq(QbxJobs.count('CreateJobs'), 1)
        eq(reply.data.job, 'hitman')
    end)
end)

describe('the accept gate', function()
    local function setup(configure)
        local s, f = W.world({ configure = configure })
        local c = W.place(s, f.creator)
        return s, f, c
    end

    it('lets everybody accept with RequireJobToAccept off', function()
        local s, f, c = setup()
        truthy(s.contracts.accept(f.hitman, c.id))
    end)

    it('refuses a non-member with RequireJobToAccept on, before anything is taken', function()
        local s, f, c = setup(function() Config.Organisation.RequireJobToAccept = true end)
        local before = W.wealth(3)
        local ok, err = s.contracts.accept(f.hitman, c.id)
        falsy(ok)
        eq(err, 'org_members_only')
        eq(W.wealth(3), before)
        truthy(s.org.hire(W.STAFF, { cid = 'HITMAN01', name = 'Rook', source = 3 }, 0))
        truthy(s.contracts.accept(s.identity.resolve(3), c.id), 'a member, any grade, may')
    end)

    it('with AcceptNeedsPower, only roles given Take contracts', function()
        local s, f, c = setup(function()
            Config.Organisation.RequireJobToAccept = true
            Config.Organisation.AcceptNeedsPower = true
        end)
        truthy(s.org.hire(W.STAFF, { cid = 'HITMAN01', name = 'Rook', source = 3 }, 0))
        local ok, err = s.contracts.accept(s.identity.resolve(3), c.id)
        falsy(ok)
        eq(err, 'org_rule')
        truthy(s.org.rolePower(W.STAFF, 0, 'TAKE', true))
        truthy(s.contracts.accept(s.identity.resolve(3), c.id))
    end)

    it('holds members to duty, a suspension and their role\'s rules', function()
        local s, f, c = setup(function() Config.Organisation.OnDutyOnly = true end)
        local _ = f
        truthy(s.org.hire(W.STAFF, { cid = 'HITMAN01', name = 'Rook', source = 3 }, 0))
        Env.players[3].PlayerData.job.onduty = false
        local ok, err = s.contracts.accept(s.identity.resolve(3), c.id)
        eq(err, 'org_off_duty')
        Env.players[3].PlayerData.job.onduty = true
        truthy(s.org.suspend(W.STAFF, 'HITMAN01', 2, 'late'))
        ok, err = s.contracts.accept(s.identity.resolve(3), c.id)
        falsy(ok)
        eq(err, CH.ERR.SUSPENDED)
        truthy(s.org.suspend(W.STAFF, 'HITMAN01', 0))
        truthy(s.org.setAccess(W.STAFF, 0, { maxReward = 1000 }))
        ok, err = s.contracts.accept(s.identity.resolve(3), c.id)
        eq(err, 'org_rule', 'over the role\'s most reward')
        truthy(s.org.setAccess(W.STAFF, 0, { maxReward = false }))
        truthy(s.contracts.accept(s.identity.resolve(3), c.id))
    end)

    it('holds a member to their own most at once and cooldown', function()
        local s, f = W.world()
        truthy(s.org.hire(W.STAFF, { cid = 'HITMAN01', name = 'Rook', source = 3 }, 0))
        truthy(s.org.memberLimits(W.STAFF, 'HITMAN01', 1, 30))
        Config.Limits.MaxActiveContractsPerCreator = 10
        W.player(21, 'TARGET02')
        local a = W.place(s, f.creator)
        local b = W.place(s, f.creator, 'TARGET02')
        truthy(a and b, 'two contracts')
        truthy(s.contracts.accept(s.identity.resolve(3), a.id))
        local ok, err = s.contracts.accept(s.identity.resolve(3), b.id)
        falsy(ok)
        truthy(err == CH.ERR.LIMIT_REACHED or err == 'org_cooldown', tostring(err))
    end)

    it('refuses an acceptance at a cut that changed since the page showed it', function()
        local s, f, c = setup()
        local _ = f
        truthy(s.org.hire(W.STAFF, { cid = 'HITMAN01', name = 'Rook', source = 3 }, 0))
        truthy(s.org.setCut(W.STAFF, 'payout', nil, 10))
        local ok, err, data = s.contracts.accept(s.identity.resolve(3), c.id, false,
            { checkDisclosure = true, shown = { orgCut = 5 } })
        falsy(ok)
        eq(err, CH.ERR.TERMS_CHANGED)
        eq(data.orgCut, 10)
        truthy(s.contracts.accept(s.identity.resolve(3), c.id, false, { checkDisclosure = true, shown = { orgCut = 10 } }))
    end)

    it('shows a member the cut on the board, and nobody else', function()
        local s = W.world()
        W.crew(s)
        truthy(s.org.setCut(W.STAFF, 'payout', nil, 15))
        local reply = W.call('list', 11, {})
        eq(reply.data.orgTerms.orgPercent, 15)
        eq(reply.data.orgTerms.youKeepPercent, 85)
        eq(W.call('list', 3, {}).data.orgTerms, nil)
    end)
end)

describe('the organisation across a restart', function()
    local function crewAndEverything(org, STAFF)
        assert(org.hire(STAFF, { cid = 'BOSS0001', name = 'Boss', source = 11 }, 3))
        assert(org.hire(STAFF, { cid = 'RECRUIT1', name = 'Recruit', source = 13 }, 0))
        assert(org.setCeiling(STAFF, 'role', 3, 'M2', 'allow'))
        assert(org.setCeiling(STAFF, 'member', 'RECRUIT1', 'C8', 'deny'))
        assert(org.rolePower(STAFF, 0, 'TAKE', true))
        assert(org.memberGrant(STAFF, 'RECRUIT1', 'M1', 'grant'))
        assert(org.setCut(STAFF, 'payout', nil, 12))
        assert(org.setCut(STAFF, 'role', 0, 8))
        assert(org.setLimits(STAFF, { MaxMembers = 9 }))
        assert(org.memberStaff(STAFF, 'RECRUIT1', { codename = 'Viper', locked = true }))
        assert(org.staffDeposit(STAFF, 7000, 'seed', 'n1'))
        assert(org.placeSpot({ staff = true, cid = 'ADMIN001', source = 6 }, { kind = 'signup', x = 10, y = 20, z = 30 }))
        assert(org.notice(STAFF, 'Meet at nine', false))
    end
    local function check(org)
        local st = org.current()
        eq(st.members.BOSS0001.grade, 3)
        eq(st.members.RECRUIT1.codename, 'Viper')
        eq(st.members.RECRUIT1.locked, true)
        eq(st.ceiling.role[3].M2, 'allow')
        eq(st.ceiling.member.RECRUIT1.C8, 'deny')
        eq(st.roles[0].powers.TAKE.by, 'staff')
        eq(st.members.RECRUIT1.grants.M1.by, 'staff')
        eq(st.settings.cuts.payout, 12)
        eq(st.settings.cuts.byRole['0'], 8)
        eq(org.Powers.limit(st, 'MaxMembers'), 9)
        eq(org.Funds.balance(st), 7000)
        eq(st.settings.notice.text, 'Meet at nine')
        local signups = 0
        for _, l in pairs(st.locations) do if l.kind == 'signup' then signups = signups + 1 end end
        eq(signups, 1)
        truthy(org.Engine.holds(st, 'BOSS0001', 'M2'))
        falsy(org.Engine.holds(st, 'RECRUIT1', 'C8'))
    end

    for _, mode in ipairs({ 'memory', 'json', 'mysql' }) do
        it('keeps every table on ' .. mode, function()
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
            local main = require('server.main')
            local modules = main.start()
            local org = modules.org
            crewAndEverything(org, { staff = true, cid = 'ADMIN001' })
            check(org)
            if mode == 'memory' then
                -- memory holds nothing past the process: one load again of
                -- what it has, the shape every backend hands back.
                org.init({ storage = modules.storage, identity = modules.identity, audit = modules.audit,
                    notify = modules.notify, escrow = modules.escrow, contracts = modules.contracts })
                org.boot()
                check(org)
                return
            end
            pcall(modules.storage.flush)
            pcall(modules.storage.close)
            forget()
            QbxJobs.calls = {}
            local again = require('server.main').start()
            check(again.org)
            eq(QbxJobs.count('CreateJobs'), 1, 'the job registered again at the start')
            forget()
        end)
    end
end)
