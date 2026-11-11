# Changelog

What changed for server owners, staff and players, newest first. Settings
are named by their place in `config/config.lua`; the README has the details.

## 1.2.0

**Config check**
- `/ch-diag config`, and **Check the config** under Developer, Health: every
  value out of range or invalid, every script a switched-on feature needs
  and lacks, every staff ACE `group.admin` does not hold and the commands it
  may not run, and the risky combinations, each in plain words with the fix.
  Reads only.

**Version check** (`Config.VersionCheck`, off as shipped)
- `Enabled = false` and `Url = ''` as shipped: nothing is ever asked. On,
  with an https address, one plain GET at start (no body, no headers of its
  own, an address with a query or fragment refused unasked) and one console
  line when the answer names a newer version. The switch is under Developer,
  Engine settings; the address is config.lua's.

**Translations** (`Config.Locale`, `'en'` as shipped)
- The words players and staff read are looked up by key in language files:
  `locales/en.lua` (notices to players, police advisories, staff alerts and
  their Discord posts, staff notices, the phone app's icon, map markers and
  target options) and `locales/en.json` (the phone's and the panel's
  refusals). Copy both to a language of your own and set `Config.Locale`; a
  key it lacks reads in English, said once in the console. The wording is
  unchanged. The pages' other labels and the server's refusal sentences
  follow in later steps (README, Escrow, and where the words live).

**Organisation extras 3** (each its own switch under `Config.Organisation`, off as shipped)
- **Several organisations** (`SeveralOrganisations`, `MaxOrganisations`):
  staff add rival organisations in Hitman organisation, Setup; each is its
  own qbx_core job with its own roles, members, funds, places, Boss
  permissions and log; a citizen is in one at most. Staff ops take `org`; a
  member's phone works on their own; outsiders and placers pick one.
- **Reputation and tiers** (`Reputation`, `RepTiers`): from members'
  completions and failures, less their heat; a tier caps what a member may
  accept. Staff adjust it.
- **Dead drops** (`DeadDrops`): with P4, payouts wait in escrow at a staff-set
  dead drop until collected; unclaimed, paid or refunded (`DeadDropUnclaimed`).
- **Territory** (`Territory`, needs `OrgContracts`): staff zones give the
  organisation a short first refusal on a contract on somebody there, only
  while a member stands near them; nobody is told why or where.
- **Garage** (`Garage`, `GarageVehicles`): staff-approved vehicles at the
  garage spot, through the new garage adapter (`Config.Integrations.Garage`,
  `onesync` or `none`).
- **Internal contracts** (`InternalContracts`): K8 asks for a contract on a
  rogue member; only staff approve it; placed by the boss with every limit.
- **Handler** (`Handler`): NPC spots brief members and hand out waiting
  contracts. **Activity log** (`ActivityLog`): M12 reads what members did.
- Four new Boss permissions rows (P4, V1, K8, M12), off until staff allow
  them; staff do all of it from Hitman organisation, Reputation, drops &
  garage, and Locations (Dead drops, Garage, Territory).

**Organisation extras 2** (each its own switch under `Config.Organisation`, off as shipped)
- **Armory** (`Armory`, `ArmoryItems`): an ox_inventory stash only the app
  reaches; members put in the items staff allow and take out their role's
  limit a day; every move logged. Off with no inventory script, in one line.
- **Record and leaderboard** (`Stats`): each member's completions, failures,
  earnings and reliability, filling Your record; players see time bands only.
- **Discipline** (`Discipline`): strikes and written warnings, decaying,
  barring from contracts or demoting at their marks; only staff overturn.
- **Recruitment** (`Recruitment`): a boss's application form, interview notes,
  a cooldown after a decline and a cap an hour.
- Five new Boss permissions rows (A1, A2, M10, M11, N4), off until staff allow
  them; staff do all of it from Hitman organisation, Armory, Record &
  discipline and Applications.

**Organisation extras** (each its own switch under `Config.Organisation`, off as shipped)
- **Contracts to the organisation** (`OrgContracts`): a placer may send a
  contract to the organisation; a boss assigns it to a member, and it goes on
  the open board if nobody takes it within `AssignMinutes`. The placer is never
  shown to the organisation.
- **Accept approval** (`AcceptApproval`): bigger accepts, or any on probation,
  wait for a boss; nothing is taken while they wait.
- **Probation** (`Probation`), **Duty** (`Duty`, with qbx_core's duty), a
  **private channel** (`Channel`, table `crimson_org_messages`) and
  **dossiers** (`Dossiers`) on assigned organisation contracts.
- Seven new Boss permissions rows (K4-K7, M8, M9, N3), off until staff allow
  them; staff do all of it from Hitman organisation, Work & channel.

**A crash no longer loses money or its record** (`mysql`)
- Money audit rows (payouts, buyouts, tips, deposits) are kept on the
  server machine the moment they are made, and written at the next start
  if the server crashes before the log is written.
- A crash part-way through an acceptance no longer leaves the hitman stuck
  on a contract still shown as open: the next start puts it right.
- An intel purchase (tip, informant, going dark) a crash interrupts is kept
  if it was recorded and refunded if not, once.
- The organisation's Renewed-Banking account and its ledger no longer
  drift apart in a crash: a salary or withdrawal that left without a ledger
  row is put back (so the pay day pays once), a salary taken from the funds
  but not yet handed over is paid (it was left for staff), a deposit that
  arrived gets its row, and a member's deposit that was charged is made.
- A payout a crash cut off and left for staff keeps what the player held
  when its give began: a buyout settle started again no longer overwrites
  it (staff following it paid the premium twice), and a payout paid as
  dirty money counts that item, not their cash. Stuck escrow says
  "paid as black_money, so check that".
- A hitman who leaves the city while their kill is being verified still
  has the body to dispose of; it was skipped and the kill paid at once.
- Staff Pay on a stuck payout held for proof of intent now settles it (owed
  and queued behind the hold, off the stuck list); it answered "nothing to
  settle" and the line stayed stuck.

**Lighter loops**
- The condition sampler no longer runs while no contract is running; it
  starts again the moment one is placed. `ch-diag` says `idle` meanwhile.
- An unworked hold's idle clocks are written in one statement a pass on
  `mysql` (was one a hold), and on `json` in a small file of their own,
  `data/clocks.json`, instead of rewriting `records.json` every tick.
- The broker and informant and the organisation's NPCs share one distance
  loop. Every loop is listed in `docs/dev/loops.md`.

**Other scripts are optional, behind adapters**
- Every script this resource works with besides Qbox is optional:
  `ox_inventory`, `ox_target`, `lb-phone`, `sc-dispatch`, `sc-ambulance` /
  `qbx_medical`, `Renewed-Banking`, `qbx_vehiclekeys`, `MugShotBase64`,
  `sc-blackmarket` and the clothing scripts. Each kind is chosen in
  `Config.Integrations` (`'auto'` as shipped picks what is started, so a
  server with all of them runs as before). One that is missing or set to
  `'none'` turns off only what needs it, said in one console line.
- Add an adapter for another script in a few lines: `docs/dev/adapters.md`
  and the templates in `server/adapters/` and `client/adapters/`.
- `ox_inventory` is no longer a manifest dependency: restarting it no longer
  stops this resource. Without an inventory, cash and bank rewards still work.
- Merged into `Config.Integrations`: `Config.Completion.DeathStateProviders`
  (now `Ambulance`), `Config.Organisation.Funds` (now `Banking`; `'internal'`
  is `'none'`) and `Config.Record.Progression.Resource` (now `Progression`).
- With no phone, notices show in the game's feed.

**First-start setup**
- The admin panel opens a setup screen for the first staff member, until a
  setup is saved: storage mode, the other scripts found (with an override),
  the exact `add_ace` lines, the panel command and the key switches, all
  showing the current values. Preview, then apply with two clicks. It opens
  again from Developer, First-start setup.
- Install in 5 minutes, at the top of the README; this changelog.
- The editable files (config, adapters, install SQL, data) are left out of
  escrow.

**Simpler, with nothing lost**
- One design system for the phone app and the admin panel; a dashboard,
  help on every screen, plainer words and fewer clicks; presets (Strict,
  Relaxed, Roleplay-heavy, Current), previewed before they apply.
- One way to do each job: one marker system, one Places registry for every
  map spot, one Measures area (freeze, suspend, protect, target limits),
  one Holds service, one rules table per target class, one Intel engine,
  one police and press path, one Discord sender, one log view, one Record
  (trust, reputation, tiers, heat, placer record), one payout check.
- Every setting, permission check, audit line and feature is still there
  (checked by the capability inventory test).

## 1.1.0

- **Mission steps**: map markers for each step (on) and body disposal (off).
- **Confirm handover** for the placer (off); staff **Change reward** and
  **Reassign** a hitman.
- **The hitman organisation** (off): a Qbox job with roles, boss
  permissions, funds and cuts, codenames, payroll, a phone tab and a boss
  menu.
- **The admin panel rebuilt** by task (Daily, Setup, Records, Developer),
  with search, Players and Contracts workspaces, Target limits, Boss
  permissions and Locations.
- Review fixes across buyouts, target limits, anonymity and reassigning.

## 1.0.0

- Contracts placed from the phone with rewards held in escrow; competitive
  and exclusive contracts; live handovers and verified kills; buyouts;
  anonymity; informants and tips; advisories to officers; staff tools
  (freeze, suspend, protect, notes, manual pay, review queue, alerts,
  daily summary); roleplay features and improvements, all off as shipped;
  json, mysql and memory storage.
