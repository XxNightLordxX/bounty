--- Payout slots (§3.5): several collections per contract, each with its own
--- reward set, claimed lowest-first, with anti-farm cooldowns.

local function multiSlot()
    return { slots = {
        { baseline = { cash = 5000 },  bonus = { cash = 1000 } },
        { baseline = { cash = 3000 },  bonus = { cash = 500 } },
        { baseline = { cash = 2000 } },
    } }
end

local function seeded()
    local s = newStack()
    local f = fixture(s)
    local contract = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt',
        mode = CB.MODE.COMPETITIVE, reward = multiSlot(),
    })
    return s, f, contract
end

describe('payout slots', function()
    it('escrows every slot up front', function()
        local s, f, c = seeded()
        truthy(c, 'contract created')
        eq(c.payout_slots, 3)
        -- 5000+1000+3000+500+2000 = 11500 taken from cash
        eq(Env.players[1].PlayerData.money.cash, 88500, 'all three slots escrowed at creation')
    end)

    it('rejects a slot with no baseline', function()
        local s = newStack()
        local f = fixture(s)
        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { slots = { { baseline = { cash = 1000 } }, { bonus = { cash = 500 } } } },
        })
        falsy(c, 'an unfunded slot is not a collection')
        eq(err, CB.ERR.INVALID_REWARD)
    end)

    it('rejects more slots than the configured maximum', function()
        local s = newStack()
        local f = fixture(s)
        local slots = {}
        for i = 1, Config.Limits.MaxPayoutSlots + 1 do
            slots[i] = { baseline = { cash = 100 } }
        end
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { slots = slots },
        })
        falsy(c)
    end)

    it('claims slots lowest-first and pays that slots reward only', function()
        local s, f, c = seeded()
        s.contracts.accept(f.hunter, c.id, false)

        local ok, err, result = s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
        truthy(ok, tostring(err))
        eq(result.slot, 1)
        eq(result.remaining, 2)
        eq(Env.players[3].PlayerData.money.cash, 10000, 'hunter got slot 1 baseline (5000) only')
    end)

    it('returns the unearned bonus to the creator on an elimination', function()
        local s, f, c = seeded()
        s.contracts.accept(f.hunter, c.id, false)
        local before = Env.players[1].PlayerData.money.cash
        s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
        eq(Env.players[1].PlayerData.money.cash, before + 1000, 'slot 1 bonus refunded')
    end)

    it('pays baseline plus bonus on a kidnapping', function()
        local s, f, c = seeded()
        s.contracts.accept(f.hunter, c.id, false)
        s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.KIDNAPPING)
        eq(Env.players[3].PlayerData.money.cash, 11000, 'baseline 5000 + bonus 1000')
    end)

    it('keeps the contract live until the last slot is claimed', function()
        local s, f, c = seeded()
        s.contracts.accept(f.hunter, c.id, false)
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd' })
        Env.addPlayer({ source = 5, citizenid = 'HUNTER03', license = 'license:eee' })
        s.contracts.accept(s.identity.resolve(4), c.id, false)
        s.contracts.accept(s.identity.resolve(5), c.id, false)

        s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
        eq(s.storage.readContract(c.id).state, CB.STATE.ACCEPTED, 'still live after slot 1')

        s.contracts.claimSlot(c.id, 'HUNTER02', CB.FULFILMENT.ELIMINATION)
        eq(s.storage.readContract(c.id).state, CB.STATE.ACCEPTED, 'still live after slot 2')

        local ok, _, result = s.contracts.claimSlot(c.id, 'HUNTER03', CB.FULFILMENT.ELIMINATION)
        truthy(ok)
        truthy(result.exhausted, 'last slot exhausts the contract')
        eq(s.storage.readContract(c.id).state, CB.STATE.COMPLETED)
    end)

    it('refuses a claim once every slot is gone', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        s.contracts.accept(f.hunter, c.id, false)
        truthy(s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION))
        local ok, err = s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
        falsy(ok, 'no slots left')
        eq(err, CB.ERR.BAD_STATE, 'contract is completed, not claimable')
    end)

    it('stops one hunter farming consecutive slots', function()
        local s, f, c = seeded()
        s.contracts.accept(f.hunter, c.id, false)
        truthy(s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION))

        local ok, err = s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
        falsy(ok, 'cooldown must block a back-to-back claim')
        eq(err, CB.ERR.RATE_LIMITED)

        Env.advance(Config.Limits.SlotCooldownSeconds + 1)
        truthy(s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION),
            'allowed once the cooldown has passed')
    end)

    it('returns unclaimed slots to the creator when the contract is cancelled', function()
        local s, f, c = seeded()
        s.contracts.accept(f.hunter, c.id, false)
        s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
        local afterClaim = Env.players[1].PlayerData.money.cash

        s.contracts.resolve(c.id, CB.STATE.CANCELLED, 'CREATOR1', nil, 'cancelled')
        -- slots 2 and 3 remain: 3000 + 500 + 2000
        eq(Env.players[1].PlayerData.money.cash, afterClaim + 5500, 'unclaimed slots refunded in full')
    end)
end)

describe('more hunters than slots', function()
    it('lets more hunters accept than there are slots, and pays the first to fulfil', function()
        local s = newStack()
        local f = fixture(s)
        -- Three slots, four hunters.
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { slots = {
                { baseline = { cash = 1000 } },
                { baseline = { cash = 1000 } },
                { baseline = { cash = 1000 } },
            } },
        })
        truthy(c)
        eq(c.payout_slots, 3)

        local hunters = { 'HUNTER01' }
        s.contracts.accept(f.hunter, c.id, false)
        for i = 2, 4 do
            local src = 3 + i
            local cid = 'HUNTER0' .. i
            Env.addPlayer({ source = src, citizenid = cid, license = 'license:h' .. i })
            local ok, err = s.contracts.accept(s.identity.resolve(src), c.id, false)
            truthy(ok, ('hunter %d should be able to accept a 3-slot contract: %s'):format(i, tostring(err)))
            hunters[#hunters + 1] = cid
        end
        eq(#s.storage.readHunters(c.id), 4, 'four hunters on a three-slot contract')

        -- First three to fulfil take the three slots.
        for i = 1, 3 do
            local ok, err = s.contracts.claimSlot(c.id, hunters[i], CB.FULFILMENT.ELIMINATION)
            truthy(ok, ('hunter %d should collect slot %d: %s'):format(i, i, tostring(err)))
        end

        -- The fourth arrives too late: the contract is finished.
        local ok, err = s.contracts.claimSlot(c.id, hunters[4], CB.FULFILMENT.ELIMINATION)
        falsy(ok, 'the fourth hunter gets nothing')
        eq(err, CB.ERR.BAD_STATE)
        eq(s.storage.readContract(c.id).state, CB.STATE.COMPLETED)

        -- And the money went to exactly the first three.
        eq(Env.players[3].PlayerData.money.cash, 6000, 'hunter 1 paid')
        eq(Env.players[7].PlayerData.money.cash, 0, 'hunter 4 unpaid — balance untouched')
    end)
end)
