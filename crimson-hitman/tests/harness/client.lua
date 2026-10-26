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

local Natives = require('crimson-hitman.tests.harness.natives')
local Env = Natives.env

local Client = {}

--- What the client sent to the server, and what it asked of lb-phone.
Client.toServer = {}
Client.coreCalls = {}
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
        -- Taking the app back off the phone, for a player who has just gone
        -- on duty. The export's name has moved across lb-phone releases and
        -- the client tries several, so the harness provides one of them and
        -- the "no export answered" path stays reachable through `without`.
        RemoveCustomApp = function(_, identifier)
            table.insert(Client.phone, { call = 'RemoveCustomApp', app = identifier })
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
        -- lb-phone's own shape: SetCameraComponent(options, cb). The callback
        -- it calls is the SECOND argument; options.cb is never read. Anything
        -- that is not a table is taken as empty options and opens a camera
        -- all the same. With no callback the real export waits for the shot
        -- (Citizen.Await) and returns the URL, which a test drives through
        -- Client.blockingCamera instead.
        SetCameraComponent = function(_, spec, cb)
            table.insert(Client.phone, { call = 'SetCameraComponent', spec = spec, cb = cb })
            Client.cameraCallback = cb
            return nil
        end,
        -- lb-phone's own: SaveToGallery(link), which returns nothing. The
        -- fallback for a page whose phone gives custom apps no
        -- components.saveToGallery.
        SaveToGallery = function(_, link)
            table.insert(Client.phone, { call = 'SaveToGallery', link = link })
        end,
        -- The game camera behind a custom app's own viewfinder, as
        -- lb-phone's app template turns it on and off. EnableWalkableCam
        -- takes whether it is the selfie camera.
        EnableWalkableCam = function(_, selfie)
            table.insert(Client.phone, { call = 'EnableWalkableCam', selfie = selfie })
        end,
        DisableWalkableCam = function()
            table.insert(Client.phone, { call = 'DisableWalkableCam' })
        end,
    }
end

--- What this player's ped has drawn in a clothing component: the mask (1)
--- is the bare face (0) unless a test puts something there
--- (Client.drawables), or makes the read throw (Client.drawableThrows).
local function drawableVariation(_, component)
    if Client.drawableThrows then error('GetPedDrawableVariation: no such ped') end
    return Client.drawables and Client.drawables[component] or 0
end

--- Run fn with the client-only natives in place, and take them away again.
---
--- Only while client code runs. FXServer has none of them, and one left
--- behind as a global is one every server spec after it could call: a
--- server reading a ped's clothes passed here while the native was nil on
--- every live server, and the nearby list it fed was always empty.
local function clientNatives(fn, ...)
    local had = _G.GetPedDrawableVariation
    _G.GetPedDrawableVariation = drawableVariation
    local results = table.pack(pcall(fn, ...))
    _G.GetPedDrawableVariation = had
    return table.unpack(results, 1, results.n)
end

--- What qbx_core's modules/playerdata.lua gives a client that loads it:
--- the QBX global, whose PlayerData qbx_core keeps current and empties on
--- unload. Read live from Client.playerData, so a test that changes this
--- player's metadata is changing what the module holds; nil is the module's
--- empty table, as before a character loads. Only while client code runs:
--- the server has no such global.
local playerDataModule = setmetatable({}, {
    __index = function(_, key)
        if key == 'PlayerData' then return Client.playerData or {} end
    end,
})

--- The client's view of qbx_core's exports. It has none the client should
--- need: every call is recorded (Client.coreCalls) and answers nothing, so a
--- test can say the death watcher never asked for the whole player record.
local function clientCore()
    return setmetatable({}, {
        __index = function(_, method)
            return function()
                Client.coreCalls[#Client.coreCalls + 1] = method
                return nil
            end
        end,
    })
end

--- Run something with this build's lb-phone in place and the console
--- captured.
---
--- Every entry point into the client needs both — a test that models a
--- missing export needs the proxy, and a test that checks the resource said
--- something useful needs the console — and doing it at four call sites is
--- four places to forget to put the real ones back.
local function withPhone(fn, ...)
    local realExports, realPrint, realQBX = _G.exports, _G.print, _G.QBX

    _G.exports = setmetatable({}, {
        __index = function(_, resource)
            if resource == 'lb-phone' then return Client.exports end
            if resource == 'qbx_core' then return clientCore() end
            return realExports[resource]
        end,
    })
    _G.QBX = playerDataModule
    _G.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        table.insert(Client.console, table.concat(parts, ' '))
    end

    local results = table.pack(clientNatives(fn, ...))

    _G.exports, _G.print, _G.QBX = realExports, realPrint, realQBX
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
    Client.coreCalls = {}
    Client.drawables, Client.drawableThrows = nil, nil
    Client.refuseRegistration = opts.refuseRegistration or false
    Client.console = {}
    -- The admin panel's page: what the focus was set to, in order, what was
    -- sent to the page, and the controls it reads (a key a test releases).
    Client.focus, Client.nuiMessages, Client.released = {}, {}, {}

    Client.exports = defaultExports()
    for _, name in ipairs(opts.without or {}) do
        Client.exports[name] = nil
    end

    -- The client half of the runtime.
    _G.RegisterNUICallback = function(name, fn) Client.nui[name] = fn end
    _G.SetNuiFocus = function(hasFocus, hasCursor)
        table.insert(Client.focus, { focus = hasFocus, cursor = hasCursor })
    end
    _G.SendNUIMessage = function(message) table.insert(Client.nuiMessages, message) end
    _G.DisableControlAction = function() end
    -- A BOOL native: 1 or false, never true.
    _G.IsDisabledControlJustReleased = function(_, control)
        return Client.released[control] and 1 or false
    end
    -- The build Qbox enforces, whose event layouts the client reads.
    _G.GetGameBuildNumber = function() return Client.gameBuild or opts.gameBuild or 3258 end
    _G.PlayerPedId = function() return Client.ped or 1003 end
    -- A BOOL native, so 1 or false, as the game answers it; never true.
    _G.IsEntityDead = function() return Client.dead == true and 1 or false end
    -- What a medical resource says about this player: nil player data is a
    -- qbx_core that cannot be read, which is every test that does not set it.
    -- The bag says a character is loaded, as qbx_core's does once one is.
    Client.playerData, Client.state = nil, { isLoggedIn = true }
    _G.LocalPlayer = setmetatable({}, { __index = function(_, key)
        if key == 'state' then return Client.state end
    end })
    _G.TriggerServerEvent = function(name, ...)
        table.insert(Client.toServer, { name = name, args = { ... } })
    end
    -- The same, sent in pieces at `bps` bytes a second; marked, so a test
    -- can tell a photo sent latent from one sent as an ordinary event.
    _G.TriggerLatentServerEvent = function(name, bps, ...)
        table.insert(Client.toServer, { name = name, args = { ... }, latent = true, bps = bps })
    end

    -- Registration and the event handlers are the whole point, so they go
    -- into the client's own tables rather than the server's.
    local realNet, realAdd = _G.RegisterNetEvent, _G.AddEventHandler
    _G.RegisterNetEvent = function(name, fn) Client.netEvents[name] = fn end
    -- Several files can listen for one engine event (onResourceStop is
    -- main.lua's and admin.lua's), as the engine lets them: each runs.
    _G.AddEventHandler = function(name, fn)
        local before = Client.handlers[name]
        if before then
            Client.handlers[name] = function(...)
                before(...)
                return fn(...)
            end
        else
            Client.handlers[name] = fn
        end
    end

    package.loaded['crimson-hitman.client.main'] = nil
    local ok, app = withPhone(require, 'crimson-hitman.client.main')

    -- The mugshot half, loaded the way the manifest loads it: after
    -- shared/util.lua has published CrimsonUtil, and after main.lua. It had
    -- no coverage at all — not one line, ever — which is how a file whose
    -- own comments explain a clock-wrap guard came to have nothing checking
    -- the guard.
    local mugOk, mugErr = true, nil
    if ok and not opts.withoutMugshot then
        package.loaded['crimson-hitman.client.mugshot'] = nil
        mugOk, mugErr = withPhone(require, 'crimson-hitman.client.mugshot')
    end

    -- And the admin panel's page, last, as the manifest lists it.
    local adminOk, admin = true, nil
    if ok and mugOk then
        package.loaded['crimson-hitman.client.admin'] = nil
        adminOk, admin = withPhone(require, 'crimson-hitman.client.admin')
    end

    _G.RegisterNetEvent, _G.AddEventHandler = realNet, realAdd

    if not ok then error(app, 0) end
    if not mugOk then error(mugErr, 0) end
    if not adminOk then error(admin, 0) end
    Client.app = app
    Client.admin = admin
    return Client
end

--- Run the client's background threads for a bounded number of ticks.
---
--- The death watcher is `while true do Wait(1000) ... end`: it cannot be
--- called, only entered and then stopped. Wait counts, and a sentinel
--- unwinds the loop once the count is reached — the same shape boot.lua's
--- dependency wait is driven by, for the same reason.
---
--- Each thread gets its own count, so the registration thread's waits do
--- not spend the death watcher's.
function Client.ticks(n)
    local STOP = {}
    local realWait = _G.Wait

    -- Not drained. A watcher is re-entered on every call so a test can put
    -- the player through dead, up, and dead again — the transitions are the
    -- whole behaviour, and a runner that consumed the thread could only ever
    -- see the first one.
    local threads = {}
    for i = 1, #Env.threads do threads[i] = Env.threads[i] end

    -- Inside the client's view of the exports, as the game runs them.
    local realExports, realQBX = _G.exports, _G.QBX
    _G.exports = setmetatable({}, {
        __index = function(_, resource)
            if resource == 'qbx_core' then return clientCore() end
            return realExports[resource]
        end,
    })
    _G.QBX = playerDataModule

    for _, fn in ipairs(threads) do
        local count = 0
        _G.Wait = function()
            count = count + 1
            if count > (n or 1) then error(STOP) end
        end
        local ok, err = clientNatives(fn)
        if not ok and err ~= STOP then
            _G.Wait, _G.exports, _G.QBX = realWait, realExports, realQBX
            error(err, 0)
        end
    end

    _G.Wait, _G.exports, _G.QBX = realWait, realExports, realQBX
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
    -- Counted, not just flagged. Answering an NUI callback twice throws
    -- inside the browser the phone is drawn in, and a boolean cannot tell
    -- "answered" from "answered three times".
    Client.answerCount = 0
    local ok, err = withPhone(handler, payload, function(value)
        Client.answered, Client.answer = true, value
        Client.answerCount = Client.answerCount + 1
    end)
    if not ok then return nil, err end
    return Client.answered, Client.answer
end

--- One pass of the client's reconciler, with this build's lb-phone in
--- place. In the resource this runs on a heartbeat; a `while true` loop is
--- not something the harness can run, so the pass itself is what tests
--- drive.
function Client.reconcile()
    withPhone(function() Client.app.reconcile() end)
end

--- lb-phone lost the app: it is off the phone and nothing said so. The
--- state a missed transition leaves behind, and the one the reconciler
--- exists to recover from.
function Client.appGone()
    Client.app.forgetRegistration()
end

--- Hand a photo (or a cancellation) back through the camera callback, the
--- way lb-phone does.
---
--- With this build's exports in place, because in production this callback
--- runs inside lb-phone's own camera and the code in it reaches for lb-phone
--- exports. Calling it bare tests a situation that cannot happen and misses
--- everything it does there.
function Client.camera(src)
    if not Client.cameraCallback then return false end
    local cb = Client.cameraCallback
    withPhone(function() cb(src) end)
    return true
end

--- Fire every timer the client has queued, as the engine would once their
--- delay has passed. The camera's own timeout lives on one of these.
function Client.runTimeouts()
    local timers = Env.timers
    Env.timers = {}
    withPhone(function()
        for i = 1, #timers do pcall(timers[i].fn) end
    end)
    return #timers
end

--- Whether anything the client printed mentions this.
function Client.said(text)
    for i = 1, #Client.console do
        if Client.console[i]:find(text, 1, true) then return true end
    end
    return false
end

return Client
