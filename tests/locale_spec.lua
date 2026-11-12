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

local PageScan = require('tests.harness.pagescan')

--- locales/en.json, read once.
local pageWords = nil
local function englishPages()
    pageWords = pageWords or json.decode(read_file('crimson-hitman/locales/en.json'))
    return pageWords
end

local function pageKey(words, key)
    local section, name = key:match('^([%w_]+)%.(.+)$')
    return section ~= nil and type(words[section]) == 'table' and type(words[section][name]) == 'string'
end

--- The pages whose words are all in locales/en.json.
local MOVED_PAGES = { 'ui/app.js', 'ui/admin.js' }

--- What the page scan reads as words and is not, by page: each with why.
local PAGE_ALLOW = {
    ['ui/app.js'] = {
        -- The page's fault reports, read in the server console.
        ['further page errors suppressed'] = true, ['page diagnostics'] = true,
        ['diagnostics requested by the player'] = true,
        -- A class name with its last part added.
        ['diag-row is-'] = true,
        -- The code of an answer that never came, looked up in errors.
        ['no reply'] = true,
    },
    ['ui/admin.js'] = {
        -- A class name with its last part added.
        ['toast is-'] = true,
        -- The section heads' ids (nh-daily ...); their words are admin.html's.
        ['Daily'] = true, ['Setup'] = true, ['Records'] = true,
        -- The server's group ids and key prefixes, matched (Settings.groupLabel
        -- gives the words).
        ['Boss limits'] = true, ['Intel.'] = true, ['Record.'] = true, ['Roleplay.'] = true,
        ['Cooldowns.'] = true, ['st-save-Cooldowns.'] = true, ['rate limits'] = true,
    },
}

--- Joined with + and not words a player reads, by page: each with why.
local JOINED_ALLOW = {
    ['ui/app.js'] = {
        -- The page's fault reports (Diag), read in the server console.
        ['build '] = true, [' reported'] = true, [' suppressed'] = true, ['action '] = true,
        -- A class name with its last part added.
        ['diag-row is-'] = true,
    },
    ['ui/admin.js'] = {
        -- The markup builder's own attribute, and a class name with its last part added.
        [' class="'] = true, ['toast is-'] = true,
        -- A config path shown as code (Config.Cooldowns.<bucket>).
        [' = { per, burst }'] = true,
    },
}

local function englishTable()
    package.loaded['crimson-hitman.locales.en'] = nil
    return require('crimson-hitman.locales.en')
end

describe('Translations: the language files', function()
    it('every key the code asks for is in locales/en.lua (the game\'s in locales/client/en.lua)', function()
        local en = englishTable()
        package.loaded['crimson-hitman.locales.client.en'] = nil
        local game = require('crimson-hitman.locales.client.en')
        local missing, asked = {}, 0
        local files = io.popen('ls crimson-hitman/server/*.lua crimson-hitman/server/*/*.lua '
            .. 'crimson-hitman/client/*.lua crimson-hitman/shared/*.lua')
        for path in files:lines() do
            local client = path:find('/client/', 1, true) ~= nil
            for key, line in pairs(TextScan.keysUsed(read_file(path))) do
                asked = asked + 1
                -- R1: the game is sent its own words only, and the server
                -- never reads them.
                local isGame = key:sub(1, 7) == 'client.'
                if client ~= isGame then
                    missing[#missing + 1] = path .. ':' .. line .. ' ' .. key .. ' (on the wrong side)'
                elseif type((isGame and game or en)[key]) ~= 'string' then
                    missing[#missing + 1] = path .. ':' .. line .. ' ' .. key
                end
            end
        end
        for key in pairs(en) do
            if key:sub(1, 7) == 'client.' then missing[#missing + 1] = 'locales/en.lua ' .. key .. ' (the game\'s)' end
        end
        for key in pairs(game) do
            if key:sub(1, 7) ~= 'client.' then missing[#missing + 1] = 'locales/client/en.lua ' .. key end
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
        local words = englishPages()
        local asked = 0
        for _, page in ipairs({ 'ui/app.js', 'ui/admin.js' }) do
            local js = src(page)
            for key, line in pairs(PageScan.keysUsed(js)) do
                asked = asked + 1
                truthy(pageKey(words, key), page .. ':' .. line .. ' asks for ' .. key)
            end
            for section in js:gmatch("Text%.section%('([%w_]+)'%)") do
                truthy(type(words[section]) == 'table', page .. ' reads section ' .. section)
            end
        end
        truthy(asked >= 1500, asked .. ' keys asked for')
        falsy(src('ui/app.js'):find('var ERRORS = {', 1, true), 'the phone\'s refusals are in en.json')
        falsy(src('ui/admin.js'):find('var WORDS = {', 1, true), 'the panel\'s refusals are in en.json')
        truthy(pageKey(words, 'errors.rate_limited') and pageKey(words, 'panel_errors.not_allowed'))
    end)

    it('no page holds a sentence of its own', function()
        local classes = PageScan.classes({ src('ui/app.css'), src('ui/kit.css'), src('ui/admin.css') })
        local left = {}
        for _, page in ipairs(MOVED_PAGES) do
            for _, lit in ipairs(PageScan.hardCoded(src(page), classes, PAGE_ALLOW[page])) do
                left[#left + 1] = ('%s:%d %q'):format(page, lit.line, lit.text)
            end
        end
        eq(table.concat(left, ', '), '', 'words still written into a page')
    end)

    -- L1: one English word joined on with + (' of ', ' minute', 'Stake: ')
    -- or a plural made in place ("? '' : 's'") is a sentence a translator
    -- cannot reorder or put in the plural: such text is one key, with %s
    -- for the values (t(key, ...)) and _one/_other forms (tn(key, n)).
    it('no page joins English to its values with +, or makes a plural in place (L1)', function()
        local classes = PageScan.classes({ src('ui/app.css'), src('ui/kit.css'), src('ui/admin.css') })
        local left = {}
        for _, page in ipairs(MOVED_PAGES) do
            for _, lit in ipairs(PageScan.joined(src(page), classes, JOINED_ALLOW[page])) do
                left[#left + 1] = ('%s:%d %q'):format(page, lit.line, lit.text)
            end
        end
        eq(#left, 0, 'English joined in a page: ' .. table.concat(left, ', '))
    end)

    it('the joined scan finds a word joined on and a plural made in place, and not a key or a class', function()
        local found = PageScan.joined("el('div', 'hint', n + ' minute' + (n === 1 ? '' : 's'));\n"
            .. "var k = 'org:' + id + ':go'; el('div', 'notice ' + kind, t('app.x', n));\n", { notice = true })
        eq(#found, 2, 'the word and the plural')
        eq(found[1].text, ' minute')
    end)

    -- 8g: words that are class names too (.more, .with) passed as classes
    -- wherever they stood, and "? '' : 'es'" and two keys picked by a
    -- count were not seen as plurals.
    it('the joined scan counts a class name used as words, and plurals of every shape', function()
        local classes = { more = true, with = true, btn = true, ico = true, chip = true, state = true }
        local found = PageScan.joined("say(n + ' more');\nel('div', 'with', 'with ' + who);\n"
            .. "h('span', n + ' switch' + (n === 1 ? '' : 'es'));\n"
            .. "var w = n + (n === 1 ? t('app.day_ago') : t('app.days_ago'));\n", classes)
        local texts = {}
        for _, lit in ipairs(found) do texts[#texts + 1] = lit.text end
        eq(table.concat(texts, '|'), " more|with | switch|'' : 's'|'' : 's'",
            'the words joined on, and both plurals')
        local none = PageScan.joined("take.className = 'btn ' + kind;\n"
            .. "el('span', 'chip' + (icon ? ' ico ' + icon : ''), text);\n"
            .. "h('span.chip', { class: 'state ' + cls }, label);\nnode.classList.add('btn ' + x);\n", classes)
        eq(#none, 0, 'classes where the page puts classes are not words')
    end)

    it('the page scan finds a sentence written back, and not a key, a class or a console line', function()
        local found = PageScan.hardCoded("el('div', 'notice gold', 'Nothing is out on you.');\n"
            .. "console.warn('a console line'); t('app.cancel'); if (x === 'Some words') {}\n"
            .. "var o = { 'Not this': 1 }; say(t('app.done'), 'ok');\n", { notice = true, gold = true })
        eq(#found, 1, 'the sentence only')
        eq(found[1].text, 'Nothing is out on you.')
    end)

    it('the pages\' own HTML reads its words by key too', function()
        local words = englishPages()
        for _, html in ipairs({ 'ui/index.html', 'ui/admin.html' }) do
            local text = src(html)
            local n = 0
            for key in text:gmatch('data%-t[%w%-]*="([%w_]+%.[%w_]+)"') do
                n = n + 1
                truthy(pageKey(words, key), html .. ' asks for ' .. key)
            end
            truthy(n >= 5, html .. ': ' .. n .. ' keys')
        end
    end)

    it('both pages and the game load them, and an escrowed build leaves them readable', function()
        local manifest = src('fxmanifest.lua')
        truthy(manifest:find("'locales/client/%*%.lua',%s*'shared/locale%.lua'"), 'the game loads its words, then the lookup')
        local clientScripts = manifest:match('client_scripts%s*(%b{})')
        falsy(clientScripts:find("'locales/%*%.lua'"), 'the server\'s words are not sent to every game (R1)')
        truthy(manifest:find("'locales/%*%.json'"), 'the pages may read the json')
        local ignore = manifest:match('escrow_ignore%s*(%b{})')
        truthy(ignore and ignore:find("'locales/%*%.lua'", 1, false), 'never escrowed')
        truthy(ignore:find("'locales/client/%*%.lua'", 1, false), 'nor the game\'s')
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

    it('no setting key changes under a language with every word replaced (L2)', function()
        -- newStack puts the shipped config back (English), so the language is
        -- set after it and the catalogue is built again under it.
        local function catalogue(lang)
            newStack()
            Locale.reset()
            Config.Locale = lang
            package.loaded['crimson-hitman.server.settings'] = nil
            return require('crimson-hitman.server.settings')
        end
        local function keys(lang)
            local out = {}
            for _, e in ipairs(catalogue(lang).CATALOGUE) do out[#out + 1] = e.key end
            return out
        end
        local real = Config.Locale
        local zz = {}
        for k in pairs(englishTable()) do zz[k] = 'ZZ ' .. k end
        CrimsonLocales.zz = zz
        local ok, err = pcall(function()
            local english = keys('en')
            local translated = keys('zz')
            eq(table.concat(translated, ','), table.concat(english, ','), 'catalogue keys are ids, not words')
            local S = catalogue('zz')
            for _, key in ipairs({ 'Debug', 'Integrations.Target', 'Admin.Commands.panel', 'Cooldowns.load.per' }) do
                truthy(S.entry(key), key .. ' found under the translation')
            end
        end)
        Config.Locale = real
        CrimsonLocales.zz = nil
        Locale.reset()
        package.loaded['crimson-hitman.server.settings'] = nil
        if not ok then error(err, 0) end
        falsy(src('ui/admin.js'):find("t('admin.cooldowns')", 1, true), 'the panel builds cooldown keys from the id')
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
