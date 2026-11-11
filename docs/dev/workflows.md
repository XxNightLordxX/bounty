# Workflow coverage (step 7)

Every capability of the inventory (`tests/inventory/extract.lua`) against the workflow
test that drives it end to end, the way a player or a member of staff would. Written by
`CH_WRITE_WORKFLOWS=1 lua5.4 tests/run.lua` (tests/workflows/coverage_spec.lua), which fails
when an item in scope is driven by nothing and not listed below with why.

## The workflow specs

| Spec | What it drives |
|---|---|
| `tests/workflows/matrix_spec.lua` | The main flows (place, accept, handover, payout; a kill verified at the scene; a buyout; an intel purchase; the organisation's pay day; body disposal; staff freeze, reassign and reward change) in every configuration, on every store, with faults injected |
| `tests/workflows/phone_spec.lua` | Every phone request through the real page callbacks and the real client |
| `tests/workflows/org_phone_spec.lua` | The Organisation tab, boss and member, through the page |
| `tests/workflows/org_extras_spec.lua` | The organisation extras: contracts to it, approval, probation, duty, the channel, dossiers |
| `tests/workflows/org_extras2_spec.lua` | The organisation extras 2: the armory, the record and leaderboard, discipline, recruitment |
| `tests/workflows/org_extras3_spec.lua` | The organisation extras 3: several organisations, reputation, dead drops, the garage, internal contracts, the handler, the activity log |
| `tests/workflows/panel_spec.lua` | Every admin panel op through the panel page (adminRequest) |
| `tests/workflows/surface_spec.lua` | Commands, server and client net events, engine and framework events, tick jobs, every switch |
| `tests/ui/run.js`, `tests/ui/admin_run.js` | Every phone and panel screen's main path (tests named `workflow screen:<id>`) |

## Configurations and faults

- Configurations: `shipped` (config.lua as the owner ships it); `allon` (every switch of the
  settings catalogue on except `Admin.Enabled`, `Completion.RejectLastStand`, `Database.AllowModeSwitch`, `Database.Json.SyncOnFinancialWrite`, `Debug`, `Holds.AppPaused`, `Organisation.AcceptApproval`: see `W.ALL_ON_SKIPPED`
  in tests/workflows/lib.lua for why each); and each integration set to `none` in turn
  (Inventory, Target, Dispatch, Ambulance, Banking, Phone, Keys, Mugshot, Clothing, Progression), the framework staying qbx_core.
- Stores: memory, json, the executing mysql harness (never a real database).
- Faults at every step boundary: a graceful restart, a crash (no stop), a player leaving and
  coming back (placer, target, hitman in turn). Memory keeps nothing across a restart
  (`testing only`, config.lua), so on memory only the drop runs. By default the `none`
  profiles inject at the boundary after the acceptance only.
- Faults at the database awaits (mysql, shipped): a crash before a statement or after it ran,
  and a player leaving there. By default every 4th await (alternating before/after) and a
  drop at every 6th; `CH_WORKFLOWS_FULL=1` runs every boundary of every profile and every
  await in both phases with a drop at each (both shipped and allon).
- After a crash that left a payout mid-release, staff clear it from the panel (Stuck, Settle)
  as the console tells them to; the money is then conserved to the dollar.

## Counts

| Category | In scope | Items | Driven by a workflow |
|---|---|---:|---:|
| ace | counted | 5 | 0 |
| audit | counted | 362 | 177 |
| command | yes | 12 | 12 |
| config | counted | 632 | 0 |
| err | counted | 152 | 4 |
| event | yes | 24 | 24 |
| ext | counted | 59 | 0 |
| handler | yes | 122 | 122 |
| netevent.client | yes | 18 | 18 |
| netevent.server | yes | 11 | 11 |
| nui | yes | 123 | 123 |
| op | yes | 127 | 127 |
| screen | yes | 78 | 78 |
| setting | counted | 572 | 0 |
| switch | yes | 157 | 157 |
| tick | yes | 45 | 45 |

## Not in scope, and why

- `ace`: staff permissions: every panel and command workflow runs with them, the refusals in authz specs.
- `audit`: rows a workflow leaves: counted (which actions any workflow made the resource write), and asserted where a flow is about them.
- `config`: values, not actions: each is read by the workflow of its feature; the panel's setSetting workflow changes them (surface spec, every switch; panel spec, game rules).
- `err`: refusal codes: counted where a phone workflow was answered with one; the refusals are the business of the authz, boundary and abuse specs.
- `export`: the resource offers none.
- `ext`: other resources' exports: the adapters and the harness's fakes answer them in every workflow; each integration set to none is a matrix profile.
- `setting`: the panel catalogue's keys; its switches are in scope (category switch), the other values are edited by the same setSetting path the game-rules workflow drives.

## Not driven by a workflow, and why

None.

## Capability -> workflow test


### command

| Capability | Workflow test |
|---|---|
| `ch-contracts` | commands > staff look a contract up, its timeline, who is behind it, a player's contracts, the queues |
| `ch-diag` | commands > staff look a contract up, its timeline, who is behind it, a player's contracts, the queues |
| `ch-refresh` | commands > staff look a contract up, its timeline, who is behind it, a player's contracts, the queues |
| `ch-review` | commands > staff look a contract up, its timeline, who is behind it, a player's contracts, the queues |
| `ch-settle` | commands > staff void a contract and the money goes back; staff settle a line left for them |
| `ch-stuck` | commands > staff look a contract up, its timeline, who is behind it, a player's contracts, the queues |
| `ch-timeline` | commands > staff look a contract up, its timeline, who is behind it, a player's contracts, the queues |
| `ch-void` | commands > staff void a contract and the money goes back; staff settle a line left for them |
| `ch-whois` | commands > staff look a contract up, its timeline, who is behind it, a player's contracts, the queues |
| `cleanse` | commands > the target buys out with the command when they cannot open the app |
| `hitmanadmin` | panel: home > the overview, the inbox lists, an announcement, a test alert, refresh, flush, the console; panel: players > looks a player up, views them, their history, and every measure on them; panel: contracts > lists, opens, notes, moves a deadline, edits text, exports, removes a hitman, voids |
| `hitmanadmin-close` | commands > the panel opens with its command and closes with -close |

### event

| Capability | Workflow test |
|---|---|
| `client:QBCore:Client:OnPlayerUnload` | client events > the client hears its access, settings, pushes, notices, markers, and unloads cleanly |
| `client:crimson-hitman:appearanceChanged` | client events > the client hears its access, settings, pushes, notices, markers, and unloads cleanly |
| `client:gameEventTriggered` | client events > the client hears its access, settings, pushes, notices, markers, and unloads cleanly |
| `client:onClientResourceStart` | client events > the client hears its access, settings, pushes, notices, markers, and unloads cleanly |
| `client:onResourceStop` | client events > the client hears its access, settings, pushes, notices, markers, and unloads cleanly |
| `client:qbx_core:client:playerLoggedOut` | client events > the client hears its access, settings, pushes, notices, markers, and unloads cleanly |
| `server:QBCore:Server:OnJobUpdate` | engine and framework events > jobs, duty, groups, jail, logging out and unloading, a resource starting |
| `server:QBCore:Server:OnPlayerUnload` | engine and framework events > jobs, duty, groups, jail, logging out and unloading, a resource starting |
| `server:QBCore:Server:PlayerLoaded` | phone: the board, the place form, placing > reads the board, finds a target, sees the reward options, places a contract; phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down |
| `server:QBCore:Server:SetDuty` | engine and framework events > jobs, duty, groups, jail, logging out and unloading, a resource starting |
| `server:lb-phone:deletedFromGallery` | engine and framework events > lb-phone deleting a kept photo from the gallery, and a phone reset |
| `server:lb-phone:factoryReset` | engine and framework events > lb-phone deleting a kept photo from the gallery, and a phone reset |
| `server:onResourceStart` | engine and framework events > jobs, duty, groups, jail, logging out and unloading, a resource starting |
| `server:onResourceStop` | engine and framework events > a txAdmin restart of the resource stops it cleanly and the next start keeps the contract; workflow matrix: shipped > contract on json: restart before place; workflow matrix: shipped > contract on json: restart before accept |
| `server:playerDropped` | workflow matrix: shipped > contract on memory: the creator leaves before place; workflow matrix: shipped > contract on memory: the target leaves before accept; workflow matrix: shipped > contract on memory: the hitman leaves before handover |
| `server:qbx_core:server:onGroupUpdate` | engine and framework events > jobs, duty, groups, jail, logging out and unloading, a resource starting |
| `server:qbx_core:server:onSetJob` | engine and framework events > jobs, duty, groups, jail, logging out and unloading, a resource starting |
| `server:qbx_core:server:onSetMetaData` | engine and framework events > jobs, duty, groups, jail, logging out and unloading, a resource starting |
| `server:qbx_core:server:playerLoaded` | engine and framework events > jobs, duty, groups, jail, logging out and unloading, a resource starting |
| `server:qbx_core:server:playerLoggedOut` | engine and framework events > jobs, duty, groups, jail, logging out and unloading, a resource starting |
| `server:txAdmin:events:scheduledRestart` | engine and framework events > a txAdmin restart holds every clock, and a skipped one lets them go |
| `server:txAdmin:events:scheduledRestartSkipped` | engine and framework events > a txAdmin restart holds every clock, and a skipped one lets them go |
| `server:txAdmin:events:skippedNextScheduledRestart` | engine and framework events > a txAdmin restart holds every clock, and a skipped one lets them go |
| `server:weaponDamageEvent` | phone: the kill photo > the hitman photographs the kill, the placer opens it once and keeps it; phone: the kill photo > sends a picture kept on the server, through the viewfinder; phone: the kill photo > verifies a kill at the scene with kill photos off |

### handler

| Capability | Workflow test |
|---|---|
| `abandon` | phone: accept and abandon > a second hitman accepts from the board, then puts it down; organisation extras 2 from the phone and the panel > the record: a walk-away counted, the leaderboard read, staff reset it; workflow matrix: shipped > staff on memory: clean |
| `accept` | phone: accept and abandon > a second hitman accepts from the board, then puts it down; organisation extras from the phone and the panel > a contract sent to the organisation: assigned, briefed, approved and taken; organisation extras from the phone and the panel > another moved by staff and released, duty forced off, probation ended and put back |
| `addEscrow` | phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `amendments` | phone: proposals > the hitman proposes a shorter deadline, the placer reads it and agrees |
| `armKidnap` | phone: the handover > the placer sets the meeting point, the hitman sets GPS, arms, the placer confirms; workflow matrix: shipped > contract on memory: clean; workflow matrix: shipped > contract on memory: the creator leaves before place |
| `bailout` | phone: the target > buys their way out; workflow matrix: shipped > buyout on memory: clean; workflow matrix: shipped > buyout on memory: the creator leaves before place |
| `brokerBrief` | phone: rumours > a hitman asks the broker NPC; a broker player briefs somebody standing with them |
| `brokerNearby` | phone: rumours > a hitman asks the broker NPC; a broker player briefs somebody standing with them |
| `browseTargets` | phone: the board, the place form, placing > reads the board, finds a target, sees the reward options, places a contract |
| `cancel` | phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `clearMeeting` | phone: the handover > the placer sets the meeting point, the hitman sets GPS, arms, the placer confirms |
| `confirmHandover` | phone: the handover > the placer sets the meeting point, the hitman sets GPS, arms, the placer confirms; workflow matrix: allon > contract on memory: clean; workflow matrix: allon > contract on memory: the creator leaves before place |
| `create` | phone: the board, the place form, placing > reads the board, finds a target, sees the reward options, places a contract; panel: logs, locations, photos > lists a disposal step, respawns its vehicle and skips it; workflow matrix: shipped > contract on memory: clean |
| `decayOff` | phone: decay, proof item, the page > the placer turns decay off; the hitman hands over a proof item |
| `disposalAct` | workflow matrix: shipped > disposal on memory: clean; workflow matrix: shipped > disposal on memory: the creator leaves before place; workflow matrix: shipped > disposal on memory: the target leaves before accept |
| `endCall` | phone: messages and calls > the placer writes to the hitman through the masked relay, mutes, calls, reports |
| `goDark` | phone: the target > goes dark once a tip on them is bought |
| `improve` | phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `informant` | phone: the target > buys an informant's name of the hitman after them |
| `kidnapProgress` | phone: the handover > the placer sets the meeting point, the hitman sets GPS, arms, the placer confirms; workflow matrix: shipped > contract on memory: clean; workflow matrix: shipped > contract on memory: the creator leaves before place |
| `ledger` | phone: my tabs > the hitman, the placer and the target each read their own tab and the ledger; workflow matrix: shipped > contract on memory: clean; workflow matrix: shipped > contract on memory: the creator leaves before place |
| `list` | phone: the board, the place form, placing > reads the board, finds a target, sees the reward options, places a contract; phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down |
| `locationTip` | phone: the target > goes dark once a tip on them is bought; workflow matrix: shipped > intel on memory: clean; workflow matrix: shipped > intel on memory: the creator leaves before place |
| `locationTips` | phone: the board, the place form, placing > reads the board, finds a target, sees the reward options, places a contract; phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down |
| `meetingWaypoint` | phone: the handover > the placer sets the meeting point, the hitman sets GPS, arms, the placer confirms |
| `mine` | phone: my tabs > the hitman, the placer and the target each read their own tab and the ledger; workflow matrix: shipped > buyout on memory: clean; workflow matrix: shipped > buyout on memory: the creator leaves before place |
| `mugshotImage` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out |
| `muteThread` | phone: messages and calls > the placer writes to the hitman through the masked relay, mutes, calls, reports |
| `openPhoto` | phone: the kill photo > the hitman photographs the kill, the placer opens it once and keeps it |
| `orgAccess` | organisation from the phone > the boss edits the roles: create, rename, powers, pay, cooldown, access, delete |
| `orgActivity` | organisation extras 3 from the phone and the panel > reputation, a dead drop, the garage, an internal contract, the handler and the log |
| `orgApplications` | organisation from the phone > places, notices, applications, picks, renaming, the layout and the office rule; organisation extras 2 from the phone and the panel > recruitment: the form set, answered, noted, and the applicant hired |
| `orgApply` | organisation from the phone > places, notices, applications, picks, renaming, the layout and the office rule; organisation extras 2 from the phone and the panel > recruitment: the form set, answered, noted, and the applicant hired; organisation extras 3 from the phone and the panel > several organisations: a second added, an outsider applies to it, one taken off |
| `orgApprove` | organisation extras from the phone and the panel > a contract sent to the organisation: assigned, briefed, approved and taken |
| `orgArmory` | organisation extras 2 from the phone and the panel > the armory: stocked by staff, filled by a member, limited by the boss, drawn from |
| `orgArmoryLimit` | organisation extras 2 from the phone and the panel > the armory: stocked by staff, filled by a member, limited by the boss, drawn from |
| `orgArmoryPut` | organisation extras 2 from the phone and the panel > the armory: stocked by staff, filled by a member, limited by the boss, drawn from |
| `orgArmoryTake` | organisation extras 2 from the phone and the panel > the armory: stocked by staff, filled by a member, limited by the boss, drawn from |
| `orgAssign` | organisation extras from the phone and the panel > a contract sent to the organisation: assigned, briefed, approved and taken |
| `orgBonus` | organisation from the phone > the money: a deposit, a cut, a salary, a bonus, a withdrawal, the funds read back |
| `orgChannel` | organisation extras from the phone and the panel > the channel: written, read, muted and moderated from the phone and the panel |
| `orgChannelMute` | organisation extras from the phone and the panel > the channel: written, read, muted and moderated from the phone and the panel |
| `orgChannelPost` | organisation extras from the phone and the panel > the channel: written, read, muted and moderated from the phone and the panel |
| `orgChannelRemove` | organisation extras from the phone and the panel > the channel: written, read, muted and moderated from the phone and the panel |
| `orgCodename` | organisation from the phone > the boss manages a member: role, suspension, limits, grant, codename, then fires them |
| `orgDecide` | organisation from the phone > places, notices, applications, picks, renaming, the layout and the office rule; organisation extras 2 from the phone and the panel > recruitment: the form set, answered, noted, and the applicant hired |
| `orgDeposit` | organisation from the phone > the money: a deposit, a cut, a salary, a bonus, a withdrawal, the funds read back |
| `orgDisciplineRecord` | organisation extras 2 from the phone and the panel > discipline: a strike and a warning given, read by the member, one overturned by staff |
| `orgDossier` | organisation extras from the phone and the panel > a contract sent to the organisation: assigned, briefed, approved and taken |
| `orgDuty` | organisation extras from the phone and the panel > a contract sent to the organisation: assigned, briefed, approved and taken; organisation extras from the phone and the panel > another moved by staff and released, duty forced off, probation ended and put back |
| `orgFire` | organisation from the phone > the boss manages a member: role, suspension, limits, grant, codename, then fires them |
| `orgForceOff` | organisation extras from the phone and the panel > another moved by staff and released, duty forced off, probation ended and put back |
| `orgFunds` | organisation from the phone > the money: a deposit, a cut, a salary, a bonus, a withdrawal, the funds read back |
| `orgGarage` | organisation extras 3 from the phone and the panel > reputation, a dead drop, the garage, an internal contract, the handler and the log |
| `orgGarageOffer` | organisation extras 3 from the phone and the panel > reputation, a dead drop, the garage, an internal contract, the handler and the log |
| `orgGarageReturn` | organisation extras 3 from the phone and the panel > reputation, a dead drop, the garage, an internal contract, the handler and the log |
| `orgGarageTake` | organisation extras 3 from the phone and the panel > reputation, a dead drop, the garage, an internal contract, the handler and the log |
| `orgHire` | organisation from the phone > the boss hires a recruit, who reads their own tab, the spots and the roles; organisation from the phone > the boss manages a member: role, suspension, limits, grant, codename, then fires them; organisation from the phone > the money: a deposit, a cut, a salary, a bonus, a withdrawal, the funds read back |
| `orgInternalRequest` | organisation extras 3 from the phone and the panel > reputation, a dead drop, the garage, an internal contract, the handler and the log |
| `orgInterviewNote` | organisation extras 2 from the phone and the panel > recruitment: the form set, answered, noted, and the applicant hired |
| `orgInviteAnswer` | organisation from the phone > the boss hires a recruit, who reads their own tab, the spots and the roles; organisation from the phone > the boss manages a member: role, suspension, limits, grant, codename, then fires them; organisation from the phone > the money: a deposit, a cut, a salary, a bonus, a withdrawal, the funds read back |
| `orgLayout` | organisation from the phone > places, notices, applications, picks, renaming, the layout and the office rule |
| `orgMemberGrant` | organisation from the phone > the boss manages a member: role, suspension, limits, grant, codename, then fires them |
| `orgMemberLimits` | organisation from the phone > the boss manages a member: role, suspension, limits, grant, codename, then fires them |
| `orgMembers` | organisation from the phone > the boss manages a member: role, suspension, limits, grant, codename, then fires them; organisation from the phone > the money: a deposit, a cut, a salary, a bonus, a withdrawal, the funds read back; organisation from the phone > places, notices, applications, picks, renaming, the layout and the office rule |
| `orgMine` | organisation from the phone > the boss hires a recruit, who reads their own tab, the spots and the roles; organisation from the phone > the boss manages a member: role, suspension, limits, grant, codename, then fires them; organisation from the phone > the money: a deposit, a cut, a salary, a bonus, a withdrawal, the funds read back |
| `orgNotice` | organisation from the phone > places, notices, applications, picks, renaming, the layout and the office rule |
| `orgOfficeRule` | organisation from the phone > places, notices, applications, picks, renaming, the layout and the office rule |
| `orgPayoutMethod` | organisation extras 3 from the phone and the panel > reputation, a dead drop, the garage, an internal contract, the handler and the log |
| `orgPick` | organisation from the phone > places, notices, applications, picks, renaming, the layout and the office rule |
| `orgPlaceHere` | organisation from the phone > places, notices, applications, picks, renaming, the layout and the office rule |
| `orgProbationEnd` | organisation extras from the phone and the panel > another moved by staff and released, duty forced off, probation ended and put back |
| `orgRecruitForm` | organisation extras 2 from the phone and the panel > recruitment: the form set, answered, noted, and the applicant hired |
| `orgRelease` | organisation extras from the phone and the panel > another moved by staff and released, duty forced off, probation ended and put back |
| `orgRemoveSpot` | organisation from the phone > places, notices, applications, picks, renaming, the layout and the office rule |
| `orgRename` | organisation from the phone > places, notices, applications, picks, renaming, the layout and the office rule |
| `orgRoleCooldown` | organisation from the phone > the boss edits the roles: create, rename, powers, pay, cooldown, access, delete |
| `orgRoleCreate` | organisation from the phone > the boss edits the roles: create, rename, powers, pay, cooldown, access, delete |
| `orgRoleDelete` | organisation from the phone > the boss edits the roles: create, rename, powers, pay, cooldown, access, delete |
| `orgRoleEdit` | organisation from the phone > the boss edits the roles: create, rename, powers, pay, cooldown, access, delete |
| `orgRolePay` | organisation from the phone > the boss edits the roles: create, rename, powers, pay, cooldown, access, delete |
| `orgRolePowers` | organisation from the phone > the boss edits the roles: create, rename, powers, pay, cooldown, access, delete |
| `orgRoles` | organisation from the phone > the boss hires a recruit, who reads their own tab, the spots and the roles; organisation from the phone > the boss edits the roles: create, rename, powers, pay, cooldown, access, delete |
| `orgSalary` | organisation from the phone > the money: a deposit, a cut, a salary, a bonus, a withdrawal, the funds read back |
| `orgSetCut` | organisation from the phone > the money: a deposit, a cut, a salary, a bonus, a withdrawal, the funds read back |
| `orgSetRole` | organisation from the phone > the boss manages a member: role, suspension, limits, grant, codename, then fires them |
| `orgSpots` | organisation from the phone > the boss hires a recruit, who reads their own tab, the spots and the roles; organisation from the phone > places, notices, applications, picks, renaming, the layout and the office rule; server net events > an organisation spot used in the world |
| `orgStats` | organisation extras 2 from the phone and the panel > the record: a walk-away counted, the leaderboard read, staff reset it |
| `orgStrike` | organisation extras 2 from the phone and the panel > discipline: a strike and a warning given, read by the member, one overturned by staff |
| `orgSuspend` | organisation from the phone > the boss manages a member: role, suspension, limits, grant, codename, then fires them |
| `orgWithdraw` | organisation from the phone > the money: a deposit, a cut, a salary, a bonus, a withdrawal, the funds read back |
| `orgWork` | organisation extras from the phone and the panel > a contract sent to the organisation: assigned, briefed, approved and taken; organisation extras from the phone and the panel > another moved by staff and released, duty forced off, probation ended and put back |
| `pageError` | phone: decay, proof item, the page > the page says it broke, asks the access mode, and the NPC places are read |
| `photoDecision` | phone: the kill photo > the hitman photographs the kill, the placer opens it once and keeps it |
| `placerInformant` | phone: the placer's informant > names the anonymous operative on their contract |
| `proofItem` | phone: decay, proof item, the page > the placer turns decay off; the hitman hands over a proof item |
| `propose` | phone: proposals > the hitman proposes a shorter deadline, the placer reads it and agrees |
| `protectionAccept` | phone: protection > the target posts a job, a guard takes it, sets GPS to the pin, the target cancels |
| `protectionBoard` | phone: protection > the target posts a job, a guard takes it, sets GPS to the pin, the target cancels |
| `protectionCancel` | phone: protection > the target posts a job, a guard takes it, sets GPS to the pin, the target cancels |
| `protectionPin` | phone: protection > the target posts a job, a guard takes it, sets GPS to the pin, the target cancels |
| `protectionPost` | phone: protection > the target posts a job, a guard takes it, sets GPS to the pin, the target cancels |
| `protectionWaypoint` | phone: protection > the target posts a job, a guard takes it, sets GPS to the pin, the target cancels |
| `readThread` | phone: messages and calls > the placer writes to the hitman through the masked relay, mutes, calls, reports |
| `report` | phone: messages and calls > the placer writes to the hitman through the masked relay, mutes, calls, reports; panel: contracts > settles a review item staff are given |
| `requestCall` | phone: messages and calls > the placer writes to the hitman through the masked relay, mutes, calls, reports |
| `requestPhotoToken` | phone: the kill photo > the hitman photographs the kill, the placer opens it once and keeps it; phone: the kill photo > sends a picture kept on the server, through the viewfinder |
| `respondAmendment` | phone: proposals > the hitman proposes a shorter deadline, the placer reads it and agrees |
| `revise` | phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `rewardBreakdown` | phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `rewardOptions` | phone: the board, the place form, placing > reads the board, finds a target, sees the reward options, places a contract |
| `rpPlaces` | phone: decay, proof item, the page > the page says it broke, asks the access mode, and the NPC places are read; client events > the client hears its access, settings, pushes, notices, markers, and unloads cleanly |
| `rumourBrief` | phone: rumours > a hitman asks the broker NPC; a broker player briefs somebody standing with them; workflow matrix: allon > contract on memory: clean; workflow matrix: allon > contract on memory: the creator leaves before place |
| `searchTargets` | phone: the board, the place form, placing > reads the board, finds a target, sees the reward options, places a contract; panel: logs, locations, photos > lists a disposal step, respawns its vehicle and skips it; workflow matrix: shipped > contract on memory: clean |
| `sendMessage` | phone: messages and calls > the placer writes to the hitman through the masked relay, mutes, calls, reports |
| `setMeeting` | phone: the handover > the placer sets the meeting point, the hitman sets GPS, arms, the placer confirms |
| `submitPhoto` | phone: the kill photo > the hitman photographs the kill, the placer opens it once and keeps it; phone: the kill photo > sends a picture kept on the server, through the viewfinder |
| `threads` | phone: messages and calls > the placer writes to the hitman through the masked relay, mutes, calls, reports |
| `verifyKill` | phone: the kill photo > verifies a kill at the scene with kill photos off; panel: logs, locations, photos > lists a disposal step, respawns its vehicle and skips it; workflow matrix: shipped > kill on memory: clean |
| `whitelistedView` | phone: the whitelisted-job view > an officer reads the view and turns its alerts on |
| `whitelistedViewAlerts` | phone: the whitelisted-job view > an officer reads the view and turns its alerts on |
| `withdrawReward` | phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |

### netevent.client

| Capability | Workflow test |
|---|---|
| `QBCore:Client:OnPlayerUnload` | client events > the client hears its access, settings, pushes, notices, markers, and unloads cleanly |
| `crimson-hitman:access` | phone: the board, the place form, placing > reads the board, finds a target, sees the reward options, places a contract; phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down |
| `crimson-hitman:adminOpen` | panel: home > the overview, the inbox lists, an announcement, a test alert, refresh, flush, the console; panel: players > looks a player up, views them, their history, and every measure on them; panel: contracts > lists, opens, notes, moves a deadline, edits text, exports, removes a hitman, voids |
| `crimson-hitman:adminPush` | client events > the client hears its access, settings, pushes, notices, markers, and unloads cleanly |
| `crimson-hitman:adminResult` | panel: home > the overview, the inbox lists, an announcement, a test alert, refresh, flush, the console; panel: players > looks a player up, views them, their history, and every measure on them; panel: contracts > lists, opens, notes, moves a deadline, edits text, exports, removes a hitman, voids |
| `crimson-hitman:askDiagnostics` | panel: home > the overview, the inbox lists, an announcement, a test alert, refresh, flush, the console; client events > the client hears its access, settings, pushes, notices, markers, and unloads cleanly |
| `crimson-hitman:client:StepMarker` | phone: the kill photo > the hitman photographs the kill, the placer opens it once and keeps it; phone: the kill photo > sends a picture kept on the server, through the viewfinder; phone: the kill photo > verifies a kill at the scene with kill photos off |
| `crimson-hitman:client:StepMarkerClear` | phone: the kill photo > the hitman photographs the kill, the placer opens it once and keeps it; phone: the kill photo > verifies a kill at the scene with kill photos off; phone: the handover > the placer sets the meeting point, the hitman sets GPS, arms, the placer confirms |
| `crimson-hitman:commandOutput` | client events > the client hears its access, settings, pushes, notices, markers, and unloads cleanly |
| `crimson-hitman:notify` | client events > the client hears its access, settings, pushes, notices, markers, and unloads cleanly |
| `crimson-hitman:orgSpots` | organisation from the phone > the boss hires a recruit, who reads their own tab, the spots and the roles; organisation from the phone > the boss manages a member: role, suspension, limits, grant, codename, then fires them; organisation from the phone > the money: a deposit, a cut, a salary, a bonus, a withdrawal, the funds read back |
| `crimson-hitman:photoImage` | client events > the client hears its access, settings, pushes, notices, markers, and unloads cleanly |
| `crimson-hitman:push` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `crimson-hitman:renderMugshot` | phone: my tabs > the hitman, the placer and the target each read their own tab and the ledger; phone: the target > buys an informant's name of the hitman after them; client events > the client hears its access, settings, pushes, notices, markers, and unloads cleanly |
| `crimson-hitman:result` | phone: the board, the place form, placing > reads the board, finds a target, sees the reward options, places a contract; phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down |
| `crimson-hitman:rpPlacesChanged` | client events > the client hears its access, settings, pushes, notices, markers, and unloads cleanly |
| `crimson-hitman:settings` | client events > the client hears its access, settings, pushes, notices, markers, and unloads cleanly |
| `qbx_core:client:playerLoggedOut` | client events > the client hears its access, settings, pushes, notices, markers, and unloads cleanly |

### netevent.server

| Capability | Workflow test |
|---|---|
| `QBCore:Server:OnPlayerLoaded` | server net events > a death and a revive, a mask, a headshot, a new look, a photo arriving, a defib |
| `crimson-hitman:admin` | panel: home > the overview, the inbox lists, an announcement, a test alert, refresh, flush, the console; panel: players > looks a player up, views them, their history, and every measure on them; panel: contracts > lists, opens, notes, moves a deadline, edits text, exports, removes a hitman, voids |
| `crimson-hitman:appearanceChanged` | server net events > a death and a revive, a mask, a headshot, a new look, a photo arriving, a defib; client events > the client hears its access, settings, pushes, notices, markers, and unloads cleanly |
| `crimson-hitman:iDied` | phone: the kill photo > the hitman photographs the kill, the placer opens it once and keeps it; phone: the kill photo > sends a picture kept on the server, through the viewfinder; phone: the kill photo > verifies a kill at the scene with kill photos off |
| `crimson-hitman:iRevived` | server net events > a death and a revive, a mask, a headshot, a new look, a photo arriving, a defib |
| `crimson-hitman:maskState` | server net events > a death and a revive, a mask, a headshot, a new look, a photo arriving, a defib |
| `crimson-hitman:mugshot` | phone: my tabs > the hitman, the placer and the target each read their own tab and the ledger; phone: the target > buys an informant's name of the hitman after them; server net events > a death and a revive, a mask, a headshot, a new look, a photo arriving, a defib |
| `crimson-hitman:orgUse` | organisation extras 3 from the phone and the panel > reputation, a dead drop, the garage, an internal contract, the handler and the log; server net events > an organisation spot used in the world |
| `crimson-hitman:photoArrived` | server net events > a death and a revive, a mask, a headshot, a new look, a photo arriving, a defib; client events > the client hears its access, settings, pushes, notices, markers, and unloads cleanly |
| `crimson-hitman:whoAmI` | phone: the board, the place form, placing > reads the board, finds a target, sees the reward options, places a contract; phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down |
| `sc-ambulance:server:UseDefib` | server net events > a death and a revive, a mask, a headshot, a new look, a photo arriving, a defib |

### nui

| Capability | Workflow test |
|---|---|
| `adminClose` | commands > the panel opens with its command and closes with -close |
| `adminRequest` | panel: home > the overview, the inbox lists, an announcement, a test alert, refresh, flush, the console; panel: players > looks a player up, views them, their history, and every measure on them; panel: contracts > lists, opens, notes, moves a deadline, edits text, exports, removes a hitman, voids |
| `crimson:abandon` | phone: accept and abandon > a second hitman accepts from the board, then puts it down; organisation extras 2 from the phone and the panel > the record: a walk-away counted, the leaderboard read, staff reset it |
| `crimson:accept` | phone: accept and abandon > a second hitman accepts from the board, then puts it down; organisation extras from the phone and the panel > a contract sent to the organisation: assigned, briefed, approved and taken; organisation extras from the phone and the panel > another moved by staff and released, duty forced off, probation ended and put back |
| `crimson:accessMode` | phone: decay, proof item, the page > the page says it broke, asks the access mode, and the NPC places are read |
| `crimson:addEscrow` | phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `crimson:amendments` | phone: proposals > the hitman proposes a shorter deadline, the placer reads it and agrees |
| `crimson:armKidnap` | phone: the handover > the placer sets the meeting point, the hitman sets GPS, arms, the placer confirms |
| `crimson:bailout` | phone: the target > buys their way out |
| `crimson:brokerBrief` | phone: rumours > a hitman asks the broker NPC; a broker player briefs somebody standing with them |
| `crimson:brokerNearby` | phone: rumours > a hitman asks the broker NPC; a broker player briefs somebody standing with them |
| `crimson:browseTargets` | phone: the board, the place form, placing > reads the board, finds a target, sees the reward options, places a contract |
| `crimson:cancel` | phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `crimson:clearMeeting` | phone: the handover > the placer sets the meeting point, the hitman sets GPS, arms, the placer confirms |
| `crimson:confirmHandover` | phone: the handover > the placer sets the meeting point, the hitman sets GPS, arms, the placer confirms |
| `crimson:create` | phone: the board, the place form, placing > reads the board, finds a target, sees the reward options, places a contract |
| `crimson:decayOff` | phone: decay, proof item, the page > the placer turns decay off; the hitman hands over a proof item |
| `crimson:endCall` | phone: messages and calls > the placer writes to the hitman through the masked relay, mutes, calls, reports |
| `crimson:goDark` | phone: the target > goes dark once a tip on them is bought |
| `crimson:gps` | phone: the handover > the placer sets the meeting point, the hitman sets GPS, arms, the placer confirms; phone: protection > the target posts a job, a guard takes it, sets GPS to the pin, the target cancels |
| `crimson:improve` | phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `crimson:informant` | phone: the target > buys an informant's name of the hitman after them |
| `crimson:kidnapProgress` | phone: the handover > the placer sets the meeting point, the hitman sets GPS, arms, the placer confirms |
| `crimson:ledger` | phone: my tabs > the hitman, the placer and the target each read their own tab and the ledger |
| `crimson:list` | phone: the board, the place form, placing > reads the board, finds a target, sees the reward options, places a contract; phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down |
| `crimson:locationTip` | phone: the target > goes dark once a tip on them is bought |
| `crimson:mine` | phone: my tabs > the hitman, the placer and the target each read their own tab and the ledger |
| `crimson:mugshotImage` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out |
| `crimson:muteThread` | phone: messages and calls > the placer writes to the hitman through the masked relay, mutes, calls, reports |
| `crimson:openPhoto` | phone: the kill photo > the hitman photographs the kill, the placer opens it once and keeps it |
| `crimson:orgAccess` | organisation from the phone > the boss edits the roles: create, rename, powers, pay, cooldown, access, delete |
| `crimson:orgActivity` | organisation extras 3 from the phone and the panel > reputation, a dead drop, the garage, an internal contract, the handler and the log |
| `crimson:orgApplications` | organisation from the phone > places, notices, applications, picks, renaming, the layout and the office rule; organisation extras 2 from the phone and the panel > recruitment: the form set, answered, noted, and the applicant hired |
| `crimson:orgApply` | organisation from the phone > places, notices, applications, picks, renaming, the layout and the office rule; organisation extras 2 from the phone and the panel > recruitment: the form set, answered, noted, and the applicant hired; organisation extras 3 from the phone and the panel > several organisations: a second added, an outsider applies to it, one taken off |
| `crimson:orgApprove` | organisation extras from the phone and the panel > a contract sent to the organisation: assigned, briefed, approved and taken |
| `crimson:orgArmory` | organisation extras 2 from the phone and the panel > the armory: stocked by staff, filled by a member, limited by the boss, drawn from |
| `crimson:orgArmoryLimit` | organisation extras 2 from the phone and the panel > the armory: stocked by staff, filled by a member, limited by the boss, drawn from |
| `crimson:orgArmoryPut` | organisation extras 2 from the phone and the panel > the armory: stocked by staff, filled by a member, limited by the boss, drawn from |
| `crimson:orgArmoryTake` | organisation extras 2 from the phone and the panel > the armory: stocked by staff, filled by a member, limited by the boss, drawn from |
| `crimson:orgAssign` | organisation extras from the phone and the panel > a contract sent to the organisation: assigned, briefed, approved and taken |
| `crimson:orgBonus` | organisation from the phone > the money: a deposit, a cut, a salary, a bonus, a withdrawal, the funds read back |
| `crimson:orgChannel` | organisation extras from the phone and the panel > the channel: written, read, muted and moderated from the phone and the panel |
| `crimson:orgChannelMute` | organisation extras from the phone and the panel > the channel: written, read, muted and moderated from the phone and the panel |
| `crimson:orgChannelPost` | organisation extras from the phone and the panel > the channel: written, read, muted and moderated from the phone and the panel |
| `crimson:orgChannelRemove` | organisation extras from the phone and the panel > the channel: written, read, muted and moderated from the phone and the panel |
| `crimson:orgCodename` | organisation from the phone > the boss manages a member: role, suspension, limits, grant, codename, then fires them |
| `crimson:orgDecide` | organisation from the phone > places, notices, applications, picks, renaming, the layout and the office rule; organisation extras 2 from the phone and the panel > recruitment: the form set, answered, noted, and the applicant hired |
| `crimson:orgDeposit` | organisation from the phone > the money: a deposit, a cut, a salary, a bonus, a withdrawal, the funds read back |
| `crimson:orgDisciplineRecord` | organisation extras 2 from the phone and the panel > discipline: a strike and a warning given, read by the member, one overturned by staff |
| `crimson:orgDossier` | organisation extras from the phone and the panel > a contract sent to the organisation: assigned, briefed, approved and taken |
| `crimson:orgDuty` | organisation extras from the phone and the panel > a contract sent to the organisation: assigned, briefed, approved and taken; organisation extras from the phone and the panel > another moved by staff and released, duty forced off, probation ended and put back |
| `crimson:orgFire` | organisation from the phone > the boss manages a member: role, suspension, limits, grant, codename, then fires them |
| `crimson:orgForceOff` | organisation extras from the phone and the panel > another moved by staff and released, duty forced off, probation ended and put back |
| `crimson:orgFunds` | organisation from the phone > the money: a deposit, a cut, a salary, a bonus, a withdrawal, the funds read back |
| `crimson:orgGarage` | organisation extras 3 from the phone and the panel > reputation, a dead drop, the garage, an internal contract, the handler and the log |
| `crimson:orgGarageOffer` | organisation extras 3 from the phone and the panel > reputation, a dead drop, the garage, an internal contract, the handler and the log |
| `crimson:orgGarageReturn` | organisation extras 3 from the phone and the panel > reputation, a dead drop, the garage, an internal contract, the handler and the log |
| `crimson:orgGarageTake` | organisation extras 3 from the phone and the panel > reputation, a dead drop, the garage, an internal contract, the handler and the log |
| `crimson:orgHire` | organisation from the phone > the boss hires a recruit, who reads their own tab, the spots and the roles; organisation from the phone > the boss manages a member: role, suspension, limits, grant, codename, then fires them; organisation from the phone > the money: a deposit, a cut, a salary, a bonus, a withdrawal, the funds read back |
| `crimson:orgInternalRequest` | organisation extras 3 from the phone and the panel > reputation, a dead drop, the garage, an internal contract, the handler and the log |
| `crimson:orgInterviewNote` | organisation extras 2 from the phone and the panel > recruitment: the form set, answered, noted, and the applicant hired |
| `crimson:orgInviteAnswer` | organisation from the phone > the boss hires a recruit, who reads their own tab, the spots and the roles; organisation from the phone > the boss manages a member: role, suspension, limits, grant, codename, then fires them; organisation from the phone > the money: a deposit, a cut, a salary, a bonus, a withdrawal, the funds read back |
| `crimson:orgLayout` | organisation from the phone > places, notices, applications, picks, renaming, the layout and the office rule |
| `crimson:orgMemberGrant` | organisation from the phone > the boss manages a member: role, suspension, limits, grant, codename, then fires them |
| `crimson:orgMemberLimits` | organisation from the phone > the boss manages a member: role, suspension, limits, grant, codename, then fires them |
| `crimson:orgMembers` | organisation from the phone > the boss manages a member: role, suspension, limits, grant, codename, then fires them; organisation from the phone > the money: a deposit, a cut, a salary, a bonus, a withdrawal, the funds read back; organisation from the phone > places, notices, applications, picks, renaming, the layout and the office rule |
| `crimson:orgMine` | organisation from the phone > the boss hires a recruit, who reads their own tab, the spots and the roles; organisation from the phone > the boss manages a member: role, suspension, limits, grant, codename, then fires them; organisation from the phone > the money: a deposit, a cut, a salary, a bonus, a withdrawal, the funds read back |
| `crimson:orgNotice` | organisation from the phone > places, notices, applications, picks, renaming, the layout and the office rule |
| `crimson:orgOfficeRule` | organisation from the phone > places, notices, applications, picks, renaming, the layout and the office rule |
| `crimson:orgPayoutMethod` | organisation extras 3 from the phone and the panel > reputation, a dead drop, the garage, an internal contract, the handler and the log |
| `crimson:orgPick` | organisation from the phone > places, notices, applications, picks, renaming, the layout and the office rule |
| `crimson:orgPlaceHere` | organisation from the phone > places, notices, applications, picks, renaming, the layout and the office rule |
| `crimson:orgProbationEnd` | organisation extras from the phone and the panel > another moved by staff and released, duty forced off, probation ended and put back |
| `crimson:orgRecruitForm` | organisation extras 2 from the phone and the panel > recruitment: the form set, answered, noted, and the applicant hired |
| `crimson:orgRelease` | organisation extras from the phone and the panel > another moved by staff and released, duty forced off, probation ended and put back |
| `crimson:orgRemoveSpot` | organisation from the phone > places, notices, applications, picks, renaming, the layout and the office rule |
| `crimson:orgRename` | organisation from the phone > places, notices, applications, picks, renaming, the layout and the office rule |
| `crimson:orgRoleCooldown` | organisation from the phone > the boss edits the roles: create, rename, powers, pay, cooldown, access, delete |
| `crimson:orgRoleCreate` | organisation from the phone > the boss edits the roles: create, rename, powers, pay, cooldown, access, delete |
| `crimson:orgRoleDelete` | organisation from the phone > the boss edits the roles: create, rename, powers, pay, cooldown, access, delete |
| `crimson:orgRoleEdit` | organisation from the phone > the boss edits the roles: create, rename, powers, pay, cooldown, access, delete |
| `crimson:orgRolePay` | organisation from the phone > the boss edits the roles: create, rename, powers, pay, cooldown, access, delete |
| `crimson:orgRolePowers` | organisation from the phone > the boss edits the roles: create, rename, powers, pay, cooldown, access, delete |
| `crimson:orgRoles` | organisation from the phone > the boss hires a recruit, who reads their own tab, the spots and the roles; organisation from the phone > the boss edits the roles: create, rename, powers, pay, cooldown, access, delete |
| `crimson:orgSalary` | organisation from the phone > the money: a deposit, a cut, a salary, a bonus, a withdrawal, the funds read back |
| `crimson:orgSetCut` | organisation from the phone > the money: a deposit, a cut, a salary, a bonus, a withdrawal, the funds read back |
| `crimson:orgSetRole` | organisation from the phone > the boss manages a member: role, suspension, limits, grant, codename, then fires them |
| `crimson:orgSpots` | organisation from the phone > the boss hires a recruit, who reads their own tab, the spots and the roles; organisation from the phone > places, notices, applications, picks, renaming, the layout and the office rule |
| `crimson:orgStats` | organisation extras 2 from the phone and the panel > the record: a walk-away counted, the leaderboard read, staff reset it |
| `crimson:orgStrike` | organisation extras 2 from the phone and the panel > discipline: a strike and a warning given, read by the member, one overturned by staff |
| `crimson:orgSuspend` | organisation from the phone > the boss manages a member: role, suspension, limits, grant, codename, then fires them |
| `crimson:orgWithdraw` | organisation from the phone > the money: a deposit, a cut, a salary, a bonus, a withdrawal, the funds read back |
| `crimson:orgWork` | organisation extras from the phone and the panel > a contract sent to the organisation: assigned, briefed, approved and taken; organisation extras from the phone and the panel > another moved by staff and released, duty forced off, probation ended and put back |
| `crimson:pageError` | phone: decay, proof item, the page > the page says it broke, asks the access mode, and the NPC places are read |
| `crimson:photoDecision` | phone: the kill photo > the hitman photographs the kill, the placer opens it once and keeps it |
| `crimson:placerInformant` | phone: the placer's informant > names the anonymous operative on their contract |
| `crimson:proofItem` | phone: decay, proof item, the page > the placer turns decay off; the hitman hands over a proof item |
| `crimson:propose` | phone: proposals > the hitman proposes a shorter deadline, the placer reads it and agrees |
| `crimson:protectionAccept` | phone: protection > the target posts a job, a guard takes it, sets GPS to the pin, the target cancels |
| `crimson:protectionBoard` | phone: protection > the target posts a job, a guard takes it, sets GPS to the pin, the target cancels |
| `crimson:protectionCancel` | phone: protection > the target posts a job, a guard takes it, sets GPS to the pin, the target cancels |
| `crimson:protectionPin` | phone: protection > the target posts a job, a guard takes it, sets GPS to the pin, the target cancels |
| `crimson:protectionPost` | phone: protection > the target posts a job, a guard takes it, sets GPS to the pin, the target cancels |
| `crimson:readThread` | phone: messages and calls > the placer writes to the hitman through the masked relay, mutes, calls, reports |
| `crimson:report` | phone: messages and calls > the placer writes to the hitman through the masked relay, mutes, calls, reports |
| `crimson:requestCall` | phone: messages and calls > the placer writes to the hitman through the masked relay, mutes, calls, reports |
| `crimson:respondAmendment` | phone: proposals > the hitman proposes a shorter deadline, the placer reads it and agrees |
| `crimson:revise` | phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `crimson:rewardBreakdown` | phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `crimson:rewardOptions` | phone: the board, the place form, placing > reads the board, finds a target, sees the reward options, places a contract |
| `crimson:rumourBrief` | phone: rumours > a hitman asks the broker NPC; a broker player briefs somebody standing with them |
| `crimson:saveToPhotos` | phone: the kill photo > the hitman photographs the kill, the placer opens it once and keeps it |
| `crimson:searchTargets` | phone: the board, the place form, placing > reads the board, finds a target, sees the reward options, places a contract |
| `crimson:sendMessage` | phone: messages and calls > the placer writes to the hitman through the masked relay, mutes, calls, reports |
| `crimson:sendVerificationPhoto` | phone: the kill photo > sends a picture kept on the server, through the viewfinder |
| `crimson:setMeeting` | phone: the handover > the placer sets the meeting point, the hitman sets GPS, arms, the placer confirms |
| `crimson:takeVerificationPhoto` | phone: the kill photo > the hitman photographs the kill, the placer opens it once and keeps it; phone: the kill photo > sends a picture kept on the server, through the viewfinder |
| `crimson:threads` | phone: messages and calls > the placer writes to the hitman through the masked relay, mutes, calls, reports |
| `crimson:verificationCamera` | phone: the kill photo > the hitman photographs the kill, the placer opens it once and keeps it |
| `crimson:verifyKill` | phone: the kill photo > verifies a kill at the scene with kill photos off |
| `crimson:whitelistedView` | phone: the whitelisted-job view > an officer reads the view and turns its alerts on |
| `crimson:whitelistedViewAlerts` | phone: the whitelisted-job view > an officer reads the view and turns its alerts on |
| `crimson:withdrawReward` | phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |

### op

| Capability | Workflow test |
|---|---|
| `access` | panel: home > the overview, the inbox lists, an announcement, a test alert, refresh, flush, the console |
| `ackAlerts` | panel: home > the overview, the inbox lists, an announcement, a test alert, refresh, flush, the console |
| `addNote` | panel: contracts > lists, opens, notes, moves a deadline, edits text, exports, removes a hitman, voids |
| `adjustDeadline` | panel: contracts > lists, opens, notes, moves a deadline, edits text, exports, removes a hitman, voids |
| `alerts` | panel: home > the overview, the inbox lists, an announcement, a test alert, refresh, flush, the console |
| `announce` | panel: home > the overview, the inbox lists, an announcement, a test alert, refresh, flush, the console |
| `bossLimits` | panel: the organisation and boss permissions > sets up, edits roles, hires and manages a member, moves money, decides an application |
| `bossOfficeRule` | panel: the organisation and boss permissions > sets up, edits roles, hires and manages a member, moves money, decides an application |
| `bossPermsGet` | panel: the organisation and boss permissions > sets up, edits roles, hires and manages a member, moves money, decides an application |
| `bossPermsRevokeAll` | panel: the organisation and boss permissions > sets up, edits roles, hires and manages a member, moves money, decides an application |
| `bossPermsSet` | organisation from the phone > the boss hires a recruit, who reads their own tab, the spots and the roles; organisation from the phone > the boss manages a member: role, suspension, limits, grant, codename, then fires them; organisation from the phone > the boss edits the roles: create, rename, powers, pay, cooldown, access, delete |
| `console` | panel: home > the overview, the inbox lists, an announcement, a test alert, refresh, flush, the console |
| `contract` | panel: contracts > lists, opens, notes, moves a deadline, edits text, exports, removes a hitman, voids |
| `contracts` | panel: contracts > lists, opens, notes, moves a deadline, edits text, exports, removes a hitman, voids |
| `diag` | panel: home > the overview, the inbox lists, an announcement, a test alert, refresh, flush, the console |
| `disposalList` | panel: logs, locations, photos > lists a disposal step, respawns its vehicle and skips it |
| `disposalRespawn` | panel: logs, locations, photos > lists a disposal step, respawns its vehicle and skips it |
| `disposalSkip` | panel: logs, locations, photos > lists a disposal step, respawns its vehicle and skips it |
| `editText` | panel: contracts > lists, opens, notes, moves a deadline, edits text, exports, removes a hitman, voids |
| `exportContract` | panel: contracts > lists, opens, notes, moves a deadline, edits text, exports, removes a hitman, voids |
| `flush` | panel: home > the overview, the inbox lists, an announcement, a test alert, refresh, flush, the console |
| `freeze` | panel: players > looks a player up, views them, their history, and every measure on them; workflow matrix: shipped > staff on memory: clean; workflow matrix: shipped > staff on memory: the creator leaves before place |
| `history` | panel: players > looks a player up, views them, their history, and every measure on them |
| `logs` | panel: game rules > changes a setting, undoes it, resets it, applies a preset, runs the first-start setup; panel: logs, locations, photos > reads the logs, sets and removes a place, resets a kind, removes kept photos |
| `manualPay` | panel: players > looks a player up, views them, their history, and every measure on them |
| `measures` | panel: players > looks a player up, views them, their history, and every measure on them |
| `orgAcceptDecide` | organisation extras from the phone and the panel > another moved by staff and released, duty forced off, probation ended and put back |
| `orgAccess` | panel: the organisation and boss permissions > sets up, edits roles, hires and manages a member, moves money, decides an application |
| `orgActivityGet` | organisation extras 3 from the phone and the panel > reputation, a dead drop, the garage, an internal contract, the handler and the log |
| `orgApplication` | organisation extras 3 from the phone and the panel > several organisations: a second added, an outsider applies to it, one taken off; panel: the organisation and boss permissions > sets up, edits roles, hires and manages a member, moves money, decides an application |
| `orgArmoryGet` | organisation extras 2 from the phone and the panel > the armory: stocked by staff, filled by a member, limited by the boss, drawn from |
| `orgArmoryLimit` | organisation extras 2 from the phone and the panel > the armory: stocked by staff, filled by a member, limited by the boss, drawn from |
| `orgArmoryStock` | organisation extras 2 from the phone and the panel > the armory: stocked by staff, filled by a member, limited by the boss, drawn from |
| `orgChannelGet` | organisation extras from the phone and the panel > the channel: written, read, muted and moderated from the phone and the panel |
| `orgChannelMute` | organisation extras from the phone and the panel > the channel: written, read, muted and moderated from the phone and the panel |
| `orgChannelPost` | organisation extras from the phone and the panel > the channel: written, read, muted and moderated from the phone and the panel |
| `orgChannelRemove` | organisation extras from the phone and the panel > the channel: written, read, muted and moderated from the phone and the panel |
| `orgContractAssign` | organisation extras from the phone and the panel > another moved by staff and released, duty forced off, probation ended and put back |
| `orgCreate` | organisation extras 3 from the phone and the panel > several organisations: a second added, an outsider applies to it, one taken off |
| `orgCuts` | panel: the organisation and boss permissions > sets up, edits roles, hires and manages a member, moves money, decides an application |
| `orgDossier` | organisation extras from the phone and the panel > another moved by staff and released, duty forced off, probation ended and put back |
| `orgDropSettle` | organisation extras 3 from the phone and the panel > reputation, a dead drop, the garage, an internal contract, the handler and the log |
| `orgDutyOff` | organisation extras from the phone and the panel > another moved by staff and released, duty forced off, probation ended and put back |
| `orgFunds` | panel: the organisation and boss permissions > sets up, edits roles, hires and manages a member, moves money, decides an application |
| `orgFundsBackend` | panel: the organisation and boss permissions > sets up, edits roles, hires and manages a member, moves money, decides an application |
| `orgFundsMove` | panel: the organisation and boss permissions > sets up, edits roles, hires and manages a member, moves money, decides an application; workflow matrix: shipped > payroll on memory: clean; workflow matrix: shipped > payroll on memory: the creator leaves before salary |
| `orgGarageOffer` | organisation extras 3 from the phone and the panel > reputation, a dead drop, the garage, an internal contract, the handler and the log |
| `orgGarageRemove` | organisation extras 3 from the phone and the panel > reputation, a dead drop, the garage, an internal contract, the handler and the log |
| `orgGet` | organisation extras from the phone and the panel > another moved by staff and released, duty forced off, probation ended and put back; organisation extras 3 from the phone and the panel > several organisations: a second added, an outsider applies to it, one taken off; panel: the organisation and boss permissions > sets up, edits roles, hires and manages a member, moves money, decides an application |
| `orgInternalDecide` | organisation extras 3 from the phone and the panel > reputation, a dead drop, the garage, an internal contract, the handler and the log |
| `orgInterviewNote` | organisation extras 2 from the phone and the panel > recruitment: the form set, answered, noted, and the applicant hired |
| `orgLayout` | panel: the organisation and boss permissions > sets up, edits roles, hires and manages a member, moves money, decides an application |
| `orgMemberFire` | organisation extras 3 from the phone and the panel > several organisations: a second added, an outsider applies to it, one taken off; panel: the organisation and boss permissions > sets up, edits roles, hires and manages a member, moves money, decides an application |
| `orgMemberHire` | organisation from the phone > the boss hires a recruit, who reads their own tab, the spots and the roles; organisation from the phone > the boss manages a member: role, suspension, limits, grant, codename, then fires them; organisation from the phone > the boss edits the roles: create, rename, powers, pay, cooldown, access, delete |
| `orgMemberLimits` | panel: the organisation and boss permissions > sets up, edits roles, hires and manages a member, moves money, decides an application |
| `orgMemberOverride` | panel: the organisation and boss permissions > sets up, edits roles, hires and manages a member, moves money, decides an application |
| `orgMemberRole` | panel: the organisation and boss permissions > sets up, edits roles, hires and manages a member, moves money, decides an application |
| `orgMemberSuspend` | panel: the organisation and boss permissions > sets up, edits roles, hires and manages a member, moves money, decides an application |
| `orgNotice` | panel: the organisation and boss permissions > sets up, edits roles, hires and manages a member, moves money, decides an application |
| `orgOverturn` | organisation extras 2 from the phone and the panel > discipline: a strike and a warning given, read by the member, one overturned by staff |
| `orgPayoutMethod` | organisation extras 3 from the phone and the panel > reputation, a dead drop, the garage, an internal contract, the handler and the log |
| `orgPick` | panel: the organisation and boss permissions > sets up, edits roles, hires and manages a member, moves money, decides an application |
| `orgProbation` | organisation extras from the phone and the panel > another moved by staff and released, duty forced off, probation ended and put back |
| `orgRecruitForm` | organisation extras 2 from the phone and the panel > recruitment: the form set, answered, noted, and the applicant hired |
| `orgRemove` | organisation extras 3 from the phone and the panel > several organisations: a second added, an outsider applies to it, one taken off |
| `orgRename` | panel: the organisation and boss permissions > sets up, edits roles, hires and manages a member, moves money, decides an application |
| `orgRepAdjust` | organisation extras 3 from the phone and the panel > reputation, a dead drop, the garage, an internal contract, the handler and the log |
| `orgRolePowers` | panel: the organisation and boss permissions > sets up, edits roles, hires and manages a member, moves money, decides an application; workflow matrix: allon > contract on memory: clean; workflow matrix: allon > contract on memory: the creator leaves before place |
| `orgRoleRemove` | panel: the organisation and boss permissions > sets up, edits roles, hires and manages a member, moves money, decides an application |
| `orgRoleSet` | panel: the organisation and boss permissions > sets up, edits roles, hires and manages a member, moves money, decides an application |
| `orgSalary` | panel: the organisation and boss permissions > sets up, edits roles, hires and manages a member, moves money, decides an application; workflow matrix: shipped > payroll on memory: clean; workflow matrix: shipped > payroll on memory: the creator leaves before salary |
| `orgSetup` | organisation from the phone > the boss hires a recruit, who reads their own tab, the spots and the roles; organisation from the phone > the boss manages a member: role, suspension, limits, grant, codename, then fires them; organisation from the phone > the boss edits the roles: create, rename, powers, pay, cooldown, access, delete |
| `orgStatsGet` | organisation extras 2 from the phone and the panel > the record: a walk-away counted, the leaderboard read, staff reset it |
| `orgStatsReset` | organisation extras 2 from the phone and the panel > the record: a walk-away counted, the leaderboard read, staff reset it |
| `orgStrike` | organisation extras 2 from the phone and the panel > discipline: a strike and a warning given, read by the member, one overturned by staff |
| `overview` | panel: home > the overview, the inbox lists, an announcement, a test alert, refresh, flush, the console |
| `placeList` | panel: logs, locations, photos > reads the logs, sets and removes a place, resets a kind, removes kept photos |
| `placeMyPosition` | panel: logs, locations, photos > reads the logs, sets and removes a place, resets a kind, removes kept photos; panel: logs, locations, photos > lists a disposal step, respawns its vehicle and skips it; workflow matrix: shipped > disposal on memory: clean |
| `placeRemove` | panel: logs, locations, photos > reads the logs, sets and removes a place, resets a kind, removes kept photos |
| `placeReset` | panel: logs, locations, photos > reads the logs, sets and removes a place, resets a kind, removes kept photos |
| `placeSet` | organisation from the phone > the boss hires a recruit, who reads their own tab, the spots and the roles; organisation from the phone > the boss manages a member: role, suspension, limits, grant, codename, then fires them; organisation from the phone > the boss edits the roles: create, rename, powers, pay, cooldown, access, delete |
| `player` | panel: players > looks a player up, views them, their history, and every measure on them; panel: target limits > reads the limits, overrides one player, extends, resets, and sets a job's; workflow matrix: shipped > staff on memory: clean |
| `playerView` | panel: players > looks a player up, views them, their history, and every measure on them |
| `presetApply` | panel: game rules > changes a setting, undoes it, resets it, applies a preset, runs the first-start setup |
| `presetDelete` | panel: game rules > changes a setting, undoes it, resets it, applies a preset, runs the first-start setup |
| `presetSave` | panel: game rules > changes a setting, undoes it, resets it, applies a preset, runs the first-start setup |
| `presetSaveOwn` | panel: game rules > changes a setting, undoes it, resets it, applies a preset, runs the first-start setup |
| `presets` | panel: game rules > changes a setting, undoes it, resets it, applies a preset, runs the first-start setup |
| `protect` | panel: players > looks a player up, views them, their history, and every measure on them |
| `reassignHitman` | workflow matrix: shipped > staff on memory: clean; workflow matrix: shipped > staff on memory: the creator leaves before place; workflow matrix: shipped > staff on memory: the target leaves before accept |
| `reassignPreview` | workflow matrix: shipped > staff on memory: clean; workflow matrix: shipped > staff on memory: the creator leaves before place; workflow matrix: shipped > staff on memory: the target leaves before accept |
| `refresh` | panel: home > the overview, the inbox lists, an announcement, a test alert, refresh, flush, the console |
| `removeHitman` | panel: contracts > lists, opens, notes, moves a deadline, edits text, exports, removes a hitman, voids |
| `removePhotos` | panel: logs, locations, photos > reads the logs, sets and removes a place, resets a kind, removes kept photos |
| `resetSetting` | panel: game rules > changes a setting, undoes it, resets it, applies a preset, runs the first-start setup |
| `resetSettings` | panel: game rules > changes a setting, undoes it, resets it, applies a preset, runs the first-start setup |
| `resolve` | panel: contracts > settles a review item staff are given |
| `reviews` | panel: home > the overview, the inbox lists, an announcement, a test alert, refresh, flush, the console; panel: contracts > settles a review item staff are given |
| `rewardChange` | workflow matrix: shipped > staff on memory: clean; workflow matrix: shipped > staff on memory: the creator leaves before place; workflow matrix: shipped > staff on memory: the target leaves before accept |
| `rewardPreview` | workflow matrix: shipped > staff on memory: clean; workflow matrix: shipped > staff on memory: the creator leaves before place; workflow matrix: shipped > staff on memory: the target leaves before accept |
| `setPlaytime` | panel: players > looks a player up, views them, their history, and every measure on them |
| `setSetting` | panel: game rules > changes a setting, undoes it, resets it, applies a preset, runs the first-start setup; panel: logs, locations, photos > lists a disposal step, respawns its vehicle and skips it; feature switches > every switch turns from the panel and back, in force at once and written down |
| `settings` | panel: game rules > changes a setting, undoes it, resets it, applies a preset, runs the first-start setup |
| `settle` | workflow matrix: shipped, a fault at a database await (mysql) > kill: crash in verify at await 13 (post); workflow matrix: shipped, a fault at a database await (mysql) > buyout: crash in settle at await 17 (pre); workflow matrix: shipped, a fault at a database await (mysql) > disposal: crash in verify at await 13 (post) |
| `setup` | panel: game rules > changes a setting, undoes it, resets it, applies a preset, runs the first-start setup |
| `setupApply` | panel: game rules > changes a setting, undoes it, resets it, applies a preset, runs the first-start setup |
| `setupPreview` | panel: game rules > changes a setting, undoes it, resets it, applies a preset, runs the first-start setup |
| `stuck` | panel: home > the overview, the inbox lists, an announcement, a test alert, refresh, flush, the console; workflow matrix: shipped > contract on memory: clean; workflow matrix: shipped > contract on memory: the creator leaves before place |
| `suspend` | panel: players > looks a player up, views them, their history, and every measure on them; the maintenance tick > lets a proposal nobody answered lapse, ends a suspension, flushes the audit |
| `targetCounts` | panel: target limits > reads the limits, overrides one player, extends, resets, and sets a job's |
| `targetExtend` | panel: target limits > reads the limits, overrides one player, extends, resets, and sets a job's |
| `targetJobAction` | panel: target limits > reads the limits, overrides one player, extends, resets, and sets a job's |
| `targetJobCount` | panel: target limits > reads the limits, overrides one player, extends, resets, and sets a job's |
| `targetJobRemove` | panel: target limits > reads the limits, overrides one player, extends, resets, and sets a job's |
| `targetJobSet` | panel: target limits > reads the limits, overrides one player, extends, resets, and sets a job's |
| `targetLimits` | panel: target limits > reads the limits, overrides one player, extends, resets, and sets a job's |
| `targetOverride` | panel: target limits > reads the limits, overrides one player, extends, resets, and sets a job's |
| `targetOverrideClear` | panel: target limits > reads the limits, overrides one player, extends, resets, and sets a job's |
| `targetReset` | panel: target limits > reads the limits, overrides one player, extends, resets, and sets a job's |
| `targetStatus` | panel: target limits > reads the limits, overrides one player, extends, resets, and sets a job's |
| `testAlert` | panel: home > the overview, the inbox lists, an announcement, a test alert, refresh, flush, the console |
| `undoSetting` | panel: game rules > changes a setting, undoes it, resets it, applies a preset, runs the first-start setup |
| `unfreeze` | panel: players > looks a player up, views them, their history, and every measure on them; workflow matrix: shipped > staff on memory: clean; workflow matrix: shipped > staff on memory: the creator leaves before place |
| `unprotect` | panel: players > looks a player up, views them, their history, and every measure on them |
| `unsuspend` | panel: players > looks a player up, views them, their history, and every measure on them |
| `void` | panel: contracts > lists, opens, notes, moves a deadline, edits text, exports, removes a hitman, voids |
| `whois` | panel: players > looks a player up, views them, their history, and every measure on them |

### screen

| Capability | Workflow test |
|---|---|
| `admin.drawer:money` | tests/ui/admin_run.js (every admin.drawer:) |
| `admin.drawer:notes` | tests/ui/admin_run.js (every admin.drawer:) |
| `admin.drawer:people` | tests/ui/admin_run.js (every admin.drawer:) |
| `admin.drawer:record` | tests/ui/admin_run.js (every admin.drawer:) |
| `admin.drawer:summary` | tests/ui/admin_run.js (every admin.drawer:) |
| `admin.group:bossperms` | tests/ui/admin_run.js (every admin.group:) |
| `admin.group:contracts` | tests/ui/admin_run.js (every admin.group:) |
| `admin.group:developer` | tests/ui/admin_run.js (every admin.group:) |
| `admin.group:help` | tests/ui/admin_run.js (every admin.group:) |
| `admin.group:home` | tests/ui/admin_run.js (every admin.group:) |
| `admin.group:locations` | tests/ui/admin_run.js (every admin.group:) |
| `admin.group:logs` | tests/ui/admin_run.js (every admin.group:) |
| `admin.group:org` | tests/ui/admin_run.js (every admin.group:) |
| `admin.group:players` | tests/ui/admin_run.js (every admin.group:) |
| `admin.group:rules` | tests/ui/admin_run.js (every admin.group:) |
| `admin.group:targets` | tests/ui/admin_run.js (every admin.group:) |
| `admin.inbox:alerts` | tests/ui/admin_run.js (every admin.inbox:) |
| `admin.inbox:all` | tests/ui/admin_run.js (every admin.inbox:) |
| `admin.inbox:reviews` | tests/ui/admin_run.js (every admin.inbox:) |
| `admin.inbox:stuck` | tests/ui/admin_run.js (every admin.inbox:) |
| `admin.view:alerts` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:announce` | tests/ui/admin_run.js |
| `admin.view:bplimits` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:bpmatrix` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:bpoffice` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:changed` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:console` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:contracts` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:devsettings` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:health` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:help` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:howto` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:inbox` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:locations` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:logs` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:measures` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:orgaccess` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:orgapps` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:orgarmory` | tests/ui/admin_run.js |
| `admin.view:orgfunds` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:orgmembers` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:orgnotices` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:orgrecord` | tests/ui/admin_run.js |
| `admin.view:orgroles` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:orgsetup` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:orgturf` | tests/ui/admin_run.js |
| `admin.view:orgwork` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:overview` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:pdiag` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:permissions` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:phistory` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:players` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:pmeasures` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:pmoney` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:pplaytime` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:presets` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:rules` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:setup` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:tldefaults` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:tljobs` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:tlplayer` | tests/ui/admin_run.js (every admin.view:) |
| `admin.view:tools` | tests/ui/admin_run.js (every admin.view:) |
| `phone.boardtab:contracts` | tests/ui/run.js |
| `phone.boardtab:protection` | tests/ui/run.js |
| `phone.dialog:choice` | tests/ui/run.js |
| `phone.dialog:fields` | tests/ui/run.js |
| `phone.dialog:pick` | tests/ui/run.js |
| `phone.dialog:proof` | tests/ui/run.js |
| `phone.dialog:reward` | tests/ui/run.js |
| `phone.dialog:sheet` | tests/ui/run.js |
| `phone.tab:board` | tests/ui/run.js |
| `phone.tab:jobview` | tests/ui/run.js |
| `phone.tab:ledger` | tests/ui/run.js |
| `phone.tab:mine` | tests/ui/run.js |
| `phone.tab:onme` | tests/ui/run.js |
| `phone.tab:org` | tests/ui/run.js |
| `phone.tab:place` | tests/ui/run.js |
| `phone.tab:thread` | tests/ui/run.js |

### switch

| Capability | Workflow test |
|---|---|
| `Admin.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Advisory.AlwaysAlertTarget` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Advisory.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Advisory.FlagListing` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Advisory.OnAccept` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Advisory.OnCancel` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Advisory.OnCreate` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Advisory.OnLocationTip` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Advisory.UseDispatch` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Advisory.WarnCreator` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Advisory.WarnHitman` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Alerts.ToDiscord` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Amendments.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `AntiCollusion.BlockSameAccount` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `App.DefaultInstalled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Audit.LogAllActions` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Audit.LogReasonText` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Bailout.BlockWhileIncapacitated` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Bailout.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `BlockOffDuty` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Completion.KillPhotos` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Completion.RejectLastStand` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Completion.RequireObservedDamage` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Database.AllowModeSwitch` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Database.Json.SyncOnFinancialWrite` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Debug` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Disposal.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `HideAppFromBlockedJobs` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Holds.AppPaused` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Improvements.ContractDecay.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Improvements.ProofItems.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Improvements.SerialScrub.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Improvements.WeeklyStats.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Intel.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Intel.GoDark.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Intel.HoldFirst.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Intel.InPerson.Blip` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Intel.InPerson.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Intel.Informant.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Intel.LocationTip.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Intel.LocationTip.NotifyTarget` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Intel.PlacerInformant.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Intel.Rumours.Blip` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Intel.Rumours.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Intel.SafeZones.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Intel.SecondTry.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Intel.TipLimits.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Intel.TipLimits.OnePerHitman` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Intel.TipLimits.PriceDoubling` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Intel.WarningDelay.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Kidnap.Coercion.handcuffed` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Kidnap.Coercion.passengerOfHitman` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Kidnap.MeetingPoint` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Kidnap.PlacerConfirms` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Kidnap.RejectDead` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Kidnap.RejectLastStand` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Kidnap.RequireCoercion` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Kidnap.RequireConscious` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Ledger.StorePhotos` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Limits.PauseWhileTargetJailed` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Mugshot.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Mugshot.RemoveBackground` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Notifications.ParanoidAlert` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Notifications.PushEnabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.AcceptApproval` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.AcceptNeedsPower` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.ActivityLog` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.ApplyAtSignupOnly` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.ApprovalProbation` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.Armory` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.ArmoryAtOffice` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.Channel` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.Codenames` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.DeadDrops` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.DefaultDuty` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.Discipline` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.Dossiers` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.Duty` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.DutyAtOffice` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.Garage` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.Handler` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.HandlerAssigns` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.InternalContracts` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.OnDutyOnly` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.OrgContracts` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.PaySuspended` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.Payroll` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.Probation` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.ProbationNoStake` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.QbxBossFlag` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.Recruitment` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.Reputation` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.RequireJobToAccept` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.SetPrimaryOnHire` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.SeveralOrganisations` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.Stats` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.StatsLeaderboard` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Organisation.Territory` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Penalty.RequireDisclosureOnAccept` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Record.Heat.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Record.PlacerRecord.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Record.PlacerRecord.ShowForAnonymous` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Record.Progression.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Record.Reputation.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Record.Tiers.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Relay.AllowMaskedCalls` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Relay.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Relay.RequireMaskingForAnonymous` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Roleplay.BurnerPhone.ConsumeOnAccept` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Roleplay.BurnerPhone.ConsumeOnPlace` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Roleplay.BurnerPhone.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Roleplay.BurnerPhone.RequireToOpen` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Roleplay.CityNews.AllTargets` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Roleplay.CityNews.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Roleplay.CityNews.NameTarget` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Roleplay.DirtyPayouts.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Roleplay.EmsRelisting.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Roleplay.EmsRelisting.RequireEMS` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Roleplay.HitOnHitman.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Roleplay.NpcPlaces.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Roleplay.ProofOfIntent.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Roleplay.Protection.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Roleplay.ReasonQuality.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Roleplay.WitnessHeat.AlwaysAlert` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Roleplay.WitnessHeat.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Roleplay.WitnessHeat.SendCoords` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Sources.bank.enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Sources.cash.enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Sources.dirty.enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Sources.item.enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Sources.weapon.enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Staff.DailySummary` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `StepMarkers.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `StepMarkers.Handover` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `StepMarkers.KillScene` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `StepMarkers.Protection` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `TargetClasses.default.AllowAnonymousHitman` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `TargetClasses.default.AllowAnonymousPlacer` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `TargetClasses.default.Informant` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `TargetClasses.default.LocationTip` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `TargetClasses.default.PlacerInformant` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `TargetClasses.default.ShowOperativeNames` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `TargetClasses.default.ShowPlacerOnBoard` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `TargetClasses.whitelisted.AllowAnonymousHitman` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `TargetClasses.whitelisted.AllowAnonymousPlacer` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `TargetClasses.whitelisted.Informant` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `TargetClasses.whitelisted.LocationTip` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `TargetClasses.whitelisted.PlacerInformant` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `TargetClasses.whitelisted.ShowOperativeNames` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `TargetClasses.whitelisted.ShowPlacerOnBoard` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Targeting.AllowBrowseAll` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Targeting.AllowNearby` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `Targeting.AllowProtectedJobTargets` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `VersionCheck.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `WhitelistedView.Alerts` | feature switches > every switch turns from the panel and back, in force at once and written down |
| `WhitelistedView.Enabled` | feature switches > every switch turns from the panel and back, in force at once and written down |

### tick

| Capability | Workflow test |
|---|---|
| `amendments.expire` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `app.sweepFloodCounters` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `app.sweepHandles` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `audit.flush` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `bailout.processQueue` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `bridges.refreshAccess` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `contracts.finishEndings` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `contracts.releaseIdleHolds` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `contracts.retryStuckClaims` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `contracts.retryStuckCreates` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `contracts.retryStuckJoins` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `death.sweep` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `disposal.tick` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `escrow.retryWaiting` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `expireContracts` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `holds.syncAppPause` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `holds.tick` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `imp_decay.tick` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `imp_weekly.tick` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `informant.retryUnsaved` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `ledger.forgetOldPhotos` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `mission_steps.tick` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `notify.deliverKept` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `org.extras` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `org.payroll` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `photo.loadAllowedHosts` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `photo.sweep` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `photos.expire` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `photos.forgetKept` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `playtime.pass` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `ratelimit.sweep` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `record.tick` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `review.decide` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `review.retryUnwritten` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `rp.tick` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `rp_intent.sweep` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `rp_places.announce` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `rp_protection.sweep` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `sanctions.tick` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `storage.flush` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `storage.heartbeat` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `storage.prune` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `summary.tick` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `target_limits.prune` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
| `thresholds.sweep` | phone: the board, the place form, placing > shows the target's face by the reference the board handed out; phone: accept and abandon > a second hitman accepts from the board, then puts it down; phone: the placer's own contract > revises the reason, adds to the reward, reads the breakdown, withdraws a line, improves, cancels |
