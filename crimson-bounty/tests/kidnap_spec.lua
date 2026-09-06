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
    local function held(s)
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
        return f, c
    end

    --- Taking somebody alive means restraining them, and restraining them
    --- all but always means putting them down first. The post-respawn rule
    --- therefore fired on the hunter's own doing, on nearly every
    --- kidnapping: a hunter with a cuffed target in the back of their car
    --- was told to give them a moment because they had just got up.
    ---
    --- The rule is against re-killing someone who has just respawned. A
    --- target already in hand is not being camped, they are being carried.
    it('delivers a target who has just got up, because that is the job', function()
        local s = newStack()
        local f, c = held(s)

        s.death.onRevived('TARGET01')

        local ok, reason = s.kidnap.arm(c.id, 'HUNTER01')
        truthy(ok, 'a live delivery was refused because the hunter downed them '
            .. 'first, which is how a delivery starts: ' .. tostring(reason))
    end)

    --- The whole delivery, end to end, on a target who has just got up.
    ---
    --- Arming is only half of it: the payout re-checks immunity when the
    --- countdown finishes, so exempting the arm alone would let a hunter
    --- hold somebody for the full thirty seconds and be refused at the end,
    --- which is exactly what the check at arming exists to prevent.
    it('pays out a delivery of a target who had just got up', function()
        local s = newStack()
        local f, c = held(s)
        s.death.onRevived('TARGET01')

        truthy(s.kidnap.arm(c.id, 'HUNTER01'), 'the countdown should start')

        local completions = {}
        local ticks = math.floor((Config.Kidnap.CountdownSeconds * 1000) / Config.Kidnap.TickMs) + 2
        for _ = 1, ticks do
            for _, d in ipairs(s.kidnap.tick(Config.Kidnap.TickMs)) do
                completions[#completions + 1] = d
            end
        end

        truthy(#completions > 0, 'the countdown should have finished')
        eq(s.storage.readContract(c.id).state, CB.STATE.COMPLETED,
            'thirty seconds of holding someone must not end in a refusal')
        eq(Env.players[3].PlayerData.money.cash, 5000 + 5000,
            'and the hunter must actually be paid')
    end)

    it('still refuses an elimination on somebody who just got up', function()
        local s = newStack()
        local f, c = held(s)

        s.death.onRevived('TARGET01')

        -- Same target, same moment, the other fulfilment. Respawn camping is
        -- what the rule is for and it has to keep working.
        local ok, err = s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
        falsy(ok, 'a kill claim on somebody who just respawned must still be refused')
        eq(err, CB.ERR.TARGET_PROTECTED)
    end)

    --- The check at arming exists so a hunter does not hold somebody for
    --- thirty seconds and only then be refused. The immunities that still
    --- apply to a delivery have to be caught there.
    it('will not arm a countdown the claim would refuse anyway', function()
        local s = newStack()
        local f, c = held(s)

        -- A target who has only just joined is not fair game by any route,
        -- delivery included.
        local realSession = s.identity.sessionMinutes
        s.identity.sessionMinutes = function(cid)
            if cid == 'TARGET01' then return 0 end
            return realSession(cid)
        end

        local ok, reason = s.kidnap.arm(c.id, 'HUNTER01')
        s.identity.sessionMinutes = realSession

        falsy(ok, 'thirty seconds of holding someone should not end in a refusal')
        eq(reason, 'target_protected')
    end)
end)
