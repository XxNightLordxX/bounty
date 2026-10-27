--- What the maintenance tick costs on the json store, counted in file
--- operations and framework lookups rather than time: the same number on
--- every machine, and on a Windows host each file operation is the cost.
---
---   * the heartbeat is one plain SaveResourceFile, at most once a minute,
---     and the downtime the next start dates from it is still never charged
---     to a deadline;
---   * the expiry pass asks qbx_core once a pass for each party, however many
---     contracts name them, and reads no contract row again that it leaves as
---     it is;
---   * the access check reads only the job, not every player's account and
---     name;
---   * the flush encodes only the playtime rows that changed, and on a server
---     whose rename keeps a taken name (Windows) a whole-file swap stops
---     making the two file operations that fail there every time.

local function forget()
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
            package.loaded[name] = nil
        end
    end
end

local function bootJson(configure)
    forget()
    Env.reset()
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Natives.resetResourceStates()
    resetConfig()
    Config.Database.Mode = 'json'
    if configure then configure() end
    Natives.files = {}
    local main = require('server.main')
    return main, main.start()
end

--- The same disk after the process died: no stop, no flush. The players
--- stay connected, as they do through a resource restart.
local function restart(old)
    if old and old.storage then rawset(old.storage, '__rawFixture', true) end
    forget()
    Env.events, Env.clientEvents, Env.notifications = {}, {}, {}
    Env.handlers, Env.threads, Env.timers, Env.commands = {}, {}, {}, {}
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Config.Database.Mode = 'json'
    local main = require('server.main')
    return main, main.start()
end

--- Every file operation in `fn`, by kind, and the files written.
local function fileOps(fn)
    local ops = { save = 0, load = 0, rename = 0, remove = 0, written = {} }
    local save, load, rename, remove = SaveResourceFile, LoadResourceFile, os.rename, os.remove
    _G.SaveResourceFile = function(res, file, ...)
        ops.save = ops.save + 1
        ops.written[#ops.written + 1] = file
        return save(res, file, ...)
    end
    _G.LoadResourceFile = function(...) ops.load = ops.load + 1 return load(...) end
    os.rename = function(...) ops.rename = ops.rename + 1 return rename(...) end
    os.remove = function(...) ops.remove = ops.remove + 1 return remove(...) end
    local ok, err = pcall(fn)
    _G.SaveResourceFile, _G.LoadResourceFile, os.rename, os.remove = save, load, rename, remove
    if not ok then error(err, 0) end
    return ops
end

local function heartbeatOf()
    local raw = Natives.files['data/heartbeat.json']
    return raw and tonumber(raw:match('"at":(%d+)')) or nil
end

local function writesOf(ops, file)
    local n = 0
    for _, written in ipairs(ops.written) do
        if written == file or written == file .. '.new' then n = n + 1 end
    end
    return n
end

--------------------------------------------------------------------------
-- The heartbeat
--------------------------------------------------------------------------

describe('the json heartbeat', function()
    it('is one plain SaveResourceFile: no copy, no read-back, no rename', function()
        local _, s = bootJson()
        local ops = fileOps(function() s.storage.heartbeat(os.time(), true) end)
        eq(ops.save, 1, 'one write')
        eq(ops.written[1], 'data/heartbeat.json', 'to the file itself, not a copy')
        eq(ops.load, 0, 'nothing read back')
        eq(ops.rename + ops.remove, 0, 'nothing renamed or removed')
        eq(heartbeatOf(), os.time())
    end)

    it('is written at most once a minute by the tick, and at the start and the stop whatever', function()
        local main, s = bootJson()
        local started = os.time()
        eq(heartbeatOf(), started, 'the start writes it')
        local writes = 0
        for _ = 1, 12 do
            Env.time = Env.time + 10
            local ops = fileOps(function() main.tick() end)
            writes = writes + writesOf(ops, 'data/heartbeat.json')
        end
        eq(writes, 2, 'two minutes of ticks wrote it twice, not twelve times')
        eq(heartbeatOf(), started + 120, 'and it stands at the last minute')
        Env.time = Env.time + 10
        Env.handlers['onResourceStop'](GetCurrentResourceName())
        eq(heartbeatOf(), started + 130, 'a stop writes it to the second')
        truthy(s.storage, 'the stack it stopped')
    end)

    it('dates a crash no later than it happened, and never charges a deadline for it', function()
        local main, s = bootJson(function()
            Config.Limits.ExclusiveIdleReleaseSeconds = 0
            Config.Limits.ExclusiveAttemptWindowSeconds = 0
        end)
        local f = fixture(s)
        local early = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } } })
        truthy(early)
        main.tick()
        local stamp = heartbeatOf()
        -- Placed after the last heartbeat, then the process dies 50 seconds
        -- after it: the stamp is up to a minute behind the crash.
        Env.time = Env.time + 30
        Env.addPlayer({ source = 4, citizenid = 'TARGET02', license = 'license:eee',
            firstname = 'Lee', lastname = 'Park' })
        local late = s.contracts.create(f.creator, { targetCid = 'TARGET02', reason = 'x',
            reward = { baseline = { cash = 5000 } } })
        truthy(late)
        local lateCreated = s.storage.readContract(late.id).created_at
        local earlyDeadline = s.storage.readContract(early.id).deadline_at
        local lateDeadline = s.storage.readContract(late.id).deadline_at
        Env.time = Env.time + 20
        local crashed = os.time()
        eq(heartbeatOf(), stamp, 'not written since')

        Env.time = Env.time + 600
        local _, s2 = restart(s)
        local a, b = s2.storage.readContract(early.id), s2.storage.readContract(late.id)
        truthy(a.paused_since and a.paused_since <= crashed and a.paused_since >= stamp,
            'paused from no later than the crash: ' .. tostring(a.paused_since))
        eq(b.paused_since, lateCreated, 'and one placed after the stamp from when it was placed, '
            .. 'not from before it existed')

        local main2 = require('server.main')
        main2.markPresenceChanged()
        main2.expire()
        a, b = s2.storage.readContract(early.id), s2.storage.readContract(late.id)
        truthy(a.deadline_at - earlyDeadline >= os.time() - crashed,
            'the whole downtime is credited to the early one')
        truthy(a.deadline_at - earlyDeadline <= os.time() - stamp,
            'and no more than from the last stamp')
        truthy(b.deadline_at - lateDeadline >= os.time() - crashed, 'and to the late one')
        truthy(b.deadline_at - lateDeadline <= os.time() - lateCreated,
            'never for time before it was placed')
    end)

    --- A contract running when the process died, and what its pause at the
    --- next start was dated from.
    local function pausedFrom(torn)
        local main, s = bootJson(function()
            Config.Limits.ExclusiveIdleReleaseSeconds = 0
            Config.Limits.ExclusiveAttemptWindowSeconds = 0
        end)
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } } })
        truthy(c)
        main.tick()
        local stamp = heartbeatOf()
        Env.time = Env.time + 40
        s.audit.action('test_row', 'CREATOR1', nil, {})
        main.tick()
        eq(heartbeatOf(), stamp, 'the stamp did not move')
        local rowAt = os.time()
        if torn then Natives.files['data/heartbeat.json'] = '{"at":17' end
        Env.time = Env.time + 300
        Env.console = {}
        local _, s2 = restart(s)
        return s2.storage.readContract(c.id).paused_since, rowAt, stamp, table.concat(Env.console, '\n')
    end

    it('dates the crash from an audit row newer than the stamp', function()
        local from, rowAt, stamp, said = pausedFrom(false)
        truthy(rowAt > stamp)
        eq(from, rowAt, 'the newest moment the server was seen running')
        falsy(said:find('could not be read whole', 1, true), 'the heartbeat was whole: ' .. said)
    end)

    it('still dates a torn heartbeat from what else the store read, and says so', function()
        local from, rowAt, _, said = pausedFrom(true)
        eq(from, rowAt)
        truthy(said:find('dated from the newest audit row', 1, true), said)
    end)
end)

--------------------------------------------------------------------------
-- The expiry pass on a store with 200 live contracts
--------------------------------------------------------------------------

local function countingExports()
    local real = _G.exports
    local counts = {}
    _G.exports = setmetatable({}, { __index = function(_, resource)
        local inner = real[resource]
        return setmetatable({}, { __index = function(_, method)
            local fn = inner[method]
            return function(...)
                local k = resource .. '.' .. method
                counts[k] = (counts[k] or 0) + 1
                return fn(...)
            end
        end })
    end })
    return counts, function() _G.exports = real end
end

--- 200 live contracts placed through the front door, by 15 players on 15
--- others, all of them in the city.
local function board(s)
    Config.Limits.MaxActiveContractsPerCreator = 10000
    Config.Limits.MaxActiveContractsPerTarget = 10000
    Config.Limits.SameCreatorSameTargetCooldownSeconds = 0
    Config.Immunity.MinTargetSessionMinutes = 0
    Config.Immunity.MinTargetPlaytimeHours = 0
    local players, creators, targets, made = 15, {}, {}, {}
    for i = 1, players do
        Env.addPlayer({ source = 100 + i, citizenid = ('CRE%05d'):format(i),
            license = ('license:cre%d'):format(i), cash = 90000000, bank = 90000000 })
        creators[i] = s.identity.resolve(100 + i)
        Env.addPlayer({ source = 200 + i, citizenid = ('TGT%05d'):format(i),
            license = ('license:tgt%d'):format(i), cash = 100, bank = 100 })
        targets[i] = s.identity.resolve(200 + i)
    end
    for i = 1, 200 do
        local creator = (i - 1) % players
        local target = (creator + math.floor((i - 1) / players)) % players
        local c = s.contracts.create(creators[creator + 1], { targetCid = targets[target + 1].cid,
            reason = 'scale', reward = { baseline = { cash = 1000, bank = 1000 } } })
        if c then made[#made + 1] = c.id end
    end
    eq(#made, 200, 'the board the owner measured')
    return made
end

describe('the expiry pass with 200 live contracts', function()
    it('asks qbx_core once a pass for each party, not twice for every contract', function()
        local main, s = bootJson()
        local ids = board(s)
        main.tick()
        Env.time = Env.time + 20
        local deadlines = {}
        for _, id in ipairs(ids) do deadlines[id] = s.storage.readContract(id).deadline_at end
        Env.time = Env.time + 5
        local main2, s2 = restart(s)
        for _, id in ipairs(ids) do truthy(s2.storage.readContract(id).paused_since, 'paused at the start') end

        local counts, put = countingExports()
        local ok, err = pcall(main2.expire)
        put()
        truthy(ok, tostring(err))
        local asked = (counts['qbx_core.GetPlayerByCitizenId'] or 0) + (counts['qbx_core.GetPlayer'] or 0)
        truthy(asked <= 30, ('the first pass after a start asked qbx_core %d times for 30 people '
            .. '(it was 400)'):format(asked))
        for _, id in ipairs(ids) do
            local c = s2.storage.readContract(id)
            eq(c.paused_since, nil, 'everybody is here, so it runs again')
            truthy(c.deadline_at > deadlines[id], 'with the restart credited')
        end
    end)

    it('reads no contract row again that the pass leaves as it is', function()
        local main, s = bootJson()
        board(s)
        main.tick()
        Env.time = Env.time + 20
        main.markPresenceChanged()
        local reads = 0
        local read = s.storage.readContract
        s.storage.readContract = function(...) reads = reads + 1 return read(...) end
        local ok, err = pcall(main.expire)
        s.storage.readContract = read
        truthy(ok, tostring(err))
        eq(reads, 0, 'a pass with nothing to do read every live contract again, one query each on mysql')
    end)

    it('still reads a row again before it acts on it', function()
        local main, s = bootJson()
        local ids = board(s)
        main.tick()
        -- One target leaves: the contracts on them pause, and only those.
        Env.removePlayer(201)
        main.markPresenceChanged()
        local reads = {}
        local read = s.storage.readContract
        s.storage.readContract = function(id, ...)
            reads[id] = (reads[id] or 0) + 1
            return read(id, ...)
        end
        local ok, err = pcall(main.expire)
        s.storage.readContract = read
        truthy(ok, tostring(err))
        local paused, readPaused, readOthers = 0, 0, 0
        for _, id in ipairs(ids) do
            local c = s.storage.readContract(id)
            if c.target_cid == 'TGT00001' then
                paused = paused + 1
                truthy(c.paused_since, 'paused')
                if reads[id] then readPaused = readPaused + 1 end
            elseif reads[id] then
                readOthers = readOthers + 1
            end
        end
        truthy(paused > 0, 'some contracts are on that target')
        eq(readPaused, paused, 'each one it paused was read again first')
        eq(readOthers, 0, 'and none of the others')
    end)
end)

--------------------------------------------------------------------------
-- The access check
--------------------------------------------------------------------------

describe('the access check on the tick', function()
    it('reads each player\'s job, not their account and name', function()
        local _, s = bootJson()
        board(s)
        local bridges = require('server.bridges')
        local identifiers = 0
        local real = GetPlayerIdentifiers
        _G.GetPlayerIdentifiers = function(...) identifiers = identifiers + 1 return real(...) end
        local counts, put = countingExports()
        local ok, err = pcall(bridges.refreshAccess)
        put()
        _G.GetPlayerIdentifiers = real
        truthy(ok, tostring(err))
        eq(identifiers, 0, 'thirty players\' identifiers read every ten seconds for nothing')
        eq(counts['qbx_core.GetPlayer'], #GetPlayers(), 'one job read a player')
    end)

    it('still closes the app to a player who takes a barred job, and opens it again', function()
        local _, s = bootJson()
        fixture(s)
        Config.WhitelistedView.Enabled = false
        local bridges = require('server.bridges')
        bridges.refreshAccess()
        Env.clientEvents = {}
        Env.players[3].PlayerData.job = { name = 'police', type = 'leo', onduty = true }
        bridges.refreshAccess()
        local told
        for _, e in ipairs(Env.clientEvents) do
            if e.name == 'crimson-hitman:access' and e.target == 3 then told = e.args end
        end
        truthy(told, 'told')
        eq(told[1], false, 'closed')
        Env.clientEvents = {}
        Env.players[3].PlayerData.job = { name = 'unemployed', type = 'none' }
        bridges.refreshAccess()
        told = nil
        for _, e in ipairs(Env.clientEvents) do
            if e.name == 'crimson-hitman:access' and e.target == 3 then told = e.args end
        end
        truthy(told and told[1] == true, 'and open again')
        eq(s.identity.byCitizenId('HITMAN01').name, 'Rook Ash', 'and everything else still resolves whole')
    end)
end)

--------------------------------------------------------------------------
-- The flush
--------------------------------------------------------------------------

describe('the json flush', function()
    it('encodes only the playtime rows that changed', function()
        local _, s = bootJson()
        local rows = {}
        for i = 1, 2000 do rows[i] = { cid = ('OLD%05d'):format(i), minutes = 600 + i, seen_at = 1 } end
        s.storage.writePlaytime(rows)
        truthy(s.storage.flush())
        s.storage.writePlaytime({ { cid = 'OLD00007', minutes = 9999, seen_at = 2 },
                                  { cid = 'NEW00001', minutes = 1, seen_at = 2 } })
        local encodes = 0
        local encode = json.encode
        json.encode = function(...) encodes = encodes + 1 return encode(...) end
        local ok, err = pcall(s.storage.flush)
        json.encode = encode
        truthy(ok, tostring(err))
        truthy(encodes <= 8, ('a minute\'s write encoded %d values for two changed rows'):format(encodes))

        local decoded = json.decode(Natives.files['data/playtime.json'])
        local n = 0
        for _ in pairs(decoded.rows) do n = n + 1 end
        eq(n, 2001, 'every row is still in the file')
        eq(decoded.rows.OLD00007.minutes, 9999, 'with the change')
        eq(decoded.rows.OLD00008.minutes, 608, 'and the rest as they were')
        eq(s.storage.readPlaytime('NEW00001').minutes, 1)
    end)

    it('stops trying the rename that fails every time on Windows, and still swaps whole', function()
        local _, s = bootJson()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } } })
        truthy(c)
        s.storage.flush()
        truthy(s.storage.save(true), 'nothing else left to write')
        Natives.renameKeeps = true
        local function write(reason)
            return fileOps(function()
                s.storage.setReason(c.id, reason)
            end)
        end
        local ok, err = pcall(function()
            local first = write('first')
            eq(first.rename, 3, 'the first swap learns it: the plain rename, then aside and over')
            local second = write('second')
            eq(second.rename, 2, 'from then on only the two renames that work')
            eq(second.remove, 1, 'and only the removal of the old file after it')
            eq(second.load, 1, 'the read-back is kept')
        end)
        Natives.renameKeeps = nil
        truthy(ok, tostring(err))
        local file = 'data/contracts/' .. c.id .. '.json'
        eq(Natives.files[file .. '.new'], nil, 'no copy left')
        eq(Natives.files[file .. '.old'], nil, 'no old file left')
        truthy(Natives.files[file]:find('second', 1, true), 'and the file holds the last write')
    end)
end)
