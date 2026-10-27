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
    s.contracts.accept(f.hitman, c.id, false)

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
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        eq(s.kidnap.activeCount(), 1)
    end)

    it('refuses to arm without the creator present', function()
        local s, f, c = seeded()
        Env.players[1]._coords = { x = 9000.0, y = 9000.0, z = 30.0 }
        local ok, reason = s.kidnap.arm(c.id, 'HITMAN01')
        falsy(ok)
        eq(reason, 'creator_too_far')
    end)

    it('refuses to arm on a dead target', function()
        local s, f, c = seeded()
        Env.players[2].PlayerData.metadata.isdead = true
        local ok, reason = s.kidnap.arm(c.id, 'HITMAN01')
        falsy(ok, 'a corpse is not a live delivery')
        eq(reason, 'target_not_conscious')
    end)

    it('refuses to arm on a downed target', function()
        local s, f, c = seeded()
        Env.players[2].PlayerData.metadata.inlaststand = true
        local ok, reason = s.kidnap.arm(c.id, 'HITMAN01')
        falsy(ok, 'bleeding out is not alive')
        eq(reason, 'target_not_conscious')
    end)

    it('refuses to arm on an unrestrained target', function()
        local s, f, c = seeded()
        Env.players[2].PlayerData.metadata.ishandcuffed = false
        local ok, reason = s.kidnap.arm(c.id, 'HITMAN01')
        falsy(ok, 'walking beside a willing friend is not a kidnapping')
        eq(reason, 'not_coerced')
    end)

    it('accepts a target riding in the hitmen vehicle as coerced', function()
        local s, f, c = seeded()
        Env.players[2].PlayerData.metadata.ishandcuffed = false
        Env.players[2]._vehicle, Env.players[3]._vehicle = 55, 55
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
    end)

    it('refuses a hitman who never accepted', function()
        local s, f, c = seeded()
        Env.addPlayer({ source = 9, citizenid = 'RANDOM01', license = 'license:r', coords = AT })
        local ok, err = s.kidnap.arm(c.id, 'RANDOM01')
        falsy(ok)
        eq(err, CH.ERR.NOT_PARTICIPANT)
    end)

    it('caps concurrent countdowns instead of shedding one in progress', function()
        local s, f, c = seeded()
        local saved = Config.Kidnap.MaxConcurrentCountdowns
        Config.Kidnap.MaxConcurrentCountdowns = 1
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))

        Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd', coords = AT })
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
        s.kidnap.arm(c.id, 'HITMAN01')
        local done = runCountdown(s, Config.Kidnap.CountdownSeconds)
        eq(#done, 1, 'delivery completed')
        eq(Env.players[3].PlayerData.money.cash, 12500, 'baseline 5000 + bonus 2500')
    end)

    it('does not pay early', function()
        local s, f, c = seeded()
        s.kidnap.arm(c.id, 'HITMAN01')
        local done = runCountdown(s, Config.Kidnap.CountdownSeconds - 2)
        eq(#done, 0, 'not yet')
        eq(Env.players[3].PlayerData.money.cash, 5000, 'unpaid')
    end)

    it('fails the delivery if the target dies mid-countdown', function()
        local s, f, c = seeded()
        s.kidnap.arm(c.id, 'HITMAN01')
        runCountdown(s, 10)
        Env.players[2].PlayerData.metadata.isdead = true
        runCountdown(s, 10)
        eq(s.kidnap.activeCount(), 0, 'countdown dropped')
        eq(Env.players[3].PlayerData.money.cash, 5000, 'no payout for a corpse')
    end)

    it('fails the delivery if the target is downed mid-countdown', function()
        local s, f, c = seeded()
        s.kidnap.arm(c.id, 'HITMAN01')
        runCountdown(s, 10)
        Env.players[2].PlayerData.metadata.inlaststand = true
        runCountdown(s, 10)
        eq(s.kidnap.activeCount(), 0)
        eq(Env.players[3].PlayerData.money.cash, 5000)
    end)

    it('tolerates a brief break within the grace budget', function()
        local s, f, c = seeded()
        s.kidnap.arm(c.id, 'HITMAN01')
        runCountdown(s, 10)

        Env.players[1]._coords = { x = 9000.0, y = 0.0, z = 0.0 }  -- creator steps away
        s.kidnap.tick(Config.Kidnap.TickMs)                        -- 1s of grace
        Env.players[1]._coords = { x = AT.x, y = AT.y, z = AT.z }

        local done = runCountdown(s, Config.Kidnap.CountdownSeconds)
        eq(#done, 1, 'a doorway should not fail the delivery')
    end)

    it('fails once the grace budget is spent, not per break', function()
        local s, f, c = seeded()
        s.kidnap.arm(c.id, 'HITMAN01')
        Env.players[1]._coords = { x = 9000.0, y = 0.0, z = 0.0 }
        runCountdown(s, (Config.Kidnap.MaxTotalGraceMs / 1000) + 2)
        eq(s.kidnap.activeCount(), 0, 'countdown abandoned')
        eq(Env.players[3].PlayerData.money.cash, 5000)
    end)

    it('keeps the radius it was armed with when staff narrow it meanwhile', function()
        local s, f, c = seeded()
        -- The client 8 m off: inside config.lua's radius.
        Env.players[1]._coords = { x = AT.x + 8, y = AT.y, z = AT.z }
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        runCountdown(s, 5)
        truthy(s.settings.set('Kidnap.Radius', 4, 'ADMIN001', 'ADMIN001'))
        eq(Config.Kidnap.Radius, 4, 'in force at once')
        local done = runCountdown(s, Config.Kidnap.CountdownSeconds)
        eq(#done, 1, 'finished: every sample measured against the radius it was armed with')
        eq(Env.players[3].PlayerData.money.cash, 12500, 'and paid')

        local again, _, other = seeded()
        truthy(again.settings.set('Kidnap.Radius', 4, 'ADMIN001', 'ADMIN001'))
        Env.players[1]._coords = { x = AT.x + 8, y = AT.y, z = AT.z }
        eq(select(2, again.kidnap.arm(other.id, 'HITMAN01')), 'creator_too_far',
            'a countdown armed after the change takes the new radius')
    end)

    it('reports live progress for the app', function()
        local s, f, c = seeded()
        s.kidnap.arm(c.id, 'HITMAN01')
        runCountdown(s, 5)
        local p = s.kidnap.progress(c.id, 'HITMAN01')
        truthy(p)
        eq(p.elapsed, 5)
        eq(p.required, Config.Kidnap.CountdownSeconds)
    end)

    it('drops the countdown if the contract resolves underneath it', function()
        local s, f, c = seeded()
        s.kidnap.arm(c.id, 'HITMAN01')
        s.contracts.resolve(c.id, CH.STATE.CANCELLED, 'CREATOR1', nil, 'cancelled')
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
        s.contracts.accept(f.hitman, c.id, false)

        for _, src in ipairs({ 1, 2, 3 }) do
            Env.players[src]._coords = { x = 5.0, y = 5.0, z = 30.0 }
        end
        Env.players[2].PlayerData.metadata.ishandcuffed = true
        return f, c
    end

    --- Taking somebody alive means restraining them, and restraining them
    --- all but always means putting them down first. The post-respawn rule
    --- therefore fired on the hitman's own doing, on nearly every
    --- kidnapping: a hitman with a cuffed target in the back of their car
    --- was told to give them a moment because they had just got up.
    ---
    --- The rule is against re-killing someone who has just respawned. A
    --- target already in hand is not being camped, they are being carried.
    it('delivers a target who has just got up, because that is the job', function()
        local s = newStack()
        local f, c = held(s)

        s.death.onRevived('TARGET01')

        local ok, reason = s.kidnap.arm(c.id, 'HITMAN01')
        truthy(ok, 'a live delivery was refused because the hitman downed them '
            .. 'first, which is how a delivery starts: ' .. tostring(reason))
    end)

    --- The whole delivery, end to end, on a target who has just got up.
    ---
    --- Arming is only half of it: the payout re-checks immunity when the
    --- countdown finishes, so exempting the arm alone would let a hitman
    --- hold somebody for the full thirty seconds and be refused at the end,
    --- which is exactly what the check at arming exists to prevent.
    it('pays out a delivery of a target who had just got up', function()
        local s = newStack()
        local f, c = held(s)
        s.death.onRevived('TARGET01')

        truthy(s.kidnap.arm(c.id, 'HITMAN01'), 'the countdown should start')

        local completions = {}
        local ticks = math.floor((Config.Kidnap.CountdownSeconds * 1000) / Config.Kidnap.TickMs) + 2
        for _ = 1, ticks do
            for _, d in ipairs(s.kidnap.tick(Config.Kidnap.TickMs)) do
                completions[#completions + 1] = d
            end
        end

        truthy(#completions > 0, 'the countdown should have finished')
        eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED,
            'thirty seconds of holding someone must not end in a refusal')
        eq(Env.players[3].PlayerData.money.cash, 5000 + 5000,
            'and the hitman must actually be paid')
    end)

    it('still refuses an elimination on somebody who just got up', function()
        local s = newStack()
        local f, c = held(s)

        s.death.onRevived('TARGET01')

        -- Same target, same moment, the other fulfilment. Respawn camping is
        -- what the rule is for and it has to keep working.
        local ok, err = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        falsy(ok, 'a kill claim on somebody who just respawned must still be refused')
        eq(err, CH.ERR.TARGET_JUST_UP)
    end)

    --- The check at arming exists so a hitman does not hold somebody for
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

        local ok, reason = s.kidnap.arm(c.id, 'HITMAN01')
        s.identity.sessionMinutes = realSession

        falsy(ok, 'thirty seconds of holding someone should not end in a refusal')
        -- Which rule, not "they only just got up", which a delivery skips.
        eq(reason, CH.ERR.TARGET_JUST_ON)
    end)
end)

--- Every way a server can decide somebody is restrained.
---
--- A live delivery only counts if the target is visibly under the hitman's
--- control, and Config.Kidnap.Coercion lets an operator choose which
--- detectors say so: handcuff metadata, riding in the hitman's vehicle, or
--- an export from their own rope or ziptie script. The comment above them
--- promises that "servers with different restraint scripts all have a
--- working path".
---
--- Line coverage said otherwise. The handcuff detector is exercised
--- everywhere; the vehicle one barely; and the RestraintProvider branch
--- never ran once in the whole suite — the same shape as the reason presets
--- and the browse scopes, a documented option nothing had ever chosen. An
--- operator who sets it is the only person who finds out whether it works.
describe('deciding whether a target is restrained', function()
    local AT = { x = 300.0, y = 300.0, z = 30.0 }

    --- All three parties together, which every detector needs anyway.
    local function together(s)
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 5000 } },
        })
        s.contracts.accept(f.hitman, c.id, false)
        for _, src in ipairs({ 1, 2, 3 }) do
            Env.players[src]._coords = { x = AT.x, y = AT.y, z = AT.z }
        end
        return f, c
    end

    --- Only the named detectors switched on, so each is tested alone rather
    --- than being carried by whichever one happens to be true.
    local function onlyDetector(name)
        local rules = { handcuffed = false, passengerOfHitman = false }
        if name then rules[name] = true end
        return rules
    end

    it('takes handcuff metadata where that detector is on', function()
        local s = newStack()
        local f, c = together(s)
        withConfig({ { Config.Kidnap, 'Coercion', onlyDetector('handcuffed') } }, function()
            Env.players[2].PlayerData.metadata.ishandcuffed = true
            local ok, how = s.kidnap.isCoerced(3, 2)
            truthy(ok, 'cuffs are the detector every server has')
            eq(how, 'handcuffed')
        end)
    end)

    it('ignores handcuff metadata where that detector is off', function()
        local s = newStack()
        local f, c = together(s)
        withConfig({ { Config.Kidnap, 'Coercion', onlyDetector(nil) } }, function()
            Env.players[2].PlayerData.metadata.ishandcuffed = true
            falsy(s.kidnap.isCoerced(3, 2),
                'an operator who switched a detector off must not still have it')
        end)
    end)

    it('takes a target riding in the hitmen own vehicle', function()
        local s = newStack()
        local f, c = together(s)
        withConfig({ { Config.Kidnap, 'Coercion', onlyDetector('passengerOfHitman') } }, function()
            Env.players[2]._vehicle = 77
            Env.players[3]._vehicle = 77
            local ok, how = s.kidnap.isCoerced(3, 2)
            truthy(ok, 'in the boot of the hitmen car is under their control')
            eq(how, 'in_hitman_vehicle')
        end)
    end)

    it('does not take a target riding in somebody elses vehicle', function()
        local s = newStack()
        local f, c = together(s)
        withConfig({ { Config.Kidnap, 'Coercion', onlyDetector('passengerOfHitman') } }, function()
            Env.players[2]._vehicle = 77
            Env.players[3]._vehicle = 88
            falsy(s.kidnap.isCoerced(3, 2),
                'two people driving separately is not a kidnapping')
        end)
    end)

    --- The branch nothing had ever run.
    describe('a servers own restraint script', function()
        local PROVIDER = 'rope-restraints'

        local function withProvider(state, answer, fn)
            Natives.resourceStates[PROVIDER] = state
            exports[PROVIDER] = answer and {
                IsRestrained = function(_, src)
                    if answer == 'throws' then error('provider exploded', 0) end
                    if answer == 'wrong-type' then return 'yes' end
                    return answer == 'restrained'
                end,
            } or nil
            local ok, err = pcall(fn)
            Natives.resourceStates[PROVIDER] = nil
            exports[PROVIDER] = nil
            if not ok then error(err, 0) end
        end

        it('takes the providers word when it says restrained', function()
            local s = newStack()
            local f, c = together(s)
            withConfig({
                { Config.Kidnap, 'Coercion', onlyDetector(nil) },
                { Config.Kidnap, 'RestraintProvider', PROVIDER },
            }, function()
                withProvider('started', 'restrained', function()
                    local ok, how = s.kidnap.isCoerced(3, 2)
                    truthy(ok, 'an operator who wired their own rope script has '
                        .. 'no other way to make a delivery count')
                    eq(how, 'restraint_provider')
                end)
            end)
        end)

        it('takes its word when it says not restrained', function()
            local s = newStack()
            local f, c = together(s)
            withConfig({
                { Config.Kidnap, 'Coercion', onlyDetector(nil) },
                { Config.Kidnap, 'RestraintProvider', PROVIDER },
            }, function()
                withProvider('started', 'free', function()
                    falsy(s.kidnap.isCoerced(3, 2), 'a free target is not a delivery')
                end)
            end)
        end)

        it('survives a provider that throws', function()
            local s = newStack()
            local f, c = together(s)
            withConfig({
                { Config.Kidnap, 'Coercion', onlyDetector(nil) },
                { Config.Kidnap, 'RestraintProvider', PROVIDER },
            }, function()
                withProvider('started', 'throws', function()
                    local ok, err = pcall(s.kidnap.isCoerced, 3, 2)
                    truthy(ok, 'a third-party script raising must not take the '
                        .. 'handover down with it: ' .. tostring(err))
                end)
            end)
        end)

        it('does not believe a provider that answers with the wrong type', function()
            local s = newStack()
            local f, c = together(s)
            withConfig({
                { Config.Kidnap, 'Coercion', onlyDetector(nil) },
                { Config.Kidnap, 'RestraintProvider', PROVIDER },
            }, function()
                withProvider('started', 'wrong-type', function()
                    -- A string is truthy in Lua, so a provider returning
                    -- 'yes' would satisfy a bare truthiness test and let a
                    -- free target be delivered.
                    local ok = s.kidnap.isCoerced(3, 2)
                    eq(type(ok), 'boolean', 'the answer handed on has to be a boolean')
                end)
            end)
        end)

        it('does not consult a provider whose resource is not running', function()
            local s = newStack()
            local f, c = together(s)
            local asked = false
            withConfig({
                { Config.Kidnap, 'Coercion', onlyDetector(nil) },
                { Config.Kidnap, 'RestraintProvider', PROVIDER },
            }, function()
                Natives.resourceStates[PROVIDER] = 'stopped'
                exports[PROVIDER] = { IsRestrained = function() asked = true return true end }
                falsy(s.kidnap.isCoerced(3, 2),
                    'a stopped resource must not decide a delivery')
                falsy(asked, 'and must not be called at all')
                Natives.resourceStates[PROVIDER] = nil
                exports[PROVIDER] = nil
            end)
        end)
    end)

    --- Any enabled detector is enough, which is what the comment promises.
    it('is satisfied by whichever detector happens to be true', function()
        local s = newStack()
        local f, c = together(s)
        withConfig({ { Config.Kidnap, 'Coercion',
            { handcuffed = true, passengerOfHitman = true } } }, function()
            Env.players[2].PlayerData.metadata.ishandcuffed = false
            Env.players[2]._vehicle = 55
            Env.players[3]._vehicle = 55
            truthy(s.kidnap.isCoerced(3, 2),
                'one detector saying no must not veto another saying yes')
        end)
    end)

    it('refuses when no detector says so', function()
        local s = newStack()
        local f, c = together(s)
        withConfig({ { Config.Kidnap, 'Coercion',
            { handcuffed = true, passengerOfHitman = true } } }, function()
            falsy(s.kidnap.isCoerced(3, 2),
                'walking beside a willing friend is not a kidnapping')
        end)
    end)

    it('needs no detector at all where coercion is not required', function()
        local s = newStack()
        local f, c = together(s)
        withConfig({ { Config.Kidnap, 'RequireCoercion', false } }, function()
            local ok, how = s.kidnap.isCoerced(3, 2)
            truthy(ok, 'an operator who turned the requirement off has turned it off')
            eq(how, 'not_required')
        end)
    end)
end)


--- An armed handover that nobody is coming to finish.
---
--- Kidnap.cancel and Kidnap.clearContract both existed and neither had a
--- caller anywhere in the resource. bridges.install wires informant, comms
--- and death into contracts.onResolved and not kidnap, and abandon says
--- nothing about a countdown the leaving hitman had armed.
---
--- No money is at risk: the countdown does not complete for a hitman who is
--- no longer active, and a resolved contract cannot be paid out twice. What
--- leaks is the entry itself. It holds one of
--- Config.Kidnap.MaxConcurrentCountdowns for the life of the process and
--- keeps the tick thread running, so on a busy server live delivery quietly
--- stops working for everybody — refused as limit_reached, which the app
--- words as holding too many contracts, and recovered by nothing short of a
--- restart.
describe('a handover left behind', function()
    local function wired()
        local s = newStack()
        local f = fixture(s)
        s.bridges.install(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 }, bonus = { cash = 2500 } },
        })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        for _, src in ipairs({ 1, 2, 3 }) do
            Env.players[src]._coords = { x = AT.x, y = AT.y, z = AT.z }
        end
        Env.players[2].PlayerData.metadata.ishandcuffed = true
        return s, f, c
    end

    it('is released when the contract resolves', function()
        local s, f, c = wired()
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        eq(s.kidnap.activeCount(), 1)

        s.contracts.resolve(c.id, CH.STATE.CANCELLED, f.creator.cid, nil, 'cancelled')

        eq(s.kidnap.activeCount(), 0,
            'a contract nobody can deliver on must not hold a countdown slot '
            .. 'for the life of the process')
    end)

    it('is released when the hitman holding it walks away', function()
        local s, f, c = wired()
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        truthy(s.contracts.abandon(f.hitman, c.id))

        eq(s.kidnap.activeCount(), 0)
        falsy(s.kidnap.progress(c.id, 'HITMAN01'),
            'and the hitman who left is not still counting down')
    end)

    it('leaves another hitman countdown on the same contract alone', function()
        local s, f, c = wired()
        Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
            cash = 5000, bank = 5000, firstname = 'Kade', lastname = 'Wolfe' })
        Env.players[4]._coords = { x = AT.x, y = AT.y, z = AT.z }
        truthy(s.contracts.accept(s.identity.resolve(4), c.id, false))

        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        truthy(s.kidnap.arm(c.id, 'HITMAN02'))
        eq(s.kidnap.activeCount(), 2)

        truthy(s.contracts.abandon(f.hitman, c.id))

        eq(s.kidnap.activeCount(), 1, 'one left, and it is not both')
        truthy(s.kidnap.progress(c.id, 'HITMAN02'),
            'the hitman who stayed is still delivering')
    end)

    it('gives the slot back, so the mechanic keeps working', function()
        -- The consequence, stated as the consequence. Fill the cap with
        -- contracts that then resolve, and arming has to work again.
        local s, f = wired()
        local cap = Config.Kidnap.MaxConcurrentCountdowns
        truthy(cap and cap > 0)

        local placed = {}
        withConfig({
            { Config.Limits, 'MaxActiveContractsPerCreator', cap + 2 },
            { Config.Limits, 'MaxActiveContractsPerTarget', cap + 2 },
            { Config.Limits, 'MaxAcceptedPerHitman', cap + 2 },
        }, function()
            for i = 1, cap do
                local targetCid = ('TGT%05d'):format(i)
                Env.addPlayer({ source = 40 + i, citizenid = targetCid,
                    license = 'license:k' .. i, cash = 10, bank = 10,
                    firstname = 'Mark', lastname = 'Number' .. i })
                Env.players[40 + i]._coords = { x = AT.x, y = AT.y, z = AT.z }
                Env.players[40 + i].PlayerData.metadata.ishandcuffed = true

                local c = s.contracts.create(f.creator, {
                    targetCid = targetCid, reason = 'x', mode = CH.MODE.COMPETITIVE,
                    reward = { baseline = { cash = 1000 } },
                })
                truthy(c, 'contract ' .. i)
                truthy(s.contracts.accept(f.hitman, c.id, false), 'accept ' .. i)
                truthy(s.kidnap.arm(c.id, 'HITMAN01'), 'arm ' .. i)
                placed[#placed + 1] = c
            end
        end)
        eq(s.kidnap.activeCount(), cap, 'the cap is full')

        for _, c in ipairs(placed) do
            s.contracts.resolve(c.id, CH.STATE.CANCELLED, f.creator.cid, nil, 'cancelled')
        end
        eq(s.kidnap.activeCount(), 0, 'and every one of them let go')
    end)

    it('records that a countdown was cancelled and why', function()
        local s, f, c = wired()
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        truthy(s.contracts.abandon(f.hitman, c.id))
        s.audit.flush()

        local row
        for _, entry in ipairs(s.storage.readAudit()) do
            if entry.action == 'kidnap_cancelled' then row = entry end
        end
        truthy(row, 'a handover that ended without a delivery is worth a row')
        eq(row.contract_id, c.id)
    end)
end)

--- Goods put up for a live delivery only, beside a percentage bonus. The
--- percentage used to be skipped on any payout that named a bonus line of
--- its own, goods included, so marking a lockpick "alive only" quietly took
--- the money bonus off that payout — at creation and on every later raise.
describe('alive-only goods beside a percentage bonus', function()
    local function placed()
        local s = newStack()
        local f = fixture(s)
        local c = assert(s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt', bonusPercent = 50,
            reward = { slots = { {
                baseline = { cash = 5000 },
                bonus = { items = { { name = 'lockpick', count = 1 } } },
            } } },
        }))
        return s, f, c
    end

    it('keeps the percentage and pays both on a live delivery', function()
        local s, f, c = placed()
        s.contracts.accept(f.hitman, c.id, false)
        for _, src in ipairs({ 1, 2, 3 }) do
            Env.players[src]._coords = { x = AT.x, y = AT.y, z = AT.z }
        end
        Env.players[2].PlayerData.metadata.ishandcuffed = true
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        eq(#runCountdown(s, Config.Kidnap.CountdownSeconds), 1, 'delivery completed')

        eq(Env.players[3].PlayerData.money.cash, 12500, '5000 own + 5000 base + 2500 bonus')
        local picks = 0
        for _, slot in ipairs(Env.players[3]._inventory) do
            if slot.name == 'lockpick' then picks = picks + slot.count end
        end
        eq(picks, 1, 'and the lockpick held for a live delivery')
    end)

    it('still tops the percentage up when it is raised', function()
        local s, f, c = placed()
        eq(#s.escrow.bonusTopUp(c.id, 50, 100), 1, 'the cash bonus is recomputed')
    end)
end)

--- Under the health floor is not "not conscious". Qbox gives no health back
--- and bleeding takes more, so a target shot during the abduction sits under
--- it awake, cuffed and talking: told they "must be alive and conscious",
--- or that they "went down", the hitman could see it was not so.
describe('a target too badly hurt to hand over', function()
    local function hurt()
        local floor = Config.Kidnap.MinTargetHealthPercent
        Env.players[2]._health = 100 + floor - 1
    end

    it('is refused at arming with a reason of its own', function()
        local s, f, c = seeded()
        hurt()
        local ok, reason = s.kidnap.arm(c.id, 'HITMAN01')
        falsy(ok)
        eq(reason, 'target_too_hurt')
    end)

    it('still reads a dead or downed target as not conscious', function()
        local s, f, c = seeded()
        hurt()
        Env.players[2].PlayerData.metadata.inlaststand = true
        local _, reason = s.kidnap.arm(c.id, 'HITMAN01')
        eq(reason, 'target_not_conscious', 'down comes before hurt')
    end)

    it('fails a countdown with that reason, and says so', function()
        local s, f, c = seeded()
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        runCountdown(s, 10)
        Natives.calls.notifications = {}
        hurt()
        runCountdown(s, 10)
        eq(s.kidnap.activeCount(), 0)
        eq(s.kidnap.outcome(c.id, 'HITMAN01').reason, 'target_too_hurt')
        local told = false
        for _, note in ipairs(Natives.calls.notifications) do
            if tostring(note.content):find('too badly hurt', 1, true) then told = true end
            falsy(tostring(note.content):find('went down', 1, true), 'they did not go down')
        end
        truthy(told, 'the phone says why')
        eq(Env.players[3].PlayerData.money.cash, 5000, 'and nothing is paid')
    end)
end)

describe('a handover after the deadline', function()
    it('is not started on a contract whose time is up', function()
        local s, f, c = seeded()
        local row = s.storage.readContract(c.id)
        row.deadline_at = Env.time - 1
        s.storage.writeContract(row)
        local ok, err = s.kidnap.arm(c.id, 'HITMAN01')
        falsy(ok, 'the expiry waits for a handover already counting, not one started late')
        eq(err, CH.ERR.ALREADY_SETTLED)
    end)
end)

local Shipped = require('crimson-hitman.tests.harness.shipped')

--- Every notice one player's phone was sent, as { title, content }.
local function noticesTo(src)
    local out = {}
    for _, event in ipairs(Env.clientEvents) do
        if Natives.isNotice(event) and event.target == src then
            local data = event.args and event.args[1] or {}
            out[#out + 1] = { title = tostring(data.title), content = tostring(data.content) }
        end
    end
    return out
end

local function told(src, title)
    for _, note in ipairs(noticesTo(src)) do
        if note.title == title then return note.content end
    end
    return nil
end

local function auditRows(s, action)
    s.audit.flush()
    return s.storage.auditByAction(action, 100) or {}
end

--- The owner's server: alive only, one collection, a stake to put up.
local function shippedHandover()
    local s = Shipped.newStack()
    local f = fixture(s)
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 } }, penaltyAmount = 500,
    })
    truthy(c, 'placed under the shipped rules')
    truthy(s.contracts.accept(f.hitman, c.id, false))
    for _, src in ipairs({ 1, 2, 3 }) do
        Env.players[src]._coords = { x = AT.x, y = AT.y, z = AT.z }
    end
    Env.players[2].PlayerData.metadata.ishandcuffed = true
    truthy(s.kidnap.arm(c.id, 'HITMAN01'))
    return s, f, c
end

--- The paid ending was the one that sent the hitman nothing: the page's
--- poller was all, and a hitman holding a target is the one most likely to
--- have put the phone away (W086, W026, W194).
describe('a handover that is paid', function()
    it('sends the hitman a receipt: what was paid and where their stake went', function()
        local s, _, c = shippedHandover()
        runCountdown(s, Config.Kidnap.CountdownSeconds + 1)
        eq(s.kidnap.outcome(c.id, 'HITMAN01').outcome, 'paid')
        local receipt = told(3, 'Handover paid')
        truthy(receipt, 'the hitman is sent a receipt')
        truthy(receipt:find('Delivered alive: $5,000 released to you.', 1, true), receipt)
        truthy(receipt:find('Your $500 stake has been returned.', 1, true), receipt)
    end)

    it('keeps the receipt for a hitman who has gone by the time it is paid', function()
        local s, _, c = shippedHandover()
        local claim = s.contracts.claimSlot
        local hitman = Env.players[3]
        s.contracts.claimSlot = function(...)
            Env.removePlayer(3)
            return claim(...)
        end
        runCountdown(s, Config.Kidnap.CountdownSeconds + 1)
        s.contracts.claimSlot = claim
        eq(s.kidnap.outcome(c.id, 'HITMAN01').outcome, 'paid')
        local count, titles = s.notify.waitingFor('HITMAN01')
        truthy(count > 0 and table.concat(titles, ','):find('Handover paid', 1, true),
            'kept for their next login: ' .. table.concat(titles, ','))
        Env.players[3], Env.byCitizen.HITMAN01 = hitman, 3
        s.notify.deliverWaiting('HITMAN01')
        truthy((told(3, 'Handover paid') or ''):find('held until you make room', 1, true),
            'and it says what waits for them')
    end)

    it('still tells the client and writes its row when the ledger write raises', function()
        local s, _, c = shippedHandover()
        s.storage.writeLedger = function() error('Lost connection to server during query', 0) end
        runCountdown(s, Config.Kidnap.CountdownSeconds + 1)
        eq(s.kidnap.outcome(c.id, 'HITMAN01').outcome, 'paid')
        truthy(told(1, 'Contract fulfilled'), 'the client is told')
        truthy(told(3, 'Handover paid'), 'and the hitman')
        eq(#auditRows(s, 'kidnap_completed'), 1, 'the financial row is written')
        eq(#auditRows(s, 'ledger_write_failed'), 1, 'and the failure is on record')
    end)
end)

--- A party who left mid-handover left only kidnap_failed { party_offline },
--- and a hitman who left nothing after kidnap_armed (W024, spec 14.42).
describe('a party leaving in the middle of a handover', function()
    it('records which party left and how far the countdown had run', function()
        local s, _, c = shippedHandover()
        runCountdown(s, 20)
        s.bridges.onPlayerDropped(s, 'TARGET01')
        local rows = auditRows(s, 'kidnap_party_dropped')
        eq(#rows, 1)
        eq(rows[1].contract_id, c.id)
        eq(rows[1].detail.role, 'target')
        eq(rows[1].detail.elapsedMs, 20000, 'twenty seconds in')
        truthy(rows[1].detail.graceUsedMs, 'and the grace spent')
        s.bridges.onPlayerDropped(s, 'TARGET01')
        eq(#auditRows(s, 'kidnap_party_dropped'), 1, 'once, for a logout said twice')
    end)

    it('records a hitman who left, and that their countdown was cancelled', function()
        local s, _, c = shippedHandover()
        runCountdown(s, 10)
        s.bridges.onPlayerDropped(s, 'HITMAN01')
        local dropped = auditRows(s, 'kidnap_party_dropped')
        eq(#dropped, 1)
        eq(dropped[1].detail.role, 'hitman')
        local cancelled = auditRows(s, 'kidnap_cancelled')
        eq(#cancelled, 1)
        eq(cancelled[1].contract_id, c.id)
        eq(cancelled[1].detail.reason, 'hitman_dropped')
        eq(s.kidnap.activeCount(), 0)
    end)

    it('records nothing while the resource itself is stopping', function()
        local s = shippedHandover()
        runCountdown(s, 10)
        Natives.resourceStates[GetCurrentResourceName()] = 'stopping'
        s.bridges.onPlayerDropped(s, 'TARGET01')
        eq(#auditRows(s, 'kidnap_party_dropped'), 0)
    end)
end)
