--- Round 3 performance (docs/dev/loops.md, and README, Performance: the requests):
--- what each change made cheaper, pinned by what it reads.
---
---   * Mine reads only the contracts not finished (O1), and the placing
---     check only the finished ones inside its longest wait;
---   * the staff views read a player's operative rows and escrow in one
---     read each (O2);
---   * Mine carries every card's open proposals (O3);
---   * the audit log's filters are in the statement (O4);
---   * the panel's contract list is read again only after a write (O5);
---   * the informant remembers that nobody bought anything (O6);
---   * a long conversation goes as a latent event (O7);
---   * the settings rows' fixed parts and the board's settings are sent
---     once, named by a hash (O8, O11);
---   * boot recovery reads only what it acts on (O10);
---   * one expiry pass ends at most its share (P2), the prune runs every ten
---     minutes unless it has a backlog (P3), the buyout queue is not walked
---     (P5), the loops share one read of what is running (P6), the photo
---     expiry reads nothing while no view is open (P9), the first playtime
---     pass reads every character in one statement (P10);
---   * a held death report stops asking once recovery failed, and the
---     playtime tracker's start is read once.

local Exec = require('tests.harness.mysql_exec')

local function forget()
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server'
            or name:find('crimson%-hitman%.server')) then
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

local function unlimited()
    for _, bucket in pairs(Config.Cooldowns) do
        bucket.per, bucket.burst = 1, 1000000
    end
end

--- `places` creators, `places` targets and `ops` operatives; `live` live
--- contracts held one each, and `finished` withdrawn ones before them.
local function city(s, live, finished)
    Config.Limits.MaxActiveContractsPerCreator = 10000
    Config.Limits.MaxActiveContractsPerTarget = 10000
    Config.Limits.SameCreatorSameTargetCooldownSeconds = 0
    Config.Limits.TargetCooldownAfterResolveSeconds = 0
    Config.Immunity.AfterBailoutSeconds = 0
    Config.Amendments.CancelCooldownSeconds = 0
    Config.Immunity.MinTargetSessionMinutes = 0
    Config.Immunity.MinTargetPlaytimeHours = 0
    Config.Limits.MaxAcceptedPerHitman = 10000
    unlimited()
    local creators, targets, ops = {}, {}, {}
    -- One live contract per placer and target: four targets, and a placer
    -- for every four live contracts.
    local placers = math.max(4, math.ceil((live or 0) / 4))
    for i = 1, placers do
        Env.addPlayer({ source = 100 + i, citizenid = ('CRE%05d'):format(i),
            license = ('license:cre%d'):format(i), cash = 90000000, bank = 90000000,
            firstname = 'Cre', lastname = ('Ator%d'):format(i) })
        creators[i] = s.identity.resolve(100 + i)
    end
    for i = 1, 4 do
        Env.addPlayer({ source = 200 + i, citizenid = ('TGT%05d'):format(i),
            license = ('license:tgt%d'):format(i), cash = 100, bank = 100,
            firstname = 'Tar', lastname = ('Get%d'):format(i) })
        targets[i] = s.identity.resolve(200 + i)
        Env.addPlayer({ source = 300 + i, citizenid = ('OPR%05d'):format(i),
            license = ('license:opr%d'):format(i), cash = 90000000, bank = 90000000,
            firstname = 'Op', lastname = ('Erative%d'):format(i) })
        ops[i] = s.identity.resolve(300 + i)
    end
    local old = {}
    for i = 1, finished or 0 do
        local c = (i - 1) % 4 + 1
        local row = s.contracts.create(creators[c], { targetCid = targets[(i % 4) + 1].cid,
            reason = 'old', reward = { baseline = { cash = 1000 } } })
        truthy(row, 'placed')
        truthy(s.contracts.accept(ops[c], row.id), 'taken')
        truthy(s.contracts.abandon and s.contracts.abandon(ops[c], row.id) ~= nil, 'left')
        truthy(s.contracts.cancel(creators[c], row.id), 'withdrawn')
        old[#old + 1] = row.id
    end
    local made = {}
    for i = 1, live or 0 do
        local c = math.floor((i - 1) / 4) + 1
        local t = (i - 1) % 4 + 1
        local row, why = s.contracts.create(creators[c], { targetCid = targets[t].cid,
            reason = 'live', reward = { baseline = { cash = 1000 + i } } })
        truthy(row, 'placed: ' .. tostring(why))
        truthy(s.contracts.accept(ops[t], row.id), 'held')
        made[#made + 1] = row.id
    end
    Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
    return { creators = creators, targets = targets, ops = ops, made = made, old = old }
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
        if event.name == 'crimson-hitman:result' and event.target == src then return event.args[1], event end
    end
end

local function admin(src, op, data)
    _G.source = src
    local from = #Env.clientEvents
    Env.events['crimson-hitman:admin']({ op = op, data = data or {}, __rid = 7 })
    _G.source = nil
    for i = from + 1, #Env.clientEvents do
        local event = Env.clientEvents[i]
        if event.name == 'crimson-hitman:adminResult' and event.target == src then return event.args[1] end
    end
end

local function staff()
    Env.addPlayer({ source = 402, citizenid = 'ADMIN001', license = 'license:adm1',
        firstname = 'Sam', lastname = 'Steward' })
    Env.aces[402] = { ['crimson.admin'] = true }
    Config.Admin.IdentityAce = 'crimson.admin'
    Config.Admin.DeveloperAce = 'crimson.admin'
end

--- Every store function wrapped, counting calls and keeping each call's
--- arguments.
local function watching(store, fn)
    local counts, args, real = {}, {}, {}
    for name, f in pairs(store) do
        if type(f) == 'function' then
            real[name] = f
            store[name] = function(...)
                counts[name] = (counts[name] or 0) + 1
                args[name] = args[name] or {}
                args[name][#args[name] + 1] = table.pack(...)
                return f(...)
            end
        end
    end
    local ok, err = pcall(fn)
    for name, f in pairs(real) do store[name] = f end
    if not ok then error(err, 0) end
    return counts, args
end

--- Statements sent while fn runs (mysql).
local function statements(fn)
    local from = #Exec.statements
    fn()
    local out = {}
    for i = from + 1, #Exec.statements do out[#out + 1] = Exec.statements[i] end
    return out
end

local function sent(list, pattern)
    local n = 0
    for _, sql in ipairs(list) do if sql:find(pattern) then n = n + 1 end end
    return n
end

--------------------------------------------------------------------------
-- O1 and the placing check
--------------------------------------------------------------------------

describe('Mine reads only the contracts not finished', function()
    for _, mode in ipairs({ 'mysql', 'json' }) do
        it('on ' .. mode .. ': each of the three reads asks for the live ones, and the cards are the same', function()
            local _, s = boot(mode)
            local w = city(s, 4, 24)
            local before
            local counts, args = watching(s.storage, function() before = call('mine', 101, {}) end)
            truthy(before and before.ok, 'answered')
            for _, name in ipairs({ 'contractsBy', 'contractsInvolving', 'contractsNaming' }) do
                eq(counts[name], 1, name .. ' once')
                eq(args[name][1][2], true, name .. ' asked for the live ones only')
            end
            -- And what they answer holds nothing finished.
            local live = s.storage.contractsInvolving(w.creators[1].cid, true)
            for _, c in ipairs(live) do falsy(CH.TERMINAL[c.state], c.id .. ' is finished') end
            local all, open = s.storage.contractsInvolving(w.creators[1].cid), 0
            for _, c in ipairs(all) do if not CH.TERMINAL[c.state] then open = open + 1 end end
            eq(#live, open, 'every live contract of theirs')
            truthy(#all >= #live + 6, ('of %d kept'):format(#all))
            eq(#before.data.created, #s.storage.contractsBy(w.creators[1].cid, true),
                'their live contracts on Mine')
        end)
    end

    it('the placing check reads the finished contracts inside its longest wait only', function()
        local _, s = boot('mysql')
        local w = city(s, 0, 8)
        Config.Limits.TargetCooldownAfterResolveSeconds = 600
        local _, args = watching(s.storage, function()
            s.contracts.canCreate(w.creators[1], w.targets[3])
        end)
        local since = args.contractsBy and args.contractsBy[1][2]
        eq(math.type(since), 'integer', 'a time, not the whole history')
        eq(since, os.time() - 600, 'the longest of the waits')
        Env.time = Env.time + 601
        eq(#s.storage.contractsBy(w.creators[1].cid, os.time() - 600), 0,
            'none of theirs is inside it any more, so none is read')
    end)
end)

--------------------------------------------------------------------------
-- O2
--------------------------------------------------------------------------

describe('the staff views read a player\'s history in a few statements', function()
    it('reads an operative\'s rows and escrow in one read each, not one per contract', function()
        local _, s = boot('mysql')
        staff()
        city(s, 4, 24)
        main = nil
        local counts = watching(s.storage, function()
            truthy(admin(402, 'player', { subject = 301 }).ok, 'player')
            truthy(admin(402, 'history', { subject = 301 }).ok, 'history')
            truthy(admin(402, 'contracts', { query = 'OPR00001' }).ok, 'search')
        end)
        eq(counts.readHitman, nil, 'no row read per contract (it was one each)')
        eq(counts.readHitmen, nil, 'no roster read per contract')
        eq(counts.readEscrow, nil, 'no escrow read per contract')
        truthy((counts.hitmenOf or 0) >= 1 and counts.hitmenOf <= 3, 'their rows in one read a view')
        truthy((counts.readEscrowMany or 0) <= 1, 'the history\'s escrow in one read')
    end)
end)

--------------------------------------------------------------------------
-- O3
--------------------------------------------------------------------------

describe('Mine carries the open proposals', function()
    it('for every card placed or held, the same as the read of each, from one read of which have any', function()
        local _, s = boot('mysql')
        local w = city(s, 4, 0)
        local id = w.made[1]
        truthy(s.amendments.propose(w.creators[1], id, CH.AMENDMENT.EXTEND_DEADLINE or 'extend_deadline',
            { minutes = 30 }) or true, 'proposed')
        local reply
        local counts = watching(s.storage, function() reply = call('mine', 101, {}) end)
        truthy(reply and reply.ok, 'answered')
        local proposals = reply.data.proposals
        truthy(type(proposals) == 'table', 'carried')
        for _, card in ipairs(reply.data.created) do
            truthy(proposals[card.id] ~= nil, 'an answer for ' .. card.id)
        end
        eq(counts.openAmendmentContracts, 1, 'which contracts have one, in one read')
        local open = s.storage.openAmendmentContracts()
        local wanted = 0
        for _, card in ipairs(reply.data.created) do if open[card.id] then wanted = wanted + 1 end end
        eq(counts.readOpenAmendments or 0, wanted, 'only those read further')
        local each = call('amendments', 101, { id = id })
        eq(#(proposals[id] or {}), #(each.data or {}), 'what the read of that card answers')
    end)
end)

--------------------------------------------------------------------------
-- O4
--------------------------------------------------------------------------

describe('the audit log\'s filters are in the statement', function()
    it('reads a page and one more of matching rows, not five hundred of anything', function()
        local _, s = boot('mysql')
        for i = 1, 300 do s.audit.action('noise_' .. i, nil, nil, {}) end
        for i = 1, 5 do s.audit.staff('admin_setting_changed', 'ADMIN001', nil, { key = 'K' .. i }) end
        s.audit.action('adminXsetting', nil, nil, {})
        s.audit.flush()
        local rows
        local sql = statements(function()
            rows = s.storage.queryAudit({ action = 'admin_setting' }, nil, 25)
        end)
        eq(#sql, 1, 'one statement')
        truthy(sql[1]:find("action LIKE %? ESCAPE '!'"), sql[1])
        eq(#rows, 5, 'the five, and not the one an unescaped _ would match')
        for _, row in ipairs(rows) do truthy(row.action:find('admin_setting', 1, true), row.action) end
        local last = Exec.statements[#Exec.statements]
        truthy(last:find('LIMIT %?'), last)
    end)
end)

--------------------------------------------------------------------------
-- O5
--------------------------------------------------------------------------

describe('the panel\'s contract list', function()
    it('is read again only after a write, however long it stays open', function()
        local _, s = boot('mysql')
        staff()
        local w = city(s, 2, 0)
        local counts = watching(s.storage, function()
            for _ = 1, 6 do
                Env.time = Env.time + 6
                truthy(admin(402, 'contracts', { page = 1 }).ok, 'listed')
            end
        end)
        eq(counts.allContracts, 1, 'once in half a minute with nothing written (it was every five seconds)')
        s.storage.setAdvised(w.made[1], { advised_posted_at = Env.time })
        Env.time = Env.time + 6
        counts = watching(s.storage, function() admin(402, 'contracts', { page = 1 }) end)
        eq(counts.allContracts, 1, 'and again after a write')
    end)

    it('is read again after a retention prune, which removes finished contracts', function()
        local main, s = boot('mysql')
        staff()
        local w = city(s, 1, 3)
        Config.Audit.ContractRetentionDays = 1
        Env.time = Env.time + 6
        local before = admin(402, 'contracts', { page = 1 })
        truthy(before.ok, 'listed')
        Env.time = Env.time + 2 * 86400
        -- The prune moves its own count, whatever the store's write count
        -- does (a prune need not move the board's), so the list knows.
        local version = s.projection.keptVersion()
        truthy(main.prune(), 'pruned')
        -- Moved by the prune through the store as well as by notePruned
        -- (merged with impB's placer record, which keys on it too), so by at
        -- least one rather than exactly one.
        truthy(tonumber(s.projection.keptVersion():match(':(%d+)$')) > tonumber(version:match(':(%d+)$')),
            'the prune moved what the list keys on, by itself')
        eq(s.projection.keptVersion():match('^(%d+):'), version:match('^(%d+):'),
            'and not the board\'s generation (round 3)')
        local counts = watching(s.storage, function() admin(402, 'contracts', { page = 1 }) end)
        eq(counts.allContracts, 1, 'read again')
        local _ = w
    end)
end)

--------------------------------------------------------------------------
-- O6
--------------------------------------------------------------------------

describe('the target\'s informant', function()
    it('asks the store once whether a target bought anything, not twice a card every Mine', function()
        local _, s = boot('mysql')
        city(s, 4, 0)
        local first = watching(s.storage, function() call('mine', 201, {}) end)
        local again = watching(s.storage, function() call('mine', 201, {}) end)
        truthy((first.readReveal or 0) <= 1, ('the first Mine asked %d times'):format(first.readReveal or 0))
        eq(again.readReveal, nil, 'the next asks nothing')
    end)
end)

--------------------------------------------------------------------------
-- O7
--------------------------------------------------------------------------

describe('a long conversation', function()
    it('goes as a latent event over 8 KB, and on the reliable channel under it', function()
        local _, s = boot('memory')
        local w = city(s, 1, 0)
        local id = w.made[1]
        local _, short = call('readThread', 301, { id = id })
        truthy(short and not short.latent, 'a short one as before')
        local okSent, lastErr = 0, nil
        for i = 1, 60 do
            s.app.resetFloodCounters()
            local r = call('sendMessage', 301, { id = id, body = string.rep('abcdefghij', 18) })
            if r and r.ok then okSent = okSent + 1 else lastErr = r and r.err end
            Env.advance(3)
        end
        local reply, event = call('readThread', 301, { id = id })
        truthy(reply and reply.ok and #reply.data.messages > 40,
            ('read whole: %d sent (%s), %s'):format(okSent, tostring(lastErr), json.encode(reply and reply.err or '')))
        truthy(event.latent, 'latent')
        eq(event.bps, s.app.LATENT_OVER.readThread.bps)
    end)
end)

--------------------------------------------------------------------------
-- O8 and O11
--------------------------------------------------------------------------

describe('what rarely changes is sent once', function()
    it('the settings rows\' fixed parts, named by a hash the panel sends back', function()
        local _, s = boot('memory')
        staff()
        local whole = admin(402, 'settings', {})
        truthy(whole.ok and type(whole.data.schema) == 'string', 'named')
        local row = whole.data.features[1]
        truthy(row.label and row.value ~= nil, 'whole rows')
        local lean = admin(402, 'settings', { schema = whole.data.schema })
        eq(lean.data.schema, whole.data.schema, 'the same hash for the same parts')
        truthy(lean.data.lean, 'lean')
        local leanRow = lean.data.features[1]
        eq(leanRow.key, row.key)
        eq(leanRow.label, nil, 'no label')
        eq(leanRow.about, nil, 'no help')
        eq(leanRow.value, row.value, 'the value, every time')
        local size = function(v) return #json.encode(v) end
        truthy(size(lean) * 3 < size(whole), ('lean %d bytes, whole %d'):format(size(lean), size(whole)))
        local other = admin(402, 'settings', { schema = 'not it' })
        eq(other.data.lean, nil, 'a hash it does not name gets them whole')
    end)

    it('the board\'s settings, only while they are not the ones the page holds', function()
        local _, s = boot('memory')
        city(s, 1, 0)
        local first = call('list', 301, { page = 1 })
        truthy(first.data.settings and type(first.data.settingsHash) == 'string', 'whole, and named')
        local again = call('list', 301, { page = 1, settingsHash = first.data.settingsHash })
        eq(again.data.settings, nil, 'left out')
        eq(again.data.settingsHash, first.data.settingsHash)
        Config.Bailout.ProcessingDelaySeconds = (Config.Bailout.ProcessingDelaySeconds or 0) + 60
        local changed = call('list', 301, { page = 1, settingsHash = first.data.settingsHash })
        truthy(changed.data.settings, 'sent whole once they change')
        truthy(changed.data.settingsHash ~= first.data.settingsHash, 'under another hash')
    end)
end)

--------------------------------------------------------------------------
-- O10
--------------------------------------------------------------------------

describe('boot recovery reads only what it acts on', function()
    it('every contract not finished, its escrow in one read, and nothing again unless a step wrote', function()
        local _, s = boot('mysql')
        city(s, 12, 24)
        s.audit.flush()
        -- The restart: the same database, a new process.
        rawset(s.storage, '__rawFixture', true)
        forget()
        Env.events, Env.clientEvents, Env.notifications = {}, {}, {}
        Env.handlers, Env.threads, Env.timers, Env.commands = {}, {}, {}, {}
        local store = require('server.storage.mysql')
        local counts, real = {}, {}
        for _, name in ipairs({ 'allContracts', 'unfinishedContracts', 'readEscrow', 'readEscrowMany',
            'readContract' }) do
            real[name] = store[name]
            store[name] = function(...)
                -- Recovery's own reads (server/main.lua), not the steps' under
                -- their locks.
                local from = debug.getinfo(2, 'S').short_src
                if name ~= 'readContract' or from:find('main.lua', 1, true) then
                    counts[name] = (counts[name] or 0) + 1
                end
                return real[name](...)
            end
        end
        local main = require('server.main')
        local ok, err = pcall(main.start)
        for name, f in pairs(real) do store[name] = f end
        truthy(ok, tostring(err))
        eq(counts.allContracts, nil, 'not every contract kept')
        eq(counts.unfinishedContracts, 2, 'the ones not finished: recovery, and the index of holds')
        eq(counts.readEscrowMany, 1, 'their escrow in one read')
        truthy((counts.readEscrow or 0) <= 1, ('escrow read %d times one by one (it was 24)')
            :format(counts.readEscrow or 0))
        truthy((counts.readContract or 0) <= 1, ('contracts read %d times one by one (it was 12)')
            :format(counts.readContract or 0))
    end)
end)

--------------------------------------------------------------------------
-- P2, P3, P5, P6, P9, P10
--------------------------------------------------------------------------

describe('the capped and gated passes', function()
    it('one expiry pass ends at most its share, and the next tick comes back for the rest', function()
        local main, s = boot('memory')
        local w = city(s, 60, 0)
        main.tick()
        local share = main.EXPIRIES_PER_PASS
        eq(share, 25)
        Env.time = Env.time + Config.Limits.ContractLifetimeSeconds + 60
        main.markPresenceChanged()
        local passes, ended = 0, 0
        while ended < #w.made and passes < 10 do
            local n = main.expire()
            truthy(n <= share, ('a pass ended %d'):format(n))
            ended, passes = ended + n, passes + 1
        end
        eq(ended, #w.made, 'every one ended')
        eq(passes, math.ceil(#w.made / share), 'a share a pass, one pass after another')
    end)

    it('the prune runs every ten minutes, and on the next tick while it removes a full batch', function()
        local main, s = boot('mysql')
        local calls = 0
        local real = s.storage.prune
        s.storage.prune = function(...) calls = calls + 1 return real(...) end
        for _ = 1, 60 do
            Env.time = Env.time + 10
            main.tick()
        end
        truthy(calls >= 1 and calls <= 2, ('ran %d times in ten minutes (it was 60)'):format(calls))
        local more = true
        s.storage.prune = function() calls = calls + 1 return true, more end
        calls = 0
        for _ = 1, 3 do Env.time = Env.time + 600 main.tick() end
        more = false
        for _ = 1, 3 do Env.time = Env.time + 10 main.tick() end
        eq(calls, 4, 'back on every tick with a backlog, then not until its interval')
        s.storage.prune = real
    end)

    it('removes at most twenty-five finished contracts a prune on mysql', function()
        local _, s = boot('mysql')
        city(s, 0, 40)
        Config.Audit.ContractRetentionDays = 1
        Env.time = Env.time + 2 * 86400
        local ok, more = s.storage.prune()
        truthy(ok, 'pruned')
        eq(more, true, 'with more left')
        eq(#s.storage.allContracts(), 15, 'twenty-five of forty gone')
        ok, more = s.storage.prune()
        eq(more, false, 'and the rest on the next')
        eq(#s.storage.allContracts(), 0)
    end)

    it('the buyout queue: no statement while it is empty on mysql, and an index on json', function()
        local _, s = boot('mysql')
        local w = city(s, 2, 0)
        s.storage.queuedBailouts()
        eq(#statements(function() s.storage.queuedBailouts() end), 0, 'empty, and nothing queued since')
        truthy(s.storage.recordBailout(w.made[1], { bailout_queued_at = Env.time, bailout_paid_by = 'TGT00002',
            bailout_paid_amount = 10, bailout_paid_account = 'bank' }), 'queued')
        eq(#s.storage.queuedBailouts(), 1, 'read again once one is queued')
        local _, j = boot('json')
        local jw = city(j, 2, 0)
        eq(#j.storage.queuedBailouts(), 0)
        truthy(j.storage.recordBailout(jw.made[2], { bailout_queued_at = Env.time, bailout_paid_by = 'TGT00003',
            bailout_paid_amount = 10, bailout_paid_account = 'bank' }), 'queued')
        eq(#j.storage.queuedBailouts(), 1, 'kept by the index')
        truthy(j.storage.clearBailout(jw.made[2], Env.time), 'cleared')
        eq(#j.storage.queuedBailouts(), 0, 'and gone from it')
    end)

    it('the sampler, the idle holds and the expiry pass share one read of what is running', function()
        local main, s = boot('mysql')
        city(s, 6, 0)
        main.tick()
        local death = require('server.completion.death')
        local thread
        for _, fn in ipairs(Env.threads) do
            if debug.getinfo(fn, 'S').short_src:find('death.lua', 1, true) then thread = fn end
        end
        local co = coroutine.wrap(thread)
        local realWait = _G.Wait
        _G.Wait = coroutine.yield
        co()
        local counts = watching(s.storage, function()
            for _ = 1, 5 do co() end        -- five sampler passes
            s.contracts.releaseIdleHolds()
            main.markPresenceChanged()
            main.expire()
        end)
        _G.Wait = realWait
        eq(counts.liveContracts, nil, 'nothing written, nothing read (it was 7 reads)')
        eq(counts.liveHitmen, nil, 'nor the rosters')
        local _ = death
    end)

    it('the photo expiry asks the store nothing while no view is open', function()
        local main, s = boot('mysql', function() Config.Completion.KillPhotos = true end)
        main.tick()
        local first = sent(statements(function() s.photos.expire() end), 'crimson_photos')
        local idle = sent(statements(function()
            for _ = 1, 5 do Env.time = Env.time + 10 s.photos.expire() end
        end), 'crimson_photos')
        truthy(first <= 1, 'read once')
        eq(idle, 0, 'then nothing (it was a statement a tick)')
    end)

    it('the first playtime pass reads every character in one statement', function()
        local main, s = boot('mysql')
        city(s, 0, 0)
        local counts = watching(s.storage, function() s.playtime.pass() end)
        eq(counts.readPlaytime, nil, 'none one by one (it was one each)')
        eq(counts.readPlaytimeMany, 1, 'all in one')
        local install = 0
        local real = s.storage.readPlaytimeInstall
        s.storage.readPlaytimeInstall = function(...) install = install + 1 return real(...) end
        for _ = 1, 3 do Env.time = Env.time + 61 s.playtime.pass() end
        s.storage.readPlaytimeInstall = real
        eq(install, 0, 'the tracker\'s start, known after the first pass, is not read again')
        local _ = main
    end)
end)

--------------------------------------------------------------------------
-- Also
--------------------------------------------------------------------------

describe('a death held while recovery runs', function()
    it('is dropped, and not asked about every second, once recovery has failed', function()
        local _, s = boot('memory')
        city(s, 1, 0)
        s.app.ready, s.app.recoveryFailed = false, false
        local before = #Env.timers
        _G.source = 201
        Env.events['crimson-hitman:iDied'](301)
        _G.source = nil
        truthy(#Env.timers > before, 'held, and looked at again in a second')
        s.app.recoveryFailed = true
        for _ = 1, 3 do Env.advance(1) end
        local again = 0
        for _, t in ipairs(Env.timers) do if not Env.clearedTimers[t.seq] then again = again + 1 end end
        eq(again, before, 'no timer left asking')
        s.app.ready = true
    end)
end)

describe('the handover countdown', function()
    it('moves on by the time since the last pass, at least TickMs and at most three of them', function()
        local _, s = boot('memory')
        local kidnap = require('server.completion.kidnap')
        local deltas = {}
        local realTick, realCount = kidnap.tick, kidnap.activeCount
        kidnap.tick = function(d) deltas[#deltas + 1] = d end
        kidnap.activeCount = function() return 1 end
        kidnap.start()
        local thread = Env.threads[#Env.threads]
        local co = coroutine.wrap(thread)
        local realWait = _G.Wait
        _G.Wait = coroutine.yield
        local tick = Config.Kidnap.TickMs
        co()
        Env.gameTimer = Env.gameTimer + tick + 400
        co()
        Env.gameTimer = Env.gameTimer + tick * 10
        co()
        Env.gameTimer = Env.gameTimer + 1
        co()
        _G.Wait = realWait
        kidnap.tick, kidnap.activeCount = realTick, realCount
        eq(deltas[1], tick + 400, 'the time it really took')
        eq(deltas[2], tick * 3, 'a hitch counts three ticks at most')
        eq(deltas[3], tick, 'and never less than one')
        local _ = s
    end)
end)
