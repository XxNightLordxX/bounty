# Crimson Hitman System

A criminal contract board for **QBox**, delivered as a custom **lb-phone** app.
Red and black, criminal-only, and built so the money cannot go missing.

Built against this server's actual stack: `qbx_core`, `ox_inventory`,
lb-phone 2.8.0, the 17mov character system, `sc-police`, `sc-ambulance`,
`sc-dispatch` and `sc-blackmarket`.

---

## Install

1. Drop `crimson-hitman` into your resources folder.
2. Add `ensure crimson-hitman` to `server.cfg`, **after** `qbx_core`,
   `ox_inventory` and `lb-phone`.
3. Open `config/config.lua` and check the sections marked below.
4. Restart. The console prints `[crimson-hitman] started in <mode> mode`,
   plus a warning for any configuration that will surprise you later.

The config ships in `json` mode: everything lives in files under
`crimson-hitman/data/` (`store.json`, `records.json`, `contracts/`, the
`audit-<day>.jsonl` log and `photos/`), which is what to back up. In `mysql`
mode the tables are created automatically on first start, as `utf8mb4` so an
emoji in a reason or a non-Latin character name is kept whatever the
database defaults to (a table an older version made is converted at start);
MariaDB and MySQL 8 both work. Nothing to import either way. A busy server
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

Restarting `lb-phone` is safe: the app comes back on every phone by itself.
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
how much. Switch back, let those contracts finish or cancel them in the app,
then switch. A store holding only finished history is no reason to refuse;
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
contract) against what those players are carrying.

### Configuration worth reading before you start

| Setting | Why it matters |
|---|---|
| `Config.Completion.PhotoStorage` | Where kill photos are kept. `'server'` (as shipped) needs no image host: the hitman takes the photo in the app's own viewfinder and it is kept as a file in `crimson-hitman/data/photos/`, which the server must be able to write to. `'host'` uses lb-phone's own camera and the image host it uploads to, keeping only the link. Either way only the client who placed the contract sees the photo, once (see *The kill photo* below). `/ch-diag` says which is in use |
| `Config.Completion.PhotoMaxSide` / `PhotoMaxBytes` | `'server'` storage only: the app shrinks each kill photo until its longest side is at most this many pixels (1280) and it weighs at most this many bytes (600000), and the server refuses anything bigger |
| `Config.Completion.PhotoPublicUrl` | `'server'` storage only: the public **https** address this server serves photos from when a client saves one to their phone's Photos, such as `'https://photos.example.com/crimson-hitman'`. Unset (as shipped), the server's `web_baseUrl` is used. Add its host name to lb-phone's `Config.UploadWhitelistedHostnames`. See *No image host?* below; `/ch-diag` says which address is used and whether lb-phone takes it |
| `Config.Completion.KeptPhotoDays` | How many days a photo kept for its client in the app (because their phone could not save it) lasts. Unset (as shipped), it stays until they delete it. `/ch-diag` says how many are kept and how much disk they take |
| `Config.Completion.ExtraPhotoHosts` | `'host'` storage only. Kill photos are accepted only from image hosts lb-phone itself allows uploads from, plus these. Ships with Fivemanage (`fivemanage.com`, `fmfile.com`), lb-phone's default uploader. If `/ch-diag` shows `photo hosts: 0`, or kill photos are refused with "not on this server's allow list", add your phone's upload host here (a bare domain, no `https://`). lb-phone's camera upload must work first |
| `Config.Database.Mode` | `json` (as shipped; no database at all), `mysql` (oxmysql), `memory` (testing only — nothing survives a restart). Modes do not share data: see *Changing storage mode* |
| `Config.BlockedJobTypes` / `BlockedJobNames` | Who cannot open the app. Blocks by job **type** as well as name, so a new LEO job is blocked without a config edit |
| `Config.Advisory` | Who gets the threat advisory when a contract is placed on an officer, and whether it also raises an `sc-dispatch` entry |
| `Config.Limits` | Contract caps, payouts, cooldowns |
| `Config.Immunity` | Playtime and session floors that protect new players from being farmed |

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

**Placing a contract.** Search for a target, give a reason, choose exclusive
or competitive, and build the reward from any mix of cash, bank, dirty money,
items and weapons. Set how many payouts it has (how many times it can be
collected) — each payout is funded separately and all of it is escrowed up
front. Optionally set a kidnapping bonus (a percentage on top, plus any items
or weapons marked to pay only if the target is delivered alive), a buyout
price, and a stake the hitman puts up when they accept. The form shows what
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
bonus, a longer deadline — and lowering or removing the stake apply at once,
from Change reward and Extend deadline. Anything else — a shorter deadline,
giving back the last payout, a new reason, switching between one hitman and
several, raising the stake (only while nobody holds it), cancelling — is
proposed in the app and happens only if the other side agrees; a proposal
nobody answers lapses after `Config.Amendments.ProposalExpirySeconds`.

**Taking one.** Accept from the board, anonymously if you like. More hitmen
may accept than there are payouts; the first to fulfil are paid. If the
contract carries a stake, you put it up when you accept — walk away and the
client keeps it. The accept dialog says how long is left, and a staked
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

**Finishing it.** Kill the target, tap **Verify kill** and photograph the
body for the baseline. On `'server'` storage the app opens its own
viewfinder over the screen, showing the phone's rear camera: point it at the
body and tap **Take photo** (or **Cancel**). On `'host'` storage lb-phone's
own camera opens instead. With `sc-ambulance`, downing them is not the kill:
they are in last stand, and you have to finish them. The kill is credited to
whoever landed a hit within `Config.Completion.DeathReportWindowMs` (30
seconds) of the death, and bleeding out takes minutes, so a target left to
bleed out pays nobody. For `Config.Completion.ProofWindowSeconds` (60
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
many tokens are asked for. Or take them alive to the client and hold them there
for thirty seconds for baseline plus bonus.

**The kill photo.** The photo is the client's alone, and they get to see it
once. Nothing of it stays on the hitman's phone: on `'server'` storage the
photo never touches lb-phone's gallery or image host and the app lets go of
it the moment it is sent; on `'host'` storage the camera never saves it to
their gallery and their page is never sent the link. Either way their Ledger
row has no photo. The client is told it is waiting under Ledger. Their row
there has a **View photo** button, and tapping it opens the photo full-screen
with **Save to Photos** and **Delete**. Save to Photos puts it in the phone's
own Photos app (how, on `'server'` storage, is under *No image host?* below);
anything else deletes it, including closing it another way, such as
switching tab. Afterwards the row says which happened. Reading the Ledger
does not count as a view; only tapping the button does.

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
   the app no upload or gallery save.

`/ch-diag` says which: the address it serves photos from (or why there is
none), whether lb-phone's `UploadWhitelistedHostnames` / `Domains` take it,
and how many photos are on disk, kept in the app and served to phones, and
how much space they take.

**Counter-play.** A target can see the price on their head and buy it out.
Players the app is closed to — law enforcement and EMS — do the same with
`/cleanse` (lists what is on them) and `/cleanse <id>` (buys one out). Either
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

**Putting a hit on a cop.** Allowed, and loud. Every officer online is advised when the
contract is posted and again on each acceptance, with a running count, on
their phone and in dispatch. Both the creator and the hitman are warned first,
and the listing is flagged. Nobody puts a hit on a cop by accident. The dispatch entry
is closed when the contract ends. An officer is an officer by every job they
hold (`qbx_core` multi-job, `sc-multijob`): switching to a second job for the
evening neither opens the app to them nor takes them off the protected list.
A player barred by a job they hold but are not working is told which one on
their phone, since a department boss can hire somebody through the MDT
without asking them; quitting it from their job menu gives the app back.

---

## What stops it being abused

The full reasoning is in `../docs/hitman-app-spec.md` (in the repository) §14. In short:

- **Money cannot be duplicated.** Every escrow line settles at most once,
  guarded by a compare-and-set. Every release path shares one function.
- **Money cannot be destroyed.** A payout that cannot be delivered — full
  inventory, player offline — stays owed and is delivered on their next
  login, never dropped. A contract the server went down while placing (its
  reward taken, the contract itself never stored) has its reward handed back
  to the client at the next start, once, and nobody else is told it existed.
- **Identity is never taken from a payload.** Every handler resolves the
  acting player from the connection. Citizen ids never reach a client;
  searches and threads use expiring per-viewer handles.
- **A kill has to be real.** Death is attributed from damage the server
  observed, corroborated against the medical state. A downed player is not a
  kill, and a revive more than `ProofWindowSeconds` (60 s) after the death
  voids a pending claim.
- **A delivery has to be real.** The target must be alive, conscious and
  restrained or in your vehicle, checked on every tick of the countdown.
- **Anonymity is enforced by omission.** An anonymous party's identity is
  never put in the payload, so there is nothing to find client-side. An
  anonymous client's contract stays on the board while they are offline, and
  nothing a hitman can press says whether they are in the city.
- **New players are protected.** Playtime and session floors, post-respawn
  immunity, per-target contract caps and re-listing cooldowns. A login event
  never restarts a session that is already running, so the session floor
  cannot be renewed on demand, and a client's limits and waits count across
  every character on their licence.

---

## Staff commands

All work from the server console. In game they need the `crimson.admin` ACE
(`add_ace group.admin crimson.admin allow`). `Config.Admin.ExtraAces` also opens
the read-only ones (`ch-diag`, `ch-timeline`, `ch-stuck`, `ch-contracts`); `ch-void` and
`ch-settle` always need `crimson.admin` itself, and `ch-whois` `crimson.identity`.

The `<contract>` the commands take is the contract's id. Players see it as the
**Ref** at the foot of each card on their Mine and On Me tabs and on each Ledger
entry, and `/ch-contracts` lists it for any player.

| Command | What it does |
|---|---|
| `/ch-diag [player id]` | Why the app is not showing something: runs the app's own reads as that player and says what each answered, plus the last faults their phone reported |
| `/ch-contracts <player id\|citizen id>` | A player's contracts, newest first, closed ones included while they are kept: each id, its state, their role and the target. Lists the ids for `/ch-timeline`, `/ch-void` and `/ch-whois`. Contracts they placed or took anonymously are left out unless you also hold `crimson.identity` |
| `/ch-timeline <contract>` | One contract's state, escrow lines and audit trail |
| `/ch-whois <contract>` | Who is really behind an anonymous creator or hitman. Needs `crimson.identity`, a separate ACE |
| `/ch-void <contract> [reason]` | Close a contract and return its escrow to the creator. Any kill photo from it that the creator has not saved to their phone is deleted, including one kept for them in the app |
| `/ch-stuck` | Escrow lines that were mid-payment when the server stopped, including one being handed back from a contract that was never placed. Who each was paying is shown as a role (the client, an operative) unless you also hold `crimson.identity`. Also lists held lines of a contract that was never placed which do not say whose they are (written by an older version) |
| `/ch-settle <line> pay\|return [citizenid]` | Finish one of those by hand. `pay` goes to whom the interrupted payment was for; `return` goes to whoever put the line up, so a hitman's stake goes back to that hitman. A line that does not say whose it is needs `return <citizenid>` once you know who put it up; the citizen id is refused on any other line. A player who is offline gets it at their next login, and the command says so |
| `/hitmanadmin timers` | Test servers: bring every wait and cooldown forward. Deadlines are only ever moved later, never earlier. `crimson.admin` itself only — the extra ACEs do not open it — and audited |

Faults the phone page hits are reported to the server, printed to the console
and kept for `/ch-diag`; `Config.Debug = true` adds each one's full stack trace.
The page log `/ch-diag` asks a player's phone for is printed whatever Debug
says, once, and only within thirty seconds of being asked for.

The staff webhook is optional and is set in `server.cfg`, never in
`config.lua`, which every player's game downloads:

```
set crimson_hitman_webhook "https://discord.com/api/webhooks/..."
```

Use `set`, never `setr`: `setr` sends the value to every player too. It
mirrors financial movements and refused attempts, without identities, as one
message per audit flush rather than one per row, and backs off when Discord
says to. An older `config.lua` that still sets `Config.Audit.Webhook` gets a
warning at startup and the URL is not used: it has already been sent to
every player, so regenerate it in Discord and move the new one to
`server.cfg`.

On the phone, tapping the build line at the bottom of the Ledger tab five times
opens a diagnostics panel showing the page's recent requests and faults.

---

## Testing

The suite runs the real server modules against a stubbed FiveM runtime, so it
can be run anywhere Lua is installed:

```bash
sh crimson-hitman/tests/all.sh    # everything
CH_SUITES=journeys_spec lua crimson-hitman/tests/run.lua   # one area, in seconds
```

Five kinds of check, because each catches what the others cannot:

- **Server suite** (about 2,200 tests) — escrow arithmetic, the state machine,
  every payout and refund path, whole player journeys, every action against
  every contract state, deliberate exploit attempts, storage conformance
  across all three backends, and randomised simulations asserting that no
  sequence of operations creates or destroys value.
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
  280 to 414px, measuring tap targets, clipping and the tab bar. Skipped where
  Playwright is not installed.

**What it cannot prove:** behaviour against the real `ox_inventory`,
`lb-phone` and `qbx_core` builds. Work through `../docs/in-game-checklist.md` (in the repository, next to this resource folder) on
a test server before going live.
