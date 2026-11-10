--- Boss permissions and the powers engine (server/org/powers.lua,
--- server/org/engine.lua), through the organisation's own functions and its
--- requests: every power off for every boss until staff allow it; staff may
--- always; a member's deny and the ceiling's deny win; a boss passes on only
--- what they hold, only below their rank, never to or on themselves, never
--- past a lock; revoking makes their grants inactive and giving it back
--- restores them; the last boss is protected; office-only powers need the
--- office by the server's own position; and every request survives every
--- hostile payload and its rate limit.

local W = require('tests.harness.org_world')

local function world(opts)
    local s, f = W.world(opts)
    W.crew(s)
    return s, f, s.org.current()
end

local BOSS, LIEUT, RECRUIT = W.boss(11, 'BOSS0001'), W.boss(12, 'LIEUT001'), W.boss(13, 'RECRUIT1')

describe('the powers as constants', function()
    it('lists every power of the plan, each once, in a known area', function()
        local Powers = require('server.org.powers')
        local codes, areas = {}, {}
        for _, a in ipairs(Powers.AREAS) do areas[a] = true end
        for _, p in ipairs(Powers.LIST) do
            falsy(codes[p.code], p.code .. ' once')
            codes[p.code] = true
            truthy(areas[p.area], p.code .. ' in a known area')
            truthy(p.label and p.about, p.code .. ' has words')
        end
        for _, code in ipairs({ 'M1', 'M2', 'M3', 'M4', 'M5', 'M6', 'R1', 'R2', 'R3', 'R4', 'P1', 'P2',
            'C1', 'C2', 'C3', 'C4', 'C5', 'C6', 'C7', 'C8', 'K1', 'K2', 'K3', 'L1', 'L2', 'L3', 'N1', 'N2',
            'S1', 'S2', 'S3', 'D2', 'D3' }) do
            truthy(codes[code], code)
        end
        eq(#Powers.LIST, 33, 'the 31 area powers and D2, D3 (D1 is R4)')
        eq(Powers.resolve('D1'), 'R4')
        eq(Powers.resolve('TAKE'), nil, 'TAKE is no boss power')
        eq(Powers.resolve('TAKE', true), 'TAKE')
        eq(Powers.resolve('X9'), nil)
        eq(Powers.resolve(12), nil)
    end)
end)

describe('Boss permissions: the ceiling', function()
    it('gives a boss nothing until staff allow it', function()
        local s, _, org = world()
        eq(next(s.org.Engine.held(org, 'BOSS0001')), nil, 'the boss holds nothing')
        for _, entry in ipairs(require('server.org.boss_ops').LIST) do
            if entry.power ~= 'any' and entry.power ~= 'member' then
                local reply = W.call(entry.name, 11, { member = 'x', grade = 0, kind = 'payout', percent = 1,
                    power = 'M1', state = 'grant', on = true, amount = 10, reason = 'r', id = 'x', target = 13,
                    label = 'X', layout = {}, rules = { maxReward = 1 }, minutes = 1, text = 'hi' })
                falsy(reply.ok, entry.name .. ' refused')
                truthy(reply.err == 'org_no_power' or reply.err == 'org_not_found' or reply.err == 'invalid_input',
                    entry.name .. ': ' .. tostring(reply.err))
                truthy(reply.data and reply.data.message, entry.name .. ' says why')
            end
        end
    end)

    it('allows by role, by member, and a member deny beats the role', function()
        local s, _, org = world()
        local E = s.org.Engine
        W.allow(s, 3, 'M1')
        truthy(E.holds(org, 'BOSS0001', 'M1'), 'role allow')
        falsy(E.holds(org, 'LIEUT001', 'M1'), 'another role has nothing')
        truthy(s.org.setCeiling(W.STAFF, 'member', 'LIEUT001', 'M1', 'allow'))
        truthy(E.holds(org, 'LIEUT001', 'M1'), 'member allow')
        truthy(s.org.setCeiling(W.STAFF, 'member', 'BOSS0001', 'M1', 'deny'))
        falsy(E.holds(org, 'BOSS0001', 'M1'), 'member deny beats the role allow')
        truthy(s.org.setCeiling(W.STAFF, 'member', 'BOSS0001', 'M1', 'inherit'))
        truthy(E.holds(org, 'BOSS0001', 'M1'), 'inherit: the role again')
        truthy(s.org.setCeiling(W.STAFF, 'role', 3, 'M1', 'off'))
        falsy(E.holds(org, 'BOSS0001', 'M1'))
        falsy(s.org.setCeiling(BOSS, 'role', 3, 'M1', 'allow'), 'a boss never sets the ceiling')
        falsy(s.org.setCeiling(W.STAFF, 'role', 3, 'M1', 'deny'), 'a role cell is allow or off')
        falsy(s.org.setCeiling(W.STAFF, 'member', 'NOBODY', 'M1', 'allow'))
        falsy(s.org.setCeiling(W.STAFF, 'role', 3, 'ZZ', 'allow'))
    end)

    it('takes a power from a member with their own deny, whatever else says', function()
        local s, _, org = world()
        W.allow(s, 3, 'M1')
        truthy(s.org.memberGrant(W.STAFF, 'BOSS0001', 'M1', 'deny'))
        falsy(s.org.Engine.holds(org, 'BOSS0001', 'M1'))
    end)

    it('lets staff save a batch from the panel, checked whole first', function()
        local s = world()
        local view = W.ask(6, 'orgGet', {})
        local ref
        for _, m in ipairs(view.data.members) do if m.grade == 2 then ref = m.ref end end
        local reply = W.ask(6, 'bossPermsSet', { cells = {
            { subject = 'role', id = 3, power = 'M2', state = 'allow' },
            { subject = 'member', id = ref, power = 'C8', state = 'allow' },
        } })
        eq(reply.ok, true, tostring(reply.message))
        local org = s.org.current()
        eq(org.ceiling.role[3].M2, 'allow')
        eq(org.ceiling.member.LIEUT001.C8, 'allow')
        reply = W.ask(6, 'bossPermsSet', { cells = {
            { subject = 'role', id = 3, power = 'M3', state = 'allow' },
            { subject = 'role', id = 3, power = 'NOPE', state = 'allow' },
        } })
        falsy(reply.ok)
        eq(org.ceiling.role[3].M3, nil, 'nothing of a refused batch is written')
        reply = W.ask(6, 'bossPermsRevokeAll', { subject = 'role', id = 3 })
        eq(reply.ok, true)
        eq(next(org.ceiling.role[3]), nil)
        eq(W.ask(7, 'bossPermsSet', { subject = 'role', id = 3, power = 'M2', state = 'allow' }).err, 'not_allowed',
            'a reader may not')
        s.audit.flush()
        truthy(#(s.storage.auditByAction('org_grant', 20) or {}) >= 3, 'every cell on the record')
    end)
end)

describe('delegation', function()
    local function delegator(s)
        W.allow(s, 3, 'R4')
        W.allow(s, 3, 'D2')
        W.allow(s, 3, 'M1')
        W.office(s)
        W.at(11, 100.0, 100.0, 30.0)
    end

    it('passes on only what the boss holds, to roles below them', function()
        local s, _, org = world()
        delegator(s)
        truthy(s.org.rolePower(BOSS, 2, 'M1', true))
        truthy(s.org.Engine.holds(org, 'LIEUT001', 'M1'), 'the lieutenant holds it from the boss')
        local ok, err = s.org.rolePower(BOSS, 2, 'C7', true)
        falsy(ok)
        eq(err, 'org_not_held', 'not one they do not hold')
        ok, err = s.org.rolePower(BOSS, 3, 'M1', true)
        eq(err, 'org_rank', 'not their own role')
        truthy(s.org.roleCreate(W.STAFF, { grade = 4, name = 'don', label = 'Don' }))
        ok, err = s.org.rolePower(BOSS, 4, 'M1', true)
        eq(err, 'org_rank', 'not a role above')
        truthy(s.org.roleEdit(W.STAFF, 1, { locked = true }))
        ok, err = s.org.rolePower(BOSS, 1, 'M1', true)
        eq(err, 'org_locked', 'not a role staff locked')
        truthy(s.org.rolePower(W.STAFF, 0, 'M1', true))
        ok, err = s.org.rolePower(BOSS, 0, 'M1', false)
        eq(err, 'org_locked', 'never takes away what staff gave')
    end)

    it('lets anyone with R4 pass Take contracts below, without the ceiling', function()
        local s, _, org = world()
        delegator(s)
        truthy(s.org.rolePower(BOSS, 0, 'TAKE', true))
        truthy(s.org.Engine.holds(org, 'RECRUIT1', 'TAKE'))
    end)

    it('makes a boss\'s grants inactive when staff revoke the power, and restores them', function()
        local s, _, org = world()
        delegator(s)
        truthy(s.org.rolePower(BOSS, 2, 'M1', true))
        truthy(s.org.memberGrant(BOSS, 'RECRUIT1', 'M1', 'grant'))
        truthy(s.org.Engine.holds(org, 'RECRUIT1', 'M1'))
        truthy(s.org.setCeiling(W.STAFF, 'role', 3, 'M1', 'off'))
        falsy(s.org.Engine.holds(org, 'LIEUT001', 'M1'), 'the role grant is inactive')
        falsy(s.org.Engine.holds(org, 'RECRUIT1', 'M1'), 'and the member grant')
        eq(s.org.Engine.inactiveWhy(org, 'RECRUIT1', org.members.RECRUIT1.grants.M1, 'M1'), 'granter_lost')
        truthy(org.roles[2].powers.M1, 'kept, not deleted')
        W.allow(s, 3, 'M1')
        truthy(s.org.Engine.holds(org, 'LIEUT001', 'M1'), 'given back: restored')
        truthy(s.org.Engine.holds(org, 'RECRUIT1', 'M1'))
    end)

    it('cascades down a chain, and a demoted granter loses what they passed on', function()
        local s, _, org = world()
        delegator(s)
        truthy(s.org.rolePower(BOSS, 2, 'D2', true))
        truthy(s.org.rolePower(BOSS, 2, 'M1', true))
        truthy(s.org.memberGrant(LIEUT, 'RECRUIT1', 'M1', 'grant'), 'the lieutenant passes it on')
        truthy(s.org.Engine.holds(org, 'RECRUIT1', 'M1'))
        truthy(s.org.setCeiling(W.STAFF, 'role', 3, 'M1', 'off'))
        falsy(s.org.Engine.holds(org, 'RECRUIT1', 'M1'), 'two steps down, inactive too')
        W.allow(s, 3, 'M1')
        truthy(s.org.Engine.holds(org, 'RECRUIT1', 'M1'))
        truthy(s.org.setRole(W.STAFF, 'LIEUT001', 0))
        falsy(s.org.Engine.holds(org, 'RECRUIT1', 'M1'), 'a granter no longer above holds nothing for them')
        eq(s.org.Engine.inactiveWhy(org, 'RECRUIT1', org.members.RECRUIT1.grants.M1, 'M1'), 'outranked')
    end)

    it('holds nothing through a loop of grants', function()
        local s, _, org = world()
        org.members.LIEUT001.grade = 3
        org.members.BOSS0001.grants.M1 = { by = 'LIEUT001', at = 1 }
        org.members.LIEUT001.grants.M1 = { by = 'BOSS0001', at = 1 }
        org.ceiling.role[3] = { D3 = 'allow' }
        falsy(s.org.Engine.holds(org, 'BOSS0001', 'M1'))
        falsy(s.org.Engine.holds(org, 'LIEUT001', 'M1'))
    end)

    it('refuses every forbidden per-member grant', function()
        local s = world()
        delegator(s)
        local ok, err = s.org.memberGrant(BOSS, 'BOSS0001', 'M1', 'grant')
        eq(err, 'org_self', 'never themselves')
        truthy(s.org.hire(W.STAFF, { cid = 'HITMAN01', name = 'Rook', source = 3 }, 3))
        ok, err = s.org.memberGrant(BOSS, 'HITMAN01', 'M1', 'grant')
        eq(err, 'org_rank', 'never an equal')
        ok, err = s.org.memberGrant(BOSS, 'RECRUIT1', 'C7', 'grant')
        eq(err, 'org_not_held', 'never what they do not hold')
        truthy(s.org.memberGrant(W.STAFF, 'RECRUIT1', 'M1', 'deny'))
        ok, err = s.org.memberGrant(BOSS, 'RECRUIT1', 'M1', 'clear')
        eq(err, 'org_locked', 'never lifts a staff deny')
        truthy(s.org.memberStaff(W.STAFF, 'LIEUT001', { locked = true }))
        ok, err = s.org.memberGrant(BOSS, 'LIEUT001', 'M1', 'grant')
        eq(err, 'org_locked', 'never a member staff locked')
        ok, err = s.org.memberGrant(BOSS, 'RECRUIT1', 'M1', 'maybe')
        eq(err, 'invalid_input')
        falsy(ok)
    end)
end)

describe('rank, self and the last boss', function()
    it('acts only below its own rank, and promotes to its own rank only with D3', function()
        local s, _, org = world()
        for _, code in ipairs({ 'M3', 'M4', 'M5', 'M6' }) do W.allow(s, 3, code) end
        W.allow(s, 2, 'M3')
        W.office(s)
        W.at(11, 100.0, 100.0)
        W.at(12, 100.0, 100.0)
        local ok, err = s.org.fire(LIEUT, 'BOSS0001', 'coup')
        eq(err, 'org_rank', 'a lieutenant never fires the boss')
        ok, err = s.org.fire(BOSS, 'BOSS0001', 'quit')
        eq(err, 'org_self')
        ok, err = s.org.setRole(BOSS, 'BOSS0001', 2)
        eq(err, 'org_self')
        ok, err = s.org.suspend(BOSS, 'BOSS0001', 1)
        eq(err, 'org_self')
        ok, err = s.org.memberLimits(BOSS, 'BOSS0001', 1, 0)
        eq(err, 'org_self')
        truthy(s.org.setRole(BOSS, 'RECRUIT1', 2), 'below their own rank')
        ok, err = s.org.setRole(BOSS, 'RECRUIT1', 3)
        eq(err, 'org_rank', 'not to their own rank without D3')
        W.allow(s, 3, 'D3')
        truthy(s.org.setRole(BOSS, 'RECRUIT1', 3), 'with D3, level with them')
        truthy(s.org.roleCreate(W.STAFF, { grade = 4, name = 'don', label = 'Don' }))
        ok, err = s.org.setRole(BOSS, 'LIEUT001', 4)
        eq(err, 'org_rank', 'never above, D3 or not')
        ok, err = s.org.setRole(BOSS, 'RECRUIT1', 0)
        eq(err, 'org_rank', 'and never on an equal, even one they raised')
        local _ = org
    end)

    it('never leaves the organisation without its top boss, unless staff do it', function()
        local s, _, org = world()
        truthy(s.org.Engine.wouldLeaveNoBoss(org, 'BOSS0001'))
        falsy(s.org.Engine.wouldLeaveNoBoss(org, 'LIEUT001'))
        truthy(s.org.hire(W.STAFF, { cid = 'HITMAN01', name = 'Rook', source = 3 }, 3))
        falsy(s.org.Engine.wouldLeaveNoBoss(org, 'BOSS0001'), 'two bosses: either may go')
        truthy(s.org.fire(W.STAFF, 'HITMAN01', 'staff may'))
        local ok, err = s.org.roleDelete(W.STAFF, 3)
        eq(err, 'org_limit', 'not a role that holds members')
        truthy(s.org.setRole(W.STAFF, 'BOSS0001', 2), 'staff may move the last boss')
        falsy(ok)
    end)

    it('lets a boss edit and delete only empty roles below them, never a boss role', function()
        local s = world()
        for _, code in ipairs({ 'R1', 'R2', 'R3' }) do W.allow(s, 3, code) end
        W.office(s)
        W.at(11, 100.0, 100.0)
        truthy(s.org.roleCreate(BOSS, { grade = 1, name = 'x', label = 'X' }) == false)
        truthy(s.org.roleCreate(BOSS, { grade = 2, name = 'dup' }) == false, 'a grade already used')
        local ok, err = s.org.roleCreate(BOSS, { grade = 3, name = 'peer', label = 'Peer' })
        eq(err, 'org_already')
        truthy(s.org.roleDelete(W.STAFF, 1))
        truthy(s.org.roleCreate(BOSS, { grade = 1, name = 'runner', label = 'Runner', pay = 10, isBoss = true }))
        falsy(s.org.current().roles[1].is_boss, 'a boss never makes a boss role')
        ok, err = s.org.roleCreate(BOSS, { grade = 9, name = 'king', label = 'King' })
        eq(err, 'org_rank', 'not at or above their own rank')
        ok, err = s.org.roleCreate(BOSS, { grade = 1.5, name = 'half' })
        eq(err, 'invalid_input')
        truthy(s.org.roleEdit(BOSS, 1, { label = 'Courier', newGrade = 1 }))
        ok, err = s.org.roleEdit(BOSS, 2, { newGrade = 5 })
        eq(err, 'org_rank', 'never moved to or above their own rank')
        ok, err = s.org.roleEdit(W.STAFF, 2, { newGrade = 7 })
        eq(err, 'org_limit', 'a role with members does not move, even for staff')
        truthy(s.org.roleDelete(BOSS, 1), 'an empty role below')
        ok, err = s.org.roleDelete(BOSS, 2)
        eq(err, 'org_limit', 'not one with members')
        truthy(s.org.fire(W.STAFF, 'LIEUT001', 'x'))
        ok, err = s.org.roleDelete(BOSS, 3)
        eq(err, 'org_limit', 'their own, which holds them')
        truthy(s.org.roleEdit(W.STAFF, 2, { isBoss = true }))
        ok, err = s.org.roleDelete(BOSS, 2)
        eq(err, 'org_locked', 'never a boss role')
    end)
end)

describe('the boss office', function()
    it('needs the office for office powers, by the server\'s own position', function()
        local s = world()
        W.allow(s, 3, 'M2')
        W.office(s, 100.0, 100.0)
        W.at(11, 500.0, 500.0)
        W.at(3, 500.0, 501.0)
        local reply = W.call('orgHire', 11, { target = 3, grade = 0 })
        eq(reply.err, 'org_office', 'away from it')
        W.at(11, 101.0, 100.0)
        W.at(3, 102.0, 100.0)
        reply = W.call('orgHire', 11, { target = 3, grade = 0 })
        eq(reply.ok, true, tostring(reply.data and reply.data.message))
        eq(reply.data.invited, true, 'an invite')
        local invite = W.call('orgMine', 3, {}).data.invite
        eq(W.call('orgInviteAnswer', 3, { id = invite.id, accept = true }).ok, true)
        eq(s.org.current().members.HITMAN01.grade, 0)
    end)

    it('lets staff lift an office rule, and a boss add one for themselves but never lift staff\'s', function()
        local s, _, org = world()
        W.allow(s, 3, 'M2')
        W.allow(s, 3, 'S3')
        W.allow(s, 3, 'M1')
        truthy(s.org.officeRule(W.STAFF, 'M2', false))
        falsy(s.org.Engine.needsOffice(org, 'M2'))
        truthy(s.org.officeRule(W.STAFF, 'C7', true))
        local ok, err = s.org.officeRule(BOSS, 'C7', false)
        eq(err, 'org_not_held', 'one they do not hold')
        W.allow(s, 3, 'C7')
        ok, err = s.org.officeRule(BOSS, 'C7', false)
        eq(err, 'org_locked', 'never lifts staff\'s')
        truthy(s.org.officeRule(BOSS, 'M1', true))
        truthy(s.org.Engine.needsOffice(org, 'M1'))
    end)

    it('refuses a hire of somebody too far, in another bucket, or past the bounds', function()
        local s = world()
        W.allow(s, 3, 'M2')
        truthy(s.org.officeRule(W.STAFF, 'M2', false))
        W.at(11, 0.0, 0.0)
        W.at(3, 50.0, 0.0)
        eq(W.call('orgHire', 11, { target = 3 }).err, 'org_rule', 'too far')
        W.at(3, 1.0, 0.0)
        Env.players[3]._bucket = 4
        eq(W.call('orgHire', 11, { target = 3 }).err, 'org_rule', 'another routing bucket')
        Env.players[3]._bucket = nil
        eq(W.call('orgHire', 11, { target = 3, grade = 2 }).err, 'org_bounds', 'above HireMaxGrade')
        truthy(s.org.setLimits(W.STAFF, { MaxMembers = 3 }))
        eq(W.call('orgHire', 11, { target = 3 }).err, 'org_limit', 'at MaxMembers')
        eq(W.call('orgHire', 11, { target = 999 }).err, 'org_not_found')
    end)
end)

describe('every phone request, through its net event', function()
    it('answers ok to a boss holding the power, at the office, for each one', function()
        local s, f, org = world({ configure = function() Config.Organisation.Funds = 'internal' end })
        for _, p in ipairs(require('server.org.powers').LIST) do W.allow(s, 3, p.code) end
        truthy(s.org.setLimits(W.STAFF, { LocationCooldownMinutes = 0 }))
        W.office(s)
        W.at(11, 100.0, 100.0)
        W.at(3, 101.0, 100.0)
        local okd = {}
        local function ok(name, payload)
            local reply = W.call(name, 11, payload)
            truthy(reply and reply.ok, name .. ': ' .. tostring(reply and reply.err) .. ' '
                .. tostring(reply and reply.data and reply.data.message))
            okd[name] = true
            return reply.data
        end
        local function ref(grade)
            for _, m in ipairs(ok('orgMembers', {}).rows) do if m.grade == grade then return m.ref end end
        end
        ok('orgMine', {})
        ok('orgRoles', {})
        ok('orgSpots', {})
        ok('orgHire', { target = 3, grade = 0 })
        local accepted = W.call('orgInviteAnswer', 3, { id = W.call('orgMine', 3, {}).data.invite.id, accept = true })
        eq(accepted.ok, true, tostring(accepted.err))
        okd.orgInviteAnswer = true
        local recruit = ref(0)
        ok('orgSetRole', { member = recruit, grade = 1 })
        ok('orgSuspend', { member = recruit, hours = 1, reason = 'late' })
        ok('orgMemberLimits', { member = recruit, maxAtOnce = 1, cooldownMinutes = 5 })
        ok('orgMemberGrant', { member = recruit, power = 'M1', state = 'grant' })
        ok('orgDeposit', { amount = 5000, account = 'bank', nonce = 'd1' })
        ok('orgFunds', {})
        ok('orgWithdraw', { amount = 100, reason = 'rent', nonce = 'w1' })
        ok('orgBonus', { member = recruit, amount = 100, reason = 'good', nonce = 'b1' })
        ok('orgSetCut', { kind = 'payout', percent = 5 })
        ok('orgAccess', { grade = 0, rules = { maxReward = 100000 } })
        ok('orgRoleCooldown', { grade = 0, minutes = 5 })
        local c = W.place(s, f.creator)
        ok('orgPick', { id = c.id, member = recruit })
        ok('orgPlaceHere', { kind = 'meeting', label = 'Docks' })
        local meeting
        for _, l in pairs(org.locations) do if l.kind == 'meeting' then meeting = l.id end end
        ok('orgRemoveSpot', { id = meeting })
        ok('orgNotice', { text = 'Meet at nine' })
        ok('orgRename', { label = 'The Firm' })
        ok('orgLayout', { layout = { labels = { members = 'Crew' } } })
        ok('orgOfficeRule', { power = 'M1', on = true })
        ok('orgFire', { member = recruit, reason = 'done' })
        ok('orgRolePowers', { grade = 0, power = 'M1', on = true })
        ok('orgRolePay', { grade = 0, pay = 10 })
        ok('orgRoleDelete', { grade = 1 })
        ok('orgRoleCreate', { grade = 1, name = 'runner', label = 'Runner', pay = 5 })
        ok('orgRoleEdit', { grade = 1, label = 'Courier' })
        ok('orgPlaceHere', { kind = 'signup', label = 'Board' })
        W.at(1, 100.0, 100.0)
        local applied = W.call('orgApply', 1, { text = 'Let me in' })
        eq(applied.ok, true, tostring(applied.err))
        okd.orgApply = true
        local apps = ok('orgApplications', {})
        ok('orgDecide', { id = apps.rows[1].id, accept = false })
        local missing = {}
        for _, entry in ipairs(require('server.org.boss_ops').LIST) do
            if not okd[entry.name] then missing[#missing + 1] = entry.name end
        end
        eq(#missing, 0, 'never answered ok: ' .. table.concat(missing, ', '))
    end)
end)

describe('rate limits and hostile payloads', function()
    it('spends the orgWrite bucket on a boss\'s change, and refunds a refusal', function()
        local s = world()
        W.allow(s, 3, 'N1')
        Config.Cooldowns.orgWrite = { per = 60, burst = 2 }
        eq(W.call('orgNotice', 11, { text = 'one' }).ok, true)
        eq(W.call('orgNotice', 11, { text = 'two' }).ok, true)
        eq(W.call('orgNotice', 11, { text = 'three' }).err, CH.ERR.RATE_LIMITED)
        local _ = s
    end)

    local HOSTILE = {
        'x', 12, true, -1, 1e308, -1e308, 0 / 0, {}, { member = {} }, { member = 12, grade = 'x' },
        { grade = -5, name = ('a'):rep(5000), label = '<script>' }, { amount = -100, reason = {} },
        { amount = 1.5, nonce = ('n'):rep(100) }, { amount = '1e9', account = 'dirty' },
        { power = 'D1', state = 'grant', member = 'm1_1' }, { kind = 'office', id = {} },
        { percent = 101, kind = 'payout' }, { percent = -1, kind = 'stake' }, { percent = 0 / 0, kind = 'payout' },
        { rules = { maxReward = -1, rule = 'dead', whitelisted = 'no' }, grade = 0 },
        { layout = { labels = { nope = 'x' } } }, { layout = { hidden = { members = { 99 } } } },
        { text = ('w'):rep(5000) }, { text = 'https://evil.example' }, { id = ('i'):rep(400), accept = 'yes' },
        { target = 0 }, { target = 1.5 }, { minutes = -3, grade = 0 }, { hours = 1e9, member = 'x' },
        { x = 0 / 0, y = 1, z = 1, kind = 'signup' }, { x = 1e9, y = 1, z = 1, kind = 'signup' },
    }

    it('answers every phone request whatever it is sent, and changes nothing it should not', function()
        local s, _, org = world()
        for _, p in ipairs(require('server.org.powers').LIST) do W.allow(s, 3, p.code) end
        W.office(s)
        W.at(11, 100.0, 100.0)
        local balance = s.org.Funds.balance(org)
        for _, entry in ipairs(require('server.org.boss_ops').LIST) do
            for i, payload in ipairs(HOSTILE) do
                local reply = W.call(entry.name, 11, payload)
                truthy(reply, entry.name .. ' answered payload ' .. i)
                if entry.name ~= 'orgMine' and entry.name ~= 'orgRoles' and entry.name ~= 'orgMembers'
                    and entry.name ~= 'orgFunds' and entry.name ~= 'orgApplications' and entry.name ~= 'orgSpots'
                    and entry.name ~= 'orgNotice' and entry.name ~= 'orgLayout' then
                    falsy(reply.ok, entry.name .. ' refused payload ' .. i)
                end
                truthy(reply.err ~= CH.ERR.SERVER_ERROR, entry.name .. ' did not raise on payload ' .. i)
            end
        end
        eq(s.org.Funds.balance(org), balance, 'no money moved')
        eq(org.members.BOSS0001.grade, 3)
        for _, m in pairs(org.members) do truthy(org.roles[m.grade], 'every member in a real role') end
    end)

    it('answers every staff op whatever it is sent, without raising', function()
        local s = world()
        local _ = s
        for op in pairs(require('server.org.staff_ops').OPS) do
            for i, payload in ipairs(HOSTILE) do
                local reply = W.ask(6, op, type(payload) == 'table' and payload or { value = payload })
                truthy(reply, op .. ' answered ' .. i)
                truthy(reply.err ~= CH.ERR.SERVER_ERROR, op .. ' did not raise on payload ' .. i .. ': '
                    .. tostring(reply.message))
            end
        end
    end)

    it('gates every staff op by the ACE: reads for any reader, writes for the staff ACE', function()
        world()
        for op, level in pairs(require('server.org.staff_ops').OPS) do
            local none = W.ask(1, op, {})
            eq(none.err, 'not_allowed', op .. ' for nobody')
            local reader = W.ask(7, op, {})
            if level == 'write' then
                eq(reader.err, 'not_allowed', op .. ' is a write')
            else
                truthy(reader.err ~= 'not_allowed', op .. ' is a read')
            end
        end
    end)
end)
