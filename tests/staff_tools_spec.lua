--- The staff tools: the daily summary to Discord, the alert thresholds,
--- the notice to every hitman, the app pause, the settings history with
--- Undo, and players' reports.
---
--- Booted through main.lua, so the maintenance tick, the expiry pass, the
--- panel and the app's net events are the real ones. What these hold:
---
---   * the summary posts once a day at its hour, counts only, through the
---     alert webhook, and not again after a restart the same day;
---   * each threshold raises one staff alert past it, naming the player by
---     citizen id only to staff with IdentityAce, and to Discord scrubbed;
---   * a notice goes from 'Staff' to the hitmen holding a contract (or to
---     everybody online with the app), held to the length and the text
---     rules, written down, and refused to anybody without the write ACE;
---   * the app pause refuses placing and accepting with nothing charged,
---     holds every clock, gives the lifetime back to the second, never ends
---     a freeze or the restart hold nor is ended by one, and outlives a
---     restart on json and mysql;
---   * the history lists every change with who, when and both values, never
---     a secret, a Developer key only to the Developer section's staff, and
---     Undo puts the old value back through the normal set path, on the
---     record, for staff with the write ACE only;
---   * a report reaches the review queue with the contract, the role, the
---     note and the thread's last twenty messages, is rate-limited, tells the
---     reported party nothing, and names nobody anonymous to staff without
---     IdentityAce.

local Exec = require('tests.harness.mysql_exec')
local Util = require('crimson-hitman.shared.util')

local function forgetServerModules()
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
            package.loaded[name] = nil
        end
    end
end

local function boot(mode, configure)
    forgetServerModules()
    Env.reset()
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Natives.resetResourceStates()
    Natives.resetConvars()
    resetConfig()
    Config.Database.Mode = mode or 'memory'
    if mode == 'mysql' then Exec.install(Natives) end
    if mode == 'json' then Natives.files = {} end
    Config.Cooldowns.admin = { per = 10, burst = 500 }
    Config.Cooldowns.adminWrite = { per = 10, burst = 500 }
    Config.Limits.ExclusiveIdleReleaseSeconds = 0
    Config.Limits.ExclusiveAttemptWindowSeconds = 0
    Config.Limits.MaxActiveContractsPerTarget = 10
    Config.Limits.MaxActiveContractsPerCreator = 10
    if configure then configure() end
    local main = require('server.main')
    return main, main.start()
end

local function restart(mode, old)
    if old and old.storage then rawset(old.storage, '__rawFixture', true) end
    forgetServerModules()
    Env.events, Env.clientEvents, Env.notifications = {}, {}, {}
    Env.handlers, Env.threads, Env.timers, Env.commands = {}, {}, {}, {}
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Config.Database.Mode = mode
    local main = require('server.main')
    return main, main.start()
end

--- The usual three, a second hitman, a stranger, and three staff:
--- crimson.admin, a read-only extra ACE, and crimson.admin with
--- crimson.identity.
local function people(s)
    local f = fixture(s)
    Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
        cash = 5000, bank = 50000, firstname = 'Kit', lastname = 'Vane' })
    Env.addPlayer({ source = 5, citizenid = 'PUBLIC01', license = 'license:pub',
        cash = 5000, bank = 5000, firstname = 'Pat', lastname = 'Lee' })
    Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
        firstname = 'Sam', lastname = 'Steward' })
    Env.addPlayer({ source = 7, citizenid = 'READER01', license = 'license:READER01',
        firstname = 'Rae', lastname = 'Dent' })
    Env.addPlayer({ source = 8, citizenid = 'UNMASK01', license = 'license:UNMASK01',
        firstname = 'Uma', lastname = 'Mask' })
    Env.aces[6] = { ['crimson.admin'] = true }
    Env.aces[7] = { command = true }
    Env.aces[8] = { ['crimson.admin'] = true, ['crimson.identity'] = true }
    f.hitman2 = s.identity.resolve(4)
    f.public = s.identity.resolve(5)
    return f
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

local function call(name, src, payload)
    local fire = Env.events['crimson-hitman:' .. name]
    truthy(fire, 'no handler registered for ' .. name)
    local from = #Env.clientEvents
    _G.source = src
    fire(payload or {})
    _G.source = nil
    for i = from + 1, #Env.clientEvents do
        local event = Env.clientEvents[i]
        if event.name == 'crimson-hitman:result' and event.target == src then return event.args[1] end
    end
    return nil
end

local function place(s, actor, extra)
    local req = { targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                  reward = { baseline = { cash = 5000 } } }
    for k, v in pairs(extra or {}) do req[k] = v end
    local c, err = s.contracts.create(actor, req)
    truthy(c, 'placed: ' .. tostring(err))
    return c
end

local function pass(main)
    main.markPresenceChanged()
    main.expire()
end

local function row(s, c) return s.storage.readContract(c.id) end

local function notices(src)
    local out = {}
    for _, event in ipairs(Env.clientEvents) do
        if Natives.isNotice(event) and event.target == src then
            out[#out + 1] = { title = tostring(event.args[1].title), text = tostring(event.args[1].content) }
        end
    end
    return out
end

local function count(list, needle)
    local n = 0
    for _, entry in ipairs(list) do if entry.text:find(needle, 1, true) then n = n + 1 end end
    return n
end

local function stored(s, action)
    s.audit.flush()
    return s.storage.auditByAction(action, 100) or {}
end

local function wealth(src)
    local m = Env.players[src].PlayerData.money
    return m.cash + m.bank
end

--- Every string in a value, keys included, joined.
local function text(value)
    local out = {}
    local function walk(v)
        if type(v) == 'string' then out[#out + 1] = v
        elseif type(v) == 'table' then for k, inner in pairs(v) do walk(k) walk(inner) end end
    end
    walk(value)
    return table.concat(out, '\n')
end

local function posts()
    local out = {}
    for _, post in ipairs(Natives.calls.http or {}) do out[#out + 1] = tostring(post.body) end
    return out
end

local WEBHOOK = 'https://discord.example/api/webhooks/1/x'

--------------------------------------------------------------------------
-- 1. The daily summary
--------------------------------------------------------------------------

describe('the daily summary to the staff Discord', function()
    local function hourNow() return os.date('*t', os.time()).hour end

    it('posts nothing while switched off, as shipped', function()
        local main, s = boot()
        people(s)
        Natives.convars['crimson_hitman_alert_webhook'] = WEBHOOK
        eq(Config.Staff.DailySummary, false, 'ships off')
        Config.Staff.DailySummaryHour = 0
        Natives.calls.http = {}
        main.tick()
        for _, body in ipairs(posts()) do falsy(body:find('daily summary', 1, true), 'posted while off') end
    end)

    it('posts once at the hour, counts only, and never again that day, a restart included', function()
        local main, s = boot('json')
        local f = people(s)
        Natives.convars['crimson_hitman_alert_webhook'] = WEBHOOK
        local done = place(s, f.creator, { anonymous = true })
        truthy(s.contracts.accept(f.hitman, done.id, true), 'taken')
        local refunded = place(s, f.creator, { targetCid = 'HITMAN02' })
        truthy(s.contracts.cancel(f.creator, refunded.id), 'cancelled')
        truthy(s.holds.freeze('ADMIN001', 'PUBLIC01', 'x'), 'frozen')

        Config.Staff.DailySummary = true
        local hour = hourNow()
        if hour < 23 then
            Config.Staff.DailySummaryHour = hour + 1
            Natives.calls.http = {}
            main.tick()
            for _, body in ipairs(posts()) do falsy(body:find('daily summary', 1, true), 'posted before the hour') end
        end
        Config.Staff.DailySummaryHour = hour
        Natives.calls.http = {}
        main.tick()
        local summaries = {}
        for _, body in ipairs(posts()) do
            if body:find('daily summary', 1, true) then summaries[#summaries + 1] = body end
        end
        eq(#summaries, 1, 'one post at the hour')
        local body = summaries[1]
        truthy(body:find('Contracts placed: 2', 1, true), body)
        truthy(body:find('Contracts refunded (cancelled, expired or voided): 1', 1, true), body)
        truthy(body:find('Frozen players: 1', 1, true), body)
        truthy(body:find('Open review items: 0', 1, true), body)
        truthy(body:find('Money in escrow: $5,000', 1, true), body)
        truthy(body:find('Suspended players: 0', 1, true), body)
        for _, needle in ipairs({ 'CREATOR1', 'HITMAN01', 'TARGET01', 'PUBLIC01', 'Vic', 'Marlowe',
            'Dana', 'Reyes', 'Rook', 'Pat Lee', done.id, refunded.id, 'license:' }) do
            falsy(body:find(needle, 1, true), 'the summary names ' .. needle)
        end
        eq(#stored(s, 'daily_summary_posted'), 1, 'on the record')

        Natives.calls.http = {}
        main.tick()
        Env.advance(600)
        main.tick()
        for _, b in ipairs(posts()) do falsy(b:find('daily summary', 1, true), 'posted twice in a day') end

        local main2, after = restart('json', s)
        Config.Staff.DailySummary = true
        Natives.calls.http = {}
        main2.tick()
        for _, b in ipairs(posts()) do falsy(b:find('daily summary', 1, true), 'posted again after a restart') end
        local _ = after

        Env.advance(86400)
        Config.Staff.DailySummaryHour = 0
        Natives.calls.http = {}
        main2.tick()
        local next = 0
        for _, b in ipairs(posts()) do if b:find('daily summary', 1, true) then next = next + 1 end end
        eq(next, 1, 'the next day posts again')
    end)

    it('counts the suspensions in force (server/sanctions.lua), not lifted or run-out ones', function()
        local main, s = boot()
        people(s)
        Natives.convars['crimson_hitman_alert_webhook'] = WEBHOOK
        eq(s.sanctions.count(), 0, 'nobody suspended')
        truthy(s.sanctions.place('suspend', 'ADMIN001', 'PUBLIC01', nil, 'spam'), 'until lifted')
        truthy(s.sanctions.place('suspend', 'ADMIN001', 'HITMAN02', 3600, 'spam'), 'for an hour')
        truthy(s.sanctions.place('suspend', 'ADMIN001', 'CREATOR1', 86400, 'spam'), 'for a day')
        truthy(s.sanctions.place('protect', 'ADMIN001', 'TARGET01', nil, 'event'), 'a protection')
        eq(s.sanctions.count(), 3, 'three suspended, the protection not counted')
        truthy(s.sanctions.lift('suspend', 'ADMIN001', 'CREATOR1', 'sorted'), 'lifted')
        Env.advance(3601)
        eq(s.sanctions.count(), 1, 'the lifted one and the one run out are not')
        eq(s.summary.counts(os.time()).suspended, 1)
        Config.Staff.DailySummary = true
        Config.Staff.DailySummaryHour = 0
        Natives.calls.http = {}
        main.tick()
        local body
        for _, b in ipairs(posts()) do if b:find('daily summary', 1, true) then body = b end end
        truthy(body, 'posted')
        truthy(body:find('Suspended players: 1', 1, true), body)
        falsy(body:find('not tracked', 1, true), body)
        for _, needle in ipairs({ 'PUBLIC01', 'HITMAN02', 'ADMIN001', 'spam' }) do
            falsy(body:find(needle, 1, true), 'the summary names ' .. needle)
        end
    end)

    it('without a webhook posts nothing and leaves the day open for one set later', function()
        local main, s = boot()
        people(s)
        Config.Staff.DailySummary = true
        Config.Staff.DailySummaryHour = 0
        Natives.calls.http = {}
        main.tick()
        eq(#posts(), 0, 'posted with no webhook')
        Natives.convars['crimson_hitman_webhook'] = WEBHOOK
        main.tick()
        local n = 0
        for _, b in ipairs(posts()) do if b:find('daily summary', 1, true) then n = n + 1 end end
        eq(n, 1, 'the staff webhook carries it once one is set')
        eq(Natives.calls.http[#Natives.calls.http].url, WEBHOOK)
        local _ = s
    end)
end)

--------------------------------------------------------------------------
-- 2. Alert thresholds
--------------------------------------------------------------------------

describe('the staff alert thresholds', function()
    local function handleFor(s, query, src)
        local found = s.app.handlers.searchTargets(s.identity.resolve(src or 1), { query = query })
        return found and found[1] and found[1].handle
    end

    local function placeByApp(s, query, src)
        return call('create', src or 1, { target = handleFor(s, query, src), reason = 'x', mode = 'competitive',
            reward = { slots = { { baseline = { cash = 500 } } } } })
    end

    local function staffAlerts(s)
        local rows = s.alerts.list('open', 100)
        local out = {}
        for _, a in ipairs(rows) do
            if a.text:find('staff alert', 1, true) then out[#out + 1] = a.text end
        end
        return out
    end

    local function setup()
        local main, s = boot(nil, function()
            Config.Cooldowns.create = { per = 1, burst = 50 }
            Config.Limits.SameCreatorSameTargetCooldownSeconds = 0
        end)
        local f = people(s)
        return main, s, f
    end

    it('one player placing past AlertPlacedPerHour: one alert, by citizen id', function()
        local _, s = setup()
        Config.Staff.AlertPlacedPerHour = 2
        Config.Staff.AlertTargetPerDay = 0
        for i = 1, 2 do truthy(placeByApp(s, i == 1 and 'Reyes' or 'Vane').ok, 'placed ' .. i) end
        eq(#staffAlerts(s), 0, 'an alert at the threshold itself')
        truthy(placeByApp(s, 'Lee').ok, 'placed 3')
        local alerts = staffAlerts(s)
        eq(#alerts, 1, 'one alert past it')
        truthy(alerts[1]:find('CREATOR1', 1, true), alerts[1])
        truthy(placeByApp(s, 'Ash').ok, 'placed 4')
        eq(#staffAlerts(s), 1, 'once a window, not once a contract')
    end)

    it('one target past AlertTargetPerDay, and one player refused past AlertRefusalsPer10Min', function()
        local _, s = setup()
        Config.Staff.AlertPlacedPerHour = 0
        Config.Staff.AlertTargetPerDay = 2
        Config.Staff.AlertRefusalsPer10Min = 3
        for i, src in ipairs({ 1, 5, 4 }) do
            local placed = placeByApp(s, 'Reyes', src)
            truthy(placed and placed.ok, 'placed ' .. i .. ': ' .. tostring(placed and placed.err))
        end
        local alerts = staffAlerts(s)
        eq(#alerts, 1, 'the target alert')
        truthy(alerts[1]:find('TARGET01', 1, true), alerts[1])
        for _ = 1, 3 do falsy(call('accept', 4, { id = 'ct0000000000' }).ok, 'refused') end
        eq(#staffAlerts(s), 1, 'an alert at the refusal threshold itself')
        falsy(call('accept', 4, { id = 'ct0000000000' }).ok, 'refused')
        alerts = staffAlerts(s)
        eq(#alerts, 2, 'the refusal alert')
        local said = table.concat(alerts, '\n')
        truthy(said:find('HITMAN02', 1, true), said)
        Env.advance(601)
        for _ = 1, 4 do call('accept', 4, { id = 'ct0000000000' }) end
        local hitman = 0
        for _, a in ipairs(s.alerts.list('open', 100)) do
            if a.text:find('HITMAN02', 1, true) then hitman = hitman + a.count end
        end
        eq(hitman, 2, 'once more in the next window')
    end)

    it('names the player only to IdentityAce staff; everybody else and Discord read (a player)', function()
        local _, s = setup()
        Natives.convars['crimson_hitman_alert_webhook'] = WEBHOOK
        Config.Staff.AlertPlacedPerHour = 1
        Config.Staff.AlertTargetPerDay = 0
        truthy(placeByApp(s, 'Reyes').ok)
        truthy(placeByApp(s, 'Vane').ok)
        local plain = ask(6, 'alerts', {})
        local identity = ask(8, 'alerts', {})
        local function staffRow(reply)
            for _, r in ipairs(reply.data.rows) do
                if r.text:find('staff alert', 1, true) then return r.text end
            end
            return ''
        end
        falsy(staffRow(plain):find('CREATOR1', 1, true), 'named to staff without IdentityAce: ' .. staffRow(plain))
        truthy(staffRow(plain):find('(a player)', 1, true), staffRow(plain))
        truthy(staffRow(identity):find('CREATOR1', 1, true), 'not named to IdentityAce staff')
        Env.advance(11)
        Env.runTimers()
        local sent = false
        for _, body in ipairs(posts()) do
            if body:find('staff alert', 1, true) then
                sent = true
                falsy(body:find('CREATOR1', 1, true), 'named on Discord: ' .. body)
            end
        end
        truthy(sent, 'the alert reached Discord')
    end)
end)

--------------------------------------------------------------------------
-- 3. A notice to every hitman
--------------------------------------------------------------------------

describe('a notice from staff to every hitman', function()
    it('reaches every hitman holding a contract, from Staff, never naming who sent it', function()
        local _, s = boot()
        local f = people(s)
        local c = place(s, f.creator)
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        local reply = ask(6, 'announce', { text = 'Event tonight: no contracts in Legion Square.' })
        truthy(reply and reply.ok, reply and reply.message)
        eq(reply.data.sent, 1, 'one hitman holds a contract')
        local got = notices(3)
        eq(#got, 1, 'the hitman got it')
        eq(got[1].title, 'Staff')
        eq(got[1].text, 'Event tonight: no contracts in Legion Square.')
        for _, src in ipairs({ 1, 2, 4, 5 }) do eq(#notices(src), 0, 'not a hitman holding one: ' .. src) end
        for _, event in ipairs(Env.clientEvents) do
            if event.target ~= 6 then
                local said = text(event.args)
                for _, needle in ipairs({ 'ADMIN001', 'Sam', 'Steward', 'license:ADMIN001' }) do
                    falsy(said:find(needle, 1, true), 'a player was told who sent it: ' .. needle)
                end
            end
        end
        local rows = stored(s, 'staff_announce')
        eq(#rows, 1, 'on the record')
        eq(rows[1].actor_cid, 'ADMIN001')
        eq(rows[1].detail.sent, 1)
        eq(rows[1].detail.scope, 'active')
        eq(rows[1].detail.text, 'Event tonight: no contracts in Legion Square.')
    end)

    it('to everybody online with the app, when chosen', function()
        local _, s = boot()
        people(s)
        local reply = ask(6, 'announce', { text = 'Server event at 8.', scope = 'online' })
        truthy(reply.ok, reply.message)
        for _, src in ipairs({ 1, 2, 3, 4, 5 }) do eq(#notices(src), 1, 'online: ' .. src) end
    end)

    it('holds the text to its length and rules, and refuses anybody without the write ACE', function()
        local _, s = boot()
        local f = people(s)
        local c = place(s, f.creator)
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        local long = ask(6, 'announce', { text = ('x'):rep(201) })
        falsy(long.ok, 'sent past the limit')
        eq(long.err, 'text_refused')
        truthy(long.message:find('200', 1, true), long.message)
        eq(ask(6, 'announce', { text = ('x'):rep(200) }).ok, true, 'the limit itself')
        local link = ask(6, 'announce', { text = 'join discord.gg/abc' })
        falsy(link.ok, 'a link went out')
        eq(ask(6, 'announce', { text = '   ' }).err, 'text_refused')
        eq(ask(6, 'announce', { text = 'hi', scope = 'everyone' }).err, CH.ERR.INVALID_INPUT)
        eq(ask(6, 'announce', { text = 42 }).err, CH.ERR.INVALID_INPUT)
        Env.clientEvents = {}
        for _, src in ipairs({ 3, 7 }) do
            local reply = ask(src, 'announce', { text = 'hello' })
            eq(reply and reply.err, 'not_allowed', tostring(src))
        end
        eq(#notices(3), 0, 'a refused notice reached a hitman')
        eq(#stored(s, 'staff_announce'), 1, 'only the one sent is on the record')
    end)
end)

--------------------------------------------------------------------------
-- 4. Pause the whole app
--------------------------------------------------------------------------

describe('pausing the whole app', function()
    local function turn(s, on)
        local ok, err, why = s.settings.set('Holds.AppPaused', on, 'ADMIN001', 'ADMIN001')
        truthy(ok, ('Holds.AppPaused: %s %s'):format(tostring(err), tostring(why)))
    end

    it('is in the catalogue under Features, a switch, shipped off', function()
        local _, s = boot()
        local entry = s.settings.entry('Holds.AppPaused')
        truthy(entry, 'catalogued')
        eq(entry.category, 'features')
        eq(entry.kind, 'switch')
        eq(Config.Holds.AppPaused, false)
    end)

    it('refuses placing and accepting with nothing charged, holds both clocks, and gives them back', function()
        local main, s = boot()
        local f = people(s)
        local c = place(s, f.creator, { penaltyAmount = 500 })
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        local open = place(s, f.creator, { targetCid = 'PUBLIC01' })
        pass(main)
        eq(row(s, c).paused_since, nil, 'running before')
        local left = Util.runLeft(row(s, c))
        local lifetime = row(s, c).expires_at - os.time()
        local openLifetime = row(s, open).expires_at - os.time()

        Env.clientEvents = {}
        turn(s, true)
        truthy(s.holds.global('app'), 'paused')
        eq(row(s, c).paused_since, os.time(), 'the deadline stopped when the pause began')
        for _, src in ipairs({ 1, 3 }) do
            eq(count(notices(src), 'Contracts are paused by staff.'), 1, 'one notice to ' .. src)
        end

        local before = { wealth(1), wealth(4), wealth(5) }
        local placed, err = s.contracts.create(f.public, { targetCid = 'TARGET01', reason = 'x',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        falsy(placed, 'placed while paused')
        eq(err, CH.ERR.APP_PAUSED)
        local took, takeErr = s.contracts.accept(f.hitman2, open.id)
        falsy(took, 'accepted while paused')
        eq(takeErr, CH.ERR.APP_PAUSED)
        local reply = call('accept', 4, { id = open.id, penaltyAmount = 0 })
        eq(reply and reply.err, 'app_paused', 'the page is told')
        eq(wealth(1), before[1], 'nothing charged')
        eq(wealth(4), before[2], 'nothing charged')
        eq(wealth(5), before[3], 'nothing charged')

        Env.advance(7200)
        pass(main)
        main.tick()
        eq(row(s, c).state, CH.STATE.ACCEPTED, 'ended while paused')
        eq(Util.runLeft(row(s, c)), left, 'the deadline ran while paused')

        Env.clientEvents = {}
        turn(s, false)
        falsy(s.holds.global('app'), 'still paused')
        eq(count(notices(1), 'Contracts are no longer paused.'), 1, 'told it is over')
        pass(main)
        eq(row(s, c).paused_since, nil, 'not running again')
        eq(Util.runLeft(row(s, c)), left, 'the time paused charged to the deadline')
        eq(row(s, c).expires_at - os.time(), lifetime, 'the lifetime not given back')
        eq(row(s, open).expires_at - os.time(), openLifetime, 'the open one\'s lifetime not given back')
        truthy(s.contracts.accept(f.hitman2, open.id), 'accepting works again')
    end)

    it('never ends a freeze or the restart hold, nor is ended by one, and gives each span once', function()
        local main, s = boot()
        local f = people(s)
        local c = place(s, f.creator)
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        pass(main)
        local left = Util.runLeft(row(s, c))
        local lifetime = row(s, c).expires_at - os.time()

        -- Frozen first, then paused: the unfreeze leaves the pause's hold.
        truthy(s.holds.freeze('ADMIN001', 'TARGET01', 'dispute'), 'frozen')
        Env.advance(60)
        turn(s, true)
        Env.advance(60)
        truthy(s.holds.unfreeze('ADMIN001', 'TARGET01'), 'released')
        truthy(row(s, c).paused_since, 'an unfreeze ended the app pause\'s hold')
        main.expire()
        truthy(row(s, c).paused_since, 'and the pass after it')

        -- The restart hold on top, then the pause ends: the restart hold's stays.
        Env.advance(60)
        TriggerEvent('txAdmin:events:scheduledRestart', { secondsRemaining = 1800 })
        truthy(s.holds.global('restart'), 'the restart hold')
        Env.advance(60)
        turn(s, false)
        main.expire()
        truthy(row(s, c).paused_since, 'the end of the pause ran a clock the restart hold stops')

        -- Paused again, then the restart is skipped: the pause's stays.
        turn(s, true)
        Env.advance(60)
        TriggerEvent('txAdmin:events:scheduledRestartSkipped', {})
        main.expire()
        truthy(row(s, c).paused_since, 'the skip ran a clock the app pause stops')
        Env.advance(60)
        turn(s, false)
        pass(main)
        eq(row(s, c).paused_since, nil, 'running once nothing stops it')
        eq(Util.runLeft(row(s, c)), left, 'a second of the holds charged to the deadline')
        eq(row(s, c).expires_at - os.time(), lifetime, 'the lifetime given back other than once')
    end)

    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': outlives a restart, the downtime counted as paused', function()
            local main, s = boot(mode)
            local f = people(s)
            local c = place(s, f.creator)
            truthy(s.contracts.accept(f.hitman, c.id), 'taken')
            pass(main)
            local left = Util.runLeft(row(s, c))
            local lifetime = row(s, c).expires_at - os.time()
            turn(s, true)
            local since = s.holds.global('app')
            Env.advance(600)
            local main2, after = restart(mode, s)
            truthy(after.holds.global('app'), mode .. ': the pause was lost to the restart')
            eq(after.holds.global('app'), since, mode .. ': when it began')
            local placed, err = after.contracts.create(f.public, { targetCid = 'TARGET01', reason = 'x',
                mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
            falsy(placed, mode .. ': placed while paused after the restart')
            eq(err, CH.ERR.APP_PAUSED)
            Env.advance(600)
            turn(after, false)
            pass(main2)
            eq(Util.runLeft(after.storage.readContract(c.id)), left, mode .. ': the deadline')
            eq(after.storage.readContract(c.id).expires_at - os.time(), lifetime, mode .. ': the lifetime')
            local _, third = restart(mode, after)
            falsy(third.holds.global('app'), mode .. ': the end was lost to the restart')
        end)
    end
end)

--------------------------------------------------------------------------
-- 5. Settings history with Undo
--------------------------------------------------------------------------

describe('the settings history', function()
    it('lists each change with who, when and both values, and Undo puts the old one back', function()
        local _, s = boot()
        people(s)
        truthy(ask(6, 'setSetting', { key = 'Relay.Enabled', value = false }).ok, 'changed')
        Env.advance(5)
        truthy(ask(6, 'setSetting', { key = 'Limits.MaxActiveContractsPerTarget', value = 4 }).ok, 'changed')
        local plain = ask(6, 'settingsHistory', {})
        truthy(plain.ok, plain.message)
        local rows = plain.data.rows
        eq(rows[1].key, 'Limits.MaxActiveContractsPerTarget', 'newest first')
        eq(rows[1].old, 10)
        eq(rows[1].new, 4)
        eq(rows[2].key, 'Relay.Enabled')
        eq(rows[2].old, true)
        eq(rows[2].new, false)
        eq(rows[2].by, 'a staff member', 'who, without IdentityAce')
        truthy(rows[2].ts and rows[2].ref, 'when, and an Undo')
        falsy(text(plain.data):find('ADMIN001', 1, true), 'a citizen id to staff without IdentityAce')
        eq(ask(8, 'settingsHistory', {}).data.rows[2].by, 'ADMIN001', 'with IdentityAce')

        local reader = ask(7, 'settingsHistory', {})
        truthy(reader.ok, 'a reader reads it')
        eq(reader.data.rows[2].key, 'Relay.Enabled')
        eq(reader.data.rows[2].ref, nil, 'and gets no Undo')
        eq(ask(7, 'undoSetting', { ref = rows[2].ref }).err, 'not_allowed')
        eq(ask(3, 'settingsHistory', {}).err, 'not_allowed', 'a player reads nothing')
        eq(ask(3, 'undoSetting', { ref = rows[2].ref }).err, 'not_allowed')
        eq(Config.Relay.Enabled, false, 'a refused undo changed it')

        local undo = ask(6, 'undoSetting', { ref = rows[2].ref })
        truthy(undo.ok, undo.message)
        eq(Config.Relay.Enabled, true, 'undone')
        truthy(undo.message:find('Undone', 1, true), undo.message)
        local undoRows = stored(s, 'admin_undo_setting')
        eq(#undoRows, 1, 'the undo on the record')
        eq(undoRows[1].actor_cid, 'ADMIN001')
        eq(undoRows[1].detail.key, 'Relay.Enabled')
        eq(undoRows[1].detail.to, true)
        eq(#stored(s, 'admin_setting_changed'), 3, 'through the normal set path, with its own row')
        local again = ask(6, 'settingsHistory', {})
        eq(again.data.rows[1].key, 'Relay.Enabled', 'the undo is itself in the history')
        eq(again.data.rows[1].old, false)
        eq(ask(6, 'undoSetting', { ref = 'h99999' }).err, CH.ERR.NOT_FOUND)
        eq(ask(6, 'undoSetting', { ref = 42 }).err, CH.ERR.NOT_FOUND)
    end)

    it('an undo is checked as any change is', function()
        local _, s = boot()
        people(s)
        truthy(ask(6, 'setSetting', { key = 'Bailout.MaxMultiplier', value = 5 }).ok, 'changed')
        local ref = ask(6, 'settingsHistory', {}).data.rows[1].ref
        local least = ask(6, 'setSetting', { key = 'Bailout.MinMultiplier', value = 4 })
        truthy(least.ok, least.message)
        local undo = ask(6, 'undoSetting', { ref = ref })
        falsy(undo.ok, 'an undo the start-up checks refuse: the most under the least')
        eq(Config.Bailout.MaxMultiplier, 5, 'and nothing changed')
        eq(#stored(s, 'admin_undo_setting'), 0, 'a refused undo is not recorded as one')
    end)

    it('shows the Developer section\'s keys only to its staff, and never a secret', function()
        local _, s = boot()
        people(s)
        truthy(ask(6, 'setSetting', { key = 'Debug', value = true }).ok, 'changed')
        truthy(ask(6, 'setSetting', { key = 'Relay.Enabled', value = false }).ok, 'changed')
        local reader = ask(7, 'settingsHistory', {})
        for _, r in ipairs(reader.data.rows) do falsy(r.key == 'Debug', 'a Developer key to a reader') end
        eq(reader.data.hidden, 1, 'and says one is left out')
        local admin = ask(6, 'settingsHistory', {})
        eq(admin.data.rows[2].key, 'Debug', 'the staff ACE opens the Developer section')
        truthy(s.settings.secretKey('convar:crimson_hitman_webhook'), 'the webhook is a secret')
        truthy(s.settings.secretKey('convar:crimson_hitman_alert_webhook'), 'and the alert webhook')
        falsy(s.settings.secretKey('Relay.Enabled'))
        -- A row for a secret (none can be written from the panel) shows no value.
        s.audit.staff('admin_setting_changed', 'ADMIN001', nil,
            { key = 'convar:crimson_hitman_webhook', old = 'https://a', new = 'https://b', by = 'ADMIN001' })
        local hist = ask(6, 'settingsHistory', {})
        eq(hist.data.rows[1].key, 'convar:crimson_hitman_webhook')
        eq(hist.data.rows[1].old, nil, 'a secret\'s old value')
        eq(hist.data.rows[1].new, nil, 'a secret\'s new value')
        eq(hist.data.rows[1].ref, nil, 'an Undo of a secret')
        falsy(text(hist.data):find('https://', 1, true), 'a secret shown')
    end)

    it('lists each key a reset of every setting changed, each with its Undo', function()
        local _, s = boot()
        people(s)
        truthy(ask(6, 'setSetting', { key = 'Relay.Enabled', value = false }).ok)
        truthy(ask(6, 'setSetting', { key = 'Limits.MaxActiveContractsPerTarget', value = 4 }).ok)
        truthy(ask(6, 'resetSettings', {}).ok, 'reset all')
        local rows = ask(6, 'settingsHistory', {}).data.rows
        local seen = {}
        for i = 1, 2 do seen[rows[i].key] = rows[i] end
        eq(seen['Relay.Enabled'].new, true)
        eq(seen['Relay.Enabled'].old, false)
        truthy(seen['Relay.Enabled'].reset, 'marked as back to config.lua')
        truthy(ask(6, 'undoSetting', { ref = seen['Relay.Enabled'].ref }).ok, 'undone')
        eq(Config.Relay.Enabled, false)
        local _ = s
    end)
end)

--------------------------------------------------------------------------
-- 6. Players' reports
--------------------------------------------------------------------------

describe('a player\'s report to staff', function()
    local function world()
        local main, s = boot(nil, function()
            Config.Relay.MaxMessagesPerThread = 100
            Config.Cooldowns.message = { per = 1, burst = 100 }
        end)
        local f = people(s)
        local c = place(s, f.creator, { anonymous = true })
        truthy(s.contracts.accept(f.hitman, c.id, true), 'taken anonymously')
        for i = 1, 25 do
            local who = i % 2 == 1 and f.hitman or f.creator
            local handle
            if who == f.creator then handle = s.comms.threads(f.creator, c.id)[1].handle end
            truthy(s.comms.send(who, c.id, handle, 'message ' .. i), 'sent ' .. i)
        end
        return main, s, f, c
    end

    local function reports(s)
        local out = {}
        for _, item in ipairs(s.review.list(false, 50)) do
            if item.kind == 'player_report' then out[#out + 1] = item end
        end
        return out
    end

    it('puts the contract, the role, the note and the last 20 messages in the review queue', function()
        local _, s, _, c = world()
        Env.clientEvents = {}
        local reply = call('report', 3, { id = c.id, note = 'Threats in the thread' })
        truthy(reply and reply.ok, reply and reply.err)
        eq(text(reply.data):find('CREATOR1', 1, true), nil, 'the reply names somebody')
        for _, event in ipairs(Env.clientEvents) do
            falsy(event.target == 1, 'the reported placer was told something: ' .. tostring(event.name))
        end
        local items = reports(s)
        eq(#items, 1, 'one report')
        local item = items[1]
        eq(item.contract_id, c.id)
        eq(item.known.role, 'hitman')
        eq(item.known.note, 'Threats in the thread')
        eq(#item.known.excerpt, 20, 'the last twenty')
        eq(item.known.excerpt[20].body, 'message 25', 'the newest last')
        eq(item.known.excerpt[1].body, 'message 6')
        eq(item.cids.from, 'HITMAN01')
        eq(item.cids.reported, 'CREATOR1')
        for _, m in ipairs(item.known.excerpt) do
            falsy(text(m):find('CREATOR1', 1, true) or text(m):find('HITMAN01', 1, true), 'a citizen id in a message')
        end
    end)

    it('from the placer\'s thread, and from a stranger on the board; refused where it cannot be seen', function()
        local _, s, f, c = world()
        local handle = s.comms.threads(f.creator, c.id)[1].handle
        truthy(call('report', 1, { id = c.id, thread = handle }).ok, 'the placer, from the thread')
        truthy(call('report', 5, { id = c.id }).ok, 'a viewer of the board')
        local items = reports(s)
        eq(#items, 2)
        local byRole = {}
        for _, item in ipairs(items) do byRole[item.known.role] = item end
        eq(byRole.placer.cids.reported, 'HITMAN01', 'the other end of the thread')
        eq(#byRole.placer.known.excerpt, 20)
        eq(byRole.viewer.known.excerpt, nil, 'a viewer has no thread')
        eq(call('report', 5, { id = c.id, thread = handle }).err, CH.ERR.NOT_PARTICIPANT,
            'somebody else\'s thread handle')
        eq(call('report', 5, { id = 'ct0000000000' }).err, CH.ERR.NOT_FOUND)
        eq(call('report', 5, { id = 42 }).err, CH.ERR.INVALID_INPUT)
        eq(call('report', 4, { id = c.id, note = ('n'):rep(201) }).err, CH.ERR.INVALID_INPUT)
        truthy(s.contracts.cancel and true)
    end)

    it('is rate-limited by its own bucket', function()
        local _, _, _, c = world()
        for i = 1, Config.Cooldowns.report.burst do truthy(call('report', 5, { id = c.id }).ok, 'report ' .. i) end
        eq(call('report', 5, { id = c.id }).err, CH.ERR.RATE_LIMITED)
        eq(Config.Cooldowns.report.per, 600)
    end)

    it('names nobody anonymous to staff without IdentityAce, and the reporter to staff with it', function()
        local _, _, _, c = world()
        truthy(call('report', 3, { id = c.id, note = 'Vic Marlowe threatened me' }).ok)
        local plain = ask(6, 'reviews', {})
        truthy(plain.ok)
        local said = text(plain.data)
        for _, needle in ipairs({ 'CREATOR1', 'HITMAN01', 'Vic Marlowe', 'Rook Ash', 'license:' }) do
            falsy(said:find(needle, 1, true), 'staff without IdentityAce read ' .. needle)
        end
        truthy(said:find('message 25', 1, true), 'the messages are there')
        local unmasked = text(ask(8, 'reviews', {}).data)
        truthy(unmasked:find('HITMAN01', 1, true), 'the reporter to IdentityAce staff')
        truthy(unmasked:find('CREATOR1', 1, true), 'the reported party to IdentityAce staff')
        -- Dismissed as any item is.
        local item
        for _, it_ in ipairs(ask(6, 'reviews', {}).data.items) do
            if it_.kind == 'player_report' then item = it_ end
        end
        truthy(item and item.about, 'it says what it is')
        local done = ask(6, 'resolve', { id = item.id, action = 'dismiss', note = 'Spoke to them' })
        truthy(done.ok, done.message)
    end)
end)
