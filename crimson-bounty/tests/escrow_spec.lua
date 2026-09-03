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
        eq(s.escrow.moneyValue(c.id), 7500)
    end)
end)
