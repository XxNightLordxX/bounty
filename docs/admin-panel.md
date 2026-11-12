# Admin panel

What staff see and do in the panel, section by section, and Target limits.
Who may open what is the README's [Permissions](../crimson-hitman/README.md#permissions);
the staff commands are the README's [Admin panel and commands](../crimson-hitman/README.md#admin-panel-and-commands).
The requests the page sends are listed for developers in
`docs/dev/panel-requests.md`.

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
| **Contracts** | Contracts | The one list of contracts. Search and filter (state, rule, when placed), narrow it to **one person** (a player id, citizen id or name, or *Their contracts* from a player's card) with their part on each (**Target**, **Placer**, **Hitman**; an anonymous part only with `crimson.identity`, which also gets **Whois** on each row), or list the live ones **by target**; then open one. Above the list, every body being disposed of ([body disposal](features.md#mission-steps)) with the exact time left, **Skip** and **Respawn vehicle**. The drawer has tabs: **Summary** (terms, the deadline with **Extend** / **Shorten**, open proposals), **Money** (lines waiting for staff, payouts, **Change reward** with the server's figures before it arms, escrow lines; its tab counts the lines waiting), **People** (operatives, **Remove an operative**, **Reassign to another hitman** looked up in Players, *As a player sees it*, Whois), **Notes & text** (staff notes, **Edit text**) and **Record** (timeline, export). **Void** is under **More** |
| **Target limits** | Defaults, Per job, Per player; **History ▸**, **Live contracts by target ▸** | See [Target limits](#target-limits). **History ▸** opens Records › Logs on the audit log's `staff_target_` rows; **Live contracts by target ▸** opens Contracts listing the live ones by target |
| **Game rules** | Areas, Presets, Changed from the panel; **Change history ▸** (Records › Logs, Setting changes) | Every rules and features setting by the area of the game it is about (who can use the app, placing contracts, anonymity, rewards & payouts, completing a contract, buyouts, Intel, record & standing, police & city news, phone messages & notifications, roleplay extras, staff tools & alerts, other): an area's switches first, then its numbers and lists. Chips narrow it to **Switches**, **Timers**, **Money**, **Limits**, **Lists** or **Changed**, across every area when none is picked. A row shows its label with its unit, its control and Save or Reset; **Details** shows its `Config` key, what it does, what happens to things under way and where its value comes from. **Undo all panel changes** is on *Changed from the panel*; every change, with **Undo**, on *Change history*. **Presets** are named bundles of settings (*Strict*, *Relaxed*, *Roleplay-heavy*, and *Current*: the server's own values, saved by hand or before any other preset is applied): each card lists every change it would make, from what to what, and what the server would refuse and why; nothing changes until **Apply**, two clicks naming how many changes. Each change is then an ordinary setting change, audited and in *Change history* with its Undo, and the apply itself is audited (`admin_preset_applied`). **Your own presets**: type a name and **Save the panel's changes as a preset** (two clicks) to keep every setting changed from the panel now under that name (up to 20, stored with the settings, audited `admin_preset_saved`); it is listed after the shipped ones, marked *yours*, previewed and applied the same way, and **Delete** (two clicks, audited `admin_preset_deleted`) takes it away |
| **Hitman organisation** | Setup, Roles & pay, Members, Applications, Funds & cuts, Contract access, Notices, Work & channel, Armory, Record & discipline, Reputation, drops & garage; **Org audit ▸** (Records › Logs, Org audit) | See [Organisation](features.md#organisation). Off as shipped: every tab is one card saying so, with its switch |
| **Boss permissions** | Matrix, Limits, Delegation & office; **Grant history ▸** (Records › Logs, Grant history) | The ceiling on what bosses may do: powers by boss role and by one boss (**Allow**, **Deny** or **Inherit role**), every change listed before one **Save** that sends them together; **Revoke all** and **Copy from** per column; each power's limits; which powers need the boss office; every grant, with **Undo** on a role's |
| **Locations** | Map points | The organisation's places (boss office, sign-up, meeting and handover spots, NPC spots), body disposal's vehicle spawn and drop-off (**Save**, **Save where I stand**, **Clear**), and the places that are settings (broker and informant NPC places, tip safe zones, rumour districts, witness areas, the prison zone). **Use my position** fills a row from where your character stands, read by the server |
| **Logs** | Logs, Alerts | Every log in one view, one chip each: **Audit log** (search it, and flush it), **Setting changes** (every setting changed from the panel, with **Undo**), **Org audit** (every boss and staff action on the organisation) and **Grant history** (every grant, with **Undo** on a role's). Each section's own link (Game rules, Hitman organisation, Boss permissions, Target limits) opens it with its chip picked. Alerts: acknowledge alerts, see where Discord stands, send a test alert |
| **Developer** | Health, Engine settings, Console, Test tools, First-start setup, Export & import | Storage, recovery, kill photos, slow jobs and the diagnosis; debug, storage, rate limits, the other scripts (`Config.Integrations`) and the read-only values; the console; **Bring timers forward** (test servers) and **Flush the audit log**; the **first-start setup** (shown by itself to the first staff member with `crimson.admin` until it is saved: storage mode, the other scripts found with an override, the exact `add_ace` lines and who holds them, the panel command and the key switches, every one at the value in force; **Preview**, then **Apply** in two clicks, each change a setting change in Change history with Undo, audited `admin_setup_applied`); **Export & import** of the settings changed here ([running.md](running.md#moving-your-settings)) |

Without `crimson.identity`, an anonymous party is *Anonymous* everywhere,
citizen ids read as the party's place (*the placer*, *the target*,
*operative <alias>*) and searches never find a contract through an anonymous
party. Every unmasking is its own audit row.


## Target limits

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

