--- The admin panel's sections (ui/admin.js GROUPS) as the server keeps
--- them: every catalogue key in one category, every config.lua setting
--- either changeable from the panel or on the deny list, the new kinds
--- (text, range, lists of other names) checked on the server, and the
--- Developer section behind Config.Admin.DeveloperAce, with the staff ACE
--- itself keeping it, so nobody is locked out of what they had.

local CHECK = require('crimson-hitman.server.main').checkCandidate

local VALID = {
    ['rules-timers'] = true, ['rules-rewards'] = true, ['rules-limits'] = true,
    ['rules-targeting'] = true, features = true, developer = true,
}

local function stack()
    local s = newStack()
    local f = fixture(s)
    s.settings.init({ storage = s.storage, audit = s.audit, check = CHECK })
    return s, f
end

--- The panel's stack, with staff: 6 the staff ACE, 7 an extra ACE only,
--- 9 an extra ACE and the developer ACE.
local function panelStack()
    local s = newStack()
    local f = fixture(s)
    Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
        firstname = 'Sam', lastname = 'Steward' })
    Env.addPlayer({ source = 7, citizenid = 'READER01', license = 'license:READER01',
        firstname = 'Rae', lastname = 'Dent' })
    Env.addPlayer({ source = 9, citizenid = 'DEVELO01', license = 'license:DEVELO01',
        firstname = 'Dev', lastname = 'Eloper' })
    Env.aces[6] = { ['crimson.admin'] = true }
    Env.aces[7] = { command = true }
    Env.aces[9] = { command = true, ['crimson.developer'] = true }
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

--- config.lua as the file ships it, run on its own.
local function shippedConfig()
    local handle = assert(io.open('crimson-hitman/config/config.lua', 'r'))
    local text = handle:read('a')
    handle:close()
    local env = setmetatable({}, { __index = _G })
    assert(load(text, '=config.lua', 't', env))()
    return rawget(env, 'Config')
end

--- Two values the same, tables compared key by key.
local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local function eqv(actual, expected, message)
    truthy(same(actual, expected), (message or 'mismatch') .. ': got '
        .. (json and json.encode(actual) or tostring(actual)))
end

local function rows(view)
    local out = {}
    for _, list in ipairs({ 'features', 'limits', 'readonly' }) do
        for _, row in ipairs(view[list] or {}) do out[#out + 1] = row end
    end
    return out
end

describe('the catalogue, by who uses it', function()
    it('puts every entry in one valid category, and every switch in Features or Developer', function()
        local s = stack()
        local bad, seen = {}, {}
        for _, entry in ipairs(s.settings.CATALOGUE) do
            if not VALID[entry.category] then bad[#bad + 1] = entry.key .. ': ' .. tostring(entry.category) end
            if entry.kind == 'switch' and entry.category ~= 'features' and entry.category ~= 'developer' then
                bad[#bad + 1] = entry.key .. ' is a switch in ' .. entry.category
            end
            if seen[entry.key] then bad[#bad + 1] = entry.key .. ' twice' end
            seen[entry.key] = true
            truthy(entry.section and entry.group, entry.key .. ' keeps its section and group')
        end
        eq(#bad, 0, table.concat(bad, ', '))
    end)

    it('shows Features as switches only', function()
        local s = stack()
        for _, entry in ipairs(s.settings.CATALOGUE) do
            if entry.category == 'features' then eq(entry.kind, 'switch', entry.key) end
        end
    end)

    it('has every reward and money setting in Rewards & money exactly once, in its money group', function()
        local s = stack()
        local GROUPS = { Rewards = true, Payouts = true, Buyouts = true, ['Informant prices'] = true,
            ['Anonymity fees'] = true, Escrow = true }
        local count = {}
        for _, entry in ipairs(s.settings.CATALOGUE) do
            if entry.category == 'rules-rewards' then
                truthy(GROUPS[entry.money], entry.key .. ' is in a money group: ' .. tostring(entry.money))
            end
            count[entry.key] = (count[entry.key] or 0) + 1
        end
        for key, group in pairs(s.settings.MONEY) do
            eq(count[key], 1, key .. ' once')
            eq(s.settings.entry(key).category, 'rules-rewards', key)
            truthy(GROUPS[group], key)
        end
        for _, key in ipairs({ 'MaxContractValue', 'Sources.cash.max', 'Limits.MinContractReward',
            'Limits.MaxPayoutSlots', 'Bailout.AbsoluteMax', 'Informant.Cost', 'LocationTip.Cost',
            'Anonymity.CreatorFee', 'EscrowBlacklist', 'Penalty.MaxAmount' }) do
            eq(s.settings.entry(key).category, 'rules-rewards', key)
        end
    end)

    it('sends the category, the money group and the shipped default with every row', function()
        local s = stack()
        for _, row in ipairs(rows(s.settings.view())) do
            truthy(VALID[row.category], row.key .. ' has its category')
        end
        local cap
        for _, row in ipairs(rows(s.settings.view())) do
            if row.key == 'MaxContractValue' then cap = row end
        end
        eq(cap.money, 'Rewards')
        eq(cap.shipped, ConfigDefaults.MaxContractValue)
        eq(cap.hasShipped, true)
    end)
end)

describe('every setting in config.lua', function()
    it('is in the catalogue or on the deny list, so a new one must be placed', function()
        local s = stack()
        local missing = {}
        local function covered(path)
            return s.settings.entry(path) ~= nil or s.settings.DENY[path] ~= nil
        end
        local function walk(value, path)
            if path and covered(path) then return end
            if type(value) == 'table' and path ~= nil then
                local isList = #value > 0
                -- A set (every value true, the keys names) is one setting;
                -- a record of switches has its fields in the catalogue.
                local isSet = next(value) ~= nil
                for k, v in pairs(value) do
                    if type(k) ~= 'string' or v ~= true or covered(path .. '.' .. k) then isSet = false end
                end
                if isList or isSet then missing[#missing + 1] = path return end
            end
            if type(value) == 'table' then
                for k, v in pairs(value) do
                    walk(v, path and (path .. '.' .. tostring(k)) or tostring(k))
                end
                return
            end
            missing[#missing + 1] = path
        end
        walk(shippedConfig(), nil)
        table.sort(missing)
        eq(#missing, 0, 'settings neither changeable nor denied: ' .. table.concat(missing, ', '))
    end)

    it('denies, by name, the secrets, the storage mode and folder, and the ACE names', function()
        local s = stack()
        for _, key in ipairs({ 'Database.Mode', 'Database.Json.Directory', 'Admin.Ace', 'Admin.IdentityAce',
            'Admin.DeveloperAce', 'Admin.ExtraAces', 'convar:crimson_hitman_webhook',
            'convar:crimson_hitman_alert_webhook' }) do
            truthy(s.settings.DENY[key], key .. ' is on the deny list')
            local value, err, why = s.settings.check(key, 'anything')
            eq(value, nil, key)
            eq(err, 'read_only', key)
            truthy(why and why ~= '', key .. ' says why')
        end
        truthy(s.settings.DENY['convar:crimson_hitman_webhook'].secret, 'a webhook is a secret')
    end)

    it('shows a secret only as set or not set, never its value', function()
        local s = stack()
        Natives.convars.crimson_hitman_webhook = 'https://discord.com/api/webhooks/1/secret-token'
        local found
        for _, row in ipairs(rows(s.settings.view())) do
            if row.key == 'convar:crimson_hitman_webhook' then found = row end
            for _, v in pairs(row) do
                falsy(type(v) == 'string' and v:find('secret-token', 1, true), 'the token reached the panel')
            end
        end
        truthy(found, 'listed')
        eq(found.value, 'set')
        eq(found.category, 'developer')
        Natives.convars.crimson_hitman_webhook = nil
    end)

    it('refuses a deny-listed key the page sends anyway, from the staff ACE itself', function()
        panelStack()
        local before = Config.Admin.Ace
        for _, key in ipairs({ 'Admin.Ace', 'Admin.DeveloperAce', 'Database.Mode', 'Database.Json.Directory',
            'convar:crimson_hitman_webhook' }) do
            local reply = ask(6, 'setSetting', { key = key, value = 'group.everyone' })
            eq(reply.ok, false, key)
            eq(reply.err, 'read_only', key)
        end
        eq(Config.Admin.Ace, before, 'nothing changed')
    end)
end)

describe('the editors\' shapes, checked on the server', function()
    it('takes a job list added to and removed from, and refuses a bad name', function()
        local s = stack()
        truthy(s.settings.set('BlockedJobNames', { 'police', 'Sheriff', 'gruppe6' }, 'ADMIN001', 'ADMIN001'))
        eqv(Config.BlockedJobNames, { gruppe6 = true, police = true, sheriff = true },
            'kept as the set config.lua holds')
        truthy(s.settings.set('BlockedJobNames', { 'police' }, 'ADMIN001', 'ADMIN001'))
        eqv(Config.BlockedJobNames, { police = true }, 'one removed')
        local ok, err, why = s.settings.set('BlockedJobNames', { 'police', 'bad name!' }, 'ADMIN001', 'ADMIN001')
        eq(ok, false)
        eq(err, 'invalid_value')
        truthy(tostring(why):find('letters, digits', 1, true), tostring(why))
        eq(select(2, s.settings.set('BlockedJobNames', { key = 'police' }, 'ADMIN001', 'ADMIN001')), 'invalid_value',
            'a map where a list belongs')
        eqv(Config.BlockedJobNames, { police = true }, 'nothing changed by a refusal')
    end)

    it('keeps an ordered list in order, with other kinds of name', function()
        local s = stack()
        truthy(s.settings.set('Reason.Presets', { 'Debt', 'Snitching', 'Turf' }, 'ADMIN001', 'ADMIN001'))
        eqv(Config.Reason.Presets, { 'Debt', 'Snitching', 'Turf' })
        eq(select(2, s.settings.set('Reason.Presets', { '<script>' }, 'ADMIN001', 'ADMIN001')), 'invalid_value')
        truthy(s.settings.set('Mugshot.AllowedMime', { 'image/png' }, 'ADMIN001', 'ADMIN001'))
        eqv(Config.Mugshot.AllowedMime, { ['image/png'] = true })
        eq(select(2, s.settings.set('Mugshot.AllowedMime', { 'png' }, 'ADMIN001', 'ADMIN001')), 'invalid_value')
    end)

    it('takes a from-to pair, and refuses one the wrong way round or with more in it', function()
        local s = stack()
        truthy(s.settings.set('Notifications.ParanoidAlertJitter', { min = 30, max = 300 }, 'ADMIN001', 'ADMIN001'))
        eqv(Config.Notifications.ParanoidAlertJitter, { min = 30, max = 300 })
        for _, bad in ipairs({ { min = 300, max = 30 }, { min = 1, max = 2, extra = 3 }, { 30, 300 }, 'thirty',
            { min = 1.5, max = 3 } }) do
            eq(select(2, s.settings.set('Notifications.ParanoidAlertJitter', bad, 'ADMIN001', 'ADMIN001')),
                'invalid_value')
        end
        eqv(Config.Notifications.ParanoidAlertJitter, { min = 30, max = 300 })
    end)

    it('takes a word for a text key, and nothing else', function()
        local s = stack()
        truthy(s.settings.set('Progression.Resource', 'my-blackmarket', 'ADMIN001', 'ADMIN001'))
        eq(Config.Progression.Resource, 'my-blackmarket')
        eq(select(2, s.settings.set('Progression.Resource', 'a b', 'ADMIN001', 'ADMIN001')), 'invalid_value')
        eq(select(2, s.settings.set('Progression.Resource', 12, 'ADMIN001', 'ADMIN001')), 'invalid_value')
    end)

    it('marks a key read once at start as applying after a restart', function()
        local s = stack()
        for _, row in ipairs(rows(s.settings.view())) do
            if row.key == 'Bailout.Command' or row.key == 'Admin.Commands.panel' then
                eq(row.live, false, row.key)
            end
            if row.key == 'MaxContractValue' then eq(row.live, true) end
        end
    end)

    it('audits a change to a new key with its key, old and new value', function()
        local s = stack()
        truthy(s.settings.set('Reason.MaxLength', 100, 'ADMIN001', 'ADMIN001'))
        local row = s.storage.auditByAction('admin_setting_changed', 5)[1]
        eq(row.detail.key, 'Reason.MaxLength')
        eq(row.detail.old, 140)
        eq(row.detail.new, 100)
    end)
end)

describe('newly changeable settings, in force at once', function()
    it('one in each section', function()
        local s = stack()
        local SAMPLE = {
            { 'Kidnap.RearmCooldownSeconds', 90, 'rules-timers' },
            { 'Sources.cash.max', 1000, 'rules-rewards' },
            { 'Reason.MaxLength', 80, 'rules-limits' },
            { 'Immunity.MinTargetSessionMinutes', 0, 'rules-targeting' },
            { 'Diagnostics.SlowJobMs', 40, 'developer' },
        }
        for _, sample in ipairs(SAMPLE) do
            local key, value, category = sample[1], sample[2], sample[3]
            eq(s.settings.entry(key).category, category, key)
            local ok, err = s.settings.set(key, value, 'ADMIN001', 'ADMIN001')
            truthy(ok, key .. ': ' .. tostring(err))
            local node = Config
            for part in key:gmatch('[^%.]+') do node = node[part] end
            eq(node, value, key .. ' in the config every module reads')
        end
    end)

    it('a lower cash cap refuses the next contract over it', function()
        local s, f = stack()
        truthy(s.settings.set('Sources.cash.max', 1000, 'ADMIN001', 'ADMIN001'))
        local c, err = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        eq(c, nil, 'refused over the new cap')
        truthy(err, 'with why')
        truthy(s.settings.set('Sources.cash.max', 250000, 'ADMIN001', 'ADMIN001'))
        c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        truthy(c, 'and taken under the old one again')
    end)
end)

describe('the Developer section', function()
    it('is the developer ACE\'s, and the staff ACE\'s too, never an extra ACE\'s alone', function()
        local s = panelStack()
        eq(s.panel.developer(6), true, 'the staff ACE keeps it: nobody is locked out')
        eq(s.panel.developer(9), true, 'the developer ACE')
        eq(s.panel.developer(7), false, 'an extra ACE alone')
        eq(s.panel.developer(3), false, 'a player')
    end)

    it('leaves the developer settings out for staff without it', function()
        panelStack()
        local reader = ask(7, 'settings', {})
        eq(reader.ok, true)
        for _, row in ipairs(rows(reader.data)) do
            falsy(row.category == 'developer', row.key .. ' reached staff without the developer ACE')
        end
        eq(reader.data.developerHidden, true)
        local developer = ask(9, 'settings', {})
        local any = false
        for _, row in ipairs(rows(developer.data)) do any = any or row.category == 'developer' end
        truthy(any, 'the developer ACE reads them')
    end)

    it('lets the developer ACE alone change and reset its own section\'s settings, and nothing else', function()
        panelStack()
        local set = ask(9, 'setSetting', { key = 'Debug', value = true })
        eq(set.ok, true, tostring(set.message))
        eq(Config.Debug, true)
        local reset = ask(9, 'resetSetting', { key = 'Debug' })
        eq(reset.ok, true, tostring(reset.message))
        -- Every other write stays the staff ACE's: another section's key, a
        -- deny-listed one, and any other write.
        eq(ask(9, 'setSetting', { key = 'Anonymity.ShowPlacerOnBoard', value = true }).err, 'not_allowed')
        eq(ask(9, 'resetSetting', { key = 'Anonymity.ShowPlacerOnBoard' }).err, 'not_allowed')
        eq(ask(9, 'setSetting', { key = 'Admin.Ace', value = 'x' }).err, 'not_allowed')
        eq(ask(9, 'resetSettings', {}).err, 'not_allowed')
        eq(ask(9, 'freeze', { subject = 2, reason = 'x' }).err, 'not_allowed')
        -- And an extra ACE alone writes none of it.
        eq(ask(7, 'setSetting', { key = 'Debug', value = true }).err, 'not_allowed')
        eq(Config.Debug, false)
    end)

    it('refuses the console to staff without it, saying how to grant it', function()
        panelStack()
        local reply = ask(7, 'console', {})
        eq(reply.err, 'developer_required')
        truthy(reply.message:find('add_ace group.admin crimson.developer allow', 1, true), reply.message)
        eq(ask(9, 'console', {}).ok, true)
        eq(ask(6, 'console', {}).ok, true)
    end)

    it('tells the staff ACE how to grant its own ACE, and nobody who holds it', function()
        panelStack()
        local owner = ask(6, 'access', {}).data
        eq(owner.canDevelop, true)
        truthy(owner.developerHint and owner.developerHint:find('crimson.developer', 1, true),
            tostring(owner.developerHint))
        local dev = ask(9, 'access', {}).data
        eq(dev.canDevelop, true)
        eq(dev.developerHint, nil)
        eq(ask(7, 'access', {}).data.canDevelop, false)
    end)

    it('lists every ACE on Permissions, held or not, with the line that grants it', function()
        panelStack()
        local list = ask(7, 'access', {}).data.permissions
        local by = {}
        for _, p in ipairs(list) do by[p.ace] = p end
        for _, ace in ipairs({ 'crimson.admin', 'crimson.identity', 'crimson.developer', 'command' }) do
            truthy(by[ace], ace .. ' listed')
            truthy(by[ace].unlocks and by[ace].grant, ace .. ' says what it opens and how to grant it')
        end
        eq(by.command.held, true)
        eq(by['crimson.admin'].held, false)
        truthy(by['crimson.developer'].grant:find('add_ace group.admin crimson.developer allow', 1, true))
        truthy(by['crimson.identity'].grant:find('not group.admin', 1, true), 'unmasking is for fewer people')
    end)
end)
