--- Crimson Bounty System — configuration.
--- Every value here is read by the resource. Nothing in this file is sent
--- to a client except through an explicit projection (server/projection.lua).
---
--- A setting that does nothing is worse than no setting at all: an owner
--- tunes it and gets silence. Anything that stops being read should be
--- deleted from here in the same change.

Config = Config or {}

--------------------------------------------------------------------------
-- Access (§2)
--------------------------------------------------------------------------

--- Job *types* barred from the app. Blocking by type is what stops a newly
--- added LEO job from silently gaining access.
Config.BlockedJobTypes = {
    leo = true, police = true, ems = true, fire = true,
}

--- Job *names* barred from the app, as a belt-and-braces list alongside the
--- types above. Sourced from this server's sc-police / sc-dispatch configs.
Config.BlockedJobNames = {
    police = true, sheriff = true, leo = true, trooper = true, sasp = true,
    bcso = true, fib = true, ranger = true, doj = true, lawyer = true,
    ambulance = true, fire = true,
}

--- Off-duty players are still blocked by default: a police officer who clocks
--- off is still a police officer to everyone they arrested this week.
Config.BlockOffDuty = true

--------------------------------------------------------------------------
-- Reward sources (§3.4)
--------------------------------------------------------------------------

Config.Sources = {
    cash   = { enabled = true,  max = 250000 },
    bank   = { enabled = true,  max = 500000 },
    dirty  = { enabled = true,  max = 250000, item = 'black_money' },
    item   = { enabled = true,  maxStacks = 10, maxPerStack = 100 },
    weapon = { enabled = true,  max = 3 },
}

--- Total escrow value ceiling across all sources, money-equivalent.
Config.MaxContractValue = 1000000

--- Items that may never be escrowed, whatever the creator selects.
Config.EscrowBlacklist = {
    ['phone'] = true, ['id_card'] = true, ['driver_license'] = true,
    ['weaponlicense'] = true, ['handcuffs'] = true,
}

--- Kidnapping bonus. Percentage applies per money source; items are extra
--- lines escrowed alongside the baseline.
Config.Bonus = {
    --- Ceiling on the kidnapping bonus percentage a creator may set.
    maxPercent = 200,
}

--------------------------------------------------------------------------
-- Payout currency (§14.10)
--------------------------------------------------------------------------

Config.Payout = {
    --- Escrow pays out in exactly the sources it holds. Leave this false.
    --- Turning it on lets a creator escrow clean money and have it paid as
    --- dirty money, which on this server is a laundering rail: sc-blackmarket
    --- prices dirty money at 0.85, making it worth ~1.18x clean.
    AllowConversion = false,
    --- Conversion rate applied when AllowConversion is on. Matched to
    --- sc-blackmarket's BlackMoneyRate so converting is value-neutral, never
    --- profitable.
    DirtyConversionRate = 0.85,
}

--------------------------------------------------------------------------
-- Anonymity (§4)
--------------------------------------------------------------------------

Config.Anonymity = {
    CreatorFee = 0,          -- flat fee, 0 = free
    HunterFee  = 0,
    FeeAccount = 'bank',     -- 'cash' | 'bank'
}

--------------------------------------------------------------------------
-- Bailout (§5, §14.16, §14.17)
--------------------------------------------------------------------------

Config.Bailout = {
    Enabled = true,
    --- The creator names the premium, but the server clamps it to a multiple
    --- of the escrow value so the bailout cannot be used as an uncapped,
    --- untaxed transfer rail between two cooperating players.
    MinMultiplier = 1.0,
    MaxMultiplier = 3.0,
    AbsoluteMax = 500000,
    --- A bailout does not resolve instantly once a hunter is engaged: the
    --- hunter gets this long to complete before it takes effect, so a target
    --- cannot rug-pull a hunter mid-fight.
    ProcessingDelaySeconds = 120,
    --- Bailout is blocked while the target is dead or in last stand.
    BlockWhileIncapacitated = true,
}

--------------------------------------------------------------------------
-- Limits and cooldowns (§9.5, §12.5, §13)
--------------------------------------------------------------------------

Config.Limits = {
    MaxActiveContractsPerCreator = 3,
    MaxAcceptedPerHunter         = 3,
    MaxActiveContractsPerTarget  = 2,
    MaxHuntersPerContract        = 5,

    --- How many times one contract may be collected. Each slot carries its
    --- own reward set and all of them are escrowed at creation.
    MaxPayoutSlots               = 5,
    --- The same hunter may not claim two slots inside this window. Without
    --- it a multi-slot contract becomes a respawn-camping machine.
    SlotCooldownSeconds          = 600,

    TargetCooldownAfterResolveSeconds = 1800,
    SameCreatorSameTargetCooldownSeconds = 7200,

    ContractLifetimeSeconds = 172800,   -- absolute ceiling, pause included
    DefaultDeadlineSeconds  = 10800,
}

Config.Cooldowns = {
    create    = { per = 60, burst = 2 },
    accept    = { per = 30, burst = 3 },
    bailout   = { per = 60, burst = 1 },
    informant = { per = 300, burst = 1 },
    message   = { per = 5,  burst = 5 },
    amend     = { per = 30, burst = 3 },
    search    = { per = 10, burst = 5 },
    photo     = { per = 15, burst = 3 },
    --- Death and revive reports are client-driven and each one walks the
    --- contract table, so they are throttled like everything else.
    death     = { per = 5,  burst = 4 },
    mugshot   = { per = 60, burst = 3 },
}

--------------------------------------------------------------------------
-- Target eligibility and immunity (§14.19, §14.39)
--------------------------------------------------------------------------

Config.Immunity = {
    MinTargetPlaytimeHours   = 5,
    MinTargetSessionMinutes  = 10,
    PostRespawnSeconds       = 300,
    AfterBailoutSeconds      = 3600,
    --- Unresolvable playtime counts as below every minimum.
    FailClosed = true,
}

--------------------------------------------------------------------------
-- Completion (§7.4, §14.2, §14.20)
--------------------------------------------------------------------------

Config.Completion = {
    --- Elimination requires a genuine death. A player who is merely downed
    --- or bleeding out is not a kill, and this is re-checked when the proof
    --- photo is submitted, not only when the death is reported.
    RejectLastStand    = true,

    --- Server-side death state providers, tried in order. Each entry is
    --- { resource, deadExport, lastStandExport }.
    DeathStateProviders = {
        { resource = 'sc-ambulance', dead = 'IsDead', lastStand = 'IsLaststand' },
        { resource = 'qbx_medical',  dead = 'IsDead', lastStand = 'IsLaststand' },
    },
    DeathReportWindowMs = 30000,
    MaxWeaponRange      = 250.0,
    PhotoRadius         = 5.0,
    PhotoTokenLifetimeSeconds = 120,
    --- How long after a death the proof is still accepted even if the target
    --- is back on their feet.
    ---
    --- Without this the elimination path barely works: players respawn in
    --- seconds, and a hunter standing over the body would lose the payout to
    --- the target pressing respawn. The kill genuinely happened, the hunter
    --- is still at the recorded scene, and the window is short.
    ProofWindowSeconds = 60,
    --- A photo URL is accepted only from the host lb-phone uploads to.
    --- Populated at boot from lb-phone's own upload config; entries here are
    --- added to that set.
    ExtraPhotoHosts = {},
}

Config.Kidnap = {
    CountdownSeconds   = 30,
    Radius             = 12.0,
    MaxTotalGraceMs    = 3000,
    TickMs             = 1000,
    MaxConcurrentCountdowns = 20,
    --- A kidnapping is a *live* delivery. The target must be conscious the
    --- whole way: not dead, not downed / bleeding out, and above the health
    --- floor. Both states are re-checked on every countdown sample, so a
    --- target who dies or goes down mid-countdown fails the delivery.
    RequireConscious   = true,
    RejectDead         = true,
    RejectLastStand    = true,
    MinTargetHealthPercent = 20,
    --- Observable coercion: the target must be restrained or under the
    --- hunter's physical control. Any enabled detector satisfies it.
    RequireCoercion    = true,
    Coercion = {
        handcuffed        = true,   -- QBox metadata 'ishandcuffed'
        passengerOfHunter = true,   -- target is in the hunter's vehicle
    },
    --- Optional resource exposing IsRestrained(playerId) for custom rope /
    --- ziptie scripts. Leave nil if unused.
    RestraintProvider  = nil,
}

--------------------------------------------------------------------------
-- Tracking, mugshots and listings (§14.22, §14.26, §14.33)
--------------------------------------------------------------------------

Config.Mugshot = {
    MinRefreshMinutes = 5,
    RenderTimeoutMs = 8000,
    --- A base64 headshot arrives from a player's client, so it is bounded
    --- and format-checked before it is cached and shown to anyone else.
    --- A real MugShotBase64 headshot is comfortably under this.
    MaxImageBytes = 49152,
    --- An explicit allowlist: a pattern match on the MIME type would also
    --- accept image/svg+xml, which is not a headshot.
    AllowedMime = {
        ['image/png'] = true, ['image/jpeg'] = true, ['image/webp'] = true,
    },
}

Config.Listing = {
    PageSize = 15,
}

Config.Targeting = {
    --- Long enough that the search is a lookup rather than an enumeration.
    MinQueryLength = 4,
    MaxResults = 5,
    --- Protected-job players may be targeted by default: hunting a cop is
    --- legitimate criminal roleplay. What makes it fair is the advisory
    --- below, not a ban. Set false to refuse creation instead.
    AllowProtectedJobTargets = true,
}

--------------------------------------------------------------------------
-- Law enforcement threat advisory (§7.5)
--------------------------------------------------------------------------

Config.Advisory = {
    Enabled = true,
    --- Job types that trigger an advisory when targeted.
    TriggerJobTypes = { leo = true, police = true, ems = true, fire = true },
    --- Job names that trigger one, for jobs with an unusual type.
    TriggerJobNames = { doj = true, lawyer = true, ranger = true },
    --- Who receives the advisory. Law enforcement only by default; EMS are
    --- not a response unit for a contract killing.
    RecipientJobTypes = { leo = true, police = true },
    RecipientJobNames = {
        police = true, sheriff = true, bcso = true, fib = true,
        trooper = true, sasp = true, ranger = true,
    },
    --- Also raise a dispatch entry through sc-dispatch when present.
    UseDispatch = true,
    DispatchPriority = 1,
    --- The targeted officer is always told, whatever the paranoid-alert
    --- setting says — they cannot open the app to check for themselves.
    AlwaysAlertTarget = true,
    --- Warn the creator before escrow is taken, and the hunter before they
    --- accept, that the target is law enforcement. The listing also carries a
    --- permanent flag. Nobody hunts a cop by accident.
    --- Advisories fire at creation and again on the first acceptance, so
    --- the department learns both that a threat exists and that it went
    --- live. Later acceptances on a competitive contract stay silent.
    OnCreate = true,
    OnAccept = true,
    WarnCreator = true,
    WarnHunter = true,
    FlagListing = true,
}

--------------------------------------------------------------------------
-- Reason text and relay (§11.4, §14.30)
--------------------------------------------------------------------------

Config.Reason = {
    Mode = 'freetext',          -- 'preset' | 'freetext' | 'off'
    MaxLength = 140,
    MaxDigits = 6,
    Presets = {
        'Unpaid debt', 'Snitching', 'Territory dispute', 'Stolen product',
        'Disrespect', 'Broken deal',
    },
    PatternDenylist = { 'https?://', 'discord%.gg', 'www%.', '@%w+' },
}

Config.Relay = {
    Enabled = true,
    MaxLength = 200,
    AllowMaskedCalls = true,
}

--------------------------------------------------------------------------
-- Amendments (§12)
--------------------------------------------------------------------------

Config.Amendments = {
    Enabled = true,
    ProposalExpirySeconds = 300,
    MaxOpenPerContract = 1,
    CancelCooldownSeconds = 300,
}

--------------------------------------------------------------------------
-- Informant and ledger (§6.1, §6.3)
--------------------------------------------------------------------------

Config.Informant = {
    Enabled = true,
    Cost = 25000,
    Account = 'bank',
    RevealMode = 'name',        -- 'name' | 'description'
    RerollLockMinutes = 30,
    MaxPurchasesPerContract = 2,
}

Config.Ledger = {
    Depth = 10,
    MaxDepthHardCap = 25,
    StorePhotos = true,
    ShowPhotoToTarget = false,
}

--------------------------------------------------------------------------
-- Notifications (§7.3, §14.40)
--------------------------------------------------------------------------

Config.Notifications = {
    ParanoidAlert = true,
    MaxPerRecipientPerMinute = 6,
    MaxPerRecipientPerHour = 40,
}

--------------------------------------------------------------------------
-- Persistence (§10)
--------------------------------------------------------------------------

Config.Database = {
    Mode = 'mysql',             -- 'mysql' | 'json' | 'memory'
    Json = {
        Directory = 'data',
        SyncOnFinancialWrite = true,
        WarnContractCount = 2000,
    },
}

Config.PendingEscrow = {
    MaxRetriesPerLogin = 5,
    --- Randomised slightly in code so a reconnect wave does not converge.
    LoginRetryDelayMs = 5000,
}

--------------------------------------------------------------------------
-- Audit (§9.8, §14.31)
--------------------------------------------------------------------------

Config.Audit = {
    LogAllActions = true,
    LogReasonText = true,
    FlushIntervalMs = 10000,
    MaxQueueSize = 5000,
    RetentionDays = 30,
    --- Optional staff webhook. Financial movements and rejected attempts are
    --- mirrored as a heads-up; identity is never included, because anything
    --- sent to a third party outlives this server's retention rules.
    Webhook = false,
}

Config.AntiCollusion = {
    --- Compares creator / hunter / target account identifiers. A shared
    --- account is blocked outright. Households are deliberately not
    --- considered: families and roommates share a connection, and blocking
    --- or flagging them would punish ordinary players.
    BlockSameAccount = true,
}

--------------------------------------------------------------------------
-- Progression
--------------------------------------------------------------------------

--- Completing a contract feeds the server's existing criminal progression,
--- so the bounty board is part of the criminal economy rather than a
--- parallel one. Disabled automatically if the resource is not running.
Config.Progression = {
    Enabled = true,
    Resource = 'sc-blackmarket',
    TrustPerElimination = 10,
    TrustPerKidnapping  = 20,
}

Config.Debug = false

return Config
