# Changelog

What changed for server owners, staff and players, newest first. Settings
are named by their place in `config/config.lua`; the README has the details.

## 1.2.0

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
