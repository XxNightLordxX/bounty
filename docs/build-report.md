# Crimson Bounty System — build report

Where the work got to, what was found along the way, and what still needs
your hands. Written for you to read cold.

---

## What exists

A complete FiveM resource at `crimson-bounty/`, built against your actual
stack — `qbx_core`, `ox_inventory`, lb-phone 2.8.0, the 17mov character
system, `sc-police`, `sc-ambulance`, `sc-dispatch`, `sc-blackmarket` and
`MugShotBase64` — plus three documents:

| | |
|---|---|
| `docs/bounty-hunter-app-spec.md` | The specification, consolidated from your three drafts and extended as decisions were made |
| `docs/implementation-plan.md` | The environment facts read from your uploads, and the decisions taken |
| `docs/in-game-checklist.md` | What to test on a live server, which no automated check can cover |
| `crimson-bounty/README.md` | Install and configuration |

## What it does

Everything you asked for, and the features are in the spec rather than
repeated here. The parts worth knowing about because they cost the most
thought:

- **Payout slots.** A contract can be collected several times, each
  collection funded separately and escrowed up front. More hunters may
  accept than there are payouts; the first to fulfil are paid.
- **The law enforcement advisory.** Hunting a cop is allowed and loud. Every
  officer online is told when the contract is posted and again on each
  acceptance, with a running count, on their phone and in dispatch. Both
  sides are warned first. The creator is never named — that is police work.
- **Dead or alive.** A kill pays the baseline; a live delivery pays baseline
  plus bonus. The bonus is real escrow taken at creation, not a promise.
- **Masked relay.** Creator and hunters can talk without either learning who
  the other is, addressed by per-viewer handles rather than identities.
- **Amendments.** Improvements apply at once; anything that could disadvantage
  the other side needs both sides to agree. The target is never amendable.
- **The failure penalty is staked**, not invoiced — a penalty charged after a
  failure is one the hunter can walk away from.
- **Progression.** Completing a contract feeds `sc-blackmarket` trust, so this
  is part of the criminal economy you already have rather than beside it.

## Decisions taken on your behalf

You said to use my judgement. These are the ones that were mine:

1. **Dirty-money payouts are off by default.** `sc-blackmarket` prices dirty
   money at 0.85, making it worth about 18% more than clean money there.
   Paying escrow out as dirty money at face value would have turned every
   contract into a risk-free laundering rail. Escrow pays out in the sources
   it holds; conversion is opt-in and value-neutral.
2. **The job blacklist blocks by type as well as name**, so a new LEO job is
   blocked without a config edit. Your server has eleven such jobs, not the
   five the original spec listed.
3. **Contracts on officers are allowed.** The advisory is what makes it fair.
4. **A proof window after a death.** Players respawn in seconds, and without
   it a hunter standing over the body loses the payout to the respawn button.
5. **A missing playtime source skips the new-player rule** rather than
   refusing everyone. See below for why that matters.

## How it was verified

```
sh crimson-bounty/tests/all.sh
```

- **301 server tests** — escrow arithmetic, the state machine, every payout
  and refund path, deliberate exploit attempts, storage conformance across
  all three backends, and a randomised simulation asserting that no sequence
  of operations creates or destroys value.
- **29 UI tests** — the real `ui/app.js` driven through a minimal DOM against
  a scripted server.
- **Static checks** — no SQL built by concatenation, no handler reading an
  identity from a payload, every module the resource loader asks for exists,
  every event name agrees across UI/client/server, every config key is read,
  the MySQL schema holds every field the code writes, no production read of a
  test-harness field, and no native browser dialogs.

Beyond that, **four completed rounds** of adversarial review by independent
agents, each finding verified or refuted by a second pass. A fifth round
could not run — the model capacity for it was unavailable, and four attempts
all failed with server errors — so that round is my own reading of the code
rather than an independent one. Treat it as weaker evidence than the four
before it.

Roughly seventy defects were found and fixed across those rounds. The ones
worth knowing about:

- The app **could not create a contract at all** — the form sent blank fields
  as zeroes and validation rejected them. Every unit test passed.
- **Every player was immune** to being targeted, because a check read a field
  only the test harness invented. No contract could be created, no payout
  claimed.
- Escrowed **weapons were destroyed** on every successful completion.
- A **money printer** in the penalty-reduction path.
- **Double refunds on MySQL**, from a stale write reverting a state change.
- The **kidnapping bonus paid nothing**.
- Six app actions **silently did nothing**, because FiveM's NUI never shows a
  native `confirm` or `prompt`.
- `weaponDamageEvent` was never wired, so **no elimination could ever pay**.

Each of those is now covered by a test that fails if the fix is reverted, and
several by a static check that catches the whole class.

## What I could not verify

No FiveM server runs in this environment, so nothing here has been run
in-game. What remains unproven:

- Behaviour against the real `ox_inventory`, `lb-phone` and `qbx_core` builds.
  Export names and shapes were read from your uploaded resources where they
  existed; `qbx_core`'s player lookup has a fallback because I could not read
  it.
- How the app looks and behaves on an actual phone.
- Performance under real player load.

`docs/in-game-checklist.md` covers exactly these. Work through it on a test
server before going live — particularly sections 3 to 6, which are the money
paths.

Given that every completed review round found something real, the honest
expectation is that a live server will find more. The audit log is there for
exactly that: `SELECT * FROM crimson_audit ORDER BY id DESC LIMIT 50` shows
every financial movement and every refused attempt, with the reason.

## What I would want you to look at

- **`Config.Immunity.PlaytimeProvider`** is nil, so the new-player rule falls
  back to QBox character metadata. If your build does not store `playtime`
  there, the rule is skipped and the console says so at startup. Point it at
  whatever your server uses.
- **`Config.Database.Mode`** defaults to `mysql`. Tables are created on first
  start.
- **`Config.Progression.Resource`** is `sc-blackmarket`. Trust per contract is
  10 for a kill and 20 for a live delivery — tune to taste.
- **The rate limits** in `Config.Cooldowns` are deliberately tight. If normal
  play feels throttled, that is the first place to look.
