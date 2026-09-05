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
    --- A command for players who cannot open the app at all (§7.5).
    ---
    --- Law enforcement and EMS are barred from the app by §2, so an officer
    --- with a contract on them had no way to buy it out — the one mechanic
    --- the target of a contract is supposed to have. The command works only
    --- for the target of a contract, does exactly what the app's button
    --- does, and is otherwise no different.
    Command = 'cleanse',
    --- How many ticks a queued buyout waits on a contract that is mid-claim
    --- before giving up and refunding. A claim resolves within a tick or two,
    --- so this only matters when one was interrupted by a crash — and the
    --- target's premium is already spent, so it cannot wait forever.
    MaxSettleAttempts = 10,
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
    --- Ceiling on escrow lines in one contract, across every payout, both
    --- portions and any later top-up. The per-payout limits multiply: five
    --- payouts, two portions and ten item stacks each is a hundred and sixty
    --- rows for one contract, every one of them read on every release. The
    --- property is the creator's own, so this is not an economy limit — it
    --- bounds the work a single contract can cost the database.
    MaxEscrowLines               = 60,
    --- The longest the expiry pass will skip ahead when no contract has a
    --- nearer deadline. A ceiling rather than a target: it bounds how stale
    --- the cached "nothing to do until" answer can get.
    MaxDeadlineSkipSeconds       = 600,
    --- The same hunter may not claim two slots inside this window. Without
    --- it a multi-slot contract becomes a respawn-camping machine.
    SlotCooldownSeconds          = 600,

    TargetCooldownAfterResolveSeconds = 1800,
    SameCreatorSameTargetCooldownSeconds = 7200,

    ContractLifetimeSeconds = 172800,   -- absolute ceiling, pause included
    DefaultDeadlineSeconds  = 10800,
}

--- What an action cooldown is counted against (§14.27).
---
--- 'license' keys buckets to the account, so switching characters does not
--- reset them — which on a server with a character selector is otherwise
--- one menu away. 'citizenid' keys them per character, which is more
--- permissive and is the older behaviour.
Config.RateLimit = {
    Key = 'license',
}

Config.Cooldowns = {
    create    = { per = 60, burst = 2 },
    accept    = { per = 30, burst = 3 },
    bailout   = { per = 60, burst = 1 },
    informant = { per = 300, burst = 1 },
    message   = { per = 5,  burst = 5 },
    amend     = { per = 30, burst = 3 },

    --- The app reading its own state: the board, this player's contracts,
    --- their ledger, an open thread. Opening the app is three of these at
    --- once and every refresh is two more, so this is a budget for the app
    --- itself rather than for anything a player chose to do.
    ---
    --- It used to share one bucket of five with everything below. Opening
    --- the app and tapping Place spent the lot, and the two requests that
    --- fire last — the wallet and the target list — were the two that came
    --- back refused. An empty item picker and an empty city, on a form that
    --- looked simply broken, and refreshing made it worse.
    load      = { per = 10, burst = 20 },

    --- Typing a name and paging through the result. Debounced at 300ms in
    --- the app, so this is generous on purpose: the limit is here to stop
    --- somebody enumerating the server, not to stop somebody typing.
    search    = { per = 10, burst = 15 },

    --- Reading what the creator is carrying. Once per Place form, plus
    --- whatever a retry costs.
    wallet    = { per = 10, burst = 8 },
    photo     = { per = 15, burst = 3 },
    --- Death and revive reports are client-driven and each one walks the
    --- contract table, so they are throttled like everything else.
    death     = { per = 5,  burst = 4 },
    mugshot   = { per = 60, burst = 3 },
    --- The countdown is polled once a second while a delivery runs, so it
    --- cannot share a bucket with the listing calls.
    progress  = { per = 1, burst = 5 },
    --- Fetching a headshot the app was given a reference to. One request per
    --- face per viewer, cached by reference afterwards, so a full page of
    --- fifteen unseen targets needs fifteen — hence the generous burst.
    image     = { per = 2, burst = 20 },
}

--------------------------------------------------------------------------
-- Target eligibility and immunity (§14.19, §14.39)
--------------------------------------------------------------------------

Config.Immunity = {
    MinTargetPlaytimeHours   = 5,
    MinTargetSessionMinutes  = 10,
    PostRespawnSeconds       = 300,
    AfterBailoutSeconds      = 3600,
    --- Where total playtime comes from. Leave nil to read QBox character
    --- metadata. If nothing can answer, the playtime rule is skipped and the
    --- resource says so at startup — it does not silently refuse everyone.
    PlaytimeProvider = nil,
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
    --- How often the photo host allowlist is re-read from lb-phone's upload
    --- config. Read only at boot, an owner who changed upload provider had
    --- to restart this resource too, and the failure mode is every
    --- verification photo being rejected.
    PhotoHostRefreshSeconds = 300,
    DeathReportWindowMs = 30000,
    --- A killer named by their victim must also appear in the damage log
    --- the server built for itself. The victim naming them is a client
    --- saying so; without this a hunter can be credited for a target the
    --- server never observed them touch.
    ---
    --- The cost is that a kill by something that raises no weapon damage
    --- event — a vehicle, a fall, fire — pays nobody, which is the safer
    --- side of the trade. Turn it off only if that matters more than the
    --- attribution being observed.
    RequireObservedDamage = true,
    --- How often the condition of a live contract's target is sampled.
    ---
    --- Each damage event is credited with the drop since the last sample,
    --- so a slow sampler lets a hunter who lands one shot inherit whatever
    --- else happened to the target in between — an explosion, a fall, or
    --- somebody else's firefight, none of which raise a weapon damage event
    --- of their own. Bounded by the number of live contracts.
    ConditionSampleMs = 1000,
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
    --- How long a hunter must wait before re-arming a handover that failed
    --- on this contract. The countdown itself is bounded by the grace
    --- budget; without this the *retrying* is not, and a hunter whose client
    --- never turns up can hold a target in a loop at no cost.
    RearmCooldownSeconds = 60,
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
    MinQueryLength = 3,
    MaxResults = 8,

    --- Let a player browse everyone who is currently online.
    ---
    --- This IS the roster §14.33 originally refused, and it is on because
    --- the server owner asked for it. Understand what it means: anybody
    --- holding the app can read the name of every player in the city, and
    --- whether they are law enforcement, without knowing anything about
    --- them first. Somebody logging in becomes visible to everyone.
    ---
    --- What it still does not hand out: citizen ids (the list carries the
    --- same opaque, per-searcher, expiring handles as a name search),
    --- positions, jobs beyond the protected flag, or anything about players
    --- sharing the browser's own account. It is rate-limited like every
    --- other listing.
    ---
    --- Set false to go back to requiring a typed name.
    AllowBrowseAll = true,
    --- Names per page when browsing. A page is one round trip and one
    --- render, so this bounds both.
    BrowsePageSize = 30,

    --- Let a player list the people standing around them, nearest first.
    ---
    --- Narrower than the roster above and useful on its own: when you are
    --- looking at somebody across a car park, "who is near me" answers the
    --- question directly, and the distance tells two people with the same
    --- name apart.
    AllowNearby = true,
    --- Metres. Roughly a street: close enough that you are looking at them.
    NearbyRadius = 30.0,
    --- How many of the nearest to name, closest first.
    MaxNearby = 12,
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

    --- The export that actually places a call, if this phone build has one.
    ---
    --- lb-phone ships its server code escrowed, so the name and signature
    --- of a call-placing export cannot be read from the resource and are
    --- not guessed here: an invented export name is a call that silently
    --- does nothing on a live server, which is worse than one that says it
    --- cannot place calls.
    ---
    --- Set `resource` and `export` if your build exposes one. It is probed
    --- at boot — the export must exist and be callable — and the startup
    --- report says whether it was found. Until then a call request notifies
    --- the other party, which is what it has always done, and the app says
    --- plainly that it is a request rather than a call.
    ---
    --- The export is called as
    ---   exports[resource][export](callerSource, targetNumber, anonymous)
    --- and anything that does not match that shape needs a shim resource.
    CallExport = nil,

    --- Refuse to place a call at all when the other party is anonymous and
    --- the phone cannot suppress caller identity. Leave this on: the
    --- alternative is revealing a number somebody paid to hide.
    RequireMaskingForAnonymous = true,
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
    --- Only a hunter the server has actually seen near the target may be
    --- named (§6.1). A hunter who pressed accept and did nothing is not
    --- tracking anyone, and revealing them turns the purchase into a roster
    --- dump. Proximity is observed by the condition sampler; nothing is ever
    --- taken from a client's word for where it is.
    RequireProximity = true,
    ProximityRadius = 120.0,
    --- How long an observation counts for. Long enough that a hunter who
    --- tailed you and backed off is still named; short enough that one who
    --- walked past yesterday is not.
    ProximityWindowMinutes = 10,
    RerollLockMinutes = 30,
    MaxPurchasesPerContract = 2,
}

Config.Ledger = {
    Depth = 10,
    MaxDepthHardCap = 25,
    StorePhotos = true,
    ShowPhotoToTarget = false,
    --- How long a verification photo stays attached to a ledger row (§14.43).
    ---
    --- The row itself is kept — a record of what somebody finished is the
    --- point of the ledger — but the photo is the most sensitive thing this
    --- resource stores and was held for the life of the row, which on a
    --- depth-ten ledger can be months. Only the reference is dropped; the
    --- image lives wherever the phone uploaded it, which is not this
    --- resource's to delete. Zero keeps them forever.
    PhotoRetentionDays = 7,
}

--------------------------------------------------------------------------
-- Notifications (§7.3, §14.40)
--------------------------------------------------------------------------

Config.Notifications = {
    ParanoidAlert = true,
    MaxPerRecipientPerMinute = 6,
    MaxPerRecipientPerHour = 40,

    --- Nudge an open app when a contract it is showing changes state, so a
    --- creator watching their own contract sees it get accepted rather than
    --- only hearing the phone. A push carries a reason and nothing else; the
    --- app re-reads through the normal projections.
    PushEnabled = true,
    --- Floor between pushes to one player. Several state changes inside this
    --- window cause one refresh, which is the whole point — the app used to
    --- refresh on every mirrored reply and buried itself.
    PushMinIntervalSeconds = 1,
}

--------------------------------------------------------------------------
-- Persistence (§10)
--------------------------------------------------------------------------

Config.Database = {
    --- 'mysql' | 'json' | 'memory'
    ---
    --- json keeps everything in files under the Directory below and needs
    --- no database at all. Contracts and escrow survive a restart exactly
    --- as they do on mysql; what it does not do is scale to a server with
    --- thousands of live contracts, and it cannot be shared between two
    --- server instances.
    ---
    --- memory keeps nothing: every contract and every escrowed reward is
    --- gone at the next restart, which is why it releases all open escrow
    --- on shutdown rather than losing it.
    Mode = 'json',
    Json = {
        Directory = 'data',
        SyncOnFinancialWrite = true,
        WarnContractCount = 2000,
        --- How many changed contracts one ordinary flush writes. Everything
        --- a contract owns lives in its own file, so a flush is bounded work
        --- rather than a rewrite of the whole store — but a burst of
        --- activity should not turn one flush into a stall either. Anything
        --- over the budget is written on the next flush, and a shutdown
        --- writes all of it regardless.
        MaxDirtyShardsPerFlush = 25,
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

--------------------------------------------------------------------------
-- Staff commands (§4.1 of the improvements document)
--------------------------------------------------------------------------

Config.Admin = {
    Enabled = true,
    --- ACE for reading and for closing a contract. The server console is
    --- always allowed: an owner locked out of their own recovery tools by a
    --- missing ACE has no way back in.
    Ace = 'crimson.admin',
    --- Reading who is behind an anonymous party is gated separately, because
    --- it is a different kind of act from reading a history. Give it to fewer
    --- people than the one above.
    IdentityAce = 'crimson.identity',
    --- Extra ACEs that also open the admin commands.
    ---
    --- `crimson.admin` is this resource's own, and nobody has it until it
    --- is granted. That is right for closing a contract or refunding
    --- escrow — and wrong for the diagnosis command, which is how an owner
    --- finds out why their app is empty and which is the one thing they
    --- need before they have set anything up.
    ---
    --- Anything here is accepted as well. `command` is the ACE most admin
    --- groups already carry.
    ExtraAces = { 'command' },

    --- Command names, without the leading slash.
    Commands = {
        timeline = 'cb-timeline',
        void     = 'cb-void',
        stuck    = 'cb-stuck',
        settle   = 'cb-settle',
        whois    = 'cb-whois',
        --- Reports why the app is not showing something. Runs the same
        --- reads the app does and says what each one answered.
        diagnose = 'cb-diag',
    },
    --- Rows read per contract for a timeline. A cap, because the audit log
    --- is the largest table here and a staff command should not be able to
    --- pull an unbounded amount of it into memory.
    TimelineRows = 200,
}

Config.Debug = false

return Config
