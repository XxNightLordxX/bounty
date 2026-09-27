--- Bugs found by walking whole player journeys rather than single calls.
---
--- Each of these needs several steps in order before it appears, which is why
--- no per-module spec had caught them: every individual call does what it
--- says, and the fault is in what the sequence leaves behind.

describe('giving a later collection back by agreement', function()
    --- A collection the creator took back stayed on sale, worth nothing.
    ---
    --- reduce_reward releases the named slot's escrow and left
    --- contract.payout_slots where it was. So the emptied collection was still
    --- one the contract sold: next_slot walks onto it, the board shows the
    --- contract at nothing for the current collection, and a hunter who
    --- eliminates the target for it is paid out of an empty slot.
    ---
    --- The app's own dialog already promised otherwise: "Collection N of M
    --- goes back to the client. M-1 would remain."
    local function twoCollections()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        Env.players[3].PlayerData.money.bank = 400000

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { cash = 1000 } },
                                 { baseline = { cash = 40000 } } } },
        })
        truthy(c, 'a contract with two collections')
        eq(s.storage.readContract(c.id).payout_slots, 2)
        truthy(s.contracts.accept(f.hunter, c.id), 'a hunter')
        return s, f, c
    end

    it('leaves the contract with one collection fewer', function()
        local s, f, c = twoCollections()

        local proposal = s.amendments.propose(f.creator, c.id,
            CB.AMENDMENT.REDUCE_REWARD, { slot = 2 })
        truthy(proposal, 'propose giving collection 2 back')
        truthy(s.amendments.respond(f.hunter, proposal.id, true), 'agreed')

        eq(s.storage.readContract(c.id).payout_slots, 1,
            'the collection was emptied and left on sale: next_slot walks onto '
            .. 'it, the board shows the contract at nothing, and a hunter who '
            .. 'kills the target for it is paid out of an empty slot')
    end)

    it('does not pay a hunter nothing for a real elimination', function()
        local s, f, c = twoCollections()
        local proposal = s.amendments.propose(f.creator, c.id,
            CB.AMENDMENT.REDUCE_REWARD, { slot = 2 })
        truthy(proposal)
        truthy(s.amendments.respond(f.hunter, proposal.id, true))

        -- Collection 1 pays out and the contract should close, because there
        -- is no second collection any more.
        local before = Env.players[3].PlayerData.money.cash
                     + Env.players[3].PlayerData.money.bank
        local ok = s.contracts.claimSlot(c.id, f.hunter.cid,
            CB.FULFILMENT.ELIMINATION, {})
        truthy(ok, 'the first collection is real and should pay')
        local after = Env.players[3].PlayerData.money.cash
                    + Env.players[3].PlayerData.money.bank
        truthy(after > before, 'and it paid something')

        eq(s.storage.readContract(c.id).state, CB.STATE.COMPLETED,
            'with the given-back collection gone, one elimination finishes the '
            .. 'contract rather than leaving an empty slot to be worked for')
    end)

    it('still refuses to give back the collection being competed for', function()
        -- The guard the fix must not have widened. It bites at apply time
        -- rather than at propose time: Amendments.sanitize validates the shape
        -- of a payload and has no contract to check a slot bound against, so
        -- the proposal is made and refused when it is agreed.
        --
        -- That is a real wart — both parties can negotiate something that can
        -- never succeed, and the app says "Waiting on the other party" about
        -- it — but it is a separate concern from the money the slot count was
        -- losing, and apply is the authority either way. Asserted here as what
        -- it actually is rather than as what would be nicer.
        local s, f, c = twoCollections()
        local proposal = s.amendments.propose(f.creator, c.id,
            CB.AMENDMENT.REDUCE_REWARD, { slot = 1 })
        truthy(proposal, 'the proposal is made, un-validated against the slots')

        local ok, err = s.amendments.respond(f.hunter, proposal.id, true)
        falsy(ok, 'the live collection is not the creator\'s to take back')
        eq(err, CB.ERR.INVALID_INPUT)
        eq(s.storage.readContract(c.id).payout_slots, 2,
            'and the count is untouched by a refused reduction')
    end)

    it('refuses to take one out of the middle', function()
        -- The slots are a sequence next_slot walks, so removing a middle one
        -- would renumber every slot after it and orphan the escrow filed
        -- against their old numbers.
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        Env.players[3].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { cash = 1000 } },
                                 { baseline = { cash = 2000 } },
                                 { baseline = { cash = 3000 } } } },
        })
        truthy(c, 'three collections')
        truthy(s.contracts.accept(f.hunter, c.id))

        local proposal = s.amendments.propose(f.creator, c.id,
            CB.AMENDMENT.REDUCE_REWARD, { slot = 2 })
        truthy(proposal)
        local ok, err = s.amendments.respond(f.hunter, proposal.id, true)
        falsy(ok, 'the middle one is not removable')
        eq(err, CB.ERR.INVALID_INPUT)
        eq(s.storage.readContract(c.id).payout_slots, 3)

        -- The last one is.
        local last = s.amendments.propose(f.creator, c.id,
            CB.AMENDMENT.REDUCE_REWARD, { slot = 3 })
        truthy(last)
        truthy(s.amendments.respond(f.hunter, last.id, true))
        eq(s.storage.readContract(c.id).payout_slots, 2)
    end)
end)

describe('buying informant data on a contract that has closed', function()
    --- The one purchase in this resource that is deliberately never refunded.
    ---
    --- An empty result costs the premium on purpose (§14.29): a refund would
    --- turn the fee into a free oracle for "is anyone hunting me?". That makes
    --- it the one purchase that MUST refuse before it charges — and there was
    --- no state check anywhere in Informant.buy, so a tap on a card that had
    --- not been redrawn yet took the money for information about a contract
    --- that no longer existed.
    local function closedContract(state)
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        Env.players[2].PlayerData.money.bank = 400000

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c)
        truthy(s.contracts.resolve(c.id, state, f.creator.cid, nil, 'fixture'))
        return s, f, c
    end

    for _, state in ipairs({ CB.STATE.CANCELLED, CB.STATE.EXPIRED,
                             CB.STATE.BAILED_OUT, CB.STATE.VOIDED }) do
        it('takes nothing once the contract is ' .. state, function()
            local s, f, c = closedContract(state)
            local before = Env.players[2].PlayerData.money.cash
                         + Env.players[2].PlayerData.money.bank

            local ok, err = s.informant.buy(f.target, c.id)

            falsy(ok, 'a closed contract has nobody tracking anybody')
            eq(err, CB.ERR.ALREADY_SETTLED)
            eq(Env.players[2].PlayerData.money.cash
               + Env.players[2].PlayerData.money.bank, before,
               'and this is the one purchase that is never refunded, so it has '
               .. 'to refuse BEFORE it charges')
        end)
    end

    it('still sells information on a live contract', function()
        -- The door the fix must not have closed.
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        Env.players[2].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(s.contracts.accept(f.hunter, c.id))
        truthy(s.informant.buy(f.target, c.id),
            'the ordinary case has to keep working')
    end)
end)

describe('a target who has already paid to get out', function()
    --- The card was identical before and after their money left.
    ---
    --- With a hunter engaged a buyout is queued rather than instant, so there
    --- is a window in which the premium has gone and the contract has not
    --- closed. The projection carried no sign of it, so the app could not draw
    --- one: same "Buy out" button, same price, to a player whose money was
    --- already spent. No money is lost — the second attempt is refused — but
    --- the only thing they can do about a payment they cannot see is pay again.
    local function paidAndWaiting()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        Env.players[2].PlayerData.money.bank = 400000
        Env.players[3].PlayerData.money.bank = 400000
        Config.Bailout.ProcessingDelaySeconds = 120

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } }, bailoutAmount = 20000,
        })
        truthy(c)
        truthy(s.contracts.accept(f.hunter, c.id), 'a hunter, so it queues')

        local before = Env.players[2].PlayerData.money.cash
                     + Env.players[2].PlayerData.money.bank
        truthy(s.bailout.buy(f.target, c.id), 'the buyout is paid for')
        truthy(Env.players[2].PlayerData.money.cash
               + Env.players[2].PlayerData.money.bank < before,
               'and the premium has actually left')
        return s, f, c
    end

    it('tells the target their card, not the one they saw before paying', function()
        local s, f, c = paidAndWaiting()
        local view = (s.projection.onMe(f.target.cid) or {})[1]
        truthy(view, 'the target still sees the contract while it closes')
        eq(view.bailoutPaid, true,
            'the projection carried no sign that it was paid for, so the page '
            .. 'drew the same button at the same price')
        local _ = c
    end)

    it('says nothing of the sort before they have paid', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } }, bailoutAmount = 20000,
        })
        truthy(c)
        local view = (s.projection.onMe(f.target.cid) or {})[1]
        truthy(view, 'the target sees it')
        falsy(view.bailoutPaid, 'nothing has been paid')
        eq(view.bailoutAvailable, true, 'and the buyout is on offer')
    end)

    it('refuses a second payment, as it always did', function()
        local s, f, c = paidAndWaiting()
        local mid = Env.players[2].PlayerData.money.cash
                  + Env.players[2].PlayerData.money.bank
        local ok, err = s.bailout.buy(f.target, c.id)
        falsy(ok, 'paying twice')
        eq(err, CB.ERR.BUYOUT_PENDING)
        eq(Env.players[2].PlayerData.money.cash
           + Env.players[2].PlayerData.money.bank, mid,
           'and nothing was taken for the second attempt')
    end)
end)

describe('money already promised to one named person', function()
    --- Escrow.moneyValue states the rule and its reason in its own comment:
    --- "a line marked for one named person is already spoken for: the release
    --- a hunter's claim runs skips it, so counting it here advertises a reward
    --- bigger than anything that will ever be paid."
    ---
    --- Escrow.goodsIn, Escrow.release and Projection.rewardLines all apply it.
    --- Two readers in contracts.lua did not, and both decide something a
    --- player pays for.
    ---
    --- A line ends up in that state on a LIVE contract by an ordinary route: a
    --- creator withdraws part of a reward, their pockets are full, so the line
    --- cannot be handed over. It goes back to 'held' and is marked owed to
    --- them, and from that moment every other reader stops counting it.
    local function withQueuedLine()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000, dirty = 4000 } },
            -- At the ceiling for 9,000 of funding (3x). Once 4,000 of it is
            -- promised to the creator the ceiling is 15,000, so a reclamp
            -- that counts the promised line leaves this where it is and one
            -- that does not brings it down. Anything below 15,000 here would
            -- pass either way and prove nothing.
            bailoutAmount = 27000,
        })
        truthy(c, 'a contract funded with clean and dirty money')

        -- The creator cannot carry the black money back.
        Env.players[1]._inventoryFull = true

        local lines = s.storage.readEscrow(c.id)
        local dirty
        for _, line in ipairs(lines) do
            if line.source == 'dirty' then dirty = line end
        end
        truthy(dirty, 'a black-money line to withdraw')

        local ok = s.contracts.withdrawReward(f.creator, c.id, { dirty.id })
        Env.players[1]._inventoryFull = false

        local back = s.storage.readEscrowLine(dirty.id)
        truthy(back and back.owed_to,
            'the withdrawal has to have QUEUED rather than settled, or this '
            .. 'measures nothing: ' .. tostring(ok))
        return s, f, c
    end

    it('is not counted as funding the collection it sits in', function()
        local s, f, c = withQueuedLine()

        -- Now take the only line still funding the collection. The emptiness
        -- check must see the collection as about to be empty.
        local cash
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.source == 'cash' and not line.owed_to then cash = line end
        end
        truthy(cash, 'the clean-money line')

        local ok, err = s.contracts.withdrawReward(f.creator, c.id, { cash.id })
        falsy(ok, 'a collection has to keep something in it, and the queued '
            .. 'line is not something: every other reader already skips it, so '
            .. 'this would leave a live contract paying a hunter nothing')
        eq(err, CB.ERR.INVALID_REWARD)
    end)

    it('is not counted when a buyout price is re-priced against the escrow', function()
        -- Clean money this time. The bailout is a multiple of CLEAN funding
        -- only (CB.MONEY_ACCOUNTS), so a queued black-money line never moved
        -- it — which is why the first version of this test passed with the
        -- fault in place. Clean money is credited rather than carried, so a
        -- full inventory cannot queue it; a creator who has logged off can.
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        Env.players[3].PlayerData.money.bank = 400000

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { cash = 1000 } },
                                 { baseline = { cash = 40000 } } } },
            -- The ceiling for 41,000 of clean funding.
            bailoutAmount = 123000,
        })
        truthy(c)
        eq(s.storage.readContract(c.id).bailout_amount, 123000)
        truthy(s.contracts.accept(f.hunter, c.id))

        local proposal = s.amendments.propose(f.creator, c.id,
            CB.AMENDMENT.REDUCE_REWARD, { slot = 2 })
        truthy(proposal)

        -- The creator closes the game; the hunter agrees, which is the
        -- ordinary way a proposal gets answered.
        Env.removePlayer(1)
        truthy(s.amendments.respond(f.hunter, proposal.id, true))

        local queued = false
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.slot == 2 and line.owed_to == 'CREATOR1' then queued = true end
        end
        truthy(queued, 'the 40,000 has to be queued for the offline creator, '
            .. 'or this measures nothing')

        eq(s.storage.readContract(c.id).bailout_amount, 3000,
            'the target would be charged 123,000 to close a contract now '
            .. 'funded at 1,000 — the old premium, on money given back')
    end)

    it('still lets an ordinary withdrawal through', function()
        -- The door the fix must not have closed.
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000, bank = 3000 } },
        })
        truthy(c)
        local first
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.source == 'bank' then first = line end
        end
        truthy(s.contracts.withdrawReward(f.creator, c.id, { first.id }),
            'taking one of two lines back leaves the collection funded')
    end)
end)

describe('a payout owed to a player who is offline', function()
    --- Queued once per line, not once per release pass.
    ---
    --- A cancel, an expiry or a buyout releases to the creator and then sweeps
    --- the unclaimed remainder to the same creator. For an offline creator the
    --- second pass re-claimed each already-owed line and queued it again. On
    --- login the retry budget was spent partly on duplicates, so which part of
    --- the payout arrived depended on the order the store returned the rows.
    local function boughtOutWhileCreatorOffline()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.cash = 100000
        Env.players[1].PlayerData.money.bank = 100000
        Env.players[2].PlayerData.money.bank = 400000

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000, bank = 3000 } },
            bailoutAmount = 15000,
        })
        truthy(c, 'a contract funded in two lines')

        local creator = Env.players[1]
        Env.removePlayer(1)

        truthy(s.bailout.buy(f.target, c.id), 'the target buys out, instantly')
        eq(s.storage.readContract(c.id).state, CB.STATE.BAILED_OUT)
        return s, f, c, creator
    end

    it('holds one queue entry per line', function()
        local s = boughtOutWhileCreatorOffline()

        local perLine = {}
        for _, entry in ipairs(s.storage.readPending('CREATOR1') or {}) do
            perLine[entry.line_id] = (perLine[entry.line_id] or 0) + 1
        end
        local lines = 0
        for id, n in pairs(perLine) do
            lines = lines + 1
            eq(n, 1, 'line ' .. id .. ' was queued ' .. n .. ' times: once by '
                .. 'the resolution and again by the remainder sweep to the same '
                .. 'person')
        end
        truthy(lines >= 3, 'two escrow lines and the premium should all be '
            .. 'owed, or this measures nothing: ' .. lines)
    end)

    it('arrives whole on the next login, and only once', function()
        local s, f, c, creator = boughtOutWhileCreatorOffline()
        local _ = f; local _c = c

        -- They come back with what they had when they left.
        Env.addPlayer({ source = 1, citizenid = 'CREATOR1', license = 'license:aaa',
                        cash = creator.PlayerData.money.cash,
                        bank = creator.PlayerData.money.bank })
        local before = Env.players[1].PlayerData.money.cash
                     + Env.players[1].PlayerData.money.bank

        s.escrow.retryPending('CREATOR1')
        local after = Env.players[1].PlayerData.money.cash
                    + Env.players[1].PlayerData.money.bank
        -- 5,000 + 3,000 of escrow back, and the 15,000 premium.
        eq(after - before, 23000,
            'part of what was owed arrived and the rest waited for another '
            .. 'login, while the app said the payment had been delivered')

        s.escrow.retryPending('CREATOR1')
        eq(Env.players[1].PlayerData.money.cash
           + Env.players[1].PlayerData.money.bank, after,
           'and a second login pays nothing more')
    end)
end)

describe('informant data across a crash', function()
    --- A relog reset the reroll lock AND the purchase count, on the one
    --- purchase in the resource that is never refunded.
    local function informed()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        Env.players[2].PlayerData.money.bank = 100000
        Env.players[3].PlayerData.money.bank = 400000
        Config.Informant.MaxPurchasesPerContract = 2

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(s.contracts.accept(f.hunter, c.id))
        truthy(s.informant.buy(f.target, c.id), 'the first purchase')
        return s, f, c
    end

    local function purse()
        local p = Env.players[2].PlayerData
        return p.money.cash + p.money.bank
    end

    local function relog(s, f)
        -- Exactly what the disconnect bridge does.
        require('crimson-bounty.server.bridges').onPlayerDropped(s, f.target.cid)
        Env.removePlayer(2)
        Env.addPlayer({ source = 2, citizenid = 'TARGET01', license = 'license:bbb',
                        cash = 0, bank = 75000 })
        return s.identity.resolve(2)
    end

    it('does not charge again for the same answer after a relog', function()
        local s, f, c = informed()
        local target = relog(s, f)
        local before = purse()

        truthy(s.informant.buy(target, c.id), 'asking again inside the lock')
        eq(purse(), before,
            'inside the reroll lock a repeat is free by design; a crash made it '
            .. 'cost the whole fee again for the same name')
    end)

    it('does not reset how many times one contract can be asked about', function()
        local s, f, c = informed()
        -- Spend the second and last purchase outside the lock.
        Env.advance(Config.Informant.RerollLockMinutes * 60 + 10)
        truthy(s.informant.buy(f.target, c.id), 'the second purchase')
        Env.advance(Config.Informant.RerollLockMinutes * 60 + 10)
        eq(select(2, s.informant.buy(f.target, c.id)), CB.ERR.LIMIT_REACHED)

        local target = relog(s, f)
        local ok, err = s.informant.buy(target, c.id)
        falsy(ok, 'rejoining must not be a way past the ceiling')
        eq(err, CB.ERR.LIMIT_REACHED)
    end)
end)
