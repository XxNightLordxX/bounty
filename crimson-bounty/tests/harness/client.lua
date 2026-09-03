--- Runs client/main.lua for real.
---
--- The client is 200 lines that sit between the UI and the server, and until
--- this existed not one of them had ever been executed by a test. It is
--- where a build of lb-phone without an export throws out of an event
--- handler, and where an NUI callback that never answers leaves the player
--- looking at a button that does nothing.
---
--- Only the natives the client needs are added here; everything else comes
--- from the server harness, so the two halves are held to one set of stubs.

local Natives = require('crimson-bounty.tests.harness.natives')
local Env = Natives.env

local Client = {}

--- What the client sent to the server, and what it asked of lb-phone.
Client.toServer = {}
Client.phone = {}

--- The client's own handler tables, kept apart from the server's: both
--- halves register events under the same names, and a shared table would
--- have one silently overwrite the other.
Client.nui = {}
Client.netEvents = {}
Client.handlers = {}

--- Which lb-phone exports this build has. A test removes one to model an
--- older or differently-built phone, which is the case the guards exist for.
Client.exports = {}

local function defaultExports()
    return {
        AddCustomApp = function(_, spec)
            table.insert(Client.phone, { call = 'AddCustomApp', spec = spec })
            if Client.refuseRegistration then return false end
            return true
        end,
        SendCustomAppMessage = function(_, app, message)
            table.insert(Client.phone, { call = 'SendCustomAppMessage', app = app, message = message })
            return true
        end,
        SendNotification = function(_, data)
            table.insert(Client.phone, { call = 'SendNotification', data = data })
            return true
        end,
        SetCameraComponent = function(_, spec)
            table.insert(Client.phone, { call = 'SetCameraComponent', spec = spec })
            Client.cameraCallback = spec and spec.cb
            return true
        end,
    }
end

--- Run something with this build's lb-phone in place and the console
--- captured.
---
--- Every entry point into the client needs both — a test that models a
--- missing export needs the proxy, and a test that checks the resource said
--- something useful needs the console — and doing it at four call sites is
--- four places to forget to put the real ones back.
local function withPhone(fn, ...)
    local realExports, realPrint = _G.exports, _G.print

    _G.exports = setmetatable({}, {
        __index = function(_, resource)
            if resource == 'lb-phone' then return Client.exports end
            return realExports[resource]
        end,
    })
    _G.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        table.insert(Client.console, table.concat(parts, ' '))
    end

    local results = table.pack(pcall(fn, ...))

    _G.exports, _G.print = realExports, realPrint
    return table.unpack(results, 1, results.n)
end

--- Load the client fresh.
---
--- Its module-level state — whether the app registered, the outstanding
--- request map, the retry latch — must not leak between tests any more than
--- a contract may.
---@param opts table|nil { without = { 'SendNotification' }, refuseRegistration = bool }
function Client.boot(opts)
    opts = opts or {}

    Client.toServer, Client.phone = {}, {}
    Client.nui, Client.netEvents, Client.handlers = {}, {}, {}
    Client.cameraCallback = nil
    Client.refuseRegistration = opts.refuseRegistration or false
    Client.console = {}

    Client.exports = defaultExports()
    for _, name in ipairs(opts.without or {}) do
        Client.exports[name] = nil
    end

    -- The client half of the runtime.
    _G.RegisterNUICallback = function(name, fn) Client.nui[name] = fn end
    _G.PlayerPedId = function() return Client.ped or 1003 end
    _G.IsEntityDead = function() return Client.dead == true end
    _G.TriggerServerEvent = function(name, ...)
        table.insert(Client.toServer, { name = name, args = { ... } })
    end

    -- Registration and the event handlers are the whole point, so they go
    -- into the client's own tables rather than the server's.
    local realNet, realAdd = _G.RegisterNetEvent, _G.AddEventHandler
    _G.RegisterNetEvent = function(name, fn) Client.netEvents[name] = fn end
    _G.AddEventHandler = function(name, fn) Client.handlers[name] = fn end

    package.loaded['crimson-bounty.client.main'] = nil
    local ok, app = withPhone(require, 'crimson-bounty.client.main')

    _G.RegisterNetEvent, _G.AddEventHandler = realNet, realAdd

    if not ok then error(app, 0) end
    Client.app = app
    return Client
end

--- Run whatever CreateThread queued, with lb-phone's exports in place.
---
--- The registration thread is the client's whole startup, and it is the one
--- thing a test of registration cannot skip.
function Client.runThreads()
    -- The startup thread waits for lb-phone before doing anything, and Wait
    -- is a no-op here: without this it is a busy loop that never ends.
    if Natives.resourceStates['lb-phone'] == nil then
        Natives.resourceStates['lb-phone'] = 'started'
    end

    -- A loop the client never leaves would otherwise hang the whole suite
    -- with no indication of which test did it. Bounded generously: the
    -- registration retry is ten attempts with a wait between each.
    local realWait = _G.Wait
    local waits = 0
    _G.Wait = function()
        waits = waits + 1
        if waits > 10000 then
            error('the client is waiting in a loop that does not end', 0)
        end
    end

    local threads = Env.threads
    Env.threads = {}
    local failures = {}
    withPhone(function()
        for i = 1, #threads do
            local ok, err = pcall(threads[i])
            if not ok then failures[#failures + 1] = tostring(err) end
        end
    end)

    _G.Wait = realWait
    Client.threadErrors = failures
    return #threads
end

--- Fire one of the client's net-event handlers, as the server would.
function Client.fire(event, ...)
    local handler = Client.netEvents[event] or Client.handlers[event]
    if not handler then return false, 'no handler for ' .. tostring(event) end
    return withPhone(handler, ...)
end

--- Invoke an NUI callback the way the page does, and collect its answer.
--- Invoke an NUI callback the way the page does.
---
--- The answer often arrives later — the callback asks the server and hands
--- the page its reply when the result event comes back — so it is recorded
--- on Client rather than only returned, and a test can check it after
--- whatever else had to happen first.
function Client.nuiCall(name, payload)
    local handler = Client.nui[name]
    if not handler then return nil, 'no NUI callback named ' .. tostring(name) end

    Client.answered, Client.answer = false, nil
    local ok, err = withPhone(handler, payload, function(value)
        Client.answered, Client.answer = true, value
    end)
    if not ok then return nil, err end
    return Client.answered, Client.answer
end

--- Whether anything the client printed mentions this.
function Client.said(text)
    for i = 1, #Client.console do
        if Client.console[i]:find(text, 1, true) then return true end
    end
    return false
end

return Client
