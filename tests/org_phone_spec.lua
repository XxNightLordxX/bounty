--- The phone's Organisation tab, from the server's side (ui/app.js draws
--- what these answer; tests/ui/run.js drives the page itself):
---
---   * the board reply says whether the tab is shown, and as what: nobody
---     while the organisation is off; a member, an applicant, an invitee or
---     a player standing at a sign-up spot while it is on; nobody else;
---   * orgMine gives a member what the tab draws: the role, the powers held
---     after Boss permissions (server-driven), which of them need the
---     office and whether the server sees them in it, the bounds of the
---     powers held, the cut and the notice; a non-member only what applies;
---   * the client bridge forwards every request the tab asks for;
---   * every request takes hostile payloads: answered, worded, nothing moved;
---   * the broker's and informant's places set from Locations
---     (Config.Roleplay.NpcPlaces, off as shipped).

local W = require('tests.harness.org_world')

local function world(opts)
    local s, f = W.world(opts)
    W.crew(s)
    return s, f, s.org.current()
end

local function tabOf(src)
    local reply = W.call('list', src, {})
    truthy(reply and reply.ok, 'the board answered: ' .. tostring(reply and reply.err))
    return reply.data.orgTab
end

describe('whether the tab is shown', function()
    it('is shown to nobody while the organisation is off', function()
        local s = W.world({ off = true })
        local _ = s
        for _, src in ipairs({ 1, 3, 11, 13 }) do eq(tabOf(src), nil, 'player ' .. src) end
    end)

    it('is shown to members, applicants, invitees and at a sign-up spot only', function()
        local s = world()
        eq(tabOf(11), 'member')
        eq(tabOf(13), 'member')
        eq(tabOf(3), nil, 'a player outside it')
        -- Standing at a sign-up spot: they may apply from there.
        W.at(6, 500.0, 500.0)
        truthy(s.org.placeSpot({ staff = true, cid = 'ADMIN001', source = 6 }, { kind = 'signup', here = true }))
        W.at(3, 501.0, 500.0)
        eq(tabOf(3), 'signup')
        local applied = W.call('orgApply', 3, { text = 'I want in' })
        eq(applied.ok, true, tostring(applied.err))
        W.at(3, 2000.0, 2000.0)
        eq(tabOf(3), 'applicant', 'an open application, wherever they stand')
        -- Invited by a boss holding Hire.
        W.allow(s, 3, 'M2')
        W.office(s)
        W.at(11, 100.0, 100.0)
        W.at(2, 101.0, 100.0)
        eq(tabOf(2), nil)
        eq(W.call('orgHire', 11, { target = 2 }).ok, true)
        eq(tabOf(2), 'invitee')
    end)
end)

describe('what the tab is told', function()
    it('gives a member only the powers they hold, the office rule and the bounds', function()
        local s, _, org = world()
        local plain = W.call('orgMine', 13, {}).data
        eq(plain.member, true)
        eq(plain.role, 'Recruit')
        eq(next(plain.powers), nil, 'a recruit holds nothing')
        eq(plain.powerNames, nil, 'and is told no power names')
        W.allow(s, 3, 'M1')
        W.allow(s, 3, 'C7')
        W.allow(s, 3, 'R4')
        W.office(s)
        W.at(11, 900.0, 900.0)
        local boss = W.call('orgMine', 11, {}).data
        eq(boss.powers.M1, true)
        eq(boss.powers.C7, true)
        eq(boss.powers.M2, nil, 'not given, not shown')
        eq(boss.officeOnly.C7, true, 'withdrawals need the office as shipped')
        eq(boss.officeOnly.M1, nil)
        eq(boss.inOffice, false, 'away from it, by the server\'s own look')
        eq(boss.hasOffice, true)
        eq(boss.bounds.WithdrawMax, 50000)
        eq(boss.bounds.PayMax, nil, 'only the bounds of powers held')
        truthy(boss.powerNames and boss.powerNames.M2 and boss.powerNames.M2.label, 'names to grey out')
        W.at(11, 100.0, 100.0)
        eq(W.call('orgMine', 11, {}).data.inOffice, true)
        truthy(s.org.notice(W.STAFF, 'Meet at nine', false))
        eq(W.call('orgMine', 13, {}).data.notice, 'Meet at nine')
        eq(W.call('orgMine', 13, {}).data.terms.orgPercent, 0)
        local _ = org
    end)

    it('tells a non-member only whether and where they may apply', function()
        local s = world()
        local mine = W.call('orgMine', 3, {}).data
        eq(mine.member, false)
        eq(mine.signupOnly, true)
        eq(mine.atSignup, nil)
        eq(mine.powers, nil)
        eq(mine.notice, nil, 'no member-only words')
        Config.Organisation.ApplyAtSignupOnly = false
        mine = W.call('orgMine', 3, {}).data
        eq(mine.signupOnly, nil)
        local _ = s
    end)

    it('words every refusal the tab can be sent', function()
        local Org = require('server.org.init')
        for _, code in pairs(Org.ERR) do
            truthy(Org.message(code) ~= 'Not done.', code .. ' has words')
        end
        local app = io.open('crimson-hitman/ui/app.js'):read('a')
        local errors = app:match('var ERRORS%s*=%s*(%b{})') or ''
        for _, code in pairs(Org.ERR) do
            if code:sub(1, 4) == 'org_' then
                truthy(errors:find(code .. ':', 1, true), 'the page words ' .. code)
            end
        end
    end)
end)

describe('the client bridge', function()
    it('forwards every request the organisation answers', function()
        local client = io.open('crimson-hitman/client/main.lua'):read('a')
        local list = client:match('local UI_EVENTS = (%b{})') or ''
        for _, entry in ipairs(require('server.org.boss_ops').LIST) do
            truthy(list:find("'" .. entry.name .. "'", 1, true), entry.name .. ' forwarded')
        end
    end)
end)

describe('hostile payloads to every request', function()
    local PAYLOADS = {
        'text', 42, true,
        { member = { nested = true }, grade = 'boss', amount = -1e309, reason = string.rep('x', 5000) },
        { member = 'BOSS0001', grade = 1e9, amount = 0 / 0, text = '<script>', label = '<b>' },
        { kind = 'office', id = string.rep('a', 400), x = 1e12, y = -1e12, z = 'up', here = 'yes' },
        { power = 'ZZZZZ', state = 'grant', on = 'yes', rules = { maxReward = 'all', rule = 'dead' } },
        { layout = { labels = { members = string.rep('L', 300) }, hidden = { members = { 'x' } } } },
        { codename = string.rep('n', 300) }, { accept = 'yes', id = {} },
    }

    it('answers each from a non-member, worded, with nothing moved', function()
        local s, _, org = world()
        local before = W.wealth(3)
        local members = 0
        for _ in pairs(org.members) do members = members + 1 end
        for _, entry in ipairs(require('server.org.boss_ops').LIST) do
            for _, payload in ipairs(PAYLOADS) do
                s.ratelimit.resetAll()
                if s.app.resetFloodCounters then s.app.resetFloodCounters() end
                local reply = W.call(entry.name, 3, payload)
                truthy(reply, entry.name .. ' answered')
                if entry.name ~= 'orgMine' and entry.name ~= 'orgSpots' then
                    falsy(reply.ok, entry.name .. ' refused a non-member')
                    truthy(reply.data and reply.data.message, entry.name .. ' worded: ' .. tostring(reply.err))
                end
            end
        end
        eq(W.wealth(3), before, 'no money moved')
        local after = 0
        for _ in pairs(org.members) do after = after + 1 end
        eq(after, members, 'nobody hired or fired')
        local _ = s
    end)

    it('answers each from a boss holding every power, never raising, never moving money on junk', function()
        local s, _, org = world({ configure = function()
            Config.Organisation.Funds = 'internal'
            Config.Organisation.Codenames = true
            Config.Organisation.Payroll = true
        end })
        for _, p in ipairs(require('server.org.powers').LIST) do W.allow(s, 3, p.code) end
        W.office(s)
        W.at(11, 100.0, 100.0)
        truthy(s.org.staffDeposit(W.STAFF, 1000, 'seed', 'seed'))
        local funds, wealth = s.org.Funds.balance(org), W.wealth(11)
        for _, entry in ipairs(require('server.org.boss_ops').LIST) do
            for _, payload in ipairs(PAYLOADS) do
                s.ratelimit.resetAll()
                if s.app.resetFloodCounters then s.app.resetFloodCounters() end
                local reply = W.call(entry.name, 11, payload)
                truthy(reply, entry.name .. ' answered')
                if not reply.ok then
                    truthy(reply.data and reply.data.message, entry.name .. ' worded: ' .. tostring(reply.err))
                end
            end
        end
        eq(s.org.Funds.balance(org), funds, 'the funds unchanged')
        eq(W.wealth(11), wealth, 'the boss\'s money unchanged')
        eq(org.label, 'Crimson Contractors', 'no markup taken as a label')
    end)
end)

describe('the broker and informant placed from Locations (Config.Roleplay.NpcPlaces)', function()
    local function stack(on)
        local s = W.world({ configure = function()
            Config.Roleplay.Rumours.Enabled = true
            Config.Roleplay.InformantNpc.Enabled = true
            if on then Config.Roleplay.NpcPlaces.Enabled = true end
        end })
        return s
    end

    local function kind(view, id)
        for _, k in ipairs(view.kinds) do if k.id == id then return k end end
    end

    it('ships off, and off every write says so and the config list is used', function()
        resetConfig()
        eq(Config.Roleplay.NpcPlaces.Enabled, false)
        local s = stack(false)
        local before = s.rpPlaces.current('broker')
        local reply = W.ask(6, 'placeSet', { kind = 'broker', here = true })
        falsy(reply.ok)
        eq(reply.err, 'feature_off')
        truthy(reply.message and reply.message:find('NpcPlaces', 1, true), 'names its switch')
        local view = W.ask(6, 'placeList', {})
        eq(view.ok, true)
        truthy(kind(view.data, 'broker').off, 'shown off')
        eq(kind(view.data, 'broker').using, 'config')
        truthy(#kind(view.data, 'broker').defaults >= 1, 'the config list shown as the defaults')
        eq(s.rpPlaces.current('broker').x, before.x)
    end)

    it('places the broker where staff stand, read by the server, and resets to config', function()
        local s = stack(true)
        local default = s.rpPlaces.current('broker')
        W.at(6, 1234.5, -987.6, 44.0)
        local reply = W.ask(6, 'placeSet', { kind = 'broker', here = true, label = 'Pier', x = 1, y = 2, z = 3 })
        eq(reply.ok, true, tostring(reply.message))
        local now = s.rpPlaces.current('broker')
        eq(now.x, 1234.5, 'where the server sees staff, never the typed figures')
        eq(now.y, -987.6)
        local view = W.ask(6, 'placeList', {}).data
        eq(kind(view, 'broker').using, 'panel')
        eq(#kind(view, 'broker').rows, 1)
        eq(kind(view, 'broker').rows[1].label, 'Pier')
        eq(kind(view, 'informant').using, 'config', 'the informant untouched')
        -- Stored with every other spot staff set: the one registry's rows.
        local rows = s.storage.readRpRows('map_place')
        eq(#rows, 1)
        -- Off again: the config list, the place kept.
        Config.Roleplay.NpcPlaces.Enabled = false
        eq(s.rpPlaces.current('broker').x, default.x)
        Config.Roleplay.NpcPlaces.Enabled = true
        eq(s.rpPlaces.current('broker').x, 1234.5)
        reply = W.ask(6, 'placeReset', { kind = 'broker' })
        eq(reply.ok, true, tostring(reply.message))
        eq(s.rpPlaces.current('broker').x, default.x, 'the config list again')
        eq(W.ask(6, 'placeReset', { kind = 'broker' }).ok, false, 'nothing left to reset')
    end)

    it('removes one, refuses junk and readers, and keeps them across a reload', function()
        local s = stack(true)
        W.at(6, 10.0, 20.0, 30.0)
        local id = W.ask(6, 'placeSet', { kind = 'informant', here = true }).data.id
        truthy(id, 'saved')
        eq(W.ask(7, 'placeSet', { kind = 'informant', here = true }).ok, false, 'a reader cannot write')
        for _, junk in ipairs({ { kind = 'mayor', here = true }, { kind = 'broker', x = 'a', y = 1, z = 1 },
            { kind = 'broker', x = 1e9, y = 1, z = 1 }, { kind = 'broker', x = 1, y = 1, z = 1, label = '<b>' },
            { kind = 'broker', x = 1, y = 1, z = 1, enabled = 'yes' }, { kind = 'broker', id = 'nope', x = 1, y = 1, z = 1 },
            { kind = 'broker', x = 1, y = 1, z = 1, heading = 0 / 0 } }) do
            local reply = W.ask(6, 'placeSet', junk)
            falsy(reply.ok, 'refused')
            truthy(reply.message, 'worded')
        end
        -- Typed figures work too.
        eq(W.ask(6, 'placeSet', { kind = 'broker', x = 100, y = 200, z = 30, heading = 90 }).ok, true)
        -- A reload reads them back from the store.
        s.rpPlaces.init({ settings = s.settings, storage = s.storage, audit = s.audit })
        eq(s.rpPlaces.current('informant').x, 10.0)
        eq(s.rpPlaces.current('broker').x, 100.0)
        eq(W.ask(6, 'placeRemove', { id = id }).ok, true)
        eq(W.ask(6, 'placeRemove', { id = id }).ok, false, 'gone')
        eq(kind(W.ask(6, 'placeList', {}).data, 'informant').using, 'config')
        s.audit.flush()
        truthy(#s.storage.auditByAction('rp_place_set', 5) >= 1, 'on the record')
    end)
end)
