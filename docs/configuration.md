# Configuration reference

Every setting in `config/config.lua`, in its sections and order (the admin
panel's), with the value it ships with and its note from the file. Generated
from config.lua (`tests/docs_spec.lua` checks every row). `config/defaults.lua`
holds the same values and only fills a section missing from an older
`config.lua`; it is not the file to edit. Most settings can also be changed
live in the admin panel, which keeps the change over this file.

## Debug and storage

The console output, and where contracts and money are kept. Switching storage mode starts empty in the new one and refuses to start while the old one still holds money (README, Changing storage mode).

| Setting | Shipped | What it does |
|---|---|---|
| `Config.Debug` | `true` | debug lines in the console and F8; false = only what needs you |
| `Config.Locale` | `'en'` | the language players and staff read: the locales/ file of that name |
| `Config.Database.Mode` | `'mysql'` | 'json' \| 'mysql' \| 'memory' (testing only) |
| `Config.Database.AllowModeSwitch` | `false` | start even though the old mode still holds money |
| `Config.Database.QueryTimeoutSeconds` | `10` | mysql: seconds a statement may go unanswered; 0 = forever |
| `Config.Database.Json.Directory` | `'data'` | folder inside the resource |
| `Config.Database.Json.SyncOnFinancialWrite` | `true` | write money changes to disk at once |

## Other scripts

Which of your other scripts this resource works with, one per kind (docs/dev/adapters.md). 'auto' uses the first one installed and started; a name uses that one only; 'none' turns off what needs it, said in one console line at start. Your own adapter goes in server/adapters/list.lua.

| Setting | Shipped | What it does |
|---|---|---|
| `Config.Integrations.Framework` | `'auto'` | 'auto' \| 'qbx_core' (required: no 'none') |
| `Config.Integrations.Inventory` | `'auto'` | 'auto' \| 'ox_inventory' \| 'none' (item rewards) |
| `Config.Integrations.Target` | `'auto'` | 'auto' \| 'ox_target' \| 'none' (third-eye options) |
| `Config.Integrations.Dispatch` | `'auto'` | 'auto' \| 'sc-dispatch' \| 'none' (police MDT) |
| `Config.Integrations.Ambulance` | `'auto'` | 'auto' \| 'sc-ambulance' \| 'qbx_medical' \| 'none' |
| `Config.Integrations.Banking` | `'auto'` | 'auto' \| 'Renewed-Banking' \| 'none' (organisation funds) |
| `Config.Integrations.Phone` | `'auto'` | 'auto' \| 'lb-phone' \| 'none' (the phone app) |
| `Config.Integrations.Keys` | `'auto'` | 'auto' \| 'qbx_vehiclekeys' \| 'none' (disposal vehicle) |
| `Config.Integrations.Garage` | `'auto'` | 'auto' \| 'onesync' \| 'none' (organisation garage vehicles) |
| `Config.Integrations.Mugshot` | `'auto'` | 'auto' \| 'MugShotBase64' \| 'none' (target headshots) |
| `Config.Integrations.Clothing` | `'auto'` | 'auto' \| a clothing adapter's name \| 'none' |
| `Config.Integrations.Progression` | `'auto'` | 'auto' \| 'sc-blackmarket' \| 'none' (trust per kill) |

## Rules: Timers

How long things last. The deadline runs only while the placer, the target and one operative are all in the city, and pauses before a restart.

| Setting | Shipped | What it does |
|---|---|---|
| `Config.Limits.DefaultDeadlineSeconds` | `10800` | run time; runs only with placer, target, operative in |
| `Config.Limits.ContractLifetimeSeconds` | `172800` | hard ceiling, pauses included |
| `Config.Limits.StaffDeadlineMaxAdjustSeconds` | `86400` | most staff may extend or shorten a deadline by at once |
| `Config.Limits.StaffDeadlineMinLeftSeconds` | `300` | least run time a staff shortening may leave |
| `Config.Limits.TargetCooldownAfterResolveSeconds` | `1800` | nobody may target a person again for this long |
| `Config.Limits.SameCreatorSameTargetCooldownSeconds` | `7200` | the same placer on the same target |
| `Config.Limits.ExclusiveIdleReleaseSeconds` | `1800` | release an exclusive hitman never near them; 0 = off |
| `Config.Limits.ExclusiveAttemptWindowSeconds` | `7200` | release one who never makes an attempt; 0 = off |
| `Config.Limits.PauseWhileTargetJailed` | `true` | the deadline stops while the target serves time |
| `Config.Limits.JailZone` | `{ radius = 300, x = 1693.3, y = 2569.5 }` | the prison grounds |
| `Config.Holds.AppPaused` | `false` | pause the whole app: no placing, no accepting, clocks held |
| `Config.Holds.RestartPauseBeforeSeconds` | `1800` | pause every contract this long before a txAdmin restart; 0 = off |
| `Config.Holds.RestartMaxHoldMinutes` | `45` | end the restart pause if the restart has not come by then |

## Rules: Rewards and money

What a reward may be made of and how big it may be, payouts, stakes and buyouts. Every reward is held in escrow from placing until the end.

`Config.Sources`: one row for each entry.

| Setting | Shipped | What it does |
|---|---|---|
| `Config.Sources.cash` | `{ enabled = true, max = 250000 }` | cash, at most this much |
| `Config.Sources.bank` | `{ enabled = true, max = 500000 }` | bank money |
| `Config.Sources.dirty` | `{ enabled = true, item = 'black_money', max = 250000 }` | dirty money, as this item |
| `Config.Sources.item` | `{ enabled = true, maxPerStack = 100, maxStacks = 10 }` | items: stacks, and per stack |
| `Config.Sources.weapon` | `{ enabled = true, max = 3 }` | weapons |
| `Config.MaxContractValue` | `1000000` | most a contract may hold, in money |
| `Config.EscrowBlacklist` | `{ driver_license = true, handcuffs = true, id_card = true, identification = true, … 8 in all }` | items that may never be put in a reward |
| `Config.Bonus.maxPercent` | `200` | under 'either': most a kidnapping bonus may add |
| `Config.Limits.MinContractReward` | `1000` | least a reward may be worth in money; 0 = off |
| `Config.Limits.MaxPayoutSlots` | `1` | each contract pays out once |
| `Config.Limits.SlotCooldownSeconds` | `600` | a hitman's wait between two payouts on one contract |
| `Config.Limits.MaxEscrowLines` | `60` | escrow lines one contract may hold |
| `Config.Penalty.MaxAmount` | `100000` | most stake a hitman may be asked for |
| `Config.Penalty.MaxFractionOfEscrow` | `2.0` | and at most this times the reward |
| `Config.Penalty.RequireDisclosureOnAccept` | `true` | accept must echo the stake it was shown |
| `Config.Penalty.MinWindowMinutes` | `30` | no staked accept with less than this left |
| `Config.PendingEscrow.MaxRetriesPerLogin` | `5` | owed payouts one retry pass tries |
| `Config.PendingEscrow.LoginRetryDelayMs` | `5000` | wait after a login before paying what is owed |
| `Config.Bailout.Enabled` | `true` | a target may buy out a contract on them |
| `Config.Bailout.MinMultiplier` | `1.0` | least buyout price, times the reward |
| `Config.Bailout.MaxMultiplier` | `3.0` | most buyout price, times the reward |
| `Config.Bailout.AbsoluteMax` | `500000` | most buyout price in money |
| `Config.Bailout.ProcessingDelaySeconds` | `120` | a held contract's hitman gets this long first |
| `Config.Bailout.BlockWhileIncapacitated` | `true` | no buyout while dead or downed |
| `Config.Bailout.Command` | `'cleanse'` | the buyout command, for players who cannot open the app |

## Rules: Limits

How many contracts a player may place, take or carry, and how one is finished: as shipped, a live handover to the placer only.

| Setting | Shipped | What it does |
|---|---|---|
| `Config.Limits.MaxActiveContractsPerCreator` | `3` | live contracts one player may place |
| `Config.Limits.MaxAcceptedPerHitman` | `3` | live contracts one hitman may hold |
| `Config.Limits.MaxActiveContractsPerTarget` | `2` | live contracts on one person |
| `Config.Limits.MaxContractsPerTargetPerDay` | `0` | contracts placed on one person in a rolling 24 h; 0 = off |
| `Config.Limits.MaxContractsPerTargetPerWeek` | `0` | contracts placed on one person in a rolling 7 days; 0 = off |
| `Config.Limits.MaxHitmenPerContract` | `5` | hitmen on one competitive contract |
| `Config.Completion.Fulfilment` | `'alive'` | 'alive' (live handover only) \| 'either' (a kill too) |
| `Config.Completion.KillPhotos` | `false` | under 'either': true = a photo, false = at the scene |
| `Config.Completion.PhotoStorage` | `'server'` | 'server' (file in data/photos) \| 'host' (lb-phone's) |
| `Config.Completion.ProofWindowSeconds` | `60` | a kill still verifies this long after death |
| `Config.Completion.PhotoTokenLifetimeSeconds` | `120` | seconds a kill waits to be verified |
| `Config.Completion.PhotoRadius` | `5.0` | metres from the body to verify a kill |
| `Config.Completion.PhotoOpenSeconds` | `600` | seconds the placer may view a photo before it is deleted |
| `Config.Kidnap.CountdownSeconds` | `30` | seconds the handover is held |
| `Config.Kidnap.Radius` | `12.0` | metres: target, hitman and placer within this of each other |
| `Config.Kidnap.RequireCoercion` | `false` | true = the target must also be cuffed or in the hitman's car |
| `Config.Kidnap.Coercion.handcuffed` | `true` | QBox metadata 'ishandcuffed' |
| `Config.Kidnap.Coercion.passengerOfHitman` | `true` | target in the hitman's vehicle |
| `Config.Kidnap.MeetingPoint` | `true` | the placer may set a meeting point for the hitmen |
| `Config.Kidnap.RequireConscious` | `true` | target conscious the whole time (always under 'alive') |
| `Config.Kidnap.RejectDead` | `true` | refuse a dead target (always under 'alive') |
| `Config.Kidnap.RejectLastStand` | `true` | refuse a downed target |
| `Config.Kidnap.MinTargetHealthPercent` | `20` | refuse a target hurt below this |
| `Config.Kidnap.RearmCooldownSeconds` | `60` | wait after a failed handover before arming again |
| `Config.Kidnap.PlacerConfirms` | `false` | true = the placer taps Confirm handover before it pays |
| `Config.Kidnap.ConfirmSeconds` | `60` | seconds the placer has to confirm (10-600) |
| `Config.Kidnap.ConfirmMissed` | `'rearm'` | no answer in time: 'rearm' (nothing paid) \| 'pay' |
| `Config.Kidnap.MaxDeclines` | `2` | declines (or missed windows) a contract gets; then it pays |
| `Config.Reason.Mode` | `'freetext'` | 'preset' \| 'freetext' \| 'off' |
| `Config.Reason.MaxLength` | `140` | characters (255 at most on mysql) |
| `Config.Reason.MaxDigits` | `6` | digits allowed, so no phone numbers |
| `Config.Reason.Presets` | `{ 'Unpaid debt', 'Snitching', 'Territory dispute', … 6 in all }` | the choices in 'preset' mode |
| `Config.Reason.PatternDenylist` | `{ 'https?://', 'discord%.gg', 'www%.', … 4 in all }` | Lua patterns a reason may not contain |
| `Config.Listing.PageSize` | `15` | contracts per board page |
| `Config.Ledger.Depth` | `10` | ledger rows kept per player |
| `Config.Ledger.MaxDepthHardCap` | `25` | ceiling on Depth |
| `Config.Ledger.StorePhotos` | `true` | keep a kill photo for the placer (KillPhotos only) |
| `Config.Ledger.PhotoRetentionDays` | `7` | days an unopened photo is kept; 0 = with its row |

## Rules: Targeting

Who may open the app and who can be named as a target. Law enforcement, EMS and fire jobs are barred by job type and by name, legal jobs by name; with the whitelisted-job view on they get one read-only screen instead.

| Setting | Shipped | What it does |
|---|---|---|
| `Config.BlockedJobTypes` | `{ ems = true, fire = true, leo = true, police = true }` | job types barred from the app |
| `Config.BlockedJobNames` | `{ ambulance = true, bcso = true, doj = true, fib = true, … 14 in all }` | job names barred from the app, alongside the types |
| `Config.BlockOffDuty` | `true` | barred jobs stay barred off duty |
| `Config.HideAppFromBlockedJobs` | `true` | hide the icon from barred jobs (only while the view is off) |
| `Config.WhitelistedView.Enabled` | `true` | barred jobs see one read-only screen: the contracts on them |
| `Config.WhitelistedView.Alerts` | `true` | they may turn on Notify me for new entries there |
| `Config.Targeting.MinQueryLength` | `3` | letters before a name search runs |
| `Config.Targeting.MaxResults` | `8` | names a search returns |
| `Config.Targeting.AllowBrowseAll` | `true` | list everyone online by name |
| `Config.Targeting.BrowsePageSize` | `30` | names per page when browsing |
| `Config.Targeting.AllowNearby` | `false` | list the people around the placer (names people: keep off) |
| `Config.Targeting.NearbyRadius` | `30.0` | metres for the nearby list |
| `Config.Targeting.MaxNearby` | `12` | names in the nearby list |
| `Config.Targeting.NearbyClosedAfterSeconds` | `1800` | nearby list closed to a contract's parties after it ends |
| `Config.Targeting.AllowProtectedJobTargets` | `true` | officers may be targeted (the advisory tells them) |
| `Config.Immunity.MinTargetPlaytimeHours` | `5` | hours played before anyone can be a target; 0 = off |
| `Config.Immunity.MinTargetSessionMinutes` | `10` | and this many minutes in the city this session |
| `Config.Immunity.PostRespawnSeconds` | `300` | protected this long after a respawn (not a handover) |
| `Config.Immunity.AfterBailoutSeconds` | `3600` | nobody may target them again this long after a buyout |
| `Config.Immunity.GrandfatherDays` | `3` | only without qbx_core's players table: days of grace |
| `Config.Mugshot.Enabled` | `true` | target headshots on the board |
| `Config.Mugshot.RemoveBackground` | `false` | cut out the background (heavy on the target's game) |

## Features: Core

The app itself, proposals, notices, messages and calls, and the alerts staff get.

| Setting | Shipped | What it does |
|---|---|---|
| `Config.App.DefaultInstalled` | `false` | true = on every eligible home screen; false = in the App Store |
| `Config.Amendments.Enabled` | `true` | placer and hitman may agree changes to a contract |
| `Config.Amendments.ProposalExpirySeconds` | `300` | a proposal lapses after this |
| `Config.Amendments.MaxOpenPerContract` | `1` | proposals open at once |
| `Config.Amendments.CancelCooldownSeconds` | `300` | wait after cancelling before another |
| `Config.Notifications.ParanoidAlert` | `true` | the target is told "You feel eyes on you" |
| `Config.Notifications.ParanoidAlertJitter` | `{ max = 600, min = 60 }` | seconds it waits, drawn at random |
| `Config.Notifications.ParanoidCooldownMinutes` | `30` | at most one such alert per target this long |
| `Config.Notifications.MaxPerRecipientPerMinute` | `6` | notices one player may get a minute |
| `Config.Notifications.MaxPerRecipientPerHour` | `40` | and an hour |
| `Config.Notifications.PushEnabled` | `true` | refresh an open app when its contract changes |
| `Config.Notifications.PushMinIntervalSeconds` | `1` | least time between two refreshes |
| `Config.Relay.Enabled` | `true` | anonymous messages between the parties |
| `Config.Relay.MaxLength` | `200` | characters a message (255 at most on mysql) |
| `Config.Relay.MaxMessagesPerThread` | `100` | newest messages a thread keeps |
| `Config.Relay.AllowMaskedCalls` | `true` | calls with the caller's alias shown |
| `Config.Relay.RequireMaskingForAnonymous` | `true` | no call for an anonymous party the phone cannot mask |
| `Config.AntiCollusion.BlockSameAccount` | `true` | one account may not be two parties to a contract |
| `Config.Alerts.ToDiscord` | `true` | post each alert to the alert webhook (server.cfg) |

## Features: Anonymity

What placing or accepting anonymously costs, and the rules that differ by the target's class: anonymity, names shown, and who may buy intel (an informant switch here says for whom; the feature's own Enabled turns it on).

| Setting | Shipped | What it does |
|---|---|---|
| `Config.Anonymity.CreatorFee` | `0` | fee to place anonymously; 0 = free |
| `Config.Anonymity.HitmanFee` | `0` | fee to accept anonymously; 0 = free |
| `Config.Anonymity.FeeAccount` | `'bank'` | 'cash' \| 'bank' |
| `Config.TargetClasses.default.AllowAnonymousPlacer` | `false` | a contract may be placed anonymously |
| `Config.TargetClasses.default.AllowAnonymousHitman` | `false` | a contract may be accepted anonymously |
| `Config.TargetClasses.default.ShowOperativeNames` | `true` | the target sees a named operative's name |
| `Config.TargetClasses.default.ShowPlacerOnBoard` | `false` | the board names a named placer; off: parties only |
| `Config.TargetClasses.default.Informant` | `true` | the target may buy the target's informant |
| `Config.TargetClasses.default.PlacerInformant` | `true` | the placer may buy the placer's informant |
| `Config.TargetClasses.default.LocationTip` | `true` | a hitman may buy an informant tip |
| `Config.TargetClasses.whitelisted.AllowAnonymousPlacer` | `false` | such a contract may be placed anonymously |
| `Config.TargetClasses.whitelisted.AllowAnonymousHitman` | `false` | such a contract may be accepted anonymously |
| `Config.TargetClasses.whitelisted.ShowOperativeNames` | `true` | such a target sees a named operative's name |
| `Config.TargetClasses.whitelisted.ShowPlacerOnBoard` | `false` | the same, on such a contract |
| `Config.TargetClasses.whitelisted.Informant` | `false` | such a target may buy the target's informant |
| `Config.TargetClasses.whitelisted.PlacerInformant` | `false` | the placer of such a contract may buy the placer's informant |
| `Config.TargetClasses.whitelisted.LocationTip` | `false` | a hitman on such a contract may buy an informant tip |

## Features: Intel

Everything a player can learn for money, in one place (docs/features.md, Intel): three paid look-ups, the target's (who is after me), the placer's (who took it) and the hitman's tip (the target's rough area), the rules over them, going dark, the informant in person and the rumours. Each ships off.

| Setting | Shipped | What it does |
|---|---|---|
| `Config.Intel.Enabled` | `true` | master switch over the three look-ups; on, each one's own switch decides |
| `Config.Intel.Informant.Enabled` | `false` | a target may pay to find out who is after them |
| `Config.Intel.Informant.Cost` | `25000` | price of one look-up, paid win or lose; 0 = free |
| `Config.Intel.Informant.Account` | `'bank'` | 'cash' \| 'bank' |
| `Config.Intel.Informant.RevealMode` | `'name'` | 'name' \| 'description' |
| `Config.Intel.Informant.RevealChancePercent` | `10` | chance one look-up finds out who it is, 0-100 |
| `Config.Intel.Informant.ProximityRadius` | `120.0` | metres that count as near (an idle hold's clock) |
| `Config.Intel.Informant.RerollLockMinutes` | `30` | the same pick again this soon repeats the answer, free |
| `Config.Intel.Informant.MaxPurchasesPerContract` | `2` | look-ups per target per contract, both kinds |
| `Config.Intel.PlacerInformant.Enabled` | `false` | the placer may pay to find out who took it |
| `Config.Intel.PlacerInformant.Cost` | `25000` | price of one look-up, paid win or lose; 0 = free |
| `Config.Intel.PlacerInformant.Account` | `'bank'` | 'cash' \| 'bank' |
| `Config.Intel.PlacerInformant.RevealChancePercent` | `20` | chance one look-up names the operative, 0-100 |
| `Config.Intel.PlacerInformant.AlertChancePercent` | `20` | chance a named operative is told, 0-100 |
| `Config.Intel.PlacerInformant.RevealMode` | `'name'` | 'name' \| 'description' |
| `Config.Intel.PlacerInformant.MaxPurchasesPerContract` | `2` | look-ups per placer per contract |
| `Config.Intel.PlacerInformant.CooldownMinutes` | `10` | wait between two look-ups |
| `Config.Intel.LocationTip.Enabled` | `false` | a hitman on a contract may buy the target's rough area |
| `Config.Intel.LocationTip.Cost` | `25000` | price; 0 = free |
| `Config.Intel.LocationTip.Account` | `'bank'` | 'cash' \| 'bank' |
| `Config.Intel.LocationTip.RadiusMeters` | `350` | metres; the area shown is twice this across |
| `Config.Intel.LocationTip.ShowMinutes` | `10` | minutes the area stays on the hitman's map |
| `Config.Intel.LocationTip.CooldownMinutes` | `10` | minutes between two tips on one contract, by anybody |
| `Config.Intel.LocationTip.MaxPurchasesPerContract` | `3` | tips per contract, all its hitmen together |
| `Config.Intel.LocationTip.NotifyTarget` | `true` | tell the target someone knows their rough area |
| `Config.Intel.WarningDelay.Enabled` | `false` | the target's tip notice waits a random while |
| `Config.Intel.WarningDelay.MinSeconds` | `60` | shortest wait (s) |
| `Config.Intel.WarningDelay.MaxSeconds` | `300` | longest wait (s) |
| `Config.Intel.TipLimits.Enabled` | `false` | the extra tip limits below apply |
| `Config.Intel.TipLimits.OnePerHitman` | `true` | each hitman buys one tip per contract |
| `Config.Intel.TipLimits.PriceDoubling` | `false` | each further tip on a contract costs twice the last |
| `Config.Intel.TipLimits.MaxCost` | `200000` | the most a doubled tip costs ($) |
| `Config.Intel.HoldFirst.Enabled` | `false` | a tip only once the contract was held a while |
| `Config.Intel.HoldFirst.MinHeldMinutes` | `10` | minutes the hitman must have held it |
| `Config.Intel.SecondTry.Enabled` | `false` | the target's later look-ups cost differently |
| `Config.Intel.SecondTry.SecondTryCostPercent` | `50` | % of Intel.Informant.Cost after the first |
| `Config.Intel.SafeZones.Enabled` | `false` | no tip while the target is inside one of Zones |
| `Config.Intel.SafeZones.Zones` | `{}` | 'x, y, radius, name', e.g. '300, -590, 80, Pillbox' |
| `Config.Intel.GoDark.Enabled` | `false` | a tipped-off target may pay to go dark |
| `Config.Intel.GoDark.Cost` | `50000` | price; 0 = free |
| `Config.Intel.GoDark.Account` | `'bank'` | 'cash' \| 'bank' |
| `Config.Intel.GoDark.Minutes` | `30` | tips bought on them this long find nothing |
| `Config.Intel.InPerson.Enabled` | `false` | informant purchases only beside the informant NPC |
| `Config.Intel.InPerson.Radius` | `5.0` | metres from the informant that count |
| `Config.Intel.InPerson.Locations` | `{ '374.2, -827.4, 29.3, 180.0', '-1394.0, -592.0, 30.3, 120.0', '1984.0, 3054.0, 47.2, 240.0' }` | where the informant stands, one at a time |
| `Config.Intel.InPerson.RotateHours` | `3` | the NPC moves to the next place this often |
| `Config.Intel.InPerson.Model` | `'a_m_y_hipster_01'` | the informant NPC's ped model |
| `Config.Intel.InPerson.Scenario` | `'WORLD_HUMAN_LEANING'` | what the NPC does while standing |
| `Config.Intel.InPerson.Blip` | `false` | show the informant on the map |
| `Config.Intel.Rumours.Enabled` | `false` | the board shows new contracts as rumours only |
| `Config.Intel.Rumours.AreaMode` | `'district'` | 'district' (target's area) \| 'zones' (from Zones) |
| `Config.Intel.Rumours.Zones` | `{ 'the city', 'the south side', 'the docks', … 5 in all }` | area names when AreaMode = 'zones' |
| `Config.Intel.Rumours.Districts` | `{ '200, -900, Legion Square', '-1300, -1400, Vespucci', '-1500, -450, Del Perro', … 12 in all }` | 'x, y, name': the nearest names the target's area |
| `Config.Intel.Rumours.BandPercent` | `25` | reward shown as a band this many % either side |
| `Config.Intel.Rumours.Radius` | `5.0` | metres from the broker (NPC or player) that count |
| `Config.Intel.Rumours.BriefValidMinutes` | `30` | a briefing unlocks a contract for this long |
| `Config.Intel.Rumours.Locations` | `{ '-1171.0, -1572.5, 4.66, 125.0', '1240.6, -3179.2, 7.1, 270.0', '-56.5, -1752.4, 29.4, 50.0' }` | where the broker NPC stands, one at a time |
| `Config.Intel.Rumours.RotateHours` | `4` | the NPC moves to the next place this often |
| `Config.Intel.Rumours.Model` | `'g_m_m_armboss_01'` | the broker NPC's ped model |
| `Config.Intel.Rumours.Scenario` | `'WORLD_HUMAN_SMOKING'` | what the NPC does while standing |
| `Config.Intel.Rumours.Blip` | `false` | show the broker on the map |
| `Config.Intel.Rumours.BrokerJobs` | `{}` | jobs whose players brief from the app: { broker = true } |

## Features: Record

A character's record (docs/features.md, A hitman's record): the trust a completion earns and how it is scaled, the tiered board, heat and the placer's record.

| Setting | Shipped | What it does |
|---|---|---|
| `Config.Record.Progression.Enabled` | `true` | feed completions into the criminal progression |
| `Config.Record.Progression.TrustPerElimination` | `10` | trust per kill |
| `Config.Record.Progression.TrustPerKidnapping` | `20` | trust per live handover |
| `Config.Record.Reputation.Enabled` | `false` | trust for a completion scaled by how it was done |
| `Config.Record.Reputation.BaseFactor` | `0.5` | a plain completion |
| `Config.Record.Reputation.ThreadBonus` | `0.2` | the hitman wrote to the placer in the thread |
| `Config.Record.Reputation.MeetingBonus` | `0.2` | a meeting point was set |
| `Config.Record.Reputation.HandoverBonus` | `0.3` | a live handover |
| `Config.Record.Reputation.WitnessFreeBonus` | `0.2` | nobody else within WitnessRadius |
| `Config.Record.Reputation.WitnessRadius` | `50.0` | metres around the hitman |
| `Config.Record.Reputation.MaxFactor` | `1.5` | the most it may reach |
| `Config.Record.Tiers.Enabled` | `false` | big rewards need a progression level |
| `Config.Record.Tiers.CompletionsPerLevel` | `5` | completed contracts per level above 1 |
| `Config.Record.Tiers.Tiers` | `{ 'Professional, 50000, 2', 'Elite, 150000, 4' }` | 'name, least reward, least level' |
| `Config.Record.Heat.Enabled` | `false` | hitmen gather heat the city can feel |
| `Config.Record.Heat.ProtectedCompletionHeat` | `3` | heat for a completion on a whitelisted-job target |
| `Config.Record.Heat.WitnessHeat` | `2` | heat for a witness report on their completion |
| `Config.Record.Heat.AdvisoryHeat` | `1` | heat for a police bulletin on their acceptance |
| `Config.Record.Heat.DecayHours` | `24` | hours each heat stays |
| `Config.Record.Heat.Threshold` | `5` | heat at which a hitman counts as known |
| `Config.Record.Heat.WarnTargetChancePercent` | `50` | chance their next target is warned, 0-100 |
| `Config.Record.Heat.BulletinEveryMinutes` | `60` | least minutes between police bulletins; 0 = none |
| `Config.Record.Heat.BulletinTitle` | `'Intelligence bulletin'` | the bulletin's title |
| `Config.Record.Heat.BulletinText` | `'A known contract killer is believed active in the city.'` | its words |
| `Config.Record.PlacerRecord.Enabled` | `false` | hitmen see the placer's record on a board card |
| `Config.Record.PlacerRecord.LookbackDays` | `30` | days of contracts the record counts |
| `Config.Record.PlacerRecord.ShowForAnonymous` | `false` | an anonymous placer's record too, in rough bands |

## Features: Advisory

The law enforcement advisory: officers are told when one of them, or another whitelisted-job member, is targeted.

| Setting | Shipped | What it does |
|---|---|---|
| `Config.Advisory.Enabled` | `true` | officers are told when one of them is targeted |
| `Config.Advisory.TriggerJobTypes` | `{ ems = true, fire = true, leo = true, police = true }` | job types that raise one |
| `Config.Advisory.TriggerJobNames` | `{ ambulance = true, bcso = true, doj = true, fib = true, … 14 in all }` | job names that raise one (every barred name) |
| `Config.Advisory.RecipientJobTypes` | `{ leo = true, police = true }` | job types told |
| `Config.Advisory.RecipientJobNames` | `{ bcso = true, fib = true, k9 = true, police = true, … 9 in all }` | job names told |
| `Config.Advisory.UseDispatch` | `true` | also raise an sc-dispatch entry |
| `Config.Advisory.DispatchPriority` | `1` | its priority |
| `Config.Advisory.AlwaysAlertTarget` | `true` | the targeted officer is always told |
| `Config.Advisory.OnCreate` | `true` | a bulletin when a contract is placed |
| `Config.Advisory.OnAccept` | `true` | and when each hitman accepts |
| `Config.Advisory.OnLocationTip` | `true` | and when a hitman buys an informant tip |
| `Config.Advisory.OnCancel` | `true` | and when one on an officer is called off |
| `Config.Advisory.WarnCreator` | `true` | warn the placer before escrow is taken |
| `Config.Advisory.WarnHitman` | `true` | warn the hitman before they accept |
| `Config.Advisory.FlagListing` | `true` | mark the card on the board |

## Staff and permissions

The staff tools: /hitmanadmin and the F8 commands. ACE names are never changed from the panel, so staff cannot grant themselves access.

| Setting | Shipped | What it does |
|---|---|---|
| `Config.Admin.Enabled` | `true` | the staff commands and the admin panel |
| `Config.Admin.Ace` | `'crimson.admin'` | ACE for staff, and for anything that writes |
| `Config.Admin.IdentityAce` | `'crimson.identity'` | ACE to see who is behind an anonymous party |
| `Config.Admin.DeveloperAce` | `'crimson.developer'` | ACE for the panel's Developer section |
| `Config.Admin.ModeratorAce` | `'crimson.moderator'` | ACE that reads, freezes, suspends, protects and voids |
| `Config.Admin.ExtraAces` | `{ 'command' }` | ACEs that may also read (never write) |
| `Config.Admin.Commands` | `{ contracts = 'ch-contracts', diagnose = 'ch-diag', panel = 'hitmanadmin', refresh = 'ch-refresh', … 10 in all }` | command names, without the slash |
| `Config.Admin.PanelPageSize` | `25` | rows per page in the panel's lists |
| `Config.Admin.PanelRefreshSeconds` | `10` | how often the overview refreshes |
| `Config.Admin.TimelineRows` | `200` | audit rows read for one timeline |
| `Config.Staff.ManualPaymentMax` | `100000` | most one manual staff payment may be ($); 0 = off |
| `Config.Staff.DailySummary` | `false` | post one count-only summary a day to the alert webhook |
| `Config.Staff.DailySummaryHour` | `6` | the hour it is posted, server time (0-23) |
| `Config.Staff.AlertPlacedPerHour` | `5` | alert past this many placed by one player an hour; 0 = off |
| `Config.Staff.AlertTargetPerDay` | `3` | alert past this many on one target a day; 0 = off |
| `Config.Staff.AlertRefusalsPer10Min` | `30` | alert past this many refusals to one player in 10 min; 0 = off |
| `Config.Staff.RewardChangeMax` | `100000` | most staff may raise or lower a reward by at once ($); 0 = off |
| `Config.Staff.ReassignStake` | `'waive'` | a hitman staff assign: 'waive' (no stake) \| 'charge' |

## Roleplay

Optional roleplay features, each its own block and each off as shipped (docs/features.md). All of them are changed from the admin panel. Places (the broker's and the informant's) are 'x, y, z, heading'.

| Setting | Shipped | What it does |
|---|---|---|
| `Config.Roleplay.WitnessHeat.Enabled` | `false` | a completion seen by bystanders alerts the police |
| `Config.Roleplay.WitnessHeat.WitnessRadius` | `60.0` | metres a bystander sees it from |
| `Config.Roleplay.WitnessHeat.MinWitnesses` | `1` | bystanders it takes to raise an alert |
| `Config.Roleplay.WitnessHeat.AlwaysAlert` | `false` | alert on every completion, seen or not |
| `Config.Roleplay.WitnessHeat.SendCoords` | `true` | give dispatch a position, fuzzed below |
| `Config.Roleplay.WitnessHeat.FuzzMeters` | `120.0` | metres that position may be off by |
| `Config.Roleplay.WitnessHeat.DispatchPriority` | `2` | sc-dispatch priority of the alert |
| `Config.Roleplay.WitnessHeat.Title` | `'Witness report'` | the alert's title |
| `Config.Roleplay.WitnessHeat.Phrases` | `{ 'a person in dark clothing fled {direction}', 'someone in a hood was seen running {direction}', 'a masked figure left the scene heading {direction}' }` | what a witness says; {direction} is where they went |
| `Config.Roleplay.WitnessHeat.Areas` | `{ 'Legion Square@195,-934', 'Mission Row@430,-980', 'Little Seoul@-700,-900', … 18 in all }` | 'Name@x,y': the nearest centre names the area |
| `Config.Roleplay.EmsRelisting.Enabled` | `false` | after a kill, no new contract on them until treated |
| `Config.Roleplay.EmsRelisting.TreatedMinutes` | `10` | minutes up (not dead, not downed) that count as treated |
| `Config.Roleplay.EmsRelisting.RequireEMS` | `false` | a medic's defibrillator revive is needed instead |
| `Config.Roleplay.EmsRelisting.MaxHoldMinutes` | `120` | the rule lets go this long after the kill, whatever |
| `Config.Roleplay.CityNews.Enabled` | `false` | post an anonymous news item after a completion |
| `Config.Roleplay.CityNews.AllTargets` | `false` | every target; off: whitelisted-job targets only |
| `Config.Roleplay.CityNews.NameTarget` | `false` | {name} is the target's name; off: 'a resident' |
| `Config.Roleplay.CityNews.App` | `'birdy'` | 'birdy' (lb-phone PostBirdy) \| 'event' |
| `Config.Roleplay.CityNews.Account` | `'LSNews'` | the Birdy account it posts from (must exist) |
| `Config.Roleplay.CityNews.Event` | `'crimson-hitman:cityNews'` | 'event': the server event fired |
| `Config.Roleplay.CityNews.Templates` | `{ 'Police are appealing for witnesses after an attack on a {job} near {zone} at {time}.', 'Breaking: a {job} was targeted near {zone} around {time}. Police are on scene.' }` | one is picked; {job}, {zone}, {time} and {name} |
| `Config.Roleplay.DirtyPayouts.Enabled` | `false` | pay cash and bank rewards as a dirty money item |
| `Config.Roleplay.DirtyPayouts.Item` | `'black_money'` | the ox_inventory item paid |
| `Config.Roleplay.DirtyPayouts.Mode` | `'count'` | 'count': Rate items a dollar \| 'worth': one item |
| `Config.Roleplay.DirtyPayouts.WorthKey` | `'worth'` | 'worth': the metadata key holding its value |
| `Config.Roleplay.DirtyPayouts.Rate` | `1` | 'count': items paid for each dollar (no loss) |
| `Config.Roleplay.ProofOfIntent.Enabled` | `false` | hold a payout until the hitman shows intent |
| `Config.Roleplay.ProofOfIntent.MinMessages` | `3` | messages to the placer in the thread that count |
| `Config.Roleplay.ProofOfIntent.HoldMaxMinutes` | `60` | released anyway after this long (min) |
| `Config.Roleplay.Protection.Enabled` | `false` | targets may hire a bodyguard from On me |
| `Config.Roleplay.Protection.Account` | `'bank'` | the reward is paid from: 'cash' \| 'bank' |
| `Config.Roleplay.Protection.MinReward` | `1000` | least reward ($) |
| `Config.Roleplay.Protection.MaxReward` | `100000` | most reward ($) |
| `Config.Roleplay.Protection.PayOnCompletionPercent` | `25` | the guard's share if the hit completes anyway |
| `Config.Roleplay.Protection.MaxJobsPerGuard` | `2` | protection jobs one guard holds at once |
| `Config.Roleplay.HitOnHitman.Enabled` | `false` | a target may place a contract on an operative revealed |
| `Config.Roleplay.BurnerPhone.Enabled` | `false` | placing and accepting need the item |
| `Config.Roleplay.BurnerPhone.Item` | `'burner_phone'` | the ox_inventory item |
| `Config.Roleplay.BurnerPhone.ConsumeOnPlace` | `false` | use one up when a contract is placed |
| `Config.Roleplay.BurnerPhone.ConsumeOnAccept` | `false` | use one up when a contract is accepted |
| `Config.Roleplay.BurnerPhone.RequireToOpen` | `true` | no item, no contract tabs at all |
| `Config.Roleplay.NpcPlaces.Enabled` | `false` | broker and informant placed from the panel (Locations) |
| `Config.Roleplay.ReasonQuality.Enabled` | `false` | hold free-text reasons to the rules below |
| `Config.Roleplay.ReasonQuality.MinLength` | `15` | least characters in a reason |
| `Config.Roleplay.ReasonQuality.MinWords` | `3` | least words in a reason |
| `Config.Roleplay.ReasonQuality.LowEffort` | `{ 'rdm', 'idk', 'cuz', … 6 in all }` | words to catch |
| `Config.Roleplay.ReasonQuality.LowEffortAction` | `'refuse'` | 'refuse' \| 'review' (placed, and queued for staff) |

## Improvements

Optional changes to existing features, each its own block and each off as shipped (docs/features.md). All are changed from the panel.

| Setting | Shipped | What it does |
|---|---|---|
| `Config.Improvements.ContractDecay.Enabled` | `false` | an untaken contract changes as it waits |
| `Config.Improvements.ContractDecay.Mode` | `'rise'` | 'rise': its reward goes up; 'shorten': it ends sooner |
| `Config.Improvements.ContractDecay.Percent` | `10` | how much each step changes it |
| `Config.Improvements.ContractDecay.Hours` | `1` | hours between steps |
| `Config.Improvements.ContractDecay.MaxIncreasePercent` | `50` | most a reward rises in all ('rise') |
| `Config.Improvements.ContractDecay.Account` | `'bank'` | where a rise is charged from: 'cash' or 'bank' |
| `Config.Improvements.ProofItems.Enabled` | `false` | a hitman may finish with an item taken from the target |
| `Config.Improvements.ProofItems.Item` | `'id_card'` | the ox_inventory item (qbx_idcard's id card as shipped) |
| `Config.Improvements.ProofItems.MetadataKey` | `'citizenid'` | the item's metadata field that must name the target |
| `Config.Improvements.ProofItems.HandoverRadius` | `3.0` | metres between the hitman and the placer at the handover |
| `Config.Improvements.SerialScrub.Enabled` | `false` | a weapon from an anonymous placer reaches the hitman with a new serial |
| `Config.Improvements.WeeklyStats.Enabled` | `false` | post the week's totals to Discord once a week (counts only) |
| `Config.Improvements.WeeklyStats.Day` | `'sunday'` | the day it is posted, server time |
| `Config.Improvements.WeeklyStats.Hour` | `18` | the hour it is posted, server time (0-23) |
| `Config.Limits.TargetCooldownAfterCompletionSeconds` | `0` | wait after a completed contract on them; 0 = off |

## Organisation

The hitman organisation: a real qbx_core job with roles, a boss menu and Boss permissions (docs/features.md). Off as shipped: while it is off no job is registered, nothing is read or written, nothing changes.

| Setting | Shipped | What it does |
|---|---|---|
| `Config.Organisation.Enabled` | `false` | the organisation and its qbx_core job |
| `Config.Organisation.RequireJobToAccept` | `false` | only members may accept contracts |
| `Config.Organisation.AcceptNeedsPower` | `false` | and only roles given Take contracts |
| `Config.Organisation.OnDutyOnly` | `false` | members accept only while on duty |
| `Config.Organisation.JobName` | `'hitman'` | the qbx_core job (lower case) |
| `Config.Organisation.JobLabel` | `'Crimson Contractors'` | the job's label in qbx_core |
| `Config.Organisation.JobType` | `'hitman'` | the qbx_core job type |
| `Config.Organisation.DefaultDuty` | `true` | on duty when the job is set |
| `Config.Organisation.SetPrimaryOnHire` | `true` | an accepted invite or application makes it their primary job |
| `Config.Organisation.QbxBossFlag` | `false` | mark boss roles isboss in qbx_core too |
| `Config.Organisation.ExternalChanges` | `'adopt'` | 'adopt' \| 'revert' job changes made elsewhere |
| `Config.Organisation.OfficeRadius` | `5.0` | metres from the boss office that count |
| `Config.Organisation.DrawMetres` | `40.0` | metres at which a spot is drawn |
| `Config.Organisation.ApplyAtSignupOnly` | `true` | applications only at a sign-up spot |
| `Config.Organisation.NpcModel` | `'g_m_m_armboss_01'` | the ped drawn at an NPC spot |
| `Config.Organisation.Codenames` | `false` | members carry a codename, shown instead of their name |
| `Config.Organisation.CodenameMinLength` | `3` | least characters in a codename |
| `Config.Organisation.CodenameMaxLength` | `20` | most characters in a codename |
| `Config.Organisation.CodenameBlocked` | `{ 'admin', 'staff', 'moderator', … 4 in all }` | words a codename may not contain |
| `Config.Organisation.Payroll` | `false` | a salary per role, paid from the funds every pay day |
| `Config.Organisation.PayrollDays` | `7` | days between two pay days |
| `Config.Organisation.PaySuspended` | `false` | suspended members are paid their salary too |
| `Config.Organisation.OrgContracts` | `false` | placers may send a contract to the organisation |
| `Config.Organisation.AssignMinutes` | `30` | minutes to assign it, then to take it, before the open board |
| `Config.Organisation.AcceptApproval` | `false` | members' bigger accepts wait for a boss's approval |
| `Config.Organisation.ApprovalAbove` | `25000` | accepts worth more than this wait ($; 0 = every one) |
| `Config.Organisation.ApprovalProbation` | `true` | every accept of a member on probation waits too |
| `Config.Organisation.ApprovalMinutes` | `15` | minutes an accept waits before it is refused |
| `Config.Organisation.Probation` | `false` | new members take only small contracts at first |
| `Config.Organisation.ProbationMaxGrade` | `0` | members at or below this grade are on probation |
| `Config.Organisation.ProbationCompletions` | `3` | completions that end it (0 = only a sign-off) |
| `Config.Organisation.ProbationMaxReward` | `10000` | most a contract on probation pays ($) |
| `Config.Organisation.ProbationNoStake` | `true` | no staked contracts on probation |
| `Config.Organisation.Duty` | `false` | members clock in; only those on duty get organisation contracts |
| `Config.Organisation.DutyAtOffice` | `false` | clock in only at the boss office |
| `Config.Organisation.Channel` | `false` | a private message channel in the Organisation tab |
| `Config.Organisation.ChannelRetentionDays` | `7` | days a message is kept |
| `Config.Organisation.ChannelMaxLength` | `300` | characters in one message |
| `Config.Organisation.ChannelPerMinute` | `6` | messages one member sends a minute |
| `Config.Organisation.Dossiers` | `false` | briefings on assigned organisation contracts |
| `Config.Organisation.DossierMaxLength` | `600` | characters in a dossier's notes |
| `Config.Organisation.Armory` | `false` | an ox_inventory stash of the organisation's, through the app |
| `Config.Organisation.ArmoryItems` | `{}` | the items allowed in it (item names); empty = none |
| `Config.Organisation.ArmoryAtOffice` | `true` | items go in and out only at the boss office |
| `Config.Organisation.ArmorySlots` | `50` | slots in the stash |
| `Config.Organisation.ArmoryWeight` | `100000` | most weight the stash holds (grams) |
| `Config.Organisation.Stats` | `false` | each member's record in the organisation, and a leaderboard |
| `Config.Organisation.StatsLeaderboard` | `true` | every member sees the leaderboard (off: bosses only) |
| `Config.Organisation.StatsMinForRate` | `3` | outcomes before a reliability is shown |
| `Config.Organisation.StatsBandShort` | `30` | time bands players see: the first edge (minutes) |
| `Config.Organisation.StatsBandMid` | `120` | the second edge (minutes) |
| `Config.Organisation.StatsBandLong` | `480` | the last edge (minutes); over it is the last band |
| `Config.Organisation.Discipline` | `false` | strikes and written warnings |
| `Config.Organisation.StrikeDecayDays` | `30` | days a strike counts |
| `Config.Organisation.StrikeSuspendAt` | `3` | strikes that bar a member from contracts (0 = never) |
| `Config.Organisation.StrikeSuspendHours` | `48` | hours that bar lasts |
| `Config.Organisation.StrikeDemoteAt` | `0` | strikes that move a member one role down (0 = never) |
| `Config.Organisation.Recruitment` | `false` | an application form with a boss's questions, and interview notes |
| `Config.Organisation.RecruitQuestions` | `5` | questions on the form at most |
| `Config.Organisation.RecruitAnswerMax` | `300` | characters in one answer |
| `Config.Organisation.RecruitNoteMax` | `500` | characters in an interview note |
| `Config.Organisation.RecruitCooldownHours` | `24` | hours a declined applicant waits to apply again |
| `Config.Organisation.RecruitPerHour` | `10` | applications the organisation takes an hour |
| `Config.Organisation.SeveralOrganisations` | `false` | staff may add more organisations, each its own job |
| `Config.Organisation.MaxOrganisations` | `3` | organisations at most, the first included (1-10) |
| `Config.Organisation.Reputation` | `false` | reputation, in tiers that unlock bigger contracts |
| `Config.Organisation.RepCompletion` | `10` | points a member's completion earns |
| `Config.Organisation.RepFailure` | `15` | points a member's failure costs |
| `Config.Organisation.RepHeat` | `2` | points off for each point of heat members carry now |
| `Config.Organisation.RepTiers` | `{ '0, Unknown, 25000', '100, Known, 75000', '300, Trusted, 200000', … 4 in all }` | 'points, label, most an accept is worth ($; 0 = no cap)' |
| `Config.Organisation.DeadDrops` | `false` | payouts may wait at a staff-set dead drop |
| `Config.Organisation.DeadDropMinutes` | `60` | minutes a member has to collect it |
| `Config.Organisation.DeadDropUnclaimed` | `'pay'` | 'pay' (handed over as always) \| 'refund' (to the placer) |
| `Config.Organisation.Territory` | `false` | staff zones give first refusal (needs OrgContracts) |
| `Config.Organisation.TerritoryMinutes` | `5` | minutes the contract is held for it first |
| `Config.Organisation.TerritorySightMetres` | `75.0` | a member must stand this near the target (metres) |
| `Config.Organisation.Garage` | `false` | staff-approved vehicles at the garage spot |
| `Config.Organisation.GarageVehicles` | `{}` | the models staff approve; empty = none |
| `Config.Organisation.GarageMaxOut` | `3` | vehicles out at once for the organisation |
| `Config.Organisation.GarageKeepMinutes` | `60` | minutes before a vehicle out is taken away |
| `Config.Organisation.GarageReturnMetres` | `15.0` | how near the garage spot a vehicle is returned |
| `Config.Organisation.InternalContracts` | `false` | a boss may ask staff for a contract on a rogue member |
| `Config.Organisation.InternalExpireHours` | `24` | hours a request waits for staff |
| `Config.Organisation.Handler` | `false` | the organisation's NPC spots brief members |
| `Config.Organisation.HandlerAssigns` | `true` | and hand out the oldest contract waiting |
| `Config.Organisation.ActivityLog` | `false` | an organisation-only log of members' actions |
| `Config.Organisation.ActivityKeep` | `200` | entries kept |
| `Config.Organisation.Roles` | `{ '0, recruit, Recruit, 0, no', '1, operative, Operative, 0, no', '2, lieutenant, Lieutenant, 0, no', … 4 in all }` | the roles made with it: 'grade, name, label, pay, boss' |
| `Config.Organisation.Limits.MaxMembers` | `20` | members at most |
| `Config.Organisation.Limits.HireRadius` | `5.0` | metres a hire stands from the boss |
| `Config.Organisation.Limits.HireMaxGrade` | `0` | highest grade a boss hires into |
| `Config.Organisation.Limits.FireCooldownMinutes` | `10` | minutes between two fires by one boss |
| `Config.Organisation.Limits.PromotionsPerDay` | `5` | role changes one boss makes a day |
| `Config.Organisation.Limits.SuspendMaxHours` | `72` | longest a boss bars a member from contracts |
| `Config.Organisation.Limits.MemberMaxAtOnce` | `3` | most contracts a boss lets a member hold |
| `Config.Organisation.Limits.MemberCooldownMaxMinutes` | `120` | longest cooldown between accepts a boss sets |
| `Config.Organisation.Limits.MaxRoles` | `8` | roles at most |
| `Config.Organisation.Limits.PayMax` | `500` | most pay per role per pay-cycle ($) |
| `Config.Organisation.Limits.BonusMax` | `10000` | largest bonus ($) |
| `Config.Organisation.Limits.BonusPerDay` | `25000` | bonuses one boss pays a day ($) |
| `Config.Organisation.Limits.WithdrawMax` | `50000` | largest withdrawal ($) |
| `Config.Organisation.Limits.WithdrawPerDay` | `100000` | withdrawals one boss makes a day ($) |
| `Config.Organisation.Limits.CutMaxPercent` | `25` | most a boss sets the payout cut to (%) |
| `Config.Organisation.Limits.TotalCutCapPercent` | `40` | most of one payout all cuts take (%) |
| `Config.Organisation.Limits.StakeCutMaxPercent` | `25` | most a boss sets the stake cut to (%) |
| `Config.Organisation.Limits.BuyoutCutMaxPercent` | `25` | most a boss sets the buyout cut to (%) |
| `Config.Organisation.Limits.OfficeMoveMetres` | `150.0` | how far a boss moves the office from staff's point |
| `Config.Organisation.Limits.LocationCooldownMinutes` | `60` | minutes between two moves of a spot by a boss |
| `Config.Organisation.Limits.MaxSignupSpots` | `2` | sign-up spots at most |
| `Config.Organisation.Limits.MaxMeetingSpots` | `5` | organisation meeting spots at most |
| `Config.Organisation.Limits.NoticeMaxLength` | `500` | characters in the board notice |
| `Config.Organisation.Limits.RenameCooldownMinutes` | `1440` | minutes between two label changes by a boss |
| `Config.Organisation.Limits.InviteMinutes` | `10` | minutes a boss's invite waits for the player to accept |
| `Config.Organisation.Limits.SalaryMax` | `1000` | most salary a boss sets per role per pay day ($) |
| `Config.Organisation.Limits.PayrollPerDayMax` | `0` | most paid in salaries in all on one pay day ($); 0 = no cap |
| `Config.Organisation.Limits.CodenameCooldownMinutes` | `1440` | minutes between two own codename changes |
| `Config.Organisation.Limits.ChannelMuteMaxHours` | `24` | longest a boss mutes a member in the channel (hours) |
| `Config.Organisation.Limits.ArmoryWithdrawMax` | `10` | most a boss lets each member of a role take out a day (items) |
| `Config.Organisation.Limits.ArmoryManagePerDay` | `20` | most a boss holding Manage armory takes out beyond that a day |
| `Config.Organisation.Limits.StrikesPerDay` | `5` | strikes and warnings one boss gives a day |

## Mission steps

Map markers for each step of a contract, to the one party who acts on it (docs/features.md), and body disposal: a verified kill paid once the body is dropped off. Disposal ships off; its spots are set by staff in the admin panel (Locations) or below.

| Setting | Shipped | What it does |
|---|---|---|
| `Config.StepMarkers.Enabled` | `true` | markers for each step, to the party who acts on it |
| `Config.StepMarkers.KillScene` | `true` | the hitman: the body, until the kill is verified |
| `Config.StepMarkers.Handover` | `true` | placer and hitman: the handover circle while it counts |
| `Config.StepMarkers.Protection` | `true` | the guard: their client's meeting pin while on the job |
| `Config.Disposal.Enabled` | `false` | a verified kill pays once the body is dropped off |
| `Config.Disposal.VehicleModel` | `'romero'` | the disposal vehicle (the hearse) |
| `Config.Disposal.VehicleSpawn` | `{}` | { x, y, z, h } where it is made; the panel's spot wins |
| `Config.Disposal.DropOff` | `{}` | { x, y, z } the drop-off; the panel's spot wins |
| `Config.Disposal.PayNowPercent` | `0` | of a cash or bank payout handed over at the kill |
| `Config.Disposal.TimeLimitMinutes` | `30` | minutes of the hitman's time in the city to finish |
| `Config.Disposal.OnTimeout` | `'pay'` | 'pay' \| 'reduced' \| 'refund' (to the placer) |
| `Config.Disposal.ReducedPercent` | `50` | 'reduced': what the hitman keeps of the money (%) |
| `Config.Disposal.LoadMetres` | `3.0` | how near the body the hitman stands to load it |
| `Config.Disposal.DropMetres` | `8.0` | how near the drop-off the hitman stands |
| `Config.Disposal.VehicleMetres` | `10.0` | how near the body or drop-off the vehicle is |
| `Config.Disposal.AbandonMetres` | `300.0` | a vehicle left this far away ... |
| `Config.Disposal.AbandonMinutes` | `5` | ... this long is taken back to the spawn spot |
| `Config.Disposal.MaxRespawns` | `3` | times the vehicle is made again when lost |
| `Config.Disposal.MaxHoldMinutes` | `120` | real minutes from the kill a step may stand, away or not |
| `Config.Disposal.DespawnSeconds` | `10` | seconds after the drop-off it is taken away |

## Advanced and developer

Logging, diagnostics, rate limits, json tuning and the timings of the kill and handover checks. The shipped values suit most servers.

`Config.Cooldowns`: one row for each entry.

| Setting | Shipped | What it does |
|---|---|---|
| `Config.Audit.LogAllActions` | `true` | audit every action, not only money and staff |
| `Config.Audit.LogReasonText` | `true` | keep the reason text in the audit log |
| `Config.Audit.FlushIntervalMs` | `10000` | how often queued rows are written |
| `Config.Audit.MaxQueueSize` | `5000` | rows queued at most |
| `Config.Audit.RetentionDays` | `30` | days the audit log is kept; 0 = forever |
| `Config.Audit.ContractRetentionDays` | `30` | days a finished contract is kept; 0 = forever |
| `Config.Audit.ContractsPrunedPerTick` | `200` | finished contracts removed per tick |
| `Config.Diagnostics.SlowJobMs` | `25` | a maintenance job slower than this prints a Debug line; 0 = never |
| `Config.VersionCheck.Enabled` | `false` | ask Url once at start; the console says if a newer version is out |
| `Config.VersionCheck.Url` | `''` | where the version is read (text or JSON); '' = nothing is asked |
| `Config.RateLimit.Key` | `'license'` | 'license' (per account) \| 'citizenid' (per character) |
| `Config.Cooldowns.diagnostic` | `{ burst = 10, per = 60 }` | the page's own fault reports |
| `Config.Cooldowns.create` | `{ burst = 2, per = 60 }` | placing a contract |
| `Config.Cooldowns.accept` | `{ burst = 3, per = 30 }` | accepting one |
| `Config.Cooldowns.bailout` | `{ burst = 1, per = 60 }` | buying one out |
| `Config.Cooldowns.informant` | `{ burst = 1, per = 300 }` | the target's informant |
| `Config.Cooldowns.placerInformant` | `{ burst = 1, per = 300 }` | the placer's informant |
| `Config.Cooldowns.locationTip` | `{ burst = 2, per = 60 }` | buying an informant tip on a target |
| `Config.Cooldowns.message` | `{ burst = 5, per = 5 }` | messages, calls, mutes, Notify me |
| `Config.Cooldowns.amend` | `{ burst = 3, per = 30 }` | proposing a change |
| `Config.Cooldowns.load` | `{ burst = 20, per = 10 }` | the app reading its own state |
| `Config.Cooldowns.search` | `{ burst = 15, per = 10 }` | searching names |
| `Config.Cooldowns.wallet` | `{ burst = 8, per = 10 }` | reading what the placer carries |
| `Config.Cooldowns.photo` | `{ burst = 3, per = 15 }` | asking to photograph a kill |
| `Config.Cooldowns.photoSubmit` | `{ burst = 5, per = 15 }` | sending the photo |
| `Config.Cooldowns.photoView` | `{ burst = 5, per = 10 }` | opening a kill photo |
| `Config.Cooldowns.photoDecide` | `{ burst = 5, per = 5 }` | keeping or deleting it |
| `Config.Cooldowns.death` | `{ burst = 4, per = 5 }` | death and revive reports |
| `Config.Cooldowns.mugshot` | `{ burst = 3, per = 60 }` | sending a headshot |
| `Config.Cooldowns.progress` | `{ burst = 5, per = 1 }` | the handover countdown, polled each second |
| `Config.Cooldowns.image` | `{ burst = 20, per = 2 }` | fetching a headshot |
| `Config.Cooldowns.admin` | `{ burst = 30, per = 10 }` | the admin panel, per staff member |
| `Config.Cooldowns.adminWrite` | `{ burst = 6, per = 10 }` | what the admin panel writes |
| `Config.Cooldowns.report` | `{ burst = 3, per = 600 }` | reporting a contract or a thread to staff |
| `Config.Cooldowns.org` | `{ burst = 20, per = 10 }` | the organisation's reads (members, boss menu) |
| `Config.Cooldowns.orgWrite` | `{ burst = 5, per = 10 }` | what a boss changes in the organisation |
| `Config.Cooldowns.disposal` | `{ burst = 6, per = 10 }` | loading and dropping off a body |
| `Config.Database.Json.WarnContractCount` | `2000` | json: warn above this many contracts |
| `Config.Database.Json.MaxDirtyShardsPerFlush` | `25` | json: contract files one ordinary flush writes |
| `Config.Limits.MaxDeadlineSkipSeconds` | `600` | longest the expiry pass sleeps |
| `Config.Kidnap.MaxTotalGraceMs` | `3000` | ms a handover may break, in all, before it fails |
| `Config.Kidnap.TickMs` | `1000` | how often a handover is checked |
| `Config.Kidnap.MaxConcurrentCountdowns` | `20` | handovers counting at once, server-wide |
| `Config.Bailout.MaxSettleAttempts` | `10` | ticks a queued buyout waits on a stuck claim |
| `Config.Completion.PhotoMaxSide` | `1280` | 'server': longest side of a photo, in pixels |
| `Config.Completion.PhotoMaxBytes` | `600000` | 'server': largest photo, in bytes |
| `Config.Completion.PhotoHostRefreshSeconds` | `300` | 'host': re-read lb-phone's hosts this often |
| `Config.Completion.ExtraPhotoHosts` | `{ 'fivemanage.com', 'fmfile.com' }` | 'host': image hosts allowed besides lb-phone's own |
| `Config.Completion.RejectLastStand` | `true` | a downed player is never a kill |
| `Config.Completion.RequireObservedDamage` | `true` | a kill needs a hit the server saw |
| `Config.Completion.DeathReportWindowMs` | `30000` | a hit counts this long before a death |
| `Config.Completion.ConditionSampleMs` | `1000` | how often targets' health is sampled |
| `Config.Completion.MaxWeaponRange` | `425.0` | metres a hit is believed from |
| `Config.Completion.MedicJobs` | `{ ambulance = true }` | as sc-ambulance's RequireEMS |
| `Config.Completion.DefibItem` | `'defibrillator'` | as sc-ambulance's Defib.Item |
| `Config.Completion.DefibRange` | `3.0` | as sc-ambulance's Defib.Distance |
| `Config.Mugshot.MinRefreshMinutes` | `5` | least time between two headshots of one target |
| `Config.Mugshot.RenderTimeoutMs` | `8000` | ms a headshot may take |
| `Config.Mugshot.MaxImageBytes` | `98304` | largest headshot accepted |
| `Config.Mugshot.AllowedMime` | `{ image/jpeg = true, image/png = true, image/webp = true }` | headshot image types accepted |
