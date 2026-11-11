--- Organisation extras 2 (server/org/extras2.lua, plan R9, R11, R12, R13),
--- each its own switch under Config.Organisation, off as shipped:
---
---   * off: nothing on the tab, nothing asked of the store or the inventory
---     script, every request refused in words, an application as before;
---   * R9 the armory: an ox_inventory stash only the app reaches; allowed
---     items in, a role's limit a day out, A1 beyond it, A2 sets it; every
---     move logged; nothing lost when the inventory refuses half a move;
---     'none' turns it off in words;
---   * R11 the record and leaderboard: counted from the record's outcomes,
---     bands not exact times for players, M10 for the numbers, staff all;
---   * R12 discipline: strikes and warnings (M11), told to the member,
---     decaying, barring from contracts and demoting at their marks, only
---     staff overturn;
---   * R13 recruitment: the boss's form (N4), answers, interview notes
---     (N2), hire or decline as before, a cooldown and an hourly cap.

local W = require('tests.harness.org_world')

local BOSS = W.boss(11, 'BOSS0001')
local SWITCHES = { 'Armory', 'Stats', 'Discipline', 'Recruitment' }

local function world(on, extra)
    local s, f = W.world({ configure = function()
        for _, key in ipairs(on or {}) do Config.Organisation[key] = true end
        for k, v in pairs(extra or {}) do Config.Organisation[k] = v end
    end })
    W.crew(s)
    return s, f, s.org.current()
end

local function refOf(s, viewer, cid) return s.org.refFor(viewer, cid) end

--- Every notice a citizen is sent from here on: [cid] = { text, ... }.
local function told(s)
    local said = {}
    local real = s.notify.toCitizen
    s.notify.toCitizen = function(cid, title, text, ...)
        said[cid] = said[cid] or {}
        table.insert(said[cid], tostring(text))
        return real(cid, title, text, ...)
    end
    return said
end

local function stash(org) return Env.stashes['crimson_armory_' .. org.id] end

local function held(src, name)
    local n = 0
    for _, slot in ipairs(Env.players[src]._inventory) do if slot.name == name then n = n + slot.count end end
    return n
end

describe('organisation extras 2 switched off (as shipped)', function()
    it('ships every switch off', function()
        resetConfig()
        for _, key in ipairs(SWITCHES) do eq(Config.Organisation[key], false, key) end
    end)

    it('adds nothing to the tab, asks the inventory nothing and refuses every request in words', function()
        local s, _, org = world()
        local before = #Natives.calls.inventory
        local mine = W.call('orgMine', 13, {}).data
        for _, key in ipairs({ 'stats', 'statsOn', 'discipline', 'armory', 'armoryReady', 'recruitment' }) do
            eq(mine[key], nil, key .. ' not on the tab')
        end
        eq(W.call('orgMine', 3, {}).data.form, nil, 'no form for an outsider')
        for _, p in ipairs(require('server.org.powers').LIST) do W.allow(s, 3, p.code) end
        local lieut = refOf(s, 'BOSS0001', 'LIEUT001')
        for _, name in ipairs({ 'orgArmory', 'orgArmoryPut', 'orgArmoryTake', 'orgArmoryLimit', 'orgStats',
            'orgStrike', 'orgDisciplineRecord', 'orgRecruitForm', 'orgInterviewNote' }) do
            local reply = W.call(name, 11, { slot = 1, count = 1, grade = 0, member = lieut, kind = 'strike',
                reason = 'x', questions = { 'Why?' }, id = 'app:x', text = 'note' })
            falsy(reply.ok, name .. ' refused')
            truthy(reply.data and reply.data.message, name .. ' says why')
        end
        for _, op in ipairs({ 'orgArmoryGet', 'orgArmoryLimit', 'orgArmoryStock', 'orgStatsGet', 'orgStatsReset',
            'orgStrike', 'orgOverturn', 'orgRecruitForm', 'orgInterviewNote' }) do
            local reply = W.ask(6, op, { grade = 0, count = 1, item = 'lockpick', all = true, subject = 'LIEUT001',
                kind = 'strike', reason = 'x', id = 'dc1', questions = { 'Why?' }, text = 'note' })
            falsy(reply.ok, op .. ' refused')
        end
        eq(#Natives.calls.inventory, before, 'the inventory script never asked')
        eq(next(Env.stashes), nil, 'no stash registered')
        eq(s.org.staffView('ADMIN001').extras2, nil, 'nothing on the panel')
        -- An application as before: no form, no cooldown.
        Config.Organisation.ApplyAtSignupOnly = false
        eq(W.call('orgApply', 3, { text = 'Let me in' }).ok, true)
        local _, _, apps = s.org.applications(W.STAFF)
        eq(apps.rows[1].body, 'Let me in')
        eq(apps.rows[1].form, nil)
        truthy(s.org.decide(W.STAFF, apps.rows[1].id, false))
        eq(next(org.settings.recruit.cooldowns), nil, 'no cooldown kept')
    end)

    it('counts nothing and asks the store nothing for an outcome while off', function()
        local s, _, org = world()
        local calls = 0
        local saved = {}
        for name, fn in pairs(s.storage) do
            if type(fn) == 'function' and name:find('Org') then
                saved[name] = fn
                s.storage[name] = function(...) calls = calls + 1 return fn(...) end
            end
        end
        for _ = 1, 20 do s.record.onCompleted('RECRUIT1', 'elimination', nil, { earned = 100, seconds = 60 }) end
        s.record.onFailed('RECRUIT1')
        for name, fn in pairs(saved) do s.storage[name] = fn end
        eq(calls, 0, 'no organisation row read or written')
        eq(next(org.settings.stats), nil)
    end)
end)

describe('R9: the armory', function()
    local function armory(extra)
        local opts = { ArmoryItems = { 'lockpick', 'bandage' }, ArmoryAtOffice = false }
        for k, v in pairs(extra or {}) do opts[k] = v end
        local s, f, org = world({ 'Armory' }, opts)
        Env.players[13]._inventory = { { name = 'lockpick', count = 6, slot = 1 },
            { name = 'weapon_pistol', count = 1, slot = 2, metadata = { serial = 'AB12' } } }
        return s, f, org
    end

    it('is a stash only the app reaches, and takes in only the items staff allow', function()
        local s, _, org = armory()
        local view = W.call('orgArmory', 13, {})
        eq(view.ok, true, tostring(view.err))
        truthy(stash(org), 'registered with ox_inventory')
        eq(stash(org).groups['crimson_armory_locked'], 0, 'under a group nobody holds: its own screen never opens it')
        eq(stash(org).slots, 50)
        eq(#view.data.own, 1, 'only the allowed item of theirs offered')
        eq(view.data.own[1].name, 'lockpick')
        eq(W.call('orgArmoryPut', 13, { slot = 2, count = 1 }).err, 'org_rule', 'a weapon not allowed')
        eq(W.call('orgArmoryPut', 13, { slot = 1, count = 9 }).err, 'org_bounds', 'more than they hold')
        eq(W.call('orgArmoryPut', 13, { slot = 1, count = 4 }).ok, true)
        eq(held(13, 'lockpick'), 2)
        eq(stash(org)._inventory[1].count, 4)
        eq(W.call('orgArmoryPut', 3, { slot = 1, count = 1 }).err, 'org_not_member')
        eq(#W.audit('org_armory_deposit'), 1, 'on the record')
        eq(org.settings.armory.log[1].dir, 'in')
    end)

    it('gives out a role\'s limit a day, A1 beyond it, and A2 sets the limit below the boss', function()
        local s, _, org = armory()
        eq(W.call('orgArmoryPut', 13, { slot = 1, count = 6 }).ok, true)
        local slot = stash(org)._inventory[1].slot
        eq(W.call('orgArmoryTake', 13, { slot = slot, count = 1 }).err, 'org_limit', 'no limit set: nothing out')
        eq(W.call('orgArmoryLimit', 11, { grade = 0, count = 2 }).err, 'org_no_power')
        W.allow(s, 3, 'A2')
        eq(W.call('orgArmoryLimit', 11, { grade = 3, count = 2 }).err, 'org_rank', 'never their own rank')
        eq(W.call('orgArmoryLimit', 11, { grade = 0, count = 11 }).err, 'org_bounds', 'within ArmoryWithdrawMax')
        eq(W.call('orgArmoryLimit', 11, { grade = 0, count = 2 }).ok, true)
        eq(W.call('orgArmoryTake', 13, { slot = slot, count = 2 }).ok, true)
        eq(held(13, 'lockpick'), 2)
        local over = W.call('orgArmoryTake', 13, { slot = slot, count = 1 })
        eq(over.err, 'org_limit', 'the day\'s limit taken')
        truthy(over.data.message:find('0 more', 1, true), over.data.message)
        -- The next day, the limit again.
        Env.advance(86400)
        eq(W.call('orgArmoryTake', 13, { slot = slot, count = 1 }).ok, true)
        -- A boss holding A1 takes beyond their role's limit, and reads the log.
        eq(W.call('orgArmoryTake', 11, { slot = slot, count = 1 }).err, 'org_limit')
        falsy(W.call('orgArmory', 11, {}).data.log, 'no log without A1')
        W.allow(s, 3, 'A1')
        eq(W.call('orgArmoryTake', 11, { slot = slot, count = 2 }).ok, true)
        local log = W.call('orgArmory', 11, {}).data.log
        eq(#log, 4, 'every move in the log')
        eq(log[1].dir, 'out', 'newest first')
        eq(#W.audit('org_armory_withdraw'), 3)
        local beyond = false
        for _, row in ipairs(W.audit('org_armory_withdraw')) do
            if type(row.detail) == 'table' and row.detail.beyond == 2 then beyond = true end
        end
        truthy(beyond, 'beyond the role limit, on the record')
    end)

    it('gives nothing to a suspended member, and keeps to the office where it says', function()
        local s, _, org = armory({ ArmoryAtOffice = true })
        eq(W.call('orgArmoryPut', 13, { slot = 1, count = 1 }).err, 'org_office', 'no office set')
        W.office(s, 100.0, 100.0)
        W.at(13, 500.0, 500.0)
        eq(W.call('orgArmoryPut', 13, { slot = 1, count = 1 }).err, 'org_office', 'away from it')
        W.at(13, 100.0, 100.0)
        eq(W.call('orgArmoryPut', 13, { slot = 1, count = 3 }).ok, true)
        truthy(s.org.armoryLimit(W.STAFF, 0, 5))
        truthy(s.org.suspend(W.STAFF, 'RECRUIT1', 2, 'late'))
        eq(W.call('orgArmoryTake', 13, { slot = stash(org)._inventory[1].slot, count = 1 }).err, 'org_rule')
    end)

    it('loses nothing when the inventory refuses half a move', function()
        local s, _, org = armory()
        Natives.stashAddRefuses = true
        eq(W.call('orgArmoryPut', 13, { slot = 1, count = 3 }).err, 'org_refused')
        Natives.stashAddRefuses = nil
        eq(held(13, 'lockpick'), 6, 'back with whoever put it in')
        eq(W.call('orgArmoryPut', 13, { slot = 1, count = 3 }).ok, true)
        truthy(s.org.armoryLimit(W.STAFF, 0, 5))
        Env.players[13]._inventoryFull = true
        eq(W.call('orgArmoryTake', 13, { slot = stash(org)._inventory[1].slot, count = 1 }).err, 'org_limit',
            'cannot carry it: asked first')
        Env.players[13]._inventoryFull = nil
        eq(stash(org)._inventory[1].count, 3, 'still in the armory')
    end)

    it('is off in words with no inventory script', function()
        local s = armory()
        Config.Integrations.Inventory = 'none'
        s.bridges.install(s)
        local reply = W.call('orgArmory', 13, {})
        eq(reply.ok, false)
        truthy(reply.data.message:find('inventory', 1, true), reply.data.message)
        eq(W.call('orgMine', 13, {}).data.armoryReady, nil)
        local lines = require('server.adapters.init').report(true)
        local said = false
        for _, line in ipairs(lines) do if line:find('armory', 1, true) then said = true end end
        truthy(said, 'one console line says the armory is off')
    end)

    it('lets staff stock it, take items out, set limits and read it from the panel', function()
        local _, _, org = armory()
        eq(W.ask(6, 'orgArmoryStock', { item = 'weapon_rifle', count = 1 }).ok, false, 'only allowed items')
        eq(W.ask(6, 'orgArmoryStock', { item = 'bandage', count = 5 }).ok, true)
        local got = W.ask(6, 'orgArmoryGet', {})
        eq(got.ok, true)
        eq(got.data.items[1].name, 'bandage')
        eq(W.ask(6, 'orgArmoryStock', { remove = true, slot = got.data.items[1].slot, count = 2 }).ok, true)
        eq(stash(org)._inventory[1].count, 3)
        eq(W.ask(6, 'orgArmoryLimit', { grade = 3, count = 500 }).ok, true, 'staff past the bound, any rank')
        eq(#W.audit('org_armory_stocked'), 1)
        eq(#W.audit('org_armory_removed'), 1)
        truthy(W.ask(6, 'orgGet', {}).data.extras2.armory.items, 'orgGet carries it')
    end)
end)

describe('R11: the record and the leaderboard', function()
    local function done(s, cid, earned, seconds)
        s.record.onCompleted(cid, 'elimination', nil, { earned = earned, seconds = seconds })
    end

    it('counts each member\'s outcomes from the record, and fills Your record', function()
        local s, _, org = world({ 'Stats' })
        done(s, 'RECRUIT1', 5000, 20 * 60)
        done(s, 'RECRUIT1', 3000, 40 * 60)
        s.record.onFailed('RECRUIT1')
        done(s, 'TARGET01', 9999, 60)
        eq(org.settings.stats.TARGET01, nil, 'only members are counted')
        local mine = W.call('orgMine', 13, {}).data.stats
        eq(mine.completed, 2)
        eq(mine.failed, 1)
        eq(mine.earned, 8000, 'their own earnings')
        eq(mine.rate, 66, 'reliability once three outcomes are in')
        eq(mine.band, '30 min to 2 h', 'a band, never the exact time')
        eq(mine.rank, 1)
    end)

    it('shows players bands and no money, M10 the numbers, staff the minutes too', function()
        local s = world({ 'Stats' })
        done(s, 'RECRUIT1', 5000, 10 * 60)
        done(s, 'LIEUT001', 1000, 600 * 60)
        done(s, 'LIEUT001', 1000, 600 * 60)
        local board = W.call('orgStats', 13, {}).data
        eq(board.rows[1].completed, 2, 'by completions')
        for _, r in ipairs(board.rows) do
            eq(r.earned, nil, 'no earnings for a player')
            eq(r.failed, nil)
            eq(r.avgMinutes, nil, 'no exact time')
        end
        eq(board.rows[1].band, 'over 8 h')
        W.allow(s, 3, 'M10')
        local boss = W.call('orgStats', 11, {}).data
        eq(boss.rows[1].earned, 2000)
        eq(boss.rows[1].avgMinutes, nil, 'a boss sees bands too')
        local staff = W.ask(6, 'orgStatsGet', {}).data
        eq(staff.rows[1].avgMinutes, 600)
        Config.Organisation.StatsLeaderboard = false
        eq(W.call('orgStats', 13, {}).err, 'org_no_power', 'bosses only, where staff say so')
        eq(W.call('orgStats', 11, {}).ok, true)
    end)

    it('counts a real claim with what it paid and a walk-away as a failure', function()
        local s, f, org = world({ 'Stats' })
        local c = W.place(s, f.creator)
        local recruit = s.identity.resolve(13)
        truthy(s.contracts.accept(recruit, c.id))
        Env.advance(90)
        truthy(s.contracts.abandon(recruit, c.id))
        eq(org.settings.stats.RECRUIT1.f, 1, 'walking away counted')
    end)

    it('lets staff reset one member or everybody', function()
        local s, _, org = world({ 'Stats' })
        done(s, 'RECRUIT1', 10, 10)
        done(s, 'LIEUT001', 10, 10)
        eq(W.ask(6, 'orgStatsReset', { subject = 'RECRUIT1' }).ok, true)
        eq(org.settings.stats.RECRUIT1, nil)
        truthy(org.settings.stats.LIEUT001)
        eq(W.ask(6, 'orgStatsReset', { all = true }).ok, true)
        eq(next(org.settings.stats), nil)
        eq(#W.audit('org_stats_reset'), 2)
    end)
end)

describe('R12: discipline', function()
    it('gives a strike or a warning below the boss, told to the member and on their record', function()
        local s = world({ 'Discipline' })
        local said = told(s)
        local ref = refOf(s, 'BOSS0001', 'RECRUIT1')
        eq(W.call('orgStrike', 11, { member = ref, kind = 'strike', reason = 'Late' }).err, 'org_no_power')
        W.allow(s, 3, 'M11')
        eq(W.call('orgStrike', 11, { member = ref, kind = 'strike', reason = '' }).err, 'invalid_input', 'a reason')
        eq(W.call('orgStrike', 11, { member = ref, kind = 'ban', reason = 'x' }).err, 'invalid_input')
        eq(W.call('orgStrike', 11, { member = ref, kind = 'strike', reason = 'Late to the meet' }).ok, true)
        eq(W.call('orgStrike', 11, { member = ref, kind = 'warning', reason = 'Loud in public' }).ok, true)
        truthy(said.RECRUIT1 and said.RECRUIT1[1]:find('Late to the meet', 1, true), 'told')
        local mine = W.call('orgMine', 13, {}).data.discipline
        eq(mine.strikes, 1)
        eq(mine.warnings, 1)
        eq(#mine.rows, 2)
        eq(mine.rows[1].by, 'A boss', 'never which boss')
        eq(W.call('orgDisciplineRecord', 13, {}).data.strikes, 1, 'their own')
        eq(W.call('orgDisciplineRecord', 13, { member = refOf(s, 'RECRUIT1', 'LIEUT001') }).err, 'org_no_power')
        -- Never on themselves or at or above their rank.
        W.allow(s, 2, 'M11')
        eq(W.call('orgStrike', 12, { member = refOf(s, 'LIEUT001', 'BOSS0001'), kind = 'strike', reason = 'x' }).err,
            'org_rank')
        eq(W.call('orgStrike', 11, { member = refOf(s, 'BOSS0001', 'BOSS0001'), kind = 'strike', reason = 'x' }).err,
            'org_self')
        eq(#W.audit('org_strike'), 1)
        eq(#W.audit('org_warning'), 1)
    end)

    it('holds a boss to StrikesPerDay', function()
        local s, _, org = world({ 'Discipline' })
        W.allow(s, 3, 'M11')
        truthy(s.org.setLimits(W.STAFF, { StrikesPerDay = 2 }))
        local ref = refOf(s, 'BOSS0001', 'LIEUT001')
        for _ = 1, 2 do eq(W.call('orgStrike', 11, { member = ref, kind = 'warning', reason = 'x' }).ok, true) end
        eq(W.call('orgStrike', 11, { member = ref, kind = 'warning', reason = 'x' }).err, 'org_limit')
        eq(W.ask(6, 'orgStrike', { subject = 'LIEUT001', kind = 'warning', reason = 'x' }).ok, true, 'staff are not')
        eq(#org.settings.discipline.LIEUT001, 3)
    end)

    it('bars from contracts at the mark, decays, and only staff overturn', function()
        local s, f, org = world({ 'Discipline' }, { StrikeSuspendAt = 2, StrikeSuspendHours = 10 })
        W.allow(s, 3, 'M11')
        local ref = refOf(s, 'BOSS0001', 'RECRUIT1')
        eq(W.call('orgStrike', 11, { member = ref, kind = 'strike', reason = 'One' }).ok, true)
        eq(org.members.RECRUIT1.suspended_until, nil)
        local second = W.call('orgStrike', 11, { member = ref, kind = 'strike', reason = 'Two' })
        eq(second.data.consequence, 'suspended 10 h')
        truthy(org.members.RECRUIT1.suspended_until > os.time())
        local c = W.place(s, f.creator)
        eq(select(2, s.contracts.accept(s.identity.resolve(13), c.id)), CH.ERR.SUSPENDED, 'barred from contracts')
        eq(select(2, s.org.overturn(BOSS, 'RECRUIT1', second.data.id, 'x')), 'org_no_power', 'a boss never')
        local id = W.call('orgDisciplineRecord', 13, {}).data.rows[1].id
        eq(W.ask(6, 'orgOverturn', { subject = 'RECRUIT1', id = id, reason = 'Wrong member' }).ok, true)
        eq(org.members.RECRUIT1.suspended_until, nil, 'the bar the strikes made lifted')
        eq(W.ask(6, 'orgOverturn', { subject = 'RECRUIT1', id = id, reason = 'again' }).err, 'org_already')
        truthy(s.contracts.accept(s.identity.resolve(13), c.id))
        local rows = W.call('orgDisciplineRecord', 13, {}).data.rows
        eq(rows[1].overturned, true, 'kept on the record, marked')
        eq(W.call('orgDisciplineRecord', 13, {}).data.strikes, 1)
        Env.advance(31 * 86400)
        eq(W.call('orgDisciplineRecord', 13, {}).data.strikes, 0, 'decayed after StrikeDecayDays')
        eq(#W.audit('org_discipline_overturned'), 1)
    end)

    it('moves a member a role down at StrikeDemoteAt, never the last boss', function()
        local s, _, org = world({ 'Discipline' }, { StrikeDemoteAt = 2, StrikeSuspendAt = 0 })
        for _ = 1, 2 do truthy(s.org.discipline(W.STAFF, 'LIEUT001', 'strike', 'x')) end
        eq(org.members.LIEUT001.grade, 1, 'one role down')
        for _ = 1, 2 do truthy(s.org.discipline(W.STAFF, 'BOSS0001', 'strike', 'x')) end
        eq(org.members.BOSS0001.grade, 3, 'the only top boss stays')
    end)
end)

describe('R13: recruitment', function()
    local function recruiting(extra)
        local opts = { ApplyAtSignupOnly = false }
        for k, v in pairs(extra or {}) do opts[k] = v end
        return world({ 'Recruitment' }, opts)
    end

    it('lets a boss holding N4 set the form an applicant answers', function()
        local s = recruiting()
        eq(W.call('orgRecruitForm', 11, { questions = { 'Why us?' } }).err, 'org_no_power')
        W.allow(s, 3, 'N4')
        eq(W.call('orgRecruitForm', 11, { questions = { 'a', 'b', 'c', 'd', 'e', 'f' } }).err, 'org_bounds')
        eq(W.call('orgRecruitForm', 11, { questions = { '<b>Why</b>' } }).err, 'invalid_input')
        eq(W.call('orgRecruitForm', 11, { questions = { 'Why us?', 'Who vouches for you?' } }).ok, true)
        local outside = W.call('orgMine', 3, {}).data
        eq(#outside.form, 2)
        eq(outside.form[1], 'Why us?')
        eq(W.call('orgApply', 3, { text = 'Hi' }).err, 'invalid_input', 'every question answered')
        eq(W.call('orgApply', 3, { answers = { 'Money', 'see http://x.y' } }).err, 'invalid_input', 'no links')
        eq(W.call('orgApply', 3, { text = 'Hi', answers = { 'Money', 'Reyes' } }).ok, true)
        eq(#W.audit('org_recruit_form'), 1)
    end)

    it('shows a boss the answers, takes an interview note, and hires or declines as before', function()
        local s, _, org = recruiting()
        truthy(s.org.recruitForm(W.STAFF, { 'Why us?' }))
        eq(W.call('orgApply', 3, { answers = { 'The pay' } }).ok, true)
        W.allow(s, 3, 'N2')
        local apps = W.call('orgApplications', 11, {}).data.rows
        eq(apps[1].form[1].q, 'Why us?')
        eq(apps[1].form[1].a, 'The pay')
        eq(W.call('orgInterviewNote', 11, { id = apps[1].id, text = 'Calm. Knows the docks.' }).ok, true)
        eq(W.call('orgApplications', 11, {}).data.rows[1].note.text, 'Calm. Knows the docks.')
        eq(W.call('orgDecide', 11, { id = apps[1].id, accept = true }).ok, true, 'hired through the flow')
        truthy(org.members[s.identity.resolve(3).cid], 'a member now')
        eq(next(org.settings.recruit.notes), nil, 'the note went with the decision')
        eq(#W.audit('org_interview_note'), 1)
    end)

    it('makes a declined applicant wait, and caps applications an hour', function()
        local s, _, org = recruiting({ RecruitCooldownHours = 2, RecruitPerHour = 2 })
        local said = told(s)
        eq(W.call('orgApply', 3, { text = 'Me' }).ok, true)
        local _, _, apps = s.org.applications(W.STAFF)
        truthy(s.org.decide(W.STAFF, apps.rows[1].id, false))
        local cid = s.identity.resolve(3).cid
        truthy(said[cid] and said[cid][1]:find('declined', 1, true), 'told')
        local again = W.call('orgApply', 3, { text = 'Me again' })
        eq(again.err, 'org_cooldown')
        truthy(again.data.retryAfter > 0)
        eq(W.call('orgMine', 3, {}).data.cooldownUntil ~= nil, true, 'the tab says when')
        Env.advance(2 * 3600 + 1)
        eq(W.call('orgApply', 3, { text = 'Me again' }).ok, true)
        eq(W.call('orgApply', 2, { text = 'Me too' }).ok, true)
        W.player(20, 'SPAM0001')
        eq(W.call('orgApply', 20, { text = 'And me' }).err, 'org_cooldown', 'two an hour at most')
        truthy(org.applications)
    end)

    it('lets staff set the form and write notes from the panel', function()
        local s = recruiting()
        eq(W.ask(6, 'orgRecruitForm', { questions = { 'Why?' } }).ok, true)
        eq(W.call('orgApply', 3, { answers = { 'Because' } }).ok, true)
        local _, _, apps = s.org.applications(W.STAFF)
        eq(W.ask(6, 'orgInterviewNote', { id = apps.rows[1].id, text = 'Fine' }).ok, true)
        eq(W.ask(6, 'orgInterviewNote', { id = apps.rows[1].id, clear = true }).ok, true)
        eq(W.ask(6, 'orgGet', {}).data.extras2.form[1], 'Why?')
    end)
end)

describe('hostile payloads with every extra 2 on', function()
    local HOSTILE = { 'x', 12, true, {}, { slot = {} }, { slot = 'one', count = 1 }, { slot = 1, count = -1 },
        { slot = 1, count = 1.5 }, { slot = 1, count = 1e309 }, { slot = 0 / 0, count = 1 }, { count = {} },
        { grade = {}, count = 1 }, { grade = 0, count = 5000 }, { member = {} }, { member = 12 },
        { kind = {}, reason = 'x' }, { kind = 'strike', reason = ('w'):rep(9000) }, { kind = 'strike', reason = {} },
        { questions = 'q' }, { questions = { {}, 1, true } }, { questions = { ('q'):rep(900) } },
        { id = {}, text = 'x' }, { id = ('i'):rep(500) }, { id = 'app:x', text = '<script>' }, { clear = 'yes' },
        { item = {}, count = 1 }, { item = 'weapon_rifle', count = 1 }, { remove = true, slot = 99, count = 1 },
        { answers = 'a' }, { answers = { {}, 2 } } }

    it('answers every new phone request and staff op, never raising, nothing moved', function()
        local s, _, org = world(SWITCHES, { ArmoryItems = { 'lockpick' }, ArmoryAtOffice = false,
            ApplyAtSignupOnly = false })
        Env.players[11]._inventory = { { name = 'lockpick', count = 3, slot = 1 } }
        truthy(s.org.recruitForm(W.STAFF, { 'Why?' }))
        for _, p in ipairs(require('server.org.powers').LIST) do W.allow(s, 3, p.code) end
        local reads = { orgArmory = true, orgStats = true, orgDisciplineRecord = true }
        for _, name in ipairs({ 'orgArmory', 'orgArmoryPut', 'orgArmoryTake', 'orgArmoryLimit', 'orgStats',
            'orgStrike', 'orgDisciplineRecord', 'orgRecruitForm', 'orgInterviewNote', 'orgApply' }) do
            for i, payload in ipairs(HOSTILE) do
                local reply = W.call(name, name == 'orgApply' and 3 or 11, payload)
                truthy(reply, name .. ' answered ' .. i)
                truthy(reply.err ~= CH.ERR.SERVER_ERROR, name .. ' did not raise on ' .. i)
                if not reads[name] then falsy(reply.ok, name .. ' refused ' .. i) end
            end
        end
        for _, op in ipairs({ 'orgArmoryGet', 'orgArmoryLimit', 'orgArmoryStock', 'orgStatsGet', 'orgStatsReset',
            'orgStrike', 'orgOverturn', 'orgRecruitForm', 'orgInterviewNote' }) do
            for i, payload in ipairs(HOSTILE) do
                local reply = W.ask(6, op, type(payload) == 'table' and payload or { value = payload })
                truthy(reply, op .. ' answered ' .. i)
                truthy(reply.err ~= CH.ERR.SERVER_ERROR, op .. ' did not raise on ' .. i)
                if op ~= 'orgArmoryGet' and op ~= 'orgStatsGet' then falsy(reply.ok, op .. ' refused ' .. i) end
            end
        end
        eq(held(11, 'lockpick'), 3, 'nothing moved')
        eq(next(org.settings.discipline), nil, 'no strike given')
        eq(next(org.applications), nil, 'no application taken')
        eq(org.settings.recruit.questions[1], 'Why?', 'the form unchanged')
    end)
end)
