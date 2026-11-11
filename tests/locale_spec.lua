--- Translations (X1): every word players and staff read lives in the
--- language files (locales/en.lua for the server and the game,
--- locales/en.json for the phone app and the admin panel), looked up by key
--- in the language Config.Locale names, English where that language lacks
--- one.
---
--- Moved so far (README, Translations, lists the rest): the notices players
--- get (server/notify.lua), staff alerts and their Discord posts
--- (server/alerts.lua, server/discord.lua), staff notices
--- (server/announce.lua), the police advisories (notify.lua's dispatch
--- entries), every answer of the admin panel's requests (server/panel.lua),
--- everything the game itself shows (client/), the phone app's
--- refusals (ERRORS) and the panel's (WORDS). The scan below is what keeps a
--- sentence from being written into one of those files again.

local TextScan = require('tests.harness.textscan')
local Locale = require('crimson-hitman.shared.locale')
local Log = require('crimson-hitman.shared.log')

--- The files whose words are all in the language files: none may hold a
--- sentence of its own.
local SCANNED = {
    'server/notify.lua', 'server/alerts.lua', 'server/discord.lua', 'server/announce.lua',
    'server/police.lua',
    'server/panel.lua',
    'client/main.lua', 'client/missionsteps.lua', 'client/admin.lua', 'client/org.lua',
    'client/rp_npc.lua', 'client/npc.lua', 'client/mugshot.lua',
}

--- What the scan reads as words in those files and is not, by file: each
--- with why.
local ALLOW = {
    -- The reason a city news post was not made, said only in the console
    -- line two lines below it.
    ['server/police.lua'] = { ['no phone adapter answers (Config.Integrations.Phone)'] = true },
    -- Patterns matched against the diagnosis's own lines (server/admin.lua,
    -- not moved yet), which must read as admin.lua writes them; the preset
    -- name kept in an audit row, which is data; and a console line.
    ['server/panel.lua'] = { ['^Not authorised: '] = true, ['name somebody who is in the city'] = true,
        ['run from the console'] = true, ['the server-wide checks below'] = true,
        ['name a player to test'] = true, ['Current'] = true,
        ["the admin panel\\'s %s raised: %s"] = true },
    -- lb-phone's camera mode name (SetCameraComponent), not a word shown.
    ['client/main.lua'] = { ['Photo'] = true },
}

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
            for _, lit in ipairs(TextScan.hardCoded(src(path), ALLOW[path])) do
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
