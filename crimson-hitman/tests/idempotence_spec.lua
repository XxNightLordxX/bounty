--- Idempotence and replay safety.
---
--- Players double-tap. A phone app on a bad connection resends. FiveM
--- redelivers a net event the client never saw acknowledged. So every
--- request that moves money or changes state arrives twice sooner or later,
--- and the second arrival must either be refused or do nothing at all — but
--- never a second time.
---
--- The other suites assert an outcome: this one asserts a non-outcome. Each
--- operation is driven twice with a byte-identical payload and the whole
--- world is compared across the two — every purse, every inventory stack,
--- every contract row, every escrow line, every hitman row, every amendment,
--- the pending-payout queue, the ledger, the live kidnap countdowns and the
--- outstanding photo tokens. Then something unrelated is allowed to happen
--- and the same request is sent a third time, because a guard that keys off
--- "nothing has changed since" stops guarding the moment anything does.
---
--- Two things are deliberately left out of the comparison. Audit rows differ
--- on purpose — a refused replay SHOULD leave a rejection behind, that is
--- how an operator sees somebody hammering a button — and so do
--- notifications. Everything else is state, and state that moves on a replay
--- is a duplicate effect whatever the return value says.

--------------------------------------------------------------------------
-- The world, as one comparable value
--------------------------------------------------------------------------

--- Canonical text for any value: tables are walked with their keys sorted,
--- so two runs of the same world produce the same string regardless of the
--- order pairs() happens to hand them back.
local function write(value, out)
    if type(value) ~= 'table' then
        out[#out + 1] = type(value) .. ':' .. tostring(value)
        return
    end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    out[#out + 1] = '{'
    for _, key in ipairs(keys) do
        out[#out + 1] = tostring(key) .. '='
        write(value[key], out)
        out[#out + 1] = ','
    end
    out[#out + 1] = '}'
end

--- Everything a replay could move.
---
--- Money is counted where it can be: pockets and inventory for what players
--- hold, escrow lines for what the resource holds, and the buyout fields on
--- a non-terminal contract for the window where a premium has been charged
--- and is neither. That last one is not decoration — a queued buyout is
--- money in no pocket and no escrow line, and an accounting that cannot see
--- it reports a replay as theft when the replay was refused correctly.
local function world(stack)
    local snapshot = {
        purses = {}, contracts = {}, escrow = {}, hitmen = {},
        amendments = {}, pending = {}, ledger = {}, kidnaps = {},
    }

    for src, player in pairs(Env.players) do
        local inventory = {}
        for _, entry in ipairs(player._inventory or {}) do
            inventory[entry.name] = (inventory[entry.name] or 0) + (entry.count or 0)
        end
        snapshot.purses[tostring(src)] = {
            cash = player.PlayerData.money.cash,
            bank = player.PlayerData.money.bank,
            inventory = inventory,
        }
    end

    for _, contract in ipairs(stack.storage.allContracts()) do
        snapshot.contracts[contract.id] = contract

        local lines = {}
        for _, line in ipairs(stack.storage.readEscrow(contract.id)) do
            lines[line.id] = line
        end
        snapshot.escrow[contract.id] = lines

        local hitmen = {}
        for _, hitman in ipairs(stack.storage.readHitmen(contract.id)) do
            hitmen[hitman.id] = hitman
            -- How far a countdown has run. A second arm that silently
            -- restarts one is not visible in any stored row.
            snapshot.kidnaps[contract.id .. ':' .. hitman.hitman_cid] =
                stack.kidnap.progress(contract.id, hitman.hitman_cid)
        end
        snapshot.hitmen[contract.id] = hitmen
    end

    local db = stack.storage._raw()
    for id, amendment in pairs(db.amendments or {}) do snapshot.amendments[id] = amendment end
    for id, row in pairs(db.pending or {}) do snapshot.pending[tostring(id)] = row end
    for index, entry in ipairs(db.ledger or {}) do snapshot.ledger[index] = entry end

    -- Unspent photo tokens are server state a replay can consume.
    snapshot.photoTokens = stack.photo.tokenCount()
    snapshot.countdowns = stack.kidnap.activeCount()

    local out = {}
    write(snapshot, out)
    return table.concat(out)
end

--- Assert two worlds are the same, and when they are not, point at the
--- difference rather than printing forty kilobytes of it.
local function same(before, after, message)
    if before == after then return end
    local i = 1
    while i <= #before and i <= #after and before:sub(i, i) == after:sub(i, i) do
        i = i + 1
    end
    local from = math.max(1, i - 70)
    error(('%s\n      before: ...%s\n      after:  ...%s'):format(
        message, before:sub(from, i + 130), after:sub(from, i + 130)), 2)
end

--------------------------------------------------------------------------
-- Driving a request more than once
--------------------------------------------------------------------------

--- An action by two people who have nothing to do with the contract under
--- test, so the third replay below lands in a world that has moved on.
---
--- A guard written as "refuse unless everything is exactly as I left it" is
--- indistinguishable from a correct one until something else happens.
local function elsewhere(stack)
    Env.addPlayer({ source = 7, citizenid = 'PASSERB1', license = 'license:g1',
        cash = 50000, bank = 50000 })
    Env.addPlayer({ source = 8, citizenid = 'PASSERB2', license = 'license:g2',
        cash = 50000, bank = 50000 })
    local other = stack.contracts.create(stack.identity.resolve(7), {
        targetCid = 'PASSERB2', reason = 'A different quarrel entirely',
        reward = { baseline = { cash = 1000 } },
    })
    truthy(other, 'the unrelated action must actually happen, or it proves nothing')
    return other
end

--- Run `request` three times: twice back to back, then once more after an
--- unrelated action. Returns what each call answered, so a test can also
--- say how the replay was refused.
local function replay(stack, label, request)
    local first = { request() }
    local afterOne = world(stack)

    local second = { request() }
    same(afterOne, world(stack),
        label .. ': the second identical request changed the world')

    elsewhere(stack)
    local settled = world(stack)

    local third = { request() }
    same(settled, world(stack),
        label .. ': a third identical request, after an unrelated action, changed the world')

    return first, second, third
end

--------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------

local function place(stack, actor, opts)
    opts = opts or {}
    return stack.contracts.create(actor, {
        targetCid = 'TARGET01', reason = 'Unpaid debt',
        mode = opts.mode or CH.MODE.COMPETITIVE,
        reward = opts.reward or { baseline = { cash = 5000 }, bonus = { cash = 2500 } },
        penaltyAmount = opts.penalty,
        bailoutAmount = opts.bailout,
    })
end

--- A contract, its creator, its target and a hitman.
local function seeded(opts)
    local stack = newStack()
    local f = fixture(stack)
    local contract = place(stack, f.creator, opts)
    truthy(contract, 'fixture contract')
    return stack, f, contract
end

--- The page's own path in, so a double-tap is tested as the player makes
--- it and not only as the module sees it.
local function call(name, src, payload)
    local fire = Env.events['crimson-hitman:' .. name]
    if not fire then return nil, 'no handler registered for ' .. name end
    Env.clientEvents = {}
    _G.source = src
    fire(payload or {})
    _G.source = nil
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:result' then return event.args[1] end
    end
    return nil
end

--------------------------------------------------------------------------
-- Accepting
--------------------------------------------------------------------------

describe('accepting twice', function()
    it('takes one hitman row and one stake, whatever the second tap does', function()
        local s, f, c = seeded({ penalty = 2000 })
        local first, second = replay(s, 'accept', function()
            return s.contracts.accept(f.hitman, c.id, false)
        end)
        truthy(first[1], 'the first acceptance stands')
        falsy(second[1], 'the second is refused rather than absorbed')
        eq(second[2], CH.ERR.ALREADY_HOLDING)

        local rows = 0
        for _, hitman in ipairs(s.storage.readHitmen(c.id)) do
            if hitman.hitman_cid == 'HITMAN01' then rows = rows + 1 end
        end
        eq(rows, 1, 'one acceptance, one hitman row')
        eq(Env.players[3].PlayerData.money.bank, 5000 - 2000, 'and one stake')
    end)

    it('is refused the same way through the app', function()
        -- The flood gate and the accept bucket both allow three in a burst,
        -- so the second tap really does reach the module here rather than
        -- being turned away at the door.
        local s, f, c = seeded()
        local one = call('accept', 3, { id = c.id, anonymous = false })
        truthy(one and one.ok, tostring(one and one.err))

        local before = world(s)
        local two = call('accept', 3, { id = c.id, anonymous = false })
        falsy(two and two.ok, 'the app refuses the double-tap')
        truthy(two and two.err ~= CH.ERR.RATE_LIMITED,
            'and refuses it on the state, not on the rate limit: ' .. tostring(two and two.err))
        same(before, world(s), 'a double-tapped accept changed the world')
    end)

    it('does not let the anonymity fee be charged twice', function()
        local s = newStack()
        local f = fixture(s)
        withConfig({ { Config.Anonymity, 'HitmanFee', 1000 },
                     { Config.Anonymity, 'FeeAccount', 'bank' } }, function()
            local c = place(s, f.creator)
            replay(s, 'anonymous accept', function()
                return s.contracts.accept(f.hitman, c.id, true)
            end)
            eq(Env.players[3].PlayerData.money.bank, 5000 - 1000,
                'one acceptance is one fee')
        end)
    end)

    --- W022: the fee went by the truthiness of `anonymous` while the row
    --- and the audit went by `== true`, so 1, 'true' or even 'false' was
    --- charged for anonymity and recorded under a name.
    for _, sent in ipairs({ 'false', 1, 'true' }) do
        it(('charges nothing for an anonymous of %s, and records them named'):format(tostring(sent)),
            function()
                local s = newStack()
                local f = fixture(s)
                withConfig({ { Config.Anonymity, 'HitmanFee', 1000 },
                             { Config.Anonymity, 'FeeAccount', 'bank' } }, function()
                    local c = place(s, f.creator)
                    local reply = call('accept', 3, { id = c.id, anonymous = sent, penaltyAmount = 0,
                        shown = { hitmanFee = 1000, feeAccount = 'bank' } })
                    truthy(reply and reply.ok, tostring(reply and reply.err))
                    eq(Env.players[3].PlayerData.money.bank, 5000, 'no fee for a name')
                    eq(s.storage.readHitman(c.id, 'HITMAN01').anon, false, 'recorded named')
                end)
            end)
    end
end)

--------------------------------------------------------------------------
-- Cancelling
--------------------------------------------------------------------------

describe('cancelling twice', function()
    it('returns the escrow once', function()
        local s, f, c = seeded()
        local first, second = replay(s, 'cancel', function()
            return s.contracts.cancel(f.creator, c.id)
        end)
        truthy(first[1])
        falsy(second[1])
        eq(Env.players[1].PlayerData.money.cash, 100000,
            'the escrow came home once, not twice')
        eq(s.storage.readContract(c.id).state, CH.STATE.CANCELLED)
    end)

    it('is refused the same way through the app', function()
        local s, f, c = seeded()
        truthy((call('cancel', 1, { id = c.id }) or {}).ok)
        local before = world(s)
        local two = call('cancel', 1, { id = c.id })
        falsy(two and two.ok)
        same(before, world(s), 'a double-tapped cancel changed the world')
    end)
end)

describe('abandoning twice', function()
    it('forfeits the stake once', function()
        local s, f, c = seeded({ penalty = 2000 })
        truthy(s.contracts.accept(f.hitman, c.id, false))

        local first, second = replay(s, 'abandon', function()
            return s.contracts.abandon(f.hitman, c.id)
        end)
        truthy(first[1])
        falsy(second[1])
        eq(second[2], CH.ERR.NOT_PARTICIPANT)
        eq(Env.players[1].PlayerData.money.bank, 100000 + 2000,
            'the creator collects one forfeited stake')
        eq(Env.players[3].PlayerData.money.bank, 3000, 'and the hitman loses it once')
    end)
end)

--------------------------------------------------------------------------
-- Buying out
--------------------------------------------------------------------------

describe('buying out twice', function()
    it('charges the premium once when it settles immediately', function()
        local s, f, c = seeded({ bailout = 15000 })
        local first, second = replay(s, 'bailout', function()
            return s.bailout.buy(f.target, c.id)
        end)
        truthy(first[1])
        falsy(second[1])
        eq(Env.players[2].PlayerData.money.bank, 20000 - 15000, 'one premium')
        eq(s.storage.readContract(c.id).state, CH.STATE.BAILED_OUT)
    end)

    --- The window that matters. With a hitman engaged the buyout is charged
    --- now and settled later, so for the length of the delay the contract is
    --- still live and still names the target — which is exactly what the
    --- second tap sees. Nothing in the contract's state says "already bought
    --- out"; only the queue fields do.
    it('charges the premium once while the settlement is still queued', function()
        local s, f, c = seeded({ bailout = 15000 })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        truthy(Config.Bailout.ProcessingDelaySeconds > 0,
            'this test is only meaningful where buyouts are delayed')

        local first, second, third = replay(s, 'queued bailout', function()
            return s.bailout.buy(f.target, c.id)
        end)
        truthy(first[1], 'the first buyout is taken')
        falsy(second[1], 'the second is refused while the first is still queued')
        eq(second[2], CH.ERR.BUYOUT_PENDING,
            'the one refusal that means it is working; telling the target '
            .. '"not right now" points them at the wrong thing entirely')
        falsy(third[1])

        eq(Env.players[2].PlayerData.money.bank, 20000 - 15000,
            'the target paid one premium, not three')
        eq(s.storage.readContract(c.id).bailout_paid_amount, 15000,
            'and one is queued')
        eq(s.bailout.queuedCount(), 1)
    end)

    it('settles a queued buyout once however often the queue is processed', function()
        local s, f, c = seeded({ bailout = 15000 })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        truthy(s.bailout.buy(f.target, c.id))
        Env.advance(Config.Bailout.ProcessingDelaySeconds + 1)

        eq(s.bailout.processQueue(), 1, 'the queue settles it')
        local afterOne = world(s)
        eq(s.bailout.processQueue(), 0, 'and has nothing left to settle')
        same(afterOne, world(s), 'processing the queue again moved money')
    end)

    --- The second tap landing while the first waits on the database, here
    --- inside its read of who is engaged, before either has recorded
    --- anything: both passed "already paid", and the target was charged
    --- twice for one queue record. The buy holds the contract's key from
    --- before its first read, so the second is refused before it charges.
    it('refuses a second buy that lands while the first is still running', function()
        local s, f, c = seeded({ bailout = 15000 })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local real, fired, inner = s.storage.readHitmen, false, nil
        s.storage.readHitmen = function(...)
            if not fired then
                fired = true
                inner = table.pack(s.bailout.buy(f.target, c.id))
            end
            return real(...)
        end
        local ok, err = s.bailout.buy(f.target, c.id)
        s.storage.readHitmen = real
        truthy(ok, tostring(err))
        truthy(fired, 'the second tap landed inside the first')
        eq(inner[1], false)
        eq(inner[2], CH.ERR.BUSY, 'refused as busy, before anything was charged')
        eq(Env.players[2].PlayerData.money.bank + Env.players[2].PlayerData.money.cash,
            40000 - 15000, 'the target paid one premium')
        eq(s.bailout.queuedCount(), 1, 'and one is queued')
    end)

    it('is stopped at the door by the rate limiter through the app', function()
        -- Said out loud because it is a different defence: the bailout
        -- bucket is one token per minute, so the app never gets to ask the
        -- module a second time. That is a real protection, but it is not
        -- idempotence, and staff may raise the bucket from the admin panel:
        -- the module's own guards, tested above, are what hold then.
        local s, f, c = seeded({ bailout = 15000 })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local one = call('bailout', 2, { id = c.id })
        truthy(one and one.ok, tostring(one and one.err))

        local before = world(s)
        local two = call('bailout', 2, { id = c.id })
        falsy(two and two.ok)
        eq(two and two.err, CH.ERR.RATE_LIMITED,
            'the limiter is what answers the second tap here')
        same(before, world(s), 'a double-tapped buyout changed the world')
    end)
end)

--------------------------------------------------------------------------
-- Withdrawing part of a reward
--------------------------------------------------------------------------

describe('withdrawing the same escrow line twice', function()
    it('pays the line back once', function()
        local s, f, c = seeded({
            reward = { baseline = { cash = 5000, bank = 3000 }, bonus = { cash = 1000 } },
        })
        local bonusLine
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.portion == CH.PORTION.BONUS then bonusLine = line.id end
        end
        truthy(bonusLine, 'a bonus line to withdraw')

        local first, second = replay(s, 'withdrawReward', function()
            return s.contracts.withdrawReward(f.creator, c.id, { bonusLine })
        end)
        truthy(first[1])
        falsy(second[1], 'a settled line is not the creator to take back again')
        eq(second[2], CH.ERR.BAD_STATE)
        eq(Env.players[1].PlayerData.money.cash, 100000 - 5000,
            'the bonus came back exactly once')
    end)

    it('treats the same line named twice in one request as one line', function()
        -- Not a replay across requests but the same mistake inside one, and
        -- the arithmetic that decides whether a slot is left unfunded has to
        -- agree with it.
        local s, f, c = seeded({
            reward = { baseline = { cash = 5000 }, bonus = { cash = 1000 } },
        })
        local bonusLine
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.portion == CH.PORTION.BONUS then bonusLine = line.id end
        end
        truthy(s.contracts.withdrawReward(f.creator, c.id, { bonusLine, bonusLine, bonusLine }))
        eq(Env.players[1].PlayerData.money.cash, 100000 - 5000,
            'named three times, returned once')
    end)
end)

--------------------------------------------------------------------------
-- Claiming a payout slot
--------------------------------------------------------------------------

describe('claiming the same payout slot twice', function()
    it('pays a single-slot contract once', function()
        local s, f, c = seeded()
        truthy(s.contracts.accept(f.hitman, c.id, false))

        local first, second = replay(s, 'claimSlot', function()
            return s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        end)
        truthy(first[1])
        falsy(second[1], 'the contract is finished; there is nothing left to claim')
        eq(Env.players[3].PlayerData.money.cash, 5000 + 5000,
            'the hitman is paid the baseline once')
        eq(s.storage.readContract(c.id).slots_claimed, 1)
    end)

    it('does not let a multi-slot contract pay two slots to one tap', function()
        -- The interesting shape: after the first claim the contract is back
        -- in ACCEPTED with a slot still on offer, so nothing about the
        -- contract's state refuses the replay. The per-hitman cooldown is
        -- what does.
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE,
            reward = { slots = {
                { baseline = { cash = 5000 } },
                { baseline = { cash = 3000 } },
            } },
        })
        truthy(c)
        truthy(s.contracts.accept(f.hitman, c.id, false))

        local first, second = replay(s, 'claimSlot (multi)', function()
            return s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        end)
        truthy(first[1])
        falsy(second[1], 'the same hitman cannot collect twice on one report')
        eq(s.storage.readContract(c.id).next_slot, 2, 'one slot advanced')
        eq(Env.players[3].PlayerData.money.cash, 5000 + 5000, 'one payout')
    end)
end)

--------------------------------------------------------------------------
-- Amendments
--------------------------------------------------------------------------

describe('proposing the same amendment twice', function()
    it('leaves one proposal on the contract', function()
        local s, f, c = seeded()
        truthy(s.contracts.accept(f.hitman, c.id, false))

        local first, second = replay(s, 'propose', function()
            return s.amendments.propose(f.creator, c.id, CH.AMENDMENT.CHANGE_REASON,
                { reason = 'A different quarrel' })
        end)
        truthy(first[1], 'the first proposal is made')
        falsy(second[1], 'the second is refused rather than queued alongside it')
        eq(#s.storage.readOpenAmendments(c.id), 1,
            'one open proposal, so one approval decides it')
    end)
end)

describe('approving the same amendment twice', function()
    it('applies a change once', function()
        local s, f, c = seeded()
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local proposal = s.amendments.propose(f.creator, c.id,
            CH.AMENDMENT.CHANGE_REASON, { reason = 'A different quarrel' })
        truthy(proposal)

        local first, second = replay(s, 'respond', function()
            return s.amendments.respond(f.hitman, proposal.id, true)
        end)
        truthy(first[1])
        eq(first[3], 'applied')
        falsy(second[1], 'a decided proposal is no longer answerable')
        eq(s.storage.readAmendment(proposal.id).outcome, 'applied')
    end)

    it('does not return escrow twice for an agreed cancellation', function()
        local s, f, c = seeded()
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local proposal = s.amendments.propose(f.creator, c.id, CH.AMENDMENT.CANCEL, {})
        truthy(proposal)

        local first, second = replay(s, 'respond (cancel)', function()
            return s.amendments.respond(f.hitman, proposal.id, true)
        end)
        truthy(first[1])
        falsy(second[1])
        eq(Env.players[1].PlayerData.money.cash, 100000,
            'the escrow returned exactly once')
        eq(s.storage.readContract(c.id).state, CH.STATE.CANCELLED)
    end)

    it('records one approval when a vote is still pending', function()
        -- The half that does not end the proposal. Answering twice must not
        -- count as two of the votes the proposal is waiting for.
        local s, f, c = seeded()
        Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
            cash = 5000, bank = 5000 })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        truthy(s.contracts.accept(s.identity.resolve(4), c.id, false))
        local proposal = s.amendments.propose(f.creator, c.id,
            CH.AMENDMENT.CHANGE_REASON, { reason = 'A different quarrel' })
        truthy(proposal)

        local first, second = replay(s, 'respond (pending)', function()
            return s.amendments.respond(f.hitman, proposal.id, true)
        end)
        eq(first[3], 'pending')
        eq(second[3], 'pending', 'still waiting on the other hitman')
        eq(s.storage.readAmendment(proposal.id).outcome, 'open',
            'one hitman answering twice does not carry the vote')
    end)

    it('lowers a penalty to the same figure once', function()
        local s, f, c = seeded({ penalty = 2000 })
        truthy(s.contracts.accept(f.hitman, c.id, false))

        local first, second = replay(s, 'lower penalty', function()
            return s.amendments.improve(f.creator, c.id,
                CH.AMENDMENT.LOWER_PENALTY, { amount = 500 })
        end)
        truthy(first[1])
        falsy(second[1], 'the penalty is already 500; there is nothing to lower')
        eq(Env.players[3].PlayerData.money.bank, 5000 - 500,
            'the hitman got the difference back once')
    end)
end)

--------------------------------------------------------------------------
-- Informant data
--------------------------------------------------------------------------

describe('buying informant data twice', function()
    --- A sticky reveal is idempotence with a price on it: inside the reroll
    --- lock the second purchase returns the first answer and takes nothing,
    --- which is also what stops the button being used to walk the roster.
    it('charges once inside the reroll lock and names the same operative', function()
        local s, f, c = seeded()
        truthy(s.contracts.accept(f.hitman, c.id, false))
        -- The sampler has to have seen the hitman on the target, or there is
        -- nobody in the pool and the purchase reveals nothing.
        Env.players[2]._coords = { x = 500.0, y = 500.0, z = 30.0 }
        Env.players[3]._coords = { x = 505.0, y = 500.0, z = 30.0 }

        local first, second, third = replay(s, 'informant', function()
            return s.informant.buy(f.creator, c.id)
        end)
        truthy(first[1], tostring(first[2]))
        truthy(second[1], 'the replay is answered, not refused')
        eq(second[3].found, first[3].found, 'with the same answer')
        eq(second[3].name or second[3].description,
           first[3].name or first[3].description, 'naming the same operative')
        truthy(third[1])
        eq(Env.players[1].PlayerData.money.bank, 100000 - Config.Informant.Cost,
            'and one purchase was paid for')
    end)

    --- The second tap landing while the first waits on the database, before
    --- the first has remembered the reveal: it found no record and was
    --- charged again for the same sticky answer, counted once.
    it('refuses a second purchase that lands while the first is still running', function()
        local s, f, c = seeded()
        -- Wired as main.lua wires it, with the contracts module for its key.
        s.informant.init({ storage = s.storage, identity = s.identity, audit = s.audit,
            death = s.death, contracts = s.contracts })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local real, fired, inner = s.storage.readHitmen, false, nil
        s.storage.readHitmen = function(...)
            if not fired then
                fired = true
                inner = table.pack(s.informant.buy(f.creator, c.id))
            end
            return real(...)
        end
        local ok, err = s.informant.buy(f.creator, c.id)
        s.storage.readHitmen = real
        truthy(ok, tostring(err))
        truthy(fired, 'the second tap landed inside the first')
        eq(inner[2], CH.ERR.BUSY, 'refused as busy, before anything was charged')
        eq(Env.players[1].PlayerData.money.bank, 100000 - Config.Informant.Cost,
            'one purchase was paid for')
        eq(s.storage.readReveal(c.id, 'CREATOR1').purchases, 1, 'and one is counted')
    end)
end)

--------------------------------------------------------------------------
-- Placing
--------------------------------------------------------------------------

describe('two creators naming one target at the same moment', function()
    --- The target's limit is counted from a read, an await on mysql: two
    --- creates in flight each counted the other as not there.
    it('places one and refuses the other as busy', function()
        local s = newStack()
        local f = fixture(s)
        Config.Limits.MaxActiveContractsPerTarget = 1
        Env.addPlayer({ source = 4, citizenid = 'CREATOR2', license = 'license:eee',
            cash = 100000, bank = 100000, firstname = 'Lou', lastname = 'Kane' })
        local other = s.identity.resolve(4)
        local function place(actor)
            return s.contracts.create(actor, {
                targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.EXCLUSIVE,
                reward = { baseline = { cash = 5000 } },
            })
        end
        local real, fired, inner = s.storage.contractsNaming, false, nil
        s.storage.contractsNaming = function(...)
            if not fired then
                fired = true
                inner = table.pack(place(other))
            end
            return real(...)
        end
        local first, err = place(f.creator)
        s.storage.contractsNaming = real
        truthy(first, tostring(err))
        truthy(fired, 'the second create landed inside the first')
        falsy(inner[1], 'the target had room for one')
        eq(inner[2], CH.ERR.BUSY)
        eq(#s.storage.contractsNaming('TARGET01'), 1, 'one contract on the target')
        eq(Env.players[4].PlayerData.money.cash, 100000, 'and nothing taken from the other')
    end)
end)

--------------------------------------------------------------------------
-- Death reports
--------------------------------------------------------------------------

describe('the same death reported twice', function()
    --- iDied is a client net event, which is the one shape of request the
    --- server has no say in the delivery of at all. A redelivered report
    --- must not open a second pending completion, because each one is a
    --- capture token waiting to be issued.
    it('opens one pending completion', function()
        local s, f, c = seeded()
        truthy(s.contracts.accept(f.hitman, c.id, false))
        Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
        Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
        Env.players[2]._health = (Env.players[2]._health or 200) - 60
        s.death.recordDamage(3, 2, 123456)
        Env.players[2].PlayerData.metadata.isdead = true

        local first, second, third = replay(s, 'iDied', function()
            return s.death.onVictimReport(2)
        end)
        eq(first[1], 1, 'the kill is attributed to one contract')
        eq(second[1], 1, 'and the replay still reports the same one contract')
        eq(third[1], 1)

        truthy(s.death.getPending(c.id, 'HITMAN01'), 'one completion is pending')
        truthy(s.photo.issue(f.hitman, c.id), 'and it is worth one token')
        eq(s.photo.tokenCount(), 1, 'one token, however many reports arrived')
    end)
end)

--------------------------------------------------------------------------
-- Photo proof
--------------------------------------------------------------------------

describe('submitting the same photo token twice', function()
    local URL = 'https://cdn.fivemanage.com/proof.png'

    local function killed()
        local s, f, c = seeded()
        Config.Completion.ExtraPhotoHosts = { 'cdn.fivemanage.com' }
        s.photo.loadAllowedHosts()
        truthy(s.contracts.accept(f.hitman, c.id, false))

        Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
        Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
        Env.players[2]._health = (Env.players[2]._health or 200) - 60
        s.death.recordDamage(3, 2, 123456)
        Env.players[2].PlayerData.metadata.isdead = true
        eq(s.death.onVictimReport(2), 1, 'the kill is attributed')

        local token = s.photo.issue(f.hitman, c.id)
        truthy(token, 'a capture token')
        return s, f, c, token
    end

    it('pays for the kill once', function()
        local s, f, c, token = killed()
        local first, second = replay(s, 'submitPhoto', function()
            return s.photo.submit(f.hitman, token, URL)
        end)
        truthy(first[1], tostring(first[2]))
        falsy(second[1], 'the token is spent')
        eq(second[2], CH.ERR.TOKEN_INVALID)
        eq(Env.players[3].PlayerData.money.cash, 5000 + 5000, 'one baseline')
        -- One completion writes one row per participant; a replay would
        -- write another three.
        eq(#s.storage._raw().ledger, 3, 'and one set of ledger entries')
    end)

    it('does not let a reissued token pay a second time', function()
        -- Issuing again is legitimate — a player whose phone lost the first
        -- one asks for another — but the kill behind it has already been
        -- paid, so the fresh token must buy nothing.
        local s, f, c, token = killed()
        truthy(s.photo.submit(f.hitman, token, URL))
        local before = world(s)

        local reissued, err = s.photo.issue(f.hitman, c.id)
        falsy(reissued, 'nothing is pending any more: ' .. tostring(reissued))
        -- Its only collection paid, the contract is closed, and that is
        -- what the hitman on it is told (W031): a kill pending on a closed
        -- contract went on minting tokens for nothing.
        eq(err, CH.ERR.ALREADY_SETTLED,
            'the contract it paid is closed, and the hitman on it is told so')
        same(before, world(s), 'reissuing a token after the payout moved something')
    end)
end)

describe('verifying the same kill twice with kill photos off', function()
    it('pays for the kill once', function()
        local s, f, c = seeded()
        truthy(s.contracts.accept(f.hitman, c.id, false))
        Config.Completion.KillPhotos = false

        Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
        Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
        Env.players[2]._health = (Env.players[2]._health or 200) - 60
        s.death.recordDamage(3, 2, 123456)
        Env.players[2].PlayerData.metadata.isdead = true
        eq(s.death.onVictimReport(2), 1, 'the kill is attributed')

        local first, second = replay(s, 'verifyKill', function()
            return s.photo.verifyAtScene(f.hitman, c.id)
        end)
        truthy(first[1], tostring(first[2]))
        falsy(second[1], 'the kill is claimed')
        eq(second[2], CH.ERR.ALREADY_SETTLED,
            'the contract it paid is closed, and the hitman on it is told so')
        eq(Env.players[3].PlayerData.money.cash, 5000 + 5000, 'one baseline')
        eq(#s.storage._raw().ledger, 3, 'and one set of ledger entries')
    end)

    --- The second tap arriving while the first waits on the database, at
    --- every await it makes, before the statement and after it: on mysql
    --- with every await a yield (tests/harness/await_scheduler.lua). Every
    --- outcome has to be one of the taps paid and the other refused.
    it('pays for the kill once however the two taps interleave on mysql', function()
        local Scheduler = require('crimson-hitman.tests.harness.await_scheduler')
        local function tap(x, rid)
            _G.source = 3
            Env.events['crimson-hitman:verifyKill']({ id = x.c.id, __rid = rid })
            _G.source = nil
            return true
        end
        local res = Scheduler.explore({
            name = 'verifyKill x verifyKill, one hitman',
            build = function()
                -- The switches as this resource ships them, contracts
                -- placed under 'either' as on a server that ran it.
                local main, m = Scheduler.boot(function()
                    require('crimson-hitman.tests.harness.shipped').apply()
                    Config.Completion.Fulfilment = 'either'
                end)
                local f = Scheduler.fixture(m)
                local c = assert(m.contracts.create(f.creator, {
                    targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
                    reward = { baseline = { cash = 5000 } },
                }))
                assert(m.contracts.accept(f.hitman, c.id, false))
                Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
                Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
                Env.players[2]._health = 140
                m.death.recordDamage(3, 2, 123456)
                Env.players[2].PlayerData.metadata.isdead = true
                assert(m.death.onVictimReport(2) == 1, 'the kill is attributed')
                return main, m, { f = f, c = c }
            end,
            first = function(_, x) return tap(x, 801) end,
            second = function(_, x) return tap(x, 802) end,
        })
        truthy(res.depth > 0, 'a verification waits on the database')
        eq(#res.findings, 0, Scheduler.report(res))
    end)
end)

--------------------------------------------------------------------------
-- Kidnap countdowns
--------------------------------------------------------------------------

describe('arming the same kidnap twice', function()
    local AT = { x = 200.0, y = 200.0, z = 30.0 }

    local function together()
        local s, f, c = seeded()
        truthy(s.contracts.accept(f.hitman, c.id, false))
        for _, src in ipairs({ 1, 2, 3 }) do
            Env.players[src]._coords = { x = AT.x, y = AT.y, z = AT.z }
        end
        Env.players[2].PlayerData.metadata.ishandcuffed = true
        return s, f, c
    end

    it('runs one countdown', function()
        local s, f, c = together()
        local first, second = replay(s, 'armKidnap', function()
            return s.kidnap.arm(c.id, 'HITMAN01')
        end)
        truthy(first[1])
        truthy(second[1], 'the second tap is absorbed, not refused')
        eq(s.kidnap.activeCount(), 1, 'one countdown')
    end)

    --- The reason the snapshot carries countdown progress at all. A second
    --- arm that quietly restarts the timer is invisible in every stored row
    --- and in every balance: the hitman holds the target longer, the
    --- creator waits longer, and a client that re-sends on a tick never
    --- finishes a delivery at all.
    it('does not restart a countdown that is already running', function()
        local s, f, c = together()
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))

        local ticks = math.floor((Config.Kidnap.CountdownSeconds * 1000)
            / Config.Kidnap.TickMs / 2)
        for _ = 1, ticks do s.kidnap.tick(Config.Kidnap.TickMs) end

        local halfway = s.kidnap.progress(c.id, 'HITMAN01')
        truthy(halfway and halfway.elapsed > 0, 'the countdown is under way')

        truthy(s.kidnap.arm(c.id, 'HITMAN01'), 'arming again is absorbed')
        eq(s.kidnap.progress(c.id, 'HITMAN01').elapsed, halfway.elapsed,
            'and does not put the countdown back to the start')
    end)

    it('pays one delivery when the countdown finishes', function()
        local s, f, c = together()
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))

        local completions = {}
        local ticks = math.floor((Config.Kidnap.CountdownSeconds * 1000)
            / Config.Kidnap.TickMs) + 2
        for _ = 1, ticks do
            for _, done in ipairs(s.kidnap.tick(Config.Kidnap.TickMs)) do
                completions[#completions + 1] = done
            end
        end
        eq(#completions, 1, 'one delivery')
        eq(Env.players[3].PlayerData.money.cash, 5000 + 7500,
            'baseline plus bonus, once')
    end)
end)

--------------------------------------------------------------------------
-- Muting a thread
--------------------------------------------------------------------------

describe('muting the same thread twice', function()
    it('is one mute, and one unmute undoes it', function()
        local s, f, c = seeded()
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local handle = s.comms.threads(f.creator, c.id)[1].handle

        local first, second, third = replay(s, 'muteThread', function()
            return call('muteThread', 1, { id = c.id, thread = handle, muted = true })
        end)
        for _, reply in ipairs({ first[1], second[1], third[1] }) do
            truthy(reply and reply.ok, 'a repeat is the answer already given, not a refusal')
            eq(reply.data.muted, true)
        end

        local rows, audited = 0, 0
        for _, row in pairs(s.storage._raw().mutes) do
            if row.cid == 'CREATOR1' then rows = rows + 1 end
        end
        s.audit.flush()
        for _, row in ipairs(s.storage.readAudit()) do
            if row.action == 'relay_muted' then audited = audited + 1 end
        end
        eq(rows, 1, 'one thread, one person, one mute')
        eq(audited, 1, 'and one entry for it, not one per tap')

        truthy(call('muteThread', 1, { id = c.id, thread = handle, muted = false }).ok)
        falsy(s.storage.readMute(c.id .. '|HITMAN01', 'CREATOR1'),
            'a mute is not a counter that takes as many unmutes as taps')
    end)
end)

describe('what this file leaves out', function()
    --- The blocks above name thirteen actions. The resource has more, and a
    --- hand-kept list has no way of noticing the next one — which is the
    --- failure mode journey_spec's coverage guard had before it was derived
    --- from App.handlers.
    ---
    --- So: every action a player can repeat is either tested above or named
    --- here with the reason repeating it is not an idempotence question. The
    --- list is checked in both directions, so an exemption for an action that
    --- no longer exists, or for one that IS tested above, is a failure.
    local TESTED = {
        accept = true, cancel = true, abandon = true, bailout = true,
        withdrawReward = true, propose = true, respondAmendment = true,
        informant = true, submitPhoto = true, verifyKill = true, armKidnap = true,
        muteThread = true,
    }

    --- Repeating these is a legitimate thing to do, not a double effect.
    local BY_DESIGN = {
        addEscrow = 'a creator may top up a reward as many times as they like; '
            .. 'each call adds what it says it adds',
        improve   = 'extending a deadline twice extends it twice, which is the '
            .. 'point. Raising the bonus twice escrows only the difference, '
            .. 'and refuses a percentage already reached',
        revise    = 'editing a contract to the same values twice leaves the '
            .. 'same values',
        sendMessage = 'two messages is two messages',
        requestCall = 'asking again once the first call is over rings again; asking while '
            .. 'it is live is refused as already_in_call (interaction_spec)',
        endCall = 'hanging up twice: the second finds no call and says so',
        requestPhotoToken = 'a second token deliberately invalidates the '
            .. 'first, so a hitman cannot bank them',
        openPhoto = 'a photo opens once; the second ask is refused as gone, '
            .. 'which photos_spec checks',
        photoDecision = 'a photo is decided on once; the second is refused as '
            .. 'gone and changes nothing, which photos_spec checks',
        -- Reads. Repeating a read is the definition of harmless.
        list = true, mine = true, ledger = true, searchTargets = true,
        browseTargets = true, mugshotImage = true, rewardOptions = true,
        rewardBreakdown = true, amendments = true, threads = true,
        readThread = true, kidnapProgress = true, pageError = true,
        whitelistedView = true,
        whitelistedViewAlerts = 'the same choice again is answered as it is, and written and '
            .. 'audited once (whitelisted_view_spec, "Notify me on the view")',
        -- The handover's meeting point (meeting_spec).
        setMeeting = 'a second set inside 30 seconds is refused as meeting_too_soon and changes '
            .. 'nothing; after them it moves the point ("how often it changes")',
        clearMeeting = 'a second clear finds no point and says so, as no_meeting ("when the '
            .. 'placer clears it")',
        -- Set GPS: a read.
        meetingWaypoint = true,
        -- Covered above under its own name rather than the handler's.
        create = 'covered by "cancelling twice" and the create-spam tests in '
            .. 'contracts_spec',
    }

    it('names every action it does not test', function()
        local source = read_file('crimson-hitman/server/app.lua')
        local missing = {}
        for name in source:gmatch("handler%('([%w]+)'") do
            if not TESTED[name] and not BY_DESIGN[name] then
                missing[#missing + 1] = name
            end
        end
        table.sort(missing)
        eq(#missing, 0,
            'these can be repeated and nothing here says what happens: '
            .. table.concat(missing, ', '))
    end)

    it('does not carry a note for an action that is gone', function()
        local source = read_file('crimson-hitman/server/app.lua')
        local exists = {}
        for name in source:gmatch("handler%('([%w]+)'") do exists[name] = true end

        local stale = {}
        for name in pairs(BY_DESIGN) do
            if not exists[name] then stale[#stale + 1] = name end
        end
        for name in pairs(TESTED) do
            if not exists[name] then stale[#stale + 1] = name end
        end
        table.sort(stale)
        eq(#stale, 0, 'a note about something that no longer exists has '
            .. 'stopped being checked: ' .. table.concat(stale, ', '))
    end)

    it('does not claim both to test an action and to excuse it', function()
        local both = {}
        for name in pairs(TESTED) do
            if BY_DESIGN[name] then both[#both + 1] = name end
        end
        table.sort(both)
        eq(#both, 0, 'an excuse next to a live test is an excuse that could '
            .. 'hide the next gap: ' .. table.concat(both, ', '))
    end)
end)
