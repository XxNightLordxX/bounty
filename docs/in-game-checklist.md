# In-game smoke test — Crimson Hitman System

The automated suite exercises the server logic against stubs. These are the
things only a running server can tell you. Work top to bottom; each section
depends on the one before.

Two test characters minimum, three for the competitive and delivery cases.
A staff account that can adjust money and spawn items makes this much faster.

---

## 1. It starts

- [ ] With the shipped `Config.Debug = true`, `ensure crimson-hitman` prints
      the integration list and `started in json mode` (the shipped
      `Config.Database.Mode`), and once a contract is placed its files are in
      `crimson-hitman/data/` (`store.json`, `contracts/`). During normal play
      no slow-job line appears unless a job really takes over 25 ms
      (`Config.Diagnostics.SlowJobMs`)
- [ ] Set `Config.Debug = false` and restart: the console prints **nothing**,
      and `ch-diag` in the server console ends with what the start would have
      said
- [ ] With `Config.Debug = false`, set `Config.Targeting.AllowNearby = true` and
      restart: the console prints exactly one line, `[crimson-hitman] 1 setting(s) need attention; run
      ch-diag (F8 or the server console) or open /hitmanadmin to see them`, and
      `ch-diag` lists the setting under *settings that need attention*. Put it
      back
- [ ] Turn **Debug output in the server console** off in the admin panel
      (**Features & limits → Audit and debug**) and restart: nothing at the
      restart. Turn it on again: the integration list, `started in json mode`
      and any warning in full
- [ ] No errors in `txAdmin` console on start or on a `restart crimson-hitman`
- [ ] Restarting twice in a row is clean (recovery runs, nothing duplicates)
- [ ] An admin with `crimson.admin` (`add_ace group.admin crimson.admin allow`)
      can run `ch-diag` in the F8 console in game: the whole report prints in
      F8, nothing in chat, and a notice says *Printed to your F8 console*.
      Typed in chat as `/ch-diag`, the same. A player without it is told "Not
      authorised" and how to grant it, in F8 too
- [ ] With another character's app open, run `ch-diag <their id>` in F8: the
      report says the answer follows here, and a moment later their app's log
      (*player N's app sent its log …*, each line *page: …*) prints in your F8,
      nothing in the server console. **Run the diagnosis** in the admin panel
      with their id: the log appears under the report there instead
- [ ] As a player, type `/cleanse` in chat: its answer (*Nothing is out on
      you.*, or the list) is in chat, not F8, with no F8 notice
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
      to `mysql` and restart: it refuses, listing the contract by its Ref with
      its state, what it holds (`50000 bank`, say), whom anything is owed to
      by role (never a name) and what clears it. Switch back and it starts as
      before
- [ ] json mode, on a copy: with a contract holding money, stop the server,
      copy `data/contracts/<its id>.json` aside and replace it with `{` (a file
      nobody can read). Switch to `mysql` and restart: it refuses, naming that
      file. Put the copy back and switch back: it starts with the contract
- [ ] json mode, on a Windows copy: hold one `data/contracts/<id>.json` open in
      a program that locks it, and move money on another contract:
      the console says once `1 contract file(s) could not be written and are
      kept in memory: <id>`, the other contract's file changes, and closing
      the editor lets the next flush write it. **Flush the audit log** in the
      admin panel meanwhile says the store did not save and names the file
- [ ] mysql mode, on a copy: set `Config.MaxContractValue = 5000000000` and
      `Config.Reason.MaxLength = 300` and restart. The start counts both among
      the settings that need attention, and `ch-diag` says each is held to
      2147483647 and 255. Put them back
- [ ] mysql mode, on a copy: put an item whose metadata is larger than 64 KB
      (a note item with a very long text, if your server has one) into a new
      contract's reward: the app says the item carries more data than the
      server can hold in escrow, and the item and the money stay with you
- [ ] mysql mode, on a copy: `SHOW INDEX FROM crimson_audit` lists
      `idx_audit_action`, `crimson_contracts` `idx_resolved` and
      `crimson_messages` `idx_message_contract` after the first start of
      this version
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
### 2a. The whitelisted-job view (as shipped, `Config.WhitelistedView.Enabled = true`)

- [ ] A `sast` character finds the app in the App Store, on duty or off, and
      opening it shows one screen with no tab bar: *You're on a whitelisted
      job, so this app only shows contracts on you and on other
      whitelisted-job members.*
- [ ] The same for an `fib` character and, if your server has them, one of
      each other law enforcement job (`police`, `bcso`, `sheriff`,
      `trooper`, `sasp`, `ranger`)
- [ ] An `ambulance` character (and `fire`, `doj` or `lawyer`, whom the
      threat advisory does not reach) gets the same one screen, saying *…
      this app only shows contracts on you.*, with no **Contracts on
      whitelisted jobs** section at all
- [ ] With nothing on any of them it says *No contracts on you or other
      whitelisted-job members.*
- [ ] Place a contract on the SAST character from a civilian (named, with a
      buyout price). Once their alert has arrived (or at once, with the
      threat advisory on), it is under **Contracts on you**: their name and
      job, *Posted … ago*, *Open — no hitman yet*, *Lapses within …* (the
      contract's lifetime, about 48h as shipped) and **Buy out — $…**. The
      FIB character sees it under **Contracts on whitelisted jobs**, with
      *Runs out within …* and no buyout button
- [ ] Log the civilian who placed it off for a few minutes, then back on:
      neither officer's *within …* jumps up when they come back
- [ ] Neither screen shows the placer's name, an operative, the reason, a
      location, a face or the reward. A contract on a civilian is not on it,
      and nothing says how many there are
- [ ] A civilian hitman accepts it: both screens say *Taken by 1 hitman* once
      the app is reopened (an acceptance does not ring the target's phone)
- [ ] The hitman abandons it: the FIB character's entry still says *Taken by
      1 hitman*, as no bulletin says one walked away. A second hitman takes it
      up: still *Taken by 1 hitman*, as that bulletin said *1 operative is
      active*
- [ ] Log the SAST character off and back on: the FIB character's entry for
      them is there throughout, the same. Place a contract on a civilian, then
      give them the `police` job: it is not under **Contracts on whitelisted
      jobs**, online or off (no advisory went out for it)
- [ ] Admin panel, Features, Law enforcement advisory: turn **Advisories** off: the
      FIB character's screen has no **Contracts on whitelisted jobs** section.
      While it is off, place a contract on another officer and have a hitman
      take it (no bulletin goes out); turn it back on: the SAST character's
      entry is back, and the other officer's contract is not listed at all
- [ ] The same with only **When accepted** off while a hitman takes a
      contract on an officer: turned back on, that entry says neither *Open —
      no hitman yet* nor *Taken by …* (no bulletin said either) until the
      next hitman takes it, when it says *Taken by 1 hitman*. A contract
      placed while it was off says neither too. Restart with
      `Config.Advisory.OnAccept = false` in config.lua and back: the same. With
      only **When posted** off while one is placed, it is listed once a hitman
      takes it, saying *Taken by 1 hitman* with neither *Posted …* nor *Runs
      out within …*
- [ ] The SAST character taps **Buy out**: it asks first (two taps), the
      price is the one On me would show a civilian, then *Paid. It closes in
      about 2 minutes. You are still a target until then.*, the entry says
      *Paid. A hitman still has … to finish this*, and after the delay it is
      gone and the placer has their escrow and the premium
- [ ] The same bought out from the floor (downed): refused, *Not from the
      floor. Get up first.* With buyouts off in the panel, no button
- [ ] `/cleanse` still lists it and buys it out exactly as the button does.
      Place a second contract on them with no buyout price: `/cleanse` lists
      it as *no buyout offered* (never *Nothing is out on you.*), and
      `/cleanse <its id>` says the person who placed it did not put a price on
      closing it
- [ ] With a hitman on it, `/cleanse <id>` says *Paid. It closes in about 2
      minutes. You are still a target until then; if a hitman finishes first,
      your money comes back.* With $10,000 in the bank and $10,000 cash
      against a $15,000 price it says the bank or the cash has to cover the
      full $15,000 on its own. The buyout dialog and every *Paid* reply, in the
      app and in chat, end *Closing this one does not mean nobody else is after
      you.*
- [ ] A SAST officer who switches their primary job to a civilian one with
      `sc-multijob` (F9) keeps the view and nothing more, and their phone
      says once *The app only shows the whitelisted-job screen while you hold
      the sast job. Quit it from your job menu for the whole app.*; the view's
      banner says *You hold the sast job, a whitelisted one, …*. Switching
      back to SAST and out again, or a tick later, says nothing more; relog to
      a character that holds a barred job it is not working: told again
- [ ] On the view, **Refresh** reads it again (a colleague's contract placed
      meanwhile appears). Tapped again at once, it says how many seconds to
      wait and the screen stays as it was
- [ ] Take SAST off that character's jobs altogether with the app open: it
      changes to the whole app (Board, Mine, Place, On Me, Ledger) at once,
      or within about ten seconds if no job event arrives (the maintenance
      tick, `Config.Audit.FlushIntervalMs`; an estimate until you time it)
- [ ] Give a civilian with the app open the `police` job: it changes to the
      view at once, and nothing of the board, their Place form or Mine
      remains. A contract they placed or took as a civilian carries on
- [ ] With `Config.BlockOffDuty = false`, an off-duty officer has the whole
      app, and an off-duty colleague is still listed on the view, as the
      advisory names them on duty or off
- [ ] Run `ch-diag <the SAST character's id>` in F8 with their app open: the
      report runs `whitelistedView`, says the answer follows here, and their
      app's log prints in your F8 a moment later
- [ ] Nothing appears in console when a whitelisted player opens the app, and
      the admin panel's **Logs** gain no *rejected* `gate_list` row for it

### 2a-i. Notify me on the view (as shipped, `Config.WhitelistedView.Alerts = true`)

Two officers (SAST A who opens the view, SAST B a colleague) and a civilian
placer, all online.

- [ ] A's view has **Notify me** beside **Refresh**, and says *Notify me is
      off. Turn it on and your phone tells you when a new contract appears
      here, while you are in the city.* Place a contract on B: A gets the
      THREAT ADVISORY bulletin and nothing else
- [ ] Tap **Notify me**: *Notify me is on.*, the button reads **Turn off
      Notify me**. Place a contract on B (another placer): A's phone gets the
      bulletin and, in the same second, *Contract on a whitelisted job: A
      contract on <B's name> (<B's job>) is now listed in this app.* The
      notice names nobody else: not the placer, not a hitman, no reason or
      reward. A hitman taking it sends A the acceptance bulletin and no
      second Notify me
- [ ] Turn off **Admin panel, Features, Law enforcement advisory, When
      posted** (`OnCreate`) and place a contract on B: nothing reaches A until a hitman
      takes it; then the acceptance bulletin and the Notify me notice arrive
      together. Turn it back on
- [ ] With **When posted** off, place a contract on A: A hears
      nothing until their own alert (*Unsettling*, one to ten minutes later,
      an estimate), and *Contract on you: A contract on you is now listed in
      this app.* arrives in the same second, never before it. Withdraw one
      inside that wait: no Notify me for it at all
- [ ] A contract on a civilian sends A nothing. An EMS character who turned
      Notify me on gets nothing for a contract on B (their view has no
      colleagues' list)
- [ ] Place seven contracts on colleagues inside a minute (several placers):
      A gets six Notify me notices that minute and the seventh when the
      minute opens (`Config.Notifications.MaxPerRecipientPerMinute`, 6 as
      shipped); every bulletin still arrives at once
- [ ] Tap **Turn off Notify me** and **Notify me** quickly six times: the
      sixth says how many seconds to wait (`Config.Cooldowns.message`)
- [ ] Restart the resource (or the server) with Notify me on: A's view still
      says it is on, and the next contract on B still reaches A's phone. A's
      other characters have it off
- [ ] Admin panel, Features, Access: turn **Notify me on the whitelisted-job
      view** off. A's open view loses the button at once; a contract on B
      sends the bulletin and no Notify me. Turn it back on: A's choice is as
      they left it
- [ ] With **Whitelisted-job view** off, the panel says **Notify me on the
      whitelisted-job view** does not apply
- [ ] resmon with ten officers online, five with Notify me on, while a
      contract on a colleague is placed: no lasting change from idle (0.02 ms
      or less when nothing happens)

### 2b. The view switched off

- [ ] Admin panel, Features, Access: turn **Whitelisted-job view** off. An
      open view says *This app is not for you.* and, with **Hide the app from
      barred jobs** on, the app leaves their phone at once (a held job is
      named on their phone, if it was not named already)
- [ ] With **Hide the app from barred jobs** off too, a character barred by a
      job they hold but are not working opens the app to *Closed to you while
      you hold the police job. Quit it from your job menu to use it again.* on
      every tab, with no **Try again**. One working the barred job reads *This
      app is not for you.*, also with no **Try again**
- [ ] Set `Config.Admin.Enabled = false` and restart: `/cleanse` still lists
      and buys out a contract on an officer, in chat, while every staff
      command is gone
- [ ] **Hide the app from barred jobs** says it does not apply while the view
      is on, and applies again once it is off
- [ ] Restart the resource: the view is still off; turn it back on and the
      app returns to their phones with its one screen

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
- [ ] Tap **Place contract** with the reason empty: *Give a reason for the
      contract.* and nothing is sent. With the reason *Owes me 1500000*: the
      refusal says the reason has more digits than the server takes, not
      *Check what you entered*
- [ ] With the Place form open, switch **Dirty money** off in the admin panel
      and place one paying dirty money: *This server no longer takes dirty
      money in a reward. Nothing was taken. The form has been read again.*,
      and the form no longer offers it
- [ ] The contract appears on the board for a third character
- [ ] A second contract from the same player on the same target, on any
      character, is refused: *You already have a contract out on them.*
- [ ] Two friends on two accounts each place a $1,000 contract on one target,
      filling the cap; a third player is told the target has as many as the
      server allows. Both friends log off while the target stays: within a
      minute the third player can place one (as shipped, `alive`)
- [ ] A contract nobody took that you let run out (bring it in with Edit to
      the least it allows and wait): another player can place on the target at
      once; you are told you placed one on them recently

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

## 3b. New players and playtime (as shipped)

`qbx_core` 1.24 keeps no playtime, so the resource counts it
(`Config.Immunity.MinTargetPlaytimeHours`, 5). Note `SELECT MAX(id) FROM players`
in your database before the first start of this version.

- [ ] Within a minute of the first start, `ch-diag` says under *playtime*:
      `tracker: counting since <time>; characters numbered up to N in
      qbx_core's players table are from before it and grandfathered.`, with N
      the number you noted
- [ ] An existing character with nothing counted yet: `/ch-diag <their player
      id>` says `grandfathered: yes, from before the tracker` and `fair game by
      playtime: grandfathered`, and a contract on them can be placed once they
      have been in the city for `MinTargetSessionMinutes` (10)
- [ ] Make a brand-new character and stay in the city with it for 10 minutes:
      a contract on them is refused with *They are too new to the city to be a
      target yet.*; `/ch-diag <their id>` says `grandfathered: no`, with the
      hours counted so far, which grow while they stay
- [ ] Admin panel, **Players**, look the new character up by player id: the
      **Playtime** card shows the hours counted, *5 h* needed and *From before
      the count: No*. Type 6 and press **Set hours** twice: *… counted playtime
      is now 6 h (it was … h).*, and a contract on them can now be placed.
      **Reset to 0** twice: refused again. **Logs** shows two
      `admin_playtime_set` rows with the hours before and after. A staff
      member with only an extra ACE sees both buttons disabled; one without
      `crimson.identity` can still use them
- [ ] Only where `Config.Immunity.PlaytimeProvider` is set (or QBox metadata
      carries a playtime figure): the card and the **Set hours** answer say
      *… reads your playtime export (or their QBox metadata) for them, not
      these hours.* and nothing else about whether they have played enough,
      grandfathered or not
- [ ] Log the new character out and back in, then `restart crimson-hitman`:
      the hours are where they were (within a minute), and do not grow by the
      time the resource was stopped. In `json` mode `data/playtime.json` holds
      their row; in `mysql` mode `crimson_playtime` does
- [ ] With 30 or more players online, `/ch-diag` never lists `playtime.pass`
      among the slow maintenance jobs (estimate: well under a millisecond a
      minute on `json`; measure yours)
- [ ] (Only on a framework without `qbx_core`'s `players` table.) The first
      start counts one setting that needs attention, naming
      `Config.Immunity.GrandfatherDays`: characters first seen in those days are
      grandfathered, a new one made in them too

## 4. Payouts

`Config.Limits.MaxPayoutSlots` ships as 1: each contract is collected once.

- [ ] As shipped, the Place form has no **Payouts** count, no note about
      more hitmen than payouts, and its one reward is headed **Reward**, not
      "Payout 1"; the placed contract's card says nothing of payouts
- [ ] In the admin panel (**Features, limits & settings → Limits**), the
      setting takes 1, 2 or 3 and refuses 0 and 4. Set it to 3: the next
      Place form offers a count of up to 3 (reopen the Place tab), and the
      checks below run
- [ ] With `MaxPayoutSlots = 7` in `config.lua`, the start warns that it has
      to be 1, 2 or 3 and uses 3; with `0`, it uses 1
- [ ] A 3-payout contract escrows all three reward sets at creation
- [ ] The board shows "Payout 1 of 3" and payout 1's reward
- [ ] Four hitmen can all accept a 3-payout contract
- [ ] After the first claim, the board shows payout 2's reward
- [ ] After the third claim the contract closes and the fourth hitman gets nothing
- [ ] With a 3-payout Place form open, set the setting back to 1 in the
      panel: within a moment the form shows one reward and says *This
      server now takes one payout per contract; payouts 2 and 3 were
      removed.*
- [ ] Place a 3-payout contract, then set the setting back to 1 in the panel:
      the contract still shows "Payout 1 of 3", pays all three collections,
      and its client can still give the last one back (**Propose change →
      Give back the last payout**); a new contract offers one collection only

## 4a. Live transfer only (as shipped)

`Config.Completion.Fulfilment = 'alive'`: a contract is completed only by
bringing the target **alive** to **the person who placed the contract**, who
has to be in the city and there for the handover. Run these before changing
it. Every line below that names a distance or a time uses your
`Config.Kidnap.Radius` and `CountdownSeconds` (12 m and 30 seconds as
shipped); set them to something else once (say 8 and 20), restart, and check
the app follows. Nothing a player reads here calls that person "the client",
and nothing mentions a photo while `Config.Completion.KillPhotos` is off.

- [ ] `/ch-diag` says `completion: alive`, that a contract is completed only
      when the target is brought alive to the person who placed it, who has
      to be there for the handover, and that the kill photo settings are not
      used; in the admin panel, **How contracts are completed** says the same
- [ ] The Place form offers no kidnapping bonus and no "alive only" marking
      on goods, says *Contracts here only pay when the target is brought to
      you alive. You need to be in the city to meet the hitman for the
      handover.*, and the placed contract holds no bonus line
- [ ] The contract's card says **Alive only** on the board, under Mine and
      under On Me, with nothing priced "if alive"; on the board, the line under
      the reward says *Bring the target alive to the person who placed this
      contract.*; the card names who placed it (**Placed by …** or **Placed
      anonymously**)
- [ ] The accept dialog says *This contract only pays when you bring the
      target, alive, to the person who placed it. Killing them does not
      count.*
- [ ] The hitman's card has **Deliver alive** alone, and reads (for a
      hitman with jobs behind them too, not only a first one) *Bring them in
      alive: take them to the person who placed this contract, stay within
      12 m of that person with them, tap Deliver alive and hold for 30
      seconds. They have to stay alive, conscious and on their feet the whole
      time. Killing them does not count — they respawn and the contract stays
      open.* Nothing on it says to cuff anybody On an anonymous contract it adds *The person who placed it is
      anonymous — use Message to agree where to meet.*; on a named one it
      names them
- [ ] As the hitman, open **Message** on that contract: the thread reads
      *with the person who placed it*, and the placer's messages, their phone
      notices (*The person who placed it: …*) and a call request (*The person
      who placed a contract you took wants to speak with you about it.*) never
      say "Client"
- [ ] As the placer, once a hitman takes it: the phone notice and your card
      under Mine say *A hitman took your contract. They'll bring the target to
      you alive — stay in the city and watch your messages.* When the
      handover starts you are told to stay within 12 m of them both for 30
      seconds; if it fails, *Handover stopped* says the contract is still open
- [ ] Place a contract, take it with a second character, and walk the target,
      **not cuffed and on foot**, to the person who placed it: the handover
      arms, counts down and pays the **whole reward**; the contract closes.
      The target's phone gets no notice from it
- [ ] Turn **Target must be restrained** on in the admin panel: the same walk
      is refused (*The target must be restrained or in your vehicle.*), the
      hitman's card now says *cuff them or get them into your vehicle*; cuff
      the target with your police script and it arms and pays. Check in
      `/ch-diag <target id>` or your cuff script that it sets QBox's
      `ishandcuffed` metadata (qbx_police does). Turn it off again
- [ ] With the phone closed during that countdown, the hitman's phone still
      gets *Handover paid* (*Delivered alive: $… released to you. Your $…
      stake has been returned.*) in its notification list. With their
      pockets full of a reward that includes an item, it adds that part is
      held until they make room, and their **Ledger** says *1 payment
      waiting for room* until they do
- [ ] Mid-countdown, the target quits the game: `/ch-timeline` on the
      contract shows `kidnap_party_dropped` with role `target` and how far
      the countdown had run. The same for the person who placed it
      (`placer`); a hitman quitting shows that and `kidnap_cancelled`
      (`hitman_dropped`). A `restart crimson-hitman` mid-countdown writes
      none of them
- [ ] With **Target must be restrained** on, the target uncuffed in the
      **hitman's vehicle**: the handover arms and pays the same
- [ ] Again, but tap **Deliver alive** with the placer 30 m away: *The person
      who placed this contract must be online and within 12 m of you and the
      target.* With the placer logged off: the same for an anonymous placer,
      and *Everyone has to be online for a handover: the person who placed
      this contract must be in the city and within 12 m …* for a named one.
      Arm it with them there, then have them walk off: the countdown says
      they must be within 12 m, and the failure notice says they did not
      arrive in time and must be online and within 12 m
- [ ] Again, but **kill** the target first: they die and respawn as normal,
      the contract stays open under Mine for the placer and the hitman,
      there is no **Verify kill**, and nothing is paid; **Deliver alive** on
      the body says killing them does not count and to bring them in alive
      once they are back up; `/ch-timeline` on it shows no
      `death_attributed`. Bring them in alive after the respawn and the
      handover still pays
- [ ] The placer's **Change reward** offers no kidnapping bonus to raise;
      adding money still works, and it is paid on the handover
- [ ] **Meeting point** (`Config.Kidnap.MeetingPoint = true`, as shipped).
      As the placer, before anybody takes the contract: your card under Mine
      shows nothing about a meeting point. Once a hitman has it, it says *No
      meeting point set.* and *Set meeting point here shows the hitman on this
      contract the spot where you are standing.* (placed anonymously: *…, not
      who you are.*). Tap **Set meeting point here**: it asks first, then says
      *Meeting point set where you are standing.* Tap it again at once: *The
      meeting point was changed a moment ago. Try again in N seconds.* Drive
      off and tap it while moving: *Could not place a meeting point where you
      are standing.*
- [ ] As the hitman: your phone gets *Meeting point set* (it names nobody),
      and your card says **Meeting point set** with **Set GPS**; tap it and
      the spot where the placer stood is marked on your map. Move it as the
      placer (after 30 seconds): *Meeting point moved*, and Set GPS marks the
      new spot. **Clear** it: your card no longer says one is set, and no
      phone notice rings
- [ ] Nobody else sees it: on the board (as a third character), on the
      target's On me, on a whitelisted-job player's view, in an advisory, and
      in the admin panel's contract view for staff without
      `Config.Admin.IdentityAce` there is no meeting point and no coordinates;
      staff with it see *Meeting point* with the coordinates
- [ ] It goes: the hitman walks away (on a contract only they held) and a
      new hitman takes it: no meeting point on their card. Set one again and
      void the contract from the panel: the contract leaves the hitman's Mine,
      and the panel's contract view (with the identity ACE) shows no meeting
      point. `restart crimson-hitman` with one set: it is still on the
      hitman's card afterwards, and Set GPS still marks it
- [ ] In the admin panel's Features, turn **Meeting point for the handover**
      off: the placer's controls and the hitman's **Meeting point set** go;
      turn it back on: a point set before is shown again
- [ ] **One `'either'` smoke test** (on a copy, or set it back afterwards):
      set `Config.Completion.Fulfilment = 'either'` and restart. `/ch-diag`
      says `completion: either`, and counts any contract still open from the
      step above as placed under `'alive'`: a kill on that one still pays
      nothing. A new contract's cards, dialog and how-to read as they always
      did (no line under the reward, no "only pays when"). Place one with a
      50% kidnapping bonus: a kill verified with **Verify kill** (no camera,
      kill photos being off as shipped) pays the baseline and the bonus goes
      back to the person who placed it; on a second one, a handover pays
      baseline plus bonus

## 5. Elimination

Only on contracts placed under `'either'`: run this section on a copy with
`Config.Completion.Fulfilment = 'either'`, first as shipped (kill photos
off, 5a), then with `Config.Completion.KillPhotos = true` for the rest.

### 5a. Pictures off (as shipped)

`Config.Completion.KillPhotos = false`: no kill photo is ever taken, kept or
served, and no image host is asked anything.

- [ ] `/ch-diag` prints `Kill photos: off`, and `photo settings: not used
      (kill photos are off)`; the start printed nothing about
      `ExtraPhotoHosts`, `PhotoPublicUrl` or `web_baseUrl`
- [ ] `crimson-hitman/data/photos/` gains no file, not even `.mode`, through
      a start, a kill and a restart
- [ ] Kill the target and tap **Verify kill** standing over the body: no
      camera and no viewfinder opens, the button reads "Verifying…" for a
      moment, and the app says "Verified. Payment released."; the payout is
      paid and the hitman's first-job hint said to tap Verify kill at the
      body, with nothing about a photograph
- [ ] Tap it again from 20 m away on a second kill: "You are too far from the
      body"; let the target respawn and wait past
      `ProofWindowSeconds` (60 s): the kill no longer pays
- [ ] Kill the target again within a minute of that respawn and tap
      **Verify kill**: *They had only just got back up, so this kill does not
      count.* Kill them about four minutes after a respawn instead: it says
      the kill does not count yet and how many seconds to wait; tap again
      once they have passed, with the target still dead, and it pays
- [ ] Kill the target, `restart crimson-hitman` before tapping **Verify
      kill**, then tap it: *The server restarted and lost the proof of this
      kill*, not a word about explosives or the weapon
- [ ] Kill the target and have staff void the contract from `/hitmanadmin`
      before tapping **Verify kill**: *That contract is closed.*, never
      *Not right now.*
- [ ] Admin panel, Features: **A downed target is not a kill** is shown
      read-only, under the read-only settings, saying why
- [ ] With **Kill photos** turned on from the panel on a server started with
      them off, verify a kill with a photo on `'server'` storage:
      `data/photos/.mode` appears beside the photo, naming the storage mode
- [ ] The client's completion notice says the contract was fulfilled and
      nothing about a photo; their Ledger row has no **View photo**
- [ ] With a link to a photo saved before (on a server that had them on),
      `https://<address>/crimson-hitman/p/<name>.webp` answers "Not found."
- [ ] A photo kept from before, opened by its client: there is no **Save
      to Photos**, only **Save** (kept in the app) and **Delete**, and the
      dialog says *Kill photos are off on this server, so it can only be kept
      for you in this app.* Tap **Save**: nothing is uploaded (no new file at
      your `Config.UploadMethod` host) and the phone's Photos gains nothing
- [ ] In the admin panel, **Kill photos** is under **Features → Completion**,
      and **Where kill photos are kept** and **Keep kill photos for the
      client** say they do not apply now. Turn **Kill photos** on there:
      the next Verify kill opens the camera, without a restart; turn it off
      again and restart: it is still off
- [ ] **Target headshots** off in the panel: the board's cards show the
      placeholder face from the next refresh, and a target's game is not
      asked for a render (no MugShotBase64 hitch on the target); on again,
      faces come back. Restart: the switch is as you left it

### 5b. Kill photos on

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

- [ ] With hitman, target and creator together, the countdown starts (with
      **Target must be restrained** on: only once the target is cuffed or in
      the hitman's vehicle)
- [ ] `restart crimson-hitman` mid-countdown: the countdown is gone, the
      contract is still open with its reward and the stake held, and
      **Deliver alive** arms again at once and pays once
- [ ] Walking away pauses it and it recovers within the grace window
- [ ] Walking away for longer fails the delivery
- [ ] Completing pays **baseline + bonus** under `'either'`, and the whole
      reward under `'alive'` (4a)
- [ ] Killing the target mid-countdown fails the delivery — no payout
- [ ] Downing the target mid-countdown fails the delivery
- [ ] A conscious target under 20% health is refused as "too badly
      hurt", not "alive and conscious"; patched up, the handover arms
- [ ] Set the `progress` rate limit to 1 held, 1 a second in the panel and run
      a handover: the bar never vanishes, nothing says *Slow down*, and it
      ends with *Delivered* as before
- [ ] A staked contract with less time left than the stake window shows *Too
      little time left to stake on this one* on the board instead of Accept

## 7. Law enforcement advisory

- [ ] Placing a contract on an officer warns the creator first, naming the
      department, and says it alerts *every officer in the city* (an off-duty
      officer is told too: check one)
- [ ] **Every** online LEO gets a phone notification naming the officer —
      including officers who never had the app, since it is never on their
      phone (lb-phone's handling of an app it has not installed is not
      documented; this is the check)
- [ ] The targeted officer is notified directly; logged off at the time, they
      find it once they have spawned at their next login
- [ ] With **Always tell the officer** off in the admin panel, the targeted
      officer gets the ordinary "eyes on you" alert instead
- [ ] An `sc-dispatch` entry appears in the MDT
- [ ] With an officer's contract taken, turn **Advisories**, **When
      accepted** or **Use dispatch** off in the admin panel, then end the
      contract (void it): both MDT entries are gone
- [ ] Accepting raises a second advisory with the operative count
- [ ] A second acceptance raises another, with the count now 2
- [ ] The first operative walks away, `restart crimson-hitman`, and takes it
      again: no second acceptance bulletin, on phones or in the MDT
- [ ] The creator is **never** named in any of it
- [ ] The listing shows the LAW ENFORCEMENT flag and warns before accepting
- [ ] All of the above for a target on `sast` and for one on `fib`

## 8. Counter-play

- [ ] A target sees the contract in **On Me** with the buyout price, but
      only once their "eyes on you" alert has arrived (one to ten minutes
      after it was placed); before that On Me and `/cleanse` show nothing,
      and the board shows no face for them unless one was already rendered.
      Restart the resource inside that wait: On Me still shows nothing, and
      one to ten minutes after the restart the alert arrives with it.
      Withdraw one inside the wait: the target never gets the alert for it
- [ ] The target logs off before the alert is due and back after it: the
      "eyes on you" alert is in their notifications once they have spawned
- [ ] Place one, switch **Tell the target** off in the admin panel inside the
      wait: no alert comes. Let a contract run out inside the wait (a short
      deadline): the target is never told it lapsed
- [ ] Two clients place one each on the same target a few minutes apart, and
      the first withdraws: the alert comes when the second shows on On Me,
      not before
- [ ] The target has On Me open when the alert arrives: the contract appears
      on it without leaving the tab
- [ ] With `Config.Advisory.OnCreate = false`, a contract on an officer is
      accepted inside the wait: the officer's "THREAT ADVISORY — ACTIVE"
      arrives and `/cleanse` lists the contract at once
- [ ] Buying out closes the contract, returns escrow **and** premium to the
      creator, who is told *Your escrow is back and the $… buyout was paid to
      you* (logged off, at their next login); the target is told *Your buyout
      went through*. With the creator's pockets full of the reward's items,
      the creator is told what is waiting for room instead
- [ ] With a hitman on it, buy out: the hitman is told *It closes in 2
      minutes unless you finish it first* even after a minute of messages,
      and their card under Mine counts it down. A second hitman who accepts
      inside the delay is told at once. If a hitman finishes first, the
      target is told *A hitman finished the contract on you … your $… is
      back*
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
- [ ] **The target's informant.** On **On me**, **Buy informant data** lists
      every operative on the contract (*Operative #1*, ...) and *The person
      who placed it*, including an operative who has never been near you. The
      dialog says *10% chance*, that the price is paid either way, and that
      nobody is told. Pick one, press **Pay $25,000**: it changes to **Tap
      again to pay $25,000** for three seconds; tap it. $25,000 leaves your
      bank once, whatever the answer. A hit puts *Informant: Operative #1 is
      <name>* on the card (still there after a restart); a miss says *Your
      informant could not find out who it is.* Neither the operative nor the
      placer gets any notice
- [ ] On a contract placed under a name, *The person who placed it* is
      greyed out with *Placed under their name: you know who it is.* After two
      look-ups on one contract (operatives and placer together) the button is
      gone. Asking about the same pick again within 30 minutes repeats the
      answer free
- [ ] A target on a whitelisted job (police, EMS): no informant anywhere, not
      on the whitelisted-job view and not on **On me** after they leave the
      job for a contract placed while they held it; the buyout is still there
- [ ] **The placer's informant.** On **Mine**, with an anonymous operative on
      your contract (placed named or anonymously): **Informant on an operative
      — $25,000**. The dialog says *20% chance*, paid either way, and that a
      successful look-up has a *20% chance* of being noticed. Two taps pay
      once. A hit puts the name on your card (kept after a restart); a miss
      says *Your informant could not find out who they are.* With
      **Chance the operative found out is told** at 100 in the panel, a hit
      sends the operative *The person who placed one of your contracts has
      found out who you are: your contract on <target>* and never your name
- [ ] The placer's button is greyed out with why: within 10 minutes of a
      look-up (*Your informant can ask again in about N minutes.*), after two
      look-ups, and when every operative took it under their name or was
      found out. Have the operative abandon between the two taps: the price
      comes back
- [ ] In the panel, raise **bailout: requests held**, **informant: requests
      held** and **placerInformant: requests held** to 2. Tap **Buy out**
      twice as fast as you can: the target pays once (the second says *That
      was busy for a moment. Try again.* or *You have already paid*). The same
      with the second tap of each informant dialog: one fee. Put them back to 1
- [ ] A hitman walks away from a staked contract while its client is offline:
      the client gets the stake at their next login, and the panel's **Logs**
      show `stake_forfeited` with the amount and *queued*. Walking away from
      one with no stake writes no `escrow_released` row
- [ ] A hitman holds a staked exclusive contract and stays far from the
      target, client and target in the city, for
      `Config.Limits.ExclusiveIdleReleaseSeconds` (30 minutes as shipped): it
      goes back on the board, the client is told *Their $… stake is yours*, and
      the hitman, logged off meanwhile, is told at their next login *Your $…
      stake went to the person who placed it*. With no stake the notice names
      no stake. The accept dialog said so before they took it
- [ ] Walk away from an exclusive contract and tap Accept on it again at
      once: refused, saying when you can take it again; another hitman can
      take it meanwhile
- [ ] With `Config.Limits.MaxHitmenPerContract` set to 2 in the panel, two
      hitmen take a competitive contract and both stay far from the target:
      after the idle window one of them is taken off it and a third hitman
      can take the place
- [ ] A client who withdraws a contract an operative took and walked away from
      is told *The operative who took it walked away*, and the dialog says
      nobody else can place one on the target for a while either

## 9. Communication

- [ ] Creator and hitman can message under aliases
- [ ] Send six messages in a minute, then have a second operative accept, and
      arm a handover: *Contract accepted* and *Handover starting* still ring,
      muted thread or not
- [ ] One operative takes a competitive contract, walks away and takes it
      again: the client is told *Contract accepted* once
- [ ] Neither sees the other's real name when anonymous
- [ ] On a competitive contract, hitmen cannot see each other's threads
- [ ] Log the client off, have the hitman send two messages, log the client
      back in: one *New message about your contract on …* notice, and a dot
      on **Message**/**Threads** that goes once the thread is opened. Mute
      the thread first and nothing is kept
- [ ] Send a message with a word lb-phone blacklists: *A word in that message
      is not allowed here. Your draft is kept.* Set the `message` rate limit
      to 1 an hour in the panel and send two: the second says *about 60
      minutes*
- [ ] Place a call, then complete the contract (or switch **Calls** off in
      the panel) mid-call: **Hang up** is still there (above the screen once
      the thread has closed) and ends the call
- [ ] Double-tap **Call**: one call rings, and the button says *Calling…*
      while it is asked
- [ ] On a phone build that cannot hide caller id, with
      **Never unmask a caller** on: no Call is drawn on a thread with an
      anonymous party, and nobody receives *wants to speak with you*

## 10. Amendments

- [ ] Adding to the pot applies immediately and notifies the hitman
- [ ] Extending the deadline applies immediately
- [ ] Shortening the deadline requires the hitman to agree
- [ ] The hitman declining leaves the original terms intact
- [ ] **Cancel the contract** (client) and **Call it off** (hitman) on a held
      contract each ask first: the client reads the waits it starts, a staked
      hitman that their stake comes back. Nothing is sent on the first tap
- [ ] Your own open proposal has **Take it back**; tapping it closes the
      proposal and the other side is told it was taken back
- [ ] Agreed cancel: the client is told *called off by agreement* and what
      came back, and each hitman where their stake went; the panel's **Logs**
      show `amendment_applied`
- [ ] Propose *one hitman only* with one operative on a competitive contract,
      let a second take it, then both agree: the last to agree reads
      *Agreed, but it no longer applies: who is on the contract changed*, and
      the client and the first operative are told too
- [ ] Buyouts off in the panel, take part of a reward back, buyouts on again:
      the target's buyout price is still there (lower only if the reward left
      buys less)

## 11. Presence and persistence

- [ ] Notifications stay in the phone's notification list once their popup
      has gone: an acceptance, "the photo is waiting under Ledger", a
      target's "eyes on you", a stake forfeited
- [ ] A hitman logged off when their contract expires, logging back in
      through the character and spawn selector, finds "Contract expired" in
      their phone's notification list once they have spawned
- [ ] A target who never downloaded the app still gets "eyes on you"
- [ ] With a staked contract held, let its deadline pass, then log the client
      (or the target) out within a few seconds: the contract expires at the
      next pass and the stake goes to the client; it is not paused
- [ ] A target sentenced at the station with a contract on them and driven to
      the prison: within a minute of arriving inside `Config.Limits.JailZone`
      the deadline stops (the hitman's card shows the clock stopped)
- [ ] A contract disappears from the board when the target logs out
- [ ] It reappears when they return, with escrow intact
- [ ] Restarting the resource mid-contract loses nothing
- [ ] **mysql mode, test server:** hold a lock on the contract's baseline
      escrow row from a second database session (`SELECT … FOR UPDATE`) past
      `innodb_lock_wait_timeout` while a handover finishes: the hitman is told
      the payout could not be recorded; within a minute (2 ×
      `Config.Database.QueryTimeoutSeconds`) the console says the claim was
      finished as the next start would, the hitman's phone says *Payout not
      recorded … deliver again to collect*, and a second handover pays
- [ ] Let a contract expire while its client is logged off, and stop the
      server in the middle of it if you can (or on a test server make the
      ending raise): at the next start the hitman is told *Contract expired*
      and where their stake went, and the client finds *Contract expired* in
      their notifications once they log back in
- [ ] A payout to a player with a full inventory is delivered on their next login
- [ ] Let a contract expire while its client is logged off: at login they
      read *Contract expired* first, then *Outstanding payment: $… you were
      owed has arrived*, with thousands separators; the panel's **Logs** for
      that contract show `escrow_delivered_late` for each line
- [ ] Staff void a contract while its client is logged off: at login the
      client reads *Contract voided*. Logged off while a hitman accepts, or
      while a kill on an `'either'` contract is verified: *Contract accepted*
      or *Contract fulfilled* at login
- [ ] With collections raised to 2 in the panel, collect one, then let it
      expire (or walk away and Withdraw): the client is told *1 of 2 payouts
      were collected; the rest of what you put up has been returned*, and the
      Withdraw dialog says the same before
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
- [ ] With boot recovery failed (`BOOT RECOVERY FAILED` in the console), stop
      and start the resource after an hour with the cause fixed: a contract
      that fell due in that hour is still running with its stake, its
      deadline moved on by the hour; `/ch-diag` meanwhile said *recovery:
      FAILED at the start* above the handler checks

### 11a. The outage drill (test server, `mysql` mode)

Stop MariaDB for 30 seconds (a) while placing a contract, (b) while buying
out, (c) while accepting with a stake, (d) during a handover countdown.

- [ ] The console says `the database stopped answering (...)` once, and `the
      database answers again after N s` once it is back
- [ ] The phone says *The server's records did not answer in time. If you
      were paying for something, look before you try again: it may still go
      through.* within 15 seconds, never nothing
- [ ] Within a minute of starting MariaDB again each payment is settled by
      the server (the reward back or the contract on the board; the buyout
      recorded or refunded; the stake back), with a phone notice
- [ ] The countdown carries on, and nothing answers *busy* a minute later
- [ ] `/ch-diag` showed `database: NOT ANSWERING since ...` during it, and
      `database: answering` and every loop a few seconds old after it
- [ ] Restart the resource **while** MariaDB is stopped: the console says
      `waiting for the database (N s): ...` every 30 seconds, the start goes on
      once it is back, the same payments are settled, and the audit rows from
      before the stop are in `crimson_audit`
- [ ] resmon idle is unchanged, before and after the drill (estimate: no new
      threads; the connection is checked only when a statement went
      unanswered)

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
- [ ] With `Config.Debug = false`, no console line at all during normal play
      (place, take and deliver a contract, open the app and the panel), and
      nothing in a player's F8; `/ch-diag` lists the slowest jobs, every one
      under `Config.Diagnostics.SlowJobMs` (25 ms), in `mysql` mode too (time
      spent waiting on the database is not counted). On a Windows host, note
      `storage.heartbeat`, `storage.flush`, `expireContracts` (and its first
      pass after a `restart crimson-hitman` with players online) and
      `bridges.refreshAccess` there: the heartbeat is one small write a
      minute now (`data/heartbeat.json`), not a swap every tick
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
- [ ] **Stuck escrow** lists the same lines as `/ch-stuck`, the badge beside it
      counting the ones left for you; each line's **Delivered** or **Pay**
      takes two clicks, its answer stays beside it, and its contract id opens
      the contract's view
- [ ] **Alerts**: make something print whatever Debug says (stop the
      resource mid-payout, or set a limit in `config.lua` the start corrects
      and restart). The badge beside **Alerts**, and the overview's Alerts
      tile, count it within 10 seconds; the section lists it newest first,
      with *Needs staff* or *Setting*, when it was said and the contract it
      names (which opens its view). Restart the resource: it is still there,
      and the same line again says *said 2 times* rather than listing it twice
- [ ] **Acknowledge** on one alert, and **Acknowledge all shown**, each turn
      brass on the first click and act on the second; the alert moves to
      **Acknowledged** with your citizen id and the time, the badge goes
      down, and the **Logs** have an `admin_alerts_acknowledged` row. On the
      `command`-only account neither button is there, **Send a test alert**
      is greyed out, and an acknowledged alert says *a staff member* rather
      than whose citizen id acknowledged it
- [ ] On the account without `crimson.identity`, an alert naming an anonymous
      contract (void one whose ending raises, say) reads *the client* and
      *Anonymous*, never a citizen id, licence or the client's name; on the
      `crimson.identity` account it reads whole
- [ ] Discord: with no webhook set the Alerts section says so and nothing is
      posted. `set crimson_hitman_alert_webhook "<a test channel's webhook>"`
      in the server console, then **Send a test alert**: one post arrives
      within about 10 seconds, and the section says where it posts (never the
      address). Make three alerts within a few seconds: they arrive as one
      post. No post names a citizen id, a licence, a character name or a link,
      and none pings anybody. Turn **Post alerts to Discord** off in Features:
      nothing more is posted. Turn it back on, set the convar to a webhook you
      deleted in Discord and send a test alert: about 30 seconds later the
      section says a post was given up
      after 3 tries (HTTP 404), and the alerts are still listed. Check
      `resmon` while this runs: the resource stays at its idle figure between
      posts (estimate; confirm on your server)
- [ ] **Console**: it shows the settings that need attention (set a limit in
      `config.lua` the start corrects and restart: it is listed as *Problem*),
      what the last start said, and the newest lines since, newest first,
      each with *Always* or *Debug*, its time and *said N times* for a line
      said again. **Always**, **Problems** and **Debug** each show only that
      kind; typing in the filter box narrows the lines as you type. With the
      section open, make the server say something (leave a payout for staff):
      it appears within 10 seconds without pressing **Refresh**, and the list
      does not flicker in between. **Copy**, then paste into a text editor:
      the lines shown arrive as plain text, in the same order. With Debug off
      the section says so, and the server console printed only the *Always*
      lines. Check `resmon` with the section open: the resource stays at its
      idle figure between refreshes (estimate; confirm on your server)
- [ ] On the account without `crimson.identity`, a console line naming an
      anonymous contract reads *the client* and *Anonymous*, never a citizen
      id, licence or the client's name; on the `crimson.identity` account it
      reads whole. With `set crimson_hitman_alert_webhook "<a webhook>"` in the
      server console and a post that fails, no account sees the webhook's
      address in the Console (its host at most, the rest *(path hidden)*), and
      a database error shows the server's words, never the values sent
- [ ] **Remove the kill photos kept from before** (as shipped, kill photos
      off): with none kept, Features shows no such button under **Kill
      photos**. On a test server set **How contracts are completed** to
      *either* and turn kill photos on, verify two kills and leave both photos
      unopened, then turn kill photos off again: under **Kill photos** the panel offers *Remove the 2 kill photos
      kept from before*, saying how many have a file here (or, on `'host'`
      storage, that the pictures stay on the image host). The first click
      turns it brass and says *Click again: remove 2 kill photos for good*;
      the second removes them, the answer says what it deleted, the button
      goes, `data/photos/` holds no picture any more, and the **Logs** have an
      `admin_photos_removed` row with the count. The client's Ledger no
      longer offers either photo. Press it on the `command`-only account: it
      is greyed out
- [ ] With a kill photo open on its client's phone (opened from the Ledger,
      not yet saved or deleted), press the removal: the photo stays on their
      screen, and the answer says *1 open on a phone
      right now*. They tap Delete (or leave it open until it times out): the
      record is gone then, and the button with it. If they tap *Keep in the
      app* instead, they are told the photo is gone
- [ ] Nothing anywhere in the panel names a command: no `/ch-…`, no
      `/hitmanadmin`, in any section, tooltip, empty list, answer or refusal
      (an answer that sends you on names the section or button instead, *see
      Stuck escrow*). Tools has no Commands card, and every command has a
      button: timeline (a contract's view), contracts (Players), stuck (Stuck
      escrow), diag (Run the diagnosis), void, settle, review (Needs review),
      refresh (Bring timers forward) and whois
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
- [ ] Leave a review item being resolved (stop the resource while a refund
      from **Needs review** is handing over). Its card says *Being resolved:
      refund ... by ...* with one **Finish as decided** button and no
      Refund, Pay or Dismiss; `/ch-review <id> dismiss x` answers that it is
      being resolved already and moves nothing; `/ch-review <id>` alone (or
      the button) finishes it, and the player is paid once
- [ ] With a `json` store, make the records file read-only and leave an item
      for staff: **Needs review** lists it as not in the store yet, its form
      drawn off, saying it can be resolved once the store has taken it;
      restore the file and, within a tick, it resolves as usual
- [ ] With `Config.Anonymity.CreatorFee` set, place an anonymous contract:
      the fee leaves the fee account only once the contract is on the board.
      Place one you cannot cover with the fee on top: refused, nothing taken
- [ ] What the page shows is what is charged. With the Place form open, raise
      the creator fee in the panel: within a second the form's **Place
      anonymously** shows the new fee (from your bank or cash), with no tab
      change. Raise it again and place before the form redraws: *Placing
      anonymously now costs …*, nothing taken; place again and the
      confirmation names the fee charged. The same with the hitman fee and
      an accept dialog open (the dialog redraws with the new fee; a tap on
      the old one says the fee now and takes nothing), and with the
      informant's price and its dialog. With the price at 0 the dialog says
      *It is free on this server*
- [ ] With the Place form open, switch **How contracts are completed** to
      *either* in the panel and place before the form redraws: *This server
      now places contracts differently: a kill completes one …*, nothing taken
- [ ] Pick a civilian on the Place form, give them the `police` job, then
      place: *That target now works in a protected job*, nothing taken, and
      the warning asks *Place a contract on them anyway?* with **Place it**
      and **Cancel**; **Place it** places it
- [ ] An EMS target: the board card, the hitman's warning and the creator's
      warning say *emergency services*, never *sworn officer*; the medic is
      told *Law enforcement has been advised*, an officer target *Your
      department has been advised*. Turn **Flag the listing** off: the card
      has no chip, no gold notice and no protected styling
- [ ] Buy the last look-up allowed from either informant: the dialog says
      *This is your last one on this contract*, and afterwards the target's
      button is gone and the placer's is greyed out with why
- [ ] Turn dirty money off in the panel: the Place form says *This server
      does not take dirty money as a reward*, and the minimum names only cash
      and bank. Turn items off while carrying a pistol: *This server does not
      take items as a reward* above the weapon picker
- [ ] A reward of dirty money only with a stake typed: the form refuses the
      stake before sending anything. Carry a car key with your name on it and
      tick **Place anonymously**: the key is held back in the item picker
      (*carries your name*)
- [ ] A hitman with abandoned contracts: their **Ledger** shows *abandoned or
      lost* beside completed, placed and survived
- [ ] Start a handover, then widen the handover radius in the panel: the
      card's how-to still says the radius the countdown was armed with
- [ ] Switch `Config.Database.Mode` with an item still open in the review
      queue: the start refuses and names it (id, kind, contract, money);
      resolve it in the old mode, then switch
- [ ] On the test server in `mysql` mode, stop MariaDB for 30 seconds while
      placing a contract, then start it again: within a minute the console
      says *review ... settled by the server*, and the contract is on the
      board with its escrow (the client is told), or its reward is back. Do
      it again and restart the resource while MariaDB is stopped: the same
      payment is settled once the database answers
- [ ] On the `crimson.identity` account, resolve a review item on an anonymous
      contract by role. Then, on the account without it, open **Needs review**,
      All, and run `/ch-review all`: whom it paid reads as *the client*, never a
      citizen id
- [ ] On the `crimson.identity` account, dismiss a review item on an anonymous
      contract with a note naming the client by citizen id and by name. On the
      account without it, the note reads *the client (Anonymous)* in **Needs
      review**, the **Logs** and the contract's timeline, and in `/ch-review all`
- [ ] `/ch-settle <line> return <citizenid>` on a line `/ch-stuck` says does
      not say whose it is: a citizen id typed in lower case reaches the player
      (it settles to them, in capitals), a typo answers *nobody on this server
      has that citizen id; check how it is spelt* and nothing moves, and the
      panel's **Return to** answers the same. A player who is away but has a
      character still gets it at their next login
- [ ] `/ch-review <id> pay client` (a word that is neither a role the item
      names nor anybody's citizen id) is refused, naming the item's roles, and
      the item stays open; `pay Payer` pays the payer
- [ ] A line nothing of which was given (*in no retry queue*, or a *stalled
      claim*) shows only **Pay** in the panel; `/ch-settle <line> pay 100` on
      it is refused, and `pay` gives the whole line
- [ ] Void a contract with `/ch-void <id> <reason>` and restart the resource
      straight away (before the next tick): the contract's timeline still has
      `admin_void` with who and why. `/ch-void` with nothing after it answers
      its usage, a made-up id *No contract has that id*, and a second void of
      the same contract *Already closed*; none of them shows a code such as
      `invalid_input`
- [ ] `/ch-settle <line> pay <amount>` above what the line owes answers how
      much it still owes, and a second settle of a settled line *Already
      settled, by another settle or its own ending*
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
- [ ] An exclusive contract with a stake, accepted: its view lists the
      operative's stake as the amount they put up, and $0 once it is handed
      back. Two operatives on one competitive contract: the overview reads
      *2 on contracts now, holding 1 contract*
- [ ] Open the id of a contract that was never stored (a review pay left for
      staff on one): its view lists its lines, and **Return to** settles them
- [ ] Settle a line from a contract's view opened from **Stuck escrow**, then
      close the view: the line has left the list and the badge agrees.
      **Run it** on the overview runs the diagnosis. Type a search in
      Contracts, then click *Active* on the overview: every active contract
      is listed
- [ ] On the `command`-only account, `/ch-void <id>` says it changes money and
      needs `crimson.admin` itself, and how to run `ch-void` from the server
      console; `/ch-whois` on an account without `crimson.identity` suggests
      it for one identifier, never `group.admin`. `/ch-timeline` and
      `/ch-whois` alone answer their usage, and `/ch-diag <citizen id>` runs
      as that player (a made-up one says *Give a player id*, never runs as
      you). Both are in the log (`admin_timeline`, `admin_diagnose`)
- [ ] With **Target must be restrained** on, turn **Handcuffs count as
      restraint** off, then **The hitman's vehicle counts as restraint**: the
      second is refused (with it off both are marked as not applying, and
      may both be off), saying no handover could
      complete and to change the handcuffs first. Turn **List the people
      nearby** on: the answer says what the start warns about it; restart, and
      the console counts it among the settings that need attention
- [ ] Set the same switch to the value it has (a second panel left open):
      nothing is written to the log and no barred player is told again
- [ ] Rate limits: each row says what it gates. Lower *load: requests held*
      to 1: refused, with the floor. Lower it to 10: the first Save says what
      it refuses and turns brass, the second saves it. Lower the photo
      retention to 9, click Save, type 1, click Save: it arms again for 1
- [ ] Turn **Kill photos** on with `'host'` storage and no upload host, then
      off again: the diagnosis no longer lists *no photo upload host*.
      Run `/ch-diag <id>` five times with that player's app open: their own
      fault is still listed first, and the logs it asked for are not faults
- [ ] Staff freeze: look up the target of a taken contract, give a reason and
      click **Freeze** twice. Their phone says their contracts are on hold, the
      hitman's card says **On hold** with the clock standing still, and
      Verify kill, Deliver alive, the buyout and Withdraw each answer *This
      contract is on hold by staff.* with no money moved. Wait five minutes,
      click **Unfreeze** twice: the clock shows the same time left as before
      the freeze, and `freeze_player` / `unfreeze_player` rows are in the log.
      Restart the resource while frozen: still frozen after
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
