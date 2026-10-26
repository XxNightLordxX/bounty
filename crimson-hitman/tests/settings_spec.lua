--- Settings changed from the admin panel (server/settings.lua): which keys,
--- how each is checked, and that a change is in force at once and still in
--- force after a restart, in every storage mode.

local Exec = require('crimson-hitman.tests.harness.mysql_exec')

local BACKENDS = { 'memory', 'json', 'mysql' }

local function freshStore(name)
    if name == 'json' then
        package.loaded['crimson-hitman.server.storage.json'] = nil
        Natives.files = {}
        local store = require('crimson-hitman.server.storage.json')
        store.open()
        return store
    elseif name == 'mysql' then
        Exec.install(Natives)
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local store = require('crimson-hitman.server.storage.mysql')
        store.open()
        return store
    end
    package.loaded['crimson-hitman.server.storage.memory'] = nil
    local store = require('crimson-hitman.server.storage.memory')
    store.open()
    return store
end

--- The same store as a new process finds it: json and mysql read back from
--- what they wrote; memory is the same tables, which is all it has.
local function reopened(name, store)
    if name == 'json' then
        package.loaded['crimson-hitman.server.storage.json'] = nil
        local again = require('crimson-hitman.server.storage.json')
        again.open()
        return again
    elseif name == 'mysql' then
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local again = require('crimson-hitman.server.storage.mysql')
        again.open()
        return again
    end
    return store
end

local CHECK = require('crimson-hitman.server.main').checkCandidate

--- The settings module on a store, as a start wires it.
local function settingsOn(s, store)
    s.settings.init({ storage = store, audit = s.audit, check = CHECK })
    return s.settings
end

local function stack()
    local s = newStack()
    fixture(s)
    return s
end

--- Membership sets in config.lua: every value true, each key a name. Not
--- switches, and listed here by path so a new set has to be named.
local SETS = {
    BlockedJobTypes = true, BlockedJobNames = true, EscrowBlacklist = true,
    ['Mugshot.AllowedMime'] = true, ['Advisory.TriggerJobTypes'] = true,
    ['Advisory.TriggerJobNames'] = true, ['Advisory.RecipientJobTypes'] = true,
    ['Advisory.RecipientJobNames'] = true, ['Completion.MedicJobs'] = true,
}

--- Every boolean leaf in a table, by path.
local function booleans(value, path, out)
    out = out or {}
    if SETS[path] then return out end
    if type(value) == 'boolean' then
        out[#out + 1] = path
    elseif type(value) == 'table' then
        for key, inner in pairs(value) do
            if type(key) == 'string' then
                booleans(inner, path and (path .. '.' .. key) or key, out)
            end
        end
    end
    return out
end

local function read(key)
    local node = Config
    for part in key:gmatch('[^%.]+') do
        if type(node) ~= 'table' then return nil end
        node = node[part]
    end
    return node
end

--------------------------------------------------------------------------
-- The catalogue
--------------------------------------------------------------------------

describe('what the admin panel can change', function()
    it('lists every on/off switch in config.lua, as a feature or read-only with why', function()
        local s = stack()
        local missing = {}
        for _, path in ipairs(booleans(Config)) do
            local entry = s.settings.entry(path)
            if not entry then missing[#missing + 1] = path end
        end
        table.sort(missing)
        eq(#missing, 0, 'switches the panel does not list: ' .. table.concat(missing, ', '))
    end)

    it('lists the choices that are features: how contracts complete, where photos are kept', function()
        local s = stack()
        eq(s.settings.entry('Completion.Fulfilment').kind, 'choice')
        eq(s.settings.entry('Completion.Fulfilment').section, 'features')
        eq(s.settings.entry('Completion.PhotoStorage').kind, 'choice')
    end)

    it('lists every number in Config.Limits, the fees, the handover and every rate limit', function()
        local s = stack()
        local missing = {}
        local function want(key)
            if not s.settings.entry(key) then missing[#missing + 1] = key end
        end
        for key, value in pairs(Config.Limits) do
            if type(value) == 'number' then want('Limits.' .. key) end
        end
        for bucket in pairs(Config.Cooldowns) do
            want('Cooldowns.' .. bucket .. '.per')
            want('Cooldowns.' .. bucket .. '.burst')
        end
        for _, key in ipairs({ 'Anonymity.CreatorFee', 'Anonymity.HitmanFee',
            'Kidnap.CountdownSeconds', 'Kidnap.Radius', 'Kidnap.MinTargetHealthPercent',
            'Targeting.NearbyRadius', 'Ledger.PhotoRetentionDays', 'Bailout.MinMultiplier',
            'Bailout.MaxMultiplier', 'Bailout.AbsoluteMax', 'Advisory.TriggerJobTypes',
            'Advisory.RecipientJobNames' }) do
            want(key)
        end
        table.sort(missing)
        eq(#missing, 0, 'not changeable from the panel: ' .. table.concat(missing, ', '))
    end)

    it('names a value config.lua has, of the type it takes, for every key', function()
        local s = stack()
        local wrong = {}
        for _, entry in ipairs(s.settings.CATALOGUE) do
            local value = read(entry.key)
            local ok
            if entry.kind == 'switch' then ok = type(value) == 'boolean'
            elseif entry.kind == 'number' then ok = type(value) == 'number'
            elseif entry.kind == 'list' then ok = type(value) == 'table'
            elseif entry.kind == 'choice' then
                ok = false
                for _, choice in ipairs(entry.choices) do if choice == value then ok = true end end
            else ok = value ~= nil end
            if not ok then wrong[#wrong + 1] = entry.key end
            if entry.readonly then
                truthy(entry.readonly ~= '', entry.key .. ' says why it is read-only')
            else
                truthy(entry.label and entry.inflight, entry.key .. ' says what it is and what it does to things under way')
            end
        end
        table.sort(wrong)
        eq(#wrong, 0, 'catalogue keys config.lua does not hold as described: ' .. table.concat(wrong, ', '))
    end)

    it('keeps staff from locking themselves out', function()
        local s = stack()
        for _, key in ipairs({ 'Admin.Enabled', 'Admin.Ace', 'Admin.IdentityAce', 'Database.Mode',
            'Cooldowns.admin.per', 'Cooldowns.admin.burst', 'Cooldowns.adminWrite.per',
            'Cooldowns.adminWrite.burst' }) do
            local value, err, why = s.settings.check(key, false)
            eq(value, nil, key)
            eq(err, 'read_only', key)
            truthy(why and #why > 10, key .. ' says why')
        end
        eq(select(2, s.settings.check('Cooldowns.admin.burst', 1)), 'read_only',
            'the panel\'s own allowance, at any value')
    end)

    it('marks the one number whose lowering deletes something, with what the second click does', function()
        local s = stack()
        local marked = {}
        for _, entry in ipairs(s.settings.CATALOGUE) do
            if entry.destroys then marked[#marked + 1] = entry.key end
        end
        eq(table.concat(marked, ','), 'Ledger.PhotoRetentionDays')
        local row
        for _, r in ipairs(s.settings.view().limits) do
            if r.key == 'Ledger.PhotoRetentionDays' then row = r end
        end
        truthy(row.destroys:find('%s', 1, true), 'the page puts the new value in')
        truthy(row.destroys:find('deleted', 1, true))
    end)
end)

--------------------------------------------------------------------------
-- Checking a value
--------------------------------------------------------------------------

describe('checking a setting before it is changed', function()
    it('refuses a key that is not on the list', function()
        local s = stack()
        eq(select(2, s.settings.check('Audit.Webhook', 'https://x')), 'not_allowed')
        eq(select(2, s.settings.check('Config', true)), 'not_allowed')
        eq(select(2, s.settings.check(nil, true)), 'not_allowed')
    end)

    it('takes each kind in its own type and range', function()
        local s = stack()
        eq(select(2, s.settings.check('Relay.Enabled', 'true')), 'invalid_value', 'a switch is on or off')
        eq(s.settings.check('Relay.Enabled', false), false)
        eq(select(2, s.settings.check('Limits.MaxAcceptedPerHitman', 0)), 'invalid_value', 'below the floor')
        eq(select(2, s.settings.check('Limits.MaxAcceptedPerHitman', 51)), 'invalid_value', 'above the ceiling')
        eq(select(2, s.settings.check('Limits.MaxAcceptedPerHitman', 2.5)), 'invalid_value', 'a whole number')
        eq(select(2, s.settings.check('Limits.MaxAcceptedPerHitman', 0 / 0)), 'invalid_value', 'not NaN')
        eq(select(2, s.settings.check('Limits.MaxAcceptedPerHitman', math.huge)), 'invalid_value')
        eq(s.settings.check('Limits.MaxAcceptedPerHitman', '7'), 7, 'digits are a number')
        eq(s.settings.check('Kidnap.Radius', 7.5), 7.5, 'a radius need not be whole')
        eq(select(2, s.settings.check('Completion.Fulfilment', 'kills')), 'invalid_value')
        eq(s.settings.check('Completion.Fulfilment', 'alive'), 'alive')
        eq(select(2, s.settings.check('Advisory.TriggerJobNames', { 'fib', 'bad name' })),
            'invalid_value', 'job names, nothing else')
        local list = s.settings.check('Advisory.TriggerJobNames', { 'FIB', 'sast', 'fib' })
        eq(table.concat(list, ','), 'fib,sast', 'lower case, once each, in order')
    end)

    it('refuses what the start-up checks would refuse, in their words', function()
        local s = stack()
        local value, err, why = s.settings.check('Bailout.MinMultiplier', 4)
        eq(value, nil)
        eq(err, 'invalid_value')
        truthy(tostring(why):find('MinMultiplier is above MaxMultiplier', 1, true), tostring(why))
    end)

    it('refuses what the start-up checks would quietly change', function()
        local s = stack()
        local _, err, why = s.settings.check('Limits.DefaultDeadlineSeconds',
            Config.Limits.ContractLifetimeSeconds + 600)
        eq(err, 'invalid_value', 'a deadline past the lifetime')
        truthy(tostring(why):find('DefaultDeadlineSeconds', 1, true), tostring(why))
        _, err, why = s.settings.check('Limits.MinContractReward', Config.MaxContractValue + 1)
        eq(err, 'invalid_value', 'a least reward above the most a contract may be worth')
        truthy(tostring(why):find('MinContractReward', 1, true), tostring(why))
    end)

    it('changes nothing when it refuses', function()
        local s = stack()
        local before = Config.Bailout.MinMultiplier
        falsy(s.settings.set('Bailout.MinMultiplier', 9, 'STAFF', 'STAFF'))
        eq(Config.Bailout.MinMultiplier, before)
        eq(next(s.storage.readSettings()), nil, 'and keeps nothing')
    end)
end)

--------------------------------------------------------------------------
-- Changing a value
--------------------------------------------------------------------------

describe('changing a setting from the admin panel', function()
    it('is in force at once, kept, and on the record with who and what it was', function()
        local s = stack()
        local ok, err, detail = s.settings.set('Limits.MaxAcceptedPerHitman', 6, 'ADMIN001', 'ADMIN001')
        truthy(ok, tostring(err))
        eq(detail.old, 3)
        eq(Config.Limits.MaxAcceptedPerHitman, 6)
        local kept = s.storage.readSettings()['Limits.MaxAcceptedPerHitman']
        eq(kept.value, 6)
        eq(kept.by, 'ADMIN001')
        truthy(kept.at, 'and when')
        local rows = s.storage.auditByAction('admin_setting_changed', 5)
        eq(#rows, 1, 'written to the store at once')
        eq(rows[1].detail.old, 3)
        eq(rows[1].detail.new, 6)
        eq(rows[1].actor_cid, 'ADMIN001')
        local view = s.settings.view()
        for _, row in ipairs(view.limits) do
            if row.key == 'Limits.MaxAcceptedPerHitman' then
                eq(row.value, 6)
                eq(row.default, 3)
                eq(row.source, 'panel')
                eq(row.by, 'ADMIN001')
            end
        end
        eq(view.overrides, 1)
    end)

    it('takes the override away when it is set back to what config.lua says', function()
        local s = stack()
        truthy(s.settings.set('Relay.Enabled', false, 'A'))
        truthy(s.settings.set('Relay.Enabled', true, 'A'))
        eq(next(s.storage.readSettings()), nil, 'config.lua\'s again')
        eq(#s.settings.active(), 0)
    end)

    it('resets one, and refuses one that is not changed', function()
        local s = stack()
        truthy(s.settings.set('Informant.Cost', 100, 'A'))
        local ok, err = s.settings.reset('Informant.Cost', 'A')
        truthy(ok, tostring(err))
        eq(Config.Informant.Cost, 25000)
        eq(next(s.storage.readSettings()), nil)
        eq(#s.storage.auditByAction('admin_setting_reset', 5), 1)
        eq(select(2, s.settings.reset('Informant.Cost', 'A')), 'not_overridden')
    end)

    it('will not reset one back under another change it would break', function()
        local s = stack()
        truthy(s.settings.set('Bailout.MaxMultiplier', 5, 'A'))
        truthy(s.settings.set('Bailout.MinMultiplier', 4, 'A'))
        local ok, err, why = s.settings.reset('Bailout.MaxMultiplier', 'A')
        falsy(ok)
        eq(err, 'invalid_value')
        truthy(tostring(why):find('MinMultiplier', 1, true), tostring(why))
        eq(Config.Bailout.MaxMultiplier, 5, 'left as it was')
        truthy(s.settings.resetAll('A'), 'all of them together is always back to config.lua')
        eq(Config.Bailout.MaxMultiplier, 3)
        eq(Config.Bailout.MinMultiplier, 1)
        eq(next(s.storage.readSettings()), nil)
        eq(#s.storage.auditByAction('admin_settings_reset_all', 5), 1)
    end)

    it('saves one change at a time, so two cannot each pass beside the other\'s old value', function()
        local s = stack()
        local real = s.storage.writeSetting
        local inner
        -- What a mysql write allows: another request runs while this one
        -- waits on the store.
        s.storage.writeSetting = function(...)
            if not inner then
                inner = { s.settings.set('Bailout.MaxMultiplier', 2, 'B', 'B') }
            end
            return real(...)
        end
        local ok, err = s.settings.set('Bailout.MinMultiplier', 2.5, 'A', 'A')
        s.storage.writeSetting = real
        truthy(ok, tostring(err))
        eq(inner[1], false, 'the second is refused while the first is saved')
        eq(inner[2], CH.ERR.BUSY)
        eq(Config.Bailout.MinMultiplier, 2.5)
        eq(Config.Bailout.MaxMultiplier, 3, 'and the pair in force is one the start accepts')
        local again = { s.settings.set('Bailout.MaxMultiplier', 2, 'B', 'B') }
        eq(again[2], 'invalid_value', 'asked again, it is checked beside the first')
        truthy(s.settings.set('Relay.Enabled', false, 'B'), 'and the next change goes through')
    end)

    it('frees the lock when a change raises', function()
        local s = stack()
        truthy(s.settings.set('Relay.Enabled', false, 'A'))
        local realStaff = s.audit.staff
        s.audit.staff = function() error('audit raised', 0) end
        local raised = pcall(s.settings.set, 'Informant.Cost', 100, 'A')
        s.audit.staff = realStaff
        falsy(raised, 'the raise reaches the caller')
        truthy(s.settings.set('Relay.Enabled', true, 'A'), 'and nothing is left holding the lock')
    end)

    it('changes nothing when the store will not take it', function()
        local s = stack()
        local real = s.storage.writeSetting
        s.storage.writeSetting = function() error('disk full', 0) end
        local ok, err = s.settings.set('Relay.Enabled', false, 'A')
        s.storage.writeSetting = real
        falsy(ok)
        eq(err, 'store_failed')
        eq(Config.Relay.Enabled, true, 'not in force either: it would not outlive a restart')
    end)

    it('tells every player\'s game a setting it reads, and only those', function()
        local s = stack()
        eq(s.settings.clientValues(), nil, 'nothing to tell while config.lua stands')
        Env.clientEvents = {}
        truthy(s.settings.set('Informant.Cost', 100, 'A'))
        for _, event in ipairs(Env.clientEvents) do
            falsy(event.name == 'crimson-hitman:settings', 'not for a setting no game reads')
        end
        truthy(s.settings.set('Targeting.AllowNearby', true, 'A'))
        local told
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:settings' then told = event end
        end
        truthy(told, 'every game is told')
        eq(told.target, -1)
        eq(told.args[1]['Targeting.AllowNearby'], true)
        eq(told.args[1]['Informant.Cost'], nil, 'and nothing else is in it')
    end)

    it('tells a player who joins after the change', function()
        local s = stack()
        s.bridges.install(s)
        truthy(s.settings.set('Mugshot.RemoveBackground', true, 'A'))
        Env.clientEvents = {}
        _G.source = 2
        Env.events['crimson-hitman:whoAmI']()
        _G.source = nil
        local told
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:settings' then told = event end
        end
        truthy(told, 'told on asking who they are')
        eq(told.target, 2)
        eq(told.args[1]['Mugshot.RemoveBackground'], true)
    end)

    it('is listed by /ch-diag', function()
        local s = stack()
        truthy(s.settings.set('Relay.Enabled', false, 'ADMIN001'))
        local text = table.concat(s.admin.diagnose(0), '\n')
        truthy(text:find('admin panel settings in force over config.lua: 1', 1, true), text)
        truthy(text:find('Relay.Enabled = off', 1, true), text)
    end)
end)

--------------------------------------------------------------------------
-- Across a restart
--------------------------------------------------------------------------

describe('settings changed from the panel, across a restart', function()
    for _, name in ipairs(BACKENDS) do
        describe(name, function()
            it('are applied over config.lua at the next start', function()
                local s = stack()
                local store = freshStore(name)
                local settings = settingsOn(s, store)
                truthy(settings.set('Bailout.Enabled', false, 'ADMIN001'))
                truthy(settings.set('Advisory.TriggerJobNames', { 'fib', 'sast' }, 'ADMIN001'))
                truthy(settings.set('Kidnap.Radius', 9.5, 'ADMIN001'))

                -- The process dies: the config is config.lua again.
                resetConfig()
                eq(Config.Bailout.Enabled, true)
                local again = reopened(name, store)
                settings = settingsOn(s, again)
                eq(settings.boot(), 3, 'all three applied')
                eq(Config.Bailout.Enabled, false)
                eq(Config.Advisory.TriggerJobNames.fib, true)
                eq(Config.Advisory.TriggerJobNames.doj, nil, 'the list as staff left it')
                eq(Config.Kidnap.Radius, 9.5)
                local row
                for _, r in ipairs(settings.view().features) do
                    if r.key == 'Bailout.Enabled' then row = r end
                end
                eq(row.source, 'panel')
                eq(row.by, 'ADMIN001')
                eq(row.default, true, 'and what config.lua says beside it')
            end)

            it('keep kill photos and headshots switched off across a restart', function()
                local s = stack()
                local store = freshStore(name)
                local settings = settingsOn(s, store)
                truthy(settings.set('Completion.KillPhotos', false, 'ADMIN001'))
                truthy(settings.set('Mugshot.Enabled', false, 'ADMIN001'))
                eq(Config.Completion.KillPhotos, false, 'in force at once')
                eq(Config.Mugshot.Enabled, false)

                resetConfig()
                eq(Config.Completion.KillPhotos, true, 'the config as the suite runs it')
                eq(Config.Mugshot.Enabled, true)
                settings = settingsOn(s, reopened(name, store))
                eq(settings.boot(), 2, 'both applied at the next start')
                eq(Config.Completion.KillPhotos, false)
                eq(Config.Mugshot.Enabled, false)
                local rows = {}
                for _, r in ipairs(settings.view().features) do rows[r.key] = r end
                eq(rows['Completion.KillPhotos'].source, 'panel')
                eq(rows['Mugshot.Enabled'].source, 'panel')
                truthy(rows['Completion.PhotoStorage'].inactive,
                    'where photos are kept is marked as not applying')
                truthy(rows['Ledger.StorePhotos'].inactive, 'and so is keeping them')
                truthy(rows['Mugshot.RemoveBackground'].inactive, 'and the headshot\'s background')
                falsy(rows['Completion.Fulfilment'].inactive, 'and nothing that still applies')

                -- Back on from the panel, and that is what the next start finds.
                truthy(settings.set('Completion.KillPhotos', true, 'ADMIN001'))
                resetConfig()
                settings = settingsOn(s, reopened(name, store))
                settings.boot()
                eq(Config.Completion.KillPhotos, true)
                eq(Config.Mugshot.Enabled, false)
                resetConfig()
            end)

            it('stay reset after a restart', function()
                local s = stack()
                local store = freshStore(name)
                local settings = settingsOn(s, store)
                truthy(settings.set('Relay.Enabled', false, 'A'))
                truthy(settings.set('Informant.Cost', 10, 'A'))
                truthy(settings.reset('Relay.Enabled', 'A'))
                resetConfig()
                settings = settingsOn(s, reopened(name, store))
                eq(settings.boot(), 1)
                eq(Config.Relay.Enabled, true, 'the reset one is config.lua\'s')
                eq(Config.Informant.Cost, 10)
                truthy(settings.resetAll('A'))
                resetConfig()
                settings = settingsOn(s, reopened(name, store))
                eq(settings.boot(), 0, 'nothing after a reset of all of them')
            end)

            it('leave out one that no longer passes, and say so', function()
                local s = stack()
                local store = freshStore(name)
                store.writeSetting('Bailout.MinMultiplier', 5, 'A', 1)
                store.writeSetting('Audit.Webhook', 'https://x', 'A', 1)
                store.writeSetting('Database.Mode', 'mysql', 'A', 1)
                local printed = {}
                local real = _G.print
                _G.print = function(line) printed[#printed + 1] = tostring(line) end
                local settings = settingsOn(s, reopened(name, store))
                local applied = settings.boot()
                _G.print = real
                eq(applied, 0)
                eq(Config.Bailout.MinMultiplier, 1, 'config.lua\'s value is used')
                eq(Config.Database.Mode, 'json', 'and nothing read-only is touched')
                truthy(table.concat(printed, '\n'):find('not applied', 1, true))
                local skipped = 0
                for _, row in ipairs(settings.active()) do
                    if row.ignored then skipped = skipped + 1 end
                end
                eq(skipped, 3, 'listed, with why, for /ch-diag')
                truthy(settings.reset('Bailout.MinMultiplier', 'A'), 'and a reset clears one')
            end)

            it('apply a pair that depends on each other together, whichever sorts first', function()
                local s = stack()
                local store = freshStore(name)
                local settings = settingsOn(s, store)
                -- Each fine beside the other, and each set in the order that
                -- the sort at the next start turns round: MaxMultiplier sorts
                -- before MinMultiplier, ContractLifetime before DefaultDeadline.
                truthy(settings.set('Bailout.MinMultiplier', 0.5, 'A'))
                truthy(settings.set('Bailout.MaxMultiplier', 0.8, 'A'))
                truthy(settings.set('Limits.DefaultDeadlineSeconds', 3600, 'A'))
                truthy(settings.set('Limits.ContractLifetimeSeconds', 7200, 'A'))

                resetConfig()
                settings = settingsOn(s, reopened(name, store))
                eq(settings.boot(), 4, 'all four applied')
                eq(Config.Bailout.MinMultiplier, 0.5)
                eq(Config.Bailout.MaxMultiplier, 0.8)
                eq(Config.Limits.DefaultDeadlineSeconds, 3600)
                eq(Config.Limits.ContractLifetimeSeconds, 7200)
                for _, row in ipairs(settings.active()) do falsy(row.ignored, row.key .. ' applied') end
            end)

            it('apply what still fits when one does not, whatever order they sort in', function()
                local s = stack()
                local deadline = Config.Limits.DefaultDeadlineSeconds
                local store = freshStore(name)
                store.writeSetting('Bailout.MaxMultiplier', 0.8, 'A', 1)
                store.writeSetting('Bailout.MinMultiplier', 0.5, 'A', 1)
                store.writeSetting('Limits.DefaultDeadlineSeconds',
                    Config.Limits.ContractLifetimeSeconds + 600, 'A', 1)
                local printed = {}
                local real = _G.print
                _G.print = function(line) printed[#printed + 1] = tostring(line) end
                local settings = settingsOn(s, reopened(name, store))
                local applied = settings.boot()
                _G.print = real
                eq(applied, 2, 'the pair, though the most sorts first and does not fit config.lua\'s '
                    .. 'least alone')
                eq(Config.Bailout.MaxMultiplier, 0.8)
                eq(Config.Bailout.MinMultiplier, 0.5)
                eq(Config.Limits.DefaultDeadlineSeconds, deadline, 'config.lua\'s for the one that does not')
                local skipped = {}
                for _, row in ipairs(settings.active()) do
                    if row.ignored then skipped[#skipped + 1] = row.key end
                end
                eq(table.concat(skipped, ','), 'Limits.DefaultDeadlineSeconds')
                truthy(table.concat(printed, '\n'):find('DefaultDeadlineSeconds', 1, true),
                    'and the console says which, and why')
            end)

            it('never apply a stored value for the panel\'s own allowance, and let staff clear it', function()
                local s = stack()
                local burst = Config.Cooldowns.admin.burst
                local store = freshStore(name)
                store.writeSetting('Cooldowns.admin.burst', 1, 'A', 1)
                store.writeSetting('Cooldowns.admin.per', 3600, 'A', 1)
                local again = reopened(name, store)
                local settings = settingsOn(s, again)
                eq(settings.boot(), 0, 'kept from before it was read-only, and applied no more')
                eq(Config.Cooldowns.admin.burst, burst)
                truthy(settings.reset('Cooldowns.admin.burst', 'A'), 'a reset takes its row away')
                eq(again.readSettings()['Cooldowns.admin.burst'], nil)
                eq(select(2, settings.reset('Cooldowns.admin.burst', 'A')), 'read_only',
                    'and it is plain read-only after')
                eq(Config.Cooldowns.admin.burst, burst, 'nothing in force moved')
            end)
        end)
    end

    it('through the real start: applied before anything reads the config', function()
        local function forget()
            for key in pairs(package.loaded) do
                if type(key) == 'string' and (key:sub(1, 7) == 'server.' or key == 'server') then
                    package.loaded[key] = nil
                end
            end
        end
        forget()
        Env.reset()
        Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
        Natives.resetResourceStates()
        resetConfig()
        Config.Database.Mode = 'json'
        Natives.files = {}
        local s = require('server.main').start()
        truthy(s.settings.set('Bailout.Enabled', false, 'ADMIN001'))
        truthy(s.settings.set('Informant.Enabled', false, 'ADMIN001'))

        -- The process dies; the disk stays, and config.lua is as it was.
        forget()
        Env.events, Env.clientEvents, Env.notifications = {}, {}, {}
        Env.handlers, Env.threads, Env.timers, Env.commands = {}, {}, {}, {}
        resetConfig()
        Config.Database.Mode = 'json'
        local again = require('server.main').start()
        eq(Config.Bailout.Enabled, false, 'in force again')
        local f = fixture(again)
        local settings = again.projection.listing(f.hitman.cid).settings
        eq(settings.buyouts, false, 'and what the app is told comes from it')
        eq(select(2, again.informant.buy(f.target, 'ct00000001')), CH.ERR.FEATURE_OFF)
        resetConfig()
    end)
end)
