--- Kidnapping fulfilment: the countdown only runs while the target is alive,
--- conscious, coerced, and all three parties are together.

local AT = { x = 200.0, y = 200.0, z = 30.0 }

local function seeded()
    local s = newStack()
    local f = fixture(s)
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt',
        reward = { baseline = { cash = 5000 }, bonus = { cash = 2500 } },
    })
    s.contracts.accept(f.hunter, c.id, false)

    -- All three together, target cuffed.
    for _, src in ipairs({ 1, 2, 3 }) do
        Env.players[src]._coords = { x = AT.x, y = AT.y, z = AT.z }
    end
    Env.players[2].PlayerData.metadata.ishandcuffed = true
    return s, f, c
end

local function runCountdown(s, seconds)
    local ticks = math.floor((seconds * 1000) / Config.Kidnap.TickMs)
    local completions = {}
    for _ = 1, ticks do
        local done = s.kidnap.tick(Config.Kidnap.TickMs)
        for _, d in ipairs(done) do completions[#completions + 1] = d end
    end
    return completions
end

describe('arming', function()
    it('arms when all three are together and the target is restrained', function()
        local s, f, c = seeded()
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))
        eq(s.kidnap.activeCount(), 1)
    end)

    it('refuses to arm without the creator present', function()
        local s, f, c = seeded()
        Env.players[1]._coords = { x = 9000.0, y = 9000.0, z = 30.0 }
        local ok, reason = s.kidnap.arm(c.id, 'HUNTER01')
        falsy(ok)
        eq(reason, 'creator_too_far')
    end)

    it('refuses to arm on a dead target', function()
        local s, f, c = seeded()
        Env.players[2].PlayerData.metadata.isdead = true
        local ok, reason = s.kidnap.arm(c.id, 'HUNTER01')
        falsy(ok, 'a corpse is not a live delivery')
        eq(reason, 'target_not_conscious')
    end)

    it('refuses to arm on a downed target', function()
        local s, f, c = seeded()
        Env.players[2].PlayerData.metadata.inlaststand = true
        local ok, reason = s.kidnap.arm(c.id, 'HUNTER01')
        falsy(ok, 'bleeding out is not alive')
        eq(reason, 'target_not_conscious')
    end)

    it('refuses to arm on an unrestrained target', function()
        local s, f, c = seeded()
        Env.players[2].PlayerData.metadata.ishandcuffed = false
        local ok, reason = s.kidnap.arm(c.id, 'HUNTER01')
        falsy(ok, 'walking beside a willing friend is not a kidnapping')
        eq(reason, 'not_coerced')
    end)

    it('accepts a target riding in the hunters vehicle as coerced', function()
        local s, f, c = seeded()
        Env.players[2].PlayerData.metadata.ishandcuffed = false
        Env.players[2]._vehicle, Env.players[3]._vehicle = 55, 55
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))
    end)

    it('refuses a hunter who never accepted', function()
        local s, f, c = seeded()
        Env.addPlayer({ source = 9, citizenid = 'RANDOM01', license = 'license:r', coords = AT })
        local ok, err = s.kidnap.arm(c.id, 'RANDOM01')
        falsy(ok)
        eq(err, CB.ERR.NOT_PARTICIPANT)
    end)

    it('caps concurrent countdowns instead of shedding one in progress', function()
        local s, f, c = seeded()
        local saved = Config.Kidnap.MaxConcurrentCountdowns
        Config.Kidnap.MaxConcurrentCountdowns = 1
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))

        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd', coords = AT })
        local c2 = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'second', reward = { baseline = { cash = 1000 } },
        })
        Config.Kidnap.MaxConcurrentCountdowns = saved
        eq(s.kidnap.activeCount(), 1, 'the first countdown survives')
    end)
end)

describe('countdown', function()
    it('pays baseline plus bonus after the full duration', function()
        local s, f, c = seeded()
        s.kidnap.arm(c.id, 'HUNTER01')
        local done = runCountdown(s, Config.Kidnap.CountdownSeconds)
        eq(#done, 1, 'delivery completed')
        eq(Env.players[3].PlayerData.money.cash, 12500, 'baseline 5000 + bonus 2500')
    end)

    it('does not pay early', function()
        local s, f, c = seeded()
        s.kidnap.arm(c.id, 'HUNTER01')
        local done = runCountdown(s, Config.Kidnap.CountdownSeconds - 2)
        eq(#done, 0, 'not yet')
        eq(Env.players[3].PlayerData.money.cash, 5000, 'unpaid')
    end)

    it('fails the delivery if the target dies mid-countdown', function()
        local s, f, c = seeded()
        s.kidnap.arm(c.id, 'HUNTER01')
        runCountdown(s, 10)
        Env.players[2].PlayerData.metadata.isdead = true
        runCountdown(s, 10)
        eq(s.kidnap.activeCount(), 0, 'countdown dropped')
        eq(Env.players[3].PlayerData.money.cash, 5000, 'no payout for a corpse')
    end)

    it('fails the delivery if the target is downed mid-countdown', function()
        local s, f, c = seeded()
        s.kidnap.arm(c.id, 'HUNTER01')
        runCountdown(s, 10)
        Env.players[2].PlayerData.metadata.inlaststand = true
        runCountdown(s, 10)
        eq(s.kidnap.activeCount(), 0)
        eq(Env.players[3].PlayerData.money.cash, 5000)
    end)

    it('tolerates a brief break within the grace budget', function()
        local s, f, c = seeded()
        s.kidnap.arm(c.id, 'HUNTER01')
        runCountdown(s, 10)

        Env.players[1]._coords = { x = 9000.0, y = 0.0, z = 0.0 }  -- creator steps away
        s.kidnap.tick(Config.Kidnap.TickMs)                        -- 1s of grace
        Env.players[1]._coords = { x = AT.x, y = AT.y, z = AT.z }

        local done = runCountdown(s, Config.Kidnap.CountdownSeconds)
        eq(#done, 1, 'a doorway should not fail the delivery')
    end)

    it('fails once the grace budget is spent, not per break', function()
        local s, f, c = seeded()
        s.kidnap.arm(c.id, 'HUNTER01')
        Env.players[1]._coords = { x = 9000.0, y = 0.0, z = 0.0 }
        runCountdown(s, (Config.Kidnap.MaxTotalGraceMs / 1000) + 2)
        eq(s.kidnap.activeCount(), 0, 'countdown abandoned')
        eq(Env.players[3].PlayerData.money.cash, 5000)
    end)

    it('reports live progress for the app', function()
        local s, f, c = seeded()
        s.kidnap.arm(c.id, 'HUNTER01')
        runCountdown(s, 5)
        local p = s.kidnap.progress(c.id, 'HUNTER01')
        truthy(p)
        eq(p.elapsed, 5)
        eq(p.required, Config.Kidnap.CountdownSeconds)
    end)

    it('drops the countdown if the contract resolves underneath it', function()
        local s, f, c = seeded()
        s.kidnap.arm(c.id, 'HUNTER01')
        s.contracts.resolve(c.id, CB.STATE.CANCELLED, 'CREATOR1', nil, 'cancelled')
        s.kidnap.tick(Config.Kidnap.TickMs)
        eq(s.kidnap.activeCount(), 0)
    end)
end)

describe('a protected target is refused up front', function()
    it('will not arm a countdown the claim would refuse anyway', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } },
        })
        s.contracts.accept(f.hunter, c.id, false)

        for _, src in ipairs({ 1, 2, 3 }) do
            Env.players[src]._coords = { x = 5.0, y = 5.0, z = 30.0 }
        end
        Env.players[2].PlayerData.metadata.ishandcuffed = true

        -- The target has just respawned, so the claim would be refused.
        s.death.onRevived('TARGET01')

        local ok, reason = s.kidnap.arm(c.id, 'HUNTER01')
        falsy(ok, 'thirty seconds of holding someone should not end in a refusal')
        eq(reason, 'target_protected')

        Env.advance(Config.Immunity.PostRespawnSeconds + 10)
        truthy(s.kidnap.arm(c.id, 'HUNTER01'), 'and arms once they are fair game again')
    end)
end)
