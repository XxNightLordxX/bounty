--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                   crimson-hitman - server/org/init.lua                    ║
    ║   The hitman organisation: state, the job, cuts, the accept gate, places  ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- Config.Organisation (README, Optional features). Off as shipped, and then
--- nothing here runs: no row is read, no job is registered, no hook does
--- more than read one switch, and every request answers org_off.
---
--- On, the organisation is one qbx_core job (Config.Organisation.JobName)
--- whose roles, members, Boss permissions, places, cuts and funds live in
--- this resource's own tables (server/org/schema.lua), read once at start
--- and kept in memory, every change written through. Every change, by staff
--- (server/org/staff_ops.lua) or a boss (server/org/boss_ops.lua), goes
--- through the functions below, which check it, write it, tell qbx_core and
--- put it on the record (audit actions org_*).

local Util = CrimsonBoot.requireShared('util')
local Log = CrimsonBoot.requireShared('log')
local Powers = CrimsonBoot.require('server.org.powers')
local Engine = CrimsonBoot.require('server.org.engine')
local Jobs = CrimsonBoot.require('server.org.jobs')
local Funds = CrimsonBoot.require('server.org.funds')

local Org = {}

Org.Powers, Org.Engine, Org.Jobs, Org.Funds = Powers, Engine, Jobs, Funds

local deps

--- The organisation in memory, or nil while none is loaded:
--- { id, job, label, jobType, settings, created_at,
---   roles = { [grade] = role }, members = { [cid] = member },
---   ceiling = { role = { [grade] = { [code] = 'allow' } },
---               member = { [cid] = { [code] = 'allow' | 'deny' } } },
---   locations = { [id] = location }, applications = { [id] = row } }
local State = nil

--- The cut frozen on each contract a member took: [contract:cid] = row.
local Splits = {}

--- When each member last accepted, for the cooldowns: [cid] = os.time().
local LastAccept = {}

--- What each boss did lately, for the per-day and cooldown bounds:
--- [cid] = { fires = { ts }, promotions = { ts } }
local Recent = {}

--- Hires a boss offered, waiting for the player to accept them in the app:
--- [cid] = { id, cid, grade, by (the boss's cid), at, expires }. Kept in
--- memory only: a restart forgets them, and the boss asks again.
local Invites = {}

--- When each player last loaded (Org.playerLoaded), against when the job
--- was registered this process (Jobs.register), by a sequence: a player
--- who loaded after it is one qbx_core could show the job to.
local LoadedSeq, RegisteredSeq, Seq = {}, nil, 0

--- Member handles given to each viewer: [viewerCid] = { [ref] = { cid, at } }
local Refs, RefSeq = {}, 0
local REF_SECONDS, REFS_PER_VIEWER = 1800, 200

--- Refusals, by code. Not in CH.ERR: the phone's Organisation tab, when it
--- is built, words them; every one carries a `message` meanwhile.
Org.ERR = {
    OFF = 'org_off', NOT_MEMBER = 'org_not_member', NO_POWER = 'org_no_power',
    OFFICE = 'org_office', RANK = 'org_rank', SELF = 'org_self', LOCKED = 'org_locked',
    LAST_BOSS = 'org_last_boss', BOUNDS = 'org_bounds', COOLDOWN = 'org_cooldown',
    LIMIT = 'org_limit', NOT_FOUND = 'org_not_found', REFUSED = 'org_refused',
    SHORT = 'org_short', BUSY = 'org_busy', MEMBERS_ONLY = 'org_members_only',
    RULE = 'org_rule', ALREADY = 'org_already', OFF_DUTY = 'org_off_duty',
    NOT_HELD = 'org_not_held', BANK_DOWN = 'org_bank_down', INVALID = CH.ERR.INVALID_INPUT,
}
local ERR = Org.ERR

local MESSAGES = {
    org_off = 'The organisation is switched off.',
    org_not_member = 'Not a member of the organisation.',
    org_no_power = 'Staff have not given you this.',
    org_office = 'That needs the boss office: go there first.',
    org_rank = 'Only below your own rank.',
    org_self = 'Not on yourself.',
    org_locked = 'Staff have locked that.',
    org_last_boss = 'The organisation would be left with nobody in its top boss role.',
    org_bounds = 'Outside the bounds staff set.',
    org_cooldown = 'Too soon: wait a while first.',
    org_limit = 'At the limit staff set.',
    org_not_found = 'Not found. Refresh and try again.',
    org_refused = 'qbx_core refused it; nothing was changed.',
    org_short = 'The funds do not hold that much.',
    org_busy = 'Already being done. Try again in a moment.',
    org_members_only = 'Only members of the organisation may accept contracts.',
    org_rule = 'The organisation does not let your role take this contract.',
    org_already = 'Already so.',
    org_off_duty = 'Go on duty first.',
    org_not_held = 'You can only pass on a power you hold yourself.',
    org_bank_down = 'The organisation\'s bank account cannot be reached right now; nothing was moved.',
    invalid_input = 'Check what was entered.',
}

---@param err string
---@return string
function Org.message(err) return MESSAGES[err] or 'Not done.' end

local function fail(err, extra)
    return false, err, extra, MESSAGES[err] or 'Not done.'
end

-- ============================================================================
--                              SWITCHES AND STATE
-- ============================================================================

--- Whether the organisation is on now: one read of one switch.
---@return boolean
function Org.enabled()
    return type(Config.Organisation) == 'table' and Config.Organisation.Enabled == true
end

--- The organisation in force, or nil (off, or not loaded).
---@return table|nil
function Org.current()
    if not Org.enabled() then return nil end
    return State
end

--- The identity module the organisation was wired with.
function Org.identity() return deps.identity end

local function now() return os.time() end

local function orgId() return tostring(Config.Organisation.JobName or 'hitman'):lower():sub(1, 32) end

--- A role row from the shipped list: 'grade, name, label, pay, boss'.
local function parseRole(text)
    if type(text) ~= 'string' then return nil end
    local g, name, label, pay, boss = text:match('^%s*(%d+)%s*,%s*([%w_]+)%s*,%s*([^,]+),%s*(%d+)%s*,%s*(%a+)%s*$')
    if not g then return nil end
    return { grade = tonumber(g), name = name:lower():sub(1, 32), label = label:gsub('%s+$', ''):sub(1, 64),
        pay = tonumber(pay), is_boss = boss:lower() == 'yes' or boss:lower() == 'true' }
end

local function roleId(grade) return State.id .. ':' .. tostring(grade) end
local function memberId(cid) return State.id .. ':' .. cid end

local function saveOrgRow()
    deps.storage.writeOrgRow('orgs', { id = State.id, job = State.job, label = State.label,
        job_type = State.jobType, settings = State.settings, created_at = State.created_at,
        updated_at = now() })
end

local function saveRole(role)
    role.updated_at = now()
    deps.storage.writeOrgRow('roles', role)
end

local function saveMember(member)
    member.updated_at = now()
    deps.storage.writeOrgRow('members', member)
end

--- Settings with every table present.
local function settingsOf(raw)
    local s = type(raw) == 'table' and raw or {}
    s.limits = type(s.limits) == 'table' and s.limits or {}
    s.cuts = type(s.cuts) == 'table' and s.cuts or {}
    s.cuts.byRole = type(s.cuts.byRole) == 'table' and s.cuts.byRole or {}
    s.cuts.byMember = type(s.cuts.byMember) == 'table' and s.cuts.byMember or {}
    s.officeBoss = type(s.officeBoss) == 'table' and s.officeBoss or {}
    s.access = type(s.access) == 'table' and s.access or {}
    s.picks = type(s.picks) == 'table' and s.picks or {}
    s.layout = type(s.layout) == 'table' and s.layout or {}
    s.moves = type(s.moves) == 'table' and s.moves or {}
    return s
end

--- Read the organisation from the store, making it from config.lua the
--- first time (its roles from Config.Organisation.Roles).
local function load()
    local id = orgId()
    local storage = deps.storage
    local row = storage.readOrgRow('orgs', id)
    local created = false
    if not row then
        row = { id = id, job = id, label = Config.Organisation.JobLabel or id,
            job_type = Config.Organisation.JobType or 'hitman', settings = {}, created_at = now() }
        storage.writeOrgRow('orgs', row)
        created = true
    end
    State = {
        id = row.id, job = row.job or id, label = row.label, jobType = row.job_type,
        settings = settingsOf(row.settings), created_at = row.created_at,
        roles = {}, members = {}, ceiling = { role = {}, member = {} }, locations = {}, applications = {},
    }
    for _, r in ipairs(storage.readOrgRows('roles', id) or {}) do
        local grade = math.floor(tonumber(r.grade) or -1)
        if grade >= 0 then
            r.grade = grade
            r.powers = type(r.powers) == 'table' and r.powers or {}
            r.is_boss, r.locked = r.is_boss == true, r.locked == true
            State.roles[grade] = r
        end
    end
    if created and next(State.roles) == nil then
        for _, text in ipairs(Config.Organisation.Roles or {}) do
            local parsed = parseRole(text)
            if parsed then
                local role = { id = roleId(parsed.grade), org_id = id, grade = parsed.grade, name = parsed.name,
                    label = parsed.label, pay = parsed.pay, is_boss = parsed.is_boss, locked = false, powers = {} }
                State.roles[parsed.grade] = role
                saveRole(role)
            end
        end
    end
    for _, m in ipairs(storage.readOrgRows('members', id) or {}) do
        if type(m.cid) == 'string' then
            m.grade = math.floor(tonumber(m.grade) or 0)
            m.grants = type(m.grants) == 'table' and m.grants or {}
            m.denies = type(m.denies) == 'table' and m.denies or {}
            m.limits = type(m.limits) == 'table' and m.limits or {}
            m.locked = m.locked == true
            State.members[m.cid] = m
        end
    end
    for _, g in ipairs(storage.readOrgRows('grants', id) or {}) do
        if g.subject == 'role' then
            local grade = math.floor(tonumber(g.subject_id) or -1)
            State.ceiling.role[grade] = State.ceiling.role[grade] or {}
            State.ceiling.role[grade][g.power] = g.state
        elseif g.subject == 'member' then
            State.ceiling.member[g.subject_id] = State.ceiling.member[g.subject_id] or {}
            State.ceiling.member[g.subject_id][g.power] = g.state
        end
    end
    for _, l in ipairs(storage.readOrgRows('locations', id) or {}) do State.locations[l.id] = l end
    for _, a in ipairs(storage.readOrgRows('applications', id) or {}) do
        if a.state == 'open' then State.applications[a.id] = a end
    end
    Funds.load(State)
    if created then
        deps.audit.staff('org_created', nil, nil, { org = id, roles = #(Config.Organisation.Roles or {}) })
    end
    return State
end

function Org.init(d)
    deps = d
    State, Splits, LastAccept, Recent, Refs, RefSeq = nil, {}, {}, {}, {}, 0
    Invites, LoadedSeq, RegisteredSeq, Seq = {}, {}, nil, 0
    Jobs.reset()
    Funds.init({ storage = d.storage, audit = d.audit })
    -- The money path's two hooks, which read one switch while it is off.
    if d.escrow then
        d.escrow.orgCut = function(recipientCid, line) return Org.cutFor(recipientCid, line) end
        d.escrow.orgTaken = function(line) return Funds.taken(line and line.id) end
    end
    if d.contracts then
        d.contracts.acceptGate = function(actor, contractId, opts, out)
            return Org.acceptGate(actor, contractId, opts, out)
        end
        d.contracts.afterAccept = function(actor, contractId, gate) return Org.afterAccept(actor, contractId, gate) end
    end
    if d.settings and d.settings.watch then
        d.settings.watch('Organisation.Enabled', function() Org.boot(true) end)
    end
end

--- Start the organisation, where it is on: read it, register the job,
--- make sure of the funds account, and bring every online player in step
--- (a start after players loaded leaves qbx_core without their job). Off,
--- nothing; turned off live, players are told their places are gone, and
--- the job stays registered until the next start, which registers none.
---@param live boolean|nil turned on or off from the panel
function Org.boot(live)
    if not Org.enabled() then
        if live and State then
            State = nil
            Org.pushSpotsAll()
        end
        return false
    end
    local ok, err = pcall(load)
    if not ok then
        Log.always(('the hitman organisation could not be read: %s; it stays off until the next start')
            :format(Util.dbError and Util.dbError(err) or tostring(err)))
        State = nil
        return false
    end
    Jobs.checkConvars()
    if Jobs.register(State) then
        Seq = Seq + 1
        RegisteredSeq = Seq
    end
    Funds.ensureAccount(State)
    Org.resync()
    Org.pushSpotsAll()
    return true
end

--- The start-up checks for Config.Organisation (main.lua's validateConfig):
--- a value they cannot take is put back to the shipped one, and said.
---@param warn string[]
function Org.validate(warn)
    local shipped = type(ConfigDefaults) == 'table' and ConfigDefaults.Organisation or {}
    if type(Config.Organisation) ~= 'table' then
        Config.Organisation = Util.copy(shipped)
        return
    end
    local cfg = Config.Organisation
    local function back(key, why)
        warn[#warn + 1] = ('Organisation.%s %s; using %s'):format(key, why, tostring(shipped[key]))
        cfg[key] = Util.copy(shipped[key])
    end
    for _, key in ipairs({ 'Enabled', 'RequireJobToAccept', 'AcceptNeedsPower', 'OnDutyOnly', 'DefaultDuty',
        'SetPrimaryOnHire', 'QbxBossFlag', 'ApplyAtSignupOnly' }) do
        if type(cfg[key]) ~= 'boolean' then back(key, 'is not true or false') end
    end
    if type(cfg.JobName) ~= 'string' or not cfg.JobName:match('^[a-z][a-z0-9_]*$') or #cfg.JobName > 32 then
        back('JobName', 'must be a lower-case qbx_core job name')
    end
    for _, key in ipairs({ 'JobLabel', 'JobType' }) do
        if type(cfg[key]) ~= 'string' or cfg[key] == '' or #cfg[key] > 64 then back(key, 'must be a short text') end
    end
    if cfg.ExternalChanges ~= 'adopt' and cfg.ExternalChanges ~= 'revert' then
        back('ExternalChanges', "is 'adopt' or 'revert'")
    end
    if cfg.Funds ~= 'auto' and cfg.Funds ~= 'internal' then back('Funds', "is 'auto' or 'internal'") end
    for _, key in ipairs({ 'OfficeRadius', 'DrawMetres' }) do
        local n = tonumber(cfg[key])
        if not n or n <= 0 or n > 500 then back(key, 'must be a distance above 0 and at most 500') end
    end
    if type(cfg.Roles) ~= 'table' then back('Roles', 'must be a list') end
    for _, text in ipairs(type(cfg.Roles) == 'table' and cfg.Roles or {}) do
        if not parseRole(text) then
            back('Roles', ("has a line that is not 'grade, name, label, pay, yes|no' (%s)"):format(tostring(text)))
            break
        end
    end
    if type(cfg.NpcModel) ~= 'string' or not cfg.NpcModel:match('^[%w_]+$') then back('NpcModel', 'must be a ped model name') end
    if type(cfg.Limits) ~= 'table' then
        back('Limits', 'must be a table')
    else
        for key, spec in pairs(Powers.LIMIT_KEYS) do
            local n = tonumber(cfg.Limits[key])
            if cfg.Limits[key] ~= nil and (not n or n < spec.min or n > spec.max or (not spec.float and n ~= math.floor(n))) then
                warn[#warn + 1] = ('Organisation.Limits.%s must be %s to %s; using %s'):format(key, spec.min, spec.max,
                    tostring(shipped.Limits and shipped.Limits[key]))
                cfg.Limits[key] = shipped.Limits and shipped.Limits[key]
            end
        end
    end
end

-- ============================================================================
--                              KEEPING QBX_CORE IN STEP
-- ============================================================================

--- One online player brought in step with the table: a member qbx_core does
--- not have at their grade is put there; somebody qbx_core has in the job
--- whom the table does not is adopted or taken out (Config.Organisation.
--- ExternalChanges); a primary job core kept by name only is set again.
---@param src integer
function Org.reconcile(src)
    local org = Org.current()
    if not org then return end
    local actor = deps.identity.resolve(src)
    if not actor or Jobs.applying(actor.cid) then return end
    local member = org.members[actor.cid]
    local grade, primary = Jobs.heldBy(org, src)
    if member then
        -- Written only when it says something new: a duty change runs this
        -- too, and on json every write is the whole records file.
        local dirty = not member.last_seen or now() - member.last_seen >= 600
            or (actor.name and member.name ~= actor.name)
        member.last_seen = now()
        if actor.name then member.name = actor.name end
        if grade ~= member.grade then
            -- A change made while this resource did not hear it (the player
            -- away, or the organisation off) is a change made elsewhere, as
            -- one heard live is (Org.external, ExternalChanges). Put back as
            -- the table has it only where qbx_core cannot be believed about
            -- a removal: the job kept by name only, qbx:cleanPlayerGroups on
            -- (it deletes the members of a job not yet registered at its
            -- start), or a character that loaded before the job was
            -- registered this process (a late start), whom qbx_core does not
            -- show the job to.
            if grade == nil and (primary or Jobs.cleansGroups() or not Org.loadedSinceRegister(src)) then
                Jobs.setMember(org, actor.cid, member.grade, primary)
            else
                if dirty then pcall(saveMember, member) end
                Org.external(actor, grade)
                return
            end
        elseif primary then
            -- qbx_core keeps an unknown primary job by name with
            -- unemployed's label and grade until it is set again.
            local job = actor.job
            if type(job) == 'table' and job.name == org.job and job.label ~= org.label then
                Jobs.setMember(org, actor.cid, member.grade, true)
            end
        end
        if dirty then pcall(saveMember, member) end
        return
    end
    if grade == nil then return end
    Org.external(actor, grade)
end

--- A change qbx_core made that this resource did not: adopted into the
--- table, or put back as the table has it.
---@param actor table
---@param grade integer|nil nil for taken out of the job
function Org.external(actor, grade)
    local org = Org.current()
    if not org or not actor or Jobs.applying(actor.cid) then return end
    local member = org.members[actor.cid]
    if (member and member.grade == grade) or (not member and grade == nil) then return end
    local adopt = Config.Organisation.ExternalChanges ~= 'revert'
    if adopt and grade ~= nil and not org.roles[grade] then adopt = false end
    if adopt then
        if grade == nil then
            org.members[actor.cid] = nil
            org.ceiling.member[actor.cid] = nil
            Invites[actor.cid] = nil
            pcall(deps.storage.deleteOrgRow, 'members', memberId(actor.cid))
            pcall(function()
                for _, g in ipairs(deps.storage.readOrgRows('grants', org.id) or {}) do
                    if g.subject == 'member' and g.subject_id == actor.cid then deps.storage.deleteOrgRow('grants', g.id) end
                end
            end)
        else
            member = member or { id = memberId(actor.cid), org_id = org.id, cid = actor.cid, name = actor.name,
                grants = {}, denies = {}, limits = {}, locked = false, joined_at = now() }
            member.grade = grade
            org.members[actor.cid] = member
            pcall(saveMember, member)
            Org.closeApplications(org, actor.cid, 'external')
        end
        deps.audit.staff('org_external_adopted', actor.cid, nil, { org = org.id, grade = grade })
    else
        if member then
            Jobs.setMember(org, actor.cid, member.grade, false)
        else
            Jobs.removeMember(org, actor.cid)
        end
        deps.audit.staff('org_external_reverted', actor.cid, nil, { org = org.id, grade = grade,
            kept = member and member.grade or nil })
    end
    Org.pushSpots(actor.source)
end

--- qbx_core:server:onGroupUpdate(source, groupName, grade|nil).
function Org.onGroupUpdate(src, groupName, grade)
    local org = Org.current()
    if not org or groupName ~= org.job then return end
    local actor = deps.identity.resolve(tonumber(src))
    if not actor then return end
    if type(grade) == 'table' then grade = grade.level end
    Org.external(actor, grade ~= nil and math.floor(tonumber(grade) or 0) or nil)
end

--- Whether a player loaded after the job was registered this process: what
--- qbx_core says of their job can then be believed (Org.reconcile).
---@param src integer
---@return boolean
function Org.loadedSinceRegister(src)
    local at = LoadedSeq[tonumber(src) or -1]
    return RegisteredSeq ~= nil and at ~= nil and at > RegisteredSeq
end

--- A character in, or a job change (QBCore:Server:OnJobUpdate).
function Org.playerLoaded(src)
    if not Org.current() then return end
    src = tonumber(src)
    if src then
        Seq = Seq + 1
        LoadedSeq[src] = Seq
    end
    Org.reconcile(src)
    Org.pushSpots(src)
end

--- Every online player, after a start.
function Org.resync()
    if not Org.current() then return end
    for _, actor in ipairs(deps.identity.online() or {}) do
        pcall(Org.reconcile, actor.source)
    end
end

-- ============================================================================
--                              WHO MAY
-- ============================================================================

--- Whether a player stands at the boss office, by where the server sees
--- their character now.
---@return boolean
function Org.inOffice(org, src)
    src = tonumber(src)
    if not src or src <= 0 then return false end
    for _, loc in pairs(org.locations) do
        if loc.kind == 'office' and loc.enabled ~= false then
            local ok, at = pcall(function() return GetEntityCoords(GetPlayerPed(src)) end)
            if ok and at then
                local dx, dy, dz = at.x - loc.x / 10, at.y - loc.y / 10, at.z - loc.z / 10
                local radius = math.max(tonumber(Config.Organisation.OfficeRadius) or 5, (loc.radius or 0) / 10)
                if dx * dx + dy * dy + dz * dz <= radius * radius then return true end
            end
        end
    end
    return false
end

--- May this actor use this power now: staff always; a boss when they hold
--- it, at the office where it needs one.
---@param who table { staff = true } or { cid, source }
---@return string|nil err
function Org.authorize(org, who, code)
    if who.staff then return nil end
    if not org.members[who.cid] then return ERR.NOT_MEMBER end
    if not Engine.holds(org, who.cid, code) then return ERR.NO_POWER end
    if Engine.needsOffice(org, code) and not Org.inOffice(org, who.source) then return ERR.OFFICE end
    return nil
end

local function record(action, who, detail, contract)
    detail = detail or {}
    detail.org = State and State.id or nil
    detail.by = who.staff and 'staff' or 'boss'
    if who.staff then
        deps.audit.staff(action, who.cid, contract, detail)
    else
        deps.audit.action(action, who.cid, contract, detail)
    end
end
Org.record = record

local function within(list, ts, seconds)
    local n = 0
    for i = #list, 1, -1 do
        if ts - list[i] < seconds then n = n + 1 else table.remove(list, i) end
    end
    return n
end

local function recent(cid)
    Recent[cid] = Recent[cid] or { fires = {}, promotions = {} }
    return Recent[cid]
end

-- ============================================================================
--                              MEMBER HANDLES
-- ============================================================================

--- A handle for a member, good for this viewer only.
---@param viewer string
---@param cid string
---@return string
function Org.refFor(viewer, cid)
    local mine = Refs[viewer]
    if not mine then
        mine = {}
        Refs[viewer] = mine
    end
    local ts, count, oldest, oldestAt = now(), 0, nil, math.huge
    for ref, entry in pairs(mine) do
        if ts - entry.at >= REF_SECONDS then
            mine[ref] = nil
        else
            if entry.cid == cid then
                entry.at = ts
                return ref
            end
            count = count + 1
            if entry.at < oldestAt then oldest, oldestAt = ref, entry.at end
        end
    end
    if count >= REFS_PER_VIEWER and oldest then mine[oldest] = nil end
    RefSeq = RefSeq + 1
    local ref = ('m%d_%d'):format(RefSeq, math.random(1000, 9999))
    mine[ref] = { cid = cid, at = ts }
    return ref
end

--- The member a handle stands for, for this viewer, or nil.
function Org.fromRef(viewer, ref)
    if type(ref) ~= 'string' or #ref > 24 then return nil end
    local entry = Refs[viewer] and Refs[viewer][ref]
    if not entry or now() - entry.at >= REF_SECONDS then return nil end
    return entry.cid
end

-- ============================================================================
--                              MEMBERS
-- ============================================================================

--- Close every open application of one citizen, who is a member now (or
--- whose application a hire overtook): never accepted later over the
--- member record they have.
---@param org table
---@param cid string
---@param by string|nil who made them a member
function Org.closeApplications(org, cid, by)
    for id, a in pairs(org.applications) do
        if a.cid == cid then
            a.state, a.decided_by, a.decided_at = 'superseded', by, now()
            pcall(deps.storage.writeOrgRow, 'applications', a)
            org.applications[id] = nil
        end
    end
end

--- Make a citizen a member at a grade, told to qbx_core.
local function enrol(org, target, grade, primary)
    local member = { id = memberId(target.cid), org_id = org.id, cid = target.cid, name = target.name,
        grade = grade, grants = {}, denies = {}, limits = {}, locked = false, joined_at = now(),
        last_seen = target.source and now() or nil }
    local done, code = Jobs.setMember(org, target.cid, grade, primary)
    if not done then return nil, code end
    org.members[target.cid] = member
    saveMember(member)
    Invites[target.cid] = nil
    Org.closeApplications(org, target.cid, 'hired')
    return member
end

--- The invite waiting for a citizen, if one is and it has not run out.
local function inviteOf(cid)
    local invite = type(cid) == 'string' and Invites[cid] or nil
    if invite and invite.expires <= now() then
        Invites[cid] = nil
        return nil
    end
    return invite
end

--- Why a boss may not hire into a grade now (nil: they may): the rules a
--- hire is checked by, but the distance, asked again as an invite is
--- accepted.
local function bossMayHire(org, bossCid, targetCid, grade)
    if not org.roles[grade] then return ERR.NOT_FOUND end
    if not org.members[bossCid] or not Engine.holds(org, bossCid, 'M2') then return ERR.NO_POWER end
    if targetCid == bossCid then return ERR.SELF end
    local count = 0
    for _ in pairs(org.members) do count = count + 1 end
    if count >= Powers.limit(org, 'MaxMembers') then return ERR.LIMIT end
    if grade > Powers.limit(org, 'HireMaxGrade') then return ERR.BOUNDS end
    if Engine.mayAssignGrade(org, bossCid, grade) then return ERR.RANK end
    return nil
end

--- Hire a citizen at a grade. Staff hire anybody into any role at once (it
--- is not made their primary job: they did not ask). A boss (M2) invites a
--- player standing within Limits.HireRadius of them, into a grade no
--- higher than HireMaxGrade and below their own: the player accepts it in
--- the app within Limits.InviteMinutes (Org.answerInvite), and only then
--- are they hired, the job made their primary one where
--- Config.Organisation.SetPrimaryOnHire says so.
---@param who table
---@param target table { cid, name, source|nil }
---@param grade integer|nil
function Org.hire(who, target, grade)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    local err = Org.authorize(org, who, 'M2')
    if err then return fail(err) end
    if type(target) ~= 'table' or type(target.cid) ~= 'string' then return fail(ERR.INVALID) end
    if org.members[target.cid] then return fail(ERR.ALREADY) end
    if grade == nil then
        for g in pairs(org.roles) do if grade == nil or g < grade then grade = g end end
    end
    grade = math.floor(tonumber(grade) or -1)
    if not org.roles[grade] then return fail(ERR.NOT_FOUND) end
    if who.staff then
        local member, code = enrol(org, target, grade, false)
        if not member then return fail(ERR.REFUSED, { qbx = code }) end
        record('org_member_hired', who, { member = target.cid, grade = grade })
        if target.source then Org.pushSpots(target.source) end
        return true, nil, { grade = grade }
    end
    local why = bossMayHire(org, who.cid, target.cid, grade)
    if why then return fail(why) end
    -- In person: the server's own positions, never the client's.
    local radius = Powers.limit(org, 'HireRadius')
    local ok, a, b = pcall(function()
        return GetEntityCoords(GetPlayerPed(who.source)), GetEntityCoords(GetPlayerPed(target.source))
    end)
    if not target.source or not ok or not a or not b
        or GetPlayerRoutingBucket(who.source) ~= GetPlayerRoutingBucket(target.source)
        or (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2 > radius * radius then
        return fail(ERR.RULE, nil)
    end
    if inviteOf(target.cid) then return fail(ERR.ALREADY) end
    local minutes = Powers.limit(org, 'InviteMinutes')
    RefSeq = RefSeq + 1
    local invite = { id = ('inv%d_%d'):format(RefSeq, math.random(1000, 9999)), cid = target.cid, grade = grade,
        by = who.cid, at = now(), expires = now() + minutes * 60 }
    Invites[target.cid] = invite
    record('org_member_invited', who, { member = target.cid, grade = grade })
    -- The organisation and the role, never who asked.
    if deps.notify and deps.notify.toCitizen then
        local role = org.roles[grade]
        pcall(deps.notify.toCitizen, target.cid, org.label or 'Organisation',
            ('You are invited to join as %s. Open the app to accept or decline within %d minutes.')
                :format(role and role.label or 'a member', minutes))
    end
    return true, nil, { invited = true, grade = grade, expiresAt = invite.expires }
end

--- What a player is shown of an invite waiting for them: the organisation,
--- the role and how long it has left. Never who sent it.
---@param cid string
---@return table|nil { id, label, role, expiresIn }
function Org.inviteFor(cid)
    local org = Org.current()
    if not org or org.members[cid] then return nil end
    local invite = inviteOf(cid)
    if not invite then return nil end
    local role = org.roles[invite.grade]
    return { id = invite.id, label = org.label, role = role and role.label or nil,
        expiresIn = math.max(0, invite.expires - now()) }
end

--- The invited player's answer, from their own app. Accepted, the hire is
--- checked again as it stands now (the boss still holding Hire, the grade
--- still theirs to give, room in the organisation) and made.
---@param actor table the player answering (the engine's source)
---@param id string the invite's id
---@param accept boolean
function Org.answerInvite(actor, id, accept)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    if type(actor) ~= 'table' or type(actor.cid) ~= 'string' then return fail(ERR.INVALID) end
    if type(accept) ~= 'boolean' then return fail(ERR.INVALID) end
    local invite = inviteOf(actor.cid)
    if not invite or invite.id ~= id then return fail(ERR.NOT_FOUND) end
    Invites[actor.cid] = nil
    local boss = { cid = invite.by, source = nil }
    if not accept then
        record('org_invite_answered', boss, { member = actor.cid, accepted = false })
        return true, nil, { accepted = false }
    end
    if org.members[actor.cid] then return fail(ERR.ALREADY) end
    local why = bossMayHire(org, invite.by, actor.cid, invite.grade)
    if why then return fail(why == ERR.LIMIT and ERR.LIMIT or ERR.RULE) end
    local member, code = enrol(org, { cid = actor.cid, name = actor.name, source = actor.source }, invite.grade,
        Config.Organisation.SetPrimaryOnHire ~= false)
    if not member then return fail(ERR.REFUSED, { qbx = code }) end
    record('org_member_hired', boss, { member = actor.cid, grade = invite.grade, invited = true })
    if actor.source then Org.pushSpots(actor.source) end
    return true, nil, { accepted = true, grade = invite.grade }
end

--- Remove a member. A boss (M3): below their rank, with a reason, once per
--- FireCooldownMinutes; never the last in the top boss role.
function Org.fire(who, cid, reason)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    local err = Org.authorize(org, who, 'M3')
    if err then return fail(err) end
    local member = type(cid) == 'string' and org.members[cid]
    if not member then return fail(ERR.NOT_FOUND) end
    reason = type(reason) == 'string' and Util.toValidUtf8(reason):sub(1, 160) or nil
    if not reason or not reason:find('%S') then return fail(ERR.INVALID) end
    if not who.staff then
        local why = Engine.mayActOn(org, who.cid, cid)
        if why then return fail(why == 'self' and ERR.SELF or why == 'locked' and ERR.LOCKED or ERR.RANK) end
        if Engine.wouldLeaveNoBoss(org, cid) then return fail(ERR.LAST_BOSS) end
        local mine = recent(who.cid)
        if within(mine.fires, now(), Powers.limit(org, 'FireCooldownMinutes') * 60) > 0 then
            return fail(ERR.COOLDOWN)
        end
    end
    local done, code = Jobs.removeMember(org, cid)
    if not done then return fail(ERR.REFUSED, { qbx = code }) end
    org.members[cid] = nil
    deps.storage.deleteOrgRow('members', memberId(cid))
    org.ceiling.member[cid] = nil
    for _, g in ipairs(deps.storage.readOrgRows('grants', org.id) or {}) do
        if g.subject == 'member' and g.subject_id == cid then deps.storage.deleteOrgRow('grants', g.id) end
    end
    if not who.staff then table.insert(recent(who.cid).fires, now()) end
    record('org_member_fired', who, { member = cid, grade = member.grade, reason = reason })
    local actor = deps.identity.byCitizenId(cid)
    if actor then Org.pushSpots(actor.source) end
    return true
end

--- Move a member to another role. A boss (M4): a member below them, into
--- a grade below their own (D3: level with it), PromotionsPerDay a day.
function Org.setRole(who, cid, grade)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    local err = Org.authorize(org, who, 'M4')
    if err then return fail(err) end
    local member = type(cid) == 'string' and org.members[cid]
    grade = math.floor(tonumber(grade) or -1)
    if not member then return fail(ERR.NOT_FOUND) end
    if not org.roles[grade] then return fail(ERR.NOT_FOUND) end
    if member.grade == grade then return true, nil, { unchanged = true } end
    if not who.staff then
        local why = Engine.mayActOn(org, who.cid, cid)
        if why then return fail(why == 'self' and ERR.SELF or why == 'locked' and ERR.LOCKED or ERR.RANK) end
        if Engine.mayAssignGrade(org, who.cid, grade) then return fail(ERR.RANK) end
        if Engine.wouldLeaveNoBoss(org, cid, grade) then return fail(ERR.LAST_BOSS) end
        if within(recent(who.cid).promotions, now(), 86400) >= Powers.limit(org, 'PromotionsPerDay') then
            return fail(ERR.LIMIT)
        end
    elseif Engine.wouldLeaveNoBoss(org, cid, grade) then
        Log.debug(('staff moved the last top boss of %s out of the role'):format(org.id))
    end
    local done, code = Jobs.setMember(org, cid, grade, false)
    if not done then return fail(ERR.REFUSED, { qbx = code }) end
    local from = member.grade
    member.grade = grade
    saveMember(member)
    if not who.staff then table.insert(recent(who.cid).promotions, now()) end
    record('org_member_role', who, { member = cid, from = from, to = grade })
    return true, nil, { from = from, to = grade }
end

--- Bar a member from accepting contracts for some hours (0 lifts it). A
--- boss (M5): below them, up to SuspendMaxHours.
function Org.suspend(who, cid, hours, reason)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    local err = Org.authorize(org, who, 'M5')
    if err then return fail(err) end
    local member = type(cid) == 'string' and org.members[cid]
    if not member then return fail(ERR.NOT_FOUND) end
    hours = tonumber(hours)
    if not hours or hours ~= math.floor(hours) or hours < 0 or hours > 720 then return fail(ERR.INVALID) end
    if not who.staff then
        local why = Engine.mayActOn(org, who.cid, cid)
        if why then return fail(why == 'self' and ERR.SELF or why == 'locked' and ERR.LOCKED or ERR.RANK) end
        if hours > Powers.limit(org, 'SuspendMaxHours') then return fail(ERR.BOUNDS) end
    end
    member.suspended_until = hours > 0 and (now() + hours * 3600) or nil
    saveMember(member)
    record('org_member_suspended', who, { member = cid, hours = hours,
        reason = type(reason) == 'string' and Util.toValidUtf8(reason):sub(1, 160) or nil })
    return true, nil, { untilAt = member.suspended_until }
end

--- A member's own limits: contracts at once and minutes between accepts. A
--- boss (M6): below them, within MemberMaxAtOnce and MemberCooldownMaxMinutes.
function Org.memberLimits(who, cid, maxAtOnce, cooldownMinutes)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    local err = Org.authorize(org, who, 'M6')
    if err then return fail(err) end
    local member = type(cid) == 'string' and org.members[cid]
    if not member then return fail(ERR.NOT_FOUND) end
    local function whole(v, lo, hi)
        if v == nil then return nil, true end
        v = tonumber(v)
        if not v or v ~= math.floor(v) or v < lo or v > hi then return nil, false end
        return v, true
    end
    local at, okA = whole(maxAtOnce, 1, 50)
    local cd, okC = whole(cooldownMinutes, 0, 10080)
    if not okA or not okC then return fail(ERR.INVALID) end
    if not who.staff then
        local why = Engine.mayActOn(org, who.cid, cid)
        if why then return fail(why == 'self' and ERR.SELF or why == 'locked' and ERR.LOCKED or ERR.RANK) end
        if (at and at > Powers.limit(org, 'MemberMaxAtOnce'))
            or (cd and cd > Powers.limit(org, 'MemberCooldownMaxMinutes')) then
            return fail(ERR.BOUNDS)
        end
    end
    member.limits = { maxAtOnce = at, cooldownMinutes = cd }
    saveMember(member)
    record('org_member_limits', who, { member = cid, maxAtOnce = at, cooldownMinutes = cd })
    return true
end

--- A member's own grant or deny of one power: 'grant', 'deny' or 'clear'.
--- A boss (D2): only a power they hold, to a member below them; never
--- themselves. Staff also lock a member against boss edits, and name
--- their codename.
function Org.memberGrant(who, cid, code, state)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    local err = Org.authorize(org, who, 'D2')
    if err then return fail(err) end
    local member = type(cid) == 'string' and org.members[cid]
    code = Powers.resolve(code, true)
    if not member or not code then return fail(member and ERR.INVALID or ERR.NOT_FOUND) end
    if state ~= 'grant' and state ~= 'deny' and state ~= 'clear' then return fail(ERR.INVALID) end
    if not who.staff then
        local why = Engine.mayActOn(org, who.cid, cid)
        if why then return fail(why == 'self' and ERR.SELF or why == 'locked' and ERR.LOCKED or ERR.RANK) end
        if Engine.mayDelegate(org, who.cid, code, 'D2') then return fail(ERR.NOT_HELD) end
        -- A grant or deny set by staff is staff's: a boss neither lifts nor
        -- overwrites it (a deny written over it would be the boss's to clear).
        local denied, granted = member.denies[code], member.grants[code]
        if (denied and denied.by == 'staff') or (granted and granted.by == 'staff') then return fail(ERR.LOCKED) end
    end
    local by = who.staff and 'staff' or who.cid
    local before = { grant = member.grants[code] and member.grants[code].by, deny = member.denies[code] and member.denies[code].by }
    if state == 'grant' then
        member.grants[code] = { by = by, at = now() }
        member.denies[code] = nil
    elseif state == 'deny' then
        member.denies[code] = { by = by, at = now() }
        member.grants[code] = nil
    else
        member.grants[code], member.denies[code] = nil, nil
    end
    saveMember(member)
    record('org_member_grant', who, { member = cid, power = code, state = state, before = before })
    return true
end

--- Staff only: lock a member against boss edits, name their codename.
function Org.memberStaff(who, cid, fields)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    if not who.staff then return fail(ERR.NO_POWER) end
    local member = type(cid) == 'string' and org.members[cid]
    if not member then return fail(ERR.NOT_FOUND) end
    fields = type(fields) == 'table' and fields or {}
    if fields.locked ~= nil then member.locked = fields.locked == true end
    if fields.codename ~= nil then
        if fields.codename == false or fields.codename == '' then
            member.codename = nil
        elseif type(fields.codename) == 'string' and fields.codename:match('^[%w _%-]+$') and #fields.codename <= 32 then
            member.codename = fields.codename
        else
            return fail(ERR.INVALID)
        end
    end
    saveMember(member)
    record('org_member_staff', who, { member = cid, locked = member.locked, codename = member.codename })
    return true
end

-- ============================================================================
--                              ROLES
-- ============================================================================

local function cleanName(v, max)
    if type(v) ~= 'string' then return nil end
    v = Util.toValidUtf8(v):gsub('^%s+', ''):gsub('%s+$', '')
    if v == '' or #v > max or v:find('[<>]') then return nil end
    return v
end

local function roleCount(org)
    local n = 0
    for _ in pairs(org.roles) do n = n + 1 end
    return n
end

--- Add a role. A boss (R1): below their own rank, within MaxRoles and
--- PayMax. Staff: any grade, boss or not.
function Org.roleCreate(who, spec)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    local err = Org.authorize(org, who, 'R1')
    if err then return fail(err) end
    spec = type(spec) == 'table' and spec or {}
    local grade = tonumber(spec.grade)
    local name = cleanName(spec.name, 32)
    local label = cleanName(spec.label or spec.name, 64)
    local pay = spec.pay == nil and 0 or tonumber(spec.pay)
    if not grade or grade ~= math.floor(grade) or grade < 0 or grade > 100 or not name or not label
        or not pay or pay ~= math.floor(pay) or pay < 0 or pay > 1000000 or not name:match('^[%w_]+$') then
        return fail(ERR.INVALID)
    end
    if org.roles[grade] then return fail(ERR.ALREADY) end
    local isBoss = spec.isBoss == true
    if not who.staff then
        if roleCount(org) >= Powers.limit(org, 'MaxRoles') then return fail(ERR.LIMIT) end
        if grade >= org.members[who.cid].grade then return fail(ERR.RANK) end
        if pay > Powers.limit(org, 'PayMax') then return fail(ERR.BOUNDS) end
        isBoss = false
    end
    local role = { id = roleId(grade), org_id = org.id, grade = grade, name = name:lower(), label = label,
        pay = pay, is_boss = isBoss, locked = false, powers = {} }
    org.roles[grade] = role
    saveRole(role)
    Jobs.upsertGrade(org, grade)
    record('org_role_created', who, { grade = grade, name = role.name, pay = pay, boss = isBoss })
    return true, nil, { grade = grade }
end

--- Rename, relabel, move or (staff) re-flag a role. A boss (R2): a role
--- below them, moved to a free grade still below them.
function Org.roleEdit(who, grade, spec)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    local err = Org.authorize(org, who, 'R2')
    if err then return fail(err) end
    grade = math.floor(tonumber(grade) or -1)
    local role = org.roles[grade]
    if not role then return fail(ERR.NOT_FOUND) end
    spec = type(spec) == 'table' and spec or {}
    if not who.staff and Engine.mayEditRole(org, who.cid, grade) then
        return fail(role.locked and ERR.LOCKED or ERR.RANK)
    end
    local name = spec.name ~= nil and cleanName(spec.name, 32) or role.name
    local label = spec.label ~= nil and cleanName(spec.label, 64) or role.label
    if not name or not label or not name:match('^[%w_]+$') then return fail(ERR.INVALID) end
    local newGrade = spec.newGrade ~= nil and tonumber(spec.newGrade) or grade
    if not newGrade or newGrade ~= math.floor(newGrade) or newGrade < 0 or newGrade > 100 then return fail(ERR.INVALID) end
    if newGrade ~= grade then
        if org.roles[newGrade] then return fail(ERR.ALREADY) end
        if not who.staff and newGrade >= org.members[who.cid].grade then return fail(ERR.RANK) end
        if Engine.countAt(org, grade) > 0 then return fail(ERR.LIMIT, nil) end
    end
    if who.staff then
        if spec.isBoss ~= nil then role.is_boss = spec.isBoss == true end
        if spec.locked ~= nil then role.locked = spec.locked == true end
        if spec.pay ~= nil then
            local pay = tonumber(spec.pay)
            if not pay or pay ~= math.floor(pay) or pay < 0 or pay > 1000000 then return fail(ERR.INVALID) end
            role.pay = pay
        end
    end
    local before = { name = role.name, label = role.label, grade = grade }
    role.name, role.label = name:lower(), label
    if newGrade ~= grade then
        org.roles[grade] = nil
        deps.storage.deleteOrgRow('roles', role.id)
        role.grade, role.id = newGrade, roleId(newGrade)
        org.roles[newGrade] = role
        org.ceiling.role[newGrade], org.ceiling.role[grade] = org.ceiling.role[grade], nil
        Jobs.upsertGrade(org, grade)
    end
    saveRole(role)
    Jobs.upsertGrade(org, newGrade)
    record('org_role_edited', who, { before = before, name = role.name, label = role.label, grade = newGrade,
        boss = role.is_boss, locked = role.locked })
    return true, nil, { grade = newGrade }
end

--- Delete an empty role. A boss (R3): below them, never a boss role.
function Org.roleDelete(who, grade)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    local err = Org.authorize(org, who, 'R3')
    if err then return fail(err) end
    grade = math.floor(tonumber(grade) or -1)
    local role = org.roles[grade]
    if not role then return fail(ERR.NOT_FOUND) end
    if Engine.countAt(org, grade) > 0 then return fail(ERR.LIMIT) end
    if not who.staff then
        if role.is_boss then return fail(ERR.LOCKED) end
        local why = Engine.mayEditRole(org, who.cid, grade)
        if why then return fail(why == 'locked' and ERR.LOCKED or ERR.RANK) end
    end
    if roleCount(org) <= 1 then return fail(ERR.LIMIT) end
    org.roles[grade] = nil
    org.ceiling.role[grade] = nil
    deps.storage.deleteOrgRow('roles', role.id)
    for _, g in ipairs(deps.storage.readOrgRows('grants', org.id) or {}) do
        if g.subject == 'role' and tonumber(g.subject_id) == grade then deps.storage.deleteOrgRow('grants', g.id) end
    end
    Jobs.upsertGrade(org, grade)
    record('org_role_deleted', who, { grade = grade, name = role.name })
    return true
end

--- Give a role a power, or take it. A boss (R4, D1): a role below them,
--- and only a power they hold. Taking it back takes only their own grant
--- (or one by somebody below them); staff's stays.
function Org.rolePower(who, grade, code, on)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    local err = Org.authorize(org, who, 'R4')
    if err then return fail(err) end
    grade = math.floor(tonumber(grade) or -1)
    local role = org.roles[grade]
    code = Powers.resolve(code, true)
    if not role then return fail(ERR.NOT_FOUND) end
    if not code or type(on) ~= 'boolean' then return fail(ERR.INVALID) end
    local held = role.powers[code]
    if not who.staff then
        local why = Engine.mayEditRole(org, who.cid, grade)
        if why then return fail(why == 'locked' and ERR.LOCKED or ERR.RANK) end
        if Engine.mayDelegate(org, who.cid, code, 'R4') then return fail(ERR.NOT_HELD) end
        -- Staff's own entry stays staff's: turned on over it, it would be the
        -- boss's to turn off.
        if held and held.by == 'staff' then return fail(ERR.LOCKED) end
        if not on and held and held.by ~= who.cid then
            local granter = org.members[held.by]
            if granter and granter.grade >= org.members[who.cid].grade then return fail(ERR.RANK) end
        end
    end
    if on then
        role.powers[code] = { by = who.staff and 'staff' or who.cid, at = now() }
    else
        role.powers[code] = nil
    end
    saveRole(role)
    record('org_role_power', who, { grade = grade, power = code, on = on, before = held and held.by or nil })
    return true
end

--- A role's pay per pay-cycle. A boss (P1): a role below them, up to PayMax.
function Org.rolePay(who, grade, pay)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    local err = Org.authorize(org, who, 'P1')
    if err then return fail(err) end
    grade = math.floor(tonumber(grade) or -1)
    local role = org.roles[grade]
    pay = tonumber(pay)
    if not role then return fail(ERR.NOT_FOUND) end
    if not pay or pay ~= math.floor(pay) or pay < 0 or pay > 1000000 then return fail(ERR.INVALID) end
    if not who.staff then
        local why = Engine.mayEditRole(org, who.cid, grade)
        if why then return fail(why == 'locked' and ERR.LOCKED or ERR.RANK) end
        if pay > Powers.limit(org, 'PayMax') then return fail(ERR.BOUNDS) end
    end
    local before = role.pay
    role.pay = pay
    saveRole(role)
    Jobs.upsertGrade(org, grade)
    record('org_role_pay', who, { grade = grade, from = before, to = pay })
    return true
end

-- ============================================================================
--                              BOSS PERMISSIONS (THE CEILING)
-- ============================================================================

--- One cell of Boss permissions: a role ('allow' or 'off') or one member
--- ('allow', 'deny' or 'inherit'). Staff only. Revoking a power makes
--- every grant the boss made of it inactive at once (Engine), and giving it
--- back restores them.
---@param subject string 'role' | 'member'
---@param id integer|string the grade, or the member's citizen id
function Org.setCeiling(who, subject, id, code, state)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    if not who.staff then return fail(ERR.NO_POWER) end
    code = Powers.resolve(code)
    if not code then return fail(ERR.INVALID) end
    local key, cells
    if subject == 'role' then
        id = math.floor(tonumber(id) or -1)
        if not org.roles[id] then return fail(ERR.NOT_FOUND) end
        if state ~= 'allow' and state ~= 'off' then return fail(ERR.INVALID) end
        org.ceiling.role[id] = org.ceiling.role[id] or {}
        cells = org.ceiling.role[id]
    elseif subject == 'member' then
        if type(id) ~= 'string' or not org.members[id] then return fail(ERR.NOT_FOUND) end
        if state ~= 'allow' and state ~= 'deny' and state ~= 'inherit' then return fail(ERR.INVALID) end
        org.ceiling.member[id] = org.ceiling.member[id] or {}
        cells = org.ceiling.member[id]
    else
        return fail(ERR.INVALID)
    end
    key = ('%s:%s:%s:%s'):format(org.id, subject, tostring(id), code)
    local before = cells[code]
    if state == 'off' or state == 'inherit' then
        cells[code] = nil
        deps.storage.deleteOrgRow('grants', key)
    else
        cells[code] = state
        deps.storage.writeOrgRow('grants', { id = key, org_id = org.id, subject = subject,
            subject_id = tostring(id), power = code, state = state, by_cid = who.cid, updated_at = now() })
    end
    record('org_grant', who, { subject = subject, id = tostring(id), power = code, before = before or 'off',
        after = cells[code] or 'off' })
    return true, nil, { before = before, after = cells[code] }
end

--- The staff bounds for this organisation: one key, or several.
function Org.setLimits(who, values)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    if not who.staff then return fail(ERR.NO_POWER) end
    if type(values) ~= 'table' then return fail(ERR.INVALID) end
    local changed = {}
    for key, value in pairs(values) do
        local spec = type(key) == 'string' and Powers.LIMIT_KEYS[key]
        if not spec then return fail(ERR.INVALID) end
        if value == false then
            changed[key] = 'config'
        else
            local n = tonumber(value)
            if not n or n ~= n or n < spec.min or n > spec.max or (not spec.float and n ~= math.floor(n)) then
                return fail(ERR.INVALID)
            end
            changed[key] = n
        end
    end
    for key, value in pairs(changed) do org.settings.limits[key] = value ~= 'config' and value or nil end
    saveOrgRow()
    record('org_limits', who, { changed = changed })
    return true
end

--- Which powers need the office: staff's own list (they force it), or one
--- a boss adds for themselves (S3), never lifting staff's.
function Org.officeRule(who, code, on)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    code = Powers.resolve(code)
    if not code or type(on) ~= 'boolean' then return fail(ERR.INVALID) end
    if who.staff then
        local staff = type(org.settings.officeStaff) == 'table' and org.settings.officeStaff or Powers.officeDefaults()
        staff[code] = on or nil
        org.settings.officeStaff = staff
    else
        local err = Org.authorize(org, who, 'S3')
        if err then return fail(err) end
        if not Engine.holds(org, who.cid, code) then return fail(ERR.NOT_HELD) end
        local staff = type(org.settings.officeStaff) == 'table' and org.settings.officeStaff or Powers.officeDefaults()
        if not on and staff[code] then return fail(ERR.LOCKED) end
        org.settings.officeBoss[code] = on or nil
    end
    saveOrgRow()
    record('org_office_rule', who, { power = code, on = on })
    return true
end

-- ============================================================================
--                              CUTS
-- ============================================================================

local CUT_KINDS = { payout = 'C1', role = 'C2', member = 'C3', stake = 'C4', buyout = 'C5' }

local function cap(org, kind)
    local total = Powers.limit(org, 'TotalCutCapPercent')
    if kind == 'stake' then return math.min(total, Powers.limit(org, 'StakeCutMaxPercent')) end
    if kind == 'buyout' then return math.min(total, Powers.limit(org, 'BuyoutCutMaxPercent')) end
    return math.min(total, Powers.limit(org, 'CutMaxPercent'))
end

--- The payout cut a member's acceptance freezes now: theirs, their role's,
--- or the organisation's, within the bounds.
---@return integer percent
function Org.payoutPercent(org, member)
    local cuts = org.settings.cuts
    local pct = tonumber(cuts.byMember[member.cid]) or tonumber(cuts.byRole[tostring(member.grade)])
        or tonumber(cuts.payout) or 0
    return math.max(0, math.min(math.floor(pct), Powers.limit(org, 'TotalCutCapPercent')))
end

--- Set one cut. A boss: C1 the organisation's, C2 a role's (below them),
--- C3 a member's (below them), C4 on stakes, C5 on buyouts, each within its
--- bound; 0 is always allowed. Staff: within 0-100 and the total cap.
--- Contracts already accepted keep the cut they were accepted at.
---@param kind string 'payout' | 'role' | 'member' | 'stake' | 'buyout'
---@param target any the grade (role) or citizen id (member)
---@param percent integer|false false clears a role's or member's own
function Org.setCut(who, kind, target, percent)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    local code = CUT_KINDS[kind]
    if not code then return fail(ERR.INVALID) end
    local err = Org.authorize(org, who, code)
    if err then return fail(err) end
    local pct
    if percent ~= false then
        pct = tonumber(percent)
        if not pct or pct ~= math.floor(pct) or pct < 0 or pct > 100 then return fail(ERR.INVALID) end
        local bound = who.staff and Powers.limit(org, 'TotalCutCapPercent') or cap(org, kind)
        if pct > bound then return fail(ERR.BOUNDS, { max = bound }) end
    elseif kind ~= 'role' and kind ~= 'member' then
        return fail(ERR.INVALID)
    end
    local cuts, before = org.settings.cuts, nil
    if kind == 'role' then
        local grade = math.floor(tonumber(target) or -1)
        if not org.roles[grade] then return fail(ERR.NOT_FOUND) end
        if not who.staff and Engine.mayEditRole(org, who.cid, grade) then return fail(ERR.RANK) end
        before = cuts.byRole[tostring(grade)]
        cuts.byRole[tostring(grade)] = pct
    elseif kind == 'member' then
        if type(target) ~= 'string' or not org.members[target] then return fail(ERR.NOT_FOUND) end
        if not who.staff then
            local why = Engine.mayActOn(org, who.cid, target)
            if why then return fail(why == 'self' and ERR.SELF or why == 'locked' and ERR.LOCKED or ERR.RANK) end
        end
        before = cuts.byMember[target]
        cuts.byMember[target] = pct
    else
        before = cuts[kind]
        cuts[kind] = pct
    end
    saveOrgRow()
    record('org_cut_set', who, { kind = kind, target = target ~= nil and tostring(target) or nil,
        from = before, to = pct })
    return true, nil, { from = before, to = pct }
end

--- What a member is told before they accept: the share each kind of money
--- they would receive leaves for the funds. nil for anybody else, or off.
---@param cid string
---@return table|nil { orgPercent, youKeepPercent, stakePercent, buyoutPercent }
function Org.termsFor(cid)
    local org = Org.current()
    local member = org and org.members[cid]
    if not member then return nil end
    local pct = Org.payoutPercent(org, member)
    return {
        orgPercent = pct, youKeepPercent = 100 - pct,
        stakePercent = math.min(math.floor(tonumber(org.settings.cuts.stake) or 0), cap(org, 'stake')),
        buyoutPercent = math.min(math.floor(tonumber(org.settings.cuts.buyout) or 0), cap(org, 'buyout')),
    }
end

--- The split frozen on one member's contract, read once.
local function splitOf(contractId, cid)
    local key = tostring(contractId) .. ':' .. tostring(cid)
    -- Only a split found is kept: a payout to somebody without one is read
    -- again next time, so this never grows with every payout made.
    if Splits[key] == nil then Splits[key] = deps.storage.readOrgRow('splits', key) end
    return Splits[key]
end

--- After an acceptance: the member's cut frozen on the contract, the one
--- the gate checked (and the page showed) before anything was awaited,
--- never read again after the acceptance's own awaits. Run while the
--- acceptance still holds the member (Contracts.accept), so their next one
--- counts this one's cooldown.
---@param gate table|nil what Org.acceptGate kept: { terms }
function Org.afterAccept(actor, contractId, gate)
    local org = Org.current()
    if not org or type(actor) ~= 'table' then return end
    LastAccept[actor.cid] = now()
    local terms
    if type(gate) == 'table' then
        -- Nobody the gate saw as a member is cut, whatever happened since.
        terms = gate.terms
    elseif org.members[actor.cid] then
        terms = Org.termsFor(actor.cid)
    end
    if not terms then return end
    local key = tostring(contractId) .. ':' .. actor.cid
    local row = { id = key, org_id = org.id, contract_id = contractId, cid = actor.cid,
        payout_pct = terms.orgPercent, stake_pct = terms.stakePercent, buyout_pct = terms.buyoutPercent,
        created_at = now() }
    local ok = pcall(deps.storage.writeOrgRow, 'splits', row)
    if ok then
        Splits[key] = row
        deps.audit.financial('org_split_frozen', actor.cid, contractId, { org = org.id,
            payout = row.payout_pct, stake = row.stake_pct, buyout = row.buyout_pct })
    end
end

--- What of this escrow line the funds take as it is given to a member, in
--- dollars, taken now (once: the line's own reference), or already taken
--- on an earlier try. Asked by Escrow.deliver for cash and bank lines; 0
--- for anything else. Off, only what was already taken this process.
---@param recipientCid string
---@param line table
---@return integer
function Org.cutFor(recipientCid, line)
    if type(line) ~= 'table' or type(line.id) ~= 'string' then return 0 end
    local taken = Funds.taken(line.id)
    if taken > 0 or not Org.enabled() then return taken end
    local org = State
    if not org then return 0 end
    if (tonumber(line.deliver_arrived) or 0) > 0 then return 0 end
    local amount = math.floor(tonumber(line.amount) or 0)
    if amount <= 0 then return 0 end
    local split = splitOf(line.contract_id, recipientCid)
    if not split then return 0 end
    local pct, kind = 0, nil
    if line.id:sub(1, 5) == 'prem:' then
        pct, kind = tonumber(split.buyout_pct) or 0, 'buyout'
    elseif line.portion == CH.PORTION.BASELINE or line.portion == CH.PORTION.BONUS then
        pct, kind = tonumber(split.payout_pct) or 0, 'payout'
    elseif line.portion == CH.PORTION.STAKE and line.staker ~= recipientCid then
        pct, kind = tonumber(split.stake_pct) or 0, 'stake'
    end
    pct = math.max(0, math.min(100, math.floor(pct)))
    local cut = math.floor(amount * pct / 100)
    if cut <= 0 then return 0 end
    local ok, ferr = Funds.credit(org, cut, { ref = 'cut:' .. line.id, kind = 'cut', actor = recipientCid,
        contract = line.contract_id, reason = kind, title = 'Contract cut' })
    if not ok then
        -- The bank chosen and not started: the member is paid whole rather
        -- than kept waiting on another resource, and it is on the record.
        if ferr == 'bank_down' then
            deps.audit.financial('org_cut_unavailable', recipientCid, line.contract_id, { org = org.id,
                line = line.id, kind = kind, percent = pct, amount = cut })
        end
        return Funds.taken(line.id)
    end
    deps.audit.financial('org_cut', recipientCid, line.contract_id, { org = org.id, line = line.id,
        kind = kind, percent = pct, amount = cut, of = amount })
    return cut
end

-- ============================================================================
--                              THE ACCEPT GATE
-- ============================================================================

local function shownCut(opts)
    local shown = type(opts) == 'table' and type(opts.shown) == 'table' and opts.shown or nil
    return shown and tonumber(shown.orgCut)
end

--- Before an acceptance: nil to let it through, or why not. Off, nil at
--- once. On, members are held to their suspension, their own and their
--- role's limits and access rules; with RequireJobToAccept, everybody else
--- is refused.
--- `out` keeps the cut checked here, for Org.afterAccept to freeze.
---@return string|nil err
---@return table|nil data
function Org.acceptGate(actor, contractId, opts, out)
    if not Org.enabled() then return nil end
    local org = State
    if not org or type(actor) ~= 'table' then return nil end
    local member = org.members[actor.cid]
    local cfg = Config.Organisation
    if not member then
        if cfg.RequireJobToAccept then
            return ERR.MEMBERS_ONLY, { message = MESSAGES[ERR.MEMBERS_ONLY] }
        end
        return nil
    end
    if cfg.RequireJobToAccept and cfg.AcceptNeedsPower and not Engine.holds(org, actor.cid, Powers.TAKE) then
        return ERR.RULE, { message = 'Your role may not take contracts.' }
    end
    if cfg.OnDutyOnly then
        local job = actor.job
        if type(job) ~= 'table' or job.name ~= org.job or not job.onduty then
            return ERR.OFF_DUTY, { message = MESSAGES[ERR.OFF_DUTY] }
        end
    end
    if member.suspended_until and member.suspended_until > now() then
        return CH.ERR.SUSPENDED, { untilAt = member.suspended_until, org = true }
    end
    local access = org.settings.access[tostring(member.grade)] or {}
    local contract = deps.storage.readContract(contractId)
    if contract then
        if access.rule and contract.fulfilment_rule and access.rule ~= contract.fulfilment_rule then
            return ERR.RULE, { message = MESSAGES[ERR.RULE] }
        end
        if access.whitelisted == false and contract.target_protected then
            return ERR.RULE, { message = MESSAGES[ERR.RULE] }
        end
        if tonumber(access.maxReward) and deps.escrow and deps.escrow.moneyValue then
            local ok, worth = pcall(deps.escrow.moneyValue, contractId)
            if ok and tonumber(worth) and worth > tonumber(access.maxReward) then
                return ERR.RULE, { message = MESSAGES[ERR.RULE] }
            end
        end
    end
    local atOnce = math.min(tonumber(member.limits.maxAtOnce) or math.huge, tonumber(access.maxAtOnce) or math.huge)
    if atOnce < math.huge and deps.storage.countHitmanContracts then
        local ok, held = pcall(deps.storage.countHitmanContracts, actor.cid,
            { active = true, accepted = true, completing = true })
        if ok and tonumber(held) and held >= atOnce then
            return CH.ERR.LIMIT_REACHED, { max = atOnce, org = true }
        end
    end
    local wait = math.max(tonumber(member.limits.cooldownMinutes) or 0, tonumber(access.cooldownMinutes) or 0)
    if wait > 0 and LastAccept[actor.cid] and now() - LastAccept[actor.cid] < wait * 60 then
        return ERR.COOLDOWN, { retryAfter = wait * 60 - (now() - LastAccept[actor.cid]) }
    end
    -- The cut, read once: the one the page must have shown (its board card
    -- says it, and the accept echoes it), and the one frozen.
    local terms = Org.termsFor(actor.cid)
    if type(opts) == 'table' and opts.checkDisclosure and shownCut(opts) ~= terms.orgPercent then
        return CH.ERR.TERMS_CHANGED, { orgCut = terms.orgPercent }
    end
    if type(out) == 'table' then out.terms = terms end
    return nil
end

--- Contract access for one role (K1, cooldowns K3): only ever stricter than
--- the server's own rules, which still apply first.
---@param spec table { maxReward, rule, whitelisted, maxAtOnce, cooldownMinutes } (false clears one)
function Org.setAccess(who, grade, spec, code)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    code = code or 'K1'
    local err = Org.authorize(org, who, code)
    if err then return fail(err) end
    grade = math.floor(tonumber(grade) or -1)
    if not org.roles[grade] then return fail(ERR.NOT_FOUND) end
    if type(spec) ~= 'table' then return fail(ERR.INVALID) end
    if not who.staff and Engine.mayEditRole(org, who.cid, grade) then return fail(ERR.RANK) end
    local access = Util.copy(org.settings.access[tostring(grade)] or {})
    local function whole(v, lo, hi)
        local n = tonumber(v)
        return n and n == math.floor(n) and n >= lo and n <= hi and n or nil
    end
    local fields = code == 'K3' and { cooldownMinutes = true }
        or { maxReward = true, rule = true, whitelisted = true, maxAtOnce = true, cooldownMinutes = who.staff }
    for key, value in pairs(spec) do
        if not fields[key] then return fail(ERR.INVALID) end
        if value == false and key ~= 'whitelisted' then
            access[key] = nil
        elseif key == 'maxReward' then
            access.maxReward = whole(value, 0, 2000000000)
            if not access.maxReward then return fail(ERR.INVALID) end
        elseif key == 'rule' then
            if value ~= 'alive' and value ~= 'either' then return fail(ERR.INVALID) end
            access.rule = value
        elseif key == 'whitelisted' then
            if type(value) ~= 'boolean' then return fail(ERR.INVALID) end
            access.whitelisted = value == false and false or nil
        elseif key == 'maxAtOnce' then
            access.maxAtOnce = whole(value, 1, 50)
            if not access.maxAtOnce then return fail(ERR.INVALID) end
            if not who.staff and access.maxAtOnce > Powers.limit(org, 'MemberMaxAtOnce') then return fail(ERR.BOUNDS) end
        elseif key == 'cooldownMinutes' then
            access.cooldownMinutes = whole(value, 0, 10080)
            if not access.cooldownMinutes then return fail(ERR.INVALID) end
            if not who.staff and access.cooldownMinutes > Powers.limit(org, 'MemberCooldownMaxMinutes') then
                return fail(ERR.BOUNDS)
            end
        end
    end
    org.settings.access[tostring(grade)] = next(access) and access or nil
    saveOrgRow()
    record('org_access', who, { grade = grade, access = access, power = code })
    return true
end

--- Pin a contract to a member as a boss pick (K2), or clear it.
function Org.pick(who, contractId, cid)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    local err = Org.authorize(org, who, 'K2')
    if err then return fail(err) end
    contractId = Util.toId(contractId)
    if not contractId then return fail(ERR.INVALID) end
    local contract = deps.storage.readContract(contractId)
    if not contract or CH.TERMINAL[contract.state] then return fail(ERR.NOT_FOUND) end
    if cid ~= nil and (type(cid) ~= 'string' or not org.members[cid]) then return fail(ERR.NOT_FOUND) end
    -- Answered alike for every member, its own parties included: a refusal
    -- for one of them would tell a boss who placed an anonymous contract
    -- (and which member is its target). Picked, they still cannot take it:
    -- the acceptance refuses its own parties.
    org.settings.picks[contractId] = cid
    saveOrgRow()
    record('org_pick', who, { member = cid }, contractId)
    return true
end

-- ============================================================================
--                              FUNDS
-- ============================================================================

--- A refusal from Funds, as the organisation words it.
local function fundsErr(ferr)
    if ferr == 'short' then return ERR.SHORT end
    if ferr == 'busy' then return ERR.BUSY end
    if ferr == 'limit' then return ERR.LIMIT end
    if ferr == 'bank_down' then return ERR.BANK_DOWN end
    return ERR.REFUSED
end

local function nonceRef(prefix, who, nonce)
    if nonce == nil then return prefix .. ':' .. tostring(who.cid or 'staff') .. ':' .. now() .. ':' .. math.random(1000, 9999) end
    if type(nonce) ~= 'string' or not nonce:match('^[%w_%-]+$') or #nonce > 32 then return nil end
    return prefix .. ':' .. tostring(who.cid or 'staff') .. ':' .. nonce
end

--- The balance and the ledger (C8; staff always).
function Org.fundsView(who, limit)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    local err = Org.authorize(org, who, 'C8')
    if err then return fail(err) end
    limit = math.max(1, math.min(100, math.floor(tonumber(limit) or 50)))
    local rows = Funds.ledger(org, limit)
    if not who.staff then
        for _, r in ipairs(rows) do r.actor = nil end
    end
    return true, nil, { balance = Funds.balance(org), bank = Funds.usesBank(), backend = Funds.backend(),
        ready = Funds.ready(), rows = rows }
end

--- A member's own money into the funds (C6): taken from them first, given
--- back if the funds refuse it.
function Org.deposit(who, amount, account, nonce)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    local err = Org.authorize(org, who, 'C6')
    if err then return fail(err) end
    amount = Funds.amount(amount)
    account = account == 'cash' and 'cash' or (account == 'bank' or account == nil) and 'bank' or nil
    local ref = nonceRef('dep', who, nonce)
    if not amount or not account or not ref then return fail(ERR.INVALID) end
    if Funds.byRef(ref) then return true, nil, { repeated = true } end
    if not Funds.ready() then return fail(ERR.BANK_DOWN) end
    local actor = deps.identity.resolve(who.source)
    if not actor or actor.cid ~= who.cid then return fail(ERR.NOT_MEMBER) end
    if not Util.charge(actor.player, account, amount) then return fail(CH.ERR.INSUFFICIENT) end
    local ok, ferr = Funds.credit(org, amount, { ref = ref, kind = 'deposit', actor = who.cid,
        reason = account, title = 'Member deposit' })
    if not ok then
        Util.credit(actor.player, account, amount)
        return fail(ferr == 'busy' and ERR.BUSY or ferr == 'bank_down' and ERR.BANK_DOWN or ERR.REFUSED)
    end
    record('org_funds_deposit', who, { amount = amount, account = account })
    return true, nil, { amount = amount }
end

--- Money out of the funds to a boss (C7): within WithdrawMax and
--- WithdrawPerDay, with a reason; the funds first, then their pocket, the
--- funds given back if their pocket refuses it.
function Org.withdraw(who, amount, reason, nonce)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    local err = Org.authorize(org, who, 'C7')
    if err then return fail(err) end
    amount = Funds.amount(amount)
    reason = cleanName(reason, 160)
    local ref = nonceRef('wd', who, nonce)
    if not amount or not reason or not ref then return fail(ERR.INVALID) end
    if Funds.byRef(ref) then return true, nil, { repeated = true } end
    -- The day's cap is checked by Funds.debit as it reserves the money, so
    -- two withdrawals at once both count (their rows are not written yet).
    local cap
    if not who.staff then
        if amount > Powers.limit(org, 'WithdrawMax') then return fail(ERR.BOUNDS) end
        cap = { limit = Powers.limit(org, 'WithdrawPerDay'), since = now() - 86400 }
    end
    local actor = not who.staff and deps.identity.resolve(who.source) or nil
    if not who.staff and (not actor or actor.cid ~= who.cid) then return fail(ERR.NOT_MEMBER) end
    local ok, ferr = Funds.debit(org, amount, { ref = ref, kind = 'withdraw', actor = who.cid, reason = reason,
        title = 'Organisation withdrawal', cap = cap })
    if not ok then return fail(fundsErr(ferr)) end
    if actor then
        local paid = Util.credit(actor.player, 'cash', amount)
        if not paid then
            Funds.credit(org, amount, { ref = ref .. ':back', kind = 'refund', actor = who.cid,
                reason = 'withdrawal not paid', title = 'Withdrawal returned' })
            return fail(ERR.REFUSED)
        end
    end
    record('org_funds_withdraw', who, { amount = amount, reason = reason, staff = who.staff or nil })
    return true, nil, { amount = amount }
end

--- Staff only: money into the funds from nowhere, with a reason.
function Org.staffDeposit(who, amount, reason, nonce)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    if not who.staff then return fail(ERR.NO_POWER) end
    amount = Funds.amount(amount)
    reason = cleanName(reason, 160)
    local ref = nonceRef('sdep', who, nonce)
    if not amount or not reason or not ref then return fail(ERR.INVALID) end
    local ok, ferr, repeated = Funds.credit(org, amount, { ref = ref, kind = 'staff', actor = who.cid,
        reason = reason, title = 'Staff deposit' })
    if not ok then return fail(fundsErr(ferr)) end
    if not repeated then record('org_funds_staff_deposit', who, { amount = amount, reason = reason }) end
    return true, nil, { amount = amount, repeated = repeated }
end

--- A one-off bonus from the funds to a member (P2): within BonusMax and
--- BonusPerDay, with a reason, paid to their bank (online or away).
function Org.bonus(who, cid, amount, reason, nonce)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    local err = Org.authorize(org, who, 'P2')
    if err then return fail(err) end
    local member = type(cid) == 'string' and org.members[cid]
    amount = Funds.amount(amount)
    reason = cleanName(reason, 160)
    local ref = nonceRef('bonus', who, nonce)
    if not member then return fail(ERR.NOT_FOUND) end
    if not amount or not reason or not ref then return fail(ERR.INVALID) end
    if Funds.byRef(ref) then return true, nil, { repeated = true } end
    local cap
    if not who.staff then
        if cid == who.cid then return fail(ERR.SELF) end
        if amount > Powers.limit(org, 'BonusMax') then return fail(ERR.BOUNDS) end
        cap = { limit = Powers.limit(org, 'BonusPerDay'), since = now() - 86400 }
    end
    local ok, ferr = Funds.debit(org, amount, { ref = ref, kind = 'bonus', actor = who.cid, reason = reason,
        title = 'Bonus', cap = cap })
    if not ok then return fail(fundsErr(ferr)) end
    local paidOk, paid = pcall(function()
        return exports.qbx_core:AddMoney(cid, 'bank', amount, 'crimson-hitman organisation bonus')
    end)
    if not paidOk or not paid then
        Funds.credit(org, amount, { ref = ref .. ':back', kind = 'refund', actor = who.cid,
            reason = 'bonus not paid', title = 'Bonus returned' })
        return fail(ERR.REFUSED)
    end
    record('org_bonus', who, { member = cid, amount = amount, reason = reason })
    return true, nil, { amount = amount }
end

--- Staff only: keep the funds in the other backend ('internal' | 'bank'),
--- the balance carried across (Funds.switch). `abandon` leaves a bank that
--- is not started with what it holds.
function Org.fundsBackend(who, to, abandon)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    if not who.staff then return fail(ERR.NO_POWER) end
    local ok, ferr, done = Funds.switch(org, to, { actor = who.cid, abandon = abandon == true })
    if not ok then
        return fail(ferr == 'already' and ERR.ALREADY or ferr == 'invalid' and ERR.INVALID or fundsErr(ferr))
    end
    record('org_funds_backend', who, { from = done.from, to = done.to, carried = done.carried,
        abandoned = done.abandoned })
    return true, nil, done
end

-- ============================================================================
--                              LOCATIONS
-- ============================================================================

--- The kinds of place, who may set each, and how many there may be.
Org.SPOTS = {
    office = { power = 'L1', max = function() return 1 end, everyone = false },
    signup = { power = 'L2', max = function(org) return Powers.limit(org, 'MaxSignupSpots') end, everyone = true },
    meeting = { power = 'L3', max = function(org) return Powers.limit(org, 'MaxMeetingSpots') end, everyone = false },
    npc = { power = nil, max = function() return 20 end, everyone = false },
    place = { power = nil, max = function() return 50 end, everyone = false },
}

local function count(org, kind)
    local n = 0
    for _, l in pairs(org.locations) do if l.kind == kind then n = n + 1 end end
    return n
end

--- The server's own position for a player: coords and heading.
---@return table|nil { x, y, z, h }
function Org.positionOf(src)
    src = tonumber(src)
    if not src or src <= 0 then return nil end
    local ok, at, h = pcall(function()
        local ped = GetPlayerPed(src)
        return GetEntityCoords(ped), GetEntityHeading(ped)
    end)
    if not ok or type(at) ~= 'table' and type(at) ~= 'vector3' and type(at) ~= 'userdata' then return nil end
    local x, y, z = tonumber(at.x), tonumber(at.y), tonumber(at.z)
    if not x or not y or not z or (x == 0 and y == 0 and z == 0) then return nil end
    return { x = x, y = y, z = z, h = tonumber(h) or 0 }
end

--- Inside one of the staff safe zones (Config.Improvements.TipSafeZones.Zones,
--- 'x, y, radius, name'), where no organisation spot is placed by a boss.
local function inSafeZone(x, y)
    local zones = type(Config.Improvements) == 'table' and type(Config.Improvements.TipSafeZones) == 'table'
        and Config.Improvements.TipSafeZones.Zones or {}
    for _, text in ipairs(type(zones) == 'table' and zones or {}) do
        local zx, zy, r = tostring(text):match('^%s*(%-?[%d.]+)%s*,%s*(%-?[%d.]+)%s*,%s*([%d.]+)')
        zx, zy, r = tonumber(zx), tonumber(zy), tonumber(r)
        if zx and zy and r and (x - zx) ^ 2 + (y - zy) ^ 2 <= r * r then return true end
    end
    return false
end

local BOUNDS = { minX = -4500, maxX = 6000, minY = -6500, maxY = 8500, minZ = -200, maxZ = 2000 }

--- Place or move a spot. Staff: any kind, from their own position (`here`)
--- or typed coordinates. A boss: the office (L1, near staff's point), a
--- sign-up spot (L2) or a meeting spot (L3), from where they stand only,
--- once per LocationCooldownMinutes, never in a staff safe zone.
---@param spec table { kind, id?, label?, radius?, blip?, enabled?, x?, y?, z?, heading? }
function Org.placeSpot(who, spec)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    if type(spec) ~= 'table' then return fail(ERR.INVALID) end
    local kind = type(spec.kind) == 'string' and Org.SPOTS[spec.kind] and spec.kind or nil
    if not kind then return fail(ERR.INVALID) end
    local def = Org.SPOTS[kind]
    if not who.staff then
        if not def.power then return fail(ERR.NO_POWER) end
        local err = Org.authorize(org, who, def.power)
        if err then return fail(err) end
    end
    local existing = spec.id ~= nil and (type(spec.id) == 'string' and org.locations[spec.id:sub(1, 48)]) or nil
    if spec.id ~= nil and (not existing or existing.kind ~= kind) then return fail(ERR.NOT_FOUND) end
    if kind == 'office' and not existing then
        for _, l in pairs(org.locations) do if l.kind == 'office' then existing = l end end
    end
    local at
    if spec.here or not who.staff then
        at = Org.positionOf(who.source)
        if not at then return fail(ERR.RULE) end
    else
        local x, y, z = tonumber(spec.x), tonumber(spec.y), tonumber(spec.z)
        if not x or not y or not z then return fail(ERR.INVALID) end
        at = { x = x, y = y, z = z, h = tonumber(spec.heading) or 0 }
    end
    if at.x ~= at.x or at.x < BOUNDS.minX or at.x > BOUNDS.maxX or at.y < BOUNDS.minY or at.y > BOUNDS.maxY
        or at.z < BOUNDS.minZ or at.z > BOUNDS.maxZ then
        return fail(ERR.INVALID)
    end
    local radius = spec.radius == nil and (existing and existing.radius / 10 or 2.0) or tonumber(spec.radius)
    if not radius or radius < 0.5 or radius > 50 then return fail(ERR.INVALID) end
    local label = spec.label == nil and (existing and existing.label or kind) or cleanName(spec.label, 64)
    if not label then return fail(ERR.INVALID) end
    if not who.staff then
        if inSafeZone(at.x, at.y) then return fail(ERR.RULE) end
        local moved = org.settings.moves[kind .. ':' .. who.cid]
        if moved and now() - moved < Powers.limit(org, 'LocationCooldownMinutes') * 60 then
            return fail(ERR.COOLDOWN)
        end
        if not existing and count(org, kind) >= def.max(org) then return fail(ERR.LIMIT) end
        if kind == 'office' then
            local anchor = existing and existing.anchor
            if type(anchor) ~= 'table' then return fail(ERR.LOCKED) end
            local reach = Powers.limit(org, 'OfficeMoveMetres')
            if (at.x - anchor.x) ^ 2 + (at.y - anchor.y) ^ 2 > reach * reach then return fail(ERR.BOUNDS) end
        end
    elseif not existing and count(org, kind) >= math.max(def.max(org), kind == 'office' and 1 or 20) then
        return fail(ERR.LIMIT)
    end
    local id = existing and existing.id or ('%s:%s:%d:%d'):format(org.id, kind, now(), math.random(100, 999))
    local loc = {
        id = id:sub(1, 48), org_id = org.id, kind = kind, label = label,
        x = math.floor(at.x * 10 + 0.5), y = math.floor(at.y * 10 + 0.5), z = math.floor(at.z * 10 + 0.5),
        heading = math.floor((at.h or 0) % 360), radius = math.floor(radius * 10 + 0.5),
        blip = spec.blip == nil and (existing and existing.blip or false) or spec.blip == true,
        enabled = spec.enabled == nil and true or spec.enabled == true,
        anchor = who.staff and kind == 'office' and { x = at.x, y = at.y } or (existing and existing.anchor) or nil,
        by_cid = who.cid, updated_at = now(),
    }
    org.locations[loc.id] = loc
    deps.storage.writeOrgRow('locations', loc)
    if not who.staff then
        org.settings.moves[kind .. ':' .. who.cid] = now()
        saveOrgRow()
    end
    record('org_location_set', who, { kind = kind, id = loc.id, x = loc.x / 10, y = loc.y / 10, z = loc.z / 10,
        moved = existing ~= nil or nil })
    Org.pushSpotsAll()
    return true, nil, { id = loc.id, x = at.x, y = at.y, z = at.z, h = at.h }
end

--- Remove a spot: staff any; a boss a sign-up (L2) or meeting (L3) spot.
function Org.removeSpot(who, id)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    local loc = type(id) == 'string' and org.locations[id:sub(1, 48)]
    if not loc then return fail(ERR.NOT_FOUND) end
    if not who.staff then
        local def = Org.SPOTS[loc.kind]
        if not def or not def.power or loc.kind == 'office' then return fail(ERR.NO_POWER) end
        local err = Org.authorize(org, who, def.power)
        if err then return fail(err) end
    end
    org.locations[loc.id] = nil
    deps.storage.deleteOrgRow('locations', loc.id)
    record('org_location_removed', who, { kind = loc.kind, id = loc.id })
    Org.pushSpotsAll()
    return true
end

--- The spots one player may see: the sign-up spots for everybody, the rest
--- for members. Nothing while the organisation is off.
---@return table[]
function Org.spotsFor(cid)
    local org = Org.current()
    if not org then return {} end
    local member = cid and org.members[cid]
    local out = {}
    for _, l in pairs(org.locations) do
        local def = Org.SPOTS[l.kind]
        if l.enabled ~= false and def and (def.everyone or member) then
            out[#out + 1] = { id = l.id, kind = l.kind, label = l.label, x = l.x / 10, y = l.y / 10, z = l.z / 10,
                h = l.heading or 0, radius = (l.radius or 20) / 10, blip = l.blip == true or nil }
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Tell one player's game which spots to draw. Sent only on a change, a
--- login and a start; with none, the game draws nothing and runs nothing.
function Org.pushSpots(src)
    src = tonumber(src)
    if not src or src <= 0 then return end
    local actor = deps.identity.resolve(src)
    local spots = actor and Org.spotsFor(actor.cid) or {}
    TriggerClientEvent('crimson-hitman:orgSpots', src, {
        spots = spots, draw = tonumber(Config.Organisation.DrawMetres) or 40.0,
        model = Config.Organisation.NpcModel,
    })
end

--- Every online player: after a change to the spots, or the switch.
function Org.pushSpotsAll()
    for _, actor in ipairs(deps.identity.online() or {}) do Org.pushSpots(actor.source) end
end

--- A player used a spot (its ox_target option): checked against where the
--- server sees them, and answered with what it is for.
function Org.useSpot(src, id)
    local org = Org.current()
    if not org or type(id) ~= 'string' then return end
    local loc = org.locations[id:sub(1, 48)]
    local actor = deps.identity.resolve(src)
    if not loc or not actor then return end
    local at = Org.positionOf(src)
    local r = (loc.radius or 20) / 10 + 2.0
    if not at or (at.x - loc.x / 10) ^ 2 + (at.y - loc.y / 10) ^ 2 + (at.z - loc.z / 10) ^ 2 > r * r then return end
    local member = org.members[actor.cid]
    local text
    if loc.kind == 'signup' then
        text = member and 'You are already a member.' or 'Apply in the app\'s Organisation tab while you stand here.'
    elseif loc.kind == 'office' and member then
        text = 'The boss office: powers that need it work while you are here.'
    elseif member then
        text = loc.label
    end
    if text and deps.notify and deps.notify.toCitizen then
        pcall(deps.notify.toCitizen, actor.cid, org.label or 'Organisation', text)
    end
end

--- Whether a player stands at a sign-up spot.
local function atSignup(org, src)
    local at = Org.positionOf(src)
    if not at then return false end
    for _, l in pairs(org.locations) do
        if l.kind == 'signup' and l.enabled ~= false then
            local r = (l.radius or 20) / 10 + 2.0
            if (at.x - l.x / 10) ^ 2 + (at.y - l.y / 10) ^ 2 + (at.z - l.z / 10) ^ 2 <= r * r then return true end
        end
    end
    return false
end

-- ============================================================================
--                              NOTICES AND APPLICATIONS
-- ============================================================================

--- The board notice (N1), and optionally a phone notice to every member
--- online. Within NoticeMaxLength; no links or markup.
function Org.notice(who, text, broadcast)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    local err = Org.authorize(org, who, 'N1')
    if err then return fail(err) end
    if text ~= false and type(text) ~= 'string' then return fail(ERR.INVALID) end
    if text then
        text = Util.toValidUtf8(text):gsub('%c', ' ')
        local max = who.staff and 2000 or Powers.limit(org, 'NoticeMaxLength')
        if #text > max or text:find('[<>]') or text:lower():find('https?://') or text:lower():find('discord%.gg') then
            return fail(ERR.BOUNDS)
        end
    end
    org.settings.notice = text and { text = text, at = now() } or nil
    saveOrgRow()
    record('org_notice', who, { length = text and #text or 0, broadcast = broadcast == true or nil })
    if text and broadcast == true and deps.notify and deps.notify.toCitizen then
        for cid in pairs(org.members) do
            if deps.identity.byCitizenId(cid) then pcall(deps.notify.toCitizen, cid, org.label or 'Organisation', text) end
        end
    end
    return true
end

--- A player asks to join (at a sign-up spot, where Config says so). One
--- open application each.
function Org.apply(actor, text)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    if org.members[actor.cid] then return fail(ERR.ALREADY) end
    for _, a in pairs(org.applications) do if a.cid == actor.cid then return fail(ERR.ALREADY) end end
    if text ~= nil and type(text) ~= 'string' then return fail(ERR.INVALID) end
    text = text and Util.toValidUtf8(text):gsub('%c', ' '):sub(1, 255) or nil
    if text and text:find('[<>]') then return fail(ERR.INVALID) end
    if Config.Organisation.ApplyAtSignupOnly ~= false and not atSignup(org, actor.source) then
        return fail(ERR.RULE)
    end
    local row = { id = ('app:%s:%d:%d'):format(org.id, now(), math.random(1000, 9999)):sub(1, 48), org_id = org.id,
        cid = actor.cid, name = actor.name, body = text, state = 'open', created_at = now() }
    deps.storage.writeOrgRow('applications', row)
    org.applications[row.id] = row
    deps.audit.action('org_applied', actor.cid, nil, { org = org.id })
    return true, nil, { id = row.id }
end

--- The open applications (N2).
function Org.applications(who)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    local err = Org.authorize(org, who, 'N2')
    if err then return fail(err) end
    local out = {}
    for _, a in pairs(org.applications) do
        out[#out + 1] = { id = a.id, name = a.name, body = a.body, at = a.created_at }
    end
    table.sort(out, function(a, b) return (a.at or 0) < (b.at or 0) end)
    return true, nil, { rows = out }
end

--- Accept (hire into the lowest role) or reject one (N2).
function Org.decide(who, id, accept)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    local err = Org.authorize(org, who, 'N2')
    if err then return fail(err) end
    local row = type(id) == 'string' and org.applications[id:sub(1, 48)]
    if not row then return fail(ERR.NOT_FOUND) end
    if type(accept) ~= 'boolean' then return fail(ERR.INVALID) end
    -- One who is a member already (hired or adopted since they applied): the
    -- application is closed, never accepted over the record they have.
    if org.members[row.cid] then
        Org.closeApplications(org, row.cid, 'member')
        record('org_application_superseded', who, { member = row.cid })
        return fail(ERR.ALREADY)
    end
    if accept then
        if row.cid == who.cid then return fail(ERR.SELF) end
        local members = 0
        for _ in pairs(org.members) do members = members + 1 end
        if not who.staff and members >= Powers.limit(org, 'MaxMembers') then return fail(ERR.LIMIT) end
        local lowest
        for g in pairs(org.roles) do if not lowest or g < lowest then lowest = g end end
        if not lowest then return fail(ERR.NOT_FOUND) end
        -- They asked to join, so the job is made their primary one where
        -- Config says so, as an invite they accept is.
        local member, code = enrol(org, { cid = row.cid, name = row.name }, lowest,
            Config.Organisation.SetPrimaryOnHire ~= false)
        if not member then return fail(ERR.REFUSED, { qbx = code }) end
    end
    row.state, row.decided_by, row.decided_at = accept and 'accepted' or 'rejected', who.cid, now()
    deps.storage.writeOrgRow('applications', row)
    org.applications[row.id] = nil
    record('org_application', who, { member = row.cid, accepted = accept })
    local applicant = deps.identity.byCitizenId(row.cid)
    if applicant then Org.pushSpots(applicant.source) end
    return true
end

-- ============================================================================
--                              SETTINGS
-- ============================================================================

--- The organisation's display label (S1), never the job name: within
--- RenameCooldownMinutes for a boss, told to qbx_core.
function Org.rename(who, label)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    local err = Org.authorize(org, who, 'S1')
    if err then return fail(err) end
    label = cleanName(label, 64)
    if not label or label:lower():find('https?://') then return fail(ERR.INVALID) end
    if not who.staff and org.settings.labelAt
        and now() - org.settings.labelAt < Powers.limit(org, 'RenameCooldownMinutes') * 60 then
        return fail(ERR.COOLDOWN)
    end
    local before = org.label
    org.label = label
    if not who.staff then org.settings.labelAt = now() end
    saveOrgRow()
    Jobs.upsertData(org)
    record('org_renamed', who, { from = before, to = label })
    return true
end

local TABS = { members = true, roles = true, pay = true, funds = true, contracts = true, locations = true,
    notices = true, settings = true, log = true }

--- The boss menu's tab labels and the tabs hidden from a role (S2).
---@param spec table { labels = { [tab] = text|false }, hidden = { [tab] = { grade, ... } } }
function Org.layout(who, spec)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    local err = Org.authorize(org, who, 'S2')
    if err then return fail(err) end
    if type(spec) ~= 'table' then return fail(ERR.INVALID) end
    local layout = { labels = {}, hidden = {} }
    for tab, text in pairs(type(spec.labels) == 'table' and spec.labels or {}) do
        if not TABS[tab] then return fail(ERR.INVALID) end
        if text ~= false then
            local clean = cleanName(text, 24)
            if not clean then return fail(ERR.INVALID) end
            layout.labels[tab] = clean
        end
    end
    for tab, grades in pairs(type(spec.hidden) == 'table' and spec.hidden or {}) do
        if not TABS[tab] or type(grades) ~= 'table' then return fail(ERR.INVALID) end
        local list = {}
        for _, g in ipairs(grades) do
            g = tonumber(g)
            if not g or not org.roles[g] then return fail(ERR.INVALID) end
            list[#list + 1] = g
        end
        layout.hidden[tab] = list
    end
    org.settings.layout = layout
    saveOrgRow()
    record('org_layout', who, {})
    return true
end

-- ============================================================================
--                              READS
-- ============================================================================

--- A member as somebody else in the organisation sees them.
local function memberView(org, viewer, m, full)
    local role = org.roles[m.grade]
    local online = deps.identity.byCitizenId(m.cid) ~= nil
    local out = {
        ref = Org.refFor(viewer, m.cid), name = m.codename or m.name, grade = m.grade,
        role = role and role.label or nil, online = online, lastSeen = m.last_seen,
        joined = m.joined_at, suspendedUntil = m.suspended_until, locked = m.locked or nil,
        boss = role and role.is_boss or nil,
    }
    if full then
        out.grants, out.denies = {}, {}
        for code, entry in pairs(m.grants) do
            out.grants[code] = { by = entry.by == 'staff' and 'staff' or 'boss',
                inactive = Engine.inactiveWhy(org, m.cid, entry, code) }
        end
        for code, entry in pairs(m.denies) do out.denies[code] = entry.by == 'staff' and 'staff' or 'boss' end
        out.limits = m.limits
        out.held = Engine.held(org, m.cid)
    end
    return out
end
Org.memberView = memberView

--- What a player's own Organisation tab shows: their place, what they hold,
--- the notice and the cut they would accept at. Off: { enabled = false }.
function Org.mine(actor)
    local org = Org.current()
    if not org then return { enabled = false } end
    local member = org.members[actor.cid]
    if not member then
        local open = false
        for _, a in pairs(org.applications) do if a.cid == actor.cid then open = true end end
        return { enabled = true, member = false, label = org.label, applied = open or nil,
            invite = Org.inviteFor(actor.cid) }
    end
    local role = org.roles[member.grade]
    local held = Engine.held(org, actor.cid)
    local office = {}
    for code in pairs(held) do if Engine.needsOffice(org, code) then office[code] = true end end
    return {
        enabled = true, member = true, label = org.label, grade = member.grade, role = role and role.label,
        powers = held, officeOnly = office, inOffice = Org.inOffice(org, actor.source),
        notice = org.settings.notice and org.settings.notice.text or nil,
        terms = Org.termsFor(actor.cid), suspendedUntil = member.suspended_until,
        limits = member.limits, layout = org.settings.layout,
    }
end

--- The roster (M1).
function Org.members(who)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    local err = Org.authorize(org, who, 'M1')
    if err then return fail(err) end
    local out = {}
    for _, m in pairs(org.members) do out[#out + 1] = memberView(org, who.cid or 'staff', m, who.staff) end
    table.sort(out, function(a, b)
        if a.grade ~= b.grade then return a.grade > b.grade end
        return tostring(a.name) < tostring(b.name)
    end)
    return true, nil, { rows = out }
end

--- The roles, for a boss holding any role or pay power (or M1).
function Org.roles(who)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    if not who.staff then
        local any = false
        if not org.members[who.cid] then return fail(ERR.NOT_MEMBER) end
        for _, code in ipairs({ 'M1', 'R1', 'R2', 'R3', 'R4', 'P1', 'C2', 'K1', 'K3' }) do
            if Engine.holds(org, who.cid, code) then any = true end
        end
        if not any then return fail(ERR.NO_POWER) end
    end
    local own = not who.staff and org.members[who.cid].grade or math.huge
    local out = {}
    for grade, r in pairs(org.roles) do
        local powers = {}
        for code, entry in pairs(r.powers) do
            powers[code] = { by = entry.by == 'staff' and 'staff' or 'boss' }
        end
        out[#out + 1] = { grade = grade, name = r.name, label = r.label, pay = r.pay, boss = r.is_boss or nil,
            locked = r.locked or nil, members = Engine.countAt(org, grade), powers = powers,
            editable = who.staff or (grade < own and not r.locked) or nil,
            cut = org.settings.cuts.byRole[tostring(grade)], access = org.settings.access[tostring(grade)] }
    end
    table.sort(out, function(a, b) return a.grade > b.grade end)
    return true, nil, { rows = out }
end

--- Everything, for staff (orgGet).
function Org.staffView(viewer)
    if not Org.enabled() then
        return { enabled = false, job = orgId() }
    end
    local org = State
    if not org then return { enabled = true, loaded = false, job = orgId() } end
    local _, _, members = Org.members({ staff = true, cid = viewer })
    local _, _, roles = Org.roles({ staff = true, cid = viewer })
    local ceiling = { role = {}, member = {} }
    for grade, cells in pairs(org.ceiling.role) do ceiling.role[tostring(grade)] = Util.copy(cells) end
    for cid, cells in pairs(org.ceiling.member) do ceiling.member[Org.refFor(viewer, cid)] = Util.copy(cells) end
    local spots = {}
    for _, l in pairs(org.locations) do
        spots[#spots + 1] = { id = l.id, kind = l.kind, label = l.label, x = l.x / 10, y = l.y / 10, z = l.z / 10,
            heading = l.heading, radius = (l.radius or 20) / 10, blip = l.blip, enabled = l.enabled ~= false }
    end
    table.sort(spots, function(a, b) return a.id < b.id end)
    local limits = {}
    for key in pairs(Powers.LIMIT_KEYS) do limits[key] = Powers.limit(org, key) end
    local officeStaff = type(org.settings.officeStaff) == 'table' and org.settings.officeStaff or Powers.officeDefaults()
    local _, _, apps = Org.applications({ staff = true })
    return {
        enabled = true, loaded = true, job = org.job, label = org.label, type = org.jobType,
        requireJob = Config.Organisation.RequireJobToAccept == true,
        roles = roles and roles.rows or {}, members = members and members.rows or {}, ceiling = ceiling,
        spots = spots, cuts = Util.copy(org.settings.cuts), limits = limits, officeStaff = officeStaff,
        officeBoss = org.settings.officeBoss, notice = org.settings.notice, access = org.settings.access,
        balance = Funds.balance(org), bank = Funds.usesBank(), fundsBackend = Funds.backend(),
        fundsReady = Funds.ready(), applications = apps and apps.rows or {},
        powers = Powers.LIST, warnings = Jobs.checkConvars(),
    }
end

return Org
