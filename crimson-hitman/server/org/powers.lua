CrimsonBoot.define('server.org.powers', function() --[[
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

local L = CrimsonBoot.requireShared('locale').t
local Powers = {}

-- ============================================================================
--                              THE POWERS
-- ============================================================================

Powers.LIST = {
    -- Members
    { code = 'M1', area = 'members', label = L('org_powers.view_members'), about = L('org_powers.see_the_member_list_roles_duty') },
    { code = 'M2', area = 'members', label = L('org_powers.hire'), office = true, limits = { 'MaxMembers', 'HireRadius', 'HireMaxGrade' },
      about = L('org_powers.add_a_player_standing_nearby_to') },
    { code = 'M3', area = 'members', label = L('org_powers.fire'), office = true, limits = { 'FireCooldownMinutes' },
      about = L('org_powers.remove_a_member_of_a_lower') },
    { code = 'M4', area = 'members', label = L('org_powers.promote_demote'), limits = { 'PromotionsPerDay' },
      about = L('org_powers.change_the_role_of_a_member') },
    { code = 'M5', area = 'members', label = L('org_powers.suspend_from_contracts'), limits = { 'SuspendMaxHours' },
      about = L('org_powers.bar_a_member_from_accepting_contracts') },
    { code = 'M6', area = 'members', label = L('org_powers.member_limits'), limits = { 'MemberMaxAtOnce', 'MemberCooldownMaxMinutes' },
      about = L('org_powers.set_a_members_contracts_at_once') },
    { code = 'M7', area = 'members', label = L('org_powers.assign_codenames'), feature = 'Codenames',
      about = L('org_powers.give_a_member_below_you_a') },
    { code = 'M8', area = 'members', label = L('org_powers.end_probation'), feature = 'Probation',
      about = L('org_powers.sign_a_member_below_you_off') },
    { code = 'M9', area = 'members', label = L('org_powers.force_off_duty'), feature = 'Duty',
      about = L('org_powers.send_a_member_below_you_off') },
    { code = 'M10', area = 'members', label = L('org_powers.view_member_stats'), feature = 'Stats',
      about = L('org_powers.see_every_members_completions_failures_earnings') },
    { code = 'M11', area = 'members', label = L('org_powers.issue_strikes'), feature = 'Discipline', limits = { 'StrikesPerDay' },
      about = L('org_powers.give_a_member_below_you_a_2') },
    { code = 'M12', area = 'members', label = L('org_powers.view_org_log'), feature = 'ActivityLog',
      about = L('org_powers.read_what_members_and_bosses_did') },
    -- Roles
    { code = 'R1', area = 'roles', label = L('org_powers.create_roles'), office = true, limits = { 'MaxRoles', 'PayMax' },
      about = L('org_powers.add_a_role_below_your_rank') },
    { code = 'R2', area = 'roles', label = L('org_powers.edit_roles'), office = true,
      about = L('org_powers.rename_relabel_and_reorder_roles_below') },
    { code = 'R3', area = 'roles', label = L('org_powers.delete_roles'), office = true,
      about = L('org_powers.delete_an_empty_role_below_your') },
    { code = 'R4', area = 'roles', label = L('org_powers.set_role_powers'), office = true,
      about = L('org_powers.give_or_take_powers_you_hold') },
    -- Pay
    { code = 'P1', area = 'pay', label = L('org_powers.set_role_pay'), limits = { 'PayMax' },
      about = L('org_powers.set_the_pay_per_pay_cycle') },
    { code = 'P2', area = 'pay', label = L('org_powers.bonus_pay'), limits = { 'BonusMax', 'BonusPerDay' },
      about = L('org_powers.pay_a_member_a_one_off') },
    { code = 'P3', area = 'pay', label = L('org_powers.set_salaries'), feature = 'Payroll', limits = { 'SalaryMax' },
      about = L('org_powers.set_the_salary_each_role_below') },
    { code = 'P4', area = 'pay', label = L('org_powers.choose_payout_method'), feature = 'DeadDrops',
      about = L('org_powers.have_members_payouts_handed_over_as') },
    -- Money and cuts
    { code = 'C1', area = 'money', label = L('org_powers.organisation_cut'), office = true, limits = { 'CutMaxPercent', 'TotalCutCapPercent' },
      about = L('org_powers.set_the_share_of_each_member') },
    { code = 'C2', area = 'money', label = L('org_powers.cut_by_role'), office = true, limits = { 'CutMaxPercent', 'TotalCutCapPercent' },
      about = L('org_powers.set_the_cut_for_the_members') },
    { code = 'C3', area = 'money', label = L('org_powers.cut_per_member'), office = true, limits = { 'CutMaxPercent', 'TotalCutCapPercent' },
      about = L('org_powers.set_the_cut_for_one_member') },
    { code = 'C4', area = 'money', label = L('org_powers.cut_on_stakes'), office = true, limits = { 'StakeCutMaxPercent' },
      about = L('org_powers.set_the_share_of_a_forfeited') },
    { code = 'C5', area = 'money', label = L('org_powers.cut_on_buyouts'), office = true, limits = { 'BuyoutCutMaxPercent' },
      about = L('org_powers.set_the_share_of_a_buyout') },
    { code = 'C6', area = 'money', label = L('org_powers.deposit_to_funds'), about = L('org_powers.move_your_own_money_into_the') },
    { code = 'C7', area = 'money', label = L('org_powers.withdraw_funds'), office = true, limits = { 'WithdrawMax', 'WithdrawPerDay' },
      about = L('org_powers.take_money_out_of_the_funds') },
    { code = 'C8', area = 'money', label = L('org_powers.view_funds'), about = L('org_powers.see_the_balance_and_the_ledger') },
    -- Contracts
    { code = 'K1', area = 'contracts', label = L('org_powers.contract_access_rules'),
      about = L('org_powers.choose_which_contracts_each_role_may') },
    { code = 'K2', area = 'contracts', label = L('org_powers.assign_recommend'), about = L('org_powers.pin_a_contract_to_a_member') },
    { code = 'K3', area = 'contracts', label = L('org_powers.role_cooldowns'), limits = { 'MemberCooldownMaxMinutes' },
      about = L('org_powers.set_the_cooldown_between_accepts_for') },
    { code = 'K4', area = 'contracts', label = L('org_powers.assign_organisation_contracts'), feature = 'OrgContracts',
      about = L('org_powers.give_a_contract_sent_to_the') },
    { code = 'K5', area = 'contracts', label = L('org_powers.reassign_organisation_contracts'), feature = 'OrgContracts',
      about = L('org_powers.move_an_assigned_organisation_contract_to') },
    { code = 'K6', area = 'contracts', label = L('org_powers.approve_accepts'), feature = 'AcceptApproval',
      about = L('org_powers.approve_or_refuse_a_members_accept') },
    { code = 'K7', area = 'contracts', label = L('org_powers.write_dossiers'), feature = 'Dossiers',
      about = L('org_powers.attach_notes_a_meeting_spot_and') },
    { code = 'K8', area = 'contracts', label = L('org_powers.request_internal_contract'), feature = 'InternalContracts',
      about = L('org_powers.ask_staff_for_a_contract_on') },
    -- Locations
    { code = 'L1', area = 'locations', label = L('org_powers.move_the_boss_office'), limits = { 'OfficeMoveMetres', 'LocationCooldownMinutes' },
      about = L('org_powers.move_the_office_to_where_you') },
    { code = 'L2', area = 'locations', label = L('org_powers.sign_up_spot'), limits = { 'MaxSignupSpots', 'LocationCooldownMinutes' },
      about = L('org_powers.place_or_move_the_sign_up') },
    { code = 'L3', area = 'locations', label = L('org_powers.meeting_spots'), limits = { 'MaxMeetingSpots', 'LocationCooldownMinutes' },
      about = L('org_powers.add_organisation_meeting_spots_where_you') },
    -- Notices
    { code = 'N1', area = 'notices', label = L('org_powers.post_notice'), limits = { 'NoticeMaxLength' },
      about = L('org_powers.edit_the_board_notice_and_message') },
    { code = 'N2', area = 'notices', label = L('org_powers.applications'), about = L('org_powers.read_accept_or_reject_sign_ups') },
    { code = 'N3', area = 'notices', label = L('org_powers.moderate_channel'), feature = 'Channel', limits = { 'ChannelMuteMaxHours' },
      about = L('org_powers.remove_messages_in_the_organisation_channel') },
    { code = 'N4', area = 'notices', label = L('org_powers.edit_application_form'), feature = 'Recruitment',
      about = L('org_powers.set_the_questions_an_applicant_answers') },
    -- Armory
    { code = 'A1', area = 'armory', label = L('org_powers.manage_armory'), feature = 'Armory', limits = { 'ArmoryManagePerDay' },
      about = L('org_powers.read_the_armorys_log_and_take') },
    { code = 'A2', area = 'armory', label = L('org_powers.set_armory_limits'), feature = 'Armory', limits = { 'ArmoryWithdrawMax' },
      about = L('org_powers.set_how_much_each_member_of') },
    -- Garage
    { code = 'V1', area = 'garage', label = L('org_powers.manage_garage'), feature = 'Garage',
      about = L('org_powers.choose_which_of_the_staff_approved') },
    -- Settings
    { code = 'S1', area = 'settings', label = L('org_powers.organisation_label'), limits = { 'RenameCooldownMinutes' },
      about = L('org_powers.rename_the_organisations_display_label_never') },
    { code = 'S2', area = 'settings', label = L('org_powers.boss_menu_layout'), about = L('org_powers.rename_tabs_and_hide_tabs_for') },
    { code = 'S3', area = 'settings', label = L('org_powers.office_requirement'),
      about = L('org_powers.choose_which_of_your_powers_need') },
    -- Delegation
    { code = 'D2', area = 'delegation', label = L('org_powers.per_member_grants'), about = L('org_powers.grant_or_deny_powers_you_hold') },
    { code = 'D3', area = 'delegation', label = L('org_powers.promote_to_own_rank'),
      about = L('org_powers.raise_someone_to_your_own_rank') },
}

--- A role right rather than a boss power: who may accept contracts when
--- Config.Organisation.AcceptNeedsPower is on. Never needs the staff
--- ceiling, and any holder of R4 or D2 may pass it to a role or member below.
Powers.TAKE = 'TAKE'

--- Plan names that are another code.
Powers.ALIAS = { D1 = 'R4' }

Powers.AREAS = { 'members', 'roles', 'pay', 'money', 'contracts', 'locations', 'notices', 'armory', 'garage',
    'settings', 'delegation' }

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
    SalaryMax = { min = 0, max = 1000000 }, PayrollPerDayMax = { min = 0, max = 100000000 },
    CodenameCooldownMinutes = { min = 0, max = 43200 },
    ChannelMuteMaxHours = { min = 0, max = 720 },
    ArmoryWithdrawMax = { min = 0, max = 1000 }, ArmoryManagePerDay = { min = 0, max = 1000 },
    StrikesPerDay = { min = 0, max = 100 },
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
end)
