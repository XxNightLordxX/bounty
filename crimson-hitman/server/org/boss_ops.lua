--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                 crimson-hitman - server/org/boss_ops.lua                  ║
    ║        The phone's requests for the organisation: members and bosses      ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- Every request here is an lb-phone custom app callback through the app's
--- own gate (App.addHandler: the engine's source, the job blacklist, the
--- flood guard and a token bucket, 'org' to read and 'orgWrite' to change),
--- and then the organisation's own checks on the server (Org.authorize: a
--- member, the power held after the staff ceiling, the office from the
--- server's own position, the rank rules), every field type-checked here.
--- Nothing a client sends names who is asking, and a member is named only
--- by a handle the server gave this viewer (Org.refFor). Off, every one
--- answers org_off before reading anything.

local Text = CrimsonBoot.requireShared('text')
local Org = CrimsonBoot.require('server.org.init')

local BossOps = {}

--- The requests, by name, with the bucket each spends and the power it
--- needs ('member' for any member, 'any' for anybody), for the docs and the
--- specs.
BossOps.LIST = {}

local function answer(ok, err, extra, message)
    if ok then return extra or { done = true } end
    local data = type(extra) == 'table' and extra or {}
    data.message = data.message or message or Org.message(err)
    return false, err, data
end

local function who(actor)
    return { cid = actor.cid, source = actor.source, name = actor.name }
end

local function memberOf(actor, payload)
    return Org.fromRef(actor.cid, type(payload) == 'table' and payload.member or nil)
end

local REQUESTS = {
    -- Reads -------------------------------------------------------------
    { 'orgMine', 'org', 'any', function(actor)
        return Org.mine(actor)
    end },
    { 'orgMembers', 'org', 'M1', function(actor)
        return answer(Org.members(who(actor)))
    end },
    { 'orgRoles', 'org', 'member', function(actor)
        return answer(Org.roles(who(actor)))
    end },
    { 'orgFunds', 'org', 'C8', function(actor, p)
        return answer(Org.fundsView(who(actor), tonumber(p.limit)))
    end },
    { 'orgApplications', 'org', 'N2', function(actor)
        return answer(Org.applications(who(actor)))
    end },
    { 'orgSpots', 'org', 'any', function(actor)
        if not Org.current() then return answer(false, Org.ERR.OFF) end
        return { rows = Org.spotsFor(actor.cid) }
    end },
    -- Members -----------------------------------------------------------
    { 'orgHire', 'orgWrite', 'M2', function(actor, p)
        local target = tonumber(p.target)
        local found = target and target > 0 and target == math.floor(target) and Org.identity().resolve(target)
        if not found then return answer(false, Org.ERR.NOT_FOUND) end
        return answer(Org.hire(who(actor), { cid = found.cid, name = found.name, source = found.source },
            p.grade ~= nil and tonumber(p.grade) or nil))
    end },
    { 'orgFire', 'orgWrite', 'M3', function(actor, p)
        return answer(Org.fire(who(actor), memberOf(actor, p), Text.field(p.reason, 200)))
    end },
    { 'orgSetRole', 'orgWrite', 'M4', function(actor, p)
        return answer(Org.setRole(who(actor), memberOf(actor, p), tonumber(p.grade)))
    end },
    { 'orgSuspend', 'orgWrite', 'M5', function(actor, p)
        return answer(Org.suspend(who(actor), memberOf(actor, p), p.hours, Text.field(p.reason, 200)))
    end },
    { 'orgMemberLimits', 'orgWrite', 'M6', function(actor, p)
        return answer(Org.memberLimits(who(actor), memberOf(actor, p), p.maxAtOnce, p.cooldownMinutes))
    end },
    -- A codename (Config.Organisation.Codenames): one's own with no member,
    -- or (M7) a member's below the boss. false clears it.
    { 'orgCodename', 'orgWrite', 'M7', function(actor, p)
        local cid = nil
        if p.member ~= nil then
            cid = memberOf(actor, p)
            if not cid then return answer(false, Org.ERR.NOT_FOUND) end
        end
        local name = p.codename == false and false or Text.field(p.codename, 64)
        if name == nil then return answer(false, Org.ERR.INVALID) end
        return answer(Org.setCodename(who(actor), cid, name))
    end },
    { 'orgMemberGrant', 'orgWrite', 'D2', function(actor, p)
        return answer(Org.memberGrant(who(actor), memberOf(actor, p), Text.field(p.power, 4), Text.field(p.state, 8)))
    end },
    -- Roles -------------------------------------------------------------
    { 'orgRoleCreate', 'orgWrite', 'R1', function(actor, p)
        return answer(Org.roleCreate(who(actor), { grade = p.grade, name = Text.field(p.name, 64),
            label = Text.field(p.label, 128), pay = p.pay }))
    end },
    { 'orgRoleEdit', 'orgWrite', 'R2', function(actor, p)
        return answer(Org.roleEdit(who(actor), tonumber(p.grade), { name = Text.field(p.name, 64),
            label = Text.field(p.label, 128), newGrade = p.newGrade }))
    end },
    { 'orgRoleDelete', 'orgWrite', 'R3', function(actor, p)
        return answer(Org.roleDelete(who(actor), tonumber(p.grade)))
    end },
    { 'orgRolePowers', 'orgWrite', 'R4', function(actor, p)
        return answer(Org.rolePower(who(actor), tonumber(p.grade), Text.field(p.power, 4), p.on))
    end },
    { 'orgRolePay', 'orgWrite', 'P1', function(actor, p)
        return answer(Org.rolePay(who(actor), tonumber(p.grade), p.pay))
    end },
    -- A role's salary (Config.Organisation.Payroll).
    { 'orgSalary', 'orgWrite', 'P3', function(actor, p)
        return answer(Org.setSalary(who(actor), tonumber(p.grade), p.amount))
    end },
    -- Pay and money -----------------------------------------------------
    { 'orgBonus', 'orgWrite', 'P2', function(actor, p)
        return answer(Org.bonus(who(actor), memberOf(actor, p), p.amount, Text.field(p.reason, 200), p.nonce))
    end },
    { 'orgSetCut', 'orgWrite', 'C1-C5', function(actor, p)
        local kind = Text.field(p.kind, 8)
        local target = kind == 'member' and memberOf(actor, p) or (kind == 'role' and tonumber(p.grade)) or nil
        if (kind == 'member' or kind == 'role') and target == nil then return answer(false, Org.ERR.NOT_FOUND) end
        local percent = p.percent
        if percent ~= false and type(percent) ~= 'number' then return answer(false, Org.ERR.INVALID) end
        return answer(Org.setCut(who(actor), kind, target, percent))
    end },
    { 'orgDeposit', 'orgWrite', 'C6', function(actor, p)
        return answer(Org.deposit(who(actor), p.amount, Text.field(p.account, 8), p.nonce))
    end },
    { 'orgWithdraw', 'orgWrite', 'C7', function(actor, p)
        return answer(Org.withdraw(who(actor), p.amount, Text.field(p.reason, 200), p.nonce))
    end },
    -- Contracts ---------------------------------------------------------
    { 'orgAccess', 'orgWrite', 'K1', function(actor, p)
        return answer(Org.setAccess(who(actor), tonumber(p.grade), type(p.rules) == 'table' and p.rules or nil, 'K1'))
    end },
    { 'orgPick', 'orgWrite', 'K2', function(actor, p)
        local cid = p.member ~= nil and memberOf(actor, p) or nil
        if p.member ~= nil and not cid then return answer(false, Org.ERR.NOT_FOUND) end
        return answer(Org.pick(who(actor), Text.field(p.id, 64), cid))
    end },
    { 'orgRoleCooldown', 'orgWrite', 'K3', function(actor, p)
        local minutes = p.minutes
        if minutes ~= false and type(minutes) ~= 'number' then return answer(false, Org.ERR.INVALID) end
        return answer(Org.setAccess(who(actor), tonumber(p.grade), { cooldownMinutes = minutes }, 'K3'))
    end },
    -- Locations ---------------------------------------------------------
    { 'orgPlaceHere', 'orgWrite', 'L1-L3', function(actor, p)
        local kind = Text.field(p.kind, 8)
        if kind ~= 'office' and kind ~= 'signup' and kind ~= 'meeting' then return answer(false, Org.ERR.INVALID) end
        return answer(Org.placeSpot(who(actor), { kind = kind, id = Text.field(p.id, 48),
            label = Text.field(p.label, 128), here = true }))
    end },
    { 'orgRemoveSpot', 'orgWrite', 'L2-L3', function(actor, p)
        return answer(Org.removeSpot(who(actor), Text.field(p.id, 48)))
    end },
    -- Notices -----------------------------------------------------------
    { 'orgNotice', 'orgWrite', 'N1', function(actor, p)
        local text = p.text
        if text ~= false and type(text) ~= 'string' then return answer(false, Org.ERR.INVALID) end
        return answer(Org.notice(who(actor), text, p.broadcast == true))
    end },
    { 'orgDecide', 'orgWrite', 'N2', function(actor, p)
        return answer(Org.decide(who(actor), Text.field(p.id, 48), p.accept))
    end },
    { 'orgApply', 'orgWrite', 'any', function(actor, p)
        return answer(Org.apply(actor, p.text ~= nil and Text.field(p.text, 600) or nil))
    end },
    -- The invited player's own answer to a boss's hire (Org.answerInvite).
    { 'orgInviteAnswer', 'orgWrite', 'any', function(actor, p)
        return answer(Org.answerInvite(actor, Text.field(p.id, 48), p.accept))
    end },
    -- Settings ----------------------------------------------------------
    { 'orgRename', 'orgWrite', 'S1', function(actor, p)
        return answer(Org.rename(who(actor), Text.field(p.label, 128)))
    end },
    { 'orgLayout', 'orgWrite', 'S2', function(actor, p)
        return answer(Org.layout(who(actor), type(p.layout) == 'table' and p.layout or nil))
    end },
    { 'orgOfficeRule', 'orgWrite', 'S3', function(actor, p)
        return answer(Org.officeRule(who(actor), Text.field(p.power, 4), p.on))
    end },
}

--- Register every request with the app's gate, and the spot a player uses
--- in the world. Each answers org_off while the organisation is off.
---@param deps table the wired modules
function BossOps.register(deps)
    if not (deps.app and deps.app.addHandler) then return end
    BossOps.LIST = {}
    for _, entry in ipairs(REQUESTS) do
        local name, bucket, power, fn = entry[1], entry[2], entry[3], entry[4]
        BossOps.LIST[#BossOps.LIST + 1] = { name = name, bucket = bucket, power = power }
        deps.app.addHandler(name, bucket, function(actor, payload)
            if not Org.enabled() and name ~= 'orgMine' then return answer(false, Org.ERR.OFF) end
            if type(payload) ~= 'table' then payload = {} end
            return fn(actor, payload)
        end)
    end

    -- The ox_target option on a spot (client/org.lua): checked against the
    -- server's own position, answered with a notice. Only the spot's id is
    -- read from the client.
    RegisterNetEvent('crimson-hitman:orgUse', function(id)
        local src = source
        if src <= 0 or not Org.enabled() then return end
        if not deps.app.floodOk(src, 'orgUse') then return end
        if type(id) ~= 'string' or #id > 48 then return end
        Org.useSpot(src, id)
    end)
end

return BossOps
