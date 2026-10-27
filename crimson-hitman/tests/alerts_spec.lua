--- The admin panel's Alerts, and the same alerts posted to Discord
--- (server/alerts.lua, server/panel.lua's alerts, ackAlerts and testAlert).
---
--- What these hold the feature to: every line printed whatever Config.Debug
--- says becomes an alert, without the path that printed it waiting on
--- anything; the same line again is counted, not kept twice; at most
--- Alerts.MAX are kept, never an unacknowledged one said within 30 days; they
--- outlive a restart on memory, json and mysql; acknowledging is a staff
--- write, audited and rate-limited; staff without IdentityAce, and Discord,
--- read the text scrubbed; and Discord gets one post every ten seconds at
--- most, ten alerts a post, retried and given up after three tries, with no
--- address and no identity in it.

local Exec = require('crimson-hitman.tests.harness.mysql_exec')
local Log = require('crimson-hitman.shared.log')

local HOOK_ALERT = 'https://discord.example/api/webhooks/alert-hook'
local HOOK_STAFF = 'https://discord.example/api/webhooks/staff-hook'

--- A stack with the usual three players and three staff: crimson.admin,
--- an extra ACE only (reads), and crimson.admin with crimson.identity.
local function stack()
    local s = newStack()
    local f = fixture(s)
    Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
        firstname = 'Sam', lastname = 'Steward' })
    Env.addPlayer({ source = 7, citizenid = 'READER01', license = 'license:READER01',
        firstname = 'Rae', lastname = 'Dent' })
    Env.addPlayer({ source = 8, citizenid = 'UNMASK01', license = 'license:UNMASK01',
        firstname = 'Uma', lastname = 'Mask' })
    Env.aces[6] = { ['crimson.admin'] = true }
    Env.aces[7] = { command = true }
    Env.aces[8] = { ['crimson.admin'] = true, ['crimson.identity'] = true }
    Config.Cooldowns.admin = { per = 10, burst = 500 }
    Config.Cooldowns.adminWrite = { per = 10, burst = 500 }
    Natives.calls.http = {}
    s.bridges.install(s)
    return s, f
end

local function ask(src, op, data)
    Env.clientEvents = {}
    _G.source = src
    local fired, err = pcall(Env.events['crimson-hitman:admin'], { op = op, data = data or {}, __rid = 9 })
    _G.source = nil
    truthy(fired, 'the net event must not raise: ' .. tostring(err))
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:adminResult' then return event.args[1] end
    end
    return nil
end

local function open(s)
    return (s.alerts.list('open', 1000))
end

local function find(rows, needle)
    for _, row in ipairs(rows) do
        if tostring(row.text):find(needle, 1, true) then return row end
    end
    return nil
end

local function strings(value, out)
    out = out or {}
    if type(value) == 'string' then
        out[#out + 1] = value
    elseif type(value) == 'table' then
        for k, v in pairs(value) do strings(k, out) strings(v, out) end
    end
    return out
end

local function bodies()
    local out = {}
    for _, call in ipairs(Natives.calls.http or {}) do out[#out + 1] = tostring(call.body) end
    return out
end

--------------------------------------------------------------------------
-- Every line printed whatever Debug says
--------------------------------------------------------------------------

describe('what becomes an alert', function()
    it('keeps every Log.always line and every setting problem, whatever Debug says', function()
        local s = stack()
        -- With the console quiet, whatever ships: the alerts are the same.
        Config.Debug = false
        Log.always('the store would not take escrow line owe00000001')
        Log.problem('warning: Limits.MaxAcceptedPerHitman is 0')
        Log.debug('a debug line is not an alert')
        local rows = open(s)
        eq(#rows, 2)
        eq(find(rows, 'owe00000001').level, 'always')
        eq(find(rows, 'MaxAcceptedPerHitman').level, 'problem')
        falsy(find(rows, 'debug line'), 'debug lines stay in the diagnosis only')
        local a = find(rows, 'owe00000001')
        eq(a.count, 1)
        eq(a.first_at, os.time())
        eq(a.last_at, os.time())
        truthy(a.id and #a.id >= 8, 'an id of its own')
    end)

    it('keeps what the start said before the Alerts were listening, with when it was said', function()
        local s = stack()
        Log.beginStart()
        local said = os.time()
        Log.problem('warning: Penalty.MaxAmount is above the reward')
        Log.always('FATAL: nothing, this is a test')
        Env.advance(30)
        s.alerts.init(s)
        local rows = open(s)
        eq(#rows, 2, 'both kept')
        eq(find(rows, 'Penalty.MaxAmount').first_at, said)
        eq(find(rows, 'FATAL').level, 'always')
    end)

    it('keeps a raise said at once, and the line counting the ones held back after it', function()
        local s = stack()
        Log.raised('request cancel', 'request cancel raised: boom on ct00000001')
        Log.raised('request cancel', 'request cancel raised: boom on ct00000002')
        eq(#open(s), 1, 'the second, inside the five minutes, is a debug line')
        Env.advance(Log.RAISED_EVERY)
        local held = find(open(s), 'raised 1 more time(s)')
        truthy(held, 'the summary is an alert')
        eq(held.level, 'always')
    end)

    it('keeps a block of lines as one alert, the rules of = left out', function()
        local s = stack()
        Log.always('============================================')
        Log.always('BOOT RECOVERY FAILED: the store raised')
        Log.always('  What the last shutdown left part-way is not settled, so the app,')
        Log.always('  the login payouts and the staff commands that settle, void or')
        Log.always('============================================')
        local rows = open(s)
        eq(#rows, 1, 'one alert for the block')
        truthy(rows[1].text:find('^BOOT RECOVERY FAILED'), rows[1].text)
        truthy(rows[1].text:find('login payouts', 1, true), 'with its lines: ' .. rows[1].text)
    end)

    it('names the contract a line names', function()
        local s = stack()
        Log.always('voiding contract ct8a2k4m9x0q1z raised: boom')
        eq(open(s)[1].contract_id, 'ct8a2k4m9x0q1z')
    end)

    it('keeps the lines of real paths: a staff write that raised, a review item opened', function()
        local s = stack()
        local real = s.admin.void
        s.admin.void = function() error('the void exploded') end
        local reply = ask(6, 'void', { id = 'ct00000042', reason = 'x' })
        s.admin.void = real
        eq(reply.err, 'server_error')
        truthy(find(open(s), 'the admin panel\'s void raised'), 'the panel write that raised')
        s.review.open({ kind = 'bailout_refund_stranded', contract_id = 'ct00000077',
            cids = { payer = 'TARGET01' }, amount = 500, account = 'bank', known = {} })
        local review = find(open(s), 'left for staff: review')
        truthy(review, 'the item left for staff')
        eq(review.contract_id, 'ct00000077')
    end)

    --- Every file that prints whatever Debug says does it through the one
    --- logger, which hands each line over (static check 33 holds the rest:
    --- no file prints any other way).
    it('reaches every Log.always and Log.raised call through shared/log.lua', function()
        local files = io.popen('ls crimson-hitman/server/*.lua crimson-hitman/server/*/*.lua '
            .. 'crimson-hitman/shared/*.lua')
        local callers = 0
        for path in files:lines() do
            local src = read_file(path)
            if not path:find('shared/log.lua', 1, true) and (src:find('Log%.always%(')
                or src:find('Log%.raised%(') or src:find('%.log%(%)%.always%(')) then
                callers = callers + 1
                truthy(src:find("CrimsonBoot.requireShared('log')", 1, true)
                    or src:find('CrimsonBoot.log()', 1, true),
                    path .. ' takes its Log from shared/log.lua')
            end
        end
        files:close()
        truthy(callers >= 15, callers .. ' files print whatever Debug says')
        local logger = read_file('crimson-hitman/shared/log.lua')
        truthy(logger:find("keep%(text, loud, Log.KEPT_ALWAYS%)%s*toAlerts%('always', text%)"),
            'Log.always hands its line over')
        truthy(logger:find("problems%[#problems %+ 1%] = entry%s*toAlerts%('problem', text%)"),
            'Log.problem hands its line over')
    end)
end)

--------------------------------------------------------------------------
-- The same line again
--------------------------------------------------------------------------

describe('merging', function()
    it('counts the same line again on the alert, its numbers aside', function()
        local s = stack()
        Log.always('waiting for the database (30 s): connect ECONNREFUSED')
        Env.advance(30)
        Log.always('waiting for the database (60 s): connect ECONNREFUSED')
        local rows = open(s)
        eq(#rows, 1)
        eq(rows[1].count, 2)
        eq(rows[1].last_at - rows[1].first_at, 30)
        truthy(rows[1].text:find('60 s', 1, true), 'the newest words')
    end)

    it('keeps two contracts, or two escrow lines, as two alerts', function()
        local s = stack()
        Log.always('escrow line owe00000003 was mid-release at shutdown; returned to held')
        Log.always('escrow line owe00000007 was mid-release at shutdown; returned to held')
        Log.always('voiding contract ct00000001 raised: x')
        Log.always('voiding contract ct00000002 raised: x')
        eq(#open(s), 4)
    end)

    it('makes a new alert for a line said again after its alert was acknowledged', function()
        local s = stack()
        Log.always('maintenance job "expireContracts" failed: boom')
        local first = open(s)[1]
        s.alerts.acknowledge({ first.id }, 'ADMIN001')
        Log.always('maintenance job "expireContracts" failed: boom')
        local rows = open(s)
        eq(#rows, 1, 'open again')
        truthy(rows[1].id ~= first.id, 'as a new alert')
        eq(#(s.alerts.list('acknowledged', 10)), 1, 'the acknowledged one kept as it was')
    end)
end)

--------------------------------------------------------------------------
-- Pruning
--------------------------------------------------------------------------

describe('pruning', function()
    it('keeps at most 500, the oldest acknowledged first', function()
        local s = stack()
        local now = os.time()
        for i = 1, 500 do s.alerts.note('always', ('line %s'):format(('x'):rep(i % 7) .. 'k' .. i), now - 1000 + i) end
        local acked = {}
        for _, row in ipairs(open(s)) do
            if #acked < 20 then acked[#acked + 1] = row.id end
        end
        s.alerts.acknowledge(acked, 'ADMIN001')
        for i = 1, 5 do s.alerts.note('always', 'fresh line n' .. ('y'):rep(i), now) end
        local _, counts = s.alerts.list('open', 1)
        eq(counts.open + counts.acknowledged, 500, 'at most 500')
        eq(counts.acknowledged, 15, 'five acknowledged ones went')
        eq(counts.open, 485, 'and no open one')
        eq(#s.storage.readAlerts(), 500, 'the store holds the same')
    end)

    it('never prunes an unacknowledged alert said within 30 days; an older one goes first', function()
        local s = stack()
        local now = os.time()
        s.alerts.note('always', 'an old line nobody read', now - 40 * 86400)
        for i = 1, 510 do s.alerts.note('always', 'recent line ' .. ('z'):rep(i % 9) .. 'q' .. i, now) end
        local rows, counts = s.alerts.list('open', 1000)
        eq(counts.open, 510, 'every recent one kept, past 500')
        falsy(find(rows, 'an old line nobody read'), 'the one not said for 40 days went')
    end)
end)

--------------------------------------------------------------------------
-- A restart, on every store
--------------------------------------------------------------------------

describe('a restart', function()
    local function load(store)
        package.loaded['crimson-hitman.server.alerts'] = nil
        local alerts = require('crimson-hitman.server.alerts')
        alerts.init({ storage = store })
        return alerts
    end

    it('memory: the alerts come back, and the same line again counts on them', function()
        local s = stack()
        Log.always('the store would not take escrow line owe00000001')
        Log.always('the store would not take escrow line owe00000001')
        Log.problem('warning: Kidnap.Radius is 2')
        local acked = find(open(s), 'Kidnap.Radius')
        s.alerts.acknowledge({ acked.id }, 'ADMIN001')
        local again = load(s.storage)
        local rows, counts = again.list('open', 10)
        eq(counts.open, 1)
        eq(counts.acknowledged, 1)
        eq(rows[1].count, 2)
        eq(again.list('acknowledged', 1)[1].acknowledged_by, 'ADMIN001')
        Log.always('the store would not take escrow line owe00000001')
        eq(again.list('open', 10)[1].count, 3, 'merged across the restart')
        eq(#again.list('open', 10), 1)
    end)

    it('json: kept in records.json by the flush, never by a money write\'s save', function()
        newStack()
        package.loaded['crimson-hitman.server.storage.json'] = nil
        Natives.files = {}
        Natives.saveFile = nil
        local store = require('crimson-hitman.server.storage.json')
        store.open()
        local alerts = load(store)
        local wrote = {}
        Natives.saveFile = function(file) wrote[(file:gsub('%.new$', ''))] = true end
        Log.always('could not write data/contracts/ct00000009.json')
        store.writeContract({ id = 'ct00000009', creator_cid = 'C', target_cid = 'T',
            state = CH.STATE.ACTIVE, created_at = os.time() })
        store.save(true)
        Natives.saveFile = nil
        falsy(wrote['data/records.json'], 'a money write\'s save leaves the alert to the flush')
        truthy(store.flush(), 'the flush')
        truthy(Natives.files['data/records.json']:find('ct00000009', 1, true), 'writes it')
        alerts.acknowledge({ alerts.list('open', 1)[1].id }, 'ADMIN001')
        store.close()

        package.loaded['crimson-hitman.server.storage.json'] = nil
        local reopened = require('crimson-hitman.server.storage.json')
        reopened.open()
        local again = load(reopened)
        local rows = again.list('acknowledged', 10)
        eq(#rows, 1, 'back after the restart')
        eq(rows[1].acknowledged_by, 'ADMIN001')
        eq(rows[1].contract_id, 'ct00000009')
    end)

    it('mysql: written in a thread of its own, in crimson_alerts, and read back at start', function()
        newStack()
        Exec.install(Natives)
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local store = require('crimson-hitman.server.storage.mysql')
        store.open()
        local alerts = load(store)
        Exec.down = true
        local said = Env.spawn(function() Log.always('voiding contract ct00000005 raised: boom') end)
        truthy(said.done, 'the line that printed it waited for nothing, the database down or not')
        eq(next(Exec.tables.crimson_alerts or {}), nil, 'not written yet')
        Exec.down = false
        Env.advance(5)
        Log.always('voiding contract ct00000005 raised: boom')
        Env.advance(5)
        local stored = 0
        for _, row in pairs(Exec.tables.crimson_alerts) do
            stored = stored + 1
            eq(row.occurrences, 2, 'counted')
            eq(row.contract_id, 'ct00000005')
            eq(row.level, 'always')
        end
        eq(stored, 1)

        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local reopened = require('crimson-hitman.server.storage.mysql')
        reopened.open()
        local again = load(reopened)
        local rows = again.list('open', 10)
        eq(#rows, 1, 'back after the restart')
        eq(rows[1].count, 2)
    end)
end)

describe('merging, pruning and a restart on every store', function()
    local function opened(name, reopen)
        if name == 'memory' then
            if not reopen then
                package.loaded['crimson-hitman.server.storage.memory'] = nil
                local store = require('crimson-hitman.server.storage.memory')
                store.open()
            end
            return require('crimson-hitman.server.storage.memory')
        end
        local module = 'crimson-hitman.server.storage.' .. name
        if name == 'json' and not reopen then Natives.files = {} end
        if name == 'mysql' and not reopen then Exec.install(Natives) end
        package.loaded[module] = nil
        local store = require(module)
        store.open()
        return store
    end

    local function alertsOn(store)
        package.loaded['crimson-hitman.server.alerts'] = nil
        local alerts = require('crimson-hitman.server.alerts')
        alerts.MAX = 5
        alerts.init({ storage = store })
        return alerts
    end

    for _, name in ipairs({ 'memory', 'json', 'mysql' }) do
        it(name, function()
            newStack()
            local store = opened(name)
            local alerts = alertsOn(store)
            Log.always('the same line, after 1 attempt(s)')
            Log.always('the same line, after 2 attempt(s)')
            local same = alerts.list('open', 10)[1]
            eq(same.count, 2, 'merged')
            alerts.acknowledge({ same.id }, 'ADMIN001')
            Env.advance(5)
            for i = 1, 5 do Log.always('another line ' .. ('k'):rep(i)) end
            Env.advance(5)
            if store.flush then store.flush() end
            local _, counts = alerts.list('open', 10)
            eq(counts.open, 5)
            eq(counts.acknowledged, 0, 'the acknowledged one pruned first')
            local rows = store.readAlerts()
            eq(#rows, 5, 'and deleted from the store')
            if name ~= 'memory' then store.close() end

            local again = alertsOn(opened(name, true))
            local _, after = again.list('open', 10)
            eq(after.open, 5, 'back after the restart')
            Log.always('another line k')
            eq(again.list('open', 10)[1].count, 2, 'merged with one kept from before')
        end)
    end
end)

--------------------------------------------------------------------------
-- A write that fails
--------------------------------------------------------------------------

describe('a store that will not take an alert', function()
    it('still prints the line, keeps the alert in memory and writes it later', function()
        local s = stack()
        local real = s.storage.writeAlert
        s.storage.writeAlert = function() error('the store is gone') end
        local ok = pcall(Log.always, 'the store would not take escrow line owe00000002')
        truthy(ok, 'Log.always never raises for it')
        local view, said = Log.view(), false
        for _, text in ipairs(view.boot) do said = said or text:find('owe00000002', 1, true) ~= nil end
        for _, entry in ipairs(view.recent) do said = said or entry.text:find('owe00000002', 1, true) ~= nil end
        truthy(said, 'the line was said, and kept for the diagnosis')
        truthy(find(open(s), 'owe00000002'), 'and the alert is in memory')
        eq(#s.storage.readAlerts(), 0, 'not in the store yet')
        s.storage.writeAlert = real
        Env.advance(s.alerts.RETRY_MS / 1000)
        eq(#s.storage.readAlerts(), 1, 'written by the next try')
    end)
end)

--------------------------------------------------------------------------
-- The panel
--------------------------------------------------------------------------

describe('the Alerts section', function()
    it('lists open alerts newest first, and acknowledged ones apart, with the open count', function()
        local s = stack()
        Log.always('first line')
        Env.advance(5)
        Log.always('second line')
        local reply = ask(7, 'alerts', {})
        eq(reply.ok, true, tostring(reply.message))
        eq(reply.data.state, 'open')
        eq(#reply.data.rows, 2)
        eq(reply.data.rows[1].text, 'second line', 'newest first')
        eq(reply.data.open, 2)
        eq(ask(7, 'overview', {}).data.alerts.open, 2, 'the overview counts them for the badge')
        local done = ask(6, 'ackAlerts', { ids = { reply.data.rows[2].id } })
        eq(done.ok, true, tostring(done.message))
        truthy(done.message:find('Acknowledged 1 alert', 1, true), done.message)
        local acked = ask(7, 'alerts', { state = 'acknowledged' })
        eq(#acked.data.rows, 1)
        eq(acked.data.rows[1].text, 'first line')
        eq(acked.data.rows[1].acknowledged_by, 'a staff member',
            'a reader without the identity ACE is not told whose citizen id acknowledged it')
        eq(ask(8, 'alerts', { state = 'acknowledged' }).data.rows[1].acknowledged_by, 'ADMIN001',
            'one with it is')
        eq(acked.data.open, 1)
    end)

    it('acknowledges every one shown in one request', function()
        local s = stack()
        for i = 1, 4 do Log.always('line ' .. ('w'):rep(i)) end
        local ids = {}
        for _, row in ipairs(ask(6, 'alerts', {}).data.rows) do ids[#ids + 1] = row.id end
        local reply = ask(6, 'ackAlerts', { ids = ids })
        truthy(reply.message:find('Acknowledged 4 alert', 1, true), reply.message)
        eq(s.alerts.openCount(), 0)
        local again = ask(6, 'ackAlerts', { ids = ids })
        eq(again.ok, true)
        truthy(again.message:find('acknowledged already', 1, true), again.message)
    end)

    it('lets only the ACE itself acknowledge, audits it, and rate-limits it like any write', function()
        local s = stack()
        Log.always('a line to acknowledge')
        local id = open(s)[1].id
        local refused = ask(7, 'ackAlerts', { ids = { id } })
        eq(refused.err, 'not_allowed', 'an extra ACE only reads')
        eq(s.alerts.openCount(), 1, 'nothing acknowledged')
        eq(ask(3, 'alerts', {}).err, 'not_allowed', 'a player reads nothing')
        eq(ask(6, 'ackAlerts', { ids = { 'not an id!' } }).err, 'invalid_input')
        eq(ask(6, 'ackAlerts', { ids = { id } }).ok, true)
        s.audit.flush()
        local rows = s.storage.auditByAction('admin_alerts_acknowledged')
        eq(#rows, 1, 'one row in the log')
        eq(rows[1].actor_cid, 'ADMIN001')
        eq(rows[1].detail.count, 1)
        eq(rows[1].detail.ids[1], id)
    end)

    it('spends the write allowance, as every other write does', function()
        local s = stack()
        Config.Cooldowns.adminWrite = { per = 60, burst = 1 }
        Log.always('one line')
        Log.always('another line')
        local rows = open(s)
        eq(ask(6, 'ackAlerts', { ids = { rows[1].id } }).ok, true)
        eq(ask(6, 'ackAlerts', { ids = { rows[2].id } }).err, 'rate_limited')
        eq(s.alerts.openCount(), 1, 'the second not acknowledged')
    end)

    it('scrubs the text for staff without IdentityAce, and shows it whole to those with it', function()
        local s, f = stack()
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } }, anonymous = true })
        truthy(c, 'an anonymous contract')
        local oxmysql = 'crimson-hitman was unable to execute a query!\nQuery: UPDATE crimson_contracts '
            .. 'SET reason = ? WHERE id = ?\n["Vic Marlowe owes","' .. c.id .. '","CREATOR1"]\n'
            .. 'Deadlock found when trying to get lock'
        Log.always(('contract %s: crediting CREATOR1 (Vic Marlowe, license:aaa) raised: %s')
            :format(c.id, oxmysql))
        local seen = ask(6, 'alerts', {}).data.rows[1].text
        for _, needle in ipairs({ 'CREATOR1', 'Vic Marlowe', 'license:aaa', 'owes' }) do
            falsy(seen:find(needle, 1, true), needle .. ' reaches staff without crimson.identity: ' .. seen)
        end
        truthy(seen:find('the client', 1, true), 'the party by their place: ' .. seen)
        truthy(seen:find('Anonymous', 1, true), 'the anonymous name as Anonymous: ' .. seen)
        truthy(seen:find('Deadlock found', 1, true), 'the server\'s words kept: ' .. seen)
        truthy(seen:find(c.id, 1, true), 'and the contract: ' .. seen)
        local whole = ask(8, 'alerts', {}).data.rows[1].text
        truthy(whole:find('CREATOR1', 1, true) and whole:find('Vic Marlowe', 1, true),
            'crimson.identity reads it whole: ' .. whole)
        falsy(whole:find('owes', 1, true), 'but never the statement\'s values, which are not kept')
    end)

    it('puts a staff command as the panel\'s own place for it', function()
        local s = stack()
        Log.always(('left for staff: review rv1 on contract ct00000001; see /%s')
            :format(Config.Admin.Commands.stuck))
        local text = ask(7, 'alerts', {}).data.rows[1].text
        falsy(text:find('/' .. Config.Admin.Commands.stuck, 1, true), text)
        truthy(#s.alerts.list('open', 1) == 1)
    end)
end)

--------------------------------------------------------------------------
-- Discord
--------------------------------------------------------------------------

describe('posting to Discord', function()
    it('posts nothing without a webhook, and nothing on the path that printed the line', function()
        local s = stack()
        Log.always('a line with no webhook set')
        Env.advance(30)
        eq(#Natives.calls.http, 0)
        eq(ask(6, 'alerts', {}).data.discord.webhook, nil, 'the panel says none is set')
        Natives.convars.crimson_hitman_alert_webhook = HOOK_ALERT
        Log.always('a line with one set')
        eq(#Natives.calls.http, 0, 'not from inside Log.always: a timer of its own posts it')
        Env.advance(1)
        eq(#Natives.calls.http, 1)
        eq(Natives.calls.http[1].url, HOOK_ALERT)
        truthy(s.alerts.discordState().posted >= 1)
    end)

    it('uses the staff webhook when no alert webhook is set, and says which', function()
        local s = stack()
        Natives.convars.crimson_hitman_webhook = HOOK_STAFF
        Log.always('a line for the staff channel')
        Env.advance(1)
        eq(Natives.calls.http[1].url, HOOK_STAFF)
        eq(ask(6, 'alerts', {}).data.discord.webhook, 'staff')
        Natives.convars.crimson_hitman_alert_webhook = HOOK_ALERT
        eq(s.alerts.discordState().webhook, 'alert')
    end)

    it('posts once every 10 seconds at most, merging what came in between', function()
        stack()
        Natives.convars.crimson_hitman_alert_webhook = HOOK_ALERT
        Log.always('first alert')
        Env.advance(1)
        eq(#Natives.calls.http, 1)
        Log.always('second alert')
        Log.always('third alert')
        Log.always('second alert')
        Env.advance(5)
        eq(#Natives.calls.http, 1, 'not within ten seconds of the last post')
        Env.advance(5)
        eq(#Natives.calls.http, 2, 'one post for all three')
        local body = bodies()[2]
        truthy(body:find('second alert (x2)', 1, true), 'the same one counted: ' .. body)
        truthy(body:find('third alert', 1, true), body)
        truthy(body:find('2 alert(s)', 1, true), body)
    end)

    it('carries ten alerts a post at most, saying how many more', function()
        stack()
        Natives.convars.crimson_hitman_alert_webhook = HOOK_ALERT
        for i = 1, 13 do Log.always('distinct alert ' .. ('v'):rep(i)) end
        Env.advance(1)
        eq(#Natives.calls.http, 1)
        local body = bodies()[1]
        local lines = select(2, body:gsub('distinct alert', ''))
        eq(lines, 10)
        truthy(body:find('and 3 more', 1, true), body)
        Env.advance(60)
        eq(#Natives.calls.http, 1, 'the three more are counted, not posted after')
    end)

    it('keeps a post under Discord\'s limit, counting what does not fit among the more', function()
        stack()
        Natives.convars.crimson_hitman_alert_webhook = HOOK_ALERT
        for i = 1, 10 do Log.always(('a long alert %s %s'):format(('u'):rep(i), ('word '):rep(80))) end
        Env.advance(1)
        local content = json.decode(bodies()[1]).content
        truthy(#content < 2000, #content .. ' characters')
        local shown = select(2, content:gsub('a long alert', ''))
        truthy(shown < 10, shown .. ' shown')
        truthy(content:find(('and %d more'):format(10 - shown), 1, true), content)
    end)

    it('says a test that could not be posted was the test, not an alert', function()
        local s = stack()
        Natives.convars.crimson_hitman_alert_webhook = HOOK_ALERT
        Natives.httpAnswer = function() return 404, '', {} end
        eq(ask(6, 'testAlert', {}).ok, true)
        Env.advance(40)
        eq(#Natives.calls.http, 3)
        local fail = s.alerts.discordState().lastFail
        eq(fail.test, true)
        eq(fail.alerts, 0, 'no alert of its own lost')
    end)

    it('tries again with a longer wait each time, and gives up after three tries', function()
        local s = stack()
        Natives.convars.crimson_hitman_alert_webhook = HOOK_ALERT
        Natives.httpAnswer = function() return 500, '', {} end
        Log.always('an alert Discord will not take')
        Env.advance(1)
        eq(#Natives.calls.http, 1, 'the first try')
        Env.advance(8)
        eq(#Natives.calls.http, 1, 'not again within ten seconds')
        Env.advance(2)
        eq(#Natives.calls.http, 2, 'the second, ten seconds on')
        Env.advance(15)
        eq(#Natives.calls.http, 2, 'the third waits twenty')
        Env.advance(5)
        eq(#Natives.calls.http, 3, 'the third')
        Env.advance(120)
        eq(#Natives.calls.http, 3, 'given up')
        local fail = ask(6, 'alerts', {}).data.discord.lastFail
        truthy(fail, 'the panel says so')
        eq(fail.tries, 3)
        eq(fail.status, 500)
        eq(fail.alerts, 1)
        eq(s.alerts.discordState().lastFail.tries, 3)
    end)

    it('waits as long as Discord asks after a 429', function()
        stack()
        Natives.convars.crimson_hitman_alert_webhook = HOOK_ALERT
        local answers = { 429, 204 }
        Natives.httpAnswer = function() return table.remove(answers, 1), '', { ['Retry-After'] = '30' } end
        Log.always('an alert sent too fast')
        Env.advance(1)
        Env.advance(20)
        eq(#Natives.calls.http, 1, 'not before the thirty seconds it asked for')
        Env.advance(10)
        eq(#Natives.calls.http, 2)
    end)

    it('posts nothing with Alerts.ToDiscord off, and drops what was waiting', function()
        local s = stack()
        Natives.convars.crimson_hitman_alert_webhook = HOOK_ALERT
        Log.always('posted')
        Env.advance(1)
        Log.always('waiting when it was switched off')
        eq(s.settings.set('Alerts.ToDiscord', false, 'ADMIN001', 'ADMIN001'), true)
        Log.always('said while it is off')
        Env.advance(60)
        eq(#Natives.calls.http, 1, 'only the first')
        truthy(find(open(s), 'said while it is off'), 'the panel still lists every one')
    end)

    it('never sends an identity or an address, and the panel never shows the webhook', function()
        local s, f = stack()
        Natives.convars.crimson_hitman_alert_webhook = HOOK_ALERT
        Natives.convars.crimson_hitman_webhook = HOOK_STAFF
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        truthy(c, 'a contract, not anonymous')
        Log.always(('contract %s: Dana Reyes (TARGET01, license:bbb) paid Vic Marlowe; see '
            .. 'https://cdn.example/photo.png @everyone'):format(c.id))
        s.review.open({ kind = 'bailout_refund_stranded', contract_id = c.id,
            cids = { payer = 'TARGET01', creator = 'CREATOR1' }, amount = 500, account = 'bank',
            known = {} })
        Env.advance(1)
        eq(#Natives.calls.http, 1)
        local body = bodies()[1]
        for _, needle in ipairs({ 'TARGET01', 'CREATOR1', 'license:bbb', 'Dana Reyes', 'Vic Marlowe',
                                  'http', '@everyone' }) do
            falsy(body:find(needle, 1, true), needle .. ' left the server: ' .. body)
        end
        truthy(body:find('the target', 1, true) and body:find('the client', 1, true), body)

        local reply = ask(8, 'alerts', {})
        for _, text in ipairs(strings(reply)) do
            falsy(text:find('discord.example', 1, true), 'a webhook reached the panel: ' .. text)
        end
        eq(reply.data.discord.webhook, 'alert')
    end)

    it('sends nothing of a line whose contract cannot be read, so whose names are not known', function()
        local s = stack()
        Natives.convars.crimson_hitman_alert_webhook = HOOK_ALERT
        Log.always('escrow line ct00000404:1 belongs to contract ct00000404, which was never stored; '
            .. 'Vic Marlowe put it up')
        Env.advance(1)
        local body = bodies()[1]
        falsy(body:find('Vic Marlowe', 1, true), body)
        truthy(body:find('not shown here; see the admin panel', 1, true), body)
        truthy(find(open(s), 'Vic Marlowe'), 'the panel keeps the line whole')
    end)

    it('sends a test alert as a staff write, on the record', function()
        local s = stack()
        local off = ask(6, 'testAlert', {})
        eq(off.ok, false)
        eq(off.err, 'no_webhook')
        truthy(off.message:find('crimson_hitman_alert_webhook', 1, true), off.message)
        eq(ask(7, 'testAlert', {}).err, 'not_allowed', 'an extra ACE only reads')
        Natives.convars.crimson_hitman_alert_webhook = HOOK_ALERT
        local sent = ask(6, 'testAlert', {})
        eq(sent.ok, true, tostring(sent.message))
        Env.advance(1)
        eq(#Natives.calls.http, 1)
        truthy(bodies()[1]:find('test alert', 1, true), bodies()[1])
        withConfig({ { Config.Alerts, 'ToDiscord', false } }, function()
            eq(ask(6, 'testAlert', {}).err, 'discord_off')
        end)
        s.audit.flush()
        eq(#s.storage.auditByAction('admin_alert_test'), 3, 'each one on the record, sent or not')
        eq(s.alerts.openCount(), 0, 'and no alert of its own in the list')
    end)
end)
