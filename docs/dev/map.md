# crimson-hitman: map of the resource

Step 1 of the owner's programme (make it simpler, better, sellable). This is a
map of the resource as it stands at `b31d10a`: what every file is for, every
feature and screen, every config section, then the **overlaps**, each with a
merge proposal for the later steps. The last section is the capability
inventory that proves no later step loses anything (hard rule 5).

Line numbers are `file:line` against `b31d10a`; paths are under
`crimson-hitman/` unless they start with `tests/` or `docs/`.

## Headline numbers

| What | Count |
|---|---:|
| Source files (Lua, JS, HTML, CSS, SQL, manifest, README) | 97 |
| Lines in them | 102,099 |
| Lua files: server / client / shared / config | 77 / 6 / 3 / 2 |
| Config key paths (config.lua + defaults.lua) | 537, in 69 sections |
| Admin panel settings (catalogue keys) | 477, of which 125 are switches |
| Admin panel ops | 96 (56 in `panel.lua` OPS, 40 added by `Panel.extend`) |
| Phone app requests (App handlers) | 92 (59 core, 33 organisation) |
| NUI callbacks | 63 |
| Net events registered: server / client | 11 (+92 via `handler()`) / 22 |
| Commands / ACE names / exports offered | 12 / 5 / 0 |
| Audit action names | 309 |
| Refusal codes (CH.ERR + Org.ERR) | 144 |
| Screens: phone tabs / board tabs / phone dialogs | 7 / 2 / 6 (+ default dialog) |
| Screens: admin groups / views / drawer tabs / inbox filters | 11 / 43 / 5 / 4 |
| Maintenance tick jobs | 43 |
| Other resources called (exports + events) | 13 resources, 38 distinct exports |
| Overlap families found (below) | 20 helper families, 12 idea clusters, 7 screen clusters |

Counts come from `lua5.4 tests/inventory/extract.lua --print` (see the last
section) except files/lines (`wc -l`) and switches (catalogue entries of kind
`switch`).

## Modules

Areas: **Platform** (boot, wiring, storage, logging), **Config**, **Network**
(the phone's surface, identity, cards, notices, relay), **Contracts** (the money
and the lifecycle), **Completion** (kill, photo, handover, markers, disposal),
**Intel** (informants, tips, rumours), **Roleplay** (`rp_*`), **Improvements**
(`imp_*`), **Staff** (commands, panel, settings, measures), **Organisation**
(`server/org/`), **Client**, **UI**.

| Area | File | Lines | Purpose |
|---|---|---:|---|
| Platform | `fxmanifest.lua` | 104 | Manifest: shared config, client and server entry points, NUI files, deps qbx_core + ox_inventory |
| Platform | `server/boot.lua` | 211 | CrimsonBoot module loader and the wait for required resources |
| Platform | `server/main.lua` | 3658 | Wiring of every module, start-up config validation, boot recovery, the maintenance tick |
| Platform | `server/bridges.lua` | 1933 | Every engine/framework event (damage, txAdmin, qbx job/load/unload, lb-phone), staff commands, /cleanse |
| Platform | `server/audit.lua` | 476 | Queued audit log (financial/staff/action/rejected) and its own webhook copy |
| Platform | `server/timing.lua` | 170 | Per-job timing of the tick for /ch-diag and Health |
| Platform | `server/storage/memory.lua` | 2076 | Reference storage backend (tests, memory mode) |
| Platform | `server/storage/json.lua` | 3844 | Flat-file storage backend (shards, day audit files) |
| Platform | `server/storage/mysql.lua` | 3866 | oxmysql storage backend, parameterised SQL, schema checks |
| Platform | `shared/constants.lua` | 570 | CH: states, transitions, sources, modes, CH.ERR refusal codes |
| Platform | `shared/util.lua` | 943 | Pure helpers: coercion, text sanitising, ids, clock bands, money charge/credit, rule readers |
| Platform | `shared/log.lua` | 367 | CrimsonLog: the one way to the console, Debug gating, problem lines |
| Config | `config/config.lua` | 851 | The owner's working configuration (Config) |
| Config | `config/defaults.lua` | 850 | Shipped defaults (ConfigDefaults), same layout; fills missing sections |
| Config | `install/sql/crimson_hitman.sql` | 584 | MySQL schema |
| Network | `server/app.lua` | 2282 | The phone's network surface: handler() gate (ready, ratelimit, identity, roleplay gates), every app request |
| Network | `server/identity.lua` | 843 | The only reader of `source`: actor resolution, access gates, job checks, death state, playtime |
| Network | `server/ratelimit.lua` | 193 | Per-citizen token buckets (Config.Cooldowns) |
| Network | `server/projection.lua` | 1632 | Per-recipient card building; anonymity by omission; card extensions |
| Network | `server/notify.lua` | 1885 | Phone notifications with budgets, kept notices, LEO advisories via sc-dispatch, whitelisted-view alerts |
| Network | `server/comms.lua` | 717 | Masked message relay and masked calls between parties |
| Contracts | `server/contracts.lua` | 5136 | Contract lifecycle: create, accept, state machine, limits, idle holds, endings |
| Contracts | `server/escrow.lua` | 2875 | Escrow: what a contract holds, charge on place, release/settle, pending deliveries |
| Contracts | `server/amendments.lua` | 1394 | Proposals and additive edits to a contract (Improve, add escrow, revise) |
| Contracts | `server/bailout.lua` | 1023 | Cleanse: the target buys out their contract, queue and refunds |
| Contracts | `server/review.lua` | 1074 | Review queue: money no rule can settle, kept for staff |
| Contracts | `server/ledger.lua` | 251 | Hitman's Ledger: last N completed contracts per participant |
| Contracts | `server/progression.lua` | 104 | Player record and the trust export call (sc-blackmarket AddTrust) |
| Contracts | `server/targetlimits.lua` | 672 | How often one person may be targeted: defaults, per job, per player overrides |
| Completion | `server/completion/death.lua` | 1760 | Kill attribution: observed damage + death report, last stand, revive/defib, restart carry-over |
| Completion | `server/completion/photo.lua` | 867 | Verification photo (host link or server upload) and Verify kill |
| Completion | `server/completion/kidnap.lua` | 1084 | Live handover: shared countdown tick, coercion, conscious checks |
| Completion | `server/photos.lua` | 1366 | Kill photo kept for the placer, one look, gallery, files |
| Completion | `server/mugshot.lua` | 259 | Live target headshots rendered by the target's own client |
| Completion | `server/meeting.lua` | 504 | Handover meeting point set by the placer, blips to hitmen |
| Completion | `server/handover_confirm.lua` | 60 | Placer confirms a live handover (Kidnap.PlacerConfirms) |
| Completion | `server/missionsteps.lua` | 455 | Step markers: who sees which map marker for each step |
| Completion | `server/disposal.lua` | 1107 | Body disposal: hearse, drop-off, pay-on-drop, panel spots |
| Intel | `server/informant.lua` | 849 | Target's informant (names a hitman) and placer's informant |
| Intel | `server/locationtip.lua` | 618 | Informant tip: hitman buys the target's rough area |
| Intel | `server/imp_tips.lua` | 710 | Six tip fairness rules: warning delay, limits, hold-first, second try, safe zones, go dark |
| Intel | `server/rp_informant.lua` | 59 | Informant as an NPC: purchases only beside it |
| Intel | `server/rp_rumours.lua` | 343 | Rumours board and the broker (NPC or player) briefing |
| Roleplay | `server/rp_places.lua` | 324 | Roleplay shared helpers: feature blocks, place parsing, NPC rotation, coordsOf |
| Roleplay | `server/rp_consequences.lua` | 621 | Witness heat, EMS before re-listing, City news, Dirty payouts |
| Roleplay | `server/rp_intent.lua` | 357 | Proof of intent: payout held until messages/time |
| Roleplay | `server/rp_reputation.lua` | 127 | Reputation earned in character (trust gated by witnesses) |
| Roleplay | `server/rp_protection.lua` | 923 | Bodyguard contracts and Hit on the hitman |
| Roleplay | `server/rp_burner.lua` | 140 | Burner phone item required/consumed |
| Roleplay | `server/rp_reason.lua` | 118 | Reason quality: min length/words, low-effort refuse or review |
| Improvements | `server/imp_board.lua` | 182 | Board improvements shared rules and wiring (heat, placer record, tiers, decay) |
| Improvements | `server/imp_staffeco.lua` | 139 | Staff & economy improvements shared helpers (proof items, scrub, weekly) |
| Improvements | `server/imp_heat.lua` | 288 | Hitman heat from police bulletins, known-hitman warning |
| Improvements | `server/imp_placer_record.lua` | 153 | Placer's record on board cards |
| Improvements | `server/imp_tiers.lua` | 105 | Tiered board by reward and level |
| Improvements | `server/imp_decay.lua` | 556 | Untaken contracts change reward over time |
| Improvements | `server/imp_proof.lua` | 235 | Proof items: finish with an item taken from the body |
| Improvements | `server/imp_scrub.lua` | 198 | Weapon serial scrubbing for anonymous placers |
| Improvements | `server/imp_weekly.lua` | 242 | Weekly stats post to Discord |
| Staff | `server/admin.lua` | 3307 | Staff commands (ch-*), diagnosis, timelines, deadline adjust, panel words |
| Staff | `server/panel.lua` | 3861 | Admin panel server: OPS table, one gate, every op handler, Panel.extend |
| Staff | `server/settings.lua` | 2988 | Settings catalogue (477 keys), validation, persistence over config.lua, history/undo |
| Staff | `server/freeze.lua` | 929 | Staff freezes, app pause, restart hold (all through contract pause) |
| Staff | `server/sanctions.lua` | 401 | Suspend a player from contracts; protect a player from being targeted |
| Staff | `server/payments.lua` | 115 | Manual staff payments |
| Staff | `server/staffcontract.lua` | 364 | Staff notes, remove hitman, replace text, export, party view |
| Staff | `server/staff_reward.lua` | 470 | Staff change reward through escrow (preview + change) |
| Staff | `server/staff_reassign.lua` | 466 | Staff reassign a live contract to another hitman |
| Staff | `server/announce.lua` | 99 | Notice from staff to every hitman |
| Staff | `server/history.lua` | 254 | One player's history card |
| Staff | `server/reports.lua` | 117 | Player Report button -> review queue item |
| Staff | `server/thresholds.lua` | 122 | Staff alert thresholds (placed/hour, target/day, refusals/10 min) |
| Staff | `server/alerts.lua` | 666 | Alerts list and Discord poster (Alerts.post) |
| Staff | `server/summary.lua` | 167 | Daily summary to staff Discord |
| Staff | `server/playtime.lua` | 450 | Built-in playtime tracker (for Immunity) |
| Organisation | `server/org/init.lua` | 2224 | Organisation state, the job, cuts, accept gate, places, invites, funds calls |
| Organisation | `server/org/engine.lua` | 216 | Pure rules: who holds which power, rank checks |
| Organisation | `server/org/powers.lua` | 164 | Boss power codes, areas, defaults, limits |
| Organisation | `server/org/funds.lua` | 484 | Org money: Renewed-Banking account or internal ledger |
| Organisation | `server/org/jobs.lua` | 242 | Registers/keeps the qbx_core job in step |
| Organisation | `server/org/schema.lua` | 299 | Org tables, one shape for all three storage modes |
| Organisation | `server/org/settings_catalogue.lua` | 121 | Org settings added to the catalogue |
| Organisation | `server/org/boss_ops.lua` | 206 | Phone requests for members/bosses (33 via App.addHandler) + orgUse spot event |
| Organisation | `server/org/staff_ops.lua` | 371 | Admin panel org and Boss-permission ops via Panel.extend |
| Client | `client/main.lua` | 1505 | lb-phone app registration, NUI bridge (UI_EVENTS), camera, GPS, meeting/tip blips, death watcher |
| Client | `client/admin.lua` | 232 | Admin panel NUI page open/close and its request bridge |
| Client | `client/missionsteps.lua` | 212 | CrimsonMarkers: map markers and ox_target zones per step |
| Client | `client/mugshot.lua` | 85 | Renders own ped headshot (MugShotBase64) |
| Client | `client/rp_npc.lua` | 238 | Broker and informant NPC peds and blips |
| Client | `client/org.lua` | 200 | Organisation spots: ox_target zones, NPCs, blips |
| UI | `ui/index.html` | 59 | Phone app shell (tabs) |
| UI | `ui/app.js` | 11129 | Phone app: every tab, dialog and request |
| UI | `ui/app.css` | 1878 | Phone app styles |
| UI | `ui/admin.html` | 145 | Admin panel shell |
| UI | `ui/admin.js` | 9329 | Admin panel: groups, views, drawer, settings editor |
| UI | `ui/admin.css` | 1037 | Admin panel styles |
| Docs | `README.md` | 1614 | Owner's manual, configuration reference, op table |

Lines per area:

| Area | Files | Lines |
|---|---:|---:|
| Platform | 12 | 18218 |
| Config | 3 | 2285 |
| Network | 6 | 7552 |
| Contracts | 8 | 12529 |
| Completion | 9 | 7462 |
| Intel | 5 | 2579 |
| Roleplay | 7 | 2610 |
| Improvements | 9 | 2098 |
| Staff | 16 | 14776 |
| Organisation | 9 | 4327 |
| Client | 6 | 2472 |
| UI | 6 | 23577 |
| Docs | 1 | 1614 |

## Features (every switch, its default, the modules involved)

Every switch below is a settings-catalogue entry (changeable from the panel).
Default is the owner's `config/config.lua` value.

| Feature (panel group) | Switches = default | Modules |
|---|---|---|
| Access | `BlockOffDuty`=true, `HideAppFromBlockedJobs`=true, `WhitelistedView.Enabled`=true, `WhitelistedView.Alerts`=true | identity, app, notify, bridges |
| The app | `App.DefaultInstalled`=false | client/main |
| Rewards | `Sources.cash/bank/dirty/item/weapon.enabled`=true | escrow, app (rewardOptions), contracts |
| Completion | `Completion.KillPhotos`=false, `Completion.RequireObservedDamage`=true, `Completion.RejectLastStand`=true, `Ledger.StorePhotos`=true | completion/death, completion/photo, photos, ledger |
| Handovers | `Kidnap.RequireConscious`=true, `Kidnap.RejectDead`=true, `Kidnap.RejectLastStand`=true, `Kidnap.RequireCoercion`=false, `Kidnap.Coercion.handcuffed`=true, `Kidnap.Coercion.passengerOfHitman`=true, `Kidnap.MeetingPoint`=true, `Kidnap.PlacerConfirms`=false | completion/kidnap, meeting, handover_confirm, missionsteps |
| Stakes | `Penalty.RequireDisclosureOnAccept`=true | contracts, escrow |
| Buyouts | `Bailout.Enabled`=true, `Bailout.BlockWhileIncapacitated`=true | bailout, bridges (/cleanse) |
| Targeting | `Targeting.AllowBrowseAll`=true, `Targeting.AllowNearby`=false, `Targeting.AllowProtectedJobTargets`=true, `Mugshot.Enabled`=true, `Mugshot.RemoveBackground`=false | app (search/browse), identity, mugshot, client/mugshot |
| Law enforcement advisory | `Advisory.Enabled`, `UseDispatch`, `AlwaysAlertTarget`, `OnCreate`, `OnAccept`, `OnLocationTip`, `OnCancel`, `WarnCreator`, `WarnHitman`, `FlagListing` (all true) | notify, projection |
| Messages and calls | `Relay.Enabled`=true, `Relay.AllowMaskedCalls`=true, `Relay.RequireMaskingForAnonymous`=true | comms |
| Anonymity | `Anonymity.AllowAnonymousPlacer`=false, `AllowAnonymousHitman`=false, `ShowOperativeNames`=true, `ShowPlacerOnBoard`=false | projection, contracts, escrow (fee), shared/util |
| Anonymity (whitelisted-job targets) | the same four under `Anonymity.WhitelistedTargets.*` (false/false/true/false) | same |
| Proposals | `Amendments.Enabled`=true | amendments |
| Informant | `InformantsEnabled`=true (master), `Informant.Enabled`=false, `PlacerInformant.Enabled`=false | informant, imp_tips, rp_informant |
| Informant tip | `LocationTip.Enabled`=false, `LocationTip.NotifyTarget`=true | locationtip, imp_tips, client/main (tip blip) |
| Informants (whitelisted-job targets) | `InformantsWhitelistedTargets.Informant/PlacerInformant/LocationTip`=false | informant, locationtip, shared/util |
| Notifications | `Notifications.ParanoidAlert`=true, `Notifications.PushEnabled`=true | notify |
| The clock | `Limits.PauseWhileTargetJailed`=true | contracts, bridges |
| Anti-collusion | `AntiCollusion.BlockSameAccount`=true | contracts, identity |
| Progression | `Progression.Enabled`=true | progression, rp_reputation |
| Audit and debug | `Audit.LogAllActions`=true, `Audit.LogReasonText`=true, `Alerts.ToDiscord`=true, `Debug`=true | audit, alerts, shared/log |
| Staff tools | `Staff.AppPaused`=false, `Staff.DailySummary`=false, `Admin.Enabled`=true (read-only) | freeze, summary, admin, panel |
| Storage | `Database.AllowModeSwitch`=false, `Database.Json.SyncOnFinancialWrite`=true (read-only) | main, storage/* |
| Roleplay: Witness heat | `Roleplay.WitnessHeat.Enabled`=false, `AlwaysAlert`=false, `SendCoords`=true | rp_consequences |
| Roleplay: EMS before re-listing | `Roleplay.EmsRelisting.Enabled`=false, `RequireEMS`=false | rp_consequences, contracts |
| Roleplay: City news | `Roleplay.CityNews.Enabled`=false, `AllTargets`=false, `NameTarget`=false | rp_consequences (lb-phone Birdy) |
| Roleplay: Dirty money payouts | `Roleplay.DirtyPayouts.Enabled`=false | rp_consequences, escrow |
| Roleplay: Proof of intent | `Roleplay.ProofOfIntent.Enabled`=false | rp_intent, escrow |
| Roleplay: Reputation | `Roleplay.Reputation.Enabled`=false | rp_reputation, progression |
| Roleplay: Bodyguards | `Roleplay.Protection.Enabled`=false | rp_protection, app, ui (board Protection tab) |
| Roleplay: Hit on the hitman | `Roleplay.HitOnHitman.Enabled`=false | rp_protection, contracts |
| Roleplay: Rumours and broker | `Roleplay.Rumours.Enabled`=false, `Blip`=false | rp_rumours, rp_places, client/rp_npc |
| Roleplay: Burner phone | `Roleplay.BurnerPhone.Enabled`=false, `ConsumeOnPlace`=false, `ConsumeOnAccept`=false, `RequireToOpen`=true | rp_burner, app |
| Roleplay: Informant in person | `Roleplay.InformantNpc.Enabled`=false, `Blip`=false | rp_informant, rp_places, client/rp_npc |
| Roleplay: Reason quality | `Roleplay.ReasonQuality.Enabled`=false | rp_reason, review |
| Improvements: Tip warning delay / Tip limits (`OnePerHitman`=true, `PriceDoubling`=false) / Hold before a tip / Informant second try / Tip safe zones / Go dark | each `Improvements.<X>.Enabled`=false | imp_tips, informant, locationtip |
| Improvements: Placer record | `Improvements.PlacerRecord.Enabled`=false, `ShowForAnonymous`=false | imp_placer_record, imp_board |
| Improvements: Hitman heat / Tiered board / Contract decay | each `.Enabled`=false | imp_heat / imp_tiers / imp_decay, imp_board |
| Improvements: Proof items / Serial scrubbing / Weekly stats | each `.Enabled`=false | imp_proof / imp_scrub / imp_weekly, imp_staffeco |
| Organisation | `Organisation.Enabled`=false, `RequireJobToAccept`=false, `AcceptNeedsPower`=false, `OnDutyOnly`=false, `DefaultDuty`=true, `SetPrimaryOnHire`=true, `QbxBossFlag`=false, `ApplyAtSignupOnly`=true | server/org/*, client/org |
| Step markers | `StepMarkers.Enabled`=true, `KillScene`=true, `Handover`=true, `Protection`=true | missionsteps, client/missionsteps |
| Body disposal | `Disposal.Enabled`=false | disposal, client/missionsteps |

Choices that act as feature modes (not switches): `Completion.Fulfilment`
('alive' | 'either' | ...), `Completion.PhotoStorage` ('server' | 'host'),
`Reason.Mode`, `Organisation.Funds` ('auto' | 'internal'),
`Organisation.ExternalChanges`, `Roleplay.Rumours.AreaMode`,
`Roleplay.ReasonQuality.LowEffortAction`, `Disposal.OnTimeout`,
`Staff.ReassignStake`.

## Screens

**Phone app** (`ui/index.html`, `ui/app.js`, drawn by `draw()`, tab table at `ui/app.js:10092`):

| Kind | Names |
|---|---|
| Tabs | `board` (Board), `mine` (Mine), `place` (Place), `onme` (On me), `ledger` (Ledger); `thread` (a contract's messages, opened from Mine); `jobview` (the whitelisted-job view, its only screen) |
| Board sub-tabs | `contracts`, `protection` (bodyguards, `viewProtection` `ui/app.js:10886`) |
| Dialogs (`state.dialog.kind`) | `confirm` (default `renderDialog`), `number`, `fields`, `pick`, `choice`, `reward` (reward editor), `sheet` (Edit this contract), `proof` (kill photo) |
| Banners on tabs | hold banner (freeze / app pause / restart hold), invite banner (organisation), call bar, broker panel (rumours) |
| Organisation | none yet: of the 33 `org*` requests only `orgInviteAnswer` has an NUI callback (being added in the parallel step) |

**Admin panel** (`ui/admin.html`, `ui/admin.js`; groups at `ui/admin.js:276`):

| Group | Views |
|---|---|
| Home | `inbox` (filters all / reviews / stuck / alerts), `overview`, `announce` |
| Players | `players`, `pcontracts`, `pmeasures`, `pmoney`, `pplaytime`, `phistory`, `pdiag`, `frozen`, `suspended`, `protected` |
| Contracts | `contracts` (+ the contract drawer: `summary`, `money`, `people`, `notes`, `record`) |
| Target limits | `tldefaults`, `tljobs`, `tlplayer`, `tlcontracts` |
| Game rules | `rules`, `changed`, `history` |
| Hitman organisation | `orgsetup`, `orgroles`, `orgmembers`, `orgapps`, `orgfunds`, `orgaccess`, `orgnotices`, `orgaudit` |
| Boss permissions | `bpmatrix`, `bplimits`, `bpoffice`, `bphistory` |
| Locations | `locations` |
| Logs | `logs`, `alerts` |
| Developer | `health`, `devsettings`, `console`, `tools` |
| Help | `help`, `howto`, `permissions` |

`ui/admin.js:333` keeps `ALIASES` (old view names `settings`, `features`,
`timers`, `money`, `limits`, `targeting`, `reviews`, `stuck`, `actions`,
`diagnostics`, `live`, `frozenlist`): old-name mappings that rule 4 says go;
delete in step 4 (UI clean-up).

**Other NUI**: the camera overlay for verification photos
(`crimson:verificationCamera`, `client/main.lua:1305`), lb-phone gallery save,
the admin page as `ui_page`. In-world: ox_target spots (org, step markers,
disposal), NPC peds (broker, informant, org), blips.

## Config sections (key count)

Leaf key paths per top-level section (lists count as one). 537 in all.

| Section | Keys | Section | Keys | Section | Keys |
|---|---:|---|---:|---|---:|
| Debug | 1 | Database | 7 | Limits | 24 |
| Restart | 2 | Sources | 12 | MaxContractValue | 1 |
| EscrowBlacklist | 8 | Bonus | 1 | Penalty | 4 |
| PendingEscrow | 2 | Bailout | 8 | Completion | 20 |
| Kidnap | 18 | Reason | 5 | Listing | 1 |
| Ledger | 4 | BlockedJobTypes | 4 | BlockedJobNames | 14 |
| BlockOffDuty | 1 | HideAppFromBlockedJobs | 1 | WhitelistedView | 2 |
| Targeting | 9 | Immunity | 5 | Mugshot | 8 |
| App | 1 | Amendments | 4 | Notifications | 8 |
| Relay | 5 | Progression | 4 | AntiCollusion | 1 |
| Alerts | 1 | Anonymity | 11 | InformantsEnabled | 1 |
| Informant | 8 | PlacerInformant | 8 | LocationTip | 8 |
| InformantsWhitelistedTargets | 3 | Advisory | 40 | Admin | 19 |
| Staff | 9 | Roleplay.WitnessHeat | 10 | Roleplay.EmsRelisting | 4 |
| Roleplay.CityNews | 7 | Roleplay.DirtyPayouts | 5 | Roleplay.ProofOfIntent | 3 |
| Roleplay.Reputation | 8 | Roleplay.Protection | 6 | Roleplay.HitOnHitman | 1 |
| Roleplay.Rumours | 13 | Roleplay.BurnerPhone | 5 | Roleplay.InformantNpc | 7 |
| Roleplay.ReasonQuality | 5 | Improvements.TipWarningDelay | 3 | Improvements.TipLimits | 4 |
| Improvements.TipHoldFirst | 2 | Improvements.InformantSecondTry | 2 | Improvements.TipSafeZones | 2 |
| Improvements.GoDark | 4 | Improvements.PlacerRecord | 3 | Improvements.HitmanHeat | 10 |
| Improvements.Tiers | 3 | Improvements.ContractDecay | 6 | Improvements.ProofItems | 4 |
| Improvements.SerialScrub | 1 | Improvements.WeeklyStats | 3 | Organisation | 42 |
| StepMarkers | 4 | Disposal | 16 | Audit | 7 |
| Diagnostics | 1 | RateLimit | 1 | Cooldowns | 52 |

Eleven top-level sections hold a single key (`Debug`, `MaxContractValue`,
`Bonus`, `Listing`, `BlockOffDuty`, `HideAppFromBlockedJobs`, `App`,
`AntiCollusion`, `Alerts`, `InformantsEnabled`, `Diagnostics`, `RateLimit`):
candidates to fold into their area in step 3. `Limits`, `Completion`, `Kidnap`,
`Bailout`, `Database`, `Mugshot` are also extended by lone assignments at the
end of `config/config.lua:816-847` (the "advanced" block), so one section's
keys live in two places in the file.

## Other surfaces

- **Admin ops** by level (core OPS): read 21, moderate 14, write 19, identity 1,
  developer 1; extended: organisation/boss permissions 30
  (`server/org/staff_ops.lua`), disposal 6 (`server/disposal.lua:988-1038`),
  reward 2 (`server/staff_reward.lua:453`), reassign 2
  (`server/staff_reassign.lua:450`).
- **Commands** (`Config.Admin.Commands`): `ch-timeline`, `ch-void`, `ch-stuck`,
  `ch-settle`, `ch-whois`, `ch-contracts`, `ch-diag`, `ch-refresh`,
  `ch-review`, `hitmanadmin` (+ `hitmanadmin-close`), and `cleanse`
  (`Config.Bailout.Command`). Registered at `server/bridges.lua:1131`, `:1522`,
  `:1919`, `client/admin.lua:121`.
- **ACEs**: `crimson.admin`, `crimson.identity`, `crimson.developer`,
  `crimson.moderator`, extra read ACE `command` (`Config.Admin`); checked at
  `server/admin.lua:108-121`, `server/panel.lua:344`.
- **Tick jobs** (`server/main.lua` `Tick`, `job()` / `every()`): 43, among them
  audit.flush, amendments.expire, bailout.processQueue, freeze.restartTick,
  freeze.syncAppPause, sanctions.tick, target_limits.prune, summary.tick,
  imp_weekly.tick, thresholds.sweep, rp.tick, rp_intent.sweep,
  rp_protection.sweep, disposal.tick, mission_steps.tick,
  informant.retryUnsaved, escrow.retryWaiting, notify.deliverKept, photo.sweep,
  photo.loadAllowedHosts, death.sweep, ratelimit.sweep, storage.prune,
  ledger.forgetOldPhotos, photos.expire, photos.forgetKept,
  bridges.refreshAccess, rp_places.announce, imp_board.tick, imp_decay.tick,
  app.sweepHandles, app.sweepFloodCounters, and the contract retries
  (finishEndings, releaseIdleHolds, retryStuckClaims/Creates/Joins), review
  decide/retryUnwritten, playtime.pass, storage flush/heartbeat,
  expireContracts. Full list in `tests/inventory/baseline.lua` (`tick:`).

## Third-party integration points

For the adapter step (rule 8). Every call into another resource. "guarded"
means the call site checks `GetResourceState` and/or wraps in `pcall`.

| Resource | Kind | What | Where |
|---|---|---|---|
| **qbx_core** (framework) | exports | `GetPlayer` | `server/identity.lua:218`, `:231`, `:640`, `:789`; `server/completion/kidnap.lua:85`; `server/org/jobs.lua:171` |
| | | `GetPlayerByCitizenId` | `server/identity.lua:619`; `server/escrow.lua:275`, `:2087`; `server/completion/death.lua:838`; `shared/util.lua:811` |
| | | `GetOfflinePlayer` | `server/identity.lua:675` |
| | | `GetJob` | `server/identity.lua:338` |
| | | `GetMetadata` (isdead, inlaststand) | `server/identity.lua:776`, `:779` |
| | | `GetMoney` / `AddMoney` / `RemoveMoney` / `Save` | `shared/util.lua:822`, `:922`, `:868`, `:795`; `server/escrow.lua:278`; `server/org/init.lua:1680` |
| | | `CreateJobs`, `UpsertJobData`, `UpsertJobGrade`, `RemoveJobGrade`, `AddPlayerToJob`, `SetPlayerPrimaryJob`, `RemovePlayerFromJob` (through `core()`) | `server/org/jobs.lua:70`, calls at `:108`, `:122`, `:130`, `:132`, `:146`, `:149`, `:156` |
| | events | `QBCore:Server:PlayerLoaded`, `qbx_core:server:playerLoaded`, `QBCore:Server:OnJobUpdate`, `qbx_core:server:onSetJob`, `qbx_core:server:onGroupUpdate`, `QBCore:Server:SetDuty`, `QBCore:Server:OnPlayerUnload`, `qbx_core:server:playerLoggedOut`, `qbx_core:server:onSetMetaData`; net `QBCore:Server:OnPlayerLoaded` | `server/bridges.lua:406`, `:439`, `:478-479`, `:677-688`, `:794-797` |
| | client | `@qbx_core/modules/playerdata.lua` (QBX.PlayerData); `QBCore:Client:OnPlayerUnload`, `qbx_core:client:playerLoggedOut` | `fxmanifest.lua`; `client/main.lua:936`, `:799-800`, `:880-881`, `:1173-1174`; `client/missionsteps.lua:205`; `client/org.lua:193`; `client/rp_npc.lua:231` |
| **ox_inventory** (inventory) | exports | `GetItem`, `GetItemCount`, `Search`, `AddItem`, `RemoveItem`, `CanCarryItem`, `GetInventoryItems`, `GetInventory` | `server/escrow.lua:456`, `:530`, `:538`, `:615`, `:793`, `:799`, `:881-889`, `:975-985`, `:1931`, `:1934`, `:2208`, `:2219`; `server/app.lua:1065`, `:2073`, `:2076`; `server/rp_burner.lua:65`, `:117`; `server/imp_proof.lua:95`, `:113`, `:186`; `server/completion/death.lua:1092` |
| **lb-phone** (phone) | server exports | `GetEquippedPhoneNumber`, `SendNotification`, `ContainsBlacklistedWord`, `IsInCall`, `EndCall`, `GetConfig`, `PostBirdy`, call export probed via `resolveExport` | `server/notify.lua:139`, `:190`; `server/escrow.lua:389`; `server/photos.lua:606`, `:757`; `server/comms.lua:30`, `:443`, `:541`, `:550`, `:577`, `:684`, `:706`; `server/contracts.lua:1000`; `server/completion/photo.lua:135`; `server/rp_consequences.lua:528` |
| | client exports | `AddCustomApp`, `RemoveCustomApp` / `DeleteCustomApp` / `UninstallApp` (tried in turn), `SendCustomAppMessage`, `SendNotification`, `SaveToGallery`, `EnableWalkableCam`, `DisableWalkableCam`, `SetCameraComponent` | `client/main.lua:117`, `:141`, `:490`, `:516`, `:538`, `:560`, `:573`, `:903`, `:1282`, `:1284`, `:1478` |
| | events | `lb-phone:deletedFromGallery`, `lb-phone:factoryReset` | `server/bridges.lua:808`, `:813` |
| **sc-dispatch** (dispatch) | exports | `AddNotification`, `ClearNotification` | `server/notify.lua:1698`, `:1739`, `:1791`, `:1879`; `server/imp_heat.lua:230`; `server/rp_consequences.lua:342` |
| **sc-ambulance** (ambulance) | exports via `Config.Completion.DeathStateProviders` | `IsDead`, `IsLaststand` | `server/identity.lua:753-754`; `client/main.lua:961` |
| | net event | `sc-ambulance:server:UseDefib` (listened) | `server/bridges.lua:348` |
| **qbx_medical** (ambulance) | metadata only | isdead / inlaststand via qbx_core | `server/identity.lua:776-779` |
| **Renewed-Banking** (banking) | exports | `CreateJobAccount`, `getAccountMoney`, `handleTransaction`, `addAccountMoney`, `removeAccountMoney` | `server/org/funds.lua:188`, `:200`, `:251`, `:293`, `:364`, `:377`, `:426`, `:438`, `:444`; state `server/org/jobs.lua:235` |
| **sc-blackmarket** (progression) | export via `Config.Progression.Resource` | `AddTrust` | `server/progression.lua:84` |
| **qbx_vehiclekeys** (keys) | export | `GiveKeys` | `server/disposal.lua:358` |
| **ox_target** (target) | client exports | `addSphereZone`, `addLocalEntity`, `removeZone`, `removeLocalEntity` | `client/org.lua:41`, `:51`, `:73`, `:109`; `client/missionsteps.lua:68`, `:126` |
| **MugShotBase64** (headshots) | client export | `GetMugShotBase64` | `client/mugshot.lua:53`; state `server/mugshot.lua:98` |
| **oxmysql** (database) | `@oxmysql/lib/MySQL.lua` | all SQL | `fxmanifest.lua`; `server/storage/mysql.lua`; `server/playtime.lua:173` |
| **txAdmin** (restarts) | events | `txAdmin:events:scheduledRestart`, `...Skipped`, `skippedNextScheduledRestart` | `server/bridges.lua:388-396` |
| Configurable | exports | `Config.Kidnap.RestraintProvider` (`IsRestrained`), `Config.Immunity.PlaytimeProvider`, `Config.Relay.CallExport` | `server/completion/kidnap.lua:103`; `server/identity.lua:141`; `server/comms.lua:619` |
| Discord | HTTP | alert webhook, audit webhook, weekly stats | `server/alerts.lua:391`, `:632`; `server/audit.lua:260`; `server/imp_weekly.lua:181` |
| chat | client event | `chat:addMessage` | `server/bridges.lua:1699` |

Not used at all: ox_lib (no `lib.*` anywhere). Hard dependencies in the
manifest: `qbx_core`, `ox_inventory` (+ oxmysql loaded in every mode).

---

## OVERLAPS

Each entry: the copies (file:line), then **MERGE**: the umbrella it goes to,
what gets deleted, risk.

### A. Repeated helper families

1. **Player position from the server ped** (`pcall(GetEntityCoords(GetPlayerPed(src)))` + finite check):
   `server/rp_places.lua:128` (`Places.coordsOf`, the shared one),
   `server/locationtip.lua:104` (`positionOf`), `server/rp_consequences.lua:182`
   (`coordsOf`), `server/imp_proof.lua:79` (`coordsOf`),
   `server/rp_protection.lua:230` (`standing`), `server/identity.lua:481`,
   `server/org/init.lua:504`, `:687`, `server/rp_reputation.lua:47`, `:62`,
   `server/missionsteps.lua:352`; unguarded in `server/completion/death.lua:543`,
   `:786`, `:885`, `:1103`, `:1138`, `:1173`, `server/completion/photo.lua:355`,
   `:384`, `server/completion/kidnap.lua:173-180`.
   **MERGE** into `Geo.position(src)` in the step-2 shared library; delete the
   seven local copies. Risk: low (pure read); the unguarded calls in
   completion gain a pcall, which only changes a throw into a refusal.
2. **Distance / "within N metres"**: `shared/util.lua:84` (`Util.dist2`) and
   `Util.dist`, `server/completion/kidnap.lua:52` and `server/meeting.lua:159`
   (`metres`), `server/rp_places.lua:142` (`Places.near`),
   `server/rp_rumours.lua:244` (`nearby`), `server/app.lua:270`
   (`nearbyNameable`). **MERGE** into `Geo.near(a, b, metres)` +
   `Geo.dist2`; delete `metres` x2 and `Places.near`. Risk: low.
3. **Place / zone text parsing** (`'x, y, z, heading'`, `'x, y, radius, name'`,
   `'x, y, name'`): `server/rp_places.lua:46`/`:62`/`:82` (`numbers`,
   `parsePoint`, `parseArea`), `server/imp_tips.lua:132` (`ImpTips.parseZone`),
   `server/rp_rumours.lua:118` (`nearestDistrict`), finite checks
   `server/meeting.lua:95`, `server/disposal.lua:160`,
   `server/missionsteps.lua:101`, `client/missionsteps.lua:57` (`Finite` x3),
   `server/org/init.lua:1736`, `:1783`, `client/org.lua:170`,
   `client/rp_npc.lua:136`; settings kind `point` at `server/settings.lua:2055`.
   **MERGE** into `Geo.parsePoint/parseArea/finite` (one grammar for every
   place); delete `ImpTips.parseZone`, the `Finite` copies. Risk: medium (a
   zone string accepted today must still parse: test with the shipped values).
4. **Feature block readers** (`rules()` / `cfg()` / `enabled()` / `on()` /
   `fits` / `says` / `describe` on `Config.Roleplay.X` or
   `Config.Improvements.X`): three "shared helper" modules for one idea,
   `server/rp_places.lua:33-42`, `:223`, `:231`, `:267`, `:289`;
   `server/imp_board.lua:37`, `:87`; `server/imp_staffeco.lua:24`, `:34`,
   `:41`, `:58`; plus local copies `server/imp_tips.lua:140`, `:161`, `:217`,
   `:224`; `server/rp_consequences.lua:69`, `:111`; `rules()` in
   `server/imp_decay.lua:78`, `imp_heat.lua:45`, `imp_placer_record.lua:42`,
   `imp_proof.lua:46`, `imp_tiers.lua:21`, `rp_burner.lua:32`,
   `rp_reason.lua:25`, `rp_rumours.lua:44`; `cfg()` in `rp_intent.lua:38`,
   `rp_protection.lua:78`, `rp_reputation.lua:24`; `enabled()` in 17 modules
   (`mugshot.lua:55`, `rp_reason.lua:21`, `rp_protection.lua:82`,
   `org/init.lua:117`, `rp_burner.lua:28`, `rp_informant.lua:24`,
   `imp_staffeco.lua:24`, `locationtip.lua:67`, `rp_places.lua:42`,
   `imp_scrub.lua:135`, `rp_rumours.lua:40`, `meeting.lua:78`,
   `rp_intent.lua:45`, `imp_tips.lua:224`, `disposal.lua:90`,
   `imp_proof.lua:42`, `missionsteps.lua:74`). **MERGE** into one
   `Feature.block(path)`, `Feature.on(path)`, `Feature.check(path, rules)` in
   the shared library; delete `imp_staffeco.lua` entirely and the
   block-reading half of `imp_board.lua` and `rp_places.lua`. Risk: low-medium
   (start-up warnings each module prints must keep their words).
5. **Online player by citizen id**: `server/identity.lua:619`,
   `server/escrow.lua:275`, `:2087`, `server/completion/death.lua:838`,
   `shared/util.lua:811`. **MERGE** into `Identity.online(cid)` (framework
   adapter); delete the direct calls. Risk: low.
6. **Text sanitising / clamps**: `Util.sanitizeText` (used by 19 modules);
   `cleanReason` x3 `server/freeze.lua:429`, `server/payments.lua:47`,
   `server/sanctions.lua:188`; `str(v, max)` x3 `server/disposal.lua:983`,
   `server/org/boss_ops.lua:42`, `server/org/staff_ops.lua:63`;
   `server/org/init.lua:943` (`cleanName`), `server/rp_consequences.lua:250`
   (`clean`), `server/alerts.lua:102` (`cut`), `server/bridges.lua:977`
   (`plain`). **MERGE** into `Text.reason`, `Text.field(v, max)` over
   `Util.sanitizeText`; delete the 9 local copies. Risk: low (byte limits
   must stay identical).
7. **One-at-a-time per key (locks / serialisers)**: `oneAtATime`
   `server/freeze.lua:71`, `server/sanctions.lua:197`, `server/settings.lua:2321`;
   `Serial` `server/targetlimits.lua:508`; `inFlight` tables
   `server/freeze.lua:61`, `server/sanctions.lua:46`, `server/payments.lua:27`,
   `server/escrow.lua:45`, `server/org/funds.lua:54`; `busy` tables
   `server/contracts.lua:175`, `server/review.lua:117`,
   `server/rp_protection.lua:67`; `guarded` `server/escrow.lua:833`.
   **MERGE** into `Lock.run(key, fn, ...)` (busy answer + release in
   `finally`); delete the four named helpers and fold the tables. Risk:
   medium: money paths (escrow, funds); move them last, with the
   race specs (`races_spec`, `interleave_spec`) as the gate.
8. **Money charge and refund**: `Util.charge`/`Util.credit`
   (`shared/util.lua`) called from 21 sites (bailout `:346`, `:349`, `:433`,
   `:785`; contracts `:1436`, `:2111`, `:4109`; escrow `:878`, `:2141`;
   informant `:215`, `:414`, `:665`; locationtip `:247`, `:366`; imp_tips
   `:556`, `:628`; rp_protection `:277`, `:604`; org/init `:1592`, `:1596`,
   `:1629`); local refund copies `server/informant.lua:210` and
   `server/locationtip.lua:245` (`refund`), `server/imp_tips.lua:551`
   (`refundDark`), `server/bailout.lua:827` (`refundBuyout`),
   `server/rp_protection.lua:194` (`refundOwed`); "leave it for staff" x3
   `server/bailout.lua:30`, `server/escrow.lua:283`,
   `server/rp_protection.lua:156` (`leaveForStaff`).
   **MERGE** into `Money.chargeFor(actor, cost, account, why)` returning a
   refund closure, plus one `Money.leaveForStaff`; delete the five refund
   copies and two of the three `leaveForStaff`. Risk: high (money): keep
   audit action names identical (inventory `audit:` items), gate on
   `money_paths_spec`, `conservation_spec`.
9. **Rate limits and budgets**: token buckets `server/ratelimit.lua`
   (Config.Cooldowns, 52 keys); flood counters `server/app.lua:223`
   (`App.floodOk`, swept by `app.sweepFloodCounters`); panel per-source limit
   `server/panel.lua:3738`; notification budgets `server/notify.lua:111`
   (`withinBudget`); staff thresholds `server/thresholds.lua:61`; org day caps
   `server/org/init.lua:539`/`:547` (`within`, `recent`). **MERGE** the
   counting into `RateLimit` (buckets + sliding windows), keep each caller's
   numbers; delete `withinBudget`, `within/recent`, `App.floodOk`'s own
   table. Risk: medium (`ratelimit_budget_spec`).
10. **Per-day / per-week counters**: `server/contracts.lua:582-652`
    (MaxContractsPerTargetPerDay/Week counted by walking contracts),
    `server/targetlimits.lua:63` (`DAY`, `WEEK`), org
    `PromotionsPerDay`/`BonusPerDay`/`WithdrawPerDay`
    (`server/org/init.lua:807`, `:1621`, `:1674`), `Staff.AlertTargetPerDay`
    (`server/thresholds.lua`), day keys `server/summary.lua:56`,
    `server/imp_weekly.lua:71-87`, `server/storage/json.lua:166`.
    **MERGE** into the windowed counter of item 9 (`RateLimit.window(key,
    seconds)`) and one `Clock.dayKey/weekStart`; risk low.
11. **Time bands and clock rounding**: `Util.timeBand`, `Util.bandLeft`,
    `Util.runLeft`, `Util.bandRank`, `Util.roundClock` (`shared/util.lua`),
    used in `server/contracts.lua:1372-1547`, `server/amendments.lua:724`,
    `server/freeze.lua:365`; display copies `hoursText` `server/admin.lua:2180`
    and `server/panel.lua:2127`; `waitWords` `server/bridges.lua:1621`,
    `server/notify.lua:1250`; `dollars` `server/bridges.lua:1630`,
    `server/notify.lua:1220` (beside `Util.dollars`). **MERGE** the words into
    `Words.hours/wait/dollars` in the shared library; delete the four local
    copies. Risk: low (exact strings are asserted by specs).
12. **Notifying the parties of a contract**: `server/freeze.lua:412`
    (`tellParties` + inner `tell`), `server/admin.lua:1265`
    (`tellDeadlineMoved` + inner `tell(cid, named)`, the same shape),
    `server/staff_reward.lua:175`, `server/meeting.lua:205`,
    `server/amendments.lua:55`/`:1376`, `server/bailout.lua:490`, `:521`,
    `server/completion/kidnap.lua:400`; `partiesOf` x2
    `server/meeting.lua:228`, `server/rp_consequences.lua:272`; `hitmenOf` x4.
    **MERGE** into `Notify.parties(contract, text, {skip, named})` with
    anonymity applied once; delete the per-module tell loops. Risk: medium
    (anonymity: the `anonymity_spec` is the gate).
13. **Discord posting**: `server/alerts.lua:612` (`Alerts.post`, convars at
    `:304-306`), its own second sender `:632`; `server/audit.lua:231`/`:260`
    (own webhook + own `PerformHttpRequest`); `server/imp_weekly.lua:153`/`:181`
    (own convar, own request); `server/summary.lua:138` already uses
    `Alerts.post`. **MERGE** into one `Discord.post(channel, content)`; delete
    the audit and weekly senders. Risk: low.
14. **Safe calls into other resources**: `server/comms.lua:575`
    (`resolveExport`), `server/org/jobs.lua:66` (`core`), `client/org.lua:34`
    (`targetUp`), `client/missionsteps.lua:63` (`TargetUp`),
    `client/main.lua:956` (`medicalRunning`), and ~40 inline
    `GetResourceState(...) == 'started'` + `pcall(function() return
    exports[...] end)` (list in "Third-party integration points").
    **MERGE** into one `Bridge.call(resource, export, ...)` + per-resource
    adapters in step 5; delete the inline checks. Risk: low.
15. **In-memory cache over store rows** (`load` / `keep` / `forget` / `prune`
    with `pcall(Storage.writeRpRow...)`): `server/alerts.lua:137`, `:156`,
    `:196`; `server/escrow.lua:145`; `server/imp_decay.lua:84-97`;
    `server/imp_heat.lua:53`, `:68`; `server/imp_tips.lua:240` (13 rp-row
    calls); `server/locationtip.lua:162`; `server/review.lua:152`, `:159`;
    `server/rp_consequences.lua:378`, `:392`; `server/rp_intent.lua:79`;
    `server/rp_protection.lua:107`, `:122`; `server/staffcontract.lua:48`,
    `:59`; `server/org/init.lua:147-180`. **MERGE** into `RowCache.new(kind,
    {key, prune})`; delete the per-module load/keep/forget. Risk: medium
    (restart recovery: `restart_spec`).
16. **Player cleanup on leave**: `clearPlayer`/`clearContract`/`forget` in
    16 modules (`server/mugshot.lua:248`, `server/comms.lua:83`, `:101`,
    `server/locationtip.lua:589`, `server/completion/death.lua:1454`, `:1699`,
    `server/completion/photo.lua:825`, `:843`,
    `server/completion/kidnap.lua:969`, `:1016`, `server/notify.lua:1806`,
    `:1822`, `server/meeting.lua:360`, `server/informant.lua:769`, `:825`,
    `server/missionsteps.lua:279`), each called from `server/bridges.lua`.
    **MERGE** into one `Lifecycle.onLeave(fn)` registry that bridges.lua
    fires; delete the hand-written fan-out. Risk: low.
17. **Client: logged-in check, NPC spawn/remove, blips**: `loggedIn`
    `client/main.lua:1070`, `client/org.lua:113`, `client/rp_npc.lua:75`;
    `spawn` `client/org.lua:91`, `client/rp_npc.lua:95`; `removePed`
    `client/org.lua:38`, `client/rp_npc.lua:46`; blips `client/org.lua:81`,
    `client/rp_npc.lua:120`, `client/missionsteps.lua:156-161`; GPS
    `client/main.lua:765`, `:850`, `:862`. **MERGE** into `CrimsonMarkers`
    (blips, GPS) and a small `CrimsonNpc` (spawn/remove/logged-in); delete the
    copies in org.lua and rp_npc.lua. Risk: low (client only, no money).
18. **Panel op glue**: `staffOf` x3 `server/panel.lua:326`,
    `server/staff_reassign.lua:335`, `server/staff_reward.lua:337`; `said` x2
    `server/org/staff_ops.lua:46`, `server/staff_reassign.lua:316`; `opPreview`
    x2 `server/staff_reassign.lua:357`, `server/staff_reward.lua:382`;
    `answer` x4 `client/admin.lua:181`, `server/bridges.lua:1696`,
    `server/org/boss_ops.lua:27`, `server/panel.lua:3690`. **MERGE** into
    `Panel.staff(src)`, `Panel.said(...)`, `Panel.previewOp(fn)`; delete the
    copies. Risk: low.
19. **Phone text filter**: `phoneRefuses` x2 `server/comms.lua:28`,
    `server/contracts.lua:998` (both lb-phone `ContainsBlacklistedWord`).
    **MERGE** into the lb-phone adapter; delete one. Risk: low.
20. **Police job lists**: `policeJobs` x2 `server/imp_heat.lua:162`,
    `server/rp_consequences.lua:261`, beside `Advisory.RecipientJobTypes/Names`.
    **MERGE** into `Jobs.police()` read from one config list; delete both.
    Risk: low.

### B. Several systems for one idea

1. **Informants, tips, rumours, broker** (10 config blocks, 5 server modules):
   `server/informant.lua` (target's + placer's informant), `server/locationtip.lua`
   (tip), `server/imp_tips.lua` (six tip rules incl. Go dark),
   `server/rp_informant.lua` (informant NPC), `server/rp_rumours.lua`
   (rumours + broker), `client/rp_npc.lua`; config `InformantsEnabled`,
   `Informant`, `PlacerInformant`, `LocationTip`, `InformantsWhitelistedTargets`,
   `Improvements.TipWarningDelay/TipLimits/TipHoldFirst/InformantSecondTry/TipSafeZones/GoDark`,
   `Roleplay.InformantNpc`, `Roleplay.Rumours`. Copies inside it: `refund`
   x2, `boughtBy` x2 (`informant.lua:547`, `locationtip.lua:139`), `stillOn`
   x2 (`informant.lua:199`, `locationtip.lua:172`).
   **MERGE** into one **Intel** umbrella (`server/intel/`): one purchase
   engine (price, account, cooldown, refund, audit) with three products
   (name a hitman, name a placer, rough area), rules as options of the
   engine (warning delay, limits, hold first, second try, safe zones), the
   "where you buy it" as one option (`app` | `npc` | `broker`), Go dark as a
   counter-product. Config: `Config.Intel = { Enabled, Products = {...},
   Rules = {...}, InPerson = {...}, Rumours = {...}, WhitelistedTargets =
   {...} }`. Deleted: `InformantsEnabled`, `InformantsWhitelistedTargets`,
   six `Improvements.Tip*` blocks, `rp_informant.lua`, the tip half of
   `imp_tips.lua`, both `refund` copies. One admin screen "Intel".
   Risk: high (money + anonymity); largest single merge; do it alone.
2. **Holds: freeze, pause, restart, jail, logoff**: `server/freeze.lua`
   (staff freeze `:332-381`, app pause `:814-915`, restart hold `:687`),
   `Config.Restart` + txAdmin events `server/bridges.lua:388`, jail pause
   `server/contracts.lua:3244` (`Limits.PauseWhileTargetJailed`), logoff
   pause `server/main.lua:2504`, `:3335`, `:3414`, kill hold over restart
   `server/completion/death.lua:1393`, `:1423`; all end in
   `Storage.startPause`. **MERGE** into one **Hold** service:
   `Hold.start(scope, reason, until)` with scopes contract / player / app and
   reasons staff / restart / jail / offline; one banner on the phone (already
   one: `holdBanner`), one admin list. Deleted: the three start/end pairs in
   freeze.lua, `Staff.AppPaused` becomes `Hold` scope app, `Config.Restart`
   moves under `Config.Holds`. Risk: medium (clocks; `freeze_spec`,
   `clock_spec`, `restart_spec`).
3. **Payout conditions (proof before pay)**: `Completion.KillPhotos` +
   Verify kill (`server/completion/photo.lua`), `Improvements.ProofItems`
   (`server/imp_proof.lua`), `Roleplay.ProofOfIntent` (`server/rp_intent.lua`),
   `Disposal` (`server/disposal.lua`), `Kidnap.PlacerConfirms`
   (`server/handover_confirm.lua`), `Roleplay.EmsRelisting`. **MERGE** into
   a **Payout checks** umbrella: an ordered list of checks a completion must
   pass (photo | item | intent | disposal | placer confirm), each with its
   own settings; one place that holds the payout (`rp_intent`'s hold).
   Deleted: the per-feature hold/release plumbing. Risk: high (money).
4. **Markers and map points**: `client/missionsteps.lua` (`CrimsonMarkers`,
   already the umbrella for step markers), meeting blips (`client/main.lua:784`,
   events `meetingBlip/meetingBlipClear`), tip blip (`client/main.lua:825`,
   events `locationTip/locationTipClear`), org spot blips (`client/org.lua:81`),
   NPC blips (`client/rp_npc.lua:120`), three GPS callbacks
   (`crimson:meetingGps`, `crimson:protectionGps`, `crimson:tipGps`).
   **MERGE** every blip, zone and GPS into `CrimsonMarkers` with one net event
   pair (`StepMarker`/`StepMarkerClear`) and one `crimson:gps` callback.
   Deleted: 4 net events, 2 NUI callbacks, blip code in org.lua/rp_npc.lua.
   Risk: low.
5. **Locations (where things are)**: broker and informant places
   (`Roleplay.Rumours.Locations`, `Roleplay.InformantNpc.Locations`, parsed in
   `server/rp_places.lua`), rumour districts/zones (`Roleplay.Rumours.Districts`,
   `.Zones`), tip safe zones (`Improvements.TipSafeZones.Zones`), org spots
   (DB table, `server/org/init.lua:1783`, ops `orgLocationSet/Remove`,
   `orgMyPosition`), disposal spots (ops `disposalSpotSet/Clear`,
   `disposalMyPosition`, config `Disposal.VehicleSpawn/DropOff`), meeting
   point (player-set), admin `locations` view. **MERGE** into one
   **Places** registry (kind, id, coords, radius, blip, enabled) stored once,
   edited on the `locations` view, with "use my position" as one op.
   Deleted: `orgMyPosition`/`disposalMyPosition` (one op), the three config
   place lists (become seeded rows), duplicate parsers. Risk: medium.
6. **Staff measures on a player**: freeze (`server/freeze.lua`, ops
   `freeze/unfreeze/frozen`), suspend and protect (`server/sanctions.lua`,
   ops `suspend/unsuspend/protect/unprotect/sanctions`), target-limit
   overrides (`server/targetlimits.lua:535`, ops `targetOverride`,
   `targetReset`, `targetExtend`, `targetCounts`), new-player immunity
   (`Config.Immunity`, playtime), org member suspend (`orgMemberSuspend`,
   `orgSuspend`); views `frozen`, `suspended`, `protected`, `pmeasures`,
   `tlplayer`. Shared copies: `cleanReason` x3, `oneAtATime` x2, `recount` x2
   (`freeze.lua:63`, `sanctions.lua:61`), `inFlight` x2. **MERGE** into one
   **Measures** module: `Measures.apply(cid, kind, hours, reason)` with kinds
   freeze / suspend / protect / limit-override, one list op, one view (the
   player's `pmeasures` + a server-wide list). Deleted: `frozen`,
   `suspended`, `protected` views and the `sanctions`/`frozen` list ops (one
   `measures` op), duplicated reason/lock code. Risk: medium (freeze moves
   clocks; keep audit names).
7. **Anonymity switches**: `Anonymity.*` (4) and
   `Anonymity.WhitelistedTargets.*` (4), `Relay.RequireMaskingForAnonymous`,
   `Improvements.PlacerRecord.ShowForAnonymous`,
   `Improvements.SerialScrub` (anonymous placers' weapons), anonymity fee in
   escrow; readers `Util.anonymityAllowed`, `Util.operativeNamesShown`,
   `Util.placerShownOnBoard`. **MERGE** into `Config.Anonymity = { Placer,
   Hitman, ShowOperativeNames, ShowPlacerOnBoard, Fee, MaskCalls,
   ScrubSerials, PlacerRecord, ByTarget = { whitelisted = {...} } }`; one
   reader `Anonymity.rule(name, target)`. Deleted: the eight placer/hitman
   switches become one table per target class; `Relay.RequireMaskingForAnonymous`
   and `ShowForAnonymous` move in. Risk: medium
   (`anonymity_spec`).
8. **Per-target-class overrides** ("whitelisted-job targets"):
   `Anonymity.WhitelistedTargets`, `InformantsWhitelistedTargets`,
   `Targeting.AllowProtectedJobTargets`, `WhitelistedView`, `Immunity`
   job rules, target limits per job (`tljobs`). **MERGE** into one
   `TargetClasses = { whitelisted = { jobs, anonymity, intel, targetable,
   limits } }`; Risk: medium. Do it with B7.
9. **Police-facing output**: LEO advisory (`server/notify.lua:1698`, `:1739`,
   `:1791`, `:1879`, 40 `Advisory` keys), witness heat
   (`server/rp_consequences.lua:342`), hitman heat bulletins
   (`server/imp_heat.lua:230`), whitelisted-view alerts
   (`server/notify.lua:581`), City news (`server/rp_consequences.lua:528`).
   **MERGE** into a **Police & press** umbrella over one dispatch adapter;
   one place for "which jobs are told" (now `Advisory.Recipient*` +
   `policeJobs` x2). Risk: low-medium.
10. **Standing / record of a player**: progression trust
    (`server/progression.lua`), reputation (`server/rp_reputation.lua`), heat
    (`server/imp_heat.lua`), tiers (`server/imp_tiers.lua`, level from
    completions), placer record (`server/imp_placer_record.lua`), ledger
    (`server/ledger.lua`), weekly stats (`server/imp_weekly.lua`), history
    card (`server/history.lua`). **MERGE** into a **Record** umbrella
    (one per-citizen record: completions, level, trust, heat, placer stats)
    that tiers/placer record/history/weekly read. Risk: medium.
11. **Staff money tools**: manual pay (`server/payments.lua`, op `manualPay`),
    settle (`settle`, `/ch-settle`), review resolve (`resolve`), reward
    change (`server/staff_reward.lua`), org funds move/bonus
    (`orgFundsMove`). **MERGE** the confirm/reason/cap/audit shell into one
    `StaffMoney.run(kind, ...)`; ops stay (they are the capabilities).
    Risk: high (money), low payoff: last.
12. **Shared-helper modules**: `server/imp_board.lua`,
    `server/imp_staffeco.lua`, `server/rp_places.lua` each "the shared
    helpers" of a feature group (see A4). The `rp_*`/`imp_*` split itself is
    history, not design: features are grouped by when they were added.
    **MERGE**: regroup by area (Intel, Payout checks, Record, Police & press,
    Places) as above; delete `imp_staffeco.lua`, the `Roleplay`/`Improvements`
    config prefixes. Risk: low per move, large rename (rule 4: no aliases).

### C. Duplicated logic

- **Three storage backends** (`server/storage/memory.lua` 2076,
  `json.lua` 3844, `mysql.lua` 3866 lines) implement each operation three
  times (`write*` x3 for 20+ row kinds). `server/org/schema.lua` already shows
  the cure: one table description, three generic drivers. **MERGE** every
  rp/staff row kind onto the schema-driven path; delete the per-kind triplets.
  Risk: high (persistence; `storage_spec`, `differential_spec`). Payoff:
  several thousand lines.
- **Staff commands vs panel buttons**: every `ch-*` command has a panel
  button doing the same ops (`Panel.COMMANDS`, `server/panel.lua:97`), with
  the command bodies in `server/admin.lua` and the op bodies in
  `server/panel.lua`. Keep both entry points, one implementation each
  (commands call the op). Risk: low.
- **Settings shown in several places**: the catalogue is rendered in `rules`,
  `changed`, `devsettings`, `tldefaults`, `orgsetup`, `bplimits`
  (`CATEGORY_VIEW`, `ui/admin.js:344`). Fine as views of one catalogue; the
  overlap is the four category->view tables in admin.js. Risk: low.
- **Config written twice**: `config/defaults.lua` mirrors `config/config.lua`
  key for key (held by `config_drift_spec`); `server/main.lua:31-432` (`DEFAULTS`) holds a
  third copy of many defaults, for keys added after a section existed. **MERGE** in step 5: defaults
  once, the owner's config and the buyer's example as overrides; delete the
  copy in main.lua. Risk: medium.

### D. Several screens for one job

1. `frozen`, `suspended`, `protected` (server-wide lists) vs `pmeasures`
   (the same measures for one player) vs `tlplayer` (target-limit override
   for one player) -> one Measures list + the player's tab (see B6).
2. `contracts` vs `pcontracts` vs `tlcontracts` (contracts on someone) -> one
   contracts list with a person filter.
3. `logs` vs `orgaudit` vs `bphistory` vs `history` (settings changes) vs
   `phistory` -> one Logs view with filters (area, player, org); keep the
   history card as the player's tab.
4. `inbox` (reviews / stuck / alerts) vs `alerts` (Logs group) vs `overview`
   -> alerts once (inbox filter), Logs keeps the audit only.
5. `orgsetup` + `bplimits` + `bpoffice` (organisation settings in three
   places) -> organisation settings in one view; Boss permissions keeps the
   matrix and history.
6. `locations` vs organisation spots (in `orgsetup`) vs disposal spots (in
   the `contracts` view's disposal list, `ui/admin.js:1500`) -> one Places view
   (see B5).
7. Phone: the three Set GPS buttons and their callbacks (meeting, protection,
   tip) -> one (see B4).

### E. Top 10 merge proposals (order for step 3)

| # | Umbrella | Deletes | Risk | Why first |
|---|---|---|---|---|
| 1 | Shared library (A1-A3, A6, A11, A14, A16-A20): `Geo`, `Text`, `Words`, `Bridge.call`, `Lifecycle`, `CrimsonNpc` | ~45 local helper copies | low | step 2; everything else uses it |
| 2 | Feature blocks (A4, B12) | `imp_staffeco.lua`, block code in `imp_board.lua`/`rp_places.lua`, 17 `enabled()` | low | makes every later merge smaller |
| 3 | Markers & GPS (B4, D7) | 4 net events, 2 NUI callbacks, blip code in 2 client files | low | client only |
| 4 | Places registry (B5, D6) | `*MyPosition` op twin, 3 parsers, place lists in config | medium | needed by Intel and Disposal |
| 5 | Measures (B6, D1) | 3 admin views, 2 list ops, `cleanReason`/`oneAtATime`/`recount` copies | medium | staff-facing, simple model |
| 6 | Holds (B2) | 3 pause start/end pairs, `Staff.AppPaused`/`Config.Restart` keys move | medium | one clock rule |
| 7 | Anonymity + target classes (B7, B8) | duplicated `WhitelistedTargets` blocks (anonymity, informants), scattered anonymity keys | medium | many readers, one rule |
| 8 | Intel (B1) | `rp_informant.lua`, 6 `Improvements.Tip*` blocks, `InformantsEnabled`, refund/boughtBy/stillOn copies | high | biggest cluster |
| 9 | Police & press + Discord (B9, A13) | 2 Discord senders, `policeJobs` x2, dispatch call sites into one adapter | low-medium | adapter step needs it |
| 10 | Logs & lists (D2-D4) | `orgaudit`/`bphistory`/`tlcontracts`/`pcontracts` as separate views | low | UI clean-up |

Then, as their own steps: Record (B10), Payout checks (B3), storage schema
(C), money shells (A7-A8, B11) last, behind the money specs.

---

## Capability inventory

Hard rule 5: nothing is lost unless a line says where it went.

- `tests/inventory/extract.lua` reads the resource and lists every
  capability as `category:name`. Categories: `config` (key paths of
  config.lua and defaults.lua), `setting` (settings catalogue keys),
  `op` (admin panel ops), `handler` (phone requests), `netevent.server`,
  `netevent.client`, `event` (local handlers, `side:name`), `nui`,
  `command`, `export`, `ace`, `audit` (action names), `err` (CH.ERR and
  Org.ERR names), `screen` (phone tabs/board tabs/dialogs, admin
  groups/views/drawer tabs/inbox filters), `tick` (tick jobs), `ext` (other
  resources' exports called). Everything is read as text except the two
  the source builds: config is run in an empty sandbox, and the settings
  catalogue is loaded from `server/settings.lua` (part of it is built in
  loops).
- `tests/inventory/baseline.lua` is its output, committed (1951 items at
  `b31d10a`; counts per category are in its header).
- `tests/inventory/moved.lua` lists capabilities that left their old name:
  `['op:freeze'] = 'op:holdPlace'` or
  `['config:Informant.Enabled'] = { to = 'config:Intel.Informant.Enabled', note = '...' }`.
  The target must itself be a current item.
- `tests/capability_inventory_spec.lua` (in `tests/run.lua`, before
  `docs_spec`) fails when a baseline item is neither extracted nor in
  moved.lua, or when a moved.lua target does not exist. New items pass.

**Regenerating.** When a step adds capabilities on purpose, or after a merge
whose moves are recorded in moved.lua:

```
lua5.4 tests/inventory/extract.lua --print   # counts only, writes nothing
lua5.4 tests/inventory/extract.lua           # rewrites tests/inventory/baseline.lua
CH_SUITES=capability_inventory_spec lua5.4 tests/run.lua
```

Run from the repository root. Regenerate only after the spec passes against
the old baseline (so every removal is recorded in moved.lua first); then
moved.lua entries the new baseline no longer needs may be dropped in the same
commit, which keeps the commit's diff of baseline.lua the record of what
moved. Never regenerate to make a failure go away.
