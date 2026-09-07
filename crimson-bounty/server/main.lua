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
--- Fill in settings the code needs that this config does not have.
---
--- config.lua is a file server owners edit, and once edited it stops
--- tracking the shipped one. Every setting added afterwards is simply
--- absent from their copy — and absent reads as nil, which is how
--- "browse everyone in the city" turned into an empty list on a live
--- server with nothing anywhere to say why.
---
--- Defaults are applied rather than refused: an operator who has never
--- touched a setting has no opinion about it, and a feature that does
--- nothing is worse than one that works the way it shipped. What was filled
--- in is printed, so the operator knows their config has drifted.
local DEFAULTS = {
    Targeting = {
        MinQueryLength = 3,
        MaxResults = 8,
        AllowBrowseAll = true,
        BrowsePageSize = 30,
        AllowNearby = true,
        NearbyRadius = 30.0,
        MaxNearby = 12,
        AllowProtectedJobTargets = true,
    },
    Sources = {
        --- Items and weapons as rewards. A config that predates these has
        --- them absent, not false — and the app reads absent as the server
        --- refusing goods, so the Place form says "money only" and drops
        --- both pickers. Absent is not a decision; false is, and false is
        --- left alone.
        item   = { enabled = true, maxStacks = 10, maxPerStack = 100 },
        weapon = { enabled = true, max = 3 },

        --- The three money sources. These were left out on the assumption
        --- that every config has them, and the code reads them without
        --- checking: Config.Sources.dirty.item, .cash.max and .bank.max are
        --- all indexed directly while building the Place form. Any one of
        --- them missing throws inside the wallet handler, which the player
        --- reads as "Could not read what you are carrying" and an operator
        --- sees as nothing at all.
        ---
        --- `dirty` is the odd one: it is not a qbx_core account but an
        --- ox_inventory item, so it carries the item name the balance is
        --- actually stored under.
        cash   = { enabled = true, max = 250000 },
        bank   = { enabled = true, max = 500000 },
        dirty  = { enabled = true, max = 250000, item = 'black_money' },
    },
    --- Indexed while building the same form, and absent on any config older
    --- than the kidnapping bonus.
    Bonus = {
        maxPercent = 200,
    },
    --- Read by the boot validation itself, which runs after this fills the
    --- gaps — but only just. A config without it took the whole resource
    --- down before it could say what was wrong.
    Payout = {
        AllowConversion = false,
        DirtyConversionRate = 0.85,
    },
    Cooldowns = {
        -- Split out of one shared bucket. On a config that predates the
        -- split these are absent, and an absent rule is not a licence to
        -- act — RateLimit falls back to a conservative one — but the app
        -- deserves the allowance it was built against.
        load   = { per = 10, burst = 20 },
        search = { per = 10, burst = 15 },
        wallet = { per = 10, burst = 8 },
    },
    --- The names the admin commands register under. Indexed directly while
    --- registering them, so a config carrying an Admin section without this
    --- key took the resource down at boot — including cb-diag, which is the
    --- one command an operator needs in order to find out why.
    Admin = {
        Commands = {
            timeline = 'cb-timeline',
            void     = 'cb-void',
            stuck    = 'cb-stuck',
            settle   = 'cb-settle',
            whois    = 'cb-whois',
            diagnose = 'cb-diag',
        },
    },
    --- Both read by the boot validation itself. Absent, they did not produce
    --- a warning about a misconfigured advisory — they crashed the check
    --- that would have reported it.
    Advisory = {
        RecipientJobTypes = { leo = true, police = true },
        RecipientJobNames = {
            police = true, sheriff = true, bcso = true, fib = true,
            trooper = true, sasp = true, ranger = true,
        },
    },
    Immunity = {
        MinTargetPlaytimeHours = 5,
    },
    --- Read while validating the text on every contract placed. A missing
    --- one is not a relaxed rule but a comparison or an ipairs against nil,
    --- so nobody can place a contract at all.
    Reason = {
        MaxLength = 140,
        MaxDigits = 6,
        PatternDenylist = { 'https?://', 'discord%.gg', 'www%.', '@%w+' },
    },
    --- The notification budget, consulted before every message the resource
    --- sends. Absent, placing or cancelling a contract answers server_error
    --- on the notify rather than on anything the player did.
    Notifications = {
        MaxPerRecipientPerMinute = 6,
        MaxPerRecipientPerHour = 40,
    },
    --- Read on the create path, where a nil cooldown is a comparison
    --- against nil rather than no cooldown.
    Amendments = {
        CancelCooldownSeconds = 300,
    },
    --- Both read inside the purchase. A missing price is not a free
    --- informant; it is one nobody can buy.
    Informant = {
        Cost = 25000,
        MaxPurchasesPerContract = 2,
    },
    --- Compared against a count in Kidnap.arm, so a missing one is not a
    --- disabled cap but a comparison against nil: every attempt to start a
    --- live delivery answers server_error.
    Kidnap = {
        MaxConcurrentCountdowns = 20,
    },
    --- The board's page size, read straight into arithmetic in
    --- Projection.listing. Absent, it takes down `list` — the app's home
    --- screen, for every player, on every request.
    Listing = {
        PageSize = 15,
    },
    --- The four job sets the advisory rules read. Indexed directly in
    --- Identity.isProtectedJob and isAdvisoryRecipient, which run inside
    --- searchTargets and browseTargets, so a missing one empties the whole
    --- target picker rather than merely switching an advisory off.
    Advisory = {
        TriggerJobTypes = { leo = true, police = true, ems = true, fire = true },
        TriggerJobNames = { doj = true, lawyer = true, ranger = true },
        RecipientJobTypes = { leo = true, police = true },
        RecipientJobNames = {
            police = true, sheriff = true, bcso = true, fib = true,
            trooper = true, sasp = true, ranger = true,
        },
    },
    --- What the json backend needs before it can open at all. Read from the
    --- first line of JsonStore.open(), so a Database section written before
    --- this block existed — or trimmed — took the resource down at boot,
    --- past the validation meant to catch exactly that.
    Database = {
        Json = {
            Directory = 'data',
            SyncOnFinancialWrite = true,
            WarnContractCount = 2000,
            MaxDirtyShardsPerFlush = 25,
        },
    },
}

--- A deep copy of a shipped default, so the live config and the fallback
--- are never the same table.
local function copyOf(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copyOf(v) end
    return out
end

local function applyConfigDefaults()
    local filled = {}

    -- Whole sections the operator's config does not have at all.
    --
    -- config.lua stops tracking the shipped one the moment it is edited, so
    -- every setting added afterwards is absent from their copy — and absent
    -- is nil, which the server then indexes inside a request handler. Three
    -- separate live-server outages have come from exactly that, each one
    -- looking to the player like "Could not read what you are carrying" and
    -- to the operator like nothing at all.
    --
    -- Only sections that are missing ENTIRELY. A table the operator has
    -- written is theirs: topping it up would put back entries they removed
    -- on purpose, and Config.BlockedJobNames is a set, so restoring a job
    -- somebody deleted from it would be worse than the gap. Per-key filling
    -- is deliberate and lives in DEFAULTS below, for the handful of
    -- record-shaped settings where it is safe.
    if type(ConfigDefaults) == 'table' then
        for section, shipped in pairs(ConfigDefaults) do
            if Config[section] == nil then
                -- A copy, not the shipped table itself.
                --
                -- Assigning it directly made Config.<section> and
                -- ConfigDefaults.<section> the same table, so anything that
                -- later wrote to the live config wrote through to the
                -- fallback — and the shipped defaults stopped being the
                -- shipped defaults for the rest of the process. A second
                -- pass then had nothing left to fall back to, which is the
                -- opposite of what this function is for.
                Config[section] = copyOf(shipped)
                filled[#filled + 1] = section .. ' (whole section)'
            end
        end
    end

    for section, defaults in pairs(DEFAULTS) do
        if type(Config[section]) ~= 'table' then Config[section] = {} end

        for key, value in pairs(defaults) do
            local held = Config[section][key]

            if held == nil then
                -- Copied for the same reason the whole sections are: several
                -- of these are tables, and handing the live config the
                -- fallback's own table makes writes to one writes to both.
                Config[section][key] = copyOf(value)
                filled[#filled + 1] = section .. '.' .. key

            elseif type(value) == 'table' and type(held) == 'table' then
                -- A setting the operator has but only half of. Filling the
                -- missing fields matters as much as the whole entry: an
                -- item source with no maxPerStack is a source nothing can
                -- be escrowed through.
                -- Copied like the rest. No default is currently a table
                -- this deep, so nothing exercises it — it is here so that
                -- adding one cannot quietly reintroduce the alias.
                for field, fallback in pairs(value) do
                    if held[field] == nil then
                        held[field] = copyOf(fallback)
                        filled[#filled + 1] = section .. '.' .. key .. '.' .. field
                    end
                end
            end
        end
    end

    if #filled > 0 then
        table.sort(filled)
        print(('[crimson-bounty] your config.lua does not set %d setting(s); the shipped '
            .. 'defaults are being used for them: %s. Copy them across from the config '
            .. 'that ships with this resource to set them yourself.')
            :format(#filled, table.concat(filled, ', ')))
    end

    return filled
end

local function validateConfig()
    local fatal, warn = {}, {}

    -- Before anything is read: a setting this config never had is nil, and
    -- the checks below would report it as broken rather than as absent.
    applyConfigDefaults()

    -- Every value the code puts straight into arithmetic or a comparison.
    -- A key an operator deleted or misspelled while editing their config is
    -- nil, and nil does not fail here — it fails deep inside whichever
    -- handler reaches that line first, as an error in a player's face with
    -- nothing to say which setting caused it.
    --
    -- This is the operator's copy of the config, which the static check
    -- cannot see. The static check covers the other direction: a key the
    -- code reads that the shipped config never defined.
    local REQUIRED_NUMBERS = {
        { 'Limits', 'MaxActiveContractsPerCreator' },
        { 'Limits', 'MaxAcceptedPerHunter' },
        { 'Limits', 'MaxActiveContractsPerTarget' },
        { 'Limits', 'MaxHuntersPerContract' },
        { 'Limits', 'MaxPayoutSlots' },
        { 'Limits', 'MaxEscrowLines' },
        { 'Limits', 'MaxDeadlineSkipSeconds' },
        { 'Limits', 'SlotCooldownSeconds' },
        { 'Limits', 'ContractLifetimeSeconds' },
        { 'Limits', 'DefaultDeadlineSeconds' },
        { 'Limits', 'TargetCooldownAfterResolveSeconds' },
        { 'Limits', 'SameCreatorSameTargetCooldownSeconds' },
        { 'Bonus', 'maxPercent' },
        { 'Bailout', 'MinMultiplier' },
        { 'Bailout', 'MaxMultiplier' },
        { 'Bailout', 'AbsoluteMax' },
        { 'Bailout', 'ProcessingDelaySeconds' },
        { 'Completion', 'PhotoTokenLifetimeSeconds' },
        { 'Completion', 'ProofWindowSeconds' },
        { 'Completion', 'DeathReportWindowMs' },
        { 'Completion', 'PhotoRadius' },
        { 'Completion', 'MaxWeaponRange' },
        { 'Kidnap', 'CountdownSeconds' },
        { 'Kidnap', 'MaxTotalGraceMs' },
        { 'Audit', 'MaxQueueSize' },
        { 'Audit', 'RetentionDays' },
        { 'Ledger', 'Depth' },
        { 'Ledger', 'MaxDepthHardCap' },
        { 'Informant', 'RerollLockMinutes' },
        { 'Amendments', 'ProposalExpirySeconds' },
        { 'Amendments', 'MaxOpenPerContract' },
        { 'Relay', 'MaxLength' },
    }

    for _, entry in ipairs(REQUIRED_NUMBERS) do
        local section, key = entry[1], entry[2]
        local block = Config[section]
        if type(block) ~= 'table' then
            fatal[#fatal + 1] = ('Config.%s is missing entirely'):format(section)
        elseif type(block[key]) ~= 'number' then
            fatal[#fatal + 1] = ('Config.%s.%s is %s; it has to be a number, and is used '
                .. 'in arithmetic that would otherwise throw at the first player who '
                .. 'reached it'):format(section, key, type(block[key]))
        end
    end

    -- Every check below compares these values, and a comparison against nil
    -- throws — so a hole in the config would take out the very code written
    -- to report it. Nothing else runs until the shapes are known good.
    if #fatal > 0 then
        for _, message in ipairs(fatal) do
            print('[crimson-bounty] FATAL: ' .. message)
        end
        error('[crimson-bounty] refusing to start on an invalid configuration')
    end

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

    -- Settings that name a money account and are handed straight to
    -- AddMoney or RemoveMoney. 'dirty' is a money SOURCE but not an
    -- account, so naming it here charges nothing and returns false — which
    -- surfaces as an anonymous contract that cannot be placed, or an
    -- informant that always says you cannot afford it, with nothing
    -- anywhere connecting that to a line in config.lua.
    --
    -- Corrected rather than fatal: the resource stays up, the operator is
    -- told exactly which setting and what it was changed to.
    for _, named in ipairs({
        { table = Config.Anonymity, key = 'FeeAccount', label = 'Anonymity.FeeAccount' },
        { table = Config.Informant, key = 'Account', label = 'Informant.Account' },
    }) do
        local holder = named.table
        local value = holder and holder[named.key]
        if holder and value ~= nil and not CB.MONEY_ACCOUNTS[value] then
            holder[named.key] = 'bank'
            warn[#warn + 1] = ('%s is "%s", which is not an account this '
                .. 'framework can charge (only cash and bank are; dirty money is '
                .. 'an inventory item). Using bank instead — set it to cash or '
                .. 'bank to choose')
                :format(named.label, tostring(value))
        end
    end

    if Config.Payout.AllowConversion then
        -- Honest about what it currently does, which is nothing. The branch
        -- it gates (escrow.lua, `line.convertTo == 'dirty'`) reads a field
        -- no code in this resource ever writes, so no payout has ever been
        -- converted. Warning about a laundering rail that does not exist
        -- sends an operator looking for a risk they do not have, and would
        -- have them believe a feature is live that is not.
        warn[#warn + 1] = 'Payout.AllowConversion is on, but nothing selects a '
            .. 'conversion: escrow always pays out in the source it was taken '
            .. 'in. The setting has no effect today. Leave it off unless a '
            .. 'later version wires it up'
    end

    if mode == 'memory' then
        warn[#warn + 1] = 'Database.Mode is "memory": contracts and escrow will NOT survive a restart'
    end

    -- A rule that cannot be evaluated is worse than one that is off, because
    -- nobody can tell. Say so at startup rather than silently skipping it.
    -- Guarded rather than assumed. These checks exist to report a
    -- configuration nobody meant to have, and a check that throws on one
    -- reports nothing at all — it takes the resource down before it can
    -- say what is wrong, which is the worst way to learn about a missing
    -- setting. Defaults above should mean it never comes to this.
    if (tonumber(Config.Immunity.MinTargetPlaytimeHours) or 0) > 0
        and not (Config.Immunity.PlaytimeProvider and Config.Immunity.PlaytimeProvider.resource) then
        warn[#warn + 1] = ('Immunity.MinTargetPlaytimeHours is %d but no PlaytimeProvider is set; ' ..
            'the rule applies only where QBox metadata carries a playtime figure')
            :format(Config.Immunity.MinTargetPlaytimeHours)
    end

    if not Config.Kidnap.RequireCoercion then
        warn[#warn + 1] = 'Kidnap.RequireCoercion is off: a target can be "delivered" while walking freely'
    end

    if Config.Advisory.Enabled
        and not next(Config.Advisory.RecipientJobTypes or {})
        and not next(Config.Advisory.RecipientJobNames or {}) then
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
--------------------------------------------------------------------------
-- Integration report (§4.2 of the improvements document)
--------------------------------------------------------------------------

--- Every optional integration, where it is configured, and what stops
--- working without it. Built from config rather than hard-coded names, so
--- renaming a resource in the config is reflected here.
local function optionalIntegrations()
    local out = {}

    local function add(resource, purpose, configured)
        if not resource then return end
        out[#out + 1] = {
            resource = resource, purpose = purpose,
            -- `configured` distinguishes "the operator asked for this and it
            -- is missing" from "this is simply not installed", which are
            -- very different startup messages.
            configured = configured ~= false,
        }
    end

    for _, provider in ipairs(Config.Completion.DeathStateProviders or {}) do
        add(provider.resource, 'true-death checks for eliminations', false)
    end

    add(Config.Kidnap.RestraintProvider and Config.Kidnap.RestraintProvider.resource,
        'custom restraint detection for handovers')
    add(Config.Immunity.PlaytimeProvider and Config.Immunity.PlaytimeProvider.resource,
        'playtime for the new-player immunity rule')

    if Config.Progression.Enabled then
        add(Config.Progression.Resource, 'reputation credit for finished contracts')
    end
    if Config.Advisory.UseDispatch then
        add('sc-dispatch', 'threat advisories in the MDT')
    end
    if Config.Relay.Enabled and Config.Relay.AllowMaskedCalls
        and Config.Relay.CallExport and Config.Relay.CallExport.resource then
        add(Config.Relay.CallExport.resource, 'placing masked calls between parties')
    end
    -- Headshots have no enable switch: without a renderer the board simply
    -- shows no faces, which is a degradation rather than a failure.
    add('MugShotBase64', 'target headshots on the board', false)

    return out
end

--- Say what was found and what was not. An integration that is silently
--- absent is the worst case: progression simply stops crediting and nothing
--- anywhere says why.
local function reportIntegrations()
    local integrations = optionalIntegrations()
    if #integrations == 0 then
        print('[crimson-bounty] no optional integrations configured')
        return integrations
    end

    -- One provider list can name several alternatives, only one of which
    -- needs to be present, so the death-state group is summarised together.
    local deathFound = false
    for _, entry in ipairs(integrations) do
        local found = GetResourceState(entry.resource) == 'started'
        if found and entry.purpose:find('true%-death') then deathFound = true end

        print(('[crimson-bounty] integration %-16s %s  (%s)'):format(
            entry.resource, found and 'found' or 'not found', entry.purpose))

        -- Only a resource the operator actually named is worth a warning.
        -- The alternatives in a provider list are not each expected.
        if not found and entry.configured then
            print(('[crimson-bounty] warning: %s is configured but not started; %s will not work')
                :format(entry.resource, entry.purpose))
        end
    end

    if not deathFound then
        print('[crimson-bounty] warning: no death-state provider is running; ' ..
            'eliminations fall back to QBox metadata for the downed check')
    end

    -- Which ox_inventory read this build answers. An item picker that comes
    -- up empty is the symptom operators actually report, and until this
    -- line existed there was no way to tell an empty pocket from an export
    -- that was never there.
    local app = require('server.app')
    local online = modules.identity and modules.identity.online() or {}
    local read = app.probeInventory(online[1])
    if read == nil then
        print('[crimson-bounty] inventory read: nobody online to probe with; '
            .. 'it is checked again the first time someone opens the app')
    elseif read == false then
        print('[crimson-bounty] warning: no ox_inventory read on this build answered. '
            .. 'Items and weapons cannot be offered as rewards; money still works. '
            .. 'The app says so on the form rather than showing an empty picker.')
    else
        print(('[crimson-bounty] inventory read: %s'):format(read))
    end

    -- The roster setting is the other one whose failure looks like nothing
    -- at all: browsing off is an empty list, which reads as broken.
    print(('[crimson-bounty] target browsing: %s, nearby: %s')
        :format(Config.Targeting.AllowBrowseAll and 'everyone online' or 'off',
                Config.Targeting.AllowNearby and 'on' or 'off'))

    return integrations
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
    local mugshot    = require('server.mugshot')
    local progression = require('server.progression')
    local admin      = require('server.admin')
    local projection = require('server.projection')
    local app        = require('server.app')

    audit.init(Storage)
    notify.init({ identity = identity })
    escrow.init(Storage, audit)
    progression.init({ storage = Storage, identity = identity, audit = audit })
    contracts.init({ storage = Storage, escrow = escrow, identity = identity,
                     audit = audit, notify = notify, progression = progression,
                     death = death })
    ledger.init(Storage)
    death.init({ storage = Storage, identity = identity, contracts = contracts, audit = audit })
    photo.init({ storage = Storage, identity = identity, contracts = contracts, audit = audit,
                 death = death, notify = notify, ledger = ledger })
    kidnap.init({ storage = Storage, identity = identity, contracts = contracts,
                  audit = audit, notify = notify, ledger = ledger })
    bailout.init({ storage = Storage, identity = identity, contracts = contracts,
                   escrow = escrow, audit = audit, notify = notify, kidnap = kidnap })
    informant.init({ storage = Storage, identity = identity, audit = audit, death = death })
    amendments.init({ storage = Storage, identity = identity, contracts = contracts,
                      escrow = escrow, audit = audit, notify = notify })
    comms.init({ storage = Storage, identity = identity, audit = audit,
                 notify = notify, ratelimit = ratelimit })
    mugshot.init({ identity = identity, audit = audit })
    projection.init({ storage = Storage, identity = identity, escrow = escrow,
                      kidnap = kidnap, mugshot = mugshot, progression = progression })

    modules = {
        storage = Storage, identity = identity, ratelimit = ratelimit, audit = audit,
        notify = notify, escrow = escrow, contracts = contracts, ledger = ledger,
        death = death, photo = photo, kidnap = kidnap, bailout = bailout,
        informant = informant, amendments = amendments, comms = comms,
        projection = projection, mugshot = mugshot, progression = progression,
        app = app, admin = admin,
        -- The expiry pass owns these; the bridge and contracts call them so
        -- it knows when a skip is no longer safe.
        scheduler = {
            presenceChanged = MarkPresenceChanged,
            contractsChanged = MarkContractsChanged,
        },
    }

    app.init(modules)
    admin.init(modules)
    require('server.bridges').install(modules)

    -- Its own clock, faster than the maintenance tick: attribution is only
    -- as precise as the last condition sample.
    death.startSampler()

    Recover()
    amendments.reindex()
    StartTick()

    reportIntegrations()
    -- Loudly, and every boot, until somebody deals with it. This is what
    -- refusing to start used to buy — the operator's attention — bought
    -- without taking the whole resource down to get it.
    local held = Storage.quarantined and Storage.quarantined() or {}
    if #held > 0 then
        print('[crimson-bounty] ============================================')
        print(('[crimson-bounty] %d CONTRACT(S) COULD NOT BE LOADED and are not '
            .. 'on the board:'):format(#held))
        for i = 1, #held do
            print(('[crimson-bounty]   %s  (%s)  %s')
                :format(held[i].id, held[i].reason, tostring(held[i].file)))
        end
        print('[crimson-bounty]   Each held escrow that cannot now be returned '
            .. 'automatically.')
        print('[crimson-bounty]   Restore those files from a backup and restart to '
            .. 'recover them,')
        print('[crimson-bounty]   or settle them by hand and remove their ids from '
            .. 'data/store.json.')
        print('[crimson-bounty]   This resource started without them rather than '
            .. 'not at all.')
        print('[crimson-bounty] ============================================')
    end

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
                -- Claimed but never settled. The server stopped between
                -- handing the money over and recording that it had, so we
                -- cannot know which happened.
                --
                -- The line is returned to `held` so it is owed rather than
                -- stuck forever. That is the deliberate trade: the window is
                -- a few instructions wide, and a line left `releasing` is
                -- money no code path can ever reach again. Every one of
                -- these is logged with everything staff need to check it.
                Storage.claimEscrowLine(lines[j].id, CB.ESCROW_STATE.RELEASING, CB.ESCROW_STATE.HELD)
                unstuck = unstuck + 1
                print(('[crimson-bounty] escrow line %s was mid-release at shutdown; ' ..
                       'returned to held — verify it was not already paid')
                       :format(tostring(lines[j].id)))
                if modules.audit then
                    modules.audit.financial('release_interrupted', lines[j].releasing_to,
                        contract.id, { line = lines[j].id, amount = lines[j].amount,
                                       review = true })
                end
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
            Wait(Config.Audit.FlushIntervalMs or 10000)
            local ok, err = pcall(Tick)
            if not ok then print('[crimson-bounty] tick error: ' .. tostring(err)) end
        end
    end)
end

--- When the photo host allowlist was last re-read. Not every tick: it is a
--- cross-resource config read, and an upload provider changes about as often
--- as anything else in a server config.
local lastHostRefresh = 0

--- Run one maintenance job, and report rather than abandon the rest.
---
--- These used to run as one statement after another. A throw in any of them
--- skipped every job below it — including the storage flush, which is last,
--- so a single bad row meant nothing was persisted at all. And because the
--- thing that threw was usually still there next tick, it kept skipping them
--- for the life of the process while the resource looked healthy.
---
--- Each job stands alone now. One that fails says so, on every tick, and the
--- others still run.
local function job(name, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        print(('[crimson-bounty] maintenance job %q failed: %s'):format(name, tostring(err)))
    end
    return ok
end

function Tick()
    job('audit.flush', modules.audit.flush)
    job('amendments.expire', modules.amendments.expire)
    job('bailout.processQueue', modules.bailout.processQueue)
    job('photo.sweep', modules.photo.sweep)

    local now = os.time()
    if now - lastHostRefresh >= (Config.Completion.PhotoHostRefreshSeconds or 300) then
        -- Marked done whether or not the read succeeds: retrying a
        -- cross-resource config read every ten seconds because it failed
        -- once is how one broken export becomes a busy loop.
        lastHostRefresh = now
        job('photo.loadAllowedHosts', modules.photo.loadAllowedHosts)
    end
    job('death.sweep', modules.death.sweep)
    job('ratelimit.sweep', modules.ratelimit.sweep)
    if Storage.prune then job('storage.prune', Storage.prune) end
    job('ledger.forgetOldPhotos', modules.ledger.forgetOldPhotos)
    local app = require('server.app')
    -- Who may have the app on their phone. Recomputed here rather than
    -- trusted to a job-change event whose name has differed across
    -- framework versions: a wrong name fails silently in the direction that
    -- costs a player the app with no way to ask for it back.
    local bridges = require('server.bridges')
    if bridges.refreshAccess then job('bridges.refreshAccess', bridges.refreshAccess) end
    job('app.sweepHandles', app.sweepHandles)
    job('app.sweepFloodCounters', app.sweepFloodCounters)
    job('expireContracts', ExpireContracts)
    -- Last, and the one every other job used to stand in front of.
    if Storage.flush then job('storage.flush', Storage.flush) end
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
--- The earliest moment any live contract could need attention, and whether
--- a player has come or gone since the last pass.
---
--- The pass itself is unchanged — pause bookkeeping depends on who is
--- online, so it genuinely has to look at every live contract when presence
--- changes. What changed is how often that happens: with nobody connecting
--- or disconnecting and no deadline due, there is nothing a pass could
--- discover, so it is skipped entirely rather than reading the whole
--- contract table every ten seconds forever.
local nextDue = 0
local presenceChanged = true

--- Called from the connection bridge. A player arriving or leaving is the
--- only thing besides the clock that can change a contract's pause state.
function MarkPresenceChanged()
    presenceChanged = true
end

--- Called when a contract is created or resolved: either can move the
--- earliest deadline, and a new contract must not wait out a skip.
function MarkContractsChanged()
    nextDue = 0
end

function ExpireContracts()
    local now = os.time()
    if not presenceChanged and now < nextDue then return 0 end
    presenceChanged = false

    local contracts = Storage.allContracts()
    local resolved = 0

    -- The soonest future moment worth waking for. Starts far out and is
    -- pulled in by every live contract's deadline.
    local soonest = now + (Config.Limits.MaxDeadlineSkipSeconds or 600)

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
                    elseif contract.deadline_at and contract.deadline_at < soonest then
                        soonest = contract.deadline_at
                    end
                end

                -- A paused contract's deadline is not running, but its
                -- absolute lifetime is.
                if contract.expires_at and contract.expires_at < soonest then
                    soonest = contract.expires_at
                end
            end
        end
    end

    -- One second past the earliest deadline, so the pass that wakes for it
    -- finds it genuinely overdue rather than exactly due.
    nextDue = soonest + 1
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
                -- Stakes belong to the hunters who put them up, and an
                -- unfiltered release deliberately skips them — so they are
                -- returned explicitly here rather than destroyed with the
                -- tables.
                local hunters = Storage.readHunters(c.id)
                for j = 1, #hunters do
                    modules.escrow.release(c.id, hunters[j].hunter_cid,
                        { portion = CB.PORTION.STAKE, staker = hunters[j].hunter_cid },
                        'resource_stopping')
                end
                modules.escrow.release(c.id, c.creator_cid, nil, 'resource_stopping')
            end
        end
    end

    if Storage and Storage.close then Storage.close() end
end)

return {
    start = StartCrimsonBounty, recover = Recover, tick = Tick, expire = ExpireContracts,
    -- The expiry pass skips itself when nothing could have changed. These
    -- are how it is told that something did.
    markPresenceChanged = MarkPresenceChanged,
    markContractsChanged = MarkContractsChanged,
    -- Exposed so the suite can assert on what the report covers rather than
    -- on printed output.
    integrations = optionalIntegrations, reportIntegrations = reportIntegrations,
    -- Exposed so a test can strip a setting, fill the defaults, and check
    -- the handlers still run. Which keys must be filled is not evident from
    -- DEFAULTS on its own: what matters is which ones the code indexes
    -- without checking, and that is only provable by removing one and
    -- watching what breaks.
    applyConfigDefaults = applyConfigDefaults, configDefaults = DEFAULTS,
    -- Exposed for the same reason: a setting that is silently corrected has
    -- to be provable, not taken on trust.
    validateConfig = validateConfig,
}
