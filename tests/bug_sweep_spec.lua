--- The bug sweep at 97f6876: each proven bug, held to its fix.
---
---   M1  a bodyguard share paid, then its row not written, was paid again
---       after a restart;
---   M2  a bodyguard charge whose second write failed stayed 'charging'
---       forever, with no staff path; a share left for staff had none
---       either;
---   M3  protection money moved on a contract staff put on hold, and jobs
---       were posted and taken while staff paused the app;
---   M4  a guard could take the contract on the person they guard;
---   C1  the idle clock ran, and released a hold (stake forfeited), while
---       staff paused the app;
---   C2  two syncs of the app pause in one another's awaits gave the
---       lifetime back twice;
---   C3  a restart started the EMS re-listing count again;
---   S2  removing a made-up operative answered "on hold" on exactly the
---       contracts a frozen (anonymous) player is on;
---   S3  a guard taking a job anonymously was named all the same;
---   U1  a byte cut split a UTF-8 character (utf8mb4 refuses the write);
---   U2  the NPC loop died, and leaked a ped, when an NPC moved during its
---       model load;
---   U3  a restart-only setting (a command name) went into Config at once;
--- and the small hardening items done with them.
---
--- Money is conserved through every one: players' cash and bank, what the
--- escrow holds, and what the bodyguard jobs hold.

local it = require('tests.harness.roleplay').it

local function cash(src) return Env.players[src].PlayerData.money.cash end
local function bank(src) return Env.players[src].PlayerData.money.bank end

--- Every player's money, what the contracts hold, and what the jobs hold.
local function total(s)
    local sum = 0
    for _, p in pairs(Env.players) do sum = sum + p.PlayerData.money.cash + p.PlayerData.money.bank end
    for _, c in ipairs(s.storage.allContracts()) do
        for _, line in ipairs(s.storage.readEscrow(c.id) or {}) do
            if CH.MONEY_SOURCES[line.source] and line.source ~= 'dirty'
                and line.state ~= CH.ESCROW_STATE.SETTLED then
                sum = sum + (line.amount or 0) - (tonumber(line.deliver_arrived) or 0)
            end
        end
    end
    return sum + s.rpProtection.held()
end

local function audits(s, action)
    s.audit.flush()
    local n = 0
    for _, row in ipairs(s.storage.readAudit()) do
        if row.action == action then n = n + 1 end
    end
    return n
end

local function call(name, src, payload)
    local fire = Env.events['crimson-hitman:' .. name]
    truthy(fire, 'no handler registered for ' .. name)
    local from = #Env.clientEvents
    _G.source = src
    fire(payload or {})
    _G.source = nil
    for i = from + 1, #Env.clientEvents do
        local event = Env.clientEvents[i]
        if event.name == 'crimson-hitman:result' and event.target == src then return event.args[1] end
    end
    return nil
end

--- A contract on Dana Reyes (2), placed by Vic Marlowe (1) and taken by
--- Rook Ash (3), shown to her; bodyguards on, and a guard, Gus Ward (4).
local function setup(opts)
    opts = opts or {}
    local s = newStack()
    local f = fixture(s)
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 } }, anonymous = opts.anonCreator == true,
    })
    truthy(c, 'placed')
    truthy(s.contracts.accept(f.hitman, c.id, true), 'taken')
    Env.players[2].PlayerData.money.bank = 100000
    Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
    Env.runTimers()
    Config.Roleplay.Protection.Enabled = true
    s.bridges.install(s)
    Env.addPlayer({ source = 4, citizenid = 'GUARD001', license = 'license:ddd', cash = 0, bank = 0,
        firstname = 'Gus', lastname = 'Ward' })
    return s, f, c
end

local function post(src, c, amount)
    return call('protectionPost', src, { id = c.id, amount = amount or 2000,
        account = Config.Roleplay.Protection.Account })
end

--- The same store, a new process: what a restart is to this module.
local function restartProtection(s)
    s.rpProtection.init({ storage = s.storage, identity = s.identity, audit = s.audit, notify = s.notify,
                          app = s.app, informant = s.informant, projection = s.projection,
                          review = s.review, contracts = s.contracts })
    s.rpProtection.boot()
end

--- The store refusing every bodyguard row `refuse(row)` says, until put back.
local function refuseRows(s, refuse)
    local write = s.storage.writeRpRow
    s.storage.writeRpRow = function(row)
        if row.kind == 'protection' and refuse(row) then error('store down') end
        return write(row)
    end
    return function() s.storage.writeRpRow = write end
end

local function openReviews(s, kind)
    local out = {}
    for _, item in ipairs(s.storage.reviewItems(true, 1000) or {}) do
        if item.kind == kind and item.state == s.review.STATE.OPEN then out[#out + 1] = item end
    end
    return out
end

--------------------------------------------------------------------------
-- M1: a share paid once, whatever the store does
--------------------------------------------------------------------------

describe('bug sweep M1: a bodyguard share is never paid twice', function()
    it('a share paid whose record could not be written is not paid again after a restart', function()
        local s, f, c = setup()
        local job = post(2, c).data.job
        truthy(call('protectionAccept', 4, { job = job, reward = 2000 }).ok, 'taken')
        local before = total(s)
        s.contracts.abandon(f.hitman, c.id)
        truthy(s.contracts.cancel(f.creator, c.id), 'called off')
        -- The store takes the claim and refuses the write that says it was paid.
        local restore = refuseRows(s, function(row) return row.guard_paid == true end)
        s.rpProtection.sweep()
        restore()
        eq(bank(4), 2000, 'paid once')
        restartProtection(s)
        s.rpProtection.sweep()
        s.rpProtection.sweep()
        eq(bank(4), 2000, 'and never again after the restart')
        local items = openReviews(s, 'protection_payout_unconfirmed')
        eq(#items, 1, 'left for staff in the review queue')
        eq(items[1].amount, 2000)
        eq(items[1].cids.guard, 'GUARD001')
        -- Staff find it arrived and dismiss it: nothing more moves.
        truthy(s.review.resolve(items[1].id, { action = 'dismiss', note = 'arrived' }, 'ADMIN001'))
        eq(bank(4), 2000)
        eq(s.rpProtection.held(), 0)
        eq(total(s), before, 'conserved')
        -- A second start opens no second item for the same money.
        restartProtection(s)
        eq(#openReviews(s, 'protection_payout_unconfirmed'), 0, 'no second item')
    end)

    it('moves nothing while the store will not take the claim, and pays once it does', function()
        local s, f, c = setup()
        local job = post(2, c).data.job
        call('protectionAccept', 4, { job = job, reward = 2000 })
        local before = total(s)
        s.contracts.abandon(f.hitman, c.id)
        s.contracts.cancel(f.creator, c.id)
        local restore = refuseRows(s, function() return true end)
        s.rpProtection.sweep()
        s.rpProtection.sweep()
        eq(bank(4), 0, 'nothing paid without the claim written')
        eq(total(s), before, 'still held')
        restore()
        s.rpProtection.sweep()
        eq(bank(4), 2000, 'paid once the store answers')
        s.rpProtection.sweep()
        eq(bank(4), 2000, 'once')
        eq(s.rpProtection.held(), 0)
        eq(total(s), before, 'conserved')
    end)

    it('a payment that raised part-way is a review item, and Pay gives only what did not arrive', function()
        local s, f, c = setup()
        local job = post(2, c).data.job
        call('protectionAccept', 4, { job = job, reward = 2000 })
        local before = total(s)
        local guard = Env.players[4]
        local add = guard.Functions.AddMoney
        guard.Functions.AddMoney = function(account, amount)
            add(account, amount / 2)
            error('half a payment')
        end
        s.contracts.abandon(f.hitman, c.id)
        s.contracts.cancel(f.creator, c.id)
        s.rpProtection.sweep()
        s.rpProtection.sweep()
        guard.Functions.AddMoney = add
        eq(bank(4), 1000, 'what arrived, once')
        eq(s.rpProtection.held(), 0, 'the share is the review queue\'s now')
        local items = openReviews(s, 'protection_payout_unconfirmed')
        eq(#items, 1)
        truthy(s.review.resolve(items[1].id, { action = 'pay', who = 'guard', note = 'half arrived' },
            'ADMIN001'))
        eq(bank(4), 2000, 'the rest, once')
        falsy(s.review.resolve(items[1].id, { action = 'pay', who = 'guard', note = 'again' }, 'ADMIN001'),
            'resolved once')
        eq(bank(4), 2000)
        eq(total(s), before, 'conserved')
        eq(s.rpProtection.all()[1].state, 'settled', 'the job closes')
    end)
end)

--------------------------------------------------------------------------
-- M2: a charge the store did not record
--------------------------------------------------------------------------

describe('bug sweep M2: a charge the store did not record is never stuck', function()
    it('hands the money back when the row cannot be written after the charge', function()
        local s, _, c = setup()
        local before, targetBank = total(s), bank(2)
        local restore = refuseRows(s, function(row) return row.state ~= 'charging' end)
        local r = post(2, c)
        falsy(r.ok, 'refused: it could not be kept')
        eq(bank(2), targetBank - 2000, 'taken, and owed back')
        eq(total(s), before, 'held by the job meanwhile')
        restore()
        s.rpProtection.sweep()
        eq(bank(2), targetBank, 'handed back once the store answers')
        s.rpProtection.sweep()
        eq(bank(2), targetBank, 'once')
        eq(s.rpProtection.held(), 0)
        eq(total(s), before, 'conserved')
        truthy(post(2, c).ok, 'and a new job may be posted')
    end)

    it('a restart that finds it charging leaves it for staff, who refund it once', function()
        local s, _, c = setup()
        local before, targetBank = total(s), bank(2)
        local restore = refuseRows(s, function(row) return row.state ~= 'charging' end)
        falsy(post(2, c).ok)
        restore()
        -- Restarted before the tick wrote anything: the store says charging.
        restartProtection(s)
        local items = openReviews(s, 'protection_charge_unknown')
        eq(#items, 1, 'left for staff')
        eq(items[1].cids.target, 'TARGET01')
        eq(s.rpProtection.held(), 0, 'off the books: the queue has it')
        local job = s.rpProtection.all()[1]
        eq(job.state, 'review')
        s.rpProtection.sweep()
        eq(bank(2), targetBank - 2000, 'nothing pays it by itself')
        -- Staff check the bank and refund it.
        truthy(s.review.resolve(items[1].id, { action = 'refund', who = 'target', amount = 2000,
            note = 'charged' }, 'ADMIN001'))
        eq(bank(2), targetBank, 'refunded')
        falsy(s.review.resolve(items[1].id, { action = 'refund', who = 'target', amount = 2000,
            note = 'again' }, 'ADMIN001'), 'once')
        eq(bank(2), targetBank)
        eq(total(s), before, 'conserved')
        -- The row no longer blocks a new job.
        truthy(post(2, c).ok, 'a new job may be posted')
        restartProtection(s)
        eq(#openReviews(s, 'protection_charge_unknown'), 0, 'no second item at the next start')
    end)
end)

--------------------------------------------------------------------------
-- M3: protection money on a contract on hold, and while the app is paused
--------------------------------------------------------------------------

describe('bug sweep M3: no protection money moves on a contract on hold', function()
    it('refuses to post on a frozen contract, charging nothing', function()
        local s, _, c = setup()
        local targetBank = bank(2)
        truthy(s.holds.freeze('ADMIN001', 'HITMAN01', 'dispute'), 'frozen')
        eq(post(2, c).err, CH.ERR.CONTRACT_FROZEN)
        eq(bank(2), targetBank, 'nothing taken')
        eq(#s.rpProtection.all(), 0, 'no row')
    end)

    it('refuses when the freeze lands while the job is being written, charging nothing', function()
        local s, _, c = setup()
        local targetBank = bank(2)
        local write = s.storage.writeRpRow
        s.storage.writeRpRow = function(row)
            if row.state == 'charging' then s.holds.freeze('ADMIN001', 'HITMAN01', 'dispute') end
            return write(row)
        end
        local r = post(2, c)
        s.storage.writeRpRow = write
        eq(r.err, CH.ERR.CONTRACT_FROZEN)
        eq(bank(2), targetBank, 'nothing taken')
        eq(#s.storage.readRpRows('protection'), 0, 'no row left behind')
    end)

    it('refuses to cancel or take a job on a frozen contract', function()
        local s, _, c = setup()
        local job = post(2, c).data.job
        local before = total(s)
        truthy(s.holds.freeze('ADMIN001', 'HITMAN01', 'dispute'), 'frozen')
        eq(call('protectionCancel', 2, { job = job }).err, CH.ERR.CONTRACT_FROZEN)
        eq(call('protectionAccept', 4, { job = job, reward = 2000 }).err, CH.ERR.BAD_STATE,
            'not right now, to somebody who is no party to it')
        eq(s.rpProtection.all()[1].state, 'open')
        eq(total(s), before, 'nothing moved')
        truthy(s.holds.unfreeze('ADMIN001', 'HITMAN01'), 'released')
        truthy(call('protectionCancel', 2, { job = job }).ok, 'cancelled once released')
    end)

    it('posts and takes nothing while staff pause the app', function()
        local s, _, c = setup()
        local job = post(2, c).data.job
        Config.Holds.AppPaused = true
        s.holds.syncAppPause()
        eq(call('protectionAccept', 4, { job = job, reward = 2000 }).err, CH.ERR.APP_PAUSED)
        local c2 = s.storage.readContract(c.id)
        truthy(c2)
        Config.Holds.AppPaused = false
        s.holds.syncAppPause()
        truthy(call('protectionAccept', 4, { job = job, reward = 2000 }).ok, 'taken once resumed')
        -- And posting.
        local s2, _, c3 = setup()
        Config.Holds.AppPaused = true
        s2.holds.syncAppPause()
        local targetBank = bank(2)
        eq(post(2, c3).err, CH.ERR.APP_PAUSED)
        eq(bank(2), targetBank, 'nothing taken')
        Config.Holds.AppPaused = false
        s2.holds.syncAppPause()
    end)
end)

--------------------------------------------------------------------------
-- M4: a guard on the contract on the person they guard
--------------------------------------------------------------------------

describe('bug sweep M4: a guard may not take the hit on the person they guard', function()
    it('refuses the contract to their guard', function()
        local s, _, c = setup()
        local job = post(2, c).data.job
        truthy(call('protectionAccept', 4, { job = job, reward = 2000 }).ok, 'guarding')
        local ok, err = s.contracts.accept(s.identity.resolve(4), c.id, false)
        falsy(ok, 'refused')
        eq(err, CH.ERR.PROTECTION_GUARDING)
        eq(s.storage.readHitman(c.id, 'GUARD001'), nil, 'not on it')
        local app = read_file('crimson-hitman/ui/app.js')
        truthy(app:find("protection_guarding: '", 1, true), 'the app words the refusal')
    end)

    it('pays a guard who got on the contract anyway nothing of the job', function()
        local s, f, c = setup()
        local job = post(2, c).data.job
        call('protectionAccept', 4, { job = job, reward = 2000 })
        -- Got on it some other way (the backstop).
        local hook = s.contracts.guardsTarget
        s.contracts.guardsTarget = nil
        truthy(s.contracts.accept(s.identity.resolve(4), c.id, false), 'on it')
        s.contracts.guardsTarget = hook
        local before, targetBank = total(s), bank(2)
        s.contracts.abandon(s.identity.resolve(4), c.id)
        s.contracts.abandon(f.hitman, c.id)
        truthy(s.contracts.cancel(f.creator, c.id), 'called off')
        s.rpProtection.sweep()
        eq(bank(4), 0, 'the guard is paid nothing')
        eq(bank(2), targetBank + 2000, 'all of it back to the target')
        eq(total(s), before, 'conserved')
    end)
end)

--------------------------------------------------------------------------
-- S3: a guard taking a job anonymously
--------------------------------------------------------------------------

describe('bug sweep S3: a guard who takes a job anonymously is never named', function()
    it('keeps the choice the page sent', function()
        local s, _, c = setup()
        Config.TargetClasses.default.ShowOperativeNames = true
        local job = post(2, c).data.job
        truthy(call('protectionAccept', 4, { job = job, reward = 2000, anonymous = true }).ok)
        eq(s.rpProtection.all()[1].guard_anon, true)
        local view = s.rpProtection.targetView(s.storage.readContract(c.id), 'TARGET01')
        eq(view.state, 'taken')
        eq(view.guardName, nil, 'not named to the target')
    end)

    it('names one who took it under their name, where the server shows names', function()
        local s, _, c = setup()
        Config.TargetClasses.default.ShowOperativeNames = true
        local job = post(2, c).data.job
        truthy(call('protectionAccept', 4, { job = job, reward = 2000 }).ok)
        local view = s.rpProtection.targetView(s.storage.readContract(c.id), 'TARGET01')
        eq(view.guardName, 'Gus Ward')
    end)
end)

--------------------------------------------------------------------------
-- Hardening: one acceptance per guard at a time
--------------------------------------------------------------------------

describe('bug sweep hardening: MaxJobsPerGuard holds across an acceptance\'s awaits', function()
    it('refuses a second acceptance landing in the first one\'s reads', function()
        local s, f, c = setup()
        Config.Roleplay.Protection.MaxJobsPerGuard = 1
        local first = post(2, c).data.job
        Env.addPlayer({ source = 5, citizenid = 'TARGET02', license = 'license:eee', bank = 100000,
            firstname = 'Tia', lastname = 'Two' })
        local c2 = s.contracts.create(f.creator, { targetCid = 'TARGET02', reason = 'Another debt',
            reward = { baseline = { cash = 5000 } } })
        truthy(c2, 'second contract')
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        Env.runTimers()
        local second = call('protectionPost', 5, { id = c2.id, amount = 2000, account = 'bank' })
        truthy(second.ok, tostring(second.err))
        local read = s.storage.readContract
        local inner
        s.storage.readContract = function(id)
            if not inner then
                inner = { s.rpProtection.accept(s.identity.resolve(4),
                    { job = second.data.job, reward = 2000 }) }
            end
            return read(id)
        end
        local outer = { s.rpProtection.accept(s.identity.resolve(4), { job = first, reward = 2000 }) }
        s.storage.readContract = read
        truthy(outer[1], 'the first taken: ' .. tostring(outer[2]))
        falsy(inner[1], 'the second, landing in its reads, refused')
        local taken = 0
        for _, j in ipairs(s.rpProtection.all()) do
            if j.state == 'taken' and j.guard_cid == 'GUARD001' then taken = taken + 1 end
        end
        eq(taken, 1, 'one job at most')
    end)
end)

--------------------------------------------------------------------------
-- C1: the idle release under the app pause
--------------------------------------------------------------------------

describe('bug sweep C1: no idle release while staff pause the app', function()
    it('keeps the hold, and the stake, while paused', function()
        local s = newStack()
        local f = fixture(s)
        Config.Limits.ExclusiveIdleReleaseSeconds = 600
        Config.Limits.ExclusiveAttemptWindowSeconds = 0
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.EXCLUSIVE, reward = { baseline = { cash = 5000 } } })
        truthy(c, 'placed')
        truthy(s.contracts.accept(f.hitman, c.id, false), 'held')
        Env.players[3]._coords = { x = 5000.0, y = 5000.0, z = 0.0 }
        s.contracts.releaseIdleHolds()
        Config.Holds.AppPaused = true
        s.holds.syncAppPause()
        for _ = 1, 30 do
            Env.advance(60)
            s.death.watchTargets(s.storage.allContracts())
            s.contracts.releaseIdleHolds()
        end
        eq(s.storage.readHitman(c.id, 'HITMAN01').state, 'active', 'still theirs while paused')
        -- Resumed, the clock starts from where it was, not from thirty minutes.
        Config.Holds.AppPaused = false
        s.holds.syncAppPause()
        Env.advance(60)
        s.contracts.releaseIdleHolds()
        eq(s.storage.readHitman(c.id, 'HITMAN01').state, 'active', 'a minute after is not ten')
        for _ = 1, 11 do
            Env.advance(60)
            s.death.watchTargets(s.storage.allContracts())
            s.contracts.releaseIdleHolds()
        end
        eq(s.storage.readHitman(c.id, 'HITMAN01').state, 'released', 'and released once it ran')
    end)
end)

--------------------------------------------------------------------------
-- C2: two syncs of the app pause
--------------------------------------------------------------------------

describe('bug sweep C2: the app pause gives the lifetime back once', function()
    it('gives it back once when a second sync lands in the first one\'s write', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            reward = { baseline = { cash = 5000 } } })
        truthy(c, 'placed')
        Config.Holds.AppPaused = true
        eq(s.holds.syncAppPause(), 'paused')
        Env.advance(600)
        local before = s.storage.readContract(c.id).expires_at
        Config.Holds.AppPaused = false
        local write = s.storage.writeStaffMeta
        local inner = 'not run'
        s.storage.writeStaffMeta = function(...)
            if inner == 'not run' then inner = s.holds.syncAppPause() end
            return write(...)
        end
        eq(s.holds.syncAppPause(), 'resumed')
        s.storage.writeStaffMeta = write
        eq(inner, nil, 'the second sync found nothing to do')
        eq(s.storage.readContract(c.id).expires_at - before, 600, 'given back once')
    end)

    it('starts it once when a second sync lands in the first one\'s write', function()
        local s = newStack()
        fixture(s)
        Config.Holds.AppPaused = true
        local write = s.storage.writeStaffMeta
        local inner = 'not run'
        s.storage.writeStaffMeta = function(...)
            if inner == 'not run' then inner = s.holds.syncAppPause() end
            return write(...)
        end
        eq(s.holds.syncAppPause(), 'paused')
        s.storage.writeStaffMeta = write
        eq(inner, nil, 'the second sync found it on')
        Config.Holds.AppPaused = false
        s.holds.syncAppPause()
    end)
end)

--------------------------------------------------------------------------
-- Hardening: a restart hold past its end replaced by a new one
--------------------------------------------------------------------------

describe('bug sweep hardening: a restart hold replaced gives its span back', function()
    it('releases an expired hold the tick has not, before a new one starts', function()
        local s = newStack()
        local f = fixture(s)
        Config.Holds.RestartPauseBeforeSeconds = 1800
        Config.Holds.RestartMaxHoldMinutes = 45
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            reward = { baseline = { cash = 5000 } } })
        truthy(c, 'placed')
        local before = s.storage.readContract(c.id).expires_at
        truthy(s.holds.scheduledRestart({ secondsRemaining = 300 }), 'held')
        Env.advance(46 * 60)
        truthy(s.holds.scheduledRestart({ secondsRemaining = 300 }), 'a new hold')
        truthy(s.storage.readContract(c.id).expires_at - before >= 45 * 60, 'the first one\'s span given back')
        s.holds.releaseRestart('skipped')
    end)
end)

--------------------------------------------------------------------------
-- C3: the EMS re-listing count across a restart
--------------------------------------------------------------------------

describe('bug sweep C3: a restart does not start the recovery count again', function()
    local function killed(config)
        local s = newStack()
        local f = fixture(s)
        Config.Limits.TargetCooldownAfterResolveSeconds = 0
        Config.Limits.SameCreatorSameTargetCooldownSeconds = 0
        Config.Immunity.PostRespawnSeconds = 0
        Config.Roleplay.EmsRelisting.Enabled = true
        for k, v in pairs(config or {}) do Config.Roleplay.EmsRelisting[k] = v end
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        truthy(c, 'placed')
        truthy(s.contracts.accept(f.hitman, c.id, false), 'accepted')
        Env.players[2].PlayerData.metadata.isdead = true
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        return s
    end

    local function restart(s)
        s.rpConsequences.init({ storage = s.storage, identity = s.identity, notify = s.notify,
            audit = s.audit, ledger = s.ledger, contracts = s.contracts, escrow = s.escrow })
    end

    local function retry(s)
        return s.contracts.create(s.identity.resolve(1), {
            targetCid = 'TARGET01', reason = 'Unpaid debt again', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 2000 } },
        })
    end

    it('counts the minutes up from before the restart', function()
        local s = killed({ TreatedMinutes = 10 })
        Env.players[2].PlayerData.metadata.isdead = false
        s.rpConsequences.tick()
        Env.advance(9 * 60)
        s.rpConsequences.tick()
        restart(s)
        falsy(retry(s), 'nine minutes up: still recovering after the restart')
        Env.advance(2 * 60)
        s.rpConsequences.tick()
        truthy(retry(s), 'eleven minutes up, a restart among them')
    end)

    it('keeps a medic\'s revive heard before the restart', function()
        local s = killed({ RequireEMS = true, TreatedMinutes = 1 })
        s.rpConsequences.noteMedicRevive(2)
        Env.players[2].PlayerData.metadata.isdead = false
        restart(s)
        truthy(retry(s), 'a medic brought them back before the restart')
    end)

    it('still waits for a medic after a restart where none was heard', function()
        local s = killed({ RequireEMS = true, TreatedMinutes = 1 })
        Env.players[2].PlayerData.metadata.isdead = false
        s.rpConsequences.tick()
        restart(s)
        Env.advance(20 * 60)
        falsy(retry(s), 'got up alone')
    end)

    it('keeps nothing once the hold is over', function()
        local s = killed({ MaxHoldMinutes = 30 })
        Env.advance(31 * 60)
        s.rpConsequences.tick()
        eq(#s.storage.readRpRows('ems'), 0, 'its row is gone')
    end)
end)

--------------------------------------------------------------------------
-- Hardening: city news never says where the hitman is
--------------------------------------------------------------------------

describe('bug sweep hardening: city news places only the target', function()
    it('says the city when the target is not in it, never the hitman\'s area', function()
        local s = newStack()
        local f = fixture(s)
        Config.Roleplay.CityNews.Enabled = true
        Config.Roleplay.CityNews.AllTargets = true
        Config.Roleplay.CityNews.Templates = { 'Attack near {zone}.' }
        Config.Roleplay.WitnessHeat.Areas = { 'Vinewood Hills@100,100' }
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            reward = { baseline = { cash = 5000 } } })
        truthy(c, 'placed')
        Env.players[3]._coords = { x = 100.0, y = 100.0, z = 0.0 }
        Env.players[2] = nil
        eq(s.rpConsequences.newsText(s.storage.readContract(c.id), 'HITMAN01'), 'Attack near the city.')
    end)
end)

--------------------------------------------------------------------------
-- S2: the freeze is asked after the operative
--------------------------------------------------------------------------

describe('bug sweep S2: removing an operative tells nothing of who is frozen', function()
    local function forgetServerModules()
        for name in pairs(package.loaded) do
            if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
                package.loaded[name] = nil
            end
        end
    end

    local function boot()
        forgetServerModules()
        Env.reset()
        Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
        Natives.resetResourceStates()
        resetConfig()
        Config.Database.Mode = 'memory'
        Config.Cooldowns.admin = { per = 10, burst = 500 }
        Config.Cooldowns.adminWrite = { per = 10, burst = 500 }
        Config.Limits.ExclusiveIdleReleaseSeconds = 0
        Config.Limits.ExclusiveAttemptWindowSeconds = 0
        Config.Limits.MaxActiveContractsPerTarget = 5
        Config.Limits.MaxActiveContractsPerCreator = 5
        local main = require('server.main')
        return main, main.start()
    end

    local function ask(src, op, data)
        Env.clientEvents = {}
        _G.source = src
        local fired, err = pcall(Env.events['crimson-hitman:admin'], { op = op, data = data or {}, __rid = 7 })
        _G.source = nil
        truthy(fired, 'the net event must not raise: ' .. tostring(err))
        for _, e in ipairs(Env.clientEvents) do
            if e.name == 'crimson-hitman:adminResult' then return e.args[1] end
        end
        return nil
    end

    it('answers no_operative alike on a contract held through an anonymous placer and one not', function()
        local _, s = boot()
        local f = fixture(s)
        Env.addPlayer({ source = 4, citizenid = 'TARGET02', license = 'license:ddd',
            firstname = 'Tia', lastname = 'Two' })
        Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
            firstname = 'Sam', lastname = 'Steward' })
        Env.addPlayer({ source = 8, citizenid = 'UNMASK01', license = 'license:UNMASK01',
            firstname = 'Uma', lastname = 'Mask' })
        Env.aces[6] = { ['crimson.admin'] = true }
        Env.aces[8] = { ['crimson.admin'] = true, ['crimson.identity'] = true }
        local suspect = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            reward = { baseline = { cash = 5000 } }, anonymous = true })
        truthy(suspect, 'placed anonymously')
        local other = s.contracts.create(s.identity.resolve(2), { targetCid = 'TARGET02',
            reason = 'Another debt', reward = { baseline = { cash = 5000 } } })
        truthy(other, 'placed by somebody else')
        truthy(s.contracts.accept(f.hitman, suspect.id, false), 'taken')
        truthy(s.contracts.accept(f.hitman, other.id, false), 'taken')
        truthy(s.holds.freeze('ADMIN001', 'CREATOR1', 'suspect'), 'the suspect frozen')
        local onSuspect = ask(6, 'removeHitman', { id = suspect.id, hitman = 'hn99999999', reason = 'probe' })
        local onOther = ask(6, 'removeHitman', { id = other.id, hitman = 'hn99999999', reason = 'probe' })
        eq(onSuspect.err, 'no_operative')
        eq(onOther.err, 'no_operative')
        eq(onSuspect.message, onOther.message, 'the same words')
        -- A real operative on the contract held through the anonymous
        -- placer: staff who may not see who it is are not told it is held.
        local hitmanId
        for _, row in ipairs(s.storage.readHitmen(suspect.id)) do
            if row.hitman_cid == 'HITMAN01' then hitmanId = row.id end
        end
        local blind = ask(6, 'removeHitman', { id = suspect.id, hitman = hitmanId, reason = 'x' })
        falsy(blind.ok)
        truthy(blind.err ~= CH.ERR.CONTRACT_FROZEN, 'not "on hold": ' .. tostring(blind.err))
        falsy(tostring(blind.message):find('hold', 1, true), tostring(blind.message))
        local seeing = ask(8, 'removeHitman', { id = suspect.id, hitman = hitmanId, reason = 'x' })
        eq(seeing.err, CH.ERR.CONTRACT_FROZEN, 'staff who may see it are told')
        eq(s.storage.readHitman(suspect.id, 'HITMAN01').state, 'active', 'nothing removed')
    end)
end)

--------------------------------------------------------------------------
-- U1: cuts by characters
--------------------------------------------------------------------------

describe('bug sweep U1: text kept for the store is never cut through a character', function()
    local function valid(text, what)
        truthy(type(text) == 'string' and utf8.len(text) ~= nil, what .. ' is valid UTF-8: ' .. tostring(text))
    end
    local reason = ('a'):rep(119) .. 'é'
    local name = ('b'):rep(127) .. 'é'

    it('a freeze\'s reason and name', function()
        local s = newStack()
        fixture(s)
        truthy(s.holds.freeze('ADMIN001', 'TARGET01', reason, name))
        local row = s.holds.of('TARGET01')
        valid(row.reason, 'the reason')
        valid(row.name, 'the name')
        eq(row.reason, reason, 'kept whole: 120 characters')
    end)

    it('a suspension\'s reason and name', function()
        local s = newStack()
        fixture(s)
        truthy(s.sanctions.place('suspend', 'ADMIN001', 'TARGET01', 3600, reason .. 'xyz', name))
        local row = s.sanctions.suspended('TARGET01')
        valid(row.reason, 'the reason')
        valid(row.name, 'the name')
        eq(utf8.len(row.reason), 120)
    end)

    it('a manual payment\'s reason', function()
        local s = newStack()
        fixture(s)
        Config.Staff.ManualPaymentMax = 10000
        truthy(s.payments.pay('ADMIN001', 'TARGET01', 100, 'cash', reason .. 'xyz', name))
        local found
        for _, row in ipairs(s.sanctions.recordsOf('TARGET01')) do
            if row.kind == 'payment' then found = row end
        end
        truthy(found, 'recorded')
        valid(found.reason, 'the reason')
        valid(found.name, 'the name')
    end)

    it('a staff note\'s author', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            reward = { baseline = { cash = 5000 } } })
        local ok, _, row = s.staffContract.addNote({ cid = 'ADMIN001', name = name }, c.id, 'a note')
        truthy(ok)
        valid(row.author_name, 'the author')
    end)

    it('a refused panel request\'s op, as the log keeps it', function()
        local s = newStack()
        fixture(s)
        s.panel.handle(3, { op = ('o'):rep(31) .. 'é', data = {} })
        s.audit.flush()
        local seen = 0
        for _, row in ipairs(s.storage.readAudit()) do
            local op = type(row.detail) == 'table' and row.detail.op or nil
            if type(op) == 'string' then
                seen = seen + 1
                valid(op, 'the op')
            end
        end
        truthy(seen > 0, 'the refusal was logged')
    end)
end)

--------------------------------------------------------------------------
-- U2: the NPC loop when an NPC moves during its model load
--------------------------------------------------------------------------

describe('bug sweep U2: the roleplay NPC loop survives an NPC moving mid-load', function()
    it('makes no ped for a place gone meanwhile, and keeps running', function()
        local loaded, created, deleted = false, 0, 0
        local thread
        local handlers = {}
        local function vec(x, y, z)
            return setmetatable({ x = x, y = y, z = z }, {
                __sub = function(a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end,
                __len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end,
            })
        end
        local env = setmetatable({
            joaat = function() return 1234 end,
            IsModelInCdimage = function() return 1 end, IsModelValid = function() return 1 end,
            RequestModel = function() end,
            HasModelLoaded = function() return loaded end,
            SetModelAsNoLongerNeeded = function() end,
            CreatePed = function() created = created + 1; return 100 + created end,
            DoesEntityExist = function() return 1 end,
            DeleteEntity = function() deleted = deleted + 1 end,
            SetEntityInvincible = function() end, FreezeEntityPosition = function() end,
            SetBlockingOfNonTemporaryEvents = function() end, SetPedCanRagdoll = function() end,
            TaskStartScenarioInPlace = function() end,
            AddBlipForCoord = function() return 1 end, SetBlipSprite = function() end,
            SetBlipScale = function() end, SetBlipAsShortRange = function() end,
            BeginTextCommandSetBlipName = function() end,
            AddTextComponentSubstringPlayerName = function() end,
            EndTextCommandSetBlipName = function() end, RemoveBlip = function() end,
            DoesBlipExist = function() return 1 end, SetBlipColour = function() end,
            GetEntityCoords = function() return vec(0.0, 0.0, 0.0) end,
            PlayerPedId = function() return 1 end,
            vector3 = vec,
            Wait = function(ms) coroutine.yield(ms) end,
            SetTimeout = function() end,
            TriggerServerEvent = function() end,
            RegisterNetEvent = function(name, fn) handlers[name] = fn end,
            AddEventHandler = function(name, fn) handlers[name] = fn end,
            GetCurrentResourceName = function() return 'crimson-hitman' end,
            CreateThread = function(fn) thread = coroutine.create(fn) end,
        }, { __index = _G })
        assert(loadfile('crimson-hitman/shared/geo.lua', 't', env))()
        require('tests.harness.client_adapters')(env)
        assert(loadfile('crimson-hitman/client/missionsteps.lua', 't', env))()
        assert(loadfile('crimson-hitman/client/npc.lua', 't', env))()
        assert(loadfile('crimson-hitman/client/rp_npc.lua', 't', env))()
        local function step()
            local ok, err = coroutine.resume(thread)
            truthy(ok, 'the loop raised: ' .. tostring(err))
        end
        step()                     -- the first wait
        step()                     -- asks, then waits with nothing placed
        handlers['crimson-hitman:result']({ event = 'rpPlaces', ok = true, data = {
            broker = { x = 1.0, y = 1.0, z = 1.0, model = 'g_m_m_armboss_01', scenario = '' } } })
        step()                     -- near it: the model load starts and waits
        -- Staff took it away while the model loaded.
        handlers['crimson-hitman:result']({ event = 'rpPlaces', ok = true, data = {} })
        loaded = true
        step()
        eq(created - deleted, 0, 'no ped left behind')
        eq(coroutine.status(thread), 'suspended', 'the loop runs on')
        -- And put back: drawn once.
        handlers['crimson-hitman:result']({ event = 'rpPlaces', ok = true, data = {
            broker = { x = 1.0, y = 1.0, z = 1.0, model = 'g_m_m_armboss_01', scenario = '' } } })
        step()
        step()
        eq(created, 1, 'drawn where it stands now')
        eq(coroutine.status(thread), 'suspended')
    end)
end)

--------------------------------------------------------------------------
-- U3: a command name changed from the panel
--------------------------------------------------------------------------

describe('bug sweep U3: a restart-only setting waits for the restart', function()
    it('keeps the command in force until the next start, and shows the new one', function()
        local s = newStack()
        local was = Config.Admin.Commands.stuck
        truthy(s.settings.set('Admin.Commands.stuck', 'stuckx', 'ADMIN001', 'ADMIN001'))
        eq(Config.Admin.Commands.stuck, was, 'the registered name is what messages quote')
        local shown
        for _, row in ipairs(s.settings.view().limits) do
            if row.key == 'Admin.Commands.stuck' then shown = row end
        end
        eq(shown.value, 'stuckx', 'the panel shows what the next start uses')
        eq(shown.source, 'panel')
        -- Set back to what is in force: nothing waits.
        truthy(s.settings.set('Admin.Commands.stuck', was, 'ADMIN001', 'ADMIN001'))
        truthy(s.settings.set('Admin.Commands.stuck', 'stuckx', 'ADMIN001', 'ADMIN001'))
        -- The next start puts it in force.
        s.settings.init({ storage = s.storage, audit = s.audit,
                          check = require('crimson-hitman.server.main').checkCandidate })
        s.settings.boot()
        eq(Config.Admin.Commands.stuck, 'stuckx', 'in force after the restart')
    end)

    it('still puts a live key into force at once', function()
        local s = newStack()
        truthy(s.settings.set('Bailout.MaxMultiplier', 5, 'ADMIN001', 'ADMIN001'))
        eq(Config.Bailout.MaxMultiplier, 5)
    end)
end)
