CrimsonBoot.define('server.adapters.init', function() --- The adapters, loaded and registered (shared/integrations.lua), and the
--- one line said for each kind left without one.
---
--- Every server module that calls another resource asks here:
---   Integrations.get(kind)              the adapter answering now, or nil
---   Integrations.call(kind, fn, ...)    the safe call: false, 'off' with no
---                                       adapter; a raise is one line a
---                                       minute and answers false (Bridge)
--- docs/dev/adapters.md says how a server adds its own.

local Integrations = CrimsonBoot.requireShared('integrations')
local Bridge = CrimsonBoot.require('server.lib.bridge')
local Log = CrimsonBoot.requireShared('log')
local LIST = CrimsonBoot.require('server.adapters.list')

--- Client kinds have their functions on the client; the server keeps what
--- it needs to say which one is in use. Clothing adapters only listen for
--- events, which costs nothing whether the resource is there or not.
local function descriptor(kind, name)
    local adapter = { resource = name }
    if kind == 'clothing' then adapter.detect = function() return true end end
    return adapter
end

for _, spec in ipairs(Integrations.KINDS) do
    for _, name in ipairs(LIST[spec.kind] or {}) do
        if not Integrations.adapter(spec.kind, name) then
            local adapter
            if spec.side == 'client' then
                adapter = descriptor(spec.kind, name)
            else
                adapter = CrimsonBoot.require(('server.adapters.%s.%s'):format(spec.kind, name))
            end
            Integrations.register(spec.kind, name, adapter)
        end
    end
end

--- Call one of a kind's functions safely: as Bridge.call does an export.
---@param kind string
---@param fn string the function's name on the adapter
---@return boolean ok false with no adapter, no such function, or a raise
---@return any ... its answers, or why not ('off', the raise)
function Integrations.call(kind, fn, ...)
    local adapter = Integrations.get(kind)
    if not adapter then return false, 'off' end
    local f = adapter[fn]
    if type(f) ~= 'function' then return false, 'no ' .. tostring(fn) end
    return Bridge.invoke(adapter.name .. ' ' .. tostring(fn), f, ...)
end

--- What was said last for each kind: the adapter's name, or false for off.
local said = {}

--- Say each kind that has no adapter answering: one line each, printed
--- whatever Debug says when a feature that uses it is on, a Debug line
--- when none is. Only what changed since the last call is said again, so
--- this runs at start and after every resource start or stop.
---@param force boolean|nil say every kind again (a fresh start)
---@return string[] lines said
function Integrations.report(force)
    if force then said = {} end
    local lines = {}
    for _, st in ipairs(Integrations.statusAll()) do
        local now = st.active or false
        if said[st.kind] ~= now then
            said[st.kind] = now
            local line = Integrations.offLine(st)
            if line then
                if st.needed or st.required then Log.notice(line) else Log.debug(line) end
                lines[#lines + 1] = line
            else
                Log.debug(('integration %s: %s'):format(st.kind, st.active))
            end
        end
    end
    return lines
end

--- Whether a resource is one some adapter stands for (a start or stop of
--- it is worth a report).
---@param resource string
---@return boolean
function Integrations.watches(resource)
    for _, spec in ipairs(Integrations.KINDS) do
        for _, name in ipairs(Integrations.names(spec.kind)) do
            if Integrations.adapter(spec.kind, name).resource == resource then return true end
        end
    end
    return false
end

return Integrations
end)
