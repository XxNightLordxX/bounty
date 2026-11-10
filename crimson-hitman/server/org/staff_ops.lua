--[[
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
local Org = CrimsonBoot.require('server.org.init')

local StaffOps = {}

local deps

--- [op] = level, for the docs and the specs.
StaffOps.OPS = {}

--- Every action the organisation writes to the log, for orgAudit.
StaffOps.ACTIONS = {
    'org_created', 'org_member_hired', 'org_member_fired', 'org_member_role', 'org_member_suspended',
    'org_member_limits', 'org_member_grant', 'org_member_staff', 'org_role_created', 'org_role_edited',
    'org_role_deleted', 'org_role_power', 'org_role_pay', 'org_grant', 'org_limits', 'org_office_rule',
    'org_cut_set', 'org_cut', 'org_split_frozen', 'org_access', 'org_pick', 'org_funds_deposit',
    'org_funds_withdraw', 'org_funds_staff_deposit', 'org_bonus', 'org_location_set', 'org_location_removed',
    'org_notice', 'org_applied', 'org_application', 'org_renamed', 'org_layout', 'org_external_adopted',
    'org_external_reverted', 'org_funds_unrecorded', 'org_setup', 'org_funds_backend', 'org_member_invited',
    'org_invite_answered', 'org_application_superseded', 'org_cut_unavailable',
}

local function staff(src)
    local cid = deps.panel.staffOf(src)
    return { staff = true, cid = cid or ('player ' .. tostring(src)), source = src }
end

local function said(ok, err, extra, message, okText)
    if ok then return true, nil, okText or 'Done.', extra end
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
local function str(v, max) return type(v) == 'string' and #v <= max and v or nil end

local function off()
    return false, Org.ERR.OFF, 'The organisation is switched off (Config.Organisation.Enabled).'
end

local OPS = {}

-- Reads ------------------------------------------------------------------

OPS.orgGet = { 'read', function(src)
    return true, nil, nil, Org.staffView(staff(src).cid)
end }

OPS.bossPermsGet = { 'read', function(src)
    local view = Org.staffView(staff(src).cid)
    if not view.loaded then return off() end
    return true, nil, nil, { powers = view.powers, roles = view.roles, ceiling = view.ceiling,
        members = view.members, limits = view.limits, officeStaff = view.officeStaff }
end }

OPS.orgFunds = { 'read', function(src, data)
    return said(Org.fundsView(staff(src), tonumber(data.limit)))
end }

OPS.orgAudit = { 'read', function(src, data)
    if not Org.current() then return off() end
    local limit = math.max(1, math.min(100, math.floor(tonumber(data.limit) or 50)))
    local only = str(data.action, 40)
    local rows = {}
    for _, action in ipairs(StaffOps.ACTIONS) do
        if not only or only == action then
            for _, row in ipairs(deps.storage.auditByAction(action, limit) or {}) do rows[#rows + 1] = row end
        end
    end
    table.sort(rows, function(a, b) return (a.ts or 0) > (b.ts or 0) end)
    local canIdentify = deps.panel.identifies and deps.panel.identifies(src)
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
                    detail[key] = 'a member'
                end
            end
        end
        out[#out + 1] = { ts = r.ts, action = r.action, kind = r.kind, contract = r.contract_id,
            by = canIdentify and r.actor_cid or (detail.by == 'boss' and 'a boss' or 'a staff member'),
            detail = detail }
    end
    return true, nil, nil, { rows = out }
end }

--- Where the staff member's character stands, read by the server: for Use
--- my position on a location row.
OPS.orgMyPosition = { 'read', function(src)
    local at = Org.positionOf(src)
    if not at then return false, Org.ERR.NOT_FOUND, 'The server cannot see your character right now.' end
    return true, nil, nil, { x = at.x, y = at.y, z = at.z, heading = at.h }
end }

-- Setup -------------------------------------------------------------------

--- Register (or register again) the job in qbx_core from the table, and
--- bring every online player in step: the Create / sync job button.
OPS.orgSetup = { 'write', function(src)
    if not Org.enabled() then return off() end
    local ok = Org.boot(false)
    if not ok then return false, Org.ERR.REFUSED, 'The organisation could not be read; the console says why.' end
    Org.record('org_setup', staff(src), {})
    return true, nil, 'The job is registered and every online member is in step.', Org.staffView(staff(src).cid)
end }

OPS.orgRename = { 'write', function(src, data)
    return said(Org.rename(staff(src), str(data.label, 128)))
end }

OPS.orgLayout = { 'write', function(src, data)
    return said(Org.layout(staff(src), type(data.layout) == 'table' and data.layout or nil))
end }

OPS.orgNotice = { 'write', function(src, data)
    local text = data.text
    if text ~= false and type(text) ~= 'string' then return false, Org.ERR.INVALID, 'Write the notice.' end
    return said(Org.notice(staff(src), text, data.broadcast == true))
end }

-- Roles -------------------------------------------------------------------

OPS.orgRoleSet = { 'write', function(src, data)
    local grade = tonumber(data.grade)
    if not grade then return false, Org.ERR.INVALID, 'Give the role\'s grade.' end
    local org = Org.current()
    if not org then return off() end
    if not org.roles[grade] then
        return said(Org.roleCreate(staff(src), { grade = grade, name = str(data.name, 64), label = str(data.label, 128),
            pay = data.pay, isBoss = data.isBoss == true }))
    end
    return said(Org.roleEdit(staff(src), grade, { name = str(data.name, 64), label = str(data.label, 128),
        newGrade = data.newGrade, isBoss = bool(data.isBoss), locked = bool(data.locked), pay = data.pay }))
end }

OPS.orgRoleRemove = { 'write', function(src, data)
    return said(Org.roleDelete(staff(src), tonumber(data.grade)))
end }

OPS.orgRolePowers = { 'write', function(src, data)
    return said(Org.rolePower(staff(src), tonumber(data.grade), str(data.power, 4), data.on))
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
    return said(Org.fire(staff(src), memberCid(src, data), str(data.reason, 200)))
end }

OPS.orgMemberSuspend = { 'write', function(src, data)
    return said(Org.suspend(staff(src), memberCid(src, data), data.hours, str(data.reason, 200)))
end }

OPS.orgMemberLimits = { 'write', function(src, data)
    return said(Org.memberLimits(staff(src), memberCid(src, data), data.maxAtOnce, data.cooldownMinutes))
end }

--- A member's own grant or deny (state), lock and codename, in one.
OPS.orgMemberOverride = { 'write', function(src, data)
    local cid = memberCid(src, data)
    if not cid then return false, Org.ERR.NOT_FOUND, Org.message(Org.ERR.NOT_FOUND) end
    if data.power ~= nil then
        local ok, err, extra, message = Org.memberGrant(staff(src), cid, str(data.power, 4), str(data.state, 8))
        if not ok then return said(ok, err, extra, message) end
    end
    if data.locked ~= nil or data.codename ~= nil then
        return said(Org.memberStaff(staff(src), cid, { locked = bool(data.locked),
            codename = (data.codename == false or type(data.codename) == 'string') and data.codename or nil }))
    end
    return true, nil, 'Done.'
end }

-- Boss permissions ----------------------------------------------------------

--- One cell, or a batch (cells = { { subject, id, power, state } }), all
--- checked before any is written. A member cell names the member's handle.
OPS.bossPermsSet = { 'write', function(src, data)
    local org = Org.current()
    if not org then return off() end
    local who = staff(src)
    local cells = type(data.cells) == 'table' and data.cells or { data }
    if #cells == 0 or #cells > 200 then return false, Org.ERR.INVALID, 'Between 1 and 200 cells at once.' end
    local plan = {}
    for i, cell in ipairs(cells) do
        if type(cell) ~= 'table' then return false, Org.ERR.INVALID, 'Cell ' .. i .. ' is not a cell.' end
        local subject = cell.subject
        local id
        if subject == 'role' then
            id = tonumber(cell.id)
            if not id or not org.roles[id] then return false, Org.ERR.NOT_FOUND, 'Cell ' .. i .. ': no such role.' end
            if cell.state ~= 'allow' and cell.state ~= 'off' then
                return false, Org.ERR.INVALID, 'Cell ' .. i .. ': a role cell is allow or off.'
            end
        elseif subject == 'member' then
            id = Org.fromRef(who.cid, cell.id)
            if not id or not org.members[id] then
                return false, Org.ERR.NOT_FOUND, 'Cell ' .. i .. ': that member handle is out of date.'
            end
            if cell.state ~= 'allow' and cell.state ~= 'deny' and cell.state ~= 'inherit' then
                return false, Org.ERR.INVALID, 'Cell ' .. i .. ': a member cell is allow, deny or inherit.'
            end
        else
            return false, Org.ERR.INVALID, 'Cell ' .. i .. ': a role or a member.'
        end
        if not Org.Powers.resolve(cell.power) then return false, Org.ERR.INVALID, 'Cell ' .. i .. ': no such power.' end
        plan[#plan + 1] = { subject, id, cell.power, cell.state }
    end
    for _, p in ipairs(plan) do Org.setCeiling(who, p[1], p[2], p[3], p[4]) end
    return true, nil, ('%d cell(s) saved.'):format(#plan)
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
    return true, nil, ('%d power(s) revoked.'):format(#codes)
end }

OPS.bossLimits = { 'write', function(src, data)
    return said(Org.setLimits(staff(src), type(data.limits) == 'table' and data.limits or nil))
end }

OPS.bossOfficeRule = { 'write', function(src, data)
    return said(Org.officeRule(staff(src), str(data.power, 4), data.on))
end }

-- Money --------------------------------------------------------------------

OPS.orgCuts = { 'write', function(src, data)
    local kind = str(data.kind, 8)
    local target
    if kind == 'role' then target = tonumber(data.grade) end
    if kind == 'member' then target = memberCid(src, data) end
    local percent = data.percent
    if percent ~= false and type(percent) ~= 'number' then return false, Org.ERR.INVALID, 'A whole percent, 0-100.' end
    return said(Org.setCut(staff(src), kind, target, percent))
end }

--- Staff money in (from nowhere) or out (to nowhere, or to a member as a
--- bonus), with a reason, idempotent by data.nonce.
OPS.orgFundsMove = { 'write', function(src, data)
    local who = staff(src)
    local reason = str(data.reason, 200)
    if data.direction == 'deposit' then
        return said(Org.staffDeposit(who, data.amount, reason, data.nonce))
    elseif data.direction == 'withdraw' then
        return said(Org.withdraw(who, data.amount, reason, data.nonce))
    elseif data.direction == 'bonus' then
        return said(Org.bonus(who, memberCid(src, data), data.amount, reason, data.nonce))
    end
    return false, Org.ERR.INVALID, 'Deposit, withdraw or bonus.'
end }

--- Keep the funds in the other backend: { backend = 'internal' | 'bank',
--- abandon = true to leave a Renewed-Banking that is not started }. The
--- balance is carried across in two ledger rows.
OPS.orgFundsBackend = { 'write', function(src, data)
    local to = data.backend
    if to ~= 'internal' and to ~= 'bank' then return false, Org.ERR.INVALID, 'internal or bank.' end
    local ok, err, extra, message = Org.fundsBackend(staff(src), to, data.abandon == true)
    if not ok then return said(ok, err, extra, message) end
    return true, nil, ('The funds are kept in %s now; %d carried across.'):format(
        to == 'bank' and 'Renewed-Banking' or 'the ledger', extra.carried or 0), extra
end }

-- Contracts ------------------------------------------------------------------

OPS.orgAccess = { 'write', function(src, data)
    return said(Org.setAccess(staff(src), tonumber(data.grade), type(data.rules) == 'table' and data.rules or nil, 'K1'))
end }

OPS.orgPick = { 'write', function(src, data)
    local cid = (data.member ~= nil or data.ref ~= nil or data.subject ~= nil) and memberCid(src, data) or nil
    return said(Org.pick(staff(src), str(data.id, 64), cid))
end }

-- Locations -------------------------------------------------------------------

--- A spot from typed figures, or (here = true) where the staff member
--- stands, read by the server.
OPS.orgLocationSet = { 'write', function(src, data)
    return said(Org.placeSpot(staff(src), { kind = str(data.kind, 8), id = str(data.id, 48),
        label = str(data.label, 128), radius = data.radius, blip = bool(data.blip), enabled = bool(data.enabled),
        here = data.here == true, x = data.x, y = data.y, z = data.z, heading = data.heading }))
end }

OPS.orgLocationRemove = { 'write', function(src, data)
    return said(Org.removeSpot(staff(src), str(data.id, 48)))
end }

-- Applications ------------------------------------------------------------------

OPS.orgApplication = { 'write', function(src, data)
    return said(Org.decide(staff(src), str(data.id, 48), data.accept))
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
        d.panel.extend(name, level, entry[2])
    end
end

return StaffOps
