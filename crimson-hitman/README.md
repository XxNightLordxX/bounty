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
`crimson-hitman/data/`, which is what to back up. In `mysql` mode the tables
are created automatically on first start. Nothing to import either way.

### Configuration worth reading before you start

| Setting | Why it matters |
|---|---|
| `Config.Completion.ExtraPhotoHosts` | Kill photos are accepted only from image hosts lb-phone itself allows uploads from, plus these. Ships with Fivemanage (`fivemanage.com`, `fmfile.com`), lb-phone's default uploader. If `/ch-diag` shows `photo hosts: 0`, or kill photos are refused with "not on this server's allow list", add your phone's upload host here (a bare domain, no `https://`). lb-phone's camera upload must work first |
| `Config.Database.Mode` | `json` (as shipped; no database at all), `mysql` (oxmysql), `memory` (testing only — nothing survives a restart) |
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

**Finishing it.** Kill the target and photograph the body through the app's
camera for the baseline. With `sc-ambulance`, downing them is not the kill:
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
| `/ch-void <contract> [reason]` | Close a contract and return its escrow to the creator |
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

- **Server suite** (about 1,870 tests) — escrow arithmetic, the state machine,
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
