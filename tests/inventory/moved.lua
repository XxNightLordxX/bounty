--- Capabilities that left their old name on purpose, and where each now
--- lives. tests/capability_inventory_spec.lua accepts a baseline item that
--- is no longer extracted only when it is listed here, and fails when the
--- place it names is not itself a current item.
---
--- Format: [old item] = 'new item', or { to = 'new item', note = 'why' }.
--- Items are written as the baseline writes them, 'category:name':
---
---     ['op:freeze'] = 'op:holdPlace',
---     ['config:Informant.Enabled'] = { to = 'config:Intel.Informant.Enabled',
---                                      note = 'informants merged under Intel' },
---
--- Once the baseline is regenerated after a merge, the entries it has folded
--- in may be removed from here (docs/dev/map.md, "Capability inventory").

return {
    -- Step 3b: one marker system. The tip and the meeting point reach the
    -- map over the one marker event pair (server/lib/markers.lua), keyed
    -- 'tip:<contract>' / 'meeting:<contract>'.
    ['netevent.client:crimson-hitman:locationTip'] = { to = 'netevent.client:crimson-hitman:client:StepMarker',
        note = 'marker kind tip, key tip:<contract>' },
    ['netevent.client:crimson-hitman:locationTipClear'] = { to = 'netevent.client:crimson-hitman:client:StepMarkerClear',
        note = 'key tip:<contract>' },
    ['netevent.client:crimson-hitman:meetingBlip'] = { to = 'netevent.client:crimson-hitman:client:StepMarker',
        note = 'marker kind meeting, key meeting:<contract>' },
    ['netevent.client:crimson-hitman:meetingBlipClear'] = { to = 'netevent.client:crimson-hitman:client:StepMarkerClear',
        note = 'key meeting:<contract>' },
    -- And every Set GPS is one NUI callback, by kind.
    ['nui:crimson:meetingGps'] = { to = 'nui:crimson:gps', note = "kind = 'meeting'" },
    ['nui:crimson:protectionGps'] = { to = 'nui:crimson:gps', note = "kind = 'protection'" },
    ['nui:crimson:tipGps'] = { to = 'nui:crimson:gps', note = "kind = 'tip'" },
    -- Step 3c: one Places registry (server/places.lua). Every staff-set map
    -- spot is a kind of it, kept as one row kind (crimson_rp_rows,
    -- 'map_place'), set and removed by one pair of panel ops, with one Use my
    -- position. Each kind's own rules stay with its feature. Not items of
    -- the inventory, recorded here as well: the stored row kinds 'rp_place'
    -- and 'disp_spot' and the table crimson_org_locations -> rp row kind
    -- 'map_place'; orgGet's `spots` -> placeList's kinds' rows.
    ['op:orgMyPosition'] = { to = 'op:placeMyPosition', note = 'one Use my position for every kind' },
    ['op:disposalMyPosition'] = { to = 'op:placeMyPosition', note = 'one Use my position for every kind' },
    ['op:orgLocationSet'] = { to = 'op:placeSet',
        note = 'kind office | signup | meeting | npc | place; the organisation keeps who may set each' },
    ['op:orgLocationRemove'] = { to = 'op:placeRemove', note = 'by id' },
    ['op:disposalSpotSet'] = { to = 'op:placeSet', note = 'kind disposal_vehicle | disposal_drop (spot vehicle | drop)' },
    ['op:disposalSpotClear'] = { to = 'op:placeRemove', note = 'by id; config VehicleSpawn/DropOff apply again' },
    ['op:rpPlaceList'] = { to = 'op:placeList', note = 'kinds broker | informant, with defaults and using' },
    ['op:rpPlaceSet'] = { to = 'op:placeSet', note = 'kind broker | informant (npc)' },
    ['op:rpPlaceRemove'] = { to = 'op:placeRemove', note = 'by id' },
    ['op:rpPlaceReset'] = { to = 'op:placeReset', note = 'kind broker | informant (npc)' },
    -- Step 3d: one Measures area (server/measures.lua). Every measure on a
    -- player in force (frozen, suspended, protected, their own target
    -- limits) is one list, filtered by kind, in Players, All measures; its
    -- rows' handles, views and lifts are the one module's. Each kind's apply
    -- and lift ops, rules, ACE, audit actions and wording stay.
    ['op:frozen'] = { to = 'op:measures', note = "kind = 'freeze' (rows as before: ref, name, cid?, since, reason, by?)" },
    ['op:sanctions'] = { to = 'op:measures', note = "kind = 'suspend' | 'protect'" },
    ['screen:admin.view:frozen'] = { to = 'screen:admin.view:measures', note = 'filter Frozen' },
    ['screen:admin.view:suspended'] = { to = 'screen:admin.view:measures', note = 'filter Suspended' },
    ['screen:admin.view:protected'] = { to = 'screen:admin.view:measures', note = 'filter Protected' },
    -- Step 3e: one Holds service (server/holds.lua, was server/freeze.lua).
    -- Every reason a contract stands still (staff freeze, freezes unread,
    -- restart hold, app pause, and the expiry pass's presence pause) is asked
    -- through one API (Holds.on / since / why / shown), given back by one
    -- routine and released by one path. The app pause's switch and the
    -- restart hold's two numbers are one Holds section.
    ['config:Staff.AppPaused'] = { to = 'config:Holds.AppPaused', note = 'same switch, shipped off' },
    ['config:Restart.PauseBeforeSeconds'] = { to = 'config:Holds.RestartPauseBeforeSeconds', note = 'same, 1800' },
    ['config:Restart.MaxHoldMinutes'] = { to = 'config:Holds.RestartMaxHoldMinutes', note = 'same, 45' },
    ['setting:Staff.AppPaused'] = { to = 'setting:Holds.AppPaused', note = 'Features, Staff tools, as before' },
    ['setting:Restart.PauseBeforeSeconds'] = { to = 'setting:Holds.RestartPauseBeforeSeconds',
        note = 'Rules, Timers, Server restart, as before' },
    ['setting:Restart.MaxHoldMinutes'] = { to = 'setting:Holds.RestartMaxHoldMinutes',
        note = 'Rules, Timers, Server restart, as before' },
    ['tick:freeze.restartTick'] = { to = 'tick:holds.tick', note = 'the unread retry and the restart hold\'s longest' },
    ['tick:freeze.syncAppPause'] = { to = 'tick:holds.syncAppPause', note = 'the app pause in line with its switch' },
    -- Step 3f: one rules table per target class (Config.TargetClasses,
    -- read by Util.targetRule): `default` and `whitelisted` (a target on a
    -- whitelisted job), each with the four anonymity switches and the three
    -- informant switches. The anonymity fees stay in Config.Anonymity. An
    -- informant is sold where its feature's Enabled and its class's switch
    -- are both on (the default class ships on, so as before).
    ['config:Anonymity.AllowAnonymousPlacer'] = 'config:TargetClasses.default.AllowAnonymousPlacer',
    ['config:Anonymity.WhitelistedTargets.AllowAnonymousPlacer'] = 'config:TargetClasses.whitelisted.AllowAnonymousPlacer',
    ['config:Anonymity.AllowAnonymousHitman'] = 'config:TargetClasses.default.AllowAnonymousHitman',
    ['config:Anonymity.WhitelistedTargets.AllowAnonymousHitman'] = 'config:TargetClasses.whitelisted.AllowAnonymousHitman',
    ['config:Anonymity.ShowOperativeNames'] = 'config:TargetClasses.default.ShowOperativeNames',
    ['config:Anonymity.WhitelistedTargets.ShowOperativeNames'] = 'config:TargetClasses.whitelisted.ShowOperativeNames',
    ['config:Anonymity.ShowPlacerOnBoard'] = 'config:TargetClasses.default.ShowPlacerOnBoard',
    ['config:Anonymity.WhitelistedTargets.ShowPlacerOnBoard'] = 'config:TargetClasses.whitelisted.ShowPlacerOnBoard',
    ['config:InformantsWhitelistedTargets.Informant'] = { to = 'config:TargetClasses.whitelisted.Informant',
        note = 'with the feature\'s own Enabled on' },
    ['config:InformantsWhitelistedTargets.PlacerInformant'] = { to = 'config:TargetClasses.whitelisted.PlacerInformant',
        note = 'with the feature\'s own Enabled on' },
    ['config:InformantsWhitelistedTargets.LocationTip'] = { to = 'config:TargetClasses.whitelisted.LocationTip',
        note = 'with the feature\'s own Enabled on' },
    ['setting:Anonymity.AllowAnonymousPlacer'] = 'setting:TargetClasses.default.AllowAnonymousPlacer',
    ['setting:Anonymity.WhitelistedTargets.AllowAnonymousPlacer'] = 'setting:TargetClasses.whitelisted.AllowAnonymousPlacer',
    ['setting:Anonymity.AllowAnonymousHitman'] = 'setting:TargetClasses.default.AllowAnonymousHitman',
    ['setting:Anonymity.WhitelistedTargets.AllowAnonymousHitman'] = 'setting:TargetClasses.whitelisted.AllowAnonymousHitman',
    ['setting:Anonymity.ShowOperativeNames'] = 'setting:TargetClasses.default.ShowOperativeNames',
    ['setting:Anonymity.WhitelistedTargets.ShowOperativeNames'] = 'setting:TargetClasses.whitelisted.ShowOperativeNames',
    ['setting:Anonymity.ShowPlacerOnBoard'] = 'setting:TargetClasses.default.ShowPlacerOnBoard',
    ['setting:Anonymity.WhitelistedTargets.ShowPlacerOnBoard'] = 'setting:TargetClasses.whitelisted.ShowPlacerOnBoard',
    ['setting:InformantsWhitelistedTargets.Informant'] = { to = 'setting:TargetClasses.whitelisted.Informant',
        note = 'with the feature\'s own Enabled on' },
    ['setting:InformantsWhitelistedTargets.PlacerInformant'] = { to = 'setting:TargetClasses.whitelisted.PlacerInformant',
        note = 'with the feature\'s own Enabled on' },
    ['setting:InformantsWhitelistedTargets.LocationTip'] = { to = 'setting:TargetClasses.whitelisted.LocationTip',
        note = 'with the feature\'s own Enabled on' },
    -- Step 3g: one Intel engine (server/intel/engine.lua). Every paid look-up
    -- (the target's informant, the placer's informant, the hitman's tip and
    -- going dark) runs through one check, one charge -> confirm -> refund
    -- path and one delivery path; every setting under Config.Intel and one
    -- admin screen group (area intel, groups 'Intel: ...' and 'Intel prices').
    -- Not items of the inventory, recorded here as well: server/informant.lua,
    -- server/locationtip.lua, server/imp_tips.lua, server/rp_rumours.lua ->
    -- server/intel/informants.lua, tip.lua, rules.lua, rumours.lua;
    -- server/rp_informant.lua -> Intel.gate / Intel.IN_PERSON (engine.lua);
    -- Util.informantOn / informantAnyOn -> Intel.on / Intel.anyOn; the three
    -- refund copies (informant.lua refund, locationtip.lua refund,
    -- imp_tips.lua refundDark) -> Intel.refund, each product's audit action
    -- and fallback kept (Intel.PRODUCTS); the app's roleplay gate
    -- 'informant' -> 'intel'; stack/deps keys impTips -> intelRules,
    -- rpRumours -> intelRumours, rpInformant -> intel. Audit names, handlers,
    -- NUI callbacks, refusal codes and rate-limit buckets are unchanged.
    ['config:Improvements.GoDark.Account'] = 'config:Intel.GoDark.Account',
    ['config:Improvements.GoDark.Cost'] = 'config:Intel.GoDark.Cost',
    ['config:Improvements.GoDark.Enabled'] = 'config:Intel.GoDark.Enabled',
    ['config:Improvements.GoDark.Minutes'] = 'config:Intel.GoDark.Minutes',
    ['config:Improvements.InformantSecondTry.Enabled'] = 'config:Intel.SecondTry.Enabled',
    ['config:Improvements.InformantSecondTry.SecondTryCostPercent'] = 'config:Intel.SecondTry.SecondTryCostPercent',
    ['config:Improvements.TipHoldFirst.Enabled'] = 'config:Intel.HoldFirst.Enabled',
    ['config:Improvements.TipHoldFirst.MinHeldMinutes'] = 'config:Intel.HoldFirst.MinHeldMinutes',
    ['config:Improvements.TipLimits.Enabled'] = 'config:Intel.TipLimits.Enabled',
    ['config:Improvements.TipLimits.MaxCost'] = 'config:Intel.TipLimits.MaxCost',
    ['config:Improvements.TipLimits.OnePerHitman'] = 'config:Intel.TipLimits.OnePerHitman',
    ['config:Improvements.TipLimits.PriceDoubling'] = 'config:Intel.TipLimits.PriceDoubling',
    ['config:Improvements.TipSafeZones.Enabled'] = 'config:Intel.SafeZones.Enabled',
    ['config:Improvements.TipSafeZones.Zones'] = 'config:Intel.SafeZones.Zones',
    ['config:Improvements.TipWarningDelay.Enabled'] = 'config:Intel.WarningDelay.Enabled',
    ['config:Improvements.TipWarningDelay.MaxSeconds'] = 'config:Intel.WarningDelay.MaxSeconds',
    ['config:Improvements.TipWarningDelay.MinSeconds'] = 'config:Intel.WarningDelay.MinSeconds',
    ['config:Informant.Account'] = 'config:Intel.Informant.Account',
    ['config:Informant.Cost'] = 'config:Intel.Informant.Cost',
    ['config:Informant.Enabled'] = 'config:Intel.Informant.Enabled',
    ['config:Informant.MaxPurchasesPerContract'] = 'config:Intel.Informant.MaxPurchasesPerContract',
    ['config:Informant.ProximityRadius'] = 'config:Intel.Informant.ProximityRadius',
    ['config:Informant.RerollLockMinutes'] = 'config:Intel.Informant.RerollLockMinutes',
    ['config:Informant.RevealChancePercent'] = 'config:Intel.Informant.RevealChancePercent',
    ['config:Informant.RevealMode'] = 'config:Intel.Informant.RevealMode',
    ['config:InformantsEnabled'] = 'config:Intel.Enabled',
    ['config:LocationTip.Account'] = 'config:Intel.LocationTip.Account',
    ['config:LocationTip.CooldownMinutes'] = 'config:Intel.LocationTip.CooldownMinutes',
    ['config:LocationTip.Cost'] = 'config:Intel.LocationTip.Cost',
    ['config:LocationTip.Enabled'] = 'config:Intel.LocationTip.Enabled',
    ['config:LocationTip.MaxPurchasesPerContract'] = 'config:Intel.LocationTip.MaxPurchasesPerContract',
    ['config:LocationTip.NotifyTarget'] = 'config:Intel.LocationTip.NotifyTarget',
    ['config:LocationTip.RadiusMeters'] = 'config:Intel.LocationTip.RadiusMeters',
    ['config:LocationTip.ShowMinutes'] = 'config:Intel.LocationTip.ShowMinutes',
    ['config:PlacerInformant.Account'] = 'config:Intel.PlacerInformant.Account',
    ['config:PlacerInformant.AlertChancePercent'] = 'config:Intel.PlacerInformant.AlertChancePercent',
    ['config:PlacerInformant.CooldownMinutes'] = 'config:Intel.PlacerInformant.CooldownMinutes',
    ['config:PlacerInformant.Cost'] = 'config:Intel.PlacerInformant.Cost',
    ['config:PlacerInformant.Enabled'] = 'config:Intel.PlacerInformant.Enabled',
    ['config:PlacerInformant.MaxPurchasesPerContract'] = 'config:Intel.PlacerInformant.MaxPurchasesPerContract',
    ['config:PlacerInformant.RevealChancePercent'] = 'config:Intel.PlacerInformant.RevealChancePercent',
    ['config:PlacerInformant.RevealMode'] = 'config:Intel.PlacerInformant.RevealMode',
    ['config:Roleplay.InformantNpc.Blip'] = 'config:Intel.InPerson.Blip',
    ['config:Roleplay.InformantNpc.Enabled'] = 'config:Intel.InPerson.Enabled',
    ['config:Roleplay.InformantNpc.Locations'] = 'config:Intel.InPerson.Locations',
    ['config:Roleplay.InformantNpc.Model'] = 'config:Intel.InPerson.Model',
    ['config:Roleplay.InformantNpc.Radius'] = 'config:Intel.InPerson.Radius',
    ['config:Roleplay.InformantNpc.RotateHours'] = 'config:Intel.InPerson.RotateHours',
    ['config:Roleplay.InformantNpc.Scenario'] = 'config:Intel.InPerson.Scenario',
    ['config:Roleplay.Rumours.AreaMode'] = 'config:Intel.Rumours.AreaMode',
    ['config:Roleplay.Rumours.BandPercent'] = 'config:Intel.Rumours.BandPercent',
    ['config:Roleplay.Rumours.Blip'] = 'config:Intel.Rumours.Blip',
    ['config:Roleplay.Rumours.BriefValidMinutes'] = 'config:Intel.Rumours.BriefValidMinutes',
    ['config:Roleplay.Rumours.BrokerJobs'] = 'config:Intel.Rumours.BrokerJobs',
    ['config:Roleplay.Rumours.Districts'] = 'config:Intel.Rumours.Districts',
    ['config:Roleplay.Rumours.Enabled'] = 'config:Intel.Rumours.Enabled',
    ['config:Roleplay.Rumours.Locations'] = 'config:Intel.Rumours.Locations',
    ['config:Roleplay.Rumours.Model'] = 'config:Intel.Rumours.Model',
    ['config:Roleplay.Rumours.Radius'] = 'config:Intel.Rumours.Radius',
    ['config:Roleplay.Rumours.RotateHours'] = 'config:Intel.Rumours.RotateHours',
    ['config:Roleplay.Rumours.Scenario'] = 'config:Intel.Rumours.Scenario',
    ['config:Roleplay.Rumours.Zones'] = 'config:Intel.Rumours.Zones',
    ['setting:Improvements.GoDark.Account'] = 'setting:Intel.GoDark.Account',
    ['setting:Improvements.GoDark.Cost'] = 'setting:Intel.GoDark.Cost',
    ['setting:Improvements.GoDark.Enabled'] = 'setting:Intel.GoDark.Enabled',
    ['setting:Improvements.GoDark.Minutes'] = 'setting:Intel.GoDark.Minutes',
    ['setting:Improvements.InformantSecondTry.Enabled'] = 'setting:Intel.SecondTry.Enabled',
    ['setting:Improvements.InformantSecondTry.SecondTryCostPercent'] = 'setting:Intel.SecondTry.SecondTryCostPercent',
    ['setting:Improvements.TipHoldFirst.Enabled'] = 'setting:Intel.HoldFirst.Enabled',
    ['setting:Improvements.TipHoldFirst.MinHeldMinutes'] = 'setting:Intel.HoldFirst.MinHeldMinutes',
    ['setting:Improvements.TipLimits.Enabled'] = 'setting:Intel.TipLimits.Enabled',
    ['setting:Improvements.TipLimits.MaxCost'] = 'setting:Intel.TipLimits.MaxCost',
    ['setting:Improvements.TipLimits.OnePerHitman'] = 'setting:Intel.TipLimits.OnePerHitman',
    ['setting:Improvements.TipLimits.PriceDoubling'] = 'setting:Intel.TipLimits.PriceDoubling',
    ['setting:Improvements.TipSafeZones.Enabled'] = 'setting:Intel.SafeZones.Enabled',
    ['setting:Improvements.TipSafeZones.Zones'] = 'setting:Intel.SafeZones.Zones',
    ['setting:Improvements.TipWarningDelay.Enabled'] = 'setting:Intel.WarningDelay.Enabled',
    ['setting:Improvements.TipWarningDelay.MaxSeconds'] = 'setting:Intel.WarningDelay.MaxSeconds',
    ['setting:Improvements.TipWarningDelay.MinSeconds'] = 'setting:Intel.WarningDelay.MinSeconds',
    ['setting:Informant.Account'] = 'setting:Intel.Informant.Account',
    ['setting:Informant.Cost'] = 'setting:Intel.Informant.Cost',
    ['setting:Informant.Enabled'] = 'setting:Intel.Informant.Enabled',
    ['setting:Informant.MaxPurchasesPerContract'] = 'setting:Intel.Informant.MaxPurchasesPerContract',
    ['setting:Informant.ProximityRadius'] = 'setting:Intel.Informant.ProximityRadius',
    ['setting:Informant.RerollLockMinutes'] = 'setting:Intel.Informant.RerollLockMinutes',
    ['setting:Informant.RevealChancePercent'] = 'setting:Intel.Informant.RevealChancePercent',
    ['setting:Informant.RevealMode'] = 'setting:Intel.Informant.RevealMode',
    ['setting:InformantsEnabled'] = 'setting:Intel.Enabled',
    ['setting:LocationTip.Account'] = 'setting:Intel.LocationTip.Account',
    ['setting:LocationTip.CooldownMinutes'] = 'setting:Intel.LocationTip.CooldownMinutes',
    ['setting:LocationTip.Cost'] = 'setting:Intel.LocationTip.Cost',
    ['setting:LocationTip.Enabled'] = 'setting:Intel.LocationTip.Enabled',
    ['setting:LocationTip.MaxPurchasesPerContract'] = 'setting:Intel.LocationTip.MaxPurchasesPerContract',
    ['setting:LocationTip.NotifyTarget'] = 'setting:Intel.LocationTip.NotifyTarget',
    ['setting:LocationTip.RadiusMeters'] = 'setting:Intel.LocationTip.RadiusMeters',
    ['setting:LocationTip.ShowMinutes'] = 'setting:Intel.LocationTip.ShowMinutes',
    ['setting:PlacerInformant.Account'] = 'setting:Intel.PlacerInformant.Account',
    ['setting:PlacerInformant.AlertChancePercent'] = 'setting:Intel.PlacerInformant.AlertChancePercent',
    ['setting:PlacerInformant.CooldownMinutes'] = 'setting:Intel.PlacerInformant.CooldownMinutes',
    ['setting:PlacerInformant.Cost'] = 'setting:Intel.PlacerInformant.Cost',
    ['setting:PlacerInformant.Enabled'] = 'setting:Intel.PlacerInformant.Enabled',
    ['setting:PlacerInformant.MaxPurchasesPerContract'] = 'setting:Intel.PlacerInformant.MaxPurchasesPerContract',
    ['setting:PlacerInformant.RevealChancePercent'] = 'setting:Intel.PlacerInformant.RevealChancePercent',
    ['setting:PlacerInformant.RevealMode'] = 'setting:Intel.PlacerInformant.RevealMode',
    ['setting:Roleplay.InformantNpc.Blip'] = 'setting:Intel.InPerson.Blip',
    ['setting:Roleplay.InformantNpc.Enabled'] = 'setting:Intel.InPerson.Enabled',
    ['setting:Roleplay.InformantNpc.Locations'] = 'setting:Intel.InPerson.Locations',
    ['setting:Roleplay.InformantNpc.Model'] = 'setting:Intel.InPerson.Model',
    ['setting:Roleplay.InformantNpc.Radius'] = 'setting:Intel.InPerson.Radius',
    ['setting:Roleplay.InformantNpc.RotateHours'] = 'setting:Intel.InPerson.RotateHours',
    ['setting:Roleplay.InformantNpc.Scenario'] = 'setting:Intel.InPerson.Scenario',
    ['setting:Roleplay.Rumours.AreaMode'] = 'setting:Intel.Rumours.AreaMode',
    ['setting:Roleplay.Rumours.BandPercent'] = 'setting:Intel.Rumours.BandPercent',
    ['setting:Roleplay.Rumours.Blip'] = 'setting:Intel.Rumours.Blip',
    ['setting:Roleplay.Rumours.BriefValidMinutes'] = 'setting:Intel.Rumours.BriefValidMinutes',
    ['setting:Roleplay.Rumours.BrokerJobs'] = 'setting:Intel.Rumours.BrokerJobs',
    ['setting:Roleplay.Rumours.Districts'] = 'setting:Intel.Rumours.Districts',
    ['setting:Roleplay.Rumours.Enabled'] = 'setting:Intel.Rumours.Enabled',
    ['setting:Roleplay.Rumours.Locations'] = 'setting:Intel.Rumours.Locations',
    ['setting:Roleplay.Rumours.Model'] = 'setting:Intel.Rumours.Model',
    ['setting:Roleplay.Rumours.Radius'] = 'setting:Intel.Rumours.Radius',
    ['setting:Roleplay.Rumours.RotateHours'] = 'setting:Intel.Rumours.RotateHours',
    ['setting:Roleplay.Rumours.Scenario'] = 'setting:Intel.Rumours.Scenario',
    ['setting:Roleplay.Rumours.Zones'] = 'setting:Intel.Rumours.Zones',
    -- Step 3i: one log view (Records › Logs); each log is an area of the
    -- logs op and a filter chip of the logs view.
    ['op:orgAudit'] = { to = 'op:logs', note = "area = 'org' (grant history: action = 'org_grant')" },
    ['op:settingsHistory'] = { to = 'op:logs', note = "area = 'settings'" },
    ['screen:admin.view:history'] = { to = 'screen:admin.view:logs', note = "chip Setting changes; Game rules' link 'logs:settings'" },
    ['screen:admin.view:orgaudit'] = { to = 'screen:admin.view:logs', note = "chip Org audit; Hitman organisation's link 'logs:org'" },
    ['screen:admin.view:bphistory'] = { to = 'screen:admin.view:logs', note = "chip Grant history; Boss permissions' link 'logs:grants'" },
    -- Step 3j: one Record (server/record/). A character's standing is kept and
    -- read in one module: the counters, standing and level (Record.of, the
    -- one read the app's Ledger, a card's operatives and the panel's player
    -- card use), trust and how it is scaled, the tiered board, heat and the
    -- placer's record, under one config section (Config.Record) and one
    -- admin area (Record & standing, groups 'Record: ...'). Every value as it
    -- was; the audit names (progression_awarded / _failed, imp_heat_*) and
    -- heat's stored row kind ('imp_heat') are unchanged. Not items of the
    -- inventory, recorded here as well: server/progression.lua,
    -- rp_reputation.lua, imp_tiers.lua -> server/record/init.lua;
    -- imp_heat.lua -> record/heat.lua; imp_placer_record.lua ->
    -- record/placer.lua; the claim's Contracts.reputationFor hook ->
    -- Record.factorFor; wiring keys progression / rpReputation /
    -- impBoard.heat / .tiers / .record -> record.
    ['tick:imp_board.tick'] = { to = 'tick:record.tick', note = 'heat, the bulletin and the placer records (Record.tick), and Intel\'s go-dark prune' },
    ['config:Progression.Enabled'] = 'config:Record.Progression.Enabled',
    ['config:Progression.Resource'] = 'config:Record.Progression.Resource',
    ['config:Progression.TrustPerElimination'] = 'config:Record.Progression.TrustPerElimination',
    ['config:Progression.TrustPerKidnapping'] = 'config:Record.Progression.TrustPerKidnapping',
    ['config:Roleplay.Reputation.BaseFactor'] = 'config:Record.Reputation.BaseFactor',
    ['config:Roleplay.Reputation.Enabled'] = 'config:Record.Reputation.Enabled',
    ['config:Roleplay.Reputation.HandoverBonus'] = 'config:Record.Reputation.HandoverBonus',
    ['config:Roleplay.Reputation.MaxFactor'] = 'config:Record.Reputation.MaxFactor',
    ['config:Roleplay.Reputation.MeetingBonus'] = 'config:Record.Reputation.MeetingBonus',
    ['config:Roleplay.Reputation.ThreadBonus'] = 'config:Record.Reputation.ThreadBonus',
    ['config:Roleplay.Reputation.WitnessFreeBonus'] = 'config:Record.Reputation.WitnessFreeBonus',
    ['config:Roleplay.Reputation.WitnessRadius'] = 'config:Record.Reputation.WitnessRadius',
    ['config:Improvements.Tiers.CompletionsPerLevel'] = 'config:Record.Tiers.CompletionsPerLevel',
    ['config:Improvements.Tiers.Enabled'] = 'config:Record.Tiers.Enabled',
    ['config:Improvements.Tiers.Tiers'] = 'config:Record.Tiers.Tiers',
    ['config:Improvements.HitmanHeat.AdvisoryHeat'] = 'config:Record.Heat.AdvisoryHeat',
    ['config:Improvements.HitmanHeat.BulletinEveryMinutes'] = 'config:Record.Heat.BulletinEveryMinutes',
    ['config:Improvements.HitmanHeat.BulletinText'] = 'config:Record.Heat.BulletinText',
    ['config:Improvements.HitmanHeat.BulletinTitle'] = 'config:Record.Heat.BulletinTitle',
    ['config:Improvements.HitmanHeat.DecayHours'] = 'config:Record.Heat.DecayHours',
    ['config:Improvements.HitmanHeat.Enabled'] = 'config:Record.Heat.Enabled',
    ['config:Improvements.HitmanHeat.ProtectedCompletionHeat'] = 'config:Record.Heat.ProtectedCompletionHeat',
    ['config:Improvements.HitmanHeat.Threshold'] = 'config:Record.Heat.Threshold',
    ['config:Improvements.HitmanHeat.WarnTargetChancePercent'] = 'config:Record.Heat.WarnTargetChancePercent',
    ['config:Improvements.HitmanHeat.WitnessHeat'] = 'config:Record.Heat.WitnessHeat',
    ['config:Improvements.PlacerRecord.Enabled'] = 'config:Record.PlacerRecord.Enabled',
    ['config:Improvements.PlacerRecord.LookbackDays'] = 'config:Record.PlacerRecord.LookbackDays',
    ['config:Improvements.PlacerRecord.ShowForAnonymous'] = 'config:Record.PlacerRecord.ShowForAnonymous',
    ['setting:Progression.Enabled'] = 'setting:Record.Progression.Enabled',
    ['setting:Progression.TrustPerElimination'] = 'setting:Record.Progression.TrustPerElimination',
    ['setting:Progression.TrustPerKidnapping'] = 'setting:Record.Progression.TrustPerKidnapping',
    ['setting:Roleplay.Reputation.BaseFactor'] = 'setting:Record.Reputation.BaseFactor',
    ['setting:Roleplay.Reputation.Enabled'] = 'setting:Record.Reputation.Enabled',
    ['setting:Roleplay.Reputation.HandoverBonus'] = 'setting:Record.Reputation.HandoverBonus',
    ['setting:Roleplay.Reputation.MaxFactor'] = 'setting:Record.Reputation.MaxFactor',
    ['setting:Roleplay.Reputation.MeetingBonus'] = 'setting:Record.Reputation.MeetingBonus',
    ['setting:Roleplay.Reputation.ThreadBonus'] = 'setting:Record.Reputation.ThreadBonus',
    ['setting:Roleplay.Reputation.WitnessFreeBonus'] = 'setting:Record.Reputation.WitnessFreeBonus',
    ['setting:Roleplay.Reputation.WitnessRadius'] = 'setting:Record.Reputation.WitnessRadius',
    ['setting:Improvements.Tiers.CompletionsPerLevel'] = 'setting:Record.Tiers.CompletionsPerLevel',
    ['setting:Improvements.Tiers.Enabled'] = 'setting:Record.Tiers.Enabled',
    ['setting:Improvements.Tiers.Tiers'] = 'setting:Record.Tiers.Tiers',
    ['setting:Improvements.HitmanHeat.AdvisoryHeat'] = 'setting:Record.Heat.AdvisoryHeat',
    ['setting:Improvements.HitmanHeat.BulletinEveryMinutes'] = 'setting:Record.Heat.BulletinEveryMinutes',
    ['setting:Improvements.HitmanHeat.BulletinText'] = 'setting:Record.Heat.BulletinText',
    ['setting:Improvements.HitmanHeat.BulletinTitle'] = 'setting:Record.Heat.BulletinTitle',
    ['setting:Improvements.HitmanHeat.DecayHours'] = 'setting:Record.Heat.DecayHours',
    ['setting:Improvements.HitmanHeat.Enabled'] = 'setting:Record.Heat.Enabled',
    ['setting:Improvements.HitmanHeat.ProtectedCompletionHeat'] = 'setting:Record.Heat.ProtectedCompletionHeat',
    ['setting:Improvements.HitmanHeat.Threshold'] = 'setting:Record.Heat.Threshold',
    ['setting:Improvements.HitmanHeat.WarnTargetChancePercent'] = 'setting:Record.Heat.WarnTargetChancePercent',
    ['setting:Improvements.HitmanHeat.WitnessHeat'] = 'setting:Record.Heat.WitnessHeat',
    ['setting:Improvements.PlacerRecord.Enabled'] = 'setting:Record.PlacerRecord.Enabled',
    ['setting:Improvements.PlacerRecord.LookbackDays'] = 'setting:Record.PlacerRecord.LookbackDays',
    ['setting:Improvements.PlacerRecord.ShowForAnonymous'] = 'setting:Record.PlacerRecord.ShowForAnonymous',
    -- Step 4a: one contracts list with a person filter (map item D2). The
    -- player's Contracts tab is Contracts with `ref` (Their contracts on the
    -- player's card), Target limits' Contracts on someone is Contracts with
    -- `byTarget` (Live contracts by target, on Target limits' strip).
    ['screen:admin.view:pcontracts'] = { to = 'screen:admin.view:contracts',
        note = 'person filter: ref (or person) and as (target, client, hitman)' },
    ['screen:admin.view:tlcontracts'] = { to = 'screen:admin.view:contracts',
        note = "'contracts:bytarget': byTarget = true, the live ones grouped by target" },
    ['op:targetContracts'] = { to = 'op:contracts', note = 'byTarget = true; audit admin_panel_target_contracts kept' },
}
