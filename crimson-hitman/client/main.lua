--- Client bootstrap: registers the app with lb-phone and bridges the UI.
---
--- The client holds no authority. It renders what the server sends, asks for
--- what the player clicks, and reports only three facts about itself: that
--- this player died, that this player was revived, and, while the nearby
--- list is on, whether this player wears a mask.

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
    print(('[crimson-hitman] lb-phone %s failed on this build: %s')
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
        print('[crimson-hitman] fxmanifest.lua has no version line. The phone '
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
            return exports['lb-phone'][name](exports['lb-phone'], 'crimson-hitman')
        end)
        if called and ok ~= false then
            appReady = false
            return
        end
    end

    print('[crimson-hitman] this lb-phone build has no export for removing a '
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
            identifier  = 'crimson-hitman',
            -- What the player reads on their home screen. The identifier
            -- above is the key everything else is registered under and does
            -- not follow it.
            name        = 'Crimson-Hitman',
            description = 'Contracts, quietly arranged.',
            developer   = 'Crimson',
            -- In the App Store for players to find, unless the owner puts
            -- it on every eligible phone (Config.App.DefaultInstalled). Read
            -- here, from this player's own copy of the config: the server
            -- fills a section an older config lacks only on its own side,
            -- so a missing one reads as the shipped false.
            defaultApp  = Config.App ~= nil and Config.App.DefaultInstalled == true,
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
            -- Stamped like the page and its stylesheet. This was the one
            -- asset loaded without it, so CEF kept the first icon it ever
            -- saw: an icon change shipped with a resource update reached
            -- nobody who had opened the app before, with no way to tell
            -- from either end — the same fault the page itself had, left
            -- behind when that one was fixed.
            icon        = 'https://cfx-nui-' .. GetCurrentResourceName()
                          .. '/ui/icon.png?v=' .. App.build(),
            fixBlur     = true,
            -- The page loads its own data when it opens; firing the same
            -- requests here would duplicate them and drain the rate limit
            -- before the player has typed anything.
            onOpen      = function() end,
            -- The kill photo viewfinder runs lb-phone's game camera behind
            -- the app. A phone put away with the viewfinder still up would
            -- otherwise leave it running.
            onClose     = function() App.walkableCam(false) end,
        })
    end)

    if not called then return false end
    if not ok then
        print('[crimson-hitman] lb-phone rejected the app')
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
        print(('[crimson-hitman] app registration attempt %d failed; retrying')
            :format(attempt))
        Wait(2000 * attempt)
    end

    print('[crimson-hitman] lb-phone would not register the app. It will not appear '
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
        print(('[crimson-hitman] app registration threw: %s'):format(tostring(err)))
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
        TriggerServerEvent('crimson-hitman:whoAmI')
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
RegisterNetEvent('crimson-hitman:access', function(allowed)
    accessAllowed = allowed == true
    CreateThread(App.reconcile)
end)

--- Settings staff changed from the admin panel that this game reads too,
--- and the type each must have. This game's copy of the config is
--- config.lua as every player downloads it; the server's, with the panel's
--- changes in it, is the one in force, and it says so when one of these
--- changes and when this player joins. Only these keys, and only values of
--- these types, are taken.
local CLIENT_SETTINGS = {
    -- Whether to say when this player's mask goes on or comes off.
    ['Targeting.AllowNearby'] = 'boolean',
    -- Whether a headshot this game renders has its background cut out.
    ['Mugshot.RemoveBackground'] = 'boolean',
    -- Whether the app goes on the home screen when it is next added.
    ['App.DefaultInstalled'] = 'boolean',
}

RegisterNetEvent('crimson-hitman:settings', function(values)
    if type(values) ~= 'table' then return end
    for key, kind in pairs(CLIENT_SETTINGS) do
        local value = values[key]
        if type(value) == kind then
            local section, name = key:match('^([%w_]+)%.([%w_]+)$')
            if type(Config[section]) ~= 'table' then Config[section] = {} end
            Config[section][name] = value
        end
    end
    -- The nearby list turned on: start saying when the mask changes.
    if App.watchMask then App.watchMask() end
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

--- How fast a kill photo goes to the server, in bytes a second, on
--- 'server' storage. A latent event is sent in pieces at this rate rather
--- than as one burst; FiveM's default of 25000 is half a minute for a large
--- photo with the hitman standing over the body. The server acknowledges
--- the pieces no faster than about 75 a second, so in practice a photo at
--- the default size takes about four seconds and the largest allowed about
--- ten; asking for more than that is what lets the first pieces go at
--- once.
local PHOTO_BPS = 500000

--- Ask the server for something and hand the answer to the UI.
---
--- `opts.latent` sends it as a latent event, for a payload too big to go
--- as an ordinary one (a kill photo), and `opts.timeoutMs` waits longer
--- than the usual fifteen seconds for the answer, since a latent event
--- takes as long as it takes to arrive.
---@param opts table|nil { latent = boolean, timeoutMs = integer }
function App.request(event, payload, cb, opts)
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
        SetTimeout(opts and opts.timeoutMs or 15000, function()
            if pending[id] then
                pending[id] = nil
                cb({ ok = false, err = 'timeout', event = event })
            end
        end)
    end

    if opts and opts.latent then
        TriggerLatentServerEvent('crimson-hitman:' .. event, PHOTO_BPS, payload)
    else
        TriggerServerEvent('crimson-hitman:' .. event, payload)
    end
end

--- The kill photo this player has open, if any: { handle, url }.
---
--- Learnt from the server's own answers, so the Save to Photos fallback
--- below saves the link the server handed this player for the photo they
--- are looking at and nothing else: the image host's link from openPhoto,
--- or, for a photo kept on the server, the link it serves the photo under
--- from photoDecision's 'link'. An NUI endpoint is addressable from any
--- frame the phone draws, and one that saved whatever link it was given
--- would put anything at all into the player's gallery.
local shownPhoto

local function notePhoto(result)
    local data = type(result.data) == 'table' and result.data or nil
    if result.event == 'openPhoto' and result.ok and data
        and type(data.handle) == 'string' and type(data.url) == 'string' then
        shownPhoto = { handle = data.handle, url = data.url }
    elseif result.event == 'photoDecision' and result.ok and data
        and type(data.handle) == 'string' and type(data.link) == 'string' then
        shownPhoto = { handle = data.handle, url = data.link }
    elseif result.event == 'photoDecision' and result.ok then
        shownPhoto = nil
    end
end

RegisterNetEvent('crimson-hitman:result', function(result)
    -- Type-checked like the notify and push handlers beside it. Net event
    -- names are a server-wide namespace: this resource's server always
    -- sends a table, and any other resource on the server can send anything
    -- at all. Indexing it raw threw out of the handler, and the waiting
    -- request was freed fifteen seconds later with 'timeout' on a call the
    -- server had actually answered.
    if type(result) ~= 'table' then return end

    notePhoto(result)

    local cb = result.rid and pending[result.rid]
    if cb then
        pending[result.rid] = nil
        cb(result)
    end

    -- Nothing goes to the page from here. Every reply it uses reaches it
    -- once, as the answer to the fetch that asked for it, and it acts on
    -- pushes alone (ui/app.js, the message listener). Each reply used to be
    -- mirrored to it as well, as a 'result' message it threw away: an
    -- export into lb-phone and an NUI message per reply, eighteen on every
    -- open of the app and one a second through a handover's countdown. The
    -- photo token never went that way and still does not: it is what lets
    -- a picture claim a payout, and it stays in this file
    -- (sendVerificationPhoto).
end)

--- An unsolicited nudge for an open app: something the player is looking at
--- changed. Forwarded as a message rather than a notification, because the
--- app refreshes on this and the phone should not buzz for it.
---
--- With the contracts it is about, when it names them, so the page re-reads
--- only those. Without, the page re-reads everything.
RegisterNetEvent('crimson-hitman:push', function(data)
    local ids
    if type(data) == 'table' and type(data.ids) == 'table' then
        ids = {}
        for i = 1, #data.ids do
            if type(data.ids[i]) == 'string' then ids[#ids + 1] = data.ids[i] end
        end
        if #ids == 0 then ids = nil end
    end
    phone('SendCustomAppMessage', function()
        exports['lb-phone']:SendCustomAppMessage('crimson-hitman', {
            type = 'push',
            reason = type(data) == 'table' and tostring(data.reason or '') or '',
            ids = ids,
        })
    end)
end)

--- Ask this player's open app what it has seen.
---
--- The other half of the fault reporting. A page reports what it catches on
--- its own, but a staff member looking into "the app is broken for me" needs
--- what the page has seen up to now — the requests it made, what came back,
--- and anything it swallowed — and there was no way to ask for it.
---
--- Nothing is read here and nothing is sent from here: the request goes to
--- the page, and the page answers through the ordinary pageError endpoint,
--- which is gated, throttled and rate-limited like everything else. A player
--- with the app closed simply does not answer, which is correct — there is
--- no page to ask.
RegisterNetEvent('crimson-hitman:askDiagnostics', function()
    phone('SendCustomAppMessage', function()
        exports['lb-phone']:SendCustomAppMessage('crimson-hitman', {
            type = 'diagnostics',
        })
    end)
end)

--- Phone notifications, where the server could not save one on this
--- player's phone through lb-phone's server export (Notify's raise: lb-phone
--- not started, no number for them, an export that said no). Raised here as
--- a popup, which lb-phone does not keep in the phone's list.
RegisterNetEvent('crimson-hitman:notify', function(data)
    if type(data) ~= 'table' then return end
    phone('SendNotification', function()
        exports['lb-phone']:SendNotification({
            app = 'crimson-hitman',
            title = tostring(data.title or 'Crimson-Hitman'),
            content = tostring(data.content or ''),
        })
    end)
end)

--------------------------------------------------------------------------
-- NUI callbacks — the UI's only route to the server
--------------------------------------------------------------------------

--- Not requestPhotoToken, and not submitPhoto. The token is what lets a
--- picture claim a payout, and this file asks for it itself, from inside
--- takeVerificationPhoto, and keeps it (heldTokens). On this list the page,
--- or any frame that addresses this resource, was answered with a live
--- token, and asking for one put a new one in place of the token held for
--- an open viewfinder.
local UI_EVENTS = {
    'list', 'mine', 'ledger', 'searchTargets', 'browseTargets',
    'rewardOptions', 'mugshotImage',
    'create', 'accept', 'abandon', 'cancel', 'revise',
    'armKidnap', 'kidnapProgress',
    'bailout', 'informant',
    'addEscrow', 'rewardBreakdown', 'withdrawReward',
    'improve', 'propose', 'respondAmendment', 'amendments',
    'threads', 'readThread', 'sendMessage', 'requestCall', 'endCall', 'muteThread',
    -- The client's one look at a kill photo, and what they did with it.
    'openPhoto', 'photoDecision',
    -- The page telling the server it broke. Through the same gate as
    -- everything else: it is an NUI endpoint like any other and is
    -- addressable from any frame the phone draws.
    'pageError',
}

--------------------------------------------------------------------------
-- A kill photo kept on the server, on its way to the client's page
--------------------------------------------------------------------------
--
-- The server sends it as a latent event of its own, not in the reply to
-- openPhoto (App's openPhoto handler), and the page's request is held here
-- until it arrives. Either can come first: the reply is an ordinary event
-- and the photo a slower latent one, but nothing promises the order.

--- How long the page's request waits for the photo once the server has
--- said it is on its way. A few hundred kilobytes at the rate FXServer
--- actually manages is about four seconds; this is for a connection far
--- slower than that. The server sends one photo at a time and counts the
--- same minute (App's photoSending).
local PHOTO_WAIT_MS = 60000

--- [handle] = the page's callback, waiting for that photo.
local photoWaiting = {}
--- A photo that came before the reply that names it: { handle, src }.
local photoArrived

--- The page's answer once the photo is here: the picture, with what the
--- server said about saving it (`link`: it can serve it to the phone's
--- Photos; `kept`: it is kept in the app and opens again).
local function arrivedFor(handle, src, said)
    return { ok = true, event = 'openPhoto', data = {
        handle = handle, src = src,
        link = said.link == true or nil, kept = said.kept == true or nil,
    } }
end

local function awaitPhoto(handle, rawCb, said)
    local function cb(result)
        if result.ok then result = arrivedFor(handle, result.data.src, said) end
        return rawCb(result)
    end
    if photoArrived and photoArrived.handle == handle then
        local src = photoArrived.src
        photoArrived = nil
        return cb({ ok = true, event = 'openPhoto', data = { handle = handle, src = src } })
    end
    photoWaiting[handle] = cb
    SetTimeout(PHOTO_WAIT_MS, function()
        if photoWaiting[handle] ~= cb then return end
        photoWaiting[handle] = nil
        -- Its own code: the one look was spent on a photo that never got
        -- here, and the page says so rather than "no answer, try again".
        --
        -- With whether the server said it is kept in the app. Opening one
        -- of those spends nothing and it opens again, and without this the
        -- page could not tell the two apart: it reported a kept photo as
        -- deleted, and the server deleted it, file and all, because one
        -- delivery was slow.
        cb({ ok = false, event = 'openPhoto', err = 'photo_no_answer',
             data = { handle = handle, kept = said.kept == true or nil } })
    end)
end

RegisterNetEvent('crimson-hitman:photoImage', function(data)
    -- Type-checked like every handler here: net event names are a
    -- server-wide namespace. Only a picture, as a data URI, is passed on.
    if type(data) ~= 'table' or type(data.handle) ~= 'string' or type(data.src) ~= 'string'
        or not data.src:find('^data:image/') then
        return
    end
    -- Here, so the server may send the next one: it sends one at a time,
    -- and otherwise waits out the minute this file waits for it.
    TriggerServerEvent('crimson-hitman:photoArrived', data.handle)
    local cb = photoWaiting[data.handle]
    if cb then
        photoWaiting[data.handle] = nil
        return cb({ ok = true, event = 'openPhoto', data = { handle = data.handle, src = data.src } })
    end
    -- Ahead of the reply. Only the latest is kept, and only until the wait
    -- for it would have run out.
    local arrived = { handle = data.handle, src = data.src }
    photoArrived = arrived
    SetTimeout(PHOTO_WAIT_MS, function()
        if photoArrived == arrived then photoArrived = nil end
    end)
end)

for _, event in ipairs(UI_EVENTS) do
    RegisterNUICallback('crimson:' .. event, function(data, cb)
        App.request(event, data, function(result)
            if event == 'openPhoto' and result.ok and type(result.data) == 'table'
                and result.data.latent and type(result.data.handle) == 'string' then
                return awaitPhoto(result.data.handle, cb, result.data)
            end
            cb(result)
        end)
    end)
end

--- Save the kill photo the player has open to their phone's Photos.
---
--- The page saves it itself where lb-phone gives custom apps
--- components.saveToGallery; this is for a build that does not, through
--- lb-phone's client export. Only the link the server handed this player
--- for the photo they have open (notePhoto): the page sends a handle,
--- never a link.
RegisterNUICallback('crimson:saveToPhotos', function(data, cb)
    local handle = type(data) == 'table' and data.handle or nil
    if not shownPhoto or type(handle) ~= 'string' or handle ~= shownPhoto.handle then
        return cb({ ok = false, err = 'photo_gone' })
    end
    local url = shownPhoto.url
    local saved = phone('SaveToGallery', function()
        exports['lb-phone']:SaveToGallery(url)
    end)
    cb({ ok = saved, err = (not saved) and 'save_unavailable' or nil })
end)

--------------------------------------------------------------------------
-- Death and revive reporting
--------------------------------------------------------------------------
--
-- The client reports only about itself, and the server treats the report as
-- a prompt to check its own records rather than as a fact.

--- The medical resource's view, read without trusting it to exist. The
--- metadata is what sc-ambulance, qbx_medical and qb-ambulancejob all write
--- (isdead, inlaststand); the state bags are read too, under the names each
--- of them uses. The third answer is whether any of it could be read at all.
---
--- The metadata comes from QBX.PlayerData, which qbx_core's own
--- modules/playerdata.lua (loaded by the manifest) keeps current from the
--- QBCore:Player:SetPlayerData event qbx_core sends with every change, and
--- empties on unload. GetPlayerData carried the whole record across the
--- export boundary once a second, on every client, for the whole session.
local function medical()
    local ok, state = pcall(function() return LocalPlayer.state end)
    local data = type(QBX) == 'table' and QBX.PlayerData or nil
    local meta = type(data) == 'table' and type(data.metadata) == 'table' and data.metadata or nil
    state = ok and state or nil
    -- qbx_medical's isDead bag is true in last stand as well, so it means
    -- down, not dead; its deathState is 2 in last stand and 3 when dead.
    -- Read as dead, it spent the one death report on the downing.
    local deathState = state and tonumber(state['qbx_medical:deathState']) or nil
    local dead = (state and (state.dead == true or deathState == 3))
        or (meta and meta.isdead == true)
    local lastStand = (state and (state.isDead == true or state.inLastStand == true
            or state.laststand == true or deathState == 2))
        or (meta and meta.inlaststand == true)
    return dead == true, lastStand == true, meta ~= nil
end

--- The medical resources this build knows, for an operator config that
--- replaced the Completion section without naming them.
local DEFAULT_PROVIDERS = { { resource = 'sc-ambulance' }, { resource = 'qbx_medical' } }

--- Whether a medical resource decides when this player is dead: one of the
--- configured death-state providers is running.
local function medicalRunning()
    local providers = Config and Config.Completion and Config.Completion.DeathStateProviders
    if type(providers) ~= 'table' or #providers == 0 then providers = DEFAULT_PROVIDERS end
    for _, provider in ipairs(providers) do
        if type(provider) == 'table' and provider.resource
            and GetResourceState(provider.resource) == 'started' then
            return true
        end
    end
    return false
end

-- Two questions, kept apart. Dead: reported as a death, once. Down (dead or
-- in last stand): what a revive ends.
--
-- Under a medical resource, both are its word, not the engine's. sc-ambulance
-- and its kind let the engine kill the ped when a player is downed, then
-- resurrect it into last stand and, when they bleed out or are finished,
-- resurrect it again as dead. Reporting on the engine spent the one death
-- report on the downing, which the server refuses (last stand is not dead),
-- and the real death that followed was never reported, so the kill that
-- finished them was never credited. Without a medical resource, or when its
-- state cannot be read, the engine is all there is.
local reportedDead, wasDown, wasEngineDead = false, false, false

--- Who the engine says killed this ped, as a server id, or nil for nobody
--- who is a player: the world, an NPC, or themselves.
local function killerOf(ped)
    local killer = GetPedSourceOfDeath(ped)
    if killer and killer ~= 0 and killer ~= ped and IsPedAPlayer(killer) then
        local killerPlayer = NetworkGetPlayerIndexFromPed(killer)
        if killerPlayer and killerPlayer ~= -1 then
            return GetPlayerServerId(killerPlayer)
        end
    end
    return nil
end

-- The wrap-safe clock shared/util.lua publishes; the manifest loads it first.
local function nowMs() return CrimsonUtil.monotonicMs() end

-- The engine's last death on this ped, and who it named, taken when the
-- watcher saw it. A medical resource declares the death after resurrecting
-- the ped, when its source of death no longer says anything reliable, so
-- the name is taken from the engine death just before, if there was one.
-- Only a fresh one: a kill older than that is the downing, not the death,
-- and naming the player who downed them handed the kill to them when
-- somebody else finished it. A finish the watcher did not see (the ped
-- resurrected inside one tick) names nobody, and the server takes the kill
-- from its own damage log, which holds the finishing hit.
local KILLER_FRESH_MS = 3000
local engineDeathAt, engineKiller

-- Who the game said killed this player, the moment it did: the damage event
-- sc-ambulance itself moves a player from last stand to dead on. A body in a
-- car or on a stretcher is raised in the same frame it dies, so a watcher
-- looking once a second never saw the engine death and named nobody; the
-- server then had no word from the victim to credit the finishing shot with.
-- A bleed-out raises no such event, and so names nobody.
local lethalBy, lethalByAt

-- Where the event carries "the victim died". Builds 2060 and 2189 each put a
-- value in ahead of it, so on the build Qbox enforces it is the sixth, and
-- the fourth is always 0: read there, no death was ever seen.
local LETHAL_FLAG = (function()
    local build = type(GetGameBuildNumber) == 'function' and GetGameBuildNumber() or 0
    return (build >= 2189 and 6) or (build >= 2060 and 5) or 4
end)()

AddEventHandler('gameEventTriggered', function(name, data)
    if name ~= 'CEventNetworkEntityDamage' or type(data) ~= 'table' then return end
    local ped = PlayerPedId()
    if data[1] ~= ped then return end
    local died = data[LETHAL_FLAG]
    if died ~= 1 and died ~= true then return end
    lethalBy, lethalByAt = nil, nowMs()
    local attacker = data[2]
    if attacker and attacker ~= 0 and attacker ~= ped and IsPedAPlayer(attacker) then
        local index = NetworkGetPlayerIndexFromPed(attacker)
        if index and index ~= -1 then lethalBy = GetPlayerServerId(index) end
    end
end)

-- How many ticks in a row a player has to be up before it counts as a
-- revive. A defibrillator takes them from dead to last stand, and
-- sc-ambulance clears isdead a second or more before it writes inlaststand:
-- read at once, that gap was a revive, and a revive gives the target five
-- minutes' immunity while they are still on the ground.
local UP_CONFIRM_TICKS = 4
local upFor = 0

-- Dead once more after a defibrillator. The shock takes a player from dead
-- to last stand, not to their feet, and the one death report stayed spent
-- until they stood up: finished again on the ground, their second death was
-- never reported and the hitman who finished them was never credited. Not
-- dead for as long as a revive has to be up re-arms the report; whether a
-- revive is reported still waits on standing up, after any death at all.
local notDeadFor = 0
local diedSinceUp = false

-- A new character starts with a watcher that has seen nothing. /relog keeps
-- this resource running, so the last character's death carried over: the
-- next one, alive, was "up after a death" and reported a revive the server
-- had no death for, which goes to the staff webhook as a probe.
local function forgetDeath()
    reportedDead, wasDown, diedSinceUp = false, false, false
    upFor, notDeadFor = 0, 0
    engineDeathAt, engineKiller = nil, nil
    lethalBy, lethalByAt = nil, nil
end

--- Whether a character is loaded. qbx_core sets the bag on load and clears
--- it on unload; between the two (17mov's character selection) its own
--- player data still holds the last character, dead or alive.
local function loggedIn()
    local ok, state = pcall(function() return LocalPlayer.state end)
    return ok and state and state.isLoggedIn and true or false
end

CreateThread(function()
    while true do
        Wait(1000)
        -- Nobody to watch while no character is loaded. Read then, the last
        -- character's isdead was reported as a death nobody had, and the
        -- next character standing up as a revive without one, which the
        -- server posts to the staff webhook as a probe.
        if not loggedIn() then
            forgetDeath()
            goto continue
        end
        local ped = PlayerPedId()
        local medDead, lastStand, readable = medical()
        local engineDead = IsEntityDead(ped)
        -- Its word counts only when it can be read. A medical resource that
        -- is running but whose state never reaches this client would
        -- otherwise mean no death is ever reported.
        local managed = readable and medicalRunning()

        local dead, down
        if managed then
            dead = medDead
            -- The engine's death at the downing is followed by a resurrect,
            -- and only then by last stand: a tick between the two read the
            -- player as up again and reported a revive that never happened.
            down = medDead or lastStand
        else
            -- And its word is kept while it restarts. The metadata stays;
            -- falling back to the engine for those ticks read a dead player
            -- as revived, then reported the same death a second time.
            dead = engineDead or (readable and medDead)
            down = dead or engineDead or (readable and lastStand)
        end

        if engineDead and not wasEngineDead then
            engineDeathAt, engineKiller = nowMs(), killerOf(ped)
        end
        wasEngineDead = engineDead

        if dead then
            notDeadFor = 0
        elseif reportedDead then
            notDeadFor = notDeadFor + 1
            -- Down but not dead after a reported death is last stand, and
            -- only a defibrillator takes a player there from dead: finished
            -- seconds after the shock, the new death went unreported and the
            -- hitman who finished them was never credited. A bare blink of
            -- the death flag, with no last stand in it, still waits.
            if down or notDeadFor >= UP_CONFIRM_TICKS then reportedDead = false end
        end

        if dead and not reportedDead then
            reportedDead = true
            diedSinceUp = true

            -- The victim reports who killed them, read from their own game.
            -- A killer's claim about their own kill is exactly what an
            -- attacker forges; a victim has no reason to hand credit to
            -- their killer, and the server corroborates it either way,
            -- against a damage log with a window of its own.
            local killer
            if lethalByAt and nowMs() - lethalByAt <= KILLER_FRESH_MS then
                killer = lethalBy
            elseif engineDead then
                killer = killerOf(ped)
            elseif engineDeathAt and nowMs() - engineDeathAt <= KILLER_FRESH_MS then
                killer = engineKiller
            end
            TriggerServerEvent('crimson-hitman:iDied', killer)
        end
        if down then
            upFor = 0
            wasDown = true
        elseif wasDown then
            upFor = upFor + 1
            if upFor >= UP_CONFIRM_TICKS then
                -- Only after a death this client reported. Somebody picked
                -- up from last stand never died, and the server takes a
                -- revive from a player it never saw dead as a probe, and
                -- posts it to the staff webhook as one.
                if diedSinceUp then TriggerServerEvent('crimson-hitman:iRevived') end
                reportedDead, diedSinceUp = false, false
                engineDeathAt, engineKiller = nil, nil
                wasDown, upFor = false, 0
            end
        end
        ::continue::
    end
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', forgetDeath)
RegisterNetEvent('qbx_core:client:playerLoggedOut', forgetDeath)

--------------------------------------------------------------------------
-- Mask reporting, for the nearby list
--------------------------------------------------------------------------
--
-- The nearby list leaves out anyone wearing a mask, and only this player's
-- own game can see what they are wearing: GetPedDrawableVariation is a
-- client native, nil on the server. So the client says, about itself
-- alone, whenever it changes. A modified client can only hide itself from
-- the list or put itself on it, which taking the mask off would do anyway.
-- The server counts a player it has heard nothing from as masked.

--- How often the mask is looked at: one native read, and an event only
--- when the answer changes.
local MASK_CHECK_MS = 1000

--- What the server was last told: true masked, false bare face, nil
--- nothing yet for this character. The server forgets it at logout.
local maskSaid = nil

--- Whether this ped has a mask on: its mask component (1) is not the bare
--- face (0), as on the freemode peds Qbox players use, so an add-on model
--- that draws something there counts as masked. A read that fails does too.
local function wearingMask(ped)
    local ok, drawable = pcall(GetPedDrawableVariation, ped, 1)
    return not ok or drawable ~= 0
end

--- Whether the watcher below is running.
local maskWatching = false

--- Watch this player's mask while the nearby list is on, and stop when it
--- goes off.
local function watchLoop()
    -- Nothing to say while the list is off (Config.Targeting.AllowNearby):
    -- the server never asks.
    local rules = Config and Config.Targeting
    if type(rules) ~= 'table' or not rules.AllowNearby then return end
    maskWatching = true
    while true do
        Wait(MASK_CHECK_MS)
        local now = Config and Config.Targeting
        if type(now) ~= 'table' or not now.AllowNearby then
            -- Turned off: nothing more to say, and everything to say again
            -- from the start if it comes back on.
            maskSaid, maskWatching = nil, false
            return
        end
        if not loggedIn() then
            -- The next character says it again.
            maskSaid = nil
        else
            local masked = wearingMask(PlayerPedId())
            if masked ~= maskSaid then
                maskSaid = masked
                TriggerServerEvent('crimson-hitman:maskState', masked)
            end
        end
    end
end

--- Start watching, unless a watch is running already. Called when staff
--- turn the list on from the admin panel (crimson-hitman:settings): it was
--- decided once, at load, so a list turned on later heard from nobody.
function App.watchMask()
    if maskWatching then return end
    CreateThread(watchLoop)
end

CreateThread(watchLoop)

--------------------------------------------------------------------------
-- Verification photo (§7.4)
--------------------------------------------------------------------------
--
-- The camera flow is started by the script for one specific contract. What
-- it produces is submitted with the server-issued token, so an image alone
-- can never claim a payout.
--
-- Two cameras, by the server's Config.Completion.PhotoStorage, which it
-- names when it issues the token. On 'host' it is lb-phone's own camera,
-- which uploads the photo and hands back a link. On 'server' it is the
-- app's own viewfinder: the page draws lb-phone's game camera into itself,
-- takes the picture and sends it here (sendVerificationPhoto), and this
-- client sends it on with the token. The token never goes to the page.

--- The token for each contract whose viewfinder is open, by contract id:
--- { token, maxBytes }. Held here and not given to the page, which hands
--- over the picture alone. One picture per token: sending takes it.
local heldTokens = {}

--- Whether lb-phone's game camera is running behind the viewfinder.
local walkable = false

--- Turn lb-phone's game camera on behind the app's viewfinder, or off.
---
--- The rear camera, said out loud: a selfie would put the hitman in the
--- photo the client is shown. Through `phone`, as every lb-phone export
--- is: a build without these answers the page rather than leaving it
--- waiting.
---@param on boolean
---@return boolean ok
function App.walkableCam(on)
    on = on == true
    if on == walkable then return true end
    local called = phone(on and 'EnableWalkableCam' or 'DisableWalkableCam', function()
        if on then
            exports['lb-phone']:EnableWalkableCam(false)
        else
            exports['lb-phone']:DisableWalkableCam()
        end
    end)
    if called then walkable = on end
    return called
end

-- A restart with the viewfinder open. lb-phone turns the camera off only
-- when the page asks or through the app's onClose, and that callback dies
-- with this resource, so nothing else would: the phone stayed in camera
-- mode. Nothing else here holds a handle; lb-phone keeps the focus.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    App.walkableCam(false)
end)

RegisterNUICallback('crimson:verificationCamera', function(data, cb)
    local on = type(data) == 'table' and data.on == true
    local ok = App.walkableCam(on)
    cb({ ok = ok, err = (not ok) and 'camera_unavailable' or nil })
end)

--- The picture the page took in its viewfinder, sent on to the server with
--- the token this client holds for that contract.
---
--- As a latent event: a photo is a few hundred kilobytes, which FiveM's
--- documentation says not to send as an ordinary event. Bounded here by
--- the size the server said it keeps, so a page cannot make this client
--- upload a great deal of anything; the server checks it properly.
RegisterNUICallback('crimson:sendVerificationPhoto', function(data, rawCb)
    local answered = false
    local function cb(payload)
        if answered then return end
        answered = true
        pcall(rawCb, payload)
    end

    local contractId = type(data) == 'table' and data.id or nil
    local held = contractId ~= nil and heldTokens[tostring(contractId)] or nil
    if not held then return cb({ ok = false, err = 'no_token' }) end

    local image = data.image
    if type(image) ~= 'string' or not image:find('^data:image/') then
        return cb({ ok = false, err = 'photo_bad_image' })
    end
    if #image > math.ceil((held.maxBytes or 600000) / 3) * 4 + 64 then
        return cb({ ok = false, err = 'photo_too_large' })
    end

    heldTokens[tostring(contractId)] = nil
    App.request('submitPhoto', { token = held.token, image = image }, function(result)
        cb({ ok = result.ok, err = result.err, data = result.data })
    end, { latent = true, timeoutMs = 60000 })
end)

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

    -- Whether the player has actually taken a shot. The no-answer timer is
    -- about a camera that was never used; once there is a photo in flight
    -- the request belongs to the upload, however long that takes.
    local shutterPressed = false

    -- Whether the camera has already handed us its result. lb-phone has
    -- been seen to call back more than once, and this asks it for the
    -- result by two routes (below), so the first one wins.
    local delivered = false

    -- There is no camera "override" to take back off the phone afterwards.
    -- lb-phone's SetCameraComponent(options, cb) opens a one-shot camera
    -- whose callback is dropped once it has been used, and it treats
    -- anything that is not a table as empty options: calling it with nil to
    -- "reset" it opened a SECOND camera with lb-phone's defaults (and the
    -- phone with it, if it was closed), and, with no callback, waited inside
    -- that call until the player dealt with it — before the page was told
    -- anything. Every ending of this request did that, including a refusal
    -- before any camera had been asked for.
    local function cb(payload)
        if answered then return end
        answered = true
        pcall(rawCb, payload)
    end

    -- A body that is not an object is refused rather than indexed: indexing
    -- a number throws, and a throw here leaves the request unanswered.
    local contractId = type(data) == 'table' and data.id or nil
    if not contractId then return cb({ ok = false, err = 'invalid_input' }) end

    App.request('requestPhotoToken', { id = contractId }, function(result)
        if not result.ok or type(result.data) ~= 'table' or not result.data.token then
            return cb({ ok = false, err = result.err or 'no_token' })
        end

        local token = result.data.token

        -- 'server' storage: the page opens its own viewfinder, and sends
        -- the picture back through sendVerificationPhoto, which puts this
        -- token to it. The page is told the size the server keeps and
        -- nothing else.
        if result.data.storage == 'server' then
            local maxBytes = tonumber(result.data.maxBytes)
            heldTokens[tostring(contractId)] = { token = token, maxBytes = maxBytes }
            return cb({ ok = true, data = {
                viewfinder = true,
                maxSide = tonumber(result.data.maxSide),
                maxBytes = maxBytes,
            } })
        end

        --- What the camera produced: a URL, or nothing if the player backed
        --- out.
        ---
        --- Guarded: lb-phone calls this from its own camera, so a throw here
        --- does not stay here — it goes back into the camera and takes the
        --- phone with it.
        local function onShot(src)
            if delivered then return end
            delivered = true

            -- The shutter has been pressed, so the no-answer timer below
            -- must not fire. Without this, a photo taken at 119 seconds is
            -- still uploading when the timer expires at 120: the page is
            -- told the camera never came back, the real answer is dropped as
            -- a second reply, and the hitman is told their kill went unsent
            -- while the server was in the middle of accepting it.
            shutterPressed = true

            -- The page has already been told the camera never came back, and
            -- the token this photo would be sent with has run out with it.
            if answered then return end

            local ok, err = pcall(function()
                if type(src) ~= 'string' or src == '' then
                    return cb({ ok = false, err = 'cancelled' })
                end
                App.request('submitPhoto', { token = token, url = src }, function(submitResult)
                    cb({ ok = submitResult.ok, err = submitResult.err,
                         data = submitResult.data })
                end)
            end)
            if not ok then
                print(('[crimson-hitman] the camera callback threw: %s')
                    :format(tostring(err)))
                cb({ ok = false, err = 'photo_rejected' })
            end
        end

        -- A camera that opens and never calls back leaves the page waiting on
        -- a request that has no timeout of its own: the server round trip has
        -- one, the player composing a shot does not. Generous, because they
        -- are lining up a photograph, but not forever.
        --
        -- Armed BEFORE the camera is asked for. SetCameraComponent is
        -- documented as returning the photo's URL, and a build that returns
        -- it waits inside the call until the camera is done with; a timer
        -- armed after that call is armed only once there is nothing left to
        -- wait for.
        --
        -- Its own code, not 'cancelled'. Cancelling is the player's own
        -- decision and the page is deliberately silent about it — so a
        -- camera that never came back said nothing at all, two minutes after
        -- a tap that had already said nothing. The two are not the same
        -- event and the second one needs words.
        SetTimeout((Config.Completion.PhotoTokenLifetimeSeconds or 120) * 1000, function()
            if shutterPressed then return end
            cb({ ok = false, err = 'camera_no_answer' })
        end)

        -- The UI is waiting on cb. A build without SetCameraComponent
        -- would throw out of here and never call it, leaving the player
        -- looking at a button that does nothing forever.
        --
        -- The callback goes in as the SECOND argument. That is the one
        -- lb-phone reads: SetCameraComponent(options, cb) calls cb(url), and
        -- with no second argument it ignores options.cb entirely, waits for
        -- the shot and returns the URL instead. The photo went nowhere: the
        -- URL was discarded, nothing was submitted, and two minutes later the
        -- hitman was told the camera never came back. options.cb is kept for
        -- a build that reads it there, and a URL handed back as the return
        -- value is used too; `delivered` makes the first of them the only one.
        local opened, returned = phone('SetCameraComponent', function()
            return exports['lb-phone']:SetCameraComponent({
                default = { type = 'Photo', flash = false, camera = 'rear' },
                -- No flip to the selfie camera. The photo goes to the client,
                -- and lb-phone's flip is one key (UP) away from its shutter
                -- (RETURN): flipped, by accident or not, the hitman sends
                -- the client his own face over the body.
                permissions = {
                    toggleFlash = true, flipCamera = false, takePhoto = true,
                    takeVideo = false, takeLandscapePhoto = false,
                },
                -- Never saved to the hitman's own gallery. The photo is
                -- the client's alone, to see once; a copy in the phone
                -- that took it is evidence of a crime the hitman carries
                -- around, and a second upload of a photograph of a body,
                -- done inside the same operation, is the step this crashed
                -- in on some builds. Written out rather than left off,
                -- because lb-phone saves to the gallery unless told not to.
                saveToGallery = false,
                cb = onShot,
            }, onShot)
        end)

        if not opened then return cb({ ok = false, err = 'camera_unavailable' }) end
        if type(returned) == 'string' and returned ~= '' then onShot(returned) end
    end)
end)

return App
