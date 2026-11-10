--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                  crimson-hitman - server/org/powers.lua                   ║
    ║          The organisation's boss powers, their areas and defaults         ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- Every power a boss may be given (docs plan §5.4), by its code. Each is off
--- for every boss until staff allow it in Boss permissions; staff themselves
--- may always do everything from the admin panel.
---
--- `office` is whether it needs the boss office by default (staff may change
--- that per organisation). `limits` names the staff bounds it works within
--- (Config.Organisation.Limits, overridden per organisation by staff).
--- D1 (delegate to roles) is R4 under another name, and resolves to it.

local Powers = {}

-- ============================================================================
--                              THE POWERS
-- ============================================================================

Powers.LIST = {
    -- Members
    { code = 'M1', area = 'members', label = 'View members', about = 'See the member list, roles, duty and last seen.' },
    { code = 'M2', area = 'members', label = 'Hire', office = true, limits = { 'MaxMembers', 'HireRadius', 'HireMaxGrade' },
      about = 'Add a player standing nearby to the organisation.' },
    { code = 'M3', area = 'members', label = 'Fire', office = true, limits = { 'FireCooldownMinutes' },
      about = 'Remove a member of a lower rank, with a reason.' },
    { code = 'M4', area = 'members', label = 'Promote / demote', limits = { 'PromotionsPerDay' },
      about = 'Change the role of a member below your rank.' },
    { code = 'M5', area = 'members', label = 'Suspend from contracts', limits = { 'SuspendMaxHours' },
      about = 'Bar a member from accepting contracts for a time.' },
    { code = 'M6', area = 'members', label = 'Member limits', limits = { 'MemberMaxAtOnce', 'MemberCooldownMaxMinutes' },
      about = 'Set a member\'s contracts at once and cooldown between accepts.' },
    { code = 'M7', area = 'members', label = 'Assign codenames', feature = 'Codenames',
      about = 'Give a member below you a codename (Config.Organisation.Codenames).' },
    -- Roles
    { code = 'R1', area = 'roles', label = 'Create roles', office = true, limits = { 'MaxRoles', 'PayMax' },
      about = 'Add a role below your rank.' },
    { code = 'R2', area = 'roles', label = 'Edit roles', office = true,
      about = 'Rename, relabel and reorder roles below your rank.' },
    { code = 'R3', area = 'roles', label = 'Delete roles', office = true,
      about = 'Delete an empty role below your rank.' },
    { code = 'R4', area = 'roles', label = 'Set role powers', office = true,
      about = 'Give or take powers you hold from roles below your rank.' },
    -- Pay
    { code = 'P1', area = 'pay', label = 'Set role pay', limits = { 'PayMax' },
      about = 'Set the pay per pay-cycle of roles below your rank.' },
    { code = 'P2', area = 'pay', label = 'Bonus pay', limits = { 'BonusMax', 'BonusPerDay' },
      about = 'Pay a member a one-off bonus from the funds, with a reason.' },
    { code = 'P3', area = 'pay', label = 'Set salaries', feature = 'Payroll', limits = { 'SalaryMax' },
      about = 'Set the salary each role below you is paid from the funds every pay day.' },
    -- Money and cuts
    { code = 'C1', area = 'money', label = 'Organisation cut', office = true, limits = { 'CutMaxPercent', 'TotalCutCapPercent' },
      about = 'Set the share of each member payout that goes to the funds.' },
    { code = 'C2', area = 'money', label = 'Cut by role', office = true, limits = { 'CutMaxPercent', 'TotalCutCapPercent' },
      about = 'Set the cut for the members of one role.' },
    { code = 'C3', area = 'money', label = 'Cut per member', office = true, limits = { 'CutMaxPercent', 'TotalCutCapPercent' },
      about = 'Set the cut for one member.' },
    { code = 'C4', area = 'money', label = 'Cut on stakes', office = true, limits = { 'StakeCutMaxPercent' },
      about = 'Set the share of a forfeited stake a member wins that goes to the funds.' },
    { code = 'C5', area = 'money', label = 'Cut on buyouts', office = true, limits = { 'BuyoutCutMaxPercent' },
      about = 'Set the share of a buyout premium paid to a member that goes to the funds.' },
    { code = 'C6', area = 'money', label = 'Deposit to funds', about = 'Move your own money into the funds.' },
    { code = 'C7', area = 'money', label = 'Withdraw funds', office = true, limits = { 'WithdrawMax', 'WithdrawPerDay' },
      about = 'Take money out of the funds, with a reason.' },
    { code = 'C8', area = 'money', label = 'View funds', about = 'See the balance and the ledger.' },
    -- Contracts
    { code = 'K1', area = 'contracts', label = 'Contract access rules',
      about = 'Choose which contracts each role may take: never looser than the server.' },
    { code = 'K2', area = 'contracts', label = 'Assign / recommend', about = 'Pin a contract to a member as a boss pick.' },
    { code = 'K3', area = 'contracts', label = 'Role cooldowns', limits = { 'MemberCooldownMaxMinutes' },
      about = 'Set the cooldown between accepts for a role.' },
    -- Locations
    { code = 'L1', area = 'locations', label = 'Move the boss office', limits = { 'OfficeMoveMetres', 'LocationCooldownMinutes' },
      about = 'Move the office to where you stand, near the staff point.' },
    { code = 'L2', area = 'locations', label = 'Sign-up spot', limits = { 'MaxSignupSpots', 'LocationCooldownMinutes' },
      about = 'Place or move the sign-up board where you stand.' },
    { code = 'L3', area = 'locations', label = 'Meeting spots', limits = { 'MaxMeetingSpots', 'LocationCooldownMinutes' },
      about = 'Add organisation meeting spots where you stand.' },
    -- Notices
    { code = 'N1', area = 'notices', label = 'Post notice', limits = { 'NoticeMaxLength' },
      about = 'Edit the board notice and message every member.' },
    { code = 'N2', area = 'notices', label = 'Applications', about = 'Read, accept or reject sign-ups.' },
    -- Settings
    { code = 'S1', area = 'settings', label = 'Organisation label', limits = { 'RenameCooldownMinutes' },
      about = 'Rename the organisation\'s display label (never the job name).' },
    { code = 'S2', area = 'settings', label = 'Boss menu layout', about = 'Rename tabs and hide tabs for roles.' },
    { code = 'S3', area = 'settings', label = 'Office requirement',
      about = 'Choose which of your powers need the office; never a staff-forced one.' },
    -- Delegation
    { code = 'D2', area = 'delegation', label = 'Per-member grants', about = 'Grant or deny powers you hold to members below you.' },
    { code = 'D3', area = 'delegation', label = 'Promote to own rank',
      about = 'Raise someone to your own rank (never above it).' },
}

--- A role right rather than a boss power: who may accept contracts when
--- Config.Organisation.AcceptNeedsPower is on. Never needs the staff
--- ceiling, and any holder of R4 or D2 may pass it to a role or member below.
Powers.TAKE = 'TAKE'

--- Plan names that are another code.
Powers.ALIAS = { D1 = 'R4' }

Powers.AREAS = { 'members', 'roles', 'pay', 'money', 'contracts', 'locations', 'notices', 'settings',
    'delegation' }

Powers.BY_CODE = {}
for i = 1, #Powers.LIST do Powers.BY_CODE[Powers.LIST[i].code] = Powers.LIST[i] end

--- A power code as typed, resolved; nil for anything that is not one.
---@param code any
---@param allowTake boolean|nil TAKE counts too
---@return string|nil
function Powers.resolve(code, allowTake)
    if type(code) ~= 'string' or #code > 4 then return nil end
    code = Powers.ALIAS[code] or code
    if Powers.BY_CODE[code] then return code end
    if allowTake and code == Powers.TAKE then return code end
    return nil
end

--- The powers that need the office by default.
---@return table [code] = true
function Powers.officeDefaults()
    local out = {}
    for i = 1, #Powers.LIST do
        if Powers.LIST[i].office then out[Powers.LIST[i].code] = true end
    end
    return out
end

--- The staff bounds, by key, with what config.lua says (or the code's floor).
Powers.LIMIT_KEYS = {
    MaxMembers = { min = 1, max = 500 }, HireRadius = { min = 1, max = 50, float = true },
    HireMaxGrade = { min = 0, max = 100 }, FireCooldownMinutes = { min = 0, max = 10080 },
    PromotionsPerDay = { min = 0, max = 100 }, SuspendMaxHours = { min = 0, max = 720 },
    MemberMaxAtOnce = { min = 1, max = 50 }, MemberCooldownMaxMinutes = { min = 0, max = 10080 },
    MaxRoles = { min = 1, max = 30 }, PayMax = { min = 0, max = 100000 },
    BonusMax = { min = 0, max = 10000000 }, BonusPerDay = { min = 0, max = 100000000 },
    WithdrawMax = { min = 0, max = 10000000 }, WithdrawPerDay = { min = 0, max = 100000000 },
    CutMaxPercent = { min = 0, max = 100 }, TotalCutCapPercent = { min = 0, max = 100 },
    StakeCutMaxPercent = { min = 0, max = 100 }, BuyoutCutMaxPercent = { min = 0, max = 100 },
    OfficeMoveMetres = { min = 0, max = 5000, float = true }, LocationCooldownMinutes = { min = 0, max = 10080 },
    MaxSignupSpots = { min = 0, max = 20 }, MaxMeetingSpots = { min = 0, max = 50 },
    NoticeMaxLength = { min = 0, max = 2000 }, RenameCooldownMinutes = { min = 0, max = 43200 },
    InviteMinutes = { min = 1, max = 1440 },
    SalaryMax = { min = 0, max = 1000000 }, CodenameCooldownMinutes = { min = 0, max = 43200 },
}

--- One staff bound, clamped, from the organisation's own value or config.
---@param org table|nil the organisation's state (its settings.limits)
---@param key string a LIMIT_KEYS key
---@return number
function Powers.limit(org, key)
    local spec = Powers.LIMIT_KEYS[key]
    if not spec then return 0 end
    local own = org and org.settings and type(org.settings.limits) == 'table' and org.settings.limits[key]
    local fromConfig = type(Config.Organisation) == 'table' and type(Config.Organisation.Limits) == 'table'
        and Config.Organisation.Limits[key]
    local value = tonumber(own) or tonumber(fromConfig) or spec.min
    if value ~= value then value = spec.min end
    value = math.max(spec.min, math.min(spec.max, value))
    if not spec.float then value = math.floor(value) end
    return value
end

return Powers
