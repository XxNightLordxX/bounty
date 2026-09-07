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

describe('the kidnapping bonus, which is real escrow and not a number', function()
    local function dirtyOf(src)
        local held = 0
        for _, entry in ipairs(Env.players[src]._inventory or {}) do
            if entry.name == Config.Sources.dirty.item then held = held + (entry.count or 0) end
        end
        return held
    end

    --- Util.toCount returns nil for anything ABOVE its maximum, so `or 0`
    --- turned a bonus over the cap into no bonus at all — and the contract
    --- was created anyway. The creator promised a premium, surrendered
    --- nothing, and was told nothing.
    it('clamps a bonus over the ceiling instead of dropping it to none', function()
        local s = newStack()
        local f = fixture(s)

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 10000 } },
            bonusPercent = Config.Bonus.maxPercent + 500,
        })
        truthy(c, 'the contract should still be created')
        eq(c.bonus_percent, Config.Bonus.maxPercent,
            'a silly number gets the ceiling, as the bailout premium does')

        local bonus = s.escrow.moneyValue(c.id, { portion = CB.PORTION.BONUS })
        truthy(bonus > 0,
            'a bonus of zero is what the creator got while believing they had '
            .. 'promised one')
    end)

    it('still refuses a bonus that is not a number at all', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 10000 } },
            bonusPercent = 'lots',
        })
        truthy(c, 'nonsense is not a reason to refuse the contract')
        eq(c.bonus_percent, 0, 'it simply carries no bonus')
    end)

    --- Raising the bonus is applied with no approval, on the stated grounds
    --- that it can only benefit the hunter. It used to store the number and
    --- escrow nothing, so it benefited them by exactly zero while telling
    --- them the client had improved the terms.
    it('takes the difference from the creator when the bonus is raised', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 10000 } },
            bonusPercent = 10,
        })
        truthy(c)
        local bonusBefore = s.escrow.moneyValue(c.id, { portion = CB.PORTION.BONUS })
        local pocketBefore = Env.players[1].PlayerData.money.cash

        truthy(s.amendments.improve(f.creator, c.id, CB.AMENDMENT.RAISE_BONUS,
            { percent = 50 }))

        local bonusAfter = s.escrow.moneyValue(c.id, { portion = CB.PORTION.BONUS })
        truthy(bonusAfter > bonusBefore,
            'the escrow has to grow, or the raise pays the hunter nothing: '
            .. bonusBefore .. ' -> ' .. bonusAfter)
        eq(bonusAfter, 5000, '50% of a 10,000 baseline')
        eq(Env.players[1].PlayerData.money.cash, pocketBefore - (bonusAfter - bonusBefore),
            'and it comes out of the creators pocket, not from nowhere')
    end)

    it('pays the raised bonus to a hunter who delivers alive', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 10000 } },
            bonusPercent = 10,
        })
        truthy(s.amendments.improve(f.creator, c.id, CB.AMENDMENT.RAISE_BONUS,
            { percent = 50 }))
        truthy(s.contracts.accept(f.hunter, c.id, false))

        local before = Env.players[3].PlayerData.money.cash
        truthy(s.contracts.claimSlot(c.id, f.hunter.cid, CB.FULFILMENT.KIDNAPPING))
        eq(Env.players[3].PlayerData.money.cash, before + 10000 + 5000,
            'the hunter was told the terms improved; they have to actually have')
    end)

    it('raises a dirty-money bonus in dirty money', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { dirty = 10000 } },
            bonusPercent = 10,
        })
        truthy(c)
        local before = dirtyOf(1)
        truthy(s.amendments.improve(f.creator, c.id, CB.AMENDMENT.RAISE_BONUS,
            { percent = 50 }))
        eq(before - dirtyOf(1), 4000,
            'the top-up is taken in the source the baseline is in')
    end)

    it('refuses a raise it cannot escrow rather than recording it', function()
        local s = newStack()
        local f = fixture(s)
        -- A bonus the creator named themselves is not a percentage to
        -- recompute, so there is nothing to derive a top-up from.
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 10000 }, bonus = { cash = 1000 } },
        })
        truthy(c)

        local ok, err = s.amendments.improve(f.creator, c.id,
            CB.AMENDMENT.RAISE_BONUS, { percent = 50 })
        falsy(ok, 'an improvement that improves nothing must not be recorded')
        eq(err, CB.ERR.INVALID_REWARD)
        eq(s.storage.readContract(c.id).bonus_percent or 0, 0,
            'and the number must not move either')
    end)
end)

describe('what one contract may be worth in total', function()
    --- The ceiling was applied to one submission at a time, so a creator
    --- could top a contract up past it in as many steps as they liked. It
    --- exists to bound what a single contract can be worth, which is a
    --- property of the contract and not of a request.
    it('counts a top-up against what the contract already holds', function()
        local s = newStack()
        local f = fixture(s)

        -- A ceiling low enough that the per-source cap is not what refuses
        -- this: the point is the contract total, not one line.
        local was = Config.MaxContractValue
        Config.MaxContractValue = 6000

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c, 'a contract under the ceiling is fine')

        local ok, err = s.amendments.addEscrow(f.creator, c.id,
            { baseline = { cash = 5000 } })
        Config.MaxContractValue = was

        falsy(ok, 'two top-ups either side of the ceiling walked straight past it')
        eq(err, CB.ERR.INVALID_REWARD)
        eq(s.escrow.moneyValue(c.id), 5000, 'and nothing was taken')
    end)

    it('still allows a top-up that stays under it', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(s.amendments.addEscrow(f.creator, c.id, { baseline = { cash = 1000 } }),
            'an ordinary top-up must still work')
        eq(s.escrow.moneyValue(c.id), 6000)
    end)
end)

describe('a config that names an account the framework does not have', function()
    --- 'dirty' is a money SOURCE but not a qbx account. Handed to RemoveMoney
    --- it charges nothing and returns false, which surfaces as an anonymous
    --- contract that cannot be placed, or an informant that always says you
    --- cannot afford it — with nothing connecting either to config.lua.
    local function reboot()
        package.loaded['server.main'] = nil
        package.loaded['crimson-bounty.server.main'] = nil
        return require('crimson-bounty.server.main')
    end

    it('corrects a fee account that is not an account, and says so', function()
        local was = Config.Anonymity.FeeAccount
        Config.Anonymity.FeeAccount = 'dirty'
        local main = reboot()
        main.validateConfig()
        local after = Config.Anonymity.FeeAccount
        Config.Anonymity.FeeAccount = was

        eq(after, 'bank',
            'left as dirty, every anonymous contract is refused for a reason '
            .. 'nobody can trace to a setting')
    end)

    it('corrects the informants account the same way', function()
        local was = Config.Informant.Account
        Config.Informant.Account = 'dirty'
        local main = reboot()
        main.validateConfig()
        local after = Config.Informant.Account
        Config.Informant.Account = was
        eq(after, 'bank')
    end)

    it('leaves a real account alone', function()
        local was = Config.Anonymity.FeeAccount
        Config.Anonymity.FeeAccount = 'cash'
        local main = reboot()
        main.validateConfig()
        local after = Config.Anonymity.FeeAccount
        Config.Anonymity.FeeAccount = was
        eq(after, 'cash', 'a choice the operator made is not a mistake to correct')
    end)
end)

describe('what the board says a contract is worth', function()
    --- The headline is one figure covering all three money sources, and they
    --- are not worth the same: black money sells for a fraction of its face
    --- value. A hunter looking at "$250,000" could be looking at a quarter of
    --- a million black_money items with no way to tell.
    it('splits the reward by source so a hunter can see what it is', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000, dirty = 2000 } },
        })
        truthy(c)

        local view = s.projection.contract(s.storage.readContract(c.id), f.hunter.cid)
        eq(view.reward.baseline, 7000, 'the total is unchanged')
        truthy(view.reward.sources, 'a hunter has to be able to tell them apart')
        eq(view.reward.sources.cash, 5000)
        eq(view.reward.sources.dirty, 2000)
        eq(view.reward.sources.bank, 0)
    end)

    it('splits the bonus too', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 }, bonus = { dirty = 1000 } },
        })
        truthy(c)
        local view = s.projection.contract(s.storage.readContract(c.id), f.hunter.cid)
        eq(view.reward.bonusSources.dirty, 1000)
    end)

    it('adds up to what moneyValue reports, so nothing is double counted', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000, bank = 3000, dirty = 1000 } },
        })
        local split = s.escrow.moneyBySource(c.id, { portion = CB.PORTION.BASELINE })
        eq(split.cash + split.bank + split.dirty,
            s.escrow.moneyValue(c.id, { portion = CB.PORTION.BASELINE }),
            'the parts must equal the whole, or one of them is wrong')
    end)

    it('leaves out what is owed to somebody, as the total does', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 }, bonus = { dirty = 1000 } },
        })
        local bonus
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.portion == CB.PORTION.BONUS then bonus = line end
        end

        Env.players[1]._inventoryFull = true
        s.contracts.withdrawReward(f.creator, c.id, { bonus.id })
        Env.players[1]._inventoryFull = false

        local split = s.escrow.moneyBySource(c.id, { portion = CB.PORTION.BONUS })
        eq(split.dirty, 0,
            'money owed back to the creator is not part of what the contract '
            .. 'pays, in the split any more than in the total')
    end)
end)

describe('dirty money remembers which item it is', function()
    local function countOf(src, name)
        local held = 0
        for _, entry in ipairs(Env.players[src]._inventory or {}) do
            if entry.name == name then held = held + (entry.count or 0) end
        end
        return held
    end

    --- Every read and write of dirty money went through
    --- Config.Sources.dirty.item at the moment of the call. An operator who
    --- renamed that setting while escrow was held took one currency out of a
    --- player's pocket and handed a different one back — destroying the
    --- first and minting the second. Items and weapons have recorded their
    --- own identity since the first version; this is the same rule for the
    --- third money source.
    it('records the item on the line', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { dirty = 1000 } },
        })
        truthy(c)

        local line
        for _, entry in ipairs(s.storage.readEscrow(c.id)) do
            if entry.source == 'dirty' then line = entry end
        end
        truthy(line, 'there should be a dirty line')
        eq(line.item, Config.Sources.dirty.item,
            'without this the line has no idea what it is denominated in')
    end)

    it('gives back what it took, even after the setting is renamed', function()
        local s = newStack()
        local f = fixture(s)
        local original = Config.Sources.dirty.item

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { dirty = 1000 } },
        })
        truthy(c)
        eq(countOf(1, original), 49000, 'it left the pocket')

        -- The operator changes what dirty money is called, with escrow held.
        Config.Sources.dirty.item = 'renamed_money'
        local ok = s.contracts.cancel(f.creator, c.id)
        Config.Sources.dirty.item = original

        truthy(ok, 'the cancellation should still work')
        eq(countOf(1, original), 50000,
            'the escrow came back as a different currency: the one that went '
            .. 'in was destroyed and another was minted')
        eq(countOf(1, 'renamed_money'), 0)
    end)

    it('pays a hunter in the currency the contract was funded with', function()
        local s = newStack()
        local f = fixture(s)
        local original = Config.Sources.dirty.item

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { dirty = 1000 } },
        })
        truthy(s.contracts.accept(f.hunter, c.id, false))

        Config.Sources.dirty.item = 'renamed_money'
        truthy(s.contracts.claimSlot(c.id, f.hunter.cid, CB.FULFILMENT.ELIMINATION))
        Config.Sources.dirty.item = original

        eq(countOf(3, original), 1000, 'the hunter is owed what was put up')
        eq(countOf(3, 'renamed_money'), 0)
    end)

    it('still works for a line written before this was recorded', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { dirty = 1000 } },
        })
        truthy(c)

        -- An older version wrote no item name. The configured one is the only
        -- answer available for those, and they must not simply fail.
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.source == 'dirty' then line.item = nil end
        end

        truthy(s.contracts.cancel(f.creator, c.id))
        eq(countOf(1, Config.Sources.dirty.item), 50000,
            'a line from before this change still has to come back')
    end)
end)

describe('a bonus top-up is denominated too', function()
    local function countOf(src, name)
        local held = 0
        for _, entry in ipairs(Env.players[src]._inventory or {}) do
            if entry.name == name then held = held + (entry.count or 0) end
        end
        return held
    end

    it('carries the item name of the baseline it derives from', function()
        local s = newStack()
        local f = fixture(s)
        local original = Config.Sources.dirty.item

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { dirty = 10000 } },
            bonusPercent = 10,
        })
        truthy(c)
        truthy(s.amendments.improve(f.creator, c.id, CB.AMENDMENT.RAISE_BONUS,
            { percent = 50 }))

        -- Counted, so the assertion cannot be skipped by there being no
        -- dirty line to check.
        local checked = 0
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.source == 'dirty' then
                checked = checked + 1
                eq(line.item, original,
                    'a top-up with no name is a line the next rename can turn '
                    .. 'into a different currency')
            end
        end
        truthy(checked >= 2,
            'there should be a baseline and a bonus line to check, got ' .. checked)

        -- And it survives one.
        Config.Sources.dirty.item = 'renamed_money'
        truthy(s.contracts.cancel(f.creator, c.id))
        Config.Sources.dirty.item = original

        eq(countOf(1, original), 50000, 'everything came back as what went in')
        eq(countOf(1, 'renamed_money'), 0)
    end)
end)

describe('what a creator is told when a refund could not be handed over', function()
    --- A refund the creator's pockets had no room for is owed and retried on
    --- next login, not lost. But "everything you put up has been returned"
    --- is untrue in exactly that case — and it is the case where a player
    --- counts their money, finds it short, and reports it stolen.
    it('says so, rather than that everything came back', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 }, bonus = { dirty = 1000 } },
        })
        truthy(c)

        Natives.calls.notifications = {}
        Env.players[1]._inventoryFull = true
        truthy(s.contracts.cancel(f.creator, c.id))
        Env.players[1]._inventoryFull = false

        local said = ''
        for _, note in ipairs(Natives.calls.notifications or {}) do
            said = said .. ' ' .. tostring(note.title or '')
                .. ' ' .. tostring(note.content or note.message or '')
        end
        truthy(said:find('waiting for you', 1, true),
            'a creator whose refund would not fit was told it all came back: '
            .. said)
        falsy(said:find('everything you put up has been returned', 1, true),
            'and must not be told both')
    end)

    it('still says everything came back when everything did', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        Natives.calls.notifications = {}
        truthy(s.contracts.cancel(f.creator, c.id))

        local said = ''
        for _, note in ipairs(Natives.calls.notifications or {}) do
            said = said .. ' ' .. tostring(note.content or note.message or '')
        end
        truthy(said:find('everything you put up has been returned', 1, true),
            'the ordinary case must not be made alarming: ' .. said)
    end)
end)
