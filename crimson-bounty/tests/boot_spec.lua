--- The real boot path.
---
--- Every other suite wires the modules itself, which is faster but means
--- main.lua — the file a live server actually loads — was never once
--- executed. It contained a call to a `local function` declared eighty lines
--- below the call site, which in Lua is a nil global: the resource would
--- have thrown on startup while 342 tests passed.
---
--- These load main.lua and run it.

local function boot()
    -- Fresh every time: main.lua holds module-level state (the expiry pass's
    -- next-due mark, the host-refresh clock) that must not leak between
    -- tests any more than a contract may.
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
            package.loaded[name] = nil
        end
    end
    package.loaded['server.main'] = nil

    Env.reset()
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Natives.resetResourceStates()
    resetConfig()

    -- start() picks its backend from the config, which ships as mysql. The
    -- harness has no database, so these run against the in-process store —
    -- the same one the mysql and json backends are held to by the storage
    -- conformance suite.
    Config.Database.Mode = 'memory'

    local main = require('server.main')
    return main, main.start()
end

describe('the real boot path', function()
    it('starts without throwing', function()
        local main, modules = boot()
        truthy(modules, 'start() should return the wired modules')
        truthy(modules.contracts and modules.escrow and modules.app,
            'and wire the modules the rest of the resource needs')
    end)

    it('wires the app, which every handler depends on', function()
        local main, modules = boot()
        -- App.canUseApp reaches through deps. Uninitialised it throws on a
        -- nil index, which is what the harness's own wiring used to hide.
        local ok = pcall(function() return modules.app.canUseApp(1) end)
        truthy(ok, 'the app must be initialised by start()')
    end)

    it('runs a maintenance tick against a live contract', function()
        local main, modules = boot()
        local f = fixture(modules)
        local c = modules.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c, 'a contract to tick over')

        -- The whole tick: audit flush, amendment expiry, bailout queue,
        -- photo sweep, death sweep, rate-limit sweep, handle sweeps, expiry.
        local ok, err = pcall(main.tick)
        truthy(ok, 'the tick must not throw: ' .. tostring(err))
        eq(modules.storage.readContract(c.id).state, CB.STATE.ACTIVE, 'and not eat a live contract')
    end)

    it('recovers without throwing on an empty store', function()
        local main = boot()
        local ok, err = pcall(main.recover)
        truthy(ok, tostring(err))
    end)
end)

describe('contract expiry', function()
    local function bootWithContract(overrides)
        local main, modules = boot()
        local f = fixture(modules)
        local c = modules.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c)
        for key, value in pairs(overrides or {}) do
            local row = modules.storage.readContract(c.id)
            row[key] = value
            modules.storage.writeContract(row)
        end
        return main, modules, f, c
    end

    it('closes a contract past its deadline and returns the escrow', function()
        local main, modules, f, c = bootWithContract({ deadline_at = Env.time - 1 })
        local before = Env.players[1].PlayerData.money.cash + Env.players[1].PlayerData.money.bank

        eq(main.expire(), 1, 'the overdue contract closes')
        eq(modules.storage.readContract(c.id).state, CB.STATE.EXPIRED)

        local after = Env.players[1].PlayerData.money.cash + Env.players[1].PlayerData.money.bank
        eq(after - before, 5000, 'and the creator has their escrow back')
    end)

    it('leaves a contract that is not due', function()
        local main, modules, f, c = bootWithContract({ deadline_at = Env.time + 3600 })
        eq(main.expire(), 0)
        eq(modules.storage.readContract(c.id).state, CB.STATE.ACTIVE)
    end)

    it('enforces the absolute lifetime even while the clock is paused', function()
        local main, modules, f, c = bootWithContract({
            expires_at = Env.time - 1,
            deadline_at = Env.time + 86400,
        })
        -- Nobody is online to unpause it; the ceiling applies regardless,
        -- or a contract whose creator never returns holds its escrow forever.
        Env.players[1] = nil
        Env.players[2] = nil

        eq(main.expire(), 1, 'the lifetime ceiling does not pause')
        eq(modules.storage.readContract(c.id).state, CB.STATE.EXPIRED)
    end)

    it('skips the pass when nothing could have changed', function()
        local main, modules, f, c = bootWithContract({ deadline_at = Env.time + 3600 })
        eq(main.expire(), 0, 'first pass establishes when the next thing is due')

        -- A pass that would find something is never skipped: make it due and
        -- move the clock past the skip, which is what a real tick does.
        local reads = 0
        local realAll = modules.storage.allContracts
        modules.storage.allContracts = function(...) reads = reads + 1 return realAll(...) end

        main.expire()
        eq(reads, 0, 'with nothing due and nobody moving, the table is not read')

        modules.storage.allContracts = realAll
    end)

    it('never skips past a deadline that has come due', function()
        local main, modules, f, c = bootWithContract({ deadline_at = Env.time + 30 })
        eq(main.expire(), 0, 'not due yet')

        -- The skip is bounded by the earliest deadline, so advancing past it
        -- must find the contract however quiet the server has been.
        Env.time = Env.time + 31
        eq(main.expire(), 1, 'the deadline is honoured, not skipped over')
        eq(modules.storage.readContract(c.id).state, CB.STATE.EXPIRED)
    end)

    it('re-reads within the ceiling even with nothing to expire', function()
        local main, modules = boot()
        -- No contracts at all: nothing pulls the next-due mark in, so the
        -- ceiling is the only thing bounding how stale the pass's answer
        -- gets. Without it a quiet server would stop looking entirely.
        eq(main.expire(), 0)

        local reads = 0
        local realAll = modules.storage.allContracts
        modules.storage.allContracts = function(...) reads = reads + 1 return realAll(...) end

        Env.time = Env.time + Config.Limits.MaxDeadlineSkipSeconds + 2
        main.expire()
        eq(reads, 1, 'the pass must come back inside the ceiling')

        modules.storage.allContracts = realAll
    end)

    it('never skips past a contract created after the last pass', function()
        local main, modules, f, c = bootWithContract({ deadline_at = Env.time + 3600 })
        eq(main.expire(), 0, 'the pass now believes nothing is due for an hour')

        -- A new contract with a much nearer deadline must not wait out the
        -- skip the previous pass established.
        local c2 = modules.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'second',
            reward = { baseline = { cash = 1000 } },
        })
        truthy(c2)
        local row = modules.storage.readContract(c2.id)
        row.deadline_at = Env.time - 1
        modules.storage.writeContract(row)

        eq(main.expire(), 1, 'creating a contract reopens the pass')
        eq(modules.storage.readContract(c2.id).state, CB.STATE.EXPIRED)
    end)
end)


--- One failing maintenance job must not stop the others.
---
--- The tick runs the audit flush, amendment expiry, the bailout queue, every
--- sweep, contract expiry and the storage flush, in that order, under a
--- single pcall. A throw anywhere in it skipped everything after — including
--- the storage flush, so nothing was persisted at all — and kept skipping it
--- on every subsequent tick, because the thing that threw was still there.
--- The resource goes on printing nothing and doing nothing.
describe('a maintenance job that throws', function()
    it('does not stop the rest of the tick', function()
        local main, modules = boot()
        local f = fixture(modules)
        local c = modules.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c)

        -- The audit flush is the first job the tick runs, and the one that
        -- talks to the database on every single tick.
        local realWrite = modules.storage.writeAudit
        modules.storage.writeAudit = function() error('database went away') end
        modules.audit.rejected('probe', 'CREATOR1', c.id, {})

        local flushed = false
        local realStorageFlush = modules.storage.flush
        modules.storage.flush = function(...)
            flushed = true
            if realStorageFlush then return realStorageFlush(...) end
            return true
        end

        -- Run the contract past its deadline so expiry has real work to do.
        local row = modules.storage.readContract(c.id)
        row.deadline_at = os.time() - 60
        modules.storage.writeContract(row)

        local ok, err = pcall(main.tick)

        modules.storage.writeAudit = realWrite
        modules.storage.flush = realStorageFlush

        truthy(ok, 'the tick itself must survive: ' .. tostring(err))
        truthy(flushed, 'the storage flush must still run after an audit write fails')
        eq(modules.storage.readContract(c.id).state, CB.STATE.EXPIRED,
            'and the contract past its deadline must still be closed')
    end)

    it('does not stop the rest of the tick when it is not the audit flush', function()
        -- The audit flush is only the first job. Any of them can throw — a
        -- sweep over a row a future migration left half-written, an export
        -- from an integration that reloaded mid-call — and the storage flush
        -- is last, so it is what every one of them stands in front of.
        local main, modules = boot()
        local f = fixture(modules)
        local c = modules.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c)

        local realExpire = modules.amendments.expire
        modules.amendments.expire = function() error('a sweep went wrong') end

        local flushed = false
        local realStorageFlush = modules.storage.flush
        modules.storage.flush = function(...)
            flushed = true
            if realStorageFlush then return realStorageFlush(...) end
            return true
        end

        local row = modules.storage.readContract(c.id)
        row.deadline_at = os.time() - 60
        modules.storage.writeContract(row)

        local ok, err = pcall(main.tick)

        modules.amendments.expire = realExpire
        modules.storage.flush = realStorageFlush

        truthy(ok, 'the tick must survive: ' .. tostring(err))
        truthy(flushed, 'the storage flush must still run')
        eq(modules.storage.readContract(c.id).state, CB.STATE.EXPIRED,
            'and contract expiry must still have run')
    end)

    it('is true of every job in the tick, not just the two tested above', function()
        -- Every job the tick runs, named the way the tick names it. Broken
        -- one at a time; the storage flush is last, so it standing in for
        -- "the rest of the tick still ran" is exactly the property at stake.
        local JOBS = {
            { 'audit',      'flush' },
            { 'amendments', 'expire' },
            { 'bailout',    'processQueue' },
            { 'photo',      'sweep' },
            { 'death',      'sweep' },
            { 'ratelimit',  'sweep' },
            { 'ledger',     'forgetOldPhotos' },
        }

        for i = 1, #JOBS do
            local module, name = JOBS[i][1], JOBS[i][2]
            local main, modules = boot()

            truthy(modules[module], 'no such module: ' .. module)
            truthy(modules[module][name], ('no such job: %s.%s'):format(module, name))
            modules[module][name] = function()
                error(('%s.%s went wrong'):format(module, name))
            end

            local flushed = false
            local realStorageFlush = modules.storage.flush
            modules.storage.flush = function(...)
                flushed = true
                if realStorageFlush then return realStorageFlush(...) end
                return true
            end

            local ok, err = pcall(main.tick)
            modules.storage.flush = realStorageFlush

            truthy(ok, ('the tick must survive a failing %s.%s: %s')
                :format(module, name, tostring(err)))
            truthy(flushed,
                ('the storage flush must still run when %s.%s throws'):format(module, name))
        end
    end)

    it('does not keep throwing on the same row forever', function()
        local main, modules = boot()
        local f = fixture(modules)

        local realWrite = modules.storage.writeAudit
        modules.storage.writeAudit = function() error('database went away') end
        modules.audit.rejected('probe', 'CREATOR1', nil, {})
        pcall(main.tick)
        modules.storage.writeAudit = realWrite

        eq(modules.audit.pending(), 0,
            'an entry that cannot be written is dropped, not retried forever — '
            .. 'otherwise every later entry is stuck behind it')

        -- And the log keeps working once the database is back.
        modules.audit.rejected('after', 'CREATOR1', nil, {})
        pcall(main.tick)
        local rows = modules.storage.readAudit(50)
        local seen = false
        for i = 1, #rows do
            if rows[i].action == 'after' then seen = true end
        end
        truthy(seen, 'entries after the failure must still reach the log')
    end)

    it('counts what it could not write, rather than losing it silently', function()
        local main, modules = boot()
        fixture(modules)

        local realWrite = modules.storage.writeAudit
        local refused = 0
        modules.storage.writeAudit = function(entry)
            if entry.action == 'probe' then
                refused = refused + 1
                error('database went away')
            end
            return realWrite(entry)
        end
        modules.audit.rejected('probe', 'CREATOR1', nil, {})
        pcall(main.tick)
        modules.storage.writeAudit = realWrite

        eq(refused, 1)
        local rows = modules.storage.readAudit(50)
        local overflow = false
        for i = 1, #rows do
            if rows[i].action == 'audit_overflow' then overflow = true end
        end
        truthy(overflow, 'a dropped audit row must be reported, because a log with '
            .. 'silent gaps is worse than no log')
    end)
end)


--- The configuration an operator edited.
---
--- Config values go straight into arithmetic. A key deleted or misspelled
--- while editing is nil, and nil does not fail at startup — it fails deep
--- inside whichever handler reaches that line first, as an error in a
--- player's face with nothing to say which setting caused it.
describe('starting on a configuration with a hole in it', function()
    --- Boot with one setting broken, capturing what the console was told.
    local function bootExpectingFailure(section, key, value)
        for name in pairs(package.loaded) do
            if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
                package.loaded[name] = nil
            end
        end
        package.loaded['server.main'] = nil

        Env.reset()
        Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
        Natives.resetResourceStates()
        resetConfig()
        Config.Database.Mode = 'memory'

        local saved = Config[section][key]
        Config[section][key] = value

        -- The fatal lines go to the console, and the console is what an
        -- operator actually reads.
        local said = {}
        local realPrint = _G.print
        _G.print = function(...)
            local parts = {}
            for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
            said[#said + 1] = table.concat(parts, ' ')
        end

        local main = require('server.main')
        local ok, err = pcall(main.start)

        _G.print = realPrint
        Config[section][key] = saved
        resetConfig()
        return ok, tostring(err), table.concat(said, ' | ')
    end

    it('refuses to start when a number it does arithmetic on is missing', function()
        local ok, err = bootExpectingFailure('Limits', 'MaxPayoutSlots', nil)
        falsy(ok, 'a missing limit must stop startup, not the first player who hits it')
        truthy(err:find('invalid configuration', 1, true), err)
    end)

    it('names the setting rather than the line that threw', function()
        local ok, _, said = bootExpectingFailure('Completion', 'PhotoTokenLifetimeSeconds', nil)
        falsy(ok)
        truthy(said:find('Completion.PhotoTokenLifetimeSeconds', 1, true),
            'the operator has to be told which setting, not which line: ' .. said)
        truthy(said:find('nil', 1, true), 'and what is wrong with it: ' .. said)
    end)

    it('refuses a number that has been set to something that is not one', function()
        local ok, err = bootExpectingFailure('Bailout', 'MaxMultiplier', 'ten')
        falsy(ok, 'a string where a number belongs is the same hole')
        truthy(err:find('invalid configuration', 1, true), err)
    end)

    it('still starts on the configuration as it ships', function()
        local main, modules = boot()
        truthy(modules, 'the shipped config must be valid')
        truthy(main)
    end)
end)

--- Boot against a config missing any single setting.
---
--- applyConfigDefaults fills whole sections an operator's config does not
--- have at all, plus a curated list of individual keys. Everything else is
--- read directly, and a config that carries a section but not one of its
--- keys is the ordinary result of drift: config.lua stops tracking the
--- shipped one the moment it is edited.
---
--- Three keys crashed boot rather than being filled or reported, and all
--- three crashed inside the validation — the code whose whole job is to say
--- what is wrong with a configuration was itself the thing that fell over
--- on one, taking cb-diag down with it.
---
--- A deliberate refusal that names the setting is an acceptable outcome
--- here; an unhandled error is not. Operators are told what to fix, or the
--- gap is filled and printed. They are never handed a stack trace.
describe('a config that has drifted a key at a time', function()
    local function sectionsOf()
        local names = {}
        if type(ConfigDefaults) ~= 'table' then return names end
        for section in pairs(ConfigDefaults) do
            if type(ConfigDefaults[section]) == 'table' then names[#names + 1] = section end
        end
        table.sort(names)
        return names
    end

    --- Both storage backends the harness can run.
    ---
    --- The first version of this swept memory mode only, because boot()
    --- forces it — and json mode reads Config.Database.Json.Directory from
    --- the first line of its open(), which memory mode never touches. So
    --- the one hole this sweep was written to close stayed open: a Database
    --- section without its Json block took the resource down at boot, past
    --- the validation meant to catch exactly that.
    local MODES = { 'memory', 'json' }

    it('starts, or says what is wrong, with any one key removed', function()
        local sections = sectionsOf()
        truthy(#sections > 10,
            'the shipped defaults have to be readable for this to mean '
            .. 'anything, got ' .. #sections .. ' sections')

        local crashed, tried = {}, 0
        for _, mode in ipairs(MODES) do
            for _, section in ipairs(sections) do
                local keys = {}
                for key in pairs(ConfigDefaults[section]) do keys[#keys + 1] = tostring(key) end
                table.sort(keys)

                for _, key in ipairs(keys) do
                    boot()
                    Config.Database.Mode = mode
                    if type(Config[section]) == 'table' then
                        tried = tried + 1
                        Config[section][key] = nil
                        local ok, err = pcall(function()
                            package.loaded['server.main'] = nil
                            local main = require('server.main')
                            return main.start()
                        end)
                        if not ok then
                            local message = tostring(err)
                            -- A refusal names the setting. A crash does not.
                            if not message:find('refusing to start on an invalid configuration', 1, true) then
                                crashed[#crashed + 1] =
                                    ('[%s] Config.%s.%s -> %s'):format(mode, section, key, message)
                            end
                        end
                    end
                end
            end
        end

        -- Counted, so a loop that stopped matching cannot read as a clean
        -- result: this sweep says nothing if it swept nothing.
        truthy(tried > 200,
            'this swept only ' .. tried .. ' keys across ' .. #MODES .. ' storage '
            .. 'modes, which is the loop having stopped rather than the config '
            .. 'having shrunk')

        resetConfig()
        eq(#crashed, 0,
            'a config missing one setting has to be filled or reported, never '
            .. 'crashed on: ' .. table.concat(crashed, ' | '))
    end)
end)

--- The same sweep, but measured at the handlers rather than at boot.
---
--- A key can be absent, boot cleanly, and take a request down the first
--- time somebody opens the app. Config.Listing.PageSize is read straight
--- into arithmetic in Projection.listing, so without it `list` throws — the
--- home screen, for every player, on every request — while the boot sweep
--- above reports a clean start.
---
--- Memory mode only: which backend is behind the handler does not change
--- which config key it indexes, and this is already the most expensive
--- test in the suite.
describe('a config that has drifted a key the handlers read', function()
    --- Enough of the surface to reach the config the app actually touches
    --- on a normal session, with a contract to talk about.
    local CALLS = {
        { 'list', { page = 1 } }, { 'mine', {} }, { 'ledger', {} },
        { 'rewardOptions', {} }, { 'searchTargets', { query = 'Dana' } },
        { 'browseTargets', { scope = 'all', page = 1 } },
        { 'browseTargets', { scope = 'nearby', page = 1 } },
        -- Placing one is the only path that reads the advisory recipient
        -- job sets, and it needs a handle the browse above actually minted:
        -- an invented one is refused before it gets anywhere near them.
        { 'create', function(handle)
            return { target = handle, reason = 'Unpaid debt', mode = 'exclusive',
                     reward = { slots = { { baseline = { cash = 1000 } } } } }
        end },
        { 'threads', { id = 'ct00000001' } },
        { 'amendments', { id = 'ct00000001' } },
        { 'rewardBreakdown', { id = 'ct00000001' } },
        { 'informant', { id = 'ct00000001' } },
        { 'bailout', { id = 'ct00000001' } },
        { 'accept', { id = 'ct00000001' } },
        { 'cancel', { id = 'ct00000001' } },
        { 'armKidnap', { id = 'ct00000001' } },
        { 'kidnapProgress', { id = 'ct00000001' } },
        { 'requestPhotoToken', { id = 'ct00000001' } },
    }

    --- A refusal is fine. A crash is not.
    ---
    --- Read from the reply rather than from pcall: handler() wraps every
    --- body in its own pcall and answers server_error, precisely so one bad
    --- request cannot take the net event down. That also means firing the
    --- event never raises, so a sweep watching for a raised error watches
    --- for something that cannot happen and passes on a handler that throws
    --- every time.
    local function drive()
        local broke = {}
        local handle

        for _, call in ipairs(CALLS) do
            local fire = Env.events['crimson-bounty:' .. call[1]]
            if fire then
                local payload = call[2]
                if type(payload) == 'function' then payload = payload(handle) end

                Env.clientEvents = {}
                _G.source = 1
                local ok, err = pcall(fire, payload)
                _G.source = nil

                if not ok then
                    broke[#broke + 1] = call[1] .. ' threw: ' .. tostring(err)
                else
                    for _, event in ipairs(Env.clientEvents) do
                        local reply = event.args and event.args[1]
                        if event.name == 'crimson-bounty:result' and reply then
                            if reply.err == CB.ERR.SERVER_ERROR then
                                broke[#broke + 1] = call[1] .. ' answered server_error'
                            end
                            -- Remember a real target handle for the create
                            -- below. They are minted per searcher and expire,
                            -- so one written into the test would be refused
                            -- before reaching the code this is measuring.
                            local people = reply.data and reply.data.people
                            if type(people) == 'table' then
                                for _, person in ipairs(people) do
                                    handle = person.handle or handle
                                end
                            end
                        end
                    end
                end
            end
        end
        return broke
    end

    it('answers every request with any one key removed', function()
        local sections = {}
        for section in pairs(ConfigDefaults) do
            if type(ConfigDefaults[section]) == 'table' then sections[#sections + 1] = section end
        end
        table.sort(sections)

        local broken, tried = {}, 0
        for _, section in ipairs(sections) do
            local keys = {}
            for key in pairs(ConfigDefaults[section]) do keys[#keys + 1] = tostring(key) end
            table.sort(keys)

            for _, key in ipairs(keys) do
                boot()
                Config.Database.Mode = 'memory'
                if type(Config[section]) == 'table' then
                    Config[section][key] = nil
                    local started, modules = pcall(function()
                        package.loaded['server.main'] = nil
                        local main = require('server.main')
                        return main.start()
                    end)
                    -- A config that cannot boot is the sweep above's
                    -- business, not this one's.
                    if started and modules and modules.identity then
                        tried = tried + 1
                        fixture(modules)
                        -- An officer on duty, so the advisory recipient
                        -- rules are actually reached. Without one,
                        -- Identity.isAdvisoryRecipient is never called and
                        -- the two job sets it indexes read as covered while
                        -- nothing touches them.
                        Env.addPlayer({ source = 20, citizenid = 'OFFICER1',
                            license = 'license:leo', firstname = 'Kay',
                            lastname = 'Mercer',
                            job = { name = 'police', type = 'leo', onduty = true } })
                        local threw = drive()
                        for _, message in ipairs(threw) do
                            broken[#broken + 1] =
                                ('Config.%s.%s -> %s'):format(section, key, message)
                        end
                    end
                end
            end
        end

        truthy(tried > 100,
            'this drove handlers for only ' .. tried .. ' keys, which is the '
            .. 'loop having stopped rather than the config having shrunk')

        resetConfig()
        eq(#broken, 0,
            'a missing setting must not throw inside a request: '
            .. table.concat(broken, ' | '))
    end)
end)

--- Somebody is actually told about a contract that could not be loaded.
---
--- Refusing to start on an unreadable shard was replaced by starting and
--- reporting it, on the argument that what the refusal really bought was
--- the operator's attention — and that this buys it instead. Two places
--- implement that: the boot banner and the diagnosis command.
---
--- Neither had a test. Replacing the lookup with an empty table in either
--- file left the whole suite green, so the mechanism that justified
--- removing the abort was the one thing nothing checked.
describe('telling somebody a contract could not be loaded', function()
    --- A store with one shard missing, opened, so quarantined() has
    --- something in it.
    local function withOneLost()
        Natives.files = {}
        package.loaded['crimson-bounty.server.storage.json'] = nil
        local store = require('crimson-bounty.server.storage.json')
        store.open()
        store.writeContract({ id = 'ct00000009', creator_cid = 'CREATOR1',
            target_cid = 'TARGET01', mode = CB.MODE.EXCLUSIVE,
            state = CB.STATE.ACTIVE, created_at = os.time() })
        store.close()
        Natives.files['data/contracts/ct00000009.json'] = nil

        package.loaded['crimson-bounty.server.storage.json'] = nil
        local reopened = require('crimson-bounty.server.storage.json')
        reopened.open()
        return reopened
    end

    it('names it in the boot banner', function()
        boot()
        Config.Database.Mode = 'json'
        withOneLost()

        Env.console = {}
        package.loaded['server.main'] = nil
        local main = require('server.main')
        main.start()

        local said = table.concat(Env.console, '\n')
        truthy(said:find('COULD NOT BE LOADED', 1, true),
            'the resource started without a contract and said nothing about '
            .. 'it: ' .. said)
        truthy(said:find('ct00000009', 1, true),
            'a warning that does not name the contract is one nobody can act '
            .. 'on: ' .. said)
        truthy(said:find('backup', 1, true),
            'and it has to say what to do about it')
    end)

    it('names it in the diagnosis command', function()
        boot()
        Config.Database.Mode = 'json'
        withOneLost()

        package.loaded['server.main'] = nil
        local main = require('server.main')
        local modules = main.start()

        local lines = table.concat(modules.admin.diagnose(1), '\n')
        truthy(lines:find('COULD NOT BE LOADED', 1, true),
            'the command for finding out why something is missing did not '
            .. 'mention the contract that is missing: ' .. lines)
        truthy(lines:find('ct00000009', 1, true), lines)
    end)

    it('says nothing on a store that opened cleanly', function()
        boot()
        Config.Database.Mode = 'json'
        -- A genuinely empty store. Leaving the previous test's files in
        -- place leaves its index still naming the lost contract, and the
        -- warning correctly persists — which is the fix, not a failure.
        Natives.files = {}
        package.loaded['crimson-bounty.server.storage.json'] = nil
        Env.console = {}
        package.loaded['server.main'] = nil
        local main = require('server.main')
        local modules = main.start()

        local said = table.concat(Env.console, '\n')
        falsy(said:find('COULD NOT BE LOADED', 1, true),
            'a banner nobody needs is one that gets ignored when it matters')
        falsy(table.concat(modules.admin.diagnose(1), '\n')
            :find('COULD NOT BE LOADED', 1, true))
    end)
end)

--- A filled setting is a copy, never the shipped table itself.
---
--- Assigning the default straight into Config made the two the same table,
--- so anything writing to the live config wrote through to the fallback and
--- the shipped defaults stopped being the shipped defaults for the rest of
--- the process. The second pass then had nothing left to fall back to,
--- which is the opposite of what filling is for.
---
--- Every assertion here is on identity or on the defaults surviving a write
--- to Config, because comparing the two values would compare a thing with
--- itself and pass either way — which is exactly how this survived.
describe('what filling a gap hands the live config', function()
    it('gives a whole section its own table', function()
        boot()
        Config.Listing = nil
        package.loaded['server.main'] = nil
        require('server.main').start()

        falsy(rawequal(Config.Listing, ConfigDefaults.Listing),
            'the live config and the fallback are the same table, so a write '
            .. 'to either is a write to both')
    end)

    it('leaves the shipped defaults intact when the live config is changed', function()
        boot()
        Config.Listing = nil
        package.loaded['server.main'] = nil
        require('server.main').start()

        local shipped = ConfigDefaults.Listing.PageSize
        truthy(shipped, 'the fixture needs a value to protect')
        Config.Listing.PageSize = nil
        eq(ConfigDefaults.Listing.PageSize, shipped,
            'deleting a key from the live config deleted it from the shipped '
            .. 'defaults, so nothing can be filled from them again')
    end)

    --- The per-key path and the nested-field path, asserted on identity.
    ---
    --- Not on the values: comparing what Config holds against what DEFAULTS
    --- holds compares a thing with itself when they are the same table, and
    --- passes either way. That is how this survived being written down.
    it('gives a per-key table its own copy', function()
        boot()
        Config.Reason.PatternDenylist = nil
        package.loaded['server.main'] = nil
        local main = require('server.main')
        main.start()

        truthy(Config.Reason.PatternDenylist, 'the gap has to be filled at all')
        falsy(rawequal(Config.Reason.PatternDenylist,
                       main.configDefaults.Reason.PatternDenylist),
            'the live denylist is the fallback, so an operator command that '
            .. 'edited one would edit both')
    end)

    it('leaves a per-key default intact when the live one is emptied', function()
        boot()
        Config.Advisory.TriggerJobTypes = nil
        package.loaded['server.main'] = nil
        require('server.main').start()

        -- An operator emptying the live set must not empty the fallback.
        for key in pairs(Config.Advisory.TriggerJobTypes) do
            Config.Advisory.TriggerJobTypes[key] = nil
        end

        boot()
        Config.Advisory.TriggerJobTypes = nil
        package.loaded['server.main'] = nil
        require('server.main').start()

        local refilled = 0
        for _ in pairs(Config.Advisory.TriggerJobTypes or {}) do refilled = refilled + 1 end
        truthy(refilled > 0,
            'the second server to need this default got an empty set, because '
            .. 'the first one emptied the fallback through the alias')
    end)
end)
