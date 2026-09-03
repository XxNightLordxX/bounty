--- Law enforcement threat advisory (§7.5): posted and accepted bulletins to
--- every online LEO, to the officer, and to dispatch.

local function leoJob(name)
    return { name = name, type = 'leo', onduty = true }
end

local function seeded(targetJob)
    local s = newStack()
    local f = fixture(s, { targetJob = targetJob })
    -- Two officers online to receive advisories.
    Env.addPlayer({ source = 20, citizenid = 'OFFICER1', license = 'license:o1',
        job = leoJob('police'), firstname = 'Ada', lastname = 'Kane' })
    Env.addPlayer({ source = 21, citizenid = 'OFFICER2', license = 'license:o2',
        job = leoJob('bcso'), firstname = 'Sam', lastname = 'Bell' })
    return s, f
end

local function countNotifications(match)
    local n = 0
    for _, note in ipairs(Natives.calls.notifications) do
        if tostring(note.title):find(match) then n = n + 1 end
    end
    return n
end

describe('threat advisory', function()
    it('does not fire for an ordinary civilian target', function()
        local s, f = seeded()
        s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        eq(countNotifications('THREAT ADVISORY'), 0)
    end)

    it('alerts every officer and the target when a contract is posted on an officer', function()
        local s, f = seeded(leoJob('trooper'))
        s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        -- two officers + the targeted officer
        eq(countNotifications('THREAT ADVISORY'), 3)
    end)

    it('raises a dispatch entry as well as phone notifications', function()
        local s, f = seeded(leoJob('trooper'))
        s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        eq(#Natives.calls.dispatch, 1, 'one dispatch call')
        truthy(tostring(Natives.calls.dispatch[1].message):find('Dana Reyes'), 'names the officer')
    end)

    it('never names the creator in an advisory', function()
        local s, f = seeded(leoJob('trooper'))
        s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        for _, note in ipairs(Natives.calls.notifications) do
            if tostring(note.title):find('THREAT ADVISORY') then
                falsy(tostring(note.content):find('Marlowe'), 'creator name leaked into an advisory')
                falsy(tostring(note.content):find('Vic'), 'creator name leaked into an advisory')
            end
        end
    end)

    it('fires again on acceptance, carrying the hunter count', function()
        local s, f = seeded(leoJob('trooper'))
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 1000 } },
        })
        Natives.calls.notifications = {}
        Natives.calls.dispatch = {}

        s.contracts.accept(f.hunter, c.id, false)
        eq(countNotifications('THREAT ADVISORY — ACTIVE'), 3, 'two officers plus the target')
        truthy(tostring(Natives.calls.dispatch[1].message):find('1 operative is active'))

        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd' })
        s.contracts.accept(s.identity.resolve(4), c.id, false)
        truthy(tostring(Natives.calls.dispatch[2].message):find('2 operatives are active'),
            'count escalates with each acceptance')
    end)

    it('sends the target a paranoid alert only when they are not protected', function()
        local s, f = seeded()
        s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        local found = false
        for _, note in ipairs(Natives.calls.notifications) do
            if tostring(note.content):find('eyes on you') then found = true end
        end
        truthy(found, 'civilian target gets the paranoid alert')
    end)

    it('refuses the contract entirely when protected targets are disallowed', function()
        local s, f = seeded(leoJob('trooper'))
        Config.Targeting.AllowProtectedJobTargets = false
        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        Config.Targeting.AllowProtectedJobTargets = true
        falsy(c)
        eq(err, CB.ERR.TARGET_PROTECTED)
    end)
end)

describe('app access', function()
    it('bars every law enforcement and emergency job from the app', function()
        local s = newStack()
        for _, job in ipairs({
            { name = 'police', type = 'leo' }, { name = 'bcso', type = 'leo' },
            { name = 'fib', type = 'leo' }, { name = 'trooper', type = 'leo' },
            { name = 'sasp', type = 'leo' }, { name = 'sheriff', type = 'leo' },
            { name = 'ambulance', type = 'ems' }, { name = 'fire', type = 'fire' },
            { name = 'doj', type = 'none' }, { name = 'lawyer', type = 'none' },
            { name = 'ranger', type = 'none' },
        }) do
            Env.addPlayer({ source = 50, citizenid = 'BLOCKED1', license = 'license:b', job = job })
            local actor, err = s.identity.gate(50)
            falsy(actor, job.name .. ' must be blocked')
            eq(err, CB.ERR.BLACKLISTED_JOB, job.name)
            Env.removePlayer(50)
        end
    end)

    it('blocks an off-duty officer too', function()
        local s = newStack()
        Env.addPlayer({ source = 51, citizenid = 'OFFDUTY1', license = 'license:od',
            job = { name = 'police', type = 'leo', onduty = false } })
        local actor = s.identity.gate(51)
        falsy(actor, 'an off-duty officer is still an officer')
    end)

    it('blocks an unknown job that carries a law enforcement type', function()
        local s = newStack()
        Env.addPlayer({ source = 52, citizenid = 'NEWCOP01', license = 'license:nc',
            job = { name = 'harbor_patrol', type = 'leo', onduty = true } })
        falsy(s.identity.gate(52), 'type check must catch a job not in the name list')
    end)

    it('admits an ordinary criminal', function()
        local s = newStack()
        Env.addPlayer({ source = 53, citizenid = 'CRIMINL1', license = 'license:cr',
            job = { name = 'unemployed', type = 'none' } })
        truthy(s.identity.gate(53))
    end)
end)
