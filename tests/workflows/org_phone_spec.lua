--- Step 7 workflows: the organisation from the phone's Organisation tab.
---
--- Staff set the organisation up from the panel (switch on, set up, hire a
--- boss, grant the boss role every power, put the office where the boss
--- stands); then the boss runs it from the phone, through the real page
--- callbacks and the real client: hiring a player standing nearby (who
--- answers the invite on their own phone), roles, pay, cuts, funds, access,
--- places, notices, applications, renaming, the menu's layout, firing.
--- Every request answers ok and leaves what it says: the roster, the funds,
--- the audit rows; and the money moved by the funds is conserved.

local W = require('tests.workflows.lib')
W.ran.org = true

local EXPECTED_FAIL = {
}

local function it_(name, fn) W.it(name, fn, EXPECTED_FAIL) end

local C = W.CAST
local BOSS, RECRUIT, HITMAN, GUARD = C.boss.source, C.hitman2.source, C.hitman.source, C.guard.source

--- The organisation set up by staff, the boss in the office with every
--- power, everyone at the office.
local function org()
    W.boot('memory', 'test', function()
        Config.Organisation.Enabled = true
        Config.Organisation.Codenames = true
        Config.Organisation.Payroll = true
        Config.Integrations.Banking = 'none'
    end)
    W.cast(W.s)
    local staff = C.staff.source
    W.allAt()
    W.opOk(staff, 'orgSetup', {}, 'set up')
    W.opOk(staff, 'orgMemberHire', { subject = C.boss.cid, grade = 3 }, 'hire the boss')
    local Powers = require('server.org.powers')
    local cells = {}
    for _, p in ipairs(Powers.LIST) do
        cells[#cells + 1] = { subject = 'role', id = 3, power = p.code, state = 'allow' }
    end
    W.opOk(staff, 'bossPermsSet', { cells = cells }, 'the boss role holds every power')
    W.opOk(staff, 'placeSet', { kind = 'office', here = true, label = 'Back room' }, 'the office')
    W.tick(1)
    return W.s.org.current()
end

local function tap(name, payload, why)
    local answer, answered = W.nui('crimson:' .. name, payload or {})
    truthy(answered, name .. ' never answered')
    if not (type(answer) == 'table' and answer.ok) then
        error(('%s refused: %s %s (%s)'):format(name, tostring(answer and answer.err),
            tostring(answer and answer.data and answer.data.message), tostring(why or '')), 2)
    end
    return answer.data
end

--- The boss's handle for a member, from the roster.
local function refOf(cid)
    W.client(BOSS)
    local rows = tap('orgMembers', {}).rows
    for _, r in ipairs(rows) do
        if r.realName == nil and W.s.org.current().members[cid] then
            -- Not full: match by the stored name or codename.
            local m = W.s.org.current().members[cid]
            if r.name == (m.codename or m.name) then return r.ref end
        elseif r.realName then
            local m = W.s.org.current().members[cid]
            if m and r.realName == m.name then return r.ref end
        end
    end
    error('no roster row for ' .. cid)
end

--- The boss hires a player standing with them; they accept on their phone.
local function hire(src, cid, grade)
    W.client(BOSS)
    tap('orgHire', { target = src, grade = grade }, 'hire ' .. cid)
    W.client(src)
    local mine = tap('orgMine', {})
    truthy(mine.invite and mine.invite.id, 'the invite is on their phone')
    tap('orgInviteAnswer', { id = mine.invite.id, accept = true })
    truthy(W.s.org.current().members[cid], cid .. ' is a member')
end

describe('organisation from the phone', function()
    it_('the boss hires a recruit, who reads their own tab, the spots and the roles', function()
        org()
        hire(RECRUIT, C.hitman2.cid, 0)
        local mine = tap('orgMine', {})
        truthy(mine.member or mine.role or mine.grade ~= nil, 'the recruit sees their membership')
        tap('orgSpots', {})
        -- The roles are read by a member holding a power over them: the boss.
        W.client(BOSS)
        tap('orgRoles', {})
        truthy(#W.audit('org_member_hired') >= 2, 'audited org_member_hired')
        local invited = false
        for _, row in ipairs(W.audit('org_member_hired')) do
            if row.detail and row.detail.invited then invited = true end
        end
        truthy(invited, 'the accepted invite is audited as a hire by invite')
    end)

    it_('the boss manages a member: role, suspension, limits, grant, codename, then fires them', function()
        org()
        hire(RECRUIT, C.hitman2.cid, 0)
        local ref = refOf(C.hitman2.cid)
        tap('orgSetRole', { member = ref, grade = 1 })
        eq(W.s.org.current().members[C.hitman2.cid].grade, 1, 'promoted')
        ref = refOf(C.hitman2.cid)
        tap('orgSuspend', { member = ref, hours = 1, reason = 'late to the meet' })
        truthy(W.s.org.current().members[C.hitman2.cid].suspended_until, 'suspended')
        tap('orgMemberLimits', { member = ref, maxAtOnce = 2, cooldownMinutes = 5 })
        tap('orgMemberGrant', { member = ref, power = 'M1', state = 'grant' })
        tap('orgCodename', { member = ref, codename = 'Ghost' })
        eq(W.s.org.current().members[C.hitman2.cid].codename, 'Ghost', 'the codename')
        Env.advance(3600)
        ref = refOf(C.hitman2.cid)
        tap('orgFire', { member = ref, reason = 'talked to the police' })
        falsy(W.s.org.current().members[C.hitman2.cid], 'fired')
        for _, action in ipairs({ 'org_member_role', 'org_member_suspended', 'org_member_limits',
                                  'org_member_grant', 'org_member_fired' }) do
            truthy(#W.audit(action) >= 1, 'audited ' .. action)
        end
    end)

    it_('the boss edits the roles: create, rename, powers, pay, cooldown, access, delete', function()
        org()
        W.client(BOSS)
        local roles = tap('orgRoles', {}).rows or {}
        local used = {}
        for _, r in ipairs(roles) do used[r.grade] = true end
        local free
        for g = 1, 2 do if not used[g] then free = g break end end
        free = free or 2
        if used[free] then tap('orgRoleDelete', { grade = free }) end
        tap('orgRoleCreate', { grade = free, name = 'enforcer', label = 'Enforcer', pay = 5 })
        tap('orgRoleEdit', { grade = free, name = 'enforcer', label = 'Heavy' })
        tap('orgRolePowers', { grade = free, power = 'M1', on = true })
        tap('orgRolePay', { grade = free, pay = 10 })
        tap('orgRoleCooldown', { grade = free, minutes = 5 })
        tap('orgAccess', { grade = free, rules = { maxAtOnce = 2 } })
        tap('orgRoleDelete', { grade = free })
        falsy(W.s.org.current().roles[free], 'deleted')
        for _, action in ipairs({ 'org_role_created', 'org_role_edited', 'org_role_power', 'org_role_pay',
                                  'org_role_deleted' }) do
            truthy(#W.audit(action) >= 1, 'audited ' .. action)
        end
    end)

    it_('the money: a deposit, a cut, a salary, a bonus, a withdrawal, the funds read back', function()
        org()
        hire(RECRUIT, C.hitman2.cid, 0)
        local start = W.world()
        W.client(BOSS)
        tap('orgDeposit', { amount = 5000, account = 'bank', nonce = 'dep-1' })
        local Funds = require('server.org.funds')
        eq(Funds.balance(W.s.org.current()), 5000, 'in the funds')
        tap('orgSetCut', { kind = 'payout', percent = 10 })
        tap('orgSalary', { grade = 0, amount = 100 })
        local ref = refOf(C.hitman2.cid)
        W.client(BOSS)
        tap('orgBonus', { member = ref, amount = 250, reason = 'good work', nonce = 'bonus-1' })
        tap('orgWithdraw', { amount = 500, reason = 'rent for the back room', nonce = 'wd-1' })
        local funds = tap('orgFunds', {})
        truthy(funds, 'the funds and their history')
        eq(Funds.balance(W.s.org.current()), 4250, 'what the funds hold after')
        eq(W.world() - start, 0, 'the funds\' money is conserved')
        for _, action in ipairs({ 'org_funds_deposit', 'org_cut_set', 'org_salary', 'org_bonus',
                                  'org_funds_withdraw' }) do
            truthy(#W.audit(action) >= 1, 'audited ' .. action)
        end
    end)

    it_('places, notices, applications, picks, renaming, the layout and the office rule', function()
        local o = org()
        W.client(BOSS)
        tap('orgPlaceHere', { kind = 'meeting', label = 'The pier' })
        local spot
        for _, row in ipairs(tap('orgSpots', {}).rows or {}) do
            if row.kind == 'meeting' then spot = row.id end
        end
        truthy(spot, 'the meeting spot')
        tap('orgRemoveSpot', { id = spot })
        tap('orgNotice', { text = 'Meet at nine', broadcast = true })
        eq(W.s.org.current().settings.notice.text, 'Meet at nine', 'the notice')
        -- A player applies at the sign-up spot; the boss decides.
        tap('orgPlaceHere', { kind = 'signup', label = 'The bar' })
        W.client(GUARD)
        tap('orgApply', { text = 'I want in' })
        W.client(BOSS)
        local apps = tap('orgApplications', {})
        local first = (apps.rows or apps)[1]
        truthy(first and first.id, 'the application is listed')
        tap('orgDecide', { id = first.id, accept = true })
        -- A contract picked for a member.
        hire(HITMAN, C.hitman.cid, 0)
        local c = W.s.contracts.create(W.s.identity.resolve(C.creator.source), { targetCid = C.target.cid,
            reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        truthy(c, 'a contract to pick')
        local ref = refOf(C.hitman.cid)
        W.client(BOSS)
        tap('orgPick', { id = c.id, member = ref })
        tap('orgRename', { label = 'The Firm' })
        eq(W.s.org.current().label, 'The Firm', 'renamed')
        tap('orgLayout', { layout = { labels = { members = 'Crew' } } })
        tap('orgOfficeRule', { power = 'M6', on = true })
        for _, action in ipairs({ 'org_location_set', 'org_location_removed', 'org_notice', 'org_applied',
                                  'org_application', 'org_pick', 'org_renamed', 'org_layout',
                                  'org_office_rule' }) do
            truthy(#W.audit(action) >= 1, 'audited ' .. action)
        end
        local _ = o
    end)
end)

return W
