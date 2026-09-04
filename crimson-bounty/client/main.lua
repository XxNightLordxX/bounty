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

--- Register the app, once. Returns false while it is still worth retrying.
local function registerApp()
    if appReady then return true end

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
            ui          = GetCurrentResourceName() .. '/ui/index.html',
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

local function registerWithRetries()
    -- lb-phone restarting twice in quick succession would otherwise leave
    -- two of these looping against each other.
    if registering then return end
    registering = true

    while GetResourceState('lb-phone') ~= 'started' do Wait(500) end
    Wait(1000)

    for attempt = 1, 10 do
        if registerApp() then
            registering = false
            return
        end
        print(('[crimson-bounty] app registration attempt %d failed; retrying')
            :format(attempt))
        Wait(2000 * attempt)
    end

    registering = false
    print('[crimson-bounty] lb-phone would not register the app. It will not appear '
        .. 'on the phone until this resource or lb-phone is restarted.')
end

CreateThread(registerWithRetries)

--- lb-phone restarting drops every custom app it was holding, this one
--- included. Without re-registering, the app is gone until the next server
--- restart and nothing says why.
AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= 'lb-phone' then return end
    appReady = false
    CreateThread(registerWithRetries)
end)

--------------------------------------------------------------------------
-- Server round trips
--------------------------------------------------------------------------

--- Ask the server for something and hand the answer to the UI.
function App.request(event, payload, cb)
    requestSeq = requestSeq + 1
    local id = requestSeq

    payload = payload or {}
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

function App.refresh()
    App.request('list', { page = 1 })
    App.request('mine', {})
end

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
    'create', 'accept', 'abandon',
    'requestPhotoToken', 'armKidnap', 'kidnapProgress',
    'bailout', 'informant',
    'addEscrow', 'improve', 'propose', 'respondAmendment', 'amendments',
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

RegisterNUICallback('crimson:takeVerificationPhoto', function(data, cb)
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
                saveToGallery = true,
                cb = function(src)
                    if not src then return cb({ ok = false, err = 'cancelled' }) end
                    App.request('submitPhoto', { token = token, url = src }, function(submitResult)
                        cb({ ok = submitResult.ok, err = submitResult.err, data = submitResult.data })
                    end)
                end,
            })
        end)

        if not opened then cb({ ok = false, err = 'camera_unavailable' }) end
    end)
end)

return App
