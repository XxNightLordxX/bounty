# Crimson Hitman System

A criminal contract board for **QBox**, delivered as an **lb-phone** app
(**Crimson-Hitman**), with a staff panel in game (`/hitmanadmin`). This file
is the owner's manual: how to install, run, configure and support it. How it
is built and tested is in [docs/developer.md](../docs/developer.md); what to
check in game is [docs/in-game-checklist.md](../docs/in-game-checklist.md).

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
| Setup | **Game rules** | Every rule by area of the game, its switches first; what was changed from the panel; the change history |
| Setup | **Hitman organisation** | The optional hitman job: setup, roles and pay, members, applications, funds and cuts, access, notices, its log |
| Setup | **Boss permissions** | What bosses may do: the matrix, limits, delegation and the office, grant history |
| Setup | **Locations** | Every place the resource uses, set from where you stand |
| Records | **Logs** | The audit log with its search, Alerts & Discord |
| Developer | **Developer** | Health, engine settings, the console, test tools |

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
| Anonymity | `Config.Anonymity.AllowAnonymousPlacer`, `AllowAnonymousHitman` (and `.WhitelistedTargets`) | off |
| Informants (target's, placer's, the tip) | `Config.InformantsEnabled`, then `Config.Informant.Enabled`, `Config.PlacerInformant.Enabled`, `Config.LocationTip.Enabled` | off |
| Law enforcement advisory | `Config.Advisory.Enabled` | on |
| Staff tools (app pause, daily summary, alerts) | `Config.Staff.AppPaused`, `Config.Staff.DailySummary`, `Config.Staff.Alert*`, `Config.Alerts.ToDiscord` | pause and summary off, alerts on |
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
2. In `server.cfg`, after `oxmysql`, `qbx_core`, `ox_inventory` and `lb-phone`: `ensure crimson-hitman`.
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
and each held exclusive contract's idle clocks), and the organisation's
`crimson_orgs`, `crimson_org_roles`, `crimson_org_members`,
`crimson_org_grants`, `crimson_org_locations`, `crimson_org_funds`,
`crimson_org_splits` and `crimson_org_applications` (made on every start,
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
| `ox_inventory` | Required (manifest dependency) | 2.48.0 |
| `oxmysql` | Required in every mode (the playtime count reads `qbx_core`'s `players` table) | 2.14.3 |
| `lb-phone` | Required for the app | 2.8.0 |
| MariaDB or MySQL | `mysql` mode | MariaDB 10.11, MySQL 8 |
| `ox_lib` | Through `qbx_core` | 3.40.3 |
| `sc-ambulance` / `qbx_medical` | Optional: death and last-stand state, the defibrillator | |
| `sc-dispatch` | Optional: advisories and bulletins in the MDT | |
| `sc-blackmarket` | Optional: criminal progression, selling the burner phone | |
| `MugShotBase64` | Optional: target headshots | |

## Updating

- **Keep `crimson-hitman/data/`** when you put a new version in place (copy the new files over the old folder, or move `data/` out and back). In `json` mode it is the store; in every mode it holds the kill photos. A `json` store that finds an empty `data/` after it has run refuses to start; put the old one back, or `set crimson_hitman_new_store 1` once to start empty on purpose.
- Carry your `config/config.lua` across. Settings changed in the panel are kept in the store and survive the update.
- Payouts an older version left owed appear once under **Money waiting** in the panel's inbox (`/ch-stuck`): check the player has it, then **Pay** or **Delivered**.
- Restarting `qbx_core`, `ox_inventory` or `oxmysql` stops this resource with them: `ensure crimson-hitman` afterwards. Restarting `lb-phone` is safe.

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
- If the staff freezes cannot be read (at the start or later), every live contract is held until they can be: the console says so once and then every five minutes, the read is tried again after a wait that grows to five minutes, the Overview's **Frozen players** reads *Unknown*, and a held contract's badge reads *store unreadable* (*held* without IdentityAce). The first good read gives every contract back the lifetime the outage took.

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
- **Holds**: a staff freeze stops a handover waiting on its confirm, and nothing is paid. The window stands still on the restart hold (a confirm is refused until it lifts) and while the app is paused (`Config.Staff.AppPaused`; a confirm still pays). A handover keeps the rule it was armed under if the switch is changed meanwhile.

### Money rules

- Every reward is held from placing to ending; a payout comes only from what is held, in exactly the sources it holds (dirty money in, dirty money out: there is no conversion, because `sc-blackmarket` values dirty money above clean).
- A payout to a player who is away or full is owed and given at their next login (and retried every 30 s while online). One the server could not give after three tries waits for staff under **Money waiting** in the panel's inbox.
- Anything no rule can settle (a buyout the store would not record, a payment the database did not confirm) goes to **Needs review** for staff.
- Caps: `Config.MaxContractValue`, each source's `max`, `Config.Penalty` for stakes, `Config.Bailout` for buyouts; every figure is checked on the server, never taken from the phone.

### What stops it being abused

- One account can never be two parties to a contract (`Config.AntiCollusion`); a target cannot be listed again for a while after a contract on them closes, nor by the same placer.
- New characters and players just online cannot be targets (`Config.Immunity`); whitelisted-job targets may be (`Config.Targeting.AllowProtectedJobTargets`, on as shipped), and the advisory warns officers.
- Barred jobs (`Config.BlockedJobTypes`, `BlockedJobNames`) never use the app; they see only the whitelisted-job view.
- Every request is rate-limited per player (`Config.Cooldowns`), every write is audited, and nothing a player's game sends is trusted for money, items or position.
- Anonymous parties stay anonymous to everybody but staff holding `crimson.identity`, in every view and log.

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
- A link or a view remembered from before the rebuild (Rules, Features,
  Stuck escrow, Diagnostics, Permissions…) opens where its items are now.

| Section | Tabs | Use it to |
|---|---|---|
| **Home** | Inbox, Overview, Announce | The inbox lists what waits for staff in one place, with a chip and a count for each: **Needs review** (refund, pay or dismiss), **Money waiting** (escrow lines left for you to settle: Pay, Pay amount, Return, Delivered) and the open **Alerts** (Acknowledge); and, while a body is being disposed of, every such step with **Skip** and **Respawn vehicle**. The overview counts contracts, operatives, money held and owed, and who is frozen, suspended or protected, with the setup problems for staff who can change things. Announce sends one notice to every hitman holding a contract, or everybody with the app |
| **Players** | Find & summary, then for the player looked up Contracts, Measures, Money, Playtime, History, *Why can't they see…*; and Frozen, Suspended, Protected | Look a player up (player id, citizen id or name; recent lookups are one click). Measures: **Freeze**, **Suspend**, **Protect**, and their standing in Target limits. Money: what they are owed, notices for their next login, **Pay**. *Why can't they see…* runs the diagnosis as them. The three lists hold everybody frozen, suspended or protected now, each with **Unfreeze** or **Lift** |
| **Contracts** | All contracts | Search and filter, then open one. Above the list, every body being disposed of ([body disposal](#mission-steps)) with the exact time left, **Skip** and **Respawn vehicle**. The drawer has tabs: **Summary** (terms, the deadline with **Extend** / **Shorten**, open proposals), **Money** (lines waiting for staff, payouts, **Change reward** with the server's figures before it arms, escrow lines; its tab counts the lines waiting), **People** (operatives, **Remove an operative**, **Reassign to another hitman** looked up in Players, *As a player sees it*, Whois), **Notes & text** (staff notes, **Edit text**) and **Record** (timeline, export). **Void** is under **More** |
| **Target limits** | Defaults, Per job, Per player, Contracts on someone | See [Target limits](#target-limits) |
| **Game rules** | Areas, Changed from the panel, Change history | Every rules and features setting by the area of the game it is about (who can use the app, placing contracts, anonymity, rewards, completing, buyouts, informants, police, messages, roleplay extras, staff tools): an area's switches first, then its numbers and lists. Chips narrow it to **Switches**, **Timers**, **Money**, **Limits**, **Lists** or **Changed**, across every area when none is picked. A row shows its label with its unit, its control and Save or Reset; **Details** shows its `Config` key, what it does, what happens to things under way and where its value comes from. **Undo all panel changes** is on *Changed from the panel*; every change, with **Undo**, on *Change history* |
| **Hitman organisation** | Setup, Roles & pay, Members, Applications, Funds & cuts, Contract access, Notices, Org audit | See [Organisation](#organisation). Off as shipped: every tab is one card saying so, with its switch |
| **Boss permissions** | Matrix, Limits, Delegation & office, Grant history | The ceiling on what bosses may do: powers by boss role and by one boss (**Allow**, **Deny** or **Inherit role**), every change listed before one **Save** that sends them together; **Revoke all** and **Copy from** per column; each power's limits; which powers need the boss office; every grant, with **Undo** on a role's |
| **Locations** | Map points | The organisation's places (boss office, sign-up, meeting and handover spots, NPC spots), body disposal's vehicle spawn and drop-off (**Save**, **Save where I stand**, **Clear**), and the places that are settings (broker and informant NPC places, tip safe zones, rumour districts, witness areas, the prison zone). **Use my position** fills a row from where your character stands, read by the server |
| **Logs** | Audit log, Alerts | Search the audit log (and flush it); acknowledge alerts, see where Discord stands, send a test alert |
| **Developer** | Health, Engine settings, Console, Test tools | Storage, recovery, kill photos, slow jobs and the diagnosis; debug, storage, rate limits and the read-only values; the console; **Bring timers forward** (test servers) and **Flush the audit log** |

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
- **Contracts on someone**: every live contract (open, taken, settling, on
  hold) grouped by target, a page at a time, searchable by the target's name
  or exact citizen id. A row opens the contract's own view, with every staff
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
| `contracts` | Read | The contract list and its search; `state = 'live'` (the page's default, *Live only*) lists every contract still running |
| `contract` | Read | One contract's view and timeline |
| `exportContract` | Read | One contract's record as text, for a ticket |
| `playerView` | Read | A contract as one of its parties sees it |
| `reviews` | Read | The review queue |
| `stuck` | Read | Money waiting for staff (Home, Inbox) |
| `logs` | Read | The audit log and its search |
| `alerts` | Read | The alerts |
| `player` | Read | One player's contracts and record |
| `history` | Read | One player's history card |
| `frozen` | Read | Frozen players |
| `sanctions` | Read | Everybody suspended or protected now, each row with a handle Lift takes |
| `settings` | Read | Every setting, its value and where it comes from |
| `settingsHistory` | Read | Every setting change from the panel |
| `diag` | Read | The diagnosis, as yourself, a player id or the player looked up (`ref`); scrubbed of citizen ids and accounts for staff without `crimson.identity`, and the lines that come later name the `ref` they were run for, so the page draws them under that player only |
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
| `targetContracts` | Read | Every live contract, by target |
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
(`Config.Progression.Enabled`), the whitelisted-job view and its Notify me
(`Config.WhitelistedView`), kill photos (`Config.Completion.KillPhotos`, off),
the nearby target list (`Config.Targeting.AllowNearby`, off).

### Anonymity

Off as shipped. `Config.Anonymity.AllowAnonymousPlacer` and
`AllowAnonymousHitman` let a contract be placed or accepted anonymously, for
a fee (`CreatorFee`, `HitmanFee`); whitelisted-job targets follow
`Config.Anonymity.WhitelistedTargets` instead. An anonymous party is
*Anonymous* to every player; staff need `crimson.identity` to see who it is.

### Informants

Three paid look-ups, each off as shipped, all behind `Config.InformantsEnabled`:
the **target's** (`Config.Informant`: who is after me, with a chance of an
answer), the **placer's** (`Config.PlacerInformant`: which operative took it)
and the hitman's **tip** (`Config.LocationTip`: the target's rough area on the
map, and the target is told). `Config.InformantsWhitelistedTargets` decides
each on a whitelisted-job target. The informant improvements below refine
them.

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
- **App pause** (`Config.Staff.AppPaused`): nothing can be placed or taken, and every clock is held, for an event.
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
| **Reputation earned in character** (`Reputation`) | Progression trust for a completion is scaled by how it was done (thread, meeting, handover, no witnesses), up to `MaxFactor` |
| **Bodyguards** (`Protection`) | A target hires protection from On me (reward held, pin where they stand); a guard takes it from the board. Ended without a completion: the guard is paid; completed anyway: their share (`PayOnCompletionPercent`), the rest back. Switched off mid-job, a live job carries on: the target can still move its pin or cancel it, and its guard keeps the Protection tab with Set GPS |
| **Hit on the hitman** (`HitOnHitman`) | A target whose informant named an operative may place a contract on them, under every placing rule |
| **Rumours and a broker** (`Rumours`) | New contracts show only as rumours (area, reward band) until the broker NPC, or a player on a broker job, briefs the hitman for `BriefValidMinutes` |
| **Burner phone** (`BurnerPhone`) | Placing, accepting and every contract action (turning contract decay off included) need the item; it may be used up on placing or accepting. Sell it through sc-blackmarket |
| **The informant in person** (`InformantNpc`) | Every informant purchase only beside the informant NPC, which moves between its places |
| **Reason quality** (`ReasonQuality`) | A typed reason needs a least length and number of words; low-effort phrases are refused or placed and sent to Needs review |

### Improvements

All off as shipped, each `Config.Improvements.<Feature>.Enabled`.

| Feature | What it does |
|---|---|
| **Tip warning delay** (`TipWarningDelay`) | A tipped target is told a random while later (`MinSeconds`..`MaxSeconds`); the time on their card is rounded to 5 minutes; survives a restart |
| **Tip limits** (`TipLimits`) | One tip per hitman per contract, and/or each further tip costs twice the last, up to `MaxCost` |
| **Hold before a tip** (`TipHoldFirst`) | A tip only once the hitman has held the contract `MinHeldMinutes` |
| **Informant second try** (`InformantSecondTry`) | The target's later look-ups cost `SecondTryCostPercent` of the price |
| **Tip safe zones** (`TipSafeZones`) | No tip while the target is inside a zone (`'x, y, radius, name'`); the hitman is told only that the informant can't place them |
| **Go dark** (`GoDark`) | A tipped-off target pays to make tips on them find nothing for `Minutes`; the hitman gets their money back. Sold only while tips on that contract are (`Config.InformantsEnabled`, `Config.LocationTip.Enabled`, and `Config.InformantsWhitelistedTargets.LocationTip` for a whitelisted-job target); a window already paid for holds, and stays on the card, to its end. The window stands still while its contract is on hold (a staff freeze, the restart hold and the restart, the app pause), as an informant tip's showing and wait do. Kept across a restart only once paid: a purchase the store could not keep is refunded, and a window that has passed is cleared from the store on the minute |
| **Placer record** (`PlacerRecord`) | A board card shows its placer's placed / paid out / cancelled counts over `LookbackDays`, never who; anonymous placers in bands with `ShowForAnonymous` |
| **Hitman heat** (`HitmanHeat`) | Completions on whitelisted-job targets, witness reports and bulletins give a hitman heat for `DecayHours`; at `Threshold` their targets may be warned and officers get a vague bulletin at most every `BulletinEveryMinutes` (every officer alike, a known hitman who holds a police job too) |
| **Tiered board** (`Tiers`) | Bigger rewards locked to a progression level (needs `Config.Progression.Enabled`) |
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
- **The 33 powers** (the plan's 31 area powers and D2, D3; D1 is R4):
  M1 view members, M2 hire, M3 fire, M4 promote/demote, M5 suspend from
  contracts, M6 member limits; R1 create, R2 edit, R3 delete roles, R4 set role
  powers; P1 role pay, P2 bonus; C1 organisation cut, C2 cut by role, C3 cut per
  member, C4 cut on stakes, C5 cut on buyouts, C6 deposit, C7 withdraw, C8 view
  funds; K1 contract access rules, K2 boss pick, K3 role cooldowns; L1 move the
  office, L2 sign-up spot, L3 meeting spots; N1 notice, N2 applications; S1
  label, S2 boss menu layout, S3 office requirement; D2 per-member grants, D3
  promote to own rank. Hire, fire, role edits, cuts and withdrawals need the
  **boss office** by default (the server's own position, `OfficeRadius`).
  Every bound is `Config.Organisation.Limits`, and staff may set an
  organisation's own.
- **Funds.** Renewed-Banking's society account for the job when it is
  installed (`Config.Organisation.Funds = 'auto'`), this resource's ledger
  otherwise, **chosen once**, the first time the organisation is read, and kept
  (changing `Funds` later does not move them). While the bank is chosen and
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
| `orgGet` | read | Everything: setup, roles, members (by handle), Boss permissions, spots, cuts, bounds, funds, applications, warnings |
| `bossPermsGet` | read | The Boss permissions matrix |
| `orgFunds` | read | Balance and ledger |
| `orgAudit` | read | The organisation's log (`org_*` actions) |
| `orgMyPosition` | read | Where your character stands, read by the server |
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
| `orgLocationSet`, `orgLocationRemove` | write | A spot, typed or `here` (Use my position); remove one |
| `orgApplication` | write | Accept or reject an application |

#### Organisation requests (phone)

lb-phone app requests through the app's own gate, `org` and `orgWrite` rate
limits; each needs the power named, held after Boss permissions, at the office
where it needs one. The phone's Organisation tab comes later; the requests
answer now. The board already shows a member their cut on every card and an
invited player their invite, with Accept and Decline (`orgInviteAnswer`).

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
| `orgInviteAnswer` | the invited player | | |

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
**Respawn vehicle**) and in Locations (the two spots, **Use my position**);
who the hitman is comes only with `crimson.identity`.

| Op | Level | What it does |
|---|---|---|
| `disposalList` | read | Every disposal step: stage, exact seconds left, held, vehicle, respawns; the spots and the rules. Without `crimson.identity`, `held` says only the restart hold, the app pause and a freeze through a party they may see (never one through an anonymous placer or hitman) |
| `disposalSkip` | write | Finish a step (`id`: a step or contract id) as if dropped off: the payout is released |
| `disposalRespawn` | write | Make the vehicle again at the spawn spot (not counted as a respawn) |
| `disposalSpotSet` | write | `spot` = `vehicle` or `drop`, typed (`x`, `y`, `z`, `heading`) or `here` (Use my position, read by the server) |
| `disposalSpotClear` | write | Clear a spot (config.lua's `VehicleSpawn` / `DropOff` apply again) |
| `disposalMyPosition` | read | Where your character stands, read by the server |

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
| `Config.Database.Mode` | `'mysql'` | 'json' \| 'mysql' \| 'memory' (testing only) |
| `Config.Database.AllowModeSwitch` | `false` | start even though the old mode still holds money |
| `Config.Database.QueryTimeoutSeconds` | `10` | mysql: seconds a statement may go unanswered; 0 = forever |
| `Config.Database.Json.Directory` | `'data'` | folder inside the resource |
| `Config.Database.Json.SyncOnFinancialWrite` | `true` | write money changes to disk at once |

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
| `Config.Restart.PauseBeforeSeconds` | `1800` | pause every contract this long before a txAdmin restart; 0 = off |
| `Config.Restart.MaxHoldMinutes` | `45` | end the pause if the restart has not come by then |

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
| `Config.Progression.Enabled` | `true` | feed completions into the criminal progression |
| `Config.Progression.Resource` | `'sc-blackmarket'` | the resource that keeps it |
| `Config.Progression.TrustPerElimination` | `10` | trust per kill |
| `Config.Progression.TrustPerKidnapping` | `20` | trust per live handover |
| `Config.AntiCollusion.BlockSameAccount` | `true` | one account may not be two parties to a contract |
| `Config.Alerts.ToDiscord` | `true` | post each alert to the alert webhook (server.cfg) |

### Features: Anonymity

Whether a contract may be placed or accepted anonymously, what that costs, and the same four switches where the target is on a whitelisted job.

| Setting | Shipped | What it does |
|---|---|---|
| `Config.Anonymity.AllowAnonymousPlacer` | `false` | a contract may be placed anonymously |
| `Config.Anonymity.AllowAnonymousHitman` | `false` | a contract may be accepted anonymously |
| `Config.Anonymity.ShowOperativeNames` | `true` | the target sees a named operative's name |
| `Config.Anonymity.ShowPlacerOnBoard` | `false` | the board names a named placer; off: parties only |
| `Config.Anonymity.CreatorFee` | `0` | fee to place anonymously; 0 = free |
| `Config.Anonymity.HitmanFee` | `0` | fee to accept anonymously; 0 = free |
| `Config.Anonymity.FeeAccount` | `'bank'` | 'cash' \| 'bank' |
| `Config.Anonymity.WhitelistedTargets.AllowAnonymousPlacer` | `false` | such a contract may be placed anonymously |
| `Config.Anonymity.WhitelistedTargets.AllowAnonymousHitman` | `false` | such a contract may be accepted anonymously |
| `Config.Anonymity.WhitelistedTargets.ShowOperativeNames` | `true` | such a target sees a named operative's name |
| `Config.Anonymity.WhitelistedTargets.ShowPlacerOnBoard` | `false` | the same, on such a contract |

### Features: Informants

Three paid look-ups: the target's (who is after me), the placer's (who took it) and the hitman's tip (the target's rough area). Each ships off.

| Setting | Shipped | What it does |
|---|---|---|
| `Config.InformantsEnabled` | `true` | master switch; on, each feature's own switch decides |
| `Config.Informant.Enabled` | `false` | a target may pay to find out who is after them |
| `Config.Informant.Cost` | `25000` | price of one look-up, paid win or lose; 0 = free |
| `Config.Informant.Account` | `'bank'` | 'cash' \| 'bank' |
| `Config.Informant.RevealMode` | `'name'` | 'name' \| 'description' |
| `Config.Informant.RevealChancePercent` | `10` | chance one look-up finds out who it is, 0-100 |
| `Config.Informant.ProximityRadius` | `120.0` | metres that count as near (an idle hold's clock) |
| `Config.Informant.RerollLockMinutes` | `30` | the same pick again this soon repeats the answer, free |
| `Config.Informant.MaxPurchasesPerContract` | `2` | look-ups per target per contract, both kinds |
| `Config.PlacerInformant.Enabled` | `false` | the placer may pay to find out who took it |
| `Config.PlacerInformant.Cost` | `25000` | price of one look-up, paid win or lose; 0 = free |
| `Config.PlacerInformant.Account` | `'bank'` | 'cash' \| 'bank' |
| `Config.PlacerInformant.RevealChancePercent` | `20` | chance one look-up names the operative, 0-100 |
| `Config.PlacerInformant.AlertChancePercent` | `20` | chance a named operative is told, 0-100 |
| `Config.PlacerInformant.RevealMode` | `'name'` | 'name' \| 'description' |
| `Config.PlacerInformant.MaxPurchasesPerContract` | `2` | look-ups per placer per contract |
| `Config.PlacerInformant.CooldownMinutes` | `10` | wait between two look-ups |
| `Config.LocationTip.Enabled` | `false` | a hitman on a contract may buy the target's rough area |
| `Config.LocationTip.Cost` | `25000` | price; 0 = free |
| `Config.LocationTip.Account` | `'bank'` | 'cash' \| 'bank' |
| `Config.LocationTip.RadiusMeters` | `350` | metres; the area shown is twice this across |
| `Config.LocationTip.ShowMinutes` | `10` | minutes the area stays on the hitman's map |
| `Config.LocationTip.CooldownMinutes` | `10` | minutes between two tips on one contract, by anybody |
| `Config.LocationTip.MaxPurchasesPerContract` | `3` | tips per contract, all its hitmen together |
| `Config.LocationTip.NotifyTarget` | `true` | tell the target someone knows their rough area |
| `Config.InformantsWhitelistedTargets.Informant` | `false` | such a target may buy the target's informant |
| `Config.InformantsWhitelistedTargets.PlacerInformant` | `false` | the placer of such a contract may buy the placer's informant |
| `Config.InformantsWhitelistedTargets.LocationTip` | `false` | a hitman on such a contract may buy an informant tip |

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
| `Config.Staff.AppPaused` | `false` | pause the whole app: no placing, no accepting, clocks held |
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
| `Config.Roleplay.Reputation.Enabled` | `false` | trust for a completion scaled by how it was done |
| `Config.Roleplay.Reputation.BaseFactor` | `0.5` | a plain completion |
| `Config.Roleplay.Reputation.ThreadBonus` | `0.2` | the hitman wrote to the placer in the thread |
| `Config.Roleplay.Reputation.MeetingBonus` | `0.2` | a meeting point was set |
| `Config.Roleplay.Reputation.HandoverBonus` | `0.3` | a live handover |
| `Config.Roleplay.Reputation.WitnessFreeBonus` | `0.2` | nobody else within WitnessRadius |
| `Config.Roleplay.Reputation.WitnessRadius` | `50.0` | metres around the hitman |
| `Config.Roleplay.Reputation.MaxFactor` | `1.5` | the most it may reach |
| `Config.Roleplay.Protection.Enabled` | `false` | targets may hire a bodyguard from On me |
| `Config.Roleplay.Protection.Account` | `'bank'` | the reward is paid from: 'cash' \| 'bank' |
| `Config.Roleplay.Protection.MinReward` | `1000` | least reward ($) |
| `Config.Roleplay.Protection.MaxReward` | `100000` | most reward ($) |
| `Config.Roleplay.Protection.PayOnCompletionPercent` | `25` | the guard's share if the hit completes anyway |
| `Config.Roleplay.Protection.MaxJobsPerGuard` | `2` | protection jobs one guard holds at once |
| `Config.Roleplay.HitOnHitman.Enabled` | `false` | a target may place a contract on an operative revealed |
| `Config.Roleplay.Rumours.Enabled` | `false` | the board shows new contracts as rumours only |
| `Config.Roleplay.Rumours.AreaMode` | `'district'` | 'district' (target's area) \| 'zones' (from Zones) |
| `Config.Roleplay.Rumours.Zones` | `{ 'the city', 'the south side', 'the docks', … 5 in all }` | area names when AreaMode = 'zones' |
| `Config.Roleplay.Rumours.Districts` | `{ '200, -900, Legion Square', '-1300, -1400, Vespucci', '-1500, -450, Del Perro', … 12 in all }` | 'x, y, name': the nearest names the target's area |
| `Config.Roleplay.Rumours.BandPercent` | `25` | reward shown as a band this many % either side |
| `Config.Roleplay.Rumours.Radius` | `5.0` | metres from the broker (NPC or player) that count |
| `Config.Roleplay.Rumours.BriefValidMinutes` | `30` | a briefing unlocks a contract for this long |
| `Config.Roleplay.Rumours.Locations` | `{ '-1171.0, -1572.5, 4.66, 125.0', '1240.6, -3179.2, 7.1, 270.0', '-56.5, -1752.4, 29.4, 50.0' }` | where the broker NPC stands, one at a time |
| `Config.Roleplay.Rumours.RotateHours` | `4` | the NPC moves to the next place this often |
| `Config.Roleplay.Rumours.Model` | `'g_m_m_armboss_01'` | the broker NPC's ped model |
| `Config.Roleplay.Rumours.Scenario` | `'WORLD_HUMAN_SMOKING'` | what the NPC does while standing |
| `Config.Roleplay.Rumours.Blip` | `false` | show the broker on the map |
| `Config.Roleplay.Rumours.BrokerJobs` | `{}` | jobs whose players brief from the app: { broker = true } |
| `Config.Roleplay.BurnerPhone.Enabled` | `false` | placing and accepting need the item |
| `Config.Roleplay.BurnerPhone.Item` | `'burner_phone'` | the ox_inventory item |
| `Config.Roleplay.BurnerPhone.ConsumeOnPlace` | `false` | use one up when a contract is placed |
| `Config.Roleplay.BurnerPhone.ConsumeOnAccept` | `false` | use one up when a contract is accepted |
| `Config.Roleplay.BurnerPhone.RequireToOpen` | `true` | no item, no contract tabs at all |
| `Config.Roleplay.InformantNpc.Enabled` | `false` | informant purchases only beside the informant NPC |
| `Config.Roleplay.InformantNpc.Radius` | `5.0` | metres from the informant that count |
| `Config.Roleplay.InformantNpc.Locations` | `{ '374.2, -827.4, 29.3, 180.0', '-1394.0, -592.0, 30.3, 120.0', '1984.0, 3054.0, 47.2, 240.0' }` | where the informant stands, one at a time |
| `Config.Roleplay.InformantNpc.RotateHours` | `3` | the NPC moves to the next place this often |
| `Config.Roleplay.InformantNpc.Model` | `'a_m_y_hipster_01'` | the informant NPC's ped model |
| `Config.Roleplay.InformantNpc.Scenario` | `'WORLD_HUMAN_LEANING'` | what the NPC does while standing |
| `Config.Roleplay.InformantNpc.Blip` | `false` | show the informant on the map |
| `Config.Roleplay.ReasonQuality.Enabled` | `false` | hold free-text reasons to the rules below |
| `Config.Roleplay.ReasonQuality.MinLength` | `15` | least characters in a reason |
| `Config.Roleplay.ReasonQuality.MinWords` | `3` | least words in a reason |
| `Config.Roleplay.ReasonQuality.LowEffort` | `{ 'rdm', 'idk', 'cuz', … 6 in all }` | words to catch |
| `Config.Roleplay.ReasonQuality.LowEffortAction` | `'refuse'` | 'refuse' \| 'review' (placed, and queued for staff) |

### Improvements

Optional changes to existing features, each its own block and each off as shipped (README, Optional features). All are changed from the panel.

| Setting | Shipped | What it does |
|---|---|---|
| `Config.Improvements.TipWarningDelay.Enabled` | `false` | the target's tip notice waits a random while |
| `Config.Improvements.TipWarningDelay.MinSeconds` | `60` | shortest wait (s) |
| `Config.Improvements.TipWarningDelay.MaxSeconds` | `300` | longest wait (s) |
| `Config.Improvements.TipLimits.Enabled` | `false` | the extra tip limits below apply |
| `Config.Improvements.TipLimits.OnePerHitman` | `true` | each hitman buys one tip per contract |
| `Config.Improvements.TipLimits.PriceDoubling` | `false` | each further tip on a contract costs twice the last |
| `Config.Improvements.TipLimits.MaxCost` | `200000` | the most a doubled tip costs ($) |
| `Config.Improvements.TipHoldFirst.Enabled` | `false` | a tip only once the contract was held a while |
| `Config.Improvements.TipHoldFirst.MinHeldMinutes` | `10` | minutes the hitman must have held it |
| `Config.Improvements.InformantSecondTry.Enabled` | `false` | the target's later look-ups cost differently |
| `Config.Improvements.InformantSecondTry.SecondTryCostPercent` | `50` | % of Informant.Cost after the first |
| `Config.Improvements.TipSafeZones.Enabled` | `false` | no tip while the target is inside one of Zones |
| `Config.Improvements.TipSafeZones.Zones` | `{}` | 'x, y, radius, name', e.g. '300, -590, 80, Pillbox' |
| `Config.Improvements.GoDark.Enabled` | `false` | a tipped-off target may pay to go dark |
| `Config.Improvements.GoDark.Cost` | `50000` | price; 0 = free |
| `Config.Improvements.GoDark.Account` | `'bank'` | 'cash' \| 'bank' |
| `Config.Improvements.GoDark.Minutes` | `30` | tips bought on them this long find nothing |
| `Config.Improvements.PlacerRecord.Enabled` | `false` | hitmen see the placer's record on a board card |
| `Config.Improvements.PlacerRecord.LookbackDays` | `30` | days of contracts the record counts |
| `Config.Improvements.PlacerRecord.ShowForAnonymous` | `false` | an anonymous placer's record too, in rough bands |
| `Config.Improvements.HitmanHeat.Enabled` | `false` | hitmen gather heat the city can feel |
| `Config.Improvements.HitmanHeat.ProtectedCompletionHeat` | `3` | heat for a completion on a whitelisted-job target |
| `Config.Improvements.HitmanHeat.WitnessHeat` | `2` | heat for a witness report on their completion |
| `Config.Improvements.HitmanHeat.AdvisoryHeat` | `1` | heat for a police bulletin on their acceptance |
| `Config.Improvements.HitmanHeat.DecayHours` | `24` | hours each heat stays |
| `Config.Improvements.HitmanHeat.Threshold` | `5` | heat at which a hitman counts as known |
| `Config.Improvements.HitmanHeat.WarnTargetChancePercent` | `50` | chance their next target is warned, 0-100 |
| `Config.Improvements.HitmanHeat.BulletinEveryMinutes` | `60` | least minutes between police bulletins; 0 = none |
| `Config.Improvements.HitmanHeat.BulletinTitle` | `'Intelligence bulletin'` | the bulletin's title |
| `Config.Improvements.HitmanHeat.BulletinText` | `'A known contract killer is believed active in the city.'` | its words |
| `Config.Improvements.Tiers.Enabled` | `false` | big rewards need a progression level |
| `Config.Improvements.Tiers.CompletionsPerLevel` | `5` | completed contracts per level above 1 |
| `Config.Improvements.Tiers.Tiers` | `{ 'Professional, 50000, 2', 'Elite, 150000, 4' }` | 'name, least reward, least level' |
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
| `Config.Organisation.Funds` | `'auto'` | 'auto' (Renewed-Banking if installed) \| 'internal', chosen once |
| `Config.Organisation.OfficeRadius` | `5.0` | metres from the boss office that count |
| `Config.Organisation.DrawMetres` | `40.0` | metres at which a spot is drawn |
| `Config.Organisation.ApplyAtSignupOnly` | `true` | applications only at a sign-up spot |
| `Config.Organisation.NpcModel` | `'g_m_m_armboss_01'` | the ped drawn at an NPC spot |
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

### Mission steps

Map markers for each step of a contract, to the one party who acts on it (README, Optional features), and body disposal: a verified kill paid once the body is dropped off. Disposal ships off; its spots are set by staff in the admin panel (disposalSpotSet) or below.

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
| `Config.Completion.DeathStateProviders` | `{ { dead = 'IsDead', lastStand = 'IsLaststand', resource = 'sc-ambulance' }, { resource = 'qbx_medical' } }` | medical resources asked who is dead, in order |
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

**The maintenance tick** (every `Config.Audit.FlushIntervalMs`, 10 s as
shipped). Every job runs inside `pcall` (a job that raises is logged and the
others go on) and stops with the resource. On a busy `mysql` server with
nothing to do, a tick sends two statements at most: the heartbeat, and every
third tick the endings check; while holds are idling, each held contract's
idle clocks are written too, at most once a minute each and 25 a pass
(`tests/loops_spec.lua` pins it job by job).

The last column says why each job cannot reasonably cost less: its interval
is bound by what it guards, and what is left is the least it must read. Where
a trade-off is left on purpose, it says which and why.

| Job | Interval | Cost a pass (`mysql` / `json`) | Why it cannot reasonably go lower |
|---|---|---|---|
| `contracts.releaseIdleHolds` | 10 s | 1.9 / 1.0 ms, 0 statements with nothing due; 75 ms and 252 statements releasing its cap of 25 | A hold is released within one tick of its window. It reads the shared snapshot (`Projection.liveSnapshot`, re-read only after a write) and asks `qbx_core` once per person; **at most 25 releases a pass**. The idle and attempt clocks are kept in `crimson_rp_rows` (kind `idle_clock`, a row a held contract) so a restart resumes them, downtime not counted: a row is written at most once a minute, at once when a count goes back to nothing, and at most 25 a pass |
| `expireContracts` | 10 s, skipped until the next deadline, a presence change or a contract change | 0.11 / 0.07 ms; 317 ms and 726 statements ending its cap of 25 | Sleeps until the soonest deadline; reads the snapshot. **At most 25 endings a pass.** Trade-off: each ending re-reads its contract under its lock, kept because it moves money |
| `audit.flush`, `storage.flush` | 10 s | 0.28 / 0.88 ms; 0 / 0.33 ms | A crash loses at most ten seconds of log rows and (`json`) changed files; only what changed is written |
| `storage.heartbeat` | `json` 60 s, `mysql` 10 s | 0.01 ms; one statement or file | A restart's downtime is dated from it; on a tick of its own |
| `playtime.pass` | 60 s | 0.21 / 0.16 ms; one transaction of a row per player | Playtime is counted in minutes; one batch for everybody |
| `storage.prune` | 600 s, every tick while a batch is full | 1.1 / 0.1 ms | Retention counts days; at most 25 contracts a pass on `mysql` |
| `bailout.processQueue`, `photos.expire`, `photos.forgetKept`, `amendments.expire`, `death.sweep`, the stuck-work retries, `review.retryUnwritten` / `review.decide` | 10 s (photos only while kill photos are in use) | under 0.02 ms each, 0 statements with nothing to do | Each reads an index or list in memory, and the store only when something in it is due |
| `bridges.refreshAccess` | 30 s | 0.32 / 0.29 ms (7 ms seen live) | The backstop for every event that tells a player at once (login, job, duty, setting); one job read a player is the least it can check |
| `notify.deliverKept` | 10 s | 0.00 ms with nothing kept | A kept notice goes on the first tick its minute opens |
| `rp_places.announce` | 60 s | 0.02 ms off, 0.14 ms on | NPC places rotate by the hour; a change from the panel is announced at once |
| `freeze.syncAppPause`, `thresholds.sweep` | 60 s | 0.00 ms | Each is a comparison or two; the pause follows its switch at once anyway |
| `freeze.restartTick`, `sanctions.tick`, `summary.tick` | 10 s | 0.00 ms | One comparison each; the end they guard happens on the tick it falls due |
| `contracts.finishEndings`, `ledger.forgetOldPhotos`, `photo.loadAllowedHosts`, `escrow.retryWaiting` | 30 s, 600 s, `PhotoHostRefreshSeconds`, 30 s per player | under 0.15 ms | Gated inside; each runs when what it guards can have changed |
| `imp_board.tick` (heat and the police bulletin, placer records) | 60 s | 0.01 ms, 0 statements, off **and** on | Off: one switch read. On: heat is kept in memory and pruned only once the oldest heat has cooled; the bulletin waits its own `BulletinEveryMinutes`, and finds a working hitman in the shared snapshot (was two reads per known hitman) |
| `imp_decay.tick` (contract decay) | 60 s, on a tick of its own | off 0.01 ms; on, nothing due 0.08 ms and 0 statements; due, 91 / 136 ms and about 300 statements for its cap of **25 steps** | Sleeps until its soonest step is due and reads the snapshot. Trade-off: each `rise` step is a charge that re-reads its contract and goes through the placer's own add-to-reward path, kept because it moves money; 100 contracts due together take four passes (was all in one: 1,951 statements, 0.7 to 1.1 s) |
| `imp_weekly.tick` (weekly stats) | 10 s, asleep until the post is due | 0.01 ms off and on | Works out the calendar once, then one comparison a tick; the week's totals are read only when it posts |
| `rp.tick` (EMS before re-listing) | 10 s | 0.01 ms off, 0.01 ms on with nobody recovering | Looks only at targets killed on a contract, in memory; nothing while nobody is |
| `rp_intent.sweep` (proof of intent) | 10 s | 0.01 ms, 0 statements with no hold | Reads only the contracts that have a hold. Trade-off: a held payout re-reads its proof at most every 5 s, kept because the hold gates money |
| `disposal.tick` (body disposal) | 10 s | 0 statements with no step | Nothing while no step runs; one row write a step a minute while its clock runs |
| `mission_steps.tick` (step markers) | 10 s | 0 statements | Memory only; nothing at all while no marker is drawn or due |
| `rp_protection.sweep` (bodyguards) | 10 s | 0.01 ms, 0 statements with no job | Nothing while no job is kept; a job's contract is read only once it has left the snapshot of what is running (was a read a job a tick); **at most 25 settles a pass** |
| `informant.retryUnsaved` | 10 s | 0.00 ms | In memory until a write the store refused is waiting |

With every optional feature **off**, each of the optional jobs above
(`imp_*`, `rp*`, `informant.retryUnsaved`) sends no statement and reads
nothing from the store; with them all **on** and nothing due, none sends a
statement either (`tests/loops_spec.lua`, *the optional features' jobs*). A
whole tick with every job due stays under 100 ms with the features off and
under 300 / 450 ms (`json` / `mysql`, harness) with them on, the worst being
the hour an untaken board's decay steps fall due. Informant tip warnings
(`Config.Improvements.TipWarningDelay`) are one timer per waiting warning, not
a loop; going dark ends when it is next looked at.

The scheduled jobs never share a tick with the playtime pass or the `json`
heartbeat, and the access check, the NPC places and contract decay never
share one with each other: one tick's jobs run in the same server frame, so
what shares a tick shares a hitch.

**The server's own clocks**

| Loop | Interval | Why that often | Cost a pass (`mysql` / `json`) |
|---|---|---|---|
| Condition sampler (`death.sampler`) | `Config.Completion.ConditionSampleMs`, 1 s | Damage is credited from the last sample, so attribution is only as precise as this. The running contracts and their rosters come from one snapshot shared with the idle holds and the expiry pass (`Projection.liveSnapshot`), read again only after something is written (was 2 statements every second, 1 with nothing running); each target's medical state and position is read once a pass, however many contracts name them | 0.94 (1.7) / 1.13 (5.5); 0 statements while nothing is written |
| Handover countdown | `Config.Kidnap.TickMs`, 1 s | Only while a handover is under way; the thread ends with the last one. Each countdown reads its contract once a pass (a statement a second per handover on `mysql`), and moves on by the time since the last pass (at least one tick, at most three), not by one tick whatever the pass waited on the database | (per handover) |
| Hit checks | 50 ms | Only while a hit waits for its damage to show, for that victim | (per hit) |
| Discord poster, alert flush | timers | Only while something waits to be posted | |

**Client**

| Loop | Interval | Why that often |
|---|---|---|
| Death watcher | 1 s, while a character is loaded | The server waits a few seconds for the victim's own report before attributing a death without it. A few natives a pass, the state bags read once, nothing made (was two reads through a new closure each, 80 bytes of garbage a pass); an event only when the answer changes. It runs for every player, not only those on a contract: a game told when a contract named it would tell a target there is one |
| Mask watcher | 1 s, only while `Config.Targeting.AllowNearby` is on | One native a pass; an event only when the mask changes |
| Roleplay NPCs | 1 s within 160 m of an NPC or while one is drawn, 2 s further off; **no thread at all with both off** (was a 2 s look at an empty table, all game) | An NPC appears within 80 m; 160 m is the ground a car covers in two seconds and more. The loop starts when the server says an NPC stands somewhere (at start, or when one moves or is switched on) and ends on the pass after both are switched off. Peds go at logout and are not drawn on the character screen |
| App heartbeat | 15 s | Puts the app back on a phone that lost it; nothing is sent |
| Asking for access | 2, 2, 2, 5, 5, 10 s, then 30 s, until answered | A start that missed the join push |
| Admin panel Escape guard | every frame, only while the panel is open | It reads the key |
| Phone page (`ui/app.js`) | handover poll, 1 s on screen and 5 s put away, only while one runs; **nothing else** (was a 30 s repaint of the deadline chips, phone put away included) | lb-phone keeps the app's frame alive all game. Put away (lb-phone's `onClose`, passed on by `client/main.lua`, or the document hidden), a push only notes what it asked for, and the page reads it once when shown again; an answer the same as the one on screen is not drawn again. The chips are the server's band, which only a new read moves |
| Admin panel (`ui/admin.js`) | overview every `Config.Admin.PanelRefreshSeconds` (10 s), only while open | Stopped on close. An overview answer the same as the last one only moves its *Updated* time |

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
- **a roleplay NPC near** (`Config.Roleplay.Rumours`,
  `Config.Roleplay.InformantNpc`): the ped is made within 80 m, a spike as
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

| Issue | Solution |
|---|---|
| A player cannot find the app | It is in the phone's App Store; each player downloads it. `Config.App.DefaultInstalled = true` puts it on every eligible phone. Barred jobs see only the whitelisted-job view. `/ch-diag <player>` says why it is not showing |
| A kill does not complete a contract | As shipped `Config.Completion.Fulfilment = 'alive'`: only a live handover completes one. Set `'either'` for kills; contracts already placed keep their rule |
| A new character can be targeted, or an old one cannot | `/ch-diag <player>` shows what the playtime rule reads for them; correct one character's hours under **Players** |
| The informant is not offered | Each informant ships off; the target's is never offered to a whitelisted-job member; the placer's only while an operative they do not know is on the contract |
| A staff command typed in chat answers nothing | It answers in your F8 console |
| *Not authorised* | Grant the ACE ([Permissions](#permissions)); the server checks on every request |
| The console prints `N setting(s) need attention` | `/ch-diag` lists each in full, or set `Config.Debug = true` |
| The console says nothing at all | `Config.Debug = false`: a sound start says nothing |
| `BOOT RECOVERY FAILED` | Recovery raised (the text says why); the app and money writes stay closed until a restart that recovers. Fix the cause and restart |
| *The server's records did not answer in time* | `mysql` was unreachable or held past `Config.Database.QueryTimeoutSeconds`; payments caught are settled once it answers. Wait for `/ch-diag` to say `database: answering` |
| `still waiting … for … resource(s) to start` | `qbx_core` or `ox_inventory` is not started, or runs under another name |
| The app stopped after restarting `qbx_core`, `ox_inventory` or `oxmysql` | `ensure crimson-hitman` |
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

**1.1.0, the panel's reward, reassign and disposal controls (newest)**

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
- Ending a staff freeze, the app pause or the restart hold gives every contract its held time back before the expiry pass can end one; a kill made in the minutes before the restart hold can still be verified once the hold is skipped; skipping the hold (or reaching `Config.Restart.MaxHoldMinutes`) tells every party *Contracts are no longer paused for the server restart.* and refreshes their pages.
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
