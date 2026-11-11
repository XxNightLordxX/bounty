--- Crimson Hitman System — the words players and staff read, by key.
---
--- Every notice, refusal and label is looked up here by its key, in the
--- language Config.Locale names ('en' as shipped): locales/<language>.lua
--- on the server, locales/client/<language>.lua in the game,
--- locales/<language>.json in the phone app
--- and the admin panel (ui/app.js, ui/admin.js). A key the chosen language
--- does not have reads in English, and the console says so once (the first
--- key missing from a language whatever Debug says; each one with
--- Config.Debug on). A key English does not have either reads as the key
--- itself, said once in the console: tests/locale_spec.lua keeps that from
--- shipping.
---
--- The texts keep their %s and %d: a caller formats them as it always did,
--- L('notify.contract_accepted_by'):format(target, who).

local Locale = {}

--- The language every key falls back to.
Locale.FALLBACK = 'en'

--- [language] = its table, or false when there is no such file.
local tables = {}
--- [language .. '\0' .. key] = true once said in the console.
local said = {}
--- [language] = true once the first missing key was said whatever Debug says.
local first = {}

--- The server's module loader (server/boot.lua); the client has none, and
--- reads the language files the manifest loaded (CrimsonLocales).
local function boot() return rawget(_G, 'CrimsonBoot') end

local function console(text, always)
    -- shared/log.lua's CrimsonLog, which both sides load before anything
    -- asks for a word.
    local Console = CrimsonLog
    if not Console then return end
    if always then Console.always(text) else Console.debug(text) end
end

--- A language's table: published by its file or loaded by name on the
--- server. false when none. The game's own words (client.*) are a file of
--- their own, locales/client/<language>.lua (CrimsonClientLocales), the
--- only language file the manifest sends every player: the rest of
--- locales/<language>.lua (staff, Discord, the panel) stays on the server.
---@param lang string
---@param game boolean|nil the game's words (a client.* key)
---@return table|false
local function tableOf(lang, game)
    local slot = game and ('client/' .. tostring(lang)) or lang
    if tables[slot] ~= nil then return tables[slot] end
    local published = game and rawget(_G, 'CrimsonClientLocales') or rawget(_G, 'CrimsonLocales')
    local found = type(published) == 'table' and published[lang] or nil
    if type(found) ~= 'table' and type(lang) == 'string' and lang:match('^[%a_%-]+$')
        and boot() and boot().require then
        local ok, mod = pcall(boot().require, (game and 'locales.client.' or 'locales.') .. lang)
        found = ok and mod or nil
    end
    tables[slot] = type(found) == 'table' and found or false
    return tables[slot]
end

--- The language in force: Config.Locale, or English.
---@return string
function Locale.language()
    local lang = type(Config) == 'table' and Config.Locale or nil
    return (type(lang) == 'string' and lang ~= '') and lang or Locale.FALLBACK
end

--- The text for `key` in the language in force; in English when that
--- language lacks it; the key itself when English does too.
---@param key string
---@return string
function Locale.t(key)
    local lang = Locale.language()
    local game = type(key) == 'string' and key:sub(1, 7) == 'client.'
    local chosen = tableOf(lang, game)
    local text = chosen and chosen[key]
    if type(text) == 'string' then return text end
    if lang ~= Locale.FALLBACK then
        if not said[lang .. '\0' .. key] then
            said[lang .. '\0' .. key] = true
            if not chosen and not first[lang] then
                first[lang] = true
                console(('locale: there is no locales/%s.lua (Config.Locale); English is used.')
                    :format(lang), true)
            elseif chosen then
                console(('locale: %s has no text for %s; English is used.'):format(lang, key), not first[lang])
                first[lang] = true
            end
        end
        local english = tableOf(Locale.FALLBACK, game)
        text = english and english[key]
        if type(text) == 'string' then return text end
    end
    if not said['\0' .. key] then
        said['\0' .. key] = true
        console(('locale: no text for %s in any language; the key is shown.'):format(tostring(key)), true)
    end
    return tostring(key)
end

--- Forget the loaded languages and what was said (tests).
function Locale.reset()
    tables, said, first = {}, {}, {}
end

CrimsonLocale = Locale

return Locale
