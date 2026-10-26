# In-game smoke test — Crimson Hitman System

The automated suite exercises the server logic against stubs. These are the
things only a running server can tell you. Work top to bottom; each section
depends on the one before.

Two test characters minimum, three for the competitive and delivery cases.
A staff account that can adjust money and spawn items makes this much faster.

---

## 1. It starts

- [ ] `ensure crimson-hitman` produces `[crimson-hitman] started in json mode`
      (the shipped `Config.Database.Mode`), and once a contract is placed its
      files are in `crimson-hitman/data/` (`store.json`, `contracts/`)
- [ ] No errors in `txAdmin` console on start or on a `restart crimson-hitman`
- [ ] Restarting twice in a row is clean (recovery runs, nothing duplicates)
- [ ] An admin with `crimson.admin` (`add_ace group.admin crimson.admin allow`)
      can run `/ch-diag` in game; a player without it is told "Not
      authorised" and how to grant it
- [ ] **mysql mode only** (`Config.Database.Mode = 'mysql'`, on a copy of the
      server): the console says `started in mysql mode`; the `crimson_*`
      tables exist in the database as InnoDB and `utf8mb4` (`SHOW TABLE STATUS
      LIKE 'crimson%'` shows `InnoDB` and `utf8mb4_unicode_ci`), on MariaDB as
      on MySQL; and a contract reason with an emoji is accepted
- [ ] **mysql mode, a database user without CREATE or ALTER** (on a copy):
      import `install/sql/crimson_hitman.sql` as a user that may, give the
      server's user only SELECT, INSERT, UPDATE and DELETE, and start: it
      starts. Drop one column as the privileged user and start again: it
      refuses, naming that column and printing the `ALTER TABLE` to run; run
      it and it starts. A table moved to MyISAM (`ALTER TABLE crimson_audit
      ENGINE=MyISAM`) is moved back to InnoDB at the next start by a user who
      may alter tables
- [ ] `restart lb-phone`: crimson-hitman stays started (`ensure` not needed)
      and the app is back on an open phone within a few seconds, and
      **Call** in a contract thread does what it did before the restart,
      anonymous parties included
- [ ] json mode, on a copy of the server: move `data/` out of the folder and
      restart. It refuses to start, saying the folder was replaced; put
      `data/` back and it starts with every contract
- [ ] With a contract holding money in json mode, switch `Config.Database.Mode`
      to `mysql` and restart: it refuses, naming how many escrow lines json
      still holds. Switch back and it starts as before
- [ ] With `MugShotBase64` stopped (`stop MugShotBase64`), a new contract's
      target never gets a face on the board, and no `crimson-hitman:renderMugshot`
      event reaches their client; started again, faces come back
- [ ] On a copy of the server, rename the folder (`crimson-hitman-test`) and
      `ensure` that name: the app opens, the board loads and a contract can
      be placed. (Every request used to go to `crimson-hitman` whatever the
      folder was called.) Rename it back

## 2. Access

- [ ] A civilian character finds **Crimson-Hitman** in the phone's App Store
      (not on the home screen) and can download it. With
      `Config.App.DefaultInstalled = true` and a restart it is on their home
      screen instead, and cannot be removed
- [ ] The app's top lines sit below lb-phone's clock and island, on every
      tab: the first board card's name, Mine's first heading, a thread's
      **Back** and **Call**, the viewfinder's instruction, and the first line
      of a refusal notice
- [ ] With lb-phone in its light theme (its default),
      the clock, signal, battery and the home indicator stay readable while
      the app is open: they sit on a pale band at the top and bottom, on
      every tab and over the viewfinder. Switch to dark with the app open:
      the bands go and the page is dark to its edges
- [ ] A `sast` character does **not** see it, on duty or off
- [ ] Nor does an `fib` character, on duty or off, or an `ambulance` character
- [ ] A SAST officer who switches their primary job to a civilian one with
      `sc-multijob` (F9) is still barred, and their phone says which job
      they hold bars them
- [ ] Take SAST off that character's jobs altogether: the app is in their App
      Store again within about ten seconds (the maintenance tick,
      `Config.Audit.FlushIntervalMs`; an estimate until you time it)
- [ ] If your server also has other law, medical or legal jobs (`police`,
      `bcso`, `sheriff`, `trooper`, `sasp`, `ranger`, `fire`, `doj`,
      `lawyer`), one character of each does not see it either
- [ ] Nothing appears in console when a blocked player's phone opens

## 3. Placing a contract

- [ ] Target search finds a player by partial name, and does not list everyone
- [ ] As shipped there is no **Within 30m** button, and boot printed
      `nearby: off`. With `Config.Targeting.AllowNearby = true` (boot now
      warns about it): a player standing beside you is listed as "under
      10m"; put a mask on them and within a couple of seconds they are gone
      from the list, take it off and they are back; a player who has just
      logged in shows up a second or so after their character loads; a player in
      noclip or another routing bucket is never listed; and once you have
      placed a contract, taken one, or seen one on you under On me, the
      list says it is closed while you are on a contract. After a handover
      pays, all three still standing together, it stays closed to each of
      them (for `NearbyClosedAfterSeconds`, half an hour)
- [ ] The item picker does not offer `money` (your cash) or `identification`
- [ ] An anonymous contract funded with an item that names you (a unique
      phone with its number, an engraved item, an ID-like card from another
      resource) is refused with "One of those items carries your name or
      number", and nothing leaves your inventory; the same item on a
      contract placed under your name goes up
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

## 4a. Live transfer only (as shipped)

`Config.Completion.Fulfilment = 'alive'`: a contract is completed only by
delivering the target alive to the client. Run these before changing it.

- [ ] `/ch-diag` says `completion: alive` and that the kill photo settings
      are not used
- [ ] The Place form offers no kidnapping bonus and no "alive only" marking
      on goods, says contracts pay only for delivering the target alive, and
      the placed contract holds no bonus line
- [ ] The contract's card says **Alive only** on the board, under Mine and
      under On Me, with nothing priced "if alive"; the accept dialog says a
      kill does not complete it; the hitman's card has **Deliver alive** alone,
      and a hitman who has never finished one is told how to deliver
- [ ] Place a contract, take it with a second character, **restrain** the
      target (cuffs) and bring them to the client: the handover arms, counts
      down and pays the **whole reward**; the contract closes
- [ ] Again, with the target uncuffed in the **hitman's vehicle**: the
      handover arms and pays the same
- [ ] Again, but **kill** the target first: they die and respawn as normal,
      the contract stays open under Mine for the client and the hitman,
      there is no **Verify kill**, and nothing is paid; `/ch-timeline` on it
      shows no `death_attributed`. Restrain them after the respawn and the
      handover still pays
- [ ] The client's **Change reward** offers no kidnapping bonus to raise;
      adding money still works, and it is paid on the handover
- [ ] **One `'either'` smoke test** (on a copy, or set it back afterwards):
      set `Config.Completion.Fulfilment = 'either'` and restart. `/ch-diag`
      says `completion: either`, and counts any contract still open from the
      step above as placed under `'alive'`: a kill on that one still pays
      nothing. Place a new contract with a 50% kidnapping bonus: a kill
      photographed with **Verify kill** pays the baseline and the bonus goes
      back to the client; on a second one, a handover pays baseline plus
      bonus

## 5. Elimination

Only on contracts placed under `'either'`: run this section on a copy with
`Config.Completion.Fulfilment = 'either'`.

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
      photo** and **Cancel**; Cancel closes it and the game camera with it.
      Take photo is greyed out until the rear camera is on (a moment), and
      the hitman is never in the shot
- [ ] Take photo sends it (the button reads "Sending…") and the viewfinder
      closes; a file appears in `crimson-hitman/data/photos/` and nothing new
      is in the hitman's Photos app or on the image host
- [ ] Open the viewfinder and, with it still open, run `restart
      crimson-hitman` in the console: the phone's camera goes off with it and
      the phone works as normal
- [ ] On `'host'` storage, Verify kill opens lb-phone's camera instead, on
      the rear camera, and its flip key (UP) does not turn it to the selfie
      camera
- [ ] Photographing the body pays the base reward and closes that payout
- [ ] The creator's completion notification says the photo is waiting under
      Ledger and can be seen once (it carries no photo itself)
- [ ] The creator's Ledger row has **View photo**; the hitman's and the
      target's rows have no photo, and nothing new is in the hitman's Photos app
- [ ] View photo shows it full-screen with **Save to Photos** and **Delete**;
      on `'host'` storage Save puts it in the phone's Photos app and the row
      then reads "Photo saved to your phone"
- [ ] Opening it again is refused. Tapping a tab while it is open does
      nothing but say "Save or delete the photo first"; the photo stays up.
      **Delete** deletes it and the row reads "Photo deleted"; on `'server'`
      storage its file is gone from `data/photos/`. A photo kept in the app
      leaves by any tab
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
      `lb-phone's upload allow list takes <host>: yes`, and a moment after
      the report `photo links: https://<host>/crimson-hitman reaches this
      resource: yes`
- [ ] Set `Config.Completion.PhotoPublicUrl` to the same host **without**
      `/crimson-hitman` and restart: `/ch-diag` now says the address answered
      404, not this resource. Save to Photos on a fresh photo: the page waits
      a few seconds, says the phone could not save it and offers **Keep it in
      the app instead**; nothing new is in the phone's Photos. Put the
      address back
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
      **Close**; Close keeps it, Delete removes it and its file. Tapping
      **View photo** again while one is still arriving says to try again in
      a few seconds, rather than sending it twice
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
- [ ] Completing pays **baseline + bonus** under `'either'`, and the whole
      reward under `'alive'` (4a)
- [ ] Killing the target mid-countdown fails the delivery — no payout
- [ ] Downing the target mid-countdown fails the delivery
- [ ] A cuffed, conscious target under 20% health is refused as "too badly
      hurt", not "alive and conscious"; patched up, the handover arms

## 7. Law enforcement advisory

- [ ] Placing a contract on an officer warns the creator first, naming the department
- [ ] **Every** online LEO gets a phone notification naming the officer —
      including officers who never had the app, since it is never on their
      phone (lb-phone's handling of an app it has not installed is not
      documented; this is the check)
- [ ] The targeted officer is notified directly
- [ ] An `sc-dispatch` entry appears in the MDT
- [ ] Accepting raises a second advisory with the operative count
- [ ] A second acceptance raises another, with the count now 2
- [ ] The creator is **never** named in any of it
- [ ] The listing shows the LAW ENFORCEMENT flag and warns before accepting
- [ ] All of the above for a target on `sast` and for one on `fib`

## 8. Counter-play

- [ ] A target sees the contract in **On Me** with the buyout price, but
      only once their "eyes on you" alert has arrived (one to ten minutes
      after it was placed); before that On Me and `/cleanse` show nothing,
      and the board shows no face for them unless one was already rendered.
      Restart the resource inside that wait: it shows at once. Withdraw one
      inside the wait: the target never gets the alert for it
- [ ] With `Config.Advisory.OnCreate = false`, a contract on an officer is
      accepted inside the wait: the officer's "THREAT ADVISORY — ACTIVE"
      arrives and `/cleanse` lists the contract at once
- [ ] Buying out closes the contract, returns escrow **and** premium to the creator
- [ ] A cash-paid premium arrives as cash, not bank
- [ ] Buying out is refused while a handover countdown is running
- [ ] Buy out with a hitman on it; the hitman kills the target in the last
      seconds of the delay: the contract stays open until the photo is sent,
      the hitman is paid, and the target gets the premium back
- [ ] The same with a handover armed in the last seconds of the delay
- [ ] A kill made just before the deadline can still be photographed after
      it, and the hitman's stake comes back; a handover cannot be armed after it,
      and a kill made a few seconds after it (before the contract shows as
      expired) is not paid and the stake goes to the client
- [ ] Buy out with a hitman on it; the hitman kills the target a few seconds
      after the delay ran out: the contract closes as bought out, the photo
      is refused, and the premium goes to the client, not back to the target
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

- [ ] Notifications stay in the phone's notification list once their popup
      has gone: an acceptance, "the photo is waiting under Ledger", a
      target's "eyes on you", a stake forfeited
- [ ] A hitman logged off when their contract expires, logging back in
      through the character and spawn selector, finds "Contract expired" in
      their phone's notification list once they have spawned
- [ ] A target who never downloaded the app still gets "eyes on you"
- [ ] A contract disappears from the board when the target logs out
- [ ] It reappears when they return, with escrow intact
- [ ] Restarting the resource mid-contract loses nothing
- [ ] A payout to a player with a full inventory is delivered on their next login
- [ ] ...and, with them still connected through a `restart crimson-hitman`,
      within a minute of making room, without a relog
- [ ] A target with a live contract on them who logs out through the
      character selector, waits more than a minute and comes back as the same
      character cannot be named in a new contract for
      `Config.Immunity.MinTargetSessionMinutes` (10): "They have only just
      come online"
- [ ] A character who logs out dead (or in last stand) and comes back as
      another, alive, leaves no `revive_claim_without_death` row in the audit
      log and nothing about it on the staff webhook
- [ ] Right after a payout, the player's `money` in the `players` table already
      shows it (qbx_core's `Save`), not five minutes later

## 12. Performance

- [ ] `resmon` for `crimson-hitman` stays near 0.01ms idle, with
      `Config.Targeting.AllowNearby` off and on (on, the client looks at its
      own mask once a second; an estimate until measured)
- [ ] With 10+ live contracts and the app open, it stays under 0.05ms
- [ ] Opening the app on a board of fifteen targets: their faces arrive within
      a few seconds, all at once, and the reading stays under 0.35ms. The
      faces keep the game's grey backdrop (`Config.Mugshot.RemoveBackground =
      false`), and the audit log has no `mugshot_too_large` row
- [ ] On `'server'` storage, send a kill photo and then open it as the client
      while watching the server's frame time (txAdmin's performance chart, or
      the console's `profiler record`): note the hitch on each. Expect about
      80 ms at the shipped `Config.Completion.PhotoMaxBytes` (600000) and a
      fifth of a second at 1500000; these are estimates until you measure them
- [ ] A kidnap countdown running does not spike it
- [ ] No console spam during normal play, and no
      `maintenance job ... took ... ms` warning; `/ch-diag` lists the
      slowest jobs, every one under `Config.Diagnostics.SlowJobMs` (5 ms),
      in `mysql` mode too (time spent waiting on the database is not counted)
- [ ] With the staff webhook set, a gunfight between players no contract
      names posts nothing to it
- [ ] On qbx_medical (no sc-ambulance), `/ch-diag <id>` says the death state
      came from QBox metadata, and a kill on a target still pays

## 13. Admin panel

Grant yourself `crimson.admin` (and, on a second account, only `command`, the
usual extra ACE; and on a third, `crimson.admin` and `crimson.identity`).

- [ ] `/hitmanadmin` opens the panel full screen with a cursor; the phone app
      still opens from the phone as before. Escape closes it, so does its close
      button, and the game takes input again at once. `restart crimson-hitman`
      with it open leaves no cursor behind
- [ ] Escape closes the panel without opening the pause menu: press and let go
      of Escape a few times, quickly and slowly, and the map or pause menu never
      opens as the panel goes (a second Escape after it has gone does open it)
- [ ] The overview shows the contracts by state, money held by account, owed
      deliveries, stuck lines, open review items and photos, and refreshes
      every 10 seconds; it matches `/ch-stuck` and `/ch-review`
- [ ] At your own game resolution (and at 1280x720 windowed, if you can) the
      panel fits the screen: the navigation, every toolbar and the contract
      drawer's Void and Close are on screen without scrolling sideways, and
      the dropdowns open inside the window. The icons show; if the game cannot
      reach cdnjs.cloudflare.com, every button still says what it does
- [ ] Type a target's name into the contract search: the list answers once you
      stop typing, and clicking a row opens its drawer. A dropdown (state, rule,
      placed) opens and picks with the mouse, and Clear brings the full list back
- [ ] Every destructive button (void, settle, resolve, reset, reset all, the
      timer refresh) turns brass on the first click and says *Click again*;
      leave it three seconds and it goes back without doing anything
- [ ] Type a citizen id into the log's citizen id box on the account without
      `crimson.identity`: the box is greyed out and nothing is filtered by it
- [ ] Turn a feature switch off and on again from **Features & limits**: each
      click answers in a toast and on the row, and the row says *changed from
      the panel* with `config.lua`'s value beside it until you reset it
- [ ] On the `command`-only account the panel opens and every section reads;
      void, settle, every switch and every Save are greyed out, with *Read only:
      changing anything needs the staff ACE itself* on hover, and the review
      queue shows no resolve form. Then, as that account, type `/ch-void <id>` in
      chat: it answers *Not authorised*, so the server refuses it too
- [ ] Place an anonymous contract and accept it anonymously on another
      character. Without `crimson.identity` the contract shows *Anonymous* for
      both, no citizen id appears anywhere (contract, log, player view), and
      searching the client's citizen id or name does not find it; with it,
      both are named and whois answers. `/ch-timeline` shows the matching
      `admin_panel_contract_identified` row
- [ ] Void a contract from the panel: the client gets their escrow back and the
      answer reads exactly as `/ch-void`'s
- [ ] Leave a payout for staff (fill the hitman's pockets, or stop the server
      mid-payout) and settle it from the contract view with `delivered` and
      then with `pay <amount>` on another: the answers read as `/ch-settle`'s
- [ ] Resolve a review item twice: the second says it is already resolved, and
      the player is paid once. After the first, the item stays in the list,
      marked resolved with the answer in it, until you press Refresh
- [ ] On the `crimson.identity` account, resolve a review item on an anonymous
      contract by role. Then, on the account without it, open **Needs review**,
      All, and run `/ch-review all`: whom it paid reads as *the client*, never a
      citizen id
- [ ] In **Features & limits**, **Limits & settings**, type 1 into *Days an
      unopened kill photo is kept* and press Enter: nothing is saved, the row says
      what lowering it deletes, and Save turns brass; only a second click on Save
      lowers it. Raising it back saves at one click. `Config.Cooldowns.admin` and
      `adminWrite` are on the **Read only** tab
- [ ] The log pages back with Older and forward again, and a filter by contract
      shows that contract's rows only
- [ ] Turn **Buyouts** off: the app's On me tab stops offering a buyout,
      `/cleanse` says buyouts are off, and a buyout paid just before still
      closes its contract after `Config.Bailout.ProcessingDelaySeconds`
- [ ] Turn **Proposals** off: a proposal already open can still be answered; a
      new one says it is turned off by the server
- [ ] Turn **List the people nearby** on from the panel: within a second or two
      a player's own unmasked face makes them appear on others' nearby lists,
      with no restart
- [ ] Change **Contracts a hitman may hold** to 1 with a hitman holding two:
      both stay, and a third is refused
- [ ] Try a least buyout above the most: refused with the start's own words
- [ ] Restart the resource: every changed setting is still in force,
      `/ch-diag` lists them as *admin panel settings in force over
      config.lua*, and the panel shows each with *panel* as its source and
      `config.lua`'s value beside it. Reset all: after another restart,
      `config.lua` is in force again
- [ ] In `mysql` mode the `crimson_settings` table holds the changes; in
      `json` mode `data/records.json` does
- [ ] `resmon` with the panel open stays under 0.35ms, and back near idle once
      it is closed (the Escape watch runs every frame only while it is open)

---

## If something fails

The audit log records every financial movement and every rejected attempt.
`/ch-timeline <contract>` shows one contract's state, escrow lines and audit
trail in any mode. For the whole log, in `json` mode (the shipped one) read
the day's file, `crimson-hitman/data/audit-<day>.jsonl`, one row a line. In
`mysql` mode:

```sql
SELECT * FROM crimson_audit ORDER BY id DESC LIMIT 50;
```

`kind = 'rejected'` rows are refused attempts and name the reason.
