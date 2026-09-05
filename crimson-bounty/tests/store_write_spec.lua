--- Writing the json store on a real server.
---
--- Observed in production, repeating on every flush:
---   [crimson-bounty] write verification failed for data/store.json;
---   keeping the previous file
---
--- Which means nothing was being persisted at all. The write itself
--- succeeded; the read-back used to judge it did not agree, and the store
--- threw away a write that had landed.

local function freshStore()
    package.loaded['crimson-bounty.server.storage.json'] = nil
    Natives.files = {}
    Natives.blocked = {}
    Natives.saveFile = nil
    Natives.loadFile = nil
    local store = require('crimson-bounty.server.storage.json')
    store.open()
    return store
end

describe('writing the json store', function()
    it('writes the file it means to write', function()
        local store = freshStore()
        store.writeContract({ id = 'ct1', creator_cid = 'CREATOR1', target_cid = 'T',
            state = CB.STATE.ACTIVE, created_at = os.time() })
        truthy(store.save(true), 'the flush must report success')
        truthy(Natives.files['data/store.json'], 'and the index has to be on disk')
        truthy(Natives.files['data/contracts/ct1.json'], 'along with the contract')
    end)

    it('does not write the same file twice to do it', function()
        -- The temp file was written in full, read back, and then the real
        -- file was written in full as well: two complete writes per flush,
        -- and no rename between them, so nothing was ever made atomic by
        -- it either.
        local store = freshStore()
        local written = {}
        Natives.saveFile = function(file) written[#written + 1] = file end
        store.writeContract({ id = 'ct2', creator_cid = 'C', target_cid = 'T',
            state = CB.STATE.ACTIVE, created_at = os.time() })
        store.save(true)
        Natives.saveFile = nil

        local temps = 0
        for _, file in ipairs(written) do
            if file:find('%.tmp$') then temps = temps + 1 end
        end
        eq(temps, 0,
            'a temp file that is never renamed is I/O for nothing: ' ..
            table.concat(written, ', '))
    end)

    it('keeps the write when the read-back disagrees but the write succeeded', function()
        -- This is the production symptom. SaveResourceFile said it wrote
        -- the file; the read-back came back a different size. Discarding on
        -- that basis turns "probably fine" into "certainly lost".
        local store = freshStore()
        store.writeContract({ id = 'ct3', creator_cid = 'C', target_cid = 'T',
            state = CB.STATE.ACTIVE, created_at = os.time() })

        -- A read that does not agree with what was just written.
        local realLoad = _G.LoadResourceFile
        _G.LoadResourceFile = function(res, file)
            local content = realLoad(res, file)
            if file == 'data/store.json' and content then return content:sub(1, 5) end
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
        package.loaded['crimson-bounty.server.storage.json'] = nil
        local reopened = require('crimson-bounty.server.storage.json')
        reopened.open()
        truthy(reopened.readContract('ct3'),
            'a contract written before a restart has to be there after it')
    end)

    it('does report a write the engine actually refused', function()
        -- The check has to keep working where it can. A refused write is
        -- not the same as a read-back that disagreed.
        local store = freshStore()
        store.writeContract({ id = 'ct4', creator_cid = 'C', target_cid = 'T',
            state = CB.STATE.ACTIVE, created_at = os.time() })
        Natives.blocked = { ['data/store.json'] = true }
        local ok = store.save(true)
        Natives.blocked = {}
        falsy(ok, 'a write the engine refused is a failed flush')
    end)

    it('does not print the same complaint on every flush', function()
        -- The production log was this line and nothing else, over and over.
        -- A warning that repeats forever buries whatever comes after it.
        local store = freshStore()
        local realLoad = _G.LoadResourceFile
        _G.LoadResourceFile = function(res, file)
            local content = realLoad(res, file)
            if file == 'data/store.json' and content then return content:sub(1, 5) end
            return content
        end

        Env.console = {}
        for i = 1, 20 do
            store.writeContract({ id = 'ctm' .. i, creator_cid = 'C', target_cid = 'T',
                state = CB.STATE.ACTIVE, created_at = os.time() })
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
end)
