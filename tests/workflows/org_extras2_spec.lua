--- Step 7 workflows: the organisation extras 2 (server/org/extras2.lua),
--- each switched on from config, driven through the real page callbacks
--- and the real client (the boss and the members on their phones) and the
--- panel's ops (staff): the armory stocked, filled, limited and drawn from;
--- the record counted from a real accept walked away from, and the
--- leaderboard read and reset; strikes and warnings given and overturned;
--- the application form set, answered, noted and decided. Every request
--- answers ok and leaves what it says, on the record.

local W = require('tests.workflows.lib')
W.ran.orgExtras2 = true

local EXPECTED_FAIL = {
}

local function it_(name, fn) W.it(name, fn, EXPECTED_FAIL) end

local C = W.CAST
local BOSS, RECRUIT, HITMAN, OUTSIDER = C.boss.source, C.hitman2.source, C.hitman.source, C.broker.source

local function tap(name, payload, why)
    local answer, answered = W.nui('crimson:' .. name, payload or {})
    truthy(answered, name .. ' never answered')
    if not (type(answer) == 'table' and answer.ok) then
        error(('%s refused: %s %s (%s)'):format(name, tostring(answer and answer.err),
            tostring(answer and answer.data and answer.data.message), tostring(why or '')), 2)
    end
    return answer.data
end

--- The organisation set up by staff with every extra 2 on, the boss holding
--- every power at the office, and two members hired by invite.
local function org()
    W.boot('memory', 'test', function()
        Config.Organisation.Enabled = true
        for _, key in ipairs({ 'Armory', 'Stats', 'Discipline', 'Recruitment' }) do
            Config.Organisation[key] = true
        end
        Config.Organisation.ArmoryItems = { 'lockpick' }
        Config.Organisation.ApplyAtSignupOnly = false
        Config.Integrations.Banking = 'none'
    end)
    W.cast(W.s)
    local staff = C.staff.source
    W.allAt()
    W.opOk(staff, 'orgSetup', {}, 'set up')
    W.opOk(staff, 'orgMemberHire', { subject = C.boss.cid, grade = 3 }, 'hire the boss')
    local cells = {}
    for _, p in ipairs(require('server.org.powers').LIST) do
        cells[#cells + 1] = { subject = 'role', id = 3, power = p.code, state = 'allow' }
    end
    W.opOk(staff, 'bossPermsSet', { cells = cells }, 'the boss role holds every power')
    W.opOk(staff, 'placeSet', { kind = 'office', here = true, label = 'Back room' }, 'the office')
    W.tick(1)
    for _, who in ipairs({ { RECRUIT, C.hitman2.cid }, { HITMAN, C.hitman.cid } }) do
        W.client(BOSS)
        tap('orgHire', { target = who[1], grade = 0 }, 'hire ' .. who[2])
        W.client(who[1])
        tap('orgInviteAnswer', { id = tap('orgMine', {}).invite.id, accept = true })
    end
    return W.s.org.current()
end

--- The boss's handle for a member, from the roster.
local function memberRef(cid)
    W.client(BOSS)
    local m = W.s.org.current().members[cid]
    for _, r in ipairs(tap('orgMembers', {}).rows or {}) do
        if r.name == (m.codename or m.name) then return r.ref end
    end
    error('no row for ' .. cid)
end

local function lockpicks(src)
    local n = 0
    for _, slot in ipairs(Env.players[src]._inventory) do if slot.name == 'lockpick' then n = n + slot.count end end
    return n
end

describe('organisation extras 2 from the phone and the panel', function()
    it_('the armory: stocked by staff, filled by a member, limited by the boss, drawn from', function()
        local o = org()
        local staff = C.staff.source
        W.opOk(staff, 'orgArmoryStock', { item = 'lockpick', count = 3 }, 'staff stock it')
        W.client(RECRUIT)
        local view = tap('orgArmory', {})
        eq(view.own[1].name, 'lockpick', 'their own allowed item offered')
        tap('orgArmoryPut', { slot = view.own[1].slot, count = 2 })
        eq(lockpicks(RECRUIT), 0, 'put in')
        W.client(BOSS)
        tap('orgArmoryLimit', { grade = 0, count = 1 })
        W.client(HITMAN)
        local stock = tap('orgArmory', {}).items
        tap('orgArmoryTake', { slot = stock[1].slot, count = 1 })
        eq(lockpicks(HITMAN), 3, 'taken out')
        local again = W.nui('crimson:orgArmoryTake', { slot = stock[1].slot, count = 1 })
        eq(again and again.err, 'org_limit', 'the role\'s limit a day')
        local got = W.opOk(staff, 'orgArmoryGet', {}, 'staff read it')
        local items = got and got.items or W.s.org.staffView(C.staff.cid).extras2.armory.items
        W.opOk(staff, 'orgArmoryStock', { remove = true, slot = items[1].slot, count = 1 }, 'staff take one out')
        W.opOk(staff, 'orgArmoryLimit', { grade = 0, count = 0 }, 'staff set it back to none')
        eq(#o.settings.armory.log, 4, 'every move in the log')
        for _, action in ipairs({ 'org_armory_stocked', 'org_armory_deposit', 'org_armory_limit',
            'org_armory_withdraw', 'org_armory_removed' }) do
            truthy(#W.audit(action) >= 1, 'audited ' .. action)
        end
    end)

    it_('the record: a walk-away counted, the leaderboard read, staff reset it', function()
        local o = org()
        local staff = C.staff.source
        local c, err = W.s.contracts.create(W.s.identity.resolve(C.creator.source), { targetCid = C.target.cid,
            reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        truthy(c, 'a contract: ' .. tostring(err))
        W.client(RECRUIT)
        local accepted = W.nui('crimson:accept', { id = c.id, shown = { orgCut = 0 } })
        truthy(accepted and accepted.ok, 'accepted: ' .. tostring(accepted and accepted.err))
        Env.advance(120)
        tap('abandon', { id = c.id })
        eq(o.settings.stats[C.hitman2.cid].f, 1, 'counted as a failure in the organisation')
        W.s.record.onCompleted(C.hitman.cid, CH.FULFILMENT.ELIMINATION, nil, { earned = 4000, seconds = 1500 })
        local mine = tap('orgMine', {})
        eq(mine.stats.failed, 1, 'Your record')
        local board = tap('orgStats', {})
        eq(board.rows[1].completed, 1, 'the leaderboard by completions')
        eq(board.rows[1].earned, nil, 'no money for a player')
        W.client(BOSS)
        eq(tap('orgStats', {}).rows[1].earned, 4000, 'the numbers for M10')
        local all = W.opOk(staff, 'orgStatsGet', {}, 'staff read it')
        truthy(all == nil or all.rows[1].avgMinutes == 25, 'staff see the minutes')
        W.opOk(staff, 'orgStatsReset', { subject = C.hitman.cid }, 'reset one')
        W.opOk(staff, 'orgStatsReset', { all = true }, 'reset all')
        eq(next(o.settings.stats), nil)
        truthy(#W.audit('org_stats_reset') >= 2, 'audited')
    end)

    it_('discipline: a strike and a warning given, read by the member, one overturned by staff', function()
        local o = org()
        local staff = C.staff.source
        local ref = memberRef(C.hitman2.cid)
        tap('orgStrike', { member = ref, kind = 'strike', reason = 'Late to the meet' })
        W.opOk(staff, 'orgStrike', { subject = C.hitman2.cid, kind = 'warning', reason = 'Loud in public' },
            'staff warn')
        W.client(RECRUIT)
        local record = tap('orgDisciplineRecord', {})
        eq(record.strikes, 1)
        eq(#record.rows, 2)
        truthy(W.has(W.notices(RECRUIT), 'Late to the meet'), 'told')
        W.client(BOSS)
        eq(#tap('orgDisciplineRecord', { member = ref }).rows, 2, 'the boss reads it')
        local strike
        for _, e in ipairs(o.settings.discipline[C.hitman2.cid]) do if e.kind == 'strike' then strike = e.id end end
        W.opOk(staff, 'orgOverturn', { subject = C.hitman2.cid, id = strike, reason = 'Wrong member' }, 'overturn')
        eq(W.s.org.Extras2.strikes(o, C.hitman2.cid), 0, 'no longer counted')
        for _, action in ipairs({ 'org_strike', 'org_warning', 'org_discipline_overturned' }) do
            truthy(#W.audit(action) >= 1, 'audited ' .. action)
        end
    end)

    it_('recruitment: the form set, answered, noted, and the applicant hired', function()
        local o = org()
        local staff = C.staff.source
        W.client(BOSS)
        tap('orgRecruitForm', { questions = { 'Why us?' } })
        W.opOk(staff, 'orgRecruitForm', { questions = { 'Why us?', 'Who vouches for you?' } }, 'staff add one')
        W.client(OUTSIDER)
        local outside = tap('orgMine', {})
        eq(#outside.form, 2, 'the form to answer')
        tap('orgApply', { answers = { 'The pay', 'Bea' } })
        W.client(BOSS)
        local apps = tap('orgApplications', {}).rows
        eq(apps[1].form[2].a, 'Bea', 'the answers read')
        tap('orgInterviewNote', { id = apps[1].id, text = 'Calm. Knows the docks.' })
        W.opOk(staff, 'orgInterviewNote', { id = apps[1].id, text = 'Checked: no record.' }, 'staff note')
        tap('orgDecide', { id = apps[1].id, accept = true })
        truthy(o.members[C.broker.cid], 'hired through the application flow')
        for _, action in ipairs({ 'org_recruit_form', 'org_interview_note', 'org_application' }) do
            truthy(#W.audit(action) >= 1, 'audited ' .. action)
        end
    end)
end)
