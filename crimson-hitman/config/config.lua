--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                        CRIMSON HITMAN CONFIGURATION                       ║
    ║                lb-phone contract app for Qbox - Crimson RP                ║
    ╚═══════════════════════════════════════════════════════════════════════════╝

    The one file to edit. Every setting is here with a one-line note; the
    full explanation of each is in README.md, "Configuration reference",
    under the same section title. Most can also be changed live in the
    admin panel (/hitmanadmin), which keeps them across restarts.

    Every player's game downloads this file, so never put a secret in it:
    the Discord webhooks are server.cfg convars (README, Admin panel).
]]

Config = Config or {}

-- ============================================================================
--                             DEBUG AND STORAGE
-- ============================================================================
-- The two settings checked first: the console output, and where contracts
-- and money are kept. Switching storage mode starts empty in the new one
-- and refuses to start while the old one still holds money (README).

Config.Debug = true  -- debug lines in the server console and F8; false = only what needs you

Config.Database = {
    Mode                = 'mysql', -- 'json' | 'mysql' | 'memory' (testing only)
    AllowModeSwitch     = false,   -- start even though the old mode still holds money
    QueryTimeoutSeconds = 10,      -- mysql: seconds a statement may go unanswered; 0 = forever
    Json                = {
        Directory              = 'data',  -- folder inside the resource
        SyncOnFinancialWrite   = true,    -- write money changes to disk at once
        WarnContractCount      = 2000,    -- warn above this many contracts
        MaxDirtyShardsPerFlush = 25,      -- contract files one ordinary flush writes
    },
}

-- ============================================================================
--                                   ACCESS
-- ============================================================================
-- Who may open the app. Law enforcement, EMS, fire and legal jobs are barred,
-- by job type as well as by name, so a new police job is barred with no edit.
-- With the whitelisted-job view on they get one read-only screen instead.

Config.BlockedJobTypes = { -- job types barred from the app
    leo = true, police = true, ems = true, fire = true,
}

Config.BlockedJobNames = { -- job names barred from the app, alongside the types
    police = true, sheriff = true, leo = true, trooper = true, sasp = true,
    bcso = true, fib = true, ranger = true, doj = true, lawyer = true,
    sast = true, k9 = true, ambulance = true, fire = true,
}

Config.BlockOffDuty           = true  -- barred jobs stay barred off duty
Config.HideAppFromBlockedJobs = true  -- hide the icon from barred jobs (only while the view below is off)

Config.WhitelistedView = {
    Enabled = true,  -- barred jobs see one read-only screen: the contracts on them
    Alerts  = true,  -- they may turn on Notify me for new entries there
}

Config.App = {
    DefaultInstalled = false,  -- true = on every eligible home screen; false = in the App Store
}

-- ============================================================================
--                          COMPLETION AND HANDOVERS
-- ============================================================================
-- How a contract is finished. As shipped it is live transfer only: the hitman
-- brings the target alive to the person who placed the contract, and both stay
-- within Radius of them for CountdownSeconds. No restraint is required.

Config.Completion = {
    Fulfilment                = 'alive',   -- 'alive' (live handover only) | 'either' (a kill completes too)
    KillPhotos                = false,     -- under 'either': true = a photo, false = checked at the scene
    PhotoStorage              = 'server',  -- 'server' (file in data/photos) | 'host' (lb-phone's image host)
    PhotoPublicUrl            = nil,       -- 'server': https address for Save to Photos; nil = web_baseUrl
    KeptPhotoDays             = nil,       -- days a photo kept in the app lasts; nil = until deleted
    ProofWindowSeconds        = 60,        -- a kill still verifies this long after death, the target back up
    PhotoTokenLifetimeSeconds = 120,       -- seconds a kill waits to be verified
    PhotoRadius               = 5.0,       -- metres from the body to verify a kill
    PhotoOpenSeconds          = 600,       -- seconds the client may view a photo before it is deleted
}

Config.Kidnap = {
    CountdownSeconds       = 30,     -- seconds the handover is held
    Radius                 = 12.0,   -- metres: target, hitman and placer within this of each other
    RequireCoercion        = false,  -- true = the target must also be cuffed or in the hitman's vehicle
    Coercion               = { -- what counts as restrained while RequireCoercion is on
        handcuffed        = true,  -- QBox metadata 'ishandcuffed'
        passengerOfHitman = true,  -- target in the hitman's vehicle
    },
    RestraintProvider      = nil,    -- resource exporting IsRestrained(playerId), or nil
    MeetingPoint           = true,   -- the placer may set a meeting point for the hitmen
    RequireConscious       = true,   -- target conscious the whole time (always under 'alive')
    RejectDead             = true,   -- refuse a dead target (always under 'alive')
    RejectLastStand        = true,   -- refuse a downed target
    MinTargetHealthPercent = 20,     -- refuse a target hurt below this
    RearmCooldownSeconds   = 60,     -- wait after a failed handover before arming again
}

-- ============================================================================
--                             REWARDS AND LIMITS
-- ============================================================================
-- What a reward may be made of, how big it may be, and how many contracts a
-- player may place, take or carry. Every reward is held in escrow until the
-- contract ends.

Config.Sources = { -- what a reward may be paid in, and the most of each
    cash   = { enabled = true,  max = 250000 },                        -- cash, at most this much
    bank   = { enabled = true,  max = 500000 },                        -- bank money
    dirty  = { enabled = true,  max = 250000, item = 'black_money' },  -- dirty money, as this item
    item   = { enabled = true,  maxStacks = 10, maxPerStack = 100 },   -- items: stacks, and per stack
    weapon = { enabled = true,  max = 3 },                             -- weapons
}

Config.MaxContractValue = 1000000  -- most a contract may hold, in money

Config.EscrowBlacklist = { -- items that may never be put in a reward
    ['phone'] = true, ['id_card'] = true, ['driver_license'] = true,
    ['weaponlicense'] = true, ['handcuffs'] = true,
    ['identification'] = true, ['lawyerpass'] = true, ['money'] = true,
}

Config.Limits = {
    MaxPayoutSlots                       = 1,       -- each contract pays out once
    MinContractReward                    = 1000,    -- least a reward may be worth in money; 0 = off
    MaxActiveContractsPerCreator         = 3,       -- live contracts one player may place
    MaxAcceptedPerHitman                 = 3,       -- live contracts one hitman may hold
    MaxActiveContractsPerTarget          = 2,       -- live contracts on one person
    MaxHitmenPerContract                 = 5,       -- hitmen on one competitive contract
    DefaultDeadlineSeconds               = 10800,   -- run time; runs only with placer, target, operative in
    ContractLifetimeSeconds              = 172800,  -- hard ceiling, pauses included
    TargetCooldownAfterResolveSeconds    = 1800,    -- nobody may target a person again for this long
    SameCreatorSameTargetCooldownSeconds = 7200,    -- the same placer on the same target
    SlotCooldownSeconds                  = 600,     -- a hitman's wait between two payouts on one contract
    ExclusiveIdleReleaseSeconds          = 1800,    -- release an exclusive hitman never near them; 0 = off
    ExclusiveAttemptWindowSeconds        = 7200,    -- release one who never makes an attempt; 0 = off
    PauseWhileTargetJailed               = true,    -- the deadline stops while the target serves time
    JailZone                             = { x = 1693.3, y = 2569.5, radius = 300 },  -- the prison grounds
}

Config.Restart = {
    PauseBeforeSeconds = 1800,  -- pause every contract this long before a txAdmin restart; 0 = off
    MaxHoldMinutes     = 45,    -- end the pause if the restart has not come by then
}

Config.Bonus = {
    maxPercent = 200,  -- under 'either': most a kidnapping bonus may add
}

Config.Penalty = {
    MaxAmount                 = 100000,  -- most stake a hitman may be asked for
    MaxFractionOfEscrow       = 2.0,     -- and at most this times the reward
    RequireDisclosureOnAccept = true,    -- accept must echo the stake it was shown
    MinWindowMinutes          = 30,      -- no staked accept with less than this left
}

Config.Anonymity = {
    CreatorFee = 0,       -- fee to place anonymously; 0 = free
    HitmanFee  = 0,       -- fee to accept anonymously; 0 = free
    FeeAccount = 'bank',  -- 'cash' | 'bank'
}

Config.Amendments = {
    Enabled               = true,  -- placer and hitman may agree changes to a contract
    ProposalExpirySeconds = 300,   -- a proposal lapses after this
    MaxOpenPerContract    = 1,     -- proposals open at once
    CancelCooldownSeconds = 300,   -- wait after cancelling before another
}

-- ============================================================================
--                                  BUYOUTS
-- ============================================================================
-- What a target can pay for: buying the contract out, and a look-up on who
-- is after them. The placer's look-up on who took their contract. And what a
-- hitman can pay for: an informant tip, the rough area the target was in
-- when it was bought.

Config.Bailout = {
    Enabled                 = true,       -- a target may buy out a contract on them
    MinMultiplier           = 1.0,        -- least buyout price, times the reward
    MaxMultiplier           = 3.0,        -- most buyout price, times the reward
    AbsoluteMax             = 500000,     -- most buyout price in money
    ProcessingDelaySeconds  = 120,        -- a held contract's hitman gets this long first
    BlockWhileIncapacitated = true,       -- no buyout while dead or downed
    Command                 = 'cleanse',  -- the buyout command, for players who cannot open the app
}

Config.Informant = {
    Enabled                 = true,    -- a target may pay to find out who is after them
    Cost                    = 25000,   -- price of one look-up, paid win or lose; 0 = free
    Account                 = 'bank',  -- 'cash' | 'bank'
    RevealMode              = 'name',  -- 'name' | 'description'
    RevealChancePercent     = 10,      -- chance one look-up finds out who it is, 0-100
    ProximityRadius         = 120.0,   -- metres that count as near (an idle hold's clock)
    RerollLockMinutes       = 30,      -- the same pick again this soon repeats the answer, free
    MaxPurchasesPerContract = 2,       -- look-ups per target per contract, both kinds
}

Config.PlacerInformant = {
    Enabled                 = true,    -- the placer may pay to find out who took it
    Cost                    = 25000,   -- price of one look-up, paid win or lose; 0 = free
    Account                 = 'bank',  -- 'cash' | 'bank'
    RevealChancePercent     = 20,      -- chance one look-up names the operative, 0-100
    AlertChancePercent      = 20,      -- chance a named operative is told, 0-100
    RevealMode              = 'name',  -- 'name' | 'description'
    MaxPurchasesPerContract = 2,       -- look-ups per placer per contract
    CooldownMinutes         = 10,      -- wait between two look-ups
}

Config.LocationTip = {
    Enabled                 = true,    -- a hitman on a contract may buy the target's rough area
    Cost                    = 25000,   -- price; 0 = free
    Account                 = 'bank',  -- 'cash' | 'bank'
    RadiusMeters            = 350,     -- metres; the area shown is twice this across
    ShowMinutes             = 10,      -- minutes the area stays on the hitman's map
    CooldownMinutes         = 10,      -- minutes between two tips on one contract
    MaxPurchasesPerContract = 3,       -- tips per hitman per contract
    NotifyTarget            = true,    -- tell the target someone knows their rough area
}

-- ============================================================================
--                                 TARGETING
-- ============================================================================
-- Who can be named as a target, how a placer finds them, what the board shows
-- and what may be written as the reason.

Config.Targeting = {
    MinQueryLength           = 3,      -- letters before a name search runs
    MaxResults               = 8,      -- names a search returns
    AllowBrowseAll           = true,   -- list everyone online by name
    BrowsePageSize           = 30,     -- names per page when browsing
    AllowNearby              = false,  -- list the people around the placer (names people: keep off)
    NearbyRadius             = 30.0,   -- metres for the nearby list
    MaxNearby                = 12,     -- names in the nearby list
    NearbyClosedAfterSeconds = 1800,   -- nearby list closed to a contract's parties after it ends
    AllowProtectedJobTargets = true,   -- officers may be targeted (the advisory tells them)
}

Config.Immunity = {
    MinTargetPlaytimeHours  = 5,     -- hours played before anyone can be a target; 0 = off
    MinTargetSessionMinutes = 10,    -- and this many minutes in the city this session
    PostRespawnSeconds      = 300,   -- protected this long after a respawn (not from a handover)
    AfterBailoutSeconds     = 3600,  -- nobody may target them again this long after a buyout
    PlaytimeProvider        = nil,   -- { resource, export } answering total minutes; nil = counted here
    GrandfatherDays         = 3,     -- only without qbx_core's players table: days of grandfathering
}

Config.Mugshot = {
    Enabled          = true,   -- target headshots on the board
    RemoveBackground = false,  -- cut out the background (heavy on the target's game)
}

Config.Reason = {
    Mode            = 'freetext',  -- 'preset' | 'freetext' | 'off'
    MaxLength       = 140,         -- characters (255 at most on mysql)
    MaxDigits       = 6,           -- digits allowed, so no phone numbers
    Presets         = { -- the choices in 'preset' mode
        'Unpaid debt', 'Snitching', 'Territory dispute', 'Stolen product',
        'Disrespect', 'Broken deal',
    },
    PatternDenylist = { -- Lua patterns a reason may not contain
        'https?://', 'discord%.gg', 'www%.', '@%w+',
    },
}

-- ============================================================================
--                               NOTIFICATIONS
-- ============================================================================
-- Phone notices, the advisory officers get when one of them is targeted, and
-- the anonymous messages and calls between the parties.

Config.Notifications = {
    ParanoidAlert            = true,                     -- the target is told "You feel eyes on you"
    ParanoidAlertJitter      = { min = 60, max = 600 },  -- seconds it waits, drawn at random
    ParanoidCooldownMinutes  = 30,                       -- at most one such alert per target in this long
    MaxPerRecipientPerMinute = 6,                        -- notices one player may get a minute
    MaxPerRecipientPerHour   = 40,                       -- and an hour
    PushEnabled              = true,                     -- refresh an open app when its contract changes
    PushMinIntervalSeconds   = 1,                        -- least time between two refreshes
}

Config.Advisory = {
    Enabled           = true,                           -- officers are told when one of them is targeted
    TriggerJobTypes   = { -- job types that raise one
        leo = true, police = true, ems = true, fire = true,
    },
    TriggerJobNames   = { -- job names that raise one (every barred name)
        doj = true, lawyer = true, ranger = true, sast = true, fib = true, k9 = true,
        police = true, sheriff = true, leo = true, trooper = true, sasp = true,
        bcso = true, ambulance = true, fire = true,
    },
    RecipientJobTypes = { leo = true, police = true },  -- job types told
    RecipientJobNames = { -- job names told
        police = true, sheriff = true, bcso = true, fib = true,
        trooper = true, sasp = true, ranger = true, sast = true, k9 = true,
    },
    UseDispatch       = true,                           -- also raise an sc-dispatch entry
    DispatchPriority  = 1,                              -- its priority
    AlwaysAlertTarget = true,                           -- the targeted officer is always told
    OnCreate          = true,                           -- a bulletin when a contract is placed
    OnAccept          = true,                           -- and when each hitman accepts
    OnLocationTip     = true,                           -- and when a hitman buys an informant tip
    OnCancel          = true,                           -- and when one on an officer is called off
    WarnCreator       = true,                           -- warn the placer before escrow is taken
    WarnHitman        = true,                           -- warn the hitman before they accept
    FlagListing       = true,                           -- mark the card on the board
}

Config.Relay = {
    Enabled                    = true,  -- anonymous messages between the parties
    MaxLength                  = 200,   -- characters a message (255 at most on mysql)
    MaxMessagesPerThread       = 100,   -- newest messages a thread keeps
    AllowMaskedCalls           = true,  -- calls with the caller's alias shown
    CallExport                 = nil,   -- your own call export { resource, export }; nil = lb-phone's
    RequireMaskingForAnonymous = true,  -- no call for an anonymous party the phone cannot mask
}

-- ============================================================================
--                                ADMIN PANEL
-- ============================================================================
-- Staff tools: /hitmanadmin and the F8 commands. Discord webhooks are set in
-- server.cfg with set (never setr), never here: see the README.

Config.Admin = {
    Enabled             = true,                -- the staff commands and the admin panel
    Ace                 = 'crimson.admin',     -- ACE for staff, and for anything that writes
    IdentityAce         = 'crimson.identity',  -- ACE to see who is behind an anonymous party
    ExtraAces           = { 'command' },       -- ACEs that may also read (never write)
    Commands            = { -- command names, without the slash
        timeline  = 'ch-timeline',   -- one contract's history
        void      = 'ch-void',       -- close a contract and refund it
        stuck     = 'ch-stuck',      -- money waiting for staff
        settle    = 'ch-settle',     -- settle a payout left for staff
        whois     = 'ch-whois',      -- who is behind an anonymous party
        contracts = 'ch-contracts',  -- a player's contracts, with their ids
        diagnose  = 'ch-diag',       -- why the app is not showing something
        refresh   = 'ch-refresh',    -- bring every wait forward, for a test server
        review    = 'ch-review',     -- the review queue
        panel     = 'hitmanadmin',   -- the admin panel
    },
    PanelPageSize       = 25,                  -- rows per page in the panel's lists
    PanelRefreshSeconds = 10,                  -- how often the overview refreshes
    TimelineRows        = 200,                 -- audit rows read for one timeline
}

Config.Alerts = {
    ToDiscord = true,  -- post each alert to the alert webhook (server.cfg)
}

-- ============================================================================
--                                  ADVANCED
-- ============================================================================
-- Storage, logging, rate limits and timings. The shipped values suit most
-- servers; read the README before changing any of them.

Config.PendingEscrow = {
    MaxRetriesPerLogin = 5,     -- owed payouts one retry pass tries
    LoginRetryDelayMs  = 5000,  -- wait after a login before paying what is owed
}

Config.Audit = {
    LogAllActions          = true,   -- audit every action, not only money and staff
    LogReasonText          = true,   -- keep the reason text in the audit log
    FlushIntervalMs        = 10000,  -- how often queued rows are written
    MaxQueueSize           = 5000,   -- rows queued at most
    RetentionDays          = 30,     -- days the audit log is kept; 0 = forever
    ContractRetentionDays  = 30,     -- days a finished contract is kept; 0 = forever
    ContractsPrunedPerTick = 200,    -- finished contracts removed per tick
}

Config.Ledger = {
    Depth              = 10,    -- ledger rows kept per player
    MaxDepthHardCap    = 25,    -- ceiling on Depth
    StorePhotos        = true,  -- keep a kill photo for the client (KillPhotos only)
    PhotoRetentionDays = 7,     -- days an unopened photo is kept; 0 = with its row
}

Config.Progression = {
    Enabled             = true,              -- feed completions into the criminal progression
    Resource            = 'sc-blackmarket',  -- the resource that keeps it
    TrustPerElimination = 10,                -- trust per kill
    TrustPerKidnapping  = 20,                -- trust per live handover
}

Config.AntiCollusion = {
    BlockSameAccount = true,  -- one account may not be two parties to a contract
}

Config.RateLimit = {
    Key = 'license',  -- 'license' (per account) | 'citizenid' (per character)
}

Config.Cooldowns = { -- per-player allowances: refill over `per` seconds, `burst` held
    diagnostic  = { per = 60, burst = 10 },  -- the page's own fault reports
    create      = { per = 60, burst = 2 },   -- placing a contract
    accept      = { per = 30, burst = 3 },   -- accepting one
    bailout     = { per = 60, burst = 1 },   -- buying one out
    informant   = { per = 300, burst = 1 },  -- the target's informant
    placerInformant = { per = 300, burst = 1 },  -- the placer's informant
    locationTip = { per = 60, burst = 2 },   -- buying an informant tip on a target
    message     = { per = 5,  burst = 5 },   -- messages, calls, mutes, Notify me
    amend       = { per = 30, burst = 3 },   -- proposing a change
    load        = { per = 10, burst = 20 },  -- the app reading its own state
    search      = { per = 10, burst = 15 },  -- searching names
    wallet      = { per = 10, burst = 8 },   -- reading what the placer carries
    photo       = { per = 15, burst = 3 },   -- asking to photograph a kill
    photoSubmit = { per = 15, burst = 5 },   -- sending the photo
    photoView   = { per = 10, burst = 5 },   -- opening a kill photo
    photoDecide = { per = 5,  burst = 5 },   -- keeping or deleting it
    death       = { per = 5,  burst = 4 },   -- death and revive reports
    mugshot     = { per = 60, burst = 3 },   -- sending a headshot
    progress    = { per = 1,  burst = 5 },   -- the handover countdown, polled each second
    image       = { per = 2,  burst = 20 },  -- fetching a headshot
    admin       = { per = 10, burst = 30 },  -- the admin panel, per staff member
    adminWrite  = { per = 10, burst = 6 },   -- what the admin panel writes
}

Config.Listing = {
    PageSize = 15,  -- contracts per board page
}

Config.Diagnostics = {
    SlowJobMs = 25,  -- a maintenance job slower than this prints a Debug line; 0 = never
}

-- Kill photos, read only with Completion.KillPhotos = true.
Config.Completion.PhotoMaxSide            = 1280    -- 'server': longest side of a photo, in pixels
Config.Completion.PhotoMaxBytes           = 600000  -- 'server': largest photo, in bytes
Config.Completion.PhotoHostRefreshSeconds = 300     -- 'host': re-read lb-phone's hosts this often
Config.Completion.ExtraPhotoHosts         = { -- 'host': image hosts allowed besides lb-phone's own
    'fivemanage.com', 'fmfile.com',
}

-- Death and damage detection.
Config.Completion.RejectLastStand       = true                  -- a downed player is never a kill
Config.Completion.RequireObservedDamage = true                  -- a kill needs a hit the server saw
Config.Completion.DeathReportWindowMs   = 30000                 -- a hit counts this long before a death
Config.Completion.ConditionSampleMs     = 1000                  -- how often targets' health is sampled
Config.Completion.MaxWeaponRange        = 425.0                 -- metres a hit is believed from
Config.Completion.MedicJobs             = { ambulance = true }  -- as sc-ambulance's RequireEMS
Config.Completion.DefibItem             = 'defibrillator'       -- as sc-ambulance's Defib.Item
Config.Completion.DefibRange            = 3.0                   -- as sc-ambulance's Defib.Distance
Config.Completion.DeathStateProviders   = { -- medical resources asked who is dead, in order
    { resource = 'sc-ambulance', dead = 'IsDead', lastStand = 'IsLaststand' },
    { resource = 'qbx_medical',  dead = 'IsDead', lastStand = 'IsLaststand' },
}

-- Handovers, contracts and headshots.
Config.Kidnap.MaxTotalGraceMs         = 3000   -- ms a handover may break, in all, before it fails
Config.Kidnap.TickMs                  = 1000   -- how often a handover is checked
Config.Kidnap.MaxConcurrentCountdowns = 20     -- handovers counting at once, server-wide
Config.Limits.MaxEscrowLines          = 60     -- escrow lines one contract may hold
Config.Limits.MaxDeadlineSkipSeconds  = 600    -- longest the expiry pass sleeps
Config.Bailout.MaxSettleAttempts      = 10     -- ticks a queued buyout waits on a stuck claim
Config.Mugshot.MinRefreshMinutes      = 5      -- least time between two headshots of one target
Config.Mugshot.RenderTimeoutMs        = 8000   -- ms a headshot may take
Config.Mugshot.MaxImageBytes          = 98304  -- largest headshot accepted
Config.Mugshot.AllowedMime            = { -- headshot image types accepted
    ['image/png'] = true, ['image/jpeg'] = true, ['image/webp'] = true,
}

return Config
