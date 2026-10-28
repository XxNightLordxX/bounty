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
        require('tests.harness.shipped').apply()
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

    --- W001: logged in on the job that bars them, which needs no word (it
    --- is the one they are working), then switched to a civilian one for
    --- the evening with sc-multijob: still barred by the one they hold, and
    --- the "already barred" answer kept that quiet, on this login and on
    --- every later one on the same connection.
    it('tells an officer who switches to a civilian job which job they hold bars them, once', function()
        local s = newStack()
        Config.WhitelistedView.Enabled = false
        s.bridges.install(s)
        Env.addPlayer({ source = 62, citizenid = 'SWITCH62', license = 'license:s62',
            job = { name = 'sast', type = 'leo', onduty = true },
            jobs = { sast = 2, mechanic = 0 } })
        local function told()
            local out = {}
            for _, note in ipairs(Natives.calls.notifications) do
                if tostring(note.content):find('hold the sast job', 1, true) then out[#out + 1] = note end
            end
            return #out
        end
        Natives.calls.notifications = {}
        s.bridges.tellAccess(62)
        eq(#Natives.calls.notifications, 0, 'the job they are working needs no word')

        local mechanic = { name = 'mechanic', type = 'mechanic', onduty = true }
        Env.players[62].PlayerData.job = mechanic
        Env.events['local:QBCore:Server:OnJobUpdate'](62, mechanic)
        eq(told(), 1, 'switched to a civilian job and still barred, by sast')
        s.bridges.refreshAccess()
        s.bridges.refreshAccess()
        eq(told(), 1, 'once, not on every pass')

        -- A character switch on the same source: the next login is its own.
        Env.events['local:QBCore:Server:OnPlayerUnload'](62)
        Env.events['local:qbx_core:server:playerLoggedOut'](62)
        s.bridges.tellAccess(62)
        eq(told(), 2, 'told again on the next character\'s login')
    end)

    --- W003 with W001: a switch staff set that moves nobody's answer tells
    --- nobody anything again.
    it('does not tell a held-barred player again when an access switch moves nothing for them', function()
        local s = newStack()
        Config.WhitelistedView.Enabled = false
        s.bridges.install(s)
        Env.addPlayer({ source = 63, citizenid = 'HIRED063', license = 'license:h63',
            job = { name = 'mechanic', type = 'mechanic', onduty = true },
            jobs = { mechanic = 0, police = 0 } })
        s.bridges.tellAccess(63)
        Natives.calls.notifications = {}
        truthy(s.settings.set('HideAppFromBlockedJobs', false, 'ADMIN001'))
        truthy(s.settings.set('HideAppFromBlockedJobs', true, 'ADMIN001'))
        eq(#Natives.calls.notifications, 0, 'told once already, for the same job')
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

--- clearContract cleared only the stages the advisory settings advised as
--- they stood at the ending, and only with UseDispatch on then: staff
--- turning either off while a contract on an officer was live left its
--- bulletins in the MDT for good (W052). And an ending the tick finished
--- after it raised cleared nothing at all (W075).
describe('taking the threat off the MDT whatever the settings say now', function()
    local function placedAndTaken()
        local s, f = seeded(leoJob('trooper'))
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 1000 } }, penaltyAmount = 100,
        })
        truthy(c)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        return s, f, c
    end

    local function clearedBy(fn)
        Natives.calls.dispatchCleared = {}
        local before = #Env.threads
        fn()
        for i = before + 1, #Env.threads do Env.threads[i]() end
        local cleared = {}
        for _, call in ipairs(Natives.calls.dispatchCleared) do cleared[call.uid] = true end
        return cleared
    end

    for _, switch in ipairs({ 'UseDispatch', 'Enabled', 'OnAccept' }) do
        it('clears both bulletins with Advisory.' .. switch .. ' turned off meanwhile', function()
            local s, _, c = placedAndTaken()
            Config.Advisory[switch] = false
            local cleared = clearedBy(function() truthy(s.admin.void(0, c.id, 'staff')) end)
            truthy(cleared['ch-' .. c.id .. '-posted'], 'the posting bulletin')
            truthy(cleared['ch-' .. c.id .. '-accepted'], 'and the acceptance bulletin')
        end)
    end

    it('clears them, and tells the hitman, when the tick finishes an ending that raised', function()
        local s, _, c = placedAndTaken()
        local release, raised = s.escrow.release, false
        s.escrow.release = function(id, cid, filter, ...)
            if not raised and type(filter) == 'table' and filter.portion == CH.PORTION.STAKE then
                raised = true
                error('the connection dropped', 0)
            end
            return release(id, cid, filter, ...)
        end
        s.admin.void(0, c.id, 'staff')
        s.escrow.release = release
        truthy(raised, 'the void raised before it handed the stake over')
        Env.clientEvents = {}
        local cleared = clearedBy(function() eq(s.contracts.finishEndings(), 1) end)
        truthy(cleared['ch-' .. c.id .. '-posted'], 'the posting bulletin')
        truthy(cleared['ch-' .. c.id .. '-accepted'], 'and the acceptance bulletin')
        local said = {}
        for _, event in ipairs(Env.clientEvents) do
            if Natives.isNotice(event) and event.target == 3 then
                said[#said + 1] = tostring(event.args[1].content)
            end
        end
        said = table.concat(said, ' | ')
        truthy(said:find('Staff closed your contract', 1, true), said)
        truthy(said:find('$100 stake has been returned', 1, true), said)
    end)
end)

--- W058, W055: what the creator is warned about, and what the target is told.
describe('a target in a protected job', function()
    local function call(name, src, payload)
        local fire = Env.events['crimson-hitman:' .. name]
        Env.clientEvents = {}
        _G.source = src
        fire(payload or {})
        _G.source = nil
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:result' then return event.args[1] end
        end
        return nil
    end

    --- Picked as a civilian and hired by the police before the tap: the page
    --- never showed the warning, and the contract was placed and announced
    --- to every officer. Refused until the warning has been agreed to.
    it('is refused, uncharged, when they took the job after being picked', function()
        local s, f = seeded()
        local found = s.app.handlers.searchTargets(s.identity.resolve(1), { query = 'Reyes' })
        local handle = found and found[1] and found[1].handle
        falsy(found[1].protected, 'a civilian when the list was read')
        Env.players[f.target.source].PlayerData.job = leoJob('police')

        local before = Env.players[1].PlayerData.money.bank + Env.players[1].PlayerData.money.cash
        local refused = call('create', 1, { target = handle, reason = 'x',
            reward = { slots = { { baseline = { cash = 1000 } } } }, shown = {} })
        eq(refused and refused.err, CH.ERR.TARGET_NOW_PROTECTED)
        eq(refused.data and refused.data.category, 'law', 'with the kind of job, for the warning')
        eq(Env.players[1].PlayerData.money.bank + Env.players[1].PlayerData.money.cash, before,
            'nothing taken')
        eq(countNotifications('THREAT ADVISORY'), 0, 'and nobody told')

        Env.advance(61)
        local placed = call('create', 1, { target = handle, reason = 'x',
            reward = { slots = { { baseline = { cash = 1000 } } } }, shown = { protectedAck = true } })
        truthy(placed and placed.ok, tostring(placed and placed.err))
        eq(s.storage.readContract(placed.data.id).target_protected, true)
    end)

    it('is not asked about where the server warns nobody', function()
        local s, f = seeded(leoJob('police'))
        Config.Advisory.WarnCreator = false
        local found = s.app.handlers.searchTargets(s.identity.resolve(1), { query = 'Reyes' })
        local placed = call('create', 1, { target = found[1].handle, reason = 'x',
            reward = { slots = { { baseline = { cash = 1000 } } } }, shown = {} })
        truthy(placed and placed.ok, tostring(placed and placed.err))
    end)

    --- A medic was told "Your department has been advised", and only law
    --- enforcement ever is.
    it('tells the target who was advised, by the job they hold', function()
        for _, case in ipairs({
            { job = { name = 'ambulance', type = 'ems', onduty = true },
              said = 'Law enforcement has been advised.' },
            { job = leoJob('police'), said = 'Your department has been advised.' },
        }) do
            local s, f = seeded(case.job)
            Env.clientEvents = {}
            truthy(s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
            }))
            local told = {}
            for _, event in ipairs(Env.clientEvents) do
                if Natives.isNotice(event) and event.target == f.target.source then
                    told[#told + 1] = tostring(event.args[1].content)
                end
            end
            told = table.concat(told, ' | ')
            truthy(told:find(case.said, 1, true), case.job.name .. ': ' .. told)
        end
    end)

    it('is offered in the picker with the kind of job', function()
        local s = seeded({ name = 'ambulance', type = 'ems', onduty = true })
        local found = s.app.handlers.searchTargets(s.identity.resolve(1), { query = 'Reyes' })
        truthy(found[1].protected)
        eq(found[1].protectedAs, 'emergency')
    end)
end)

--------------------------------------------------------------------------
-- The target's alert, as it is sent (W032, W035, W036, W037, W038, W051, W053)
--------------------------------------------------------------------------

describe('the target\'s alert, kept and checked when it falls due', function()
    local Shipped = require('tests.harness.shipped')

    local function place(s, actor, reason)
        -- Placed anonymously on a shipped stack, which allows no anonymous
        -- placing (Config.Anonymity.AllowAnonymousPlacer = false): on here,
        -- explicitly, so these keep covering the anonymous placer's alert.
        Config.Anonymity.AllowAnonymousPlacer = true
        Config.Anonymity.WhitelistedTargets.AllowAnonymousPlacer = true
        local c, err = s.contracts.create(actor or s.identity.resolve(1), {
            targetCid = 'TARGET01', reason = reason or 'x', anonymous = true,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c, 'placed: ' .. tostring(err))
        return c
    end

    local function lapses()
        return countNotifications('Breathing room')
    end

    --- One wait, fixed, so a test can say when the alert falls due.
    local function waitOf(seconds)
        Config.Notifications.ParanoidAlertJitter = { min = seconds, max = seconds }
    end

    it('keeps the alert for a target who is away when it falls due', function()
        local s = seeded()
        Shipped.apply()
        place(s)
        Env.removePlayer(2)
        s.notify.clearPlayer('TARGET01')
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        eq(countParanoid(), 0, 'nobody there to tell')
        Env.addPlayer({ source = 2, citizenid = 'TARGET01', license = 'license:bbb',
            cash = 20000, bank = 20000, firstname = 'Dana', lastname = 'Reyes' })
        s.bridges.onPlayerReady(s, 2)
        eq(countParanoid(), 1, 'kept for their next login, not lost')
    end)

    it('is not dropped by a notice budget full when it falls due', function()
        local s = seeded()
        Shipped.apply()
        waitOf(300)
        place(s)
        Env.advance(299)
        for i = 1, Config.Notifications.MaxPerRecipientPerMinute do
            s.notify.toCitizen('TARGET01', 'n' .. i, 'x')
        end
        Env.advance(2)
        eq(countParanoid(), 1, 'the cooldown rations it, not the budget')
    end)

    it('is not sent once staff switched alerts off while it waited', function()
        local s = seeded()
        Shipped.apply()
        place(s)
        Env.advance(30)
        Config.Notifications.ParanoidAlert = false
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        eq(countParanoid(), 0, 'the panel says alerts still waiting are checked when they fall due')
    end)

    it('says nothing of a contract that lapsed inside the wait', function()
        local s = seeded()
        Shipped.apply()
        waitOf(600)
        local c = place(s)
        Env.advance(10)
        truthy(s.contracts.resolve(c.id, CH.STATE.EXPIRED, 'CREATOR1', nil, 'expired'))
        Env.advance(700)
        eq(countParanoid(), 0, 'never alerted')
        eq(lapses(), 0, 'and not told it lapsed: that would date the placement')
    end)

    it('says it lapsed by what the target was told, not by the switch now', function()
        -- Placed with alerts off, ending after they were switched on.
        local s = seeded()
        Shipped.apply()
        Config.Notifications.ParanoidAlert = false
        local quiet = place(s)
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        Config.Notifications.ParanoidAlert = true
        truthy(s.contracts.resolve(quiet.id, CH.STATE.EXPIRED, 'CREATOR1', nil, 'expired'))
        eq(lapses(), 0, 'never told of it, so not told it lapsed')

        -- Told, then the switch turned off before it ended.
        s = seeded()
        Shipped.apply()
        local loud = place(s)
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        eq(countParanoid(), 1)
        Config.Notifications.ParanoidAlert = false
        truthy(s.contracts.resolve(loud.id, CH.STATE.EXPIRED, 'CREATOR1', nil, 'expired'))
        eq(lapses(), 1, 'told of it, so told it lapsed')
    end)

    it('rings for a second contract at its own reveal when the first is withdrawn', function()
        local s = seeded()
        Shipped.apply()
        waitOf(600)
        local first = place(s)
        Env.advance(300)
        Env.addPlayer({ source = 5, citizenid = 'CREATOR2', license = 'license:eee',
            cash = 100000, bank = 100000 })
        place(s, s.identity.resolve(5), 'y')
        Env.advance(50)
        truthy(s.contracts.cancel(s.identity.resolve(1), first.id))
        Env.advance(260)
        eq(countParanoid(), 0, 'not at the first one\'s time')
        eq(#s.projection.onMe('TARGET01'), 0, 'while On me still shows nothing')
        Env.advance(300)
        eq(countParanoid(), 1, 'at the second one\'s reveal')
        eq(#s.projection.onMe('TARGET01'), 1)
    end)

    it('moves an open On me tab as the alert arrives, naming no contract', function()
        local s = seeded()
        Shipped.apply()
        place(s)
        Env.clientEvents = {}
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        eq(countParanoid(), 1)
        local pushes = {}
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:push' and event.target == 2 then
                pushes[#pushes + 1] = event.args[1]
            end
        end
        eq(#pushes, 1, 'one push to the target')
        eq(pushes[1].reason, 'alert')
        eq(pushes[1].ids, nil, 'no contract named')
    end)

    it('gives an officer the paranoid alert when they are not sent the bulletin', function()
        local s, f = seeded(leoJob('trooper'))
        Shipped.apply()
        Config.Advisory.AlwaysAlertTarget = false
        place(s)
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        local toTarget = 0
        for _, event in ipairs(Env.clientEvents) do
            if Natives.isNotice(event) and event.target == f.target.source then
                toTarget = toTarget + 1
            end
        end
        eq(countParanoid(), 1, 'an officer with a price on their head was told nothing')
        eq(toTarget, 1, 'and nothing else')
    end)
end)

describe('a returning operative after a restart', function()
    local function forget()
        for name in pairs(package.loaded) do
            if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
                package.loaded[name] = nil
            end
        end
    end

    it('raises no second acceptance bulletin', function()
        forget()
        Env.reset()
        Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
        Natives.resetResourceStates()
        resetConfig()
        require('tests.harness.shipped').apply()
        Config.Database.Mode = 'json'
        Natives.files = {}
        local s = require('server.main').start()
        local f = fixture(s, { targetJob = leoJob('trooper') })
        Env.addPlayer({ source = 20, citizenid = 'OFFICER1', license = 'license:o1',
            job = leoJob('police'), firstname = 'Ada', lastname = 'Kane' })
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        eq(countNotifications('THREAT ADVISORY — ACTIVE'), 2, 'the officer and the target')
        truthy(s.contracts.abandon(f.hitman, c.id))

        rawset(s.storage, '__rawFixture', true)
        forget()
        Env.events, Env.clientEvents, Env.notifications = {}, {}, {}
        Env.handlers, Env.threads, Env.timers, Env.commands = {}, {}, {}, {}
        Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
        local again = require('server.main').start()
        local ok, err = again.contracts.accept(again.identity.resolve(3), c.id, false)
        truthy(ok, 'taken up again: ' .. tostring(err))
        eq(countNotifications('THREAT ADVISORY — ACTIVE'), 0,
            'one who walks away and comes back is not news twice')
        eq(#Natives.calls.dispatch, 0, 'nor on the MDT')
        resetConfig()
    end)
end)

describe('a contract on an officer called off', function()
    local function cancelled(title)
        local out = {}
        for _, note in ipairs(Natives.calls.notifications) do
            if tostring(note.title) == (title or 'THREAT ADVISORY — CANCELLED') then out[#out + 1] = note end
        end
        return out
    end

    local function placeOn(s, f)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', anonymous = true,
            reward = { baseline = { cash = 1000 } },
        })
        truthy(c, 'placed')
        Natives.calls.notifications, Natives.calls.dispatch = {}, {}
        return c
    end

    it('tells every officer, the officer it was on, and dispatch, naming nobody else', function()
        local s, f = seeded(leoJob('trooper'))
        local c = placeOn(s, f)
        Natives.calls.dispatchCleared = {}
        local before = #Env.threads
        truthy(s.contracts.cancel(f.creator, c.id), 'cancelled by its placer')
        for i = before + 1, #Env.threads do Env.threads[i]() end

        local notes = cancelled()
        eq(#notes, 3, 'two officers and the targeted one')
        local toOfficer, toTarget = 0, 0
        for _, note in ipairs(notes) do
            if note.content == 'The contract on TROOPER Dana Reyes has been called off.' then
                toOfficer = toOfficer + 1
            elseif note.content == 'The contract on you has been called off.' then
                toTarget = toTarget + 1
            end
            for _, leak in ipairs({ 'Vic', 'Marlowe', 'CREATOR1', 'Rook', 'HITMAN01', 'Operative' }) do
                falsy(tostring(note.content):find(leak, 1, true), 'names ' .. leak .. ': ' .. note.content)
            end
        end
        eq(toOfficer, 2, 'the bulletin, in its words')
        eq(toTarget, 1, 'and the officer it was on')

        local call
        for _, entry in ipairs(Natives.calls.dispatch) do
            if entry.unique_id == 'ch-' .. c.id .. '-cancelled' then call = entry end
        end
        truthy(call, 'over sc-dispatch')
        eq(call.title, 'THREAT ADVISORY — CANCELLED')
        eq(call.message, 'The contract on TROOPER Dana Reyes has been called off.')
        for key, value in pairs(call) do
            if type(value) == 'string' then
                falsy(value:find('Marlowe', 1, true) or value:find('CREATOR1', 1, true),
                    'the dispatch payload names the placer in ' .. key)
            end
        end
        local cleared = {}
        for _, entry in ipairs(Natives.calls.dispatchCleared) do cleared[entry.uid] = true end
        truthy(cleared['ch-' .. c.id .. '-posted'], 'the earlier calls cleared')
        falsy(cleared['ch-' .. c.id .. '-cancelled'], 'and not this one')

        -- Off the whitelisted-job view, as any closed contract.
        local view = s.projection.whitelistedView('OFFICER1', { name = 'police', type = 'leo', onduty = true })
        eq(#(view.colleagues or {}), 0, 'still listed once called off')
    end)

    it('goes out for a staff void, which hands the escrow back', function()
        local s, f = seeded(leoJob('trooper'))
        local c = placeOn(s, f)
        truthy(s.contracts.resolve(c.id, CH.STATE.VOIDED, 'CREATOR1', nil, 'voided_by_staff'))
        eq(#cancelled(), 3, 'a void is a contract called off too')
    end)

    it('says nothing for a civilian target', function()
        local s, f = seeded()
        local c = placeOn(s, f)
        truthy(s.contracts.cancel(f.creator, c.id))
        eq(#cancelled(), 0)
        eq(#Natives.calls.dispatch, 0, 'nor on the MDT')
    end)

    it('says nothing with Advisory.OnCancel off, or Advisory.Enabled off', function()
        for _, setting in ipairs({ 'OnCancel', 'Enabled' }) do
            local s, f = seeded(leoJob('trooper'))
            local c = placeOn(s, f)
            Config.Advisory[setting] = false
            truthy(s.contracts.cancel(f.creator, c.id))
            eq(#cancelled(), 0, setting .. ' off and a bulletin went')
            for _, entry in ipairs(Natives.calls.dispatch) do
                falsy(entry.unique_id == 'ch-' .. c.id .. '-cancelled', setting .. ' off and dispatch was told')
            end
            resetConfig()
        end
    end)

    it('is not sent for a contract that ran out', function()
        local s, f = seeded(leoJob('trooper'))
        local c = placeOn(s, f)
        s.storage.setDeadline(c.id, nil, os.time() - 1)
        truthy(s.contracts.resolve(c.id, CH.STATE.EXPIRED, 'CREATOR1', nil, 'expired', { dueAt = os.time() }))
        eq(#cancelled(), 0, 'an expiry is not a cancellation')
    end)
end)
