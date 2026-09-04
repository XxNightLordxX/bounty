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
            if victimSrc and victimSrc > 0 and victimSrc ~= sender then
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
                :format(delivered, delivered == 1 and ' has' or 's have'))
    end
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
            if c.creator_cid == cid and c.state == CB.STATE.ACTIVE then
                modules.contracts.resolve(c.id, CB.STATE.CANCELLED, cid, nil,
                    'creator_disconnected_memory_mode')
            end
        end
    end

    return true
end

--- Register every bridge against the live runtime.
function Bridges.install(modules)
    -- Per-contract caches in modules that contracts.lua cannot see are
    -- released through this hook when a contract resolves.
    modules.contracts.onResolved = function(contractId)
        modules.informant.clearContract(contractId)
        modules.comms.clearContract(contractId)
        modules.death.clearProximity(contractId)
    end

    -- The expiry pass skips itself when nothing could have changed since the
    -- last one. Creating or ending a contract can move the earliest
    -- deadline, so it is told.
    modules.contracts.onChanged = modules.scheduler and modules.scheduler.contractsChanged or nil

    -- Citizen ids are remembered while players are connected, so disconnect
    -- cleanup does not depend on the framework still knowing them.
    local connected = {}

    AddEventHandler('weaponDamageEvent', function(sender, data)
        Bridges.onWeaponDamage(modules, sender, data)
    end)

    local function remember(src)
        local actor = modules.identity.resolve(src)
        if actor then
            connected[src] = actor.cid
            -- Someone arriving can unpause a contract's clock.
            if modules.scheduler then modules.scheduler.presenceChanged() end
            -- A session we watched begin, so its length is known exactly.
            -- Identity.resolve may already have noted them as observed; this
            -- replaces that with the real thing.
            modules.identity.endSession(actor.cid)
            modules.identity.beginSession(actor.cid, false)
        end
        return actor
    end

    RegisterNetEvent('QBCore:Server:OnPlayerLoaded', function()
        local src = source
        remember(src)
        SetTimeout(Config.PendingEscrow.LoginRetryDelayMs or 5000, function()
            Bridges.onPlayerReady(modules, src)
        end)
    end)

    AddEventHandler('qbx_core:server:playerLoaded', function(player)
        if not (player and player.PlayerData) then return end
        local src = player.PlayerData.source
        remember(src)
        SetTimeout(Config.PendingEscrow.LoginRetryDelayMs or 5000, function()
            Bridges.onPlayerReady(modules, src)
        end)
    end)

    -- A player's own client is the only one that can reliably render their
    -- headshot, so the image arrives from them and is bounded on arrival.
    RegisterNetEvent('crimson-bounty:mugshot', function(image)
        local src = source
        if not modules.app.floodOk(src, 'mugshot') then return end
        local actor = modules.identity.resolve(src)
        if not actor then return end
        if not modules.ratelimit.check(actor, 'mugshot') then return end
        modules.mugshot.store(actor.cid, image)
    end)

    RegisterNetEvent('crimson-bounty:appearanceChanged', function()
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
        connected[src] = nil
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
    local function unload(src)
        src = tonumber(src)
        if not src then return end

        local cid = connected[src]
        if not cid then
            local actor = modules.identity.resolve(src)
            cid = actor and actor.cid
        end
        connected[src] = nil
        if cid then Bridges.onPlayerDropped(modules, cid) end
    end

    -- Both spellings: qbx_core emits the QBCore-compatible one, and a build
    -- that emits its own is still covered. The handler is idempotent, so
    -- being called twice for one switch costs nothing.
    AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
        unload(src or source)
    end)
    AddEventHandler('qbx_core:server:playerLoggedOut', function(src)
        unload(src or source)
    end)

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

--- Register the staff commands. Kept here with the other engine bindings so
--- there is one place that knows what this resource attaches to the runtime.
function Bridges.installCommands(modules)
    if not Config.Admin.Enabled then return false end

    local Admin = modules.admin
    local names = Config.Admin.Commands

    --- Wrap a command in its permission check. A caller without the ACE is
    --- told the same thing whether or not the contract exists, so the
    --- command cannot be used to probe for ids.
    local function command(name, ace, fn)
        RegisterCommand(name, function(src, args)
            if not Admin.allowed(src, ace) then
                reply(src, 'Not authorised.')
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
    command(names.diagnose, Config.Admin.Ace, function(src)
        local lines = Admin.diagnose(src)
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
                line.id, line.portion, line.source,
                line.amount and ('$' .. line.amount) or (tostring(line.item) .. ' x' .. tostring(line.quantity)),
                tostring(line.slot), line.state))
        end

        for i = 1, #view.events do
            local row = view.events[i]
            reply(src, ('  %s  %-10s %s'):format(
                os.date('%H:%M:%S', row.ts), row.kind, row.action))
        end
    end)

    command(names.void, Config.Admin.Ace, function(src, args)
        local reason = table.concat(args, ' ', math.min(2, #args + 1))
        local ok, err = Admin.void(src, args[1], reason)
        reply(src, ok and 'Contract voided; escrow returned to the creator.'
                       or ('Could not void it: ' .. tostring(err)))
    end)

    command(names.stuck, Config.Admin.Ace, function(src)
        local lines = Admin.interrupted()
        if #lines == 0 then return reply(src, 'No interrupted releases.') end

        reply(src, ('%d escrow line(s) were mid-release at a shutdown:'):format(#lines))
        for i = 1, #lines do
            local line = lines[i]
            reply(src, ('  %s  contract %s  %s  was paying %s  (%s)'):format(
                line.line, line.contract,
                line.amount and ('$' .. line.amount) or tostring(line.item),
                tostring(line.intended), os.date('%Y-%m-%d %H:%M', line.at)))
        end
        reply(src, ('Settle each with /%s <line> pay|return'):format(names.settle))
    end)

    command(names.settle, Config.Admin.Ace, function(src, args)
        local ok, err = Admin.settleLine(src, args[1], args[2])
        reply(src, ok and 'Line settled.' or ('Could not settle it: ' .. tostring(err)))
    end)

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
            if not modules.ratelimit.check(actor, 'bailout') then
                return reply(src, 'Slow down.')
            end

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

            local ok, err = modules.bailout.buy(actor, args[1])
            reply(src, ok and 'Paid. The contract closes shortly.'
                          or ('Could not buy it out: ' .. tostring(err)))
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
        for i = 1, #who.hunters do
            local h = who.hunters[i]
            reply(src, ('%-8s %s  %s%s'):format(
                h.alias or 'operative', h.cid, h.name,
                h.anonymous and '  (listed anonymously)' or ''))
        end
    end)

    return true
end

return Bridges
