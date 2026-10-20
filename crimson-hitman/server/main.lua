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
        AllowNearby = false,
        NearbyRadius = 30.0,
        MaxNearby = 12,
        NearbyClosedAfterSeconds = 1800,
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
    --- Contract retention, added long after Config.Audit itself.
    ---
    --- The whole-section fill above does not reach this: an operator who has
    --- an Audit section — which is every operator who ever edited their
    --- config — keeps the section they wrote, and a key added to it later is
    --- simply absent. Absent reads as off here, so without this entry
    --- nothing prunes contracts on any upgraded server and every full scan
    --- goes on growing with the server's whole history, which is the thing
    --- retention was added to stop.
    Audit = {
        ContractRetentionDays = 30,
        ContractsPrunedPerTick = 200,
        -- Missing, it was read as below the floor and held to one second:
        -- every maintenance job, the prune among them, ten times as often.
        FlushIntervalMs = 10000,
    },
    Cooldowns = {
        -- Split out of one shared bucket. On a config that predates the
        -- split these are absent, and an absent rule is not a licence to
        -- act — RateLimit falls back to a conservative one — but the app
        -- deserves the allowance it was built against.
        load   = { per = 10, burst = 20 },
        search = { per = 10, burst = 15 },
        wallet = { per = 10, burst = 8 },
        -- The kill photo's one view, which no config before it names. The
        -- fallback rule would answer, but the one view deserves the
        -- allowance it was built against, as the three above do.
        photoView   = { per = 10, burst = 5 },
        photoDecide = { per = 5, burst = 5 },
    },
    --- The names the admin commands register under. Indexed directly while
    --- registering them, so a config carrying an Admin section without this
    --- key took the resource down at boot — including ch-diag, which is the
    --- one command an operator needs in order to find out why.
    Admin = {
        Commands = {
            timeline = 'ch-timeline',
            void     = 'ch-void',
            stuck    = 'ch-stuck',
            settle   = 'ch-settle',
            whois    = 'ch-whois',
            contracts = 'ch-contracts',
            diagnose = 'ch-diag',
        },
    },
    Immunity = {
        MinTargetPlaytimeHours = 5,
        MinTargetSessionMinutes = 10,
    },
    --- The safety switches. Each was added to a section operators already
    --- had, and each is read as a plain truth test, so on a config taken
    --- before it the protection was simply off: a victim's client naming any
    --- hitman as the killer with no damage observed, a stake repriced
    --- between the board and Accept, an informant naming hitmen never near
    --- the target. A switch the operator never had is not one they turned
    --- off; one they set to false stays false.
    Completion = {
        RequireObservedDamage = true,
        RejectLastStand = true,
        --- Where kill photos are kept, and how long one stays open. Absent
        --- on a config from before the client's one view existed; the
        --- storage is checked below, the open time read by the tick.
        PhotoStorage = 'server',
        PhotoOpenSeconds = 600,
        --- How big a photo kept on this server may be. Absent on the same
        --- configs, and read on every photo sent; checked below.
        PhotoMaxSide = 1280,
        PhotoMaxBytes = 600000,
        -- PhotoPublicUrl and KeptPhotoDays are absent too, and nothing is
        -- filled for them: absent is their default (web_baseUrl; kept until
        -- deleted). Checked below.
        --- A list, so filled whole or not at all: see isRecord.
        DeathStateProviders = {
            { resource = 'sc-ambulance', dead = 'IsDead', lastStand = 'IsLaststand' },
            { resource = 'qbx_medical',  dead = 'IsDead', lastStand = 'IsLaststand' },
        },
    },
    Penalty = {
        RequireDisclosureOnAccept = true,
        MinWindowMinutes = 30,
    },
    Bailout = {
        BlockWhileIncapacitated = true,
    },
    --- Added to a section every config has. Absent read as 0, which is off:
    --- on every upgraded server an exclusive contract could still be held
    --- by somebody who never went near the target.
    Limits = {
        ExclusiveIdleReleaseSeconds = 1800,
        ExclusiveAttemptWindowSeconds = 7200,
        -- Absent read as off, and a jailed target's deadline ran on through
        -- the sentence on every server that upgraded.
        PauseWhileTargetJailed = true,
        JailZone = { x = 1693.3, y = 2569.5, radius = 300 },
    },
    --- Absent read as off, and an anonymous client calling a named operative
    --- on a phone that cannot mask was dialled from their own number.
    Relay = {
        RequireMaskingForAnonymous = true,
        -- Absent, a thread kept every message ever sent to it.
        MaxMessagesPerThread = 100,
    },
    --- Owed deliveries tried per pass. Read inside the login timer, where a
    --- nil is a comparison that throws with nobody to see it.
    PendingEscrow = {
        MaxRetriesPerLogin = 5,
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
        PushEnabled = true,
        -- Absent, the alert went the second the contract was placed.
        ParanoidAlertJitter = { min = 60, max = 600 },
        ParanoidCooldownMinutes = 30,
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
        RequireProximity = true,
    },
    --- Compared against a count in Kidnap.arm, so a missing one is not a
    --- disabled cap but a comparison against nil: every attempt to start a
    --- live delivery answers server_error.
    Kidnap = {
        MaxConcurrentCountdowns = 20,
        Radius = 12.0,
        TickMs = 1000,
        RequireConscious = true,
        RejectDead = true,
        RejectLastStand = true,
        RequireCoercion = true,
        --- Absent, every detector reads as off, and with coercion required
        --- no delivery could ever succeed — silently. A set, so an operator
        --- who has one keeps exactly the detectors they left in it.
        Coercion = {
            handcuffed = true,
            passengerOfHitman = true,
        },
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
    --- target picker rather than merely switching an advisory off. The
    --- recipient sets are also read by the boot validation itself: absent,
    --- they crashed the check that would have reported a misconfigured
    --- advisory.
    ---
    --- One entry. There were two in this constructor, and Lua keeps only the
    --- last of a repeated key, so anything added to the first was silently
    --- never filled.
    Advisory = {
        AlwaysAlertTarget = true,
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
    --- A whole section a config from before it had is filled from
    --- defaults.lua; this fills the key in one that has the section.
    Diagnostics = {
        SlowJobMs = 5,
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

--- Whether a default is a record whose missing fields can be filled one by
--- one, rather than a set or a list the operator owns whole.
---
--- A record's fields are separate settings: an item source with no
--- maxPerStack is a gap. A set's entries are a choice: an operator who took
--- ems out of the jobs that trigger an advisory, or a detector out of
--- Kidnap.Coercion, had it put straight back by a fill that topped up every
--- table, and a list was topped up by position — a denylist of two patterns
--- came back with the shipped third and fourth appended.
local function isRecord(value)
    if type(value) ~= 'table' or #value > 0 then return false end
    for _, v in pairs(value) do
        if v ~= true then return true end
    end
    return false
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

            elseif isRecord(value) and type(held) == 'table' then
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
        print(('[crimson-hitman] your config.lua does not set %d setting(s); the shipped '
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
        { 'Limits', 'MaxAcceptedPerHitman' },
        { 'Limits', 'MaxActiveContractsPerTarget' },
        { 'Limits', 'MaxHitmenPerContract' },
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
        -- Squared for every Arm, and the countdown thread's own wait and
        -- delta: a string here stopped every handover rather than one.
        { 'Kidnap', 'Radius' },
        { 'Kidnap', 'TickMs' },
        -- Compared against elapsed seconds on every idle-hold sweep.
        { 'Limits', 'ExclusiveIdleReleaseSeconds' },
        { 'Limits', 'ExclusiveAttemptWindowSeconds' },
        -- Compared on every create and every payout.
        { 'Immunity', 'MinTargetSessionMinutes' },
        -- Inside the login timer.
        { 'PendingEscrow', 'MaxRetriesPerLogin' },
        { 'Audit', 'MaxQueueSize' },
        { 'Audit', 'RetentionDays' },
        { 'Audit', 'ContractRetentionDays' },
        { 'Audit', 'ContractsPrunedPerTick' },
        -- Both go straight into math.min on every contract creation.
        { 'Penalty', 'MaxAmount' },
        { 'Penalty', 'MaxFractionOfEscrow' },
        { 'Penalty', 'MinWindowMinutes' },
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
            print('[crimson-hitman] FATAL: ' .. message)
        end
        error('[crimson-hitman] refusing to start on an invalid configuration')
    end

    local mode = Config.Database.Mode
    if mode ~= 'mysql' and mode ~= 'json' and mode ~= 'memory' then
        fatal[#fatal + 1] = ('Config.Database.Mode is "%s"; expected mysql, json or memory'):format(tostring(mode))
    end
    -- Only true lets a start past money another mode still holds (see
    -- refuseModeSwitch). Anything else, a string 'true' included, is the
    -- refusal, which is the safe way to misread it; said so here.
    local allowSwitch = Config.Database.AllowModeSwitch
    if allowSwitch ~= nil and type(allowSwitch) ~= 'boolean' then
        warn[#warn + 1] = ('Config.Database.AllowModeSwitch is %s, not true or false; it is read '
            .. 'as false'):format(tostring(allowSwitch))
    end
    -- Read by every player's game, not here, as a plain `== true`: a
    -- string 'true' leaves the app in the App Store with nothing to say
    -- why. Nothing is filled for an App section without it, since absent
    -- is the shipped false on both sides.
    local installed = Config.App and Config.App.DefaultInstalled
    if installed ~= nil and type(installed) ~= 'boolean' then
        warn[#warn + 1] = ('Config.App.DefaultInstalled is %s, not true or false; players\' '
            .. 'phones read it as false and the app stays in the App Store')
            :format(tostring(installed))
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

    -- A deadline past the lifetime is one that never arrives: the contract
    -- ends on its lifetime instead, and a lifetime ending hands the stake
    -- back, so the penalty a hitman agreed to could never be taken.
    if Config.Limits.DefaultDeadlineSeconds > Config.Limits.ContractLifetimeSeconds then
        warn[#warn + 1] = ('Limits.DefaultDeadlineSeconds (%d) is longer than '
            .. 'ContractLifetimeSeconds (%d); a contract would end on its lifetime '
            .. 'before its deadline and no stake could ever be forfeited. Using the lifetime.')
            :format(Config.Limits.DefaultDeadlineSeconds, Config.Limits.ContractLifetimeSeconds)
        Config.Limits.DefaultDeadlineSeconds = Config.Limits.ContractLifetimeSeconds
    end

    -- The interval drives the whole maintenance tick, not only the audit
    -- flush: at 0 the tick, a database prune included, ran every frame.
    local flushMs = tonumber(Config.Audit.FlushIntervalMs)
    if not flushMs then
        warn[#warn + 1] = ('Audit.FlushIntervalMs is %s, not a number of milliseconds; '
            .. 'using 10000.'):format(tostring(Config.Audit.FlushIntervalMs))
        Config.Audit.FlushIntervalMs = 10000
    elseif flushMs < 1000 then
        warn[#warn + 1] = ('Audit.FlushIntervalMs is %s; it paces every maintenance job '
            .. 'including the database prune, so it is held to at least 1000.')
            :format(tostring(Config.Audit.FlushIntervalMs))
        Config.Audit.FlushIntervalMs = 1000
    else
        Config.Audit.FlushIntervalMs = flushMs
    end

    -- Where kill photos are kept. A misspelling is not a third place: it
    -- is read as the default, and said so, rather than left to fail the
    -- first time somebody photographs a body.
    local photoStorage = Config.Completion.PhotoStorage
    if photoStorage ~= 'server' and photoStorage ~= 'host' then
        warn[#warn + 1] = ('Completion.PhotoStorage is %s; it has to be \'server\' or '
            .. '\'host\'. Using \'server\'.'):format(type(photoStorage) == 'string'
                and ('"' .. photoStorage .. '"') or tostring(photoStorage))
        Config.Completion.PhotoStorage = 'server'
    end

    -- How big a photo kept on this server may be: the longest side the page
    -- shrinks it to, and the most it may weigh once decoded. Whole numbers
    -- above a floor, because the page draws to this many pixels and a
    -- photo of a body forty pixels across proves nothing; and a ceiling on
    -- the bytes, because each one is sent whole to the server and back out
    -- to the client's phone. 1500000, not the 4000000 it was: FXServer moves
    -- a latent event at about 150 KB a second, so a photo that size took
    -- over half a minute each way, close to the minute either end waits for
    -- it, and half a second of the server's main thread to decode or encode.
    local function photoLimit(key, default, floor, ceiling)
        local value = tonumber(Config.Completion[key])
        if not value or value ~= value or value < floor or value > ceiling then
            warn[#warn + 1] = ('Completion.%s is %s; it has to be a number from %d to %d. '
                .. 'Using %d.'):format(key, tostring(Config.Completion[key]), floor, ceiling, default)
            value = default
        end
        Config.Completion[key] = math.floor(value)
    end
    photoLimit('PhotoMaxSide', 1280, 320, 4096)
    photoLimit('PhotoMaxBytes', 600000, 50000, 1500000)

    -- How long an opened kill photo waits for Save or Delete. Read on every
    -- tick; zero or less would delete a photo the moment it was opened.
    local openFor = tonumber(Config.Completion.PhotoOpenSeconds)
    if not openFor or openFor <= 0 then
        warn[#warn + 1] = ('Completion.PhotoOpenSeconds is %s, not a number of seconds above '
            .. 'zero; using 600.'):format(tostring(Config.Completion.PhotoOpenSeconds))
        Config.Completion.PhotoOpenSeconds = 600
    else
        Config.Completion.PhotoOpenSeconds = openFor
    end

    -- The public address photos kept on this server are saved to a phone's
    -- Photos from. Unset is the default (web_baseUrl is used); anything
    -- else must be an https:// address the phone can load, and one that is
    -- not is dropped here, with the reason, rather than handed to phones as
    -- links that lead nowhere.
    local publicUrl = Config.Completion.PhotoPublicUrl
    if publicUrl ~= nil and publicUrl ~= '' then
        local checked = require('server.photos').checkBase(publicUrl)
        if not checked then
            warn[#warn + 1] = ('Completion.PhotoPublicUrl is %s; it has to be an https:// '
                .. 'address such as \'https://photos.example.com/crimson-hitman\', with no '
                .. 'query. Ignoring it.'):format(type(publicUrl) == 'string'
                    and ('"' .. publicUrl .. '"') or tostring(publicUrl))
            Config.Completion.PhotoPublicUrl = nil
        else
            Config.Completion.PhotoPublicUrl = checked
        end
    end

    -- How long a photo kept in the app lasts. Unset keeps it until its
    -- owner deletes it; a number of days must be above zero, since zero
    -- would delete every kept photo on the next tick.
    local keptDays = Config.Completion.KeptPhotoDays
    if keptDays ~= nil then
        local days = tonumber(keptDays)
        if not days or days ~= days or days <= 0 then
            warn[#warn + 1] = ('Completion.KeptPhotoDays is %s, not a number of days above '
                .. 'zero; photos kept in the app are kept until their owner deletes them.')
                :format(tostring(keptDays))
            Config.Completion.KeptPhotoDays = nil
        else
            Config.Completion.KeptPhotoDays = days
        end
    end

    -- How slow a maintenance job may be before the console hears about it.
    -- 0 turns the warning off; /ch-diag still lists the slowest jobs.
    local slowMs = tonumber(Config.Diagnostics.SlowJobMs)
    if not slowMs or slowMs ~= slowMs or slowMs < 0 then
        warn[#warn + 1] = ('Diagnostics.SlowJobMs is %s, not a number of milliseconds (0 for '
            .. 'no warning); using 5.'):format(tostring(Config.Diagnostics.SlowJobMs))
        slowMs = 5
    end
    Config.Diagnostics.SlowJobMs = slowMs

    if Config.Audit.MaxQueueSize < 1 then
        warn[#warn + 1] = 'Audit.MaxQueueSize is below 1; the queue holds at least one row.'
    end
    if Config.Audit.RetentionDays < 0 then
        warn[#warn + 1] = 'Audit.RetentionDays is negative; the audit log is kept forever.'
    end

    -- Every rate-limit rule is a table of a positive `per` and a `burst` of
    -- at least one. A rule missing `burst` threw inside the net event, before
    -- the handler's own guard, so every request in that bucket went
    -- unanswered and the page waited fifteen seconds each time.
    for name, rule in pairs(Config.Cooldowns or {}) do
        local good = type(rule) == 'table'
            and type(rule.per) == 'number' and rule.per > 0
            and type(rule.burst) == 'number' and rule.burst >= 1
        if not good then
            warn[#warn + 1] = ('Cooldowns.%s is not { per = <seconds above 0>, burst = <1 or '
                .. 'more> }; using the fallback rule for it.'):format(tostring(name))
            Config.Cooldowns[name] = { per = 10, burst = 10 }
        end
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
        if holder and value ~= nil and not CH.MONEY_ACCOUNTS[value] then
            holder[named.key] = 'bank'
            warn[#warn + 1] = ('%s is "%s", which is not an account this '
                .. 'framework can charge (only cash and bank are; dirty money is '
                .. 'an inventory item). Using bank instead — set it to cash or '
                .. 'bank to choose')
                :format(named.label, tostring(value))
        end
    end

    -- A staff webhook left in config.lua by an older version. That file is
    -- a shared script, so every player's game has downloaded the URL, and
    -- anyone holding it can post into the staff channel or delete the hook.
    -- It is not used: the URL is already out, and carrying on with it would
    -- hide that. The webhook is the crimson_hitman_webhook convar now.
    --
    -- Read through the section, not by its full path: the key is gone from
    -- the shipped config on purpose, and the static check holds every
    -- full-path read to a key the shipped config defines.
    local audit = Config.Audit
    if type(audit.Webhook) == 'string' and audit.Webhook ~= '' then
        warn[#warn + 1] = 'Audit.Webhook is set in config/config.lua, which every '
            .. 'player\'s game downloads, so that URL is exposed and is not used. '
            .. 'Delete or regenerate the webhook in Discord, remove it from '
            .. 'config.lua, and put the new one in server.cfg as: set '
            .. 'crimson_hitman_webhook "<url>" (set, never setr: setr sends it to '
            .. 'every player too)'
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
    --
    -- A provider in the wrong shape was a silent no-op: a table with no
    -- export failed inside a pcall on every contract and fell back to
    -- metadata, and a bare string read as no provider at all. A number
    -- threw here and on every contract placed. It is dropped with a word,
    -- which is what it was doing anyway, without the silence.
    local provider = Config.Immunity.PlaytimeProvider
    if provider ~= nil and not (type(provider) == 'table'
        and type(provider.resource) == 'string' and provider.resource ~= ''
        and type(provider.export) == 'string' and provider.export ~= '') then
        warn[#warn + 1] = ('Immunity.PlaytimeProvider has to be { resource = '
            .. '\'<resource>\', export = \'<function>\' }, an export returning total '
            .. 'minutes played; it is %s, so it is ignored and playtime is read '
            .. 'from QBox metadata'):format(type(provider) == 'table'
                and 'missing its resource or export' or ('a ' .. type(provider)))
        Config.Immunity.PlaytimeProvider = nil
    end

    -- The restraint provider is a resource name, which is what the coercion
    -- check hands GetResourceState and exports[]. The startup report read it
    -- as a table, the shape the playtime provider takes: written as the
    -- config comment says it was never reported, and written as a table it
    -- reached GetResourceState, which takes a string, on every coercion
    -- check. A table carrying a resource is taken as its name; anything else
    -- is dropped with a word.
    local restraint = Config.Kidnap.RestraintProvider
    if type(restraint) == 'table' and type(restraint.resource) == 'string'
        and restraint.resource ~= '' then
        Config.Kidnap.RestraintProvider = restraint.resource
    elseif restraint ~= nil and not (type(restraint) == 'string' and restraint ~= '') then
        warn[#warn + 1] = ('Kidnap.RestraintProvider has to be the name of a resource '
            .. 'exposing IsRestrained(playerId); it is %s, so it is ignored')
            :format(type(restraint) == 'string' and 'empty' or ('a ' .. type(restraint)))
        Config.Kidnap.RestraintProvider = nil
    end

    if (tonumber(Config.Immunity.MinTargetPlaytimeHours) or 0) > 0
        and not (Config.Immunity.PlaytimeProvider and Config.Immunity.PlaytimeProvider.resource) then
        warn[#warn + 1] = ('Immunity.MinTargetPlaytimeHours is %d but no PlaytimeProvider is set; ' ..
            'the rule applies only where QBox metadata carries a playtime figure')
            :format(Config.Immunity.MinTargetPlaytimeHours)
    end

    if not Config.Kidnap.RequireCoercion then
        warn[#warn + 1] = 'Kidnap.RequireCoercion is off: a target can be "delivered" while walking freely'
    end
    -- Two releases with two switches. Turning the idle one off leaves the
    -- attempt window, which an operator who meant "never take a hold away"
    -- would not expect.
    if (Config.Limits.ExclusiveIdleReleaseSeconds or 0) <= 0
        and (Config.Limits.ExclusiveAttemptWindowSeconds or 0) > 0 then
        warn[#warn + 1] = ('Limits.ExclusiveIdleReleaseSeconds is off, but a hitman who holds an '
            .. 'exclusive contract without an attempt is still released after %d s '
            .. '(Limits.ExclusiveAttemptWindowSeconds; 0 turns that off too)')
            :format(Config.Limits.ExclusiveAttemptWindowSeconds)
    end
    -- Shipped on until it was found to name anonymous parties, so a config
    -- taken before then still has it on, and an operator who has never read
    -- the comment has no reason to look.
    if Config.Targeting.AllowNearby == true then
        warn[#warn + 1] = ('Targeting.AllowNearby is on: any player with the app can list the names '
            .. 'of the unmasked people within %s m of them, through walls. Read its comment in '
            .. 'config.lua before leaving it on'):format(tostring(Config.Targeting.NearbyRadius))
    end
    if Config.Relay.RequireMaskingForAnonymous == false then
        warn[#warn + 1] = 'Relay.RequireMaskingForAnonymous is off: on a phone that cannot hide '
            .. 'caller id, an anonymous party\'s calls are placed from their own number'
    end

    if Config.Advisory.Enabled
        and not next(Config.Advisory.RecipientJobTypes or {})
        and not next(Config.Advisory.RecipientJobNames or {}) then
        warn[#warn + 1] = 'Advisory is enabled but nobody is configured to receive it'
    end

    for _, message in ipairs(warn) do
        print('[crimson-hitman] warning: ' .. message)
    end
    if #fatal > 0 then
        for _, message in ipairs(fatal) do
            print('[crimson-hitman] FATAL: ' .. message)
        end
        error('[crimson-hitman] refusing to start on an invalid configuration')
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

--- Refuse to start where another storage mode still holds players' money.
---
--- Modes do not share data. A server switched from json to mysql (which the
--- json store itself suggests once it is busy), or tried on memory for a
--- test, started with an empty store: every open contract was invisible,
--- the escrow taken for it with it — cash, bank, dirty money, items,
--- weapons — and every payout owed to a player who was offline. Nothing
--- returned any of it and nothing said so. Switching back found it all
--- again, after staff had refunded by hand what they could, so it was paid
--- twice.
---
--- Only money stops the start: escrow not yet settled, or a payout queued
--- for somebody offline. A store holding finished history is left as it
--- is and mentioned once. Config.Database.AllowModeSwitch = true starts
--- anyway.
local function refuseModeSwitch()
    local mode = Config.Database.Mode
    local found = {}

    if mode ~= 'json' then
        local ok, held = pcall(require('server.storage.json').inspect)
        if ok and held then
            if held.lines > 0 or held.owed > 0 or held.unreadable then
                found[#found + 1] = held.unreadable
                    and ('json mode: %s/store.json, which cannot be read')
                        :format(Config.Database.Json.Directory or 'data')
                    or ('json mode: %d escrow line(s) and %d payout(s) owed, in %s/')
                        :format(held.lines, held.owed, Config.Database.Json.Directory or 'data')
            elseif held.contracts > 0 then
                print(('[crimson-hitman] %s/store.json still names %d finished contract(s) from '
                    .. 'json mode. They hold no money and %s mode does not read them.')
                    :format(Config.Database.Json.Directory or 'data', held.contracts, mode))
            end
        end
    end

    -- Only where oxmysql is running: a json server without a database has
    -- nothing there to find, and asking would wait on a connection forever.
    if mode ~= 'mysql' and GetResourceState('oxmysql') == 'started' and MySQL then
        local ok, held = pcall(require('server.storage.mysql').inspect)
        if ok and held and (held.lines > 0 or held.owed > 0) then
            found[#found + 1] = ('mysql mode: %d escrow line(s) and %d payout(s) owed, in the '
                .. 'crimson_* tables'):format(held.lines, held.owed)
        end
    end

    if #found == 0 then return end
    if Config.Database.AllowModeSwitch == true then
        print(('[crimson-hitman] warning: started in %s mode although %s. '
            .. 'Config.Database.AllowModeSwitch is on, so none of it is visible or returned '
            .. 'from here.'):format(mode, table.concat(found, '; ')))
        return
    end
    error(('[crimson-hitman] Config.Database.Mode is \'%s\', but players\' money is still held by '
        .. 'another mode: %s. Modes do not share data, so started like this every contract '
        .. 'there and the money in it would be invisible, and nothing would return it. '
        .. 'Refusing to start. Switch Mode back and let those contracts finish (or cancel them '
        .. 'in the app), or settle them by hand and move that data out of the way, or set '
        .. 'Config.Database.AllowModeSwitch = true to start anyway.')
        :format(tostring(mode), table.concat(found, '; ')), 0)
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

    -- A resource name (validateConfig takes a table down to one).
    add(Config.Kidnap.RestraintProvider, 'custom restraint detection for handovers')
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
        print('[crimson-hitman] no optional integrations configured')
        return integrations
    end

    -- One provider list can name several alternatives, only one of which
    -- needs to be present, so the death-state group is summarised together.
    local deathFound = false
    for _, entry in ipairs(integrations) do
        local found = GetResourceState(entry.resource) == 'started'
        if found and entry.purpose:find('true%-death') then deathFound = true end

        print(('[crimson-hitman] integration %-16s %s  (%s)'):format(
            entry.resource, found and 'found' or 'not found', entry.purpose))

        -- Only a resource the operator actually named is worth a warning.
        -- The alternatives in a provider list are not each expected.
        if not found and entry.configured then
            print(('[crimson-hitman] warning: %s is configured but not started; %s will not work')
                :format(entry.resource, entry.purpose))
        end
    end

    if not deathFound then
        print('[crimson-hitman] warning: no death-state provider is running; ' ..
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
        print('[crimson-hitman] inventory read: nobody online to probe with; '
            .. 'it is checked again the first time someone opens the app')
    elseif read == false then
        print('[crimson-hitman] warning: no ox_inventory read on this build answered. '
            .. 'Items and weapons cannot be offered as rewards; money still works. '
            .. 'The app says so on the form rather than showing an empty picker.')
    else
        print(('[crimson-hitman] inventory read: %s'):format(read))
    end

    -- The roster setting is the other one whose failure looks like nothing
    -- at all: browsing off is an empty list, which reads as broken.
    print(('[crimson-hitman] target browsing: %s, nearby: %s')
        :format(Config.Targeting.AllowBrowseAll and 'everyone online' or 'off',
                Config.Targeting.AllowNearby and 'on' or 'off'))

    return integrations
end



function StartCrimsonHitman()
    validateConfig()

    refuseModeSwitch()
    Storage = selectStorage()
    Storage.open()

    local identity   = require('server.identity')
    local ratelimit  = require('server.ratelimit')
    local audit      = require('server.audit')
    local notify     = require('server.notify')
    local escrow     = require('server.escrow')
    local contracts  = require('server.contracts')
    local ledger     = require('server.ledger')
    local photos     = require('server.photos')
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
    local timing     = require('server.timing')

    -- A job is charged for the time it holds the thread, not for the time
    -- it waits on the database while everything else runs (Timing.await).
    if Storage.timeWaitsWith then Storage.timeWaitsWith(timing.await) end

    audit.init(Storage)
    notify.init({ identity = identity })
    escrow.init(Storage, audit)
    progression.init({ storage = Storage, identity = identity, audit = audit })
    contracts.init({ storage = Storage, escrow = escrow, identity = identity,
                     audit = audit, notify = notify, progression = progression,
                     death = death })
    photos.init({ storage = Storage, audit = audit })
    ledger.init({ storage = Storage, photos = photos, notify = notify })
    death.init({ storage = Storage, identity = identity, contracts = contracts, audit = audit,
                 timing = timing })
    photo.init({ storage = Storage, identity = identity, contracts = contracts, audit = audit,
                 death = death, notify = notify, ledger = ledger })
    kidnap.init({ storage = Storage, identity = identity, contracts = contracts,
                  audit = audit, notify = notify, ledger = ledger })
    bailout.init({ storage = Storage, identity = identity, contracts = contracts,
                   escrow = escrow, audit = audit, notify = notify, kidnap = kidnap,
                   death = death })
    informant.init({ storage = Storage, identity = identity, audit = audit, death = death })
    amendments.init({ storage = Storage, identity = identity, contracts = contracts,
                      escrow = escrow, audit = audit, notify = notify })
    comms.init({ storage = Storage, identity = identity, audit = audit,
                 notify = notify, ratelimit = ratelimit })
    mugshot.init({ identity = identity, audit = audit })
    projection.init({ storage = Storage, identity = identity, escrow = escrow,
                      kidnap = kidnap, mugshot = mugshot, progression = progression,
                      comms = comms, informant = informant, notify = notify })

    modules = {
        storage = Storage, identity = identity, ratelimit = ratelimit, audit = audit,
        notify = notify, escrow = escrow, contracts = contracts, ledger = ledger,
        death = death, photo = photo, kidnap = kidnap, bailout = bailout,
        informant = informant, amendments = amendments, comms = comms,
        projection = projection, mugshot = mugshot, progression = progression,
        app = app, admin = admin, photos = photos,
        -- How long each tick job and sampler pass takes, for the console
        -- warning and /ch-diag.
        timing = timing,
        -- The expiry pass owns these; the bridge and contracts call them so
        -- it knows when a skip is no longer safe.
        scheduler = {
            presenceChanged = MarkPresenceChanged,
            contractsChanged = MarkContractsChanged,
        },
    }

    -- Nothing is answered until recovery has finished (App.ready).
    app.ready = false
    app.init(modules)
    admin.init(modules)
    require('server.bridges').install(modules)

    -- Its own clock, faster than the maintenance tick: attribution is only
    -- as precise as the last condition sample.
    death.startSampler()

    Recover()
    -- Kill photo files no record names any more. Before the app answers:
    -- a photo is written to its file a moment before its record, and a
    -- sweep that ran alongside a kill being verified would remove that one.
    local swept, sweepErr = pcall(photos.sweepFiles)
    if not swept then
        print(('[crimson-hitman] the sweep of kill photo files failed: %s'):format(tostring(sweepErr)))
    end
    amendments.reindex()
    -- Contracts already held when this process started, so an idle hold
    -- from before a restart is still one the sweep can see.
    contracts.reindexHolds()
    app.ready = true
    StartTick()

    reportIntegrations()
    -- Loudly, and every boot, until somebody deals with it. This is what
    -- refusing to start used to buy — the operator's attention — bought
    -- without taking the whole resource down to get it.
    local held = Storage.quarantined and Storage.quarantined() or {}
    if #held > 0 then
        print('[crimson-hitman] ============================================')
        print(('[crimson-hitman] %d CONTRACT(S) COULD NOT BE LOADED and are not '
            .. 'on the board:'):format(#held))
        for i = 1, #held do
            print(('[crimson-hitman]   %s  (%s)  %s')
                :format(held[i].id, held[i].reason, tostring(held[i].file)))
        end
        print('[crimson-hitman]   Each held escrow that cannot now be returned '
            .. 'automatically.')
        print('[crimson-hitman]   Restore those files from a backup and restart to '
            .. 'recover them,')
        print('[crimson-hitman]   or settle them by hand and remove their ids from '
            .. 'data/store.json.')
        print('[crimson-hitman]   This resource started without them rather than '
            .. 'not at all.')
        print('[crimson-hitman] ============================================')
    end

    print(('[crimson-hitman] started in %s mode'):format(Config.Database.Mode))
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
    local recovered, unstuck, finished, paused = 0, 0, 0, 0

    -- When this process was last known to be running. Every contract's clock
    -- pauses while either party is offline, and while the server is down
    -- everybody is. A contract nobody had paused when the process went away
    -- only started pausing at the first tick after the boot, so the downtime
    -- itself was charged to the deadline — and one that fell due inside it
    -- expired the moment both parties were back, forfeiting the hitman's
    -- stake for a restart. Dated from the last heartbeat instead.
    local now = os.time()
    local lastAlive = Storage.lastHeartbeat and Storage.lastHeartbeat() or nil
    if lastAlive and lastAlive >= now then lastAlive = nil end

    -- The contracts still holding an escrow line that is not settled, in
    -- one read. A finished contract whose lines are all settled has nothing
    -- below to do: every step acts on a live or completing contract, or on
    -- a line held or mid-release. Read for each of them anyway, on mysql
    -- that was some four awaited queries per contract kept (thirty days of
    -- them), with the app answering nobody until they were done.
    local unsettled = Storage.unsettledEscrowContracts and Storage.unsettledEscrowContracts() or nil

    for i = 1, #contracts do
        local contract = contracts[i]
        if unsettled and CH.TERMINAL[contract.state] and not unsettled[contract.id] then
            goto continue
        end

        if lastAlive and not contract.paused_since
            and (contract.state == CH.STATE.ACTIVE or contract.state == CH.STATE.ACCEPTED
                 or contract.state == CH.STATE.COMPLETING) then
            if Storage.startPause(contract.id, lastAlive) then
                contract.paused_since = lastAlive
                paused = paused + 1
            end
        end

        -- Whether anything on this contract was never handed to anybody:
        -- held (or caught mid-claim before a recipient was written), owed
        -- to nobody, and naming nobody it was on its way to.
        local untouched = false

        local lines = Storage.readEscrow(contract.id)
        for j = 1, #lines do
            local line = lines[j]
            if (line.state == CH.ESCROW_STATE.HELD or line.state == CH.ESCROW_STATE.RELEASING)
                and not line.owed_to and not line.releasing_to
                and line.portion ~= CH.PORTION.OWED then
                untouched = true
            end
            if lines[j].state == CH.ESCROW_STATE.RELEASING then
                -- Claimed but never settled. The server stopped between
                -- handing the money over and recording that it had, so we
                -- cannot know which happened.
                --
                -- The line is returned to `held` so it is owed rather than
                -- stuck forever. That is the deliberate trade: the window is
                -- a few instructions wide, and a line left `releasing` is
                -- money no code path can ever reach again. Every one of
                -- these is logged with everything staff need to check it.
                Storage.claimEscrowLine(lines[j].id, CH.ESCROW_STATE.RELEASING, CH.ESCROW_STATE.HELD)
                unstuck = unstuck + 1
                print(('[crimson-hitman] escrow line %s was mid-release at shutdown; ' ..
                       'returned to held — verify it was not already paid')
                       :format(tostring(lines[j].id)))
                if modules.audit then
                    modules.audit.financial('release_interrupted', lines[j].releasing_to,
                        contract.id, { line = lines[j].id, amount = lines[j].amount,
                                       review = true })
                end
            end
        end

        if contract.state == CH.STATE.COMPLETING then
            -- A claim that had paid its collection and died before moving
            -- the slot on. Every baseline line of that collection is either
            -- settled or waiting for the person it was paid to, so it was
            -- paid; left where it was, the next hitman to kill the target
            -- for it was paid out of an empty slot.
            local slot = contract.next_slot or 1
            local baseline, unpaid = 0, 0
            for j = 1, #lines do
                local line = lines[j]
                if line.slot == slot and line.portion == CH.PORTION.BASELINE then
                    baseline = baseline + 1
                    if line.state ~= CH.ESCROW_STATE.SETTLED and not line.owed_to then
                        unpaid = unpaid + 1
                    end
                end
            end
            if baseline > 0 and unpaid == 0 and Storage.advanceSlot(contract.id, slot) then
                contract = Storage.readContract(contract.id) or contract
            end

            if (contract.next_slot or 1) > (contract.payout_slots or 1) then
                -- Every collection was already paid: the last claim died
                -- between advancing the slot and closing. Put back to
                -- accepted, this was a live contract with nothing left to
                -- claim, which then ran out and forfeited the stake of the
                -- hitman who had collected all of it. It is finished instead.
                if modules.contracts.recoverEnded(contract.id) then
                    finished = finished + 1
                end
            else
                -- Settlement was interrupted. Put it back to accepted so the
                -- normal path can run again; escrow lines are individually
                -- guarded, so anything already settled stays settled.
                Storage.compareSetContractState(contract.id, CH.STATE.COMPLETING, CH.STATE.ACCEPTED)
                recovered = recovered + 1
            end
        elseif untouched and CH.TERMINAL[contract.state] then
            -- Closed, and still holding something nobody tried to pay.
            -- `resolve` moves the state first and the money after, so a crash
            -- in between left the escrow on a contract nothing releases again.
            if modules.contracts.recoverEnded(contract.id) then
                finished = finished + 1
            end
        end

        -- Both below read the contract as the steps above left it. Asked of
        -- the first read, an acceptance part-way on a contract another
        -- hitman's claim had locked (COMPLETING) was skipped, and the claim
        -- was then put back to ACCEPTED with the row still joining: its
        -- stake held, its hitman unable to take it, leave it or work it.
        local current = Storage.readContract(contract.id) or contract

        -- An acceptance the crash left part-way (Contracts.recoverJoining).
        if (current.state == CH.STATE.ACTIVE or current.state == CH.STATE.ACCEPTED)
            and modules.contracts.recoverJoining then
            recovered = recovered + modules.contracts.recoverJoining(current)
        end

        -- Owed lines a crash left unqueued, and a stake reduction it
        -- interrupted (Escrow.recoverOwed). After the lines caught
        -- mid-release are back to held: asked before, it looked only at
        -- held lines, so an owed line the crash caught releasing was put
        -- back to held unqueued, and waited for the next restart — while
        -- the claim it belonged to was counted as paid.
        if modules.escrow.recoverOwed then
            recovered = recovered + modules.escrow.recoverOwed(Storage.readEscrow(contract.id))
        end

        ::continue::
    end

    -- Escrow whose contract was never stored: a crash between taking a new
    -- contract's escrow and writing its row (Contracts.recoverNeverPlaced).
    -- The walk above only reaches lines through a contract that exists.
    local returned = modules.contracts.recoverNeverPlaced
        and modules.contracts.recoverNeverPlaced() or 0

    if recovered > 0 or unstuck > 0 or finished > 0 or returned > 0 then
        print(('[crimson-hitman] recovery: %d contracts resumed, %d finished, %d escrow '
            .. 'lines unstuck, %d handed back from contracts never placed')
            :format(recovered, finished, unstuck, returned))
        modules.audit.action('startup_recovery', nil, nil,
            { contracts = recovered, finished = finished, lines = unstuck,
              paused = paused, never_placed = returned })
    end

    -- Alive from here on.
    if Storage.heartbeat then Storage.heartbeat(now) end

    return recovered, unstuck, finished
end

--------------------------------------------------------------------------
-- Maintenance tick
--------------------------------------------------------------------------

function StartTick()
    CreateThread(function()
        while true do
            Wait(Config.Audit.FlushIntervalMs or 10000)
            local ok, err = pcall(Tick)
            if not ok then print('[crimson-hitman] tick error: ' .. tostring(err)) end
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
---
--- And each is timed (server/timing.lua): one slower than
--- Config.Diagnostics.SlowJobMs says so in the console, and /ch-diag lists
--- the slowest.
local function job(name, fn, ...)
    local ok, err = modules.timing.run(name, fn, ...)
    if not ok then
        print(('[crimson-hitman] maintenance job %q failed: %s'):format(name, tostring(err)))
    end
    return ok
end

--- Hand over what was queued for players who are still online.
---
--- The login retry was the only thing that ever read the queue, while the
--- app told a player whose pockets were full to "make room and it will be
--- handed over". Told the same way the login retry tells them.
function RetryWaiting()
    local delivered = modules.escrow.retryWaiting(function(cid)
        return modules.identity.byCitizenId(cid) ~= nil
    end)
    for cid, count in pairs(delivered) do
        modules.notify.toCitizen(cid, 'Outstanding payment',
            ('%d outstanding item%s been delivered.')
                :format(count, count == 1 and ' has' or 's have'),
            { bypassBudget = true })
    end
    return delivered
end

--- How often the photo retention runs while it has nothing to catch up on.
--- Counted in days, so ten minutes late is nothing; every tick, it was an
--- UPDATE across the whole ledger on mysql, which no index can serve.
local FORGET_EVERY_SECONDS = 600
local nextForget = 0

--- The ledger's photo retention, at most every FORGET_EVERY_SECONDS. Back
--- next tick while it is still removing photos: a pass takes a bounded
--- number, and a backlog (retention just switched on, a long downtime)
--- drains at the old rate.
function ForgetOldPhotos()
    local now = os.time()
    if now < nextForget then return 0, 0 end
    -- Marked before the call, like the host refresh: a pass that throws
    -- is not retried every ten seconds.
    nextForget = now + FORGET_EVERY_SECONDS
    local forgotten, photos = modules.ledger.forgetOldPhotos()
    if (tonumber(photos) or 0) > 0 then nextForget = 0 end
    return forgotten, photos
end

function Tick()
    job('audit.flush', modules.audit.flush)
    job('amendments.expire', modules.amendments.expire)
    job('bailout.processQueue', modules.bailout.processQueue)
    job('escrow.retryWaiting', RetryWaiting)
    job('photo.sweep', modules.photo.sweep)

    local now = os.time()
    -- Only where photos come from a host. On 'server' storage the
    -- allowlist is never consulted.
    if Config.Completion.PhotoStorage == 'host'
        and now - lastHostRefresh >= (Config.Completion.PhotoHostRefreshSeconds or 300) then
        -- Marked done whether or not the read succeeds: retrying a
        -- cross-resource config read every ten seconds because it failed
        -- once is how one broken export becomes a busy loop.
        lastHostRefresh = now
        job('photo.loadAllowedHosts', modules.photo.loadAllowedHosts)
    end
    job('death.sweep', modules.death.sweep)
    job('ratelimit.sweep', modules.ratelimit.sweep)
    if Storage.prune then job('storage.prune', Storage.prune) end
    job('ledger.forgetOldPhotos', ForgetOldPhotos)
    -- A kill photo opened and never saved or deleted: the phone closed
    -- mid-view. It goes as if the client had chosen Delete.
    job('photos.expire', modules.photos.expire)
    -- A photo kept in the app past Config.Completion.KeptPhotoDays, where
    -- that is set.
    job('photos.forgetKept', modules.photos.forgetKept)
    local app = require('server.app')
    -- Who may have the app on their phone. Recomputed here rather than
    -- trusted to a job-change event whose name has differed across
    -- framework versions: a wrong name fails silently in the direction that
    -- costs a player the app with no way to ask for it back.
    local bridges = require('server.bridges')
    if bridges.refreshAccess then job('bridges.refreshAccess', bridges.refreshAccess) end
    job('app.sweepHandles', app.sweepHandles)
    job('app.sweepFloodCounters', app.sweepFloodCounters)
    -- An exclusive contract held by somebody who is not working it goes
    -- back on the board (§14.8).
    if modules.contracts.releaseIdleHolds then
        job('contracts.releaseIdleHolds', modules.contracts.releaseIdleHolds)
    end
    -- An acceptance a throw left part-way, and whose taking back threw too.
    if modules.contracts.retryStuckJoins then
        job('contracts.retryStuckJoins', modules.contracts.retryStuckJoins)
    end
    -- A contract a throw left undecided as it was placed: its escrow and
    -- fee back once the store answers, if it was not stored after all.
    if modules.contracts.retryStuckCreates then
        job('contracts.retryStuckCreates', modules.contracts.retryStuckCreates)
    end
    job('expireContracts', ExpireContracts)
    -- When this process was last known to be running, so the next boot can
    -- tell how long nobody could play. See Recover.
    if Storage.heartbeat then job('storage.heartbeat', Storage.heartbeat, os.time()) end
    -- Last, and the one every other job used to stand in front of.
    if Storage.flush then job('storage.flush', Storage.flush) end
end

--- Close contracts whose deadline has passed.
---
--- The completion clock is paused while either party is offline, so logging
--- out cannot run out a hitman's timer and cannot dodge a refund (§7.1). The
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

    -- Live contracts only, which is all the pass acts on.
    local contracts = Storage.liveContracts()
    local resolved = 0

    -- The soonest future moment worth waking for. Starts far out and is
    -- pulled in by every live contract's deadline.
    local soonest = now + (Config.Limits.MaxDeadlineSkipSeconds or 600)

    for i = 1, #contracts do
        local contract = contracts[i]
        -- Read again before acting on it. The list above was read once, and
        -- every write and every resolve for the contracts before this one is
        -- an await in which a player can act on this one: a payout claimed,
        -- a deadline extended, a bonus raised. The pause marker below wrote
        -- back the whole row as the list had it and undid all of them — a
        -- claimed collection went back on offer and the next kill was paid
        -- out of a slot already settled — and the deadline check expired a
        -- contract its creator had just extended.
        if contract.state == CH.STATE.ACTIVE or contract.state == CH.STATE.ACCEPTED then
            contract = Storage.readContract(contract.id) or contract
        end
        if contract.state == CH.STATE.ACTIVE or contract.state == CH.STATE.ACCEPTED then
            -- The absolute ceiling applies whatever anyone's presence is.
            if contract.expires_at and now > contract.expires_at then
                -- Whether the hitmen failed is the paused deadline's
                -- question, not the lifetime's (§3.6, §14.18). The lifetime
                -- runs through every pause, so reaching it while the
                -- deadline still has time on it — which is how it is almost
                -- always reached, a target who was out of the city — is not
                -- a hitman who let the clock run out, and their stake comes
                -- back. It used to forfeit to the creator regardless: a
                -- hitman holding a contract on a target who left for two
                -- days lost their stake without ever having had them in
                -- the city.
                local deadlinePassed = not contract.paused_since
                    and contract.deadline_at ~= nil and now > contract.deadline_at
                if modules.contracts.resolve(contract.id, CH.STATE.EXPIRED,
                    contract.creator_cid, nil, 'lifetime_exceeded',
                    { forfeit = deadlinePassed and true or false,
                      dueAt = now, byLifetime = true }) then
                    resolved = resolved + 1
                end
            else
                -- An anonymous creator's presence is not asked (§14.32).
                -- Pausing for it moved the deadline on by exactly how long
                -- they were away, and every viewer is sent the deadline:
                -- their session, to the minute. The hitman loses nothing by
                -- it. A kill needs only the target, and a handover to a
                -- creator nobody can locate is as easily avoided by one who
                -- is online and elsewhere as by one who has logged off.
                local creatorOnline = contract.anon_creator == true
                    or modules.identity.byCitizenId(contract.creator_cid) ~= nil
                local targetActor = modules.identity.byCitizenId(contract.target_cid)
                -- A target in prison is as far out of reach as one who has
                -- logged off, and the hitman's clock ran on while they
                -- served their time. Not once the deadline has gone,
                -- though: a sentence written after it would otherwise turn
                -- an expiry into a pause, and the lifetime then hands the
                -- hitman back a stake they had already lost.
                local overdue = not contract.paused_since
                    and contract.deadline_at ~= nil and now > contract.deadline_at
                local jailed = Config.Limits.PauseWhileTargetJailed and targetActor ~= nil
                    and not overdue and modules.identity.isJailed(targetActor)
                local targetAvailable = targetActor ~= nil and not jailed
                local paused = not (creatorOnline and targetAvailable)

                if paused then
                    -- Record when the pause began, once. The deadline is
                    -- extended when it ends, by however long it lasted.
                    --
                    -- Narrow writes, not the row: the row this pass holds was
                    -- read one await ago, and writing it back undid whatever
                    -- landed in that await — a deadline the client had just
                    -- extended, most of all.
                    if not contract.paused_since and Storage.startPause(contract.id, now) then
                        contract.paused_since = now
                    end
                    -- A release from prison is not a player arriving, and on
                    -- a framework that does not announce it nothing else
                    -- would bring the pass back before its longest skip.
                    if targetActor and not targetAvailable and now + 60 < soonest then
                        soonest = now + 60
                    end
                else
                    if contract.paused_since then
                        local since = contract.paused_since
                        -- Relative, so an extension landing meanwhile is kept.
                        if Storage.endPause(contract.id, since, now - since) then
                            contract = Storage.readContract(contract.id) or contract
                        end
                    end

                    -- A hitman who made the kill before the deadline and is
                    -- walking to the body with the camera, or who armed a
                    -- handover that is still counting: expired under them,
                    -- the photo was refused and the stake went to the
                    -- client, for a job done in time. The pass comes back
                    -- next tick until it finishes, for no longer than a kill
                    -- waits for its photo. Never the lifetime's branch: that
                    -- ceiling holds whatever anyone is doing. Never for a
                    -- kill made after the deadline either, in the seconds
                    -- before this pass came round: that one was too late.
                    local finishing = contract.deadline_at and now > contract.deadline_at
                        and now <= contract.deadline_at
                            + 2 * Config.Completion.PhotoTokenLifetimeSeconds
                        and modules.bailout.finishing(contract.id, contract.deadline_at)
                    if finishing then
                        soonest = now
                    elseif contract.deadline_at and now > contract.deadline_at then
                        if modules.contracts.resolve(contract.id, CH.STATE.EXPIRED,
                            contract.creator_cid, nil, 'expired', { dueAt = now }) then
                            resolved = resolved + 1
                        end
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

    -- Without waiting on the database (Audit.flush): on mysql the first
    -- awaited row yielded this handler, the stop went on without it, and
    -- every queued row behind that one was lost.
    modules.audit.flush(true)

    -- Memory mode: release every open escrow before the tables vanish.
    if Config.Database.Mode == 'memory' then
        local contracts = Storage.allContracts()
        for i = 1, #contracts do
            local c = contracts[i]

            -- Money already promised to one named person, on EVERY contract
            -- whatever state it is in.
            --
            -- A payout that could not be handed over when it was earned — a
            -- hitman whose pockets were full, a creator who had logged off
            -- before an unearned bonus came back — is marked owed_to and
            -- delivered at that player's next login. In memory mode there is
            -- no next login: the tables go with the resource. The config says
            -- this mode "releases all open escrow on shutdown rather than
            -- losing it", and both sweeps below stepped straight past these
            -- lines — the stake loop names a portion they do not have, and the
            -- creator refund deliberately skips anything owed to somebody
            -- else. Worse, a finished contract was not visited at all, and a
            -- completed contract is exactly where a claimed payout and an
            -- unearned bonus end up.
            --
            -- Released by name, so the release is authorised to move money
            -- that is spoken for. A recipient who is still offline gets
            -- nothing, and nothing here can change that; one who is online —
            -- back from the crash that queued it, or never gone — is paid.
            local owed = {}
            for _, line in ipairs(Storage.readEscrow(c.id) or {}) do
                if line.owed_to and line.state ~= CH.ESCROW_STATE.SETTLED then
                    owed[line.owed_to] = owed[line.owed_to] or {}
                    owed[line.owed_to][line.id] = true
                end
            end
            -- A buyout paid and still waiting out its delay. The target's
            -- premium is in no pocket and no escrow line: it exists only as
            -- the queue columns on this row, and the row goes with the
            -- resource. Neither sweep below reads those columns, so a target
            -- who paid in the two minutes before a restart lost the premium
            -- outright. It goes back to whoever paid it.
            if c.bailout_queued_at and modules.bailout then
                modules.bailout.returnQueued(c, 'resource_stopping')
            end

            for cid, ids in pairs(owed) do
                modules.escrow.release(c.id, cid, { lines = ids }, 'resource_stopping_owed')
            end

            if not CH.TERMINAL[c.state] then
                -- Stakes belong to the hitmen who put them up, and an
                -- unfiltered release deliberately skips them — so they are
                -- returned explicitly here rather than destroyed with the
                -- tables.
                local hitmen = Storage.readHitmen(c.id)
                for j = 1, #hitmen do
                    modules.escrow.release(c.id, hitmen[j].hitman_cid,
                        { portion = CH.PORTION.STAKE, staker = hitmen[j].hitman_cid },
                        'resource_stopping')
                end
                modules.escrow.release(c.id, c.creator_cid, nil, 'resource_stopping')
            end
        end
    end

    -- The last moment anybody could play, to the second.
    if Storage and Storage.heartbeat then pcall(Storage.heartbeat, os.time()) end
    if Storage and Storage.close then Storage.close() end
end)

return {
    start = StartCrimsonHitman, recover = Recover, tick = Tick, expire = ExpireContracts,
    forgetOldPhotos = ForgetOldPhotos,
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
