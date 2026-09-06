--- The app's own opening sequence, against its own rate limit.
---
--- Every listing handler shared one bucket. Opening the app spends three of
--- it — list, mine and ledger — and opening the Place form spends two more
--- on the wallet and the target list. With a burst of five that is the
--- whole allowance before the player has typed anything, and the two
--- requests that fire last are the two that come back refused: an empty
--- target list and an empty item picker, on a form that looks like it
--- simply does not work.
---
--- Refreshing makes it worse rather than better, because a refresh is two
--- more requests into a bucket that refills twice a second.

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

--- Exactly what the page asks for when a player opens it and taps Place.
local OPENING = { 'list', 'mine', 'ledger' }
local PLACE = { 'rewardOptions', 'browseTargets' }

describe('opening the app inside its own rate limit', function()
    local function seeded()
        local s = newStack()
        local f = fixture(s)
        Env.addPlayer({ source = 10, citizenid = 'PERSON10', license = 'license:p10',
            firstname = 'Ada', lastname = 'Quill' })
        return s, f
    end

    it('has enough allowance to open the app and reach the Place form', function()
        local s = seeded()
        local refused = {}

        for _, name in ipairs(OPENING) do
            local reply = call(name, 1)
            if not (reply and reply.ok) then
                refused[#refused + 1] = name .. ':' .. tostring(reply and reply.err)
            end
        end
        for _, name in ipairs(PLACE) do
            local reply = call(name, 1)
            if not (reply and reply.ok) then
                refused[#refused + 1] = name .. ':' .. tostring(reply and reply.err)
            end
        end

        eq(#refused, 0,
            'a player who has done nothing but open the app and tap Place was '
            .. 'refused: ' .. table.concat(refused, ', '))
    end)

    it('survives a refresh without locking the form out', function()
        -- The push channel refreshes the board, and a player pressing the
        -- tab again refreshes it too. Neither is abuse.
        local s = seeded()
        for _, name in ipairs(OPENING) do call(name, 1) end
        for _, name in ipairs(PLACE) do call(name, 1) end

        for _, name in ipairs(OPENING) do call(name, 1) end

        local refused = {}
        for _, name in ipairs(PLACE) do
            local reply = call(name, 1)
            if not (reply and reply.ok) then
                refused[#refused + 1] = name .. ':' .. tostring(reply and reply.err)
            end
        end
        eq(#refused, 0,
            'after one refresh the Place form was refused: '
            .. table.concat(refused, ', '))
    end)

    it('lets a player page through the city and type a name', function()
        local s = seeded()
        for _, name in ipairs(OPENING) do call(name, 1) end

        local refused = 0
        -- Open the form, then five interactions: three pages and two
        -- debounced filter queries. Nothing here is fast or unusual.
        call('rewardOptions', 1)
        for i = 1, 5 do
            local reply = call('browseTargets', 1, { scope = 'all', page = i })
            if not (reply and reply.ok) then refused = refused + 1 end
        end
        eq(refused, 0, refused .. ' of 5 ordinary interactions were refused')
    end)

    it('still refuses somebody hammering it', function()
        -- The limit has to stay a limit. This is the point of it.
        local s = seeded()
        local refused = 0
        for _ = 1, 200 do
            local reply = call('browseTargets', 1, { scope = 'all' })
            if not (reply and reply.ok) then refused = refused + 1 end
        end
        truthy(refused > 0,
            'two hundred requests in no time at all must not all be allowed')
    end)
end)


describe('an action with no rule of its own', function()
    it('is limited rather than unlimited', function()
        -- The wrong way round is dangerous: a bucket that gets renamed, or
        -- one an operator's older config does not carry, would silently
        -- become a handler nobody can rate limit.
        local s = newStack()
        fixture(s)
        local allowed = 0
        for _ = 1, 200 do
            if s.ratelimit.check('SOMEONE1', 'an_action_nobody_configured') then
                allowed = allowed + 1
            end
        end
        truthy(allowed > 0, 'it still has to allow ordinary use')
        truthy(allowed < 200,
            'but two hundred calls to an unconfigured action must not all pass: '
            .. allowed)
    end)

    it('uses a real bucket, so it refills like every other', function()
        local s = newStack()
        fixture(s)
        while s.ratelimit.check('SOMEONE2', 'unconfigured') do end
        falsy(s.ratelimit.check('SOMEONE2', 'unconfigured'), 'spent')

        Env.advance(60)
        truthy(s.ratelimit.check('SOMEONE2', 'unconfigured'),
            'a minute later it must be usable again, not blocked for good')
    end)
end)

describe('a config that predates the bucket split', function()
    local function bootOld()
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
        -- One shared bucket of five, as it was.
        Config.Cooldowns.load = nil
        Config.Cooldowns.wallet = nil
        Config.Cooldowns.search = { per = 10, burst = 5 }
        return require('server.main').start()
    end

    it('gets the allowance the app was built against', function()
        bootOld()
        eq(Config.Cooldowns.load.burst, 20,
            'an operator who never had this bucket is not choosing to withhold it')
        eq(Config.Cooldowns.wallet.burst, 8)
        eq(Config.Cooldowns.search.burst, 5,
            'but a bucket they did set keeps the value they set')
        resetConfig()
    end)

    it('opens the app and reaches the Place form on that config', function()
        local modules = bootOld()
        fixture(modules)
        Env.addPlayer({ source = 10, citizenid = 'PERSON10', license = 'license:p10',
            firstname = 'Ada', lastname = 'Quill' })

        for _, name in ipairs({ 'list', 'mine', 'ledger' }) do call(name, 1) end
        for _, name in ipairs({ 'list', 'mine', 'ledger' }) do call(name, 1) end

        local wallet = call('rewardOptions', 1)
        truthy(wallet and wallet.ok,
            'the item picker must not be refused after two refreshes: '
            .. tostring(wallet and wallet.err))
        resetConfig()
    end)
end)

--- How long until a refused action is allowed again.
---
--- "Slow down" on its own is not something a player can act on: they cannot
--- tell a two second wait from a five minute one, so they tap again, read
--- the same words, and conclude the button is broken.
describe('telling a player how long to wait', function()
    it('says nothing to wait for when the action is allowed', function()
        local s = newStack()
        local f = fixture(s)
        eq(s.ratelimit.retryAfter(f.creator, 'accept'), 0,
            'an untouched bucket has no wait')
    end)

    it('gives a wait once the bucket is spent', function()
        local s = newStack()
        local f = fixture(s)
        local rule = Config.Cooldowns.accept

        for _ = 1, rule.burst do
            truthy(s.ratelimit.check(f.creator, 'accept'), 'the burst should be allowed')
        end
        falsy(s.ratelimit.check(f.creator, 'accept'), 'and then refused')

        local wait = s.ratelimit.retryAfter(f.creator, 'accept')
        truthy(wait > 0, 'a refused action must say how long: got ' .. wait)
        truthy(wait <= rule.per,
            'and never longer than the window itself: got ' .. wait
            .. ' for a ' .. rule.per .. 's window')
    end)

    it('counts down as the bucket refills', function()
        local s = newStack()
        local f = fixture(s)
        local rule = Config.Cooldowns.informant

        for _ = 1, rule.burst do s.ratelimit.check(f.creator, 'informant') end
        local first = s.ratelimit.retryAfter(f.creator, 'informant')
        truthy(first > 0, 'spent, so there should be a wait')

        Env.advance(math.max(1, math.floor((rule.per / rule.burst) / 2)))
        local later = s.ratelimit.retryAfter(f.creator, 'informant')
        truthy(later < first,
            'the wait has to shrink as the bucket refills: ' .. first .. ' -> ' .. later)
    end)

    it('answers for a bucket the config does not have', function()
        local s = newStack()
        local f = fixture(s)
        -- An action with no rule falls back, and the fallback still has to be
        -- able to say how long — a wait of "nil" is a crash in the handler.
        local ok = s.ratelimit.retryAfter(f.creator, 'no_such_action')
        eq(ok, 0)
        for _ = 1, 20 do s.ratelimit.check(f.creator, 'no_such_action') end
        truthy(s.ratelimit.retryAfter(f.creator, 'no_such_action') > 0)
    end)
end)
