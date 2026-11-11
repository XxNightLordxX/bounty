--- Sweep 8, security: each finding the skeptic confirmed (SEC-1 to SEC-11,
--- and LB, the leaderboard), as the probe that showed it, now held.
---
---   SEC-1  a territory hold keeps its own placer's contract on their board;
---   SEC-2  own presets and the setup name who saved them only with IdentityAce;
---   SEC-3  an internal contract's reason is the boss's, with no marker;
---   SEC-4  an anonymous accept and its outcome are not in the activity log;
---   SEC-5  orgGet names the anonymous boss of an internal contract only with IdentityAce;
---   SEC-6  dead drops by an opaque handle; an anonymous one's operative only with IdentityAce;
---   SEC-7  a hidden spot (a territory) never answers orgUse; spot ids are not guessable;
---   SEC-8  a version part too big for an integer is no version, and never a script error;
---   SEC-9  Check the config carries none of the console's problem lines;
---   SEC-10 the activity log names a reassigned contract's previous member, never their cid;
---   SEC-11 presets show the Developer section's keys only to staff who may open it;
---   LB     an anonymous outcome moves no organisation count: stats, reputation, log.

local W = require('tests.harness.org_world')
local Natives = require('tests.harness.natives')
local Log = require('crimson-hitman.shared.log')

local STAFF = { staff = true, cid = 'ADMIN001', source = 6 }

local function world(on, extra)
    local s, f = W.world({ configure = function()
        Config.Integrations.Banking = 'none'
        Config.Cooldowns.create = { per = 10, burst = 100 }
        Config.TargetClasses.default.AllowAnonymousHitman = true
        Config.TargetClasses.default.AllowAnonymousPlacer = true
        for _, key in ipairs(on or {}) do Config.Organisation[key] = true end
        for k, v in pairs(extra or {}) do Config.Organisation[k] = v end
    end })
    W.crew(s)
    return s, f, s.org.current()
end

local function spot(s, kind, x, y, radius)
    W.at(6, x, y, 30.0)
    local ok, err, row = s.org.placeSpot(STAFF, { kind = kind, here = true, radius = radius })
    assert(ok, kind .. ': ' .. tostring(err) .. ' ' .. tostring(row and row.message))
    return row
end

local function handleFor(s, query)
    local found = s.app.handlers.searchTargets(s.identity.resolve(1), { query = query })
    return found and found[1] and found[1].handle
end

local function listed(src, id)
    local reply = W.call('list', src, {})
    for _, c in ipairs(reply and reply.data and reply.data.contracts or {}) do
        if c.id == id then return true end
    end
    return false
end

--- Every string anywhere in a value, joined.
local function strings(v, out)
    out = out or {}
    if type(v) == 'string' then out[#out + 1] = v
    elseif type(v) == 'table' then for k, x in pairs(v) do strings(k, out); strings(x, out) end end
    return out
end

local function text(v) return table.concat(strings(v), '|') end

local function internalPlaced(s)
    W.allow(s, 3, 'K8')
    local asked = W.call('orgInternalRequest', 11, { member = s.org.refFor('BOSS0001', 'RECRUIT1'),
        reason = 'Sold us out', amount = 2000, anonymous = true })
    eq(asked.ok, true, tostring(asked.err))
    local placed = W.ask(6, 'orgInternalDecide', { id = asked.data.id, approve = true })
    eq(placed.ok, true, tostring(placed.message))
    return placed.data.contract
end

describe('sweep 8 security: SEC-1 a territory hold and its own placer', function()
    it('keeps a territory-held contract on its placer\'s board, and off everybody else\'s', function()
        local s, _, org = world({ 'Territory', 'OrgContracts' })
        spot(s, 'territory', 0.0, 0.0, 300)
        W.at(11, 3000.0, 3000.0)
        W.at(12, 3100.0, 3000.0)
        W.at(1, 2000.0, 2000.0)
        W.at(2, 10.0, 10.0)
        W.at(13, 40.0, 10.0)
        local reply = W.call('create', 1, { target = handleFor(s, 'Reyes'), reason = 'x', anonymous = false,
            reward = { slots = { { baseline = { cash = 1000 } } } }, shown = {} })
        eq(reply.ok, true, tostring(reply.err))
        local id = reply.data.id
        truthy(org.settings.orgContracts[id], 'held for the organisation')
        truthy(listed(1, id), 'the placer still sees their own contract')
        falsy(listed(7, id), 'nobody else does while it is held')
        falsy(listed(12, id), 'nor a member it is not assigned to')
    end)
end)

describe('sweep 8 security: SEC-2 and SEC-11 presets and the setup', function()
    it('names who saved an own preset only with IdentityAce', function()
        world()
        eq(W.ask(6, 'setSetting', { key = 'Limits.DefaultDeadlineSeconds', value = 7200 }).ok, true)
        eq(W.ask(6, 'presetSaveOwn', { name = 'Mine' }).ok, true)
        local function mine(src)
            for _, p in ipairs(W.ask(src, 'presets', {}).data.presets) do if p.name == 'Mine' then return p end end
        end
        local row = mine(7)
        falsy(text(row):find('ADMIN001', 1, true), 'no citizen id for a reader: ' .. text(row))
        eq(row.by, 'a staff member')
        Env.aces[7]['crimson.identity'] = true
        truthy(text(mine(7)):find('ADMIN001', 1, true), 'with IdentityAce, who it was')
    end)

    it('names who saved the setup only with IdentityAce', function()
        world()
        eq(W.ask(6, 'setupApply', { values = {} }).ok, true)
        local view = W.ask(6, 'setup', {}).data
        eq(view.saved, true)
        eq(view.savedBy, 'a staff member', 'Write staff without IdentityAce')
        Env.aces[6]['crimson.identity'] = true
        eq(W.ask(6, 'setup', {}).data.savedBy, 'ADMIN001')
    end)

    it('shows the Developer section\'s keys in a preset only to staff who may open it', function()
        world()
        eq(W.ask(6, 'setSetting', { key = 'Admin.PanelPageSize', value = 37 }).ok, true)
        eq(W.ask(6, 'presetSaveOwn', { name = 'Mine' }).ok, true)
        eq(W.ask(6, 'setSetting', { key = 'Admin.PanelPageSize', value = 41 }).ok, true)
        local function mine(src)
            for _, p in ipairs(W.ask(src, 'presets', {}).data.presets) do if p.name == 'Mine' then return p end end
        end
        local row = mine(7)
        falsy(text(row):find('Admin.PanelPageSize', 1, true), 'hidden from a reader')
        eq(row.hidden, 1, 'counted as hidden')
        truthy(text(mine(6)):find('Admin.PanelPageSize', 1, true), 'the developer sees it')
    end)
end)

describe('sweep 8 security: SEC-3 an internal contract\'s reason', function()
    it('places it with the boss\'s reason as given, on the row and every card', function()
        local s = world({ 'InternalContracts' })
        local id = internalPlaced(s)
        local c = s.storage.readContract(id)
        eq(c.anon_creator, true)
        eq(c.reason, 'Sold us out')
        local card
        for _, row in ipairs(W.call('list', 3, {}).data.contracts or {}) do if row.id == id then card = row end end
        truthy(card, 'on the board')
        falsy(text(card):find('Internal', 1, true), 'no marker on the card')
    end)
end)

describe('sweep 8 security: SEC-4 and LB anonymous accepts and outcomes', function()
    local function anonymousDone()
        local s, _, org = world({ 'ActivityLog', 'Stats', 'Reputation' })
        W.allow(s, 3, 'M12')
        local c = W.place(s, s.identity.resolve(11), 'TARGET01')
        truthy(s.contracts.accept(s.identity.resolve(13), c.id, true))
        eq(s.storage.readHitman(c.id, 'RECRUIT1').anon, true, 'held anonymously')
        truthy(s.contracts.claimSlot(c.id, 'RECRUIT1', CH.FULFILMENT.KIDNAPPING))
        return s, org
    end

    it('SEC-4: leaves an anonymous accept and its outcome out of the activity log', function()
        anonymousDone()
        local rows = W.call('orgActivity', 11, {}).data.rows
        for _, r in ipairs(rows) do
            falsy(r.action == 'accepted', 'no anonymous accept logged, by ' .. tostring(r.by) .. ' at ' .. tostring(r.at))
        end
        for _, r in ipairs(rows) do falsy(r.action == 'completed', 'nor its outcome') end
    end)

    it('LB: moves no leaderboard count, nor the standing, for an anonymous outcome', function()
        local s, org = anonymousDone()
        local board = W.call('orgStats', 11, {}).data
        for _, r in ipairs(board.rows) do eq(r.completed, 0, 'no count moved: ' .. tostring(r.name)) end
        eq(org.settings.stats.RECRUIT1, nil)
        eq(math.floor(tonumber(org.settings.rep.c) or 0), 0, 'not in the standing')
        -- An anonymous walk-away is no failure on the organisation's books either.
        local c2 = assert(W.place(s, s.identity.resolve(1), 'READER01'))
        truthy(s.contracts.accept(s.identity.resolve(13), c2.id, true))
        Env.advance(90)
        truthy(s.contracts.abandon(s.identity.resolve(13), c2.id))
        eq(org.settings.stats.RECRUIT1, nil)
        eq(math.floor(tonumber(org.settings.rep.f) or 0), 0)
        -- A named accept is still counted and logged.
        local c3 = assert(W.place(s, s.identity.resolve(12), 'CREATOR1'))
        truthy(s.contracts.accept(s.identity.resolve(13), c3.id, false))
        truthy(s.contracts.claimSlot(c3.id, 'RECRUIT1', CH.FULFILMENT.KIDNAPPING))
        local kinds = {}
        for _, r in ipairs(W.call('orgActivity', 11, {}).data.rows) do kinds[r.action] = r end
        eq(kinds.accepted and kinds.accepted.by, 'P13')
        truthy(kinds.completed)
        eq(org.settings.stats.RECRUIT1.c, 1)
        eq(math.floor(tonumber(org.settings.rep.c) or 0), 1)
    end)
end)

describe('sweep 8 security: SEC-5 orgGet and an anonymous internal contract', function()
    it('names its boss only to staff with IdentityAce', function()
        local s = world({ 'InternalContracts' })
        internalPlaced(s)
        local row = W.ask(7, 'orgGet', {}).data.extras3.internal[1]
        eq(row.anonymous, true)
        eq(row.by, 'A boss', 'no name for a reader without IdentityAce')
        Env.aces[7]['crimson.identity'] = true
        eq(W.ask(7, 'orgGet', {}).data.extras3.internal[1].by, 'P11')
    end)
end)

describe('sweep 8 security: SEC-6 dead drops', function()
    it('gives each an opaque handle, and an anonymous one\'s operative only with IdentityAce', function()
        local s = world({ 'DeadDrops' })
        spot(s, 'deaddrop', 500.0, 500.0)
        W.allow(s, 3, 'P4')
        eq(W.call('orgPayoutMethod', 11, { method = 'deaddrop' }).ok, true)
        local c = W.place(s, s.identity.resolve(1), 'READER01')
        truthy(s.contracts.accept(s.identity.resolve(13), c.id, true))
        truthy(s.contracts.claimSlot(c.id, 'RECRUIT1', CH.FULFILMENT.KIDNAPPING))
        local view = W.ask(7, 'orgGet', {}).data
        local all = text(view)
        falsy(all:find('RECRUIT1', 1, true), 'no citizen id anywhere in orgGet')
        local row = view.extras3.deadDrops.rows[1]
        eq(row.key, nil)
        truthy(type(row.handle) == 'string' and not row.handle:find(c.id, 1, true), 'opaque')
        eq(row.name, 'A member', 'whose an anonymous drop is: not without IdentityAce')
        eq(row.contract, nil)
        Env.aces[7]['crimson.identity'] = true
        row = W.ask(7, 'orgGet', {}).data.extras3.deadDrops.rows[1]
        eq(row.name, 'P13')
        eq(row.contract, c.id)
        falsy(W.ask(6, 'orgDropSettle', { handle = c.id .. ':RECRUIT1', how = 'release' }).ok, 'never the raw key')
        eq(W.ask(6, 'orgDropSettle', { handle = row.handle, how = 'release' }).ok, true)
    end)
end)

describe('sweep 8 security: SEC-7 hidden spots', function()
    it('never answers orgUse at a territory, from inside it', function()
        local s = world({ 'Territory', 'OrgContracts' })
        spot(s, 'office', 100.0, 100.0)
        local terr = spot(s, 'territory', 0.0, 0.0, 300)
        local said = 0
        local real = s.notify.toCitizen
        s.notify.toCitizen = function(...) said = said + 1; return real(...) end
        W.at(13, 200.0, 50.0)
        s.org.useSpot(13, terr.id)
        _G.source = 13
        Env.events['crimson-hitman:orgUse'](terr.id)
        _G.source = nil
        s.notify.toCitizen = real
        eq(said, 0, 'nothing said from inside a territory')
    end)

    it('mints spot ids with no time or sequence in them', function()
        local s = world({ 'Territory', 'OrgContracts' })
        local office = spot(s, 'office', 100.0, 100.0)
        local terr = spot(s, 'territory', 0.0, 0.0, 300)
        local _ = s
        for _, id in ipairs({ tostring(office.id), tostring(terr.id) }) do
            falsy(id:find(tostring(os.time()), 1, true), 'no time in the id: ' .. id)
            falsy(id:match('%d%d%d%d%d%d%d%d+_%d+$'), 'no time and sequence: ' .. id)
        end
    end)
end)

describe('sweep 8 security: SEC-8 the version check and a huge number', function()
    it('reads a part too big for an integer as no version, and never raises in the callback', function()
        newStack()
        local VersionCheck = require('server.versioncheck')
        eq(VersionCheck.parse('99999999999999999999.1.0'), nil)
        local v = VersionCheck.parse('1.2.3')
        eq(math.type(v[1]), 'integer')
        Config.VersionCheck.Enabled, Config.VersionCheck.Url = true, 'https://example.invalid/v.txt'
        local cb
        local realHttp = _G.PerformHttpRequest
        _G.PerformHttpRequest = function(_, fn) cb = fn end
        VersionCheck.reset()
        eq(VersionCheck.run(), 'asked')
        _G.PerformHttpRequest = realHttp
        truthy(cb, 'asked')
        local ok, err = pcall(cb, 200, '99999999999999999999.1.0')
        truthy(ok, 'no script error: ' .. tostring(err))
        -- And an answer the format itself could not take still raises nothing.
        local realParse = VersionCheck.parse
        VersionCheck.parse = function() return { 1.5, 0, 0 } end
        ok, err = pcall(cb, 200, 'x')
        VersionCheck.parse = realParse
        truthy(ok, 'anything else is a debug line at most: ' .. tostring(err))
        VersionCheck.reset()
        resetConfig()
    end)
end)

describe('sweep 8 security: SEC-9 Check the config', function()
    it('carries none of the console\'s problem lines, which stay the Developer console\'s, scrubbed', function()
        world()
        Natives.convars['crimson_hitman_webhook'] = 'https://discord.com/api/webhooks/123456/SECRETTOKENabc'
        Log.problem('some_bridge raised: posting to https://discord.com/api/webhooks/123456/SECRETTOKENabc '
            .. 'failed for CREATOR1 (license:abcdef123)')
        local lines = table.concat(W.ask(7, 'diag', { config = true }).data.lines, '\n')
        falsy(lines:find('SECRETTOKEN', 1, true), 'no secret')
        falsy(lines:find('CREATOR1', 1, true), 'no citizen id')
        falsy(lines:find('some_bridge raised', 1, true), 'not the line at all')
        eq(W.ask(7, 'console', {}).ok, false, 'the console is the developer\'s')
        local dev = text(W.ask(6, 'console', {}).data)
        truthy(dev:find('some_bridge raised', 1, true), 'the console still has it')
        falsy(dev:find('SECRETTOKEN', 1, true), 'scrubbed there')
        Natives.convars['crimson_hitman_webhook'] = nil
    end)
end)

describe('sweep 8 security: SEC-10 a reassigned contract in the activity log', function()
    it('names the previous member, never their citizen id', function()
        local s, f = world({ 'ActivityLog', 'OrgContracts' })
        for _, code in ipairs({ 'K4', 'K5', 'M12' }) do W.allow(s, 3, code) end
        local c = W.place(s, s.identity.resolve(1), 'TARGET01')
        s.org.receiveContract(c.id, 'CREATOR1')
        eq(W.call('orgAssign', 11, { id = c.id, member = s.org.refFor('BOSS0001', 'LIEUT001') }).ok, true)
        eq(W.call('orgAssign', 11, { id = c.id, member = s.org.refFor('BOSS0001', 'RECRUIT1') }).ok, true)
        local reply = W.call('orgActivity', 11, {}).data
        falsy(text(reply):find('LIEUT001', 1, true), 'no citizen id: ' .. text(reply))
        local row
        for _, r in ipairs(reply.rows) do if r.action == 'org_contract_reassigned' then row = r end end
        truthy(row)
        eq(row.from, 'P12', 'by name')
        falsy(text(W.ask(7, 'orgGet', {}).data.extras3.activity):find('LIEUT001', 1, true), 'nor to a reader')
        local _ = f
    end)
end)
