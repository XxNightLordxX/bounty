--- Writing the json store on a real server.
---
--- Observed in production, repeating on every flush:
---   [crimson-hitman] write verification failed for data/store.json;
---   keeping the previous file
---
--- Which means nothing was being persisted at all. The write itself
--- succeeded; the read-back used to judge it did not agree, and the store
--- threw away a write that had landed.

--- The file a write is of. Every whole file is written as <file>.new and
--- renamed over <file> (writeRaw), so SaveResourceFile sees the copy's name.
local function logical(file)
    return (file:gsub('%.new$', ''))
end

local function freshStore()
    package.loaded['crimson-hitman.server.storage.json'] = nil
    Natives.files = {}
    Natives.blocked = {}
    Natives.saveFile = nil
    Natives.loadFile = nil
    Natives.renameKeeps, Natives.renameRefused = nil, nil
    local store = require('crimson-hitman.server.storage.json')
    store.open()
    return store
end

describe('writing the json store', function()
    it('writes the file it means to write', function()
        local store = freshStore()
        store.writeContract({ id = 'ct1', creator_cid = 'CREATOR1', target_cid = 'T',
            state = CH.STATE.ACTIVE, created_at = os.time() })
        truthy(store.save(true), 'the flush must report success')
        truthy(Natives.files['data/store.json'], 'and the index has to be on disk')
        truthy(Natives.files['data/contracts/ct1.json'], 'along with the contract')
    end)

    it('does not write the same file twice to do it', function()
        -- The temp file was written in full, read back, and then the real
        -- file was written in full as well: two complete writes per flush,
        -- and no rename between them, so nothing was ever made atomic by
        -- it either.
        --
        -- The copy is renamed now, which is what makes it worth writing: a
        -- crash part-way tears <file>.new, never <file> (see the crash specs
        -- below). Still one whole write a file, and nothing left behind.
        local store = freshStore()
        local written = {}
        Natives.saveFile = function(file) written[#written + 1] = file end
        Natives.calls.renamed = {}
        store.writeContract({ id = 'ct2', creator_cid = 'C', target_cid = 'T',
            state = CH.STATE.ACTIVE, created_at = os.time() })
        store.save(true)
        Natives.saveFile = nil

        local temps, times = 0, {}
        for _, file in ipairs(written) do
            if file:find('%.tmp$') then temps = temps + 1 end
            times[logical(file)] = (times[logical(file)] or 0) + 1
        end
        eq(temps, 0, 'no temp file that is never renamed: ' .. table.concat(written, ', '))
        eq(times['data/contracts/ct2.json'], 1, 'the contract written once')
        eq(times['data/store.json'], 1, 'and the index once')
        local moved = {}
        for _, r in ipairs(Natives.calls.renamed) do moved[r.from] = r.to end
        eq(moved['data/contracts/ct2.json.new'], 'data/contracts/ct2.json',
            'each written whole as its copy and renamed over it')
        eq(moved['data/store.json.new'], 'data/store.json')
        eq(Natives.files['data/store.json.new'], nil, 'with no copy left behind')
        eq(Natives.files['data/contracts/ct2.json.new'], nil)
    end)

    it('keeps the write when the read-back disagrees but the write succeeded', function()
        -- This is the production symptom. SaveResourceFile said it wrote
        -- the file; the read-back came back a different size. Discarding on
        -- that basis turns "probably fine" into "certainly lost".
        local store = freshStore()
        store.writeContract({ id = 'ct3', creator_cid = 'C', target_cid = 'T',
            state = CH.STATE.ACTIVE, created_at = os.time() })

        -- A read that does not agree with what was just written: the
        -- read-back is of the copy, before it is renamed over the file.
        local realLoad = _G.LoadResourceFile
        _G.LoadResourceFile = function(res, file)
            local content = realLoad(res, file)
            if file == 'data/store.json.new' and content then return content:sub(1, 5) end
            return content
        end
        local ok = store.save(true)
        _G.LoadResourceFile = realLoad

        truthy(ok, 'the flush must not report failure for a write that landed')

        -- Not just present: current. The old code left whatever was there
        -- from startup and called that safety.
        local stored = Natives.files['data/store.json']
        truthy(stored, 'the file must still be there rather than abandoned')
        truthy(stored:find('ct3', 1, true),
            'and hold the contract that was just written: ' .. tostring(stored))

        -- And it survives a restart, which is the only thing any of this is for.
        package.loaded['crimson-hitman.server.storage.json'] = nil
        local reopened = require('crimson-hitman.server.storage.json')
        reopened.open()
        truthy(reopened.readContract('ct3'),
            'a contract written before a restart has to be there after it')
    end)

    it('does report a write the engine actually refused', function()
        -- The check has to keep working where it can. A refused write is
        -- not the same as a read-back that disagreed.
        -- Refused while a new contract has to be named in the index, so the
        -- save has an index to write. A forced save with nothing changed in
        -- the index no longer writes it at all (see the next test).
        local store = freshStore()
        Natives.blocked = { ['data/store.json'] = true }
        store.writeContract({ id = 'ct4', creator_cid = 'C', target_cid = 'T',
            state = CH.STATE.ACTIVE, created_at = os.time() })
        local ok = store.save(true)
        Natives.blocked = {}
        falsy(ok, 'a write the engine refused is a failed flush')
        truthy(store.save(true), 'and the next one, once it can write, succeeds')
        truthy((Natives.files['data/store.json'] or ''):find('ct4', 1, true),
            'naming the contract the refused one could not')
    end)

    --- A money write on a contract the index already names changes that
    --- contract's file and nothing in the index. It used to rewrite the
    --- index anyway, and the index carried the ledger: a kill payout wrote a
    --- multi-megabyte store.json a dozen times over.
    it('does not rewrite the index for a contract it already names', function()
        local store = freshStore()
        store.writeContract({ id = 'ct5', creator_cid = 'C', target_cid = 'T',
            state = CH.STATE.ACTIVE, created_at = os.time() })
        local written = {}
        Natives.saveFile = function(file)
            written[logical(file)] = (written[logical(file)] or 0) + 1
        end
        store.setReason('ct5', 'changed')
        store.save(true)
        Natives.saveFile = nil
        eq(written['data/contracts/ct5.json'], 1, 'the contract is written once')
        eq(written['data/store.json'], nil, 'and the index not at all')
        eq(written['data/records.json'], nil, 'nor the records')
    end)

    it('does not print the same complaint on every flush', function()
        -- The production log was this line and nothing else, over and over.
        -- A warning that repeats forever buries whatever comes after it.
        local store = freshStore()
        local realLoad = _G.LoadResourceFile
        _G.LoadResourceFile = function(res, file)
            local content = realLoad(res, file)
            if file == 'data/store.json.new' and content then return content:sub(1, 5) end
            return content
        end

        Env.console = {}
        for i = 1, 20 do
            store.writeContract({ id = 'ctm' .. i, creator_cid = 'C', target_cid = 'T',
                state = CH.STATE.ACTIVE, created_at = os.time() })
            store.save(true)
        end
        _G.LoadResourceFile = realLoad

        local complaints = 0
        for _, line in ipairs(Env.console) do
            if line:find('reads back as', 1, true) then complaints = complaints + 1 end
        end
        truthy(complaints > 0,
            'the mismatch has to be said at least once, or nobody can act on it')
        truthy(complaints <= 3,
            'twenty flushes produced ' .. complaints .. ' identical warnings; '
            .. 'a line that repeats forever buries whatever comes after it')

        local closed = false
        for _, line in ipairs(Env.console) do
            if line:find('will not be printed', 1, true) then closed = true end
        end
        truthy(closed, 'and it has to say it has stopped, not just go quiet')
    end)

    --- An antivirus, a backup tool or an editor holding one contract file on
    --- Windows stopped the save at that file: every contract after it in
    --- pairs() order had its escrow in memory only, on every save while the
    --- file stayed locked, and the save answered true.
    it('one locked contract file does not stop another contract\'s escrow reaching disk; save answers false', function()
        local store = freshStore()
        for i = 0, 5 do
            store.writeContract({ id = 'ctlock0' .. i, creator_cid = 'C', target_cid = 'T',
                state = CH.STATE.ACTIVE, created_at = os.time() })
        end
        truthy(store.save(true))
        Natives.blocked = { ['data/contracts/ctlock00.json'] = true }
        Env.console = {}
        store.writeMessage({ contract_id = 'ctlock00', thread_id = 't', from_cid = 'C',
            from_alias = 'Client', body = 'x', sent_at = os.time() })
        for i = 1, 5 do
            local id = 'ctlock0' .. i
            store.writeEscrow(id, { { id = id .. ':1', contract_id = id, slot = 1,
                portion = 'baseline', source = 'bank', amount = 1000 * i,
                state = CH.ESCROW_STATE.HELD } })
            truthy((Natives.files['data/contracts/' .. id .. '.json'] or ''):find(id .. ':1', 1, true),
                id .. '\'s money write is on disk')
        end
        local saved, file = store.save(true)
        falsy(saved, 'a save that left a dirty file unwritten did not save')
        eq(file, 'data/contracts/ctlock00.json', 'and says which')
        local said = {}
        for _, line in ipairs(Env.console) do
            if line:find('could not be written', 1, true) or line:find('could not write', 1, true) then
                said[#said + 1] = line
            end
        end
        eq(#said, 1, 'one console line for it: ' .. table.concat(said, ' | '))
        truthy(said[1]:find('ctlock00', 1, true) and said[1]:find('next flush retries', 1, true),
            said[1])

        Natives.blocked = {}
        truthy(store.save(true), 'once it can be written, it is')
        truthy((Natives.files['data/contracts/ctlock00.json'] or ''):find('"body":"x"', 1, true))
    end)

    --- The admin panel's Flush button reads what flush answers.
    it('a flush that could not write answers false, naming the file', function()
        local store = freshStore()
        truthy(store.flush(), 'nothing to write is nothing left unwritten')
        Natives.blocked = { ['data/store.json'] = true }
        store.nextId('zz')
        local saved, file = store.flush()
        Natives.blocked = {}
        falsy(saved)
        eq(file, 'data/store.json')
    end)
end)


--- store.json is rewritten in place, so a crash mid-write can leave it
--- empty. Read as a first install, that wrote an index naming no contracts
--- over it, and every open contract and the escrow it held were gone, with
--- no warning and no quarantine.
describe('an index that reads back empty', function()
    local function reopen()
        package.loaded['crimson-hitman.server.storage.json'] = nil
        local store = require('crimson-hitman.server.storage.json')
        return store, pcall(store.open)
    end

    local function heldContract()
        local store = freshStore()
        store.writeContract({ id = 'ctheld01', creator_cid = 'C', target_cid = 'T',
            state = CH.STATE.ACTIVE, created_at = os.time() })
        store.writeEscrow('ctheld01', { { id = 'ctheld01:1', contract_id = 'ctheld01', slot = 1,
            portion = 'baseline', source = 'cash', amount = 50000, state = CH.ESCROW_STATE.HELD } })
        store.close()
    end

    it('refuses to start where the store has run before, and overwrites nothing', function()
        heldContract()
        local _, opened = reopen()
        truthy(opened, 'a whole index opens')
        truthy((Natives.files['data/store.json.prev'] or ''):find('ctheld01', 1, true),
            'and is kept as the copy to restore from')

        Natives.files['data/store.json'] = ''
        local _, ok, err = reopen()
        falsy(ok, 'an empty index on a store that has run is not a first install')
        truthy(tostring(err):find('store.json.prev', 1, true), 'names the copy: ' .. tostring(err))
        eq(Natives.files['data/store.json'], '', 'and has not written an empty index over it')
        truthy(Natives.files['data/contracts/ctheld01.json'], 'the contract file is still there')

        Natives.files['data/store.json'] = Natives.files['data/store.json.prev']
        local store, restored = reopen()
        truthy(restored, 'restored from the copy, it starts')
        eq(store.readEscrowLine('ctheld01:1').amount, 50000, 'with the escrow held')
    end)

    it('starts empty on a first install', function()
        Natives.files = {}
        local store, ok = reopen()
        truthy(ok, 'nothing has run here, so empty is right')
        eq(#store.allContracts(), 0)
    end)
end)


--- The audit log was a field of the index, and a financial write rewrites
--- the index whole: with a month of rows, a single kill payout encoded and
--- wrote several megabytes a dozen times over.
describe('the audit log and a money write', function()
    local function today() return 'data/audit-' .. os.date('!%Y-%m-%d', os.time()) .. '.jsonl' end

    it('leaves the log alone; the flush writes it', function()
        local store = freshStore()
        store.writeContract({ id = 'ctaud01', creator_cid = 'C', target_cid = 'T',
            state = CH.STATE.ACTIVE, created_at = os.time() })
        for i = 1, 50 do
            store.writeAudit({ ts = os.time(), kind = 'conduct', action = 'row' .. i, detail = {} })
        end
        store.close()
        -- One more, not yet on disk, so the money write has a reason to.
        store.writeAudit({ ts = os.time(), kind = 'financial', action = 'unwritten', detail = {} })

        local written = {}
        Natives.saveFile = function(file, data) written[logical(file)] = data end
        store.writeEscrow('ctaud01', { { id = 'ctaud01:1', contract_id = 'ctaud01', slot = 1,
            portion = 'baseline', source = 'cash', amount = 500, state = CH.ESCROW_STATE.HELD } })
        truthy(store.claimEscrowLine('ctaud01:1', CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING))
        Natives.saveFile = nil

        truthy(written['data/contracts/ctaud01.json'], 'the money write still lands at once')
        eq(written[today()], nil, 'and does not write the audit log')
        local index = written['data/store.json'] or ''
        falsy(index:find('row1', 1, true) or index:find('unwritten', 1, true),
            'nor carry it in the index: ' .. index:sub(1, 200))

        store.flush()
        truthy((Natives.files[today()] or ''):find('unwritten', 1, true), 'the flush writes it')
    end)

    it('adds a flush\'s rows to the end of the day\'s file rather than rewriting it', function()
        local base = '/srv/resources/crimson-hitman/'
        local appended = {}
        local realOpen, realPath = io.open, _G.GetResourcePath
        _G.GetResourcePath = function() return base:sub(1, -2) end
        io.open = function(target, mode)
            if target:sub(1, #base) ~= base then return realOpen(target, mode) end
            local file = target:sub(#base + 1)
            return {
                write = function(_, data)
                    appended[#appended + 1] = data
                    Natives.files[file] = (Natives.files[file] or '') .. data
                    return true
                end,
                close = function() end,
            }
        end

        local ok, err = pcall(function()
            local store = freshStore()
            store.writeAudit({ ts = os.time(), kind = 'conduct', action = 'one', detail = {} })
            store.flush()
            eq(#appended, 0, 'a day\'s first write is the whole file')

            store.writeAudit({ ts = os.time(), kind = 'conduct', action = 'two', detail = {} })
            store.writeAudit({ ts = os.time(), kind = 'conduct', action = 'three', detail = {} })
            store.flush()
            eq(#appended, 1, 'one add for the flush')
            falsy(appended[1]:find('"one"', 1, true), 'carrying only the new rows: ' .. appended[1])
            truthy(appended[1]:find('"two"', 1, true) and appended[1]:find('"three"', 1, true))

            package.loaded['crimson-hitman.server.storage.json'] = nil
            local reopened = require('crimson-hitman.server.storage.json')
            reopened.open()
            local actions = {}
            for _, row in ipairs(reopened.readAudit()) do actions[#actions + 1] = row.action end
            eq(table.concat(actions, ','), 'one,two,three', 'and it all reads back')
        end)
        io.open, _G.GetResourcePath = realOpen, realPath
        if not ok then error(err, 0) end
    end)

    it('does not write over a day\'s file that read back empty; that day goes on in another', function()
        -- A failed read looked like an empty day, and the day's next row was
        -- its first write: the whole file, holding only that row. Every
        -- earlier row was gone, release_interrupted among them.
        local store = freshStore()
        store.writeAudit({ ts = os.time(), kind = 'conduct', action = 'a', detail = {} })
        store.writeAudit({ ts = os.time(), kind = 'financial', action = 'release_interrupted', detail = {} })
        store.close()
        local before = Natives.files[today()]

        local realLoad = _G.LoadResourceFile
        _G.LoadResourceFile = function(res, file)
            if file == today() then return nil end
            return realLoad(res, file)
        end
        local ok, err = pcall(function()
            package.loaded['crimson-hitman.server.storage.json'] = nil
            local unread = require('crimson-hitman.server.storage.json')
            unread.open()
            unread.writeAudit({ ts = os.time(), kind = 'conduct', action = 'c', detail = {} })
            truthy(unread.flush(), 'the row is written')
        end)
        _G.LoadResourceFile = realLoad
        if not ok then error(err, 0) end

        eq(Natives.files[today()], before, 'the file that would not read is left as it was')
        local beside = today():gsub('%.jsonl$', '.1.jsonl')
        truthy((Natives.files[beside] or ''):find('"c"', 1, true), 'the new row is in ' .. beside)

        package.loaded['crimson-hitman.server.storage.json'] = nil
        local reopened = require('crimson-hitman.server.storage.json')
        reopened.open()
        local actions = {}
        for _, row in ipairs(reopened.readAudit()) do actions[#actions + 1] = row.action end
        eq(table.concat(actions, ','), 'a,release_interrupted,c', 'and every row reads back')
    end)
end)


--- The records — ledger, pending payouts, stats, reveals, kill photo
--- records — were fields of store.json, and every money write rewrote
--- store.json whole. They are records.json now, written only when one of
--- them changed.
describe('the records file', function()
    local function reopen()
        package.loaded['crimson-hitman.server.storage.json'] = nil
        local store = require('crimson-hitman.server.storage.json')
        return store, pcall(store.open)
    end

    local function owed(store)
        store.writeContract({ id = 'ctrec01', creator_cid = 'C', target_cid = 'T',
            state = CH.STATE.COMPLETED, created_at = os.time() })
        store.writeEscrow('ctrec01', { { id = 'ctrec01:1', contract_id = 'ctrec01', slot = 1,
            portion = 'baseline', source = 'cash', amount = 7000, owed_to = 'HITMAN01',
            state = CH.ESCROW_STATE.HELD } })
        store.queuePending('HITMAN01', 'ctrec01', 'ctrec01:1')
        store.writeLedger({ cid = 'HITMAN01', contract_id = 'ctrec01', role = 'hitman',
            resolved_at = os.time() })
        store.bumpStat('HITMAN01', 'completed', 1)
        store.close()
    end

    it('keeps them out of the index, and reads them back', function()
        local store = freshStore()
        owed(store)
        local index = json.decode(Natives.files['data/store.json'])
        eq(index.ledger, nil, 'no ledger in the index')
        eq(index.pending, nil, 'no pending payouts in it')
        eq(index.records, true, 'only that the records file exists')
        local records = json.decode(Natives.files['data/records.json'])
        truthy(records.pending and next(records.pending), 'the payout is in records.json')

        local reopened, ok = reopen()
        truthy(ok, 'it starts')
        eq(#reopened.readPending('HITMAN01'), 1, 'the payout owed is still owed')
        eq(#reopened.readLedger('HITMAN01', 10), 1, 'the ledger row is there')
        eq(reopened.readStats('HITMAN01').completed, 1, 'and the stat')
        eq(Natives.files['data/records.json.prev'], Natives.files['data/records.json'],
            'and the records as this start read them are kept to restore from')
    end)

    it('moves them out of an index that still carries them, records first', function()
        local store = freshStore()
        owed(store)
        -- An index as a version before the move wrote it: the records in it,
        -- and no records.json.
        local index = json.decode(Natives.files['data/store.json'])
        local records = json.decode(Natives.files['data/records.json'])
        for key, value in pairs(records) do index[key] = value end
        index.records = nil
        Natives.files['data/store.json'] = json.encode(index)
        Natives.files['data/records.json'] = nil

        local order = {}
        Natives.saveFile = function(file) order[#order + 1] = logical(file) end
        local moved, ok = reopen()
        Natives.saveFile = nil
        truthy(ok, 'it starts')
        local recordsAt, indexAt
        for i, file in ipairs(order) do
            if file == 'data/records.json' and not recordsAt then recordsAt = i end
            if file == 'data/store.json' and not indexAt then indexAt = i end
        end
        truthy(recordsAt and indexAt and recordsAt < indexAt,
            'records.json is written before an index without them: ' .. table.concat(order, ', '))
        eq(json.decode(Natives.files['data/store.json']).pending, nil, 'the index is without them')
        eq(#moved.readPending('HITMAN01'), 1, 'and nothing owed was lost in the move')

        local again, reopened = reopen()
        truthy(reopened, 'and it starts from the new layout')
        eq(#again.readPending('HITMAN01'), 1)
    end)

    it('does not start without a records file the index says it wrote', function()
        local store = freshStore()
        owed(store)
        local kept = Natives.files['data/records.json']
        Natives.files['data/records.json'] = ''
        local _, ok, err = reopen()
        falsy(ok, 'a missing records file is not an empty one')
        truthy(tostring(err):find('records.json.prev', 1, true), 'names the copy: ' .. tostring(err))
        eq(Natives.files['data/records.json'], '', 'and has written nothing over it')

        Natives.files['data/records.json'] = '{"pending":{"pnd1":'
        local _, torn = reopen()
        falsy(torn, 'nor a torn one')

        Natives.files['data/records.json'] = kept
        local restored, back = reopen()
        truthy(back, 'restored, it starts')
        eq(#restored.readPending('HITMAN01'), 1, 'with the payout still owed')
    end)

    it('does not write a payout ahead of the sequence its id came from', function()
        local store = freshStore()
        Natives.blocked = { ['data/store.json'] = true }
        local wrote = {}
        Natives.saveFile = function(file) wrote[logical(file)] = true end
        store.queuePending('HITMAN01', 'ctrec02', 'ctrec02:1')
        Natives.saveFile = nil
        Natives.blocked = {}
        falsy(wrote['data/records.json'],
            'with the index refused, the row whose id it minted waits for it')
        truthy(store.save(true), 'once the index can be written, both are')
        truthy(Natives.files['data/records.json']:find('ctrec02', 1, true))
    end)
end)


--- A whole file is written as <file>.new and renamed over <file>; where the
--- system will not rename over a file that exists (Windows), <file> is
--- moved aside to <file>.old first and removed once the copy is in place.
--- Each of these stops the server at one step of that and starts it again
--- on what was left on disk.
---
--- A stop is a coroutine never resumed: the write goes no further, as a
--- process that has died does not come back to finish it.
describe('a write the server stopped part-way', function()
    local ROOT = Natives.RESOURCE_ROOT .. '/'
    local SHARD = 'data/contracts/ctcrash1.json'

    local function reopen()
        package.loaded['crimson-hitman.server.storage.json'] = nil
        local store = require('crimson-hitman.server.storage.json')
        local ok, err = pcall(store.open)
        return store, ok, err
    end

    local function line(n)
        return { id = 'ctcrash1:' .. n, contract_id = 'ctcrash1', slot = 1,
            portion = 'baseline', source = 'cash', amount = 100 * n,
            state = CH.ESCROW_STATE.HELD }
    end

    --- On disk: a contract holding one line. Then a second line, written
    --- with the server stopping where `install` says, under `mode`
    --- ('windows': rename keeps a taken name; 'refused': no rename at all).
    --- What starting again finds is returned.
    local function stopWriting(install, mode, write)
        local store = freshStore()
        store.writeContract({ id = 'ctcrash1', creator_cid = 'C', target_cid = 'T',
            state = CH.STATE.ACTIVE, created_at = os.time() })
        store.writeEscrow('ctcrash1', { line(1) })
        truthy(store.save(true), 'the first write lands')
        Env.console = {}

        local realRename, realRemove = os.rename, os.remove
        Natives.renameKeeps = mode == 'windows' or nil
        Natives.renameRefused = mode == 'refused' or nil
        install(realRename, realRemove)
        local co = coroutine.create(write or function()
            store.writeEscrow('ctcrash1', { line(2) })
            store.save(true)
        end)
        local ok, err = coroutine.resume(co)
        os.rename, os.remove, Natives.saveFile = realRename, realRemove, nil
        Natives.renameKeeps, Natives.renameRefused = nil, nil
        if not ok then error(err, 0) end
        eq(coroutine.status(co), 'suspended', 'the server stopped where this test said')
        return reopen()
    end

    --- Stop inside SaveResourceFile, with half of `file` written.
    local function tornWhile(file)
        return function()
            Natives.saveFile = function(name, data)
                if name == file then
                    Natives.files[name] = data:sub(1, math.floor(#data / 2))
                    coroutine.yield()
                end
            end
        end
    end

    --- Stop at the rename to `to`: before it, or once it has happened.
    local function atRename(to, after)
        return function(realRename)
            os.rename = function(from, target)
                if target == ROOT .. to and not after then coroutine.yield() end
                local done, err = realRename(from, target)
                if target == ROOT .. to and after and done then coroutine.yield() end
                return done, err
            end
        end
    end

    local function holds(store, n)
        return store.readEscrowLine('ctcrash1:' .. n) ~= nil
    end

    it('tearing the copy leaves the file as it was', function()
        local store, ok, err = stopWriting(tornWhile(SHARD .. '.new'))
        truthy(ok, tostring(err))
        truthy(holds(store, 1) and not holds(store, 2), 'the last write that finished')
        eq(#store.quarantined(), 0, 'and nothing set aside')
    end)

    it('stopping before the rename leaves the file as it was', function()
        local store, ok, err = stopWriting(atRename(SHARD))
        truthy(ok, tostring(err))
        truthy(holds(store, 1) and not holds(store, 2))
        eq(#store.quarantined(), 0)
    end)

    it('on Windows, stopping with the file moved aside puts the copy back', function()
        -- The file is gone and its copy whole: set aside as missing, this was
        -- a contract and its escrow quarantined for a write that had finished.
        local store, ok, err = stopWriting(atRename(SHARD .. '.old', true), 'windows')
        truthy(ok, tostring(err))
        truthy(holds(store, 1) and holds(store, 2), 'the write the copy holds')
        eq(#store.quarantined(), 0, 'nothing quarantined')
        truthy(Natives.files[SHARD], 'the file is back in place')
        eq(Natives.files[SHARD .. '.new'], nil, 'renamed there, not written over')
        truthy(table.concat(Env.console, '\n'):find('put back', 1, true),
            'and the console says so')
    end)

    it('on Windows, stopping before the old file is removed loses nothing', function()
        local store, ok, err = stopWriting(function(_, realRemove)
            os.remove = function(target)
                if target == ROOT .. SHARD .. '.old' and Natives.files[SHARD .. '.old'] then
                    coroutine.yield()
                end
                return realRemove(target)
            end
        end, 'windows')
        truthy(ok, tostring(err))
        truthy(holds(store, 1) and holds(store, 2), 'the copy was in place')
        truthy(Natives.files[SHARD .. '.old'], 'with the old one still beside it')

        -- And the next write on Windows clears it out of the way first.
        Natives.renameKeeps = true
        local wrote = pcall(function()
            store.writeEscrow('ctcrash1', { line(3) })
            return store.save(true)
        end)
        Natives.renameKeeps = nil
        truthy(wrote)
        eq(Natives.files[SHARD .. '.old'], nil, 'no old file left')
        local again, reopened = reopen()
        truthy(reopened)
        truthy(holds(again, 3), 'and the write after it landed')
    end)

    it('on Windows, a write that is not stopped leaves only the file', function()
        local store = freshStore()
        Natives.renameKeeps = true
        local ok = pcall(function()
            store.writeContract({ id = 'ctcrash1', creator_cid = 'C', target_cid = 'T',
                state = CH.STATE.ACTIVE, created_at = os.time() })
            store.writeEscrow('ctcrash1', { line(1) })
            store.save(true)
            store.writeEscrow('ctcrash1', { line(2) })
            return store.save(true)
        end)
        Natives.renameKeeps = nil
        truthy(ok)
        for _, suffix in ipairs({ '.new', '.old' }) do
            eq(Natives.files[SHARD .. suffix], nil, suffix .. ' left behind')
            eq(Natives.files['data/store.json' .. suffix], nil, 'store.json' .. suffix)
        end
        local again, reopened = reopen()
        truthy(reopened)
        truthy(holds(again, 2))
    end)

    it('where renames are refused, a file torn in place is put back from its copy', function()
        local store, ok, err = stopWriting(tornWhile(SHARD), 'refused')
        truthy(ok, tostring(err))
        truthy(holds(store, 1) and holds(store, 2), 'the copy was written whole first')
        eq(#store.quarantined(), 0)
        truthy(Natives.files[SHARD .. '.torn'], 'the torn one is kept, not lost')
        truthy(table.concat(Env.console, '\n'):find('rename', 1, true),
            'and the console said renames were refused')
    end)

    it('a torn file with no whole copy is still set aside, not guessed at', function()
        local store = freshStore()
        store.writeContract({ id = 'ctcrash1', creator_cid = 'C', target_cid = 'T',
            state = CH.STATE.ACTIVE, created_at = os.time() })
        store.writeEscrow('ctcrash1', { line(1) })
        store.close()
        Natives.files[SHARD] = '{"contract":'
        Natives.files[SHARD .. '.new'] = '{"esc'
        local again, ok = reopen()
        truthy(ok, 'one contract is quarantined, the store still starts')
        eq(#again.quarantined(), 1, 'and that contract is named for staff')
        eq(Natives.files[SHARD], '{"contract":', 'with its file left as it was')
    end)

    --- The index and the records: a store that has run before refuses to
    --- start without them, and a copy beside a missing one is not "without".
    it('on Windows, an index stopped between renames is put back, not refused', function()
        local store, ok, err = stopWriting(atRename('data/store.json.old', true), 'windows',
            function()
                local s = require('crimson-hitman.server.storage.json')
                s.writeContract({ id = 'ctcrash2', creator_cid = 'C', target_cid = 'T',
                    state = CH.STATE.ACTIVE, created_at = os.time() })
                s.save(true)
            end)
        truthy(ok, 'refused as missing: ' .. tostring(err))
        truthy(store.readContract('ctcrash2'), 'with the contract the new index names')
        truthy(Natives.files['data/store.json'], 'and store.json back in place')
    end)

    it('on Windows, records stopped between renames are put back, not refused', function()
        local store, ok, err = stopWriting(atRename('data/records.json.old', true), 'windows',
            function()
                local s = require('crimson-hitman.server.storage.json')
                s.queuePending('HITMAN01', 'ctcrash1', 'ctcrash1:1')
                s.save(true)
            end)
        truthy(ok, tostring(err))
        eq(#store.readPending('HITMAN01'), 1, 'the payout owed is still owed')
    end)

    it('an index torn with its copy torn too is still refused, and left alone', function()
        local store = freshStore()
        store.writeContract({ id = 'ctcrash3', creator_cid = 'C', target_cid = 'T',
            state = CH.STATE.ACTIVE, created_at = os.time() })
        store.close()
        Natives.files['data/store.json'] = '{"contractIds":["ctcr'
        Natives.files['data/store.json.new'] = '{"contra'
        local _, ok, err = reopen()
        falsy(ok, 'nothing whole to put back')
        truthy(tostring(err):find('store.json.prev', 1, true), tostring(err))
        eq(Natives.files['data/store.json'], '{"contractIds":["ctcr', 'and nothing written over it')
    end)

    it('an audit day stopped between renames comes back with its rows', function()
        local day = 'data/audit-' .. os.date('!%Y-%m-%d', os.time()) .. '.jsonl'
        local store, ok, err = stopWriting(atRename(day .. '.old', true), 'windows', function()
            local s = require('crimson-hitman.server.storage.json')
            s.writeAudit({ ts = os.time(), kind = 'financial', action = 'first', detail = {} })
            s.flush()
            s.writeAudit({ ts = os.time(), kind = 'financial', action = 'second', detail = {} })
            s.flush()
        end)
        truthy(ok, tostring(err))
        local actions = {}
        for _, row in ipairs(store.readAudit()) do actions[#actions + 1] = row.action end
        eq(table.concat(actions, ','), 'first,second', 'every row, in its own file')
        truthy(Natives.files[day], 'the day file is back')
    end)

    --- A new contract is its file first, then the index naming it. Stopped
    --- between the two, the start kept the old whole index, ignored the
    --- whole store.json.new that named the contract, and never read the
    --- file: the contract, its escrow and the client's money were gone.
    local function placeNew()
        local s = require('crimson-hitman.server.storage.json')
        local sync = Config.Database.Json.SyncOnFinancialWrite
        Config.Database.Json.SyncOnFinancialWrite = false
        s.writeContract({ id = 'ctcrash4', creator_cid = 'C', target_cid = 'T',
            state = CH.STATE.ACTIVE, created_at = os.time() })
        s.writeEscrow('ctcrash4', { { id = 'ctcrash4:1', contract_id = 'ctcrash4', slot = 1,
            portion = 'baseline', source = 'bank', amount = 50000, state = CH.ESCROW_STATE.HELD } })
        Config.Database.Json.SyncOnFinancialWrite = sync
        s.save(true)
    end

    it('a new contract stopped before its index\'s rename is there at the next start', function()
        local store, ok, err = stopWriting(atRename('data/store.json'), nil, placeNew)
        truthy(ok, tostring(err))
        truthy(store.readContract('ctcrash4'), 'the contract the whole store.json.new names')
        eq(store.readEscrowLine('ctcrash4:1').amount, 50000, 'with its escrow')
        truthy(holds(store, 1), 'and everything the old index named')
        truthy((Natives.files['data/store.json'] or ''):find('ctcrash4', 1, true),
            'the newer index put in place')
        truthy(table.concat(Env.console, '\n'):find('newer of the two', 1, true),
            'and the console says so')
    end)

    it('a new contract whose index copy was torn is taken back in from its own file', function()
        local store, ok, err = stopWriting(tornWhile('data/store.json.new'), nil, function()
            -- And a finished contract's file a prune had not yet removed.
            Natives.files['data/contracts/ctdone01.json'] = json.encode({
                contract = { id = 'ctdone01', state = CH.STATE.COMPLETED, created_at = 1 },
                escrow = { ['ctdone01:1'] = { id = 'ctdone01:1', contract_id = 'ctdone01',
                    state = CH.ESCROW_STATE.SETTLED, amount = 10 } } })
            placeNew()
        end)
        truthy(ok, tostring(err))
        truthy(store.readContract('ctcrash4'), 'a file nothing names that holds money is read')
        eq(store.readEscrowLine('ctcrash4:1').amount, 50000)
        truthy(table.concat(Env.console, '\n'):find('taken back in: ctcrash4', 1, true),
            table.concat(Env.console, '\n'))
        eq(store.readContract('ctdone01'), nil, 'a finished one holding nothing is not')
        truthy(Natives.files['data/contracts/ctdone01.json'], 'and is left where it is')
        store.close()
        truthy((Natives.files['data/store.json'] or ''):find('ctcrash4', 1, true),
            'the index names it from now on')
    end)

    it('another mode, looking before it starts, counts the money in a copy', function()
        stopWriting(atRename(SHARD .. '.old', true), 'windows')
        -- Back as the moment of the stop: the file aside, the copy whole.
        Natives.files[SHARD .. '.new'] = Natives.files[SHARD]
        Natives.files[SHARD] = nil
        package.loaded['crimson-hitman.server.storage.json'] = nil
        local held = require('crimson-hitman.server.storage.json').inspect()
        eq(held.lines, 2, 'both lines are held, read from the copy')
        eq(Natives.files[SHARD], nil, 'and looking moves nothing')
    end)
end)

--------------------------------------------------------------------------
-- A contract taken off the index on purpose
--------------------------------------------------------------------------
--
-- The scan of contracts/ for a new contract's file the index had yet to
-- name (W158) took back in any file holding money or a running contract.
-- A contract pruned with a stale .old left beside it, or one staff took off
-- store.json by hand, came back at the next start, and a cancel then
-- refunded its money a second time.

describe('a contract taken off the index on purpose', function()
    local FILE = 'data/contracts/ctgone01.json'

    local function reopen()
        package.loaded['crimson-hitman.server.storage.json'] = nil
        Env.console = {}
        local store = require('crimson-hitman.server.storage.json')
        local ok, err = pcall(store.open)
        truthy(ok, tostring(err))
        return store
    end

    --- A running contract holding 5000, written and named. `first` is its
    --- file as first written, before any index named it.
    local function placed()
        local store = freshStore()
        store.writeContract({ id = 'ctgone01', creator_cid = 'C', target_cid = 'T',
            state = CH.STATE.ACTIVE, created_at = os.time() })
        local first = Natives.files[FILE]
        store.writeEscrow('ctgone01', { { id = 'ctgone01:1', contract_id = 'ctgone01', slot = 1,
            portion = 'baseline', source = 'cash', amount = 5000, state = CH.ESCROW_STATE.HELD } })
        truthy(store.save(true))
        return store, first
    end

    local function dropById()
        local index = json.decode(Natives.files['data/store.json'])
        local kept = {}
        for _, id in ipairs(index.contractIds) do
            if id ~= 'ctgone01' then kept[#kept + 1] = id end
        end
        index.contractIds = kept
        Natives.files['data/store.json'] = json.encode(index)
    end

    local function takenBack()
        return table.concat(Env.console, '\n'):find('taken back in', 1, true) ~= nil
    end

    it('pruned, its copies go with it, and a stale .old is never taken back in', function()
        local store, first = placed()
        local c = store.readContract('ctgone01')
        c.state, c.resolved_at = CH.STATE.CANCELLED, os.time() - 31 * 86400
        store.writeContract(c)
        truthy(store.claimEscrowLine('ctgone01:1', CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING))
        truthy(store.settleEscrowLine('ctgone01:1', 'C'))
        Natives.files[FILE .. '.old'] = first
        Natives.files[FILE .. '.torn'] = '{"contract":'
        store.prune()
        truthy(store.save(true))
        eq(store.readContract('ctgone01'), nil, 'pruned')
        eq(Natives.files[FILE], nil)
        eq(Natives.files[FILE .. '.old'], nil, 'its .old with it')
        eq(Natives.files[FILE .. '.torn'], nil, 'and a torn one set aside')

        -- An .old a remove could not take (an antivirus holding it), as the
        -- contract was while it was running and held the money.
        Natives.files[FILE .. '.old'] = first
        local again = reopen()
        eq(again.readContract('ctgone01'), nil, 'not back as running')
        falsy(takenBack(), table.concat(Env.console, '\n'))
        eq(again.inspect().contracts, 0, 'nor counted by a mode switch')
    end)

    it('taken off store.json by hand with its file left in contracts/, stays off', function()
        local store = placed()
        store.close()
        dropById()
        local again = reopen()
        eq(again.readContract('ctgone01'), nil, 'staff dropped it, and it stays dropped')
        falsy(takenBack(), table.concat(Env.console, '\n'))
        truthy(Natives.files[FILE], 'its file left where it is')
        again.close()
        falsy((Natives.files['data/store.json'] or ''):find('ctgone01', 1, true),
            'and the index does not name it again')
    end)

    it('taken off by hand while its file is only as first written, before any index named it', function()
        local store, first = placed()
        store.close()
        dropById()
        Natives.files[FILE] = first
        local again = reopen()
        eq(again.readContract('ctgone01'), nil,
            'an index named it after that file was written, so it is not a new one')
        falsy(takenBack(), table.concat(Env.console, '\n'))
    end)

    --- Where renames are refused every file keeps a whole .new beside it,
    --- store.json's at the same count as store.json. Taken as newer, it put
    --- back an id staff had taken out, and said the server stopped mid-write.
    it('on a server that cannot rename, a hand edit of store.json is kept', function()
        local store = freshStore()
        Natives.renameRefused = true
        store.writeContract({ id = 'ctgone01', creator_cid = 'C', target_cid = 'T',
            state = CH.STATE.ACTIVE, created_at = os.time() })
        store.writeEscrow('ctgone01', { { id = 'ctgone01:1', contract_id = 'ctgone01', slot = 1,
            portion = 'baseline', source = 'cash', amount = 5000, state = CH.ESCROW_STATE.HELD } })
        store.close()
        truthy(Natives.files['data/store.json.new'], 'the copy stays beside it')
        dropById()
        Natives.files[FILE] = nil
        local again = reopen()
        Natives.renameRefused = nil
        eq(again.readContract('ctgone01'), nil, 'the edit stands')
        falsy(table.concat(Env.console, '\n'):find('newer of the two', 1, true),
            'and nothing says the server stopped mid-write: ' .. table.concat(Env.console, '\n'))
        falsy(takenBack(), 'nor is it taken back from its own .new')
    end)
end)

--------------------------------------------------------------------------
-- An abandon a store call stopped part-way
--------------------------------------------------------------------------
--
-- Contracts.abandon writes the row, then hands the stake to the client,
-- then puts an exclusive contract nobody is on back on the board. A store
-- call that raised in between left it ACCEPTED with nobody on it, every
-- acceptance refused, and the stake held under a row that walked away,
-- which the ending, or a refused retake, gave back to the walker.

describe('an abandon a store call stopped part-way', function()
    local function staked(mode)
        local s = newStack()
        local f = fixture(s)
        Env.players[3].PlayerData.money.bank = 50000
        Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
            cash = 5000, bank = 50000, firstname = 'Sol', lastname = 'Vane' })
        local c = assert(s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt', mode = mode,
            reward = { baseline = { cash = 5000 } }, penaltyAmount = 2000,
        }))
        truthy(s.contracts.accept(f.hitman, c.id, false))
        return s, f, c
    end

    --- The abandon, with the store's `name` raising the first time it is
    --- called, after the abandon has written its row.
    local function stopped(s, f, c, name)
        local real, raised = s.storage[name], false
        s.storage[name] = function(...)
            if not raised then
                raised = true
                error('the connection dropped', 0)
            end
            return real(...)
        end
        local ran = pcall(s.contracts.abandon, f.hitman, c.id)
        s.storage[name] = real
        falsy(ran, 'the abandon raised part-way')
        eq(s.storage.readHitman(c.id, 'HITMAN01').state, 'abandoned', 'after its row')
    end

    local function bank(src) return Env.players[src].PlayerData.money.bank end

    it('exclusive: the next tick puts it back on the board, and the stake goes to the client', function()
        local s, f, c = staked(CH.MODE.EXCLUSIVE)
        stopped(s, f, c, 'readEscrow')
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'held by nobody')
        local client = bank(1)

        s.contracts.releaseIdleHolds()
        eq(s.storage.readContract(c.id).state, CH.STATE.ACTIVE, 'back on the board')
        eq(bank(1) - client, 2000, 'the walked-away stake is the client\'s')
        eq(bank(3), 48000, 'and not the hitman\'s who walked away')
        truthy(s.contracts.accept(s.identity.resolve(4), c.id, false), 'and another may take it')
    end)

    it('exclusive: a retake that is refused does not hand the stake back', function()
        local s, f, c = staked(CH.MODE.EXCLUSIVE)
        stopped(s, f, c, 'readEscrow')
        local client = bank(1)
        -- Refused before anything is read of the stake: the one who walked
        -- away may not take it straight back (RETAKE_TOO_SOON). The stake
        -- is the client's all the same, by the next pass.
        local ok, err = s.contracts.accept(f.hitman, c.id, false)
        falsy(ok, 'held by nobody, and still refused')
        eq(err, CH.ERR.RETAKE_TOO_SOON)
        eq(bank(3), 48000, 'not back to the hitman who walked away')
        s.contracts.releaseIdleHolds()
        eq(bank(1) - client, 2000, 'the stake went to the client')
        eq(bank(3), 48000)
    end)

    --- The repair waits for an acceptance in flight, which holds the
    --- contract's key, rather than undoing anything under it.
    it('exclusive: the tick leaves alone a contract an acceptance is running on', function()
        local s, f, c = staked(CH.MODE.EXCLUSIVE)
        stopped(s, f, c, 'readEscrow')
        local real, fired, seen = s.storage.readHitman, false, nil
        s.storage.readHitman = function(...)
            if not fired then
                fired = true
                s.contracts.releaseIdleHolds()
                seen = s.storage.readContract(c.id).state
            end
            return real(...)
        end
        s.contracts.accept(s.identity.resolve(4), c.id, false)
        s.storage.readHitman = real
        eq(seen, CH.STATE.ACCEPTED, 'nothing was changed under the acceptance')
        s.contracts.releaseIdleHolds()
        eq(s.storage.readContract(c.id).state, CH.STATE.ACTIVE, 'and the next pass finished it')
    end)

    it('competitive: a retake straight after, then a completion, hands back only the new stake', function()
        local s, f, c = staked(CH.MODE.COMPETITIVE)
        stopped(s, f, c, 'claimEscrowLine')
        local client = bank(1)
        truthy(s.contracts.accept(f.hitman, c.id, false), 'taken straight back')
        eq(bank(1) - client, 2000, 'the walked-away stake went to the client first')
        eq(bank(3), 46000, 'and a new one was staked')
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        eq(bank(3), 48000, 'only the new stake came back')
        eq(bank(1) - client, 2000, 'and the client kept the old one')
    end)
end)

--- W067: the change went in first and 'applied' was written after, so a
--- write that raised left the proposal open and still waiting on the last
--- answer, and a second Agree cut the deadline again. On a copying store,
--- as a database answers.
describe('an agreed change whose last write raises', function()
    it('is not applied a second time by a second Agree', function()
        local s = newCopyingStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            mode = CH.MODE.EXCLUSIVE, reward = { baseline = { cash = 5000 } } })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local p = s.amendments.propose(f.creator, c.id, CH.AMENDMENT.SHORTEN_DEADLINE,
            { seconds = 1800 })
        truthy(p and p.outcome == 'open')
        local before = s.storage.readContract(c.id).deadline_at

        local real = s.storage.writeAmendment
        s.storage.writeAmendment = function(a)
            if a.outcome == 'applied' then error('oxmysql: Connection lost', 0) end
            return real(a)
        end
        falsy(pcall(s.amendments.respond, f.hitman, p.id, true), 'the last write raised')
        s.storage.writeAmendment = real
        eq(before - s.storage.readContract(c.id).deadline_at, 1800, 'cut once')

        local ok, err = s.amendments.respond(f.hitman, p.id, true)
        falsy(ok, 'agreed again, and applied again')
        eq(err, CH.ERR.NOT_FOUND)
        eq(before - s.storage.readContract(c.id).deadline_at, 1800, 'still cut once')
    end)
end)
