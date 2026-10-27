--- Bootstrap and the maintenance tick.
---
--- Wires the modules together, validates the configuration at boot, and owns
--- the only recurring timer in the resource besides the kidnap countdown.

local Util = CrimsonBoot.requireShared('util')
local Log = CrimsonBoot.requireShared('log')

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
        -- The admin panel's, which no config before it names. Its overview
        -- refreshes itself while it is open, and the fallback rule of ten
        -- would refuse a staff member clicking through a few contracts.
        admin      = { per = 10, burst = 30 },
        adminWrite = { per = 10, burst = 6 },
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
            -- The review queue's, added to a list every config has.
            review   = 'ch-review',
            -- The timer refresh had /hitmanadmin, which is the admin
            -- panel's now: a config without either has both under their
            -- names (and one that still gives the refresh /hitmanadmin is
            -- moved off it at start, below).
            refresh  = 'ch-refresh',
            panel    = 'hitmanadmin',
        },
        PanelPageSize = 25,
        PanelRefreshSeconds = 10,
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
        --- How a contract is completed. Absent on every config from before
        --- live transfer only, and filled with what ships, as every switch
        --- here is: a city that never chose kills does not get them back
        --- by having an older config. Checked below.
        Fulfilment = 'alive',
        --- Kill photos at all. Absent on every config from before the
        --- switch, and filled with what ships, as the rule above is: off,
        --- so nothing asks an image host anything on a server that never
        --- chose to. Checked below.
        KillPhotos = false,
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
    --- Headshots at all. Absent on every config from before the switch,
    --- whose headshots were on. Checked below.
    Mugshot = {
        Enabled = true,
    },
    --- The whitelisted-job view. A whole section a config from before it
    --- lacks is filled from defaults.lua; this fills the key in one that
    --- has the section without it, with what ships: on. Checked below.
    WhitelistedView = {
        Enabled = true,
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
        -- Absent read as off, and two one-dollar contracts filled a target's
        -- MaxActiveContractsPerTarget on every server that upgraded.
        MinContractReward = 1000,
        -- How many times one contract can be collected. Filled, not
        -- refused, now that it is a choice of 1, 2 or 3 with a shipped
        -- answer; checked below.
        MaxPayoutSlots = 1,
        JailZone = { x = 1693.3, y = 2569.5, radius = 300 },
    },
    --- Absent read as off, and an anonymous client calling a named operative
    --- on a phone that cannot mask was dialled from their own number.
    Relay = {
        RequireMaskingForAnonymous = true,
        -- Absent, a thread kept every message ever sent to it.
        MaxMessagesPerThread = 100,
    },
    --- Owed deliveries tried per pass: at login and every 30 seconds for a
    --- player still online. Read inside the login timer, where a nil is a
    --- comparison that throws with nobody to see it.
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
        TriggerJobNames = {
            doj = true, lawyer = true, ranger = true, sast = true, fib = true, k9 = true,
            police = true, sheriff = true, leo = true, trooper = true, sasp = true,
            bcso = true, ambulance = true, fire = true,
        },
        RecipientJobTypes = { leo = true, police = true },
        RecipientJobNames = {
            police = true, sheriff = true, bcso = true, fib = true,
            trooper = true, sasp = true, ranger = true, sast = true, k9 = true,
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
        -- A Database section from before the limit existed waits 10 s, as
        -- shipped, not for ever.
        QueryTimeoutSeconds = 10,
    },
    --- A whole section a config from before it had is filled from
    --- defaults.lua; this fills the key in one that has the section.
    Diagnostics = {
        SlowJobMs = 5,
    },
    --- The same: a config with an Alerts section and not this key posts
    --- alerts to Discord, as shipped, where a webhook is set. Checked below.
    Alerts = {
        ToDiscord = true,
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

---@param quiet boolean|nil fill without saying so: a copy being checked, not the config
local function applyConfigDefaults(quiet)
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

    -- A configuration problem (shared/log.lua): in full with Config.Debug,
    -- and counted, once per setting, in the start's one line without it.
    if #filled > 0 and not quiet then
        table.sort(filled)
        Log.problem(('your config.lua does not set %d setting(s); the shipped '
            .. 'defaults are being used for them: %s. Copy them across from the config '
            .. 'that ships with this resource to set them yourself.')
            :format(#filled, table.concat(filled, ', ')), #filled)
    end

    return filled
end

---
--- `quiet` checks without printing or raising, and answers what it found:
--- the admin panel runs these same checks against a copy of the config
--- with a staff member's change in it (checkCandidate), so a value the
--- start would refuse, or quietly correct, is refused there in these words.
---@param quiet boolean|nil
---@return boolean ok
---@return string[]|nil fatal with `quiet`
---@return string[]|nil warn with `quiet`
--- The public address photos kept on this server are saved to a phone's
--- Photos from. Unset is the default (web_baseUrl is used); anything else
--- must be an https:// address the phone can load, and one that is not is
--- dropped, with the reason, rather than handed to phones as links that
--- lead nowhere.
---
--- Not with kill photos off (Config.Completion.KillPhotos): nothing is
--- served then, and a warning about the address would send the owner to
--- set up something that is never used. That switch is also the admin
--- panel's, kept across restarts, so a start checks this after the panel's
--- settings are applied (StartCrimsonHitman): read before, a config.lua
--- saying on and a panel saying off still counted the address as a setting
--- that needs attention. It is checked again where it is read
--- (Photos.publicBase), so turning photos on later is safe.
---@param warn string[] where a problem is added
local function checkPhotoAddress(warn)
    local publicUrl = Config.Completion.PhotoPublicUrl
    if publicUrl ~= nil and publicUrl ~= '' and Config.Completion.KillPhotos == true then
        local checked = CrimsonBoot.require('server.photos').checkBase(publicUrl)
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
end

local function validateConfig(quiet)
    local fatal, warn = {}, {}
    -- What is worth knowing and wrong with nothing: printed with
    -- Config.Debug only, and never counted as a setting that needs
    -- attention (shared/log.lua).
    local notes = {}

    -- Checked from scratch: what an earlier check found is not this one's.
    if not quiet then Log.clearProblems() end

    -- Before anything is read: a setting this config never had is nil, and
    -- the checks below would report it as broken rather than as absent.
    applyConfigDefaults(quiet)

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
        -- Inside the login timer and the 30-second retry (at least 1,
        -- below).
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
    if #fatal > 0 and quiet then return false, fatal, warn end
    -- Refusing to start: in full whatever Config.Debug says, the problems
    -- found so far with them, since no diagnosis can be run to read them.
    if #fatal > 0 then
        Log.reportProblems(true)
        for _, message in ipairs(fatal) do
            Log.always('FATAL: ' .. message)
        end
        error('[crimson-hitman] refusing to start on an invalid configuration')
    end

    local mode = Config.Database.Mode
    if mode ~= 'mysql' and mode ~= 'json' and mode ~= 'memory' then
        fatal[#fatal + 1] = ('Config.Database.Mode is "%s"; expected mysql, json or memory'):format(tostring(mode))
    end

    -- mysql keeps every amount in an INT column, which holds at most
    -- 2,147,483,647, and the reason and relay texts in VARCHAR(255). A
    -- setting above either let through what the store then refused: a
    -- contract taken and rolled back as bad_state, a message that never
    -- arrived. Held to the columns here, in mysql mode only; json and
    -- memory keep any figure. Before the MinContractReward check below,
    -- which compares against MaxContractValue.
    if mode == 'mysql' then
        local INT_MAX = 2147483647
        for _, path in ipairs({
            { 'MaxContractValue' }, { 'Sources', 'cash', 'max' }, { 'Sources', 'bank', 'max' },
            { 'Sources', 'dirty', 'max' }, { 'Bailout', 'AbsoluteMax' }, { 'Penalty', 'MaxAmount' },
            { 'Anonymity', 'CreatorFee' }, { 'Anonymity', 'HitmanFee' }, { 'Informant', 'Cost' },
        }) do
            local holder = Config
            for i = 1, #path - 1 do holder = type(holder) == 'table' and holder[path[i]] or nil end
            local key = path[#path]
            local value = type(holder) == 'table' and tonumber(holder[key]) or nil
            if value and value > INT_MAX then
                warn[#warn + 1] = ('Config.%s is %s; mysql mode keeps money in INT columns, which '
                    .. 'hold at most 2147483647. Using 2147483647.')
                    :format(table.concat(path, '.'), value == math.huge and 'infinite'
                        or ('%.0f'):format(value))
                holder[key] = INT_MAX
            end
        end
        for _, text in ipairs({
            { section = 'Reason', columns = 'crimson_contracts.reason and crimson_ledger.reason' },
            { section = 'Relay', columns = 'crimson_messages.body' },
        }) do
            local block = Config[text.section]
            local length = type(block) == 'table' and tonumber(block.MaxLength) or nil
            if length and length > 255 then
                warn[#warn + 1] = ('Config.%s.MaxLength is %s; mysql mode keeps that text in %s, '
                    .. 'which hold at most 255 characters. Using 255.')
                    :format(text.section, tostring(block.MaxLength), text.columns)
                block.MaxLength = 255
            end
        end
    end
    -- Only true lets a start past money another mode still holds (see
    -- refuseModeSwitch). Anything else, a string 'true' included, is the
    -- refusal, which is the safe way to misread it; said so here.
    local allowSwitch = Config.Database.AllowModeSwitch
    if allowSwitch ~= nil and type(allowSwitch) ~= 'boolean' then
        warn[#warn + 1] = ('Config.Database.AllowModeSwitch is %s, not true or false; it is read '
            .. 'as false'):format(tostring(allowSwitch))
    end
    -- How long one mysql statement may go unanswered (server/storage/mysql.lua).
    -- Not a number, or below 0, is the shipped 10; over 12, the phone's own
    -- 15 s wait can run out first.
    local answerLimit = Config.Database.QueryTimeoutSeconds
    if type(answerLimit) ~= 'number' or answerLimit ~= answerLimit or answerLimit < 0 then
        warn[#warn + 1] = ('Config.Database.QueryTimeoutSeconds is %s; expected 0 or more seconds. '
            .. 'Using 10.'):format(tostring(answerLimit))
        Config.Database.QueryTimeoutSeconds = 10
    elseif answerLimit > 12 then
        warn[#warn + 1] = ('Config.Database.QueryTimeoutSeconds is %s; the phone gives up after '
            .. '15 s, so a player may be told "no answer yet" before the server answers')
            :format(tostring(answerLimit))
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

    -- How many times one contract can be collected: 1, 2 or 3. Anything
    -- else is read as the nearest of those and said so, rather than
    -- refusing to start: a contract collected four times is not something
    -- this server offers, and a 0 is an owner who meant once.
    local slots = tonumber(Config.Limits.MaxPayoutSlots)
    if not slots or slots ~= slots or slots < 1 or slots > 3 or math.floor(slots) ~= slots then
        local nearest = (not slots or slots ~= slots) and 1
            or math.max(1, math.min(3, math.floor(slots + 0.5)))
        warn[#warn + 1] = ('Limits.MaxPayoutSlots is %s; it has to be 1, 2 or 3 (how many '
            .. 'times one contract can be collected). Using %d.')
            :format(type(Config.Limits.MaxPayoutSlots) == 'string'
                and ('"' .. Config.Limits.MaxPayoutSlots .. '"')
                or tostring(Config.Limits.MaxPayoutSlots), nearest)
        slots = nearest
    end
    Config.Limits.MaxPayoutSlots = math.tointeger(slots) or slots

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

    -- How a contract is completed. A misspelling is not a third rule, and
    -- not the looser one: it is read as live transfer only, as shipped, and
    -- said so, rather than handing back kills to a city that switched them
    -- off.
    local fulfilment = Config.Completion.Fulfilment
    if fulfilment ~= CH.FULFILMENT_RULE.ALIVE and fulfilment ~= CH.FULFILMENT_RULE.EITHER then
        warn[#warn + 1] = ('Completion.Fulfilment is %s; it has to be \'alive\' or '
            .. '\'either\'. Using \'alive\': contracts are completed only by a live handover.')
            :format(type(fulfilment) == 'string' and ('"' .. fulfilment .. '"') or tostring(fulfilment))
        Config.Completion.Fulfilment = CH.FULFILMENT_RULE.ALIVE
    end

    -- Kill photos at all, target headshots at all, and the whitelisted-job
    -- view. Read as plain truths everywhere, so anything but true or false
    -- is said and read as off, the side that takes, keeps and shows
    -- nothing: a string 'true' is not an owner who chose to keep pictures.
    for _, switch in ipairs({
        { section = 'Completion', key = 'KillPhotos',
          off = 'no kill photo is taken or kept, and Verify kill completes at the scene' },
        { section = 'Mugshot', key = 'Enabled', off = 'no target headshot is asked for or shown' },
        -- Off is the app closed to whitelisted jobs, as before the view:
        -- the side that shows them least.
        { section = 'WhitelistedView', key = 'Enabled',
          off = 'players on a whitelisted job get no screen in the app, as before the view' },
        -- Off is nothing sent outside the server.
        { section = 'Alerts', key = 'ToDiscord',
          off = 'no alert is posted to Discord; the admin panel still lists every one' },
    }) do
        local value = Config[switch.section][switch.key]
        if type(value) ~= 'boolean' then
            warn[#warn + 1] = ('%s.%s is %s, not true or false; it is read as false: %s.')
                :format(switch.section, switch.key, type(value) == 'string'
                    and ('"' .. value .. '"') or tostring(value), switch.off)
            Config[switch.section][switch.key] = false
        end
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

    -- The public address photos are served from (checkPhotoAddress). At a
    -- start it is checked after the admin panel's settings are applied,
    -- since whether kill photos are on may be the panel's to say; a
    -- candidate the panel checks has its own value in it already.
    if quiet then checkPhotoAddress(warn) end

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

    -- The least a new contract's reward may be worth in money. A whole
    -- number of dollars, 0 for no minimum; anything else is read as the
    -- shipped figure and said so, rather than as no minimum at all. One
    -- above the most a contract may be worth would refuse every contract
    -- placed, so it is held to that.
    local minReward = tonumber(Config.Limits.MinContractReward)
    if not minReward or minReward ~= minReward or minReward < 0 or minReward == math.huge then
        warn[#warn + 1] = ('Limits.MinContractReward is %s, not a number of dollars (0 for no '
            .. 'minimum); using 1000.'):format(tostring(Config.Limits.MinContractReward))
        minReward = 1000
    end
    minReward = math.floor(minReward)
    local maxValue = tonumber(Config.MaxContractValue)
    if maxValue and minReward > maxValue then
        warn[#warn + 1] = ('Limits.MinContractReward (%d) is above MaxContractValue (%d), so no '
            .. 'contract could ever be placed; using %d.'):format(minReward, maxValue,
                math.floor(maxValue))
        minReward = math.floor(maxValue)
    end
    Config.Limits.MinContractReward = minReward

    -- How slow a maintenance job may be before the console hears about it.
    -- 0 turns the warning off; /ch-diag still lists the slowest jobs.
    local slowMs = tonumber(Config.Diagnostics.SlowJobMs)
    if not slowMs or slowMs ~= slowMs or slowMs < 0 then
        warn[#warn + 1] = ('Diagnostics.SlowJobMs is %s, not a number of milliseconds (0 for '
            .. 'no warning); using 5.'):format(tostring(Config.Diagnostics.SlowJobMs))
        slowMs = 5
    end
    Config.Diagnostics.SlowJobMs = slowMs

    -- How many owed payouts one retry pass tries: the one at login and the
    -- one every 30 seconds for a player still online alike. Below 1 no owed
    -- payout was ever tried, and nothing said so; read as 'none at login'
    -- or 'unlimited' it stopped every one of them for good.
    local retries = Config.PendingEscrow.MaxRetriesPerLogin
    if retries ~= retries or retries < 1 then
        warn[#warn + 1] = ('PendingEscrow.MaxRetriesPerLogin is %s; it is how many owed payouts '
            .. 'every retry pass tries (at login, and every 30 seconds for a player still '
            .. 'online), so below 1 none would ever be delivered. Using 1.'):format(tostring(retries))
        Config.PendingEscrow.MaxRetriesPerLogin = 1
    end

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

    -- A note: memory mode is chosen on purpose, for testing, and the
    -- diagnosis's first lines say which storage is in use.
    if mode == 'memory' then
        notes[#notes + 1] = 'Database.Mode is "memory": contracts and escrow will NOT survive a restart'
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

    -- A note, not a problem: it is how the shipped config works (QBox's own
    -- playtime metadata), and it changes nothing. Said with Config.Debug,
    -- and kept for the diagnosis; never counted as a setting to fix.
    if (tonumber(Config.Immunity.MinTargetPlaytimeHours) or 0) > 0
        and not (Config.Immunity.PlaytimeProvider and Config.Immunity.PlaytimeProvider.resource) then
        notes[#notes + 1] = ('Immunity.MinTargetPlaytimeHours is %d but no PlaytimeProvider is set; ' ..
            'the rule applies only where QBox metadata carries a playtime figure')
            :format(Config.Immunity.MinTargetPlaytimeHours)
    end

    if not Config.Kidnap.RequireCoercion then
        warn[#warn + 1] = 'Kidnap.RequireCoercion is off: a target can be "delivered" while walking freely'
    end
    -- A restraint required and nothing that can show one: every handover is
    -- refused as not restrained, the target cuffed in the hitman's car too,
    -- so on 'alive' no accepted contract could ever complete and each ran to
    -- its deadline with its hitman's stake forfeited. Handcuffs are counted
    -- again rather than the start refused, which would freeze every
    -- contract's escrow; the admin panel refuses the click that causes it,
    -- in these words (checkCandidate).
    local coercion = Config.Kidnap.Coercion
    if Config.Kidnap.RequireCoercion and type(coercion) == 'table' and not coercion.handcuffed
        and not coercion.passengerOfHitman and not Config.Kidnap.RestraintProvider then
        warn[#warn + 1] = 'Kidnap.RequireCoercion is on, but neither Kidnap.Coercion.handcuffed nor '
            .. 'Kidnap.Coercion.passengerOfHitman counts as restraint and no Kidnap.RestraintProvider '
            .. 'is set, so no handover could ever complete. Using Kidnap.Coercion.handcuffed = true.'
        coercion.handcuffed = true
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
        warn[#warn + 1] = 'Advisory.Enabled is on but nobody is configured to receive it '
            .. '(Advisory.RecipientJobTypes and RecipientJobNames are both empty)'
    end

    -- A job barred from the app that does not count as law enforcement
    -- here: a contract on its members raises no advisory, carries no
    -- listing flag and warns nobody, and the whitelisted-job view, which
    -- lists only what the advisory covers, leaves them out. Unless
    -- qbx_core gives the job a type in TriggerJobTypes, which only a
    -- running server can say.
    local unprotected = {}
    local triggerNames = Config.Advisory.TriggerJobNames or {}
    local triggerTypes = Config.Advisory.TriggerJobTypes or {}
    for name, on in pairs(Config.BlockedJobNames or {}) do
        if on and not triggerNames[tostring(name):lower()] then
            unprotected[#unprotected + 1] = tostring(name)
        end
    end
    for jobType, on in pairs(Config.BlockedJobTypes or {}) do
        if on and not triggerTypes[tostring(jobType):lower()] then
            unprotected[#unprotected + 1] = 'type ' .. tostring(jobType)
        end
    end
    if #unprotected > 0 then
        table.sort(unprotected)
        warn[#warn + 1] = ('barred from the app but not law enforcement to the advisory: %s. A '
            .. 'contract on them raises no advisory and no listing flag, and the whitelisted-job '
            .. 'view does not list it, unless qbx_core gives the job a type in '
            .. 'Advisory.TriggerJobTypes. Add each to Advisory.TriggerJobNames (or TriggerJobTypes)')
            :format(table.concat(unprotected, ', '))
    end

    -- The timer refresh was /hitmanadmin until the admin panel took the
    -- name. A config.lua from before that still gives it to the refresh,
    -- and two commands under one name is whichever registered last: the
    -- refresh moves to its new name, and the panel keeps /hitmanadmin.
    local commands = Config.Admin.Commands
    if type(commands) == 'table' and commands.panel ~= nil and commands.refresh == commands.panel then
        warn[#warn + 1] = ('Admin.Commands.refresh is \'%s\', which is the admin panel\'s '
            .. 'command (Admin.Commands.panel). Using \'ch-refresh\' for the timer refresh; set '
            .. 'Admin.Commands.refresh = \'ch-refresh\' in config.lua.'):format(tostring(commands.panel))
        commands.refresh = 'ch-refresh'
    end

    if quiet then return #fatal == 0, fatal, warn end

    -- Configuration problems (shared/log.lua): each in full with
    -- Config.Debug on, and one line for all of them at the end of the start
    -- with it off (StartCrimsonHitman). Refusing to start says them all.
    for _, message in ipairs(warn) do
        Log.problem('warning: ' .. message)
    end
    for _, message in ipairs(notes) do
        Log.debug('note: ' .. message)
    end
    if #fatal > 0 then
        Log.reportProblems(true)
        for _, message in ipairs(fatal) do
            Log.always('FATAL: ' .. message)
        end
        error('[crimson-hitman] refusing to start on an invalid configuration')
    end

    return true
end

--- Run the start-up checks against a copy of the config rather than the
--- live one, and answer what they found (validateConfig's quiet mode).
---
--- The admin panel's settings (server/settings.lua) are checked this way,
--- with the change in the copy, so a value is held to exactly what the
--- start holds config.lua to. The checks read the global Config, so it is
--- the copy for the length of the call and the live one again after it,
--- whatever happens: nothing in them waits, so nothing else runs meanwhile.
---@param candidate table
---@return boolean ok
---@return string[] fatal
---@return string[] warn
local function checkCandidate(candidate)
    local live = Config
    Config = candidate
    local ran, ok, fatal, warn = pcall(validateConfig, true)
    Config = live
    if not ran then return false, { tostring(ok) }, {} end
    return ok, fatal or {}, warn or {}
end

--------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------

local function selectStorage()
    local mode = Config.Database.Mode
    if mode == 'mysql' then return CrimsonBoot.require('server.storage.mysql') end
    if mode == 'json' then return CrimsonBoot.require('server.storage.json') end
    return CrimsonBoot.require('server.storage.memory')
end

--- How many contracts holding money a refusal names, each with what it
--- holds and what clears it.
local SWITCH_LISTED = 10

--- One contract another mode holds money on, in a line for the owner: its
--- id and state, what its unsettled lines hold by source, whom anything is
--- owed to by role (never by name), and what clears it. `mode` is the mode
--- holding it, which is the one these must be cleared in.
---@param entry table { id, contract, lines, hitmen } from a store's inspect
---@param mode string
---@return string
local function heldLine(entry, mode)
    local contract = entry.contract
    local amounts, order, goods, owed, owedOrder = {}, {}, 0, {}, {}
    local staff, limit = contract == nil, CrimsonBoot.require('server.escrow').DELIVER_RAISE_LIMIT
    local lines = {}
    for i, line in ipairs(entry.lines or {}) do lines[i] = line end
    table.sort(lines, function(a, b) return tostring(a.id) < tostring(b.id) end)
    for _, line in ipairs(lines) do
        if line.source == CH.SOURCE.ITEM or line.source == CH.SOURCE.WEAPON then
            goods = goods + 1
        else
            local source = tostring(line.source)
            if amounts[source] == nil then order[#order + 1] = source end
            amounts[source] = (amounts[source] or 0) + (tonumber(line.amount) or 0)
        end
        if line.owed_to ~= nil then
            local role = (contract and line.owed_to == contract.creator_cid and 'the client')
                or (contract and line.owed_to == contract.target_cid and 'the target')
                or ((entry.hitmen or {})[line.owed_to] and 'an operative') or 'a player'
            if not owed[role] then
                owed[role] = true
                owedOrder[#owedOrder + 1] = role
            end
        end
        -- Left for staff: a give that kept raising, or one the server
        -- stopped in the middle of, which the next start leaves for them.
        if (tonumber(line.deliver_raises) or 0) >= limit or line.releasing_to ~= nil then
            staff = true
        end
    end

    local held = {}
    for _, source in ipairs(order) do
        held[#held + 1] = ('%d %s'):format(math.floor(amounts[source]),
            source == CH.SOURCE.DIRTY and 'dirty money' or source)
    end
    if goods > 0 then held[#held + 1] = ('%d item(s) or weapon(s)'):format(goods) end
    local what = table.concat(held, ', ')
    if #owedOrder > 0 then what = what .. ' owed to ' .. table.concat(owedOrder, ' and ') end

    local commands = Config.Admin.Commands
    local clears
    if staff then
        clears = ('left for staff: /%s lists it, /%s settles it'):format(commands.stuck, commands.settle)
    elseif not CH.TERMINAL[contract.state] then
        clears = ('running: let it finish, the client can cancel it in the app while nobody has '
            .. 'taken it, or staff can void it (/%s)'):format(commands.void)
    elseif #owedOrder > 0 then
        clears = 'owed to a player who is away: handed over at their next login'
    else
        clears = ('finished with money not yet handed back: the next start in %s mode hands it '
            .. 'back'):format(mode)
    end
    return ('%s (%s): %s; %s'):format(tostring(entry.id),
        contract and tostring(contract.state) or 'no contract row', what, clears)
end

--- The contracts holding money, up to SWITCH_LISTED of them, one a line.
local function heldList(holding, mode, more)
    local out = {}
    for i = 1, math.min(#(holding or {}), SWITCH_LISTED) do
        out[#out + 1] = '  - ' .. heldLine(holding[i], mode)
    end
    local beyond = more or (#(holding or {}) - SWITCH_LISTED)
    if beyond == true then
        out[#out + 1] = '  - and more not listed'
    elseif beyond > 0 then
        out[#out + 1] = ('  - and %d more contract(s) not listed'):format(beyond)
    end
    return out
end

--- The review items another mode keeps for staff (W155), up to SWITCH_LISTED
--- of them, one a line: its id, kind and contract, the money it records,
--- and what clears it. `mode` is the mode keeping them.
---@param reviews table[] { id, kind, contract_id, state, account, money, goods } from inspect
---@param mode string
---@param more boolean|nil the store has more than it listed
---@return string[]
local function reviewLines(reviews, mode, more)
    local out = {}
    for i = 1, math.min(#reviews, SWITCH_LISTED) do
        local r = reviews[i]
        local what = {}
        if (tonumber(r.money) or 0) > 0 then
            what[#what + 1] = ('%d%s'):format(math.floor(r.money), r.account and (' ' .. r.account) or '')
        end
        if (tonumber(r.goods) or 0) > 0 then
            what[#what + 1] = ('%d item(s) or weapon(s)'):format(r.goods)
        end
        out[#out + 1] = ('  - review %s (%s) on contract %s: %s; %s, resolved with /%s in %s mode')
            :format(tostring(r.id), tostring(r.kind), tostring(r.contract_id),
                #what > 0 and table.concat(what, ', ') or 'no money recorded',
                r.state == 'resolving' and 'being resolved' or 'waiting for staff',
                tostring(Config.Admin.Commands.review), mode)
    end
    local beyond = more or (#reviews - SWITCH_LISTED)
    if beyond == true then
        out[#out + 1] = '  - and more review items not listed'
    elseif beyond > 0 then
        out[#out + 1] = ('  - and %d more review item(s) not listed'):format(beyond)
    end
    return out
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
---
--- Said contract by contract, with what each holds and what clears it: a
--- count of lines told the owner neither where nor how much, and "cancel
--- them in the app" clears neither a payout owed to a player who is away
--- nor a line left for staff. A contract file json mode cannot read is
--- named as one that may hold money: nobody can tell that it does not, and
--- switching away would also stop the warning that says to restore it.
local function refuseModeSwitch()
    local mode = Config.Database.Mode
    local found, listed = {}, {}

    if mode ~= 'json' then
        local ok, held = pcall(CrimsonBoot.require('server.storage.json').inspect)
        local folder = Config.Database.Json.Directory or 'data'
        if ok and held then
            local unreadable = held.unreadable or {}
            local reviews = held.reviews or {}
            if held.lines > 0 or held.owed > 0 or #unreadable > 0 or #reviews > 0 then
                if held.lines > 0 or held.owed > 0 then
                    found[#found + 1] = ('json mode: %d escrow line(s) and %d payout(s) owed, in %s/')
                        :format(held.lines, held.owed, folder)
                end
                -- Money waiting for staff: an item is the only record of a
                -- payment no rule could settle, and this mode's queue would
                -- start without it (W155).
                if #reviews > 0 then
                    found[#found + 1] = ('json mode: %d review item(s) waiting for staff, in %s/')
                        :format(#reviews, folder)
                    for _, text in ipairs(reviewLines(reviews, 'json')) do listed[#listed + 1] = text end
                end
                if #unreadable > 0 then
                    local files = {}
                    for i = 1, #unreadable do files[i] = tostring(unreadable[i].file) end
                    found[#found + 1] = ('json mode: %d file(s) that cannot be read and may hold '
                        .. 'money (%s); restore them from a backup'):format(#files, table.concat(files, ', '))
                end
                for _, text in ipairs(heldList(held.holding, 'json')) do listed[#listed + 1] = text end
            elseif held.contracts > 0 then
                Log.debug(('%s/store.json still names %d finished contract(s) from '
                    .. 'json mode. They hold no money and %s mode does not read them.')
                    :format(folder, held.contracts, mode))
            end
        end
    end

    -- Only where oxmysql is running: a json server without a database has
    -- nothing there to find, and asking would wait on a connection forever.
    if mode ~= 'mysql' and GetResourceState('oxmysql') == 'started' and MySQL then
        -- Bounded, as every statement of the mysql store is: a database that
        -- does not answer held this start for ever, silently.
        local ok, held = pcall(CrimsonBoot.require('server.storage.mysql').inspect)
        if not ok then
            Log.always(('could not ask the database whether mysql mode still holds players\' '
                .. 'money (%s); starting in %s mode'):format(Util.dbError(held), tostring(mode)))
        end
        local reviews = ok and held and held.reviews or {}
        if ok and held and (held.lines > 0 or held.owed > 0 or #reviews > 0) then
            if held.lines > 0 or held.owed > 0 then
                found[#found + 1] = ('mysql mode: %d escrow line(s) and %d payout(s) owed, in the '
                    .. 'crimson_* tables'):format(held.lines, held.owed)
            end
            if #reviews > 0 then
                found[#found + 1] = ('mysql mode: %d%s review item(s) waiting for staff, in '
                    .. 'crimson_review'):format(#reviews, held.moreReviews and ' or more' or '')
                for _, text in ipairs(reviewLines(reviews, 'mysql', held.moreReviews)) do
                    listed[#listed + 1] = text
                end
            end
            for _, text in ipairs(heldList(held.holding, 'mysql', held.more)) do
                listed[#listed + 1] = text
            end
        end
    end

    -- Payments this machine keeps for another mode (resource KVP): caught
    -- by a database that stopped answering, and settled only by a start in
    -- the mode they were kept for. Started here, they would be carried
    -- nowhere.
    local kept = CrimsonBoot.require('server.review').keptElsewhere(mode)
    local modes = {}
    for keptMode in pairs(kept) do modes[#modes + 1] = keptMode end
    table.sort(modes)
    for _, keptMode in ipairs(modes) do
        found[#found + 1] = ('%d payment(s) kept on this machine for %s mode')
            :format(#kept[keptMode], keptMode)
        for i, item in ipairs(kept[keptMode]) do
            if i > SWITCH_LISTED then
                listed[#listed + 1] = ('  - and %d more kept on this machine not listed')
                    :format(#kept[keptMode] - SWITCH_LISTED)
                break
            end
            listed[#listed + 1] = ('  - review %s (%s) on contract %s: kept on this machine; a start '
                .. 'in %s mode settles it or lists it for staff'):format(tostring(item.id),
                tostring(item.kind), tostring(item.contract_id), keptMode)
        end
    end

    if #found == 0 then return end
    local where = table.concat(found, '; ')
    local contracts = #listed > 0 and ('\n' .. table.concat(listed, '\n')) or ''
    -- Money another mode holds, out of reach: said whatever Config.Debug says.
    if Config.Database.AllowModeSwitch == true then
        Log.always(('warning: started in %s mode although %s. '
            .. 'Config.Database.AllowModeSwitch is on, so none of it is visible or returned '
            .. 'from here.%s'):format(mode, where, contracts))
        return
    end
    error(('[crimson-hitman] Config.Database.Mode is \'%s\', but players\' money is still held by '
        .. 'another mode: %s. Modes do not share data, so started like this every contract '
        .. 'there and the money in it would be invisible, and nothing would return it. '
        .. 'Refusing to start. Switch Mode back and clear each contract as its line below says, '
        .. 'or settle them by hand and move that data out of the way, or set '
        .. 'Config.Database.AllowModeSwitch = true to start anyway.%s')
        :format(tostring(mode), where, contracts), 0)
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
    -- Without a renderer the board simply shows no faces, which is a
    -- degradation rather than a failure. With headshots switched off
    -- (Config.Mugshot.Enabled) nothing asks it anything, so it is not one.
    if Config.Mugshot.Enabled ~= false then
        add('MugShotBase64', 'target headshots on the board', false)
    end

    return out
end

--- Say what was found and what was not. An integration that is silently
--- absent is the worst case: progression simply stops crediting and nothing
--- anywhere says why.
local function reportIntegrations()
    -- The list itself only with Config.Debug on (and kept for the
    -- diagnosis); one that is configured and missing is a configuration
    -- problem, counted in the start's one line (shared/log.lua).
    local integrations = optionalIntegrations()
    if #integrations == 0 then
        Log.debug('no optional integrations configured')
        return integrations
    end

    -- One provider list can name several alternatives, only one of which
    -- needs to be present, so the death-state group is summarised together.
    local deathFound = false
    for _, entry in ipairs(integrations) do
        local found = GetResourceState(entry.resource) == 'started'
        if found and entry.purpose:find('true%-death') then deathFound = true end

        Log.debug(('integration %-16s %s  (%s)'):format(
            entry.resource, found and 'found' or 'not found', entry.purpose))

        -- Only a resource the operator actually named is worth a warning.
        -- The alternatives in a provider list are not each expected.
        if not found and entry.configured then
            Log.problem(('warning: %s is configured but not started; %s will not work')
                :format(entry.resource, entry.purpose))
        end
    end

    if not deathFound then
        Log.problem('warning: no death-state provider is running; ' ..
            'eliminations fall back to QBox metadata for the downed check')
    end

    -- Which ox_inventory read this build answers. An item picker that comes
    -- up empty is the symptom operators actually report, and until this
    -- line existed there was no way to tell an empty pocket from an export
    -- that was never there.
    local app = CrimsonBoot.require('server.app')
    local online = modules.identity and modules.identity.online() or {}
    local read = app.probeInventory(online[1])
    if read == nil then
        Log.debug('inventory read: nobody online to probe with; '
            .. 'it is checked again the first time someone opens the app')
    elseif read == false then
        Log.problem('warning: no ox_inventory read on this build answered. '
            .. 'Items and weapons cannot be offered as rewards; money still works. '
            .. 'The app says so on the form rather than showing an empty picker.')
    else
        Log.debug(('inventory read: %s'):format(read))
    end

    -- The roster setting is the other one whose failure looks like nothing
    -- at all: browsing off is an empty list, which reads as broken.
    Log.debug(('target browsing: %s, nearby: %s')
        :format(Config.Targeting.AllowBrowseAll and 'everyone online' or 'off',
                Config.Targeting.AllowNearby and 'on' or 'off'))

    return integrations
end



function StartCrimsonHitman()
    -- A start of its own: what an earlier one found and said is forgotten,
    -- and every line until the start is over is kept whole for the
    -- diagnosis (shared/log.lua).
    Log.beginStart()
    validateConfig()

    refuseModeSwitch()
    Storage = selectStorage()
    Storage.open()

    -- What staff changed from the admin panel, over config.lua: after the
    -- start-up checks, which it is held to as well, and before anything
    -- reads the config (server/settings.lua).
    local settings = CrimsonBoot.require('server.settings')
    settings.init({ storage = Storage, audit = CrimsonBoot.require('server.audit'),
                    check = checkCandidate })
    settings.boot()

    -- The start's warnings again, now for the config in force: the first
    -- run read config.lua before the panel's settings were applied, so a
    -- warning about a value set from the panel (the nearby list on, say)
    -- was never said at any start. Only the ones naming a key the panel
    -- set; the same line twice is said once (Log.problem).
    local inForce = {}
    for _, row in ipairs(settings.active()) do
        if row.applied then inForce[#inForce + 1] = row.key end
    end
    if #inForce > 0 then
        local _, _, again = checkCandidate(copyOf(Config))
        for _, message in ipairs(again or {}) do
            for _, key in ipairs(inForce) do
                if message:find(key, 1, true) then
                    Log.problem(('warning: %s (%s is set from the admin panel)'):format(message, key))
                    break
                end
            end
        end
    end

    -- The photo address, against whether kill photos are on now the panel's
    -- settings are in force (checkPhotoAddress).
    local photoWarn = {}
    checkPhotoAddress(photoWarn)
    for _, message in ipairs(photoWarn) do Log.problem('warning: ' .. message) end

    local identity   = CrimsonBoot.require('server.identity')
    local ratelimit  = CrimsonBoot.require('server.ratelimit')
    local audit      = CrimsonBoot.require('server.audit')
    local notify     = CrimsonBoot.require('server.notify')
    local escrow     = CrimsonBoot.require('server.escrow')
    local review     = CrimsonBoot.require('server.review')
    local contracts  = CrimsonBoot.require('server.contracts')
    local ledger     = CrimsonBoot.require('server.ledger')
    local photos     = CrimsonBoot.require('server.photos')
    local death      = CrimsonBoot.require('server.completion.death')
    local photo      = CrimsonBoot.require('server.completion.photo')
    local kidnap     = CrimsonBoot.require('server.completion.kidnap')
    local bailout    = CrimsonBoot.require('server.bailout')
    local informant  = CrimsonBoot.require('server.informant')
    local amendments = CrimsonBoot.require('server.amendments')
    local comms      = CrimsonBoot.require('server.comms')
    local mugshot    = CrimsonBoot.require('server.mugshot')
    local progression = CrimsonBoot.require('server.progression')
    local admin      = CrimsonBoot.require('server.admin')
    local projection = CrimsonBoot.require('server.projection')
    local app        = CrimsonBoot.require('server.app')
    local timing     = CrimsonBoot.require('server.timing')
    local panel      = CrimsonBoot.require('server.panel')
    local alerts     = CrimsonBoot.require('server.alerts')

    -- A job is charged for the time it holds the thread, not for the time
    -- it waits on the database while everything else runs (Timing.await).
    if Storage.timeWaitsWith then Storage.timeWaitsWith(timing.await) end

    audit.init(Storage)
    notify.init({ identity = identity, storage = Storage })
    -- Money events no rule can settle by themselves are left for staff
    -- here (server/review.lua), from escrow, contracts, buyouts and staff
    -- settles alike.
    review.init({ storage = Storage, escrow = escrow, audit = audit })
    escrow.init(Storage, audit, review)
    progression.init({ storage = Storage, identity = identity, audit = audit })
    contracts.init({ storage = Storage, escrow = escrow, identity = identity,
                     audit = audit, notify = notify, progression = progression,
                     death = death, review = review, ledger = ledger })
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
                   death = death, review = review })
    informant.init({ storage = Storage, identity = identity, audit = audit, death = death,
                     contracts = contracts })
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
        app = app, admin = admin, photos = photos, review = review,
        -- How long each tick job and sampler pass takes, for the console
        -- warning and /ch-diag.
        timing = timing,
        -- The settings changed from the admin panel, and the panel's own
        -- requests (server/panel.lua).
        settings = settings, panel = panel,
        -- Every line printed whatever Config.Debug says, kept as an alert
        -- for the panel and posted to Discord (server/alerts.lua).
        alerts = alerts,
        -- The expiry pass owns these; the bridge and contracts call them so
        -- it knows when a skip is no longer safe.
        scheduler = {
            presenceChanged = MarkPresenceChanged,
            contractsChanged = MarkContractsChanged,
        },
    }

    -- Nothing is answered until recovery has finished (App.ready).
    app.ready = false
    app.recoveryFailed = false

    --- Recovery that did not finish: the gate stays shut and the console says
    --- why. Everything between closing the gate and opening it is guarded so
    --- that a raise anywhere in it lands here (W151). It used to raise out of
    --- the start with the gate shut and recoveryFailed unset, so every request
    --- answered "busy, try again" for the life of the process, the commands
    --- said "try again in a moment", no maintenance tick ran, and the console
    --- said only "failed to start".
    local function recoveryFailed(err)
        app.recoveryFailed = true
        pcall(audit.flush)
        -- Money left as the last shutdown left it: whatever Config.Debug says.
        Log.always('============================================')
        Log.always('BOOT RECOVERY FAILED: ' .. tostring(err))
        Log.always('  What the last shutdown left part-way is not settled, so the app,')
        Log.always('  the login payouts and the staff commands that settle, void or')
        Log.always('  list escrow stay closed, and the maintenance tick does not start.')
        if Storage.timedOut and Storage.timedOut(err) then
            Log.always('  The database stopped answering during recovery; restart the')
            Log.always(('  resource once /%s says it answers.')
                :format(tostring(Config.Admin.Commands.diagnose)))
        else
            Log.always('  Fix the cause above, then restart the resource.')
        end
        Log.always('============================================')
        Log.reportProblems()
        Log.started()
        return modules
    end

    local wired, wireErr = pcall(function()
        app.init(modules)
        admin.init(modules)
        panel.init(modules)
        -- After the panel, whose scrub every post to Discord goes through.
        -- Every line this start said before it (the checks above, the store
        -- opening) waited in shared/log.lua and is kept now. Never raises.
        alerts.init(modules)
        CrimsonBoot.require('server.bridges').install(modules)

        -- Its own clock, faster than the maintenance tick: attribution is
        -- only as precise as the last condition sample. And when this start
        -- was, for a death reported again after it with its proof lost to
        -- the restart (Death.noteStarted).
        death.noteStarted()
        death.startSampler()
    end)
    if not wired then return recoveryFailed(wireErr) end

    -- A recovery that raises has left part of what the last shutdown left
    -- as it was: a line still `releasing`, a contract still mid-claim, a
    -- clock not paused for the downtime. Raised through, the boot said only
    -- "failed to start" and App.ready stayed down, so /ch-settle, /ch-void
    -- and /ch-stuck answered "try again in a moment" for as long as the
    -- process ran. The gate stays shut (the app, the login payouts, the
    -- maintenance tick and those commands), and the commands say what
    -- happened instead: only a restart once the cause is fixed runs
    -- recovery again.
    --
    -- First, the payments a database that stopped answering left undecided
    -- (S12, server/review.lua): every one the store or this machine's KVP
    -- keeps with its whole record is settled by the server from it now,
    -- before recovery, and the contract the server may still place holds its
    -- escrow, so recovery does not hand back what the server then places.
    -- One that cannot be decided yet stays for the maintenance tick.
    local decidedOk, decideErr = pcall(review.recoverSystem)
    if not decidedOk then
        Log.always(('settling the payments the database did not confirm failed: %s; each is '
            .. 'tried again by the maintenance tick (/%s)'):format(Util.dbError(decideErr),
            tostring(Config.Admin.Commands.stuck)))
    end
    local recovered, recoverErr = pcall(Recover)
    if not recovered then return recoveryFailed(recoverErr) end

    -- Kill photo files no record names any more. Before the app answers:
    -- a photo is written to its file a moment before its record, and a
    -- sweep that ran alongside a kill being verified would remove that one.
    -- Only while there are kill photos at all (Photos.inUse): with them off
    -- and none kept, data/photos is not touched.
    local swept, sweepErr = true, nil
    if photos.inUse() then swept, sweepErr = pcall(photos.sweepFiles) end
    if not swept then
        Log.debug(('the sweep of kill photo files failed: %s'):format(tostring(sweepErr)))
    end
    -- The two indexes below are rebuilt in memory, and every start rebuilds
    -- them again: one that raised is not worth keeping the app closed for,
    -- so the start goes on and says so (W151).
    local function reindexed(name, fn, meanwhile)
        local ok, err = pcall(fn)
        if not ok then
            Log.always(('rebuilding %s at start failed: %s; the server started anyway, and until '
                .. 'the next start %s'):format(name, Util.dbError(err), meanwhile))
        end
    end
    reindexed('the list of contracts with open proposed changes', amendments.reindex,
        'a change proposed before this start does not lapse on its own')
    -- An agreed change the last process stopped part-way through applying
    -- is closed as 'unknown', never applied a second time, and both sides
    -- are told to look at the contract (Amendments.recoverApplying).
    local closedOk, closedErr = pcall(amendments.recoverApplying)
    if not closedOk then
        Log.always(('closing agreed changes a restart cut off failed: %s; they stay closed to '
            .. 'answers and are looked at again on the next start'):format(Util.dbError(closedErr)))
    end
    -- Contracts already held when this process started, so an idle hold
    -- from before a restart is still one the sweep can see.
    reindexed('the list of held contracts', contracts.reindexHolds,
        'a hold taken before this start is not released for being idle')
    -- The wait before a target is shown a new contract, and their alert, are
    -- kept in memory: a contract placed inside the longest wait before this
    -- start is held back again for a fresh one, and its alert re-armed
    -- (Notify.rearm).
    reindexed('the waits before targets are told of new contracts', function()
        notify.rearm(Storage.liveContracts())
    end, 'a contract placed just before it is shown to its target at once, unannounced')
    -- Acceptance bulletins off at this start (config.lua, or the admin
    -- panel's setting applied above): what the whitelisted-job view says of
    -- each live contract's hitmen is unknown until one says it again
    -- (Notify.forgetAcceptances), as when staff turn them off.
    if not Util.advises('accepted') then
        reindexed('what the whitelisted-job view says of taken contracts', function()
            notify.forgetAcceptances(Storage.liveContracts())
        end, 'a contract on an officer taken while acceptance bulletins are off may be listed '
            .. 'as open once they are back on')
    end
    -- Reviews the last shutdown left part-way resolved, finished as staff
    -- decided them, now recovery has put back what their lines left.
    local reviewed, reviewErr = pcall(review.recover)
    if not reviewed then
        -- The review queue, left for staff: whatever Config.Debug says.
        Log.always(('finishing reviews left part-way failed: %s; /%s finishes each')
            :format(tostring(reviewErr), tostring(Config.Admin.Commands.review)))
    end
    app.ready = true
    StartTick()

    reportIntegrations()
    -- Loudly, and every boot, until somebody deals with it. This is what
    -- refusing to start used to buy — the operator's attention — bought
    -- without taking the whole resource down to get it.
    local held = Storage.quarantined and Storage.quarantined() or {}
    if #held > 0 then
        Log.always('============================================')
        Log.always(('%d CONTRACT(S) COULD NOT BE LOADED and are not '
            .. 'on the board:'):format(#held))
        for i = 1, #held do
            Log.always(('  %s  (%s)  %s')
                :format(held[i].id, held[i].reason, tostring(held[i].file)))
        end
        Log.always('  Each held escrow that cannot now be returned '
            .. 'automatically.')
        Log.always('  Restore those files from a backup and restart to '
            .. 'recover them,')
        Log.always('  or settle them by hand and remove their ids from '
            .. 'data/store.json.')
        Log.always('  This resource started without them rather than '
            .. 'not at all.')
        Log.always('============================================')
    end

    -- The configuration problems this start found: each in full with
    -- Config.Debug on (the admin panel's included, applied above), or one
    -- line for all of them, or nothing when there are none.
    Log.reportProblems()
    Log.debug(('started in %s mode'):format(Config.Database.Mode))
    Log.started()
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
    local lastAlive, datedFrom
    if Storage.lastHeartbeat then lastAlive, datedFrom = Storage.lastHeartbeat() end
    if lastAlive and lastAlive >= now then lastAlive = nil end
    -- The heartbeat file a crash did not leave whole (json): dated from
    -- what the store says instead, no later than the server went down.
    if lastAlive and datedFrom then
        Log.always(('the last heartbeat could not be read whole, so the downtime before this '
            .. 'start is dated from %s instead (%d second(s) ago); running contracts are paused '
            .. 'from then.'):format(tostring(datedFrom), now - lastAlive))
    end

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
                -- stuck forever: a line left `releasing` is money no code
                -- path can ever reach again. One that names who it was going
                -- to may have reached them (the name is written just before
                -- the give), and it used to be given again by the next
                -- login's retry: it is left for staff instead, owed to that
                -- player, given by nothing until they settle it
                -- (Escrow.parkInterrupted). Parked while it is still
                -- `releasing`, and only then put back: put back first, a boot
                -- that died or raised between the two left it held, owed,
                -- queued and not parked, and the next login gave it again.
                -- One that names nobody was never given, and goes on as
                -- before. Every one of these is logged with everything staff
                -- need to check it.
                --
                -- Through the claims in flight (Escrow.putBackStuck): read
                -- afresh, held in flight while it is parked and put back, and
                -- left alone if another call holds it. Put back from this
                -- read, whatever had claimed it since, a staff pay giving it
                -- was put back under its own give, queued again below and
                -- paid twice. Staff commands wait for recovery (App.ready);
                -- this holds even if one did not.
                local stuck, read = modules.escrow.putBackStuck(lines[j].id)
                if stuck then
                    local parked = read.releasing_to ~= nil
                    unstuck = unstuck + 1
                    Log.always(('escrow line %s was mid-release at shutdown; ' ..
                           'returned to held%s')
                           :format(tostring(read.id), parked
                               and (' and left for staff (/%s) — check whether it was already '
                                   .. 'paid'):format(tostring(Config.Admin.Commands.stuck))
                               or ''))
                    if modules.audit then
                        modules.audit.financial('release_interrupted', read.releasing_to,
                            contract.id, { line = read.id, amount = read.amount,
                                           review = true })
                    end
                end
            elseif line.state == CH.ESCROW_STATE.HELD and line.releasing_to
                and not modules.escrow.parked(line) then
                -- Put back to held without being parked: by an older version
                -- at an earlier start, or by one that put a line back before
                -- parking it and died in between (owed and still queued, it
                -- looked like any owed line). A held line names whom a give
                -- was going to only while that give may have happened: one
                -- that moved nothing clears it (Escrow.release). The same
                -- question, and it waited only in the log, which is pruned.
                -- Left for staff the same way, so /ch-stuck lists it from the
                -- escrow itself.
                modules.escrow.parkInterrupted(line)
            end
        end

        if contract.state == CH.STATE.COMPLETING then
            -- A claim caught part-way: a collection it had paid is moved on
            -- past and credited, a contract every collection of which was
            -- paid is finished, and anything else goes back to accepted so
            -- the normal path can run again (Contracts.recoverCompleting).
            -- The maintenance tick does the same to a claim that raised on
            -- the running server (Contracts.retryStuckClaims).
            local how = modules.contracts.recoverCompleting(contract, lines)
            if how == 'paid' or how == 'reopened' then
                recovered = recovered + 1
            elseif how then
                finished = finished + 1
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

        -- And an abandon it left part-way (Contracts.repairHeld): a stake
        -- still held under a row that walked away goes to the client, and an
        -- exclusive contract nobody holds goes back on the board.
        if (current.state == CH.STATE.ACTIVE or current.state == CH.STATE.ACCEPTED)
            and modules.contracts.repairHeld and modules.contracts.repairHeld(current.id) then
            recovered = recovered + 1
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
        Log.debug(('recovery: %d contracts resumed, %d finished, %d escrow '
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

--- How often a failure that needs staff (a write or money job below, or
--- the tick itself) is printed again when it fails on every tick: once a
--- few minutes, as a slow job is (server/timing.lua), so a database that
--- has gone away does not fill the console. Every failure in between is
--- still counted on the line the diagnosis keeps, and printed with Debug on.
local FAILURE_SAID_EVERY_SECONDS = 300
local failureSaidAt = {} -- [job name] = os.time() it was last printed

--- Say a failure that needs staff, at most once every
--- FAILURE_SAID_EVERY_SECONDS for the same job.
---@param name string the job, or 'tick' for the tick as a whole
---@param text string
local function sayFailure(name, text)
    local now = os.time()
    local last = failureSaidAt[name]
    if last and now - last < FAILURE_SAID_EVERY_SECONDS then
        return Log.debug(text)
    end
    failureSaidAt[name] = now
    Log.always(text)
end

function StartTick()
    CreateThread(function()
        while true do
            Wait(Config.Audit.FlushIntervalMs or 10000)
            -- The whole tick failing is every job above not run: escrow,
            -- buyouts and the flush with it. Said whatever Config.Debug
            -- says, at most once every few minutes (sayFailure).
            local ok, err = pcall(Tick)
            if not ok then sayFailure('tick', 'maintenance tick error: ' .. tostring(err)) end
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
--- Each job stands alone now. One that fails says so, and the others still
--- run.
---
--- And each is timed (server/timing.lua): one slower than
--- Config.Diagnostics.SlowJobMs says so in the console, and /ch-diag lists
--- the slowest.
--- Jobs whose failure is a write that did not happen, so data could be
--- lost, or money at risk (MONEY_JOBS): said whatever Config.Debug says, at
--- most once every FAILURE_SAID_EVERY_SECONDS each. Any other job's failure
--- is said with Debug on. Every one is kept for the diagnosis either way
--- (shared/log.lua).
local WRITE_JOBS = {
    ['audit.flush'] = true, ['storage.flush'] = true, ['storage.heartbeat'] = true,
    -- The review queue's items the store would not take when they opened.
    ['review.retryUnwritten'] = true,
}

--- Jobs whose failure is money at risk or left stuck: a buyout the target
--- has already paid, escrow held past a deadline or the lifetime, payouts
--- owed, an ending that raised, a placement or an acceptance a throw left
--- part-way, an exclusive hold nobody is working. Said whatever
--- Config.Debug says, like a failed write.
local MONEY_JOBS = {
    ['bailout.processQueue'] = true, ['expireContracts'] = true,
    ['escrow.retryWaiting'] = true, ['contracts.finishEndings'] = true,
    ['contracts.retryStuckCreates'] = true, ['contracts.retryStuckJoins'] = true,
    ['contracts.releaseIdleHolds'] = true, ['contracts.retryStuckClaims'] = true,
    -- A payment the database did not confirm, which the server settles.
    ['review.decide'] = true,
}

local function job(name, fn, ...)
    local ok, err = modules.timing.run(name, fn, ...)
    if not ok then
        local text = ('maintenance job %q failed: %s'):format(name, tostring(err))
        -- The database not answering (mysql) fails every job that asks it,
        -- every tick, and the store says when that starts and when it ends:
        -- with Debug on only, so those two lines bracket the outage.
        if Storage.timedOut and Storage.timedOut(err) then
            Log.debug(text)
        elseif WRITE_JOBS[name] or MONEY_JOBS[name] then
            sayFailure(name, text)
        else
            Log.debug(text)
        end
    end
    return ok
end

--- Hand over what was queued for players who are still online.
---
--- The login retry was the only thing that ever read the queue, while the
--- app told a player whose pockets were full to "make room and it will be
--- handed over". Told the same way the login retry tells them.
function RetryWaiting()
    local delivered, summaries = modules.escrow.retryWaiting(function(cid)
        return modules.identity.byCitizenId(cid) ~= nil
    end)
    for cid, count in pairs(delivered) do
        modules.notify.outstandingDelivered(cid, count, summaries and summaries[cid])
    end
    return delivered
end

--- How often notices kept past a player's budget are tried again: once the
--- minute that was full has opened (Notify.deliverKept).
local DELIVER_KEPT_EVERY_SECONDS = 60
local nextKept = 0

--- Contract notices that found their player past the per-minute budget,
--- sent once there is room, at most every DELIVER_KEPT_EVERY_SECONDS
--- (§14.40: coalesced, never dropped).
function DeliverKept()
    local now = os.time()
    if now < nextKept then return 0 end
    nextKept = now + DELIVER_KEPT_EVERY_SECONDS
    return modules.notify.deliverKept()
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

--- How often the maintenance tick looks for endings that stopped part-way
--- while it finds none. Staff are told such a line settles itself within a
--- minute (/ch-settle), which this and the tick's own interval have to keep
--- true; every tick, it was a read of the held escrow on mysql every ten
--- seconds for something that happens only when an ending raises.
local FINISH_ENDINGS_EVERY_SECONDS = 30
local nextFinish = 0

--- Endings that raised part-way on the running server, finished as the next
--- start would (Contracts.finishEndings), at most every
--- FINISH_ENDINGS_EVERY_SECONDS. Back next tick while it leaves any: more
--- than a pass takes, or one an ending or an acceptance still held.
function FinishEndings()
    local now = os.time()
    if now < nextFinish then return 0 end
    -- Marked before the call, like the photo retention: a pass that throws
    -- is not retried every tick.
    nextFinish = now + FINISH_ENDINGS_EVERY_SECONDS
    local finished, more = modules.contracts.finishEndings()
    if more then nextFinish = 0 end
    return finished
end

function Tick()
    job('audit.flush', modules.audit.flush)
    job('amendments.expire', modules.amendments.expire)
    job('bailout.processQueue', modules.bailout.processQueue)
    job('escrow.retryWaiting', RetryWaiting)
    if modules.notify.deliverKept then job('notify.deliverKept', DeliverKept) end
    -- Kill photos switched off (Config.Completion.KillPhotos): nothing below
    -- that is about them runs while none is kept, and nothing ever asks an
    -- image host. One kept from before still expires as usual.
    local photosInUse = modules.photos.inUse()
    if Util.killPhotos() or modules.photo.tokenCount() > 0 then
        job('photo.sweep', modules.photo.sweep)
    end

    local now = os.time()
    -- Only where photos come from a host. On 'server' storage the
    -- allowlist is never consulted, and with kill photos off nothing is:
    -- then the warning that no host is allowed is not one any more.
    local fromHost = Util.killPhotos() and Config.Completion.PhotoStorage == 'host'
    if not fromHost and modules.photo.clearHostProblem then modules.photo.clearHostProblem() end
    if fromHost and now - lastHostRefresh >= (Config.Completion.PhotoHostRefreshSeconds or 300) then
        -- Marked done whether or not the read succeeds: retrying a
        -- cross-resource config read every ten seconds because it failed
        -- once is how one broken export becomes a busy loop.
        lastHostRefresh = now
        job('photo.loadAllowedHosts', modules.photo.loadAllowedHosts)
    end
    job('death.sweep', modules.death.sweep)
    job('ratelimit.sweep', modules.ratelimit.sweep)
    if Storage.prune then job('storage.prune', Storage.prune) end
    if photosInUse then
        job('ledger.forgetOldPhotos', ForgetOldPhotos)
        -- A kill photo opened and never saved or deleted: the phone closed
        -- mid-view. It goes as if the client had chosen Delete.
        job('photos.expire', modules.photos.expire)
        -- A photo kept in the app past Config.Completion.KeptPhotoDays,
        -- where that is set.
        job('photos.forgetKept', modules.photos.forgetKept)
    end
    local app = CrimsonBoot.require('server.app')
    -- Who may have the app on their phone. Recomputed here rather than
    -- trusted to a job-change event whose name has differed across
    -- framework versions: a wrong name fails silently in the direction that
    -- costs a player the app with no way to ask for it back.
    local bridges = CrimsonBoot.require('server.bridges')
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
    -- A claim that raised part-way, left COMPLETING: finished as the next
    -- start would, once a statement still on its way has had time to land.
    if modules.contracts.retryStuckClaims then
        job('contracts.retryStuckClaims', modules.contracts.retryStuckClaims)
    end
    -- A contract a throw left undecided as it was placed: its escrow and
    -- fee back once the store answers, if it was not stored after all.
    if modules.contracts.retryStuckCreates then
        job('contracts.retryStuckCreates', modules.contracts.retryStuckCreates)
    end
    -- An item for staff the store would not take when it was opened.
    if modules.review then job('review.retryUnwritten', modules.review.retryUnwritten) end
    -- And a payment the database did not confirm, settled by the server
    -- from its whole record once the database answers (S12).
    if modules.review and modules.review.decide then job('review.decide', modules.review.decide) end
    job('expireContracts', ExpireContracts)
    -- A closed contract whose ending raised before it handed its escrow
    -- over: finished as the next start would (Contracts.finishEndings).
    if modules.contracts.finishEndings then job('contracts.finishEndings', FinishEndings) end
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

--- When the expiry pass last said that it could not update a contract, by
--- contract id: once every EXPIRY_FAILURE_SAID_EVERY seconds each, so one
--- the store keeps refusing is not a console line every tick.
local expiryFailureSaidAt = {}
local EXPIRY_FAILURE_SAID_EVERY = 600

--- One live contract's turn in the expiry pass. `pass` carries what the
--- pass works out across them: how many it resolved, and the soonest moment
--- worth waking for. Run in a pcall each, so one contract the store refuses
--- does not stop the pass for every contract after it.
---@param contract table as Storage.liveContracts listed it
---@param now integer
---@param pass table { resolved = integer, soonest = integer }
local function expireOne(contract, now, pass)
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
    if contract.state ~= CH.STATE.ACTIVE and contract.state ~= CH.STATE.ACCEPTED then return end

    -- A due contract whose ending was refused (a claim running on it, a
    -- write that did not land) is looked at again on the next tick, not
    -- after the longest skip.
    local function ended(ok)
        if ok then
            pass.resolved = pass.resolved + 1
        else
            pass.soonest = math.min(pass.soonest, now)
        end
    end

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
        ended(modules.contracts.resolve(contract.id, CH.STATE.EXPIRED,
            contract.creator_cid, nil, 'lifetime_exceeded',
            { forfeit = deadlinePassed and true or false,
              dueAt = now, byLifetime = true }))
        return
    end

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
    -- Whether the deadline has gone while the clock ran, asked before any
    -- pause. Once it has, nobody leaving or being jailed now stops the
    -- clock: a pause begun after the deadline turned an expiry into one
    -- the lifetime ended, which hands the hitman back a stake they had
    -- already lost, and left them on a card saying Due now with nothing
    -- they could do on it. Either order on its own — the expiry first,
    -- or the party gone with the deadline still to come and then passed
    -- — forfeits; the seconds between the deadline and this pass must
    -- too.
    local overdue = not contract.paused_since
        and contract.deadline_at ~= nil and now > contract.deadline_at
    -- A target in prison is as far out of reach as one who has
    -- logged off, and the hitman's clock ran on while they
    -- served their time.
    local jailed = Config.Limits.PauseWhileTargetJailed and targetActor ~= nil
        and not overdue and modules.identity.isJailed(targetActor)
    local targetAvailable = targetActor ~= nil and not jailed
    local paused = not overdue and not (creatorOnline and targetAvailable)

    -- A sentence the pass cannot count yet: the target not inside the
    -- prison grounds yet (driven there, a fade, a few seconds of lag), or
    -- the pause switched off. The sentence being written wakes one pass,
    -- and nothing wakes another when they arrive, so it looks again within
    -- a minute rather than after the longest skip, by when the deadline
    -- could have gone with them inside.
    if targetActor and not jailed and not overdue and modules.identity.serving(targetActor) then
        pass.soonest = math.min(pass.soonest, now + 60)
    end

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
        if targetActor and not targetAvailable then
            pass.soonest = math.min(pass.soonest, now + 60)
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
            pass.soonest = now
        elseif contract.deadline_at and now > contract.deadline_at then
            ended(modules.contracts.resolve(contract.id, CH.STATE.EXPIRED,
                contract.creator_cid, nil, 'expired', { dueAt = now }))
        elseif contract.deadline_at and contract.deadline_at < pass.soonest then
            pass.soonest = contract.deadline_at
        end
    end

    -- A paused contract's deadline is not running, but its
    -- absolute lifetime is.
    if contract.expires_at and contract.expires_at < pass.soonest then
        pass.soonest = contract.expires_at
    end
end

function ExpireContracts()
    local now = os.time()
    if not presenceChanged and now < nextDue then return 0 end
    presenceChanged = false

    -- Live contracts only, which is all the pass acts on. A read that
    -- raised forgot whatever woke this pass (a logoff, a sentence) until
    -- the next deadline, so it is remembered for the next tick.
    local read, contracts = pcall(Storage.liveContracts)
    if not read then
        presenceChanged = true
        error(contracts, 0)
    end

    -- The soonest future moment worth waking for. Starts far out and is
    -- pulled in by every live contract's deadline.
    local pass = { resolved = 0, soonest = now + (Config.Limits.MaxDeadlineSkipSeconds or 600) }

    for i = 1, #contracts do
        local ok, err = pcall(expireOne, contracts[i], now, pass)
        if not ok then
            -- A store that is not answering at all would make every
            -- contract after this one wait out the same timeout: the pass
            -- stops, and the next tick runs it again.
            if Storage.timedOut and Storage.timedOut(err) then
                presenceChanged = true
                error(err, 0)
            end
            local id = tostring(contracts[i] and contracts[i].id)
            local last = expiryFailureSaidAt[id]
            if last == nil or now - last >= EXPIRY_FAILURE_SAID_EVERY then
                for seen, at in pairs(expiryFailureSaidAt) do
                    if now - at >= EXPIRY_FAILURE_SAID_EVERY then expiryFailureSaidAt[seen] = nil end
                end
                expiryFailureSaidAt[id] = now
                Log.always(('expiry pass: contract %s could not be updated (%s); the others went '
                    .. 'on, and it is tried again within a minute'):format(id, Util.dbError(err)))
            end
            pass.soonest = math.min(pass.soonest, now + 60)
        end
    end

    -- One second past the earliest deadline, so the pass that wakes for it
    -- finds it genuinely overdue rather than exactly due.
    nextDue = pass.soonest + 1
    return pass.resolved
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
    -- The alerts not yet in the store, the same way (Alerts.flush).
    if modules.alerts then pcall(modules.alerts.flush, true) end

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

    -- The last moment anybody could play, to the second. Only from an app
    -- that was open: while recovery runs, or after it failed, the app was
    -- closed, and the heartbeat Recover goes by stands at the last moment it
    -- served. Written at this stop, the next start charged the whole outage
    -- (the crash, the failed boot, the time staff took to fix it) to every
    -- deadline Recover had not yet paused, and a contract that fell due in
    -- it expired at the first tick with the hitman's stake forfeited (W150).
    local served = modules.app and modules.app.ready == true and not modules.app.recoveryFailed
    if served and Storage and Storage.heartbeat then pcall(Storage.heartbeat, os.time()) end
    if Storage and Storage.close then Storage.close() end
end)

return {
    start = StartCrimsonHitman, recover = Recover, tick = Tick, expire = ExpireContracts,
    forgetOldPhotos = ForgetOldPhotos, finishEndings = FinishEndings,
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
    -- The same checks against a copy, as the admin panel's settings run them.
    checkCandidate = checkCandidate,
}
