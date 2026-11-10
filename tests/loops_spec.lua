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
---     once a pass, not each held contract twice (and not at all while
---     nothing has been written: the read is shared, Projection.liveSnapshot),
---     and asks qbx_core once for each person; with nothing held it reads
---     nothing; it releases at most IDLE_RELEASES_PER_PASS holds a pass;
---   * the condition sampler reads no roster with nothing running, and asks
---     for each target's medical state once a pass however many contracts
---     name them;
---   * the NPC positions are looked at by the tick, not a thread of their
---     own; a duty change tells a player whether they have the app at once;
---   * /ch-diag lists every job with how often it runs, the prune every ten
---     minutes;
---   * on a busy mysql server with nothing to do, no job sends the database
---     anything but the heartbeat, the endings check and the playtime batch;
---   * the client's NPC loop sleeps two seconds while nothing is near, and
---     does not run at all while both NPCs are off;
---   * a whole maintenance pass, every job due, with 200 live contracts and
---     64 players in the city, stays inside its budget (BUDGET_MS) at its
---     worst, and the pass where every hold and every contract falls due at
---     once ends only a share of them (MASS_BUDGET_MS).

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
    ['holds.syncAppPause'] = 6, ['thresholds.sweep'] = 6,
    ['imp_board.tick'] = 6, ['imp_decay.tick'] = 6,
}

--- And jobs that stay on every tick: money, expiry, the holds, the flush.
local EVERY_TICK = { 'holds.tick', 'sanctions.tick', 'summary.tick', 'contracts.releaseIdleHolds',
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
            'thresholds.sweep', 'holds.syncAppPause', 'imp_decay.tick' }) do
            for _, t in ipairs(at[name] or {}) do
                if t > 1 then
                    falsy(heavy[t], ('%s shares tick %d with the playtime pass or the heartbeat')
                        :format(name, t))
                    -- And the two that send or read from each other (the
                    -- other two are a comparison or two each).
                    if name == 'rp_places.announce' or name == 'bridges.refreshAccess'
                        or name == 'imp_decay.tick' then
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
        local made = city(s)
        main.tick()
        -- A write, so the shared snapshot (Projection.liveSnapshot) is read
        -- again by this pass.
        s.storage.setAdvised(made[1], { advised_posted_at = Env.time })
        local counts = storeReads(s.storage, function() s.contracts.releaseIdleHolds() end, READS)
        eq(counts.liveContracts, 1, 'the running contracts, once')
        eq(counts.liveHitmen, 1, 'their rosters, once')
        eq(counts.readContract, nil, 'no contract read one at a time (it was 200)')
        eq(counts.readHitmen, nil, 'nor its roster (it was 200 more)')
    end)

    it('releases at most IDLE_RELEASES_PER_PASS holds a pass, the rest on the passes after', function()
        local main, s = boot('mysql', function()
            Config.Limits.ExclusiveIdleReleaseSeconds = 60
            Config.Limits.ExclusiveAttemptWindowSeconds = 0
        end)
        local made = city(s)
        main.tick()
        local cap = s.contracts.IDLE_RELEASES_PER_PASS
        eq(cap, 25, 'twenty-five a pass')
        -- Every hold idle past its window on the same pass, as half an hour
        -- after a restart: the 2,000-statement pass this caps.
        s.contracts.releaseIdleHolds()
        Env.time = Env.time + 61
        local statements = #Exec.statements
        local first = s.contracts.releaseIdleHolds()
        eq(first, cap, 'one pass releases its share and no more')
        truthy(#Exec.statements - statements < 600, ('the pass sent %d statements (it was 2,002)')
            :format(#Exec.statements - statements))
        local total, passes = first, 1
        while total < #made and passes < 20 do
            Env.time = Env.time + 10
            local n = s.contracts.releaseIdleHolds()
            truthy(n <= cap, 'never more than the share')
            total, passes = total + n, passes + 1
        end
        eq(total, #made, 'and every one goes, a share a pass')
        eq(passes, math.ceil(#made / cap), 'in as few passes as the share allows')
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
        Config.Holds.AppPaused = true
        s.holds.syncAppPause()
        for _ = 1, 10 do
            Env.time = Env.time + 10
            s.contracts.releaseIdleHolds()
        end
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'held through the pause')
        Config.Holds.AppPaused = false
        s.holds.syncAppPause()
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
        truthy(out:match('storage%.prune[^\n]*every 600s'), out)
    end)

    --- What each job sends the database on a tick with nothing to do, on a
    --- busy server (200 live contracts, kill photos on): the early exits,
    --- pinned. [job] = statements at most; a job not listed sends none.
    local IDLE_STATEMENTS = {
        -- Every tick on mysql: when the server was last alive (Recover).
        ['storage.heartbeat'] = 1,
        -- Every 30 s: endings that stopped part-way.
        ['contracts.finishEndings'] = 1,
        -- Once a minute: everybody's time in the city, one transaction of a
        -- row each for the 64 here.
        ['playtime.pass'] = 64,
        -- Each held contract's idle clocks, kept for a restart: a row a
        -- contract at most once a minute, and at most 25 rows a pass
        -- (Contracts.IDLE_CLOCK_WRITES_PER_PASS).
        ['contracts.releaseIdleHolds'] = 25,
    }

    it('sends the database nothing from a job with nothing to do, on a busy mysql server', function()
        local main, s = boot('mysql', function() Config.Completion.KillPhotos = true end)
        city(s)
        main.tick()
        tick(main)
        tick(main)
        local Timing = require('server.timing')
        local run = Timing.run
        for pass = 1, 6 do
            local by = {}
            Timing.run = function(name, fn, ...)
                local from = #Exec.statements
                local out = table.pack(run(name, fn, ...))
                by[name] = (by[name] or 0) + (#Exec.statements - from)
                return table.unpack(out, 1, out.n)
            end
            local ok, err = pcall(tick, main)
            Timing.run = run
            truthy(ok, tostring(err))
            for name, n in pairs(by) do
                truthy(n <= (IDLE_STATEMENTS[name] or 0),
                    ('%s sent %d statement(s) on idle tick %d'):format(name, n, pass))
            end
            -- The jobs this pins by name, each present on the tick.
            for _, name in ipairs({ 'storage.prune', 'photos.expire', 'bailout.processQueue',
                'amendments.expire', 'photo.sweep', 'contracts.retryStuckJoins',
                'contracts.retryStuckClaims', 'contracts.retryStuckCreates', 'review.retryUnwritten',
                'review.decide', 'app.sweepHandles', 'app.sweepFloodCounters', 'expireContracts',
                'contracts.releaseIdleHolds' }) do
                truthy(by[name] ~= nil, name .. ' ran')
            end
        end
    end)
end)

describe('the expiry pass with a player frozen', function()
    --- Sweep 6 J-1: once anybody at all was frozen, the pass asked every live
    --- contract's freeze without the roster it already held, and each read
    --- it again: 0 statements became 200 (16-18 ms) on this city, on every
    --- login, logout, acceptance or hold change for as long as the freeze
    --- lasted. Pinned: the same as with nobody frozen.
    it('sends the database nothing more than with nobody frozen, on a busy mysql server', function()
        local main, s = boot('mysql')
        city(s)
        main.tick()
        tick(main)
        local function pass()
            main.markPresenceChanged()
            local from = #Exec.statements
            main.expire()
            return #Exec.statements - from
        end
        pass()
        local idle = pass()
        Env.addPlayer({ source = 499, citizenid = 'BYSTAND1', license = 'license:bys1' })
        truthy(s.holds.freeze('ADMIN001', 'BYSTAND1', 'unrelated'))
        pass()                                     -- the snapshot read again after the freeze's writes
        local frozen = pass()
        eq(frozen, idle, ('the pass sent %d statements with one player frozen, %d with none')
            :format(frozen, idle))
        eq(frozen, 0, 'the pass reads nothing it already holds')
    end)
end)

--------------------------------------------------------------------------
-- The optional features' jobs (Config.Improvements, Config.Roleplay)
--------------------------------------------------------------------------

--- Every block of Config.Improvements and Config.Roleplay switched on (or
--- off). Put back by resetConfig in the next boot.
local function features(on)
    for _, root in ipairs({ Config.Improvements, Config.Roleplay }) do
        for _, block in pairs(root) do
            if type(block) == 'table' and block.Enabled ~= nil then block.Enabled = on end
        end
    end
end

--- `n` more contracts nobody has taken, on the city's players: what
--- contract decay steps.
local function untaken(s, n)
    for i = 1, n do
        local c = (i - 1) % 20
        local row, err = s.contracts.create(s.identity.resolve(101 + c), { targetCid = ('TGT%05d'):format((c + 11 + (i - 1) // 20) % 20 + 1),
            reason = 'scale', reward = { baseline = { cash = 1000, bank = 1000 } } })
        truthy(row, 'placed: ' .. tostring(err))
    end
end

--- The jobs that exist for an optional feature, each on the tick.
local OPTIONAL_JOBS = { 'imp_board.tick', 'imp_decay.tick', 'imp_weekly.tick', 'rp.tick',
    'rp_intent.sweep', 'rp_protection.sweep', 'informant.retryUnsaved', 'rp_places.announce' }

--- What each of `jobs` cost over `count` ticks of `step` seconds:
--- [job] = { runs, statements (most in one pass), reads (store reads, all
--- passes) }.
local function costs(main, s, count, step, jobs)
    local Timing = require('server.timing')
    local run = Timing.run
    local want = setOf(jobs)
    local by, current = {}, nil
    local reads = {}
    for _, name in ipairs(READS) do
        reads[name] = s.storage[name]
        s.storage[name] = function(...)
            if current then by[current].reads = by[current].reads + 1 end
            return reads[name](...)
        end
    end
    Timing.run = function(name, fn, ...)
        if not want[name] then return run(name, fn, ...) end
        by[name] = by[name] or { runs = 0, statements = 0, reads = 0 }
        local from = Exec.statements and #Exec.statements or 0
        current = name
        local out = table.pack(run(name, fn, ...))
        current = nil
        local n = (Exec.statements and #Exec.statements or 0) - from
        by[name].runs = by[name].runs + 1
        if n > by[name].statements then by[name].statements = n end
        return table.unpack(out, 1, out.n)
    end
    local ok, err = pcall(function()
        for _ = 1, count do
            Env.time = Env.time + step
            Env.gameTimer = Env.gameTimer + step * 1000
            main.tick()
        end
    end)
    Timing.run = run
    for name, f in pairs(reads) do s.storage[name] = f end
    if not ok then error(err, 0) end
    return by
end

describe('the optional features\' jobs', function()
    it('cost nothing with every feature off: no statement and no store read, on a busy mysql server', function()
        local main, s = boot('mysql')
        city(s)
        main.tick()
        local by = costs(main, s, 60, 10, OPTIONAL_JOBS)
        for _, name in ipairs(OPTIONAL_JOBS) do
            truthy(by[name] and by[name].runs > 0, name .. ' ran')
            eq(by[name].statements, 0, name .. ': statements in a pass, features off')
            eq(by[name].reads, 0, name .. ': store reads in ten minutes, features off')
        end
    end)

    it('read nothing of their own with every feature on and nothing due: the shared snapshot only', function()
        local main, s = boot('mysql')
        city(s)
        untaken(s, 100)
        features(true)
        main.tick()
        local by = costs(main, s, 60, 10, OPTIONAL_JOBS)
        for _, name in ipairs(OPTIONAL_JOBS) do
            truthy(by[name] and by[name].runs > 0, name .. ' ran')
            eq(by[name].statements, 0, name .. ': statements in a pass, features on, nothing due')
        end
        -- Contract decay and the board's minute read what is running from
        -- the snapshot the other loops share, never on their own.
        eq(by['imp_decay.tick'].reads, 0, 'contract decay read the store itself')
        eq(by['imp_board.tick'].reads, 0, 'the board\'s minute read the store itself')
    end)

    it('takes at most its share of decay steps a pass, then sleeps until the next is due', function()
        local main, s = boot('mysql')
        city(s)
        untaken(s, 100)
        features(true)
        main.tick()
        local Decay = require('server.imp_decay')
        eq(Decay.STEPS_PER_PASS, 25, 'twenty-five a pass')
        -- An hour on: every untaken contract (100 of the 200) due at once.
        Env.time = Env.time + 3600
        local from = #Exec.statements
        local first = Decay.tick()
        eq(first, 25, 'one pass steps its share and no more')
        truthy(#Exec.statements - from < 400, ('%d statements in the pass (1,951 before the cap)')
            :format(#Exec.statements - from))
        local total, passes = first, 1
        while passes < 10 do
            Env.time = Env.time + 60
            local n = Decay.tick()
            if n == 0 then break end
            truthy(n <= 25, 'never more than the share')
            total, passes = total + n, passes + 1
        end
        eq(total, 100, 'every untaken contract stepped once')
        eq(passes, 4, 'in as few passes as the share allows')
        -- Then asleep: no step is due for an hour, and a pass reads nothing.
        local counts = storeReads(s.storage, function()
            for _ = 1, 30 do
                Env.time = Env.time + 60
                eq(Decay.tick(), 0, 'nothing due')
            end
        end, READS)
        eq(next(counts), nil, 'asleep: no store read')
        -- The first share was stepped 34 minutes ago (four passes and
        -- thirty minutes): its next step is due in 26.
        Env.time = Env.time + 1560
        truthy(Decay.tick() > 0, 'and awake again when the next step is due')
    end)

    it('works the weekly stats\' calendar out once, then sleeps until the post is due', function()
        local main, s = boot('memory')
        fixture(s)
        Config.Improvements.WeeklyStats.Enabled = true
        local Weekly = require('server.imp_weekly')
        local real, asked = Weekly.lastDue, 0
        Weekly.lastDue = function(...)
            asked = asked + 1
            return real(...)
        end
        local ok, err = pcall(function()
            for _ = 1, 30 do tick(main) end
        end)
        Weekly.lastDue = real
        truthy(ok, tostring(err))
        truthy(asked <= 1, ('the calendar worked out %d times in five minutes'):format(asked))
    end)

    it('keeps heat in memory: the board\'s minute prunes nothing before the oldest heat cools', function()
        local _, s = boot('memory')
        local f = fixture(s)
        Config.Improvements.HitmanHeat.Enabled = true
        local Heat = require('server.imp_heat')
        local writes = 0
        local real = s.storage.writeRpRow
        s.storage.writeRpRow = function(...)
            writes = writes + 1
            return real(...)
        end
        local ok, err = pcall(function()
            Heat.add(f.hitman.cid, 1, 'test')
            writes = 0
            for _ = 1, 10 do
                Env.time = Env.time + 60
                Heat.tick()
            end
            eq(writes, 0, 'nothing cooled, nothing written')
            Env.time = Env.time + 25 * 3600
            Heat.tick()
            eq(writes, 0, 'cooled: its row taken away, not written')
            eq(Heat.of(f.hitman.cid), 0, 'and it has none')
        end)
        s.storage.writeRpRow = real
        truthy(ok, tostring(err))
    end)
end)

--------------------------------------------------------------------------
-- The client's NPC loop
--------------------------------------------------------------------------

describe('the client\'s NPC loop', function()
    --- The file loaded in an environment of its own, with every thread it
    --- starts kept so a test can step it: { handlers, threads, step, me,
    --- loop, peds, state }.
    local function npcClient()
        local t = { handlers = {}, threads = {}, me = { x = 5000.0, y = 0.0, z = 0.0 },
                    peds = {}, made = 0, vectors = 0, state = { isLoggedIn = true } }
        local function vec(x, y, z)
            t.vectors = t.vectors + 1
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
            CreatePed = function() t.made = t.made + 1; t.peds[100 + t.made] = true; return 100 + t.made end,
            DoesEntityExist = function(ped) return t.peds[ped] and 1 or false end,
            DeleteEntity = function(ped) t.peds[ped] = nil end,
            SetEntityInvincible = function() end, FreezeEntityPosition = function() end,
            SetBlockingOfNonTemporaryEvents = function() end, SetPedCanRagdoll = function() end,
            TaskStartScenarioInPlace = function() end,
            AddBlipForCoord = function() return 1 end, SetBlipSprite = function() end,
            SetBlipScale = function() end, SetBlipAsShortRange = function() end,
            BeginTextCommandSetBlipName = function() end,
            AddTextComponentSubstringPlayerName = function() end,
            EndTextCommandSetBlipName = function() end, RemoveBlip = function() end,
            DoesBlipExist = function() return 1 end, SetBlipColour = function() end,
            GetEntityCoords = function() return vec(t.me.x, t.me.y, t.me.z) end,
            PlayerPedId = function() return 1 end,
            LocalPlayer = { state = t.state },
            vector3 = vec,
            Wait = function(ms) coroutine.yield(ms) end,
            SetTimeout = function() end,
            TriggerServerEvent = function() end,
            RegisterNetEvent = function(name, fn) t.handlers[name] = fn end,
            AddEventHandler = function(name, fn) t.handlers[name] = fn end,
            GetCurrentResourceName = function() return 'crimson-hitman' end,
            CreateThread = function(fn) t.threads[#t.threads + 1] = coroutine.create(fn) end,
        }, { __index = _G })
        -- As the manifest loads them: CrimsonGeo, CrimsonMarkers (the blips)
        -- and CrimsonNpc before client/rp_npc.lua.
        assert(loadfile('crimson-hitman/shared/geo.lua', 't', env))()
        assert(loadfile('crimson-hitman/client/missionsteps.lua', 't', env))()
        assert(loadfile('crimson-hitman/client/npc.lua', 't', env))()
        t.loop = assert(loadfile('crimson-hitman/client/rp_npc.lua', 't', env))()
        t.markers = env.CrimsonMarkers
        --- Run thread `i` to its next wait: the wait, or 'ended'.
        function t.step(i)
            local co = t.threads[i]
            local ok, ms = coroutine.resume(co)
            truthy(ok, 'the loop raised: ' .. tostring(ms))
            if coroutine.status(co) == 'dead' then return 'ended' end
            return ms
        end
        function t.place(data)
            t.handlers['crimson-hitman:result']({ event = 'rpPlaces', ok = true, data = data })
        end
        return t
    end

    local BROKER = { broker = { x = 0.0, y = 0.0, z = 0.0, model = 'g_m_m_armboss_01', scenario = '' } }

    it('runs no loop at all while both NPCs are off', function()
        local t = npcClient()
        eq(#t.threads, 1, 'one thread at load: the question at start')
        eq(t.step(1), 5000, 'it waits for the server to be up')
        eq(t.step(1), 'ended', 'asks once, and ends')
        t.place({})
        eq(#t.threads, 1, 'nothing placed: no distance loop is started')
        falsy(t.loop.running(), 'and none is running')
    end)

    it('marks an NPC with a blip through the one marker system, and takes it off with the NPC', function()
        local t = npcClient()
        t.step(1); t.step(1)
        t.place({ broker = { x = 1.0, y = 2.0, z = 3.0, model = 'g_m_m_armboss_01', scenario = '', blip = true },
            informant = { x = 4.0, y = 5.0, z = 6.0, model = 'a_m_y_hipster_01', scenario = '' } })
        local broker = t.markers.get('npc:broker')
        truthy(broker, 'the broker\'s blip is a marker')
        eq(broker.x, 1.0)
        eq(t.markers.get('npc:informant'), nil, 'no blip where the server says none')
        t.handlers['QBCore:Client:OnPlayerUnload']()
        truthy(t.markers.get('npc:broker'), 'a logout leaves the map\'s own blip')
        t.place({})
        eq(t.markers.get('npc:broker'), nil, 'gone with the NPC')
    end)

    it('sleeps two seconds while nothing is near, and one second near an NPC', function()
        local t = npcClient()
        t.step(1); t.step(1)
        t.place(BROKER)
        eq(#t.threads, 2, 'an NPC placed starts the loop')
        truthy(t.loop.running(), 'running')
        eq(t.step(2), 2000, 'placed, but five kilometres off: every two seconds')
        t.me.x = 150.0
        eq(t.step(2), 1000, 'inside 160 m: every second, so it is drawn before the player arrives')
        t.me.x = 10.0
        eq(t.step(2), 1000, 'drawn: every second, so it is removed when they leave')
        eq(t.made, 1, 'the ped was made')
        t.place(BROKER)
        eq(#t.threads, 2, 'a second answer starts no second loop')
    end)

    it('ends the loop when the NPCs are switched off, and starts it again when one comes back', function()
        local t = npcClient()
        t.step(1); t.step(1)
        t.place(BROKER)
        t.me.x = 10.0
        eq(t.step(2), 1000, 'drawn')
        t.place({})
        eq(next(t.peds), nil, 'switched off: the ped is gone at once')
        eq(t.step(2), 'ended', 'and the loop ends on its next pass')
        falsy(t.loop.running(), 'nothing running')
        t.place(BROKER)
        eq(#t.threads, 3, 'placed again: a loop again')
        eq(t.step(3), 1000, 'and it draws the NPC beside the player')
    end)

    it('makes one vector a pass for the player, none for the places', function()
        local t = npcClient()
        t.step(1); t.step(1)
        t.place({ broker = BROKER.broker, informant = { x = 3000.0, y = 0.0, z = 0.0, model = 'a', scenario = '' } })
        t.step(2)
        local before = t.vectors
        t.step(2)
        -- The player's coords, and one difference per place.
        eq(t.vectors - before, 3, 'no vector made for a place on a pass')
    end)

    it('takes the ped away at logout and draws nothing between characters', function()
        local t = npcClient()
        t.step(1); t.step(1)
        t.place(BROKER)
        t.me.x = 10.0
        t.step(2)
        eq(t.made, 1, 'drawn')
        t.state.isLoggedIn = false
        t.handlers['qbx_core:client:playerLoggedOut']()
        eq(next(t.peds), nil, 'gone at logout')
        t.step(2)
        eq(t.made, 1, 'not drawn again on the character screen')
        t.state.isLoggedIn = true
        t.step(2)
        eq(t.made, 2, 'drawn again for the next character')
    end)
end)

--------------------------------------------------------------------------
-- The budget
--------------------------------------------------------------------------

--- What a whole maintenance pass may take, every job due at once, plus one
--- condition sampler pass, with 200 live contracts and 64 players in the
--- city: the WORST of seven passes, in milliseconds of this process's
--- processor time, since one slow pass is a hitch whatever the others did.
--- Measured at about 10 ms on json and 30 to 45 ms on mysql at the worst
--- (whose figure includes this harness running every statement in Lua,
--- which a real database does elsewhere: the playtime pass's batch of 64
--- upserts is most of it) on the machine the change was made on; the
--- budget leaves twice that and more for a slower or busier one.
---
--- And the worst pass of all: every hold idle past its window and every
--- contract past its lifetime on the same tick, as after a long outage. The
--- releases and the endings are capped a pass (Contracts.IDLE_RELEASES_PER_PASS,
--- EXPIRIES_PER_PASS), so that pass ends a share of them, not two hundred in
--- one frame (about a second on json, 5,600 statements on mysql, before).
local BUDGET_MS = 100
--- Measured at about 100 ms on json and 400 ms on mysql (the harness's
--- Lua database again: a real one does that work off the server thread).
local MASS_BUDGET_MS = { json = 300, mysql = 1000 }
--- With every optional feature on, the worst pass is the one an hour on,
--- where the untaken contracts' decay steps fall due: a share of 25 'rise'
--- steps, each a charge with its escrow and notice. Measured at about 100
--- ms on json and 150 ms on mysql (harness), with the rest of the tick; the
--- passes with nothing due at 5 to 17 ms and 19 to 28 ms, as with them off.
local BUDGET_ON_MS = { json = 300, mysql = 450 }

describe('a whole maintenance pass on a busy server', function()
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(('stays inside %d ms on %s at its worst, every job due, 200 contracts and 64 players')
            :format(BUDGET_MS, mode), function()
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
                if os.getenv('CH_PERF') then
                    local shown = {}
                    for i = 1, #passes do shown[i] = ('%.1f'):format(passes[i]) end
                    io.write(('\n  passes on %s: %s ms\n'):format(mode, table.concat(shown, ', ')))
                end
                table.sort(passes)
                local worst = passes[#passes]
                truthy(worst < BUDGET_MS, ('the worst pass took %.1f ms on %s (budget %d ms)')
                    :format(worst, mode, BUDGET_MS))
            end)

        it(('stays inside %d ms on %s at its worst with every optional feature on'):format(BUDGET_ON_MS[mode], mode),
            function()
                local main, s = boot(mode)
                city(s)
                untaken(s, 100)
                features(true)
                main.tick()
                local death = require('server.completion.death')
                local passes = {}
                -- Ten minutes a pass for an hour and more: every scheduled
                -- job due, and on the sixth an hour's decay steps (their
                -- share, Decay.STEPS_PER_PASS).
                for i = 1, 7 do
                    Env.time = Env.time + 600
                    Env.gameTimer = Env.gameTimer + 600000
                    local started = os.clock()
                    main.tick()
                    death.watchTargets(s.storage.liveContracts(), s.storage.liveHitmen())
                    passes[i] = (os.clock() - started) * 1000
                end
                if os.getenv('CH_PERF') then
                    local shown = {}
                    for i = 1, #passes do shown[i] = ('%.1f'):format(passes[i]) end
                    io.write(('\n  passes on %s, features on: %s ms\n'):format(mode, table.concat(shown, ', ')))
                end
                table.sort(passes)
                truthy(passes[#passes] < BUDGET_ON_MS[mode], ('the worst pass took %.1f ms on %s with every '
                    .. 'feature on (budget %d ms)'):format(passes[#passes], mode, BUDGET_ON_MS[mode]))
            end)

        it(('ends at most its share on %s when everything falls due at once'):format(mode), function()
            local main, s = boot(mode, function()
                Config.Limits.ExclusiveIdleReleaseSeconds = 60
                Config.Limits.ExclusiveAttemptWindowSeconds = 0
            end)
            city(s)
            main.tick()
            -- Past every lifetime: each contract ends on the passes below.
            Env.time = Env.time + Config.Limits.ContractLifetimeSeconds + 60
            Env.gameTimer = Env.gameTimer + 600000
            main.markPresenceChanged()
            local from = mode == 'mysql' and #Exec.statements or 0
            local started = os.clock()
            main.tick()
            local ms = (os.clock() - started) * 1000
            local live = #s.storage.liveContracts()
            truthy(live >= 200 - 2 * 25, ('%d of 200 still running after the first pass'):format(live))
            truthy(live < 200, 'and some ended')
            truthy(ms < MASS_BUDGET_MS[mode], ('the pass took %.1f ms on %s (budget %d ms)')
                :format(ms, mode, MASS_BUDGET_MS[mode]))
            if mode == 'mysql' then
                local n = #Exec.statements - from
                truthy(n < 2000, ('%d statements in one pass (5,602 before the caps)'):format(n))
            end
            if os.getenv('CH_PERF') then
                io.write(('\n  mass pass %s: %.1f ms, %s statements\n'):format(mode, ms,
                    mode == 'mysql' and tostring(#Exec.statements - from) or '-'))
            end
        end)
    end
end)
