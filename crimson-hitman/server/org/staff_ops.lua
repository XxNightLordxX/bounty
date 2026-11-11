CrimsonBoot.define('server.org.staff_ops', function() --[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                 crimson-hitman - server/org/staff_ops.lua                 ║
    ║    The admin panel's requests for the organisation and Boss permissions   ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- Added to the panel's one way in (Panel.extend), so each runs the same
--- gate as every other op: the engine's source, the ACE again (READ for the
--- reads; WRITE, the staff ACE itself, for every change), the panel's token
--- buckets, a write waiting for boot recovery, the log flushed after every
--- write. Staff may do everything here whatever Boss permissions say. A
--- player is named by the lookup handle Players gave (data.ref), an exact
--- citizen id (data.subject), or a member's handle from orgGet
--- (data.member); never a name or a player id matched again now. Every
--- change is on the record (audit actions org_*, by = 'staff'). The ops
--- the page will ask for are listed in README, "Organisation requests".

local Util = CrimsonBoot.requireShared('util')
local Text = CrimsonBoot.requireShared('text')
local Org = CrimsonBoot.require('server.org.init')
local Feature = CrimsonBoot.require('server.lib.feature')
local L = CrimsonBoot.requireShared('locale').t

local StaffOps = {}

local deps

--- [op] = level, for the docs and the specs.
StaffOps.OPS = {}

--- Every action the organisation writes to the log, for its log area.
StaffOps.ACTIONS = {
    'org_created', 'org_member_hired', 'org_member_fired', 'org_member_role', 'org_member_suspended',
    'org_member_limits', 'org_member_grant', 'org_member_staff', 'org_role_created', 'org_role_edited',
    'org_role_deleted', 'org_role_power', 'org_role_pay', 'org_grant', 'org_limits', 'org_office_rule',
    'org_cut_set', 'org_cut', 'org_split_frozen', 'org_access', 'org_pick', 'org_funds_deposit',
    'org_funds_withdraw', 'org_funds_staff_deposit', 'org_bonus', 'org_location_set', 'org_location_removed',
    'org_notice', 'org_applied', 'org_application', 'org_renamed', 'org_layout', 'org_external_adopted',
    'org_external_reverted', 'org_funds_unrecorded', 'org_setup', 'org_funds_backend', 'org_member_invited',
    'org_invite_answered', 'org_application_superseded', 'org_cut_unavailable',
    'org_codename', 'org_salary', 'org_salary_max', 'org_payroll_run', 'org_payroll_skipped',
    'org_salary_applied', 'org_payroll_unconfirmed', 'org_payroll_refund_failed', 'org_payroll_refunded',
    'org_payroll_unmarked', 'org_funds_put_back', 'org_funds_recorded', 'org_funds_switch_recorded',
    'org_cut_given_back', 'org_cut_kept', 'org_funds_giveback_failed', 'org_funds_give_unmarked',
    'org_funds_give_raised', 'org_funds_give_unconfirmed', 'org_funds_deposit_refund_failed', 'org_armory_move_unknown',
    'org_contract_received', 'org_contract_assigned', 'org_contract_reassigned', 'org_contract_released',
    'org_accept_requested', 'org_accept_approved', 'org_accept_refused', 'org_accept_expired',
    'org_probation', 'org_probation_passed', 'org_duty', 'org_duty_forced', 'org_channel_post',
    'org_channel_removed', 'org_channel_mute', 'org_dossier',
    'org_armory_deposit', 'org_armory_withdraw', 'org_armory_limit', 'org_armory_stocked', 'org_armory_removed',
    'org_armory_refund_failed', 'org_stats_reset', 'org_strike', 'org_warning', 'org_discipline_overturned',
    'org_recruit_form', 'org_interview_note', 'org_added', 'org_removed',
    'org_rep_adjusted', 'org_payout_method', 'org_drop_left', 'org_drop_collected', 'org_drop_expired',
    'org_drop_settled', 'org_territory_hold', 'org_vehicle_out', 'org_vehicle_returned', 'org_vehicle_removed',
    'org_garage_offer', 'org_internal_requested', 'org_internal_decided',
}

local function staff(src)
    local cid = deps.panel.staffOf(src)
    return { staff = true, cid = cid or ('player ' .. tostring(src)), source = src }
end

local function said(ok, err, extra, message, okText)
    if ok then return true, nil, okText or L('org_staff_ops.done'), extra end
    return false, err, message or Org.message(err), extra
end

--- The member a request names: an organisation handle from orgGet, or a
--- player the panel looked up (ref), or an exact citizen id (subject).
local function memberCid(src, data)
    if data.member ~= nil then
        local who = staff(src)
        return Org.fromRef(who.cid, data.member)
    end
    local subject = deps.panel.writeSubject(data, src)
    return subject and subject.cid or nil
end

local function bool(v) return type(v) == 'boolean' and v or nil end

local function off()
    return false, Org.ERR.OFF, L('org_staff_ops.the_organisation_is_switched_off_config')
end

--- Whether this staff member may see who is behind an anonymous party.
local function identifies(src)
    return deps.panel.identifies and deps.panel.identifies(src) or false
end

local OPS = {}

-- Reads ------------------------------------------------------------------

OPS.orgGet = { 'read', function(src)
    return true, nil, nil, Org.staffView(staff(src).cid, identifies(src))
end }

OPS.bossPermsGet = { 'read', function(src)
    local view = Org.staffView(staff(src).cid, identifies(src))
    if not view.loaded then return off() end
    return true, nil, nil, { powers = view.powers, roles = view.roles, ceiling = view.ceiling,
        members = view.members, limits = view.limits, officeStaff = view.officeStaff }
end }

OPS.orgFunds = { 'read', function(src, data)
    return said(Org.fundsView(staff(src), tonumber(data.limit)))
end }

--- Records › Logs, area 'org' (Panel.logArea): every boss and staff
--- action on the organisation, newest first, at most data.limit (100); one
--- action with data.action (the grant history: 'org_grant').
local function orgLog(src, data)
    if not Org.current() then return off() end
    local limit = math.max(1, math.min(100, math.floor(tonumber(data.limit) or 50)))
    local only = Text.field(data.action, 40)
    local rows = {}
    for _, action in ipairs(StaffOps.ACTIONS) do
        if not only or only == action then
            for _, row in ipairs(deps.storage.auditByAction(action, limit) or {}) do rows[#rows + 1] = row end
        end
    end
    table.sort(rows, function(a, b) return (a.ts or 0) > (b.ts or 0) end)
    local canIdentify = identifies(src)
    -- Several organisations: only the one picked (data.org; the first by default).
    if Org.severalOn() then
        local here, kept = Org.current().id, {}
        for _, r in ipairs(rows) do
            local o = type(r.detail) == 'table' and r.detail.org or nil
            if o == nil or o == here then kept[#kept + 1] = r end
        end
        rows = kept
    end
    local out = {}
    for i = 1, math.min(#rows, limit) do
        local r = rows[i]
        local detail = Util.copy(type(r.detail) == 'table' and r.detail or {})
        if not canIdentify then
            -- No citizen id without IdentityAce: whoever a row names is
            -- 'a member' or 'a player'.
            local org = Org.current()
            for key, value in pairs(detail) do
                if type(value) == 'string' and (value == r.actor_cid or (org and org.members[value])
                    or key == 'member' or (key == 'id' and detail.subject == 'member')) then
                    detail[key] = L('org_staff_ops.a_member')
                end
            end
        end
        out[#out + 1] = { ts = r.ts, action = r.action, kind = r.kind, contract = r.contract_id,
            by = canIdentify and r.actor_cid or (detail.by == 'boss' and L('org_staff_ops.a_boss') or L('org_staff_ops.a_staff_member')),
            detail = detail }
    end
    return true, nil, nil, { rows = out }
end

-- Setup -------------------------------------------------------------------

--- Register (or register again) the job in qbx_core from the table, and
--- bring every online player in step: the Create / sync job button.
OPS.orgSetup = { 'write', function(src)
    if not Feature.on('Organisation') then return off() end
    local ok = Org.boot(false)
    if not ok then return false, Org.ERR.REFUSED, L('org_staff_ops.the_organisation_could_not_be_read') end
    Org.record('org_setup', staff(src), {})
    return true, nil, L('org_staff_ops.the_job_is_registered_and_every'), Org.staffView(staff(src).cid, identifies(src))
end }

OPS.orgRename = { 'write', function(src, data)
    return said(Org.rename(staff(src), Text.field(data.label, 128)))
end }

OPS.orgLayout = { 'write', function(src, data)
    return said(Org.layout(staff(src), type(data.layout) == 'table' and data.layout or nil))
end }

OPS.orgNotice = { 'write', function(src, data)
    local text = data.text
    if text ~= false and type(text) ~= 'string' then return false, Org.ERR.INVALID, L('org_staff_ops.write_the_notice') end
    return said(Org.notice(staff(src), text, data.broadcast == true))
end }

-- Roles -------------------------------------------------------------------

OPS.orgRoleSet = { 'write', function(src, data)
    local grade = tonumber(data.grade)
    if not grade then return false, Org.ERR.INVALID, L('org_staff_ops.give_the_roles_grade') end
    local org = Org.current()
    if not org then return off() end
    if not org.roles[grade] then
        return said(Org.roleCreate(staff(src), { grade = grade, name = Text.field(data.name, 64),
            label = Text.field(data.label, 128), pay = data.pay, isBoss = data.isBoss == true }))
    end
    return said(Org.roleEdit(staff(src), grade, { name = Text.field(data.name, 64), label = Text.field(data.label, 128),
        newGrade = data.newGrade, isBoss = bool(data.isBoss), locked = bool(data.locked), pay = data.pay }))
end }

OPS.orgRoleRemove = { 'write', function(src, data)
    return said(Org.roleDelete(staff(src), tonumber(data.grade)))
end }

OPS.orgRolePowers = { 'write', function(src, data)
    return said(Org.rolePower(staff(src), tonumber(data.grade), Text.field(data.power, 4), data.on))
end }

-- Members -----------------------------------------------------------------

OPS.orgMemberHire = { 'write', function(src, data)
    local subject, err, message = deps.panel.writeSubject(data, src)
    if not subject then return false, err, message end
    local actor = subject.actor
    return said(Org.hire(staff(src), { cid = subject.cid, name = actor and actor.name or subject.cid,
        source = actor and actor.source or nil }, data.grade ~= nil and tonumber(data.grade) or nil))
end }

OPS.orgMemberRole = { 'write', function(src, data)
    return said(Org.setRole(staff(src), memberCid(src, data), tonumber(data.grade)))
end }

OPS.orgMemberFire = { 'write', function(src, data)
    return said(Org.fire(staff(src), memberCid(src, data), Text.field(data.reason, 200)))
end }

OPS.orgMemberSuspend = { 'write', function(src, data)
    return said(Org.suspend(staff(src), memberCid(src, data), data.hours, Text.field(data.reason, 200)))
end }

OPS.orgMemberLimits = { 'write', function(src, data)
    return said(Org.memberLimits(staff(src), memberCid(src, data), data.maxAtOnce, data.cooldownMinutes))
end }

--- A member's own grant or deny (state), lock and codename, in one.
OPS.orgMemberOverride = { 'write', function(src, data)
    local cid = memberCid(src, data)
    if not cid then return false, Org.ERR.NOT_FOUND, Org.message(Org.ERR.NOT_FOUND) end
    if data.power ~= nil then
        local ok, err, extra, message = Org.memberGrant(staff(src), cid, Text.field(data.power, 4),
            Text.field(data.state, 8))
        if not ok then return said(ok, err, extra, message) end
    end
    if data.locked ~= nil or data.codename ~= nil then
        return said(Org.memberStaff(staff(src), cid, { locked = bool(data.locked),
            codename = (data.codename == false or type(data.codename) == 'string') and data.codename or nil }))
    end
    return true, nil, L('org_staff_ops.done')
end }

-- Boss permissions ----------------------------------------------------------

--- One cell, or a batch (cells = { { subject, id, power, state } }), all
--- checked before any is written. A member cell names the member's handle.
OPS.bossPermsSet = { 'write', function(src, data)
    local org = Org.current()
    if not org then return off() end
    local who = staff(src)
    local cells = type(data.cells) == 'table' and data.cells or { data }
    if #cells == 0 or #cells > 200 then return false, Org.ERR.INVALID, L('org_staff_ops.between_1_and_200_cells_at') end
    local plan = {}
    for i, cell in ipairs(cells) do
        if type(cell) ~= 'table' then return false, Org.ERR.INVALID, 'Cell ' .. i .. L('org_staff_ops.is_not_a_cell') end
        local subject = cell.subject
        local id
        if subject == 'role' then
            id = tonumber(cell.id)
            if not id or not org.roles[id] then return false, Org.ERR.NOT_FOUND, 'Cell ' .. i .. L('org_staff_ops.no_such_role') end
            if cell.state ~= 'allow' and cell.state ~= 'off' then
                return false, Org.ERR.INVALID, 'Cell ' .. i .. L('org_staff_ops.a_role_cell_is_allow_or')
            end
        elseif subject == 'member' then
            id = Org.fromRef(who.cid, cell.id)
            if not id or not org.members[id] then
                return false, Org.ERR.NOT_FOUND, 'Cell ' .. i .. L('org_staff_ops.that_member_handle_is_out_of')
            end
            if cell.state ~= 'allow' and cell.state ~= 'deny' and cell.state ~= 'inherit' then
                return false, Org.ERR.INVALID, 'Cell ' .. i .. L('org_staff_ops.a_member_cell_is_allow_deny')
            end
        else
            return false, Org.ERR.INVALID, 'Cell ' .. i .. L('org_staff_ops.a_role_or_a_member')
        end
        if not Org.Powers.resolve(cell.power) then return false, Org.ERR.INVALID, 'Cell ' .. i .. L('org_staff_ops.no_such_power') end
        plan[#plan + 1] = { subject, id, cell.power, cell.state }
    end
    for _, p in ipairs(plan) do Org.setCeiling(who, p[1], p[2], p[3], p[4]) end
    return true, nil, (L('org_staff_ops.cell_saved')):format(#plan)
end }

--- Revoke every power from one column at once.
OPS.bossPermsRevokeAll = { 'write', function(src, data)
    local org = Org.current()
    if not org then return off() end
    local who = staff(src)
    local subject, id, cells = data.subject, nil, nil
    if subject == 'role' then
        id = tonumber(data.id)
        cells = id and org.ceiling.role[id]
    elseif subject == 'member' then
        id = Org.fromRef(who.cid, data.id)
        cells = id and org.ceiling.member[id]
    end
    if not id then return false, Org.ERR.NOT_FOUND, Org.message(Org.ERR.NOT_FOUND) end
    local codes = {}
    for code in pairs(cells or {}) do codes[#codes + 1] = code end
    for _, code in ipairs(codes) do Org.setCeiling(who, subject, id, code, subject == 'role' and 'off' or 'inherit') end
    return true, nil, (L('org_staff_ops.power_revoked')):format(#codes)
end }

OPS.bossLimits = { 'write', function(src, data)
    return said(Org.setLimits(staff(src), type(data.limits) == 'table' and data.limits or nil))
end }

OPS.bossOfficeRule = { 'write', function(src, data)
    return said(Org.officeRule(staff(src), Text.field(data.power, 4), data.on))
end }

-- Money --------------------------------------------------------------------

OPS.orgCuts = { 'write', function(src, data)
    local kind = Text.field(data.kind, 8)
    local target
    if kind == 'role' then target = tonumber(data.grade) end
    if kind == 'member' then target = memberCid(src, data) end
    local percent = data.percent
    if percent ~= false and type(percent) ~= 'number' then return false, Org.ERR.INVALID, L('org_staff_ops.a_whole_percent_0_100') end
    return said(Org.setCut(staff(src), kind, target, percent))
end }

--- Staff money in (from nowhere) or out (to nowhere, or to a member as a
--- bonus), with a reason, idempotent by data.nonce.
OPS.orgFundsMove = { 'write', function(src, data)
    local who = staff(src)
    local reason = Text.field(data.reason, 200)
    if data.direction == 'deposit' then
        return said(Org.staffDeposit(who, data.amount, reason, data.nonce))
    elseif data.direction == 'withdraw' then
        return said(Org.withdraw(who, data.amount, reason, data.nonce))
    elseif data.direction == 'bonus' then
        return said(Org.bonus(who, memberCid(src, data), data.amount, reason, data.nonce))
    end
    return false, Org.ERR.INVALID, L('org_staff_ops.deposit_withdraw_or_bonus')
end }

--- Keep the funds in the other backend: { backend = 'internal' | 'bank',
--- abandon = true to leave a Renewed-Banking that is not started }. The
--- balance is carried across in two ledger rows.
OPS.orgFundsBackend = { 'write', function(src, data)
    local to = data.backend
    if to ~= 'internal' and to ~= 'bank' then return false, Org.ERR.INVALID, L('org_staff_ops.internal_or_bank') end
    local ok, err, extra, message = Org.fundsBackend(staff(src), to, data.abandon == true)
    if not ok then return said(ok, err, extra, message) end
    return true, nil, (L('org_staff_ops.the_funds_are_kept_in_now')):format(
        to == 'bank' and 'Renewed-Banking' or L('org_staff_ops.the_ledger'), extra.carried or 0), extra
end }

-- Payroll ------------------------------------------------------------------------

--- A role's salary, and (max) the most it may be paid: Config.Organisation.Payroll.
OPS.orgSalary = { 'write', function(src, data)
    local grade = tonumber(data.grade)
    if data.max ~= nil then
        if data.max ~= false and type(data.max) ~= 'number' then
            return false, Org.ERR.INVALID, L('org_staff_ops.a_whole_number_of_dollars_or')
        end
        return said(Org.setSalaryMax(staff(src), grade, data.max))
    end
    return said(Org.setSalary(staff(src), grade, data.amount))
end }

-- Contracts ------------------------------------------------------------------

OPS.orgAccess = { 'write', function(src, data)
    return said(Org.setAccess(staff(src), tonumber(data.grade), type(data.rules) == 'table' and data.rules or nil, 'K1'))
end }

OPS.orgPick = { 'write', function(src, data)
    local cid = (data.member ~= nil or data.ref ~= nil or data.subject ~= nil) and memberCid(src, data) or nil
    return said(Org.pick(staff(src), Text.field(data.id, 64), cid))
end }

-- Organisation extras (server/org/extras.lua) -----------------------------------

--- The channel's newest messages (orgGet carries the last 50 too).
OPS.orgChannelGet = { 'read', function(src, data)
    return said(Org.channelRead(staff(src), tonumber(data.limit)))
end }

--- Assign an organisation contract to a member (data.member), or send it
--- to the open board (data.release).
OPS.orgContractAssign = { 'write', function(src, data)
    local id = Text.field(data.id, 64)
    if data.release == true then return said(Org.releaseContract(staff(src), id)) end
    local cid = memberCid(src, data)
    if not cid then return false, Org.ERR.NOT_FOUND, Org.message(Org.ERR.NOT_FOUND) end
    return said(Org.assignContract(staff(src), id, cid))
end }

OPS.orgAcceptDecide = { 'write', function(src, data)
    return said(Org.decideAccept(staff(src), Text.field(data.id, 24), data.approve))
end }

--- End a member's probation (passed = true) or put them on it again (false).
OPS.orgProbation = { 'write', function(src, data)
    return said(Org.setProbation(staff(src), memberCid(src, data), data.passed))
end }

OPS.orgDutyOff = { 'write', function(src, data)
    return said(Org.forceOffDuty(staff(src), memberCid(src, data)))
end }

OPS.orgChannelPost = { 'write', function(src, data)
    return said(Org.channelPost(staff(src), Text.field(data.text, 8000)))
end }

OPS.orgChannelRemove = { 'write', function(src, data)
    return said(Org.channelRemove(staff(src), Text.field(data.id, 64)))
end }

OPS.orgChannelMute = { 'write', function(src, data)
    return said(Org.channelMute(staff(src), memberCid(src, data), data.hours))
end }

--- A dossier on an assigned organisation contract, or (clear) none.
OPS.orgDossier = { 'write', function(src, data)
    local id = Text.field(data.id, 64)
    if data.clear == true then return said(Org.writeDossier(staff(src), id, false)) end
    local notes = data.notes ~= nil and Text.field(data.notes, 8000) or nil
    if data.notes ~= nil and not notes then return false, Org.ERR.INVALID, Org.message(Org.ERR.INVALID) end
    return said(Org.writeDossier(staff(src), id, { notes = notes,
        spot = data.spot ~= nil and (Text.field(data.spot, 48) or 0) or nil,
        rules = data.rules ~= nil and (Text.field(data.rules, 16) or 0) or nil }))
end }

-- Organisation extras 2 (server/org/extras2.lua) --------------------------------

--- The armory: contents, role limits and its log (orgGet carries it too).
OPS.orgArmoryGet = { 'read', function(src)
    return said(Org.armoryView(staff(src)))
end }

--- A role's armory limit a day (data.grade, data.count; 0 is none).
OPS.orgArmoryLimit = { 'write', function(src, data)
    return said(Org.armoryLimit(staff(src), tonumber(data.grade), data.count))
end }

--- Stock the armory with an allowed item (data.item, data.count), or take
--- items out of a slot (data.slot, data.count, data.remove = true).
OPS.orgArmoryStock = { 'write', function(src, data)
    if data.remove == true then
        return said(Org.armoryStaff(staff(src), 'out', { slot = tonumber(data.slot), count = data.count }))
    end
    return said(Org.armoryStaff(staff(src), 'in', { item = Text.field(data.item, 64), count = data.count }))
end }

--- The leaderboard with every number (orgGet carries it too).
OPS.orgStatsGet = { 'read', function(src)
    return said(Org.leaderboard(staff(src)))
end }

--- Reset the organisation's counts: one member's, or (data.all) everybody's.
OPS.orgStatsReset = { 'write', function(src, data)
    if data.all == true then return said(Org.statsReset(staff(src), nil)) end
    local cid = memberCid(src, data)
    if not cid then return false, Org.ERR.NOT_FOUND, Org.message(Org.ERR.NOT_FOUND) end
    return said(Org.statsReset(staff(src), cid))
end }

--- A strike or a written warning (data.kind), with a reason.
OPS.orgStrike = { 'write', function(src, data)
    return said(Org.discipline(staff(src), memberCid(src, data), Text.field(data.kind, 8),
        Text.field(data.reason, 800)))
end }

--- Overturn a strike or a warning (data.id), with a reason.
OPS.orgOverturn = { 'write', function(src, data)
    return said(Org.overturn(staff(src), memberCid(src, data), Text.field(data.id, 24), Text.field(data.reason, 800)))
end }

--- The application form's questions (data.questions, a list).
OPS.orgRecruitForm = { 'write', function(src, data)
    if type(data.questions) ~= 'table' then return false, Org.ERR.INVALID, Org.message(Org.ERR.INVALID) end
    local list = {}
    for i = 1, math.min(#data.questions, 21) do list[i] = Text.field(data.questions[i], 800) or '' end
    return said(Org.recruitForm(staff(src), list))
end }

--- An interview note on an open application (data.id; data.clear).
OPS.orgInterviewNote = { 'write', function(src, data)
    local text = false
    if data.clear ~= true then text = Text.field(data.text, 8000) end
    if text == nil then return false, Org.ERR.INVALID, Org.message(Org.ERR.INVALID) end
    return said(Org.interviewNote(staff(src), Text.field(data.id, 48), text))
end }

-- Organisation extras 3 (server/org/extras3.lua) --------------------------------

--- Move the reputation by data.points (either way), with a reason.
OPS.orgRepAdjust = { 'write', function(src, data)
    return said(Org.repAdjust(staff(src), data.points, Text.field(data.reason, 800)))
end }

--- How members' payouts are handed over: data.method 'bank' or 'deaddrop'.
OPS.orgPayoutMethod = { 'write', function(src, data)
    return said(Org.setPayoutMethod(staff(src), Text.field(data.method, 12)))
end }

--- Settle a dead drop now (data.handle, from orgGet's rows): data.how 'release' or 'refund'.
OPS.orgDropSettle = { 'write', function(src, data)
    return said(Org.dropSettle(staff(src), Text.field(data.handle, 32), Text.field(data.how, 8)))
end }

--- Which approved models the organisation offers (data.models, a list).
OPS.orgGarageOffer = { 'write', function(src, data)
    if type(data.models) ~= 'table' then return false, Org.ERR.INVALID, Org.message(Org.ERR.INVALID) end
    local set = {}
    for i = 1, math.min(#data.models, 50) do
        local m = Text.field(data.models[i], 32)
        if m then set[m] = true end
    end
    return said(Org.garageOffer(staff(src), set))
end }

--- Take a member's garage vehicle away (data.member).
OPS.orgGarageRemove = { 'write', function(src, data)
    return said(Org.garageRemove(staff(src), memberCid(src, data)))
end }

--- Approve or decline an internal contract request (data.id, data.approve).
OPS.orgInternalDecide = { 'write', function(src, data)
    return said(Org.internalDecide(staff(src), Text.field(data.id, 32), data.approve))
end }

--- The organisation's activity log (orgGet carries the last 50).
OPS.orgActivityGet = { 'read', function(src, data)
    return said(Org.activity(staff(src), tonumber(data.limit)))
end }

-- Applications ------------------------------------------------------------------

OPS.orgApplication = { 'write', function(src, data)
    return said(Org.decide(staff(src), Text.field(data.id, 48), data.accept))
end }

--- Several organisations: an op runs on the one data.org names (its id),
--- the first where none is named; an id that names none is refused.
---@param fn function the op
---@return function
function StaffOps.scoped(fn)
    return function(src, data, ...)
        local wanted = type(data) == 'table' and data.org or nil
        if wanted == nil then return fn(src, data, ...) end
        local org = Org.byId(wanted)
        if not org then
            if not Feature.on('Organisation') then return off() end
            return false, Org.ERR.NOT_FOUND, L('org_staff_ops.no_such_organisation_refresh_the_page')
        end
        return Org.within(org, fn, src, data, ...)
    end
end

-- Several organisations (Config.Organisation.SeveralOrganisations) ------------

--- Add an organisation: data.job (its qbx_core job name) and data.label.
OPS.orgCreate = { 'write', function(src, data)
    local ok, err, extra, message = Org.create(staff(src), { job = Text.field(data.job, 32),
        label = Text.field(data.label, 128) })
    if not ok then return said(ok, err, extra, message) end
    return true, nil, (L('org_staff_ops.organisation_added_with_its_own_job')):format(extra.label, extra.id), extra
end }

--- Take one off the list (data.id): no members, empty funds, nothing held.
OPS.orgRemove = { 'write', function(src, data)
    return said(Org.removeOrg(staff(src), Text.field(data.id, 32)))
end }

--- Add every op to the panel.
---@param d table the wired modules
function StaffOps.register(d)
    deps = d
    if not (d.panel and d.panel.extend) then return end
    local levels = d.panel.LEVELS
    StaffOps.OPS = {}
    for name, entry in pairs(OPS) do
        local level = entry[1] == 'write' and levels.WRITE or levels.READ
        StaffOps.OPS[name] = level
        d.panel.extend(name, level, StaffOps.scoped(entry[2]))
    end
    if d.panel.logArea then d.panel.logArea('org', StaffOps.scoped(orgLog)) end
end

return StaffOps
end)
