--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                      CRIMSON HITMAN SHIPPED DEFAULTS                      ║
    ║                not the file to edit: edit config/config.lua               ║
    ╚═══════════════════════════════════════════════════════════════════════════╝

    The configuration as this resource ships it, in the same layout and
    with the same values as config/config.lua. The start fills a section
    missing from an operator's config.lua (one written before it existed)
    from here: whole missing sections only, since a table the operator
    wrote is theirs. Keep it in step with config.lua; the tests fail the
    build when a key or a value differs.
]]

ConfigDefaults = ConfigDefaults or {}

-- ============================================================================
--                             DEBUG AND STORAGE
-- ============================================================================
-- The console output, and where contracts and money are kept. Switching
-- storage mode starts empty in the new one and refuses to start while the
-- old one still holds money (README).

ConfigDefaults.Debug = true  -- debug lines in the console and F8; false = only what needs you

ConfigDefaults.Database = {
    Mode                = 'mysql', -- 'json' | 'mysql' | 'memory' (testing only)
    AllowModeSwitch     = false,   -- start even though the old mode still holds money
    QueryTimeoutSeconds = 10,      -- mysql: seconds a statement may go unanswered; 0 = forever
    Json                = {
        Directory            = 'data',  -- folder inside the resource
        SyncOnFinancialWrite = true,    -- write money changes to disk at once
    },
}

-- ============================================================================
--                               RULES: TIMERS
-- ============================================================================
-- How long things last. The deadline runs only while the placer, the
-- target and one operative are all in the city, and pauses before a restart.

ConfigDefaults.Limits = {
    DefaultDeadlineSeconds               = 10800,   -- run time; runs only with placer, target, operative in
    ContractLifetimeSeconds              = 172800,  -- hard ceiling, pauses included
    StaffDeadlineMaxAdjustSeconds        = 86400,   -- most staff may extend or shorten a deadline by at once
    StaffDeadlineMinLeftSeconds          = 300,     -- least run time a staff shortening may leave
    TargetCooldownAfterResolveSeconds    = 1800,    -- nobody may target a person again for this long
    SameCreatorSameTargetCooldownSeconds = 7200,    -- the same placer on the same target
    ExclusiveIdleReleaseSeconds          = 1800,    -- release an exclusive hitman never near them; 0 = off
    ExclusiveAttemptWindowSeconds        = 7200,    -- release one who never makes an attempt; 0 = off
    PauseWhileTargetJailed               = true,    -- the deadline stops while the target serves time
    JailZone                             = { x = 1693.3, y = 2569.5, radius = 300 },  -- the prison grounds
}

ConfigDefaults.Holds = { -- what stops every contract's clocks (server/holds.lua)
    AppPaused                 = false,  -- pause the whole app: no placing, no accepting, clocks held
    RestartPauseBeforeSeconds = 1800,   -- pause every contract this long before a txAdmin restart; 0 = off
    RestartMaxHoldMinutes     = 45,     -- end the restart pause if the restart has not come by then
}

-- ============================================================================
--                          RULES: REWARDS AND MONEY
-- ============================================================================
-- What a reward may be made of and how big it may be, payouts, stakes and
-- buyouts. Every reward is held in escrow from placing until the end.

ConfigDefaults.Sources = { -- what a reward may be paid in, and the most of each
    cash   = { enabled = true,  max = 250000 },                        -- cash, at most this much
    bank   = { enabled = true,  max = 500000 },                        -- bank money
    dirty  = { enabled = true,  max = 250000, item = 'black_money' },  -- dirty money, as this item
    item   = { enabled = true,  maxStacks = 10, maxPerStack = 100 },   -- items: stacks, and per stack
    weapon = { enabled = true,  max = 3 },                             -- weapons
}

ConfigDefaults.MaxContractValue = 1000000  -- most a contract may hold, in money

ConfigDefaults.EscrowBlacklist = { -- items that may never be put in a reward
    ['phone'] = true, ['id_card'] = true, ['driver_license'] = true,
    ['weaponlicense'] = true, ['handcuffs'] = true,
    ['identification'] = true, ['lawyerpass'] = true, ['money'] = true,
}

ConfigDefaults.Bonus = {
    maxPercent = 200,  -- under 'either': most a kidnapping bonus may add
}

ConfigDefaults.Limits.MinContractReward   = 1000  -- least a reward may be worth in money; 0 = off
ConfigDefaults.Limits.MaxPayoutSlots      = 1     -- each contract pays out once
ConfigDefaults.Limits.SlotCooldownSeconds = 600   -- a hitman's wait between two payouts on one contract
ConfigDefaults.Limits.MaxEscrowLines      = 60    -- escrow lines one contract may hold

ConfigDefaults.Penalty = {
    MaxAmount                 = 100000,  -- most stake a hitman may be asked for
    MaxFractionOfEscrow       = 2.0,     -- and at most this times the reward
    RequireDisclosureOnAccept = true,    -- accept must echo the stake it was shown
    MinWindowMinutes          = 30,      -- no staked accept with less than this left
}

ConfigDefaults.PendingEscrow = {
    MaxRetriesPerLogin = 5,     -- owed payouts one retry pass tries
    LoginRetryDelayMs  = 5000,  -- wait after a login before paying what is owed
}

ConfigDefaults.Bailout = {
    Enabled                 = true,       -- a target may buy out a contract on them
    MinMultiplier           = 1.0,        -- least buyout price, times the reward
    MaxMultiplier           = 3.0,        -- most buyout price, times the reward
    AbsoluteMax             = 500000,     -- most buyout price in money
    ProcessingDelaySeconds  = 120,        -- a held contract's hitman gets this long first
    BlockWhileIncapacitated = true,       -- no buyout while dead or downed
    Command                 = 'cleanse',  -- the buyout command, for players who cannot open the app
}

-- ============================================================================
--                               RULES: LIMITS
-- ============================================================================
-- How many contracts a player may place, take or carry, and how one is
-- finished: as shipped, a live handover to the placer only.

ConfigDefaults.Limits.MaxActiveContractsPerCreator = 3  -- live contracts one player may place
ConfigDefaults.Limits.MaxAcceptedPerHitman         = 3  -- live contracts one hitman may hold
ConfigDefaults.Limits.MaxActiveContractsPerTarget  = 2  -- live contracts on one person
ConfigDefaults.Limits.MaxContractsPerTargetPerDay  = 0  -- contracts placed on one person in a rolling 24 h; 0 = off
ConfigDefaults.Limits.MaxContractsPerTargetPerWeek = 0  -- contracts placed on one person in a rolling 7 days; 0 = off
ConfigDefaults.Limits.MaxHitmenPerContract         = 5  -- hitmen on one competitive contract

ConfigDefaults.Completion = {
    Fulfilment                = 'alive',   -- 'alive' (live handover only) | 'either' (a kill too)
    KillPhotos                = false,     -- under 'either': true = a photo, false = at the scene
    PhotoStorage              = 'server',  -- 'server' (file in data/photos) | 'host' (lb-phone's)
    PhotoPublicUrl            = nil,       -- 'server': https address for Save to Photos; nil = web_baseUrl
    KeptPhotoDays             = nil,       -- days a photo kept in the app lasts; nil = until deleted
    ProofWindowSeconds        = 60,        -- a kill still verifies this long after death
    PhotoTokenLifetimeSeconds = 120,       -- seconds a kill waits to be verified
    PhotoRadius               = 5.0,       -- metres from the body to verify a kill
    PhotoOpenSeconds          = 600,       -- seconds the placer may view a photo before it is deleted
}

ConfigDefaults.Kidnap = {
    CountdownSeconds       = 30,     -- seconds the handover is held
    Radius                 = 12.0,   -- metres: target, hitman and placer within this of each other
    RequireCoercion        = false,  -- true = the target must also be cuffed or in the hitman's car
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
    PlacerConfirms         = false,  -- true = the placer taps Confirm handover before it pays
    ConfirmSeconds         = 60,     -- seconds the placer has to confirm (10-600)
    ConfirmMissed          = 'rearm', -- no answer in time: 'rearm' (nothing paid) | 'pay'
    MaxDeclines            = 2,      -- declines (or missed windows) a contract gets; then it pays
}

ConfigDefaults.Reason = {
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

ConfigDefaults.Listing = {
    PageSize = 15,  -- contracts per board page
}

ConfigDefaults.Ledger = {
    Depth              = 10,    -- ledger rows kept per player
    MaxDepthHardCap    = 25,    -- ceiling on Depth
    StorePhotos        = true,  -- keep a kill photo for the placer (KillPhotos only)
    PhotoRetentionDays = 7,     -- days an unopened photo is kept; 0 = with its row
}

-- ============================================================================
--                              RULES: TARGETING
-- ============================================================================
-- Who may open the app and who can be named as a target. Law enforcement,
-- EMS, fire and legal jobs are barred by job type as well as by name; with
-- the whitelisted-job view on they get one read-only screen instead.

ConfigDefaults.BlockedJobTypes = { -- job types barred from the app
    leo = true, police = true, ems = true, fire = true,
}

ConfigDefaults.BlockedJobNames = { -- job names barred from the app, alongside the types
    police = true, sheriff = true, leo = true, trooper = true, sasp = true,
    bcso = true, fib = true, ranger = true, doj = true, lawyer = true,
    sast = true, k9 = true, ambulance = true, fire = true,
}

ConfigDefaults.BlockOffDuty           = true  -- barred jobs stay barred off duty
ConfigDefaults.HideAppFromBlockedJobs = true  -- hide the icon from barred jobs (only while the view is off)

ConfigDefaults.WhitelistedView = {
    Enabled = true,  -- barred jobs see one read-only screen: the contracts on them
    Alerts  = true,  -- they may turn on Notify me for new entries there
}

ConfigDefaults.Targeting = {
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

ConfigDefaults.Immunity = {
    MinTargetPlaytimeHours  = 5,     -- hours played before anyone can be a target; 0 = off
    MinTargetSessionMinutes = 10,    -- and this many minutes in the city this session
    PostRespawnSeconds      = 300,   -- protected this long after a respawn (not a handover)
    AfterBailoutSeconds     = 3600,  -- nobody may target them again this long after a buyout
    PlaytimeProvider        = nil,   -- { resource, export } answering minutes; nil = counted here
    GrandfatherDays         = 3,     -- only without qbx_core's players table: days of grace
}

ConfigDefaults.Mugshot = {
    Enabled          = true,   -- target headshots on the board
    RemoveBackground = false,  -- cut out the background (heavy on the target's game)
}

-- ============================================================================
--                               FEATURES: CORE
-- ============================================================================
-- The app itself, proposals, notices, messages and calls, progression and
-- the alerts staff get.

ConfigDefaults.App = {
    DefaultInstalled = false,  -- true = on every eligible home screen; false = in the App Store
}

ConfigDefaults.Amendments = {
    Enabled               = true,  -- placer and hitman may agree changes to a contract
    ProposalExpirySeconds = 300,   -- a proposal lapses after this
    MaxOpenPerContract    = 1,     -- proposals open at once
    CancelCooldownSeconds = 300,   -- wait after cancelling before another
}

ConfigDefaults.Notifications = {
    ParanoidAlert            = true,                     -- the target is told "You feel eyes on you"
    ParanoidAlertJitter      = { min = 60, max = 600 },  -- seconds it waits, drawn at random
    ParanoidCooldownMinutes  = 30,                       -- at most one such alert per target this long
    MaxPerRecipientPerMinute = 6,                        -- notices one player may get a minute
    MaxPerRecipientPerHour   = 40,                       -- and an hour
    PushEnabled              = true,                     -- refresh an open app when its contract changes
    PushMinIntervalSeconds   = 1,                        -- least time between two refreshes
}

ConfigDefaults.Relay = {
    Enabled                    = true,  -- anonymous messages between the parties
    MaxLength                  = 200,   -- characters a message (255 at most on mysql)
    MaxMessagesPerThread       = 100,   -- newest messages a thread keeps
    AllowMaskedCalls           = true,  -- calls with the caller's alias shown
    CallExport                 = nil,   -- your own call export { resource, export }; nil = lb-phone's
    RequireMaskingForAnonymous = true,  -- no call for an anonymous party the phone cannot mask
}

ConfigDefaults.Progression = {
    Enabled             = true,              -- feed completions into the criminal progression
    Resource            = 'sc-blackmarket',  -- the resource that keeps it
    TrustPerElimination = 10,                -- trust per kill
    TrustPerKidnapping  = 20,                -- trust per live handover
}

ConfigDefaults.AntiCollusion = {
    BlockSameAccount = true,  -- one account may not be two parties to a contract
}

ConfigDefaults.Alerts = {
    ToDiscord = true,  -- post each alert to the alert webhook (server.cfg)
}

-- ============================================================================
--                            FEATURES: ANONYMITY
-- ============================================================================
-- Whether a contract may be placed or accepted anonymously, what that costs,
-- and the same four switches where the target is on a whitelisted job.

ConfigDefaults.Anonymity = {
    AllowAnonymousPlacer = false,   -- a contract may be placed anonymously
    AllowAnonymousHitman = false,   -- a contract may be accepted anonymously
    ShowOperativeNames   = true,    -- the target sees a named operative's name
    ShowPlacerOnBoard    = false,   -- the board names a named placer; off: parties only
    CreatorFee           = 0,       -- fee to place anonymously; 0 = free
    HitmanFee            = 0,       -- fee to accept anonymously; 0 = free
    FeeAccount           = 'bank',  -- 'cash' | 'bank'
    WhitelistedTargets   = { -- the same four, where the target is on a whitelisted job
        AllowAnonymousPlacer = false,  -- such a contract may be placed anonymously
        AllowAnonymousHitman = false,  -- such a contract may be accepted anonymously
        ShowOperativeNames   = true,   -- such a target sees a named operative's name
        ShowPlacerOnBoard    = false,  -- the same, on such a contract
    },
}

-- ============================================================================
--                           FEATURES: INFORMANTS
-- ============================================================================
-- Three paid look-ups: the target's (who is after me), the placer's (who
-- took it) and the hitman's tip (the target's rough area). Each ships off.

ConfigDefaults.InformantsEnabled = true  -- master switch; on, each feature's own switch decides

ConfigDefaults.Informant = {
    Enabled                 = false,   -- a target may pay to find out who is after them
    Cost                    = 25000,   -- price of one look-up, paid win or lose; 0 = free
    Account                 = 'bank',  -- 'cash' | 'bank'
    RevealMode              = 'name',  -- 'name' | 'description'
    RevealChancePercent     = 10,      -- chance one look-up finds out who it is, 0-100
    ProximityRadius         = 120.0,   -- metres that count as near (an idle hold's clock)
    RerollLockMinutes       = 30,      -- the same pick again this soon repeats the answer, free
    MaxPurchasesPerContract = 2,       -- look-ups per target per contract, both kinds
}

ConfigDefaults.PlacerInformant = {
    Enabled                 = false,   -- the placer may pay to find out who took it
    Cost                    = 25000,   -- price of one look-up, paid win or lose; 0 = free
    Account                 = 'bank',  -- 'cash' | 'bank'
    RevealChancePercent     = 20,      -- chance one look-up names the operative, 0-100
    AlertChancePercent      = 20,      -- chance a named operative is told, 0-100
    RevealMode              = 'name',  -- 'name' | 'description'
    MaxPurchasesPerContract = 2,       -- look-ups per placer per contract
    CooldownMinutes         = 10,      -- wait between two look-ups
}

ConfigDefaults.LocationTip = {
    Enabled                 = false,   -- a hitman on a contract may buy the target's rough area
    Cost                    = 25000,   -- price; 0 = free
    Account                 = 'bank',  -- 'cash' | 'bank'
    RadiusMeters            = 350,     -- metres; the area shown is twice this across
    ShowMinutes             = 10,      -- minutes the area stays on the hitman's map
    CooldownMinutes         = 10,      -- minutes between two tips on one contract, by anybody
    MaxPurchasesPerContract = 3,       -- tips per contract, all its hitmen together
    NotifyTarget            = true,    -- tell the target someone knows their rough area
}

ConfigDefaults.InformantsWhitelistedTargets = { -- the three above, where the target is on a whitelisted job
    Informant       = false,  -- such a target may buy the target's informant
    PlacerInformant = false,  -- the placer of such a contract may buy the placer's informant
    LocationTip     = false,  -- a hitman on such a contract may buy an informant tip
}

-- ============================================================================
--                            FEATURES: ADVISORY
-- ============================================================================
-- The law enforcement advisory: officers are told when one of them, or
-- another whitelisted-job member, is targeted.

ConfigDefaults.Advisory = {
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

-- ============================================================================
--                           STAFF AND PERMISSIONS
-- ============================================================================
-- The staff tools: /hitmanadmin and the F8 commands. ACE names are never
-- changed from the panel, so staff cannot grant themselves access.

ConfigDefaults.Admin = {
    Enabled             = true,                 -- the staff commands and the admin panel
    Ace                 = 'crimson.admin',      -- ACE for staff, and for anything that writes
    IdentityAce         = 'crimson.identity',   -- ACE to see who is behind an anonymous party
    DeveloperAce        = 'crimson.developer',  -- ACE for the panel's Developer section
    ModeratorAce        = 'crimson.moderator',  -- ACE that reads, freezes, suspends, protects and voids
    ExtraAces           = { 'command' },        -- ACEs that may also read (never write)
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
    PanelPageSize       = 25,                   -- rows per page in the panel's lists
    PanelRefreshSeconds = 10,                   -- how often the overview refreshes
    TimelineRows        = 200,                  -- audit rows read for one timeline
}

ConfigDefaults.Staff = {
    ManualPaymentMax      = 100000, -- most one manual staff payment may be ($); 0 = off
    DailySummary          = false,  -- post one count-only summary a day to the staff Discord
    DailySummaryHour      = 6,      -- the hour it is posted, server time (0-23)
    AlertPlacedPerHour    = 5,      -- alert past this many placed by one player an hour; 0 = off
    AlertTargetPerDay     = 3,      -- alert past this many on one target a day; 0 = off
    AlertRefusalsPer10Min = 30,     -- alert past this many refusals to one player in 10 min; 0 = off
    RewardChangeMax       = 100000, -- most staff may raise or lower a reward by at once ($); 0 = off
    ReassignStake         = 'waive', -- a hitman staff assign: 'waive' (no stake) | 'charge'
}
-- ============================================================================
--                                 ROLEPLAY
-- ============================================================================
-- Optional roleplay features, each its own block and each off as shipped
-- (README, Optional features). All of them are changed from the admin panel.
-- Places (the broker's and the informant's) are 'x, y, z, heading'.

ConfigDefaults.Roleplay = ConfigDefaults.Roleplay or {}  -- the roleplay features, one block each

ConfigDefaults.Roleplay.WitnessHeat = {
    Enabled          = false,  -- a completion seen by bystanders alerts the police
    WitnessRadius    = 60.0,   -- metres a bystander sees it from
    MinWitnesses     = 1,      -- bystanders it takes to raise an alert
    AlwaysAlert      = false,  -- alert on every completion, seen or not
    SendCoords       = true,   -- give dispatch a position, fuzzed below
    FuzzMeters       = 120.0,  -- metres that position may be off by
    DispatchPriority = 2,      -- sc-dispatch priority of the alert
    Title            = 'Witness report',  -- the alert's title
    Phrases          = { -- what a witness says; {direction} is where they went
        'a person in dark clothing fled {direction}',
        'someone in a hood was seen running {direction}',
        'a masked figure left the scene heading {direction}',
    },
    Areas            = { -- 'Name@x,y': the nearest centre names the area
        'Legion Square@195,-934', 'Mission Row@430,-980', 'Little Seoul@-700,-900',
        'Vespucci Beach@-1300,-1400', 'Del Perro@-1550,-500', 'Rockford Hills@-800,-200',
        'Vinewood@300,200', 'Mirror Park@1100,-550', 'La Mesa@800,-1100',
        'Strawberry@200,-1400', 'Davis@100,-1700', 'the docks@600,-2800',
        'the airport@-1050,-2700', 'Sandy Shores@1850,3700', 'Grapeseed@1700,4800',
        'Paleto Bay@-250,6300', 'Harmony@550,2700', 'Chumash@-3150,1100',
    },
}

ConfigDefaults.Roleplay.EmsRelisting = {
    Enabled        = false,  -- after a kill, no new contract on them until treated
    TreatedMinutes = 10,     -- minutes up (not dead, not downed) that count as treated
    RequireEMS     = false,  -- a medic's defibrillator revive is needed instead
    MaxHoldMinutes = 120,    -- the rule lets go this long after the kill, whatever
}

ConfigDefaults.Roleplay.CityNews = {
    Enabled    = false,     -- post an anonymous news item after a completion
    AllTargets = false,     -- every target; off: whitelisted-job targets only
    NameTarget = false,     -- {name} is the target's name; off: 'a resident'
    App        = 'birdy',   -- 'birdy' (lb-phone PostBirdy) | 'event'
    Account    = 'LSNews',  -- the Birdy account it posts from (must exist)
    Event      = 'crimson-hitman:cityNews',  -- 'event': the server event fired
    Templates  = { -- one is picked; {job}, {zone}, {time} and {name}
        'Police are appealing for witnesses after an attack on a {job} near {zone} at {time}.',
        'Breaking: a {job} was targeted near {zone} around {time}. Police are on scene.',
    },
}

ConfigDefaults.Roleplay.DirtyPayouts = {
    Enabled  = false,          -- pay cash and bank rewards as a dirty money item
    Item     = 'black_money',  -- the ox_inventory item paid
    Mode     = 'count',        -- 'count': Rate items a dollar | 'worth': one item
    WorthKey = 'worth',        -- 'worth': the metadata key holding its value
    Rate     = 1,              -- 'count': items paid for each dollar (no loss)
}

ConfigDefaults.Roleplay.ProofOfIntent = {
    Enabled        = false, -- hold a payout until the hitman shows intent
    MinMessages    = 3,     -- messages to the placer in the thread that count
    HoldMaxMinutes = 60,    -- released anyway after this long (min)
}

ConfigDefaults.Roleplay.Reputation = {
    Enabled          = false, -- trust for a completion scaled by how it was done
    BaseFactor       = 0.5,   -- a plain completion
    ThreadBonus      = 0.2,   -- the hitman wrote to the placer in the thread
    MeetingBonus     = 0.2,   -- a meeting point was set
    HandoverBonus    = 0.3,   -- a live handover
    WitnessFreeBonus = 0.2,   -- nobody else within WitnessRadius
    WitnessRadius    = 50.0,  -- metres around the hitman
    MaxFactor        = 1.5,   -- the most it may reach
}

ConfigDefaults.Roleplay.Protection = {
    Enabled                = false,  -- targets may hire a bodyguard from On me
    Account                = 'bank', -- the reward is paid from: 'cash' | 'bank'
    MinReward              = 1000,   -- least reward ($)
    MaxReward              = 100000, -- most reward ($)
    PayOnCompletionPercent = 25,     -- the guard's share if the hit completes anyway
    MaxJobsPerGuard        = 2,      -- protection jobs one guard holds at once
}

ConfigDefaults.Roleplay.HitOnHitman = {
    Enabled = false, -- a target may place a contract on an operative revealed
}

ConfigDefaults.Roleplay.Rumours = {
    Enabled           = false,       -- the board shows new contracts as rumours only
    AreaMode          = 'district',  -- 'district' (target's area) | 'zones' (from Zones)
    Zones             = { -- area names when AreaMode = 'zones'
        'the city', 'the south side', 'the docks', 'the hills', 'the county',
    },
    Districts         = { -- 'x, y, name': the nearest names the target's area
        '200, -900, Legion Square', '-1300, -1400, Vespucci', '-1500, -450, Del Perro',
        '-800, -150, Rockford Hills', '1100, -600, Mirror Park', '100, -1750, Davis',
        '800, -1200, La Mesa', '1000, -3000, the port', '0, 800, Vinewood Hills',
        '1850, 3700, Sandy Shores', '2000, 4900, Grapeseed', '-150, 6350, Paleto Bay',
    },
    BandPercent       = 25,          -- reward shown as a band this many % either side
    Radius            = 5.0,         -- metres from the broker (NPC or player) that count
    BriefValidMinutes = 30,          -- a briefing unlocks a contract for this long
    Locations         = { -- where the broker NPC stands, one at a time
        '-1171.0, -1572.5, 4.66, 125.0', '1240.6, -3179.2, 7.1, 270.0',
        '-56.5, -1752.4, 29.4, 50.0',
    },
    RotateHours       = 4,           -- the NPC moves to the next place this often
    Model             = 'g_m_m_armboss_01',     -- the broker NPC's ped model
    Scenario          = 'WORLD_HUMAN_SMOKING',  -- what the NPC does while standing
    Blip              = false,       -- show the broker on the map
    BrokerJobs        = {},          -- jobs whose players brief from the app: { broker = true }
}

ConfigDefaults.Roleplay.BurnerPhone = {
    Enabled         = false,           -- placing and accepting need the item
    Item            = 'burner_phone',  -- the ox_inventory item
    ConsumeOnPlace  = false,           -- use one up when a contract is placed
    ConsumeOnAccept = false,           -- use one up when a contract is accepted
    RequireToOpen   = true,            -- no item, no contract tabs at all
}

ConfigDefaults.Roleplay.InformantNpc = {
    Enabled     = false,  -- informant purchases only beside the informant NPC
    Radius      = 5.0,    -- metres from the informant that count
    Locations   = { -- where the informant stands, one at a time
        '374.2, -827.4, 29.3, 180.0', '-1394.0, -592.0, 30.3, 120.0',
        '1984.0, 3054.0, 47.2, 240.0',
    },
    RotateHours = 3,                      -- the NPC moves to the next place this often
    Model       = 'a_m_y_hipster_01',     -- the informant NPC's ped model
    Scenario    = 'WORLD_HUMAN_LEANING',  -- what the NPC does while standing
    Blip        = false,                  -- show the informant on the map
}

ConfigDefaults.Roleplay.NpcPlaces = {
    Enabled = false,  -- broker and informant placed from the panel (Locations)
}

ConfigDefaults.Roleplay.ReasonQuality = {
    Enabled         = false,     -- hold free-text reasons to the rules below
    MinLength       = 15,        -- least characters in a reason
    MinWords        = 3,         -- least words in a reason
    LowEffort       = { 'rdm', 'idk', 'cuz', 'no reason', 'test', 'because' }, -- words to catch
    LowEffortAction = 'refuse',  -- 'refuse' | 'review' (placed, and queued for staff)
}
-- ============================================================================
--                               IMPROVEMENTS
-- ============================================================================
-- Optional changes to existing features, each its own block and each off as
-- shipped (README, Optional features). All are changed from the panel.

ConfigDefaults.Improvements = ConfigDefaults.Improvements or {}  -- the improvements, one block each

ConfigDefaults.Improvements.TipWarningDelay = {
    Enabled    = false,  -- the target's tip notice waits a random while
    MinSeconds = 60,     -- shortest wait (s)
    MaxSeconds = 300,    -- longest wait (s)
}

ConfigDefaults.Improvements.TipLimits = {
    Enabled       = false,   -- the extra tip limits below apply
    OnePerHitman  = true,    -- each hitman buys one tip per contract
    PriceDoubling = false,   -- each further tip on a contract costs twice the last
    MaxCost       = 200000,  -- the most a doubled tip costs ($)
}

ConfigDefaults.Improvements.TipHoldFirst = {
    Enabled        = false,  -- a tip only once the contract was held a while
    MinHeldMinutes = 10,     -- minutes the hitman must have held it
}

ConfigDefaults.Improvements.InformantSecondTry = {
    Enabled              = false,  -- the target's later look-ups cost differently
    SecondTryCostPercent = 50,     -- % of Informant.Cost after the first
}

ConfigDefaults.Improvements.TipSafeZones = {
    Enabled = false,  -- no tip while the target is inside one of Zones
    Zones   = {},     -- 'x, y, radius, name', e.g. '300, -590, 80, Pillbox'
}

ConfigDefaults.Improvements.GoDark = {
    Enabled = false,   -- a tipped-off target may pay to go dark
    Cost    = 50000,   -- price; 0 = free
    Account = 'bank',  -- 'cash' | 'bank'
    Minutes = 30,      -- tips bought on them this long find nothing
}

ConfigDefaults.Improvements.PlacerRecord = {
    Enabled          = false,  -- hitmen see the placer's record on a board card
    LookbackDays     = 30,     -- days of contracts the record counts
    ShowForAnonymous = false,  -- an anonymous placer's record too, in rough bands
}

ConfigDefaults.Improvements.HitmanHeat = {
    Enabled                 = false,  -- hitmen gather heat the city can feel
    ProtectedCompletionHeat = 3,      -- heat for a completion on a whitelisted-job target
    WitnessHeat             = 2,      -- heat for a witness report on their completion
    AdvisoryHeat            = 1,      -- heat for a police bulletin on their acceptance
    DecayHours              = 24,     -- hours each heat stays
    Threshold               = 5,      -- heat at which a hitman counts as known
    WarnTargetChancePercent = 50,     -- chance their next target is warned, 0-100
    BulletinEveryMinutes    = 60,     -- least minutes between police bulletins; 0 = none
    BulletinTitle           = 'Intelligence bulletin',  -- the bulletin's title
    BulletinText            = 'A known contract killer is believed active in the city.',  -- its words
}

ConfigDefaults.Improvements.Tiers = {
    Enabled             = false,  -- big rewards need a progression level
    CompletionsPerLevel = 5,      -- completed contracts per level above 1
    Tiers               = { -- 'name, least reward, least level'
        'Professional, 50000, 2',
        'Elite, 150000, 4',
    },
}

ConfigDefaults.Improvements.ContractDecay = {
    Enabled            = false,   -- an untaken contract changes as it waits
    Mode               = 'rise',  -- 'rise': its reward goes up; 'shorten': it ends sooner
    Percent            = 10,      -- how much each step changes it
    Hours              = 1,       -- hours between steps
    MaxIncreasePercent = 50,      -- most a reward rises in all ('rise')
    Account            = 'bank',  -- where a rise is charged from: 'cash' or 'bank'
}

ConfigDefaults.Improvements.ProofItems = {
    Enabled        = false,        -- a hitman may finish with an item taken from the target
    Item           = 'id_card',    -- the ox_inventory item (qbx_idcard's id card as shipped)
    MetadataKey    = 'citizenid',  -- the item's metadata field that must name the target
    HandoverRadius = 3.0,          -- metres between the hitman and the placer at the handover
}

ConfigDefaults.Improvements.SerialScrub = {
    Enabled = false,  -- a weapon from an anonymous placer reaches the hitman with a new serial
}

ConfigDefaults.Improvements.WeeklyStats = {
    Enabled = false,     -- post the week's totals to Discord once a week (counts only)
    Day     = 'sunday',  -- the day it is posted, server time
    Hour    = 18,        -- the hour it is posted, server time (0-23)
}

ConfigDefaults.Limits.TargetCooldownAfterCompletionSeconds = 0  -- wait after a completed contract on them; 0 = off
-- ============================================================================
--                               ORGANISATION
-- ============================================================================
-- The hitman organisation: a real qbx_core job with roles, a boss menu and
-- Boss permissions (README, Optional features). Off as shipped: while it is
-- off no job is registered, nothing is read or written, nothing changes.

ConfigDefaults.Organisation = {
    Enabled            = false,                  -- the organisation and its qbx_core job
    RequireJobToAccept = false,                  -- only members may accept contracts
    AcceptNeedsPower   = false,                  -- and only roles given Take contracts
    OnDutyOnly         = false,                  -- members accept only while on duty
    JobName            = 'hitman',               -- the qbx_core job (lower case)
    JobLabel           = 'Crimson Contractors',  -- the job's label in qbx_core
    JobType            = 'hitman',               -- the qbx_core job type
    DefaultDuty        = true,                   -- on duty when the job is set
    SetPrimaryOnHire   = true,                   -- an accepted invite or application makes it their primary job
    QbxBossFlag        = false,                  -- mark boss roles isboss in qbx_core too
    ExternalChanges    = 'adopt',                -- 'adopt' | 'revert' job changes made elsewhere
    Funds              = 'auto',                 -- 'auto' (Renewed-Banking if installed) | 'internal', chosen once
    OfficeRadius       = 5.0,                    -- metres from the boss office that count
    DrawMetres         = 40.0,                   -- metres at which a spot is drawn
    ApplyAtSignupOnly  = true,                   -- applications only at a sign-up spot
    NpcModel           = 'g_m_m_armboss_01',     -- the ped drawn at an NPC spot
    Codenames          = false,                  -- members carry a codename, shown instead of their name
    CodenameMinLength  = 3,                      -- least characters in a codename
    CodenameMaxLength  = 20,                     -- most characters in a codename
    CodenameBlocked    = { 'admin', 'staff', 'moderator', 'police' }, -- words a codename may not contain
    Payroll            = false,                  -- a salary per role, paid from the funds every pay day
    PayrollDays        = 7,                      -- days between two pay days
    PaySuspended       = false,                  -- suspended members are paid their salary too
    Roles              = { -- the roles made with it: 'grade, name, label, pay, boss'
        '0, recruit, Recruit, 0, no',
        '1, operative, Operative, 0, no',
        '2, lieutenant, Lieutenant, 0, no',
        '3, boss, Boss, 0, yes',
    },
    Limits             = { -- the staff bounds every boss power works within
        MaxMembers               = 20,      -- members at most
        HireRadius               = 5.0,     -- metres a hire stands from the boss
        HireMaxGrade             = 0,       -- highest grade a boss hires into
        FireCooldownMinutes      = 10,      -- minutes between two fires by one boss
        PromotionsPerDay         = 5,       -- role changes one boss makes a day
        SuspendMaxHours          = 72,      -- longest a boss bars a member from contracts
        MemberMaxAtOnce          = 3,       -- most contracts a boss lets a member hold
        MemberCooldownMaxMinutes = 120,     -- longest cooldown between accepts a boss sets
        MaxRoles                 = 8,       -- roles at most
        PayMax                   = 500,     -- most pay per role per pay-cycle ($)
        BonusMax                 = 10000,   -- largest bonus ($)
        BonusPerDay              = 25000,   -- bonuses one boss pays a day ($)
        WithdrawMax              = 50000,   -- largest withdrawal ($)
        WithdrawPerDay           = 100000,  -- withdrawals one boss makes a day ($)
        CutMaxPercent            = 25,      -- most a boss sets the payout cut to (%)
        TotalCutCapPercent       = 40,      -- most of one payout all cuts take (%)
        StakeCutMaxPercent       = 25,      -- most a boss sets the stake cut to (%)
        BuyoutCutMaxPercent      = 25,      -- most a boss sets the buyout cut to (%)
        OfficeMoveMetres         = 150.0,   -- how far a boss moves the office from staff's point
        LocationCooldownMinutes  = 60,      -- minutes between two moves of a spot by a boss
        MaxSignupSpots           = 2,       -- sign-up spots at most
        MaxMeetingSpots          = 5,       -- organisation meeting spots at most
        NoticeMaxLength          = 500,     -- characters in the board notice
        RenameCooldownMinutes    = 1440,    -- minutes between two label changes by a boss
        InviteMinutes            = 10,      -- minutes a boss's invite waits for the player to accept
        SalaryMax                = 1000,    -- most salary a boss sets per role per pay day ($)
        PayrollPerDayMax         = 0,       -- most paid in salaries in all on one pay day ($); 0 = no cap
        CodenameCooldownMinutes  = 1440,    -- minutes between two own codename changes
    },
}
-- ============================================================================
--                               MISSION STEPS
-- ============================================================================
-- Map markers for each step of a contract, to the one party who acts on it
-- (README, Optional features), and body disposal: a verified kill paid once
-- the body is dropped off. Disposal ships off; its spots are set by staff
-- in the admin panel (Locations) or below.

ConfigDefaults.StepMarkers = {
    Enabled    = true,  -- markers for each step, to the party who acts on it
    KillScene  = true,  -- the hitman: the body, until the kill is verified
    Handover   = true,  -- placer and hitman: the handover circle while it counts
    Protection = true,  -- the guard: their client's meeting pin while on the job
}

ConfigDefaults.Disposal = {
    Enabled          = false,     -- a verified kill pays once the body is dropped off
    VehicleModel     = 'romero',  -- the disposal vehicle (the hearse)
    VehicleSpawn     = {},        -- { x, y, z, h } where it is made; the panel's spot wins
    DropOff          = {},        -- { x, y, z } the drop-off; the panel's spot wins
    PayNowPercent    = 0,         -- of a cash or bank payout handed over at the kill
    TimeLimitMinutes = 30,        -- minutes of the hitman's time in the city to finish
    OnTimeout        = 'pay',     -- 'pay' | 'reduced' | 'refund' (to the placer)
    ReducedPercent   = 50,        -- 'reduced': what the hitman keeps of the money (%)
    LoadMetres       = 3.0,       -- how near the body the hitman stands to load it
    DropMetres       = 8.0,       -- how near the drop-off the hitman stands
    VehicleMetres    = 10.0,      -- how near the body or drop-off the vehicle is
    AbandonMetres    = 300.0,     -- a vehicle left this far away ...
    AbandonMinutes   = 5,         -- ... this long is taken back to the spawn spot
    MaxRespawns      = 3,         -- times the vehicle is made again when lost
    MaxHoldMinutes   = 120,       -- real minutes from the kill a step may stand, away or not
    DespawnSeconds   = 10,        -- seconds after the drop-off it is taken away
}
-- ============================================================================
--                          ADVANCED AND DEVELOPER
-- ============================================================================
-- Logging, diagnostics, rate limits, json tuning and the timings of the
-- kill and handover checks. The shipped values suit most servers.

ConfigDefaults.Audit = {
    LogAllActions          = true,   -- audit every action, not only money and staff
    LogReasonText          = true,   -- keep the reason text in the audit log
    FlushIntervalMs        = 10000,  -- how often queued rows are written
    MaxQueueSize           = 5000,   -- rows queued at most
    RetentionDays          = 30,     -- days the audit log is kept; 0 = forever
    ContractRetentionDays  = 30,     -- days a finished contract is kept; 0 = forever
    ContractsPrunedPerTick = 200,    -- finished contracts removed per tick
}

ConfigDefaults.Diagnostics = {
    SlowJobMs = 25,  -- a maintenance job slower than this prints a Debug line; 0 = never
}

ConfigDefaults.RateLimit = {
    Key = 'license',  -- 'license' (per account) | 'citizenid' (per character)
}

ConfigDefaults.Cooldowns = { -- per-player allowances: refill over `per` seconds, `burst` held
    diagnostic      = { per = 60, burst = 10 },   -- the page's own fault reports
    create          = { per = 60, burst = 2 },    -- placing a contract
    accept          = { per = 30, burst = 3 },    -- accepting one
    bailout         = { per = 60, burst = 1 },    -- buying one out
    informant       = { per = 300, burst = 1 },   -- the target's informant
    placerInformant = { per = 300, burst = 1 },   -- the placer's informant
    locationTip     = { per = 60, burst = 2 },    -- buying an informant tip on a target
    message         = { per = 5,  burst = 5 },    -- messages, calls, mutes, Notify me
    amend           = { per = 30, burst = 3 },    -- proposing a change
    load            = { per = 10, burst = 20 },   -- the app reading its own state
    search          = { per = 10, burst = 15 },   -- searching names
    wallet          = { per = 10, burst = 8 },    -- reading what the placer carries
    photo           = { per = 15, burst = 3 },    -- asking to photograph a kill
    photoSubmit     = { per = 15, burst = 5 },    -- sending the photo
    photoView       = { per = 10, burst = 5 },    -- opening a kill photo
    photoDecide     = { per = 5,  burst = 5 },    -- keeping or deleting it
    death           = { per = 5,  burst = 4 },    -- death and revive reports
    mugshot         = { per = 60, burst = 3 },    -- sending a headshot
    progress        = { per = 1,  burst = 5 },    -- the handover countdown, polled each second
    image           = { per = 2,  burst = 20 },   -- fetching a headshot
    admin           = { per = 10, burst = 30 },   -- the admin panel, per staff member
    adminWrite      = { per = 10, burst = 6 },    -- what the admin panel writes
    report          = { per = 600, burst = 3 },   -- reporting a contract or a thread to staff
    org             = { per = 10, burst = 20 },   -- the organisation's reads (members, boss menu)
    orgWrite        = { per = 10, burst = 5 },    -- what a boss changes in the organisation
    disposal        = { per = 10, burst = 6 },    -- loading and dropping off a body
}

ConfigDefaults.Database.Json.WarnContractCount      = 2000  -- json: warn above this many contracts
ConfigDefaults.Database.Json.MaxDirtyShardsPerFlush = 25    -- json: contract files one ordinary flush writes

ConfigDefaults.Limits.MaxDeadlineSkipSeconds  = 600    -- longest the expiry pass sleeps
ConfigDefaults.Kidnap.MaxTotalGraceMs         = 3000   -- ms a handover may break, in all, before it fails
ConfigDefaults.Kidnap.TickMs                  = 1000   -- how often a handover is checked
ConfigDefaults.Kidnap.MaxConcurrentCountdowns = 20     -- handovers counting at once, server-wide
ConfigDefaults.Bailout.MaxSettleAttempts      = 10     -- ticks a queued buyout waits on a stuck claim

ConfigDefaults.Completion.PhotoMaxSide            = 1280    -- 'server': longest side of a photo, in pixels
ConfigDefaults.Completion.PhotoMaxBytes           = 600000  -- 'server': largest photo, in bytes
ConfigDefaults.Completion.PhotoHostRefreshSeconds = 300     -- 'host': re-read lb-phone's hosts this often
ConfigDefaults.Completion.ExtraPhotoHosts         = { -- 'host': image hosts allowed besides lb-phone's own
    'fivemanage.com', 'fmfile.com',
}
ConfigDefaults.Completion.RejectLastStand       = true                  -- a downed player is never a kill
ConfigDefaults.Completion.RequireObservedDamage = true                  -- a kill needs a hit the server saw
ConfigDefaults.Completion.DeathReportWindowMs   = 30000                 -- a hit counts this long before a death
ConfigDefaults.Completion.ConditionSampleMs     = 1000                  -- how often targets' health is sampled
ConfigDefaults.Completion.MaxWeaponRange        = 425.0                 -- metres a hit is believed from
ConfigDefaults.Completion.MedicJobs             = { ambulance = true }  -- as sc-ambulance's RequireEMS
ConfigDefaults.Completion.DefibItem             = 'defibrillator'       -- as sc-ambulance's Defib.Item
ConfigDefaults.Completion.DefibRange            = 3.0                   -- as sc-ambulance's Defib.Distance
ConfigDefaults.Completion.DeathStateProviders   = { -- medical resources asked who is dead, in order
    { resource = 'sc-ambulance', dead = 'IsDead', lastStand = 'IsLaststand' },
    { resource = 'qbx_medical' },  -- no server exports: read from the QBox metadata it writes
}

ConfigDefaults.Mugshot.MinRefreshMinutes = 5      -- least time between two headshots of one target
ConfigDefaults.Mugshot.RenderTimeoutMs   = 8000   -- ms a headshot may take
ConfigDefaults.Mugshot.MaxImageBytes     = 98304  -- largest headshot accepted
ConfigDefaults.Mugshot.AllowedMime       = { -- headshot image types accepted
    ['image/png'] = true, ['image/jpeg'] = true, ['image/webp'] = true,
}

return ConfigDefaults
