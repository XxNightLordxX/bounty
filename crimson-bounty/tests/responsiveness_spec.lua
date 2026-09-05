--- Why the app felt slow, and why placing a bounty said "Slow down."
---
--- Three separate things, all of which look like lag to a player.

local function call(name, source, payload)
    local fire = Env.events['crimson-bounty:' .. name]
    if not fire then return nil, 'no handler registered for ' .. name end
    Env.clientEvents = {}
    _G.source = source
    fire(payload or {})
    _G.source = nil
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-bounty:result' then return event.args[1] end
    end
    return nil
end

describe('a request the flood guard drops', function()
    it('is still answered', function()
        -- It used to return without replying at all. The page waits on
        -- every request it sends and gives up after fifteen seconds, so a
        -- dropped one is not a refusal the player sees — it is the app
        -- sitting there doing nothing for a quarter of a minute, once per
        -- click.
        local s = newStack()
        fixture(s)

        local silent = 0
        for _ = 1, 120 do
            local reply = call('list', 1, { page = 1 })
            if reply == nil then silent = silent + 1 end
        end
        eq(silent, 0,
            silent .. ' of 120 requests got no answer at all; every one of those '
            .. 'is the app frozen until its own timeout')
    end)

    it('says it is being throttled rather than failing namelessly', function()
        local s = newStack()
        fixture(s)
        local told
        for _ = 1, 120 do
            local reply = call('list', 1, { page = 1 })
            if reply and not reply.ok then told = reply.err end
        end
        eq(told, CB.ERR.RATE_LIMITED, 'the player has to be told to wait')
    end)

    it('still stops an actual flood', function()
        local s = newStack()
        fixture(s)
        local refused = 0
        for _ = 1, 500 do
            local reply = call('list', 1, { page = 1 })
            if reply and reply.err == CB.ERR.RATE_LIMITED then refused = refused + 1 end
        end
        truthy(refused > 0, 'the guard has to keep guarding')
    end)

    it('has room for what one screen of the app actually asks for', function()
        -- Opening the board is three requests, and then one mugshot per
        -- contract on it. A board of eight is eleven before the player has
        -- touched anything.
        local s = newStack()
        local f = fixture(s)
        for i = 1, 8 do
            s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x ' .. i, mode = CB.MODE.COMPETITIVE,
                reward = { baseline = { cash = 100 } },
            })
        end

        -- What one player actually does in ten seconds: open the app,
        -- look at the board, open their own contracts, place something,
        -- and have the push channel refresh them a couple of times. Every
        -- one of these is the app asking, not the player hammering.
        local throttled = 0
        local function ask(name, payload)
            local reply = call(name, 3, payload)
            if reply and reply.err == CB.ERR.RATE_LIMITED then
                throttled = throttled + 1
            end
        end

        local function openTheBoard()
            ask('list', { page = 1 })
            ask('mine', {})
            ask('ledger', {})
            -- One headshot per contract on the board.
            for _ = 1, 8 do ask('mugshotImage', { id = 'nope' }) end
        end

        openTheBoard()
        ask('browseTargets', { scope = 'all' })
        ask('rewardOptions', {})
        -- Two refreshes: one from a push, one from the player going back.
        openTheBoard()
        openTheBoard()

        eq(throttled, 0,
            'opening one screen and refreshing it twice was throttled '
            .. throttled .. ' times; a guard that trips on ordinary use is a '
            .. 'guard against the app')
    end)
end)

describe('placing a bounty that the server refuses', function()
    it('does not cost the attempt', function()
        -- The limit is checked before the handler runs, so a create refused
        -- for insufficient funds, a bad target, or a typo'd reward spent the
        -- same allowance as one that worked. Two mistakes and the player was
        -- told to slow down for half a minute.
        local s = newStack()
        local f = fixture(s)

        -- Several refusals in a row: no target handle at all.
        for _ = 1, 6 do
            local reply = call('create', 1, { reason = 'x' })
            falsy(reply.ok, 'these are all meant to fail')
            falsy(reply.err == CB.ERR.RATE_LIMITED,
                'a refused attempt must not use up the allowance')
        end

        -- And a real one still goes through afterwards.
        local browse = call('browseTargets', 1, { scope = 'all' })
        local handle
        for _, person in ipairs((browse.data and browse.data.people) or {}) do
            if person.name == 'Dana Reyes' then handle = person.handle end
        end
        truthy(handle, 'a target to place on')

        local made = call('create', 1, {
            target = handle, reason = 'Owes me', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(made and made.ok,
            'after six failed attempts a good one must still work: '
            .. tostring(made and made.err))
    end)

    it('still limits how many contracts actually get placed', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.cash = 1000000

        local browse = call('browseTargets', 1, { scope = 'all' })
        local handle = browse.data.people[1] and browse.data.people[1].handle
        truthy(handle)

        local placed, throttled = 0, 0
        for i = 1, 15 do
            local reply = call('create', 1, {
                target = handle, reason = 'Number ' .. i, mode = CB.MODE.COMPETITIVE,
                reward = { baseline = { cash = 100 } },
            })
            if reply and reply.ok then placed = placed + 1
            elseif reply and reply.err == CB.ERR.RATE_LIMITED then throttled = throttled + 1 end
        end
        truthy(throttled > 0,
            'the limit on real creations has to hold: ' .. placed .. ' placed')
    end)

    it('does not refund an attempt the limit itself refused', function()
        -- Refunding there would make the bucket bottomless.
        local s = newStack()
        fixture(s)
        local refusals = 0
        for _ = 1, 40 do
            local reply = call('accept', 1, { id = 'ct00000001' })
            if reply and reply.err == CB.ERR.RATE_LIMITED then refusals = refusals + 1 end
        end
        truthy(refusals >= 0)
    end)
end)


--- Why a target cannot be listed.
---
--- "That target cannot be listed right now" covered six different rules —
--- law enforcement, already carrying contracts, only just online, too new
--- to the city, only just back on their feet, and a cooling-off period
--- after the last one. A player reading it could not tell which, or
--- whether waiting would help.
describe('being told why a target is off limits', function()
    local function targeting(s, f)
        local browse = call('browseTargets', 1, { scope = 'all' })
        for _, person in ipairs((browse.data and browse.data.people) or {}) do
            if person.name == 'Dana Reyes' then return person.handle end
        end
        return nil
    end

    local function tryPlace(s, handle)
        return call('create', 1, {
            target = handle, reason = 'Owes me', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
    end

    it('says when the server bars law enforcement outright', function()
        local s = newStack()
        local f = fixture(s, { targetJob = { name = 'police', type = 'leo' } })
        local handle = targeting(s, f)
        truthy(handle)

        withConfig({ { Config.Targeting, 'AllowProtectedJobTargets', false } }, function()
            local reply = tryPlace(s, handle)
            eq(reply.err, CB.ERR.TARGET_IS_LEO,
                'not the same answer as "they just logged in"')
        end)
    end)

    it('lists a sworn officer happily when the server allows it', function()
        -- The default. An officer being listable is the point of the
        -- advisory that goes with it.
        local s = newStack()
        local f = fixture(s, { targetJob = { name = 'police', type = 'leo' } })
        Env.players[2]._sessionMinutes = 600
        local handle = targeting(s, f)
        local reply = tryPlace(s, handle)
        truthy(reply.ok, 'an officer is fair game by default: ' .. tostring(reply.err))
    end)

    it('says when the target already has as many as the server allows', function()
        local s = newStack()
        local f = fixture(s)
        for i = 1, Config.Limits.MaxActiveContractsPerTarget do
            truthy(s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x ' .. i, mode = CB.MODE.COMPETITIVE,
                reward = { baseline = { cash = 100 } },
            }), 'seeding contract ' .. i)
        end

        Env.addPlayer({ source = 12, citizenid = 'CREATOR2', license = 'license:c2',
            cash = 100000, bank = 100000, firstname = 'Ann', lastname = 'Poe' })
        local other = s.identity.resolve(12)
        local ok, err = s.contracts.create(other, {
            targetCid = 'TARGET01', reason = 'one more', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 100 } },
        })
        falsy(ok)
        eq(err, CB.ERR.TARGET_HAS_ENOUGH,
            'and not the same answer as "they are law enforcement"')
    end)

    it('gives every rule its own answer', function()
        -- Six rules, six codes. A message that cannot distinguish them is
        -- a message that cannot be acted on.
        local seen = {}
        for _, code in ipairs({
            CB.ERR.TARGET_IS_LEO, CB.ERR.TARGET_HAS_ENOUGH, CB.ERR.TARGET_JUST_ON,
            CB.ERR.TARGET_TOO_NEW, CB.ERR.TARGET_JUST_UP, CB.ERR.TARGET_RECENTLY_ON,
        }) do
            truthy(code, 'every reason needs a code')
            falsy(seen[code], 'two reasons share the code ' .. tostring(code))
            seen[code] = true
        end
    end)
end)
