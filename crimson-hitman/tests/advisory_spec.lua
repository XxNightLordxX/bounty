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

local function countParanoid()
    local n = 0
    for _, note in ipairs(Natives.calls.notifications) do
        if tostring(note.content):find('eyes on you') then n = n + 1 end
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

    it('sends the dispatch entry to the departments that get the advisory', function()
        -- sc-dispatch files an entry under the jobs it is given. The list
        -- was its own, and a department configured to receive advisories on
        -- phones (sast, on this server) was missing from the MDT's.
        local s, f = seeded(leoJob('trooper'))
        Config.Advisory.RecipientJobNames = { police = true, sast = true, k9 = false }
        s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        local jobs = Natives.calls.dispatch[1].job_table
        eq(#jobs, 2, 'the enabled names and no others')
        eq(jobs[1], 'police')
        eq(jobs[2], 'sast')
    end)

    it('takes the threat off the MDT when the contract ends', function()
        -- sc-dispatch files the advisory as an active call. Nothing closed
        -- it, so an officer's dispatch list kept a live threat against a
        -- colleague long after the contract was settled.
        local s, f = seeded(leoJob('trooper'))
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        Natives.calls.dispatchCleared = {}
        local before = #Env.threads
        truthy(s.contracts.cancel(f.creator, c.id))
        for i = before + 1, #Env.threads do Env.threads[i]() end
        local cleared = {}
        for _, call in ipairs(Natives.calls.dispatchCleared) do cleared[call.uid] = call.jobs end
        truthy(cleared['ch-' .. c.id .. '-posted'], 'the posting bulletin is closed')
        truthy(cleared['ch-' .. c.id .. '-accepted'], 'and any acceptance bulletin')
        truthy(#cleared['ch-' .. c.id .. '-posted'] > 0, 'for the departments it went to')
    end)

    it('clears nothing for a contract that never reached the MDT', function()
        local s, f = seeded()
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        Natives.calls.dispatchCleared = {}
        local before = #Env.threads
        truthy(s.contracts.cancel(f.creator, c.id))
        for i = before + 1, #Env.threads do Env.threads[i]() end
        eq(#Natives.calls.dispatchCleared, 0)
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

    it('fires again on acceptance, carrying the hitman count', function()
        local s, f = seeded(leoJob('trooper'))
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 1000 } },
        })
        Natives.calls.notifications = {}
        Natives.calls.dispatch = {}

        s.contracts.accept(f.hitman, c.id, false)
        eq(countNotifications('THREAT ADVISORY — ACTIVE'), 3, 'two officers plus the target')
        truthy(tostring(Natives.calls.dispatch[1].message):find('1 operative is active'))

        Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd' })
        s.contracts.accept(s.identity.resolve(4), c.id, false)
        truthy(tostring(Natives.calls.dispatch[2].message):find('2 operatives are active'),
            'count escalates with each acceptance')
    end)

    it('tells officers about a new operative on a contract another walked away from', function()
        -- Keyed by the running count, B taking it up after A left was a
        -- count of one, already announced, and nobody heard of B at all.
        local s, f = seeded(leoJob('trooper'))
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 1000 } },
        })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        truthy(s.contracts.abandon(f.hitman, c.id))
        Natives.calls.notifications = {}

        Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd' })
        truthy(s.contracts.accept(s.identity.resolve(4), c.id, false))
        eq(countNotifications('THREAT ADVISORY — ACTIVE'), 3, 'two officers plus the target')
    end)

    it('sends the target a paranoid alert only when they are not protected', function()
        local s, f = seeded()
        s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        eq(countParanoid(), 0, 'not at the second it was placed, which dates the client')
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        eq(countParanoid(), 1, 'civilian target gets the paranoid alert')

        -- A second contract inside the cooldown is not a second alert, so
        -- the alerts do not count the people paying.
        Env.addPlayer({ source = 5, citizenid = 'CREATOR2', license = 'license:eee',
            cash = 100000 })
        truthy(s.contracts.create(s.identity.resolve(5), {
            targetCid = 'TARGET01', reason = 'y', reward = { baseline = { cash = 1000 } },
        }))
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        eq(countParanoid(), 1, 'one alert per cooldown')
    end)

    --- What a drop clears for a player (Bridges, Notify.clearPlayer) keeps
    --- a cooldown still running, or a relog would buy a second alert, and
    --- the alerts would count the people paying.
    it('sends no second alert to a target who relogged inside the cooldown', function()
        local s, f = seeded()
        require('crimson-hitman.tests.harness.shipped').apply()
        truthy(s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        }))
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        eq(countParanoid(), 1, 'the first contract alerts them')
        local alerted = Env.time

        -- Out of the city and back, inside ParanoidCooldownMinutes.
        Env.removePlayer(2)
        s.notify.clearPlayer('TARGET01')
        Env.advance(60)
        Env.addPlayer({ source = 2, citizenid = 'TARGET01', license = 'license:bbb',
            cash = 20000, bank = 20000, firstname = 'Dana', lastname = 'Reyes' })

        Env.addPlayer({ source = 5, citizenid = 'CREATOR2', license = 'license:eee',
            cash = 100000 })
        truthy(s.contracts.create(s.identity.resolve(5), {
            targetCid = 'TARGET01', reason = 'y', reward = { baseline = { cash = 1000 } },
        }))
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        truthy(Env.time - alerted < Config.Notifications.ParanoidCooldownMinutes * 60,
            'all of it inside the cooldown')
        eq(countParanoid(), 1, 'a relog does not earn a second alert')
    end)

    it('refuses the contract entirely when protected targets are disallowed', function()
        local s, f = seeded(leoJob('trooper'))
        Config.Targeting.AllowProtectedJobTargets = false
        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        Config.Targeting.AllowProtectedJobTargets = true
        falsy(c)
        eq(err, CH.ERR.TARGET_IS_LEO)
    end)
end)

describe('an officer working a second job', function()
    local function officerOnSecondJob()
        return { name = 'mechanic', type = 'mechanic', onduty = true }
    end

    local function seededSwitched()
        local s = newStack()
        local f = fixture(s, { targetJob = officerOnSecondJob() })
        Env.players[f.target.source].PlayerData.jobs = { mechanic = 0, police = 2 }
        return s, f
    end

    it('is refused as a target where officers are', function()
        local s, f = seededSwitched()
        Config.Targeting.AllowProtectedJobTargets = false
        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        falsy(c, 'switching job for the evening does not take an officer off the list')
        eq(err, CH.ERR.TARGET_IS_LEO)
    end)

    it('is marked as an officer where contracts on them are allowed', function()
        local s, f = seededSwitched()
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        truthy(c)
        eq(s.storage.readContract(c.id).target_protected, true)
    end)

    it('is named to their colleagues by the job that makes them one', function()
        -- Announced as "MECHANIC Dana Reyes", the advisory did not say the
        -- target was one of theirs, which is its whole point.
        local s, f = seededSwitched()
        Env.addPlayer({ source = 20, citizenid = 'OFFICER1', license = 'license:o1',
            job = { name = 'police', type = 'leo', onduty = true } })
        s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        local message = Natives.calls.dispatch[1] and Natives.calls.dispatch[1].message or ''
        truthy(message:find('POLICE', 1, true), message)
        falsy(message:find('MECHANIC', 1, true), message)
    end)
end)

describe('with the advisory switched off', function()
    --- Whether officers are told is one setting. It also decided whether an
    --- officer counted as one, so switching the bulletins off put officers
    --- back on the board on a server that had forbidden it.
    it('still refuses a contract on an officer where that is forbidden', function()
        local s, f = seeded(leoJob('trooper'))
        Config.Advisory.Enabled = false
        Config.Targeting.AllowProtectedJobTargets = false
        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        falsy(c, 'placed on a sworn officer on a server that forbids it')
        eq(err, CH.ERR.TARGET_IS_LEO)
    end)

    it('still marks a contract on an officer, so both sides are warned', function()
        local s, f = seeded(leoJob('trooper'))
        Config.Advisory.Enabled = false
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        truthy(c)
        eq(s.storage.readContract(c.id).target_protected, true)
        eq(countNotifications('THREAT ADVISORY'), 0, 'and sends no bulletin')
    end)

    it('tells the page officers are not being advised', function()
        local s = seeded(leoJob('trooper'))
        Config.Advisory.Enabled = false
        local settings = s.projection.listing('HITMAN01', 1).settings
        eq(settings.advisory.posted, false)
        eq(settings.advisory.accepted, false)
        Config.Advisory.Enabled = true
        eq(s.projection.listing('HITMAN01', 1).settings.advisory.posted, true)
    end)

    it('gives the officer the paranoid alert in place of the advisory', function()
        local s, f = seeded(leoJob('trooper'))
        Config.Advisory.Enabled = false
        s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        local found = false
        for _, note in ipairs(Natives.calls.notifications) do
            if tostring(note.content):find('eyes on you') then found = true end
        end
        truthy(found, 'an officer with a price on their head was told nothing at all')
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
            eq(err, CH.ERR.BLACKLISTED_JOB, job.name)
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

    --- qbx_core lets a player hold several jobs, and sc-multijob lets them
    --- choose which one is primary. Only the primary was read, so an officer
    --- with a second job switched to it and was a civilian to this app.
    it('bars an officer who has switched to their second job', function()
        local s = newStack()
        Env.addPlayer({ source = 54, citizenid = 'SWITCH01', license = 'license:sw',
            job = { name = 'mechanic', type = 'mechanic', onduty = true },
            jobs = { mechanic = 0, police = 2 } })
        local actor, err = s.identity.gate(54)
        falsy(actor, 'still an officer, working a different job tonight')
        eq(err, CH.ERR.BLACKLISTED_JOB)
    end)

    it('reads a held job as off duty, so it bars only when off duty does', function()
        local s = newStack()
        Config.BlockOffDuty = false
        Env.addPlayer({ source = 55, citizenid = 'SWITCH02', license = 'license:sw2',
            job = { name = 'mechanic', type = 'mechanic', onduty = true },
            jobs = { mechanic = 0, police = 2 } })
        truthy(s.identity.gate(55), 'a server that lets off-duty officers in lets this one in')
    end)

    it('bars a held job by its type when its name is not on the list', function()
        local s = newStack()
        Env.jobDefinitions.harbor_patrol = { label = 'Harbor Patrol', type = 'leo' }
        Env.addPlayer({ source = 56, citizenid = 'SWITCH03', license = 'license:sw3',
            job = { name = 'unemployed', type = 'none' },
            jobs = { unemployed = 0, harbor_patrol = 1 } })
        falsy(s.identity.gate(56), 'the type comes from the framework job list')
    end)

    it('bars a held job by name when the framework cannot say its type', function()
        local s = newStack()
        Env.addPlayer({ source = 57, citizenid = 'SWITCH04', license = 'license:sw4',
            job = { name = 'unemployed', type = 'none' },
            jobs = { unemployed = 0, sast = 1 } })
        falsy(s.identity.gate(57), 'sast is on the list of names')
    end)

    it('tells a player barred by a job they hold which one, and how to get the app back', function()
        -- A department boss can hire anybody through the MDT, with no say
        -- from them; the app then vanished with no word why.
        local s = newStack()
        -- With the whitelisted-job view off: on (as shipped) the app stays,
        -- showing its one screen, so nothing goes away to explain.
        Config.WhitelistedView.Enabled = false
        s.bridges.install(s)
        Env.addPlayer({ source = 61, citizenid = 'HIRED001', license = 'license:hd',
            job = { name = 'mechanic', type = 'mechanic', onduty = true },
            jobs = { mechanic = 0 } })
        s.bridges.tellAccess(61)
        Natives.calls.notifications = {}
        Env.players[61].PlayerData.jobs.police = 0
        s.bridges.refreshAccess()
        local told
        for _, note in ipairs(Natives.calls.notifications) do
            if tostring(note.content):find('police', 1, true) then told = note.content end
        end
        truthy(told, 'the app went away with no word why')
        truthy(told:find('Quit it', 1, true), told)

        Natives.calls.notifications = {}
        s.bridges.refreshAccess()
        eq(#Natives.calls.notifications, 0, 'once, not on every pass')
    end)

    it('admits somebody whose other jobs are all civilian', function()
        local s = newStack()
        Env.addPlayer({ source = 58, citizenid = 'SWITCH05', license = 'license:sw5',
            job = { name = 'unemployed', type = 'none' },
            jobs = { unemployed = 0, mechanic = 3 } })
        truthy(s.identity.gate(58))
    end)

    it('asks the framework for a job type once, not on every request', function()
        local s = newStack()
        Env.addPlayer({ source = 59, citizenid = 'SWITCH06', license = 'license:sw6',
            job = { name = 'unemployed', type = 'none' },
            jobs = { unemployed = 0, mechanic = 3 } })
        Natives.calls.getJob = 0
        for _ = 1, 20 do s.identity.gate(59) end
        eq(Natives.calls.getJob, 1, 'every net handler gates, so this runs on all of them')
        Env.advance(301)
        s.identity.gate(59)
        eq(Natives.calls.getJob, 2, 'and asks again after a while, for an edited job')
    end)

    it('hides the app from an officer working their second job', function()
        local s = newStack()
        s.bridges.install(s)
        Env.addPlayer({ source = 60, citizenid = 'SWITCH07', license = 'license:sw7',
            job = { name = 'mechanic', type = 'mechanic', onduty = true },
            jobs = { mechanic = 0, police = 2 } })
        local function told()
            Env.clientEvents = {}
            s.bridges.tellAccess(60)
            local answer
            for _, event in ipairs(Env.clientEvents) do
                if event.name == 'crimson-hitman:access' and event.target == 60 then
                    answer = event.args[1]
                end
            end
            return answer
        end
        -- With the whitelisted-job view off, as before it: hidden.
        Config.WhitelistedView.Enabled = false
        eq(told(), false)
        -- On, as shipped: the app, with the view's one screen, which the
        -- gate answers them on (whitelisted_view_spec).
        Config.WhitelistedView.Enabled = true
        eq(told(), true, 'a held job puts them in the view as their primary one does')
        truthy(s.identity.gateFor(60, 'view'), 'and the view is theirs')
        falsy(s.identity.gate(60), 'and the rest of the app is not')
    end)

    it('admits an ordinary criminal', function()
        local s = newStack()
        Env.addPlayer({ source = 53, citizenid = 'CRIMINL1', license = 'license:cr',
            job = { name = 'unemployed', type = 'none' } })
        truthy(s.identity.gate(53))
    end)
end)

describe('an advisory switched off at one stage', function()
    --- The posting bulletin off: the officer was told nothing at all — no
    --- bulletin, and no paranoid alert either, which went only where the
    --- whole advisory was off. And with OnCreate absent the page said the
    --- department had been advised while no bulletin went.
    local function placed(onCreate)
        local s, f = seeded(leoJob('trooper'))
        Config.Advisory.OnCreate = onCreate
        Natives.calls.notifications = {}
        truthy(s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        }))
        local settings = s.projection.listing('HITMAN01', 1).settings
        return settings, countNotifications('THREAT ADVISORY')
    end

    it('gives the officer the paranoid alert when the posting bulletin is off', function()
        placed(false)
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        local found = false
        for _, note in ipairs(Natives.calls.notifications) do
            if tostring(note.content):find('eyes on you') then found = true end
        end
        truthy(found, 'an officer with a price on their head was told nothing')
    end)

    --- Told by the acceptance bulletin, an officer still read "Nothing is
    --- out on you" in /cleanse until the reveal wait ran out.
    it('shows the officer the contract once the acceptance bulletin has told them', function()
        local s, f = seeded(leoJob('trooper'))
        Config.Advisory.OnCreate = false
        Config.Notifications.ParanoidAlertJitter = { min = 300, max = 300 }
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
            bailoutAmount = 5000,
        })
        truthy(c)
        eq(#s.bailout.available(f.target), 0, 'held back inside the wait, with nothing said yet')
        truthy(s.contracts.accept(f.hitman, c.id, false))
        Env.advance(1)
        local told = false
        for _, note in ipairs(Natives.calls.notifications) do
            if tostring(note.content):find('The contract on you has been accepted', 1, true) then
                told = true
            end
        end
        truthy(told, 'the officer is told an operative is on them')
        eq(#s.bailout.available(f.target), 1, 'and /cleanse lists what they were told of')
    end)

    it('tells the page the same thing it does', function()
        local settings, bulletins = placed(false)
        eq(settings.advisory.posted, false)
        eq(bulletins, 0)
        settings, bulletins = placed(nil)
        eq(settings.advisory.posted, true, 'absent is on')
        truthy(bulletins > 0, 'and the bulletin went, as the page says')
    end)
end)
