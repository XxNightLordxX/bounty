--- Client bootstrap: registers the app with lb-phone and bridges the UI.
---
--- The client holds no authority. It renders what the server sends, asks for
--- what the player clicks, and reports only two facts about itself: that this
--- player died, and that this player was revived.

local App = {}

local pending = {}   -- [event] = callback awaiting a server reply
local appReady = false

--------------------------------------------------------------------------
-- lb-phone registration
--------------------------------------------------------------------------

local function registerApp()
    if appReady then return end

    local ok, err = exports['lb-phone']:AddCustomApp({
        identifier  = 'crimson-bounty',
        name        = 'Crimson',
        description = 'Contracts, quietly arranged.',
        developer   = 'Crimson',
        defaultApp  = false,
        size        = 4200,
        ui          = GetCurrentResourceName() .. '/ui/index.html',
        icon        = 'https://cfx-nui-' .. GetCurrentResourceName() .. '/ui/icon.png',
        fixBlur     = true,
        onOpen      = function() App.refresh() end,
    })

    if not ok then
        print(('[crimson-bounty] lb-phone rejected the app: %s'):format(tostring(err)))
        return
    end

    appReady = true
end

CreateThread(function()
    while GetResourceState('lb-phone') ~= 'started' do Wait(500) end
    Wait(1000)
    registerApp()
end)

--------------------------------------------------------------------------
-- Server round trips
--------------------------------------------------------------------------

--- Ask the server for something and hand the answer to the UI.
function App.request(event, payload, cb)
    pending[event] = pending[event] or {}
    if cb then table.insert(pending[event], cb) end
    TriggerServerEvent('crimson-bounty:' .. event, payload or {})
end

RegisterNetEvent('crimson-bounty:result', function(result)
    local waiting = pending[result.event]
    if waiting then
        pending[result.event] = nil
        for i = 1, #waiting do waiting[i](result) end
    end

    -- Everything also goes to the UI, which decides what to render.
    exports['lb-phone']:SendCustomAppMessage('crimson-bounty', {
        type = 'result', event = result.event, ok = result.ok,
        err = result.err, data = result.data,
    })
end)

function App.refresh()
    App.request('list', { page = 1 })
    App.request('mine', {})
end

--- Phone notifications. lb-phone's SendNotification is client-side only, so
--- the server addresses the player and the client raises it locally.
RegisterNetEvent('crimson-bounty:notify', function(data)
    if type(data) ~= 'table' then return end
    exports['lb-phone']:SendNotification({
        app = 'crimson-bounty',
        title = tostring(data.title or 'Crimson'),
        content = tostring(data.content or ''),
    })
end)

--------------------------------------------------------------------------
-- NUI callbacks — the UI's only route to the server
--------------------------------------------------------------------------

local UI_EVENTS = {
    'list', 'mine', 'ledger', 'searchTargets', 'rewardOptions',
    'create', 'accept', 'abandon',
    'requestPhotoToken', 'armKidnap', 'kidnapProgress',
    'bailout', 'informant',
    'addEscrow', 'propose', 'respondAmendment',
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
            TriggerServerEvent('crimson-bounty:iDied')
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
end)

return App
