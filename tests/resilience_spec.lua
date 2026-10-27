--- One bad thing must not take everything with it.
---
--- Found by an adversarial audit of why the app kept showing an empty
--- target list and an empty item picker on a live server while 680 tests
--- passed. Each of these turns one local failure into the whole feature
--- going silent, and none of them is visible from a harness where nothing
--- ever throws.

local function call(name, source, payload)
    local fire = Env.events['crimson-hitman:' .. name]
    if not fire then return nil, 'no handler registered for ' .. name end
    Env.clientEvents = {}
    _G.source = source
    local ok, err = pcall(fire, payload or {})
    _G.source = nil
    if not ok then return nil, 'THREW: ' .. tostring(err) end
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:result' then return event.args[1] end
    end
    return nil
end

describe('one player the framework cannot describe', function()
    local function crowd(s)
        local f = fixture(s)
        Env.addPlayer({ source = 10, citizenid = 'PERSON10', license = 'license:p10',
            firstname = 'Ada', lastname = 'Quill' })
        Env.addPlayer({ source = 11, citizenid = 'PERSON11', license = 'license:p11',
            firstname = 'Bo', lastname = 'Renn' })
        return f
    end

    --- A source that is connected but whose character record is not there
    --- yet, or a framework export that raises for it. Ordinary on a live
    --- server: somebody is always mid-join.
    local function withOneBadPlayer(badSource, fn)
        local real = exports.qbx_core.GetPlayer
        exports.qbx_core.GetPlayer = function(self, src)
            if tonumber(src) == badSource then
                error('qbx_core: player is not loaded')
            end
            return real(self, src)
        end
        local ok, err = pcall(fn)
        exports.qbx_core.GetPlayer = real
        if not ok then error(err, 0) end
    end

    it('does not empty the roster for everybody else', function()
        local s = newStack()
        crowd(s)
        withOneBadPlayer(11, function()
            local online = s.identity.online()
            truthy(#online >= 2,
                'one player mid-join must not take the whole roster with them, '
                .. 'got ' .. #online)
        end)
    end)

    it('still lists the others when browsing', function()
        local s = newStack()
        crowd(s)
        withOneBadPlayer(11, function()
            local reply = call('browseTargets', 1, { scope = 'all' })
            truthy(reply and reply.ok,
                'the handler must answer: ' .. tostring(reply and reply.err))
            truthy(#reply.data.people > 0,
                'the city is not empty because one person is still loading')
        end)
    end)

    it('leaves out only the one it could not read', function()
        local s = newStack()
        crowd(s)
        withOneBadPlayer(11, function()
            local names = {}
            for _, person in ipairs(call('browseTargets', 1, { scope = 'all' }).data.people) do
                names[person.name] = true
            end
            truthy(names['Ada Quill'], 'the readable ones are all there')
            falsy(names['Bo Renn'], 'and the unreadable one is simply absent')
        end)
    end)
end)

describe('a request the gate itself cannot process', function()
    it('is still answered', function()
        -- The gate runs before the handler's pcall, so a throw inside it
        -- left the request with no reply at all — and the page waits fifteen
        -- seconds on every request it sends.
        local s = newStack()
        fixture(s)

        local real = s.identity.gate
        s.identity.gate = function() error('something in the framework broke') end
        local reply, why = call('list', 1, { page = 1 })
        s.identity.gate = real

        truthy(reply, 'no answer came back: ' .. tostring(why))
        falsy(reply.ok, 'and it is a refusal, not a success')
    end)

    it('does not take the whole event handler down with it', function()
        local s = newStack()
        fixture(s)
        local real = s.identity.gate
        s.identity.gate = function() error('boom') end
        local _, why = call('list', 1, { page = 1 })
        s.identity.gate = real
        falsy(why and why:find('THREW', 1, true),
            'the handler threw out to the engine: ' .. tostring(why))
    end)
end)

--- An lb-phone build without the word filter.
---
--- The resource states its own rule twice — in client/main.lua and in the
--- static check that enforces it — that lb-phone ships its server code
--- escrowed, its export surface has moved across releases, and indexing an
--- export that is not there throws. The check walked only the client. The
--- server broke the rule in two places, and comms.lua guards an export a
--- hundred and ninety lines below the one it does not.
---
--- Both are inside handlers, so the throw is not a degraded feature: it is
--- every contract refused with server_error and every message the same.
describe('a phone build with no word filter', function()
    local function withoutFilter(fn)
        Natives.noWordFilter = true
        local ok, err = pcall(fn)
        Natives.noWordFilter = nil
        if not ok then error(err, 0) end
    end

    it('still places a contract', function()
        local s = newStack()
        local f = fixture(s)
        withoutFilter(function()
            local c, err = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'Unpaid debt',
                mode = CH.MODE.EXCLUSIVE,
                reward = { baseline = { cash = 5000 } },
            })
            truthy(c, 'an export this build does not have took the whole '
                .. 'resource down: ' .. tostring(err))
        end)
    end)

    it('still applies the rules this resource owns', function()
        local s = newStack()
        local f = fixture(s)
        withoutFilter(function()
            local c, err, refusal = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'come to discord.gg/whatever',
                mode = CH.MODE.EXCLUSIVE,
                reward = { baseline = { cash = 5000 } },
            })
            falsy(c, 'the pattern denylist is this resource\'s own and does '
                .. 'not depend on the phone')
            -- A reason refused for what it says answers reason_refused with
            -- the rule it broke (server/contracts.lua reasonFor, W010).
            eq(err, CH.ERR.REASON_REFUSED)
            eq(refusal and refusal.rule, 'pattern', 'refused by the denylist, not the phone')
        end)
    end)

    it('still carries a message between the two parties', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        s.contracts.accept(f.hitman, c.id, false)
        -- The creator addresses a thread; only the hitman's side may leave
        -- it implicit, because they have exactly one.
        local threads = s.comms.threads(f.creator, c.id)
        truthy(#threads > 0, 'there has to be somebody to write to')
        withoutFilter(function()
            local ok, err = s.comms.send(f.creator, c.id, threads[1].handle,
                'Where are you?')
            truthy(ok, 'the relay went down with an export it does not need: '
                .. tostring(err))
        end)
    end)

    it('still refuses what the phone refuses, where the phone is there', function()
        local s = newStack()
        local f = fixture(s)
        local c, err, refusal = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'you absolute slur',
            mode = CH.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 5000 } },
        })
        falsy(c, 'a build that has the filter must still use it')
        eq(err, CH.ERR.REASON_REFUSED)
        eq(refusal and refusal.rule, 'phone', 'refused by the phone\'s own filter')
    end)
end)

--- The harness's own outage: a database that stops answering, and one that
--- answers after the caller stopped waiting (tests/harness/mysql_exec.lua).
--- Later suites hold the store to both, so these hold the harness to what
--- oxmysql does (docs/oxmysql.md §6): an await on a database that is gone is
--- never answered and parks only its own thread; a statement already sent
--- can still land after its caller gave up on it.
describe('the harness can leave an await unanswered, or answer it late', function()
    local Exec = require('tests.harness.mysql_exec')

    -- With no limit on an await (QueryTimeoutSeconds = 0), as oxmysql has
    -- none: these hold the harness, not the store's own bounds, which the
    -- next describe holds.
    local function store()
        newStack()
        Config.Database.QueryTimeoutSeconds = 0
        Exec.install(Natives)
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local m = require('crimson-hitman.server.storage.mysql')
        m.open()
        return m
    end

    local function contract(id)
        return { id = id, creator_cid = 'CREATOR1', target_cid = 'TARGET01',
                 mode = CH.MODE.EXCLUSIVE, state = CH.STATE.ACTIVE,
                 created_at = os.time(), payout_slots = 1, next_slot = 1 }
    end

    it('parks only the thread whose statement went out while the database was down', function()
        local m = store()
        m.writeContract(contract('c1'))
        Exec.down = true
        local reader = Env.spawn(function() return m.readContract('c1') end)
        falsy(reader.done, 'the read is waiting')
        -- The statement's own thread, and its caller waiting on it
        -- (server/storage/mysql.lua runs every statement in a thread of its own).
        eq(#Env.parked, 2, 'parked in Citizen.Await')

        local fired = false
        SetTimeout(500, function() fired = true end)
        Env.advance(1)
        truthy(fired, 'the rest of the server goes on: a timer still fires')

        Exec.down = false
        truthy(m.readContract('c1'), 'a statement sent once it is back is answered')
        Env.advance(60)
        falsy(reader.done, 'and the one sent while it was down never is')

        Exec.down = true
        local ok, err = pcall(m.readContract, 'c1')
        falsy(ok, 'outside a coroutine nothing could resume it')
        truthy(tostring(err):find('outside a coroutine', 1, true), tostring(err))

        local answered = false
        MySQL.query('SELECT * FROM crimson_contracts WHERE id = ?', { 'c1' },
            function() answered = true end)
        falsy(answered, 'a direct call is lost too')
        eq(Exec.lost[#Exec.lost], 'SELECT * FROM crimson_contracts WHERE id = ?')
    end)

    it('lands a held write after its caller moved on', function()
        local m = store()
        Exec.lateNext = 1
        local writer = Env.spawn(function()
            m.writeContract(contract('c2'))
            return 'written'
        end)
        falsy(writer.done, 'the write is waiting on its answer')
        eq(m.readContract('c2'), nil, 'and has not landed')

        m.writeContract(contract('c3'))
        truthy(m.readContract('c3'), 'the next statement is not held')

        eq(Exec.releaseLate(), 1)
        truthy(m.readContract('c2'), 'it lands when the test lets it')
        falsy(writer.done, 'its caller resumes on the next tick, not inside the landing')
        Env.runTimers()
        truthy(writer.done)
        eq(writer.results[1], 'written')
    end)

    it('keeps the first answer an await got, and lands the write all the same', function()
        local m = store()
        Exec.lateNext = 1
        local writer = Env.spawn(function()
            return pcall(m.writeContract, contract('c4'))
        end)
        -- The caller's own timeout answers first, as a bounded await would.
        Exec.late[1].promise:reject('timed out')
        Env.runTimers()
        truthy(writer.done)
        falsy(writer.results[1], 'the caller was told it timed out')
        truthy(tostring(writer.results[2]):find('timed out', 1, true), tostring(writer.results[2]))

        Exec.releaseLate()
        truthy(m.readContract('c4'), 'the write it gave up on still landed')
        eq(Exec.late[1], nil)
    end)

    it('keeps what the database refused, in oxmysql\'s words, as its console would', function()
        local m = store()
        local answered = false
        MySQL.query('INSERT INTO crimson_audit (ts, kind, action) VALUES (?, ?, ?)',
            { os.time(), nil, 'x' }, function() answered = true end)
        falsy(answered, 'a direct call the database refuses is never answered')
        eq(#Exec.refused, 1)
        truthy(Exec.refused[1]:find('was unable to execute a query!', 1, true), Exec.refused[1])
        truthy(Exec.refused[1]:find("Column 'kind' cannot be null", 1, true), Exec.refused[1])
        local ok, err = pcall(m.writeAudit, { ts = os.time(), action = 'x', detail = {} })
        falsy(ok, 'an awaited one raises')
        eq(Exec.refused[2], err, 'and is kept too')
    end)

    it('has a timer that can be cleared, and a string KVP on the same store', function()
        newStack()
        local fired = {}
        local a = SetTimeout(100, function() fired[#fired + 1] = 'a' end)
        SetTimeout(100, function() fired[#fired + 1] = 'b' end)
        ClearTimeout(a)
        Env.advance(1)
        eq(table.concat(fired, ','), 'b', 'the cleared timer never fired')

        SetResourceKvp('crimson:review:1', '{"id":1}')
        SetResourceKvp('crimson:review:2', '{"id":2}')
        SetResourceKvpInt('other', 3)
        eq(GetResourceKvpString('crimson:review:1'), '{"id":1}')
        eq(GetResourceKvpString('other'), nil, 'a number is not a string')
        local handle, keys = StartFindKvp('crimson:review:'), {}
        local key = FindKvp(handle)
        while key do
            keys[#keys + 1] = key
            DeleteResourceKvp(key)
            key = FindKvp(handle)
        end
        EndFindKvp(handle)
        eq(table.concat(keys, ','), 'crimson:review:1,crimson:review:2')
        eq(GetResourceKvpString('crimson:review:2'), nil, 'deleted on the way')
    end)
end)

--- S14, S15, S16: the store's own bounds (server/storage/mysql.lua). A
--- statement oxmysql never answers used to park whatever was waiting on it
--- for good: a payment caught between its charge and its first write was
--- gone with no record, the request was never answered, its busy keys were
--- never let go, and a maintenance tick caught in one was the last.
describe('the database stops answering (mysql)', function()
    local Exec = require('tests.harness.mysql_exec')

    local function boot()
        for name in pairs(package.loaded) do
            if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
                package.loaded[name] = nil
            end
        end
        Env.reset()
        Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
        Natives.resetResourceStates()
        resetConfig()
        -- A fresh disk, and this machine's KVP with it.
        Natives.files = {}
        Config.Database.Mode = 'mysql'
        Exec.install(Natives)
        local main = require('server.main')
        return main, main.start()
    end

    local function money(src)
        local m = Env.players[src].PlayerData.money
        return m.cash + m.bank
    end

    local function itemsOf(s, kind)
        local out = {}
        for _, item in ipairs(s.review.list(false, 50)) do
            if item.kind == kind then out[#out + 1] = item end
        end
        return out
    end

    --- What this machine keeps (resource KVP) of the payments the store
    --- could not take: what is there to settle while the store is down.
    local function keptOnMachine(kind)
        local n = 0
        local handle = StartFindKvp('reviewKept:mysql:')
        local key = FindKvp(handle)
        while key do
            if GetResourceKvpString(key):find(kind, 1, true) then n = n + 1 end
            key = FindKvp(handle)
        end
        EndFindKvp(handle)
        return n
    end

    --- The database back: the next thing that asks the store (the
    --- condition sampler does, every second) starts the probe that closes
    --- the breaker, and is itself refused.
    local function back(s)
        Exec.down = false
        Env.advance(5)
        pcall(s.storage.readContract, 'ct-asking')
        truthy(s.storage.healthy(), 'the probe found it answering')
    end

    local function place(s, f, extra)
        local spec = { targetCid = 'TARGET01', reason = 'x', reward = { baseline = { bank = 5000 } } }
        for k, v in pairs(extra or {}) do spec[k] = v end
        return s.contracts.create(f.creator, spec)
    end

    it('a buyout whose record gets no answer is answered in time, kept, and settled once it answers', function()
        local main, s = boot()
        local f = fixture(s)
        Env.players[2].PlayerData.money.bank = 100000
        local c = place(s, f, { reward = { baseline = { cash = 10000 } }, bailoutAmount = 15000 })
        truthy(c)
        local before = money(2)
        local real = s.storage.recordBailout
        s.storage.recordBailout = function(...) Exec.down = true return real(...) end
        Env.clientEvents = {}
        _G.source = 2
        local buying = Env.spawn(Env.events['crimson-hitman:bailout'], { id = c.id, __rid = 9 })
        _G.source = nil
        Env.advance(14)
        s.storage.recordBailout = real
        truthy(buying.done, 'never answered: the page gave up after 15 s')
        local reply
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:result' then reply = event.args[1] end
        end
        truthy(reply and not reply.ok, 'refused')
        eq(reply.err, CH.ERR.DB_TIMEOUT, 'said as the database not answering')
        eq(money(2), before - 15000, 'the premium taken')
        eq(keptOnMachine('bailout_unrecorded'), 1, 'and its record kept on this machine')

        back(s)
        for _ = 1, 3 do
            Env.advance(10)
            main.tick()
        end
        eq(#itemsOf(s, 'bailout_unrecorded'), 0, 'settled by the server once it answers')
        local now = s.storage.readContract(c.id)
        truthy(money(2) == before or now.bailout_paid_by == 'TARGET01'
            or now.state == CH.STATE.BAILED_OUT, 'the premium is recorded or back with the target')
    end)

    it('a create whose escrow write is given up on is handed back once, and its late landing adds nothing', function()
        local main, s = boot()
        local f = fixture(s)
        local before = money(1)
        local real = s.storage.insertEscrow
        s.storage.insertEscrow = function(...)
            s.storage.insertEscrow = real
            Exec.lateNext = 1
            return real(...)
        end
        local creating = Env.spawn(function() return pcall(place, s, f) end)
        Env.advance(11)
        truthy(creating.done, 'answered at the limit')
        falsy(creating.results[1])
        truthy(s.storage.timedOut(creating.results[2]), tostring(creating.results[2]))
        eq(money(1), before - 5000, 'not handed back on what a read found while it may still land')

        main.tick()
        eq(money(1), before, 'handed back by the server, which wrote the lines again')
        eq(Exec.releaseLate(), 1, 'the original lands now')
        Env.runTimers()
        main.tick()
        s.contracts.retryStuckCreates()
        s.contracts.recoverNeverPlaced()
        eq(money(1), before, 'once')
    end)

    it('a take write that lost its connection is left undecided, not refunded on a read', function()
        local main, s = boot()
        local f = fixture(s)
        local before = money(1)
        local real = s.storage.insertEscrow
        s.storage.insertEscrow = function()
            s.storage.insertEscrow = real
            error('Connection lost: The server closed the connection.', 0)
        end
        falsy(pcall(place, s, f))
        eq(money(1), before - 5000, 'it may have committed, so nothing was handed back on a read')
        eq(#itemsOf(s, 'escrow_take_unverified'), 1)
        main.tick()
        eq(money(1), before, 'the server wrote it again and handed it back')
    end)

    it('an acceptance caught in it lets go of the contract once it is answered', function()
        local main, s = boot()
        local f = fixture(s)
        local creator, hitman = money(1), money(3)
        local c = place(s, f, { penaltyAmount = 1000 })
        truthy(c)
        local real = s.storage.insertEscrow
        s.storage.insertEscrow = function(...)
            s.storage.insertEscrow = real
            Exec.down = true
            return real(...)
        end
        local accepting = Env.spawn(function() return pcall(s.contracts.accept, f.hitman, c.id) end)
        Env.advance(14)
        truthy(accepting.done, 'answered within the page\'s wait')
        falsy(accepting.results[1])
        back(s)
        for _ = 1, 2 do
            Env.advance(10)
            main.tick()
        end
        local ok, err = s.contracts.cancel(f.creator, c.id)
        truthy(ok, 'the contract was held busy for good: ' .. tostring(err))
        eq(money(1), creator, 'the reward back')
        eq(money(3), hitman, 'and the stake')
    end)

    it('a maintenance tick caught in it finishes, and the next expires what fell due', function()
        local main, s = boot()
        local f = fixture(s)
        local c = place(s, f)
        truthy(c)
        Exec.down = true
        local ticking = Env.spawn(main.tick)
        Env.advance(14)
        truthy(ticking.done, 'parked for good on the first statement nobody answered')
        back(s)
        Env.advance(s.storage.readContract(c.id).expires_at - os.time() + 61)
        main.tick()
        main.tick()
        eq(s.storage.readContract(c.id).state, CH.STATE.EXPIRED)
        eq(s.storage.lastHeartbeat(), os.time(), 'and the heartbeat goes on')
    end)
end)
