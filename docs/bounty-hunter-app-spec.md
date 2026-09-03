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
- Automated **escrow** of cash, bank funds, and inventory items
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

- The creator sets a **baseline escrow reward**:
  - Cash and/or bank balance
  - Specific QBox inventory items and/or weapons currently held
- The creator configures a **Kidnapping Bonus Multiplier** (e.g., +50% extra cash, or additional items) paid on live delivery.
- The hunter decides **on the fly** how to handle the target based on opportunity — eliminate for the baseline, or kidnap for baseline + bonus.

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
- Payout currency mode — clean bank / dirty money item / crypto
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
