--- The holds service (server/holds.lua, step 3e): every reason a contract
--- stands still asked through one API, given back by one routine and
--- released by one path.
---
--- Booted through main.lua, so the expiry pass's presence judgement is the
--- real one. What these hold the service to:
---
---   * Holds.on / Holds.since by kind ('staff', 'restart', 'app', a list,
---     or every kind), with no contract for the holds on every contract;
---   * who may see why: Holds.why tells a stranger only the holds on every
---     contract and a party On hold too; Holds.shown names to staff only the
---     parties they may see;
---   * one give-back: a freeze, the app pause and the restart hold
---     overlapping and released in turn give the lifetime the whole span
---     once, with the releasing guard up while each gives its part back;
---   * Holds.clockMayRun asks every hold and the presence pause;
---   * the old per-feature checks, the freeze module and its config keys
---     are gone (rule 4: no aliases).

local function forgetServerModules()
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
            package.loaded[name] = nil
        end
    end
end

local function boot()
    forgetServerModules()
    Env.reset()
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Natives.resetResourceStates()
    resetConfig()
    Config.Database.Mode = 'memory'
    Config.Limits.ExclusiveIdleReleaseSeconds = 0
    Config.Limits.ExclusiveAttemptWindowSeconds = 0
    local main = require('server.main')
    return main, main.start()
end

local function place(s, actor, extra)
    local req = { targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                  reward = { baseline = { cash = 5000 } } }
    for k, v in pairs(extra or {}) do req[k] = v end
    local c, err = s.contracts.create(actor, req)
    truthy(c, 'placed: ' .. tostring(err))
    return c
end

local function row(s, c) return s.storage.readContract(c.id) end

local function appPause(s, on)
    Config.Holds.AppPaused = on
    s.holds.syncAppPause()
end

describe('the holds service: is it held, by what, since when', function()
    it('answers each kind on its own, a list of them, and every kind at once', function()
        local _, s = boot()
        local f = fixture(s)
        local c = place(s, f.creator)
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        falsy(s.holds.on(row(s, c)), 'nothing holds it yet')
        eq(s.holds.since(row(s, c)), nil)

        local frozenAt = os.time()
        truthy(s.holds.freeze('ADMIN', 'TARGET01', 'test', 'Target'))
        truthy(s.holds.on(row(s, c), nil, 'staff'), 'a freeze on the target holds it')
        falsy(s.holds.on(row(s, c), nil, 'app'), 'not the app pause')
        falsy(s.holds.on(row(s, c), nil, 'restart'), 'nor the restart hold')
        truthy(s.holds.on(row(s, c)), 'every kind: held')
        falsy(s.holds.on(nil, nil, 'staff'), 'no contract, no staff hold')
        eq(s.holds.since(row(s, c), nil, 'staff'), frozenAt)

        Env.advance(60)
        appPause(s, true)
        truthy(s.holds.on(nil, nil, 'app'), 'the app pause holds every contract, asked with none')
        eq(s.holds.global('app'), frozenAt + 60)
        truthy(s.holds.on(row(s, c), nil, { 'restart', 'app' }), 'a list: any of them')
        eq(s.holds.since(row(s, c), nil, 'app'), frozenAt + 60, 'the app pause on its own')
        eq(s.holds.since(row(s, c)), frozenAt, 'the earliest of every kind')

        Env.advance(60)
        truthy(s.holds.scheduledRestart({ secondsRemaining = 1800 }), 'the restart hold began')
        eq(s.holds.global('restart'), frozenAt + 120)
        eq(s.holds.since(nil, nil, 'restart'), frozenAt + 120)
    end)

    it('lets a stranger know only of the holds on every contract, and a party of On hold too', function()
        local _, s = boot()
        local f = fixture(s)
        local c = place(s, f.creator)
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        truthy(s.holds.freeze('ADMIN', 'HITMAN01', 'test', 'Hitman'))
        local frozenAt = os.time()
        eq(s.holds.why(row(s, c), nil, 'public'), nil, 'a staff freeze is nothing a stranger is told')
        local party = s.holds.why(row(s, c), nil, 'party')
        eq(party.since, frozenAt)
        eq(party.staff, frozenAt, 'a party is told it is on hold')

        Env.advance(30)
        appPause(s, true)
        local public = s.holds.why(row(s, c), nil, 'public')
        eq(public.since, frozenAt + 30, 'the app pause stands a stranger\'s band still')
        eq(public.staff, nil, 'and never says On hold')
        eq(s.holds.why(row(s, c), nil, 'party').since, frozenAt, 'a party\'s from the freeze')
    end)

    it('names to staff only the frozen parties they may see', function()
        local _, s = boot()
        local f = fixture(s)
        local c = place(s, f.creator, { anonymous = true })
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        eq(s.holds.shown(row(s, c), nil, true), nil, 'nobody frozen')
        truthy(s.holds.freeze('ADMIN', 'CREATOR1', 'test', 'Placer'))
        eq(s.holds.shown(row(s, c), nil, false), nil, 'an anonymous placer is not shown')
        eq(table.concat(s.holds.shown(row(s, c), nil, true), ','), 'the placer', 'with IdentityAce')
        truthy(s.holds.freeze('ADMIN', 'TARGET01', 'test', 'Target'))
        eq(table.concat(s.holds.shown(row(s, c), nil, false), ','), 'the target')
    end)
end)

describe('the holds service: one give-back, one release path', function()
    it('gives the lifetime a freeze, the app pause and the restart hold overlapping took, once', function()
        local _, s = boot()
        local f = fixture(s)
        local c = place(s, f.creator)
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        local expires = row(s, c).expires_at
        truthy(expires, 'a lifetime')

        -- Inside every release, the guard is up while the time goes back.
        local real, guarded, calls = s.storage.addToExpires, true, 0
        s.storage.addToExpires = function(...)
            calls = calls + 1
            guarded = guarded and s.holds.releasing()
            return real(...)
        end

        truthy(s.holds.freeze('ADMIN', 'TARGET01', 'test', 'Target'))
        Env.advance(100)
        appPause(s, true)
        Env.advance(100)
        truthy(s.holds.scheduledRestart({ secondsRemaining = 1800 }))
        Env.advance(100)
        truthy(s.holds.unfreeze('ADMIN', 'TARGET01', 'done'))
        eq(row(s, c).expires_at, expires + 100, 'the freeze gives back only what no other hold covers')
        Env.advance(100)
        appPause(s, false)
        eq(row(s, c).expires_at, expires + 200, 'the app pause up to the restart hold\'s start')
        Env.advance(100)
        truthy(s.holds.releaseRestart('skipped'))
        eq(row(s, c).expires_at, expires + 500, 'the whole 500 seconds, once')
        s.storage.addToExpires = real

        eq(calls, 3, 'one give-back each')
        truthy(guarded, 'each under the releasing guard')
        falsy(s.holds.releasing(), 'and the guard down after')
    end)

    it('runs a clock only where no hold and nobody\'s absence stops it', function()
        local main, s = boot()
        local f = fixture(s)
        local c = place(s, f.creator)
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        truthy(s.holds.clockMayRun(row(s, c)), 'everybody here, nothing held')
        appPause(s, true)
        falsy(s.holds.clockMayRun(row(s, c)), 'the app pause')
        appPause(s, false)
        truthy(s.holds.freeze('ADMIN', 'HITMAN01', 'test', 'Hitman'))
        falsy(s.holds.clockMayRun(row(s, c)), 'a staff freeze')
        truthy(s.holds.unfreeze('ADMIN', 'HITMAN01', 'done'))
        Env.removePlayer(2)
        main.markPresenceChanged()
        falsy(s.holds.clockMayRun(row(s, c)), 'the target away: the presence pause')
    end)
end)

describe('the holds service replaces the per-feature checks', function()
    it('leaves no old name behind', function()
        local _, s = boot()
        for _, name in ipairs({ 'heldByStaff', 'restartHeld', 'restartHeldSince', 'heldSince',
            'holdReleasing', 'appPaused', 'frozenPlayer' }) do
            eq(s.contracts[name], nil, 'Contracts.' .. name)
        end
        eq(s.panel.frozenShown, nil, 'Panel.frozenShown')
        eq(rawget(_G, 'ContractClockMayRun'), nil, 'the ContractClockMayRun global')
        eq(io.open('crimson-hitman/server/freeze.lua', 'r'), nil, 'server/freeze.lua')
        eq(Config.Restart, nil, 'Config.Restart')
        eq(Config.Staff.AppPaused, nil, 'Config.Staff.AppPaused')
        eq(s.settings.entry('Staff.AppPaused'), nil, 'the Staff.AppPaused setting')
        eq(s.settings.entry('Restart.PauseBeforeSeconds'), nil, 'the Restart.PauseBeforeSeconds setting')
        truthy(s.settings.entry('Holds.AppPaused'), 'Holds.AppPaused')
        truthy(s.settings.entry('Holds.RestartPauseBeforeSeconds'), 'Holds.RestartPauseBeforeSeconds')
        truthy(s.settings.entry('Holds.RestartMaxHoldMinutes'), 'Holds.RestartMaxHoldMinutes')
        for _, name in ipairs({ 'holds', 'heldSince', 'holdStart', 'bandStart', 'restartHeld',
            'restartHeldSince', 'appPaused', 'appPausedSince', 'restartTick' }) do
            eq(s.holds[name], nil, 'Holds.' .. name)
        end
    end)
end)
