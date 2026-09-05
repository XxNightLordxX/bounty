--- One bad thing must not take everything with it.
---
--- Found by an adversarial audit of why the app kept showing an empty
--- target list and an empty item picker on a live server while 680 tests
--- passed. Each of these turns one local failure into the whole feature
--- going silent, and none of them is visible from a harness where nothing
--- ever throws.

local function call(name, source, payload)
    local fire = Env.events['crimson-bounty:' .. name]
    if not fire then return nil, 'no handler registered for ' .. name end
    Env.clientEvents = {}
    _G.source = source
    local ok, err = pcall(fire, payload or {})
    _G.source = nil
    if not ok then return nil, 'THREW: ' .. tostring(err) end
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-bounty:result' then return event.args[1] end
    end
    return nil
end

describe('one player the framework cannot describe', function()
    local function crowd(s)
        local f = fixture(s)
        Env.addPlayer({ source = 10, citizenid = 'PERSON10', license = 'license:p10',
            firstname = 'Ada', lastname = 'Quill' })
        Env.addPlayer({ source = 11, citizenid = 'PERSON11', license = 'license:p11',
            firstname = 'Bo', lastname = 'Renn' })
        return f
    end

    --- A source that is connected but whose character record is not there
    --- yet, or a framework export that raises for it. Ordinary on a live
    --- server: somebody is always mid-join.
    local function withOneBadPlayer(badSource, fn)
        local real = exports.qbx_core.GetPlayer
        exports.qbx_core.GetPlayer = function(self, src)
            if tonumber(src) == badSource then
                error('qbx_core: player is not loaded')
            end
            return real(self, src)
        end
        local ok, err = pcall(fn)
        exports.qbx_core.GetPlayer = real
        if not ok then error(err, 0) end
    end

    it('does not empty the roster for everybody else', function()
        local s = newStack()
        crowd(s)
        withOneBadPlayer(11, function()
            local online = s.identity.online()
            truthy(#online >= 2,
                'one player mid-join must not take the whole roster with them, '
                .. 'got ' .. #online)
        end)
    end)

    it('still lists the others when browsing', function()
        local s = newStack()
        crowd(s)
        withOneBadPlayer(11, function()
            local reply = call('browseTargets', 1, { scope = 'all' })
            truthy(reply and reply.ok,
                'the handler must answer: ' .. tostring(reply and reply.err))
            truthy(#reply.data.people > 0,
                'the city is not empty because one person is still loading')
        end)
    end)

    it('leaves out only the one it could not read', function()
        local s = newStack()
        crowd(s)
        withOneBadPlayer(11, function()
            local names = {}
            for _, person in ipairs(call('browseTargets', 1, { scope = 'all' }).data.people) do
                names[person.name] = true
            end
            truthy(names['Ada Quill'], 'the readable ones are all there')
            falsy(names['Bo Renn'], 'and the unreadable one is simply absent')
        end)
    end)
end)

describe('a request the gate itself cannot process', function()
    it('is still answered', function()
        -- The gate runs before the handler's pcall, so a throw inside it
        -- left the request with no reply at all — and the page waits fifteen
        -- seconds on every request it sends.
        local s = newStack()
        fixture(s)

        local real = s.identity.gate
        s.identity.gate = function() error('something in the framework broke') end
        local reply, why = call('list', 1, { page = 1 })
        s.identity.gate = real

        truthy(reply, 'no answer came back: ' .. tostring(why))
        falsy(reply.ok, 'and it is a refusal, not a success')
    end)

    it('does not take the whole event handler down with it', function()
        local s = newStack()
        fixture(s)
        local real = s.identity.gate
        s.identity.gate = function() error('boom') end
        local _, why = call('list', 1, { page = 1 })
        s.identity.gate = real
        falsy(why and why:find('THREW', 1, true),
            'the handler threw out to the engine: ' .. tostring(why))
    end)
end)
