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

--- A contract with `slots` collections, one hitman on it, and everybody in
--- place for a handover.
local function placed(slots, opts)
    opts = opts or {}
    local s = newStack()
    local f = fixture(s)
    Env.players[1].PlayerData.money.bank = 400000
    local list = {}
    for i = 1, slots do list[i] = { baseline = { cash = 1000 * i } } end
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
        reward = { slots = list },
    })
    truthy(c, 'the contract has to be placed')
    truthy(s.contracts.accept(f.hitman, c.id, false))
    if opts.second then
        Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
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

local function toldHitman(title)
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
        if event.name == 'crimson-hitman:push' and event.target == source then n = n + 1 end
    end
    return n
end

describe('a second collection on the same contract', function()
    it('refuses to arm a handover the claim is certain to refuse', function()
        local s, f, c = placed(2)
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION),
            'the first collection')

        -- Ten minutes of wait against a thirty-second countdown: the claim
        -- at the end would be refused, after the target had been held for
        -- all of it.
        local ok, err = s.kidnap.arm(c.id, 'HITMAN01')
        falsy(ok, 'armed a delivery the claim will refuse thirty seconds from now')
        eq(err, CH.ERR.SLOT_COOLDOWN)
        eq(s.kidnap.activeCount(), 0)

        Env.advance(Config.Limits.SlotCooldownSeconds + 1)
        truthy(s.kidnap.arm(c.id, 'HITMAN01'), 'and arms once the wait is over')
    end)

    it('names the wait between payouts rather than calling it a flood', function()
        local s, f, c = placed(2)
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        local _, err = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        truthy(err ~= CH.ERR.RATE_LIMITED, 'the page words rate_limited as '
            .. '"Slow down." and tells a hitman with a body to try again in a '
            .. 'few seconds, on a wait of ten minutes')
        eq(err, CH.ERR.SLOT_COOLDOWN)
    end)

    it('tells every party their card has changed', function()
        local s, f, c = placed(2, { second = true })
        Env.clientEvents = {}
        Env.advance(5)
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'a collection remains')

        truthy(pushesTo(1) >= 1, 'the creator went on being shown the first '
            .. 'collection after it had been paid')
        truthy(pushesTo(4) >= 1, 'the second hitman went on competing for a '
            .. 'collection that was gone')
    end)
end)

describe('a handover while another payout settles', function()
    it('survives the lock rather than being thrown away', function()
        local s, f, c = placed(2, { second = true })
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        ticks(s, Config.Kidnap.CountdownSeconds - 5)
        local before = s.kidnap.progress(c.id, 'HITMAN01').elapsed

        -- The other hitman's settlement holds the lock, across yields.
        truthy(s.contracts.transition(c.id, CH.STATE.ACCEPTED, CH.STATE.COMPLETING, 'claiming_slot'))
        ticks(s, 2)
        local during = s.kidnap.progress(c.id, 'HITMAN01')
        truthy(during, 'a countdown twenty-five seconds in was thrown away '
            .. 'because somebody else was being paid')
        eq(during.elapsed, before, 'and it does not run on while paused')
        truthy(s.contracts.transition(c.id, CH.STATE.COMPLETING, CH.STATE.ACCEPTED, 'slot_claimed'))

        Natives.calls.notifications = {}
        ticks(s, 6)
        eq(s.kidnap.activeCount(), 0)
        eq(s.storage.readContract(c.id).next_slot, 2, 'and it paid')
    end)

    it('does not wait forever on a lock that never lets go', function()
        local s, f, c = placed(2)
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        truthy(s.contracts.transition(c.id, CH.STATE.ACCEPTED, CH.STATE.COMPLETING, 'claiming_slot'))
        Natives.calls.notifications = {}
        ticks(s, 61)
        eq(s.kidnap.activeCount(), 0, 'a countdown paused on a dead settlement '
            .. 'holds one of the server handover slots until recovery runs')
        truthy(toldHitman('Handover failed') ~= '', 'and the hitman is told')
    end)
end)

describe('how a handover ended', function()
    local function progress(s, c, source)
        return s.app.handlers.kidnapProgress(s.identity.resolve(source), { id = c.id })
    end

    it('tells the poller it was paid, not that it ended', function()
        local s, f, c = placed(1)
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        ticks(s, Config.Kidnap.CountdownSeconds + 1)
        eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED)

        local out = progress(s, c, 3)
        truthy(out and out.done, 'the hitman who had just been paid was told '
            .. 'the handover ended and to try again')
        eq(out.outcome, 'paid')
    end)

    it('tells the hitman who lost the race what happened', function()
        local s, f, c = placed(1, { second = true })
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        truthy(s.kidnap.arm(c.id, 'HITMAN02'))
        Natives.calls.notifications = {}
        ticks(s, Config.Kidnap.CountdownSeconds + 1)

        local paid, refused = progress(s, c, 3), progress(s, c, 4)
        truthy(paid and refused, 'both have an answer')
        local outcomes = { [paid.outcome] = true, [refused.outcome] = true }
        truthy(outcomes.paid and outcomes.refused,
            'one was paid and one was refused: ' .. tostring(paid.outcome)
            .. ', ' .. tostring(refused.outcome))
        truthy(toldHitman('Handover not paid') ~= '', 'the refused hitman held '
            .. 'a restrained player for the whole countdown and was told nothing')

        s.audit.flush()
        local rows = 0
        for _, row in ipairs(s.storage.readAudit()) do
            if row.action == 'kidnap_claim_failed' then rows = rows + 1 end
        end
        eq(rows, 1, 'and there was not even an audit row')
    end)

    it('tells the hitman holding the target that the contract closed', function()
        local s, f, c = placed(1)
        s.bridges.install(s)  -- as main.lua wires it: resolving clears the handover
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        ticks(s, 5)
        Natives.calls.notifications = {}
        truthy(s.contracts.resolve(c.id, CH.STATE.VOIDED, 'CREATOR1', nil, 'voided'),
            'the contract closes underneath the handover')
        eq(s.kidnap.activeCount(), 0)
        truthy(toldHitman('Handover ended'):find('closed', 1, true),
            'the hitman holding a restrained player was told nothing')
        eq(progress(s, c, 3).outcome, 'closed')
    end)

    it('says the same when the tick is the first to notice', function()
        local s, f, c = placed(1)
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        truthy(s.contracts.resolve(c.id, CH.STATE.VOIDED, 'CREATOR1', nil, 'voided'))
        Natives.calls.notifications = {}
        ticks(s, 1)
        eq(s.kidnap.activeCount(), 0)
        truthy(toldHitman('Handover ended'):find('closed', 1, true),
            'dropped without a word')
        eq(progress(s, c, 3).outcome, 'closed')
    end)

    it('only ever describes the asker\'s own handover', function()
        local s, f, c = placed(1)
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        ticks(s, Config.Kidnap.CountdownSeconds + 1)
        local other = progress(s, c, 1)
        falsy(other and other.done, 'the creator read the hitman\'s outcome')
    end)
end)

describe('why a handover failed', function()
    local function failWith(setup)
        local s, f, c = placed(1)
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        setup(s)
        Natives.calls.notifications = {}
        for _ = 1, 10 do s.kidnap.tick(Config.Kidnap.MaxTotalGraceMs) end
        eq(s.kidnap.activeCount(), 0, 'the handover failed')
        return toldHitman('Handover failed')
    end

    it('does not tell the hitman they lost the target when the client crashed', function()
        local said = failWith(function() Env.removePlayer(1) end)
        falsy(said:find('lost hold', 1, true), 'sent after a target still in '
            .. 'their hands: ' .. said)
        -- Named as what they are to the hitman, with the distance they have
        -- to keep, from Config.Kidnap rather than a figure in the words.
        truthy(said:find('The person who placed this contract went offline', 1, true), said)
        truthy(said:find(('online and within %d m'):format(math.floor(Config.Kidnap.Radius)),
            1, true), said)
        falsy(said:find('client', 1, true), 'a hitman may not know who "the client" is: ' .. said)
    end)

    it('says so when it is the target who left', function()
        local said = failWith(function() Env.removePlayer(2) end)
        -- Not the grip wording: nobody slipped anybody's grip, and a hitman
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
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        Env.players[1]._coords = { x = 3000.0, y = 3000.0, z = 30.0 }
        for _ = 1, 10 do s.kidnap.tick(Config.Kidnap.MaxTotalGraceMs) end
        Env.players[1]._coords = AT
        return s, f, c
    end

    it('is not reset by the hitman relogging', function()
        local s, f, c = failed()
        s.kidnap.clearPlayer('HITMAN01')
        local ok, err = s.kidnap.arm(c.id, 'HITMAN01')
        falsy(ok, 'a relog reset the wait, so the hold has no time limit')
        eq(err, CH.ERR.HANDOVER_COOLDOWN)
    end)

    it('starts when a relog ends a countdown in progress', function()
        local s, f, c = placed(1)
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        s.kidnap.clearPlayer('HITMAN01')
        eq(s.kidnap.activeCount(), 0)
        local ok, err = s.kidnap.arm(c.id, 'HITMAN01')
        falsy(ok, 'relogging out of a countdown skipped the wait a failure owes')
        eq(err, CH.ERR.HANDOVER_COOLDOWN)
    end)

    it('still lets the hitman try again once it is over', function()
        local s, f, c = failed()
        s.kidnap.clearPlayer('HITMAN01')
        Env.advance(Config.Kidnap.RearmCooldownSeconds + 1)
        s.kidnap.clearPlayer('SOMEONE9')
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
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
        truthy(s.death.getPending(c.id, 'HITMAN01'), 'the server attributed the kill')
        return s, f, c
    end

    it('keeps the kill when the target closes the game', function()
        local s, f, c = killed()
        s.bridges.onPlayerDropped(s, 'TARGET01')
        truthy(s.death.getPending(c.id, 'HITMAN01'), 'quitting while dead '
            .. 'destroyed a kill the server itself had attributed')
        local token, err = s.photo.issue(f.hitman, c.id)
        truthy(token, 'the hitman standing over the body was told there was '
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

        local token, err = s.photo.issue(f.hitman, c.id)
        truthy(token, tostring(err))
        local ok, why = s.photo.submit(f.hitman, token, 'https://cdn.fivemanage.com/p.png')
        truthy(ok, 'the kill was refused as the target having just arrived: ' .. tostring(why))
        eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED)
    end)

    it('still protects a target who has just arrived from a death after it', function()
        local s = newStack()
        local f = fixture(s)
        s.identity.confirmSession('TARGET01')
        eq(s.contracts.isImmune(f.target,
            { deathAt = require('crimson-hitman.shared.util').monotonicMs() }), true,
            'a kill made after they arrived is the thing the floor is for')
        local _ = f
    end)

    it('still lets the kill go with the hitman who made it', function()
        local s, f, c = killed()
        s.death.clearPlayer('HITMAN01')
        falsy(s.death.getPending(c.id, 'HITMAN01'))
    end)
end)

describe('two changes to a contract inside one second', function()
    local function pushesTo(source)
        local n = 0
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:push' and event.target == source then n = n + 1 end
        end
        return n
    end

    it('still tells the open app about the second one', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 1000 } },
        })
        Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
            cash = 5000, bank = 5000, firstname = 'Kade', lastname = 'Wolfe' })
        Env.clientEvents = {}
        truthy(s.contracts.accept(f.hitman, c.id, false))
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

    it('does not let a message held behind an acceptance take its place', function()
        -- The page re-reads only the thread for a message, and everything
        -- for anything else. A message after the acceptance in the same
        -- second left the creator's card showing one operative.
        local s = newStack()
        s.notify.clearPush('CREATOR1')
        local f = fixture(s)
        Env.clientEvents = {}
        truthy(s.notify.push('CREATOR1', 'a'))
        s.notify.push('CREATOR1', 'accepted')
        s.notify.push('CREATOR1', 'message')
        Env.advance(2)
        local last
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:push' and event.target == 1 then
                last = event.args[1] and event.args[1].reason
            end
        end
        eq(last, 'accepted', 'the held push became a thread re-read')

        -- And the other way round, the fuller reason wins.
        Env.clientEvents = {}
        s.notify.push('CREATOR1', 'message')
        s.notify.push('CREATOR1', 'improved')
        Env.advance(2)
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:push' and event.target == 1 then
                last = event.args[1] and event.args[1].reason
            end
        end
        eq(last, 'improved')
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

describe('the other party\'s open page', function()
    --- A phone notification does not change a page that is already open;
    --- only a push does, and none was sent for any of these. A proposal ran
    --- out unseen, a thread never showed the reply, and a card kept showing
    --- terms that had changed.
    local function ready()
        local s, f, c = placed(1)
        s.notify.clearPush('CREATOR1')
        s.notify.clearPush('HITMAN01')
        Env.clientEvents = {}
        return s, f, c
    end

    it('is pushed when a change is proposed to it', function()
        local s, f, c = ready()
        truthy(s.amendments.propose(f.creator, c.id, CH.AMENDMENT.SHORTEN_DEADLINE, { seconds = 900 }))
        truthy(pushesTo(3) >= 1, 'the hitman is not told to re-read')
        eq(pushesTo(2), 0, 'and never the target')
    end)

    it('is pushed when a message arrives in its thread', function()
        local s, f, c = ready()
        local thread = s.comms.threads(f.creator, c.id)[1]
        truthy(s.comms.send(f.creator, c.id, thread.handle, 'there yet?'))
        truthy(pushesTo(3) >= 1, 'the reply never reached an open thread')
    end)

    it('is pushed when the reward is added to', function()
        local s, f, c = ready()
        truthy(s.amendments.addEscrow(f.creator, c.id, { baseline = { cash = 500 } }))
        truthy(pushesTo(3) >= 1, 'the hitman card kept the old reward')
    end)

    it('is pushed when a hitman walks away', function()
        local s, f, c = ready()
        truthy(s.contracts.abandon(f.hitman, c.id))
        truthy(pushesTo(1) >= 1, 'the client card still showed an operative on it')
    end)
end)

describe('a push names the contract it is about', function()
    --- Every push made an open Mine tab re-read every contract's proposals:
    --- three placed and three taken were nine reads from the bucket the
    --- board, Mine and the ledger share. A push names its contract now, to
    --- the people who already have that id, so the page re-reads that one.
    local function pushes(source)
        local out = {}
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:push' and event.target == source then
                out[#out + 1] = event.args[1]
            end
        end
        return out
    end

    local function ready()
        local s = newStack()
        local f = fixture(s)
        for _, cid in ipairs({ 'CREATOR1', 'TARGET01', 'HITMAN01' }) do s.notify.clearPush(cid) end
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 1000 } },
        })
        Env.clientEvents = {}
        return s, f, c
    end

    it('names it to the client and the hitman on an acceptance', function()
        local s, f, c = ready()
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local toClient, toHitman = pushes(1), pushes(3)
        eq(#toClient, 1)
        eq(toClient[1].ids and toClient[1].ids[1], c.id)
        eq(toHitman[1] and toHitman[1].ids and toHitman[1].ids[1], c.id)
    end)

    it('never names it to the target', function()
        local s, f, c = ready()
        -- Once the target has been shown it: inside the wait nothing tells
        -- them it exists, a push included (anonymity_spec).
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        -- And past the floor the alert's own push started (Notify.paranoid
        -- moves an open On me as it arrives).
        Env.advance(Config.Notifications.PushMinIntervalSeconds or 1)
        Env.clientEvents = {}
        truthy(s.contracts.cancel(f.creator, c.id))
        local toTarget = pushes(2)
        eq(#toTarget, 1, 'the target is still nudged when it ends')
        eq(toTarget[1].ids, nil,
            'the push told the target which contract, which only the projection may')
        eq(pushes(1)[1].ids[1], c.id, 'and the client still gets its own')
    end)

    it('names every contract a held burst was about', function()
        local s = ready()
        truthy(s.notify.push('CREATOR1', 'a', 'ct1'))
        s.notify.push('CREATOR1', 'proposal', 'ct3')
        s.notify.push('CREATOR1', 'amended', 'ct2')
        -- A message names none and needs none: the page re-reads the thread.
        s.notify.push('CREATOR1', 'message')
        Env.advance(2)
        local got = pushes(1)
        eq(#got, 2)
        eq(got[1].ids[1], 'ct1')
        eq(table.concat(got[2].ids or {}, ','), 'ct2,ct3',
            'the held push stands for both, so it has to name both')
        eq(got[2].reason, 'amended')
    end)

    it('names none once anything in the burst named none', function()
        local s = ready()
        truthy(s.notify.push('CREATOR1', 'a', 'ct1'))
        s.notify.push('CREATOR1', 'proposal', 'ct2')
        s.notify.push('CREATOR1', 'settled')
        Env.advance(2)
        local got = pushes(1)
        eq(#got, 2)
        eq(got[2].ids, nil, 'a page told only ct2 would not re-read what the other one changed')
    end)
end)
