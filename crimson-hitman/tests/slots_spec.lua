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
        mode = CH.MODE.COMPETITIVE, reward = multiSlot(),
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
        eq(err, CH.ERR.INVALID_REWARD)
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
        s.contracts.accept(f.hitman, c.id, false)

        local ok, err, result = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        truthy(ok, tostring(err))
        eq(result.slot, 1)
        eq(result.remaining, 2)
        eq(Env.players[3].PlayerData.money.cash, 10000, 'hitman got slot 1 baseline (5000) only')
    end)

    it('returns the unearned bonus to the creator on an elimination', function()
        local s, f, c = seeded()
        s.contracts.accept(f.hitman, c.id, false)
        local before = Env.players[1].PlayerData.money.cash
        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        eq(Env.players[1].PlayerData.money.cash, before + 1000, 'slot 1 bonus refunded')
    end)

    it('pays baseline plus bonus on a kidnapping', function()
        local s, f, c = seeded()
        s.contracts.accept(f.hitman, c.id, false)
        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.KIDNAPPING)
        eq(Env.players[3].PlayerData.money.cash, 11000, 'baseline 5000 + bonus 1000')
    end)

    it('keeps the contract live until the last slot is claimed', function()
        local s, f, c = seeded()
        s.contracts.accept(f.hitman, c.id, false)
        Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd' })
        Env.addPlayer({ source = 5, citizenid = 'HITMAN03', license = 'license:eee' })
        s.contracts.accept(s.identity.resolve(4), c.id, false)
        s.contracts.accept(s.identity.resolve(5), c.id, false)

        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'still live after slot 1')

        s.contracts.claimSlot(c.id, 'HITMAN02', CH.FULFILMENT.ELIMINATION)
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'still live after slot 2')

        local ok, _, result = s.contracts.claimSlot(c.id, 'HITMAN03', CH.FULFILMENT.ELIMINATION)
        truthy(ok)
        truthy(result.exhausted, 'last slot exhausts the contract')
        eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED)
    end)

    it('refuses a claim once every slot is gone', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        s.contracts.accept(f.hitman, c.id, false)
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        local ok, err = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        falsy(ok, 'no slots left')
        eq(err, CH.ERR.BAD_STATE, 'contract is completed, not claimable')
    end)

    it('stops one hitman farming consecutive slots', function()
        local s, f, c = seeded()
        s.contracts.accept(f.hitman, c.id, false)
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))

        local ok, err = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        falsy(ok, 'cooldown must block a back-to-back claim')
        -- Its own code: this is a ten-minute policy wait, and RATE_LIMITED is
        -- the flood guard, which the page words as "Slow down."
        eq(err, CH.ERR.SLOT_COOLDOWN)

        Env.advance(Config.Limits.SlotCooldownSeconds + 1)
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION),
            'allowed once the cooldown has passed')
    end)

    it('returns unclaimed slots to the creator when the contract is cancelled', function()
        local s, f, c = seeded()
        s.contracts.accept(f.hitman, c.id, false)
        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        local afterClaim = Env.players[1].PlayerData.money.cash

        s.contracts.resolve(c.id, CH.STATE.CANCELLED, 'CREATOR1', nil, 'cancelled')
        -- slots 2 and 3 remain: 3000 + 500 + 2000
        eq(Env.players[1].PlayerData.money.cash, afterClaim + 5500, 'unclaimed slots refunded in full')
    end)
end)

describe('more hitmen than slots', function()
    it('lets more hitmen accept than there are slots, and pays the first to fulfil', function()
        local s = newStack()
        local f = fixture(s)
        -- Three slots, four hitmen.
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { slots = {
                { baseline = { cash = 1000 } },
                { baseline = { cash = 1000 } },
                { baseline = { cash = 1000 } },
            } },
        })
        truthy(c)
        eq(c.payout_slots, 3)

        local hitmen = { 'HITMAN01' }
        s.contracts.accept(f.hitman, c.id, false)
        for i = 2, 4 do
            local src = 3 + i
            local cid = 'HITMAN0' .. i
            Env.addPlayer({ source = src, citizenid = cid, license = 'license:h' .. i })
            local ok, err = s.contracts.accept(s.identity.resolve(src), c.id, false)
            truthy(ok, ('hitman %d should be able to accept a 3-slot contract: %s'):format(i, tostring(err)))
            hitmen[#hitmen + 1] = cid
        end
        eq(#s.storage.readHitmen(c.id), 4, 'four hitmen on a three-slot contract')

        -- First three to fulfil take the three slots.
        for i = 1, 3 do
            local ok, err = s.contracts.claimSlot(c.id, hitmen[i], CH.FULFILMENT.ELIMINATION)
            truthy(ok, ('hitman %d should collect slot %d: %s'):format(i, i, tostring(err)))
        end

        -- The fourth arrives too late: the contract is finished.
        local ok, err = s.contracts.claimSlot(c.id, hitmen[4], CH.FULFILMENT.ELIMINATION)
        falsy(ok, 'the fourth hitman gets nothing')
        eq(err, CH.ERR.BAD_STATE)
        eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED)

        -- And the money went to exactly the first three.
        eq(Env.players[3].PlayerData.money.cash, 6000, 'hitman 1 paid')
        eq(Env.players[7].PlayerData.money.cash, 0, 'hitman 4 unpaid — balance untouched')
    end)
end)

describe('escrow lines always carry a valid payout slot', function()
    --- A line whose slot does not match a real payout can never be released
    --- by a slot-filtered claim, so it would be stranded on a completed
    --- contract — property destroyed, silently.
    local function assertSlotsValid(s, contract)
        local lines = s.storage.readEscrow(contract.id)
        truthy(#lines > 0, 'contract should hold escrow')
        for _, line in ipairs(lines) do
            truthy(line.slot >= 1 and line.slot <= (contract.payout_slots or 1),
                ('line %s has slot %s, outside 1..%d')
                    :format(line.id, tostring(line.slot), contract.payout_slots or 1))
        end
    end

    it('assigns weapons the payout slot, not their inventory slot', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { slots = {
                { baseline = { cash = 1000 } },
                { baseline = { cash = 1000, weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } } },
            } },
        })
        truthy(c)
        assertSlotsValid(s, c)

        local weaponLine
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.source == 'weapon' then weaponLine = line end
        end
        truthy(weaponLine)
        eq(weaponLine.slot, 2, 'payout slot 2, not inventory slot 3')
        eq(weaponLine.inv_slot, 3, 'the inventory slot is kept separately')
    end)

    it('delivers an escrowed weapon to the hitman on completion', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 1000, weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } } },
        })
        truthy(c)
        s.contracts.accept(f.hitman, c.id, false)
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))

        local got
        for _, slot in ipairs(Env.players[3]._inventory) do
            if slot.name == 'WEAPON_PISTOL' then got = slot end
        end
        truthy(got, 'the hitman must actually receive the escrowed weapon')
        eq(got.metadata.serial, 'ABC123', 'with its serial intact')

        -- And nothing may be left held on a finished contract.
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            eq(line.state, CH.ESCROW_STATE.SETTLED,
                ('line %s left %s on a completed contract'):format(line.id, line.state))
        end
    end)

    it('hands an anonymous client\'s weapon over without the client\'s name on it', function()
        -- ox_inventory keeps the owner's name in `registered`, and the
        -- hitman's game holds the metadata of everything they carry.
        local function placed()
            local s = newStack()
            local f = fixture(s, { creatorInventory = {
                { name = 'WEAPON_PISTOL', count = 1, slot = 3,
                  metadata = { serial = 'ABC123', ammo = 12, registered = 'Vic Marlowe' } },
            } })
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', anonymous = true,
                reward = { baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } } },
            })
            truthy(c)
            return s, f, c
        end
        local function pistolOf(src)
            for _, slot in ipairs(Env.players[src]._inventory) do
                if slot.name == 'WEAPON_PISTOL' then return slot end
            end
        end

        local s, f, c = placed()
        s.contracts.accept(f.hitman, c.id, false)
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        local got = pistolOf(3)
        truthy(got, 'the hitman must receive the weapon')
        eq(got.metadata.serial, 'ABC123', 'with its serial intact')
        truthy(got.metadata.registered ~= 'Vic Marlowe',
            'the hitman holds a weapon registered to the anonymous client')

        -- Withdrawn instead: back to the client exactly as it was.
        s, f, c = placed()
        truthy(s.contracts.cancel(f.creator, c.id))
        local back = pistolOf(1)
        eq(back and back.metadata.registered, 'Vic Marlowe', 'a refund is the weapon as it was')
    end)

    it('never strands a line on any completed multi-slot contract', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1]._inventory[#Env.players[1]._inventory + 1] =
            { name = 'WEAPON_PISTOL', count = 1, slot = 7, metadata = { serial = 'XYZ789' } }

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { slots = {
                { baseline = { cash = 500, weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } } },
                { baseline = { cash = 500, items = { { name = 'lockpick', count = 1 } } } },
            } },
        })
        truthy(c)
        assertSlotsValid(s, c)

        s.contracts.accept(f.hitman, c.id, false)
        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        Env.advance(Config.Limits.SlotCooldownSeconds + 1)
        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)

        eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED)
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            eq(line.state, CH.ESCROW_STATE.SETTLED,
                ('line %s (%s) stranded on a completed contract'):format(line.id, line.source))
        end
    end)
end)

describe('the kidnapping bonus is real money', function()
    local function withBonus(percent)
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 10000 } },
            bonusPercent = percent,
        })
        return s, f, c
    end

    it('escrows the bonus at creation rather than merely promising it', function()
        local s, f, c = withBonus(50)
        truthy(c)
        eq(s.escrow.moneyValue(c.id, CH.PORTION.BONUS), 5000)
        eq(Env.players[1].PlayerData.money.cash, 85000,
            'the creator surrendered the bonus too')
    end)

    it('pays a live delivery more than a kill', function()
        local s, f, c = withBonus(50)
        s.contracts.accept(f.hitman, c.id, false)
        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.KIDNAPPING)
        eq(Env.players[3].PlayerData.money.cash, 20000, '10000 baseline + 5000 bonus + 5000 start')
    end)

    it('returns the unearned bonus to the creator on a kill', function()
        local s, f, c = withBonus(50)
        s.contracts.accept(f.hitman, c.id, false)
        local before = Env.players[1].PlayerData.money.cash
        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        eq(Env.players[3].PlayerData.money.cash, 15000, 'baseline only')
        eq(Env.players[1].PlayerData.money.cash, before + 5000, 'bonus comes home')
    end)

    it('refuses a contract whose bonus the creator cannot cover', function()
        local s = newStack()
        local f = fixture(s, { creatorCash = 10000 })
        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 10000 } }, bonusPercent = 100,
        })
        falsy(c, 'a bonus that cannot be funded is not a bonus')
        eq(err, CH.ERR.INSUFFICIENT)
        eq(Env.players[1].PlayerData.money.cash, 10000, 'and nothing was taken')
    end)

    it('is shown on the board as what the hitman would actually get', function()
        local s, f, c = withBonus(50)
        local row = s.projection.contract(s.storage.readContract(c.id), 'HITMAN01')
        eq(row.reward.baseline, 10000)
        eq(row.reward.bonus, 5000, 'the +alive figure must be the real one')
    end)
end)

describe('an explicit bonus is not doubled by a percentage', function()
    it('leaves a slot that names its own bonus alone', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 10000 }, bonus = { cash = 1000 } },
            bonusPercent = 50,
        })
        truthy(c)
        eq(s.escrow.moneyValue(c.id, CH.PORTION.BONUS), 1000,
            'the creator said 1000; they must not be charged 6000')
    end)

    it('still derives one for a slot that does not', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { slots = {
                { baseline = { cash = 10000 }, bonus = { cash = 1000 } },
                { baseline = { cash = 10000 } },
            } },
            bonusPercent = 50,
        })
        truthy(c)
        eq(s.escrow.moneyValue(c.id, { slot = 1, portion = CH.PORTION.BONUS }), 1000)
        eq(s.escrow.moneyValue(c.id, { slot = 2, portion = CH.PORTION.BONUS }), 5000)
    end)
end)


--- A claim must not write back what it read before it yielded.
---
--- claimSlot held a contract snapshot from the top of the function and wrote
--- the whole thing back after several yielding reads. Anything stored in
--- between was erased by that copy — and a bailout queuing during the window
--- is the target's money.
describe('a claim does not erase what happened while it ran', function()
    it('does not write back a snapshot taken before it yielded', function()
        -- Against a store that returns copies, as a real database does. On
        -- the sharing backend the snapshot claimSlot holds IS the stored
        -- row, so this bug cannot be reproduced there at all.
        local s = newCopyingStack()
        local f = fixture(s)
        Env.players[3].PlayerData.money.bank = 50000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { cash = 5000 } },
                                 { baseline = { cash = 5000 } } } },
            bailoutAmount = 15000,
        })
        truthy(s.contracts.accept(f.hitman, c.id, false))

        -- Something else writes the contract in the window between the read
        -- at the top of claimSlot and the write at the end. On a live server
        -- that window is several yielding database calls wide; here it is
        -- forced at the first of them.
        --
        -- A queued buyout was the case review raised. That one turns out to
        -- be unreachable — the contract is locked in COMPLETING for the whole
        -- window and Bailout.buy refuses that state — but the pattern is the
        -- bug, and the next writer added may not be so lucky.
        local realReadEscrow = s.storage.readEscrow
        local fired = false
        s.storage.readEscrow = function(...)
            if not fired then
                fired = true
                local row = s.storage.readContract(c.id)
                row.resolution = 'written mid-claim'
                s.storage.writeContract(row)
            end
            return realReadEscrow(...)
        end

        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        s.storage.readEscrow = realReadEscrow
        truthy(fired, 'the write must have landed mid-claim')

        local row = s.storage.readContract(c.id)
        eq(row.resolution, 'written mid-claim',
            'a claim must not erase what was written while it ran')
        eq(row.slots_claimed, 1, 'and must still record its own claim')
        eq(row.next_slot, 2)
    end)

    it('advances the slot exactly once', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[3].PlayerData.money.bank = 50000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { cash = 1000 } },
                                 { baseline = { cash = 1000 } },
                                 { baseline = { cash = 1000 } } } },
        })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))

        local row = s.storage.readContract(c.id)
        eq(row.slots_claimed, 1, 'one claim, one slot')
        eq(row.next_slot, 2)
    end)

    it('refuses to advance a slot that has already moved', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { slots = { { baseline = { cash = 1000 } },
                                 { baseline = { cash = 1000 } } } },
        })
        truthy(s.storage.advanceSlot(c.id, 1), 'the first advance takes')
        falsy(s.storage.advanceSlot(c.id, 1), 'the same one again does not')
        eq(s.storage.readContract(c.id).slots_claimed, 1)
    end)

    it('advances the same way in every backend', function()
        local Exec = require('crimson-hitman.tests.harness.mysql_exec')
        for _, name in ipairs({ 'memory', 'json', 'mysql' }) do
            local store
            if name == 'mysql' then
                Exec.install(Natives)
                package.loaded['crimson-hitman.server.storage.mysql'] = nil
                store = require('crimson-hitman.server.storage.mysql')
            else
                package.loaded['crimson-hitman.server.storage.' .. name] = nil
                Natives.files = {}
                store = require('crimson-hitman.server.storage.' .. name)
            end
            store.open()

            store.writeContract({ id = 'ct1', creator_cid = 'C', target_cid = 'T',
                                  mode = 'exclusive', state = 'active', created_at = 1,
                                  payout_slots = 3, next_slot = 1, slots_claimed = 0 })

            truthy(store.advanceSlot('ct1', 1), name .. ': the first advance')
            falsy(store.advanceSlot('ct1', 1), name .. ': and not twice')

            local row = store.readContract('ct1')
            eq(row.next_slot, 2, name)
            eq(row.slots_claimed, 1, name)
        end
    end)
end)

--------------------------------------------------------------------------
-- How many times a contract can be collected: 1, 2 or 3, shipped 1
--------------------------------------------------------------------------

describe('collections as the owner chooses them (Config.Limits.MaxPayoutSlots)', function()
    --- The setting as config.lua and defaults.lua ship it, read from the
    --- files themselves: the suite runs at 3 (tests/run.lua).
    local function shipped(path)
        local source = read_file(path)
        return tonumber(source:match('MaxPayoutSlots%s*=%s*(%d+)'))
    end

    it('ships as 1 in config.lua and defaults.lua', function()
        eq(shipped('crimson-hitman/config/config.lua'), 1, 'config.lua')
        eq(shipped('crimson-hitman/config/defaults.lua'), 1, 'defaults.lua')
        local main = require('crimson-hitman.server.main')
        eq(main.configDefaults.Limits.MaxPayoutSlots, 1, 'and what boot fills in for a config without it')
    end)

    it('places a contract collected once at 1, and refuses a second collection', function()
        local s = newStack()
        local f = fixture(s)
        withConfig({ { Config.Limits, 'MaxPayoutSlots', 1 } }, function()
            local once = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
            })
            truthy(once, 'one collection is the contract')
            eq(once.payout_slots, 1)

            Env.addPlayer({ source = 4, citizenid = 'TARGET04', license = 'license:t4',
                firstname = 'Ola', lastname = 'Berg' })
            local twice, err = s.contracts.create(f.creator, {
                targetCid = 'TARGET04', reason = 'x',
                reward = { slots = { { baseline = { cash = 1000 } }, { baseline = { cash = 1000 } } } },
            })
            falsy(twice, 'a second collection is not offered at 1')
            eq(err, CH.ERR.INVALID_REWARD)
        end)
    end)

    it('tells the Place form the server\'s number, so at 1 it offers no more', function()
        local s = newStack()
        fixture(s)
        withConfig({ { Config.Limits, 'MaxPayoutSlots', 1 } }, function()
            _G.source = 1
            Env.clientEvents = {}
            Env.events['crimson-hitman:rewardOptions']({ __rid = 1 })
            _G.source = nil
            local reply
            for _, event in ipairs(Env.clientEvents) do
                if event.name == 'crimson-hitman:result' then reply = event.args[1] end
            end
            truthy(reply and reply.ok, 'the form reads the wallet')
            eq(reply.data.caps.slots, 1)
        end)
    end)

    it('lets a contract placed with more collections keep them after the number comes down', function()
        local s, f, c = seeded()
        truthy(c)
        eq(c.payout_slots, 3)
        withConfig({ { Config.Limits, 'MaxPayoutSlots', 1 } }, function()
            eq(s.storage.readContract(c.id).payout_slots, 3, 'the contract keeps its three')
            truthy(s.contracts.accept(f.hitman, c.id, false))
            truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION),
                'the first collection is paid')
            eq(s.storage.readContract(c.id).next_slot, 2, 'and the second is still on offer')

            -- The last collection given back, which a proposal names by
            -- number: three, above the 1 in force now.
            local proposal, err = s.amendments.propose(f.creator, c.id,
                CH.AMENDMENT.REDUCE_REWARD, { slot = 3 })
            truthy(proposal, 'the third is still the contract\'s to give back: ' .. tostring(err))
        end)
    end)

    --- The start-up checks, run quietly as the panel runs them.
    local function checked(value)
        local main = require('crimson-hitman.server.main')
        resetConfig()
        Config.Limits.MaxPayoutSlots = value
        local ok, fatal, warn = main.validateConfig(true)
        local result = Config.Limits.MaxPayoutSlots
        resetConfig()
        return ok, result, table.concat(warn or {}, '\n'), table.concat(fatal or {}, '\n')
    end

    it('takes 1, 2 and 3 as they are, saying nothing', function()
        for _, value in ipairs({ 1, 2, 3 }) do
            local ok, result, warned = checked(value)
            truthy(ok)
            eq(result, value)
            falsy(warned:find('MaxPayoutSlots', 1, true), 'no warning for ' .. value .. ': ' .. warned)
        end
    end)

    it('reads anything else as the nearest of them, with a warning, rather than refusing to start', function()
        local cases = {
            { 0, 1 }, { -4, 1 }, { 5, 3 }, { 20, 3 }, { 2.4, 2 }, { 2.6, 3 }, { 0.5, 1 },
            { math.huge, 3 }, { 'two', 1 }, { true, 1 },
        }
        for _, case in ipairs(cases) do
            local ok, result, warned, fatal = checked(case[1])
            truthy(ok, tostring(case[1]) .. ' does not stop the start: ' .. fatal)
            eq(result, case[2], tostring(case[1]))
            truthy(warned:find('Limits.MaxPayoutSlots', 1, true)
                and warned:find('1, 2 or 3', 1, true),
                tostring(case[1]) .. ' is said at the start: ' .. warned)
        end
    end)

    it('fills it in as 1 for a config that does not have it', function()
        local ok, result, warned = checked(nil)
        truthy(ok)
        eq(result, 1)
        falsy(warned:find('MaxPayoutSlots', 1, true), 'filled, not corrected: ' .. warned)
    end)

    it('is held to 1 to 3 in the admin panel', function()
        local s = newStack()
        for _, value in ipairs({ 0, 4, 5, 20, 2.5, -1 }) do
            local accepted, err = s.settings.check('Limits.MaxPayoutSlots', value)
            eq(accepted, nil, tostring(value))
            eq(err, 'invalid_value', tostring(value))
        end
        for _, value in ipairs({ 1, 2, 3 }) do
            eq(s.settings.check('Limits.MaxPayoutSlots', value), value, tostring(value))
        end
        local entry = s.settings.entry('Limits.MaxPayoutSlots')
        eq(entry.min, 1)
        eq(entry.max, 3)
    end)
end)
