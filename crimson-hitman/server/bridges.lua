--- FiveM event bridges.
---
--- Every engine event this resource listens to is registered here, in one
--- place, through a function the test suite calls too. A producer that is
--- written but never wired is a silent dead path — the elimination payout
--- depended on exactly one of these, and nothing else would have noticed.

local Bridges = {}

--- Observe damage the engine reports, so an elimination can be attributed
--- without trusting either player's account of it (§14.2).
---
--- `sender` is engine-supplied and trustworthy. The entity list inside the
--- payload is not, which is why Death.recordDamage re-checks the distance
--- server-side before recording anything.
---@param modules table
---@param sender number
---@param data table
function Bridges.onWeaponDamage(modules, sender, data)
    if not modules.death or type(data) ~= 'table' then return 0 end
    if (data.weaponDamage or 0) <= 0 then return 0 end

    local hits = data.hitGlobalIds
    if type(hits) ~= 'table' then return 0 end

    local recorded = 0
    for i = 1, #hits do
        local ped = NetworkGetEntityFromNetworkId(hits[i])
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            local victimSrc = NetworkGetEntityOwner(ped)
            -- The player's own ped, and nothing else they own. A player's
            -- client owns their car and the NPCs around them too, and a round
            -- into any of those was queued as a hit on them, to take the
            -- damage of the next real shot that landed.
            if victimSrc and victimSrc > 0 and victimSrc ~= sender
                and ped == GetPlayerPed(victimSrc) then
                modules.death.recordDamage(sender, victimSrc, data.weaponType)
                recorded = recorded + 1
            end
        end
    end
    return recorded
end

--- Deliver anything owed to a player who has just come online (§9.3).
function Bridges.onPlayerReady(modules, src)
    local actor = modules.identity and modules.identity.resolve(src)
    if not actor then return 0 end

    local delivered = modules.escrow.retryPending(actor.cid)
    if delivered > 0 then
        modules.notify.toCitizen(actor.cid, 'Outstanding payment',
            ('%d outstanding item%s been delivered.')
                :format(delivered, delivered == 1 and ' has' or 's have'),
            { bypassBudget = true })
    end
    -- And what happened to their contracts while they were away.
    modules.notify.deliverWaiting(actor.cid)
    return delivered
end

--- Release per-player state when someone disconnects.
---
--- Identity is resolved from a citizen id captured while they were still
--- connected: by the time playerDropped fires, the framework may already
--- have discarded the player, and cleanup that depends on resolving them
--- would silently never run.
function Bridges.onPlayerDropped(modules, cid)
    if not cid then return false end

    -- Someone leaving pauses the clock on every contract they are party to.
    if modules.scheduler then modules.scheduler.presenceChanged() end

    modules.identity.endSession(cid)
    modules.ratelimit.clear(cid)
    modules.death.clearPlayer(cid)
    modules.photo.clearPlayer(cid)
    modules.kidnap.clearPlayer(cid)
    modules.notify.clearPlayer(cid)
    modules.comms.clearPlayer(cid)
    modules.mugshot.clearPlayer(cid)
    modules.informant.clearPlayer(cid)
    modules.app.clearPlayerHandles(cid)

    -- Memory mode holds no durable escrow, so a creator disconnecting would
    -- strand it. Refund and close rather than risk losing their property.
    if Config.Database.Mode == 'memory' then
        local contracts = modules.storage.allContracts()
        for i = 1, #contracts do
            local c = contracts[i]
            if c.creator_cid == cid and c.state == CH.STATE.ACTIVE then
                modules.contracts.resolve(c.id, CH.STATE.CANCELLED, cid, nil,
                    'creator_disconnected_memory_mode')
            end
        end
    end

    return true
end

--- Register every bridge against the live runtime.
--- The last answer sent to each source, so the sweep below sends only
--- changes rather than an event per player per tick.
local lastAccess = {}

--- How many sources it is holding an answer for. Bounded by who is
--- connected, not by who has ever connected: this table is written on every
--- tick for the life of the server, so a leak here is one that only grows.
function Bridges.accessMemoSize()
    local n = 0
    for _ in pairs(lastAccess) do n = n + 1 end
    return n
end

function Bridges.install(modules)
    -- Per-contract caches in modules that contracts.lua cannot see are
    -- released through this hook when a contract resolves.
    modules.contracts.onResolved = function(contractId)
        modules.informant.clearContract(contractId)
        modules.comms.clearContract(contractId)
        modules.death.clearProximity(contractId)
        -- Kidnap was missing from this list. An armed handover on a contract
        -- that then cancelled, expired, or was completed by somebody else
        -- stayed in memory for the life of the process: it holds one of
        -- Config.Kidnap.MaxConcurrentCountdowns and keeps the tick thread
        -- running. Fill the cap that way and live delivery stops working for
        -- everybody on the server, refused as limit_reached, until a
        -- restart.
        modules.kidnap.clearContract(contractId)
    end

    --- A hitman who is no longer on a contract has no handover on it either.
    ---
    --- Through a hook rather than a direct call, like onResolved above:
    --- contracts.lua does not know about the kidnap module and should not
    --- start to. Kidnap.cancel existed for this and had no caller.
    modules.contracts.onHitmanLeft = function(contractId, hitmanCid, reason)
        modules.kidnap.cancel(contractId, hitmanCid, reason)
        -- And the proof of a kill made during the stint that just ended. A
        -- hitman may now take the contract up again, and a kill or a photo
        -- token from before they walked away is not something the new stint
        -- earned.
        modules.death.clearPending(contractId, hitmanCid)
        modules.photo.forget(contractId, hitmanCid)
        -- And the handles that stood for their thread on it.
        if modules.comms and modules.comms.clearHitman then
            modules.comms.clearHitman(contractId, hitmanCid)
        end
    end

    -- The expiry pass skips itself when nothing could have changed since the
    -- last one. Creating or ending a contract can move the earliest
    -- deadline, so it is told.
    modules.contracts.onChanged = modules.scheduler and modules.scheduler.contractsChanged or nil

    -- Citizen ids are remembered while players are connected, so disconnect
    -- cleanup does not depend on the framework still knowing them.
    local connected = {}
    -- And the other way round, [cid] = src, for the death sampler, which
    -- needs the server id of every live contract's parties once a second
    -- and used to ask qbx_core for each one's whole record to read it.
    -- Written only through connect(), so the two never disagree.
    local sourceByCid = {}

    ---@param src number
    ---@param cid string|nil nil when the character at src has gone
    local function connect(src, cid)
        local was = connected[src]
        if was and sourceByCid[was] == src then sourceByCid[was] = nil end
        connected[src] = cid
        if cid then sourceByCid[cid] = src end
    end

    -- Filled at every login, emptied at every logout and disconnect, and
    -- checked against everyone online on every maintenance tick
    -- (refreshAccess). Death.sourceOf asks qbx_core about anybody it does
    -- not hold, so a login it has not heard of yet is still watched.
    if modules.death then
        modules.death.sourceOf = function(cid) return sourceByCid[cid] end
    end

    --- Sources with a readiness pass already on the way.
    ---
    --- The pass is what delivers escrow owed to somebody who was offline
    --- when it was released, so it has to happen on login and must not
    --- happen a thousand times. Two things schedule it: this server may have
    --- both framework shims present and fire both loaded events for one
    --- login, and — the reason it is latched rather than merely
    --- de-duplicated — QBCore:Server:OnPlayerLoaded is a RegisterNetEvent,
    --- so any client on the server can fire it as often as it likes.
    ---
    --- Measured before this existed: 200 firings from one source queued 200
    --- server timers and 200 reads of the pending-payout table, five seconds
    --- later, with nothing to stop the next 200.
    local readying = {}

    local function scheduleReady(src)
        if not src or readying[src] then return false end
        readying[src] = true
        SetTimeout(Config.PendingEscrow.LoginRetryDelayMs or 5000, function()
            readying[src] = nil
            -- Owed money is not delivered while boot recovery is still
            -- deciding what is owed (App.ready): asked again shortly.
            if modules.app and modules.app.ready == false then
                return scheduleReady(src)
            end
            Bridges.onPlayerReady(modules, src)
        end)
        return true
    end

    AddEventHandler('weaponDamageEvent', function(sender, data)
        -- A hit another resource has cancelled (an anti-cheat, as a rule) is
        -- never passed on to the victim's game, so it can land nothing.
        -- Queued anyway, it took an honest hit's drop between two attackers,
        -- or a fall's alone. Only handlers that ran before this one are seen.
        if WasEventCanceled and WasEventCanceled() then return end
        Bridges.onWeaponDamage(modules, sender, data)
    end)

    -- sc-ambulance's defibrillator, heard as it is sent to sc-ambulance: the
    -- moment it leaves between dead and last stand is no revive, whatever
    -- lands in it. Death.noteDefib asks what sc-ambulance asks — an on-duty
    -- medic of Config.Completion.MedicJobs, holding the DefibItem, within
    -- DefibRange of a patient who is dead — so a medic firing it proves
    -- nothing they could not do with the real device. What it cannot read
    -- is whether sc-ambulance's defibrillator is switched on at all: with
    -- it off, set MedicJobs = {} so none is heard.
    --
    -- Any client can fire it, so it answers to the same flood guard as every
    -- other net event this resource hears; each one costs two framework
    -- lookups before the job check can refuse a non-medic.
    RegisterNetEvent('sc-ambulance:server:UseDefib', function(targetId)
        local src = source
        if not modules.app.floodOk(src, 'useDefib') then return end
        if not modules.death or not modules.death.noteDefib then return end
        pcall(modules.death.noteDefib, src, targetId)
    end)

    -- A medical resource starting again may be a version with the death-state
    -- exports the one before did not have (Identity.deathState stops asking
    -- one that has none). A local event: the engine raises it, no client can.
    --
    -- lb-phone starting again may have a config edit behind it, or exports
    -- it did not have: whether it hides a caller's number, and how a call is
    -- placed, are asked of it afresh rather than kept from before. Kept,
    -- an answer read while it was stopped refused every anonymous call, or
    -- hid the Call button, until this resource restarted.
    AddEventHandler('onResourceStart', function(name)
        if modules.identity and modules.identity.forgetProvider then
            modules.identity.forgetProvider(name)
        end
        if name == 'lb-phone' and modules.comms then
            if modules.comms.resetMaskingCache then modules.comms.resetMaskingCache() end
            if modules.comms.resetCallCache then modules.comms.resetCallCache() end
        end
    end)

    -- A sentence starting or ending moves a contract's clock as a player
    -- arriving or leaving does. qbx_core announces every metadata write on
    -- the server; a local event, so no client can raise it.
    --
    -- Going in and coming out only. sc-police writes the sentence down a
    -- month at a time, every thirty seconds, for every inmate, and a full
    -- pass on each write was the table read the expiry skip exists to save.
    AddEventHandler('qbx_core:server:onSetMetaData', function(key, old, new)
        if key ~= 'injail' or not modules.scheduler then return end
        local was = (tonumber(old) or 0) > 0
        local now = (tonumber(new) or 0) > 0
        if was ~= now then modules.scheduler.presenceChanged() end
    end)

    ---@param untrusted boolean|nil true for the event any client can fire
    local function remember(src, untrusted)
        local actor = modules.identity.resolve(src)
        if actor then
            connect(src, actor.cid)
            -- Someone arriving can unpause a contract's clock.
            if modules.scheduler then modules.scheduler.presenceChanged() end
            -- A session we watched begin, so its length is known exactly.
            -- Identity.resolve may already have noted them as observed a
            -- moment ago; that becomes the real thing. Never restarted:
            -- one of the two events that lands here is a net event any
            -- client can fire, and restarting the clock on it made the
            -- sender "just arrived" — immune to every claim — on demand.
            modules.identity.confirmSession(actor.cid, untrusted)
        end
        return actor
    end

    -- A net event, not a local one, because some builds relay it from the
    -- client. That also means any client can fire it, so it answers to the
    -- same flood guard as this resource's own events — every one of which
    -- has one, and this did not.
    RegisterNetEvent('QBCore:Server:OnPlayerLoaded', function()
        local src = source
        if not modules.app.floodOk(src, 'playerLoaded') then return end
        remember(src, true)
        scheduleReady(src)
    end)

    local function loaded(player)
        -- Type-checked, not merely truth-checked. `player and
        -- player.PlayerData` throws for a number or a boolean, and again one
        -- level down for a PlayerData that is not a table — and an event
        -- name is a server-wide namespace, so this resource is not the only
        -- thing that can put something on it. The same rule the client's own
        -- handlers answer to.
        if type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then return end
        local src = player.PlayerData.source
        -- A character that has just loaded has said nothing about its mask:
        -- qbx_core announces it before the client is marked logged in, and
        -- the client says it once it is. Anything kept was said for the
        -- one before.
        if modules.app and modules.app.forgetMask then modules.app.forgetMask(src) end
        remember(src)
        Bridges.tellAccess(src)
        scheduleReady(src)
    end

    -- The trusted login: a local event, so no client can raise it. qbx_core
    -- announces a character it has loaded as QBCore:Server:PlayerLoaded,
    -- with the player object, at the end of CreatePlayer. This listened
    -- only for qbx_core:server:playerLoaded, which qbx_core has never
    -- fired, so on a stock server no session was ever watched beginning:
    -- the new-player session floor never applied, and a contract could be
    -- placed and paid on somebody seconds after they walked in. Kept under
    -- the other name too, for a build that fires it; remember() never
    -- restarts a session, so hearing one login twice changes nothing.
    AddEventHandler('QBCore:Server:PlayerLoaded', loaded)
    AddEventHandler('qbx_core:server:playerLoaded', loaded)

    -- Whether this player may have the app at all.
    --
    -- The gate already refuses every request from a barred job, but a player
    -- whose job is barred was still shown the app: it installed, opened, and
    -- answered nothing, which reads as broken rather than as not-for-them.
    -- An officer looking at a contract board they cannot use is also a design
    -- problem, not only a cosmetic one.
    --
    -- The decision is the server's, because the client cannot be trusted
    -- with it and because the job blacklist lives in the server's config.
    --- The app going away because of a job the player holds but is not
    --- working. They may not have taken it themselves (a department boss
    --- can hire anybody through the MDT), so they are told which job it is
    --- and how to get the app back, once, when it goes.
    local function explainHeld(actor, was)
        if was == false then return end
        local job, held = modules.identity.barredBy(actor)
        if not job or not held then return end
        modules.notify.toCitizen(actor.cid, 'Crimson-Hitman',
            ('Closed to you while you hold the %s job. Quit it from your job '
            .. 'menu to use it again.'):format(job), { bypassBudget = true })
    end

    local function tellAccess(src)
        if not src or src <= 0 then return end
        local actor = modules.identity.resolve(src)
        -- Unresolvable is not "allowed": a player mid-join gets told nothing
        -- and asks again, rather than being handed the app on a job nobody
        -- has read yet.
        if not actor then return end
        -- Known from here on, whichever way they arrived (see refreshAccess).
        connect(src, actor.cid)

        local allowed = Config.HideAppFromBlockedJobs == false
            or not modules.identity.isBarred(actor)
        if not allowed then explainHeld(actor, lastAccess[src]) end
        lastAccess[src] = allowed
        TriggerClientEvent('crimson-hitman:access', src, allowed)
    end

    Bridges.tellAccess = tellAccess

    --- Re-check everyone, and tell only those whose answer changed.
    ---
    --- The job-change event is not enough on its own. Its name has differed
    --- across framework versions, and a name that is wrong fails silently in
    --- the worst possible direction: a player who takes a barred job keeps
    --- the app, and — far worse — one who LEAVES that job never gets it back
    --- and has no way to ask. Taking something away on an event you cannot
    --- verify, and only restoring it on that same event, is how a fix
    --- becomes the bug.
    ---
    --- So the answer is recomputed on the ordinary maintenance tick, which
    --- depends on no framework event at all. It costs one job read per
    --- player and sends nothing unless the answer has moved.
    function Bridges.refreshAccess()
        local seen = {}
        local players = GetPlayers() or {}

        for i = 1, #players do
            local src = tonumber(players[i])
            if src then
                seen[src] = true
                local ok, actor = pcall(modules.identity.resolve, src)
                if ok and actor then
                    -- Everyone online is remembered here too, not only on
                    -- the load events. After a restart of this resource
                    -- nobody fires those until they relog, and a player
                    -- the framework had already let go of when their
                    -- playerDropped arrived was never cleaned up and never
                    -- paused a clock: the deadline ran on while they were
                    -- away and the contract expired the moment they came
                    -- back, their hitman's stake with it.
                    connect(src, actor.cid)
                    local allowed = Config.HideAppFromBlockedJobs == false
                        or not modules.identity.isBarred(actor)
                    if lastAccess[src] ~= allowed then
                        if not allowed then explainHeld(actor, lastAccess[src]) end
                        lastAccess[src] = allowed
                        TriggerClientEvent('crimson-hitman:access', src, allowed)
                    end
                end
            end
        end

        -- A source is reused by the next player to take that slot, so a
        -- remembered answer for somebody who has gone would be applied to a
        -- stranger.
        for src in pairs(lastAccess) do
            if not seen[src] then lastAccess[src] = nil end
        end
    end

    -- Asked for by the client when it starts, so a client that loaded after
    -- the push above is not left waiting for an event that has been and
    -- gone. Rate-limited by the flood guard like anything else a client can
    -- send.
    RegisterNetEvent('crimson-hitman:whoAmI', function()
        local src = source
        if not modules.app.floodOk(src, 'whoami') then return end
        tellAccess(src)
    end)

    -- A player who takes a barred job loses the app, and one who leaves it
    -- gets it back, without waiting for a reconnect. qbx_core fires
    -- QBCore:Server:OnJobUpdate (source, job) whenever a job is set; the
    -- other name is one it has never fired, kept for a build that does.
    -- The maintenance tick (refreshAccess) catches whatever both miss.
    local function jobChanged(src)
        local id = tonumber(src)
        if id then tellAccess(id) end
    end
    AddEventHandler('QBCore:Server:OnJobUpdate', jobChanged)
    AddEventHandler('qbx_core:server:onSetJob', jobChanged)

    -- A player's own client is the only one that can reliably render their
    -- headshot, so the image arrives from them and is bounded on arrival.
    RegisterNetEvent('crimson-hitman:mugshot', function(image)
        local src = source
        if not modules.app.floodOk(src, 'mugshot') then return end
        local actor = modules.identity.resolve(src)
        if not actor then return end
        if not modules.ratelimit.check(actor, 'mugshot') then return end
        modules.mugshot.store(actor.cid, image)
    end)

    RegisterNetEvent('crimson-hitman:appearanceChanged', function()
        local src = source
        if not modules.app.floodOk(src, 'appearanceChanged') then return end
        local actor = modules.identity.resolve(src)
        if not actor then return end
        if not modules.ratelimit.check(actor, 'mugshot') then return end
        modules.mugshot.invalidate(actor.cid)
    end)

    AddEventHandler('playerDropped', function()
        local src = source
        local cid = connected[src]
        if not cid then
            local actor = modules.identity.resolve(src)
            cid = actor and actor.cid
        end
        connect(src, nil)
        readying[src] = nil
        -- A photo on its way to them is not any more, whoever gets this
        -- server id next.
        if modules.app.forgetSource then modules.app.forgetSource(src) end
        -- Somebody left, whoever they were: the expiry pass looks again.
        -- Without a citizen id onPlayerDropped stops before saying so, and
        -- the pass waited up to MaxDeadlineSkipSeconds to notice the clock
        -- should have stopped.
        if not cid and modules.scheduler then modules.scheduler.presenceChanged() end
        Bridges.onPlayerDropped(modules, cid)
    end)

    -- A character switch. The player stays connected and keeps their source,
    -- but the character this resource has been dealing with is gone — on
    -- this server that runs through the selector's /relog, which calls the
    -- framework's Logout.
    --
    -- Without this, everything keyed on the old citizen id is orphaned:
    -- their session start never ends, their rate-limit buckets and damage
    -- records stay, and an armed handover keeps its slot in the global
    -- countdown budget until the grace timer happens to expire it. It is
    -- the same cleanup as a disconnect, because from here it is the same
    -- event — that character has left.
    --
    -- qbx_core's Logout fires OnPlayerUnload, waits 200 ms with the player
    -- still registered, and only then unregisters them and fires
    -- playerLoggedOut. Anything that looks them up inside that window (the
    -- death sampler does, once a second, for every live target) starts
    -- their session again as observed, and an observed session that old has
    -- no length on their next login, so the login-camping floor did not
    -- apply to them. So the citizen id is kept from the first event and the
    -- cleanup runs again on the second, once nothing can find them.
    local loggingOut = {}   -- [src] = cid, from OnPlayerUnload to playerLoggedOut

    ---@param loggedOut boolean|nil true for qbx_core:server:playerLoggedOut
    local function unload(src, loggedOut)
        src = tonumber(src)
        if not src then return end

        local cid
        if loggedOut then cid = loggingOut[src] or connected[src]
        else cid = connected[src] end
        if not cid then
            local actor = modules.identity.resolve(src)
            cid = actor and actor.cid
        end
        connect(src, nil)
        if loggedOut then loggingOut[src] = nil else loggingOut[src] = cid end
        -- What their client said about their mask was said for the
        -- character that has gone; the next one says it again.
        if modules.app and modules.app.forgetMask then modules.app.forgetMask(src) end
        if cid then Bridges.onPlayerDropped(modules, cid) end
    end

    -- Both spellings: qbx_core emits the QBCore-compatible one first and
    -- its own after the window above. The handler is idempotent, so being
    -- called twice for one switch costs nothing.
    AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
        unload(src or source)
    end)
    AddEventHandler('qbx_core:server:playerLoggedOut', function(src)
        unload(src or source, true)
    end)

    -- Kill photos kept on this server and saved to a client's Photos
    -- through a link this server serves (Photos.publish). lb-phone raises
    -- these itself, with TriggerEvent: the player, their phone number and,
    -- for a deletion, the link. Plain handlers, never RegisterNetEvent, so
    -- a client cannot raise them here: the player and the link come from the
    -- phone resource, not from somebody who wants a photo gone. Each lets go
    -- of the file and its link, for the photo's own client only.
    AddEventHandler('lb-phone:deletedFromGallery', function(phoneSource, _, link)
        if not modules.photos then return end
        local actor = modules.identity.resolve(phoneSource)
        if actor then modules.photos.galleryDeleted(actor, link) end
    end)
    AddEventHandler('lb-phone:factoryReset', function(phoneSource, phoneNumber)
        if not modules.photos then return end
        local actor = modules.identity.resolve(phoneSource)
        if actor then modules.photos.phoneReset(actor, phoneNumber) end
    end)

    -- The links themselves: GET /<this resource>/p/<name>.<ext>, read-only
    -- (Photos.serveHttp). One handler a resource, and this resource answers
    -- nothing else over HTTP. A throw is answered as not found rather than
    -- left hanging.
    if type(SetHttpHandler) == 'function' and modules.photos then
        SetHttpHandler(function(req, res)
            local ok = pcall(modules.photos.serveHttp, req, res)
            if not ok then
                pcall(function()
                    res.writeHead(404, { ['Content-Type'] = 'text/plain; charset=utf-8' })
                    res.send('Not found.')
                end)
            end
        end)
    end

    -- Players already connected as this resource starts: a `restart` or an
    -- `ensure` after a config edit, with the server full. The login events
    -- that schedule the readiness pass came and went before this resource
    -- was listening, and the framework does not fire them again, so
    -- whatever was queued for them — goods that did not fit, a refund to
    -- full pockets — waited until they relogged, however much room they
    -- made. The same pass a login runs, after recovery like any other
    -- (scheduleReady waits for App.ready). Not remember(): nobody watched
    -- these sessions begin.
    --
    -- And into the map the death sampler reads, now rather than at the first
    -- maintenance tick: a target already in the city is watched from the
    -- sampler's first pass without it having to ask qbx_core who they are.
    for _, id in ipairs(GetPlayers() or {}) do
        local src = tonumber(id)
        if src then
            scheduleReady(src)
            local ok, actor = pcall(modules.identity.resolve, src)
            if ok and actor then connect(src, actor.cid) end
        end
    end

    Bridges.installCommands(modules)
    return true
end

--------------------------------------------------------------------------
-- Staff commands
--------------------------------------------------------------------------

--- Print to whoever ran the command — the console when there is no player.
local function reply(src, line)
    if src == 0 then
        print(line)
    else
        TriggerClientEvent('chat:addMessage', src, { args = { 'CRIMSON', line } })
    end
end

--- An escrow line in words, for a staff command.
---
--- Decided by the line's SOURCE, not by whether it happens to carry an
--- amount. The MySQL schema declares `amount INT DEFAULT 0`, so an item or
--- weapon line reads back with an amount of 0 rather than nothing — and 0 is
--- truthy in Lua, so every piece of escrowed property was reported to staff
--- as "$0". In the recovery tool that is the one place it must not happen:
--- somebody settling an interrupted release needs to know what the property
--- was to hand it back.
---@param line table
---@return string
local function describeLine(line)
    if CH.MONEY_SOURCES[line.source] then
        return ('$%s%s'):format(tostring(line.amount or 0),
            line.source ~= 'cash' and (' ' .. tostring(line.source)) or '')
    end

    local what = tostring(line.item or line.source or 'something')
    local many = tonumber(line.quantity) or 0
    return many > 1 and (what .. ' x' .. many) or what
end

Bridges.describeLine = describeLine

--- Register the staff commands. Kept here with the other engine bindings so
--- there is one place that knows what this resource attaches to the runtime.
function Bridges.installCommands(modules)
    if not Config.Admin.Enabled then return false end

    local Admin = modules.admin
    local names = Config.Admin.Commands

    --- Wrap a command in its permission check. A caller without the ACE is
    --- told the same thing whether or not the contract exists, so the
    --- command cannot be used to probe for ids.
    ---@param strict boolean|nil only the named ACE: Config.Admin.ExtraAces
    --- opens the read-only commands, never one that moves money or unmasks
    --- an anonymous party.
    local function command(name, ace, fn, strict)
        RegisterCommand(name, function(src, args)
            if not Admin.allowed(src, ace, strict) then
                reply(src, Admin.howToAuthorise(ace))
                return
            end
            fn(src, args or {})
        end, false)
    end

    --- Why the app is not showing something.
    ---
    --- Reads only, and reads the same things the app reads, as the person
    --- running it. Three separate causes have produced the same symptom on
    --- a live server and none of them left anything behind to look at, so
    --- this asks the server rather than guessing.
    command(names.diagnose, Config.Admin.Ace, function(src, args)
        -- The optional player id is what makes this runnable from the server
        -- console, which is the one place that never refuses an owner.
        -- With somewhere to say what comes back later: whether the public
        -- photo address reaches this resource is asked over the network.
        local lines = Admin.diagnose(src, args[1], function(line) reply(src, line) end)
        for i = 1, #lines do reply(src, lines[i]) end
    end)

    command(names.timeline, Config.Admin.Ace, function(src, args)
        local view, err = Admin.timeline(args[1])
        if not view then return reply(src, 'No such contract (' .. tostring(err) .. ').') end

        local c = view.contract
        reply(src, ('%s  %s  %s -> %s'):format(c.id, c.state, c.creator, c.target))
        reply(src, ('slots %d/%d  created %s%s'):format(
            c.claimed or 0, c.slots or 1, os.date('%Y-%m-%d %H:%M', c.created_at),
            c.resolved_at and ('  resolved ' .. os.date('%Y-%m-%d %H:%M', c.resolved_at)
                .. ' (' .. tostring(c.resolution) .. ')') or ''))

        for i = 1, #view.escrow do
            local line = view.escrow[i]
            reply(src, ('  escrow %s  %s %s  %s  slot %s  %s'):format(
                line.id, line.portion, line.source, describeLine(line),
                tostring(line.slot), line.state))
        end

        for i = 1, #view.events do
            local row = view.events[i]
            reply(src, ('  %s  %-10s %s'):format(
                os.date('%H:%M:%S', row.ts), row.kind, row.action))
        end
    end)

    -- Where the id every other command takes comes from. Read-only, so the
    -- same gate as the timeline; who is behind an anonymous part is
    -- Admin.contractsOf's to withhold.
    if names.contracts then
        command(names.contracts, Config.Admin.Ace, function(src, args)
            if not args[1] then
                return reply(src, ('Usage: /%s <player id|citizen id>'):format(names.contracts))
            end
            local rows, err = Admin.contractsOf(src, args[1])
            if not rows then
                return reply(src, err == CH.ERR.NOT_FOUND
                    and 'Nobody with that player id is online. Give their citizen id instead.'
                    or  'Give a player id or a citizen id.')
            end
            if #rows == 0 then return reply(src, 'No contracts on record for them.') end

            for i = 1, #rows do
                local row = rows[i]
                reply(src, ('%s  %-10s %-6s%s  on %s  %s%s'):format(
                    row.id, row.state, row.role, row.anonymous and ' (anon)' or '',
                    tostring(row.target or '?'),
                    row.created_at and os.date('%Y-%m-%d %H:%M', row.created_at) or '',
                    row.resolution and ('  (resolved: ' .. tostring(row.resolution) .. ')') or ''))
            end
            reply(src, ('Details: /%s <id>'):format(names.timeline))
        end)
    end

    command(names.void, Config.Admin.Ace, function(src, args)
        local reason = table.concat(args, ' ', math.min(2, #args + 1))
        local ok, err = Admin.void(src, args[1], reason)
        reply(src, ok and 'Contract voided; escrow returned to the creator.'
                       or ('Could not void it: ' .. tostring(err)))
    end, true)

    command(names.stuck, Config.Admin.Ace, function(src)
        local lines = Admin.interrupted(src)
        if #lines == 0 then return reply(src, 'No interrupted releases.') end

        local interrupted, nameless, parked = {}, {}, {}
        for i = 1, #lines do
            local list = (lines[i].orphan and nameless) or (lines[i].raised and parked)
                or interrupted
            list[#list + 1] = lines[i]
        end

        -- Lines left for staff (Escrow.parked): a give that kept raising with
        -- nothing arriving, raised with only part of it or no telling what
        -- arrived, or was under way when the server stopped; one held and
        -- owed that nothing queues or gives until the next start (stalled,
        -- unqueued); and one left `releasing` by a call that raised. Owed to
        -- the player named, and given to nobody until settled here.
        if #parked > 0 then
            reply(src, ('%d escrow line(s) raised an error when they were given, or were stopped '
                .. 'while being given, and wait for you:'):format(#parked))
            for i = 1, #parked do
                local line = parked[i]
                -- What is known: a part that arrived is on the line; why it
                -- was left, and when, while the log still has the row.
                local known = 'why is no longer in the log'
                if line.why == 'interrupted' then
                    known = 'the server stopped while it was being given'
                elseif line.why == 'unknown' then
                    known = 'raised, and what arrived could not be read'
                elseif line.why == 'raised' then
                    known = ('raised %d times with nothing arriving'):format(line.raised)
                elseif line.why == 'stalled' then
                    known = 'giving it stopped part-way, and nothing will try it again'
                elseif line.why == 'unqueued' then
                    known = 'owed and in no retry queue, so nothing will give it'
                elseif line.why == 'stopped' then
                    known = 'a raise stopped it while it was being given'
                elseif line.why == 'releasing' then
                    known = 'left mid-release by a call that raised, and nothing is finishing it'
                end
                if (line.arrived or 0) > 0 then
                    known = ('%s; %s of it arrived'):format(known, tostring(line.arrived))
                end
                reply(src, ('  %s  contract %s  %s %s  owed to %s  %s%s'):format(
                    line.line, line.contract, tostring(line.portion), describeLine(line),
                    tostring(line.intended), known,
                    line.at and ('  (' .. os.date('%Y-%m-%d %H:%M', line.at) .. ')') or ''))
                -- Only one that raised with nothing arriving, or that no
                -- give was under way for, is known to have given nothing.
                -- Any other may have given more than the line says arrived:
                -- a give stopped before the line recorded what of it had,
                -- and pay alone would give that part again.
                if line.why ~= 'raised' and line.why ~= 'unqueued' then
                    reply(src, ('    arrival unknown: check what they received, then pay the rest '
                        .. 'with /%s %s pay <amount>, or delivered'):format(names.settle, line.line))
                end
            end
            reply(src, ('Whether such a give arrived cannot always be told, so check their '
                .. 'inventory or balance first. /%s <line> delivered if it is there (settled, '
                .. 'nothing given); /%s <line> pay if it is not (gives only what has not '
                .. 'arrived), or /%s <line> pay <amount> to give exactly what is missing; '
                .. '/%s <line> return to hand that back to whoever put it up instead')
                :format(names.settle, names.settle, names.settle, names.settle))
        end

        if #interrupted > 0 then
            reply(src, ('%d escrow line(s) were mid-release at a shutdown:'):format(#interrupted))
            for i = 1, #interrupted do
                local line = interrupted[i]
                reply(src, ('  %s  contract %s  %s %s  was paying %s  (%s)'):format(
                    line.line, line.contract, tostring(line.portion), describeLine(line),
                    tostring(line.intended), os.date('%Y-%m-%d %H:%M', line.at)))
            end
            reply(src, ('Settle each with /%s <line> pay|return'):format(names.settle))
        end

        -- Lines of a contract never stored, written before a line said
        -- whose it was (Admin.interrupted).
        if #nameless > 0 then
            reply(src, ('%d escrow line(s) of contracts never stored do not say whose they '
                .. 'are:'):format(#nameless))
            for i = 1, #nameless do
                local line = nameless[i]
                reply(src, ('  %s  contract %s  %s %s'):format(line.line, line.contract,
                    tostring(line.portion), describeLine(line)))
            end
            reply(src, ('Find out who put each up, then /%s <line> return <citizenid>')
                :format(names.settle))
        end
    end)

    -- Not through `command`: this one refuses the extra ACEs. `command`
    -- most admin groups already carry opens every read-only tool here, and
    -- that is right for them — it is not right for the one command that
    -- moves every clock on the server.
    if names.refresh then
        RegisterCommand(names.refresh, function(src, args)
            if not Admin.allowed(src, Config.Admin.Ace, true) then
                return reply(src, Admin.howToAuthorise(Config.Admin.Ace))
            end
            local what = tostring((args or {})[1] or 'timers'):lower()
            if what ~= 'timers' and what ~= 'refresh' then
                return reply(src, ('Usage: /%s timers'):format(names.refresh))
            end
            local lines = Admin.refreshTimers(src)
            for i = 1, #lines do reply(src, lines[i]) end
        end, false)
    end

    command(names.settle, Config.Admin.Ace, function(src, args)
        local ok, err, detail = Admin.settleLine(src, args[1], args[2], args[3])
        if ok and err == 'queued' then
            return reply(src, 'Queued: they are not in the city, so it is delivered at their next login.')
        end
        if ok and err == 'requeued' then
            return reply(src, ('Re-queued after a failed give: giving it raised an error with nothing '
                .. 'arriving, so it goes back on their retry queue and is tried again while they are '
                .. 'in the city and at their next login; three such raises leave it for staff (see /%s).')
                :format(names.stuck))
        end
        if err == 'parked' then
            return reply(src, ('Not settled: giving it raised again, so it is left for staff again; '
                .. 'see /%s.'):format(names.stuck))
        end
        if err == 'already_queued' then
            return reply(src, ('Already queued for %s: it is theirs, given while they are in the city '
                .. 'or at their next login. Nothing to settle.'):format(tostring(detail)))
        end
        if err == 'owes_less' then
            return reply(src, ('Not settled: the line now owes only %s, less than that amount; '
                .. 'check again (/%s).'):format(tostring(detail), names.stuck))
        end
        if err == 'not_left' then
            return reply(src, ('Not settled: it is no longer left for staff, as something settled or '
                .. 'moved it since it was read; see /%s.'):format(names.stuck))
        end
        if err == 'raised' then
            return reply(src, ('Not settled: settling it raised an error (logged as admin_settle_raised, '
                .. 'and in the console). Anything it left mid-give is left for staff; see /%s.')
                :format(names.stuck))
        end
        reply(src, ok and 'Line settled.' or ('Could not settle it: ' .. tostring(err)))
    end, true)

    --- What /cleanse says for each refusal, where the app's words do not
    --- reach because the app is closed to the player running it.
    local CLEANSE_REFUSALS = {
        [CH.ERR.BAILOUT_OFF] = 'this server does not offer buyouts.',
        [CH.ERR.NO_BUYOUT_PRICE] = 'the client did not put a price on closing that one.',
        [CH.ERR.BUYOUT_PENDING] = 'you have already paid; it closes shortly.',
        [CH.ERR.INCAPACITATED] = 'not from the floor. Get up first.',
        [CH.ERR.HANDOVER_IN_PROGRESS] = 'somebody has hold of you.',
        [CH.ERR.INSUFFICIENT] = 'you do not have that much.',
        [CH.ERR.ALREADY_SETTLED] = 'that contract has already closed.',
        [CH.ERR.NOT_FOUND] = 'no contract on you has that id.',
        [CH.ERR.NOT_PARTICIPANT] = 'that contract is not on you.',
        [CH.ERR.INVALID_INPUT] = 'that is not a contract id.',
    }

    -- Buying out a contract on yourself, for players the app is closed to.
    --
    -- Law enforcement and EMS are barred from the app by §2, so an officer
    -- with a contract on them had no way to reach the one mechanic the
    -- target of a contract is supposed to have. Not ACE-gated — anyone may
    -- run it — because it only ever acts on a contract naming the caller,
    -- and every check the app's button passes is applied here too.
    if Config.Bailout.Enabled and Config.Bailout.Command then
        RegisterCommand(Config.Bailout.Command, function(src, args)
            if src == 0 then
                return reply(src, 'This is for a player buying out a contract on themselves.')
            end

            local actor = modules.identity.resolve(src)
            if not actor then return end

            -- Deliberately past the app's job gate: being barred from the
            -- app is the reason this exists.
            --
            -- Two allowances, for two things. Every run of the command reads
            -- the store, so every run spends from `load` — the budget the app
            -- itself reads on — which bounds a player hammering it: a command
            -- does not pass the net-event flood guard the app's requests do.
            -- The one-a-minute `bailout` allowance is for a purchase, and
            -- only a purchase spends it. It used to be spent by the listing,
            -- so running /cleanse, reading the id it printed and doing
            -- exactly what it said was refused as "Slow down."
            local function slowDown(bucket)
                local wait = modules.ratelimit.retryAfter(actor, bucket) or 0
                return reply(src, wait > 0
                    and ('Slow down. Try again in %d second(s).'):format(wait)
                    or 'Slow down.')
            end
            if not modules.ratelimit.check(actor, 'load') then return slowDown('load') end

            local open = modules.bailout.available(actor)
            if #open == 0 then
                return reply(src, 'Nothing is out on you.')
            end

            if not args[1] then
                reply(src, ('%d contract(s) on you can be bought out:'):format(#open))
                for i = 1, #open do
                    reply(src, ('  %s  $%d%s'):format(open[i].id, open[i].amount,
                        open[i].queued and '  (already paid, closing shortly)' or ''))
                end
                return reply(src, ('Buy one out with /%s <id>'):format(Config.Bailout.Command))
            end

            -- Not while boot recovery runs (App.ready), like every app request.
            if modules.app and modules.app.ready == false then
                return reply(src, 'The server is still starting. Try again in a moment.')
            end
            if not modules.ratelimit.check(actor, 'bailout') then return slowDown('bailout') end

            local ok, err = modules.bailout.buy(actor, args[1])
            if not ok then
                -- Nothing was bought, so the purchase allowance goes back,
                -- as the app's own handler does. And in words: the command
                -- printed the raw code, "Could not buy it out: incapacitated".
                modules.ratelimit.refund(actor, 'bailout')
                return reply(src, 'Could not buy it out: '
                    .. (CLEANSE_REFUSALS[err] or tostring(err)))
            end
            reply(src, 'Paid. The contract closes shortly.')
        end, false)
    end

    -- Its own ACE: reading a history and unmasking a person are different
    -- kinds of act, and should not be the same permission.
    command(names.whois, Config.Admin.IdentityAce, function(src, args)
        local who, err = Admin.identify(src, args[1])
        if not who then return reply(src, 'No such contract (' .. tostring(err) .. ').') end

        reply(src, ('creator  %s  %s%s'):format(who.creator.cid, who.creator.name,
            who.creator.anonymous and '  (listed anonymously)' or ''))
        reply(src, ('target   %s  %s'):format(who.target.cid, who.target.name))
        for i = 1, #who.hitmen do
            local h = who.hitmen[i]
            reply(src, ('%-8s %s  %s%s'):format(
                h.alias or 'operative', h.cid, h.name,
                h.anonymous and '  (listed anonymously)' or ''))
        end
    end, true)

    return true
end

return Bridges
