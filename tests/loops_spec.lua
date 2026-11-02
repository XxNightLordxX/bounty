--- The recurring loops: how often each runs, that each does nothing when it
--- has nothing to do, and what a whole maintenance pass costs on a busy
--- server (README, Performance: the loops).
---
---   * the maintenance tick runs every job on its first pass after a start,
---     then the scheduled ones at their own interval (the access check every
---     30 seconds, the minute jobs once a minute), and the minute jobs land
---     on ticks of their own, never on the playtime pass's or the json
---     heartbeat's;
---   * the idle-hold sweep reads the running contracts and their rosters
---     once a pass, not each held contract twice, and asks qbx_core once for
---     each person; with nothing held it reads nothing;
---   * the condition sampler reads no roster with nothing running, and asks
---     for each target's medical state once a pass however many contracts
---     name them;
---   * the NPC positions are looked at by the tick, not a thread of their
---     own; a duty change tells a player whether they have the app at once;
---   * /ch-diag lists every job with how often it runs;
---   * the client's NPC loop sleeps two seconds while nothing is near;
---   * a whole maintenance pass, every job due, with 200 live contracts and
---     64 players in the city, stays inside its budget (BUDGET_MS).

local Exec = require('tests.harness.mysql_exec')

local function forget()
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
            package.loaded[name] = nil
        end
    end
end

local function boot(mode, configure)
    forget()
    Env.reset()
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Natives.resetResourceStates()
    resetConfig()
    Config.Database.Mode = mode or 'memory'
    if mode == 'mysql' then Exec.install(Natives) end
    if mode == 'json' then Natives.files = {} end
    if configure then configure() end
    local main = require('server.main')
    return main, main.start()
end

--- 64 players: 20 who place, 20 they place on, 24 operatives. 200 live
--- contracts, each held by one operative, so every clock runs.
local function city(s)
    Config.Limits.MaxActiveContractsPerCreator = 10000
    Config.Limits.MaxActiveContractsPerTarget = 10000
    Config.Limits.SameCreatorSameTargetCooldownSeconds = 0
    Config.Immunity.MinTargetSessionMinutes = 0
    Config.Immunity.MinTargetPlaytimeHours = 0
    Config.Limits.MaxAcceptedPerHitman = 10000
    local creators, targets, ops = {}, {}, {}
    for i = 1, 20 do
        Env.addPlayer({ source = 100 + i, citizenid = ('CRE%05d'):format(i),
            license = ('license:cre%d'):format(i), cash = 90000000, bank = 90000000 })
        creators[i] = s.identity.resolve(100 + i)
        Env.addPlayer({ source = 200 + i, citizenid = ('TGT%05d'):format(i),
            license = ('license:tgt%d'):format(i), cash = 100, bank = 100 })
        targets[i] = s.identity.resolve(200 + i)
    end
    for i = 1, 24 do
        Env.addPlayer({ source = 300 + i, citizenid = ('OPR%05d'):format(i),
            license = ('license:opr%d'):format(i), cash = 90000000, bank = 90000000 })
        ops[i] = s.identity.resolve(300 + i)
    end
    local made = {}
    for i = 1, 200 do
        local c = (i - 1) % 20
        local t = (c + 1 + math.floor((i - 1) / 20)) % 20
        local row = s.contracts.create(creators[c + 1], { targetCid = targets[t + 1].cid,
            reason = 'scale', reward = { baseline = { cash = 1000, bank = 1000 } } })
        if row then
            made[#made + 1] = row.id
            truthy(s.contracts.accept(ops[(i - 1) % 24 + 1], row.id), 'held')
        end
    end
    eq(#made, 200, 'two hundred live contracts')
    return made
end

--- One tick, ten seconds on.
local function tick(main)
    Env.time = Env.time + 10
    Env.gameTimer = Env.gameTimer + 10000
    main.tick()
end

--- Which jobs ran on each of `count` ticks: [job] = { tick numbers }.
local function runs(main, count, also)
    local Timing = require('server.timing')
    local record = Timing.record
    local at, n = {}, 0
    Timing.record = function(name, ms)
        at[name] = at[name] or {}
        at[name][#at[name] + 1] = n
        return record(name, ms)
    end
    local ok, err = pcall(function()
        for i = 1, count do
            n = i
            if also then also(i) end
            tick(main)
        end
    end)
    Timing.record = record
    if not ok then error(err, 0) end
    return at
end

local function gaps(list)
    local out = {}
    for i = 2, #(list or {}) do out[#out + 1] = list[i] - list[i - 1] end
    return out
end

local function setOf(list)
    local out = {}
    for _, v in ipairs(list or {}) do out[v] = true end
    return out
end

--------------------------------------------------------------------------
-- The schedule
--------------------------------------------------------------------------

--- The scheduled jobs and their interval, in ticks of ten seconds.
local SCHEDULED = {
    ['bridges.refreshAccess'] = 3, ['rp_places.announce'] = 6,
    ['freeze.syncAppPause'] = 6, ['thresholds.sweep'] = 6,
}

--- And jobs that stay on every tick: money, expiry, the holds, the flush.
local EVERY_TICK = { 'freeze.restartTick', 'sanctions.tick', 'summary.tick', 'contracts.releaseIdleHolds',
    'expireContracts', 'escrow.retryWaiting', 'rp_protection.sweep', 'rp_intent.sweep', 'rp.tick',
    'audit.flush', 'storage.flush', 'bailout.processQueue', 'notify.deliverKept' }

describe('the maintenance tick\'s schedule', function()
    it('runs every job on the first tick after a start', function()
        local main = boot('memory')
        local at = runs(main, 1)
        for name in pairs(SCHEDULED) do
            eq(at[name] and at[name][1], 1, name .. ' on the first tick')
        end
        for _, name in ipairs(EVERY_TICK) do
            eq(at[name] and at[name][1], 1, name .. ' on the first tick')
        end
    end)

    it('then runs each scheduled job at its own interval, and the rest on every tick', function()
        local main = boot('memory')
        local at = runs(main, 60)
        for name, period in pairs(SCHEDULED) do
            local between = gaps(at[name])
            truthy(#between >= math.floor(60 / period) - 2,
                ('%s ran %d times in ten minutes'):format(name, #(at[name] or {})))
            -- The first gap carries the job's phase; every one after it is
            -- the interval exactly.
            for i = 2, #between do
                eq(between[i], period, ('%s comes round every %d ticks'):format(name, period))
            end
        end
        for _, name in ipairs(EVERY_TICK) do
            eq(#(at[name] or {}), 60, name .. ' runs on every tick')
        end
    end)

    it('keeps each job on its own tick of the cycle when the tick runs late', function()
        local main = boot('memory')
        local Timing = require('server.timing')
        local record = Timing.record
        local at, n = {}, 0
        Timing.record = function(name, ms)
            if name == 'rp_places.announce' then at[#at + 1] = n end
            return record(name, ms)
        end
        -- Every third tick a second late, as a busy server's is: the tick
        -- waits its interval after the last one finished.
        local ok, err = pcall(function()
            for i = 1, 60 do
                n = i
                Env.time = Env.time + 10 + (i % 3 == 0 and 1 or 0)
                main.tick()
            end
        end)
        Timing.record = record
        truthy(ok, tostring(err))
        local between = gaps(at)
        truthy(#between >= 8, 'ran')
        for i = 2, #between do eq(between[i], 6, 'still every sixth tick') end
    end)

    it('puts the minute jobs on ticks of their own, away from the playtime pass and the heartbeat', function()
        local main, s = boot('json')
        city(s)
        local playtime, heartbeat = {}, {}
        local n = 0
        local write = s.storage.writePlaytime
        s.storage.writePlaytime = function(rows)
            playtime[#playtime + 1] = n
            return write(rows)
        end
        local save = SaveResourceFile
        _G.SaveResourceFile = function(res, file, ...)
            if file == 'data/heartbeat.json' then heartbeat[#heartbeat + 1] = n end
            return save(res, file, ...)
        end
        local ok, at = pcall(runs, main, 60, function(i) n = i end)
        _G.SaveResourceFile = save
        s.storage.writePlaytime = write
        truthy(ok, tostring(at))
        truthy(#playtime >= 9 and #heartbeat >= 9, ('the playtime pass (%d) and the heartbeat (%d) '
            .. 'both ran'):format(#playtime, #heartbeat))

        local heavy = setOf(playtime)
        for t in pairs(setOf(heartbeat)) do heavy[t] = true end
        local seen = {}
        for _, name in ipairs({ 'rp_places.announce', 'bridges.refreshAccess',
            'thresholds.sweep', 'freeze.syncAppPause' }) do
            for _, t in ipairs(at[name] or {}) do
                if t > 1 then
                    falsy(heavy[t], ('%s shares tick %d with the playtime pass or the heartbeat')
                        :format(name, t))
                    -- And the two that send or read from each other (the
                    -- other two are a comparison or two each).
                    if name == 'rp_places.announce' or name == 'bridges.refreshAccess' then
                        falsy(seen[t], ('%s shares tick %d with %s'):format(name, t, tostring(seen[t])))
                        seen[t] = name
                    end
                end
            end
        end
    end)
end)

--------------------------------------------------------------------------
-- Early exits
--------------------------------------------------------------------------

--- Every store read in `fn`, by name.
local function storeReads(store, fn, names)
    local counts, real = {}, {}
    for _, name in ipairs(names) do
        real[name] = store[name]
        store[name] = function(...)
            counts[name] = (counts[name] or 0) + 1
            return real[name](...)
        end
    end
    local ok, err = pcall(fn)
    for name, f in pairs(real) do store[name] = f end
    if not ok then error(err, 0) end
    return counts
end

local READS = { 'readContract', 'readHitmen', 'readHitman', 'liveContracts', 'liveHitmen', 'allContracts' }

describe('the idle-hold sweep', function()
    it('reads the running contracts and their rosters once a pass, not each held contract twice', function()
        local main, s = boot('mysql')
        city(s)
        main.tick()
        local counts = storeReads(s.storage, function() s.contracts.releaseIdleHolds() end, READS)
        eq(counts.liveContracts, 1, 'the running contracts, once')
        eq(counts.liveHitmen, 1, 'their rosters, once')
        eq(counts.readContract, nil, 'no contract read one at a time (it was 200)')
        eq(counts.readHitmen, nil, 'nor its roster (it was 200 more)')
    end)

    it('asks qbx_core once a pass for each person, however many contracts name them', function()
        local main, s = boot('json')
        city(s)
        main.tick()
        local asked = 0
        local real = s.identity.byCitizenId
        s.identity.byCitizenId = function(...)
            asked = asked + 1
            return real(...)
        end
        local ok, err = pcall(s.contracts.releaseIdleHolds)
        s.identity.byCitizenId = real
        truthy(ok, tostring(err))
        truthy(asked <= 40, ('asked %d times for 40 people (it was 400)'):format(asked))
    end)

    it('still releases an idle hold, and runs no clock while the app is paused', function()
        local _, s = boot('memory', function()
            Config.Limits.ExclusiveIdleReleaseSeconds = 60
            Config.Limits.ExclusiveAttemptWindowSeconds = 0
        end)
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            mode = CH.MODE.EXCLUSIVE, reward = { baseline = { cash = 5000 } } })
        truthy(c, 'placed')
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        s.contracts.releaseIdleHolds()
        Config.Staff.AppPaused = true
        s.freeze.syncAppPause()
        for _ = 1, 10 do
            Env.time = Env.time + 10
            s.contracts.releaseIdleHolds()
        end
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'held through the pause')
        Config.Staff.AppPaused = false
        s.freeze.syncAppPause()
        for _ = 1, 7 do
            Env.time = Env.time + 10
            s.contracts.releaseIdleHolds()
        end
        eq(s.storage.readContract(c.id).state, CH.STATE.ACTIVE, 'released once idle for the window')
    end)

    it('reads nothing with nothing held', function()
        local _, s = boot('mysql')
        fixture(s)
        local counts = storeReads(s.storage, function() s.contracts.releaseIdleHolds() end, READS)
        eq(next(counts), nil, 'no store read at all')
    end)
end)

describe('the condition sampler', function()
    --- One pass of the sampler's own thread.
    local function samplerPass()
        local thread
        for _, fn in ipairs(Env.threads) do
            if debug.getinfo(fn, 'S').short_src:find('death.lua', 1, true) then thread = fn end
        end
        truthy(thread, 'the sampler thread')
        local co = coroutine.wrap(thread)
        local realWait = _G.Wait
        _G.Wait = coroutine.yield
        local ok, err = pcall(function()
            co()   -- to its first wait
            co()   -- one pass
        end)
        _G.Wait = realWait
        truthy(ok, tostring(err))
    end

    it('reads no roster with nothing running', function()
        local _, s = boot('mysql')
        fixture(s)
        local counts = storeReads(s.storage, samplerPass, READS)
        eq(counts.liveContracts, 1, 'what is running: nothing')
        eq(counts.liveHitmen, nil, 'so no roster is read')
    end)

    it('asks each target\'s medical state once a pass, however many contracts name them', function()
        local main, s = boot('json')
        city(s)
        main.tick()
        local asked = 0
        local real = s.identity.deathState
        s.identity.deathState = function(...)
            asked = asked + 1
            return real(...)
        end
        local death = require('server.completion.death')
        local ok, err = pcall(death.watchTargets, s.storage.liveContracts(), s.storage.liveHitmen())
        s.identity.deathState = real
        truthy(ok, tostring(err))
        eq(asked, 20, 'twenty targets, asked once each (it was 200)')
    end)
end)

describe('the rest of the loops', function()
    it('looks at where the NPCs stand from the tick, with no thread of its own', function()
        boot('memory')
        for _, fn in ipairs(Env.threads) do
            falsy(debug.getinfo(fn, 'S').short_src:find('rp_places', 1, true), 'a thread in rp_places.lua')
        end
        eq(#Env.threads, 2, 'the condition sampler and the maintenance tick, and nothing else')
    end)

    it('tells a player whether they have the app the moment their duty changes', function()
        local _, s = boot('memory', function()
            Config.WhitelistedView.Enabled = false
        end)
        fixture(s)
        require('server.bridges').refreshAccess()
        Env.players[3].PlayerData.job = { name = 'police', type = 'leo', onduty = true }
        local fire = Env.events['local:QBCore:Server:SetDuty']
        truthy(fire, 'the duty event is heard')
        Env.clientEvents = {}
        fire(3, true)
        local told
        for _, e in ipairs(Env.clientEvents) do
            if e.name == 'crimson-hitman:access' and e.target == 3 then told = e.args end
        end
        truthy(told, 'told at once, not at the next access check')
        eq(told[1], false, 'and closed to them')
    end)

    it('lists every job in /ch-diag with how often it runs', function()
        local main, s = boot('memory')
        fixture(s)
        main.tick()
        local out = table.concat(s.admin.diagnose(0), '\n')
        local listed = 0
        for _ in out:gmatch('\n  [%w_.]+%s+max ') do listed = listed + 1 end
        local timed = #require('server.timing').slowest()
        eq(listed, timed, 'every timed job, not the five slowest')
        truthy(timed > 20, 'and there are more than twenty')
        truthy(out:match('bridges%.refreshAccess[^\n]*every 30s'), out)
        truthy(out:match('rp_places%.announce[^\n]*every 60s'), out)
        truthy(out:match('playtime%.pass[^\n]*every 60s'), out)
        truthy(out:match('expireContracts[^\n]*every 10s'), out)
    end)
end)

--------------------------------------------------------------------------
-- The client's NPC loop
--------------------------------------------------------------------------

describe('the client\'s NPC loop', function()
    it('sleeps two seconds while nothing is near or placed, and one second near an NPC', function()
        local handlers, thread = {}, nil
        local me = { x = 5000.0, y = 0.0, z = 0.0 }
        local function vec(x, y, z)
            return setmetatable({ x = x, y = y, z = z }, {
                __sub = function(a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end,
                __len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end,
            })
        end
        local env = setmetatable({
            joaat = function() return 1234 end,
            IsModelInCdimage = function() return 1 end, IsModelValid = function() return 1 end,
            RequestModel = function() end, HasModelLoaded = function() return true end,
            SetModelAsNoLongerNeeded = function() end,
            CreatePed = function() return 101 end, DoesEntityExist = function() return 1 end,
            DeleteEntity = function() end,
            SetEntityInvincible = function() end, FreezeEntityPosition = function() end,
            SetBlockingOfNonTemporaryEvents = function() end, SetPedCanRagdoll = function() end,
            TaskStartScenarioInPlace = function() end,
            AddBlipForCoord = function() return 1 end, SetBlipSprite = function() end,
            SetBlipScale = function() end, SetBlipAsShortRange = function() end,
            BeginTextCommandSetBlipName = function() end,
            AddTextComponentSubstringPlayerName = function() end,
            EndTextCommandSetBlipName = function() end, RemoveBlip = function() end,
            GetEntityCoords = function() return vec(me.x, me.y, me.z) end,
            PlayerPedId = function() return 1 end,
            vector3 = vec,
            Wait = function(ms) coroutine.yield(ms) end,
            SetTimeout = function() end,
            TriggerServerEvent = function() end,
            RegisterNetEvent = function(name, fn) handlers[name] = fn end,
            AddEventHandler = function(name, fn) handlers[name] = fn end,
            GetCurrentResourceName = function() return 'crimson-hitman' end,
            CreateThread = function(fn) thread = coroutine.create(fn) end,
        }, { __index = _G })
        assert(loadfile('crimson-hitman/client/rp_npc.lua', 't', env))()
        local function step()
            local ok, ms = coroutine.resume(thread)
            truthy(ok, 'the loop raised: ' .. tostring(ms))
            return ms
        end
        step()                                   -- the first wait
        eq(step(), 2000, 'nothing placed: every two seconds')
        handlers['crimson-hitman:result']({ event = 'rpPlaces', ok = true, data = {
            broker = { x = 0.0, y = 0.0, z = 0.0, model = 'g_m_m_armboss_01', scenario = '' } } })
        eq(step(), 2000, 'placed, but five kilometres off: every two seconds')
        me.x = 150.0
        eq(step(), 1000, 'inside 160 m: every second, so it is drawn before the player arrives')
        me.x = 10.0
        eq(step(), 1000, 'drawn: every second, so it is removed when they leave')
    end)
end)

--------------------------------------------------------------------------
-- The budget
--------------------------------------------------------------------------

--- What a whole maintenance pass may take, every job due at once, plus one
--- condition sampler pass, with 200 live contracts and 64 players in the
--- city: the median of seven passes, in milliseconds of this process's
--- processor time. Measured at about 5 ms on json and 18 ms on mysql (whose
--- figure includes this harness running every statement in Lua, which a
--- real database does elsewhere) on the machine the change was made on;
--- the budget leaves three times that and more for a slower one.
local BUDGET_MS = 60

describe('a whole maintenance pass on a busy server', function()
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(('stays inside %d ms on %s, every job due, 200 contracts and 64 players'):format(BUDGET_MS, mode),
            function()
                local main, s = boot(mode)
                city(s)
                main.tick()   -- what placing two hundred left to write, written
                local death = require('server.completion.death')
                local passes = {}
                for i = 1, 7 do
                    -- Ten minutes on: every scheduled and self-gated job is due.
                    Env.time = Env.time + 600
                    Env.gameTimer = Env.gameTimer + 600000
                    local started = os.clock()
                    main.tick()
                    death.watchTargets(s.storage.liveContracts(), s.storage.liveHitmen())
                    passes[i] = (os.clock() - started) * 1000
                end
                table.sort(passes)
                local median = passes[4]
                truthy(median < BUDGET_MS, ('the median pass took %.1f ms on %s (budget %d ms)')
                    :format(median, mode, BUDGET_MS))
            end)
    end
end)
