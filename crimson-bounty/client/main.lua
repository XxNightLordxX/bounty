--- Client bootstrap: registers the app with lb-phone and bridges the UI.
---
--- The client holds no authority. It renders what the server sends, asks for
--- what the player clicks, and reports only two facts about itself: that this
--- player died, and that this player was revived.

local App = {}

--- Outstanding requests, keyed by a per-request id rather than by event
--- name: two searches in flight at once would otherwise resolve into each
--- other's callbacks and show the wrong results.
local pending = {}
local requestSeq = 0
local appReady = false

--------------------------------------------------------------------------
-- Talking to lb-phone
--------------------------------------------------------------------------

--- Run something that calls an lb-phone export, and survive a build that
--- does not have it.
---
--- lb-phone ships its server code escrowed and its export surface has moved
--- across releases. Indexing an export that is not there throws, and every
--- one of these is called from inside an event handler or an NUI callback:
--- the throw takes the handler with it, so the player gets no notification,
--- no refresh, or — worst — an app left waiting forever for a reply to a
--- button they pressed.
---
--- Returns whether the call went through, so a caller that owes the UI an
--- answer can still give it one.
---@param what string named in the console line, so a failure says which
---@param fn fun():any
---@return boolean ok
---@return any result
local function phone(what, fn)
    local ok, result = pcall(fn)
    if ok then return true, result end
    print(('[crimson-bounty] lb-phone %s failed on this build: %s')
        :format(what, tostring(result)))
    return false
end

--------------------------------------------------------------------------
-- lb-phone registration
--------------------------------------------------------------------------

--- What this resource's UI build is, for cache-busting and for saying so.
---
--- The version in fxmanifest.lua, so a released change to the page reaches
--- players the moment they load the updated resource. A manifest with no
--- version still has to bust the cache rather than silently stop doing it,
--- so the resource name stands in and the operator is told.
local buildStamp
function App.build()
    if buildStamp then return buildStamp end

    -- Guarded: this is read while building the registration payload, which
    -- happens inside a pcall that reports any throw as "lb-phone rejected
    -- the app". A native that is absent or behaves differently on some
    -- build would take the whole app off the phone and blame lb-phone for
    -- it. Nothing here is worth that, so a failure falls back to a stamp
    -- that still busts the cache.
    local ok, version = pcall(GetResourceMetadata, GetCurrentResourceName(), 'version', 0)
    if not ok then version = nil end

    if type(version) == 'string' and version ~= '' then
        buildStamp = version
    else
        buildStamp = 'nover'
        print('[crimson-bounty] fxmanifest.lua has no version line. The phone '
            .. 'page cannot then be cache-busted by version, so players may keep '
            .. 'an old copy of the app after an update. Add a version to the '
            .. 'manifest.')
    end
    return buildStamp
end

--- Whether this player's job lets them have the app at all.
---
--- nil until the server has said. Unknown is not "yes": a player who has
--- never been told is not shown the app, because showing it and then taking
--- it away is worse than a second's wait, and because the answer arrives on
--- join before the phone is ever opened.
local accessAllowed = nil

--- Take the app back off the phone.
---
--- A player who takes a barred job mid-session has it installed already, so
--- refusing to register it next time is not enough — it has to go now. The
--- export for this has moved across lb-phone releases, so each name is tried
--- and every one of them is guarded: a build with none of them leaves the
--- icon there, and the server still refuses every request behind it.
local function unregisterApp()
    if not appReady then return end

    for _, name in ipairs({ 'RemoveCustomApp', 'DeleteCustomApp', 'UninstallApp' }) do
        local called, ok = phone(name, function()
            return exports['lb-phone'][name](exports['lb-phone'], 'crimson-bounty')
        end)
        if called and ok ~= false then
            appReady = false
            return
        end
    end

    print('[crimson-bounty] this lb-phone build has no export for removing a '
        .. 'custom app, so the icon stays until the player reconnects. Every '
        .. 'request behind it is still refused.')
end

--- Register the app, once. Returns false while it is still worth retrying.
local function registerApp()
    if appReady then return true end
    -- Barred jobs never get it. The gate refuses their every request anyway,
    -- so the app they were being shown installed, opened, and answered
    -- nothing — which reads as broken rather than as not for them.
    if accessAllowed ~= true then return true end

    local called, ok = phone('AddCustomApp', function()
        return exports['lb-phone']:AddCustomApp({
            identifier  = 'crimson-bounty',
            -- What the player reads on their home screen. The identifier
            -- above is the key everything else is registered under and does
            -- not follow it.
            name        = 'Crimson-Bounty',
            description = 'Contracts, quietly arranged.',
            developer   = 'Crimson',
            defaultApp  = false,
            size        = 4200,
            -- The build stamp is what makes an update reach the player.
            --
            -- CEF caches this page and everything it loads on its own disk,
            -- keyed by URL, and the URL used to be the same string forever.
            -- A player who had opened the app once kept that copy of app.js
            -- through resource restarts, server restarts and updates: every
            -- fix shipped to the page did nothing for them, and neither end
            -- had any way to tell. index.html passes this query on to
            -- app.js and app.css, so bumping the resource version is what
            -- replaces what they are running.
            ui          = GetCurrentResourceName() .. '/ui/index.html?v=' .. App.build(),
            icon        = 'https://cfx-nui-' .. GetCurrentResourceName() .. '/ui/icon.png',
            fixBlur     = true,
            -- The page loads its own data when it opens; firing the same
            -- requests here would duplicate them and drain the rate limit
            -- before the player has typed anything.
            onOpen      = function() end,
        })
    end)

    if not called then return false end
    if not ok then
        print('[crimson-bounty] lb-phone rejected the app')
        return false
    end

    appReady = true
    return true
end

--- Keep trying for a while.
---
--- One attempt a second after lb-phone reports started was a single throw of
--- the dice: lb-phone finishes its own setup on its own schedule, and a call
--- that lands too early is refused. A refusal used to be permanent — the
--- player simply had no app for the rest of the session, with one line in a
--- console nobody reads.
local registering = false

local function attemptRegistration()

    while GetResourceState('lb-phone') ~= 'started' do Wait(500) end
    Wait(1000)

    for attempt = 1, 10 do
        if registerApp() then return end
        print(('[crimson-bounty] app registration attempt %d failed; retrying')
            :format(attempt))
        Wait(2000 * attempt)
    end

    print('[crimson-bounty] lb-phone would not register the app. It will not appear '
        .. 'on the phone until this resource or lb-phone is restarted.')
end

--- The same, with the in-progress flag released whatever happens.
---
--- The flag used to be cleared on each way out of the function above, which
--- meant any throw in between left it set for the rest of the session — and
--- a set flag makes every later attempt return immediately. lb-phone coming
--- back would then never re-register the app, and the player would have no
--- app until they reconnected, with nothing said. A guard whose failure mode
--- is "this feature is now permanently off" has to be the kind that cannot
--- leak.
local function registerWithRetries()
    -- lb-phone restarting twice in quick succession would otherwise leave
    -- two of these looping against each other.
    if registering then return end
    registering = true

    local ok, err = pcall(attemptRegistration)
    registering = false

    if not ok then
        print(('[crimson-bounty] app registration threw: %s'):format(tostring(err)))
    end
end

CreateThread(registerWithRetries)

--- Ask whether this player may have the app.
---
--- The server pushes this on join and on every job change, but a client that
--- started after the join push — a resource restart mid-session, most
--- often — would otherwise wait for an event that has already been and
--- gone, and never get the app at all. Asked until answered, then dropped.
CreateThread(function()
    -- Ten tries and then silence was a player stranded: if the server was
    -- restarting, or they were still mid-join, the app never appeared and
    -- there was nothing they could do about it. Withholding something has
    -- to come with a way to ask again, and asking has to keep being
    -- possible. It backs off to a slow heartbeat rather than stopping.
    local waits = { 2000, 2000, 2000, 5000, 5000, 10000 }
    local i = 0
    while accessAllowed == nil do
        i = i + 1
        TriggerServerEvent('crimson-bounty:whoAmI')
        Wait(waits[i] or 30000)
    end
end)

--- lb-phone restarting drops every custom app it was holding, this one
--- included. Without re-registering, the app is gone until the next server
--- restart and nothing says why.
AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= 'lb-phone' then return end
    appReady = false
    CreateThread(registerWithRetries)
end)

--- Make what is on the phone match what the server last said, whatever it
--- is now and however it got out of step.
---
--- This replaced acting on the transition — register when the answer turns
--- true, remove when it turns false — which read well and was wrong. Every
--- way of missing a transition ended in the same state, and it is the worst
--- one: no app, and nothing that will ever put it back. A missed event, a
--- removal that half worked, lb-phone restarting while the answer was not
--- yet known, our own resource restarting mid-session — each of them
--- stranded a player who had done nothing but keep playing. It happened
--- twice on a live server.
---
--- Comparing the two states instead of watching for the moment between them
--- has no such failure: whatever went wrong, the next pass puts it right,
--- and a pass that has nothing to do costs one comparison.
--- Forget that the app is registered.
---
--- lb-phone restarting drops every custom app it holds, and this is how it
--- says so. Exposed because a test has to be able to produce the state the
--- reconciler exists for: the app gone from the phone with nothing having
--- said it went.
function App.forgetRegistration()
    appReady = false
end

function App.reconcile()
    if accessAllowed == nil then return end

    if accessAllowed and not appReady then
        registerWithRetries()
    elseif not accessAllowed and appReady then
        unregisterApp()
    end
end

--- The server's decision about whether this player may have the app.
---
--- Sent on join, on any job change, on the maintenance tick, and whenever
--- the client asks. The client never decides this for itself: the job
--- blacklist is the server's config and a client that could answer it could
--- grant itself the app.
RegisterNetEvent('crimson-bounty:access', function(allowed)
    accessAllowed = allowed == true
    CreateThread(App.reconcile)
end)

--- And on a slow heartbeat, because an answer that never changes is exactly
--- when a phone that lost the app has nothing coming to fix it.
CreateThread(function()
    while true do
        Wait(15000)
        App.reconcile()
    end
end)

--------------------------------------------------------------------------
-- Server round trips
--------------------------------------------------------------------------

--- Ask the server for something and hand the answer to the UI.
function App.request(event, payload, cb)
    requestSeq = requestSeq + 1
    local id = requestSeq

    -- Coerced, not merely defaulted. `payload or {}` covers nil and nothing
    -- else, and the line below indexes it: every one of the generic NUI
    -- callbacks hands whatever the page posted straight through, so a body
    -- that is a number, a boolean or a string threw here — before
    -- TriggerServerEvent, so nothing was pending, the 15s timeout had no
    -- request to rescue, and the page's promise never settled. The shipped
    -- page always posts an object, but an NUI endpoint is addressable by
    -- resource name from any frame the phone draws.
    if type(payload) ~= 'table' then payload = {} end
    payload.__rid = id

    if cb then
        pending[id] = cb
        -- Never leak a callback: if the server never answers, drop it.
        SetTimeout(15000, function()
            if pending[id] then
                pending[id] = nil
                cb({ ok = false, err = 'timeout', event = event })
            end
        end)
    end

    TriggerServerEvent('crimson-bounty:' .. event, payload)
end

RegisterNetEvent('crimson-bounty:result', function(result)
    -- Type-checked like the notify and push handlers beside it. Net event
    -- names are a server-wide namespace: this resource's server always
    -- sends a table, and any other resource on the server can send anything
    -- at all. Indexing it raw threw out of the handler, which also skipped
    -- the SendCustomAppMessage below — so the open app was told nothing
    -- either, and the waiting request was freed fifteen seconds later with
    -- 'timeout' on a call the server had actually answered.
    if type(result) ~= 'table' then return end

    local cb = result.rid and pending[result.rid]
    if cb then
        pending[result.rid] = nil
        cb(result)
    end

    -- Everything also goes to the UI, which decides what to render.
    phone('SendCustomAppMessage', function()
        exports['lb-phone']:SendCustomAppMessage('crimson-bounty', {
            type = 'result', event = result.event, ok = result.ok,
            err = result.err, data = result.data,
        })
    end)
end)

--- An unsolicited nudge for an open app: something the player is looking at
--- changed. Forwarded as a message rather than a notification, because the
--- app refreshes on this and the phone should not buzz for it.
RegisterNetEvent('crimson-bounty:push', function(data)
    phone('SendCustomAppMessage', function()
        exports['lb-phone']:SendCustomAppMessage('crimson-bounty', {
            type = 'push',
            reason = type(data) == 'table' and tostring(data.reason or '') or '',
        })
    end)
end)

--- Phone notifications. lb-phone's SendNotification is client-side only, so
--- the server addresses the player and the client raises it locally.
RegisterNetEvent('crimson-bounty:notify', function(data)
    if type(data) ~= 'table' then return end
    phone('SendNotification', function()
        exports['lb-phone']:SendNotification({
            app = 'crimson-bounty',
            title = tostring(data.title or 'Crimson-Bounty'),
            content = tostring(data.content or ''),
        })
    end)
end)

--------------------------------------------------------------------------
-- NUI callbacks — the UI's only route to the server
--------------------------------------------------------------------------

local UI_EVENTS = {
    'list', 'mine', 'ledger', 'searchTargets', 'browseTargets',
    'rewardOptions', 'mugshotImage',
    'create', 'accept', 'abandon', 'cancel', 'revise',
    'requestPhotoToken', 'armKidnap', 'kidnapProgress',
    'bailout', 'informant',
    'addEscrow', 'rewardBreakdown', 'withdrawReward',
    'improve', 'propose', 'respondAmendment', 'amendments',
    'threads', 'readThread', 'sendMessage', 'requestCall',
}

for _, event in ipairs(UI_EVENTS) do
    RegisterNUICallback('crimson:' .. event, function(data, cb)
        App.request(event, data, function(result) cb(result) end)
    end)
end

--------------------------------------------------------------------------
-- Death and revive reporting
--------------------------------------------------------------------------
--
-- The client reports only about itself, and the server treats the report as
-- a prompt to check its own records rather than as a fact.

local wasDead = false

CreateThread(function()
    while true do
        Wait(1000)
        local ped = PlayerPedId()
        local dead = IsEntityDead(ped)

        if dead and not wasDead then
            wasDead = true

            -- The victim reports who killed them, read from their own game.
            -- A killer's claim about their own kill is exactly what an
            -- attacker forges; a victim has no reason to hand credit to
            -- their killer, and the server corroborates it either way.
            local killer = GetPedSourceOfDeath(ped)
            local killerServerId
            if killer and killer ~= 0 and killer ~= ped and IsPedAPlayer(killer) then
                local killerPlayer = NetworkGetPlayerIndexFromPed(killer)
                if killerPlayer and killerPlayer ~= -1 then
                    killerServerId = GetPlayerServerId(killerPlayer)
                end
            end

            TriggerServerEvent('crimson-bounty:iDied', killerServerId)
        elseif not dead and wasDead then
            wasDead = false
            TriggerServerEvent('crimson-bounty:iRevived')
        end
    end
end)

--------------------------------------------------------------------------
-- Verification photo (§7.4)
--------------------------------------------------------------------------
--
-- The camera flow is started by the script for one specific contract. The
-- URL it produces is submitted with the server-issued token, so an image
-- alone can never claim a payout.

RegisterNUICallback('crimson:takeVerificationPhoto', function(data, rawCb)
    -- Answered exactly once, whatever happens after.
    --
    -- Three paths can reach this callback — the camera cancelling, the
    -- submission returning, and the camera failing to open — and lb-phone
    -- has been seen to invoke a camera callback more than once. Resolving an
    -- NUI callback twice throws inside the browser the phone is drawn in,
    -- which does not look like a bug in this resource: it looks like the
    -- phone crashing, in the middle of an upload, for no stated reason.
    local answered = false
    local function cb(payload)
        if answered then return end
        answered = true
        pcall(rawCb, payload)
    end

    local contractId = data and data.id
    if not contractId then return cb({ ok = false, err = 'invalid_input' }) end

    App.request('requestPhotoToken', { id = contractId }, function(result)
        if not result.ok or not result.data or not result.data.token then
            return cb({ ok = false, err = result.err or 'no_token' })
        end

        local token = result.data.token

        -- The UI is waiting on cb. A build without SetCameraComponent
        -- would throw out of here and never call it, leaving the player
        -- looking at a button that does nothing forever.
        local opened = phone('SetCameraComponent', function()
            exports['lb-phone']:SetCameraComponent({
                default = { type = 'Photo', flash = false, camera = 'rear' },
                permissions = {
                    toggleFlash = true, flipCamera = true, takePhoto = true,
                    takeVideo = false, takeLandscapePhoto = false,
                },
                -- Saving the shot to the player's own gallery is a second
                -- upload of a photograph of a body, done inside the same
                -- operation, and it is the step this crashes in on some
                -- builds. It is also evidence of a crime sitting in the
                -- hunter's phone. Off unless an operator asks for it.
                saveToGallery = Config.Completion.SavePhotoToGallery == true,
                cb = function(src)
                    -- The override is ours and we are done with it. Left
                    -- installed, every later use of the phone's own camera
                    -- runs through a component this resource configured for
                    -- one photograph of a body — including its callback,
                    -- which by then belongs to a request that has finished.
                    phone('SetCameraComponent reset', function()
                        return exports['lb-phone']:SetCameraComponent(nil)
                    end)

                    -- Guarded: this runs inside lb-phone's camera, so a
                    -- throw here does not stay here — it goes back into the
                    -- camera and takes the phone with it.
                    local ok, err = pcall(function()
                        if not src then return cb({ ok = false, err = 'cancelled' }) end
                        App.request('submitPhoto', { token = token, url = src }, function(submitResult)
                            cb({ ok = submitResult.ok, err = submitResult.err,
                                 data = submitResult.data })
                        end)
                    end)
                    if not ok then
                        print(('[crimson-bounty] the camera callback threw: %s')
                            :format(tostring(err)))
                        cb({ ok = false, err = 'photo_rejected' })
                    end
                end,
            })
        end)

        if not opened then return cb({ ok = false, err = 'camera_unavailable' }) end

        -- A camera that opens and never calls back leaves the page waiting on
        -- a request that has no timeout of its own: the server round trip has
        -- one, the player composing a shot does not. Generous, because they
        -- are lining up a photograph, but not forever.
        SetTimeout((Config.Completion.PhotoTokenLifetimeSeconds or 120) * 1000, function()
            cb({ ok = false, err = 'cancelled' })
        end)
    end)
end)

return App
