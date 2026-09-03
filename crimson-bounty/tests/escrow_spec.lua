--- Escrow: validation, atomic take, source-faithful release, double-release
--- guards and the never-destroy-property rule.

describe('escrow validation', function()
    it('accepts a composed reward across every source', function()
        local s = newStack()
        local f = fixture(s)
        local lines, err = s.escrow.validate(f.creator, {
            baseline = {
                cash = 5000, bank = 10000, dirty = 2500,
                items = { { name = 'lockpick', count = 2 } },
                weapons = { { name = 'WEAPON_PISTOL', slot = 3 } },
            },
        })
        truthy(lines, 'expected lines, got err ' .. tostring(err))
        eq(#lines, 5, 'five lines')
    end)

    it('rejects an empty baseline', function()
        local s = newStack()
        local f = fixture(s)
        local lines, err = s.escrow.validate(f.creator, { baseline = {} })
        falsy(lines, 'must not validate')
        eq(err, CB.ERR.INVALID_REWARD)
    end)

    it('rejects more than the creator holds', function()
        local s = newStack()
        local f = fixture(s)
        local lines, err = s.escrow.validate(f.creator, { baseline = { cash = 999999999 } })
        falsy(lines)
        eq(err, CB.ERR.INVALID_REWARD, 'over the per-source cap')

        lines, err = s.escrow.validate(f.creator, { baseline = { cash = 150000 } })
        falsy(lines)
        eq(err, CB.ERR.INSUFFICIENT, 'within cap but more than held')
    end)

    it('rejects negative, fractional and non-numeric amounts', function()
        local s = newStack()
        local f = fixture(s)
        for _, bad in ipairs({ -500, 0.5, 'abc', {}, 1/0 }) do
            local lines = s.escrow.validate(f.creator, { baseline = { cash = bad } })
            falsy(lines, 'accepted a bad amount: ' .. tostring(bad))
        end
    end)

    it('rejects blacklisted items', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1]._inventory[#Env.players[1]._inventory + 1] = { name = 'handcuffs', count = 1 }
        local lines = s.escrow.validate(f.creator, {
            baseline = { items = { { name = 'handcuffs', count = 1 } } },
        })
        falsy(lines, 'handcuffs must never be escrowable')
    end)

    it('snapshots weapon metadata rather than referencing a slot', function()
        local s = newStack()
        local f = fixture(s)
        local lines = s.escrow.validate(f.creator, {
            baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } },
        })
        truthy(lines)
        eq(lines[1].metadata.serial, 'ABC123', 'serial captured')
        eq(lines[1].metadata.ammo, 12, 'ammo captured')
    end)

    it('caps the total number of escrow lines in one contract', function()
        local s = newStack()
        -- Twenty distinct stacks, enough to build a contract of a hundred
        -- lines across five payouts if nothing stopped it.
        local carried = {}
        for i = 1, 20 do
            carried[i] = { name = 'part_' .. i, count = 500, slot = i, label = 'Part ' .. i }
        end
        local f = fixture(s, { creatorInventory = carried })

        local function payoutOf(count)
            local list = {}
            for i = 1, count do list[i] = { name = 'part_' .. i, count = 1 } end
            return { baseline = { items = list } }
        end

        -- Five payouts of ten stacks: fifty lines, inside the ceiling.
        local lines, err = s.escrow.validate(f.creator, {
            slots = { payoutOf(10), payoutOf(10), payoutOf(10), payoutOf(10), payoutOf(10) },
        })
        truthy(lines, 'fifty lines should validate, got ' .. tostring(err))
        eq(#lines, 50)

        -- The same again with a bonus portion on each doubles it, and the
        -- per-payout limits alone would allow every one of them.
        local doubled = {}
        for i = 1, 5 do
            doubled[i] = { baseline = payoutOf(10).baseline, bonus = payoutOf(10).baseline }
        end
        lines, err = s.escrow.validate(f.creator, { slots = doubled })
        falsy(lines, 'a hundred lines in one contract must be refused')
        eq(err, CB.ERR.INVALID_REWARD)
    end)

    it('counts a top-up against the lines the contract already holds', function()
        local s = newStack()
        local carried = {}
        for i = 1, 20 do
            carried[i] = { name = 'part_' .. i, count = 500, slot = i, label = 'Part ' .. i }
        end
        local f = fixture(s, { creatorInventory = carried })

        local list = {}
        for i = 1, 10 do list[i] = { name = 'part_' .. i, count = 1 } end
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { slots = {
                { baseline = { items = list } }, { baseline = { items = list } },
                { baseline = { items = list } }, { baseline = { items = list } },
                { baseline = { items = list } },
            } },
        })
        truthy(c, 'fifty lines is a legal contract')
        eq(#s.storage.readEscrow(c.id), 50)

        -- Ten more is inside the ceiling; the eleventh set is not.
        truthy(s.amendments.addEscrow(f.creator, c.id, { baseline = { items = list } }),
            'sixty lines is still allowed')
        local ok, err = s.amendments.addEscrow(f.creator, c.id,
            { baseline = { items = { { name = 'part_11', count = 1 } } } })
        falsy(ok, 'a top-up must not walk past the ceiling one line at a time')
        eq(err, CB.ERR.INVALID_REWARD)
    end)

    it('refuses to stage the same physical weapon in two payouts', function()
        local s = newStack()
        local f = fixture(s)
        -- One pistol, named by both payouts. Held-count arithmetic cannot
        -- catch this on its own: the aggregate check counts weapons by name,
        -- and a creator holding two pistols would pass it while both lines
        -- still pointed at the same object.
        local lines, err = s.escrow.validate(f.creator, {
            slots = {
                { baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } } },
                { baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } } },
            },
        })
        falsy(lines, 'one weapon cannot fund two payouts')
        eq(err, CB.ERR.INVALID_REWARD)
    end)

    it('still allows two different weapons across two payouts', function()
        local s = newStack()
        local f = fixture(s, { creatorInventory = {
            { name = 'WEAPON_PISTOL', count = 1, slot = 3, metadata = { serial = 'ABC123' } },
            { name = 'WEAPON_PISTOL', count = 1, slot = 4, metadata = { serial = 'DEF456' } },
        } })
        local lines, err = s.escrow.validate(f.creator, {
            slots = {
                { baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } } },
                { baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 4 } } } },
            },
        })
        truthy(lines, 'expected lines, got err ' .. tostring(err))
        eq(#lines, 2)
        eq(lines[1].inv_slot, 3)
        eq(lines[2].inv_slot, 4)
    end)

    it('rejects funding several slots from one balance', function()
        local s = newStack()
        local f = fixture(s, { creatorCash = 10000 })
        -- Each slot passes on its own; together they exceed the balance.
        local lines, err = s.escrow.validate(f.creator, {
            slots = {
                { baseline = { cash = 6000 } },
                { baseline = { cash = 6000 } },
            },
        })
        falsy(lines, 'aggregate check must catch this')
        eq(err, CB.ERR.INSUFFICIENT)
    end)
end)

describe('escrow take', function()
    it('debits every source and writes the record', function()
        local s = newStack()
        local f = fixture(s)
        local lines = s.escrow.validate(f.creator, {
            baseline = { cash = 5000, bank = 10000, dirty = 2500, items = { { name = 'lockpick', count = 2 } } },
        })
        local ok = s.escrow.take(f.creator, 'ct1', lines)
        truthy(ok)
        eq(Env.players[1].PlayerData.money.cash, 95000, 'cash debited')
        eq(Env.players[1].PlayerData.money.bank, 90000, 'bank debited')
        eq(#s.storage.readEscrow('ct1'), 4, 'four lines stored')
    end)

    it('puts everything back when one debit fails', function()
        local s = newStack()
        local f = fixture(s)
        local lines = {
            { portion = 'baseline', source = 'cash', amount = 5000, slot = 1 },
            { portion = 'baseline', source = 'item', item = 'nonexistent', quantity = 3, slot = 1 },
        }
        local ok, err = s.escrow.take(f.creator, 'ct2', lines)
        falsy(ok, 'must fail')
        eq(err, CB.ERR.INSUFFICIENT)
        eq(Env.players[1].PlayerData.money.cash, 100000, 'cash restored exactly')
        eq(#s.storage.readEscrow('ct2'), 0, 'no partial record')
    end)
end)

describe('escrow release', function()
    local function seed()
        local s = newStack()
        local f = fixture(s)
        local lines = s.escrow.validate(f.creator, {
            baseline = { cash = 5000, items = { { name = 'lockpick', count = 2 } } },
            bonus = { cash = 2500 },
        })
        s.escrow.take(f.creator, 'ct1', lines)
        return s, f
    end

    it('pays the recipient in the sources escrow holds', function()
        local s, f = seed()
        local moved, result = s.escrow.release('ct1', 'HUNTER01', CB.PORTION.BASELINE, 'test')
        truthy(moved)
        eq(result.settled, 2, 'cash line and item line')
        eq(Env.players[3].PlayerData.money.cash, 10000, 'hunter received cash')
    end)

    it('never pays the same line twice', function()
        local s, f = seed()
        s.escrow.release('ct1', 'HUNTER01', CB.PORTION.BASELINE, 'first')
        local moved, result = s.escrow.release('ct1', 'HUNTER01', CB.PORTION.BASELINE, 'second')
        falsy(moved, 'second release must move nothing')
        eq(result.settled, 0)
        eq(Env.players[3].PlayerData.money.cash, 10000, 'balance unchanged by the replay')
    end)

    it('keeps the line owed when delivery fails, rather than destroying it', function()
        local s, f = seed()
        Env.players[3]._inventoryFull = true
        local _, result = s.escrow.release('ct1', 'HUNTER01', CB.PORTION.BASELINE, 'test')
        eq(result.pending, 1, 'the item line could not be delivered')
        eq(result.settled, 1, 'the cash line still settled')

        local line
        for _, l in ipairs(s.storage.readEscrow('ct1')) do
            if l.source == 'item' then line = l end
        end
        eq(line.state, CB.ESCROW_STATE.HELD, 'undelivered line returns to held')
        eq(#s.storage.readPending('HUNTER01'), 1, 'queued for retry')
    end)

    it('delivers queued escrow on the next login', function()
        local s, f = seed()
        Env.players[3]._inventoryFull = true
        s.escrow.release('ct1', 'HUNTER01', CB.PORTION.BASELINE, 'test')
        Env.players[3]._inventoryFull = false

        local delivered = s.escrow.retryPending('HUNTER01')
        eq(delivered, 1, 'the owed item is delivered')
        eq(s.escrow.retryPending('HUNTER01'), 0, 'and not delivered twice')
    end)

    it('restores a weapon with its original metadata', function()
        local s = newStack()
        local f = fixture(s)
        local lines = s.escrow.validate(f.creator, {
            baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } },
        })
        s.escrow.take(f.creator, 'ct9', lines)
        s.escrow.release('ct9', 'CREATOR1', nil, 'refund')

        local restored
        for _, slot in ipairs(Env.players[1]._inventory) do
            if slot.name == 'WEAPON_PISTOL' and slot.metadata then restored = slot end
        end
        truthy(restored, 'weapon returned')
        eq(restored.metadata.serial, 'ABC123', 'serial survived the round trip')
    end)
end)

describe('escrow top-ups', function()
    it('appends to existing escrow instead of overwriting it', function()
        local s = newStack()
        local f = fixture(s)
        local first = s.escrow.validate(f.creator, { baseline = { cash = 5000 } })
        s.escrow.take(f.creator, 'ct1', first)
        eq(s.escrow.moneyValue('ct1'), 5000)

        local second = s.escrow.validate(f.creator, { baseline = { cash = 1000 } })
        s.escrow.take(f.creator, 'ct1', second)
        eq(s.escrow.moneyValue('ct1'), 6000, 'the original line must survive a top-up')
        eq(#s.storage.readEscrow('ct1'), 2, 'two distinct lines')
    end)

    it('refunds a topped-up contract in full', function()
        local s = newStack()
        local f = fixture(s)
        local start = Env.players[1].PlayerData.money.cash
        s.escrow.take(f.creator, 'ct1', s.escrow.validate(f.creator, { baseline = { cash = 5000 } }))
        s.escrow.take(f.creator, 'ct1', s.escrow.validate(f.creator, { baseline = { cash = 1000 } }))
        s.escrow.release('ct1', 'CREATOR1', nil, 'refund')
        eq(Env.players[1].PlayerData.money.cash, start, 'every line returned')
    end)
end)

describe('a form that sends every field still works', function()
    --- A web form sends all of its inputs, blank ones included. Treating a
    --- zero as a rejection rather than as "not selected" made every single
    --- contract creation fail while every unit test passed, because the
    --- tests hand-built payloads containing only the sources they meant.

    it('accepts a submission carrying zeroed sources alongside a funded one', function()
        local s = newStack()
        local f = fixture(s)
        local lines, err = s.escrow.validate(f.creator, {
            slots = { { baseline = { cash = 5000, bank = 0, dirty = 0 } } },
        })
        truthy(lines, 'zeroed fields must not reject the contract: ' .. tostring(err))
        eq(#lines, 1, 'and only the funded source is escrowed')
        eq(lines[1].source, 'cash')
    end)

    it('still rejects a submission where every source is zero', function()
        local s = newStack()
        local f = fixture(s)
        local lines, err = s.escrow.validate(f.creator, {
            slots = { { baseline = { cash = 0, bank = 0, dirty = 0 } } },
        })
        falsy(lines, 'a contract offering nothing is not a contract')
        eq(err, CB.ERR.INVALID_REWARD)
    end)

    it('creates a contract end to end from a form-shaped payload', function()
        local s = newStack()
        local f = fixture(s)
        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CB.MODE.EXCLUSIVE,
            reward = { slots = {
                { baseline = { cash = 5000, bank = 0, dirty = 0 } },
                { baseline = { cash = 0, bank = 2500, dirty = 0 } },
            } },
            bonusPercent = 50, bailoutAmount = 0, penaltyAmount = 0,
        })
        truthy(c, 'the app must be able to place a contract: ' .. tostring(err))
        eq(c.payout_slots, 2)
        -- 7500 baseline plus the 50% live-delivery bonus, escrowed up front.
        eq(s.escrow.moneyValue(c.id), 11250)
        eq(s.escrow.moneyValue(c.id, CB.PORTION.BONUS), 3750)
    end)
end)

describe('money owed to a player is reachable only by them', function()
    local function owedToHunter()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { items = { { name = 'lockpick', count = 2 } } } },
        })
        s.contracts.accept(f.hunter, c.id, false)

        -- The hunter earns it but cannot carry it.
        Env.players[3]._inventoryFull = true
        s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
        return s, f, c
    end

    it('marks an undeliverable payout as the hunters', function()
        local s, f, c = owedToHunter()
        local owed
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.owed_to then owed = line end
        end
        truthy(owed, 'the payout should be recorded as owed')
        eq(owed.owed_to, 'HUNTER01')
    end)

    it('does not hand it to the creator when the contract closes', function()
        local s, f, c = owedToHunter()
        eq(s.storage.readContract(c.id).state, CB.STATE.COMPLETED,
            'a single-slot contract is finished')

        local creatorHas = 0
        for _, slot in ipairs(Env.players[1]._inventory) do
            if slot.name == 'lockpick' then creatorHas = creatorHas + slot.count end
        end
        eq(creatorHas, 3, 'the creator keeps only the 3 they started with')
    end)

    it('delivers it to the hunter when they can carry it', function()
        local s, f, c = owedToHunter()
        Env.players[3]._inventoryFull = false
        eq(s.escrow.retryPending('HUNTER01'), 1)

        local hunterHas = 0
        for _, slot in ipairs(Env.players[3]._inventory) do
            if slot.name == 'lockpick' then hunterHas = hunterHas + slot.count end
        end
        eq(hunterHas, 2, 'what they earned arrives when there is room for it')
    end)

    it('refuses to deliver it to anyone else', function()
        local s, f, c = owedToHunter()
        Env.players[1]._inventoryFull = false
        s.escrow.release(c.id, 'CREATOR1', nil, 'a general sweep')
        eq(s.escrow.retryPending('CREATOR1'), 0, 'not the creator\'s to collect')
        eq(#s.storage.readPending('HUNTER01'), 1, 'still owed to the hunter')
    end)
end)
