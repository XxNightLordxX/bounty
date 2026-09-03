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


--- Items are not interchangeable because they share a name.
---
--- Exposing items in the reward builder made this reachable: escrow took a
--- worn repair kit and handed back a fresh one, and took a loaded backpack
--- and handed back an empty one with a new container id. The first mints
--- value, the second destroys it, and both break the invariant this whole
--- resource is built on.
describe('item instances', function()
    local function carrying(inventory)
        local s = newStack()
        local f = fixture(s, { creatorInventory = inventory })
        return s, f
    end

    it('snapshots what was actually in the slot', function()
        local s, f = carrying({
            { name = 'repairkit', count = 1, slot = 1, label = 'Repair Kit',
              metadata = { durability = 11 } },
        })
        local lines, err = s.escrow.validate(f.creator, {
            baseline = { items = { { name = 'repairkit', count = 1 } } },
        })
        truthy(lines, tostring(err))
        eq(lines[1].metadata.durability, 11,
            'the worn kit, not the idea of a repair kit')
        eq(lines[1].inv_slot, 1, 'and where it came from')
    end)

    it('gives back the same instance it took', function()
        local s, f = carrying({
            { name = 'repairkit', count = 1, slot = 1, label = 'Repair Kit',
              metadata = { durability = 11 } },
        })
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { items = { { name = 'repairkit', count = 1 } } } },
        })
        truthy(c)

        -- Gone from the creator while it is escrowed.
        eq(exports.ox_inventory:GetItem(1, 'repairkit', nil, true), 0)

        truthy(s.contracts.resolve(c.id, CB.STATE.CANCELLED, f.creator.cid, nil, 'cancelled'))

        local returned
        for _, slot in ipairs(Env.players[1]._inventory) do
            if slot.name == 'repairkit' and slot.count > 0 then returned = slot end
        end
        truthy(returned, 'the kit comes back')
        eq(returned.metadata.durability, 11,
            'at the durability it had — a stage-and-cancel loop must not repair it')
    end)

    it('does not orphan what a container was holding', function()
        local s, f = carrying({
            { name = 'backpack', count = 1, slot = 1, label = 'Backpack',
              metadata = { container = 'bp-1234' } },
        })
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { items = { { name = 'backpack', count = 1 } } } },
        })
        truthy(c)
        truthy(s.contracts.resolve(c.id, CB.STATE.CANCELLED, f.creator.cid, nil, 'cancelled'))

        local returned
        for _, slot in ipairs(Env.players[1]._inventory) do
            if slot.name == 'backpack' and slot.count > 0 then returned = slot end
        end
        truthy(returned, 'the bag comes back')
        eq(returned.metadata.container, 'bp-1234',
            'still the same bag — a new container id orphans everything in it')
    end)

    it('takes the slot it staged, not any stack of the name', function()
        local s, f = carrying({
            { name = 'repairkit', count = 1, slot = 1, metadata = { durability = 11 } },
            { name = 'repairkit', count = 1, slot = 2, metadata = { durability = 96 } },
        })
        local lines = s.escrow.validate(f.creator, {
            baseline = { items = { { name = 'repairkit', count = 1 } } },
        })
        truthy(lines)
        truthy(s.escrow.take(f.creator, 'ct_probe', lines))

        -- The other kit is untouched, whichever one was staged.
        local left = {}
        for _, slot in ipairs(Env.players[1]._inventory) do
            if slot.name == 'repairkit' and slot.count > 0 then
                left[#left + 1] = slot.metadata.durability
            end
        end
        eq(#left, 1, 'one kit left')
        truthy(left[1] ~= lines[1].metadata.durability,
            'and it is the one that was not staked')
    end)

    it('splits a request across the slots it actually draws from', function()
        local s, f = carrying({
            { name = 'bandage', count = 2, slot = 1, metadata = { source = 'ems' } },
            { name = 'bandage', count = 3, slot = 2, metadata = { source = 'store' } },
        })
        local lines, err = s.escrow.validate(f.creator, {
            baseline = { items = { { name = 'bandage', count = 4 } } },
        })
        truthy(lines, tostring(err))
        eq(#lines, 2, 'one line per slot drawn from')
        eq(lines[1].quantity + lines[2].quantity, 4, 'four bandages in total')
        truthy(lines[1].metadata.source ~= lines[2].metadata.source,
            'each remembering its own instance')
    end)

    it('refuses a weapon smuggled through the item list', function()
        local s = newStack()
        local f = fixture(s)
        -- The picker sends weapons separately, so this is a hand-written
        -- payload. Through the item path a weapon is stored as a bare name
        -- and handed back clean: attachments destroyed, serial laundered.
        for _, name in ipairs({ 'WEAPON_PISTOL', 'weapon_pistol', 'Weapon_Pistol' }) do
            local lines, err = s.escrow.validate(f.creator, {
                baseline = { items = { { name = name, count = 1 } } },
            })
            falsy(lines, name .. ' must not escrow as an item')
            eq(err, CB.ERR.INVALID_REWARD)
        end
    end)

    it('still escrows a weapon properly through its own path', function()
        local s = newStack()
        local f = fixture(s)
        local lines = s.escrow.validate(f.creator, {
            baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } },
        })
        truthy(lines, 'the weapon path is unaffected')
        eq(lines[1].metadata.serial, 'ABC123')
    end)

    it('carries the metadata through storage in every backend', function()
        local Exec = require('crimson-bounty.tests.harness.mysql_exec')
        for _, name in ipairs({ 'memory', 'json', 'mysql' }) do
            local store
            if name == 'mysql' then
                Exec.install(Natives)
                package.loaded['crimson-bounty.server.storage.mysql'] = nil
                store = require('crimson-bounty.server.storage.mysql')
            else
                package.loaded['crimson-bounty.server.storage.' .. name] = nil
                Natives.files = {}
                store = require('crimson-bounty.server.storage.' .. name)
            end
            store.open()

            store.writeEscrow('ct1', { {
                id = 'ct1:1', contract_id = 'ct1', slot = 1, portion = 'baseline',
                source = CB.SOURCE.ITEM, item = 'repairkit', quantity = 1,
                state = CB.ESCROW_STATE.HELD, inv_slot = 1,
                metadata = { durability = 11 },
            } })

            local read = store.readEscrowLine('ct1:1')
            truthy(read, name .. ': line not found')
            truthy(read.metadata, name .. ': metadata must survive the round trip')
            eq(read.metadata.durability, 11, name)
        end
    end)
end)


--- Four bugs review found, each with no test until now.
describe('the authority is the server, not the picker', function()
    it('honours the item kill switch on a hand-written payload', function()
        local s = newStack()
        local f = fixture(s)
        withConfig({ { Config.Sources.item, 'enabled', false } }, function()
            eq(#s.app.escrowableItems(f.creator), 0, 'the picker offers nothing')
            local lines, err = s.escrow.validate(f.creator, {
                baseline = { items = { { name = 'lockpick', count = 1 } } },
            })
            falsy(lines, 'and a payload sent by hand is refused too')
            eq(err, CB.ERR.INVALID_REWARD)
        end)
    end)

    it('honours the weapon kill switch on a hand-written payload', function()
        local s = newStack()
        local f = fixture(s)
        withConfig({ { Config.Sources.weapon, 'enabled', false } }, function()
            eq(#s.app.escrowableWeapons(f.creator), 0)
            local lines, err = s.escrow.validate(f.creator, {
                baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } },
            })
            falsy(lines, 'a switch only the UI honours is not a switch')
            eq(err, CB.ERR.INVALID_REWARD)
        end)
    end)

    it('stakes the weapon that was picked, not one that shares its name', function()
        local s = newStack()
        local f = fixture(s, { creatorInventory = {
            { name = 'WEAPON_PISTOL', count = 1, slot = 3,
              metadata = { serial = 'PLAIN1' } },
            { name = 'WEAPON_PISTOL', count = 1, slot = 4,
              metadata = { serial = 'KITTED', components = { 'suppressor' } } },
        } })

        local lines = s.escrow.validate(f.creator, {
            baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 4 } } },
        })
        truthy(lines)
        eq(lines[1].metadata.serial, 'KITTED', 'the one they chose')
    end)

    it('refuses a weapon slot the creator does not hold', function()
        local s = newStack()
        local f = fixture(s)
        -- Slot 3 is the pistol; slot 9 is nothing. This used to fall back to
        -- "the first weapon of that name", staking an object the creator
        -- never picked.
        local lines, err = s.escrow.validate(f.creator, {
            baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 9 } } },
        })
        falsy(lines, 'a slot they do not hold is not a near-enough answer')
        eq(err, CB.ERR.INSUFFICIENT)
    end)
end)

describe('ids the rest of the resource will accept', function()
    local Util = require('crimson-bounty.shared.util')

    it('mints ids every handler accepts, whatever the clock says', function()
        local Exec = require('crimson-bounty.tests.harness.mysql_exec')
        Exec.install(Natives)
        package.loaded['crimson-bounty.server.storage.mysql'] = nil
        local store = require('crimson-bounty.server.storage.mysql')
        store.open()

        -- The clock component is taken modulo 100000, so it is a single
        -- digit for ten seconds out of every twenty-eight hours. Unpadded,
        -- every contract minted in that window had an id Util.toId refuses
        -- as malformed, and nothing could act on it.
        local realTime = os.time
        for _, moment in ipairs({ 0, 5, 99, 1234, 99999 }) do
            os.time = function() return moment end
            local id = store.nextId('ct')
            os.time = realTime
            truthy(Util.toId(id),
                ('id %q minted at clock %d is rejected by every handler'):format(id, moment))
        end
    end)

    it('agrees with the other backends on what an id looks like', function()
        for _, name in ipairs({ 'memory', 'json' }) do
            package.loaded['crimson-bounty.server.storage.' .. name] = nil
            Natives.files = {}
            local store = require('crimson-bounty.server.storage.' .. name)
            store.open()
            truthy(Util.toId(store.nextId('ct')), name)
        end
    end)
end)

describe('a hunter who cannot afford anonymity', function()
    it('is recorded as named in every backend', function()
        local Exec = require('crimson-bounty.tests.harness.mysql_exec')
        for _, name in ipairs({ 'memory', 'json', 'mysql' }) do
            local store
            if name == 'mysql' then
                Exec.install(Natives)
                package.loaded['crimson-bounty.server.storage.mysql'] = nil
                store = require('crimson-bounty.server.storage.mysql')
            else
                package.loaded['crimson-bounty.server.storage.' .. name] = nil
                Natives.files = {}
                store = require('crimson-bounty.server.storage.' .. name)
            end
            store.open()

            store.addHunter({ id = 'h1', contract_id = 'ct1', hunter_cid = 'HUNTER01',
                              hunter_name = 'Rook Ash', alias = 'Operative #1',
                              anon = true, state = 'active', accepted_at = 1, claims = 0 })

            -- They could not cover the fee, so they are simply named.
            truthy(store.updateHunter('h1', { anon = false }), name)
            eq(store.readHunter('ct1', 'HUNTER01').anon, false,
                name .. ': a hunter who paid nothing must not stay anonymous')
        end
    end)
end)


--- Two takes on one contract must not collide.
---
--- Escrow line ids are allocated from the lines the contract already has,
--- and reading those yields on a real database. Two takes can therefore
--- allocate the same ids, and the second one's lines are merged into the
--- first's rather than stored — with the money for them already gone.
describe('concurrent escrow takes', function()
    it('refuses rather than charging for escrow that does not exist', function()
        local s = newCopyingStack()
        local f = fixture(s)

        local first = s.escrow.validate(f.creator, { baseline = { cash = 1000 } })
        local second = s.escrow.validate(f.creator, { baseline = { cash = 2000 } })
        truthy(first and second)

        truthy(s.escrow.take(f.creator, 'ct_race', first), 'the first take lands')

        -- The second take reads the contract as it was before the first
        -- wrote, which is exactly what a yielding read gives you when two
        -- of them overlap. It then allocates ids that are already taken.
        local realRead = s.storage.readEscrow
        local stale = true
        s.storage.readEscrow = function(id, ...)
            if stale and id == 'ct_race' then
                stale = false
                return {}
            end
            return realRead(id, ...)
        end

        local before = Env.players[1].PlayerData.money.cash
            + Env.players[1].PlayerData.money.bank
        local ok, err = s.escrow.take(f.creator, 'ct_race', second)
        s.storage.readEscrow = realRead

        falsy(ok, 'a take whose lines did not store must not report success')
        eq(err, CB.ERR.LOCKED)

        local after = Env.players[1].PlayerData.money.cash
            + Env.players[1].PlayerData.money.bank
        eq(after, before, 'and the creator is not charged for it')
    end)

    it('leaves the first take untouched', function()
        local s = newCopyingStack()
        local f = fixture(s)

        local first = s.escrow.validate(f.creator, { baseline = { cash = 1000 } })
        truthy(s.escrow.take(f.creator, 'ct_race', first))

        local second = s.escrow.validate(f.creator, { baseline = { cash = 2000 } })

        local realRead = s.storage.readEscrow
        local stale = true
        s.storage.readEscrow = function(id, ...)
            if stale and id == 'ct_race' then stale = false return {} end
            return realRead(id, ...)
        end
        s.escrow.take(f.creator, 'ct_race', second)
        s.storage.readEscrow = realRead

        local lines = s.storage.readEscrow('ct_race')
        eq(#lines, 1, 'one line, from the take that won')
        eq(lines[1].amount, 1000, 'and it still holds what it held')
    end)

    it('still takes two escrows that do not collide', function()
        local s = newCopyingStack()
        local f = fixture(s)

        local first = s.escrow.validate(f.creator, { baseline = { cash = 1000 } })
        truthy(s.escrow.take(f.creator, 'ct_ok', first))

        local second = s.escrow.validate(f.creator, { baseline = { cash = 2000 } })
        truthy(s.escrow.take(f.creator, 'ct_ok', second),
            'an ordinary top-up must not be caught by the collision guard')
        eq(#s.storage.readEscrow('ct_ok'), 2)
    end)
end)


--- The picker's data is a snapshot, and an inventory moves.
---
--- The wallet is read when the Place tab opens and not again until a
--- contract is placed, so the slot a weapon was picked at can be stale by
--- the time it is submitted. Substituting whatever weapon happens to share
--- the name means the creator loses one they never offered.
describe('a weapon slot that has moved', function()
    it('refuses rather than staking a weapon the creator did not pick', function()
        local s = newStack()
        local f = fixture(s, { creatorInventory = {
            { name = 'WEAPON_PISTOL', count = 1, slot = 3,
              metadata = { serial = 'MODDED', components = { 'suppressor' } } },
            { name = 'WEAPON_PISTOL', count = 1, slot = 9,
              metadata = { serial = 'BEATUP' } },
        } })

        -- They picked the beat-up one at slot 9; by submit it has moved.
        local lines, err = s.escrow.validate(f.creator, {
            baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 4 } } },
        })
        falsy(lines, 'a slot nothing sits in is not an invitation to substitute')
        eq(err, CB.ERR.INSUFFICIENT)

        -- And the modded one is still theirs.
        local held = 0
        for _, slot in ipairs(Env.players[1]._inventory) do
            if slot.name == 'WEAPON_PISTOL' then held = held + 1 end
        end
        eq(held, 2, 'nothing left their pockets')
    end)

    it('takes the one that is still where it was', function()
        local s = newStack()
        local f = fixture(s, { creatorInventory = {
            { name = 'WEAPON_PISTOL', count = 1, slot = 3, metadata = { serial = 'MODDED' } },
            { name = 'WEAPON_PISTOL', count = 1, slot = 9, metadata = { serial = 'BEATUP' } },
        } })
        local lines = s.escrow.validate(f.creator, {
            baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 9 } } },
        })
        truthy(lines)
        eq(lines[1].metadata.serial, 'BEATUP', 'the one they picked, and only that')
    end)
end)


--- Items are taken from named inventory slots, and validation runs before
--- anything is taken. Weapons already guard against staging one slot twice
--- (a weapon is one physical object); item stacks are the same object with a
--- count on it, and had no such guard.
describe('staging the same item stack twice', function()
    --- Two stacks of one item, distinguishable only by what is in them.
    local function twoStacks(s)
        return fixture(s, { creatorInventory = {
            { name = 'repairkit', count = 10, slot = 5, metadata = { durability = 50 } },
            { name = 'repairkit', count = 10, slot = 9, metadata = { durability = 100 } },
        } })
    end

    it('draws the second payout from the second stack, not the first again', function()
        local s = newStack()
        local f = twoStacks(s)

        local lines, err = s.escrow.validate(f.creator, {
            slots = {
                { baseline = { items = { { name = 'repairkit', count = 10 } } } },
                { baseline = { items = { { name = 'repairkit', count = 10 } } } },
            },
        })
        truthy(lines, 'twenty held and twenty asked for: ' .. tostring(err))
        eq(#lines, 2)

        local from = {}
        for i = 1, #lines do from[#from + 1] = lines[i].inv_slot end
        table.sort(from)
        eq(from[1], 5)
        eq(from[2], 9, 'the second payout must come from the stack the first did not empty')
    end)

    it('snapshots what each stack actually holds', function()
        local s = newStack()
        local f = twoStacks(s)

        local lines = s.escrow.validate(f.creator, {
            slots = {
                { baseline = { items = { { name = 'repairkit', count = 10 } } } },
                { baseline = { items = { { name = 'repairkit', count = 10 } } } },
            },
        })
        truthy(lines)

        local seen = {}
        for i = 1, #lines do seen[lines[i].metadata.durability] = true end
        truthy(seen[50] and seen[100],
            'both stacks were escrowed, so both durabilities must be recorded — '
            .. 'otherwise one of them is handed back as a copy of the other')
    end)

    it('actually takes both stacks rather than rolling the contract back', function()
        local s = newStack()
        local f = twoStacks(s)

        local lines = s.escrow.validate(f.creator, {
            slots = {
                { baseline = { items = { { name = 'repairkit', count = 10 } } } },
                { baseline = { items = { { name = 'repairkit', count = 10 } } } },
            },
        })
        truthy(lines)

        local ok, err = s.escrow.take(f.creator, 'CB-STACKS', lines)
        truthy(ok, 'a fully-funded contract must not be refused: ' .. tostring(err))

        local left = 0
        for _, slot in ipairs(Env.players[1]._inventory) do
            if slot.name == 'repairkit' then left = left + slot.count end
        end
        eq(left, 0, 'both stacks were escrowed, so neither should still be carried')
    end)

    it('is tested against an inventory shaped like the real one', function()
        -- The guard is keyed on the slot number, and ox_inventory numbers
        -- every stack. A harness that left them unnumbered would exercise
        -- the fallback path on every test and never the one production
        -- takes — so the fixture's own default inventory is checked here.
        local s = newStack()
        local f = fixture(s)
        local found = exports.ox_inventory:Search(f.creator.source, 'slots', 'lockpick')
        eq(#found, 1)
        eq(type(found[1].slot), 'number',
            'a stack written without a slot must still arrive with one, because '
            .. 'that is what ox_inventory does')

        -- And a test that means to model a build without them says so.
        local g = fixture(newStack(), { creatorInventory = {
            { name = 'lockpick', count = 1, slot = false },
        } })
        local bare = exports.ox_inventory:Search(g.creator.source, 'slots', 'lockpick')
        eq(#bare, 1)
        eq(bare[1].slot, nil, 'slot = false is an explicit claim, and is honoured')
    end)

    it('still refuses when the stacks together are not enough', function()
        local s = newStack()
        local f = twoStacks(s)

        local lines, err = s.escrow.validate(f.creator, {
            slots = {
                { baseline = { items = { { name = 'repairkit', count = 10 } } } },
                { baseline = { items = { { name = 'repairkit', count = 10 } } } },
                { baseline = { items = { { name = 'repairkit', count = 10 } } } },
            },
        })
        falsy(lines, 'thirty asked for against twenty held')
        eq(err, CB.ERR.INSUFFICIENT)
    end)
end)


--- A percentage bonus is real escrow, so the arithmetic that derives it is
--- financial arithmetic.
describe('a bonus derived from a percentage', function()
    local function bonusFor(percent, baseline)
        local s = newStack()
        local f = fixture(s)
        local lines = s.escrow.validate(f.creator, {
            baseline = { cash = baseline },
        }, percent)
        truthy(lines, 'lines for ' .. percent .. '% of ' .. baseline)
        for i = 1, #lines do
            if lines[i].portion == CB.PORTION.BONUS then return lines[i].amount end
        end
        return nil
    end

    it('pays exactly the percentage promised', function()
        -- amount * (percent / 100) computes a binary fraction first and loses
        -- a whole unit on it: 29% of 50000 came out as 14499. Multiplying
        -- before dividing keeps it in integers.
        eq(bonusFor(29, 50000), 14500)
        eq(bonusFor(57, 10000), 5700)
        eq(bonusFor(58, 50000), 29000)
        eq(bonusFor(69, 10000), 6900)
    end)

    it('is still exact on the percentages that never lost anything', function()
        eq(bonusFor(50, 10000), 5000)
        eq(bonusFor(25, 10000), 2500)
        eq(bonusFor(100, 10000), 10000)
        eq(bonusFor(1, 10000), 100)
    end)

    it('rounds down rather than up when the split is not whole', function()
        -- 33% of 101 is 33.33: the creator is charged 33, not 34. Rounding
        -- the other way would take money they never agreed to.
        eq(bonusFor(33, 101), 33)
        eq(bonusFor(50, 99), 49)
    end)
end)


--- Delivery either happens or the line stays owed. There is no third answer.
describe('a payout the framework refuses', function()
    local function owedLine(s, f)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c)
        return c
    end

    it('does not mark a line settled when AddMoney says no', function()
        -- The item branches ask whether the inventory took the goods; the
        -- cash branch called AddMoney and reported success regardless. A
        -- server with a balance ceiling — or any qbx_core refusal — would
        -- have settled the line with nothing delivered, and the money is
        -- then gone from escrow and never arrived.
        local s = newStack()
        local f = fixture(s)
        local c = owedLine(s, f)

        Env.players[3]._refuseMoney = true
        local before = Env.players[3].PlayerData.money.cash
        eq(before, 5000, 'the hunter starts with their own money and nothing else')

        local ok, result = s.escrow.release(c.id, 'HUNTER01', CB.PORTION.BASELINE, 'test')

        eq(Env.players[3].PlayerData.money.cash, before, 'nothing was actually paid')
        falsy(ok, 'so the release did not settle anything')
        eq(result.settled, 0)
        eq(result.pending, 1, 'and the line is owed, to be retried on next login')
    end)

    it('keeps the line claimable once the framework will take it', function()
        local s = newStack()
        local f = fixture(s)
        local c = owedLine(s, f)

        Env.players[3]._refuseMoney = true
        s.escrow.release(c.id, 'HUNTER01', CB.PORTION.BASELINE, 'test')

        Env.players[3]._refuseMoney = false
        local ok, result = s.escrow.release(c.id, 'HUNTER01', CB.PORTION.BASELINE, 'retry')
        truthy(ok, 'the retry must pay')
        eq(result.settled, 1)
        eq(Env.players[3].PlayerData.money.cash, 10000,
            'and the hunter is paid the 5000 baseline exactly once, on top of their own 5000')
    end)

    it('does not let anyone else collect the line in the meantime', function()
        local s = newStack()
        local f = fixture(s)
        local c = owedLine(s, f)

        Env.players[3]._refuseMoney = true
        s.escrow.release(c.id, 'HUNTER01', CB.PORTION.BASELINE, 'test')
        Env.players[3]._refuseMoney = false

        -- An unfiltered refund to the creator must not sweep up a payout
        -- that is owed to the hunter.
        local before = Env.players[1].PlayerData.money.cash
        s.escrow.release(c.id, 'CREATOR1', nil, 'refund')
        eq(Env.players[1].PlayerData.money.cash, before,
            'the creator must not be handed the hunter money')

        -- And it is still there for the hunter afterwards.
        local ok, result = s.escrow.release(c.id, 'HUNTER01', CB.PORTION.BASELINE, 'retry')
        truthy(ok)
        eq(result.settled, 1)
        eq(Env.players[3].PlayerData.money.cash, 10000)
    end)
end)


describe('a rollback that cannot return what it took', function()
    it('records what the creator is still owed', function()
        -- The end of the line: escrow was taken, the write failed, and the
        -- give-back failed too. There is no escrow record left to hold the
        -- property, so the audit row is the only thing that says who is
        -- owed what.
        local s = newStack()
        local f = fixture(s)

        local realWrite = s.storage.writeEscrow
        s.storage.writeEscrow = function() return false end
        Env.players[1]._refuseMoney = true

        local ok, err = s.escrow.take(f.creator, 'CB-ROLLBACK', {
            { slot = 1, portion = CB.PORTION.BASELINE, source = 'cash', amount = 5000 },
        })

        s.storage.writeEscrow = realWrite
        Env.players[1]._refuseMoney = false

        falsy(ok, 'the take must fail: ' .. tostring(err))
        s.audit.flush()

        local seen = false
        for _, row in ipairs(s.storage.readAudit(200)) do
            if row.action == 'escrow_rollback_failed' then seen = true end
        end
        truthy(seen, 'property that could not be returned must be recorded, not lost quietly')
    end)

    it('says nothing when the rollback works', function()
        local s = newStack()
        local f = fixture(s)

        local realWrite = s.storage.writeEscrow
        s.storage.writeEscrow = function() return false end
        local before = Env.players[1].PlayerData.money.cash

        local ok = s.escrow.take(f.creator, 'CB-ROLLBACK2', {
            { slot = 1, portion = CB.PORTION.BASELINE, source = 'cash', amount = 5000 },
        })
        s.storage.writeEscrow = realWrite

        falsy(ok)
        eq(Env.players[1].PlayerData.money.cash, before, 'the creator is whole again')
        s.audit.flush()
        for _, row in ipairs(s.storage.readAudit(200)) do
            falsy(row.action == 'escrow_rollback_failed',
                'a rollback that worked must not raise an alarm')
        end
    end)
end)


describe('a settle the store will not take', function()
    it('records it, because the money has already gone', function()
        -- Settling is guarded on the line still being the one this release
        -- claimed. If something else took it — restart recovery returning a
        -- stuck line to held, or a second server instance on the same
        -- database — the delivery has already happened and the line is at
        -- risk of being paid again. Nothing here can undo it; the row is
        -- what tells staff to look.
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c)

        local real = s.storage.settleEscrowLine
        s.storage.settleEscrowLine = function() return false end
        local ok, result = s.escrow.release(c.id, 'HUNTER01', CB.PORTION.BASELINE, 'test')
        s.storage.settleEscrowLine = real

        truthy(ok, 'the hunter was paid')
        eq(result.settled, 1)
        eq(Env.players[3].PlayerData.money.cash, 10000, 'and really has the money')

        s.audit.flush()
        local seen = false
        for _, row in ipairs(s.storage.readAudit(200)) do
            if row.action == 'escrow_settle_lost' then seen = true end
        end
        truthy(seen, 'a line that could not be settled after delivery must be recorded')
    end)

    it('says nothing on an ordinary settle', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(s.escrow.release(c.id, 'HUNTER01', CB.PORTION.BASELINE, 'test'))

        s.audit.flush()
        for _, row in ipairs(s.storage.readAudit(200)) do
            falsy(row.action == 'escrow_settle_lost', 'a normal payout raises no alarm')
        end
    end)
end)
