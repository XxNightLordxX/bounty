--- The organisation's places, notices, applications and settings
--- (Org.placeSpot and the rest, client/org.lua): staff's Use my position
--- reads the server's own position and never a client's; a boss moves the
--- office only near staff's point, places spots only where they stand,
--- inside the counts, the cooldown and outside the safe zones; each player
--- is sent only the spots they may use, and their game draws nothing, and
--- runs nothing, without one.

local W = require('tests.harness.org_world')

local BOSS = W.boss(11, 'BOSS0001')

local function world(opts)
    local s, f = W.world(opts)
    W.crew(s)
    return s, f, s.org.current()
end

local function spotsSentTo(src)
    local last
    for _, e in ipairs(Env.clientEvents) do
        if e.name == 'crimson-hitman:orgSpots' and e.target == src then last = e.args[1] end
    end
    return last
end

describe('Use my position, and staff\'s spots', function()
    it('reads where the staff member stands on the server, never what the page sends', function()
        local s, _, org = world()
        W.at(6, 215.5, -810.25, 30.75)
        Env.players[6]._heading = 90.0
        local reply = W.ask(6, 'orgMyPosition', {})
        eq(reply.ok, true)
        eq(reply.data.x, 215.5)
        eq(reply.data.heading, 90.0)
        reply = W.ask(6, 'orgLocationSet', { kind = 'office', here = true, x = 1, y = 2, z = 3, label = 'Office' })
        eq(reply.ok, true, tostring(reply.message))
        local office
        for _, l in pairs(org.locations) do if l.kind == 'office' then office = l end end
        eq(office.x, 2155, 'decimetres, from the server\'s position, not the page\'s 1')
        eq(office.heading, 90)
        truthy(office.anchor, 'staff\'s point, which a boss may move it near')
        reply = W.ask(6, 'orgLocationSet', { kind = 'meeting', x = 10, y = 20, z = 30, radius = 3, blip = true })
        eq(reply.ok, true)
        reply = W.ask(6, 'orgLocationSet', { kind = 'signup', x = 1e9, y = 20, z = 30 })
        falsy(reply.ok, 'off the map')
        reply = W.ask(6, 'orgLocationSet', { kind = 'vault', x = 1, y = 2, z = 3 })
        falsy(reply.ok, 'no such kind')
        reply = W.ask(6, 'orgLocationRemove', { id = office.id })
        eq(reply.ok, true)
        eq(org.locations[office.id], nil)
        local _ = s
    end)

    it('keeps one office, moved rather than doubled', function()
        local _, _, org = world()
        local s = W
        s.at(6, 10, 10)
        eq(W.ask(6, 'orgLocationSet', { kind = 'office', here = true }).ok, true)
        s.at(6, 50, 50)
        eq(W.ask(6, 'orgLocationSet', { kind = 'office', here = true }).ok, true)
        local n = 0
        for _, l in pairs(org.locations) do if l.kind == 'office' then n = n + 1 end end
        eq(n, 1)
    end)
end)

describe('a boss\'s spots', function()
    it('moves the office only near staff\'s point, from where the boss stands, once per cooldown', function()
        local s, _, org = world()
        W.allow(s, 3, 'L1')
        W.at(11, 120.0, 100.0)
        local ok, err = s.org.placeSpot(BOSS, { kind = 'office' })
        eq(err, 'org_locked', 'no office staff set yet')
        W.office(s, 100.0, 100.0)
        W.at(11, 400.0, 100.0)
        ok, err = s.org.placeSpot(BOSS, { kind = 'office' })
        eq(err, 'org_bounds', 'past OfficeMoveMetres')
        W.at(11, 180.0, 100.0)
        truthy(s.org.placeSpot(BOSS, { kind = 'office', x = 5000, y = 5000, z = 1 }), 'where they stand')
        local office
        for _, l in pairs(org.locations) do if l.kind == 'office' then office = l end end
        eq(office.x, 1800, 'their position, not the figures sent')
        W.at(11, 170.0, 100.0)
        ok, err = s.org.placeSpot(BOSS, { kind = 'office' })
        eq(err, 'org_cooldown')
        falsy(ok)
    end)

    it('places sign-up and meeting spots inside the counts, never in a safe zone', function()
        local s, _, org = world()
        W.allow(s, 3, 'L2')
        W.allow(s, 3, 'L3')
        truthy(s.org.setLimits(W.STAFF, { MaxSignupSpots = 1, LocationCooldownMinutes = 0 }))
        Config.Improvements.TipSafeZones.Zones = { '300, -590, 80, Pillbox' }
        W.at(11, 310.0, -580.0)
        eq(select(2, s.org.placeSpot(BOSS, { kind = 'meeting' })), 'org_rule', 'inside Pillbox')
        W.at(11, 1000.0, 1000.0)
        truthy(s.org.placeSpot(BOSS, { kind = 'signup', label = 'Board' }))
        eq(select(2, s.org.placeSpot(BOSS, { kind = 'signup' })), 'org_limit', 'MaxSignupSpots')
        truthy(s.org.placeSpot(BOSS, { kind = 'meeting' }))
        eq(select(2, s.org.placeSpot(BOSS, { kind = 'npc' })), 'org_no_power', 'NPCs are staff\'s')
        local meeting
        for _, l in pairs(org.locations) do if l.kind == 'meeting' then meeting = l end end
        truthy(s.org.removeSpot(BOSS, meeting.id))
        W.at(6, 1, 1)
        truthy(s.org.placeSpot({ staff = true, cid = 'ADMIN001', source = 6 }, { kind = 'npc', here = true }))
        local npc
        for _, l in pairs(org.locations) do if l.kind == 'npc' then npc = l end end
        eq(select(2, s.org.removeSpot(BOSS, npc.id)), 'org_no_power')
        local reply = W.call('orgPlaceHere', 11, { kind = 'npc' })
        eq(reply.err, 'invalid_input', 'the phone places only the three')
    end)

    it('needs L1, L2 or L3 for each, and nobody without them places anything', function()
        local s = world()
        W.at(11, 1000.0, 1000.0)
        for _, kind in ipairs({ 'office', 'signup', 'meeting' }) do
            eq(select(2, s.org.placeSpot(BOSS, { kind = kind })), 'org_no_power', kind)
        end
    end)
end)

describe('the spots each player is sent', function()
    it('sends sign-up spots to everybody and the rest to members only, and nothing while off', function()
        local s, _, org = world()
        W.at(6, 1, 1)
        local staff = { staff = true, cid = 'ADMIN001', source = 6 }
        truthy(s.org.placeSpot(staff, { kind = 'signup', here = true }))
        truthy(s.org.placeSpot(staff, { kind = 'meeting', x = 5, y = 5, z = 5 }))
        Env.clientEvents = {}
        s.org.pushSpotsAll()
        eq(#spotsSentTo(11).spots, 2, 'a member: both')
        eq(#spotsSentTo(3).spots, 1, 'anybody else: the sign-up spot')
        eq(spotsSentTo(3).spots[1].kind, 'signup')
        eq(#s.org.spotsFor('HITMAN01'), 1)
        Config.Organisation.Enabled = false
        eq(#s.org.spotsFor('BOSS0001'), 0, 'off: nothing')
        s.org.boot(true)
        eq(#spotsSentTo(11).spots, 0, 'turned off live: every game told to draw nothing')
        local _ = org
    end)

    it('answers a spot used only by somebody the server sees there', function()
        local s, _, org = world()
        W.at(6, 50, 50)
        truthy(s.org.placeSpot({ staff = true, cid = 'ADMIN001', source = 6 }, { kind = 'signup', here = true }))
        local id
        for _, l in pairs(org.locations) do id = l.id end
        Natives.calls.notifications = {}
        W.at(3, 500, 500)
        _G.source = 3
        Env.events['crimson-hitman:orgUse'](id)
        _G.source = nil
        eq(#Natives.calls.notifications, 0, 'too far: nothing')
        W.at(3, 50, 51)
        _G.source = 3
        Env.events['crimson-hitman:orgUse'](id)
        Env.events['crimson-hitman:orgUse']({ 'not', 'an', 'id' })
        Env.events['crimson-hitman:orgUse'](('x'):rep(500))
        _G.source = nil
        eq(#Natives.calls.notifications, 1, 'there: told how to apply')
    end)
end)

describe('applications, notices and settings', function()
    it('takes an application only at a sign-up spot, once, and hires on acceptance', function()
        local s, _, org = world()
        W.allow(s, 3, 'N2')
        W.at(6, 50, 50)
        truthy(s.org.placeSpot({ staff = true, cid = 'ADMIN001', source = 6 }, { kind = 'signup', here = true }))
        W.at(3, 500, 500)
        eq(W.call('orgApply', 3, { text = 'Hire me' }).err, 'org_rule', 'away from the board')
        W.at(3, 50, 50)
        eq(W.call('orgApply', 3, { text = 'Hire me' }).ok, true)
        eq(W.call('orgApply', 3, { text = 'Again' }).err, 'org_already')
        eq(W.call('orgApply', 11, {}).err, 'org_already', 'a member does not apply')
        local list = W.call('orgApplications', 11, {})
        eq(#list.data.rows, 1)
        local reply = W.call('orgDecide', 11, { id = list.data.rows[1].id, accept = true })
        eq(reply.ok, true, tostring(reply.data and reply.data.message))
        eq(org.members.HITMAN01.grade, 0, 'hired into the lowest role')
        eq(W.QbxJobs.groups.HITMAN01.hitman, 0)
        eq(W.call('orgMine', 3, {}).data.member, true)
    end)

    it('posts the notice within its length, with no links, and tells members online', function()
        local s, _, org = world()
        W.allow(s, 3, 'N1')
        truthy(s.org.setLimits(W.STAFF, { NoticeMaxLength = 20 }))
        eq(W.call('orgNotice', 11, { text = ('x'):rep(21) }).err, 'org_bounds')
        eq(W.call('orgNotice', 11, { text = 'join discord.gg/abc' }).err, 'org_bounds')
        eq(W.call('orgNotice', 11, { text = '<b>hi</b>' }).err, 'org_bounds')
        Natives.calls.notifications = {}
        eq(W.call('orgNotice', 11, { text = 'Meet at nine', broadcast = true }).ok, true)
        truthy(#Natives.calls.notifications >= 3, 'every member online told')
        eq(W.call('orgMine', 13, {}).data.notice, 'Meet at nine')
        eq(W.call('orgNotice', 11, { text = false }).ok, true, 'cleared')
        eq(org.settings.notice, nil)
    end)

    it('renames the label (never the job) once per cooldown, and lays out the menu', function()
        local s, _, org = world()
        W.allow(s, 3, 'S1')
        W.allow(s, 3, 'S2')
        eq(W.call('orgRename', 11, { label = 'The Firm' }).ok, true)
        eq(org.job, 'hitman', 'the job name stays')
        eq(W.call('orgRename', 11, { label = 'Again' }).err, 'org_cooldown')
        eq(W.call('orgLayout', 11, { layout = { labels = { members = 'Crew' }, hidden = { funds = { 0 } } } }).ok, true)
        eq(org.settings.layout.labels.members, 'Crew')
        eq(W.call('orgLayout', 11, { layout = { labels = { vault = 'x' } } }).err, 'invalid_input')
        local _ = s
    end)

    it('pins a contract to a member as a boss pick, and never to its own parties', function()
        local s, f, org = world()
        W.allow(s, 3, 'K2')
        W.allow(s, 3, 'M1')
        local c = W.place(s, f.creator)
        local roster = W.call('orgMembers', 11, {}).data.rows
        local ref
        for _, m in ipairs(roster) do if m.grade == 0 then ref = m.ref end end
        eq(W.call('orgPick', 11, { id = c.id, member = ref }).ok, true)
        eq(org.settings.picks[c.id], 'RECRUIT1')
        eq(W.call('orgPick', 11, { id = c.id, member = 'm999_1' }).err, 'org_not_found', 'a handle not given to them')
        eq(W.call('orgPick', 12, { id = c.id, member = ref }).err, 'org_not_found', 'a handle is good for its viewer only')
        eq(W.call('orgPick', 12, { id = c.id }).err, 'org_no_power', 'and K2 is the boss\'s')
    end)

    it('shows a member\'s roster only with M1, by handles good for that viewer only', function()
        local s = world()
        eq(W.call('orgMembers', 11, {}).err, 'org_no_power')
        W.allow(s, 3, 'M1')
        local rows = W.call('orgMembers', 11, {}).data.rows
        eq(#rows, 3)
        for _, r in ipairs(rows) do
            eq(r.cid, nil, 'no citizen id')
            truthy(r.ref)
        end
        eq(W.call('orgMine', 3, {}).data.member, false, 'a non-member is told so')
    end)
end)

describe('client/org.lua', function()
    local function client()
        local t = { handlers = {}, threads = {}, zones = {}, entities = {}, peds = {}, made = 0, blips = 0,
            me = { x = 0.0, y = 0.0, z = 0.0 }, target = 'started', sent = {} }
        local function vec(x, y, z)
            return setmetatable({ x = x, y = y, z = z }, {
                __sub = function(a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end,
                __len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end,
            })
        end
        local ox = {
            addSphereZone = function(_, spec) t.zones[#t.zones + 1] = spec return #t.zones end,
            removeZone = function(_, id) t.zones[id] = false end,
            addLocalEntity = function(_, ped, opts) t.entities[ped] = opts end,
            removeLocalEntity = function(_, ped) t.entities[ped] = nil end,
        }
        local env = setmetatable({
            exports = setmetatable({}, { __index = function(_, k) if k == 'ox_target' then return ox end end }),
            GetResourceState = function(name) return name == 'ox_target' and t.target or 'missing' end,
            joaat = function() return 1234 end, IsModelInCdimage = function() return 1 end,
            RequestModel = function() end, HasModelLoaded = function() return true end,
            SetModelAsNoLongerNeeded = function() end,
            CreatePed = function() t.made = t.made + 1; t.peds[200 + t.made] = true; return 200 + t.made end,
            DoesEntityExist = function(ped) return t.peds[ped] and 1 or false end,
            DeleteEntity = function(ped) t.peds[ped] = nil end,
            SetEntityInvincible = function() end, FreezeEntityPosition = function() end,
            SetBlockingOfNonTemporaryEvents = function() end,
            AddBlipForCoord = function() t.blips = t.blips + 1 return t.blips end,
            SetBlipSprite = function() end, SetBlipScale = function() end, SetBlipAsShortRange = function() end,
            BeginTextCommandSetBlipName = function() end, AddTextComponentSubstringPlayerName = function() end,
            EndTextCommandSetBlipName = function() end, RemoveBlip = function() t.blips = t.blips - 1 end,
            GetEntityCoords = function() return vec(t.me.x, t.me.y, t.me.z) end,
            PlayerPedId = function() return 1 end, LocalPlayer = { state = { isLoggedIn = true } },
            vector3 = vec, Wait = function(ms) coroutine.yield(ms) end,
            TriggerServerEvent = function(name, ...) t.sent[#t.sent + 1] = { name, ... } end,
            RegisterNetEvent = function(name, fn) t.handlers[name] = fn end,
            AddEventHandler = function(name, fn) t.handlers[name] = fn end,
            GetCurrentResourceName = function() return 'crimson-hitman' end,
            CreateThread = function(fn) t.threads[#t.threads + 1] = coroutine.create(fn) end,
        }, { __index = _G })
        t.mod = assert(loadfile('crimson-hitman/client/org.lua', 't', env))()
        function t.step(i)
            local ok, ms = coroutine.resume(t.threads[i])
            truthy(ok, tostring(ms))
            if coroutine.status(t.threads[i]) == 'dead' then return 'ended' end
            return ms
        end
        return t
    end

    local function live(t)
        local n = 0
        for _, z in ipairs(t.zones) do if z then n = n + 1 end end
        return n
    end

    it('runs nothing at load, and nothing with no spot sent', function()
        local t = client()
        eq(#t.threads, 0, 'no thread at load')
        eq(#t.sent, 0, 'no question to the server either')
        t.handlers['crimson-hitman:orgSpots']({ spots = {} })
        eq(#t.threads, 0)
        eq(#t.zones, 0)
    end)

    it('makes an ox_target zone a spot, whose option asks the server, and clears it at a logout and a stop', function()
        local t = client()
        t.handlers['crimson-hitman:orgSpots']({ spots = {
            { id = 'a', kind = 'signup', label = 'Board', x = 1, y = 2, z = 3, radius = 2, blip = true },
            { id = 'b', kind = 'office', label = 'Office', x = 9, y = 9, z = 9 },
            { id = 'bad', kind = 'office', x = 'nope' }, 'junk',
        } })
        eq(live(t), 2, 'two zones, the junk left out')
        eq(t.blips, 1)
        eq(#t.threads, 0, 'no loop without an NPC')
        t.zones[1].options[1].onSelect()
        eq(t.sent[1][1], 'crimson-hitman:orgUse')
        eq(t.sent[1][2], 'a', 'only the spot\'s id')
        t.handlers['QBCore:Client:OnPlayerUnload']()
        eq(live(t), 0, 'a logout clears every zone')
        eq(t.blips, 0)
        t.handlers['crimson-hitman:orgSpots']({ spots = { { id = 'a', kind = 'signup', x = 1, y = 2, z = 3 } } })
        t.handlers['onResourceStop']('crimson-hitman')
        eq(live(t), 0, 'and so does the stop')
    end)

    it('streams an NPC in near and out far, on an adaptive loop that ends with no NPC', function()
        local t = client()
        t.me = { x = 5000.0, y = 0.0, z = 0.0 }
        t.handlers['crimson-hitman:orgSpots']({ draw = 40, spots = { { id = 'n', kind = 'npc', x = 0, y = 0, z = 0 } } })
        eq(#t.threads, 1, 'one loop for the NPC')
        eq(t.step(1), 2000, 'far: every two seconds')
        eq(t.made, 0)
        t.me = { x = 10.0, y = 0.0, z = 0.0 }
        eq(t.step(1), 1000, 'near: every second')
        eq(t.made, 1, 'the ped made')
        truthy(next(t.entities), 'with its ox_target option')
        t.me = { x = 200.0, y = 0.0, z = 0.0 }
        t.step(1)
        eq(next(t.peds), nil, 'removed past the distance')
        t.handlers['crimson-hitman:orgSpots']({ spots = {} })
        eq(t.step(1), 'ended', 'the loop ends with no NPC')
        falsy(t.mod.running(), 'and says so')
    end)

    it('draws no zone where ox_target is not running', function()
        local t = client()
        t.target = 'missing'
        t.handlers['crimson-hitman:orgSpots']({ spots = { { id = 'a', kind = 'signup', x = 1, y = 2, z = 3 } } })
        eq(#t.zones, 0)
    end)
end)
