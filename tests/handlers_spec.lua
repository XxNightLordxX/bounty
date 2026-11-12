--- The requests players and staff send most, on a busy server: what each
--- costs in store calls, and what it leaves for the collector.
---
--- Measured on the city tests/loops_spec.lua builds (200 live contracts,
--- each held, and 64 players), with the 'mysql' and 'json' backends, and
--- run with CH_PERF=1 to print the table docs/dev/loops.md's "The
--- requests" section quotes.

local Exec = require('tests.harness.mysql_exec')

local function forget()
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
            package.loaded[name] = nil
        end
    end
end

local function boot(mode, configure)
    forget()
    Env.reset()
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Natives.resetResourceStates()
    resetConfig()
    Config.Database.Mode = mode or 'memory'
    if mode == 'mysql' then Exec.install(Natives) end
    if mode == 'json' then Natives.files = {} end
    if configure then configure() end
    local main = require('server.main')
    return main, main.start()
end

--- 64 players: 20 who place, 20 they place on, 24 operatives; 200 live
--- contracts, each held by one operative. And an officer on the
--- whitelisted-job view, and a staff member with the admin ACE.
local function city(s)
    Config.Limits.MaxActiveContractsPerCreator = 10000
    Config.Limits.MaxActiveContractsPerTarget = 10000
    Config.Limits.SameCreatorSameTargetCooldownSeconds = 0
    Config.Immunity.MinTargetSessionMinutes = 0
    Config.Immunity.MinTargetPlaytimeHours = 0
    Config.Limits.MaxAcceptedPerHitman = 10000
    local creators, targets, ops = {}, {}, {}
    for i = 1, 20 do
        Env.addPlayer({ source = 100 + i, citizenid = ('CRE%05d'):format(i),
            license = ('license:cre%d'):format(i), cash = 90000000, bank = 90000000,
            firstname = 'Cre', lastname = ('Ator%d'):format(i) })
        creators[i] = s.identity.resolve(100 + i)
        Env.addPlayer({ source = 200 + i, citizenid = ('TGT%05d'):format(i),
            license = ('license:tgt%d'):format(i), cash = 100, bank = 100,
            firstname = 'Tar', lastname = ('Get%d'):format(i) })
        targets[i] = s.identity.resolve(200 + i)
    end
    for i = 1, 24 do
        Env.addPlayer({ source = 300 + i, citizenid = ('OPR%05d'):format(i),
            license = ('license:opr%d'):format(i), cash = 90000000, bank = 90000000,
            firstname = 'Op', lastname = ('Erative%d'):format(i) })
        ops[i] = s.identity.resolve(300 + i)
    end
    Env.addPlayer({ source = 401, citizenid = 'OFFICER1', license = 'license:off1',
        firstname = 'Otto', lastname = 'Beat', job = { name = 'police', type = 'leo', onduty = true } })
    Env.addPlayer({ source = 402, citizenid = 'ADMIN001', license = 'license:adm1',
        firstname = 'Sam', lastname = 'Steward' })
    Env.aces[402] = { ['crimson.admin'] = true }
    local made = {}
    for i = 1, 200 do
        local c = (i - 1) % 20
        local t = (c + 1 + math.floor((i - 1) / 20)) % 20
        local row = s.contracts.create(creators[c + 1], { targetCid = targets[t + 1].cid,
            reason = 'scale', anonymous = i % 3 == 0,
            reward = { baseline = { cash = 1000 + i, bank = 1000 } } })
        if row then
            made[#made + 1] = row.id
            truthy(s.contracts.accept(ops[(i - 1) % 24 + 1], row.id, i % 2 == 0), 'held')
        end
    end
    eq(#made, 200, 'two hundred live contracts')
    -- Past every reveal wait, so the targets see theirs.
    Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
    -- A message each way on the first contract.
    return { creators = creators, targets = targets, ops = ops, made = made }
end

--- No allowance or flood guard in the way of a measurement.
local function unlimited()
    for _, bucket in pairs(Config.Cooldowns) do
        bucket.per, bucket.burst = 1, 1000000
    end
end

--- Fire a net event as a player and answer the reply sent back.
local function call(name, src, payload)
    local fire = Env.events['crimson-hitman:' .. name]
    truthy(fire, 'no handler registered for ' .. name)
    local from = #Env.clientEvents
    _G.source = src
    fire(payload or {})
    _G.source = nil
    for i = from + 1, #Env.clientEvents do
        local event = Env.clientEvents[i]
        if (event.name == 'crimson-hitman:result' or event.name == 'crimson-hitman:adminResult')
            and event.target == src then
            return event.args[1]
        end
    end
end

local function admin(src, op, data)
    _G.source = src
    local from = #Env.clientEvents
    Env.events['crimson-hitman:admin']({ op = op, data = data or {}, __rid = 7 })
    _G.source = nil
    for i = from + 1, #Env.clientEvents do
        local event = Env.clientEvents[i]
        if event.name == 'crimson-hitman:adminResult' and event.target == src then
            return event.args[1]
        end
    end
end

--- Every store function wrapped in place, counting calls.
local function counting(storage)
    local counts, originals = {}, {}
    for name, fn in pairs(storage) do
        if type(fn) == 'function' then
            originals[name] = fn
            storage[name] = function(...)
                counts[name] = (counts[name] or 0) + 1
                return fn(...)
            end
        end
    end
    local function total()
        local n = 0
        for _, v in pairs(counts) do n = n + v end
        return n
    end
    return counts, total, function()
        for name, fn in pairs(originals) do storage[name] = fn end
    end, function() for k in pairs(counts) do counts[k] = nil end end
end

--- One request, `n` times: the median time in ms, the store calls of one,
--- and the KB it allocates (collector stopped while it runs).
local function measure(s, fn, n, before)
    n = n or 15
    local counts, total, restore, reset = counting(s.storage)
    local times, calls, kb = {}, nil, nil
    local ok, err = pcall(function()
        for i = 1, n do
            s.app.resetFloodCounters()
            if before then before(i) end
            reset()
            collectgarbage('collect')
            collectgarbage('stop')
            local before = collectgarbage('count')
            local started = os.clock()
            fn(i)
            times[i] = (os.clock() - started) * 1000
            local grew = collectgarbage('count') - before
            collectgarbage('restart')
            if i == n then calls, kb = total(), grew end
        end
    end)
    collectgarbage('restart')
    restore()
    if not ok then error(err, 0) end
    table.sort(times)
    local by = {}
    for k, v in pairs(counts) do by[#by + 1] = k .. '=' .. v end
    table.sort(by)
    return { ms = times[math.ceil(n / 2)], calls = calls, kb = kb, detail = table.concat(by, ' ') }
end

--- The requests measured, each as fun(s, w, i).
local function requests(w)
    local first = w.made[1]
    return {
        { 'list (board)', function() return call('list', 301, { page = 1 }) end },
        { 'list (after a write)', function() return call('list', 301, { page = 1 }) end,
            function(s) s.storage.clearBailout(first, -1) end },
        { 'mine (placer)', function() return call('mine', 101, {}) end },
        { 'mine (operative)', function() return call('mine', 301, {}) end },
        { 'mine (target)', function() return call('mine', 201, {}) end },
        { 'whitelistedView', function() return call('whitelistedView', 401, {}) end },
        { 'ledger', function() return call('ledger', 101, {}) end },
        { 'rewardOptions', function() return call('rewardOptions', 101, {}) end },
        { 'searchTargets', function() return call('searchTargets', 101, { query = 'get' }) end },
        { 'browseTargets', function() return call('browseTargets', 101, { page = 1 }) end },
        { 'threads', function() return call('threads', 101, { id = first }) end },
        { 'readThread', function() return call('readThread', 301, { id = first }) end },
        { 'sendMessage', function() return call('sendMessage', 301, { id = first, body = 'on my way' }) end },
        { 'admin overview', function(i)
            Env.time = Env.time + 6
            return admin(402, 'overview')
        end },
        { 'admin contracts', function() return admin(402, 'contracts', { page = 1 }) end },
        { 'admin contracts search', function() return admin(402, 'contracts', { query = 'get1' }) end },
        { 'admin logs', function() return admin(402, 'logs', {}) end },
    }
end

local function report(mode)
    local main, s = boot(mode)
    unlimited()
    local w = city(s)
    main.tick()
    local rows = {}
    for _, req in ipairs(requests(w)) do
        local reply
        local m = measure(s, function(i) reply = req[2](i) end, nil, req[3] and function() req[3](s) end)
        truthy(reply and reply.ok, req[1] .. ' answered: ' .. tostring(reply and (reply.err or reply.message)))
        rows[#rows + 1] = { name = req[1], m = m }
    end
    return rows, s, w
end

--- What 1000 requests, the mix a busy evening sends (the board most, then
--- Mine, a thread, the ledger, the view), allocate in all, in KB, with
--- the collector stopped so nothing is hidden by it running.
local function thousand(s, w)
    local first = w.made[1]
    local mix = {
        function(i) return call('list', 301 + (i % 24), { page = 1 }) end,
        function() return call('list', 101, { page = 1 }) end,
        function() return call('mine', 301, {}) end,
        function() return call('mine', 101, {}) end,
        function() return call('readThread', 301, { id = first }) end,
        function() return call('ledger', 101, {}) end,
        function() return call('whitelistedView', 401, {}) end,
        function() return call('threads', 101, { id = first }) end,
    }
    collectgarbage('collect')
    collectgarbage('stop')
    local before = collectgarbage('count')
    local started = os.clock()
    for i = 1, 1000 do
        s.app.resetFloodCounters()
        -- A write every tenth request, as players act between their reads.
        if i % 10 == 0 then s.storage.clearBailout(first, -1) end
        mix[i % #mix + 1](i)
        if i % 50 == 0 then Env.clientEvents = {} end
    end
    local kb, ms = collectgarbage('count') - before, (os.clock() - started) * 1000
    collectgarbage('restart')
    return kb, ms
end

if os.getenv('CH_PERF') then
    describe('handler costs (CH_PERF)', function()
        for _, mode in ipairs({ 'mysql', 'json' }) do
            it('measures ' .. mode, function()
                local rows, s, w = report(mode)
                io.write(('\n%s\n%-24s %8s %6s %9s\n'):format(mode, 'request', 'ms', 'calls', 'KB'))
                for _, r in ipairs(rows) do
                    io.write(('%-24s %8.2f %6d %9.1f  %s\n'):format(r.name, r.m.ms, r.m.calls, r.m.kb,
                        os.getenv('CH_PERF') == '2' and r.m.detail or ''))
                end
                local kb, ms = thousand(s, w)
                io.write(('1000 mixed requests: %.0f KB allocated, %.0f ms\n'):format(kb, ms))
            end)
        end
    end)
end

--------------------------------------------------------------------------
-- What is pinned
--------------------------------------------------------------------------

--- A value as one string, keys sorted, so two answers compare whole.
local function encode(value)
    if type(value) ~= 'table' then
        return type(value) == 'string' and ('%q'):format(value) or tostring(value)
    end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, key in ipairs(keys) do parts[#parts + 1] = tostring(key) .. '=' .. encode(value[key]) end
    return '{' .. table.concat(parts, ',') .. '}'
end

--- Store calls made by `fn`, by name, and their total.
local function storeCalls(s, fn)
    local counts, total, restore = counting(s.storage)
    local ok, err = pcall(fn)
    restore()
    if not ok then error(err, 0) end
    return counts, total()
end

--- The SELECTs the mysql harness ran inside `fn`.
local function selects(fn)
    local from = #Exec.statements
    fn()
    local n = 0
    for i = from + 1, #Exec.statements do
        if Exec.statements[i]:find('^SELECT') then n = n + 1 end
    end
    return n
end

describe('the board on a busy server', function()
    it('reads the store once per change, in four statements, and not at all for the next viewer', function()
        local main, s = boot('mysql')
        unlimited()
        local w = city(s)
        main.tick()
        s.storage.clearBailout(w.made[1], -1)   -- a write: whatever was kept is gone
        local counts, total
        local statements = selects(function()
            counts, total = storeCalls(s, function()
                truthy(call('list', 301, { page = 1 }).ok)
            end)
        end)
        eq(counts.liveContracts, 1, 'the running contracts, once')
        eq(counts.readEscrowMany, 1, 'every one\'s escrow in one read (it was 200 reads)')
        eq(counts.readHitmenMany, 1, 'the rows\' rosters in one read (it was 31)')
        eq(counts.readEscrow, nil)
        eq(counts.readHitmen, nil)
        eq(counts.readHitman, nil)
        -- And what is the viewer's own on a row they work (their tip, their
        -- thread): two reads here, the rest of the 232 gone.
        truthy(total <= 5, ('%d store calls for one board'):format(total))
        truthy(statements <= 6, ('%d SELECTs for one board (it was 232)'):format(statements))

        -- The next viewers read none of it again: only the rosters of rows
        -- nobody was shown yet (a target is not shown their own), and what
        -- is theirs on a row. A second look reads no roster either.
        for round = 1, 2 do
            for _, src in ipairs({ 302, 101, 201, 301 }) do
                local again = storeCalls(s, function() truthy(call('list', src, { page = 1 }).ok) end)
                for _, name in ipairs({ 'liveContracts', 'readEscrowMany', 'readEscrow',
                                        'readHitmen', 'readHitman' }) do
                    eq(again[name], nil, ('%s read again for viewer %d while nothing changed'):format(name, src))
                end
                if round == 2 then eq(again.readHitmenMany, nil, 'rosters kept for viewer ' .. src) end
            end
        end
    end)

    it('shows a change at the next open, wherever it lands on the board', function()
        local main, s = boot('json')
        unlimited()
        local w = city(s)
        main.tick()
        local before = call('list', 302, { page = 1 }).data
        local last = before.contracts[#before.contracts]
        local c = s.storage.readContract(last.id)
        local placer
        for i = 1, #w.creators do if w.creators[i].cid == c.creator_cid then placer = w.creators[i] end end
        local raised, why = s.amendments.addEscrow(placer, last.id, { baseline = { cash = 20000 } })
        truthy(raised, 'raised: ' .. tostring(why))
        local after = call('list', 302, { page = 1 }).data
        eq(after.contracts[1].id, last.id, 'it heads the board at once')
        truthy(after.contracts[1].reward.baseline > last.reward.baseline, 'at its new price')
    end)

    --- The board kept between viewers holds the store's rows and nothing
    --- worked out for one viewer. Every viewer's answer read from it is the
    --- answer they get from a fresh read: their role, what they may see of
    --- an anonymous party, why they may not take one.
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(('answers every viewer exactly as a fresh read does, on %s'):format(mode), function()
            local main, s = boot(mode)
            unlimited()
            city(s)
            main.tick()
            local viewers = { 101, 102, 201, 202, 301, 302, 324, 401 }
            local function answers(cold)
                local out = {}
                local function ask(name, src, payload)
                    if cold then s.storage.clearBailout('ct0', -1) end
                    local reply = call(name, src, payload)
                    out[#out + 1] = encode(reply)
                end
                for _, src in ipairs(viewers) do
                    ask('list', src, { page = 1 })
                    ask('list', src, { page = 2 })
                    ask('mine', src, {})
                    ask('whitelistedView', src, {})
                end
                return out
            end
            local cold, warm = answers(true), answers(false)
            eq(#cold, #warm)
            for i = 1, #cold do
                eq(warm[i], cold[i], 'answer ' .. i .. ' differs read from the kept board')
            end
        end)
    end

    --- The same with the board improvements on (server/imp_*.lua): the
    --- placer's record (kept per change for named placers, fixed per
    --- contract for anonymous ones), the tier lock (per viewer, from their
    --- own record) and contract decay (the placer's own card). What one
    --- viewer is shown is never another's, and a change shows at once.
    local function improvementsOn()
        local imp, rec = Config.Improvements, Config.Record
        rec.PlacerRecord.Enabled, rec.PlacerRecord.ShowForAnonymous = true, true
        rec.Tiers.Enabled, rec.Tiers.Tiers = true, { 'Mid, 2150, 2', 'Top, 2190, 3' }
        imp.ContractDecay.Enabled, rec.Heat.Enabled = true, true
    end

    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(('answers every viewer exactly as a fresh read does with the board improvements on, on %s')
            :format(mode), function()
            local main, s = boot(mode, improvementsOn)
            unlimited()
            local w = city(s)
            main.tick()
            -- A few operatives with a record, so the tier lock differs by viewer.
            s.storage.bumpStat('OPR00001', 'completed', 10)
            s.storage.bumpStat('OPR00002', 'completed', 5)
            local viewers = { 101, 102, 201, 202, 301, 302, 324, 401 }
            local function answers(cold)
                local out = {}
                local function ask(name, src, payload)
                    if cold then s.storage.clearBailout('ct0', -1) end
                    out[#out + 1] = encode(call(name, src, payload))
                end
                for _, src in ipairs(viewers) do
                    ask('list', src, { page = 1 })
                    ask('list', src, { page = 2 })
                    ask('mine', src, {})
                end
                return out
            end
            local cold, warm = answers(true), answers(false)
            eq(#cold, #warm)
            for i = 1, #cold do
                eq(warm[i], cold[i], 'answer ' .. i .. ' differs read from the kept board')
            end
            -- Every card carries what it should, and only to its viewer.
            local rows = call('list', 324, { page = 1 }).data.contracts
            local records, locked = 0, 0
            for _, row in ipairs(rows) do
                if row.placerRecord then records = records + 1 end
                if row.tierLocked then locked = locked + 1 end
                if row.creatorAnonymous and row.placerRecord then
                    truthy(row.placerRecord.banded, 'an anonymous placer only in bands')
                end
            end
            truthy(records > 0, 'records on the board')
            truthy(locked > 0, 'locked cards for a level-1 operative')
            local senior = call('list', 301, { page = 1 }).data.contracts
            for _, row in ipairs(senior) do
                eq(row.tierLocked, nil, 'nothing locked for a level-3 operative')
            end
            -- Nothing changed: a second look reads no placer's contracts again.
            local again = storeCalls(s, function() truthy(call('list', 302, { page = 1 }).ok) end)
            eq(again.contractsBy, nil, 'the named placers\' records kept while nothing changed')
            -- A change shows at once: a named placer's contract withdrawn.
            local before = call('list', 302, { page = 1 }).data.contracts[1]
            local named
            for _, row in ipairs(call('list', 302, { page = 1 }).data.contracts) do
                if not row.creatorAnonymous and row.placerRecord then named = row break end
            end
            truthy(named, 'a named placer on the first page')
            local c = s.storage.readContract(named.id)
            local placer
            for i = 1, #w.creators do if w.creators[i].cid == c.creator_cid then placer = w.creators[i] end end
            local extra = s.contracts.create(placer, { targetCid = w.targets[20].cid, reason = 'one more',
                reward = { baseline = { cash = 1500 } } })
            truthy(extra, 'placed')
            truthy(s.contracts.cancel(placer, extra.id), 'and withdrawn')
            local after
            for _, row in ipairs(call('list', 302, { page = 1 }).data.contracts) do
                if row.id == named.id then after = row end
            end
            truthy(after, 'still listed')
            eq(after.placerRecord.placed, named.placerRecord.placed + 1, 'one more placed, seen at once')
            eq(after.placerRecord.cancelled, named.placerRecord.cancelled + 1, 'and cancelled')
            truthy(before)
        end)
    end
end)

describe('a player\'s own tabs on mysql', function()
    it('read each contract\'s escrow and roster once, in one statement each', function()
        local main, s = boot('mysql')
        unlimited()
        local w = city(s)
        main.tick()
        for _, src in ipairs({ 101, 201, 301 }) do
            s.storage.clearBailout(w.made[1], -1)
            local counts = storeCalls(s, function() truthy(call('mine', src, {}).ok) end)
            eq(counts.readHitman, nil, src .. ': no row read one contract at a time')
            eq(counts.readHitmen, nil, src)
            eq(counts.readEscrow, nil, src)
            truthy((counts.readHitmenMany or 0) <= 2, src .. ': rosters in one read a tab at most')
            truthy((counts.readEscrowMany or 0) <= 2, src .. ': escrow in one read a tab at most')
            truthy((counts.readStats or 0) <= 6, src .. ': an operative\'s record once')
        end
    end)
end)

describe('pushes in one tick', function()
    local function pushes(src)
        Env.runTimers()
        local out = {}
        for _, e in ipairs(Env.clientEvents) do
            if e.name == 'crimson-hitman:push' and e.target == src then out[#out + 1] = e.args[1] end
        end
        return out
    end

    it('go as one per player, about every contract the tick changed', function()
        local main, s = boot('json')
        unlimited()
        local w = city(s)
        main.tick()
        Env.advance(10)
        Env.clientEvents = {}
        local ids = {}
        for k = 1, 3 do
            local row = s.contracts.create(w.creators[1], { targetCid = w.targets[14 + k].cid,
                reason = 'x', reward = { baseline = { cash = 1000 } } })
            truthy(row, 'placed')
            truthy(s.contracts.accept(w.ops[1], row.id, false), 'taken')
            ids[#ids + 1] = row.id
        end
        table.sort(ids)
        local toClient, toOperative = pushes(101), pushes(301)
        eq(#toClient, 1, 'three placed and three taken: one refresh, not two')
        eq(#toOperative, 1)
        eq(table.concat(toClient[1].ids or {}, ','), table.concat(ids, ','),
            'about every contract the tick changed')
        -- Nothing behind the floor for it: the refresh reads all of it.
        Env.advance(5)
        eq(#pushes(101), 1, 'and no second push after it')
    end)

    it('keeps the floor: the next tick inside it is held and goes once, after it', function()
        local main, s = boot('json')
        unlimited()
        local w = city(s)
        main.tick()
        Env.advance(10)
        Env.clientEvents = {}
        truthy(s.notify.push(w.creators[1].cid, 'accepted', w.made[1]))
        eq(#pushes(101), 1, 'the first goes at the end of its tick')
        falsy(s.notify.push(w.creators[1].cid, 'proposal', w.made[2]), 'held by the floor')
        s.notify.push(w.creators[1].cid, 'amended', w.made[3])
        eq(#pushes(101), 1, 'not inside the floor')
        Env.advance(Config.Notifications.PushMinIntervalSeconds + 1)
        local got = pushes(101)
        eq(#got, 2, 'one more once the floor passed')
        eq(got[2].reason, 'amended')
        eq(#(got[2].ids or {}), 2, 'about both')
    end)
end)

describe('the admin panel\'s contract list with a player frozen', function()
    --- Sweep 6 J-2: the On hold badge read each row's roster twice once
    --- anybody was frozen (frozenShown, partiesOf): 1 statement became 26 to
    --- 32 on a 28-row page, and the player view's list the same. One read
    --- of the page's rosters now, whoever is frozen.
    it('reads the page\'s rosters in one statement, not two a row', function()
        local main, s = boot('mysql')
        unlimited()
        city(s)
        main.tick()
        local idle = selects(function() truthy(admin(402, 'contracts', { page = 1 }).ok) end)
        Env.addPlayer({ source = 499, citizenid = 'BYSTAND1', license = 'license:bys1' })
        truthy(s.holds.freeze('ADMIN001', 'BYSTAND1', 'unrelated'))
        truthy(admin(402, 'contracts', { page = 1 }).ok)
        local frozen = selects(function() truthy(admin(402, 'contracts', { page = 1 }).ok) end)
        truthy(frozen <= idle + 2, ('%d statements with one player frozen, %d with none'):format(frozen, idle))
        local search = selects(function() truthy(admin(402, 'contracts', { query = 'get1' }).ok) end)
        truthy(search <= idle + 4, ('the search sent %d statements with one player frozen'):format(search))
    end)
end)

describe('an admin panel reply\'s size', function()
    it('is counted without encoding it, close enough to say which side of the line it falls', function()
        local main, s = boot('json')
        unlimited()
        city(s)
        main.tick()
        local real = json.encode
        local encoded = 0
        json.encode = function(...) encoded = encoded + 1 return real(...) end
        local replies = {}
        local ok, err = pcall(function()
            for _, op in ipairs({ 'overview', 'contracts', 'logs', 'stuck', 'alerts' }) do
                replies[#replies + 1] = admin(402, op, {})
            end
        end)
        json.encode = real
        truthy(ok, tostring(err))
        eq(encoded, 0, 'no reply encoded only to be measured')
        local panel = require('server.panel')
        for _, reply in ipairs(replies) do
            local size = #real(reply)
            truthy(panel.over(reply, math.floor(size * 0.9)), reply.op .. ' counted short of ' .. size)
            falsy(panel.over(reply, math.ceil(size * 1.1)), reply.op .. ' counted past ' .. size)
        end
    end)
end)

describe('a thousand requests', function()
    --- Measured at about 40 MB on json and 98 MB on mysql (the harness's
    --- database copies every row it answers) where it was 103 and 514.
    --- The ceilings leave room for a different machine's allocator, and not
    --- for the board to go back to reading per contract.
    for _, case in ipairs({ { 'json', 60000 }, { 'mysql', 160000 } }) do
        local mode, ceiling = case[1], case[2]
        it(('allocate under %d KB on %s, the board read once per change'):format(ceiling, mode), function()
            local main, s = boot(mode)
            unlimited()
            local w = city(s)
            main.tick()
            local kb = thousand(s, w)
            truthy(kb < ceiling, ('%.0f KB for 1000 requests on %s'):format(kb, mode))
        end)
    end
end)
