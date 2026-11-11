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
local Geo = CrimsonBoot.requireShared('geo')
local Window = CrimsonBoot.require('server.lib.window')
local Powers = CrimsonBoot.require('server.org.powers')
local Engine = CrimsonBoot.require('server.org.engine')
local Jobs = CrimsonBoot.require('server.org.jobs')
local Funds = CrimsonBoot.require('server.org.funds')
local Feature = CrimsonBoot.require('server.lib.feature')
local Places = CrimsonBoot.require('server.places')
local Integrations = CrimsonBoot.require('server.adapters.init')
local Extras = CrimsonBoot.require('server.org.extras')
local Extras2 = CrimsonBoot.require('server.org.extras2')
local Extras3 = CrimsonBoot.require('server.org.extras3')
local L = CrimsonBoot.requireShared('locale').t

--- The adapters answering now (server/adapters/): nil while none does.
local function Framework() return Integrations.get('framework') end

local Org = {}

Org.Powers, Org.Engine, Org.Jobs, Org.Funds, Org.Extras, Org.Extras2 = Powers, Engine, Jobs, Funds, Extras, Extras2
Org.Extras3 = Extras3

local deps

--- The organisation in memory, or nil while none is loaded:
--- { id, job, label, jobType, settings, created_at,
---   roles = { [grade] = role }, members = { [cid] = member },
---   ceiling = { role = { [grade] = { [code] = 'allow' } },
---               member = { [cid] = { [code] = 'allow' | 'deny' } } },
---   locations = { [id] = location }, applications = { [id] = row } }
---
--- Several organisations (Config.Organisation.SeveralOrganisations, off as
--- shipped): every one loaded is kept here by its id, the first (the
--- config.lua one, Config.Organisation.JobName) first. Off, only that one.
local Orgs, Order = {}, {}

--- The organisation each running request works on: [coroutine] = org.
--- Set by Org.within at every way in (a player's request: their own
--- organisation; a staff op: the one it names; a tick: each in turn), so
--- the functions below keep reading "the" organisation as they always did.
--- Keyed by coroutine, because a request that waits (the store, a bank)
--- lets another run meanwhile. With none set, the first organisation.
local Ctx = setmetatable({}, { __mode = 'k' })

local function Cur()
    local org = Ctx[coroutine.running()]
    if org then return org end
    local first = Order[1]
    return first and Orgs[first] or nil
end

--- The cut frozen on each contract a member took: [contract:cid] = row.
local Splits = {}

--- Contracts with no split for a member, already looked for, so a page
--- shown again does not read the store again: [contract:cid] = true. Only
--- Org.afterAccept writes a split, and it clears its key here; emptied
--- whole when it grows large (Org.shownName).
local NoSplit, NoSplitCount = {}, 0

--- Salaries (Org.payrollTick) being paid in this process right now, so a second tick never
--- takes one mid-payment for one the server stopped on: [ref] = true. And
--- those paid here whose marker the store would not take: [ref] = true.
local Paying, PaidHere = {}, {}

--- When each member last accepted, for the cooldowns: [cid] = os.time().
local LastAccept = {}

--- When each boss last fired a member, for FireCooldownMinutes: [cid] = os.time().
local LastFire = {}

--- Each boss's role moves in the last day, for PromotionsPerDay (Window.new).
local Promotions = Window.new(86400)

--- Hires a boss offered, waiting for the player to accept them in the app:
--- [cid] = { id, cid, grade, by (the boss's cid), at, expires }. Kept in
--- memory only: a restart forgets them, and the boss asks again.
local Invites = {}

--- When each player last loaded (Org.playerLoaded), against when the job
--- was registered this process (Jobs.register), by a sequence: a player
--- who loaded after it is one qbx_core could show the job to.
local LoadedSeq, RegisteredSeq, Seq = {}, {}, 0

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
    NAME_TAKEN = 'org_name_taken', NAME_BLOCKED = 'org_name_blocked', FEATURE_OFF = 'org_feature_off',
    RESERVED = 'org_reserved', APPROVAL = 'org_approval', PROBATION = 'org_probation',
    OTHER_ORG = 'org_other_org', TIER = 'org_tier',
}
local ERR = Org.ERR

local MESSAGES = {
    org_off = L('org.the_organisation_is_switched_off'),
    org_not_member = L('org.not_a_member_of_the_organisation'),
    org_no_power = L('org.staff_have_not_given_you_this'),
    org_office = L('org.that_needs_the_boss_office_go'),
    org_rank = L('org.only_below_your_own_rank'),
    org_self = L('org.not_on_yourself'),
    org_locked = L('org.staff_have_locked_that'),
    org_last_boss = L('org.the_organisation_would_be_left_with'),
    org_bounds = L('org.outside_the_bounds_staff_set'),
    org_cooldown = L('org.too_soon_wait_a_while_first'),
    org_limit = L('org.at_the_limit_staff_set'),
    org_not_found = L('org.not_found_refresh_and_try_again'),
    org_refused = L('org.qbx_core_refused_it_nothing_was'),
    org_short = L('org.the_funds_do_not_hold_that'),
    org_busy = L('org.already_being_done_try_again_in'),
    org_members_only = L('org.only_members_of_the_organisation_may'),
    org_rule = L('org.the_organisation_does_not_let_your'),
    org_already = L('org.already_so'),
    org_off_duty = L('org.go_on_duty_first'),
    org_not_held = L('org.you_can_only_pass_on_a'),
    org_bank_down = L('org.the_organisations_bank_account_cannot_be'),
    org_name_taken = L('org.another_member_already_goes_by_that'),
    org_name_blocked = L('org.that_codename_is_not_allowed_pick'),
    org_feature_off = L('org.staff_have_not_switched_that_on'),
    org_reserved = L('org.that_contract_is_held_for_the'),
    org_approval = L('org.sent_to_a_boss_for_approval'),
    org_probation = L('org.on_probation_you_may_not_take'),
    org_other_org = L('org.they_are_a_member_of_another'),
    org_tier = L('org.the_organisations_reputation_does_not_unlock'),
    invalid_input = L('org.check_what_was_entered'),
}

---@param err string
---@return string
function Org.message(err) return MESSAGES[err] or L('org.not_done') end

local function fail(err, extra)
    return false, err, extra, MESSAGES[err] or L('org.not_done')
end

-- ============================================================================
--                              SWITCHES AND STATE
-- ============================================================================

--- The organisation in force, or nil (off, or not loaded).
---@return table|nil
function Org.current()
    if not Feature.on('Organisation') then return nil end
    return Cur()
end

--- Run fn with `org` as the organisation every function here works on, in
--- this coroutine only; put back after, whatever fn did.
---@param org table
---@param fn function
function Org.within(org, fn, ...)
    local co = coroutine.running()
    local before = Ctx[co]
    Ctx[co] = org
    local res = table.pack(pcall(fn, ...))
    Ctx[co] = before
    if not res[1] then error(res[2], 0) end
    return table.unpack(res, 2, res.n)
end

--- Whether staff may keep more than one organisation.
---@return boolean
function Org.severalOn()
    return Feature.on('Organisation') and Config.Organisation.SeveralOrganisations == true
end

--- One organisation loaded, by its id, or nil.
---@param id any
---@return table|nil
function Org.byId(id)
    if not Feature.on('Organisation') or type(id) ~= 'string' or #id > 32 then return nil end
    return Orgs[id]
end

--- Every organisation loaded, the first first.
---@return table[]
function Org.all()
    local out = {}
    if not Feature.on('Organisation') then return out end
    for _, id in ipairs(Order) do if Orgs[id] then out[#out + 1] = Orgs[id] end end
    return out
end

--- The organisation a citizen is a member of, or nil. A citizen is a
--- member of one at most (Org.hire refuses a second).
---@param cid any
---@return table|nil
function Org.orgOf(cid)
    if type(cid) ~= 'string' then return nil end
    for _, id in ipairs(Order) do
        local org = Orgs[id]
        if org and org.members[cid] then return org end
    end
    return nil
end

--- A member of another organisation than `org`.
local function memberElsewhere(cid, org)
    local other = Org.orgOf(cid)
    return other ~= nil and other ~= org
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

local function roleId(grade) return Cur().id .. ':' .. tostring(grade) end
local function memberId(cid) return Cur().id .. ':' .. cid end

local function saveOrgRow(org)
    org = org or Cur()
    deps.storage.writeOrgRow('orgs', { id = org.id, job = org.job, label = org.label,
        job_type = org.jobType, settings = org.settings, created_at = org.created_at,
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
    -- Codenames (Config.Organisation.Codenames): who gave each and when.
    s.codenames = type(s.codenames) == 'table' and s.codenames or {}
    -- Payroll (Config.Organisation.Payroll): salary and staff max by grade,
    -- and when the next pay day falls.
    s.payroll = type(s.payroll) == 'table' and s.payroll or {}
    s.payroll.salary = type(s.payroll.salary) == 'table' and s.payroll.salary or {}
    s.payroll.max = type(s.payroll.max) == 'table' and s.payroll.max or {}
    -- A boss's salaries waiting for their first pay day, and salaries a
    -- bank refused whose give-back to the funds is to be tried again.
    s.payroll.pending = type(s.payroll.pending) == 'table' and s.payroll.pending or {}
    s.payroll.refunds = type(s.payroll.refunds) == 'table' and s.payroll.refunds or {}
    -- Organisation extras (server/org/extras.lua): contracts sent to the
    -- organisation, probation counts and channel mutes, by contract or cid.
    s.orgContracts = type(s.orgContracts) == 'table' and s.orgContracts or {}
    s.probation = type(s.probation) == 'table' and s.probation or {}
    s.channelMutes = type(s.channelMutes) == 'table' and s.channelMutes or {}
    -- Organisation extras 2 (server/org/extras2.lua): the armory's role
    -- limits and short log, each member's counts, the discipline record
    -- and the suspensions strikes made, the application form.
    s.armory = type(s.armory) == 'table' and s.armory or {}
    s.armory.limits = type(s.armory.limits) == 'table' and s.armory.limits or {}
    s.armory.log = type(s.armory.log) == 'table' and s.armory.log or {}
    s.stats = type(s.stats) == 'table' and s.stats or {}
    s.discipline = type(s.discipline) == 'table' and s.discipline or {}
    s.strikeSuspended = type(s.strikeSuspended) == 'table' and s.strikeSuspended or {}
    s.recruit = type(s.recruit) == 'table' and s.recruit or {}
    s.recruit.questions = type(s.recruit.questions) == 'table' and s.recruit.questions or {}
    s.recruit.cooldowns = type(s.recruit.cooldowns) == 'table' and s.recruit.cooldowns or {}
    s.recruit.notes = type(s.recruit.notes) == 'table' and s.recruit.notes or {}
    -- Several organisations (the first one's row only): the ids of the
    -- others staff made, in the order they were made.
    s.others = type(s.others) == 'table' and s.others or {}
    -- Organisation extras 3 (server/org/extras3.lua): reputation, dead drops
    -- waiting, the garage's models a boss took off, internal contract
    -- requests and the activity log.
    s.rep = type(s.rep) == 'table' and s.rep or {}
    s.drops = type(s.drops) == 'table' and s.drops or {}
    s.garage = type(s.garage) == 'table' and s.garage or {}
    s.garage.off = type(s.garage.off) == 'table' and s.garage.off or {}
    s.internal = type(s.internal) == 'table' and s.internal or {}
    s.activity = type(s.activity) == 'table' and s.activity or {}
    if s.payoutMethod ~= 'deaddrop' then s.payoutMethod = nil end
    return s
end

--- Read the organisation from the store, making it from config.lua the
--- first time (its roles from Config.Organisation.Roles).
local fill

---@param id string|nil the organisation's id (nil: the first, from config.lua)
---@param spec table|nil a new one's { job, label, jobType } (Org.create)
local function load(id, spec)
    id = id or orgId()
    local storage = deps.storage
    local row = storage.readOrgRow('orgs', id)
    local created = false
    if not row then
        if spec == nil and id ~= orgId() then return nil end
        spec = spec or {}
        row = { id = id, job = spec.job or id, label = spec.label or Config.Organisation.JobLabel or id,
            job_type = spec.jobType or Config.Organisation.JobType or 'hitman', settings = {}, created_at = now() }
        storage.writeOrgRow('orgs', row)
        created = true
    end
    local State = {
        id = row.id, job = row.job or id, label = row.label, jobType = row.job_type,
        settings = settingsOf(row.settings), created_at = row.created_at,
        roles = {}, members = {}, ceiling = { role = {}, member = {} }, locations = {}, applications = {},
    }
    Org.within(State, fill, State, id, created)
    return State
end

fill = function(State, id, created)
    local storage = deps.storage
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
    -- Its spots are kept by the one registry of map spots (server/places.lua).
    State.locations = Places.owned(id)
    for _, a in ipairs(storage.readOrgRows('applications', id) or {}) do
        if a.state == 'open' then State.applications[a.id] = a end
    end
    Funds.load(State)
    if created then
        deps.audit.staff('org_created', nil, nil, { org = id, roles = #(Config.Organisation.Roles or {}) })
    end
end

local registerSpots -- LOCATIONS, below

function Org.init(d)
    deps = d
    -- A member's codename where a hitman's name is shown (Org.shownName).
    Util.shownHitmanName = function(cid, name, contractId) return Org.shownName(cid, name, contractId) end
    Orgs, Order, Splits, LastAccept, LastFire, Refs, RefSeq = {}, {}, {}, {}, {}, {}, 0
    Ctx = setmetatable({}, { __mode = 'k' })
    Promotions.reset()
    NoSplit, NoSplitCount = {}, 0
    Invites, LoadedSeq, RegisteredSeq, Seq = {}, {}, {}, 0
    Paying, PaidHere = {}, {}
    Jobs.reset()
    Funds.init({ storage = d.storage, audit = d.audit, review = d.review })
    Extras.init(d)
    Extras2.init(d)
    Extras3.init(d)
    Places.attach(d.storage)
    -- The panel's Locations ops on the organisation data.org names.
    Places.scope = function(data, fn)
        local wanted = type(data) == 'table' and data.org or nil
        if wanted == nil then return fn() end
        local org = Org.byId(wanted)
        if not org then return false, ERR.NOT_FOUND, L('org.no_such_organisation_refresh_the_page') end
        return Org.within(org, fn)
    end
    registerSpots()
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
        d.settings.watch('Organisation.SeveralOrganisations', function() Org.boot(true) end)
    end
end

--- Register one organisation's job and make sure of its funds account.
local function bring(org)
    if Jobs.register(org) then
        Seq = Seq + 1
        RegisteredSeq[org.id] = Seq
    end
    Funds.ensureAccount(org)
end

--- Start the organisation, where it is on: read it, register the job,
--- make sure of the funds account, and bring every online player in step
--- (a start after players loaded leaves qbx_core without their job). Off,
--- nothing; turned off live, players are told their places are gone, and
--- the job stays registered until the next start, which registers none.
---@param live boolean|nil turned on or off from the panel
function Org.boot(live)
    if not Feature.on('Organisation') then
        if live and Order[1] then
            Orgs, Order = {}, {}
            Extras.rebuild()
            Org.pushSpotsAll()
        end
        return false
    end
    local ok, first = pcall(load)
    if not ok or not first then
        Log.always(('the hitman organisation could not be read: %s; it stays off until the next start')
            :format(Util.dbError and Util.dbError(first) or tostring(first)))
        Orgs, Order = {}, {}
        return false
    end
    Orgs, Order = { [first.id] = first }, { first.id }
    -- The others staff made (SeveralOrganisations), each read the same way;
    -- one that cannot be read stays out until the next start, and is said.
    if Org.severalOn() then
        for _, id in ipairs(first.settings.others) do
            if type(id) == 'string' and not Orgs[id] then
                local okO, other = pcall(load, id)
                if okO and other then
                    Orgs[id] = other
                    Order[#Order + 1] = id
                else
                    Log.always(('the hitman organisation %s could not be read: %s; it stays out until the next start')
                        :format(id, tostring(other)))
                end
            end
        end
    end
    Jobs.checkConvars()
    for _, id in ipairs(Order) do bring(Orgs[id]) end
    Extras.loaded()
    Extras3.loaded()
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
        warn[#warn + 1] = (L('org.organisation_using')):format(key, why, tostring(shipped[key]))
        cfg[key] = Util.copy(shipped[key])
    end
    for _, key in ipairs({ 'Enabled', 'RequireJobToAccept', 'AcceptNeedsPower', 'OnDutyOnly', 'DefaultDuty',
        'SetPrimaryOnHire', 'QbxBossFlag', 'ApplyAtSignupOnly' }) do
        if type(cfg[key]) ~= 'boolean' then back(key, L('org.is_not_true_or_false')) end
    end
    if type(cfg.JobName) ~= 'string' or not cfg.JobName:match('^[a-z][a-z0-9_]*$') or #cfg.JobName > 32 then
        back('JobName', L('org.must_be_a_lower_case_qbx'))
    end
    for _, key in ipairs({ 'JobLabel', 'JobType' }) do
        if type(cfg[key]) ~= 'string' or cfg[key] == '' or #cfg[key] > 64 then back(key, L('org.must_be_a_short_text')) end
    end
    if cfg.ExternalChanges ~= 'adopt' and cfg.ExternalChanges ~= 'revert' then
        back('ExternalChanges', "is 'adopt' or 'revert'")
    end
    for _, key in ipairs({ 'OfficeRadius', 'DrawMetres' }) do
        local n = tonumber(cfg[key])
        if not n or n <= 0 or n > 500 then back(key, L('org.must_be_a_distance_above_0')) end
    end
    if type(cfg.Roles) ~= 'table' then back('Roles', L('org.must_be_a_list')) end
    for _, text in ipairs(type(cfg.Roles) == 'table' and cfg.Roles or {}) do
        if not parseRole(text) then
            back('Roles', (L('org.has_a_line_that_is_not')):format(tostring(text)))
            break
        end
    end
    if type(cfg.NpcModel) ~= 'string' or not cfg.NpcModel:match('^[%w_]+$') then back('NpcModel', L('org.must_be_a_ped_model_name')) end
    Extras.validate(warn)
    Extras2.validate(warn)
    Extras3.validate(warn)
    Feature.check('Organisation', Org.CHECKS, warn)
    if type(cfg.Limits) ~= 'table' then
        back('Limits', L('org.must_be_a_table'))
    else
        for key, spec in pairs(Powers.LIMIT_KEYS) do
            local n = tonumber(cfg.Limits[key])
            if cfg.Limits[key] ~= nil and (not n or n < spec.min or n > spec.max or (not spec.float and n ~= math.floor(n))) then
                warn[#warn + 1] = (L('org.organisation_limits_must_be_to_using')):format(key, spec.min, spec.max,
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
    -- A member of another organisation is never adopted into this one too.
    if adopt and grade ~= nil and memberElsewhere(actor.cid, org) then adopt = false end
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
    local org = Cur()
    local registered = org and RegisteredSeq[org.id]
    return registered ~= nil and at ~= nil and at > registered
end

--- A character in, or a job change (QBCore:Server:OnJobUpdate).
function Org.playerLoaded(src)
    if not Org.current() then return end
    src = tonumber(src)
    if src then
        Seq = Seq + 1
        LoadedSeq[src] = Seq
        -- A character in again starts off duty (Config.Organisation.Duty).
        if Extras.on('Duty') then
            local actor = deps.identity.resolve(src)
            if actor then Extras.playerLoaded(actor.cid) end
        end
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
    local at
    for _, loc in pairs(org.locations) do
        if loc.kind == 'office' and loc.enabled ~= false then
            at = at or Geo.position(src)
            if not at then return false end
            local radius = math.max(tonumber(Config.Organisation.OfficeRadius) or 5, loc.radius or 0)
            if Geo.near(at, loc, radius) then return true end
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
    local cur = Cur()
    detail.org = cur and cur.id or nil
    detail.by = who.staff and 'staff' or 'boss'
    if who.staff then
        deps.audit.staff(action, who.cid, contract, detail)
    else
        deps.audit.action(action, who.cid, contract, detail)
    end
    -- The organisation's own activity log (Config.Organisation.ActivityLog).
    Extras3.logAction(action, who, detail)
end
Org.record = record

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
    if memberElsewhere(target.cid, org) then return nil, 'other_org' end
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
    if memberElsewhere(target.cid, org) then return fail(ERR.OTHER_ORG) end
    if grade == nil then
        for g in pairs(org.roles) do if grade == nil or g < grade then grade = g end end
    end
    grade = math.floor(tonumber(grade) or -1)
    if not org.roles[grade] then return fail(ERR.NOT_FOUND) end
    if who.staff then
        local member, code = enrol(org, target, grade, false)
        if not member and code == 'other_org' then return fail(ERR.OTHER_ORG) end
        if not member then return fail(ERR.REFUSED, { qbx = code }) end
        record('org_member_hired', who, { member = target.cid, grade = grade })
        if target.source then Org.pushSpots(target.source) end
        return true, nil, { grade = grade }
    end
    local why = bossMayHire(org, who.cid, target.cid, grade)
    if why then return fail(why) end
    -- In person: the server's own positions, never the client's.
    local radius = Powers.limit(org, 'HireRadius')
    local a = target.source and Geo.position(who.source)
    local b = a and Geo.position(target.source)
    if not b or GetPlayerRoutingBucket(who.source) ~= GetPlayerRoutingBucket(target.source)
        or not Geo.near(a, b, radius) then
        return fail(ERR.RULE, { message = (L('org.they_must_be_in_the_city'))
            :format(tostring(radius)) })
    end
    if inviteOf(target.cid) then return fail(ERR.ALREADY) end
    local minutes = Powers.limit(org, 'InviteMinutes')
    RefSeq = RefSeq + 1
    local invite = { id = ('inv%d_%d'):format(RefSeq, math.random(1000, 9999)), cid = target.cid, grade = grade,
        by = who.cid, at = now(), expires = now() + minutes * 60, org = org.id }
    Invites[target.cid] = invite
    record('org_member_invited', who, { member = target.cid, grade = grade })
    -- The organisation and the role, never who asked.
    if deps.notify and deps.notify.toCitizen then
        local role = org.roles[grade]
        pcall(deps.notify.toCitizen, target.cid, org.label or L('org.organisation'),
            (L('org.you_are_invited_to_join_as'))
                :format(role and role.label or L('org.a_member'), minutes))
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
    if memberElsewhere(actor.cid, org) then return fail(ERR.OTHER_ORG) end
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
        local last = LastFire[who.cid]
        if last and now() - last < Powers.limit(org, 'FireCooldownMinutes') * 60 then
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
    if not who.staff then LastFire[who.cid] = now() end
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
        if Promotions.count(who.cid, now()) >= Powers.limit(org, 'PromotionsPerDay') then
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
    if not who.staff then Promotions.add(who.cid, now()) end
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
            org.settings.codenames[cid] = nil
        else
            local clean, why = Org.checkCodename(org, fields.codename, cid)
            if not clean then return fail(why) end
            member.codename = clean
            org.settings.codenames[cid] = { by = 'staff', at = now() }
        end
        saveOrgRow()
    end
    saveMember(member)
    record('org_member_staff', who, { member = cid, locked = member.locked, codename = member.codename })
    return true
end

-- ============================================================================
--                              CODENAMES
-- ============================================================================
-- Config.Organisation.Codenames (off as shipped). A member picks their own,
-- or a boss holding M7 (Assign codenames) gives one to a member below them;
-- one given by a boss or staff is theirs to change, not the member's. Shown
-- inside the organisation, and to placers and targets in place of the
-- member's name only where their name would have been shown at all: a
-- hitman who took a contract anonymously is still nobody. Off, nothing
-- reads one and every name is shown as before.

--- Whether codenames are on now.
---@return boolean
function Org.codenamesOn()
    return Feature.on('Organisation') and Config.Organisation.Codenames == true
end

--- The letters a codename is checked with: lower case, letters only, the
--- look-alike swaps folded to one letter (1, l, i and ! to 'i'; 0 to 'o';
--- 3 to 'e'; 4 and @ to 'a'; 5 and $ to 's'; 7 to 't'), and separators
--- (spaces, - and _, any punctuation) dropped: so 'A.d-m 1n', 'Admln' and
--- 'Po1ice' read 'admin' and 'poiice', as 'Police' does. 8 reads 'b', 'a'
--- or 'ate' ('Moder8tor'), so a word or name is looked for in each reading.
--- Blocked words and names are folded the same way before they are compared.
local LEET = { ['0'] = 'o', ['1'] = 'i', ['l'] = 'i', ['!'] = 'i', ['|'] = 'i', ['3'] = 'e', ['4'] = 'a',
    ['@'] = 'a', ['5'] = 's', ['$'] = 's', ['7'] = 't' }
local EIGHT = { 'b', 'a', 'ate' }

--- Every reading of a text (one per reading of 8), folded.
---@param text string
---@return string[]
local function foldings(text)
    local base = text:lower():gsub('.', function(c) return LEET[c] or c end)
    if not base:find('8', 1, true) then return { (base:gsub('[^%a]', '')) } end
    local out = {}
    for _, as in ipairs(EIGHT) do
        out[#out + 1] = (base:gsub('8', as):gsub('[^%a]', ''))
    end
    return out
end

--- A text folded once (its first reading), for comparing names.
local function folded(text) return foldings(text)[1] end

--- Whether two texts read the same once folded, in any reading of either.
local function sameFolded(a, b)
    if type(a) ~= 'string' or type(b) ~= 'string' then return false end
    for _, x in ipairs(foldings(a)) do
        if x ~= '' then
            for _, y in ipairs(foldings(b)) do
                if x == y then return true end
            end
        end
    end
    return false
end

--- The character names a codename may not read as, besides its own
--- member's: every member's and applicant's (kept in memory) and every
--- player's in the city now (Identity.online, asked only when a codename is
--- set). A codename that reads as somebody's name would put that name on
--- this member's contracts.
local function namesInUse(org, cid)
    local out = {}
    for other, m in pairs(org.members) do
        if other ~= cid and type(m.name) == 'string' then out[#out + 1] = m.name end
    end
    for _, a in pairs(org.applications or {}) do
        if a.cid ~= cid and type(a.name) == 'string' then out[#out + 1] = a.name end
    end
    local ok, online = pcall(function() return deps.identity.online() end)
    for _, actor in ipairs(ok and type(online) == 'table' and online or {}) do
        if type(actor) == 'table' and actor.cid ~= cid and type(actor.name) == 'string' then
            out[#out + 1] = actor.name
        end
    end
    return out
end

--- A codename as typed, checked: its cleaned form, or nil and why not.
--- Length (CodenameMinLength-CodenameMaxLength), letters, digits, spaces,
--- - and _ only (starting with a letter or digit), none of the blocked
--- words (CodenameBlocked), and, folded, no other member's codename and no
--- character's name (namesInUse).
---@param org table
---@param text any
---@param cid string|nil the member it is for (their own does not clash)
---@return string|nil clean
---@return string|nil err
function Org.checkCodename(org, text, cid)
    if type(text) ~= 'string' then return nil, ERR.INVALID end
    text = Util.toValidUtf8(text):gsub('^%s+', ''):gsub('%s+$', ''):gsub('%s+', ' ')
    local cfg = Config.Organisation
    local lo = math.max(1, math.floor(tonumber(cfg.CodenameMinLength) or 3))
    local hi = math.min(32, math.max(lo, math.floor(tonumber(cfg.CodenameMaxLength) or 20)))
    if #text < lo or #text > hi or not text:match('^[%w][%w _%-]*$') then return nil, ERR.INVALID end
    local readings = foldings(text)
    for _, word in ipairs(type(cfg.CodenameBlocked) == 'table' and cfg.CodenameBlocked or {}) do
        local w = type(word) == 'string' and folded(word) or ''
        if w ~= '' then
            for _, plain in ipairs(readings) do
                if plain:find(w, 1, true) then return nil, ERR.NAME_BLOCKED end
            end
        end
    end
    for other, m in pairs(org.members) do
        if other ~= cid and sameFolded(m.codename, text) then return nil, ERR.NAME_TAKEN end
    end
    -- Never somebody's own name: a codename that reads as another
    -- character would put that character's name on this one's contracts.
    for _, name in ipairs(namesInUse(org, cid)) do
        if sameFolded(name, text) then return nil, ERR.NAME_TAKEN end
    end
    return text
end

--- Set a codename: a member's own (`cid` nil or theirs), or (M7) one for a
--- member below the boss. `name` false clears it.
---@param who table
---@param cid string|nil
---@param name string|false
function Org.setCodename(who, cid, name)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    if Config.Organisation.Codenames ~= true then return fail(ERR.FEATURE_OFF) end
    local own = not who.staff and (cid == nil or cid == who.cid)
    if who.staff and cid == nil then return fail(ERR.NOT_FOUND) end
    if own then
        cid = who.cid
        if not org.members[cid] then return fail(ERR.NOT_MEMBER) end
    else
        local err = Org.authorize(org, who, 'M7')
        if err then return fail(err) end
    end
    local member = type(cid) == 'string' and org.members[cid]
    if not member then return fail(ERR.NOT_FOUND) end
    local meta = org.settings.codenames[cid]
    if own then
        -- One a boss or staff gave stays theirs to change.
        if meta and meta.by ~= 'self' then return fail(ERR.LOCKED) end
        if meta and meta.at and now() - meta.at < Powers.limit(org, 'CodenameCooldownMinutes') * 60 then
            return fail(ERR.COOLDOWN)
        end
    elseif not who.staff then
        local why = Engine.mayActOn(org, who.cid, cid)
        if why then return fail(why == 'self' and ERR.SELF or why == 'locked' and ERR.LOCKED or ERR.RANK) end
        if meta and meta.by == 'staff' then return fail(ERR.LOCKED) end
    end
    local clean
    if name ~= false then
        local why
        clean, why = Org.checkCodename(org, name, cid)
        if not clean then return fail(why) end
        if clean == member.codename then return true, nil, { codename = clean, unchanged = true } end
    end
    local before = member.codename
    member.codename = clean
    org.settings.codenames[cid] = clean and { by = who.staff and 'staff' or (own and 'self' or 'boss'), at = now() }
        or nil
    saveMember(member)
    saveOrgRow()
    record('org_codename', who, { member = cid, own = own or nil, set = clean ~= nil, changed = before ~= nil or nil })
    return true, nil, { codename = clean }
end

--- How a codename reads wherever it stands in for a name, so nobody takes
--- it for a character's own: 'Viper (codename)'.
---@param codename string
---@return string
function Org.codenameLabel(codename)
    return codename .. ' (codename)'
end

--- The split kept for one hitman on one contract, if any (the name shown
--- when they took it).
local function shownSplit(contractId, cid)
    local key = tostring(contractId) .. ':' .. tostring(cid)
    if Splits[key] then return Splits[key] end
    if NoSplit[key] then return nil end
    local ok, row = pcall(deps.storage.readOrgRow, 'splits', key)
    if ok and type(row) == 'table' then
        Splits[key] = row
        return row
    end
    if ok then
        if NoSplitCount >= 5000 then NoSplit, NoSplitCount = {}, 0 end
        NoSplit[key], NoSplitCount = true, NoSplitCount + 1
    end
    return nil
end

--- The name to show for a hitman where their name is shown at all. On a
--- contract (`contractId`): the name shown when they took it, kept with
--- their split (Org.afterAccept), so a codename shown once is never
--- swapped for the real name later (a member who leaves, a codename
--- cleared or changed, codenames turned off); a contract taken with no
--- codename keeps the name. With no contract: their codename now, while
--- codenames are on and they have one, else their name. A codename always
--- reads as one (Org.codenameLabel).
---@param cid string|nil
---@param name string|nil the name the contract keeps
---@param contractId string|nil
---@return string|nil
function Org.shownName(cid, name, contractId)
    if name == nil or type(cid) ~= 'string' or not Feature.on('Organisation') then return name end
    if contractId ~= nil then
        local split = Cur() and shownSplit(contractId, cid)
        if split then
            return type(split.shown_name) == 'string' and split.shown_name ~= '' and split.shown_name or name
        end
        -- No split: not a member when they took it; their name was shown.
        return name
    end
    if not Org.codenamesOn() then return name end
    local member = Cur() and Cur().members[cid]
    return member and type(member.codename) == 'string' and Org.codenameLabel(member.codename) or name
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
    -- An organisation contract taken (Config.Organisation.OrgContracts).
    Extras.afterAccept(org, actor, contractId)
    Extras3.accepted(org, actor, gate)
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
    -- The name shown for them on this contract from now on (Org.shownName):
    -- the codename they carry as they take it. Taken up again, what was
    -- shown the first time stays, so the placer never sees it change.
    local before = Splits[key] or (not NoSplit[key] and select(2, pcall(deps.storage.readOrgRow, 'splits', key)))
    local shown
    if type(before) == 'table' then
        shown = before.shown_name
    else
        local member = org.members[actor.cid]
        shown = Org.codenamesOn() and member and type(member.codename) == 'string'
            and Org.codenameLabel(member.codename) or nil
    end
    local row = { id = key, org_id = org.id, contract_id = contractId, cid = actor.cid,
        payout_pct = terms.orgPercent, stake_pct = terms.stakePercent, buyout_pct = terms.buyoutPercent,
        created_at = now(), shown_name = shown }
    local ok = pcall(deps.storage.writeOrgRow, 'splits', row)
    if ok then
        Splits[key] = row
        if NoSplit[key] then NoSplit[key], NoSplitCount = nil, NoSplitCount - 1 end
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
    if taken > 0 or not Feature.on('Organisation') then return taken end
    if not Cur() then return 0 end
    if (tonumber(line.deliver_arrived) or 0) > 0 then return 0 end
    local amount = math.floor(tonumber(line.amount) or 0)
    if amount <= 0 then return 0 end
    local split = splitOf(line.contract_id, recipientCid)
    if not split then return 0 end
    -- The organisation the member was in as they took it (the split says),
    -- while it is still kept; otherwise nothing is cut.
    local org = Orgs[split.org_id or ''] or (split.org_id == nil and Cur()) or nil
    if not org then return 0 end
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
        contract = line.contract_id, reason = kind, title = L('org.contract_cut') })
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
    if not Feature.on('Organisation') then return nil end
    local org = Cur()
    if not org or type(actor) ~= 'table' then return nil end
    -- Held for the organisation (OrgContracts): only its assigned member.
    local held, heldData = Extras.reservedRefusal(org, actor, contractId, opts)
    if held then return held, heldData end
    local member = org.members[actor.cid]
    local cfg = Config.Organisation
    if not member then
        if cfg.RequireJobToAccept then
            return ERR.MEMBERS_ONLY, { message = MESSAGES[ERR.MEMBERS_ONLY] }
        end
        return nil
    end
    if cfg.RequireJobToAccept and cfg.AcceptNeedsPower and not Engine.holds(org, actor.cid, Powers.TAKE) then
        return ERR.RULE, { message = L('org.your_role_may_not_take_contracts') }
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
    -- Probation's limits (Config.Organisation.Probation).
    local barred, barredData = Extras.probationGate(org, member, actor, contractId, contract, opts, out)
    if barred then return barred, barredData end
    -- The cut, read once: the one the page must have shown (its board card
    -- says it, and the accept echoes it), and the one frozen.
    local terms = Org.termsFor(actor.cid)
    if type(opts) == 'table' and opts.checkDisclosure and shownCut(opts) ~= terms.orgPercent then
        return CH.ERR.TERMS_CHANGED, { orgCut = terms.orgPercent }
    end
    -- Last, once every other rule passed: an accept that waits for a boss
    -- (Config.Organisation.AcceptApproval). Nothing is taken while it does.
    -- The organisation's reputation tier (Config.Organisation.Reputation).
    local tiered, tierData = Extras3.tierGate(org, member, contractId)
    if tiered then return tiered, tierData end
    local waits, waitData = Extras.approvalGate(org, member, actor, contractId, opts, out)
    if waits then return waits, waitData end
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
    -- Kept before anything is awaited: a crash from here to the ledger row
    -- makes the deposit at the next start (Funds.decideInterrupted).
    local charged = Funds.charged(org, ref, amount, account, who.cid)
    local ok, ferr = Funds.credit(org, amount, { ref = ref, kind = 'deposit', actor = who.cid,
        reason = account, title = L('org.member_deposit'), charged = charged })
    if not ok then
        Util.credit(actor.player, account, amount)
        Funds.settled(charged)
        return fail(ferr == 'busy' and ERR.BUSY or ferr == 'bank_down' and ERR.BANK_DOWN or ERR.REFUSED)
    end
    Funds.settled(charged)
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
        title = L('org.organisation_withdrawal'), cap = cap })
    if not ok then return fail(fundsErr(ferr)) end
    if actor then
        local paid = Util.credit(actor.player, 'cash', amount)
        if not paid then
            Funds.credit(org, amount, { ref = ref .. ':back', kind = 'refund', actor = who.cid,
                reason = L('org.withdrawal_not_paid'), title = L('org.withdrawal_returned') })
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
        reason = reason, title = L('org.staff_deposit') })
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
        title = L('org.bonus'), cap = cap })
    if not ok then return fail(fundsErr(ferr)) end
    local paidOk, paid = pcall(function()
        return Framework().AddMoney(cid, 'bank', amount, L('org.crimson_hitman_organisation_bonus'))
    end)
    if not paidOk or not paid then
        Funds.credit(org, amount, { ref = ref .. ':back', kind = 'refund', actor = who.cid,
            reason = L('org.bonus_not_paid'), title = L('org.bonus_returned') })
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
--                              PAYROLL
-- ============================================================================
-- Config.Organisation.Payroll (off as shipped). Every PayrollDays each
-- member is paid their role's salary from the funds, to their bank: the
-- funds first (Funds.debit, one ledger row per member and pay day, by a
-- reference made of both, so a restart part-way pays nobody twice), then
-- their bank, then a marker row saying it was paid ('salary_paid'). Where
-- the bank refuses, the funds are given back (':back'); a give-back that
-- fails is audited and kept, and tried again every tick until it lands. A
-- debit found again with no marker and no give-back (the server stopped
-- between the two) is never paid again on a guess: it is audited and left
-- for staff (review org_payroll_unconfirmed), once. A salary the funds
-- cannot cover is skipped and the member told; the rest are still paid.
-- A suspended member is not paid unless Config.Organisation.PaySuspended;
-- one pay day pays at most Limits.PayrollPerDayMax in all (0: no cap but
-- each role's). A salary a boss sets (P3) is paid from the pay day after
-- the next one, and said so, so a boss cannot set a salary just before a
-- pay day and have it paid out at once; staff's take effect at once.
-- The pay day is kept with the organisation's settings, so a restart
-- neither skips nor repeats one. The maintenance tick asks every tick; it
-- compares one number until the pay day comes (Org.payrollTick).

--- Whether payroll is on now.
---@return boolean
function Org.payrollOn()
    return Feature.on('Organisation') and Config.Organisation.Payroll == true
end

local function payDays()
    local days = math.floor(tonumber(Config.Organisation.PayrollDays) or 7)
    return math.max(1, math.min(31, days))
end

--- The most a role may be paid: SalaryMax, or less where staff set the
--- role's own maximum. Bounds what a boss sets, and what is paid.
---@return integer
function Org.salaryMax(org, grade)
    local cap = Powers.limit(org, 'SalaryMax')
    local own = tonumber(org.settings.payroll.max[tostring(grade)])
    if own then cap = math.min(cap, math.floor(own)) end
    return math.max(0, cap)
end

--- What a role is paid every pay day, within Org.salaryMax as it is now:
--- a salary set before staff lowered either bound is paid only up to it.
---@return integer
function Org.salaryOf(org, grade)
    local pay = math.floor(tonumber(org.settings.payroll.salary[tostring(grade)]) or 0)
    return math.max(0, math.min(pay, Org.salaryMax(org, grade)))
end

--- A salary a boss set that is not paid yet: { amount, from (the first pay
--- day it is paid on), by, at }, or nil.
---@return table|nil
function Org.pendingSalary(org, grade)
    local p = org.settings.payroll.pending[tostring(grade)]
    return type(p) == 'table' and p or nil
end

--- A role's salary (P3): a role below the boss, up to Org.salaryMax, paid
--- from the pay day after the next one. Staff: any role, up to
--- Org.salaryMax, at once (and a boss's waiting change dropped).
function Org.setSalary(who, grade, amount)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    if Config.Organisation.Payroll ~= true then return fail(ERR.FEATURE_OFF) end
    local err = Org.authorize(org, who, 'P3')
    if err then return fail(err) end
    grade = math.floor(tonumber(grade) or -1)
    if not org.roles[grade] then return fail(ERR.NOT_FOUND) end
    amount = tonumber(amount)
    if not amount or amount ~= math.floor(amount) or amount < 0 or amount > 1000000 then return fail(ERR.INVALID) end
    if not who.staff then
        local why = Engine.mayEditRole(org, who.cid, grade)
        if why then return fail(why == 'locked' and ERR.LOCKED or ERR.RANK) end
    end
    local max = Org.salaryMax(org, grade)
    if amount > max then return fail(ERR.BOUNDS, { max = max }) end
    local key = tostring(grade)
    local pay = org.settings.payroll
    local before = tonumber(pay.salary[key]) or 0
    if who.staff then
        pay.salary[key] = amount > 0 and amount or nil
        pay.pending[key] = nil
        saveOrgRow()
        record('org_salary', who, { grade = grade, from = before, to = amount })
        return true, nil, { from = before, to = amount }
    end
    -- A boss's: the pay day after the next one, so nothing they set is
    -- paid before the members and staff have seen it for a whole period.
    local period = payDays() * 86400
    local fromAt = (tonumber(pay.nextAt) or (now() + period)) + period
    if amount == before then
        pay.pending[key] = nil
    else
        pay.pending[key] = { amount = amount, from = fromAt, by = who.cid, at = now() }
    end
    saveOrgRow()
    record('org_salary', who, { grade = grade, from = before, to = amount, fromPayDay = fromAt })
    return true, nil, { from = before, to = amount, fromPayDay = amount ~= before and fromAt or nil }
end

--- Staff only: the most a role may be paid (false clears it: SalaryMax).
function Org.setSalaryMax(who, grade, amount)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    if not who.staff then return fail(ERR.NO_POWER) end
    grade = math.floor(tonumber(grade) or -1)
    if not org.roles[grade] then return fail(ERR.NOT_FOUND) end
    local key = tostring(grade)
    if amount == false then
        org.settings.payroll.max[key] = nil
    else
        amount = tonumber(amount)
        if not amount or amount ~= math.floor(amount) or amount < 0 or amount > 1000000 then return fail(ERR.INVALID) end
        org.settings.payroll.max[key] = amount
    end
    saveOrgRow()
    record('org_salary_max', who, { grade = grade, max = org.settings.payroll.max[key] or false })
    return true
end

local function tell(cid, text)
    if deps.notify and deps.notify.toCitizen and deps.identity.byCitizenId(cid) then
        pcall(deps.notify.toCitizen, cid, (Cur() and Cur().label) or L('org.organisation'), text)
    end
end

--- Hand a salary the funds have already paid out to the member's bank,
--- marked paid; given back to the funds if the bank refuses it. The give
--- is kept before the marker is awaited (Funds.willMark), so a crash in
--- between is marked at the next start rather than left for staff.
local function payMember(org, member, amount, period, ref)
    local paidOk, paid = pcall(function()
        return Framework().AddMoney(member.cid, 'bank', amount, L('org.crimson_hitman_organisation_salary'))
    end)
    if not paidOk or not paid then
        local back, berr = Funds.credit(org, amount, { ref = ref .. ':back', kind = 'refund', actor = member.cid,
            reason = L('org.salary_not_paid'), title = L('org.salary_returned') })
        if not back then
            -- Kept with the settings and tried again every tick (Org.payrollTick).
            org.settings.payroll.refunds[ref] = { cid = member.cid, amount = amount, period = period }
            saveOrgRow()
            deps.audit.financial('org_payroll_refund_failed', member.cid, nil, { org = org.id, amount = amount,
                period = period, ref = ref, why = berr or 'refused' })
        end
        return 'failed', 'bank'
    end
    local mark = { kind = 'salary_paid', actor = member.cid, reason = L('org.paid_to_bank') }
    local kept = Funds.willMark(org, ref .. ':paid', mark)
    if not Funds.mark(org, ref .. ':paid', mark) then
        PaidHere[ref] = true
        deps.audit.financial('org_payroll_unmarked', member.cid, nil, { org = org.id, amount = amount,
            period = period, ref = ref })
    else
        Funds.settled(kept)
    end
    return 'paid'
end

--- A salary's funds row found already written (Funds.debit 'repeat'): what
--- became of it. Paid (its marker, or paid in this process), given back
--- (':back'), or a give-back waiting to be tried again: 'repeat'. Left
--- for staff before: 'repeat'. Otherwise the server stopped between the
--- debit and the marker. Where every give is kept before its marker
--- (Funds.marksKept, mysql), a debit with neither never reached the member
--- (step 8a): paid now. Elsewhere whether the bank took it is not known:
--- never paid again on a guess, audited and left for staff once
--- ('unconfirmed').
local function settleRepeat(org, member, amount, period, ref)
    if PaidHere[ref] or Funds.byRef(ref .. ':paid') or Funds.byRef(ref .. ':back')
        or org.settings.payroll.refunds[ref] or Funds.byRef(ref .. ':review')
        or Funds.markWaiting(ref .. ':paid') then
        return 'repeat'
    end
    local row = Funds.byRef(ref)
    if row and Funds.marksKept() then
        return payMember(org, member, math.abs(math.floor(tonumber(row.amount) or 0)), period, ref)
    end
    local debited = row and math.abs(math.floor(tonumber(row.amount) or 0)) or amount
    deps.audit.financial('org_payroll_unconfirmed', member.cid, nil, { org = org.id, amount = debited,
        period = period, ref = ref })
    if deps.review and deps.review.open then
        pcall(deps.review.open, { kind = 'org_payroll_unconfirmed', cids = { member = member.cid },
            amount = debited, account = 'bank', known = { org = org.id, ref = ref, period = period } })
    end
    Funds.mark(org, ref .. ':review', { kind = 'salary_review', actor = member.cid,
        reason = L('org.left_for_staff_not_known_whether') })
    return 'unconfirmed', nil, debited
end

--- Pay one member for one pay day. Answers 'paid', 'repeat' (dealt with
--- before: a restart part-way), 'unconfirmed' (left for staff: see
--- settleRepeat), 'skipped' (the funds could not cover it) or 'failed'
--- (the bank refused; the funds were given back, or will be).
local function payOne(org, member, amount, period)
    local ref = ('pay:%d:%s'):format(period, member.cid)
    if Paying[ref] then return 'repeat' end
    Paying[ref] = true
    local ok, ferr, repeated = Funds.debit(org, amount, { ref = ref, kind = 'salary', actor = member.cid,
        reason = 'grade ' .. tostring(member.grade), title = L('org.salary') })
    if repeated then
        local how, why, debited = settleRepeat(org, member, amount, period, ref)
        Paying[ref] = nil
        return how, why, debited
    end
    if not ok then
        Paying[ref] = nil
        return ferr == 'short' and 'skipped' or 'failed', ferr
    end
    local how, why = payMember(org, member, amount, period, ref)
    Paying[ref] = nil
    return how, why
end

--- Give back the salaries a bank refused whose give-back failed, where the
--- funds can move: each once (its ':back' reference), audited.
local function retryRefunds(org)
    local pay = org.settings.payroll
    if not next(pay.refunds) or not Funds.ready() then return end
    local changed = false
    for ref, r in pairs(pay.refunds) do
        local amount = type(r) == 'table' and Funds.amount(r.amount)
        if not amount then
            pay.refunds[ref], changed = nil, true
        else
            local ok, _, repeated = Funds.credit(org, amount, { ref = ref .. ':back', kind = 'refund',
                actor = r.cid, reason = L('org.salary_not_paid'), title = L('org.salary_returned') })
            if ok or repeated then
                pay.refunds[ref], changed = nil, true
                deps.audit.financial('org_payroll_refunded', r.cid, nil, { org = org.id, amount = amount,
                    period = r.period, ref = ref })
            end
        end
    end
    if changed then saveOrgRow() end
end

--- A boss's salaries due by this pay day, made the salary.
local function applyPending(org, due)
    local pay = org.settings.payroll
    for key, p in pairs(pay.pending) do
        if type(p) ~= 'table' or not org.roles[tonumber(key)] then
            pay.pending[key] = nil
        elseif (tonumber(p.from) or 0) <= due then
            local amount = math.floor(tonumber(p.amount) or 0)
            pay.salary[key] = amount > 0 and amount or nil
            pay.pending[key] = nil
            deps.audit.financial('org_salary_applied', p.by, nil, { org = org.id, grade = tonumber(key),
                to = amount, period = due })
        end
    end
end

--- Pay day, where it is due: every member paid their role's salary from the
--- funds, a short one skipped and told; the next pay day kept. Cheap until
--- then: one comparison (and a give-back to try again, where one waits).
--- Restart-safe both ways (see the section above).
---@param at integer|nil os.time() (the tests)
---@return table|nil what happened { paid, skipped, failed, unconfirmed, total } when it ran
function Org.payrollTick(at)
    if not Org.payrollOn() then return nil end
    local org = Cur()
    if not org then return nil end
    local ts = at or now()
    local pay = org.settings.payroll
    if next(pay.refunds) then retryRefunds(org) end
    local due = tonumber(pay.nextAt)
    if not due then
        -- The first pay day: a whole period from when it was turned on.
        pay.nextAt = ts + payDays() * 86400
        saveOrgRow()
        return nil
    end
    if ts < due then return nil end
    if not Funds.ready() then return nil end
    applyPending(org, due)
    local list = {}
    for _, m in pairs(org.members) do list[#list + 1] = m end
    table.sort(list, function(a, b)
        if a.grade ~= b.grade then return a.grade > b.grade end
        return a.cid < b.cid
    end)
    local out = { paid = 0, skipped = 0, failed = 0, unconfirmed = 0, total = 0, period = due }
    local cap = Powers.limit(org, 'PayrollPerDayMax')
    local spent = 0
    local paySuspended = Config.Organisation.PaySuspended == true
    local function skip(m, amount, why, text)
        out.skipped = out.skipped + 1
        deps.audit.financial('org_payroll_skipped', m.cid, nil, { org = org.id, amount = amount,
            period = due, why = why })
        tell(m.cid, text)
    end
    for _, m in ipairs(list) do
        local amount = Org.salaryOf(org, m.grade)
        if amount > 0 then
            if not paySuspended and m.suspended_until and m.suspended_until > ts then
                skip(m, amount, 'suspended', (L('org.pay_day_your_salary_of_was'))
                    :format(amount))
            elseif cap > 0 and spent + amount > cap then
                skip(m, amount, 'cap', (L('org.pay_day_your_salary_of_was_2')):format(amount))
            else
                local result, why, debited = payOne(org, m, amount, due)
                if result == 'paid' then
                    spent = spent + amount
                    out.paid, out.total = out.paid + 1, out.total + amount
                    tell(m.cid, (L('org.pay_day_your_salary_of_was_3')):format(amount))
                elseif result == 'repeat' then
                    -- Paid (or given back) before a restart: counts toward the cap.
                    spent = spent + amount
                elseif result == 'unconfirmed' then
                    spent = spent + (debited or amount)
                    out.unconfirmed = out.unconfirmed + 1
                elseif result == 'skipped' then
                    skip(m, amount, 'short', (L('org.pay_day_your_salary_of_was_4')):format(amount))
                elseif result == 'failed' then
                    out.failed = out.failed + 1
                    deps.audit.financial('org_payroll_skipped', m.cid, nil, { org = org.id, amount = amount,
                        period = due, why = why or 'refused' })
                end
            end
        end
    end
    -- The next pay day: one period on, or (a server down for longer than a
    -- period) one period from now. Missed pay days are not paid twice over.
    local nextAt = due + payDays() * 86400
    if nextAt <= ts then nextAt = ts + payDays() * 86400 end
    pay.nextAt = nextAt
    pay.lastAt = due
    saveOrgRow()
    deps.audit.financial('org_payroll_run', nil, nil, { org = org.id, period = due, paid = out.paid,
        skipped = out.skipped, failed = out.failed, unconfirmed = out.unconfirmed, total = out.total,
        nextAt = nextAt })
    if out.skipped > 0 or out.unconfirmed > 0 then
        -- Those who can see the funds hear that some were not paid.
        for cid in pairs(org.members) do
            if Engine.holds(org, cid, 'C8') then
                tell(cid, (L('org.pay_day_salary_ies_could_not')):format(out.skipped + out.unconfirmed))
            end
        end
    end
    return out
end

-- ============================================================================
--                              LOCATIONS
-- ============================================================================

--- The kinds of place, who may set each, and how many there may be. Each
--- is a kind of the one registry of map spots (server/places.lua), which
--- keeps them (owner: the organisation's id), reads where the actor stands
--- and checks what is set; the rules below stay the organisation's.
Org.SPOTS = {
    office = { power = 'L1', max = function() return 1 end, everyone = false,
        label = L('org.boss_office'), one = L('org.boss_office_2'), icon = 'building' },
    signup = { power = 'L2', max = function(org) return Powers.limit(org, 'MaxSignupSpots') end, everyone = true,
        label = L('org.sign_up_spots'), one = L('org.sign_up_spot'), icon = 'clipboard' },
    meeting = { power = 'L3', max = function(org) return Powers.limit(org, 'MaxMeetingSpots') end, everyone = false,
        label = L('org.meeting_and_handover_spots'), one = L('org.meeting_spot'), icon = 'handshake' },
    npc = { power = nil, max = function() return 20 end, everyone = false,
        label = L('org.npc_spots'), one = L('org.npc_spot'), icon = 'user-tie' },
    place = { power = nil, max = function() return 50 end, everyone = false,
        label = L('org.other_organisation_places'), one = 'place', icon = 'location-dot' },
    -- Organisation extras 3 (server/org/extras3.lua): staff only. A
    -- territory is never sent to any game (hidden).
    deaddrop = { power = nil, max = function() return 3 end, everyone = false,
        label = L('org.dead_drops'), one = L('org.dead_drop'), icon = 'box-archive' },
    garage = { power = nil, max = function() return 1 end, everyone = false,
        label = L('org.garage'), one = L('org.garage_spot'), icon = 'warehouse' },
    territory = { power = nil, max = function() return 10 end, everyone = false, hidden = true,
        label = L('org.territory'), one = 'territory', icon = 'map', radius = { min = 10, max = 1000, default = 150 } },
}
Org.SPOT_ORDER = { 'office', 'signup', 'meeting', 'npc', 'place', 'deaddrop', 'garage', 'territory' }

--- The server's own position for a player: coords and heading.
---@return table|nil { x, y, z, h }
function Org.positionOf(src)
    return Places.positionOf(src)
end

--- Inside one of the staff safe zones (Config.Intel.SafeZones.Zones,
--- 'x, y, radius, name'), where no organisation spot is placed by a boss.
local function inSafeZone(x, y)
    local zones = Feature.block('Intel.SafeZones').Zones
    for _, text in ipairs(type(zones) == 'table' and zones or {}) do
        local zx, zy, r = tostring(text):match('^%s*(%-?[%d.]+)%s*,%s*(%-?[%d.]+)%s*,%s*([%d.]+)')
        zx, zy, r = tonumber(zx), tonumber(zy), tonumber(r)
        if zx and zy and r and (x - zx) ^ 2 + (y - zy) ^ 2 <= r * r then return true end
    end
    return false
end

--- The registry's refusals in the organisation's words.
local FROM_PLACES = {
    invalid_input = ERR.INVALID, not_found = ERR.NOT_FOUND, limit_reached = ERR.LIMIT,
    feature_off = ERR.OFF, store_unreadable = ERR.REFUSED,
}

--- Register the five kinds with the registry. Staff: any kind, from their
--- own position (`here`) or typed coordinates, up to 20 of a kind (50 other
--- places, one office). A boss: the office (L1, near staff's point), a
--- sign-up spot (L2) or a meeting spot (L3), from where they stand only,
--- once per LocationCooldownMinutes, within the limits, never in a staff
--- safe zone. Audited org_location_set / org_location_removed.
registerSpots = function()
    for _, kind in ipairs(Org.SPOT_ORDER) do
        local def = Org.SPOTS[kind]
        local says = {}
        for code, err in pairs(FROM_PLACES) do says[code] = MESSAGES[err] end
        says.no_position = L('org.the_server_cannot_see_where_you')
        for code, text in pairs(MESSAGES) do says[code] = text end
        Places.kind(kind, {
            group = 'org', label = def.label, one = def.one, icon = def.icon,
            fields = { label = true, radius = true, blip = true, enabled = true }, labelMax = 64,
            defaultLabel = kind, single = kind == 'office' or kind == 'garage',
            radius = def.radius or { min = 0.5, max = 50, default = 2.0 },
            owner = function() return Org.current() and Cur().id or nil end,
            ready = function()
                if Org.current() then return nil end
                if Feature.on('Organisation') then
                    return ERR.OFF, { message = L('org.the_organisation_is_on_and_not') }
                end
                return ERR.OFF, { message = L('org.its_places_boss_office_sign_up') }
            end,
            allow = function(who)
                if who.staff then return nil end
                if not def.power then return ERR.NO_POWER end
                return Org.authorize(Cur(), who, def.power)
            end,
            max = function(who)
                if who.staff then return math.max(def.max(Cur()), kind == 'office' and 1 or 20) end
                return def.max(Cur())
            end,
            rules = function(who, at, existing)
                if who.staff then return nil end
                if inSafeZone(at.x, at.y) then
                    return ERR.RULE, { message = L('org.not_here_this_is_a_safe') }
                end
                local moved = Cur().settings.moves[kind .. ':' .. who.cid]
                if moved and now() - moved < Powers.limit(Cur(), 'LocationCooldownMinutes') * 60 then
                    return ERR.COOLDOWN
                end
                if kind == 'office' then
                    local anchor = existing and existing.anchor
                    if type(anchor) ~= 'table' then return ERR.LOCKED end
                    local reach = Powers.limit(Cur(), 'OfficeMoveMetres')
                    if (at.x - anchor.x) ^ 2 + (at.y - anchor.y) ^ 2 > reach * reach then return ERR.BOUNDS end
                end
            end,
            anchor = function(who, at)
                if who.staff and kind == 'office' then return { x = at.x, y = at.y } end
            end,
            after = function(who, row, existing)
                if not who.staff then
                    Cur().settings.moves[kind .. ':' .. who.cid] = now()
                    saveOrgRow()
                end
                record('org_location_set', who, { kind = kind, id = row.id, x = row.x, y = row.y, z = row.z,
                    moved = existing ~= nil or nil })
                Org.pushSpotsAll()
            end,
            mayRemove = function(who)
                if who.staff then return nil end
                if not def.power or kind == 'office' then return ERR.NO_POWER end
                return Org.authorize(Cur(), who, def.power)
            end,
            removed = function(who, rows)
                for _, row in ipairs(rows) do record('org_location_removed', who, { kind = kind, id = row.id }) end
                Org.pushSpotsAll()
            end,
            says = says,
            view = function() return { switch = 'Organisation.Enabled' } end,
        })
    end
end

local function fromPlaces(ok, err, row, extra)
    if ok then return true, nil, row end
    return fail(FROM_PLACES[err] or err, extra)
end

--- Place or move a spot (the boss menu's Place here; the panel's placeSet
--- reaches the registry itself). See registerSpots for who may set what.
---@param spec table { kind, id?, label?, radius?, blip?, enabled?, here?, x?, y?, z?, heading? }
function Org.placeSpot(who, spec)
    if not Org.current() then return fail(ERR.OFF) end
    if type(spec) ~= 'table' or type(spec.kind) ~= 'string' or not Org.SPOTS[spec.kind] then return fail(ERR.INVALID) end
    local ok, err, row, extra = Places.set(who, spec.kind, spec)
    if not ok then
        if err == 'no_position' then
            return fail(ERR.RULE, { message = L('org.the_server_cannot_see_where_you') })
        end
        return fromPlaces(false, err, nil, extra)
    end
    return true, nil, { id = row.id, x = row.x, y = row.y, z = row.z, h = row.h }
end

--- Remove a spot: staff any; a boss a sign-up (L2) or meeting (L3) spot.
function Org.removeSpot(who, id)
    if not Org.current() then return fail(ERR.OFF) end
    if type(id) ~= 'string' then return fail(ERR.NOT_FOUND) end
    local ok, err, _, extra = Places.remove(who, id:sub(1, 48), Org.SPOTS)
    if not ok then return fromPlaces(false, err, nil, extra) end
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
        if l.enabled ~= false and def and not def.hidden and (def.everyone or member) then
            out[#out + 1] = { id = l.id, kind = l.kind, label = l.label, x = l.x, y = l.y, z = l.z,
                h = l.h or 0, radius = l.radius or 2.0, blip = l.blip == true or nil }
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
    -- Only a spot this player is sent (Org.spotsFor): a hidden one (a
    -- territory) answering from inside it would say where it is.
    local member = org.members[actor.cid]
    local def = Org.SPOTS[loc.kind]
    if not def or def.hidden or loc.enabled == false or not (def.everyone or member) then return end
    local at = Org.positionOf(src)
    if not at or not Geo.near(at, loc, (loc.radius or 2.0) + 2.0) then return end
    -- The dead drop, the garage and the handler (server/org/extras3.lua).
    if Extras3.useSpot(org, actor, loc) then return end
    local text
    if loc.kind == 'signup' then
        text = member and L('org.you_are_already_a_member') or L('org.apply_in_the_apps_organisation_tab')
    elseif loc.kind == 'office' and member then
        text = L('org.the_boss_office_powers_that_need')
    elseif member then
        text = loc.label
    end
    if text and deps.notify and deps.notify.toCitizen then
        pcall(deps.notify.toCitizen, actor.cid, org.label or L('org.organisation'), text)
    end
end

--- Whether a player stands at a sign-up spot.
local function atSignup(org, src)
    local at = Org.positionOf(src)
    if not at then return false end
    for _, l in pairs(org.locations) do
        if l.kind == 'signup' and l.enabled ~= false then
            if Geo.near(at, l, (l.radius or 2.0) + 2.0) then return true end
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
            if deps.identity.byCitizenId(cid) then pcall(deps.notify.toCitizen, cid, org.label or L('org.organisation'), text) end
        end
    end
    return true
end

--- A player asks to join (at a sign-up spot, where Config says so). One
--- open application each.
function Org.apply(actor, text, answers)
    local org = Org.current()
    if not org then return fail(ERR.OFF) end
    if org.members[actor.cid] then return fail(ERR.ALREADY) end
    if memberElsewhere(actor.cid, org) then
        return fail(ERR.OTHER_ORG, { message = L('org.you_are_a_member_of_another') })
    end
    for _, a in pairs(org.applications) do if a.cid == actor.cid then return fail(ERR.ALREADY) end end
    if text ~= nil and type(text) ~= 'string' then return fail(ERR.INVALID) end
    text = text and Util.toValidUtf8(text):gsub('%c', ' '):sub(1, 255) or nil
    if text and text:find('[<>]') then return fail(ERR.INVALID) end
    if Config.Organisation.ApplyAtSignupOnly ~= false and not atSignup(org, actor.source) then
        return fail(ERR.RULE, { message = L('org.applications_are_taken_only_at_a') })
    end
    -- The form's answers, the cooldown and the hourly cap
    -- (Config.Organisation.Recruitment): one comparison while it is off.
    local body = text
    if Extras2.on('Recruitment') then
        local berr, bdata
        body, berr, bdata = Extras2.applyBody(org, actor, text, answers)
        if berr then return fail(berr, bdata) end
    end
    local row = { id = ('app:%s:%d:%d'):format(org.id, now(), math.random(1000, 9999)):sub(1, 48), org_id = org.id,
        cid = actor.cid, name = actor.name, body = body, state = 'open', created_at = now() }
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
        local row = { id = a.id, name = a.name, body = a.body, at = a.created_at }
        -- The form's answers and the interview note (Recruitment).
        Extras2.applicationView(org, a, row)
        out[#out + 1] = row
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
        if not member and code == 'other_org' then return fail(ERR.OTHER_ORG) end
        if not member then return fail(ERR.REFUSED, { qbx = code }) end
    end
    row.state, row.decided_by, row.decided_at = accept and 'accepted' or 'rejected', who.cid, now()
    deps.storage.writeOrgRow('applications', row)
    org.applications[row.id] = nil
    record('org_application', who, { member = row.cid, accepted = accept })
    -- The interview note dropped, a declined applicant's cooldown begun.
    Extras2.decided(org, row, accept)
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
        ref = Org.refFor(viewer, m.cid),
        name = (Org.codenamesOn() and m.codename) or m.name, grade = m.grade,
        codename = Org.codenamesOn() and m.codename or nil,
        role = role and role.label or nil, online = online, lastSeen = m.last_seen,
        joined = m.joined_at, suspendedUntil = m.suspended_until, locked = m.locked or nil,
        boss = role and role.is_boss or nil,
    }
    Extras.memberView(org, m, out)
    Extras2.memberView(org, m, out, full)
    if full then
        out.grants, out.denies = {}, {}
        for code, entry in pairs(m.grants) do
            out.grants[code] = { by = entry.by == 'staff' and 'staff' or 'boss',
                inactive = Engine.inactiveWhy(org, m.cid, entry, code) }
        end
        for code, entry in pairs(m.denies) do out.denies[code] = entry.by == 'staff' and 'staff' or 'boss' end
        out.limits = m.limits
        out.held = Engine.held(org, m.cid)
        out.realName = m.name
    end
    return out
end
Org.memberView = memberView

--- Every power's name and area, by code, and Take contracts.
---@return table [code] = { label, area }
function Org.powerNames()
    local out = { [Powers.TAKE] = { label = L('org.take_contracts'), area = 'contracts' } }
    for _, p in ipairs(Powers.LIST) do out[p.code] = { label = p.label, area = p.area, feature = p.feature } end
    return out
end

--- Whether the organisation has a boss office set (and on).
---@return boolean
function Org.hasOffice(org)
    for _, l in pairs(org.locations) do
        if l.kind == 'office' and l.enabled ~= false then return true end
    end
    return false
end

--- Whether a player's app shows the Organisation tab, and as what: a
--- 'member', an 'applicant' (an open application), an 'invitee' (a boss's
--- invite waiting), or 'signup' (standing at a sign-up spot, where they
--- may apply). nil for anybody else, and while it is off. Read with every
--- board reply, so it costs a table lookup or two; the sign-up spots are
--- looked at only for a non-member and only where one is set.
---@param cid string
---@param src integer|nil
---@return string|nil
function Org.tabFor(cid, src)
    local org = Org.current()
    if not org or type(cid) ~= 'string' then return nil end
    if org.members[cid] then return 'member' end
    for _, a in pairs(org.applications) do if a.cid == cid then return 'applicant' end end
    if inviteOf(cid) then return 'invitee' end
    if src and atSignup(org, src) then return 'signup' end
    return nil
end

--- What a player's own Organisation tab shows: their place, what they hold,
--- the notice and the cut they would accept at. Off: { enabled = false }.
function Org.mine(actor)
    local org = Org.current()
    if not org then return { enabled = false } end
    local member = org.members[actor.cid]
    if not member then
        local open = false
        for _, a in pairs(org.applications) do if a.cid == actor.cid then open = true end end
        local outside = { enabled = true, member = false, label = org.label, applied = open or nil,
            -- Several organisations: which this is, and the others to pick from.
            id = #Order > 1 and org.id or nil, choices = Org.choices(),
            invite = Org.inviteFor(actor.cid),
            -- Where they may apply from: anywhere, or only at a sign-up spot
            -- (and whether they stand at one now, by the server's own look).
            signupOnly = Config.Organisation.ApplyAtSignupOnly ~= false or nil,
            atSignup = (Config.Organisation.ApplyAtSignupOnly ~= false and atSignup(org, actor.source)) or nil }
        -- The application form (Config.Organisation.Recruitment), while on.
        Extras2.outside(org, actor.cid, outside)
        return outside
    end
    local role = org.roles[member.grade]
    local held = Engine.held(org, actor.cid)
    local office, bounds = {}, {}
    local out
    for code in pairs(held) do
        if Engine.needsOffice(org, code) then office[code] = true end
        -- The staff bounds of the powers they hold, for the boss menu to
        -- say before it is asked (the server checks them again).
        local spec = Powers.BY_CODE[code]
        for _, key in ipairs(spec and spec.limits or {}) do bounds[key] = Powers.limit(org, key) end
    end
    out = {
        enabled = true, member = true, label = org.label, grade = member.grade, role = role and role.label,
        powers = held, officeOnly = office, inOffice = Org.inOffice(org, actor.source), bounds = bounds,
        -- What each power is called, for the powers editor of a boss who
        -- may pass some on (R4, D2) or set the office rule (S3): the ones
        -- they do not hold are shown
        -- greyed, as staff not having given them.
        powerNames = (held.R4 or held.D2 or held.S3) and Org.powerNames() or nil,
        notice = org.settings.notice and org.settings.notice.text or nil,
        terms = Org.termsFor(actor.cid), suspendedUntil = member.suspended_until,
        limits = member.limits, layout = org.settings.layout,
        hasOffice = Org.hasOffice(org) or nil,
        -- Codenames and payroll, each only while switched on.
        codenames = Org.codenamesOn() or nil,
        codename = Org.codenamesOn() and member.codename or nil,
        codenameGiven = Org.codenamesOn() and org.settings.codenames[actor.cid] ~= nil
            and org.settings.codenames[actor.cid].by ~= 'self' or nil,
        payroll = Org.payrollOn() and { salary = Org.salaryOf(org, member.grade),
            nextIn = org.settings.payroll.nextAt and math.max(0, org.settings.payroll.nextAt - now()) or nil } or nil,
    }
    -- Duty, probation, assigned contracts, approvals and the channel, each
    -- only while its switch is on (server/org/extras.lua).
    Extras.mine(org, member, out)
    -- The record and leaderboard, discipline, the armory and recruitment,
    -- each only while its switch is on (server/org/extras2.lua).
    Extras2.mine(org, member, out)
    -- Reputation, dead drops, the garage, internal contracts, the activity
    -- log and the handler, each only while on (server/org/extras3.lua).
    Extras3.mine(org, member, out)
    return out
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
        for _, code in ipairs({ 'M1', 'R1', 'R2', 'R3', 'R4', 'P1', 'P3', 'C2', 'K1', 'K3' }) do
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
            cut = org.settings.cuts.byRole[tostring(grade)], access = org.settings.access[tostring(grade)],
            salary = Org.payrollOn() and Org.salaryOf(org, grade) or nil,
            salaryMax = Org.payrollOn() and Org.salaryMax(org, grade) or nil,
            -- A boss's change waiting for its first pay day.
            salaryNext = Org.payrollOn() and Org.pendingSalary(org, grade) and Org.pendingSalary(org, grade).amount
                or nil,
            salaryNextAt = Org.payrollOn() and Org.pendingSalary(org, grade) and Org.pendingSalary(org, grade).from
                or nil }
    end
    table.sort(out, function(a, b) return a.grade > b.grade end)
    return true, nil, { rows = out }
end

--- Everything, for staff (orgGet).
---@param canIdentify boolean|nil the viewer holds IdentityAce
function Org.staffView(viewer, canIdentify)
    if not Feature.on('Organisation') then
        return { enabled = false, job = orgId() }
    end
    local org = Cur()
    if not org then return { enabled = true, loaded = false, job = orgId() } end
    local _, _, members = Org.members({ staff = true, cid = viewer })
    local _, _, roles = Org.roles({ staff = true, cid = viewer })
    local ceiling = { role = {}, member = {} }
    for grade, cells in pairs(org.ceiling.role) do ceiling.role[tostring(grade)] = Util.copy(cells) end
    for cid, cells in pairs(org.ceiling.member) do ceiling.member[Org.refFor(viewer, cid)] = Util.copy(cells) end
    local limits = {}
    for key in pairs(Powers.LIMIT_KEYS) do limits[key] = Powers.limit(org, key) end
    local officeStaff = type(org.settings.officeStaff) == 'table' and org.settings.officeStaff or Powers.officeDefaults()
    local _, _, apps = Org.applications({ staff = true })
    local view = {
        enabled = true, loaded = true, job = org.job, label = org.label, type = org.jobType,
        requireJob = Config.Organisation.RequireJobToAccept == true,
        roles = roles and roles.rows or {}, members = members and members.rows or {}, ceiling = ceiling,
        cuts = Util.copy(org.settings.cuts), limits = limits, officeStaff = officeStaff,
        officeBoss = org.settings.officeBoss, notice = org.settings.notice, access = org.settings.access,
        layout = org.settings.layout,
        balance = Funds.balance(org), bank = Funds.usesBank(), fundsBackend = Funds.backend(),
        fundsReady = Funds.ready(), applications = apps and apps.rows or {},
        powers = Powers.LIST, warnings = Jobs.checkConvars(),
        codenames = Org.codenamesOn() or nil,
        payroll = Org.payrollOn() and { nextAt = org.settings.payroll.nextAt, lastAt = org.settings.payroll.lastAt,
            salary = Util.copy(org.settings.payroll.salary), max = Util.copy(org.settings.payroll.max),
            pending = Util.copy(org.settings.payroll.pending), refunds = Util.copy(org.settings.payroll.refunds),
            paySuspended = Config.Organisation.PaySuspended == true,
            perDayMax = Powers.limit(org, 'PayrollPerDayMax') } or nil,
    }
    -- Several organisations: which this is, and every one staff may pick.
    view.id = org.id
    if Org.severalOn() then
        view.several = true
        view.maxOrgs = Org.maxOrgs()
        view.orgs = {}
        for i, o in ipairs(Org.all()) do
            local n = 0
            for _ in pairs(o.members) do n = n + 1 end
            view.orgs[#view.orgs + 1] = { id = o.id, label = o.label, job = o.job, members = n,
                first = i == 1 or nil }
        end
    end
    -- Organisation extras (server/org/extras.lua), each only while on.
    Extras.staffView(org, viewer, view)
    Extras2.staffView(org, viewer, view)
    Extras3.staffView(org, viewer, view, canIdentify == true)
    return view
end

Extras.attach(Org, {
    fail = fail, record = record, save = function() saveOrgRow() end, deps = function() return deps end,
})

--- Move a member one role, as discipline does (StrikeDemoteAt): told to
--- qbx_core, saved, on the record as the strikes' doing.
---@return boolean
local function setGrade(org, cid, grade)
    local member = org.members[cid]
    if not member or not org.roles[grade] then return false end
    local done = Jobs.setMember(org, cid, grade, false)
    if not done then return false end
    local from = member.grade
    member.grade = grade
    saveMember(member)
    deps.audit.action('org_member_role', cid, nil, { org = org.id, member = cid, from = from, to = grade,
        by = 'discipline' })
    return true
end

Extras2.attach(Org, {
    fail = fail, record = record, save = function() saveOrgRow() end, deps = function() return deps end,
    saveMember = saveMember, setGrade = setGrade,
})

Extras3.attach(Org, {
    fail = fail, record = record, save = function() saveOrgRow() end, deps = function() return deps end,
})

-- ============================================================================
--                              SEVERAL ORGANISATIONS
-- ============================================================================

--- The start-up check of these settings (Feature.check).
Org.CHECKS = {
    SeveralOrganisations = { kind = 'switch' },
    MaxOrganisations = { kind = 'number', integer = true, min = 1, max = 10 },
}

--- The most organisations staff may keep (Config.Organisation.MaxOrganisations).
---@return integer
function Org.maxOrgs()
    return math.max(1, math.min(10, math.floor(tonumber(Config.Organisation.MaxOrganisations) or 3)))
end

--- Add an organisation (staff only, SeveralOrganisations on): its own qbx_core
--- job (`job`, lower case, never another's), label, roles (Config.Organisation.
--- Roles), funds account, places, Boss permissions and settings, all kept by
--- its id (the job name). A job name used before brings that one back as it
--- was left. Audited org_added.
---@param who table staff
---@param spec table { job, label }
function Org.create(who, spec)
    if not Feature.on('Organisation') then return fail(ERR.OFF) end
    if type(who) ~= 'table' or not who.staff then return fail(ERR.NO_POWER) end
    if not Org.severalOn() then return fail(ERR.FEATURE_OFF) end
    local first = Order[1] and Orgs[Order[1]]
    if not first then return fail(ERR.OFF) end
    if type(spec) ~= 'table' then return fail(ERR.INVALID) end
    local job = type(spec.job) == 'string' and spec.job:lower() or nil
    if not job or #job < 2 or #job > 32 or not job:match('^[a-z][a-z0-9_]+$') then
        return fail(ERR.INVALID, { message = L('org.a_job_name_2_32_lower') })
    end
    local label = cleanName(spec.label, 64)
    if not label then return fail(ERR.INVALID, { message = L('org.a_label_of_1_64_characters') }) end
    if #Order >= Org.maxOrgs() then
        return fail(ERR.LIMIT, { message = (L('org.at_the_most_organisations_staff_set')
            .. 'MaxOrganisations).'):format(Org.maxOrgs()) })
    end
    for _, o in pairs(Orgs) do
        if o.id == job or o.job == job then
            return fail(ERR.ALREADY, { message = L('org.another_organisation_already_uses_that_job') })
        end
    end
    local ok, org = pcall(load, job, { job = job, label = label, jobType = Config.Organisation.JobType })
    if not ok or not org then
        return fail(ERR.REFUSED, { message = L('org.the_store_would_not_take_it') })
    end
    if org.job ~= job then
        return fail(ERR.ALREADY, { message = L('org.that_id_is_kept_for_another') })
    end
    Orgs[job] = org
    Order[#Order + 1] = job
    local listed = false
    for _, id in ipairs(first.settings.others) do if id == job then listed = true end end
    if not listed then first.settings.others[#first.settings.others + 1] = job end
    saveOrgRow(first)
    bring(org)
    Org.within(org, record, 'org_added', who, { job = job, label = org.label })
    Extras.rebuild()
    return true, nil, { id = job, label = org.label }
end

--- Take an organisation off the list (staff only): never the first, and only
--- with no member, nothing in its funds and no contract held for it. Its rows
--- stay (the record keeps them); its qbx_core job stays registered until the
--- next start. Adding its job name again brings it back.
function Org.removeOrg(who, id)
    if not Feature.on('Organisation') then return fail(ERR.OFF) end
    if type(who) ~= 'table' or not who.staff then return fail(ERR.NO_POWER) end
    if not Org.severalOn() then return fail(ERR.FEATURE_OFF) end
    local org = Org.byId(id)
    if not org then return fail(ERR.NOT_FOUND) end
    if org.id == Order[1] then return fail(ERR.RULE, { message = L('org.the_first_organisation_config_lua_stays') }) end
    if next(org.members) then return fail(ERR.RULE, { message = L('org.it_still_has_members_fire_them') }) end
    if Funds.balance(org) ~= 0 then return fail(ERR.RULE, { message = L('org.its_funds_are_not_empty_withdraw') }) end
    if next(org.settings.orgContracts) then
        return fail(ERR.RULE, { message = L('org.a_contract_is_still_held_for') })
    end
    local first = Orgs[Order[1]]
    for i = #first.settings.others, 1, -1 do
        if first.settings.others[i] == org.id then table.remove(first.settings.others, i) end
    end
    saveOrgRow(first)
    for i = #Order, 1, -1 do if Order[i] == org.id then table.remove(Order, i) end end
    Orgs[org.id] = nil
    Org.within(org, record, 'org_removed', who, { job = org.job })
    Extras.rebuild()
    Org.pushSpotsAll()
    return true
end

--- Whose a request is, when its sender is no member (several organisations):
--- the one the payload names (`wanted`), or the one whose invite waits for
--- them, whose application is open, or at whose sign-up spot they stand.
--- nil: the first. The second answer is true when `wanted` names none.
---@return table|nil org
---@return boolean|nil unknown
function Org.contextFor(actor, wanted)
    if type(actor) ~= 'table' then return nil end
    local mine = Org.orgOf(actor.cid)
    if mine then return mine end
    if #Order < 2 then return nil end
    if wanted ~= nil then
        local org = Org.byId(wanted)
        if not org then return nil, true end
        return org
    end
    local invite = inviteOf(actor.cid)
    if invite and Orgs[invite.org or ''] then return Orgs[invite.org] end
    for _, id in ipairs(Order) do
        for _, a in pairs(Orgs[id].applications) do if a.cid == actor.cid then return Orgs[id] end end
    end
    if actor.source then
        for _, id in ipairs(Order) do
            if Org.within(Orgs[id], atSignup, Orgs[id], actor.source) then return Orgs[id] end
        end
    end
    return nil
end

--- The organisations a player outside them may apply to, for the tab.
---@return table[]|nil
function Org.choices()
    if #Order < 2 then return nil end
    local out = {}
    for _, id in ipairs(Order) do out[#out + 1] = { id = id, label = Orgs[id].label } end
    return out
end

-- The ways in from outside this file, each run on the organisation it is
-- about. With one organisation every one of them is the first, as before.

local function wrapBy(name, pick)
    local raw = Org[name]
    Org[name] = function(...)
        local org = pick(...)
        if not org then return raw(...) end
        return Org.within(org, raw, ...)
    end
end

local function byCid(cid) return Org.orgOf(cid) end
local function bySrc(src)
    local actor = deps and deps.identity.resolve(tonumber(src))
    return actor and Org.orgOf(actor.cid) or nil
end

wrapBy('termsFor', byCid)
wrapBy('shownName', byCid)
wrapBy('playerLoaded', bySrc)
wrapBy('inviteFor', function(cid)
    if Org.orgOf(cid) then return Org.orgOf(cid) end
    local invite = inviteOf(cid)
    return invite and Orgs[invite.org or ''] or nil
end)
wrapBy('answerInvite', function(actor)
    local invite = type(actor) == 'table' and inviteOf(actor.cid)
    return invite and Orgs[invite.org or ''] or nil
end)
wrapBy('onGroupUpdate', function(_, groupName)
    for _, id in ipairs(Order) do
        if Orgs[id].job == groupName then return Orgs[id] end
    end
    return nil
end)
wrapBy('useSpot', function(_, id)
    if type(id) ~= 'string' then return nil end
    for _, oid in ipairs(Order) do
        if Orgs[oid].locations[id:sub(1, 48)] then return Orgs[oid] end
    end
    return nil
end)
wrapBy('sendRefusal', function(orgId) return Org.byId(orgId) end)
wrapBy('garageView', function(who) return type(who) == 'table' and Org.orgOf(who.cid) or nil end)
wrapBy('receiveContract', function(_, _, orgId) return Org.byId(orgId) end)

do
    -- In every organisation: each keeps its own members and job.
    local rawReconcile = Org.reconcile
    Org.reconcile = function(src)
        if #Order < 2 then return rawReconcile(src) end
        for _, id in ipairs(Order) do
            if Orgs[id] then Org.within(Orgs[id], rawReconcile, src) end
        end
    end

    local rawSpots = Org.spotsFor
    Org.spotsFor = function(cid)
        if #Order < 2 then return rawSpots(cid) end
        local out = {}
        for _, id in ipairs(Order) do
            for _, row in ipairs(Org.within(Orgs[id], rawSpots, cid)) do out[#out + 1] = row end
        end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end

    local rawTab = Org.tabFor
    Org.tabFor = function(cid, src)
        if #Order < 2 then return rawTab(cid, src) end
        local mine = Org.orgOf(cid)
        if mine then return Org.within(mine, rawTab, cid, src) end
        for _, id in ipairs(Order) do
            local tab = Org.within(Orgs[id], rawTab, cid, src)
            if tab then return tab end
        end
        return nil
    end

    local rawPayroll = Org.payrollTick
    Org.payrollTick = function(at)
        if #Order < 2 then return rawPayroll(at) end
        local firstOut
        for i, id in ipairs(Order) do
            local out = Orgs[id] and Org.within(Orgs[id], rawPayroll, at)
            if i == 1 then firstOut = out end
        end
        return firstOut
    end

    -- Held for any organisation: only its assigned member, whoever asks.
    local rawGate = Org.acceptGate
    Org.acceptGate = function(actor, contractId, opts, out)
        if #Order < 2 or type(actor) ~= 'table' or not Feature.on('Organisation') then
            return rawGate(actor, contractId, opts, out)
        end
        local home = Org.orgOf(actor.cid) or Orgs[Order[1]]
        for _, id in ipairs(Order) do
            local org = Orgs[id]
            if org ~= home then
                local held, data = Org.within(org, Extras.reservedRefusal, org, actor, contractId, opts)
                if held then return held, data end
            end
        end
        return Org.within(home, rawGate, actor, contractId, opts, out)
    end

    local rawAfter = Org.afterAccept
    Org.afterAccept = function(actor, contractId, gate)
        if #Order < 2 or type(actor) ~= 'table' or not Feature.on('Organisation') then
            return rawAfter(actor, contractId, gate)
        end
        local home = Org.orgOf(actor.cid) or Orgs[Order[1]]
        for _, id in ipairs(Order) do
            local org = Orgs[id]
            if org ~= home and org.settings.orgContracts[contractId] then
                Org.within(org, Extras.afterAccept, org, actor, contractId)
            end
        end
        return Org.within(home, rawAfter, actor, contractId, gate)
    end

    -- The record's outcomes: the stats (extras 2), reputation and the
    -- activity log (extras 3), on the member's own organisation.
    -- Kept on the module the first time: this file may be read again
    -- (a fresh stack in the tests), and Extras2 is not.
    Extras2.rawObserve = Extras2.rawObserve or Extras2.observe
    local rawObserve = Extras2.rawObserve
    local function both(kind, cid, info)
        rawObserve(kind, cid, info)
        Extras3.observe(kind, cid, info)
    end
    Extras2.observe = function(kind, cid, info)
        local org = Org.orgOf(cid)
        if not org then return both(kind, cid, info) end
        return Org.within(org, both, kind, cid, info)
    end

    Extras.rawFrameworkDuty = Extras.rawFrameworkDuty or Extras.frameworkDuty
    local rawDuty = Extras.rawFrameworkDuty
    Extras.frameworkDuty = function(src, value)
        local org = bySrc(src)
        if not org then return rawDuty(src, value) end
        return Org.within(org, rawDuty, src, value)
    end
end

return Org
