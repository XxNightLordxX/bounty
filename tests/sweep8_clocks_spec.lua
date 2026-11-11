--- Sweep 8, contract state, clocks and holds: each finding the skeptic
--- confirmed, as the probe that showed it, now held.
---
---   S8-STATE-1  an app pause whose end the store could not keep is not given
---               back a second time at the next start;
---   S8-STATE-3  a kill made in time outlives a staff freeze longer than its
---               verify window, and runs out on the time it had left;
---   S8-STATE-5  a stranger's accept on a frozen contract answers as an open
---               one would, and is refused only where an open one is taken;
---   S8-STATE-6  an unfreeze's awaits never let a proposal it holds expire;
---   S8-STATE-7  the freezes coming back from unreadable give the proposals
---               and the pending kills the outage, as an unfreeze does;
---   S8-STATE-8  an organisation's reservation and accept approvals stand
---               still while their contract is held.
---
--- S8-STATE-4 (disposal's ceiling) is in tests/disposal_spec.lua, beside the
--- disposal holds it extends.

local W = require('tests.workflows.lib')
local F = require('tests.workflows.flows')
local OrgW = require('tests.harness.org_world')

local REASON = 'a long enough reason here'

local function place(s, a, extra)
    local payload = { targetCid = 'TARGET01', reason = REASON, mode = CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 } } }
    for k, v in pairs(extra or {}) do payload[k] = v end
    local c, err = s.contracts.create(a, payload)
    assert(c, 'placed: ' .. tostring(err))
    return c
end

describe('S8-STATE-1: the end of an app pause the store could not keep', function()
    it('is not given back again at the next start, and is written once the store answers', function()
        local _, s = W.boot('json', 'shipped')
        local a = W.cast(s)
        local c = place(s, a.creator)
        local exp0 = s.storage.readContract(c.id).expires_at
        Config.Holds.AppPaused = true
        s.holds.syncAppPause()
        Env.advance(3600)
        local real = s.storage.writeStaffMeta
        s.storage.writeStaffMeta = function(k, v)
            if v == 0 then error('db down') end
            return real(k, v)
        end
        Config.Holds.AppPaused = false
        s.holds.syncAppPause()
        s.storage.writeStaffMeta = real
        local exp1 = s.storage.readContract(c.id).expires_at
        eq(exp1 - exp0, 3600, 'the pause given back once')
        Env.advance(600)
        local _, s2 = W.restart(s, true)
        eq(s2.storage.readContract(c.id).expires_at - exp1, 0, 'nothing given back a second time')
        falsy(s2.holds.global('app'), 'and the pause is not on again')
        -- The store is told the end from the tick.
        s2.holds.tick()
        eq(tonumber(s2.storage.readStaffMeta().staff_pause_since) or 0, 0, 'the end written once it could be')
    end)

    it('with nothing failing, a pause still holds across a restart and gives its time back once', function()
        local _, s = W.boot('json', 'shipped')
        local a = W.cast(s)
        local c = place(s, a.creator)
        local exp0 = s.storage.readContract(c.id).expires_at
        Config.Holds.AppPaused = true
        s.holds.syncAppPause()
        Env.advance(1200)
        local _, s2 = W.restart(s, true)
        truthy(s2.holds.global('app'), 'still paused after the restart')
        Env.advance(600)
        Config.Holds.AppPaused = false
        s2.holds.syncAppPause()
        eq(s2.storage.readContract(c.id).expires_at - exp0, 1800, 'the whole pause, once')
    end)
end)

describe('S8-STATE-3: a kill pending a photo, under a staff freeze', function()
    local function killed(holdSeconds, who)
        local main, s = W.boot('memory', 'shipped')
        W.cast(s)
        local ctx = { reward = 5000 }
        F.kill.setup(ctx)
        F.stepPlace().run(ctx)
        F.stepAccept().run(ctx)
        F.stepKill().run(ctx)
        Env.advance(10)
        truthy(s.holds.freeze('ADMIN001', who or 'TARGET01', 'checking a report'))
        Env.advance(5)
        W.at(3, 100.0, 100.0, 30.0)
        local during = W.phone(3, 'verifyKill', { id = ctx.id })
        Env.advance(holdSeconds - 5)
        W.tick(1)
        truthy(s.holds.unfreeze('ADMIN001', who or 'TARGET01', 'fine'))
        return main, s, ctx, during
    end

    it('is refused while frozen, and verified after a freeze longer than its window', function()
        local _, s, ctx, during = killed(300)
        falsy(during and during.ok, 'no verify while frozen')
        Env.advance(20)
        W.at(3, 100.0, 100.0, 30.0)
        local r = W.phone(3, 'verifyKill', { id = ctx.id })
        truthy(r and r.ok, 'the kill outlived the freeze: ' .. tostring(r and r.err))
    end)

    it('runs out on the time it had left when the freeze began, and no later', function()
        local _, s, ctx = killed(300, 'HITMAN01')
        local window = Config.Completion.PhotoTokenLifetimeSeconds
        Env.advance(window - 10 - 5)        -- 10 s used before the freeze
        truthy(s.death.getPending(ctx.id, 'HITMAN01'), 'still within what it had left')
        Env.advance(10)
        eq(s.death.getPending(ctx.id, 'HITMAN01'), nil, 'gone once that ran out')
    end)
end)

describe('S8-STATE-5: Accept on a contract a staff freeze holds, asked by a stranger', function()
    local function world()
        local _, s = W.boot('memory', 'shipped', function()
            Config.TargetClasses.default.AllowAnonymousPlacer = true
        end)
        local a = W.cast(s)
        local c1 = place(s, a.creator, { anonymous = true })
        local c2 = place(s, a.broker)
        truthy(s.holds.freeze('ADMIN001', 'CREATOR1', 'a report'))
        return s, a, c1, c2
    end

    it('is refused as a momentary lock once every check has passed, nothing taken', function()
        local s, a, c1, c2 = world()
        local before = W.purse(Env.players[4])
        local ok, err = s.contracts.accept(a.hitman2, c1.id)
        falsy(ok, 'not taken')
        eq(err, CH.ERR.BUSY, 'the code any locked contract gives')
        eq(s.storage.readHitman(c1.id, 'HITMAN02'), nil, 'no row')
        eq(W.purse(Env.players[4]), before, 'nothing charged')
        truthy(s.contracts.accept(a.hitman2, c2.id), 'the open one is taken')
    end)

    it('answers every earlier refusal as an open contract does', function()
        local s, a, c1, c2 = world()
        -- The target on their own contract, the placer's other contract: the
        -- same answers on the frozen one as on the open one.
        local _, onFrozen = s.contracts.accept(a.target, c1.id)
        local _, onOpen = s.contracts.accept(a.target, c2.id)
        eq(onFrozen, onOpen, 'the target is told the same on both')
        eq(onFrozen, CH.ERR.SELF_TARGET)
    end)
end)

describe('S8-STATE-6: an unfreeze on mysql, the expiry tick between its awaits', function()
    it('never closes a proposal the freeze held as expired, whichever await the tick lands in', function()
        for k = 1, 9 do
            local _, s = W.boot('mysql', 'shipped')
            local a = W.cast(s)
            local c = place(s, a.creator)
            truthy(s.contracts.accept(a.hitman, c.id))
            local p = s.amendments.propose(a.hitman, c.id, 'shorten_deadline', { seconds = 600 })
            local pid = type(p) == 'table' and p.id or p
            truthy(pid, 'proposed')
            local life = s.storage.readAmendment(pid).expires_at - os.time()
            truthy(s.holds.freeze('ADMIN001', 'TARGET01', 'x'))
            Env.advance(life + 60)
            s.amendments.expire()
            eq(s.storage.readAmendment(pid).outcome, 'open', 'held by the freeze')
            W.atAwait(k, 'pre', function() s.holds.unfreeze('ADMIN001', 'TARGET01') end,
                function() s.amendments.expire() end)
            s.amendments.expire()
            local row = s.storage.readAmendment(pid)
            eq(row.outcome, 'open', 'await ' .. k .. ': still open')
            truthy(row.expires_at > os.time(), 'await ' .. k .. ': with the frozen span given back')
        end
    end)
end)

describe('S8-STATE-7: the freezes read again after an outage', function()
    it('gives an open proposal the outage, as an unfreeze does', function()
        local _, s = W.boot('memory', 'shipped')
        local a = W.cast(s)
        local c = place(s, a.creator)
        truthy(s.contracts.accept(a.hitman, c.id))
        local p = s.amendments.propose(a.hitman, c.id, 'shorten_deadline', { seconds = 600 })
        local pid = type(p) == 'table' and p.id or p
        local life = s.storage.readAmendment(pid).expires_at - os.time()
        local real = s.storage.readFreezes
        s.storage.readFreezes = function() error('db down') end
        s.holds.reload()
        s.storage.readFreezes = real
        truthy(s.holds.on(s.storage.readContract(c.id), nil, 'staff'), 'held while unread')
        Env.advance(life + 60)
        s.amendments.expire()
        eq(s.storage.readAmendment(pid).outcome, 'open', 'not run out while unanswerable')
        s.holds.reload()
        s.amendments.expire()
        local row = s.storage.readAmendment(pid)
        eq(row.outcome, 'open', 'still open once the freezes are read')
        truthy(row.expires_at > os.time(), 'with the outage given back')
    end)

    it('keeps a kill pending through the outage', function()
        local _, s = W.boot('memory', 'shipped')
        W.cast(s)
        local ctx = { reward = 5000 }
        F.kill.setup(ctx)
        F.stepPlace().run(ctx)
        F.stepAccept().run(ctx)
        F.stepKill().run(ctx)
        local real = s.storage.readFreezes
        s.storage.readFreezes = function() error('db down') end
        s.holds.reload()
        s.storage.readFreezes = real
        Env.advance(Config.Completion.PhotoTokenLifetimeSeconds + 60)
        truthy(s.death.getPending(ctx.id, 'HITMAN01'), 'held while unread')
        s.holds.reload()
        Env.advance(10)
        truthy(s.death.getPending(ctx.id, 'HITMAN01'), 'and given the window it had left')
    end)
end)

describe('S8-STATE-8: an organisation contract on hold', function()
    local function world(on, extra)
        local s, f = OrgW.world({ configure = function()
            for _, key in ipairs(on) do Config.Organisation[key] = true end
            for k, v in pairs(extra or {}) do Config.Organisation[k] = v end
        end })
        OrgW.crew(s)
        return s, f, s.org.current()
    end

    it('keeps its reservation while a party to it is frozen, and releases it on time after', function()
        local s, f, org = world({ 'OrgContracts' }, { AssignMinutes = 5 })
        local c = OrgW.place(s, f.creator)
        truthy(s.org.receiveContract(c.id, 'CREATOR1'))
        local t0 = os.time()
        s.org.extrasTick(t0 + 60)
        truthy(s.holds.freeze('ADMIN001', 'CREATOR1', 'a report'))
        s.org.extrasTick(t0 + 10 * 60)
        truthy(org.settings.orgContracts[c.id], 'still reserved: nobody could take it meanwhile')
        truthy(s.holds.unfreeze('ADMIN001', 'CREATOR1', 'fine'))
        s.org.extrasTick(t0 + 12 * 60)
        truthy(org.settings.orgContracts[c.id], 'the time left when the hold began, still to run')
        s.org.extrasTick(t0 + 16 * 60)
        eq(org.settings.orgContracts[c.id], nil, 'released once it ran out')
    end)

    it('keeps an approval asked for while the app is paused', function()
        local s, f = world({ 'AcceptApproval' }, { ApprovalAbove = 1000 })
        OrgW.allow(s, 3, 'K6')
        local c = OrgW.place(s, f.creator, nil, { penaltyAmount = 500 })
        eq(select(2, s.contracts.accept(s.identity.resolve(13), c.id)), 'org_approval')
        local t0 = os.time()
        s.org.extrasTick(t0 + 60)
        Config.Holds.AppPaused = true
        s.holds.syncAppPause()
        s.org.extrasTick(t0 + 30 * 60)
        eq(#OrgW.call('orgWork', 11, {}).data.approvals, 1, 'not run out while nobody could accept')
        Config.Holds.AppPaused = false
        s.holds.syncAppPause()
    end)
end)
