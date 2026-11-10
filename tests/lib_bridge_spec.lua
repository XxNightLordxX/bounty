--- Safe calls into other resources (server/lib/bridge.lua): a resource
--- that is not started, or an export that raises, is an answer, never a
--- raise, and a raise is said in one line at most once a minute.

local Bridge = require('server.lib.bridge')
local Log = require('crimson-hitman.shared.log')

--- Run fn with these as the other resources' exports, put back after.
local function withExports(fake, fn)
    local real = _G.exports
    _G.exports = fake
    local ok, err = pcall(fn)
    _G.exports = real
    if not ok then error(err, 0) end
end

local function problemsSaying(text)
    local n = 0
    for _, line in ipairs(Log.view().problems) do
        if line:find(text, 1, true) then n = n + 1 end
    end
    return n
end

describe('Bridge: calls into other resources', function()
    local function fresh()
        newStack()
        Bridge.reset()
        Log.clearProblems()
    end

    it('knows a started resource from one that is not, and from no name at all', function()
        fresh()
        Natives.resourceStates['some-res'] = 'started'
        truthy(Bridge.started('some-res'))
        Natives.resourceStates['some-res'] = 'stopped'
        falsy(Bridge.started('some-res'))
        falsy(Bridge.started('never-installed'))
        falsy(Bridge.started(nil))
        falsy(Bridge.started(''))
        falsy(Bridge.started(42))
    end)

    it('calls the export as exports[res]:Name(...) and hands back every answer', function()
        fresh()
        Natives.resourceStates['fake-res'] = 'started'
        local gotSelf, gotArgs
        local api = {}
        api.Pair = function(self, a, b)
            gotSelf, gotArgs = self, { a, b }
            return 'x', nil, 'z'
        end
        withExports({ ['fake-res'] = api }, function()
            local out = table.pack(Bridge.call('fake-res', 'Pair', 1, 2))
            eq(out[1], true)
            eq(out[2], 'x')
            eq(out[3], nil)
            eq(out[4], 'z')
        end)
        eq(gotSelf, api, 'called as a method, as exports.res:Name is')
        eq(gotArgs[1], 1)
        eq(gotArgs[2], 2)
    end)

    it('answers false for a resource that is not started, and calls nothing', function()
        fresh()
        local called = false
        withExports({ ['off-res'] = { Go = function() called = true end } }, function()
            local ok, why = Bridge.call('off-res', 'Go')
            eq(ok, false)
            eq(why, 'not started')
        end)
        falsy(called)
        eq(#Log.view().problems, 0, 'nothing said: not running is a choice, not a fault')
    end)

    it('turns a raise, or a missing export, into false and one line, never a raise', function()
        fresh()
        Natives.resourceStates['bad-res'] = 'started'
        withExports({ ['bad-res'] = { Boom = function() error('it broke', 0) end } }, function()
            local ok, err = Bridge.call('bad-res', 'Boom')
            eq(ok, false)
            eq(err, 'it broke')
            local okMissing = Bridge.call('bad-res', 'NoSuchExport')
            eq(okMissing, false, 'calling an export that is not there is a refusal too')
        end)
        eq(problemsSaying('bad-res Boom raised: it broke'), 1, 'said, naming the resource and export')
        eq(problemsSaying('bad-res NoSuchExport raised'), 1)
    end)

    it('says the same export at most once a minute', function()
        fresh()
        Env.time = 1000
        truthy(Bridge.raised('ox_inventory Search', 'one'))
        falsy(Bridge.raised('ox_inventory Search', 'two'), 'not again inside the minute')
        truthy(Bridge.raised('ox_inventory AddItem', 'three'), 'another export is its own')
        Env.time = 1000 + Bridge.SAY_EVERY
        truthy(Bridge.raised('ox_inventory Search', 'four'), 'again once the minute is up')
        eq(problemsSaying('ox_inventory Search raised: two'), 0)
        eq(problemsSaying('ox_inventory Search raised: four'), 1)
    end)

    it('asks lb-phone\'s word filter, and lets text through when it cannot', function()
        fresh()
        truthy(Bridge.phoneRefuses(1, 'a slur here'), 'the filter refuses')
        falsy(Bridge.phoneRefuses(1, 'hello'), 'and passes clean text')
        Natives.noWordFilter = true
        local ok, refused = pcall(Bridge.phoneRefuses, 1, 'a slur here')
        Natives.noWordFilter = nil
        truthy(ok, 'a filter that raises never raises here')
        falsy(refused, 'and lets the text through')
        Natives.resourceStates['lb-phone'] = nil
        falsy(Bridge.phoneRefuses(1, 'a slur here'), 'nor with lb-phone not started')
    end)
end)
