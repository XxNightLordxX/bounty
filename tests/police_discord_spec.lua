--- Step 3h: one Police & press module (server/police.lua) for everything
--- told to the police or the city, and one Discord sender
--- (server/discord.lua) for every post to Discord. Held here: the one call
--- site of each outside resource (sc-dispatch, lb-phone's Birdy,
--- PerformHttpRequest), that every bulletin and every post goes through
--- them with its words and recipients as before, and what the sender does
--- to every post whoever sent it (@ defused, links left out, cut, a 429
--- holding the webhook for every sender, the tries).

local Log = require('crimson-hitman.shared.log')

local HOOK_ALERT = 'https://discord.example/api/webhooks/1/alert'
local HOOK_STAFF = 'https://discord.example/api/webhooks/2/staff'
local HOOK_STATS = 'https://discord.example/api/webhooks/3/stats'

local function leoJob(name) return { name = name, type = 'leo', onduty = true } end

local function officers()
    Env.addPlayer({ source = 20, citizenid = 'OFFICER1', license = 'license:o1',
        job = leoJob('police'), firstname = 'Ada', lastname = 'Kane' })
    Env.addPlayer({ source = 21, citizenid = 'OFFICER2', license = 'license:o2',
        job = leoJob('bcso'), firstname = 'Sam', lastname = 'Bell' })
end

local function clearHooks()
    for _, name in ipairs({ 'crimson_hitman_alert_webhook', 'crimson_hitman_webhook',
                            'crimson_hitman_stats_webhook' }) do
        Natives.convars[name] = nil
    end
end

--- Every server file but the ones named, as text.
local function serverFilesExcept(skip)
    local out = {}
    local pipe = io.popen("find crimson-hitman/server -name '*.lua' -type f | sort")
    for path in pipe:lines() do
        if not skip[path] then out[path] = read_file(path) end
    end
    pipe:close()
    return out
end

local function code(text)
    -- Comments out: a file may say what it no longer does.
    return (text:gsub('%-%-%[%[.-%]%]', ''):gsub('%-%-[^\n]*', ''))
end

--------------------------------------------------------------------------
-- One call site each
--------------------------------------------------------------------------

describe('step 3h: one call site for every outside channel', function()
    it('only server/police.lua files with sc-dispatch or posts to Birdy', function()
        for path, text in pairs(serverFilesExcept({ ['crimson-hitman/server/police.lua'] = true })) do
            local body = code(text)
            for _, word in ipairs({ "'AddNotification'", "'ClearNotification'", "'PostBirdy'" }) do
                falsy(body:find(word, 1, true), path .. ' calls ' .. word .. ' itself')
            end
        end
        local police = read_file('crimson-hitman/server/police.lua')
        for _, word in ipairs({ "'AddNotification'", "'ClearNotification'", "'PostBirdy'" }) do
            truthy(police:find(word, 1, true), word .. ' is in server/police.lua')
        end
    end)

    it('only server/discord.lua posts to a webhook, and nothing reads a webhook convar itself', function()
        local skip = { ['crimson-hitman/server/discord.lua'] = true }
        for path, text in pairs(serverFilesExcept(skip)) do
            local body = code(text)
            -- photos.lua asks whether its own public address leads here;
            -- versioncheck.lua makes its one GET (X4, off as shipped), to no webhook.
            if path ~= 'crimson-hitman/server/photos.lua' and path ~= 'crimson-hitman/server/versioncheck.lua' then
                falsy(body:find('PerformHttpRequest', 1, true), path .. ' makes a request of its own')
            end
            for _, convar in ipairs({ "GetConvar('crimson_hitman_webhook'",
                                      "GetConvar('crimson_hitman_alert_webhook'",
                                      'GetConvar(Weekly.CONVAR' }) do
                falsy(body:find(convar, 1, true), path .. ' reads a webhook convar itself')
            end
        end
        -- photos.lua's one request is the photo host probe, never Discord.
        local photos = code(read_file('crimson-hitman/server/photos.lua'))
        falsy(photos:find('webhook', 1, true))
    end)

    it('no module keeps a police job list or an officer loop of its own', function()
        for path, text in pairs(serverFilesExcept({ ['crimson-hitman/server/police.lua'] = true })) do
            local body = code(text)
            falsy(body:find('RecipientJobNames', 1, true) and not path:find('identity.lua', 1, true)
                and not path:find('settings.lua', 1, true) and not path:find('main.lua', 1, true),
                path .. ' reads the recipient job names itself')
            falsy(body:find('job_table', 1, true), path .. ' builds a dispatch job table')
        end
    end)
end)

--------------------------------------------------------------------------
-- Police & press
--------------------------------------------------------------------------

describe('Police & press', function()
    it('tells every officer online but the ones left out, past the budget', function()
        local s = newStack()
        fixture(s)
        officers()
        Natives.calls.notifications = {}
        eq(s.police.tell('Bulletin', 'Words.'), 2)
        eq(s.police.tell('Bulletin', 'Words.', function(actor) return actor.cid == 'OFFICER1' end), 1)
        local n = 0
        for _, note in ipairs(Natives.calls.notifications) do
            if note.title == 'Bulletin' then n = n + 1 end
        end
        eq(n, 3)
    end)

    it('files every dispatch entry for the advisory departments, its ids held to sc-dispatch\'s lengths', function()
        local s = newStack()
        Config.Advisory.RecipientJobNames = { sast = true, fib = true }
        Natives.calls.dispatch = {}
        truthy(s.police.dispatch({ title = 'T', message = 'M', caller = ('c'):rep(80),
            street = ('s'):rep(150), unique_id = ('u'):rep(90) }))
        local entry = Natives.calls.dispatch[1]
        eq(table.concat(entry.job_table, ','), 'fib,sast')
        eq(#entry.unique_id, 60)
        eq(#entry.caller, 60)
        eq(#entry.street, 100)
        resetConfig()
    end)

    it('files nothing, and never raises, without sc-dispatch', function()
        local s = newStack()
        Natives.resourceStates['sc-dispatch'] = 'stopped'
        Natives.calls.dispatch = {}
        local ok, filed = pcall(s.police.dispatch, { title = 'T', message = 'M', unique_id = 'x' })
        truthy(ok)
        falsy(filed)
        eq(#Natives.calls.dispatch, 0)
        Natives.resourceStates['sc-dispatch'] = 'started'
    end)

    it('every advisory goes through it: posted, accepted, tip, cancelled, and the clear', function()
        local s = newStack()
        local f = fixture(s, { targetJob = leoJob('trooper') })
        officers()
        local seen = {}
        local dispatch, tell, clear = s.police.dispatch, s.police.tell, s.police.clear
        s.police.dispatch = function(entry) seen[#seen + 1] = 'dispatch:' .. entry.title; return dispatch(entry) end
        s.police.tell = function(title, ...) seen[#seen + 1] = 'tell:' .. title; return tell(title, ...) end
        s.police.clear = function(uid) seen[#seen + 1] = 'clear:' .. uid; return clear(uid) end
        local c = assert(s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 1000 } } }))
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        s.notify.tipAdvisory(s.storage.readContract(c.id))
        s.notify.cancelAdvisory(s.storage.readContract(c.id))
        local before = #Env.threads
        s.notify.clearContract(c.id, s.storage.readContract(c.id))
        for i = before + 1, #Env.threads do Env.threads[i]() end
        local got = table.concat(seen, '|')
        for _, want in ipairs({ 'tell:THREAT ADVISORY', 'dispatch:THREAT ADVISORY',
                                'tell:THREAT ADVISORY — ACTIVE', 'dispatch:THREAT ADVISORY — ACTIVE',
                                'tell:THREAT ADVISORY — TIP', 'dispatch:THREAT ADVISORY — TIP',
                                'tell:THREAT ADVISORY — CANCELLED', 'dispatch:THREAT ADVISORY — CANCELLED',
                                'clear:ch-' .. c.id .. '-posted', 'clear:ch-' .. c.id .. '-tip' }) do
            truthy(got:find(want, 1, true), want .. ' in ' .. got)
        end
    end)

    it('the city news post goes through Police.press, and a failure is said once a minute', function()
        local s = newStack()
        Natives.resourceStates['lb-phone'] = 'stopped'
        local said = 0
        local always = Log.always
        Log.always = function(text, ...)
            if tostring(text):find('city news', 1, true) then said = said + 1 end
            return always(text, ...)
        end
        local cfg = { App = 'birdy', Account = 'news' }
        falsy(s.police.press(cfg, 'Shots were heard.'))
        falsy(s.police.press(cfg, 'Shots were heard again.'))
        eq(said, 1, 'once a minute')
        Env.advance(61)
        falsy(s.police.press(cfg, 'And again.'))
        eq(said, 2)
        Log.always = always
        Natives.resourceStates['lb-phone'] = 'started'
        local fired
        AddEventHandler('ch-test:news', function(data) fired = data end)
        truthy(s.police.press({ App = 'event', Event = 'ch-test:news', Account = 'wire' }, 'Text.'))
        truthy(fired and fired.account == 'wire' and fired.text == 'Text.', 'the owner\'s event')
    end)
end)

--------------------------------------------------------------------------
-- The one Discord sender
--------------------------------------------------------------------------

describe('the one Discord sender', function()
    it('reads each channel\'s convars in order, never shown', function()
        local s = newStack()
        clearHooks()
        eq(s.discord.url('alerts'), nil)
        Natives.convars.crimson_hitman_webhook = HOOK_STAFF
        eq(select(2, s.discord.url('alerts')), 'staff')
        eq(select(2, s.discord.url('stats')), 'staff')
        Natives.convars.crimson_hitman_alert_webhook = HOOK_ALERT
        eq(s.discord.url('alerts'), HOOK_ALERT)
        eq(s.discord.url('staff'), HOOK_STAFF)
        eq(select(2, s.discord.url('stats')), 'alert')
        Natives.convars.crimson_hitman_stats_webhook = HOOK_STATS
        eq(s.discord.url('stats'), HOOK_STATS)
        clearHooks()
    end)

    it('defuses every @ once, leaves links out and cuts to the limit', function()
        local s = newStack()
        local text = s.discord.text('@everyone see https://evil.example/x now')
        falsy(text:find('@everyone', 1, true))
        falsy(text:find('evil.example', 1, true))
        truthy(text:find('(a link)', 1, true))
        eq(s.discord.text(text), text, 'said twice, defused once')
        eq(#s.discord.text(('x'):rep(3000), 1900), 1900)
    end)

    it('every sender\'s post goes through it, on its own channel', function()
        local s = newStack()
        clearHooks()
        Natives.convars.crimson_hitman_alert_webhook = HOOK_ALERT
        Natives.convars.crimson_hitman_webhook = HOOK_STAFF
        Natives.convars.crimson_hitman_stats_webhook = HOOK_STATS
        local channels = {}
        local post = s.discord.post
        s.discord.post = function(channel, ...)
            channels[#channels + 1] = channel
            return post(channel, ...)
        end
        -- An alert.
        Log.always('an alert for the sender')
        Env.advance(1)
        -- The audit mirror.
        s.audit.rejected('some_refusal', 'CREATOR1', nil, {})
        s.audit.flush()
        -- The daily summary.
        Config.Staff.DailySummary = true
        Config.Staff.DailySummaryHour = 0
        truthy(s.summary.tick(), 'the summary posted')
        -- The weekly stats.
        local t = os.date('*t', os.time())
        Config.Improvements.WeeklyStats.Day = s.impWeekly.DAYS[t.wday]
        Config.Improvements.WeeklyStats.Hour = t.hour
        Config.Improvements.WeeklyStats.Enabled = true
        truthy(s.impWeekly.tick(), 'the weekly stats posted')
        s.discord.post = post
        local got = table.concat(channels, ',')
        eq(got, 'alerts,staff,alerts,stats')
        local urls = {}
        for _, call in ipairs(Natives.calls.http) do urls[#urls + 1] = call.url end
        eq(table.concat(urls, ','), table.concat({ HOOK_ALERT, HOOK_STAFF, HOOK_ALERT, HOOK_STATS }, ','))
        for _, call in ipairs(Natives.calls.http) do
            local body = json.decode(call.body).content
            falsy(body:find('@[^\226]'), 'no live mention: ' .. body)
        end
        clearHooks()
    end)

    it('a 429 holds the webhook for every sender: the audit mirror is not sent into it', function()
        local s = newStack()
        clearHooks()
        Natives.convars.crimson_hitman_webhook = HOOK_STAFF
        local answers = { 429 }
        Natives.httpAnswer = function() return table.remove(answers, 1) or 204, '', { ['Retry-After'] = '30' } end
        Natives.calls.http = {}
        truthy(s.discord.post('alerts', 'first'), 'queued')
        eq(#Natives.calls.http, 1)
        s.audit.rejected('held_refusal', 'CREATOR1', nil, {})
        s.audit.flush()
        eq(#Natives.calls.http, 1, 'the mirror waits out the hold')
        local queued, why = s.discord.post('staff', 'one try', { tries = 1 })
        falsy(queued)
        eq(why, 'held')
        Env.advance(31)
        eq(#Natives.calls.http, 2, 'the first post tried again once the hold is over')
        truthy(s.discord.post('staff', 'after', { tries = 1 }))
        eq(#Natives.calls.http, 3)
        clearHooks()
    end)

    it('a request that raises: refused at once with no tries to spare, tried again with some', function()
        local s = newStack()
        clearHooks()
        Natives.convars.crimson_hitman_webhook = HOOK_STAFF
        local http = PerformHttpRequest
        local calls = 0
        _G.PerformHttpRequest = function() calls = calls + 1; error('http down') end
        local queued, why = s.discord.post('staff', 'x', { tries = 1 })
        falsy(queued)
        eq(why, 'unavailable')
        local result
        truthy(s.discord.post('staff', 'y', { tries = 2, every = 1000,
            done = function(ok, code, tries) result = { ok = ok, code = code, tries = tries } end }))
        Env.advance(2)
        eq(result and result.tries, 2)
        eq(result.code, 0)
        falsy(result.ok)
        _G.PerformHttpRequest = http
        clearHooks()
    end)

    it('drops a post switched off between tries, and posts nothing without a webhook', function()
        local s = newStack()
        clearHooks()
        eq(select(2, s.discord.post('alerts', 'x')), 'no_webhook')
        Natives.convars.crimson_hitman_alert_webhook = HOOK_ALERT
        Natives.httpAnswer = function() return 500, '', {} end
        Natives.calls.http = {}
        local on, result = true, nil
        truthy(s.discord.post('alerts', 'x', { still = function() return on end,
            done = function(ok, code) result = { ok = ok, code = code } end }))
        on = false
        Env.advance(60)
        eq(#Natives.calls.http, 1, 'not tried again')
        falsy(result.ok)
        eq(result.code, nil, 'dropped, not given up')
        clearHooks()
    end)
end)
