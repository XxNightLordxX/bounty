# How a contract works

The roles, the words used everywhere, a contract from placing to payout, the
money rules and the phone app's screens. The optional features are in
[features.md](features.md); the staff side is in [admin-panel.md](admin-panel.md).

## Roles

The words used everywhere are in the [glossary](#glossary).

| Role | Who | Where in the app |
|---|---|---|
| **Placer** | The player who placed the contract and funds it | **Place** to place one; **Mine** to edit, withdraw, message and watch it |
| **Hitman** | A player who accepted it (shown to others as an **operative**, by alias) | **Board** to accept; **Mine** to finish it, message, propose a change or abandon |
| **Target** | The player the contract is on | **On me**: buy out, the informant, a bodyguard |
| **Guard** | A player hired by a target as a bodyguard (roleplay, off as shipped) | **Board**, Protection tab |
| **Officer** | A player on a whitelisted job (police, EMS, as listed) | The whitelisted-job view: contracts on them, and advisories |
| **Staff** | Holders of the panel ACEs ([Permissions](../crimson-hitman/README.md#permissions)) | `/hitmanadmin` and the `/ch-*` commands |

## Glossary

One word for one thing, on the phone, in the panel, in notices and here.

| Word | Means | Never called |
|---|---|---|
| **contract** | One price on one target, with its reward held in escrow | bounty, job (a bodyguard's is a *protection job*) |
| **placer** | The player who placed a contract. Players read *the person who placed it* | client, creator (in text; `creator` stays in data and code) |
| **hitman** | A player who accepted a contract | contractor |
| **operative** | How a hitman is shown to the placer and the target: an alias (*Operative #1*), or their name if they did not stay anonymous | |
| **target** | The player a contract is on | victim |
| **reward** | What the placer put up: cash, bank, dirty money, items, weapons; paid as one or more **payouts** | pot, bounty |
| **payout** | One collection of the reward by a hitman (`Config.Limits.MaxPayoutSlots`, 1 as shipped) | slot (in text) |
| **stake** | What a placer may ask a hitman to put up on accepting, lost on walking away or running out | penalty (in text) |
| **buyout** | A target paying to close a contract on them | cleanse (that is only the command's name) |
| **on hold** | A contract staff stopped: its clocks stand and nothing on it moves. Staff do it by **freezing** a player | frozen (to players) |
| **paused** | Every contract stopped by the **app pause** (staff) or before a **server restart** | |
| **escrow** | Where a reward is held from placing until the contract ends | |

## A contract, start to finish

1. **Placing** (Place tab): pick the target, give a reason, set the reward (and a stake, a kidnapping bonus or more payouts where allowed); the second tap on **Place** names the total and takes it. The target is not told at once.
2. **Accepting** (Board): the hitman sees the reward, the rough time left and any stake, and accepts (anonymously where allowed). One hitman (**exclusive**) or several (**competitive**).
3. **The clock**: the deadline (3 h as shipped) runs only while the placer, the target and one hitman holding it are all in the city, never while the target is jailed, and stops before a txAdmin restart. So a contract nobody has taken never runs out at its deadline: it ends when it is withdrawn, or at its lifetime. Players see a rough band from the deadline or the lifetime, whichever ends first: *More than 2 hours left* (over 2 h), *1–2 hours left* (over 1 h, up to 2 h), *Under 1 hour left* (over 15 minutes, up to 1 h) and *Under 15 minutes left* (15 minutes or less); staff see the exact time. A two-day lifetime (`Config.Limits.ContractLifetimeSeconds`) ends any contract, the time its players were away included; the time a staff freeze, the restart hold or the app pause took is given back to it, and a staff extension past it (or `/ch-refresh timers`) moves it out to at most two days from that moment.
4. **Finishing**: as shipped only a live handover completes it (`Config.Completion.Fulfilment = 'alive'`): the hitman brings the target alive within `Config.Kidnap.Radius` of the placer and the three stay close for `Config.Kidnap.CountdownSeconds`. With `'either'`, a verified kill completes it too (**Verify kill**, with or without a kill photo).
5. **Ending**: completed, the hitman is paid from escrow (owed and paid at their next login if away or full). Withdrawn by the placer while nobody holds it, expired, voided by staff or bought out: the reward goes back to the placer. A hitman's stake comes back to them on a completion, a void or a buyout; it goes to the placer when they walk away, are released for idling, or the deadline runs out while they hold it (a contract that only reached its lifetime hands it back). An exclusive hitman who never goes near the target is released after `ExclusiveIdleReleaseSeconds`, and so is the idlest hitman on a competitive contract that is full (`MaxHitmenPerContract`), so the place frees up.
6. **Changes**: before anyone takes it, the placer's **Edit** sheet changes reason, reward, stake, deadline, mode, the buyout price, how it is completed (*alive or dead* only where `Config.Completion.Fulfilment` is `'either'`) and whether it is placed anonymously (only where the anonymity switches allow it for that target, the creator fee charged then), each checked as placing checks it. The target cannot be changed in place: **Cancel and place again** (two taps) withdraws it with everything handed back but an anonymity fee, which is never refunded, and opens the Place form, where the new one goes through every placing check; the usual wait after withdrawing (`Config.Amendments.CancelCooldownSeconds`) applies. Once taken, the reward can still be raised (a kidnapping bonus raised is escrowed as that percentage of every money payout still held, the ones added later included), the deadline extended, and anything else proposed (**Propose change**) for the hitman to accept.

## The meeting point

On a contract only a live handover completes, once a hitman holds it the placer can tap **Set meeting point here** (asked first) to mark where they stand (`Config.Kidnap.MeetingPoint`, on as shipped).

- **Who gets the marker**: the placer and every hitman active on the contract get a yellow *Meeting point* marker on their map, seen from anywhere. Nobody else does: never the target, a bystander, or staff who are not a party. The coordinates go only to those games, never to the app's page.
- **What each side is told**: both get a phone notice (*Meeting point set*, or *Meeting point moved*) saying what to do, and their card under Mine shows the same words as a *What to do* line. The placer: be at the meeting point, stay within `Config.Kidnap.Radius` of the hitman and the target and keep still while the hitman taps **Deliver alive** (`Config.Kidnap.CountdownSeconds`), and follow it in the app; there is nothing for them to tap. The hitman: bring the target alive there (cuffed or in their vehicle where `RequireCoercion` is on), get within the radius of the person who placed it, open the app and tap **Deliver alive** on the contract under Mine, and hold. Neither notice names the other side.
- **With Confirm handover on** (`Config.Kidnap.PlacerConfirms`): the placer's words say to tap **Confirm handover** on their card within `Config.Kidnap.ConfirmSeconds` once the hold is done, and the hitman's that it pays once the placer confirms.
- **When it changes**: moving the point moves the marker on every map. A hitman who takes the contract after it was set gets the marker and the notice when they accept. A party who logs out loses it from their map and gets it back when they return (and after a restart).
- **When it goes**: off every map when the placer clears it, when the contract is completed by the handover, cancelled, expired, voided or bought out, and when the last hitman walks away, is released for idling or is removed by staff. A hitman who leaves while others stay loses it from their own map only. Turning the switch off takes it off every map; turning it on puts it back.

## Confirm handover

Off as shipped (`Config.Kidnap.PlacerConfirms = false`): a live handover pays the moment the hitman has held the target for `Config.Kidnap.CountdownSeconds`. On, the hold no longer pays by itself:

- **The placer confirms**: once the hold is done, their card under Mine shows **Confirm handover** and **Decline** (two taps each, the second naming what it does) for `Config.Kidnap.ConfirmSeconds` (60), and their phone says so. The payout is made once they confirm. Nothing is sampled during the window: the hold is what proves the handover, so a hitman whose game crashes or who logs out in the window keeps it (a payout while they are away is owed and given at their next login).
- **Decline, or no answer**: a decline pays nothing; the contract stays open, and the hitman may tap **Deliver alive** again after `Config.Kidnap.RearmCooldownSeconds`, as after any failed handover. A window that runs out does the same, unless `Config.Kidnap.ConfirmMissed = 'pay'`, which pays as if confirmed. The hitman reads the same words for a decline and a timeout.
- **Declines are capped** (`Config.Kidnap.MaxDeclines`, 2 as shipped; 0 = no limit): each decline, and each window left to run out under `'rearm'`, counts against the contract. Once a placer has used them all, the next handover held for its countdown pays without asking them (pay by default rather than a staff review, so an alive-only contract cannot be held open by declining for ever), and the placer is told why. Counted in memory: a restart, which ends every handover, starts the count again. A Confirm or Decline that arrives after the window closed (run out, rearmed or paid by the tick meanwhile) is answered *no handover* rather than reported as done.
- **Anonymity**: the hitman is told the person who placed it confirms; the placer is told nothing of who holds the target. Only the placer is answered; anybody else asking is told not found.
- **Holds**: a staff freeze stops a handover waiting on its confirm, and nothing is paid. The window stands still on the restart hold (a confirm is refused until it lifts) and while the app is paused (`Config.Holds.AppPaused`; a confirm still pays). A handover keeps the rule it was armed under if the switch is changed meanwhile.

## Money rules

- Every reward is held from placing to ending; a payout comes only from what is held, in exactly the sources it holds (dirty money in, dirty money out: nothing is converted, because `sc-blackmarket` values dirty money above clean). The one exception is `Config.Roleplay.DirtyPayouts`, off as shipped: it hands a hitman's cash or bank payout over as a dirty money item, at a whole number of items a dollar (`Rate`) or as one item carrying its worth, so nothing is lost; refunds always go back as they were taken.
- A payout to a player who is away or full is owed and given at their next login (and retried every 30 s while online). One the server could not give after three tries waits for staff under **Money waiting** in the panel's inbox.
- Every completion (a verified kill, a live handover, a proof item, a confirmed handover) is paid by one claim, after one check that it may pay (still on it, no staff or restart hold, no slot cooldown, a slot left). Once paid, a payout may wait in escrow, owed to the hitman, for the payout checks switched on, in order: body disposal (`Config.Disposal`), then proof of intent (`Config.Roleplay.ProofOfIntent`); it is handed over by the same retry once none holds it.
- Anything no rule can settle (a buyout the store would not record, a payment the database did not confirm) goes to **Needs review** for staff.
- Caps: `Config.MaxContractValue`, each source's `max` (per part of a reward: a payout's baseline, its bonus, one addition; `Config.MaxContractValue` bounds the whole contract), `Config.Penalty` for stakes, `Config.Bailout` for buyouts; every figure is checked on the server, never taken from the phone.

## What stops it being abused

- One account can never be two parties to a contract (`Config.AntiCollusion`); a target cannot be listed again for a while after a contract on them closes (`TargetCooldownAfterResolveSeconds`; not after one withdrawn or run out before anybody took it, where only the placer who withdrew it waits), nor by the same placer. While the target is in the city, an untaken contract whose named placer is away does not fill one of the target's places (`MaxActiveContractsPerTarget`): it cannot be taken or worked, so two cheap contracts from friends who log off do not keep everybody else off the target. An anonymous placer's contracts always count.
- New characters and players just online cannot be targets (`Config.Immunity`); whitelisted-job targets may be (`Config.Targeting.AllowProtectedJobTargets`, on as shipped), and the advisory warns officers. The Place search marks somebody who has played too little (`MinTargetPlaytimeHours`) as *Too new to be a target yet*. A target who leaves the city while an operative is at work on them (a handover counting on them, or a hit landed within `MinTargetSessionMinutes`) and comes back within `MinTargetSessionMinutes` is not "just online" for that operative: quitting does not buy ten minutes of immunity. Everybody else, and a target who left with nobody at work on them, gets the floor as before.
- A contract placed where the placer may not stay anonymous says so on the Place form, in the officer warning and on the second tap: it goes out under their name, the target sees who placed it, and an officer's whitelisted-job view shows it at once.
- Barred jobs (`Config.BlockedJobTypes`, `BlockedJobNames`) never use the app; they see only the whitelisted-job view: the contracts on them, with **Buy out** on their own where buyouts run, and **Notify me**.
- Every request is rate-limited per player (`Config.Cooldowns`), every write is audited, and nothing a player's game sends is trusted for money, items or position.
- Anonymous parties stay anonymous to everybody but staff holding `crimson.identity`, in every view and log.

## The app's screens

Every screen says in one line, at its top, what it is for. The **Board**,
where the app opens, also sums up what you have going (*N taken*, *N
placed*, *N on you*: a tap on each opens where they are) and has one
**search** over the contracts on the board page on screen and the app's own
screens: type a name or a word, and the cards that do not match step aside
while the screens that do (*Open Ledger*, *Open Place*…) are one tap away.
The board comes a page at a time, so a contract on a later page is found
there (**More**); with nothing on this page matching, the search says so.

## The most common actions, in taps

Every write takes two taps (the second confirms). Counted from the tab the
action starts on; typing is not counted.

| Action | Role | Taps |
|---|---|---|
| Accept a contract | hitman | 2 (Accept, then Anonymously / Under my name / Accept) |
| Place a contract | placer | 2 after the form (Place, then *Tap again to place* with the total) |
| Deliver alive | hitman | 1, then hold the countdown |
| Verify kill (`'either'`) | hitman | 1, then the photo |
| Message the other side | placer or hitman | 2 (Message, Send); one operative opens straight away |
| Buy out a contract | target | 2 |
| Withdraw an untaken contract | placer | 2 |
| Abandon a contract | hitman | 2 |
| Edit an untaken contract | placer | 3 (Edit, Save, Confirm) |
| Raise the reward on a taken contract | placer | 2 after the amount |
| Extend the deadline | placer | 2 after the minutes |
| Propose a change, or answer one | either | 3 to propose, 2 to answer |
| Buy the target's informant | target | 3 (Informant, pick, Pay) |
| Buy an informant tip | hitman | 2 |
| Report a contract to staff | any party | 2 |
| Set or clear the meeting point | placer | 2 |
| Move a protection job's meeting pin | target | 2 |

