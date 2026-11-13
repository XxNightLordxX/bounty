# Changelog

What changed for server owners, staff and players, newest first. Settings
are named by their place in `config/config.lua`; the README and `docs/`
say how things work now.

## 1.2.0

**Review 86 fixes (organisation)**
- Staff panel: **Unlock** on a member, and **Not boss** / **Bosses may edit**
  on a role, now take effect; they answered *Done* and changed nothing.
- Boss permissions **Revoke all** on one boss's column now sets **Deny** on
  every power that boss holds, their role's included, and keeps a Deny staff
  set; it used to put the cells back to *Inherit role*, which handed the
  role's powers (and a denied one) back. The reply counts the powers taken.
- Staff panel refusals from the organisation say the real reason (the boss
  who asked is away, the member left, the organisation still has members,
  and so on) instead of *The organisation does not let your role take this
  contract.*
- Reputation is the plain sum of completions, failures and staff changes:
  failures early on are no longer forgiven, so the same record gives the
  same tier in any order. The standing shown is never below 0.
- With `SeveralOrganisations` off, a member of an organisation kept for when
  it is on is no longer hired, invited, adopted or taken on by application
  into the first one (`org_other_org`).
- An internal-contract request that runs out tells the boss who asked and
  is in the log (`org_internal_decided`, `expired`).
- `ApprovalAbove = 0` holds every accept, one paid only in items included.
- An S3 office rule a boss set can be lifted or taken over by that boss or a
  boss above, not by another boss of the same rank (while the setter is still
  of that rank).
- Start-up warnings for `Config.Organisation.Roles` and `Limits` name the
  shipped roles or values, not a Lua table address.
- `mysql`: an organisation channel post by a member whose name is over 64
  bytes (Cyrillic, emoji) is kept; role labels from the config are cut by
  whole characters; `crimson_org_applications.body` is `MEDIUMTEXT`, so a
  long recruitment form answered in full in a non-Latin script is kept (the
  next start widens it on an existing database, keeping every value).
- Docs: a territory hold tells the organisation `TerritoryMinutes`, not
  `AssignMinutes`, so while the two differ a boss can tell it from a contract
  a placer sent; features.md now says so and how to make them the same.

**Review 86 fixes (pages and docs)**
- Phone: **Go dark** works on a translated server. It echoed the account in
  the page's words and was refused every time with *Going dark now costs …
  Nothing was taken.*; the accept dialog names the anonymity fee's account in
  the page's language too.
- Organisation: a Boss menu name renames only the screen its field is for;
  the screens sharing its layout tab (Assignments, Application form, Activity
  log, the Channel, Armory, Leaderboard and Garage) keep their own names, so
  the menu no longer shows two buttons with one name.
- Organisation › Contracts › Boss pick: **Nobody (clears the pick)** clears
  a pick; **Pin it** with nobody chosen asks for a member instead of quietly
  clearing the pick.
- Organisation: accepting an invite on the Org tab shows the member's page
  at once, not the outsider's Apply form; a two-tap button refused for an
  empty field reads its own name again, so the next two taps send it.
- Phone: **Withdraw** on an anonymous contract says the anonymity fee is not
  refunded, as **Cancel and place again** does; where anonymity was free,
  neither speaks of a fee.
- Phone: the board search says when nothing on this page matches on a board
  of several pages, and to look with **More**.
- Staff panel: **Pay**, **Save the panel's changes as a preset**, Target
  limits' **Extend by minutes** and **Save job limits** name the amount, name
  or minutes when armed (the preset one says when it replaces one of yours),
  and typing in their boxes disarms them, so the second click sets what the
  first one named.
- Staff panel header search: Enter on a name looks the player up unless it is
  exactly a section's, action's or setting's name, and the *Look up as a
  player* row is listed however many rows match.
- Staff panel: a contract's Money tab whose reward read got no answer offers
  **Ask again**; a header-search jump to an organisation or Locations setting
  marks its row once the view has drawn.
- Docs and config notes now say what the code does: the lifetime (holds
  give their time back, a staff extension moves it), an untaken contract's
  deadline (it does not run), the time bands' edges, where a stake goes, the
  proof window against the photo window, buyout and stake caps (cash and
  bank only), the shared rate-limit buckets, `LogAllActions`, the mysql prune
  pace, the target wait after an untaken contract, an away placer's contract
  and the target's cap, idle release on a full competitive contract, the
  burner phone, `AdvisoryHeat`, dirty-money payouts, the bodyguard on a void,
  proof of intent, disposal's `reduced` and `refund` with `PayNowPercent`,
  payroll order, job pay against salary, the armory's day counts, which
  organisation notices name a boss or staff, lb-phone's shared clouds, the
  json files to back up, the audit day files (UTC), which console lines are
  translated, `/ch-void` and moderators, the whitelisted-job view and the
  missing target script.

**Review 85 fixes (organisation)**
- A contract on a member of an organisation is no longer held for that
  organisation when the placer sends it there: it goes on the open board as
  if unsent. Its target is never told of it, shown it in the work list or
  shown who hunts them; it is never assigned to its placer or target (nor by
  its target) and the handler never hands it to either.
- With `Config.Organisation.AcceptApproval` on, a boss who is a contract's
  target is no longer told of, shown or able to refuse a member's accept of
  it; another boss holding Approve accepts, or staff, decide it.
- Contract access *Targets on whitelisted jobs: Not allowed* is now kept, so
  that role can no longer take contracts on police or EMS targets.
- Adding an organisation (`SeveralOrganisations`) with a job name qbx_core
  already has for another job, such as `police`, is refused; one an older
  version saved over such a job is left out at the start, so the job and
  its holders are never touched.
- `mysql`: an application to the recruitment form no longer fails with a
  server error, and a long-running organisation no longer stops saving.
  `crimson_org_applications.body` is `TEXT` and `crimson_orgs.settings`
  `MEDIUMTEXT`; the next start widens both on an existing database, keeping
  every value. The discipline record keeps at most 2000 entries (a former
  member's oldest go first), and an activity-log line the database refuses is
  said in the console instead of failing the boss's action.
- Application text and fire and suspend reasons are cut by whole characters,
  never half of a Polish, Cyrillic or emoji character.
- Garage vehicles out are taken away when staff switch the organisation (or
  several organisations) off, and through the adapter they were made with
  when `Config.Integrations.Garage` was changed since; a return is still
  checked against the garage spot.
- Staff approving an internal contract: the boss who asked must still be a
  member, hold Ask for an internal contract and outrank the target; a member
  who leaves has their requests declined.
- The roster shows a member's *Take contracts* grant as not in force once the
  boss who gave it lost per-member grants.
- Staff without `crimson.identity`: the organisation's work list names no
  member who took an organisation contract anonymously, and the organisation
  log names no citizen id at any depth (a grant's earlier holders, a granter
  fired since), ties no contract to a member and says *a member* or
  *a player* for rows a member or applicant wrote.
- A member muted by staff is told staff muted them when they post; switching
  approvals off tells a waiting member so, never *Nobody approved*; an invite
  that can no longer be accepted says so; a deposit the internal ledger
  refuses is no longer said to be Renewed-Banking's; the organisation-limit
  refusal says which limit.
- A boss's menu layout hides tabs only from grades below their own, and an
  office rule a boss sets binds only up to their grade and cannot be lifted
  from below.
- Translations: the stats time bands, the armory stash label, the codename
  label, two power labels, the strike consequence and overturn notices, the
  salary ledger reason, two spot names and a config warning come from
  `locales/en.lua` as whole sentences.

**Review 85 fixes (pages)**
- Staff panel, Organisation › Funds: a deposit, withdrawal or bonus with no
  answer in time keeps its nonce, so clicking it again cannot move the money
  twice; the panel says *No answer yet. It may still go through: look before
  you try again.* A different amount, reason, direction or member is a new
  movement.
- Staff panel: a Whois answer (who is behind an anonymous party) and the
  Contracts person filter no longer survive closing the panel, and are never
  drawn once the identity ACE is gone.
- Staff panel: an answer to a write on a player's card or in Target limits ›
  Per player that comes back after another player was looked up is told in a
  toast only, never shown on the new player's card.
- Translated servers (`Config.Locale`): every card shows its time left again,
  with the stake-window block and the deadline cut; the server now sends the
  band as a code (`over_2h`, `1_to_2h`, `under_1h`, `under_15m`) that the pages
  put into words. A money source switched off is no longer offered on the
  Place form or Add to it.
- Phone: a protection job taken just as the player's job changed is still
  confirmed, and the board no longer errors.
- Staff panel: Escape with a dropdown open closes the dropdown; a button off
  for its own reason (nothing to apply, no Preview yet) stays off when
  recovery finishes; an emptied list reads *(none)* in Setting changes; how
  a contract ended reads in words (*Withdrawn by the placer*), never its code.
- Organisation › Money: each funds row says when it moved and what moved it
  in words.
- Translations: the waits (*in about 3 minutes*), what a missing script
  means (Config.Integrations), and many single words and joined phrases on
  the phone and in the panel are now in the language files, whole sentences
  with their plural forms.

**Review 85 fixes (server)**
- A kill pays one collection, however many photo tokens are asked for: a
  token asked for while the first photo's claim waited on the database is
  refused (*busy*), and a claim that raised part-way is decided from what the
  store holds before that kill can be claimed again.
- `/ch-diag` in F8 names nobody to staff without `crimson.identity`, as the
  panel's Run diagnosis already did (staff alerts, page faults, the subject's
  identity line and page log).
- A late payout's notice says what arrived (after the organisation's cut, or a
  part already given), not the line's whole amount. The weekly Discord post
  counts only payouts as *Paid out to hitmen*, never refunds.
- The placer's informant shows the answer bought, whatever
  `Config.Intel.PlacerInformant.RevealMode` says later (a new `answer` column
  in `crimson_placer_informants`, added at the next start). A description
  names the job by its label (*LS Customs*), never its internal name.
- A delayed tip warning (`Config.Intel.WarningDelay`) loaded after a start
  whose read failed is still sent, and the target's card shows the tip.
- Locations: a spot staff switched off stays off when a boss moves it with
  Place here; Remove no longer sends the row (with the boss's citizen id) back
  to the page.
- Reason quality (`Config.Roleplay.ReasonQuality`) counts words in any script:
  Cyrillic, Greek and Polish reasons count their real words, and a LowEffort
  phrase in them matches in any case.
- Settings import, presets and the setup apply both halves of a linked pair
  (Buyout pricing's least and most) in one go; a damaged text whose settings
  are a list is refused as damaged, not as secrets.
- A target-limit staff reason is cut by characters, never mid-character.
- `/cleanse` tells a target short of the buyout across both accounts just
  that, not to move money into one account.
- Body disposal: a refused Load or Drop off says why; `ReducedPercent` is what
  the hitman keeps in all with `PayNowPercent`; past `MaxRespawns` a vehicle
  left behind stays where it is instead of being made again for free.
- Contract decay: a reward that never rose is not said to have risen as far as
  it will; the *shorten* stop notice is titled *Contract time*.
- Staff reward preview names the real limits (most it may be lowered by, the
  least a reward may be, the most at once); a refused reassign says why in
  words, never its code.
- The panel's *Largest photo* range is the one the server takes (50,000 to
  1,500,000 bytes); a fractional or infinite duration in `config.lua` is a
  warning, not a stopped start; an advisory is cleared off the MDT even after
  `Config.Integrations.Dispatch` was set to `none`; lowering
  `ParanoidAlertJitter` no longer lets Nearby show a target a contract
  withdrawn inside its own wait.
- Translations: every server sentence that slotted an English word into
  translated text (staff console lines and resolutions, the config check,
  history kinds, meeting, receipts, the panel's spans and export, reputation,
  witness compass points, the guard's pay, proof of intent, reward notices,
  setting rules, *on*/*off* and the other scripts' names) is whole sentences
  in `locales/en.lua`.

**Review 84 fixes (1)**
- Body disposal starts in game: a verified kill with `Config.Disposal` on
  waits in escrow until the drop-off, the vehicle is made and the body can be
  loaded and dropped off. The game's coordinates (a `vector3`) were refused
  as not a table, so the payout went at once and no step was made. Spots in
  `config.lua` may be written as `vector3(...)` or `vector4(...)` (its `w` the
  heading), and the config check and the panel read them.
- Escape in the staff panel closes the innermost thing open first, also when
  the game sees the key: the drawer closes and the reason typed in it is kept.
  A page that cannot answer is still closed from the game after a second.
- A player frozen, suspended, protected or paid while away from the city, by
  the citizen id staff with the identity ACE typed, is no longer listed under
  that citizen id in Measures for staff without it.
- Translations: the disposal time bands, the `/cleanse` price prompt, and
  every other server message that ended in English joined on after the
  language file's words, are now one sentence each in `locales/en.lua`.

**Review 84 fixes (2)**
- Organisation dead drops: each collection is its own drop. On a contract
  with more than one payout slot, a later collection waits its own
  `Config.Organisation.DeadDropMinutes`, its receipt says it waits at the
  drop, and `DeadDropUnclaimed = 'refund'` gives back only the collection
  whose time ran out. Drops saved before this update still pay or refund
  what they held.
- Staff without `crimson.identity` no longer see the member or the contract
  on the organisation's funds ledger rows.
- A member sent off duty, muted, whose accept was approved or refused, or
  given a dossier by staff is told *by staff*, not *a boss*; mutes say
  *1 hour* / *N hours*.
- Clearer refusals: moving a role that still has members, deleting the last
  role, a refusal of Renewed-Banking's society account, and an approved
  accept the contract then refused (now in words, never its code).
- The armory: a put-in or take-out that could not be given back either way
  says it is left for staff, and opens a Review item with the items; one
  whose move raised opens one too.
- The handler's *Briefing:* and *Notice:* lines, and the panel's boss
  permission cell refusals, come from the language file.

**Player review fixes (1)**
- A target who quits mid-handover, or while being shot, no longer comes back
  with ten minutes' immunity for the operative at work on them; a crash with
  nobody at work on them keeps the floor (`Config.Immunity
  .MinTargetSessionMinutes`).
- The Place form, the officer warning and the second tap say when a contract
  goes out under the placer's name, and who sees it.
- A character relog brings back the meeting point and informant tips on the
  map, and an open app drops the last character's form and wallet.
- A hitman who crashes during the placer's confirm window keeps the
  handover; one who crashes right after a kill can still verify it.
- Garage and disposal vehicles are made as their model's own type (bikes,
  boats, helicopters), from qbx_core's shared list or the game.
- A rumour's area stays the one first told across restarts.
- Clearer refusals: a buyout the target cannot pay at all, a handover re-arm
  with how long is left; *too new to be a target* in the Place search;
  notices on the game feed (no phone) keep every word; a first headshot that
  failed is asked for again within a minute; translated board and record
  labels; "held" said once on a held payout.

**Fixes (sweep 9)**
- A kidnapping bonus raised after a reward top-up is escrowed as the full
  new percentage of every payout still held.
- Organisation: a role moved to another rank keeps its staff limit (across a
  restart), cut, access rules, salary, armory limit and hidden tabs; a
  deleted role, or a member who leaves, leaves no settings behind for the
  next one; a lower boss cannot change a higher boss's per-member grant; an
  anonymous accept waiting for approval is never shown to the boss who
  placed the contract (staff see who only with `IdentityAce`); the funds
  ledger names no contract to a boss.
- Panel: a setting under a cap raised from the panel survives a restart, and
  an import, preset or setup raises the cap first; a from-to setting is
  named, imported and restored by presets; text settings take their own rule
  (spaces in a title, a colon in an event name); own preset names are one
  name whatever their case.
- Phone: a kill-photo claim, a protection post or an organisation deposit,
  withdrawal or bonus with no answer in time says it may still go through.

**Escrowed builds start**
- Every Lua file the server runs is listed in `fxmanifest.lua` and loaded by
  FiveM's script loader, the only one that decrypts an escrowed file; the
  module loader no longer reads files itself. A server adapter of your own
  names its path on its first line (`server/adapters/TEMPLATE.lua`).

**Settings export and import**
- Developer, Export & import: every setting changed from the panel and your
  own presets as one JSON text, to copy (not the map places, not the target
  limits). Paste one in and read it: every change from and to, every refused
  key with why (deny list, unknown, read-only, invalid value), the presets it
  would add; nothing changes until Apply, two clicks. Each change goes
  through the normal Save (audited, in Change history with Undo), then one
  `admin_settings_imported` row. Panel ops `settingsExport`,
  `settingsImport`, `settingsImportApply`.

**Your own presets**
- Game rules, Presets: name and save the settings changed from the panel as
  a preset of your own (up to 20; the same name replaces it), listed after
  the shipped ones as *yours*, previewed and applied with two clicks like
  them, and deleted with two clicks. Stored with the settings; audited
  (`admin_preset_saved`, `admin_preset_deleted`). Panel ops `presetSaveOwn`,
  `presetDelete`.

**Config check**
- `/ch-diag config`, and **Check the config** under Developer, Health: every
  value out of range or invalid, every script a switched-on feature needs
  and lacks, every staff ACE `group.admin` does not hold and the commands it
  may not run, and the risky combinations, each in plain words with the fix.
  Reads only.

**Version check** (`Config.VersionCheck`, off as shipped)
- `Enabled = false` and `Url = ''` as shipped: nothing is ever asked. On,
  with an https address, one plain GET at start (no body, no headers of its
  own, an address with a query or fragment refused unasked) and one console
  line when the answer names a newer version. The switch is under Developer,
  Engine settings; the address is config.lua's.

**Translations** (`Config.Locale`, `'en'` as shipped)
- The words players and staff read are looked up by key in language files:
  `locales/en.lua` (notices to players, police advisories, staff alerts and
  their Discord posts, staff notices, the phone app's icon, map markers and
  target options) and `locales/en.json` (the phone's and the panel's
  refusals). Copy both to a language of your own and set `Config.Locale`; a
  key it lacks reads in English, said once in the console. The wording is
  unchanged. Every answer and refusal of the admin panel's requests
  (`server/panel.lua`) is in `locales/en.lua` too, and so is every other
  sentence the server says: the staff commands and the diagnosis, the buyout
  command, every feature's refusals and notices, the organisation's, and the
  panel's setting labels, help and group names. The phone app's every
  label, help line, button and dialog (its tabs included) is in
  `locales/en.json` (`app`), and so is the admin panel's (`admin`, its
  sections, header and help included): every word players and staff read
  is now in the language files (README, Escrow, and where the words live, which
  says step by step how to add a language). The game's own words (map
  markers, the app icon, target options) are in `locales/client/en.lua`, the
  only language file sent to every player. A page text with values names
  them by `%s` (or `%2$s` to reorder), and one that depends on a count has
  `_one` / `_other` forms (and `_few`, `_many` where a language needs them).
  Setting keys never change with the language, and the pages read their
  language files with the build stamp, so an update is never shown with an
  old copy.

**Fixes: the phone, the pages and the clocks**
- Agree, Decline and Apply it on a proposed change, and Take back what I
  ticked, take two taps; the second names the change or what comes back.
- A boss holding Issue strikes or the record power opens a member's
  discipline record from their row on the phone.
- Third-eye spots and disposal options come back when ox_target restarts or
  starts late; a live change of `Config.Integrations.Clothing` is followed;
  nothing waits for a phone that is not there; a barred job's game asks for
  the NPC places once instead of every minute.
- A kill pending its photo outlives a staff freeze (or freezes that could
  not be read) on its contract, with the window it had left. An app pause
  whose end could not be stored is not given back twice at the next start.
  Disposal's `MaxHoldMinutes` leaves out the time staff held the step. An
  organisation's reservation and accept approvals stand still while their
  contract is held. Proposals do not run out between an unfreeze's steps,
  and the freezes coming back after an outage give proposals their time
  back. A stranger's Accept on a frozen contract no longer says which ones a
  frozen player is on.

**Fixes: anonymity and privacy**
- A contract held for an organisation's territory still shows on its own
  placer's board.
- An anonymous accept is left out of the organisation's record,
  leaderboard, reputation and activity log.
- Staff without `crimson.identity` no longer read which staff member saved
  a preset or the setup, which boss asked anonymously for an internal
  contract, or which contract a dead drop is for (dead drops are settled by
  a handle of their own).
- An internal contract keeps the boss's reason as written.
- The organisation's map spots answer only the players they are drawn for,
  and their ids cannot be guessed.
- Presets hide the Developer section's settings from staff who cannot open
  it; Check the config no longer repeats other scripts' console errors (the
  Developer console keeps them, scrubbed); the version check refuses absurd
  version numbers and a broken answer cannot raise.

**Fixes: organisation money and crashes**
- Each organisation keeps its own funds side (ledger or Renewed-Banking):
  moving one leaves the others where they are, and an organisation is
  removed only with both sides empty.
- Moving the funds to Renewed-Banking makes the job's society account
  first; a bank refusal is named as Renewed-Banking's. A move cut short by a
  crash is finished at the next start, so the money is never on both sides
  or on neither, and a bank balance that cannot be read is never carried as
  $0.
- Bonuses, salaries and withdrawals are checked by the balance before and
  after: arrived is marked paid, refused is given back, unclear is left for
  staff, never given back blind. A give-back the funds refuse is tried
  again every tick. One interrupted by a crash, or retried, is paid once or
  left for staff, never twice; while staff hold one, neither a retry nor
  **Pay** pays it.
- A deposit whose give-back fails is owed to the member (or left for staff),
  recorded before anything else is tried. An armory move whose result
  cannot be told is left as it is and logged.
- A cut taken on a payout that never reached the member goes back, so the
  placer gets it whole; the part of a payout paid at the kill (body
  disposal) is cut and held like the rest. A dead drop holds a payout only
  while dead drops and the organisation are on.
- Every organisation money and goods move is a money audit row, whatever
  `Config.Audit.LogAllActions` says.

**Fixes: the last review**
- A kill's photo is accepted after a staff freeze or a restart hold longer
  than two photo windows: the kill keeps the time it was given back.
- After a refused take-back, the button reads *Take back what I ticked*
  again.
- More of the pages' words are whole sentences in the language file
  (counts, *about N min*, *N days ago*); English reads as it did.

**Organisation extras 3** (each its own switch under `Config.Organisation`, off as shipped)
- **Several organisations** (`SeveralOrganisations`, `MaxOrganisations`):
  staff add rival organisations in Hitman organisation, Setup; each is its
  own qbx_core job with its own roles, members, funds, places, Boss
  permissions and log; a citizen is in one at most. Staff ops take `org`; a
  member's phone works on their own; outsiders and placers pick one.
- **Reputation and tiers** (`Reputation`, `RepTiers`): from members'
  completions and failures, less their heat; a tier caps what a member may
  accept. Staff adjust it.
- **Dead drops** (`DeadDrops`): with P4, payouts wait in escrow at a staff-set
  dead drop until collected; unclaimed, paid or refunded (`DeadDropUnclaimed`).
- **Territory** (`Territory`, needs `OrgContracts`): staff zones give the
  organisation a short first refusal on a contract on somebody there, only
  while a member stands near them; nobody is told why or where.
- **Garage** (`Garage`, `GarageVehicles`): staff-approved vehicles at the
  garage spot, through the new garage adapter (`Config.Integrations.Garage`,
  `onesync` or `none`).
- **Internal contracts** (`InternalContracts`): K8 asks for a contract on a
  rogue member; only staff approve it; placed by the boss with every limit.
- **Handler** (`Handler`): NPC spots brief members and hand out waiting
  contracts. **Activity log** (`ActivityLog`): M12 reads what members did.
- Four new Boss permissions rows (P4, V1, K8, M12), off until staff allow
  them; staff do all of it from Hitman organisation, Reputation, drops &
  garage, and Locations (Dead drops, Garage, Territory).

**Organisation extras 2** (each its own switch under `Config.Organisation`, off as shipped)
- **Armory** (`Armory`, `ArmoryItems`): an ox_inventory stash only the app
  reaches; members put in the items staff allow and take out their role's
  limit a day; every move logged. Off with no inventory script, in one line.
- **Record and leaderboard** (`Stats`): each member's completions, failures,
  earnings and reliability, filling Your record; players see time bands only.
- **Discipline** (`Discipline`): strikes and written warnings, decaying,
  barring from contracts or demoting at their marks; only staff overturn.
- **Recruitment** (`Recruitment`): a boss's application form, interview notes,
  a cooldown after a decline and a cap an hour.
- Five new Boss permissions rows (A1, A2, M10, M11, N4), off until staff allow
  them; staff do all of it from Hitman organisation, Armory, Record &
  discipline and Applications.

**Organisation extras** (each its own switch under `Config.Organisation`, off as shipped)
- **Contracts to the organisation** (`OrgContracts`): a placer may send a
  contract to the organisation; a boss assigns it to a member, and it goes on
  the open board if nobody takes it within `AssignMinutes`. The placer is never
  shown to the organisation.
- **Accept approval** (`AcceptApproval`): bigger accepts, or any on probation,
  wait for a boss; nothing is taken while they wait.
- **Probation** (`Probation`), **Duty** (`Duty`, with qbx_core's duty), a
  **private channel** (`Channel`, table `crimson_org_messages`) and
  **dossiers** (`Dossiers`) on assigned organisation contracts.
- Seven new Boss permissions rows (K4-K7, M8, M9, N3), off until staff allow
  them; staff do all of it from Hitman organisation, Work & channel.

**A crash no longer loses money or its record** (`mysql`)
- Money audit rows (payouts, buyouts, tips, deposits) are kept on the
  server machine the moment they are made, and written at the next start
  if the server crashes before the log is written.
- A crash part-way through an acceptance no longer leaves the hitman stuck
  on a contract still shown as open: the next start puts it right.
- An intel purchase (tip, informant, going dark) a crash interrupts is kept
  if it was recorded and refunded if not, once.
- The organisation's Renewed-Banking account and its ledger no longer
  drift apart in a crash: a salary or withdrawal that left without a ledger
  row is put back (so the pay day pays once), a salary taken from the funds
  but not yet handed over is paid (it was left for staff), a deposit that
  arrived gets its row, and a member's deposit that was charged is made.
- A payout a crash cut off and left for staff keeps what the player held
  when its give began: a buyout settle started again no longer overwrites
  it (staff following it paid the premium twice), and a payout paid as
  dirty money counts that item, not their cash. Stuck escrow says
  "paid as black_money, so check that".
- A hitman who leaves the city while their kill is being verified still
  has the body to dispose of; it was skipped and the kill paid at once.
- Staff Pay on a stuck payout held for proof of intent now settles it (owed
  and queued behind the hold, off the stuck list); it answered "nothing to
  settle" and the line stayed stuck.

**Lighter loops**
- The condition sampler no longer runs while no contract is running; it
  starts again the moment one is placed. `ch-diag` says `idle` meanwhile.
- An unworked hold's idle clocks are written in one statement a pass on
  `mysql` (was one a hold), and on `json` in a small file of their own,
  `data/clocks.json`, instead of rewriting `records.json` every tick.
- The broker and informant and the organisation's NPCs share one distance
  loop. Every loop is listed in `docs/dev/loops.md`.

**Other scripts are optional, behind adapters**
- Every script this resource works with besides Qbox is optional:
  `ox_inventory`, `ox_target`, `lb-phone`, `sc-dispatch`, `sc-ambulance` /
  `qbx_medical`, `Renewed-Banking`, `qbx_vehiclekeys`, `MugShotBase64`,
  `sc-blackmarket` and the clothing scripts. Each kind is chosen in
  `Config.Integrations` (`'auto'` as shipped picks what is started, so a
  server with all of them runs as before). One that is missing or set to
  `'none'` turns off only what needs it, said in one console line.
- Add an adapter for another script in a few lines: `docs/dev/adapters.md`
  and the templates in `server/adapters/` and `client/adapters/`.
- `ox_inventory` is no longer a manifest dependency: restarting it no longer
  stops this resource. Without an inventory, cash and bank rewards still work.
- Merged into `Config.Integrations`: `Config.Completion.DeathStateProviders`
  (now `Ambulance`), `Config.Organisation.Funds` (now `Banking`; `'internal'`
  is `'none'`) and `Config.Record.Progression.Resource` (now `Progression`).
- With no phone, notices show in the game's feed.

**First-start setup**
- The admin panel opens a setup screen for the first staff member, until a
  setup is saved: storage mode, the other scripts found (with an override),
  the exact `add_ace` lines, the panel command and the key switches, all
  showing the current values. Preview, then apply with two clicks. It opens
  again from Developer, First-start setup.
- Install in 5 minutes, at the top of the README; this changelog.
- The editable files (config, adapters, install SQL, data) are left out of
  escrow.

**Simpler, with nothing lost**
- One design system for the phone app and the admin panel; a dashboard,
  help on every screen, plainer words and fewer clicks; presets (Strict,
  Relaxed, Roleplay-heavy, Current), previewed before they apply.
- One way to do each job: one marker system, one Places registry for every
  map spot, one Measures area (freeze, suspend, protect, target limits),
  one Holds service, one rules table per target class, one Intel engine,
  one police and press path, one Discord sender, one log view, one Record
  (trust, reputation, tiers, heat, placer record), one payout check.
- Every setting, permission check, audit line and feature is still there
  (checked by the capability inventory test).

## 1.1.0

- **Mission steps**: map markers for each step (on) and body disposal (off).
- **Confirm handover** for the placer (off); staff **Change reward** and
  **Reassign** a hitman.
- **The hitman organisation** (off): a Qbox job with roles, boss
  permissions, funds and cuts, codenames, payroll, a phone tab and a boss
  menu.
- **The admin panel rebuilt** by task (Daily, Setup, Records, Developer),
  with search, Players and Contracts workspaces, Target limits, Boss
  permissions and Locations.
- Review fixes across buyouts, target limits, anonymity and reassigning.

## 1.0.0

- Contracts placed from the phone with rewards held in escrow; competitive
  and exclusive contracts; live handovers and verified kills; buyouts;
  anonymity; informants and tips; advisories to officers; staff tools
  (freeze, suspend, protect, notes, manual pay, review queue, alerts,
  daily summary); roleplay features and improvements, all off as shipped;
  json, mysql and memory storage.
