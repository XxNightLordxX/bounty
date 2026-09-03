--- Bootstrap and the maintenance tick.
---
--- Wires the modules together, validates the configuration at boot, and owns
--- the only recurring timer in the resource besides the kidnap countdown.

local Storage
local modules = {}

--------------------------------------------------------------------------
-- Boot validation (§14.47)
--------------------------------------------------------------------------

--- Refuse to start on a configuration that cannot behave correctly, and warn
--- on one that is merely surprising. A silent misconfiguration here is a
--- money bug later.
local function validateConfig()
    local fatal, warn = {}, {}

    local mode = Config.Database.Mode
    if mode ~= 'mysql' and mode ~= 'json' and mode ~= 'memory' then
        fatal[#fatal + 1] = ('Config.Database.Mode is "%s"; expected mysql, json or memory'):format(tostring(mode))
    end

    if Config.Bailout.MinMultiplier > Config.Bailout.MaxMultiplier then
        fatal[#fatal + 1] = 'Bailout MinMultiplier is above MaxMultiplier; no premium could ever be valid'
    end

    if Config.Limits.MaxPayoutSlots < 1 then
        fatal[#fatal + 1] = 'Config.Limits.MaxPayoutSlots must be at least 1'
    end

    if Config.Ledger.Depth > Config.Ledger.MaxDepthHardCap then
        warn[#warn + 1] = ('Ledger.Depth (%d) exceeds the hard cap (%d); the cap wins')
            :format(Config.Ledger.Depth, Config.Ledger.MaxDepthHardCap)
    end

    if Config.Payout.AllowConversion then
        warn[#warn + 1] = ('Payout.AllowConversion is on at rate %.2f. Check this matches your ' ..
            'black market rate, or the escrow becomes a laundering rail')
            :format(Config.Payout.DirtyConversionRate)
    end

    if mode == 'memory' then
        warn[#warn + 1] = 'Database.Mode is "memory": contracts and escrow will NOT survive a restart'
    end

    if not Config.Kidnap.RequireCoercion then
        warn[#warn + 1] = 'Kidnap.RequireCoercion is off: a target can be "delivered" while walking freely'
    end

    if Config.Advisory.Enabled and not next(Config.Advisory.RecipientJobTypes)
        and not next(Config.Advisory.RecipientJobNames) then
        warn[#warn + 1] = 'Advisory is enabled but nobody is configured to receive it'
    end

    for _, message in ipairs(warn) do
        print('[crimson-bounty] warning: ' .. message)
    end
    if #fatal > 0 then
        for _, message in ipairs(fatal) do
            print('[crimson-bounty] FATAL: ' .. message)
        end
        error('[crimson-bounty] refusing to start on an invalid configuration')
    end

    return true
end

--------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------

local function selectStorage()
    local mode = Config.Database.Mode
    if mode == 'mysql' then return require('server.storage.mysql') end
    if mode == 'json' then return require('server.storage.json') end
    return require('server.storage.memory')
end

function StartCrimsonBounty()
    validateConfig()

    Storage = selectStorage()
    Storage.open()

    local identity   = require('server.identity')
    local ratelimit  = require('server.ratelimit')
    local audit      = require('server.audit')
    local notify     = require('server.notify')
    local escrow     = require('server.escrow')
    local contracts  = require('server.contracts')
    local ledger     = require('server.ledger')
    local death      = require('server.completion.death')
    local photo      = require('server.completion.photo')
    local kidnap     = require('server.completion.kidnap')
    local bailout    = require('server.bailout')
    local informant  = require('server.informant')
    local amendments = require('server.amendments')
    local comms      = require('server.comms')
    local projection = require('server.projection')
    local app        = require('server.app')

    audit.init(Storage)
    notify.init({ identity = identity })
    escrow.init(Storage, audit)
    contracts.init({ storage = Storage, escrow = escrow, identity = identity,
                     audit = audit, notify = notify })
    ledger.init(Storage)
    death.init({ storage = Storage, identity = identity, contracts = contracts, audit = audit })
    photo.init({ storage = Storage, identity = identity, contracts = contracts, audit = audit,
                 death = death, notify = notify, ledger = ledger })
    kidnap.init({ storage = Storage, identity = identity, contracts = contracts,
                  audit = audit, notify = notify, ledger = ledger })
    bailout.init({ storage = Storage, identity = identity, contracts = contracts,
                   escrow = escrow, audit = audit, notify = notify })
    informant.init({ storage = Storage, identity = identity, audit = audit })
    amendments.init({ storage = Storage, identity = identity, contracts = contracts,
                      escrow = escrow, audit = audit, notify = notify })
    comms.init({ storage = Storage, identity = identity, audit = audit,
                 notify = notify, ratelimit = ratelimit })
    projection.init({ storage = Storage, identity = identity, escrow = escrow, kidnap = kidnap })

    modules = {
        storage = Storage, identity = identity, ratelimit = ratelimit, audit = audit,
        notify = notify, escrow = escrow, contracts = contracts, ledger = ledger,
        death = death, photo = photo, kidnap = kidnap, bailout = bailout,
        informant = informant, amendments = amendments, comms = comms,
        projection = projection,
    }

    app.init(modules)

    Recover()
    StartTick()

    print(('[crimson-bounty] started in %s mode'):format(Config.Database.Mode))
    return modules
end

--------------------------------------------------------------------------
-- Restart recovery (§10.4)
--------------------------------------------------------------------------

--- Resolve anything the last shutdown left mid-flight. A contract caught in
--- `completing`, or an escrow line caught in `releasing`, is reconciled
--- exactly once by re-reading whether the funds actually moved.
function Recover()
    local contracts = Storage.allContracts()
    local recovered, unstuck = 0, 0

    for i = 1, #contracts do
        local contract = contracts[i]

        if contract.state == CB.STATE.COMPLETING then
            -- Settlement was interrupted. Put it back to accepted so the
            -- normal path can run again; escrow lines are individually
            -- guarded, so anything already settled stays settled.
            Storage.compareSetContractState(contract.id, CB.STATE.COMPLETING, CB.STATE.ACCEPTED)
            recovered = recovered + 1
        end

        local lines = Storage.readEscrow(contract.id)
        for j = 1, #lines do
            if lines[j].state == CB.ESCROW_STATE.RELEASING then
                -- Claimed but never settled: the delivery did not complete,
                -- so the line is owed again rather than lost.
                Storage.claimEscrowLine(lines[j].id, CB.ESCROW_STATE.RELEASING, CB.ESCROW_STATE.HELD)
                unstuck = unstuck + 1
            end
        end
    end

    if recovered > 0 or unstuck > 0 then
        print(('[crimson-bounty] recovery: %d contracts resumed, %d escrow lines unstuck')
            :format(recovered, unstuck))
        modules.audit.action('startup_recovery', nil, nil,
            { contracts = recovered, lines = unstuck })
    end

    return recovered, unstuck
end

--------------------------------------------------------------------------
-- Maintenance tick
--------------------------------------------------------------------------

function StartTick()
    CreateThread(function()
        while true do
            Wait(10000)
            local ok, err = pcall(Tick)
            if not ok then print('[crimson-bounty] tick error: ' .. tostring(err)) end
        end
    end)
end

function Tick()
    modules.audit.flush()
    modules.amendments.expire()
    modules.bailout.processQueue()
    modules.photo.sweep()
    ExpireContracts()
    if Storage.flush then Storage.flush() end
end

--- Close contracts whose deadline has passed. The clock is paused while
--- either party is offline, so logging out cannot run out a hunter's timer
--- and cannot dodge a refund (§7.1).
function ExpireContracts()
    local contracts = Storage.allContracts()
    local now = os.time()

    for i = 1, #contracts do
        local contract = contracts[i]
        if contract.state == CB.STATE.ACTIVE or contract.state == CB.STATE.ACCEPTED then
            local creatorOnline = modules.identity.byCitizenId(contract.creator_cid) ~= nil
            local targetOnline = modules.identity.byCitizenId(contract.target_cid) ~= nil

            if not (creatorOnline and targetOnline) then
                -- Paused: push the deadline out by the elapsed interval.
                contract.deadline_at = (contract.deadline_at or now) + 10
                contract.paused_ms = (contract.paused_ms or 0) + 10000
                Storage.writeContract(contract)
            elseif contract.deadline_at and now > contract.deadline_at then
                modules.contracts.resolve(contract.id, CB.STATE.EXPIRED,
                    contract.creator_cid, nil, 'expired')
            end
        end
    end
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

--- When a player comes online, deliver anything the script owes them from a
--- previous session — a payout that could not be handed over because their
--- inventory was full, or because they had already logged out (§9.3).
local function onPlayerReady(src)
    local actor = modules.identity and modules.identity.resolve(src)
    if not actor then return end

    SetTimeout(Config.PendingEscrow.LoginRetryDelayMs or 5000, function()
        local delivered = modules.escrow.retryPending(actor.cid)
        if delivered > 0 then
            modules.notify.toCitizen(actor.cid, 'Outstanding payment',
                ('%d outstanding item%s been delivered.')
                    :format(delivered, delivered == 1 and ' has' or 's have'))
        end
    end)
end

RegisterNetEvent('QBCore:Server:OnPlayerLoaded', function()
    onPlayerReady(source)
end)

AddEventHandler('qbx_core:server:playerLoaded', function(player)
    if player and player.PlayerData then onPlayerReady(player.PlayerData.source) end
end)

AddEventHandler('playerDropped', function()
    local src = source
    local actor = modules.identity and modules.identity.resolve(src)
    if not actor then return end

    modules.ratelimit.clear(actor.cid)
    modules.death.clearPlayer(actor.cid)
    modules.photo.clearPlayer(actor.cid)
    modules.kidnap.clearPlayer(actor.cid)

    -- Memory mode holds no durable escrow, so a creator disconnecting would
    -- strand it. Refund and close rather than risk losing their property.
    if Config.Database.Mode == 'memory' then
        local contracts = Storage.allContracts()
        for i = 1, #contracts do
            local c = contracts[i]
            if c.creator_cid == actor.cid and c.state == CB.STATE.ACTIVE then
                modules.contracts.resolve(c.id, CB.STATE.CANCELLED, actor.cid, nil,
                    'creator_disconnected_memory_mode')
            end
        end
    end
end)

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    if not modules.audit then return end

    modules.audit.flush()

    -- Memory mode: release every open escrow before the tables vanish.
    if Config.Database.Mode == 'memory' then
        local contracts = Storage.allContracts()
        for i = 1, #contracts do
            local c = contracts[i]
            if not CB.TERMINAL[c.state] then
                modules.escrow.release(c.id, c.creator_cid, nil, 'resource_stopping')
            end
        end
    end

    if Storage and Storage.close then Storage.close() end
end)

return { start = StartCrimsonBounty, recover = Recover, tick = Tick, expire = ExpireContracts }
