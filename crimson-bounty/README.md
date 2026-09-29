# Crimson Bounty System

A criminal contract board for **QBox**, delivered as a custom **lb-phone** app.
Red and black, criminal-only, and built so the money cannot go missing.

Built against this server's actual stack: `qbx_core`, `ox_inventory`,
lb-phone 2.8.0, the 17mov character system, `sc-police`, `sc-ambulance`,
`sc-dispatch` and `sc-blackmarket`.

---

## Install

1. Drop `crimson-bounty` into your resources folder.
2. Add `ensure crimson-bounty` to `server.cfg`, **after** `qbx_core`,
   `ox_inventory` and `lb-phone`.
3. Open `config/config.lua` and check the sections marked below.
4. Restart. The console prints `[crimson-bounty] started in <mode> mode`,
   plus a warning for any configuration that will surprise you later.

The config ships in `json` mode: everything lives in files under
`crimson-bounty/data/`, which is what to back up. In `mysql` mode the tables
are created automatically on first start. Nothing to import either way.

### Configuration worth reading before you start

| Setting | Why it matters |
|---|---|
| `Config.Database.Mode` | `json` (as shipped; no database at all), `mysql` (oxmysql), `memory` (testing only — nothing survives a restart) |
| `Config.BlockedJobTypes` / `BlockedJobNames` | Who cannot open the app. Blocks by job **type** as well as name, so a new LEO job is blocked without a config edit |
| `Config.Advisory` | Who gets the threat advisory when a contract is placed on an officer, and whether it also raises an `sc-dispatch` entry |
| `Config.Payout.AllowConversion` | Leave **off**. See "Dirty money" below |
| `Config.Limits` | Contract caps, payout slots, cooldowns |
| `Config.Immunity` | Playtime and session floors that protect new players from being farmed |

### Dirty money

`sc-blackmarket` prices dirty money at `0.85`, which makes it worth about
**18% more** than clean money there. Paying a bounty out as dirty money at
face value would turn every contract into a risk-free laundering rail, so:

- Escrow pays out in **exactly the sources it holds**. Cash in, cash out.
- Conversion is a separate, opt-in step (`Config.Payout.AllowConversion`),
  and when enabled it converts at `0.85` — matching your black market, so
  converting is value-neutral rather than profitable.

---

## How it plays

**Placing a contract.** Search for a target, give a reason, choose exclusive
or competitive, and build the reward from any mix of cash, bank, dirty money,
items and weapons. Set how many times it can be collected — each collection
is funded separately and all of it is escrowed up front. Optionally set a
kidnapping bonus, a buyout price, and a failure penalty.

**Changing what it pays.** While nobody is hunting it, the client can add to
the reward or take part of it back — tick the lines to return and they come
home as the same property, the same weapon with the same serial. A slot's
baseline cannot be emptied, because a collection that pays nothing is not a
contract. The moment somebody accepts, the client can only add to it on their
own: the hunter took it as written, and escrow exists so it cannot be pulled
out from under them. Anything else — a shorter deadline, giving back the last
payout, cancelling — is proposed in the app and happens only if the other side
agrees.

**Taking one.** Accept from the board, anonymously if you like. More hunters
may accept than there are payouts; the first to fulfil are paid. If the
contract carries a penalty, you stake it when you accept — walk away and the
client keeps it. The accept dialog says how long is left, and a staked
contract with less than `Config.Penalty.MinWindowMinutes` to go cannot be
taken; if the stake or the deadline changed while you were looking at it, the
acceptance is refused and the board refreshes rather than taking a stake on
terms you were not shown. You can take it up again later, staking again; the wait
between payouts on one contract (`Config.Limits.SlotCooldownSeconds`) carries
over, so walking away is not a way round it. Where the server charges for
hunter anonymity and you cannot cover it, the acceptance is refused rather
than made under your name. An exclusive contract you hold without going near
the target for `Config.Limits.ExclusiveIdleReleaseSeconds` (counted only while
the client and the target are both in the city) goes back on the board with
your stake returned, and is not yours to take again. So does one you hold
near the target without ever making an attempt on them — no hit landed, no
handover armed — for `Config.Limits.ExclusiveAttemptWindowSeconds`. The
deadline pauses the same way. Both follow the target alone when the client is anonymous, because
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
bleed out pays nobody. A revive before you photograph them cancels it, once
they have stayed up for a few seconds or somebody has put them down again,
and a kill in the protection a revive gives does not pay. A defibrillator that only brings them
back to last stand does not, even if they are hit while it takes effect, but
the photograph needs them dead: the app says they are still down, and
finishing them is a new kill with its own photograph. A hit counts once the
server sees the damage it did, which reaches it a moment after the shot, and
only on the target's own body: a round into their car is not a hit on them.
Where the target's game says who damaged them, that is who the damage goes to.
sc-ambulance usually clears that within a tenth of a second, so the target's
client also tells the server who hit them, how many times, and what their
health and armour read just after, as the hits land. That reading ties each
report to the damage the server saw: a hunter is credited only with damage
the target's report on them covers, down to the reading it gave. When hunters
have hits waiting on the same damage, the server waits for the target's word
on every one of them, up to about a third of a second (longer on a slow
connection): the damage goes to the one hunter the target names; if it names
two, or nobody in that time, it counts for neither. A player whose game runs
this resource (every player's does, from when it starts) is held to that word
even when only one hunter is shooting, so damage the target never reports,
such as a fall, an NPC or a last-stand bleed, is nobody's. A hit another
resource (an anti-cheat) cancels is never counted.
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
side can pay an informant to unmask one hunter. Creator and hunters can
message or call each other through the app without either learning who the
other is (`Config.Relay`; switching it off removes messaging and calls
entirely). A call to an anonymous party asks them to call back rather than
ringing them, since a phone that rings only when its owner is in the city
would say whether they are.

**Hunting a cop.** Allowed, and loud. Every officer online is advised when the
contract is posted and again on each acceptance, with a running count, on
their phone and in dispatch. Both the creator and the hunter are warned first,
and the listing is flagged. Nobody hunts a cop by accident. The dispatch entry
is closed when the contract ends. An officer is an officer by every job they
hold (`qbx_core` multi-job, `sc-multijob`): switching to a second job for the
evening neither opens the app to them nor takes them off the protected list.
A player barred by a job they hold but are not working is told which one on
their phone, since a department boss can hire somebody through the MDT
without asking them; quitting it from their job menu gives the app back.

---

## What stops it being abused

The full reasoning is in `../docs/bounty-hunter-app-spec.md` (in the repository) §14. In short:

- **Money cannot be duplicated.** Every escrow line settles at most once,
  guarded by a compare-and-set. Every release path shares one function.
- **Money cannot be destroyed.** A payout that cannot be delivered — full
  inventory, player offline — stays owed and is delivered on their next
  login, never dropped.
- **Identity is never taken from a payload.** Every handler resolves the
  acting player from the connection. Citizen ids never reach a client;
  searches and threads use expiring per-viewer handles.
- **A kill has to be real.** Death is attributed from damage the server
  observed, corroborated against the medical state. A downed player is not a
  kill, and a revive voids a pending claim.
- **A delivery has to be real.** The target must be alive, conscious and
  restrained or in your vehicle, checked on every tick of the countdown.
- **Anonymity is enforced by omission.** An anonymous party's identity is
  never put in the payload, so there is nothing to find client-side. An
  anonymous client's contract stays on the board while they are offline, and
  nothing a hunter can press says whether they are in the city.
- **New players are protected.** Playtime and session floors, post-respawn
  immunity, per-target contract caps and re-listing cooldowns. A login event
  never restarts a session that is already running, so the session floor
  cannot be renewed on demand, and a client's limits and waits count across
  every character on their licence.

---

## Staff commands

All work from the server console. In game they need the `crimson.admin` ACE
(`add_ace group.admin crimson.admin allow`). `Config.Admin.ExtraAces` also opens
the read-only ones (`cb-diag`, `cb-timeline`, `cb-stuck`); `cb-void` and
`cb-settle` always need `crimson.admin` itself, and `cb-whois` `crimson.identity`.

| Command | What it does |
|---|---|
| `/cb-diag [player id]` | Why the app is not showing something: runs the app's own reads as that player and says what each answered, plus the last faults their phone reported |
| `/cb-timeline <contract>` | One contract's state, escrow lines and audit trail |
| `/cb-whois <contract>` | Who is really behind an anonymous creator or hunter. Needs `crimson.identity`, a separate ACE |
| `/cb-void <contract> [reason]` | Close a contract and return its escrow to the creator |
| `/cb-stuck` | Escrow lines that were mid-payment when the server stopped. Who each was paying is shown as a role (the client, an operative) unless you also hold `crimson.identity` |
| `/cb-settle <line> pay\|return` | Finish one of those by hand. `pay` goes to whom the interrupted payment was for; `return` goes to whoever put the line up, so a hunter's stake goes back to that hunter. A player who is offline gets it at their next login, and the command says so |
| `/bountyadmin timers` | Test servers: bring every wait and cooldown forward. Deadlines are only ever moved later, never earlier. `crimson.admin` itself only — the extra ACEs do not open it — and audited |

Faults the phone page hits are reported to the server, printed to the console
and kept for `/cb-diag`; `Config.Debug = true` adds each one's full stack trace.
The page log `/cb-diag` asks a player's phone for is printed whatever Debug
says, once, and only within thirty seconds of being asked for. The staff webhook (`Config.Audit.Webhook`) sends one message per audit
flush rather than one per row, and backs off when Discord says to.
On the phone, tapping the build line at the bottom of the Ledger tab five times
opens a diagnostics panel showing the page's recent requests and faults.

---

## Testing

The suite runs the real server modules against a stubbed FiveM runtime, so it
can be run anywhere Lua is installed:

```bash
sh crimson-bounty/tests/all.sh    # everything
CB_SUITES=journeys_spec lua crimson-bounty/tests/run.lua   # one area, in seconds
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
