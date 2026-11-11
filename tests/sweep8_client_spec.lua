--- Sweep 8, the client and the stores: each finding the skeptic confirmed,
--- as the probe that showed it, now held.
---
---   C1  an organisation NPC whose spot went (a logout, a push) while its
---       model loaded is never made;
---   A1  the third-eye zones (organisation spots, disposal markers) come back
---       when ox_target restarts or starts late;
---   P2  a barred job's game asks for the NPC places once, not every minute,
---       and keeps at most one retry waiting;
---   A3  with no phone started, nothing polls for one: its start registers;
---   S1  idle clocks still in records.json read back once on the json store.
---
--- L2 and R1 are in tests/locale_spec.lua, A2 in tests/adapters_spec.lua; the
--- page findings (P1, L1, L3, U1) in tests/ui/run.js and tests/ui/admin_run.js.

local Client = require('tests.harness.client')

--- A game with the client files the manifest loads before and with
--- client/org.lua and client/rp_npc.lua, whose engine events run every
--- listener (as the engine's do), with a model load and ox_target to steer.
local function game()
    local t = { handlers = {}, threads = {}, zones = {}, entities = {}, peds = {}, made = 0,
        me = { x = 0.0, y = 0.0, z = 0.0 }, target = 'started', loaded = true, sent = {}, timers = {},
        state = { isLoggedIn = true } }
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
    local function listen(name, fn)
        local before = t.handlers[name]
        t.handlers[name] = before and function(...) before(...) return fn(...) end or fn
    end
    local env = setmetatable({
        exports = setmetatable({}, { __index = function(_, k) if k == 'ox_target' then return ox end end }),
        GetResourceState = function(name) return name == 'ox_target' and t.target or 'missing' end,
        joaat = function() return 1234 end, IsModelInCdimage = function() return 1 end,
        IsModelValid = function() return 1 end,
        RequestModel = function() end, HasModelLoaded = function() return t.loaded end,
        SetModelAsNoLongerNeeded = function() end,
        CreatePed = function() t.made = t.made + 1; t.peds[200 + t.made] = true; return 200 + t.made end,
        DoesEntityExist = function(ped) return t.peds[ped] and 1 or false end,
        DeleteEntity = function(ped) t.peds[ped] = nil end,
        SetEntityInvincible = function() end, FreezeEntityPosition = function() end,
        SetBlockingOfNonTemporaryEvents = function() end, SetPedCanRagdoll = function() end,
        TaskStartScenarioInPlace = function() end,
        AddBlipForCoord = function() return 1 end, AddBlipForRadius = function() return 1 end,
        SetBlipAlpha = function() end,
        SetBlipSprite = function() end, SetBlipScale = function() end, SetBlipAsShortRange = function() end,
        BeginTextCommandSetBlipName = function() end, AddTextComponentSubstringPlayerName = function() end,
        EndTextCommandSetBlipName = function() end, RemoveBlip = function() end,
        DoesBlipExist = function() return 1 end, SetBlipColour = function() end,
        GetEntityCoords = function() return vec(t.me.x, t.me.y, t.me.z) end,
        PlayerPedId = function() return 1 end, LocalPlayer = { state = t.state },
        vector3 = vec, Wait = function(ms) coroutine.yield(ms) end,
        SetTimeout = function(ms, fn) t.timers[#t.timers + 1] = { ms = ms, fn = fn } end,
        TriggerServerEvent = function(name, ...) t.sent[#t.sent + 1] = { name, ... } end,
        RegisterNetEvent = function(name, fn) if fn then listen(name, fn) end end,
        AddEventHandler = listen,
        GetCurrentResourceName = function() return 'crimson-hitman' end,
        CreateThread = function(fn) t.threads[#t.threads + 1] = coroutine.create(fn) end,
    }, { __index = _G })
    assert(loadfile('crimson-hitman/shared/geo.lua', 't', env))()
    assert(loadfile('crimson-hitman/locales/client/en.lua', 't', env))()
    assert(loadfile('crimson-hitman/shared/locale.lua', 't', env))()
    require('tests.harness.client_adapters')(env)
    assert(loadfile('crimson-hitman/client/missionsteps.lua', 't', env))()
    assert(loadfile('crimson-hitman/client/npc.lua', 't', env))()
    assert(loadfile('crimson-hitman/client/rp_npc.lua', 't', env))()
    t.markers = env.CrimsonMarkers
    t.org = assert(loadfile('crimson-hitman/client/org.lua', 't', env))()
    function t.step(i)
        local ok, ms = coroutine.resume(t.threads[i])
        truthy(ok, tostring(ms))
        if coroutine.status(t.threads[i]) == 'dead' then return 'ended' end
        return ms
    end
    function t.alive()
        local n = 0
        for _ in pairs(t.peds) do n = n + 1 end
        return n
    end
    function t.live()
        local n = 0
        for _, z in ipairs(t.zones) do if z then n = n + 1 end end
        return n
    end
    function t.asked()
        local n = 0
        for _, e in ipairs(t.sent) do if e[1] == 'crimson-hitman:rpPlaces' then n = n + 1 end end
        return n
    end
    return t
end

--- The NPC distance loop's thread (the last one made: rp_npc's start
--- question is the first).
local function loopOf(t) return #t.threads end

describe('C1: an organisation NPC whose spot went while its model loaded', function()
    local NPC = { draw = 40, spots = { { id = 'n', kind = 'npc', x = 0, y = 0, z = 0 } } }

    it('is not made after a logout during the load', function()
        local t = game()
        t.loaded = false
        t.handlers['crimson-hitman:orgSpots'](NPC)
        local loop = loopOf(t)
        t.step(loop)                                   -- the pass: the model load waits
        t.handlers['QBCore:Client:OnPlayerUnload']()
        t.state.isLoggedIn = false
        t.loaded = true
        t.step(loop)
        eq(t.alive(), 0, 'no ped left behind')
    end)

    it('is not made after a push that moved the spot away during the load', function()
        local t = game()
        t.loaded = false
        t.handlers['crimson-hitman:orgSpots'](NPC)
        local loop = loopOf(t)
        t.step(loop)
        t.handlers['crimson-hitman:orgSpots']({ draw = 40, spots = {
            { id = 'o', kind = 'office', label = 'Office', x = 9, y = 9, z = 9 } } })
        t.loaded = true
        t.step(loop)
        eq(t.alive(), 0, 'no ped for a spot that is gone')
    end)

    it('is made as before when nothing changed during the load', function()
        local t = game()
        t.loaded = false
        t.handlers['crimson-hitman:orgSpots'](NPC)
        local loop = loopOf(t)
        t.step(loop)
        t.loaded = true
        t.step(loop)
        eq(t.alive(), 1)
    end)
end)

describe('A1: the third-eye zones when ox_target restarts or starts late', function()
    local SPOTS = { spots = {
        { id = 'a', kind = 'signup', label = 'Board', x = 1, y = 2, z = 3, radius = 2 },
        { id = 'b', kind = 'office', label = 'Office', x = 9, y = 9, z = 9 } } }

    it('draws the organisation spots again when ox_target comes back', function()
        local t = game()
        t.handlers['crimson-hitman:orgSpots'](SPOTS)
        eq(t.live(), 2)
        -- ox_target restarting forgets every zone it was given.
        t.target = 'stopped'
        t.handlers['onClientResourceStop']('ox_target')
        t.zones = {}
        t.target = 'started'
        t.handlers['onClientResourceStart']('ox_target')
        eq(t.live(), 2, 'both zones added again')
    end)

    it('adds the zones ox_target missed when it starts after this resource', function()
        local t = game()
        t.target = 'missing'
        t.handlers['crimson-hitman:orgSpots'](SPOTS)
        eq(t.live(), 0, 'nothing to add them to yet')
        t.target = 'started'
        t.handlers['onClientResourceStart']('ox_target')
        eq(t.live(), 2)
        t.handlers['onClientResourceStart']('some-other-resource')
        eq(t.live(), 2, 'another resource means nothing')
    end)

    it('adds a disposal marker\'s zone again when ox_target comes back', function()
        local t = game()
        truthy(t.markers.set('disposal:x', { kind = 'disposal_body', x = 1, y = 1, z = 1, act = 'load', ref = 'ct1' }))
        eq(t.live(), 1)
        t.target = 'stopped'
        t.handlers['onClientResourceStop']('ox_target')
        t.zones = {}
        t.target = 'started'
        t.handlers['onClientResourceStart']('ox_target')
        eq(t.live(), 1, 'the load option is back')
        eq(t.zones[1].options[1].name, 'crimson_disposal_load')
    end)
end)

describe('P2: the NPC places, asked by a barred job\'s game', function()
    local function refused(t, err)
        t.handlers['crimson-hitman:result']({ event = 'rpPlaces', ok = false, err = err })
    end

    it('asks once and does not ask again every minute, nor on every change notice', function()
        local t = game()
        t.step(1)
        t.step(1)                                  -- the question at start
        eq(t.asked(), 1)
        refused(t, 'blacklisted_job')
        eq(#t.timers, 0, 'no retry for a barred job')
        t.handlers['crimson-hitman:rpPlacesChanged']()
        t.handlers['crimson-hitman:rpPlacesChanged']()
        eq(t.asked(), 1, 'a change notice asks nothing of a barred game')
        -- Their access changed (a new job): asked again.
        t.handlers['crimson-hitman:access'](true, 'full')
        eq(t.asked(), 2)
    end)

    it('keeps one retry waiting, however many refusals pass by themselves', function()
        local t = game()
        t.step(1)
        t.step(1)
        refused(t, 'busy')
        t.handlers['crimson-hitman:rpPlacesChanged']()
        refused(t, 'rate_limited')
        refused(t, 'busy')
        eq(#t.timers, 1, 'one retry waiting')
        t.timers[1].fn()
        eq(t.asked(), 2, 'and it asks once')
        refused(t, 'busy')
        eq(#t.timers, 2, 'the next one only after it ran')
    end)
end)

describe('A3: the phone app with no phone started', function()
    local function registered()
        local n = 0
        for _, call in ipairs(Client.phone) do if call.call == 'AddCustomApp' then n = n + 1 end end
        return n
    end

    it('polls for nothing, and registers when the phone starts', function()
        Env.reset()
        Client.boot()
        Natives.resourceStates = { ['lb-phone'] = 'missing' }
        Client.fire('crimson-hitman:access', true)
        -- The registration thread alone (client/main.lua registerWithRetries),
        -- its waits counted: one waiting for the phone never ends.
        local src = io.open('crimson-hitman/client/main.lua'):read('a')
        local at = select(2, src:sub(1, src:find('local function registerWithRetries', 1, true)):gsub('\n', '')) + 1
        local reg
        for _, fn in ipairs(Env.threads) do
            local info = debug.getinfo(fn, 'S')
            if info.short_src:find('client/main.lua', 1, true) and info.linedefined == at then reg = fn end
        end
        truthy(reg, 'the registration thread, at line ' .. at)
        local waits, realWait = 0, _G.Wait
        _G.Wait = function()
            waits = waits + 1
            if waits > 1000 then error('waits for the phone', 0) end
        end
        local ok, err = pcall(reg)
        _G.Wait = realWait
        truthy(ok, tostring(err))
        eq(waits, 0, 'nothing waits for a phone that is not there')
        Env.threads = {}
        eq(registered(), 0)
        Natives.resourceStates = { ['lb-phone'] = 'started' }
        Client.fire('onClientResourceStart', 'lb-phone')
        Client.runThreads()
        eq(registered(), 1, 'its start registers the app')
        Natives.resetResourceStates()
    end)
end)

describe('S1: idle clocks still in records.json, on the json store', function()
    it('read back once, not twice, on the first read', function()
        package.loaded['crimson-hitman.server.storage.json'] = nil
        Natives.files = {}
        local store = require('crimson-hitman.server.storage.json')
        store.open()
        store.writeRpRow({ id = 'x:1', kind = 'other' })
        store.close()
        local dir = Config.Database.Json.Directory or 'data'
        local path = dir .. '/records.json'
        local db = json.decode(Natives.files[path])
        db.rpRows = db.rpRows or {}
        db.rpRows['idle:ct1'] = { id = 'idle:ct1', kind = 'idle_clock', contract_id = 'ct1' }
        Natives.files[path] = json.encode(db)
        package.loaded['crimson-hitman.server.storage.json'] = nil
        local reopened = require('crimson-hitman.server.storage.json')
        reopened.open()
        eq(#reopened.readRpRows('idle_clock'), 1, 'the first read')
        eq(#reopened.readRpRows('idle_clock'), 1, 'and the second')
        package.loaded['crimson-hitman.server.storage.json'] = nil
    end)
end)
