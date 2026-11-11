--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║             crimson-hitman - server/org/settings_catalogue.lua            ║
    ║      The organisation's admin panel settings (category Organisation)      ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- Added to the settings catalogue (server/settings.lua) in its own
--- category, 'organisation'. Every switch ships off. The job's name, type
--- and the roles it is made with are read-only here: the roles are edited
--- with the organisation's own ops, and the job's name is what its members
--- hold in qbx_core.

local Powers = CrimsonBoot.require('server.org.powers')

local GROUP = 'Organisation'
local LIMITS = 'Organisation: Boss limits'
local NEW_ONLY = 'Read at every use: things already under way finish as they started.'
local AT_USE = 'Read each time it is used.'

local list = {
    { key = 'Organisation.Enabled', section = 'features', category = 'organisation', group = GROUP, kind = 'switch',
      label = 'Hitman organisation',
      about = 'A real qbx_core job with roles, a boss menu and Boss permissions. Off: no job is registered and '
          .. 'nothing changes for anybody.',
      inflight = 'On: the job is registered at once and online members brought in step. Off: every request '
          .. 'answers that it is off; the job stays registered until the next start, which registers none, '
          .. 'and contracts already accepted keep their frozen cut only while it is on.' },
    { key = 'Organisation.RequireJobToAccept', section = 'features', category = 'organisation', group = GROUP,
      kind = 'switch', label = 'Only members may accept contracts',
      about = 'Only players holding the organisation job may accept a contract.', inflight = NEW_ONLY },
    { key = 'Organisation.AcceptNeedsPower', section = 'features', category = 'organisation', group = GROUP,
      kind = 'switch', label = 'Only roles given Take contracts may accept',
      about = 'With the rule above on, only roles (or members) given Take contracts may accept.',
      inflight = NEW_ONLY },
    { key = 'Organisation.OnDutyOnly', section = 'features', category = 'organisation', group = GROUP,
      kind = 'switch', label = 'Members accept only on duty',
      about = 'A member accepts only with the job as their primary job and on duty.', inflight = NEW_ONLY },
    { key = 'Organisation.DefaultDuty', section = 'features', category = 'organisation', group = GROUP,
      kind = 'switch', label = 'On duty when the job is set',
      about = 'qbx_core\'s defaultDuty for the job.', inflight = 'Told to qbx_core at the next job sync.' },
    { key = 'Organisation.SetPrimaryOnHire', section = 'features', category = 'organisation', group = GROUP,
      kind = 'switch', label = 'Joining makes it their primary job',
      about = 'An invite the player accepted, or their application accepted, makes the job their primary one; '
          .. 'otherwise it is one more job they hold. A staff hire never does.',
      inflight = AT_USE },
    { key = 'Organisation.QbxBossFlag', section = 'features', category = 'organisation', group = GROUP,
      kind = 'switch', label = 'Mark boss roles isboss in qbx_core',
      about = 'Lets qbx_management and lb-phone\'s Services boss tab treat bosses as bosses. Their checks are '
          .. 'weaker than this resource\'s, so it ships off.',
      inflight = 'Told to qbx_core at the next job sync.' },
    { key = 'Organisation.ApplyAtSignupOnly', section = 'features', category = 'organisation', group = GROUP,
      kind = 'switch', label = 'Applications only at a sign-up spot',
      about = 'A player applies only while standing at one of the sign-up spots.', inflight = AT_USE },
    { key = 'Organisation.ExternalChanges', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'choice', choices = { 'adopt', 'revert' }, label = 'Job changes made elsewhere',
      about = '"adopt": a /setjob or another resource\'s change is taken into the table. "revert": it is put back '
          .. 'as the table has it.', inflight = AT_USE },
    { key = 'Organisation.OfficeRadius', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', min = 1, max = 50, label = 'Boss office radius (m)',
      about = 'How near the office a boss must stand for powers that need it.', inflight = AT_USE },
    { key = 'Organisation.DrawMetres', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', min = 5, max = 200, label = 'Distance spots are drawn at (m)',
      about = 'Players\' games draw a spot from this far.', inflight = 'Sent with the next change of spots.' },
    { key = 'Organisation.Codenames', section = 'features', category = 'organisation', group = GROUP,
      kind = 'switch', label = 'Codenames',
      about = 'Members pick a codename (or a boss gives one), shown inside the organisation and to placers '
          .. 'instead of their name, only where their name would be shown at all.', inflight = AT_USE },
    { key = 'Organisation.CodenameMinLength', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 1, max = 32, label = 'Shortest codename (characters)',
      about = 'Codenames shorter than this are refused.', inflight = AT_USE },
    { key = 'Organisation.CodenameMaxLength', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 1, max = 32, label = 'Longest codename (characters)',
      about = 'Codenames longer than this are refused.', inflight = AT_USE },
    { key = 'Organisation.CodenameBlocked', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'list', array = true, names = 'phrase', label = 'Words a codename may not contain',
      about = 'Any case; spaces, digits and punctuation are ignored when it is checked.', inflight = AT_USE },
    { key = 'Organisation.Payroll', section = 'features', category = 'organisation', group = GROUP,
      kind = 'switch', label = 'Payroll',
      about = 'Every pay day each member is paid their role\'s salary from the funds; one the funds cannot '
          .. 'cover is skipped and told.', inflight = 'Read at the next pay day; nothing already paid changes.' },
    { key = 'Organisation.PaySuspended', section = 'features', category = 'organisation', group = GROUP,
      kind = 'switch', label = 'Pay suspended members',
      about = 'Off: a member suspended on pay day is not paid that pay day, and told.',
      inflight = 'Read at the next pay day; nothing already paid changes.' },
    { key = 'Organisation.PayrollDays', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 1, max = 31, label = 'Days between pay days',
      about = 'How often salaries are paid.', inflight = 'Used for the pay day after the next one.' },
    -- Organisation extras (server/org/extras.lua), each its own switch, off.
    { key = 'Organisation.OrgContracts', section = 'features', category = 'organisation', group = GROUP,
      kind = 'switch', label = 'Contracts to the organisation',
      about = 'A placer may send a contract to the organisation instead of the open board: a boss assigns it to a '
          .. 'member, and it goes on the open board if nobody takes it in time. The placer stays as anonymous as '
          .. 'on the board.', inflight = 'Off: every contract held goes on the open board at the next tick.' },
    { key = 'Organisation.AssignMinutes', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 1, max = 1440, label = 'Minutes to assign, then to take (min)',
      about = 'How long a contract sent to the organisation waits for a boss to assign it, and then for the member '
          .. 'to take it, before it goes on the open board.', inflight = NEW_ONLY },
    { key = 'Organisation.AcceptApproval', section = 'features', category = 'organisation', group = GROUP,
      kind = 'switch', label = 'Accepts wait for approval',
      about = 'A member\'s accept worth more than the amount below, or of a member on probation, waits for a boss '
          .. 'holding Approve accepts. Nothing is taken while it waits.',
      inflight = 'Off: accepts waiting are dropped at the next tick; nothing was taken for them.' },
    { key = 'Organisation.ApprovalAbove', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 0, max = 2000000000, label = 'Accepts worth more than this wait ($)',
      about = '0: every accept of a member waits.', inflight = NEW_ONLY },
    { key = 'Organisation.ApprovalProbation', section = 'features', category = 'organisation', group = GROUP,
      kind = 'switch', label = 'Accepts on probation wait too',
      about = 'With approval on, every accept of a member on probation waits, whatever it is worth.',
      inflight = NEW_ONLY },
    { key = 'Organisation.ApprovalMinutes', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 1, max = 1440, label = 'Minutes an accept waits for approval',
      about = 'Then it is refused; nothing was taken.', inflight = NEW_ONLY },
    { key = 'Organisation.Probation', section = 'features', category = 'organisation', group = GROUP,
      kind = 'switch', label = 'Probation',
      about = 'New members take only small contracts until their completions are done or a boss signs them off.',
      inflight = AT_USE },
    { key = 'Organisation.ProbationMaxGrade', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 0, max = 100, label = 'Grades on probation (at or below)',
      about = 'Members at or below this grade are on probation; promoted above it, they are off it.',
      inflight = AT_USE },
    { key = 'Organisation.ProbationCompletions', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 0, max = 1000, label = 'Completions that end probation',
      about = 'Counted on their record from when probation began; 0: only a boss or staff end it.',
      inflight = AT_USE },
    { key = 'Organisation.ProbationMaxReward', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 0, max = 2000000000, label = 'Most a contract on probation pays ($)',
      about = 'A member on probation may not take a contract worth more.', inflight = AT_USE },
    { key = 'Organisation.ProbationNoStake', section = 'features', category = 'organisation', group = GROUP,
      kind = 'switch', label = 'No staked contracts on probation',
      about = 'A member on probation may not take a contract with a stake.', inflight = AT_USE },
    { key = 'Organisation.Duty', section = 'features', category = 'organisation', group = GROUP,
      kind = 'switch', label = 'Duty (clock in)',
      about = 'Members clock in and out in the app; only members on duty are assigned, see and take the '
          .. 'organisation\'s contracts. Told to qbx_core where the job is their primary one.',
      inflight = 'Off: everybody counts as on duty at once.' },
    { key = 'Organisation.DutyAtOffice', section = 'features', category = 'organisation', group = GROUP,
      kind = 'switch', label = 'Clock in only at the office',
      about = 'Members go on duty only standing at the boss office.', inflight = AT_USE },
    { key = 'Organisation.Channel', section = 'features', category = 'organisation', group = GROUP,
      kind = 'switch', label = 'Private channel',
      about = 'A message channel inside the Organisation tab: plain text, rate limited, kept the days below.',
      inflight = AT_USE },
    { key = 'Organisation.ChannelRetentionDays', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 1, max = 365, label = 'Days a channel message is kept',
      about = 'Older messages are deleted.', inflight = 'Read at the next hourly clean-up.' },
    { key = 'Organisation.ChannelMaxLength', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 1, max = 1000, label = 'Longest channel message (characters)',
      about = 'Longer messages are refused, never cut.', inflight = AT_USE },
    { key = 'Organisation.ChannelPerMinute', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 1, max = 60, label = 'Channel messages per member a minute',
      about = 'More are refused until the minute has passed.', inflight = AT_USE },
    { key = 'Organisation.Dossiers', section = 'features', category = 'organisation', group = GROUP,
      kind = 'switch', label = 'Dossiers',
      about = 'A boss attaches notes, a meeting spot and the rules of engagement to an assigned organisation '
          .. 'contract, shown only to its member. Never a citizen id.', inflight = AT_USE },
    { key = 'Organisation.DossierMaxLength', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 1, max = 2000, label = 'Longest dossier notes (characters)',
      about = 'Longer notes are refused, never cut.', inflight = AT_USE },
    -- Organisation extras 2 (server/org/extras2.lua), each its own switch, off.
    { key = 'Organisation.Armory', section = 'features', category = 'organisation', group = GROUP,
      kind = 'switch', label = 'Armory',
      about = 'An ox_inventory stash of the organisation\'s, reached only through the Organisation tab: members put '
          .. 'in the items allowed below and take out up to their role\'s limit a day; every move is logged. Needs '
          .. 'an inventory script (Config.Integrations.Inventory); none, it stays off.', inflight = AT_USE },
    { key = 'Organisation.ArmoryItems', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'list', array = true, names = 'item', label = 'Items allowed in the armory',
      about = 'ox_inventory item names members may put in (and staff stock it with). Empty: nothing goes in.',
      inflight = 'Read at every move: items already in it may still be taken out.' },
    { key = 'Organisation.ArmoryAtOffice', section = 'features', category = 'organisation', group = GROUP,
      kind = 'switch', label = 'Armory only at the boss office',
      about = 'Items go in and out only standing at the boss office.', inflight = AT_USE },
    { key = 'Organisation.ArmorySlots', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 1, max = 500, label = 'Armory slots',
      about = 'Slots in the stash, told to ox_inventory.', inflight = 'Told to ox_inventory at the next use.' },
    { key = 'Organisation.ArmoryWeight', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 1000, max = 10000000, label = 'Most the armory holds (grams)',
      about = 'The stash\'s weight limit, told to ox_inventory.', inflight = 'Told to ox_inventory at the next use.' },
    { key = 'Organisation.Stats', section = 'features', category = 'organisation', group = GROUP,
      kind = 'switch', label = 'Record and leaderboard',
      about = 'Each member\'s completions, failures, earnings and reliability in the organisation, counted from '
          .. 'when it is on, and a leaderboard. Players see time bands, never exact times.',
      inflight = 'Counted from now on; off, nothing is counted and the counts are kept.' },
    { key = 'Organisation.StatsLeaderboard', section = 'features', category = 'organisation', group = GROUP,
      kind = 'switch', label = 'Every member sees the leaderboard',
      about = 'Off: only bosses holding View member stats (and staff) see it.', inflight = AT_USE },
    { key = 'Organisation.StatsMinForRate', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 1, max = 1000, label = 'Outcomes before a reliability is shown',
      about = 'Completions and failures together; fewer, no percentage is shown.', inflight = AT_USE },
    { key = 'Organisation.StatsBandShort', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 1, max = 100000, label = 'Time band: first edge (min)',
      about = 'Players see how long a member takes as a band (under this, between edges, over the last).',
      inflight = AT_USE },
    { key = 'Organisation.StatsBandMid', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 1, max = 100000, label = 'Time band: second edge (min)',
      about = 'Above the first edge; one not above it is left out.', inflight = AT_USE },
    { key = 'Organisation.StatsBandLong', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 1, max = 100000, label = 'Time band: last edge (min)',
      about = 'Above the second edge; one not above it is left out.', inflight = AT_USE },
    { key = 'Organisation.Discipline', section = 'features', category = 'organisation', group = GROUP,
      kind = 'switch', label = 'Discipline',
      about = 'Strikes and written warnings with a reason, shown to the member and told to them. Strikes decay; '
          .. 'enough of them bar the member from contracts, or move them a role down. Only staff overturn one.',
      inflight = AT_USE },
    { key = 'Organisation.StrikeDecayDays', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 1, max = 3650, label = 'Days a strike counts',
      about = 'Older strikes stay on the record and no longer count.', inflight = AT_USE },
    { key = 'Organisation.StrikeSuspendAt', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 0, max = 100, label = 'Strikes that bar from contracts',
      about = '0: never. At this many standing strikes the member is barred for the hours below.',
      inflight = 'Read when a strike is given.' },
    { key = 'Organisation.StrikeSuspendHours', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 1, max = 720, label = 'Hours that bar lasts',
      about = 'How long strikes bar a member from contracts.', inflight = 'Read when a strike is given.' },
    { key = 'Organisation.StrikeDemoteAt', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 0, max = 100, label = 'Strikes that move a member a role down',
      about = '0: never. Reaching this many standing strikes moves the member one role down (never the last boss).',
      inflight = 'Read when a strike is given.' },
    { key = 'Organisation.Recruitment', section = 'features', category = 'organisation', group = GROUP,
      kind = 'switch', label = 'Recruitment',
      about = 'An application form with questions a boss sets, read with the answers; interview notes; a cooldown '
          .. 'after a decline and a cap an hour against spam. Hire or decline as with any application.',
      inflight = AT_USE },
    { key = 'Organisation.RecruitQuestions', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 0, max = 20, label = 'Questions on the form at most',
      about = 'How many questions a boss may put on the application form.', inflight = 'Read when the form is set.' },
    { key = 'Organisation.RecruitAnswerMax', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 1, max = 2000, label = 'Longest answer (characters)',
      about = 'Longer answers are refused, never cut.', inflight = AT_USE },
    { key = 'Organisation.RecruitNoteMax', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 1, max = 2000, label = 'Longest interview note (characters)',
      about = 'Longer notes are refused, never cut.', inflight = AT_USE },
    { key = 'Organisation.RecruitCooldownHours', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 0, max = 8760, label = 'Hours a declined applicant waits',
      about = 'Before they may apply again; 0: at once.', inflight = 'Read when an application is declined.' },
    { key = 'Organisation.RecruitPerHour', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', integer = true, min = 1, max = 1000, label = 'Applications taken an hour',
      about = 'More are refused until the hour has passed.', inflight = AT_USE },
    { key = 'Organisation.JobName', section = 'readonly', category = 'organisation', group = GROUP, kind = 'text',
      label = 'Job name', readonly = 'What every member holds in qbx_core: changed, they would lose it. Set it in '
          .. 'config.lua before the organisation is first turned on.' },
    { key = 'Organisation.JobLabel', section = 'readonly', category = 'organisation', group = GROUP, kind = 'text',
      label = 'Job label', readonly = 'The label the organisation is made with; rename it with the organisation\'s '
          .. 'own Rename.' },
    { key = 'Organisation.JobType', section = 'readonly', category = 'organisation', group = GROUP, kind = 'text',
      label = 'Job type', readonly = 'Set it in config.lua; told to qbx_core at the next start.' },
    { key = 'Organisation.Roles', section = 'readonly', category = 'organisation', group = GROUP, kind = 'list',
      label = 'Roles it is made with', readonly = 'Only read the first time it is turned on; roles are edited '
          .. 'with the organisation\'s own Roles.' },
    { key = 'Organisation.NpcModel', section = 'readonly', category = 'organisation', group = GROUP, kind = 'text',
      label = 'NPC model', readonly = 'A ped model the game loads by name. Set it in config.lua.' },
}

--- One number row per staff bound (Config.Organisation.Limits), the
--- defaults every organisation uses until staff change its own.
local ABOUT = {
    MaxMembers = 'Members at most.', HireRadius = 'Metres a hire must stand from the boss.',
    HireMaxGrade = 'The highest grade a boss may hire into.',
    FireCooldownMinutes = 'Minutes between two fires by one boss.',
    PromotionsPerDay = 'Role changes one boss may make a day.',
    SuspendMaxHours = 'Longest a boss may bar a member from contracts.',
    MemberMaxAtOnce = 'Most contracts at once a boss may let a member hold.',
    MemberCooldownMaxMinutes = 'Longest cooldown between accepts a boss may set.',
    MaxRoles = 'Roles at most.', PayMax = 'Most pay a boss may set per role per pay-cycle ($).',
    BonusMax = 'Largest bonus ($).', BonusPerDay = 'Bonuses one boss may pay a day ($).',
    WithdrawMax = 'Largest withdrawal ($).', WithdrawPerDay = 'Withdrawals one boss may make a day ($).',
    CutMaxPercent = 'Most a boss may set the payout cut to (%).',
    TotalCutCapPercent = 'Most of one payout all cuts may take, staff included (%).',
    StakeCutMaxPercent = 'Most a boss may set the stake cut to (%).',
    BuyoutCutMaxPercent = 'Most a boss may set the buyout cut to (%).',
    OfficeMoveMetres = 'How far a boss may move the office from the point staff set.',
    LocationCooldownMinutes = 'Minutes between two moves of a spot by one boss.',
    MaxSignupSpots = 'Sign-up spots at most.', MaxMeetingSpots = 'Organisation meeting spots at most.',
    NoticeMaxLength = 'Characters in the board notice.',
    RenameCooldownMinutes = 'Minutes between two label changes by a boss.',
    InviteMinutes = 'Minutes a boss\'s invite waits for the player to accept it in the app.',
    SalaryMax = 'Most salary a boss may set per role per pay day ($).',
    PayrollPerDayMax = 'Most paid in salaries in all on one pay day ($); 0 is no cap but each role\'s.',
    CodenameCooldownMinutes = 'Minutes between two changes a member makes to their own codename.',
    ChannelMuteMaxHours = 'Longest a boss may mute a member in the organisation channel (hours).',
    ArmoryWithdrawMax = 'Most a boss may let each member of a role take out of the armory a day (items).',
    ArmoryManagePerDay = 'Most a boss holding Manage armory may take out beyond their role\'s limit a day (items).',
    StrikesPerDay = 'Strikes and written warnings one boss may give a day.',
}
local keys = {}
for key in pairs(Powers.LIMIT_KEYS) do keys[#keys + 1] = key end
table.sort(keys)
for _, key in ipairs(keys) do
    local spec = Powers.LIMIT_KEYS[key]
    list[#list + 1] = { key = 'Organisation.Limits.' .. key, section = 'limits', category = 'organisation',
        group = LIMITS, kind = 'number', integer = not spec.float or nil, min = spec.min, max = spec.max,
        label = ABOUT[key] and ABOUT[key]:gsub('%.$', '') or key, about = ABOUT[key] .. ' Staff may set an '
            .. 'organisation\'s own in Boss permissions, Limits.', inflight = AT_USE }
end

return list
