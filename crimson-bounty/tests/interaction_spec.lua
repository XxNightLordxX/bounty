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
    it('names a hunter for the creator', function()
        local s, f, c = seeded()
        local ok, err, data = s.informant.buy(f.creator, c.id)
        truthy(ok, tostring(err))
        truthy(data.found)
        eq(data.name, 'Rook Ash')
    end)

    it('is available to the target as well', function()
        local s, f, c = seeded()
        Env.players[2].PlayerData.money.bank = 100000
        local ok, _, data = s.informant.buy(f.target, c.id)
        truthy(ok)
        truthy(data.found)
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
