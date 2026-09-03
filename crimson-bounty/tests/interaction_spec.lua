--- Bailout, informant data, amendments and the masked relay.

local function seeded(opts)
    opts = opts or {}
    local s = newStack()
    local f = fixture(s)
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt',
        mode = opts.mode or CB.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 }, bonus = { cash = 2500 } },
        bailoutAmount = opts.bailout,
    })
    if opts.accept ~= false then s.contracts.accept(f.hunter, c.id, false) end
    return s, f, c
end

describe('bailout', function()
    it('closes the contract and pays the creator escrow plus premium', function()
        local s, f, c = seeded({ bailout = 15000, accept = false })
        local before = Env.players[1].PlayerData.money.cash + Env.players[1].PlayerData.money.bank
        truthy(s.bailout.buy(f.target, c.id))
        eq(s.storage.readContract(c.id).state, CB.STATE.BAILED_OUT)
        local after = Env.players[1].PlayerData.money.cash + Env.players[1].PlayerData.money.bank
        eq(after - before, 7500 + 15000, 'escrow returned plus the premium')
    end)

    it('charges the target', function()
        local s, f, c = seeded({ bailout = 15000, accept = false })
        truthy(s.bailout.buy(f.target, c.id))
        eq(Env.players[2].PlayerData.money.bank, 5000, '20000 - 15000')
    end)

    it('refuses when the target cannot pay, leaving the contract alone', function()
        local s, f, c = seeded({ bailout = 22500, accept = false })
        Env.players[2].PlayerData.money.bank = 100
        Env.players[2].PlayerData.money.cash = 100
        local ok, err = s.bailout.buy(f.target, c.id)
        falsy(ok)
        eq(err, CB.ERR.INSUFFICIENT)
        eq(s.storage.readContract(c.id).state, CB.STATE.ACTIVE, 'untouched')
    end)

    it('refuses a buyout of someone elses contract', function()
        local s, f, c = seeded({ bailout = 15000, accept = false })
        local ok, err = s.bailout.buy(f.hunter, c.id)
        falsy(ok)
        eq(err, CB.ERR.NOT_PARTICIPANT)
    end)

    it('refuses a buyout from the floor', function()
        local s, f, c = seeded({ bailout = 15000, accept = false })
        Env.players[2].PlayerData.metadata.inlaststand = true
        local ok = s.bailout.buy(f.target, c.id)
        falsy(ok, 'cannot buy your way out while bleeding out')
    end)

    it('delays the buyout while a hunter is engaged, then settles', function()
        local s, f, c = seeded({ bailout = 15000 })
        truthy(s.bailout.buy(f.target, c.id))
        eq(s.storage.readContract(c.id).state, CB.STATE.ACCEPTED, 'not instant — the hunter gets a window')
        eq(s.bailout.queuedCount(), 1)

        Env.advance(Config.Bailout.ProcessingDelaySeconds + 1)
        eq(s.bailout.processQueue(), 1)
        eq(s.storage.readContract(c.id).state, CB.STATE.BAILED_OUT)
    end)

    it('refunds the premium if a hunter completes during the delay', function()
        local s, f, c = seeded({ bailout = 15000 })
        s.bailout.buy(f.target, c.id)
        local afterPaying = Env.players[2].PlayerData.money.bank

        s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
        Env.advance(Config.Bailout.ProcessingDelaySeconds + 1)
        s.bailout.processQueue()

        eq(Env.players[2].PlayerData.money.bank, afterPaying + 15000, 'the target paid for nothing and is repaid')
    end)

    it('cannot be paid twice for the same contract', function()
        local s, f, c = seeded({ bailout = 15000, accept = false })
        truthy(s.bailout.buy(f.target, c.id))
        local paid = Env.players[2].PlayerData.money.bank
        local ok = s.bailout.buy(f.target, c.id)
        falsy(ok)
        eq(Env.players[2].PlayerData.money.bank, paid, 'not charged again')
    end)
end)

describe('informant data', function()
    --- Put the hunter on the target's shoulder and let the sampler see it.
    --- A hunter who pressed accept and went to bed is not tracking anybody,
    --- and naming them would make the purchase a roster dump (§6.1).
    local function tailing(s, hunterSource)
        Env.players[2]._coords = { x = 500.0, y = 500.0, z = 30.0 }
        Env.players[hunterSource or 3]._coords = { x = 505.0, y = 500.0, z = 30.0 }
        s.death.watchTargets(s.storage.allContracts())
    end

    it('names a hunter for the creator', function()
        local s, f, c = seeded()
        tailing(s)
        local ok, err, data = s.informant.buy(f.creator, c.id)
        truthy(ok, tostring(err))
        truthy(data.found)
        eq(data.name, 'Rook Ash')
    end)

    it('is available to the target as well', function()
        local s, f, c = seeded()
        tailing(s)
        Env.players[2].PlayerData.money.bank = 100000
        local ok, _, data = s.informant.buy(f.target, c.id)
        truthy(ok)
        truthy(data.found)
    end)

    it('names nobody when no hunter has come near', function()
        local s, f, c = seeded()
        -- Accepted, and a mile away. There is nobody on you to name.
        Env.players[2]._coords = { x = 0.0, y = 0.0, z = 30.0 }
        Env.players[3]._coords = { x = 3000.0, y = 3000.0, z = 30.0 }
        s.death.watchTargets(s.storage.allContracts())

        local ok, err, data = s.informant.buy(f.creator, c.id)
        truthy(ok, tostring(err))
        falsy(data.found, 'accepting a contract is not tracking somebody')
    end)

    it('forgets an observation that has gone stale', function()
        local s, f, c = seeded()
        tailing(s)
        Env.time = Env.time + (Config.Informant.ProximityWindowMinutes * 60) + 1

        local ok, _, data = s.informant.buy(f.creator, c.id)
        truthy(ok)
        falsy(data.found, 'somebody who walked past yesterday is not on you now')
    end)

    it('names everyone active when proximity is not required', function()
        local s, f, c = seeded()
        withConfig({ { Config.Informant, 'RequireProximity', false } }, function()
            local ok, _, data = s.informant.buy(f.creator, c.id)
            truthy(ok)
            truthy(data.found, 'the old behaviour, for servers that prefer it')
        end)
    end)

    it('refuses anyone who is not the creator or the target', function()
        local s, f, c = seeded()
        Env.addPlayer({ source = 9, citizenid = 'NOSEY001', license = 'license:n', bank = 99999 })
        local ok, err = s.informant.buy(s.identity.resolve(9), c.id)
        falsy(ok)
        eq(err, CB.ERR.NOT_PARTICIPANT)
    end)

    it('charges the premium', function()
        local s, f, c = seeded()
        Env.players[1].PlayerData.money.bank = 100000
        s.informant.buy(f.creator, c.id)
        eq(Env.players[1].PlayerData.money.bank, 100000 - Config.Informant.Cost)
    end)

    it('returns the same hunter on a repeat purchase inside the lock', function()
        local s, f, c = seeded()
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd' })
        s.contracts.accept(s.identity.resolve(4), c.id, false)
        local _, _, first = s.informant.buy(f.creator, c.id)
        local _, _, again = s.informant.buy(f.creator, c.id)
        eq(again.name, first.name, 'sticky, so repeat buys cannot enumerate the roster')
    end)

    it('charges even when nobody is hunting, so it is not a free oracle', function()
        local s, f, c = seeded({ accept = false })
        Env.players[1].PlayerData.money.bank = 100000
        local ok, _, data = s.informant.buy(f.creator, c.id)
        truthy(ok)
        falsy(data.found)
        eq(Env.players[1].PlayerData.money.bank, 100000 - Config.Informant.Cost, 'still charged')
    end)

    it('never returns a citizen id', function()
        local s, f, c = seeded()
        local _, _, data = s.informant.buy(f.creator, c.id)
        falsy(data.cid, 'citizen ids are internal keys')
        falsy(data.citizenid)
    end)
end)

describe('amendments', function()
    it('applies an escrow increase immediately', function()
        local s, f, c = seeded()
        truthy(s.amendments.addEscrow(f.creator, c.id, { baseline = { cash = 1000 } }))
        eq(s.escrow.moneyValue(c.id), 8500, 'added to the pot')
    end)

    it('refuses an increase from anyone but the creator', function()
        local s, f, c = seeded()
        local ok, err = s.amendments.addEscrow(f.hunter, c.id, { baseline = { cash = 1000 } })
        falsy(ok)
        eq(err, CB.ERR.NOT_PARTICIPANT)
    end)

    it('needs both sides to approve a material change', function()
        local s, f, c = seeded()
        local proposal = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.SHORTEN_DEADLINE, { seconds = 600 })
        truthy(proposal)
        eq(s.storage.readContract(c.id).deadline_at > os.time() + 3000, true, 'not applied yet')

        local ok, _, outcome = s.amendments.respond(f.hunter, proposal.id, true)
        truthy(ok)
        eq(outcome, 'applied')
    end)

    it('lets a single decline stop it, leaving the original terms', function()
        local s, f, c = seeded()
        local before = s.storage.readContract(c.id).deadline_at
        local proposal = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.SHORTEN_DEADLINE, { seconds = 60 })
        s.amendments.respond(f.hunter, proposal.id, false)
        eq(s.storage.readContract(c.id).deadline_at, before, 'unchanged')
    end)

    it('expires an unanswered proposal', function()
        local s, f, c = seeded()
        local proposal = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.SHORTEN_DEADLINE, { seconds = 60 })
        Env.advance(Config.Amendments.ProposalExpirySeconds + 10)
        local ok, err, outcome = s.amendments.respond(f.hunter, proposal.id, true)
        falsy(ok)
        eq(outcome, 'expired')
    end)

    it('never allows the target to be changed', function()
        local s, f, c = seeded()
        local proposal, err = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.CHANGE_REASON,
            { reason = 'new', targetCid = 'HUNTER01' })
        falsy(proposal, 'retargeting is a new contract, never an amendment')
        eq(err, CB.ERR.INVALID_INPUT)
    end)

    it('refuses a proposal from an outsider', function()
        local s, f, c = seeded()
        Env.addPlayer({ source = 9, citizenid = 'OUTSIDR1', license = 'license:o' })
        local proposal, err = s.amendments.propose(s.identity.resolve(9), c.id,
            CB.AMENDMENT.CANCEL, {})
        falsy(proposal)
        eq(err, CB.ERR.NOT_PARTICIPANT)
    end)

    it('returns escrow to the creator on an agreed cancellation', function()
        local s, f, c = seeded()
        local before = Env.players[1].PlayerData.money.cash
        local proposal = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.CANCEL, {})
        s.amendments.respond(f.hunter, proposal.id, true)
        eq(s.storage.readContract(c.id).state, CB.STATE.CANCELLED)
        eq(Env.players[1].PlayerData.money.cash, before + 7500, 'full refund')
    end)
end)

describe('masked relay', function()
    it('lets creator and hunter talk under aliases', function()
        local s, f, c = seeded()
        local threads = s.comms.threads(f.creator, c.id)
        eq(#threads, 1)
        truthy(s.comms.send(f.creator, c.id, threads[1].handle, 'Take him alive if you can.'))
        truthy(s.comms.send(f.hunter, c.id, nil, 'Understood.'))

        local thread = s.comms.read(f.hunter, c.id, nil)
        eq(#thread, 2)
        eq(thread[1].alias, 'Client')
        eq(thread[2].alias, 'Operative #1')
    end)

    it('never returns the other partys identity', function()
        local s, f, c = seeded()
        local threads = s.comms.threads(f.creator, c.id)
        s.comms.send(f.creator, c.id, threads[1].handle, 'hello')
        local thread = s.comms.read(f.hunter, c.id, nil)
        for _, message in ipairs(thread) do
            falsy(message.from_cid, 'citizen id must not cross')
            falsy(message.name, 'name must not cross')
            falsy(tostring(message.alias):find('Marlowe'), 'real name leaked into the alias')
        end
    end)

    it('refuses an outsider reading or writing', function()
        local s, f, c = seeded()
        Env.addPlayer({ source = 9, citizenid = 'OUTSIDR1', license = 'license:o' })
        local outsider = s.identity.resolve(9)
        falsy(s.comms.send(outsider, c.id, 'anything', 'hi'))
        falsy(s.comms.read(outsider, c.id, 'anything'))
    end)

    it('keeps competitive hunters in separate threads', function()
        local s, f, c = seeded()
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd' })
        local second = s.identity.resolve(4)
        s.contracts.accept(second, c.id, false)

        local threads = s.comms.threads(f.creator, c.id)
        s.comms.send(f.creator, c.id, threads[1].handle, 'for hunter one only')
        eq(#s.comms.read(second, c.id, nil), 0, 'hunter two sees nothing of it')
        eq(#s.comms.read(f.hunter, c.id, nil), 1)
    end)

    it('filters blacklisted words', function()
        local s, f, c = seeded()
        local threads = s.comms.threads(f.creator, c.id)
        local ok, err = s.comms.send(f.creator, c.id, threads[1].handle, 'you slur person')
        falsy(ok)
        eq(err, CB.ERR.INVALID_INPUT)
    end)

    it('rate limits message spam', function()
        local s, f, c = seeded()
        local threads = s.comms.threads(f.creator, c.id)
        local sent = 0
        for i = 1, 30 do
            if s.comms.send(f.creator, c.id, threads[1].handle, 'msg ' .. i) then sent = sent + 1 end
        end
        truthy(sent <= Config.Cooldowns.message.burst, 'throttled, sent ' .. sent)
    end)
end)

describe('amendment payloads are bounded', function()
    local function seededPair()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        s.contracts.accept(f.hunter, c.id, false)
        return s, f, c
    end

    it('stores only the fields the amendment kind actually uses', function()
        local s, f, c = seededPair()
        local proposal = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.SHORTEN_DEADLINE, {
            seconds = 600,
            junk = string.rep('a', 100000),
            nested = { deep = { deeper = 'noise' } },
        })
        truthy(proposal)

        local stored = s.storage.readAmendment(proposal.id)
        eq(stored.payload.seconds, 600)
        falsy(stored.payload.junk, 'unbounded client data must not be persisted')
        falsy(stored.payload.nested)
    end)

    it('rejects a proposal whose parameters are missing or malformed', function()
        local s, f, c = seededPair()
        for _, bad in ipairs({
            { kind = CB.AMENDMENT.SHORTEN_DEADLINE, payload = { seconds = 'soon' } },
            { kind = CB.AMENDMENT.SHORTEN_DEADLINE, payload = {} },
            { kind = CB.AMENDMENT.CHANGE_MODE, payload = { mode = 'whatever' } },
            { kind = CB.AMENDMENT.CHANGE_REASON, payload = { reason = '' } },
            { kind = CB.AMENDMENT.REDUCE_REWARD, payload = { slot = -1 } },
        }) do
            local proposal, err = s.amendments.propose(f.creator, c.id, bad.kind, bad.payload)
            falsy(proposal, 'accepted a malformed payload for ' .. bad.kind)
            eq(err, CB.ERR.INVALID_INPUT)
        end
    end)

    it('expires proposals without walking every contract ever created', function()
        local s, f, c = seededPair()
        local proposal = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.SHORTEN_DEADLINE, { seconds = 600 })
        truthy(proposal)

        Env.advance(Config.Amendments.ProposalExpirySeconds + 10)
        eq(s.amendments.expire(), 1, 'the open proposal expires')
        eq(s.amendments.expire(), 0, 'and the tracking set is then empty')
        eq(s.storage.readAmendment(proposal.id).outcome, 'expired')
    end)
end)

describe('bailout money survives everything', function()
    local function queued()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } }, bailoutAmount = 10000,
        })
        s.contracts.accept(f.hunter, c.id, false)
        truthy(s.bailout.buy(f.target, c.id))
        return s, f, c
    end

    it('persists a queued buyout on the contract, not in memory', function()
        local s, f, c = queued()
        local stored = s.storage.readContract(c.id)
        truthy(stored.bailout_queued_at, 'a restart must not lose the queued buyout')
        eq(stored.bailout_paid_amount, 10000)
        eq(stored.bailout_paid_by, 'TARGET01')
    end)

    it('settles a queued buyout that was pending across a restart', function()
        local s, f, c = queued()
        -- Simulate a restart: a fresh process reads the queue from storage.
        s.bailout.init({ storage = s.storage, identity = s.identity,
            contracts = s.contracts, escrow = s.escrow, audit = s.audit, notify = s.notify })

        Env.advance(Config.Bailout.ProcessingDelaySeconds + 1)
        eq(s.bailout.processQueue(), 1, 'the queued buyout survives a restart')
        eq(s.storage.readContract(c.id).state, CB.STATE.BAILED_OUT)
    end)

    it('owes the premium to an offline creator instead of dropping it', function()
        local s, f, c = queued()
        Env.removePlayer(1)  -- creator logs out before it settles

        Env.advance(Config.Bailout.ProcessingDelaySeconds + 1)
        s.bailout.processQueue()

        local owed = s.storage.readPending('CREATOR1')
        truthy(#owed > 0, 'the premium must be owed, not silently dropped')

        -- The creator comes back and is paid.
        Env.addPlayer({ source = 1, citizenid = 'CREATOR1', license = 'license:aaa', cash = 0, bank = 0 })
        local before = Env.players[1].PlayerData.money.bank + Env.players[1].PlayerData.money.cash
        s.escrow.retryPending('CREATOR1')
        local after = Env.players[1].PlayerData.money.bank + Env.players[1].PlayerData.money.cash
        truthy(after > before, 'the owed premium and escrow are delivered on return')
    end)

    it('refunds a cash premium as cash, not as bank money', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[2].PlayerData.money.bank = 0
        Env.players[2].PlayerData.money.cash = 50000

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } }, bailoutAmount = 10000,
        })
        truthy(s.bailout.buy(f.target, c.id))
        eq(Env.players[2].PlayerData.money.cash, 40000, 'paid from cash')
        eq(Env.players[1].PlayerData.money.cash, 95000 + 5000 + 10000,
            'creator receives the premium as cash too')
        eq(Env.players[1].PlayerData.money.bank, 100000, 'and no bank money appeared')
    end)
end)

describe('additive improvements apply without approval', function()
    local function seededImprove()
        local s = newStack()
        local f = fixture(s)
        Env.players[3].PlayerData.money.bank = 50000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } },
            bonusPercent = 50, penaltyAmount = 10000,
        })
        s.contracts.accept(f.hunter, c.id, false)
        return s, f, c
    end

    it('extends the deadline immediately', function()
        local s, f, c = seededImprove()
        local before = s.storage.readContract(c.id).deadline_at
        truthy(s.amendments.improve(f.creator, c.id, CB.AMENDMENT.EXTEND_DEADLINE, { seconds = 600 }))
        eq(s.storage.readContract(c.id).deadline_at, before + 600)
    end)

    it('never extends past the absolute lifetime', function()
        local s, f, c = seededImprove()
        s.amendments.improve(f.creator, c.id, CB.AMENDMENT.EXTEND_DEADLINE,
            { seconds = Config.Limits.ContractLifetimeSeconds })
        local stored = s.storage.readContract(c.id)
        truthy(stored.deadline_at <= stored.expires_at, 'the lifetime ceiling holds')
    end)

    it('raises the bonus but never lowers it', function()
        local s, f, c = seededImprove()
        truthy(s.amendments.improve(f.creator, c.id, CB.AMENDMENT.RAISE_BONUS, { percent = 80 }))
        eq(s.storage.readContract(c.id).bonus_percent, 80)
        falsy(s.amendments.improve(f.creator, c.id, CB.AMENDMENT.RAISE_BONUS, { percent = 20 }),
            'lowering a bonus is not an improvement')
    end)

    it('returns the difference to the hunter out of the stake, not out of nothing', function()
        local s, f, c = seededImprove()
        eq(Env.players[3].PlayerData.money.bank, 40000, 'staked 10000')

        truthy(s.amendments.improve(f.creator, c.id, CB.AMENDMENT.LOWER_PENALTY, { amount = 4000 }))
        eq(Env.players[3].PlayerData.money.bank, 46000, 'the 6000 difference comes back')

        -- And the escrowed stake shrank to match: the difference came out of
        -- the stake rather than being minted alongside it.
        local staked = 0
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.portion == CB.PORTION.STAKE then staked = staked + line.amount end
        end
        eq(staked, 4000, 'the escrow line must shrink with the penalty')
    end)

    it('cannot be looped to print money', function()
        local s, f, c = seededImprove()
        local opening = Env.players[3].PlayerData.money.bank
            + Env.players[1].PlayerData.money.bank
            + Env.players[1].PlayerData.money.cash

        -- Raise and lower repeatedly: each cycle used to mint the difference.
        for _ = 1, 5 do
            local proposal = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.RAISE_PENALTY,
                { amount = 10000 })
            if proposal then s.amendments.respond(f.hunter, proposal.id, true) end
            s.amendments.improve(f.creator, c.id, CB.AMENDMENT.LOWER_PENALTY, { amount = 1 })
        end

        local staked = 0
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.portion == CB.PORTION.STAKE then staked = staked + line.amount end
        end

        local closing = Env.players[3].PlayerData.money.bank
            + Env.players[1].PlayerData.money.bank
            + Env.players[1].PlayerData.money.cash

        -- What must be conserved is money in hand plus money in escrow.
        -- 10000 was staked before the opening measurement was taken.
        eq(closing + staked, opening + 10000,
            'no value may be created by cycling the penalty')
    end)

    it('refuses to lower a penalty to or above its current figure', function()
        local s, f, c = seededImprove()
        falsy(s.amendments.improve(f.creator, c.id, CB.AMENDMENT.LOWER_PENALTY, { amount = 10000 }))
        falsy(s.amendments.improve(f.creator, c.id, CB.AMENDMENT.LOWER_PENALTY, { amount = 99999 }))
    end)

    it('refuses improvements from anyone but the creator', function()
        local s, f, c = seededImprove()
        local ok, err = s.amendments.improve(f.hunter, c.id, CB.AMENDMENT.EXTEND_DEADLINE, { seconds = 60 })
        falsy(ok)
        eq(err, CB.ERR.NOT_PARTICIPANT)
    end)
end)

describe('amendment guards', function()
    local function competitive()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { slots = {
                { baseline = { cash = 1000 } }, { baseline = { cash = 1000 } },
                { baseline = { cash = 1000 } },
            } },
        })
        s.contracts.accept(f.hunter, c.id, false)
        return s, f, c
    end

    it('refuses to switch to exclusive while several hunters hold it', function()
        local s, f, c = competitive()
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd' })
        local second = s.identity.resolve(4)
        s.contracts.accept(second, c.id, false)

        local proposal = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.CHANGE_MODE,
            { mode = CB.MODE.EXCLUSIVE })
        truthy(proposal)
        s.amendments.respond(f.hunter, proposal.id, true)
        local ok = s.amendments.respond(second, proposal.id, true)
        falsy(ok, 'exclusive means one hunter; the contract cannot land in a state it forbids')
        eq(s.storage.readContract(c.id).mode, CB.MODE.COMPETITIVE)
    end)

    it('refuses to empty the slot hunters are competing for', function()
        local s, f, c = competitive()
        local proposal = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.REDUCE_REWARD, { slot = 1 })
        truthy(proposal)
        local ok = s.amendments.respond(f.hunter, proposal.id, true)
        falsy(ok, 'the live slot must stay funded')
        eq(s.escrow.moneyValue(c.id, { slot = 1 }), 1000, 'still funded')
    end)

    it('allows withdrawing a later slot nobody is competing for', function()
        local s, f, c = competitive()
        local proposal = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.REDUCE_REWARD, { slot = 3 })
        truthy(s.amendments.respond(f.hunter, proposal.id, true))
        eq(s.escrow.moneyValue(c.id, { slot = 3 }), 0, 'returned to the creator')
        eq(s.escrow.moneyValue(c.id, { slot = 1 }), 1000, 'the live slot is untouched')
    end)

    it('binds a hunter who joins after a proposal, only once they respond', function()
        local s, f, c = competitive()
        local proposal = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.CHANGE_REASON,
            { reason = 'new reason' })

        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd' })
        local second = s.identity.resolve(4)
        s.contracts.accept(second, c.id, false)

        local _, _, outcome = s.amendments.respond(f.hunter, proposal.id, true)
        eq(outcome, 'pending', 'the newcomer has not agreed yet')
        local _, _, final = s.amendments.respond(second, proposal.id, true)
        eq(final, 'applied')
    end)

    it('does not let a hunter who left keep a veto', function()
        local s, f, c = competitive()
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd' })
        local second = s.identity.resolve(4)
        s.contracts.accept(second, c.id, false)

        local proposal = s.amendments.propose(f.creator, c.id, CB.AMENDMENT.CHANGE_REASON,
            { reason = 'new reason' })
        s.contracts.abandon(second, c.id)

        local _, _, outcome = s.amendments.respond(f.hunter, proposal.id, true)
        eq(outcome, 'applied', 'the remaining participants are enough')
    end)
end)

describe('bailout timing', function()
    it('cannot be bought while a handover is under way', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } }, bailoutAmount = 10000,
        })
        s.contracts.accept(f.hunter, c.id, false)

        for _, src in ipairs({ 1, 2, 3 }) do
            Env.players[src]._coords = { x = 10.0, y = 10.0, z = 30.0 }
        end
        Env.players[2].PlayerData.metadata.ishandcuffed = true
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))

        local ok, err = s.bailout.buy(f.target, c.id)
        falsy(ok, 'the hunter has them in hand; no buying out from there')
        eq(err, CB.ERR.BAD_STATE)
        eq(Env.players[2].PlayerData.money.bank, 20000, 'and nothing was charged')
    end)
end)


--- What the reward builder is offered. The server has escrowed items and
--- weapons since the first commit; these cover the reading of the inventory
--- that lets the form actually offer them.
describe('reward options', function()
    it('offers the stackable items the creator is carrying', function()
        local s = newStack()
        local f = fixture(s)
        local items = s.app.escrowableItems(f.creator)

        local byName = {}
        for _, item in ipairs(items) do byName[item.name] = item.count end

        eq(byName.lockpick, 5, 'the five lockpicks are offerable')
        eq(byName.black_money, nil, 'dirty money is its own source, not an item')
        eq(byName.WEAPON_PISTOL, nil, 'a weapon is not a stack')
    end)

    it('never offers a blacklisted item', function()
        local s = newStack()
        local f = fixture(s, { creatorInventory = {
            { name = 'handcuffs', count = 2, label = 'Handcuffs' },
            { name = 'lockpick', count = 1, label = 'Lockpick' },
        } })
        for _, item in ipairs(s.app.escrowableItems(f.creator)) do
            falsy(item.name == 'handcuffs', 'handcuffs must never be offered')
        end
    end)

    it('adds up a stack split across inventory slots', function()
        local s = newStack()
        local f = fixture(s, { creatorInventory = {
            { name = 'lockpick', count = 3, slot = 1, label = 'Lockpick' },
            { name = 'lockpick', count = 4, slot = 2, label = 'Lockpick' },
        } })
        local items = s.app.escrowableItems(f.creator)
        eq(#items, 1, 'one offer, not one per slot')
        eq(items[1].count, 7)
    end)

    it('offers weapons one at a time, with only the tail of the serial', function()
        local s = newStack()
        local f = fixture(s, { creatorInventory = {
            { name = 'WEAPON_PISTOL', count = 1, slot = 3, label = 'Pistol',
              metadata = { serial = 'ABC123' } },
            { name = 'WEAPON_PISTOL', count = 1, slot = 4, label = 'Pistol',
              metadata = { serial = 'DEF456' } },
        } })
        local weapons = s.app.escrowableWeapons(f.creator)
        eq(#weapons, 2, 'two objects, not one stack of two')
        eq(weapons[1].slot, 3)
        eq(weapons[2].slot, 4)
        -- Enough to tell them apart in the picker, not enough to publish.
        eq(weapons[1].serial, 'C123')
        eq(weapons[2].serial, 'F456')
    end)

    it('never offers a weapon it could not identify on submit', function()
        local s = newStack()
        -- ox_inventory always sets a slot, so the first of these is a shape
        -- it does not produce today. The guard is for the ones that might:
        -- a differently-shaped build, or a slot that survived a round trip
        -- as a string. Offering either would offer a guaranteed rejection,
        -- since the slot is what names the weapon on submit.
        local f = fixture(s, { creatorInventory = {
            { name = 'WEAPON_KNIFE', count = 1, label = 'Knife' },
            { name = 'WEAPON_SMG', count = 1, slot = 'not a number', label = 'SMG' },
            { name = 'WEAPON_PISTOL', count = 1, slot = '4', label = 'Pistol' },
        } })
        local weapons = s.app.escrowableWeapons(f.creator)
        eq(#weapons, 1, 'only the one whose slot is usable')
        eq(weapons[1].name, 'WEAPON_PISTOL')
        eq(weapons[1].slot, 4, 'and it is offered as a number, whatever it arrived as')
    end)

    it('offers nothing for a player who is not there', function()
        local s = newStack()
        local f = fixture(s)
        f.creator.source = 999   -- nobody
        eq(#s.app.escrowableItems(f.creator), 0)
        eq(#s.app.escrowableWeapons(f.creator), 0)
    end)

    it('falls back to the older export when this build lacks the newer one', function()
        local s = newStack()
        local f = fixture(s)

        -- Not every ox_inventory build has GetInventoryItems, which is the
        -- whole reason readInventory has a chain. Nothing exercised it: the
        -- previous test read an empty inventory successfully rather than
        -- failing a read at all.
        Natives.noGetInventoryItems = true
        local items = s.app.escrowableItems(f.creator)
        Natives.noGetInventoryItems = nil

        truthy(#items > 0, 'the fallback has to actually read something')
        local found = false
        for _, item in ipairs(items) do if item.name == 'lockpick' then found = true end end
        truthy(found, 'the same items, read the other way')
    end)

    it('offers nothing when no inventory export works at all', function()
        local s = newStack()
        local f = fixture(s)

        Natives.noGetInventoryItems, Natives.noGetInventory = true, true
        local items = s.app.escrowableItems(f.creator)
        local weapons = s.app.escrowableWeapons(f.creator)
        Natives.noGetInventoryItems, Natives.noGetInventory = nil, nil

        eq(#items, 0, 'an unreadable inventory offers nothing, rather than throwing')
        eq(#weapons, 0)
    end)
end)


--- App pushes. A phone notification tells a player something happened; it
--- does not move an app they already have open, and the app refreshes only
--- on an unsolicited push.
describe('app pushes', function()
    local function pushesTo(source)
        local out = {}
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-bounty:push' and event.target == source then
                out[#out + 1] = event.args[1] and event.args[1].reason or true
            end
        end
        return out
    end

    it('nudges the creator and the hunter when a contract is accepted', function()
        local s, f, c = seeded({ accept = false })
        Env.clientEvents = {}
        truthy(s.contracts.accept(f.hunter, c.id, false))

        eq(#pushesTo(1), 1, 'the creator card now shows one more operative')
        eq(pushesTo(1)[1], 'accepted')
        eq(#pushesTo(3), 1, 'the hunter has a contract in Mine that was not there')
    end)

    it('does not nudge the target on acceptance', function()
        local s, f, c = seeded({ accept = false })
        Env.clientEvents = {}
        truthy(s.contracts.accept(f.hunter, c.id, false))
        -- A target is not told a contract exists except through the paranoid
        -- alert or an advisory. A push would be a side channel saying one
        -- was just accepted.
        eq(#pushesTo(2), 0, 'the target must learn nothing from a push')
    end)

    it('nudges every party when a contract ends', function()
        local s, f, c = seeded({ bailout = 15000, accept = false })
        Env.clientEvents = {}
        truthy(s.bailout.buy(f.target, c.id))

        eq(#pushesTo(1), 1, 'the creator')
        eq(#pushesTo(2), 1, 'the target, who paid for this one')
        eq(pushesTo(1)[1], CB.STATE.BAILED_OUT, 'the reason is the state it reached')
    end)

    it('nudges a hunter whose contract ended under them', function()
        local s, f, c = seeded()
        -- Accepting already nudged both of them a moment ago, and the floor
        -- is deliberately wider than a test. Clearing it is what a second of
        -- wall clock would do; the floor has its own test below.
        s.notify.clearPush('CREATOR1')
        s.notify.clearPush('HUNTER01')
        Env.clientEvents = {}

        truthy(s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION))
        eq(#pushesTo(3), 1, 'the hunter who collected')
        eq(#pushesTo(1), 1, 'and the client who paid')
    end)

    it('carries no contract data at all', function()
        local s, f, c = seeded({ accept = false })
        Env.clientEvents = {}
        truthy(s.contracts.accept(f.hunter, c.id, false))

        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-bounty:push' then
                local payload = event.args[1] or {}
                local keys = {}
                for key in pairs(payload) do keys[#keys + 1] = key end
                eq(#keys, 1, 'a push carries a reason and nothing else')
                eq(keys[1], 'reason')
            end
        end
    end)

    it('holds a burst to one push per player', function()
        local s, f, c = seeded({ accept = false })
        Env.clientEvents = {}
        -- Two state changes on one contract inside the same second.
        truthy(s.contracts.accept(f.hunter, c.id, false))
        truthy(s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION))
        eq(#pushesTo(1), 1, 'the floor collapses a burst into one refresh')
    end)

    it('sends nothing when pushes are switched off', function()
        local s, f, c = seeded({ accept = false })
        withConfig({ { Config.Notifications, 'PushEnabled', false } }, function()
            Env.clientEvents = {}
            truthy(s.contracts.accept(f.hunter, c.id, false))
            eq(#pushesTo(1), 0, 'an operator who turns this off gets no pushes')
        end)
    end)
end)


--- The startup integration report. An optional integration that is silently
--- absent is the worst case: progression simply stops crediting and nothing
--- anywhere says why.
describe('integration report', function()
    local function report()
        package.loaded['crimson-bounty.server.main'] = nil
        return require('crimson-bounty.server.main')
    end

    local function named(list)
        local out = {}
        for _, entry in ipairs(list) do out[entry.resource] = entry end
        return out
    end

    it('covers every optional resource the config names', function()
        local s = newStack()
        local found = named(report().integrations())

        truthy(found['sc-blackmarket'], 'the progression resource')
        truthy(found['sc-dispatch'], 'the dispatch resource')
        truthy(found['sc-ambulance'], 'a death-state provider')
        truthy(found['MugShotBase64'], 'the headshot renderer')
    end)

    it('follows a renamed resource rather than a hard-coded name', function()
        local s = newStack()
        withConfig({ { Config.Progression, 'Resource', 'my-own-blackmarket' } }, function()
            local found = named(report().integrations())
            truthy(found['my-own-blackmarket'], 'the report reads the config')
            falsy(found['sc-blackmarket'], 'and not a name baked into it')
        end)
    end)

    it('names nothing when the features that need it are switched off', function()
        local s = newStack()
        withConfig({
            { Config.Progression, 'Enabled', false },
            { Config.Advisory, 'UseDispatch', false },
        }, function()
            local found = named(report().integrations())
            falsy(found['sc-blackmarket'], 'progression is off')
            falsy(found['sc-dispatch'], 'dispatch advisories are off')
        end)
    end)

    it('marks a resource the operator asked for as expected', function()
        local s = newStack()
        local found = named(report().integrations())
        -- sc-blackmarket is named directly in the config, so its absence is
        -- a misconfiguration worth warning about.
        truthy(found['sc-blackmarket'].configured, 'a configured resource')
        -- The death-state list offers alternatives; only one need be present,
        -- so neither is individually expected.
        falsy(found['sc-ambulance'].configured, 'one of several alternatives')
    end)

    it('reports without throwing whether or not anything is installed', function()
        local s = newStack()
        local main = report()

        -- Mutated in place, and handed back through the harness. Assigning
        -- a new table here left a later suite holding the old one, which is
        -- one test quietly changing what another measures.
        local states = Natives.resourceStates
        for name in pairs(states) do states[name] = nil end
        truthy(main.reportIntegrations(), 'nothing installed')

        Natives.resetResourceStates()
        truthy(main.reportIntegrations(), 'everything installed')
    end)
end)


--- A queued buyout that loses a race. LOCKED means the contract is mid-claim,
--- not that it resolved: refunding there made the target buy out again for a
--- race they had not lost.
describe('bailout races', function()
    local function queued()
        local s = newStack()
        local f = fixture(s)
        Env.players[3].PlayerData.money.bank = 50000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } }, bailoutAmount = 15000,
        })
        truthy(s.contracts.accept(f.hunter, c.id, false))
        -- A hunter is engaged, so the buyout queues rather than settling.
        truthy(s.bailout.buy(f.target, c.id))
        eq(s.storage.readContract(c.id).bailout_queued_at ~= nil, true)
        Env.time = Env.time + Config.Bailout.ProcessingDelaySeconds + 1
        return s, f, c
    end

    it('waits rather than refunding while a claim is in flight', function()
        local s, f, c = queued()
        local paid = Env.players[2].PlayerData.money.bank

        -- Mid-claim: the contract sits in COMPLETING, so resolve returns
        -- LOCKED rather than a terminal state.
        truthy(s.contracts.transition(c.id, CB.STATE.ACCEPTED, CB.STATE.COMPLETING, 'claiming'))
        eq(s.bailout.processQueue(), 0, 'nothing settles this tick')

        eq(Env.players[2].PlayerData.money.bank, paid, 'and the premium is not handed back')
        local row = s.storage.readContract(c.id)
        truthy(row.bailout_queued_at, 'the buyout is still queued')
        eq(row.bailout_attempts, 1, 'the attempt is counted')
    end)

    it('settles once the claim clears without completing', function()
        local s, f, c = queued()
        truthy(s.contracts.transition(c.id, CB.STATE.ACCEPTED, CB.STATE.COMPLETING, 'claiming'))
        eq(s.bailout.processQueue(), 0)

        -- The claim fell through — the hunter's proof was rejected — and the
        -- contract went back to accepted.
        truthy(s.contracts.transition(c.id, CB.STATE.COMPLETING, CB.STATE.ACCEPTED, 'claim_failed'))
        eq(s.bailout.processQueue(), 1, 'the buyout the target paid for goes through')
        eq(s.storage.readContract(c.id).state, CB.STATE.BAILED_OUT)
    end)

    it('refunds when the hunter actually completes first', function()
        local s, f, c = queued()
        local before = Env.players[2].PlayerData.money.bank

        truthy(s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION))
        eq(s.bailout.processQueue(), 0, 'the contract is genuinely over')

        eq(Env.players[2].PlayerData.money.bank, before + 15000,
            'a race the target lost returns their premium')
        falsy(s.storage.readContract(c.id).bailout_queued_at, 'and clears the queue')
    end)

    it('gives up and refunds if the claim never clears', function()
        local s, f, c = queued()
        local before = Env.players[2].PlayerData.money.bank
        truthy(s.contracts.transition(c.id, CB.STATE.ACCEPTED, CB.STATE.COMPLETING, 'claiming'))

        -- A claim interrupted by a crash leaves the contract completing for
        -- good. The target's money is already spent, so it cannot wait
        -- forever.
        for _ = 1, Config.Bailout.MaxSettleAttempts do s.bailout.processQueue() end

        eq(Env.players[2].PlayerData.money.bank, before + 15000, 'refunded in the end')
        falsy(s.storage.readContract(c.id).bailout_queued_at, 'and no longer queued')
        eq(s.storage.readContract(c.id).state, CB.STATE.COMPLETING, 'the stuck contract is untouched')
    end)

    it('does not count attempts against an unqueued buyout', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } }, bailoutAmount = 15000,
        })
        -- Nobody engaged, so this settles immediately and never queues.
        truthy(s.bailout.buy(f.target, c.id))
        falsy(s.storage.readContract(c.id).bailout_attempts)
    end)
end)


--- Masked calls. The server checked that the phone could suppress caller
--- identity, notified the other party, and never placed a call — and the app
--- had no button that reached any of it.
describe('masked calls', function()
    local function threaded(opts)
        opts = opts or {}
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
            anonymous = opts.anonCreator,
        })
        truthy(s.contracts.accept(f.hunter, c.id, opts.anonHunter))
        s.comms.resetCallCache()
        return s, f, c
    end

    it('notifies rather than calling when no export is configured', function()
        local s, f, c = threaded()
        Natives.calls.notifications = {}

        local ok, err, result = s.comms.requestCall(f.hunter, c.id, nil)
        truthy(ok, tostring(err))
        eq(result.placed, false, 'nothing was dialled')

        local said = Natives.calls.notifications[1]
        truthy(said, 'the other party is still told')
        truthy(said.title:find('request'), 'and told it is a request: ' .. said.title)
    end)

    it('places the call when the phone exports one', function()
        local s, f, c = threaded()
        local dialled = {}
        Natives.callExport = function(_, caller, number, anonymous)
            dialled = { caller = caller, number = number, anonymous = anonymous }
            return true
        end

        withConfig({ { Config.Relay, 'CallExport',
                       { resource = 'lb-phone', export = 'StartCall' } } }, function()
            s.comms.resetCallCache()
            Natives.calls.notifications = {}

            local ok, err, result = s.comms.requestCall(f.hunter, c.id, nil)
            truthy(ok, tostring(err))
            eq(result.placed, true, 'the call was placed')

            eq(dialled.caller, 3, 'from the caller, resolved server-side')
            eq(dialled.number, '555-1', "to the callee's own number, read server-side")
            eq(dialled.anonymous, false)

            local said = Natives.calls.notifications[1]
            truthy(said.title:find('Incoming'), 'and it says a call is coming: ' .. said.title)
        end)

        Natives.callExport = nil
    end)

    it('asks the phone to suppress identity for an anonymous party', function()
        local s, f, c = threaded({ anonCreator = true })
        local anonymous = nil
        Natives.callExport = function(_, _, _, anon) anonymous = anon return true end

        withConfig({ { Config.Relay, 'CallExport',
                       { resource = 'lb-phone', export = 'StartCall' } } }, function()
            s.comms.resetCallCache()
            truthy(s.comms.requestCall(f.hunter, c.id, nil))
            eq(anonymous, true, 'the creator being called chose to be anonymous')
        end)

        Natives.callExport = nil
    end)

    it('refuses to place one that would unmask a number somebody hid', function()
        local s, f, c = threaded({ anonCreator = true })
        local dialled = false
        Natives.callExport = function() dialled = true return true end

        withConfig({
            { Config.Relay, 'CallExport', { resource = 'lb-phone', export = 'StartCall' } },
            { Natives, 'phoneConfig', { AnonymousCalls = false } },
        }, function()
            s.comms.resetCallCache()
            s.comms.resetMaskingCache()
            local ok, err = s.comms.requestCall(f.hunter, c.id, nil)
            -- The whole request is refused, not degraded to an unmasked call.
            falsy(ok, 'a call that reveals a hidden number is not placed')
            eq(err, CB.ERR.BAD_STATE)
            falsy(dialled, 'and nothing was dialled')
        end)

        Natives.callExport = nil
        s.comms.resetMaskingCache()
    end)

    it('falls back to a notification when the named export does not exist', function()
        local s, f, c = threaded()
        withConfig({ { Config.Relay, 'CallExport',
                       { resource = 'lb-phone', export = 'NoSuchExport' } } }, function()
            s.comms.resetCallCache()
            Natives.calls.notifications = {}

            local ok, err, result = s.comms.requestCall(f.hunter, c.id, nil)
            truthy(ok, tostring(err))
            eq(result.placed, false, 'an export this build lacks is not a call')
            truthy(Natives.calls.notifications[1], 'the other party is still told')
        end)
    end)

    it('does not re-probe a phone that has no call export', function()
        local s, f, c = threaded()
        local probes = 0
        withConfig({ { Config.Relay, 'CallExport',
                       { resource = 'nope-not-started', export = 'StartCall' } } }, function()
            s.comms.resetCallCache()
            for _ = 1, 3 do
                if not s.comms.callPlacer() then probes = probes + 1 end
            end
        end)
        eq(probes, 3, 'it answers every time')
    end)

    it('will not dial an anonymous party a phone cannot mask', function()
        local s, f, c = threaded({ anonCreator = true })
        local dialled = false
        Natives.callExport = function() dialled = true return true end

        withConfig({
            { Config.Relay, 'CallExport', { resource = 'lb-phone', export = 'StartCall' } },
            { Natives, 'phoneConfig', { AnonymousCalls = false } },
        }, function()
            s.comms.resetCallCache()
            s.comms.resetMaskingCache()

            -- placeCall directly, past the request-level check, because it
            -- is a public function and the guard has to hold on its own —
            -- not only because something upstream happened to refuse first.
            falsy(s.comms.placeCall(f.hunter, 'CREATOR1', true),
                'a number somebody paid to hide is not dialled')
            falsy(dialled)

            -- The same call for a party who is not anonymous goes through.
            truthy(s.comms.placeCall(f.hunter, 'CREATOR1', false))
        end)

        Natives.callExport = nil
        s.comms.resetMaskingCache()
    end)

    it('is refused entirely when calls are switched off', function()
        local s, f, c = threaded()
        withConfig({ { Config.Relay, 'AllowMaskedCalls', false } }, function()
            local ok, err = s.comms.requestCall(f.hunter, c.id, nil)
            falsy(ok)
            eq(err, CB.ERR.BAD_STATE)
        end)
    end)
end)


--- What is on the table. readOpenAmendments was read only by the expiry
--- sweep, so a change could be proposed and the other party had no way to
--- see one waiting, let alone answer it.
describe('open amendments', function()
    local function proposed(opts)
        opts = opts or {}
        local s = newStack()
        local f = fixture(s)
        Env.players[3].PlayerData.money.bank = 50000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
            anonymous = opts.anonCreator,
        })
        truthy(s.contracts.accept(f.hunter, c.id, opts.anonHunter))
        local p = s.amendments.propose(
            opts.by == 'hunter' and f.hunter or f.creator, c.id,
            CB.AMENDMENT.SHORTEN_DEADLINE, { seconds = 600 })
        truthy(p, 'the proposal should be made')
        return s, f, c, p
    end

    it('shows the other party what has been proposed', function()
        local s, f, c = proposed()
        local open, err = s.amendments.openFor(f.hunter, c.id)
        truthy(open, tostring(err))
        eq(#open, 1)
        eq(open[1].kind, CB.AMENDMENT.SHORTEN_DEADLINE)
        eq(open[1].payload.seconds, 600, 'and what it actually changes')
        eq(open[1].mine, false, 'it is not theirs')
        eq(open[1].answered, false, 'and they have not answered')
    end)

    it('marks the proposer their own proposal', function()
        local s, f, c = proposed()
        local open = s.amendments.openFor(f.creator, c.id)
        eq(open[1].mine, true)
        eq(open[1].answered, true, 'proposing is agreeing')
        eq(open[1].waiting, 1, 'one other party still to answer')
    end)

    it('does not name an anonymous creator who proposed it', function()
        local s, f, c = proposed({ anonCreator = true })
        local open = s.amendments.openFor(f.hunter, c.id)
        eq(open[1].proposer, 'The client',
            'a proposal is not a hole in anonymity')
        falsy(tostring(open[1].proposer):find('Vic'))
    end)

    it('names an anonymous hunter by their alias, never their name', function()
        local s, f, c = proposed({ anonHunter = true, by = 'hunter' })
        local open = s.amendments.openFor(f.creator, c.id)
        truthy(tostring(open[1].proposer):find('Operative'),
            'the alias they are known by: ' .. tostring(open[1].proposer))
        falsy(tostring(open[1].proposer):find('Rook'))
        falsy(tostring(open[1].proposer):find('HUNTER01'))
    end)

    it('shows nobody outside the contract anything', function()
        local s, f, c = proposed()
        local outsider = Env.addPlayer({ source = 5, citizenid = 'NOSY0001',
            license = 'license:n', firstname = 'Nos', lastname = 'Ey' })
        local open, err = s.amendments.openFor(s.identity.resolve(5), c.id)
        falsy(open, 'an outsider learns nothing')
        eq(err, CB.ERR.NOT_PARTICIPANT)
    end)

    it('stops showing one that has been answered', function()
        local s, f, c, p = proposed()
        truthy(s.amendments.respond(f.hunter, p.id, true))
        eq(#s.amendments.openFor(f.creator, c.id), 0, 'a settled question is closed')
    end)

    it('stops showing one that expired', function()
        local s, f, c, p = proposed()
        Env.time = Env.time + Config.Amendments.ProposalExpirySeconds + 1
        eq(s.amendments.expire(), 1)
        eq(#s.amendments.openFor(f.creator, c.id), 0)
    end)

    it('shows nothing on a contract with no proposals', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 1000 } },
        })
        local open = s.amendments.openFor(f.creator, c.id)
        truthy(open, 'an empty list, not an error')
        eq(#open, 0)
    end)
end)


--- The four spec promises the code did not keep, now that it does.

describe('a handover cannot be retried in a loop', function()
    local AT = { x = 300.0, y = 300.0, z = 30.0 }

    local function armed()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(s.contracts.accept(f.hunter, c.id, false))
        for _, src in ipairs({ 1, 2, 3 }) do Env.players[src]._coords = AT end
        Env.players[2].PlayerData.metadata.ishandcuffed = true
        return s, f, c
    end

    it('tells the client to come when a handover starts', function()
        local s, f, c = armed()
        Natives.calls.notifications = {}
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))

        local told = false
        for _, note in ipairs(Natives.calls.notifications) do
            if tostring(note.title):find('Handover') then told = true end
        end
        truthy(told, 'the creator has to be present for the whole countdown')
    end)

    it('refuses to re-arm straight after a failure', function()
        local s, f, c = armed()
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))

        -- The client walks off and the grace budget runs out.
        Env.players[1]._coords = { x = 3000.0, y = 3000.0, z = 30.0 }
        for _ = 1, 10 do s.kidnap.tick(Config.Kidnap.MaxTotalGraceMs) end
        eq(s.kidnap.activeCount(), 0, 'the handover failed')

        Env.players[1]._coords = AT
        local ok, err = s.kidnap.arm(c.id, 'HUNTER01')
        falsy(ok, 'a failed handover cannot be restarted immediately')
        eq(err, CB.ERR.BAD_STATE)
    end)

    it('lets them try again once the cooldown has passed', function()
        local s, f, c = armed()
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))
        Env.players[1]._coords = { x = 3000.0, y = 3000.0, z = 30.0 }
        for _ = 1, 10 do s.kidnap.tick(Config.Kidnap.MaxTotalGraceMs) end

        Env.players[1]._coords = AT
        Env.time = Env.time + Config.Kidnap.RearmCooldownSeconds + 1
        truthy(s.kidnap.arm(c.id, 'HUNTER01'), 'the target is still fair game afterwards')
    end)

    it('tells the hunter why it failed', function()
        local s, f, c = armed()
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))
        Env.players[1]._coords = { x = 3000.0, y = 3000.0, z = 30.0 }
        Natives.calls.notifications = {}
        for _ = 1, 10 do s.kidnap.tick(Config.Kidnap.MaxTotalGraceMs) end

        local said = ''
        for _, note in ipairs(Natives.calls.notifications) do
            said = said .. tostring(note.content)
        end
        truthy(said:find('client did not arrive'),
            'rather than leaving them to assume the script ate it: ' .. said)
    end)
end)

describe('a photo is not kept forever', function()
    local function recorded(s, f, c)
        s.ledger.record(s.storage.readContract(c.id), 'HUNTER01',
                        'https://cdn.fivemanage.com/proof.png', CB.FULFILMENT.ELIMINATION, {})
    end

    it('drops the reference once the window has passed', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 1000 } },
        })
        recorded(s, f, c)

        truthy(s.storage.readLedger('HUNTER01', 10)[1].photo_ref, 'kept at first')

        Env.time = Env.time + (Config.Ledger.PhotoRetentionDays * 86400) + 1
        truthy(s.ledger.forgetOldPhotos() > 0, 'something was forgotten')

        local row = s.storage.readLedger('HUNTER01', 10)[1]
        truthy(row, 'the row itself stays — the record is the point of the ledger')
        falsy(row.photo_ref, 'but the photo of somebody\'s corpse does not')
    end)

    it('keeps a photo inside the window', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 1000 } },
        })
        recorded(s, f, c)

        Env.time = Env.time + 60
        eq(s.ledger.forgetOldPhotos(), 0)
        truthy(s.storage.readLedger('HUNTER01', 10)[1].photo_ref)
    end)

    it('keeps them forever when the window is zero', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 1000 } },
        })
        recorded(s, f, c)

        withConfig({ { Config.Ledger, 'PhotoRetentionDays', 0 } }, function()
            Env.time = Env.time + (365 * 86400)
            eq(s.ledger.forgetOldPhotos(), 0, 'an operator who asks for that gets it')
            truthy(s.storage.readLedger('HUNTER01', 10)[1].photo_ref)
        end)
    end)

    it('forgets in every backend', function()
        for _, name in ipairs({ 'memory', 'json', 'mysql' }) do
            local store = name == 'mysql'
                and (function()
                    require('crimson-bounty.tests.harness.mysql_exec').install(Natives)
                    package.loaded['crimson-bounty.server.storage.mysql'] = nil
                    local m = require('crimson-bounty.server.storage.mysql')
                    m.open()
                    return m
                end)()
                or (function()
                    package.loaded['crimson-bounty.server.storage.' .. name] = nil
                    Natives.files = {}
                    local m = require('crimson-bounty.server.storage.' .. name)
                    m.open()
                    return m
                end)()

            store.writeLedger({ cid = 'A', contract_id = 'c1', role = 'hunter',
                                resolved_at = 100, photo_ref = 'https://x/y.png' })
            eq(store.forgetLedgerPhotos(1000), 1, name .. ': one row forgotten')
            falsy(store.readLedger('A', 10)[1].photo_ref, name .. ': and it is gone')
        end
    end)
end)

describe('a player the app is closed to can still buy out', function()
    local function officer()
        local s = newStack()
        local f = fixture(s, { targetJob = { name = 'trooper', type = 'leo', onduty = true } })
        Env.players[2].PlayerData.money.bank = 100000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } }, bailoutAmount = 15000,
        })
        truthy(c, 'a contract on an officer')

        Env.commands = {}
        require('crimson-bounty.server.bridges').installCommands(s)
        return s, f, c
    end

    it('is barred from the app in the first place', function()
        local s, f, c = officer()
        falsy(s.app.canUseApp(2), 'the job gate is why this command exists')
    end)

    it('lists what is out on them', function()
        local s, f, c = officer()
        Env.chat = {}
        Env.commands[Config.Bailout.Command](2, {})

        local said = ''
        for _, line in ipairs(Env.chat) do said = said .. line.text .. '\n' end
        truthy(said:find(c.id, 1, true), 'the contract: ' .. said)
        truthy(said:find('15000', 1, true), 'and what it costs')
    end)

    it('buys it out', function()
        local s, f, c = officer()
        Env.commands[Config.Bailout.Command](2, { c.id })

        eq(Env.players[2].PlayerData.money.bank, 85000, 'charged the premium')
        eq(s.storage.readContract(c.id).state, CB.STATE.BAILED_OUT)
    end)

    it('will not buy out somebody else contract', function()
        local s, f, c = officer()
        Env.chat = {}
        -- The creator running it against their own contract: they are not
        -- its target, so there is nothing here for them.
        Env.commands[Config.Bailout.Command](1, { c.id })

        eq(s.storage.readContract(c.id).state, CB.STATE.ACTIVE, 'untouched')
        local said = ''
        for _, line in ipairs(Env.chat) do said = said .. line.text end
        truthy(said:find('Nothing is out on you'), said)
    end)

    it('refuses an id that is not one', function()
        local s, f, c = officer()
        for _, bogus in ipairs({ '../etc', 'ct99999999', 'x' }) do
            Env.commands[Config.Bailout.Command](2, { bogus })
        end
        eq(Env.players[2].PlayerData.money.bank, 100000, 'nothing was charged')
        eq(s.storage.readContract(c.id).state, CB.STATE.ACTIVE)
    end)
end)


--- The handler, not the helpers.
---
--- rewardOptions is the whole server-to-UI contract for the reward builder,
--- and everything tested about it was tested one layer below: the helpers
--- were covered and the handler that assembles their output, applies the
--- gate and the rate limit, and names the caps was not.
describe('the rewardOptions handler', function()
    --- Fire a registered net event as a player, and read the reply.
    local function call(name, source, payload)
        local fire = Env.events['crimson-bounty:' .. name]
        truthy(fire, 'no handler registered for ' .. name)

        Env.clientEvents = {}
        _G.source = source
        fire(payload or {})
        _G.source = nil

        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-bounty:result' then return event.args[1] end
        end
        return nil
    end

    it('answers with what the creator holds and what the server allows', function()
        local s = newStack()
        local f = fixture(s)

        local reply = call('rewardOptions', 1)
        truthy(reply, 'the handler must reply')
        truthy(reply.ok, 'and succeed for an ordinary player')

        local data = reply.data
        eq(data.cash, 100000, 'their cash')
        eq(data.bank, 100000, 'their bank')
        eq(data.dirty, 50000, 'their dirty money')

        truthy(#data.items > 0, 'the items they carry')
        truthy(#data.weapons > 0, 'and the weapons')

        -- The caps the form builds against. Every one of these is read by
        -- ui/app.js, so a missing key is a form that cannot bound itself.
        eq(data.caps.slots, Config.Limits.MaxPayoutSlots)
        eq(data.caps.maxStacks, Config.Sources.item.maxStacks)
        eq(data.caps.maxPerStack, Config.Sources.item.maxPerStack)
        eq(data.caps.maxWeapons, Config.Sources.weapon.max)
        eq(data.caps.bonusPercent, Config.Bonus.maxPercent)
    end)

    it('never sends a full weapon serial', function()
        local s = newStack()
        local f = fixture(s)
        local data = call('rewardOptions', 1).data

        for _, weapon in ipairs(data.weapons) do
            falsy(tostring(weapon.serial):find('ABC123', 1, true),
                'the tail is enough to tell two apart; the whole thing is an identifier')
            truthy(#tostring(weapon.serial) <= 4, 'four characters at most')
        end
    end)

    it('tells a barred job nothing at all', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.job = { name = 'police', type = 'leo', onduty = true }

        local reply = call('rewardOptions', 1)
        falsy(reply.ok, 'the job gate applies to this handler like every other')
        eq(reply.err, CB.ERR.BLACKLISTED_JOB)
        falsy(reply.data)
    end)

    it('is rate limited', function()
        local s = newStack()
        local f = fixture(s)

        local refused = false
        for _ = 1, 40 do
            local reply = call('rewardOptions', 1)
            if reply and not reply.ok and reply.err == CB.ERR.RATE_LIMITED then refused = true end
        end
        truthy(refused, 'an unbounded inventory read is a free way to load the server')
    end)

    it('echoes the correlation id so replies do not cross', function()
        local s = newStack()
        local f = fixture(s)
        local reply = call('rewardOptions', 1, { __rid = 4242 })
        eq(reply.rid, 4242, 'two requests in flight must not resolve into each other')
    end)
end)


--- The escrow-line ceiling bounds what a contract still holds, not what it
--- has ever held. Counting settled lines and hunters' stakes refused a
--- legitimate top-up on any contract that had already paid out.
describe('topping up a contract that has paid out', function()
    local function carrying()
        local inventory = {}
        for i = 1, 20 do
            inventory[i] = { name = 'part_' .. i, count = 500, slot = i, label = 'Part ' .. i }
        end
        return inventory
    end

    local function itemList(n)
        local list = {}
        for i = 1, n do list[i] = { name = 'part_' .. i, count = 1 } end
        return list
    end

    it('does not count what it has already paid out', function()
        local s = newStack()
        local f = fixture(s, { creatorInventory = carrying() })
        Env.players[3].PlayerData.money.bank = 50000

        -- Fifty lines across five payouts: at the ceiling minus ten.
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { slots = {
                { baseline = { items = itemList(10) } }, { baseline = { items = itemList(10) } },
                { baseline = { items = itemList(10) } }, { baseline = { items = itemList(10) } },
                { baseline = { items = itemList(10) } },
            } },
            penaltyAmount = 5000,
        })
        truthy(c)
        truthy(s.contracts.accept(f.hunter, c.id, false))

        -- One payout collected: ten of those lines are settled now, and the
        -- hunter's stake is a line the creator never put up.
        truthy(s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION))

        local ok, err = s.amendments.addEscrow(f.creator,
            c.id, { baseline = { items = itemList(10) } })
        truthy(ok, 'a top-up on a contract that has paid out must not be refused: '
            .. tostring(err))
    end)

    it('still refuses one that would take it past the ceiling', function()
        local s = newStack()
        local f = fixture(s, { creatorInventory = carrying() })
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { slots = {
                { baseline = { items = itemList(10) } }, { baseline = { items = itemList(10) } },
                { baseline = { items = itemList(10) } }, { baseline = { items = itemList(10) } },
                { baseline = { items = itemList(10) } },
            } },
        })
        truthy(c)

        -- Fifty held plus ten is the ceiling exactly; the next ten is over.
        truthy(s.amendments.addEscrow(f.creator, c.id, { baseline = { items = itemList(10) } }))
        local ok, err = s.amendments.addEscrow(f.creator,
            c.id, { baseline = { items = { { name = 'part_11', count = 1 } } } })
        falsy(ok, 'the ceiling still holds')
        eq(err, CB.ERR.INVALID_REWARD)
    end)
end)

--- Switching characters.
---
--- On this server the selector's /relog calls the framework's Logout, which
--- fires QBCore:Server:OnPlayerUnload. The player stays connected and keeps
--- their source, but the character this resource has been dealing with is
--- gone. Nothing listened for it, so everything keyed on that citizen id was
--- orphaned.
describe('a character switch', function()
    local function switched(s, source)
        local fire = Env.events['local:QBCore:Server:OnPlayerUnload']
            or Env.events['QBCore:Server:OnPlayerUnload']
        truthy(fire, 'the unload event must be handled')
        _G.source = source
        fire(source)
        _G.source = nil
    end

    local function installed()
        local s = newStack()
        local f = fixture(s)
        require('crimson-bounty.server.bridges').install(s)
        return s, f
    end

    it('ends the session of the character that left', function()
        local s, f = installed()
        -- fixture() resolved them, which notes an observed session. A
        -- watched one has to replace it before the length is measurable.
        s.identity.endSession('CREATOR1')
        truthy(s.identity.beginSession('CREATOR1', false))
        Env.time = Env.time + 600
        truthy(s.identity.sessionMinutes('CREATOR1'), 'the session is running')

        switched(s, 1)
        falsy(s.identity.sessionMinutes('CREATOR1'),
            'a character that logged out is not still sitting in a session')
    end)

    it('releases an armed handover rather than leaking its slot', function()
        local s, f = installed()
        local AT = { x = 400.0, y = 400.0, z = 30.0 }
        for _, src in ipairs({ 1, 2, 3 }) do Env.players[src]._coords = AT end
        Env.players[2].PlayerData.metadata.ishandcuffed = true

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c)
        truthy(s.contracts.accept(f.hunter, c.id, false))
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))
        eq(s.kidnap.activeCount(), 1)

        -- The hunter switches characters mid-handover.
        switched(s, 3)
        eq(s.kidnap.activeCount(), 0,
            'the countdown slot is global, so a leaked one is taken from everybody')
    end)

    it('does not hand the next character a fresh set of cooldowns', function()
        local s, f = installed()

        -- Spend the create bucket as this character.
        local before = s.identity.resolve(1)
        truthy(s.ratelimit.check(before, 'create'))
        truthy(s.ratelimit.check(before, 'create'))
        falsy(s.ratelimit.check(before, 'create'), 'the bucket is spent')

        switched(s, 1)

        -- The same player, now a different character on the same account.
        Env.players[1].PlayerData.citizenid = 'CREATOR2'
        Env.byCitizen['CREATOR2'] = 1
        local after = s.identity.resolve(1)
        eq(after.cid, 'CREATOR2', 'a different character')
        eq(after.account, before.account, 'the same account')

        falsy(s.ratelimit.check(after, 'create'),
            'switching characters is a menu, and must not be a way to reset a cooldown')
    end)

    it('still separates two genuinely different accounts', function()
        local s, f = installed()
        local creator = s.identity.resolve(1)
        truthy(s.ratelimit.check(creator, 'create'))
        truthy(s.ratelimit.check(creator, 'create'))
        falsy(s.ratelimit.check(creator, 'create'))

        -- Someone else entirely, with their own licence.
        local other = s.identity.resolve(3)
        truthy(other.account ~= creator.account, 'a different account')
        truthy(s.ratelimit.check(other, 'create'),
            'one player must not spend another player is allowance')
    end)

    it('refuses when there is no identity to key on', function()
        local s = newStack()
        falsy(s.ratelimit.check(nil, 'create'),
            'no identity is not a licence to act')
        falsy(s.ratelimit.check({}, 'create'))
        falsy(s.ratelimit.check(42, 'create'))
    end)

    it('drops the damage recorded against the character that left', function()
        local s, f = installed()
        Env.players[3]._coords = { x = 10.0, y = 10.0, z = 30.0 }
        Env.players[2]._coords = { x = 11.0, y = 10.0, z = 30.0 }
        Env.players[2]._health = 200
        s.death.watch('TARGET01', 2, true)
        Env.players[2]._health = 60
        s.death.recordDamage(3, 2, 123456)
        truthy(s.death.recordFor('TARGET01', 'HUNTER01'))

        switched(s, 2)
        falsy(s.death.recordFor('TARGET01', 'HUNTER01'),
            'a hunter must not inherit the next character to hold that id')
    end)

    it('retires the target handles the character was given', function()
        local s, f = installed()
        local handle = s.app.mintTargetHandle('CREATOR1', 'TARGET01')
        truthy(handle)
        eq(s.app.resolveTargetHandle('CREATOR1', handle), 'TARGET01')

        switched(s, 1)
        falsy(s.app.resolveTargetHandle('CREATOR1', handle),
            'a handle minted for a character that left must not still resolve')
    end)

    it('survives an unload for a source holding nobody', function()
        local s, f = installed()
        local ok = pcall(switched, s, 9999)
        truthy(ok, 'an unload for a source this resource never saw must not throw')
    end)

    it('lets the next character start clean', function()
        local s, f = installed()
        switched(s, 1)

        -- The same player, now someone else entirely.
        Env.players[1].PlayerData.citizenid = 'CREATOR2'
        Env.byCitizen['CREATOR2'] = 1

        local actor = s.identity.resolve(1)
        truthy(actor, 'the new character resolves')
        eq(actor.cid, 'CREATOR2')
        truthy(s.ratelimit.check('CREATOR2', 'search'),
            'and starts with their own buckets')
    end)
end)
