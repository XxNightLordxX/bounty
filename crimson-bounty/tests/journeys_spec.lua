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
        -- The guard the fix must not have widened. It used to bite only at
        -- apply time, so both parties could negotiate something that could
        -- never succeed and the refusal landed on whoever pressed Agree. It
        -- is now asked when the proposal is made, and again when it is
        -- applied.
        local s, f, c = twoCollections()
        local proposal, err = s.amendments.propose(f.creator, c.id,
            CB.AMENDMENT.REDUCE_REWARD, { slot = 1 })
        falsy(proposal, 'the live collection is not the creator\'s to take back')
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

        local proposal, err = s.amendments.propose(f.creator, c.id,
            CB.AMENDMENT.REDUCE_REWARD, { slot = 2 })
        falsy(proposal, 'the middle one is not removable')
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

describe('a withdrawal that queued a line', function()
    --- A queued line has left the pot: it is owed to the creator, and every
    --- reader of what the contract pays skips it from that moment. Two paths
    --- in withdrawReward counted only SETTLED lines as having got out.
    local function race()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        Env.players[3].PlayerData.money.bank = 400000

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { slots = {
                { baseline = { cash = 5000 }, bonus = { dirty = 1000 } },
                { baseline = { cash = 3000 }, bonus = { cash = 500 } },
            } },
        })
        truthy(c, 'two collections, each with a bonus')

        local wanted = {}
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.portion == CB.PORTION.BONUS then wanted[#wanted + 1] = line.id end
        end
        eq(#wanted, 2, 'two bonus lines, so the acceptance can land between them')

        local worthBefore = s.escrow.moneyValue(c.id) + 1000  -- the dirty line
        -- No room for the black money: the first line out is queued.
        Env.players[1]._inventoryFull = true

        -- The hunter accepts as the SECOND line leaves `held` — the window the
        -- release guard exists for.
        local realClaim = s.storage.claimEscrowLine
        local seen = 0
        s.storage.claimEscrowLine = function(id, expected, next_)
            local out = realClaim(id, expected, next_)
            if out and expected == CB.ESCROW_STATE.HELD then
                seen = seen + 1
                if seen == 2 then s.contracts.accept(f.hunter, c.id, false) end
            end
            return out
        end
        Natives.calls.notifications = {}
        local moved, err, result = s.contracts.withdrawReward(f.creator, c.id, wanted)
        s.storage.claimEscrowLine = realClaim
        Env.players[1]._inventoryFull = false

        local queued = false
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.owed_to == 'CREATOR1' then queued = true end
        end
        truthy(queued, 'the black money has to have been queued, or this '
            .. 'measures nothing')
        truthy(seen >= 2, 'the acceptance has to have landed mid-release')
        return s, f, c, moved, err, result, worthBefore
    end

    it('does not tell the creator it failed while the reward has shrunk', function()
        local _, _, _, moved, err = race()
        truthy(moved, 'the creator was told "that did not work" (' .. tostring(err)
            .. ') about a withdrawal that had already taken money out of the pot')
    end)

    it('tells the hunter the contract shrank as they took it', function()
        race()
        local told = false
        for _, note in ipairs(Natives.calls.notifications or {}) do
            local text = tostring(note.title or '') .. ' '
                .. tostring(note.content or note.message or '')
            if text:find('Reward changed', 1, true) then told = true end
        end
        truthy(told, 'part of the reward left as the hunter accepted and the '
            .. 'hunter was told nothing')
    end)

    it('leaves a financial row for the escrow that moved', function()
        local s = race()
        s.audit.flush()
        local rows = 0
        for _, row in ipairs(s.storage.readAudit()) do
            if row.action == 'reward_reduced' then rows = rows + 1 end
        end
        eq(rows, 1, 'escrow left the pot with no financial row saying so')
    end)
end)

describe('a withdrawal where every line queued', function()
    --- Nothing settled, so Escrow.release answered "not ok" — and the early
    --- return for that case took "a line was queued" as success and left
    --- before the audit row and the re-pricing. The escrow had left the pot
    --- all the same.
    local function withdraw()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { cash = 1000 }, bonus = { cash = 40000 } } } },
            -- The ceiling for 41,000 of clean funding.
            bailoutAmount = 123000,
        })
        truthy(c)
        eq(s.storage.readContract(c.id).bailout_amount, 123000)

        local bonus
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.portion == CB.PORTION.BONUS then bonus = line end
        end
        truthy(bonus)

        -- The creator's game closes with the request in flight: clean money
        -- is credited rather than carried, so being offline is what queues it.
        Env.removePlayer(1)
        local moved, err = s.contracts.withdrawReward(f.creator, c.id, { bonus.id })

        local queued = false
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.id == bonus.id and line.owed_to == 'CREATOR1' then queued = true end
        end
        truthy(queued, 'the 40,000 has to be queued, or this measures nothing')
        return s, c, moved, err
    end

    it('reports that the reward changed', function()
        local _, _, moved, err = withdraw()
        truthy(moved, 'refused with ' .. tostring(err))
    end)

    it('leaves a financial row for the escrow that moved', function()
        local s = withdraw()
        s.audit.flush()
        local rows = 0
        for _, row in ipairs(s.storage.readAudit()) do
            if row.action == 'reward_reduced' then rows = rows + 1 end
        end
        eq(rows, 1, '40,000 left the pot with no financial row saying so')
    end)

    it('re-prices the buyout against what is left', function()
        local s, c = withdraw()
        eq(s.storage.readContract(c.id).bailout_amount, 3000,
            'the target would be charged 123,000 to close a contract now '
            .. 'funded at 1,000')
    end)
end)

describe('taking a contract up again after walking away', function()
    local function walkedAway(opts)
        opts = opts or {}
        local s = newStack()
        local f = fixture(s)
        s.bridges.install(s)
        Env.players[1].PlayerData.money.bank = 400000
        Env.players[3].PlayerData.money.bank = 400000
        local slots = {}
        for i = 1, (opts.slots or 1) do slots[i] = { baseline = { cash = 1000 * i } } end
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = opts.mode or CB.MODE.COMPETITIVE,
            reward = { slots = slots }, penaltyAmount = opts.stake,
        })
        truthy(c)
        truthy(s.contracts.accept(f.hunter, c.id, false), 'the first stint')
        if opts.before then opts.before(s, f, c) end
        truthy(s.contracts.abandon(f.hunter, c.id), 'walks away')
        return s, f, c
    end

    it('lets the hunter accept again', function()
        local s, f, c = walkedAway()
        local ok, err = s.contracts.accept(f.hunter, c.id, false)
        truthy(ok, 'the contract is listed to them with an Accept button and '
            .. 'was refused "Not right now." forever: ' .. tostring(err))
        eq(s.projection.contract(s.storage.readContract(c.id), 'HUNTER01').role, 'hunter')
    end)

    it('takes the old row up again rather than writing a second one', function()
        local s, f, c = walkedAway()
        local alias = s.storage.readHunter(c.id, 'HUNTER01').alias
        truthy(s.contracts.accept(f.hunter, c.id, false))
        local rows = 0
        for _, row in ipairs(s.storage.readHunters(c.id)) do
            if row.hunter_cid == 'HUNTER01' then rows = rows + 1 end
        end
        eq(rows, 1, 'two rows for one person: which one readHunter returns is '
            .. 'up to the store')
        eq(s.storage.readHunter(c.id, 'HUNTER01').alias, alias,
            'the creator would see a second name for the same person')
    end)

    it('does not make walking away a way round the wait between payouts', function()
        local s, f, c = walkedAway({ slots = 2, before = function(s, f, c)
            truthy(s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION))
        end })
        truthy(s.contracts.accept(f.hunter, c.id, false))
        local ok, err = s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
        falsy(ok, 'collected twice in a row by walking away in between')
        eq(err, CB.ERR.SLOT_COOLDOWN)
    end)

    it('takes the stake again, because it was forfeited the first time', function()
        local s, f, c = walkedAway({ stake = 2000 })
        local before = Env.players[3].PlayerData.money.bank
        truthy(s.contracts.accept(f.hunter, c.id, false))
        eq(Env.players[3].PlayerData.money.bank, before - 2000)
    end)

    it('does not carry a kill from the first stint into the second', function()
        local s, f, c = walkedAway({ before = function(s, f, c)
            Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
            Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
            Env.players[2]._health = (Env.players[2]._health or 200) - 60
            s.death.recordDamage(3, 2, 123456)
            Env.players[2].PlayerData.metadata.isdead = true
            s.death.onVictimReport(2)
            truthy(s.death.getPending(c.id, 'HUNTER01'), 'a kill in the first stint')
            truthy(s.photo.issue(f.hunter, c.id), 'and a token for it')
        end })
        falsy(s.death.getPending(c.id, 'HUNTER01'),
            'the proof outlived the stint it was made in')
        eq(s.photo.tokenCount(), 0, 'and so did the token')
        truthy(s.contracts.accept(f.hunter, c.id, false))
        local _, err = s.photo.issue(f.hunter, c.id)
        eq(err, CB.ERR.NO_KILL_TO_VERIFY)
    end)

    it('needs no new id to come back, so running out of them cannot refuse it', function()
        local s, f, c = walkedAway()
        local real = s.storage.readHunterById
        s.storage.readHunterById = function() return { id = 'taken' } end
        local ok, err = s.contracts.accept(f.hunter, c.id, false)
        s.storage.readHunterById = real
        truthy(ok, 'refused for want of an id the re-accept never uses: ' .. tostring(err))
    end)

    it('still refuses somebody already on it, in words that say so', function()
        local s, f, c = walkedAway()
        truthy(s.contracts.accept(f.hunter, c.id, false))
        local ok, err = s.contracts.accept(f.hunter, c.id, false)
        falsy(ok)
        eq(err, CB.ERR.ALREADY_HOLDING)
    end)
end)

describe('accepting a contract that is no longer there to take', function()
    it('says a closed contract is closed', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        truthy(s.contracts.cancel(f.creator, c.id))
        local ok, err = s.contracts.accept(f.hunter, c.id, false)
        falsy(ok)
        eq(err, CB.ERR.ALREADY_SETTLED, '"Not right now." on a contract that '
            .. 'will never be acceptable again')
    end)

    it('keeps "not right now" for the one state that is momentary', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd',
            cash = 5000, bank = 5000, firstname = 'Kade', lastname = 'Wolfe' })
        truthy(s.contracts.accept(s.identity.resolve(4), c.id, false))
        truthy(s.contracts.transition(c.id, CB.STATE.ACCEPTED, CB.STATE.COMPLETING, 'x'),
            'somebody else is being paid')
        local _, err = s.contracts.accept(f.hunter, c.id, false)
        eq(err, CB.ERR.BAD_STATE)
    end)
end)

describe('moving a deadline by agreement', function()
    local function held()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        truthy(s.contracts.accept(f.hunter, c.id, false))
        return s, f, c
    end

    it('shortens BY the amount both parties agreed to', function()
        local s, f, c = held()
        local before = s.storage.readContract(c.id).deadline_at
        truthy(before and before - os.time() > 3600, 'a deadline hours away')
        local p = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.SHORTEN_DEADLINE,
            { seconds = 1800 })
        truthy(p)
        truthy(s.amendments.respond(f.hunter, p.id, true))
        eq(s.storage.readContract(c.id).deadline_at, before - 1800,
            '"Shorten the deadline by 30 minutes" left thirty minutes in total')
    end)

    it('does not let a late answer cut the deadline to nothing', function()
        -- Into the past, or to under the five minutes a cut must leave: the
        -- time left is measured when it is agreed, not when it was asked.
        local s, f, c = held()
        local deadline = s.storage.readContract(c.id).deadline_at
        local p = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.SHORTEN_DEADLINE,
            { seconds = (deadline - os.time()) - 400 })
        truthy(p, 'a cut that fits when it is proposed')
        Env.advance(150)  -- answered when it would leave only 250 seconds
        local ok, err = s.amendments.respond(f.hunter, p.id, true)
        falsy(ok, 'agreed into a deadline that had already passed')
        eq(err, CB.ERR.INVALID_INPUT)
        eq(s.storage.readContract(c.id).deadline_at, deadline, 'and it did not move')
    end)

    it('refuses, when proposed, a cut that would leave under five minutes', function()
        -- The cut is in the store until the look for holders who did not
        -- agree is done, where the expiry pass can see it; one leaving
        -- seconds could end the contract before it was put back.
        local s, f, c = held()
        local left = s.storage.readContract(c.id).deadline_at - os.time()
        local p, err = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.SHORTEN_DEADLINE,
            { seconds = left - 299 })
        falsy(p, 'a cut leaving 299 seconds')
        eq(err, CB.ERR.INVALID_INPUT)
        truthy(s.amendments.propose(f.creator, c.id, CB.AMENDMENT.SHORTEN_DEADLINE,
            { seconds = left - 300 }), 'five minutes is enough')
    end)

    it('counts what a stopped clock has left, not the wall clock', function()
        local s, f, c = held()
        local deadline = s.storage.readContract(c.id).deadline_at
        truthy(s.storage.startPause(c.id, os.time()))
        Env.advance(deadline - os.time() + 600)  -- the wall clock is past it
        truthy(s.amendments.propose(f.creator, c.id, CB.AMENDMENT.SHORTEN_DEADLINE,
            { seconds = 600 }), 'hours are left on the stopped clock')
    end)

    it('refuses, when proposed, a cut longer than the time that is left', function()
        local s, f, c = held()
        local left = s.storage.readContract(c.id).deadline_at - os.time()
        local p, err = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.SHORTEN_DEADLINE,
            { seconds = left + 60 })
        falsy(p, 'the other party would be asked to agree to something that '
            .. 'cannot be applied')
        eq(err, CB.ERR.INVALID_INPUT)
    end)
end)

describe('a proposal whose time is up', function()
    local function lapsed()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        truthy(s.contracts.accept(f.hunter, c.id, false))
        truthy(s.amendments.propose(f.creator, c.id, CB.AMENDMENT.SHORTEN_DEADLINE,
            { seconds = 600 }))
        -- Past its time (rounded up to five minutes), and the sweep has
        -- not run yet.
        Env.advance(Config.Amendments.ProposalExpirySeconds + 300 + 1)
        return s, f, c
    end

    it('does not hold the open slot until the sweep gets round to it', function()
        local s, f, c = lapsed()
        local p, err = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.CANCEL, {})
        truthy(p, 'refused by a proposal nobody can answer any more: ' .. tostring(err))
    end)

    it('is not listed with Agree and Decline', function()
        local s, f, c = lapsed()
        local listed = s.amendments.openFor(f.hunter, c.id)
        eq(#listed, 0, 'drawn with two buttons that can only be refused')
    end)
end)

describe('an agreed change the contract has moved past', function()
    it('tells the person who proposed it', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { cash = 1000 } }, { baseline = { cash = 2000 } } } },
        })
        truthy(s.contracts.accept(f.hunter, c.id, false))
        local p = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.REDUCE_REWARD, { slot = 2 })
        truthy(p, 'the last collection, while nobody is competing for it')

        -- Collection 1 is paid, so collection 2 is now the live one.
        truthy(s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION))
        Natives.calls.notifications = {}
        local ok, err = s.amendments.respond(f.hunter, p.id, true)
        falsy(ok, 'the live collection cannot be given back')
        eq(err, CB.ERR.INVALID_INPUT)

        local told = false
        for _, note in ipairs(Natives.calls.notifications) do
            if note.title == 'Change not made' then told = true end
        end
        truthy(told, 'only the person who pressed Agree saw the refusal; the '
            .. 'one who asked for the change went on believing it was waiting')
        eq(s.escrow.moneyValue(c.id, { slot = 2 }), 2000, 'and nothing moved')
    end)
end)
