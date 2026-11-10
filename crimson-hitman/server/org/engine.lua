--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                  crimson-hitman - server/org/engine.lua                   ║
    ║      Who holds which power, and what a boss may do to whom (the rules)    ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- Pure functions over one organisation's state (server/org/init.lua). The
--- model (docs plan §5.1, §5.5):
---
---   * A power reaches the organisation only from staff: an Allow cell in
---     Boss permissions for a role or one member (the ceiling), or a power
---     staff put on a role or a member directly. A Deny cell on a member
---     takes it from them whatever else says so.
---   * A boss passes on only what they hold: a power a boss put on a role
---     (R4) or on a member (D2) is active only while that boss still holds
---     it, is still a member and still outranks who has it. Revoking it from
---     the boss makes every grant they made of it inactive, not deleted, so
---     giving it back restores them (rule 4). A loop of grants holds nothing.
---   * A member's own deny takes the power whatever else says.
---   * Ranks are grades: higher is senior. A boss acts only on members, and
---     assigns only grades, below their own; with D3, a grade equal to their
---     own (never above). Never on themselves, never on a locked role or
---     member, and never so that nobody holds the top boss role.
---
--- TAKE (Take contracts) is a role right, not a boss power: no ceiling, and
--- any holder of R4 (a role) or D2 (a member) may pass it below them.

local Powers = CrimsonBoot.require('server.org.powers')

local Engine = {}

--- The staff ceiling for one member and power: 'allow', 'deny' or nil.
---@param org table
---@param member table
---@param code string
---@return string|nil
function Engine.ceiling(org, member, code)
    local own = org.ceiling.member[member.cid]
    local cell = own and own[code]
    if cell == 'deny' or cell == 'allow' then return cell end
    local byRole = org.ceiling.role[member.grade]
    if byRole and byRole[code] == 'allow' then return 'allow' end
    return nil
end

local holds

--- Whether a grant (a role's power or a member's own) is in force for the
--- member who has it.
---@param entry table { by = 'staff' | cid }
---@param via string 'R4' for a role's power, 'D2' for a member's own grant
local function sourceActive(org, entry, holder, code, via, visited)
    if type(entry) ~= 'table' then return false end
    if entry.by == 'staff' then return true end
    local granterCid = entry.by
    if type(granterCid) ~= 'string' or granterCid == holder.cid then return false end
    local granter = org.members[granterCid]
    if not granter then return false end
    if visited[granterCid] then return false end
    -- Still above who has it (or level with D3, which never reaches above).
    if granter.grade < holder.grade then return false end
    if granter.grade == holder.grade and not holds(org, granter, 'D3', visited) then return false end
    if code == Powers.TAKE then return holds(org, granter, via, visited) end
    return holds(org, granter, code, visited)
end

---@param org table
---@param member table
---@param code string
---@param visited table|nil
---@return boolean
holds = function(org, member, code, visited)
    if type(member) ~= 'table' or not code then return false end
    visited = visited or {}
    if visited[member.cid] then return false end
    visited[member.cid] = true
    local function done(v) visited[member.cid] = nil return v end
    if type(member.denies) == 'table' and member.denies[code] then return done(false) end
    if code ~= Powers.TAKE then
        local cell = Engine.ceiling(org, member, code)
        if cell == 'deny' then return done(false) end
        if cell == 'allow' then return done(true) end
    end
    local role = org.roles[member.grade]
    local entry = role and type(role.powers) == 'table' and role.powers[code]
    if entry and sourceActive(org, entry, member, code, 'R4', visited) then return done(true) end
    entry = type(member.grants) == 'table' and member.grants[code]
    if entry and sourceActive(org, entry, member, code, 'D2', visited) then return done(true) end
    return done(false)
end

--- Whether a member holds a power now, after the ceiling, every deny and
--- every granter's own standing.
---@param org table
---@param cid string
---@param code string
---@return boolean
function Engine.holds(org, cid, code)
    code = Powers.resolve(code, true)
    local member = code and org.members[cid]
    if not member then return false end
    return holds(org, member, code, {})
end

--- Every power a member holds, as a set.
---@return table [code] = true
function Engine.held(org, cid)
    local out = {}
    for _, p in ipairs(Powers.LIST) do
        if Engine.holds(org, cid, p.code) then out[p.code] = true end
    end
    if Engine.holds(org, cid, Powers.TAKE) then out[Powers.TAKE] = true end
    return out
end

--- Why a grant someone has is not in force, for the panel: nil when it is.
---@return string|nil 'granter_lost' | 'granter_gone' | 'outranked'
function Engine.inactiveWhy(org, holderCid, entry, code)
    if type(entry) ~= 'table' or entry.by == 'staff' then return nil end
    local holder = org.members[holderCid]
    local granter = org.members[entry.by]
    if not granter or not holder then return 'granter_gone' end
    if granter.grade < holder.grade then return 'outranked' end
    if granter.grade == holder.grade and not Engine.holds(org, granter.cid, 'D3') then return 'outranked' end
    if code == Powers.TAKE then return nil end
    if not Engine.holds(org, granter.cid, code) then return 'granter_lost' end
    return nil
end

--- The top boss grade: the highest grade marked boss, or nil.
---@return integer|nil
function Engine.topBossGrade(org)
    local top
    for grade, role in pairs(org.roles) do
        if role.is_boss and (not top or grade > top) then top = grade end
    end
    return top
end

--- How many members hold a grade.
function Engine.countAt(org, grade)
    local n = 0
    for _, m in pairs(org.members) do if m.grade == grade then n = n + 1 end end
    return n
end

--- Whether taking `cid` off its grade (fired, moved, its role moved or
--- deleted) would leave the top boss role empty. Staff may; nobody else.
---@return boolean
function Engine.wouldLeaveNoBoss(org, cid, newGrade)
    local top = Engine.topBossGrade(org)
    local member = org.members[cid]
    if not top or not member or member.grade ~= top then return false end
    if newGrade ~= nil and newGrade >= top then return false end
    return Engine.countAt(org, top) <= 1
end

--- What a boss may do to another member: nil, or why not.
---@param actorCid string
---@param targetCid string
---@return string|nil 'self' | 'not_member' | 'rank' | 'locked'
function Engine.mayActOn(org, actorCid, targetCid)
    local actor, target = org.members[actorCid], org.members[targetCid]
    if not actor then return 'not_member' end
    if not target then return 'not_member' end
    if actorCid == targetCid then return 'self' end
    if target.locked then return 'locked' end
    if target.grade >= actor.grade then return 'rank' end
    return nil
end

--- Whether a boss may give a member, a hire or a role this grade: below
--- their own, or level with it holding D3. Never above.
---@return string|nil why not
function Engine.mayAssignGrade(org, actorCid, grade)
    local actor = org.members[actorCid]
    if not actor then return 'not_member' end
    if type(grade) ~= 'number' then return 'invalid' end
    if grade > actor.grade then return 'rank' end
    if grade == actor.grade and not Engine.holds(org, actorCid, 'D3') then return 'rank' end
    return nil
end

--- Whether a boss may touch a role: one strictly below them, not locked.
---@return string|nil why not
function Engine.mayEditRole(org, actorCid, grade)
    local actor, role = org.members[actorCid], org.roles[grade]
    if not actor then return 'not_member' end
    if not role then return 'not_found' end
    if role.locked then return 'locked' end
    if grade >= actor.grade then return 'rank' end
    return nil
end

--- Whether a boss may hand on a power: they hold it themselves, and (for
--- TAKE) the delegation power that hands it on.
---@param via string 'R4' | 'D2'
---@return string|nil why not
function Engine.mayDelegate(org, actorCid, code, via)
    if not Engine.holds(org, actorCid, via) then return 'no_power' end
    if code == Powers.TAKE then return nil end
    if not Engine.holds(org, actorCid, code) then return 'not_held' end
    return nil
end

--- Whether a power needs the boss office for this organisation: staff's
--- list (the defaults until staff change it), plus what bosses added (S3).
function Engine.needsOffice(org, code)
    local s = org.settings or {}
    local staff = type(s.officeStaff) == 'table' and s.officeStaff or Powers.officeDefaults()
    if staff[code] then return true end
    return type(s.officeBoss) == 'table' and s.officeBoss[code] == true
end

return Engine
