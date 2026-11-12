# Optional features

Every feature beyond placing, taking and paying a contract: what each does,
its switch and what it shipped as. The settings themselves, with their
shipped values, are in [configuration.md](configuration.md); how a contract
works is in [how-it-works.md](how-it-works.md).

Each is switched in the panel's **Game rules** and in `config.lua`; each has
a **How it works** card in the panel's Help linked to its settings. Switching
one off never strands money: what is under way finishes under the rules it
started with, and new actions are refused with *turned off by the server*.

## Core switches

On as shipped unless marked: buyouts (`Config.Bailout.Enabled`), proposals
(`Config.Amendments.Enabled`), messages and calls (`Config.Relay.Enabled`),
headshots (`Config.Mugshot.Enabled`), criminal progression
(`Config.Record.Progression.Enabled`, under A hitman's record), the whitelisted-job view and its Notify me
(`Config.WhitelistedView`), kill photos (`Config.Completion.KillPhotos`, off),
the nearby target list (`Config.Targeting.AllowNearby`, off).

## Anonymity

Off as shipped. `Config.TargetClasses.default.AllowAnonymousPlacer` and
`AllowAnonymousHitman` let a contract be placed or accepted anonymously, for
a fee (`Config.Anonymity.CreatorFee`, `HitmanFee`). Every rule that differs
by who the target is lives in one table per target class,
`Config.TargetClasses`: `default` for every target, `whitelisted` for a target
on a whitelisted job (read by one resolver, `Util.targetRule`). An anonymous party is
*Anonymous* to every player; staff need `crimson.identity` to see who it is.

## Intel

Everything a player can learn for money lives under `Config.Intel` and one
admin screen group, **Intel**. Three paid look-ups, each off as shipped, all
behind `Config.Intel.Enabled`: the **target's** (`Config.Intel.Informant`:
who is after me, with a chance of an answer), the **placer's**
(`Config.Intel.PlacerInformant`: which operative took it) and the hitman's
**tip** (`Config.Intel.LocationTip`: the target's rough area on the map, and
the target is told). Each is sold where its own `Enabled` is on and its
switch for the target's class is (`Config.TargetClasses.default` /
`.whitelisted` `.Informant`, `.PlacerInformant`, `.LocationTip`).

Every purchase runs through one engine (`server/intel/engine.lua`): one check
(who may buy it, the switches and the target's class, a staff hold, the
contract still open, the product's limits, waits and price), the price the
page quoted held to the price now, the charge last, and the price given back
in full, under the product's own audit action, if anything stops the purchase
after the charge (the contract ending, a staff hold, an operative leaving, a
read that failed). A refund that cannot be paid at once is owed (the
informants, going dark) or left for staff (the tip), as before.

All off as shipped, each `Config.Intel.<Feature>.Enabled`:

| Feature | What it does |
|---|---|
| **Tip warning delay** (`WarningDelay`) | A tipped target is told a random while later (`MinSeconds`..`MaxSeconds`); the time on their card is rounded to 5 minutes; survives a restart |
| **Tip limits** (`TipLimits`) | One tip per hitman per contract, and/or each further tip costs twice the last, up to `MaxCost` |
| **Hold before a tip** (`HoldFirst`) | A tip only once the hitman has held the contract `MinHeldMinutes` |
| **Informant second try** (`SecondTry`) | The target's later look-ups cost `SecondTryCostPercent` of the price |
| **Tip safe zones** (`SafeZones`) | No tip while the target is inside a zone (`'x, y, radius, name'`); the hitman is told only that the informant can't place them |
| **Go dark** (`GoDark`) | A tipped-off target pays to make tips on them find nothing for `Minutes`; the hitman gets their money back. Sold only while tips on that contract are (`Config.Intel.Enabled`, `Config.Intel.LocationTip.Enabled`, and `Config.TargetClasses.whitelisted.LocationTip` for a whitelisted-job target); a window already paid for holds, and stays on the card, to its end. The window stands still while its contract is on hold (a staff freeze, the restart hold and the restart, the app pause), as an informant tip's showing and wait do. Kept across a restart only once paid: a purchase the store could not keep is refunded, and a window that has passed is cleared from the store on the minute |
| **The informant in person** (`InPerson`) | Every informant purchase only beside the informant NPC, which moves between its places |
| **Rumours and a broker** (`Rumours`) | New contracts show only as rumours (area, reward band) until the broker NPC, or a player on a broker job, briefs the hitman for `BriefValidMinutes`. The area is the one first told, kept across restarts (FXServer's KVP store) until the contract ends |

## A hitman's record

Where a player stands lives under `Config.Record` and one admin screen
group, **Record & standing**, read and kept by one module
(`server/record/`): the counters every character has (contracts placed,
completed, failed and survived, shown on the app's Ledger, on a card's
operatives and on the panel's player card), the standing they give
(*Unproven*, *Known*, *Established*, *Notorious*) and the level the tiered
board asks for. Criminal progression is on as shipped; the rest is off,
each `Config.Record.<Part>.Enabled`.

| Part | What it does |
|---|---|
| **Criminal progression** (`Progression`) | A completion gives `TrustPerElimination` / `TrustPerKidnapping` trust through the progression adapter (`Config.Integrations.Progression`, sc-blackmarket's `AddTrust`); one missing or failing never touches the payout |
| **Reputation earned in character** (`Reputation`) | Progression trust for a completion is scaled by how it was done (thread, meeting, handover, no witnesses), up to `MaxFactor` |
| **Tiered board** (`Tiers`) | Bigger rewards locked to a progression level, 1 plus one for each `CompletionsPerLevel` completed (needs `Config.Record.Progression.Enabled`) |
| **Hitman heat** (`Heat`) | Completions on whitelisted-job targets, witness reports and bulletins give a hitman heat for `DecayHours`; at `Threshold` their targets may be warned and officers get a vague bulletin at most every `BulletinEveryMinutes` (every officer alike, a known hitman who holds a police job too) |
| **Placer record** (`PlacerRecord`) | A board card shows its placer's placed / paid out / cancelled counts over `LookbackDays`, never who; anonymous placers in bands with `ShowForAnonymous` |

## Advisory

On as shipped (`Config.Advisory.Enabled`). A contract on an officer or another
whitelisted-job member is announced to the recipient jobs on their phones
and, with `UseDispatch`, in sc-dispatch, at the stages switched on (`OnCreate`,
`OnAccept`, `OnLocationTip`, `OnCancel`). The placer and the hitman are warned
first and the card is marked on the board.

## Staff tools

- **Freeze** a player (Players): every live contract of theirs goes on hold until **Unfreeze**, which gives the time back. Players see only *on hold by staff*.
- **Suspend** a player from contracts, or **protect** one from them, for hours, days or for good; neither touches running contracts. **Lift** ends either.
- **Pay** a player by hand (cash or bank, a reason, at most `Config.Staff.ManualPaymentMax`).
- **Deadlines**: extend or shorten a live contract by up to `Config.Limits.StaffDeadlineMaxAdjustSeconds`, never under `StaffDeadlineMinLeftSeconds`.
- **On a contract**: staff notes, remove an operative (stake to the placer as a walk-away, or returned), edit a player's text, export, *As a player sees it*.
- **Change reward** on a live contract (`crimson.admin`, a reason, two clicks, at most `Config.Staff.RewardChangeMax` at once): a raise is *added by staff* (taken from nobody, and handed back to staff, never to the placer, if the contract is cancelled, expires, is bought out or voided), or charged to the placer's cash or bank if staff choose that and the placer is in the city; a cut comes off what staff added first, then the placer's own, each part going back to whoever funded it (queued for a placer who is away), never below `Config.Limits.MinContractReward` and never touching money already owed or being paid: the store cuts a line only while it is owed to nobody and being given to nobody, and the change stops at a claim that starts while it runs, so a claim's hitman is paid what the claim owed them. Refused while a payout is being settled, a buyout waits out its delay, or the contract is on hold (unfreeze first). The placer and every operative are told staff changed it; nobody is named.
- **Reassign** a live contract to another hitman (`crimson.admin`, a reason, two clicks): the hitman is named by a Players lookup and must be in the city and pass every check their own Accept would (job, eligibility, not the target, the placer or the target's guard, their limits, the stake rule). Every operative on it is taken off as **Remove** does (their stake to the placer, or returned; barred from taking it again unless staff untick it), all under the contract's own key, so nobody takes it from the board in between. The new hitman's stake is waived (`Config.Staff.ReassignStake = 'waive'`, as shipped) or charged as on Accept (`'charge'`). They go on it **anonymously** and are never charged the anonymity fee, unless staff choose **Named to the placer** or **As they chose before** (their own earlier stint on it); only a server with a hitman's anonymity turned off names them anyway, as it names every hitman. Every check of the acceptance (the stake money, `MaxAcceptedPerHitman`, anonymity, a walk-away's wait) is asked before anybody is taken off, and the preview asks the same, so it refuses what the reassignment would. If the acceptance is still refused once the operatives are off (a balance or a limit that moved in between), every operative is put back on it with their stake still held and the bar this set lifted, and staff are told so.
- **App pause** (`Config.Holds.AppPaused`): nothing can be placed or taken, and every clock is held, for an event.
- **Daily summary** (`Config.Staff.DailySummary`, off) at `DailySummaryHour`; **alerts** past the `Config.Staff.Alert*` thresholds, posted to Discord with `Config.Alerts.ToDiscord`.
- **Moderators** (`crimson.moderator`): read without identities, freeze, suspend, protect, void and move deadlines; settings, payments and settling stay with `crimson.admin`.

## Roleplay

All off as shipped, each `Config.Roleplay.<Feature>.Enabled`.

| Feature | What it does |
|---|---|
| **Witness heat** (`WitnessHeat`) | A completion with bystanders near (or always) sends officers a vague witness report: a phrase, the way the hitman went and the nearest named area, optionally a fuzzed position. Never names anybody |
| **EMS before re-listing** (`EmsRelisting`) | A target killed on a contract cannot be listed again until up for `TreatedMinutes` (or revived by a medic with `RequireEMS`), at most `MaxHoldMinutes` |
| **City news** (`CityNews`) | A completed contract on a whitelisted-job target (or any, with `AllTargets`) posts an anonymous news item on Birdy or as a server event |
| **Dirty money payouts** (`DirtyPayouts`) | A hitman's cash and bank payout is handed over as a dirty money item (by count or by worth); refunds go back as taken |
| **Proof of intent** (`ProofOfIntent`) | A payout is held, never refused, until the hitman has worked the contract in character (`MinMessages` to the placer, a live handover or a meeting point), at most `HoldMaxMinutes` |
| **Bodyguards** (`Protection`) | A target hires protection from On me (reward held, pin where they stand); a guard takes it from the board. Ended without a completion: the guard is paid; completed anyway: their share (`PayOnCompletionPercent`), the rest back. Switched off mid-job, a live job carries on: the target can still move its pin or cancel it, and its guard keeps the Protection tab with Set GPS |
| **Hit on the hitman** (`HitOnHitman`) | A target whose informant named an operative may place a contract on them, under every placing rule |
| **Burner phone** (`BurnerPhone`) | Placing, accepting and every contract action (turning contract decay off included) need the item; it may be used up on placing or accepting. Sell it through sc-blackmarket |
| **Broker and informant placed from the panel** (`NpcPlaces`) | Staff place the broker and the informant in the admin panel's Locations by standing there (Use my position, read by the server); each rotates among the places set as its `RotateHours` says. Kept by the store with the other spots staff set, on every backend. The `Locations` lists stay the defaults: used while none is set, after Reset to config, and with this off |
| **Reason quality** (`ReasonQuality`) | A typed reason needs a least length and number of words; low-effort phrases are refused or placed and sent to Needs review |

## Improvements

All off as shipped, each `Config.Improvements.<Feature>.Enabled`. The informant and tip rules are Intel's (above).

| Feature | What it does |
|---|---|
| **Contract decay** (`ContractDecay`) | An untaken contract's reward rises (charged to its placer, up to `MaxIncreasePercent`) or its deadline comes in, every `Hours` of waiting; time on a staff freeze, the restart hold, the app pause, held by an operative, or with decay itself switched off does not count. `rise` applies only to contracts placed under the placer's own name: a step charged when an anonymous placer logs in would show on the board when they did, so an anonymous contract never rises (its card says so). The placer can stop it on their card |
| **Proof items** (`ProofItems`) | On a contract a kill completes, the hitman may hand the placer an item taken from the target (an id card as shipped) instead of a photo. The item is checked before where anybody stands, so a hitman without it is only ever told it is missing; refused, taking nothing, under a freeze, the restart hold or the app pause. Paid as a kill would be, but recorded as what it was: the Ledger says *Proof handed over*, and there is no EMS re-listing, witness report or city news, since nobody saw a kill |
| **Weapon serial scrubbing** (`SerialScrub`) | A weapon an anonymous placer put up reaches the hitman with a new serial (as does one whose contract cannot be read). One weapon always gets the same new serial, after a restart too: it is worked out from the escrow line and a secret the store keeps (`imp_serial_secret_1` to `_5`, 140 random bits made at the first scrub), never from anything a player can see |
| **Weekly stats** (`WeeklyStats`) | One count-only post a week (`Day`, `Hour`) to `crimson_hitman_stats_webhook`, or the alert webhook |
| **Completion cooldown** (`Config.Limits.TargetCooldownAfterCompletionSeconds`) | A wait before a completed contract's target can be listed again; 0 (off) as shipped |

## Organisation

Off as shipped (`Config.Organisation.Enabled`). While it is off no job is
registered, nothing about it is read or written, every request answers
*switched off*, and contracts are placed, taken and paid exactly as without it.

On, the **hitman organisation** is a real qbx_core job (`Config.Organisation.JobName`,
`hitman` as shipped) whose roles are its grades. This resource's own tables
(`crimson_orgs`, `crimson_org_*`) are the source of truth and qbx_core is told:
the job is registered at every start with `CreateJobs` (never written into
qbx_core's own `jobs.lua`), roles with `UpsertJobGrade`, members with
`AddPlayerToJob` / `RemovePlayerFromJob` / `SetPlayerPrimaryJob` by citizen id,
so it works for players who are away too. A start that comes after players
loaded brings every online member back in step. A change made elsewhere
(`/setjob`, another resource) is adopted into the table, or put back with
`Config.Organisation.ExternalChanges = 'revert'`, the same whether it was made
while the player was online, away, or while the organisation was off (found
at their next login). A removal qbx_core cannot be believed about is always
put back: the job kept by name only, `qbx:cleanPlayerGroups` on, or a
character that loaded before the job was registered (a late start).

- **Roles and members.** Staff run everything from the panel: roles (order,
  name, label, pay, boss), hiring, roles, firing (with a reason), per-member
  grants and denies, a lock against boss edits, a codename. A staff hire is
  made at once and never made the player's primary job.
- **Joining.** A boss's hire is an **invite**: the player standing by them
  sees it on the app's board (the organisation and the role, never who asked)
  and taps Accept or Decline, twice to be sure, within
  `Config.Organisation.Limits.InviteMinutes`. Only an accepted invite (or an
  accepted application) makes them a member, and only then is the job made
  their primary one (`SetPrimaryOnHire`); the hire is checked again as they
  accept. Becoming a member any way closes every open application of theirs,
  so a stale one is never accepted over the record they have.
- **Boss permissions.** Every boss power is **off for every boss** until staff
  allow it for a boss role or one boss (Allow / Deny / Inherit). Staff can
  always do everything themselves. A boss passes on only what they hold, only
  to roles and members below their rank (level with it only with D3, never
  above), never to or on themselves, never past a staff lock (a grant or deny
  staff made, on a member or a role, is staff's alone to change, and a per-member
  grant or deny a boss made is theirs against anyone at or below their rank); revoking a power
  from a boss makes every grant they made of it inactive at once, and allowing
  it again restores them. The organisation is never left without a member in
  its top boss role, unless staff do it. Every rule is checked on the server
  for every request.
- **The powers**: 51 in all, the 35 below (31 area powers, D2, D3, and M7,
  P3 for codenames and payroll; D1 is R4) and the 16 the organisation extras
  add (M8 to M12, K4 to K8, N3, N4, A1, A2, P4, V1), each named with its extra:
  M1 view members, M2 hire, M3 fire, M4 promote/demote, M5 suspend from
  contracts, M6 member limits, M7 assign codenames; R1 create, R2 edit, R3
  delete roles, R4 set role powers; P1 role pay, P2 bonus, P3 set salaries; C1 organisation cut, C2 cut by role, C3 cut per
  member, C4 cut on stakes, C5 cut on buyouts, C6 deposit, C7 withdraw, C8 view
  funds; K1 contract access rules, K2 boss pick, K3 role cooldowns; L1 move the
  office, L2 sign-up spot, L3 meeting spots; N1 notice, N2 applications; S1
  label, S2 boss menu layout, S3 office requirement; D2 per-member grants, D3
  promote to own rank. A role moved to another rank takes its staff limit, cut,
  access rules, salary, armory limit and hidden tabs with it, and a deleted
  role leaves none behind for the next role made at that rank; a member who
  leaves (fired, or the job taken elsewhere) leaves no own cut, codename
  record, probation, strike suspension or channel mute behind for a re-hire
  (their discipline and counts stay as the record). Hire, fire, role edits, cuts and withdrawals need the
  **boss office** by default (the server's own position, `OfficeRadius`).
  Every day count (an armory role's limit and `ArmoryManagePerDay`,
  `StrikesPerDay`, `PromotionsPerDay`) and `FireCooldownMinutes` are kept
  with the organisation's settings, so a restart or a crash never starts a
  fresh day. A member is told when they are fired (with the boss's reason),
  suspended or lifted, and moved to another role: by *a boss* or *staff*,
  never by name.
  Every bound is `Config.Organisation.Limits`, and staff may set an
  organisation's own.
- **Funds.** Renewed-Banking's society account for the job when it is
  installed (`Config.Integrations.Banking = 'auto'`), this resource's ledger
  otherwise (or with `'none'`), **chosen once**, the first time the organisation is read, and kept
  (changing `Banking` later does not move them). While the bank is chosen and
  Renewed-Banking is not started, every deposit, withdrawal, bonus and cut is
  refused and the balance shows as unknown: nothing is paid from, or into, a
  ledger the bank does not see. Staff move one organisation's funds to the
  other side with `orgFundsBackend` (each organisation keeps its own side; the
  others stay where they are), which makes the job's Renewed-Banking account
  first where it has none and carries the balance across in two ledger rows
  (with `abandon`, leaving a bank that is down, nothing is carried); a crash
  part-way is finished at the next start. Every movement
  is one ledger row written once, marked with the side it moved, so a retry
  never pays twice and the ledger's balance is only its own rows; money is
  reserved before anything is awaited, so two withdrawals at once never
  overdraw it or pass a day's cap together; only whole amounts above zero ever
  reach Renewed-Banking (it would take a negative one).
- **Cuts.** A share of a member's payout (and of a stake they win, or a buyout
  premium paid to them) goes to the funds. It is shown to the member on every
  board card before they accept (`orgTerms`), echoed back by the accept (a cut
  changed since is refused, `terms_changed`), frozen on the contract at the
  figure checked, and taken out of the payout when it is paid, once per escrow
  line, as cash, bank or a dirty item, and still after a restart with the
  organisation off: what was escrowed is what the member and the funds
  received.
- **Accepting.** With `RequireJobToAccept`, only members may accept (with
  `AcceptNeedsPower`, only roles given *Take contracts*; with `OnDutyOnly`, on
  duty). Members are always held to a suspension, their own and their role's
  limits and access rules, which are only ever stricter than the server's,
  checked one acceptance at a time per member; a check that cannot be made
  refuses the acceptance. A boss pick (K2) answers the same for every member,
  so it never says who placed an anonymous contract.
- **Places.** The boss office, sign-up spots, meeting spots, NPCs and other
  places are set by staff with **Use my position** (the server reads where the
  staff member stands) and drawn as ox_target spots only for the players who may
  use them: sign-up spots for everybody, the rest for members. A boss may move
  the office near staff's point, and place sign-up and meeting spots, where they
  stand, never in a safe zone.
- **The phone's Organisation tab.** Shown in the app's tab bar (as *Org*)
  only while the organisation is on and the board says it is for this
  player: a member, an applicant, an invited player, or a player standing at
  a sign-up spot (who applies from it). Anybody else has the same five tabs
  as before, and nothing more is asked of the server. A member sees the
  organisation, their role (and codename), the board notice, their cut and,
  with payroll on, their salary. A boss sees a **boss menu** with only the
  screens of the powers the server says they hold: **Members** (hire by the
  ID over a nearby player's head, fire, set a role, suspend, limits, a
  codename, their own grants and denies), **Roles** (create, rename, delete,
  pay, salary, and a powers checklist where a power they do not hold is
  greyed as *Staff have not given you this*, and one a boss gave who can no
  longer pass it on (gone, moved below the role, or no longer holding it)
  reads *not in force* with **Give** to give it again), **Money** (the funds and ledger,
  deposit, withdraw, bonus, every cut with its staff bound), **Contracts**
  (access rules, cooldowns, boss picks), **Places** (the office, sign-up and
  meeting spots, placed where they stand: the server reads the position, the
  phone sends none), **Notices**, **Applications** and **Settings** (the
  label, the menu's names, the office rule). Every write takes two taps; every
  refusal is the server's own words; a power that needs the office is greyed,
  with why, while the server does not see them there.
- **Codenames** (`Config.Organisation.Codenames`, off as shipped). A member
  picks their own codename in the tab, or a boss holding M7 gives one to a
  member below them (then only the boss or staff change it). Each is checked
  on the server: `CodenameMinLength` to `CodenameMaxLength` characters,
  letters, digits, spaces, `-` and `_`, none of `CodenameBlocked`, and it may
  not read as another member's codename or as any character's name (every
  member's and applicant's, and every player's in the city when it is set).
  Both sides are folded before they are compared: any case, separators
  (spaces, `-`, `_`, punctuation) dropped, and the look-alikes `1`/`l`/`i`,
  `0`/`o`, `3`/`e`, `4`/`a`, `5`/`s`, `7`/`t`, `8`/`b` (also read as `a` and
  `ate`), `@`/`a` and `$`/`s` read as one, so `Po1ice`, `Admln` and `P 11`
  are caught. A member's own change waits
  `Config.Organisation.Limits.CodenameCooldownMinutes`. It is shown in the
  organisation's roster and, to a placer (and a target where names are
  shown), in place of the hitman's name, only where that name would have been
  shown at all, and always marked as one: `Viper (codename)`. A hitman who
  took a contract anonymously is still an operative, and nobody in the
  organisation is told the name behind it. The name shown is kept with the
  contract when it is taken (`crimson_org_splits.shown_name`), so leaving,
  being fired, a changed or cleared codename, or codenames turned off later
  never shows the real name on a contract that showed the codename.
- **Payroll** (`Config.Organisation.Payroll`, off as shipped). A boss holding
  P3 sets each role below them a salary, up to
  `Config.Organisation.Limits.SalaryMax` or the lower maximum staff set for
  that role (`orgSalary` with `max`). A boss's change is paid from the pay day
  after the next one (the roles screen says so) and is on the record
  (`org_salary`, then `org_salary_applied`); a change staff make takes effect
  at once. What is paid is always held to those two bounds as they are on
  the pay day, so lowering either lowers a salary already set. Every
  `PayrollDays` each member is paid their role's salary from the funds into
  their bank: one ledger row per member and pay day, by a reference made of
  both, so a restart part-way pays nobody twice and the funds fall by exactly
  what the members gained; a marker row follows once the bank took it. A
  salary the funds cannot cover is skipped and the member told (and those
  who can see the funds); the rest are still paid. A member suspended on pay
  day is skipped and told unless `Config.Organisation.PaySuspended`, and one
  pay day pays at most `Config.Organisation.Limits.PayrollPerDayMax` in all
  (0: no cap beyond each role's; members past it, from the lowest rank up,
  are skipped and told). Where the bank refuses a salary it goes back to the
  funds; a give-back that fails is on the record
  (`org_payroll_refund_failed`) and tried again every tick until it lands
  (`org_payroll_refunded`). If the server stops after a salary left the funds
  and before the bank's answer was marked, the next run never pays it again
  on a guess: it is on the record (`org_payroll_unconfirmed`) and left for
  staff in the review queue (`/ch-stuck`, kind `org_payroll_unconfirmed`):
  check the member's bank, then pay or dismiss. The pay day is kept with
  the organisation, so a restart neither skips nor repeats one; a server down
  for longer than a period pays once, not for every period missed. Until the
  pay day the maintenance tick compares one number. Every pay day is on the
  record (`org_payroll_run`, `org_payroll_skipped`).
- **Organisation extras** (server/org/extras.lua). Six more switches under
  `Config.Organisation`, each off as shipped and each needing the organisation
  on. Every boss side is its own row in Boss permissions, off until staff
  allow it; staff do all of it from the panel (Hitman organisation, **Work &
  channel**); every write takes two clicks or taps and is on the record.
  - **Contracts to the organisation** (`OrgContracts`). The placer ticks
    *Send to the organisation* on the form. The contract is placed as any
    other (the same charges, rules and refusals), then held off the open
    board while a boss holding **K4 Assign organisation contracts** gives it
    to one member and that member takes it, `AssignMinutes` each; then it
    goes on the open board and the placer is told. **K5 Reassign** moves it
    to another member or sends it to the open board at once. Only the member
    it is assigned to sees it on the board and may take it. The organisation
    sees what a board card shows (the target's name, the worth, the rule),
    never who placed it, and the placer is never told who took it beyond
    what any contract says.
  - **Accept approval** (`AcceptApproval`). A member's accept worth more than
    `ApprovalAbove` (0: every accept), or any accept of a member on probation
    (`ApprovalProbation`), waits for a boss holding **K6 Approve accepts**
    (never one's own; only below the boss's rank). An anonymous accept is
    never shown to, nor decided by, a boss who placed the contract or is its
    target, and staff see who it is only with `IdentityAce`; nor is the member
    who took an organisation contract named to its placer. Nothing is taken while it
    waits. Approved, the accept runs then with every rule checked again, the
    stake and the fee the page showed included; refused, or not answered in
    `ApprovalMinutes`, nothing was ever taken, so the stake stays with the
    member, who is told.
  - **Probation** (`Probation`). Members at or below `ProbationMaxGrade` take
    only contracts worth up to `ProbationMaxReward`, none with a stake
    (`ProbationNoStake`), until `ProbationCompletions` completions counted on
    their record from when probation began, or a boss holding **M8 End
    probation** signs them off. Staff may put a member on probation again.
  - **Duty** (`Duty`). Members clock in and out in the tab (only at the boss
    office with `DutyAtOffice`). Only members on duty are assigned, see and
    take the organisation's contracts. Where the job is their primary one,
    qbx_core is told (SetJobDuty, through the framework adapter), and a duty
    change made at a qbx duty point is taken in. A boss holding **M9 Force off
    duty** sends a member below them off duty. A character in again starts
    off duty.
  - **Private channel** (`Channel`). A message channel inside the
    Organisation tab: plain text up to `ChannelMaxLength` characters, no
    links or markup, `ChannelPerMinute` messages a member a minute, kept
    `ChannelRetentionDays` (table `crimson_org_messages`). A boss holding **N3
    Moderate channel** removes messages of members below them and mutes one
    for up to `Config.Organisation.Limits.ChannelMuteMaxHours`. The record
    keeps who wrote and how long, never the words.
  - **Dossiers** (`Dossiers`). A boss holding **K7 Write dossiers** attaches
    notes (up to `DossierMaxLength`), one of the organisation's meeting spots
    and the rules of engagement to an assigned organisation contract. Only its
    member reads it, in the tab. It has no field about the target, and notes
    holding a citizen id of the target or the placer are refused: a dossier
    never tells the hitman more about who the target is than the card does.
- **Organisation extras 2** (server/org/extras2.lua). Four more switches under
  `Config.Organisation`, each off as shipped and each needing the organisation
  on, as the extras above: every boss side is its own row in Boss permissions,
  off until staff allow it; staff do all of it from the panel (Hitman
  organisation, **Armory**, **Record & discipline** and **Applications**);
  every write takes two clicks or taps and is on the record. Nothing here
  shows a placer or a target.
  - **Armory** (`Armory`). An ox_inventory stash of the organisation's
    (`ArmorySlots`, `ArmoryWeight`), reached only through the Organisation
    tab: it is registered under a group nobody holds, so ox_inventory's own
    screen never opens it and every move goes through the limits here.
    Members put in the items staff allow (`ArmoryItems`; empty, nothing goes
    in) and take out up to their role's limit a day; a boss holding **A2 Set
    armory limits** sets a role's limit below their own rank, up to
    `Config.Organisation.Limits.ArmoryWithdrawMax`, and one holding **A1 Manage
    armory** reads the armory's log and takes out up to
    `Config.Organisation.Limits.ArmoryManagePerDay` more a day. Items go in and
    out only at the boss office with `ArmoryAtOffice`; a member suspended from
    contracts takes nothing out. An item is taken from one side before it is
    given to the other, and given back where the other side refuses it, so
    nothing is made or lost; a give-back that fails is on the record
    (`org_armory_refund_failed`). Staff stock it with an allowed item, take
    items out (for good) and set any role's limit. With
    `Config.Integrations.Inventory` set to `none`, or no inventory script
    started, the armory is off and the console says so in one line. The
    limits a day are kept in memory: a restart starts the day again.
  - **Record and leaderboard** (`Stats`). Each member's completions, failures,
    earnings and reliability in the organisation (completions out of
    completions and failures, once `StatsMinForRate` are in), counted from the
    record's own outcomes from when it is on, and a leaderboard by
    completions. It fills the tab's **Your record** card. Players see how long
    a member usually takes as a band (under `StatsBandShort` minutes, up to
    `StatsBandMid`, up to `StatsBandLong`, over it), never the exact time, and
    no other member's money; a boss holding **M10 View member stats** sees
    every member's failures and earnings; staff see the average minutes too,
    and may reset one member's counts or everybody's. `StatsLeaderboard` off
    shows the leaderboard only to M10 holders and staff.
  - **Discipline** (`Discipline`). A boss holding **M11 Issue strikes** gives a
    member below them a strike or a written warning with a reason (up to
    `Config.Organisation.Limits.StrikesPerDay` a day); the member is told and
    sees it on their record, never which boss gave it. A strike counts for
    `StrikeDecayDays`; at `StrikeSuspendAt` standing strikes the member is
    barred from contracts for `StrikeSuspendHours` (the same bar as Suspend),
    and at `StrikeDemoteAt` they move one role down (never the last top boss);
    0 turns either off. Suspension and demotion by hand stay **M5** and
    **M4**. Only staff overturn a strike or warning: it stays on the record,
    marked, no longer counts, and a bar the strikes made is lifted once they
    fall below the mark (a demotion stays: staff move them back with Set
    role); the member is told.
  - **Recruitment** (`Recruitment`). A boss holding **N4 Edit application
    form** sets the questions an applicant answers (up to `RecruitQuestions`,
    each answer up to `RecruitAnswerMax` characters, plain text). A boss
    holding **N2 Applications** reads the answers, writes an interview note
    (up to `RecruitNoteMax`), and hires or declines as with any application;
    the applicant is told. Against spam, a declined applicant waits
    `RecruitCooldownHours` before they apply again, and the organisation takes
    at most `RecruitPerHour` applications an hour.
- **Organisation extras 3** (server/org/init.lua, server/org/extras3.lua).
  More switches under `Config.Organisation`, each off as shipped and each
  needing the organisation on, as the extras above; staff do all of it from the
  panel; every write takes two clicks or taps and is on the record.
  - **Several organisations** (`SeveralOrganisations`, `MaxOrganisations`).
    Staff add more hitman organisations (rival crews) in Hitman organisation,
    Setup, **Organisations**: each is its own qbx_core job (the job name staff
    give, lower case, never another's) with its own roles (made from
    `Config.Organisation.Roles`), members, funds (its own society account or
    ledger rows), places, Boss permissions, settings and log, all kept by its id
    (the job name). The card picks which one every Hitman organisation, Boss
    permissions and Locations view works on (the ops carry `org`; none is the
    first, the config.lua one). A citizen is a member of one at most: a hire,
    an invite, an application or a job change made elsewhere into a second is
    refused (`org_other_org`). A member's phone always works on their own; an
    outsider picks which one to look at and apply to; a placer sending a
    contract to an organisation picks which. Each pay day, extras tick, channel
    and contract held is its own. Staff take one off the list only when it has
    no member, empty funds and nothing held; its rows stay, and adding its job
    name again brings it back. Off: only the first is read, exactly as before;
    the others are kept for when it is on. `MaxOrganisations` (1-10) counts the
    first.
  - **Reputation and tiers** (`Reputation`). The organisation's standing:
    `RepCompletion` points for each member's completion, `RepFailure` off for
    each failure (counted from the record's own outcomes from when it is on),
    less `RepHeat` for every point of heat its members carry now
    (`Config.Record.Heat`). `RepTiers` names the tiers, one line each as
    `'points, label, most an accept is worth'` ($, 0 = no cap): a member's
    accept of a contract worth more than their organisation's tier allows is
    refused in words (`org_tier`); a higher tier unlocks bigger ones. Members
    see the tier, the points and what the next needs; staff see how it is made
    up and adjust it (with a reason) in **Reputation, drops & garage**.
  - **Dead drops** (`DeadDrops`, `DeadDropMinutes`, `DeadDropUnclaimed`). Staff
    set the organisation's dead drop in Locations (**Dead drops**); a boss
    holding **P4 Choose payout method** (or staff) picks *the usual way* or
    *the dead drop*. With the dead drop, a member's payout (baseline, bonus,
    items included) waits in escrow, owed to them and queued, until they use
    the drop (its ox_target option) within `DeadDropMinutes`; unclaimed, it is
    handed over the usual way (`'pay'`) or given back to the placer
    (`'refund'`). It is a payout check (server/payout.lua) on the escrow's own
    give, so only the escrow's paths move money: what was escrowed is what the
    member (and the funds' cut) or the placer receive. A restart keeps every
    drop. Staff hand one over or refund it at once. A member who stops being
    one (fired, or out of the job by another script) is paid every drop
    waiting for them at once and told, never refunded to the placer; the
    hitman's receipt says where the payout waits and for how long.
  - **Territory** (`Territory`, `TerritoryMinutes`, `TerritorySightMetres`;
    needs `OrgContracts`). Staff draw zones in Locations (**Territory**: a
    centre and a radius). A contract placed (not sent anywhere) on somebody
    standing in an organisation's zone, while one of its members stands within
    `TerritorySightMetres` of them in the same routing bucket, is held for that
    organisation for `TerritoryMinutes` as a contract sent to it, then goes on
    the open board. **Privacy:** the target's position is read once, on the
    server, and acted on only when a member can already see the target
    (standing beside them); it is never stored, sent or logged; no zone is ever
    sent to a game; the organisation is told exactly what it is told of a
    contract a placer sent ("A contract was sent to the organisation"), so it
    cannot tell a territory hold from a placer's choice; and the placer is told
    nothing, then or when it goes on the open board, so they learn nothing of
    where the target was. The staff log has the hold, with no position.
  - **Garage** (`Garage`, `GarageVehicles`, `GarageMaxOut`, `GarageKeepMinutes`,
    `GarageReturnMetres`). Staff set the garage spot (Locations, **Garage**) and
    approve models; a boss holding **V1 Manage garage** chooses which of them
    are offered. A member standing at the spot takes one out in the tab (one at
    a time, `GarageMaxOut` for the organisation): made by the server through
    the garage adapter (`Config.Integrations.Garage`, `onesync`: server
    vehicles, nobody's own car, kept by the server, a random plate, locked,
    keys from the keys adapter; any model, made as its own vehicles.meta type,
    bike, boat or helicopter included, read from qbx_core's shared vehicle list
    or, failing that, from the game: server/lib/vehicles.lua, which body
    disposal's vehicle uses too), and returned near the spot. Out for
    `GarageKeepMinutes`, or its member gone from the city or the organisation,
    it is taken away; every one goes at the resource's stop. Staff take one
    away from the panel. With the adapter `none`, the garage says so.
  - **Internal contracts** (`InternalContracts`, `InternalExpireHours`). A boss
    holding **K8 Request internal contract** asks staff for a contract on a
    member below them who went rogue: a reason and the cash reward. Nothing is
    placed or taken until staff approve it in the panel; it is then placed in
    the boss's name, with their own money, through the ordinary placement, so
    every limit, cap and anonymity rule applies (a boss away or short is told,
    and the request stays open). Declined or run out, the boss is told.
  - **Handler** (`Handler`, `HandlerAssigns`). The organisation's NPC spots
    (Locations, NPC spots; drawn only within `DrawMetres`, nothing runs while
    far) brief a member who talks to them: their assigned contract, its dossier
    and the notice; with `HandlerAssigns`, a member on duty with nothing
    assigned is given the oldest contract waiting for the organisation.
  - **Activity log** (`ActivityLog`, `ActivityKeep`). What members and bosses
    did (accepts, completions and failures, deposits, withdrawals and bonuses,
    grants, hires and fires, armory moves, vehicles), for a boss holding **M12
    View org log** and for staff: members by the name the organisation shows
    (codename where on), staff as *Staff*, never a citizen id, a placer or a
    target.

**server.cfg.** Keep `set qbx:cleanPlayerGroups false` (true deletes the
organisation's members at every qbx_core start) and `set
qbx:enableGroupManagement false` (qbx_management would take over the job), set
`set qbx:max_jobs_per_player 2` or more so a player with a job can join, and
`ensure crimson-hitman` before `ensure Renewed-Banking` (it reads the job list
once, as it starts). Each one wrong is said once at the start and in
`/ch-diag`. bankAuth is never set, and isboss only with
`Config.Organisation.QbxBossFlag`: Renewed-Banking's bank screen,
qbx_management and lb-phone's Services boss tab check far less than this
resource does.


## Mission steps

**Step markers** (`Config.StepMarkers`, on as shipped) put each step of a
contract on the map of the one party who has to act on it, and nobody else:
never the target, never a bystander, never the page. Every marker is a fixed
point the server recorded (a death, an arm, a pin, a staff spot), never
anybody's live position, so no marker can say where a hidden party is. Each
comes off on every way its step ends, is drawn again when a player comes back
(their app asks, as it does for tips and meeting points), and costs nothing
while there is none: no thread, no loop, one look on the maintenance tick.

| Marker | Who sees it | Taken off when |
|---|---|---|
| Informant tip (red circle) | The hitman who bought it | Its time runs out, the contract ends, the hitman leaves it |
| Meeting point (yellow) | The placer and every active hitman | Cleared or moved, the last hitman leaves, the contract ends, `Config.Kidnap.MeetingPoint` off |
| Kill to verify (`KillScene`) | The hitman the kill was attributed to, at the body | Verified, lapsed, the target revived, the hitman leaves, the contract ends |
| Handover circle (`Handover`) | The placer and the hitman who armed it, at the point it was armed | The countdown ends in any way |
| Protection pin (`Protection`) | The guard holding the job | The job ends or is cancelled; moved with the pin |
| Body, disposal vehicle, drop-off (`Config.Disposal`) | The hitman disposing of the body | Loaded (body), reached (vehicle), dropped off, timed out, skipped by staff, switched off |
| Broker, informant, organisation spots | As their own features say | As their own features say |

A proof-item handover has no marker: it happens wherever the hitman meets the
placer, and a fixed spot for it would be the placer's position.

**Body disposal** (`Config.Disposal`, off as shipped). With it on and both
spots set, a verified kill (never a live handover or a proof item, and only on
a contract a kill may complete) claims its payout as always, and the payout
waits in escrow for the hitman, as a payout held for proof of intent waits,
until the body is dropped off. The hitman is sent a marker at the body (where
the server recorded the death), the disposal vehicle (`VehicleModel`, a hearse
as shipped) is made by the server at the spawn spot with a marker of its own,
locked, with keys for the hitman alone (qbx_vehiclekeys). They bring it to the
body and choose **Load the body** (ox_target): the server checks that they and
the vehicle are both within `LoadMetres` / `VehicleMetres` of the body. They
drive to the drop-off (its marker appears once loaded) and choose **Drop off
the body**, checked the same way, and the payout is released; the vehicle is
taken away `DespawnSeconds` later. `PayNowPercent` of a cash or bank payout can
be handed over at the kill instead (0 as shipped: all at the drop-off).

- **The body** is a stage the server keeps on the step (at the scene, then loaded), never an ox_inventory item or a prop a player holds: nothing to drop, trade, stash or duplicate, and nothing lost to a death or full pockets.
- **The clock** (`TimeLimitMinutes`) runs only while the hitman is in the city and nothing holds the contract: a staff freeze on any party, the app pause and the restart hold stop it, keep the vehicle where it is, and refuse loading and dropping off. The hitman is told the time left as a band (over 20 minutes, 10 to 20, 5 to 10, under 5); staff see it to the second.
- **On timeout** (`OnTimeout`): `pay` (as shipped, so nobody can grief a hitman out of a kill), `reduced` (they keep `ReducedPercent` of the money; items are paid whole; the rest goes back to the placer) or `refund` (all of it back to the placer).
- **The clock's ceiling** (`MaxHoldMinutes`, 120 as shipped, never below `TimeLimitMinutes`): real minutes from the kill, counted whether the hitman is in the city or not, and through restarts. Past it the step no longer keeps its target off the board, held or not, so a hitman logging off over a body cannot shield the target from every new contract. It times out as `OnTimeout` says once that many minutes have stood without a staff hold (a freeze, the app pause, the restart hold), even while the hitman is away: a hold longer than the ceiling does not time the step out as it ends.
- **The vehicle** is a server-made networked vehicle, nobody's own, with no garage row, a random plate (`CH` and six random characters, never one another step's vehicle has, so a key qbx_vehiclekeys gave for an earlier disposal vehicle opens no later one) and a `crimsonDisposal` state bag, so nothing can store or sell it. Left more than `AbandonMetres` behind for `AbandonMinutes`, lost or destroyed, it is taken away and made again at the spawn spot, at most `MaxRespawns` times. It goes when the hitman leaves the city (made again when they are back, not counted) and at every stop; every other loss counts as a respawn, a relog in between or not, so losing it and relogging does not make free vehicles.
- **How the server keeps it** (OneSync entity rules): its orphan mode is set to keep it (`SetEntityOrphanMode(vehicle, 2)`, where the artifact has the native), since a server-made entity is otherwise deleted once nobody is in scope of it, and only this resource deletes it. It is put in the hitman's routing bucket when made, and moved with them if they change bucket, or a hitman in an instance never sees it. Population or cleanup resources that delete vehicles by plate or by distance should leave `crimsonDisposal` vehicles alone; one deleted anyway counts as lost.
- **The target** cannot have a new contract placed on them while their body is being disposed of, whatever `Config.Roleplay.EmsRelisting` says; a revive or a respawn changes nothing about a payout already claimed.
- **A restart** resumes the step where it was (`crimson_rp_rows`, kind `disposal`, in every store); the downtime is not counted. Turned off mid-step, every step finishes and pays at the next tick.

