--- The admin panel's requests (server/panel.lua), driven through the real
--- net event, crimson-hitman:admin, as the page's client sends them.
---
--- What these hold the panel to is the order every request goes through:
--- the engine's source, the ACE again on every request, a rate limit per
--- staff member, every field checked, then the same functions and the same
--- words as the commands, audited and flushed. And that nobody without
--- crimson.identity is ever shown who is behind an anonymous party, or any
--- citizen id at all.

local Exec = require('crimson-hitman.tests.harness.mysql_exec')

local READS = { 'access', 'overview', 'contracts', 'contract', 'reviews', 'logs', 'player',
                'settings', 'diag' }
local WRITES = { 'void', 'settle', 'resolve', 'setSetting', 'resetSetting', 'resetSettings',
                 'refresh', 'flush' }
local ALL = {}
for _, op in ipairs(READS) do ALL[#ALL + 1] = op end
for _, op in ipairs(WRITES) do ALL[#ALL + 1] = op end
ALL[#ALL + 1] = 'whois'

--- A stack with the usual three players and three staff: one with
--- crimson.admin, one with only an extra ACE (reads), one with both
--- crimson.admin and crimson.identity.
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
    -- Generous, so a test about something else is not stopped by the limit.
    Config.Cooldowns.admin = { per = 10, burst = 500 }
    Config.Cooldowns.adminWrite = { per = 10, burst = 500 }
    s.bridges.install(s)
    return s, f
end

--- Send one request as the page's client does, and hand back the reply.
local function ask(src, op, data, payload)
    Env.clientEvents = {}
    _G.source = src
    local fired, err = pcall(Env.events['crimson-hitman:admin'],
        payload or { op = op, data = data or {}, __rid = 41 })
    _G.source = nil
    truthy(fired, 'the net event must not raise: ' .. tostring(err))
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:adminResult' then
            eq(event.target, src, 'answered to whoever asked, and nobody else')
            return event.args[1]
        end
    end
    return nil
end

--- Every string anywhere in a value, keys included.
local function strings(value, out)
    out = out or {}
    if type(value) == 'string' then
        out[#out + 1] = value
    elseif type(value) == 'table' then
        for k, v in pairs(value) do
            strings(k, out)
            strings(v, out)
        end
    end
    return out
end

local function mentions(value, needle)
    for _, text in ipairs(strings(value)) do
        if text:find(needle, 1, true) then return true end
    end
    return false
end

--- Audit rows with one action, in the store (written, not queued).
local function stored(s, action)
    return s.storage.auditByAction(action, 100) or {}
end

local function money(src)
    local m = Env.players[src].PlayerData.money
    return m.cash + m.bank
end

local function place(s, f, opts)
    opts = opts or {}
    local c = s.contracts.create(f.creator, {
        targetCid = opts.target or 'TARGET01', reason = opts.reason or 'Unpaid debt',
        mode = opts.mode or CH.MODE.COMPETITIVE,
        reward = opts.reward or { baseline = { cash = 5000 } },
        anonymous = opts.anonymous,
    })
    truthy(c, 'a contract to look at')
    if opts.accept then truthy(s.contracts.accept(f.hitman, c.id, opts.anonHitman == true)) end
    return c
end

--------------------------------------------------------------------------
-- Opening it
--------------------------------------------------------------------------

describe('opening the admin panel', function()
    it('is /hitmanadmin, and the timer refresh is /ch-refresh', function()
        stack()
        eq(Config.Admin.Commands.panel, 'hitmanadmin')
        eq(Config.Admin.Commands.refresh, 'ch-refresh')
        truthy(Env.commands['hitmanadmin'], 'the panel command')
        truthy(Env.commands['ch-refresh'], 'the timer refresh, under its new name')
    end)

    it('opens for staff and tells the page what they may do', function()
        local s = stack()
        Env.clientEvents = {}
        Env.commands['hitmanadmin'](6, {})
        local opened
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:adminOpen' then opened = event end
        end
        truthy(opened, 'the page is told to open')
        eq(opened.target, 6, 'on the staff member\'s own screen')
        eq(opened.args[1].canWrite, true)
        eq(opened.args[1].canIdentify, false)
        eq(opened.args[1].commands, nil, 'and no command names: the page is buttons only')
        eq(opened.args[1].refreshSeconds, 10)
        s.audit.flush()
        eq(#stored(s, 'admin_panel_opened'), 1, 'and it is on the record')
    end)

    it('opens to read only for an extra ACE', function()
        stack()
        Env.clientEvents = {}
        Env.commands['hitmanadmin'](7, {})
        local opened
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:adminOpen' then opened = event.args[1] end
        end
        truthy(opened)
        eq(opened.canWrite, false, 'the extra ACEs read, never write')
    end)

    it('does not open for a player with no ACE, and says how to grant it', function()
        stack()
        Env.clientEvents, Env.chat = {}, {}
        Env.commands['hitmanadmin'](3, {})
        for _, event in ipairs(Env.clientEvents) do
            falsy(event.name == 'crimson-hitman:adminOpen', 'nothing opens')
        end
        local said = false
        for _, line in ipairs(Env.chat) do
            if line.target == 3 and line.text:find('Not authorised', 1, true) then said = true end
        end
        truthy(said, 'told why, and what to grant')
    end)

    it('says at the console that the page opens in game', function()
        stack()
        local printed = {}
        local real = _G.print
        _G.print = function(line) printed[#printed + 1] = tostring(line) end
        local ok, err = pcall(Env.commands['hitmanadmin'], 0, {})
        _G.print = real
        truthy(ok, tostring(err))
        truthy(table.concat(printed, '\n'):find('opens in game', 1, true), table.concat(printed, '\n'))
    end)

    it('moves a timer refresh an older config left on /hitmanadmin to /ch-refresh', function()
        newStack()
        local main = require('crimson-hitman.server.main')
        Config.Admin.Commands.refresh = 'hitmanadmin'
        local ok, fatal, warn = main.validateConfig(true)
        local moved = Config.Admin.Commands.refresh
        resetConfig()
        truthy(ok, table.concat(fatal or {}, '; '))
        eq(moved, 'ch-refresh', 'the panel keeps the name')
        truthy(table.concat(warn, '\n'):find('ch-refresh', 1, true), 'and the start says so')
    end)
end)

--------------------------------------------------------------------------
-- Who may ask for what
--------------------------------------------------------------------------

describe('who may ask the admin panel for what', function()
    it('refuses every request from a player with no ACE, and sends nothing with it', function()
        stack()
        for _, op in ipairs(ALL) do
            local reply = ask(3, op, {})
            truthy(reply, op .. ' is answered')
            eq(reply.ok, false, op)
            eq(reply.err, 'not_allowed', op)
            eq(reply.data, nil, op .. ' carries nothing')
            eq(reply.rid, 41, op .. ' answers the request it was asked')
        end
    end)

    it('answers every read to an extra ACE, and refuses it every write', function()
        stack()
        for _, op in ipairs(READS) do
            local reply = ask(7, op, {})
            falsy(reply.err == 'not_allowed', op .. ' is a read')
        end
        for _, op in ipairs(WRITES) do
            eq(ask(7, op, {}).err, 'not_allowed', op .. ' writes, and needs crimson.admin itself')
        end
    end)

    it('lets crimson.admin write, and not unmask', function()
        local s, f = stack()
        local c = place(s, f, { anonymous = true })
        local reply = ask(6, 'setSetting', { key = 'Relay.Enabled', value = false })
        eq(reply.ok, true, tostring(reply.message))
        eq(ask(6, 'whois', { id = c.id }).err, 'identity_required')
        local who = ask(8, 'whois', { id = c.id })
        eq(who.ok, true)
        eq(who.data.creator.cid, 'CREATOR1', 'crimson.identity sees who placed it')
    end)

    it('checks the ACE again on every request, not only when it opened', function()
        stack()
        eq(ask(6, 'overview').ok, true)
        Env.aces[6] = nil
        eq(ask(6, 'overview').err, 'not_allowed', 'a revoked ACE closes it at the next request')
    end)

    it('answers a request with no op, or no table, and never the console source', function()
        local s = stack()
        eq(ask(6, nil, nil, { data = {}, __rid = 2 }).err, 'unknown_op')
        eq(ask(6, nil, nil, 'not a table').err, 'unknown_op')
        eq(ask(6, 'dropTables', {}).err, 'unknown_op')
        eq(ask(3, 'dropTables', {}).err, 'not_allowed', 'and to nobody else does it say which ops exist')
        eq(s.panel.handle(0, { op = 'overview' }), nil, 'the console has no page to answer')
    end)

    it('is closed with the staff tools', function()
        stack()
        Config.Admin.Enabled = false
        eq(ask(6, 'overview').err, 'admin_off')
    end)

    it('never raises on whatever a client sends', function()
        local s, f = stack()
        place(s, f)
        local junk = {
            {}, { id = {}, line = 5, key = string.rep('k', 500), value = { 1, 2 } },
            { id = 'ct' .. string.rep('9', 60), subject = -1, cursor = 'x', amount = 1e308 },
            { query = string.rep('%', 80), state = 7, from = 'yesterday', page = -4, all = 'yes' },
            { disposition = 'pay', amount = -1, owner = '../../etc', action = 'refund', who = {} },
        }
        for _, op in ipairs(ALL) do
            for _, data in ipairs(junk) do
                local reply = ask(8, op, data)
                truthy(reply, op .. ' answers')
                falsy(reply.err == CH.ERR.SERVER_ERROR, op .. ' raised: ' .. tostring(reply.message))
            end
        end
    end)
end)

--------------------------------------------------------------------------
-- The rate limit
--------------------------------------------------------------------------

describe('the admin panel rate limit', function()
    it('refuses past the allowance, per staff member, and says how long', function()
        stack()
        Config.Cooldowns.admin = { per = 10, burst = 3 }
        for i = 1, 3 do eq(ask(6, 'access').ok, true, 'request ' .. i) end
        local refused = ask(6, 'access')
        eq(refused.err, CH.ERR.RATE_LIMITED)
        truthy((refused.data.retryAfter or 0) > 0, 'with how long to wait')
        eq(ask(8, 'access').ok, true, 'another staff member has an allowance of their own')
        Env.gameTimer = Env.gameTimer + 10000
        eq(ask(6, 'access').ok, true, 'and it comes back')
    end)

    it('holds writes to an allowance of their own', function()
        stack()
        Config.Cooldowns.adminWrite = { per = 10, burst = 2 }
        eq(ask(6, 'flush').ok, true)
        eq(ask(6, 'flush').ok, true)
        eq(ask(6, 'flush').err, CH.ERR.RATE_LIMITED, 'the third write')
        eq(ask(6, 'overview').ok, true, 'reads go on')
    end)
end)

--- "Flush the audit log" kept whether the flush raised, not what it
--- answered. The json store's flush answers false and never raises, so
--- "the store did not save" could never be said: staff pressing it before a
--- restart were told the rows were written while nothing reached the disk.
describe('flushing the audit log on a store that cannot write', function()
    it('json: says the store did not save, and names the file', function()
        for name in pairs(package.loaded) do
            if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
                package.loaded[name] = nil
            end
        end
        Env.reset()
        Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
        Natives.resetResourceStates()
        resetConfig()
        Config.Database.Mode = 'json'
        Natives.files, Natives.blocked = {}, {}
        local s = require('server.main').start()
        fixture(s)
        Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
            firstname = 'Sam', lastname = 'Steward' })
        Env.aces[6] = { ['crimson.admin'] = true }
        Config.Cooldowns.adminWrite = { per = 10, burst = 500 }

        local fine = ask(6, 'flush')
        eq(fine.ok, true)
        falsy(tostring(fine.message):find('did not save', 1, true), tostring(fine.message))

        Natives.blocked = { ['data/store.json'] = true }
        s.storage.nextId('zz')
        local refused = ask(6, 'flush')
        Natives.blocked = {}
        eq(refused.ok, true, 'the rows were handed to the store')
        truthy(tostring(refused.message):find('but the store did not save', 1, true),
            tostring(refused.message))
        truthy(tostring(refused.message):find('data/store.json could not be written', 1, true),
            tostring(refused.message))
    end)
end)

--------------------------------------------------------------------------
-- Recovery
--------------------------------------------------------------------------

describe('admin panel writes while the server recovers', function()
    local GATED = { 'void', 'settle', 'resolve', 'setSetting', 'resetSetting', 'resetSettings',
                    'refresh' }

    it('refuses every write while recovery runs, in the commands\' words', function()
        local s, f = stack()
        local c = place(s, f)
        s.app.ready = false
        for _, op in ipairs(GATED) do
            local reply = ask(6, op, { id = c.id, key = 'Relay.Enabled', value = false })
            eq(reply.err, 'recovering', op)
            eq(reply.message, s.admin.RECOVERING, op)
        end
        eq(s.storage.readContract(c.id).state, CH.STATE.ACTIVE, 'nothing was voided')
        eq(Config.Relay.Enabled, true, 'nothing was changed')
        local overview = ask(6, 'overview')
        eq(overview.ok, true, 'the overview still reads')
        eq(overview.data.recovery, 'recovering')
        eq(overview.data.stuck, nil, 'and lists nothing as stuck that recovery is deciding')
        eq(ask(6, 'flush').ok, true, 'flushing the log moves nothing, and is allowed')
    end)

    it('and after recovery failed, says so and what to do', function()
        local s = stack()
        s.app.ready, s.app.recoveryFailed = false, true
        for _, op in ipairs(GATED) do
            local reply = ask(6, op, {})
            eq(reply.err, 'recovery_failed', op)
            eq(reply.message, s.admin.RECOVERY_FAILED, op)
        end
    end)

    --- W132: the refresh itself waits too, so the button and the command
    --- (bridges' /ch-refresh, which has no gate of its own) cannot drift.
    it('has the refresh refuse by itself, in the same words, with nothing moved', function()
        local s, f = stack()
        local c = place(s, f)
        local deadline = s.storage.readContract(c.id).deadline_at
        Env.advance(600)
        for _, case in ipairs({ { false, 'recovering', s.admin.RECOVERING },
                                { true, 'recovery_failed', s.admin.RECOVERY_FAILED } }) do
            s.app.ready, s.app.recoveryFailed = false, case[1]
            local lines, err = s.admin.refreshTimers(6)
            eq(err, case[2])
            eq(#lines, 1)
            eq(lines[1], case[3])
        end
        eq(s.storage.readContract(c.id).deadline_at, deadline, 'nothing was refreshed')
    end)
end)

--------------------------------------------------------------------------
-- The overview
--------------------------------------------------------------------------

describe('the admin panel overview', function()
    it('counts contracts, operatives, money held and what waits for staff', function()
        local s, f = stack()
        place(s, f, { accept = true })
        place(s, f, { target = 'HITMAN01', reward = { baseline = { bank = 3000 } } })
        local data = ask(6, 'overview').data
        eq(data.contracts.total, 2)
        eq(data.contracts.byState.accepted, 1)
        eq(data.contracts.byState.active, 1)
        eq(data.hitmen.active, 1)
        eq(data.held.cash, 5000, 'held in escrow, by account')
        eq(data.held.bank, 3000)
        eq(data.owed.lines, 0)
        eq(data.reviews.open, 0)
        eq(data.storage, Config.Database.Mode)
        eq(data.fulfilment, Config.Completion.Fulfilment)
        eq(data.recovery, 'ready')
        eq(data.stuck.total, 0)
        eq(type(data.warnings), 'table')
        eq(type(data.slowest), 'table')
    end)

    it('shows a review item, and the diagnosis warning that goes with it', function()
        local s = stack()
        s.review.open({ kind = 'bailout_refund_stranded', contract_id = 'ct00000001',
            cids = { payer = 'TARGET01' }, amount = 5000, account = 'bank' })
        local data = ask(6, 'overview').data
        eq(data.reviews.open, 1)
        truthy(mentions(data.warnings, 'REVIEW QUEUE'), table.concat(data.warnings, ' | '))
    end)

    it('is shared for a few seconds, and read again after a write', function()
        local s, f = stack()
        eq(ask(6, 'overview').data.contracts.total, 0)
        place(s, f)
        eq(ask(6, 'overview').data.contracts.total, 0, 'a refresh inside the window is the same read')
        eq(ask(6, 'flush').ok, true)
        eq(ask(6, 'overview').data.contracts.total, 1, 'a write makes the next one fresh')
    end)

    it('counts as left for staff every line something settles by hand, and only those', function()
        local s = stack()
        local real = s.admin.interrupted
        s.admin.interrupted = function()
            return {
                { line = 'l1', contract = 'ct00000001', raised = 3, why = 'raised', portion = 'baseline' },
                { line = 'l2', contract = 'ct00000001', settles = 'pay_or_return', portion = 'baseline' },
                { line = 'l3', contract = 'ct00000009', orphan = true },
                { line = 'l4', contract = 'ct00000001', settles = 'queued', portion = 'baseline' },
                { line = 'l5', contract = 'ct00000002', why = 'ending_unfinished', unfinished = true },
            }
        end
        local stuck = ask(6, 'overview').data.stuck
        s.admin.interrupted = real
        eq(stuck.total, 5, 'every line /ch-stuck lists')
        eq(stuck.leftForStaff, 3, 'a parked line, one a shutdown caught, and an orphan are staff\'s; '
            .. 'one queued since and an ending finishing itself are nobody\'s')
    end)
end)

--------------------------------------------------------------------------
-- Contracts
--------------------------------------------------------------------------

describe('contracts in the admin panel', function()
    it('finds one by id, by name and by citizen id, newest first and a page at a time', function()
        local s, f = stack()
        Config.Admin.PanelPageSize = 5
        local first = place(s, f)
        for i = 1, 6 do
            Env.time = Env.time + 60
            Env.addPlayer({ source = 20 + i, citizenid = 'MARK000' .. i, license = 'license:m' .. i,
                firstname = 'Mark', lastname = 'Number' .. i })
            Config.Limits.MaxActiveContractsPerCreator = 10
            place(s, f, { target = 'MARK000' .. i })
        end
        local all = ask(6, 'contracts', {}).data
        eq(all.total, 7)
        eq(all.pages, 2)
        eq(#all.rows, 5)
        local second = ask(6, 'contracts', { page = 2 }).data
        eq(#second.rows, 2)
        eq(second.rows[#second.rows].id, first.id, 'the oldest last')

        eq(ask(6, 'contracts', { query = first.id }).data.total, 1, 'by id')
        eq(ask(6, 'contracts', { query = 'number3' }).data.total, 1, 'by part of a name')
        eq(ask(6, 'contracts', { query = 'MARK0004' }).data.total, 1, 'by citizen id')
        eq(ask(6, 'contracts', { state = 'expired' }).data.total, 0, 'by state')
        eq(ask(6, 'contracts', { rule = Config.Completion.Fulfilment }).data.total, 7, 'by rule')
        s.audit.flush()
        truthy(#stored(s, 'admin_panel_search') > 0, 'a search by a person is on the record')
    end)

    it('does not find an anonymous client by who they are, without crimson.identity', function()
        local s, f = stack()
        place(s, f, { anonymous = true })
        eq(ask(6, 'contracts', { query = 'CREATOR1' }).data.total, 0, 'not by citizen id')
        eq(ask(6, 'contracts', { query = 'Marlowe' }).data.total, 0, 'not by name')
        local rows = ask(6, 'contracts', {}).data.rows
        eq(rows[1].client, 'Anonymous')
        eq(ask(8, 'contracts', { query = 'CREATOR1' }).data.total, 1, 'with it, found')
        eq(ask(8, 'contracts', {}).data.rows[1].client, 'Vic Marlowe')
    end)

    it('shows a contract whole, and nobody behind an anonymous party', function()
        local s, f = stack()
        local c = place(s, f, { anonymous = true, accept = true, anonHitman = true })
        local reply = ask(6, 'contract', { id = c.id })
        eq(reply.ok, true, tostring(reply.message))
        local data = reply.data
        eq(data.contract.id, c.id)
        eq(data.contract.client.name, 'Anonymous')
        eq(data.contract.client.cid, nil)
        eq(#data.escrow, 1)
        eq(data.escrow[1].amount, 5000)
        eq(#data.hitmen, 1)
        eq(data.hitmen[1].name, 'Anonymous')
        truthy(#data.timeline > 0, 'with its history')
        eq(data.canVoid, true)
        for _, cid in ipairs({ 'CREATOR1', 'HITMAN01', 'TARGET01' }) do
            falsy(mentions(data, cid), cid .. ' must not reach staff without crimson.identity')
        end
        falsy(mentions(data, 'Vic Marlowe'), 'nor the anonymous client\'s name')
        falsy(mentions(data, 'Rook Ash'), 'nor the anonymous hitman\'s')

        local seen = ask(8, 'contract', { id = c.id }).data
        eq(seen.contract.client.cid, 'CREATOR1', 'crimson.identity sees who')
        eq(seen.hitmen[1].name, 'Rook Ash')
        s.audit.flush()
        eq(#stored(s, 'admin_panel_contract'), 1)
        eq(#stored(s, 'admin_panel_contract_identified'), 1, 'and the unmasking is its own row')
    end)

    it('reads every contract once for a few seconds, between the overview and the searches', function()
        local s, f = stack()
        place(s, f)
        -- Counted inside the panel's reads only: a store write is followed
        -- by reads of its own where an invariant monitor wraps the store.
        local real, reads, counting = s.storage.allContracts, 0, false
        s.storage.allContracts = function(...)
            if counting then reads = reads + 1 end
            return real(...)
        end
        local function read(op, data)
            counting = true
            local reply = ask(6, op, data)
            counting = false
            return reply
        end
        read('overview')
        for _, query in ipairs({ 'D', 'Da', 'Dana', 'Dana R' }) do read('contracts', { query = query }) end
        read('contracts', { state = 'active' })
        eq(reads, 1, 'one read of the whole table for the overview and five searches')
        place(s, f, { target = 'HITMAN01' })
        eq(read('contracts', {}).data.total, 1, 'a contract placed meanwhile shows a few seconds later')
        Env.time = Env.time + 5
        eq(read('contracts', {}).data.total, 2, 'and does then')
        eq(reads, 2)
        eq(ask(6, 'flush').ok, true)
        read('contracts', {})
        eq(reads, 3, 'a write reads it afresh')
        s.storage.allContracts = real
    end)

    it('finds a citizen id typed in lower case', function()
        local s, f = stack()
        place(s, f)
        eq(ask(6, 'contracts', { query = 'target01' }).data.total, 1, 'qbx ids are capitals and digits')
        eq(ask(6, 'contracts', { query = 'TaRgEt01' }).data.total, 1)
    end)

    it('offers no return for a stuck line owed to somebody, which only a pay settles', function()
        local s, f = stack()
        local c = place(s, f)
        local real = s.admin.interrupted
        s.admin.interrupted = function()
            return {
                { line = c.id .. ':8', contract = c.id, raised = 3, why = 'raised', portion = 'owed' },
                { line = c.id .. ':9', contract = c.id, settles = 'pay_or_return', portion = 'owed' },
                { line = c.id .. ':7', contract = c.id, raised = 3, why = 'raised', portion = 'baseline' },
            }
        end
        local stuck = ask(6, 'contract', { id = c.id }).data.stuck
        s.admin.interrupted = real
        eq(table.concat(stuck[1].actions, ','), 'pay,pay_amount,delivered')
        eq(table.concat(stuck[2].actions, ','), 'pay')
        eq(table.concat(stuck[3].actions, ','), 'pay,pay_amount,return,delivered', 'a payout still can')
    end)

    it('voids a contract in the words /ch-void uses, on the record at once', function()
        local s, f = stack()
        local c = place(s, f)
        local before = money(1)
        local reply = ask(6, 'void', { id = c.id, reason = 'test server cleanup' })
        eq(reply.ok, true)
        eq(reply.message, s.admin.voidAnswer(c.id, true, nil))
        eq(s.storage.readContract(c.id).state, CH.STATE.VOIDED)
        eq(money(1) - before, 5000, 'the client has their escrow back')
        eq(#stored(s, 'admin_void'), 1, 'written to the store without waiting for the tick')
        local again = ask(6, 'void', { id = c.id })
        eq(again.ok, false)
        eq(again.message, s.admin.voidAnswer(c.id, false, again.err))
    end)

    it('settles a stuck line from the contract view, as /ch-settle would', function()
        local s, f = stack()
        local c = place(s, f, { accept = true })
        local line = s.storage.readEscrow(c.id)[1]
        local p = Env.players[3]
        local real = p.Functions.AddMoney
        p.Functions.AddMoney = function() error('AddMoney hook raised', 0) end
        for _ = 1, s.escrow.DELIVER_RAISE_LIMIT do
            pcall(s.escrow.release, c.id, 'HITMAN01', { line = line.id }, 'test')
        end
        p.Functions.AddMoney = real
        truthy(s.escrow.parked(s.storage.readEscrowLine(line.id)), 'left for staff')

        local view = ask(6, 'contract', { id = c.id }).data
        eq(#view.stuck, 1, 'listed with its contract')
        eq(view.stuck[1].line, line.id)
        local actions = table.concat(view.stuck[1].actions, ',')
        truthy(actions:find('delivered', 1, true) and actions:find('pay_amount', 1, true), actions)

        local before = money(3)
        local reply = ask(6, 'settle', { line = line.id, disposition = 'delivered' })
        eq(reply.ok, true, tostring(reply.message))
        eq(reply.message, 'Line settled.')
        eq(money(3), before, 'delivered gives nothing')
        eq(s.storage.readEscrowLine(line.id).state, CH.ESCROW_STATE.SETTLED)
        eq(ask(6, 'settle', { line = line.id, disposition = 'pay' }).message,
            s.admin.settleAnswer(false, CH.ERR.ALREADY_SETTLED), 'and once only')
        eq(ask(6, 'settle', { line = line.id, disposition = 'pay', amount = 0 }).err,
            CH.ERR.INVALID_INPUT, 'an amount is at least 1')
    end)
end)

--------------------------------------------------------------------------
-- The review queue
--------------------------------------------------------------------------

describe('the review queue in the admin panel', function()
    it('resolves an item once, however often it is asked', function()
        local s = stack()
        local id = s.review.open({ kind = 'bailout_refund_stranded', contract_id = 'ct00000001',
            cids = { payer = 'TARGET01' }, amount = 5000, account = 'bank' })
        local listed = ask(6, 'reviews', {}).data.items
        eq(#listed, 1)
        eq(listed[1].parties[1].who, '(a player)', 'a role, to staff who may not see who')

        local before = money(2)
        local first = ask(6, 'resolve', { id = id, action = 'refund', who = 'payer', amount = 5000 })
        eq(first.ok, true, tostring(first.message))
        -- The command's answer, in the panel's words: it names the panel's
        -- sections, never a command.
        eq(first.message, s.admin.reviewAnswer(id, true, nil, first.data.detail, true))
        falsy(first.message:find('/' .. Config.Admin.Commands.stuck, 1, true), first.message)
        local second = ask(6, 'resolve', { id = id, action = 'refund', who = 'payer', amount = 5000 })
        eq(second.ok, false)
        eq(second.message, 'Already resolved; nothing was given again.')
        eq(money(2) - before, 5000, 'given once')
        eq(ask(6, 'reviews', { all = true }).data.items[1].state, 'resolved')
    end)

    it('never shows who an anonymous party is through a resolved item, nor a weapon\'s owner', function()
        local s, f = stack()
        local c = place(s, f, { anonymous = true })
        local pistol = { source = 'weapon', item = 'WEAPON_PISTOL', quantity = 1,
                         metadata = { registered = 'Vic Marlowe', serial = 'SER0042' } }
        local fee = s.review.open({ kind = 'anonymity_fee_refund_failed', contract_id = c.id,
            cids = { payer = 'CREATOR1' }, amount = 500, account = 'bank', items = { pistol },
            known = { error = 'credit to CREATOR1 raised' } })
        local goods = s.review.open({ kind = 'escrow_take_raised', contract_id = c.id,
            cids = { from = 'CREATOR1' }, items = { pistol } })
        -- Resolved by somebody who may see who it is, and by a role.
        eq(ask(8, 'resolve', { id = fee, action = 'refund', who = 'payer', amount = 500 }).ok, true)
        ask(8, 'resolve', { id = goods, action = 'refund', who = 'from', goods = true })

        for _, src in ipairs({ 6, 7 }) do
            local items = ask(src, 'reviews', { all = true }).data.items
            eq(#items, 2, 'source ' .. src)
            falsy(mentions(items, 'CREATOR1'), 'no citizen id reaches source ' .. src)
            falsy(mentions(items, 'Vic Marlowe'), 'nor the weapon owner\'s name, to source ' .. src)
            falsy(mentions(items, 'SER0042'), 'nor anything else of its metadata')
            for _, item in ipairs(items) do
                if item.id == fee then
                    eq(item.resolution.cid, 'the client', 'whom it paid, as the party\'s place')
                    eq(item.known.error, 'credit to the client raised')
                    eq(item.items[1].item, 'WEAPON_PISTOL', 'what it records still shows')
                end
            end
        end
        local seen = ask(8, 'reviews', { all = true }).data.items
        truthy(mentions(seen, 'CREATOR1'), 'crimson.identity reads them as they are')
        truthy(mentions(seen, 'Vic Marlowe'))

        Env.chat = {}
        Env.commands['ch-review'](6, { 'all' })
        local said = {}
        for _, line in ipairs(Env.chat) do said[#said + 1] = line.text end
        truthy(#said > 0, 'the command lists them')
        falsy(table.concat(said, '\n'):find('CREATOR1', 1, true), table.concat(said, '\n'))
        truthy(table.concat(said, '\n'):find('to the client', 1, true), table.concat(said, '\n'))
    end)

    it('settles a review payout left for staff on a contract that was never stored', function()
        local s = stack()
        local id = s.review.open({ kind = 'escrow_take_unverified', contract_id = 'ctnever00001',
            cids = { from = 'CREATOR1' }, amount = 700, account = 'cash' })
        local p = Env.players[1]
        local real = p.Functions.AddMoney
        p.Functions.AddMoney = function() error('AddMoney hook raised', 0) end
        pcall(s.review.resolve, id, { action = 'pay', who = 'from' }, 'console')
        local line = s.storage.readEscrowLine(id .. ':1')
        truthy(line, 'the pay is an escrow line')
        for _ = 1, s.escrow.DELIVER_RAISE_LIMIT do
            pcall(s.escrow.release, 'ctnever00001', 'CREATOR1', { line = line.id }, 'test')
        end
        p.Functions.AddMoney = real
        truthy(s.escrow.parked(s.storage.readEscrowLine(line.id)), 'left for staff')
        local listed = false
        for _, entry in ipairs(s.admin.interrupted(0, true)) do
            if entry.line == line.id then listed = true end
        end
        truthy(listed, 'listed by /ch-stuck')

        local before = money(1)
        local reply = ask(6, 'settle', { line = line.id, disposition = 'pay' })
        eq(reply.ok, true, tostring(reply.message))
        eq(money(1) - before, 700, 'paid to whom it is owed, once')
        eq(s.storage.readEscrowLine(line.id).state, CH.ESCROW_STATE.SETTLED)
    end)

    it('wants a note to dismiss, and a party to pay', function()
        local s = stack()
        local id = s.review.open({ kind = 'escrow_settle_lost', contract_id = 'ct00000001',
            cids = { recipient = 'HITMAN01' } })
        eq(ask(6, 'resolve', { id = id, action = 'dismiss' }).message,
            s.admin.reviewAnswer(id, false, 'note_required', nil, true))
        eq(ask(6, 'resolve', { id = id, action = 'pay' }).err, 'no_party')
        eq(ask(6, 'resolve', { id = id, action = 'dismiss', note = 'checked by hand' }).ok, true)
    end)
end)

--------------------------------------------------------------------------
-- The audit log
--------------------------------------------------------------------------

describe('the audit log in the admin panel', function()
    it('reads newest first, filtered, a page at a time', function()
        local s, f = stack()
        local c = place(s, f)
        for i = 1, 5 do s.audit.financial('test_row_' .. i, 'CREATOR1', c.id, { n = i }) end
        local page = ask(6, 'logs', { action = 'test_row_', limit = 2 }).data
        eq(#page.rows, 2)
        eq(page.rows[1].action, 'test_row_5', 'newest first')
        truthy(page.next, 'and where the next page starts')
        local nextPage = ask(6, 'logs', { action = 'test_row_', limit = 2, cursor = page.next }).data
        eq(nextPage.rows[1].action, 'test_row_3')
        local last = ask(6, 'logs', { action = 'test_row_', limit = 2, cursor = nextPage.next }).data
        eq(#last.rows, 1)
        eq(last.next, nil, 'the last page says so')

        eq(#ask(6, 'logs', { kind = 'financial', contract = c.id, action = 'test_row_',
            limit = 50 }).data.rows, 5)
        eq(ask(6, 'logs', { contract = 'not an id' }).err, CH.ERR.INVALID_INPUT)
    end)

    it('shows no citizen id without crimson.identity, and finds a player\'s rows only with it', function()
        local s, f = stack()
        local c = place(s, f, { anonymous = true })
        s.audit.financial('test_row', 'CREATOR1', c.id, { to = 'TARGET01', from = 'active' })
        local rows = ask(6, 'logs', { contract = c.id, limit = 50 }).data.rows
        truthy(#rows > 0)
        for _, cid in ipairs({ 'CREATOR1', 'TARGET01' }) do
            falsy(mentions(rows, cid), cid .. ' in the log')
        end
        local row
        for _, r in ipairs(rows) do if r.action == 'test_row' then row = r end end
        eq(row.actor, 'the client', 'a role instead')
        eq(row.detail.from, 'active', 'and what is not a citizen id is left alone')

        eq(ask(6, 'logs', { actor = 'CREATOR1' }).err, 'identity_required')
        local theirs = ask(8, 'logs', { actor = 'CREATOR1', limit = 100 }).data.rows
        truthy(#theirs > 0)
        eq(theirs[1].actor, 'CREATOR1', 'crimson.identity reads them as they are')
        s.audit.flush()
        eq(#stored(s, 'admin_panel_logs_identified'), 1)
        eq(#ask(8, 'logs', { actor = 'creator01', limit = 100 }).data.rows, 0, 'not a cid anybody has')
        eq(#ask(8, 'logs', { actor = 'creator1', limit = 100 }).data.rows, #theirs,
            'and one typed in lower case is the same player')
    end)

    it('does not show staff without crimson.identity what a search by somebody with it found', function()
        local s, f = stack()
        place(s, f, { anonymous = true })
        eq(ask(6, 'contracts', { query = 'CREATOR1' }).data.total, 0, 'their own search finds nothing')
        eq(ask(8, 'contracts', { query = 'CREATOR1' }).data.total, 1, 'and one with identity finds it')
        local function searches(src)
            local rows = ask(src, 'logs', { action = 'admin_panel_search', limit = 50 }).data.rows
            for _, row in ipairs(rows) do
                if row.action == 'admin_panel_search_identified' then return row, rows end
            end
            return nil, rows
        end
        local row = searches(6)
        truthy(row, 'the identified search is on the record for them to see')
        eq(row.detail.query, '(identity only)', 'not what was typed')
        eq(row.detail.rows, '(identity only)', 'nor how many it matched')
        falsy(mentions(row, 'CREATOR1'), 'no citizen id anywhere in it (their own search row has '
            .. 'what they typed themselves)')
        local plain = searches(7)
        eq(plain.detail.query, '(identity only)', 'nor to an extra ACE')
        local whole = searches(8)
        eq(whole.detail.query, 'CREATOR1', 'crimson.identity reads it as it was')
        eq(whole.detail.rows, 1)
    end)
end)

describe('the audit log a page at a time, in every backend', function()
    local BACKENDS = { 'memory', 'json', 'mysql' }

    local function storeOf(name)
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

    for _, name in ipairs(BACKENDS) do
        it(name .. ': pages newest first, filters, and says where it ends', function()
            newStack()
            local store = storeOf(name)
            local base = Env.time
            for i = 1, 7 do
                store.writeAudit({ ts = base + i, kind = i % 2 == 0 and 'financial' or 'conduct',
                    action = 'act_' .. i, actor_cid = i <= 3 and 'AAA11111' or 'BBB22222',
                    contract_id = i == 5 and 'ct00000005' or nil, detail = { i = i } })
            end
            local seen, cursor, pages = {}, nil, 0
            repeat
                local rows, next_ = store.queryAudit({}, cursor, 3)
                pages = pages + 1
                for _, row in ipairs(rows) do seen[#seen + 1] = row.action end
                cursor = next_
            until not cursor or pages > 5
            eq(pages, 3, 'three pages of three, three and one')
            eq(table.concat(seen, ','), 'act_7,act_6,act_5,act_4,act_3,act_2,act_1')

            local financial = store.queryAudit({ kind = 'financial' }, nil, 10)
            eq(#financial, 3)
            eq(financial[1].action, 'act_6')
            eq(#store.queryAudit({ action = '_1' }, nil, 10), 1, 'by part of the action')
            eq(#store.queryAudit({ action = '%' }, nil, 10), 0, 'a substring, never a pattern')
            local one = store.queryAudit({ contract = 'ct00000005' }, nil, 10)
            eq(#one, 1)
            eq(one[1].detail.i, 5, 'the detail read back as a table')
            eq(#store.queryAudit({ actor = 'AAA11111' }, nil, 10), 3, 'by who acted')
            eq(#store.queryAudit({ from = base + 3, to = base + 5 }, nil, 10), 3, 'by time')
        end)

        it(name .. ': pages on where it was when old rows age out between pages', function()
            newStack()
            local store = storeOf(name)
            Config.Audit.RetentionDays = 1
            local base = Env.time
            for i = 1, 10 do
                store.writeAudit({ ts = base + i, kind = 'conduct', action = 'row' .. i,
                    detail = { i = i } })
            end
            local first, cursor = store.queryAudit({}, nil, 4)
            eq(first[1].action, 'row10')
            eq(first[4].action, 'row7')
            truthy(cursor, 'there is a next page')

            -- A day on, the two oldest age out with the next write (json
            -- ages them as it writes, memory and mysql when they prune).
            Env.time = base + 86400 + 3
            store.writeAudit({ ts = Env.time, kind = 'conduct', action = 'row11', detail = {} })
            if store.prune then store.prune() end
            eq(#store.queryAudit({}, nil, 20), 9, 'row1 and row2 aged out')

            local second, after = store.queryAudit({}, cursor, 4)
            local seen = {}
            for _, row in ipairs(second) do seen[#seen + 1] = row.action end
            eq(table.concat(seen, ','), 'row6,row5,row4,row3', 'the page after, and nothing again')
            eq(after, nil, 'and the last: what aged out is not shown')
        end)
    end
end)

--------------------------------------------------------------------------
-- Players
--------------------------------------------------------------------------

describe('a player in the admin panel', function()
    it('looks them up by server id, without their citizen id to staff who may not unmask', function()
        local s, f = stack()
        place(s, f, { accept = true })
        local reply = ask(6, 'player', { subject = 3 })
        eq(reply.ok, true, tostring(reply.message))
        eq(reply.data.player.online, true)
        eq(reply.data.player.name, 'Rook Ash')
        eq(reply.data.player.cid, nil)
        eq(#reply.data.contracts, 1, 'their contracts, as /ch-contracts lists them')
        eq(reply.data.contracts[1].role, 'hitman')
        eq(reply.data.stats, nil, 'the record counts anonymous work, so it needs crimson.identity')
        eq(type(reply.data.notices.count), 'number')
        eq(type(ask(8, 'player', { subject = 3 }).data.stats.completed), 'number',
            'crimson.identity reads the record')
        eq(ask(8, 'player', { subject = 3 }).data.player.cid, 'HITMAN01', 'crimson.identity sees it')
        eq(ask(6, 'player', { subject = 'HITMAN01' }).data.player.cid, 'HITMAN01',
            'and anybody sees the one they typed')
        eq(ask(6, 'player', { subject = 99 }).err, CH.ERR.NOT_FOUND)
        eq(ask(6, 'player', { subject = '!!' }).err, CH.ERR.INVALID_INPUT)
    end)

    it('leaves out what they are owed on a contract they were anonymous on', function()
        local s, f = stack()
        local c = place(s, f, { accept = true, anonHitman = true })
        local line = s.storage.readEscrow(c.id)[1]
        Env.removePlayer(3)
        s.escrow.release(c.id, 'HITMAN01', { line = line.id }, 'test')
        eq(s.storage.readEscrowLine(line.id).owed_to, 'HITMAN01', 'owed to them, offline')
        -- Offline, and party to nothing but that contract: to staff who may
        -- not unmask, nothing they may see names them, which is what an
        -- unknown citizen id answers too.
        local hidden = ask(6, 'player', { subject = 'HITMAN01' })
        eq(hidden.err, CH.ERR.NOT_FOUND, 'not to staff who may not unmask')
        falsy(mentions(hidden, line.id), 'and nothing of the line')
        local owed = ask(8, 'player', { subject = 'HITMAN01' }).data.owed
        eq(#owed, 1)
        eq(owed[1].queued, true, 'and in their queue')
    end)

    it('counts nothing they did anonymously, to staff who may not unmask', function()
        local s, f = stack()
        Config.Limits.MaxActiveContractsPerCreator = 10
        local open = place(s, f)
        local hidden = place(s, f, { anonymous = true, target = 'HITMAN01' })
        Env.removePlayer(1)
        -- A notice kept for their next login on each, and a delivery on each.
        for _, c in ipairs({ open, hidden }) do
            s.notify.contractEnded(s.storage.readContract(c.id), CH.STATE.EXPIRED, {}, {})
            s.storage.queuePending('CREATOR1', c.id, c.id .. ':1')
        end

        for _, src in ipairs({ 6, 7 }) do
            local data = ask(src, 'player', { subject = 'CREATOR1' }).data
            eq(#data.contracts, 1, 'the contract placed openly, as /ch-contracts lists it')
            eq(data.stats, nil, 'and no record: its counters hold the anonymous one too')
            eq(data.pending, 1, 'a delivery on the anonymous contract is left out')
            eq(data.notices.count, 1, 'and so is a notice about it')
            falsy(mentions(data, hidden.id), 'nothing names the anonymous contract')
        end
        local whole = ask(8, 'player', { subject = 'CREATOR1' }).data
        eq(#whole.contracts, 2)
        eq(whole.stats.placed, 2, 'crimson.identity reads the whole record')
        eq(whole.pending, 2)
        eq(whole.notices.count, 2)
    end)

    it('answers not found for a citizen id nothing names, and finds one typed in lower case', function()
        local s, f = stack()
        place(s, f)
        local nobody = ask(6, 'player', { subject = 'NOBODY99' })
        eq(nobody.err, CH.ERR.NOT_FOUND, 'not an empty profile that reads as a player with nothing')
        truthy(tostring(nobody.message):find('spelt', 1, true), tostring(nobody.message))
        local typed = ask(6, 'player', { subject = 'target01' })
        eq(typed.ok, true, tostring(typed.message))
        eq(typed.data.player.cid, 'TARGET01', 'the server\'s form of what was typed')
        eq(typed.data.player.online, true)
        eq(#typed.data.contracts, 1)
    end)
end)

--------------------------------------------------------------------------
-- Settings and tools
--------------------------------------------------------------------------

describe('settings and tools in the admin panel', function()
    it('lists every setting, changes one, and refuses what is not on the list', function()
        local s = stack()
        local view = ask(6, 'settings').data
        truthy(#view.features > 40 and #view.limits > 40, 'the switches and the limits')
        truthy(#view.readonly >= 5, 'and the ones shown read-only, with why')

        local changed = ask(6, 'setSetting', { key = 'Limits.MaxAcceptedPerHitman', value = 5 })
        eq(changed.ok, true, tostring(changed.message))
        eq(Config.Limits.MaxAcceptedPerHitman, 5, 'in force at once')
        eq(s.storage.readSettings()['Limits.MaxAcceptedPerHitman'].value, 5, 'and kept')
        eq(s.storage.readSettings()['Limits.MaxAcceptedPerHitman'].by, 'ADMIN001', 'with who')

        eq(ask(6, 'setSetting', { key = 'Database.Mode', value = 'mysql' }).err, 'read_only')
        eq(ask(6, 'setSetting', { key = 'Admin.Enabled', value = false }).err, 'read_only')
        eq(ask(6, 'setSetting', { key = 'Audit.Webhook', value = 'x' }).err, 'not_allowed')
        eq(ask(6, 'setSetting', { key = 'Limits.MaxAcceptedPerHitman', value = 0 }).err,
            'invalid_value')
        eq(ask(6, 'resetSetting', { key = 'Limits.MaxAcceptedPerHitman' }).ok, true)
        eq(Config.Limits.MaxAcceptedPerHitman, 3, 'back to config.lua')
        eq(ask(6, 'resetSettings', {}).ok, true)
    end)

    it('will not let staff rate-limit the panel itself', function()
        local s = stack()
        for _, key in ipairs({ 'Cooldowns.admin.per', 'Cooldowns.admin.burst',
            'Cooldowns.adminWrite.per', 'Cooldowns.adminWrite.burst' }) do
            local reply = ask(6, 'setSetting', { key = key, value = key:find('per') and 3600 or 1 })
            eq(reply.err, 'read_only', key)
            truthy(tostring(reply.message):find('every request it makes', 1, true), tostring(reply.message))
        end
        eq(next(s.storage.readSettings()), nil, 'nothing kept')
        for i = 1, 5 do eq(ask(8, 'overview').ok, true, 'request ' .. i .. ' still answered') end
        local readonly = {}
        for _, row in ipairs(ask(6, 'settings').data.readonly) do readonly[row.key] = row end
        truthy(readonly['Cooldowns.admin.burst'], 'shown read-only, with why')
        truthy(readonly['Cooldowns.adminWrite.per'])
        eq(ask(6, 'setSetting', { key = 'Cooldowns.load.burst', value = 50 }).ok, true,
            'the players\' own limits still change')
    end)

    it('runs the timer refresh, the diagnosis and the log flush', function()
        local s = stack()
        local refreshed = ask(6, 'refresh', {})
        eq(refreshed.ok, true)
        truthy(#refreshed.data.lines > 3)
        eq(#stored(s, 'admin_timers_refreshed'), 1, 'on the record at once')
        local diag = ask(6, 'diag', {})
        truthy(diag.data.lines[1]:find('diagnosis', 1, true))
        s.audit.action('queued_row', 'CREATOR1', nil, {})
        local flushed = ask(6, 'flush', {})
        eq(flushed.ok, true)
        truthy(flushed.data.written >= 1, 'what was queued is written')
        eq(#stored(s, 'queued_row'), 1)
    end)
end)
