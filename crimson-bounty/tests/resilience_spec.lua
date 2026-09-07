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

--- An lb-phone build without the word filter.
---
--- The resource states its own rule twice — in client/main.lua and in the
--- static check that enforces it — that lb-phone ships its server code
--- escrowed, its export surface has moved across releases, and indexing an
--- export that is not there throws. The check walked only the client. The
--- server broke the rule in two places, and comms.lua guards an export a
--- hundred and ninety lines below the one it does not.
---
--- Both are inside handlers, so the throw is not a degraded feature: it is
--- every contract refused with server_error and every message the same.
describe('a phone build with no word filter', function()
    local function withoutFilter(fn)
        Natives.noWordFilter = true
        local ok, err = pcall(fn)
        Natives.noWordFilter = nil
        if not ok then error(err, 0) end
    end

    it('still places a contract', function()
        local s = newStack()
        local f = fixture(s)
        withoutFilter(function()
            local c, err = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'Unpaid debt',
                mode = CB.MODE.EXCLUSIVE,
                reward = { baseline = { cash = 5000 } },
            })
            truthy(c, 'an export this build does not have took the whole '
                .. 'resource down: ' .. tostring(err))
        end)
    end)

    it('still applies the rules this resource owns', function()
        local s = newStack()
        local f = fixture(s)
        withoutFilter(function()
            local c, err = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'come to discord.gg/whatever',
                mode = CB.MODE.EXCLUSIVE,
                reward = { baseline = { cash = 5000 } },
            })
            falsy(c, 'the pattern denylist is this resource\'s own and does '
                .. 'not depend on the phone')
            eq(err, CB.ERR.INVALID_INPUT)
        end)
    end)

    it('still carries a message between the two parties', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        s.contracts.accept(f.hunter, c.id, false)
        -- The creator addresses a thread; only the hunter's side may leave
        -- it implicit, because they have exactly one.
        local threads = s.comms.threads(f.creator, c.id)
        truthy(#threads > 0, 'there has to be somebody to write to')
        withoutFilter(function()
            local ok, err = s.comms.send(f.creator, c.id, threads[1].handle,
                'Where are you?')
            truthy(ok, 'the relay went down with an export it does not need: '
                .. tostring(err))
        end)
    end)

    it('still refuses what the phone refuses, where the phone is there', function()
        local s = newStack()
        local f = fixture(s)
        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'you absolute slur',
            mode = CB.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 5000 } },
        })
        falsy(c, 'a build that has the filter must still use it')
        eq(err, CB.ERR.INVALID_INPUT)
    end)
end)
