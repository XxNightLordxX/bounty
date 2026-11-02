--- Board and progression improvements, group impB (server/imp_*.lua, README
--- Optional improvements): the placer's record on a board card, hitman
--- heat, the tiered board and contract decay.
---
--- What these hold:
---   * every one ships off, and off changes nothing: no key on a card, no
---     row kept, no money moved, no notice, no refusal;
---   * the placer's record names nobody, counts a named placer's named
---     contracts only, shows an anonymous placer's only when asked, in
---     bands, fixed when first drawn, so it never moves when another of
---     their contracts ends and never ties two anonymous contracts together;
---   * heat comes from whitelisted-job completions, witness reports and
---     police bulletins, cools after DecayHours, survives a restart, warns a
---     known hitman's target and sends police a bulletin naming nobody, at
---     most every BulletinEveryMinutes;
---   * a tier above the viewer's level is locked on their card, and Accept
---     on it is refused before anything is taken;
---   * contract decay raises an untaken reward through the placer's own
---     top-up path, conserving every dollar, stops when they cannot pay,
---     waits while they are away, caps, can be turned off by them alone,
---     survives a restart, and in 'shorten' brings the deadline in;
---   * every setting is in the panel, applied live, held to its rule;
---   * nothing on any new channel names a hidden party.

--- Config.Improvements put back as it was found, whatever the test did.
local function deepCopy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = deepCopy(v) end
    return out
end

local plainIt = it
local function it(name, fn)
    plainIt(name, function(...)
        local saved = deepCopy(Config.Improvements)
        local out = table.pack(pcall(fn, ...))
        Config.Improvements = saved
        if not out[1] then error(out[2], 0) end
    end)
end

local function stack(opts)
    opts = opts or {}
    local s = newStack()
    local f = fixture(s, { targetJob = opts.targetJob, creatorCash = 500000, creatorBank = 200000 })
    Config.Limits.TargetCooldownAfterResolveSeconds = 0
    Config.Limits.SameCreatorSameTargetCooldownSeconds = 0
    Config.Amendments.CancelCooldownSeconds = 0
    Config.Limits.MaxActiveContractsPerCreator = 20
    Config.Limits.MaxActiveContractsPerTarget = 20
    Config.Cooldowns.create = { per = 1, burst = 1000 }
    Config.Cooldowns.accept = { per = 1, burst = 1000 }
    Config.Cooldowns.load = { per = 1, burst = 1000 }
    Config.Anonymity.AllowAnonymousPlacer = true
    Config.Anonymity.AllowAnonymousHitman = true
    -- The paranoid alert at placing is a test of its own; here it would
    -- start the target's cooldown and hide the heat's warning.
    Config.Notifications.ParanoidAlert = false
    return s, f
end

--- Targets for the contracts a test places, one each unless it names one:
--- a placer may not have two live contracts on one person.
local fresh = 0
local function nextTarget()
    fresh = fresh + 1
    local src = 20 + fresh
    local cid = ('TGT%05d'):format(fresh)
    Env.addPlayer({ source = src, citizenid = cid, license = 'license:t' .. fresh,
        firstname = 'Tess', lastname = 'Target' .. fresh })
    return cid
end

local function place(s, f, opts)
    opts = opts or {}
    local c, err = s.contracts.create(opts.creator or f.creator, {
        targetCid = opts.target or nextTarget(), reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
        reward = opts.reward or { baseline = { cash = 10000 } }, anonymous = opts.anonymous == true,
    })
    truthy(c, 'placed: ' .. tostring(err))
    return c
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

local function boardCard(src, id)
    local reply = call('list', src, { page = 1 })
    truthy(reply and reply.ok, 'the board answers')
    for _, row in ipairs(reply.data.contracts) do
        if row.id == id then return row end
    end
    return nil
end

local function mineCard(src, id)
    local reply = call('mine', src, {})
    truthy(reply and reply.ok, 'Mine answers')
    local function find(list)
        for _, row in ipairs(list or {}) do if row.id == id then return row end end
    end
    return find(reply.data.created) or find(reply.data.accepted)
end

--- Every player's cash and bank, and the money every contract holds.
local function value(s)
    local total = 0
    for _, p in pairs(Env.players) do
        total = total + (p.PlayerData.money.cash or 0) + (p.PlayerData.money.bank or 0)
    end
    for _, c in ipairs(s.storage.allContracts()) do
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if CH.MONEY_SOURCES[line.source] and line.state ~= CH.ESCROW_STATE.SETTLED then
                total = total + (line.amount or 0) - (tonumber(line.deliver_arrived) or 0)
            end
        end
    end
    return total
end

local function audits(s, action)
    s.audit.flush()
    local n = 0
    for _, row in ipairs(s.storage.readAudit()) do
        if row.action == action then n = n + 1 end
    end
    return n
end

local function noticesTo(src, title)
    local n = 0
    for _, event in ipairs(Env.clientEvents) do
        if event.target == src and Natives.isNotice(event) then
            local data = event.args[1] or {}
            if title == nil or tostring(data.title) == title then n = n + 1 end
        end
    end
    return n
end

local function heatBulletins()
    local out = {}
    for _, sent in ipairs(Natives.calls.dispatch or {}) do
        if sent.caller == 'Criminal Intelligence' and tostring(sent.unique_id):find('^ch%-heat%-') then
            out[#out + 1] = sent
        end
    end
    return out
end

local IMP = { 'PlacerRecord', 'HitmanHeat', 'Tiers', 'ContractDecay' }

--------------------------------------------------------------------------
-- As shipped
--------------------------------------------------------------------------

describe('the board improvements as shipped', function()
    it('ships every one off, in config.lua and defaults.lua', function()
        local shipped = require('tests.harness.shipped').fromFile()
        for _, name in ipairs(IMP) do
            eq(shipped.Improvements[name].Enabled, false, name)
            eq(ConfigDefaults.Improvements[name].Enabled, false, name .. ' in defaults.lua')
        end
    end)

    it('changes nothing: no key on a card, no row, no money moved, no notice', function()
        local s, f = stack()
        s.storage.bumpStat('HITMAN01', 'completed', 0)
        local big = place(s, f, { reward = { baseline = { cash = 200000 } } })
        local small = place(s, f, { anonymous = true })
        local before = value(s)
        local bank = Env.players[1].PlayerData.money.bank
        Env.advance(2 * 3600)
        Env.clientEvents = {}
        for _ = 1, 3 do s.impBoard.tick() end
        for _, id in ipairs({ big.id, small.id }) do
            local card = boardCard(3, id)
            truthy(card, 'listed')
            eq(card.placerRecord, nil)
            eq(card.tierLocked, nil)
        end
        local mine = mineCard(1, big.id)
        eq(mine.decay, nil)
        eq(#s.storage.readRpRows('imp_heat'), 0)
        eq(#s.storage.readRpRows('imp_decay'), 0)
        eq(Env.players[1].PlayerData.money.bank, bank, 'nobody charged')
        eq(value(s), before)
        eq(noticesTo(1), 0, 'no notice to the placer')
        local reply = call('accept', 3, { id = big.id, penaltyAmount = 0 })
        truthy(reply and reply.ok, 'a level-1 hitman takes a big contract: ' .. tostring(reply and reply.err))
        eq(call('decayOff', 1, { id = small.id }).err, CH.ERR.FEATURE_OFF)
        eq(audits(s, 'imp_heat_added'), 0)
    end)
end)

--------------------------------------------------------------------------
-- The placer's record
--------------------------------------------------------------------------

describe('the placer\'s record on a board card', function()
    --- Vic's history: three named contracts (one completed, one cancelled,
    --- one live) and two anonymous ones (one completed), then a live named
    --- and a live anonymous one on the board.
    local function history()
        local s, f = stack()
        Env.addPlayer({ source = 4, citizenid = 'TARGET02', firstname = 'Ty', lastname = 'Two' })
        local done = place(s, f)
        truthy(s.contracts.accept(f.hitman, done.id, false))
        truthy(s.contracts.claimSlot(done.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        local gone = place(s, f)
        truthy(s.contracts.cancel(f.creator, gone.id))
        local anonDone = place(s, f, { anonymous = true })
        truthy(s.contracts.accept(f.hitman, anonDone.id, false))
        truthy(s.contracts.claimSlot(anonDone.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        local named = place(s, f)
        local anon = place(s, f, { anonymous = true })
        return s, f, named, anon
    end

    it('shows a named placer\'s named contracts, exact, never who they are', function()
        local s, _, named, anon = history()
        Config.Improvements.PlacerRecord.Enabled = true
        local card = boardCard(3, named.id)
        truthy(card.placerRecord, 'a record')
        eq(card.placerRecord.placed, 2, 'the completed and the cancelled one, not this one, not the anonymous')
        eq(card.placerRecord.paidOut, 1)
        eq(card.placerRecord.cancelled, 1)
        eq(card.placerRecord.days, 30)
        for k in pairs(card.placerRecord) do
            truthy(({ placed = true, paidOut = true, cancelled = true, days = true })[k], 'only counts: ' .. k)
        end
        eq(card.creatorName, nil, 'a stranger is still not told the name')
        eq(boardCard(3, anon.id).placerRecord, nil, 'nothing for an anonymous placer as shipped')
        -- Not to the placer, nor to the target.
        eq(mineCard(1, named.id).placerRecord, nil)
    end)

    it('shows an anonymous placer\'s anonymous contracts only, in bands, with ShowForAnonymous', function()
        local _, _, _, anon = history()
        Config.Improvements.PlacerRecord.Enabled = true
        Config.Improvements.PlacerRecord.ShowForAnonymous = true
        local record = boardCard(3, anon.id).placerRecord
        truthy(record and record.banded, 'banded')
        eq(record.placed, '1-4')
        eq(record.paidOut, '1-4')
        eq(record.cancelled, '0')
    end)

    it('never moves an anonymous band when another of their contracts ends', function()
        local s, f, named, anon = history()
        Config.Improvements.PlacerRecord.Enabled = true
        Config.Improvements.PlacerRecord.ShowForAnonymous = true
        local first = boardCard(3, anon.id).placerRecord
        -- Four more anonymous ones placed and cancelled would take the
        -- placed band to 5-9 if it were worked out again.
        for _ = 1, 4 do
            local more = place(s, f, { anonymous = true })
            truthy(s.contracts.cancel(f.creator, more.id))
        end
        truthy(s.contracts.cancel(f.creator, named.id), 'and the named one ends')
        local later = boardCard(3, anon.id).placerRecord
        eq(later.placed, first.placed, 'the band it was first drawn with')
        eq(later.cancelled, first.cancelled)
        -- A new anonymous contract placed now reads the new history.
        local newer = place(s, f, { anonymous = true })
        eq(boardCard(3, newer.id).placerRecord.placed, '5-9')
    end)

    it('is the same for every viewer, and current after every change, read from the kept board', function()
        local s, f, named = history()
        Config.Improvements.PlacerRecord.Enabled = true
        local a = boardCard(3, named.id).placerRecord
        local b = boardCard(4, named.id) and boardCard(4, named.id).placerRecord
        eq(a.placed, 2)
        if b then eq(b.placed, a.placed) end
        local more = place(s, f)
        truthy(s.contracts.cancel(f.creator, more.id))
        local after = boardCard(3, named.id).placerRecord
        eq(after.placed, 3, 'the change is seen at once')
        eq(after.cancelled, 2)
    end)

    -- Merge with round 3 (b037930): the prune no longer moves the board's
    -- generation, so the named record is kept on keptVersion, which the
    -- prune does move, and for a minute at most as the days roll on.
    it('is current at once when a contract it counts finishes', function()
        local s, f, named = history()
        Config.Improvements.PlacerRecord.Enabled = true
        local more = place(s, f)
        eq(boardCard(3, named.id).placerRecord.paidOut, 1, 'kept before')
        truthy(s.contracts.accept(f.hitman, more.id, false))
        truthy(s.contracts.claimSlot(more.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        local after = boardCard(3, named.id).placerRecord
        eq(after.placed, 3)
        eq(after.paidOut, 2, 'the completion is counted at once')
    end)

    it('is current at once when a contract it counts is pruned, with nothing else written', function()
        local s, _, named = history()
        Config.Improvements.PlacerRecord.Enabled = true
        Env.advance(2 * 86400)
        local before = boardCard(3, named.id).placerRecord
        eq(before.placed, 2, 'both finished ones counted and kept')
        local gen = s.projection.generation()
        local kept = s.projection.keptVersion()
        Config.Audit.ContractRetentionDays = 1
        s.storage.prune()
        eq(s.projection.generation(), gen, 'the prune leaves the board generation (round 3)')
        truthy(s.projection.keptVersion() ~= kept, 'and moves the kept version')
        eq(#s.storage.contractsBy('CREATOR1'), 2, 'the finished named and anonymous ones are gone')
        local after = boardCard(3, named.id).placerRecord
        eq(after.placed, 0, 'the pruned contracts are no longer counted')
        eq(after.paidOut, 0)
        eq(after.cancelled, 0)
    end)

    it('lets a counted contract age out of LookbackDays with nothing written', function()
        local _, _, named = history()
        Config.Improvements.PlacerRecord.Enabled = true
        Config.Improvements.PlacerRecord.LookbackDays = 1
        eq(boardCard(3, named.id).placerRecord.placed, 2, 'kept')
        Env.advance(2 * 86400)
        local card = boardCard(3, named.id)
        if card then eq(card.placerRecord.placed, 0, 'older than a day, not kept') end
    end)

    it('counts only the last LookbackDays', function()
        local _, _, named = history()
        Config.Improvements.PlacerRecord.Enabled = true
        Config.Improvements.PlacerRecord.LookbackDays = 1
        Env.advance(2 * 86400)
        local card = boardCard(3, named.id)
        if card then eq(card.placerRecord.placed, 0, 'older than a day') end
    end)
end)

--------------------------------------------------------------------------
-- Hitman heat
--------------------------------------------------------------------------

describe('hitman heat', function()
    local function scene()
        local s, f = stack({ targetJob = { name = 'police', type = 'leo', onduty = true } })
        Config.Improvements.HitmanHeat.Enabled = true
        Env.addPlayer({ source = 5, citizenid = 'OFFICER1', firstname = 'Otto', lastname = 'Beat',
            job = { name = 'police', type = 'leo', onduty = true } })
        s.impBoard.heat.random = function() return 1 end
        return s, f
    end

    it('gives heat for a whitelisted-job completion and an acceptance bulletin, never for a civilian', function()
        local s, f = scene()
        local c = place(s, f, { target = 'TARGET01' })
        truthy(call('accept', 3, { id = c.id, penaltyAmount = 0 }).ok)
        eq(s.impBoard.heat.of('HITMAN01'), Config.Improvements.HitmanHeat.AdvisoryHeat, 'the bulletin on accepting')
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        eq(s.impBoard.heat.of('HITMAN01'), 1 + 3, 'and the completion')
        -- A civilian target gives none.
        local s2, f2 = stack()
        Config.Improvements.HitmanHeat.Enabled = true
        local c2 = place(s2, f2)
        truthy(call('accept', 3, { id = c2.id, penaltyAmount = 0 }).ok)
        truthy(s2.contracts.claimSlot(c2.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        eq(s2.impBoard.heat.of('HITMAN01'), 0)
    end)

    it('gives heat for a witness report on their completion', function()
        local s, f = stack()
        Config.Improvements.HitmanHeat.Enabled = true
        Config.Roleplay.WitnessHeat.Enabled = true
        Config.Roleplay.WitnessHeat.AlwaysAlert = true
        Env.players[3]._coords = { x = 195.0, y = -934.0, z = 30.0 }
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        eq(s.impBoard.heat.of('HITMAN01'), Config.Improvements.HitmanHeat.WitnessHeat)
        Config.Roleplay.WitnessHeat.Enabled = false
        Config.Roleplay.WitnessHeat.AlwaysAlert = false
    end)

    it('cools after DecayHours, and survives a restart until then', function()
        local s = scene()
        s.impBoard.heat.add('HITMAN01', 4, 'test')
        Env.advance(3600)
        -- A restart: the module reads its rows back.
        s.impBoard.init({ storage = s.storage, identity = s.identity, notify = s.notify, audit = s.audit,
            escrow = s.escrow, contracts = s.contracts, amendments = s.amendments,
            projection = s.projection, progression = s.progression, rpConsequences = s.rpConsequences })
        eq(s.impBoard.heat.of('HITMAN01'), 4, 'kept')
        Env.advance(24 * 3600)
        eq(s.impBoard.heat.of('HITMAN01'), 0, 'cooled')
        s.impBoard.tick()
        eq(#s.storage.readRpRows('imp_heat'), 0, 'its row gone once cold')
    end)

    it('warns a known hitman\'s target with the paranoid alert, and says nothing of who', function()
        local s, f = stack()
        Config.Improvements.HitmanHeat.Enabled = true
        Config.Improvements.HitmanHeat.WarnTargetChancePercent = 100
        -- The warning is the paranoid alert, which needs its own switch (on
        -- as shipped); the one at placing goes first, and its cooldown runs.
        Config.Notifications.ParanoidAlert = true
        s.impBoard.heat.add('HITMAN01', 10, 'test')
        local c = place(s, f, { target = 'TARGET01' })
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        Env.runTimers()
        Env.advance(Config.Notifications.ParanoidCooldownMinutes * 60 + 1)
        Env.clientEvents = {}
        truthy(call('accept', 3, { id = c.id, penaltyAmount = 0 }).ok)
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        Env.runTimers()
        eq(noticesTo(2, 'Unsettling'), 1, 'the target felt eyes on them')
        eq(audits(s, 'imp_heat_warned'), 1)
        for _, event in ipairs(Env.clientEvents) do
            if event.target == 2 and Natives.isNotice(event) then
                local text = tostring((event.args[1] or {}).content or '')
                for _, needle in ipairs({ 'Rook', 'Ash', 'HITMAN01' }) do falsy(text:find(needle, 1, true)) end
            end
        end
    end)

    it('does not warn a target below the threshold, or with the chance at 0', function()
        local s, f = stack()
        Config.Improvements.HitmanHeat.Enabled = true
        Config.Improvements.HitmanHeat.WarnTargetChancePercent = 100
        Config.Notifications.ParanoidAlert = true
        s.impBoard.heat.add('HITMAN01', 4, 'test')
        local c = place(s, f, { target = 'TARGET01' })
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        Env.runTimers()
        Env.advance(Config.Notifications.ParanoidCooldownMinutes * 60 + 1)
        Env.clientEvents = {}
        truthy(call('accept', 3, { id = c.id, penaltyAmount = 0 }).ok)
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        Env.runTimers()
        eq(noticesTo(2, 'Unsettling'), 0)
    end)

    it('sends police a bulletin naming nobody while a known hitman works, at most every N minutes', function()
        local s, f = scene()
        Env.players[2].PlayerData.job = { name = 'unemployed', type = 'none' }
        local c = place(s, f, { target = 'TARGET01' })
        truthy(s.contracts.accept(f.hitman, c.id, true))
        s.impBoard.tick()
        eq(#heatBulletins(), 0, 'not known yet')
        s.impBoard.heat.add('HITMAN01', 5, 'test')
        Env.clientEvents = {}
        s.impBoard.tick()
        local sent = heatBulletins()
        eq(#sent, 1, 'one bulletin')
        eq(sent[1].coords, nil, 'no position')
        eq(noticesTo(5, 'Intelligence bulletin'), 1, 'the officer was told')
        eq(noticesTo(3, 'Intelligence bulletin'), 0, 'not the hitman')
        for _, needle in ipairs({ 'Rook', 'Ash', 'HITMAN01', 'Vic', 'Marlowe', 'CREATOR1', 'Dana', 'Reyes', c.id }) do
            falsy(tostring(sent[1].message):find(needle, 1, true), needle)
        end
        Env.advance(60)
        s.impBoard.tick()
        eq(#heatBulletins(), 1, 'not again inside the hour')
        Env.advance(3600)
        s.impBoard.tick()
        eq(#heatBulletins(), 2, 'again after it')
        Config.Improvements.HitmanHeat.BulletinEveryMinutes = 0
        Env.advance(7200)
        s.impBoard.tick()
        eq(#heatBulletins(), 2, '0 sends none')
    end)

    it('sends no bulletin while no known hitman holds a contract', function()
        local s = scene()
        s.impBoard.heat.add('HITMAN01', 50, 'test')
        s.impBoard.tick()
        eq(#heatBulletins(), 0)
    end)
end)

--------------------------------------------------------------------------
-- The tiered board
--------------------------------------------------------------------------

describe('the tiered board', function()
    local function scene()
        local s, f = stack()
        Config.Improvements.Tiers.Enabled = true
        local big = place(s, f, { reward = { baseline = { cash = 200000 } } })
        local mid = place(s, f, { reward = { baseline = { cash = 60000 } } })
        local small = place(s, f, { reward = { baseline = { cash = 10000 } } })
        return s, f, big, mid, small
    end

    it('locks the cards above the viewer\'s level, with the level needed', function()
        local _, _, big, mid, small = scene()
        local lock = boardCard(3, big.id).tierLocked
        truthy(lock, 'locked')
        eq(lock.tier, 'Elite')
        eq(lock.level, 4)
        eq(lock.yours, 1)
        eq(boardCard(3, mid.id).tierLocked.tier, 'Professional')
        eq(boardCard(3, small.id).tierLocked, nil, 'no tier, no lock')
    end)

    it('refuses Accept on a locked card before anything is taken', function()
        local s, _, big = scene()
        Config.Penalty.MinWindowMinutes = 0
        local before, cash = value(s), Env.players[3].PlayerData.money.cash
        local reply = call('accept', 3, { id = big.id, penaltyAmount = 0 })
        eq(reply.ok, false)
        eq(reply.err, CH.ERR.TIER_LOCKED)
        eq(reply.data.level, 4)
        eq(Env.players[3].PlayerData.money.cash, cash)
        eq(value(s), before)
        eq(s.storage.readHitman(big.id, 'HITMAN01'), nil, 'no row')
    end)

    it('opens as the hitman levels up', function()
        local s, _, big, mid = scene()
        s.storage.bumpStat('HITMAN01', 'completed', 5)
        eq(boardCard(3, mid.id).tierLocked, nil, 'level 2 takes Professional')
        eq(boardCard(3, big.id).tierLocked.yours, 2)
        truthy(call('accept', 3, { id = mid.id, penaltyAmount = 0 }).ok)
        s.storage.bumpStat('HITMAN01', 'completed', 15)
        eq(boardCard(3, big.id).tierLocked, nil, 'level 5 takes Elite')
    end)

    it('locks nothing with Criminal progression off', function()
        local _, _, big = scene()
        Config.Progression.Enabled = false
        eq(boardCard(3, big.id).tierLocked, nil)
        truthy(call('accept', 3, { id = big.id, penaltyAmount = 0 }).ok)
    end)
end)

--------------------------------------------------------------------------
-- Contract decay
--------------------------------------------------------------------------

describe('contract decay', function()
    local function scene(mode)
        local s, f = stack()
        Config.Improvements.ContractDecay.Enabled = true
        Config.Improvements.ContractDecay.Mode = mode or 'rise'
        local c = place(s, f)
        -- The tick sees it within its first minute.
        s.impBoard.tick()
        return s, f, c
    end

    it('raises an untaken reward from the placer\'s bank each step, conserving every dollar', function()
        local s, _, c = scene()
        local before, bank = value(s), Env.players[1].PlayerData.money.bank
        s.impBoard.tick()
        eq(Env.players[1].PlayerData.money.bank, bank, 'not before the first hour')
        Env.advance(3600)
        Env.clientEvents = {}
        s.impBoard.tick()
        eq(Env.players[1].PlayerData.money.bank, bank - 1000, '10% of 10000')
        eq(s.escrow.moneyValue(c.id), 11000)
        eq(value(s), before, 'conserved')
        eq(noticesTo(1, 'Contract reward'), 1, 'the placer is told')
        eq(audits(s, 'imp_decay_rose'), 1)
        local card = mineCard(1, c.id)
        eq(card.decay.added, 1000)
        eq(card.decay.mode, 'rise')
        s.impBoard.tick()
        eq(Env.players[1].PlayerData.money.bank, bank - 1000, 'once a step')
        eq(boardCard(3, c.id).reward.baseline, 11000, 'the board shows the new reward')
    end)

    it('stops at MaxIncreasePercent', function()
        local s, _, c = scene()
        Config.Improvements.ContractDecay.MaxIncreasePercent = 25
        for _ = 1, 5 do
            Env.advance(3600)
            s.impBoard.tick()
        end
        eq(s.escrow.moneyValue(c.id), 12500, '+10%, +10%, +5%, then no more')
        eq(mineCard(1, c.id).decay.stopped, true)
    end)

    it('stops for good when the placer cannot pay, charging nothing', function()
        local s, _, c = scene()
        Env.players[1].PlayerData.money.bank = 50
        local before = value(s)
        Env.advance(3600)
        Env.clientEvents = {}
        s.impBoard.tick()
        eq(Env.players[1].PlayerData.money.bank, 50)
        eq(s.escrow.moneyValue(c.id), 10000)
        eq(value(s), before)
        eq(noticesTo(1, 'Contract reward'), 1, 'told it stopped')
        Env.players[1].PlayerData.money.bank = 100000
        Env.advance(3600)
        s.impBoard.tick()
        eq(s.escrow.moneyValue(c.id), 10000, 'stopped for good')
    end)

    it('waits while the placer is away, and steps once they are back', function()
        local s, _, c = scene()
        local saved = Env.players[1]
        Env.removePlayer(1)
        Env.advance(3 * 3600)
        s.impBoard.tick()
        eq(s.escrow.moneyValue(c.id), 10000, 'nobody away is charged')
        Env.addPlayer({ source = 1, citizenid = 'CREATOR1', license = 'license:aaa',
            cash = saved.PlayerData.money.cash, bank = saved.PlayerData.money.bank,
            firstname = 'Vic', lastname = 'Marlowe' })
        s.impBoard.tick()
        s.impBoard.tick()
        eq(s.escrow.moneyValue(c.id), 11000, 'one step, not three at once')
    end)

    it('does nothing to a contract somebody took', function()
        local s, f, c = scene()
        truthy(s.contracts.accept(f.hitman, c.id, false))
        Env.advance(3600)
        s.impBoard.tick()
        eq(s.escrow.moneyValue(c.id), 10000)
    end)

    it('lets the placer turn it off for their contract, and nobody else', function()
        local s, _, c = scene()
        eq(call('decayOff', 3, { id = c.id }).err, CH.ERR.NOT_PARTICIPANT)
        eq(call('decayOff', 2, { id = c.id }).err, CH.ERR.NOT_PARTICIPANT)
        local reply = call('decayOff', 1, { id = c.id })
        truthy(reply.ok, 'turned off')
        eq(reply.data.off, true)
        truthy(call('decayOff', 1, { id = c.id }).ok, 'again is still off')
        Env.advance(3600)
        s.impBoard.tick()
        eq(s.escrow.moneyValue(c.id), 10000)
        -- After a restart too.
        s.impBoard.init({ storage = s.storage, identity = s.identity, notify = s.notify, audit = s.audit,
            escrow = s.escrow, contracts = s.contracts, amendments = s.amendments,
            projection = s.projection, progression = s.progression, rpConsequences = s.rpConsequences })
        Env.advance(3600)
        s.impBoard.tick()
        eq(s.escrow.moneyValue(c.id), 10000, 'the opt-out is kept')
        truthy(s.contracts.cancel(s.identity.resolve(1), c.id))
        eq(call('decayOff', 1, { id = c.id }).err, CH.ERR.ALREADY_SETTLED)
    end)

    it('hands every rise back with the rest when the contract is withdrawn', function()
        local s, _, c = scene()
        local before = value(s)
        local cash, bank = Env.players[1].PlayerData.money.cash, Env.players[1].PlayerData.money.bank
        Env.advance(3600)
        s.impBoard.tick()
        truthy(s.contracts.cancel(s.identity.resolve(1), c.id))
        eq(value(s), before)
        eq(Env.players[1].PlayerData.money.cash + Env.players[1].PlayerData.money.bank, cash + bank + 10000,
            'the reward and the rise back')
        s.impBoard.tick()
        eq(#s.storage.readRpRows('imp_decay'), 0, 'its row gone')
    end)

    it('brings the deadline in instead with Mode shorten, charging nothing', function()
        local s, _, c = scene('shorten')
        local was = s.storage.readContract(c.id).deadline_at
        local bank = Env.players[1].PlayerData.money.bank
        Env.advance(3600)
        s.impBoard.tick()
        local now = s.storage.readContract(c.id).deadline_at
        truthy(now < was, 'brought in')
        eq(Env.players[1].PlayerData.money.bank, bank)
        eq(s.escrow.moneyValue(c.id), 10000)
    end)

    it('does not step a contract older than a step when first seen, at once', function()
        local s, f = stack()
        local c = place(s, f)
        Env.advance(5 * 3600)
        Config.Improvements.ContractDecay.Enabled = true
        s.impBoard.tick()
        eq(s.escrow.moneyValue(c.id), 10000, 'its count starts now')
        Env.advance(3600)
        s.impBoard.tick()
        eq(s.escrow.moneyValue(c.id), 11000)
    end)

    it('offers the Place form its terms', function()
        local _, _, c = scene()
        local reply = call('list', 3, { page = 1 })
        eq(reply.data.settings.contractDecay.percent, 10)
        truthy(c)
    end)
end)

--------------------------------------------------------------------------
-- The admin panel
--------------------------------------------------------------------------

describe('the improvements in the admin panel', function()
    local KEYS = {
        'Improvements.PlacerRecord.Enabled', 'Improvements.PlacerRecord.LookbackDays',
        'Improvements.PlacerRecord.ShowForAnonymous', 'Improvements.HitmanHeat.Enabled',
        'Improvements.HitmanHeat.ProtectedCompletionHeat', 'Improvements.HitmanHeat.WitnessHeat',
        'Improvements.HitmanHeat.AdvisoryHeat', 'Improvements.HitmanHeat.DecayHours',
        'Improvements.HitmanHeat.Threshold', 'Improvements.HitmanHeat.WarnTargetChancePercent',
        'Improvements.HitmanHeat.BulletinEveryMinutes', 'Improvements.HitmanHeat.BulletinTitle',
        'Improvements.HitmanHeat.BulletinText', 'Improvements.Tiers.Enabled',
        'Improvements.Tiers.CompletionsPerLevel', 'Improvements.Tiers.Tiers',
        'Improvements.ContractDecay.Enabled', 'Improvements.ContractDecay.Mode',
        'Improvements.ContractDecay.Percent', 'Improvements.ContractDecay.Hours',
        'Improvements.ContractDecay.MaxIncreasePercent', 'Improvements.ContractDecay.Account',
    }

    it('lists every setting, each switch under Features in its Improvements group', function()
        local s = stack()
        for _, key in ipairs(KEYS) do
            local entry = s.settings.entry(key)
            truthy(entry, key)
            if entry.kind == 'switch' then eq(entry.category, 'features', key) end
            truthy(entry.group:find('^Improvements: '), key)
        end
    end)

    it('applies a change at once, and the feature follows it', function()
        local s, f = stack()
        truthy(s.settings.set('Improvements.Tiers.Enabled', true, 'ADMIN001', 'ADMIN001'))
        truthy(s.settings.set('Improvements.Tiers.Tiers', { 'Starter, 5000, 3' }, 'ADMIN001', 'ADMIN001'))
        local c = place(s, f)
        eq(boardCard(3, c.id).tierLocked.tier, 'Starter')
        truthy(s.settings.set('Improvements.PlacerRecord.Enabled', true, 'ADMIN001', 'ADMIN001'))
        truthy(boardCard(3, c.id).placerRecord)
        truthy(s.settings.set('Improvements.ContractDecay.Enabled', true, 'ADMIN001', 'ADMIN001'))
        truthy(s.settings.set('Improvements.ContractDecay.Percent', 20, 'ADMIN001', 'ADMIN001'))
        s.impBoard.tick()
        Env.advance(3600)
        s.impBoard.tick()
        eq(s.escrow.moneyValue(c.id), 12000)
    end)

    it('refuses a value out of its rule, and changes nothing', function()
        local s = stack()
        falsy(s.settings.set('Improvements.ContractDecay.Percent', 0, 'ADMIN001', 'ADMIN001'))
        falsy(s.settings.set('Improvements.ContractDecay.Mode', 'explode', 'ADMIN001', 'ADMIN001'))
        falsy(s.settings.set('Improvements.Tiers.Tiers', { 'Elite' }, 'ADMIN001', 'ADMIN001'))
        falsy(s.settings.set('Improvements.Tiers.Tiers', { 'Elite, 100, 0' }, 'ADMIN001', 'ADMIN001'))
        falsy(s.settings.set('Improvements.HitmanHeat.BulletinText', '<b>x</b>', 'ADMIN001', 'ADMIN001'))
        eq(Config.Improvements.ContractDecay.Percent, 10)
        eq(Config.Improvements.ContractDecay.Mode, 'rise')
        eq(#Config.Improvements.Tiers.Tiers, 2)
    end)

    it('puts a broken config.lua value back at the start, and fills a block it lacks', function()
        resetConfig()
        local main = require('crimson-hitman.server.main')
        Config.Improvements.ContractDecay.Hours = -4
        Config.Improvements.Tiers.Tiers = { 'nonsense' }
        Config.Improvements.HitmanHeat = nil
        local ok, fatal, warn = main.checkCandidate(Config)
        truthy(ok, table.concat(fatal or {}, '; '))
        local said, tiers = false, false
        for _, line in ipairs(warn) do
            if line:find('ContractDecay.Hours', 1, true) then said = true end
            if line:find('Tiers.Tiers', 1, true) then tiers = true end
        end
        truthy(said and tiers, 'the corrections are said')
        resetConfig()
    end)

    it('is refused to a player who is not staff, and changed by one who is', function()
        local s = stack()
        Config.Cooldowns.admin = { per = 10, burst = 500 }
        Config.Cooldowns.adminWrite = { per = 10, burst = 500 }
        Env.addPlayer({ source = 7, citizenid = 'PLAYER07' })
        Env.addPlayer({ source = 6, citizenid = 'ADMIN001' })
        Env.aces[6] = { ['crimson.admin'] = true }
        s.bridges.install(s)
        _G.source = 7
        Env.events['crimson-hitman:admin']({ op = 'setSetting', data = {
            key = 'Improvements.ContractDecay.Enabled', value = true }, __rid = 1 })
        _G.source = nil
        eq(Config.Improvements.ContractDecay.Enabled, false, 'unchanged')
        _G.source = 6
        Env.events['crimson-hitman:admin']({ op = 'setSetting', data = {
            key = 'Improvements.ContractDecay.Enabled', value = true }, __rid = 2 })
        _G.source = nil
        eq(Config.Improvements.ContractDecay.Enabled, true, 'changed by staff')
    end)
end)

--------------------------------------------------------------------------
-- The shared number reading (Util.num)
--------------------------------------------------------------------------

describe('the number reading heat and decay share', function()
    --- imp_decay.lua and imp_heat.lua each had this, word for word; both
    --- now read Util.num. Held to the old definition over every kind of
    --- value a setting can hold, so nothing either accepts has changed.
    local function old(value, fallback)
        local n = tonumber(value)
        if not n or n ~= n then return fallback or 0 end
        return n
    end
    local values = { 0, 1, -1, 2.5, 24, 1e308, math.huge, -math.huge, 0 / 0, '12', ' 7 ', '0x10',
        '1e2', 'abc', '', true, false, {}, function() end }
    it('answers exactly what the two copies answered, with and without a fallback', function()
        local Util = require('crimson-hitman.shared.util')
        for i = 1, #values + 1 do
            local v = values[i] -- the last is nil
            for _, fallback in ipairs({ false, 24, 5, -3 }) do
                local fb = fallback or nil
                local want, got = old(v, fb), Util.num(v, fb)
                eq(math.type(got), math.type(want), ('the kind of number for %s, %s'):format(tostring(v), tostring(fb)))
                eq(got, want, ('%s, %s'):format(tostring(v), tostring(fb)))
            end
        end
    end)
    it('is the one both modules read', function()
        for _, file in ipairs({ 'imp_decay', 'imp_heat' }) do
            local src = read_file('crimson-hitman/server/' .. file .. '.lua')
            truthy(src:find('local num = Util.num', 1, true), file .. ' reads Util.num')
            falsy(src:find('local function num', 1, true), file .. ' keeps no copy of its own')
        end
    end)
end)
