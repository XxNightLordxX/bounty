--- While nobody has ever accepted a contract, its placer can change every
--- term of it, or cancel it with a full refund, and nothing else waits on
--- them for it but the anti-spam cooldowns every placer has.
---
--- Each change goes through the path the app uses for it: Edit
--- (Contracts.revise) for the reason and the deadline, Change reward
--- (Amendments.addEscrow, Contracts.withdrawReward) for money and goods,
--- Extend deadline and the additive changes (Amendments.improve), and
--- Propose change (Amendments.propose), which with nobody to agree applies
--- at once. Anonymity is not one of them: it is how the placer is shown, fixed
--- when it is placed (with its fee, where the server charges one), and
--- changed by cancelling and placing again.

local function money(src)
    local m = Env.players[src].PlayerData.money
    return m.cash + m.bank
end

local function setup(extra)
    local s = newStack()
    Config.Limits.MaxPayoutSlots = 3
    local f = fixture(s)
    local req = { targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
                  reward = { baseline = { cash = 5000 } }, penaltyAmount = 1000 }
    for k, v in pairs(extra or {}) do req[k] = v end
    local before = money(1)
    local c, err = s.contracts.create(f.creator, req)
    truthy(c, 'placed: ' .. tostring(err))
    return s, f, c, before
end

local function row(s, c) return s.storage.readContract(c.id) end

local function applied(proposal, err)
    truthy(proposal, 'proposed: ' .. tostring(err))
    eq(proposal.outcome, 'applied', 'applied at once with nobody to agree: '
        .. tostring(proposal.outcome) .. ' ' .. tostring(proposal.error))
end

describe('a contract nobody has accepted', function()
    it('takes a new reason and a new deadline from Edit', function()
        local s, f, c = setup()
        truthy(s.contracts.revise(f.creator, c.id, { reason = 'Owes more than money' }))
        eq(row(s, c).reason, 'Owes more than money')
        truthy(s.contracts.revise(f.creator, c.id, { deadlineSeconds = 7200 }))
        local left = row(s, c).deadline_at - os.time()
        truthy(left >= 7200 and left < 7200 + 300, 'the deadline set from Edit: ' .. left)
    end)

    it('takes more money and goods, and gives any of them back', function()
        local s, f, c = setup()
        truthy(s.amendments.addEscrow(f.creator, c.id, { baseline = { cash = 2000 } }), 'more money')
        eq(s.escrow.moneyValue(c.id), 7000)
        local ok, err = s.amendments.addEscrow(f.creator, c.id,
            { baseline = { items = { { name = 'lockpick', count = 1 } } } })
        truthy(ok, 'goods: ' .. tostring(err))
        local back = {}
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.state == CH.ESCROW_STATE.HELD and (line.source == CH.SOURCE.ITEM
                or (line.amount == 2000 and line.portion ~= CH.PORTION.STAKE)) then
                back[#back + 1] = line.id
            end
        end
        eq(#back, 2, 'the added money and the item')
        local pulled, pullErr = s.contracts.withdrawReward(f.creator, c.id, back)
        truthy(pulled, 'given back: ' .. tostring(pullErr))
        eq(s.escrow.moneyValue(c.id), 5000, 'the reward as placed')
    end)

    it('takes a longer or shorter deadline, a bonus and a stake either way', function()
        local s, f, c = setup()
        local was = row(s, c).deadline_at
        truthy(s.amendments.improve(f.creator, c.id, CH.AMENDMENT.EXTEND_DEADLINE, { seconds = 1800 }))
        eq(row(s, c).deadline_at, was + 1800, 'extended')
        applied(s.amendments.propose(f.creator, c.id, CH.AMENDMENT.SHORTEN_DEADLINE, { seconds = 3600 }))
        eq(row(s, c).deadline_at, was - 1800, 'shortened')
        truthy(s.amendments.improve(f.creator, c.id, CH.AMENDMENT.RAISE_BONUS, { percent = 50 }))
        eq(row(s, c).bonus_percent, 50, 'a bonus')
        applied(s.amendments.propose(f.creator, c.id, CH.AMENDMENT.RAISE_PENALTY, { amount = 3000 }))
        eq(row(s, c).penalty_amount, 3000, 'a bigger stake')
        truthy(s.amendments.improve(f.creator, c.id, CH.AMENDMENT.LOWER_PENALTY, { amount = 0 }))
        eq(row(s, c).penalty_amount or 0, 0, 'no stake')
    end)

    it('takes a new mode, a new reason, and a payout given back', function()
        local s, f, c = setup({ reward = { slots = {
            { baseline = { cash = 5000 } }, { baseline = { cash = 4000 } } } } })
        eq(row(s, c).payout_slots, 2, 'two payouts placed')
        applied(s.amendments.propose(f.creator, c.id, CH.AMENDMENT.CHANGE_MODE,
            { mode = CH.MODE.EXCLUSIVE }))
        eq(row(s, c).mode, CH.MODE.EXCLUSIVE)
        applied(s.amendments.propose(f.creator, c.id, CH.AMENDMENT.CHANGE_REASON,
            { reason = 'Talked to the wrong people' }))
        eq(row(s, c).reason, 'Talked to the wrong people')
        local before = money(1)
        applied(s.amendments.propose(f.creator, c.id, CH.AMENDMENT.REDUCE_REWARD, { slot = 2 }))
        eq(row(s, c).payout_slots, 1, 'the second payout given back')
        eq(money(1) - before, 4000, 'and what funded it')
    end)

    it('is cancelled with everything back, and starts no wait on its target', function()
        local s, f, c, before = setup({ reward = { baseline = { cash = 5000, bank = 2000 } } })
        truthy(money(1) < before, 'escrow taken')
        truthy(s.contracts.cancel(f.creator, c.id))
        eq(row(s, c).state, CH.STATE.CANCELLED)
        eq(money(1), before, 'not everything came back')
        -- Nobody else is kept off the target for it (TargetCooldownAfterResolveSeconds
        -- is for a contract somebody took up), and this placer waits only the
        -- anti-spam cooldowns every cancel starts.
        Env.addPlayer({ source = 11, citizenid = 'CREATOR2', license = 'license:c2',
            cash = 100000, bank = 100000, firstname = 'Ann', lastname = 'Poe' })
        local again, err = s.contracts.create(s.identity.resolve(11), { targetCid = 'TARGET01',
            reason = 'x', mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        truthy(again, 'another placer kept off the target: ' .. tostring(err))
    end)

    it('follows the amendment rules again once somebody has accepted', function()
        local s, f, c = setup()
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        local ok, err = s.contracts.revise(f.creator, c.id, { reason = 'Changed' })
        falsy(ok, 'edited under the hitman')
        eq(err, CH.ERR.CONTRACT_TAKEN)
        local proposal = s.amendments.propose(f.creator, c.id, CH.AMENDMENT.CHANGE_MODE,
            { mode = CH.MODE.EXCLUSIVE })
        truthy(proposal, 'proposed')
        eq(proposal.outcome, 'open', 'applied without the hitman agreeing')
        ok, err = s.contracts.cancel(f.creator, c.id)
        falsy(ok, 'cancelled from under the hitman')
        eq(err, CH.ERR.CONTRACT_TAKEN)
    end)
end)
