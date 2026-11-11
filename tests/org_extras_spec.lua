--- Organisation extras 1 (server/org/extras.lua, plan R2-R5, R7, R8), each
--- its own switch under Config.Organisation, off as shipped:
---
---   * off: nothing reserved, nothing asked of the store, no field on the
---     tab, every request refused in words, the accept as before;
---   * R2 contracts to the organisation: placed as any other, held off the
---     open board for the member a boss assigns (K4, K5), on the open board
---     once nobody took it in time; the placer never shown to the org;
---   * R3 accept approval: an accept above the value waits, nothing taken;
---     approved it runs, refused or run out nothing was taken;
---   * R4 probation: small and unstaked contracts only, until the
---     completions or a sign-off (M8);
---   * R5 duty: only members on duty are assigned, see and take them; qbx
---     told and listened to; M9 sends one off duty;
---   * R7 the channel: plain text, rate limited, muted and moderated (N3),
---     kept the retention days;
---   * R8 dossiers: on assigned contracts only, to their member only, never
---     a citizen id.

local W = require('tests.harness.org_world')

local BOSS = W.boss(11, 'BOSS0001')
local LIEUT = W.boss(12, 'LIEUT001')
local RECRUIT = { cid = 'RECRUIT1', source = 13, name = 'P13' }
local SWITCHES = { 'OrgContracts', 'AcceptApproval', 'Probation', 'Duty', 'Channel', 'Dossiers' }

local function world(on, extra)
    local s, f = W.world({ configure = function()
        for _, key in ipairs(on or {}) do Config.Organisation[key] = true end
        for k, v in pairs(extra or {}) do Config.Organisation[k] = v end
    end })
    W.crew(s)
    return s, f, s.org.current()
end

local function listed(src, id)
    local reply = W.call('list', src, {})
    for _, c in ipairs(reply and reply.data and reply.data.contracts or {}) do
        if c.id == id then return true end
    end
    return false
end

local function refOf(s, viewer, cid)
    return s.org.refFor(viewer, cid)
end

local function handleFor(s, query)
    local found = s.app.handlers.searchTargets(s.identity.resolve(1), { query = query })
    return found and found[1] and found[1].handle
end

describe('organisation extras switched off (as shipped)', function()
    it('ships every switch off', function()
        resetConfig()
        for _, key in ipairs(SWITCHES) do eq(Config.Organisation[key], false, key) end
    end)

    it('reserves nothing, adds nothing to the tab and refuses every request in words', function()
        local s, f, org = world()
        local c = W.place(s, f.creator)
        eq(s.org.receiveContract(c.id, 'CREATOR1'), false, 'nothing held while off')
        eq(s.projection.reserved, nil, 'the board pays nothing')
        local mine = W.call('orgMine', 13, {}).data
        for _, key in ipairs({ 'duty', 'dutyOn', 'probation', 'probationOn', 'assigned', 'orgContracts', 'channel',
            'approval', 'waiting' }) do
            eq(mine[key], nil, key .. ' not on the tab')
        end
        for _, p in ipairs(require('server.org.powers').LIST) do W.allow(s, 3, p.code) end
        for _, name in ipairs({ 'orgWork', 'orgDuty', 'orgChannel', 'orgChannelPost', 'orgDossier', 'orgAssign',
            'orgRelease', 'orgApprove', 'orgProbationEnd', 'orgForceOff', 'orgChannelRemove', 'orgChannelMute' }) do
            local reply = W.call(name, 11, { on = true, text = 'hi', id = c.id, member = refOf(s, 'BOSS0001', 'RECRUIT1'),
                approve = true, hours = 1 })
            falsy(reply.ok, name .. ' refused')
            truthy(reply.data and reply.data.message, name .. ' says why')
        end
        -- The accept as before: nothing waits, nothing is held.
        truthy(s.contracts.accept(f.hitman, c.id))
        eq(next(org.settings.orgContracts), nil)
    end)

    it('asks the store nothing on a tick while off', function()
        local s = world()
        local calls = 0
        local storage = s.storage
        local saved = {}
        for name, fn in pairs(storage) do
            if type(fn) == 'function' then
                saved[name] = fn
                storage[name] = function(...) calls = calls + 1 return fn(...) end
            end
        end
        for i = 1, 20 do s.org.extrasTick(os.time() + i * 60) end
        for name, fn in pairs(saved) do storage[name] = fn end
        eq(calls, 0, 'no store call')
    end)

    it('refuses Send to the organisation before anything is placed or charged', function()
        local s = world()
        local handle = handleFor(s, 'Reyes')
        truthy(handle)
        local before = W.wealth(1)
        local reply = W.call('create', 1, { target = handle, reason = 'x', toOrg = true,
            reward = { slots = { { baseline = { cash = 1000 } } } }, shown = {} })
        eq(reply.ok, false)
        eq(reply.err, 'org_feature_off')
        eq(W.wealth(1), before, 'nothing taken')
    end)
end)

describe('R2: contracts sent to the organisation', function()
    it('is placed from the form, held off the open board, and the placer never shown', function()
        local s, _, org = world({ 'OrgContracts' })
        local handle = handleFor(s, 'Reyes')
        local reply = W.call('create', 1, { target = handle, reason = 'x', toOrg = true, anonymous = false,
            reward = { slots = { { baseline = { cash = 2000 } } } }, shown = {} })
        eq(reply.ok, true, tostring(reply.err))
        eq(reply.data.sentToOrg, true)
        local id = reply.data.id
        eq(org.settings.orgContracts[id].state, 'waiting')
        falsy(listed(3, id), 'not on the open board for a stranger')
        falsy(listed(13, id), 'nor for a member before it is assigned')
        W.allow(s, 3, 'K4')
        local work = W.call('orgWork', 11, {})
        eq(work.ok, true, tostring(work.err))
        local function scan(v)
            if type(v) == 'string' then
                truthy(v ~= 'CREATOR1' and not v:find('Marlowe'), 'never the placer: ' .. v)
            elseif type(v) == 'table' then
                for k, x in pairs(v) do
                    falsy(tostring(k):find('creator'), 'no creator field')
                    scan(x)
                end
            end
        end
        scan(work.data)
        eq(work.data.contracts[1].targetName ~= nil, true, 'what a board card shows')
        -- The board's settings say it may be sent.
        truthy(W.call('list', 1, {}).data.settings.orgContracts, 'offered on the form')
    end)

    it('is shown and taken only by the member assigned; others are refused', function()
        local s, f, org = world({ 'OrgContracts' })
        local c = W.place(s, f.creator)
        truthy(s.org.receiveContract(c.id, 'CREATOR1'))
        W.allow(s, 3, 'K4')
        eq(select(2, s.org.assignContract(LIEUT, c.id, 'RECRUIT1')), 'org_no_power', 'K4 only')
        truthy(s.org.assignContract(BOSS, c.id, 'RECRUIT1'))
        eq(select(2, s.org.assignContract(BOSS, c.id, 'LIEUT001')), 'org_no_power', 'moving it needs K5')
        truthy(listed(13, c.id), 'the assignee sees it')
        falsy(listed(12, c.id), 'another member does not')
        falsy(listed(3, c.id), 'nor a stranger')
        local refused, err = s.contracts.accept(f.hitman, c.id)
        falsy(refused)
        eq(err, 'org_reserved')
        local recruit = s.identity.resolve(13)
        truthy(s.contracts.accept(recruit, c.id))
        eq(org.settings.orgContracts[c.id].state, 'taken')
        W.allow(s, 3, 'K5')
        eq(select(2, s.org.releaseContract(BOSS, c.id)), 'org_not_found', 'a taken one stays with its member')
    end)

    it('goes on the open board when nobody assigns it, or the member does not take it, in time', function()
        local s, f, org = world({ 'OrgContracts' }, { AssignMinutes = 5 })
        local c = W.place(s, f.creator)
        truthy(s.org.receiveContract(c.id, 'CREATOR1'))
        s.org.extrasTick(os.time() + 4 * 60)
        truthy(org.settings.orgContracts[c.id], 'still held inside the window')
        s.org.extrasTick(os.time() + 6 * 60)
        eq(org.settings.orgContracts[c.id], nil, 'released')
        truthy(listed(3, c.id), 'on the open board')
        -- Assigned and not taken: the same.
        local c2 = W.place(s, f.creator, 'READER01')
        truthy(s.org.receiveContract(c2.id, 'CREATOR1'))
        truthy(s.org.assignContract(W.STAFF, c2.id, 'RECRUIT1'))
        s.org.extrasTick(os.time() + 20 * 60)
        eq(org.settings.orgContracts[c2.id], nil)
        s.audit.flush()
        truthy(#s.storage.auditByAction('org_contract_released', 5) >= 1, 'on the record')
    end)

    it('lets a boss with K5 move it or send it to the open board, and staff do either', function()
        local s, f, org = world({ 'OrgContracts' })
        local c = W.place(s, f.creator)
        truthy(s.org.receiveContract(c.id, 'CREATOR1'))
        W.allow(s, 3, 'K4')
        W.allow(s, 3, 'K5')
        truthy(s.org.assignContract(BOSS, c.id, 'RECRUIT1'))
        truthy(s.org.assignContract(BOSS, c.id, 'LIEUT001'))
        eq(org.settings.orgContracts[c.id].cid, 'LIEUT001')
        truthy(s.org.releaseContract(BOSS, c.id))
        truthy(listed(3, c.id))
        local c2 = W.place(s, f.creator, 'READER01')
        truthy(s.org.receiveContract(c2.id, 'CREATOR1'))
        local member = refOf(s, 'ADMIN001', 'RECRUIT1')
        eq(W.ask(6, 'orgContractAssign', { id = c2.id, member = member }).ok, true)
        eq(org.settings.orgContracts[c2.id].cid, 'RECRUIT1')
        eq(W.ask(6, 'orgContractAssign', { id = c2.id, release = true }).ok, true)
        eq(org.settings.orgContracts[c2.id], nil)
    end)

    it('goes on the open board when the member it is assigned to leaves', function()
        local s, f, org = world({ 'OrgContracts' })
        local c = W.place(s, f.creator)
        truthy(s.org.receiveContract(c.id, 'CREATOR1'))
        truthy(s.org.assignContract(W.STAFF, c.id, 'RECRUIT1'))
        truthy(s.org.fire(W.STAFF, 'RECRUIT1', 'gone'))
        s.org.extrasTick(os.time() + 60)
        eq(org.settings.orgContracts[c.id], nil)
        truthy(listed(3, c.id))
    end)

    it('goes on the open board the moment the switch is off', function()
        local s, f, org = world({ 'OrgContracts' })
        local c = W.place(s, f.creator)
        truthy(s.org.receiveContract(c.id, 'CREATOR1'))
        Config.Organisation.OrgContracts = false
        s.org.Extras.rebuild()
        truthy(listed(3, c.id), 'shown at once')
        s.org.extrasTick(os.time() + 60)
        eq(next(org.settings.orgContracts), nil, 'and forgotten at the tick')
    end)
end)

describe('R3: accepts that wait for approval', function()
    local function setup(extra)
        local s, f, org = world({ 'AcceptApproval' }, extra or { ApprovalAbove = 1000 })
        W.allow(s, 3, 'K6')
        return s, f, org
    end

    it('holds an accept above the value, nothing taken, and runs it once approved', function()
        local s, f = setup()
        local c = W.place(s, f.creator, nil, { penaltyAmount = 500 })
        local recruit = s.identity.resolve(13)
        local before = W.wealth(13)
        local ok, err, data = s.contracts.accept(recruit, c.id)
        falsy(ok)
        eq(err, 'org_approval')
        truthy(data and data.pending and data.message)
        eq(W.wealth(13), before, 'no stake taken while it waits')
        eq(s.storage.readHitman(c.id, 'RECRUIT1'), nil, 'not on it')
        local mine = W.call('orgMine', 13, {}).data
        eq(#mine.waiting, 1, 'the member sees it waiting')
        local work = W.call('orgWork', 11, {}).data
        eq(#work.approvals, 1)
        local reply = W.call('orgApprove', 11, { id = work.approvals[1].id, approve = true })
        eq(reply.ok, true, tostring(reply.err) .. ' ' .. tostring(reply.data and reply.data.message))
        local h = s.storage.readHitman(c.id, 'RECRUIT1')
        eq(h and h.state, 'active', 'the accept ran')
    end)

    it('lets a cheaper accept through, and refuses or lets one run out with nothing taken', function()
        local s, f, org = setup()
        local small = W.place(s, f.creator, nil, { reward = { baseline = { cash = 1000 } } })
        truthy(s.contracts.accept(s.identity.resolve(13), small.id), 'at the value: no wait')
        local big = W.place(s, f.creator, 'READER01')
        eq(select(2, s.contracts.accept(s.identity.resolve(12), big.id)), 'org_approval')
        local work = W.call('orgWork', 11, {}).data
        eq(W.call('orgApprove', 11, { id = work.approvals[1].id, approve = false }).ok, true)
        eq(s.storage.readHitman(big.id, 'LIEUT001'), nil, 'refused: never on it')
        eq(select(2, s.contracts.accept(s.identity.resolve(12), big.id)), 'org_approval', 'asked again')
        s.org.extrasTick(os.time() + 16 * 60)
        eq(#W.call('orgWork', 11, {}).data.approvals, 0, 'ran out')
        s.audit.flush()
        truthy(#s.storage.auditByAction('org_accept_expired', 5) == 1)
        local _ = org
    end)

    it('never lets a boss approve their own, nor one above them', function()
        local s, f = setup({ ApprovalAbove = 0 })
        W.allow(s, 2, 'K6')
        local c = W.place(s, f.creator)
        eq(select(2, s.contracts.accept(s.identity.resolve(11), c.id)), 'org_approval')
        local work = W.call('orgWork', 11, {}).data
        eq(work.approvals[1].own, true)
        eq(W.call('orgApprove', 11, { id = work.approvals[1].id, approve = true }).err, 'org_self')
        local lieut = W.call('orgWork', 12, {}).data
        eq(W.call('orgApprove', 12, { id = lieut.approvals[1].id, approve = true }).err, 'org_rank')
        eq(W.ask(6, 'orgAcceptDecide', { id = work.approvals[1].id, approve = false }).ok, true, 'staff may')
    end)

    it('never holds an acceptance staff make', function()
        local s, f = setup({ ApprovalAbove = 0 })
        local c = W.place(s, f.creator)
        local ok, err = s.contracts.accept(s.identity.resolve(13), c.id, false, { staffAssigned = true })
        truthy(ok, tostring(err))
    end)
end)

describe('R4: probation', function()
    it('holds a member at or below the grade to small, unstaked contracts until the completions', function()
        local s, f, org = world({ 'Probation' }, { ProbationMaxReward = 3000, ProbationCompletions = 2 })
        local recruit = s.identity.resolve(13)
        local big = W.place(s, f.creator)
        local ok, err, data = s.contracts.accept(recruit, big.id)
        falsy(ok)
        eq(err, 'org_probation')
        truthy(data.message:find('$3000', 1, true), data.message)
        local staked = W.place(s, f.creator, 'READER01', { reward = { baseline = { cash = 2000 } }, penaltyAmount = 100 })
        eq(select(2, s.contracts.accept(recruit, staked.id)), 'org_probation', 'no stake')
        -- A lieutenant (grade 2) is not on probation.
        truthy(s.contracts.accept(s.identity.resolve(12), big.id))
        local mine = W.call('orgMine', 13, {}).data
        eq(mine.probation.done, 0)
        eq(mine.probation.need, 2)
        s.storage.bumpStat('RECRUIT1', 'completed', 1)
        eq(W.call('orgMine', 13, {}).data.probation.done, 1, 'counted from when it began')
        s.storage.bumpStat('RECRUIT1', 'completed', 1)
        eq(W.call('orgMine', 13, {}).data.probation, nil, 'the completions done: it ends')
        eq(org.settings.probation.RECRUIT1.passed, 'record')
        truthy(s.contracts.accept(recruit, staked.id), 'and a staked one is open to them')
    end)

    it('is ended by a boss holding M8, below them, and staff put a member on it again', function()
        local s, _, org = world({ 'Probation' })
        local ref = refOf(s, 'BOSS0001', 'RECRUIT1')
        eq(W.call('orgProbationEnd', 11, { member = ref }).err, 'org_no_power')
        W.allow(s, 3, 'M8')
        eq(W.call('orgProbationEnd', 11, { member = ref }).ok, true)
        eq(org.settings.probation.RECRUIT1.passed, 'boss')
        eq(W.call('orgProbationEnd', 11, { member = ref }).err, 'org_already')
        eq(select(2, s.org.setProbation(BOSS, 'RECRUIT1', false)), 'invalid_input', 'only staff put one back')
        eq(W.ask(6, 'orgProbation', { member = refOf(s, 'ADMIN001', 'RECRUIT1'), passed = false }).ok, true)
        truthy(W.call('orgMine', 13, {}).data.probation, 'on it again')
    end)

    it('makes every accept on probation wait for approval, with both on', function()
        local s, f = world({ 'Probation', 'AcceptApproval' }, { ApprovalAbove = 1000000, ProbationMaxReward = 100000 })
        local c = W.place(s, f.creator)
        eq(select(2, s.contracts.accept(s.identity.resolve(13), c.id)), 'org_approval')
        truthy(s.contracts.accept(s.identity.resolve(12), c.id), 'off probation, under the value')
    end)
end)

describe('R5: duty', function()
    it('assigns, shows and lets take an organisation contract only on duty', function()
        local s, f, org = world({ 'OrgContracts', 'Duty' })
        local c = W.place(s, f.creator)
        truthy(s.org.receiveContract(c.id, 'CREATOR1'))
        eq(select(2, s.org.assignContract(W.STAFF, c.id, 'RECRUIT1')), 'org_off_duty')
        eq(W.call('orgDuty', 13, { on = true }).ok, true)
        truthy(s.org.assignContract(W.STAFF, c.id, 'RECRUIT1'))
        truthy(listed(13, c.id))
        eq(#W.call('orgMine', 13, {}).data.assigned, 1)
        eq(W.call('orgDuty', 13, { on = false }).ok, true)
        falsy(listed(13, c.id), 'off duty: hidden')
        eq(W.call('orgMine', 13, {}).data.assigned, nil)
        eq(select(2, s.contracts.accept(s.identity.resolve(13), c.id)), 'org_off_duty')
        eq(W.call('orgDuty', 13, { on = true }).ok, true)
        truthy(s.contracts.accept(s.identity.resolve(13), c.id))
        local _ = org
    end)

    it('tells qbx_core where the job is the primary one, and takes in its duty changes', function()
        local s = world({ 'Duty' })
        local core = W.QbxJobs
        local qbx = require('tests.harness.natives').exportTables['qbx_core']
        truthy(qbx.SetPlayerPrimaryJob(nil, 'RECRUIT1', 'hitman'))
        Env.players[13].PlayerData.job.onduty = false
        core.calls = {}
        eq(W.call('orgDuty', 13, { on = true }).ok, true)
        eq(Env.players[13].PlayerData.job.onduty, true, 'qbx told')
        qbx.SetJobDuty(nil, 13, false)
        eq(W.call('orgMine', 13, {}).data.duty.on, false, 'a qbx duty point taken in')
        qbx.SetJobDuty(nil, 13, true)
        eq(W.call('orgMine', 13, {}).data.duty.on, true)
        -- Another job's duty is not the organisation's.
        eq(W.call('orgDuty', 12, { on = true }).ok, true)
        Env.players[12].PlayerData.job = { name = 'police', onduty = false }
        s.org.Extras.frameworkDuty(12, false)
        eq(s.org.Extras.onDuty('LIEUT001'), true, 'left as it was')
        local _ = s
    end)

    it('is sent off by a boss holding M9 below them, on duty at the office only where it says so', function()
        local s = world({ 'Duty' }, { DutyAtOffice = true })
        W.office(s)
        W.at(13, 500.0, 500.0)
        eq(W.call('orgDuty', 13, { on = true }).err, 'org_office')
        W.at(13, 100.0, 100.0)
        eq(W.call('orgDuty', 13, { on = true }).ok, true)
        local ref = refOf(s, 'BOSS0001', 'RECRUIT1')
        eq(W.call('orgForceOff', 11, { member = ref }).err, 'org_no_power')
        W.allow(s, 3, 'M9')
        eq(W.call('orgForceOff', 11, { member = ref }).ok, true)
        eq(W.call('orgMine', 13, {}).data.duty.on, false)
        eq(W.call('orgForceOff', 11, { member = ref }).err, 'org_already')
        W.at(11, 100.0, 100.0)
        eq(W.call('orgDuty', 11, { on = true }).ok, true)
        W.allow(s, 2, 'M9')
        eq(W.call('orgForceOff', 12, { member = refOf(s, 'LIEUT001', 'BOSS0001') }).err, 'org_rank')
        eq(W.ask(6, 'orgDutyOff', { member = refOf(s, 'ADMIN001', 'BOSS0001') }).ok, true, 'staff anybody')
    end)

    it('ends the duty of a player gone at the tick', function()
        local s = world({ 'Duty' })
        eq(W.call('orgDuty', 13, { on = true }).ok, true)
        Env.removePlayer(13)
        s.org.extrasTick(os.time() + 60)
        eq(s.org.Extras.onDuty('RECRUIT1'), false)
    end)
end)

describe('R7: the channel', function()
    it('posts plain text and reads it back, newest last, with who wrote it', function()
        local s = world({ 'Channel' })
        eq(W.call('orgChannelPost', 13, { text = '  Evening,   all. ' }).ok, true)
        eq(W.call('orgChannelPost', 12, { text = 'Evening.' }).ok, true)
        local rows = W.call('orgChannel', 13, {}).data.rows
        eq(#rows, 2)
        eq(rows[1].body, 'Evening, all.', 'spaces folded')
        eq(rows[1].mine, true)
        eq(rows[2].from, 'P12')
        eq(rows[2].member, nil, 'no handle without N3')
        eq(W.call('orgChannel', 3, {}).err, 'org_not_member')
        eq(W.call('orgChannelPost', 3, { text = 'hi' }).err, 'org_not_member')
        local _ = s
    end)

    it('refuses markup, links, empty and too long, never cut', function()
        world({ 'Channel' }, { ChannelMaxLength = 20 })
        for _, text in ipairs({ '<b>x</b>', 'see https://x.example', 'www.x.example', 'discord.gg/abc', '   ',
            string.rep('a', 21), 5, { 'x' } }) do
            local reply = W.call('orgChannelPost', 13, { text = text })
            eq(reply.ok, false, tostring(text))
            truthy(reply.data.message, 'worded')
        end
        eq(#W.call('orgChannel', 13, {}).data.rows, 0, 'nothing kept')
    end)

    it('holds each member to ChannelPerMinute', function()
        local s = world({ 'Channel' }, { ChannelPerMinute = 2 })
        eq(W.call('orgChannelPost', 13, { text = 'one' }).ok, true)
        eq(W.call('orgChannelPost', 13, { text = 'two' }).ok, true)
        eq(W.call('orgChannelPost', 13, { text = 'three' }).err, 'org_cooldown')
        eq(W.call('orgChannelPost', 12, { text = 'mine' }).ok, true, 'per member')
        local _ = s
    end)

    it('lets a boss holding N3 remove and mute below them, within the bound', function()
        local s = world({ 'Channel' })
        W.allow(s, 3, 'N3')
        W.allow(s, 2, 'N3')
        eq(W.call('orgChannelPost', 13, { text = 'rude words' }).ok, true)
        eq(W.call('orgChannelPost', 11, { text = 'from the boss' }).ok, true)
        local rows = W.call('orgChannel', 11, {}).data.rows
        truthy(rows[1].member, 'a handle to mute them by')
        eq(W.call('orgChannelRemove', 12, { id = rows[2].id }).err, 'org_rank', 'never one above')
        eq(W.call('orgChannelRemove', 11, { id = rows[1].id }).ok, true)
        eq(#W.call('orgChannel', 11, {}).data.rows, 1)
        eq(W.call('orgChannelMute', 11, { member = rows[1].member, hours = 999 }).err, 'invalid_input')
        eq(W.call('orgChannelMute', 11, { member = rows[1].member, hours = 48 }).err, 'org_bounds')
        eq(W.call('orgChannelMute', 11, { member = rows[1].member, hours = 2 }).ok, true)
        eq(W.call('orgChannelPost', 13, { text = 'again' }).err, 'org_locked')
        truthy(W.call('orgMine', 13, {}).data.channelMuted)
        eq(W.call('orgChannelMute', 11, { member = rows[1].member, hours = 0 }).ok, true)
        eq(W.call('orgChannelPost', 13, { text = 'again' }).ok, true)
        s.audit.flush()
        local post = s.storage.auditByAction('org_channel_post', 5)[1]
        eq(post.detail.length ~= nil, true)
        for _, v in pairs(post.detail) do truthy(v ~= 'again', 'never the words on the record') end
    end)

    it('lets staff read, post, remove and mute from the panel', function()
        local s = world({ 'Channel' })
        eq(W.call('orgChannelPost', 13, { text = 'hello' }).ok, true)
        eq(W.ask(6, 'orgChannelPost', { text = 'Staff here.' }).ok, true)
        local read = W.ask(6, 'orgChannelGet', {})
        eq(read.ok, true)
        eq(#read.data.rows, 2)
        eq(read.data.rows[2].from, 'Staff')
        eq(W.ask(6, 'orgChannelMute', { member = read.data.rows[1].member, hours = 100 }).ok, true, 'staff past the bound')
        eq(W.ask(6, 'orgChannelRemove', { id = read.data.rows[1].id }).ok, true)
        eq(#s.org.staffView('ADMIN001').extras.channel, 1)
    end)

    it('deletes messages older than the retention days', function()
        local s, _, org = world({ 'Channel' }, { ChannelRetentionDays = 1 })
        eq(W.call('orgChannelPost', 13, { text = 'old news' }).ok, true)
        eq(#s.storage.readOrgRows('messages', org.id), 1, 'kept in its table')
        s.org.extrasTick(os.time() + 2 * 86400)
        eq(#s.storage.readOrgRows('messages', org.id), 0, 'gone')
        eq(#W.call('orgChannel', 13, {}).data.rows, 0)
    end)
end)

describe('R8: dossiers', function()
    local function assigned()
        local s, f, org = world({ 'OrgContracts', 'Dossiers' })
        local c = W.place(s, f.creator)
        truthy(s.org.receiveContract(c.id, 'CREATOR1'))
        W.allow(s, 3, 'K7')
        return s, f, org, c
    end

    it('needs an assigned contract, a meeting spot of the organisation and a rule from the list', function()
        local s, _, org, c = assigned()
        eq(select(2, s.org.writeDossier(BOSS, c.id, { notes = 'x' })), 'org_not_found', 'not assigned yet')
        truthy(s.org.assignContract(W.STAFF, c.id, 'RECRUIT1'))
        eq(select(2, s.org.writeDossier(LIEUT, c.id, { notes = 'x' })), 'org_no_power')
        eq(select(2, s.org.writeDossier(BOSS, c.id, { spot = 'nowhere' })), 'org_not_found')
        eq(select(2, s.org.writeDossier(BOSS, c.id, { rules = 'loud' })), 'invalid_input')
        W.at(6, 50.0, 50.0)
        truthy(s.org.placeSpot({ staff = true, cid = 'ADMIN001', source = 6 }, { kind = 'meeting', here = true,
            label = 'Pier' }))
        local pier
        for id, l in pairs(org.locations) do if l.kind == 'meeting' then pier = id end end
        truthy(s.org.writeDossier(BOSS, c.id, { notes = 'Wait for dark.', spot = pier, rules = 'discreet' }))
        local mine = W.call('orgMine', 13, {}).data.assigned[1].dossier
        eq(mine.notes, 'Wait for dark.')
        eq(mine.spot.label, 'Pier')
        truthy(mine.rulesText)
        eq(W.call('orgMine', 12, {}).data.assigned[1], nil, 'only its member reads it')
        truthy(s.org.writeDossier(BOSS, c.id, false))
        eq(W.call('orgMine', 13, {}).data.assigned[1].dossier, nil, 'cleared')
    end)

    it('never carries a citizen id, markup or a link', function()
        local s, _, _, c = assigned()
        truthy(s.org.assignContract(W.STAFF, c.id, 'RECRUIT1'))
        for _, notes in ipairs({ 'target is TARGET01', 'placed by creator1', '<i>x</i>', 'https://x.example',
            string.rep('n', 601) }) do
            falsy(s.org.writeDossier(BOSS, c.id, { notes = notes }), notes)
        end
        -- What the assigned member reads has no field about the target
        -- beyond the name the board card shows.
        truthy(s.org.writeDossier(BOSS, c.id, { notes = 'Quietly.' }))
        local row = W.call('orgMine', 13, {}).data.assigned[1]
        for key in pairs(row) do
            truthy(({ id = true, state = true, targetName = true, expiresIn = true, dossier = true })[key], key)
        end
        for key in pairs(row.dossier) do
            truthy(({ notes = true, rules = true, rulesText = true, spot = true, at = true })[key], key)
        end
    end)

    it('is written by staff from the panel too', function()
        local s, _, org, c = assigned()
        truthy(s.org.assignContract(W.STAFF, c.id, 'RECRUIT1'))
        eq(W.ask(6, 'orgDossier', { id = c.id, notes = 'From staff.', rules = 'clean' }).ok, true)
        eq(org.settings.orgContracts[c.id].dossier.by, 'staff')
        eq(W.ask(6, 'orgDossier', { id = c.id, clear = true }).ok, true)
        eq(org.settings.orgContracts[c.id].dossier, nil)
    end)
end)

describe('hostile payloads with every extra on', function()
    local HOSTILE = { 'x', 12, true, {}, { id = {} }, { id = ('i'):rep(500) }, { member = {} }, { member = 12 },
        { on = 'yes' }, { text = {} }, { text = ('w'):rep(9000) }, { approve = 'yes', id = 'ap1_1' },
        { hours = -1, member = 'm1' }, { hours = 0 / 0 }, { hours = 1e309 }, { notes = {}, id = 'x' },
        { spot = {}, rules = {}, id = 'x' }, { clear = 'yes' }, { limit = -5 }, { limit = 1e9 }, { release = 1 } }

    it('answers every new phone request and staff op, never raising', function()
        local s = world(SWITCHES)
        for _, p in ipairs(require('server.org.powers').LIST) do W.allow(s, 3, p.code) end
        for _, name in ipairs({ 'orgWork', 'orgAssign', 'orgRelease', 'orgApprove', 'orgDossier', 'orgProbationEnd',
            'orgDuty', 'orgForceOff', 'orgChannel', 'orgChannelPost', 'orgChannelRemove', 'orgChannelMute' }) do
            for i, payload in ipairs(HOSTILE) do
                local reply = W.call(name, 11, payload)
                truthy(reply, name .. ' answered ' .. i)
                truthy(reply.err ~= CH.ERR.SERVER_ERROR, name .. ' did not raise on ' .. i)
                if name ~= 'orgWork' and name ~= 'orgChannel' then falsy(reply.ok, name .. ' refused ' .. i) end
            end
        end
        for _, op in ipairs({ 'orgChannelGet', 'orgContractAssign', 'orgAcceptDecide', 'orgProbation', 'orgDutyOff',
            'orgChannelPost', 'orgChannelRemove', 'orgChannelMute', 'orgDossier' }) do
            for i, payload in ipairs(HOSTILE) do
                local reply = W.ask(6, op, type(payload) == 'table' and payload or { value = payload })
                truthy(reply, op .. ' answered ' .. i)
                truthy(reply.err ~= CH.ERR.SERVER_ERROR, op .. ' did not raise on ' .. i)
                if op ~= 'orgChannelGet' then falsy(reply.ok, op .. ' refused ' .. i) end
            end
        end
        local _, _, read = s.org.channelRead(BOSS)
        eq(#read.rows, 0, 'no message got in')
    end)
end)
