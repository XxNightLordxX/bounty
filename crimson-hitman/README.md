# Crimson Hitman System

A criminal contract board for **QBox**, played from an **lb-phone** app
(**Crimson-Hitman**) and run by staff from an in-game admin panel
(`/hitmanadmin`). This is the owner's README: what you need, how to install
it, where the settings are and what to do when something looks wrong. Every
other document is listed at the end.

## What it is

1. A player places a **contract** on another player from the phone, naming a **reward**; the money is taken at once and held (escrow).
2. A **hitman** accepts it from the board and finishes it: as shipped by bringing the **target** alive to the **placer** for a live handover (a verified kill can count too, if you allow it).
3. The held reward pays the hitman; a contract that ends any other way hands it back. Nothing is promised that is not held.
4. The target can see contracts on them under **On me** and buy one out; officers are warned when one of them is targeted.
5. Staff watch, freeze, void, pay and tune all of it live from the admin panel, and every money movement is in the audit log.

How a contract plays, step by step, is in [docs/how-it-works.md](../docs/how-it-works.md).

## Requirements

Only `qbx_core` (with `oxmysql`) is required. Every other script is optional:

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
| `ox_lib` | Through `qbx_core` (this resource calls none of it) | 3.40.3 |
| `sc-ambulance` / `qbx_medical` | Optional: death and last-stand state, the defibrillator | |
| `sc-dispatch` | Optional: advisories and bulletins in the MDT | |
| `sc-blackmarket` | Optional: criminal progression, selling the burner phone | |
| `MugShotBase64` | Optional: target headshots | |
| `qb-clothing` / `illenium-appearance` / `rcore_clothing` | Optional: a change of clothes refreshes the headshot early | |

**Adapters.** Each optional script is reached through an adapter, one per
kind, chosen in `Config.Integrations`: `'auto'` (as shipped) uses the first
one installed and started, a name (`'sc-dispatch'`) uses that one only, and
`'none'` turns the kind off. A kind left without a script turns off only
what needs it and says so in one console line at start, never an error.
To use another script (another dispatch, inventory or phone), copy
`server/adapters/TEMPLATE.lua` or `client/adapters/TEMPLATE.lua`; how is in
the developer notes (`docs/dev/adapters.md`).

## Install in 5 minutes

1. Copy `crimson-hitman` into your resources folder (another folder name works; use it in the `ensure` line).
2. Put `ensure crimson-hitman` in `server.cfg`, after `oxmysql`, `qbx_core` and the other scripts you use (`ox_inventory`, `lb-phone`, `ox_target`, ...); with the organisation on, before `Renewed-Banking` ([features.md](../docs/features.md#organisation)).
3. Give yourself the panel: `add_ace group.admin crimson.admin allow` in `server.cfg` (the other ACEs: [Permissions](#permissions)).
4. Open `config/config.lua`: set `Config.Database.Mode` (`'mysql'`, as shipped, or `'json'`). Everything else can wait.
5. Start the server and type `/hitmanadmin` in game. The **first-start setup** opens: check the other scripts it found, the permissions, the command and the key switches, **Preview**, then **Apply** (two clicks). It opens again from Developer, First-start setup.

In `mysql` mode the tables are made on the first start; a database user that
may not create tables imports `install/sql/crimson_hitman.sql` first (the
tables and limits: [docs/running.md](../docs/running.md#database)). With
`Config.Debug = true` (as shipped) the console prints `[crimson-hitman]
started in mysql mode` and every warning in full; with it off, a sound start
prints nothing. Players download the app from the phone's **App Store**, or
`Config.App.DefaultInstalled = true` puts it on every eligible phone.

What to check once it runs: the **First hour in game** plan at the top of
[docs/in-game-checklist.md](../docs/in-game-checklist.md).

## Main settings

Every setting is in `config/config.lua`, the one file to edit, in the admin
panel's order; each is listed with its shipped value in
[docs/configuration.md](../docs/configuration.md). Most can also be changed
live in the panel (**Game rules**, and Developer, Engine settings), which
keeps its change over the file across restarts. `config/defaults.lua` only
fills a section missing from an older `config.lua`; do not edit it.

**Read these before you open the server:** `Config.Database.Mode` (where
everything is kept), `Config.Completion.Fulfilment` and
`Config.Kidnap.RequireCoercion` (how a contract is finished),
`Config.BlockedJobTypes` / `BlockedJobNames` and `Config.WhitelistedView` (who
may use the app), `Config.Limits.MaxPayoutSlots` and
`Config.Limits.MinContractReward` (what a contract pays) and `Config.Debug`
(what the console prints).

**Where each optional feature is switched on** (in the panel, Game rules,
and in `config.lua` under the same section title; what each does is in
[docs/features.md](../docs/features.md)):

| Feature | Switch | Shipped |
|---|---|---|
| Anonymity | `Config.TargetClasses.default.AllowAnonymousPlacer`, `AllowAnonymousHitman` (and `Config.TargetClasses.whitelisted`) | off |
| Informants (target's, placer's, the tip) | `Config.Intel.Enabled` (the master switch, on), then `Config.Intel.Informant.Enabled`, `Config.Intel.PlacerInformant.Enabled`, `Config.Intel.LocationTip.Enabled`, per target class (`Config.TargetClasses`) | each off |
| Intel rules (tip rules, go dark, the informant in person, rumours) | `Config.Intel.<Feature>.Enabled` | all off |
| A hitman's record (progression, reputation, tiered board, heat, placer record) | `Config.Record.<Part>.Enabled` | progression on, the rest off |
| Law enforcement advisory | `Config.Advisory.Enabled` | on |
| Staff tools (app pause, daily summary, alerts) | `Config.Holds.AppPaused`, `Config.Staff.DailySummary`, `Config.Staff.Alert*`, `Config.Alerts.ToDiscord` | pause and summary off, alerts on |
| Roleplay (10 features) | `Config.Roleplay.<Feature>.Enabled` | all off |
| Improvements (4 features and a cooldown) | `Config.Improvements.<Feature>.Enabled`, `Config.Limits.TargetCooldownAfterCompletionSeconds` | all off |
| The hitman organisation | `Config.Organisation.Enabled`, then one switch per extra | off |
| Step markers, body disposal | `Config.StepMarkers.Enabled`, `Config.Disposal.Enabled` | markers on, disposal off |

**Secrets never go in `config.lua`** (every player's game downloads it). The
Discord webhooks are convars in `server.cfg`, set with `set`, never `setr`
(which sends the value to every player): `set crimson_hitman_webhook "..."`
(the audit mirror), `set crimson_hitman_alert_webhook "..."` (alerts and the
daily summary) and `set crimson_hitman_stats_webhook "..."` (the weekly
stats). What each posts: [docs/running.md](../docs/running.md#console-output-and-discord).

## Admin panel and commands

`/hitmanadmin` opens the panel in game; every staff command below is a
button there too. Its sections: **Daily** (Home,
Players, Contracts, Target limits), **Setup** (Game rules, Hitman
organisation, Boss permissions, Locations), **Records** (Logs) and
**Developer** (Health, Engine settings, Console, Test tools, First-start
setup, Export & import), with **Help** in the header. How it works and what each section
holds: [docs/admin-panel.md](../docs/admin-panel.md).

The same tools as commands, run in your **F8 console** in game (the answer
prints there, never in chat) or the server console. The names are
`Config.Admin.Commands`. The `<contract>` id is the **Ref** at the foot of
every card and Ledger entry.

| Command | What it does | Needs |
|---|---|---|
| `/hitmanadmin` | Opens the admin panel (in game only) | `crimson.admin`, `crimson.moderator` or an extra ACE |
| `/ch-diag [player]` | Why the app is not showing something; the database, the loops and a player's own view | `crimson.admin`, `crimson.moderator` or an extra ACE |
| `/ch-contracts <player>` | A player's contracts with their ids | `crimson.admin`, `crimson.moderator` or an extra ACE |
| `/ch-timeline <contract>` | One contract's state, escrow and audit trail | `crimson.admin`, `crimson.moderator` or an extra ACE |
| `/ch-stuck` | Money waiting for staff, and open review items | `crimson.admin`, `crimson.moderator` or an extra ACE |
| `/ch-whois <contract>` | Who is behind an anonymous party | `crimson.identity` |
| `/ch-void <contract> [reason]` | Close a contract and refund its placer (moderators void from the panel) | `crimson.admin` |
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

## Permissions

| ACE | Opens | Grant |
|---|---|---|
| `crimson.admin` (`Config.Admin.Ace`) | The panel and every command; every write (settings, money, settling, reviews) | `add_ace group.admin crimson.admin allow` |
| `Config.Admin.ExtraAces` (`command` as shipped) | Reading: the panel's read-only sections, `/ch-diag`, `/ch-timeline`, `/ch-stuck`, `/ch-contracts` | already held by the ACE named |
| `crimson.moderator` (`Config.Admin.ModeratorAce`) | Reading without identities; in the panel: freeze, suspend, protect, void, move deadlines | `add_ace group.<your moderators> crimson.moderator allow` |
| `crimson.developer` (`Config.Admin.DeveloperAce`) | The Developer section (console, diagnostics, developer settings); `crimson.admin` always has it | `add_ace group.admin crimson.developer allow` |
| `crimson.identity` (`Config.Admin.IdentityAce`) | Who is behind an anonymous party, every citizen id, `/ch-whois` | grant to few: `add_ace identifier.license:<licence> crimson.identity allow` |

## Updating

- **Keep `crimson-hitman/data/`** when you put a new version in place (copy the new files over the old folder, or move `data/` out and back). In `json` mode it is the store; in every mode it holds the kill photos. A `json` store that finds an empty `data/` after it has run refuses to start; put the old one back, or `set crimson_hitman_new_store 1` once to start empty on purpose.
- Carry your `config/config.lua` across. Settings changed in the panel are kept in the store and survive the update.
- Payouts an older version left owed appear once under **Money waiting** in the panel's inbox (`/ch-stuck`): check the player has it, then **Pay** or **Delivered**.
- Restarting `qbx_core` or `oxmysql` stops this resource with them: `ensure crimson-hitman` afterwards. Restarting `lb-phone`, `ox_inventory` or any other optional script is safe: what needs it is off while it is down, said in one console line.
- Moving your settings to another server, and the optional version check (`Config.VersionCheck`, off as shipped): [docs/running.md](../docs/running.md#moving-your-settings). What changed in each version: [CHANGELOG.md](CHANGELOG.md).

### Changing storage mode

Modes do not share data. The start refuses to begin in a new mode while the
old one still holds players' money (escrow, payouts owed, a review item, a
payment kept for that mode), and lists up to ten contracts with what each
holds and what clears it: let it finish, the placer withdraws it, staff void
it (`/ch-void`), the player logs in, or `/ch-stuck` and `/ch-settle`; and each
review item (`/ch-review` in the old mode). Switch back, clear them, switch
again. `Config.Database.AllowModeSwitch = true` starts anyway, for money
already settled by hand.

## Escrow, and where the words live

On an escrowed build (FiveM Asset Escrow) everything you edit stays readable:
`escrow_ignore` in `fxmanifest.lua` leaves out `config/*.lua`, the language
files (`locales/*.lua`, `locales/client/*.lua`) and the adapters
(`server/adapters/`, `client/adapters/`), so you can change settings, words
and integrations without the source. The pages (`ui/`), `install/sql/` and
`data/` are never escrowed, as only Lua is.

The escrowed build starts like the open one because every Lua file the
resource runs is listed in `fxmanifest.lua`, the only way FiveM decrypts
one: the server's modules load through the manifest, never by reading a
file. So a Lua file you add (an adapter, a language) has to be in a folder
the manifest already lists, as those are, and a server adapter names its own
path on its first line (`server/adapters/TEMPLATE.lua` says how).

**Translations.** The words players and staff read are in language files,
by key: `locales/en.lua` (the server's: notices, advisories, staff alerts,
the panel's answers and setting labels, the commands and the diagnosis),
`locales/client/en.lua` (the game's own: the app's name, map markers, target
options; the only language file sent to every player) and `locales/en.json`
(every word of the phone app and the admin panel). `Config.Locale` (`'en'`)
names the language; a key your file leaves out reads in English. To add
one: [docs/running.md](../docs/running.md#adding-a-language).

## Troubleshooting

Start with **`/ch-diag [player]`** (F8 or the server console, or **Developer
→ Health → Run the diagnosis** in the panel). It says whether the app is
closed while boot recovery runs or failed, whether the database answers, how
long ago each loop ran, every setting that needs attention, and, for a
player, what each of the app's reads answers for them and why the app is or
is not showing.

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
| The informant is not offered | Each informant ships off; the target's is not offered to a whitelisted-job member unless `Config.TargetClasses.whitelisted.Informant` is on; the placer's only while an operative they do not know is on the contract |
| A staff command typed in chat answers nothing | It answers in your F8 console |
| *Not authorised* | Grant the ACE ([Permissions](#permissions)); the server checks on every request |
| The console prints `N setting(s) need attention` | `/ch-diag` lists each in full, or set `Config.Debug = true` |
| Not sure the config is right | `/ch-diag config` lists every value out of range, missing script, missing ACE and risky combination, each with its fix |
| The console says nothing at all | `Config.Debug = false`: a sound start says nothing |
| `BOOT RECOVERY FAILED` | Recovery raised (the text says why); the app and money writes stay closed until a restart that recovers. Fix the cause and restart |
| *The server's records did not answer in time* | `mysql` was unreachable or held past `Config.Database.QueryTimeoutSeconds`; payments caught are settled once it answers. Wait for `/ch-diag` to say `database: answering` ([after a crash](../docs/running.md#after-a-crash-and-when-the-database-stops-answering)) |
| `still waiting … for … resource(s) to start` | `qbx_core` is not started, or runs under another name |
| The app stopped after restarting `qbx_core` or `oxmysql` | `ensure crimson-hitman` |
| `integration <kind> off (...)` in the console | That script is not started, or `Config.Integrations.<Kind>` is `'none'` or names no adapter: what the line says is off. Start the script, or add an adapter ([Requirements](#requirements)) |
| `missing module server.adapters.<kind>.<name>` | An adapter of your own whose first line does not name its own path, or that sits in a folder the manifest does not list ([Escrow](#escrow-and-where-the-words-live)) |
| `json` refuses to start on an empty `data/` | You lost `data/` in an update: put it back, or `set crimson_hitman_new_store 1` once |
| It refuses to start after changing `Config.Database.Mode` | The old mode still holds money: see [Changing storage mode](#changing-storage-mode) |
| `failed to start: mysql mode cannot start: the database is missing what it needs` | Your user may not create or alter tables: import `install/sql/crimson_hitman.sql` as a user that may, or run the printed `ALTER TABLE` |
| `table crimson_… already exists … and is not this resource's` | Another resource owns that table name: rename it, or give crimson-hitman its own database |
| A panel change is back to config.lua's value after a restart | An edit to config.lua made the override invalid; the start lists it among the settings that need attention |
| A value is refused in the panel with a sentence about another setting | It is checked against everything else in force: change the other one first |
| `photo hosts: 0`, or kill photos refused as not allowed | `'host'` storage: add the phone's upload host to `Config.Completion.ExtraPhotoHosts`; a shared cloud host in lb-phone's list (amazonaws.com, cloudfront.net, r2.dev, storage.googleapis.com, googleusercontent.com, blob.core.windows.net, digitaloceanspaces.com) counts only when named there too |
| Save to Photos keeps the photo in the app | `'server'` storage needs a public https address (`Config.Completion.PhotoPublicUrl` or `web_baseUrl`) in lb-phone's upload whitelist |
| Alerts are not posted to Discord | Set `crimson_hitman_alert_webhook` with `set` and turn on `Config.Alerts.ToDiscord`; **Logs → Alerts** says which webhook it uses |
| `/ch-settle` says *ending unfinished; it settles itself within a minute* | Nothing to do: the maintenance tick finishes it |
| `/ch-stuck` lists a line that raised while being given | Check the player's inventory or balance, then **Pay**, **Pay amount** or **Delivered** |

The audit log records every money movement and every refused attempt:
`/ch-timeline <contract>` for one contract; the whole log in the panel's
**Logs**, `data/audit-<day>.jsonl` (`json`) or the `crimson_audit` table
(`mysql`).

## Documents

For server owners and staff (shipped with the release):

- [docs/in-game-checklist.md](../docs/in-game-checklist.md): the first hour in game, then every check by area.
- [docs/how-it-works.md](../docs/how-it-works.md): roles, the glossary, a contract start to finish, the money rules, the app's screens.
- [docs/features.md](../docs/features.md): every optional feature, the hitman organisation and mission steps.
- [docs/admin-panel.md](../docs/admin-panel.md): every section of the panel, and Target limits.
- [docs/configuration.md](../docs/configuration.md): every setting with its shipped value.
- [docs/running.md](../docs/running.md): the database, crashes, the console and Discord, moving settings, adding a language, performance.
- [CHANGELOG.md](CHANGELOG.md): what changed in each version.

For developers (in the source repository only): [docs/developer.md](../docs/developer.md)
(architecture, storage, testing, the release build) and `docs/dev/` (the
adapters, the loops, every panel request, the workflow report, the map).
