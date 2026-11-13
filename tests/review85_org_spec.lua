--- Review 85, organisation fixes: each confirmed finding, driven through the
--- code the game runs (the org functions, the panel's ops, the phone's
--- requests, the mysql store and its migration).
---
---   * C7-2 / F2-1: a contract on a member is never held for their own
---     organisation, never assigned to (or by) a party to it, never listed
---     to its target, and the handler never hands it to one;
---   * C7-3: the target boss is never told of, shown or let decide an
---     accept of a contract on themselves;
---   * C7-1: a take grant whose granter lost D2 shows as not in force;
---   * C8-1: 'Targets on whitelisted jobs: Not allowed' is stored and kept;
---   * C8-2: an existing framework job (police) is never made an
---     organisation, nor registered over at a start;
---   * GAP1-1 / GAP1-2: the application body and the settings column are
---     wide enough, existing tables are widened, the record is bounded and
---     a refused activity-log save never fails the action;
---   * GAP1-3: application text and fire / suspend reasons cut by whole
---     characters;
---   * F2-2 / G2-1: garage vehicles are taken away when the organisation is
---     switched off, and through the adapter they were made with;
---   * G2R1-1: an internal contract is re-checked against the boss who asked;
---   * F1-1: an anonymous member's org contract is not named to staff
---     without IdentityAce;
---   * C8-3: the org log names nobody to staff without IdentityAce, nested
---     or former;
---   * the lows: staff mutes, discipline sentences, the ledger's refusal,
---     approvals switched off, invites, layout and office rules by rank, the
---     organisation-limit message and the strings moved to the locale.

local OW = require('tests.harness.org_world')
local QbxJobs = OW.QbxJobs

local STAFF = { staff = true, cid = 'ADMIN001', source = 6 }
local BOSS = OW.boss(11, 'BOSS0001')
local LIEUT = OW.boss(12, 'LIEUT001')

local function world(on, extra, opts)
    opts = opts or {}
    local s, f = OW.world({ bank = opts.bank, configure = function()
        if not opts.bank then Config.Integrations.Banking = 'none' end
        Config.Cooldowns.create = { per = 10, burst = 100 }
        for _, key in ipairs(on or {}) do Config.Organisation[key] = true end
        for k, v in pairs(extra or {}) do Config.Organisation[k] = v end
        if opts.configure then opts.configure() end
    end })
    if opts.crew ~= false then OW.crew(s) end
    return s, f, s.org.current()
end

--- Every notice a citizen is sent from here on: [cid] = { text, ... }.
local function told(s)
    local said = {}
    local real = s.notify.toCitizen
    s.notify.toCitizen = function(cid, title, text, ...)
        said[cid] = said[cid] or {}
        table.insert(said[cid], tostring(text))
        return real(cid, title, text, ...)
    end
    return said
end

local function has(list, needle)
    for _, text in ipairs(list or {}) do if tostring(text):find(needle, 1, true) then return true end end
    return false
end

--- Every string anywhere in a value, joined.
local function text(v)
    local out = {}
    local function walk(x)
        if type(x) == 'table' then
            for k, y in pairs(x) do out[#out + 1] = tostring(k); walk(y) end
        else
            out[#out + 1] = tostring(x)
        end
    end
    walk(v)
    return table.concat(out, ' ')
end

local function spot(s, kind, x, y)
    OW.at(6, x, y, 30.0)
    local ok, err, row = s.org.placeSpot(STAFF, { kind = kind, here = true })
    assert(ok, kind .. ': ' .. tostring(err) .. ' ' .. tostring(row and row.message))
    return row
end

local function vehicles()
    local n = 0
    for _ in pairs(Env.vehicles or {}) do n = n + 1 end
    return n
end

local function source(path)
    local handle = assert(io.open('crimson-hitman/' .. path, 'r'))
    local body = handle:read('a')
    handle:close()
    return body
end

--------------------------------------------------------------------------
-- C7-2 / F2-1
--------------------------------------------------------------------------

describe('Review 85 C7-2 / F2-1: a contract on a member and its own organisation', function()
    it('is never held for the target\'s organisation, nor told to its bosses', function()
        local s, f, org = world({ 'OrgContracts' })
        OW.allow(s, 3, 'K4')
        OW.allow(s, 3, 'K5')
        local said = told(s)
        local c = assert(OW.place(s, f.creator, 'BOSS0001'))
        falsy(s.org.receiveContract(c.id, 'CREATOR1'), 'not held for the organisation of its target')
        eq(org.settings.orgContracts[c.id], nil)
        falsy(has(said.BOSS0001, 'A contract was sent'), 'the target boss is told nothing')
        local ok, _, work = s.org.work(BOSS)
        truthy(ok)
        for _, row in ipairs(work.contracts or {}) do falsy(row.id == c.id, 'never listed to its target') end
        -- One on somebody else is still held, as before.
        local other = assert(OW.place(s, f.creator, 'READER01'))
        truthy(s.org.receiveContract(other.id, 'CREATOR1'))
    end)

    it('is never assigned to its target or placer, nor by its target, nor listed or shown to them', function()
        local s, f, org = world({ 'OrgContracts' })
        OW.allow(s, 3, 'K4')
        OW.allow(s, 3, 'K5')
        -- A contract held before this build, on a member: an entry as one
        -- older build kept.
        local c = assert(OW.place(s, f.creator, 'BOSS0001'))
        org.settings.orgContracts[c.id] = { state = 'waiting', at = os.time(), expires = os.time() + 1800 }
        local ok, err = s.org.assignContract(STAFF, c.id, 'BOSS0001')
        falsy(ok, 'never to its own target')
        eq(err, s.org.ERR.RULE)
        ok, err = s.org.assignContract(BOSS, c.id, 'RECRUIT1')
        falsy(ok, 'nor by its target')
        eq(err, s.org.ERR.NOT_FOUND)
        local _, _, work = s.org.work(BOSS)
        for _, row in ipairs(work.contracts or {}) do falsy(row.id == c.id, 'not in the target\'s work') end
        -- Staff may still give it to somebody else; then the target's tab
        -- never shows it, and a contract on the member themselves is never
        -- in their own assigned list.
        truthy(s.org.assignContract(STAFF, c.id, 'RECRUIT1'))
        local c2 = assert(OW.place(s, f.creator, 'RECRUIT1'))
        org.settings.orgContracts[c2.id] = { state = 'assigned', cid = 'RECRUIT1', at = os.time(),
            expires = os.time() + 1800 }
        local out = {}
        s.org.Extras.mine(org, org.members.RECRUIT1, out)
        local ids = {}
        for _, row in ipairs(out.assigned or {}) do ids[row.id] = true end
        truthy(ids[c.id], 'the one on the boss is the recruit\'s')
        falsy(ids[c2.id], 'never one on the recruit themselves')
    end)

    it('is never handed out by the handler to a party to it', function()
        local s, f, org = world({ 'Handler', 'OrgContracts' })
        local npc = spot(s, 'npc', 500.0, 500.0)
        local c = assert(OW.place(s, f.creator, 'RECRUIT1'))
        org.settings.orgContracts[c.id] = { state = 'waiting', at = os.time(), expires = os.time() + 1800 }
        OW.at(13, 500.0, 500.0)
        s.org.useSpot(13, npc.id)
        eq(org.settings.orgContracts[c.id].state, 'waiting', 'not reserved to its own target')
        OW.at(12, 500.0, 500.0)
        s.org.useSpot(12, npc.id)
        eq(org.settings.orgContracts[c.id].cid, 'LIEUT001', 'another member gets it')
    end)
end)

--------------------------------------------------------------------------
-- C7-3
--------------------------------------------------------------------------

describe('Review 85 C7-3: the target boss and an accept on themselves', function()
    it('is not told, shown it or let decide it; another K6 holder and staff still decide', function()
        local s, f, org = world({ 'AcceptApproval' }, { ApprovalAbove = 0 })
        OW.allow(s, 3, 'K6')
        OW.allow(s, 2, 'K6')
        org.roles[0].powers = org.roles[0].powers or {}
        org.roles[0].powers.TAKE = { by = 'staff' }
        local said = told(s)
        local c = assert(OW.place(s, f.creator, 'BOSS0001'))
        local ok, err = s.contracts.accept(s.identity.resolve(13), c.id)
        falsy(ok)
        eq(err, 'org_approval')
        falsy(has(said.BOSS0001, 'A member asks to take a contract'), 'the target is not told')
        truthy(has(said.LIEUT001, 'A member asks to take a contract'), 'another K6 holder is')
        local _, _, work = s.org.work(BOSS)
        eq(#(work.approvals or {}), 0, 'nothing listed to the target')
        local _, _, lw = s.org.work(LIEUT)
        eq(#lw.approvals, 1)
        local id = lw.approvals[1].id
        eq(select(2, s.org.decideAccept(BOSS, id, false)), s.org.ERR.NOT_FOUND, 'the target may not refuse it')
        truthy(s.org.decideAccept(STAFF, id, true), 'staff decide it')
    end)
end)

--------------------------------------------------------------------------
-- C7-1
--------------------------------------------------------------------------

describe('Review 85 C7-1: a take grant whose granter lost D2', function()
    it('shows as not in force, and in force again once D2 is back', function()
        local s, _, org = world()
        OW.allow(s, 3, 'D2')
        OW.office(s)
        OW.at(11, 100.0, 100.0, 30.0)
        truthy(s.org.memberGrant(BOSS, 'RECRUIT1', 'TAKE', 'grant'))
        local E = s.org.Engine
        eq(E.inactiveWhy(org, 'RECRUIT1', org.members.RECRUIT1.grants.TAKE, 'TAKE'), nil)
        truthy(s.org.setCeiling(OW.STAFF, 'role', 3, 'D2', 'off'))
        falsy(E.holds(org, 'RECRUIT1', 'TAKE'))
        eq(E.inactiveWhy(org, 'RECRUIT1', org.members.RECRUIT1.grants.TAKE, 'TAKE'), 'granter_lost')
        OW.allow(s, 3, 'D2')
        eq(E.inactiveWhy(org, 'RECRUIT1', org.members.RECRUIT1.grants.TAKE, 'TAKE'), nil)
    end)
end)

--------------------------------------------------------------------------
-- C8-1
--------------------------------------------------------------------------

describe('Review 85 C8-1: Targets on whitelisted jobs: Not allowed', function()
    it('is stored, refuses a protected target, and clears when allowed again', function()
        local s, f, org = world()
        local reply = OW.ask(6, 'orgAccess', { grade = 0, rules = { whitelisted = false } })
        truthy(reply.ok, tostring(reply.message))
        eq(org.settings.access['0'] and org.settings.access['0'].whitelisted, false, 'kept as false')
        local c = assert(OW.place(s, f.creator))
        local row = s.storage.readContract(c.id)
        row.target_protected = true
        s.storage.writeContract(row)
        local ok, err = s.contracts.accept(s.identity.resolve(13), c.id)
        falsy(ok, 'refused on a whitelisted-job target')
        eq(err, s.org.ERR.RULE)
        truthy(OW.ask(6, 'orgAccess', { grade = 0, rules = { whitelisted = true } }).ok)
        eq(org.settings.access['0'], nil, 'allowed is the default')
        truthy(s.contracts.accept(s.identity.resolve(13), c.id))
    end)
end)

--------------------------------------------------------------------------
-- C8-2
--------------------------------------------------------------------------

describe('Review 85 C8-2: an existing framework job', function()
    local function police()
        exports.qbx_core:CreateJobs({ police = { label = 'LSPD', type = 'leo', defaultDuty = true,
            grades = { [0] = { name = 'Cadet', payment = 50 }, [4] = { name = 'Chief', payment = 500, isboss = true } } } })
    end

    it('is never made an organisation, and says why', function()
        local s = world(nil, nil, { crew = false, configure = function()
            Config.Organisation.SeveralOrganisations = true
        end })
        police()
        local reply = OW.ask(6, 'orgCreate', { job = 'police', label = 'Crew' })
        falsy(reply.ok, 'refused')
        truthy(tostring(reply.message):find('qbx_core already has a job', 1, true), tostring(reply.message))
        eq(QbxJobs.jobs.police.type, 'leo', 'its type kept')
        eq(QbxJobs.jobs.police.grades[4].name, 'Chief', 'its grades kept')
        for _, id in ipairs(s.org.byId('hitman').settings.others) do falsy(id == 'police') end
        -- A name of its own still works.
        truthy(OW.ask(6, 'orgCreate', { job = 'syndicate', label = 'The Syndicate' }).ok)
    end)

    it('saved by an older build, is never registered over at a start', function()
        local s = world(nil, nil, { crew = false, configure = function()
            Config.Organisation.SeveralOrganisations = true
        end })
        police()
        s.storage.writeOrgRow('orgs', { id = 'police', job = 'police', label = 'Crew', job_type = 'hitman',
            settings = {}, created_at = os.time() })
        local stored = s.storage.readOrgRow('orgs', 'hitman')
        local settings = type(stored.settings) == 'string' and json.decode(stored.settings) or stored.settings
        settings.others = { 'police' }
        stored.settings = settings
        s.storage.writeOrgRow('orgs', stored)
        s.org.boot(true)
        eq(QbxJobs.jobs.police.type, 'leo', 'its type kept')
        eq(QbxJobs.jobs.police.grades[4].name, 'Chief', 'its grades kept')
        eq(s.org.byId('police'), nil, 'left out')
    end)
end)

--------------------------------------------------------------------------
-- GAP1-1 / GAP1-2: the mysql columns
--------------------------------------------------------------------------

describe('Review 85 GAP1-1 / GAP1-2: the mysql columns', function()
    local Exec = require('tests.harness.mysql_exec')

    local function store()
        Exec.install(Natives)
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local m = require('crimson-hitman.server.storage.mysql')
        m.open()
        return m
    end

    it('take an application body past 255 and settings past 64 KB', function()
        local m = store()
        local body = '\2' .. ('{"form":[{"q":"Why us?","a":"%s"}],"text":"hi"}'):format(('é'):rep(400))
        local ok, err = pcall(m.writeOrgRow, 'applications', { id = 'app:hitman:1:1', org_id = 'hitman',
            cid = 'RECRUIT1', name = 'P13', body = body, state = 'open', created_at = 1 })
        truthy(ok, 'the application body: ' .. tostring(err))
        eq(m.readOrgRow('applications', 'app:hitman:1:1').body, body)
        local log = {}
        for i = 1, 1000 do
            log[i] = { at = i, a = 'org_member_role', by = 'BOSS0001', m = 'RECRUIT1', grade = i % 4, power = 'M4',
                kind = ('x'):rep(40), state = ('y'):rep(40) }
        end
        ok, err = pcall(m.writeOrgRow, 'orgs', { id = 'hitman', job = 'hitman', label = 'Org', job_type = 'hitman',
            settings = { activity = log }, created_at = 1 })
        truthy(ok, 'settings past 64 KB: ' .. tostring(err))
        eq(#m.readOrgRow('orgs', 'hitman').settings.activity, 1000)
    end)

    it('are widened on a table an older version made, keeping its rows, once', function()
        Exec.install(Natives)
        Exec.run([[CREATE TABLE IF NOT EXISTS crimson_orgs (
            id VARCHAR(32) PRIMARY KEY, job VARCHAR(32) NOT NULL, label VARCHAR(64), job_type VARCHAR(32),
            settings TEXT, created_at INT NOT NULL, updated_at INT
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]])
        Exec.run([[CREATE TABLE IF NOT EXISTS crimson_org_applications (
            id VARCHAR(48) PRIMARY KEY, org_id VARCHAR(32) NOT NULL, cid VARCHAR(32) NOT NULL, name VARCHAR(64),
            body VARCHAR(255), state VARCHAR(12) NOT NULL, decided_by VARCHAR(64), created_at INT NOT NULL,
            decided_at INT, INDEX idx_org_applications_org (org_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]])
        Exec.run('INSERT INTO crimson_org_applications (id, org_id, cid, state, created_at, body) VALUES (?, ?, ?, ?, ?, ?)',
            { 'old', 'hitman', 'X1', 'open', 1, 'kept' })
        local ran = {}
        local realRun = Exec.run
        Exec.run = function(sql, params)
            if type(sql) == 'string' and sql:find('MODIFY COLUMN', 1, true) then ran[#ran + 1] = sql end
            return realRun(sql, params)
        end
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local m = require('crimson-hitman.server.storage.mysql')
        local ok, err = pcall(m.open)
        truthy(ok, tostring(err))
        local all = table.concat(ran, ' | ')
        truthy(all:find('ALTER TABLE crimson_orgs MODIFY COLUMN settings MEDIUMTEXT', 1, true), all)
        truthy(all:find('ALTER TABLE crimson_org_applications MODIFY COLUMN body MEDIUMTEXT', 1, true), all)
        eq(m.readOrgRow('applications', 'old').body, 'kept', 'its rows kept')
        ok, err = pcall(m.writeOrgRow, 'applications', { id = 'new', org_id = 'hitman', cid = 'X2', name = 'P',
            body = ('a'):rep(1000), state = 'open', created_at = 2 })
        truthy(ok, 'a long body after the widening: ' .. tostring(err))
        ran = {}
        m.migrate()
        Exec.run = realRun
        eq(#ran, 0, 'a second run widens nothing')
    end)

    it('are widened by migrate as the database reports them, and never another column', function()
        local Sim = require('tests.harness.mysql_sim')
        Sim.install(Natives)
        Sim.existingSchema({
            crimson_orgs = { id = true, job = true, label = true, job_type = true, settings = true,
                created_at = true, updated_at = true },
            crimson_contracts = { id = true, creator_cid = true, target_cid = true, mode = true, state = true,
                created_at = true },
        })
        Sim.existingTypes = { crimson_orgs = { settings = 'text', label = 'varchar' },
            crimson_contracts = { creator_cid = 'varchar' } }
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local m = require('crimson-hitman.server.storage.mysql')
        m.open()
        local widened = {}
        for _, change in ipairs(Sim.altered) do
            if change.modified then widened[#widened + 1] = change.table_ .. '.' .. change.modified end
        end
        eq(table.concat(widened, ','), 'crimson_orgs.settings')
        Sim.altered = {}
        m.migrate()
        for _, change in ipairs(Sim.altered) do falsy(change.modified, 'nothing the second time: ' .. change.sql) end
    end)

    it('ship in the install SQL the same', function()
        local sql = source('install/sql/crimson_hitman.sql')
        truthy(sql:find('settings MEDIUMTEXT,', 1, true))
        truthy(sql:match('crimson_org_applications %b()'):find('body MEDIUMTEXT,', 1, true))
    end)
end)

describe('Review 85 GAP1-2: the settings row cannot grow without limit', function()
    it('keeps at most RECORD_MOST discipline entries, a former member\'s going first', function()
        local s, _, org = world({ 'Discipline' })
        local most = s.org.Extras2.RECORD_MOST
        truthy(most and most > 0, 'a bound')
        local gone = {}
        for i = 1, most do gone[i] = { id = 'dc' .. i, kind = 'warning', reason = 'x', at = 1000 + i, by = 'boss' } end
        org.settings.discipline.GONE0001 = gone
        truthy(s.org.discipline(STAFF, 'RECRUIT1', 'warning', 'late'))
        local total = 0
        for _, list in pairs(org.settings.discipline) do total = total + #list end
        eq(total, most)
        eq(#org.settings.discipline.RECRUIT1, 1, 'the member\'s own kept')
        eq(org.settings.discipline.GONE0001[1].id, 'dc2', 'the oldest of the former member went')
    end)

    it('never fails the action for an activity-log save the store refuses', function()
        local s = world({ 'ActivityLog' })
        local real = s.storage.writeOrgRow
        s.storage.writeOrgRow = function(kind, row)
            if kind == 'orgs' then error('Data too long for column \'settings\' at row 1', 0) end
            return real(kind, row)
        end
        local ok, err = pcall(s.org.Extras3.logAction, 'org_member_role', BOSS, { member = 'RECRUIT1', grade = 0 })
        s.storage.writeOrgRow = real
        truthy(ok, 'said, never raised: ' .. tostring(err))
    end)

    it('uses no hourly application slot on a body that could not be made', function()
        local s, _, org = world({ 'Recruitment' }, { RecruitPerHour = 1, ApplyAtSignupOnly = false })
        org.settings.recruit.questions = { 'Why us?' }
        local realEncode = json.encode
        json.encode = function() error('cannot encode', 0) end
        local ok = s.org.apply(s.identity.resolve(3), 'hello', { 'because' })
        json.encode = realEncode
        falsy(ok)
        truthy(s.org.apply(s.identity.resolve(3), 'hello', { 'because' }), 'the hour\'s one slot is still free')
    end)
end)

--------------------------------------------------------------------------
-- GAP1-3
--------------------------------------------------------------------------

describe('Review 85 GAP1-3: text cut by whole characters', function()
    it('keeps the application text, a fire reason and a suspend reason valid UTF-8', function()
        local s, _, org = world(nil, { ApplyAtSignupOnly = false })
        truthy(s.org.apply(s.identity.resolve(3), ('a'):rep(254) .. 'é'))
        for _, a in pairs(org.applications) do
            truthy(utf8.len(a.body), 'the application body')
            eq(a.body, ('a'):rep(254))
        end
        truthy(s.org.suspend(STAFF, 'RECRUIT1', 2, ('b'):rep(159) .. 'é'))
        truthy(s.org.fire(STAFF, 'LIEUT001', ('c'):rep(159) .. 'é'))
        s.audit.flush()
        for _, action in ipairs({ 'org_member_suspended', 'org_member_fired' }) do
            local rows = OW.audit(action)
            truthy(#rows > 0, action)
            for _, r in ipairs(rows) do
                local reason = type(r.detail) == 'table' and r.detail.reason
                if reason then truthy(utf8.len(reason), action .. ' reason is whole characters') end
            end
        end
    end)
end)

--------------------------------------------------------------------------
-- F2-2 / G2-1: the garage
--------------------------------------------------------------------------

describe('Review 85 F2-2 / G2-1: garage vehicles', function()
    local function setup()
        local s, f, org = world({ 'Garage' }, { GarageVehicles = { 'sultan' } })
        spot(s, 'garage', 300.0, 300.0)
        OW.at(13, 300.0, 300.0)
        truthy(OW.call('orgGarageTake', 13, { model = 'sultan' }).ok)
        eq(vehicles(), 1)
        return s, f, org
    end

    it('are taken away when Organisation is switched off live', function()
        local s = setup()
        truthy(s.settings.set('Organisation.Enabled', false, 'ADMIN001', 'ADMIN001'))
        eq(vehicles(), 0, 'taken away with the organisation')
    end)

    it('are taken away through the adapter they were made with, after Garage is set to none', function()
        setup()
        Config.Integrations.Garage = 'none'
        local id = next(Env.vehicles)
        Env.vehicles[id].x = 5000.0
        falsy(OW.call('orgGarageReturn', 13, {}).ok, 'still only near the spot')
        eq(vehicles(), 1, 'and still tracked')
        Env.vehicles[id].x = 302.0
        truthy(OW.call('orgGarageReturn', 13, {}).ok)
        eq(vehicles(), 0, 'taken away from the world')
    end)
end)

--------------------------------------------------------------------------
-- G2R1-1
--------------------------------------------------------------------------

describe('Review 85 G2R1-1: an internal contract and the boss who asked', function()
    local function setup()
        local s, f, org = world({ 'InternalContracts' })
        OW.allow(s, 2, 'K8')
        OW.office(s)
        OW.at(12, 100.0, 100.0)
        local ok, err, data = s.org.internalRequest(LIEUT, 'RECRUIT1', { reason = 'went rogue', amount = 6000 })
        truthy(ok, tostring(err))
        return s, f, org, data.id
    end

    it('is declined when they leave, and never placed in their name', function()
        local s, _, org, id = setup()
        local cash = OW.wealth(12)
        truthy(s.org.fire(STAFF, 'LIEUT001', 'gone'))
        eq(org.settings.internal[id].state, 'declined')
        falsy(s.org.internalDecide(STAFF, id, true))
        eq(org.settings.internal[id].contract, nil)
        eq(OW.wealth(12), cash, 'nothing taken')
    end)

    it('is declined when they no longer hold K8', function()
        local s, _, org, id = setup()
        local cash = OW.wealth(12)
        truthy(s.org.setCeiling(OW.STAFF, 'role', 2, 'K8', 'off'))
        local ok, err = s.org.internalDecide(STAFF, id, true)
        falsy(ok)
        eq(err, s.org.ERR.RULE)
        eq(org.settings.internal[id].state, 'declined')
        eq(OW.wealth(12), cash, 'nothing taken')
    end)
end)

--------------------------------------------------------------------------
-- F1-1
--------------------------------------------------------------------------

describe('Review 85 F1-1: an anonymous member on an org contract, to staff', function()
    it('is named only with IdentityAce', function()
        local s, f, org = world({ 'OrgContracts' }, nil, { configure = function()
            Config.TargetClasses.default.AllowAnonymousHitman = true
        end })
        local c = assert(OW.place(s, f.creator, 'READER01'))
        truthy(s.org.receiveContract(c.id, 'CREATOR1'))
        truthy(s.org.assignContract(STAFF, c.id, 'RECRUIT1'))
        local ok, err = s.contracts.accept(s.identity.resolve(13), c.id, true)
        truthy(ok, tostring(err))
        eq(org.settings.orgContracts[c.id].state, 'taken')
        local function row(canIdentify)
            local _, _, work = s.org.work({ staff = true, cid = 'ADMIN001', canIdentify = canIdentify })
            for _, r in ipairs(work.contracts) do if r.id == c.id then return r end end
        end
        eq(row(false).member, nil, 'no member without IdentityAce')
        truthy(row(true).member, 'named with it')
    end)
end)

--------------------------------------------------------------------------
-- C8-3
--------------------------------------------------------------------------

describe('Review 85 C8-3: the org log to staff without IdentityAce', function()
    it('names no citizen id at any depth, nor a granter fired since', function()
        local s = world()
        OW.allow(s, 3, 'D2'); OW.allow(s, 3, 'M1'); OW.allow(s, 3, 'R4')
        OW.allow(s, 2, 'R4'); OW.allow(s, 2, 'M1')
        OW.office(s)
        OW.at(11, 100.0, 100.0); OW.at(12, 100.0, 100.0)
        truthy(s.org.memberGrant(BOSS, 'RECRUIT1', 'M1', 'grant'))
        truthy(s.org.memberGrant(BOSS, 'RECRUIT1', 'M1', 'deny'))
        truthy(s.org.rolePower(LIEUT, 0, 'M1', true))
        truthy(s.org.rolePower(BOSS, 0, 'M1', false))
        truthy(s.org.fire(STAFF, 'LIEUT001', 'gone'))
        s.audit.flush()
        local log = OW.ask(6, 'logs', { area = 'org', limit = 100 })
        truthy(log.ok)
        local all = text(log.data.rows)
        for _, cid in ipairs({ 'BOSS0001', 'LIEUT001', 'RECRUIT1' }) do
            falsy(all:find(cid, 1, true), cid .. ' named')
        end
        Env.aces[6]['crimson.identity'] = true
        truthy(text(OW.ask(6, 'logs', { area = 'org', limit = 100 }).data.rows):find('LIEUT001', 1, true),
            'named with IdentityAce')
    end)

    it('ties no contract to a member, and says a player for one who is not a member', function()
        local s, f = world(nil, { ApplyAtSignupOnly = false })
        local c = assert(OW.place(s, f.creator, 'READER01', { anonymousHitman = true }))
        truthy(s.contracts.accept(s.identity.resolve(13), c.id))
        truthy(s.org.apply(s.identity.resolve(3), 'let me in'))
        s.audit.flush()
        local seen = {}
        for _, r in ipairs(OW.ask(6, 'logs', { area = 'org', limit = 100 }).data.rows) do
            seen[r.action] = r
            if r.action == 'org_split_frozen' then eq(r.contract, nil, 'no contract on a member\'s accept') end
        end
        truthy(seen.org_split_frozen, 'the accept is on the log')
        eq(seen.org_applied.by, 'a player')
    end)
end)

--------------------------------------------------------------------------
-- The lows
--------------------------------------------------------------------------

describe('Review 85 lows: what members and staff are told', function()
    it('C7-4: a member muted by staff is told staff did it when they post', function()
        local s = world({ 'Channel' })
        truthy(s.org.channelMute(STAFF, 'RECRUIT1', 2))
        local r = OW.call('orgChannelPost', 13, { text = 'hello' })
        falsy(r.ok)
        local said = tostring(r.data and r.data.message)
        truthy(said:find('Staff muted you', 1, true), said)
        OW.allow(s, 3, 'N3')
        truthy(s.org.channelMute(BOSS, 'RECRUIT1', 2))
        r = OW.call('orgChannelPost', 13, { text = 'hello' })
        truthy(tostring(r.data.message):find('A boss muted you', 1, true))
    end)

    it('C7-5: an overturned strike is one whole sentence', function()
        local s = world({ 'Discipline' })
        local said = told(s)
        local ok, _, data = s.org.discipline(STAFF, 'RECRUIT1', 'strike', 'late')
        truthy(ok)
        truthy(s.org.overturn(STAFF, 'RECRUIT1', data.id, 'mistake'))
        truthy(has(said.RECRUIT1, 'Staff overturned a strike on your record.'), table.concat(said.RECRUIT1 or {}, ' / '))
    end)

    it('C8-4: a deposit the ledger refuses is not said to be Renewed-Banking\'s', function()
        local s = world()
        OW.allow(s, 3, 'C6')
        OW.office(s)
        OW.at(11, 100.0, 100.0)
        local real = s.storage.insertOrgRowOnce
        s.storage.insertOrgRowOnce = function(kind, row)
            if kind == 'funds' then error('db down', 0) end
            return real(kind, row)
        end
        local before = OW.wealth(11)
        local ok, err, _, message = s.org.deposit(BOSS, 500, 'bank', 'dep1')
        s.storage.insertOrgRowOnce = real
        falsy(ok)
        falsy(err == s.org.ERR.BANK_REFUSED, 'not BANK_REFUSED on the ledger')
        falsy(tostring(message):find('Renewed', 1, true), tostring(message))
        eq(OW.wealth(11), before, 'given back')
    end)

    it('F1-2: approvals switched off say so, never "nobody approved"', function()
        local s, f, org = world({ 'AcceptApproval' }, { ApprovalAbove = 0 })
        OW.allow(s, 3, 'K6')
        org.roles[0].powers = org.roles[0].powers or {}
        org.roles[0].powers.TAKE = { by = 'staff' }
        local said = told(s)
        local c = assert(OW.place(s, f.creator))
        eq(select(2, s.contracts.accept(s.identity.resolve(13), c.id)), 'org_approval')
        Config.Organisation.AcceptApproval = false
        s.org.extrasTick(os.time())
        truthy(has(said.RECRUIT1, 'Approvals were switched off'), table.concat(said.RECRUIT1 or {}, ' / '))
        falsy(has(said.RECRUIT1, 'Nobody approved'))
    end)

    it('G2-4: an invite that can no longer be accepted says so', function()
        local s = world()
        OW.allow(s, 3, 'M2')
        OW.office(s)
        OW.at(11, 100.0, 100.0)
        OW.player(21, 'NEWBIE01')
        OW.at(21, 101.0, 100.0)
        truthy(s.org.hire(BOSS, s.identity.resolve(21), 0))
        local invite = s.org.inviteFor('NEWBIE01')
        truthy(s.org.setCeiling(OW.STAFF, 'role', 3, 'M2', 'off'))
        local ok, err, _, message = s.org.answerInvite(s.identity.resolve(21), invite.id, true)
        falsy(ok)
        eq(err, s.org.ERR.RULE)
        truthy(tostring(message):find('That invite can no longer be accepted', 1, true), tostring(message))
    end)

    it('G2-5: the layout and office rules a boss sets bind only grades below them', function()
        local s, _, org = world()
        OW.allow(s, 2, 'S2')
        OW.allow(s, 2, 'S3')
        OW.allow(s, 3, 'S3')
        OW.allow(s, 2, 'M1')
        OW.allow(s, 3, 'M1')
        OW.office(s)
        OW.at(11, 100.0, 100.0); OW.at(12, 100.0, 100.0)
        truthy(s.org.layout(STAFF, { hidden = { settings = { 3 } } }))
        truthy(s.org.layout(LIEUT, { hidden = { settings = { 0 }, members = { 3 } } }))
        local hidden = org.settings.layout.hidden
        local function holds(list, g) for _, x in ipairs(list or {}) do if x == g then return true end end return false end
        truthy(holds(hidden.settings, 0), 'below them: theirs to hide')
        truthy(holds(hidden.settings, 3), 'what staff hid from the top boss stays')
        falsy(holds(hidden.members, 3), 'never hidden from the boss above them')
        truthy(s.org.officeRule(LIEUT, 'M1', true))
        falsy(s.org.Engine.needsOffice(org, 'M1', 'BOSS0001'), 'the top boss is not bound by it')
        truthy(s.org.Engine.needsOffice(org, 'M1', 'LIEUT001'))
        truthy(s.org.officeRule(BOSS, 'M1', true))
        eq(select(2, s.org.officeRule(LIEUT, 'M1', false)), s.org.ERR.RANK, 'nor lifted from below')
    end)

    it('R3G2-3: the organisation limit says which limit, whole', function()
        world(nil, { SeveralOrganisations = true, MaxOrganisations = 1 }, { crew = false })
        local reply = OW.ask(6, 'orgCreate', { job = 'syndicate', label = 'The Syndicate' })
        falsy(reply.ok)
        truthy(tostring(reply.message):find('Config.Organisation.MaxOrganisations).', 1, true), tostring(reply.message))
    end)
end)

describe('Review 85 lows: player text from the locale, never English in code', function()
    it('builds the bands, the stash label, the codename label and the power labels from locale keys', function()
        local s = world()
        local Locale = CrimsonBoot.requireShared('locale')
        local L = Locale.t
        Config.Organisation.StatsBandShort, Config.Organisation.StatsBandMid, Config.Organisation.StatsBandLong = 30, 60, 180
        local E2 = s.org.Extras2
        eq(E2.band(600), (L('org_extras2.band_under')):format((L('org_extras2.min')):format(30)))
        eq(E2.band(2700), (L('org_extras2.band_between')):format((L('org_extras2.min')):format(30),
            (L('org_extras2.hours_short')):format(1)))
        eq(E2.band(20000), (L('org_extras2.band_over')):format((L('org_extras2.hours_short')):format(3)))
        eq(s.org.codenameLabel('Viper'), (L('org.codename_shown')):format('Viper'))
        eq(s.org.Powers.BY_CODE.M4.label, L('org_powers.promote_demote'))
        eq(s.org.Powers.BY_CODE.K2.label, L('org_powers.assign_recommend'))
        for _, key in ipairs({ 'org_extras2.stash_label', 'org_extras2.demoted', 'org.is_adopt_or_revert',
            'org.salary_grade_reason', 'org.place_one', 'org.territory_one', 'org_extras2.staff_overturned_warning',
            'org_extras2.staff_overturned_strike_lifted', 'org_extras2.staff_overturned_warning_lifted' }) do
            falsy(L(key) == key, key .. ' is in the locale')
        end
    end)

    it('leaves none of the English the review found joined in code', function()
        local scans = {
            ['server/org/extras2.lua'] = { "' armory'", "'under '", "' to '", "'over '", "('%d h')", "'demoted'",
                "'strike' or L('org_extras2.written_warning')" },
            ['server/org/init.lua'] = { "' (codename)'", "'MaxOrganisations).'", "\"is 'adopt' or 'revert'\"",
                "'grade ' ..", "one = 'place'", "one = 'territory'", "defaultLabel = kind," },
            ['server/org/powers.lua'] = { "'Promote / demote'", "'Assign / recommend'" },
        }
        for path, needles in pairs(scans) do
            local body = source(path)
            for _, needle in ipairs(needles) do falsy(body:find(needle, 1, true), path .. ' still has ' .. needle) end
        end
    end)
end)
