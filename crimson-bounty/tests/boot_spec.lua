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
