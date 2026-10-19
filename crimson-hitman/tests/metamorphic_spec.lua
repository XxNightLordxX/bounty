--- Relations between inputs, rather than expected values.
---
--- Every other spec here says "this input should produce that output", so
--- each one is only as right as the number written into it — and a rule
--- applied consistently but wrongly satisfies all of them. These say
--- nothing about what the answer is. They say that two inputs which ought
--- to mean the same thing must produce the same answer, and that changing
--- an input one way must move the answer the matching way.
---
--- A different failure is visible from here: not a wrong constant, but a
--- rule that does not compose.

local function seeded()
    local s = newStack()
    local f = fixture(s)
    return s, f
end

local function place(s, f, req)
    req.targetCid = req.targetCid or 'TARGET01'
    req.reason = req.reason or 'Unpaid debt'
    req.mode = req.mode or CB.MODE.EXCLUSIVE
    return s.contracts.create(f.creator, req)
end

--- What escrow still owes on a contract, by source, so two contracts can be
--- compared without caring how the lines were split up.
---
--- Settled lines are excluded: they have already been handed over, so
--- counting them says a contract still holds money it has given back. The
--- first version of this reported a withdrawal that had worked perfectly
--- as having left 6500 where 5000 went in — the 1500 was sitting there
--- marked settled, which is what a completed withdrawal looks like.
local function holding(s, contractId)
    local total = {}
    for _, line in ipairs(s.storage.readEscrow(contractId)) do
        if line.state ~= CB.ESCROW_STATE.SETTLED then
            local key = line.source .. '/' .. tostring(line.item or '-')
            total[key] = (total[key] or 0) + (line.amount or 0) + (line.quantity or 0)
        end
    end
    return total
end

local function sameHolding(a, b, why)
    for key, value in pairs(a) do
        eq(b[key], value, why .. ' (' .. key .. ')')
    end
    for key in pairs(b) do
        truthy(a[key] ~= nil, why .. ': the second holds ' .. key .. ' and the first does not')
    end
end

describe('two ways of saying the same thing', function()
    --- One payout of 6000 and two of 3000 are different contracts, but the
    --- escrow taken must be the same money. A per-slot rule that rounds, or
    --- charges a fee per slot, would break this without breaking any test
    --- that names a single expected figure.
    it('take the same money however the payouts are split', function()
        local s, f = seeded()
        local one = place(s, f, { reward = { slots = { { baseline = { cash = 6000 } } } } })
        truthy(one)
        local two = place(s, f, { targetCid = 'TARGET01', reward = { slots = {
            { baseline = { cash = 3000 } }, { baseline = { cash = 3000 } },
        } } })

        if two then
            local a, b = holding(s, one.id), holding(s, two.id)
            eq(b['cash/-'], a['cash/-'],
                'six thousand in one payout and six thousand in two are the '
                .. 'same six thousand')
        end
    end)

    --- The order two independent additions arrive in cannot change what the
    --- contract ends up holding.
    it('hold the same whichever order the sources were added in', function()
        local s, f = seeded()
        local first = place(s, f, { reward = { baseline = { cash = 4000 } } })
        truthy(first)
        s.amendments.addEscrow(f.creator, first.id, { baseline = { bank = 2000 } })
        local a = holding(s, first.id)

        local s2, f2 = seeded()
        local second = place(s2, f2, { reward = { baseline = { bank = 2000 } } })
        truthy(second)
        s2.amendments.addEscrow(f2.creator, second.id, { baseline = { cash = 4000 } })
        local b = holding(s2, second.id)

        sameHolding(a, b, 'the order two additions arrived in changed the escrow')
    end)

    --- Adding to a reward and then taking the same thing back must leave
    --- the contract where it started. Not a fixed figure: whatever it held
    --- before, it holds after.
    it('are unchanged by an addition that is withdrawn again', function()
        local s, f = seeded()
        local c = place(s, f, { reward = { slots = { { baseline = { cash = 5000 } } } } })
        truthy(c)
        local before = holding(s, c.id)

        local added = s.amendments.addEscrow(f.creator, c.id, {
            slots = { { baseline = { cash = 1500 } } },
        })

        if added then
            local extra = {}
            for _, line in ipairs(s.storage.readEscrow(c.id)) do
                if line.amount == 1500 and line.state == CB.ESCROW_STATE.HELD then
                    extra[#extra + 1] = line.id
                end
            end
            if #extra > 0 then
                s.contracts.withdrawReward(f.creator, c.id, extra)
                sameHolding(before, holding(s, c.id),
                    'putting something in and taking it out again left the '
                    .. 'contract holding something different')
            end
        end
    end)

    --- A refusal must cost nothing. Whatever the world held before a
    --- rejected contract, it holds after — and this is true whichever rule
    --- did the rejecting.
    it('leave the world untouched when a placement is refused', function()
        local REFUSALS = {
            { 'a reward of nothing', { reward = { baseline = {} } } },
            { 'more than the ceiling', { reward = { baseline = { cash = 99999999 } } } },
            { 'a target that does not exist', { targetCid = 'NOBODY99',
                reward = { baseline = { cash = 1000 } } } },
            { 'themselves', { targetCid = 'CREATOR1',
                reward = { baseline = { cash = 1000 } } } },
            { 'a reason full of links', { reason = 'https://example.com pay me',
                reward = { baseline = { cash = 1000 } } } },
        }

        for _, case in ipairs(REFUSALS) do
            local s, f = seeded()
            local before = Env.players[1].PlayerData.money.cash
                + Env.players[1].PlayerData.money.bank
            local c = place(s, f, case[2])
            falsy(c, 'the fixture is wrong: ' .. case[1] .. ' was accepted')
            local after = Env.players[1].PlayerData.money.cash
                + Env.players[1].PlayerData.money.bank
            eq(after, before,
                'a contract refused for ' .. case[1] .. ' still cost the creator money')
            eq(#s.storage.allContracts(), 0,
                'a contract refused for ' .. case[1] .. ' was written anyway')
        end
    end)
end)

describe('changing an input moves the answer the matching way', function()
    --- The buyout ceiling scales with the escrow it is a multiple of.
    ---
    --- Monotonicity alone was too weak to be worth having: quartering the
    --- ceiling above a threshold still leaves the prices in order, so a
    --- relation that only asks "never lower" waves it through. Proportion
    --- is the actual rule — the ceiling is a multiple, so doubling the
    --- stake doubles it — and it is still a relation rather than a figure:
    --- it holds whatever the operator sets the multiplier to.
    it('prices a buyout in proportion to the escrow', function()
        local ratios = {}
        for _, stake in ipairs({ 1000, 5000, 20000, 60000 }) do
            local s, f = seeded()
            Env.players[1].PlayerData.money.bank = 1000000
            local c = place(s, f, {
                reward = { baseline = { cash = stake } },
                -- Far above any ceiling, so what comes back IS the ceiling.
                bailoutAmount = 10000000,
            })
            truthy(c, 'the fixture has to place at a stake of ' .. stake)
            local price = s.storage.readContract(c.id).bailout_amount

            -- The absolute cap would flatten the ratio legitimately, so
            -- only stakes below it are compared.
            if price < (Config.Bailout.AbsoluteMax or math.huge) then
                ratios[#ratios + 1] = { stake = stake, price = price,
                                        ratio = price / stake }
            end
        end

        truthy(#ratios >= 3, 'not enough stakes under the absolute cap to compare')
        for i = 2, #ratios do
            local a, b = ratios[1], ratios[i]
            truthy(math.abs(a.ratio - b.ratio) < 0.01,
                ('%d of escrow priced its buyout at %d, and %d priced it at %d '
                 .. '— a ceiling that is a multiple of the escrow has to stay '
                 .. 'the same multiple'):format(a.stake, a.price, b.stake, b.price))
        end
    end)

    --- And the weaker relation as well, because it holds even where the
    --- absolute cap flattens the proportion.
    it('never prices a buyout lower on a contract worth more', function()
        local previous, previousStake
        for _, stake in ipairs({ 1000, 5000, 20000, 60000, 400000 }) do
            local s, f = seeded()
            Env.players[1].PlayerData.money.bank = 10000000
            Env.players[1].PlayerData.money.cash = 10000000
            local c = place(s, f, {
                reward = { baseline = { cash = stake } },
                bailoutAmount = 10000000,
            })
            if c then
                local price = s.storage.readContract(c.id).bailout_amount
                if previous then
                    truthy(price >= previous,
                        ('a contract holding %d priced its buyout at %d, and one '
                         .. 'holding %d priced it at %d — more escrow cannot buy '
                         .. 'a cheaper way out'):format(stake, price, previousStake, previous))
                end
                previous, previousStake = price, stake
            end
        end
        truthy(previous, 'no stake placed at all, so nothing was compared')
    end)

    --- A longer deadline is never a shorter one. Extending twice must not
    --- land earlier than extending once.
    it('never shortens a deadline by extending it', function()
        local s, f = seeded()
        local c = place(s, f, { reward = { baseline = { cash = 5000 } } })
        truthy(c)

        local start = s.storage.readContract(c.id).deadline_at
        s.amendments.improve(f.creator, c.id, CB.AMENDMENT.EXTEND_DEADLINE, { seconds = 600 })
        local once = s.storage.readContract(c.id).deadline_at
        s.amendments.improve(f.creator, c.id, CB.AMENDMENT.EXTEND_DEADLINE, { seconds = 600 })
        local twice = s.storage.readContract(c.id).deadline_at

        truthy(once >= start, 'extending moved the deadline backwards')
        truthy(twice >= once, 'extending twice landed before extending once')
    end)

    --- Buying informant data twice must never be cheaper than buying it
    --- once: each purchase costs, and the second cannot refund the first.
    it('never leaves a buyer richer for buying twice', function()
        local s, f = seeded()
        local c = place(s, f, { mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } } })
        s.contracts.accept(f.hunter, c.id, false)

        Env.players[1].PlayerData.money.bank = 500000
        local start = Env.players[1].PlayerData.money.bank
        s.informant.buy(f.creator, c.id)
        local afterOne = Env.players[1].PlayerData.money.bank
        s.informant.buy(f.creator, c.id)
        local afterTwo = Env.players[1].PlayerData.money.bank

        truthy(afterOne <= start, 'the first purchase paid the buyer')
        truthy(afterTwo <= afterOne, 'the second purchase paid the buyer')
    end)
end)
