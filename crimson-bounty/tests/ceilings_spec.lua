--- The ceilings a contract answers to, and the figures a player is shown
--- before they agree to one.
---
--- Every rule here bounds what one player can do to another, or to the
--- database, and every one of them had a way round it that the rest of the
--- suite could not see: none of them moves money incorrectly, so
--- conservation stays green while a contract grows to eight hundred escrow
--- rows, a $1,000 job carries a $1,000,000 stake, and a hunter is debited
--- for a figure that was never on their screen.

--- Escrow rows a contract is holding, counted the way the ceiling counts
--- them: settled lines are not held, and neither are hunters' stakes.
local function heldLines(s, contractId)
    local n = 0
    for _, line in ipairs(s.storage.readEscrow(contractId)) do
        if line.state ~= CB.ESCROW_STATE.SETTLED and line.portion ~= CB.PORTION.STAKE then
            n = n + 1
        end
    end
    return n
end

describe('the escrow line ceiling', function()
    --- Config.Limits.MaxEscrowLines exists to bound what one contract can
    --- cost the database. Amendments.addEscrow counts what a contract holds
    --- and refuses at the ceiling; the raise_bonus branch built its lines
    --- itself and checked only their VALUE, and a bonus top-up appends one
    --- fresh derived line per unsettled money baseline every time it runs.
    --- So a creator could walk one contract to hundreds of rows a
    --- percentage point at a time, for the price of the difference, while
    --- the total it was worth never moved.
    it('holds when the bonus is raised, not only when escrow is added', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { slots = {
                { baseline = { cash = 100, bank = 100 } },
                { baseline = { cash = 100, bank = 100 } },
            } },
        })
        truthy(c, 'the fixture contract must exist')

        -- Every raise the server will take, one point at a time.
        local accepted = 0
        for percent = 1, Config.Bonus.maxPercent do
            local ok = s.amendments.improve(f.creator, c.id,
                CB.AMENDMENT.RAISE_BONUS, { percent = percent })
            if ok then accepted = accepted + 1 end
        end

        truthy(accepted > 0, 'at least some raises must be legitimate')
        truthy(heldLines(s, c.id) <= Config.Limits.MaxEscrowLines,
            ('one contract holds %d escrow lines against a ceiling of %d')
                :format(heldLines(s, c.id), Config.Limits.MaxEscrowLines))
    end)

    it('still lets a bonus be raised below the ceiling', function()
        -- The fix must refuse the run-away, not the feature. Of all the
        -- amendments this is the one that applies with no approval, on the
        -- stated grounds that it can only benefit the hunter.
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 1000 } },
        })
        local ok, err = s.amendments.improve(f.creator, c.id,
            CB.AMENDMENT.RAISE_BONUS, { percent = 50 })
        truthy(ok, tostring(err))
        eq(s.storage.readContract(c.id).bonus_percent, 50)
    end)
end)

describe('a buyout premium with nowhere to go', function()
    --- Util.mintId refuses when every id the store's sequence offers is
    --- already in use — the documented case of two server instances sharing
    --- one database. Bailout.owe returns nil there, and the settle path
    --- discarded it: the contract closed, the creator was never credited,
    --- no owed line existed for them to collect on login, and the target's
    --- already-spent premium simply stopped existing.
    ---
    --- It is the only one of the three Util.mintId call sites with a
    --- player's money in flight. Contracts.create refuses before it charges
    --- anyone; Contracts.accept releases the stake.
    local function exhausted(s)
        -- Every id on offer is taken.
        s.storage.readEscrowLine = function() return { id = 'owe00000001' } end
    end

    local function worth(s)
        local total = 0
        for _, src in ipairs({ 1, 2, 3 }) do
            local p = Env.players[src]
            if p then
                total = total + p.PlayerData.money.cash + p.PlayerData.money.bank
            end
        end
        for _, c in ipairs(s.storage.allContracts()) do
            for _, line in ipairs(s.storage.readEscrow(c.id)) do
                if CB.MONEY_ACCOUNTS[line.source]
                    and line.state ~= CB.ESCROW_STATE.SETTLED then
                    total = total + (line.amount or 0)
                end
            end
            total = total + (c.bailout_paid_amount or 0)
        end
        return total
    end

    local function bought(prepare)
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 10000 } }, bailoutAmount = 20000,
        })
        truthy(c)
        -- The creator is offline, so the premium has to be written as an
        -- owed line rather than handed over.
        Env.removePlayer(1)
        local before = worth(s)
        if prepare then prepare(s) end
        s.bailout.buy(f.target, c.id)
        return s, before, worth(s)
    end

    it('conserves the premium when a line can be minted', function()
        local _, before, after = bought(nil)
        eq(after, before, 'the control: nothing is created or destroyed')
    end)

    it('does not destroy the premium when no owed line can be minted', function()
        local _, before, after = bought(exhausted)
        eq(after, before,
            'the target paid the premium and it stopped existing: expected '
            .. tostring(before) .. ', got ' .. tostring(after))
    end)
end)

describe('an acceptance that fails on the stake', function()
    --- The exclusive branch put the contract back to ACTIVE on both stake
    --- failure paths. The competitive branch performs the same ACTIVE ->
    --- ACCEPTED transition and had no revert, so any player with an empty
    --- account could flip a competitive contract's advertised state for
    --- every viewer of the board, with no hunter on it, by tapping Accept.
    local function unaffordable(mode)
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = mode,
            reward = { baseline = { cash = 50000 } }, penaltyAmount = 90000,
        })
        truthy(c, 'the fixture contract must exist')
        truthy((c.penalty_amount or 0) > 0, 'the stake must survive the clamp')

        Env.players[3].PlayerData.money.bank = 0
        Env.players[3].PlayerData.money.cash = 0

        local ok, err = s.contracts.accept(f.hunter, c.id, false)
        return s, c, ok, err
    end

    it('puts a competitive contract back on the board', function()
        local s, c, ok, err = unaffordable(CB.MODE.COMPETITIVE)
        falsy(ok, 'a hunter who cannot cover the stake cannot accept')
        eq(err, CB.ERR.INSUFFICIENT)
        eq(s.storage.readContract(c.id).state, CB.STATE.ACTIVE,
            'the board must not advertise a contract as taken by nobody')
        eq(#s.storage.readHunters(c.id), 0)
    end)

    it('puts an exclusive contract back on the board', function()
        local s, c, ok = unaffordable(CB.MODE.EXCLUSIVE)
        falsy(ok)
        eq(s.storage.readContract(c.id).state, CB.STATE.ACTIVE)
    end)

    it('leaves a contract another hunter already took alone', function()
        -- Only the call that advanced the contract may put it back. A
        -- competitive contract somebody else is already working is theirs.
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 50000 } }, penaltyAmount = 90000,
        })
        Env.players[3].PlayerData.money.bank = 100000
        truthy(s.contracts.accept(f.hunter, c.id, false), 'the first hunter takes it')

        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd',
            cash = 0, bank = 0, firstname = 'Bly', lastname = 'Kade' })
        local ok = s.contracts.accept(s.identity.resolve(4), c.id, false)
        falsy(ok, 'the second cannot cover the stake')

        eq(s.storage.readContract(c.id).state, CB.STATE.ACCEPTED,
            'and must not have taken the first hunter off the board with them')
        eq(#s.storage.readHunters(c.id), 1)
    end)
end)

describe('the failure stake', function()
    --- §14.18: clamped server-side at creation to
    --- min(Config.Penalty.MaxAmount, MaxFractionOfEscrow x escrow value),
    --- silently. It was bounded only by Config.MaxContractValue, so a
    --- contract advertising a $1,000 reward could carry a $1,000,000 stake —
    --- a transfer rail of exactly the kind Contracts.clampBailout exists to
    --- close on the other side.
    it('cannot exceed what the contract is worth', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 1000 } },
            penaltyAmount = Config.MaxContractValue,
        })
        truthy(c)

        local ceiling = math.min(Config.Penalty.MaxAmount,
            math.floor(1000 * Config.Penalty.MaxFractionOfEscrow))
        eq(c.penalty_amount, ceiling,
            'a $1,000 contract must not be able to ask for a $1,000,000 stake')
    end)

    it('cannot exceed the absolute ceiling either', function()
        local s = newStack()
        local f = fixture(s)
        -- Escrowed well past the point where the fraction stops binding,
        -- so the absolute ceiling is the one being tested.
        local escrow = Config.Penalty.MaxAmount * 2
        Env.players[1].PlayerData.money.cash = escrow * 4
        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = escrow } },
            penaltyAmount = Config.MaxContractValue,
        })
        truthy(c, tostring(err))
        truthy(c.penalty_amount <= Config.Penalty.MaxAmount,
            ('the absolute ceiling is %d, the stake is %d')
                :format(Config.Penalty.MaxAmount, c.penalty_amount))
    end)

    it('keeps a figure that is already within the ceilings', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 10000 } }, penaltyAmount = 5000,
        })
        eq(c.penalty_amount, 5000, 'clamping must not reprice a legitimate stake')
    end)

    it('is clamped when it is raised by amendment too', function()
        -- raise_penalty is only allowed on an unheld contract, so the figure
        -- it leaves is what the next hunter is asked to put up. An
        -- amendment that skipped the clamp would be the way back to it.
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 1000 } }, penaltyAmount = 100,
        })
        -- Raising a stake is not an improvement, so it goes through the
        -- proposal path. With no hunter on the contract the creator is the
        -- only participant, so their own approval carries it — which is the
        -- only state raise_penalty is allowed in anyway: a stake may not be
        -- raised over a hunter who already put up the old one.
        local proposal, err = s.amendments.propose(f.creator, c.id,
            CB.AMENDMENT.RAISE_PENALTY, { amount = Config.MaxContractValue })
        truthy(proposal, tostring(err))
        local applied, applyErr = s.amendments.respond(f.creator, proposal.id, true)
        truthy(applied, tostring(applyErr))

        local ceiling = math.min(Config.Penalty.MaxAmount,
            math.floor(1000 * Config.Penalty.MaxFractionOfEscrow))
        eq(s.storage.readContract(c.id).penalty_amount, ceiling)
    end)

    --- The clamp holds at the moment the figure is set, and withdrawReward
    --- is the one path that takes escrow back out afterwards. The bailout
    --- premium is re-clamped there for exactly this reason, with a comment
    --- saying so; the stake was not, so the same door was open on the other
    --- side: fund the contract, price the stake at the ceiling that funding
    --- buys, withdraw the funding, and every hunter who accepts afterwards
    --- is asked for a stake the contract can no longer justify.
    it('moves down when the escrow it is proportional to is withdrawn', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 40000, bank = 1000 } },
            penaltyAmount = 80000,
        })
        truthy(c)
        eq(c.penalty_amount, 80000, 'funded, the ceiling allows this')

        -- Nobody holds it, so the creator may take the cash back. The bank
        -- line stays, because a slot may not be emptied outright.
        local ids = {}
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.source == 'cash' then ids[#ids + 1] = line.id end
        end
        truthy(#ids > 0, 'the slot the creator is withdrawing must exist')
        local pulled, pullErr = s.contracts.withdrawReward(f.creator, c.id, ids)
        truthy(pulled, tostring(pullErr))

        local after = s.storage.readContract(c.id)
        local worth = s.escrow.moneyValue(c.id)
        truthy(after.penalty_amount <= math.floor(worth * Config.Penalty.MaxFractionOfEscrow),
            ('the contract is worth %d and still asks a hunter for %d')
                :format(worth, after.penalty_amount))
    end)

    --- withdrawReward is not the only path that takes escrow back out: the
    --- reduce_reward amendment releases a whole unclaimed slot and, until
    --- this test, re-clamped nothing at all. The comment on the bailout
    --- re-clamp says withdrawReward is "the one path", which was true when
    --- it was written.
    it('moves down when a slot is given back by amendment', function()
        -- On a store that hands back copies, the way a real database does.
        -- Amendments.apply writes the contract table it is holding at the
        -- end, so re-pricing before that write is undone by it — and on the
        -- in-process store the snapshot IS the stored row, so the wrong
        -- order looks correct there and only breaks on a live server.
        local s = newCopyingStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { slots = {
                { baseline = { cash = 1000 } },
                { baseline = { cash = 40000 } },
            } },
            penaltyAmount = 80000,
            bailoutAmount = 100000,
        })
        truthy(c)
        eq(c.penalty_amount, 80000, 'funded, the ceiling allows this')
        local pricedAt = c.bailout_amount
        truthy(pricedAt > 0)

        local proposal, err = s.amendments.propose(f.creator, c.id,
            CB.AMENDMENT.REDUCE_REWARD, { slot = 2 })
        truthy(proposal, tostring(err))
        local applied, applyErr = s.amendments.respond(f.creator, proposal.id, true)
        truthy(applied, tostring(applyErr))

        local after = s.storage.readContract(c.id)
        local worth = s.escrow.moneyValue(c.id)
        truthy(after.penalty_amount <= math.floor(worth * Config.Penalty.MaxFractionOfEscrow),
            ('the contract is worth %d and still asks a hunter for %d')
                :format(worth, after.penalty_amount))
        truthy(after.bailout_amount <= math.floor(worth * Config.Bailout.MaxMultiplier),
            ('the contract is worth %d and still prices the buyout at %d')
                :format(worth, after.bailout_amount))
    end)

    --- §3.6: "A hunter who cannot cover it cannot accept the contract, and
    --- is told so." §14.18: "The required stake is shown prominently on the
    --- listing before the accept button." The figure reached the creator
    --- alone, and acceptance debited it anyway.
    it('is on the listing a prospective hunter reads', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 10000 } }, penaltyAmount = 4000,
        })
        truthy(c)

        local board = s.projection.listing('HUNTER01', 1)
        local row
        for _, entry in ipairs(board.contracts) do
            if entry.id == c.id then row = entry end
        end
        truthy(row, 'the contract must be on the board for a prospective hunter')
        eq(row.penaltyAmount, 4000,
            'a hunter must not learn what accepting costs from their bank balance')
    end)

    it('is on the listing as zero when there is no stake', function()
        -- "No stake" and "not told" are different things, and the page has
        -- to be able to tell them apart.
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 10000 } },
        })
        local board = s.projection.listing('HUNTER01', 1)
        local row
        for _, entry in ipairs(board.contracts) do
            if entry.id == c.id then row = entry end
        end
        truthy(row)
        eq(row.penaltyAmount, 0)
    end)

    it('is what acceptance actually charges', function()
        -- The disclosed figure and the debited figure have to be the same
        -- number, or disclosure is theatre.
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 10000 } }, penaltyAmount = 4000,
        })
        local board = s.projection.listing('HUNTER01', 1)
        local shown
        for _, entry in ipairs(board.contracts) do
            if entry.id == c.id then shown = entry.penaltyAmount end
        end

        Env.players[3].PlayerData.money.bank = 50000
        truthy(s.contracts.accept(f.hunter, c.id, false))
        eq(Env.players[3].PlayerData.money.bank, 50000 - shown,
            'the stake taken must be the stake shown')
    end)
end)

--- What one board open costs the database.
---
--- These are counters, not timings: a wall clock on a laptop says nothing
--- about a live server, but the number of round trips a request makes is
--- the same everywhere, and on the mysql backend each one is an awaited
--- SELECT that yields.
describe('what opening the board costs', function()
    --- Wrap the store so every read is counted.
    local function counting(s)
        local counts = {}
        for name, fn in pairs(s.storage) do
            if type(fn) == 'function' and name:find('^read') or name == 'allContracts' then
                local wrapped = fn
                s.storage[name] = function(...)
                    counts[name] = (counts[name] or 0) + 1
                    return wrapped(...)
                end
            end
        end
        -- Every module holds its own reference to the store.
        s.escrow.init(s.storage, s.audit)
        s.projection.init({ storage = s.storage, identity = s.identity,
                            escrow = s.escrow, kidnap = s.kidnap,
                            mugshot = s.mugshot, progression = s.progression })
        return counts
    end

    --- A board with `count` contracts on it, each on its own target so the
    --- per-target limit is not what is being measured.
    local function boardWith(count)
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.cash = 100000000

        local made = {}
        withConfig({
            { Config.Limits, 'MaxActiveContractsPerCreator', count + 1 },
            { Config.Limits, 'MaxActiveContractsPerTarget', count + 1 },
        }, function()
            for i = 1, count do
                local targetCid = i == 1 and 'TARGET01' or ('TGT%05d'):format(i)
                if i > 1 then
                    Env.addPlayer({ source = 20 + i, citizenid = targetCid,
                        license = 'license:t' .. i, cash = 100, bank = 100,
                        firstname = 'Mark', lastname = 'Number' .. i })
                end
                local c, err = s.contracts.create(f.creator, {
                    targetCid = targetCid, reason = 'x',
                    reward = { baseline = { cash = 100 + i } },
                })
                truthy(c, 'contract ' .. i .. ': ' .. tostring(err))
                made[#made + 1] = c
            end
        end)
        return s, f, made
    end

    it('reads a contract escrow once per row, not once per figure on it', function()
        local s = boardWith(6)
        local counts = counting(s)
        s.projection.listing('HUNTER01', 1)

        eq(counts.readEscrow, 6,
            'six contracts on the board should be six escrow reads, and each '
            .. 'row asks what it is worth several times over: got '
            .. tostring(counts.readEscrow))
    end)

    it('asks the store for the caller\'s own contracts, not for all of them', function()
        -- Bailout.available is what /cleanse runs, for a player barred from
        -- the app entirely. It used to read and hydrate every contract the
        -- server has ever held and filter in Lua, while Projection.onMe
        -- asked the same question on an index.
        local s, f = boardWith(4)
        local counts = counting(s)
        s.bailout.available(f.target)

        falsy((counts.allContracts or 0) > 0,
            'the indexed lookup answers this exactly: got '
            .. tostring(counts.allContracts) .. ' full scans')
    end)

    it('does not scan the whole table to find a queued buyout', function()
        local s = boardWith(4)
        local counts = counting(s)
        s.bailout.processQueue()

        falsy((counts.allContracts or 0) > 0,
            'this runs on every maintenance tick and is almost always empty: '
            .. 'got ' .. tostring(counts.allContracts) .. ' full scans')
    end)

    it('still returns the same board with the reads memoised', function()
        -- The point of the memo is that nothing about the answer changes.
        local s = boardWith(3)
        local before = s.projection.listing('HUNTER01', 1)
        local after = s.escrow.cached(function()
            return s.projection.listing('HUNTER01', 1)
        end)

        eq(#after.contracts, #before.contracts)
        for i = 1, #before.contracts do
            eq(after.contracts[i].id, before.contracts[i].id)
            eq(after.contracts[i].reward.baseline, before.contracts[i].reward.baseline)
        end
    end)

    it('drops the memo when escrow changes underneath it', function()
        -- A cache that is sometimes right is worse than none.
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 1000 } },
        })

        s.escrow.cached(function()
            eq(s.escrow.moneyValue(c.id), 1000, 'read once, memoised')
            truthy(s.amendments.addEscrow(f.creator, c.id, { baseline = { cash = 500 } }))
            eq(s.escrow.moneyValue(c.id), 1500,
                'the memo must not survive a write through it')
        end)
    end)
end)
