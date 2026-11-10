--- Target limits (server/targetlimits.lua and the admin panel's Target
--- limits section): how often one person may have a contract placed on
--- them.
---
--- What these hold the server to: with every default as shipped and nothing
--- set, placing behaves exactly as it did; a player's override beats their
--- job's, which beats the defaults, limit by limit; the day and week caps
--- count a rolling window; staff can reset a cooldown (keeping the same
--- placer's wait unless they reset all), extend one, reset the counts, set
--- a player's own limits or exempt them, and do the same for every player
--- of a job; every write needs its ACE and the lookup's own handle, is
--- audited, and is kept by all three stores across a restart; a stored row
--- that does not check out is not applied; and a player is told nothing
--- beyond the band wording they were told before.

local Exec = require('tests.harness.mysql_exec')

--- Staff: 6 crimson.admin, 7 an extra ACE (reads only), 8 crimson.admin
--- with crimson.identity, 9 crimson.moderator.
local function staff(s)
    Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
        firstname = 'Sam', lastname = 'Steward' })
    Env.addPlayer({ source = 7, citizenid = 'READER01', license = 'license:READER01',
        firstname = 'Rae', lastname = 'Dent' })
    Env.addPlayer({ source = 8, citizenid = 'UNMASK01', license = 'license:UNMASK01',
        firstname = 'Uma', lastname = 'Mask' })
    Env.addPlayer({ source = 9, citizenid = 'MODER001', license = 'license:MODER001',
        firstname = 'Mo', lastname = 'Derate' })
    Env.aces[6] = { ['crimson.admin'] = true }
    Env.aces[7] = { command = true }
    Env.aces[8] = { ['crimson.admin'] = true, ['crimson.identity'] = true }
    Env.aces[9] = { ['crimson.moderator'] = true }
    Config.Cooldowns.admin = { per = 10, burst = 1000 }
    Config.Cooldowns.adminWrite = { per = 10, burst = 1000 }
    if s.bridges and s.bridges.install then s.bridges.install(s) end
end

--- Two more placers, so a placer's own waits never stand in for the target's.
local function placers()
    Env.addPlayer({ source = 4, citizenid = 'PLACER04', license = 'license:p04', cash = 100000,
        bank = 100000, firstname = 'Pat', lastname = 'Four' })
    Env.addPlayer({ source = 5, citizenid = 'PLACER05', license = 'license:p05', cash = 100000,
        bank = 100000, firstname = 'Pia', lastname = 'Five' })
end

local function world(overrides)
    local s = newStack()
    local f = fixture(s, overrides)
    placers()
    staff(s)
    return s, f
end

local function ask(src, op, data)
    Env.clientEvents = {}
    _G.source = src
    local fired, err = pcall(Env.events['crimson-hitman:admin'], { op = op, data = data or {}, __rid = 7 })
    _G.source = nil
    truthy(fired, 'the net event must not raise: ' .. tostring(err))
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:adminResult' then return event.args[1] end
    end
    return nil
end

--- The handle a Target limits lookup gives.
local function lookedUp(src, subject)
    local reply = ask(src, 'targetStatus', { subject = subject })
    truthy(reply and reply.ok, 'looked up ' .. tostring(subject) .. ': ' .. tostring(reply and reply.message))
    return reply.data.player.ref, reply.data.status
end

local function place(s, src, target)
    return s.contracts.create(s.identity.resolve(src), { targetCid = target or 'TARGET01', reason = 'x',
        mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 1000 } } })
end

--- A contract on the target that a hitman took and that then ran out: it
--- starts the wait after a contract ends for everybody.
local function ended(s, f, src, state)
    local c = assert(place(s, src), 'placed')
    truthy(s.contracts.accept(f.hitman, c.id, false), 'taken')
    truthy(s.contracts.resolve(c.id, state or CH.STATE.EXPIRED, s.identity.resolve(src).cid, nil, 'expired'))
    return c
end

--- A player's adjustment row in force, or nil.
local function adjOf(s, cid) return s.targetLimits.effective(cid, nil).adj end

local function rows(s, action)
    s.audit.flush()
    return s.storage.auditByAction(action, 100) or {}
end

--------------------------------------------------------------------------
-- As shipped
--------------------------------------------------------------------------

describe('target limits as shipped', function()
    it('ships the day and week caps off, and every default as config.lua says', function()
        eq(Config.Limits.MaxContractsPerTargetPerDay, 0)
        eq(Config.Limits.MaxContractsPerTargetPerWeek, 0)
        local s = world()
        local eff = s.targetLimits.effective('TARGET01', 'unemployed')
        for _, entry in ipairs(s.targetLimits.KEYS) do
            eq(eff.values[entry.key], Config.Limits[entry.key], entry.key)
            eq(eff.source[entry.key], 'global', entry.key)
        end
        eq(#s.targetLimits.jobs(), 0, 'no job has its own')
    end)

    --- One script of placings, cancellings and waits, run once with the
    --- target limits wired and once without (the code before them): every
    --- answer the same.
    local function script(s, f)
        local out = {}
        local function try(src)
            local c, err = place(s, src)
            out[#out + 1] = c and 'ok' or tostring(err)
            return c
        end
        try(1); try(4); try(5)                       -- the cap of two live
        Env.advance(60)
        local live = s.storage.contractsNaming('TARGET01', true)
        for _, c in ipairs(live) do
            s.contracts.accept(f.hitman, c.id, false)
            s.contracts.resolve(c.id, CH.STATE.EXPIRED, c.creator_cid, nil, 'expired')
        end
        try(4)                                       -- the wait after one ends
        Env.advance(Config.Limits.TargetCooldownAfterResolveSeconds + 1)
        try(1)                                       -- the same placer's wait
        try(5)                                       -- free again
        Env.advance(Config.Limits.SameCreatorSameTargetCooldownSeconds + 1)
        try(1)
        return table.concat(out, ',')
    end

    it('reproduces the placing rules exactly with nothing set', function()
        local s1, f1 = world()
        local with = script(s1, f1)
        local s2, f2 = world()
        s2.contracts.targetLimitsFor = nil
        local without = script(s2, f2)
        eq(with, without, 'the same answers with and without target limits')
        eq(with, 'ok,ok,target_has_enough,target_recently_on,same_target_too_soon,ok,ok')
    end)
end)

--------------------------------------------------------------------------
-- Precedence and the windows
--------------------------------------------------------------------------

describe('target limits: player over job over global', function()
    it('takes each limit from the most specific place that sets it', function()
        local s = world({ targetJob = { name = 'mechanic', type = 'none' } })
        truthy(ask(6, 'targetJobSet', { job = 'mechanic', limits = {
            TargetCooldownAfterResolveSeconds = 7200, MaxActiveContractsPerTarget = 1 } }).ok)
        local eff = s.targetLimits.effective('TARGET01', 'mechanic')
        eq(eff.values.TargetCooldownAfterResolveSeconds, 7200)
        eq(eff.source.TargetCooldownAfterResolveSeconds, 'job')
        eq(eff.values.SameCreatorSameTargetCooldownSeconds, Config.Limits.SameCreatorSameTargetCooldownSeconds)
        eq(eff.source.SameCreatorSameTargetCooldownSeconds, 'global')
        local ref = lookedUp(9, 2)
        truthy(ask(9, 'targetOverride', { ref = ref, reason = 'event', hours = 0,
            limits = { MaxActiveContractsPerTarget = 3 } }).ok)
        eff = s.targetLimits.effective('TARGET01', 'mechanic')
        eq(eff.values.MaxActiveContractsPerTarget, 3)
        eq(eff.source.MaxActiveContractsPerTarget, 'player')
        eq(eff.source.TargetCooldownAfterResolveSeconds, 'job', 'the job still sets what the player does not')
        -- And the placing check follows: three live on them now.
        truthy(place(s, 1)); truthy(place(s, 4)); truthy(place(s, 5))
    end)

    it('a job override gives that job a longer wait, and nobody else', function()
        local s, f = world({ targetJob = { name = 'mechanic', type = 'none' } })
        truthy(ask(6, 'targetJobSet', { job = 'Mechanic', limits = { TargetCooldownAfterResolveSeconds = 7200 } }).ok,
            'job names are taken in lower case')
        ended(s, f, 1)
        Env.advance(Config.Limits.TargetCooldownAfterResolveSeconds + 5)
        local c, err, refusal = place(s, 4)
        eq(c, nil)
        eq(err, CH.ERR.TARGET_RECENTLY_ON)
        eq(refusal, nil, 'no time, no job, nothing beyond the wording')
        -- The same history on a target with another job: free.
        Env.players[2].PlayerData.job = { name = 'unemployed', type = 'none' }
        truthy(place(s, 4), 'the global wait is over for every other job')
    end)

    -- A contract cancelled after a hitman took it still counts. One withdrawn
    -- (or left to run out) before anybody took it does not: this used to
    -- assert that it did, which let two friends shield a target for a day
    -- with two $1 contracts withdrawn at once, free and refunded (review-mst
    -- F3; tests/review_mst_spec.lua). The wait after a resolution never
    -- counted those either.
    it('counts contracts placed on them in a rolling day and week', function()
        local s, f = world()
        truthy(ask(6, 'setSetting', { key = 'Limits.MaxContractsPerTargetPerDay', value = 2 }).ok)
        ended(s, f, 1, CH.STATE.CANCELLED)
        Env.advance(Config.Limits.TargetCooldownAfterResolveSeconds + 1)
        truthy(place(s, 4), 'the second today')
        local c, err = place(s, 5)
        eq(c, nil, 'a cancelled one a hitman took still counts')
        eq(err, CH.ERR.TARGET_HAS_ENOUGH)
        Env.advance(86400 - 10 - (Config.Limits.TargetCooldownAfterResolveSeconds + 1))
        eq(select(2, place(s, 5)), CH.ERR.TARGET_HAS_ENOUGH, 'still inside the 24 hours')
        Env.advance(20)
        -- The live one counts toward the cap of two live; one placed a day ago no longer counts.
        truthy(place(s, 5), 'the first left the 24 hours')
        -- The week.
        local w, wf = world()
        truthy(ask(6, 'setSetting', { key = 'Limits.MaxContractsPerTargetPerWeek', value = 1 }).ok)
        ended(w, wf, 1, CH.STATE.CANCELLED)
        Env.advance(6 * 86400)
        eq(select(2, place(w, 4)), CH.ERR.TARGET_HAS_ENOUGH, 'six days on')
        Env.advance(86400)
        truthy(place(w, 4), 'seven days on')
    end)

    it('does not count a contract staff voided', function()
        local s = world()
        truthy(ask(6, 'setSetting', { key = 'Limits.MaxContractsPerTargetPerDay', value = 1 }).ok)
        local c = assert(place(s, 1))
        truthy(s.contracts.resolve(c.id, CH.STATE.VOIDED, 'CREATOR1', nil, 'voided'))
        -- Past the ordinary wait a void starts, as any ending does.
        Env.advance(Config.Limits.TargetCooldownAfterResolveSeconds + 1)
        local again, err = place(s, 4)
        truthy(again, 'a voided contract is not one placed on them: ' .. tostring(err))
    end)
end)

--------------------------------------------------------------------------
-- Staff actions on one player
--------------------------------------------------------------------------

describe('target limits: staff actions on one player', function()
    it('shows their standing exactly, and which rule sets the cooldown', function()
        local s, f = world({ targetJob = { name = 'mechanic', type = 'none' } })
        truthy(ask(6, 'targetJobSet', { job = 'mechanic', limits = { TargetCooldownAfterResolveSeconds = 7200 } }).ok)
        ended(s, f, 1)
        Env.advance(600)
        local _, st = lookedUp(7, 2)
        eq(st.cooldownLeft, 6600)
        eq(st.cooldownRule, 'TargetCooldownAfterResolveSeconds')
        eq(st.cooldownFrom, 'job')
        eq(st.day, 1)
        eq(st.week, 1)
        eq(st.live, 0)
        eq(st.job, 'mechanic')
    end)

    it('Reset cooldown lets anybody name them now, but the same placer still waits; Reset all clears both', function()
        local s, f = world()
        ended(s, f, 1)
        local ref = lookedUp(9, 2)
        eq(select(2, place(s, 4)), CH.ERR.TARGET_RECENTLY_ON)
        local reply = ask(9, 'targetReset', { ref = ref, reason = 'ticket 12' })
        truthy(reply.ok, tostring(reply.message))
        eq(select(2, place(s, 1)), CH.ERR.SAME_TARGET_TOO_SOON, 'the same placer still waits')
        truthy(ask(9, 'targetReset', { ref = ref, reason = 'ticket 12', all = true }).ok)
        truthy(place(s, 1), 'Reset all clears the same placer\'s wait')
        local row = rows(s, 'staff_target_reset')
        eq(#row, 2)
        eq(row[1].detail.subject, 'TARGET01')
        eq(row[1].detail.reason, 'ticket 12')
    end)

    it('Extend holds them for the minutes given, from whichever is later, and says nothing more', function()
        local s = world()
        local ref = lookedUp(9, 2)
        truthy(ask(9, 'targetExtend', { ref = ref, reason = 'rp break', minutes = 30 }).ok)
        local c, err, refusal = place(s, 1)
        eq(c, nil)
        eq(err, CH.ERR.TARGET_RECENTLY_ON)
        eq(refusal, nil)
        truthy(ask(9, 'targetExtend', { ref = ref, reason = 'rp break', minutes = 30 }).ok, 'extended again')
        Env.advance(30 * 60 + 5)
        eq(select(2, place(s, 1)), CH.ERR.TARGET_RECENTLY_ON, 'the second extension added to the first')
        Env.advance(30 * 60)
        truthy(place(s, 1), 'over once it ends')
        eq(#rows(s, 'staff_target_extend'), 2)
        -- An until-time, and one in the past refused.
        local ref2 = lookedUp(9, 3)
        eq(ask(9, 'targetExtend', { ref = ref2, reason = 'x', untilAt = os.time() - 5 }).err, CH.ERR.INVALID_INPUT)
        truthy(ask(9, 'targetExtend', { ref = ref2, reason = 'x', untilAt = os.time() + 3600 }).ok)
        eq(adjOf(s, 'HITMAN01').until_at, os.time() + 3600)
    end)

    it('Reset counts starts the day and week counts from now', function()
        local s, f = world()
        truthy(ask(6, 'setSetting', { key = 'Limits.MaxContractsPerTargetPerDay', value = 1 }).ok)
        -- Taken, then cancelled: one withdrawn untaken is not counted (F3).
        ended(s, f, 1, CH.STATE.CANCELLED)
        Env.advance(Config.Limits.TargetCooldownAfterResolveSeconds + 1)
        eq(select(2, place(s, 4)), CH.ERR.TARGET_HAS_ENOUGH)
        local ref = lookedUp(9, 2)
        truthy(ask(9, 'targetCounts', { ref = ref, reason = 'mistake' }).ok)
        Env.advance(1)
        truthy(place(s, 4), 'counted from now')
        local _, st = lookedUp(9, 2)
        eq(st.day, 1)
        eq(st.dayAll, 2, 'the card says how many in all')
        eq(#rows(s, 'staff_target_counts'), 1)
    end)

    it('Exempt lifts every limit for a while, and lifting it puts them back', function()
        local s, f = world()
        ended(s, f, 1)
        local ref = lookedUp(9, 2)
        truthy(ask(9, 'targetOverride', { ref = ref, reason = 'event', exempt = true, hours = 1 }).ok)
        truthy(place(s, 4), 'no wait')
        truthy(place(s, 5), 'two live')
        Env.addPlayer({ source = 10, citizenid = 'PLACER10', license = 'license:p10', cash = 100000,
            bank = 100000, firstname = 'Ten', lastname = 'Placer' })
        truthy(place(s, 10), 'a third live: no cap')
        truthy(ask(9, 'targetOverrideClear', { ref = ref, reason = 'over' }).ok)
        eq(ask(9, 'targetOverrideClear', { ref = ref, reason = 'over' }).err, 'not_active')
        Env.advance(Config.Limits.TargetCooldownAfterResolveSeconds + 1)
        Env.addPlayer({ source = 11, citizenid = 'PLACER11', license = 'license:p11', cash = 100000,
            bank = 100000, firstname = 'Eleven', lastname = 'Placer' })
        eq(select(2, place(s, 11)), CH.ERR.TARGET_HAS_ENOUGH)
        eq(#rows(s, 'staff_target_override'), 1)
        eq(rows(s, 'staff_target_override')[1].detail.exempt, true)
        eq(#rows(s, 'staff_target_clear'), 1)
    end)

    it('an override runs out by itself', function()
        local s = world()
        local ref = lookedUp(9, 2)
        truthy(ask(9, 'targetOverride', { ref = ref, reason = 'x', hours = 1,
            limits = { MaxActiveContractsPerTarget = 1 } }).ok)
        truthy(place(s, 1))
        eq(select(2, place(s, 4)), CH.ERR.TARGET_HAS_ENOUGH)
        Env.advance(3601)
        truthy(place(s, 4), 'back to the cap of two')
    end)

    it('refuses a bad limit, a missing reason, and limits out of range', function()
        world()
        local ref = lookedUp(9, 2)
        eq(ask(9, 'targetReset', { ref = ref }).err, CH.ERR.INVALID_INPUT, 'no reason')
        eq(ask(9, 'targetOverride', { ref = ref, reason = 'x', hours = 0,
            limits = { MaxActiveContractsPerTarget = 0 } }).err, CH.ERR.INVALID_INPUT)
        eq(ask(9, 'targetOverride', { ref = ref, reason = 'x', hours = 0,
            limits = { Nonsense = 1 } }).err, CH.ERR.INVALID_INPUT)
        eq(ask(9, 'targetExtend', { ref = ref, reason = 'x', minutes = 0 }).err, CH.ERR.INVALID_INPUT)
        eq(ask(6, 'targetJobSet', { job = 'po lice', limits = { MaxActiveContractsPerTarget = 1 } }).err,
            CH.ERR.INVALID_INPUT)
        eq(ask(6, 'targetJobSet', { job = string.rep('a', 33), limits = { MaxActiveContractsPerTarget = 1 } }).err,
            CH.ERR.INVALID_INPUT)
        eq(ask(6, 'targetJobSet', { job = 'police', limits = {} }).err, CH.ERR.INVALID_INPUT)
    end)
end)

--------------------------------------------------------------------------
-- Who may, and by which handle
--------------------------------------------------------------------------

describe('target limits: ACEs and lookup handles', function()
    it('needs the moderator or the staff ACE for a player\'s, the staff ACE for a job\'s', function()
        local s = world()
        local mine = lookedUp(7, 2)
        for _, op in ipairs({ 'targetReset', 'targetExtend', 'targetCounts', 'targetOverride',
            'targetOverrideClear' }) do
            eq(ask(7, op, { ref = mine, reason = 'x', minutes = 5, exempt = true, hours = 0 }).err,
                'not_allowed', 'a reader: ' .. op)
        end
        eq(ask(7, 'targetJobAction', { job = 'unemployed', action = 'reset', reason = 'x' }).err, 'not_allowed')
        eq(ask(9, 'targetJobSet', { job = 'police', limits = { MaxActiveContractsPerTarget = 1 } }).err,
            'not_allowed', 'a moderator may not set a job\'s limits')
        eq(ask(9, 'targetJobRemove', { job = 'police' }).err, 'not_allowed')
        truthy(ask(7, 'targetLimits', {}).ok, 'a reader reads')
        truthy(ask(7, 'targetContracts', {}).ok, 'a reader reads the list')
        eq(adjOf(s, 'TARGET01'), nil, 'nothing was written')
    end)

    it('refuses a handle that is not this staff member\'s, has run out, or is missing', function()
        local s = world()
        local theirs = lookedUp(6, 2)
        eq(ask(9, 'targetReset', { ref = theirs, reason = 'x' }).err, 'stale_lookup', 'another\'s handle')
        eq(ask(9, 'targetReset', { reason = 'x', subject = 'TARGET01' }).err, 'stale_lookup', 'no handle')
        local mine = lookedUp(9, 2)
        -- The handles last ten minutes of the server's own clock.
        local util = require('crimson-hitman.shared.util')
        local was = util.monotonicMs
        util.monotonicMs = function() return was() + 600001 end
        local reply = ask(9, 'targetReset', { ref = mine, reason = 'x' })
        util.monotonicMs = was
        eq(reply.err, 'stale_lookup', 'a handle run out')
        eq(adjOf(s, 'TARGET01'), nil, 'nothing was written')
    end)
end)

--------------------------------------------------------------------------
-- Every player of a job
--------------------------------------------------------------------------

describe('target limits: one action for every player of a job', function()
    local function jobs(s)
        Env.players[2].PlayerData.job = { name = 'mechanic', type = 'none' }
        Env.players[3].PlayerData.job = { name = 'mechanic', type = 'none' }
        Env.players[4].PlayerData.job = { name = 'taxi', type = 'none' }
        return s
    end

    it('counts the job\'s players, online now and the ones a recent contract recorded', function()
        local s, f = world()
        jobs(s)
        -- PLACER05 named on a contract while a mechanic, then gone.
        Env.players[5].PlayerData.job = { name = 'mechanic', type = 'none' }
        local c = assert(s.contracts.create(f.creator, { targetCid = 'PLACER05', reason = 'x',
            reward = { baseline = { cash = 1000 } } }))
        eq(s.storage.readContract(c.id).target_job, 'mechanic')
        Env.removePlayer(5)
        local reply = ask(9, 'targetJobCount', { job = 'mechanic' })
        truthy(reply.ok)
        eq(reply.data.count, 3, 'two in the city and one offline')
        eq(ask(9, 'targetJobCount', { job = 'taxi' }).data.count, 1)
        eq(ask(9, 'targetJobCount', { job = 'nobody' }).data.count, 0)
    end)

    it('resets, extends and resets counts for only that job\'s players, with one audit row and the count', function()
        local s, f = world()
        jobs(s)
        ended(s, f, 1)
        local reply = ask(9, 'targetJobAction', { job = 'mechanic', action = 'extend', minutes = 60, reason = 'war' })
        truthy(reply.ok, tostring(reply.message))
        eq(reply.data.done, 2)
        truthy(adjOf(s, 'TARGET01').until_at, 'the mechanic target held')
        truthy(adjOf(s, 'HITMAN01').until_at, 'the mechanic hitman held')
        eq(adjOf(s, 'PLACER04'), nil, 'the taxi driver untouched')
        local row = rows(s, 'staff_target_job_extend')
        eq(#row, 1)
        eq(row[1].detail.job, 'mechanic')
        eq(row[1].detail.players, 2)
        eq(#rows(s, 'staff_target_extend'), 0, 'one row for the job, not one a player')
        truthy(ask(9, 'targetJobAction', { job = 'mechanic', action = 'reset', all = true, reason = 'over' }).ok)
        truthy(place(s, 4), 'the reset all cleared the extension and the wait')
        truthy(ask(9, 'targetJobAction', { job = 'mechanic', action = 'counts', reason = 'x' }).ok)
        eq(#rows(s, 'staff_target_job_counts'), 1)
        eq(ask(9, 'targetJobAction', { job = 'nobody', action = 'reset', reason = 'x' }).err, 'nobody')
        eq(ask(9, 'targetJobAction', { job = 'mechanic', action = 'reset' }).err, CH.ERR.INVALID_INPUT, 'a reason')
    end)
end)

--------------------------------------------------------------------------
-- Current contracts
--------------------------------------------------------------------------

describe('target limits: every live contract, by target', function()
    it('lists every live contract grouped by target, scrubbed without the identity ACE', function()
        local s, f = world()
        ended(s, f, 5)
        Env.advance(Config.Limits.TargetCooldownAfterResolveSeconds + 1)
        truthy(place(s, 1))
        assert(s.contracts.create(s.identity.resolve(4), { targetCid = 'TARGET01', reason = 'x', anonymous = true,
            reward = { baseline = { cash = 1000 } } }))
        assert(s.contracts.create(s.identity.resolve(5), { targetCid = 'HITMAN01', reason = 'x',
            reward = { baseline = { cash = 1000 } } }))
        local reply = ask(6, 'targetContracts', {})
        truthy(reply.ok)
        eq(reply.data.total, 3, 'live ones only')
        eq(reply.data.targets, 2)
        local groups = {}
        for _, row in ipairs(reply.data.rows) do
            groups[#groups + 1] = row.group
            if row.anonymous then eq(row.client, 'Anonymous', 'no name without the identity ACE') end
            falsy(tostring(row.group):match('TARGET01'), 'no citizen id without the identity ACE')
        end
        eq(groups[1], groups[2], 'the two on one target together')
        local seen = ask(8, 'targetContracts', {}).data.rows
        local named = false
        for _, row in ipairs(seen) do if row.anonymous and row.client == 'Pat Four' then named = true end end
        truthy(named, 'with the identity ACE the placer is named')
        eq(ask(6, 'targetContracts', { query = 'Rook' }).data.total, 1, 'searched by the target\'s name')
    end)
end)

--------------------------------------------------------------------------
-- Across a restart, in every store
--------------------------------------------------------------------------

local function forgetServerModules()
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
            package.loaded[name] = nil
        end
    end
end

local function boot(mode)
    forgetServerModules()
    Env.reset()
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Natives.resetResourceStates()
    resetConfig()
    Config.Database.Mode = mode
    if mode == 'mysql' then Exec.install(Natives) end
    if mode == 'json' then Natives.files = {} end
    local main = require('server.main')
    return main, main.start()
end

local function restart(mode, old)
    if old and old.storage then rawset(old.storage, '__rawFixture', true) end
    forgetServerModules()
    Env.events, Env.clientEvents, Env.notifications = {}, {}, {}
    Env.handlers, Env.threads, Env.timers, Env.commands = {}, {}, {}, {}
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Config.Database.Mode = mode
    local main = require('server.main')
    return main, main.start()
end

describe('target limits across a restart', function()
    for _, mode in ipairs({ 'memory', 'json', 'mysql' }) do
        it(mode .. ': a job\'s limits and a player\'s adjustments are kept and applied again', function()
            local _, s = boot(mode)
            fixture(s)
            staff(s)
            truthy(ask(6, 'targetJobSet', { job = 'mechanic', limits = { TargetCooldownAfterResolveSeconds = 7200 } }).ok,
                mode)
            truthy(ask(9, 'targetExtend', { ref = lookedUp(9, 2), reason = 'held', minutes = 90 }).ok, mode)
            truthy(ask(9, 'targetOverride', { ref = lookedUp(9, 3), reason = 'kept', exempt = true, hours = 0 }).ok,
                mode)
            local after
            if mode == 'memory' then
                -- Nothing outlives the process in memory mode: read back
                -- from the store as a start would.
                s.targetLimits.reload()
                after = s
            else
                after = select(2, restart(mode, s))
            end
            local job = after.targetLimits.jobs()[1]
            truthy(job, mode .. ': the job\'s limits were lost')
            eq(job.job, 'mechanic')
            eq(job.limits.TargetCooldownAfterResolveSeconds, 7200, mode)
            local row = adjOf(after, 'TARGET01')
            truthy(row, mode .. ': the extension was lost')
            truthy(math.abs(row.until_at - (os.time() + 5400)) <= 2, mode .. ': its end kept')
            eq(row.reason, 'held', mode)
            local eff = after.targetLimits.effective('HITMAN01', nil)
            eq(eff.exempt, true, mode .. ': the exemption was lost')
            eq(after.targetLimits.effective('X', 'mechanic').values.TargetCooldownAfterResolveSeconds, 7200, mode)
        end)
    end

    it('does not apply a stored row that does not check out, and applies the rest', function()
        local s = world()
        s.storage.writeRpRow({ id = 'tl_job:bad job', kind = 'tl_job', job = 'bad job',
            limits = { MaxActiveContractsPerTarget = 2 } })
        s.storage.writeRpRow({ id = 'tl_job:huge', kind = 'tl_job', job = 'huge',
            limits = { MaxActiveContractsPerTarget = 999 } })
        s.storage.writeRpRow({ id = 'tl_job:unknown', kind = 'tl_job', job = 'unknown', limits = { Nope = 1 } })
        s.storage.writeRpRow({ id = 'tl_job:fine', kind = 'tl_job', job = 'fine',
            limits = { MaxActiveContractsPerTarget = 4 } })
        s.storage.writeRpRow({ id = 'tl_player:X', kind = 'tl_player', cid = 'X', until_at = 'soon' })
        s.storage.writeRpRow({ id = 'tl_player:Y', kind = 'tl_player', cid = 'Y',
            override = { exempt = false, limits = { MaxContractsPerTargetPerDay = -3 } } })
        s.storage.writeRpRow({ id = 'tl_player:Z', kind = 'tl_player', cid = 'Z', until_at = os.time() + 600 })
        s.targetLimits.reload()
        local jobs = s.targetLimits.jobs()
        eq(#jobs, 1, 'only the good job')
        eq(jobs[1].job, 'fine')
        eq(#s.targetLimits.ignored(), 5)
        eq(adjOf(s, 'X'), nil)
        eq(adjOf(s, 'Y'), nil)
        truthy(adjOf(s, 'Z'), 'the good player row')
        eq(s.targetLimits.effective('Y', nil).values.MaxContractsPerTargetPerDay, 0, 'the default applies')
        eq(ask(6, 'targetLimits', {}).data.ignored, 5, 'the panel says how many')
    end)

    it('prunes a player row once every fact in it has run out', function()
        local s = world()
        truthy(ask(9, 'targetExtend', { ref = lookedUp(9, 2), reason = 'x', minutes = 10 }).ok)
        eq(s.targetLimits.prune(), 0, 'not yet')
        Env.advance(11 * 60)
        eq(s.targetLimits.prune(), 1)
        eq(#s.storage.readRpRows('tl_player'), 0, 'out of the store')
        -- A reset is kept as long as the longest wait it can matter for.
        truthy(ask(9, 'targetReset', { ref = lookedUp(9, 2), reason = 'x' }).ok)
        Env.advance(29 * 86400)
        eq(s.targetLimits.prune(), 0)
        Env.advance(2 * 86400)
        eq(s.targetLimits.prune(), 1)
    end)
end)
