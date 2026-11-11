--- Step 7 workflows: the organisation extras (server/org/extras.lua), each
--- switched on from config, driven through the real page callbacks and the
--- real client (the boss and the members on their phones) and the panel's
--- ops (staff): a contract sent to the organisation assigned, briefed in a
--- dossier, its accept approved and taken; another moved and released;
--- duty on and forced off; probation ended and put back; the channel
--- written, moderated and muted. Every request answers ok and leaves what
--- it says, on the record.

local W = require('tests.workflows.lib')
W.ran.orgExtras = true

local EXPECTED_FAIL = {
}

local function it_(name, fn) W.it(name, fn, EXPECTED_FAIL) end

local C = W.CAST
local BOSS, RECRUIT, HITMAN = C.boss.source, C.hitman2.source, C.hitman.source

local function tap(name, payload, why)
    local answer, answered = W.nui('crimson:' .. name, payload or {})
    truthy(answered, name .. ' never answered')
    if not (type(answer) == 'table' and answer.ok) then
        error(('%s refused: %s %s (%s)'):format(name, tostring(answer and answer.err),
            tostring(answer and answer.data and answer.data.message), tostring(why or '')), 2)
    end
    return answer.data
end

--- The organisation set up by staff with every extra on, the boss holding
--- every power at the office, and two members hired by invite.
local function org()
    W.boot('memory', 'test', function()
        Config.Organisation.Enabled = true
        for _, key in ipairs({ 'OrgContracts', 'AcceptApproval', 'Probation', 'Duty', 'Channel', 'Dossiers' }) do
            Config.Organisation[key] = true
        end
        Config.Organisation.ApprovalAbove = 1000
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
    W.opOk(staff, 'placeSet', { kind = 'meeting', here = true, label = 'Pier' }, 'a meeting spot')
    W.tick(1)
    for _, who in ipairs({ { RECRUIT, C.hitman2.cid }, { HITMAN, C.hitman.cid } }) do
        W.client(BOSS)
        tap('orgHire', { target = who[1], grade = 0 }, 'hire ' .. who[2])
        W.client(who[1])
        tap('orgInviteAnswer', { id = tap('orgMine', {}).invite.id, accept = true })
    end
    return W.s.org.current()
end

local function contract(target)
    local c, err = W.s.contracts.create(W.s.identity.resolve(C.creator.source), { targetCid = target or C.target.cid,
        reason = 'Unpaid debt', mode = CH.MODE.EXCLUSIVE, reward = { baseline = { cash = 5000 } } })
    truthy(c, 'a contract: ' .. tostring(err))
    truthy(W.s.org.receiveContract(c.id, C.creator.cid), 'sent to the organisation')
    return c
end

--- The boss's handle for a member, from the assignment list.
local function memberRef(cid)
    W.client(BOSS)
    local m = W.s.org.current().members[cid]
    for _, r in ipairs(tap('orgWork', {}).members or {}) do
        if r.name == (m.codename or m.name) then return r.ref end
    end
    error('no row for ' .. cid)
end

describe('organisation extras from the phone and the panel', function()
    it_('a contract sent to the organisation: assigned, briefed, approved and taken', function()
        local o = org()
        W.client(RECRUIT)
        tap('orgDuty', { on = true })
        local c = contract()
        local ref = memberRef(C.hitman2.cid)
        tap('orgAssign', { id = c.id, member = ref })
        eq(o.settings.orgContracts[c.id].cid, C.hitman2.cid, 'assigned')
        local spot
        for id, l in pairs(o.locations) do if l.kind == 'meeting' then spot = id end end
        tap('orgDossier', { id = c.id, notes = 'After dark.', spot = spot, rules = 'discreet' })
        W.client(RECRUIT)
        local mine = tap('orgMine', {})
        eq(mine.assigned[1].dossier.notes, 'After dark.', 'the member reads the dossier')
        local answer = W.nui('crimson:accept', { id = c.id, shown = { orgCut = 0 } })
        eq(answer and answer.err, 'org_approval', 'it waits for the boss')
        W.client(BOSS)
        local work = tap('orgWork', {})
        tap('orgApprove', { id = work.approvals[1].id, approve = true })
        local h = W.s.storage.readHitman(c.id, C.hitman2.cid)
        eq(h and h.state, 'active', 'the accept ran on approval')
        eq(o.settings.orgContracts[c.id].state, 'taken')
        for _, action in ipairs({ 'org_contract_received', 'org_contract_assigned', 'org_dossier',
            'org_accept_requested', 'org_accept_approved', 'org_duty' }) do
            truthy(#W.audit(action) >= 1, 'audited ' .. action)
        end
    end)

    it_('another moved by staff and released, duty forced off, probation ended and put back', function()
        local o = org()
        local staff = C.staff.source
        W.client(RECRUIT)
        tap('orgDuty', { on = true })
        local c = contract()
        W.opOk(staff, 'orgContractAssign', { id = c.id, subject = C.hitman2.cid }, 'staff assign')
        W.client(BOSS)
        tap('orgRelease', { id = c.id })
        eq(o.settings.orgContracts[c.id], nil, 'on the open board')
        local c2 = contract(C.guard.cid)
        W.opOk(staff, 'orgContractAssign', { id = c2.id, subject = C.hitman2.cid }, 'staff assign')
        W.opOk(staff, 'orgDossier', { id = c2.id, notes = 'From staff.', rules = 'clean' }, 'staff dossier')
        W.opOk(staff, 'orgContractAssign', { id = c2.id, release = true }, 'staff release')
        tap('orgForceOff', { member = memberRef(C.hitman2.cid) })
        falsy(W.s.org.Extras.onDuty(C.hitman2.cid), 'sent off duty')
        W.client(RECRUIT)
        tap('orgDuty', { on = true })
        W.opOk(staff, 'orgDutyOff', { subject = C.hitman2.cid }, 'staff off duty')
        tap('orgProbationEnd', { member = memberRef(C.hitman.cid) })
        W.opOk(staff, 'orgProbation', { subject = C.hitman.cid, passed = false }, 'back on probation')
        W.opOk(staff, 'orgProbation', { subject = C.hitman.cid, passed = true }, 'and off it')
        -- An accept waiting, refused by staff.
        local c3 = contract(C.broker.cid)
        W.opOk(staff, 'orgContractAssign', { id = c3.id, release = true }, 'on the board')
        W.client(HITMAN)
        local answer = W.nui('crimson:accept', { id = c3.id, shown = { orgCut = 0 } })
        eq(answer and answer.err, 'org_approval')
        local view = W.opOk(staff, 'orgGet', {}, 'the panel reads it')
        local waiting = view and view.extras and view.extras.work and view.extras.work.approvals
            or W.s.org.staffView(C.staff.cid).extras.work.approvals
        W.opOk(staff, 'orgAcceptDecide', { id = waiting[1].id, approve = false }, 'refused')
        for _, action in ipairs({ 'org_contract_released', 'org_duty_forced', 'org_probation',
            'org_accept_refused' }) do
            truthy(#W.audit(action) >= 1, 'audited ' .. action)
        end
    end)

    it_('the channel: written, read, muted and moderated from the phone and the panel', function()
        org()
        local staff = C.staff.source
        W.client(RECRUIT)
        tap('orgChannelPost', { text = 'Evening, all.' })
        W.client(BOSS)
        local rows = tap('orgChannel', {}).rows
        eq(rows[1].body, 'Evening, all.')
        tap('orgChannelMute', { member = rows[1].member, hours = 1 })
        W.client(RECRUIT)
        local refused = W.nui('crimson:orgChannelPost', { text = 'again' })
        eq(refused and refused.err, 'org_locked', 'muted')
        W.client(BOSS)
        tap('orgChannelRemove', { id = rows[1].id })
        W.opOk(staff, 'orgChannelPost', { text = 'Staff here.' }, 'staff post')
        local read = W.opOk(staff, 'orgChannelGet', {}, 'staff read')
        local list = read and read.rows or W.s.org.staffView(C.staff.cid).extras.channel
        eq(#list, 1, 'the one staff wrote')
        W.opOk(staff, 'orgChannelMute', { subject = C.hitman2.cid, hours = 0 }, 'unmuted')
        W.client(RECRUIT)
        tap('orgChannelPost', { text = 'Thanks.' })
        W.opOk(staff, 'orgChannelRemove', { id = list[1].id }, 'staff remove')
        for _, action in ipairs({ 'org_channel_post', 'org_channel_mute', 'org_channel_removed' }) do
            truthy(#W.audit(action) >= 1, 'audited ' .. action)
        end
    end)
end)
