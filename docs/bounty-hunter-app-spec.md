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

### 3.6 Failure Penalty Configuration

An optional, config-backed setting allowing the creator to enforce a **financial penalty** (a specific amount of money) if an accepted hunter fails to complete an **exclusive** contract within a designated time parameter.

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
A bounty appears on the public bounty list **only if both the creator and the target are currently online**. If either logs out, the bounty is temporarily **hidden** from active listings until both return. Hidden ≠ cancelled; escrow and state persist.

### 7.2 Real-Time Visuals
Each bounty listing features a dynamic, **real-time mugshot** of the target. If the target changes outfit or appearance, the image in the app updates **instantly**.

### 7.3 Automated lb-phone Notifications

| Event | Message | Notes |
|---|---|---|
| Creator Alert | "Your contract on [Target] has been accepted by an operative." | Respects hunter anonymity. |
| Target Paranoid Alert | "You feel eyes on you. A price has been put on your head." | Toggleable in config. |
| Completion Alert | "Contract Fulfilled. Verification photo attached. Check your archives." | Sent to creator with photo. |

### 7.4 Contract Acceptance & Payout Security

A hunter must **explicitly accept** the contract via the phone app to participate.

#### Elimination Fulfillment
- Payout triggers **only** if the target is killed specifically by a player who accepted the bounty.
- To claim, the hunter must stand near the dead target and take a **verification photo** using the lb-phone camera.
- The script confirms completion only if the target player's entity is within a short radius of the hunter at capture time.
- On verification: the photo is transmitted instantly to the creator's app as proof of death, **baseline rewards** are released, and the contract closes for all hunters.
- **No payout** if the target dies by local elements, suicide, or a player who did not accept the contract.

#### Kidnapping Fulfillment
- The contractor must bring the target **alive** to the physical location of the bounty creator.
- The script must detect a **30-second continuous proximity countdown** between contractor, target, and creator.
- On success: **baseline + bonus** escrowed rewards are released, and the contract closes for all hunters.
- Any break in continuous proximity resets the countdown.

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
- Kidnapping proximity radius and countdown duration (default 30s)

---

## 9. Non-Functional Requirements

- **Server authority** — all escrow, payouts, job checks, and completion validation are resolved server-side. Clients send intent only; they never assert outcomes.
- **Escrow integrity** — funds and items are never duplicated or lost across logout, server restart, or contract cancellation; escrow state persists to the database.
- **Anti-exploit** — validate acceptance, kill attribution, proximity, and photo capture on the server; rate-limit app actions; reject blacklisted-job callers on every event.
- **Persistence footprint** — keep it small: active contracts plus the last 10 completed contracts per player.

---

## 10. Refinement Recommendations

Improvements to what is already specified above — no new systems, no new player-facing features.

### 10.1 Make escrow the single source of truth
Give every contract one escrow record listing each source and amount, written in the **same database transaction** that removes the funds and items from the creator. Payout, refund, and bailout all read from that one record. This is what stops the classic duplication bugs — nothing anywhere else in the script should independently decide what a contract is worth.

### 10.2 Snapshot weapons, don't reference them
When a weapon goes into escrow, store its full serialized metadata (serial, attachments, ammo, durability) in the escrow record rather than a slot reference. Slots move; a reference that dangles pays out a stock weapon and loses the player's attachments.

### 10.3 Validate the reward builder server-side, twice
Once when the builder is opened (to send the client only what the player actually holds) and again on submit (to confirm nothing changed in between). A client that submits an item it dropped mid-flow must be rejected, not silently paid.

### 10.4 Refund path must be as strict as the payout path
The bailout, the expiry refund, and the failure-penalty refund all return the same composed escrow. Give them one shared "release escrow to X" function so an item type that survives payout can't be dropped on refund. If the creator's inventory is full at refund time, the escrow stays open and retries on next login rather than deleting the items.

### 10.5 Kill attribution should be recorded, not queried
Log the killer, weapon, and timestamp at the moment of death into the contract's pending-completion state. Reading attribution later, at photo time, invites a window where a second player's damage or a respawn overwrites it.

### 10.6 Bind the verification photo to the contract
The photo must be captured through a flow the script started for a specific contract — not any photo taken near a corpse. Server-side, validate contract id, hunter id, target ped distance, and a short expiry window on the capture token together, and reject a photo that arrives without all four.

### 10.7 Kidnapping countdown needs a break tolerance
Strict continuous proximity will reset on a single frame of desync or a doorway. Allow a short grace (2–3 seconds) before the countdown resets, and show the hunter the live countdown and the grace state so it never fails silently.

### 10.8 Live mugshot: update on event, not on a timer
Hook appearance changes and refresh the cached mugshot then, rather than re-rendering on an interval for every listed bounty. On a busy server the interval approach is the thing that costs frames.

### 10.9 Rate-limit and debounce every app action
Contract creation, acceptance, bailout, and informant purchases should each carry a server-side cooldown per citizen id. Without it, a spammed accept is a cheap way to probe the anonymity system or race the competitive payout.

### 10.10 Resolve competitive payout with a single-winner lock
When multiple hunters race, the first valid completion must take an atomic lock on the contract before any funds move. Everyone else gets a clean "contract closed" result, not a partial payout.

### 10.11 Persist "hidden" contracts explicitly
Online-presence hiding is a display filter, never a state change. Keep the contract row active with its escrow intact and its failure-penalty timer paused while either party is offline — otherwise a creator can log out to dodge a penalty.

### 10.12 Log everything financial
An admin-readable log of every escrow, payout, refund, bailout, and penalty, with amounts and both parties. Without it, the first time a player claims they lost items you have no way to tell whether they did.
