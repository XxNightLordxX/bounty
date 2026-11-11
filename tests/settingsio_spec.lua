--- Settings export and import (X2, server/settingsio.lua): the admin
--- panel's Developer > Export and import. One JSON text holding every
--- setting changed from the panel and the server's own presets; an import
--- previewed in full (from, to, refused and why) with nothing changed, and
--- applied through Settings.set (each change audited and undoable).

local function stack()
    local s = newStack()
    local f = fixture(s)
    Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
        firstname = 'Sam', lastname = 'Steward' })
    Env.addPlayer({ source = 7, citizenid = 'READER01', license = 'license:READER01',
        firstname = 'Rae', lastname = 'Dent' })
    Env.addPlayer({ source = 9, citizenid = 'MODER001', license = 'license:MODER001',
        firstname = 'Mo', lastname = 'Derate' })
    Env.aces[6] = { ['crimson.admin'] = true }
    Env.aces[7] = { command = true }
    Env.aces[9] = { ['crimson.moderator'] = true }
    Config.Cooldowns.admin = { per = 10, burst = 500 }
    Config.Cooldowns.adminWrite = { per = 10, burst = 500 }
    s.bridges.install(s)
    return s, f
end

local function ask(src, op, data)
    Env.clientEvents = {}
    _G.source = src
    local fired, err = pcall(Env.events['crimson-hitman:admin'], { op = op, data = data or {}, __rid = 7 })
    _G.source = nil
    truthy(fired, 'the net event must not raise: ' .. tostring(err))
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:adminResult' then return event.args[1] end
    end
    return nil
end

local function stored(s, action)
    s.audit.flush()
    return s.storage.auditByAction(action, 100) or {}
end

describe('settings export and import (X2)', function()
    it('exports every setting changed from the panel and the own presets, never a secret, as one text', function()
        local s = stack()
        eq(ask(6, 'setSetting', { key = 'Limits.MaxAcceptedPerHitman', value = 4 }).ok, true)
        eq(ask(6, 'setSetting', { key = 'Limits.TargetCooldownAfterResolveSeconds', value = 900 }).ok, true)
        eq(ask(6, 'presetSaveOwn', { name = 'Night' }).ok, true)
        eq(ask(7, 'settingsExport').ok, false, 'a reader without the Developer section may not')
        local reply = ask(6, 'settingsExport')
        eq(reply.ok, true, tostring(reply.message))
        eq(reply.data.settings, 2)
        eq(reply.data.presets, 1)
        local body = json.decode(reply.data.text)
        eq(body.format, 'crimson-hitman-settings')
        eq(body.version, 1)
        eq(body.settings['Limits.MaxAcceptedPerHitman'], 4)
        eq(body.settings['Limits.TargetCooldownAfterResolveSeconds'], 900)
        eq(body.presets[1].name, 'Night')
        eq(body.presets[1].values['Limits.MaxAcceptedPerHitman'], 4)
        falsy(reply.data.text:lower():find('webhook', 1, true), 'no secret')
        falsy(body.places or body.targetLimits, 'places and target limits are not in it')
    end)

    it('previews an import in full and changes nothing; refuses DENY, unknown, read-only and invalid keys', function()
        local s = stack()
        local before = Config.Limits.MaxAcceptedPerHitman
        local text = json.encode({ format = 'crimson-hitman-settings', version = 1, settings = {
            ['Limits.MaxAcceptedPerHitman'] = 2,
            ['Database.Mode'] = 'memory',
            ['Admin.Ace'] = 'everyone',
            ['No.Such.Key'] = 1,
            ['Limits.TargetCooldownAfterResolveSeconds'] = 'soon',
            ['Debug'] = Config.Debug,
        }, presets = { { name = 'Imported', values = { ['Limits.MaxAcceptedPerHitman'] = 3 } },
                       { name = 'Strict', values = { ['Limits.MaxAcceptedPerHitman'] = 3 } } } })
        eq(ask(9, 'settingsImport', { text = text }).ok, false, 'a moderator may not')
        local reply = ask(6, 'settingsImport', { text = text })
        eq(reply.ok, true, tostring(reply.message))
        local p = reply.data
        eq(#p.changes, 1)
        eq(p.changes[1].key, 'Limits.MaxAcceptedPerHitman')
        eq(p.changes[1].from, tostring(before))
        eq(p.changes[1].to, '2')
        eq(p.same, 1, 'Debug is as the text says already')
        local why = {}
        for _, r in ipairs(p.refused) do why[r.key] = r.why end
        truthy(why['Database.Mode'] and why['Database.Mode']:find('Never changed from the panel', 1, true))
        truthy(why['Admin.Ace'], 'read-only')
        eq(why['No.Such.Key'], 'Not a setting this version has.')
        truthy(why['Limits.TargetCooldownAfterResolveSeconds'], 'an invalid value')
        eq(p.values, nil, 'the values to apply stay on the server')
        eq(p.presets[1].name, 'Imported')
        eq(p.presets[1].why, nil, 'added')
        truthy(p.presets[2].why, 'a shipped name is not added')
        eq(Config.Limits.MaxAcceptedPerHitman, before, 'nothing changed by reading')
        eq(#stored(s, 'admin_setting_changed'), 0)
    end)

    it('refuses text that is not an export', function()
        stack()
        eq(ask(6, 'settingsImport', { text = '' }).err, 'invalid_input')
        eq(ask(6, 'settingsImport', { text = 'not json' }).err, 'invalid_input')
        eq(ask(6, 'settingsImport', { text = json.encode({ format = 'other', version = 1 }) }).err, 'invalid_input')
        eq(ask(6, 'settingsImport', { text = ('x'):rep(200001) }).err, 'invalid_input')
    end)

    it('applies through Settings.set, each change audited and undoable, the presets added, one import row', function()
        local s = stack()
        local before, mode = Config.Limits.MaxAcceptedPerHitman, Config.Database.Mode
        local text = json.encode({ format = 'crimson-hitman-settings', version = 1,
            settings = { ['Limits.MaxAcceptedPerHitman'] = 2, ['Database.Mode'] = 'memory' },
            presets = { { name = 'Imported', values = { ['Limits.MaxAcceptedPerHitman'] = 3, ['Admin.Ace'] = 'x' } } } })
        eq(ask(7, 'settingsImportApply', { text = text, expect = 1 }).ok, false, 'a reader may not')
        eq(ask(6, 'settingsImportApply', { text = text, expect = 2 }).err, 'invalid_value',
            'not the changes the preview showed')
        eq(Config.Limits.MaxAcceptedPerHitman, before, 'nothing changed')
        local reply = ask(6, 'settingsImportApply', { text = text, expect = 1 })
        eq(reply.ok, true, tostring(reply.message))
        eq(Config.Limits.MaxAcceptedPerHitman, 2, 'in force')
        eq(Config.Database.Mode, mode, 'the deny list untouched')
        eq(#stored(s, 'admin_setting_changed'), 1, 'audited as a Save is')
        local imported = stored(s, 'admin_settings_imported')
        eq(#imported, 1)
        eq(imported[1].detail.presets[1], 'Imported')
        local listed = ask(6, 'presets').data.presets
        local added
        for _, p in ipairs(listed) do if p.name == 'Imported' then added = p end end
        truthy(added and added.own, 'the preset is one of the server\'s own')
        -- Its deny-list value was dropped: only the setting this server takes.
        eq(#added.changes, 1)
        -- And the change is undoable from Change history.
        local hist = ask(6, 'logs', { area = 'settings' }).data.rows or {}
        truthy(hist[1] and hist[1].ref, 'in Change history with Undo')
        eq(ask(6, 'undoSetting', { ref = hist[1].ref }).ok, true)
        eq(Config.Limits.MaxAcceptedPerHitman, before, 'undone')
        eq(ask(6, 'settingsImportApply', { text = json.encode({ format = 'crimson-hitman-settings', version = 1,
            settings = {} }), expect = 0 }).err, 'unchanged')
    end)

    it('round-trips: an export applied on a fresh server gives the same settings', function()
        local s = stack()
        eq(ask(6, 'setSetting', { key = 'Limits.MaxAcceptedPerHitman', value = 5 }).ok, true)
        local text = ask(6, 'settingsExport').data.text
        local _ = s
        stack()
        local preview = ask(6, 'settingsImport', { text = text }).data
        eq(#preview.changes, 1)
        eq(ask(6, 'settingsImportApply', { text = text, expect = #preview.changes }).ok, true)
        eq(Config.Limits.MaxAcceptedPerHitman, 5)
    end)
end)
