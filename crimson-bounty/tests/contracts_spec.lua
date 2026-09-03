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

    it('refuses a target who is too new or just connected', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[2]._playtimeHours = 1
        local contract, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = baseReward(),
        })
        falsy(contract)
        eq(err, CB.ERR.TARGET_PROTECTED)
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
