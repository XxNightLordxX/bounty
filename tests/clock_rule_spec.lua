--- The deadline runs only with everybody in the city, players see only a
--- rough band of it, and every contract is paused for the half hour before
--- a scheduled txAdmin restart.
---
--- Booted through main.lua, so the expiry pass, the maintenance tick, the
--- txAdmin handlers and the staff freeze are the real ones. What these hold:
---
---   * the deadline runs only while the placer (named or anonymous), the
---     target (out of prison) and at least one operative holding it are all
---     in; with nobody holding it, it does not run; once it has gone with the
---     clock running, nobody leaving stops it;
---   * no player is sent the deadline, the seconds left or whether the clock
---     runs, and two snapshots either side of an anonymous party logging off
---     are byte-identical to every other party; the band moves only when the
---     run time crosses a boundary while the clock runs;
---   * txAdmin's scheduledRestart inside Config.Restart.PauseBeforeSeconds
---     holds every live contract, with one notice; the hold ends at the next
---     start, on a skip, or at Config.Restart.MaxHoldMinutes; and no hold, a
---     freeze or anybody's absence ends another's.

local Exec = require('tests.harness.mysql_exec')
local Util = require('crimson-hitman.shared.util')

local function forgetServerModules()
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
            package.loaded[name] = nil
        end
    end
end

local function boot(mode, configure)
    forgetServerModules()
    Env.reset()
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Natives.resetResourceStates()
    resetConfig()
    Config.Database.Mode = mode or 'memory'
    if mode == 'mysql' then Exec.install(Natives) end
    if mode == 'json' then Natives.files = {} end
    Config.Limits.ExclusiveIdleReleaseSeconds = 0
    Config.Limits.ExclusiveAttemptWindowSeconds = 0
    Config.Limits.MaxActiveContractsPerTarget = 5
    Config.Limits.MaxActiveContractsPerCreator = 5
    if configure then configure() end
    local main = require('server.main')
    return main, main.start()
end

--- The same store, a new process: what a server restart is.
local function restart(mode, old)
    if old and old.storage then rawset(old.storage, '__rawFixture', true) end
    forgetServerModules()
    Env.events, Env.clientEvents, Env.notifications = {}, {}, {}
    Env.handlers, Env.threads, Env.timers, Env.commands = {}, {}, {}, {}
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Config.Database.Mode = mode
    local main = require('server.main')
    return main, main.start()
end

--- The usual three, a second hitman and a stranger who reads the board.
local function people(s)
    local f = fixture(s)
    Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
        cash = 5000, bank = 50000, firstname = 'Kit', lastname = 'Vane' })
    Env.addPlayer({ source = 9, citizenid = 'PUBLIC01', license = 'license:pub',
        cash = 5000, bank = 5000, firstname = 'Pat', lastname = 'Lee' })
    f.hitman2 = s.identity.resolve(4)
    return f
end

local function place(s, actor, extra)
    local req = { targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                  reward = { baseline = { cash = 5000 } } }
    for k, v in pairs(extra or {}) do req[k] = v end
    local c, err = s.contracts.create(actor, req)
    truthy(c, 'placed: ' .. tostring(err))
    return c
end

local function pass(main)
    main.markPresenceChanged()
    main.expire()
end

local function row(s, c) return s.storage.readContract(c.id) end

--- A player back in the city, as they were.
local PEOPLE = {
    [1] = { source = 1, citizenid = 'CREATOR1', license = 'license:aaa', cash = 100000,
            bank = 100000, firstname = 'Vic', lastname = 'Marlowe' },
    [3] = { source = 3, citizenid = 'HITMAN01', license = 'license:ccc', cash = 5000,
            bank = 5000, firstname = 'Rook', lastname = 'Ash' },
    [4] = { source = 4, citizenid = 'HITMAN02', license = 'license:ddd', cash = 5000,
            bank = 50000, firstname = 'Kit', lastname = 'Vane' },
}

local function leave(main, src)
    Env.removePlayer(src)
    pass(main)
end

local function back(main, src)
    Env.addPlayer(PEOPLE[src])
    pass(main)
end

--- One value as text, keys sorted, so two snapshots compare byte for byte.
local function canonical(value)
    local kind = type(value)
    if kind == 'table' then
        local keys = {}
        for k in pairs(value) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local out = {}
        for _, k in ipairs(keys) do out[#out + 1] = tostring(k) .. '=' .. canonical(value[k]) end
        return '{' .. table.concat(out, ',') .. '}'
    elseif kind == 'string' then
        return ('%q'):format(value)
    end
    return tostring(value)
end

local function notices(src)
    local out = {}
    for _, event in ipairs(Env.clientEvents) do
        if Natives.isNotice(event) and event.target == src then
            out[#out + 1] = tostring(event.args[1].title) .. ' | ' .. tostring(event.args[1].content)
        end
    end
    return out
end

local function count(list, needle)
    local n = 0
    for _, text in ipairs(list) do if text:find(needle, 1, true) then n = n + 1 end end
    return n
end

local function restartIn(seconds)
    TriggerEvent('txAdmin:events:scheduledRestart',
        { secondsRemaining = seconds, translatedMessage = 'restart' })
end

--------------------------------------------------------------------------
-- 1. The clock runs only with everyone in
--------------------------------------------------------------------------

describe('the deadline runs only with the placer, the target and an operative in', function()
    it('does not run with nobody holding it, and never expires for it', function()
        local main, s = boot()
        local f = people(s)
        local c = place(s, f.creator)
        pass(main)
        truthy(row(s, c).paused_since, 'running with no operative')
        Env.advance(Config.Limits.DefaultDeadlineSeconds + 600)
        pass(main)
        eq(row(s, c).state, CH.STATE.ACTIVE, 'expired by a deadline that never ran')
        eq(Util.runLeft(row(s, c)), Util.runLeft(row(s, c), os.time() - 99999), 'the run time moved')

        -- Taken: the next pass starts it, with every second it waited banked.
        local left = Util.runLeft(row(s, c))
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        main.expire()
        eq(row(s, c).paused_since, nil, 'not started once somebody held it')
        eq(row(s, c).deadline_at - os.time(), left, 'not banked to the second')
    end)

    it('stops for an anonymous placer away, as for a named one', function()
        for _, anonymous in ipairs({ false, true }) do
            local main, s = boot()
            local f = people(s)
            local c = place(s, f.creator, { anonymous = anonymous })
            truthy(s.contracts.accept(f.hitman, c.id), 'taken')
            pass(main)
            eq(row(s, c).paused_since, nil, 'running with everyone in')
            leave(main, 1)
            truthy(row(s, c).paused_since, (anonymous and 'anonymous' or 'named')
                .. ' placer away and the clock ran on')
            back(main, 1)
            eq(row(s, c).paused_since, nil, 'not started again once they were back')
        end
    end)

    it('stops with every operative away, and runs while one of several is in', function()
        local main, s = boot()
        local f = people(s)
        local c = place(s, f.creator)
        truthy(s.contracts.accept(f.hitman, c.id), 'one')
        truthy(s.contracts.accept(f.hitman2, c.id), 'two')
        pass(main)
        eq(row(s, c).paused_since, nil, 'running with both in')
        leave(main, 3)
        eq(row(s, c).paused_since, nil, 'one of two away stopped a competitive contract')
        leave(main, 4)
        truthy(row(s, c).paused_since, 'both away and it ran on')
        back(main, 4)
        eq(row(s, c).paused_since, nil, 'one back and it stayed stopped')
    end)

    it('stops when the last operative walks away, at the next pass', function()
        local main, s = boot()
        local f = people(s)
        local c = place(s, f.creator)
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        pass(main)
        eq(row(s, c).paused_since, nil, 'running')
        truthy(s.contracts.abandon(f.hitman, c.id), 'walked away')
        main.expire()
        truthy(row(s, c).paused_since, 'nobody holds it and it ran on')
    end)

    it('once the deadline has gone with the clock running, nobody leaving stops it', function()
        local main, s = boot()
        local f = people(s)
        local c = place(s, f.creator, { penaltyAmount = 500 })
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        pass(main)
        Env.advance(row(s, c).deadline_at - os.time() + 1)
        Env.removePlayer(3)
        Env.removePlayer(1)
        pass(main)
        eq(row(s, c).state, CH.STATE.EXPIRED, 'a party leaving after the deadline saved it')
    end)
end)

--------------------------------------------------------------------------
-- 2. No visible countdown
--------------------------------------------------------------------------

describe('what players see of the clock', function()
    --- Every view of every party but `skip`, as text.
    local function views(s, c, skip)
        local out = {}
        local function add(name, value) out[#out + 1] = name .. '=' .. canonical(value) end
        if skip ~= 'CREATOR1' then add('creator.mine', s.projection.mine('CREATOR1')) end
        if skip ~= 'HITMAN01' then
            add('hitman1.accepted', s.projection.accepted('HITMAN01'))
            add('hitman1.card', s.projection.contract(row(s, c), 'HITMAN01'))
        end
        if skip ~= 'HITMAN02' then add('hitman2.accepted', s.projection.accepted('HITMAN02')) end
        add('target.onMe', s.projection.onMe('TARGET01'))
        add('target.card', s.projection.contract(row(s, c), 'TARGET01'))
        add('public.board', s.projection.listing('PUBLIC01', 1))
        add('public.card', s.projection.contract(row(s, c), 'PUBLIC01'))
        return table.concat(out, '\n')
    end

    it('is byte-identical to everyone else either side of an anonymous party logging off', function()
        for _, who in ipairs({ 'placer', 'operative' }) do
            local main, s = boot()
            local f = people(s)
            local c = place(s, f.creator, { anonymous = true })
            truthy(s.contracts.accept(f.hitman, c.id, true), 'taken anonymously')
            truthy(s.contracts.accept(f.hitman2, c.id, true), 'and by a second, anonymously')
            -- Past the wait before its target is shown it, which would
            -- change their view whoever was online.
            Env.advance(Config.Notifications.ParanoidAlertJitter.max + 60)
            main.tick()
            pass(main)
            local cid, src = 'CREATOR1', 1
            if who == 'operative' then
                -- The only one in: their leaving stops the clock.
                Env.removePlayer(4)
                pass(main)
                cid, src = 'HITMAN01', 3
            end
            eq(row(s, c).paused_since, nil, who .. ': running before')
            local before = views(s, c, cid)
            Env.removePlayer(src)
            pass(main)
            truthy(row(s, c).paused_since, who .. ': the clock stopped for them')
            eq(views(s, c, cid), before, who .. ': what another party sees changed as they left')
            Env.advance(3 * 3600)
            pass(main)
            local during = views(s, c, cid)
            eq(during, before, who .. ': and while they were away')
            Env.addPlayer(PEOPLE[src])
            pass(main)
            eq(row(s, c).paused_since, nil, who .. ': running again')
            eq(views(s, c, cid), before, who .. ': and as they came back')
        end
    end)

    it('sends no deadline, seconds left or clock state anywhere a player looks', function()
        local main, s = boot()
        local f = people(s)
        local c = place(s, f.creator, { anonymous = true })
        truthy(s.contracts.accept(f.hitman, c.id, true), 'taken')
        pass(main)
        Env.removePlayer(1)
        pass(main)
        local text = views(s, c) .. canonical(s.projection.accepted('HITMAN01'))
        for _, key in ipairs({ 'deadline=', 'deadline_at', 'secondsLeft', 'clockStopped', 'paused',
            'paused_since', 'expires' }) do
            falsy(text:find(key, 1, true), key .. ' reached a player: ' .. text:sub(1, 300))
        end
        truthy(text:find('timeLeft="', 1, true), 'and the band did')
    end)

    it('moves the band only when the run time crosses a boundary while it runs', function()
        local main, s = boot()
        local f = people(s)
        local c = place(s, f.creator)
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        pass(main)
        local function band() return s.projection.contract(row(s, c), 'TARGET01').timeLeft end
        -- Three hours as shipped: just over two hours left after 59 minutes.
        local left = Util.runLeft(row(s, c))
        Env.advance(left - 7201)
        main.tick()
        eq(band(), 'More than 2 hours left')
        leave(main, 3)
        Env.advance(5 * 3600)
        main.tick()
        eq(band(), 'More than 2 hours left', 'moved while the clock stood still')
        back(main, 3)
        eq(band(), 'More than 2 hours left', 'moved as the operative came back')
        Env.advance(2)
        eq(band(), '1–2 hours left', 'did not move across the boundary with the clock running')
        Env.advance(3600)
        eq(band(), 'Under 1 hour left')
        Env.advance(2700)
        eq(band(), 'Under 15 minutes left')
    end)
end)

--------------------------------------------------------------------------
-- 3. The restart hold
--------------------------------------------------------------------------

describe('the half hour before a scheduled txAdmin restart', function()
    it('holds every live contract from the first warning inside the window, with one notice', function()
        local main, s = boot()
        local f = people(s)
        local a = place(s, f.creator, { penaltyAmount = 500 })
        truthy(s.contracts.accept(f.hitman, a.id), 'taken')
        Env.addPlayer({ source = 11, citizenid = 'CREATOR2', license = 'license:c2',
            cash = 100000, bank = 100000, firstname = 'Ann', lastname = 'Poe' })
        local b = place(s, s.identity.resolve(11))
        pass(main)
        eq(row(s, a).paused_since, nil, 'running before')

        Env.clientEvents = {}
        restartIn(3600)
        falsy(s.freeze.restartHeld(), 'an hour out is outside the window')
        restartIn(1800)
        truthy(s.freeze.restartHeld(), 'thirty minutes out holds')
        eq(row(s, a).paused_since, os.time(), 'the deadline stopped when the hold began')
        for _, src in ipairs({ 1, 3, 11 }) do
            eq(count(notices(src), 'Contracts are paused until the server restart.'), 1,
                'one notice to ' .. src)
        end
        for _, mins in ipairs({ 15, 10, 5, 4, 3, 2, 1 }) do restartIn(mins * 60) end
        for _, src in ipairs({ 1, 3, 11 }) do
            eq(count(notices(src), 'Contracts are paused until the server restart.'), 1,
                'one notice, not one a warning, to ' .. src)
        end

        -- Nothing ends meanwhile: not the deadline, not the lifetime.
        local deadlineLeft = Util.runLeft(row(s, a))
        Env.advance(30 * 60 - 1)
        s.storage.setContractFields(b.id, { expires_at = os.time() - 1 })
        pass(main)
        main.tick()
        eq(row(s, a).state, CH.STATE.ACCEPTED, 'ended on the hold')
        eq(row(s, b).state, CH.STATE.ACTIVE, 'its lifetime ended it on the hold')
        eq(Util.runLeft(row(s, a)), deadlineLeft, 'the deadline ran on the hold')
        local ok, err = s.kidnap.arm(a.id, 'HITMAN01')
        falsy(ok, 'a handover armed on the hold')
        eq(err, CH.ERR.RESTART_HOLD)
    end)

    it('ends with the start after the restart, banking the time on hold', function()
        local main, s = boot('json')
        local f = people(s)
        local c = place(s, f.creator)
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        pass(main)
        local left = Util.runLeft(row(s, c))
        restartIn(1800)
        truthy(s.freeze.restartHeld(), 'held')
        Env.advance(1800)
        main.tick()
        Env.advance(120)
        main, s = restart('json', s)
        falsy(s.freeze.restartHeld(), 'still held after the restart')
        pass(main)
        local now = s.storage.readContract(c.id)
        eq(now.paused_since, nil, 'not running again after the restart')
        eq(now.deadline_at - os.time(), left, 'the hold and the downtime were charged to the deadline')
    end)

    it('ends on a skip, either of txAdmin\'s names for it', function()
        for _, event in ipairs({ 'txAdmin:events:scheduledRestartSkipped',
            'txAdmin:events:skippedNextScheduledRestart' }) do
            local main, s = boot()
            local f = people(s)
            local c = place(s, f.creator)
            truthy(s.contracts.accept(f.hitman, c.id), 'taken')
            pass(main)
            local left = Util.runLeft(row(s, c))
            restartIn(900)
            truthy(s.freeze.restartHeld(), 'held')
            Env.advance(600)
            TriggerEvent(event, { secondsRemaining = 300, temporary = false, author = 'Staff' })
            falsy(s.freeze.restartHeld(), event .. ' did not release it')
            main.expire()
            eq(row(s, c).paused_since, nil, event .. ': not running again')
            eq(row(s, c).deadline_at - os.time(), left, event .. ': the time on hold not banked')
        end
    end)

    it('ends at MaxHoldMinutes when the restart never comes', function()
        local main, s = boot()
        local f = people(s)
        local c = place(s, f.creator)
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        pass(main)
        restartIn(1800)
        Env.advance(Config.Restart.MaxHoldMinutes * 60 - 1)
        main.tick()
        truthy(s.freeze.restartHeld(), 'released early')
        Env.advance(1)
        main.tick()
        falsy(s.freeze.restartHeld(), 'not released at the longest hold')
        eq(row(s, c).paused_since, nil, 'not running again')
    end)

    it('is off with PauseBeforeSeconds 0, and ignores a warning it cannot read', function()
        local main, s = boot(nil, function() Config.Restart.PauseBeforeSeconds = 0 end)
        people(s)
        restartIn(60)
        falsy(s.freeze.restartHeld(), 'held with the hold off')
        Config.Restart.PauseBeforeSeconds = 1800
        TriggerEvent('txAdmin:events:scheduledRestart', { secondsRemaining = 'soon' })
        TriggerEvent('txAdmin:events:scheduledRestart', nil)
        falsy(s.freeze.restartHeld(), 'held on a warning with no seconds')
    end)

    it('holds a queued buyout, and pays it once released', function()
        local main, s = boot()
        local f = people(s)
        local c = place(s, f.creator, { bailoutAmount = 1000 })
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        pass(main)
        restartIn(1800)
        local ok, err = s.bailout.buy(f.target, c.id)
        truthy(ok, 'a buyout paid on the hold: ' .. tostring(err))
        Env.advance(Config.Bailout.ProcessingDelaySeconds + 5)
        s.bailout.processQueue()
        eq(row(s, c).state, CH.STATE.ACCEPTED, 'settled on the hold')
        TriggerEvent('txAdmin:events:scheduledRestartSkipped', { secondsRemaining = 1 })
        s.bailout.processQueue()
        eq(row(s, c).state, CH.STATE.BAILED_OUT, 'not settled once released')
    end)

    it('never ends a freeze, and a freeze or an absence never ends it', function()
        local main, s = boot()
        local f = people(s)
        local c = place(s, f.creator)
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        pass(main)
        local left = Util.runLeft(row(s, c))

        -- Frozen, then the hold: the hold's release leaves the freeze's pause.
        truthy(s.freeze.freeze('ADMIN001', 'TARGET01', 'dispute'), 'frozen')
        Env.advance(60)
        restartIn(1800)
        Env.advance(60)
        TriggerEvent('txAdmin:events:scheduledRestartSkipped', {})
        main.expire()
        truthy(row(s, c).paused_since, 'the skip ended a staff freeze\'s pause')

        -- The hold again, then the unfreeze: the unfreeze leaves the hold's.
        restartIn(1800)
        Env.advance(60)
        truthy(s.freeze.unfreeze('ADMIN001', 'TARGET01'), 'released')
        truthy(row(s, c).paused_since, 'an unfreeze ended the restart hold\'s pause')
        main.expire()
        truthy(row(s, c).paused_since, 'and the pass after it')

        -- The hold released with the operative away: their absence holds it.
        Env.removePlayer(3)
        Env.advance(60)
        TriggerEvent('txAdmin:events:scheduledRestartSkipped', {})
        main.expire()
        truthy(row(s, c).paused_since, 'the release ran a clock nobody was working')
        back(main, 3)
        eq(row(s, c).paused_since, nil, 'running once they were back')
        eq(row(s, c).deadline_at - os.time(), left, 'a second of it charged to the deadline')

        -- And the other way round: an unfreeze with a party away banks
        -- nothing itself, and the pass starts it once they are back.
        truthy(s.freeze.freeze('ADMIN001', 'TARGET01', 'again'), 'frozen again')
        Env.removePlayer(1)
        Env.advance(60)
        truthy(s.freeze.unfreeze('ADMIN001', 'TARGET01'), 'released')
        truthy(row(s, c).paused_since, 'an unfreeze ran a clock with the placer away')
        back(main, 1)
        eq(row(s, c).paused_since, nil, 'running again')
        eq(row(s, c).deadline_at - os.time(), left, 'and not a second charged')
    end)
end)
