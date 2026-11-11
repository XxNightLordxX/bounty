CrimsonBoot.define('server.lib.db', function() --- Store calls that may raise: the one wrapper for "try it, and say so if
--- the database would not".
---
--- A store call raises on mysql when the database refuses (a lost
--- connection, a full disk). Each caller says in its own words what that
--- means for the player; the line is that sentence with the database's
--- error put where it says %s, kept short and free of the values the
--- statement was sent (Util.dbError).

local Log = CrimsonBoot.requireShared('log')
local Util = CrimsonBoot.requireShared('util')

local Db = {}

local function attempt(say, said, fn, ...)
    local out = table.pack(pcall(fn, ...))
    if out[1] then return table.unpack(out, 1, out.n) end
    say(said:format(Util.dbError(out[2])))
    return false, out[2]
end

--- Run a store call; on a raise print `said` (Log.always) and answer false.
---@param said string the line, with %s where the database error goes
---@param fn function the store call
---@return boolean ok
---@return any ... its answers, or the raise
function Db.try(said, fn, ...)
    return attempt(Log.always, said, fn, ...)
end

--- The same, the line printed only with Config.Debug on (Log.debug): for a
--- read that is simply tried again later.
---@param said string
---@param fn function
---@return boolean ok
---@return any ...
function Db.quiet(said, fn, ...)
    return attempt(Log.debug, said, fn, ...)
end

return Db
end)
