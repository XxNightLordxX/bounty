--- Crimson Hitman System — configuration.
--- Every value here is read by the resource. This file is shared: every
--- player's game downloads it and runs it, so any player can read anything
--- written here. Never put a secret in it (a webhook URL, an API key); the
--- staff webhook is set in server.cfg instead (see the Audit section).
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
    sast = true, k9 = true, ambulance = true, fire = true,
}

--- Off-duty players are still blocked by default: a police officer who clocks
--- off is still a police officer to everyone they arrested this week.
Config.BlockOffDuty = true

--- Keep the app off a barred player's phone entirely, rather than letting
--- them install an app that answers nothing.
---
--- Turning this OFF does not grant anybody access: the gate still refuses
--- every request from a barred job, exactly as it did before this existed.
--- All it changes is whether they can see the icon.
---
--- It is here because hiding the app is the only thing in this resource that
--- can take something away from a player, and anything that can do that
--- needs a switch an operator can reach without waiting for a patch.
Config.HideAppFromBlockedJobs = true

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
---
--- An item reaches the hitman with its metadata, so list anything whose
--- metadata names its owner: identity documents (ox_inventory's
--- `identification` carries the holder's name and date of birth), phones
--- kept as unique items (lb-phone's coloured `phone_*` names, each with its
--- own number), bank cards, and keys or passes from other resources that
--- store an owner or a plate. On an anonymous contract an item whose
--- metadata names the client is refused anyway (it carries a name, an owner
--- or a phone number), but on a named one it is handed over as it is.
---
--- `money` is cash: on Qbox the cash balance is that ox_inventory item.
--- Every item named in the server's `inventory:accounts` convar (default
--- '["money"]') is refused whether it is listed here or not, so cash only
--- goes up through the cash source above, with its switch and its ceiling.
Config.EscrowBlacklist = {
    ['phone'] = true, ['id_card'] = true, ['driver_license'] = true,
    ['weaponlicense'] = true, ['handcuffs'] = true,
    ['identification'] = true, ['lawyerpass'] = true, ['money'] = true,
}

--- Kidnapping bonus. Percentage applies per money source; items are extra
--- lines escrowed alongside the baseline.
Config.Bonus = {
    --- Ceiling on the kidnapping bonus percentage a creator may set.
    maxPercent = 200,
}

--------------------------------------------------------------------------
-- Anonymity (§4)
--------------------------------------------------------------------------

Config.Anonymity = {
    CreatorFee = 0,          -- flat fee, 0 = free
    HitmanFee  = 0,
    FeeAccount = 'bank',     -- 'cash' | 'bank'
}

--------------------------------------------------------------------------
-- Failure penalty (§3.6, §14.18)
--------------------------------------------------------------------------

Config.Penalty = {
    --- The creator names the stake a hitman must put up to accept, and the
    --- server clamps it the same way it clamps the bailout premium and for
    --- the same reason: unclamped, an "accept" is an uncapped transfer of
    --- the hitman's money to the creator, forfeit on abandonment or expiry,
    --- on a contract that need only advertise a token reward. A $1,000
    --- contract could carry a $1,000,000 stake.
    ---
    --- Both ceilings apply; the lower wins. The fraction is of the §9.1
    --- money escrow value, so the stake stays proportional to what the
    --- contract is actually worth.
    MaxAmount = 100000,
    MaxFractionOfEscrow = 2.0,
    --- Acceptance must echo back the stake the hitman was shown (§14.18).
    ---
    --- Disclosure that is not binding is disclosure with a race in it: the
    --- figure on the board is read, the creator repriced the contract, and
    --- Accept charges the new one. The echo makes the two the same number by
    --- construction — a page showing a stale figure is refused rather than
    --- silently repriced, and told to look again.
    ---
    --- Only ever applied to a contract that carries a stake, so a page that
    --- predates this cannot be locked out of the contracts where there is
    --- nothing to disclose.
    RequireDisclosureOnAccept = true,
    --- A staked acceptance is refused with less than this long left before
    --- the deadline (§14.18). A client can set a contract nobody holds to
    --- run out in minutes; without this a hitman could stake on it and lose
    --- the stake to the client almost at once, having had no chance to work
    --- it. Contracts that carry no stake are not affected.
    MinWindowMinutes = 30,
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
    --- A bailout does not resolve instantly once a hitman is engaged: the
    --- hitman gets this long to complete before it takes effect, so a target
    --- cannot rug-pull a hitman mid-fight. A kill still waiting for its
    --- photo, or a handover still counting down, when it runs out holds it
    --- off until that finishes, for at most two PhotoTokenLifetimeSeconds
    --- more: the hitman was told to finish it first, and had.
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
    MaxAcceptedPerHitman         = 3,
    MaxActiveContractsPerTarget  = 2,
    MaxHitmenPerContract        = 5,

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
    --- The same hitman may not claim two slots inside this window. Without
    --- it a multi-slot contract becomes a respawn-camping machine.
    SlotCooldownSeconds          = 600,

    TargetCooldownAfterResolveSeconds = 1800,
    SameCreatorSameTargetCooldownSeconds = 7200,

    ContractLifetimeSeconds = 172800,   -- absolute ceiling, pause included
    --- How long a contract runs before it expires, unless the client
    --- extends it. A kill made before it that is still waiting for its
    --- photo, or a handover still counting down, holds the expiry off until
    --- it finishes, for at most two Completion.PhotoTokenLifetimeSeconds.
    DefaultDeadlineSeconds  = 10800,
    --- The deadline stops while the target is in prison, as it does while
    --- they are offline, and is moved on by however long they served. The
    --- lifetime above still ends the contract. In prison means a sentence
    --- ('injail' metadata, as sc-police writes it) AND standing inside
    --- JailZone: sc-police lets a client write the sentence for itself, so
    --- the metadata alone would let a target stop the clock from anywhere.
    PauseWhileTargetJailed  = true,
    --- The prison grounds, as a centre and a radius in metres. Bolingbroke
    --- by default; set it to your prison if it is elsewhere.
    JailZone = { x = 1693.3, y = 2569.5, radius = 300 },

    --- An exclusive contract goes back on the board when the one operative
    --- holding it has not been near the target for this long (§14.8). The
    --- clock only runs while the client and the target are both in the
    --- city, their stake is returned, and they may not take that contract
    --- again on any character. 0 turns it off.
    ---
    --- Without it a target's friend could take the contract on them and sit
    --- on it: the client cannot cancel a held contract and nobody else can
    --- take an exclusive one, so it was frozen until its deadline ran out.
    ExclusiveIdleReleaseSeconds = 1800,
    --- And one who is near the target but never makes an attempt on them —
    --- no hit landed, no handover armed — for this long, counted the same
    --- way, is released the same way. Being near is what a target's friend
    --- does best, so on its own it reset the clock above for ever. 0 turns
    --- it off.
    ExclusiveAttemptWindowSeconds = 7200,
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
    --- Faults the page reports about itself. Generous enough that a genuinely
    --- broken screen gets its report through, tight enough that a client
    --- posting straight at the endpoint cannot fill the audit log with it.
    diagnostic  = { per = 60, burst = 10 },
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
    --- Submitting one. Separate from asking for a token, because both used
    --- to bill `photo` and one verification therefore cost two attempts —
    --- with the second charged after the photograph had been taken.
    --- A refusal is given back, as everywhere, except one that came after
    --- the server read the picture ('server' storage): that keeps its
    --- charge, so this is also how often a hitman can have the server
    --- decode a picture.
    photoSubmit = { per = 15, burst = 5 },
    --- Opening a kill photo from the Ledger. Each photo opens once, so this
    --- only has to stop somebody trying handles.
    photoView = { per = 10, burst = 5 },
    --- Saving or deleting the photo just opened. Separate and looser, as
    --- submitting one is: refused, a photo the client had already saved to
    --- their phone was recorded as deleted when it timed out.
    photoDecide = { per = 5, burst = 5 },
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
    --- metadata (metadata.playtime, in minutes). To use another script, give
    --- its resource and export, e.g.
    ---   PlaytimeProvider = { resource = 'my_playtime', export = 'GetMinutes' },
    --- It is called as exports.my_playtime:GetMinutes(citizenid) and must
    --- return TOTAL MINUTES played, as a number. An export that answers in
    --- hours or seconds makes the playtime floor wrong for everyone. If the
    --- call errors or returns a non-number, metadata is used instead. If
    --- nothing can answer, the playtime rule is skipped and the resource says
    --- so at startup — it does not silently refuse everyone.
    PlaytimeProvider = nil,
}

--------------------------------------------------------------------------
-- Completion (§7.4, §14.2, §14.20)
--------------------------------------------------------------------------

Config.Completion = {
    --- Where kill photos are kept: 'server' (the default) or 'host'.
    ---
    --- 'server' needs no image host at all. The hitman takes the photo in
    --- this app's own viewfinder (lb-phone's game camera, drawn inside the
    --- app), and it is sent to this server and kept as a file in
    --- data/photos/ inside this resource. Deleting a photo deletes the file.
    --- The server must be able to write to that folder.
    ---
    --- 'host' uses lb-phone's own camera, which uploads the photo to the
    --- image host lb-phone is set up with (Fivemanage, for instance), and
    --- this resource keeps only the link. Deleting a photo then only makes
    --- the app forget the link: the file stays on the host, because
    --- lb-phone gives a resource no way to delete it. ExtraPhotoHosts and
    --- PhotoHostRefreshSeconds apply to this mode only.
    ---
    --- Either way the photo never stays on the hitman's phone, and the
    --- client who placed the contract can open it once (see
    --- PhotoOpenSeconds and Config.Ledger). Anything else is read as
    --- 'server', with a warning at startup. /ch-diag says which is in use.
    ---
    --- On 'server', Save to Photos needs a link, because lb-phone's Photos
    --- keeps links, not pictures. This server serves the photo itself when
    --- it has a public https address (PhotoPublicUrl, or web_baseUrl).
    --- Without one, the app uses lb-phone's own upload if the phone has
    --- one; failing both, the photo is kept for the client in this app
    --- instead (KeptPhotoDays).
    PhotoStorage = 'server',
    --- 'server' storage only: the public https address that serves photos
    --- the client saves to their phone's Photos, with no image host. Set it
    --- to the address that reaches this resource over https, such as
    --- 'https://photos.example.com/crimson-hitman' (a photo is then
    --- https://photos.example.com/crimson-hitman/p/<name>.webp). Left unset,
    --- the server's web_baseUrl is used instead: 'https://<web_baseUrl>/
    --- crimson-hitman'. Cfx.re's own *.users.cfx.re addresses stopped
    --- working on 30 June 2026; Qbox's free Nucleus replacement gives you
    --- one (set web_baseUrl "<name>.server.qbox.re" in server.cfg), or put
    --- your own https proxy in front of the server.
    ---
    --- Whichever it is, add its host name to Config.UploadWhitelistedHostnames
    --- in lb-phone's config, or the phone may refuse to save the photo.
    --- /ch-diag says which address is used and whether lb-phone allows it.
    --- With no address at all, the app uses lb-phone's own upload, or keeps
    --- the photo in the app.
    PhotoPublicUrl = nil,
    --- How many days a photo kept for its client in this app (because
    --- their phone could not save it) lasts before it is deleted, counted
    --- from when it was kept. Unset, it stays until they delete it
    --- themselves. /ch-diag says how many are kept and how much disk they
    --- take.
    KeptPhotoDays = nil,
    --- 'server' storage only: how big a kill photo may be. The app shrinks
    --- the photo until its longest side is at most PhotoMaxSide pixels
    --- (320 to 4096) and it weighs at most PhotoMaxBytes bytes (50000 to
    --- 4000000), and the server refuses anything bigger. Every photo is
    --- sent to the server and, when opened, back out to the client's phone,
    --- so keep these modest: the defaults give a clear photo of a few
    --- hundred kilobytes. The server also decodes each photo it keeps, in
    --- Lua on its main thread: about 60ms at the default size, half a
    --- second at the largest, once per kill.
    PhotoMaxSide = 1280,
    PhotoMaxBytes = 600000,

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
    --- 'host' storage only: how often the photo host allowlist is re-read
    --- from lb-phone's upload config. Read only at boot, an owner who
    --- changed upload provider had to restart this resource too, and the
    --- failure mode is every verification photo being rejected.
    PhotoHostRefreshSeconds = 300,
    --- How long before a death a hit still counts towards it. The kill goes
    --- to the hitman the target's own game names, if the server saw a hit of
    --- theirs land; otherwise to whoever on the contract it saw do the most
    --- damage in this time. A death the target's game never reports (it
    --- crashed or quit, or never sends it) is attributed by the server
    --- itself a few seconds later, the second way.
    DeathReportWindowMs = 30000,
    --- A killer named by their victim must also appear in the damage log
    --- the server built for itself. The victim naming them is a client
    --- saying so; without this a hitman can be credited for a target the
    --- server never observed them touch.
    ---
    --- The cost is that a kill by something that raises no weapon damage
    --- event — an explosive (a grenade, a sticky bomb, a rocket), fire, a
    --- vehicle, a fall — pays nobody, which is the safer side of the trade:
    --- only gunfire and melee count. Verify kill tells the hitman the
    --- target's game named so. Turn it off only if that matters more than
    --- the attribution being observed.
    RequireObservedDamage = true,
    --- The defibrillator the kill logic listens for. sc-ambulance's brings a
    --- dead player back to last stand after a gap in which they read as up;
    --- that gap is never a revive, whatever lands in it. Match these to
    --- sc-ambulance's own Config.Defib: MedicJobs to its RequireEMS job
    --- (false when RequireEMS is false: any job; {} when its defibrillator
    --- is off: none), DefibItem to its Item, DefibRange to its Distance.
    MedicJobs = { ambulance = true },
    DefibItem = 'defibrillator',
    DefibRange = 3.0,
    --- How often the condition of a live contract's target is sampled.
    ---
    --- A damage event is credited with the drop the server sees across it:
    --- one already showing since the last sample, or one that appears in the
    --- second after it (the damage reaches the server after the event). The
    --- target's own game says who last damaged them, and a drop it puts down
    --- to somebody else — an NPC, a player with no hit waiting — goes to no
    --- hit. Where it says nothing (sc-ambulance clears it within a tenth of a
    --- second), a slow sampler lets a hitman who lands one shot inherit
    --- whatever else happened to the target in between — a fall, a blast.
    --- Bounded by the number of live contracts.
    ConditionSampleMs = 1000,
    --- How far a hit is believed from, in metres. A hit from further, and
    --- a killer the target's game names from further, is dropped. Keep it
    --- at least OneSync's player culling radius (424 m unless the server
    --- changes it): players are in each other's game, and can shoot each
    --- other, out to there, and a sniper's kill beyond this pays nobody.
    MaxWeaponRange      = 425.0,
    --- How close to the body the hitman must stand for the photo: to where
    --- it lay when the death was recorded, or to where it lies now, while
    --- the target is online and still dead (a car rolling on, a body
    --- carried off).
    PhotoRadius         = 5.0,
    PhotoTokenLifetimeSeconds = 120,
    --- How long the client may look at a kill photo once they open it.
    --- They see it once, with a Save to Photos button (or Save, to keep it
    --- in the app, where their phone cannot take it) and a Delete button;
    --- a photo still open after this many seconds without either (the
    --- phone closed mid-view, say) is deleted as if they had tapped Delete.
    PhotoOpenSeconds = 600,
    --- How long after a death the proof is still accepted even if the target
    --- is back on their feet.
    ---
    --- Without this the elimination path barely works: players respawn in
    --- seconds, and a hitman standing over the body would lose the payout to
    --- the target pressing respawn. The kill genuinely happened, the hitman
    --- is still at the recorded scene, and the window is short.
    ProofWindowSeconds = 60,
    --- 'host' storage only: a kill photo's URL is accepted only from a host
    --- lb-phone itself takes uploads from (UploadWhitelistedDomains /
    --- UploadWhitelistedHostnames in lb-phone's config), plus these. Bare
    --- domains, no https:// and no path: each also covers its subdomains.
    --- Shipped with Fivemanage, lb-phone's default uploader; add your own
    --- if the phone uploads elsewhere. /ch-diag lists what is allowed.
    ExtraPhotoHosts = { 'fivemanage.com', 'fmfile.com' },
}

Config.Kidnap = {
    CountdownSeconds   = 30,
    Radius             = 12.0,
    MaxTotalGraceMs    = 3000,
    TickMs             = 1000,
    MaxConcurrentCountdowns = 20,
    --- How long a hitman must wait before re-arming a handover that failed
    --- on this contract. The countdown itself is bounded by the grace
    --- budget; without this the *retrying* is not, and a hitman whose client
    --- never turns up can hold a target in a loop at no cost.
    RearmCooldownSeconds = 60,
    --- A kidnapping is a *live* delivery. The target must be conscious the
    --- whole way: not dead, not downed / bleeding out, and above the health
    --- floor. Both states are re-checked on every countdown sample, so a
    --- target who dies or goes down mid-countdown fails the delivery.
    RequireConscious   = true,
    RejectDead         = true,
    RejectLastStand    = true,
    --- Below this (health above the 100 that is dead, out of 100) the target
    --- is too badly hurt to hand over, and the hitman is told so. Qbox gives
    --- no health back on its own and bleeding takes more, so a target shot
    --- during the abduction needs patching up first.
    MinTargetHealthPercent = 20,
    --- Observable coercion: the target must be restrained or under the
    --- hitman's physical control. Any enabled detector satisfies it.
    RequireCoercion    = true,
    Coercion = {
        handcuffed        = true,   -- QBox metadata 'ishandcuffed'
        passengerOfHitman = true,   -- target is in the hitman's vehicle
    },
    --- Optional resource exposing IsRestrained(playerId) for custom rope /
    --- ziptie scripts, by its name: RestraintProvider = 'my_ropes'. Leave
    --- nil if unused.
    RestraintProvider  = nil,
}

--------------------------------------------------------------------------
-- Tracking, mugshots and listings (§14.22, §14.26, §14.33)
--------------------------------------------------------------------------

--- Headshots are rendered by each target's own phone with MugShotBase64.
--- Without that resource started on the server, none is asked for and none
--- is accepted: the board shows no faces rather than whatever picture a
--- modified client sends.
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
    --- same opaque, per-searcher, expiring handles as a name search), where
    --- anybody is (that is the nearby list below, which ships off), jobs
    --- beyond the protected flag, or anything about players sharing the
    --- browser's own account. It is rate-limited like every other listing.
    ---
    --- Set false to go back to requiring a typed name.
    AllowBrowseAll = true,
    --- Names per page when browsing. A page is one round trip and one
    --- render, so this bounds both.
    BrowsePageSize = 30,

    --- Let a player list the names of the people standing around them.
    ---
    --- Off, because what it gives away is more than it looks. The server
    --- knows where everyone is, whatever the walls, the dark or the clothes,
    --- so on it any player holding the app can put a name to anyone within
    --- NearbyRadius, and ask again a second later as they move. A target
    --- named the anonymous hitman closing in on them that way, a hitman
    --- named the anonymous client standing beside him at a handover, and
    --- anyone could name a masked robber.
    ---
    --- Turned on, it leaves out: players in another routing bucket, players
    --- who are invisible (noclip, spectating staff), and anyone wearing a
    --- mask. It is closed altogether, to the player asking, while they are
    --- on a live contract: one they placed, one they hold, or one on them
    --- that they have been shown (they can still pick a target by name, or
    --- from everyone online). Distance goes out only as "under 10m",
    --- "under 20m" and so on, and the list is ordered by that and by name.
    --- What it cannot stop: a friend who is on no contract standing next to
    --- a target and reading off the names around them. That is why it is
    --- off.
    AllowNearby = false,
    --- Metres. Roughly a street: close enough that you are looking at them.
    NearbyRadius = 30.0,
    --- How many names to list, nearest band first.
    MaxNearby = 12,
    --- Protected-job players may be targeted by default: putting a hit on a cop is
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
    TriggerJobNames = { doj = true, lawyer = true, ranger = true, sast = true, k9 = true },
    --- Who receives the advisory. Law enforcement only by default; EMS are
    --- not a response unit for a contract killing.
    RecipientJobTypes = { leo = true, police = true },
    RecipientJobNames = {
        police = true, sheriff = true, bcso = true, fib = true,
        trooper = true, sasp = true, ranger = true, sast = true, k9 = true,
    },
    --- Also raise a dispatch entry through sc-dispatch when present.
    UseDispatch = true,
    DispatchPriority = 1,
    --- The targeted officer is always told, whatever the paranoid-alert
    --- setting says — they cannot open the app to check for themselves.
    AlwaysAlertTarget = true,
    --- Warn the creator before escrow is taken, and the hitman before they
    --- accept, that the target is law enforcement. The listing also carries a
    --- permanent flag. Nobody puts a hit on a cop by accident.
    --- Advisories fire when the contract is posted and again when each
    --- operative accepts, carrying the running count, so one contract raises
    --- one acceptance bulletin per operative who takes it up. One who walks
    --- away and comes back raises no second. The dispatch entry for
    --- acceptances shares one id per contract.
    OnCreate = true,
    OnAccept = true,
    WarnCreator = true,
    WarnHitman = true,
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
    --- The newest messages a thread keeps; older ones go as new ones
    --- arrive. Every read sends the whole thread to a phone, and a thread
    --- could otherwise grow for a contract's whole life — a message a
    --- second for two days is tens of megabytes on every read.
    MaxMessagesPerThread = 100,
    AllowMaskedCalls = true,

    --- An override for the export that places a call. Leave it nil.
    ---
    --- Calls go through lb-phone's documented server export CreateCall,
    --- with the caller's alias as the number the other phone shows. lb-phone
    --- draws no call screen for those, so the app's thread gets a Hang up
    --- button (lb-phone's EndCall). Whether CreateCall exists is probed, not
    --- assumed; on a build without it the Call button is not drawn.
    ---
    --- Set `resource` and `export` only to use a call export of your own
    --- instead. It is probed the same way — it must exist and be callable —
    --- and when it does not resolve, nothing is dialled. It is called as
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
    --- Only a hitman the server has actually seen near the target may be
    --- named (§6.1). A hitman who pressed accept and did nothing is not
    --- tracking anyone, and revealing them turns the purchase into a roster
    --- dump. Proximity is observed by the condition sampler; nothing is ever
    --- taken from a client's word for where it is.
    RequireProximity = true,
    ProximityRadius = 120.0,
    --- How long an observation counts for. Long enough that a hitman who
    --- tailed you and backed off is still named; short enough that one who
    --- walked past yesterday is not.
    ProximityWindowMinutes = 10,
    RerollLockMinutes = 30,
    MaxPurchasesPerContract = 2,
}

Config.Ledger = {
    Depth = 10,
    MaxDepthHardCap = 25,
    --- Whether a kill photo is kept for the client who placed the contract.
    --- Only they ever see it: never the hitman, never the target. Off, the
    --- client is told their contract was fulfilled and there is no photo to
    --- open, and on 'server' storage the photo is never written to disk.
    StorePhotos = true,
    --- How long a kill photo the client has not opened is kept (§14.43).
    ---
    --- The ledger row stays — a record of what somebody finished is the
    --- point of the ledger — but a photo of somebody's corpse is the most
    --- sensitive thing this resource stores. Past this age it is forgotten
    --- whatever became of it, and an unopened one is deleted. On 'server'
    --- storage its file is deleted. On 'host' storage that forgets the
    --- link; the file stays on the image host, which is not this
    --- resource's to delete. Zero keeps an unopened photo until its
    --- ledger row goes.
    ---
    --- Not a photo the client chose to keep in the app (see
    --- Config.Completion.KeptPhotoDays), nor one in their phone's Photos
    --- through a link this server serves, which goes when they delete it
    --- there. Neither goes with its ledger row either.
    PhotoRetentionDays = 7,
}

--------------------------------------------------------------------------
-- Notifications (§7.3, §14.40)
--------------------------------------------------------------------------

Config.Notifications = {
    ParanoidAlert = true,
    --- Seconds the target's alert waits after the contract is placed, drawn
    --- at random between these two, so it does not date the placement to
    --- the second for somebody who paid to stay unnamed (§14.40).
    ---
    --- The same wait, drawn once per contract, holds back everything else
    --- the target could learn it from, whether or not ParanoidAlert is on:
    --- the contract shows on their On me tab and in /cleanse only when it is
    --- over, their headshot is not asked of their phone before then (so the
    --- board shows no face for a new target until it is, unless one is
    --- already cached), and the nearby list stays open to them meanwhile.
    --- An officer whose department is advised at once is not held back.
    --- Kept in memory: after a restart every contract shows at once.
    ParanoidAlertJitter = { min = 60, max = 600 },
    --- And at most one per target in this many minutes, however many
    --- contracts are placed on them, so neither do the alerts count them.
    ParanoidCooldownMinutes = 30,
    --- Phone notifications one player can be sent, per minute and per hour.
    --- A message into a thread they muted is counted here and not sent, so
    --- the sender cannot tell a muted thread from one that rang.
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
    ---
    --- Modes do not share data: a server switched from one to another
    --- starts with nothing in the new one. So it refuses to start while the
    --- mode it left still holds players' money — escrow not yet settled, or
    --- payouts owed to somebody offline — and says where. Let those
    --- contracts finish in the old mode first (README, Changing storage
    --- mode). Kill photo files kept for the old mode are left alone too.
    Mode = 'json',
    --- true starts in the mode above even though another mode still holds
    --- players' money. That money is then invisible from here and nothing
    --- returns it, so only for a server that has settled it by hand.
    AllowModeSwitch = false,
    --- json keeps its files in the resource folder, so an update that
    --- replaces the folder takes them with it: keep data/ when updating
    --- (README, Updating). The server also remembers, outside the folder,
    --- that the store has run, and refuses to start empty where it has;
    --- `set crimson_hitman_new_store 1` in the server console starts empty
    --- on purpose, once.
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
    --- In json mode the log is one file per day in the data directory, and a
    --- day's file is deleted once the whole day is older than this.
    RetentionDays = 30,   -- 0 keeps the audit log forever
    --- How long a finished contract and its rows are kept, in days. 0 keeps
    --- them forever, which is what this did before it was a setting.
    ---
    --- Nothing pruned contracts, so every full scan in the resource walked
    --- the server's whole history rather than its live board — the board
    --- projection per player per board open, the death sampler once a
    --- second, the bailout queue every tick — and all of them grew without
    --- bound for the life of the database.
    ---
    --- A contract is only ever removed once it is finished, past this age,
    --- holds no escrow line that is not settled, and owes nobody anything
    --- on login. Ledger history is not touched: it is the player's own
    --- record and carries its own copy of what it needs.
    ContractRetentionDays = 30,
    --- How many contracts one maintenance tick may remove. A first prune on
    --- a long-lived database has a lot to get through, and doing it all in
    --- one tick would stall the server.
    ContractsPrunedPerTick = 200,
    --- The staff webhook is set in server.cfg, never here: this file is sent
    --- to every player's game, and anyone holding the URL can post into the
    --- staff channel or delete the hook.
    ---   set crimson_hitman_webhook "https://discord.com/api/webhooks/..."
    --- `set`, never `setr`: setr sends the value to every player as well.
    --- Financial movements and rejected attempts are mirrored there as a
    --- heads-up; identity is never included, because anything sent to a
    --- third party outlives this server's retention rules.
}

Config.AntiCollusion = {
    --- Compares creator / hitman / target account identifiers. A shared
    --- account is blocked outright. Households are deliberately not
    --- considered: families and roommates share a connection, and blocking
    --- or flagging them would punish ordinary players.
    BlockSameAccount = true,
}

--------------------------------------------------------------------------
-- Progression
--------------------------------------------------------------------------

--- Completing a contract feeds the server's existing criminal progression,
--- so the contract board is part of the criminal economy rather than a
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
    --- Anything here is accepted as well, for the read-only commands only
    --- (diag, timeline, stuck, contracts). Void, settle and whois move money or unmask
    --- an anonymous party, so they need the named ACE itself. `command` is
    --- the ACE most admin groups already carry.
    ExtraAces = { 'command' },

    --- Command names, without the leading slash.
    Commands = {
        timeline = 'ch-timeline',
        void     = 'ch-void',
        stuck    = 'ch-stuck',
        settle   = 'ch-settle',
        whois    = 'ch-whois',
        --- Lists a player's contracts with the ids the commands above take.
        contracts = 'ch-contracts',
        --- Reports why the app is not showing something. Runs the same
        --- reads the app does and says what each one answered.
        diagnose = 'ch-diag',
        --- Brings every wait forward so a test server can be tested. ACE
        --- only — the extra ACEs above do NOT open it, because it writes.
        refresh  = 'hitmanadmin',
    },
    --- Rows read per contract for a timeline. A cap, because the audit log
    --- is the largest table here and a staff command should not be able to
    --- pull an unbounded amount of it into memory.
    TimelineRows = 200,
}

Config.Debug = false

return Config
