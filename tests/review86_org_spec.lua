--- Review 86, organisation fixes: each confirmed finding, driven through the
--- code the game runs (the panel's ops through its net event, the org
--- functions, the phone's requests and the mysql store).
---
---   * F1 / C12-1: staff Unlock a member, Not boss and Bosses may edit on a
---     role are kept (false was turned into nil and nothing changed);
---   * E7-1: Revoke all on one boss's column denies every power they hold,
---     a role's included, and never turns a staff Deny into Inherit;
---   * C6-1 (staff panel) / F2: a refusal's own sentence reaches the panel,
---     not the code's generic one;
---   * C6-1 (reputation): the standing is the plain sum, whatever the order;
---   * E7-6: with Several organisations off, a member of a kept one is not
---     hired into the first;
---   * the lows: a request that runs out is told, ApprovalAbove 0 holds
---     every accept, an S3 rule a peer set, readable config warnings, and
---     names, role labels and application bodies the database takes.

local OW = require('tests.harness.org_world')
local L = CrimsonBoot.requireShared('locale').t

local STAFF = { staff = true, cid = 'ADMIN001', source = 6 }

local function world(on, extra, opts)
    opts = opts or {}
    local s, f = OW.world({ configure = function()
        Config.Integrations.Banking = 'none'
        Config.Cooldowns.create = { per = 10, burst = 100 }
        for _, key in ipairs(on or {}) do Config.Organisation[key] = true end
        for k, v in pairs(extra or {}) do Config.Organisation[k] = v end
        if opts.configure then opts.configure() end
    end })
    if opts.crew ~= false then OW.crew(s) end
    return s, f, s.org.current()
end

local function refOf(s, cid) return s.org.refFor('ADMIN001', cid) end

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

describe('Review 86 F1 / C12-1: staff unlock and un-boss from the panel', function()
    it('unlocks a member it locked', function()
        local s, _, org = world()
        local ref = refOf(s, 'RECRUIT1')
        eq(OW.ask(6, 'orgMemberOverride', { member = ref, locked = true }).ok, true)
        eq(org.members.RECRUIT1.locked, true)
        local r = OW.ask(6, 'orgMemberOverride', { member = ref, locked = false })
        eq(r.ok, true, tostring(r.message))
        eq(org.members.RECRUIT1.locked, false, 'unlocked')
    end)

    it('takes Locked and Boss off a role it set them on', function()
        local s, _, org = world()
        local role = org.roles[2]
        local base = { grade = 2, name = role.name, label = role.label, pay = role.pay }
        local function set(extra)
            local data = {}
            for k, v in pairs(base) do data[k] = v end
            for k, v in pairs(extra) do data[k] = v end
            return OW.ask(6, 'orgRoleSet', data)
        end
        eq(set({ isBoss = true, locked = true }).ok, true)
        eq(org.roles[2].is_boss, true)
        eq(org.roles[2].locked, true)
        local r = set({ isBoss = false, locked = false })
        eq(r.ok, true, tostring(r.message))
        eq(org.roles[2].is_boss, false, 'not boss')
        eq(org.roles[2].locked, false, 'bosses may edit')
    end)
end)

describe('Review 86 E7-1: Revoke all on one boss\'s column', function()
    it('denies every power they hold, keeps a staff Deny, and counts what stopped', function()
        local s, _, org = world()
        local E = s.org.Engine
        OW.allow(s, 3, 'C7')
        OW.allow(s, 3, 'M3')
        OW.allow(s, 3, 'M1')
        truthy(s.org.setCeiling(OW.STAFF, 'member', 'BOSS0001', 'C7', 'deny'))
        falsy(E.holds(org, 'BOSS0001', 'C7'))
        truthy(E.holds(org, 'BOSS0001', 'M3'))
        local reply = OW.ask(6, 'bossPermsRevokeAll', { subject = 'member', id = refOf(s, 'BOSS0001') })
        eq(reply.ok, true, tostring(reply.message))
        falsy(E.holds(org, 'BOSS0001', 'C7'), 'the staff Deny stays')
        falsy(E.holds(org, 'BOSS0001', 'M3'), 'the role power is revoked')
        falsy(E.holds(org, 'BOSS0001', 'M1'), 'every role power is revoked')
        eq(org.ceiling.member.BOSS0001.C7, 'deny')
        for _, p in ipairs(s.org.Powers.LIST) do
            falsy(E.holds(org, 'BOSS0001', p.code), 'still holds ' .. p.code)
        end
        eq(reply.message, (L('org_staff_ops.power_revoked')):format(2), 'M1 and M3 stopped')
        -- Another boss of the role still holds what the role gives.
        truthy(s.org.setRole(OW.STAFF, 'LIEUT001', 3))
        truthy(E.holds(org, 'LIEUT001', 'M3'), 'the role keeps its powers')
    end)

    it('still clears a role column to off', function()
        local s, _, org = world()
        OW.allow(s, 3, 'M3')
        local reply = OW.ask(6, 'bossPermsRevokeAll', { subject = 'role', id = 3 })
        eq(reply.ok, true)
        eq(org.ceiling.role[3].M3, nil)
        falsy(s.org.Engine.holds(org, 'BOSS0001', 'M3'))
    end)
end)

describe('Review 86 C6-1 / F2: a refusal\'s own words on the staff panel', function()
    it('internal contract: the boss away, the member gone', function()
        local s = world({ 'InternalContracts' })
        OW.allow(s, 3, 'K8')
        local id = OW.call('orgInternalRequest', 11, { member = s.org.refFor('BOSS0001', 'RECRUIT1'),
            reason = 'Sold us out', amount = 2000 }).data.id
        local saved = Env.players[11]
        Env.removePlayer(11)
        local r = OW.ask(6, 'orgInternalDecide', { id = id, approve = true })
        eq(r.ok, false)
        eq(r.message, L('org_extras3.the_boss_who_asked_is_not'))
        Env.players[11] = saved
        Env.byCitizen.BOSS0001 = 11
        truthy(s.org.fire(OW.STAFF, 'RECRUIT1', 'gone'))
        r = OW.ask(6, 'orgInternalDecide', { id = id, approve = true })
        eq(r.ok, false)
        eq(r.message, L('org_extras3.they_are_no_longer_a_member'))
    end)

    it('removing an organisation: the first, or one with members', function()
        local s = world({ 'SeveralOrganisations' })
        eq(OW.ask(6, 'orgCreate', { job = 'syndicate', label = 'The Syndicate' }).ok, true)
        eq(OW.ask(6, 'orgMemberHire', { org = 'syndicate', subject = 'CREATOR1', grade = 0 }).ok, true)
        local r = OW.ask(6, 'orgRemove', { id = 'hitman' })
        eq(r.message, L('org.the_first_organisation_config_lua_stays'))
        r = OW.ask(6, 'orgRemove', { id = 'syndicate' })
        eq(r.message, L('org.it_still_has_members_fire_them'))
    end)
end)

describe('Review 86 C6-1: reputation is the sum, whatever the order', function()
    local function standing(order)
        local s, _, org = world({ 'Reputation' }, { RepCompletion = 10, RepFailure = 15, RepHeat = 0 })
        for _, kind in ipairs(order) do
            if kind == 'f' then
                s.record.onFailed('LIEUT001', CH.FULFILMENT.ELIMINATION, nil, {})
            else
                s.record.onCompleted('LIEUT001', CH.FULFILMENT.ELIMINATION, nil, { earned = 100 })
            end
        end
        return s.org.Extras3.standing(org)
    end
    it('3 failures then 10 completions is 10 completions then 3 failures', function()
        local early = standing({ 'f', 'f', 'f', 'c', 'c', 'c', 'c', 'c', 'c', 'c', 'c', 'c', 'c' })
        local late = standing({ 'c', 'c', 'c', 'c', 'c', 'c', 'c', 'c', 'c', 'c', 'f', 'f', 'f' })
        eq(early.points, 55)
        eq(late.points, 55)
        eq(early.tier and early.tier.label, late.tier and late.tier.label)
    end)
    it('is never shown below 0', function()
        local only = standing({ 'f', 'f' })
        eq(only.points, 0)
        eq(only.earned, 0)
    end)
end)

describe('Review 86 E7-6: Several organisations off, a member of a kept one', function()
    it('is not hired into the first, nor adopted', function()
        local s = world({ 'SeveralOrganisations' })
        eq(OW.ask(6, 'orgCreate', { job = 'syndicate', label = 'The Syndicate' }).ok, true)
        eq(OW.ask(6, 'orgMemberHire', { org = 'syndicate', subject = 'CREATOR1', grade = 3 }).ok, true)
        Config.Organisation.SeveralOrganisations = false
        s.org.boot(true)
        eq(#s.org.all(), 1)
        local r = OW.ask(6, 'orgMemberHire', { subject = 'CREATOR1', grade = 0 })
        eq(r.ok, false)
        eq(r.err, 'org_other_org')
        falsy(s.org.current().members.CREATOR1)
        Config.Organisation.SeveralOrganisations = true
        s.org.boot(true)
        falsy(s.org.byId('hitman').members.CREATOR1, 'in one only')
        truthy(s.org.byId('syndicate').members.CREATOR1)
        -- And somebody of no organisation is still hired as before.
        Config.Organisation.SeveralOrganisations = false
        s.org.boot(true)
        eq(OW.ask(6, 'orgMemberHire', { subject = 'HITMAN01', grade = 0 }).ok, true)
    end)
end)

describe('Review 86 lows', function()
    it('C6-3: a request that runs out tells the boss and is logged', function()
        local s, _, org = world({ 'InternalContracts' }, { InternalExpireHours = 1 })
        OW.allow(s, 3, 'K8')
        local said = told(s)
        local asked = OW.call('orgInternalRequest', 11, { member = s.org.refFor('BOSS0001', 'RECRUIT1'),
            reason = 'Sold us out', amount = 2000 })
        eq(asked.ok, true)
        said.BOSS0001 = nil
        Env.advance(3700)
        s.org.extrasTick(os.time())
        eq(org.settings.internal[asked.data.id].state, 'expired')
        eq((said.BOSS0001 or {})[1], L('org_extras3.your_request_for_an_internal_contract_ran_out'))
        local found = false
        for _, row in ipairs(OW.audit('org_internal_decided')) do
            if tostring(row.detail or row.details or ''):find('expired', 1, true)
                or (type(row.detail) == 'table' and row.detail.state == 'expired') then found = true end
        end
        if not found then
            for _, row in ipairs(OW.audit('org_internal_decided')) do
                for _, v in pairs(row) do
                    if type(v) == 'string' and v:find('expired', 1, true) then found = true end
                    if type(v) == 'table' and v.state == 'expired' then found = true end
                end
            end
        end
        truthy(found, 'an org_internal_decided row says expired')
    end)

    it('C6-5: ApprovalAbove 0 holds an accept worth 0 in money', function()
        local s, f = world({ 'AcceptApproval' }, { ApprovalAbove = 0, ApprovalProbation = false })
        OW.allow(s, 3, 'K6')
        local c = OW.place(s, f.creator)
        local real = s.escrow.moneyValue
        s.escrow.moneyValue = function() return 0 end
        local ok, err = s.contracts.accept(s.identity.resolve(13), c.id)
        s.escrow.moneyValue = real
        eq(ok, false)
        eq(err, 'org_approval')
    end)

    it('C6-5: ApprovalAbove above 0 still lets a cheaper accept through', function()
        local s, f = world({ 'AcceptApproval' }, { ApprovalAbove = 25000, ApprovalProbation = false })
        OW.allow(s, 3, 'K6')
        local c = OW.place(s, f.creator)
        local ok, err = s.contracts.accept(s.identity.resolve(13), c.id)
        eq(ok, true, tostring(err))
    end)

    it('E7-2: an S3 rule a boss of the same rank set is theirs to lift', function()
        local s, _, org = world()
        truthy(s.org.setRole(OW.STAFF, 'LIEUT001', 3))
        OW.allow(s, 3, 'S3')
        OW.allow(s, 3, 'M1')
        local a, b = OW.boss(11, 'BOSS0001'), OW.boss(12, 'LIEUT001')
        truthy(s.org.officeRule(a, 'M1', true))
        local ok, err = s.org.officeRule(b, 'M1', false)
        eq(ok, false)
        eq(err, 'org_rank')
        eq(org.settings.officeBoss.M1, true, 'still on')
        ok, err = s.org.officeRule(b, 'M1', true)
        eq(ok, false, 'nor taken over')
        truthy(s.org.officeRule(a, 'M1', false), 'the setter lifts it')
        eq(org.settings.officeBoss.M1, nil)
        -- Once the setter is no longer of that rank, a peer may.
        truthy(s.org.officeRule(a, 'M1', true))
        truthy(s.org.setRole(OW.STAFF, 'BOSS0001', 2))
        truthy(s.org.officeRule(b, 'M1', false))
    end)

    it('F3: a config warning for Roles or Limits says the shipped value, not a table address', function()
        local s = world()
        local warn = {}
        Config.Organisation.Roles = { 'not a role line' }
        Config.Organisation.Limits = 'x'
        s.org.validate(warn)
        local all = table.concat(warn, ' | ')
        falsy(all:find('table: ', 1, true), all)
        truthy(all:find('0, recruit, Recruit, 0, no', 1, true), all)
        truthy(all:find(L('org.the_shipped_values'), 1, true), all)
    end)

    it('DB1: a long multi-byte name posts in the channel as whole characters', function()
        local s, _, org = world({ 'Channel' })
        local name = 'Александр Сергеевич Пушкин-Гончаров'
        eq(utf8.len(name), 35)
        truthy(#name > 64)
        org.members.RECRUIT1.name = name
        local written
        local real = s.storage.writeOrgRow
        s.storage.writeOrgRow = function(kind, row, ...)
            if kind == 'messages' then written = row end
            return real(kind, row, ...)
        end
        local r = OW.call('orgChannelPost', 13, { text = 'Evening.' })
        s.storage.writeOrgRow = real
        eq(r.ok, true)
        truthy(written, 'written')
        truthy(utf8.len(written.name), 'valid UTF-8: ' .. tostring(written.name))
        eq(written.name, name, 'kept whole: it is 35 characters')
    end)

    it('DB3: a role label from the config is cut by whole characters', function()
        local long = 'A' .. ('Б'):rep(40)
        local s, _, org = world(nil, nil, { crew = false, configure = function()
            Config.Organisation.Roles = { '0, recruit, Recruit, 0, no', '3, boss, ' .. long .. ', 0, yes' }
        end })
        local label = org.roles[3].label
        truthy(utf8.len(label), 'valid UTF-8')
        truthy(#label <= 64)
        eq(label, 'A' .. ('Б'):rep(31), 'a byte cut at 64 lands inside a letter')
    end)

    it('DB2: an application body past 64 KB is kept on mysql, and old tables are widened', function()
        local Exec = require('tests.harness.mysql_exec')
        Exec.install(Natives)
        Exec.run([[CREATE TABLE IF NOT EXISTS crimson_org_applications (
            id VARCHAR(48) PRIMARY KEY, org_id VARCHAR(32) NOT NULL, cid VARCHAR(32) NOT NULL, name VARCHAR(64),
            body TEXT, state VARCHAR(12) NOT NULL, decided_by VARCHAR(64), created_at INT NOT NULL,
            decided_at INT, INDEX idx_org_applications_org (org_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]])
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local m = require('crimson-hitman.server.storage.mysql')
        local ok, err = pcall(m.open)
        truthy(ok, tostring(err))
        local form = {}
        for i = 1, 20 do form[i] = { q = 'Q' .. i, a = ('é'):rep(2000) } end
        local body = '\2' .. json.encode({ form = form, text = 'hi' })
        truthy(#body > 65535)
        ok, err = pcall(m.writeOrgRow, 'applications', { id = 'app:hitman:1:1', org_id = 'hitman',
            cid = 'RECRUIT1', name = 'P13', body = body, state = 'open', created_at = 1 })
        truthy(ok, 'an 80 KB body: ' .. tostring(err))
        eq(m.readOrgRow('applications', 'app:hitman:1:1').body, body)
    end)
end)
