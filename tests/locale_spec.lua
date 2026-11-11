--- Translations (X1): every word players and staff read lives in the
--- language files (locales/en.lua for the server and the game,
--- locales/en.json for the phone app and the admin panel), looked up by key
--- in the language Config.Locale names, English where that language lacks
--- one.
---
--- Moved: every server file (notices, alerts, staff answers, the panel's
--- requests, the diagnosis and the staff commands, the buyout command, the
--- feature modules, the organisation, the setting labels and help), and
--- everything the game itself shows (client/). The scan below is what keeps
--- a sentence from being written into one of those files again.

local TextScan = require('tests.harness.textscan')
local Locale = require('crimson-hitman.shared.locale')
local Log = require('crimson-hitman.shared.log')

--- Files whose every sentence is a console line or an error the start
--- raises for the owner reading the console (which stays English): the
--- stores' start refusals and outage lines, the start's waits, the version
--- check. Never scanned.
local CONSOLE_FILES = {
    ['server/storage/mysql.lua'] = true, ['server/storage/json.lua'] = true,
    ['server/storage/memory.lua'] = true, ['server/boot.lua'] = true, ['server/versioncheck.lua'] = true,
}

--- The files whose words are all in the language files: none may hold a
--- sentence of its own. Every server file but CONSOLE_FILES, and the game's.
local SCANNED = {
    'client/main.lua', 'client/missionsteps.lua', 'client/admin.lua', 'client/org.lua',
    'client/rp_npc.lua', 'client/npc.lua', 'client/mugshot.lua',
}
do
    local files = io.popen('ls crimson-hitman/server/*.lua crimson-hitman/server/*/*.lua')
    for path in files:lines() do
        local rel = path:gsub('^crimson%-hitman/', '')
        if not CONSOLE_FILES[rel] then SCANNED[#SCANNED + 1] = rel end
    end
    files:close()
end

--- What the scan reads as words in every file and is not: names the code
--- passes and never shows. Config sections and keys (read(Config, ...),
--- Feature.on('Mugshot'), the organisation's extras by name), key prefixes
--- ('Intel.', 'Organisation.Limits.'), ox_inventory's Search export.
local NAMES = {}
for name in ([[Account Alerts Amendments Anonymity Audit Bailout Bonus Completion Cost Depth Enabled Holds
    Immunity Informant Intel Kidnap Ledger Limits Mugshot Penalty Radius Reason Relay Sources Staff Duty
    Organisation Recruitment Roles Armory Channel Codenames Discipline Dossiers Garage Payroll Probation
    Stats Handler Reputation Territory Heat Progression Tiers Handover Protection Disposal Debug Ace
    Search Locale]]):gmatch('%S+') do NAMES[name] = true end
for _, prefix in ipairs({ 'Admin.Commands.', 'Record.', 'Roleplay.', 'Intel.', 'Improvements.',
    'Integrations.', 'Organisation.Limits.', 'Cooldowns.', 'command.', 'contract.', 'count.', 'handover.' }) do
    NAMES[prefix] = true
end

--- And by file: each with why.
local ALLOW = {
    -- The reason a city news post was not made, said only in the console
    -- line two lines below it.
    ['server/police.lua'] = { ['no phone adapter answers (Config.Integrations.Phone)'] = true },
    -- The preset name kept in an audit row, which is data; and a console line.
    ['server/panel.lua'] = { ['Current'] = true, ["the admin panel\\'s %s raised: %s"] = true },
    -- The shipped presets' names, which are what they are applied, saved
    -- and audited by.
    ['server/presets.lua'] = { ['Current'] = true, ['Strict'] = true, ['Relaxed'] = true },
    -- A date format (os.date).
    ['server/admin.lua'] = { ['!%Y-%m-%d %H:%M UTC'] = true },
    -- The name the page's own fault report goes by, compared.
    ['server/app.lua'] = { ['page diagnostics'] = true },
    -- The body of a photo address that serves nothing: no person reads it.
    ['server/bridges.lua'] = { ['Not found.'] = true },
    -- The alias messages were signed with before, still on stored rows.
    ['server/comms.lua'] = { ['Client'] = true },
    -- The database's own errors, matched to know a deadlock from a timeout.
    ['server/contracts.lua'] = { ['Deadlock found'] = true, ['Lock wait timeout'] = true,
        ['was unable to execute a query'] = true },
    -- FiveM's error for an export that is not there, matched.
    ['server/identity.lua'] = { ['No such export'] = true },
    -- The answer stored before a look-up that found nobody was marked so.
    ['server/intel/informants.lua'] = { ['Unknown operative'] = true },
    -- The grade the job is registered with in qbx_core: qbx_core's data.
    ['server/org/jobs.lua'] = { ['Member'] = true },
    -- lb-phone's camera mode name (SetCameraComponent), not a word shown.
    ['client/main.lua'] = { ['Photo'] = true },
    -- Console lines from the start, through local helpers (reindexed, add).
    ['server/main.lua'] = {},
}
for _, line in ipairs({ 'a change proposed before this start does not lapse on its own',
    'a contract on an officer taken while acceptance bulletins are off may be listed ',
    'a contract placed just before it is shown to its target at once, unannounced',
    'a hold taken before this start is not released for being idle', 'as open once they are back on',
    'custom restraint detection for handovers', 'placing masked calls between parties',
    'playtime for the new-player immunity rule', 'the list of contracts with open proposed changes',
    'the list of held contracts', 'the waits before targets are told of new contracts',
    'what the whitelisted-job view says of taken contracts' }) do
    ALLOW['server/main.lua'][line] = true
end

--- The settings' group names (server/settings.lua, its catalogue and the
--- organisation's): the English name is the group's id, read by
--- AREA_OF_GROUP, MONEY and the panel's own checks; what staff read is
--- its label, settings_group.* (Settings.groupLabel).
local function groupIds()
    local ids = {}
    for key, text in pairs(require('crimson-hitman.locales.en')) do
        if key:find('^settings_group%.') then ids[text] = true end
    end
    return ids
end

local function allowed(path)
    local out = {}
    for text in pairs(NAMES) do out[text] = true end
    for text in pairs(ALLOW[path] or {}) do out[text] = true end
    if path == 'server/settings.lua' or path:find('settings_catalogue') then
        for text in pairs(groupIds()) do out[text] = true end
    end
    return out
end

local function src(path) return read_file('crimson-hitman/' .. path) end

local function englishTable()
    package.loaded['crimson-hitman.locales.en'] = nil
    return require('crimson-hitman.locales.en')
end

describe('Translations: the language files', function()
    it('every key the code asks for is in locales/en.lua', function()
        local en = englishTable()
        local missing, asked = {}, 0
        local files = io.popen('ls crimson-hitman/server/*.lua crimson-hitman/server/*/*.lua '
            .. 'crimson-hitman/client/*.lua crimson-hitman/shared/*.lua')
        for path in files:lines() do
            for key, line in pairs(TextScan.keysUsed(read_file(path))) do
                asked = asked + 1
                if type(en[key]) ~= 'string' then missing[#missing + 1] = path .. ':' .. line .. ' ' .. key end
            end
        end
        files:close()
        table.sort(missing)
        truthy(asked >= 120, asked .. ' keys asked for')
        eq(table.concat(missing, ', '), '', 'keys used and not in locales/en.lua')
    end)

    it('no file moved over holds a sentence of its own', function()
        local left = {}
        for _, path in ipairs(SCANNED) do
            for _, lit in ipairs(TextScan.hardCoded(src(path), allowed(path))) do
                left[#left + 1] = ('%s:%d %q'):format(path, lit.line, lit.text)
            end
        end
        eq(table.concat(left, ', '), '', 'words still written into the code')
    end)

    it('the scan finds a sentence written back into a file', function()
        local found = TextScan.hardCoded("Notify.toCitizen(cid, 'Contract closed', ('Staff closed it.'))\n"
            .. "Log.always('a console line is not counted')\nlocal k = L('notify.contract_closed')\n")
        eq(#found, 2, 'the title and the sentence; not the console line or the key')
        eq(found[1].text, 'Contract closed')
    end)

    it('every key the pages ask for is in locales/en.json, and their tables came out of the code', function()
        local text = read_file('crimson-hitman/locales/en.json')
        local function hasKey(section, key)
            local body = text:match('"' .. section .. '"%s*:%s*(%b{})')
            return body ~= nil and body:find('"' .. key:gsub('%p', '%%%0') .. '"%s*:') ~= nil
        end
        for _, page in ipairs({ 'ui/app.js', 'ui/admin.js' }) do
            local js = src(page)
            for key in js:gmatch("Text%.t%('([%w_]+%.[%w_]+)'%)") do
                local section, name = key:match('^([%w_]+)%.(.+)$')
                truthy(hasKey(section, name), page .. ' asks for ' .. key)
            end
            for section in js:gmatch("Text%.section%('([%w_]+)'%)") do
                truthy(text:find('"' .. section .. '"%s*:%s*{'), page .. ' reads section ' .. section)
            end
        end
        falsy(src('ui/app.js'):find('var ERRORS = {', 1, true), 'the phone\'s refusals are in en.json')
        falsy(src('ui/admin.js'):find('var WORDS = {', 1, true), 'the panel\'s refusals are in en.json')
        truthy(hasKey('errors', 'rate_limited') and hasKey('panel_errors', 'not_allowed'))
    end)

    it('both pages and the game load them, and an escrowed build leaves them readable', function()
        local manifest = src('fxmanifest.lua')
        truthy(manifest:find("'locales/%*%.lua',%s*'shared/locale%.lua'"), 'the game loads the words, then the lookup')
        truthy(manifest:find("'locales/%*%.json'"), 'the pages may read the json')
        local ignore = manifest:match('escrow_ignore%s*(%b{})')
        truthy(ignore and ignore:find("'locales/%*%.lua'", 1, false), 'never escrowed')
        eq(Config.Locale, 'en', 'English as shipped')
        truthy(src('config/defaults.lua'):find("ConfigDefaults.Locale = 'en'", 1, true))
        truthy(src('client/main.lua'):find("'&lang=' .. CrimsonLocale.language()", 1, true), 'the phone is told')
        truthy(src('client/admin.lua'):find('locale = CrimsonLocale.language()', 1, true), 'the panel is told')
    end)
end)

describe('Translations: words read by key, never matched by their words', function()
    it('a setting keeps its English group as its id and shows its label in the language', function()
        local real = Config.Locale
        CrimsonLocales.zz = { ['settings_group.access'] = 'Zugang' }
        local ok, err = pcall(function()
            local s = newStack()
            Locale.reset()
            Config.Locale = 'zz'
            local row
            for _, r in ipairs(s.settings.view().features) do
                if r.key == 'BlockOffDuty' then row = r end
            end
            truthy(row, 'BlockOffDuty listed')
            eq(row.group, 'Access', 'the id the area and the page read')
            eq(s.settings.groupLabel('Access'), 'Zugang')
            eq(s.settings.groupLabel('No such group'), 'No such group', 'one with no label reads as itself')
            eq(row.groupLabel, 'Zugang', 'the page is sent the label')
            local en = englishTable()
            for group, key in pairs(s.settings.GROUP_LABEL) do
                eq(en[key], group, 'settings_group key ' .. key .. ' reads its group in English')
            end
        end)
        Config.Locale = real
        CrimsonLocales.zz = nil
        Locale.reset()
        if not ok then error(err, 0) end
        local s = newStack()
        for _, r in ipairs(s.settings.view().features) do
            if r.key == 'BlockOffDuty' then eq(r.groupLabel, 'Access', 'English as shipped') end
        end
    end)

    it('the panel builds its ACE answers from parts, never by cutting a sentence', function()
        local s = newStack()
        local needs, grant = s.admin.grantFor('crimson.dev')
        eq(needs, 'this needs the crimson.dev ACE. ')
        eq(grant, 'Grant it with add_ace group.admin crimson.dev allow, pasted into the server console '
            .. 'until the next restart, or put in server.cfg to keep it.')
        eq(s.admin.howToAuthorise('crimson.dev', true), 'Not authorised: ' .. needs .. grant,
            'the panel\'s refusal reads as before')
        falsy(read_file('crimson-hitman/server/panel.lua'):find(':gsub(\'^Not authorised', 1, true))
    end)
end)

describe('Translations: a language that lacks a key', function()
    local function capture(fn)
        local said, realAlways, realDebug = {}, Log.always, Log.debug
        Log.always = function(text) said[#said + 1] = { 'always', text } end
        Log.debug = function(text) said[#said + 1] = { 'debug', text } end
        local ok, err = pcall(fn)
        Log.always, Log.debug = realAlways, realDebug
        if not ok then error(err, 0) end
        return said
    end

    it('reads in English, and the console says so once', function()
        local real = Config.Locale
        CrimsonLocales.zz = { ['notify.contract_closed'] = 'Vertrag geschlossen' }
        Locale.reset()
        Config.Locale = 'zz'
        local said = capture(function()
            eq(Locale.t('notify.contract_closed'), 'Vertrag geschlossen', 'the language\'s own')
            eq(Locale.t('notify.contract_expired'), 'Contract expired', 'English where it has none')
            eq(Locale.t('notify.contract_expired'), 'Contract expired')
            eq(Locale.t('notify.breathing_room'), 'Breathing room')
        end)
        Config.Locale = real
        CrimsonLocales.zz = nil
        Locale.reset()
        eq(#said, 2, 'once per key')
        eq(said[1][1], 'always', 'the first missing key whatever Debug says')
        truthy(said[1][2]:find('zz has no text for notify.contract_expired', 1, true), said[1][2])
        eq(said[2][1], 'debug', 'the next with Debug on')
    end)

    it('a language with no file reads English, said once', function()
        local real = Config.Locale
        Locale.reset()
        Config.Locale = 'nonesuch'
        local said = capture(function()
            eq(Locale.t('notify.contract_closed'), 'Contract closed')
            eq(Locale.t('notify.contract_expired'), 'Contract expired')
        end)
        Config.Locale = real
        Locale.reset()
        eq(#said, 1)
        truthy(said[1][2]:find('there is no locales/nonesuch.lua', 1, true), said[1][2])
    end)

    it('a key no language has reads as the key, said once', function()
        Locale.reset()
        local said = capture(function()
            eq(Locale.t('notify.no_such_key'), 'notify.no_such_key')
            eq(Locale.t('notify.no_such_key'), 'notify.no_such_key')
        end)
        Locale.reset()
        eq(#said, 1)
        eq(said[1][1], 'always')
    end)

    it('a notice reads the same words as before (rule 7)', function()
        local s = newStack()
        local title, body = s.notify.hitmanReceipt({ target_name = 'Pia Nolan' }, true, { money = 5000 })
        eq(title, 'Handover paid')
        eq(body, 'Delivered alive: $5,000 released to you.')
    end)
end)
