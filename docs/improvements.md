# Crimson Bounty System — improvements to what exists

Not a feature list. Every item here sharpens something already built, and
each says why it matters and where it lives. Ordered by what I would do
first.

A short note on judgement: the things at the top are worth doing before the
script sees heavy use. The things at the bottom are worth doing if they ever
start to annoy you, and not before.

---

## 1. Worth doing before heavy use

### 1.1 Stop the full-table walks
`server/projection.lua` and `server/contracts.lua` both call
`Storage.allContracts()` and then filter in Lua. `Projection.mine`,
`accepted` and `onMe` each walk every contract the server has ever stored,
and `Contracts.canCreate` does it again on every creation.

On the `mysql` backend that is a `SELECT *` over the whole table per call,
plus a `readHunter` query per contract. It is fine at a hundred contracts and
unpleasant at ten thousand.

**Do:** add `Storage.contractsInvolving(cid)` and
`Storage.contractsNaming(cid)` to all three backends — indexed queries in
`mysql` (the indexes already exist), filtered loops in `memory` and `json` —
and have the projection and eligibility paths call those instead.

The storage conformance suite already runs one contract against every
backend, so the new methods get covered for free.

### 1.2 Serve mugshots by reference, not by value
`server/projection.lua` inlines the base64 headshot into **every row of every
page**, for every viewer. A 48 KB image across a 15-row listing is 700 KB per
`list` call, and the listing is fetched on every tab change.

**Do:** give each cached mugshot an id, send the id in the projection, and
add a handler that returns one image by id. The app caches by id, so a
board refresh re-sends nothing. `Config.Mugshot.MaxImageBytes` can then come
down further.

### 1.3 Shard the json store
`server/storage/json.lua` re-serialises and rewrites the entire store on
every financial write (`touch(true)`). With a few thousand contracts that is
a multi-megabyte write on every escrow movement.

**Do:** write one file per contract under `data/contracts/`, keep the index
in the main file, and flush only the contracts that changed. The
`MaxDirtyShardsPerFlush` idea from the original audit belongs here.

### 1.4 Tighten what a damage claim can be worth
`server/completion/death.lua` corroborates a claim against condition the
server observed, and credits the attacker with the **whole** observed drop.
The named-killer path (the victim's own game naming who killed them) is the
primary signal and is sound, but the fallback still means a hunter who lands
one shot during someone else's firefight can inherit a large delta.

**Do:** two things, both small. Sample condition for live targets on a
faster tick than the ten-second maintenance loop, so each delta is attributed
closer to the event that caused it. And when the victim names a killer,
require that killer to appear in the damage log rather than synthesising a
record for them — a named killer with no observed damage should be treated as
unattributed, not credited.

### 1.5 Give interrupted releases somewhere to go
On restart, `server/main.lua` returns an escrow line caught mid-release to
`held` and logs it for review. That is the right call — money stuck forever
is worse than a rare double-pay — but "logged for review" currently means a
console line and an audit row nobody is watching.

**Do:** add an admin command that lists interrupted releases and lets a
staff member settle or return each one deliberately. The audit row already
carries everything needed (`release_interrupted`, with the line id and
amount).

---

## 2. Existing features that are less finished than they look

### 2.1 The reward builder cannot offer items or weapons — **done**
The server has supported item and weapon escrow since the first commit —
validation, metadata snapshots, restoration, the lot — and it was tested. The
form did not expose it: `ui/app.js` collected cash, bank and dirty money only,
so nobody could put a weapon up as a bounty.

**Done.** `rewardOptions` now returns the creator's stackable items (aggregated
across inventory slots, weapons and currency excluded, blacklist applied) and
their weapons one at a time, each identified by its inventory slot and shown
with the last four characters of its serial so two of the same model can be
told apart. The Place form grows an item picker and a weapon picker per payout,
each staged reward removable, and the counts are checked against what is
already promised to the other payouts before anything is sent.

Four things came out of building it:

- **One weapon could be staged in two payouts.** Both lines snapshotted the
  same physical object; the take removed it once and then failed hunting for
  its twin, rolling the whole contract back. `Escrow.validate` now refuses a
  repeated inventory slot up front.
- **The per-payout limits multiply.** Five payouts × two portions × ten item
  stacks is 160 escrow rows for one contract, every one of them read on every
  release. `Config.Limits.MaxEscrowLines` bounds the total, and
  `Amendments.addEscrow` counts a top-up against what the contract already
  holds so it cannot be walked past one line at a time.
- **A weapon with no inventory slot was offerable** and could only ever be
  refused on submit. It is filtered out of the offer instead.
- **`app.init` was missing from the test harness.** Nothing had noticed,
  because the app only reached through `deps` once the reward builder needed
  it. Static check 11 now fails the build if `main.lua` initialises a module
  the harness does not.

### 2.2 Amendment negotiation is server-only
`server/amendments.lua` implements proposals, approvals, declines and expiry,
and it is well tested. There is no UI for any of it, and no handler that
returns the open proposals on a contract, so `Storage.readOpenAmendments` is
read only by the expiry sweep.

**Do:** add a read handler and a panel: open proposals with their diff, and
approve/decline buttons. The creator can already improve a contract from the
card; this is the other half.

### 2.3 Masked calls are checked for but never placed
`Comms.requestCall` verifies that the phone can suppress caller identity and
then notifies the other party that someone wants to talk. It never places a
call.

**Do:** either place the call through lb-phone with identity suppressed, or
drop `requestCall` and `Config.Relay.AllowMaskedCalls` and let the relay
threads be the whole of it. Half-built is the worst of the three.

### 2.4 The app never learns anything it did not ask for
`ui/app.js` refreshes on a `push` message that nothing sends — deliberately,
because refreshing on every reply was an exponential storm. So a creator is
not told in-app when a hunter accepts, and a hunter's card does not change
when the handover settles. The phone notification arrives; the open app does
not move.

**Do:** send a `push` from the server on the four state changes that matter
(accepted, settled, bailed out, expired), forwarded by the client as
`SendCustomAppMessage`. Debounce it in the app so several pushes in a second
cause one refresh.

### 2.5 The countdown fetches its grace state and shows none of it
`Kidnap.progress` returns `graceLeft` and `breaking`, the app polls it every
second, and `countdown()` renders neither. A hunter whose hold is slipping
has no idea until it fails.

**Do:** render the grace budget and the reason it is breaking
(`creator_too_far`, `not_coerced`) under the bar. The data is already on the
wire.

---

## 3. Robustness

### 3.1 Bailout should retry, not refund, when it loses a race
`Bailout.settle` refunds the premium if the contract resolved some other way
during the processing delay. Correct, but a contract that is merely mid-claim
resolves a moment later, and the target has to buy out again.

**Do:** distinguish "resolved" from "busy": on `LOCKED`, leave it queued and
try again on the next tick; refund only on a terminal state.

### 3.2 Re-read the photo host allowlist
`Photo.loadAllowedHosts` reads lb-phone's upload configuration once at boot.
An owner who changes upload provider has to restart this resource too, and
the failure mode is every verification photo being rejected.

**Do:** re-read it on the maintenance tick, and log when the set changes.

### 3.3 Expire by deadline, not by scanning
`ExpireContracts` walks every contract on every tick. Contracts carry
`deadline_at` already.

**Do:** keep an in-memory heap of the next few deadlines and only touch
storage when one comes due.

### 3.4 One place that knows a contract is over
Terminal transitions now go through `finalise`, which was the fix for stakes
being stranded. Two paths still call `Contracts.transition` to a terminal
state directly (`bailout`, admin void). They happen to be correct today
because they route through `resolve`.

**Do:** make `transition` refuse a terminal target unless it comes from
`resolve` or `claimSlot`, so the next path added cannot skip settlement. A
static check would also do it.

---

## 4. Operator experience

### 4.1 There are no admin commands
The audit log records everything, and nothing surfaces it in game. A staff
member handling "the script ate my gun" needs database access.

**Do:** add ACE-gated commands for the four things staff actually need:
show a contract's full timeline, void a contract with a full refund, list
interrupted releases (§1.5), and look up who is behind an anonymous party —
that last one logging its own access record, since the point of anonymity is
that looking is exceptional.

### 4.2 Nothing tells an operator the integrations are working
Optional integrations — `sc-ambulance`, `sc-dispatch`, `sc-blackmarket`,
`MugShotBase64` — are detected silently. If `sc-blackmarket` is renamed,
progression stops and nothing says so.

**Do:** print one startup line listing each optional integration and whether
it was found, and warn when a configured one is missing.

### 4.3 The schema has no migration path
`mysql.lua` creates tables if they do not exist. It cannot alter one. The
columns added during this build (`staker`, `owed_to`, `paused_since`, the
bailout queue) would be missing on a server that had run an earlier version.

**Do:** add an idempotent migration step that checks
`information_schema.columns` and adds anything absent. Not urgent now — there
is no earlier version in the wild — but it gets harder to add later.

---

## 5. Test coverage worth adding

The suite is strong on money and weak in three specific places:

1. **The mysql backend is never executed.** The harness stubs it. Everything
   proven about `mysql.lua` is proven by the schema conformance check and by
   reading. A docker MySQL in CI, running the same conformance suite, would
   close the largest remaining hole — and it is the backend that ships by
   default.
2. **The simulation never restarts.** `invariant_spec.lua` asserts value
   conservation across thousands of operations but never saves, reloads and
   continues. A restart in the middle of each seed would exercise the
   recovery path that currently has only hand-written tests.
3. **The UI suite does not cover the thread view or the countdown.** Both
   render from shapes the server sends, and both have been broken before.

---

## 6. Where the code and the spec still disagree

Four of the five are now resolved in the code; the fifth is resolved in the
spec, which is the other honest way to close a gap.

| Spec | Resolution |
|---|---|
| §6.1 informant requires recorded proximity | **Built.** The pool is hunters the condition sampler has actually seen within `Config.Informant.ProximityRadius` of the target, inside a window. A hunter who pressed accept and went to bed is no longer named, which is what turned the purchase into a roster dump. `RequireProximity = false` restores the old behaviour. |
| §14.25 maximum hold time, creator arrival clock | **Built.** The countdown was always bounded by the grace budget; the *retrying* was not, so a hunter whose client never turned up could re-arm in a loop and hold a target at no cost. `Config.Kidnap.RearmCooldownSeconds` bounds it, the creator is told the moment a handover starts, and the hunter is told why one failed. |
| §14.43 photo retention window | **Built.** `Config.Ledger.PhotoRetentionDays` drops the photo reference from ledger rows past the window, in every backend — one indexed UPDATE on mysql. The row stays, because the record is the point of the ledger; the photo of somebody's corpse does not. Zero keeps them forever. |
| §7.5 out-of-app buyout for officers | **Built.** `/cleanse` lists what is out on the caller and buys one out. Law enforcement and EMS are barred from the app by §2, so an officer had no way to reach the one mechanic a target is supposed to have. Not ACE-gated: it only ever acts on a contract naming the caller, and applies every check the app's button does. |
| §14.22 coarse target tracking | **Spec amended, not built.** This resource ships no tracking of any kind, and §14.22 now says so at the top. Every safeguard that section lists exists to stop a feature that hands a player another player's position from becoming a cheat feed, and the safest version is the one that does not exist. §1's tracking pillar is served by the informant purchase and by nothing else. A server that wants it should build it to that section. |

---

## 7. Still open

Nothing from sections 1 to 5 remains. What is deliberately *not* here:

- **The storage conformance suite against a real MySQL.** The backend is now
  executed rather than only read — `tests/harness/mysql_exec.lua` runs the
  statement shapes this resource issues and raises on one it cannot, and the
  whole conformance suite runs against it. That is not the same as a real
  database: it does not prove MySQL's own behaviour around collation,
  concurrent writes or transaction isolation. A docker MySQL in CI would
  close the rest, and it has not been written because it could not be run
  here, and a CI job that has never been executed is a CI job that is broken.
- **Anything requiring a live server.** `docs/in-game-checklist.md` is the
  list of what only a running FiveM server can prove.
