--- Staff moving a live contract's deadline (Admin.adjustDeadline, the admin
--- panel's adjustDeadline op: Extend and Shorten on the contract's view).
---
--- Booted through main.lua, so the expiry pass, the presence pause and the
--- staff freeze are the real ones. What these hold it to: the run time left
--- moves by exactly the adjustment whether the clock is running, stopped by
--- somebody's absence, or on hold by a freeze, so the band players see moves
--- by that and nothing else; a shortening never leaves less than
--- Config.Limits.StaffDeadlineMinLeftSeconds, and says how far it could go;
--- no adjustment is more than Config.Limits.StaffDeadlineMaxAdjustSeconds;
--- extending past the lifetime extends the lifetime, capped at
--- Config.Limits.ContractLifetimeSeconds from now, and says which; only staff
--- with the write ACE may; each is on the record (staff_deadline_adjust),
--- scrubbed for staff without the identity ACE; every party is told in words
--- with no figure and no name; and no money moves.

local Util = require('crimson-hitman.shared.util')

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
    local main = require('server.main')
    return main, main.start()
end

--- The usual three, and three staff: crimson.admin, a read-only extra ACE,
--- and crimson.admin with crimson.identity.
local function people(s)
    local f = fixture(s)
    Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
        firstname = 'Sam', lastname = 'Steward' })
    Env.addPlayer({ source = 7, citizenid = 'READER01', license = 'license:READER01',
        firstname = 'Rae', lastname = 'Dent' })
    Env.addPlayer({ source = 8, citizenid = 'UNMASK01', license = 'license:UNMASK01',
        firstname = 'Uma', lastname = 'Mask' })
    Env.aces[6] = { ['crimson.admin'] = true }
    Env.aces[7] = { command = true }
    Env.aces[8] = { ['crimson.admin'] = true, ['crimson.identity'] = true }
    return f
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

local function place(s, actor, extra)
    local req = { targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                  reward = { baseline = { cash = 5000 } } }
    for k, v in pairs(extra or {}) do req[k] = v end
    local c, err = s.contracts.create(actor, req)
    truthy(c, 'placed: ' .. tostring(err))
    return c
end

local function pass(main)
    main.markPresenceChanged()
    main.expire()
end

local function row(s, c) return s.storage.readContract(c.id) end
local function left(s, c) return Util.runLeft(row(s, c)) end

--- A contract taken, its clock running, and its target shown it.
local function running(main, s, f, extra)
    local c = place(s, f.creator, extra)
    truthy(s.contracts.accept(f.hitman, c.id), 'taken')
    Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
    pass(main)
    eq(row(s, c).paused_since, nil, 'the clock runs')
    return c
end

local function adjust(src, c, seconds, reason)
    return ask(src, 'adjustDeadline', { id = c.id, seconds = seconds, reason = reason or 'a ticket' })
end

local function notices(src)
    local out = {}
    for _, event in ipairs(Env.clientEvents) do
        if Natives.isNotice(event) and event.target == src then
            out[#out + 1] = tostring(event.args[1].title) .. ' | ' .. tostring(event.args[1].content)
        end
    end
    return out
end

local function pushes(src)
    Env.runTimers()   -- a push goes at the end of its tick (Notify)
    local n = 0
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:push' and event.target == src then n = n + 1 end
    end
    return n
end

local function stored(s, action)
    s.audit.flush()
    return s.storage.auditByAction(action, 100) or {}
end

--- Every player's cash and bank, and every escrow line's state and amount.
local function snapshot(s, ids)
    local out = {}
    for src = 1, 3 do
        local m = Env.players[src].PlayerData.money
        out[#out + 1] = ('%d:%d/%d'):format(src, m.cash, m.bank)
    end
    for _, id in ipairs(ids) do
        local lines = s.storage.readEscrow(id) or {}
        table.sort(lines, function(a, b) return tostring(a.id) < tostring(b.id) end)
        for _, line in ipairs(lines) do
            out[#out + 1] = ('%s:%s:%s:%s'):format(tostring(line.id), tostring(line.state),
                tostring(line.amount), tostring(line.owed_to))
        end
    end
    return table.concat(out, ' ')
end

--------------------------------------------------------------------------

describe('the run time left moves by exactly the adjustment', function()
    it('with the clock running: extend, then shorten, and every band follows', function()
        local main, s = boot()
        local f = people(s)
        local c = running(main, s, f)
        local before, deadline = left(s, c), row(s, c).deadline_at

        local reply = adjust(6, c, 3600, 'Crash cost them an hour')
        truthy(reply and reply.ok, 'extended: ' .. tostring(reply and reply.message))
        eq(left(s, c), before + 3600, 'the run time left did not move by the hour')
        eq(row(s, c).deadline_at, deadline + 3600)
        eq(row(s, c).paused_since, nil, 'the clock was stopped by an extension')
        local band = Util.timeBand(before + 3600)
        for _, cid in ipairs({ 'CREATOR1', 'HITMAN01', 'TARGET01' }) do
            eq(s.projection.contract(row(s, c), cid).timeLeft, band, cid .. '\'s band')
        end
        eq(reply.data.leftBefore, before)
        eq(reply.data.leftAfter, before + 3600)
        truthy(reply.message:find('Extended by 1 h', 1, true), reply.message)

        reply = adjust(6, c, -9000, 'Agreed in the ticket')
        truthy(reply and reply.ok, 'shortened: ' .. tostring(reply and reply.message))
        eq(left(s, c), before + 3600 - 9000)
        for _, cid in ipairs({ 'CREATOR1', 'HITMAN01', 'TARGET01' }) do
            eq(s.projection.contract(row(s, c), cid).timeLeft, Util.timeBand(before - 5400), cid .. '\'s band')
        end
        truthy(reply.message:find('Shortened by 2 h 30 min', 1, true), reply.message)

        -- And it runs down from there, and expires at the new deadline.
        Env.advance(left(s, c) + 1)
        pass(main)
        eq(row(s, c).state, CH.STATE.EXPIRED, 'it did not expire at the deadline it was moved to')
    end)

    it('with the clock stopped by somebody away: moved now, banked as every pause is', function()
        local main, s = boot()
        local f = people(s)
        local c = running(main, s, f)
        Env.removePlayer(3)
        pass(main)
        local since = row(s, c).paused_since
        truthy(since, 'the operative away stopped it')
        local atPause = left(s, c)
        Env.advance(600)
        eq(left(s, c), atPause, 'a stopped clock ran')

        local reply = adjust(6, c, 1800)
        truthy(reply and reply.ok, tostring(reply and reply.message))
        eq(left(s, c), atPause + 1800, 'stopped: the run time left did not move by the change')
        eq(row(s, c).paused_since, since, 'the pause was ended or restarted')
        eq(s.projection.contract(row(s, c), 'CREATOR1').timeLeft, Util.timeBand(atPause + 1800))
        truthy(reply.message:find('clock is stopped', 1, true), reply.message)

        reply = adjust(6, c, -900)
        truthy(reply and reply.ok, tostring(reply and reply.message))
        eq(left(s, c), atPause + 900)

        Env.advance(300)
        Env.addPlayer({ source = 3, citizenid = 'HITMAN01', license = 'license:ccc', cash = 5000,
            bank = 5000, firstname = 'Rook', lastname = 'Ash' })
        pass(main)
        eq(row(s, c).paused_since, nil, 'running again')
        eq(left(s, c), atPause + 900, 'the pause banked over the change, or the change was lost')
    end)

    it('on a frozen contract: moved while on hold, and the freeze gives back only its own time', function()
        local main, s = boot()
        local f = people(s)
        local c = running(main, s, f)
        local before = left(s, c)
        truthy(ask(6, 'freeze', { subject = 2, reason = 'dispute' }).ok, 'the target frozen')
        Env.advance(900)
        eq(left(s, c), before, 'on hold and it ran')

        local reply = adjust(6, c, -1800)
        truthy(reply and reply.ok, 'shortened on hold: ' .. tostring(reply and reply.message))
        eq(left(s, c), before - 1800)
        reply = adjust(6, c, 7200)
        truthy(reply and reply.ok, 'extended on hold: ' .. tostring(reply and reply.message))
        eq(left(s, c), before + 5400)
        eq(s.projection.contract(row(s, c), 'HITMAN01').timeLeft, Util.timeBand(before + 5400))

        Env.advance(300)
        truthy(ask(6, 'unfreeze', { subject = 2 }).ok, 'released')
        pass(main)
        eq(row(s, c).paused_since, nil, 'running again')
        eq(left(s, c), before + 5400, 'the release undid the change, or banked the hold twice')
    end)
end)

describe('what a shortening may leave, and how far either way', function()
    it('refuses to leave less than StaffDeadlineMinLeftSeconds, saying the most it can be', function()
        local main, s = boot()
        local f = people(s)
        local c = running(main, s, f)
        local before, deadline = left(s, c), row(s, c).deadline_at
        local most = before - Config.Limits.StaffDeadlineMinLeftSeconds

        local reply = adjust(6, c, -(most + 60))
        falsy(reply.ok, 'shortened below the least left')
        eq(reply.err, 'min_left')
        local h, m = most // 3600, (most % 3600) // 60
        local said = ('The most you can shorten it by is %d h %02d min'):format(h, m)
        truthy(reply.message:find(said, 1, true), reply.message)
        eq(row(s, c).deadline_at, deadline, 'a refused shortening moved the deadline')

        reply = adjust(6, c, -most)
        truthy(reply.ok, 'shortened to the least left: ' .. tostring(reply.message))
        eq(left(s, c), Config.Limits.StaffDeadlineMinLeftSeconds)

        reply = adjust(6, c, -60)
        eq(reply.err, 'min_left', 'shortened past the least left')
        truthy(reply.message:find('It cannot be shortened now.', 1, true), reply.message)
        eq(#stored(s, 'staff_deadline_adjust'), 1, 'a refusal was recorded as a change')
        pass(main)
        eq(row(s, c).state, CH.STATE.ACCEPTED, 'expired at once')
    end)

    it('refuses anything past StaffDeadlineMaxAdjustSeconds either way, zero, or not whole', function()
        local main, s = boot()
        local f = people(s)
        local c = running(main, s, f)
        local deadline = row(s, c).deadline_at
        eq(Config.Limits.StaffDeadlineMaxAdjustSeconds, 86400, 'ships as a day')
        for _, seconds in ipairs({ 86401, -86401, 0, 1.5, 'abc', 1e12 }) do
            local reply = adjust(6, c, seconds)
            falsy(reply.ok, tostring(seconds) .. ' went through')
            eq(reply.err, CH.ERR.INVALID_INPUT, tostring(seconds))
            truthy(reply.message:find('StaffDeadlineMaxAdjustSeconds', 1, true), reply.message)
        end
        Config.Limits.StaffDeadlineMaxAdjustSeconds = 600
        local reply = adjust(6, c, 601)
        eq(reply.err, CH.ERR.INVALID_INPUT, 'the setting is read on every use')
        truthy(reply.message:find('10 min', 1, true), reply.message)
        truthy(adjust(6, c, 600).ok, 'at the limit')
        eq(row(s, c).deadline_at, deadline + 600)
        local noReason = ask(6, 'adjustDeadline', { id = c.id, seconds = 60 })
        eq(noReason.err, CH.ERR.INVALID_INPUT, 'moved without a reason')
        eq(row(s, c).deadline_at, deadline + 600)
    end)

    it('only a live contract: closed or unknown ones are refused', function()
        local main, s = boot()
        local f = people(s)
        local c = running(main, s, f)
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION, {}), 'paid out')
        eq(row(s, c).state, CH.STATE.COMPLETED)
        local reply = adjust(6, c, 600)
        eq(reply.err, CH.ERR.BAD_STATE)
        truthy(reply.message:find('active or accepted', 1, true), reply.message)
        eq(ask(6, 'adjustDeadline', { id = 'ct99999999', seconds = 60, reason = 'x' }).err, CH.ERR.NOT_FOUND)
        eq(ask(6, 'contract', { id = c.id }).data.deadline.adjustable, false, 'the view offers it')
        local open = place(s, f.creator, { targetCid = 'HITMAN01' })
        local view = ask(6, 'contract', { id = open.id }).data.deadline
        eq(view.adjustable, true, 'an active contract')
        eq(view.left, left(s, open), 'the exact run time left')
        eq(view.maxAdjust, 86400)
        eq(view.minLeft, 300)
    end)
end)

describe('the lifetime', function()
    it('extended by the same amount where the deadline passes it, or to its cap, saying which', function()
        local main, s = boot()
        local f = people(s)
        local c = running(main, s, f)
        local expires = row(s, c).expires_at

        -- Inside the lifetime: it stands.
        local reply = adjust(6, c, 86400)
        truthy(reply.ok, tostring(reply.message))
        eq(row(s, c).expires_at, expires, 'the lifetime moved for a deadline inside it')
        eq(reply.data.lifetime, 'unchanged')
        falsy(reply.message:find('lifetime', 1, true), reply.message)

        -- Past it, with room under the cap: the lifetime moves by the same.
        Config.Limits.ContractLifetimeSeconds = 400000
        local deadline = row(s, c).deadline_at
        reply = adjust(6, c, 86400)
        truthy(reply.ok, tostring(reply.message))
        eq(row(s, c).deadline_at, deadline + 86400, 'the deadline was held back')
        eq(row(s, c).expires_at, expires + 86400, 'the lifetime was not extended by the same')
        eq(reply.data.lifetime, 'extended')
        truthy(reply.message:find('the lifetime was extended by 24 h too', 1, true), reply.message)

        -- Past it, against the cap: the lifetime to the cap, the deadline to it.
        Config.Limits.ContractLifetimeSeconds = 172800
        local cap = os.time() + 172800
        deadline = row(s, c).deadline_at
        reply = adjust(6, c, 86400)
        truthy(reply.ok, tostring(reply.message))
        eq(row(s, c).expires_at, math.max(expires + 86400, cap), 'not held to the cap')
        eq(reply.data.lifetime, 'capped')
        eq(row(s, c).deadline_at, row(s, c).expires_at, 'the deadline past the lifetime')
        truthy(reply.message:find('extended to its most', 1, true), reply.message)
        truthy(reply.message:find('the deadline only as far as it', 1, true), reply.message)
        truthy(row(s, c).deadline_at > deadline)

        -- At it: refused, nothing moved.
        local was = row(s, c).deadline_at
        reply = adjust(6, c, 3600)
        eq(reply.err, 'at_limit')
        eq(row(s, c).deadline_at, was)
        pass(main)
        eq(row(s, c).state, CH.STATE.ACCEPTED)
    end)
end)

describe('who may', function()
    it('a player without the ACE, and a reader, are refused, and nothing moves', function()
        local main, s = boot()
        local f = people(s)
        local c = running(main, s, f)
        local deadline = row(s, c).deadline_at
        for _, src in ipairs({ 1, 3, 7 }) do
            local reply = adjust(src, c, 3600)
            falsy(reply and reply.ok, src .. ': moved without the write ACE')
            eq(reply and reply.err, 'not_allowed', tostring(src))
            eq(reply.data, nil, 'and carries nothing')
        end
        eq(row(s, c).deadline_at, deadline, 'somebody moved it')
        eq(#stored(s, 'staff_deadline_adjust'), 0, 'a refusal was recorded as a change')
        eq(s.panel.OPS.adjustDeadline, s.panel.OPS.void, 'the same permission as void')
    end)
end)

describe('the record', function()
    it('staff_deadline_adjust: the staff member, the seconds, the reason, the old and new deadline', function()
        local main, s = boot()
        local f = people(s)
        local c = running(main, s, f, { anonymous = true })
        local deadline = row(s, c).deadline_at
        truthy(adjust(6, c, -1800, 'CREATOR1 asked, Vic Marlowe agreed').ok, 'shortened')
        local rows = stored(s, 'staff_deadline_adjust')
        eq(#rows, 1)
        eq(rows[1].actor_cid, 'ADMIN001')
        eq(rows[1].contract_id, c.id)
        eq(rows[1].detail.seconds, -1800)
        eq(rows[1].detail.reason, 'CREATOR1 asked, Vic Marlowe agreed')
        eq(rows[1].detail.old_deadline, deadline)
        eq(rows[1].detail.new_deadline, deadline - 1800)

        local function timelineRow(src)
            local view = ask(src, 'contract', { id = c.id })
            truthy(view and view.ok, 'read')
            for _, r in ipairs(view.data.timeline) do
                if r.action == 'staff_deadline_adjust' then return r end
            end
        end
        local plain = timelineRow(6)
        truthy(plain, 'on the contract\'s timeline')
        eq(plain.actor, '(a player)', 'the staff member named without the identity ACE')
        falsy(plain.detail.reason:find('CREATOR1', 1, true), plain.detail.reason)
        falsy(plain.detail.reason:find('Vic Marlowe', 1, true), 'the anonymous client named: ' .. plain.detail.reason)
        eq(plain.detail.old_deadline, deadline, 'the times are staff\'s to see')
        local whole = timelineRow(8)
        eq(whole.actor, 'ADMIN001')
        eq(whole.detail.reason, 'CREATOR1 asked, Vic Marlowe agreed')
    end)
end)

describe('what the parties are told', function()
    it('every party, in words with no figure and no name, and their open apps move on', function()
        local main, s = boot()
        local f = people(s)
        local c = running(main, s, f, { anonymous = true })
        Env.advance(Config.Notifications.PushMinIntervalSeconds or 1)

        local reply = adjust(6, c, 5400, 'Sam Steward: CREATOR1 lost 90 minutes')
        truthy(reply.ok, tostring(reply.message))
        local function clean(said)
            falsy(said:find('%d'), 'a figure in: ' .. said)
            for _, name in ipairs({ 'ADMIN001', 'Sam', 'Steward', 'CREATOR1', 'Vic', 'Marlowe',
                                    'HITMAN01', 'Rook', 'TARGET01', 'minutes', 'hour' }) do
                falsy(said:find(name, 1, true), name .. ' in: ' .. said)
            end
        end
        for _, src in ipairs({ 1, 2, 3 }) do
            local said = notices(src)
            eq(#said, 1, src .. ' was told ' .. #said .. ' time(s)')
            truthy(said[1]:find('Staff have extended this contract\'s time.', 1, true), said[1])
            clean(said[1])
            eq(pushes(src), 1, src .. '\'s open app was not moved on')
        end
        eq(#notices(6), 0, 'the staff member was told as a party')

        Env.advance(Config.Notifications.PushMinIntervalSeconds or 1)
        reply = adjust(6, c, -600)
        truthy(reply.ok, tostring(reply.message))
        for _, src in ipairs({ 1, 2, 3 }) do
            local said = notices(src)
            eq(#said, 1)
            truthy(said[1]:find('Staff have shortened this contract\'s time.', 1, true), said[1])
            clean(said[1])
        end
        -- The target's push names no contract, as every push to a target.
        Env.runTimers()
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:push' and event.target == 2 then
                eq(event.args[1].ids, nil, 'the target\'s push named the contract')
            end
        end
    end)

    it('a whitelisted-job target\'s view shows the new band, and is moved on', function()
        local main, s = boot()
        local f = people(s)
        Env.addPlayer({ source = 11, citizenid = 'OFFICER1', license = 'license:of1',
            cash = 50000, bank = 50000, firstname = 'Olive', lastname = 'Ward' })
        local police = { name = 'police', label = 'Police', type = 'leo', onduty = true }
        Env.players[11].PlayerData.job = police
        local c = place(s, f.creator, { targetCid = 'OFFICER1' })
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        pass(main)
        local function entry()
            local view = s.projection.whitelistedView('OFFICER1', police)
            for _, e in ipairs(view.onYou) do if e.id == c.id then return e end end
        end
        truthy(entry(), 'the officer\'s view lists it')
        local before = left(s, c)
        truthy(entry().timeLeft, 'a band')
        eq(entry().timeLeft, Util.timeBand(before))

        local reply = adjust(6, c, -(before - 600))
        truthy(reply.ok, tostring(reply.message))
        eq(entry().timeLeft, Util.timeBand(600), 'the officer\'s band did not follow')
        truthy(Util.timeBand(600) ~= Util.timeBand(before), 'the band moved')
        eq(pushes(11), 1, 'the officer\'s open view was not moved on')
        local said = notices(11)
        eq(#said, 1)
        truthy(said[1]:find('Staff have shortened this contract\'s time.', 1, true), said[1])
    end)
end)

describe('no money moves', function()
    it('cash, bank and every escrow line are as they were, through every kind of change', function()
        local main, s = boot()
        local f = people(s)
        local c = running(main, s, f, { penaltyAmount = 1000, bailoutAmount = 2000 })
        local before = snapshot(s, { c.id })
        truthy(adjust(6, c, 3600).ok)
        truthy(adjust(6, c, -1800).ok)
        local held = Env.players[3].PlayerData.money
        local cash, bank = held.cash, held.bank
        Env.removePlayer(3)
        pass(main)
        truthy(adjust(6, c, 900).ok)
        adjust(6, c, -86400)
        Config.Limits.ContractLifetimeSeconds = 400000
        truthy(adjust(6, c, 86400).ok)
        truthy(adjust(6, c, 86400).ok)
        Env.addPlayer({ source = 3, citizenid = 'HITMAN01', license = 'license:ccc', cash = cash,
            bank = bank, firstname = 'Rook', lastname = 'Ash' })
        pass(main)
        eq(snapshot(s, { c.id }), before, 'money moved')
        eq(row(s, c).state, CH.STATE.ACCEPTED)
    end)
end)
