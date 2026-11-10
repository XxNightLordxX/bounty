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
    { key = 'Organisation.Funds', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'choice', choices = { 'auto', 'internal' }, label = 'Where the funds are kept',
      about = '"auto": Renewed-Banking\'s society account when it is installed, this resource\'s ledger otherwise. '
          .. '"internal": always the ledger. Chosen once, the first time the organisation is read, and kept.',
      inflight = 'Read only for that first choice. Staff move the funds between the two with the funds backend '
          .. 'switch, which carries the balance across; while the bank is chosen and not started, nothing moves.' },
    { key = 'Organisation.OfficeRadius', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', min = 1, max = 50, label = 'Boss office radius (m)',
      about = 'How near the office a boss must stand for powers that need it.', inflight = AT_USE },
    { key = 'Organisation.DrawMetres', section = 'limits', category = 'organisation', group = GROUP,
      kind = 'number', min = 5, max = 200, label = 'Distance spots are drawn at (m)',
      about = 'Players\' games draw a spot from this far.', inflight = 'Sent with the next change of spots.' },
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
