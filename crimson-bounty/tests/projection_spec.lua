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
