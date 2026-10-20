# In-game smoke test — Crimson Hitman System

The automated suite exercises the server logic against stubs. These are the
things only a running server can tell you. Work top to bottom; each section
depends on the one before.

Two test characters minimum, three for the competitive and delivery cases.
A staff account that can adjust money and spawn items makes this much faster.

---

## 1. It starts

- [ ] `ensure crimson-hitman` produces `[crimson-hitman] started in mysql mode`
- [ ] No errors in `txAdmin` console on start or on a `restart crimson-hitman`
- [ ] The `crimson_*` tables exist in the database, `utf8mb4` (`SHOW TABLE
      STATUS LIKE 'crimson%'` shows `utf8mb4_unicode_ci`), on MariaDB as on MySQL
- [ ] Restarting twice in a row is clean (recovery runs, nothing duplicates)
- [ ] `restart lb-phone`: crimson-hitman stays started (`ensure` not needed)
      and the app is back on an open phone within a few seconds
- [ ] json mode, on a copy of the server: move `data/` out of the folder and
      restart. It refuses to start, saying the folder was replaced; put
      `data/` back and it starts with every contract
- [ ] With a contract holding money in json mode, switch `Config.Database.Mode`
      to `mysql` and restart: it refuses, naming how many escrow lines json
      still holds. Switch back and it starts as before

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
- [ ] Taking back the whole base reward of a payout is refused
- [ ] "Add money" from the same screen still puts more up
- [ ] Once a hitman accepts, the screen says why the reward cannot be
      reduced — and adding still works
- [ ] Nothing on that screen is cut off, and its buttons clear the tab bar

## 4. Payouts

- [ ] A 3-payout contract escrows all three reward sets at creation
- [ ] The board shows "Payout 1 of 3" and payout 1's reward
- [ ] Four hitmen can all accept a 3-payout contract
- [ ] After the first claim, the board shows payout 2's reward
- [ ] After the third claim the contract closes and the fourth hitman gets nothing

## 5. Elimination

- [ ] Hitman kills target with a firearm → hitman can request the camera
- [ ] The same from 300-400 m with a sniper rifle → the kill is credited
- [ ] With the target's game killed (quit or crash) in the second after the
      death, Verify kill works a few seconds later anyway, and `/ch-timeline`
      shows `death_unreported`
- [ ] A kill by sticky bomb or grenade pays nothing, and Verify kill says only
      gunfire and melee count (not "Down is not dead")
- [ ] Kill a target driving at speed: the photo is taken standing at the car
      where it stopped, not where they died
- [ ] `/ch-diag` says which photo storage is in use (`server` as shipped)
- [ ] On `'server'` storage, **Verify kill** opens the app's own viewfinder
      over the whole screen, showing the phone's rear camera, with **Take
      photo** and **Cancel**; Cancel closes it and the game camera with it
- [ ] Take photo sends it (the button reads "Sending…") and the viewfinder
      closes; a file appears in `crimson-hitman/data/photos/` and nothing new
      is in the hitman's Photos app or on the image host
- [ ] On `'host'` storage, Verify kill opens lb-phone's camera instead
- [ ] Photographing the body pays the base reward and closes that payout
- [ ] The creator's completion notification says the photo is waiting under
      Ledger and can be seen once (it carries no photo itself)
- [ ] The creator's Ledger row has **View photo**; the hitman's and the
      target's rows have no photo, and nothing new is in the hitman's Photos app
- [ ] View photo shows it full-screen with **Save to Photos** and **Delete**;
      on `'host'` storage Save puts it in the phone's Photos app and the row
      then reads "Photo saved to your phone"
- [ ] Opening it again is refused; switching tab while it is open deletes it
      and the row reads "Photo deleted"; on `'server'` storage its file is
      gone from `data/photos/`
- [ ] A photo left open (phone closed mid-view) is deleted after
      `Config.Completion.PhotoOpenSeconds`
- [ ] A stray file put in `data/photos/` or `data/photos/kept/` (named like
      the others) is removed at the next resource start, and the waiting and
      kept photos are not

### Save to Photos on `'server'` storage

Run these three times: with a public address, with none but a phone that
uploads, and with neither. Restart the resource between them.

- [ ] **With a public address.** Set `web_baseUrl` (Qbox Nucleus: `set
      web_baseUrl "<name>.server.qbox.re"` in `server.cfg`) or
      `Config.Completion.PhotoPublicUrl`, and add that host to lb-phone's
      `Config.UploadWhitelistedHostnames`. `/ch-diag <id>` shows
      `photo links: https://<host>/crimson-hitman/p/...` and
      `lb-phone's upload allow list takes <host>: yes`
- [ ] Remove the host from lb-phone's list and restart lb-phone: `/ch-diag`
      now says the list does NOT take it, and names the line to add. Put it back
- [ ] Save to Photos on a fresh kill photo: the phone's **Photos** app has the
      photo, it loads there, and the row reads "Photo saved to your phone".
      The file is still in `data/photos/`, and `/ch-diag` counts it under
      "served to phones' Photos"
- [ ] The photo opens in a desktop browser at its link (the newest `link`
      in lb-phone's `phone_photos` table); the same link with `.png` instead
      of `.webp`/`.jpg`, with the name changed by one letter, or with `/p/../`
      in it answers "Not found."; a `curl -X POST` of the real link answers
      "Not found." too
- [ ] Delete the photo from the phone's Photos app: its file is gone from
      `data/photos/` within a second, and the link answers "Not found."
- [ ] Save another, then factory reset that phone (Settings): its file is
      gone too
- [ ] **With no address, on a phone whose lb-phone has an upload method**
      (Fivemanage or the like): `/ch-diag` shows `photo links: none (...)`.
      Save to Photos uploads it, the phone's Photos has it, and its file is
      gone from `data/photos/` at once
- [ ] **With neither** (no address, and lb-phone's upload not working, e.g.
      no `Config.UploadMethod` it can reach): the dialog's button still reads
      **Save to Photos**, since the page cannot tell an upload will fail
      before trying it. Tap it: the save fails, the dialog says the phone could
      not save it and offers **Keep it in the app instead**. That keeps it:
      the row reads "Kept for you in this app" and still has **View photo**,
      and the file is in `data/photos/kept/`. (A button reading **Save**, with
      "Your phone can't take it, so it is kept for you in this app", appears
      only on a phone build whose app page has no `components.uploadMedia` /
      `components.saveToGallery` at all.)
- [ ] A kept photo opens again as often as you like, with **Delete** and
      **Close**; Close keeps it, Delete removes it and its file
- [ ] When a save to Photos fails (take the host off lb-phone's list and
      try), the dialog says the phone could not save it and offers **Keep it
      in the app instead**; that keeps it as above
- [ ] Push the row of a kept photo off the Ledger (complete more contracts
      than `Config.Ledger.Depth`): the photo is listed on its own under
      **Photos kept in this app**, and still opens
- [ ] `/ch-diag` reports how many photos are kept in the app and how much
      space they take; with `Config.Completion.KeptPhotoDays = 1` a kept
      photo is gone a day after it was kept
- [ ] **Downing** the target without killing them does **not** allow a claim
- [ ] A target who is revived before the photo invalidates the claim
- [ ] A kill by someone who never accepted pays nobody
- [ ] Target killed by NPC / fall / vehicle pays nobody

## 6. Kidnapping

- [ ] Restrain the target (cuffs, or put them in your vehicle)
- [ ] With hitman, target and creator together, the countdown starts
- [ ] Walking away pauses it and it recovers within the grace window
- [ ] Walking away for longer fails the delivery
- [ ] Completing pays **baseline + bonus**
- [ ] Killing the target mid-countdown fails the delivery — no payout
- [ ] Downing the target mid-countdown fails the delivery
- [ ] A cuffed, conscious target under 20% health is refused as "too badly
      hurt", not "alive and conscious"; patched up, the handover arms

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
- [ ] Buy out with a hitman on it; the hitman kills the target in the last
      seconds of the delay: the contract stays open until the photo is sent,
      the hitman is paid, and the target gets the premium back
- [ ] The same with a handover armed in the last seconds of the delay
- [ ] A kill made just before the deadline can still be photographed after
      it, and the hitman's stake comes back; a handover cannot be armed after it
- [ ] Informant data names one hitman, and charges even when it finds nobody
- [ ] Buying informant data twice returns the same name

## 9. Communication

- [ ] Creator and hitman can message under aliases
- [ ] Neither sees the other's real name when anonymous
- [ ] On a competitive contract, hitmen cannot see each other's threads

## 10. Amendments

- [ ] Adding to the pot applies immediately and notifies the hitman
- [ ] Extending the deadline applies immediately
- [ ] Shortening the deadline requires the hitman to agree
- [ ] The hitman declining leaves the original terms intact

## 11. Presence and persistence

- [ ] A contract disappears from the board when the target logs out
- [ ] It reappears when they return, with escrow intact
- [ ] Restarting the resource mid-contract loses nothing
- [ ] A payout to a player with a full inventory is delivered on their next login
- [ ] ...and, with them still connected through a `restart crimson-hitman`,
      within a minute of making room, without a relog
- [ ] A contract reason with an emoji is accepted in mysql mode
- [ ] Right after a payout, the player's `money` in the `players` table already
      shows it (qbx_core's `Save`), not five minutes later

## 12. Performance

- [ ] `resmon` for `crimson-hitman` stays near 0.01ms idle
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
