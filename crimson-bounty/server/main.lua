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
    require('server.bridges').install(modules)

    Recover()
    amendments.reindex()
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
    modules.death.sweep()
    require('server.app').sweepHandles()
    ExpireContracts()
    if Storage.flush then Storage.flush() end
end

--- Close contracts whose deadline has passed.
---
--- The completion clock is paused while either party is offline, so logging
--- out cannot run out a hunter's timer and cannot dodge a refund (§7.1). The
--- absolute lifetime is NOT paused: without that ceiling a contract whose
--- creator never logs in again would hold its escrow forever.
---
--- Pause bookkeeping is written only when a contract changes pause state,
--- not on every tick: rewriting every paused contract every ten seconds is a
--- database write per contract per tick, forever.
function ExpireContracts()
    local contracts = Storage.allContracts()
    local now = os.time()
    local resolved = 0

    for i = 1, #contracts do
        local contract = contracts[i]
        if contract.state == CB.STATE.ACTIVE or contract.state == CB.STATE.ACCEPTED then
            -- The absolute ceiling applies whatever anyone's presence is.
            if contract.expires_at and now > contract.expires_at then
                modules.contracts.resolve(contract.id, CB.STATE.EXPIRED,
                    contract.creator_cid, nil, 'lifetime_exceeded')
                resolved = resolved + 1
            else
                local creatorOnline = modules.identity.byCitizenId(contract.creator_cid) ~= nil
                local targetOnline = modules.identity.byCitizenId(contract.target_cid) ~= nil
                local paused = not (creatorOnline and targetOnline)

                if paused then
                    -- Record when the pause began, once. The deadline is
                    -- extended when it ends, by however long it lasted.
                    if not contract.paused_since then
                        contract.paused_since = now
                        Storage.writeContract(contract)
                    end
                else
                    if contract.paused_since then
                        local pausedFor = now - contract.paused_since
                        contract.paused_ms = (contract.paused_ms or 0) + (pausedFor * 1000)
                        contract.deadline_at = (contract.deadline_at or now) + pausedFor
                        contract.paused_since = nil
                        Storage.writeContract(contract)
                    end

                    if contract.deadline_at and now > contract.deadline_at then
                        modules.contracts.resolve(contract.id, CB.STATE.EXPIRED,
                            contract.creator_cid, nil, 'expired')
                        resolved = resolved + 1
                    end
                end
            end
        end
    end

    return resolved
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

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
