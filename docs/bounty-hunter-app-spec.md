# Development Specification — Criminal Bounty Hunter App

**Target platform:** FiveM
**Framework:** QBox
**Phone integration:** lb-phone (custom app)
**Document status:** Consolidated requirements specification (pre-implementation)

---

## 1. Overview

A custom bounty hunter script for FiveM, integrated with **lb-phone** on the **QBox** framework. The system operates entirely through a custom phone application restricted exclusively to criminal players.

Core pillars:

- Real-time target tracking with live mugshots
- Flexible **"Dead or Alive"** contracts with dynamic field pivots
- Automated **escrow** of any mix of cash, bank funds, dirty money, crypto, items, and weapons
- **Multi-hunter competition** (exclusive vs. competitive assignment)
- **Anonymity** systems for both creators and hunters
- **Dynamic target counter-play** (bailout, counter-intelligence)

---

## 2. Job & Access Restrictions

| Rule | Requirement |
|---|---|
| Criminal only | The app is visible and accessible **only** to players without whitelisted emergency or legal jobs. |
| Blacklisted jobs | `police`, `bcso`, `fib`, `fire`, `ambulance` |
| Enforcement scope | Blacklisted players may not access, view, or interact with the application in any way — including listings, notifications, and contract actions. |

> The blacklist must be enforced **server-side** on every event, not only by hiding the app icon client-side.

---

## 3. Bounty Creation

When a player opens the app to place a bounty, they complete the following configuration steps.

### 3.1 Target Selection
Choose an **online** player to target.

### 3.2 Contract Reason
Provide a free-text reason for the bounty.

### 3.3 Assignment Mode

| Mode | Behavior |
|---|---|
| **Exclusive** | Only one hunter may hold the contract at a time. |
| **Competitive** | Multiple hunters may accept simultaneously; the contract pays out strictly to **whoever fulfills the conditions first**. |

### 3.4 "Dead or Alive" Reward Selection

Contracts natively support **dynamic field pivots** — the style of completion is not locked in at creation time.

**Baseline escrow reward — fully composable.** The creator builds the reward from any combination of the sources below. Every source is individually selectable, none are mutually exclusive, and a single contract may use one, several, or all of them at once:

| Source | Selection |
|---|---|
| Cash (on hand) | Any amount up to the creator's carried cash |
| Bank balance | Any amount up to the creator's bank balance |
| Dirty money | Any amount up to the creator's dirty money holdings (item or account, per server setup) |
| Crypto | Any amount up to the creator's crypto balance, if the server runs one |
| Inventory items | Any items currently held, with per-item quantity |
| Weapons | Any weapons currently held, carrying their serial and attachments |

The app presents these as a single reward builder: the creator picks sources, sets amounts/quantities, and sees a running **total reward composition** before submitting. At least one source must be non-empty for the contract to be valid.

**Kidnapping Bonus Multiplier.** The creator configures a bonus paid on live delivery, using the same fully composable model:

- A **percentage multiplier** applied to any or all of the monetary sources in the baseline (e.g., +50% cash, +25% dirty money), set per source or globally, and/or
- **Additional items/weapons** held only for the kidnapping outcome.

**Hunter choice.** The hunter decides on the fly how to handle the target based on opportunity — eliminate for the baseline, or kidnap for baseline + bonus.

### 3.5 Escrow Automation

On submission, **all baseline and potential bonus** currency and items are automatically confiscated from the creator's inventory/accounts and held securely in escrow by the script until the contract resolves.

Required behavior:

- The reward builder is validated **server-side twice** — once when it is opened (the client is sent only what the player actually holds) and again on submit, to confirm nothing changed in between. A submitted source the player no longer holds rejects the whole contract; it is never silently reduced.
- Confiscation and the writing of the escrow record happen as a **single atomic operation** — a database transaction in `mysql` mode, an atomic file swap in `json` mode (§10). If any part fails, nothing is taken.
- Weapons are stored as a **full metadata snapshot** (serial, attachments, ammo, durability), never as a slot reference.

See §9 for the binding rules these follow from.

### 3.6 Failure Penalty Configuration

An optional, config-backed setting allowing the creator to enforce a **financial penalty** (a specific amount of money) if an accepted hunter fails to complete an **exclusive** contract within a designated time parameter.

The penalty timer **pauses** whenever the creator or target is offline (§7.1), so that logging out cannot be used to run out a hunter's clock — or, from the creator's side, to dodge the refund that follows expiry.

---

## 4. Privacy & Identity (Anonymous Mode)

An anonymity system governed by server configuration.

- **Creator Anonymity** — when placing a bounty, the creator may toggle Anonymous Mode; their name is hidden from the public bounty listing.
- **Hunter Anonymity** — when accepting a contract, the hunter may toggle Anonymous Mode; the creator cannot see who accepted.
- **Config Controls** — anonymity is **free by default**. `config.lua` must expose options to enable an entry fee (flat cash or bank fee), configurable **independently** for creators and hunters, charged before anonymity is granted.

---

## 5. Target Interaction — "Bounty Cleanse" (Self-Bailout)

- **Creator Choice** — when placing the bounty, the creator toggles **Bailout Allowed** on or off. If on, they input the exact cash amount required for the target to buy their freedom.
- **The Buyout** — if enabled, a target who sees an active price on their head through the app may pay that exact creator-specified premium to **anonymously** buy out and instantly delete the contract.
- **Payout** — the contract closes immediately. The original creator receives **all** original escrowed items/cash back, **plus** the cash premium, paid directly from the target's bank or pocket.
- **Refund path** — the return of escrow on bailout uses the **same shared release routine** as expiry refunds and payouts (§9.2), so no source type can be dropped on one path and honored on another.

> Target visibility of their own contract is itself config-gated (see §7.3, Paranoid Alert).

---

## 6. Additional Immersive Features

### 6.1 Counter-Intelligence — Purchasable Hunter Identity
A bounty creator or target being hunted anonymously may pay a heavy premium through the app to **"Buy Informant Data."** This unmasks the name / citizen ID of **one randomly selected** hunter currently tracking them.

*Design intent:* counters Anonymous Mode and creates counter-intelligence gameplay where targets can turn around and hunt their own hunters.

### 6.2 Blood Money Laundering — Crypto / Dirty Money Payouts
A config option allowing bounty payouts to be distributed via the server's **dirty money item** or a specific **crypto currency** rather than clean bank money.

*Design intent:* fits the criminal aesthetic and pushes players into existing money-laundering mechanics.

### 6.3 Proof of Death Archive — The Hitman's Ledger
An app tab (**History / Ledger**) storing the **past 10 completed contracts**. Opening a completed contract shows the verification photo taken by the hitman.

*Design intent:* persistent progression and a "trophy room" of successful hits and survivals with a minimal database footprint.

---

## 7. System Logic & Completion Tracking

### 7.1 Online Presence Dependency
A bounty appears on the public bounty list **only if both the creator and the target are currently online**. If either logs out, the bounty is temporarily **hidden** from active listings until both return.

Hiding is a **display filter only** — never a state change. The contract row stays active, its escrow stays intact, and its failure-penalty timer is **paused** for the duration. Nothing about a player being offline may alter contract state.

### 7.2 Real-Time Visuals
Each bounty listing features a dynamic, **real-time mugshot** of the target. If the target changes outfit or appearance, the image in the app updates **instantly**.

The refresh is **event-driven** — hooked to appearance/outfit change events, updating a cached mugshot at that moment. It must not be implemented as a polling interval that re-renders every listed bounty; on a populated server that is the dominant frame cost of the whole script.

### 7.3 Automated lb-phone Notifications

| Event | Message | Notes |
|---|---|---|
| Creator Alert | "Your contract on [Target] has been accepted by an operative." | Respects hunter anonymity. |
| Target Paranoid Alert | "You feel eyes on you. A price has been put on your head." | Toggleable in config. |
| Completion Alert | "Contract Fulfilled. Verification photo attached. Check your archives." | Sent to creator with photo. |

### 7.4 Contract Acceptance & Payout Security

A hunter must **explicitly accept** the contract via the phone app to participate.

**Acceptance** is rate-limited server-side per citizen id (§9.5), and on a **competitive** contract the first valid completion takes an **atomic single-winner lock** before any funds move — every other hunter receives a clean "contract closed" result and no partial payout.

#### Elimination Fulfillment
- Payout triggers **only** if the target is killed specifically by a player who accepted the bounty.
- To claim, the hunter must stand near the dead target and take a **verification photo** using the lb-phone camera.
- The script confirms completion only if the target player's entity is within a short radius of the hunter at capture time.
- On verification: the photo is transmitted instantly to the creator's app as proof of death, **baseline rewards** are released, and the contract closes for all hunters.
- **No payout** if the target dies by local elements, suicide, or a player who did not accept the contract.

Attribution and photo binding:

- Killer, weapon, and timestamp are **recorded into the contract's pending-completion state at the moment of death** — never queried later at photo time, where a second player's damage or a respawn can overwrite the answer.
- The verification photo must be captured through a flow **the script opened for a specific contract**. On submit, the server validates **contract id, hunter id, target ped distance, and an unexpired capture token together**; a photo missing any of the four is rejected. An arbitrary photo taken near a corpse never satisfies the check.

#### Kidnapping Fulfillment
- The contractor must bring the target **alive** to the physical location of the bounty creator.
- The script must detect a **30-second continuous proximity countdown** between contractor, target, and creator.
- On success: **baseline + bonus** escrowed rewards are released, and the contract closes for all hunters.
- A short **grace period (config-backed, 2–3s default)** absorbs desync and doorways before the countdown resets; only a break exceeding the grace resets it.
- The hunter sees the live countdown and its grace state on screen, so a reset is never silent.

---

## 8. Configuration Surface (`config.lua`)

The following must be config-driven:

- Blacklisted jobs list
- Anonymous Mode fees — creator and hunter, independently (off by default)
- Failure penalty availability and time window for exclusive contracts
- Target Paranoid Alert on/off
- Target visibility of own contract (enables Bounty Cleanse)
- Reward sources enabled server-wide (cash / bank / dirty money / crypto / items / weapons) — any disabled source is hidden from the reward builder
- Per-source caps and a global maximum contract value
- Item/weapon blacklist (things that may never be escrowed)
- Default payout currency for percentage-based bonuses — clean bank / dirty money / crypto
- Informant Data premium cost
- Ledger history depth (default 10)
- Photo-verification proximity radius
- Kidnapping proximity radius, countdown duration (default 30s), and proximity grace period (default 2–3s)
- Per-action cooldowns (create / accept / bailout / informant purchase)
- Capture-token lifetime for photo verification
- `Config.Database.Mode` — `mysql` / `json` / `memory` (§10)
- JSON-mode write debounce interval
- Contract reason: maximum length and permitted character set

---

## 9. Binding Implementation Rules

These are requirements, not suggestions. Every one of them is referenced from the sections above.

### 9.1 Escrow is the single source of truth
Each contract has **one** escrow record enumerating every source and amount it holds. It is written in the same atomic operation that removes those funds and items from the creator (§10 defines that operation per persistence mode). Payout, refund, bailout, and penalty resolution all read from that record. No other part of the script independently computes what a contract is worth.

### 9.2 One shared release routine
Bailout return, expiry refund, failure-penalty resolution, and hunter payout all call a single `releaseEscrow(contractId, recipient, portion)` function. Adding a new reward source means touching one function, so no source can be honored on one path and dropped on another.

### 9.3 Refunds never destroy property
If the recipient's inventory is full or they are offline at release time, the escrow record **stays open in a pending state** and retries on their next login. Items are never dropped on the ground or deleted to force the transaction through.

### 9.4 Weapons are snapshots
Serial, attachments, ammo, and durability are serialized into the escrow record. Slot references are never stored.

### 9.5 Rate limiting
Contract creation, acceptance, bailout, and informant purchases each carry a server-side cooldown per citizen id. Cooldowns are config-backed.

### 9.6 Server authority
All escrow, payouts, job checks, kill attribution, proximity checks, and photo validation resolve server-side. Clients send intent only; they never assert outcomes. Every event handler re-checks the job blacklist (§2).

### 9.7 Atomic completion
Completion takes a lock on the contract before any funds move. A contract can transition to `completed` exactly once.

### 9.8 Financial audit log
Every escrow, payout, refund, bailout, and penalty is written to an admin-readable log with amounts, sources, both parties, and timestamp. This is the only way to adjudicate a player dispute after the fact.

### 9.9 Persistence footprint
Active contracts plus the last 10 completed contracts per player. Verification photos are stored as lb-phone image references, not blobs. Storage backend is selectable per §10 without changing any of these rules.

### 9.10 Contract state machine
`draft → active → accepted → (completed | bailed_out | expired | cancelled)`, with `hidden` as a display flag orthogonal to state (§7.1). No transition skips escrow resolution.

## 10. Persistence Modes (`Config.Database.Mode`)

Persistence is selectable so a server owner can run the script with **no SQL engine involved at all**.

| Mode | Storage | Durability | Intended use |
|---|---|---|---|
| `mysql` | `oxmysql`, auto-created tables | Full — survives restart and crash | Default, production |
| `json` | Flat files under the resource's `data/` directory | Full — survives restart | Production without a database |
| `memory` | In-process tables only | **None** — everything is lost on restart | Testing and development only |

### 10.1 A correction worth stating plainly

Turning the database off does **not** fix SQL injection — and leaving it on does not cause it. Injection comes from **building query strings out of user input**, nothing else. A script that writes

```lua
MySQL.query('SELECT * FROM bounties WHERE citizenid = "' .. citizenid .. '"')
```

is exploitable; the same script using a placeholder is not:

```lua
MySQL.query('SELECT * FROM bounties WHERE citizenid = ?', { citizenid })
```

So `Config.Database.Mode` exists because some owners genuinely do not want to run MySQL — not as a security control. **Regardless of mode**, these hold:

- Every query uses **parameterized placeholders**. String concatenation or `string.format` into SQL is forbidden, without exception.
- Table and column names are **never** taken from config or player input — they are literals in the source.
- All player-supplied text (the contract reason above all) is **length-capped, character-filtered, and escaped at the render boundary** before it reaches the app UI. This matters in every mode: `json` mode is immune to SQL injection but not to injection into the phone UI or into the JSON files themselves.
- No query is ever built from a value that arrived in a client event.

### 10.2 `json` mode requirements

- Writes are **atomic**: serialize to a temp file, `os.rename` over the target. A crash mid-write must never leave a truncated escrow file.
- Writes are **debounced and batched** (config-backed, default 5s), not one write per state change.
- Keys are sanitized before use as filenames or object keys — a citizen id is validated against a strict pattern, never trusted as a path fragment.
- On load, a malformed or unreadable data file **halts the resource with a clear console error** rather than starting with empty escrow. Silently starting fresh would delete every open contract's escrow.

### 10.3 `memory` mode requirements

Memory mode holds no durable escrow, so it must not be able to destroy player property:

- On resource stop and server shutdown, **all open escrow is released back to its creators** before the resource unloads.
- Creators who are offline at that moment cannot be refunded — therefore memory mode **refuses to escrow from a player who then logs out**: contracts are cancelled and refunded automatically when the creator disconnects.
- The Ledger (§6.3) is empty in this mode; the tab states that history is disabled.
- The console prints a **startup warning** that persistence is off and contracts will not survive a restart.

### 10.4 Mode-independent guarantees

- The escrow record (§9.1) has the same shape in all three modes; storage is behind one interface, so no game logic branches on the mode.
- Restart recovery (`mysql` and `json`): on startup, every contract in `accepted` state has its capture tokens invalidated and its failure-penalty timer resumed from stored elapsed time — never restarted from zero, which would silently extend a hunter's deadline.

---

## 11. Design Rationale

The rules in §9 exist for specific failure modes, recorded here so they are not "simplified away" during implementation:

| Rule | Failure it prevents |
|---|---|
| Single escrow record, single transaction | Item and money duplication — the bug that gets a script pulled from a server |
| Weapon metadata snapshot | Refunded weapons losing serials and attachments |
| Double server-side validation of the builder | Escrowing an item the player dropped mid-flow |
| Shared release routine | A source type honored on payout but dropped on refund |
| Escrow stays open on full inventory | Items deleted because a refund landed on a full bag |
| Attribution recorded at death | Kill credit overwritten between death and photo |
| Four-factor photo binding | Any photo near any corpse claiming any contract |
| Countdown grace period | Kidnappings failing to desync rather than to counter-play |
| Event-driven mugshots | Frame cost scaling with the number of listed bounties |
| Per-action rate limits | Spammed accepts probing anonymity or racing payout |
| Atomic single-winner lock | Two hunters paid for one contract |
| Hiding as display filter only | Logging out to dodge a penalty or void an escrow |
| Financial audit log | No way to adjudicate "the script ate my items" |
