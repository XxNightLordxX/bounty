--- Sweep 2 (the older core at 003249c): each decided fix, held to it.
---
---   1  the restart hold pauses every hit: no kill claimed, no instant
---      buyout charged; the placer's cancel still works;
---   2  a kill made while staff hold the contract opens nothing, so nothing
---      is claimable once it is released;
---   3  a freeze stopping a running handover tells the hitman it is on hold,
---      and a handover claim refused as frozen says so in words;
---   4  placing on a frozen target is refused as a protected target is, and
---      a frozen placer is still told they are on hold;
---   5  a freeze landing between an instant buyout's charge and its settle
---      tells the target it is on hold and that the premium came back;
---   6  with anonymity off, a named placer is named in the hitman's inbox
---      and a named operative in the placer's proposals.

local KIDNAP_AT = { x = 200.0, y = 200.0, z = 30.0 }

local function money(src)
    local m = Env.players[src].PlayerData.money
    return m.cash + m.bank
end

--- What a player was told, as 'title | content'.
local function notices(src)
    local out = {}
    for _, event in ipairs(Env.clientEvents) do
        if Natives.isNotice(event) and event.target == src then
            out[#out + 1] = tostring(event.args[1].title) .. ' | ' .. tostring(event.args[1].content)
        end
    end
    return out
end

local function has(list, needle)
    for _, text in ipairs(list) do if text:find(needle, 1, true) then return true end end
    return false
end

local function place(s, f, extra)
    local req = { targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
                  reward = { baseline = { cash = 5000 } } }
    for k, v in pairs(extra or {}) do req[k] = v end
    local c, err = s.contracts.create(f.creator, req)
    truthy(c, 'placed: ' .. tostring(err))
    return c
end

--- Run `fn` under the restart hold, released whichever way it ends: the
--- hold is the freeze module's own state, which no new stack clears.
local function underRestartHold(s, fn)
    Config.Holds.RestartPauseBeforeSeconds = 1800
    truthy(s.holds.scheduledRestart({ secondsRemaining = 300 }), 'the restart hold began')
    local ok, err = pcall(fn)
    s.holds.releaseRestart('skipped')
    if not ok then error(err, 0) end
end

--------------------------------------------------------------------------
-- 1: the restart hold pauses every hit
--------------------------------------------------------------------------

describe('sweep 2 fix 1: the restart hold stops hits', function()
    it('refuses an instant buyout before anything is charged', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f, { bailoutAmount = 1000 })
        underRestartHold(s, function()
            local before = money(2)
            local ok, err = s.bailout.buy(f.target, c.id)
            falsy(ok, 'bought out during the restart hold')
            eq(err, CH.ERR.RESTART_HOLD)
            eq(money(2), before, 'nothing was charged')
            eq(s.storage.readContract(c.id).state, CH.STATE.ACTIVE, 'the contract is still live')
        end)
        truthy(s.bailout.buy(f.target, c.id), 'bought out once the hold is released')
    end)

    it('still takes a buyout queued behind a hitman, which waits out the hold', function()
        local s = newStack()
        local f = fixture(s)
        Config.Bailout.ProcessingDelaySeconds = 60
        local c = place(s, f, { bailoutAmount = 1000 })
        truthy(s.contracts.accept(f.hitman, c.id, false), 'accepted')
        underRestartHold(s, function()
            local ok, err, queued = s.bailout.buy(f.target, c.id)
            truthy(ok, 'queued: ' .. tostring(err))
            eq(queued, true, 'it waits in the queue')
            Env.advance(120)
            eq(s.bailout.processQueue(), 0, 'nothing settles during the hold')
            eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED)
        end)
    end)

    it('refuses a kill claim', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false), 'accepted')
        Env.players[2].PlayerData.metadata.isdead = true
        underRestartHold(s, function()
            local before = money(3)
            local ok, err = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
            falsy(ok, 'a kill was paid during the restart hold')
            eq(err, CH.ERR.RESTART_HOLD)
            eq(money(3), before, 'nothing was paid')
            eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'the contract is still live')
        end)
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION),
            'claimed once the hold is released')
    end)

    it('still lets the placer withdraw a contract', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f)
        underRestartHold(s, function()
            local ok, err = s.contracts.cancel(f.creator, c.id)
            truthy(ok, 'withdrawn: ' .. tostring(err))
            eq(s.storage.readContract(c.id).state, CH.STATE.CANCELLED)
        end)
    end)

    it('words the refusal on /cleanse', function()
        local source = read_file('crimson-hitman/server/bridges.lua')
        truthy(source:find("[CH.ERR.RESTART_HOLD] = 'contracts are paused until the server restart.'", 1, true),
            'the buyout command says why')
    end)
end)

--------------------------------------------------------------------------
-- 2: a kill made while frozen opens nothing
--------------------------------------------------------------------------

describe('sweep 2 fix 2: a kill on a frozen contract opens no pending kill', function()
    local function killTarget(s)
        Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
        Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
        Env.players[2]._health = (Env.players[2]._health or 200) - 60
        s.death.recordDamage(3, 2, 123456)
        Env.players[2].PlayerData.metadata.isdead = true
        return s.death.onVictimReport(2)
    end

    it('leaves nothing claimable after an unfreeze within the photo lifetime', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false), 'accepted')
        truthy(s.holds.freeze('ADMIN001', 'TARGET01', 'dispute'), 'frozen')
        eq(killTarget(s), 0, 'a kill opened on a contract staff hold')
        falsy(s.death.getPending(c.id, 'HITMAN01'), 'nothing pending while frozen')

        Env.advance(math.max(1, Config.Completion.PhotoTokenLifetimeSeconds // 4))
        truthy(s.holds.unfreeze('ADMIN001', 'TARGET01'), 'released')
        falsy(s.death.getPending(c.id, 'HITMAN01'), 'nothing claimable once released')
        local token, err = s.photo.issue(f.hitman, c.id)
        falsy(token, 'a photo token for a kill made on hold')
        eq(err, CH.ERR.NO_KILL_TO_VERIFY)
    end)

    it('still opens one on a contract nobody holds', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false), 'accepted')
        eq(killTarget(s), 1)
        truthy(s.death.getPending(c.id, 'HITMAN01'))
    end)
end)

--------------------------------------------------------------------------
-- 3: a freeze during a handover
--------------------------------------------------------------------------

describe('sweep 2 fix 3: a handover stopped or refused by a freeze says so', function()
    local function armed()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f, { mode = CH.MODE.EXCLUSIVE })
        truthy(s.contracts.accept(f.hitman, c.id, false), 'accepted')
        for _, src in ipairs({ 1, 2, 3 }) do
            Env.players[src]._coords = { x = KIDNAP_AT.x, y = KIDNAP_AT.y, z = KIDNAP_AT.z }
        end
        Env.players[2].PlayerData.metadata.ishandcuffed = true
        truthy(s.kidnap.arm(c.id, 'HITMAN01'), 'armed')
        return s, f, c
    end

    local function run(s, seconds)
        for _ = 1, math.floor(seconds * 1000 / Config.Kidnap.TickMs) do
            s.kidnap.tick(Config.Kidnap.TickMs)
        end
    end

    it('records a countdown a freeze stopped as refused, on hold', function()
        local s, _, c = armed()
        run(s, 2)
        truthy(s.holds.freeze('ADMIN001', 'TARGET01', 'dispute'), 'frozen')
        falsy(s.kidnap.progress(c.id, 'HITMAN01'), 'the countdown stopped')
        local ended = s.kidnap.outcome(c.id, 'HITMAN01')
        truthy(ended, 'how it ended is kept for the hitman\'s page')
        eq(ended.outcome, 'refused')
        eq(ended.reason, CH.ERR.CONTRACT_FROZEN)
    end)

    it('tells the hitman a claim refused as frozen is on hold, not the generic words', function()
        local s, _, c = armed()
        local claim = s.contracts.claimSlot
        s.contracts.claimSlot = function(...)
            -- The freeze lands in the claim's awaits, after the countdown
            -- left the running list: nothing is left for it to cancel.
            s.holds.freeze('ADMIN001', 'TARGET01', 'dispute')
            return claim(...)
        end
        Env.clientEvents = {}
        local ok, err = pcall(run, s, Config.Kidnap.CountdownSeconds + 2)
        s.contracts.claimSlot = claim
        truthy(ok, tostring(err))
        local ended = s.kidnap.outcome(c.id, 'HITMAN01')
        truthy(ended, 'an outcome')
        eq(ended.outcome, 'refused')
        eq(ended.reason, CH.ERR.CONTRACT_FROZEN)
        local told = notices(3)
        truthy(has(told, 'Handover not paid | This contract is on hold by staff.'),
            'the hitman\'s notice: ' .. table.concat(told, ' / '))
        falsy(has(told, 'could not be collected'), 'not the generic words')
    end)
end)

--------------------------------------------------------------------------
-- 4: placing on a frozen target
--------------------------------------------------------------------------

describe('sweep 2 fix 4: placing on a frozen target tells nobody they are frozen', function()
    it('refuses a stranger as for a protected target', function()
        local s = newStack()
        local f = fixture(s)
        truthy(s.holds.freeze('ADMIN001', 'TARGET01', 'dispute'), 'frozen')
        local before = money(1)
        local c, err = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            reward = { baseline = { cash = 5000 } } })
        falsy(c, 'placed on a frozen target')
        eq(err, CH.ERR.TARGET_PROTECTED, 'the protected target\'s refusal, not contract_frozen')
        eq(money(1), before, 'nothing was charged')
    end)

    it('still tells a frozen placer it is about them', function()
        local s = newStack()
        local f = fixture(s)
        truthy(s.holds.freeze('ADMIN001', 'CREATOR1', 'dispute'), 'frozen')
        local c, err = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            reward = { baseline = { cash = 5000 } } })
        falsy(c)
        eq(err, CH.ERR.CONTRACT_FROZEN)
    end)
end)

--------------------------------------------------------------------------
-- 5: a freeze between an instant buyout's charge and its settle
--------------------------------------------------------------------------

describe('sweep 2 fix 5: a buyout frozen after its charge says on hold and refunded', function()
    it('returns the premium and says why', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f, { bailoutAmount = 1000 })
        local before = { money(1), money(2) }
        local Util = require('crimson-hitman.shared.util')
        local charge = Util.charge
        Util.charge = function(...)
            local paid = charge(...)
            -- Staff freeze the target the moment the premium is taken.
            s.holds.freeze('ADMIN001', 'TARGET01', 'dispute')
            return paid
        end
        Env.clientEvents = {}
        local ran, ok, err, third = pcall(s.bailout.buy, f.target, c.id)
        Util.charge = charge
        truthy(ran, tostring(ok))
        falsy(ok, 'bought out a contract on hold')
        eq(err, CH.ERR.CONTRACT_FROZEN, 'the reply says it is on hold')
        truthy(type(third) == 'table' and third.refunded == true, 'and that the premium came back')
        eq(money(2), before[2], 'the target has their premium back')
        eq(money(1), before[1], 'the placer was paid nothing')
        eq(s.storage.readContract(c.id).state, CH.STATE.ACTIVE, 'the contract is on hold, not closed')

        local told = notices(2)
        local premium = require('crimson-hitman.shared.words').dollars(s.storage.readContract(c.id).bailout_amount, 'before')
        truthy(has(told, 'Buyout refunded | Staff put the contract on hold before your buyout went '
            .. 'through, so your ' .. premium .. ' is back.'), 'the target\'s notice: ' .. table.concat(told, ' / '))
        falsy(has(told, 'could not be completed'), 'not the generic words')
        falsy(has(told, 'closed another way'), 'nor that it closed another way')
    end)

    it('says so on the page', function()
        local source = read_file('crimson-hitman/ui/app.js')
        truthy(source:find("result.err === 'contract_frozen' && result.data && result.data.refunded", 1, true),
            'failText words a refunded frozen buyout')
    end)
end)

--------------------------------------------------------------------------
-- 6: names with anonymity off
--------------------------------------------------------------------------

describe('sweep 2 fix 6: a named party is named where the viewer may see it', function()
    local function taken(opts)
        local s = newStack()
        local f = fixture(s)
        Env.players[3].PlayerData.money.bank = 50000
        local c = place(s, f, { anonymous = opts.anonCreator == true })
        truthy(s.contracts.accept(f.hitman, c.id, opts.anonHitman == true), 'accepted')
        return s, f, c
    end

    it('names a named placer in the hitman\'s inbox', function()
        local s, f, c = taken({})
        local mine = s.comms.threads(f.hitman, c.id)
        eq(#mine, 1)
        eq(mine[1].alias, 'Vic Marlowe', 'the placer chose to be seen')
    end)

    it('keeps an anonymous placer by role in the inbox', function()
        local s, f, c = taken({ anonCreator = true })
        local mine = s.comms.threads(f.hitman, c.id)
        eq(mine[1].alias, 'The person who placed it')
    end)

    it('names a named operative\'s proposal to the placer', function()
        local s, f, c = taken({})
        truthy(s.amendments.propose(f.hitman, c.id, CH.AMENDMENT.SHORTEN_DEADLINE, { seconds = 600 }))
        local open = s.amendments.openFor(f.creator, c.id)
        eq(open[1].proposer, 'Rook Ash', 'the operative chose to be seen')
    end)

    it('keeps an anonymous operative\'s proposal under the alias', function()
        local s, f, c = taken({ anonHitman = true })
        truthy(s.amendments.propose(f.hitman, c.id, CH.AMENDMENT.SHORTEN_DEADLINE, { seconds = 600 }))
        local proposer = tostring(s.amendments.openFor(f.creator, c.id)[1].proposer)
        falsy(proposer:find('Rook'), 'named: ' .. proposer)
        truthy(proposer:find('Operative'), 'the alias: ' .. proposer)
    end)

    it('names a named operative to nobody else on the contract', function()
        local s, f, c = taken({})
        Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
            cash = 5000, bank = 50000, firstname = 'Kit', lastname = 'Vane' })
        local other = s.identity.resolve(4)
        truthy(s.contracts.accept(other, c.id, false), 'a second operative')
        truthy(s.amendments.propose(f.hitman, c.id, CH.AMENDMENT.SHORTEN_DEADLINE, { seconds = 600 }))
        local proposer = tostring(s.amendments.openFor(other, c.id)[1].proposer)
        falsy(proposer:find('Rook'), 'another operative was told the name: ' .. proposer)
    end)

    it('names a named placer\'s proposal to the hitman, as before', function()
        local s, f, c = taken({})
        truthy(s.amendments.propose(f.creator, c.id, CH.AMENDMENT.SHORTEN_DEADLINE, { seconds = 600 }))
        eq(s.amendments.openFor(f.hitman, c.id)[1].proposer, 'Vic Marlowe')
    end)
end)
