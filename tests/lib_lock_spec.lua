--- The one serialiser (server/lib/lock.lua, Lock.new): one at a time per
--- key, the second refused as busy, every key let go however the work ends.
--- Used by Contracts.serialized, freezes, sanctions, payments, settings
--- saves, target limit writes, review items and protection jobs.

local Lock = require('server.lib.lock')

describe('Lock: one at a time per key', function()
    it('runs the work holding its keys and hands back every answer', function()
        local lock = Lock.new()
        local seen
        local a, b, c, d = lock.run('k', function(x, y)
            seen = lock.held('k')
            return x, y, nil, 'four'
        end, 1, 2)
        truthy(seen, 'the key is held while the work runs')
        eq(a, 1)
        eq(b, 2)
        eq(c, nil)
        eq(d, 'four', 'answers past a nil are not lost')
        falsy(lock.held('k'), 'and let go after')
    end)

    it('refuses a second run on a held key as busy, and runs it once the first is done', function()
        local lock = Lock.new()
        local co = coroutine.create(function()
            return lock.run('player:1', function()
                coroutine.yield('waiting on the store')
                return true, 'first'
            end)
        end)
        local _, said = coroutine.resume(co)
        eq(said, 'waiting on the store')
        local ok, err, extra = lock.run('player:1', function() return true end)
        eq(ok, false)
        eq(err, CH.ERR.BUSY)
        eq(extra, nil, 'no detail without a busy option')
        -- Another key is not held.
        truthy(lock.run('player:2', function() return true end), 'another key runs alongside')
        local _, first, word = coroutine.resume(co)
        truthy(first)
        eq(word, 'first')
        truthy(lock.run('player:1', function() return true end), 'free again once the first ended')
    end)

    it('refuses when any of several keys is held, and holds them all', function()
        local lock = Lock.new()
        local inner
        lock.run({ 'contract:1', 'settle:1' }, function()
            inner = table.pack(lock.run({ 'settle:1' }, function() return true end))
            truthy(lock.held('contract:1') and lock.held('settle:1'))
        end)
        eq(inner[1], false)
        eq(inner[2], CH.ERR.BUSY)
        falsy(lock.held('contract:1') or lock.held('settle:1'), 'every key let go')
    end)

    it('says how long the oldest key has been held, through the busy option', function()
        local lock = Lock.new({ busy = function(heldMs) return { heldMs = heldMs } end })
        local answer
        lock.run('a', function()
            answer = table.pack(lock.run({ 'b', 'a' }, function() return true end))
        end)
        eq(answer[2], CH.ERR.BUSY)
        eq(type(answer[3]), 'table')
        truthy(answer[3].heldMs >= 0, 'a wait, never negative')
        local fixed = Lock.new({ busy = function() return 'being saved' end })
        local said
        fixed.run('s', function() said = select(3, fixed.run('s', function() end)) end)
        eq(said, 'being saved')
    end)

    it('lets go of every key when the work raises, and raises it on', function()
        local lock = Lock.new()
        local ok, err = pcall(lock.run, { 'x', 'y' }, function() error('store down', 0) end)
        falsy(ok)
        eq(err, 'store down', 'the raise is the caller\'s, unchanged')
        falsy(lock.held('x') or lock.held('y'))
        truthy(lock.run('x', function() return true end), 'and the key works again')
    end)

    it('answers a raise itself with the raised option, never raising', function()
        local got
        local lock = Lock.new({ raised = function(err)
            got = err
            return false, 'store_failed'
        end })
        local ok, err = lock.run('k', function() error('boom', 0) end)
        eq(ok, false)
        eq(err, 'store_failed')
        eq(got, 'boom')
        falsy(lock.held('k'))
    end)

    it('keeps each lock\'s keys its own, and reset lets go of all of them', function()
        local a, b = Lock.new(), Lock.new()
        a.run('cid', function()
            truthy(b.run('cid', function() return true end), 'the same key in another lock runs')
            a.reset()
            falsy(a.held('cid'), 'reset lets go')
        end)
    end)
end)
