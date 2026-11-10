--- Store calls that may raise (server/lib/db.lua): the answers through
--- when it works; false and the caller's own line, with the database's
--- error cut short, when it raises; never a raise.

local Db = require('server.lib.db')
local Util = require('crimson-hitman.shared.util')

local function saidLine(text)
    for i = #Env.console, 1, -1 do
        if Env.console[i]:find(text, 1, true) then return Env.console[i] end
    end
    return nil
end

describe('Db: store calls that may raise', function()
    it('hands back every answer of a call that works, and says nothing', function()
        newStack()
        local before = #Env.console
        local out = table.pack(Db.try('never said (%s)', function(a, b) return a + b, nil, 'c' end, 1, 2))
        eq(out[1], true)
        eq(out[2], 3)
        eq(out[3], nil)
        eq(out[4], 'c')
        eq(#Env.console, before)
    end)

    it('answers false and says the caller\'s line with the error where %s stands', function()
        newStack()
        local ok, err = Db.try('a staff record could not be written (%s); nothing changed', function()
            error('Lost connection to MySQL server', 0)
        end)
        eq(ok, false)
        eq(err, 'Lost connection to MySQL server', 'the raise itself, for the caller')
        local line = saidLine('a staff record could not be written (')
        truthy(line, 'printed whatever Debug says')
        truthy(line:find(Util.dbError('Lost connection to MySQL server'), 1, true), line)
    end)

    it('keeps the values a statement was sent out of the line', function()
        newStack()
        Db.try('the write failed (%s)', function()
            error('crimson-hitman was unable to execute a query!\nQuery: INSERT INTO t VALUES (?)\n'
                .. '["SECRET-VALUE"]\nDuplicate entry', 0)
        end)
        local line = saidLine('the write failed (')
        truthy(line)
        falsy(line:find('SECRET-VALUE', 1, true), line)
    end)

    it('says a quiet failure only with Config.Debug on', function()
        newStack()
        Config.Debug = false
        local before = #Env.console
        local ok = Db.quiet('a read failed (%s)', function() error('down', 0) end)
        eq(ok, false)
        eq(#Env.console, before, 'nothing printed with Debug off')
        Config.Debug = true
        Db.quiet('a read failed again (%s)', function() error('down', 0) end)
        truthy(saidLine('a read failed again ('), 'printed with Debug on')
        Config.Debug = false
    end)
end)
