--- The journeys around collecting a payout: a handover, a second collection
--- on the same contract, and a kill whose victim leaves.
---
--- Each of these was found by walking a player through the whole sequence.
--- Every call along the way did what it said; what went wrong was what the
--- player was told, or not told, at the end.

local AT = { x = 200.0, y = 200.0, z = 30.0 }

local function together()
    for _, src in ipairs({ 1, 2, 3, 4 }) do
        if Env.players[src] then
            Env.players[src]._coords = { x = AT.x, y = AT.y, z = AT.z }
        end
    end
    Env.players[2].PlayerData.metadata.ishandcuffed = true
end

--- A contract with `slots` collections, one hunter on it, and everybody in
--- place for a handover.
local function placed(slots, opts)
    opts = opts or {}
    local s = newStack()
    local f = fixture(s)
    Env.players[1].PlayerData.money.bank = 400000
    local list = {}
    for i = 1, slots do list[i] = { baseline = { cash = 1000 * i } } end
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
        reward = { slots = list },
    })
    truthy(c, 'the contract has to be placed')
    truthy(s.contracts.accept(f.hunter, c.id, false))
    if opts.second then
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd',
            cash = 5000, bank = 5000, firstname = 'Kade', lastname = 'Wolfe' })
        truthy(s.contracts.accept(s.identity.resolve(4), c.id, false))
    end
    together()
    return s, f, c
end

local function ticks(s, seconds)
    for _ = 1, math.ceil((seconds * 1000) / Config.Kidnap.TickMs) do
        s.kidnap.tick(Config.Kidnap.TickMs)
    end
end

local function toldHunter(title)
    local said = {}
    for _, note in ipairs(Natives.calls.notifications or {}) do
        if not title or tostring(note.title) == title then
            said[#said + 1] = tostring(note.content)
        end
    end
    return table.concat(said, ' | ')
end

local function pushesTo(source)
    local n = 0
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-bounty:push' and event.target == source then n = n + 1 end
    end
    return n
end

describe('a second collection on the same contract', function()
    it('refuses to arm a handover the claim is certain to refuse', function()
        local s, f, c = placed(2)
        truthy(s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION),
            'the first collection')

        -- Ten minutes of wait against a thirty-second countdown: the claim
        -- at the end would be refused, after the target had been held for
        -- all of it.
        local ok, err = s.kidnap.arm(c.id, 'HUNTER01')
        falsy(ok, 'armed a delivery the claim will refuse thirty seconds from now')
        eq(err, CB.ERR.SLOT_COOLDOWN)
        eq(s.kidnap.activeCount(), 0)

        Env.advance(Config.Limits.SlotCooldownSeconds + 1)
        truthy(s.kidnap.arm(c.id, 'HUNTER01'), 'and arms once the wait is over')
    end)

    it('names the wait between payouts rather than calling it a flood', function()
        local s, f, c = placed(2)
        truthy(s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION))
        local _, err = s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
        truthy(err ~= CB.ERR.RATE_LIMITED, 'the page words rate_limited as '
            .. '"Slow down." and tells a hunter with a body to try again in a '
            .. 'few seconds, on a wait of ten minutes')
        eq(err, CB.ERR.SLOT_COOLDOWN)
    end)

    it('tells every party their card has changed', function()
        local s, f, c = placed(2, { second = true })
        Env.clientEvents = {}
        Env.advance(5)
        truthy(s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION))
        eq(s.storage.readContract(c.id).state, CB.STATE.ACCEPTED, 'a collection remains')

        truthy(pushesTo(1) >= 1, 'the creator went on being shown the first '
            .. 'collection after it had been paid')
        truthy(pushesTo(4) >= 1, 'the second hunter went on competing for a '
            .. 'collection that was gone')
    end)
end)

describe('a handover while another payout settles', function()
    it('survives the lock rather than being thrown away', function()
        local s, f, c = placed(2, { second = true })
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))
        ticks(s, Config.Kidnap.CountdownSeconds - 5)
        local before = s.kidnap.progress(c.id, 'HUNTER01').elapsed

        -- The other hunter's settlement holds the lock, across yields.
        truthy(s.contracts.transition(c.id, CB.STATE.ACCEPTED, CB.STATE.COMPLETING, 'claiming_slot'))
        ticks(s, 2)
        local during = s.kidnap.progress(c.id, 'HUNTER01')
        truthy(during, 'a countdown twenty-five seconds in was thrown away '
            .. 'because somebody else was being paid')
        eq(during.elapsed, before, 'and it does not run on while paused')
        truthy(s.contracts.transition(c.id, CB.STATE.COMPLETING, CB.STATE.ACCEPTED, 'slot_claimed'))

        Natives.calls.notifications = {}
        ticks(s, 6)
        eq(s.kidnap.activeCount(), 0)
        eq(s.storage.readContract(c.id).next_slot, 2, 'and it paid')
    end)

    it('does not wait forever on a lock that never lets go', function()
        local s, f, c = placed(2)
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))
        truthy(s.contracts.transition(c.id, CB.STATE.ACCEPTED, CB.STATE.COMPLETING, 'claiming_slot'))
        Natives.calls.notifications = {}
        ticks(s, 61)
        eq(s.kidnap.activeCount(), 0, 'a countdown paused on a dead settlement '
            .. 'holds one of the server handover slots until recovery runs')
        truthy(toldHunter('Handover failed') ~= '', 'and the hunter is told')
    end)
end)

describe('how a handover ended', function()
    local function progress(s, c, source)
        return s.app.handlers.kidnapProgress(s.identity.resolve(source), { id = c.id })
    end

    it('tells the poller it was paid, not that it ended', function()
        local s, f, c = placed(1)
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))
        ticks(s, Config.Kidnap.CountdownSeconds + 1)
        eq(s.storage.readContract(c.id).state, CB.STATE.COMPLETED)

        local out = progress(s, c, 3)
        truthy(out and out.done, 'the hunter who had just been paid was told '
            .. 'the handover ended and to try again')
        eq(out.outcome, 'paid')
    end)

    it('tells the hunter who lost the race what happened', function()
        local s, f, c = placed(1, { second = true })
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))
        truthy(s.kidnap.arm(c.id, 'HUNTER02'))
        Natives.calls.notifications = {}
        ticks(s, Config.Kidnap.CountdownSeconds + 1)

        local paid, refused = progress(s, c, 3), progress(s, c, 4)
        truthy(paid and refused, 'both have an answer')
        local outcomes = { [paid.outcome] = true, [refused.outcome] = true }
        truthy(outcomes.paid and outcomes.refused,
            'one was paid and one was refused: ' .. tostring(paid.outcome)
            .. ', ' .. tostring(refused.outcome))
        truthy(toldHunter('Handover not paid') ~= '', 'the refused hunter held '
            .. 'a restrained player for the whole countdown and was told nothing')

        s.audit.flush()
        local rows = 0
        for _, row in ipairs(s.storage.readAudit()) do
            if row.action == 'kidnap_claim_failed' then rows = rows + 1 end
        end
        eq(rows, 1, 'and there was not even an audit row')
    end)

    it('tells the hunter holding the target that the contract closed', function()
        local s, f, c = placed(1)
        s.bridges.install(s)  -- as main.lua wires it: resolving clears the handover
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))
        ticks(s, 5)
        Natives.calls.notifications = {}
        truthy(s.contracts.resolve(c.id, CB.STATE.VOIDED, 'CREATOR1', nil, 'voided'),
            'the contract closes underneath the handover')
        eq(s.kidnap.activeCount(), 0)
        truthy(toldHunter('Handover ended'):find('closed', 1, true),
            'the hunter holding a restrained player was told nothing')
        eq(progress(s, c, 3).outcome, 'closed')
    end)

    it('says the same when the tick is the first to notice', function()
        local s, f, c = placed(1)
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))
        truthy(s.contracts.resolve(c.id, CB.STATE.VOIDED, 'CREATOR1', nil, 'voided'))
        Natives.calls.notifications = {}
        ticks(s, 1)
        eq(s.kidnap.activeCount(), 0)
        truthy(toldHunter('Handover ended'):find('closed', 1, true),
            'dropped without a word')
        eq(progress(s, c, 3).outcome, 'closed')
    end)

    it('only ever describes the asker\'s own handover', function()
        local s, f, c = placed(1)
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))
        ticks(s, Config.Kidnap.CountdownSeconds + 1)
        local other = progress(s, c, 1)
        falsy(other and other.done, 'the creator read the hunter\'s outcome')
    end)
end)

describe('why a handover failed', function()
    local function failWith(setup)
        local s, f, c = placed(1)
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))
        setup(s)
        Natives.calls.notifications = {}
        for _ = 1, 10 do s.kidnap.tick(Config.Kidnap.MaxTotalGraceMs) end
        eq(s.kidnap.activeCount(), 0, 'the handover failed')
        return toldHunter('Handover failed')
    end

    it('does not tell the hunter they lost the target when the client crashed', function()
        local said = failWith(function() Env.removePlayer(1) end)
        falsy(said:find('lost hold', 1, true), 'sent after a target still in '
            .. 'their hands: ' .. said)
        truthy(said:find('client', 1, true), said)
    end)

    it('says so when it is the target who left', function()
        local said = failWith(function() Env.removePlayer(2) end)
        -- Not the grip wording: nobody slipped anybody's grip, and a hunter
        -- told they did goes looking for a target who is not in the city.
        truthy(said:find('left the city', 1, true), said)
    end)

    it('still says the client never arrived when they walked off', function()
        local said = failWith(function()
            Env.players[1]._coords = { x = 3000.0, y = 3000.0, z = 30.0 }
        end)
        truthy(said:find('did not arrive', 1, true), said)
    end)
end)

describe('the re-arm wait across a relog', function()
    local function failed()
        local s, f, c = placed(1)
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))
        Env.players[1]._coords = { x = 3000.0, y = 3000.0, z = 30.0 }
        for _ = 1, 10 do s.kidnap.tick(Config.Kidnap.MaxTotalGraceMs) end
        Env.players[1]._coords = AT
        return s, f, c
    end

    it('is not reset by the hunter relogging', function()
        local s, f, c = failed()
        s.kidnap.clearPlayer('HUNTER01')
        local ok, err = s.kidnap.arm(c.id, 'HUNTER01')
        falsy(ok, 'a relog reset the wait, so the hold has no time limit')
        eq(err, CB.ERR.HANDOVER_COOLDOWN)
    end)

    it('starts when a relog ends a countdown in progress', function()
        local s, f, c = placed(1)
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))
        s.kidnap.clearPlayer('HUNTER01')
        eq(s.kidnap.activeCount(), 0)
        local ok, err = s.kidnap.arm(c.id, 'HUNTER01')
        falsy(ok, 'relogging out of a countdown skipped the wait a failure owes')
        eq(err, CB.ERR.HANDOVER_COOLDOWN)
    end)

    it('still lets the hunter try again once it is over', function()
        local s, f, c = failed()
        s.kidnap.clearPlayer('HUNTER01')
        Env.advance(Config.Kidnap.RearmCooldownSeconds + 1)
        s.kidnap.clearPlayer('SOMEONE9')
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))
    end)
end)

describe('a kill whose victim leaves', function()
    local function killed()
        local s, f, c = placed(1)
        Env.players[2].PlayerData.metadata.ishandcuffed = false
        Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
        Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
        Env.players[2]._health = (Env.players[2]._health or 200) - 60
        s.death.recordDamage(3, 2, 123456)
        Env.players[2].PlayerData.metadata.isdead = true
        s.death.onVictimReport(2)
        truthy(s.death.getPending(c.id, 'HUNTER01'), 'the server attributed the kill')
        return s, f, c
    end

    it('keeps the kill when the target closes the game', function()
        local s, f, c = killed()
        s.bridges.onPlayerDropped(s, 'TARGET01')
        truthy(s.death.getPending(c.id, 'HUNTER01'), 'quitting while dead '
            .. 'destroyed a kill the server itself had attributed')
        local token, err = s.photo.issue(f.hunter, c.id)
        truthy(token, 'the hunter standing over the body was told there was '
            .. 'no kill to verify: ' .. tostring(err))
    end)

    it('pays for the kill when the target quits and comes straight back', function()
        local s, f, c = killed()
        s.photo.loadAllowedHosts()
        -- A long-standing session, so the floor is not already in play.
        s.identity.beginSession('TARGET01', false)
        Env.advance(5)
        s.bridges.onPlayerDropped(s, 'TARGET01')
        local target = Env.players[2]
        Env.removePlayer(2)
        Env.advance(15)
        Env.players[2] = target
        Env.byCitizen['TARGET01'] = 2
        Env.players[2].PlayerData.metadata.isdead = false
        -- What the login bridge does for a real login.
        s.identity.confirmSession('TARGET01')
        eq(s.identity.sessionMinutes('TARGET01'), 0, 'a new session, just begun')

        local token, err = s.photo.issue(f.hunter, c.id)
        truthy(token, tostring(err))
        local ok, why = s.photo.submit(f.hunter, token, 'https://cdn.fivemanage.com/p.png')
        truthy(ok, 'the kill was refused as the target having just arrived: ' .. tostring(why))
        eq(s.storage.readContract(c.id).state, CB.STATE.COMPLETED)
    end)

    it('still protects a target who has just arrived from a death after it', function()
        local s = newStack()
        local f = fixture(s)
        s.identity.confirmSession('TARGET01')
        eq(s.contracts.isImmune(f.target,
            { deathAt = require('crimson-bounty.shared.util').monotonicMs() }), true,
            'a kill made after they arrived is the thing the floor is for')
        local _ = f
    end)

    it('still lets the kill go with the hunter who made it', function()
        local s, f, c = killed()
        s.death.clearPlayer('HUNTER01')
        falsy(s.death.getPending(c.id, 'HUNTER01'))
    end)
end)

describe('two changes to a contract inside one second', function()
    local function pushesTo(source)
        local n = 0
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-bounty:push' and event.target == source then n = n + 1 end
        end
        return n
    end

    it('still tells the open app about the second one', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 1000 } },
        })
        Env.addPlayer({ source = 4, citizenid = 'HUNTER02', license = 'license:ddd',
            cash = 5000, bank = 5000, firstname = 'Kade', lastname = 'Wolfe' })
        Env.clientEvents = {}
        truthy(s.contracts.accept(f.hunter, c.id, false))
        truthy(s.contracts.accept(s.identity.resolve(4), c.id, false))
        eq(pushesTo(1), 1, 'one refresh now, not two')

        -- The refresh the first push caused can have read the contract
        -- before the second acceptance landed. Something has to follow it.
        Env.advance(2)
        eq(pushesTo(1), 2, 'the creator\'s card went on showing one operative')
    end)

    it('sends one trailing push for a whole burst, not one each', function()
        local s = newStack()
        s.notify.clearPush('CREATOR1')
        local f = fixture(s)
        Env.clientEvents = {}
        truthy(s.notify.push('CREATOR1', 'a'))
        local timers = #Env.timers
        for _ = 1, 5 do s.notify.push('CREATOR1', 'b') end
        eq(#Env.timers, timers + 1, 'a timer per held push, where one would do')
        Env.advance(2)
        eq(pushesTo(1), 2)
        local _ = f
    end)

    it('does not push a player who has left', function()
        local s = newStack()
        local f = fixture(s)
        Env.clientEvents = {}
        truthy(s.notify.push('CREATOR1', 'a'))
        s.notify.push('CREATOR1', 'b')
        s.notify.clearPlayer('CREATOR1')
        Env.advance(2)
        eq(pushesTo(1), 1)
        local _ = f
    end)
end)
