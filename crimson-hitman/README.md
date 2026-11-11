# Crimson Hitman System

A criminal contract board for **QBox**, delivered as an **lb-phone** app
(**Crimson-Hitman**), with a staff panel in game (`/hitmanadmin`). This file
is the owner's manual: how to install, run, configure and support it. How it
is built and tested is in [docs/developer.md](../docs/developer.md); what to
check in game is [docs/in-game-checklist.md](../docs/in-game-checklist.md).

## Install in 5 minutes

1. Copy `crimson-hitman` into your resources folder.
2. Put `ensure crimson-hitman` in `server.cfg`, after `oxmysql`, `qbx_core` and the other scripts you use (`ox_inventory`, `lb-phone`, `ox_target`, ...).
3. Give yourself the panel: `add_ace group.admin crimson.admin allow` in `server.cfg`.
4. Open `config/config.lua`: set `Config.Database.Mode` (`'mysql'` or `'json'`). Everything else can wait.
5. Start the server and type `/hitmanadmin` in game. The **first-start setup** opens: check the other scripts it found, the permissions, the command and the key switches, **Preview**, then **Apply** (two clicks). It opens again from Developer, First-start setup.

Only `qbx_core` (with `oxmysql`) is required; every other script is optional and found on its own (`Config.Integrations`, [Other scripts](#other-scripts)). The full steps are under [Install](#install); what changed is in [CHANGELOG.md](CHANGELOG.md).

## Start here

**What it does.**

1. A player places a **contract** on another player from the phone, naming a **reward**; the money is taken at once and held (escrow).
2. A **hitman** accepts it from the board and finishes it: as shipped by bringing the **target** alive to the **placer** for a live handover (a verified kill can count too, if you allow it).
3. The held reward pays the hitman; a contract that ends any other way hands it back. Nothing is promised that is not held.
4. The target can see contracts on them under **On me** and buy one out; officers are warned when one of them is targeted.
5. Staff watch, freeze, void, pay and tune all of it live from the admin panel, and every money movement is in the audit log.

**The admin panel's sections** (`/hitmanadmin`, see [Admin panel](#admin-panel)), in four groups, with **Help** in its header:

| Group | Section | What you do there |
|---|---|---|
| Daily | **Home** | The inbox (Needs review, Money waiting, open alerts), the overview, Announce |
| Daily | **Players** | Find a player; their contracts, measures (freeze, suspend, protect), money, playtime, history; who is frozen, suspended or protected |
| Daily | **Contracts** | Every contract, searched and filtered; a contract's drawer |
| Daily | **Target limits** | How often one person may be targeted: defaults, per job, per player, contracts on someone |
| Setup | **Game rules** | Every rule by area of the game, its switches first; presets (named bundles of settings); what was changed from the panel; the change history |
| Setup | **Hitman organisation** | The optional hitman job: setup, roles and pay, members, applications, funds and cuts, access, notices, its log |
| Setup | **Boss permissions** | What bosses may do: the matrix, limits, delegation and the office, grant history |
| Setup | **Locations** | Every place the resource uses, set from where you stand |
| Records | **Logs** | The audit log with its search, Alerts & Discord |
| Developer | **Developer** | Health, engine settings, the console, test tools, the first-start setup |

**The roles** (the words used everywhere: see [Glossary](#glossary)):

| Role | Who | Where in the app |
|---|---|---|
| **Placer** | The player who placed the contract and funds it | **Place** to place one; **Mine** to edit, withdraw, message and watch it |
| **Hitman** | A player who accepted it (shown to others as an **operative**, by alias) | **Board** to accept; **Mine** to finish it, message, propose a change or abandon |
| **Target** | The player the contract is on | **On me**: buy out, the informant, a bodyguard |
| **Guard** | A player hired by a target as a bodyguard (roleplay, off as shipped) | **Board**, Protection tab |
| **Officer** | A player on a whitelisted job (police, EMS, as listed) | The whitelisted-job view: contracts on them, and advisories |
| **Staff** | Holders of the panel ACEs ([Permissions](#permissions)) | `/hitmanadmin` and the `/ch-*` commands |

**Where each optional feature is switched on.** Everything below is in the
panel's **Features** section (live, kept across restarts) and in
`config/config.lua` under the same section title.

| Feature | Switch | Shipped |
|---|---|---|
| Anonymity | `Config.TargetClasses.default.AllowAnonymousPlacer`, `AllowAnonymousHitman` (and `Config.TargetClasses.whitelisted`) | off |
| Informants (target's, placer's, the tip) | `Config.Intel.Enabled`, then `Config.Intel.Informant.Enabled`, `Config.Intel.PlacerInformant.Enabled`, `Config.Intel.LocationTip.Enabled`, per target class (`Config.TargetClasses`) | off |
| Law enforcement advisory | `Config.Advisory.Enabled` | on |
| Staff tools (app pause, daily summary, alerts) | `Config.Holds.AppPaused`, `Config.Staff.DailySummary`, `Config.Staff.Alert*`, `Config.Alerts.ToDiscord` | pause and summary off, alerts on |
| Roleplay (12 features) | `Config.Roleplay.<Feature>.Enabled` | all off |
| Improvements (13 features and a cooldown) | `Config.Improvements.<Feature>.Enabled`, `Config.Limits.TargetCooldownAfterCompletionSeconds` | all off |

**Read these settings before you open the server:** `Config.Database.Mode`
(where everything is kept), `Config.Completion.Fulfilment` and
`Config.Kidnap.RequireCoercion` (how a contract is finished),
`Config.BlockedJobTypes` / `BlockedJobNames` and `Config.WhitelistedView` (who
may use the app), `Config.Limits.MaxPayoutSlots` and
`Config.Limits.MinContractReward` (what a contract pays) and `Config.Debug`
(what the console prints).

## Install

`mysql` is the shipped mode (`Config.Database.Mode = 'mysql'`).

1. Put `crimson-hitman` in your resources folder (another folder name works; use it in the `ensure` line).
2. In `server.cfg`, after `oxmysql`, `qbx_core` and the other scripts you use (`ox_inventory`, `lb-phone`, ...): `ensure crimson-hitman`.
3. Grant staff: `add_ace group.admin crimson.admin allow` (more in [Permissions](#permissions)).
4. Optional Discord webhooks, in `server.cfg` with `set`, never `setr` (which sends the value to every player): `set crimson_hitman_webhook "..."` (the audit mirror), `set crimson_hitman_alert_webhook "..."` (alerts and the daily summary), `set crimson_hitman_stats_webhook "..."` (the weekly stats).
5. Check the settings listed in [Start here](#start-here), then start the server. With `Config.Debug = true` (as shipped) the console prints `[crimson-hitman] started in mysql mode` and every warning in full; with it off, a sound start prints nothing and one with settings to look at prints one line pointing to `ch-diag`.
6. Tell players the app is in the phone's **App Store** (each downloads it), or set `Config.App.DefaultInstalled = true` to put it on every eligible phone.

**The database.** The tables are made on the first start (utf8mb4, InnoDB;
MariaDB 10.11 and MySQL 8). Each start creates or alters only what is missing.
A database user without `CREATE`, `ALTER` and `INDEX`: import
`install/sql/crimson_hitman.sql` once, as a user that may, before the first
start; if a later version needs something that user cannot add, the start
stops and prints the `ALTER TABLE` to run. The tables are `crimson_contracts`,
`crimson_escrow`, `crimson_hitmen`, `crimson_amendments`, `crimson_messages`,
`crimson_ledger`, `crimson_pending`, `crimson_stats`, `crimson_audit`,
`crimson_reveals`, `crimson_placer_informants`, `crimson_mutes`,
`crimson_photos`, `crimson_review`, `crimson_settings`, `crimson_alerts`,
`crimson_view_alerts`, `crimson_playtime`, `crimson_location_tips`,
`crimson_freezes`, `crimson_contract_staff`, `crimson_staff_records`,
`crimson_meta` and `crimson_rp_rows` (the roleplay and improvements rows,
each held exclusive contract's idle clocks, and every map spot set in
Locations), and the organisation's
`crimson_orgs`, `crimson_org_roles`, `crimson_org_members`,
`crimson_org_grants`, `crimson_org_funds`,
`crimson_org_splits`, `crimson_org_applications` and `crimson_org_messages` (made on every start,
read and written only with `Config.Organisation.Enabled`). A
start refuses, changing nothing, where a table of one of these names belongs
to another resource. Money columns are `INT` (at most $2,147,483,647; the
start holds every money setting to it), reasons and messages at most 255
characters, times until 2038-01-19.

**`json` mode** keeps everything in files under `crimson-hitman/data/`
(`store.json`, `records.json`, `contracts/`, `audit-<day>.jsonl`,
`playtime.json`, `photos/`) and needs no database; it does not suit thousands
of live contracts. Kill photo files are in `data/photos/` in every mode.

**Dependencies.**

| Resource | Needed | Known to work |
|---|---|---|
| `qbx_core` | Required (manifest dependency) | 1.24.0 |
| `oxmysql` | Required in every mode (the playtime count reads `qbx_core`'s `players` table) | 2.14.3 |
| `lb-phone` | Optional, but the app is an lb-phone app: without it there is no app (notices fall back to the game's feed) | 2.8.0 |
| `ox_inventory` | Optional: item, weapon and dirty-money rewards, burner phones, proof items | 2.48.0 |
| `ox_target` | Optional: third-eye options on step markers and organisation spots | 1.18.1 |
| `Renewed-Banking` | Optional: the organisation's funds in a society account | 2.1.4 |
| `qbx_vehiclekeys` | Optional: keys for the disposal vehicle | |
| MariaDB or MySQL | `mysql` mode | MariaDB 10.11, MySQL 8 |
| `ox_lib` | Through `qbx_core` | 3.40.3 |
| `sc-ambulance` / `qbx_medical` | Optional: death and last-stand state, the defibrillator | |
| `sc-dispatch` | Optional: advisories and bulletins in the MDT | |
| `sc-blackmarket` | Optional: criminal progression, selling the burner phone | |
| `MugShotBase64` | Optional: target headshots | |

Every optional script is reached through an adapter, chosen by
`Config.Integrations` (`'auto'` as shipped picks each one that is started).
One that is missing, or set to `'none'`, turns off only what needs it and
says so in one console line at start. To use another script (another
dispatch, inventory or phone), add an adapter: `docs/dev/adapters.md`.

## Updating

- **Keep `crimson-hitman/data/`** when you put a new version in place (copy the new files over the old folder, or move `data/` out and back). In `json` mode it is the store; in every mode it holds the kill photos. A `json` store that finds an empty `data/` after it has run refuses to start; put the old one back, or `set crimson_hitman_new_store 1` once to start empty on purpose.
- Carry your `config/config.lua` across. Settings changed in the panel are kept in the store and survive the update.
- Payouts an older version left owed appear once under **Money waiting** in the panel's inbox (`/ch-stuck`): check the player has it, then **Pay** or **Delivered**.
- Restarting `qbx_core` or `oxmysql` stops this resource with them: `ensure crimson-hitman` afterwards. Restarting `lb-phone`, `ox_inventory` or any other optional script is safe: what needs it is off while it is down, said in one console line.
- **Moving your settings** to another server or keeping a copy: Developer, **Export & import**, **Export the settings**, then **Copy**. The text holds every setting changed from the panel (never a secret: the webhooks stay in server.cfg) and your own presets. It does not hold the map places (Locations) or the target limits set for a job or a player (Target limits): those belong to one server's map, jobs and characters. On the other server, paste it under Import and **Read it**: every change (from, to), every key refused and why (one the panel never changes, one this version does not have, one read-only, a value it would refuse) and the presets it would add. Nothing changes until **Apply it**, two clicks naming how many changes; each is then an ordinary setting change, audited and in Change history with Undo.
- **Version check** (off as shipped): set `Config.VersionCheck.Enabled = true` and `Config.VersionCheck.Url` to an https address that serves the latest version number (plain text such as `1.3.0`, or JSON with it in). The server asks it once at start, with a plain GET: no body, no headers of its own, and an address with `?` or `#` (or a user name) in it is refused unasked, so nothing about your server is sent. A newer version is one console line; anything else says nothing. With no address (as shipped) nothing is ever asked.

### Escrow, and where the words live

On an escrowed build (FiveM Asset Escrow) everything you edit stays readable
(`escrow_ignore` in `fxmanifest.lua`): `config/`, the language files
(`locales/`), the adapters (`server/adapters/`, `client/adapters/`, see
`docs/dev/adapters.md`). The page files (`ui/`), `install/sql/` and `data/`
are never escrowed, as only Lua is.

**Translations.** The words players and staff read are in language files, by
key. `locales/en.lua` holds the game's and the server's: every notice a
player gets, the police advisories, staff alerts and their Discord posts,
staff notices, the app's name on the phone, the map markers and target
options, every answer and refusal of the admin panel's requests, the staff
commands and the diagnosis (`/ch-diag`, Run the diagnosis), the buyout
command, every feature's refusals and notices, the organisation's, and the
panel's setting labels, help lines and group names. `locales/en.json` holds
the pages': every label, help line, button and dialog of the phone app
(`app`, its tabs included) and of the admin panel (`admin`, its sections
and header included), and both pages' refusals by code (`errors`,
`panel_errors`). `Config.Locale` (`'en'`) names the language.

To add a language (say German, `de`):
1. Copy `locales/en.lua` to `locales/de.lua` and `locales/en.json` to
   `locales/de.json`.
2. In `de.lua`, change `CrimsonLocales.en` to `CrimsonLocales.de` (twice: the
   table and the `return` at the end).
3. Translate the texts on the right. Keep every `%s` and `%d` in its order
   (names, numbers and amounts go there) and the keys on the left as they
   are. Leading spaces and a leading `->` in a diagnosis line are layout:
   keep them.
4. Set `Config.Locale = 'de'` in `config/config.lua` and restart.

A key your file leaves out reads in English, and the console says so once;
you can translate a few screens and leave the rest. The pages show their
texts as plain text: write `&` and `<` as they are.
Console lines stay English, and so do the files that only ever print to the
console (the stores, `server/boot.lua`, `server/versioncheck.lua`). Labels a
server owner sets are in `config/config.lua` (titles of advisories, bulletins
and the city news, the command names).

### Changing storage mode

Modes do not share data. The start refuses to begin in a new mode while the
old one still holds players' money (escrow, payouts owed, a review item, a
payment kept for that mode), and lists up to ten contracts with what each
holds and what clears it: let it finish, the placer withdraws it, staff void
it (`/ch-void`), the player logs in, or `/ch-stuck` and `/ch-settle`; and each
review item (`/ch-review` in the old mode). Switch back, clear them, switch
again. `Config.Database.AllowModeSwitch = true` starts anyway, for money
already settled by hand.

### After a crash, and when the database stops answering

- A crash never charges downtime to a deadline: running contracts are paused for at least as long as the server was down. Claims and endings the crash cut short are finished at the next start, and their parties told.
- Balances move through `qbx_core`'s `Save`; items and dirty money are `ox_inventory`'s, saved every five minutes. After a hard crash, compare the last five minutes of `escrow_*`, `stake_taken` and `pending_delivered` audit rows with what those players carry.
- `mysql`: no statement waits longer than `Config.Database.QueryTimeoutSeconds` (10 s). The console says when the database stopped answering and when it answers again; players are told *The server's records did not answer in time*, and a payment caught in the middle is settled by the server once it answers (kept on the machine meanwhile, restarts included). `/ch-diag` says whether it answers now. Wait; restart only once it says `database: answering`. Back up with `mysqldump --single-transaction`, never `--lock-tables` during play.
- If the staff freezes cannot be read (at the start or later), every live contract is held until they can be: the console says so once and then every five minutes, the read is tried again after a wait that grows to five minutes, the Dashboard's **Frozen** reads *Unknown*, and a held contract's badge reads *store unreadable* (*held* without IdentityAce). The first good read gives every contract back the lifetime the outage took.

## Roles and how a contract works

### Glossary

One word for one thing, on the phone, in the panel, in notices and here.

| Word | Means | Never called |
|---|---|---|
| **contract** | One price on one target, with its reward held in escrow | bounty, job (a bodyguard's is a *protection job*) |
| **placer** | The player who placed a contract. Players read *the person who placed it* | client, creator (in text; `creator` stays in data and code) |
| **hitman** | A player who accepted a contract | contractor |
| **operative** | How a hitman is shown to the placer and the target: an alias (*Operative #1*), or their name if they did not stay anonymous | |
| **target** | The player a contract is on | victim |
| **reward** | What the placer put up: cash, bank, dirty money, items, weapons; paid as one or more **payouts** | pot, bounty |
| **payout** | One collection of the reward by a hitman (`Config.Limits.MaxPayoutSlots`, 1 as shipped) | slot (in text) |
| **stake** | What a placer may ask a hitman to put up on accepting, lost on walking away or running out | penalty (in text) |
| **buyout** | A target paying to close a contract on them | cleanse (that is only the command's name) |
| **on hold** | A contract staff stopped: its clocks stand and nothing on it moves. Staff do it by **freezing** a player | frozen (to players) |
| **paused** | Every contract stopped by the **app pause** (staff) or before a **server restart** | |
| **escrow** | Where a reward is held from placing until the contract ends | |

### A contract, start to finish

1. **Placing** (Place tab): pick the target, give a reason, set the reward (and a stake, a kidnapping bonus or more payouts where allowed); the second tap on **Place** names the total and takes it. The target is not told at once.
2. **Accepting** (Board): the hitman sees the reward, the rough time left and any stake, and accepts (anonymously where allowed). One hitman (**exclusive**) or several (**competitive**).
3. **The clock**: the deadline (3 h as shipped) runs only while the placer, the target and one hitman holding it are all in the city, never while the target is jailed, and stops before a txAdmin restart. Players see a rough band (*More than 2 hours left* … *Under 15 minutes left*), from the deadline or the lifetime, whichever ends first; staff see the exact time. A two-day lifetime ends any contract, pauses included.
4. **Finishing**: as shipped only a live handover completes it (`Config.Completion.Fulfilment = 'alive'`): the hitman brings the target alive within `Config.Kidnap.Radius` of the placer and the three stay close for `Config.Kidnap.CountdownSeconds`. With `'either'`, a verified kill completes it too (**Verify kill**, with or without a kill photo).
5. **Ending**: completed, the hitman is paid from escrow (owed and paid at their next login if away or full). Withdrawn by the placer while nobody holds it, expired, voided by staff or bought out: the reward goes back to the placer; a hitman's stake goes as the rules say. An exclusive hitman who never goes near the target is released after `ExclusiveIdleReleaseSeconds`.
6. **Changes**: before anyone takes it, the placer's **Edit** sheet changes reason, reward, stake, deadline, mode, the buyout price, how it is completed (*alive or dead* only where `Config.Completion.Fulfilment` is `'either'`) and whether it is placed anonymously (only where the anonymity switches allow it for that target, the creator fee charged then), each checked as placing checks it. The target cannot be changed in place: **Cancel and place again** (two taps) withdraws it with everything handed back and opens the Place form, where the new one goes through every placing check; the usual wait after withdrawing (`Config.Amendments.CancelCooldownSeconds`) applies. Once taken, the reward can still be raised, the deadline extended, and anything else proposed (**Propose change**) for the hitman to accept.

### The meeting point

On a contract only a live handover completes, once a hitman holds it the placer can tap **Set meeting point here** (asked first) to mark where they stand (`Config.Kidnap.MeetingPoint`, on as shipped).

- **Who gets the marker**: the placer and every hitman active on the contract get a yellow *Meeting point* marker on their map, seen from anywhere. Nobody else does: never the target, a bystander, or staff who are not a party. The coordinates go only to those games, never to the app's page.
- **What each side is told**: both get a phone notice (*Meeting point set*, or *Meeting point moved*) saying what to do, and their card under Mine shows the same words as a *What to do* line. The placer: be at the meeting point, stay within `Config.Kidnap.Radius` of the hitman and the target and keep still while the hitman taps **Deliver alive** (`Config.Kidnap.CountdownSeconds`), and follow it in the app; there is nothing for them to tap. The hitman: bring the target alive there (cuffed or in their vehicle where `RequireCoercion` is on), get within the radius of the person who placed it, open the app and tap **Deliver alive** on the contract under Mine, and hold. Neither notice names the other side.
- **With Confirm handover on** (`Config.Kidnap.PlacerConfirms`): the placer's words say to tap **Confirm handover** on their card within `Config.Kidnap.ConfirmSeconds` once the hold is done, and the hitman's that it pays once the placer confirms.
- **When it changes**: moving the point moves the marker on every map. A hitman who takes the contract after it was set gets the marker and the notice when they accept. A party who logs out loses it from their map and gets it back when they return (and after a restart).
- **When it goes**: off every map when the placer clears it, when the contract is completed by the handover, cancelled, expired, voided or bought out, and when the last hitman walks away, is released for idling or is removed by staff. A hitman who leaves while others stay loses it from their own map only. Turning the switch off takes it off every map; turning it on puts it back.

### Confirm handover

Off as shipped (`Config.Kidnap.PlacerConfirms = false`): a live handover pays the moment the hitman has held the target for `Config.Kidnap.CountdownSeconds`. On, the hold no longer pays by itself:

- **The placer confirms**: once the hold is done, their card under Mine shows **Confirm handover** and **Decline** (two taps each, the second naming what it does) for `Config.Kidnap.ConfirmSeconds` (60), and their phone says so. The payout is made once they confirm. Nothing is sampled during the window: the hold is what proves the handover.
- **Decline, or no answer**: a decline pays nothing; the contract stays open, and the hitman may tap **Deliver alive** again after `Config.Kidnap.RearmCooldownSeconds`, as after any failed handover. A window that runs out does the same, unless `Config.Kidnap.ConfirmMissed = 'pay'`, which pays as if confirmed. The hitman reads the same words for a decline and a timeout.
- **Declines are capped** (`Config.Kidnap.MaxDeclines`, 2 as shipped; 0 = no limit): each decline, and each window left to run out under `'rearm'`, counts against the contract. Once a placer has used them all, the next handover held for its countdown pays without asking them (pay by default rather than a staff review, so an alive-only contract cannot be held open by declining for ever), and the placer is told why. Counted in memory: a restart, which ends every handover, starts the count again. A Confirm or Decline that arrives after the window closed (run out, rearmed or paid by the tick meanwhile) is answered *no handover* rather than reported as done.
- **Anonymity**: the hitman is told the person who placed it confirms; the placer is told nothing of who holds the target. Only the placer is answered; anybody else asking is told not found.
- **Holds**: a staff freeze stops a handover waiting on its confirm, and nothing is paid. The window stands still on the restart hold (a confirm is refused until it lifts) and while the app is paused (`Config.Holds.AppPaused`; a confirm still pays). A handover keeps the rule it was armed under if the switch is changed meanwhile.

### Money rules

- Every reward is held from placing to ending; a payout comes only from what is held, in exactly the sources it holds (dirty money in, dirty money out: there is no conversion, because `sc-blackmarket` values dirty money above clean).
- A payout to a player who is away or full is owed and given at their next login (and retried every 30 s while online). One the server could not give after three tries waits for staff under **Money waiting** in the panel's inbox.
- Every completion (a verified kill, a live handover, a proof item, a confirmed handover) is paid by one claim, after one check that it may pay (still on it, no staff or restart hold, no slot cooldown, a slot left). Once paid, a payout may wait in escrow, owed to the hitman, for the payout checks switched on, in order: body disposal (`Config.Disposal`), then proof of intent (`Config.Roleplay.ProofOfIntent`); it is handed over by the same retry once none holds it.
- Anything no rule can settle (a buyout the store would not record, a payment the database did not confirm) goes to **Needs review** for staff.
- Caps: `Config.MaxContractValue`, each source's `max`, `Config.Penalty` for stakes, `Config.Bailout` for buyouts; every figure is checked on the server, never taken from the phone.

### What stops it being abused

- One account can never be two parties to a contract (`Config.AntiCollusion`); a target cannot be listed again for a while after a contract on them closes, nor by the same placer.
- New characters and players just online cannot be targets (`Config.Immunity`); whitelisted-job targets may be (`Config.Targeting.AllowProtectedJobTargets`, on as shipped), and the advisory warns officers.
- Barred jobs (`Config.BlockedJobTypes`, `BlockedJobNames`) never use the app; they see only the whitelisted-job view.
- Every request is rate-limited per player (`Config.Cooldowns`), every write is audited, and nothing a player's game sends is trusted for money, items or position.
- Anonymous parties stay anonymous to everybody but staff holding `crimson.identity`, in every view and log.

### The app's screens

Every screen says in one line, at its top, what it is for. The **Board**,
where the app opens, also sums up what you have going (*N taken*, *N
placed*, *N on you*: a tap on each opens where they are) and has one
**search** over the contracts on the board and the app's own screens: type
a name or a word, and the cards that do not match step aside while the
screens that do (*Open Ledger*, *Open Place*…) are one tap away.

### The most common actions, in taps

Every write takes two taps (the second confirms). Counted from the tab the
action starts on; typing is not counted.

| Action | Role | Taps |
|---|---|---|
| Accept a contract | hitman | 2 (Accept, then Anonymously / Under my name / Accept) |
| Place a contract | placer | 2 after the form (Place, then *Tap again to place* with the total) |
| Deliver alive | hitman | 1, then hold the countdown |
| Verify kill (`'either'`) | hitman | 1, then the photo |
| Message the other side | any party | 2 (Message, Send); one operative opens straight away |
| Buy out a contract | target | 2 |
| Withdraw an untaken contract | placer | 2 |
| Abandon a contract | hitman | 2 |
| Edit an untaken contract | placer | 3 (Edit, Save, Confirm) |
| Raise the reward on a taken contract | placer | 2 after the amount |
| Extend the deadline | placer | 2 after the minutes |
| Propose a change, or answer one | either | 3 to propose, 2 to answer |
| Buy the target's informant | target | 3 (Informant, pick, Pay) |
| Buy an informant tip | hitman | 2 |
| Report a contract to staff | any party | 2 |
| Set or clear the meeting point | placer | 2 |
| Move a protection job's meeting pin | target | 2 |

## Admin panel

`/hitmanadmin` opens the panel in game. Every staff command is a button
there; nothing in it needs a command. The server checks the ACE on every
request, so taking one away closes the panel at its next click. Every write
takes two clicks, a settings switch, choice or Save included: the first
arms the button in brass and names what the second sets (*Click again: turn
On*, *Click again: save 60 d*), and it disarms after three seconds. A
redraw meanwhile, such as the overview's timed refresh, keeps it armed.
Every write is rate-limited per staff member (`Config.Cooldowns.admin`,
`adminWrite`) and is written to the audit log at once. While the server is
still recovering from a restart, every write but flushing the log is
refused.

The sidebar groups the sections by how often each is used: **Daily**,
**Setup**, **Records** and **Developer** (only for staff who hold
`crimson.developer`, or `crimson.admin`). **Help** is in the header: *How it
works* (an accordion, a card per feature with links to its settings), *How do
I…* (every staff action, each with a Go that opens where it is done) and *Who
can do what* (every ACE, and how to grant it).

- **Search** (`/` or Ctrl+K, in the header) finds a setting, an action or a
  section as you type; Enter on a contract id opens it, on a player id or a
  name looks them up.
- **The player and contract you are on stay put.** A lookup puts *Player:
  <name>* in the header, with the minutes left of the lookup (ten); the
  contract you last opened is a chip too. The contract drawer stays open over
  any section until you close it, and its chip opens it again. A breadcrumb
  under the tabs says where you are.
- **On a phone-width window** the sidebar folds into one *Sections* menu, the
  tabs scroll along one line, and the drawer takes the whole screen.
- A view has one name. A view remembered under a name it no longer has
  opens on Home, like any name the panel does not know.
- **One line of help** under every view's title says what it is for.
- **A gear** beside that line (*Settings for this screen*) opens the
  settings the view works by, above it, as rows of the settings list (two
  clicks, on the record, undone from Change history); *All settings* there
  opens Game rules, the view of every setting. Views that are settings
  already have none.
- **Home opens on its dashboard**: what waits for you (each count opens its
  list), the live counts (contracts by state, operatives, money held and
  owed, measures on players), **quick actions** (Find a player, Contracts,
  Live by target, Announce, Game rules) and the server's **health** at a
  glance (recovery, storage, setup problems, settings changed here).
- A refusal the server gives without words of its own says so in a
  sentence; no internal code is shown.

| Section | Tabs | Use it to |
|---|---|---|
| **Home** | Dashboard, Inbox, Announce | The dashboard is described above. The inbox lists what waits for staff in one place, with a chip and a count for each: **Needs review** (refund, pay or dismiss), **Money waiting** (escrow lines left for you to settle: Pay, Pay amount, Return, Delivered) and the open **Alerts** (Acknowledge); and, while a body is being disposed of, every such step with **Skip** and **Respawn vehicle**. The dashboard counts contracts, operatives, money held and owed, and who is frozen, suspended or protected, with the setup problems for staff who can change things. Announce sends one notice to every hitman holding a contract, or everybody with the app |
| **Players** | Find & summary, then for the player looked up **Their contracts** (Contracts, filtered to them), Measures, Money, Playtime, History, *Why can't they see…*; and All measures | Look a player up (player id, citizen id or name; recent lookups are one click). Measures: **Freeze**, **Suspend**, **Protect**, and their standing in Target limits. Money: what they are owed, notices for their next login, **Pay**. *Why can't they see…* runs the diagnosis as them. All measures is one list of everybody frozen, suspended, protected or with target limits of their own, filtered by kind, each freeze, suspension and protection with **Unfreeze** or **Lift** (their own target limits are lifted in Target limits, Per player, with a reason) |
| **Contracts** | Contracts | The one list of contracts. Search and filter (state, rule, when placed), narrow it to **one person** (a player id, citizen id or name, or *Their contracts* from a player's card) with their part on each (**Target**, **Placer**, **Hitman**; an anonymous part only with `crimson.identity`, which also gets **Whois** on each row), or list the live ones **by target**; then open one. Above the list, every body being disposed of ([body disposal](#mission-steps)) with the exact time left, **Skip** and **Respawn vehicle**. The drawer has tabs: **Summary** (terms, the deadline with **Extend** / **Shorten**, open proposals), **Money** (lines waiting for staff, payouts, **Change reward** with the server's figures before it arms, escrow lines; its tab counts the lines waiting), **People** (operatives, **Remove an operative**, **Reassign to another hitman** looked up in Players, *As a player sees it*, Whois), **Notes & text** (staff notes, **Edit text**) and **Record** (timeline, export). **Void** is under **More** |
| **Target limits** | Defaults, Per job, Per player; **History ▸**, **Live contracts by target ▸** | See [Target limits](#target-limits). **History ▸** opens Records › Logs on the audit log's `staff_target_` rows; **Live contracts by target ▸** opens Contracts listing the live ones by target |
| **Game rules** | Areas, Presets, Changed from the panel; **Change history ▸** (Records › Logs, Setting changes) | Every rules and features setting by the area of the game it is about (who can use the app, placing contracts, anonymity, rewards, completing, buyouts, informants, police, messages, roleplay extras, staff tools): an area's switches first, then its numbers and lists. Chips narrow it to **Switches**, **Timers**, **Money**, **Limits**, **Lists** or **Changed**, across every area when none is picked. A row shows its label with its unit, its control and Save or Reset; **Details** shows its `Config` key, what it does, what happens to things under way and where its value comes from. **Undo all panel changes** is on *Changed from the panel*; every change, with **Undo**, on *Change history*. **Presets** are named bundles of settings (*Strict*, *Relaxed*, *Roleplay-heavy*, and *Current*: the server's own values, saved by hand or before any other preset is applied): each card lists every change it would make, from what to what, and what the server would refuse and why; nothing changes until **Apply**, two clicks naming how many changes. Each change is then an ordinary setting change, audited and in *Change history* with its Undo, and the apply itself is audited (`admin_preset_applied`). **Your own presets**: type a name and **Save the panel's changes as a preset** (two clicks) to keep every setting changed from the panel now under that name (up to 20, stored with the settings, audited `admin_preset_saved`); it is listed after the shipped ones, marked *yours*, previewed and applied the same way, and **Delete** (two clicks, audited `admin_preset_deleted`) takes it away |
| **Hitman organisation** | Setup, Roles & pay, Members, Applications, Funds & cuts, Contract access, Notices; **Org audit ▸** (Records › Logs, Org audit) | See [Organisation](#organisation). Off as shipped: every tab is one card saying so, with its switch |
| **Boss permissions** | Matrix, Limits, Delegation & office; **Grant history ▸** (Records › Logs, Grant history) | The ceiling on what bosses may do: powers by boss role and by one boss (**Allow**, **Deny** or **Inherit role**), every change listed before one **Save** that sends them together; **Revoke all** and **Copy from** per column; each power's limits; which powers need the boss office; every grant, with **Undo** on a role's |
| **Locations** | Map points | The organisation's places (boss office, sign-up, meeting and handover spots, NPC spots), body disposal's vehicle spawn and drop-off (**Save**, **Save where I stand**, **Clear**), and the places that are settings (broker and informant NPC places, tip safe zones, rumour districts, witness areas, the prison zone). **Use my position** fills a row from where your character stands, read by the server |
| **Logs** | Logs, Alerts | Every log in one view, one chip each: **Audit log** (search it, and flush it), **Setting changes** (every setting changed from the panel, with **Undo**), **Org audit** (every boss and staff action on the organisation) and **Grant history** (every grant, with **Undo** on a role's). Each section's own link (Game rules, Hitman organisation, Boss permissions, Target limits) opens it with its chip picked. Alerts: acknowledge alerts, see where Discord stands, send a test alert |
| **Developer** | Health, Engine settings, Console, Test tools, First-start setup | Storage, recovery, kill photos, slow jobs and the diagnosis; debug, storage, rate limits, the other scripts (`Config.Integrations`) and the read-only values; the console; **Bring timers forward** (test servers) and **Flush the audit log**; the **first-start setup** (shown by itself to the first staff member with `crimson.admin` until it is saved: storage mode, the other scripts found with an override, the exact `add_ace` lines and who holds them, the panel command and the key switches, every one at the value in force; **Preview**, then **Apply** in two clicks, each change a setting change in Change history with Undo, audited `admin_setup_applied`) |

Without `crimson.identity`, an anonymous party is *Anonymous* everywhere,
citizen ids read as the party's place (*the placer*, *the target*,
*operative <alias>*) and searches never find a contract through an anonymous
party. Every unmasking is its own audit row.

### Target limits

**Target limits** is its own section, under Daily. Every write in it takes
two clicks, is rate-limited and audited, and waits for boot recovery, like
every other write.

- **Defaults**: the six limits every target has unless a job or a player
  override says otherwise. `Config.Limits.TargetCooldownAfterResolveSeconds`
  (wait after a contract on a person ends), `SameCreatorSameTargetCooldownSeconds`
  (the same placer naming them again), `TargetCooldownAfterCompletionSeconds`
  (after a completed one, 0 off), `MaxActiveContractsPerTarget` (live at
  once), and two new caps, both 0 (off) as shipped:
  `MaxContractsPerTargetPerDay` (placed on them in a rolling 24 hours) and
  `MaxContractsPerTargetPerWeek` (a rolling 7 days). A contract counts toward
  the day and week caps whatever became of it, unless staff voided it or it
  was withdrawn or ran out before anybody took it (those cost nothing, so
  friends could otherwise fill the caps for free).
  Changing these needs `crimson.admin`, like every setting.
- **Per job**: add a qbx job name (`[a-z0-9_]+`, at most 32 characters) with
  any of the six limits; a target holding that job when the contract is
  placed, as the one they are working or as a second job, has those instead
  of the defaults. Where more than one of their jobs has its own, the
  strictest value wins, limit by limit (the longer wait, the smaller cap), so
  switching the active job steps round none of them. Each job shows its own values
  and the effective ones. Kept in the store (`crimson_rp_rows`, kind
  `tl_job`) and applied again at every start; a stored row that does not
  check out is not applied and the start says why. Adding, changing and
  removing one needs `crimson.admin`.
- **Per player**: look a player up (as Players does). Their card shows the
  live contracts on them, the contracts placed on them in the last 24 hours
  and 7 days, the exact cooldown left and which rule sets it (global, job or
  player), with *Reset cooldown* (the wait after a contract ends; the same
  placer's wait, a staff extension and a buyout's immunity hold unless you
  choose *Reset all*, and the reply says so), *Extend cooldown* by minutes or
  until a time, *Reset counts* (the day and week counts start from now), and
  their own limits or *Exempt from limits*, for some hours or for good.
  The immunity a target bought with a buyout
  (`Config.Immunity.AfterBailoutSeconds`) is not a target limit: Reset,
  Exempt and every job-wide action leave it, the card shows how long it has
  left, and only *Reset all* on that one player lifts it. Every
  one takes a reason and needs `crimson.moderator` or `crimson.admin`. Kept
  in `crimson_rp_rows` (kind `tl_player`) and pruned once every fact in them
  has run out.
- **Per job, at once**: the same Reset cooldowns, Extend cooldowns and
  Reset counts for every player of one job. *Players of a job* are everybody
  in the city holding it now (working it or as a second job), and everybody
  not in the city whom the latest contract placed on them in the last 7 days
  recorded as holding it. A job-wide Reset, even Reset all, never lifts a
  buyout's immunity. The
  confirm names the job and how many players it reaches; one audit row
  records the action with the count. `crimson.moderator` or `crimson.admin`.
- **Live contracts by target ▸** (Contracts, listed *Live, by target*):
  every live contract (open, taken, settling, on hold) grouped by target, a
  page at a time, searchable by the target's name or exact citizen id. A row opens the contract's own view, with every staff
  action it has (Extend / Shorten, Void, remove an operative, edit text,
  notes), under the same ACEs and the same scrubbing.

Players are never told any of this: a refusal is the wording the target
rules already use (*already has as many contracts on them as this server
allows*, *there was a contract on them very recently*), with no time beyond
what they see today, and nothing about a job or staff.

### Staff commands

Run in your **F8 console** in game (the answer prints there, never in chat)
or the server console. The names are `Config.Admin.Commands`. The `<contract>`
id is the **Ref** at the foot of every card and Ledger entry.

| Command | What it does | Needs |
|---|---|---|
| `/hitmanadmin` | Opens the admin panel (in game only) | `crimson.admin` or an extra ACE |
| `/ch-diag [player]` | Why the app is not showing something; the database, the loops and a player's own view | `crimson.admin` or an extra ACE |
| `/ch-contracts <player>` | A player's contracts with their ids | `crimson.admin` or an extra ACE |
| `/ch-timeline <contract>` | One contract's state, escrow and audit trail | `crimson.admin` or an extra ACE |
| `/ch-stuck` | Money waiting for staff, and open review items | `crimson.admin` or an extra ACE |
| `/ch-whois <contract>` | Who is behind an anonymous party | `crimson.identity` |
| `/ch-void <contract> [reason]` | Close a contract and refund its placer | `crimson.admin` |
| `/ch-settle <line> pay [amount] \| return [citizenid] \| delivered` | Finish one stuck payout by hand | `crimson.admin` |
| `/ch-review [all] \| <id> refund … \| pay … \| dismiss <note>` | The review queue | `crimson.admin` |
| `/ch-refresh timers` | Test servers: bring every wait forward | `crimson.admin` |

The players' buyout command (`Config.Bailout.Command`, `/cleanse`) is not a
staff command; it answers in chat. `/cleanse` lists what is out on the player
with each price; `/cleanse <id>` then buys at the price listed to them in the
last 5 minutes, and `/cleanse <id> <price>` at the price typed. Where that is
not the price now (the placer may change it until somebody accepts), nothing
is bought and the new price is said.

No two of these names may be the same, in any case, and none may be the
panel's way out, `/<panel>-close` (`/hitmanadmin-close`): two commands under
one name is whichever registered last, so the start refuses it, the panel
refuses such a change, and a stored one is not applied at the start.

### Panel requests

Every request the panel page sends (`server/panel.lua`), and who may send it.
*Read*: `crimson.admin` or one of `Config.Admin.ExtraAces`. *Moderate*:
`crimson.moderator` or `crimson.admin`. *Write*: `crimson.admin` itself.
*Identity*: `crimson.identity`. *Developer*: `crimson.developer` or
`crimson.admin`.

| Op | Who | What it does |
|---|---|---|
| `access` | Read | What this staff member may do, and the Permissions list |
| `overview` | Read | The overview: counts, money held, alerts, the server's state |
| `contracts` | Read | The one contract list and its search; `state = 'live'` (the page's default, *Live only*) lists every contract still running; `ref` or `person` (and `as`) one person's, `byTarget` the live ones by target |
| `contract` | Read | One contract's view and timeline |
| `exportContract` | Read | One contract's record as text, for a ticket |
| `playerView` | Read | A contract as one of its parties sees it |
| `reviews` | Read | The review queue |
| `stuck` | Read | Money waiting for staff (Home, Inbox) |
| `logs` | Read | Every log, one area each (`area`): the audit log and its search (none, or `audit`), every setting change from the panel (`settings`), the organisation's log (`org`, `org_*` actions; `action = 'org_grant'` the grant history) |
| `alerts` | Read | The alerts |
| `player` | Read | One player's contracts and record |
| `history` | Read | One player's history card |
| `measures` | Read | Every measure on a player in force, newest first (`server/measures.lua`): frozen, suspended, protected and their own target limits, each row with its `kind` and a handle (`ref`) Unfreeze or Lift takes; `kind` filters to one. The citizen id and who set it only with `crimson.identity` |
| `settings` | Read | Every setting, its value and where it comes from |
| `diag` | Read | The diagnosis, as yourself, a player id or the player looked up (`ref`); with `config = true`, the config check (`/ch-diag config`); scrubbed of citizen ids and accounts for staff without `crimson.identity`, and the lines that come later name the `ref` they were run for, so the page draws them under that player only |
| `console` | Developer | What this resource printed in the server console |
| `whois` | Identity | Who is behind an anonymous party |
| `void` | Moderate | Void a contract and refund it |
| `adjustDeadline` | Moderate | Extend or shorten a live contract's deadline |
| `freeze` | Moderate | Freeze a player: every live contract of theirs on hold |
| `unfreeze` | Moderate | Release a freeze; the time on hold is given back |
| `suspend` | Moderate | Bar a player from placing and accepting |
| `unsuspend` | Moderate | Lift a suspension |
| `protect` | Moderate | Make a player untargetable for a while |
| `unprotect` | Moderate | Lift a protection |
| `settle` | Write | Settle a stuck payout: pay, pay an amount, return, delivered |
| `resolve` | Write | Resolve a review item: refund, pay, dismiss |
| `manualPay` | Write | Pay a player by hand, up to `Config.Staff.ManualPaymentMax` |
| `addNote` | Write | A private staff note on a contract |
| `removeHitman` | Write | Take one operative off a contract |
| `editText` | Write | Replace a player's text on a contract (reason, message) |
| `setSetting` | Write | Change a setting |
| `resetSetting` | Write | Put one setting back to config.lua's value |
| `resetSettings` | Write | Put every setting back to config.lua |
| `undoSetting` | Write | Undo one setting change |
| `presets` | Read | Every preset with the changes it would make now and what would be refused |
| `presetApply` | Write | Apply one preset by name: Current saved first, then each change as a setting change |
| `presetSave` | Write | Save the settings the presets name, as they are now, as Current |
| `presetSaveOwn` | Write | Save the settings changed from the panel now as a preset of the server's own, under `name` (1-32 letters, digits, spaces, - _ '; not a shipped name; at most 20; the same name replaces it); audited `admin_preset_saved` |
| `presetDelete` | Write | Delete a preset of the server's own by `name`; audited `admin_preset_deleted` |
| `settingsExport` | Developer | Every setting changed from the panel (never a secret) and the server's own presets as one JSON `text` (`format`, `version`, `resource`, `exported`, `settings`, `presets`), with how many of each; not the map places or the target limits |
| `settingsImport` | Developer | What an exported `text` (at most 200 KB) would change now: `changes` (key, label, from, to), `refused` (key, label, why: on the deny list, not a setting of this version, read-only, or a value the start-up checks refuse), `same`, and the `presets` it would add (or why not); changes nothing |
| `settingsImportApply` | Write | Apply an exported `text` when its changes still number `expect` (the preview's): each through Settings.set (audited `admin_setting_changed`, in Change history with Undo), then its presets (only the values this server takes), then one `admin_settings_imported` row; needs the Developer section too |
| `setup` | Write | The first-start setup: storage, the other scripts (detected, and the adapter chosen), the `add_ace` lines, the panel command, the key switches, each at the value in force |
| `setupPreview` | Write | What applying the setup's choices would change, and what would be refused; changes nothing |
| `setupApply` | Write | Apply the setup's choices, each as a setting change, and save the setup as done |
| `announce` | Write | One notice to every hitman, or everybody with the app |
| `refresh` | Write | Bring every wait forward (test servers) |
| `flush` | Write | Write the audit log now |
| `ackAlerts` | Write | Acknowledge alerts |
| `testAlert` | Write | Send a test alert to Discord |
| `removePhotos` | Write | Remove the kill photos kept from before |
| `setPlaytime` | Write | Correct one character's counted playtime |
| `targetLimits` | Read | Target limits: the limits and every job's own |
| `targetStatus` | Read | One player's standing as a target, exactly |
| `targetJobCount` | Read | How many players a job action would reach |
| `targetJobSet` | Write | Add or change a job's own target limits |
| `targetJobRemove` | Write | Remove a job's own target limits |
| `targetReset` | Moderate | Reset a player's cooldown (or all of them) |
| `targetExtend` | Moderate | Extend a player's cooldown by minutes or until a time |
| `targetCounts` | Moderate | Reset a player's day and week counts |
| `targetOverride` | Moderate | A player's own target limits, or exempt |
| `targetOverrideClear` | Moderate | Lift a player's own target limits |
| `targetJobAction` | Moderate | Reset, extend or reset counts for every player of a job |

### Reward and reassign requests

Added by `server/staff_reward.lua` and `server/staff_reassign.lua` through the panel's one way in (`Panel.extend`), so each runs the same gate: the ACE on every request, the panel's rate limits, a write waiting for boot recovery, every write audited. The page asks twice before it sends a write, naming the figure or the hitman.

| Request | Who | What it does |
|---|---|---|
| `rewardPreview` | Read | `{ id, by }`: the collection's reward now and after, the most it may be lowered by, what staff added, and why a change would be refused |
| `rewardChange` | Write | `{ id, by, from, account, reason }`: raise (`by` above 0, `from = 'staff'` or `'placer'`, `account = 'cash'` or `'bank'`) or lower (`by` below 0) the reward; audit `staff_reward_changed` |
| `reassignPreview` | Read | `{ id, ref, identity }`: the operatives on it now (aliases), whether the stake is waived, whether the hitman would go on anonymously, and what would refuse them: every check the reassignment asks before it takes anybody off, the same refusals |
| `reassignHitman` | Write | `{ id, ref, reason, block, returnStake, identity }`: take every operative off and assign the hitman the lookup named; `identity` is `'anonymous'` (the default, no fee), `'named'` or `'carry'` (what they chose on their own earlier stint on it); the old `anonymous = false` still means named. Audit `staff_reassign_hitman` (`staff_reassign_failed` when it could not finish, with how many were put back) |

### Console output and Discord

`Config.Debug = true` (as shipped) prints start progress, every setting
problem in full and slow jobs (`Config.Diagnostics.SlowJobMs`). Off, a sound
start prints nothing; only refusing to start, money left for staff and failed
writes are printed, and one line counts the settings that need attention.
`/ch-diag` lists all of it either way. The audit mirror
(`crimson_hitman_webhook`) posts money movements and refusals without
identities, one message per flush; alerts and the daily summary go to
`crimson_hitman_alert_webhook` (or the audit one).

## Optional features

Each is switched in the panel's **Features** and in `config.lua`; each has a
**How it works** card in the panel (Live) linked to its settings. Switching
one off never strands money: what is under way finishes under the rules it
started with, and new actions are refused with *turned off by the server*.

### Core switches

On as shipped unless marked: buyouts (`Config.Bailout.Enabled`), proposals
(`Config.Amendments.Enabled`), messages and calls (`Config.Relay.Enabled`),
headshots (`Config.Mugshot.Enabled`), criminal progression
(`Config.Record.Progression.Enabled`, under A hitman's record), the whitelisted-job view and its Notify me
(`Config.WhitelistedView`), kill photos (`Config.Completion.KillPhotos`, off),
the nearby target list (`Config.Targeting.AllowNearby`, off).

### Anonymity

Off as shipped. `Config.TargetClasses.default.AllowAnonymousPlacer` and
`AllowAnonymousHitman` let a contract be placed or accepted anonymously, for
a fee (`Config.Anonymity.CreatorFee`, `HitmanFee`). Every rule that differs
by who the target is lives in one table per target class,
`Config.TargetClasses`: `default` for every target, `whitelisted` for a target
on a whitelisted job (read by one resolver, `Util.targetRule`). An anonymous party is
*Anonymous* to every player; staff need `crimson.identity` to see who it is.

### Intel

Everything a player can learn for money lives under `Config.Intel` and one
admin screen group, **Intel**. Three paid look-ups, each off as shipped, all
behind `Config.Intel.Enabled`: the **target's** (`Config.Intel.Informant`:
who is after me, with a chance of an answer), the **placer's**
(`Config.Intel.PlacerInformant`: which operative took it) and the hitman's
**tip** (`Config.Intel.LocationTip`: the target's rough area on the map, and
the target is told). Each is sold where its own `Enabled` is on and its
switch for the target's class is (`Config.TargetClasses.default` /
`.whitelisted` `.Informant`, `.PlacerInformant`, `.LocationTip`).

Every purchase runs through one engine (`server/intel/engine.lua`): one check
(who may buy it, the switches and the target's class, a staff hold, the
contract still open, the product's limits, waits and price), the price the
page quoted held to the price now, the charge last, and the price given back
in full, under the product's own audit action, if anything stops the purchase
after the charge (the contract ending, a staff hold, an operative leaving, a
read that failed). A refund that cannot be paid at once is owed (the
informants, going dark) or left for staff (the tip), as before.

All off as shipped, each `Config.Intel.<Feature>.Enabled`:

| Feature | What it does |
|---|---|
| **Tip warning delay** (`WarningDelay`) | A tipped target is told a random while later (`MinSeconds`..`MaxSeconds`); the time on their card is rounded to 5 minutes; survives a restart |
| **Tip limits** (`TipLimits`) | One tip per hitman per contract, and/or each further tip costs twice the last, up to `MaxCost` |
| **Hold before a tip** (`HoldFirst`) | A tip only once the hitman has held the contract `MinHeldMinutes` |
| **Informant second try** (`SecondTry`) | The target's later look-ups cost `SecondTryCostPercent` of the price |
| **Tip safe zones** (`SafeZones`) | No tip while the target is inside a zone (`'x, y, radius, name'`); the hitman is told only that the informant can't place them |
| **Go dark** (`GoDark`) | A tipped-off target pays to make tips on them find nothing for `Minutes`; the hitman gets their money back. Sold only while tips on that contract are (`Config.Intel.Enabled`, `Config.Intel.LocationTip.Enabled`, and `Config.TargetClasses.whitelisted.LocationTip` for a whitelisted-job target); a window already paid for holds, and stays on the card, to its end. The window stands still while its contract is on hold (a staff freeze, the restart hold and the restart, the app pause), as an informant tip's showing and wait do. Kept across a restart only once paid: a purchase the store could not keep is refunded, and a window that has passed is cleared from the store on the minute |
| **The informant in person** (`InPerson`) | Every informant purchase only beside the informant NPC, which moves between its places |
| **Rumours and a broker** (`Rumours`) | New contracts show only as rumours (area, reward band) until the broker NPC, or a player on a broker job, briefs the hitman for `BriefValidMinutes` |

### A hitman's record

Where a player stands lives under `Config.Record` and one admin screen
group, **Record & standing**, read and kept by one module
(`server/record/`): the counters every character has (contracts placed,
completed, failed and survived, shown on the app's Ledger, on a card's
operatives and on the panel's player card), the standing they give
(*Unproven*, *Known*, *Established*, *Notorious*) and the level the tiered
board asks for. Criminal progression is on as shipped; the rest is off,
each `Config.Record.<Part>.Enabled`.

| Part | What it does |
|---|---|
| **Criminal progression** (`Progression`) | A completion gives `TrustPerElimination` / `TrustPerKidnapping` trust through the progression adapter (`Config.Integrations.Progression`, sc-blackmarket's `AddTrust`); one missing or failing never touches the payout |
| **Reputation earned in character** (`Reputation`) | Progression trust for a completion is scaled by how it was done (thread, meeting, handover, no witnesses), up to `MaxFactor` |
| **Tiered board** (`Tiers`) | Bigger rewards locked to a progression level, 1 plus one for each `CompletionsPerLevel` completed (needs `Config.Record.Progression.Enabled`) |
| **Hitman heat** (`Heat`) | Completions on whitelisted-job targets, witness reports and bulletins give a hitman heat for `DecayHours`; at `Threshold` their targets may be warned and officers get a vague bulletin at most every `BulletinEveryMinutes` (every officer alike, a known hitman who holds a police job too) |
| **Placer record** (`PlacerRecord`) | A board card shows its placer's placed / paid out / cancelled counts over `LookbackDays`, never who; anonymous placers in bands with `ShowForAnonymous` |

### Advisory

On as shipped (`Config.Advisory.Enabled`). A contract on an officer or another
whitelisted-job member is announced to the recipient jobs on their phones
and, with `UseDispatch`, in sc-dispatch, at the stages switched on (`OnCreate`,
`OnAccept`, `OnLocationTip`, `OnCancel`). The placer and the hitman are warned
first and the card is marked on the board.

### Staff tools

- **Freeze** a player (Players): every live contract of theirs goes on hold until **Unfreeze**, which gives the time back. Players see only *on hold by staff*.
- **Suspend** a player from contracts, or **protect** one from them, for hours, days or for good; neither touches running contracts. **Lift** ends either.
- **Pay** a player by hand (cash or bank, a reason, at most `Config.Staff.ManualPaymentMax`).
- **Deadlines**: extend or shorten a live contract by up to `Config.Limits.StaffDeadlineMaxAdjustSeconds`, never under `StaffDeadlineMinLeftSeconds`.
- **On a contract**: staff notes, remove an operative (stake to the placer as a walk-away, or returned), edit a player's text, export, *As a player sees it*.
- **Change reward** on a live contract (`crimson.admin`, a reason, two clicks, at most `Config.Staff.RewardChangeMax` at once): a raise is *added by staff* (taken from nobody, and handed back to staff, never to the placer, if the contract is cancelled, expires, is bought out or voided), or charged to the placer's cash or bank if staff choose that and the placer is in the city; a cut comes off what staff added first, then the placer's own, each part going back to whoever funded it (queued for a placer who is away), never below `Config.Limits.MinContractReward` and never touching money already owed or being paid: the store cuts a line only while it is owed to nobody and being given to nobody, and the change stops at a claim that starts while it runs, so a claim's hitman is paid what the claim owed them. Refused while a payout is being settled, a buyout waits out its delay, or the contract is on hold (unfreeze first). The placer and every operative are told staff changed it; nobody is named.
- **Reassign** a live contract to another hitman (`crimson.admin`, a reason, two clicks): the hitman is named by a Players lookup and must be in the city and pass every check their own Accept would (job, eligibility, not the target, the placer or the target's guard, their limits, the stake rule). Every operative on it is taken off as **Remove** does (their stake to the placer, or returned; barred from taking it again unless staff untick it), all under the contract's own key, so nobody takes it from the board in between. The new hitman's stake is waived (`Config.Staff.ReassignStake = 'waive'`, as shipped) or charged as on Accept (`'charge'`). They go on it **anonymously** and are never charged the anonymity fee, unless staff choose **Named to the placer** or **As they chose before** (their own earlier stint on it); only a server with a hitman's anonymity turned off names them anyway, as it names every hitman. Every check of the acceptance (the stake money, `MaxAcceptedPerHitman`, anonymity, a walk-away's wait) is asked before anybody is taken off, and the preview asks the same, so it refuses what the reassignment would. If the acceptance is still refused once the operatives are off (a balance or a limit that moved in between), every operative is put back on it with their stake still held and the bar this set lifted, and staff are told so.
- **App pause** (`Config.Holds.AppPaused`): nothing can be placed or taken, and every clock is held, for an event.
- **Daily summary** (`Config.Staff.DailySummary`, off) at `DailySummaryHour`; **alerts** past the `Config.Staff.Alert*` thresholds, posted to Discord with `Config.Alerts.ToDiscord`.
- **Moderators** (`crimson.moderator`): read without identities, freeze, suspend, protect, void and move deadlines; settings, payments and settling stay with `crimson.admin`.

### Roleplay

All off as shipped, each `Config.Roleplay.<Feature>.Enabled`.

| Feature | What it does |
|---|---|
| **Witness heat** (`WitnessHeat`) | A completion with bystanders near (or always) sends officers a vague witness report: a phrase, the way the hitman went and the nearest named area, optionally a fuzzed position. Never names anybody |
| **EMS before re-listing** (`EmsRelisting`) | A target killed on a contract cannot be listed again until up for `TreatedMinutes` (or revived by a medic with `RequireEMS`), at most `MaxHoldMinutes` |
| **City news** (`CityNews`) | A completed contract on a whitelisted-job target (or any, with `AllTargets`) posts an anonymous news item on Birdy or as a server event |
| **Dirty money payouts** (`DirtyPayouts`) | A hitman's cash and bank payout is handed over as a dirty money item (by count or by worth); refunds go back as taken |
| **Proof of intent** (`ProofOfIntent`) | A payout is held, never refused, until the hitman has worked the contract in character (`MinMessages` to the placer, a live handover or a meeting point), at most `HoldMaxMinutes` |
| **Bodyguards** (`Protection`) | A target hires protection from On me (reward held, pin where they stand); a guard takes it from the board. Ended without a completion: the guard is paid; completed anyway: their share (`PayOnCompletionPercent`), the rest back. Switched off mid-job, a live job carries on: the target can still move its pin or cancel it, and its guard keeps the Protection tab with Set GPS |
| **Hit on the hitman** (`HitOnHitman`) | A target whose informant named an operative may place a contract on them, under every placing rule |
| **Burner phone** (`BurnerPhone`) | Placing, accepting and every contract action (turning contract decay off included) need the item; it may be used up on placing or accepting. Sell it through sc-blackmarket |
| **Broker and informant placed from the panel** (`NpcPlaces`) | Staff place the broker and the informant in the admin panel's Locations by standing there (Use my position, read by the server); each rotates among the places set as its `RotateHours` says. Kept by the store with the other spots staff set, on every backend. The `Locations` lists stay the defaults: used while none is set, after Reset to config, and with this off |
| **Reason quality** (`ReasonQuality`) | A typed reason needs a least length and number of words; low-effort phrases are refused or placed and sent to Needs review |

### Improvements

All off as shipped, each `Config.Improvements.<Feature>.Enabled`. The informant and tip rules are Intel's (above).

| Feature | What it does |
|---|---|
| **Contract decay** (`ContractDecay`) | An untaken contract's reward rises (charged to its placer, up to `MaxIncreasePercent`) or its deadline comes in, every `Hours` of waiting; time on a staff freeze, the restart hold, the app pause, held by an operative, or with decay itself switched off does not count. `rise` applies only to contracts placed under the placer's own name: a step charged when an anonymous placer logs in would show on the board when they did, so an anonymous contract never rises (its card says so). The placer can stop it on their card |
| **Proof items** (`ProofItems`) | On a contract a kill completes, the hitman may hand the placer an item taken from the target (an id card as shipped) instead of a photo. The item is checked before where anybody stands, so a hitman without it is only ever told it is missing; refused, taking nothing, under a freeze, the restart hold or the app pause. Paid as a kill would be, but recorded as what it was: the Ledger says *Proof handed over*, and there is no EMS re-listing, witness report or city news, since nobody saw a kill |
| **Weapon serial scrubbing** (`SerialScrub`) | A weapon an anonymous placer put up reaches the hitman with a new serial (as does one whose contract cannot be read). One weapon always gets the same new serial, after a restart too: it is worked out from the escrow line and a secret the store keeps (`imp_serial_secret_1` to `_5`, 140 random bits made at the first scrub), never from anything a player can see |
| **Weekly stats** (`WeeklyStats`) | One count-only post a week (`Day`, `Hour`) to `crimson_hitman_stats_webhook`, or the alert webhook |
| **Completion cooldown** (`Config.Limits.TargetCooldownAfterCompletionSeconds`) | A wait before a completed contract's target can be listed again; 0 (off) as shipped |

### Organisation

Off as shipped (`Config.Organisation.Enabled`). While it is off no job is
registered, nothing about it is read or written, every request answers
*switched off*, and contracts are placed, taken and paid exactly as without it.

On, the **hitman organisation** is a real qbx_core job (`Config.Organisation.JobName`,
`hitman` as shipped) whose roles are its grades. This resource's own tables
(`crimson_orgs`, `crimson_org_*`) are the source of truth and qbx_core is told:
the job is registered at every start with `CreateJobs` (never written into
qbx_core's own `jobs.lua`), roles with `UpsertJobGrade`, members with
`AddPlayerToJob` / `RemovePlayerFromJob` / `SetPlayerPrimaryJob` by citizen id,
so it works for players who are away too. A start that comes after players
loaded brings every online member back in step. A change made elsewhere
(`/setjob`, another resource) is adopted into the table, or put back with
`Config.Organisation.ExternalChanges = 'revert'`, the same whether it was made
while the player was online, away, or while the organisation was off (found
at their next login). A removal qbx_core cannot be believed about is always
put back: the job kept by name only, `qbx:cleanPlayerGroups` on, or a
character that loaded before the job was registered (a late start).

- **Roles and members.** Staff run everything from the panel: roles (order,
  name, label, pay, boss), hiring, roles, firing (with a reason), per-member
  grants and denies, a lock against boss edits, a codename. A staff hire is
  made at once and never made the player's primary job.
- **Joining.** A boss's hire is an **invite**: the player standing by them
  sees it on the app's board (the organisation and the role, never who asked)
  and taps Accept or Decline, twice to be sure, within
  `Config.Organisation.Limits.InviteMinutes`. Only an accepted invite (or an
  accepted application) makes them a member, and only then is the job made
  their primary one (`SetPrimaryOnHire`); the hire is checked again as they
  accept. Becoming a member any way closes every open application of theirs,
  so a stale one is never accepted over the record they have.
- **Boss permissions.** Every boss power is **off for every boss** until staff
  allow it for a boss role or one boss (Allow / Deny / Inherit). Staff can
  always do everything themselves. A boss passes on only what they hold, only
  to roles and members below their rank (level with it only with D3, never
  above), never to or on themselves, never past a staff lock (a grant or deny
  staff made, on a member or a role, is staff's alone to change); revoking a power
  from a boss makes every grant they made of it inactive at once, and allowing
  it again restores them. The organisation is never left without a member in
  its top boss role, unless staff do it. Every rule is checked on the server
  for every request.
- **The 35 powers** (the plan's 31 area powers, D2, D3, and M7, P3 for
  codenames and payroll; D1 is R4):
  M1 view members, M2 hire, M3 fire, M4 promote/demote, M5 suspend from
  contracts, M6 member limits, M7 assign codenames; R1 create, R2 edit, R3
  delete roles, R4 set role powers; P1 role pay, P2 bonus, P3 set salaries; C1 organisation cut, C2 cut by role, C3 cut per
  member, C4 cut on stakes, C5 cut on buyouts, C6 deposit, C7 withdraw, C8 view
  funds; K1 contract access rules, K2 boss pick, K3 role cooldowns; L1 move the
  office, L2 sign-up spot, L3 meeting spots; N1 notice, N2 applications; S1
  label, S2 boss menu layout, S3 office requirement; D2 per-member grants, D3
  promote to own rank. Hire, fire, role edits, cuts and withdrawals need the
  **boss office** by default (the server's own position, `OfficeRadius`).
  Every bound is `Config.Organisation.Limits`, and staff may set an
  organisation's own.
- **Funds.** Renewed-Banking's society account for the job when it is
  installed (`Config.Integrations.Banking = 'auto'`), this resource's ledger
  otherwise (or with `'none'`), **chosen once**, the first time the organisation is read, and kept
  (changing `Banking` later does not move them). While the bank is chosen and
  Renewed-Banking is not started, every deposit, withdrawal, bonus and cut is
  refused and the balance shows as unknown: nothing is paid from, or into, a
  ledger the bank does not see. Staff move the funds to the other side with
  `orgFundsBackend`, which carries the balance across in two ledger rows (with
  `abandon`, leaving a bank that is down, nothing is carried). Every movement
  is one ledger row written once, marked with the side it moved, so a retry
  never pays twice and the ledger's balance is only its own rows; money is
  reserved before anything is awaited, so two withdrawals at once never
  overdraw it or pass a day's cap together; only whole amounts above zero ever
  reach Renewed-Banking (it would take a negative one).
- **Cuts.** A share of a member's payout (and of a stake they win, or a buyout
  premium paid to them) goes to the funds. It is shown to the member on every
  board card before they accept (`orgTerms`), echoed back by the accept (a cut
  changed since is refused, `terms_changed`), frozen on the contract at the
  figure checked, and taken out of the payout when it is paid, once per escrow
  line, as cash, bank or a dirty item, and still after a restart with the
  organisation off: what was escrowed is what the member and the funds
  received.
- **Accepting.** With `RequireJobToAccept`, only members may accept (with
  `AcceptNeedsPower`, only roles given *Take contracts*; with `OnDutyOnly`, on
  duty). Members are always held to a suspension, their own and their role's
  limits and access rules, which are only ever stricter than the server's,
  checked one acceptance at a time per member; a check that cannot be made
  refuses the acceptance. A boss pick (K2) answers the same for every member,
  so it never says who placed an anonymous contract.
- **Places.** The boss office, sign-up spots, meeting spots, NPCs and other
  places are set by staff with **Use my position** (the server reads where the
  staff member stands) and drawn as ox_target spots only for the players who may
  use them: sign-up spots for everybody, the rest for members. A boss may move
  the office near staff's point, and place sign-up and meeting spots, where they
  stand, never in a safe zone.
- **The phone's Organisation tab.** Shown in the app's tab bar (as *Org*)
  only while the organisation is on and the board says it is for this
  player: a member, an applicant, an invited player, or a player standing at
  a sign-up spot (who applies from it). Anybody else has the same five tabs
  as before, and nothing more is asked of the server. A member sees the
  organisation, their role (and codename), the board notice, their cut and,
  with payroll on, their salary. A boss sees a **boss menu** with only the
  screens of the powers the server says they hold: **Members** (hire by the
  ID over a nearby player's head, fire, set a role, suspend, limits, a
  codename, their own grants and denies), **Roles** (create, rename, delete,
  pay, salary, and a powers checklist where a power they do not hold is
  greyed as *Staff have not given you this*), **Money** (the funds and ledger,
  deposit, withdraw, bonus, every cut with its staff bound), **Contracts**
  (access rules, cooldowns, boss picks), **Places** (the office, sign-up and
  meeting spots, placed where they stand: the server reads the position, the
  phone sends none), **Notices**, **Applications** and **Settings** (the
  label, the menu's names, the office rule). Every write takes two taps; every
  refusal is the server's own words; a power that needs the office is greyed,
  with why, while the server does not see them there.
- **Codenames** (`Config.Organisation.Codenames`, off as shipped). A member
  picks their own codename in the tab, or a boss holding M7 gives one to a
  member below them (then only the boss or staff change it). Each is checked
  on the server: `CodenameMinLength` to `CodenameMaxLength` characters,
  letters, digits, spaces, `-` and `_`, none of `CodenameBlocked`, and it may
  not read as another member's codename or as any character's name (every
  member's and applicant's, and every player's in the city when it is set).
  Both sides are folded before they are compared: any case, separators
  (spaces, `-`, `_`, punctuation) dropped, and the look-alikes `1`/`l`/`i`,
  `0`/`o`, `3`/`e`, `4`/`a`, `5`/`s`, `7`/`t`, `8`/`b` (also read as `a` and
  `ate`), `@`/`a` and `$`/`s` read as one, so `Po1ice`, `Admln` and `P 11`
  are caught. A member's own change waits
  `Config.Organisation.Limits.CodenameCooldownMinutes`. It is shown in the
  organisation's roster and, to a placer (and a target where names are
  shown), in place of the hitman's name, only where that name would have been
  shown at all, and always marked as one: `Viper (codename)`. A hitman who
  took a contract anonymously is still an operative, and nobody in the
  organisation is told the name behind it. The name shown is kept with the
  contract when it is taken (`crimson_org_splits.shown_name`), so leaving,
  being fired, a changed or cleared codename, or codenames turned off later
  never shows the real name on a contract that showed the codename.
- **Payroll** (`Config.Organisation.Payroll`, off as shipped). A boss holding
  P3 sets each role below them a salary, up to
  `Config.Organisation.Limits.SalaryMax` or the lower maximum staff set for
  that role (`orgSalary` with `max`). A boss's change is paid from the pay day
  after the next one (the roles screen says so) and is on the record
  (`org_salary`, then `org_salary_applied`); a change staff make takes effect
  at once. What is paid is always held to those two bounds as they are on
  the pay day, so lowering either lowers a salary already set. Every
  `PayrollDays` each member is paid their role's salary from the funds into
  their bank: one ledger row per member and pay day, by a reference made of
  both, so a restart part-way pays nobody twice and the funds fall by exactly
  what the members gained; a marker row follows once the bank took it. A
  salary the funds cannot cover is skipped and the member told (and those
  who can see the funds); the rest are still paid. A member suspended on pay
  day is skipped and told unless `Config.Organisation.PaySuspended`, and one
  pay day pays at most `Config.Organisation.Limits.PayrollPerDayMax` in all
  (0: no cap beyond each role's; members past it, from the lowest rank up,
  are skipped and told). Where the bank refuses a salary it goes back to the
  funds; a give-back that fails is on the record
  (`org_payroll_refund_failed`) and tried again every tick until it lands
  (`org_payroll_refunded`). If the server stops after a salary left the funds
  and before the bank's answer was marked, the next run never pays it again
  on a guess: it is on the record (`org_payroll_unconfirmed`) and left for
  staff in the review queue (`/ch-stuck`, kind `org_payroll_unconfirmed`):
  check the member's bank, then pay or dismiss. The pay day is kept with
  the organisation, so a restart neither skips nor repeats one; a server down
  for longer than a period pays once, not for every period missed. Until the
  pay day the maintenance tick compares one number. Every pay day is on the
  record (`org_payroll_run`, `org_payroll_skipped`).
- **Organisation extras** (server/org/extras.lua). Six more switches under
  `Config.Organisation`, each off as shipped and each needing the organisation
  on. Every boss side is its own row in Boss permissions, off until staff
  allow it; staff do all of it from the panel (Hitman organisation, **Work &
  channel**); every write takes two clicks or taps and is on the record.
  - **Contracts to the organisation** (`OrgContracts`). The placer ticks
    *Send to the organisation* on the form. The contract is placed as any
    other (the same charges, rules and refusals), then held off the open
    board while a boss holding **K4 Assign organisation contracts** gives it
    to one member and that member takes it, `AssignMinutes` each; then it
    goes on the open board and the placer is told. **K5 Reassign** moves it
    to another member or sends it to the open board at once. Only the member
    it is assigned to sees it on the board and may take it. The organisation
    sees what a board card shows (the target's name, the worth, the rule),
    never who placed it, and the placer is never told who took it beyond
    what any contract says.
  - **Accept approval** (`AcceptApproval`). A member's accept worth more than
    `ApprovalAbove` (0: every accept), or any accept of a member on probation
    (`ApprovalProbation`), waits for a boss holding **K6 Approve accepts**
    (never one's own; only below the boss's rank). Nothing is taken while it
    waits. Approved, the accept runs then with every rule checked again, the
    stake and the fee the page showed included; refused, or not answered in
    `ApprovalMinutes`, nothing was ever taken, so the stake stays with the
    member, who is told.
  - **Probation** (`Probation`). Members at or below `ProbationMaxGrade` take
    only contracts worth up to `ProbationMaxReward`, none with a stake
    (`ProbationNoStake`), until `ProbationCompletions` completions counted on
    their record from when probation began, or a boss holding **M8 End
    probation** signs them off. Staff may put a member on probation again.
  - **Duty** (`Duty`). Members clock in and out in the tab (only at the boss
    office with `DutyAtOffice`). Only members on duty are assigned, see and
    take the organisation's contracts. Where the job is their primary one,
    qbx_core is told (SetJobDuty, through the framework adapter), and a duty
    change made at a qbx duty point is taken in. A boss holding **M9 Force off
    duty** sends a member below them off duty. A character in again starts
    off duty.
  - **Private channel** (`Channel`). A message channel inside the
    Organisation tab: plain text up to `ChannelMaxLength` characters, no
    links or markup, `ChannelPerMinute` messages a member a minute, kept
    `ChannelRetentionDays` (table `crimson_org_messages`). A boss holding **N3
    Moderate channel** removes messages of members below them and mutes one
    for up to `Config.Organisation.Limits.ChannelMuteMaxHours`. The record
    keeps who wrote and how long, never the words.
  - **Dossiers** (`Dossiers`). A boss holding **K7 Write dossiers** attaches
    notes (up to `DossierMaxLength`), one of the organisation's meeting spots
    and the rules of engagement to an assigned organisation contract. Only its
    member reads it, in the tab. It has no field about the target, and notes
    holding a citizen id of the target or the placer are refused: a dossier
    never tells the hitman more about who the target is than the card does.
- **Organisation extras 2** (server/org/extras2.lua). Four more switches under
  `Config.Organisation`, each off as shipped and each needing the organisation
  on, as the extras above: every boss side is its own row in Boss permissions,
  off until staff allow it; staff do all of it from the panel (Hitman
  organisation, **Armory**, **Record & discipline** and **Applications**);
  every write takes two clicks or taps and is on the record. Nothing here
  shows a placer or a target.
  - **Armory** (`Armory`). An ox_inventory stash of the organisation's
    (`ArmorySlots`, `ArmoryWeight`), reached only through the Organisation
    tab: it is registered under a group nobody holds, so ox_inventory's own
    screen never opens it and every move goes through the limits here.
    Members put in the items staff allow (`ArmoryItems`; empty, nothing goes
    in) and take out up to their role's limit a day; a boss holding **A2 Set
    armory limits** sets a role's limit below their own rank, up to
    `Config.Organisation.Limits.ArmoryWithdrawMax`, and one holding **A1 Manage
    armory** reads the armory's log and takes out up to
    `Config.Organisation.Limits.ArmoryManagePerDay` more a day. Items go in and
    out only at the boss office with `ArmoryAtOffice`; a member suspended from
    contracts takes nothing out. An item is taken from one side before it is
    given to the other, and given back where the other side refuses it, so
    nothing is made or lost; a give-back that fails is on the record
    (`org_armory_refund_failed`). Staff stock it with an allowed item, take
    items out (for good) and set any role's limit. With
    `Config.Integrations.Inventory` set to `none`, or no inventory script
    started, the armory is off and the console says so in one line. The
    limits a day are kept in memory: a restart starts the day again.
  - **Record and leaderboard** (`Stats`). Each member's completions, failures,
    earnings and reliability in the organisation (completions out of
    completions and failures, once `StatsMinForRate` are in), counted from the
    record's own outcomes from when it is on, and a leaderboard by
    completions. It fills the tab's **Your record** card. Players see how long
    a member usually takes as a band (under `StatsBandShort` minutes, up to
    `StatsBandMid`, up to `StatsBandLong`, over it), never the exact time, and
    no other member's money; a boss holding **M10 View member stats** sees
    every member's failures and earnings; staff see the average minutes too,
    and may reset one member's counts or everybody's. `StatsLeaderboard` off
    shows the leaderboard only to M10 holders and staff.
  - **Discipline** (`Discipline`). A boss holding **M11 Issue strikes** gives a
    member below them a strike or a written warning with a reason (up to
    `Config.Organisation.Limits.StrikesPerDay` a day); the member is told and
    sees it on their record, never which boss gave it. A strike counts for
    `StrikeDecayDays`; at `StrikeSuspendAt` standing strikes the member is
    barred from contracts for `StrikeSuspendHours` (the same bar as Suspend),
    and at `StrikeDemoteAt` they move one role down (never the last top boss);
    0 turns either off. Suspension and demotion by hand stay **M5** and
    **M4**. Only staff overturn a strike or warning: it stays on the record,
    marked, no longer counts, and a bar the strikes made is lifted once they
    fall below the mark (a demotion stays: staff move them back with Set
    role); the member is told.
  - **Recruitment** (`Recruitment`). A boss holding **N4 Edit application
    form** sets the questions an applicant answers (up to `RecruitQuestions`,
    each answer up to `RecruitAnswerMax` characters, plain text). A boss
    holding **N2 Applications** reads the answers, writes an interview note
    (up to `RecruitNoteMax`), and hires or declines as with any application;
    the applicant is told. Against spam, a declined applicant waits
    `RecruitCooldownHours` before they apply again, and the organisation takes
    at most `RecruitPerHour` applications an hour.
- **Organisation extras 3** (server/org/init.lua, server/org/extras3.lua).
  More switches under `Config.Organisation`, each off as shipped and each
  needing the organisation on, as the extras above; staff do all of it from the
  panel; every write takes two clicks or taps and is on the record.
  - **Several organisations** (`SeveralOrganisations`, `MaxOrganisations`).
    Staff add more hitman organisations (rival crews) in Hitman organisation,
    Setup, **Organisations**: each is its own qbx_core job (the job name staff
    give, lower case, never another's) with its own roles (made from
    `Config.Organisation.Roles`), members, funds (its own society account or
    ledger rows), places, Boss permissions, settings and log, all kept by its id
    (the job name). The card picks which one every Hitman organisation, Boss
    permissions and Locations view works on (the ops carry `org`; none is the
    first, the config.lua one). A citizen is a member of one at most: a hire,
    an invite, an application or a job change made elsewhere into a second is
    refused (`org_other_org`). A member's phone always works on their own; an
    outsider picks which one to look at and apply to; a placer sending a
    contract to an organisation picks which. Each pay day, extras tick, channel
    and contract held is its own. Staff take one off the list only when it has
    no member, empty funds and nothing held; its rows stay, and adding its job
    name again brings it back. Off: only the first is read, exactly as before;
    the others are kept for when it is on. `MaxOrganisations` (1-10) counts the
    first.
  - **Reputation and tiers** (`Reputation`). The organisation's standing:
    `RepCompletion` points for each member's completion, `RepFailure` off for
    each failure (counted from the record's own outcomes from when it is on),
    less `RepHeat` for every point of heat its members carry now
    (`Config.Record.Heat`). `RepTiers` names the tiers, one line each as
    `'points, label, most an accept is worth'` ($, 0 = no cap): a member's
    accept of a contract worth more than their organisation's tier allows is
    refused in words (`org_tier`); a higher tier unlocks bigger ones. Members
    see the tier, the points and what the next needs; staff see how it is made
    up and adjust it (with a reason) in **Reputation, drops & garage**.
  - **Dead drops** (`DeadDrops`, `DeadDropMinutes`, `DeadDropUnclaimed`). Staff
    set the organisation's dead drop in Locations (**Dead drops**); a boss
    holding **P4 Choose payout method** (or staff) picks *the usual way* or
    *the dead drop*. With the dead drop, a member's payout (baseline, bonus,
    items included) waits in escrow, owed to them and queued, until they use
    the drop (its ox_target option) within `DeadDropMinutes`; unclaimed, it is
    handed over the usual way (`'pay'`) or given back to the placer
    (`'refund'`). It is a payout check (server/payout.lua) on the escrow's own
    give, so only the escrow's paths move money: what was escrowed is what the
    member (and the funds' cut) or the placer receive. A restart keeps every
    drop. Staff hand one over or refund it at once.
  - **Territory** (`Territory`, `TerritoryMinutes`, `TerritorySightMetres`;
    needs `OrgContracts`). Staff draw zones in Locations (**Territory**: a
    centre and a radius). A contract placed (not sent anywhere) on somebody
    standing in an organisation's zone, while one of its members stands within
    `TerritorySightMetres` of them in the same routing bucket, is held for that
    organisation for `TerritoryMinutes` as a contract sent to it, then goes on
    the open board. **Privacy:** the target's position is read once, on the
    server, and acted on only when a member can already see the target
    (standing beside them); it is never stored, sent or logged; no zone is ever
    sent to a game; the organisation is told exactly what it is told of a
    contract a placer sent ("A contract was sent to the organisation"), so it
    cannot tell a territory hold from a placer's choice; and the placer is told
    nothing, then or when it goes on the open board, so they learn nothing of
    where the target was. The staff log has the hold, with no position.
  - **Garage** (`Garage`, `GarageVehicles`, `GarageMaxOut`, `GarageKeepMinutes`,
    `GarageReturnMetres`). Staff set the garage spot (Locations, **Garage**) and
    approve models; a boss holding **V1 Manage garage** chooses which of them
    are offered. A member standing at the spot takes one out in the tab (one at
    a time, `GarageMaxOut` for the organisation): made by the server through
    the garage adapter (`Config.Integrations.Garage`, `onesync`: server
    vehicles, nobody's own car, kept by the server, a random plate, locked,
    keys from the keys adapter), and returned near the spot. Out for
    `GarageKeepMinutes`, or its member gone from the city or the organisation,
    it is taken away; every one goes at the resource's stop. Staff take one
    away from the panel. With the adapter `none`, the garage says so.
  - **Internal contracts** (`InternalContracts`, `InternalExpireHours`). A boss
    holding **K8 Request internal contract** asks staff for a contract on a
    member below them who went rogue: a reason and the cash reward. Nothing is
    placed or taken until staff approve it in the panel; it is then placed in
    the boss's name, with their own money, through the ordinary placement, so
    every limit, cap and anonymity rule applies (a boss away or short is told,
    and the request stays open). Declined or run out, the boss is told.
  - **Handler** (`Handler`, `HandlerAssigns`). The organisation's NPC spots
    (Locations, NPC spots; drawn only within `DrawMetres`, nothing runs while
    far) brief a member who talks to them: their assigned contract, its dossier
    and the notice; with `HandlerAssigns`, a member on duty with nothing
    assigned is given the oldest contract waiting for the organisation.
  - **Activity log** (`ActivityLog`, `ActivityKeep`). What members and bosses
    did (accepts, completions and failures, deposits, withdrawals and bonuses,
    grants, hires and fires, armory moves, vehicles), for a boss holding **M12
    View org log** and for staff: members by the name the organisation shows
    (codename where on), staff as *Staff*, never a citizen id, a placer or a
    target.

**server.cfg.** Keep `set qbx:cleanPlayerGroups false` (true deletes the
organisation's members at every qbx_core start) and `set
qbx:enableGroupManagement false` (qbx_management would take over the job), set
`set qbx:max_jobs_per_player 2` or more so a player with a job can join, and
`ensure crimson-hitman` before `ensure Renewed-Banking` (it reads the job list
once, as it starts). Each one wrong is said once at the start and in
`/ch-diag`. bankAuth is never set, and isboss only with
`Config.Organisation.QbxBossFlag`: Renewed-Banking's bank screen,
qbx_management and lb-phone's Services boss tab check far less than this
resource does.

#### Organisation requests (admin panel)

Through the panel's one way in, as every op in *Panel requests*; reads need a
staff ACE, writes `crimson.admin` itself. The panel's Hitman organisation,
Boss permissions and Locations sections use them; every write takes two
clicks, naming what it sets.

| Op | Level | What it does |
|---|---|---|
| `orgGet` | read | Everything: setup, roles, members (by handle), Boss permissions, cuts, bounds, funds, applications, warnings (its spots: `placeList`) |
| `bossPermsGet` | read | The Boss permissions matrix |
| `orgFunds` | read | Balance and ledger |
| `orgSetup` | write | Create / sync the job in qbx_core |
| `orgRename`, `orgLayout`, `orgNotice` | write | Label, boss menu layout, board notice |
| `orgRoleSet`, `orgRoleRemove`, `orgRolePowers` | write | Add or edit a role, delete an empty one, set its powers |
| `orgMemberHire`, `orgMemberRole`, `orgMemberFire` | write | Hire (lookup handle or exact citizen id), set a role, fire with a reason |
| `orgMemberSuspend`, `orgMemberLimits`, `orgMemberOverride` | write | Bar from contracts, limits, a grant or deny, lock and codename |
| `bossPermsSet`, `bossPermsRevokeAll`, `bossLimits`, `bossOfficeRule` | write | Boss permissions cells (one or a batch), revoke a column, bounds, the office list |
| `orgCuts` | write | A cut: payout, role, member, stake, buyout |
| `orgFundsMove` | write | Deposit, withdraw or bonus, with a reason and a nonce |
| `orgFundsBackend` | write | Keep the funds in the ledger or Renewed-Banking (`backend`), the balance carried across; `abandon` leaves a bank that is down |
| `orgAccess`, `orgPick` | write | A role's access rules; a boss pick |
| `orgSalary` | write | A role's salary (`amount`), or the most it may be paid (`max`, false clears it): payroll |
| `orgApplication` | write | Accept or reject an application |
| `orgChannelGet` | read | The channel's newest messages (`limit`, at most 100); `orgGet` carries the last 50 under `extras` |
| `orgContractAssign` | write | Assign a contract sent to the organisation to a member (`member`), or send it to the open board (`release`) |
| `orgAcceptDecide` | write | Approve or refuse an accept waiting for approval (`id`, `approve`) |
| `orgProbation` | write | End a member's probation (`passed` true) or put them on it again (false) |
| `orgDutyOff` | write | Send a member off duty |
| `orgChannelPost`, `orgChannelRemove`, `orgChannelMute` | write | Post as Staff, remove a message, mute a member (`hours`, 0 lifts it) |
| `orgDossier` | write | A dossier on an assigned organisation contract (`notes`, `spot`, `rules`), or `clear` |
| `orgArmoryGet` | read | The armory: what it holds, the allow-list, each role's limit a day and its log; `orgGet` carries it under `extras2` |
| `orgArmoryLimit` | write | A role's armory limit a day (`grade`, `count`; 0 is none) |
| `orgArmoryStock` | write | Stock the armory with an allowed item (`item`, `count`), or take items out of a slot for good (`remove`, `slot`, `count`) |
| `orgStatsGet` | read | The leaderboard with every number, the average minutes included |
| `orgStatsReset` | write | Reset one member's counts (`member`), or everybody's (`all`) |
| `orgStrike` | write | A strike or a written warning (`kind`) with a `reason` |
| `orgOverturn` | write | Overturn a strike or warning (`id`) with a `reason`; the member is told |
| `orgRecruitForm` | write | The application form's `questions` (a list; empty clears it) |
| `orgInterviewNote` | write | An interview note on an open application (`id`, `text`), or `clear` |
| `orgCreate` | write | Add an organisation (`job`, `label`): Several organisations |
| `orgRemove` | write | Take one off the list (`id`): no members, empty funds, nothing held |
| `orgRepAdjust` | write | Move the reputation by `points` (either way), with a `reason` |
| `orgPayoutMethod` | write | Payouts the usual way or at the dead drop (`method`: `bank` or `deaddrop`) |
| `orgDropSettle` | write | Settle a dead drop now (`key`; `how`: `release` or `refund`) |
| `orgGarageOffer` | write | Which approved models the organisation offers (`models`, a list) |
| `orgGarageRemove` | write | Take a member's garage vehicle away (`member`) |
| `orgInternalDecide` | write | Approve (placed by the boss who asked) or decline an internal contract request (`id`, `approve`) |
| `orgActivityGet` | read | The activity log (`limit`); `orgGet` carries the last 50 under `extras3` |

With Several organisations on, every op above (and Boss permissions' and
Locations' `place*` ops) takes `org`, the id of the one it works on; none is the
first, and an id that names none is refused.

#### Organisation requests (phone)

lb-phone app requests through the app's own gate, `org` and `orgWrite` rate
limits; each needs the power named, held after Boss permissions, at the office
where it needs one. The app's Organisation tab asks them; the board also shows
a member their cut on every card, an invited player their invite, with Accept
and Decline (`orgInviteAnswer`), and says whether the tab is for this player
(`orgTab`).

| Request | Power | Request | Power |
|---|---|---|---|
| `orgMine` | anybody | `orgApply` | anybody, at a sign-up spot |
| `orgMembers` | M1 | `orgRoles`, `orgSpots` | a member |
| `orgHire` | M2 | `orgFire` | M3 |
| `orgSetRole` | M4 | `orgSuspend` | M5 |
| `orgMemberLimits` | M6 | `orgMemberGrant` | D2 |
| `orgRoleCreate` | R1 | `orgRoleEdit` | R2 |
| `orgRoleDelete` | R3 | `orgRolePowers` | R4 |
| `orgRolePay` | P1 | `orgBonus` | P2 |
| `orgSetCut` | C1-C5 | `orgDeposit` | C6 |
| `orgWithdraw` | C7 | `orgFunds` | C8 |
| `orgAccess` | K1 | `orgPick` | K2 |
| `orgRoleCooldown` | K3 | `orgPlaceHere` | L1-L3 |
| `orgRemoveSpot` | L2, L3 | `orgNotice` | N1 |
| `orgApplications`, `orgDecide` | N2 | `orgRename` | S1 |
| `orgLayout` | S2 | `orgOfficeRule` | S3 |
| `orgInviteAnswer` | the invited player | `orgCodename` | a member's own; M7 for another's |
| `orgSalary` | P3 | `orgWork` | K4, K5, K6 or K7 |
| `orgAssign` | K4 (K5 to move one) | `orgRelease` | K5 |
| `orgApprove` | K6 | `orgDossier` | K7 |
| `orgProbationEnd` | M8 | `orgForceOff` | M9 |
| `orgDuty` | a member's own | `orgChannel`, `orgChannelPost` | a member |
| `orgChannelRemove`, `orgChannelMute` | N3 | `orgArmory`, `orgArmoryPut`, `orgArmoryTake` | a member (A1 to take beyond the role's limit) |
| `orgArmoryLimit` | A2 | `orgStats` | a member (M10 for every number) |
| `orgStrike` | M11 | `orgDisciplineRecord` | a member's own; M11 or M5 for another's |
| `orgRecruitForm` | N4 | `orgInterviewNote` | N2 |
| `orgPayoutMethod` | P4 | `orgGarage`, `orgGarageTake`, `orgGarageReturn` | a member |
| `orgGarageOffer` | V1 | `orgInternalRequest` | K8 |
| `orgActivity` | M12 | | |

With Several organisations on, a member's requests always work on their own
organisation; anybody else's take `org` (the one picked in the tab), or else the
one inviting them, holding their application or whose sign-up spot they stand at.

### Mission steps

**Step markers** (`Config.StepMarkers`, on as shipped) put each step of a
contract on the map of the one party who has to act on it, and nobody else:
never the target, never a bystander, never the page. Every marker is a fixed
point the server recorded (a death, an arm, a pin, a staff spot), never
anybody's live position, so no marker can say where a hidden party is. Each
comes off on every way its step ends, is drawn again when a player comes back
(their app asks, as it does for tips and meeting points), and costs nothing
while there is none: no thread, no loop, one look on the maintenance tick.

| Marker | Who sees it | Taken off when |
|---|---|---|
| Informant tip (red circle) | The hitman who bought it | Its time runs out, the contract ends, the hitman leaves it |
| Meeting point (yellow) | The placer and every active hitman | Cleared or moved, the last hitman leaves, the contract ends, `Config.Kidnap.MeetingPoint` off |
| Kill to verify (`KillScene`) | The hitman the kill was attributed to, at the body | Verified, lapsed, the target revived, the hitman leaves, the contract ends |
| Handover circle (`Handover`) | The placer and the hitman who armed it, at the point it was armed | The countdown ends in any way |
| Protection pin (`Protection`) | The guard holding the job | The job ends or is cancelled; moved with the pin |
| Body, disposal vehicle, drop-off (`Config.Disposal`) | The hitman disposing of the body | Loaded (body), reached (vehicle), dropped off, timed out, skipped by staff, switched off |
| Broker, informant, organisation spots | As their own features say | As their own features say |

A proof-item handover has no marker: it happens wherever the hitman meets the
placer, and a fixed spot for it would be the placer's position.

**Body disposal** (`Config.Disposal`, off as shipped). With it on and both
spots set, a verified kill (never a live handover or a proof item, and only on
a contract a kill may complete) claims its payout as always, and the payout
waits in escrow for the hitman, as a payout held for proof of intent waits,
until the body is dropped off. The hitman is sent a marker at the body (where
the server recorded the death), the disposal vehicle (`VehicleModel`, a hearse
as shipped) is made by the server at the spawn spot with a marker of its own,
locked, with keys for the hitman alone (qbx_vehiclekeys). They bring it to the
body and choose **Load the body** (ox_target): the server checks that they and
the vehicle are both within `LoadMetres` / `VehicleMetres` of the body. They
drive to the drop-off (its marker appears once loaded) and choose **Drop off
the body**, checked the same way, and the payout is released; the vehicle is
taken away `DespawnSeconds` later. `PayNowPercent` of a cash or bank payout can
be handed over at the kill instead (0 as shipped: all at the drop-off).

- **The body** is a stage the server keeps on the step (at the scene, then loaded), never an ox_inventory item or a prop a player holds: nothing to drop, trade, stash or duplicate, and nothing lost to a death or full pockets.
- **The clock** (`TimeLimitMinutes`) runs only while the hitman is in the city and nothing holds the contract: a staff freeze on any party, the app pause and the restart hold stop it, keep the vehicle where it is, and refuse loading and dropping off. The hitman is told the time left as a band (over 20 minutes, 10 to 20, 5 to 10, under 5); staff see it to the second.
- **On timeout** (`OnTimeout`): `pay` (as shipped, so nobody can grief a hitman out of a kill), `reduced` (they keep `ReducedPercent` of the money; items are paid whole; the rest goes back to the placer) or `refund` (all of it back to the placer).
- **The clock's ceiling** (`MaxHoldMinutes`, 120 as shipped, never below `TimeLimitMinutes`): real minutes from the kill, counted whether the hitman is in the city or not, and through restarts. Past it the step times out as `OnTimeout` says even while the hitman is away (unless staff hold it), and from then on it no longer keeps its target off the board, so a hitman logging off over a body cannot shield the target from every new contract.
- **The vehicle** is a server-made networked vehicle, nobody's own, with no garage row, a random plate (`CH` and six random characters, never one another step's vehicle has, so a key qbx_vehiclekeys gave for an earlier disposal vehicle opens no later one) and a `crimsonDisposal` state bag, so nothing can store or sell it. Left more than `AbandonMetres` behind for `AbandonMinutes`, lost or destroyed, it is taken away and made again at the spawn spot, at most `MaxRespawns` times. It goes when the hitman leaves the city (made again when they are back, not counted) and at every stop; every other loss counts as a respawn, a relog in between or not, so losing it and relogging does not make free vehicles.
- **How the server keeps it** (OneSync entity rules): its orphan mode is set to keep it (`SetEntityOrphanMode(vehicle, 2)`, where the artifact has the native), since a server-made entity is otherwise deleted once nobody is in scope of it, and only this resource deletes it. It is put in the hitman's routing bucket when made, and moved with them if they change bucket, or a hitman in an instance never sees it. Population or cleanup resources that delete vehicles by plate or by distance should leave `crimsonDisposal` vehicles alone; one deleted anyway counts as lost.
- **The target** cannot have a new contract placed on them while their body is being disposed of, whatever `Config.Roleplay.EmsRelisting` says; a revive or a respawn changes nothing about a payout already claimed.
- **A restart** resumes the step where it was (`crimson_rp_rows`, kind `disposal`, in every store); the downtime is not counted. Turned off mid-step, every step finishes and pays at the next tick.

#### Mission steps requests (admin panel)

Through the panel's one way in; reads need a staff ACE, writes `crimson.admin`
itself. The page draws them on Contracts and Home (the steps, **Skip**,
**Respawn vehicle**); its two spots are set in Locations (*Places requests*);
who the hitman is comes only with `crimson.identity`.

| Op | Level | What it does |
|---|---|---|
| `disposalList` | read | Every disposal step: stage, exact seconds left, held, vehicle, respawns; the spots and the rules. Without `crimson.identity`, `held` says only the restart hold, the app pause and a freeze through a party they may see (never one through an anonymous placer or hitman) |
| `disposalSkip` | write | Finish a step (`id`: a step or contract id) as if dropped off: the payout is released |
| `disposalRespawn` | write | Make the vehicle again at the spawn spot (not counted as a respawn) |

#### Places requests (admin panel)

Every map spot staff set lives in one registry (`server/places.lua`), kept as
one row kind (`crimson_rp_rows`, kind `map_place`) in every store, and is set
from Locations. Each kind keeps its own rules: the organisation's `office`
(one; a boss moves it only near staff's point), `signup`, `meeting` (a boss
with L2 / L3 from where they stand, within the limits and the cooldown, never
in a safe zone), `npc` and `place` (staff only); the `broker` and `informant`
NPCs (`Config.Roleplay.NpcPlaces`, off as shipped; off, every write says so;
at most 20 each; their config `Locations` stay the defaults); body disposal's
`disposal_vehicle` and `disposal_drop` (one each; config.lua's `VehicleSpawn`
/ `DropOff` apply while one is not set). One check for every kind: on the map
(x -4500 to 6000, y -6500 to 8500, z -200 to 2000), finite, a heading -360 to
360 (kept 0-360), a name without `<`, `>` or control characters (64 for the
organisation's, 40 for the NPCs'), a radius 0.5 to 50 m where the kind has
one. Reads need a staff ACE, writes `crimson.admin`; every write takes two
clicks. The places that are settings (tip safe zones, the rumours' districts
and zone names, witness heat's areas, the prison zone, the NPCs' default
lists) are settings, marked `place` in the catalogue, and edited in the same
Locations section, with Use my position filling a line.

| Op | Level | What it does |
|---|---|---|
| `placeList` | read | Every kind: its rows, what may be set beside the point, its limit, its config defaults and which it uses, and why it cannot be set now |
| `placeMyPosition` | read | Where your character stands, read by the server (Use my position, for every kind) |
| `placeSet` | write | `kind`, typed `x`, `y`, `z`, `heading` or `here` (read by the server); `label`, `radius`, `blip`, `enabled` where the kind takes them; `id` moves one (a kind with one moves it) |
| `placeRemove` | write | Remove one spot (`id`) |
| `placeReset` | write | Remove every place of the `broker` or the `informant` (`kind`): its config list applies again |

## Permissions

| ACE | Opens | Grant |
|---|---|---|
| `crimson.admin` (`Config.Admin.Ace`) | The panel and every command; every write (settings, money, settling, reviews) | `add_ace group.admin crimson.admin allow` |
| `Config.Admin.ExtraAces` (`command` as shipped) | Reading: the panel's read-only sections, `/ch-diag`, `/ch-timeline`, `/ch-stuck`, `/ch-contracts` | already held by the ACE named |
| `crimson.moderator` (`Config.Admin.ModeratorAce`) | Reading without identities; freeze, suspend, protect, void, move deadlines | `add_ace group.<your moderators> crimson.moderator allow` |
| `crimson.developer` (`Config.Admin.DeveloperAce`) | The Developer section (console, diagnostics, developer settings); `crimson.admin` always has it | `add_ace group.admin crimson.developer allow` |
| `crimson.identity` (`Config.Admin.IdentityAce`) | Who is behind an anonymous party, every citizen id, `/ch-whois` | grant to few: `add_ace identifier.license:<licence> crimson.identity allow` |

Secrets never go in `config.lua` (every player's game downloads it): the
webhooks are `set` convars in `server.cfg`.

## Configuration reference

Every setting in `config/config.lua`, in its sections and order (the admin
panel's), with the value it ships with and its note from the file. Generated
from config.lua (`tests/docs_spec.lua` checks every row). `config/defaults.lua`
holds the same values and only fills a section missing from an older
`config.lua`; it is not the file to edit. Most settings can also be changed
live in the admin panel, which keeps the change over this file.

### Debug and storage

The console output, and where contracts and money are kept. Switching storage mode starts empty in the new one and refuses to start while the old one still holds money (README).

| Setting | Shipped | What it does |
|---|---|---|
| `Config.Debug` | `true` | debug lines in the console and F8; false = only what needs you |
| `Config.Locale` | `'en'` | the language players and staff read: the locales/ file of that name |
| `Config.Database.Mode` | `'mysql'` | 'json' \| 'mysql' \| 'memory' (testing only) |
| `Config.Database.AllowModeSwitch` | `false` | start even though the old mode still holds money |
| `Config.Database.QueryTimeoutSeconds` | `10` | mysql: seconds a statement may go unanswered; 0 = forever |
| `Config.Database.Json.Directory` | `'data'` | folder inside the resource |
| `Config.Database.Json.SyncOnFinancialWrite` | `true` | write money changes to disk at once |

### Other scripts

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

### Rules: Timers

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
| `Config.Holds.RestartPauseBeforeSeconds` | `1800` | pause every contract this long before a txAdmin restart; 0 = off |
| `Config.Holds.RestartMaxHoldMinutes` | `45` | end the pause if the restart has not come by then |

### Rules: Rewards and money

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

### Rules: Limits

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

### Rules: Targeting

Who may open the app and who can be named as a target. Law enforcement, EMS, fire and legal jobs are barred by job type as well as by name; with the whitelisted-job view on they get one read-only screen instead.

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

### Features: Core

The app itself, proposals, notices, messages and calls, progression and the alerts staff get.

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

### Features: Anonymity

What placing or accepting anonymously costs, and the rules that differ by the target's class (`Config.TargetClasses`: `default`, or `whitelisted` for a target on a whitelisted job): anonymity, names shown, and for whom each informant feature is sold (the feature's own `Enabled` still turns it on).

| Setting | Shipped | What it does |
|---|---|---|
| `Config.TargetClasses.default.AllowAnonymousPlacer` | `false` | a contract may be placed anonymously |
| `Config.TargetClasses.default.AllowAnonymousHitman` | `false` | a contract may be accepted anonymously |
| `Config.TargetClasses.default.ShowOperativeNames` | `true` | the target sees a named operative's name |
| `Config.TargetClasses.default.ShowPlacerOnBoard` | `false` | the board names a named placer; off: parties only |
| `Config.TargetClasses.default.Informant` | `true` | the target may buy the target's informant |
| `Config.TargetClasses.default.PlacerInformant` | `true` | the placer may buy the placer's informant |
| `Config.TargetClasses.default.LocationTip` | `true` | a hitman may buy an informant tip |
| `Config.Anonymity.CreatorFee` | `0` | fee to place anonymously; 0 = free |
| `Config.Anonymity.HitmanFee` | `0` | fee to accept anonymously; 0 = free |
| `Config.Anonymity.FeeAccount` | `'bank'` | 'cash' \| 'bank' |
| `Config.TargetClasses.whitelisted.AllowAnonymousPlacer` | `false` | such a contract may be placed anonymously |
| `Config.TargetClasses.whitelisted.AllowAnonymousHitman` | `false` | such a contract may be accepted anonymously |
| `Config.TargetClasses.whitelisted.ShowOperativeNames` | `true` | such a target sees a named operative's name |
| `Config.TargetClasses.whitelisted.ShowPlacerOnBoard` | `false` | the same, on such a contract |

### Features: Intel

Everything a player can learn for money, in one place (README, Intel): three paid look-ups, the target's (who is after me), the placer's (who took it) and the hitman's tip (the target's rough area), the rules over them, going dark, the informant in person and the rumours. Each ships off.

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
| `Config.TargetClasses.whitelisted.Informant` | `false` | such a target may buy the target's informant |
| `Config.TargetClasses.whitelisted.PlacerInformant` | `false` | the placer of such a contract may buy the placer's informant |
| `Config.TargetClasses.whitelisted.LocationTip` | `false` | a hitman on such a contract may buy an informant tip |

### Features: Record

A character's record (README, A hitman's record): the trust a completion earns and how it is scaled, the tiered board, heat and the placer's record.

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

### Features: Advisory

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

### Staff and permissions

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
| `Config.Holds.AppPaused` | `false` | pause the whole app: no placing, no accepting, clocks held |
| `Config.Staff.DailySummary` | `false` | post one count-only summary a day to the staff Discord |
| `Config.Staff.DailySummaryHour` | `6` | the hour it is posted, server time (0-23) |
| `Config.Staff.AlertPlacedPerHour` | `5` | alert past this many placed by one player an hour; 0 = off |
| `Config.Staff.AlertTargetPerDay` | `3` | alert past this many on one target a day; 0 = off |
| `Config.Staff.AlertRefusalsPer10Min` | `30` | alert past this many refusals to one player in 10 min; 0 = off |
| `Config.Staff.RewardChangeMax` | `100000` | most staff may raise or lower a reward by at once ($); 0 = off |
| `Config.Staff.ReassignStake` | `'waive'` | a hitman staff assign: 'waive' (no stake) \| 'charge' |

### Roleplay

Optional roleplay features, each its own block and each off as shipped (README, Optional features). All of them are changed from the admin panel. Places (the broker's and the informant's) are 'x, y, z, heading'.

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
| `Config.Roleplay.NpcPlaces.Enabled` | `false` | the broker and informant stand where staff placed them in the panel's Locations (Use my position); their `Locations` lists stay the defaults while none is set |
| `Config.Roleplay.ReasonQuality.Enabled` | `false` | hold free-text reasons to the rules below |
| `Config.Roleplay.ReasonQuality.MinLength` | `15` | least characters in a reason |
| `Config.Roleplay.ReasonQuality.MinWords` | `3` | least words in a reason |
| `Config.Roleplay.ReasonQuality.LowEffort` | `{ 'rdm', 'idk', 'cuz', … 6 in all }` | words to catch |
| `Config.Roleplay.ReasonQuality.LowEffortAction` | `'refuse'` | 'refuse' \| 'review' (placed, and queued for staff) |

### Improvements

Optional changes to existing features, each its own block and each off as shipped (README, Optional features). All are changed from the panel.

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

### Organisation

The hitman organisation: a real qbx_core job with roles, a boss menu and Boss permissions (README, Optional features). Off as shipped: while it is off no job is registered, nothing is read or written, nothing changes.

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
| `Config.Organisation.Codenames` | `false` | members carry a codename, shown inside the organisation and to placers in place of their name (only where their name is shown at all) |
| `Config.Organisation.CodenameMinLength` | `3` | least characters in a codename |
| `Config.Organisation.CodenameMaxLength` | `20` | most characters in a codename |
| `Config.Organisation.CodenameBlocked` | `{ 'admin', 'staff', 'moderator', … 4 in all }` | words a codename may not contain (any case; spaces, digits and punctuation ignored) |
| `Config.Organisation.Payroll` | `false` | every pay day each member is paid their role's salary from the funds |
| `Config.Organisation.PayrollDays` | `7` | days between two pay days |
| `Config.Organisation.PaySuspended` | `false` | whether a member suspended on pay day is paid that pay day; off, they are skipped and told |
| `Config.Organisation.OrgContracts` | `false` | placers may send a contract to the organisation; a boss assigns it to a member |
| `Config.Organisation.AssignMinutes` | `30` | minutes a contract sent to the organisation waits to be assigned, then to be taken, before the open board |
| `Config.Organisation.AcceptApproval` | `false` | members' accepts above `ApprovalAbove` (or on probation) wait for a boss's approval; nothing is taken while they wait |
| `Config.Organisation.ApprovalAbove` | `25000` | accepts worth more than this wait ($; 0 = every accept) |
| `Config.Organisation.ApprovalProbation` | `true` | every accept of a member on probation waits too |
| `Config.Organisation.ApprovalMinutes` | `15` | minutes an accept waits before it is refused (nothing was taken) |
| `Config.Organisation.Probation` | `false` | new members take only small contracts until their completions are done or a boss signs them off |
| `Config.Organisation.ProbationMaxGrade` | `0` | members at or below this grade are on probation |
| `Config.Organisation.ProbationCompletions` | `3` | completions, counted from when probation began, that end it (0 = only a sign-off) |
| `Config.Organisation.ProbationMaxReward` | `10000` | most a contract taken on probation pays ($) |
| `Config.Organisation.ProbationNoStake` | `true` | no contract with a stake on probation |
| `Config.Organisation.Duty` | `false` | members clock in; only members on duty are assigned, see and take organisation contracts |
| `Config.Organisation.DutyAtOffice` | `false` | clock in only at the boss office |
| `Config.Organisation.Channel` | `false` | a private message channel in the Organisation tab |
| `Config.Organisation.ChannelRetentionDays` | `7` | days a channel message is kept |
| `Config.Organisation.ChannelMaxLength` | `300` | characters in one message (longer is refused, never cut) |
| `Config.Organisation.ChannelPerMinute` | `6` | messages one member may send a minute |
| `Config.Organisation.Dossiers` | `false` | a boss attaches notes, a meeting spot and the rules of engagement to an assigned organisation contract |
| `Config.Organisation.DossierMaxLength` | `600` | characters in a dossier's notes |
| `Config.Organisation.Armory` | `false` | an ox_inventory stash of the organisation's, reached only through the app |
| `Config.Organisation.ArmoryItems` | `{}` | the item names allowed in it; empty = none |
| `Config.Organisation.ArmoryAtOffice` | `true` | items go in and out only at the boss office |
| `Config.Organisation.ArmorySlots` | `50` | slots in the stash |
| `Config.Organisation.ArmoryWeight` | `100000` | most weight the stash holds (grams) |
| `Config.Organisation.Stats` | `false` | each member's record in the organisation, and a leaderboard |
| `Config.Organisation.StatsLeaderboard` | `true` | every member sees the leaderboard; off, only bosses holding View member stats |
| `Config.Organisation.StatsMinForRate` | `3` | completions and failures before a reliability is shown |
| `Config.Organisation.StatsBandShort` | `30` | the time bands players see: the first edge (minutes) |
| `Config.Organisation.StatsBandMid` | `120` | the second edge (minutes) |
| `Config.Organisation.StatsBandLong` | `480` | the last edge (minutes); over it is the last band |
| `Config.Organisation.Discipline` | `false` | strikes and written warnings |
| `Config.Organisation.StrikeDecayDays` | `30` | days a strike counts |
| `Config.Organisation.StrikeSuspendAt` | `3` | standing strikes that bar a member from contracts (0 = never) |
| `Config.Organisation.StrikeSuspendHours` | `48` | hours that bar lasts |
| `Config.Organisation.StrikeDemoteAt` | `0` | standing strikes that move a member one role down (0 = never) |
| `Config.Organisation.Recruitment` | `false` | an application form with a boss's questions, and interview notes |
| `Config.Organisation.RecruitQuestions` | `5` | questions on the form at most |
| `Config.Organisation.RecruitAnswerMax` | `300` | characters in one answer (longer is refused, never cut) |
| `Config.Organisation.RecruitNoteMax` | `500` | characters in an interview note |
| `Config.Organisation.RecruitCooldownHours` | `24` | hours a declined applicant waits to apply again |
| `Config.Organisation.RecruitPerHour` | `10` | applications the organisation takes an hour |
| `Config.Organisation.SeveralOrganisations` | `false` | staff may add more organisations, each its own job |
| `Config.Organisation.MaxOrganisations` | `3` | organisations at most, the first included (1-10) |
| `Config.Organisation.Reputation` | `false` | the organisation's reputation, in tiers that unlock bigger contracts |
| `Config.Organisation.RepCompletion` | `10` | points a member's completion earns |
| `Config.Organisation.RepFailure` | `15` | points a member's failure costs |
| `Config.Organisation.RepHeat` | `2` | points off for each point of heat members carry now |
| `Config.Organisation.RepTiers` | `{ '0, Unknown, 25000', '100, Known, 75000', '300, Trusted, 200000', … 4 in all }` | 'points, label, most an accept is worth ($; 0 = no cap)' |
| `Config.Organisation.DeadDrops` | `false` | payouts may be left at a staff-set dead drop to collect |
| `Config.Organisation.DeadDropMinutes` | `60` | minutes a member has to collect it |
| `Config.Organisation.DeadDropUnclaimed` | `'pay'` | 'pay' (handed over as always) \| 'refund' (back to the placer) |
| `Config.Organisation.Territory` | `false` | staff-drawn zones: the organisation gets first refusal (needs OrgContracts) |
| `Config.Organisation.TerritoryMinutes` | `5` | minutes the contract is held for it first |
| `Config.Organisation.TerritorySightMetres` | `75.0` | a member this close to the target, who can see them, is needed |
| `Config.Organisation.Garage` | `false` | staff-approved vehicles members take out at the garage spot |
| `Config.Organisation.GarageVehicles` | `{}` | the models staff approve (model names); empty = none |
| `Config.Organisation.GarageMaxOut` | `3` | vehicles out at once for the organisation |
| `Config.Organisation.GarageKeepMinutes` | `60` | minutes before a vehicle out is taken away |
| `Config.Organisation.GarageReturnMetres` | `15.0` | how near the garage spot a vehicle is returned |
| `Config.Organisation.InternalContracts` | `false` | a boss may ask staff for a contract on a rogue member |
| `Config.Organisation.InternalExpireHours` | `24` | hours a request waits for staff |
| `Config.Organisation.Handler` | `false` | the organisation's NPC spots brief members in the world |
| `Config.Organisation.HandlerAssigns` | `true` | and hand out the oldest contract waiting for the organisation |
| `Config.Organisation.ActivityLog` | `false` | an organisation-only log of what members and bosses did |
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
| `Config.Organisation.Limits.SalaryMax` | `1000` | most salary a boss sets per role per pay day ($); staff may set a lower one per role |
| `Config.Organisation.Limits.PayrollPerDayMax` | `0` | most paid in salaries in all on one pay day ($); members past it are skipped and told; 0 = no cap beyond each role's |
| `Config.Organisation.Limits.CodenameCooldownMinutes` | `1440` | minutes between two changes a member makes to their own codename |
| `Config.Organisation.Limits.ChannelMuteMaxHours` | `24` | longest a boss mutes a member in the organisation channel (hours) |
| `Config.Organisation.Limits.ArmoryWithdrawMax` | `10` | most a boss lets each member of a role take out of the armory a day (items) |
| `Config.Organisation.Limits.ArmoryManagePerDay` | `20` | most a boss holding Manage armory takes out beyond their role's limit a day (items) |
| `Config.Organisation.Limits.StrikesPerDay` | `5` | strikes and written warnings one boss gives a day |

### Mission steps

Map markers for each step of a contract, to the one party who acts on it (README, Optional features), and body disposal: a verified kill paid once the body is dropped off. Disposal ships off; its spots are set by staff in the admin panel (Locations) or below.

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

### Advanced and developer

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

## Performance

What every loop and the busiest requests cost, measured with the test
harness on a city of **200 live contracts and 64 players** (`mysql` / `json`;
the harness runs `mysql`'s statements in Lua, so read its statement counts
rather than its milliseconds). `/ch-diag` lists every job with this server's
own worst, average and last times and its interval. `tests/loops_spec.lua`
and `tests/handlers_spec.lua` pin these figures.

### The loops

Every loop, timer and tick job, with its interval, the deadline it guards,
what it cost measured off and on, and why it cannot reasonably cost less,
is in [docs/dev/loops.md](../docs/dev/loops.md). In short: nothing runs per
frame while idle, every optional feature costs its job one comparison while
off, and the loops that can sleep until something is due or something
happens do.

### What resmon should show

A player's `resmon` (F8, `resmon 1`) line for `crimson-hitman` should read
**0.00 to 0.01 ms** with the phone put away and nothing near: one thread a
second (the death watcher, a few natives), one every 15 s (the app
heartbeat), and the mask watcher a second only with
`Config.Targeting.AllowNearby` on. Nothing draws per frame, and the phone
page runs no timer while it is put away.

It goes up, and comes back down, with:

- **the app open**: its requests and redraws, a few hundredths of a ms
  while you tap, more for a moment as a board opens; once a second a
  handover's poll while one runs;
- **a roleplay NPC near** (`Config.Intel.Rumours`,
  `Config.Intel.InPerson`): the ped is made within 80 m, a spike as
  its model loads, then a distance check a second; nothing with both off;
- **the admin panel open** (staff only): every frame for its Escape guard,
  and the overview every ten seconds; nothing once it is closed.

To check: stand somewhere quiet with the phone put away, run `resmon 1` in
F8 and read the line for `crimson-hitman` (the CPU msec column); open the app
and watch it rise and fall back once you put it away. The server's own
share is in `/ch-diag` (F8 or the server console): every maintenance job with
how often it runs and its worst, average and last times (see above).
`ch-diag <player>` also asks that player's app what it has seen, which
helps when one player's figure is high and nobody else's is. A figure that
stays high with the phone put away and no NPC near is worth reporting with
both.

### The requests

Store calls one request makes (on `mysql`, each an awaited statement), before
the performance rounds and now:

| Request | Store calls, before → now |
|---|---|
| Board, nothing changed since the last viewer | 232 → 0 (read once per change, shared by every viewer) |
| Board, the first viewer after a change | 232 → 3 |
| Mine: placer / operative / target | 43 / 48 / 53 → 9 / 3 / 23 |
| Mine with a long history | the whole history three times → the live contracts only |
| Whitelisted-job view | 2 → 1 |
| Admin panel: a player, their history, a search (92 contracts) | 95, 187, 93 statements → 4, 5, 2 |
| Admin panel: Contracts left open | the whole table every 5 s → only after a write or a prune |
| Placing a contract | both players' whole history → the live contracts and those inside the longest wait |

A thousand requests in a busy evening's mix (a write every tenth): `json`
1.3 s → 0.45 s, `mysql` (harness) 24.6 s → 3.2 s. Several contracts are read
in one statement (`readEscrowMany`, `readHitmenMany`), pushes to a player are
one per tick, and every query is served by an existing index.

## Troubleshooting and /ch-diag

Start with **`/ch-diag [player]`** (F8 or the server console, or **Tools →
Run the diagnosis** in the panel). It says whether the app is closed while
boot recovery runs or failed, whether the database answers, how long ago each
loop ran, every setting that needs attention, and, for a player, what each of
the app's reads answers for them and why the app is or is not showing.

**`/ch-diag config`** (or **Developer → Health → Check the config** in the
panel) is the config check alone: every value out of range or invalid (what
the start-up checks said at this start, and what they say of the settings in
force now), every other script a switched-on feature needs and does not have
(`Config.Integrations`), every staff ACE `group.admin` does not hold and the
staff commands it may not run, and the risky combinations (debug output on,
`memory` storage, `AllowModeSwitch` left on, the identity ACE the same as the
staff one, the staff tools off, alerts to Discord with no webhook, the version
check on with no address). Each is one plain line with the fix under it; it
reads only and changes nothing.

| Issue | Solution |
|---|---|
| A player cannot find the app | It is in the phone's App Store; each player downloads it. `Config.App.DefaultInstalled = true` puts it on every eligible phone. Barred jobs see only the whitelisted-job view. `/ch-diag <player>` says why it is not showing |
| A kill does not complete a contract | As shipped `Config.Completion.Fulfilment = 'alive'`: only a live handover completes one. Set `'either'` for kills; contracts already placed keep their rule |
| A new character can be targeted, or an old one cannot | `/ch-diag <player>` shows what the playtime rule reads for them; correct one character's hours under **Players** |
| The informant is not offered | Each informant ships off; the target's is never offered to a whitelisted-job member; the placer's only while an operative they do not know is on the contract |
| A staff command typed in chat answers nothing | It answers in your F8 console |
| *Not authorised* | Grant the ACE ([Permissions](#permissions)); the server checks on every request |
| The console prints `N setting(s) need attention` | `/ch-diag` lists each in full, or set `Config.Debug = true` |
| Not sure the config is right | `/ch-diag config` lists every value out of range, missing script, missing ACE and risky combination, each with its fix |
| The console says nothing at all | `Config.Debug = false`: a sound start says nothing |
| `BOOT RECOVERY FAILED` | Recovery raised (the text says why); the app and money writes stay closed until a restart that recovers. Fix the cause and restart |
| *The server's records did not answer in time* | `mysql` was unreachable or held past `Config.Database.QueryTimeoutSeconds`; payments caught are settled once it answers. Wait for `/ch-diag` to say `database: answering` |
| `still waiting … for … resource(s) to start` | `qbx_core` is not started, or runs under another name |
| The app stopped after restarting `qbx_core` or `oxmysql` | `ensure crimson-hitman` |
| `integration <kind> off (...)` in the console | That script is not started, or `Config.Integrations.<Kind>` is `'none'` or names no adapter: what the line says is off. Start the script, or add an adapter (`docs/dev/adapters.md`) |
| `json` refuses to start on an empty `data/` | You lost `data/` in an update: put it back, or `set crimson_hitman_new_store 1` once |
| It refuses to start after changing `Config.Database.Mode` | The old mode still holds money: see [Changing storage mode](#changing-storage-mode) |
| `failed to start: mysql mode cannot start: the database is missing what it needs` | Your user may not create or alter tables: import `install/sql/crimson_hitman.sql` as a user that may, or run the printed `ALTER TABLE` |
| `table crimson_… already exists … and is not this resource's` | Another resource owns that table name: rename it, or give crimson-hitman its own database |
| A panel change is back to config.lua's value after a restart | An edit to config.lua made the override invalid; the start lists it among the settings that need attention |
| A value is refused in the panel with a sentence about another setting | It is checked against everything else in force: change the other one first |
| `photo hosts: 0`, or kill photos refused as not allowed | `'host'` storage: add the phone's upload host to `Config.Completion.ExtraPhotoHosts` |
| Save to Photos keeps the photo in the app | `'server'` storage needs a public https address (`Config.Completion.PhotoPublicUrl` or `web_baseUrl`) in lb-phone's upload whitelist |
| Alerts are not posted to Discord | Set `crimson_hitman_alert_webhook` with `set` and turn on `Config.Alerts.ToDiscord`; **Alerts & Discord** says which webhook it uses |
| `/ch-settle` says *ending unfinished; it settles itself within a minute* | Nothing to do: the maintenance tick finishes it |
| `/ch-stuck` lists a line that raised while being given | Check the player's inventory or balance, then **Pay**, **Pay amount** or **Delivered** |

The audit log records every money movement and every refused attempt:
`/ch-timeline <contract>` for one contract; the whole log in the panel's
**Logs**, `data/audit-<day>.jsonl` (`json`) or the `crimson_audit` table
(`mysql`).

## What's New

**1.2.0, other scripts optional, first-start setup (newest)**

- **Settings export and import**: Developer, Export & import: every setting changed from the panel and your own presets as one text; paste one in to see every change and every refused key with why, then apply it with two clicks, each change audited and undoable. Not the map places or the target limits.
- **Your own presets**: Game rules, Presets keeps up to 20 presets of the server's own (the settings changed from the panel, under a name), previewed and applied like the shipped ones, deleted with two clicks, audited.
- **Config check**: `/ch-diag config` (and Developer, Health, **Check the config**) lists every value out of range, missing script, missing ACE and risky combination, each with its fix. See Troubleshooting and /ch-diag.
- **Version check** (`Config.VersionCheck`, off as shipped, no address): one HTTPS GET at start, sending nothing of this server's, and one console line when a newer version is out. See Updating.
- **Translations**: every word the server and the game show (notices, police advisories, staff alerts and their Discord posts, the staff commands and the diagnosis, every feature's refusals, the organisation's, the panel's answers and its setting labels and help) and every refusal on the phone and in the panel are read from language files (`locales/en.lua`, `locales/en.json`) in the language `Config.Locale` names; a missing key reads in English. See Updating, Escrow, and where the words live.

- **Organisation extras 3**, each off as shipped: **several organisations** (rival crews, each its own job, roles, funds and places), **reputation and tiers**, **dead drops**, **territory**, the **garage**, **internal contracts** on rogue members, the **handler** NPC and the boss's **activity log**. See Optional features, Organisation extras 3.

- **Organisation extras 2**, each off as shipped: the **armory**, each member's **record and the leaderboard**, **discipline** (strikes and warnings) and **recruitment** (the boss's application form). See Optional features, Organisation extras 2.

- Every script besides Qbox is optional, behind an adapter chosen by `Config.Integrations` ('auto' picks what is started, so nothing changes on a server that has them all); one missing turns off only what needs it, in one console line. `ox_inventory` is no longer a manifest dependency. Add your own adapter: `docs/dev/adapters.md`.
- The **first-start setup** in the admin panel; **Install in 5 minutes** at the top of this file; `CHANGELOG.md`; editable files left out of escrow.
- Merged: `Config.Completion.DeathStateProviders` into `Config.Integrations.Ambulance`, `Config.Organisation.Funds` into `Banking`, `Config.Record.Progression.Resource` into `Progression`.

**1.1.0, the panel's reward, reassign and disposal controls**

- The contract drawer's **Money** tab has **Change reward**: raise or lower by an amount, added by staff or charged to the placer, from cash or bank, with a reason; the server's figures (the reward before and after, what comes off staff's part and what goes back to the placer) are drawn before the button arms, and the armed button names them. **People** has **Reassign to another hitman**: the hitman looked up in Players, who comes off and whether the stake is waived said first, with the bar and the stakes to choose.
- **Review fixes**: a cut of the reward never lands on a line a claim already owes its hitman; a disposal step stands at most `Config.Disposal.MaxHoldMinutes` (120) real minutes, away or not, and stops keeping its target off the board then; every lost disposal vehicle counts as a respawn, a relog in between or not; the disposal vehicle is kept by the server (orphan mode), in the hitman's routing bucket, with a random plate; a hitman staff assign is anonymous by default, with no fee; Reassign asks every check before anybody comes off and puts everybody back if the acceptance is refused after all; a placer gets `Config.Kidnap.MaxDeclines` (2) declines per contract, after which the next handover pays.
- **Panel fixes**: *Why can't they see…* names no citizen id to staff without `crimson.identity`, and draws a diagnosis only under the player it was run for (Health keeps its own); the disposal list's *held* never points at an anonymous party; the reward's figures load even when an amount is typed at once; an armed **Refund**, **Pay** or **Pay amount** names the amount, the recipient and the account, and editing any of them disarms it; **Contracts** opens on *Live only*.
- **Mission steps** (step markers, on, and body disposal, off as shipped): see [Mission steps](#mission-steps). Contracts, and Home while there is one, list every body being disposed of with **Skip** and **Respawn vehicle**; **Locations** sets the disposal vehicle spawn and the drop-off, with **Use my position**.
- **Where the funds are kept** offers only **Abandon the bank** while Renewed-Banking is not answering, as the server allows nothing else then.
- A staff assignment freezes the organisation cut its gate checked and refuses when the gate cannot answer, as Accept does; a declined or unconfirmed handover takes its circle off the map at once; the step-marker and body-disposal settings sit under *Completing a contract* in Game rules.

**1.1.0, Confirm handover, Change reward, Reassign**

- **Confirm handover** (`Config.Kidnap.PlacerConfirms`, off as shipped): the placer taps Confirm handover on their card before a live handover pays; a decline or no answer pays nothing and the hitman may arm again. See Roles and how a contract works, Confirm handover.
- The contract view's staff tools gain **Change reward** (raise, added by staff or charged to the placer, or lower, back to whoever funded it) and **Reassign** (to a hitman looked up under Players, through every Accept check). See Optional features, Staff tools, and Admin panel, Reward and reassign requests.

**1.1.0, the admin panel rebuilt**

- The admin panel is organised by task: a sidebar of **Daily** (Home, Players, Contracts, Target limits), **Setup** (Game rules, Hitman organisation, Boss permissions, Locations), **Records** (Logs) and **Developer**, with **Help** in the header. Every view it had is still there; a link or a remembered view from before opens where its items are now.
- **Search** from the header (`/` or Ctrl+K): settings, actions, sections, a contract id or a player. The player and the contract you are on stay in the header as you move, and the contract drawer stays open over any section.
- **Home** has one inbox for Needs review, Money waiting and open alerts. **Players** is a workspace with a tab per part of a player's card, and lists of everybody frozen, suspended or protected (new request `sanctions`). *Why can't they see…* runs the diagnosis as the player looked up (`diag` takes the lookup).
- **Game rules** shows every setting by area of the game, its switches first, with type chips and compact rows whose **Details** hold the key and the rest. Each setting carries its area from the server.
- The contract drawer has tabs (Summary, Money, People, Notes & text, Record), with Void under More.
- The panel for the **Hitman organisation**, **Boss permissions** (the matrix, saved as one batch) and **Locations** (Use my position).
- A phone-width window folds the sidebar into one menu and gives the drawer the whole screen.

**1.1.0, review fixes**

- A buyout's immunity (`Config.Immunity.AfterBailoutSeconds`) survives a staff Reset, Exempt and every job-wide action; only Reset all on the player lifts it, and the panel's replies say so. A plain Reset also says when a staff extension still holds.
- A job's own target limits apply to a target holding that job as a second one too, the strictest of their jobs winning, in placing, the lookup card and the job-wide actions alike.
- Contracts withdrawn or run out before anybody took them no longer count toward the day and week caps.
- Accepting is refused, nothing taken, when the placer changed how the contract is completed, whether it is anonymous, or the buyout on the card since the hitman read it; the hitman is told what it is now.
- `/cleanse <id>` buys at the price it listed (or `/cleanse <id> <price>`), never at one changed since; the completion wait's hours never reveal a job's or a player's own wait; contract decay counts nothing of the time it was off before a contract's first step; **Cancel and place again** names the wait after withdrawing, and says the anonymity fee is not refunded.

**1.1.0, Target limits**

- The admin panel has a **Target limits** section: the six limits on how often one person may have a contract placed on them (two new, a day and a week cap, off as shipped), each job's own, one player's cooldown reset or extended, counts reset and own limits or exempt, the same for a whole job at once, and every live contract by target. See Admin panel, Target limits.

**1.1.0, sweep 6 fixes**

- Before anybody accepts, the **Edit** sheet also changes the buyout price, how the contract is completed and whether it is placed anonymously, each checked as placing checks it; **Cancel and place again** puts it on someone else. A target's **Buy out** is charged the price the dialog showed, and told the new one if the placer changed it meanwhile.
- **Go dark** is offered and sold only while tips on that contract are; a paid window stays on the card to its end. Go-dark windows and an informant tip's showing and wait stand still while the contract is on hold, and through the restart hold and the restart.
- Contract decay switched off and back on counts none of the time it was off. Bodyguards switched off mid-job keep working for the job under way. Turning decay off needs the burner phone where one is required.
- With a player frozen, the expiry pass and the panel's contract lists read nothing more than with nobody frozen.

**1.1.0, sweep 5 fixes**

- The meeting point is a marker on the map of the placer and every hitman on the contract, and both are told on their phone, and on their card, exactly what to do to finish the handover; it comes off every map when it is cleared, moved, or no longer needed.
- Staff without `crimson.identity`: a log search by a player's citizen id pages with a handle good for that staff member and that search only (ten minutes), and offers **Older** only when a row they may see is left, so no page or its absence points at an anonymous contract; a party's phone view says *On hold* only where the contract's own frozen badge would.
- A handover arm refused because the placer is not close enough waits up to 15 seconds (at most `Config.Kidnap.RearmCooldownSeconds`) before the next try.
- Ending a staff freeze, the app pause or the restart hold gives every contract its held time back before the expiry pass can end one; a kill made in the minutes before the restart hold can still be verified once the hold is skipped; skipping the hold (or reaching `Config.Holds.RestartMaxHoldMinutes`) tells every party *Contracts are no longer paused for the server restart.* and refreshes their pages.
- Answering a lapsed proposal while its contract is frozen is refused as on hold and leaves it open; the time band on a card is worked out from whichever ends first, the deadline or the two-day lifetime; an idle release never lands on a hitman being paid; a claim checks the holds again under its lock; if the freezes cannot be read at the start, every live contract is held until a tick reads them.
- Withdrawing every cash and bank line of a contract takes its buyout off (the placer is told *Buyout removed*): a contract funded only in dirty money or goods cannot carry one. A give cut off by a restart records what the player held before it, and the start says when it probably arrived; tip and go-dark refunds whose credit raised go to staff as a buyout refund does; a decay step whose top-up raised after the charge is not charged again; a top-up's audit row lists each line.

**1.1.0, leftover fixes**

- A staff freeze gives an open amendment proposal back the time it held it, also when the app pause or the restart hold covered the freeze (both of which let a proposal be answered, so they give it nothing); an idle release refused by a hold that landed at that moment keeps the hold's idle clocks.
- A proof-item handover is its own outcome: *Proof handed over* on the Ledger, no EMS re-listing, witness report or city news.
- The placer's Ledger row for an expiry (or a cancel) counts the operatives' stakes handed to them, and says how much of it was stakes, never whose.
- Go dark keeps its row only once paid and confirmed, refunding a purchase the store could not keep; a delayed tip warning leaves the store only after the target is told. Passed go-dark windows, and decay rows of ended contracts while decay is off, are pruned a few a pass.
- `/<panel>-close` follows the name the server registered the panel command under (a panel override included); a scrubbed serial is the same after a restart.

**1.1.0, final pass**

- Loops: contract decay runs on its own tick, sleeps until a step is due and takes at most 25 steps a pass; the weekly stats and hitman heat sleep until due; the bodyguard sweep reads a contract only once it has ended. Every optional job costs nothing with its feature off.
- Simpler workflows: every refusal on the phone says what to do next; *the placer* is one word everywhere (never *the client*); the panel's Features run core, Anonymity, Informants, Advisory, Staff tools, Roleplay, Improvements, and config.lua follows the same order; every settings group says what it does and every number shows its unit; **Undo a setting change** is on Staff actions; the Developer section reads **Permissions & history** without the Developer ACE.
- The documents: this manual rewritten short; [docs/developer.md](../docs/developer.md) replaces the spec, the plan, the build report and the oxmysql notes; the in-game checklist is one line a check.

**1.1.0, the feature rounds**

- Improvements, each off as shipped: informant fairness (tip warning delay, tip limits, hold before a tip, second try, safe zones, go dark), the board (placer record, hitman heat, tiered board, contract decay), staff and economy (proof items, completion cooldown, serial scrubbing, weekly stats).
- Roleplay, each off as shipped: witness heat, EMS before re-listing, city news, dirty money payouts, proof of intent, reputation, bodyguards, the hit on the hitman, rumours and a broker, burner phone, the informant in person, reason quality.
- Staff: suspensions, protections, player history, manual payments, moderators, the app pause, the daily summary, alerts with thresholds, settings history with undo, staff tools on a contract, the staff freeze, deadline changes.
- Smoother journeys: banners while contracts are on hold or paused, one Edit sheet before a contract is taken, the placer's handover countdown, the Ledger's kinds and amounts, fewer taps to place and to buy an informant.
- Performance: the board read once per change, bulk reads, capped passes, the shared live snapshot, the loops scheduled on ticks of their own.

**1.1.0, the base**

The clock that runs only with everyone in, rough time bands instead of a
countdown, the pause before a restart, live transfer as the shipped way to
finish, the whitelisted-job view with Notify me, the three informants, the
admin panel in six sections, `mysql` storage that survives outages, and the
quiet console.
