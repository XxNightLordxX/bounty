CrimsonBoot.define('server.settings', function() --- Settings staff change from the admin panel, kept over config.lua.
---
--- The owner wanted every feature switchable, and the limits changeable,
--- from inside the game, with every change surviving a restart. config.lua
--- stays the file a server owner edits: what the panel changes is kept
--- beside it as an override per key, in whichever store the server runs
--- (memory, json records.json, mysql crimson_settings), applied over the
--- config at every start, right after the start-up checks and before
--- anything reads the config, and changed live in the same table every
--- module reads at use time.
---
--- Only keys in the catalogue below can be changed, and each one is checked
--- the way the start-up checks it (main.lua's validateConfig, run against a
--- copy of the config with the new value in it): a value those checks would
--- refuse, or quietly correct, is refused here with their words. A switch
--- that would lock staff out, or one that needs a migration, is listed
--- read-only with the reason.
---
--- What happens to things already under way when a feature is turned off
--- is the same everywhere unless an entry says otherwise: contracts already
--- placed, and payouts already owed, finish under the rules they started
--- with, and only new actions are refused, with CH.ERR.FEATURE_OFF (or the
--- feature's own code) and words on the page. No switch here strands money.

local Util = CrimsonBoot.requireShared('util')
local Log = CrimsonBoot.requireShared('log')
local Geo = CrimsonBoot.requireShared('geo')
local Lock = CrimsonBoot.require('server.lib.lock')
local Integrations = CrimsonBoot.require('server.adapters.init')
local L = CrimsonBoot.requireShared('locale').t

local Settings = {}

local Storage, Audit, Check

--- What config.lua says for each catalogue key, as the start-up checks left
--- it, before any override: what a reset puts back. [key] = value
local defaults = {}

--- Overrides in force. [key] = { value, by, at }
local overrides = {}

--- Overrides the store holds that were not applied at start, and why.
--- [key] = { value, by, at, why }
local ignored = {}

--- Keys a change raised on and could not be read back for: the store may
--- or may not hold what was written, and the diagnosis says so until a
--- change to the key, or the next start, settles it. [key] = { why, by, at }
local unknown = {}

--- Called with (key, entry) after a key changes live; set by Bridges.install,
--- which knows who to tell (the access refresh, the photo host list).
Settings.onChanged = nil

--- Functions called after one key changes live, by key: what a switch
--- starts or stops the moment it is turned (the app pause,
--- Holds.syncAppPause). Kept across Settings.init. [key] = fn
local watchers = {}

--- Call `fn` after `key` changes live (set, reset, reset all, an undo).
---@param key string
---@param fn function
function Settings.watch(key, fn)
    if type(key) == 'string' and type(fn) == 'function' then watchers[key] = fn end
end

--------------------------------------------------------------------------
-- The catalogue
--------------------------------------------------------------------------

--- Shared wording for in-flight behaviour, so every entry says the same
--- thing the same way.
local NEW_ONLY = L('settings.things_already_under_way_finish_under')
local AT_USE = L('settings.read_each_time_it_is_used')
local CAP = L('settings.lowering_it_below_what_is_in')
local RESTART = L('settings.read_once_at_start_kept_now')

--- Never changed from the panel, whatever a page sends: shown read-only with
--- why, and refused by Settings.check before anything else. Secrets (secret
--- = true) are shown only as set or not set, never their value; a key here
--- that config.lua does not hold (a convar, a key nil by default) is listed
--- all the same. [key] = { why, secret, convar }
local EDIT_IN_CONFIG = L('settings.edit_it_in_config_lua')
local DENY = {
    ['Locale'] = { label = L('settings.language'),
        why = L('settings.the_language_players_and_staff_see') .. EDIT_IN_CONFIG },
    ['VersionCheck.Url'] = { label = L('settings.version_check_address'),
        why = L('settings.an_address_the_server_asks_once') .. EDIT_IN_CONFIG },
    ['Database.Mode'] = { label = L('settings.storage_mode'),
        why = L('settings.changing_it_needs_the_money_in') .. EDIT_IN_CONFIG },
    ['Database.Json.Directory'] = { label = L('settings.json_store_folder'),
        why = L('settings.where_the_json_store_lives_on') .. EDIT_IN_CONFIG },
    ['Admin.Ace'] = { label = L('settings.staff_panel_ace'),
        why = L('settings.who_may_use_this_panel_an') .. EDIT_IN_CONFIG },
    ['Admin.IdentityAce'] = { label = L('settings.identity_ace_unmask_anonymous_parties'),
        why = L('settings.who_may_unmask_anonymous_parties_an') .. EDIT_IN_CONFIG },
    ['Admin.DeveloperAce'] = { label = L('settings.developer_section_ace'),
        why = L('settings.who_sees_the_developer_section_an') .. EDIT_IN_CONFIG },
    ['Admin.ModeratorAce'] = { label = L('settings.moderator_ace'),
        why = L('settings.who_may_freeze_suspend_protect_and') .. EDIT_IN_CONFIG },
    ['Admin.ExtraAces'] = { label = L('settings.extra_aces_that_may_read_the'),
        why = L('settings.aces_that_may_read_the_staff') .. EDIT_IN_CONFIG },
    ['Reason.PatternDenylist'] = { label = L('settings.patterns_a_reason_may_not_contain'),
        why = L('settings.lua_patterns_a_malformed_one_raises')
        .. EDIT_IN_CONFIG },
    ['Completion.PhotoPublicUrl'] = { label = L('settings.address_photos_are_served_from'),
        why = L('settings.the_address_photos_are_served_from') .. EDIT_IN_CONFIG },
    ['Completion.KeptPhotoDays'] = { label = L('settings.days_a_saved_photo_is_kept'),
        why = L('settings.nil_keeps_a_saved_photo_until') .. EDIT_IN_CONFIG },
    ['Disposal.VehicleSpawn'] = { label = L('settings.disposal_vehicle_spawn_spot'),
        why = L('settings.a_place_set_it_with_the')
        .. EDIT_IN_CONFIG },
    ['Disposal.DropOff'] = { label = L('settings.disposal_drop_off'),
        why = L('settings.a_place_set_it_with_the')
        .. EDIT_IN_CONFIG },
    ['Kidnap.RestraintProvider'] = { label = L('settings.restraint_export'),
        why = L('settings.a_resource_export_called_by_name') .. EDIT_IN_CONFIG },
    ['Immunity.PlaytimeProvider'] = { label = L('settings.playtime_export'),
        why = L('settings.a_resource_export_called_by_name') .. EDIT_IN_CONFIG },
    ['Relay.CallExport'] = { label = L('settings.phone_call_export'),
        why = L('settings.a_resource_export_called_by_name') .. EDIT_IN_CONFIG },
    ['convar:crimson_hitman_webhook'] = { secret = true, convar = 'crimson_hitman_webhook',
        why = L('settings.the_discord_webhook_for_the_log') },
    ['convar:crimson_hitman_alert_webhook'] = { secret = true, convar = 'crimson_hitman_alert_webhook',
        why = L('settings.the_discord_webhook_for_alerts_a') },
}
Settings.DENY = DENY

--- The categories a key is shown under in the panel: who uses it.
Settings.CATEGORIES = { 'rules-timers', 'rules-rewards', 'rules-limits', 'rules-targeting', 'features',
    'developer', 'organisation',
    -- The Target limits section's Defaults (server/targetlimits.lua).
    'target-limits',
    -- The step markers and body disposal (server/missionsteps.lua).
    'mission-steps' }

--- Rewards & money, shown in these groups rather than the key's own.
local MONEY = {
    ['MaxContractValue'] = 'Rewards', ['Limits.MinContractReward'] = 'Rewards',
    ['Sources.cash.max'] = 'Rewards', ['Sources.bank.max'] = 'Rewards', ['Sources.dirty.max'] = 'Rewards',
    ['Sources.dirty.item'] = 'Rewards', ['Sources.item.maxStacks'] = 'Rewards',
    ['Sources.item.maxPerStack'] = 'Rewards', ['Sources.weapon.max'] = 'Rewards',
    ['Bonus.maxPercent'] = 'Rewards',
    ['Limits.MaxPayoutSlots'] = 'Payouts', ['Limits.SlotCooldownSeconds'] = 'Payouts',
    ['PendingEscrow.MaxRetriesPerLogin'] = 'Payouts', ['PendingEscrow.LoginRetryDelayMs'] = 'Payouts',
    ['Bailout.MinMultiplier'] = 'Buyouts', ['Bailout.MaxMultiplier'] = 'Buyouts',
    ['Bailout.AbsoluteMax'] = 'Buyouts', ['Bailout.ProcessingDelaySeconds'] = 'Buyouts',
    ['Intel.Informant.Cost'] = 'Intel prices', ['Intel.Informant.Account'] = 'Intel prices',
    ['Intel.PlacerInformant.Cost'] = 'Intel prices', ['Intel.PlacerInformant.Account'] = 'Intel prices',
    ['Intel.LocationTip.Cost'] = 'Intel prices', ['Intel.LocationTip.Account'] = 'Intel prices',
    ['Anonymity.CreatorFee'] = 'Anonymity fees', ['Anonymity.HitmanFee'] = 'Anonymity fees',
    ['Anonymity.FeeAccount'] = 'Anonymity fees',
    ['EscrowBlacklist'] = 'Escrow', ['Limits.MaxEscrowLines'] = 'Escrow', ['Penalty.MaxAmount'] = 'Escrow',
    ['Penalty.MaxFractionOfEscrow'] = 'Escrow',
}
Settings.MONEY = MONEY

--- Beside both restraints. With a restraint required and neither counting
--- (and no restraint resource), every handover was refused as 'not
--- restrained', even with the target cuffed in the hitman's car: on 'alive'
--- no contract could complete, and each ran to its deadline with its
--- hitman's stake forfeited. The start turns handcuffs back on; this
--- refuses the click that would do it, in the start's words.
local ONE_RESTRAINT = L('settings.while_target_must_be_restrained_is')

--- What the panel says beside a key whose `unless` switch is on.
local UNLESS_ON = {
    ['WhitelistedView.Enabled'] = L('settings.does_not_apply_while_the_whitelisted'),
}

--- What the panel says beside a key whose `needs` switch is off.
local NEEDS_OFF = {
    ['Completion.KillPhotos'] = L('settings.does_not_apply_while_kill_photos'),
    ['Mugshot.Enabled'] = L('settings.does_not_apply_while_target_headshots'),
    ['WhitelistedView.Enabled'] = L('settings.does_not_apply_while_the_whitelisted_2'),
    ['Intel.Enabled'] = L('settings.does_not_apply_while_every_informant'),
    ['Intel.Informant.Enabled'] = L('settings.does_not_apply_while_the_targets'),
    ['Intel.PlacerInformant.Enabled'] = L('settings.does_not_apply_while_the_placers'),
    ['Intel.LocationTip.Enabled'] = L('settings.does_not_apply_while_the_informant'),
    ['Kidnap.RequireCoercion'] = L('settings.does_not_apply_while_target_must'),
}

--- Every key the panel may show, in the order it shows them.
---
--- kind: 'switch' (on/off), 'choice' (one of `choices`), 'number' (with
--- min, max and `integer`), 'list' (job names). needs is a switch this key
--- means nothing without: while it is off the panel says so beside the key
--- (`inactive`, from NEEDS_OFF); unless is the other way round, a switch
--- this key means nothing beside while it is ON (UNLESS_ON). section: 'features' or
--- 'limits'. live = false is a key kept and applied at the next start (or
--- the next time what reads it runs), and said so. client = true is a key
--- players' games read too, sent to them when it changes. readonly is the
--- reason a key cannot be changed here. destroys is for a number whose
--- lowering deletes something for good (0 being 'never', the highest): what
--- the panel says lowering it does, %s the new value. Lowering it takes the
--- two clicks every other destructive button does; one click, or Enter in
--- the box, put a typo of 1 for 10 days into force, and the next sweep
--- deleted every unopened kill photo older than a day.
local CATALOGUE = {
    -- Features ------------------------------------------------------------
    { key = 'BlockOffDuty', section = 'features', category = 'features', group = 'Access', kind = 'switch',
      label = L('settings.bar_off_duty_officers'),
      about = L('settings.barred_jobs_stay_barred_from_the'),
      inflight = AT_USE .. L('settings.who_may_see_the_app_is') },
    { key = 'HideAppFromBlockedJobs', section = 'features', category = 'features', group = 'Access', kind = 'switch',
      unless = 'WhitelistedView.Enabled',
      label = L('settings.hide_the_app_from_barred_jobs'),
      about = L('settings.keeps_the_app_off_a_barred'),
      inflight = L('settings.every_phone_is_told_at_once') },
    { key = 'WhitelistedView.Enabled', section = 'features', category = 'features', group = 'Access', kind = 'switch',
      label = L('settings.whitelisted_job_view'),
      about = L('settings.barred_jobs_police_ems_doj_lawyers'),
      inflight = L('settings.every_phone_is_told_at_once_2') },
    { key = 'WhitelistedView.Alerts', section = 'features', category = 'features', group = 'Access', kind = 'switch',
      needs = 'WhitelistedView.Enabled',
      label = L('settings.notify_me_on_the_whitelisted_job'),
      about = L('settings.a_player_on_the_whitelisted_job'),
      inflight = L('settings.read_at_every_use_with_no') },
    { key = 'App.DefaultInstalled', section = 'features', category = 'features', group = 'The app', kind = 'switch',
      label = L('settings.put_the_app_on_every_home'), client = true, live = false,
      about = L('settings.installs_the_app_on_eligible_phones'),
      inflight = L('settings.applies_after_restart_read_when_the') },

    { key = 'Sources.cash.enabled', section = 'features', category = 'features', group = 'Rewards', kind = 'switch',
      label = L('settings.cash_rewards'), about = L('settings.cash_may_be_put_up_as'), inflight = NEW_ONLY
          .. L('settings.cash_already_held_in_escrow_is') },
    { key = 'Sources.bank.enabled', section = 'features', category = 'features', group = 'Rewards', kind = 'switch',
      label = L('settings.bank_rewards'), about = L('settings.bank_money_may_be_put_up'), inflight = NEW_ONLY
          .. L('settings.money_already_held_in_escrow_is') },
    { key = 'Sources.dirty.enabled', section = 'features', category = 'features', group = 'Rewards', kind = 'switch',
      label = L('settings.dirty_money_rewards'), about = L('settings.dirty_money_may_be_put_up'),
      inflight = NEW_ONLY .. L('settings.money_already_held_in_escrow_is') },
    { key = 'Sources.item.enabled', section = 'features', category = 'features', group = 'Rewards', kind = 'switch',
      label = L('settings.item_rewards'), about = L('settings.items_may_be_put_up_as'), inflight = NEW_ONLY
          .. L('settings.items_already_held_in_escrow_are') },
    { key = 'Sources.weapon.enabled', section = 'features', category = 'features', group = 'Rewards', kind = 'switch',
      label = L('settings.weapon_rewards'), about = L('settings.weapons_may_be_put_up_as'), inflight = NEW_ONLY
          .. L('settings.weapons_already_held_in_escrow_are') },

    { key = 'Completion.Fulfilment', section = 'features', group = 'Completion', kind = 'choice',
      category = 'rules-limits',
      choices = { 'alive', 'either' }, label = L('settings.how_contracts_are_completed'),
      -- Who the target is handed to, said here as everywhere a player reads
      -- it; and no photograph, which under KillPhotos off is never taken.
      about = L('settings.alive_live_transfer_only_the_target'),
      inflight = L('settings.each_contract_keeps_the_rule_it') },
    { key = 'Completion.KillPhotos', section = 'features', category = 'features', group = 'Completion', kind = 'switch',
      label = L('settings.kill_photos'),
      about = L('settings.off_no_kill_photo_is_ever'),
      inflight = L('settings.read_at_the_next_verify_kill') },
    { key = 'Completion.PhotoStorage', section = 'features', group = 'Completion', kind = 'choice',
      category = 'developer',
      needs = 'Completion.KillPhotos',
      choices = { 'server', 'host' }, label = L('settings.where_kill_photos_are_kept'),
      about = L('settings.server_in_this_resources_data_folder'),
      inflight = L('settings.photos_already_kept_stay_where_they') },
    { key = 'Completion.RequireObservedDamage', section = 'features', category = 'features', group = 'Completion',
      kind = 'switch', label = L('settings.kills_need_damage_the_server_saw'),
      about = L('settings.the_killer_a_victim_names_must'),
      inflight = AT_USE },
    { key = 'Ledger.StorePhotos', section = 'features', category = 'features', group = 'Completion', kind = 'switch',
      needs = 'Completion.KillPhotos',
      label = L('settings.keep_kill_photos_for_the_placer'),
      about = L('settings.the_placer_who_placed_the_contract'),
      inflight = L('settings.photos_already_kept_stay_openable_kills') },

    { key = 'Kidnap.RequireConscious', section = 'features', group = 'Handovers', kind = 'switch',
      category = 'features',
      label = L('settings.target_must_be_conscious'), about = L('settings.not_dead_not_downed_above_the'),
      inflight = AT_USE .. L('settings.a_contract_placed_under_alive_always') },
    { key = 'Kidnap.RejectDead', section = 'features', category = 'features', group = 'Handovers', kind = 'switch',
      label = L('settings.refuse_a_dead_target'), about = L('settings.a_body_is_never_handed_over'),
      inflight = AT_USE .. L('settings.a_contract_placed_under_alive_always') },
    { key = 'Kidnap.RejectLastStand', section = 'features', category = 'features', group = 'Handovers', kind = 'switch',
      label = L('settings.refuse_a_downed_target'), about = L('settings.a_target_in_last_stand_cannot'),
      inflight = AT_USE },
    { key = 'Kidnap.RequireCoercion', section = 'features', category = 'features', group = 'Handovers', kind = 'switch',
      label = L('settings.target_must_be_restrained'),
      about = L('settings.off_as_shipped_the_target_only'),
      inflight = AT_USE .. L('settings.a_countdown_already_running_is_checked') },
    { key = 'Kidnap.Coercion.handcuffed', section = 'features', group = 'Handovers', kind = 'switch',
      category = 'features',
      label = L('settings.handcuffs_count_as_restraint'), about = 'QBox \'ishandcuffed\' metadata. ' .. ONE_RESTRAINT,
      needs = 'Kidnap.RequireCoercion', inflight = AT_USE },
    { key = 'Kidnap.Coercion.passengerOfHitman', section = 'features', category = 'features', group = 'Handovers',
      kind = 'switch', label = L('settings.the_hitmans_vehicle_counts_as_restraint'),
      about = L('settings.the_target_riding_in_the_hitmans') .. ONE_RESTRAINT,
      needs = 'Kidnap.RequireCoercion', inflight = AT_USE },
    { key = 'Kidnap.MeetingPoint', section = 'features', category = 'features', group = 'Handovers', kind = 'switch',
      label = L('settings.meeting_point_for_the_handover'),
      about = L('settings.on_an_alive_only_contract_a'),
      inflight = L('settings.read_at_every_use_with_no_2') },
    { key = 'Kidnap.PlacerConfirms', section = 'features', category = 'features', group = 'Handovers',
      kind = 'switch', label = L('settings.the_placer_confirms_the_handover'),
      about = L('settings.once_a_handover_has_been_held'),
      inflight = L('settings.a_handover_keeps_the_rule_it') },
    { key = 'Kidnap.ConfirmSeconds', section = 'limits', category = 'rules-timers', group = 'Handovers',
      kind = 'number', integer = true, min = 10, max = 600, needs = 'Kidnap.PlacerConfirms',
      label = L('settings.time_the_placer_has_to_confirm'),
      about = L('settings.from_the_end_of_the_countdown'),
      inflight = L('settings.a_window_already_open_keeps_its') },
    { key = 'Kidnap.ConfirmMissed', section = 'limits', category = 'rules-timers', group = 'Handovers',
      kind = 'choice', choices = { 'rearm', 'pay' }, needs = 'Kidnap.PlacerConfirms',
      label = L('settings.when_the_placer_does_not_answer'),
      about = L('settings.rearm_nothing_is_paid_and_the'),
      inflight = AT_USE },
    { key = 'Kidnap.MaxDeclines', section = 'limits', category = 'rules-limits', group = 'Handovers',
      kind = 'number', integer = true, min = 0, max = 20, needs = 'Kidnap.PlacerConfirms',
      label = L('settings.declines_a_contracts_placer_gets_0'),
      about = L('settings.declines_and_windows_left_to_run'),
      inflight = AT_USE },

    { key = 'Penalty.RequireDisclosureOnAccept', section = 'features', category = 'features', group = 'Stakes',
      kind = 'switch', label = L('settings.accept_must_echo_the_stake_shown'),
      about = L('settings.a_page_showing_a_stale_stake'),
      inflight = AT_USE },

    { key = 'Bailout.Enabled', section = 'features', category = 'features', group = 'Buyouts', kind = 'switch',
      label = L('settings.buyouts'),
      about = L('settings.a_target_may_pay_to_close'),
      inflight = L('settings.a_buyout_already_paid_still_closes') },
    { key = 'Bailout.BlockWhileIncapacitated', section = 'features', category = 'features', group = 'Buyouts',
      kind = 'switch', label = L('settings.no_buyout_from_the_floor'),
      about = L('settings.a_dead_or_downed_target_cannot'), inflight = AT_USE },

    { key = 'Targeting.AllowBrowseAll', section = 'features', group = 'Targeting', kind = 'switch',
      category = 'features',
      label = L('settings.browse_everyone_online'), about = L('settings.pick_a_target_from_a_list'),
      inflight = L('settings.placed_contracts_are_untouched_the_list') },
    { key = 'Targeting.AllowNearby', section = 'features', category = 'features', group = 'Targeting', kind = 'switch',
      label = L('settings.list_the_people_nearby'), client = true,
      about = L('settings.names_unmasked_players_within_the_nearby'),
      inflight = L('settings.the_list_is_empty_while_it') },
    { key = 'Targeting.AllowProtectedJobTargets', section = 'features', category = 'features', group = 'Targeting',
      kind = 'switch', label = L('settings.law_enforcement_may_be_targeted'),
      about = L('settings.off_refuses_new_contracts_on_protected'),
      inflight = L('settings.contracts_already_on_protected_targets_run') },
    { key = 'Mugshot.Enabled', section = 'features', category = 'features', group = 'Targeting', kind = 'switch',
      label = L('settings.target_headshots'), client = true,
      about = L('settings.faces_on_the_board_rendered_by'),
      inflight = L('settings.read_at_the_next_card_drawn') },
    { key = 'Mugshot.RemoveBackground', section = 'features', group = 'Targeting', kind = 'switch',
      category = 'features',
      needs = 'Mugshot.Enabled',
      label = L('settings.cut_the_background_out_of_headshots'), client = true,
      about = L('settings.loads_a_segmentation_model_into_the'),
      inflight = L('settings.headshots_already_cached_keep_the_background') },

    { key = 'Advisory.Enabled', section = 'features', category = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = L('settings.advisories'), about = L('settings.law_enforcement_is_told_about_contracts'),
      inflight = L('settings.bulletins_already_sent_stand_none_is') },
    { key = 'Advisory.UseDispatch', section = 'features', category = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = L('settings.through_sc_dispatch'), about = L('settings.raise_a_dispatch_entry_as_well'),
      inflight = AT_USE },
    { key = 'Advisory.AlwaysAlertTarget', section = 'features', group = 'Law enforcement advisory',
      category = 'features',
      kind = 'switch', label = L('settings.always_tell_the_officer'), about = L('settings.the_targeted_officer_is_told'),
      inflight = AT_USE },
    { key = 'Advisory.OnCreate', section = 'features', category = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = L('settings.when_posted'), about = L('settings.a_bulletin_when_the_contract_is'),
      inflight = AT_USE },
    { key = 'Advisory.OnAccept', section = 'features', category = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = L('settings.when_accepted'), about = L('settings.a_bulletin_when_an_operative_accepts'),
      inflight = AT_USE },
    { key = 'Advisory.OnLocationTip', section = 'features', category = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = L('settings.when_a_tip_is_bought'),
      about = L('settings.a_bulletin_when_a_hitman_buys'), inflight = AT_USE },
    { key = 'Advisory.OnCancel', section = 'features', category = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = L('settings.when_called_off'),
      about = L('settings.a_bulletin_when_a_contract_on'),
      inflight = AT_USE },
    { key = 'Advisory.WarnCreator', section = 'features', category = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = L('settings.warn_the_placer'), about = L('settings.before_escrow_is_taken'), inflight = AT_USE },
    { key = 'Advisory.WarnHitman', section = 'features', category = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = L('settings.warn_the_hitman'), about = L('settings.before_they_accept'), inflight = AT_USE },
    { key = 'Advisory.FlagListing', section = 'features', category = 'features', group = 'Law enforcement advisory',
      kind = 'switch', label = L('settings.flag_the_listing'), about = L('settings.the_board_marks_an_officer_target'),
      inflight = AT_USE },

    { key = 'Relay.Enabled', section = 'features', category = 'features', group = 'Messages and calls', kind = 'switch',
      label = L('settings.messages'), about = L('settings.the_masked_relay_between_the_parties'),
      inflight = L('settings.threads_are_kept_and_come_back') },
    { key = 'Relay.AllowMaskedCalls', section = 'features', category = 'features', group = 'Messages and calls',
      kind = 'switch', label = L('settings.calls'), about = L('settings.calls_between_the_parties_through_lb'),
      inflight = L('settings.a_call_already_ringing_is_left') },
    { key = 'Relay.RequireMaskingForAnonymous', section = 'features', group = 'Messages and calls',
      category = 'features',
      kind = 'switch', label = L('settings.never_unmask_a_caller'),
      about = L('settings.no_call_to_or_from_an'),
      inflight = AT_USE },

    { key = 'TargetClasses.default.AllowAnonymousPlacer', section = 'features', category = 'features', group = 'Anonymity',
      kind = 'switch', label = L('settings.placing_anonymously'),
      about = L('settings.a_contract_may_be_placed_anonymously'),
      inflight = L('settings.read_at_every_placing_with_no') },
    { key = 'TargetClasses.default.AllowAnonymousHitman', section = 'features', category = 'features', group = 'Anonymity',
      kind = 'switch', label = L('settings.accepting_anonymously'),
      about = L('settings.a_contract_may_be_accepted_anonymously'),
      inflight = L('settings.read_at_every_acceptance_with_no') },
    { key = 'TargetClasses.default.ShowOperativeNames', section = 'features', category = 'features', group = 'Anonymity',
      kind = 'switch', label = L('settings.operative_names_shown_to_the_target'),
      about = L('settings.an_operative_who_accepted_under_their'),
      inflight = L('settings.read_at_every_view_with_no') },
    { key = 'TargetClasses.default.ShowPlacerOnBoard', section = 'features', category = 'features', group = 'Anonymity',
      kind = 'switch', label = L('settings.placer_names_shown_on_the_board'),
      about = L('settings.a_placer_who_put_their_name'),
      inflight = L('settings.read_at_every_view_with_no_2') },

    -- The same four for the other target class (Config.TargetClasses), on a
    -- contract whose target is on a whitelisted job (as the contract records
    -- it, like the advisory).
    { key = 'TargetClasses.whitelisted.AllowAnonymousPlacer', section = 'features', category = 'features',
      group = 'Anonymity (whitelisted-job targets)', kind = 'switch',
      label = L('settings.placing_anonymously'),
      about = L('settings.a_contract_on_a_member_of'),
      inflight = L('settings.read_at_every_placing_with_no_2') },
    { key = 'TargetClasses.whitelisted.AllowAnonymousHitman', section = 'features', category = 'features',
      group = 'Anonymity (whitelisted-job targets)', kind = 'switch',
      label = L('settings.accepting_anonymously'),
      about = L('settings.a_contract_on_a_member_of_2'),
      inflight = L('settings.read_at_every_acceptance_with_no_2') },
    { key = 'TargetClasses.whitelisted.ShowOperativeNames', section = 'features', category = 'features',
      group = 'Anonymity (whitelisted-job targets)', kind = 'switch',
      label = L('settings.operative_names_shown_to_the_target'),
      about = L('settings.a_member_of_a_whitelisted_job'),
      inflight = L('settings.read_at_every_view_with_no') },
    { key = 'TargetClasses.whitelisted.ShowPlacerOnBoard', section = 'features', category = 'features',
      group = 'Anonymity (whitelisted-job targets)', kind = 'switch',
      label = L('settings.placer_names_shown_on_the_board'),
      about = L('settings.a_placer_who_put_their_name_2'),
      inflight = L('settings.read_at_every_view_with_no_2') },

    { key = 'Amendments.Enabled', section = 'features', category = 'features', group = 'Proposals', kind = 'switch',
      label = L('settings.proposals'), about = L('settings.changes_to_a_contract_that_need'),
      inflight = L('settings.proposals_already_open_can_still_be') },

    { key = 'Intel.Enabled', section = 'features', category = 'features', group = 'Intel: Informants', kind = 'switch',
      label = L('settings.every_informant_feature'),
      about = L('settings.the_master_switch_over_the_targets'),
      inflight = L('settings.names_already_found_stay_shown_and') },
    { key = 'Intel.Informant.Enabled', section = 'features', category = 'features', group = 'Intel: Informants', kind = 'switch',
      needs = 'Intel.Enabled',
      label = L('settings.targets_informant'),
      about = L('settings.a_target_may_pay_for_a'),
      inflight = L('settings.names_already_found_stay_shown_new') },
    { key = 'Intel.PlacerInformant.Enabled', section = 'features', group = 'Intel: Informants', kind = 'switch',
      category = 'features',
      needs = 'Intel.Enabled',
      label = L('settings.placers_informant'),
      about = L('settings.the_person_who_placed_a_contract'),
      inflight = L('settings.names_already_found_stay_shown_new') },

    { key = 'Intel.LocationTip.Enabled', section = 'features', group = 'Intel: Informant tip', kind = 'switch',
      category = 'features',
      needs = 'Intel.Enabled',
      label = L('settings.intel_informant_tip'),
      about = L('settings.a_hitman_on_a_contract_may'),
      inflight = L('settings.a_tip_already_bought_stays_on') },
    { key = 'Intel.LocationTip.NotifyTarget', section = 'features', category = 'features', group = 'Intel: Informant tip',
      kind = 'switch', label = L('settings.tell_the_target'),
      about = L('settings.the_target_is_told_someone_knows'),
      inflight = L('settings.read_when_a_tip_is_bought') },

    -- Whom each of the three above is sold to, by the target's class
    -- (Config.TargetClasses): every other target, and a target on a
    -- whitelisted job (the flag the contract recorded, as the advisory reads
    -- it). The master switch and the feature's own still turn each off.
    { key = 'TargetClasses.default.Informant', section = 'features', category = 'features',
      group = 'Intel: Every other target', kind = 'switch',
      needs = 'Intel.Informant.Enabled', label = L('settings.targets_informant'),
      about = L('settings.a_target_not_on_a_whitelisted'),
      inflight = L('settings.names_already_found_stay_shown_new') },
    { key = 'TargetClasses.default.PlacerInformant', section = 'features', category = 'features',
      group = 'Intel: Every other target', kind = 'switch',
      needs = 'Intel.PlacerInformant.Enabled', label = L('settings.placers_informant'),
      about = L('settings.the_person_who_placed_a_contract_2'),
      inflight = L('settings.names_already_found_stay_shown_new') },
    { key = 'TargetClasses.default.LocationTip', section = 'features', category = 'features',
      group = 'Intel: Every other target', kind = 'switch',
      needs = 'Intel.LocationTip.Enabled', label = L('settings.intel_informant_tip'),
      about = L('settings.a_hitman_on_a_contract_on'),
      inflight = L('settings.a_tip_already_bought_stays_on') },
    { key = 'TargetClasses.whitelisted.Informant', section = 'features', category = 'features',
      group = 'Intel: Whitelisted-job targets', kind = 'switch',
      needs = 'Intel.Informant.Enabled', label = L('settings.targets_informant'),
      about = L('settings.a_target_on_a_whitelisted_job'),
      inflight = L('settings.names_already_found_stay_shown_new') },
    { key = 'TargetClasses.whitelisted.PlacerInformant', section = 'features', category = 'features',
      group = 'Intel: Whitelisted-job targets', kind = 'switch',
      needs = 'Intel.PlacerInformant.Enabled', label = L('settings.placers_informant'),
      about = L('settings.the_person_who_placed_a_contract_3'),
      inflight = L('settings.names_already_found_stay_shown_new') },
    { key = 'TargetClasses.whitelisted.LocationTip', section = 'features', category = 'features',
      group = 'Intel: Whitelisted-job targets', kind = 'switch',
      needs = 'Intel.LocationTip.Enabled', label = L('settings.intel_informant_tip'),
      about = L('settings.a_hitman_on_a_contract_on_2'),
      inflight = L('settings.a_tip_already_bought_stays_on') },

    { key = 'Notifications.ParanoidAlert', section = 'features', category = 'features', group = 'Notifications',
      kind = 'switch', label = L('settings.tell_the_target'), about = L('settings.the_targets_phone_says_a_price'),
      inflight = L('settings.alerts_already_sent_stand_alerts_still') },
    { key = 'Notifications.PushEnabled', section = 'features', category = 'features', group = 'Notifications',
      kind = 'switch', label = L('settings.refresh_open_apps'), about = L('settings.nudge_an_open_app_when_its'),
      inflight = AT_USE },

    { key = 'Limits.PauseWhileTargetJailed', section = 'features', category = 'features', group = 'The clock',
      kind = 'switch', label = L('settings.pause_while_the_target_is_jailed'),
      about = L('settings.a_target_serving_time_stops_the'),
      inflight = L('settings.checked_by_the_next_expiry_pass') },

    { key = 'AntiCollusion.BlockSameAccount', section = 'features', category = 'features', group = 'Anti-collusion',
      kind = 'switch', label = L('settings.refuse_your_own_account'),
      about = L('settings.no_contract_between_characters_of_one'),
      inflight = L('settings.contracts_already_placed_run_on_new') },

    { key = 'Audit.LogAllActions', section = 'features', group = 'Audit and debug', kind = 'switch',
      category = 'features',
      label = L('settings.log_player_conduct'), about = L('settings.every_creation_acceptance_and_refusal_not'),
      inflight = L('settings.money_staff_actions_and_refusals_are') },
    { key = 'Audit.LogReasonText', section = 'features', group = 'Audit and debug', kind = 'switch',
      category = 'features',
      label = L('settings.log_contract_reasons'), about = L('settings.the_reason_text_goes_into_the'), inflight = AT_USE },
    { key = 'Alerts.ToDiscord', section = 'features', category = 'features', group = 'Audit and debug', kind = 'switch',
      label = L('settings.post_alerts_to_discord'),
      about = L('settings.every_alert_in_the_alerts_section'),
      inflight = L('settings.read_at_the_next_post_with') },
    { key = 'Holds.AppPaused', section = 'features', category = 'features', group = 'Staff tools',
      kind = 'switch', label = L('settings.pause_the_whole_app'),
      about = L('settings.for_an_event_no_contract_is'),
      inflight = L('settings.at_once_with_no_restart_and') },
    { key = 'Staff.DailySummary', section = 'features', category = 'features', group = 'Staff tools',
      kind = 'switch', label = L('settings.daily_summary_to_discord'),
      about = L('settings.once_a_day_at_the_hour'),
      inflight = L('settings.read_at_the_hour_at_most') },
    { key = 'VersionCheck.Enabled', section = 'features', category = 'developer', group = 'Audit and debug',
      kind = 'switch', label = L('settings.check_for_a_newer_version_at'),
      about = L('settings.off_as_shipped_on_with_an'),
      inflight = L('settings.asked_once_as_the_server_starts') },
    { key = 'Debug', section = 'features', category = 'developer', group = 'Audit and debug', kind = 'switch',
      label = L('settings.debug_output_in_the_server_console'),
      about = L('settings.off_the_server_console_prints_only'),
      inflight = L('settings.read_at_every_line_printed_with') },


    -- Read only, with the reason -----------------------------------------
    { key = 'Admin.Enabled', section = 'readonly', category = 'developer', group = 'Staff', kind = 'switch',
      label = L('settings.staff_tools'),
      readonly = L('settings.turning_the_staff_tools_off_from') },
    { key = 'Admin.Ace', section = 'readonly', category = 'developer', group = 'Staff', kind = 'text',
      label = L('settings.staff_ace'), readonly = L('settings.who_may_use_this_panel_set') },
    { key = 'Admin.IdentityAce', section = 'readonly', category = 'developer', group = 'Staff', kind = 'text',
      label = L('settings.identity_ace'), readonly = L('settings.who_may_unmask_anonymous_parties_set') },
    { key = 'Database.Mode', section = 'readonly', category = 'developer', group = 'Storage', kind = 'text',
      label = L('settings.storage_mode'), readonly = L('settings.changing_it_needs_the_money_in') },
    { key = 'Database.AllowModeSwitch', section = 'readonly', group = 'Storage', kind = 'switch',
      category = 'developer',
      label = L('settings.start_over_money_in_another_mode'),
      readonly = L('settings.read_once_at_start_and_only') },
    { key = 'Database.Json.SyncOnFinancialWrite', section = 'readonly', category = 'developer', group = 'Storage',
      kind = 'switch', label = L('settings.write_money_to_disk_as_it'),
      readonly = L('settings.off_a_crash_could_lose_money') },
    { key = 'Database.QueryTimeoutSeconds', section = 'readonly', category = 'developer', group = 'Storage',
      kind = 'number', label = L('settings.database_answer_limit'),
      readonly = L('settings.mysql_only_set_it_in_config') },
    -- Shown, not switched: turned off it changed nothing. A target only in
    -- last stand never reads as dead to the server, the sampler or the
    -- photo checks, whatever it says; it only removes one a death provider
    -- reports as dead and in last stand at once.
    { key = 'Completion.RejectLastStand', section = 'readonly', category = 'developer', group = 'Completion',
      kind = 'switch', label = L('settings.a_downed_target_is_not_a'),
      readonly = L('settings.only_matters_for_a_death_provider') },

    -- Limits and settings -------------------------------------------------
    { key = 'Limits.MaxActiveContractsPerCreator', section = 'limits', group = 'Contract limits',
      category = 'rules-limits',
      kind = 'number', integer = true, min = 1, max = 50, label = L('settings.contracts_a_client_may_have_out'),
      inflight = CAP },
    { key = 'Limits.MaxAcceptedPerHitman', section = 'limits', category = 'rules-limits', group = 'Contract limits',
      kind = 'number', integer = true, min = 1, max = 50, label = L('settings.contracts_a_hitman_may_hold'),
      inflight = CAP },
    -- Target limits (the panel's own section, server/targetlimits.lua): how
    -- often one person may have a contract placed on them. A job's or a
    -- player's override is set there too, over these.
    { key = 'Limits.MaxActiveContractsPerTarget', section = 'limits', group = 'Target limits',
      category = 'target-limits',
      kind = 'number', integer = true, min = 1, max = 50, label = L('settings.live_contracts_on_one_person_at'),
      inflight = CAP },
    { key = 'Limits.MaxContractsPerTargetPerDay', section = 'limits', group = 'Target limits',
      category = 'target-limits',
      kind = 'number', integer = true, min = 0, max = 100,
      label = L('settings.contracts_placed_on_one_person_in'),
      about = L('settings.every_contract_placed_on_them_counts'),
      inflight = CAP },
    { key = 'Limits.MaxContractsPerTargetPerWeek', section = 'limits', group = 'Target limits',
      category = 'target-limits',
      kind = 'number', integer = true, min = 0, max = 500,
      label = L('settings.contracts_placed_on_one_person_in_2'),
      about = L('settings.every_contract_placed_on_them_counts'),
      inflight = CAP },
    -- Never above the most a contract may be worth (Config.MaxContractValue,
    -- config.lua's only): offered up to 100,000,000, anything over that was
    -- refused, in words that said the start would use the ceiling instead.
    { key = 'Limits.MinContractReward', section = 'limits', category = 'rules-rewards', group = 'Contract limits',
      kind = 'number', integer = true, min = 0, max = 100000000, ceiling = 'MaxContractValue',
      label = L('settings.least_a_reward_may_be_worth'), inflight = CAP },
    { key = 'Limits.MaxHitmenPerContract', section = 'limits', category = 'rules-limits', group = 'Contract limits',
      kind = 'number', integer = true, min = 1, max = 50, label = L('settings.operatives_on_one_contract'),
      inflight = CAP },
    { key = 'Limits.MaxPayoutSlots', section = 'limits', category = 'rules-rewards', group = 'Contract limits',
      kind = 'number', integer = true, min = 1, max = 3,
      label = L('settings.times_one_contract_can_be_collected'),
      inflight = L('settings.new_contracts_only_each_contract_keeps') },
    { key = 'Limits.MaxEscrowLines', section = 'limits', category = 'rules-rewards', group = 'Contract limits',
      kind = 'number', integer = true, min = 1, max = 500, label = L('settings.escrow_lines_in_one_contract'),
      inflight = CAP },
    { key = 'Limits.MaxDeadlineSkipSeconds', section = 'limits', category = 'developer', group = 'Contract limits',
      kind = 'number', integer = true, min = 10, max = 3600,
      label = L('settings.longest_the_expiry_pass_sleeps'), inflight = AT_USE },
    { key = 'Limits.SlotCooldownSeconds', section = 'limits', category = 'rules-rewards', group = 'Contract limits',
      kind = 'number', integer = true, min = 0, max = 86400,
      label = L('settings.wait_between_one_hitmans_payouts'), inflight = AT_USE },
    { key = 'Limits.TargetCooldownAfterResolveSeconds', section = 'limits', group = 'Target limits',
      category = 'target-limits',
      kind = 'number', integer = true, min = 0, max = 604800,
      label = L('settings.wait_after_a_contract_on_a'),
      inflight = AT_USE },
    { key = 'Limits.SameCreatorSameTargetCooldownSeconds', section = 'limits', category = 'target-limits',
      group = 'Target limits', kind = 'number', integer = true, min = 0, max = 604800,
      label = L('settings.wait_before_the_same_placer_names'), inflight = AT_USE },
    { key = 'Limits.ContractLifetimeSeconds', section = 'limits', category = 'rules-timers', group = 'Contract limits',
      kind = 'number', integer = true, min = 600, max = 2592000,
      label = L('settings.longest_a_contract_may_run'),
      inflight = L('settings.new_contracts_only_each_contract_keeps_2') },
    { key = 'Limits.DefaultDeadlineSeconds', section = 'limits', category = 'rules-timers', group = 'Contract limits',
      kind = 'number', integer = true, min = 300, max = 2592000,
      label = L('settings.deadline_a_new_contract_gets'),
      inflight = L('settings.new_contracts_only_each_contract_keeps_3') },
    { key = 'Limits.StaffDeadlineMaxAdjustSeconds', section = 'limits', category = 'rules-timers',
      group = 'Contract limits', kind = 'number', integer = true, min = 60, max = 2592000,
      label = L('settings.most_staff_may_extend_or_shorten'), inflight = AT_USE },
    { key = 'Limits.StaffDeadlineMinLeftSeconds', section = 'limits', category = 'rules-timers',
      group = 'Contract limits', kind = 'number', integer = true, min = 0, max = 86400,
      label = L('settings.least_time_a_staff_shortening_leaves'), inflight = AT_USE },
    -- Config.Staff (Staff and permissions in config.lua): the most one
    -- manual payment from Players may be. Shown with the limits.
    { key = 'Staff.ManualPaymentMax', section = 'limits', category = 'rules-limits', group = 'Staff',
      kind = 'number', integer = true, min = 0, max = 100000000,
      label = L('settings.most_one_manual_staff_payment_may'),
      about = L('settings.players_pay_cash_or_bank_paid'),
      inflight = AT_USE },
    { key = 'Staff.RewardChangeMax', section = 'limits', category = 'rules-limits', group = 'Staff',
      kind = 'number', integer = true, min = 0, max = 100000000,
      label = L('settings.most_staff_may_change_a_reward'),
      about = L('settings.a_contracts_change_reward_raised_added'),
      inflight = AT_USE },
    { key = 'Staff.ReassignStake', section = 'limits', category = 'rules-limits', group = 'Staff',
      kind = 'choice', choices = { 'waive', 'charge' },
      label = L('settings.stake_of_a_hitman_staff_assign'),
      about = L('settings.a_contracts_reassign_waive_puts_no'),
      inflight = AT_USE },
    { key = 'Limits.ExclusiveIdleReleaseSeconds', section = 'limits', group = 'Contract limits',
      category = 'rules-timers',
      kind = 'number', integer = true, min = 0, max = 604800,
      label = L('settings.release_an_idle_exclusive_hold_after'), inflight = AT_USE },
    { key = 'Limits.ExclusiveAttemptWindowSeconds', section = 'limits', group = 'Contract limits',
      category = 'rules-timers',
      kind = 'number', integer = true, min = 0, max = 604800,
      label = L('settings.release_a_hold_with_no_attempt'), inflight = AT_USE },
    { key = 'Limits.JailZone.radius', place = 'jail',
      section = 'limits', category = 'rules-limits', group = 'Contract limits',
      kind = 'number', min = 10, max = 5000, label = L('settings.prison_grounds_radius_m'), inflight = AT_USE },

    { key = 'Penalty.MaxAmount', section = 'limits', category = 'rules-rewards', group = 'Stakes', kind = 'number',
      integer = true, min = 0, max = 100000000, label = L('settings.largest_stake'),
      inflight = L('settings.new_contracts_only_a_stake_is') },
    { key = 'Penalty.MaxFractionOfEscrow', section = 'limits', group = 'Stakes', kind = 'number',
      category = 'rules-rewards',
      min = 0, max = 10, label = L('settings.largest_stake_as_a_share_of'),
      inflight = L('settings.new_contracts_only_a_stake_is') },
    { key = 'Penalty.MinWindowMinutes', section = 'limits', group = 'Stakes', kind = 'number',
      category = 'rules-timers',
      integer = true, min = 0, max = 1440, label = L('settings.least_time_left_to_stake_on'),
      inflight = AT_USE },

    { key = 'Anonymity.CreatorFee', section = 'limits', category = 'rules-rewards', group = 'Anonymity',
      kind = 'number',
      integer = true, min = 0, max = 10000000, label = L('settings.fee_to_place_anonymously'),
      inflight = L('settings.charged_when_a_contract_is_placed') },
    { key = 'Anonymity.HitmanFee', section = 'limits', category = 'rules-rewards', group = 'Anonymity', kind = 'number',
      integer = true, min = 0, max = 10000000, label = L('settings.fee_to_accept_anonymously'),
      inflight = L('settings.charged_when_a_contract_is_accepted') },
    { key = 'Anonymity.FeeAccount', section = 'limits', category = 'rules-rewards', group = 'Anonymity',
      kind = 'choice',
      choices = { 'bank', 'cash' }, label = L('settings.account_the_fees_are_charged_to'),
      inflight = L('settings.a_fee_refunded_goes_back_to') },

    { key = 'Intel.Informant.Cost', section = 'limits', category = 'rules-rewards', group = 'Intel: Informants', kind = 'number',
      integer = true, min = 0, max = 10000000, label = L('settings.targets_look_up_price'),
      inflight = AT_USE },
    { key = 'Intel.Informant.RevealChancePercent', section = 'limits', category = 'rules-limits', group = 'Intel: Informants',
      kind = 'number', integer = true, min = 0, max = 100,
      label = L('settings.targets_chance_a_look_up_finds'), inflight = AT_USE },
    { key = 'Intel.PlacerInformant.Cost', section = 'limits', category = 'rules-rewards', group = 'Intel: Informants',
      kind = 'number',
      integer = true, min = 0, max = 10000000, label = L('settings.placers_look_up_price'),
      inflight = AT_USE },
    { key = 'Intel.PlacerInformant.RevealChancePercent', section = 'limits', category = 'rules-limits', group = 'Intel: Informants',
      kind = 'number', integer = true, min = 0, max = 100,
      label = L('settings.placers_chance_a_look_up_finds'), inflight = AT_USE },
    { key = 'Intel.PlacerInformant.AlertChancePercent', section = 'limits', category = 'rules-limits', group = 'Intel: Informants',
      kind = 'number', integer = true, min = 0, max = 100,
      label = L('settings.chance_the_operative_found_out_is'), inflight = AT_USE },
    { key = 'Intel.PlacerInformant.MaxPurchasesPerContract', section = 'limits', group = 'Intel: Informants',
      category = 'rules-limits',
      kind = 'number', integer = true, min = 0, max = 20,
      label = L('settings.placers_look_ups_per_contract'),
      inflight = L('settings.look_ups_already_made_count_against') },
    { key = 'Intel.PlacerInformant.CooldownMinutes', section = 'limits', category = 'rules-timers', group = 'Intel: Informants',
      kind = 'number', integer = true, min = 0, max = 1440,
      label = L('settings.placers_wait_between_look_ups_min'), inflight = AT_USE },

    { key = 'Intel.LocationTip.Cost', section = 'limits', category = 'rules-rewards', group = 'Intel: Informant tip',
      kind = 'number',
      integer = true, min = 0, max = 10000000, label = L('settings.price_of_a_tip'), inflight = AT_USE },
    { key = 'Intel.LocationTip.RadiusMeters', section = 'limits', category = 'rules-limits', group = 'Intel: Informant tip',
      kind = 'number', integer = true, min = 100, max = 2000,
      label = L('settings.radius_of_the_area_m_shown'),
      inflight = L('settings.tips_already_bought_keep_the_area') },
    { key = 'Intel.LocationTip.ShowMinutes', section = 'limits', category = 'rules-timers', group = 'Intel: Informant tip',
      kind = 'number', integer = true, min = 1, max = 120, label = L('settings.minutes_a_tip_is_shown'),
      inflight = L('settings.tips_already_bought_keep_the_time') },
    { key = 'Intel.LocationTip.CooldownMinutes', section = 'limits', category = 'rules-timers', group = 'Intel: Informant tip',
      kind = 'number', integer = true, min = 0, max = 1440,
      label = L('settings.minutes_between_two_tips_on_a'), inflight = AT_USE },
    { key = 'Intel.LocationTip.MaxPurchasesPerContract', section = 'limits', group = 'Intel: Informant tip',
      category = 'rules-limits',
      kind = 'number', integer = true, min = 1, max = 50,
      label = L('settings.tips_per_contract_all_its_hitmen'), inflight = AT_USE },

    { key = 'Holds.RestartPauseBeforeSeconds', section = 'limits', category = 'rules-timers', group = 'Server restart',
      kind = 'number', integer = true, min = 0, max = 3600,
      label = L('settings.pause_contracts_this_long_before_a'),
      inflight = L('settings.a_pause_already_on_stays_until') },
    { key = 'Holds.RestartMaxHoldMinutes', section = 'limits', category = 'rules-timers', group = 'Server restart',
      kind = 'number', integer = true, min = 1, max = 240,
      label = L('settings.longest_the_pause_lasts_with_no'),
      inflight = L('settings.a_pause_already_on_ends_at') },

    { key = 'Staff.DailySummaryHour', section = 'limits', category = 'rules-timers', group = 'Staff tools',
      kind = 'number', integer = true, min = 0, max = 23,
      label = L('settings.hour_the_daily_summary_is_posted'),
      inflight = L('settings.read_every_tick_a_summary_already') },
    { key = 'Staff.AlertPlacedPerHour', section = 'limits', category = 'rules-limits', group = 'Staff alerts',
      kind = 'number', integer = true, min = 0, max = 1000,
      label = L('settings.alert_past_this_many_contracts_placed'),
      inflight = AT_USE },
    { key = 'Staff.AlertTargetPerDay', section = 'limits', category = 'rules-limits', group = 'Staff alerts',
      kind = 'number', integer = true, min = 0, max = 1000,
      label = L('settings.alert_past_this_many_contracts_on'),
      inflight = AT_USE },
    { key = 'Staff.AlertRefusalsPer10Min', section = 'limits', category = 'rules-limits', group = 'Staff alerts',
      kind = 'number', integer = true, min = 0, max = 10000,
      label = L('settings.alert_past_this_many_refusals_to'),
      inflight = AT_USE },

    { key = 'Kidnap.CountdownSeconds', section = 'limits', group = 'Handovers', kind = 'number',
      category = 'rules-timers',
      integer = true, min = 5, max = 600, label = L('settings.handover_countdown'), inflight = AT_USE
          .. L('settings.a_countdown_already_running_finishes_at') },
    { key = 'Kidnap.Radius', section = 'limits', category = 'rules-limits', group = 'Handovers', kind = 'number',
      min = 2, max = 100, label = L('settings.handover_radius_m'),
      inflight = L('settings.a_countdown_already_running_keeps_the') },
    { key = 'Kidnap.MinTargetHealthPercent', section = 'limits', category = 'rules-limits', group = 'Handovers',
      kind = 'number', integer = true, min = 0, max = 100,
      label = L('settings.least_health_to_hand_a_target'), inflight = AT_USE },

    { key = 'Bailout.MinMultiplier', section = 'limits', group = 'Buyout pricing', kind = 'number',
      category = 'rules-rewards',
      min = 0, max = 20, label = L('settings.least_buyout_times_the_reward'),
      inflight = L('settings.new_contracts_only_a_buyout_price') },
    { key = 'Bailout.MaxMultiplier', section = 'limits', group = 'Buyout pricing', kind = 'number',
      category = 'rules-rewards',
      min = 0, max = 20, label = L('settings.most_buyout_times_the_reward'),
      inflight = L('settings.new_contracts_only_a_buyout_price_2') },
    { key = 'Bailout.AbsoluteMax', section = 'limits', group = 'Buyout pricing', kind = 'number',
      category = 'rules-rewards',
      integer = true, min = 0, max = 100000000, label = L('settings.most_buyout'),
      inflight = L('settings.new_contracts_only_a_buyout_price_3') },

    { key = 'Targeting.NearbyRadius', section = 'limits', group = 'Targeting', kind = 'number',
      category = 'rules-targeting',
      min = 5, max = 200, label = L('settings.nearby_list_radius_m'), inflight = AT_USE },
    { key = 'Targeting.MaxNearby', section = 'limits', group = 'Targeting', kind = 'number',
      category = 'rules-targeting',
      integer = true, min = 1, max = 50, label = L('settings.names_on_the_nearby_list'), inflight = AT_USE },
    { key = 'Targeting.NearbyClosedAfterSeconds', section = 'limits', category = 'rules-targeting', group = 'Targeting',
      kind = 'number', integer = true, min = 0, max = 86400,
      label = L('settings.nearby_list_closed_after_a_contract'), inflight = AT_USE },
    { key = 'Targeting.BrowsePageSize', section = 'limits', group = 'Targeting', kind = 'number',
      category = 'rules-targeting',
      integer = true, min = 5, max = 100, label = L('settings.names_per_page_when_browsing'), inflight = AT_USE },
    { key = 'Targeting.MinQueryLength', section = 'limits', group = 'Targeting', kind = 'number',
      category = 'rules-targeting',
      integer = true, min = 1, max = 10, label = L('settings.shortest_name_search'), inflight = AT_USE },
    { key = 'Targeting.MaxResults', section = 'limits', group = 'Targeting', kind = 'number',
      category = 'rules-targeting',
      integer = true, min = 1, max = 50, label = L('settings.results_of_a_name_search'), inflight = AT_USE },

    { key = 'Ledger.PhotoRetentionDays', section = 'limits', group = 'Ledger', kind = 'number',
      category = 'rules-timers',
      integer = true, min = 0, max = 365, label = L('settings.days_an_unopened_kill_photo_is'),
      inflight = L('settings.looked_at_every_ten_minutes_photos'),
      destroys = L('settings.lowered_to_every_unopened_kill_photo') },

    { key = 'Advisory.TriggerJobTypes', section = 'limits', category = 'rules-targeting', group = 'Advisory job lists',
      kind = 'list', label = L('settings.job_types_that_raise_an_advisory'), inflight = AT_USE },
    { key = 'Advisory.TriggerJobNames', section = 'limits', category = 'rules-targeting', group = 'Advisory job lists',
      kind = 'list', label = L('settings.job_names_that_raise_an_advisory'), inflight = AT_USE },
    { key = 'Advisory.RecipientJobTypes', section = 'limits', group = 'Advisory job lists',
      category = 'rules-targeting',
      kind = 'list', label = L('settings.job_types_that_receive_advisories'), inflight = AT_USE },
    { key = 'Advisory.RecipientJobNames', section = 'limits', group = 'Advisory job lists',
      category = 'rules-targeting',
      kind = 'list', label = L('settings.job_names_that_receive_advisories'), inflight = AT_USE },
    -- Every other setting in config.lua ------------------------------------
    -- Added so (close to) every setting is changed from the panel. Each is
    -- checked by the start-up checks like the rest (fits); a key that is
    -- read once at start says so (live = false) and is kept for the next one.
    { key = 'MaxContractValue', section = 'limits', category = 'rules-rewards', group = 'Rewards',
      kind = 'number', integer = true, min = 1, max = 100000000,
      label = L('settings.most_a_contract_may_hold'), about = L('settings.the_money_a_reward_its_bonus'), inflight = CAP },
    { key = 'Sources.cash.max', section = 'limits', category = 'rules-rewards', group = 'Rewards',
      kind = 'number', integer = true, min = 0, max = 100000000, label = L('settings.most_cash_in_a_reward'),
      about = L('settings.the_cash_one_reward_may_hold'), inflight = CAP },
    { key = 'Sources.bank.max', section = 'limits', category = 'rules-rewards', group = 'Rewards',
      kind = 'number', integer = true, min = 0, max = 100000000, label = L('settings.most_bank_money_in_a_reward'),
      about = L('settings.the_bank_money_one_reward_may'), inflight = CAP },
    { key = 'Sources.dirty.max', section = 'limits', category = 'rules-rewards', group = 'Rewards',
      kind = 'number', integer = true, min = 0, max = 100000000, label = L('settings.most_dirty_money_in_a_reward'),
      about = L('settings.the_dirty_money_one_reward_may'), inflight = CAP },
    { key = 'Sources.dirty.item', section = 'limits', category = 'rules-rewards', group = 'Rewards',
      kind = 'text', pattern = '^[%w_%-]+$', maxLength = 64, label = L('settings.dirty_money_item'),
      about = L('settings.the_ox_inventory_item_dirty_money'),
      inflight = L('settings.read_at_each_payment_lines_already') },
    { key = 'Sources.item.maxStacks', section = 'limits', category = 'rules-rewards', group = 'Rewards',
      kind = 'number', integer = true, min = 0, max = 100, label = L('settings.item_stacks_in_a_reward'),
      about = L('settings.how_many_stacks_of_items_one'), inflight = CAP },
    { key = 'Sources.item.maxPerStack', section = 'limits', category = 'rules-rewards', group = 'Rewards',
      kind = 'number', integer = true, min = 1, max = 100000, label = L('settings.items_in_one_stack'),
      about = L('settings.the_count_one_stack_of_a'), inflight = CAP },
    { key = 'Sources.weapon.max', section = 'limits', category = 'rules-rewards', group = 'Rewards',
      kind = 'number', integer = true, min = 0, max = 50, label = L('settings.weapons_in_a_reward'),
      about = L('settings.how_many_weapons_one_reward_may'), inflight = CAP },
    { key = 'Bonus.maxPercent', section = 'limits', category = 'rules-rewards', group = 'Rewards',
      kind = 'number', integer = true, min = 0, max = 1000, label = L('settings.most_a_kidnapping_bonus_adds'),
      about = L('settings.under_either_the_most_a_live'),
      inflight = L('settings.contracts_keep_the_bonus_they_were') },
    { key = 'EscrowBlacklist', section = 'limits', category = 'rules-rewards', group = 'Rewards',
      kind = 'list', names = 'item', label = L('settings.items_never_put_in_a_reward'),
      about = L('settings.ox_inventory_item_names_a_reward'),
      inflight = L('settings.items_already_in_escrow_are_paid') },
    { key = 'PendingEscrow.MaxRetriesPerLogin', section = 'limits', category = 'rules-rewards',
      group = 'Payouts', kind = 'number', integer = true, min = 1, max = 100,
      label = L('settings.owed_payouts_tried_at_each_login'),
      about = L('settings.how_many_payouts_owed_to_a'), inflight = AT_USE },
    { key = 'PendingEscrow.LoginRetryDelayMs', section = 'limits', category = 'rules-rewards',
      group = 'Payouts', kind = 'number', integer = true, min = 0, max = 600000,
      label = L('settings.wait_after_login_before_paying_ms'),
      about = L('settings.how_long_after_a_login_what'),
      inflight = AT_USE },
    { key = 'Bailout.ProcessingDelaySeconds', section = 'limits', category = 'rules-rewards',
      group = 'Buyouts', kind = 'number', integer = true, min = 0, max = 86400,
      label = L('settings.hitmans_head_start_on_a_buyout'),
      about = L('settings.a_held_contracts_hitman_gets_this'),
      inflight = L('settings.a_buyout_already_queued_keeps_the') },
    { key = 'Intel.Informant.Account', section = 'limits', category = 'rules-rewards', group = 'Intel prices',
      kind = 'choice', choices = { 'bank', 'cash' }, label = L('settings.account_the_targets_look_up_is'),
      about = L('settings.where_the_targets_informant_price_is'), inflight = AT_USE },
    { key = 'Intel.PlacerInformant.Account', section = 'limits', category = 'rules-rewards',
      group = 'Intel prices', kind = 'choice', choices = { 'bank', 'cash' },
      label = L('settings.account_the_placers_look_up_is'),
      about = L('settings.where_the_placers_informant_price_is'), inflight = AT_USE },
    { key = 'Intel.LocationTip.Account', section = 'limits', category = 'rules-rewards',
      group = 'Intel prices', kind = 'choice', choices = { 'bank', 'cash' },
      label = L('settings.account_a_tip_is_paid_from'), about = L('settings.where_the_price_of_an_informant'),
      inflight = AT_USE },

    { key = 'Completion.ProofWindowSeconds', section = 'limits', category = 'rules-timers',
      group = 'Completion', kind = 'number', integer = true, min = 0, max = 3600,
      label = L('settings.kill_verifies_this_long_after_death'),
      about = L('settings.a_kill_still_verifies_this_long'),
      inflight = AT_USE },
    { key = 'Completion.PhotoTokenLifetimeSeconds', section = 'limits', category = 'rules-timers',
      group = 'Completion', kind = 'number', integer = true, min = 10, max = 3600, client = true,
      label = L('settings.time_to_verify_a_kill'), about = L('settings.how_long_a_kill_waits_to'),
      inflight = L('settings.applies_to_the_next_kill_one') },
    { key = 'Completion.PhotoOpenSeconds', section = 'limits', category = 'rules-timers',
      group = 'Completion', kind = 'number', integer = true, min = 10, max = 86400,
      label = L('settings.time_the_placer_may_view_a'), about = L('settings.after_this_the_opened_photo_is'),
      inflight = AT_USE },
    { key = 'Kidnap.RearmCooldownSeconds', section = 'limits', category = 'rules-timers',
      group = 'Handovers', kind = 'number', integer = true, min = 0, max = 3600,
      label = L('settings.wait_after_a_failed_handover'), about = L('settings.before_a_handover_can_be_armed'),
      inflight = AT_USE },
    { key = 'Amendments.ProposalExpirySeconds', section = 'limits', category = 'rules-timers',
      group = 'Proposals', kind = 'number', integer = true, min = 30, max = 86400,
      label = L('settings.a_proposal_lapses_after'), about = L('settings.open_proposals_between_placer_and_hitman'),
      inflight = L('settings.proposals_already_open_keep_the_time') },
    { key = 'Amendments.CancelCooldownSeconds', section = 'limits', category = 'rules-timers',
      group = 'Proposals', kind = 'number', integer = true, min = 0, max = 86400,
      label = L('settings.wait_after_calling_a_contract_off'),
      about = L('settings.before_the_same_placer_may_place'), inflight = AT_USE },
    { key = 'Intel.Informant.RerollLockMinutes', section = 'limits', category = 'rules-timers',
      group = 'Intel: Informants', kind = 'number', integer = true, min = 0, max = 1440,
      label = L('settings.same_pick_repeats_its_answer_for'),
      about = L('settings.the_same_look_up_again_this'), inflight = AT_USE },
    { key = 'Immunity.PostRespawnSeconds', section = 'limits', category = 'rules-timers',
      group = 'Immunity', kind = 'number', integer = true, min = 0, max = 86400,
      label = L('settings.protected_after_a_respawn'), about = L('settings.nobody_may_be_targeted_this_long'),
      inflight = AT_USE },
    { key = 'Immunity.AfterBailoutSeconds', section = 'limits', category = 'rules-timers',
      group = 'Immunity', kind = 'number', integer = true, min = 0, max = 604800,
      label = L('settings.protected_after_a_buyout'), about = L('settings.nobody_may_target_them_again_this'),
      inflight = AT_USE },
    { key = 'Notifications.ParanoidAlertJitter', section = 'limits', category = 'rules-timers',
      group = 'Notifications', kind = 'range', integer = true, min = 0, max = 86400,
      label = L('settings.wait_before_eyes_on_you_from'),
      about = L('settings.the_targets_alert_waits_a_random'), inflight = AT_USE },
    { key = 'Notifications.ParanoidCooldownMinutes', section = 'limits', category = 'rules-timers',
      group = 'Notifications', kind = 'number', integer = true, min = 0, max = 1440,
      label = L('settings.one_eyes_on_you_per_target'), about = L('settings.at_most_one_such_alert_in'),
      inflight = AT_USE },
    { key = 'Mugshot.MinRefreshMinutes', section = 'limits', category = 'rules-timers',
      group = 'Targeting', kind = 'number', integer = true, min = 0, max = 1440,
      label = L('settings.least_time_between_two_headshots_min'), about = L('settings.of_one_target'), inflight = AT_USE },

    { key = 'Completion.PhotoRadius', section = 'limits', category = 'rules-limits', group = 'Completion',
      kind = 'number', min = 1, max = 100, label = L('settings.distance_to_the_body_to_verify'),
      about = L('settings.how_close_the_hitman_must_be'), inflight = AT_USE },
    { key = 'Completion.MaxWeaponRange', section = 'limits', category = 'rules-limits',
      group = 'Completion', kind = 'number', min = 10, max = 2000, label = L('settings.range_a_hit_is_believed_from'),
      about = L('settings.a_hit_reported_from_further_than'), inflight = AT_USE },
    { key = 'Completion.MedicJobs', section = 'limits', category = 'rules-limits', group = 'Completion',
      kind = 'list', label = L('settings.medic_jobs'), about = L('settings.jobs_whose_revive_counts_as_sc'),
      inflight = AT_USE },
    { key = 'Completion.DefibItem', section = 'limits', category = 'rules-limits', group = 'Completion',
      kind = 'text', pattern = '^[%w_%-]+$', maxLength = 64, label = L('settings.defibrillator_item'),
      about = L('settings.as_sc_ambulances_defib_item'), inflight = AT_USE },
    { key = 'Completion.DefibRange', section = 'limits', category = 'rules-limits', group = 'Completion',
      kind = 'number', min = 0.5, max = 20, label = L('settings.defibrillator_range_m'),
      about = L('settings.as_sc_ambulances_defib_distance'), inflight = AT_USE },
    { key = 'Kidnap.MaxConcurrentCountdowns', section = 'limits', category = 'rules-limits',
      group = 'Handovers', kind = 'number', integer = true, min = 1, max = 500,
      label = L('settings.handovers_counting_at_once'), about = L('settings.server_wide'), inflight = CAP },
    { key = 'Amendments.MaxOpenPerContract', section = 'limits', category = 'rules-limits',
      group = 'Proposals', kind = 'number', integer = true, min = 1, max = 10,
      label = L('settings.proposals_open_at_once'), about = L('settings.on_one_contract'), inflight = CAP },
    { key = 'Intel.Informant.RevealMode', section = 'limits', category = 'rules-limits', group = 'Intel: Informants',
      kind = 'choice', choices = { 'name', 'description' }, label = L('settings.what_the_targets_look_up_reveals'),
      about = L('settings.name_the_hitmans_name_description_what'), inflight = AT_USE },
    { key = 'Intel.Informant.ProximityRadius', section = 'limits', category = 'rules-limits', group = 'Intel: Informants',
      kind = 'number', min = 5, max = 2000, label = L('settings.distance_that_counts_as_near_m'),
      about = L('settings.for_an_idle_exclusive_holds_clock'), inflight = AT_USE },
    { key = 'Intel.Informant.MaxPurchasesPerContract', section = 'limits', category = 'rules-limits',
      group = 'Intel: Informants', kind = 'number', integer = true, min = 0, max = 50,
      label = L('settings.targets_look_ups_per_contract'), about = L('settings.both_kinds_together'), inflight = AT_USE },
    { key = 'Intel.PlacerInformant.RevealMode', section = 'limits', category = 'rules-limits',
      group = 'Intel: Informants', kind = 'choice', choices = { 'name', 'description' },
      label = L('settings.what_the_placers_look_up_reveals'),
      about = L('settings.name_the_operatives_name_description_what'), inflight = AT_USE },
    { key = 'Reason.Mode', section = 'limits', category = 'rules-limits', group = 'Contract reasons',
      kind = 'choice', choices = { 'preset', 'freetext', 'off' }, label = L('settings.how_a_reason_is_given'),
      about = L('settings.preset_picked_from_the_list_freetext'),
      inflight = L('settings.contracts_keep_the_reason_they_were') },
    { key = 'Reason.MaxLength', section = 'limits', category = 'rules-limits', group = 'Contract reasons',
      kind = 'number', integer = true, min = 10, max = 255, label = L('settings.longest_reason_characters'),
      about = L('settings.255_at_most_on_mysql'), inflight = AT_USE },
    { key = 'Reason.MaxDigits', section = 'limits', category = 'rules-limits', group = 'Contract reasons',
      kind = 'number', integer = true, min = 0, max = 50, label = L('settings.digits_a_reason_may_hold'),
      about = L('settings.kept_low_so_no_phone_number'), inflight = AT_USE },
    { key = 'Reason.Presets', section = 'limits', category = 'rules-limits', group = 'Contract reasons',
      kind = 'list', array = true, names = 'phrase', label = L('settings.reasons_to_pick_from'),
      about = L('settings.the_choices_in_preset_mode_in'), inflight = AT_USE },
    { key = 'Notifications.MaxPerRecipientPerMinute', section = 'limits', category = 'rules-limits',
      group = 'Notifications', kind = 'number', integer = true, min = 1, max = 100,
      label = L('settings.notices_a_player_may_get_a'), about = L('settings.above_it_notices_are_dropped'),
      inflight = AT_USE },
    { key = 'Notifications.MaxPerRecipientPerHour', section = 'limits', category = 'rules-limits',
      group = 'Notifications', kind = 'number', integer = true, min = 1, max = 1000,
      label = L('settings.notices_a_player_may_get_an'), about = L('settings.above_it_notices_are_dropped'),
      inflight = AT_USE },
    { key = 'Advisory.DispatchPriority', section = 'limits', category = 'rules-limits',
      group = 'Law enforcement advisory', kind = 'number', integer = true, min = 1, max = 3,
      label = L('settings.dispatch_priority'), about = L('settings.the_sc_dispatch_priority_of_an'), inflight = AT_USE },
    { key = 'Relay.MaxLength', section = 'limits', category = 'rules-limits', group = 'Messages and calls',
      kind = 'number', integer = true, min = 10, max = 255, label = L('settings.longest_message_characters'),
      about = L('settings.255_at_most_on_mysql'), inflight = AT_USE },
    { key = 'Relay.MaxMessagesPerThread', section = 'limits', category = 'rules-limits',
      group = 'Messages and calls', kind = 'number', integer = true, min = 10, max = 1000,
      label = L('settings.messages_a_thread_keeps'), about = L('settings.the_newest_are_kept'), inflight = AT_USE },
    { key = 'Ledger.Depth', section = 'limits', category = 'rules-limits', group = 'Ledger',
      kind = 'number', integer = true, min = 1, max = 100, ceiling = 'Ledger.MaxDepthHardCap',
      label = L('settings.ledger_rows_per_player'), about = L('settings.at_most_the_hard_cap_below'), inflight = AT_USE },
    { key = 'Ledger.MaxDepthHardCap', section = 'limits', category = 'rules-limits', group = 'Ledger',
      kind = 'number', integer = true, min = 1, max = 100, label = L('settings.ledger_rows_hard_cap'),
      about = L('settings.the_ceiling_on_ledger_rows_per'), inflight = AT_USE },
    { key = 'Listing.PageSize', section = 'limits', category = 'rules-limits', group = 'The app',
      kind = 'number', integer = true, min = 5, max = 100, label = L('settings.contracts_per_board_page'),
      about = L('settings.on_the_apps_board'), inflight = AT_USE },
    { key = 'Limits.JailZone.x', place = 'jail',
      section = 'limits', category = 'rules-limits', group = 'Contract limits',
      kind = 'number', min = -10000, max = 10000, label = L('settings.prison_grounds_centre_x'),
      about = L('settings.where_the_prison_grounds_are'), inflight = AT_USE },
    { key = 'Limits.JailZone.y', place = 'jail',
      section = 'limits', category = 'rules-limits', group = 'Contract limits',
      kind = 'number', min = -10000, max = 10000, label = L('settings.prison_grounds_centre_y'),
      about = L('settings.where_the_prison_grounds_are'), inflight = AT_USE },
    { key = 'Bailout.Command', section = 'limits', category = 'rules-limits', group = 'Buyouts',
      kind = 'text', pattern = '^[%w_%-]+$', maxLength = 32, live = false,
      label = L('settings.buyout_command'), about = L('settings.for_players_who_cannot_open_the'), inflight = RESTART },

    { key = 'BlockedJobTypes', section = 'limits', category = 'rules-targeting', group = 'Barred jobs',
      kind = 'list', label = L('settings.job_types_barred_from_the_app'),
      about = L('settings.players_on_these_job_types_cannot'),
      inflight = AT_USE .. L('settings.who_may_see_the_app_is') },
    { key = 'BlockedJobNames', section = 'limits', category = 'rules-targeting', group = 'Barred jobs',
      kind = 'list', label = L('settings.job_names_barred_from_the_app'),
      about = L('settings.players_on_these_jobs_cannot_use'),
      inflight = AT_USE .. L('settings.who_may_see_the_app_is') },
    { key = 'Immunity.MinTargetPlaytimeHours', section = 'limits', category = 'rules-targeting',
      group = 'Immunity', kind = 'number', min = 0, max = 10000,
      label = L('settings.hours_played_before_being_a_target'), about = L('settings.new_players_are_protected'),
      inflight = AT_USE },
    { key = 'Immunity.MinTargetSessionMinutes', section = 'limits', category = 'rules-targeting',
      group = 'Immunity', kind = 'number', integer = true, min = 0, max = 1440,
      label = L('settings.minutes_in_the_city_this_session'), about = L('settings.before_anyone_may_target_them'),
      inflight = AT_USE },
    { key = 'Immunity.GrandfatherDays', section = 'limits', category = 'rules-targeting',
      group = 'Immunity', kind = 'number', integer = true, min = 0, max = 365,
      label = L('settings.days_of_grandfathering'), about = L('settings.only_without_qbx_cores_players_table'),
      inflight = AT_USE },

    { key = 'Database.Json.WarnContractCount', section = 'limits', category = 'developer', group = 'Storage',
      kind = 'number', integer = true, min = 100, max = 1000000, label = L('settings.json_warn_above_this_many_contracts'),
      about = L('settings.a_console_warning_past_it'), inflight = AT_USE },
    { key = 'Database.Json.MaxDirtyShardsPerFlush', section = 'limits', category = 'developer',
      group = 'Storage', kind = 'number', integer = true, min = 1, max = 1000,
      label = L('settings.json_contract_files_one_flush_writes'), about = L('settings.the_rest_wait_for_the_next'),
      inflight = AT_USE },
    { key = 'Audit.FlushIntervalMs', section = 'limits', category = 'developer', group = 'Audit and debug',
      kind = 'number', integer = true, min = 1000, max = 600000, label = L('settings.audit_flush_interval_ms'),
      about = L('settings.how_often_queued_log_rows_are'),
      inflight = L('settings.read_at_the_next_flush') },
    { key = 'Audit.MaxQueueSize', section = 'limits', category = 'developer', group = 'Audit and debug',
      kind = 'number', integer = true, min = 100, max = 100000, label = L('settings.log_rows_queued_at_most'),
      about = L('settings.past_it_the_oldest_are_written'), inflight = AT_USE },
    { key = 'Audit.RetentionDays', section = 'limits', category = 'developer', group = 'Audit and debug',
      kind = 'number', integer = true, min = 0, max = 3650, label = L('settings.days_the_log_is_kept_0'),
      about = L('settings.older_rows_are_deleted_by_the'),
      destroys = L('settings.lowering_it_to_deletes_every_log'),
      inflight = L('settings.read_at_the_next_sweep') },
    { key = 'Audit.ContractRetentionDays', section = 'limits', category = 'developer',
      group = 'Audit and debug', kind = 'number', integer = true, min = 0, max = 3650,
      label = L('settings.days_a_finished_contract_is_kept'),
      about = L('settings.finished_contracts_older_than_this_are'),
      destroys = L('settings.lowering_it_to_deletes_every_finished'),
      inflight = L('settings.read_at_the_next_sweep') },
    { key = 'Audit.ContractsPrunedPerTick', section = 'limits', category = 'developer',
      group = 'Audit and debug', kind = 'number', integer = true, min = 1, max = 10000,
      label = L('settings.finished_contracts_removed_per_sweep'), about = L('settings.paces_the_sweep'), inflight = AT_USE },
    { key = 'Diagnostics.SlowJobMs', section = 'limits', category = 'developer', group = 'Diagnostics',
      kind = 'number', integer = true, min = 0, max = 60000, label = L('settings.slow_job_threshold_ms_0_never'),
      about = L('settings.a_maintenance_job_slower_than_this'), inflight = AT_USE },
    { key = 'Kidnap.MaxTotalGraceMs', section = 'limits', category = 'developer', group = 'Handovers',
      kind = 'number', integer = true, min = 0, max = 60000, label = L('settings.handover_break_allowed_ms'),
      about = L('settings.in_all_before_a_handover_fails'), inflight = AT_USE },
    { key = 'Kidnap.TickMs', section = 'limits', category = 'developer', group = 'Handovers',
      kind = 'number', integer = true, min = 250, max = 5000, label = L('settings.handover_check_interval_ms'),
      about = L('settings.how_often_a_running_handover_is'), inflight = L('settings.read_at_the_next_check') },
    { key = 'Completion.DeathReportWindowMs', section = 'limits', category = 'developer',
      group = 'Completion', kind = 'number', integer = true, min = 1000, max = 600000,
      label = L('settings.a_hit_counts_this_long_before'), about = L('settings.for_the_damage_log'),
      inflight = AT_USE },
    { key = 'Completion.ConditionSampleMs', section = 'limits', category = 'developer',
      group = 'Completion', kind = 'number', integer = true, min = 250, max = 10000,
      label = L('settings.targets_health_sampled_every_ms'), about = L('settings.server_wide'), inflight = L('settings.read_at_the_next_sample') },
    { key = 'Completion.PhotoMaxSide', section = 'limits', category = 'developer', group = 'Completion',
      kind = 'number', integer = true, min = 320, max = 4096, label = L('settings.photo_longest_side_px'),
      about = L('settings.server_storage'), inflight = AT_USE },
    { key = 'Completion.PhotoMaxBytes', section = 'limits', category = 'developer', group = 'Completion',
      kind = 'number', integer = true, min = 50000, max = 1500000, label = L('settings.largest_photo_bytes'),
      about = L('settings.server_storage'), inflight = AT_USE },
    { key = 'Completion.PhotoHostRefreshSeconds', section = 'limits', category = 'developer',
      group = 'Completion', kind = 'number', integer = true, min = 30, max = 86400,
      label = L('settings.re_read_lb_phones_image_hosts'), about = L('settings.host_storage'),
      inflight = L('settings.read_at_the_next_re_read') },
    { key = 'Completion.ExtraPhotoHosts', section = 'limits', category = 'developer', group = 'Completion',
      kind = 'list', array = true, names = 'host', label = L('settings.image_hosts_allowed_besides_lb_phones'),
      about = L('settings.host_storage_host_names_such_as'), inflight = AT_USE },
    { key = 'Mugshot.RenderTimeoutMs', section = 'limits', category = 'developer', group = 'Targeting',
      kind = 'number', integer = true, min = 1000, max = 60000, label = L('settings.time_a_headshot_may_take_ms'),
      about = L('settings.on_the_targets_game'), inflight = AT_USE },
    { key = 'Mugshot.MaxImageBytes', section = 'limits', category = 'developer', group = 'Targeting',
      kind = 'number', integer = true, min = 4096, max = 1048576, label = L('settings.largest_headshot_bytes'),
      about = L('settings.a_larger_one_is_refused'), inflight = AT_USE },
    { key = 'Mugshot.AllowedMime', section = 'limits', category = 'developer', group = 'Targeting',
      kind = 'list', names = 'mime', label = L('settings.headshot_image_types_accepted'),
      about = L('settings.such_as_image_png'), inflight = AT_USE },
    { key = 'Bailout.MaxSettleAttempts', section = 'limits', category = 'developer', group = 'Buyouts',
      kind = 'number', integer = true, min = 1, max = 100, label = L('settings.ticks_a_buyout_waits_on_a'),
      about = L('settings.then_it_is_left_for_staff'), inflight = AT_USE },
    { key = 'Notifications.PushMinIntervalSeconds', section = 'limits', category = 'developer',
      group = 'Notifications', kind = 'number', integer = true, min = 1, max = 60,
      label = L('settings.least_time_between_two_app_refreshes'), about = L('settings.per_open_app'), inflight = AT_USE },
    { key = 'Admin.PanelPageSize', section = 'limits', category = 'developer', group = 'Staff',
      kind = 'number', integer = true, min = 5, max = 100, label = L('settings.rows_per_page_in_this_panel'),
      about = L('settings.its_lists'), inflight = L('settings.read_at_the_next_page_asked') },
    { key = 'Admin.PanelRefreshSeconds', section = 'limits', category = 'developer', group = 'Staff',
      kind = 'number', integer = true, min = 2, max = 300, label = L('settings.overview_refresh'),
      about = L('settings.how_often_this_panels_overview_refreshes'), inflight = L('settings.read_when_the_panel_is_opened') },
    { key = 'Admin.TimelineRows', section = 'limits', category = 'developer', group = 'Staff',
      kind = 'number', integer = true, min = 10, max = 2000, label = L('settings.log_rows_read_for_one_timeline'),
      about = L('settings.a_contracts_history'), inflight = AT_USE },
    { key = 'RateLimit.Key', section = 'limits', category = 'developer', group = 'Rate limits',
      kind = 'choice', choices = { 'license', 'citizenid' }, label = L('settings.rate_limits_counted_per'),
      about = L('settings.license_per_account_citizenid_per_character'),
      inflight = L('settings.read_at_each_request_allowances_start') },
}

--- The other scripts this resource works with (Config.Integrations,
--- server/adapters/): one choice per kind, of the adapters this build has
--- and 'auto' (and 'none', but for the framework). A resource name is never
--- typed in here, so nothing can be made to call an export it was not
--- written for.
--- Each kind's name and what happens without one, in the language in force:
--- shared/integrations.lua keeps its English for the console line alone.
--- [kind] = { name, without }
local INTEGRATION_WORDS = {
    framework = { L('integrations.framework_name'), L('integrations.framework_without') },
    inventory = { L('integrations.inventory_name'), L('integrations.inventory_without') },
    target = { L('integrations.target_name'), L('integrations.target_without') },
    dispatch = { L('integrations.dispatch_name'), L('integrations.dispatch_without') },
    ambulance = { L('integrations.ambulance_name'), L('integrations.ambulance_without') },
    banking = { L('integrations.banking_name'), L('integrations.banking_without') },
    phone = { L('integrations.phone_name'), L('integrations.phone_without') },
    keys = { L('integrations.keys_name'), L('integrations.keys_without') },
    garage = { L('integrations.garage_name'), L('integrations.garage_without') },
    mugshot = { L('integrations.mugshot_name'), L('integrations.mugshot_without') },
    clothing = { L('integrations.clothing_name'), L('integrations.clothing_without') },
    progression = { L('integrations.progression_name'), L('integrations.progression_without') },
}

--- What a kind's words are, for the Setup page (server/setup.lua).
---@param kind string
---@return string|nil without
function Settings.integrationWithout(kind)
    local words = INTEGRATION_WORDS[kind]
    return words and words[2] or nil
end

local INTEGRATION_ABOUT = {
    Framework = L('settings.players_jobs_and_money_required_so'),
    Banking = L('settings.where_the_organisations_funds_are_kept'),
}
for _, spec in ipairs(Integrations.KINDS) do
    local choices = { 'auto' }
    for _, name in ipairs(Integrations.names(spec.kind)) do choices[#choices + 1] = name end
    if not spec.required then choices[#choices + 1] = 'none' end
    local client = spec.side ~= 'server'
    local inflight = AT_USE
    if spec.required then
        inflight = RESTART
    elseif spec.kind == 'banking' then
        inflight = L('settings.read_for_the_first_choice_of')
    elseif client then
        inflight = L('settings.sent_to_every_players_game_at')
    end
    local words = INTEGRATION_WORDS[spec.kind] or { spec.kind, spec.without }
    CATALOGUE[#CATALOGUE + 1] = {
        key = 'Integrations.' .. spec.key, section = 'limits', category = 'developer', group = 'Other scripts',
        kind = 'choice', choices = choices, client = client or nil, live = spec.required and false or nil,
        -- The kind and what happens without one, in the language in force
        -- (integrations.<kind>_name, _without): shared/integrations.lua
        -- keeps its English for the console line alone.
        label = L('settings.other_scripts') .. words[1],
        about = (INTEGRATION_ABOUT[spec.key] or '') .. (INTEGRATION_ABOUT[spec.key] and ' ' or '')
            .. L('settings.auto_the_first_installed_and_started') .. words[2] .. '.',
        inflight = inflight,
    }
end

--- Each staff command's name, read once at start (RegisterCommand): kept,
--- and in force after a restart.
for _, name in ipairs({ 'timeline', 'void', 'stuck', 'settle', 'whois', 'contracts', 'diagnose',
    'refresh', 'review', 'panel' }) do
    CATALOGUE[#CATALOGUE + 1] = {
        key = 'Admin.Commands.' .. name, section = 'limits', category = 'developer', group = 'Staff commands',
        kind = 'text', pattern = '^[%w_%-]+$', maxLength = 32, live = false,
        label = L('settings.command_name') .. name, about = L('settings.without_the_slash'), inflight = RESTART,
    }
end

--- The rate-limit buckets, each as two keys: how many seconds a full
--- bucket refills over, and how many it holds.
local BUCKETS = {
    'load', 'search', 'wallet', 'create', 'accept', 'amend', 'informant', 'placerInformant', 'locationTip',
    'bailout', 'photo',
    'photoSubmit', 'photoView', 'photoDecide', 'message', 'progress', 'death', 'mugshot',
    'image', 'diagnostic', 'admin', 'adminWrite', 'report', 'org', 'orgWrite', 'disposal',
}

--- What each bucket gates: the buttons and events a player is refused once
--- it is spent. The rows said only '<bucket>: requests held', and one click
--- of 'load' from 20 to 1 refused every Board, Mine and Ledger read for an
--- hour. The background ones are refused without a word to anybody.
local BUCKET_ABOUT = {
    load = L('settings.every_read_the_app_makes_of'),
    search = L('settings.browsing_and_searching_names_on_the'),
    wallet = L('settings.reading_what_the_placer_carries_once'),
    create = L('settings.placing_a_contract'),
    accept = L('settings.accepting_abandoning_and_cancelling_a_contract'),
    amend = L('settings.proposals_and_the_answers_to_them'),
    informant = L('settings.a_targets_look_up_from_the'),
    placerInformant = L('settings.a_placers_look_up_from_the'),
    locationTip = L('settings.buying_an_informant_tip_on_a'),
    bailout = L('settings.buying_out_a_contract_in_the'),
    photo = L('settings.asking_to_photograph_a_kill_and'),
    photoSubmit = L('settings.sending_a_kill_photo'),
    photoView = L('settings.opening_a_kill_photo_from_the'),
    photoDecide = L('settings.saving_or_deleting_a_kill_photo'),
    message = L('settings.placing_and_ending_a_call_muting'),
    progress = L('settings.in_the_background_the_handover_countdown'),
    death = L('settings.in_the_background_death_and_revive'),
    mugshot = L('settings.in_the_background_the_headshots_players'),
    image = L('settings.fetching_a_headshot_the_board_was'),
    diagnostic = L('settings.fault_reports_players_apps_send_the'),
    report = L('settings.reporting_a_contract_or_a_message'),
    org = L('settings.reading_the_hitman_organisation_in_the'),
    orgWrite = L('settings.what_a_boss_or_member_changes'),
    disposal = L('settings.loading_a_body_and_dropping_it'),
}

--- The least the buckets the app cannot work without may be set to from
--- here. Set from config.lua, a value below them is the owner's to choose;
--- one click here could otherwise stop the app opening, or stop a handover
--- running, for everyone at once.
local BUCKET_FLOORS = {
    load = { burst = 6, rate = 1 / 5,
             needs = L('settings.at_least_6_requests_held_and'),
             why = L('settings.opening_the_app_sends_four_reads') },
    progress = { rate = 1, needs = L('settings.a_refill_of_at_least_one'),
                 why = L('settings.a_running_handover_asks_for_its') },
    death = { burst = 2, needs = L('settings.at_least_2_requests_held'),
              why = L('settings.a_death_and_the_revive_after') },
}

--- What a stricter value does, said beside the second click: %s the value.
local BUCKET_STRICTER = L('settings.players_are_refused_sooner_and_wait')

--- The panel's own buckets, which every request it makes spends (Panel.handle).
--- Changeable here, one request an hour was accepted, kept and applied at
--- every start, and the page's own overview refresh spent it: the reset that
--- would have put it back was refused with the rest, and only an edit of the
--- store by hand let staff in again.
local PANEL_BUCKETS = { admin = true, adminWrite = true }
local PANEL_BUCKET_READONLY = L('settings.the_staff_panels_own_allowance_which')

--- Each bucket's two rows. `stricter` is the way a value refuses players
--- sooner (a longer refill window, fewer requests held), which takes two
--- clicks with `strict` said beside the second, as `destroys` does.
for _, bucket in ipairs(BUCKETS) do
    local panel = PANEL_BUCKETS[bucket]
    local gates = BUCKET_ABOUT[bucket]
    CATALOGUE[#CATALOGUE + 1] = {
        key = 'Cooldowns.' .. bucket .. '.per', section = panel and 'readonly' or 'limits', category = 'developer',
        group = panel and L('settings.staff') or L('settings.rate_limits'),
        kind = 'number', min = 0.5, max = 3600, label = bucket .. L('settings.refill_window'),
        about = gates and (gates .. L('settings.a_full_allowance_refills_over_this')) or nil,
        stricter = not panel and 'up' or nil,
        strict = not panel and (L('settings.a_refill_window_of') .. BUCKET_STRICTER) or nil,
        inflight = not panel and AT_USE or nil, readonly = panel and PANEL_BUCKET_READONLY or nil,
    }
    CATALOGUE[#CATALOGUE + 1] = {
        key = 'Cooldowns.' .. bucket .. '.burst', section = panel and 'readonly' or 'limits', category = 'developer',
        group = panel and L('settings.staff') or L('settings.rate_limits'),
        kind = 'number', integer = true, min = 1, max = 200, label = bucket .. L('settings.requests_held'),
        about = gates and (gates .. L('settings.how_many_it_allows_at_once')) or nil,
        stricter = not panel and 'down' or nil,
        strict = not panel and (L('settings.holding_x'):format(BUCKET_STRICTER)) or nil,
        inflight = not panel and AT_USE or nil, readonly = panel and PANEL_BUCKET_READONLY or nil,
    }
end

--- The roleplay consequences (server/rp_consequences.lua, README, Optional
--- features): each switch under Features, the rest under the Rules view it
--- belongs to. `whole` lists take each line as typed, spaces and commas
--- included (a phrase, a template, an area), rather than as names.
local RP_TEXT = L('settings.letters_digits_spaces_and_punctuation_no')
for _, entry in ipairs({
    -- Witness heat
    { key = 'Roleplay.WitnessHeat.Enabled', category = 'features', group = 'Roleplay: Witness heat',
      kind = 'switch', label = L('settings.witness_heat'),
      about = L('settings.a_completion_seen_by_bystanders_players'),
      inflight = L('settings.at_the_next_completion_with_no') },
    { key = 'Roleplay.WitnessHeat.AlwaysAlert', category = 'features', group = 'Roleplay: Witness heat',
      kind = 'switch', label = L('settings.witness_heat_alert_on_every_completion'),
      about = L('settings.a_report_on_every_completion_whether'), inflight = AT_USE },
    { key = 'Roleplay.WitnessHeat.SendCoords', category = 'features', group = 'Roleplay: Witness heat',
      kind = 'switch', label = L('settings.witness_heat_give_dispatch_a_position'),
      about = L('settings.off_only_the_area_is_named'),
      inflight = AT_USE },
    { key = 'Roleplay.WitnessHeat.WitnessRadius', category = 'rules-limits', group = 'Roleplay: Witness heat',
      kind = 'number', min = 1, max = 500, label = L('settings.metres_a_bystander_sees_a_completion'),
      about = L('settings.measured_from_the_hitman_on_the'), inflight = AT_USE },
    { key = 'Roleplay.WitnessHeat.MinWitnesses', category = 'rules-limits', group = 'Roleplay: Witness heat',
      kind = 'number', integer = true, min = 1, max = 50, label = L('settings.bystanders_it_takes_to_raise_a'),
      inflight = AT_USE },
    { key = 'Roleplay.WitnessHeat.FuzzMeters', category = 'rules-limits', group = 'Roleplay: Witness heat',
      kind = 'number', min = 0, max = 1000, label = L('settings.metres_the_position_may_be_off'),
      inflight = AT_USE },
    { key = 'Roleplay.WitnessHeat.DispatchPriority', category = 'rules-limits', group = 'Roleplay: Witness heat',
      kind = 'number', integer = true, min = 1, max = 5, label = L('settings.sc_dispatch_priority_of_a_report'),
      inflight = AT_USE },
    { key = 'Roleplay.WitnessHeat.Title', category = 'rules-limits', group = 'Roleplay: Witness heat',
      kind = 'text', pattern = '^[^%c<>]+$', maxLength = 60, says = RP_TEXT,
      label = L('settings.title_of_a_witness_report'), inflight = AT_USE },
    { key = 'Roleplay.WitnessHeat.Phrases', category = 'rules-limits', group = 'Roleplay: Witness heat',
      kind = 'list', array = true, whole = true, names = 'phrase', label = L('settings.what_a_witness_says'),
      about = L('settings.one_is_picked_direction_is_where'),
      inflight = AT_USE },
    { key = 'Roleplay.WitnessHeat.Areas', place = 'area', category = 'rules-limits', group = 'Roleplay: Witness heat',
      kind = 'list', array = true, whole = true, names = 'area', label = L('settings.areas_as_name_x_y'),
      about = L('settings.the_nearest_centre_names_the_area'), inflight = AT_USE },
    -- EMS before re-listing
    { key = 'Roleplay.EmsRelisting.Enabled', category = 'features', group = 'Roleplay: EMS before re-listing',
      kind = 'switch', label = L('settings.ems_before_re_listing'),
      about = L('settings.after_a_contract_on_somebody_completes'),
      inflight = L('settings.at_the_next_contract_placed_with') },
    { key = 'Roleplay.EmsRelisting.RequireEMS', category = 'features', group = 'Roleplay: EMS before re-listing',
      kind = 'switch', label = L('settings.ems_before_re_listing_a_medics'),
      about = L('settings.instead_of_the_minutes_up_an'), inflight = AT_USE },
    { key = 'Roleplay.EmsRelisting.TreatedMinutes', category = 'rules-timers', group = 'Roleplay: EMS before re-listing',
      kind = 'number', integer = true, min = 0, max = 240, label = L('settings.minutes_up_that_count_as_treated'),
      inflight = AT_USE },
    { key = 'Roleplay.EmsRelisting.MaxHoldMinutes', category = 'rules-timers', group = 'Roleplay: EMS before re-listing',
      kind = 'number', integer = true, min = 1, max = 1440, label = L('settings.longest_the_rule_holds_after_a'),
      about = L('settings.past_it_the_target_may_be'), inflight = AT_USE },
    -- City news
    { key = 'Roleplay.CityNews.Enabled', category = 'features', group = 'Roleplay: City news',
      kind = 'switch', label = L('settings.city_news'),
      about = L('settings.a_completed_contract_on_a_whitelisted'),
      inflight = L('settings.at_the_next_completion_with_no') },
    { key = 'Roleplay.CityNews.AllTargets', category = 'features', group = 'Roleplay: City news',
      kind = 'switch', label = L('settings.city_news_on_every_target'),
      about = L('settings.off_whitelisted_job_targets_only'), inflight = AT_USE },
    { key = 'Roleplay.CityNews.NameTarget', category = 'features', group = 'Roleplay: City news',
      kind = 'switch', label = L('settings.city_news_name_the_target'),
      about = L('settings.on_name_in_a_template_is'), inflight = AT_USE },
    { key = 'Roleplay.CityNews.App', category = 'rules-limits', group = 'Roleplay: City news',
      kind = 'choice', choices = { 'birdy', 'event' }, label = L('settings.where_news_is_posted'),
      about = L('settings.birdy_lb_phones_postbirdy_export_event'), inflight = AT_USE },
    { key = 'Roleplay.CityNews.Account', category = 'rules-limits', group = 'Roleplay: City news',
      kind = 'text', pattern = '^[%w_%-%.]+$', maxLength = 32, label = L('settings.birdy_account_news_is_posted_from'),
      about = L('settings.it_must_exist_in_lb_phone'), inflight = AT_USE },
    { key = 'Roleplay.CityNews.Event', category = 'rules-limits', group = 'Roleplay: City news',
      kind = 'text', pattern = '^[%w_%-%.:]+$', maxLength = 64, says = L('settings.an_event_name_letters_digits_and'),
      label = L('settings.server_event_news_is_fired_as'),
      about = L('settings.fired_on_the_server_only_with'), inflight = AT_USE },
    { key = 'Roleplay.CityNews.Templates', category = 'rules-limits', group = 'Roleplay: City news',
      kind = 'list', array = true, whole = true, names = 'sentence', label = L('settings.news_templates'),
      about = L('settings.one_is_picked_job_zone_time'), inflight = AT_USE },
    -- Dirty money payouts
    { key = 'Roleplay.DirtyPayouts.Enabled', category = 'features', group = 'Roleplay: Dirty money payouts',
      kind = 'switch', label = L('settings.dirty_money_payouts'),
      about = L('settings.a_hitmans_cash_or_bank_payout'),
      inflight = L('settings.at_the_next_payout_owed_ones') },
    { key = 'Roleplay.DirtyPayouts.Item', category = 'rules-rewards', group = 'Roleplay: Dirty money payouts',
      kind = 'text', pattern = '^[%w_%-]+$', maxLength = 64, label = L('settings.item_a_payout_is_paid_as'),
      about = L('settings.an_ox_inventory_item_black_money'),
      inflight = AT_USE },
    { key = 'Roleplay.DirtyPayouts.Mode', category = 'rules-rewards', group = 'Roleplay: Dirty money payouts',
      kind = 'choice', choices = { 'count', 'worth' }, label = L('settings.how_the_item_holds_the_money'),
      about = L('settings.count_items_by_the_rate_worth'),
      inflight = AT_USE },
    { key = 'Roleplay.DirtyPayouts.WorthKey', category = 'rules-rewards', group = 'Roleplay: Dirty money payouts',
      kind = 'text', pattern = '^[%w_%-]+$', maxLength = 32, label = L('settings.metadata_key_of_its_value_worth'),
      inflight = AT_USE },
    { key = 'Roleplay.DirtyPayouts.Rate', category = 'rules-rewards', group = 'Roleplay: Dirty money payouts',
      kind = 'number', integer = true, min = 1, max = 100, label = L('settings.items_paid_for_each_dollar_count'),
      inflight = AT_USE },
}) do
    entry.section = entry.category == 'features' and 'features' or 'limits'
    CATALOGUE[#CATALOGUE + 1] = entry
end
for _, key in ipairs({ 'Roleplay.DirtyPayouts.Item', 'Roleplay.DirtyPayouts.Mode',
    'Roleplay.DirtyPayouts.WorthKey', 'Roleplay.DirtyPayouts.Rate' }) do
    MONEY[key] = 'Payouts'
end

--- Roleplay (group rpC, README, Optional features): proof of intent,
--- bodyguards and the hit on the hitman. Each switch under
--- Features, each figure under Rules; all read at use, with no restart.
local RP_INTENT = L('settings.roleplay_proof_of_intent')
local RP_PROTECTION, RP_HIT = 'Roleplay: Bodyguards', L('settings.roleplay_hit_on_the_hitman')
for _, entry in ipairs({
    { key = 'Roleplay.ProofOfIntent.Enabled', section = 'features', category = 'features', group = RP_INTENT,
      kind = 'switch', label = L('settings.proof_of_intent_before_a_payout'),
      about = L('settings.a_payout_waits_until_the_hitman'),
      inflight = L('settings.read_at_every_give_turned_off') },
    { key = 'Roleplay.ProofOfIntent.MinMessages', section = 'limits', category = 'rules-limits', group = RP_INTENT,
      kind = 'number', integer = true, min = 0, max = 100,
      label = L('settings.messages_to_the_placer_that_count'), inflight = AT_USE },
    { key = 'Roleplay.ProofOfIntent.HoldMaxMinutes', section = 'limits', category = 'rules-timers', group = RP_INTENT,
      kind = 'number', integer = true, min = 1, max = 10080,
      label = L('settings.longest_a_payout_is_held_for'),
      inflight = L('settings.read_at_every_give_a_hold') },

    { key = 'Roleplay.Protection.Enabled', section = 'features', category = 'features', group = RP_PROTECTION,
      kind = 'switch', label = L('settings.bodyguard_contracts'),
      about = L('settings.a_target_may_post_an_anonymous'),
      inflight = L('settings.turned_off_no_job_is_posted') },
    { key = 'Roleplay.Protection.Account', section = 'limits', category = 'rules-rewards', group = RP_PROTECTION,
      kind = 'choice', choices = { 'cash', 'bank' }, label = L('settings.bodyguard_reward_paid_from'),
      inflight = L('settings.new_jobs_only_a_job_is') },
    { key = 'Roleplay.Protection.MinReward', section = 'limits', category = 'rules-rewards', group = RP_PROTECTION,
      kind = 'number', integer = true, min = 1, max = 10000000, label = L('settings.least_bodyguard_reward'),
      inflight = L('settings.new_jobs_only') },
    { key = 'Roleplay.Protection.MaxReward', section = 'limits', category = 'rules-rewards', group = RP_PROTECTION,
      kind = 'number', integer = true, min = 1, max = 10000000, label = L('settings.most_bodyguard_reward'),
      inflight = L('settings.new_jobs_only') },
    { key = 'Roleplay.Protection.PayOnCompletionPercent', section = 'limits', category = 'rules-rewards',
      group = RP_PROTECTION, kind = 'number', integer = true, min = 0, max = 100,
      label = L('settings.guards_share_if_the_contract_completes'),
      inflight = L('settings.read_when_the_contract_ends') },
    { key = 'Roleplay.Protection.MaxJobsPerGuard', section = 'limits', category = 'rules-limits', group = RP_PROTECTION,
      kind = 'number', integer = true, min = 1, max = 20, label = L('settings.protection_jobs_one_guard_holds_at'),
      inflight = CAP },

    { key = 'Roleplay.HitOnHitman.Enabled', section = 'features', category = 'features', group = RP_HIT,
      kind = 'switch', label = L('settings.hit_on_the_hitman'),
      about = L('settings.a_target_whose_informant_found_out'),
      inflight = AT_USE },
}) do
    CATALOGUE[#CATALOGUE + 1] = entry
end
MONEY['Roleplay.Protection.Account'] = 'Payouts'
MONEY['Roleplay.Protection.MinReward'] = 'Payouts'
MONEY['Roleplay.Protection.MaxReward'] = 'Payouts'
MONEY['Roleplay.Protection.PayOnCompletionPercent'] = 'Payouts'

--- The roleplay features (server/rp_*.lua, Config.Roleplay), each off as
--- shipped: the switch under Features, the rest under the rules they are.
--- `whole` on a list: what is typed is one entry, spaces and commas kept
--- (a place, a phrase), not names split at each.
local INTEL_RUMOURS, RP_BURNER = L('settings.intel_rumours_and_broker'), L('settings.roleplay_burner_phone')
local INTEL_IN_PERSON, RP_REASON = L('settings.intel_informant_in_person'), L('settings.roleplay_reason_quality')
local PLACES = L('settings.each_place_is_x_y_z')
local NPC_MOVES = L('settings.every_game_is_told_at_once')
for _, entry in ipairs({
    { key = 'Intel.Rumours.Enabled', section = 'features', category = 'features', group = INTEL_RUMOURS,
      kind = 'switch', label = L('settings.rumours_and_the_broker'),
      about = L('settings.the_board_shows_a_new_contract'),
      inflight = L('settings.read_at_every_board_read_and') },
    { key = 'Intel.Rumours.AreaMode', section = 'limits', category = 'rules-targeting', group = INTEL_RUMOURS,
      kind = 'choice', choices = { 'district', 'zones' }, label = L('settings.what_area_a_rumour_names'),
      about = L('settings.district_the_nearest_of_districts_to'), inflight = L('settings.rumours_already_told_keep_the_area') },
    { key = 'Intel.Rumours.Zones', place = 'name',
      section = 'limits', category = 'rules-targeting', group = INTEL_RUMOURS,
      kind = 'list', array = true, whole = true, names = 'phrase', label = L('settings.zone_names'),
      about = L('settings.vague_area_names_a_rumour_picks'), inflight = AT_USE },
    { key = 'Intel.Rumours.Districts', place = 'district', section = 'limits', category = 'rules-targeting',
      group = INTEL_RUMOURS, kind = 'list', array = true, whole = true, names = 'area',
      label = L('settings.districts_x_y_name'), about = L('settings.the_nearest_one_to_the_target'),
      inflight = L('settings.rumours_already_told_keep_the_area') },
    { key = 'Intel.Rumours.BandPercent', section = 'limits', category = 'rules-limits', group = INTEL_RUMOURS,
      kind = 'number', integer = true, min = 0, max = 100, label = L('settings.reward_band_either_side'),
      about = L('settings.a_rumour_gives_the_reward_as'), inflight = AT_USE },
    { key = 'Intel.Rumours.Radius', section = 'limits', category = 'rules-limits', group = INTEL_RUMOURS,
      kind = 'number', min = 1, max = 100, label = L('settings.distance_to_the_broker_m'),
      about = L('settings.how_close_the_hitman_stands_to'), inflight = AT_USE },
    { key = 'Intel.Rumours.BriefValidMinutes', section = 'limits', category = 'rules-timers',
      group = INTEL_RUMOURS, kind = 'number', integer = true, min = 1, max = 1440,
      label = L('settings.a_briefing_lasts_min'), about = L('settings.how_long_a_briefing_unlocks_a'),
      inflight = L('settings.briefings_already_given_keep_their_time') },
    { key = 'Intel.Rumours.Locations', place = 'point',
      section = 'limits', category = 'rules-limits', group = INTEL_RUMOURS,
      kind = 'list', array = true, whole = true, names = 'point', label = L('settings.broker_npc_places'),
      about = PLACES, inflight = NPC_MOVES },
    { key = 'Intel.Rumours.RotateHours', section = 'limits', category = 'rules-timers', group = INTEL_RUMOURS,
      kind = 'number', integer = true, min = 1, max = 168, label = L('settings.broker_moves_every_h'),
      about = L('settings.the_broker_npc_moves_to_its'), inflight = NPC_MOVES },
    { key = 'Intel.Rumours.Model', section = 'limits', category = 'rules-limits', group = INTEL_RUMOURS,
      kind = 'text', pattern = '^[%w_%-]+$', maxLength = 64, label = L('settings.broker_npc_model'),
      about = L('settings.a_gta_ped_model_name'), inflight = NPC_MOVES },
    { key = 'Intel.Rumours.Scenario', section = 'limits', category = 'rules-limits', group = INTEL_RUMOURS,
      kind = 'text', pattern = '^[%w_%-]+$', maxLength = 64, label = L('settings.broker_npc_scenario'),
      about = L('settings.what_the_npc_does_while_it'), inflight = NPC_MOVES },
    { key = 'Intel.Rumours.Blip', section = 'features', category = 'features', group = INTEL_RUMOURS,
      kind = 'switch', label = L('settings.broker_on_the_map'), about = L('settings.a_map_blip_where_the_broker'),
      inflight = NPC_MOVES },
    { key = 'Intel.Rumours.BrokerJobs', section = 'limits', category = 'rules-targeting',
      group = INTEL_RUMOURS, kind = 'list', label = L('settings.broker_jobs'),
      about = L('settings.players_on_these_jobs_brief_a'),
      inflight = AT_USE },

    { key = 'Roleplay.BurnerPhone.Enabled', section = 'features', category = 'features', group = RP_BURNER,
      kind = 'switch', label = L('settings.burner_phone_required'),
      about = L('settings.placing_accepting_and_every_contract_action'),
      inflight = L('settings.checked_at_every_action_live_contracts') },
    { key = 'Roleplay.BurnerPhone.ConsumeOnPlace', section = 'features', category = 'features',
      group = RP_BURNER, kind = 'switch', label = L('settings.use_one_up_on_placing'),
      about = L('settings.one_burner_is_used_up_when'), inflight = AT_USE },
    { key = 'Roleplay.BurnerPhone.ConsumeOnAccept', section = 'features', category = 'features',
      group = RP_BURNER, kind = 'switch', label = L('settings.use_one_up_on_accepting'),
      about = L('settings.one_burner_is_used_up_when_2'), inflight = AT_USE },
    { key = 'Roleplay.BurnerPhone.RequireToOpen', section = 'features', category = 'features',
      group = RP_BURNER, kind = 'switch', label = L('settings.no_burner_no_contract_tabs'),
      about = L('settings.without_one_the_board_and_the'), inflight = AT_USE },
    { key = 'Roleplay.BurnerPhone.Item', section = 'limits', category = 'rules-limits', group = RP_BURNER,
      kind = 'text', pattern = '^[%w_%-]+$', maxLength = 64, label = L('settings.burner_phone_item'),
      about = L('settings.the_ox_inventory_item_name'), inflight = AT_USE },

    { key = 'Intel.InPerson.Enabled', section = 'features', category = 'features', group = INTEL_IN_PERSON,
      kind = 'switch', label = L('settings.informant_in_person'),
      about = L('settings.every_informant_purchase_needs_the_buyer'),
      inflight = L('settings.checked_at_every_purchase_nothing_already') },
    { key = 'Intel.InPerson.Radius', section = 'limits', category = 'rules-limits', group = INTEL_IN_PERSON,
      kind = 'number', min = 1, max = 100, label = L('settings.distance_to_the_informant_m'),
      about = L('settings.how_close_the_buyer_stands_to'), inflight = AT_USE },
    { key = 'Intel.InPerson.Locations', place = 'point', section = 'limits', category = 'rules-limits',
      group = INTEL_IN_PERSON, kind = 'list', array = true, whole = true, names = 'point',
      label = L('settings.informant_npc_places'), about = PLACES, inflight = NPC_MOVES },
    { key = 'Intel.InPerson.RotateHours', section = 'limits', category = 'rules-timers',
      group = INTEL_IN_PERSON, kind = 'number', integer = true, min = 1, max = 168,
      label = L('settings.informant_moves_every_h'), about = L('settings.the_informant_npc_moves_to_its'),
      inflight = NPC_MOVES },
    { key = 'Intel.InPerson.Model', section = 'limits', category = 'rules-limits', group = INTEL_IN_PERSON,
      kind = 'text', pattern = '^[%w_%-]+$', maxLength = 64, label = L('settings.informant_npc_model'),
      about = L('settings.a_gta_ped_model_name'), inflight = NPC_MOVES },
    { key = 'Intel.InPerson.Scenario', section = 'limits', category = 'rules-limits',
      group = INTEL_IN_PERSON, kind = 'text', pattern = '^[%w_%-]+$', maxLength = 64,
      label = L('settings.informant_npc_scenario'), about = L('settings.what_the_npc_does_while_it'),
      inflight = NPC_MOVES },
    { key = 'Intel.InPerson.Blip', section = 'features', category = 'features', group = INTEL_IN_PERSON,
      kind = 'switch', label = L('settings.informant_on_the_map'), about = L('settings.a_map_blip_where_the_informant'),
      inflight = NPC_MOVES },
    { key = 'Roleplay.NpcPlaces.Enabled', section = 'features', category = 'features', group = INTEL_IN_PERSON,
      kind = 'switch', label = L('settings.broker_and_informant_placed_from_the'),
      about = L('settings.the_places_staff_set_in_locations'), inflight = NPC_MOVES },

    { key = 'Roleplay.ReasonQuality.Enabled', section = 'features', category = 'features', group = RP_REASON,
      kind = 'switch', label = L('settings.reason_quality'),
      about = L('settings.a_typed_reason_needs_a_least'),
      inflight = L('settings.read_at_every_placing_and_edit') },
    { key = 'Roleplay.ReasonQuality.MinLength', section = 'limits', category = 'rules-limits',
      group = RP_REASON, kind = 'number', integer = true, min = 0, max = 255,
      label = L('settings.shortest_reason_characters'), about = L('settings.at_most_reason_maxlength'), inflight = AT_USE },
    { key = 'Roleplay.ReasonQuality.MinWords', section = 'limits', category = 'rules-limits',
      group = RP_REASON, kind = 'number', integer = true, min = 0, max = 50,
      label = L('settings.fewest_words_in_a_reason'), about = L('settings.words_are_runs_of_letters_and'), inflight = AT_USE },
    { key = 'Roleplay.ReasonQuality.LowEffort', section = 'limits', category = 'rules-limits',
      group = RP_REASON, kind = 'list', array = true, whole = true, names = 'phrase',
      label = L('settings.low_effort_phrases'), about = L('settings.matched_as_whole_words_in_any'), inflight = AT_USE },
    { key = 'Roleplay.ReasonQuality.LowEffortAction', section = 'limits', category = 'rules-limits',
      group = RP_REASON, kind = 'choice', choices = { 'refuse', 'review' },
      label = L('settings.a_low_effort_reason_is'),
      about = L('settings.refuse_refused_review_placed_and_put'),
      inflight = AT_USE },
}) do
    CATALOGUE[#CATALOGUE + 1] = entry
end

--- The improvements (server/imp_*.lua, Config.Improvements), each off as
--- shipped: the switch under Features, the rest under the rules they are.
--- Informant fairness (server/intel/rules.lua), six blocks.
local INTEL_DELAY, INTEL_LIMITS = L('settings.intel_tip_warning_delay'), L('settings.intel_tip_limits')
local INTEL_HOLD, INTEL_SECOND = L('settings.intel_hold_before_a_tip'), L('settings.intel_informant_second_try')
local INTEL_ZONES, INTEL_DARK = L('settings.intel_tip_safe_zones'), L('settings.intel_go_dark')
MONEY['Intel.TipLimits.MaxCost'] = 'Intel prices'
MONEY['Intel.SecondTry.SecondTryCostPercent'] = 'Intel prices'
MONEY['Intel.GoDark.Cost'] = 'Intel prices'
MONEY['Intel.GoDark.Account'] = 'Intel prices'
for _, entry in ipairs({
    { key = 'Intel.WarningDelay.Enabled', section = 'features', category = 'features',
      group = INTEL_DELAY, kind = 'switch', label = L('settings.delay_the_targets_tip_warning'),
      about = L('settings.the_targets_someone_knows_your_rough'),
      inflight = L('settings.read_at_every_tip_warnings_already') },
    { key = 'Intel.WarningDelay.MinSeconds', section = 'limits', category = 'rules-timers',
      group = INTEL_DELAY, kind = 'number', integer = true, min = 0, max = 3600,
      label = L('settings.shortest_warning_delay'), about = L('settings.at_most_the_longest_delay'), inflight = AT_USE },
    { key = 'Intel.WarningDelay.MaxSeconds', section = 'limits', category = 'rules-timers',
      group = INTEL_DELAY, kind = 'number', integer = true, min = 0, max = 3600,
      label = L('settings.longest_warning_delay'), about = L('settings.0_sends_the_warning_at_once'),
      inflight = AT_USE },

    { key = 'Intel.TipLimits.Enabled', section = 'features', category = 'features', group = INTEL_LIMITS,
      kind = 'switch', label = L('settings.extra_tip_limits'),
      about = L('settings.one_tip_per_hitman_per_contract'),
      inflight = L('settings.read_at_every_tip_tips_already') },
    { key = 'Intel.TipLimits.OnePerHitman', section = 'features', category = 'features',
      group = INTEL_LIMITS, kind = 'switch', label = L('settings.one_tip_per_hitman_per_contract_2'),
      about = L('settings.each_hitman_on_a_contract_buys'),
      inflight = AT_USE },
    { key = 'Intel.TipLimits.PriceDoubling', section = 'features', category = 'features',
      group = INTEL_LIMITS, kind = 'switch', label = L('settings.each_further_tip_costs_double'),
      about = L('settings.each_tip_on_a_contract_costs'),
      inflight = AT_USE },
    { key = 'Intel.TipLimits.MaxCost', section = 'limits', category = 'rules-rewards', group = INTEL_LIMITS,
      kind = 'number', integer = true, min = 0, max = 10000000, label = L('settings.most_a_doubled_tip_costs'),
      about = L('settings.never_less_than_the_price_of'), inflight = AT_USE },

    { key = 'Intel.HoldFirst.Enabled', section = 'features', category = 'features', group = INTEL_HOLD,
      kind = 'switch', label = L('settings.hold_a_contract_before_a_tip'),
      about = L('settings.a_hitman_buys_a_tip_only'), inflight = AT_USE },
    { key = 'Intel.HoldFirst.MinHeldMinutes', section = 'limits', category = 'rules-timers',
      group = INTEL_HOLD, kind = 'number', integer = true, min = 0, max = 1440,
      label = L('settings.hold_before_a_tip_min'), about = L('settings.counted_from_when_the_hitman_accepted'),
      inflight = AT_USE },

    { key = 'Intel.SecondTry.Enabled', section = 'features', category = 'features',
      group = INTEL_SECOND, kind = 'switch', label = L('settings.targets_later_look_ups_priced_apart'),
      about = L('settings.the_targets_look_ups_after_the'),
      inflight = AT_USE },
    { key = 'Intel.SecondTry.SecondTryCostPercent', section = 'limits',
      category = 'rules-rewards', group = INTEL_SECOND, kind = 'number', integer = true, min = 0, max = 1000,
      label = L('settings.later_look_ups_cost_of_the'),
      about = L('settings.100_is_the_same_price_the'), inflight = AT_USE },

    { key = 'Intel.SafeZones.Enabled', section = 'features', category = 'features', group = INTEL_ZONES,
      kind = 'switch', label = L('settings.safe_zones_for_tips'),
      about = L('settings.no_tip_is_sold_while_the'),
      inflight = AT_USE },
    { key = 'Intel.SafeZones.Zones', place = 'zone', section = 'limits', category = 'rules-targeting',
      group = INTEL_ZONES, kind = 'list', array = true, whole = true, names = 'zone',
      label = L('settings.safe_zones_x_y_radius_name'),
      about = L('settings.the_hitman_is_told_only_that'), inflight = AT_USE },

    { key = 'Intel.GoDark.Enabled', section = 'features', category = 'features', group = INTEL_DARK,
      kind = 'switch', label = L('settings.go_dark'),
      about = L('settings.a_target_told_of_a_tip'),
      inflight = L('settings.read_at_every_purchase_a_target') },
    { key = 'Intel.GoDark.Cost', section = 'limits', category = 'rules-rewards', group = INTEL_DARK,
      kind = 'number', integer = true, min = 0, max = 10000000, label = L('settings.price_to_go_dark'),
      inflight = AT_USE },
    { key = 'Intel.GoDark.Account', section = 'limits', category = 'rules-rewards', group = INTEL_DARK,
      kind = 'choice', choices = { 'bank', 'cash' }, label = L('settings.account_going_dark_is_paid_from'),
      inflight = AT_USE },
    { key = 'Intel.GoDark.Minutes', section = 'limits', category = 'rules-timers', group = INTEL_DARK,
      kind = 'number', integer = true, min = 1, max = 1440, label = L('settings.dark_for_min'),
      about = L('settings.tips_bought_on_them_meanwhile_find'),
      inflight = L('settings.a_target_already_dark_keeps_the') },
}) do
    CATALOGUE[#CATALOGUE + 1] = entry
end
--- A character's record (server/record/, Config.Record, README A hitman's
--- record): the trust a completion earns and how it is scaled, the tiered
--- board, heat and the placer's record. One screen group, Record, each
--- part its own group in it; every switch under Features, the rest under
--- the Rules view it belongs to; all read at use, with no restart.
local REC_TRUST, REC_REPUTATION = 'Record: Progression', 'Record: Reputation'
local REC_TIERS, REC_HEAT, REC_PLACER = L('settings.record_tiered_board'), L('settings.record_hitman_heat'), L('settings.record_placer_record')
for _, entry in ipairs({
    { key = 'Record.Progression.Enabled', section = 'features', category = 'features', group = REC_TRUST,
      kind = 'switch', label = L('settings.criminal_progression'), about = L('settings.completed_contracts_earn_sc_blackmarket_trust'),
      inflight = L('settings.trust_already_given_stands_completions_while') },
    { key = 'Record.Progression.TrustPerElimination', section = 'limits', category = 'rules-limits',
      group = REC_TRUST, kind = 'number', integer = true, min = 0, max = 10000,
      label = L('settings.trust_per_kill'), about = L('settings.sc_blackmarket_trust_a_completed_kill'), inflight = AT_USE },
    { key = 'Record.Progression.TrustPerKidnapping', section = 'limits', category = 'rules-limits',
      group = REC_TRUST, kind = 'number', integer = true, min = 0, max = 10000,
      label = L('settings.trust_per_live_handover'), about = L('settings.sc_blackmarket_trust_a_handover_earns'), inflight = AT_USE },

    { key = 'Record.Reputation.Enabled', section = 'features', category = 'features', group = REC_REPUTATION,
      kind = 'switch', label = L('settings.reputation_earned_in_character'),
      about = L('settings.the_progression_trust_a_completion_earns'),
      inflight = L('settings.read_at_each_completion_trust_already') },
    { key = 'Record.Reputation.BaseFactor', section = 'limits', category = 'rules-limits', group = REC_REPUTATION,
      kind = 'number', min = 0, max = 10, label = L('settings.trust_factor_for_a_plain_completion'), inflight = AT_USE },
    { key = 'Record.Reputation.ThreadBonus', section = 'limits', category = 'rules-limits', group = REC_REPUTATION,
      kind = 'number', min = 0, max = 10, label = L('settings.bonus_the_hitman_wrote_in_the'), inflight = AT_USE },
    { key = 'Record.Reputation.MeetingBonus', section = 'limits', category = 'rules-limits', group = REC_REPUTATION,
      kind = 'number', min = 0, max = 10, label = L('settings.bonus_a_meeting_point_was_set'), inflight = AT_USE },
    { key = 'Record.Reputation.HandoverBonus', section = 'limits', category = 'rules-limits', group = REC_REPUTATION,
      kind = 'number', min = 0, max = 10, label = L('settings.bonus_a_live_handover'), inflight = AT_USE },
    { key = 'Record.Reputation.WitnessFreeBonus', section = 'limits', category = 'rules-limits',
      group = REC_REPUTATION, kind = 'number', min = 0, max = 10, label = L('settings.bonus_no_witnesses'),
      inflight = AT_USE },
    { key = 'Record.Reputation.WitnessRadius', section = 'limits', category = 'rules-limits', group = REC_REPUTATION,
      kind = 'number', min = 1, max = 500, label = L('settings.witness_radius_around_the_hitman_m'), inflight = AT_USE },
    { key = 'Record.Reputation.MaxFactor', section = 'limits', category = 'rules-limits', group = REC_REPUTATION,
      kind = 'number', min = 0, max = 10, label = L('settings.most_the_trust_factor_may_reach'), inflight = AT_USE },

    { key = 'Record.PlacerRecord.Enabled', category = 'features', group = REC_PLACER,
      kind = 'switch', label = L('settings.placer_record_on_the_board'),
      about = L('settings.a_board_card_shows_how_many'),
      inflight = L('settings.at_the_next_board_read_with') },
    { key = 'Record.PlacerRecord.ShowForAnonymous', category = 'features', group = REC_PLACER,
      kind = 'switch', label = L('settings.placer_record_anonymous_placers_too'),
      about = L('settings.off_no_record_on_an_anonymous'), inflight = AT_USE },
    { key = 'Record.PlacerRecord.LookbackDays', category = 'rules-limits', group = REC_PLACER,
      kind = 'number', integer = true, min = 1, max = 365, label = L('settings.days_the_placer_record_counts'),
      inflight = AT_USE },

    { key = 'Record.Heat.Enabled', category = 'features', group = REC_HEAT,
      kind = 'switch', label = L('settings.hitman_heat'),
      about = L('settings.completions_on_whitelisted_job_targets_and'),
      inflight = L('settings.at_the_next_completion_acceptance_or') },
    { key = 'Record.Heat.ProtectedCompletionHeat', category = 'rules-limits', group = REC_HEAT,
      kind = 'number', integer = true, min = 0, max = 100, label = L('settings.heat_for_a_whitelisted_job_completion'),
      inflight = AT_USE },
    { key = 'Record.Heat.WitnessHeat', category = 'rules-limits', group = REC_HEAT,
      kind = 'number', integer = true, min = 0, max = 100, label = L('settings.heat_for_a_witness_report'),
      about = L('settings.needs_witness_heat_roleplay_on_to'), inflight = AT_USE },
    { key = 'Record.Heat.AdvisoryHeat', category = 'rules-limits', group = REC_HEAT,
      kind = 'number', integer = true, min = 0, max = 100, label = L('settings.heat_for_a_police_bulletin_on'),
      about = L('settings.an_acceptance_or_an_informant_tip'),
      inflight = AT_USE },
    { key = 'Record.Heat.Threshold', category = 'rules-limits', group = REC_HEAT,
      kind = 'number', integer = true, min = 1, max = 1000, label = L('settings.heat_at_which_a_hitman_is'),
      inflight = AT_USE },
    { key = 'Record.Heat.WarnTargetChancePercent', category = 'rules-limits', group = REC_HEAT,
      kind = 'number', integer = true, min = 0, max = 100, label = L('settings.chance_a_known_hitmans_target_is'),
      about = L('settings.100_the_paranoid_alert_always_goes'), inflight = AT_USE },
    { key = 'Record.Heat.DecayHours', category = 'rules-timers', group = REC_HEAT,
      kind = 'number', integer = true, min = 1, max = 720, label = L('settings.hours_heat_stays'),
      inflight = AT_USE },
    { key = 'Record.Heat.BulletinEveryMinutes', category = 'rules-timers', group = REC_HEAT,
      kind = 'number', integer = true, min = 0, max = 1440, label = L('settings.least_minutes_between_police_bulletins'),
      about = L('settings.0_no_bulletin'), inflight = AT_USE },
    { key = 'Record.Heat.BulletinTitle', category = 'rules-limits', group = REC_HEAT,
      kind = 'text', pattern = '^[^%c<>]+$', maxLength = 60, says = RP_TEXT,
      label = L('settings.title_of_the_police_bulletin'), inflight = AT_USE },
    { key = 'Record.Heat.BulletinText', category = 'rules-limits', group = REC_HEAT,
      kind = 'text', pattern = '^[^%c<>]+$', maxLength = 160, says = RP_TEXT,
      label = L('settings.what_the_police_bulletin_says'), about = L('settings.keep_it_vague_it_must_name'),
      inflight = AT_USE },

    { key = 'Record.Tiers.Enabled', category = 'features', group = REC_TIERS,
      kind = 'switch', label = L('settings.tiered_board'),
      about = L('settings.contracts_paying_more_are_locked_to'), inflight = L('settings.at_the_next_board_read_and') },
    { key = 'Record.Tiers.CompletionsPerLevel', category = 'rules-limits', group = REC_TIERS,
      kind = 'number', integer = true, min = 1, max = 1000, label = L('settings.completed_contracts_per_level'),
      about = L('settings.a_hitman_is_level_1_plus'),
      inflight = AT_USE },
    { key = 'Record.Tiers.Tiers', category = 'rules-limits', group = REC_TIERS,
      kind = 'list', array = true, whole = true, names = 'tier', label = L('settings.tiers_as_name_least_reward_level'),
      about = L('settings.such_as_elite_150000_4_the'), inflight = AT_USE },

}) do
    entry.section = entry.section or (entry.category == 'features' and 'features' or 'limits')
    CATALOGUE[#CATALOGUE + 1] = entry
end

--- Contract decay (server/imp_board.lua, README Optional features), off as
--- shipped: the switch under Features, the rest under the Rules view it
--- belongs to; all read at use, with no restart.
local IMP_DECAY = L('settings.improvements_contract_decay')
for _, entry in ipairs({
    { key = 'Improvements.ContractDecay.Enabled', category = 'features', group = IMP_DECAY,
      kind = 'switch', label = L('settings.contract_decay'),
      about = L('settings.an_untaken_contracts_reward_rises_each'),
      inflight = L('settings.at_the_next_tick_with_no') },
    { key = 'Improvements.ContractDecay.Mode', category = 'rules-limits', group = IMP_DECAY,
      kind = 'choice', choices = { 'rise', 'shorten' }, label = L('settings.what_decay_does'),
      about = L('settings.rise_the_reward_goes_up_shorten'), inflight = AT_USE },
    { key = 'Improvements.ContractDecay.Hours', category = 'rules-timers', group = IMP_DECAY,
      kind = 'number', integer = true, min = 1, max = 168, label = L('settings.hours_between_decay_steps'),
      inflight = AT_USE },
    { key = 'Improvements.ContractDecay.Percent', category = 'rules-rewards', group = IMP_DECAY,
      kind = 'number', integer = true, min = 1, max = 100, label = L('settings.decay_step'),
      about = L('settings.of_the_reward_at_the_first'),
      inflight = AT_USE },
    { key = 'Improvements.ContractDecay.MaxIncreasePercent', category = 'rules-rewards', group = IMP_DECAY,
      kind = 'number', integer = true, min = 0, max = 1000, label = L('settings.most_a_reward_rises_in_all'),
      inflight = AT_USE },
    { key = 'Improvements.ContractDecay.Account', category = 'rules-rewards', group = IMP_DECAY,
      kind = 'choice', choices = { 'cash', 'bank' }, label = L('settings.where_a_rise_is_charged_from'),
      inflight = AT_USE },
}) do
    entry.section = entry.category == 'features' and 'features' or 'limits'
    CATALOGUE[#CATALOGUE + 1] = entry
end
for _, key in ipairs({ 'Improvements.ContractDecay.Percent', 'Improvements.ContractDecay.MaxIncreasePercent',
    'Improvements.ContractDecay.Account' }) do
    MONEY[key] = 'Rewards'
end

--- Proof items, serial scrubbing, the weekly stats and the completion cooldown
--- (server/imp_proof.lua, imp_scrub.lua, imp_weekly.lua, targetlimits.lua).
local IMP_PROOF, IMP_SCRUB = L('settings.improvements_proof_items'), L('settings.improvements_serial_scrubbing')
local IMP_WEEKLY = L('settings.improvements_weekly_stats')
for _, entry in ipairs({
    { key = 'Improvements.ProofItems.Enabled', section = 'features', category = 'features', group = IMP_PROOF,
      kind = 'switch', label = L('settings.proof_items'),
      about = L('settings.on_a_contract_a_kill_completes'),
      inflight = L('settings.read_at_every_handover_on_the') },
    { key = 'Improvements.ProofItems.Item', section = 'limits', category = 'rules-limits', group = IMP_PROOF,
      kind = 'text', pattern = '^[%w_%-]+$', maxLength = 64, label = L('settings.proof_item'),
      about = L('settings.the_ox_inventory_item_a_hitman'), inflight = AT_USE },
    { key = 'Improvements.ProofItems.MetadataKey', section = 'limits', category = 'rules-limits',
      group = IMP_PROOF, kind = 'text', pattern = '^[%w_%-]+$', maxLength = 64,
      label = L('settings.metadata_field_that_names_the_target'),
      about = L('settings.must_hold_the_targets_citizen_id'), inflight = AT_USE },
    { key = 'Improvements.ProofItems.HandoverRadius', section = 'limits', category = 'rules-limits',
      group = IMP_PROOF, kind = 'number', min = 1, max = 50, label = L('settings.distance_to_the_placer_m'),
      about = L('settings.how_close_the_hitman_stands_to_2'), inflight = AT_USE },

    { key = 'Improvements.SerialScrub.Enabled', section = 'features', category = 'features', group = IMP_SCRUB,
      kind = 'switch', label = L('settings.weapon_serial_scrubbing'),
      about = L('settings.a_weapon_an_anonymous_placer_put'),
      inflight = L('settings.read_at_every_give_weapons_already') },

    { key = 'Improvements.WeeklyStats.Enabled', section = 'features', category = 'features', group = IMP_WEEKLY,
      kind = 'switch', label = L('settings.weekly_stats_to_discord'),
      about = L('settings.once_a_week_a_post_of'),
      inflight = L('settings.read_at_the_hour_at_most_2') },
    { key = 'Improvements.WeeklyStats.Day', section = 'limits', category = 'rules-timers', group = IMP_WEEKLY,
      kind = 'choice', choices = { 'sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday' },
      label = L('settings.day_the_weekly_stats_are_posted'), about = L('settings.server_time'),
      inflight = L('settings.read_every_tick_a_week_already') },
    { key = 'Improvements.WeeklyStats.Hour', section = 'limits', category = 'rules-timers', group = IMP_WEEKLY,
      kind = 'number', integer = true, min = 0, max = 23,
      label = L('settings.hour_the_weekly_stats_are_posted'),
      inflight = L('settings.read_every_tick_a_week_already') },

    { key = 'Limits.TargetCooldownAfterCompletionSeconds', section = 'limits', category = 'target-limits',
      group = 'Target limits', kind = 'number', integer = true, min = 0, max = 2592000,
      label = L('settings.wait_after_a_completed_contract_before'),
      about = L('settings.the_longer_of_this_and_the'), inflight = AT_USE },
}) do
    CATALOGUE[#CATALOGUE + 1] = entry
end

-- The hitman organisation's own (server/org/settings_catalogue.lua), in
-- their category, 'organisation'.
for _, entry in ipairs(CrimsonBoot.require('server.org.settings_catalogue')) do
    CATALOGUE[#CATALOGUE + 1] = entry
end
-- The step markers and body disposal (server/missionsteps.lua), in their
-- category, 'mission-steps'.
for _, entry in ipairs(CrimsonBoot.require('server.missionsteps').CATALOGUE) do
    CATALOGUE[#CATALOGUE + 1] = entry
end

local byKey = {}
for i = 1, #CATALOGUE do byKey[CATALOGUE[i].key] = CATALOGUE[i] end
for key, group in pairs(MONEY) do
    if byKey[key] then byKey[key].money = group end
end

Settings.CATALOGUE = CATALOGUE

--------------------------------------------------------------------------
-- Reading and writing a key
--------------------------------------------------------------------------

--- A deep copy (Util.copy, the one shared copy).
local copyOf = Util.copy

local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local function parts(key)
    local out = {}
    for part in key:gmatch('[^%.]+') do out[#out + 1] = part end
    return out
end

--- The value at a key in a config table, as it is stored there.
local function read(config, key)
    local node = config
    for _, part in ipairs(parts(key)) do
        if type(node) ~= 'table' then return nil end
        node = node[part]
    end
    return node
end

--- Put a value at a key in a config table. Every table on the way exists
--- once the start-up checks have run; one that does not is made.
local function write(config, key, value)
    local path = parts(key)
    local node = config
    for i = 1, #path - 1 do
        if type(node[path[i]]) ~= 'table' then node[path[i]] = {} end
        node = node[path[i]]
    end
    node[path[#path]] = value
end

--- A job list as the config holds it (a set) from how the panel shows it
--- (a sorted list), and back.
local function asSet(list)
    local set = {}
    for _, name in ipairs(list) do set[name] = true end
    return set
end

local function asList(set)
    local list = {}
    for name, on in pairs(type(set) == 'table' and set or {}) do
        if on == true and type(name) == 'string' then list[#list + 1] = name end
    end
    table.sort(list)
    return list
end

--- A key's value in the shape the panel shows it.
local function shown(entry, stored)
    if entry.kind == 'list' and entry.array then return copyOf(type(stored) == 'table' and stored or {}) end
    if entry.kind == 'list' then return asList(stored) end
    return copyOf(stored)
end

--- And in the shape the config holds it.
local function stored(entry, value)
    if entry.kind == 'list' and not entry.array then return asSet(value) end
    return copyOf(value)
end

--- What defaults.lua ships for a key, in the shape the panel shows it, or
--- nil where it ships none (a key only config.lua has).
local function shippedOf(entry)
    if type(ConfigDefaults) ~= 'table' then return nil end
    local value = read(ConfigDefaults, entry.key)
    if value == nil then return nil end
    return shown(entry, value)
end

--- Keys read once at start (inflight RESTART: the command names) changed
--- from the panel since this start: kept in the store and shown, and put
--- into Config only by the next start (Settings.init's apply). Written into
--- Config at once, every message quoted a command that was not registered
--- until then. [key] = the value as the panel shows it.
local nextStart = {}

--- What the panel would show for a key now.
local function current(entry)
    if nextStart[entry.key] ~= nil then return copyOf(nextStart[entry.key]) end
    return shown(entry, read(Config, entry.key))
end

--- Put a changed value in force: into Config, or, for a key read once at
--- start, kept for the next one (nextStart).
local function putInForce(entry, key, value)
    if entry and entry.inflight == RESTART then
        if same(value, shown(entry, read(Config, key))) then
            nextStart[key] = nil
        else
            nextStart[key] = copyOf(value)
        end
        return
    end
    write(Config, key, stored(entry, value))
end

--------------------------------------------------------------------------
-- Checking a value
--------------------------------------------------------------------------

local LIST_MAX, NAME_MAX = 50, 32

--- What one name in a list may be, by the entry's `names` (job names when
--- not given): the pattern, how long, and what the refusal says.
local NAMES = {
    job = { pattern = '^[%w_%-]+$', max = NAME_MAX, lower = true,
            says = L('settings.names_letters_digits_and_only_up') },
    item = { pattern = '^[%w_%-]+$', max = 64, says = L('settings.item_names_letters_digits_and_only') },
    mime = { pattern = '^[%w%-%.]+/[%w%-%.%+]+$', max = 64, lower = true,
             says = L('settings.image_types_such_as_image_png') },
    host = { pattern = '^[%w%-]+%.[%w%-%.]+$', max = 128, lower = true,
             says = L('settings.host_names_such_as_fivemanage_com') },
    phrase = { pattern = '^[^%c<>]+$', max = 60, says = L('settings.short_phrases_up_to_60_characters') },
    -- The roleplay lists (server/rp_places.lua, rp_consequences.lua): an NPC's
    -- place; a news template; and a named area, in either form both lists
    -- read (Places.parseArea): 'Name@x,y' (witness heat and city news) or
    -- 'x, y, name' (the rumours' districts).
    point = { pattern = '^[%d%s%.,%-]+$', max = 60, says = L('settings.places_as_x_y_z_heading') },
    sentence = { pattern = '^[^%c<>]+$', max = 160, says = L('settings.sentences_up_to_160_characters_no') },
    area = { patterns = { '^[^%c<>@]+@%s*%-?%d+%.?%d*%s*,%s*%-?%d+%.?%d*$',
                          '^%s*%-?%d+%.?%d*%s*,%s*%-?%d+%.?%d*%s*,[^%c<>@]+$' }, max = 60,
             says = L('settings.areas_as_name_x_y_or') },
    -- The tiered board (Record.parseTier, server/record/): 'name, least reward, level'.
    tier = { pattern = '^[^%c<>,]+,%s*%d+%s*,%s*%d+$', max = 60,
             says = L('settings.tiers_as_name_least_reward_level_2') },
    -- A tip safe zone (server/intel/rules.lua, IntelRules.parseZone): 'x, y, radius, name'.
    zone = { pattern = '^%s*%-?%d+%.?%d*%s*,%s*%-?%d+%.?%d*%s*,%s*%d+%.?%d*%s*,[^%c<>]+$', max = 80,
             says = L('settings.zones_as_x_y_radius_name') },
}

--- Whether one typed name keeps its list's rule: its pattern, or any one of
--- its patterns.
local function nameFits(rule, name)
    if rule.pattern and name:match(rule.pattern) then return true end
    for _, pattern in ipairs(rule.patterns or {}) do
        if name:match(pattern) then return true end
    end
    return false
end

--- The most a number key takes now: its own max, or less where another
--- setting caps it (`ceiling`, a key read from the config in force).
---@param entry table
---@return number|nil
---@param config table|nil the config to read the ceiling from (the live one by default)
function Settings.maxOf(entry, config)
    local ceiling = entry.ceiling and tonumber(read(config or Config, entry.ceiling))
    if ceiling and (not entry.max or ceiling < entry.max) then return ceiling end
    return entry.max
end

--- The keys some other key's range is capped by (an entry's `ceiling`).
local CEILINGS = {}
for i = 1, #CATALOGUE do
    if CATALOGUE[i].ceiling then CEILINGS[CATALOGUE[i].ceiling] = true end
end

--- A list of keys in the order a batch checks and applies them: every key
--- that caps another first, then the rest, each part by name. Checked by
--- name alone, 'Ledger.Depth' came before 'Ledger.MaxDepthHardCap' and was
--- refused against the ceiling the same batch was raising.
---@param keys string[] sorted in place
---@return string[] keys
function Settings.order(keys)
    table.sort(keys, function(a, b)
        local ca, cb = CEILINGS[a] == true, CEILINGS[b] == true
        if ca ~= cb then return ca end
        return tostring(a) < tostring(b)
    end)
    return keys
end

--- Whether two values are the same value (a list, a range, a number).
---@return boolean
function Settings.same(a, b) return same(a, b) end

--- A batch of values checked as Settings.boot loads them: in `keys` order,
--- then again in passes, each key refused retried against every value
--- accepted so far, until a pass accepts nothing more. Checked once, a key
--- refused against the live value of another the same batch changes (one
--- of a linked pair, Buyout pricing's least and most) was refused, and
--- the batch applied half the pair. Every batch the panel applies (an
--- import, a preset, the setup) checks through here and sets in the order
--- returned, so each set sees the ones before it live.
---@param keys string[] in Settings.order order
---@param valueFor fun(key: string): any the raw value for a key
---@return table[] accepted { { key, value } } in the order they were accepted
---@return table[] refused { { key, why } } with the last pass's refusal
---@return table with every accepted key's checked value
function Settings.checkInPasses(keys, valueFor)
    local accepted, with, waiting = {}, {}, {}
    for _, key in ipairs(keys) do waiting[#waiting + 1] = { key = key } end
    local progressed = true
    while progressed and #waiting > 0 do
        progressed = false
        local still = {}
        for _, w in ipairs(waiting) do
            local value, _, why = Settings.check(w.key, Util.copy(valueFor(w.key)), with)
            if value == nil then
                w.why = tostring(why or 'refused')
                still[#still + 1] = w
            else
                progressed = true
                with[w.key] = value
                accepted[#accepted + 1] = { key = w.key, value = value }
            end
        end
        waiting = still
    end
    return accepted, waiting, with
end

--- Whether a start-up line names a key: in full, or by its last part where
--- no other key on the list ends in it ('MinMultiplier', not 'Enabled').
local lastParts = {}
for i = 1, #CATALOGUE do
    local last = CATALOGUE[i].key:match('([%w_]+)$')
    lastParts[last] = (lastParts[last] or 0) + 1
end
local function names(line, key)
    line = tostring(line)
    if line:find(key, 1, true) then return true end
    local last = key:match('([%w_]+)$')
    return lastParts[last] == 1 and #last >= 8 and line:find(last, 1, true) ~= nil
end

--- A start-up line as the reason a change is refused: what it says without
--- the start's own correction ("Using the lifetime."), which the panel does
--- not make, and naming the key once. Read as "Not changed: <key> <line>
--- Using X..", it said both that nothing changed and that something else
--- was used, and not what to do. `other` is the key to change first.
---@param key string
---@param line string
---@param other string|nil
---@return string
local function refusal(key, line, other)
    local text = tostring(line):gsub('[%.;]%s+[Uu]sing .*$', ''):gsub('[%s%.]+$', '')
    if not names(text, key) then text = key .. ' ' .. text end
    if other and other ~= key then text = (L('settings.change_first')):format(text, other) end
    return text
end

--- Why a change would leave a bucket the app cannot work without below its
--- floor (BUCKET_FLOORS), or nil. Only for the keys being changed, and not
--- for one put back to what config.lua says.
---@param changes table [key] = value
---@param candidate table the config with the changes in it
---@return string|nil
local function belowFloor(changes, candidate)
    for key, value in pairs(changes) do
        local bucket = key:match('^Cooldowns%.([%w_]+)%.%a+$')
        local floor = bucket and BUCKET_FLOORS[bucket]
        if floor and not same(value, defaults[key]) then
            local rule = read(candidate, 'Cooldowns.' .. bucket)
            local per = type(rule) == 'table' and tonumber(rule.per)
            local burst = type(rule) == 'table' and tonumber(rule.burst)
            if per and burst and per > 0 and ((floor.burst and burst < floor.burst)
                or (floor.rate and burst / per < floor.rate)) then
                return (L('settings.would_leave_below_what_it_needs')):format(key, bucket,
                    floor.needs, floor.why)
            end
        end
    end
    return nil
end

--- A value the panel sent, in the type and range the key takes, or nil
--- and why not. Nothing here trusts what the page sent: a number arrives
--- as a number or as digits, a switch as a boolean, a list as job names.
---@return any value
---@return string|nil why
---@param config table|nil the config a `ceiling` is read from (the live one by default)
local function normalise(entry, raw, config)
    if entry.kind == 'switch' then
        if type(raw) ~= 'boolean' then return nil, L('settings.has_to_be_on_or_off') end
        return raw
    end
    if entry.kind == 'choice' then
        for _, choice in ipairs(entry.choices) do
            if raw == choice then return raw end
        end
        return nil, (L('settings.has_to_be_one_of')):format(table.concat(entry.choices, ', '))
    end
    if entry.kind == 'number' then
        local n = (type(raw) == 'number' or type(raw) == 'string') and tonumber(raw) or nil
        if not n or n ~= n or n == math.huge or n == -math.huge then
            return nil, L('settings.has_to_be_a_number')
        end
        if entry.integer then
            if math.floor(n) ~= n then return nil, L('settings.has_to_be_a_whole_number') end
            n = math.tointeger(n) or n
        end
        local max = Settings.maxOf(entry, config)
        if (entry.min and n < entry.min) or (max and n > max) then
            return nil, (L('settings.has_to_be_from_to')):format(tostring(entry.min), tostring(max))
        end
        return n
    end
    if entry.kind == 'list' then
        local rule = NAMES[entry.names or 'job']
        if type(raw) ~= 'table' then return nil, L('settings.has_to_be_a_list') .. rule.says end
        if #raw > LIST_MAX then return nil, (L('settings.takes_at_most_names')):format(LIST_MAX) end
        for k in pairs(raw) do
            if math.type(k) ~= 'integer' or k < 1 or k > #raw then return nil, L('settings.has_to_be_a_list_2') end
        end
        local seen, out = {}, {}
        for i = 1, #raw do
            local name = raw[i]
            if type(name) == 'string' then name = name:gsub('^%s+', ''):gsub('%s+$', '') end
            if type(name) ~= 'string' or #name == 0 or #name > rule.max or not nameFits(rule, name) then
                return nil, rule.says
            end
            if rule.lower then name = name:lower() end
            if not seen[name] then
                seen[name] = true
                out[#out + 1] = name
            end
        end
        if not entry.array then table.sort(out) end
        return out
    end
    if entry.kind == 'text' then
        if type(raw) ~= 'string' or #raw == 0 or #raw > (entry.maxLength or 64)
            or not raw:match(entry.pattern or '^[%w_%-]+$') then
            return nil, (L('settings.has_to_be_up_to_long')):format(entry.says or L('settings.letters_digits_dash_underscore_only'),
                entry.maxLength or 64)
        end
        return raw
    end
    if entry.kind == 'range' then
        if type(raw) ~= 'table' then return nil, L('settings.has_to_be_a_pair_from') end
        for k in pairs(raw) do
            if k ~= 'min' and k ~= 'max' then return nil, L('settings.has_to_be_a_pair_from') end
        end
        local lo, hi = tonumber(raw.min), tonumber(raw.max)
        if not lo or not hi or lo ~= lo or hi ~= hi then return nil, L('settings.has_to_be_two_numbers') end
        if entry.integer and (math.floor(lo) ~= lo or math.floor(hi) ~= hi) then
            return nil, L('settings.has_to_be_whole_numbers')
        end
        if lo < (entry.min or -math.huge) or hi > (entry.max or math.huge) then
            return nil, (L('settings.has_to_be_within_to')):format(tostring(entry.min), tostring(entry.max))
        end
        if lo > hi then return nil, L('settings.has_its_from_above_its_to') end
        if entry.integer then lo, hi = math.tointeger(lo) or lo, math.tointeger(hi) or hi end
        return { min = lo, max = hi }
    end
    return nil, L('settings.cannot_be_changed_here')
end

--- Whether a set of changes passes the start-up checks, run against a copy
--- of the live config with the changes in it (main.lua's checkConfig).
---
--- Refused when the checks would refuse to start on it, or would quietly
--- change any key the panel shows: a value they correct at start is one
--- that would not mean what staff set it to. Their own words are the reason.
---
--- A bucket the app cannot work without is held to its floor as well
--- (BUCKET_FLOORS). What passes answers, third, the start's warnings: they
--- refuse nothing, and staff are told the ones that name a key changed.
---@param changes table [key] = value as the panel shows it
---@return boolean ok
---@return string|nil reason
---@return string[]|nil warn on success, every warning the checks gave
---@return string|nil other on refusal, another key the checks would change
local function fits(changes)
    if not Check then return true, nil, {} end
    local candidate = copyOf(Config)
    -- A restart-only key changed since this start is checked as the next
    -- start will run it: left at the value in force, every later change was
    -- refused as one that "would change" it (sweep 4 D1).
    for key, value in pairs(nextStart) do
        if byKey[key] then write(candidate, key, stored(byKey[key], value)) end
    end
    for key, value in pairs(changes) do write(candidate, key, stored(byKey[key], value)) end
    local floor = belowFloor(changes, candidate)
    if floor then return false, floor end
    local ok, fatal, warn = Check(candidate)
    fatal, warn = fatal or {}, warn or {}
    if not ok or #fatal > 0 then
        local line = tostring(fatal[1] or L('settings.the_start_up_checks_refuse_it'))
        -- Another key the line names, to change first.
        local other
        for _, entry in ipairs(CATALOGUE) do
            if not other and not entry.readonly and changes[entry.key] == nil
                and names(line, entry.key) then
                other = entry.key
            end
        end
        return false, line, nil, other
    end
    for _, entry in ipairs(CATALOGUE) do
        if not entry.readonly then
            local wanted = changes[entry.key]
            if wanted == nil then wanted = current(entry) end
            local got = shown(entry, read(candidate, entry.key))
            if not same(got, wanted) then
                for _, line in ipairs(warn) do
                    if names(line, entry.key) then return false, line, nil, entry.key end
                end
                return false, (L('settings.would_make_the_start_up_checks')):format(entry.key),
                    nil, entry.key
            end
        end
    end
    return true, nil, warn
end

--- What the start-up checks say of the settings in force now, for the
--- config check (server/configcheck.lua): their refusals and their
--- warnings, run on a copy, changing nothing.
---@return string[] fatal
---@return string[] warn
function Settings.configWarnings()
    if not Check then return {}, {} end
    local called, okOrErr, fatal, warn = pcall(Check, copyOf(Config))
    if not called then return { L('settings.the_start_up_checks_raised') .. tostring(okOrErr) }, {} end
    return fatal or {}, warn or {}
end

--- A value for a key, checked as the start-up checks would check it.
---@param key string
---@param raw any
---@return any value as the panel shows it, or nil
---@return string|nil err 'not_allowed' | 'read_only' | 'invalid_value'
---@return string|nil why a sentence that names the key, without its full stop
---@return string[]|nil warnings with a value: the start's warnings that name
--- the key, which refuse nothing and were said nowhere (W145)
---@param with table|nil [key] = value: other values checked to go in beside
--- this one (an import, a preset, the setup), so a key is checked against a
--- ceiling raised in the same batch (Settings.order puts ceilings first)
function Settings.check(key, raw, with)
    if type(key) == 'string' and DENY[key] then return nil, 'read_only', DENY[key].why end
    local entry = type(key) == 'string' and byKey[key] or nil
    if not entry then return nil, 'not_allowed', L('settings.not_a_setting_the_panel_may') end
    if entry.readonly then return nil, 'read_only', entry.readonly end
    local changes, config = { [key] = true }, nil
    if type(with) == 'table' and next(with) ~= nil then
        config = copyOf(Config)
        changes = {}
        for k, v in pairs(with) do
            if byKey[k] and k ~= key then
                write(config, k, stored(byKey[k], v))
                changes[k] = v
            end
        end
    end
    local value, why = normalise(entry, raw, config)
    if value == nil then return nil, 'invalid_value', refusal(key, why) end
    changes[key] = value
    local ok, reason, warn, other = fits(changes)
    if not ok then return nil, 'invalid_value', refusal(key, reason, other) end
    local said = {}
    for _, line in ipairs(warn or {}) do
        if names(line, key) then said[#said + 1] = line end
    end
    return value, nil, nil, said
end

--------------------------------------------------------------------------
-- Changing a key
--------------------------------------------------------------------------

--- A change being saved (set, reset, reset all): only one runs at a time.
---
--- Each is checked against the config in force, then waits on the store (a
--- yield on mysql), then applied. Two at once were each checked against the
--- config from before the other: a least buyout of 2.5 and a most of 2,
--- each fine beside what was in force, both passed, and the server ran on a
--- pair the start-up checks call fatal, which the next start then dropped
--- one of. The second is refused as busy, and staff ask again.
--- One key for every change (Lock), so only one runs at a time.
local SaveLock = Lock.new({ busy = function() return L('settings.another_change_to_the_settings_is') end })
local SAVING = 'settings'

--- Moved by every init: what each catalogue entry says of itself, and the
--- defaults read here, are fixed until the next (Settings.schemaVersion).
local schemaVersion = 0

--- Which version of the entries' fixed parts (label, help, limits,
--- defaults) the panel is shown: the same number, the same parts. The
--- admin panel sends them once and then only the values (server/panel.lua).
---@return integer
function Settings.schemaVersion()
    return schemaVersion
end

function Settings.init(deps)
    schemaVersion = schemaVersion + 1
    Storage, Audit, Check = deps.storage, deps.audit, deps.check
    overrides, ignored, unknown, nextStart = {}, {}, {}, {}
    SaveLock.reset()
    -- What config.lua says, as the start-up checks left it. Taken here so a
    -- stack that never boots still knows what a reset puts back.
    defaults = {}
    for _, entry in ipairs(CATALOGUE) do defaults[entry.key] = current(entry) end
end

--- The log written now, and on json to the disk as well: a setting staff
--- changed is the record of how the server was run, and the store is where
--- the next start finds it.
local function flushNow()
    pcall(Audit.flush)
    if Storage.flush then pcall(Storage.flush) end
end

--- Values of the keys players' games read, for the client's copy of the
--- config, or nil when every one of them is what config.lua says.
---@param always boolean|nil every one, whatever it says
---@return table|nil [key] = value
function Settings.clientValues(always)
    local out, any = {}, false
    for _, entry in ipairs(CATALOGUE) do
        if entry.client then
            out[entry.key] = current(entry)
            if overrides[entry.key] then any = true end
        end
    end
    if not (always or any) then return nil end
    return out
end

--- Tell whoever needs telling that a key changed: players' games for a key
--- they read, and the hook Bridges installs.
local function changed(entry)
    if entry.client then
        TriggerClientEvent('crimson-hitman:settings', -1, Settings.clientValues(true))
    end
    if Settings.onChanged then pcall(Settings.onChanged, entry.key, entry) end
    local watcher = watchers[entry.key]
    if watcher then
        local ok, err = pcall(watcher, entry.key)
        if not ok then
            Log.always(('the change to %s is in force, but what follows it raised: %s')
                :format(entry.key, tostring(err)))
        end
    end
end

--- Whether a write that raised landed after all, read back from the store
--- as the money paths read theirs: true when the store holds `expected`
--- for the key (nothing at all, for a delete), false when it does not, and
--- nil, with why, when the read raised too. A commit followed by a dropped
--- connection raises, and "Nothing changed" said then left config.lua's
--- value in force over a row the next start applied.
---@param key string
---@param expected any the value written, or nil for a delete
---@return boolean|nil landed
---@return string|nil why
local function landed(key, expected)
    local ok, rows = pcall(Storage.readSettings)
    if not ok or type(rows) ~= 'table' then return nil, Util.dbError(rows) end
    local row = rows[key]
    if expected == nil then return row == nil end
    return type(row) == 'table' and same(row.value, expected)
end

--- A key the store may or may not hold the change for, kept for the
--- diagnosis (Settings.active) until a change to it, or the next start.
local function markUnknown(key, why, staff)
    unknown[key] = { why = tostring(why), by = staff, at = os.time() }
    Log.always(('the admin panel change to %s raised in the store, and reading it back raised '
        .. 'too (%s): the store may or may not hold it. It is not in force; set or reset it again '
        .. 'once the store answers.'):format(key, tostring(why)))
end

--- What follows a change the store has kept: the audit row, the log
--- written, and whoever needs telling. Each in its own pcall: one that
--- raised after the commit answered the change as an error, with no row
--- and nobody told, though it was in force and kept.
local function committed(entry, action, actorCid, detail)
    local okAudit, auditErr = pcall(Audit.staff, action, actorCid, nil, detail)
    if not okAudit then
        Log.always(('the admin panel %s is in force and kept, but its audit row raised: %s')
            :format(detail.key and ('change to ' .. tostring(detail.key)) or 'reset of every setting',
                tostring(auditErr)))
    end
    flushNow()
    if entry then
        local okTold, toldErr = pcall(changed, entry)
        if not okTold then
            Log.debug(('players\' games were not told of the change to %s: %s')
                :format(entry.key, tostring(toldErr)))
        end
    end
end

local function setKey(key, raw, staff, actorCid, basis)
    local value, err, why, warnings = Settings.check(key, raw)
    if value == nil then return false, err, why end
    local entry = byKey[key]
    local old = current(entry)

    -- The value in force already: nothing written, recorded or told. Set
    -- again from a stale page, a switch to what it was re-sent every
    -- barred player the 'Closed to you' notice and every phone its access.
    -- Not for a key the store holds something else for (not applied, or
    -- not known): writing it is what settles that row.
    if same(value, old) and not ignored[key] and not unknown[key] then
        return true, nil, { key = key, value = copyOf(value), old = old, unchanged = true,
                            source = overrides[key] and 'panel' or 'config', warnings = warnings }
    end

    -- Made from a value that is no longer the one in force (another staff
    -- member changed it since this page read it, an Undo of an older row):
    -- refused, never written over the newer change. Checked under the save
    -- lock, so two saves from the same page read cannot both pass.
    if basis ~= nil and not same(normalise(entry, basis) or basis, old) then
        return false, 'changed_since', { key = key, value = old }
    end

    local backToConfig = same(value, defaults[key])
    local at = os.time()

    local wrote, writeErr
    if backToConfig then
        wrote, writeErr = pcall(Storage.deleteSetting, key)
    else
        wrote, writeErr = pcall(Storage.writeSetting, key, copyOf(value), staff, at)
    end
    if not wrote then
        local expected = nil
        if not backToConfig then expected = value end
        local kept, readErr = landed(key, expected)
        if kept == nil then
            markUnknown(key, readErr, staff)
            return false, 'store_unknown', Util.dbError(writeErr)
        end
        if not kept then return false, 'store_failed', Util.dbError(writeErr) end
        Log.debug(('the admin panel change to %s raised in the store (%s), and the store holds it: '
            .. 'applied'):format(key, Util.dbError(writeErr)))
    end

    putInForce(entry, key, value)
    if backToConfig then
        overrides[key] = nil
    else
        overrides[key] = { value = copyOf(value), by = staff, at = at }
    end
    ignored[key], unknown[key] = nil, nil

    committed(entry, 'admin_setting_changed', actorCid, {
        key = key, old = old, new = copyOf(value), by = staff,
        source = backToConfig and 'config' or 'panel',
    })
    return true, nil, { key = key, value = copyOf(value), old = old,
                        source = backToConfig and 'config' or 'panel', warnings = warnings }
end

--- Change a key live and keep it over config.lua.
---
--- A value equal to what config.lua says takes the override away instead:
--- the key is then config.lua's again, as a reset would leave it.
---@param key string
---@param raw any
---@param staff string|nil who, for the record ('console' at the console)
---@param actorCid string|nil their citizen id, for the audit row
---@param basis any|nil the value the change was made from (the page's read):
---     refused with 'changed_since' when it is no longer the one in force
---@return boolean ok
---@return string|nil err also 'busy' while another change is being saved
---@return any detail the reason, or { key, value, old, source } on success
function Settings.set(key, raw, staff, actorCid, basis)
    return SaveLock.run(SAVING, setKey, key, raw, staff, actorCid, basis)
end

--- One key back to what config.lua says. A key read-only now whose stored
--- value was not applied at start (one changeable before, say) has its row
--- taken away all the same: nothing in force changes, and it stops being
--- listed as not applied. So does a row for a key the catalogue does not
--- list at all (one from another version), which every start said to reset
--- in the panel and the panel had no row for.
local function resetKey(key, staff, actorCid)
    local entry = type(key) == 'string' and byKey[key] or nil
    local stray = type(key) == 'string' and not entry and (ignored[key] or unknown[key]) ~= nil
    if not entry and not stray then
        return false, 'not_allowed', L('settings.not_a_setting_the_panel_may')
    end
    if entry and entry.readonly and not ignored[key] then return false, 'read_only', entry.readonly end
    if not overrides[key] and not ignored[key] and not unknown[key] then
        return false, 'not_overridden', L('settings.it_is_what_config_lua_says')
    end
    -- What config.lua says passed the start-up checks on its own, but not
    -- necessarily beside the other overrides still in force: a least
    -- buyout put back under a most one changed from here.
    if overrides[key] then
        local ok, reason, _, other = fits({ [key] = defaults[key] })
        if not ok then return false, 'invalid_value', refusal(key, reason, other) end
    end
    local wrote, writeErr = pcall(Storage.deleteSetting, key)
    if not wrote then
        local gone, readErr = landed(key, nil)
        if gone == nil then
            markUnknown(key, readErr, staff)
            return false, 'store_unknown', Util.dbError(writeErr)
        end
        if not gone then return false, 'store_failed', Util.dbError(writeErr) end
    end

    local old = entry and current(entry) or copyOf((ignored[key] or {}).value)
    if entry then putInForce(entry, key, defaults[key]) end
    local had = overrides[key] ~= nil
    overrides[key], ignored[key], unknown[key] = nil, nil, nil
    committed(had and entry or nil, 'admin_setting_reset', actorCid,
        { key = key, old = old, new = copyOf(defaults[key]), by = staff })
    return true, nil, { key = key, value = copyOf(defaults[key]), old = old, source = 'config',
                        removed = not entry or nil }
end

--- Put one key back to what config.lua says.
---@return boolean ok
---@return string|nil err 'not_allowed' | 'read_only' | 'not_overridden' | 'invalid_value' |
--- 'store_failed' | 'busy'
---@return any detail
function Settings.reset(key, staff, actorCid)
    return SaveLock.run(SAVING, resetKey, key, staff, actorCid)
end

local function resetEvery(staff, actorCid)
    local keys = {}
    for key in pairs(overrides) do keys[#keys + 1] = key end
    for key in pairs(ignored) do if not overrides[key] then keys[#keys + 1] = key end end
    for key in pairs(unknown) do
        if not overrides[key] and not ignored[key] then keys[#keys + 1] = key end
    end
    table.sort(keys)

    -- Which rows went: every one, or, when the clear raised, the ones the
    -- store no longer holds (read back, as a change is).
    local gone = {}
    local wrote, writeErr = pcall(Storage.clearSettings)
    if wrote then
        for _, key in ipairs(keys) do gone[key] = true end
    else
        local ok, rows = pcall(Storage.readSettings)
        if not ok or type(rows) ~= 'table' then
            for _, key in ipairs(keys) do
                if not unknown[key] then markUnknown(key, Util.dbError(rows), staff) end
            end
            return false, 'store_unknown', Util.dbError(writeErr)
        end
        for _, key in ipairs(keys) do gone[key] = rows[key] == nil end
    end

    local changes, touched, done, kept = {}, {}, {}, 0
    for _, key in ipairs(keys) do
        if gone[key] then
            local entry = byKey[key]
            if entry and overrides[key] then
                changes[key] = { old = current(entry), new = copyOf(defaults[key]) }
                putInForce(entry, key, defaults[key])
                touched[#touched + 1] = entry
            end
            overrides[key], ignored[key], unknown[key] = nil, nil, nil
            done[#done + 1] = key
        else
            kept = kept + 1
        end
    end
    if #done == 0 and kept > 0 then return false, 'store_failed', Util.dbError(writeErr) end

    committed(nil, 'admin_settings_reset_all', actorCid,
        { keys = done, changes = changes, by = staff, kept = kept > 0 and kept or nil })
    for _, entry in ipairs(touched) do
        local okTold, toldErr = pcall(changed, entry)
        if not okTold then
            Log.debug(('players\' games were not told of the change to %s: %s')
                :format(entry.key, tostring(toldErr)))
        end
    end
    if kept > 0 then
        return false, 'store_failed', (L('settings.were_reset_and_are_still_kept'))
            :format(Util.dbError(writeErr), #done, kept)
    end
    return true, nil, { keys = #done }
end

--- Put every key back to what config.lua says.
---@return boolean ok
---@return string|nil err 'store_failed' | 'busy'
---@return any detail { keys = n }
function Settings.resetAll(staff, actorCid)
    return SaveLock.run(SAVING, resetEvery, staff, actorCid)
end

--------------------------------------------------------------------------
-- At start
--------------------------------------------------------------------------

--- Apply what the store holds over config.lua. Run at start, right after
--- the start-up checks and before anything reads the config.
---
--- The overrides are checked again against config.lua as it now is, all of
--- them together, as they stood together in force when the server stopped.
--- One at a time, each was checked beside config.lua and only the ones
--- before it in sort order: a least buyout of 0.5 and a most of 0.8, set in
--- that order and each fine beside the other, sorted Max before Min, and the
--- most was refused beside config.lua's least of 1 and dropped at every
--- restart. Only when the set as a whole fails are they tried one at a time,
--- in passes until a pass applies nothing more, so that the order they sort
--- in decides nothing. One the catalogue no longer lists, one read-only, or
--- one config.lua has made invalid (a most buyout now under a least one an
--- owner raised in the file) is not applied, and is said so in the console
--- and in /ch-diag until staff reset it.
---@return integer applied
function Settings.boot()
    local ok, rows = pcall(Storage.readSettings)
    if not ok then
        Log.problem(('warning: could not read the settings changed from the admin '
            .. 'panel (%s); config.lua is used as it stands.'):format(tostring(rows)))
        return 0
    end
    local keys = {}
    for key in pairs(type(rows) == 'table' and rows or {}) do keys[#keys + 1] = key end
    Settings.order(keys)

    local function rowOf(key) return type(rows[key]) == 'table' and rows[key] or {} end
    local function notApplied(key, why)
        local row = rowOf(key)
        ignored[key] = { value = copyOf(row.value), by = row.by, at = row.at, why = tostring(why) }
        Log.problem(('warning: the admin panel setting %s is not applied: %s. '
            .. 'config.lua\'s value is used; reset it in the panel to clear this.')
            :format(key, tostring(why)))
    end

    -- Each value first as the panel would take it, on its own: a ceiling
    -- read from the config with the stored ceilings in it (they come first),
    -- or a value valid only under a ceiling raised from the panel was
    -- dropped at every restart. The checks below still refuse a pair that
    -- does not fit together.
    local ceilings = copyOf(Config)
    local wanted, order = {}, {}
    for _, key in ipairs(keys) do
        local entry = byKey[key]
        -- Read as it is, not through `and ... or`: a switch turned off is
        -- false, and `row and row.value or nil` read it as nothing at all.
        local raw = rowOf(key).value
        local value, why
        if not entry then
            why = L('settings.not_a_setting_the_panel_may')
        elseif entry.readonly then
            why = entry.readonly
        else
            value, why = normalise(entry, raw, ceilings)
        end
        if value == nil then
            notApplied(key, why or 'invalid_value')
        else
            wanted[key] = value
            order[#order + 1] = key
            if CEILINGS[key] then write(ceilings, key, stored(entry, value)) end
        end
    end

    -- Then together; and only if that fails, one at a time in passes.
    local applied = {}
    if fits(wanted) then
        for _, key in ipairs(order) do applied[key] = wanted[key] end
    else
        local left = order
        repeat
            local rest, progressed = {}, false
            for _, key in ipairs(left) do
                local candidate = copyOf(applied)
                candidate[key] = wanted[key]
                if fits(candidate) then
                    applied[key] = wanted[key]
                    progressed = true
                else
                    rest[#rest + 1] = key
                end
            end
            left = rest
        until not progressed or #left == 0
        for _, key in ipairs(left) do
            local candidate = copyOf(applied)
            candidate[key] = wanted[key]
            local _, reason = fits(candidate)
            notApplied(key, reason or L('settings.the_start_up_checks_refuse_it'))
        end
    end

    local said = {}
    for _, key in ipairs(order) do
        local value = applied[key]
        if value ~= nil then
            local row = rowOf(key)
            write(Config, key, stored(byKey[key], value))
            overrides[key] = { value = copyOf(value), by = row.by, at = row.at }
            said[#said + 1] = ('%s = %s'):format(key, Settings.describe(value))
        end
    end
    if #said > 0 then
        Log.debug(('%d setting(s) changed from the admin panel are in force over '
            .. 'config.lua: %s'):format(#said, table.concat(said, ', ')))
    end
    return #said
end

--------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------

--- A value in words, for the console and /ch-diag.
---@param value any
---@return string
function Settings.describe(value)
    if type(value) == 'boolean' then return value and L('settings.on') or L('settings.off') end
    -- A range ({ min, max }): table.concat reads only a list, so every
    -- range read '[]' and compared equal to every other.
    if type(value) == 'table' and value.min ~= nil and value.max ~= nil and value[1] == nil then
        return (L('settings.range_from_to')):format(tostring(value.min), tostring(value.max))
    end
    if type(value) == 'table' then return '[' .. table.concat(value, ', ') .. ']' end
    return tostring(value)
end

--- The feature area each group is shown under in the admin panel's Game
--- rules (a setting's `area`): staff find a feature's switch, numbers and
--- lists on one page, whatever kind of value each is. A group not named
--- here is 'other'; the Developer section's own groups are 'engine'.
local AREA_OF_GROUP = {
    ['Access'] = 'access', ['The app'] = 'access', ['Barred jobs'] = 'access',
    ['Anti-collusion'] = 'access',
    ['Contract limits'] = 'placing', ['Contract reasons'] = 'placing', ['Roleplay: Reason quality'] = 'placing',
    ['Proposals'] = 'placing', ['Stakes'] = 'placing', ['Targeting'] = 'placing', ['Immunity'] = 'placing',
    ['Improvements: Contract decay'] = 'placing',
    ['Anonymity'] = 'anonymity', ['Anonymity (whitelisted-job targets)'] = 'anonymity',
    ['Improvements: Serial scrubbing'] = 'anonymity',
    ['Rewards'] = 'rewards', ['Payouts'] = 'rewards', ['Roleplay: Dirty money payouts'] = 'rewards',
    ['Completion'] = 'completing', ['Handovers'] = 'completing', ['Ledger'] = 'completing',
    ['The clock'] = 'completing', ['Server restart'] = 'completing',
    ['Roleplay: EMS before re-listing'] = 'completing', ['Roleplay: Proof of intent'] = 'completing',
    ['Improvements: Proof items'] = 'completing',
    ['Buyouts'] = 'buyouts', ['Buyout pricing'] = 'buyouts',
    -- Intel (server/intel/): every paid look-up, its rules, going dark, the
    -- informant in person and the rumours, one screen group.
    ['Intel: Informants'] = 'intel', ['Intel prices'] = 'intel', ['Intel: Informant tip'] = 'intel',
    ['Intel: Every other target'] = 'intel', ['Intel: Whitelisted-job targets'] = 'intel',
    ['Intel: Informant in person'] = 'intel', ['Intel: Rumours and broker'] = 'intel',
    ['Intel: Tip warning delay'] = 'intel', ['Intel: Tip limits'] = 'intel',
    ['Intel: Hold before a tip'] = 'intel', ['Intel: Informant second try'] = 'intel',
    ['Intel: Tip safe zones'] = 'intel', ['Intel: Go dark'] = 'intel',
    ['Law enforcement advisory'] = 'police', ['Advisory job lists'] = 'police',
    ['Roleplay: Witness heat'] = 'police', ['Roleplay: City news'] = 'police',
    ['Messages and calls'] = 'messages', ['Notifications'] = 'messages', ['Roleplay: Burner phone'] = 'messages',
    ['Roleplay: Bodyguards'] = 'extras', ['Roleplay: Hit on the hitman'] = 'extras',
    -- A character's record (server/record/): trust, reputation, the tiered
    -- board, heat and the placer's record, one screen group.
    ['Record: Progression'] = 'record', ['Record: Reputation'] = 'record', ['Record: Tiered board'] = 'record',
    ['Record: Hitman heat'] = 'record', ['Record: Placer record'] = 'record',
    ['Staff tools'] = 'staff', ['Staff alerts'] = 'staff', ['Audit and debug'] = 'staff', ['Staff'] = 'staff',
    ['Improvements: Weekly stats'] = 'staff',
    ['Storage'] = 'engine', ['Rate limits'] = 'engine', ['Diagnostics'] = 'engine', ['Staff commands'] = 'engine', ['Other scripts'] = 'engine',
    ['Edit in config.lua'] = 'engine', ['Kept in the store, not on this list'] = 'engine',
    ['Target limits'] = 'targets',
    ['Organisation'] = 'organisation', ['Organisation: Boss limits'] = 'organisation',
    -- The step markers and body disposal (server/missionsteps.lua): steps
    -- of completing a contract.
    ['Step markers'] = 'completing', ['Body disposal'] = 'completing',
}
Settings.AREA_OF_GROUP = AREA_OF_GROUP

--- Each group's label, by key: a group is named in English in the catalogue
--- (its id, read by AREA_OF_GROUP, MONEY and the page's own checks), and
--- shown in the language Config.Locale names (Settings.view's groupLabel),
--- looked up each time it is read. [group] = locale key
local GROUP_LABEL = {
    ['Access'] = 'settings_group.access',
    ['Advisory job lists'] = 'settings_group.advisory_job_lists',
    ['Anonymity (whitelisted-job targets)'] = 'settings_group.anonymity_whitelisted_job_targets',
    ['Anonymity'] = 'settings_group.anonymity',
    ['Anti-collusion'] = 'settings_group.anti_collusion',
    ['Audit and debug'] = 'settings_group.audit_and_debug',
    ['Barred jobs'] = 'settings_group.barred_jobs',
    ['Body disposal'] = 'settings_group.body_disposal',
    ['Buyout pricing'] = 'settings_group.buyout_pricing',
    ['Buyouts'] = 'settings_group.buyouts',
    ['Completion'] = 'settings_group.completion',
    ['Contract limits'] = 'settings_group.contract_limits',
    ['Contract reasons'] = 'settings_group.contract_reasons',
    ['Diagnostics'] = 'settings_group.diagnostics',
    ['Edit in config.lua'] = 'settings_group.edit_in_config_lua',
    ['Handovers'] = 'settings_group.handovers',
    ['Immunity'] = 'settings_group.immunity',
    ['Improvements: Contract decay'] = 'settings_group.improvements_contract_decay',
    ['Improvements: Proof items'] = 'settings_group.improvements_proof_items',
    ['Improvements: Serial scrubbing'] = 'settings_group.improvements_serial_scrubbing',
    ['Improvements: Weekly stats'] = 'settings_group.improvements_weekly_stats',
    ['Intel prices'] = 'settings_group.intel_prices',
    ['Intel: Every other target'] = 'settings_group.intel_every_other_target',
    ['Intel: Go dark'] = 'settings_group.intel_go_dark',
    ['Intel: Hold before a tip'] = 'settings_group.intel_hold_before_a_tip',
    ['Intel: Informant in person'] = 'settings_group.intel_informant_in_person',
    ['Intel: Informant second try'] = 'settings_group.intel_informant_second_try',
    ['Intel: Informant tip'] = 'settings_group.intel_informant_tip',
    ['Intel: Informants'] = 'settings_group.intel_informants',
    ['Intel: Rumours and broker'] = 'settings_group.intel_rumours_and_broker',
    ['Intel: Tip limits'] = 'settings_group.intel_tip_limits',
    ['Intel: Tip safe zones'] = 'settings_group.intel_tip_safe_zones',
    ['Intel: Tip warning delay'] = 'settings_group.intel_tip_warning_delay',
    ['Intel: Whitelisted-job targets'] = 'settings_group.intel_whitelisted_job_targets',
    ['Kept in the store, not on this list'] = 'settings_group.kept_in_the_store_not_on',
    ['Law enforcement advisory'] = 'settings_group.law_enforcement_advisory',
    ['Ledger'] = 'settings_group.ledger',
    ['Messages and calls'] = 'settings_group.messages_and_calls',
    ['Notifications'] = 'settings_group.notifications',
    ['Organisation'] = 'settings_group.organisation',
    ['Organisation: Boss limits'] = 'settings_group.organisation_boss_limits',
    ['Other scripts'] = 'settings_group.other_scripts',
    ['Payouts'] = 'settings_group.payouts',
    ['Proposals'] = 'settings_group.proposals',
    ['Rate limits'] = 'settings_group.rate_limits',
    ['Record: Hitman heat'] = 'settings_group.record_hitman_heat',
    ['Record: Placer record'] = 'settings_group.record_placer_record',
    ['Record: Progression'] = 'settings_group.record_progression',
    ['Record: Reputation'] = 'settings_group.record_reputation',
    ['Record: Tiered board'] = 'settings_group.record_tiered_board',
    ['Rewards'] = 'settings_group.rewards',
    ['Roleplay: Bodyguards'] = 'settings_group.roleplay_bodyguards',
    ['Roleplay: Burner phone'] = 'settings_group.roleplay_burner_phone',
    ['Roleplay: City news'] = 'settings_group.roleplay_city_news',
    ['Roleplay: Dirty money payouts'] = 'settings_group.roleplay_dirty_money_payouts',
    ['Roleplay: EMS before re-listing'] = 'settings_group.roleplay_ems_before_re_listing',
    ['Roleplay: Hit on the hitman'] = 'settings_group.roleplay_hit_on_the_hitman',
    ['Roleplay: Proof of intent'] = 'settings_group.roleplay_proof_of_intent',
    ['Roleplay: Reason quality'] = 'settings_group.roleplay_reason_quality',
    ['Roleplay: Witness heat'] = 'settings_group.roleplay_witness_heat',
    ['Server restart'] = 'settings_group.server_restart',
    ['Staff alerts'] = 'settings_group.staff_alerts',
    ['Staff commands'] = 'settings_group.staff_commands',
    ['Staff tools'] = 'settings_group.staff_tools',
    ['Staff'] = 'settings_group.staff',
    ['Stakes'] = 'settings_group.stakes',
    ['Step markers'] = 'settings_group.step_markers',
    ['Storage'] = 'settings_group.storage',
    ['Target limits'] = 'settings_group.target_limits',
    ['Targeting'] = 'settings_group.targeting',
    ['The app'] = 'settings_group.the_app',
    ['The clock'] = 'settings_group.the_clock',
    ['Anonymity fees'] = 'settings_group.anonymity_fees',
    ['Escrow'] = 'settings_group.escrow',
}

--- A group's name as staff read it (the English one when it has none).
---@param group string|nil
---@return string|nil
function Settings.groupLabel(group)
    if group == nil then return nil end
    return GROUP_LABEL[group] and L(GROUP_LABEL[group]) or group
end
Settings.GROUP_LABEL = GROUP_LABEL

--- A catalogue entry's area: its own `area`, or its group's.
---@param entry table
---@return string
function Settings.areaOf(entry)
    return entry.area or AREA_OF_GROUP[entry.group] or 'other'
end

--- Every key the panel shows, with its value now, what config.lua says,
--- and where the value in force comes from.
---
--- `overrides` counts the ones in force; `stored` every row the store holds
--- (or may hold), which Reset all clears; `notApplied` the rows held and
--- not applied. A row for a key this version does not list is shown
--- read-only, with why and its Reset: every start said to reset it here,
--- and there was no row to do it from.
---@return table { features = entry[], limits = entry[], readonly = entry[], overrides = n, stored = n, notApplied = n }
function Settings.view()
    local out = { features = {}, limits = {}, readonly = {}, overrides = 0, stored = 0, notApplied = 0 }
    for _, entry in ipairs(CATALOGUE) do
        local override = overrides[entry.key]
        local skipped = ignored[entry.key]
        local row = {
            key = entry.key, group = entry.group, groupLabel = Settings.groupLabel(entry.group),
            label = entry.label, about = entry.about, moneyLabel = Settings.groupLabel(entry.money),
            category = entry.category, money = entry.money, area = Settings.areaOf(entry),
            shipped = shippedOf(entry), hasShipped = shippedOf(entry) ~= nil,
            kind = entry.kind, choices = entry.choices, min = entry.min, max = Settings.maxOf(entry),
            integer = entry.integer or nil, live = entry.live ~= false, place = entry.place,
            inflight = entry.inflight, readonly = entry.readonly, destroys = entry.destroys,
            stricter = entry.stricter, strict = entry.strict, whole = entry.whole or nil,
            -- A text key's own length and rule in words, for the page's
            -- hint and its length check (the server checks the rule).
            maxLength = entry.kind == 'text' and (entry.maxLength or 64) or nil,
            says = entry.kind == 'text' and entry.says or nil,
            value = current(entry), default = copyOf(defaults[entry.key]),
            source = override and 'panel' or 'config',
            by = override and override.by or nil, at = override and override.at or nil,
            ignored = skipped and skipped.why or nil,
            unknown = unknown[entry.key] and unknown[entry.key].why or nil,
            inactive = (entry.needs and read(Config, entry.needs) ~= true
                and NEEDS_OFF[entry.needs])
                or (entry.unless and read(Config, entry.unless) == true
                and UNLESS_ON[entry.unless]) or nil,
        }
        if override then out.overrides = out.overrides + 1 end
        local list = out[entry.section]
        list[#list + 1] = row
    end
    -- The keys never changed from here, not on the list above: shown with
    -- why, and a secret only as set or not.
    local denied = {}
    for key in pairs(DENY) do if not byKey[key] then denied[#denied + 1] = key end end
    table.sort(denied)
    for _, key in ipairs(denied) do
        local rule = DENY[key]
        local value
        if rule.secret then
            local ok, got = pcall(GetConvar, rule.convar, '')
            value = (ok and type(got) == 'string' and got ~= '') and L('settings.set') or L('settings.not_set')
        else
            -- A game vector (vector4(...) for a spot in config.lua) is
            -- shown as the table of its axes: it cannot be sent as one.
            value = Geo.plain(copyOf(read(Config, key)))
            if value == nil then value = L('settings.not_set_2') end
            if type(value) == 'table' then value = json and json.encode(value) or L('settings.a_table') end
        end
        out.readonly[#out.readonly + 1] = {
            key = key, group = 'Edit in config.lua', groupLabel = Settings.groupLabel('Edit in config.lua'),
            area = 'engine',
            label = rule.secret and (L('settings.secret_x'):format(tostring(rule.convar))) or rule.label or key,
            kind = 'text', category = 'developer', readonly = rule.why, denied = true,
            secret = rule.secret or nil, value = value, source = 'config',
        }
    end
    local strays = {}
    for key in pairs(ignored) do if not byKey[key] then strays[#strays + 1] = key end end
    for key in pairs(unknown) do
        if not byKey[key] and not ignored[key] then strays[#strays + 1] = key end
    end
    table.sort(strays)
    for _, key in ipairs(strays) do
        local skipped = ignored[key] or {}
        out.readonly[#out.readonly + 1] = {
            key = key, group = 'Kept in the store, not on this list',
            groupLabel = Settings.groupLabel('Kept in the store, not on this list'), label = key, kind = 'text',
            category = 'developer', area = 'engine',
            readonly = L('settings.not_a_setting_this_version_lists'),
            value = copyOf(skipped.value), source = 'config', by = skipped.by, at = skipped.at,
            ignored = skipped.why, unknown = unknown[key] and unknown[key].why or nil, stray = true,
        }
    end
    for _, row in ipairs(Settings.active()) do
        out.stored = out.stored + 1
        if row.ignored then out.notApplied = out.notApplied + 1 end
    end
    return out
end

--- The overrides in force and the ones not applied, by key, for /ch-diag:
--- `applied` on the ones in force, `ignored` (why) on the ones not, and
--- `unknown` (why) on a key whose last change the store may or may not hold.
---@return table[] { key, value, by, at, applied, ignored, unknown }
function Settings.active()
    local out, listed = {}, {}
    for key, override in pairs(overrides) do
        listed[key] = #out + 1
        out[#out + 1] = { key = key, value = copyOf(override.value), by = override.by,
                          at = override.at, applied = true }
    end
    for key, skipped in pairs(ignored) do
        listed[key] = #out + 1
        out[#out + 1] = { key = key, value = copyOf(skipped.value), by = skipped.by,
                          at = skipped.at, ignored = skipped.why }
    end
    for key, doubt in pairs(unknown) do
        local row = listed[key] and out[listed[key]]
        if row then
            row.unknown = doubt.why
        else
            local entry = byKey[key]
            out[#out + 1] = { key = key, value = entry and current(entry) or nil, by = doubt.by,
                              at = doubt.at, unknown = doubt.why }
        end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

--- The catalogue entry for a key, for the panel and the tests.
---@param key string
---@return table|nil
function Settings.entry(key)
    return byKey[key]
end

--- The value in force for a key, as the panel shows it (presets compare
--- against it); nil for a key the catalogue does not list.
---@param key string
---@return any
function Settings.valueOf(key)
    local entry = type(key) == 'string' and byKey[key] or nil
    if not entry then return nil end
    return current(entry)
end

--------------------------------------------------------------------------
-- History (Developer > Settings history)
--------------------------------------------------------------------------

--- The audit rows every change writes (admin_setting_changed, its reset
--- admin_setting_reset, and admin_settings_reset_all) each hold the key,
--- the value before and after, who and when, so the history is read from
--- them: one substring of the action matches all three.
local HISTORY_ACTION = 'admin_setting'

--- Whether a key's values are never shown: a secret on the deny list (a
--- webhook), or a key the catalogue does not list whose name says it holds
--- one. Neither is changeable from the panel, so neither should ever be in a
--- row; this is the guard should one be. A key the catalogue lists is an
--- ordinary setting whatever its name (Completion.PhotoTokenLifetimeSeconds
--- is a time): config.lua, where every one lives, goes to every client.
---@param key any
---@return boolean
function Settings.secretKey(key)
    if type(key) ~= 'string' then return true end
    local rule = DENY[key]
    if rule and rule.secret then return true end
    if byKey[key] then return false end
    local lowered = key:lower()
    return lowered:find('webhook', 1, true) ~= nil or lowered:find('secret', 1, true) ~= nil
        or lowered:find('password', 1, true) ~= nil or lowered:find('token', 1, true) ~= nil
end

--- One page of the history, newest first: a row for each change of one
--- key, and a reset of every setting one row for each key it changed.
---@param cursor any where the page before stopped (opaque)
---@param limit integer rows of the log read, at most
---@return table[] rows { ts, action, key, old, new, actor, by, source, secret, category, undoable }
---@return any next the cursor of the next page, nil on the last
function Settings.history(cursor, limit)
    pcall(Audit.flush)
    local rows, next_ = Storage.queryAudit({ action = HISTORY_ACTION }, cursor, limit)
    local out = {}
    local function add(row, key, old, new, by, source)
        local secret = Settings.secretKey(key)
        local entry = byKey[key]
        local shownOld, shownNew
        if not secret then shownOld, shownNew = copyOf(old), copyOf(new) end
        out[#out + 1] = {
            ts = tonumber(row.ts), action = row.action, key = key,
            old = shownOld, new = shownNew,
            actor = row.actor_cid, by = by, source = source, secret = secret or nil,
            category = entry and entry.category or 'developer',
            undoable = (not secret and entry ~= nil and not entry.readonly and old ~= nil) or nil,
        }
    end
    for _, row in ipairs(rows or {}) do
        local detail = type(row.detail) == 'table' and row.detail or {}
        if row.action == 'admin_settings_reset_all' then
            local changes = type(detail.changes) == 'table' and detail.changes or {}
            local keys = {}
            for key in pairs(changes) do keys[#keys + 1] = key end
            table.sort(keys)
            for _, key in ipairs(keys) do
                local change = changes[key]
                if type(change) == 'table' then add(row, key, change.old, change.new, detail.by, 'config') end
            end
        elseif row.action == 'admin_setting_changed' or row.action == 'admin_setting_reset' then
            add(row, detail.key, detail.old, detail.new, detail.by,
                row.action == 'admin_setting_reset' and 'config' or detail.source)
        end
    end
    return out, next_
end

return Settings
end)
