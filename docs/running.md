# Running the server

Where everything is kept, what happens after a crash, the console and
Discord, moving settings between servers, adding a language and what the
resource costs. Installing is in the [README](../crimson-hitman/README.md).

## Database

The tables are made on the first start (utf8mb4, InnoDB;
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
characters, times until 2038-01-19. An organisation's settings (with its
activity log and discipline record) are `MEDIUMTEXT` and an application's
answers `TEXT`; a start widens the columns an older version made narrower,
keeping every value.

`json` mode keeps everything in files under `crimson-hitman/data/`
(`store.json`, `records.json`, `contracts/`, `audit-<day>.jsonl`,
`playtime.json`, `clocks.json`, `heartbeat.json`, `photos/`, and the
`.prev` copies of the first two): back it up or move it as the whole folder.
It needs no database; it does not suit thousands
of live contracts. Kill photo files are in `data/photos/` in every mode.

## After a crash, and when the database stops answering

- A crash never charges downtime to a deadline: running contracts are paused for at least as long as the server was down. Claims and endings the crash cut short are finished at the next start, and their parties told.
- Balances move through `qbx_core`'s `Save`; items and dirty money are `ox_inventory`'s, saved every five minutes. After a hard crash, compare the last five minutes of `escrow_*`, `stake_taken` and `pending_delivered` audit rows with what those players carry.
- `mysql`: no statement waits longer than `Config.Database.QueryTimeoutSeconds` (10 s). The console says when the database stopped answering and when it answers again; players are told *The server's records did not answer in time*, and a payment caught in the middle is settled by the server once it answers (kept on the machine meanwhile, restarts included). `/ch-diag` says whether it answers now. Wait; restart only once it says `database: answering`. Back up with `mysqldump --single-transaction`, never `--lock-tables` during play.
- If the staff freezes cannot be read (at the start or later), every live contract is held until they can be: the console says so once and then every five minutes, the read is tried again after a wait that grows to five minutes, the Dashboard's **Frozen** reads *Unknown*, and a held contract's badge reads *store unreadable* (*held* without IdentityAce). The first good read gives every contract back the lifetime the outage took.

## Console output and Discord

`Config.Debug = true` (as shipped) prints start progress, every setting
problem in full and slow jobs (`Config.Diagnostics.SlowJobMs`). Off, a sound
start prints nothing; only refusing to start, money left for staff and failed
writes are printed, and one line counts the settings that need attention.
`/ch-diag` lists all of it either way. The audit mirror
(`crimson_hitman_webhook`) posts money movements and refusals without
identities, one message per flush; alerts and the daily summary go to
`crimson_hitman_alert_webhook` (or the audit one).

## Moving your settings

To copy your settings to another server, or keep a copy: Developer, **Export & import**, **Export the settings**, then **Copy**. The text holds every setting changed from the panel (never a secret: the webhooks stay in server.cfg) and your own presets. It does not hold the map places (Locations) or the target limits set for a job or a player (Target limits): those belong to one server's map, jobs and characters. On the other server, paste it under Import and **Read it**: every change (from, to), every key refused and why (one the panel never changes, one this version does not have, one read-only, a value it would refuse) and the presets it would add. Nothing changes until **Apply it**, two clicks naming how many changes; each is then an ordinary setting change, audited and in Change history with Undo.

## Version check

Off as shipped. Set `Config.VersionCheck.Enabled = true` and `Config.VersionCheck.Url` to an https address that serves the latest version number (plain text such as `1.3.0`, or JSON with it in a `"version"` or `"tag_name"` field). The server asks it once at start, with a plain GET: no body, no headers of its own, and an address with `?` or `#` (or a user name) in it is refused unasked, so nothing about your server is sent. A newer version is one console line; anything else says nothing. With no address (as shipped) nothing is ever asked.

## Adding a language

To add a language (say German, `de`):
1. Copy `locales/en.lua` to `locales/de.lua`, `locales/client/en.lua` to
   `locales/client/de.lua` and `locales/en.json` to `locales/de.json`.
2. In `de.lua`, change `CrimsonLocales.en` to `CrimsonLocales.de` (twice: the
   table and the `return` at the end), and in `client/de.lua`
   `CrimsonClientLocales.en` to `CrimsonClientLocales.de` the same way.
3. Translate the texts on the right. Keep every `%s` and `%d` in its order
   (names, numbers and amounts go there) and the keys on the left as they
   are. Leading spaces and a leading `->` in a diagnosis line are layout:
   keep them. In `de.json` a value may name its values by place (`%2$s`,
   `%1$s`) to put them in another order, and a key ending `_one` / `_other`
   is one text in its singular and plural (add `_few`, `_many` if German
   needed them: the page picks the form the language's rules ask for).
4. Set `Config.Locale = 'de'` in `config/config.lua` and restart.

A key your file leaves out reads in English, and the console says so once;
you can translate a few screens and leave the rest. The pages show their
texts as plain text: write `&` and `<` as they are.
The start-up checks, their warnings and notes, and the lines about a missing
script print in the server's language, since the panel's diagnosis shows the
same lines; the rest of the console stays English, and so do the files that
only ever print to the console (the stores, `server/boot.lua`,
`server/versioncheck.lua`). Labels a server owner sets are in
`config/config.lua` (the witness-report and heat-bulletin titles, the city
news account and its templates, the command names); the officers' threat
advisory titles are translated text, `notify.threat_advisory*` in
`locales/<lang>.lua`.

## Performance

Nothing runs per frame while idle, every optional feature costs its job
one comparison while off, and the loops that can sleep until something is
due or something happens do. `/ch-diag` lists every maintenance job with
this server's own worst, average and last times and its interval. What
each loop and request costs, as measured, is in the developer notes
(`docs/dev/loops.md`).

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
how often it runs and its worst, average and last times.
`ch-diag <player>` also asks that player's app what it has seen, which
helps when one player's figure is high and nobody else's is. A figure that
stays high with the phone put away and no NPC near is worth reporting with
both.

