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
}
