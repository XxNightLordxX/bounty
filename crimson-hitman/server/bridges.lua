--- FiveM event bridges.
---
--- Every engine event this resource listens to is registered here, in one
--- place, through a function the test suite calls too. A producer that is
--- written but never wired is a silent dead path — the elimination payout
--- depended on exactly one of these, and nothing else would have noticed.

local Log = CrimsonBoot.requireShared('log')

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
---
--- The maintenance tick's retry is told of them first (Escrow.noteWaiting),
--- before this pass reads their queue: a pass that raised (a database that
--- stopped answering, a store error mid-claim) used to leave their owed
--- payout for a relog, since only this pass ever put a player who had been
--- offline back on the tick's list (W085). What happened to their contracts
--- is told even then.
function Bridges.onPlayerReady(modules, src)
    local actor = modules.identity and modules.identity.resolve(src)
    if not actor then return 0 end

    if modules.escrow.noteWaiting then modules.escrow.noteWaiting(actor.cid) end
    local ran, delivered = pcall(modules.escrow.retryPending, actor.cid)
    if ran and delivered > 0 then
        modules.notify.toCitizen(actor.cid, 'Outstanding payment',
            ('%d outstanding item%s been delivered.')
                :format(delivered, delivered == 1 and ' has' or 's have'),
            { bypassBudget = true })
    end
    -- And what happened to their contracts while they were away.
    modules.notify.deliverWaiting(actor.cid)
    if not ran then error(delivered, 0) end
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

--- Which screen each source was last given: 'full' (the app), 'whitelisted'
--- (the whitelisted-job view, Config.WhitelistedView) or 'closed' (barred,
--- with the view off). Forgotten with lastAccess.
local lastMode = {}

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
    --- Bumped when a player leaves or switches character (W004): a pass
    --- scheduled before that is not theirs any more, and stops. Each one
    --- waiting for recovery set itself again every few seconds, and a drop
    --- cleared the latch only for the next run to set it again: after a
    --- failed recovery every player who had logged in left a timer behind
    --- that ran for the life of the process.
    local generation = {}   -- [src] = integer

    --- A player who left, or whose character went, during the wait.
    local function forgetReady(src)
        readying[src] = nil
        generation[src] = (generation[src] or 0) + 1
    end

    local function scheduleReady(src)
        if not src or readying[src] then return false end
        readying[src] = true
        local mine = generation[src] or 0
        -- Up to two seconds more at random (Config.PendingEscrow), so a
        -- restart with a full server does not run every player's pass in
        -- the same tick.
        SetTimeout((Config.PendingEscrow.LoginRetryDelayMs or 5000) + math.random(0, 2000), function()
            if (generation[src] or 0) ~= mine then return end
            readying[src] = nil
            -- Owed money is not delivered while boot recovery is still
            -- deciding what is owed (App.ready): asked again shortly. Not
            -- once recovery has failed, which nothing in this process
            -- changes, nor for a player who is no longer there.
            if modules.app and modules.app.ready == false then
                if modules.app.recoveryFailed then return end
                local found, actor = pcall(modules.identity.resolve, src)
                if not (found and actor) then return end
                return scheduleReady(src)
            end
            -- In pcall: a pass that raised is the tick's to finish
            -- (Bridges.onPlayerReady), and a timer that raises says nothing.
            local ok, err = pcall(Bridges.onPlayerReady, modules, src)
            if not ok then
                Log.debug(('the login pass for player %s raised: %s; the maintenance tick tries '
                    .. 'their owed payouts again'):format(tostring(src), tostring(err)))
            end
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
        Bridges.tellSettings(modules, src)
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
    --
    -- With the whitelisted-job view on (Config.WhitelistedView, as shipped)
    -- a barred player keeps the app, and it shows them one read-only screen:
    -- the gate still refuses them everything else.
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

    --- Whether a player may have the app on their phone, and which screen
    --- it shows them. A player the app bars has it, with the one read-only
    --- screen, while the whitelisted-job view is on
    --- (Config.WhitelistedView); HideAppFromBlockedJobs decides only while
    --- it is off.
    ---@return boolean allowed
    ---@return string mode 'full' | 'whitelisted' | 'closed'
    local function accessOf(actor)
        if not modules.identity.isBarred(actor) then return true, 'full' end
        if modules.identity.whitelistedViewOn() then return true, 'whitelisted' end
        return Config.HideAppFromBlockedJobs == false, 'closed'
    end

    --- A job change that moves a player between the app and the
    --- whitelisted-job view, said at once to their open page, which drops
    --- what it holds from the other one and asks again. A push like any
    --- other, so it names no contract and carries nothing; not behind the
    --- push floor or Config.Notifications.PushEnabled, since it is not news
    --- about a contract but which screen is theirs. Only once a screen has
    --- been given: the first answer is the page's own first read. And only
    --- to or from the view: between the whole app and an app closed to them
    --- (the view off) nothing is sent, as before the view existed.
    local function tellMode(src, mode)
        local was = lastMode[src]
        lastMode[src] = mode
        if was ~= nil and was ~= mode and (was == 'whitelisted' or mode == 'whitelisted') then
            TriggerClientEvent('crimson-hitman:push', src, { reason = 'access' })
        end
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

        local allowed, mode = accessOf(actor)
        if not allowed then explainHeld(actor, lastAccess[src]) end
        lastAccess[src] = allowed
        TriggerClientEvent('crimson-hitman:access', src, allowed)
        tellMode(src, mode)
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
                    local allowed, mode = accessOf(actor)
                    if lastAccess[src] ~= allowed then
                        if not allowed then explainHeld(actor, lastAccess[src]) end
                        lastAccess[src] = allowed
                        TriggerClientEvent('crimson-hitman:access', src, allowed)
                    end
                    tellMode(src, mode)
                end
            end
        end

        -- A source is reused by the next player to take that slot, so a
        -- remembered answer for somebody who has gone would be applied to a
        -- stranger.
        for src in pairs(lastAccess) do
            if not seen[src] then lastAccess[src] = nil end
        end
        for src in pairs(lastMode) do
            if not seen[src] then lastMode[src] = nil end
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
        -- And the settings their game reads that staff changed from the
        -- admin panel, which their copy of config.lua does not have.
        Bridges.tellSettings(modules, src)
    end)

    -- A player who takes a barred job loses the app (or, with the
    -- whitelisted-job view on, is moved to its one screen), and one who
    -- leaves it gets the whole app back, without waiting for a reconnect.
    -- qbx_core fires QBCore:Server:OnJobUpdate (source, job) whenever a job
    -- is set, an sc-multijob switch included, since that goes through
    -- qbx_core; the other name is one it has never fired, kept for a build
    -- that does.
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
        -- Headshots switched off (Config.Mugshot.Enabled): refused before
        -- anything about the sender or the picture is looked at.
        if not modules.mugshot.enabled() then return end
        if not modules.app.floodOk(src, 'mugshot') then return end
        local actor = modules.identity.resolve(src)
        if not actor then return end
        if not modules.ratelimit.check(actor, 'mugshot') then return end
        modules.mugshot.store(actor.cid, image)
    end)

    RegisterNetEvent('crimson-hitman:appearanceChanged', function()
        local src = source
        -- Nothing is kept to go stale while headshots are off.
        if not modules.mugshot.enabled() then return end
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
        forgetReady(src)
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
        -- A pass scheduled for the character that went is not the next one's.
        forgetReady(src)
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

    -- The admin panel's requests. The engine's source and nothing else
    -- decides who is asking; Panel.handle checks them against the ACEs on
    -- every request, rate-limits them, checks every field, and answers each
    -- one, refusals included, so the page is never left waiting.
    RegisterNetEvent('crimson-hitman:admin', function(payload)
        local src = source
        if not modules.panel then return end
        local reply = modules.panel.handle(src, payload)
        if reply then modules.panel.send(src, reply) end
    end)

    -- A setting changed from the admin panel takes effect at once where
    -- something holds on to it between uses: who may see the app is sent
    -- to every phone again, and a switch to photos from an image host reads
    -- the host list now rather than at its next refresh.
    if modules.settings then
        modules.settings.onChanged = function(key)
            -- Every open app reads its settings again (the switches the
            -- page draws by, the limits on its forms): one push each, as a
            -- state change sends, under the same floor (Notify.push).
            if modules.notify and modules.notify.push then
                for _, actor in ipairs(modules.identity.online()) do
                    pcall(modules.notify.push, actor.cid, 'settings')
                end
            end
            if key == 'HideAppFromBlockedJobs' or key == 'BlockOffDuty'
                or key == 'WhitelistedView.Enabled' then
                for src in pairs(lastAccess) do lastAccess[src] = nil end
                Bridges.refreshAccess()
            elseif (key == 'Completion.PhotoStorage' or key == 'Completion.KillPhotos')
                and Config.Completion.KillPhotos == true
                and Config.Completion.PhotoStorage == 'host'
                and modules.photo and modules.photo.loadAllowedHosts then
                -- Kill photos turned on, or moved to a host: the list of
                -- hosts is read now, which nothing did while they were off.
                pcall(modules.photo.loadAllowedHosts)
            elseif key == 'Mugshot.Enabled' and Config.Mugshot.Enabled == false and modules.mugshot then
                -- Headshots turned off: none is kept, and every card shows
                -- the placeholder from its next refresh.
                modules.mugshot.clearAll()
            elseif (key == 'Limits.PauseWhileTargetJailed' or key:sub(1, 15) == 'Limits.JailZone')
                and modules.scheduler then
                -- Who counts as in prison changed, as a sentence starting
                -- does: the next tick runs the expiry pass, rather than the
                -- one after the longest skip, by when the deadline of a
                -- target already inside could have gone.
                modules.scheduler.presenceChanged()
            end
        end
    end

    Bridges.installCommands(modules)
    return true
end

--- Send one player the settings their game reads that staff changed from
--- the admin panel (Settings.clientValues), if any were: their copy of the
--- config is config.lua's until it is told otherwise.
---@param modules table
---@param src number
---@return boolean sent
function Bridges.tellSettings(modules, src)
    local values = modules.settings and modules.settings.clientValues()
    if not values or not src or src <= 0 then return false end
    TriggerClientEvent('crimson-hitman:settings', src, values)
    return true
end

--------------------------------------------------------------------------
-- Staff commands
--------------------------------------------------------------------------

-- A command's answer goes to whoever ran it: the server console, printed
-- there whatever Config.Debug says (Log.console), or a player's own F8
-- console, never chat. A player's lines are gathered while the command runs
-- (Bridges.runCommand) and sent when it ends, in order, in as few events as
-- fit under OUTPUT_EVENT_BYTES each, with one notice on their screen saying
-- where to look. A line said after the command ended (the diagnosis's photo
-- address check answers later) goes on its own.

--- The most one output event carries, in bytes of text. FiveM refuses a
--- reliable event much over 16 KB, and a line's envelope adds a little.
local OUTPUT_EVENT_BYTES = 8000
Bridges.OUTPUT_EVENT_BYTES = OUTPUT_EVENT_BYTES

--- The lines a command run by a player has said so far, by the thread it
--- runs on: { src, lines }. Weak, so a thread that ended is not kept.
local Gathering = setmetatable({}, { __mode = 'k' })

--- The notify bridge (server/notify.lua), as Bridges.installCommands was
--- handed it.
local Notify

--- A line as it is shown: FiveM's colour codes (^0 to ^9) taken out, since
--- names, aliases and reasons in it are player-written, and one ending in
--- ^1 would colour everything printed after it. Until none is left
--- (Log.plain): one pass turned '^^11' into a live '^1'.
---@param line any
---@return string
local function plain(line)
    return Log.plain(line)
end
Bridges.plainLine = plain

--- A line longer than OUTPUT_EVENT_BYTES, in pieces that fit, in order, and
--- never cut inside a character: a cut that would land on a byte that
--- continues one (0x80 to 0xBF) is moved back to where it starts.
---@param line string
---@return string[]
local function piecesOf(line)
    local out, at = {}, 1
    while at <= #line do
        local stop = math.min(#line, at + OUTPUT_EVENT_BYTES - 1)
        while stop < #line and stop > at do
            local next_ = line:byte(stop + 1)
            if next_ < 0x80 or next_ >= 0xC0 then break end
            stop = stop - 1
        end
        out[#out + 1] = line:sub(at, stop)
        at = stop + 1
    end
    return out
end

--- Send a player their lines, in order, batched under OUTPUT_EVENT_BYTES
--- and CH.OUTPUT_LINES_MAX lines an event, the most their game prints of
--- one (client/admin.lua). A single line longer than that goes in pieces,
--- one after another.
---@param src number
---@param lines string[]
---@param notice boolean whether to say on screen where they went
---@return integer events
function Bridges.sendOutput(src, lines, notice)
    if #lines == 0 then return 0 end
    local events, batch, size = 0, {}, 0
    local function flush()
        if #batch == 0 then return end
        TriggerClientEvent('crimson-hitman:commandOutput', src, batch)
        events = events + 1
        batch, size = {}, 0
    end
    for i = 1, #lines do
        local line = lines[i]
        local pieces = #line > OUTPUT_EVENT_BYTES and piecesOf(line) or { line }
        for _, piece in ipairs(pieces) do
            if size + #piece > OUTPUT_EVENT_BYTES or #batch >= CH.OUTPUT_LINES_MAX then flush() end
            batch[#batch + 1] = piece
            size = size + #piece
        end
    end
    flush()
    -- One short notice through the notify bridge, for somebody who typed
    -- the command in chat and is looking there for its answer.
    if notice and Notify then
        Notify.onScreen(src, 'Crimson-Hitman', 'Printed to your F8 console')
    end
    return events
end

--- Print to whoever ran the command — the console when there is no player.
local function reply(src, line)
    line = plain(line)
    if src == 0 then return Log.console(line) end
    local gathering = Gathering[coroutine.running()]
    if gathering and gathering.src == src then
        gathering.lines[#gathering.lines + 1] = line
        return
    end
    Bridges.sendOutput(src, { line }, false)
end

--- Run one command for whoever typed it, its answer gathered and sent to a
--- player's F8 console as it ends (reply). One that raises is answered so,
--- in F8 too, and the error kept for the diagnosis: printed whatever
--- Config.Debug says when the command moves money (Log.raised, as the admin
--- panel's writes are), with Debug on otherwise.
---@param src number
---@param fn function
---@param moves string|nil the command's name, for one that moves money
function Bridges.runCommand(src, fn, moves)
    if src == 0 then return fn(src) end
    local key = coroutine.running()
    local outer = Gathering[key]
    local gathering = { src = src, lines = {} }
    Gathering[key] = gathering
    local ok, err = pcall(fn, src)
    Gathering[key] = outer
    if not ok then
        if moves then
            Log.raised('command ' .. moves, ('/%s run by player %s raised: %s')
                :format(moves, tostring(src), tostring(err)))
        else
            Log.debug(('a staff command run by player %s raised: %s')
                :format(tostring(src), tostring(err)))
        end
        gathering.lines[#gathering.lines + 1] = 'That raised an error on the server; the diagnosis '
            .. 'lists it.'
    end
    Bridges.sendOutput(src, gathering.lines, true)
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
    Notify = modules.notify

    --- What a command that settles, voids or lists escrow says while boot
    --- recovery runs (App.ready), or once it has raised; nil once it has
    --- finished. The admin panel says the same (Admin.notRecovered).
    local function notRecovered()
        return Admin.notRecovered()
    end

    --- Wrap a command in its permission check. A caller without the ACE is
    --- told the same thing whether or not the contract exists, so the
    --- command cannot be used to probe for ids.
    ---@param strict boolean|nil only the named ACE: Config.Admin.ExtraAces
    --- opens the read-only commands, never one that moves money or unmasks
    --- an anonymous party.
    ---@param moves boolean|nil it moves money: one that raises is printed
    --- whatever Config.Debug says (Bridges.runCommand)
    ---
    --- Its answer goes to the console that ran it, or to the player's own
    --- F8 console (Bridges.runCommand), never chat.
    local function command(name, ace, fn, strict, moves)
        RegisterCommand(name, function(src, args)
            Bridges.runCommand(src, function()
                if not Admin.allowed(src, ace, strict) then
                    reply(src, Admin.howToAuthorise(ace))
                    return
                end
                fn(src, args or {})
            end, moves and name or nil)
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
        --
        -- And the subject's own page log, which arrives as a list: sent in
        -- as few events as it fits (Bridges.sendOutput), not one per line.
        local lines = Admin.diagnose(src, args[1], function(said)
            if type(said) ~= 'table' then return reply(src, said) end
            if src == 0 then
                for i = 1, #said do reply(0, said[i]) end
                return
            end
            local clean = {}
            for i = 1, #said do clean[i] = plain(said[i]) end
            Bridges.sendOutput(src, clean, false)
        end)
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
        local ok, err, detail = Admin.void(src, args[1], reason)
        -- In the words the admin panel uses too (Admin.voidAnswer).
        reply(src, Admin.voidAnswer(args[1], ok, err, nil, detail))
    end, true, true)

    --- One review item in words (Admin.reviews), for /ch-stuck and /ch-review.
    local function sayReview(src, item)
        local what = {}
        if (tonumber(item.amount) or 0) > 0 then
            what[#what + 1] = describeLine({ source = item.account or 'cash', amount = item.amount })
        end
        for _, entry in ipairs(type(item.items) == 'table' and item.items or {}) do
            if type(entry) == 'table' then what[#what + 1] = describeLine(entry) end
        end
        local parties = {}
        for _, party in ipairs(item.parties or {}) do
            parties[#parties + 1] = ('%s %s'):format(party.role, tostring(party.who))
        end
        reply(src, ('  %s  %s  contract %s  %s  %s%s'):format(item.id, item.kind,
            tostring(item.contract or 'n/a'), #what > 0 and table.concat(what, ', ') or 'nothing recorded',
            #parties > 0 and table.concat(parties, ', ') or 'no party recorded',
            item.created_at and ('  (' .. os.date('%Y-%m-%d %H:%M', item.created_at) .. ')') or ''))
        if item.about then reply(src, '    ' .. item.about) end

        local known = {}
        for key, value in pairs(type(item.known) == 'table' and item.known or {}) do
            known[#known + 1] = ('%s %s'):format(key, tostring(value))
        end
        table.sort(known)
        if #known > 0 then reply(src, '    known: ' .. table.concat(known, '; ')) end

        local now = item.now or {}
        local said = {}
        if now.contract then said[#said + 1] = 'contract ' .. tostring(now.contract) end
        if now.buyout then said[#said + 1] = 'buyout ' .. tostring(now.buyout) end
        if now.lines then
            said[#said + 1] = ('lines held %d, settled %d, not in the store %d')
                :format(now.lines.held, now.lines.settled, now.lines.missing)
        end
        if #said > 0 then reply(src, '    now: ' .. table.concat(said, '; ')) end

        if item.unwritten then
            reply(src, '    the store has not taken this yet; it is written once it answers, within '
                .. 'a tick, and can be resolved then')
        elseif item.settles and item.state == 'open' then
            reply(src, ('    the server settles this itself from its own record once the database '
                .. 'answers; /%s %s pay <role> settles it the same way now'):format(names.review, item.id))
        elseif item.state == 'resolving' then
            reply(src, ('    being resolved (%s, by %s) and stopped part-way: /%s %s finishes it as decided')
                :format(tostring(item.resolution and item.resolution.action), tostring(item.resolved_by),
                    names.review, item.id))
        elseif item.state == 'resolved' then
            local r = item.resolution or {}
            reply(src, ('    resolved: %s%s by %s%s%s'):format(tostring(r.action),
                r.cid and (' to ' .. tostring(r.cid)) or '', tostring(item.resolved_by),
                item.resolved_at and (' ' .. os.date('%Y-%m-%d %H:%M', item.resolved_at)) or '',
                r.note and (' (' .. r.note .. ')') or ''))
        end
    end

    --- The review queue's open items, as /ch-stuck lists them below the
    --- escrow. Read-only; /ch-review resolves one.
    local function listReviews(src)
        if not names.review then return 0 end
        local items = Admin.reviews(src)
        if #items == 0 then return 0 end
        reply(src, ('%d money event(s) no rule could settle wait for you in the review queue:')
            :format(#items))
        for i = 1, #items do sayReview(src, items[i]) end
        reply(src, ('Resolve one with /%s <id> refund <citizenid|role> <amount> [cash|bank|dirty], '
            .. '/%s <id> refund <citizenid|role> items, /%s <id> pay <citizenid|role>, or /%s <id> '
            .. 'dismiss <note>. A role is one the item names (payer, creator, ...).')
            :format(names.review, names.review, names.review, names.review))
        return #items
    end

    command(names.stuck, Config.Admin.Ace, function(src)
        -- Recovery is still putting back, leaving for staff and queuing what
        -- the last shutdown left: listed now, a line it is about to deal
        -- with read as stuck.
        local waiting = notRecovered()
        if waiting then return reply(src, waiting) end
        local lines = Admin.interrupted(src)
        -- And the review queue, last: money no rule could settle, kept until
        -- staff resolve it rather than only in the log, which is pruned.
        if #lines == 0 then
            if listReviews(src) == 0 then reply(src, 'No interrupted releases.') end
            return
        end

        local interrupted, nameless, parked, unfinished, nobody = {}, {}, {}, {}, {}
        for i = 1, #lines do
            local why = lines[i].why
            local list = (lines[i].unfinished and unfinished) or (lines[i].orphan and nameless)
                or ((why == 'owed_to_nobody' or why == 'owed_to_unchecked') and nobody)
                or (lines[i].raised and parked) or interrupted
            list[#list + 1] = lines[i]
        end

        -- Lines of a closed contract whose ending raised before it handed
        -- them over (Admin.interrupted): not left for staff, and settled by
        -- the server itself (Contracts.finishEndings).
        if #unfinished > 0 then
            reply(src, ('%d escrow line(s) of contracts whose ending did not finish (it raised part-way) '
                .. 'wait to be handed over:'):format(#unfinished))
            for i = 1, #unfinished do
                local line = unfinished[i]
                reply(src, ('  %s  contract %s  %s %s  ending unfinished; it settles itself within a '
                    .. 'minute'):format(line.line, line.contract, tostring(line.portion),
                    describeLine(line)))
            end
            reply(src, ('The server finishes each ending as a restart would: a stake by why the contract '
                .. 'ended, the rest back to the client. Nothing for /%s to do.'):format(names.settle))
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
                elseif line.why == 'stalled_claim' then
                    known = 'stalled claim: the claim that owed it raised before paying it, '
                        .. 'so nothing will give it'
                elseif line.why == 'stopped' then
                    known = 'a raise stopped it while it was being given'
                elseif line.why == 'releasing' then
                    known = 'left mid-release by a call that raised, and nothing is finishing it'
                elseif line.why == 'never_given_release' then
                    known = 'left mid-release by a call that raised before it named anyone, so '
                        .. 'nothing of it was given'
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
                if line.why ~= 'raised' and line.why ~= 'never_given_release'
                    and not modules.escrow.NEVER_GIVEN[line.why] then
                    reply(src, ('    arrival unknown: check what they received, then pay the rest '
                        .. 'with /%s %s pay <amount>, or delivered'):format(names.settle, line.line))
                end
                -- Never given, so neither handed back nor called delivered
                -- (Admin.settleLine): paid to whom it is owed, in full.
                if line.why == 'unqueued' or (line.why == 'never_given_release' and line.owed) then
                    reply(src, ('    never given: only /%s %s pay settles it, to them')
                        :format(names.settle, line.line))
                end
                -- Owed to nobody either: there is nobody to pay, and a
                -- return puts it back to its contract.
                if line.why == 'never_given_release' and not line.owed then
                    reply(src, ('    owed to nobody: /%s %s return puts it back to its contract, '
                        .. 'which keeps it while it is live and hands it back once it is closed')
                        :format(names.settle, line.line))
                end
                -- Its contract stays COMPLETING, which nothing but the next
                -- start puts back; the payout need not wait for it.
                if line.why == 'stalled_claim' then
                    reply(src, ('    stalled claim: contract %s stays mid-claim until the next start, '
                        .. 'and nothing of this was given: only /%s %s pay settles it, to them')
                        :format(line.contract, names.settle, line.line))
                end
            end
            -- A return only where one of them takes it: never a line owed to
            -- somebody (a review payout, a buyout's premium), which nobody
            -- put up, and never one nothing of which was given.
            local returnable = false
            for i = 1, #parked do
                local line = parked[i]
                if line.portion ~= CH.PORTION.OWED and not modules.escrow.NEVER_GIVEN[line.why]
                    and line.why ~= 'never_given_release' then
                    returnable = true
                end
            end
            reply(src, ('Whether such a give arrived cannot always be told, so check their '
                .. 'inventory or balance first. /%s <line> delivered if it is there (settled, '
                .. 'nothing given); /%s <line> pay if it is not (gives only what has not '
                .. 'arrived), or /%s <line> pay <amount> to give exactly what is missing%s')
                :format(names.settle, names.settle, names.settle, returnable
                    and ('; /%s <line> return to hand that back to whoever put it up instead (not '
                        .. 'for a line owed to somebody, which nobody put up)'):format(names.settle)
                    or ''))
        end

        -- Lines owed and queued to a citizen id no character has
        -- (Admin.interrupted): typed wrong before ids were checked.
        if #nobody > 0 then
            reply(src, ('%d escrow line(s) are owed and queued to a citizen id no character has, '
                .. 'so nothing will give them:'):format(#nobody))
            for i = 1, #nobody do
                local line = nobody[i]
                reply(src, ('  %s  contract %s  %s %s  owed to %s'):format(line.line, line.contract,
                    tostring(line.portion), describeLine(line), tostring(line.intended)))
                if line.why == 'owed_to_unchecked' then
                    reply(src, '    could not be checked: qbx_core did not say whether anybody has '
                        .. 'that citizen id, so it stays queued for them and is not moved')
                else
                    reply(src, ('    /%s %s return <citizenid> moves it to the citizen id it should '
                        .. 'go to'):format(names.settle, line.line))
                end
            end
        end

        if #interrupted > 0 then
            reply(src, ('%d escrow line(s) were mid-release at a shutdown:'):format(#interrupted))
            for i = 1, #interrupted do
                local line = interrupted[i]
                reply(src, ('  %s  contract %s  %s %s  was paying %s  (%s)'):format(
                    line.line, line.contract, tostring(line.portion), describeLine(line),
                    tostring(line.intended), os.date('%Y-%m-%d %H:%M', line.at)))
                -- What settles this one (Admin.interrupted): a pay needs
                -- somebody to go to, which a line the boot put back naming
                -- nobody does not have.
                if line.settles == 'queued' then
                    reply(src, '    queued for them since: nothing to settle')
                elseif line.settles == 'return_owner' then
                    reply(src, ('    does not say whose it is: /%s %s return <citizenid> once you know '
                        .. 'who put it up'):format(names.settle, line.line))
                elseif line.settles == 'pay_or_return' then
                    reply(src, ('    /%s %s pay (to them) or return (to whoever put it up)')
                        :format(names.settle, line.line))
                else
                    reply(src, ('    names nobody to pay: only /%s %s return settles it, to whoever '
                        .. 'put it up'):format(names.settle, line.line))
                end
            end
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

        listReviews(src)
    end)

    -- Not through `command`: this one refuses the extra ACEs. `command`
    -- most admin groups already carry opens every read-only tool here, and
    -- that is right for them — it is not right for the one command that
    -- moves every clock on the server.
    if names.refresh then
        RegisterCommand(names.refresh, function(src, args)
            Bridges.runCommand(src, function()
                if not Admin.allowed(src, Config.Admin.Ace, true) then
                    return reply(src, Admin.howToAuthorise(Config.Admin.Ace))
                end
                local what = tostring((args or {})[1] or 'timers'):lower()
                if what ~= 'timers' and what ~= 'refresh' then
                    return reply(src, ('Usage: /%s timers'):format(names.refresh))
                end
                local lines = Admin.refreshTimers(src)
                for i = 1, #lines do reply(src, lines[i]) end
            end, names.refresh)
        end, false)
    end

    command(names.settle, Config.Admin.Ace, function(src, args)
        local ok, err, detail = Admin.settleLine(src, args[1], args[2], args[3])
        -- In the words the admin panel uses too (Admin.settleAnswer).
        reply(src, Admin.settleAnswer(ok, err, detail))
    end, true, true)

    -- The review queue: list it, or resolve one item. Strict, as /ch-settle
    -- is, because it moves money; the list is in /ch-stuck for the rest.
    if names.review then
        command(names.review, Config.Admin.Ace, function(src, args)
            local waiting = notRecovered()
            if waiting then return reply(src, waiting) end
            local first = args[1] and tostring(args[1]):lower()
            if first == nil or first == 'list' or first == 'all' then
                local items = Admin.reviews(src, first == 'all')
                if #items == 0 then
                    return reply(src, first == 'all' and 'The review queue has never held anything.'
                        or 'Nothing waits in the review queue.')
                end
                for i = 1, #items do sayReview(src, items[i]) end
                return
            end

            local rest = {}
            for i = 2, #args do rest[#rest + 1] = args[i] end
            local ok, err, detail = Admin.resolveReview(src, args[1], rest)
            -- In the words the admin panel uses too (Admin.reviewAnswer).
            reply(src, Admin.reviewAnswer(args[1], ok, err, detail))
        end, true, true)
    end

    --- What /cleanse says for each refusal, where the app's words do not
    --- reach because the app is closed to the player running it.
    local CLEANSE_REFUSALS = {
        [CH.ERR.BAILOUT_OFF] = 'this server does not offer buyouts.',
        [CH.ERR.NO_BUYOUT_PRICE] = 'the person who placed it did not put a price on closing it.',
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
    --
    -- Registered whether or not buyouts are on, and refused while they are
    -- off: Config.Bailout.Enabled can be turned on from the admin panel, and
    -- a command registered only at a start with it on never came back.
    --
    -- Its answer goes to the player in chat, as it always has. It is a
    -- player's command, not staff's (Config.Admin.Commands alone answer in
    -- F8): mostly an officer or a medic the app is closed to, who looks for
    -- the answer where they typed it, and whose phone may show no notice
    -- from an app it does not have.
    if Config.Bailout.Command then
        local function answer(src, line)
            line = plain(line)
            if src == 0 then return Log.console(line) end
            TriggerClientEvent('chat:addMessage', src, { args = { 'CRIMSON', line } })
        end
        local function cleanse(src, args)
            if src == 0 then
                return answer(src, 'This is for a player buying out a contract on themselves.')
            end
            if not Config.Bailout.Enabled then
                return answer(src, 'Could not buy it out: ' .. CLEANSE_REFUSALS[CH.ERR.BAILOUT_OFF])
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
                return answer(src, wait > 0
                    and ('Slow down. Try again in %d second(s).'):format(wait)
                    or 'Slow down.')
            end
            if not modules.ratelimit.check(actor, 'load') then return slowDown('load') end

            local open = modules.bailout.available(actor)
            if #open == 0 then
                return answer(src, 'Nothing is out on you.')
            end

            if not args[1] then
                answer(src, ('%d contract(s) on you can be bought out:'):format(#open))
                for i = 1, #open do
                    answer(src, ('  %s  $%d%s'):format(open[i].id, open[i].amount,
                        open[i].queued and '  (already paid, closing shortly)' or ''))
                end
                return answer(src, ('Buy one out with /%s <id>'):format(Config.Bailout.Command))
            end

            -- Not while boot recovery runs (App.ready), like every app request.
            -- Nor ever, once it has raised (App.recoveryFailed): the gate stays
            -- shut until a restart, so a moment changes nothing, and the
            -- console has told staff (BOOT RECOVERY FAILED).
            if modules.app and modules.app.ready == false then
                if modules.app.recoveryFailed then
                    return answer(src, 'The server\'s contract system failed to start, and staff have '
                        .. 'been told. Nothing was charged.')
                end
                return answer(src, 'The server is still starting. Try again in a moment.')
            end
            if not modules.ratelimit.check(actor, 'bailout') then return slowDown('bailout') end

            local ok, err = modules.bailout.buy(actor, args[1])
            if not ok then
                -- Nothing was bought, so the purchase allowance goes back,
                -- as the app's own handler does. And in words: the command
                -- printed the raw code, "Could not buy it out: incapacitated".
                modules.ratelimit.refund(actor, 'bailout')
                return answer(src, 'Could not buy it out: '
                    .. (CLEANSE_REFUSALS[err] or tostring(err)))
            end
            answer(src, 'Paid. The contract closes shortly.')
        end
        RegisterCommand(Config.Bailout.Command, function(src, args)
            local ok, err = pcall(cleanse, src, args or {})
            if not ok then
                -- A buyout takes the premium before it records it, so one
                -- that raised may have charged part of it: printed whatever
                -- Config.Debug says, as an app request's would be.
                Log.raised('command ' .. Config.Bailout.Command, ('/%s run by player %s raised: %s')
                    :format(Config.Bailout.Command, tostring(src), tostring(err)))
                answer(src, 'That raised an error on the server; staff can see what in the '
                    .. 'diagnosis.')
            end
        end, false)
    end

    -- The admin panel. Opening it reads, so the gate is the one the read
    -- commands use (Ace, or one of ExtraAces); every request the page makes
    -- afterwards is checked again on the server (Panel.handle), and
    -- anything that writes needs Ace itself. The page is drawn by the
    -- player's own game, so there is nothing to open from the console.
    if names.panel then
        command(names.panel, Config.Admin.Ace, function(src)
            if src == 0 then
                return reply(src, ('The admin panel opens in game. From the console: /%s, /%s, '
                    .. '/%s and /%s.'):format(names.diagnose, names.stuck, names.contracts,
                    names.timeline))
            end
            local access = modules.panel and modules.panel.open(src)
            if not access then return reply(src, Admin.howToAuthorise(Config.Admin.Ace)) end
            TriggerClientEvent('crimson-hitman:adminOpen', src, access)
        end)
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
