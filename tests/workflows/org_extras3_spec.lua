--- Step 7 workflows: the organisation extras 3 (server/org/init.lua's several
--- organisations, server/org/extras3.lua), each switched on from config,
--- driven through the real page callbacks and the real client (the boss and
--- the members on their phones) and the panel's ops (staff). Every request
--- answers ok and leaves what it says, on the record.

local W = require('tests.workflows.lib')
W.ran.orgExtras3 = true

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

--- The organisation set up by staff with the switches given on, the boss
--- holding every power at the office, and two members hired by invite.
local function org(switches, extra)
    W.boot('memory', 'test', function()
        Config.Organisation.Enabled = true
        for _, key in ipairs(switches or {}) do Config.Organisation[key] = true end
        Config.Organisation.ApplyAtSignupOnly = false
        Config.Integrations.Banking = 'none'
        for k, v in pairs(extra or {}) do Config.Organisation[k] = v end
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

describe('organisation extras 3 from the phone and the panel', function()
    it_('several organisations: a second added, an outsider applies to it, one taken off', function()
        local first = org({ 'SeveralOrganisations' })
        local staff = C.staff.source
        W.opOk(staff, 'orgCreate', { job = 'syndicate', label = 'The Syndicate' }, 'add the second')
        local second = W.s.org.byId('syndicate')
        truthy(second, 'kept by its id')
        W.client(OUTSIDER)
        local outside = tap('orgMine', {})
        eq(#outside.choices, 2, 'the outsider picks one')
        eq(tap('orgMine', { org = 'syndicate' }).label, 'The Syndicate')
        tap('orgApply', { org = 'syndicate', text = 'I know the docks' })
        local view = W.opOk(staff, 'orgGet', { org = 'syndicate' }, 'staff read the second')
        local apps = (view and view.applications) or W.s.org.within(second, W.s.org.staffView, C.staff.cid).applications
        W.opOk(staff, 'orgApplication', { org = 'syndicate', id = apps[1].id, accept = true }, 'hire them')
        truthy(second.members[C.broker.cid], 'a member of the second')
        eq(first.members[C.broker.cid], nil, 'never of the first too')
        W.client(BOSS)
        local refused = W.nui('crimson:orgHire', { target = OUTSIDER, grade = 0 })
        eq(refused and refused.err, 'org_other_org', 'a member of one is not hired by the other')
        W.opOk(staff, 'orgMemberFire', { org = 'syndicate', subject = C.broker.cid, reason = 'Gone' }, 'fire')
        W.opOk(staff, 'orgRemove', { id = 'syndicate' }, 'take it off')
        eq(W.s.org.byId('syndicate'), nil)
        for _, action in ipairs({ 'org_added', 'org_removed' }) do
            truthy(#W.audit(action) >= 1, 'audited ' .. action)
        end
    end)

    it_('reputation, a dead drop, the garage, an internal contract, the handler and the log', function()
        local o = org({ 'Reputation', 'DeadDrops', 'Garage', 'InternalContracts', 'Handler', 'ActivityLog',
            'OrgContracts', 'Territory' }, { RepTiers = { '0, Unknown, 1000', '50, Known, 0' }, RepHeat = 0,
            GarageVehicles = { 'sultan' } })
        local staff = C.staff.source
        for _, kind in ipairs({ 'deaddrop', 'garage', 'npc' }) do
            W.opOk(staff, 'placeSet', { kind = kind, here = true, label = kind }, 'the ' .. kind)
        end
        W.opOk(staff, 'placeSet', { kind = 'territory', here = true, label = 'Docks', radius = 300 }, 'a territory')
        -- Reputation: the Unknown tier refuses a $5000 accept until staff lift it.
        local c, err = W.s.contracts.create(W.s.identity.resolve(C.creator.source), { targetCid = C.target.cid,
            reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        truthy(c, 'a contract: ' .. tostring(err))
        local territory = o.settings.orgContracts[c.id]
        if territory then W.opOk(staff, 'orgContractAssign', { id = c.id, release = true }, 'off the hold') end
        W.client(RECRUIT)
        local refused = W.nui('crimson:accept', { id = c.id, shown = { orgCut = 0 } })
        eq(refused and refused.err, 'org_tier', 'above the tier')
        W.opOk(staff, 'orgRepAdjust', { points = 60, reason = 'Proven at the docks' }, 'staff lift it')
        -- The boss leaves payouts at the dead drop; the member collects it there.
        W.client(BOSS)
        tap('orgPayoutMethod', { method = 'deaddrop' })
        W.client(RECRUIT)
        local accepted = W.nui('crimson:accept', { id = c.id, shown = { orgCut = 0 } })
        truthy(accepted and accepted.ok, 'accepted: ' .. tostring(accepted and accepted.err))
        local before = W.wealth and W.wealth(RECRUIT) or nil
        truthy(W.s.contracts.claimSlot(c.id, C.hitman2.cid, CH.FULFILMENT.KIDNAPPING))
        truthy(o.settings.drops[c.id .. ':' .. C.hitman2.cid], 'left at the drop')
        local drop
        for _, l in pairs(o.locations) do if l.kind == 'deaddrop' then drop = l.id end end
        truthy(W.net(RECRUIT, 'crimson-hitman:orgUse', drop), 'collected at the drop')
        eq(o.settings.drops[c.id .. ':' .. C.hitman2.cid], nil, 'collected')
        W.opOk(staff, 'orgPayoutMethod', { method = 'bank' }, 'staff set it back')
        -- A drop staff settle.
        W.opOk(staff, 'orgPayoutMethod', { method = 'deaddrop' }, 'staff choose the drop')
        local c2 = W.s.contracts.create(W.s.identity.resolve(C.creator.source), { targetCid = C.guard.cid,
            reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 500 } } })
        if o.settings.orgContracts[c2.id] then W.opOk(staff, 'orgContractAssign', { id = c2.id, release = true }, 'off') end
        W.client(HITMAN)
        local took = W.nui('crimson:accept', { id = c2.id, shown = { orgCut = 0 } })
        truthy(took and took.ok, 'accepted: ' .. tostring(took and took.err))
        truthy(W.s.contracts.claimSlot(c2.id, C.hitman.cid, CH.FULFILMENT.KIDNAPPING))
        -- By the handle the panel's row carries, as the page sends it.
        local handle
        for _, row in ipairs(W.opOk(staff, 'orgGet', {}, 'the drops').extras3.deadDrops.rows) do
            if row.contract == c2.id then handle = row.handle end
        end
        truthy(handle, 'the drop on the panel')
        W.opOk(staff, 'orgDropSettle', { handle = handle, how = 'release' }, 'staff hand it over')
        -- The garage: offered, taken out, returned, taken away by staff.
        W.client(BOSS)
        tap('orgGarageOffer', { models = { 'sultan' } })
        W.client(RECRUIT)
        eq(tap('orgGarage', {}).models[1], 'sultan')
        tap('orgGarageTake', { model = 'sultan' })
        tap('orgGarageReturn', {})
        tap('orgGarageTake', { model = 'sultan' })
        W.opOk(staff, 'orgGarageOffer', { models = { 'sultan' } }, 'staff offer it')
        W.opOk(staff, 'orgGarageRemove', { subject = C.hitman2.cid }, 'staff take it away')
        -- An internal contract on a member, asked by the boss, placed by staff's approval.
        W.client(BOSS)
        local ref
        for _, r in ipairs(tap('orgMembers', {}).rows or {}) do
            if r.name == W.s.org.current().members[C.hitman.cid].name then ref = r.ref end
        end
        local asked = tap('orgInternalRequest', { member = ref, reason = 'Sold us out', amount = 1000 })
        W.opOk(staff, 'orgInternalDecide', { id = asked.id, approve = true }, 'staff approve it')
        eq(o.settings.internal[asked.id].state, 'placed')
        -- The handler, at its NPC spot.
        local npc
        for _, l in pairs(o.locations) do if l.kind == 'npc' then npc = l.id end end
        truthy(W.net(RECRUIT, 'crimson-hitman:orgUse', npc), 'the handler talked to')
        -- The log: read by the boss, and by staff.
        W.client(BOSS)
        truthy(#tap('orgActivity', {}).rows > 0, 'the log has rows')
        W.opOk(staff, 'orgActivityGet', {}, 'staff read it')
        for _, action in ipairs({ 'org_rep_adjusted', 'org_payout_method', 'org_drop_left', 'org_drop_collected',
            'org_drop_settled', 'org_vehicle_out', 'org_vehicle_returned', 'org_vehicle_removed', 'org_garage_offer',
            'org_internal_requested', 'org_internal_decided' }) do
            truthy(#W.audit(action) >= 1, 'audited ' .. action)
        end
        local _ = before
    end)
end)
