CrimsonBoot.define('server.lib.bridge', function() --- Safe calls into other resources: the one way this resource asks another
--- script for anything.
---
--- Every other script is optional at the call (rule: a missing script turns
--- its feature off, never raises). Bridge.call checks the resource is
--- started, calls its export inside pcall, and on a raise prints one line,
--- at most once a minute for the same export (Bridge.raised), as a
--- configuration problem (Log.problem). It never raises itself.

local Log = CrimsonBoot.requireShared('log')
local L = CrimsonBoot.requireShared('locale').t

local Bridge = {}

--- How long one export's raise keeps the next one quiet, in seconds.
Bridge.SAY_EVERY = 60

local saidAt = {}   -- [what] = os.time() of the last line printed for it

--- Whether a resource is started now.
---@param resource any
---@return boolean
function Bridge.started(resource)
    return type(resource) == 'string' and resource ~= '' and GetResourceState(resource) == 'started'
end

--- Say that a call into another resource raised: one line, at most once a
--- minute for the same `what` ('ox_inventory RemoveItem').
---@param what string
---@param err any
---@return boolean said
function Bridge.raised(what, err)
    local now = os.time()
    if saidAt[what] and now - saidAt[what] < Bridge.SAY_EVERY then return false end
    saidAt[what] = now
    Log.problem(('%s raised: %s'):format(what, tostring(err)))
    return true
end

--- Call another resource's export: exports[resource]:export(...).
---@param resource string
---@param export string
---@return boolean ok false when it is not started or the call raised
---@return any ... the export's answers, or the reason ('not started', the raise)
function Bridge.call(resource, export, ...)
    if not Bridge.started(resource) then return false, L('lib_bridge.not_started') end
    return Bridge.invoke(resource .. ' ' .. tostring(export), function(...)
        local api = exports[resource]
        return api[export](api, ...)
    end, ...)
end

--- Run `fn` inside pcall, as Bridge.call runs an export: a raise is one
--- line at most once a minute for the same `what` and answers false. The
--- adapters' calls (Integrations.call, server/adapters/init.lua) go
--- through here.
---@param what string what is being called ('ox_inventory RemoveItem')
---@param fn function
---@return boolean ok false when it raised
---@return any ... its answers, or the raise
function Bridge.invoke(what, fn, ...)
    local out = table.pack(pcall(fn, ...))
    if not out[1] then
        Bridge.raised(what, out[2])
        return false, out[2]
    end
    return true, table.unpack(out, 2, out.n)
end

--- Whether the phone's own word filter refuses this text from this player
--- (the phone adapter's ContainsBlacklistedWord, server/adapters/phone/).
--- False with no phone adapter, no filter, or a filter that raised.
---@param src integer
---@param text string
---@return boolean
function Bridge.phoneRefuses(src, text)
    -- Asked at use: the adapters are built on this file.
    local ok, blocked = CrimsonBoot.require('server.adapters.init')
        .call('phone', 'ContainsBlacklistedWord', src, text)
    return ok and blocked == true
end

--- Forget when each raise was last said (tests; a fresh start).
function Bridge.reset()
    saidAt = {}
end

return Bridge
end)
