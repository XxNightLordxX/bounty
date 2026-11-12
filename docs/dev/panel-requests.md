# Admin panel and phone requests

Every request the admin panel page and the phone's organisation tab send to
the server, and who may send each. What staff see and do is in the owner's
[admin-panel.md](../admin-panel.md); this list is for developers and for
anybody auditing the permission checks. `tests/docs_spec.lua` holds the
first table to `server/panel.lua`'s `OPS`.

## Panel requests

Every request the panel page sends (`server/panel.lua`), and who may send it.
*Read*: `crimson.admin` or one of `Config.Admin.ExtraAces`. *Moderate*:
`crimson.moderator` or `crimson.admin`. *Write*: `crimson.admin` itself.
*Identity*: `crimson.identity`. *Developer*: `crimson.developer` or
`crimson.admin`.

| Op | Who | What it does |
|---|---|---|
| `access` | Read | What this staff member may do, and the Permissions list |
| `overview` | Read | The overview: counts, money held, alerts, the server's state |
| `contracts` | Read | The one contract list and its search; `state = 'live'` (the page's default, *Live only*) lists every contract still running; `ref` or `person` (and `as`) one person's, `byTarget` the live ones by target |
| `contract` | Read | One contract's view and timeline |
| `exportContract` | Read | One contract's record as text, for a ticket |
| `playerView` | Read | A contract as one of its parties sees it |
| `reviews` | Read | The review queue |
| `stuck` | Read | Money waiting for staff (Home, Inbox) |
| `logs` | Read | Every log, one area each (`area`): the audit log and its search (none, or `audit`), every setting change from the panel (`settings`), the organisation's log (`org`, `org_*` actions; `action = 'org_grant'` the grant history) |
| `alerts` | Read | The alerts |
| `player` | Read | One player's contracts and record |
| `history` | Read | One player's history card |
| `measures` | Read | Every measure on a player in force, newest first (`server/measures.lua`): frozen, suspended, protected and their own target limits, each row with its `kind` and a handle (`ref`) Unfreeze or Lift takes; `kind` filters to one. The citizen id and who set it only with `crimson.identity` |
| `settings` | Read | Every setting, its value and where it comes from |
| `diag` | Read | The diagnosis, as yourself, a player id or the player looked up (`ref`); with `config = true`, the config check (`/ch-diag config`); scrubbed of citizen ids and accounts for staff without `crimson.identity`, and the lines that come later name the `ref` they were run for, so the page draws them under that player only |
| `console` | Developer | What this resource printed in the server console |
| `whois` | Identity | Who is behind an anonymous party |
| `void` | Moderate | Void a contract and refund it |
| `adjustDeadline` | Moderate | Extend or shorten a live contract's deadline |
| `freeze` | Moderate | Freeze a player: every live contract of theirs on hold |
| `unfreeze` | Moderate | Release a freeze; the time on hold is given back |
| `suspend` | Moderate | Bar a player from placing and accepting |
| `unsuspend` | Moderate | Lift a suspension |
| `protect` | Moderate | Make a player untargetable for a while |
| `unprotect` | Moderate | Lift a protection |
| `settle` | Write | Settle a stuck payout: pay, pay an amount, return, delivered |
| `resolve` | Write | Resolve a review item: refund, pay, dismiss |
| `manualPay` | Write | Pay a player by hand, up to `Config.Staff.ManualPaymentMax` |
| `addNote` | Write | A private staff note on a contract |
| `removeHitman` | Write | Take one operative off a contract |
| `editText` | Write | Replace a player's text on a contract (reason, message) |
| `setSetting` | Write | Change a setting |
| `resetSetting` | Write | Put one setting back to config.lua's value |
| `resetSettings` | Write | Put every setting back to config.lua |
| `undoSetting` | Write | Undo one setting change |
| `presets` | Read | Every preset with the changes it would make now and what would be refused |
| `presetApply` | Write | Apply one preset by name: Current saved first, then each change as a setting change |
| `presetSave` | Write | Save the settings the presets name, as they are now, as Current |
| `presetSaveOwn` | Write | Save the settings changed from the panel now as a preset of the server's own, under `name` (1-32 letters, digits, spaces, - _ '; not a shipped name; at most 20; the same name replaces it); audited `admin_preset_saved` |
| `presetDelete` | Write | Delete a preset of the server's own by `name`; audited `admin_preset_deleted` |
| `settingsExport` | Developer | Every setting changed from the panel (never a secret) and the server's own presets as one JSON `text` (`format`, `version`, `resource`, `exported`, `settings`, `presets`), with how many of each; not the map places or the target limits |
| `settingsImport` | Developer | What an exported `text` (at most 200 KB) would change now: `changes` (key, label, from, to), `refused` (key, label, why: on the deny list, not a setting of this version, read-only, or a value the start-up checks refuse), `same`, and the `presets` it would add (or why not); changes nothing |
| `settingsImportApply` | Write | Apply an exported `text` when its changes still number `expect` (the preview's): each through Settings.set (audited `admin_setting_changed`, in Change history with Undo), then its presets (only the values this server takes), then one `admin_settings_imported` row; needs the Developer section too |
| `setup` | Write | The first-start setup: storage, the other scripts (detected, and the adapter chosen), the `add_ace` lines, the panel command, the key switches, each at the value in force |
| `setupPreview` | Write | What applying the setup's choices would change, and what would be refused; changes nothing |
| `setupApply` | Write | Apply the setup's choices, each as a setting change, and save the setup as done |
| `announce` | Write | One notice to every hitman, or everybody with the app |
| `refresh` | Write | Bring every wait forward (test servers) |
| `flush` | Write | Write the audit log now |
| `ackAlerts` | Write | Acknowledge alerts |
| `testAlert` | Write | Send a test alert to Discord |
| `removePhotos` | Write | Remove the kill photos kept from before |
| `setPlaytime` | Write | Correct one character's counted playtime |
| `targetLimits` | Read | Target limits: the limits and every job's own |
| `targetStatus` | Read | One player's standing as a target, exactly |
| `targetJobCount` | Read | How many players a job action would reach |
| `targetJobSet` | Write | Add or change a job's own target limits |
| `targetJobRemove` | Write | Remove a job's own target limits |
| `targetReset` | Moderate | Reset a player's cooldown (or all of them) |
| `targetExtend` | Moderate | Extend a player's cooldown by minutes or until a time |
| `targetCounts` | Moderate | Reset a player's day and week counts |
| `targetOverride` | Moderate | A player's own target limits, or exempt |
| `targetOverrideClear` | Moderate | Lift a player's own target limits |
| `targetJobAction` | Moderate | Reset, extend or reset counts for every player of a job |

## Reward and reassign requests

Added by `server/staff_reward.lua` and `server/staff_reassign.lua` through the panel's one way in (`Panel.extend`), so each runs the same gate: the ACE on every request, the panel's rate limits, a write waiting for boot recovery, every write audited. The page asks twice before it sends a write, naming the figure or the hitman.

| Request | Who | What it does |
|---|---|---|
| `rewardPreview` | Read | `{ id, by }`: the collection's reward now and after, the most it may be lowered by, what staff added, and why a change would be refused |
| `rewardChange` | Write | `{ id, by, from, account, reason }`: raise (`by` above 0, `from = 'staff'` or `'placer'`, `account = 'cash'` or `'bank'`) or lower (`by` below 0) the reward; audit `staff_reward_changed` |
| `reassignPreview` | Read | `{ id, ref, identity }`: the operatives on it now (aliases), whether the stake is waived, whether the hitman would go on anonymously, and what would refuse them: every check the reassignment asks before it takes anybody off, the same refusals |
| `reassignHitman` | Write | `{ id, ref, reason, block, returnStake, identity }`: take every operative off and assign the hitman the lookup named; `identity` is `'anonymous'` (the default, no fee), `'named'` or `'carry'` (what they chose on their own earlier stint on it); the old `anonymous = false` still means named. Audit `staff_reassign_hitman` (`staff_reassign_failed` when it could not finish, with how many were put back) |


## Organisation requests (admin panel)

Through the panel's one way in, as every op in *Panel requests*; reads need a
staff ACE, writes `crimson.admin` itself. The panel's Hitman organisation,
Boss permissions and Locations sections use them; every write takes two
clicks, naming what it sets.

| Op | Level | What it does |
|---|---|---|
| `orgGet` | read | Everything: setup, roles, members (by handle), Boss permissions, cuts, bounds, funds, applications, warnings (its spots: `placeList`) |
| `bossPermsGet` | read | The Boss permissions matrix |
| `orgFunds` | read | Balance and ledger |
| `orgSetup` | write | Create / sync the job in qbx_core |
| `orgRename`, `orgLayout`, `orgNotice` | write | Label, boss menu layout, board notice |
| `orgRoleSet`, `orgRoleRemove`, `orgRolePowers` | write | Add or edit a role, delete an empty one, set its powers |
| `orgMemberHire`, `orgMemberRole`, `orgMemberFire` | write | Hire (lookup handle or exact citizen id), set a role, fire with a reason |
| `orgMemberSuspend`, `orgMemberLimits`, `orgMemberOverride` | write | Bar from contracts, limits, a grant or deny, lock and codename |
| `bossPermsSet`, `bossPermsRevokeAll`, `bossLimits`, `bossOfficeRule` | write | Boss permissions cells (one or a batch), revoke a column, bounds, the office list |
| `orgCuts` | write | A cut: payout, role, member, stake, buyout |
| `orgFundsMove` | write | Deposit, withdraw or bonus, with a reason and a nonce |
| `orgFundsBackend` | write | Keep the funds in the ledger or Renewed-Banking (`backend`), the balance carried across; `abandon` leaves a bank that is down |
| `orgAccess`, `orgPick` | write | A role's access rules; a boss pick |
| `orgSalary` | write | A role's salary (`amount`), or the most it may be paid (`max`, false clears it): payroll |
| `orgApplication` | write | Accept or reject an application |
| `orgChannelGet` | read | The channel's newest messages (`limit`, at most 100); `orgGet` carries the last 50 under `extras` |
| `orgContractAssign` | write | Assign a contract sent to the organisation to a member (`member`), or send it to the open board (`release`) |
| `orgAcceptDecide` | write | Approve or refuse an accept waiting for approval (`id`, `approve`) |
| `orgProbation` | write | End a member's probation (`passed` true) or put them on it again (false) |
| `orgDutyOff` | write | Send a member off duty |
| `orgChannelPost`, `orgChannelRemove`, `orgChannelMute` | write | Post as Staff, remove a message, mute a member (`hours`, 0 lifts it) |
| `orgDossier` | write | A dossier on an assigned organisation contract (`notes`, `spot`, `rules`), or `clear` |
| `orgArmoryGet` | read | The armory: what it holds, the allow-list, each role's limit a day and its log; `orgGet` carries it under `extras2` |
| `orgArmoryLimit` | write | A role's armory limit a day (`grade`, `count`; 0 is none) |
| `orgArmoryStock` | write | Stock the armory with an allowed item (`item`, `count`), or take items out of a slot for good (`remove`, `slot`, `count`) |
| `orgStatsGet` | read | The leaderboard with every number, the average minutes included |
| `orgStatsReset` | write | Reset one member's counts (`member`), or everybody's (`all`) |
| `orgStrike` | write | A strike or a written warning (`kind`) with a `reason` |
| `orgOverturn` | write | Overturn a strike or warning (`id`) with a `reason`; the member is told |
| `orgRecruitForm` | write | The application form's `questions` (a list; empty clears it) |
| `orgInterviewNote` | write | An interview note on an open application (`id`, `text`), or `clear` |
| `orgCreate` | write | Add an organisation (`job`, `label`): Several organisations |
| `orgRemove` | write | Take one off the list (`id`): no members, empty funds, nothing held |
| `orgRepAdjust` | write | Move the reputation by `points` (either way), with a `reason` |
| `orgPayoutMethod` | write | Payouts the usual way or at the dead drop (`method`: `bank` or `deaddrop`) |
| `orgDropSettle` | write | Settle a dead drop now (`handle`, from the drop's row in `orgGet`; `how`: `release` or `refund`) |
| `orgGarageOffer` | write | Which approved models the organisation offers (`models`, a list) |
| `orgGarageRemove` | write | Take a member's garage vehicle away (`member`) |
| `orgInternalDecide` | write | Approve (placed by the boss who asked) or decline an internal contract request (`id`, `approve`) |
| `orgActivityGet` | read | The activity log (`limit`); `orgGet` carries the last 50 under `extras3` |

With Several organisations on, every op above (and Boss permissions' and
Locations' `place*` ops) takes `org`, the id of the one it works on; none is the
first, and an id that names none is refused.

## Organisation requests (phone)

lb-phone app requests through the app's own gate, `org` and `orgWrite` rate
limits; each needs the power named, held after Boss permissions, at the office
where it needs one. The app's Organisation tab asks them; the board also shows
a member their cut on every card, an invited player their invite, with Accept
and Decline (`orgInviteAnswer`), and says whether the tab is for this player
(`orgTab`).

| Request | Power | Request | Power |
|---|---|---|---|
| `orgMine` | anybody | `orgApply` | anybody, at a sign-up spot |
| `orgMembers` | M1 | `orgRoles`, `orgSpots` | a member |
| `orgHire` | M2 | `orgFire` | M3 |
| `orgSetRole` | M4 | `orgSuspend` | M5 |
| `orgMemberLimits` | M6 | `orgMemberGrant` | D2 |
| `orgRoleCreate` | R1 | `orgRoleEdit` | R2 |
| `orgRoleDelete` | R3 | `orgRolePowers` | R4 |
| `orgRolePay` | P1 | `orgBonus` | P2 |
| `orgSetCut` | C1-C5 | `orgDeposit` | C6 |
| `orgWithdraw` | C7 | `orgFunds` | C8 |
| `orgAccess` | K1 | `orgPick` | K2 |
| `orgRoleCooldown` | K3 | `orgPlaceHere` | L1-L3 |
| `orgRemoveSpot` | L2, L3 | `orgNotice` | N1 |
| `orgApplications`, `orgDecide` | N2 | `orgRename` | S1 |
| `orgLayout` | S2 | `orgOfficeRule` | S3 |
| `orgInviteAnswer` | the invited player | `orgCodename` | a member's own; M7 for another's |
| `orgSalary` | P3 | `orgWork` | K4, K5, K6 or K7 |
| `orgAssign` | K4 (K5 to move one) | `orgRelease` | K5 |
| `orgApprove` | K6 | `orgDossier` | K7 |
| `orgProbationEnd` | M8 | `orgForceOff` | M9 |
| `orgDuty` | a member's own | `orgChannel`, `orgChannelPost` | a member |
| `orgChannelRemove`, `orgChannelMute` | N3 | `orgArmory`, `orgArmoryPut`, `orgArmoryTake` | a member (A1 to take beyond the role's limit) |
| `orgArmoryLimit` | A2 | `orgStats` | a member (M10 for every number) |
| `orgStrike` | M11 | `orgDisciplineRecord` | a member's own; M11 or M5 for another's |
| `orgRecruitForm` | N4 | `orgInterviewNote` | N2 |
| `orgPayoutMethod` | P4 | `orgGarage`, `orgGarageTake`, `orgGarageReturn` | a member |
| `orgGarageOffer` | V1 | `orgInternalRequest` | K8 |
| `orgActivity` | M12 | | |

With Several organisations on, a member's requests always work on their own
organisation; anybody else's take `org` (the one picked in the tab), or else the
one inviting them, holding their application or whose sign-up spot they stand at.


## Mission steps requests (admin panel)

Through the panel's one way in; reads need a staff ACE, writes `crimson.admin`
itself. The page draws them on Contracts and Home (the steps, **Skip**,
**Respawn vehicle**); its two spots are set in Locations (*Places requests*);
who the hitman is comes only with `crimson.identity`.

| Op | Level | What it does |
|---|---|---|
| `disposalList` | read | Every disposal step: stage, exact seconds left, held, vehicle, respawns; the spots and the rules. Without `crimson.identity`, `held` says only the restart hold, the app pause and a freeze through a party they may see (never one through an anonymous placer or hitman) |
| `disposalSkip` | write | Finish a step (`id`: a step or contract id) as if dropped off: the payout is released |
| `disposalRespawn` | write | Make the vehicle again at the spawn spot (not counted as a respawn) |

## Places requests (admin panel)

Every map spot staff set lives in one registry (`server/places.lua`), kept as
one row kind (`crimson_rp_rows`, kind `map_place`) in every store, and is set
from Locations. Each kind keeps its own rules: the organisation's `office`
(one; a boss moves it only near staff's point), `signup`, `meeting` (a boss
with L2 / L3 from where they stand, within the limits and the cooldown, never
in a safe zone), `npc` and `place` (staff only); the `broker` and `informant`
NPCs (`Config.Roleplay.NpcPlaces`, off as shipped; off, every write says so;
at most 20 each; their config `Locations` stay the defaults); body disposal's
`disposal_vehicle` and `disposal_drop` (one each; config.lua's `VehicleSpawn`
/ `DropOff` apply while one is not set). One check for every kind: on the map
(x -4500 to 6000, y -6500 to 8500, z -200 to 2000), finite, a heading -360 to
360 (kept 0-360), a name without `<`, `>` or control characters (64 for the
organisation's, 40 for the NPCs'), a radius 0.5 to 50 m where the kind has
one. Reads need a staff ACE, writes `crimson.admin`; every write takes two
clicks. The places that are settings (tip safe zones, the rumours' districts
and zone names, witness heat's areas, the prison zone, the NPCs' default
lists) are settings, marked `place` in the catalogue, and edited in the same
Locations section, with Use my position filling a line.

| Op | Level | What it does |
|---|---|---|
| `placeList` | read | Every kind: its rows, what may be set beside the point, its limit, its config defaults and which it uses, and why it cannot be set now |
| `placeMyPosition` | read | Where your character stands, read by the server (Use my position, for every kind) |
| `placeSet` | write | `kind`, typed `x`, `y`, `z`, `heading` or `here` (read by the server); `label`, `radius`, `blip`, `enabled` where the kind takes them; `id` moves one (a kind with one moves it) |
| `placeRemove` | write | Remove one spot (`id`) |
| `placeReset` | write | Remove every place of the `broker` or the `informant` (`kind`): its config list applies again |

