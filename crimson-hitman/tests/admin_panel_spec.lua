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
                 'refresh', 'flush', 'setPlaytime' }
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
        anonymous = opts.anonymous, penaltyAmount = opts.penalty,
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
            s.admin.settleAnswer(false, CH.ERR.ALREADY_SETTLED, nil, true), 'and once only')
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
-- What staff without crimson.identity read in errors and notes
--------------------------------------------------------------------------

describe('errors and notes, to staff who may not unmask', function()
    --- oxmysql's message for a statement the database refused, as its await
    --- raises it: the statement, every value it was sent, the server's words.
    local function refusal(values)
        return 'crimson-hitman/server/timing.lua:41: crimson-hitman was unable to execute a query!\n'
            .. 'Query: \n        INSERT INTO crimson_contracts\n            (id, creator_cid, '
            .. 'creator_account, creator_name, anon_creator)\n        VALUES (?, ?, ?, ?, ?)\n'
            .. json.encode(values) .. '\nLock wait timeout exceeded; try restarting transaction'
    end

    --- Who the anonymous client is, in every form a leak could take.
    local WHO = { 'CREATOR1', 'license:aaa', 'Vic Marlowe' }

    --- Every line the staff commands print to a source, and every answer
    --- the panel's reads give it.
    local function everythingShown(s, src, contractId)
        local shown = {
            ask(src, 'reviews', { all = true }), ask(src, 'logs', { limit = 100 }),
            ask(src, 'logs', { contract = contractId, limit = 100 }),
            ask(src, 'contract', { id = contractId }), ask(src, 'stuck'),
        }
        for _, args in ipairs({ { 'review', { 'all' } }, { 'review', {} }, { 'stuck', {} } }) do
            Env.chat = {}
            Env.commands[Config.Admin.Commands[args[1]]](src, args[2])
            for _, line in ipairs(Env.chat) do shown[#shown + 1] = line.text end
        end
        return shown
    end

    local function anonymousArmed(s, f, landed)
        -- Both refuse, oxmysql-style, with the parameter JSON: the write, and
        -- (where it did not land) the read that asks whether it did.
        local write, readContract = s.storage.writeContract, s.storage.readContract
        local armed = false
        s.storage.writeContract = function(contract)
            if landed then write(contract) end
            armed = not landed
            error(refusal({ contract.id, contract.creator_cid, contract.creator_account,
                contract.creator_name, contract.anon_creator }), 0)
        end
        s.storage.readContract = function(id)
            if armed then error(refusal({ id }), 0) end
            return readContract(id)
        end
        local ran, c = pcall(s.contracts.create, f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } }, anonymous = true,
        })
        s.storage.writeContract, s.storage.readContract = write, readContract
        return ran, c
    end

    it('A07: never names an anonymous client through the error a contract write raised', function()
        local s, f = stack()
        local ran = anonymousArmed(s, f, false)
        falsy(ran, 'the create raises: the store would neither write it nor say whether it had')
        local item = s.storage.reviewItems(true, 10)[1]
        truthy(item and item.kind == 'contract_unrecorded', 'left for staff')

        for _, src in ipairs({ 6, 7 }) do
            local shown = everythingShown(s, src, item.contract_id)
            for _, who in ipairs(WHO) do
                falsy(mentions(shown, who), ('%s reaches source %d'):format(who, src))
            end
        end
        -- Who may unmask reads the driver's words, cleaned of the values.
        local rows = ask(8, 'logs', { action = 'contract_write_failed', limit = 10 }).data.rows
        eq(#rows, 1)
        truthy(rows[1].detail.error:find('Lock wait timeout exceeded', 1, true), rows[1].detail.error)
        falsy(rows[1].detail.error:find('Vic Marlowe', 1, true), 'kept without the values')
    end)

    it('A07: nor through one a write that landed raised, in the contract\'s view and the log', function()
        local s, f = stack()
        local ran, c = anonymousArmed(s, f, true)
        truthy(ran and c, 'placed: the store has it')
        eq(s.storage.readContract(c.id).anon_creator, true)
        for _, src in ipairs({ 6, 7 }) do
            local shown = everythingShown(s, src, c.id)
            for _, who in ipairs(WHO) do
                falsy(mentions(shown, who), ('%s reaches source %d'):format(who, src))
            end
        end
    end)

    it('A07: nor through an error stored whole before rows were cleaned', function()
        local s, f = stack()
        local c = place(s, f, { anonymous = true })
        -- As an older build left them: the row and the item hold it all.
        s.storage.writeAudit({ ts = os.time(), kind = 'financial', action = 'contract_write_failed',
            actor_cid = 'CREATOR1', contract_id = c.id,
            detail = { error = refusal({ c.id, 'CREATOR1', 'license:aaa', 'Vic Marlowe', true }) } })
        s.storage.writeReview({ id = 'rv00000077', kind = 'contract_unrecorded', contract_id = c.id,
            cids = { creator = 'CREATOR1' }, state = 'open', created_at = os.time(),
            known = { error = refusal({ c.id, 'CREATOR1', 'license:aaa', 'Vic Marlowe', true }),
                      read_error = 'read raised for license:aaa' } })
        for _, src in ipairs({ 6, 7 }) do
            local shown = everythingShown(s, src, c.id)
            for _, who in ipairs(WHO) do
                falsy(mentions(shown, who), ('%s reaches source %d'):format(who, src))
            end
        end
        truthy(mentions(ask(8, 'reviews', {}).data.items, 'license:aaa'),
            'crimson.identity reads what was stored, as it was')
    end)

    it('A10: scrubs a staff note naming the anonymous client from the log and the timeline', function()
        local s, f = stack()
        local c = place(s, f, { anonymous = true, accept = true, anonHitman = true })
        local id = s.review.open({ kind = 'escrow_settle_lost', contract_id = c.id,
            cids = { recipient = 'HITMAN01' } })
        eq(ask(8, 'resolve', { id = id, action = 'dismiss',
            note = 'refunded CREATOR1 (Vic Marlowe) by hand; told Rook Ash' }).ok, true)
        for _, src in ipairs({ 6, 7 }) do
            local shown = everythingShown(s, src, c.id)
            for _, who in ipairs({ 'CREATOR1', 'Vic Marlowe', 'HITMAN01', 'Rook Ash' }) do
                falsy(mentions(shown, who), ('%s reaches source %d'):format(who, src))
            end
        end
        local timeline = ask(6, 'contract', { id = c.id }).data.timeline
        local note
        for _, row in ipairs(timeline) do
            if row.action == 'review_resolved' then note = row.detail.note end
        end
        eq(note, 'refunded the client (Anonymous) by hand; told Anonymous', 'the note, scrubbed')
        truthy(mentions(ask(8, 'contract', { id = c.id }).data.timeline, 'Vic Marlowe'),
            'crimson.identity reads it as written')
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

--- A character's playtime in the panel: the hours the built-in tracker
--- counted and whether they are from before it, shown in the lookup and the
--- diagnosis, and set or reset from there by staff who may write.
describe('a player\'s playtime in the admin panel', function()
    --- The stack, on a server whose metadata keeps no playtime, with
    --- qbx_core's players table numbering the three as from before the
    --- tracker and a fourth character made after it.
    local function tracked()
        local s, f = stack()
        Exec.install(Natives)
        Natives.resourceStates.oxmysql = 'started'
        Exec.run('CREATE TABLE IF NOT EXISTS players (citizenid VARCHAR(50) PRIMARY KEY, id INT NOT NULL)')
        for i, cid in ipairs({ 'CREATOR1', 'TARGET01', 'HITMAN01' }) do
            Exec.run('INSERT INTO players (citizenid, id) VALUES (?, ?)', { cid, i })
        end
        s.playtime.pass()
        Env.addPlayer({ source = 4, citizenid = 'NEWBIE01', license = 'license:ddd',
            firstname = 'Nell', lastname = 'Newer' })
        Exec.run('INSERT INTO players (citizenid, id) VALUES (?, ?)', { 'NEWBIE01', 9 })
        for src = 1, 4 do Env.players[src].PlayerData.metadata.playtime = nil end
        Env.advance(90)
        s.playtime.pass()
        return s, f
    end

    it('shows the hours counted and whether they are from before the count, to any reader', function()
        local s = tracked()
        local newer = ask(7, 'player', { subject = 4 }).data.playtime
        eq(newer.hours, 0, 'first seen at the last pass')
        eq(newer.grandfathered, false)
        eq(newer.floor, 5)
        eq(newer.from, 'tracker', 'what the rule reads for them')
        eq(newer.counting, true)
        local older = ask(7, 'player', { subject = 2 }).data.playtime
        eq(older.hours, 0.0)
        eq(older.grandfathered, true, 'numbered before the first start')
        Env.players[2].PlayerData.metadata.playtime = 600
        eq(ask(7, 'player', { subject = 2 }).data.playtime.from, 'metadata', 'said where the rule reads metadata')
        truthy(s.storage.readPlaytime('NEWBIE01'))
    end)

    it('is set and reset by crimson.admin without the identity ACE, on the record, and the rule follows', function()
        local s, f = tracked()
        local refused = s.contracts.create(f.creator, { targetCid = 'NEWBIE01', reason = 'x',
            reward = { baseline = { cash = 5000 } } })
        falsy(refused, 'new, and under the floor')

        local set = ask(6, 'setPlaytime', { subject = 4, hours = 6 })
        eq(set.ok, true, tostring(set.message))
        eq(set.message, 'Nell Newer\'s counted playtime is now 6 h (it was 0 h).')
        eq(set.data.playtime.hours, 6)
        eq(s.storage.readPlaytime('NEWBIE01').played_seconds, 6 * 3600, 'written at once')
        eq(ask(6, 'player', { subject = 4 }).data.playtime.hours, 6, 'and shown')
        truthy(s.contracts.create(f.creator, { targetCid = 'NEWBIE01', reason = 'x',
            reward = { baseline = { cash = 5000 } } }), 'six hours is enough')

        local reset = ask(6, 'setPlaytime', { subject = 'NEWBIE01', hours = 0 })
        eq(reset.ok, true, tostring(reset.message))
        eq(reset.message, 'Nell Newer\'s counted playtime is reset to 0 h (it was 6 h).',
            'named as in the city, though looked up by citizen id')
        eq(s.storage.readPlaytime('NEWBIE01').played_seconds, 0)

        local rows = stored(s, 'admin_playtime_set')
        eq(#rows, 2, 'each one on the record')
        local seen = {}
        for _, row in ipairs(rows) do
            eq(row.actor_cid, 'ADMIN001', 'by whom')
            eq(row.detail.subject, 'NEWBIE01', 'about whom')
            seen[row.detail.hours] = row.detail
        end
        eq(seen[6].before, 0)
        eq(seen[0].before, 6)
        eq(seen[0].reset, true)

        local grandfathered = ask(6, 'setPlaytime', { subject = 2, hours = 1 })
        truthy(grandfathered.message:find('They are grandfathered', 1, true), grandfathered.message)
    end)

    it('needs crimson.admin itself, and takes only a number of hours for somebody who exists', function()
        local s = tracked()
        eq(ask(7, 'setPlaytime', { subject = 4, hours = 6 }).err, 'not_allowed', 'an extra ACE only reads')
        eq(ask(3, 'setPlaytime', { subject = 4, hours = 6 }).err, 'not_allowed', 'a player does nothing')
        for _, bad in ipairs({ -1, 'six', 100001, 0 / 0, {} }) do
            eq(ask(6, 'setPlaytime', { subject = 4, hours = bad }).err, CH.ERR.INVALID_INPUT, tostring(bad))
        end
        eq(ask(6, 'setPlaytime', { subject = 99, hours = 1 }).err, CH.ERR.NOT_FOUND)
        eq(ask(6, 'setPlaytime', { subject = 'NOBODY99', hours = 1 }).err, CH.ERR.NOT_FOUND,
            'no row is made for a character nobody has')
        eq(s.storage.readPlaytime('NOBODY99'), nil)
        eq(s.storage.readPlaytime('NEWBIE01').played_seconds, 0, 'nothing refused was written')
        eq(#stored(s, 'admin_playtime_set'), 0)
    end)

    it('is in the diagnosis, for the server and for the player named', function()
        tracked()
        local lines = table.concat(ask(6, 'diag', { subject = 4 }).data.lines, '\n')
        truthy(lines:find('playtime: a target needs 5 hour(s) played', 1, true), lines)
        truthy(lines:find('characters numbered up to 3 in qbx_core', 1, true), lines)
        truthy(lines:find('this player: 0 h counted by the tracker; grandfathered: no', 1, true), lines)
        truthy(lines:find('protected as too new to be a target', 1, true), lines)
        local older = table.concat(ask(6, 'diag', { subject = 2 }).data.lines, '\n')
        truthy(older:find('grandfathered: yes, from before the tracker', 1, true), older)
        truthy(older:find('fair game by playtime: grandfathered', 1, true), older)
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

--------------------------------------------------------------------------
-- What the panel offers for each line staff settle, against the server
--------------------------------------------------------------------------

--- Every kind of line Admin.interrupted lists, built the way the server
--- leaves it, on a stack of its own: the contract placed and accepted, its
--- 5,000 baseline line in the state the kind names. Each returns the line's
--- id.
local function raw(s) rawset(s.storage, '__rawFixture', true) end
local function baselineOf(s, c) return s.storage.readEscrow(c.id)[1] end
local function closeAs(s, c, from, to)
    raw(s)
    truthy(s.storage.compareSetContractState(c.id, from, to))
end
local function owe(s, c, extra)
    local line = baselineOf(s, c)
    for k, v in pairs(extra) do line[k] = v end
    s.storage.writeEscrow(c.id, { line })
    return line
end

local LINE_KINDS = {
    { name = 'raised', why = 'raised', offers = 'pay,pay_amount,return,delivered', build = function(s, f)
        local c = place(s, f, { accept = true })
        local line = baselineOf(s, c)
        local p = Env.players[3]
        local real = p.Functions.AddMoney
        p.Functions.AddMoney = function() error('AddMoney hook raised', 0) end
        for _ = 1, s.escrow.DELIVER_RAISE_LIMIT do
            pcall(s.escrow.release, c.id, 'HITMAN01', { line = line.id }, 'test')
        end
        p.Functions.AddMoney = real
        return line.id
    end },
    { name = 'interrupted', why = 'interrupted', offers = 'pay,pay_amount,return,delivered',
      build = function(s, f)
        local c = place(s, f, { accept = true })
        local line = owe(s, c, { releasing_to = 'HITMAN01' })
        truthy(s.escrow.parkInterrupted(line))
        return line.id
    end },
    { name = 'stalled', why = 'stalled', offers = 'pay,pay_amount,return,delivered', build = function(s, f)
        local c = place(s, f, { accept = true })
        return owe(s, c, { owed_to = 'HITMAN01', releasing_to = 'HITMAN01' }).id
    end },
    { name = 'unqueued', why = 'unqueued', offers = 'pay', build = function(s, f)
        local c = place(s, f, { accept = true })
        return owe(s, c, { owed_to = 'HITMAN01' }).id
    end },
    { name = 'stalled claim', why = 'stalled_claim', offers = 'pay', build = function(s, f)
        local c = place(s, f, { accept = true })
        closeAs(s, c, CH.STATE.ACCEPTED, CH.STATE.COMPLETING)
        return owe(s, c, { owed_to = 'HITMAN01' }).id
    end },
    { name = 'releasing, named', why = 'releasing', offers = 'pay,pay_amount,return,delivered',
      build = function(s, f)
        local c = place(s, f, { accept = true })
        local line = baselineOf(s, c)
        truthy(s.storage.claimEscrowLine(line.id, CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING))
        line = s.storage.readEscrowLine(line.id)
        line.releasing_to = 'HITMAN01'
        s.storage.writeEscrow(c.id, { line })
        return line.id
    end },
    { name = 'releasing, unnamed and owed', why = 'never_given_release', offers = 'pay',
      build = function(s, f)
        local c = place(s, f, { accept = true })
        closeAs(s, c, CH.STATE.ACCEPTED, CH.STATE.COMPLETING)
        local line = owe(s, c, { owed_to = 'HITMAN01' })
        truthy(s.storage.claimEscrowLine(line.id, CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING))
        return line.id
    end },
    { name = 'releasing, unnamed and owed to nobody', why = 'never_given_release', offers = 'return',
      build = function(s, f)
        local c = place(s, f, { accept = true })
        local line = baselineOf(s, c)
        truthy(s.storage.claimEscrowLine(line.id, CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING))
        return line.id
    end },
    { name = 'ending unfinished', why = 'ending_unfinished', offers = '', build = function(s, f)
        local c = place(s, f, { accept = true })
        closeAs(s, c, CH.STATE.ACCEPTED, CH.STATE.CANCELLED)
        return baselineOf(s, c).id
    end },
    { name = 'mid-release at a shutdown, pay or return', settles = 'pay_or_return', offers = 'pay,return',
      build = function(s, f)
        local c = place(s, f, { accept = true })
        closeAs(s, c, CH.STATE.ACCEPTED, CH.STATE.CANCELLED)
        local line = owe(s, c, { releasing_to = 'HITMAN01' })
        s.audit.financial('release_interrupted', 'HITMAN01', c.id, { line = line.id, review = true })
        s.audit.flush()
        return line.id
    end },
    { name = 'mid-release at a shutdown, queued since', settles = 'queued', offers = '',
      build = function(s, f)
        local c = place(s, f, { accept = true })
        closeAs(s, c, CH.STATE.ACCEPTED, CH.STATE.CANCELLED)
        local line = owe(s, c, { owed_to = 'HITMAN01' })
        s.storage.queuePending('HITMAN01', c.id, line.id)
        s.audit.financial('release_interrupted', 'HITMAN01', c.id, { line = line.id, review = true })
        s.audit.flush()
        return line.id
    end },
    { name = 'never stored, naming nobody', orphan = true, offers = 'return_owner', build = function(s)
        s.storage.writeEscrow('ct00000099', { { id = 'ct00000099:1', contract_id = 'ct00000099',
            slot = 1, portion = CH.PORTION.BASELINE, source = 'cash', amount = 5000,
            state = CH.ESCROW_STATE.HELD } })
        return 'ct00000099:1'
    end },
    { name = 'owed and queued to a citizen id nobody has', why = 'owed_to_nobody', offers = 'return_owner',
      build = function(s)
        s.storage.writeEscrow('ct00000099', { { id = 'ct00000099:1', contract_id = 'ct00000099',
            slot = 1, portion = CH.PORTION.BASELINE, source = 'cash', amount = 5000,
            owed_to = 'creator1', state = CH.ESCROW_STATE.HELD } })
        s.storage.queuePending('creator1', 'ct00000099', 'ct00000099:1')
        return 'ct00000099:1'
    end },
}

--- Every button a stuck line can have, and the settle it sends.
local SETTLES = {
    pay = function(s, id) return s.admin.settleLine(0, id, 'pay') end,
    pay_amount = function(s, id)
        local line = s.storage.readEscrowLine(id)
        return s.admin.settleLine(0, id, 'pay', tostring(s.escrow.stillOwed(line) - 1))
    end,
    ['return'] = function(s, id) return s.admin.settleLine(0, id, 'return') end,
    return_owner = function(s, id) return s.admin.settleLine(0, id, 'return', 'CREATOR1') end,
    delivered = function(s, id) return s.admin.settleLine(0, id, 'delivered') end,
}
local BUTTONS = { 'pay', 'pay_amount', 'return', 'return_owner', 'delivered' }

describe('every line the panel lists for staff, settled from what it offers', function()
    --- W192: the buttons were tested only against hand-written replies,
    --- one of which offered the money-losing Pay amount. Here each real
    --- kind is built, listed by the real stuck op, and every button it
    --- offers is accepted by Admin.settleLine, every one it does not
    --- offer refused, with nothing moved.
    for _, kind in ipairs(LINE_KINDS) do
        it(kind.name .. ': offers ' .. (kind.offers ~= '' and kind.offers or 'nothing'), function()
            local s, f = stack()
            local id = kind.build(s, f)
            local entry
            for _, listed in ipairs(ask(6, 'stuck').data.lines or {}) do
                if listed.line == id then entry = listed end
            end
            truthy(entry, 'listed by Stuck escrow')
            if kind.why then eq(entry.why, kind.why) end
            if kind.settles then eq(entry.settles, kind.settles) end
            if kind.orphan then truthy(entry.orphan) end
            eq(table.concat(entry.actions, ','), kind.offers)
        end)

        for _, button in ipairs(BUTTONS) do
            local offered = (',' .. kind.offers .. ','):find(',' .. button .. ',', 1, true) ~= nil
            it(('%s: %s is %s'):format(kind.name, button, offered and 'accepted' or 'refused'), function()
                local s, f = stack()
                local id = kind.build(s, f)
                local before = { money(1), money(3) }
                local ok, err = SETTLES[button](s, id)
                if offered then
                    eq(ok, true, button .. ' answered ' .. tostring(err))
                else
                    eq(ok, false, button .. ' went through: ' .. tostring(err))
                    eq(money(1), before[1], 'nothing given to the client')
                    eq(money(3), before[2], 'nothing given to the hitman')
                end
            end)
        end
    end
end)

describe('the panel\'s own dead ends', function()
    --- W186: the never-given line's drawer said "only Pay" beside a Pay
    --- amount box that paid part of it and wrote the rest off.
    it('a never-given line offers only Pay, and refuses an amount from the panel and the command', function()
        local s, f = stack()
        local c = place(s, f, { accept = true })
        local line = owe(s, c, { owed_to = 'HITMAN01', portion = CH.PORTION.OWED })
        local view = ask(6, 'contract', { id = c.id }).data
        eq(#view.stuck, 1)
        eq(table.concat(view.stuck[1].actions, ','), 'pay', 'no Pay amount')
        local before = money(3)
        local reply = ask(6, 'settle', { line = line.id, disposition = 'pay', amount = 1000 })
        eq(reply.ok, false)
        eq(reply.err, 'pay_only')
        Env.chat = {}
        Env.commands[Config.Admin.Commands.settle](6, { line.id, 'pay', '1000' })
        eq(select(2, s.admin.settleLine(6, line.id, 'pay', '1000')), 'pay_only')
        eq(money(3), before, 'nothing given')
        local stored = s.storage.readEscrowLine(line.id)
        eq(stored.state, CH.ESCROW_STATE.HELD, 'still owed in full')
        eq(tonumber(stored.deliver_arrived) or 0, 0, 'nothing written off as arrived')
        eq(ask(6, 'settle', { line = line.id, disposition = 'pay' }).ok, true, 'Pay settles it')
        eq(money(3) - before, 5000, 'all of it')
    end)

    --- W191: listed with every button and an "Arrival unknown" note, and
    --- each button answered that it was not staff's to settle.
    it('a line left mid-release before it named anyone says nothing arrived, and what settles it', function()
        local s, f = stack()
        local c = place(s, f, { accept = true })
        local line = baselineOf(s, c)
        truthy(s.storage.claimEscrowLine(line.id, CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING))
        local entry = ask(6, 'stuck').data.lines[1]
        eq(entry.why, 'never_given_release')
        eq(entry.owed, nil, 'owed to nobody')
        eq(table.concat(entry.actions, ','), 'return')
        local reply = ask(6, 'settle', { line = line.id, disposition = 'pay' })
        eq(reply.err, 'return_only')
        reply = ask(6, 'settle', { line = line.id, disposition = 'return' })
        eq(reply.ok, true, tostring(reply.message))
        eq(reply.err, 'put_back')
        truthy(reply.message:find('nothing of it was given', 1, true), reply.message)
        eq(s.storage.readEscrowLine(line.id).state, CH.ESCROW_STATE.HELD, 'its contract\'s own again')
        eq(#ask(6, 'stuck').data.lines, 0)
    end)

    --- W138: an item the store has not taken yet was listed with a working
    --- form, and resolving it answered that no item had that id.
    it('an item not in the store yet answers that it can be resolved once it is', function()
        local s = stack()
        local real = s.storage.writeReview
        s.storage.writeReview = function() error('connection lost', 0) end
        local id = s.review.open({ kind = 'bailout_refund_stranded', contract_id = 'ct00000001',
            cids = { payer = 'TARGET01' }, amount = 5000, account = 'bank' })
        s.storage.writeReview = real
        local listed = ask(6, 'reviews', {}).data.items
        eq(#listed, 1)
        truthy(listed[1].unwritten)
        local before = money(2)
        local reply = ask(6, 'resolve', { id = id, action = 'refund', who = 'payer', amount = 5000 })
        eq(reply.ok, false)
        eq(reply.err, 'unwritten')
        eq(reply.message, 'It can be resolved once the store has taken it, within a tick. Nothing was given.')
        eq(money(2), before)
        s.review.retryUnwritten()
        eq(ask(6, 'resolve', { id = id, action = 'refund', who = 'payer', amount = 5000 }).ok, true,
            'and resolves once the store has it')
    end)

    --- A02: the overview counted the lines of a contract never stored as
    --- left for staff, and its id answered not found: only the console's
    --- settle command could reach them.
    it('a contract never stored opens as its lines alone, settled from there', function()
        local s = stack()
        s.storage.writeEscrow('ct00000099', { { id = 'ct00000099:1', contract_id = 'ct00000099',
            slot = 1, portion = CH.PORTION.BASELINE, source = 'cash', amount = 5000,
            state = CH.ESCROW_STATE.HELD } })
        eq(ask(6, 'overview').data.stuck.leftForStaff, 1, 'counted as staff\'s')
        local reply = ask(6, 'contract', { id = 'ct00000099' })
        eq(reply.ok, true, tostring(reply.message))
        eq(reply.data.contract.neverStored, true)
        eq(reply.data.canVoid, false)
        eq(#reply.data.escrow, 1, 'its line')
        eq(#reply.data.stuck, 1)
        eq(table.concat(reply.data.stuck[1].actions, ','), 'return_owner', 'with Return to')
        local before = money(1)
        local settled = ask(6, 'settle', { line = 'ct00000099:1', disposition = 'return',
            owner = 'CREATOR1' })
        eq(settled.ok, true, tostring(settled.message))
        eq(money(1) - before, 5000, 'back to who put it up')
        eq(ask(6, 'contract', { id = 'ct00000098' }).err, CH.ERR.NOT_FOUND, 'an id with nothing is not found')
    end)

    --- W139: a write that raised skipped the flush and the cache drop, and
    --- its row named no contract.
    it('a write that raises is on the record at once, with what it was about', function()
        local s, f = stack()
        local c = place(s, f)
        ask(6, 'overview')
        -- The overview counts through the store's count by state (S24).
        local reads, real = 0, s.storage.countContractsByState
        s.storage.countContractsByState = function(...) reads = reads + 1 return real(...) end
        local readContract = s.storage.readContract
        s.storage.readContract = function() error('connection lost', 0) end
        local reply = ask(6, 'void', { id = c.id, reason = 'duplicate listing' })
        s.storage.readContract = readContract
        eq(reply.ok, false)
        eq(reply.err, CH.ERR.SERVER_ERROR)
        local rows = stored(s, 'admin_panel_error')
        eq(#rows, 1, 'in the store, not the queue')
        eq(rows[1].contract_id, c.id, 'on the contract\'s timeline')
        eq(rows[1].detail.id, c.id)
        eq(rows[1].detail.reason, 'duplicate listing')
        eq(s.audit.pending(), 0, 'nothing left in the queue')
        ask(6, 'overview')
        s.storage.countContractsByState = real
        eq(reads, 1, 'the overview is read again, not served from before the write')
    end)
end)

--------------------------------------------------------------------------
-- What the panel reads (G3)
--------------------------------------------------------------------------

describe('what the admin panel reads, as the store holds it', function()
    local function storeOf(name)
        if name == 'json' then
            package.loaded['crimson-hitman.server.storage.json'] = nil
            Natives.files = {}
            local store = require('crimson-hitman.server.storage.json')
            store.open()
            return store
        end
        Exec.install(Natives)
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local store = require('crimson-hitman.server.storage.mysql')
        store.open()
        return store
    end

    --- The panel reading `name`'s store, with what the memory one holds of
    --- `ids` copied into it.
    local function panelOn(s, name, ids)
        if name == 'memory' then return s.storage end
        local store = storeOf(name)
        for _, id in ipairs(ids) do
            store.insertContract(s.storage.readContract(id))
            for _, hitman in ipairs(s.storage.readHitmen(id)) do store.addHitman(hitman) end
            store.insertEscrow(id, s.storage.readEscrow(id))
        end
        s.panel.init(setmetatable({ storage = store }, { __index = s }))
        return store
    end

    for _, name in ipairs({ 'memory', 'json', 'mysql' }) do
        --- S02/S27: read from crimson_hitmen.stake_amount, written by nothing.
        it(name .. ': an operative\'s stake is what they have at stake', function()
            local s, f = stack()
            Env.players[3].PlayerData.money.bank = 50000
            local c = place(s, f, { mode = CH.MODE.EXCLUSIVE, penalty = 2000, accept = true })
            local store = panelOn(s, name, { c.id })
            eq(ask(6, 'contract', { id = c.id }).data.hitmen[1].stake, 2000)
            local stakeLine
            for _, line in ipairs(store.readEscrow(c.id)) do
                if line.portion == CH.PORTION.STAKE then stakeLine = line.id end
            end
            truthy(store.claimEscrowLine(stakeLine, CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING))
            truthy(store.settleEscrowLine(stakeLine, 'HITMAN01'))
            local view = ask(6, 'contract', { id = c.id }).data
            eq(view.hitmen[1].stake, 0, 'handed back, nothing at stake')
            local listed = false
            for _, line in ipairs(view.escrow) do
                if line.id == stakeLine then listed = line.state == CH.ESCROW_STATE.SETTLED end
            end
            truthy(listed, 'and the escrow still lists the settled line')
        end)

        --- S24: every row of crimson_contracts read every few seconds to count it.
        it(name .. ': the overview counts contracts by state as the store holds them', function()
            local s, f = stack()
            Config.Limits.MaxActiveContractsPerCreator = 10
            local a = place(s, f, { accept = true })
            local b = place(s, f, { target = 'HITMAN01' })
            truthy(s.admin.void(0, b.id, 'test'))
            panelOn(s, name, { a.id, b.id })
            if name == 'mysql' then Exec.statements = {} end
            local counts = ask(6, 'overview').data.contracts
            eq(counts.total, 2)
            eq(counts.byState.accepted, 1)
            eq(counts.byState.voided, 1)
            if name == 'mysql' then
                local grouped, whole = false, false
                for _, sql in ipairs(Exec.statements) do
                    if sql:find('GROUP BY state', 1, true) then grouped = true end
                    if sql:find('^SELECT %* FROM crimson_contracts') then whole = true end
                end
                truthy(grouped, 'counted by GROUP BY')
                falsy(whole, 'and no SELECT * of the whole table')
            end
        end)
    end

    --- A03: the tile said 'holding 2 contracts' for two operatives on one.
    it('counts the contracts operatives hold, not the places', function()
        local s, f = stack()
        local c = place(s, f, { accept = true })
        Env.addPlayer({ source = 9, citizenid = 'HITMAN02', license = 'license:h2',
            firstname = 'Second', lastname = 'Gun' })
        truthy(s.contracts.accept(s.identity.resolve(9), c.id, false))
        local hitmen = ask(6, 'overview').data.hitmen
        eq(hitmen.active, 2, 'two places')
        eq(hitmen.operatives, 2, 'two people')
        eq(hitmen.contracts, 1, 'one contract')
    end)

    --- A04: typedCitizenId read the index to decide the case, and the search
    --- read it again.
    it('reads the index once for a search typed in lower case', function()
        local s, f = stack()
        place(s, f)
        local real, reads = s.storage.contractsInvolving, 0
        s.storage.contractsInvolving = function(...) reads = reads + 1 return real(...) end
        ask(6, 'contracts', { query = 'dana' })
        eq(reads, 1, 'a name')
        reads = 0
        eq(ask(6, 'contracts', { query = 'target01' }).data.total, 1, 'a citizen id in lower case')
        eq(reads, 1)
        s.storage.contractsInvolving = real
    end)

    --- W148: counted with the rows not applied, the overview and the
    --- Settings section disagreed.
    it('counts the settings in force, and the ones not applied apart', function()
        local s = stack()
        s.storage.writeSetting('Bailout.MinMultiplier', 50, 'A', 1)
        s.settings.boot()
        local data = ask(6, 'overview').data
        eq(data.overrides, 0, 'none in force')
        eq(data.notApplied, 1)
        eq(ask(6, 'settings').data.overrides, 0, 'as the Settings section says')
        local report = table.concat(s.admin.diagnose(0), '\n')
        truthy(report:find('admin panel settings in force over config.lua: 0, and 1 not applied', 1, true),
            report)
    end)

    --- W190: a listing that raised left the tile saying recovery was running.
    it('says the stuck listing could not be read when it raises', function()
        local s = stack()
        local real = s.admin.interrupted
        s.admin.interrupted = function() error('connection lost', 0) end
        local data = ask(6, 'overview').data
        s.admin.interrupted = real
        eq(data.recovery, 'ready')
        eq(data.stuck and data.stuck.error, true)
    end)
end)
