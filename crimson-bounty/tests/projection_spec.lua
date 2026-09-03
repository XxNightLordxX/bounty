--- What each viewer is allowed to receive. These tests exist so a refactor
--- cannot quietly widen a payload and defeat anonymity.

local function seeded(opts)
    opts = opts or {}
    local s = newStack()
    local f = fixture(s)
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt',
        mode = CB.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 }, bonus = { cash = 2500 } },
        bailoutAmount = opts.bailout, anonymous = opts.anonCreator,
    })
    if opts.accept then s.contracts.accept(f.hunter, c.id, opts.anonHunter or false) end
    return s, f, c
end

local function keysOf(row)
    local out = {}
    for k in pairs(row) do out[#out + 1] = k end
    table.sort(out)
    return out
end

local function assertOnlyAllowed(row, role)
    local allowed = {}
    for k in pairs(Suite.projectionAllowed.common) do allowed[k] = true end
    for k in pairs(Suite.projectionAllowed[role] or {}) do allowed[k] = true end
    for _, k in ipairs(keysOf(row)) do
        truthy(allowed[k], ('role %s received an unexpected key: %s'):format(role, k))
    end
end

describe('projection', function()
    it('sends a public viewer nothing beyond the allowed key set', function()
        local s, f, c = seeded()
        Suite.projectionAllowed = s.projection.ALLOWED_KEYS
        Env.addPlayer({ source = 9, citizenid = 'PUBLIC01', license = 'license:p' })
        local row = s.projection.contract(s.storage.readContract(c.id), 'PUBLIC01')
        assertOnlyAllowed(row, 'public')
    end)

    it('omits the creator identity entirely when anonymous', function()
        local s, f, c = seeded({ anonCreator = true })
        local row = s.projection.contract(s.storage.readContract(c.id), 'HUNTER01')
        falsy(row.creatorName, 'no name key at all')
        falsy(row.creator_cid, 'no citizen id')
        truthy(row.creatorAnonymous)
        -- The stored record still knows, for the audit trail.
        eq(s.storage.readContract(c.id).creator_cid, 'CREATOR1')
    end)

    it('shows the creator name when they chose to be seen', function()
        local s, f, c = seeded()
        local row = s.projection.contract(s.storage.readContract(c.id), 'HUNTER01')
        eq(row.creatorName, 'Vic Marlowe')
    end)

    it('never sends the hunter roster to a public viewer', function()
        local s, f, c = seeded({ accept = true })
        Env.addPlayer({ source = 9, citizenid = 'PUBLIC01', license = 'license:p' })
        local row = s.projection.contract(s.storage.readContract(c.id), 'PUBLIC01')
        falsy(row.hunters, 'roster is for the creator only')
        eq(row.huntersActive, 1, 'a count is enough for everyone else')
    end)

    it('gives the creator aliases but not names for anonymous hunters', function()
        local s, f, c = seeded({ accept = true, anonHunter = true })
        local row = s.projection.contract(s.storage.readContract(c.id), 'CREATOR1')
        eq(#row.hunters, 1)
        eq(row.hunters[1].alias, 'Operative #1')
        falsy(row.hunters[1].name, 'anonymity paid for is anonymity kept')
    end)

    it('gives the creator names for hunters who chose to be seen', function()
        local s, f, c = seeded({ accept = true, anonHunter = false })
        local row = s.projection.contract(s.storage.readContract(c.id), 'CREATOR1')
        eq(row.hunters[1].name, 'Rook Ash')
    end)

    it('never shows a target the creator or the hunters', function()
        local s, f, c = seeded({ accept = true, bailout = 15000 })
        local rows = s.projection.onMe('TARGET01')
        eq(#rows, 1)
        falsy(rows[1].creatorName, 'the target does not learn who wants them dead')
        falsy(rows[1].hunters, 'nor who is coming')
        eq(rows[1].bailoutAmount, 15000, 'but does learn the price of freedom')
    end)

    it('hides a contract from the list when either party is offline', function()
        local s, f, c = seeded()
        Env.addPlayer({ source = 9, citizenid = 'PUBLIC01', license = 'license:p' })
        eq(#s.projection.listing('PUBLIC01').contracts, 1, 'listed while both are online')

        Env.removePlayer(2)  -- target logs out
        eq(#s.projection.listing('PUBLIC01').contracts, 0, 'hidden')

        -- Hidden is a display state only: escrow and contract are untouched.
        eq(s.storage.readContract(c.id).state, CB.STATE.ACTIVE)
        eq(s.escrow.moneyValue(c.id), 7500)
    end)

    it('does not list a contract to its own target', function()
        local s, f, c = seeded()
        eq(#s.projection.listing('TARGET01').contracts, 0, 'the target sees it in their own tab instead')
    end)

    it('reports the reward of the slot currently being competed for', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { slots = {
                { baseline = { cash = 5000 } },
                { baseline = { cash = 1000 } },
            } },
        })
        s.contracts.accept(f.hunter, c.id, false)
        local row = s.projection.contract(s.storage.readContract(c.id), 'HUNTER01')
        eq(row.reward.baseline, 5000, 'slot 1 first')

        s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
        row = s.projection.contract(s.storage.readContract(c.id), 'HUNTER01')
        eq(row.reward.baseline, 1000, 'now slot 2')
        eq(row.currentSlot, 2)
    end)

    it('flags a law enforcement target for every viewer', function()
        local s = newStack()
        local f = fixture(s, { targetJob = { name = 'trooper', type = 'leo', onduty = true } })
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        local row = s.projection.contract(s.storage.readContract(c.id), 'HUNTER01')
        truthy(row.targetProtected, 'no hunter accepts a police contract by accident')
    end)
end)

describe('target mugshots', function()
    local function seededMug()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        return s, f, c
    end

    local VALID = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUg=='

    --- The real flow: the server asks, then the client answers. store()
    --- rejects an image nothing asked for.
    local function render(s, cid, image)
        s.mugshot.request(cid)
        return s.mugshot.store(cid, image or VALID)
    end

    it('asks the target to render their own headshot', function()
        local s, f, c = seededMug()
        s.projection.contract(s.storage.readContract(c.id), 'HUNTER01')

        local asked = false
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-bounty:renderMugshot' and event.target == 2 then asked = true end
        end
        truthy(asked, 'only the target can reliably render their own ped')
    end)

    it('serves the cached image to every viewer once rendered', function()
        local s, f, c = seededMug()
        truthy(render(s, 'TARGET01'))
        local row = s.projection.contract(s.storage.readContract(c.id), 'HUNTER01')

        -- The row carries a reference, not the image: inlining forty
        -- kilobytes of base64 into every row of every page was the whole
        -- cost of the listing.
        truthy(row.targetImageId, 'the row should name an image')
        falsy(row.targetImage, 'and must not carry the bytes')
        eq(s.mugshot.byHandle(row.targetImageId), VALID,
            'and the reference must resolve to the image')
    end)

    it('does not put a citizen id in the reference', function()
        local s, f, c = seededMug()
        truthy(render(s, 'TARGET01'))
        local row = s.projection.contract(s.storage.readContract(c.id), 'HUNTER01')
        falsy(row.targetImageId:find('TARGET01', 1, true),
            'the handle goes to every viewer; a citizen id in it is a leak')
    end)

    it('mints a new reference for a new render, and retires the old one', function()
        local s, f, c = seededMug()
        truthy(render(s, 'TARGET01'))
        local first = s.projection.contract(s.storage.readContract(c.id), 'HUNTER01').targetImageId

        -- A second render, past the refresh floor.
        s.mugshot.clearPlayer('TARGET01')
        truthy(render(s, 'TARGET01'))
        local second = s.projection.contract(s.storage.readContract(c.id), 'HUNTER01').targetImageId

        truthy(second and second ~= first, 'a new image is a new reference')
        falsy(s.mugshot.byHandle(first),
            'the retired reference must not still serve a face its owner replaced')
        eq(s.mugshot.byHandle(second), VALID)
    end)

    it('resolves nothing for a handle nobody minted', function()
        local s = newStack()
        fixture(s)
        for _, bogus in ipairs({ 'mg1_000000', 'TARGET01', '', 'mg' }) do
            falsy(s.mugshot.byHandle(bogus), 'must not resolve ' .. bogus)
        end
        falsy(s.mugshot.byHandle(nil))
        falsy(s.mugshot.byHandle(42))
        falsy(s.mugshot.byHandle({}))
    end)

    it('rejects an oversized or malformed image', function()
        local s = newStack()
        fixture(s)
        for _, bad in ipairs({
            'data:image/png;base64,' .. string.rep('A', Config.Mugshot.MaxImageBytes + 1),
            'javascript:alert(1)',
            'https://evil.tld/x.png',
            'data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=',   -- not a headshot
            'data:image/x-anything;base64,QUFBQQ==',
            'data:image/png;base64,QUFBQQ==',               -- claims png, is not
            12345,
        }) do
            falsy(render(s, 'TARGET01', bad), 'accepted: ' .. tostring(bad):sub(1, 40))
        end
        falsy(s.mugshot.get('TARGET01'), 'nothing bad was cached')
    end)

    it('refuses an image nothing asked for', function()
        local s = newStack()
        fixture(s)
        falsy(s.mugshot.store('TARGET01', VALID),
            'a client must not be able to push an image on its own initiative')
        falsy(s.mugshot.get('TARGET01'))
    end)

    it('does not let an unanswered request pin the cache forever', function()
        local s, f, c = seededMug()
        render(s, 'TARGET01')

        -- The client stops answering. After the timeout the entry stops
        -- claiming to be pending, and after repeated silence it is dropped
        -- rather than serving an image nobody is refreshing.
        for _ = 1, 4 do
            Env.advance((Config.Mugshot.MinRefreshMinutes * 60) + 60)
            s.mugshot.request('TARGET01')
        end
        falsy(s.mugshot.get('TARGET01'), 'a stale image must not be served indefinitely')
    end)

    it('does not re-render inside the refresh floor', function()
        local s, f, c = seededMug()
        render(s, 'TARGET01')
        Env.clientEvents = {}

        s.projection.contract(s.storage.readContract(c.id), 'HUNTER01')
        for _, event in ipairs(Env.clientEvents) do
            falsy(event.name == 'crimson-bounty:renderMugshot',
                'a fresh image must not trigger another render')
        end
    end)

    it('re-renders after an appearance change once the floor has passed', function()
        local s, f, c = seededMug()
        render(s, 'TARGET01')

        falsy(s.mugshot.invalidate('TARGET01'), 'too soon after the last render')
        Env.advance((Config.Mugshot.MinRefreshMinutes * 60) + 10)
        truthy(s.mugshot.invalidate('TARGET01'), 'now the appearance change takes effect')
        falsy(s.mugshot.get('TARGET01'))
    end)
end)
