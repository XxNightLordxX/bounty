# Crimson Hitman System

A criminal contract board for **QBox**, delivered as a custom **lb-phone** app.
Red and black, criminal-only, and built so the money cannot go missing.

Built against this server's actual stack: `qbx_core`, `ox_inventory`,
lb-phone 2.8.0, the 17mov character system, `sc-police`, `sc-ambulance`,
`sc-dispatch` and `sc-blackmarket`.

---

## What's New in 1.1.0

- **Renamed** to `crimson-hitman` (the app: **Crimson-Hitman**), with hitman
  wording everywhere a player or admin reads it.
- **Live transfer only** (`Config.Completion.Fulfilment = 'alive'`, as
  shipped): a contract is completed only by bringing the target alive to the
  person who placed it, who has to be there for the handover, never by a kill,
  and the whole reward is paid on delivery with no separate bonus. `'either'`
  turns kills back on. Each contract keeps the rule it was placed under, and
  `/ch-diag` says which is in use (see *Live transfer only*).
- **Plain words for it:** the board card, the accept dialog, the hitman's
  how-to (on every alive-only card they hold, not only their first), every
  Deliver alive refusal, the Place form, the placer's own card, the phone
  notices and the message thread (its header, each message, its notice and a
  call, all from *The person who placed it*) say who the target is brought
  to — *the person who placed this contract*, never "the client" — and that
  this person has to be
  in the city and within `Config.Kidnap.Radius` metres for the
  `Config.Kidnap.CountdownSeconds` hold, with both figures read from your
  config. Contracts placed under `'either'` keep their old words.
- **Collections:** how many times one contract can be collected
  (`Config.Limits.MaxPayoutSlots`) is your choice of 1, 2 or 3, and ships as 1:
  each contract is collected once, and the Place form shows nothing about
  collecting it again. Anything outside 1 to 3 is read as the nearest of them,
  with a warning at startup; the admin panel takes 1 to 3. Contracts already
  placed keep the number they were placed with.
- **Pictures off:** `Config.Completion.KillPhotos` ships `false`, so the
  resource never takes, uploads, keeps or serves a kill photo and never asks
  Fivemanage or any image host anything; under `'either'`, Verify kill
  completes at the scene on the server's own checks. `Config.Mugshot.Enabled`
  switches target headshots off the same way. Both are in the admin panel's
  Features, live and kept across restarts (see *Turning pictures off*).
- **The kill photo** (with `Config.Completion.KillPhotos = true`) is the
  client's alone and seen once, then saved to the phone's Photos or deleted. On `'server'` storage (the default) it is taken in
  the app's own viewfinder and kept on this server, so no image host is needed;
  Save to Photos uses a link this server serves, lb-phone's own upload, or
  keeps the photo in the app.
- **Kills:** a death the target's game never reports is attributed by the
  server; the photo counts where the body lies now; `MaxWeaponRange` is 425 m;
  a kill made, or a handover armed, before a deadline or a buyout's delay holds
  it off until it finishes.
- **Anonymity:** the Nearby list ships off; a target learns of a contract only
  when their alert's wait is over; an item that names an anonymous client is
  refused; headshots only where `MugShotBase64` runs.
- **Storage:** `mysql` mode starts on MariaDB (`portion` renamed), every table
  is utf8mb4 in one collation and InnoDB, and each start creates or alters only
  what is missing, so a database user without `CREATE`/`ALTER` starts on
  imported tables; `json` keeps records in `records.json` and refuses to start
  on an empty `data/`; no start while another mode still holds players' money.
- **Escrow:** a payout whose `AddItem` or `AddMoney` raises is checked against
  the player's inventory or balance: delivered if all of it arrived, still
  owed if none did. After three raises with nothing arriving, or at once when
  only part arrived or what arrived cannot be read, it waits for staff in
  `/ch-stuck`, and so does a payout the server stopped in the middle of,
  owed to whom that give was going (a hand-back you started included);
  `/ch-stuck` lists them from the escrow itself for as long as they are held.
  A part that arrived is kept on the line, so `/ch-settle <line> pay` gives
  only the rest, and `/ch-settle <line> delivered` settles one that did arrive
  without giving anything, recorded on the line itself. Where the line cannot
  know what arrived (the server stopped part-way through a give),
  `/ch-stuck` says so, and `/ch-settle <line> pay <amount>` gives exactly what
  you found missing. Nothing is given again blind.
- **Admin panel** (`/hitmanadmin`): an overview, contracts with their whole
  history, every escrow line waiting for staff (**Stuck escrow**), the review
  queue, the audit log, a player lookup, and every feature switch and limit,
  changed live and kept across restarts in every storage mode (see *Admin
  panel*). Everything in it is a button: every staff command has one, with
  the command's permission, the same two clicks for anything that moves money
  and the same audit row, and nothing in the panel names a command. The timer
  refresh that had `/hitmanadmin` is `/ch-refresh` now.
- **Staff commands in F8:** a `/ch-*` command run by a player prints its whole
  answer in that player's F8 console, never in chat, with one notice on their
  screen saying so (*Printed to your F8 console*). That includes the page log
  `ch-diag <player>` asks the player's app for, which arrives a moment later:
  it goes to whoever asked (their F8, their open admin panel, or the server
  console that ran it), never only to the server console. Run from the server
  console, a command prints there as before. The players' buyout command
  (`/cleanse`) still answers in chat.
- **Quiet console:** with `Config.Debug = false` (as shipped) a normal start
  and normal play print nothing at all. Only refusing to start, money left for
  staff (the review queue, a stuck escrow line, an ending that raised, a
  maintenance job that moves money failing, and an app request, staff command
  or `/cleanse` that moves money and raised, once every five minutes each, with
  one line when they are up counting any more held back) and a write that
  failed are printed; the settings a start finds wrong are counted
  in one line (*N setting(s) need attention; run ch-diag …*). `ch-diag`, and
  **Run the diagnosis** in the panel, list everything a quiet console left out
  (see *Console output*). `Config.Debug` is in the panel's Features too.
- **Staff:** `/ch-contracts`, a contract **Ref** on every card, in-game ACE
  checks that work (`IsPlayerAceAllowed` answers 1, not `true`), `/ch-diag`
  job timings and a photo-address check.
- **Performance:** the once-a-second death sampler reads only running
  contracts and finds the parties in the city without asking `qbx_core` (one
  lookup for each party who is away). Where no server-side medical resource
  answers a target's death state (`qbx_medical`'s exports are client-only), it
  asks `qbx_core`'s `GetMetadata` for `isdead` and `inlaststand`: two calls per
  target a pass. The client reads `QBX.PlayerData` instead of the
  `GetPlayerData` export; headshots are paced and travel as latent events.
- **Notices** are saved in the phone's notification list through lb-phone's
  server export; threads can be muted; masked calls go through `CreateCall`.
- **Whitelisted-job view** (`Config.WhitelistedView.Enabled`, shipped on):
  police, sheriff, SAST, FIB, EMS, fire, DOJ, lawyers and every other job the
  app bars can install and open it, and see one read-only screen: the
  contracts on them and, for those the law enforcement advisory reaches, the
  contracts on other whitelisted-job members, with no more than the advisory
  carries, and the buyout on a
  contract on them, through the same server path as On me and `/cleanse`. A
  job change moves them in or out of it at once. In the admin panel's
  Features; off is the app closed to them, as before (see *Access*).

---

## Install

1. Drop `crimson-hitman` into your resources folder. Another folder name
   (`crimson-hitman-main` from a zip, say) works too; use that name in the
   `ensure` line.
2. Add `ensure crimson-hitman` to `server.cfg`, **after** `qbx_core`,
   `ox_inventory` and `lb-phone`.
3. Open `config/config.lua` and check the sections marked below.
4. Restart. With `Config.Debug = false`, as shipped, a sound start prints
   nothing; one with settings that will surprise you later prints one line,
   `[crimson-hitman] N setting(s) need attention; run ch-diag …`, and `ch-diag`
   lists each (see *Console output*). With `Config.Debug = true` the console
   prints `[crimson-hitman] started in <mode> mode` and every warning in full.
5. Tell your players where it is. **Crimson-Hitman** is in the phone's App
   Store, not on anybody's home screen: each player downloads it, and
   nothing in the game tells them to — a target alerted that a price is on
   their head included, though their only answer to it (*On me*, the buyout)
   is in the app. Set `Config.App.DefaultInstalled = true` to put it on
   every eligible phone instead (lb-phone then does not let them remove it).
   Barred jobs never see it either way.

The config ships in `json` mode: everything lives in files under
`crimson-hitman/data/` (`store.json`, `records.json`, `contracts/`, the
`audit-<day>.jsonl` log and `photos/`), which is what to back up. In `mysql`
mode the tables are created automatically on first start, as `utf8mb4` so an
emoji in a reason or a non-Latin character name is kept whatever the
database defaults to (a table an older version made is converted at start),
and as InnoDB, which the escrow writes need to be all-or-nothing (a table left
on another engine is moved to InnoDB at start); MariaDB and MySQL 8 both work.
Nothing to import either way. The tables are
`crimson_contracts`, `crimson_escrow`, `crimson_hitmen`, `crimson_amendments`,
`crimson_messages`, `crimson_ledger`, `crimson_pending`, `crimson_stats`,
`crimson_audit`, `crimson_reveals`, `crimson_mutes`, `crimson_photos`,
`crimson_review`, `crimson_settings` (what staff changed from the admin panel)
and `crimson_meta`. Each start in `mysql` mode asks `information_schema` what is
there and creates or alters only what is missing: a table, a column or index a
newer version needs, a table in another character set, or one on another
engine. So a database user without `CREATE`, `ALTER` and `INDEX` starts on
tables that are already complete: import `install/sql/crimson_hitman.sql`
once, as a user that may, before the first start (it holds the same
statements, word for word). If a later version needs something that user
cannot add, the start stops and the console names each thing missing, with
the `ALTER TABLE` statement to run as a user that may; this version adds the
columns `crimson_escrow.deliver_raises`, `deliver_before`, `deliver_arrived`,
`settled_by_staff` and `settled_staff`, and `crimson_contracts.fulfilment_rule`
(how each contract may be completed; NULL on older rows, which read as
`'either'`), `advised_posted_at` and `advised_hitmen` (what the law
enforcement advisory said of each contract, which the whitelisted-job view
shows; NULL where no bulletin went), and the tables `crimson_review` (the
review queue) and `crimson_settings` (the admin panel's settings): import
`install/sql/crimson_hitman.sql`, or create them as a user that may. It also
adds three indexes, which an existing database gets at its next start (about
three seconds per million audit rows, with writes going on) or, for a user
that may not add them, with these as a user that may:
`ALTER TABLE crimson_audit ADD INDEX idx_audit_action (action);`,
`ALTER TABLE crimson_contracts ADD INDEX idx_resolved (resolved_at);` and
`ALTER TABLE crimson_messages ADD INDEX idx_message_contract (contract_id);`.
A start refuses, with nothing changed, where a table of one of these names
is not this resource's (another resource's `crimson_settings`, say: it has
no `setting_key` primary key, which every version of it has had); rename
that table, or give crimson-hitman a database of its own. A busy server
(thousands of contracts a month) is better on `mysql` from the start: see
*Changing storage mode* before switching a server that already has players'
money in one.

Kill photo files are kept in `crimson-hitman/data/photos/` in **every** mode,
`mysql` included.

### Updating

Keep `crimson-hitman/data/` when you put a new version in place, in every
mode. The usual habit — delete the old folder, extract the new one — deletes
it:

- in `json` mode it **is** the store: every open contract, the money held for
  it, the payouts owed to players who were offline, the ledger;
- in every mode `data/photos/` (and `data/photos/kept/`) holds the kill photos
  kept for clients in the app and the files behind the links already saved to
  players' Photos. Lose them and those photos are gone and those links dead.

So either copy the new files over the old folder, or move `data/` out first
and back in after. `config/config.lua` is yours too; carry it across. In
`json` mode the server remembers, outside the resource folder, that the store
has run, and refuses to start on an empty `data/` rather than start empty
without a word; put the old `data/` back and start it again. To start empty on
purpose, run `set crimson_hitman_new_store 1` in the server console and
start the resource, then leave it unset.

Payouts an earlier version left owed (to a player who was away, or whose
pockets were full) still name whom they were being given to, which is what a
payout the server stopped in the middle of looks like, and the two cannot be
told apart. So the first start after updating leaves each of them for you in
`/ch-stuck` instead of giving it at the player's next login: check their
inventory or balance, then `/ch-settle <line> pay`, or `delivered` if it is
already there. Payouts owed from then on are given at login as before.

Restarting `lb-phone` is safe: the app comes back on every phone by itself,
and whether it can place calls and hide a caller's number is asked again, so
an edit to its config takes effect on the restart.
Restarting `qbx_core`, `ox_inventory` or `oxmysql` stops this resource with
them (FiveM stops everything that depends on a resource it restarts and does
not start it again), so follow it with `ensure crimson-hitman`. A player still
connected through a restart of this resource gets anything queued for them
(goods that did not fit, a refund to full pockets) once they make room, as
after a login.

### Changing storage mode

Modes do not share data: a server switched from `json` to `mysql` (or tried
on `memory`) starts with nothing in the new one. So the resource refuses to
start while the mode it left still holds players' money — escrow not yet
settled, or payouts owed to somebody offline — and the console says where and
how much: up to ten contracts, each with its state, what its unsettled lines
hold by source (`50000 bank, 2000 cash`), whom anything is owed to by role
(the client, the target, an operative, never a name) and what clears it:

- **running**: let it finish; the client can cancel it in the app while
  nobody has taken it, or staff can void it (`/ch-void`);
- **owed to a player who is away**: handed over at their next login;
- **left for staff**: `/ch-stuck` lists it and `/ch-settle` settles it;
- **finished with money not yet handed back**: the next start in the old
  mode hands it back.

Switch back, clear them, then switch. In `json` mode a contract file the
index names and cannot be read is named as one that may hold money (nobody
can tell that it does not, and the old mode says so at every start until it
is restored): restore it from a backup first. A queued payout whose money was
already handed over (its entry waits for that player's next login) is not
money owed, and neither stops the switch nor keeps the contract from being
pruned. A store holding only finished history is no reason to refuse;
it is left where it is. `Config.Database.AllowModeSwitch = true` starts
anyway, for money already settled by hand. Kill photo files kept for the old
mode are left alone in the new one (the start-up sweep of unnamed photo
files is off until you switch back or delete `data/photos/.mode`).

### After a server crash

Balances this resource moves are written to the database as they move
(qbx_core's `Save`), so a hard crash no longer rolls cash and bank back by up
to five minutes behind an escrow that was already written. Items, weapons
and dirty money belong to
`ox_inventory`, which saves every five minutes and at a clean shutdown, with
no way to ask it to save one player. After a crash (not a restart), compare
the `escrow_taken`, `escrow_released`, `stake_taken` and `pending_delivered`
rows of the last five minutes in the audit log (`data/audit-<day>.jsonl` in
`json` mode, the `crimson_audit` table in `mysql`, or `/ch-timeline` for one
contract) against what those players are carrying. In `json` mode a file
the crash cut off part-way through writing is put back from its last whole
copy at the next start, and the console names it (see `data/README.md`); a
new contract whose file was written before the index naming it is taken back
in, and a heartbeat file the crash left empty is replaced by the newest audit
row or the index's own time, so the downtime is still not charged to any
deadline.

### Configuration worth reading before you start

| Setting | Why it matters |
|---|---|
| `Config.Completion.Fulfilment` | How a contract is completed. `'alive'` (as shipped) is live transfer only, because this city wants roleplay before anybody is killed: the target has to be brought alive to the person who placed the contract, who has to be in the city and within `Config.Kidnap.Radius` for the handover (the app says so to both sides, with your figures); a kill never completes a contract, the whole reward is paid on delivery, and there is no kidnapping bonus. `'either'` lets a kill complete one too, and pays the bonus on top of a live handover. Each contract keeps the rule it was placed under, so a change reaches new contracts only. Anything else is read as `'alive'`, with a warning at startup. See *Live transfer only* below; `/ch-diag` says which is in use |
| `Config.Completion.KillPhotos` | Whether kill photos exist at all (`false`, as shipped). Off, the resource never takes, uploads, downloads, keeps or serves one and never asks lb-phone or any image host about one; under `'either'`, Verify kill completes at the scene on the server's own checks, with no camera. `PhotoStorage`, the other `Photo*` settings, `ExtraPhotoHosts` and `Config.Ledger.StorePhotos` then do not apply, and the admin panel says so beside them. Anything but `true` or `false` is read as `false`, with a warning at startup. See *Turning pictures off* below; `/ch-diag` prints `Kill photos: off` |
| `Config.Completion.PhotoStorage` | Where kill photos are kept. `'server'` (as shipped) needs no image host: the hitman takes the photo in the app's own viewfinder and it is kept as a file in `crimson-hitman/data/photos/`, which the server must be able to write to. `'host'` uses lb-phone's own camera and the image host it uploads to, keeping only the link. Either way only the client who placed the contract sees the photo, once (see *The kill photo* below). `/ch-diag` says which is in use |
| `Config.Completion.PhotoMaxSide` / `PhotoMaxBytes` | `'server'` storage only: the app shrinks each kill photo until its longest side is at most this many pixels (1280) and it weighs at most this many bytes (600000; at most 1500000), and the server refuses anything bigger. FXServer moves a photo at about 150 KB a second, so the default takes about four seconds each way. The server also decodes each photo when it arrives and encodes it again when the client opens it, on its main thread and roughly in proportion to its size: about 80 ms each at the default and a fifth of a second at 1500000, each a single hitch (estimates; measure yours with the in-game checklist) |
| `Config.Completion.PhotoPublicUrl` | `'server'` storage only: the public **https** address this server serves photos from when a client saves one to their phone's Photos, such as `'https://photos.example.com/crimson-hitman'`. Unset (as shipped), the server's `web_baseUrl` is used. Add its host name to lb-phone's `Config.UploadWhitelistedHostnames`. See *No image host?* below; `/ch-diag` says which address is used and whether lb-phone takes it |
| `Config.Completion.KeptPhotoDays` | How many days a photo kept for its client in the app (because their phone could not save it) lasts. Unset (as shipped), it stays until they delete it. `/ch-diag` says how many are kept and how much disk they take |
| `Config.Completion.ExtraPhotoHosts` | `'host'` storage only. Kill photos are accepted only from image hosts lb-phone itself allows uploads from, plus these. Ships with Fivemanage (`fivemanage.com`, `fmfile.com`), lb-phone's default uploader. If `/ch-diag` shows `photo hosts: 0`, or kill photos are refused with "not on this server's allow list", add your phone's upload host here (a bare domain, no `https://`). lb-phone's camera upload must work first |
| `Config.Database.Mode` | `json` (as shipped; no database at all), `mysql` (oxmysql), `memory` (testing only — nothing survives a restart). Modes do not share data: see *Changing storage mode* |
| `Config.App.DefaultInstalled` | Whether the app is on every eligible player's home screen (`true`) or left in the phone's App Store for each player to download (`false`, as shipped). Players are not told it exists either way; see *Install* |
| `Config.BlockedJobTypes` / `BlockedJobNames` | Who the app is barred to: the whitelisted jobs. Blocks by job **type** as well as name, so a new LEO job is blocked without a config edit. With the whitelisted-job view on they see its one screen and nothing else (see *Access*) |
| `Config.WhitelistedView.Enabled` | The whitelisted-job view (`true`, as shipped): players on a job the app bars open it to one read-only screen, the contracts on them and (for those the advisory reaches) on other whitelisted-job members, and the buyout on their own. `false` closes the app to them as before, and `Config.HideAppFromBlockedJobs` then decides whether they see the icon. Anything but `true` or `false` is read as `false`, with a warning at startup. In the admin panel's Features, kept across restarts |
| `Config.HideAppFromBlockedJobs` | Whether a barred player's phone shows the app at all (`true`, as shipped: hidden). Applies only while the whitelisted-job view is off; with it on they have the app, showing that one screen, and the admin panel marks this as not applying |
| `Config.Advisory` | Who gets the threat advisory when a contract is placed on an officer, and whether it also raises an `sc-dispatch` entry. `TriggerJobNames` ships with every name in `Config.BlockedJobNames`, so a barred job whose type `qbx_core` leaves out still counts; a barred job in neither trigger list is warned about at startup |
| `Config.Limits` | Contract caps, payouts, cooldowns |
| `Config.Limits.MaxPayoutSlots` | How many times one contract can be collected: `1` (as shipped; each contract is collected once), `2` or `3`. At 1 the Place form shows no extra-collection controls at all; at 2 or 3 the creator chooses how many, each funded and escrowed up front. Anything outside 1 to 3, or not a whole number, is read as the nearest of them with a warning at startup; the admin panel takes 1 to 3. Contracts already placed keep the number they were placed with, and can still give their last collection back |
| `Config.Limits.MinContractReward` | The least a new contract's reward may be worth in money (1000 as shipped; `0` turns it off): cash, bank and dirty money summed across every payout, the kidnapping bonus included. Items and weapons do not count, since nothing prices them. A contract worth less is refused (`reward_too_small`) and the app says the figure, on the Place form before anything is typed and in the refusal; a reward cannot be taken back out below it either, by Withdraw part or by giving back a payout. Without it two one-dollar contracts fill a target's `Config.Limits.MaxActiveContractsPerTarget` and nobody else can list them until both close. Anything that is not a whole number of dollars is read as 1000, and one above `Config.MaxContractValue` is held to it, with a warning at startup |
| `Config.Immunity` | Playtime and session floors that protect new players from being farmed |
| `Config.Targeting.AllowBrowseAll` / `AllowNearby` | How a client finds a target. Browsing everyone online is on (a roster of names, no positions). The nearby list is **off**: on, it puts names to the unmasked people around a player, through walls, and boot warns while it is (see *Placing a contract*) |
| `Config.Notifications.ParanoidAlertJitter` | How long (1 to 10 minutes, drawn per contract) a new contract is kept from its target: their alert, their On me tab, `/cleanse` and the request for their headshot all wait for it, so none of them dates the placement |
| `Config.Mugshot.Enabled` | Target headshots on the board (`true`, as shipped). Off, no headshot is ever asked of a target's game, one a client sends anyway is refused before it is read, none is kept, and every card shows the usual placeholder. Anything but `true` or `false` is read as `false`, with a warning at startup |
| `Config.Mugshot.RemoveBackground` | Whether target headshots have their background cut out (`false`, as shipped). On, `MugShotBase64` loads a 2.6 MB model into the target's game for every render and never frees it, set off by other players viewing a board that names them; off, the headshot keeps the game's grey backdrop |
| `Config.Diagnostics.SlowJobMs` | A maintenance job (the tick's, or the death sampler's pass) slower than this many milliseconds (5) prints one console warning naming it, with `Config.Debug` on, at most every five minutes per job; `0` turns it off. `/ch-diag` lists the slowest jobs either way |
| `Config.Debug` | Debug output in the server console (`false`, as shipped): the console stays quiet, printing only refusing to start, money left for staff and a write that failed, and one line counting the settings that need attention; players' F8 consoles show nothing but a staff command's answer. `true` prints everything, each setting problem in full. `/ch-diag` lists all of it either way. In the admin panel's Features as *Debug output in the server console*, kept across restarts (see *Console output*) |

### Dirty money

`sc-blackmarket` prices dirty money at `0.85`, which makes it worth about
**18% more** than clean money there. Paying a contract out as dirty money at
face value would turn every contract into a risk-free laundering rail, so:

- Escrow pays out in **exactly the sources it holds**. Cash in, cash out;
  dirty money in, dirty money out.
- There is no conversion option. A client who wants the hit paid in blood
  money funds it with dirty money, and the hitman is paid in dirty money.

---

## How it plays

**Live transfer only.** This server ships with
`Config.Completion.Fulfilment = 'alive'`, because the city wants roleplay
before anybody is killed. A contract is completed only by a live handover:
the hitman cuffs the target or gets them into the hitman's own vehicle,
brings them **alive** to **the person who placed the contract**, and holds
them there for the handover countdown. That person has to be in the city and
there for the handover: within `Config.Kidnap.Radius` (12 m) of the hitman and
the target for `Config.Kidnap.CountdownSeconds` (30 seconds). Killing the
target never completes it: they die and respawn as normal, the contract stays
open, and there is no **Verify kill**. Nor is a body handed over: the target
must be alive and conscious for the whole countdown, and a dead one is
refused, whatever `Config.Kidnap.RequireConscious` and
`Config.Kidnap.RejectDead` say (those loosen only contracts placed under
`'either'`). The whole reward is paid on delivery, so there is no separate
kidnapping bonus, and the kill photo settings are not used.

The app says this to both sides, in these words, with the distance and the
seconds read from your `Config.Kidnap` (never written into the page), and
none of these lines calls that person "the client":

- **Board card**, under the reward: *Bring the target alive to the person who
  placed this contract.* Every card of such a contract is also marked
  **Alive only**.
- **Accept dialog**: *This contract only pays when you bring the target,
  alive, to the person who placed it. Killing them does not count.*
- **The hitman's card** offers **Deliver alive** alone, and until they have
  finished one it says how: *Bring them in alive: cuff them or get them into
  your vehicle, take them to the person who placed this contract, get within
  12 m of that person, tap Deliver alive and hold for 30 seconds. Killing them
  does not count — they respawn and the contract stays open.* For an
  anonymous placer it adds *The person who placed it is anonymous — use
  Message to agree where to meet*; a named one is named.
- **A kill refused** (`kill_not_allowed`), and a handover refused because the
  target is down or dead, say what to do instead.
- **Deliver alive refused** because the person who placed it is missing
  (`party_offline`, `creator_too_far`), the countdown slipping for that
  reason, and a handover that failed for it, say plainly that *the person who
  placed this contract must be online and within 12 m of you and the
  target*. An anonymous placer who is away gets the same words as one who is
  only far off, so neither can be told from the other.
- **The Place form**, instead of a bonus: *Contracts here only pay when the
  target is brought to you alive. You need to be in the city to meet the
  hitman for the handover.*
- **The placer's own card under Mine**, once a hitman has it, and the phone
  notice that it was taken: *A hitman took your contract. They'll bring the
  target to you alive — stay in the city and watch your messages.* When a
  handover starts they are told to stay within 12 m of them both for the 30
  seconds.

Set it to `'either'` to turn kills back on: then a kill, verified with
**Verify kill**, or a live handover completes a contract, and a handover pays
the kidnapping bonus on top. Contracts placed under `'either'` keep the words
they always had. Each
contract keeps the rule it was placed under, so changing the setting changes
new contracts only; a contract stored before this setting existed keeps the
terms it was taken on, `'either'`. `/ch-diag` says
which rule is in use and how many live contracts still run under the other.
What follows about kills, the kill photo and the bonus applies only to
contracts placed under `'either'`.

**Placing a contract.** Search for a target, give a reason, choose exclusive
or competitive, and build the reward from any mix of cash, bank, dirty money,
items and weapons. The target is picked by name or from everyone online
(`Config.Targeting.AllowBrowseAll`). A list of the people around you
(`AllowNearby`) ships off, because the server knows where everyone is
whatever the walls or the mask: on, it named the anonymous hitman to the
target he was closing on, and the anonymous client to the hitman at a
handover. Turned on, it leaves out anyone masked, invisible or in another
routing bucket (the server cannot see clothes, so each player's own game says
when their mask goes on or comes off, and anyone whose game has not said yet
is left off as masked), gives distance only as "under 10m", "under 20m" and so on,
and is closed to a player while they are on a live contract and for half an
hour after one ends (`NearbyClosedAfterSeconds`; a handover ends with all
three standing together); a friend on no contract can still read the names
around a target. Cash goes up as cash:
the `money` item (and anything else in the `inventory:accounts` convar) is
not offered as goods. On an anonymous contract an item that names you in its
metadata (an ID, a phone with its number, a key with its owner) is refused,
since the hitman would be handed it as it is. Set how many payouts it has (how many times it can be
collected) — each payout is funded separately and all of it is escrowed up
front. Under `'either'`, optionally set a kidnapping bonus (a percentage on
top, plus any items or weapons marked to pay only if the target is delivered
alive); under `'alive'` there is none, since the whole reward pays for the
delivery: a percentage sent anyway is placed as 0, and money or goods set
apart as a bonus are refused (`no_bonus`). Set a
buyout price, and a stake the hitman puts up when they accept. The form shows what
it will take from you before you place it, and the contract runs for
`Config.Limits.DefaultDeadlineSeconds` (3 hours as shipped) unless you extend
it from Mine.

**Changing what it pays.** While nobody is working it, the client can add to
the reward or take part of it back — tick the lines to return and they come
home as the same property, the same weapon with the same serial. A payout's
base reward cannot be emptied, because a payout that pays nothing is not a
contract. The moment somebody accepts, the client can only add to it on their
own: the hitman took it as written, and escrow exists so it cannot be pulled
out from under them. Adding — money, items, weapons, a bigger kidnapping
bonus (under `'either'` only), a longer deadline — and lowering or removing the stake apply at once,
from Change reward and Extend deadline. Anything else — a shorter deadline,
giving back the last payout, a new reason, switching between one hitman and
several, raising the stake (only while nobody holds it), cancelling — is
proposed in the app and happens only if the other side agrees; a proposal
nobody answers lapses after `Config.Amendments.ProposalExpirySeconds`.

**Taking one.** Accept from the board, anonymously if you like. More hitmen
may accept than there are payouts; the first to fulfil are paid. If the
contract carries a stake, you put it up when you accept — walk away and the
person who placed it keeps it. The accept dialog says how long is left, and a staked
contract with less than `Config.Penalty.MinWindowMinutes` to go cannot be
taken; if the stake or the deadline changed while you were looking at it, the
acceptance is refused and the board refreshes rather than taking a stake on
terms you were not shown. You can take it up again later, staking again; the wait
between payouts on one contract (`Config.Limits.SlotCooldownSeconds`) carries
over, so walking away is not a way round it. Where the server charges for
hitman anonymity and you cannot cover it, the acceptance is refused rather
than made under your name. A refusal for money says which charge you were
short for (the stake, taken whole from your bank or whole from your cash, or
the fee), how much and from where. An exclusive contract you hold without going near
the target for `Config.Limits.ExclusiveIdleReleaseSeconds` (counted only while
the client and the target are both in the city) goes back on the board with
your stake returned, and is not yours to take again. So does one you hold
near the target without ever making an attempt on them — no hit landed, no
handover armed — for `Config.Limits.ExclusiveAttemptWindowSeconds`. The
accept dialog names both windows, and so does your card under Mine while you
hold it. The deadline pauses the same way. Both follow the target alone when the client is anonymous, because
a clock that stops while they are away tells everyone watching it when they
logged off. A target serving a prison sentence counts as away too, so the
deadline stops for the sentence and moves on by the time served, and an
exclusive hold is not released for idleness meanwhile
(`Config.Limits.PauseWhileTargetJailed`). "In prison" means an `injail`
sentence, as `sc-police` writes it, and standing inside
`Config.Limits.JailZone` (Bolingbroke by default): `sc-police` lets a client
write its own sentence, so the metadata alone is not trusted.

**Finishing it.** On a contract placed under `'alive'`, as this server ships,
there is one way: take the target alive to the person who placed the contract
and hold them there for the handover, as described at the end of this
paragraph, for the whole reward. A kill does nothing for it, however it happens; **Verify kill** is
not offered, and the server refuses one with `kill_not_allowed`. On a
contract placed under `'either'`, kill the target, tap **Verify kill** and
(with `Config.Completion.KillPhotos` on) photograph the body for the
baseline; with kill photos off, as shipped, the tap itself is the
verification and there is no camera (see *Turning pictures off*). Either way
you stand within `Config.Completion.PhotoRadius` (5 m)
of where it lay when they died, or of where it lies now if it has moved
since (a car rolling on, a body carried off) while they are still dead. On `'server'` storage the app opens its own
viewfinder over the screen, showing the phone's rear camera: point it at the
body and tap **Take photo** (or **Cancel**). On `'host'` storage lb-phone's
own camera opens instead. With `sc-ambulance`, downing them is not the kill:
they are in last stand, and you have to finish them. The kill is credited to
whoever landed a hit within `Config.Completion.DeathReportWindowMs` (30
seconds) of the death, and bleeding out takes minutes, so a target left to
bleed out pays nobody. Only gunfire and melee the server sees land on the
target count, from up to `Config.Completion.MaxWeaponRange` (425 m, OneSync's
player culling radius) away: explosives (grenades, sticky bombs, rockets),
fire, run-overs and falls pay nobody (`Config.Completion.RequireObservedDamage`),
and Verify kill tells a hitman whose kill the target's own game put down to
them that this is why. The target's game reports its death; if that report
never comes (the game crashed or quit, or never sends it), the server
attributes the death itself a few seconds later, the same way. For `Config.Completion.ProofWindowSeconds` (60
seconds) after the death, the photograph counts whatever has happened to them
since, whether a respawn, a revive or a defibrillator, so none of these can
take a kill away from a hitman standing over the body. After that, a revive
cancels the kill once they have stayed up for a few seconds or somebody has
put them down again, and a kill made while a revive's protection lasts does
not pay. A defibrillator that only brings them back to last stand does not
cancel it, even if they are hit while it takes effect. Once that minute has
passed, though, the photograph needs them dead: the app says they are still
down, and finishing them is a new kill with its own photograph. A hit counts once the
server sees the damage it did, which reaches it a moment after the shot, and
only on the target's own body: a round into their car is not a hit on them.
Where the target's game says who damaged them, that is who the damage goes to.
The defibrillator is heard from sc-ambulance's own event, from an on-duty
medic of `Config.Completion.MedicJobs` holding `DefibItem` within `DefibRange`
of the patient. Match them to sc-ambulance's `Config.Defib`: `MedicJobs = false`
when it does not require EMS, `MedicJobs = {}` when its defibrillator is off.
A kill waits for its photograph for at most two photo-token lifetimes, however
many tokens are asked for. A kill made before the deadline whose photograph
is still on its way, or a handover armed before it and still counting down,
holds off the expiry until it finishes, for that long at most; a kill made
after the deadline does not, and a handover cannot be started once the
deadline has passed. A buyout's delay is held off the same way, only for a
kill made or a handover armed before the delay ran out. Or take them alive to the person who placed the
contract and hold them there, all three of you within `Config.Kidnap.Radius` (12 m) of each other,
for thirty seconds (`Config.Kidnap.CountdownSeconds`), for baseline plus bonus
under `'either'` and the whole reward under `'alive'`: restrained or in your vehicle,
neither dead nor down, and not under `Config.Kidnap.MinTargetHealthPercent`
(20%) health. A target hurt worse than that (Qbox gives no health back on its
own) has to be patched up first, and the app says so.

**The kill photo.** The photo is the client's alone, and they get to see it
once. Nothing of it stays on the hitman's phone: on `'server'` storage the
photo never touches lb-phone's gallery or image host and the app lets go of
it the moment it is sent; on `'host'` storage the camera never saves it to
their gallery and their page is never sent the link. Either way their Ledger
row has no photo. The client is told it is waiting under Ledger. Their row
there has a **View photo** button, and tapping it opens the photo full-screen
with **Save to Photos** and **Delete**. Save to Photos puts it in the phone's
own Photos app (how, on `'server'` storage, is under *No image host?* below);
**Delete** deletes it. Until one of the two is tapped the tab bar stays put
("Save or delete the photo first"), so a mis-tap there cannot throw the photo
away; anything else that closes it deletes it. Afterwards the row says which
happened. Reading the Ledger does not count as a view; only tapping the
button does.

Where the phone cannot take the photo, it is not lost: the button reads
**Save** and keeps it for the client in this app instead ("Your phone can't
take it, so it is kept for you in this app"). The same happens if the phone
refuses it when asked: the dialog then offers **Keep it in the app instead**.
A kept photo stays on the client's Ledger row with **View photo**, opens as
often as they like, and is deleted when they tap **Delete** there, or after
`Config.Completion.KeptPhotoDays` if that is set. It outlives its row: once
the row has been pushed off the Ledger, the photo is listed on its own under
**Photos kept in this app**. On `'host'` storage a kept photo is its link; on
`'server'` storage its file moves to `data/photos/kept/`.

A photo still waiting, or open, is also deleted if:

- it is left open for `Config.Completion.PhotoOpenSeconds` (10 minutes), as
  when the phone is closed while it is open;
- it is never opened within `Config.Ledger.PhotoRetentionDays` (7 days);
- its row is pushed off the client's ledger (`Config.Ledger.Depth`);
- staff void the contract with `/ch-void` (which deletes a kept one too).

With `Config.Ledger.StorePhotos = false` no photo is kept at all. On
`'server'` storage every one of these deletes the photo's file from
`data/photos/`, and each start removes any file there (or in `kept/`) that no
photo still names (left by a crash, say; this needs a server build with
`io.readdir`). On `'host'` storage (`Config.Completion.PhotoStorage`),
deleting a photo only makes the app forget its link. The file stays on the
image host (Fivemanage, say), because lb-phone gives a resource no way to
delete it.

**No image host? Use `PhotoStorage = 'server'`** (the shipped setting). The
photo is taken in the app with lb-phone's own game camera, sent to this
server over a latent event, checked (a webp, jpeg or png of at most
`PhotoMaxBytes`, and really what it says it is) and kept as a file in
`crimson-hitman/data/photos/`. When the client opens it, it is sent to their
phone alone. Nothing about it depends on Fivemanage or any other upload
service, and the host allowlist is not used.

lb-phone's Photos app keeps a link to each photo, never the picture, so
**Save to Photos** needs a link. In order:

1. **This server serves it.** With a public **https** address, the server
   gives the photo a new name nobody can guess (128 bits from the server's
   own cryptographic random source) and serves it read-only at
   `https://<address>/p/<name>.webp`; the client's Photos keeps that link.
   The app loads the link first, as the Photos app will, and saves it only
   if it loads within a few seconds: a link that leads nowhere is the phone
   saying no (keep it in the app instead), not a broken picture in Photos.
   The file stays for as long as their Photos does: deleting it there
   (`lb-phone:deletedFromGallery`), or factory resetting the phone it was
   saved from (`lb-phone:factoryReset`), deletes it here too. The address is
   `Config.Completion.PhotoPublicUrl`, or else `https://<web_baseUrl>/crimson-hitman`.
   Cfx.re's own `*.users.cfx.re` addresses stopped working on 30 June 2026;
   Qbox's free **Nucleus** replacement gives you one (`set web_baseUrl
   "<name>.server.qbox.re"` in `server.cfg`), or put your own https proxy in
   front of the server and set `PhotoPublicUrl` to it. **Add the host name to
   lb-phone's `Config.UploadWhitelistedHostnames`** (for Nucleus,
   `"<name>.server.qbox.re"`, or `"*.server.qbox.re"`), or the phone may
   refuse to save it.
2. **lb-phone uploads it.** With no address, the app hands the photo to
   lb-phone's own upload (whatever `Config.UploadMethod` the phone uses),
   saves that link, and the server deletes its copy at once.
3. **Kept in the app.** With neither, the photo is kept for the client in
   this app, as above. The page cannot tell lb-phone's upload will fail
   before it tries, so on a phone that has an upload at all the button still
   reads **Save to Photos**; when the upload fails, the dialog offers **Keep
   it in the app instead**. **Save** appears only on a phone build that gives
   the app no upload or gallery save, or while kill photos are off (see
   *Turning pictures off*).

`/ch-diag` says which: the address it serves photos from (or why there is
none), whether lb-phone's `UploadWhitelistedHostnames` / `Domains` take it,
and how many photos are on disk, kept in the app and served to phones, and
how much space they take. A moment after the report it says whether the
address actually reaches this resource: it asks the address for a photo
nobody has and expects this resource's own "Not found." (every answer the
photo handler gives carries an `X-Crimson-Hitman` header). Anything else
answering — an address without `/crimson-hitman`, a proxy that does not pass
it on — is named; no answer at all is a warning, since some networks cannot
reach their own public address from inside while phones can.

**Turning pictures off.** `Config.Completion.KillPhotos = false` (as shipped)
turns kill photos off completely. The resource then never takes, uploads,
downloads, keeps or serves one, and never talks to Fivemanage or any other
image host for one:

- the hitman's Verify kill (offered only under `'either'`) opens no camera
  and no viewfinder: the server checks the scene itself, on the same rules a
  photo is held to (`PhotoRadius`, `ProofWindowSeconds`,
  `RequireObservedDamage`, `RejectLastStand`, a revive undoing the kill), and
  pays the collection there and then;
- every photo upload, latent photo event and photo request is refused before
  anything sent with it is read, with the same answer as a photo nobody has;
  no file is written and `data/photos/` is not touched;
- nothing asks lb-phone for its upload hosts, and the start says nothing about
  `ExtraPhotoHosts`, `PhotoPublicUrl` or `web_baseUrl`;
- the photo link route answers `404` to every request, so a photo saved to a
  phone's Photos by link stops loading;
- the Ledger, the notices and the client's cards say nothing about a photo;
- `/ch-diag` prints `Kill photos: off`, and the admin panel marks
  `Config.Completion.PhotoStorage` and `Config.Ledger.StorePhotos` as not
  applying.

A photo kept before they were turned off keeps its normal expiry, and its
client can still open it once, to keep it in the app or delete it: **Save to
Photos** is not offered, by link or by lb-phone's own upload, since nothing is
served, uploaded or handed to the phone's Photos while photos are off, and the
dialog says *Kill photos are off on this server, so it can only be kept for you
in this app.* The start-up sweep of photo files and the retention run only
while such a photo is kept.

`Config.Mugshot.Enabled = false` turns target headshots off the same way: no
render is ever asked of a target's game, a headshot a client sends anyway is
refused before it is read, nothing is kept (those already kept are forgotten
the moment it is switched off), and every card shows the usual placeholder.

Both switches are under **Features** in the admin panel (`/hitmanadmin`),
take effect at the next action that reads them, with no restart, and are
kept across restarts like every other setting there.

**Notifications.** Every notice the resource sends (an acceptance, the
photo waiting under Ledger, a target's alert, a stake forfeited, the advisory
to officers) is saved in the phone's notification list through lb-phone's
server export, by the number of the phone the player has equipped, so it is
still there after the popup has gone. A notice kept for a player's next login
waits up to two minutes for their phone to load, so it is there once they
have spawned. Where lb-phone cannot take it, the player's game raises
lb-phone's popup instead, which is not saved.

**Counter-play.** A target can see the price on their head and buy it out.
A new contract shows on their On me tab (and in `/cleanse`) when their
alert arrives, one to ten minutes after it was placed
(`Config.Notifications.ParanoidAlertJitter`), not the second it was placed;
after a restart, at once. One withdrawn inside that wait is never announced
to them. An officer sees it as soon as a threat advisory about it goes out.
With a hitman on the contract, the buyout waits
`Config.Bailout.ProcessingDelaySeconds` (2 minutes) so they can finish first,
and longer for a kill made, or a handover armed, before those two minutes
ran out and still waiting for its photograph or counting down (up to two
photo-token lifetimes more). If they finish, the premium goes back to the
target.
Players on a whitelisted job — law enforcement, EMS and the rest — have the
same button on the whitelisted-job view (see *Access*), and anyone can use
`/cleanse` (lists what is on them) and `/cleanse <id>` (buys one out); all
three go through the same server path. Either
side can pay an informant to unmask one hitman. Creator and hitmen can
message or call each other through the app without either learning who the
other is (`Config.Relay`; switching it off removes messaging and calls
entirely). A call to an anonymous party asks them to call back rather than
ringing them, since a phone that rings only when its owner is in the city
would say whether they are. Calls go through lb-phone's `CreateCall` export
with the caller's alias shown, and are hung up from the thread. On a phone
build without it the Call button is not drawn, and when both sides are
anonymous neither can ring the other: they use messages. Either side can
Mute a thread from its header: their phone stops ringing for its messages,
which still arrive and show in the thread, while contract updates still
ring. The mute is theirs alone, is kept across restarts, and the other side
cannot tell.

**Access.** The app is criminal-only. Every job in `Config.BlockedJobTypes`
or `Config.BlockedJobNames` is barred from it (police, sheriff, SAST, FIB,
EMS, fire, DOJ, lawyers and so on): by the job they are working, or by any
other job they hold through `qbx_core` multi-job or `sc-multijob`, and off
duty too while `Config.BlockOffDuty` is on. The server decides this on every
request; nothing a client says changes it.

With `Config.WhitelistedView.Enabled = true` (as shipped) a barred player
can still install and open the app, and sees **one read-only screen**:
*You're on a whitelisted job, so this app only shows contracts on you and on
other whitelisted-job members.*

- **Contracts on you**: every live contract whose target is them.
- **Contracts on whitelisted jobs**: every live contract whose target was
  law enforcement to the advisory when it was placed: the flag the listing
  carries and the job the advisory names, both recorded on the contract.
  Never by a lookup of the target now, so an entry does not come and go as
  they log in and out, or change job. Only for a viewer the advisory reaches
  (`Config.Advisory.RecipientJobTypes` / `RecipientJobNames`, by the job they
  are working: law enforcement, as shipped, not EMS, fire, DOJ or lawyers),
  and only while advisories go out (`Config.Advisory.Enabled`). Anybody else
  has no such section, and the screen says *this app only shows contracts on
  you.*

Each entry carries no more than the law enforcement advisory already said
about it. What each bulletin says is kept on the contract as it goes out, and
the entry is read from that, never from how the advisory is set now: a
contract placed or taken while advisories (or that stage of them) were off is
not listed as posted or taken when they are turned back on, and one no
bulletin was sent for is not listed at all. The target's name and job; when it
was posted (to the five minutes), where a posting bulletin went out and while
`OnCreate` ones still do; and open or taken by how many hitmen, while
`OnAccept` ones go out: taken by the count the latest acceptance bulletin
carried (each operative who takes it up is one bulletin, and one walking away
is not announced, so the count does not drop for it), or open where a posting
bulletin went and no acceptance one has since. And, beside when it was posted
and only there, when it runs out at the latest (*Runs out within 47h*). With
only acceptance bulletins going out, a contract is listed once one has, with
neither. When it runs out is the contract's lifetime
(`Config.Limits.ContractLifetimeSeconds`, counted from the end of the five
minutes it was placed in, so it dates the placement no more finely than when
it was posted does, and is left out with it, since the two give each other
back), which no one's presence moves: the hitmen's deadline stops while a
named placer is offline and jumps on when they come back, so a countdown read
from it would tell every officer when the placer reconnected. Never who
placed it (named or anonymous), any hitman, the
reason, a location, a photo or headshot, or the reward. A contract on anybody else is never shown or counted. Like On me, a
new contract appears once its target may be shown it (their alert's wait, or
at once where a bulletin has already gone out). With nothing to show it says
*No contracts on you or other whitelisted-job members.*

On a contract on them, and only there, they get the **buyout** a civilian
target has in On me, priced and confirmed (two taps) the same way, with the
same pending line and countdown once paid: it is the same request to the
same server path as On me's button and `/cleanse`, so every buyout rule
applies unchanged (`Config.Bailout.Enabled`, the premium's limits, the
processing delay while a hitman is engaged, no buyout from the floor, the
settle attempts and the refund, who it pays, its audit rows and notices).
With buyouts off there is no button. Nothing else in the app answers them:
not the board, Place, Accept, Deliver, Message, the wallet or the ledger,
and every other request is refused as it always was, apart from the page's
own fault report, so a fault on this screen reaches `/ch-diag` and the page
log the diagnosis asks their app for comes back.

A job change (the QBox job update, an `sc-multijob` switch, or the next
maintenance tick if no event comes) moves them at once: somebody who leaves
a whitelisted job gets the whole app back, and a civilian who joins one is
moved to the view, with everything the open page held from the other one
dropped. Contracts they placed or took as a civilian carry on as before.
`Config.WhitelistedView.Enabled = false` is the app closed to every barred
job, as before the view, and `Config.HideAppFromBlockedJobs` then decides
whether they see the icon. Both are in the admin panel's Features.

**Putting a hit on a cop.** Allowed, and loud. Every officer online is advised when the
contract is posted and again on each acceptance, with a running count, on
their phone and in dispatch. Both the creator and the hitman are warned first,
and the listing is flagged. Nobody puts a hit on a cop by accident. The dispatch entry
is closed when the contract ends. An officer is an officer by every job they
hold (`qbx_core` multi-job, `sc-multijob`): switching to a second job for the
evening neither opens the whole app to them (they keep the whitelisted-job
view) nor takes them off the protected list.
With the whitelisted-job view off, a player barred by a job they hold but
are not working is told which one on their phone, since a department boss can
hire somebody through the MDT without asking them; quitting it from their job
menu gives the app back.

---

## What stops it being abused

The full reasoning is in `../docs/hitman-app-spec.md` (in the repository) §14. In short:

- **Money cannot be duplicated.** Every escrow line settles at most once,
  guarded by a compare-and-set. Every release path shares one function. A
  give that raised an error, or that the server stopped in the middle of, is
  never given again blind (below).
- **Money cannot be destroyed.** A payout that cannot be delivered — full
  inventory, player offline — stays owed and is delivered once there is room
  or at their next login, never dropped. A contract the server went down
  while placing (its reward taken, the contract itself never stored) has its
  reward handed back to the client at the next start, once, and nobody else
  is told it existed.
  A reward whose charge fails part-way with an error from `qbx_core` or
  `ox_inventory` is handed back line by line. Where such an error leaves it
  unknown whether one line moved, the audit log names that line for you to
  check (`escrow_take_raised` on a charge, `escrow_deliver_raised` on a
  payout). A payout whose give raises an error (`AddItem`, or `AddMoney`,
  which adds the money before the hooks that can raise) is checked against
  what the player held just before it and holds now (an item by its count, a
  weapon by its serial, money by the balance): one that all arrived is
  delivered and settled, and one where nothing arrived stays owed and is tried
  again. After the third raise on one line with nothing arriving (counted
  until you settle it), or at once when only part arrived or what arrived
  cannot be read, it is tried no more and waits for you in `/ch-stuck`
  (`escrow_deliver_parked`), with what they held before and the part that
  arrived kept on the line; any later give of it hands over only the rest.
  A give the server stopped part-way may have handed over more than the line
  recorded, so for those `/ch-stuck` tells you to check what arrived and
  `/ch-settle <line> pay <amount>` gives exactly the rest you found missing.
  What they hold that cannot be read before the give means nothing is given,
  and it stays owed. A payout the server stopped between naming who it was for
  and recording it as settled waits for you the same way at the next start,
  rather than being given again at their next login: owed to whom that give
  was going, so a `/ch-settle <line> return` stopped after the client's credit
  is owed to the client, never to the hitman it was owed to before. It is
  left for you before it is put back to held, so a start that stops part-way
  leaves nothing to be given again. A held line still naming whom it was
  being given to is left for you the same way (a give that moved nothing no
  longer names anybody), which at the first start after updating includes
  the payouts an earlier version left owed (see *Updating*). A
  buyout premium handed back, an anonymity fee refunded and a charge rolled
  back are decided by the balance the same way: once it has arrived it is
  never owed or offered to anybody a second time. Where only part of it
  arrived, or there is no telling, a handed-back premium is owed on a line
  left for you in `/ch-stuck`, and the rows of the others
  (`anonymity_fee_refund_failed`, `escrow_rollback_failed`,
  `bailout_refund_stranded`) say how much arrived (`arrived`). Each of those,
  and every other money event no rule can settle by itself, is also kept as
  an item in the **review queue** until staff resolve it (`/ch-review`), so
  it is not lost when the log is pruned.
- **Identity is never taken from a payload.** Every handler resolves the
  acting player from the connection. Citizen ids never reach a client;
  searches and threads use expiring per-viewer handles.
- **A kill has to be real.** Death is attributed from damage the server
  observed, corroborated against the medical state. The target's own report
  can name the killer, but never stands in for that damage, and a kill
  still opens without it. A downed player is not a
  kill, and a revive more than `ProofWindowSeconds` (60 s) after the death
  voids a pending claim.
- **A delivery has to be real.** The target must be alive, conscious and
  restrained or in your vehicle, checked on every tick of the countdown.
- **Anonymity is enforced by omission.** An anonymous party's identity is
  never put in the payload, so there is nothing to find client-side. An
  anonymous client's contract stays on the board while they are offline, and
  nothing a hitman can press says whether they are in the city. No list
  names the other side of a contract to a player on it, an item that names
  an anonymous client is not handed to the hitman, and a target learns of a
  new contract only when their alert's wait is over. Headshots are asked for
  and accepted only where `MugShotBase64` runs on the server; the kill photo
  is taken with the rear camera only.
- **New players are protected.** Playtime and session floors, post-respawn
  immunity, per-target contract caps and re-listing cooldowns. Those caps
  cannot be filled for a dollar: a contract has to be worth at least
  `Config.Limits.MinContractReward` in money, and stays so. A login event
  never restarts a session that is already running, so the session floor
  cannot be renewed on demand, and a client's limits and waits count across
  every character on their licence.

---

## Staff commands

Run them in your **F8 console** in game, or use the buttons in the **admin
panel** (`/hitmanadmin`), where every one of them is a button. A command run in
game prints its whole answer in your F8 console, never in chat, in order, with
one notice on your screen (*Printed to your F8 console*) for when you typed it
in chat. Run from the server console, every one prints there, whatever
`Config.Debug` says. The players' buyout command (`Config.Bailout.Command`,
`/cleanse`) is not a staff command: it answers the player in chat, as it always
has.

All work from the server console except `/hitmanadmin`, which opens a page in
game. In game they need the `crimson.admin` ACE
(`add_ace group.admin crimson.admin allow`). `Config.Admin.ExtraAces` also opens
the read-only ones (`ch-diag`, `ch-timeline`, `ch-stuck`, `ch-contracts`) and
the admin panel to read; `ch-void`, `ch-settle`, `ch-review` and `ch-refresh`
always need `crimson.admin` itself, and `ch-whois` `crimson.identity`.

The `<contract>` the commands take is the contract's id. Players see it as the
**Ref** at the foot of each card on their Mine and On Me tabs and on each Ledger
entry, and `/ch-contracts` lists it for any player.

| Command | What it does |
|---|---|
| `/ch-diag [player id]` | Why the app is not showing something: runs the app's own reads as that player and says what each answered (including which medical resource, or QBox metadata, answered for their death state), plus the last faults their phone reported. Also lists the slowest maintenance jobs with their worst, average and last times |
| `/ch-contracts <player id\|citizen id>` | A player's contracts, newest first, closed ones included while they are kept: each id, its state, their role and the target. Lists the ids for `/ch-timeline`, `/ch-void` and `/ch-whois`. Contracts they placed or took anonymously are left out unless you also hold `crimson.identity` |
| `/ch-timeline <contract>` | One contract's state, escrow lines and audit trail. It only reads, so it answers while the server is still recovering from a restart too, and then shows the lines as they stand at that moment, which recovery may still change |
| `/ch-whois <contract>` | Who is really behind an anonymous creator or hitman. Needs `crimson.identity`, a separate ACE |
| `/ch-void <contract> [reason]` | Close a contract and return its escrow to the creator. Any kill photo from it that the creator has not saved to their phone is deleted, including one kept for them in the app. Refused, with *try again in a moment*, while the server is still recovering from a restart; if recovery failed at the start, it says so instead, and that the resource needs a restart once you have fixed the cause the console logged (`BOOT RECOVERY FAILED`). A contract mid-claim is not voided: while a claim is paying one of its collections the command answers *locked*, and goes through once the claim is done. One a claim left mid-claim when it raised, with no claim running (a *stalled claim*), stays so until the next start, and the command says what to do: pay each line `/ch-stuck` lists for it as a *stalled claim* with `/ch-settle <line> pay`, then restart the resource. Recovery puts the contract back to accepted, past the collection that claim owed (or completes it, if that was its last), and `/ch-void` closes it then |
| `/ch-stuck` | Escrow lines left for you: a payout whose give raised an error three times with nothing arriving, or once with only part of it arriving or no telling what did, and one the server stopped in the middle of (including one being handed back from a contract that was never placed). Each is still owed to the player named, given by nothing until you settle it, and listed from the escrow itself for as long as it is held, with how much of it arrived and, while the log keeps it, why it was left and when. Who each was paying is shown as a role (the client, an operative) unless you also hold `crimson.identity`. Check their inventory or balance first: `/ch-settle <line> delivered` if it is there, `pay` if it is not. A line whose arrival is unknown (the server stopped while it was being given, or what arrived could not be read) carries the hint *check what they received, then pay the rest with `/ch-settle <line> pay <amount>`, or delivered*: what the line says arrived may be short, and `pay` alone would give that part again. Also lists every other line nothing will pick up until the next start: a held line owed to a player and in no retry queue (a give that stopped part-way on the running server, marked *arrival unknown* and settled the same way; a queue entry that failed or was cleared under it, marked *in no retry queue* and *never given*; or a payout whose claim raised after owing it and before paying it, which leaves the contract mid-claim until the next start, marked *stalled claim*; nothing of those last two was given, so only `pay` settles them), and a line left mid-release by a call that raised, which nothing else is finishing (`/ch-settle` first puts it back as the next start would, left for you when it names whom it was being given to). Never a line something on the server is still working on: one a release, a login retry or another settle holds or is about to queue (every claim is counted from before it is made, and no line a claim holds is listed at all, one left for you or left mid-release included), or a held line not left for you of a contract a claim or an ending is still running on (a payout the claim has just owed to its hitman and is about to pay; a stake of a contract an expiry has just closed and is about to forfeit); and nothing at all while the server is still recovering from a restart, when it says to try again in a moment, or after recovery failed at the start, when it says so and that the resource needs a restart once the cause the console logged is fixed. Also lists, marked *ending unfinished; it settles itself within a minute*, a held line owed to nobody of a contract that has closed whose ending (an expiry, a void, a cancel, a buyout) raised an error after closing it and before handing that line over: it is not yours to settle, and the server finishes that ending itself, as a restart would (a stake by why the contract ended, the rest back to the client), at its next maintenance pass for such endings (every 30 seconds, ten contracts at a time, at the default 10-second tick). Never a line of a contract still being placed (its escrow taken and its row not yet written). Also lists, while the log keeps its row, a held line the server stopped before anything of it was given, of a contract that has closed or was never stored, each with the command that settles it: only `return`, to whoever put it up, where nothing names whom it was paying (the row the server writes now for such a line names nobody, so a `pay` has nobody to go to and is refused as `invalid_input`; of a contract that has closed, such a line is its ending's, listed as *ending unfinished* above); `pay` or `return` where the line or an older row names whom it was paying; `return <citizenid>` for one of a contract never stored that does not say whose it is; and nothing for one queued for a player since, which needs nothing (of a contract still live it is that contract's own again, and not listed), and held lines of a contract that was never placed which do not say whose they are (written by an older version) |
| `/ch-settle <line> pay [amount]\|return [citizenid]\|delivered` | Finish one of those by hand. `pay` goes to the player the line is owed to, as `/ch-stuck` names them (whom the interrupted payment was for; for a `return` the server stopped, the one it was returning to); `return` goes to whoever put the line up, so a hitman's stake goes back to that hitman. Either gives only the part that has not already arrived. `delivered` only on a line whose give may have run (left for you, or marked *arrival unknown*), and `return` on such a line too, or on a held line owed to nobody of a contract that was never stored, or of one that has closed where the line names whom an interrupted give was going to (one naming nobody is its ending's: every disposition is refused with *ending unfinished; it settles itself within a minute*, and the server hands it over as that ending would have, at its next pass for such endings): one *in no retry queue*, or a *stalled claim*, was never given, so only `pay` settles it, to the player it is owed to (given now, or queued again), and the others answer *Not settled: nothing of it was given*. A line owed to nobody of a contract still live (active, accepted, or mid-claim) is that contract's own (a collection its next claim pays, a bonus, a stake): every disposition is refused, and the command says the contract is still live and that `/ch-void <contract>` closes it and returns its escrow (a contract mid-claim once its claim is done, or, left by a *stalled claim*, after the restart `/ch-void` then asks for). `pay <amount>` (a count for an item), only on a line `/ch-stuck` lists as left for you, gives exactly that much and counts the rest as already with them on the line (`deliver_arrived`), with the amount in the log: for a line whose arrival is unknown, once you have checked what they received. The amount has to be a whole number of at least 1 and no more than the line still owes, or it is refused as `invalid_input`. Every check on the line is made again on it as the settle claims it, a `delivered` included (whether its contract is closed is not: a closed contract never opens again): if another settle queued it, left it owing less than the amount you named, or left it owed to somebody else since, nothing moves and the command says why (already queued for them; now owes only that much; that something else is giving or settling it, for one another call asks for, or whose contract a claim or an ending has started on, since; no longer left for you; or, for one now owed to somebody else, that something else holds it or it is owed elsewhere). A plain `pay`, or an amount the line still covers, gives what is left after another settle gave part of it. A line something on the server is working on right now (a release or login retry giving it, another settle, a contract still being placed, whose escrow is taken before its row is written, a claim running on its contract, which owes a collection's lines before it pays them, and until it has owed them is refused as still live, or an ending running on its contract, which writes the contract closed before it moves its escrow, so a stake an expiry is about to forfeit reads as a held line of a closed contract until it has) is that one's: nothing moves, and the command says something else is giving or settling it; check again with `/ch-stuck`, which lists it once nothing is (a claim that raised leaves its payout there as a *stalled claim*). While the server is still recovering from a restart, nothing moves: the command says to try again in a moment; if recovery failed at the start, it says so instead, and that the resource needs a restart once the cause the console logged is fixed. If the give raises again with nothing arriving, the line goes back on their retry queue, tried again while they are in the city and at their next login and left for you after three such raises, and the command says it was re-queued after a failed give; if part of it arrived or what arrived cannot be told, it is left for you again at once and the command says so (see `/ch-stuck`). `delivered`, only on a line `/ch-stuck` lists as left for you, settles it to that player without giving anything, for one you found already there, and the line itself records it (`settled_by_staff` = `delivered`, `settled_staff` = who, `settled_at` = when). Every settle is logged, and the log written at once, not at the next flush: a `pay` or `return` before anything moves (`admin_settle_line`: who, the line, the amount asked for and what the line owed) and what came of it after (`admin_settle_result`: what was actually given, and what the line owed once claimed); a `delivered`, which gives nothing, as it settles (`admin_settle_line`, with what the line owed). A settle that raises an error is logged too (`admin_settle_raised`, with the error in the console), anything it stopped mid-give is left for you in `/ch-stuck` with its arrival unknown, and the command says so. A line already queued for the player it names needs nothing: `pay` answers *Already queued for* them, named as `/ch-stuck` names them. A line that does not say whose it is needs `return <citizenid>` once you know who put it up; the citizen id is refused on any other line. A player who is offline gets it at their next login, and the command says so; one in the city whose give was refused (no room in their pockets, or an account that would not take it) has it queued too, tried again while they are in the city, and the command says the give was refused |
| `/ch-review [all]` | The **review queue**: money events no rule on the server can settle by itself, kept in the store (in every mode) until you resolve them, and listed by `/ch-stuck` below its escrow lines while they are open. One is left for you when a buyout was charged and the store would neither record it nor say whether it had (`bailout_unrecorded`); a buyout premium handed back reached nobody (`bailout_refund_stranded`); money owed could not be put on the books (`owe_id_exhausted`); an anonymity fee could not be credited back (`anonymity_fee_refund_failed`); escrow was taken and the store would not confirm the write (`escrow_take_unverified`), or taking a line raised (`escrow_take_raised`), or escrow taken for a contract that was not placed could not be given back (`escrow_rollback_failed`); a contract's escrow was taken and the store would neither write it nor read it back (`contract_unrecorded`, closed by the server itself if the store answers before a restart); or a payout reached its recipient and something else settled its line as well (`escrow_settle_lost`). Each item says what happened and what settles it, who was involved (as roles to staff without `crimson.identity`), how much or which goods, what was known (what arrived, the error), and what the store says now (the contract's state, whether the escrow lines it names are there). With no argument it lists the open ones; `all` lists the latest fifty, resolved ones with how, by whom and when. The audit log keeps the same events, but is pruned after `Config.Audit.RetentionDays`; the queue keeps an item until it is resolved, and the contract an open item names is kept until then too (`Config.Audit.ContractRetentionDays` prunes it at the first tick after) |
| `/ch-review <id> refund <citizenid\|role> <amount> [cash\|bank\|dirty]`, `refund <citizenid\|role> items`, `pay <citizenid\|role>`, `dismiss <note>` | Resolve one. A role is one the item names (`payer`, `creator`, `from`, `owed`, `recipient`), so staff who may not see who is behind an anonymous party still resolve it. `refund` gives that amount of one money the item records (at most what it records there; name the money where it records more than one), or with `items` every item and weapon it records, as they were. `pay` gives everything it records, less any part known to have arrived. `dismiss` gives nothing and needs a note saying why. What is given is given as every payout here is: an escrow line owed to them under an id that comes from the item, handed over now if they are in the city and at their next login if not, and, if the give raises without telling what arrived, left for you in `/ch-stuck` like any other line. Resolving an item twice gives nothing the second time, and a resolution the server stopped part-way is finished at the next start, or by the next `/ch-review` of it, as it was decided rather than as asked again. Every resolution is logged (`review_resolved`) and written at once. Waits for recovery after a restart, as `/ch-settle` does. `crimson.admin` only |
| `/hitmanadmin` | Opens the **admin panel** (see *Admin panel*). In game only; `Config.Admin.Commands.panel` |
| `/ch-refresh timers` | Test servers: bring every wait and cooldown forward. Deadlines are only ever moved later, never earlier. `crimson.admin` itself only — the extra ACEs do not open it — and audited. It was `/hitmanadmin`, which is the panel's now: a `config.lua` that still gives the refresh that name has it moved to `ch-refresh` at start, with a warning |

Faults the phone page hits are reported to the server and kept for `/ch-diag`;
`Config.Debug = true` prints each in the console too, with its full stack
trace. The page log `/ch-diag` asks a player's phone for goes to whoever asked:
their F8, their open admin panel, or the server console that ran it, once, and
only within thirty seconds of being asked for. A player on the whitelisted-job
view sends it too; with the view off, the diagnosis says a barred player's app
cannot.

The staff webhook is optional and is set in `server.cfg`, never in
`config.lua`, which every player's game downloads:

```
set crimson_hitman_webhook "https://discord.com/api/webhooks/..."
```

Use `set`, never `setr`: `setr` sends the value to every player too. It
mirrors financial movements and refused attempts, without identities, as one
message per audit flush rather than one per row, and backs off when Discord
says to. Routine refusals are counted on one line rather than listed: rate
limits, and hits on a target whose damage never showed (rounds into somebody
already down, a second gun in the same fight). Hits on players no contract
names are not looked at at all, so ordinary shootouts never reach it. An older `config.lua` that still sets `Config.Audit.Webhook` gets a
warning at startup and the URL is not used: it has already been sent to
every player, so regenerate it in Discord and move the new one to
`server.cfg`.

On the phone, tapping the build line at the bottom of the Ledger tab five times
opens a diagnostics panel showing the page's recent requests and faults.

Every maintenance job times itself: each job the ten-second tick runs, and the
death sampler's pass every second. One that takes longer than
`Config.Diagnostics.SlowJobMs` (5 ms as shipped) prints one console line
naming it with `Config.Debug` on, at most once every five minutes per job; `0`
turns that off.
`/ch-diag` lists the five slowest with their numbers either way. The times are
processor time (`os.clock`), so read them as "about this slow". In `mysql`
mode the time a job spends waiting on the database is left out: while it
waits, the server runs everything else, and that is not this job's work.

---

## Console output

With `Config.Debug = false`, as shipped, the server console stays quiet: a
normal start on a sound config, and normal play, print nothing at all. Every
line this resource prints is one of three kinds.

| Kind | Printed | What |
|---|---|---|
| **Always** | Whatever `Config.Debug` says | Refusing to start (`FATAL`, `failed to start`, waiting for `qbx_core` or `ox_inventory`); money at risk or left for staff (a review item opened, a stuck or parked escrow line, an ending or a handover claim that raised, an app request, staff command, admin panel write or `/cleanse` that moves money and raised, each request or command once every five minutes, and when they are up one line saying how many more raised under it meanwhile (*request cancel raised 2 more time(s) …; run ch-diag …*), `BOOT RECOVERY FAILED`, contracts that could not be loaded, starting over money another storage mode holds, a maintenance job that moves money failing: the buyout queue, expiry, owed payouts, unfinished endings, placements and acceptances left part-way, idle holds, or the tick as a whole); a write that failed or read back wrong (a `json` file that could not be written, was torn or is missing, contract files left in memory because they could not be written, once every five minutes, a newer index copy used or a contract file the index did not name taken back in, the downtime dated from something other than the heartbeat, a kill photo that could not be written or reads back short, the audit or storage flush failing). A job that fails on every tick is printed once every five minutes, each failure in between counted in the diagnosis |
| **Settings that need attention** | One line at the end of a start with `Config.Debug` off: `[crimson-hitman] N setting(s) need attention; run ch-diag (F8 or the server console) or open /hitmanadmin to see them`, and nothing when there are none. Each in full with it on | Every startup warning about `config.lua` (a value read as the nearest it may be, a setting your config lacks, counted once for each, an integration you configured that is not running, an admin panel setting not applied). One found later (an empty photo host list on the first tick) says the line again with the new count |
| **Everything else** | Only with `Config.Debug` on | The integration list, start progress (`started in json mode`), finished migrations, photo sweeps, photo host list changes, slow maintenance jobs and failing ones that move no money, a read the app or a staff command asked for that raised, the settings changed from the panel in force, the `json` size advice, page faults players' phones report (marked *page stack from …*, with colour codes taken out), notes (memory mode, the playtime rule reading QBox metadata) |

Nothing is lost: `ch-diag` (in F8 or the server console) and **Run the
diagnosis** in the admin panel list the settings that need attention in full,
everything the start said and the newest forty lines since, each repeated line
counted once. The lines printed whatever Debug says are kept in a list of their
own, so nothing a player can cause (page fault reports, counted as one entry)
pushes money left for staff out of it. FiveM colour codes (`^0` to `^9`) are
taken out of every line, so a name or a page's report cannot colour the
console. The panel's overview shows the settings that need attention
among what the diagnosis says wants doing. In game, players' F8 consoles show
nothing from this resource but a staff command's own answer; `Config.Debug` on
also prints the client's own notes there (an lb-phone export missing, say).

`Config.Debug` is in the admin panel's Features (*Debug output in the server
console*) and kept across restarts like every other setting there: it is read
at every line, so it takes effect at once. The lines a start prints before the
panel's settings are applied (the store opening and its migrations) follow
`config.lua`; the start's settings line, and everything after, follow the
panel.

---

## Admin panel

`/hitmanadmin` (`Config.Admin.Commands.panel`) opens a full-screen panel in
game: everything the staff commands do, each as a button, an overview, the
audit log, a player lookup, and every feature switch and limit, changed live
and kept across restarts. Nothing in it is a command, and nothing in it names
one: where an answer sends you next, it names the section or button (*see
Stuck escrow*), while the same answer to a command in F8 keeps the command's
words. It is this resource's own page (`ui/admin.html`), apart from the
phone app, which lb-phone draws from `ui/index.html` as before. The page stays
hidden and takes no input until you open it; Escape or its close button closes
it, and a restart of the resource gives the focus back.

**Who may do what.** The server checks the ACE again on every request the page
makes, not only when it opens, so taking an ACE away closes the panel at its
next request.

| Permission | What it opens |
|---|---|
| `crimson.admin` (`Config.Admin.Ace`), or one of `Config.Admin.ExtraAces` | Opening the panel, and every section that reads: the overview, contracts and their detail, Stuck escrow, the review queue, the audit log, players, the settings (to look at), the diagnosis |
| `crimson.admin` itself | Everything that writes: void, settle, resolve a review item, change or reset a setting, the timer refresh, flushing the log |
| `crimson.identity` (`Config.Admin.IdentityAce`) as well | Who is behind an anonymous client or hitman, anywhere in the panel; every citizen id; finding a player's rows in the log; whois |

Without `crimson.identity` an anonymous party is shown as *Anonymous*, every
citizen id is the party's place on the contract (*the client*, *the target*,
*operative &lt;alias&gt;*, or *(a player)*) in contract details, the log and
the player view alike, a search by citizen id or name never finds a contract
through a party who placed or took it anonymously, and what a player is owed,
the deliveries waiting for them and the notices kept for them on a contract
they were anonymous on are left out of their view. So is their record (placed,
completed, failed, survived): its counters hold their anonymous contracts too,
and nothing says which. The review queue's items, resolved ones included, name
whom a resolution paid by the party's place, and carry no item's metadata (a
weapon's `registered` is its owner's name). What a staff member with
`crimson.identity` searched for, and how many contracts it found, reads
*(identity only)* in the log. Each lookup that unmasks is its own audit row
(`admin_panel_contract_identified`, `admin_panel_logs_identified`,
`admin_panel_player_identified`, `admin_panel_search_identified`). Every request
is rate-limited per staff member (`Config.Cooldowns.admin`, and
`Config.Cooldowns.adminWrite` as well for a write). Every write is in the audit
log, written at once rather than at the next flush. While the server is still
recovering from a restart, or after recovery failed, every write except
flushing the log is refused, in the commands' own words.

**Sections.**

| Section | What it shows | What you can do |
|---|---|---|
| **Overview** | Contracts by state; operatives on contracts now, and how many contracts they hold; money held in escrow by account, and items and weapons held; owed deliveries (lines, players, and how many are in a retry queue); the lines waiting for staff, headed by the ones left for you to settle, with the ones that need nothing (queued since, or an ending settling itself) said apart, and a button to **Stuck escrow**; open review items; kill photos waiting, kept and served, with their size; the storage mode, the rule new contracts are placed under and the recovery state; the slowest maintenance jobs; what the diagnosis says wants doing, the settings that need attention among it; how many settings are changed from the panel. Refreshes itself every `Config.Admin.PanelRefreshSeconds` (10) while open | — |
| **Contracts** | Search by contract id, citizen id or name, and filter by state, completion rule and date; `Config.Admin.PanelPageSize` (25) a page, newest first. The detail: terms, payouts, every escrow line with its state and what it owes and what arrived, the operatives, open proposals, the lines `/ch-stuck` lists for it with what settles each, and its audit timeline | **Void** with a reason, as `/ch-void`; **settle** a listed stuck line `pay`, `pay <amount>`, `return` or `delivered`, as `/ch-settle`. Both answer in the commands' exact words |
| **Stuck escrow** | Every escrow line waiting for staff, as `/ch-stuck` lists it (the badge beside it counts the ones left for you to settle): what each holds, whom it is owed to, why it waits and whether its arrival is known, each naming its contract, which opens its view; and how many items wait in the review queue, with a button to it. Nothing is listed while the server is recovering from a restart | **Settle** each line `pay`, `pay <amount>`, `return`, `return <citizenid>` or `delivered`, as `/ch-settle`, with two clicks; its answer stays beside it and the list is read again |
| **Needs review** | The review queue's open items with what is known and what the store says now, and the latest resolved ones with how, by whom and when | **Refund**, **pay** or **dismiss** (with a note), as `/ch-review`: given once, however often it is asked |
| **Logs** | The audit log, newest first, a page at a time, filtered by kind, part of the action, contract id, citizen id (with `crimson.identity`) and time. Read from whichever store keeps it (the json day files, the `crimson_audit` table, or memory); a page follows on from the last even when old rows age out in between. A contract id or citizen id box is marked, and asks nothing, until it holds a whole one | — |
| **Players** | By server id or citizen id (in any case: it is read as the server keeps it): their contracts (as `/ch-contracts`), their record (with `crimson.identity`), what they are owed and whether it is queued for them, and how many notices wait for their next login. A citizen id nobody in the city has and nothing you may see names answers *not found* | **Whois** on a contract, with `crimson.identity` |
| **Features, limits & settings** | Every on/off switch in `config.lua`, grouped by section, with a line on what it does and what turning it off does to things already under way, and the two multi-choice features (`Config.Completion.Fulfilment`, `Config.Completion.PhotoStorage`). Then the limits: every number in `Config.Limits`, the anonymity fees and their account, the informant's price, the stake ceilings, the handover countdown, radius and health floor, buyout pricing, the targeting radii and page sizes, `Config.Ledger.PhotoRetentionDays`, the advisory job lists and every rate limit. Each with its value now, what `config.lua` says, and whether the value comes from `config.lua` or the panel | **Change** one, **reset** one, **reset all** |
| **Tools** | — | **Bring timers forward** (`/ch-refresh`, test servers), **Run the diagnosis** and read it (`/ch-diag`, with the settings that need attention and what the console said), **Flush the audit log** (its answer says when the store did not save, and which file it could not write) |

**Every command is a button.** The server keeps the list (`Panel.COMMANDS`,
in `server/panel.lua`), and the test suite fails for a command added without
one.

| Command | In the panel | Needs | Two clicks | Audit row |
|---|---|---|---|---|
| `/ch-timeline` | A contract's view (a row in Contracts, or any contract id shown) | read | — | `admin_panel_contract` |
| `/ch-contracts` | Players: **Look up** | read | — | `admin_contracts` |
| `/ch-stuck` | **Stuck escrow** | read | — | `admin_stuck` |
| `/ch-diag` | Tools: **Run the diagnosis** | read | — | — |
| `/ch-void` | A contract's view: **Void contract** | write | yes | `admin_void` |
| `/ch-settle` | Stuck escrow, or a contract's view: **Pay**, **Pay amount**, **Return**, **Return to**, **Delivered** | write | yes | `admin_settle_line` |
| `/ch-review` | Needs review: **Refund**, **Pay**, **Dismiss** | write | yes | `review_resolved` |
| `/ch-refresh` | Tools: **Bring timers forward** | write | yes | `admin_timers_refreshed` |
| `/ch-whois` | A contract's view, or Players: **Whois** | identity | — | `admin_identify` |

*read* is `crimson.admin` or one of `Config.Admin.ExtraAces`, *write*
`crimson.admin` itself, *identity* `crimson.identity` as well; opening the
panel at all needs *read*. `/ch-timeline` leaves no audit row; its button
writes `admin_panel_contract`.

**Using the page.** The panel is sized for a game window 1280 to 1920 pixels
wide, and still works at 1024. It opens on the overview, with the open review
items, the lines left for you to settle and the settings changed from the panel
counted beside their sections. A contract opens in a drawer over the list,
with what you can do to it first: void, whois, and each stuck line's settle
buttons. Anything that moves money or cannot be undone (void, settle, resolve,
reset, the timer refresh, and lowering `Config.Ledger.PhotoRetentionDays`,
which deletes the unopened kill photos past the new age at the next sweep)
takes two clicks: the first turns the button brass and says what the second
does, and it disarms itself after three seconds. Enter in the photo age's box
only arms its Save; it never lowers it. The server's answer is shown in its
exact words where you asked, and as a toast in the corner; a review item you
resolve stays in the queue, marked resolved with that answer, until you press
Refresh or open another section. A refusal (a rate limit with its wait, a
recovering server, a value the start-up checks refuse) is shown the same way.
The contract search reads the store at most once every five seconds between
every open panel, so a contract placed a moment ago shows within that; the
search asks once you stop typing, and an answer to an older search never
replaces a newer one. Read-only staff see every write control disabled, with
why on hover, and no resolve form on a review item, and a banner says when
recovery holds writes back. The page never asks for whois, a player's log rows
or anything that unmasks without `crimson.identity`; what it shows is only what
the server sent, already redacted for you. Escape (as you let go of it), or
Close, closes it, and the pause menu stays shut for a moment after; so does the
server refusing a read (the ACE taken away), with why. The icons come from Font Awesome's CDN,
and every control has its words beside its icon, so a game that cannot reach
the CDN loses nothing but the icons.

**Settings changed from the panel** are kept as overrides in the store your
server runs: `data/records.json` in `json` mode, the `crimson_settings` table in
`mysql` mode (created at start, and in `install/sql/crimson_hitman.sql`), and in
memory mode for as long as it keeps anything, which is until the resource
stops. They are applied over `config.lua` at every start, right after the
start-up checks and before anything reads the config, all of them checked
together as they stood in force (a least buyout and a most changed in either
order come back as a pair), and they are in force the moment you change them,
because the code reads the config when it uses it. One change is saved at a
time: one sent while another is being saved is refused as busy, so two staff
changing keys that depend on each other can never leave a pair the start
would refuse. `config.lua` is never rewritten: setting a value back to what it says, or
resetting it, makes it the file's again. Each value is checked the way the
start checks `config.lua` (the same checks, run against a copy of the config
with your change in it), so a value the start would refuse, or quietly
correct, is refused, in the start's own words: a least buyout above the most,
a deadline past the lifetime, a least reward above `Config.MaxContractValue`.
Every change is in the audit log with the old and the new value and who made
it (`admin_setting_changed`, `admin_setting_reset`,
`admin_settings_reset_all`). `/ch-diag` lists every setting in force over
`config.lua`, and any the store holds that the start did not apply (one an edit
to `config.lua` has since made invalid, say), with why; the start counts it
among the settings that need attention (in full with `Config.Debug` on). The settings players' games read themselves (the nearby list,
headshot backgrounds, the app on the home screen) are sent to every game when
they change and to each player as they join, and every open phone app re-reads
its settings at once.

**What turning something off does to what is under way.** A contract already
placed, and money already owed, finish under the rules they started with: only
new actions are refused, and the app says the feature is turned off by the
server (or uses the feature's own words, for buyouts, messages and calls). A
buyout already paid still closes its contract after its delay, and `/cleanse`
says buyouts are off; proposals already open can still be answered; a contract
keeps the completion rule it was placed under; a kill photo is taken the way
its token was issued; an anonymity fee refunded is always the one charged, to
the account it came from; money already in escrow for a reward source you turn
off is paid out or returned as before. Lowering a cap below what is in use
cancels nothing and only refuses new ones. A rule read each time it is used
(the handover's and the kill's checks) applies from the next check, except the
handover radius, which a countdown already running keeps from when it was
armed. A name a target already bought from the informant stays on their card
while the informant is off. The panel says which for every key. `Config.App.DefaultInstalled` is kept and sent to
every game but applies when the app is next added to a phone (after this
resource or lb-phone restarts, or when a player rejoins), and the panel marks it
*applies after restart*.

Shown read-only, with why: `Config.Admin.Enabled`, `Config.Admin.Ace` and
`Config.Admin.IdentityAce` (changed from the panel, a slip could lock staff
out), the panel's own rate limits `Config.Cooldowns.admin` and
`Config.Cooldowns.adminWrite` (set too low from the panel, they would refuse the
request that puts them back, at every start), `Config.Database.Mode` (changing
storage needs the old mode's money settled and a restart; see *Changing storage
mode*), `Config.Database.AllowModeSwitch` and
`Config.Database.Json.SyncOnFinancialWrite`. A value the store still holds for
one of these from an older version is not applied, is listed as *not applied*,
and **Reset to config.lua** on its row takes it away.
There is no single switch for the phone app as a whole:
`Config.WhitelistedView.Enabled`, `Config.HideAppFromBlockedJobs` and the job
lists decide who sees it and what it shows them, and the panel works whatever
they say.

---

## Integration Guide

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
| `access` | read | — | `{ canWrite, canIdentify, pageSize, refreshSeconds, recovery = 'ready'\|'recovering'\|'recovery_failed', version }` (no command names: the page is buttons only) |
| `overview` | read | — | `{ at, contracts = { total, byState = { [state] = n } }, hitmen = { active, operatives }, held = { cash, bank, dirty, items, weapons, lines }, owed = { cash, bank, dirty, items, weapons, lines, players, queued }, stuck = { total, leftForStaff, byWhy = { [why] = n } }` (absent while recovering; `leftForStaff` counts the lines something settles by hand, `total` every line listed)`, reviews = { open }, photos = { waiting, kept, served }` (each `{ count, bytes }`)`, storage, fulfilment, photoStorage, recovery, slowest = [{ name, max, avg, last, runs }], slowMs, warnings = [line], overrides, auditQueued }` |
| `contracts` | read | `{ query?, state?, rule?, from?, to?, page? }` (times in os.time seconds) | `{ rows = [{ id, state, mode, rule, created_at, deadline_at, resolved_at, resolution, target, client, anonymous, slots, claimed }], page, pages, total }` |
| `contract` | read | `{ id }` | `{ contract = { id, state, mode, rule, reason, created_at, deadline_at, expires_at, resolved_at, resolution, paused_since, bailout_amount, penalty_amount, bonus_percent, slots, claimed, next_slot, buyout_queued, target_protected, anonymous, client = { name, cid? }, target = { name, cid? } }, escrow = [line], hitmen = [{ id, alias, anonymous, name, cid?, state, accepted_at, left_at, claims, stake, last_claim_at }], amendments = [{ id, kind, proposer, outcome, expires_at, payload }], timeline = [row]` (oldest first)`, stuck = [stuck]` (absent while recovering)`, canVoid }` |
| `void` | write | `{ id, reason? }` | — (`message` is `/ch-void`'s answer, in the panel's words) |
| `settle` | write | `{ line, disposition = 'pay'\|'return'\|'delivered', amount?` (with `pay`)`, owner?` (with `return`, a citizen id) `}` | `{ detail }` (`message` is `/ch-settle`'s answer, in the panel's words) |
| `stuck` | read | — | `{ recovery, reviews, lines = [stuck] }`: every line waiting for staff, as `/ch-stuck` lists them, and the review queue's open count; `lines` absent while recovering. Audited `admin_stuck`, as the command is |
| `reviews` | read | `{ all? }` | `{ items = [{ id, kind, about, contract, parties = [{ role, who }], amount, account, items, known, now, state, created_at, resolution, resolved_by, resolved_at, unwritten }] }` |
| `resolve` | write | `{ id, action = 'refund'\|'pay'\|'dismiss', who?` (a role the item names, or a citizen id)`, amount?, account?, goods?, note? }` | `{ detail = { action, settled, pending, parked, continued } }` (`message` is `/ch-review`'s answer, in the panel's words) |
| `logs` | read | `{ kind?, action?, contract?, actor?, from?, to?, limit?, cursor? }` | `{ rows = [row], next }`: pass `next` back as `cursor` for the page after; absent on the last |
| `player` | read | `{ subject }` (a server id, or a citizen id) | `{ player = { cid?, name, online, server }, contracts = [{ id, state, role, anonymous, target, created_at, resolution }], stats = { completed, failed, placed, survived, rate, standing }` (with `crimson.identity` only)`, owed = [line + queued], pending, notices = { count, titles } }`; `not_found` for a citizen id nobody in the city has and nothing shown names |
| `whois` | identity | `{ id }` | `{ creator = { cid, name, anonymous }, target = { cid, name }, hitmen = [{ alias, cid, name, anonymous, state }] }` |
| `settings` | read | — | `{ features = [setting], limits = [setting], readonly = [setting], overrides }` |
| `setSetting` | write | `{ key, value }` (a boolean, a number, one of `choices`, or a list of job names) | `{ key, value, old, source }`; refused `not_allowed`, `read_only`, `invalid_value`, `store_failed` or `busy` (another change is being saved), with why in `message` |
| `resetSetting` | write | `{ key }` | `{ key, value, old, source }`; also `not_overridden` and `busy` |
| `resetSettings` | write | — | `{ keys }` |
| `refresh` | write | — | `{ lines }` |
| `diag` | read | `{ subject? }` (a server id) | `{ lines }` |
| `flush` | write | — | `{ written }` |

`line` (an escrow line) is `{ id, contract, slot, portion, source, amount?,
item, quantity, state, owed_to, releasing_to, taken_from, staker, settled_to,
settled_at, settled_by_staff, arrived, raised, parked, owes }`; `row` (an audit
row) is `{ ts, kind, action, contract, actor, detail }`; `stuck` is a `/ch-stuck`
entry, `{ line, contract, amount, source, item, quantity, portion, intended,
why, at, raised, arrived, settles, orphan, unfinished, actions }`, where
`actions` lists what settles it: `pay`, `pay_amount`, `return`, `return_owner`
(a `return` naming a citizen id) and `delivered`; never `return` for a line
owed to somebody (portion `owed`), which nobody put up to take back. `setting` is `{ key, group,
label, about, kind = 'switch'\|'choice'\|'number'\|'list'\|'text', choices?, min?,
max?, integer?, live, inflight, readonly?, destroys?, value, default, source =
'config'\|'panel', by?, at?, ignored? }`: `live = false` is *applies after
restart*, `readonly` is why it cannot be changed, `destroys` (with `%s` for the
new value) is what lowering it deletes for good, which the page asks a second
click for, and `ignored` is why a value the store holds was not applied at start.

**Convars.**

| Convar | How | What |
|---|---|---|
| `crimson_hitman_webhook` | `set` in `server.cfg`, never `setr` | The staff Discord webhook (optional) |
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

**ox_inventory** (required). `GetInventoryItems`, `GetInventory`, `Search` and
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
`unique_id = 'ch-<contract>-<stage>'` (`posted` or `accepted`); it is cleared
with `ClearNotification` when the contract ends.

**Other optional hooks**, each skipped when the resource is not started:
`sc-ambulance` (`IsDead`, `IsLaststand` through
`Config.Completion.DeathStateProviders`; QBox metadata answers otherwise),
`sc-blackmarket` (`AddTrust(citizenid, amount)` on a completed contract,
`Config.Progression`), `MugShotBase64` (`GetMugShotBase64` on the client, for
headshots), `Config.Kidnap.RestraintProvider` (`IsRestrained(playerId)`) and
`Config.Immunity.PlaytimeProvider` (minutes played by citizen id).

---

## Troubleshooting

| Issue | Solution |
|---|---|
| A player cannot find the app | It is in the phone's App Store, not on the home screen: each player downloads it. Set `Config.App.DefaultInstalled = true` to put it on every eligible phone. Players with a barred job (`Config.BlockedJobTypes` / `Config.BlockedJobNames`, any job they hold) never see it. `/ch-diag <player id>` says why it is not showing for them |
| A kill does not complete a contract, or there is no Verify kill | As shipped, `Config.Completion.Fulfilment` is `'alive'`: contracts are completed only by bringing the target alive to the person who placed the contract, who has to be there for the handover, and a kill never completes one (the server answers `kill_not_allowed`). Set it to `'either'` to let kills complete contracts placed from then on; ones already placed keep their rule. `/ch-diag` says which is in use |
| A staff command typed in chat seems to answer nothing | It answers in your F8 console, never in chat: press F8. A notice on your screen says *Printed to your F8 console* |
| The console prints `N setting(s) need attention` at start | `config.lua` has settings the start read as something else, or lacks some. Run `ch-diag` in F8 or the server console, or open the admin panel's **Tools** and **Run the diagnosis**: *settings that need attention* lists each in full. Or set `Config.Debug = true` to have the start print each |
| The console says nothing at all, not even that it started | That is the shipped `Config.Debug = false`: a sound start says nothing. `ch-diag` lists what it would have said |
| A staff command answers "Not authorised" in game | Grant the ACE in `server.cfg`: `add_ace group.admin crimson.admin allow` (and `crimson.identity` for `/ch-whois`). The server console never refuses, so you can run any of them there meanwhile |
| The console printed `BOOT RECOVERY FAILED`, and `/ch-settle`, `/ch-void` and `/ch-stuck` answer *Recovery failed at the last start* | Boot recovery raised an error (the text after `BOOT RECOVERY FAILED:` says what), so what the last shutdown left part-way is not settled. Rather than act on it, the resource keeps the app, the login payouts, the maintenance tick and those commands closed until it is restarted; players running `/cleanse <id>` are told the server's contract system failed to start and staff have been told, and so is everyone who opens the app, on every tab, with no *Try again* (it answers `recovery_failed`). Fix the cause (a database that refused the query, say), then restart the resource (`restart crimson-hitman`): the next start runs recovery again |
| The console keeps printing `[crimson-hitman] still waiting after ...s for ... resource(s) to start` | The lines under it name `qbx_core` or `ox_inventory`, which is not started or runs under another name. Start it under that name; a renamed or forked copy never matches |
| The app stopped answering after you restarted `qbx_core`, `ox_inventory` or `oxmysql` | FiveM stops this resource with them and does not start it again. Run `ensure crimson-hitman` |
| `json` mode refuses to start on an empty `data/` | You replaced the resource folder and lost `data/`, which is the store. Put the old `data/` back and start it again. To start empty on purpose, run `set crimson_hitman_new_store 1` in the console, start the resource, then leave it unset (see *Updating*) |
| The resource refuses to start after you changed `Config.Database.Mode` | The mode you left still holds players' money, and the console lists each contract, what it holds and what clears it (a login, `/ch-stuck` and `/ch-settle`, the contract finishing), or names a `json` contract file that cannot be read. Switch back, clear them, then switch. `Config.Database.AllowModeSwitch = true` starts anyway, for money you have settled by hand (see *Changing storage mode*) |
| The console says `N contract file(s) could not be written and are kept in memory` | `json` mode: those `data/contracts/` files are held open by something (a backup tool, an antivirus, an editor) or the server cannot write there. Every other contract is still written, and each flush tries those again; until one lands, a crash loses what changed in them. Close whatever holds them; the line comes back at most every five minutes while they stay unwritten |
| The console says `table crimson_… already exists in this database and is not this resource's` | `mysql` mode found another resource's table under one of these names and changed nothing. Rename that table, or give crimson-hitman a database of its own |
| With `Config.Targeting.AllowNearby` on, somebody standing beside you is not on the nearby list | They are listed only once their own game has said they wear no mask, about a second after their character loads. Turned on from the admin panel, every game is told at once; turned on in `config.lua`, their game reads it when the resource starts, so restart it. Anyone masked, invisible or in another routing bucket is left off by design, and the list is closed to you while you are on a live contract |
| `/hitmanadmin` used to refresh the timers | It opens the admin panel now; the timer refresh is `/ch-refresh timers` (`Config.Admin.Commands.refresh`). A `config.lua` that still names the refresh `hitmanadmin` is moved to `ch-refresh` at start, with a warning: set it there to stop the warning |
| The admin panel opens but every button says *Not authorised*, or nothing changes | Reading needs `crimson.admin` or one of `Config.Admin.ExtraAces`; changing anything needs `crimson.admin` itself, and unmasking `crimson.identity`. The server checks on every request, so an ACE granted while the panel is open works at the next click |
| A setting changed from the admin panel is back to `config.lua`'s value after a restart | The start checks every override against `config.lua` as it is now, and one an edit has made invalid (a least buyout above a most you lowered in the file, say) is not applied. The start counts it among the settings that need attention (in full with `Config.Debug` on), and `/ch-diag` lists it as *NOT APPLIED* with why; reset it in the panel, or set it again |
| A value is refused in the admin panel with a sentence about another setting | It is checked against everything else in force, as the start would check it: a deadline past the lifetime, a least buyout above the most. Change the other one first |
| `/ch-diag` shows `photo hosts: 0`, or kill photos are refused as "not on this server's allow list" | `'host'` storage only. Add your phone's upload host to `Config.Completion.ExtraPhotoHosts` (a bare domain), and check that lb-phone's own camera upload works |
| Save to Photos keeps the photo in the app instead | `'server'` storage needs a public https address: set `Config.Completion.PhotoPublicUrl` or `web_baseUrl`, and add its host name to lb-phone's `Config.UploadWhitelistedHostnames`. `/ch-diag` says which address it uses and whether it reaches this resource |
| The startup warning says `Config.Audit.Webhook` is ignored | The URL in `config.lua` has already been sent to every player. Regenerate it in Discord and set the new one in `server.cfg` with `set crimson_hitman_webhook "..."` (never `setr`) |
| `failed to start: mysql mode cannot start: the database is missing what it needs` | Your database user may not create or alter tables, and something is missing. The lines under it name each table, column, index or engine change, with the database's own reason (error 1142 is a missing privilege). Import `install/sql/crimson_hitman.sql` as a user that may create tables, run the `ALTER TABLE` statements it prints as one that may alter them, or grant this user `CREATE`, `ALTER` and `INDEX` on the database; then `ensure crimson-hitman` |
| `/ch-settle` answers *ending unfinished; it settles itself within a minute*, and `/ch-stuck` lists the line the same way | An expiry, void, cancel or buyout raised an error (the console has it) after closing the contract and before handing that line over. Nothing for you to do: the maintenance tick finishes the ending as a restart would (a hitman's stake by why the contract ended, the rest back to the client) and says `contract … had closed with escrow its ending never handed over` (in the console with `Config.Debug` on, and in `/ch-diag` either way). If the console instead says `finishing the ending of contract … raised` on every pass, fix that cause; a restart finishes it too |
| `/ch-stuck` lists a line that "raised an error when they were given, or were stopped while being given" | `ox_inventory`'s `AddItem` or `qbx_core`'s `AddMoney` raised giving it (a hook or another resource failing): three times with nothing arriving, or once with only part of it arriving or no telling what did. Or the server stopped while it was being given, in which case it is owed to whom that give was going (the client, for a `return` you ran). It is still owed to that player and nothing gives it again on its own. Check their inventory or balance against what the line says arrived: if it is all there, `/ch-settle <line> delivered`; if not, `/ch-settle <line> pay` gives only what has not arrived. On a line marked *arrival unknown*, what the line says arrived may be short, so give what you found missing with `/ch-settle <line> pay <amount>` instead. A line marked *in no retry queue* was never given (its queue entry failed to be written, or a retry cleared it under a settle), and nor was a *stalled claim* (the claim paying it raised after owing it), so `pay` it (`return` and `delivered` are refused on it); one *left mid-release by a call that raised* was stopped by an error on the running server, and settles like any other. The console and the `escrow_deliver_raised` rows show the error |

---

## Dependencies

Ensure them before `crimson-hitman` in `server.cfg`. "Checked against" means
the calls this resource makes were read in that version's source; nothing here
has been run in game by this build.

| Resource | Needed | Known to work |
|---|---|---|
| `qbx_core` | Required (manifest dependency) | 1.24.0, checked against: `GetPlayer`, `GetPlayerByCitizenId`, `GetMetadata`, `GetJob`, `Save`, `Player.Functions.GetMoney` / `AddMoney` / `RemoveMoney`, the login and logout events, `modules/playerdata.lua` |
| `ox_inventory` | Required (manifest dependency) | 2.48.0, checked against |
| `oxmysql` | Required in every mode: the manifest loads `@oxmysql/lib/MySQL.lua` (`qbx_core` needs it anyway) | 2.14.3, checked against |
| `lb-phone` | Required for the app; not a manifest dependency | 2.8.0, the version this was built against (escrowed: exports from its documentation) |
| MariaDB or MySQL | `mysql` mode only | MariaDB 10.11.14, run against: tables made, imported, migrated and refused as described in *Install*; MySQL 8 by the reserved-word and collation checks only |
| `ox_lib` | Not used directly; `qbx_core` needs it | 3.40.3, beside `qbx_core` 1.24.0 |
| `sc-ambulance` | Optional: death and last-stand state, the defibrillator | This server's build |
| `qbx_medical` | Optional: read through the QBox metadata it writes | — |
| `sc-dispatch` | Optional: advisories in the MDT | This server's build |
| `sc-blackmarket` | Optional: criminal progression | This server's build |
| `MugShotBase64` | Optional: target headshots | — |

---

## Testing

The suite runs the real server modules against a stubbed FiveM runtime, so it
can be run anywhere Lua is installed:

```bash
sh crimson-hitman/tests/all.sh    # everything
CH_SUITES=journeys_spec lua crimson-hitman/tests/run.lua   # one area, in seconds
```

Six kinds of check, because each catches what the others cannot:

- **Server suite** (about 2,900 tests) — escrow arithmetic, the state machine,
  every payout and refund path, whole player journeys, every action against
  every contract state, deliberate exploit attempts, storage conformance
  across all three backends (mysql on an executor that refuses what MariaDB's
  strict mode refuses, with pairs of requests landed at every database wait
  of each other), every admin panel request against every
  permission (with what each staff member may see of an anonymous party),
  every feature switch turned off and on with what it does to things under
  way, settings kept across a restart in each backend, and randomised
  simulations asserting that no sequence of operations creates or destroys
  value.
- **Store invariants** — the same suite again with a monitor auditing the
  whole store after every write.
- **Static checks** — rules no unit test can see: no SQL built by
  concatenation, no handler reading an identity from a payload, every module
  the resource loader asks for exists, every event name agrees across UI,
  client and server, every config key is actually read, and the MySQL schema
  can hold every field the code writes.
- **UI suite** — the real `ui/app.js` driven against a scripted server
  through a minimal DOM. This exists because the two worst bugs in the whole
  build were in the app and invisible to Lua tests: a form that could never
  submit a valid contract, and an open that refreshed itself into a storm.
- **Layout suite** — the page rendered in a real browser at phone widths from
  280 to 414px, measuring tap targets, clipping, the tab bar over lb-phone's
  home indicator, the page's top under lb-phone's status bar, and the pale
  bands that keep both readable in lb-phone's light theme. Skipped
  where Playwright is not installed.
- **Staff panel suites** — the real `ui/admin.js` driven through the same DOM
  shim, which parses its markup (`tests/ui/admin_run.js`): every section and
  every action against a scripted server, the two-click confirms, the exact
  answers, read-only and identity access, recovery, stale answers, and player
  text that looks like markup staying text. And the page at 1280, 1920 and
  1024 wide in a real browser, without its icon font
  (`tests/layout/admin_run.js`): nothing off the window or cut off, no
  sideways scrolling, controls at least 28px, text at least 12px, the drawer
  and dropdowns inside the window, and nothing drawn over the game while it
  is closed.

**What it cannot prove:** behaviour against the real `ox_inventory`,
`lb-phone` and `qbx_core` builds. Work through `../docs/in-game-checklist.md` (in the repository, next to this resource folder) on
a test server before going live.
