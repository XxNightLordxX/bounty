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

Database tables are created automatically on first start in `mysql` mode.
Nothing to import.

### Configuration worth reading before you start

| Setting | Why it matters |
|---|---|
| `Config.Database.Mode` | `mysql` (default), `json` (no database at all), `memory` (testing only — nothing survives a restart) |
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

**Taking one.** Accept from the board, anonymously if you like. More hunters
may accept than there are payouts; the first to fulfil are paid. If the
contract carries a penalty, you stake it when you accept — walk away and the
client keeps it.

**Finishing it.** Kill the target and photograph the body through the app's
camera for the baseline. Or take them alive to the client and hold them there
for thirty seconds for baseline plus bonus.

**Counter-play.** A target can see the price on their head and buy it out.
Either side can pay an informant to unmask one hunter. Creator and hunters can
message or call each other through the app without either learning who the
other is.

**Hunting a cop.** Allowed, and loud. Every officer online is advised when the
contract is posted and again on each acceptance, with a running count, on
their phone and in dispatch. Both the creator and the hunter are warned first,
and the listing is flagged. Nobody hunts a cop by accident.

---

## What stops it being abused

The full reasoning is in `docs/bounty-hunter-app-spec.md` §14. In short:

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
  never put in the payload, so there is nothing to find client-side.
- **New players are protected.** Playtime and session floors, post-respawn
  immunity, per-target contract caps and re-listing cooldowns.

---

## Testing

The suite runs the real server modules against a stubbed FiveM runtime, so it
can be run anywhere Lua is installed:

```bash
sh crimson-bounty/tests/all.sh    # everything
```

Three kinds of check, because each catches what the others cannot:

- **Server suite** (278 tests) — escrow arithmetic, the state machine, every
  payout and refund path, deliberate exploit attempts, storage conformance
  across all three backends, and a randomised simulation asserting that no
  sequence of operations creates or destroys value.
- **Static checks** — rules no unit test can see: no SQL built by
  concatenation, no handler reading an identity from a payload, every module
  the resource loader asks for exists, every event name agrees across UI,
  client and server, every config key is actually read, and the MySQL schema
  can hold every field the code writes.
- **UI suite** — the real `ui/app.js` driven against a scripted server
  through a minimal DOM. This exists because the two worst bugs in the whole
  build were in the app and invisible to Lua tests: a form that could never
  submit a valid contract, and an open that refreshed itself into a storm.

**What it cannot prove:** behaviour against the real `ox_inventory`,
`lb-phone` and `qbx_core` builds, or how the UI renders on an actual phone.
Work through `docs/in-game-checklist.md` on a test server before going live.
