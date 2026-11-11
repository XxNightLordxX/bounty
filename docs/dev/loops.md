# Loops: every timer, tick job and thread

Everything in `crimson-hitman` that runs on a clock, in one table each for
the server, the client and the two pages. Each row says what starts it, how
often it runs, the deadline that interval has to meet, what it cost when it
was measured, and why it cannot reasonably cost less.

**How it was measured.** The test harness, on a city of **200 live
contracts and 64 players**, ten minutes of ten-second ticks, on the `json`
and `mysql` stores, with every optional feature (`Config.Improvements`,
`Config.Roleplay`) **off** and then **on**:

```bash
CH_PERF=1 CH_SUITES=loops_spec lua5.4 tests/run.lua
```

prints, for every job: runs in ten minutes, average and worst ms a pass,
the most statements one pass sent (`mysql`), and every call it made to the
store. The harness runs `mysql`'s statements in Lua, so read the statement
counts rather than its milliseconds. `tests/loops_spec.lua` pins the
schedule, the early exits and the budgets below; `tests/handlers_spec.lua`
and `tests/perf_round3_spec.lua` pin the requests and the capped passes.
On a live server, `/ch-diag` lists every job with that server's own worst,
average and last times and its interval. What a player's `resmon` should
read is in the README (*Performance*, *What resmon should show*).

**Off / on.** A feature switched off costs its job one comparison: no store
call and no statement in ten minutes (`tests/loops_spec.lua`, *every
maintenance job on a busy server*), and no client thread. With every
feature on and nothing due, no job sends more than the statements and
store calls pinned in `BUSY_ON` there.

## The maintenance tick

One server thread (`StartTick`, `server/main.lua`), every
`Config.Audit.FlushIntervalMs` (10 s as shipped). Each job runs inside
`pcall` through `job()` and is timed. Jobs in `SCHEDULE` come round every
`every` seconds on a phase of their own, so no two heavy jobs share a tick
(one tick's jobs run in the same server frame: what shares a tick shares a
hitch); self-gated jobs keep their own next due time. Everything that reads
what is running shares one read per change (`Projection.liveSnapshot`).

Cost columns: average ms a pass `json` / `mysql`, features off and on alike
unless said; statements a pass on `mysql` with nothing due.

| Job | File | Interval / trigger | Deadline it guards | Cost (json / mysql) | Why it cannot reasonably go lower |
|---|---|---|---|---|---|
| `contracts.releaseIdleHolds` | `server/contracts.lua` | 10 s | An idle exclusive hold is released within one tick of `Config.Limits.ExclusiveIdleReleaseSeconds` | 1.1 / 3.0 ms; **1 statement** (was 25); 75 ms and about 250 statements releasing its cap of 25 | Reads the shared snapshot and asks `qbx_core` once per person; at most 25 releases a pass. Its idle clocks (kept for a restart, at most once a minute each) go in **one write a pass** (`Storage.writeRpRows`; on `json` a file of their own, `clocks.json`, with only the changed rows encoded): they were a statement a row on `mysql` and a rewrite of `records.json`, the ledger with it, on `json` |
| `expireContracts` | `server/main.lua` | 10 s, skipped until the next deadline, a presence change or a contract change | A contract ends on the tick its deadline passes | 0.02 / 0.02 ms, 0 statements; 317 ms and 726 statements ending its cap of 25 | Sleeps until the soonest deadline. Each ending re-reads its contract under its lock, kept because it moves money |
| `audit.flush`, `storage.flush` | `server/audit.lua`, `server/storage/` | 10 s | A crash loses at most one tick of log rows and (`json`) changed files | `json` flush 0.6 ms (was 2.0: the idle clocks no longer rewrite `records.json`); `mysql` 0.00 ms, 0 statements | Only what changed is written |
| `storage.heartbeat` | `server/storage/` | `json` 60 s, `mysql` 10 s | A restart's downtime is dated from it (contracts paused from then) | 0.00 / 0.05 ms; one statement or file | Kept at 10 s on `mysql`: a crash's pause would otherwise start up to a minute early, which players see as time on their contract |
| `playtime.pass` | `server/playtime.lua` | 60 s | Playtime is counted in minutes (`Config.Immunity`) | 0.13 / 0.8 ms; one transaction of a row per player (64) | One batch for everybody |
| `storage.prune`, `ledger.forgetOldPhotos` | `server/main.lua` | 600 s, every tick while a batch is full | Retention counts days | under 0.02 ms; 2 statements | At most 25 contracts a pass on `mysql` |
| `contracts.finishEndings` | `server/main.lua` | 30 s, every tick while it leaves any | Staff are told a stopped ending settles within a minute (`/ch-settle`) | 0.04 / 0.15 ms; 1 statement | The one read of the held escrow that can find one; an ending that raised is not otherwise known after a restart |
| `escrow.retryWaiting` | `server/main.lua` | 10 s, each player at most every 30 s | A payout waiting for room in pockets goes once there is room | 0.00 ms, 0 statements | In memory until a player has something waiting |
| `bailout.processQueue` | `server/bailout.lua` | 10 s | A paid buyout is settled on the next tick | 0.00 ms, 0 statements (one index look) | The queue is read from an index; the store only when it holds something |
| `review.retryUnwritten`, `review.decide` | `server/review.lua` | 10 s | A payment the database did not confirm is settled once it answers | 0.00 ms, 0 statements | One look at what is waiting |
| `contracts.retryStuckJoins`, `retryStuckClaims`, `retryStuckCreates` | `server/contracts.lua` | 10 s | Work a throw left part-way is finished on the next tick | 0.00 ms, 0 statements | Empty tables until something raised |
| `amendments.expire`, `death.sweep`, `ratelimit.sweep`, `app.sweepHandles`, `app.sweepFloodCounters` | `server/amendments.lua`, `server/completion/death.lua`, `server/ratelimit.lua`, `server/app.lua` | 10 s | Proposals, death records, rate buckets and handles age out by the tick | under 0.01 ms, no store call | Memory only |
| `notify.deliverKept` | `server/notify.lua` | 10 s | A notice kept past the per-minute budget goes on the first tick its minute opens | 0.02 ms, no store call | Nothing read while nothing is kept |
| `bridges.refreshAccess` | `server/bridges.lua` | 30 s | The backstop for the events that tell a player at once (login, job, duty, setting) | 0.19 ms (7 ms seen live), no store call | A job read a player online; the events act at once, this only catches what they miss |
| `holds.tick`, `sanctions.tick`, `summary.tick`, `org.payroll` | `server/holds.lua`, `server/sanctions.lua`, `server/summary.lua`, `server/org/init.lua` | 10 s | A restart hold, a suspension, the daily summary and pay day end or post on the tick they fall due | 0.00 ms, no store call, off and on | One comparison each until due |
| `org.extras` | `server/org/extras.lua` | 10 s, its own gate 30 s | Organisation contracts that ran out go to the open board, approvals run out, duty of players gone ends, old channel messages go | 0.00 ms, no store call while off; one contract read per organisation contract a pass while on | One comparison while off |
| `holds.syncAppPause`, `thresholds.sweep` | `server/holds.lua`, `server/thresholds.lua` | 60 s | The app pause follows its switch at once (`Settings.watch`); the alert windows are an hour and more | 0.00 ms | A comparison or two |
| `target_limits.prune` | `server/targetlimits.lua` | 300 s | Player adjustments whose facts ran out leave the store | 0.00 ms, no store call | Nothing while none has run out |
| `photo.sweep`, `photos.expire`, `photos.forgetKept`, `photo.loadAllowedHosts` | `server/completion/photo.lua`, `server/photos.lua`, `server/ledger.lua` | 10 s, only while kill photos are on or one is kept; the host list every `Config.Completion.PhotoHostRefreshSeconds` | An unsaved photo view, a token or a kept photo ends on time | 0.00 ms, 0 statements; nothing at all with kill photos off | An index in memory |
| `record.tick` | `server/record/` | 60 s | Heat cools and the police bulletin goes on its `BulletinEveryMinutes` | 0.01 ms, 0 statements, off and on | Off: one switch read. On: heat in memory, pruned only once the oldest has cooled |
| `imp_decay.tick` | `server/imp_board.lua`, `server/imp_decay.lua` | 60 s, on a tick of its own, asleep until the soonest step | A decay step lands within a minute of due | 0.00 ms off and with nothing due; 91 / 136 ms and about 300 statements for its cap of 25 steps | Each `rise` step is a charge through the placer's own path, kept because it moves money |
| `imp_weekly.tick` | `server/imp_weekly.lua` | 10 s, asleep until the post | The weekly post goes on its hour | 0.00 ms | The calendar worked out once; one comparison a tick |
| `rp.tick`, `rp_intent.sweep`, `rp_protection.sweep`, `informant.retryUnsaved` | `server/rp_consequences.lua`, `server/rp_intent.lua`, `server/rp_protection.lua`, `server/intel/informants.lua` | 10 s | EMS re-listing, proof-of-intent holds and bodyguard jobs end on time; a refused write is retried | 0.01 ms, 0 statements | Each reads only its own rows in memory. They run with their switch off too, so switching one off strands nothing |
| `disposal.tick`, `mission_steps.tick` | `server/disposal.lua`, `server/missionsteps.lua` | 10 s | A disposal step's clock and a step marker's lapse | 0.00 ms, 0 statements | Nothing while no step runs or no marker is drawn |
| `rp_places.announce` | `server/rp_places.lua` | 60 s | NPC places rotate by the hour; a panel change is announced at once | 0.01 ms | A comparison of the hour |

A whole tick with every job due, plus a sampler pass, stays under 100 ms
with the features off and under 300 / 450 ms (`json` / `mysql`, harness)
with them on (`BUDGET_MS`, `BUDGET_ON_MS`); the pass where everything falls
due at once ends a share (`MASS_BUDGET_MS`). Measured now: 3 to 8 ms and 14
to 20 ms off, 40 and 85 to 100 ms at worst on (the hour the decay steps
fall due); the mass pass 67 ms and 1,296 statements (was 78 ms and 1,322).

## The server's other clocks

| Loop | File | Interval / trigger | Deadline it guards | Cost | Why it cannot reasonably go lower |
|---|---|---|---|---|---|
| Condition sampler (`death.sampler`) | `server/completion/death.lua` | `Config.Completion.ConditionSampleMs` (1 s) while a contract runs; **no thread while none does** (was a pass a second all game) | Damage is credited from the last sample, so attribution is only as precise as this | 0.94 / 1.13 ms a pass with 200 running, 0 statements while nothing is written; nothing at all with none | The pass that finds nothing running ends the thread; the next write through the store (`Projection.onWrite`) starts it, so a contract is sampled within a second of going live as before. Each target's state and position is read once a pass |
| Handover countdown | `server/completion/kidnap.lua` | `Config.Kidnap.TickMs` (1 s), only while a handover runs | The countdown a hitman sees | a read of its contract a pass | The thread ends with the last handover |
| Hit checks | `server/completion/death.lua` | 50 ms timers, only while a hit waits for its damage | A hit is matched to the damage that follows it | per hit | Ends with the hit |
| Unreported death, revive confirm | `server/completion/death.lua` | one timer each | The victim's own report is waited for, then the death is attributed | per death | A timer, not a loop |
| Tip warnings, tip clears | `server/intel/rules.lua`, `server/intel/tip.lua` | one timer each, due time | `Config.Intel.WarningDelay`, the tip's map time | per tip | Due-time timers |
| Discord poster, alert flush, notice floor | `server/discord.lua`, `server/alerts.lua`, `server/notify.lua` | timers, only while something waits | Posts and pushes go in order within their budgets | per item | Nothing while nothing waits |
| Database await timeouts | `server/storage/mysql.lua` | a timer an await | A database that does not answer is said, not waited on forever | per statement | Cancelled on the answer |
| Waiting for `qbx_core` at start | `server/boot.lua` | 1 s, only until it is started | The resource starts as soon as the framework is up | none after the start | Ends at once on a normal start |

## Client

| Loop | File | Interval / trigger | Deadline it guards | Cost | Why it cannot reasonably go lower |
|---|---|---|---|---|---|
| Death watcher | `client/main.lua` | 1 s while a character is loaded | The server waits a few seconds (`Death.UNREPORTED_WAIT_MS`) for the victim's own report | a few natives, nothing made a pass; an event only on a change | It runs for every player, not only targets: a game told when it is named would tell a target there is one. The damage event names the killer the moment it happens; this only reads the medical state |
| Mask watcher | `client/main.lua` | 1 s, only while `Config.Targeting.AllowNearby` is on | The nearby list hides a masked player within a second | one native; an event only on a change | No game event says a component changed |
| NPC distance loop | `client/npc.lua` (`CrimsonNpc.watch`), for `client/rp_npc.lua` and `client/org.lua` | 1 s while an NPC is near or drawn, 2 s further off; **no thread while none is placed** | An NPC is drawn before a player reaches it (80 m in two seconds at speed) | one vector a pass for the player, none for the places | **One loop for both** (was a loop each for the broker and informant and for the organisation's NPCs). Peds go at logout |
| App heartbeat | `client/main.lua` | 15 s | Puts the app back on a phone that lost it | one comparison; nothing sent | lb-phone has no event for an app it dropped; its restart is handled at once (`onClientResourceStart`) |
| Asking for access | `client/main.lua` | 2, 2, 2, 5, 5, 10 s, then 30 s, until answered | A start that missed the join push | one event a try | Ends on the answer |
| Admin panel Escape guard | `client/admin.lua` | every frame, only while the panel is open and for a moment after | The pause menu never opens over the panel | two control reads, nothing made | Ends when closed |
| Admin panel focus | `client/admin.lua` | 5 times at 50 ms on open | The focus sticks | none after | SC focus handling |
| Marker lifetimes, request timeouts, tip retries | `client/missionsteps.lua`, `client/main.lua`, `client/rp_npc.lua` | one timer each | A marker the server's word did not clear goes on time; no request waits forever | per item | Timers, not loops |

## The pages

| Loop | File | Interval / trigger | Deadline it guards | Why it cannot reasonably go lower |
|---|---|---|---|---|
| Handover poll | `ui/app.js` | 1 s on screen, 5 s put away, only while a handover runs | The countdown bar the hitman watches | The server keeps the outcome two minutes and tells the phone how it ended; nothing else runs while the phone is put away |
| Camera watch | `ui/app.js` | 1 s while the kill photo camera is open | lb-phone takes the game render down itself when the phone is put away | Ends with the camera |
| Search debounce, toasts, confirms | `ui/app.js`, `ui/admin.js` | one timer each | A typed search waits for a pause; a two-click confirm lasts 3 s | Timers |
| Admin overview | `ui/admin.js` | every `Config.Admin.PanelRefreshSeconds` (10 s), only while open | The overview staff watch | Stopped on close; an answer the same as the last only moves its *Updated* time |

## What changed in step 6

- **Idle-hold clocks**: one write a pass (one statement on `mysql`, was up
  to 25), at most 100 rows a pass (was 25, which let 200 holds fall behind
  the minute); on `json` in `clocks.json`, not `records.json`.
- **Condition sampler**: no thread while nothing is running; woken by the
  next write.
- **NPC loops**: the roleplay NPCs' and the organisation's distance loops
  merged into `CrimsonNpc.watch`.
- Everything else was already event-driven or asleep until due, and is
  pinned as it is.
