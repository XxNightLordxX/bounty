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
    end

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
            -- Session length is measured here rather than asked of the
            -- framework, so the new-player rule always has an answer.
            modules.identity.beginSession(actor.cid)
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
        if not modules.ratelimit.check(actor.cid, 'mugshot') then return end
        modules.mugshot.store(actor.cid, image)
    end)

    RegisterNetEvent('crimson-bounty:appearanceChanged', function()
        local src = source
        if not modules.app.floodOk(src, 'appearanceChanged') then return end
        local actor = modules.identity.resolve(src)
        if not actor then return end
        if not modules.ratelimit.check(actor.cid, 'mugshot') then return end
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

    return true
end

return Bridges
