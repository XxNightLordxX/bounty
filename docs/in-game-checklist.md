# In-game smoke test — Crimson Bounty System

The automated suite exercises the server logic against stubs. These are the
things only a running server can tell you. Work top to bottom; each section
depends on the one before.

Two test characters minimum, three for the competitive and delivery cases.
A staff account that can adjust money and spawn items makes this much faster.

---

## 1. It starts

- [ ] `ensure crimson-bounty` produces `[crimson-bounty] started in mysql mode`
- [ ] No errors in `txAdmin` console on start or on a `restart crimson-bounty`
- [ ] The `crimson_*` tables exist in the database
- [ ] Restarting twice in a row is clean (recovery runs, nothing duplicates)

## 2. Access

- [ ] A civilian character sees the **Crimson** app on their phone
- [ ] A `police` character does **not** see it
- [ ] So do `bcso`, `sheriff`, `trooper`, `sasp`, `fib`, `ranger`, `ambulance`, `fire`, `doj`, `lawyer`
- [ ] An officer who clocks **off duty** still cannot open it
- [ ] Nothing appears in console when a blocked player's phone opens

## 3. Placing a contract

- [ ] Target search finds a player by partial name, and does not list everyone
- [ ] The reward builder shows your real cash, bank and dirty money
- [ ] Placing a contract debits exactly what you selected — check all four:
      cash, bank, dirty money (`black_money`), an item, a weapon
- [ ] The weapon leaves your inventory **with its attachments**
- [ ] A contract you cannot afford is refused and charges nothing
- [ ] The contract appears on the board for a third character

## 3a. Changing what a contract pays

- [ ] "Change reward" on your own contract lists every line it is holding
- [ ] Ticking a line and confirming returns exactly that, and nothing else
- [ ] An item comes back **with its metadata**; a weapon with its serial
      and attachments
- [ ] Taking back the whole baseline of a slot is refused
- [ ] "Add cash" from the same screen still puts more up
- [ ] Once a hunter accepts, the screen says why the reward cannot be
      reduced — and adding still works
- [ ] Nothing on that screen is cut off, and its buttons clear the tab bar

## 4. Payout slots

- [ ] A 3-payout contract escrows all three reward sets at creation
- [ ] The board shows "Slot 1 of 3" and slot 1's reward
- [ ] Four hunters can all accept a 3-payout contract
- [ ] After the first claim, the board shows slot 2's reward
- [ ] After the third claim the contract closes and the fourth hunter gets nothing

## 5. Elimination

- [ ] Hunter kills target with a firearm → hunter can request the camera
- [ ] Photographing the body pays the baseline and closes the slot
- [ ] The creator receives the completion notification **with the photo**
- [ ] The photo appears in the creator's Ledger tab
- [ ] **Downing** the target without killing them does **not** allow a claim
- [ ] A target who is revived before the photo invalidates the claim
- [ ] A kill by someone who never accepted pays nobody
- [ ] Target killed by NPC / fall / vehicle pays nobody

## 6. Kidnapping

- [ ] Restrain the target (cuffs, or put them in your vehicle)
- [ ] With hunter, target and creator together, the countdown starts
- [ ] Walking away pauses it and it recovers within the grace window
- [ ] Walking away for longer fails the delivery
- [ ] Completing pays **baseline + bonus**
- [ ] Killing the target mid-countdown fails the delivery — no payout
- [ ] Downing the target mid-countdown fails the delivery

## 7. Law enforcement advisory

- [ ] Placing a contract on an officer warns the creator first, naming the department
- [ ] **Every** online LEO gets a phone notification naming the officer
- [ ] The targeted officer is notified directly
- [ ] An `sc-dispatch` entry appears in the MDT
- [ ] Accepting raises a second advisory with the operative count
- [ ] A second acceptance raises another, with the count now 2
- [ ] The creator is **never** named in any of it
- [ ] The listing shows the LAW ENFORCEMENT flag and warns before accepting

## 8. Counter-play

- [ ] A target sees the contract in **On Me** with the buyout price
- [ ] Buying out closes the contract, returns escrow **and** premium to the creator
- [ ] A cash-paid premium arrives as cash, not bank
- [ ] Buying out is refused while a handover countdown is running
- [ ] Informant data names one hunter, and charges even when it finds nobody
- [ ] Buying informant data twice returns the same name

## 9. Communication

- [ ] Creator and hunter can message under aliases
- [ ] Neither sees the other's real name when anonymous
- [ ] On a competitive contract, hunters cannot see each other's threads

## 10. Amendments

- [ ] Adding to the pot applies immediately and notifies the hunter
- [ ] Extending the deadline applies immediately
- [ ] Shortening the deadline requires the hunter to agree
- [ ] The hunter declining leaves the original terms intact

## 11. Presence and persistence

- [ ] A contract disappears from the board when the target logs out
- [ ] It reappears when they return, with escrow intact
- [ ] Restarting the resource mid-contract loses nothing
- [ ] A payout to a player with a full inventory is delivered on their next login

## 12. Performance

- [ ] `resmon` for `crimson-bounty` stays near 0.01ms idle
- [ ] With 10+ live contracts and the app open, it stays under 0.05ms
- [ ] A kidnap countdown running does not spike it
- [ ] No console spam during normal play

---

## If something fails

The audit log records every financial movement and every rejected attempt.
In `mysql` mode:

```sql
SELECT * FROM crimson_audit ORDER BY id DESC LIMIT 50;
```

`kind = 'rejected'` rows are refused attempts and name the reason.
