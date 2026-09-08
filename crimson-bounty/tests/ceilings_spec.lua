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

    --- Disclosure that is not binding is disclosure with a race in it.
    ---
    --- §14.18: "acceptance is refused server-side unless the payload echoes
    --- back the current amount ... so acceptance without disclosure is
    --- structurally impossible and a creator-side edit invalidates in-flight
    --- accept dialogs rather than silently repricing them."
    it('refuses an acceptance that echoes a stake that has moved', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 10000 } }, penaltyAmount = 2000,
        })
        Env.players[3].PlayerData.money.bank = 50000

        -- The hunter is reading a board that says 2,000. The creator
        -- reprices while they read: allowed, because nobody holds it.
        local proposal = s.amendments.propose(f.creator, c.id,
            CB.AMENDMENT.RAISE_PENALTY, { amount = 15000 })
        truthy(proposal)
        truthy(s.amendments.respond(f.creator, proposal.id, true))
        eq(s.storage.readContract(c.id).penalty_amount, 15000)

        falsy(s.contracts.stakeWasDisclosed(s.storage.readContract(c.id), 2000),
            'the figure the page had is not the figure on the contract')
        eq(Env.players[3].PlayerData.money.bank, 50000,
            'and nothing has been taken from the hunter')
    end)

    it('accepts an acceptance that echoes the standing stake', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 10000 } }, penaltyAmount = 2000,
        })
        truthy(s.contracts.stakeWasDisclosed(s.storage.readContract(c.id), 2000))
        truthy(s.contracts.stakeWasDisclosed(s.storage.readContract(c.id), '2000'),
            'the wire carries numbers as text on some paths')
    end)

    it('asks nothing of a contract that carries no stake', function()
        -- A page that predates the echo must not be locked out of the
        -- contracts where there is nothing to disclose, which is most of
        -- them.
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 10000 } },
        })
        local standing = s.storage.readContract(c.id)
        eq(standing.penalty_amount, 0)
        truthy(s.contracts.stakeWasDisclosed(standing, nil),
            'nothing to disclose, so nothing to echo')
        truthy(s.contracts.stakeWasDisclosed(standing, 0))
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


--- Nothing charges a player more than they are holding.
---
--- Escrow.validate reads the live balance and refuses what a creator cannot
--- afford, and then Escrow.take does the debit — with RemoveMoney, whose
--- return this codebase has already learned twice is not an affordability
--- check: qbx_core ships dontAllowMinus as { 'cash', 'crypto' }, so a bank
--- debit succeeds on an empty account and reports success.
---
--- Between the check and the debit, money moves. The anonymity fee is
--- charged in exactly that window, out of the same account, which is how a
--- creator with exactly enough ends up funding a contract from an overdraft
--- they never agreed to.
describe('a charge that lands between the check and the debit', function()
    local function anonymousWithFee(bank, escrow, fee)
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = bank
        Env.players[1].PlayerData.money.cash = 0

        local created, err
        withConfig({
            { Config.Anonymity, 'CreatorFee', fee },
            { Config.Anonymity, 'FeeAccount', 'bank' },
        }, function()
            created, err = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', anonymous = true,
                reward = { baseline = { bank = escrow } },
            })
        end)
        return s, created, err
    end

    it('does not put a creator into an overdraft to fund a contract', function()
        -- Exactly enough for the escrow, and a fee on top. The old code
        -- checked 10000 against 10000, took the 500 fee, then debited 10000
        -- from 9500 and reported success: bank -500, contract funded.
        local s, created, err = anonymousWithFee(10000, 10000, 500)

        falsy(created, 'this contract is not affordable and must be refused')
        eq(err, CB.ERR.INSUFFICIENT)
        truthy(Env.players[1].PlayerData.money.bank >= 0,
            'a creator must never be charged more than they hold: bank is '
            .. tostring(Env.players[1].PlayerData.money.bank))
    end)

    it('gives the fee back when the escrow it preceded cannot be taken', function()
        local s = anonymousWithFee(10000, 10000, 500)
        eq(Env.players[1].PlayerData.money.bank, 10000,
            'refused means untouched, not part-charged')
    end)

    it('still places the contract when the creator can cover both', function()
        -- The fix must refuse the unaffordable one, not the feature.
        local s, created, err = anonymousWithFee(10500, 10000, 500)
        truthy(created, tostring(err))
        eq(Env.players[1].PlayerData.money.bank, 0,
            'ten thousand of escrow and five hundred of fee, and nothing over')
    end)

    it('refuses a debit the balance stopped covering, whoever moved it', function()
        -- The fee is only the reachable case. The rule is that the debit
        -- itself checks, so anything moving money in that window is covered
        -- — another resource, a concurrent purchase, a payout landing.
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 10000
        Env.players[1].PlayerData.money.cash = 0

        local lines, err = s.escrow.validate(f.creator, { baseline = { bank = 10000 } })
        truthy(lines, tostring(err))

        -- Something else spends it after the check and before the take.
        Env.players[1].PlayerData.money.bank = 4000

        local took, takeErr = s.escrow.take(f.creator, 'ct00000099', lines)
        falsy(took, 'the debit must re-check what is actually there')
        eq(takeErr, CB.ERR.INSUFFICIENT)
        eq(Env.players[1].PlayerData.money.bank, 4000,
            'and must leave the balance exactly as it found it')
    end)
end)


--- Putting back what was already taken, for every kind of thing.
---
--- Escrow.take confiscates line by line and undoes the lot on the first
--- failure, so a part-charged creator is not a reachable state (§3.5). Only
--- the money branch of that undo had ever run: line coverage showed the
--- dirty-money, item and weapon arms of rollback() never executed once in
--- the whole suite. A contract funded in goods is the normal case for this
--- resource, and the failure it protects against — a slot emptying between
--- the check and the debit — is the same one the money side just had a bug
--- in.
describe('an escrow take that fails partway through', function()
    local function heldItems(src, name)
        local total = 0
        for _, slot in ipairs(Env.players[src]._inventory or {}) do
            if slot.name == name then total = total + (slot.count or 0) end
        end
        return total
    end

    local function dirtyHeld(src)
        return heldItems(src, Config.Sources.dirty.item)
    end

    it('hands back an item stack when a later line cannot be taken', function()
        local s = newStack()
        local f = fixture(s)
        local before = heldItems(1, 'lockpick')
        truthy(before > 0, 'the fixture creator carries lockpicks')

        local ok, err = s.escrow.take(f.creator, 'ct00000091', {
            { portion = 'baseline', source = CB.SOURCE.ITEM, item = 'lockpick',
              quantity = 2, slot = 1 },
            { portion = 'baseline', source = CB.SOURCE.ITEM, item = 'nothing_like_this',
              quantity = 1, slot = 1 },
        })

        falsy(ok)
        eq(err, CB.ERR.INSUFFICIENT)
        eq(heldItems(1, 'lockpick'), before,
            'the lockpicks taken for the first line have to come back')
        eq(#s.storage.readEscrow('ct00000091'), 0, 'and nothing is stored')
    end)

    it('hands back dirty money when a later line cannot be taken', function()
        local s = newStack()
        local f = fixture(s)
        local before = dirtyHeld(1)
        truthy(before > 0, 'the fixture creator carries black money')

        local ok = s.escrow.take(f.creator, 'ct00000092', {
            { portion = 'baseline', source = 'dirty', amount = 5000, slot = 1 },
            { portion = 'baseline', source = CB.SOURCE.ITEM, item = 'nothing_like_this',
              quantity = 1, slot = 1 },
        })

        falsy(ok)
        eq(dirtyHeld(1), before, 'black money is an item, and it comes back too')
    end)

    it('hands back a weapon when a later line cannot be taken', function()
        local s = newStack()
        local f = fixture(s)
        local before = heldItems(1, 'WEAPON_PISTOL')
        truthy(before > 0, 'the fixture creator carries a pistol')

        local ok = s.escrow.take(f.creator, 'ct00000093', {
            { portion = 'baseline', source = CB.SOURCE.WEAPON, item = 'WEAPON_PISTOL',
              metadata = { serial = 'ABC123', ammo = 12 }, slot = 1 },
            { portion = 'baseline', source = 'cash', amount = 99999999, slot = 1 },
        })

        falsy(ok)
        eq(heldItems(1, 'WEAPON_PISTOL'), before, 'the weapon comes back')
    end)

    it('hands back money and goods together', function()
        local s = newStack()
        local f = fixture(s)
        local cash = Env.players[1].PlayerData.money.cash
        local picks = heldItems(1, 'lockpick')
        local dirty = dirtyHeld(1)

        local ok = s.escrow.take(f.creator, 'ct00000094', {
            { portion = 'baseline', source = 'cash', amount = 5000, slot = 1 },
            { portion = 'baseline', source = 'dirty', amount = 2500, slot = 1 },
            { portion = 'baseline', source = CB.SOURCE.ITEM, item = 'lockpick',
              quantity = 1, slot = 1 },
            { portion = 'baseline', source = CB.SOURCE.ITEM, item = 'nothing_like_this',
              quantity = 1, slot = 1 },
        })

        falsy(ok)
        eq(Env.players[1].PlayerData.money.cash, cash)
        eq(dirtyHeld(1), dirty)
        eq(heldItems(1, 'lockpick'), picks)
    end)

    --- The end of the line: there is nothing left to undo and no escrow
    --- record to hold the property in, so a give-back that fails has
    --- genuinely cost the creator something. The audit row is what tells
    --- staff exactly what to return by hand, and to whom.
    it('names what it could not give back when the pockets are full', function()
        local s = newStack()
        local f = fixture(s)

        local taken = false
        local realAdd = exports.ox_inventory.AddItem
        exports.ox_inventory.AddItem = function(...)
            taken = true
            return false
        end

        local ok = pcall(function()
            s.escrow.take(f.creator, 'ct00000095', {
                { portion = 'baseline', source = CB.SOURCE.ITEM, item = 'lockpick',
                  quantity = 1, slot = 1 },
                { portion = 'baseline', source = CB.SOURCE.ITEM, item = 'nothing_like_this',
                  quantity = 1, slot = 1 },
            })
        end)
        exports.ox_inventory.AddItem = realAdd
        truthy(ok, 'a failed rollback must not throw')
        truthy(taken, 'the rollback must have tried to give it back')

        s.audit.flush()
        local named
        for _, row in ipairs(s.storage.readAudit()) do
            if row.action == 'escrow_rollback_failed' then named = row end
        end
        truthy(named, 'a give-back that failed has to be recorded, or nobody '
            .. 'can return it by hand')
        truthy(tostring(named.detail and named.detail.item or ''):find('lockpick', 1, true),
            'and it has to say what: ' .. tostring(named.detail and named.detail.item))
    end)
end)


--- A refusal that names the rule it is about.
---
--- LIMIT_REACHED covered three unrelated rules: a creator holding too many
--- contracts, a hunter holding too many, and a contract already carrying as
--- many operatives as it allows. The app words it as "You are holding too
--- many contracts", which for the third is not merely vague — it is false.
--- The hunter may hold none. It sends them off to cancel their own work to
--- fix somebody else's contract being popular.
---
--- The same split has been made twice already here: the six reasons a
--- target cannot be listed, and the informant's own limit.
describe('a competitive contract that is full', function()
    local function crowded()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c)

        -- Fill it to the cap with hunters who hold nothing else.
        local cap = Config.Limits.MaxHuntersPerContract
        for i = 1, cap do
            local cid = ('HNT%05d'):format(i)
            Env.addPlayer({ source = 50 + i, citizenid = cid,
                license = 'license:h' .. i, cash = 5000, bank = 5000,
                firstname = 'Hunter', lastname = 'Number' .. i })
            truthy(s.contracts.accept(s.identity.resolve(50 + i), c.id, false),
                'hunter ' .. i .. ' of ' .. cap)
        end
        return s, f, c, cap
    end

    it('refuses one more, under its own name', function()
        local s, f, c = crowded()
        -- Somebody holding no contracts at all.
        Env.addPlayer({ source = 90, citizenid = 'FRESH001', license = 'license:z',
            cash = 5000, bank = 5000, firstname = 'Wes', lastname = 'New' })

        local ok, err = s.contracts.accept(s.identity.resolve(90), c.id, false)
        falsy(ok)
        eq(err, CB.ERR.CONTRACT_FULL,
            'this hunter holds nothing; telling them they hold too much is a '
            .. 'refusal about the wrong player')
    end)

    it('still says too many when the hunter really does hold too many', function()
        -- The other rule must keep its own answer, or the split has just
        -- moved the confusion.
        local s = newStack()
        local f = fixture(s)
        local held = {}
        withConfig({
            { Config.Limits, 'MaxActiveContractsPerCreator', 20 },
            { Config.Limits, 'MaxActiveContractsPerTarget', 20 },
        }, function()
            for i = 1, Config.Limits.MaxAcceptedPerHunter + 1 do
                local targetCid = ('TG%06d'):format(i)
                Env.addPlayer({ source = 60 + i, citizenid = targetCid,
                    license = 'license:g' .. i, cash = 10, bank = 10,
                    firstname = 'Mark', lastname = 'Number' .. i })
                local c = s.contracts.create(f.creator, {
                    targetCid = targetCid, reason = 'x', mode = CB.MODE.COMPETITIVE,
                    reward = { baseline = { cash = 1000 } },
                })
                truthy(c, 'contract ' .. i)
                held[#held + 1] = c
            end
        end)

        local last
        for i = 1, #held do
            local ok, err = s.contracts.accept(f.hunter, held[i].id, false)
            if not ok then last = err end
        end
        eq(last, CB.ERR.LIMIT_REACHED,
            'a hunter who really is holding too many keeps that answer')
    end)

    it('shows the count against the cap before the tap', function()
        local s, f, c, cap = crowded()
        local board = s.projection.listing('FRESH001', 1)
        local row
        for _, entry in ipairs(board.contracts) do
            if entry.id == c.id then row = entry end
        end
        truthy(row, 'the contract is on the board')
        eq(row.huntersActive, cap)
        eq(row.huntersMax, cap,
            'the cap is already sent; the page just never read it')
    end)
end)
