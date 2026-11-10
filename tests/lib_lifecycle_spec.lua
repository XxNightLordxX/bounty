--- Cleanup lists (server/lib/lifecycle.lua): each module's step run in
--- order against the modules in hand, a missing one skipped, a raise said
--- and the rest still run. Used by server/bridges.lua for a player leaving,
--- a contract ending and a hitman stepping off one.

local Lifecycle = require('server.lib.lifecycle')

describe('Lifecycle: cleanup lists', function()
    it('runs every step in order with the same arguments', function()
        newStack()
        local calls = {}
        local modules = {
            a = { forget = function(...) calls[#calls + 1] = { 'a', ... } end },
            b = { clear = function(...) calls[#calls + 1] = { 'b', ... } end },
        }
        local ran, failed = Lifecycle.run('a test', modules, { { 'b', 'clear' }, { 'a', 'forget' } }, 'CID1', 2)
        eq(ran, 2)
        eq(failed, 0)
        eq(calls[1][1], 'b', 'in the order listed')
        eq(calls[1][2], 'CID1')
        eq(calls[1][3], 2)
        eq(calls[2][1], 'a')
    end)

    it('skips a module that is not wired, or has no such function', function()
        newStack()
        local ran = Lifecycle.run('a test', { a = {}, c = 'not a module' },
            { { 'a', 'forget' }, { 'b', 'forget' }, { 'c', 'forget' } }, 'CID1')
        eq(ran, 0)
        eq(Lifecycle.run('a test', nil, { { 'a', 'forget' } }), 0, 'nor raises with no modules at all')
    end)

    it('says a step that raises in one line and still runs the rest', function()
        newStack()
        local after = false
        local modules = {
            bad = { clearPlayer = function() error('stale handle', 0) end },
            good = { clearPlayer = function() after = true end },
        }
        local ok, ran, failed = pcall(Lifecycle.run, 'a player leaving', modules,
            { { 'bad', 'clearPlayer' }, { 'good', 'clearPlayer' } }, 'CID1')
        truthy(ok, 'never raises')
        eq(ran, 2)
        eq(failed, 1)
        truthy(after, 'the step after the raise still ran')
        local said = false
        for _, line in ipairs(Env.console) do
            if line:find('a player leaving: bad.clearPlayer raised: stale handle', 1, true) then said = true end
        end
        truthy(said, 'the line names the list, the step and the raise')
    end)
end)
