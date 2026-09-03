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

### 3.5 Payout Slots — multiple collections per contract

A contract is not limited to paying out once. The creator sets **how many times it can be collected**, and funds a **separate reward set for each collection**.

- `payoutSlots` is chosen at creation, from 1 to `Config.Limits.MaxPayoutSlots`.
- Each slot carries its **own baseline and its own kidnapping bonus**. They need not be equal — a creator can make the first kill worth more than the third, or load the value onto the last one.
- **All slots are escrowed up front** (§3.6). A contract that can pay three times has all three reward sets confiscated at creation; the creator cannot promise value they have not surrendered.
- Slots are claimed **lowest-numbered first**, so what a hunter is competing for is always unambiguous, and the app shows which slot is next and what it holds.
- The contract closes when the **last slot is claimed**, or on deadline/bailout/cancellation, whichever comes first. Unclaimed slots return to the creator in full through the normal release path (§9.2).
- Multi-slot contracts are inherently competitive: `Config.Limits.MaxHuntersPerContract` still caps concurrent hunters, and exclusive mode with more than one slot means the same single hunter may collect repeatedly.

**Anti-farm rules** (these are what stop a multi-slot contract becoming a respawn-camping machine):

- A slot cannot be claimed while the target holds post-respawn immunity (§14.39).
- The same hunter cannot claim two slots within `Config.Limits.SlotCooldownSeconds`.
- Each claim is a full fulfilment: its own death report, its own capture token, its own verification photo. There is no bulk claim.

---

### 3.5 Escrow Automation

On submission, **all baseline and potential bonus** currency and items are automatically confiscated from the creator's inventory/accounts and held securely in escrow by the script until the contract resolves.

Required behavior:

- The reward builder is validated **server-side twice** — once when it is opened (the client is sent only what the player actually holds) and again on submit, to confirm nothing changed in between. A submitted source the player no longer holds rejects the whole contract; it is never silently reduced.
- Confiscation and the writing of the escrow record happen as a **single atomic operation** — a database transaction in `mysql` mode, an atomic file swap in `json` mode (§10). If any part fails, nothing is taken.
- Weapons are stored as a **full metadata snapshot** (serial, attachments, ammo, durability), never as a slot reference.

See §9 for the binding rules these follow from.

### 3.6 Failure Penalty Configuration

An optional, config-backed setting allowing the creator to enforce a **financial penalty** if an accepted hunter fails to complete the contract within a designated time parameter.

The penalty is **staked, not invoiced**. A penalty charged only after a failure is a penalty the hunter can simply walk away from, so:

- The amount is **taken from the hunter when they accept**, and held in escrow alongside the creator's reward. A hunter who cannot cover it cannot accept the contract, and is told so.
- It is **forfeited to the creator** if they abandon the contract or let it expire while holding it.
- It is **returned in full** when they deliver, or when the contract ends for a reason that is not their fault — the creator cancelling, or the target buying out.
- A stake is never counted as part of the contract's reward, never shown on the board as such, and never swept into a general refund to the creator.
- Lowering the penalty by amendment (§12.1) returns the difference to every hunter who staked the higher figure.

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
- **The target must be genuinely dead, not downed.** A player in a downed / bleeding-out / last-stand state is *not* a completed elimination: the server requires the QBox death state (`isdead`), and explicitly rejects `inlaststand`. A hunter who downs a target and photographs them mid-bleedout gets nothing until the target actually dies. This is re-checked at photo submission, not only at the death report — a target revived between the two invalidates the pending completion.

Attribution and photo binding:

- Killer, weapon, and timestamp are **recorded into the contract's pending-completion state at the moment of death** — never queried later at photo time, where a second player's damage or a respawn can overwrite the answer.
- The verification photo must be captured through a flow **the script opened for a specific contract**. On submit, the server validates **contract id, hunter id, target ped distance, and an unexpired capture token together**; a photo missing any of the four is rejected. An arbitrary photo taken near a corpse never satisfies the check.

#### Kidnapping Fulfillment
- The contractor must bring the target **alive** to the physical location of the bounty creator.
- The script must detect a **30-second continuous proximity countdown** between contractor, target, and creator.
- On success: **baseline + bonus** escrowed rewards are released, and the contract closes for all hunters.
- **The target must be alive and conscious for the entire delivery** — not dead, not downed / bleeding out, and above a configurable health floor. This is re-checked on every countdown sample, not only when the countdown arms: a target who dies or drops into last stand mid-countdown fails the delivery, and the hunter gets nothing. Delivering a corpse is not a kidnapping.
- A short **grace period (config-backed, 2–3s default)** absorbs desync and doorways before the countdown resets; only a break exceeding the grace resets it.
- The hunter sees the live countdown and its grace state on screen, so a reset is never silent.

---

### 7.5 Law Enforcement Threat Advisory

A contract may name a player who holds a protected job (LEO, EMS, fire). Those players cannot use the app (§2), so they have no in-app way to learn about it — the system tells them, and tells their department.

When a contract is created against a protected-job target:

- **Every online law enforcement player receives an lb-phone notification** naming **which officer** the contract is on: *"THREAT ADVISORY — A contract has been placed on Deputy J. Wood."* The bulletin is sent to their phone, one per contract, deduped.
- **An advisory goes out on every acceptance, carrying the running count.** The first bulletin says a threat exists; each acceptance says how much worse it has got — *"THREAT ADVISORY — The contract on Deputy J. Wood has been accepted. 3 operatives are now active."* Law enforcement can therefore judge the scale of the threat, not just its existence. The per-contract hunter cap (§3.7) bounds how many advisories one contract can raise, so this cannot be used to flood dispatch.
- **The targeted officer is alerted directly** regardless of the paranoid-alert config — they cannot open the app to check, so the alert is not optional for them.
- **The creator's identity is never included**, even when the creator is not anonymous. The advisory tells law enforcement that a threat exists and who it is against; finding out who ordered it is police work, not a free lookup.
- **A dispatch entry is raised** through `sc-dispatch`'s `AddNotification` export when that resource is present, so the threat lands in the MDT alongside other calls. Config-backed; falls back to phone notification alone.
- Which job types trigger a bulletin, and which jobs receive it, are separate config lists.

Both sides of the contract are told plainly who they are dealing with:

- **The creator is warned before the contract is placed.** Selecting a protected-job target raises an explicit confirmation — *"This target is a sworn law enforcement officer. Placing this contract will alert every officer on duty."* — naming the target's department. Escrow is not taken until they confirm.
- **The hunter is warned before accepting.** The listing carries a permanent **LAW ENFORCEMENT** flag, and accepting raises the same style of confirmation — *"This contract is on an active police officer. Law enforcement has been advised."* No hunter can claim they did not know.
- The flag is shown even when the creator is anonymous: it describes the *target*, and the target's job is not the creator's secret to keep.

Contracts on protected-job targets are **allowed by default** — hunting a cop is legitimate criminal roleplay, and the advisory is what makes it a two-sided fight rather than an ambush. A server that would rather forbid it entirely sets `Config.Targeting.AllowProtectedJobTargets = false`, and creation is refused instead.

The out-of-app bailout (§5) is unavailable to protected-job targets by default — the department response is their counter-play. `Config.Bailout.AllowProtectedJobCommand` enables a command-based buyout for servers that prefer it.

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
- `Config.MaxActiveContractsPerCreator` and `Config.MaxAcceptedPerHunter`
- `Config.Limits.MaxPayoutSlots` and `Config.Limits.SlotCooldownSeconds`
- Threat advisory: trigger job types, recipient jobs, dispatch integration on/off
- `Config.Targeting.AllowProtectedJobTargets`, `Config.Bailout.AllowProtectedJobCommand`
- Amendment proposal expiry window (default 5 min)
- Contract-cancellation cooldown (pre-acceptance)
- Relay message rate limit and length cap; masked-call enable
- Alt-account protection toggle (account-level identifier check)
- `Config.Progression` — enabled, resource name, trust per elimination and per kidnapping
- `Config.Mugshot.MaxImageBytes` — bound on a client-rendered headshot
- `Config.Audit.Webhook` — staff mirror for financial and rejected lines

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

## 11. Contract Communications (Masked Relay)

The creator and every accepted hunter can talk to each other **without breaking anonymity**. This exists so contracts can be negotiated in character rather than guessed at.

### 11.1 Masked identities
Each contract issues a stable per-contract **alias** to every participant — `Client` for the creator, `Operative #1`, `Operative #2`… for hunters, assigned in acceptance order. The server holds the alias → citizen id map; **it is never sent to another player's client**. Aliases are per contract, so the same hunter appearing on two contracts cannot be correlated across them by alias.

### 11.2 In-app contract thread
- Every contract has a message thread inside the app. In **exclusive** mode it is one-to-one; in **competitive** mode the creator has a **separate thread per hunter** — hunters cannot see each other or each other's messages.
- Messages relay **server-side**. No phone number, character name, citizen id, or source id ever crosses to the other participant. The app renders the alias only.
- Anonymity is a display property, not a gag: if a player chooses to reveal who they are in the text, that is their roleplay decision. The script never leaks it for them.

### 11.3 Voice calls
- A participant may request a **masked call**. The call is placed through lb-phone with caller identity suppressed and the alias shown as the caller name.
- If the installed lb-phone version cannot suppress caller identity, the feature is **disabled rather than degraded** — it must never place a call that reveals a number an anonymous participant paid to hide. This is a config-backed capability check performed at resource start, logged to console.
- Non-anonymous participants may call normally.

### 11.4 Abuse controls
- All relayed text passes through lb-phone's `ContainsBlacklistedWord` export before delivery, and is length-capped.
- Per-participant message rate limit (config-backed).
- Either participant can **mute a thread**; muting does not affect contract state. A muted hunter still receives contract-critical notifications (amendments, completion, expiry) — those are system messages, not player text.
- Threads are retained only while the contract is open, plus the ledger retention window (§6.3). Staff-facing logs record that a thread existed and its participants, not its contents, unless the server enables full logging in config.

---

## 12. Contract Amendments

Terms can change after a contract goes live, but **never unilaterally against the other side**. Every amendment is a proposal with an explicit diff, an expiry, and a recorded outcome.

### 12.1 Additive changes — immediate
A creator may improve a contract at any time with no approval required, because the change can only benefit hunters:

- Adding cash, bank, dirty money, crypto, items, or weapons to the baseline escrow
- Raising the kidnapping bonus
- Extending the completion deadline
- Removing or lowering a failure penalty

The added value is escrowed immediately under §9.1 rules. Every accepted hunter is notified of the improvement. **Escrow can never be reduced by an additive change**, and added escrow is subject to the same release paths as the original.

### 12.2 Material changes — mutual approval required
Anything that could disadvantage the other side is a **proposal**:

- Lowering the reward or the bonus
- Shortening the deadline
- Adding or raising a failure penalty
- Switching assignment mode (exclusive ↔ competitive)
- Changing the contract reason or completion conditions
- Withdrawing escrow

Rules:

- Either side may propose. The **creator and every accepted hunter** must approve before it applies.
- In **competitive** mode, a material amendment requires approval from **all** accepted hunters. A single decline rejects it.
- A proposal **expires** after a config-backed window (default 5 minutes) and is treated as declined.
- On decline or expiry, the contract continues on its **original terms**, unchanged. A rejected proposal never partially applies.
- The app shows a plain-language **diff** — what changes, from what to what — never a raw payload.
- Amendment history is stored with the contract and visible to its participants, so nobody can claim terms they never agreed to.

### 12.3 What can never be amended
- **The target.** Retargeting is a new contract, always. This closes the bait-and-switch where a hunter accepts a soft target and is redirected onto a hard one.
- **The identity of the creator or an accepted hunter.**
- **Escrow already owed to a completed fulfilment.**

### 12.4 Withdrawal and abandonment
- **Before any hunter accepts**, the creator may cancel outright; full escrow returns via §9.2. A config-backed cancellation cooldown prevents list-spam through create-and-cancel cycling.
- **After acceptance**, cancellation is a material amendment (§12.2) — the hunter has to agree, since they have already invested time.
- A hunter may **abandon** a contract they accepted at any time. The contract reverts to open (exclusive) or simply loses that hunter (competitive), and the failure penalty applies if one was configured and the deadline had started.

### 12.5 The hunter's final determination
Where the specification says a hunter "decides on the fly" (§3.4 elimination vs. kidnapping), that choice remains the **hunter's alone** and is not amendable. A creator can add a bonus to influence it; they cannot compel it.

---

## 13. Participation & Concurrency

The system is fully symmetric — there is no "hunter role" and "creator role", only players holding contracts in one capacity or the other.

- A player may place **multiple contracts** simultaneously, up to `Config.MaxActiveContractsPerCreator`.
- A hunter may hold **multiple accepted contracts** simultaneously, up to `Config.MaxAcceptedPerHunter`.
- The same player may be a creator on one contract and a hunter on another, at the same time, with no restriction.
- Two hunters on the same competitive contract race normally (§7.4, atomic single-winner lock).

### 13.1 Conflict rules (server-enforced, non-negotiable)
- A player may **not** place a bounty on themselves.
- A player may **not** accept a contract where they are the target.
- A player may **not** accept their own contract, in either assignment mode.
- Where the server exposes an account-level identifier (license, Discord id), a player may **not** place a bounty on **another character of their own account**, and may not accept a contract created by one. With the 17mov multi-character system in use this is the primary alt-farming vector, so the check is on the **account identifier, not the citizen id**. Config-backed toggle for servers that permit it.
- Every one of these is checked **server-side on every event**, not only when the app renders a button.

### 13.2 Concurrency safety
- All caps are counted **server-side from live state**, never from a client-supplied count.
- Contract creation, acceptance, amendment, and completion each take the contract's lock before mutating it, so two simultaneous actions on the same contract cannot interleave.

---

## 14. Abuse Resistance

Produced by an adversarial audit of this specification across seven dimensions — economy, collusion, client trust, harassment, RP metagaming, availability and privacy. 111 vectors survived independent refutation and merged into the rules below. These are binding in the same way as §9; where a rule sharpens an earlier section, the rule wins.

Severity is the damage if the rule is absent, not the difficulty of the fix.

---

### Critical

#### 14.1 The acting player is the event source, never a payload field

**Vector.** Every payload field is attacker-controlled while `source` is engine-supplied; §7.4 currently lists "hunter id" among the things the server validates on submit, which reads as a client-sent field. A handler that trusts it accepts a contract as another player, claims a payout as a hunter who never accepted, or rotates the field to evade the §9.5 cooldown.

**Rule.** §9.6 governs outcomes; this rule governs identity. Every server handler in this resource resolves the acting player exactly once, as `exports.qbx_core:GetPlayer(source)`, and returns immediately if that is nil. No handler reads an identity from the payload: `citizenid`, `hunterId`, `playerId`, `serverId` and any equivalent are discarded before validation, never validated. Client payloads may carry only server-issued opaque handles — contract id, reward-builder slot index, target-search handle, capture token. The §9.5 rate-limit key, the §2 blacklist re-check, the §3.5 escrow debit and §7.4's hunter-id factor are all derived from the resolved citizen id. The pass condition is testable: for every registered net event, no handler body references a payload identity field. Admin tooling that acts on another player's behalf uses its own ACE-gated handlers and never reuses app events.

*Config:* none (structural)

#### 14.2 Death reports are victim-sourced and independently corroborated

**Vector.** FiveM has no native server-side death event, so the signal always originates on a client. A killer-sourced death report lets a hunter assert the target died, anywhere on the map, and §7.4's four-factor check then validates cleanly against a fabricated death.

**Rule.** §7.4's "recorded at the moment of death" is qualified as follows. A pending-completion opens only on a death report whose `source` resolves to the victim; a killer-asserted death is never accepted. Before writing attribution the server independently confirms all of: the victim's synced ped is dead or at zero health; the named killer is on that contract's accepted-hunter list; a `weaponDamageEvent` naming that killer and that victim was observed within `Config.Completion.DeathReportWindowMs`; and killer-to-victim distance at the reported timestamp is within `Config.Completion.MaxWeaponRange` for the reported weapon hash. A report failing any check is dropped and written to the conduct log (§14.31). Deaths with no corroborating damage event (fire, explosions, vehicle impact, drowning, falls) do not pay out unless the owner widens the weapon-hash allowlist; that is the intended direction to fail.

*Config:* `Config.Completion.DeathReportWindowMs, Config.Completion.MaxWeaponRange`

#### 14.3 Escrow rows carry a settled state and every release is a guarded compare-and-set

**Vector.** §9.7's lock covers only the transition to `completed`; bailout, cancel, expiry, penalty resolution, pending-login retry and the §10.3 shutdown sweep take no lock and all call `releaseEscrow`. Each yields on an await between reading the row and moving the funds, so a bailout landing beside a completion — or a restart sweep releasing a row paid out minutes earlier — pays one escrow twice.

**Rule.** Extend §9.1: the escrow record carries `state ∈ {held, releasing, settled}` plus `settled_at` and `settled_to`. Extend §9.2: `releaseEscrow`'s first statement, inside the same transaction that moves the funds, is a conditional update from `held` to `releasing` (`UPDATE ... WHERE id = ? AND state = 'held'` in mysql; the equivalent check-and-set with no yield between read and write in json and memory). If zero rows changed, `releaseEscrow` returns false and moves nothing. Every caller without exception passes through that guard: completion, bailout, cancel, expiry, penalty resolution, pending-login retry, memory-mode disconnect refund and the §10.3 shutdown sweep. Expiry-with-penalty is one resolution producing one settled row. Extend §9.10 with a `completing` state persisted before any funds move; §10.4's restart recovery resolves any contract found in `completing` or any row found in `releasing` exactly once by re-reading the escrow record to determine whether funds actually moved, and writes the outcome to the audit log. Without that reconciliation pass this guard converts a rare duplication into a rare property loss, which §9.3 exists to prevent.

*Config:* none (structural)

#### 14.4 Anonymity and hiding are enforced by omission at the transmit boundary

**Vector.** §4's "hidden from the public listing" and §7.1's "display filter only" are rendering language, so the natural build ships the full row and filters in NUI. Anyone with devtools or an event logger then reads the anonymous creator's name, the hunter roster the creator is not allowed to see, and every hidden contract — defeating both §4 systems for free and mooting the §6.1 informant purchase.

**Rule.** The server builds a per-recipient projection of every contract. Identity fields for an anonymous party are never placed in the payload rather than masked inside it: an anonymous contract carries `creatorLabel = 'Anonymous'` and no creator id or name key at all, and `hunters[]` is never sent to the creator — a boolean for exclusive contracts, or a count for competitive, is the maximum §7.3 needs. "Display filter" in §7.1 and §9.10 means server-side filtering per recipient: a contract a viewer may not see is not sent to that viewer, and no `hidden` flag or hidden row ever crosses the wire to a player client. There is no client-side hiding step anywhere in the app. Contract data is never sent to `-1` and never placed in a state bag or any globally replicated store; every push is per-recipient and re-checks the §2 blacklist at push time as well as at request time, and a QBox job change drops the player from the push set and pushes a cache-clear to that client. The omission is re-applied independently at every send point — listing, contract detail, acceptance notification, completion alert, ledger entry, tracking update — and the exact allowed key set per recipient role (public viewer, accepted hunter, creator, target, staff) is asserted in a test so a refactor cannot widen it silently. Real identities remain in the server-side record for the audit log and the §6.1 informant path. Staff and debug tooling get their own ACE-gated projection and never reuse the player payload.

*Config:* `none (per-role key allowlist is code, covered by a test — no config opt-out)`

#### 14.5 Contract limits are enforced per target, not only per actor

**Vector.** §9.5's cooldowns and §8's caps are all actor-scoped and value-scoped, so nothing bounds how often one player can be named. Escrow refunds on every non-completion path, so re-placing costs approximately nothing, and §7.1 removes the victim's last escape by design — the contract is waiting on next login.

**Rule.** Four target-scoped checks run server-side before escrow is taken, keyed on the target's citizen id and additionally on the creator's account identifier (§14.7): creation is refused if the target already holds `Config.Limits.MaxActiveContractsPerTarget` contracts in `active` or `accepted` state; if any contract naming that target resolved less than `Config.Limits.TargetCooldownAfterResolveSeconds` ago, counting `completed`, `bailed_out`, `expired` and `cancelled` alike as resolutions; if this creator last named this target less than `Config.Limits.SameCreatorSameTargetCooldownHours` ago; or if the target is at `Config.Limits.MaxContractsPerTargetPerDay` on a rolling 24h window. Every rejection returns the single uniform string defined in §14.33 with no timer and no reason, so the limits cannot be binary-searched to learn whether someone is already under contract, and every rejection is written to the conduct log so a pattern of blocked attempts is visible even when nothing gets through. Fire the admin webhook when `Config.Limits.BurstDistinctCreatorsTrigger` distinct creators name one target inside `Config.Limits.BurstWindowSeconds`; coordinated targeting needs staff eyes, not silent throttling. Defaults are the owner's balance decision — a genuinely notorious character being contracted by several unrelated people is the mechanic working, an unbounded rotating pool on one victim is not.

*Config:* Config.Limits.MaxActiveContractsPerTarget, Config.Limits.TargetCooldownAfterResolveSeconds, Config.Limits.SameCreatorSameTargetCooldownHours, Config.Limits.MaxContractsPerTargetPerDay, Config.Limits.BurstWindowSeconds, Config.Limits.BurstDistinctCreatorsTrigger, Config.Alerts.AdminWebhook

---

### High

#### 14.6 Creator, target and hunter are three distinct parties

**Vector.** Nothing requires the three roles to be different people. A self-targeted contract is a death-proof, arrest-proof vault whose owner withdraws on demand; a creator who is also the target can guarantee any hunter fails and harvest the §3.6 penalty; and a self-accepted kidnapping is trivially satisfiable because all three distances are permanently zero.

**Rule.** Creation is rejected when the resolved creator's citizen id equals the target's. Acceptance is rejected when the resolved hunter's citizen id equals the contract's creator or target, evaluated inside the same guarded write as §14.34. Kidnapping completion additionally requires creator, target and hunter to be three distinct citizen ids on three distinct server source ids, re-checked inside the §9.7 completion lock — evaluated at completion only, never continuously, so a creator who disconnects mid-countdown fails for the right reason. These are structural rules with no config flag to disable them. Where the framework exposes account identifiers, a creator, hunter and target resolving to the same identifier is also rejected at creation and acceptance; where two of them merely share an identifier with a third party's household, the resource flags to the admin webhook and does not block — shared machines are common and auto-blocking them is itself a griefing vector. None of this defeats alt-account collusion, which is what §14.5, §14.7 and §14.10 are for.

*Config:* `Config.AntiCollusion.CheckSharedIdentifiers, Config.AntiCollusion.FlagOnly`

#### 14.7 Economic limits are keyed to the account, not the character

**Vector.** §9.5 scopes cooldowns "per citizen id", and one QBox account holds several characters each with its own citizen id, so every cumulative ceiling multiplies by the account's character count. Per-contract caps also give false confidence: nothing limits how many contracts are open at once, which is what makes escrow-as-stash and pair transfer rails unbounded.

**Rule.** Every economic counter — action cooldowns, concurrency caps and all value ceilings — is keyed to both the citizen id and the account identifier (the FiveM license, read from the server-side identifier list and never from anything the client supplies), with the stricter limit applying. These counters are persisted in the same store as the §9.1 escrow record and survive character switches, reconnects and restarts; they are never in-memory tables. A missing identifier degrades to the citizen-id key and never fails open on a value ceiling. Citizen-id scope is retained for presentation only — ledger ownership, contract ownership, notifications — and never for an economic limit. Enforce at creation, against the sum of the creator's currently open escrow records rather than the single submission: `Config.Limits.MaxActivePerCreator`, `Config.Limits.CreatesPerHour` on a rolling window, `Config.Limits.DailyEscrowValue` as a rolling 24h fiat ceiling, `Config.Limits.MaxActiveGlobal` as a server-wide ceiling, and `Config.Limits.MinContractValue` (with `Config.Limits.MinItemCount` for item-only contracts, which §3.4 permits) so a $1 probe contract is not valid. Rejection names which ceiling was hit. Do not add a per-target contract cap here — that is §14.5, and it must be reachable only through target-scoped keys, never by letting allies fill a victim's slots.

*Config:* Config.RateLimit.Key = 'license', Config.Limits.MaxActivePerCreator, Config.Limits.CreatesPerHour, Config.Limits.DailyEscrowValue, Config.Limits.MaxActiveGlobal, Config.Limits.MinContractValue, Config.Limits.MinItemCount

#### 14.8 Every contract has an absolute lifetime; the pause has a ceiling; hunters can always get out

**Vector.** §9.10 lists `expired` but nothing in the spec drives that transition: §3.6's timer is optional, exclusive-only and pausable, so an unaccepted contract never resolves and a paused one never resolves either. Escrow becomes an immortal police-proof stash, a victim stays permanently hunted, and a hunter who accepted an exclusive contract whose creator logged off can neither complete it, abandon it, nor recover a posted bond.

**Rule.** Every contract carries three independent clocks, all evaluated by one sweeper — never per-contract timers — and resumed from stored elapsed time on restart per §10.4. (a) `Config.Contract.AbsoluteTTLHours` runs on wall-clock time, is never paused, applies to `active` and `accepted` contracts alike, and exists as a garbage collector — set it in days, not hours. (b) `Config.Contract.MaxOnlineLifetimeMinutes` accrues only while the target is online and is the survive-the-clock counter-play; it is the same timer referenced by §14.19 and is not implemented twice. (c) `Config.Contract.MaxPausedHours` caps total accumulated pause across a contract's life. On any of the three, the contract transitions to `expired` and resolves through `releaseEscrow` with reason `refund`, the creator is refunded in full, any hunter is released with no penalty applied, both parties are notified on next login, and the §14.5 post-resolution cooldown starts. Amend §7.1 to read: no state change may be *triggered by* a player going offline; contracts still expire on absolute age. §3.6's pause continues to govern whether the *failure penalty* applies and never whether the contract can expire — expiry refunds, it does not punish. Separately, a hunter may abandon an exclusive contract at any time, recovering their bond in full before `Config.Penalty.GraceBeforeForfeit` and forfeiting it after; and an exclusive hold returns to the board when the holder shows no server-recorded engagement with the target for `Config.Exclusive.InactivityRevokeSeconds`, after which that citizen id and account may not re-accept the same contract id. Both of those clocks pause while the creator or target is offline, so no hunter is revoked for a target who is not in the world, and the hunter sees the countdown exactly as §7.4 already requires for the kidnap timer.

*Config:* `Config.Contract.AbsoluteTTLHours, Config.Contract.MaxOnlineLifetimeMinutes, Config.Contract.MaxPausedHours, Config.Exclusive.InactivityRevokeSeconds, Config.Penalty.GraceBeforeForfeit`

#### 14.9 Cancellation is defined, gated, locked and logged

**Vector.** `cancelled` appears in §9.10's state machine and nowhere else, so the implementer invents it — and the default invention is free, instant and unlocked. That makes escrow a momentary stash you fill before an arrest and empty afterwards, and it lets a creator yank the escrow out from under a hunter who has already cornered the target.

**Rule.** Only the creator may cancel. Cancellation is permitted only while the contract is `active` and only after `Config.Contract.MinAgeBeforeCancel`, so escrow cannot be used as a deposit-and-withdraw stash; it is forbidden once the contract is `accepted` unless `Config.Cancel.AllowAfterAccept` is true, in which case `Config.Cancel.FeeFraction` of the escrow is paid to the accepted hunter. Cancellation takes the same §9.7 lock and the same §14.3 settled-state guard as completion, resolves through `releaseEscrow` with reason `refund` and no currency conversion, is subject to `Config.Cooldowns.cancel` added to §9.5's list, counts as a resolution against the §14.5 per-target and per-creator ceilings, and writes an audit entry. A cancellation refund may be delayed by `Config.Cancel.RefundDelaySeconds` so cancel is never a cheaper withdrawal than bailout. Because cancel-after-accept is forbidden by default, §14.8's absolute TTL and inactivity revoke are mandatory rather than optional — otherwise a colluding hunter freezes a creator's escrow permanently.

*Config:* `Config.Cooldowns.cancel, Config.Contract.MinAgeBeforeCancel, Config.Cancel.AllowAfterAccept, Config.Cancel.FeeFraction, Config.Cancel.RefundDelaySeconds`

#### 14.10 Release is source-faithful; currency conversion is a payout-only, lossy, explicit step

**Vector.** §8 mandates a bonus payout currency and §6.2 mandates a dirty/crypto payout option, but nothing states that the payout currency matches the escrowed currency — and §9.2 mandates one shared release routine, which is exactly where an implementer will put the mapping, so refunds and bailouts get converted too. Escrow a million dirty and bail out for $1 to receive it clean: a 100%-efficiency launderette that no server's actual laundering economy is priced at.

**Rule.** Change the mandated signature in §9.2 to `releaseEscrow(contractId, recipient, portion, reason)` with `reason ∈ {payout, refund, bailout, penalty, cancel, shutdown}`, written into the audit entry. `releaseEscrow` pays out every source in exactly the currency, item and metadata the escrow record holds it as; the escrow row's source type is the payout type. Currency conversion is legal only for `reason == payout`. It is offered only when `Config.Payout.AllowCrossCurrency` is true — default false, source-faithful — and when enabled it applies `Config.Payout.ConversionRate` computed server-side from the escrow record, routed through the server's existing laundering or exchange resource via a single bridge function rather than crediting the destination account directly, with converted value capped per creator per rolling 24h. Validate at resource start that the configured rate is no better than the server's own launderette rate and log a warning otherwise. The escrow record stores both the pre-conversion source and amount and the post-conversion amount, and the hunter sees the post-conversion figure in the accept UI and the completion notification before it is relevant to them — an honest hunter must never discover the spread after the fact.

*Config:* `Config.Payout.AllowCrossCurrency, Config.Payout.ConversionRate, Config.Payout.MaxSafeRate, Config.Payout.MaxConvertedPerDay, Config.Transfers.Handler`

#### 14.11 The write debounce is not a durability window for money

**Vector.** §3.5 requires confiscation and the escrow write to be one atomic operation while §10.2 requires debounced batched writes; both cannot hold, and §3.5's atomicity clause covers creation only. A hunter paid through ox_inventory while the contract's state transition sits in the 5-second buffer, followed by a crash or a scheduled restart, is a payout that can be claimed a second time — and the mirror case destroys player property.

**Rule.** Extend §3.5's atomicity requirement to the entire financial lifecycle: escrow creation, every `releaseEscrow` call, completion, bailout, cancel and penalty resolution each force an immediate synchronous flush that bypasses §10.2's debounce, using the same atomic temp-file-and-rename in json mode. Ordering is fixed: persist the state transition first (`completing`, `releasing`, `bailed_out`, `expired`), flush, perform the account and inventory mutation, then persist and flush the terminal state. `Config.Database.DebounceMs` applies only to non-financial state — listing caches, mugshot references, hidden flags, countdown progress, ledger cosmetics. In json mode write a write-ahead intent line before the money moves, clear it after the escrow row lands, and run a boot-time reconciliation pass that reports and repairs both "funds removed with no escrow row" and "row marked `releasing` but never settled", logging every repair. §10.2's debounce buffer is flushed unconditionally in the resource's on-stop handler before §10.3's sweep runs. State plainly that synchronous financial writes cost main-thread I/O and are not to be optimised back into the debounce; §14.51's sharding is what keeps that cost bounded.

*Config:* `Config.Database.Json.SyncOnFinancialWrite, Config.Database.DebounceMs (non-financial writes only)`

#### 14.12 Pending releases are per-line, bounded, and dead-lettered

**Vector.** §9.3 correctly refuses to destroy property but never says the row is decremented in the same operation as the give, and never defines partial delivery — so "retry until fully delivered" on an undecremented row re-gives everything each attempt. Escrow five rare weapons, take the refund with a deliberately full bag, and relog with two free slots repeatedly.

**Rule.** The §9.3 retry is per line item and decrements before it gives. For each line in the escrow record: write the decrement first, under the same check-and-set guard as §14.3, then call AddItem/AddMoney; if the give returns false, restore that single line and stop, leaving the rest of the row pending. A give whose result is unknown because the player dropped mid-call is treated as delivered and never re-given — loss over duplication is the correct direction to fail, and the audit entry per delivered line is what lets an admin restore it manually. The row is marked `settled` only when every line reaches zero. A per-citizen-id retry mutex is held for the duration of the retry so a relog loop cannot run two retries concurrently. Bound the machinery without weakening the guarantee: `Config.PendingEscrow.MaxPerPlayer` (while at the cap the player cannot create new contracts, with a message naming the cause, so the abuse is self-limiting and the queue is visible and manually claimable in the app), `Config.PendingEscrow.MaxRetriesPerLogin` with exponential backoff, and a randomised `Config.PendingEscrow.LoginRetryDelayMs` so a post-restart reconnect wave does not converge. After `Config.PendingEscrow.DeadLetterAfterDays` a record moves to an admin-visible dead-letter queue that is no longer retried automatically but still holds the property for manual return; this is never framed or implemented as forfeiture.

*Config:* `Config.PendingEscrow.MaxPerPlayer, Config.PendingEscrow.MaxRetriesPerLogin, Config.PendingEscrow.RetryBackoffSeconds, Config.PendingEscrow.LoginRetryDelayMs, Config.PendingEscrow.DeadLetterAfterDays`

#### 14.13 One validator builds the escrow record from server-read data, over baseline and bonus together

**Vector.** §3.5's double validation is scoped by its own wording to *holdings*, not config compliance, and §3.4 presents the kidnapping bonus as a separate bucket — so a crafted submit escrows a blacklisted weapon or a cap-busting amount through the bonus path, and the escrow becomes a transfer channel for exactly the items config forbids. Separately, nothing says the item metadata in the record was read from the inventory slot rather than from the payload.

**Rule.** A single server-side validator runs over baseline and bonus combined, on builder open and again on submit, with one call site — the bonus is not a separate code path. It enforces four things, not one: the source is enabled in config; the item or weapon is not on `Config.Escrow.ItemBlacklist`; the per-source cap is not exceeded; and baseline plus bonus together do not exceed `Config.Escrow.GlobalMaxContractValue`. Rejection follows §3.5's existing all-or-nothing rule and names the failing source. The client sends only `{slot, quantity}` per item source; inside the same atomic operation that removes the item, the server reads the name, quantity and complete metadata table from that inventory slot and writes those values into the escrow record — any name or metadata in the payload is discarded before validation, and the blacklist check runs against the server-read name. Non-cash assets with a variable price, crypto above all, are escrowed, recorded and released in **units**, never in fiat value; the fiat valuation is computed once at creation solely to enforce the caps and is stored alongside the unit count as an audit figure, and may be recomputed at release for the log only — it never alters the units returned. Do not re-run cap checks at release: a cap an admin lowered mid-contract must not shrink an earned payout. Re-validating the blacklist at release is permitted only for items blacklisted *after* escrow, diverting them to the creator with an audit entry, because a hunter who silently receives less than the listing promised will read it as theft.

*Config:* `Config.Escrow.ItemBlacklist, Config.Escrow.PerSourceCaps, Config.Escrow.GlobalMaxContractValue`

#### 14.14 Every client-supplied number passes one coercion helper before any comparison

**Vector.** §8's caps are upper bounds only and §10.1's sanitisation rule is explicitly about text, so nothing rejects a negative, fractional, NaN or overflowing amount. QBox's RemoveMoney given a negative amount credits rather than debits — direct money creation from one event with a minus sign, the cheapest exploit in the set.

**Rule.** Every numeric field arriving from a client passes through one coercion helper that rejects nil, NaN, infinity, non-integers, values below 1, and values above a hard sanity ceiling, *before* any comparison against a per-source cap. Rejection fails the whole contract; a silent clamp is forbidden. The kidnapping bonus multiplier is bounded by `Config.Bonus.MaxPercent` and resolved to concrete absolute amounts at creation, and those absolute amounts are what §3.5 confiscates and the escrow record stores, so §9.1 continues to govern payout size. Per-source caps and the global maximum are re-checked server-side against the resolved absolute totals after coercion. The rejection message names the source that failed.

*Config:* `Config.Bonus.MaxPercent`

#### 14.15 Non-escrow transfers are debit-first, server-priced, and two-sided

**Vector.** The bailout premium, anonymity fees, informant premium, cancellation fee and failure penalty all move money outside the escrow record, governed by no binding rule. §5's credit side is unconditional in its wording — "the creator receives all escrow back, plus the cash premium" — with no clause requiring the premium to have actually been collected, so a discarded RemoveMoney return value mints the premium out of nothing.

**Rule.** Every non-escrow transfer in this resource — bailout premium, anonymity fee, informant premium, cancellation fee, failure penalty — is two-sided and debit-first: the price is read from the stored contract record or from config, never from the payload; the payer is the party the server resolves as entitled to pay (the target for a bailout, the creator or target for an informant purchase), never a payload-named player; the debit's return value is checked; the credit executes only after a true return inside the same server-side handler; and any failure rejects the whole action with a UI error and moves nothing. Partial payment is forbidden — the handler may sum across accounts in `Config.Bailout.PaymentOrder` but must debit all of it or none. All five transfer types are added to §9.8's audit list.

*Config:* `Config.Bailout.PaymentOrder`

#### 14.16 The bailout premium is server-clamped and rail-limited

**Vector.** §5 lets the creator type any figure with no floor, no ceiling and no relation to the escrow, and §8 caps only the reward builder — so the same person sets both sides of the trade. A $1 escrow with a $2,000,000 premium is spec-legal and moves that money straight from the target's bank with no proximity, no ATM and no pass through the server's banking resource, routing around every transfer tax and limit the owner tuned there; priced the other way, the advertised escape is put out of the victim's reach entirely.

**Rule.** The premium is validated and clamped server-side at creation, not at payment, and is immutable thereafter. The stored figure is `min(Config.Bailout.MaxAmount, Config.Bailout.MaxMultipleOfEscrow × escrow value from the §9.1 record)` and no lower than `Config.Bailout.MinPremiumPctOfEscrow` of that same value; the clamp is applied silently so the ceiling cannot be probed by trial. At payment time it is additionally clamped to `Config.Bailout.MaxPercentOfTargetNetWorth` of the target's liquid holdings, evaluated server-side and never surfaced to the creator, so the clamp is not a wealth oracle. The premium moves through the same server bridge used for player-to-player bank transfers (`Config.Transfers.Handler`) rather than direct account writes, so the server's transfer tax and limits apply, and the UI shows the gross figure before confirmation. A rolling 24h ceiling applies per creator-and-target pair, keyed per §14.7. `Config.Bailout.MaxPerPairPerDay` bounds repeat extortion and `Config.Bailout.CreatorShare` may direct the remainder to a sink so a repeat loop decays rather than compounds; where a sink share is used it is stated in the audit line or players will report it as the script eating money.

*Config:* Config.Bailout.MaxAmount, Config.Bailout.MaxMultipleOfEscrow, Config.Bailout.MinPremiumPctOfEscrow, Config.Bailout.MaxPercentOfTargetNetWorth, Config.Bailout.MaxPerPairPerDay, Config.Bailout.CreatorShare, Config.Transfers.Handler

#### 14.17 Bailout has a state gate, a processing delay, and never rug-pulls a hunter

**Vector.** §5 gates the buyout on two config toggles and no player state, so it resolves an IC scene with an OOC transaction at second 25 of a kidnap countdown, while hogtied, downed or mid-firefight. It also "instantly deletes the contract" with no statement of what happens to a hunter who has already accepted, posted a bond, or downed the target — which a creator and a colluding target can use as bait-and-forfeit against every real hunter on the server.

**Rule.** The bailout is evaluated server-side against the target's state, never client-asserted, and is refused while the target is dead, downed, restrained, carried, in a vehicle trunk, inside a running kidnap countdown for that contract, or within `Config.Bailout.CombatLockoutSeconds` of dealing or taking player damage. A successful payment starts `Config.Bailout.ProcessingDelaySeconds`, during which the contract remains completable and the target sees the pending timer; money moves only at the end of the delay through §9.2, and a completion landing inside the window voids the buyout and refunds the premium in full. A bailout that lands while a hunter holds the contract never counts as hunter failure: the hunter's penalty stake is returned with reason `refund`, and either `Config.Bailout.HunterCompensationPct` of the premium is paid to each accepted hunter as a surcharge charged to the target on top of the creator's figure, or the bailout is blocked outright while an exclusive hold is active, per `Config.Bailout.BlockedWhileAccepted`. Compensation is never funded out of the creator's premium — that breaks §5's payout guarantee and creates a target-and-hunter collusion channel. The target's own contract view and the bailout action are exempt from §7.1's presence filter and work regardless of the creator's presence; the returned escrow and premium route through §9.3's pending mechanism when the creator is offline rather than blocking the transaction.

*Config:* Config.Bailout.CombatLockoutSeconds, Config.Bailout.BlockedWhileRestrained, Config.Bailout.ProcessingDelaySeconds, Config.Bailout.HunterCompensationPct, Config.Bailout.BlockedWhileAccepted, Config.Bailout.WorksWhileCreatorOffline, Config.Bailout.MinContractAgeSeconds

#### 14.18 The failure penalty is staked at acceptance, capped, and disclosed before it can be agreed to

**Vector.** §3.6 lets a creator name any amount, §8 exposes only the feature's availability and window, and nothing requires the amount to be shown before acceptance or collected before failure. As written it is a debt owed by someone who has already chosen to fail: a hunter parks their funds elsewhere and squats every penalty-bearing exclusive contract on the board at zero cost, while an honest hunter can be charged an amount they never saw.

**Rule.** The penalty is clamped server-side at creation to `min(Config.Penalty.MaxAmount, Config.Penalty.MaxFractionOfEscrow × the §9.1 escrow value)`, silently, and the window may not be shorter than `Config.Penalty.MinWindowMinutes`. The exact amount and deadline appear on the contract card and in the accept dialog, and acceptance is refused server-side unless the payload echoes back the current amount and deadline for that contract version, so acceptance without disclosure is structurally impossible and a creator-side edit invalidates in-flight accept dialogs rather than silently repricing them. The penalty is escrowed from the hunter at acceptance into that contract's §9.1 record as a hunter-funded portion tagged `penalty`; acceptance is rejected outright, naming the shortfall, if the hunter cannot cover it, so the amount is always collectible and a hunter can never owe more than they knowingly staked. The required stake is shown prominently on the listing before the accept button. On failure it releases to the creator with reason `penalty`, less `Config.Penalty.SinkFraction` to a server sink so the round trip is lossy; it returns to the hunter with reason `refund` on completion, creator cancellation, absolute expiry, a bailout (§14.17), a paused-time cap breach, or where kill attribution shows the creator or target killed the hunter during the window. Total accumulated paused time is capped by `Config.Penalty.MaxPausedDuration`, past which the penalty is voided and the stake returned while the contract still expires on its §14.8 clock.

*Config:* Config.Penalty.MaxAmount, Config.Penalty.MaxFractionOfEscrow, Config.Penalty.MinWindowMinutes, Config.Penalty.EscrowAtAccept, Config.Penalty.RequireDisclosureOnAccept, Config.Penalty.SinkFraction, Config.Penalty.MaxPausedDuration, Config.Penalty.VoidIfHunterKilledByCreatorOrTarget

#### 14.19 Target eligibility is checked at creation, acceptance and every payout tick

**Vector.** §2's blacklist governs who may *use* the app, never who may be *named* by it, and §3.1 places no condition on the target at all. An on-duty officer or medic can therefore carry an active contract while §2 structurally bars them from the Paranoid Alert (a notification), the listing (a listing) and the bailout (a contract action) — a paid hit with no warning and no counter-play. A character created ten minutes ago is equally huntable, with no weapon and no money to buy out.

**Rule.** Introduce `Config.Targeting.BlacklistedTargetJobs` as a list separate from the §2 app-access blacklist, defaulting to the same five jobs. Creation is refused, and an existing contract is *suspended* exactly like §7.1's hidden flag — display and completion blocked, escrow untouched, state unchanged — when the target's current job is on that list; when the target's tracked playtime is below `Config.Immunity.MinTargetPlaytimeHours`; when they have been connected less than `Config.Immunity.MinTargetSessionMinutes`, which is what actually stops login-camping; when they are in jail, in hospital, cuffed or dead at that moment; or when they are inside a `Config.SafeZones` polygon. Ineligible players are omitted server-side from the target-search results of §14.33 so the refusal is never observable. Playtime is read through one configurable provider with a documented fallback to character creation date, and fails closed — an unresolvable playtime is below the minimum both for being targeted and for creating. State-dependent checks degrade to a no-op with a startup warning when the server's police or restraint resource exposes no readable state, rather than blocking all creation. If an owner sets `Config.Targeting.AllowTargetingBlacklistedJobs` true, the spec requires an out-of-app delivery path, because §2 forbids the in-app one: a plain chat notification and a console command for the buyout, exempted from the §2 check for exactly those two actions and nothing else. Record that exemption in §2 itself, or a later implementer will close it as a bug. Do not add an AFK or idle eligibility rule — it is a stand-still immunity switch. A minimum net-worth floor for targets is also rejected: it turns the picker into a wealth oracle.

*Config:* Config.Targeting.BlacklistedTargetJobs, Config.Targeting.AllowTargetingBlacklistedJobs, Config.Targeting.OutOfAppAlertFallback, Config.Targeting.BlockIfCuffedOrDead, Config.Immunity.MinTargetPlaytimeHours, Config.Immunity.MinTargetSessionMinutes, Config.Limits.MinCreatorPlaytimeHours, Config.Playtime.Export, Config.Playtime.FailClosed, Config.SafeZones

#### 14.20 The verification photo is obtained from the camera flow, never from the payload

**Vector.** §7.4's four factors authenticate the claim, not the image; §9.9 describes the photo's storage shape, not its provenance; and §10.1's escaping rule names player-supplied text, which an implementer will not read as covering an image URL. So the proof-of-death artifact is an arbitrary attacker-supplied string that is pushed instantly to a named player's phone and persisted in their Ledger — a griefer with one legitimate kill can deliver any image on the internet to the creator.

**Rule.** Add a fifth factor to §7.4. The server obtains the image reference from lb-phone's server-side upload result for the capture session it opened, scoped to the resolved hunter's `source`; any reference field present in the payload is discarded, never validated. Before storing, the server verifies the reference's host is in `Config.Photo.AllowedHosts` — literals in config, never client input — that it is a fresh upload by that hunter's own phone created after the capture token was issued and within `Config.Photo.MaxAgeSeconds`, and that it does not already appear on any contract this resource stores. The server stores its own resolved id, not the client's string, escapes it at the render boundary on the same rule as the contract reason, and writes the reference plus a SHA-256 of it, the hunter's citizen id and the contract id to the audit log. Where the gallery-ownership export is unavailable, fall back to the host allowlist and log a version warning at startup. `Config.Photo.Enabled = false` is a supported mode in which the contract completes on the remaining factors and no image moves at all, and an ACE-gated admin command purges a photo from every ledger row and from pending-completion state by contract id, documented as removing it from the game and not from the media host.

*Config:* `Config.Photo.Enabled, Config.Photo.AllowedHosts, Config.Photo.RequireGalleryOwnership, Config.Photo.MaxAgeSeconds, Config.Photo.LogHashToAudit, Config.Admin.PurgePhotoCommand`

#### 14.21 Server-read positions are untrusted telemetry, sampled with continuity and one grace budget

**Vector.** §9.6 presents server-side proximity as authoritative, but on FiveM the server's entity coordinates are whatever the owning client last synced — a position spoof satisfies a server-side distance check exactly as it satisfies a client-side one. The kidnap countdown is the softer target because §7.4's grace is specified per break with no cumulative cap, so an intermittent blink-teleport satisfies a 30-second "continuous" countdown.

**Rule.** State in §9 that positions read on the server are client-synced telemetry, not ground truth. For every proximity sample the server retains the player's previous sample and rejects the new one when the implied speed exceeds `Config.AntiCheat.MaxPositionDeltaPerSample` for that player's current vehicle and state — the ceiling is a per-state table, or legitimate aircraft, trains, interior warps and ambulance respawns will fail. The kidnap countdown is sampled by the server-side timer of §14.23, never by client ticks; a rejected or out-of-radius sample consumes grace, grace is one budget capped by `Config.Kidnap.MaxTotalGraceMs` across the whole countdown rather than reset per break, and exhausting it resets the countdown to zero with the reason shown on the hunter's HUD. Photo proximity requires N consecutive continuity-valid samples, not one instantaneous reading. Cross-client corroboration is not required and must not be specified — FiveM gives the server no way to read one client's view of another entity's position.

*Config:* `Config.AntiCheat.MaxPositionDeltaPerSample, Config.Kidnap.MaxTotalGraceMs, Config.Kidnap.SampleIntervalMs`

#### 14.22 Tracking is defined, coarse, scoped and suppressed — it is not a player locator

**Vector.** §1 advertises real-time target tracking and no later section defines it, so the implementer ships the thing the word means: a live blip. Under OneSync Infinity a client cannot otherwise obtain the position of a player outside its cull radius, so an unscoped precise feed hands cheaters information their menu cannot get, on a player they select — and it makes disguise, hiding and every counter-play inoperative because position arrives by menu.

**Rule.** Define tracking in §7 rather than leaving §1's pillar undefined. The server never transmits a target's raw coordinates, heading, blip, GPS route or postal to any client, including admin-facing client builds. Under `Config.Tracking.Mode = 'ping'` (the default) one shared server tick resolves positions every `Config.Tracking.UpdateIntervalMs` — never per frame, never a timer per hunter-contract pair — and sends each recipient a point coarsened to `Config.Tracking.CoarseRadius` or a district name, so hunters receive a search area and the UI renders a radius rather than a cursor. Fine proximity state — in-photo-range, countdown ticks, grace state — is computed server-side and pushed as a boolean and an integer, never as coordinates the client can difference. The channel is addressed per recipient to citizen ids the server has recorded as accepted hunters on a contract in `accepted` state; a subscribe carrying a contract id the resolved player does not hunt returns nothing. Tracking returns nothing while the target is dead or downed, for `Config.Immunity.PostRespawnSeconds` after respawn, and inside any `Config.SafeZones` polygon, where photo verification also refuses to validate and kidnap countdowns do not progress. Tracking stops on contract close, hunter abandonment and disconnect, and total live streams are capped by `Config.Tracking.MaxActiveStreams`. Granularity is a per-server balance decision — set too coarse in a dense downtown block the pillar stops working, and players will coordinate the search in Discord instead, which is worse.

*Config:* Config.Tracking.Mode, Config.Tracking.UpdateIntervalMs, Config.Tracking.CoarseRadius, Config.Tracking.AcceptedHuntersOnly, Config.Tracking.DisabledWhileDead, Config.Tracking.MaxActiveStreams, Config.SafeZones, Config.SafeZones.BlockVerification

#### 14.23 Kidnap countdowns run on one shared tick behind an arm gate

**Vector.** §7.4 mandates a continuous three-party proximity countdown and §9.6 forces it server-side, but nothing constrains how it ticks — so the straight reading is one thread per accepted contract, three coordinate reads per hunter per tick, running whether or not the parties are on the same island or even online. Contract count and hunters per contract are both unbounded, so per-tick work grows until the scheduler misses its budget and every other resource's threads are delayed.

**Rule.** All kidnap countdowns are evaluated by exactly one shared server tick at `Config.Kidnap.TickMs` — never a thread or timer per contract or per hunter. Before any distance math a countdown must pass an arm gate: the contract is `accepted`, and hunter, target and creator are all online and in the same routing bucket. Only armed countdowns consume distance work; per-tick cost is O(armed countdowns), not O(accepted contracts). Compare squared distances against squared `Config.Kidnap.ArmRadius` and the configured proximity radius; take no square roots. A client-side proximity report may hint that a countdown should arm so idle contracts cost nothing, but the server re-derives every coordinate itself and is sole authority on whether the countdown progresses — a client hint can start work, never cause progress. Armed countdowns are capped server-wide by `Config.Kidnap.MaxConcurrentCountdowns`; over the cap the server refuses to arm new ones and tells the hunter, and never sheds an in-progress countdown, because §7.4 promises a reset is never silent. §10.4 is extended: in-flight countdowns reset on restart and the affected hunters are notified, since a restart currently breaks that same promise.

*Config:* `Config.Kidnap.TickMs, Config.Kidnap.ArmRadius, Config.Kidnap.MaxConcurrentCountdowns`

#### 14.24 Kidnapping requires observable coercion and a living, conscious target

**Vector.** §7.4's kidnapping test is purely geometric: three entities near each other for 30 seconds. There is no restraint, damage or consciousness requirement, so a downed body in a trunk satisfies "alive" and three friends standing in a circle satisfy the whole thing — making the highest-paying outcome the cheapest to reach, which inverts the risk gradient the bonus exists to create.

**Rule.** The countdown progresses only while a server-evaluated predicate holds on every tick of §14.23, not merely at the start. The target must be: not dead; not in the framework's downed, last-stand or bleed-out state; above `Config.Kidnap.MinTargetHealthPercent` by server-read health; and, where `Config.Kidnap.RequireRestraintState` is true, in a restraint state exposed server-side by `Config.Kidnap.RestraintStateProvider`, carried, or a passenger in a vehicle the accepting hunter is driving, with the restraining action attributed to that hunter. Where `Config.Kidnap.RequireHunterDamagedTarget` is true the server must additionally have recorded damage from that hunter to that target on this contract. Any failure is a hard countdown reset that the §7.4 grace period does not absorb — grace covers desync only — and the hunter's HUD names which condition failed. Where no restraint provider is configured, log a startup warning that the restraint condition is unenforced rather than silently passing it. The coercion list is server-editable so owners can add their own restraint resources, and the damage requirement is a separate toggle, because a compliant hostage walking uncuffed and a clean social-engineering kidnapping are both legitimate outcomes this rule would otherwise delete. Do not require a fixed drop location declared at creation — it contradicts §7.4's "physical location of the bounty creator" and strands a creator who has to move.

*Config:* Config.Kidnap.RequireConscious, Config.Kidnap.CoercionStates, Config.Kidnap.RequireRestraintState, Config.Kidnap.RestraintStateProvider, Config.Kidnap.MinTargetHealthPercent, Config.Kidnap.RequireHunterDamagedTarget

#### 14.25 Kidnap delivery has a creator obligation clock and a maximum hold

**Vector.** §7.4 makes creator presence a payout condition and §7.1 guarantees that a creator who walks away or logs off costs the contract nothing, with no expiry and no partial resolution defined. Once their enemy is hogtied in front of them the creator has already received the entire benefit, so paying is optional: escrow stays locked, the hunter is unpaid and holding a live hostage with no exit but an unpaid murder, and nothing in the spec ever ends the situation.

**Rule.** A hunter may raise "delivery ready" only while the server independently verifies that the target is alive and coerced per §14.24 and within the kidnap radius of the hunter — never on the hunter's assertion alone, or a hunter and a willing target can farm the baseline off an absent creator. On a valid raise the creator is notified and has `Config.Kidnap.CreatorArrivalMinutes` of *creator online time* to be present, paused while the creator is offline exactly as §7.1 pauses the penalty timer; a creator offline beyond `Config.Kidnap.CreatorAbsenceMinutes` resolves the contract through §9.2 as `delivery_defaulted` — `Config.Kidnap.DefaultPayoutPortion` (default baseline only) pays the hunter, the kidnapping bonus refunds to the creator, and the default is logged. A creator who disconnects inside a running countdown is recorded under §14.43 like any other party. Independently, `Config.Kidnap.MaxHoldMinutes` runs from the first contract-linked restraint, with an in-app warning to the hunter five minutes out and automatic resolution plus a required release at expiry, so the bonus never incentivises an unbounded hostage situation; the escrow resolves per the delivery-ready record above. A capture may not be initiated and a countdown may not progress inside `Config.SafeZones`. Do not add a mandatory target-facing kidnapping notice — it overrides the §7.3 and §5 config gates the owner deliberately set.

*Config:* `Config.Kidnap.CreatorArrivalMinutes, Config.Kidnap.CreatorAbsenceMinutes, Config.Kidnap.DefaultPayoutPortion, Config.Kidnap.MaxHoldMinutes, Config.Kidnap.SafeZoneBlocked`

#### 14.26 The mugshot is frozen or floor-debounced, and pushed only to subscribers

**Vector.** §7.2's "updates instantly" is not just a render requirement — it is a broadcast requirement hooked to a client-driven appearance event with no floor. A target masks up precisely so they are not recognised and the app re-renders them in the mask beside their legal name; an idle observer reads every image flip as a timestamped notification that the target just changed clothes; and a modified client fires the appearance event in a loop, multiplying one player's rate into a push to every client viewing the listing.

**Rule.** Replace §7.2's real-time requirement. `Config.Mugshot.Mode = 'frozen'` is the default: the mugshot is a single snapshot captured server-side at contract creation, stored as an lb-phone image reference, and never refreshed by appearance or outfit events — if the target changes appearance afterwards the stored photo stops matching, which is how a disguise is supposed to work. The listing states the capture time so hunters read a dated likeness as intended rather than as a bug. Under `Config.Mugshot.Mode = 'delayed'`, appearance changes set a dirty flag and exactly one re-render fires on the trailing edge of `Config.Mugshot.MinRefreshMinutes` per *target* citizen id regardless of how many signals arrive or who sends them, and §7.2's "instantly" is restated as a bounded delay. Never render for a player with no active contract and never while no client has the listing open; bound in-flight renders at `Config.Mugshot.MaxConcurrentRenders` with a FIFO queue and release every headshot handle on every exit path including timeout and supersession. Pushes go only to clients currently subscribed to the listing page the target appears on, coalesced at `Config.Mugshot.PushIntervalMs` — never a global broadcast. Do not implement a "store the last uncovered face" option: rendering an unmasked face for a masked player is a stronger disguise defeat than the bug it claims to fix. Replace §11's "Event-driven mugshots" row with "Frozen mugshot — prevents the listing acting as a live appearance feed and defeating disguises".

*Config:* `Config.Mugshot.Mode, Config.Mugshot.MinRefreshMinutes, Config.Mugshot.MaxConcurrentRenders, Config.Mugshot.RenderTimeoutMs, Config.Mugshot.PushIntervalMs`

#### 14.27 Every net event passes one gate before its handler body runs

**Vector.** §9.5 meters exactly four actions; opening the listing, opening the reward builder, refreshing a mugshot, fetching the ledger, subscribing to tracking and submitting a photo are all unmetered. Worse, §9.6's mandatory per-event blacklist re-check turns each rejected event into a player lookup — and if that lookup is DB-backed, one client loop becomes a database flood. The reward builder is the sharpest of these: §3.5 makes each open a full inventory walk plus four balance reads.

**Rule.** Every net event this resource registers is registered through one wrapper, and no handler body is reachable without passing it. In order, before any handler logic: a per-source token bucket at `Config.RateLimit.EventsPerSecond` with `Config.RateLimit.BurstSize`; a payload sanity gate rejecting any argument table over `Config.RateLimit.MaxEntries` or any string over `Config.RateLimit.MaxStringBytes`, as the handler's first action; and the §9.6 blacklist re-check reading a per-source job cache populated on player load and invalidated on job change and drop — never a database round trip. `Config.RateLimit.Default` applies automatically to any handler not given an explicit cooldown, so a new handler cannot ship without one. Sustained violation moves the source to a drop list for `Config.RateLimit.CooloffSeconds`, keyed on source and cleared on disconnect so a recycled id never inherits a stranger's penalty, and emits one aggregated admin line rather than one per event. A rejected event never writes to the database or the audit log. Expensive read paths additionally carry their own per-citizen-id cooldowns and are served from cache: the listing is rebuilt at most every `Config.Listing.CacheTTLMs` and paginated at `Config.Listing.PageSize` so N opens by N players cost one rebuild, and the builder's inventory and balance snapshot is cached per player for `Config.Reward.BuilderSnapshotTTLMs` — safe because §3.5 already revalidates everything on submit, so the snapshot is display data and a stale entry can never cause a bad escrow.

*Config:* Config.RateLimit.Default, Config.RateLimit.EventsPerSecond, Config.RateLimit.BurstSize, Config.RateLimit.MaxEntries, Config.RateLimit.MaxStringBytes, Config.RateLimit.CooloffSeconds, Config.Cooldowns.openBuilder, Config.Cooldowns.fetchListing, Config.Listing.CacheTTLMs, Config.Listing.PageSize, Config.Reward.BuilderSnapshotTTLMs

#### 14.28 Read handlers derive their result set from the requester, never from a submitted id

**Vector.** §9.6's server-authority list covers escrow, payouts, attribution, proximity and photo validation — read authorization is absent from it, and §9.9 describes the ledger's storage footprint rather than an access check. A fetch handler that takes a contract id and returns the row is a textbook IDOR that retroactively destroys both §4 anonymity systems by enumeration.

**Rule.** Every read handler builds its result set from the resolved requester's citizen id server-side — the ledger query binds that id as creator, target or winning hunter — and a contract id in a request is only ever used to select from that already-authorised set, never as the sole query key. A detail read for a contract the requester is not party to returns nothing, with a response that does not distinguish "not yours" from "does not exist". A photo reference is transmitted only to parties, and because the underlying host URL is publicly fetchable once known it must also be unguessable and must never appear in a listing, ledger preview or broadcast payload. Where party-scoping empties a field the creator expects to see — an anonymous hunter on their own completed contract — the UI shows a placeholder rather than an empty record.

*Config:* `Config.Ledger.Depth`

#### 14.29 Informant Data: authorised buyer, server-side selection, engaged pool, uniform response

**Vector.** §6.1 states in prose who may buy but no binding rule requires the server to verify the caller is party to the contract id they submitted, and contract ids are enumerable from the public listing. "One randomly selected hunter" implemented as ship-the-list-and-let-the-client-pick leaks the whole roster for free; "currently tracking" is undefined, so decoy accepts dilute the draw; and an undefined empty result becomes either a charge for nothing or a free, repeatable acceptance oracle.

**Rule.** Before anything is debited the server verifies that the resolved buyer's citizen id is the creator or the target of that specific contract id, that the contract is `active` or `accepted`, and that the buyer passes the §2 job check. The candidate pool is computed server-side from that contract's own acceptance rows and contains only hunters who both enabled Hunter Anonymity on it and have server-recorded engagement with the target — damage dealt, or presence within `Config.Informant.TrackingRadius` inside `Config.Informant.TrackingWindow`. Selection happens server-side and exactly one identity object is returned; the anonymous hunter list is never transmitted to any client under any circumstance. The response is indistinguishable whether or not a revealable hunter exists — same wording, same latency, no refund path — and the full premium is charged either way, stated plainly on the confirmation screen before payment, so the purchase is never an oracle for whether anyone has accepted. The reveal returns a display name and, under `Config.Informant.RevealMode = 'description'`, IC-followable detail only (build, outfit, vehicle and partial plate, last recorded district); a citizen id is never returned to a player in any mode and appears only in the conduct log. A repeat purchase on the same contract returns the same hunter for `Config.Informant.RerollLockMinutes` and is refused before payment inside that window, and total purchases per contract are capped by `Config.Informant.MaxPurchasesPerContract`. The reveal is delivered as a targeted one-shot response, never written into the listing payload, client state or the ledger. `Config.Cooldowns.informant` applies to *attempts*, not successes, so failed probes are throttled too, and every purchase is written to the audit log with buyer, contract, amount and whether a name was returned.

*Config:* Config.Informant.Cost, Config.Informant.RequireHunterActivity, Config.Informant.TrackingRadius, Config.Informant.TrackingWindow, Config.Informant.RevealMode, Config.Informant.RerollLockMinutes, Config.Informant.MaxPurchasesPerContract, Config.Informant.ChargeOnEmptyResult, Config.Cooldowns.informant

#### 14.30 The contract reason is content-controlled and permanently attributed

**Vector.** §8 and §10.1 give the reason only a length cap, a charset filter and render escaping — all injection controls. A slur, a real name, a home address or a rival server's invite is plain alphanumeric and passes unchanged, and it is broadcast to every criminal player beside the victim's mugshot, authored by someone §4 lets hide for free, with §9.8's money-only log recording nothing that links it back.

**Rule.** The reason string and the creator's true citizen id are written to the conduct log on every creation, unconditionally: Anonymous Mode is a player-facing display feature and never applies to logs, staff views or a report payload. `Config.Reason.Mode` supports `preset` — the creator picks from a config table and free text does not exist — `freetext`, and `off`. In `freetext` mode the server rejects on submit, never silently strips, any string matching a URL, invite or handle pattern (scheme prefixes, bare `domain.tld/`, known invite hosts) and any string exceeding `Config.Reason.MaxDigits` total digits, which blunts phone numbers and addresses; an owner-editable word list is normalised for spacing, repeats and leetspeak before matching and is treated as a speed bump that flags for staff, not as a control, because it will be bypassed and will false-positive on in-character names. Rejection messages are generic so the lists cannot be enumerated, and rejection happens before confiscation so a creator is never charged for a contract that publishes altered text. Every listing entry, ledger entry and completion alert carries a report action that posts the contract id, verbatim reason, true creator citizen id and reporter to `Config.Reports.Webhook`; a report flags for staff and never auto-hides the contract, never affects escrow, and never affects completion, or mass reports become their own griefing vector.

*Config:* Config.Reason.Mode, Config.Reason.Presets, Config.Reason.PatternDenylist, Config.Reason.WordDenylist, Config.Reason.MaxDigits, Config.Audit.LogReasonText, Config.Anonymity.AppliesToStaff, Config.Reports.Enabled, Config.Reports.Webhook

#### 14.31 §9.8 becomes a conduct log, with reports and admin commands

**Vector.** §9.8 defines its own scope as money — escrow, payout, refund, bailout, penalty — and calls itself the only way to adjudicate a dispute. Every behaviour worth adjudicating here is non-financial, and worse, the rows that do exist show a clean, correct money movement in exactly the cases that need investigating, so the log actively makes abuse look fine. No report path, no admin command and no staff carve-out from anonymity exists anywhere in the spec.

**Rule.** Extend §9.8 into two logs sharing one admin-readable sink: the existing financial log, and a conduct log recording per contract, with real citizen ids regardless of anonymity — creation (creator, target, verbatim reason, mode, escrow summary, bailout price, targeting identifier used); acceptance and abandonment; engagement record satisfied or absent with dwell seconds and closest approach; kill attribution with killer, weapon and server-computed distance; kidnap countdown start, every reset with a reason code, restraint applied and released; disconnect inside an engagement window; bailout with the target's full state at press time; informant purchase with what was revealed and to whom; photo submission with reference and hash; every terminal transition; and every eligibility or limit rejection naming which limit fired. Add ACE-gated admin commands, each writing its own audit line: void a contract with full refund through §9.2, purge a photo by contract id, ban a citizen id from creating contracts, flag a citizen id as untargetable (logged and expiring, since it silently removes a player from the mechanic), and dump one contract's full timeline in order. Fire the admin webhook on advisory flags only — a creator/target/hunter triad resolving more than `Config.Audit.RepeatPairThreshold` times in 24h, parties sharing an account identifier, a premium above the configured ratio threshold, cross-currency payouts, completions faster than the minimum age — never as an automatic block, because on a small server the same handful of criminals interact all night. The conduct log is never readable in-game by non-admins and never surfaced through the app.

*Config:* Config.Audit.LogAllActions, Config.Audit.RepeatPairThreshold, Config.Audit.AlertThresholds, Config.Alerts.AdminWebhook, Config.Admin.VoidContractCommand, Config.Admin.CreateBanCommand, Config.Admin.ProtectPlayerCommand, Config.Admin.DumpContractCommand

#### 14.32 Listing visibility for anonymous contracts follows the target's presence only

**Vector.** §7.1 ties visibility to both parties being online, and the creator is by definition online while watching, so every hide and unhide the target cannot explain by their own session is pure creator-presence signal — and FiveM leaks connect and disconnect everywhere. Intersect the set of players offline across a few hidden windows and Creator Anonymity collapses to one person, at a cost of one contract.

**Rule.** For a contract whose creator is anonymous, listing visibility depends on the *target's* presence only; the creator's session state must never be derivable from the listing, and no presence indicator — badge, label, greyed row, sort demotion or hidden-reason string — is rendered to any viewer. Creator-presence hiding remains permitted for non-anonymous contracts. Where an owner insists on creator-presence hiding for anonymous contracts, transitions are delayed by a uniform random `Config.Presence.HideJitterMinutes` and batched onto a fixed tick so no edge pins to a disconnect event. No machine-precision creation time — `created_at`, an age in seconds, or anything differenceable — is sent to a client for an anonymous contract; render coarse relative buckets, and do not order the listing by creation time while any anonymous contract is present, or sort position reconstructs the timestamp the payload withheld. This decoupling costs nothing that §7.1 was written to protect: §11 records that the rule exists to stop logging out dodging a penalty or voiding an escrow, and §3.6's paused timer plus §14.8's absolute clocks already handle that. Record in §11 that presence-linked visibility and anonymity are in direct tension, so this is not simplified back. State in §7.4 that a kidnapping countdown simply never starts while the creator is absent, and that the reason surfaced to the hunter must not re-leak presence.

*Config:* `Config.Presence.HideMode, Config.Presence.HideJitterMinutes, Config.Presence.HideDelayMinutes, Config.Listing.ExposeCreatedAt, Config.Listing.DefaultSort`

#### 14.33 Target selection is a scoped server-side search, not a roster

**Vector.** §3.1's "choose an online player" implies the client is handed a list of connected players, which is a live server roster shown to every criminal — information a FiveM client does not natively have, overriding whatever the owner decided about a hidden player list, and surfacing staff in noclip and players in instanced content. It is also a standing presence probe available before any contract exists.

**Rule.** No roster is ever sent to a client. `Config.Targeting.Mode = 'search'` sends a name fragment of at least `Config.Targeting.MinQueryLength` characters, rate-limited per §9.5 like any other action; the server returns at most `Config.Targeting.MaxResults` matches as short-lived opaque handles plus a display name, and the submit references the handle, never a citizen id. `Config.Targeting.Mode = 'nearby'` restricts candidates to players in the requester's own scope and is the immersive option. Excluded server-side from every result: players flagged invisible or in noclip, players in a different instance or routing bucket, players ineligible under §14.19, and anyone the owner's player-list setting hides. Every rejection anywhere in the creation path — unknown identifier, ineligible target, blacklisted job, limit hit, offline — returns one uniform failure string, so the create flow is neither an identity-enumeration oracle nor a presence probe, and presence is evaluated only after resolution and never distinguished in the response. `Config.Targeting.AllowBrowseList` exists as an explicit opt-out for owners who want the roster picker back; it defaults to false and its consequences are stated rather than discovered.

*Config:* `Config.Targeting.Mode, Config.Targeting.MinQueryLength, Config.Targeting.MaxResults, Config.Targeting.AllowBrowseList, Config.Targeting.RateLimit`

---

### Medium

#### 14.34 Acceptance is a conditional atomic write

**Vector.** §9.7 grants the atomic lock to completion only, and §3.3 states the exclusive invariant as behaviour with no concurrency rule behind it. Two accepts inside the same DB await window both land, so an exclusive contract has two holders and §3.6's penalty-timer ownership becomes incoherent.

**Rule.** Acceptance is a conditional atomic write, never a read-then-write. In `mysql` mode: `UPDATE bounties SET hunter = ?, state = 'accepted' WHERE id = ? AND state = 'active' AND hunter IS NULL`, succeeding only on one affected row. In `json` and `memory` modes the same compare-and-set runs inside the storage interface's per-contract lock with no yield between test and write. Competitive contracts append to the hunter list under the same lock. The same guarded write rejects acceptance when the contract is hidden under §7.1, when it is not in `active` state, when the accepted-hunter set is at the §14.38 cap, and when the resolved accepter is the contract's creator or target per §14.6. A losing racer receives the same "contract already taken" result the feature already needs.

*Config:* none (structural)

#### 14.35 Capture tokens have provenance, one live token per hunter-contract, and single use

**Vector.** §7.4 and §8 give the token only a lifetime — nothing says it is CSPRNG-generated, bound to one pending completion, consumed on submit, or kept out of broadcast payloads. A token derived from contract id and timestamp is the obvious lazy build and is guessable, which collapses the fourth factor of the four-factor binding. Unkeyed issuance also leaks: a token never submitted is never evicted.

**Rule.** The capture token is at least 128 bits from a server-side CSPRNG and is never derived from a contract id, timestamp or citizen id. It is stored server-side only, mapped to exactly one `(contractId, hunterCitizenId, deathRecordId)` triple, transmitted to that one hunter and never included in any listing, ledger or broadcast payload. It is consumed atomically on first submit by compare-and-delete, so two concurrent submits cannot both pass, and is invalidated on contract close, hunter abandonment or disconnect, target respawn, expiry and resource restart (§10.4). At most one live token exists per `(contractId, hunterCitizenId)`: re-opening the capture flow overwrites the prior token in place and the client closes any stale camera prompt, so table size is bounded by accepted-contract count and never by issuance rate. Token issuance joins §9.5's cooldowned actions at `Config.Photo.TokenIssuesPerMinute`, and a sweeper at `Config.Photo.TokenSweepIntervalSeconds` evicts expired tokens — the sweeper, not the submit path, is what bounds the table. Because consumption is single-use, the flow must expose an explicit reissue path for a still-open pending completion, or a submit that fails on a full inventory or a dropped upload burns a hunter's earned payout.

*Config:* `Config.Photo.TokenLifetime, Config.Photo.TokenIssuesPerMinute, Config.Photo.TokenSweepIntervalSeconds`

#### 14.36 Photo proximity binds to the recorded death scene, not the live ped

**Vector.** §7.4 measures distance to "the target player's entity", which stops being the corpse the moment they are revived or respawn — so a hunter loses a legitimately earned claim to an EMS revive, and their cheapest recovery is to kill the target again. Read the other way, a live-ped check passes next to the living target at a hospital with no corpse involved at all.

**Rule.** Since §7.4 already records killer, weapon and timestamp authoritatively at the moment of death, the target ped's live position adds no evidential value and is removed as a factor. A claim is valid when contract id, hunter id and an unexpired capture token validate — three of the existing four factors, unchanged — and the photo is captured within `Config.Photo.SceneRadius` of the death coordinates recorded server-side at the moment of death, within `Config.Photo.ClaimWindowMinutes` of that death. State explicitly that a revive or respawn cannot void a legitimate claim. `Config.Photo.OneClaimPerDeath` holds, the pending completion is swept at `Config.PendingCompletion.TTLSeconds` — which must comfortably exceed the capture-token lifetime and the server's respawn timer — and a completed contract starts the §14.5 per-target cooldown. Do not write "a hunter may not obstruct revival" as a spec requirement: no script check can enforce it and it belongs in the server's rules document.

*Config:* `Config.Photo.SceneRadius, Config.Photo.ClaimWindowMinutes, Config.Photo.OneClaimPerDeath, Config.PendingCompletion.TTLSeconds`

#### 14.37 Competitive contracts cap simultaneous hunters per target

**Vector.** §3.3 defines competitive acceptance as unbounded and §7.4's single-winner lock correctly makes many acceptors safe for the payout — but nothing counts accepted hunters per target, so one advertised contract can put every criminal on the server onto one victim, with the app supplying the listing, the mugshot and the tracking as a coordination layer.

**Rule.** Cap concurrently accepted hunters per *target* citizen id across all contracts naming them at `Config.Limits.MaxHuntersPerTarget`, enforced in the accept handler inside the §14.34 guarded write; further accepts are refused with the uniform failure string. Do not cap hunters per contract as the primary control — that guts §3.3's design intent. `Config.Competitive.MaxSimultaneousHunters` exists as a secondary per-contract cap for owners who want it, documented as contradicting §3.3, and `Config.Competitive.Enabled` allows removing the mode wholesale. Because a cap makes acceptance a race and therefore rewards accept-and-squat, a slot is freed by §14.8's abandonment and inactivity revoke; without those the cap becomes a way for a colluding hunter to protect the target. Hunters may be shown a bucketed count of current acceptors — a number only, never identities, and bucketed at low counts so a single acceptor plus one viewer is not an anonymity leak.

*Config:* `Config.Limits.MaxHuntersPerTarget, Config.Competitive.Enabled, Config.Competitive.MaxSimultaneousHunters, Config.Competitive.ShowHunterCount, Config.Contract.DefaultMode`

#### 14.38 Pair throttles and a minimum age before completion

**Vector.** §9.5's cooldowns are keyed to the actor and nothing is keyed to the pair, so create-accept-complete can all land inside a few seconds and the loop repeats at the create cooldown. That is what turns each transfer rail in this section from a one-off into a pipeline: a willing target killed as fast as they respawn, each cycle producing a clean `completed` row with a verification photo.

**Rule.** Two pair-scoped throttles, keyed to citizen id and account identifier per §14.7, enforced at creation and re-checked inside the §9.7 completion lock: `Config.Limits.PerPairCooldownMinutes` bars a new contract for the same creator-and-target pair and a completion for the same hunter-and-target pair inside the window, and `Config.Limits.PerPairDailyValue` caps rolling 24h value moved between the same pairs, read from the audit log. `Config.Contract.MinAgeBeforeCompletion` is measured from creation, and a completion arriving before it is **held**, not rejected, so a legitimate fast kill still pays — a hunter already in a firefight when the contract lands must not lose it to a metric. Rejection messages name the limit so it does not read as a bug. Do not attempt to require "meaningful resistance": a willing friend absorbs rounds as easily as none, so a damage threshold filters nothing and voids honest ambush kills.

*Config:* `Config.Limits.PerPairCooldownMinutes, Config.Limits.PerPairDailyValue, Config.Contract.MinAgeBeforeCompletion`

#### 14.39 Post-death immunity and an attributed-death cap

**Vector.** §7.4's protections are payout-correctness rules only; nothing grants the target a protected window. A contract closes at photo submission, not at the kill, so a hunter who simply delays the photo can kill the target repeatedly under one contract while tracking and the mugshot keep resolving through death and respawn, marking the hospital.

**Rule.** For `Config.Immunity.PostRespawnSeconds` after respawn, and while the target's ped is dead or downed, the server returns no tracking position and serves a stale cached mugshot (§14.22, §14.26). A contract voids and refunds through §9.2 once `Config.Limits.MaxAttributedDeathsPerContract` deaths attributed to accepted hunters have occurred under it — this is one mechanism, also serving as the non-monetary exit of §14.50, and only deaths attributed under §7.4 count, so a target cannot self-trigger it by dying to a friend. `Config.Immunity.AfterBailoutSeconds` and `Config.Immunity.AfterContractResolvedSeconds` bar any new contract naming that citizen id, and the §14.5 post-resolution cooldown starts on *every* terminal transition, not only `completed`, so paying or surviving buys real time rather than a gap before the next placement.

*Config:* `Config.Immunity.PostRespawnSeconds, Config.Immunity.AfterBailoutSeconds, Config.Immunity.AfterContractResolvedSeconds, Config.Limits.MaxAttributedDeathsPerContract`

#### 14.40 Notifications carry a per-recipient budget

**Vector.** §7.3 defines three notifications and rate-limits none. The Creator Alert fires per acceptance on an uncapped competitive contract; the Paranoid Alert fires per contract placed, so a group on the create cooldown delivers a steady stream into one victim's phone, making it unusable for banking, jobs and comms. Alert count also tells the target how many separate people want them dead, which §7.3 never intended to publish.

**Rule.** This resource enforces a per-recipient budget before calling lb-phone: `Config.Notifications.MaxPerRecipientPerMinute` and `MaxPerRecipientPerHour`. Over-budget notifications coalesce rather than drop — a dedupe key of recipient, event type and contract id collapses repeats, and surplus Creator Alerts aggregate into one "N operatives have accepted" message when the window closes. The Target Paranoid Alert fires at most once per target per `Config.Notifications.ParanoidCooldownMinutes` regardless of how many contracts were placed in it, with wording that does not imply a count, never re-fires for a contract merely un-hidden by §7.1, and is delayed by an independently drawn `Config.Notifications.ParanoidAlertJitter` from the listing publish so it does not timestamp the creation. A contract that leaves and re-enters `accepted` with the same hunter does not re-notify the creator. The Completion Alert is exempt from budgeting — it is the payout receipt and losing it looks like a lost contract. Because coalescing hides a second, distinct contract from a target genuinely under multiple hits, the bailout confirmation screen must state that clearing this contract does not guarantee no others exist.

*Config:* `Config.Notifications.MaxPerRecipientPerMinute, Config.Notifications.MaxPerRecipientPerHour, Config.Notifications.ParanoidCooldownMinutes, Config.Notifications.ParanoidAlertJitter`

#### 14.41 The engagement record is always computed; gating payout on it is the owner's choice

**Vector.** §7.4's payout conditions are exhaustive and none of them require the hunter to have interacted with the target — so the app supplies the IC justification and then verifies no IC act occurred. A rooftop kill on a name read off the listing validates every check, and the free-text reason is the entire roleplay requirement.

**Rule.** The server samples hunter-to-target proximity at no less than 1Hz from server-read coordinates and records, into the pending-completion state alongside killer, weapon and timestamp, whether an engagement record exists for `(contract, hunter, target)`: the hunter was within `Config.RP.InitiationRadius` for a cumulative `Config.RP.InitiationSeconds` inside the `Config.RP.InitiationWindowMinutes` preceding the death, together with the server-computed kill distance. **Recording is mandatory**; it is what makes an RDM ticket adjudicable under §14.31 and is the load-bearing half of this rule. Gating the payout on it is `Config.RP.RequireInitiation`, which defaults to false: when enabled, payout is refused where no engagement record exists and the kill distance exceeds `Config.RP.MaxEngagementDistance`. Never accept a client-asserted engagement or line-of-sight flag — the hunter is the party with the incentive to forge it, and FiveM offers the server no raycast. Owners must be told plainly what the gate costs: it makes long-range sniper contracts unpayable without prior loitering, it is satisfied by two players standing near each other doing nothing, and hunters who did everything right will lose payouts to a proxy metric. `Config.Contract.ReasonMinLength` buys typing, not motive, and is a presentation control only.

*Config:* `Config.RP.RequireInitiation, Config.RP.InitiationRadius, Config.RP.InitiationSeconds, Config.RP.InitiationWindowMinutes, Config.RP.MaxEngagementDistance, Config.Contract.ReasonMinLength`

#### 14.42 Disconnecting inside an active engagement is recorded

**Vector.** §7.1 and §3.6 handle logout correctly for escrow and the penalty clock, and neither addresses a party escaping an engagement in progress. A target hogtied at second 28 pulls the plug: the countdown resets, the contract merely hides, and §9.8's money-only log produces no row at all, so an admin has nothing to look at.

**Rule.** On `playerDropped`, when the dropping player is a party to a contract and any of (a) a kidnap countdown for that contract is running, (b) they are in a contract-linked hunter-applied restraint, or (c) they took damage from an accepted hunter within `Config.CombatLog.WindowSeconds`, write a `combat_log_suspected` record to the conduct log carrying the contract id, both real citizen ids, countdown progress, elapsed-since-last-damage and timestamp. This applies to a creator who drops inside a running countdown as well as to a target. `Config.CombatLog.Policy` defaults to `flag_only`: the evidentiary record is the reliable part, because a crash, a router drop and an alt-F4 are indistinguishable server-side. `hold_state` — restraint and countdown progress persisted and reapplied on reconnect within `Config.CombatLog.HoldMinutes` — is opt-in for that reason. A `credit_hunter` policy is not offered at all: paying a hunter for a target's disconnect gives hunters a direct incentive to induce one. All three checks are suppressed during a server shutdown or resource stop, mirroring §10.4, so a restart is never logged as a combat log.

*Config:* `Config.CombatLog.Policy, Config.CombatLog.WindowSeconds, Config.CombatLog.HoldMinutes`

#### 14.43 Ledger content, anonymity scope, and photo lifecycle

**Vector.** §6.3 says only "stores the past 10 completed contracts", so the implementer silently decides whether anonymity survives completion and whether a hunter's photo of the victim's corpse renders in the victim's own app. §9.9's reference-not-blob rule means the image lives on a media host behind an unguessable but publicly fetchable URL, and evicting the eleventh ledger row deletes nothing — with no index, deletion is impossible even for an owner who wants it.

**Rule.** State the scope of §4's guarantee explicitly rather than letting the ledger define it by omission: where a contract was anonymous, the ledger row stores an opaque contract id and the display label only — no citizen id and no name is *written*, not written-and-hidden — and the opaque id is visible and copyable so a player can still raise a support ticket. A hunter-captured photo is never rendered in the target's view; the target's history shows contract id, outcome, timestamp and, subject to anonymity, the counterparty. Maintain a photo index mapping reference to `{contract id, target, hunter, created_at, expires_at}`; without it deletion is impossible in principle, so it is required even where expiry is off. A photo is deleted on ledger eviction and after `Config.Ledger.PhotoRetentionDays`, whichever comes first, with the ledger row surviving and showing "photo expired" rather than a broken image; deletion invokes the configured host's delete API where one exists, and the storage adapter declares whether it supports deletion so a startup warning names the host when retention is unenforceable there. `Config.Ledger.StorePhotos = false` keeps the ledger and drops images entirely. A hard-coded ceiling caps ledger depth so the §8 config value cannot turn a ten-entry trophy room into a dossier.

*Config:* `Config.Ledger.Depth, Config.Ledger.MaxDepthHardCap, Config.Ledger.StorePhotos, Config.Ledger.ShowPhotoToTarget, Config.Ledger.PhotoRetentionDays`

#### 14.44 The log's write path, distribution, retention and purge are bounded

**Vector.** §8 exposes no retention or rotation entry for an append-only log and §10.2 grants it no exemption from the debounced whole-document rewrite, so an implementer who puts it in the state document makes every flush O(total log size). Separately, the FiveM norm is a Discord webhook whose URL lives in config.lua and travels with a shared or resold resource — which widens the audience for a log that now carries verbatim reason text and true identities from "people with DB access" to "anyone who ever saw that URL". And QBox supports character deletion with no hook here at all, so a pending escrow row for a deleted character can never resolve.

**Rule.** The log is never part of the debounced state document: in json mode it is a daily-rotated, genuinely append-only file written with plain appends, never a read-modify-write; in mysql mode it is its own table. Writes are buffered into a bounded queue flushed as one batched insert every `Config.Audit.FlushIntervalMs` — never one insert per event and never synchronously on the payout path, since it is the contract state transition, not the audit row, that §14.11 requires to flush. The authoritative copy is local: identity fields are never included in any outbound webhook or console-mirrored line, which carries contract id, source, amount and timestamp only, and webhook mirroring defaults to off. An in-game identity lookup for dispute adjudication is ACE-gated, requires a free-text reason, and writes its own access record. `Config.Audit.RetentionDays` prunes at startup and daily, with pending-escrow entries exempt because an unpaid refund may outlive the cap, and the log's own retention and access are treated as a data-handling obligation the owner is told about. A purge hook on character deletion and permanent ban releases or writes off any pending escrow first, then deletes photos via the §14.43 index, then drops identity fields referencing that character while leaving financial entries intact with the identity replaced by the contract id — purge on ban is delayed by default so a ban appeal or duplication investigation still has its evidence. The same code path is exposed as an admin purge command, and the spec carries a short table of what this resource retains, where, and for how long.

*Config:* Config.Audit.FlushIntervalMs, Config.Audit.MaxQueueSize, Config.Audit.RetentionDays, Config.Audit.Webhook, Config.Audit.IdentityRevealAce, Config.Audit.LogReads, Config.Retention.PurgeOnCharacterDelete, Config.Retention.PurgeOnBan

#### 14.45 Weapon serials and unique item identifiers never leave the holder

**Vector.** §3.4 escrows weapons carrying serial and attachments and §9.4 snapshots the serial, and nothing says what a hunter's view of the reward composition contains — so the escrow record's fields are shipped straight to the listing. A weapon serial is a globally unique, cross-resource identifier traceable through police and MDT resources, rendered beside an "Anonymous" label.

**Rule.** Weapon serials and any unique or persistent item identifier are never sent to a client other than the current holder, on anonymous and non-anonymous contracts alike. The listing and hunter detail views render weapon class, attachments and condition; unique items render as name and count. The serial stays in the §9.1 escrow record, which §9.2's release routine reads server-side, so nothing downstream changes. At reward-build time the creator is warned before confirming anonymity when a selected item is uniquely identifiable in-world. Do not extend this to bracketing or rounding monetary totals: hunters need exact reward values to choose between contracts, and approximate payouts invite "the script paid me less than advertised" disputes.

*Config:* `Config.Listing.HideWeaponSerials, Config.Listing.WarnOnUniqueItem`

#### 14.46 Fees fold into the atomic escrow debit and carry generic transaction memos

**Vector.** §4 charges the anonymity fee "before anonymity is granted", which places it outside the single atomic confiscation §3.5 requires — so a fee that succeeds followed by an escrow that fails leaves the player charged for a contract that does not exist, which §11's "nothing is taken if any part fails" plainly meant to prevent. A fixed-amount debit labelled with the feature is also a distinctive marker in any transaction feed.

**Rule.** The anonymity fee is charged inside the single atomic escrow debit of §3.5 — one combined transaction, so a failed escrow cannot leave a paid fee behind. All transactions this resource writes carry one generic description (`Config.Transactions.GenericMemo`) identical for anonymous and non-anonymous contracts and for the informant premium and bailout premium, so the transaction record does not label the feature. The app's own confirmation screen shows the itemised breakdown to the payer before they confirm, and the app retains a per-player, self-only breakdown so "why was I charged" is answerable; the audit entry records each fee as its own line item even though the bank transaction is combined.

*Config:* `Config.Anonymity.CreatorFee, Config.Anonymity.HunterFee, Config.Transactions.GenericMemo`

#### 14.47 Boot-time configuration validation

**Vector.** Several config combinations produce a system that is coherent in code and broken in play: bailout enabled while target visibility of own contract is off means §5's escape exists and is unreachable; a payout conversion rate better than the server's launderette turns §6.2 into a laundry; a missing playtime or restraint provider silently disables an eligibility or coercion check. Nothing warns the owner at boot.

**Rule.** On resource start the server validates its own configuration and refuses to start, or prints a loud console error naming the contradiction, for each of: a bailout path enabled while `Config.Target.SeeOwnContract` is false — in which case visibility is forced on, or the owner must have enabled a non-monetary exit; no non-monetary exit enabled at all (the §14.8 online-time expiry, item payment, or the §14.39 attributed-death cap), so a broke target always has at least one available action; `Config.Payout.ConversionRate` better than `Config.Payout.MaxSafeRate`; a missing playtime provider while §14.19's floors are set (which then fail closed); a missing restraint provider while §14.24 requires one (which is then unenforced); and a media host that cannot delete while `Config.Ledger.PhotoRetentionDays` is set. Validation results are printed once at startup, not discovered by a player hitting a dead end.

*Config:* `Config.Boot.ValidateCounterplayConfig, Config.Target.SeeOwnContract, Config.Bailout.RequiresVisibility, Config.Bailout.AllowItemPayment`

---

### Low

#### 14.48 json persistence is sharded per contract

**Vector.** §10.2 mandates temp-file-plus-rename and never says what the unit of the swap is, so the natural reading is one state document holding every contract — a synchronous whole-dataset encode on the main thread every flush, whose fixed cost grows permanently with every contract created. §14.11's synchronous financial writes make that cost land on every payout.

**Rule.** Persistence in json mode is sharded: one file per contract, keys sanitised per §10.2's existing rule, plus a small index file. A flush rewrites only dirty shards, each still by temp-file-plus-rename so the atomicity guarantee is unchanged, and flush cost is O(changed contracts), not O(total contracts). Bound each flush at `Config.Database.Json.MaxDirtyShardsPerFlush`, deferring the remainder. The audit log is outside the shard set entirely (§14.44). Restate §10.2's halt rule for the sharded layout — a malformed *index or shard* halts the resource — or one corrupt contract file will be silently skipped and its escrow lost, which is the exact failure that rule was written to prevent. Emit a startup warning above `Config.Database.Json.WarnContractCount`.

*Config:* `Config.Database.Json.MaxDirtyShardsPerFlush, Config.Database.Json.WarnContractCount`

#### 14.49 memory-mode disconnect cancel is scoped to unaccepted contracts

**Vector.** §10.3 requires contracts to be cancelled and refunded when the creator disconnects, while §7.1 states that nothing about a player being offline may alter contract state and §11 lists logging out to void an escrow as a failure the design prevents. The two are written as binding and contradict, so an implementer guesses — and the permissive guess lets a creator pull the plug as a hunter closes on the target.

**Rule.** Resolve the conflict in §10.3 and record the exception in §7.1 itself rather than leaving it only in §10.3. Disconnect-cancel applies only to contracts still in `active` state with no hunter attached. A contract in `accepted` state survives the creator's disconnect and its penalty timer pauses per §7.1; if it completes while the creator is offline the hunter is paid as normal, since the recipient is online and §9.3's offline problem does not arise. Escrow still open at resource stop is released to the creator, and on failure is logged as an unrecoverable loss with amounts — unavoidable in a mode with no durability, which is why the memory-mode warning must appear in the app UI at contract creation and not only in the console. Every disconnect-cancel is written to the audit log.

*Config:* `Config.Database.Mode`

#### 14.50 A creation gate that is not a resource stop

**Vector.** Stopping the resource is already a safe kill switch in both production modes, but it strands hunters mid-contract and mid-countdown with no notice. An admin facing a wave of bounty-related tickets at 3am has no way to stop new contracts while letting in-flight ones resolve.

**Rule.** `Config.Enabled` plus an ACE-gated admin command suspends contract *creation and acceptance* only, leaving open contracts fully resolvable. The suspension is a creation gate and never a state change — escrow untouched, §9.10 unaffected — exactly as §7.1's hiding is a display filter. It is announced in-app so hunters are not racing a window they cannot win, and §3.6 penalty timers pause for its duration under the same rule that pauses them for offline players. `Config.MaxActiveContractsServerWide` gives a throughput ceiling and `Config.ActiveHours` an optional, empty-by-default scheduling control; both refuse contracts for reasons no player can see, so the in-app announcement is what makes them tolerable. Do not gate the app on staff presence — it ties a core gameplay loop to a rota and goes dark exactly when players most want something to do.

*Config:* `Config.Enabled, Config.ActiveHours, Config.MaxActiveContractsServerWide`

#### 14.51 Bounty Cleanse is discreet, not anonymous

**Vector.** §5 promises the target can "anonymously" buy out, but the contract names the target, exactly one player can pay, the money comes from that player's own pocket, and §9.8 logs both parties — there is nobody the target could be anonymous from. A player who pays believing otherwise and is then confronted in character will reasonably conclude the script lied to them.

**Rule.** Delete "anonymously" from §5 and state what happens: the target pays the creator-specified premium to close the contract; the creator is refunded and paid the premium and can infer the target bought out. The buyout confirmation screen says the same before the target pays. Where an owner wants partial discretion, route the premium through §9.2 with the same generic memo as an expiry refund and omit the closure-reason notification to the creator (`Config.Bailout.DiscloseClosureReasonToCreator`) — but the spec and the confirmation screen must both say this obscures the closure and never hides it, since the arrival of a premium alongside returned escrow is itself the signal. The audit entry records the true reason regardless of what the creator is told.

*Config:* `Config.Bailout.DiscloseClosureReasonToCreator`

---

## 15. Progression & Reputation

The bounty board is part of the server's criminal economy, not a parallel one.

### 16.1 Criminal progression
Completing a contract awards **trust in the server's existing criminal progression** (`sc-blackmarket` on this server), so hunting feeds the same rank and access ladder as every other criminal activity. A live delivery is worth more than a kill.

- Config-gated and resource-detected: if the progression resource is absent, the award is skipped silently.
- A progression failure **never** affects the payout. Money moves first, and the award is attempted afterwards inside a guard — a broken integration must not cost a hunter what they earned.

### 16.2 Hunter record
Each player carries four counters: contracts **completed**, **placed**, **failed** and **survived**, plus a standing derived from them (`Unproven` → `Known` → `Established` → `Notorious`).

- Shown to the player in their Ledger.
- Shown to a **creator** for each operative on their contract — attached to the alias, never to an identity — so anonymity and reputation coexist: a client can judge whether the operative who took their contract is any good without learning who they are.
- A success rate is withheld until there are at least three resolved contracts. One completed contract is not a hundred percent record.

### 16.3 What counts
| Event | Counter |
|---|---|
| Slot claimed by a hunter | `completed` for the hunter |
| Contract created | `placed` for the creator |
| Hunter abandons an accepted contract | `failed` for the hunter |
| Target buys out, or the contract expires | `survived` for the target |

---

## 16. Configuration Appendix

Every `config.lua` entry implied by §8, §10 and §15, as one list. Defaults belong in the file itself; this is the surface an implementer must cover.

- Config.Enabled — master switch; false suspends creation and acceptance only
- Config.ActiveHours — optional creation window, empty by default
- Config.MaxActiveContractsServerWide — server-wide throughput ceiling
- Config.RateLimit.Key = 'license' — all economic counters keyed to account, citizenid secondary
- Config.RateLimit.Default — cooldown applied to any handler with no explicit one
- Config.RateLimit.EventsPerSecond — per-source token bucket refill
- Config.RateLimit.BurstSize — token bucket depth
- Config.RateLimit.MaxEntries — max entries in any client argument table
- Config.RateLimit.MaxStringBytes — max bytes in any client string
- Config.RateLimit.CooloffSeconds — drop-list duration after sustained violation
- Config.Cooldowns.cancel — per-citizenid cancellation cooldown
- Config.Cooldowns.informant — applies to informant attempts, not successes
- Config.Cooldowns.openBuilder — reward-builder open cooldown
- Config.Cooldowns.fetchListing — listing fetch cooldown
- Config.Limits.MaxActiveContractsPerTarget — live contracts naming one citizenid (default 1)
- Config.Limits.TargetCooldownAfterResolveSeconds — bar after any resolution on that target
- Config.Limits.SameCreatorSameTargetCooldownHours — same creator re-naming same target
- Config.Limits.MaxContractsPerTargetPerDay — rolling 24h per target
- Config.Limits.MaxHuntersPerTarget — concurrently accepted hunters across all contracts on one target
- Config.Limits.MaxActivePerCreator — open contracts per creator account
- Config.Limits.MaxActiveGlobal — open contracts server-wide
- Config.Limits.CreatesPerHour — rolling creation budget per account
- Config.Limits.DailyEscrowValue — rolling 24h fiat value escrowed per account
- Config.Limits.MinContractValue — minimum summed escrow value at submit
- Config.Limits.MinItemCount — minimum items for an item-only contract
- Config.Limits.PerPairCooldownMinutes — creator+target and hunter+target pair throttle
- Config.Limits.PerPairDailyValue — rolling 24h value between the same pair
- Config.Limits.MaxAttributedDeathsPerContract — voids and refunds the contract at the cap
- Config.Limits.MinCreatorPlaytimeHours — playtime floor to create a contract
- Config.Limits.BurstWindowSeconds — window for the coordinated-targeting webhook
- Config.Limits.BurstDistinctCreatorsTrigger — distinct creators on one target in that window
- Config.Contract.AbsoluteTTLHours — never-paused garbage-collector lifetime (days, not hours)
- Config.Contract.MaxOnlineLifetimeMinutes — target online time before expiry (survive-the-clock exit)
- Config.Contract.MaxPausedHours — ceiling on total accumulated pause
- Config.Contract.MinAgeBeforeCancel — blocks escrow-as-momentary-stash
- Config.Contract.MinAgeBeforeCompletion — completions before this are held, not rejected
- Config.Contract.DefaultMode — 'exclusive' or 'competitive'
- Config.Contract.ReasonMinLength — presentation control only
- Config.Cancel.AllowAfterAccept = false — cancel forbidden once a hunter holds it
- Config.Cancel.FeeFraction — paid to the accepted hunter when cancel-after-accept is enabled
- Config.Cancel.RefundDelaySeconds — delay before cancelled escrow returns
- Config.Exclusive.InactivityRevokeSeconds — no recorded engagement releases the hold
- Config.Competitive.Enabled — allows removing competitive mode wholesale
- Config.Competitive.MaxSimultaneousHunters — secondary per-contract cap (contradicts §3.3; document it)
- Config.Competitive.ShowHunterCount — bucketed acceptor count, never identities
- Config.Escrow.PerSourceCaps — per-source ceilings, checked over baseline + bonus
- Config.Escrow.GlobalMaxContractValue — checked over baseline + bonus combined
- Config.Escrow.ItemBlacklist — matched against the server-read item name
- Config.Bonus.MaxPercent — ceiling on the kidnapping percentage multiplier
- Config.Payout.AllowCrossCurrency = false — source-faithful release by default
- Config.Payout.ConversionRate — per source pair, payout only, validated at boot
- Config.Payout.MaxSafeRate — boot-time ceiling; a better rate warns loudly
- Config.Payout.MaxConvertedPerDay — rolling 24h converted value per creator
- Config.Transfers.Handler — bridge used for premiums and conversions so server transfer rules apply
- Config.Transactions.GenericMemo — one description for every transaction this resource writes
- Config.Bailout.MaxAmount — absolute premium ceiling, clamped silently at creation
- Config.Bailout.MaxMultipleOfEscrow — premium ceiling relative to escrow value
- Config.Bailout.MinPremiumPctOfEscrow — premium floor relative to escrow value
- Config.Bailout.MaxPercentOfTargetNetWorth — payment-time clamp, never surfaced to the creator
- Config.Bailout.PaymentOrder = {'cash','bank'} — sum across accounts in order, all or none
- Config.Bailout.MaxPerPairPerDay — collected bailouts per creator+target per 24h
- Config.Bailout.CreatorShare — remainder burned to a sink so extortion decays
- Config.Bailout.MinContractAgeSeconds — blocks deposit-and-withdraw on demand
- Config.Bailout.CombatLockoutSeconds — refuses buyout near player damage
- Config.Bailout.BlockedWhileRestrained — refuses buyout while downed, restrained, carried or in a trunk
- Config.Bailout.ProcessingDelaySeconds — contract stays completable; a completion voids and refunds
- Config.Bailout.HunterCompensationPct — surcharge on top of the creator's figure, paid to accepted hunters
- Config.Bailout.BlockedWhileAccepted = false — alternative to compensation
- Config.Bailout.WorksWhileCreatorOffline = true — bailout exempt from the §7.1 presence filter
- Config.Bailout.AllowItemPayment — non-monetary exit for a broke target
- Config.Bailout.RequiresVisibility — boot check couples bailout to target visibility
- Config.Bailout.DiscloseClosureReasonToCreator — obscures the closure, never hides it
- Config.Target.SeeOwnContract — forced true when any bailout path is enabled
- Config.Penalty.EscrowAtAccept = true — staked from the hunter into the contract's escrow record
- Config.Penalty.MaxAmount — absolute ceiling, clamped silently at creation
- Config.Penalty.MaxFractionOfEscrow — ceiling relative to escrow value
- Config.Penalty.MinWindowMinutes — deadline cannot be set to an impossible value
- Config.Penalty.RequireDisclosureOnAccept = true — accept payload must echo amount and deadline
- Config.Penalty.SinkFraction — minority share of a collected penalty burned
- Config.Penalty.MaxPausedDuration — past the cap the penalty voids and the stake returns
- Config.Penalty.GraceBeforeForfeit — hunter abandonment recovers the stake before this
- Config.Penalty.VoidIfHunterKilledByCreatorOrTarget — scoped to kills of the hunter
- Config.Penalty.PauseZones — zones where the hunter has no lawful means of attack
- Config.Completion.DeathReportWindowMs — corroborating weaponDamageEvent window
- Config.Completion.MaxWeaponRange — per weapon hash, checked at the reported timestamp
- Config.PendingCompletion.TTLSeconds — swept; must exceed token lifetime and respawn timer
- Config.AntiCheat.MaxPositionDeltaPerSample — per vehicle/state table, not one number
- Config.Photo.Enabled — false completes on the remaining factors with no image
- Config.Photo.AllowedHosts — literals in config, never client input
- Config.Photo.RequireGalleryOwnership — falls back to host allowlist with a startup warning
- Config.Photo.MaxAgeSeconds — upload must postdate the capture token
- Config.Photo.LogHashToAudit — reference plus SHA-256 written to the log
- Config.Photo.SceneRadius — distance from recorded death coordinates, not the live ped
- Config.Photo.ClaimWindowMinutes — from the recorded death
- Config.Photo.OneClaimPerDeath — one claim per recorded death
- Config.Photo.TokenLifetime — capture-token expiry
- Config.Photo.TokenIssuesPerMinute — token issuance joins the §9.5 cooldowned actions
- Config.Photo.TokenSweepIntervalSeconds — sweeper, not the submit path, bounds the table
- Config.Kidnap.TickMs — one shared server tick for all countdowns
- Config.Kidnap.ArmRadius — squared-distance arm gate
- Config.Kidnap.MaxConcurrentCountdowns — refuse to arm and notify; never shed one in progress
- Config.Kidnap.SampleIntervalMs — server-side sampling interval for the countdown
- Config.Kidnap.MaxTotalGraceMs — one grace budget for the whole countdown, not per break
- Config.Kidnap.RequireConscious = true — not dead, not downed, above the health floor
- Config.Kidnap.MinTargetHealthPercent — health floor for a live delivery
- Config.Kidnap.CoercionStates — server-editable restraint/carry/passenger states
- Config.Kidnap.RequireRestraintState — off logs a startup warning that the check is unenforced
- Config.Kidnap.RestraintStateProvider — names the server-readable restraint resource
- Config.Kidnap.RequireHunterDamagedTarget — separate toggle for RP-heavy servers
- Config.Kidnap.CreatorArrivalMinutes — creator online time to attend a verified delivery
- Config.Kidnap.CreatorAbsenceMinutes — beyond this the contract resolves as delivery_defaulted
- Config.Kidnap.DefaultPayoutPortion — baseline only by default on a creator default
- Config.Kidnap.MaxHoldMinutes — from first contract-linked restraint, with a 5-minute warning
- Config.Kidnap.SafeZoneBlocked — no capture initiation or countdown progress inside safe zones
- Config.Tracking.Mode = 'ping' — coarse search area, never raw coordinates
- Config.Tracking.UpdateIntervalMs — one shared tick, never per frame
- Config.Tracking.CoarseRadius — grid cell or district granularity
- Config.Tracking.AcceptedHuntersOnly = true — per-recipient addressing
- Config.Tracking.DisabledWhileDead = true — plus the post-respawn window
- Config.Tracking.MaxActiveStreams — server-wide ceiling on live streams
- Config.SafeZones — polygons where tracking returns nothing
- Config.SafeZones.BlockVerification = true — photo verification refuses inside them
- Config.Mugshot.Mode = 'frozen' — snapshot at creation; 'delayed' is the alternative
- Config.Mugshot.MinRefreshMinutes — floor per target citizenid in delayed mode
- Config.Mugshot.MaxConcurrentRenders — FIFO queue for headshot renders
- Config.Mugshot.RenderTimeoutMs — handle released on every exit path
- Config.Mugshot.PushIntervalMs — coalesced push to listing subscribers only
- Config.Targeting.Mode = 'search' | 'nearby' — no roster mode
- Config.Targeting.MinQueryLength — minimum name fragment for a search
- Config.Targeting.MaxResults — capped opaque handles returned
- Config.Targeting.AllowBrowseList = false — explicit opt-out with stated consequences
- Config.Targeting.RateLimit — search attempts per citizenid
- Config.Targeting.BlacklistedTargetJobs — separate from the §2 app-access blacklist
- Config.Targeting.AllowTargetingBlacklistedJobs = false — requires the out-of-app path when true
- Config.Targeting.OutOfAppAlertFallback — chat alert and console buyout for blacklisted-job targets
- Config.Targeting.BlockIfCuffedOrDead — degrades to a no-op with a warning if unreadable
- Config.Immunity.MinTargetPlaytimeHours — targeting floor, fails closed
- Config.Immunity.MinTargetSessionMinutes — stops login-camping
- Config.Immunity.PostRespawnSeconds — tracking and mugshot suppressed
- Config.Immunity.AfterBailoutSeconds — no new contract may name that citizenid
- Config.Immunity.AfterContractResolvedSeconds — starts on every terminal transition
- Config.Playtime.Export — single provider, falls back to character creation date
- Config.Playtime.FailClosed = true — unresolvable playtime is below every minimum
- Config.RP.RequireInitiation = false — recording is mandatory; gating payout is the owner's choice
- Config.RP.InitiationRadius — dwell radius for the engagement record
- Config.RP.InitiationSeconds — cumulative dwell required
- Config.RP.InitiationWindowMinutes — window preceding the death
- Config.RP.MaxEngagementDistance — server-computed kill distance ceiling when gating is on
- Config.CombatLog.Policy = 'flag_only' — 'hold_state' is opt-in; credit_hunter is not offered
- Config.CombatLog.WindowSeconds — recent-damage window for a suspected combat log
- Config.CombatLog.HoldMinutes — restraint and countdown reapplied on reconnect under hold_state
- Config.Informant.Cost — premium, charged whether or not a name is returned
- Config.Informant.RequireHunterActivity — pool requires recorded engagement
- Config.Informant.TrackingRadius — proximity that counts as tracking
- Config.Informant.TrackingWindow — recency for the tracking pool
- Config.Informant.RevealMode = 'description' | 'name' — citizenid never returned in either
- Config.Informant.RerollLockMinutes — sticky reveal per contract
- Config.Informant.MaxPurchasesPerContract — enumeration cap
- Config.Informant.ChargeOnEmptyResult = true — uniform response, no refund oracle
- Config.Anonymity.CreatorFee — folded into the atomic escrow debit
- Config.Anonymity.HunterFee — folded into the atomic escrow debit
- Config.Anonymity.AppliesToStaff = false — never applies to logs, staff views or reports
- Config.Presence.HideMode — 'never' or 'delayed' for anonymous contracts
- Config.Presence.HideDelayMinutes — base delay before a visibility transition
- Config.Presence.HideJitterMinutes — random jitter so no edge pins to a disconnect
- Config.Listing.PageSize — server-side pagination
- Config.Listing.CacheTTLMs — one rebuild serves N opens
- Config.Listing.ExposeCreatedAt = false — no machine-precision creation time for anonymous contracts
- Config.Listing.DefaultSort = 'reward' — never creation order while anonymous contracts are listed
- Config.Listing.HideWeaponSerials — forced; serials never leave the holder
- Config.Listing.WarnOnUniqueItem — warns the creator before anonymity is confirmed
- Config.Reward.BuilderSnapshotTTLMs — display-only cache; §3.5 still revalidates on submit
- Config.Reason.Mode = 'preset' | 'freetext' | 'off'
- Config.Reason.Presets — config table of RP reasons for preset mode
- Config.Reason.PatternDenylist — URL, invite and handle shapes, rejected on submit
- Config.Reason.WordDenylist — normalised before matching; advisory, not a control
- Config.Reason.MaxDigits — blunts phone numbers and addresses
- Config.Notifications.MaxPerRecipientPerMinute — per-recipient budget before lb-phone is called
- Config.Notifications.MaxPerRecipientPerHour — rolling hourly budget
- Config.Notifications.ParanoidCooldownMinutes — one alert per target per window
- Config.Notifications.ParanoidAlertJitter — independent draw from the publish delay
- Config.PendingEscrow.MaxPerPlayer — at the cap the player cannot create new contracts
- Config.PendingEscrow.MaxRetriesPerLogin — bounded retries per session
- Config.PendingEscrow.RetryBackoffSeconds — exponential backoff between retries
- Config.PendingEscrow.LoginRetryDelayMs — randomised so reconnect waves do not converge
- Config.PendingEscrow.DeadLetterAfterDays — admin-visible queue; never forfeiture
- Config.Audit.LogAllActions = true — conduct log alongside the financial log
- Config.Audit.LogReasonText = true — verbatim reason with the true creator citizenid
- Config.Audit.FlushIntervalMs — batched queue flush, never on the payout path
- Config.Audit.MaxQueueSize — bounded audit write queue
- Config.Audit.RetentionDays — pruned at startup and daily; pending-escrow entries exempt
- Config.Audit.Webhook = false — mirrored lines never contain identity
- Config.Audit.IdentityRevealAce — ACE for in-game identity lookup, requires a reason
- Config.Audit.LogReads — identity lookups write their own access record
- Config.Audit.RepeatPairThreshold — advisory flag for repeated triads in 24h
- Config.Audit.AlertThresholds — advisory flags only, never automatic blocks
- Config.Alerts.AdminWebhook — advisory flags and coordinated-targeting bursts
- Config.Reports.Enabled — report action on listings, ledger entries and completion alerts
- Config.Reports.Webhook — report destination
- Config.Admin.VoidContractCommand — ACE-gated void with full refund
- Config.Admin.PurgePhotoCommand — removes a photo from every ledger row by contract id
- Config.Admin.CreateBanCommand — bars a citizenid from creating contracts
- Config.Admin.ProtectPlayerCommand — untargetable flag; logged and expiring
- Config.Admin.DumpContractCommand — one contract's full timeline in order
- Config.Ledger.Depth — configured history depth
- Config.Ledger.MaxDepthHardCap — hard ceiling the config value cannot exceed
- Config.Ledger.StorePhotos — false keeps the ledger and drops images
- Config.Ledger.ShowPhotoToTarget = false — hunter photos never render in the target's view
- Config.Ledger.PhotoRetentionDays — with the photo index; row survives the photo
- Config.Retention.PurgeOnCharacterDelete — releases pending escrow first, then purges identity
- Config.Retention.PurgeOnBan = 'delayed' — preserves evidence for appeals
- Config.Database.DebounceMs — non-financial writes only
- Config.Database.Json.SyncOnFinancialWrite = true — financial transitions bypass the debounce
- Config.Database.Json.MaxDirtyShardsPerFlush — bounds each sharded flush
- Config.Database.Json.WarnContractCount — startup warning above this stored count
- Config.AntiCollusion.CheckSharedIdentifiers — compares creator, hunter and target identifiers
- Config.AntiCollusion.FlagOnly = true — shared households flag, never auto-block
- Config.Boot.ValidateCounterplayConfig = true — refuse or warn on contradictory configuration

---
## 17. Design Rationale

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
