--- Bug sweep 9, each confirmed finding pinned by the repro that showed it.
---
--- CONTRACT-1 a bonus raise after a baseline top-up escrows the percentage
---            it advertises, from the derived bonus actually held.
--- ORG-1      a role moved to another grade takes its staff ceiling (stored)
---            and its per-grade settings with it; a deleted role leaves none.
--- ORG-2      a lower boss cannot clear or replace a higher boss's
---            per-member grant.
--- ORG-3      a member who leaves takes their per-member settings with them.
--- ORG-4      an anonymous accept waiting for approval names nobody to the
---            boss who placed the contract.
--- ORG-5      the funds ledger names no contract to a boss.
--- ADMIN-1    a stored value under a stored ceiling survives a restart.
--- ADMIN-2    a range setting describes as a range and imports.
--- ADMIN-4    own preset names are one name whatever their case.
--- (ADMIN-3 and PHONE-2 are in tests/ui/admin_run.js and tests/ui/run.js;
--- PHONE-1 is in tests/client_spec.lua.)

local W = require('tests.harness.org_world')

local function bonusHeld(s, contractId)
    local sum = 0
    for _, l in ipairs(s.storage.readEscrow(contractId)) do
        if l.portion == CH.PORTION.BONUS and l.state ~= CH.ESCROW_STATE.SETTLED and not l.owed_to then
            sum = sum + (l.amount or 0)
        end
    end
    return sum
end

describe('sweep 9 CONTRACT-1: a raise after a top-up', function()
    it('escrows the new percentage of every baseline, a top-up included', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE, bonusPercent = 10,
            reward = { slots = { { baseline = { cash = 10000 } } } },
        })
        truthy(c, 'placed')
        eq(bonusHeld(s, c.id), 1000, '10% at creation')
        truthy(s.amendments.addEscrow(f.creator, c.id, { baseline = { cash = 10000 } }))
        eq(bonusHeld(s, c.id), 1000, 'a top-up takes no bonus of its own')
        truthy(s.amendments.improve(f.creator, c.id, CH.AMENDMENT.RAISE_BONUS, { percent = 20 }))
        eq(bonusHeld(s, c.id), 4000, '20% of the 20,000 the contract holds')
        truthy(s.amendments.improve(f.creator, c.id, CH.AMENDMENT.RAISE_BONUS, { percent = 25 }))
        eq(bonusHeld(s, c.id), 5000, 'and every later raise from what is held')
    end)

    it('tops up nothing when the held bonus is already the percentage', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE, bonusPercent = 30,
            reward = { slots = { { baseline = { cash = 7000, bank = 3000 } } } },
        })
        eq(#s.escrow.bonusTopUp(c.id, 30), 0, 'nothing more to hold')
        local extra = s.escrow.bonusTopUp(c.id, 40)
        local sum = 0
        for _, l in ipairs(extra) do sum = sum + l.amount end
        eq(sum, 1000, 'ten points of 10,000, per source')
        eq(#extra, 2, 'one line per source')
    end)
end)

describe('sweep 9 ORG-1: a role moved or deleted takes its grade settings', function()
    it('moves the stored ceiling and the per-grade settings with the role', function()
        local s = W.world({ configure = function() Config.Organisation.Payroll = true end })
        W.crew(s)
        truthy(s.org.roleCreate(W.STAFF, { grade = 5, name = 'runner', label = 'Runner' }))
        W.allow(s, 5, 'M1')
        truthy(s.org.setCut(W.STAFF, 'role', 5, 30))
        truthy(s.org.setSalary(W.STAFF, 5, 250))
        truthy(s.org.layout(W.STAFF, { hidden = { funds = { 5 } } }))
        truthy(s.org.roleEdit(W.STAFF, 5, { newGrade = 7 }))
        s.org.boot()
        local org = s.org.current()
        eq(org.ceiling.role[7] and org.ceiling.role[7].M1, 'allow', 'the ceiling is still on the moved role after a restart')
        eq(org.ceiling.role[5], nil, 'and not back on the old grade')
        eq(org.settings.cuts.byRole['7'], 30, 'the cut moved')
        eq(org.settings.cuts.byRole['5'], nil)
        eq(tonumber(org.settings.payroll.salary['7']), 250, 'the salary moved')
        eq(org.settings.payroll.salary['5'], nil)
        eq(org.settings.layout.hidden.funds[1], 7, 'the hidden tab moved')
        truthy(s.org.roleCreate(W.STAFF, { grade = 5, name = 'newbie', label = 'Newbie' }))
        org = s.org.current()
        eq(org.ceiling.role[5], nil, 'a new role at the old grade inherits no ceiling')
        eq(s.org.payoutPercent(org, { cid = 'X', grade = 5 }), s.org.payoutPercent(org, { cid = 'X', grade = 0 }),
            'nor the cut')
    end)

    it('clears a deleted role\'s per-grade settings', function()
        local s = W.world({ configure = function() Config.Organisation.Payroll = true end })
        W.crew(s)
        truthy(s.org.roleCreate(W.STAFF, { grade = 5, name = 'runner', label = 'Runner' }))
        W.allow(s, 5, 'M1')
        truthy(s.org.setCut(W.STAFF, 'role', 5, 30))
        truthy(s.org.setSalary(W.STAFF, 5, 250))
        truthy(s.org.roleDelete(W.STAFF, 5))
        s.org.boot()
        truthy(s.org.roleCreate(W.STAFF, { grade = 5, name = 'newbie', label = 'Newbie' }))
        local org = s.org.current()
        eq(org.ceiling.role[5], nil, 'no ceiling')
        eq(org.settings.cuts.byRole['5'], nil, 'no cut')
        eq(org.settings.payroll.salary['5'], nil, 'no salary')
    end)
end)

describe('sweep 9 ORG-2: a lower boss and a higher boss\'s member grant', function()
    local function setup()
        local s = W.world()
        W.crew(s)
        for _, g in ipairs({ 3, 2 }) do W.allow(s, g, 'D2'); W.allow(s, g, 'M1') end
        truthy(s.org.memberGrant(W.boss(11, 'BOSS0001'), 'RECRUIT1', 'M1', 'grant'))
        return s
    end

    it('refuses a deny, a clear and a grant over the top boss\'s grant', function()
        local s = setup()
        for _, state in ipairs({ 'deny', 'clear', 'grant' }) do
            local ok, err = s.org.memberGrant(W.boss(12, 'LIEUT001'), 'RECRUIT1', 'M1', state)
            falsy(ok, state .. ' over a higher boss')
            eq(err, 'org_rank', state .. ' answers with the rank refusal')
        end
        truthy(s.org.Engine.holds(s.org.current(), 'RECRUIT1', 'M1'), 'the grant stands')
        eq(s.org.current().members.RECRUIT1.grants.M1.by, 'BOSS0001', 'still the top boss\'s')
    end)

    it('lets the top boss replace a lieutenant\'s, and a lieutenant change their own', function()
        local s = setup()
        truthy(s.org.memberGrant(W.boss(11, 'BOSS0001'), 'RECRUIT1', 'M1', 'clear'))
        truthy(s.org.memberGrant(W.boss(12, 'LIEUT001'), 'RECRUIT1', 'M1', 'grant'))
        truthy(s.org.memberGrant(W.boss(12, 'LIEUT001'), 'RECRUIT1', 'M1', 'deny'), 'their own entry')
        truthy(s.org.memberGrant(W.boss(11, 'BOSS0001'), 'RECRUIT1', 'M1', 'grant'), 'over a lower boss\'s')
    end)
end)

describe('sweep 9 ORG-3: a member who leaves takes their settings', function()
    local function check(s)
        local org = s.org.current()
        eq(org.settings.cuts.byMember.RECRUIT1, nil, 'no own cut')
        eq(org.settings.codenames.RECRUIT1, nil, 'no codename record')
        eq(org.settings.probation.RECRUIT1, nil, 'no probation record')
        eq(org.settings.channelMutes.RECRUIT1, nil, 'no channel mute')
        eq(org.settings.strikeSuspended.RECRUIT1, nil, 'no strike suspension')
        truthy(s.org.hire(W.STAFF, { cid = 'RECRUIT1', name = 'P13', source = 13 }, 0))
        local ok, err = s.org.setCodename(W.boss(13, 'RECRUIT1'), nil, 'Cobra')
        truthy(ok, 'their own codename is theirs to choose: ' .. tostring(err))
    end
    local function seed(s)
        truthy(s.org.setCut(W.STAFF, 'member', 'RECRUIT1', 40))
        truthy(s.org.setCodename(W.STAFF, 'RECRUIT1', 'Viper'))
        local org = s.org.current()
        org.settings.probation.RECRUIT1 = { passed = 'staff', passedAt = os.time() }
        org.settings.channelMutes.RECRUIT1 = os.time() + 3600
        org.settings.strikeSuspended.RECRUIT1 = os.time() + 3600
    end

    it('when fired', function()
        local s = W.world({ configure = function() Config.Organisation.Codenames = true end })
        W.crew(s)
        seed(s)
        truthy(s.org.fire(W.STAFF, 'RECRUIT1', 'bye'))
        check(s)
    end)

    it('when the job is taken outside the resource', function()
        local s = W.world({ configure = function()
            Config.Organisation.Codenames = true
            Config.Organisation.ExternalChanges = 'adopt'
        end })
        W.crew(s)
        seed(s)
        s.org.external({ cid = 'RECRUIT1', source = 13, name = 'P13' }, nil)
        eq(s.org.current().members.RECRUIT1, nil, 'adopted the removal')
        check(s)
    end)
end)

describe('sweep 9 ORG-4: an anonymous accept and the boss who placed the contract', function()
    local function world(on, extra)
        local s = W.world({ configure = function()
            for _, key in ipairs(on) do Config.Organisation[key] = true end
            for k, v in pairs(extra or {}) do Config.Organisation[k] = v end
        end })
        W.crew(s)
        return s
    end

    it('is neither shown to nor decided by its placer, and staff see who only with IdentityAce', function()
        local s = world({ 'AcceptApproval' }, { ApprovalAbove = 1000 })
        W.allow(s, 3, 'K6')
        W.allow(s, 2, 'K6')
        local c = W.place(s, s.identity.resolve(11))
        truthy(c, 'the top boss placed it')
        eq(select(2, s.contracts.accept(s.identity.resolve(13), c.id, true)), 'org_approval')
        local mine = W.call('orgWork', 11, {}).data
        eq(#mine.approvals, 0, 'the placer is not shown the anonymous accept')
        local lieut = W.call('orgWork', 12, {}).data
        eq(#lieut.approvals, 1, 'another boss decides it')
        truthy(lieut.approvals[1].member and lieut.approvals[1].member.name, 'and sees who, as before')
        eq(W.call('orgApprove', 11, { id = lieut.approvals[1].id, approve = true }).err, 'org_not_found',
            'the placer cannot decide it')
        local blind = s.org.staffView('ADMIN001', false).extras.work.approvals[1]
        eq(blind.member, nil, 'staff without IdentityAce: a member')
        local seen = s.org.staffView('ADMIN001', true).extras.work.approvals[1]
        truthy(seen.member and seen.member.name, 'staff with IdentityAce see who')
        truthy(W.call('orgApprove', 12, { id = lieut.approvals[1].id, approve = true }).ok)
    end)

    it('still shows a named accept to its placer', function()
        local s = world({ 'AcceptApproval' }, { ApprovalAbove = 1000 })
        W.allow(s, 3, 'K6')
        local c = W.place(s, s.identity.resolve(11))
        eq(select(2, s.contracts.accept(s.identity.resolve(13), c.id, false)), 'org_approval')
        eq(#W.call('orgWork', 11, {}).data.approvals, 1)
    end)

    it('does not name the member who took an organisation contract to its placer', function()
        local s = world({ 'OrgContracts' })
        W.allow(s, 3, 'K4')
        W.allow(s, 2, 'K4')
        local c = W.place(s, s.identity.resolve(11))
        truthy(s.org.receiveContract(c.id, 'BOSS0001'))
        truthy(s.org.assignContract(W.STAFF, c.id, 'RECRUIT1'))
        truthy(s.contracts.accept(s.identity.resolve(13), c.id, true))
        local row = W.call('orgWork', 11, {}).data.contracts[1]
        eq(row.state, 'taken')
        eq(row.member, nil, 'the placer is not told who took it')
        truthy(W.call('orgWork', 12, {}).data.contracts[1].member, 'another boss is, as before')
    end)
end)

describe('sweep 9 ORG-5: the funds ledger names no contract to a boss', function()
    it('drops the contract from the rows a boss reads, keeps it for staff', function()
        local s = W.world()
        W.crew(s)
        W.allow(s, 3, 'C8')
        local org = s.org.current()
        truthy(s.org.Funds.credit(org, 500, { ref = 'cut:test1', kind = 'cut', actor = 'RECRUIT1',
            contract = 'CONTRACTX', reason = 'baseline' }))
        local _, _, boss = s.org.fundsView(W.boss(11, 'BOSS0001'))
        eq(#boss.rows, 1)
        eq(boss.rows[1].contract, nil, 'no contract for a boss')
        eq(boss.rows[1].actor, nil, 'nor who')
        local _, _, staff = s.org.fundsView(W.STAFF)
        eq(staff.rows[1].contract, 'CONTRACTX', 'staff still see it')
    end)
end)

-- The admin panel's settings (server/settings.lua, settingsio, presets).

local Exec = require('tests.harness.mysql_exec')
local CHECK = require('crimson-hitman.server.main').checkCandidate

local function freshStore(name)
    package.loaded['crimson-hitman.server.storage.' .. name] = nil
    if name == 'json' then Natives.files = {} end
    if name == 'mysql' then Exec.install(Natives) end
    local store = require('crimson-hitman.server.storage.' .. name)
    store.open()
    return store
end

local function reopened(name, store)
    if name == 'memory' then return store end
    package.loaded['crimson-hitman.server.storage.' .. name] = nil
    local again = require('crimson-hitman.server.storage.' .. name)
    again.open()
    return again
end

local function panelStack()
    local s = newStack()
    fixture(s)
    Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
        firstname = 'Sam', lastname = 'Steward' })
    Env.aces[6] = { ['crimson.admin'] = true }
    Config.Cooldowns.admin = { per = 10, burst = 500 }
    Config.Cooldowns.adminWrite = { per = 10, burst = 500 }
    s.bridges.install(s)
    return s
end

local function ask(op, data)
    Env.clientEvents = {}
    _G.source = 6
    local fired, err = pcall(Env.events['crimson-hitman:admin'], { op = op, data = data or {}, __rid = 7 })
    _G.source = nil
    truthy(fired, 'the net event must not raise: ' .. tostring(err))
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:adminResult' then return event.args[1] end
    end
    return nil
end

describe('sweep 9 ADMIN-1: a value under a ceiling raised from the panel', function()
    for _, name in ipairs({ 'memory', 'json', 'mysql' }) do
        it('survives a restart on ' .. name, function()
            local s = newStack()
            fixture(s)
            local store = freshStore(name)
            s.settings.init({ storage = store, audit = s.audit, check = CHECK })
            truthy(s.settings.set('Ledger.MaxDepthHardCap', 50, 'ADMIN001'))
            truthy(s.settings.set('Ledger.Depth', 40, 'ADMIN001'))
            resetConfig()
            eq(Config.Ledger.MaxDepthHardCap, 25, 'config.lua again')
            s.settings.init({ storage = reopened(name, store), audit = s.audit, check = CHECK })
            eq(s.settings.boot(), 2, 'both applied')
            eq(Config.Ledger.Depth, 40)
            eq(Config.Ledger.MaxDepthHardCap, 50)
            resetConfig()
        end)
    end

    it('is still refused at a restart when its ceiling is not raised', function()
        local s = newStack()
        fixture(s)
        local store = freshStore('json')
        s.settings.init({ storage = store, audit = s.audit, check = CHECK })
        store.writeSetting('Ledger.Depth', 40, 'ADMIN001', os.time())
        resetConfig()
        s.settings.init({ storage = reopened('json', store), audit = s.audit, check = CHECK })
        eq(s.settings.boot(), 0, 'not applied')
        eq(Config.Ledger.Depth, 10)
        resetConfig()
    end)

    it('imports a ceiling and a value under it in one text', function()
        panelStack()
        local text = json.encode({ format = 'crimson-hitman-settings', version = 1, settings = {
            ['Ledger.Depth'] = 40, ['Ledger.MaxDepthHardCap'] = 50 } })
        local preview = ask('settingsImport', { text = text })
        eq(preview.ok, true, tostring(preview.message))
        eq(#preview.data.changes, 2, 'both are changes, neither refused')
        eq(preview.data.changes[1].key, 'Ledger.MaxDepthHardCap', 'the ceiling first')
        local reply = ask('settingsImportApply', { text = text, expect = 2 })
        eq(reply.ok, true, tostring(reply.message))
        eq(Config.Ledger.Depth, 40)
        eq(Config.Ledger.MaxDepthHardCap, 50)
        resetConfig()
    end)
end)

describe('sweep 9 ADMIN-2: a range setting', function()
    local KEY = 'Notifications.ParanoidAlertJitter'

    it('describes as a range', function()
        local s = newStack()
        eq(s.settings.describe({ min = 5, max = 10 }), '5 to 10')
        eq(s.settings.describe({ 'fib', 'sast' }), '[fib, sast]', 'a list as before')
    end)

    it('is imported, named in its reply, and restored by an own preset', function()
        panelStack()
        local text = json.encode({ format = 'crimson-hitman-settings', version = 1,
            settings = { [KEY] = { min = 5, max = 10 } } })
        local preview = ask('settingsImport', { text = text })
        eq(#preview.data.changes, 1, 'a change, not the same')
        eq(preview.data.changes[1].to, '5 to 10')
        truthy(ask('settingsImportApply', { text = text, expect = 1 }).ok)
        eq(Config.Notifications.ParanoidAlertJitter.min, 5)
        eq(Config.Notifications.ParanoidAlertJitter.max, 10)
        local set = ask('setSetting', { key = KEY, value = { min = 6, max = 12 } })
        truthy(set.ok)
        falsy(tostring(set.message):find('[]', 1, true), 'not "[]": ' .. tostring(set.message))
        truthy(ask('presetSaveOwn', { name = 'J' }).ok)
        truthy(ask('setSetting', { key = KEY, value = { min = 60, max = 600 } }).ok)
        local applied = ask('presetApply', { name = 'J' })
        eq(applied.ok, true, tostring(applied.message))
        eq(Config.Notifications.ParanoidAlertJitter.min, 6, 'restored')
        resetConfig()
    end)
end)

describe('sweep 9 ADMIN-4: own preset names whatever their case', function()
    it('replaces the one saved under the name in another case (the memory store kept both)', function()
        local s = panelStack()
        truthy(ask('setSetting', { key = 'Limits.MaxAcceptedPerHitman', value = 4 }).ok)
        truthy(ask('presetSaveOwn', { name = 'Night' }).ok)
        truthy(ask('setSetting', { key = 'Limits.MaxAcceptedPerHitman', value = 2 }).ok)
        local again = ask('presetSaveOwn', { name = 'night' })
        truthy(again.ok)
        truthy(tostring(again.message):find('replaced', 1, true), 'said it replaced: ' .. tostring(again.message))
        local own = {}
        for _, p in ipairs(ask('presets').data.presets) do if p.own then own[#own + 1] = p.name end end
        eq(#own, 1, 'one own preset')
        eq(own[1], 'Night', 'under the name it had')
        s.audit.flush()
        local rows = s.storage.auditByAction('admin_preset_saved', 10)
        local replaced = 0
        for _, r in ipairs(rows) do if r.detail and r.detail.replaced then replaced = replaced + 1 end end
        eq(replaced, 1, 'audited as a replacement')
        truthy(ask('presetDelete', { name = 'NIGHT' }).ok, 'deleted whatever the case')
    end)
end)

describe('sweep 9 ADMIN-3: a text setting\'s own rule reaches the panel', function()
    it('sends each text key\'s length and rule in words', function()
        local s = newStack()
        fixture(s)
        local rows = {}
        for _, list in pairs(s.settings.view()) do
            if type(list) == 'table' then
                for _, r in ipairs(list) do if type(r) == 'table' and r.key then rows[r.key] = r end end
            end
        end
        local title = rows['Roleplay.WitnessHeat.Title']
        truthy(title, 'listed')
        eq(title.maxLength, 60)
        truthy(type(title.says) == 'string' and #title.says > 0, 'its rule in words')
        eq(rows['Roleplay.CityNews.Event'].maxLength, 64)
        eq(rows['Limits.MaxAcceptedPerHitman'].maxLength, nil, 'only text keys')
    end)
end)
