# Crimson Hitman System — developer guide

What a developer needs to change this resource safely: how it is built, how
it stores, how it is tested, how a release is made, and the rules it keeps.
The owner's README is [crimson-hitman/README.md](../crimson-hitman/README.md),
with the owner docs beside this file (how it works, features, the admin
panel, configuration, running the server); what only a running server can
prove is [in-game-checklist.md](in-game-checklist.md). The developer notes
are under `docs/dev/`: [the adapters](dev/adapters.md), [the loops](dev/loops.md),
[every panel request](dev/panel-requests.md), [the workflow
report](dev/workflows.md) and [the map](dev/map.md) of the resource at `b31d10a`.

This file replaces the original specification, the implementation plan, the
build report and the oxmysql notes. Code comments cite the specification's
rules by number (`§14.8`): [the rules, by number](#the-specifications-rules-by-number)
lists every one, and comments citing oxmysql's behaviour (`oxmysql §6`) are
answered under [oxmysql](#oxmysql-as-the-mysql-store-relies-on-it).

## Architecture

### The stack

Qbox (`qbx_core`) and `oxmysql`, with every other script behind an adapter
(`server/adapters/`, `client/adapters/`, `Config.Integrations`; see
`docs/dev/adapters.md`): `ox_inventory`, `ox_target`, lb-phone,
`sc-ambulance` / `qbx_medical`, `sc-dispatch`, `Renewed-Banking`,
`qbx_vehiclekeys`, `sc-blackmarket` and `MugShotBase64`, detected at runtime
and skipped when absent, one console line for each kind left without one.
`fxmanifest.lua` lists only `qbx_core` as a dependency: lb-phone may start
after this resource, and the client adds the app whenever lb-phone starts.

### Modules

`server/boot.lua` waits for the dependencies and loads the modules through
one loader (`CrimsonBoot.require`); `server/main.lua` wires them (each
module's `init(deps)`), runs boot recovery, and owns the maintenance tick.
Every module (each `server/**` file but `boot.lua` and `main.lua`, and each
`shared/**` file but `constants.lua`) is listed in `fxmanifest.lua`'s
`server_scripts`, between `boot.lua` and `main.lua`. Its first line,
`CrimsonBoot.define('server.escrow', function() `, opens its body under its
path, and its last line, `end)`, closes it: the manifest running the file
only stores the body, and `CrimsonBoot.require` runs it once, when it is
first asked for. Nothing reads a module with `LoadResourceFile`, which hands
an escrowed file back still encrypted. On the client, `client/boot.lua`'s
`CrimsonBoot.define` runs a shared file's body at once. The language files
are plain scripts that publish their table (every one on the server,
`locales/client/` in the game). The tests load modules the same way (`tests/harness/modules.lua`),
and `tests/escrow_boot_spec.lua` starts the whole resource with every
`.lua` sealed to `LoadResourceFile`.
Every server file's public functions take an actor already resolved by
`identity.lua`; nothing but `identity.lua` and the handlers in `app.lua` /
`panel.lua` reads `source`.

| Area | Files |
|---|---|
| Boot, wiring, the tick | `server/boot.lua`, `server/main.lua`, `server/timing.lua` |
| Network surface | `server/app.lua` (the phone), `server/panel.lua` (the admin panel), `server/admin.lua` (the commands), `server/bridges.lua` (framework and game events) |
| Identity and access | `server/identity.lua`, `server/ratelimit.lua`, `server/playtime.lua` |
| Contracts and money | `server/contracts.lua` (lifecycle, state machine, locks, limits), `server/escrow.lua` (the single source of truth for what a contract holds), `server/amendments.lua`, `server/bailout.lua`, `server/review.lua`, `server/payments.lua` |
| Finishing | `server/completion/death.lua` (attribution, the condition sampler), `photo.lua` (capture tokens, hosts), `kidnap.lua` (the handover countdown), `server/meeting.lua`, `server/photos.lua` |
| What players see | `server/projection.lua` (every payload, per recipient), `server/notify.lua`, `server/comms.lua` (the masked relay), `server/ledger.lua`, `server/mugshot.lua`, `server/record/init.lua` (`Record.of`) |
| Intel | `server/intel/engine.lua` (the one purchase engine: `Intel.on` / `anyOn` (master switch, product switch, target class), `Intel.PRODUCTS` (party, lock, refund action and fallback per product), `Intel.define` (a product's terms, steps, ready, uncharged, confirm, deliver), `Intel.check` (steps from one set: `party`, `holds`, `open`, `live`, `class`, then the product's own), `Intel.buy` (lock, terms, check, quote, ready, charge, confirm, refund, deliver), `Intel.refund` (owe or review, the product's audit action), `Intel.tell` (every notice), `Intel.gate` (in person beside the informant NPC), `Intel.validate`); `server/intel/informants.lua` (target's and placer's), `server/intel/tip.lua` (the tip), `server/intel/rules.lua` (the tip rules and going dark), `server/intel/rumours.lua` (rumours and the broker's briefings); all under `Config.Intel` |
| Holds | `server/holds.lua`: every reason a contract stands still, as one service. Kinds `staff` (a staff freeze on a party, or the freezes unreadable), `restart` (the txAdmin restart hold), `app` (the app pause, `Config.Holds.AppPaused`), and the expiry pass's presence pause (logoff, a target in prison), registered with `Holds.presence`. Ask `Holds.on(contract, hitmen, kinds)` (held, by `'staff'` / `'restart'` / `'app'` or a list; nil is every kind), `Holds.since` (since when), `Holds.why(contract, hitmen, 'party' \| 'public')` (what a player's card is told: the band's start, and On hold for a party only), `Holds.shown(contract, hitmen, canIdentify)` (which parties a staff member may be shown), `Holds.global(kind)`, `Holds.of(cid)`, `Holds.releasing()`, `Holds.clockMayRun(contract)`. One give-back (`giveBack` / `giveBackLive`: the lifetime and the paid windows, never past another hold still on it) and one release path (the releasing guard). Every clock asks it: deadline, lifetime, idle release, proposals, tips and go dark, decay, disposal, handover confirm, kills pending |
| Police & press | `server/police.lua`: everything this resource tells the police or the city, one path each. `Police.jobs()` (the departments a dispatch entry is for: `Config.Advisory.RecipientJobNames` switched on, `police` when none), `Police.recipients(skip)` / `Police.tell(title, text, skip)` (every officer online by `Identity.isAdvisoryRecipient`, past their budget), `Police.dispatch(entry)` (the one sc-dispatch `AddNotification`; unique id held to 60, caller 60, street 100) and `Police.clear(uid)` (`ClearNotification`), `Police.press(cfg, text)` (the city news post: lb-phone `PostBirdy` or the owner's event, a failure said once a minute). Its callers say what and when: the advisories (`Notify.advisory` / `tipAdvisory` / `cancelAdvisory`, cleared by `Notify.clearContract`), the heat bulletin (`record/heat.lua`), the witness report and city news (`rp_consequences.lua`). Wired by `Notify.init` |
| Discord | `server/discord.lua`: every Discord post (alerts, the audit mirror, the daily summary, the weekly stats). `Discord.url(channel)` (`alerts`: `crimson_hitman_alert_webhook` else `crimson_hitman_webhook`; `staff`: `crimson_hitman_webhook`; `stats`: `crimson_hitman_stats_webhook` else the alerts' two; read on every post), `Discord.text` (@ defused, links left out, cut), `Discord.post(channel, content, { tries, every, still, done })` (a 429 holds that webhook for every sender; a refusal tried again after a doubling wait, never sooner than Retry-After) |
| Target classes | `Config.TargetClasses` (`default`, `whitelisted`: a target on a whitelisted job, the contract's `target_protected`), read only through `Util.targetClass(protected)` and `Util.targetRule(name, protected)` (AllowAnonymousPlacer, AllowAnonymousHitman, ShowOperativeNames, ShowPlacerOnBoard, Informant, PlacerInformant, LocationTip); `Intel.on(section, protected)` (server/intel/engine.lua) is the master switch, the feature's `Enabled` and its class's switch |
| Staff | `server/settings.lua` (the panel's settings over config.lua), `server/presets.lua` (named bundles of settings, previewed, applied through it), `server/sanctions.lua`, `server/staffcontract.lua`, `server/history.lua`, `server/announce.lua`, `server/summary.lua`, `server/thresholds.lua`, `server/alerts.lua`, `server/reports.lua`, `server/audit.lua` |
| Roleplay | `server/rp_places.lua` (the NPC places and their parsers), `rp_consequences.lua` (witness heat, EMS, city news, dirty payouts), `rp_intent.lua`, `rp_protection.lua` (bodyguards, the hit on the hitman), `rp_burner.lua`, `rp_reason.lua` (the rumours and the informant in person are Intel's) |
| Record | `server/record/`: `init.lua` (the one read and store of a character's standing: `Record.of`, the counters, standing, level, trust and the reputation factor, the tiered board's lock and gate, `Record.RULES` / `Record.validate` for `Config.Record`, the `record.tick` minute job), `heat.lua` (hitman heat), `placer.lua` (the placer's record on a card) |
| Improvements | `imp_board.lua` with `imp_decay.lua` (contract decay); `imp_proof.lua`, `imp_scrub.lua`, `imp_weekly.lua` (the completion cooldown is `server/targetlimits.lua`) |
| Organisation | `server/org/init.lua` (state, members, roles, cuts, the accept gate, places, notices), `powers.lua` (the power codes and bounds), `engine.lua` (who holds what, the delegation rules), `jobs.lua` (qbx_core), `funds.lua` (Renewed-Banking or the ledger), `schema.lua` (its tables, all three stores), `staff_ops.lua` (panel ops), `boss_ops.lua` (app requests), `settings_catalogue.lua`; `client/org.lua` |
| Payout checks | `server/payout.lua`: the one ordered list of what may hold a payout once a claim went through (`Payout.ORDER`: `disposal`, then `intent`), over the escrow's one hold. `Payout.holds` is `Escrow.holdBack` (asked before every give), `Payout.releasesAt` is `Escrow.holdUntil` (staff settling a held line), `Payout.onClaim` / `afterClaim` are `Contracts.payoutOnClaim` / `payoutAfterClaim` (the claim, under its lock, and when it ended). A feature adds its check with `Payout.add(name, check, deps)`; every call is protected. Whether a claim pays at all is the one check `Contracts.payoutRefusal` (still on it, no staff or restart hold, no slot cooldown, a slot left), asked before the claim's lock and again under it |
| Mission steps | `server/missionsteps.lua` (one marker system: who must act on each step, diffed and sent to that game alone, `crimson-hitman:client:StepMarker` / `StepMarkerClear`), `server/disposal.lua` (body disposal: the `disposal` payout check, asked ahead of proof of intent, and `Contracts.relistHold`; steps and spots in `crimson_rp_rows`, kinds `disposal` and `disp_spot`); `client/missionsteps.lua` (`CrimsonMarkers`: every blip this resource draws, the tip, the meeting point, the steps, the broker and informant NPCs and the organisation's spots); `server/lib/markers.lua` (`Markers.show` / `clear`: the one sender, used by missionsteps.lua, meeting.lua and intel/tip.lua); Set GPS is one NUI callback, `crimson:gps` (`kind` tip, meeting or protection) |
| Storage | `server/storage/memory.lua` (the reference implementation of the interface), `json.lua`, `mysql.lua` |
| Shared | `shared/constants.lua` (states, enums, `CH.ERR`), `shared/util.lua` (pure helpers, `Util.copy`), `shared/log.lua` (the one way to the console), `shared/geo.lua` (`Geo.position` / `finite` / `dist2` / `near`, both sides as `CrimsonGeo`), `shared/text.lua` (`Text.reason` / `field`), `shared/words.lua` (`Words.dollars` / `hours` / `duration` / `inAbout` / `metres`) |
| Helper library | `server/lib/lock.lua` (`Lock.new`: one at a time per key; `Contracts.serialized` is one), `server/lib/window.lua` (`Window.new`: counts in a sliding window, check and count in one step), `server/lib/bridge.lua` (`Bridge.call` / `started` / `raised` / `phoneRefuses`: every call into another resource, never a raise), `server/lib/db.lua` (`Db.try` / `quiet`: a store call and its own failure line), `server/lib/lifecycle.lua` (`Lifecycle.run`: the cleanup lists server/bridges.lua runs when a player leaves, a contract ends or a hitman steps off), `server/lib/feature.lua` (`Feature.on` / `block` / `active` / `check`: every optional feature's block of config, read live and held to its rules at the start), `server/lib/markers.lua` (`Markers.show` / `clear`: every map marker sent to a player's game); in modules: `Identity.sourceOf`, `Notify.parties`, `Police.jobs` / `tell` / `dispatch` / `clear` / `press` (`server/police.lua`: everything told to the police or the city), `Discord.post` / `url` / `text` (`server/discord.lua`: every Discord post), `Panel.staffActor`. Use these rather than a local copy; `tests/static_check.lua` refuses the old local names |
| Client | `client/main.lua` (lb-phone registration, the NUI bridge, the death and mask watchers), `client/admin.lua` (the panel's page), `client/mugshot.lua`, `client/npc.lua` (`CrimsonNpc`: scenery peds, the logged-in and ox_target-started checks; their blips are `CrimsonMarkers`', used by `client/rp_npc.lua`, `client/org.lua` and `client/missionsteps.lua`), `client/rp_npc.lua` |
| Pages | `ui/kit.css` (the one design system both pages link first: tokens, buttons with the two-click armed state, fields, cards, chips, notices, tables, dialogs); `ui/index.html`, `ui/app.js`, `ui/app.css` (the phone app); `ui/admin.html`, `ui/admin.js`, `ui/admin.css` (the panel) |

An optional feature is a module with an `init(deps)`, a block of
`Config.Improvements` or `Config.Roleplay` read through `server/lib/feature.lua`
(`Feature.on(path)`, `Feature.block(path)`, `Feature.active(path)`, never by
hand) and held to its rules at start by `Feature.check(path, RULES, warn,
filled)` from the module's `checkConfig` / `validate` (which the panel also
runs against a copy with a change in it; `tests/lib_feature_spec.lua` holds
every rule to the settings catalogue's entry for the same key), hooks it registers on the modules it extends
(`Projection.extenders`, `Contracts.afterClaim`, `Escrow.holdBack` and the
like) and, if it has periodic work, one job on the tick that does nothing
while it is off.

### Confirm handover, Change reward and Reassign

- `server/completion/kidnap.lua`: with `Config.Kidnap.PlacerConfirms` (captured per countdown at arm), a countdown that has run its course enters a confirm window (`confirmLeftMs`, ticked by the shared tick, standing still on the restart hold and the app pause) instead of being claimed; `Kidnap.answer` (the app request `confirmHandover`, `server/handover_confirm.lua`) confirms, which the next tick claims, or declines (`Kidnap.notConfirmed`: re-arm cooldown, outcome `not_confirmed`). `Kidnap.placerConfirm` feeds the placer's card (`handoverConfirm`), `Kidnap.progress` the hitman's (`awaitingConfirm`, `confirmLeft`).
- `server/escrow.lua`: `Escrow.STAFF` (`'staff'`) is who a staff-funded line was taken from (`taken_from`) and whom it goes back to. `Escrow.addStaffLine` writes one (no player charged, one take per contract at a time); `release` hands any such line it would give the contract's placer to `Escrow.STAFF` instead, and `Escrow.deliver` settles a give to `Escrow.STAFF` with nothing moved. `Escrow.reduceLine` lowers a reward line as `reduceStake` lowers a stake (owed split first, guarded cut, boot recovery by the line's amount), owing the cut to the line's funder; a split owed to staff is settled at once, at boot too (`recoverOwed`).
- `server/staff_reward.lua` and `server/staff_reassign.lua` add their panel ops with `Panel.extend` and run under `Contracts.serialized({ 'contract:' .. id })`; reassignment accepts through `Contracts.acceptHeld` (Contracts.accept's rules and after-steps, keyed on the hitman only, since the caller holds the contract's key) with `opts.waiveStake`, after `App.acceptGate` (the roleplay rules and tiers in front of Accept).
- `tests/invariants.lua` holds every staff-funded line away from the placer, everything settled or owed to staff to a staff-funded line, every split to exactly what it cut, and nothing owed to staff left held at rest.

### The hitman organisation

`server/org/` (Config.Organisation, off as shipped). Its own tables are the
source of truth, read once at start into one state and written through on
every change; qbx_core is told after (`jobs.lua`: `CreateJobs` at start and for
a new job, `UpsertJobData` / `UpsertJobGrade` / `RemoveJobGrade` on a role or
label change, `AddPlayerToJob` / `RemovePlayerFromJob` / `SetPlayerPrimaryJob`
for members by citizen id; never `commitToFile`). The calls this resource makes
are marked (`Jobs.applying`) so the qbx_core events they fire are not read as
outside changes; an outside change arrives through `qbx_core:server:onGroupUpdate`
and `QBCore:Server:OnJobUpdate` (both heard in `bridges.lua`) and is adopted or
reverted. Every change goes through one function in `init.lua` with the
actor `{ staff = true }` or a boss `{ cid, source }`; `Org.authorize` is the
whole permission check (member, `Engine.holds` after the ceiling, the office
from `GetEntityCoords(GetPlayerPed(src))`), then the rank rules
(`Engine.mayActOn`, `mayAssignGrade`, `mayEditRole`, `mayDelegate`,
`wouldLeaveNoBoss`). A grant records who made it (`by`), and `Engine.holds`
asks whether that granter still holds the power and still outranks the holder,
so revoking cascades without touching a row.

Money: `funds.lua` picks the first backend once (`Funds.pick`, kept as staff
meta `org_funds_backend`: 1 the ledger, 2 Renewed-Banking), every
organisation's until staff move it: each organisation then keeps its own, in
a marker row of its ledger (`backend:<id>`, kind `backend`, amount 0;
`Funds.backend(org)`). Only the staff op `orgFundsBackend` (`Funds.switch`)
changes one organisation's, making the job's Renewed-Banking account first
(`CreateJobAccount`), carrying its balance across in two `switch` rows; the
money moves with nothing awaited and is kept on this machine (review item
`org_funds_interrupted`, how `switch`) until the rows and the marker are
written, so a crash in between is finished at the next start. Removing an
organisation checks its money under both backends (`Funds.emptyEverywhere`).
Money paid out to a member (bonus, withdrawal, salary) is decided by what
arrived (`handOver`: `Util.credit`), marked `:paid` (kept before it is awaited),
given back `:back` only when nothing arrived, left for staff
(`org_funds_give_raised`, its `:review` marker kept before it is awaited, as
`:paid` is) when part of it, or no telling, did; a crash inside the
give is left for staff (`org_funds_give_unconfirmed`), and a debit row with neither
never reached the member, so the retry pays it (mysql). Nothing pays a give
again while staff hold it: an open review item naming its reference, or its
`:review` marker waiting to be written (`staffHold`). A member's deposit the
funds refuse, whose give-back fails too, is owed to them (`Bailout.owe`); its
write-ahead item becomes a staff item (`org_funds_deposit_refund_failed`,
`Review.recast`) before the owe is minted or awaited, and goes only once the
owe's line is written, so a store that raises there leaves it for staff. A cut taken on a give
that never arrived is given back (`cut:<line>:back`) when the line goes to
anyone else. Every movement is one `crimson_org_funds` row under a
reference written once (`insertOrgRowOnce`), marked with its `backend`; the
ledger's balance is the sum of its own (`internal`) rows only. Credit: row
first, then the account, the row taken back if the account refuses. Debit: the
day's cap (`spec.cap`, counting debits reserved and not written yet), the
balance and the reservation in one step before any await, then the account
and the row, the reservation given back if the row is not written. With the
bank chosen and Renewed-Banking not started every movement answers
`bank_down` (`org_bank_down`). The cut is two hooks on the payout path:
`Escrow.orgCut(recipient, line)` in `Escrow.deliver` credits the funds once per
line (reference `cut:<line id>`) and the member is given the line less it, as
cash, bank or a dirty item, and `Escrow.orgTaken(line)` in `Escrow.stillOwed`
keeps a later give (a retry, a staff pay) from paying that part again;
`Funds.taken` reads the cut row from the store when the ledger was not loaded
(the organisation off since the start). The split is frozen per contract and
member (`crimson_org_splits`) by `Contracts.afterAccept` at the figure
`Contracts.acceptGate` checked (handed over in the gate's `out` table); both
run inside the acceptance's own hold on `contract:` and `hitman:` keys, so one
member's acceptances are gated one at a time, and a gate that raises refuses
(`server_error`). A page acceptance must echo the cut the board showed
(`shown.orgCut`). `tests/invariants.lua` holds every cut to its line and the
internal ledger above zero. Off, both hooks read one switch and `Funds.taken`,
and no request reads anything.

Organisation extras 1 (`server/org/extras.lua`, each its own switch under
`Config.Organisation`, off as shipped): its functions are copied onto `Org`
(`Extras.attach`) and work on the same state, settings row and record. Contracts
sent to the organisation (`OrgContracts`) are kept in `settings.orgContracts`
by contract id (`waiting`, `assigned`, `taken`), never with the placer; the
board's filter is `Projection.reserved` (`[contract id] = the one viewer shown it
| false`), rebuilt on every change and nil while none is held, so `listedFor`
pays one nil check. The accept gate asks, in order: `Extras.reservedRefusal`
(first, members or not; staff acceptances pass), the existing member rules,
`Extras.probationGate`, the cut, then `Extras.approvalGate` last, so an accept
is held for approval only once every other rule of the organisation passed.
A held accept keeps only what the page showed (`checkDisclosure`, `disclosed`,
`shownBand`, `shown`) and whether it was anonymous (the gate's `out.anonymous`,
set by `Contracts.accept`); approval sets `Approved[contract:cid]` around one
`Contracts.accept`, which checks everything again. Probation counts
`readStats(cid).completed` less the count kept when it began
(`settings.probation`). Duty is in memory (`OnDuty`), told to qbx_core with the
framework adapter's optional `SetJobDuty` where the job is the primary one, and
`QBCore:Server:SetDuty` (heard in `bridges.lua`) is taken in. The channel is
`crimson_org_messages` (schema `messages`), read once when first used, the last
200 kept in memory; its posts are a `Window` per member. Dossiers sit on the
`orgContracts` entry. One tick job, `org.extras` (its own 30 s gate), expires and
prunes; with every switch off it compares one value.

Organisation extras 2 (`server/org/extras2.lua`, each its own switch under
`Config.Organisation`, off as shipped), copied onto `Org` the same way
(`Extras2.attach`, with `saveMember` and `setGrade` in its kit). The armory is
an ox_inventory stash (`crimson_armory_<org id>`) registered through the
inventory adapter's `RegisterStash` before every read and move (so an
inventory restart is taken in), under the group `crimson_armory_locked`, which
nobody holds, so only the server moves items. A move reads the slot from the
server's own inventory read (`GetInventoryItems`), never the client's word,
asks `CanCarryItem` of the side receiving, removes from one side, adds to the
other, and gives back on a refusal; one move at a time (`Busy`). The limits a
day are `Window`s of one entry per unit (`Taken`, `Managed`), in memory; the
role limits and the last 100 moves are in `settings.armory`. The record is
`settings.stats[cid]` (`c`, `f`, `e`, `t`, `n`, `since`), fed by
`Record.observer(kind, cid, info)` (server/record/init.lua, asked in a pcall
from `onCompleted` and `onFailed`; the claim passes `{ contractId, earned,
seconds }`), which compares one switch while Stats is off. Bands are from
`StatsBandShort/Mid/Long`. Discipline is `settings.discipline[cid]` (the last
50 entries, `strike` or `warning`), counted at read time against
`StrikeDecayDays`; a suspension the strikes made is in
`settings.strikeSuspended` so an overturn lifts only that one. Recruitment's
questions, cooldowns and notes are in `settings.recruit`; the answers are kept
in the application's own `body`, as `\2` followed by JSON (a control
character no plain text can hold), read back by `Extras2.readBody`; the hourly
cap is a `Window` by organisation. `Org.apply`, `Org.applications` and
`Org.decide` ask `Extras2` only while Recruitment is on. There is no tick.

Several organisations (`Config.Organisation.SeveralOrganisations`, off as
shipped): `server/org/init.lua` keeps every organisation loaded in `Orgs` (by
id, the job name) and `Order` (the first, from config.lua, first; the others'
ids in its `settings.others`). Every function reads "the" organisation through
`Cur()`, the one set for the running coroutine by `Org.within(org, fn, ...)`
(a weak table keyed by `coroutine.running()`, so a request that waits on the
store or a bank never hands its organisation to another), and the first where
none is set, which is everything when only one is loaded. The ways in set it:
`BossOps` (the member's own, `Org.contextFor`: else `payload.org`, the inviting
one, the one holding their application, the one at whose sign-up spot they
stand), `StaffOps.scoped` and `Places.scope` (`data.org`, refused when it names
none), the hooks wrapped at the end of the file (`termsFor`, `shownName`,
`playerLoaded`, `inviteFor`, `answerInvite`, `onGroupUpdate`, `useSpot`,
`sendRefusal`/`receiveContract` by the id the placer sent, `Extras2.observe`,
`Extras.frameworkDuty`), and the loops (`reconcile`, `spotsFor`, `tabFor`,
`payrollTick`, `extrasTick` run on each in turn). `Org.cutFor` takes the
organisation from the split's `org_id`, so a cut lands in the funds of the
organisation the member was in when they took the contract. `acceptGate` asks
`Extras.reservedRefusal` of every other organisation first, so a contract held
for one is held from everybody else; `afterAccept` marks it taken in whichever
holds it. `Org.orgOf(cid)` is the one membership index (a citizen is in one at
most: `enrol`, `Org.hire`, `Org.apply`, `Org.answerInvite` and `Org.external`
refuse a second). The channel's cache is by organisation. The tables were
keyed by `org_id` from the start; nothing in the store changed.

Organisation extras 3 (`server/org/extras3.lua`, each its own switch, off as
shipped), copied onto `Org` the same way (`Extras3.attach`). Reputation is
`settings.rep` (`points`, `c`, `f`), fed by the record's observer (the
wrapped `Extras2.observe` calls `Extras3.observe` after the stats, on the
member's own organisation), its standing read at use (`Extras3.standing`, the
heat from `server/record/heat.lua`'s `Heat.of`), and asked by the accept gate
(`Extras3.tierGate`, after probation and before approval). Dead drops are a
payout check, `'deaddrop'`, last in `Payout.ORDER`: `onClaim` writes the drop
to `settings.drops[contract:cid]` (and the in-memory index `Drops`, rebuilt by
`Extras3.loaded` at every boot), `holds` keeps the member's baseline and bonus
lines owed and queued (one `next()` while none waits), the drop's ox_target use
(`Org.useSpot`) or the tick ends it, and `escrow.retryPending` hands it over;
`'refund'` gives every held line back with `escrow.release`, as body disposal
does. Territory is the `territory` place kind (hidden: `Org.spotsFor` never
sends it), read by `Org.territoryClaim` (asked by `server/app.lua` after a
placement not sent anywhere): the target's server position, a zone, and a
member of that organisation within `TerritorySightMetres` in the same routing
bucket; the hold is an `orgContracts` entry marked `territory`, so
`release` tells the placer nothing. The garage keeps its vehicles in memory
(`Vehicles[cid]`) and makes them through the `garage` adapter kind
(`server/adapters/garage/onesync.lua`); the tick and `onResourceStop` take them
away. Internal contract requests are `settings.internal[id]`; approval calls
`Contracts.create` with the requesting boss as the actor. The handler is the
`npc` place kind's use with `Handler` on. The activity log is
`settings.activity`, appended by `Org.record` (an allow-list of actions and of
detail fields), `Org.afterAccept` and the observer. The extras tick
(`org.extras`) runs `Extras3.tick` on each organisation.

Joining: a boss's `Org.hire` is an invite held in memory (`Invites`, expiring
after `Limits.InviteMinutes`), shown to the player as the board's `orgInvite`
and in `orgMine`, answered by `orgInviteAnswer` (`Org.answerInvite`, the hire
checked again); a staff hire is made at once without `SetPlayerPrimaryJob`.
Any enrolment closes the citizen's open applications (`superseded`).
`Org.reconcile` treats a grade qbx_core holds differently from the table as an
outside change (`Org.external`), except a removal it cannot be believed about:
the job kept by name only, `qbx:cleanPlayerGroups` on, or a character that
loaded before the job was registered this process (`Org.loadedSinceRegister`).

### Translations

Every word players and staff read is a key: server and client Lua call
`L('area.key')` (`local L = CrimsonBoot.requireShared('locale').t` on the
server, `CrimsonLocale.t` on the client), which reads
`locales/<Config.Locale>.lua` and falls back to `locales/en.lua` (the game's
own `client.*` keys: `locales/client/<Config.Locale>.lua`, the only language
file the manifest sends every player; client files ask no other key and the
server none of these, which tests/locale_spec.lua holds); the pages
call `Text.t('section.key')` or read a whole `Text.section(name)` from
`locales/<lang>.json`, loaded synchronously as the page starts (the phone is
told the language by `?lang=` on its address, the panel by its open message).
A page reads every word through its one helper, `t('section.key')` (`var t
= Text.t`; the phone's keys are `app.*`), with values after the key filling
its `%s` in order (`t('app.page_of', p, pages)`; `%2$s` names one by place),
and `tn('section.key', count)` for words that depend on a count
(`key_one`, `key_other`, and any further form Intl.PluralRules names for the
language). English is never joined onto a value with `+` in a page
(tests/locale_spec.lua, PageScan.joined). Its own HTML is read by attribute:
`data-t` (the text), `data-t-title`, `data-t-placeholder`,
`data-t-aria-label`, applied as the page starts (the panel's keys are
`admin.*`). `Text.later(fn)` runs `fn`
now and again once a language is applied, for what a page builds from its
words while it loads: the panel learns its language from its first open
message, after it loaded, so every table it builds from t() at load (GROUPS,
VIEW_LABEL, HELP, GROUP_INTRO, ...) is `var X; Text.later(function () { X =
... })`. Wrap only tables and t() statements, never one that adds a
listener. Ids stay English where the page matches them (a section's
`head`, a setting's `group`). A local variable is never called `t`.
Texts keep their `%s`/`%d` and are formatted by the caller, so the wording is
the same. Keys are `<file area>.<first words>`: `admin.*` server/admin.lua,
`bridges.*` server/bridges.lua, `settings.*` and `settings_group.*`
server/settings.lua, `org_settings.*` server/org/settings_catalogue.lua,
`org.*` server/org/init.lua, `org_extras2.*` server/org/extras2.lua, and so on
for every server file (its path under server/ with `_` for `/`).

Where words used to be matched, they are not any more:
- The panel's Dashboard reads the diagnosis by marks: `Admin.diagnose`
  returns `lines, marks`, and `say(line, 'act')` marks a line that wants doing,
  `say(line, 'console')` one only the console needs (panel.lua
  `diagWarnings`; a `->` and a word in capitals still count, as before).
- The panel's ACE answers are built from `Admin.grantFor(ace)` (which ACE,
  then the grant), never by cutting `Admin.howToAuthorise`'s sentence.
- A setting's `group` stays its English id (AREA_OF_GROUP, MONEY, the page's
  checks); `Settings.view` sends `groupLabel` (and `moneyLabel`) from
  `GROUP_LABEL`, keys looked up each time (`Settings.groupLabel`).
- An informant answer that found nobody by name is marked `unknown`; one
  stored before still reads by its English text (`UNKNOWN_BEFORE`).

Strings that stay in code are names, never shown: config sections and keys
(`Feature.on('Mugshot')`), key prefixes, preset names (their ids), stored
data (the old placer alias), patterns of other software's errors, a date
format. `tests/locale_spec.lua` checks that every key used exists in English
and scans every server file and the game's (`tests/harness/textscan.lua`) for
a sentence written back into code; `NAMES` and `ALLOW` list what it reads as
words and is not, each with why. The pages are scanned the same way
(`tests/harness/pagescan.lua`, a small JavaScript lexer: an object key, a
comparison, an index, CSS classes and icons, key prefixes and console lines
are not words; `PAGE_ALLOW` lists the rest, with why), and every key a page
or its HTML asks for must be in `locales/en.json` (tests/ui/run.js and
tests/ui/admin_run.js boot each page in a made-up language and read its
words). A test that reads a page's source for its words reads it through
`tests/harness/pagewords.lua`, which puts each t('key') back as its
English. Console lines (`Log.*`, `print`, `error`,
`Db.try`, `Lifecycle.run`) are never scanned: they stay English, and so do
the files that only print to the console (`CONSOLE_FILES`: the stores,
server/boot.lua, server/versioncheck.lua).

To add a language: [running.md](running.md#adding-a-language).

### Version check

`server/versioncheck.lua` runs once at the end of a sound start (main.lua,
after `Log.started()`, inside pcall). `VersionCheck.allowed` refuses any
address that is not `https://`, carries `?`, `#`, a space or a user name, or
is over 512 characters; the request is `PerformHttpRequest(url, cb, 'GET',
'', {})`. The answer is read for its first `n.n[.n]` and compared with the
manifest's `version` by number (a part over nine digits reads as no
version; the callback runs in a `pcall`). `tests/versioncheck_spec.lua`.

### Config check

`server/configcheck.lua` builds the findings for `/ch-diag config`
(`Admin.diagnose` with `config`) and the panel's `diag` op with
`config = true`: `Settings.configWarnings()` (the start-up checks run
quietly on a copy of the config in force; never `Log.view().problems`,
which carry other scripts' error text and stay the Developer console's,
scrubbed there), `Integrations.offLine` for each needed kind with no
adapter, `IsPrincipalAceAllowed('group.admin', …)` for each staff ACE and
`command.<name>`, and `ConfigCheck.RISKS` (a `when(Config)` and a fix
each). Add a risk there with its own test in `tests/configcheck_spec.lua`.

### Settings export and import

`server/settingsio.lua`: `export()` is `Settings.active()` (applied, not
read-only, not a secret) plus `Presets.ownList()` as one JSON text
(`format = 'crimson-hitman-settings'`, `version = 1`). `preview(text)` reads
it (at most 200 KB) and sorts every key into changes, `refused` (secret,
`Settings.DENY`, no catalogue entry, read-only, `Settings.check` refused)
and `same`, and each preset through `Presets.importable`. `apply(text,
expect)` previews again, refuses when the changes no longer number `expect`,
then calls `Settings.set` for each and `Presets.importOwn` for each preset.
The page sends the text as a latent event (client/admin.lua `LATENT_OPS`).
`tests/settingsio_spec.lua`.

### The event and handler order

Every net event and callback handler, in `app.lua` and `panel.lua`, runs in
this order: `local src = source` first and `src > 0`; permission (job from the
config lists, rank, duty, ACE for staff); the per-source token bucket
(`Config.Cooldowns`); type checks and clamps on every field; plausibility
(fresh server-side position, the entity exists); then the change, on the
server only. Permission and type failures are logged through the audit log;
plausibility and timing failures are dropped silently. Writes run under the
contract's lock (`Contracts.serialized`), re-read what they act on after
every await, take money last and refund on failure.

### The maintenance tick

One thread, every `Config.Audit.FlushIntervalMs` (10 s). Each job runs inside
`pcall` through `job(name, fn)` and is timed for `/ch-diag`; scheduled jobs
(`SCHEDULE` in `main.lua`) come round every `every` seconds on a phase of
their own so no two heavy jobs share a tick; self-gated jobs sleep until their
next due time. Jobs that read what is running share one read per change
(`Projection.liveSnapshot`). Per-pass batches are capped (25 releases, 25
endings, 25 decay steps, 25 bodyguard settles). [docs/dev/loops.md](dev/loops.md)
lists every loop and its cost; `tests/loops_spec.lua` pins them.

### Storage

Three backends behind one interface (`server/main.lua` picks one by `Config.Database.Mode`);
`memory.lua` is the reference, and the storage conformance suite runs every
backend against the same tests. Same rows in all three:

- `mysql`: tables made at start after `MySQL.ready` (utf8mb4, InnoDB), created or altered only where `information_schema` says something is missing; the same statements in `install/sql/crimson_hitman.sql`. Every statement races `Config.Database.QueryTimeoutSeconds`. Upserts use `ON DUPLICATE KEY UPDATE c = VALUES(c)`; SQL takes `?` parameters only and never holds `:` or `@`.
- `json`: `data/store.json` is the index (sequence, contract files, audit days); `data/records.json` the records (ledger, pending payouts, stats, reveals, photo records, the review queue, panel settings), written only when one changes; `data/contracts/<id>.json` one contract each with its escrow, hitmen, amendments and messages; `data/heartbeat.json` when the server was last seen running, which a restart dates its downtime from; `audit-<day>.jsonl` the log. Written on change and at the flush, money writes synced at once (`SyncOnFinancialWrite`). `store.json.prev` and `records.json.prev` are the last start's copies: a missing or unreadable index or records file stops the start rather than lose what it held, and a file cut off by a crash is restored from its last whole copy. The folders ship with a README each because `SaveResourceFile` cannot create a folder.
- `memory`: testing only; releases every open escrow at a stop.

Database changes only add (new tables, `ADD COLUMN` inside `pcall`); nothing
drops or renames a column that holds player data.

Kept across a restart besides the rows above: an exclusive (or full
competitive) hold's idle and attempt clocks, one `crimson_rp_rows` row a held
contract (kind `idle_clock`, written by `Contracts.releaseIdleHolds`, read
back by `Contracts.reindexHolds`). Only time the clock could run is counted
(the first pass after a start adds nothing for the downtime); a row is
written when its counts have grown and a minute has passed since this
process last wrote it, at once when a count goes back to nothing, at most
`Contracts.IDLE_CLOCK_WRITES_PER_PASS` (100) a pass, all of a pass's rows
in one write (`Storage.writeRpRows`: one statement on `mysql`), and dropped
with the hold. On `json` they are kept in `clocks.json`, a file of their own
saved at the tick's flush, not synced at once and never in `records.json`:
they hold no money.

## Testing

No FiveM server runs in CI, so the real modules run against a stubbed
runtime. Run everything from the repository root:

```bash
sh tests/all.sh                                  # every suite below
lua5.4 tests/run.lua                             # the server suite
CH_SUITES=journeys_spec,loops_spec lua5.4 tests/run.lua   # a few specs, in seconds
lua5.4 tests/invariants.lua                      # the server suite under the store monitor
lua5.4 tests/static_check.lua                    # source rules
node tests/ui/run.js                             # the phone page
node tests/ui/admin_run.js                       # the admin panel page
node tests/layout/run.js                         # the phone page in a real browser (Playwright)
node tests/layout/admin_run.js                   # the panel at 1280, 1920 and 1024 wide
```

And the linter, from `crimson-hitman/`:
`qbx-lint client server shared config fxmanifest.lua --format compact --min-severity warning`.

| Suite | What it proves | How |
|---|---|---|
| Server (`tests/run.lua`, `tests/*_spec.lua`) | Escrow arithmetic, the state machine, every payout and refund path, whole journeys, every action against every state, exploits, every panel request against every permission, feature switches, settings across restarts, conservation of value under random sequences | `tests/harness/natives.lua` stubs FiveM, `qbx_core`, `ox_inventory` and lb-phone; `newStack()` wires the real modules on a fresh store; `fixture(s)` adds a placer, a target and a hitman |
| Storage conformance (`storage_spec`) | Every backend behaves the same | `mysql` runs on `tests/harness/mysql_exec.lua`, which executes the statement shapes this resource sends, refuses what MariaDB's strict mode refuses and answers as oxmysql does; `await_scheduler.lua` yields every await as oxmysql does |
| Races (`races_spec`, `interleave_spec`) | Two requests landing before and after every database wait of each other | The await scheduler |
| Store invariants (`tests/invariants.lua`) | Nothing in the store is ever inconsistent, whatever ran | The whole suite again, with a monitor after every write |
| Loops and requests (`loops_spec`, `handlers_spec`, `perf_round3_spec`) | Each job's schedule, early exits, statement counts and a worst-pass budget on a 200-contract city | `CH_PERF=1` prints the measured figures |
| Documents (`docs_spec`) | `docs/configuration.md` equals config.lua; every refusal has words; every panel op is in `docs/dev/panel-requests.md`; every switch has a checklist line; the README's sections, and no build history in the owner docs; every link, anchor, `docs/` path and `file:line` in every document exists | `CH_PRINT_DOCS=1 CH_SUITES=docs_spec lua5.4 tests/run.lua` prints the reference to paste |
| Static (`tests/static_check.lua`) | No SQL built by concatenation; no handler reading an identity from a payload; every module, event and config key consistent; the schema holds every field; one word for one thing (the glossary); cited documents exist | Reads the source |
| Phone page (`tests/ui/run.js`) | The real `ui/app.js` against a scripted server: forms, refusals, taps, two-click confirms, escaping | `tests/ui/dom.js`, a minimal DOM |
| Panel page (`tests/ui/admin_run.js`) | Every section and action of `ui/admin.js`, access levels, stale answers, player text staying text | The same DOM, reading `admin.html` (`tests/ui/markup.js`); a test that asserts a time the page works out from the clock boots it with `{ clock: { ms } }`, so the page's `Date` stands still unless the test moves it |
| Layout (`tests/layout/*.js`) | Tap targets, clipping, the tab bar and status bar on the phone; the panel without its icon font | Playwright; skipped where it is not installed |
| Release (`release_spec`) | The release build holds every file the manifest names and nothing it should not; the zip is named for the version; shipped links land; a missing file or a webhook stops it | Runs `tools/release.lua` into a temporary folder, and on a broken copy of the resource |

**Adding a spec.** Write `tests/<area>_spec.lua` with `describe` / `it` and the
globals the runner gives (`eq`, `truthy`, `falsy`, `newStack`, `fixture`,
`withConfig`, `resetConfig`, `Env` for time and players, `Natives` for calls
made); add its name to the `suites` list in `tests/run.lua`. Every stack starts
from the shipped config, so a test changes config through `withConfig` or the
roleplay and improvements guards (`tests/harness/roleplay.lua`,
`improvements.lua`) and never leaves it changed. A spec that builds a big city
to measure cost goes in `MEASUREMENT_SPECS` so the invariant run skips it,
and a test that writes a state straight to the store (ending a contract
without releasing its escrow) marks that store
`rawset(store, '__rawFixture', true)` so the invariant run does not audit
its fixture. The invariant run holds the stores it watches weakly, so it
stays at a few tens of megabytes and well inside its 3 GB and 30-minute
limits.

**Changing a setting.** Add it to `config/config.lua` (with one short note)
and `config/defaults.lua` in the same place, to the panel's catalogue
(`server/settings.lua`) if staff may change it, read it where it is used, and
paste the reference `docs_spec` prints over `docs/configuration.md`'s. `config_layout_spec`,
`config_drift_spec` and `docs_spec` fail until all of them agree.

**What the suites cannot prove:** the real `ox_inventory`, lb-phone and
`qbx_core` builds, the page on a real phone, a real MySQL's isolation and
collation under concurrent writes, and performance under real load. That is
[in-game-checklist.md](in-game-checklist.md).

## Release build

`tools/release.lua` makes what a server owner (or the escrow upload) gets:

```bash
lua5.4 tools/release.lua                 # dist/crimson-hitman/ and dist/crimson-hitman-<version>.zip
lua5.4 tools/release.lua --out /tmp/rel  # somewhere else
```

Run it from the repository root; `dist/` is git-ignored. The file list comes
from `fxmanifest.lua` (every shared, client and server script, `files {}`,
`ui_page`, and what `escrow_ignore` leaves readable, globs expanded as FiveM
does), plus the manifest, the README, the CHANGELOG, a LICENSE if there is
one, `install/sql/`, the `data/` folders' notes and the owner docs (under
`docs/` in the release, their links pointed at where they land; a link to a
developer document becomes plain text). Tests, `docs/dev/`, this guide, the
tools and anything the server wrote under `data/` are left out. It stops,
naming the file, when the manifest names a file that is not there or a
directive it does not know, when CHANGELOG.md's newest version is not the
manifest's, when a scratch file would ship, and when a shipped file holds
what reads as a secret (a Discord webhook, a database password). The zip is
stored, not compressed, with one fixed date, so the same tree gives the same
bytes. A new owner document goes in `Release.OWNER_DOCS`.
`tests/release_spec.lua` builds it into a temporary folder and checks it.

## Design rules still true

**Security.** The server decides: money, items, positions and outcomes are
never taken from a client (§9.6, §14.1, §14.14). Every handler runs the order
above. Staff ACEs are checked on every panel request; anything that moves
money takes `crimson.admin` itself. Secrets are `set` convars, never in
`config.lua`. SQL uses `?` parameters only; player text is escaped in both
pages.

**Anonymity.** What a recipient may see is decided once, in
`server/projection.lua`, by omission at the boundary (§14.4): an anonymous
party's name, citizen id and licence never reach a player, and reach staff
only with `crimson.identity`, each unmasking audited. Error text kept for
staff is cut to the statement's start (oxmysql's message carries every
parameter). Notices never date or place an anonymous party (§14.32, §14.40).

**Money.** Escrow is the single source of truth (§9.1), released by one
routine (§9.2), source-faithful (§14.10), never destroying property: a
payout that cannot be given is owed, then left for staff, never dropped
(§9.3, §14.12). Every movement is in the audit log (§9.8). Completion takes
the contract's lock and happens once (§9.7, §14.34). Charges come last and are
refunded on failure; a write the database did not confirm is settled by the
server from its whole record (the review queue). A payout given as a
dirty money item at `Rate` items a dollar (`Config.Roleplay.DirtyPayouts`)
that raised part-way keeps the items of a dollar not yet whole on the line
(`deliver_part`) beside the whole dollars that arrived (`deliver_arrived`),
so the give staff finish hands over exactly the rest; any part arriving,
even less than a dollar's worth, leaves the line for staff at once.

**Load.** Nothing per frame while idle; loops sleep until due, share their
reads and cap their passes; optional features cost nothing while off.

### Deliberate trade-offs

These were reviewed and left as they are on purpose:

- **Freeze and pause end ordering.** Ending a staff freeze, the app pause or the restart hold clears the hold record before the lifetime give-back (`server/holds.lua`). Reversing it would turn a crash between the two steps from a lost give-back into a double one. Neither is safe, and a lost give-back is the smaller harm. While a release is still giving time back, the expiry pass leaves every contract alone (`Holds.releasing`), so only a crash, never an expiry pass in between, can lose it.
- **17mov mugshot refresh.** The headshot refreshes on the qb-clothing, illenium and rcore appearance events only. 17mov_CharacterSystem is escrowed and its saved-appearance event name cannot be verified, so it is not guessed. On a 17mov server the headshot refreshes on its normal timer instead.
- **Boot recovery re-reads per contract.** Crash recovery reads each contract and roster again under that contract's lock before it moves money. This is slower than one batched read, but it never acts on a row another step has just changed.
- **No by-age index for the json prune.** The prune walks every contract, but only every 10 minutes (more often only while a backlog drains), so an index would be fragile for little gain.
- **Dirty-money cash settle.** If staff turn dirty payouts off and then settle a part-delivered line in cash or bank, the part of a dollar already given as items cannot be expressed in dollars, so the hitman can end up less than $1 ahead. Item-to-item deliveries are exact (`deliver_part`).
- **Contract decay never raises an anonymous contract.** A `rise` step is charged to the placer and so waits until they are in the city; landing on the board a minute after an anonymous placer logs in, it timed their login. Reserving the whole rise in escrow at placing would need a new escrow portion that every release, refund and recovery path skips, so the smaller rule was taken: `rise` applies to named contracts only (`server/imp_decay.lua`); `shorten` charges nothing and applies to both. The decay count stands still while staff, the restart hold, the app pause or an operative hold the contract (`held_since` on its row).
- **Ledger kinds.** A contract cancelled any way but by its placer writes the kind `cancelled` (shown *Cancelled — refunded*); `refunded` is kept for one that ran out.
- **Ledger stakes.** The placer's row for an expiry or a cancel counts the operatives' stakes the ending hands them in its `amount` and says the stake part apart (`stakes`, a column of `crimson_ledger`), never whose. A proof-item handover is paid as an elimination but recorded as `CH.FULFILMENT.PROOF`, on the Ledger and to `Contracts.afterClaim` (`opts.outcome` on `Contracts.claimSlot`), so the roleplay consequences never take it for a kill.
- **Scrubbed serials are derived, not stored.** `server/imp_scrub.lua` works a line's new serial out from its escrow line id and a secret kept as the staff meta rows `imp_serial_secret_1` to `_5` (five 28-bit words, made at the first scrub through `Storage.claimStaffMeta`, insert-if-absent then read back, so two first uses landing together both use the stored words; the single `imp_serial_secret` of earlier versions is no longer read), so a give retried after a restart hands over the same serial without a row per weapon.
- **Freezes that cannot be read at the start.** Every live contract is held, without naming a party, until a maintenance tick reads them (`Holds.reload`). Read as nobody frozen, a frozen player's deadlines banked and the real unfreeze gave the span back again. The lifetime is not given back for the unread stretch, which lasts one tick on a store that answers again.
- **Staff log search handles.** A search by citizen id without IdentityAce pages with handles kept per staff source (`openPages` in `server/panel.lua`, ten minutes, 20 each), holding the rows read past the page, never the store's cursor. A search that reads ten pages of the log without finding another row it may show stops there; narrow it by date to reach older rows.
- **Intent hold when the store cannot be read.** A proof-of-intent hold whose rows cannot be read is treated as holding (the payout waits) until a read succeeds. This is safer than paying a held line out.

## Integration: events and protocols

**Exports.** None. Nothing here is meant to be called by another resource:
contracts, escrow and payouts change only through the app and the staff
commands.

**Events.** It raises none for other resources. The `crimson-hitman:*` net
events are this resource's own protocol between its client and its server.
Every one resolves the player from the connection, never from the payload,
answers to a per-source flood guard and checks its payload; they are not an
API, and they may change between versions. What it listens to:

| Event | Raised by | What it does here |
|---|---|---|
| `QBCore:Server:PlayerLoaded` (and `qbx_core:server:playerLoaded`) | `qbx_core`, local | A character loaded: their session starts, the app is shown or hidden, owed payouts are delivered |
| `QBCore:Server:OnPlayerLoaded` | the client, net | The same, flood-guarded, and never the start of a watched session (any client can fire it) |
| `QBCore:Server:OnPlayerUnload`, `qbx_core:server:playerLoggedOut` | `qbx_core`, local | Logout or character switch: cleans up on the first, and again on the second, after `qbx_core` has let the player go |
| `playerDropped` | FXServer | Disconnect: the same cleanup |
| `QBCore:Server:OnJobUpdate` (and `qbx_core:server:onSetJob`) | `qbx_core`, local | Re-checks whether the app is closed to the player's jobs, or shows them the whitelisted-job view, and moves an open page between the two at once |
| `QBCore:Server:SetDuty` | `qbx_core`, local (`SetJobDuty`) | The same re-check on a duty change, which `Config.BlockOffDuty` reads; the maintenance tick repeats it for everybody every 30 seconds |
| `qbx_core:server:onSetMetaData` | `qbx_core`, local | An `injail` sentence starting or ending pauses or resumes contract clocks |
| `weaponDamageEvent` | FXServer | The damage log kills are attributed from |
| `sc-ambulance:server:UseDefib` | sc-ambulance's client, net | A defibrillator used on a target, flood-guarded |
| `lb-phone:deletedFromGallery`, `lb-phone:factoryReset` | `lb-phone`, local | Deletes the file behind a kill photo saved to Photos by link |
| `onResourceStart` | FXServer | A medical resource or `lb-phone` that restarted is asked afresh what it supports |
| `QBCore:Client:OnPlayerUnload`, `qbx_core:client:playerLoggedOut` | `qbx_core`, client | The client's death watcher forgets the last character |
| `gameEventTriggered` (`CEventNetworkEntityDamage`) | the game, client | The blow that killed the player, so their death report can name who dealt it |
| `onClientResourceStart` | FiveM, client | `lb-phone` starting again: the app is added to it again |
| `qb-clothing:client:loadOutfit`, `illenium-appearance:client:reloadSkin`, `rcore_clothing:outfitChanged` | a clothing resource, client | The player's appearance changed: the server drops their cached headshot |


**A command's answer to a player.** `crimson-hitman:commandOutput`, server to
client, with a list of lines: the answer of one command run in F8 (or chat),
batched in order under about 8 KB an event, FiveM's colour codes taken out.
The client prints each line in F8 (`client/admin.lua`); the notice *Printed to
your F8 console* goes through `crimson-hitman:notify`, as a popup never saved
on the phone.

**The admin panel's protocol.** Between `ui/admin.js`, `client/admin.lua` and
`server/panel.lua`; not an API for other resources. The page posts to its own
resource (`GetParentResourceName()`):

- `adminRequest` with `{ op, data }`, answered `{ ok, err, message, data }`.
  `message` is a sentence to show whenever there is one; for `void`, `settle`
  and `resolve` it is what the command would have said, in the panel's words:
  where the command's answer names a command, the panel's names the section
  or button that does it.
- `adminClose` with `{}`, answered `{ ok = true }`. The client gives the focus
  back and answers every request still waiting with `err = 'closed'`.
- The client answers without the server: `closed` (the panel is not open),
  `invalid_input` (no `op`, or one over 32 characters), `timeout` (no answer in
  15 s).
- Messages to the page, keyed `type`: `{ type = 'open', access }` (the `access`
  shape below), `{ type = 'close' }`, `{ type = 'push', kind = 'diag', line }`
  (a diagnosis line that had to wait for an answer).
- Every op can be refused with `not_allowed` (no ACE for it), `rate_limited`
  (`data.retryAfter` seconds), `unknown_op`, `admin_off`, `server_error` and
  `invalid_input`; every write also with `recovering` or `recovery_failed`;
  `whois`, and `logs` with an `actor`, with `identity_required`.
- A list arrives as `{}` when it is empty (it is a Lua table on the way), so
  read every list through a helper that takes either.
- People are shown as the staff member may see them (*Who may do what*): a
  `cid` field is absent without `crimson.identity`, and every citizen id
  elsewhere is a role.

| op | Needs | `data` sent | `data` answered |
|---|---|---|---|
| `access` | read | — | `{ canWrite, canModerate, canIdentify, canDevelop, developerAce, developerByAce, developerHint?, permissions = [{ ace, name, held, unlocks, grant }], pageSize, refreshSeconds, recovery = 'ready'\|'recovering'\|'recovery_failed', version }` (no command names: the page is buttons only; read-only metadata for the sections and the Permissions page) |
| `overview` | read | — | `{ at, contracts = { total, byState = { [state] = n } }, hitmen = { active, operatives }, held = { cash, bank, dirty, items, weapons, lines }, owed = { cash, bank, dirty, items, weapons, lines, players, queued }, stuck = { total, leftForStaff, byWhy = { [why] = n } }` (absent while recovering; `leftForStaff` counts the lines something settles by hand, `total` every line listed)`, reviews = { open }, photos = { waiting, kept, served }` (each `{ count, bytes }`)`, alerts = { open }, storage, fulfilment, photoStorage, recovery, slowest = [{ name, max, avg, last, runs }], slowMs, warnings = [line], overrides, auditQueued }` |
| `contracts` | read | `{ query?, state?, rule?, from?, to?, page?, ref? or person?, as?, byTarget? }` (times in os.time seconds; `ref` a player lookup's handle, `person` as Players' lookup takes it, `as` `target` / `client` / `hitman`) | `{ rows = [{ id, state, mode, rule, created_at, deadline_at, resolved_at, resolution, target, client, anonymous, slots, claimed, role?, roleAnonymous?, group?, onTarget? }], page, pages, total, targets? }`: the one contract list. With a person, each row's `role` is their part on it (an anonymous part only with `crimson.identity`); with `byTarget`, the unfinished contracts by target, `group` the target's citizen id only with `crimson.identity` |
| `contract` | read | `{ id }` | `{ contract = { id, state, mode, rule, reason, created_at, deadline_at, expires_at, resolved_at, resolution, paused_since, bailout_amount, penalty_amount, bonus_percent, slots, claimed, next_slot, buyout_queued, target_protected, anonymous, client = { name, cid? }, target = { name, cid? } }, escrow = [line], hitmen = [{ id, alias, anonymous, name, cid?, state, accepted_at, left_at, claims, stake, last_claim_at }], amendments = [{ id, kind, proposer, outcome, expires_at, payload }], timeline = [row]` (oldest first)`, stuck = [stuck]` (absent while recovering)`, canVoid, deadline = { left, stopped, adjustable, maxAdjust, minLeft } }` (`left` the exact run time left, in seconds) |
| `void` | moderate | `{ id, reason? }` | — (`message` is `/ch-void`'s answer, in the panel's words) |
| `addNote` | write | `{ id, text }` (at most 300 characters) | `{ id }`; refused `too_many` (100 a contract), `not_found` or `invalid_input`. Audited `staff_note` |
| `removeHitman` | write | `{ id, hitman, reason, returnStake?, block? }` (`hitman` the operative's row id from `contract`'s `hitmen`) | `{ stake, returned, forfeited, blocked, remaining }`; refused `bad_state`, `contract_frozen`, `no_operative`, `not_active`, `not_found` or `invalid_input`. Audited `staff_remove_hitman` |
| `editText` | write | `{ id, field = 'reason', text, reason }` | `{ new }`; refused `reason_refused` (the rule in `message`), `unchanged`, `no_text`, `busy`, `not_found` or `invalid_input`. Audited `staff_text_edit` (old and new text) |
| `exportContract` | read | `{ id }` | `{ text }`: the contract's record as plain text, scrubbed as `contract` is. Audited `admin_panel_export` |
| `playerView` | read | `{ id, role = 'target'\|'placer'\|'hitman', hitman? }` | `{ role, shown, note?, view?, whitelisted?, alias?, viewer? }`: `view` is `Projection.contract` for that party (scrubbed without `crimson.identity`, which alone gets `viewer = { cid, name }`). Audited `admin_panel_player_view` |
| `adjustDeadline` | moderate | `{ id, seconds, reason }` (`seconds` a signed whole number, not 0, within `Config.Limits.StaffDeadlineMaxAdjustSeconds` either way) | `{ seconds, leftBefore, leftAfter, deadline, lifetime = 'unchanged'\|'extended'\|'capped'?, expires? }`; refused `min_left` (with the most it can be shortened by in `message`), `at_limit`, `bad_state`, `not_found` or `invalid_input`. Audited `staff_deadline_adjust` |
| `settle` | write | `{ line, disposition = 'pay'\|'return'\|'delivered', amount?` (with `pay`)`, owner?` (with `return`, a citizen id) `}` | `{ detail }` (`message` is `/ch-settle`'s answer, in the panel's words) |
| `stuck` | read | — | `{ recovery, reviews, lines = [stuck] }`: every line waiting for staff, as `/ch-stuck` lists them, and the review queue's open count; `lines` absent while recovering. Audited `admin_stuck`, as the command is |
| `reviews` | read | `{ all? }` | `{ items = [{ id, kind, about, contract, parties = [{ role, who }], amount, account, items, known, now, state, created_at, resolution, resolved_by, resolved_at, unwritten }] }` |
| `resolve` | write | `{ id, action = 'refund'\|'pay'\|'dismiss'\|'finish', who?` (a role the item names, or a citizen id)`, amount?, account?, goods?, note? }` (`finish`, with no other field, finishes one left part-way as it was decided) | `{ detail = { action, settled, pending, parked, continued } }` (`message` is `/ch-review`'s answer, in the panel's words) |
| `logs` | read | `{ area?, kind?, action?, contract?, actor?, from?, to?, limit?, cursor? }`: `area` picks the log (Records › Logs' chips; `Panel.logArea` adds one): none or `audit` the audit log, as below; `settings` every setting change (`{ cursor?, limit? }` -> `{ rows = [{ ts, key, label, old, new, secret, reset, by, ref }], next, hidden }`, a Developer key only for its staff, `ref` only for the staff ACE); `org` the organisation's log (`{ action?, limit? }` -> `{ rows = [{ ts, action, kind, contract, by, detail }] }`, refused `org_off` while it is off). An unknown area is refused `invalid_input`. For the audit log: | `{ rows = [row], next }`: pass `next` back as `cursor` for the page after; absent on the last. `actor` without `crimson.identity` keeps only the rows that player acted in openly (audited `admin_panel_logs_player`) |
| `player` | read | `{ subject }` (a server id, a citizen id or a name), or `{ ref }` to read the same player again | `{ player = { cid?, name, online, server, ref }, contracts = [{ id, state, role, anonymous, target, created_at, resolution }], stats = { completed, failed, placed, survived, rate, standing }` (with `crimson.identity` only)`, owed = [line + queued], pending, notices = { count, titles }, frozen?, suspended?, protected?, payMax }` (`suspended` and `protected` are `{ since, until?, reason, by? }`, `by` with `crimson.identity` only); `not_found` for a citizen id nobody in the city has and nothing shown names |
| `whois` | identity | `{ id }` | `{ creator = { cid, name, anonymous }, target = { cid, name }, hitmen = [{ alias, cid, name, anonymous, state }] }` |
| `settings` | read | — | each `setting` carries its `category` (`rules-timers`, `rules-rewards`, `rules-limits`, `rules-targeting`, `features`, `developer`), `money` (its Rewards & money group), and `shipped`/`hasShipped` (defaults.lua's value); developer rows only for staff with the developer ACE. `{ features = [setting], limits = [setting], readonly = [setting], overrides, keptPhotos? = { count, open, links, files, waiting } }` (`keptPhotos` only while kill photos are off and some are kept from before) |
| `setSetting` | write | `{ key, value }` (a boolean, a number, one of `choices`, a word for a `text` key, a list of names, or `{ min, max }` for a `range` key; a key on `Settings.DENY` is refused `read_only`, and a developer-category key needs the developer ACE) | `{ key, value, old, source }`; refused `not_allowed`, `read_only`, `invalid_value`, `store_failed` or `busy` (another change is being saved), with why in `message` |
| `resetSetting` | write | `{ key }` | `{ key, value, old, source }`; also `not_overridden` and `busy` |
| `resetSettings` | write | — | `{ keys }` |
| `presets` | read | — | `{ presets = [{ name, about, builtIn, at?, changes = [{ key, label, from, to }], refused = [{ key, label, why }], same }] }`: every preset (server/presets.lua: the shipped Strict, Relaxed, Roleplay-heavy, and Current from the store, rp row kind `settings_preset`) against the settings in force now; reading changes nothing |
| `presetApply` | write | `{ name }` | `{ applied = [keys], refused = [{ key, why }] }`: Current saved first (unless it is Current), then each change through `Settings.set` (audited `admin_setting_changed`, in Change history with Undo), and one `admin_preset_applied` row; refused `not_found`, `unchanged`, `store_failed` |
| `presetSave` | write | — | saves Current (the values of every key a shipped preset names), audited `admin_preset_saved` |
| `setup` | write | — | `{ saved, savedAt?, savedBy?, storage = { mode, choices, line }, integrations = [{ kind, key, choice, active, choices, detected, without, required }], aces = [{ name, ace, held, line }], command = { key, label, value }, switches = [{ key, label, kind, choices, value }] }` (server/setup.lua); `access` carries `setupDue` while none is saved, for staff who may write |
| `setupPreview` | write | `{ values = { [key] = value } }` (at most 64 plain values) | `{ changes = [{ key, label, from, to }], refused = [{ key, label, why }], same }`; a key the setup does not offer is refused; changes nothing |
| `setupApply` | write | `{ values }` | `{ applied = [keys], refused = [{ key, why }] }`: each change through `Settings.set` (audited `admin_setting_changed`), the setup saved (rp row kind `setup`), one `admin_setup_applied` row; refused `invalid_input`, `store_failed` |
| `refresh` | write | — | `{ lines }` |
| `diag` | read | `{ subject? }` (a server id) | `{ lines }` |
| `flush` | write | — | `{ written }` |
| `alerts` | read | `{ state = 'open'\|'acknowledged' }` | `{ state, rows = [{ id, level = 'always'\|'problem', text, contract, count, first_at, last_at, acknowledged_by, acknowledged_at }]` (newest first, at most `limit`; without `crimson.identity`, `text` scrubbed and `acknowledged_by` is `'a staff member'` rather than their citizen id)`, open, acknowledged, limit, discord = { on, webhook = 'alert'\|'staff'\|nil, waiting, posting, posted, lastOkAt, lastFail = { at, tries, status, alerts, test } } }` (never a webhook's address) |
| `ackAlerts` | write | `{ ids = [id] }` (at most 100) | `{ done, already, missing }`; audited `admin_alerts_acknowledged` when it acknowledged any |
| `testAlert` | write | — | `{ seconds }`; refused `no_webhook` or `discord_off`. Audited `admin_alert_test` either way |
| `console` | developer (`crimson.developer`, or `crimson.admin` itself; refused `developer_required` with the grant line) | — | `{ at, debug, count, problems = [text], boot = [{ text, kind = 'always'\|'debug' }], bootLeft, recent = [{ text, kind = 'always'\|'debug', at, times }]` (oldest first)`, bootKept, recentKept, alwaysKept }`: what `shared/log.lua` keeps (`Log.view`), every line without a webhook's address, a secret convar's value or a statement's values, and scrubbed without `crimson.identity` |
| `removePhotos` | write | — | `{ removed, files, links, left, waiting }` (`left`: files that could not be deleted; `waiting`: open on a phone, removed when that view closes); refused `photos_on` while kill photos are on. Audited `admin_photos_removed`, with the count, every time |
| `history` | read | `{ subject }` or `{ ref }` | `{ counts = { placed, taken, completed, cancelled, onThem, boughtOut }, recent = [{ id, state, roles, anonymous?, created_at, resolved_at, client?, target? }], buyouts = { paid, amount }, informants = { count, spent, informant, placerInformant, locationTip }, money = { in = [{ kind, amount }], out = [...] }, measures = [{ kind, from, until?, ended?, state, reason, by?, endedBy? }], anonymous?, identified, retentionDays }`. Names and `anonymous` only with `crimson.identity`; without it nothing anonymous is counted |
| `suspend` | moderate | `{ ref, days (0 until lifted, at most 365), reason }` | `{ suspended = { since, until?, reason, by? } }`; also `already` |
| `unsuspend` | moderate | `{ ref, reason? }` | —; also `not_active` |
| `protect` | moderate | `{ ref, hours (0 for good, at most 8760), reason }` | `{ protected = { since, until?, reason, by? } }`; also `already` |
| `unprotect` | moderate | `{ ref, reason? }` | —; also `not_active` |
| `manualPay` | write | `{ ref, amount, account = 'cash'\|'bank', reason }` | `{ paid, owed }`; also `over_max`, `payments_off` |
| `targetLimits` | read | — | `{ keys = [{ key, label, unit, min, max, value }], jobs = [{ job, limits, at, effective }], ignored, jobMax, extendMax, overrideMaxHours }` (server/targetlimits.lua) |
| `targetStatus` | read | `{ subject }` or `{ ref }` | `{ player = { name, cid?, online, ref }, status = { live, day, week, dayAll, weekAll, cooldownLeft, cooldownRule, cooldownFrom = 'global'\|'job'\|'player', buyoutLeft? (seconds of a buyout's immunity left: only `targetReset` with `all` lifts it), exempt, limits, source, job (the one they work), jobs (every job they hold, primary first; the strictest override among them applies), jobOverride, jobOverrides, jobFrom, adjustment? } }`; audited `admin_panel_target_status` |
| `targetJobCount` | read | `{ job }` | `{ job, count }`: players in the city holding it now (working it or as a second job), and those not in the city whom the latest contract on them in the last 7 days recorded as holding it |
| `targetJobSet` | write | `{ job, limits = { [key] = n } }` | —; audited `staff_target_job_set`; also `too_many` |
| `targetJobRemove` | write | `{ job }` | —; audited `staff_target_job_removed`; also `not_active` |
| `targetReset` | moderate | `{ ref, reason, all? }` | —; audited `staff_target_reset`. Without `all` the same placer's wait, a staff extension and a buyout's immunity hold, and the message says so; `all` lifts them all |
| `targetExtend` | moderate | `{ ref, reason, minutes }` or `{ ref, reason, untilAt }` | —; audited `staff_target_extend` |
| `targetCounts` | moderate | `{ ref, reason }` | —; audited `staff_target_counts` |
| `targetOverride` | moderate | `{ ref, reason, hours (0 for good), exempt? , limits? }` | —; audited `staff_target_override` |
| `targetOverrideClear` | moderate | `{ ref, reason }` | —; audited `staff_target_clear`; also `not_active` |
| `targetJobAction` | moderate | `{ job, action = 'reset'\|'extend'\|'counts', reason, minutes?, all? }` | `{ done, failed }`; one row audited `staff_target_job_<action>` with the count; a reset, even with `all`, never lifts a buyout's immunity; also `nobody` |

`ref` is the handle `player` answered with: bound on the server to the character that lookup found, for the staff member who made it, for ten minutes. Every write naming a player (`freeze`, `unfreeze`, `setPlaytime` and the five above) takes it, or `subject` as an exact citizen id (or a contract party, `contract:<id>:<role>`); a name or a server id is refused there, never matched again. A stale handle is refused `stale_lookup` ("Look them up again").

`line` (an escrow line) is `{ id, contract, slot, portion, source, amount?,
item, quantity, state, owed_to, releasing_to, taken_from, staker, settled_to,
settled_at, settled_by_staff, arrived, raised, parked, owes }`; `row` (an audit
row) is `{ ts, kind, action, contract, actor, detail }`; `stuck` is a `/ch-stuck`
entry, `{ line, contract, amount, source, item, quantity, portion, intended,
why, at, raised, arrived, settles, orphan, unfinished, owed, actions }`, where
`actions` lists what settles it: `pay`, `pay_amount`, `return`, `return_owner`
(a `return` naming a citizen id) and `delivered`; never `return` for a line
owed to somebody (portion `owed`), which nobody put up to take back, and only
`pay` for one nothing of which was given (`why` `unqueued`, `stalled_claim`,
or `never_given_release` with `owed`; `never_given_release` owed to nobody
takes `return` alone). `why` `owed_to_nobody` (a line owed and queued to a
citizen id no character has) takes `return_owner`, and `owed_to_unchecked`
(qbx_core could not say) nothing. `setting` is `{ key, group,
label, about, kind = 'switch'\|'choice'\|'number'\|'list'\|'text', choices?, min?,
max?, integer?, live, inflight, readonly?, destroys?, value, default, source =
'config'\|'panel', by?, at?, ignored? }`: `live = false` is *applies after
restart*, `readonly` is why it cannot be changed, `destroys` (with `%s` for the
new value) is what lowering it deletes for good, which the page asks a second
click for, and `ignored` is why a value the store holds was not applied at start.

**Convars.**

| Convar | How | What |
|---|---|---|
| `crimson_hitman_webhook` | `set` in `server.cfg`, never `setr` | The staff Discord webhook (optional); the admin panel's alerts go there too when the alert webhook is not set |
| `crimson_hitman_alert_webhook` | `set` in `server.cfg`, never `setr` | The Discord webhook the admin panel's alerts are posted to (optional) |
| `crimson_hitman_new_store` | `set crimson_hitman_new_store 1` in the console, once | `json` mode: start an empty store on purpose (see *Updating*) |
| `web_baseUrl` | read | The public address kill photos are served from when `Config.Completion.PhotoPublicUrl` is unset |
| `inventory:accounts` | read (`ox_inventory`'s, default `["money"]`) | Items that are money and so are refused as goods |

**lb-phone** (not a manifest dependency, so restarting it is safe; every call
is guarded). Client: `AddCustomApp` with the identifier `crimson-hitman`, and
`RemoveCustomApp` (or `DeleteCustomApp`, `UninstallApp`) for a player who
loses access; `SendCustomAppMessage`; `SendNotification` for the popup;
`SetCameraComponent` on `'host'` photo storage; `EnableWalkableCam` /
`DisableWalkableCam` behind the `'server'` viewfinder; `SaveToGallery` where
the page cannot save. Server: `GetEquippedPhoneNumber` and `SendNotification`
for saved notices, `CreateCall`, `IsInCall` and `EndCall` for relay calls,
`GetConfig` for upload hosts and caller masking, `ContainsBlacklistedWord` on
reasons and messages, and the two gallery events above.

**ox_inventory** (optional, the inventory adapter; without one, item, weapon and dirty-money rewards are off). `GetInventoryItems`, `GetInventory`, `Search` and
`GetItem` read what a player can put up; `RemoveItem` takes it into escrow;
`CanCarryItem` then `AddItem` pay it out or hand it back, with the metadata it
was taken with. Each call is made inside `pcall`, and a raise is a refusal,
except an `AddItem` that raised after the item arrived: `GetItemCount` (or
`Search` by serial, for a weapon) before and after the give tells which, and
one that arrived is delivered (see *What stops it being abused*). It registers
no ox_inventory hooks and ships no items.

**sc-dispatch** (optional; `Config.Advisory.UseDispatch`, only while it is
started). A threat advisory goes to the MDT through `AddNotification` with
`caller = 'Criminal Intelligence'`, `priority = Config.Advisory.DispatchPriority`,
`job_table` from `Config.Advisory.RecipientJobNames` and
`unique_id = 'ch-<contract>-<stage>'` (`posted` or `accepted`); both are
cleared with `ClearNotification` when a contract on an officer ends, whatever
`Config.Advisory` says by then (clearing an id never filed does nothing).

**Other optional hooks**, each skipped when the resource is not started:
`sc-ambulance` (`IsDead`, `IsLaststand`, the ambulance adapter,
`Config.Integrations.Ambulance`; QBox metadata answers otherwise),
`sc-blackmarket` (`AddTrust(citizenid, amount)` on a completed contract,
`Config.Record.Progression`, the progression adapter), `MugShotBase64` (`GetMugShotBase64` on the client, for
headshots), `Config.Kidnap.RestraintProvider` (`IsRestrained(playerId)`) and
`Config.Immunity.PlaytimeProvider` (minutes played by citizen id; without it
the playtime is counted here, see *New players and playtime*).


## oxmysql, as the mysql store relies on it

The reference the mysql store (`crimson-hitman/server/storage/mysql.lua`) and the
test harness that stands in for oxmysql (`tests/harness/mysql_exec.lua`,
`natives.lua`, `await_scheduler.lua`) cite as `oxmysql §N` (docs/developer.md). Each section says what
oxmysql does, so a comment that leans on it can be checked here.

### oxmysql §0. Version and how it was checked

* **OX**: overextended/oxmysql, tag `v2.14.3` (commit `bae715c`). Paths below are in its source.
* **M2**: mysql2 3.24.5, with oxmysql's `patches/mysql2@3.24.5.patch` applied.
* **NP**: named-placeholders 1.1.6, with oxmysql's patch applied.
* **SE**: sql-escaper 1.5.2, the version oxmysql's `bun.lock` pins (mysql2's query formatter).
* **FX**: citizenfx/fivem `data/shared/citizen/scripting/lua/scheduler.lua` and `deferred.lua`
  (the Lua scheduler and promises), and `.../v8/main.js` (the JS runtime).

Behaviour marked **[run]** was observed by running the real oxmysql 2.14.3 source (bundled
as its own build bundles it) under node 22 against MariaDB 10.11.14, through its exports,
with the FiveM globals shimmed and Lua tables sent as FiveM's msgpack sends them. Marked
**[src]**: read from the source only. To check a claim again, read the cited lines in that
version, or run the same call against a scratch database.


### oxmysql §1. The call path

* `MySQL[method].await(sql, params)` calls the export
  `oxmysql[method](nil, sql, params, function(result, error) ... end, resourceName, true)` and
  then `Citizen.Await(p)` (OX `lib/MySQL.lua:15-27, 87-97`). The callback rejects the promise
  when `error` is set, else resolves it with `result`.
* A plain call `MySQL[method](sql, params, cb)` does not wait. It passes `isPromise` as the
  resource's `mysql_option 'return_callback_errors'`, which is off unless the fxmanifest sets
  it (OX `lib/MySQL.lua:6-13, 72-77`).
* The exports return at once; the answer only ever comes through `cb` (OX `src/index.ts:20-102`).
* A call made before oxmysql has a pool waits in `while (!pool) await sleep(0)`
  (OX `src/database/connection.ts:71-72`).
* Lua to JS: a Lua table whose keys are exactly 1..n is a JS array; a table with a nil hole
  is a msgpack map and arrives as a JS object `{"1": a, "3": c}` (FX `scheduler.lua:30-34`,
  lua-cmsgpack `set_array('without_hole')`). `{}` is `[]`.
* JS to Lua: `null`/`undefined` become `nil`, so a NULL column is a key absent from the row;
  an integer within int32 is a Lua integer, any other number a Lua float.

### oxmysql §2. Placeholders

On `query`, `single`, `scalar`, `update`, `insert` and `transaction` (OX
`src/utils/parseArguments.ts:4-37`), formatted on the client by sql-escaper:

| Case | Behaviour |
|---|---|
| `?` with an array | Positional. Fewer values than `?`: the rest are NULL. More values: raises `Expected N parameters, but received M.` before anything is sent, without yielding. [run] |
| `?` with an object (a Lua table with a hole) | Each `?` takes `params[i + 1] ?? null`: the hole is NULL, extra keys are ignored. [run] |
| `@name` / `:name` | Converted only when the parameters are an **object** and the SQL text holds `:` or `@` anywhere (OX `parseArguments.ts:7-10`). [run] |
| An object and any `:` or `@` in the SQL, even in a `--` comment or a string literal | The named path numbers each `?` from 0 (NP `index.js:50`), so the first `?` gets NULL and every other one the value meant for the one before it. No error. An array with the same SQL is unaffected. [run] |
| nil | NULL. |
| boolean | `true` / `false`, stored as 1 / 0, never NULL (SE). |
| a sequence table as one value | Expanded to `a, b, c`: right for `IN (?)` only. |

This resource's SQL never holds `:` or `@` (a rule in `tests/static_check.lua`),
because about twenty of its writes send tables with holes.

### oxmysql §3. Return shapes

`parseResponse` (OX `src/utils/parseResponse.ts:4-22`). [run]

| Method | Returns |
|---|---|
| `query` SELECT | An array of rows (`{}` when none). |
| `query` INSERT/UPDATE/DELETE | The result header `{ affectedRows, insertId, ... }`. |
| `scalar` | The first column of the first row, or nil (`0` and `false` survive). |
| `insert` | `insertId`; 0 on a table without AUTO_INCREMENT. |
| `update` | `affectedRows`, **matched rows, not changed rows**: mysql2 connects with `FOUND_ROWS` by default (M2 `lib/connection_config.js:286-289`). `UPDATE t SET s = s` answers 1. A DELETE answers the rows deleted. |
| `transaction` | `true` after COMMIT; **`false`** when any statement fails, after a ROLLBACK, with the error printed. It does **not** raise for an SQL error (OX `src/database/rawTransaction.ts:35-91`). It does raise for malformed input (not an array; more values than `?`). A statement matching no row does not fail it. [src] `false` also comes back when COMMIT was sent and its answer was lost, so false does not prove nothing landed. |

### oxmysql §4. What a column comes back as

Through `query` and the others (OX `src/utils/typeCast.ts:30-71`). [run]

* `TINYINT(1)` / `BOOLEAN`: a boolean, `true` only for 1 (2 reads as false).
* `INT`: a number. `BIGINT`: a number up to 2^53, else a string. `COUNT(*)`: a number.
* `DECIMAL`, `SUM(int)`, `AVG()`: a **string**.
* `DATETIME` / `TIMESTAMP`: milliseconds, read in the FXServer process's time zone.
* `JSON` and `TEXT`: a string, not decoded.

This store's schema uses `INT`, `VARCHAR`, `TEXT` and `TINYINT(1)` only, and reads `COUNT(*)`
through `tonumber`, so none of the string or millisecond shapes reach it.

### oxmysql §5. Errors

| Situation | What happens |
|---|---|
| SQL error under `.await` (syntax, duplicate key, strict-mode `Data too long`, `Column 'x' cannot be null`, `Out of range value`) | The callback gets `(nil, message)`, the promise is rejected and `Citizen.Await` **raises** (FX `scheduler.lua:85-99`). oxmysql prints nothing itself. The message is `"<resource> was unable to execute a query!\nQuery: <sql>\n<params as JSON>\n<server message>"` (OX `src/logger/index.ts:35-37`): every parameter value is in it. [run] |
| A parse error (too many `?` values) | Raised at once, without yielding. [run] |
| SQL error on a plain call (no `return_callback_errors`) | Printed with `console.error`; **the callback is never called**. [run] |
| SQL error in a transaction | Answers `false`, prints `"<resource> was unable to complete a transaction!..."`, rolls back. [run] |
| Session `sql_mode` | MariaDB's default plus mysql2's `IGNORE_SPACE`: `STRICT_TRANS_TABLES` among them, so an overlong string, an INT past -2^31..2^31-1, a TEXT past 65,535 bytes and a NULL in a NOT NULL column are **refused**, never cut short or wrapped. [run] |

### oxmysql §6. While the database is down

**At start.** oxmysql tries once, prints `Unable to establish a connection to the database`,
then retries every 30 s for good (OX `src/database/index.ts:5-12`, `pool.ts:28-44`). Every
statement issued meanwhile **waits, with no error and no timeout**, and is answered at the
retry that connects. [run]

**Mid-run, once the pool exists: awaits are never answered.** `getConnection()` runs outside
the `try` in `rawQuery.ts:29` (and in `rawExecute.ts:34`, `rawTransaction.ts:31`). When mysql2
cannot open a connection the export's promise rejects, **`cb` is never called**, and FXServer
prints only an unhandled rejection (FX `v8/main.js:443-470`). [run]

| Scenario | `.await` outcome |
|---|---|
| MariaDB stopped; then `query`, `update`, `transaction` | Never answered. `isReady()` still says true. |
| Issued while down, database back 1.5 s later | Still never answered: a lost call does not come back. |
| A fresh call after the database is back | Answered: the pool recovers by itself. |
| A statement in flight when MariaDB is killed | Raises `Connection lost: The server closed the connection.` It may or may not have committed. |
| The network stops answering, an idle pooled connection reused | Never answered: oxmysql passes no query timeout and mysql2 has none. |

In Lua a coroutine parked in `Citizen.Await` on a promise that never settles is never resumed:
not an error, so a `pcall` around it never returns either (FX `scheduler.lua:85-99`). This is
why the store races every statement against `Config.Database.QueryTimeoutSeconds`, and why a
statement given up on may still land later.

### oxmysql §7. Every await yields

`Citizen.Await` yields when the promise is still pending, and a successful query's callback
always arrives on a later JS tick, so **every** `.await` yields its coroutine, every time; only
a parse error raises without yielding (FX `scheduler.lua:85-99`, `465-511`). [run]

Meanwhile anything else in the resource may run to its own next yield: other net events (each
its own thread), the `CreateThread` loops, timers, commands, exports called by other
resources. Lua state read before an await can be stale after it.

A plain `MySQL.insert(sql, params)` with no `.await` does not yield; the statement runs inside
oxmysql whatever happens to the caller (OX `src/index.ts:60-68`).

### oxmysql §8. Pool and concurrency

* mysql2's pool: 10 connections, an unbounded queue (M2 `lib/pool_config.js:11-30`).
* Two awaits run at once on different connections and finish in completion order, not call
  order. [run]
* One coroutine's awaits usually land on the same connection, by luck, not by guarantee: never
  rely on session state (user variables, `LAST_INSERT_ID()`, `GET_LOCK`) across two awaits.
  This store uses none.
* Each `.await` is its own autocommit transaction; only `transaction` groups statements.

### oxmysql §9. `mysql_connection_string`

Every option value is a string, so `?multipleStatements=false` turns multiple statements ON
(`"false"` is truthy) [run]. `connectTimeout` (oxmysql's default 60 s) covers opening a
connection only; there is no query timeout anywhere. `flags=["-FOUND_ROWS"]` would make
`update` answer changed rows instead of matched ones [src].

### oxmysql §10. What oxmysql prints

* A statement slower than `mysql_slow_query_warning` (200 ms by default) is printed **with its
  full SQL and every parameter value** (OX `src/logger/index.ts:78-93`). [run]
* A result of 1,000 rows or more: `executed a query with an oversized result set`
  (OX `src/utils/validateResultSet.ts`). [run]

### oxmysql §11. What this store relies on

* Every `db.*` call yields (§7) and is bounded by `Config.Database.QueryTimeoutSeconds` (§6).
* A failed statement raises (§5); a failed transaction answers false (§3).
* `update` answers matched rows (§3): a compare-and-set `UPDATE ... WHERE id = ? AND state = ?`
  answers 1 only when the row was in that state, and an `UPDATE` setting what is already there
  answers 1 too.
* NULL is a missing key and `TINYINT(1)` a boolean (§1, §4).

### oxmysql §12. Assumptions that differ from oxmysql

1. **"An await returns or raises."** Not during an outage (§6): a statement that needs a new
   connection while MariaDB cannot be reached is never answered, and a `pcall` cannot catch it.
   The store races each statement against a timeout and treats one given up on as one that may
   still land.
2. **A table with a hole plus a `:` or `@` in the SQL** shifts every value one column (§2), with
   no error. Kept out by the static check.
3. **A stand-in that raises on a failed transaction, keeps the statements before it, stores
   values strict mode refuses, or never yields** is not oxmysql (§3, §5, §7). The harness
   (`mysql_exec.lua`, `await_scheduler.lua`) is held to this file.
4. **Matched rows** (§3): an `UPDATE` that changes nothing still answers 1.
5. **A failed read answers nothing**: it raises (§5).
6. **A plain call with no `.await`** (the audit's and the alerts' writes while the resource stops) is not waited for: a failure
   is only printed by oxmysql and the row is lost; several run at once, so their order may not
   be the call order (§5, §8).
7. **Console exposure.** oxmysql's error message (§5) and its slow-query line (§10) carry every
   parameter value: citizen ids, character names, reasons, message bodies. Anything this
   resource prints or stores from an error is cut to the statement's start and the server's own
   words, never its parameters.
8. **A thousand rows** in one result prints oxmysql's oversized-result warning (§10).
9. **Session state across awaits** is not guaranteed (§8).
10. **Lua `false` as a parameter is 0, not NULL** (§2): bind `nil` for NULL.
11. **A start with the database down** waits silently until oxmysql's next 30 s retry (§6).

## The specification's rules, by number

Code comments cite the original specification's rules by number. Its text is
retired: what is still true is in this file, the owner docs and the code each
comment sits in. The titles, to read a citation by:

| § | Rule |
|---|---|
| §1 | **Overview** |
| §2 | **Job & Access Restrictions** |
| §3 | **Contract Creation** |
| §3.1 | Target Selection |
| §3.2 | Contract Reason |
| §3.3 | Assignment Mode |
| §3.4 | "Dead or Alive" Reward Selection |
| §3.5 | Payout Slots — multiple collections per contract |
| §3.5 | Escrow Automation |
| §3.6 | Failure Penalty Configuration |
| §4 | **Privacy & Identity (Anonymous Mode)** |
| §5 | **Target Interaction — "Contract Cleanse" (Self-Bailout)** |
| §6 | **Additional Immersive Features** |
| §6.1 | Counter-Intelligence — Purchasable Hitman Identity |
| §6.2 | Blood Money Laundering — Crypto / Dirty Money Payouts |
| §6.3 | Proof of Death Archive — The Hitman's Ledger |
| §7 | **System Logic & Completion Tracking** |
| §7.1 | Online Presence Dependency |
| §7.2 | Real-Time Visuals |
| §7.3 | Automated lb-phone Notifications |
| §7.4 | Contract Acceptance & Payout Security |
| §7.5 | Law Enforcement Threat Advisory |
| §8 | **Configuration Surface (`config.lua`)** |
| §9 | **Binding Implementation Rules** |
| §9.1 | Escrow is the single source of truth |
| §9.2 | One shared release routine |
| §9.3 | Refunds never destroy property |
| §9.4 | Weapons are snapshots |
| §9.5 | Rate limiting |
| §9.6 | Server authority |
| §9.7 | Atomic completion |
| §9.8 | Financial audit log |
| §9.9 | Persistence footprint |
| §9.10 | Contract state machine |
| §10 | **Persistence Modes (`Config.Database.Mode`)** |
| §10.1 | A correction worth stating plainly |
| §10.2 | `json` mode requirements |
| §10.3 | `memory` mode requirements |
| §10.4 | Mode-independent guarantees |
| §11 | **Contract Communications (Masked Relay)** |
| §11.1 | Masked identities |
| §11.2 | In-app contract thread |
| §11.3 | Voice calls |
| §11.4 | Abuse controls |
| §12 | **Contract Amendments** |
| §12.1 | Additive changes — immediate |
| §12.2 | Material changes — mutual approval required |
| §12.3 | What can never be amended |
| §12.4 | Withdrawal and abandonment |
| §12.5 | The hitman's final determination |
| §13 | **Participation & Concurrency** |
| §13.1 | Conflict rules (server-enforced, non-negotiable) |
| §13.2 | Concurrency safety |
| §14 | **Abuse Resistance** |
| §14.1 | The acting player is the event source, never a payload field |
| §14.2 | Death reports are victim-sourced and independently corroborated |
| §14.3 | Escrow rows carry a settled state and every release is a guarded compare-and-set |
| §14.4 | Anonymity and hiding are enforced by omission at the transmit boundary |
| §14.5 | Contract limits are enforced per target, not only per actor |
| §14.6 | Creator, target and hitman are three distinct parties |
| §14.7 | Economic limits are keyed to the account, not the character |
| §14.8 | Every contract has an absolute lifetime; the pause has a ceiling; hitmen can always get out |
| §14.9 | Cancellation is defined, gated, locked and logged |
| §14.10 | Release is source-faithful; currency conversion is a payout-only, lossy, explicit step |
| §14.11 | The write debounce is not a durability window for money |
| §14.12 | Pending releases are per-line, bounded, and dead-lettered |
| §14.13 | One validator builds the escrow record from server-read data, over baseline and bonus together |
| §14.14 | Every client-supplied number passes one coercion helper before any comparison |
| §14.15 | Non-escrow transfers are debit-first, server-priced, and two-sided |
| §14.16 | The bailout premium is server-clamped and rail-limited |
| §14.17 | Bailout has a state gate, a processing delay, and never rug-pulls a hitman |
| §14.18 | The failure penalty is staked at acceptance, capped, and disclosed before it can be agreed to |
| §14.19 | Target eligibility is checked at creation, acceptance and every payout tick |
| §14.20 | The verification photo is obtained from the camera flow, never from the payload |
| §14.21 | Server-read positions are untrusted telemetry, sampled with continuity and one grace budget |
| §14.22 | Tracking is defined, coarse, scoped and suppressed — it is not a player locator |
| §14.23 | Kidnap countdowns run on one shared tick behind an arm gate |
| §14.24 | Kidnapping requires observable coercion and a living, conscious target |
| §14.25 | Kidnap delivery has a creator obligation clock and a maximum hold |
| §14.26 | The mugshot is frozen or floor-debounced, and pushed only to subscribers |
| §14.27 | Every net event passes one gate before its handler body runs |
| §14.28 | Read handlers derive their result set from the requester, never from a submitted id |
| §14.29 | Informant Data: authorised buyer, server-side selection, engaged pool, uniform response |
| §14.30 | The contract reason is content-controlled and permanently attributed |
| §14.31 | §9.8 becomes a conduct log, with reports and admin commands |
| §14.32 | Listing visibility for anonymous contracts follows the target's presence only |
| §14.33 | Target selection is a scoped server-side search, not a roster |
| §14.34 | Acceptance is a conditional atomic write |
| §14.35 | Capture tokens have provenance, one live token per hitman-contract, and single use |
| §14.36 | Photo proximity binds to the recorded death scene, not the live ped |
| §14.37 | Competitive contracts cap simultaneous hitmen per target |
| §14.38 | Pair throttles and a minimum age before completion |
| §14.39 | Post-death immunity and an attributed-death cap |
| §14.40 | Notifications carry a per-recipient budget |
| §14.41 | The engagement record is always computed; gating payout on it is the owner's choice |
| §14.42 | Disconnecting inside an active engagement is recorded |
| §14.43 | Ledger content, anonymity scope, and photo lifecycle |
| §14.44 | The log's write path, distribution, retention and purge are bounded |
| §14.45 | Weapon serials and unique item identifiers never leave the holder |
| §14.46 | Fees fold into the atomic escrow debit and carry generic transaction memos |
| §14.47 | Boot-time configuration validation |
| §14.48 | json persistence is sharded per contract |
| §14.49 | memory-mode disconnect cancel is scoped to unaccepted contracts |
| §14.50 | A creation gate that is not a resource stop |
| §14.51 | Contract Cleanse is discreet, not anonymous |
| §15 | **Progression & Reputation** |
| §16.1 | Criminal progression |
| §16.2 | Hitman record |
| §16.3 | What counts |
| §16 | **Configuration Appendix** |
| §17 | **Design Rationale** |

§14.22 (coarse tracking) was never built; §9.9 and §14.48 describe `json` storage, no longer the shipped mode.
