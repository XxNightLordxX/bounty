--- Contract lifecycle: creation gates, acceptance, the state machine and the
--- conflict rules that keep creator, target and hunter three distinct people.

local function baseReward()
    return { baseline = { cash = 5000 }, bonus = { cash = 2500 } }
end

describe('contract creation', function()
    it('creates a contract and escrows the reward', function()
        local s = newStack()
        local f = fixture(s)
        local contract, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.EXCLUSIVE, reward = baseReward(),
        })
        truthy(contract, 'expected a contract, got ' .. tostring(err))
        eq(contract.state, CB.STATE.ACTIVE)
        eq(Env.players[1].PlayerData.money.cash, 92500, 'baseline and bonus both escrowed')
    end)

    it('refuses a bounty on yourself', function()
        local s = newStack()
        local f = fixture(s)
        local contract, err = s.contracts.create(f.creator, {
            targetCid = 'CREATOR1', reason = 'x', reward = baseReward(),
        })
        falsy(contract)
        eq(err, CB.ERR.SELF_TARGET)
    end)

    it('refuses a bounty on another character of the same account', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[2].PlayerData.license = 'license:aaa' -- same account as creator
        local contract, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = baseReward(),
        })
        falsy(contract, 'alt-account targeting must be blocked')
        eq(err, CB.ERR.SAME_ACCOUNT)
    end)

    it('refuses a target who has barely played', function()
        local s = newStack()
        local f = fixture(s)
        -- Playtime comes from the framework's own metadata, in minutes.
        Env.players[2].PlayerData.metadata.playtime = 60
        local contract, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = baseReward(),
        })
        falsy(contract)
        eq(err, CB.ERR.TARGET_PROTECTED)
    end)

    it('refuses a target who only just connected', function()
        local s = newStack()
        local f = fixture(s)
        s.identity.beginSession('TARGET01')
        local contract, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = baseReward(),
        })
        falsy(contract, 'someone who walked in a moment ago is not fair game')
        eq(err, CB.ERR.TARGET_PROTECTED)

        Env.advance((Config.Immunity.MinTargetSessionMinutes * 60) + 60)
        truthy(s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = baseReward(),
        }), 'and fair game once they have settled in')
    end)

    it('does not refuse everyone when playtime cannot be resolved', function()
        local s = newStack()
        local f = fixture(s)
        -- No provider, no metadata: the rule is skipped, not applied to all.
        Env.players[2].PlayerData.metadata.playtime = nil
        local contract, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = baseReward(),
        })
        truthy(contract, 'a missing playtime source must not stop the resource: ' .. tostring(err))
    end)

    it('rejects a reason containing a link or a phone number', function()
        local s = newStack()
        local f = fixture(s)
        for _, bad in ipairs({ 'join discord.gg/abcd', 'call me 5551234567', 'visit https://x.com' }) do
            local contract = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = bad, reward = baseReward(),
            })
            falsy(contract, 'accepted a bad reason: ' .. bad)
        end
    end)

    it('takes nothing when creation fails', function()
        local s = newStack()
        local f = fixture(s)
        s.contracts.create(f.creator, { targetCid = 'CREATOR1', reason = 'x', reward = baseReward() })
        eq(Env.players[1].PlayerData.money.cash, 100000, 'creator was never charged')
    end)

    it('clamps the bailout premium to a multiple of the escrow', function()
        local s = newStack()
        local f = fixture(s)
        local contract = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = baseReward(),
            bailoutAmount = 10000000,
        })
        truthy(contract)
        -- money escrow is 7500; ceiling is 3x
        eq(contract.bailout_amount, 22500, 'premium clamped to 3x escrow')
    end)

    it('enforces the per-creator contract cap', function()
        local s = newStack()
        local f = fixture(s)
        for i = 1, Config.Limits.MaxActiveContractsPerCreator do
            Env.addPlayer({ source = 10 + i, citizenid = 'TGT0000' .. i, license = 'license:t' .. i })
            local c = s.contracts.create(f.creator, {
                targetCid = 'TGT0000' .. i, reason = 'x', reward = { baseline = { cash = 1000 } },
            })
            truthy(c, 'contract ' .. i .. ' should be created')
        end
        Env.addPlayer({ source = 30, citizenid = 'TGT00009', license = 'license:t9' })
        local extra, err = s.contracts.create(f.creator, {
            targetCid = 'TGT00009', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        falsy(extra, 'cap must hold')
        eq(err, CB.ERR.LIMIT_REACHED)
    end)
end)

describe('acceptance', function()
    local function seeded(mode)
        local s = newStack()
        local f = fixture(s)
        local contract = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = mode or CB.MODE.EXCLUSIVE, reward = baseReward(),
        })
        return s, f, contract
    end

    it('records the hunter and moves the contract to accepted', function()
        local s, f, c = seeded()
        local ok, err = s.contracts.accept(f.hunter, c.id, false)
        truthy(ok, tostring(err))
        eq(s.storage.readContract(c.id).state, CB.STATE.ACCEPTED)
    end)

    it('refuses the creator accepting their own contract', function()
        local s, f, c = seeded()
        local ok, err = s.contracts.accept(f.creator, c.id, false)
        falsy(ok)
        eq(err, CB.ERR.SELF_ACCEPT)
    end)

    it('refuses the target accepting a contract on themselves', function()
        local s, f, c = seeded()
        local ok, err = s.contracts.accept(f.target, c.id, false)
        falsy(ok)
        eq(err, CB.ERR.SELF_TARGET)
    end)

    it('refuses a hunter on the creators account', function()
        local s, f, c = seeded()
        Env.players[3].PlayerData.license = 'license:aaa'
        local hunter = s.identity.resolve(3)
        local ok, err = s.contracts.accept(hunter, c.id, false)
        falsy(ok)
        eq(err, CB.ERR.SAME_ACCOUNT)
    end)

    it('allows exactly one hunter on an exclusive contract', function()
        local s, f, c = seeded(CB.MODE.EXCLUSIVE)
        truthy(s.contracts.accept(f.hunter, c.id, false))
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd' })
        local ok, err = s.contracts.accept(s.identity.resolve(4), c.id, false)
        falsy(ok, 'exclusive means one')
        eq(err, CB.ERR.BAD_STATE)
    end)

    it('allows several hunters on a competitive contract', function()
        local s, f, c = seeded(CB.MODE.COMPETITIVE)
        truthy(s.contracts.accept(f.hunter, c.id, false))
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd' })
        truthy(s.contracts.accept(s.identity.resolve(4), c.id, false))
        eq(#s.storage.readHunters(c.id), 2)
    end)

    it('refuses the same hunter twice', function()
        local s, f, c = seeded(CB.MODE.COMPETITIVE)
        truthy(s.contracts.accept(f.hunter, c.id, false))
        local ok = s.contracts.accept(f.hunter, c.id, false)
        falsy(ok)
    end)
end)

describe('state machine', function()
    it('rejects any transition not declared', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = baseReward(),
        })
        falsy(s.contracts.transition(c.id, CB.STATE.ACTIVE, CB.STATE.COMPLETED, 'illegal'),
            'active cannot jump straight to completed')
        eq(s.storage.readContract(c.id).state, CB.STATE.ACTIVE, 'state unchanged')
    end)

    it('never transitions out of a terminal state', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = baseReward(),
        })
        s.contracts.resolve(c.id, CB.STATE.CANCELLED, 'CREATOR1', nil, 'cancelled')
        falsy(s.contracts.transition(c.id, CB.STATE.CANCELLED, CB.STATE.ACTIVE, 'revive'))
    end)

    it('releases escrow exactly once across repeated resolutions', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = baseReward(),
        })
        eq(Env.players[1].PlayerData.money.cash, 92500)
        s.contracts.resolve(c.id, CB.STATE.CANCELLED, 'CREATOR1', nil, 'cancelled')
        eq(Env.players[1].PlayerData.money.cash, 100000, 'refunded in full')
        local ok, err = s.contracts.resolve(c.id, CB.STATE.CANCELLED, 'CREATOR1', nil, 'cancelled again')
        falsy(ok)
        eq(err, CB.ERR.ALREADY_SETTLED)
        eq(Env.players[1].PlayerData.money.cash, 100000, 'no second refund')
    end)
end)

describe('failure penalty', function()
    local function withPenalty(amount)
        local s = newStack()
        local f = fixture(s)
        Env.players[3].PlayerData.money.bank = 50000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } },
            penaltyAmount = amount,
        })
        return s, f, c
    end

    it('stakes the penalty from the hunter at acceptance', function()
        local s, f, c = withPenalty(10000)
        truthy(s.contracts.accept(f.hunter, c.id, false))
        eq(Env.players[3].PlayerData.money.bank, 40000, 'staked up front, not merely promised')
    end)

    it('refuses acceptance from a hunter who cannot cover the stake', function()
        local s, f, c = withPenalty(10000)
        Env.players[3].PlayerData.money.bank = 100
        Env.players[3].PlayerData.money.cash = 100
        local ok, err = s.contracts.accept(f.hunter, c.id, false)
        falsy(ok)
        eq(err, CB.ERR.INSUFFICIENT)
        eq(s.storage.readContract(c.id).state, CB.STATE.ACTIVE, 'and the contract stays open')
    end)

    it('forfeits the stake to the creator when the hunter walks away', function()
        local s, f, c = withPenalty(10000)
        s.contracts.accept(f.hunter, c.id, false)
        local creatorBefore = Env.players[1].PlayerData.money.bank

        truthy(s.contracts.abandon(f.hunter, c.id))
        eq(Env.players[1].PlayerData.money.bank, creatorBefore + 10000, 'creator keeps the penalty')
        eq(Env.players[3].PlayerData.money.bank, 40000, 'hunter does not get it back')
    end)

    it('returns the stake when the hunter delivers', function()
        local s, f, c = withPenalty(10000)
        s.contracts.accept(f.hunter, c.id, false)
        s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
        eq(Env.players[3].PlayerData.money.bank, 50000, 'stake returned in full')
        eq(Env.players[3].PlayerData.money.cash, 10000, 'and the reward paid')
    end)

    it('forfeits the stake when the contract expires under them', function()
        local s, f, c = withPenalty(10000)
        s.contracts.accept(f.hunter, c.id, false)
        local creatorBefore = Env.players[1].PlayerData.money.bank

        s.contracts.resolve(c.id, CB.STATE.EXPIRED, 'CREATOR1', nil, 'expired')
        eq(Env.players[1].PlayerData.money.bank, creatorBefore + 10000, 'the penalty is the point')
    end)

    it('returns the stake when the creator cancels instead', function()
        local s, f, c = withPenalty(10000)
        s.contracts.accept(f.hunter, c.id, false)
        s.contracts.resolve(c.id, CB.STATE.CANCELLED, 'CREATOR1', nil, 'cancelled')
        eq(Env.players[3].PlayerData.money.bank, 50000, 'not the hunter\'s fault, not their loss')
    end)

    it('never counts a stake as part of the contract reward', function()
        local s, f, c = withPenalty(10000)
        s.contracts.accept(f.hunter, c.id, false)
        eq(s.escrow.moneyValue(c.id), 5000, 'the board shows the reward, not the hunter\'s stake')
        local row = s.projection.contract(s.storage.readContract(c.id), 'HUNTER01')
        eq(row.reward.baseline, 5000)
    end)

    it('does not sweep a stake into a general refund', function()
        local s, f, c = withPenalty(10000)
        s.contracts.accept(f.hunter, c.id, false)
        local creatorBefore = Env.players[1].PlayerData.money.cash

        s.contracts.resolve(c.id, CB.STATE.CANCELLED, 'CREATOR1', nil, 'cancelled')
        eq(Env.players[1].PlayerData.money.cash, creatorBefore + 5000,
            'the creator gets their escrow back and nothing of the stake')
        eq(Env.players[3].PlayerData.money.bank, 50000)
    end)
end)

describe('spam and rollback', function()
    it('throttles create-and-cancel list spam', function()
        local s = newStack()
        local f = fixture(s)
        local first = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        truthy(first)
        s.contracts.resolve(first.id, CB.STATE.CANCELLED, 'CREATOR1', nil, 'cancelled')

        -- A different target, so the cancel throttle is what is being
        -- measured rather than the per-target cooldown.
        Env.addPlayer({ source = 8, citizenid = 'TARGET02', license = 'license:t2' })
        local second, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET02', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        falsy(second, 'cancelling should not be a free way back onto the board')
        eq(err, CB.ERR.RATE_LIMITED)

        Env.advance(Config.Amendments.CancelCooldownSeconds + 10)
        truthy(s.contracts.create(f.creator, {
            targetCid = 'TARGET02', reason = 'x', reward = { baseline = { cash = 1000 } },
        }), 'allowed once the cooldown passes')
    end)

    it('leaves no contract behind when escrow cannot be taken', function()
        local s = newStack()
        local f = fixture(s)
        local before = #s.storage.allContracts()

        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000, items = { { name = 'lockpick', count = 99 } } } },
        })
        falsy(c)
        eq(err, CB.ERR.INSUFFICIENT)
        eq(#s.storage.allContracts(), before, 'no shell row was written')
        eq(Env.players[1].PlayerData.money.cash, 100000, 'and nothing was charged')
    end)
end)

describe('stakes survive every ending', function()
    local function competitiveWithStakes()
        local s = newStack()
        local f = fixture(s)
        Env.players[3].PlayerData.money.bank = 50000
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd', bank = 50000 })
        local second = s.identity.resolve(4)

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } }, penaltyAmount = 10000,
        })
        s.contracts.accept(f.hunter, c.id, false)
        s.contracts.accept(second, c.id, false)
        return s, f, c, second
    end

    it('returns the losing hunters stake when the contract completes', function()
        local s, f, c, second = competitiveWithStakes()
        eq(Env.players[4].PlayerData.money.bank, 40000, 'hunter two staked')

        s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
        eq(s.storage.readContract(c.id).state, CB.STATE.COMPLETED)

        eq(Env.players[3].PlayerData.money.bank, 50000, 'the winner gets their stake back')
        eq(Env.players[4].PlayerData.money.bank, 50000,
            'and so does the hunter who simply lost the race')
    end)

    it('leaves nothing held on a completed contract', function()
        local s, f, c = competitiveWithStakes()
        s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            eq(line.state, CB.ESCROW_STATE.SETTLED,
                ('line %s (%s) stranded on a completed contract'):format(line.id, line.portion))
        end
    end)

    it('refuses an abandon on a contract that has already finished', function()
        local s, f, c, second = competitiveWithStakes()
        s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
        local before = Env.players[1].PlayerData.money.bank

        local ok, err = s.contracts.abandon(second, c.id)
        falsy(ok, 'nothing to abandon once it is over')
        eq(err, CB.ERR.BAD_STATE)
        eq(Env.players[1].PlayerData.money.bank, before,
            'and the creator cannot be handed a stake that was already returned')
    end)

    it('conserves value across a completion with several stakes', function()
        local s, f, c, second = competitiveWithStakes()
        local function total()
            local money = 0
            for _, p in pairs(Env.players) do
                money = money + p.PlayerData.money.cash + p.PlayerData.money.bank
            end
            for _, line in ipairs(s.storage.readEscrow(c.id)) do
                if line.state ~= CB.ESCROW_STATE.SETTLED and CB.MONEY_SOURCES[line.source] then
                    money = money + (line.amount or 0)
                end
            end
            return money
        end

        local opening = total()
        s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
        eq(total(), opening, 'completion must neither create nor destroy value')
    end)
end)

describe('a stake stays at risk until the contract ends', function()
    local function multiSlotWithPenalty()
        local s = newStack()
        local f = fixture(s)
        Env.players[3].PlayerData.money.bank = 50000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { slots = {
                { baseline = { cash = 1000 } },
                { baseline = { cash = 1000 } },
            } },
            penaltyAmount = 10000,
        })
        s.contracts.accept(f.hunter, c.id, false)
        return s, f, c
    end

    it('does not hand the stake back after the first of several payouts', function()
        local s, f, c = multiSlotWithPenalty()
        s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)

        eq(Env.players[3].PlayerData.money.bank, 40000,
            'the hunter is still on the hook for the remaining payout')
        eq(s.storage.readContract(c.id).state, CB.STATE.ACCEPTED)
    end)

    it('still forfeits the stake if they walk away after collecting once', function()
        local s, f, c = multiSlotWithPenalty()
        s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
        local creatorBefore = Env.players[1].PlayerData.money.bank

        s.contracts.abandon(f.hunter, c.id)
        eq(Env.players[1].PlayerData.money.bank, creatorBefore + 10000,
            'collect-then-abandon must not be free')
        eq(Env.players[3].PlayerData.money.bank, 40000)
    end)

    it('returns the stake once the last payout is collected', function()
        local s, f, c = multiSlotWithPenalty()
        s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
        Env.advance(Config.Limits.SlotCooldownSeconds + 1)
        s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)

        eq(s.storage.readContract(c.id).state, CB.STATE.COMPLETED)
        eq(Env.players[3].PlayerData.money.bank, 50000, 'stake returned when the job is done')
        eq(Env.players[3].PlayerData.money.cash, 7000, 'plus both payouts')
    end)
end)

describe('money already promised to someone is not swept away', function()
    it('does not refund a forfeited stake to the hunter who forfeited it', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[3].PlayerData.money.bank = 50000

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 1000 } }, penaltyAmount = 5000,
        })
        s.contracts.accept(f.hunter, c.id, false)

        -- The creator is offline, so the forfeited stake is owed to them
        -- rather than paid immediately.
        Env.removePlayer(1)
        s.contracts.abandon(f.hunter, c.id)
        eq(Env.players[3].PlayerData.money.bank, 45000, 'the hunter forfeited it')

        -- The creator returns and lowers the penalty for whoever comes next.
        Env.addPlayer({ source = 1, citizenid = 'CREATOR1', license = 'license:aaa',
            cash = 0, bank = 0 })
        s.amendments.improve(s.identity.resolve(1), c.id, CB.AMENDMENT.LOWER_PENALTY,
            { amount = 1 })

        eq(Env.players[3].PlayerData.money.bank, 45000,
            'an ordinary penalty reduction must not refund a stake already forfeited')
    end)

    it('keeps a bailout premium owed to an offline creator out of general refunds', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } }, bailoutAmount = 5000,
        })

        Env.removePlayer(1)
        truthy(s.bailout.buy(f.target, c.id))

        local owed = s.storage.readPending('CREATOR1')
        truthy(#owed > 0, 'the premium is owed to the creator')

        -- Any later general release must not carry it off to someone else.
        s.escrow.release(c.id, 'HUNTER01', nil, 'a general sweep')

        local stillOwed = s.storage.readPending('CREATOR1')
        eq(#stillOwed, #owed, 'the premium is still the creator\'s')
        eq(Env.players[3].PlayerData.money.bank, 5000, 'and nobody else was paid it')
    end)
end)

describe('anonymity fees', function()
    local function withFees(creatorFee, hunterFee)
        Config.Anonymity.CreatorFee = creatorFee
        Config.Anonymity.HunterFee = hunterFee
        local s = newStack()
        local f = fixture(s)
        Env.players[3].PlayerData.money.bank = 50000
        return s, f
    end

    local function reset()
        Config.Anonymity.CreatorFee = 0
        Config.Anonymity.HunterFee = 0
    end

    it('charges nothing by default', function()
        reset()
        local s = newStack()
        local f = fixture(s)
        s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 1000 } }, anonymous = true,
        })
        eq(Env.players[1].PlayerData.money.bank, 100000, 'anonymity is free unless configured')
    end)

    it('charges the creator when a fee is configured', function()
        local s, f = withFees(5000, 0)
        s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 1000 } }, anonymous = true,
        })
        reset()
        eq(Env.players[1].PlayerData.money.bank, 95000)
    end)

    it('does not charge a creator who chose to be seen', function()
        local s, f = withFees(5000, 0)
        s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 1000 } }, anonymous = false,
        })
        reset()
        eq(Env.players[1].PlayerData.money.bank, 100000)
    end)

    it('refunds the fee when the contract cannot be created', function()
        local s, f = withFees(5000, 0)
        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { items = { { name = 'nonexistent', count = 5 } } } },
            anonymous = true,
        })
        reset()
        falsy(c)
        eq(Env.players[1].PlayerData.money.bank, 100000, 'no half-charged creators')
    end)

    it('charges a hunter who accepts anonymously', function()
        local s, f = withFees(0, 2500)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        s.contracts.accept(f.hunter, c.id, true)
        reset()
        eq(Env.players[3].PlayerData.money.bank, 47500)
    end)

    it('accepts under their own name when they cannot afford anonymity', function()
        local s, f = withFees(0, 2500)
        Env.players[3].PlayerData.money.bank = 100
        Env.players[3].PlayerData.money.cash = 100
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })

        local ok = s.contracts.accept(f.hunter, c.id, true)
        reset()

        truthy(ok, 'anonymity is a preference, not a requirement to take work')
        local hunter = s.storage.readHunter(c.id, 'HUNTER01')
        falsy(hunter.anon, 'and they are simply named instead')
        eq(Env.players[3].PlayerData.money.bank, 100, 'charged nothing')
    end)

    it('never charges a hunter for an acceptance that fails', function()
        local s, f = withFees(0, 2500)
        Env.players[3].PlayerData.money.bank = 50000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 1000 } }, penaltyAmount = 99999,
        })
        local ok, err = s.contracts.accept(f.hunter, c.id, true)
        reset()

        falsy(ok, 'the stake is unaffordable')
        eq(err, CB.ERR.INSUFFICIENT)
        eq(Env.players[3].PlayerData.money.bank, 50000,
            'and no anonymity fee was taken for it')
    end)
end)

describe('post-respawn immunity', function()
    it('protects a target who has just got back up', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { slots = {
                { baseline = { cash = 1000 } }, { baseline = { cash = 1000 } },
            } },
        })
        s.contracts.accept(f.hunter, c.id, false)

        -- A second hunter, so the per-hunter slot cooldown is not what is
        -- being measured here.
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd' })
        local second = s.identity.resolve(4)
        s.contracts.accept(second, c.id, false)

        s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)

        -- The target goes down, respawns, and the next hunter tries again
        -- straight away.
        s.death.onRevived('TARGET01')

        local ok, err = s.contracts.claimSlot(c.id, 'HUNTER02', CB.FULFILMENT.ELIMINATION)
        falsy(ok, 'a multi-slot contract must not become respawn camping')
        eq(err, CB.ERR.TARGET_PROTECTED)

        Env.advance(Config.Immunity.PostRespawnSeconds + 10)
        truthy(s.contracts.claimSlot(c.id, 'HUNTER02', CB.FULFILMENT.ELIMINATION),
            'and claimable again once they have had a moment on their feet')
    end)

    it('gives a target who bought their way out a longer breather', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[2].PlayerData.money.bank = 100000

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } }, bailoutAmount = 10000,
        })
        truthy(s.bailout.buy(f.target, c.id))
        eq(s.storage.readContract(c.id).state, CB.STATE.BAILED_OUT)

        Env.advance(Config.Limits.TargetCooldownAfterResolveSeconds + 10)
        local again, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 5000 } },
        })
        falsy(again, 'paying to be left alone should buy more than the usual cooldown')
        eq(err, CB.ERR.TARGET_PROTECTED)
    end)
end)
