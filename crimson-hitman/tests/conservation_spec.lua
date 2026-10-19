--- Conservation: money taken into escrow comes back out exactly once, in
--- the source it went in as.
---
--- cash and bank are qbx_core accounts; dirty is an ox_inventory item. The
--- world total per source (every player's pocket, plus everything escrow is
--- still holding) must not change across a create/settle cycle.

local DIRTY = function() return Config.Sources.dirty.item end

--- What one player holds, per source.
local function purse(src)
    local p = Env.players[src]
    if not p then return { cash = 0, bank = 0, dirty = 0 } end
    local dirty = 0
    for _, e in ipairs(p._inventory or {}) do
        if e.name == DIRTY() then dirty = dirty + (e.count or 0) end
    end
    return { cash = p.PlayerData.money.cash or 0,
             bank = p.PlayerData.money.bank or 0,
             dirty = dirty }
end

--- Everything escrow is still holding, per source. A settled line has
--- already been delivered; anything else is money the escrow owes somebody.
local function heldEscrow(s)
    local out = { cash = 0, bank = 0, dirty = 0 }
    for _, c in ipairs(s.storage.allContracts()) do
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if CB.MONEY_SOURCES[line.source]
                and line.state ~= CB.ESCROW_STATE.SETTLED then
                out[line.source] = out[line.source] + (line.amount or 0)
            end
        end
    end
    return out
end

--- Every coin in the world: pockets plus escrow.
local function world(s)
    local total = heldEscrow(s)
    for src in pairs(Env.players) do
        local p = purse(src)
        total.cash = total.cash + p.cash
        total.bank = total.bank + p.bank
        total.dirty = total.dirty + p.dirty
    end
    return total
end

local function report(label, before, after)
    return ('%s: cash %+d, bank %+d, dirty %+d'):format(
        label, after.cash - before.cash, after.bank - before.bank,
        after.dirty - before.dirty)
end

local function conserved(s, before, label)
    local after = world(s)
    for _, source in ipairs({ 'cash', 'bank', 'dirty' }) do
        eq(after[source], before[source],
           ('%s minted or destroyed %s (%s)'):format(label, source, report(label, before, after)))
    end
end

local ALL = { cash = 5000, bank = 3000, dirty = 1000 }

local function place(s, f, reward, extra)
    local req = {
        targetCid = 'TARGET01', reason = 'Unpaid debt',
        mode = CB.MODE.COMPETITIVE, reward = reward,
    }
    for k, v in pairs(extra or {}) do req[k] = v end
    return s.contracts.create(f.creator, req)
end

describe('conservation across every settlement path', function()

    it('create -> cancel returns every source, and only its own', function()
        local s = newStack()
        local f = fixture(s)
        local before = world(s)
        local start = purse(1)

        local c, err = place(s, f, { baseline = ALL, bonus = { cash = 500, bank = 400, dirty = 300 } })
        truthy(c, tostring(err))
        conserved(s, before, 'creation')

        truthy(s.contracts.cancel(f.creator, c.id))
        conserved(s, before, 'cancel')

        local back = purse(1)
        eq(back.cash, start.cash, 'cash came back as cash')
        eq(back.bank, start.bank, 'bank came back as bank')
        eq(back.dirty, start.dirty, 'dirty came back as dirty')
    end)

    it('create -> accept -> claim pays the hunter in the same sources', function()
        local s = newStack()
        local f = fixture(s)
        local before = world(s)

        local c, err = place(s, f, { baseline = ALL, bonus = { cash = 500, bank = 400, dirty = 300 } })
        truthy(c, tostring(err))
        truthy(s.contracts.accept(f.hunter, c.id, false))
        conserved(s, before, 'accept')

        local hunterBefore = purse(3)
        truthy(s.contracts.claimSlot(c.id, f.hunter.cid, CB.FULFILMENT.KIDNAPPING))
        conserved(s, before, 'kidnap payout')

        local got = purse(3)
        eq(got.cash - hunterBefore.cash, 5500, 'cash baseline + bonus')
        eq(got.bank - hunterBefore.bank, 3400, 'bank baseline + bonus')
        eq(got.dirty - hunterBefore.dirty, 1300, 'dirty baseline + bonus, as dirty')
    end)

    it('an elimination pays the baseline and returns the bonus in its own source', function()
        local s = newStack()
        local f = fixture(s)
        local before = world(s)

        local c, err = place(s, f, { baseline = ALL, bonus = { cash = 500, bank = 400, dirty = 300 } })
        truthy(c, tostring(err))
        truthy(s.contracts.accept(f.hunter, c.id, false))

        local hunterBefore, creatorBefore = purse(3), purse(1)
        truthy(s.contracts.claimSlot(c.id, f.hunter.cid, CB.FULFILMENT.ELIMINATION))
        conserved(s, before, 'elimination')

        local hunterGot, creatorGot = purse(3), purse(1)
        eq(hunterGot.dirty - hunterBefore.dirty, 1000, 'hunter gets the dirty baseline')
        eq(creatorGot.dirty - creatorBefore.dirty, 300, 'unearned dirty bonus goes back as dirty')
        eq(creatorGot.cash - creatorBefore.cash, 500, 'unearned cash bonus goes back as cash')
        eq(creatorGot.bank - creatorBefore.bank, 400, 'unearned bank bonus goes back as bank')
    end)

    it('create -> expiry refunds the creator in every source', function()
        local s = newStack()
        local f = fixture(s)
        local before = world(s)
        local start = purse(1)

        local c, err = place(s, f, { baseline = ALL })
        truthy(c, tostring(err))
        truthy(s.contracts.resolve(c.id, CB.STATE.EXPIRED, f.creator.cid, nil, 'expired'))
        conserved(s, before, 'expiry')

        local back = purse(1)
        eq(back.cash, start.cash, 'cash refunded on expiry')
        eq(back.bank, start.bank, 'bank refunded on expiry')
        eq(back.dirty, start.dirty, 'dirty refunded on expiry')
    end)

    it('withdrawReward hands back exactly the named lines, in their own source', function()
        local s = newStack()
        local f = fixture(s)
        local before = world(s)
        local start = purse(1)

        local c, err = place(s, f, { baseline = ALL, bonus = { cash = 500, bank = 400, dirty = 300 } })
        truthy(c, tostring(err))

        -- Take back every bonus line and nothing else.
        local ids, expect = {}, { cash = 0, bank = 0, dirty = 0 }
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.portion == CB.PORTION.BONUS then
                ids[#ids + 1] = line.id
                expect[line.source] = expect[line.source] + line.amount
            end
        end
        eq(#ids, 3, 'three bonus lines, one per source')

        truthy(s.contracts.withdrawReward(f.creator, c.id, ids))
        conserved(s, before, 'withdrawReward')

        local now = purse(1)
        eq(now.cash - (start.cash - 5500), 500, 'the cash bonus came back as cash')
        eq(now.bank - (start.bank - 3400), 400, 'the bank bonus came back as bank')
        eq(now.dirty - (start.dirty - 1300), 300, 'the dirty bonus came back as dirty')

        -- And the baseline is still escrowed, untouched.
        local held = heldEscrow(s)
        eq(held.cash, 5000); eq(held.bank, 3000); eq(held.dirty, 1000)
    end)

    it('a hunter who cannot carry it is owed it, not paid it in something else', function()
        local s = newStack()
        local f = fixture(s)
        local before = world(s)

        local c, err = place(s, f, { baseline = { dirty = 1000 } })
        truthy(c, tostring(err))
        truthy(s.contracts.accept(f.hunter, c.id, false))

        Env.players[3]._inventoryFull = true
        local hunterBefore = purse(3)
        truthy(s.contracts.claimSlot(c.id, f.hunter.cid, CB.FULFILMENT.KIDNAPPING))
        conserved(s, before, 'undeliverable dirty payout')

        eq(purse(3).dirty, hunterBefore.dirty, 'nothing was delivered')
        eq(purse(3).cash, hunterBefore.cash, 'and it was not quietly paid as cash')

        Env.players[3]._inventoryFull = false
        eq(s.escrow.retryPending(f.hunter.cid), 1, 'the queued line is delivered on retry')
        conserved(s, before, 'retryPending')
        eq(purse(3).dirty - hunterBefore.dirty, 1000, 'and it arrives as dirty money')
    end)

    it('a percentage bonus on a dirty baseline is escrowed and paid as dirty', function()
        local s = newStack()
        local f = fixture(s)
        local before = world(s)

        local c, err = place(s, f, { baseline = { dirty = 1000 } }, { bonusPercent = 50 })
        truthy(c, tostring(err))
        conserved(s, before, 'derived bonus creation')

        local held = heldEscrow(s)
        eq(held.dirty, 1500, 'the derived bonus is real dirty escrow')
        eq(held.cash, 0, 'and it did not become cash')

        truthy(s.contracts.accept(f.hunter, c.id, false))
        local hunterBefore = purse(3)
        truthy(s.contracts.claimSlot(c.id, f.hunter.cid, CB.FULFILMENT.KIDNAPPING))
        conserved(s, before, 'derived bonus payout')
        eq(purse(3).dirty - hunterBefore.dirty, 1500, 'baseline plus derived bonus, as dirty')
    end)

    it('a stake is returned in the account it was taken from', function()
        local s = newStack()
        local f = fixture(s)
        local before = world(s)

        local c, err = place(s, f, { baseline = ALL }, { penaltyAmount = 2500 })
        truthy(c, tostring(err))
        truthy(s.contracts.accept(f.hunter, c.id, false))
        conserved(s, before, 'stake taken')

        truthy(s.contracts.claimSlot(c.id, f.hunter.cid, CB.FULFILMENT.KIDNAPPING))
        conserved(s, before, 'stake settled with the contract')
    end)

    it('a bailout leaves nobody up or down', function()
        local s = newStack()
        local f = fixture(s)
        local before = world(s)

        local c, err = place(s, f, { baseline = ALL }, { bailoutAmount = 20000 })
        truthy(c, tostring(err))
        truthy(c.bailout_amount and c.bailout_amount > 0, 'the contract offers a buyout')

        truthy(s.bailout.buy(f.target, c.id))
        conserved(s, before, 'bailout')
    end)
end)
