--- Three rules the specification states plainly and nothing measures.
---
--- Read against docs/bounty-hunter-app-spec.md. Each of these is a numbered
--- claim in that document, implemented in the resource, and never exercised:
--- line coverage over the whole server suite shows the branch that enforces
--- it never runs. A rule nothing runs is a rule the next refactor deletes.

--------------------------------------------------------------------------
-- §14.23 — "Armed countdowns are capped server-wide by
-- Config.Kidnap.MaxConcurrentCountdowns; over the cap the server refuses to
-- arm new ones and tells the hunter, and never sheds an in-progress
-- countdown, because §7.4 promises a reset is never silent."
--
-- kidnap_spec has a test with this name. It sets the cap to 1, arms one
-- countdown, creates a second contract — and never arms anything on it,
-- never accepts it with a second hunter, and then asserts activeCount() is
-- still 1. That assertion holds with the cap ripped out, because nothing
-- ever asked for a second countdown. The cap's refusal branch has never
-- executed in this suite.
--------------------------------------------------------------------------

local AT = { x = 200.0, y = 200.0, z = 30.0 }

--- Two contracts on one target, one hunter each, everyone standing together
--- and the target cuffed: two deliveries that both satisfy every arming
--- condition except the cap.
local function twoDeliveries()
    local s = newStack()
    local f = fixture(s)

    local first = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt',
        reward = { baseline = { cash = 5000 } },
    })
    local second = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Also unpaid',
        reward = { baseline = { cash = 4000 } },
    })

    Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd' })
    s.contracts.accept(f.hunter, first.id, false)
    s.contracts.accept(s.identity.resolve(4), second.id, false)

    for _, src in ipairs({ 1, 2, 3, 4 }) do
        Env.players[src]._coords = { x = AT.x, y = AT.y, z = AT.z }
    end
    Env.players[2].PlayerData.metadata.ishandcuffed = true

    return s, f, first, second
end

describe('the countdown cap (§14.23)', function()
    it('arms both handovers when the cap has room for them', function()
        -- The control. Without it a refusal below proves only that the
        -- second delivery was unarmable for some other reason.
        local s, _, first, second = twoDeliveries()
        truthy(s.kidnap.arm(first.id, 'HUNTER01'), 'first handover')
        truthy(s.kidnap.arm(second.id, 'HUNTER02'), 'second handover')
        eq(s.kidnap.activeCount(), 2, 'both countdowns running')
    end)

    it('refuses to arm past the cap, and says so', function()
        local s, _, first, second = twoDeliveries()
        -- The stack is opened first: newStack() resets the whole config, so
        -- opening one inside withConfig would discard the cap set here.
        withConfig({ { Config.Kidnap, 'MaxConcurrentCountdowns', 1 } }, function()
            truthy(s.kidnap.arm(first.id, 'HUNTER01'), 'the first one arms')

            local armed, err = s.kidnap.arm(second.id, 'HUNTER02')
            falsy(armed, 'the cap must refuse the second countdown')
            eq(err, CB.ERR.LIMIT_REACHED, 'and the hunter is told which wall they hit')
        end)
    end)

    it('never sheds the delivery already in progress to make room', function()
        local s, _, first, second = twoDeliveries()
        withConfig({ { Config.Kidnap, 'MaxConcurrentCountdowns', 1 } }, function()
            s.kidnap.arm(first.id, 'HUNTER01')
            s.kidnap.tick(Config.Kidnap.TickMs)
            s.kidnap.arm(second.id, 'HUNTER02')

            eq(s.kidnap.activeCount(), 1, 'exactly the one that was already running')
            truthy(s.kidnap.progress(first.id, 'HUNTER01'),
                'the hunter halfway through a handover keeps it')
        end)

        -- And it really was the first one: it still pays out.
        local done = {}
        for _ = 1, Config.Kidnap.CountdownSeconds do
            for _, d in ipairs(s.kidnap.tick(Config.Kidnap.TickMs)) do done[#done + 1] = d end
        end
        eq(#done, 1, 'the surviving delivery completes')
        eq(done[1].contractId, first.id, 'and it is the one that was armed first')
    end)
end)

--------------------------------------------------------------------------
-- §14.29 — "total purchases per contract are capped by
-- Config.Informant.MaxPurchasesPerContract, and is refused before payment".
--
-- The sticky reveal and the seeded selection are both tested. The ceiling
-- on how many times one buyer may go back to the well is not, and the
-- branch that enforces it has never run. It is the one that decides whether
-- an unbounded 25,000 a head walks the whole hunter roster.
--------------------------------------------------------------------------

describe('the informant purchase ceiling (§14.29)', function()
    local function contested()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } },
        })
        s.contracts.accept(f.hunter, c.id, true)
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd' })
        s.contracts.accept(s.identity.resolve(4), c.id, true)
        return s, f, c
    end

    --- Past the reroll lock, so each call is a fresh purchase rather than
    --- the cached reveal handed back for free.
    local function pastTheLock()
        Env.time = Env.time + (Config.Informant.RerollLockMinutes * 60) + 1
    end

    it('refuses the purchase past the cap, and charges nothing for the refusal', function()
        local s, f, c = contested()
        withConfig({ { Config.Informant, 'RequireProximity', false } }, function()
            local cost = Config.Informant.Cost

            for i = 1, Config.Informant.MaxPurchasesPerContract do
                local bank = Env.players[1].PlayerData.money.bank
                local ok = s.informant.buy(f.creator, c.id)
                truthy(ok, 'purchase ' .. i .. ' is inside the ceiling')
                eq(Env.players[1].PlayerData.money.bank, bank - cost,
                    'and is paid for')
                pastTheLock()
            end

            local bank = Env.players[1].PlayerData.money.bank
            local ok, err, data = s.informant.buy(f.creator, c.id)
            falsy(ok, 'one purchase past the ceiling must be refused')
            eq(err, CB.ERR.LIMIT_REACHED)
            falsy(data, 'and reveals nobody')
            eq(Env.players[1].PlayerData.money.bank, bank,
                'refused before payment: a wall you are charged for is a sale')
        end)
    end)
end)

--------------------------------------------------------------------------
-- §9.3 / §14.12 — "The §9.3 retry is per line item and decrements before it
-- gives... if the give returns false, restore that single line and stop."
--
-- Release-time refusal is covered: the line goes back to held and is
-- queued. The retry's own refusal is not. That path claims the line into
-- `releasing` first, and if the give fails and nothing puts it back, the
-- line is stranded in a state no code path reads: the property is gone from
-- the player it was taken from, owed to somebody it will never reach again,
-- and no later login retries it. The store monitor does not see it either —
-- it only flags a mid-release line on a *closed* contract.
--------------------------------------------------------------------------

describe('a retry that still cannot deliver (§9.3)', function()
    local function owedAnItem()
        local s = newStack()
        local f = fixture(s)
        local lines = s.escrow.validate(f.creator, {
            baseline = { cash = 5000, items = { { name = 'lockpick', count = 2 } } },
        })
        s.escrow.take(f.creator, 'ct1', lines)

        -- Full bag: the cash settles, the item cannot be handed over.
        Env.players[3]._inventoryFull = true
        s.escrow.release('ct1', 'HUNTER01', CB.PORTION.BASELINE, 'payout_baseline')
        return s, f
    end

    local function itemLine(s)
        for _, line in ipairs(s.storage.readEscrow('ct1')) do
            if line.source == CB.SOURCE.ITEM then return line end
        end
    end

    it('leaves the line held and queued when the bag is still full', function()
        local s = owedAnItem()
        eq(s.escrow.retryPending('HUNTER01'), 0, 'nothing could be delivered')

        local line = itemLine(s)
        eq(line.state, CB.ESCROW_STATE.HELD,
            'a line that could not be given must not sit in releasing forever')
        eq(line.owed_to, 'HUNTER01', 'still owed to the hunter who earned it')
        eq(#s.storage.readPending('HUNTER01'), 1, 'and still queued for the next login')
    end)

    it('delivers it on a later login, once there is room', function()
        -- The consequence of the line above, and what makes it worth
        -- asserting: a stranded line is not delivered by any later attempt.
        local s = owedAnItem()
        s.escrow.retryPending('HUNTER01')

        Env.players[3]._inventoryFull = false
        eq(s.escrow.retryPending('HUNTER01'), 1, 'the second login gets it')

        local carried = 0
        for _, slot in ipairs(Env.players[3]._inventory) do
            if slot.name == 'lockpick' then carried = carried + slot.count end
        end
        eq(carried, 2, 'the whole line, once')
        eq(itemLine(s).state, CB.ESCROW_STATE.SETTLED, 'and it is settled')
    end)
end)
