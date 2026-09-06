--- All three money sources, through every movement.
---
--- Cash and bank are qbx_core accounts. Dirty money is not: it is an
--- ox_inventory item whose name is Config.Sources.dirty.item, so every read
--- and write of it goes through a different API. Code that treats a source
--- string as an account without checking which of the three it is moves
--- nothing and reports success — money vanishes, or is created.
---
--- These follow each source from a creator's pocket into escrow and back
--- out again, and check the totals rather than that nothing threw.

--- What one player is holding, across all three sources.
local function purse(src)
    local player = Env.players[src]
    local dirty = 0
    for _, entry in ipairs(player._inventory or {}) do
        if entry.name == Config.Sources.dirty.item then
            dirty = dirty + (entry.count or 0)
        end
    end
    return {
        cash = player.PlayerData.money.cash,
        bank = player.PlayerData.money.bank,
        dirty = dirty,
    }
end

local function moved(before, after)
    return {
        cash = after.cash - before.cash,
        bank = after.bank - before.bank,
        dirty = after.dirty - before.dirty,
    }
end

--- One contract funded from a single source, so the arithmetic is legible.
local function fundedFrom(s, source, baseline, bonus)
    local f = fixture(s)
    local reward = { baseline = {}, bonus = {} }
    reward.baseline[source] = baseline
    if bonus then reward.bonus[source] = bonus end

    local contract, err = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt',
        mode = CB.MODE.COMPETITIVE, reward = reward,
    })
    return f, contract, err
end

local SOURCES = { 'cash', 'bank', 'dirty' }

describe('taking each money source into escrow', function()
    for _, source in ipairs(SOURCES) do
        it(('takes %s out of the creators pocket, exactly once'):format(source), function()
            local s = newStack()
            local f = fixture(s)
            local before = purse(1)

            local reward = { baseline = {} }
            reward.baseline[source] = 5000
            local contract, err = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'Unpaid debt',
                mode = CB.MODE.COMPETITIVE, reward = reward,
            })
            truthy(contract, ('a contract funded from %s was refused: %s')
                :format(source, tostring(err)))

            local delta = moved(before, purse(1))
            eq(delta[source], -5000,
                ('%s should have left the pocket'):format(source))

            for _, other in ipairs(SOURCES) do
                if other ~= source then
                    eq(delta[other], 0,
                        ('funding from %s must not touch %s'):format(source, other))
                end
            end
        end)

        it(('refuses %s the creator does not have, and charges nothing'):format(source), function()
            local s = newStack()
            local f = fixture(s)
            local before = purse(1)

            local reward = { baseline = {} }
            reward.baseline[source] = 99999999
            local contract, err = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'Unpaid debt',
                mode = CB.MODE.COMPETITIVE, reward = reward,
            })
            falsy(contract, 'a reward beyond the creators means must be refused')
            truthy(err)

            local delta = moved(before, purse(1))
            for _, any in ipairs(SOURCES) do
                eq(delta[any], 0,
                    ('a refused contract charged %s anyway'):format(any))
            end
        end)
    end
end)

describe('paying each money source out to a hunter', function()
    for _, source in ipairs(SOURCES) do
        it(('pays a kidnapping in %s, baseline and bonus'):format(source), function()
            local s = newStack()
            local f, c = fundedFrom(s, source, 5000, 2500)
            truthy(c, 'the contract should exist')
            truthy(s.contracts.accept(f.hunter, c.id, false))

            local before = purse(3)
            truthy(s.contracts.claimSlot(c.id, f.hunter.cid, CB.FULFILMENT.KIDNAPPING))
            local delta = moved(before, purse(3))

            eq(delta[source], 7500,
                ('a delivery must pay baseline and bonus in %s'):format(source))
            for _, other in ipairs(SOURCES) do
                if other ~= source then
                    eq(delta[other], 0,
                        ('%s was paid out as %s'):format(source, other))
                end
            end
        end)

        it(('pays an elimination in %s and returns the bonus'):format(source), function()
            local s = newStack()
            local f, c = fundedFrom(s, source, 5000, 2500)
            truthy(s.contracts.accept(f.hunter, c.id, false))

            local hunterBefore = purse(3)
            local creatorBefore = purse(1)
            truthy(s.contracts.claimSlot(c.id, f.hunter.cid, CB.FULFILMENT.ELIMINATION))

            eq(moved(hunterBefore, purse(3))[source], 5000,
                'a kill pays the baseline only')
            eq(moved(creatorBefore, purse(1))[source], 2500,
                'and the unearned bonus goes back to the client, in its own source')
        end)
    end
end)

describe('giving each money source back', function()
    for _, source in ipairs(SOURCES) do
        it(('returns %s in full when the contract is withdrawn'):format(source), function()
            local s = newStack()
            -- The fixture is what creates the players, so their pockets can
            -- only be read after it has run.
            local f = fixture(s)
            local before = purse(1)

            local reward = { baseline = {}, bonus = {} }
            reward.baseline[source] = 5000
            reward.bonus[source] = 2500
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'Unpaid debt',
                mode = CB.MODE.COMPETITIVE, reward = reward,
            })
            truthy(c)
            eq(moved(before, purse(1))[source], -7500, 'it left the pocket')

            truthy(s.contracts.cancel(f.creator, c.id))
            local delta = moved(before, purse(1))
            for _, any in ipairs(SOURCES) do
                eq(delta[any], 0,
                    ('withdrawing must leave the creator exactly as they were; '
                     .. '%s is off by %d'):format(any, delta[any]))
            end
        end)

        it(('returns %s when a reward is reduced'):format(source), function()
            local s = newStack()
            local f, c = fundedFrom(s, source, 5000, 2500)
            truthy(c)

            local bonus
            for _, line in ipairs(s.storage.readEscrow(c.id)) do
                if line.portion == CB.PORTION.BONUS then bonus = line end
            end
            truthy(bonus, ('the bonus should be one %s line'):format(source))

            local before = purse(1)
            truthy(s.contracts.withdrawReward(f.creator, c.id, { bonus.id }))
            eq(moved(before, purse(1))[source], 2500,
                ('taking a %s line back must return %s'):format(source, source))
        end)
    end
end)

describe('a reward built from all three at once', function()
    it('takes each from where it lives and gives each back the same way', function()
        local s = newStack()
        local f = fixture(s)
        local before = purse(1)

        local contract, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000, bank = 3000, dirty = 1000 } },
        })
        truthy(contract, tostring(err))

        local delta = moved(before, purse(1))
        eq(delta.cash, -5000)
        eq(delta.bank, -3000)
        eq(delta.dirty, -1000)

        truthy(s.contracts.cancel(f.creator, contract.id))
        local after = moved(before, purse(1))
        eq(after.cash, 0, 'cash came back as cash')
        eq(after.bank, 0, 'bank came back as bank')
        eq(after.dirty, 0, 'dirty came back as dirty, not as one of the others')
    end)

    it('pays a hunter each source in the source it was put up in', function()
        local s = newStack()
        local f = fixture(s)
        local contract = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000, bank = 3000, dirty = 1000 } },
        })
        truthy(contract)
        truthy(s.contracts.accept(f.hunter, contract.id, false))

        local before = purse(3)
        truthy(s.contracts.claimSlot(contract.id, f.hunter.cid, CB.FULFILMENT.KIDNAPPING))
        local delta = moved(before, purse(3))

        eq(delta.cash, 5000)
        eq(delta.bank, 3000)
        eq(delta.dirty, 1000,
            'dirty money is an inventory item, so a payout that used the money '
            .. 'account API would move nothing and report success')
    end)
end)

describe('what the app offers as a reward', function()
    it('reports a balance for all three, read the right way', function()
        local s = newStack()
        s.app.init(s)
        local f = fixture(s)

        local wallet = s.app.handlers.rewardOptions(f.creator, {})
        truthy(wallet, 'the wallet handler should answer')

        eq(wallet.cash, Env.players[1].PlayerData.money.cash)
        eq(wallet.bank, Env.players[1].PlayerData.money.bank)
        eq(wallet.dirty, purse(1).dirty,
            'dirty is read from the inventory, not from a money account')
        truthy(wallet.dirty > 0, 'the fixture carries dirty money, so this proves something')
    end)

    it('carries a ceiling for each so the form can bound its own fields', function()
        local s = newStack()
        s.app.init(s)
        local f = fixture(s)

        local caps = s.app.handlers.rewardOptions(f.creator, {}).caps
        for _, source in ipairs({ 'cash', 'bank', 'dirty' }) do
            truthy(caps[source] and caps[source] > 0,
                ('no ceiling for %s, so the form cannot stop a player building '
                 .. 'a contract the server will always refuse'):format(source))
        end
    end)
end)

describe('dirty money is an item, and must not count twice', function()
    --- Dirty money lives in the inventory, so without a guard it can be put
    --- up twice over: once as `dirty`, which Config.Sources.dirty caps and
    --- switches, and again through the item picker, which is neither.
    ---
    --- Found by an audit of the three money sources, not by anything here.
    local function dirtyOf(src)
        local held = 0
        for _, entry in ipairs(Env.players[src]._inventory or {}) do
            if entry.name == Config.Sources.dirty.item then
                held = held + (entry.count or 0)
            end
        end
        return held
    end

    it('refuses the dirty money item through the item path', function()
        local s = newStack()
        local f = fixture(s)
        local before = dirtyOf(1)

        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { items = {
                { name = Config.Sources.dirty.item, count = 100 } } } },
        })

        falsy(c, 'the item picker is a second way to escrow dirty money, past '
            .. 'its own ceiling and past its own off switch')
        eq(err, CB.ERR.INVALID_REWARD)
        eq(dirtyOf(1), before, 'and nothing left the pocket')
    end)

    it('refuses it even when dirty money is switched off entirely', function()
        local s = newStack()
        local f = fixture(s)
        local was = Config.Sources.dirty.enabled
        Config.Sources.dirty.enabled = false

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { items = {
                { name = Config.Sources.dirty.item, count = 100 } } } },
        })
        Config.Sources.dirty.enabled = was

        falsy(c, 'a server that turned dirty money off was still taking it, '
            .. 'through the other door')
    end)

    it('follows the operators own item name, not a literal', function()
        local s = newStack()
        local f = fixture(s)
        local was = Config.Sources.dirty.item

        -- An operator who stores dirty money under another name gets the
        -- same protection; one who hardcodes 'black_money' protects only the
        -- default.
        Config.Sources.dirty.item = 'lockpick'
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { items = { { name = 'lockpick', count = 1 } } } },
        })
        Config.Sources.dirty.item = was

        falsy(c, 'the guard has to follow the configured name')
    end)

    it('still allows an ordinary item', function()
        local s = newStack()
        local f = fixture(s)
        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { items = { { name = 'lockpick', count = 1 } } } },
        })
        truthy(c, 'this must not have blocked normal items: ' .. tostring(err))
    end)
end)

describe('topping up a live contract in each money source', function()
    --- The take at creation is covered above. The OTHER take —
    --- Amendments.addEscrow, reachable from the app's "Add to the pot" — has
    --- never been exercised with dirty money by anything in this suite:
    --- every addEscrow test in the build passes `{ baseline = { cash = n } }`
    --- or an item list. It is a real money movement out of a player's
    --- pocket, on a contract a hunter may already hold, and dirty is the one
    --- source that cannot go through the money-account API.
    ---
    --- The qbx_core account table is asserted on directly as well as the
    --- inventory: RemoveMoney('dirty', n) on a framework that creates
    --- unknown accounts would leave a `money.dirty` key behind, and a purse
    --- check alone would read that as "nothing happened" rather than as
    --- money moved through the wrong door.
    local function accountsOf(src)
        local out = {}
        for name in pairs(Env.players[src].PlayerData.money) do out[#out + 1] = name end
        table.sort(out)
        return table.concat(out, ',')
    end

    for _, source in ipairs(SOURCES) do
        it(('adds %s to a contract that is already live'):format(source), function()
            local s = newStack()
            local f = fixture(s)

            local c, err = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'Unpaid debt',
                mode = CB.MODE.COMPETITIVE,
                reward = { baseline = { cash = 1000 } },
            })
            truthy(c, tostring(err))
            truthy(s.contracts.accept(f.hunter, c.id, false))

            local before = purse(1)
            local topUp = { baseline = {} }
            topUp.baseline[source] = 2000

            local ok
            ok, err = s.amendments.addEscrow(f.creator, c.id, topUp)
            truthy(ok, ('a top-up in %s was refused: %s'):format(source, tostring(err)))

            local delta = moved(before, purse(1))
            eq(delta[source], -2000,
                ('the top-up must leave the pocket as %s'):format(source))
            for _, other in ipairs(SOURCES) do
                if other ~= source then
                    eq(delta[other], 0,
                        ('a %s top-up moved %s'):format(source, other))
                end
            end
            eq(accountsOf(1), 'bank,cash',
                'dirty money is an inventory item; nothing may open a qbx_core '
                .. 'account called "dirty"')

            -- And the hunter is paid it, in the source it was added in.
            local hunterBefore = purse(3)
            truthy(s.contracts.claimSlot(c.id, f.hunter.cid, CB.FULFILMENT.ELIMINATION))
            eq(moved(hunterBefore, purse(3))[source], 2000 + (source == 'cash' and 1000 or 0),
                ('the top-up must be paid out as %s'):format(source))
        end)
    end
end)

describe('what the form is told a server will accept', function()
    --- Each money source has an `enabled` flag the server honours when a
    --- contract is submitted (escrow.lua's addMoney). The form was never
    --- told about it, so a source an operator had switched off was still
    --- offered, with the player's balance printed above it — and the whole
    --- contract was then refused as "That reward does not add up", a message
    --- about the numbers when the numbers were fine.
    it('carries an on/off flag for each money source, as it does for goods', function()
        local s = newStack()
        s.app.init(s)
        local f = fixture(s)

        local caps = s.app.handlers.rewardOptions(f.creator, {}).caps
        for _, source in ipairs({ 'cash', 'bank', 'dirty' }) do
            eq(caps[source .. 'Enabled'], true,
                ('the form has no way to know whether %s is accepted'):format(source))
        end
    end)

    it('reports a source the operator switched off as off', function()
        local s = newStack()
        s.app.init(s)
        local f = fixture(s)

        local was = Config.Sources.dirty.enabled
        Config.Sources.dirty.enabled = false
        local caps = s.app.handlers.rewardOptions(f.creator, {}).caps
        Config.Sources.dirty.enabled = was

        eq(caps.dirtyEnabled, false,
            'a switch the form never hears about is not a switch')
        eq(caps.cashEnabled, true, 'and the others are unaffected')
    end)

    it('refuses that source on submit, which is what the flag is for', function()
        local s = newStack()
        local f = fixture(s)

        local was = Config.Sources.dirty.enabled
        Config.Sources.dirty.enabled = false
        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { dirty = 1000 } },
        })
        Config.Sources.dirty.enabled = was

        falsy(c, 'the server really does refuse it')
        eq(err, CB.ERR.INVALID_REWARD,
            'and the message the player gets blames the amount, which is why '
            .. 'the form must not offer the source in the first place')
    end)
end)
