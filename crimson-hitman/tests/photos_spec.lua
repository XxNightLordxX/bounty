--- The kill photo kept for a contract's client, and the one look they get
--- (server/photos.lua).
---
--- Every test here is about who can see a photograph of somebody's corpse,
--- and for how long. The rules: the client who placed the contract is the
--- only person who ever sees it; they see it once, by asking; nobody else
--- learns anything by asking with its handle; and every way it can end —
--- deleted, saved, left open, never opened, pushed off the ledger, voided
--- by staff — leaves no link behind.

local URL = 'https://cdn.fivemanage.com/proof.png'

--- A contract, an accepted hitman and a kill the server saw.
local function killed(opts)
    opts = opts or {}
    local s = newStack()
    local f = fixture(s)
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt',
        mode = CH.MODE.COMPETITIVE,
        reward = opts.reward or { baseline = { cash = 5000 } },
    })
    truthy(c, 'the contract has to exist')
    truthy(s.contracts.accept(f.hitman, c.id, false))
    Config.Completion.ExtraPhotoHosts = { 'cdn.fivemanage.com' }
    s.photo.loadAllowedHosts()

    Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
    Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
    Env.players[2]._health = 140
    s.death.recordDamage(3, 2, 123456)
    Env.players[2].PlayerData.metadata.isdead = true
    s.death.onVictimReport(2)
    return s, f, c
end

--- Killed and photographed: the client's photo is waiting.
local function photographed(opts)
    local s, f, c = killed(opts)
    local token = s.photo.issue(f.hitman, c.id)
    truthy(token, 'the hitman has to be able to photograph the kill')
    local ok, err = s.photo.submit(f.hitman, token, URL)
    truthy(ok, 'the photo has to be accepted: ' .. tostring(err))
    local handle = s.storage.readLedger('CREATOR1', 10)[1].photo_ref
    truthy(handle, 'the client row has to name the photo')
    return s, f, c, handle
end

--- Fire a handler the way a client does and hand back the reply.
local function call(name, src, payload)
    local fire = Env.events['crimson-hitman:' .. name]
    if not fire then return { ok = false, err = 'NO SUCH HANDLER' } end
    Env.clientEvents = {}
    _G.source = src
    local fired, err = pcall(fire, payload or {})
    _G.source = nil
    if not fired then return { ok = false, err = 'THREW: ' .. tostring(err) } end
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:result' then return event.args[1] end
    end
    return nil
end

--- Everything in a value, flattened to one string, for "does X appear
--- anywhere in what was sent".
local function flat(value, out)
    out = out or {}
    if type(value) == 'table' then
        for k, v in pairs(value) do
            out[#out + 1] = tostring(k)
            flat(v, out)
        end
    elseif value ~= nil then
        out[#out + 1] = tostring(value)
    end
    return table.concat(out, ' ')
end

describe('who a kill photo is kept for', function()
    it('keeps it for the client, by a handle, and names no hitman', function()
        local s, _, c, handle = photographed()
        local record = s.storage.readPhoto(handle)
        truthy(record, 'a record behind the handle')
        eq(record.owner_cid, 'CREATOR1')
        eq(record.contract_id, c.id)
        eq(record.state, CH.PHOTO.PENDING)
        eq(record.url, URL)
        falsy(flat(record):find('HITMAN01', 1, true),
            'the record goes to nobody but the client, and has no business knowing who took it')
    end)

    it('puts no photo on the hitman row or the target row', function()
        local s = photographed()
        falsy(s.storage.readLedger('HITMAN01', 10)[1].photo_ref,
            'the photo must not stay on the phone of the hitman who took it')
        falsy(s.storage.readLedger('TARGET01', 10)[1].photo_ref)
    end)

    it('shows the client a handle and a state, and nobody a link', function()
        local s, _, _, handle = photographed()

        local mine = call('ledger', 1, {})
        truthy(mine and mine.ok, 'the client reads their ledger')
        local row = mine.data.entries[1]
        eq(row.role, 'creator')
        truthy(row.photo, 'their row offers the photo')
        eq(row.photo.handle, handle)
        eq(row.photo.state, CH.PHOTO.PENDING)
        falsy(row.photo_ref, 'the stored reference is not sent as it is')
        falsy(row.cid, 'nor the cid the row is filed under')
        falsy(flat(mine):find('fivemanage', 1, true),
            'reading the ledger is not opening the photo: the page reads it on every refresh')

        for _, src in ipairs({ 2, 3 }) do
            local theirs = call('ledger', src, {})
            truthy(theirs and theirs.ok)
            falsy(theirs.data.entries[1].photo, 'source ' .. src .. ' is offered no photo')
            falsy(flat(theirs):find(handle, 1, true), 'nor told its handle')
            falsy(flat(theirs):find('fivemanage', 1, true))
        end
    end)

    it('never sends a link left on a row from before the one view', function()
        local s = newStack()
        fixture(s)
        s.storage.writeLedger({ cid = 'CREATOR1', contract_id = 'ct00000001', role = 'creator',
            resolved_at = os.time(), photo_ref = URL })
        s.storage.writeLedger({ cid = 'HITMAN01', contract_id = 'ct00000001', role = 'hitman',
            resolved_at = os.time(), photo_ref = URL })
        for _, src in ipairs({ 1, 3 }) do
            local reply = call('ledger', src, {})
            truthy(reply and reply.ok)
            falsy(reply.data.entries[1].photo)
            falsy(flat(reply):find('fivemanage', 1, true),
                'a link stored before the upgrade went to whoever opened their ledger')
        end
    end)

    it('keeps nothing when the ledger keeps no photos', function()
        local s, f, c = killed()
        withConfig({ { Config.Ledger, 'StorePhotos', false } }, function()
            Natives.calls.notifications = {}
            local token = s.photo.issue(f.hitman, c.id)
            truthy(s.photo.submit(f.hitman, token, URL))
            falsy(s.storage.readLedger('CREATOR1', 10)[1].photo_ref)
            eq(#s.storage.photosOf('CREATOR1'), 0, 'no record at all')
            local said = flat(Natives.calls.notifications)
            truthy(said:find('fulfilled', 1, true), said)
            falsy(said:find('Ledger', 1, true),
                'the client is not sent looking for a photo that was never kept: ' .. said)
        end)
    end)
end)

describe('the one look', function()
    it('hands the client the photo once', function()
        local s, _, _, handle = photographed()
        local first = call('openPhoto', 1, { handle = handle })
        truthy(first and first.ok, 'the client opens it: ' .. tostring(first and first.err))
        eq(first.data.url, URL)
        eq(first.data.handle, handle)
        eq(s.storage.readPhoto(handle).state, CH.PHOTO.OPEN)

        local second = call('openPhoto', 1, { handle = handle })
        falsy(second.ok, 'a second look is refused')
        eq(second.err, CH.ERR.PHOTO_GONE)
        falsy(second.data, 'and carries nothing')
    end)

    it('answers anybody else exactly as a handle that does not exist', function()
        for _, src in ipairs({ 2, 3 }) do
            local s, _, _, handle = photographed()
            local unknown = call('openPhoto', src, { handle = 'ph0000000000zz' })
            local theirs = call('openPhoto', src, { handle = handle })
            eq(theirs.ok, false)
            eq(theirs.err, unknown.err, 'source ' .. src .. ': the answers must not differ')
            eq(theirs.data, unknown.data)
            eq(theirs.err, CH.ERR.PHOTO_GONE)
            eq(s.storage.readPhoto(handle).state, CH.PHOTO.PENDING,
                'and asking spent nothing of the client look')

            local decided = call('photoDecision', src, { handle = handle, choice = 'delete' })
            local decidedUnknown = call('photoDecision', src,
                { handle = 'ph0000000000zz', choice = 'delete' })
            eq(decided.err, decidedUnknown.err)
            eq(decided.data, decidedUnknown.data)
        end
    end)

    it('lets only one of two requests racing to open it see it', function()
        local s, f, _, handle = photographed()
        -- Both read the record before either writes: the store has to be
        -- what decides, not the read. A copy, as mysql hands back.
        local record = {}
        for k, v in pairs(s.storage.readPhoto(handle)) do record[k] = v end
        local realRead = s.storage.readPhoto
        s.storage.readPhoto = function() return record end
        local a = s.photos.open(f.creator, handle)
        local b, err = s.photos.open(f.creator, handle)
        s.storage.readPhoto = realRead
        truthy(a, 'the first is shown it')
        falsy(b, 'the second is not')
        eq(err, CH.ERR.PHOTO_GONE)
    end)

    it('forgets the link when the client saves it', function()
        local s, _, _, handle = photographed()
        truthy(call('openPhoto', 1, { handle = handle }).ok)
        local saved = call('photoDecision', 1, { handle = handle, choice = 'save' })
        truthy(saved and saved.ok, tostring(saved and saved.err))
        eq(saved.data.state, CH.PHOTO.SAVED)
        local record = s.storage.readPhoto(handle)
        eq(record.state, CH.PHOTO.SAVED)
        falsy(record.url, 'the phone has it now; the server keeps no link')
        eq(call('ledger', 1, {}).data.entries[1].photo.state, CH.PHOTO.SAVED,
            'the row says what became of it')
    end)

    it('forgets the link when the client deletes it', function()
        local s, _, _, handle = photographed()
        truthy(call('openPhoto', 1, { handle = handle }).ok)
        truthy(call('photoDecision', 1, { handle = handle, choice = 'delete' }).ok)
        local record = s.storage.readPhoto(handle)
        eq(record.state, CH.PHOTO.DELETED)
        falsy(record.url)
        falsy(call('openPhoto', 1, { handle = handle }).ok, 'and it cannot be opened again')
    end)

    it('takes a decision only on a photo that is open, once', function()
        local s, _, _, handle = photographed()
        local early = call('photoDecision', 1, { handle = handle, choice = 'save' })
        eq(early.err, CH.ERR.PHOTO_GONE, 'saving a photo nobody has looked at is not a look')
        eq(s.storage.readPhoto(handle).state, CH.PHOTO.PENDING)

        truthy(call('openPhoto', 1, { handle = handle }).ok)
        eq(call('photoDecision', 1, { handle = handle, choice = 'archive' }).err,
            CH.ERR.INVALID_INPUT, 'save, delete, keep or link, nothing else')
        truthy(call('photoDecision', 1, { handle = handle, choice = 'delete' }).ok)
        eq(call('photoDecision', 1, { handle = handle, choice = 'save' }).err,
            CH.ERR.PHOTO_GONE, 'a deleted photo is not saved after all')
        eq(s.storage.readPhoto(handle).state, CH.PHOTO.DELETED)
    end)

    it('deletes a photo left open too long', function()
        local s, _, _, handle = photographed()
        truthy(call('openPhoto', 1, { handle = handle }).ok)

        Env.advance(Config.Completion.PhotoOpenSeconds - 5)
        eq(s.photos.expire(), 0, 'not before its time')
        eq(s.storage.readPhoto(handle).state, CH.PHOTO.OPEN)

        Env.advance(10)
        eq(s.photos.expire(), 1, 'the phone closed mid-view')
        local record = s.storage.readPhoto(handle)
        eq(record.state, CH.PHOTO.DELETED)
        falsy(record.url)
        eq(call('photoDecision', 1, { handle = handle, choice = 'save' }).err, CH.ERR.PHOTO_GONE)
    end)

    it('runs the open-photo expiry on the maintenance tick', function()
        local src = read_file('crimson-hitman/server/main.lua')
        truthy(src:find("job%('photos%.expire', modules%.photos%.expire%)"),
            'nothing else would ever delete a photo the phone closed on')
    end)
end)

describe('a photo kept for the client in the app, from an image host', function()
    --- A host photo the phone would not save (the gallery refused it): the
    --- link is kept on the record, and nothing is downloaded.
    local function kept()
        local s, f, c, handle = photographed()
        truthy(call('openPhoto', 1, { handle = handle }).ok)
        local reply = call('photoDecision', 1, { handle = handle, choice = 'keep' })
        truthy(reply and reply.ok, tostring(reply and reply.err))
        eq(reply.data.state, CH.PHOTO.KEPT)
        return s, f, c, handle
    end

    it('keeps the link, and offers it again as often as the client likes', function()
        local s, _, _, handle = kept()
        local record = s.storage.readPhoto(handle)
        eq(record.state, CH.PHOTO.KEPT)
        eq(record.url, URL, 'the link stays; nothing is downloaded')
        eq(call('ledger', 1, {}).data.entries[1].photo.state, CH.PHOTO.KEPT)
        for _ = 1, 3 do
            local again = call('openPhoto', 1, { handle = handle })
            truthy(again and again.ok, 'a kept photo opens again')
            eq(again.data.url, URL)
            eq(again.data.kept, true, 'and says it is kept')
        end
        eq(s.storage.readPhoto(handle).state, CH.PHOTO.KEPT, 'opening it spends nothing')
    end)

    it('is still the client\'s alone', function()
        local _, _, _, handle = kept()
        for _, src in ipairs({ 2, 3 }) do
            local theirs = call('openPhoto', src, { handle = handle })
            local unknown = call('openPhoto', src, { handle = 'ph0000000000zz' })
            eq(theirs.err, unknown.err, 'source ' .. src)
            eq(theirs.data, unknown.data)
            eq(call('photoDecision', src, { handle = handle, choice = 'delete' }).err,
                CH.ERR.PHOTO_GONE)
        end
    end)

    it('is deleted when the client deletes it, and only then', function()
        local s, _, _, handle = kept()
        eq(call('photoDecision', 1, { handle = handle, choice = 'save' }).err, CH.ERR.PHOTO_GONE,
            'a kept photo is opened and deleted, nothing else')
        eq(call('photoDecision', 1, { handle = handle, choice = 'keep' }).err, CH.ERR.PHOTO_GONE)
        truthy(call('photoDecision', 1, { handle = handle, choice = 'delete' }).ok)
        local record = s.storage.readPhoto(handle)
        eq(record.state, CH.PHOTO.DELETED)
        falsy(record.url, 'no link left behind')
        falsy(call('openPhoto', 1, { handle = handle }).ok)
    end)

    it('cannot be kept before it is opened, or kept twice', function()
        local s, _, _, handle = photographed()
        eq(call('photoDecision', 1, { handle = handle, choice = 'keep' }).err, CH.ERR.PHOTO_GONE,
            'keeping a photo nobody looked at is not a look')
        eq(s.storage.readPhoto(handle).state, CH.PHOTO.PENDING)
    end)

    it('outlives the open-photo expiry, the retention and its ledger row', function()
        local s, _, _, handle = kept()
        Env.advance(Config.Completion.PhotoOpenSeconds + 5)
        eq(s.photos.expire(), 0)
        Env.advance(Config.Ledger.PhotoRetentionDays * 86400 + 1)
        s.ledger.forgetOldPhotos()
        eq(s.storage.readPhoto(handle).state, CH.PHOTO.KEPT, 'not the retention\'s')

        local depth = math.min(Config.Ledger.Depth, Config.Ledger.MaxDepthHardCap)
        for i = 1, depth do
            Env.advance(1)
            s.ledger.record({ id = 'cx' .. i, creator_cid = 'OTHER001', target_cid = 'TARGET99',
                target_name = 'Somebody' }, 'CREATOR1', nil, CH.FULFILMENT.KIDNAPPING, { slot = 1 })
        end
        eq(s.storage.readPhoto(handle).state, CH.PHOTO.KEPT, 'nor pushed out with its row')
        local ledger = call('ledger', 1, {})
        for _, row in ipairs(ledger.data.entries) do falsy(row.photo, 'no row names it now') end
        eq(#ledger.data.kept, 1, 'so the Ledger lists it on its own')
        eq(ledger.data.kept[1].handle, handle)
        eq(ledger.data.kept[1].state, CH.PHOTO.KEPT)
        falsy(flat(ledger.data.kept):find('fivemanage', 1, true), 'by handle, never by link')
        eq(#call('ledger', 3, {}).data.kept, 0, 'and to nobody else')
    end)

    it('goes after Config.Completion.KeptPhotoDays, where that is set', function()
        local s, _, _, handle = kept()
        Env.advance(400 * 86400)
        eq(s.photos.forgetKept(), 0, 'unset: kept until the client deletes it')
        Config.Completion.KeptPhotoDays = 500
        eq(s.photos.forgetKept(), 0, 'not before its time')
        Env.advance(101 * 86400)
        eq(s.photos.forgetKept(), 1)
        local record = s.storage.readPhoto(handle)
        eq(record.state, CH.PHOTO.DELETED)
        falsy(record.url)
    end)

    it('runs the kept-photo limit on the maintenance tick', function()
        local src = read_file('crimson-hitman/server/main.lua')
        truthy(src:find("job%('photos%.forgetKept', modules%.photos%.forgetKept%)"),
            'nothing else would ever apply KeptPhotoDays')
    end)

    it('is deleted when staff void the contract', function()
        local s, _, c, handle = photographed({
            reward = { slots = { { baseline = { cash = 1000 } }, { baseline = { cash = 1000 } } } } })
        truthy(call('openPhoto', 1, { handle = handle }).ok)
        truthy(call('photoDecision', 1, { handle = handle, choice = 'keep' }).ok)
        truthy(s.admin.void(0, c.id, 'abuse'))
        eq(s.storage.readPhoto(handle).state, CH.PHOTO.DELETED,
            'a voided contract leaves no photo held in the app')
    end)
end)

describe('every other way a photo ends', function()
    it('forgets a photo whose row is pushed off the client ledger', function()
        local s, _, _, handle = photographed()
        local depth = math.min(Config.Ledger.Depth, Config.Ledger.MaxDepthHardCap)
        -- The client works contracts of their own: hitman rows in their own
        -- ledger push their client row out as surely as client rows would.
        for i = 1, depth do
            Env.advance(1)
            s.ledger.record({ id = 'cx' .. i, creator_cid = 'OTHER001', target_cid = 'TARGET99',
                target_name = 'Somebody' }, 'CREATOR1', nil, CH.FULFILMENT.KIDNAPPING, { slot = 1 })
        end
        for _, row in ipairs(s.storage.readLedger('CREATOR1', depth)) do
            falsy(row.photo_ref == handle, 'the row should have been pushed out')
        end
        falsy(s.storage.readPhoto(handle), 'and the photo with it')
    end)

    it('does not take a photo whose row is still being written for a pushed-out one', function()
        local s = photographed()
        local depth = math.min(Config.Ledger.Depth, Config.Ledger.MaxDepthHardCap)
        for i = 1, depth do
            Env.advance(1)
            s.storage.writeLedger({ cid = 'CREATOR1', contract_id = 'cy' .. i, role = 'hitman',
                resolved_at = os.time() })
        end
        -- A second collection claimed in the same moment: kept, its row not
        -- written yet.
        local fresh = s.photos.keep({ id = 'cz000001', creator_cid = 'CREATOR1' }, 2,
            { kind = 'url', url = URL })
        truthy(fresh)
        s.photos.evict('CREATOR1')
        truthy(s.storage.readPhoto(fresh), 'newer than every row, so not one that was pushed out')
    end)

    it('deletes the photos of a contract staff void', function()
        local s, _, c, handle = photographed({
            reward = { slots = { { baseline = { cash = 1000 } }, { baseline = { cash = 1000 } } } } })
        falsy(CH.TERMINAL[s.storage.readContract(c.id).state],
            'one collection of two leaves it running, for staff to void')
        truthy(s.admin.void(0, c.id, 'abuse'))
        local record = s.storage.readPhoto(handle)
        eq(record.state, CH.PHOTO.DELETED, 'not left waiting out the retention days')
        falsy(record.url)
    end)

    it('forgets a saved or deleted photo with its row once the retention passes', function()
        local s, _, _, handle = photographed()
        truthy(call('openPhoto', 1, { handle = handle }).ok)
        truthy(call('photoDecision', 1, { handle = handle, choice = 'save' }).ok)
        Env.advance(Config.Ledger.PhotoRetentionDays * 86400 + 1)
        s.ledger.forgetOldPhotos()
        falsy(s.storage.readPhoto(handle))
        falsy(s.storage.readLedger('CREATOR1', 10)[1].photo_ref)
    end)
end)

describe('telling the client', function()
    it('says the photo can be seen once, and where', function()
        local s, f, c = killed()
        Natives.calls.notifications = {}
        local token = s.photo.issue(f.hitman, c.id)
        truthy(s.photo.submit(f.hitman, token, URL))
        local said = flat(Natives.calls.notifications)
        truthy(said:find('Ledger', 1, true), 'where to find it: ' .. said)
        truthy(said:find('once', 1, true), 'and that it is one look: ' .. said)
        falsy(said:find('fivemanage', 1, true), 'never the link itself')
    end)

    it('pushes the client again once their row is written', function()
        local s, f, c = killed()
        local token = s.photo.issue(f.hitman, c.id)
        truthy(s.photo.submit(f.hitman, token, URL))
        -- Held behind the push floor if the claim's own push went this
        -- second; it still goes.
        Env.advance(5)
        local reasons = {}
        for i = 1, #Env.clientEvents do
            local event = Env.clientEvents[i]
            if event.name == 'crimson-hitman:push' and event.target == 1 then
                reasons[#reasons + 1] = tostring(event.args[1] and event.args[1].reason)
            end
        end
        truthy(table.concat(reasons, ','):find('ledger', 1, true),
            'the claim pushed before the ledger row existed, and nothing pushed after: '
            .. table.concat(reasons, ','))
    end)
end)
