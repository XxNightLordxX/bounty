--- Sweep 4: each decided fix, held to it.
---
---   D1  a restart-only setting waiting for the next start does not make
---       every other settings change refused;
---   D2  a staff write taking a player acts on exactly the player staff
---       looked up (an opaque lookup ref, or an exact citizenid), never on a
---       name or server id matched again at write time;
---   D3  the weekly stats and the daily digest do not total the contracts
---       on every tick when there is nowhere to send them.

describe('sweep 4 D1: a pending restart-only setting blocks nothing else', function()
    it('still changes a live key while a command name waits for the restart', function()
        local s = newStack()
        local was = Config.Admin.Commands.void
        truthy(s.settings.set('Admin.Commands.void', 'ch-void2', 'ADMIN001', 'ADMIN001'))
        eq(Config.Admin.Commands.void, was, 'the command waits for the next start')
        local ok, err, why = s.settings.set('Limits.MaxAcceptedPerHitman', 4, 'ADMIN001', 'ADMIN001')
        truthy(ok, tostring(err) .. ': ' .. tostring(why))
        eq(Config.Limits.MaxAcceptedPerHitman, 4)
        -- And another restart-only key beside the first.
        truthy(s.settings.set('Admin.Commands.stuck', 'ch-stuck2', 'ADMIN001', 'ADMIN001'))
        local v, cerr = s.settings.check('Limits.MaxAcceptedPerHitman', 3)
        eq(v, 3, tostring(cerr))
    end)

    it('checks a change beside the pending value, as the next start will run it', function()
        local s = newStack()
        truthy(s.settings.set('Admin.Commands.panel', 'ch-px', 'ADMIN001', 'ADMIN001'))
        local ok, err, why = s.settings.set('Admin.Commands.refresh', 'ch-px', 'ADMIN001', 'ADMIN001')
        falsy(ok, 'the refresh would take the panel\'s next name')
        eq(err, 'invalid_value')
        truthy(tostring(why):find('admin panel', 1, true), 'refused for the clash itself: ' .. tostring(why))
    end)
end)

--------------------------------------------------------------------------
-- D3: the weekly stats and the daily summary with nowhere to post
--------------------------------------------------------------------------

describe('sweep 4 D3: no totals read for a post that goes nowhere', function()
    local HOOK = 'https://discord.example/api/webhooks/4/x'

    --- Counts the store's full contract reads from here on.
    local function counting(s)
        local n = { reads = 0 }
        local all = s.storage.allContracts
        s.storage.allContracts = function(...)
            n.reads = n.reads + 1
            return all(...)
        end
        return n, function() s.storage.allContracts = all end
    end

    local function weeklyDue(s)
        local t = os.date('*t', os.time())
        Config.Improvements.WeeklyStats.Day = ({ 'sunday', 'monday', 'tuesday', 'wednesday', 'thursday',
            'friday', 'saturday' })[t.wday]
        Config.Improvements.WeeklyStats.Hour = t.hour
        Config.Improvements.WeeklyStats.Enabled = true
        s.impWeekly.init({ storage = s.storage, audit = s.audit, alerts = s.alerts })
    end

    it('weekly: no webhook reads no contract, tick after tick, and posts once one is set', function()
        local s = newStack()
        weeklyDue(s)
        local n, undo = counting(s)
        Natives.calls.http = {}
        for _ = 1, 30 do
            local posted, why = s.impWeekly.tick()
            falsy(posted)
            eq(why, 'no_webhook')
            Env.advance(10)
        end
        eq(n.reads, 0, 'the totals were worked out for a post with nowhere to go')
        Natives.convars[s.impWeekly.CONVAR] = HOOK
        truthy(s.impWeekly.tick(), 'posted on the next tick once a webhook is set')
        eq(n.reads, 1)
        undo()
        Natives.convars[s.impWeekly.CONVAR] = nil
    end)

    it('weekly: a refused send backs off ten minutes before reading again', function()
        local s = newStack()
        weeklyDue(s)
        Natives.convars[s.impWeekly.CONVAR] = HOOK
        local http = PerformHttpRequest
        _G.PerformHttpRequest = function() error('http down') end
        local n, undo = counting(s)
        for _ = 1, 30 do
            falsy(s.impWeekly.tick())
            Env.advance(10)
        end
        eq(n.reads, 1, 'read once, then backed off')
        Env.advance(s.impWeekly.BACKOFF_SECONDS)
        falsy(s.impWeekly.tick())
        eq(n.reads, 2, 'tried again after the back-off')
        _G.PerformHttpRequest = http
        Env.advance(s.impWeekly.BACKOFF_SECONDS)
        truthy(s.impWeekly.tick(), 'posted once it can')
        undo()
        Natives.convars[s.impWeekly.CONVAR] = nil
    end)

    it('daily summary: no webhook reads no contract, tick after tick, and posts once one is set', function()
        local s = newStack()
        Config.Staff.DailySummary = true
        Config.Staff.DailySummaryHour = 0
        local n, undo = counting(s)
        local unsettled, escrowReads = s.storage.unsettledEscrow, 0
        s.storage.unsettledEscrow = function(...)
            escrowReads = escrowReads + 1
            return unsettled(...)
        end
        for _ = 1, 30 do
            local posted, why = s.summary.tick()
            falsy(posted)
            eq(why, 'no_webhook')
            Env.advance(10)
        end
        eq(n.reads, 0, 'the counts were worked out for a post with nowhere to go')
        eq(escrowReads, 0)
        Natives.convars['crimson_hitman_webhook'] = HOOK
        truthy(s.summary.tick(), 'posted on the next tick once a webhook is set')
        eq(n.reads, 1)
        undo()
        s.storage.unsettledEscrow = unsettled
        Natives.convars['crimson_hitman_webhook'] = nil
    end)

    it('daily summary: a refused post backs off ten minutes before counting again', function()
        local s = newStack()
        Config.Staff.DailySummary = true
        Config.Staff.DailySummaryHour = 0
        Natives.convars['crimson_hitman_webhook'] = HOOK
        local post = s.alerts.post
        s.alerts.post = function() return false, 'unavailable' end
        local n, undo = counting(s)
        for _ = 1, 30 do
            falsy(s.summary.tick())
            Env.advance(10)
        end
        eq(n.reads, 1, 'counted once, then backed off')
        Env.advance(s.summary.BACKOFF_SECONDS)
        s.alerts.post = post
        truthy(s.summary.tick(), 'posted after the back-off')
        eq(n.reads, 2)
        undo()
        Natives.convars['crimson_hitman_webhook'] = nil
    end)
end)

--------------------------------------------------------------------------
-- D2: a staff write acts on the player staff looked up
--------------------------------------------------------------------------

describe('sweep 4 D2: staff writes bound to the looked-up player', function()
    --- Staff: 6 crimson.admin, 8 with crimson.identity too, 9 crimson.moderator.
    local function world()
        local s = newStack()
        local f = fixture(s)
        Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
            firstname = 'Sam', lastname = 'Steward' })
        Env.addPlayer({ source = 8, citizenid = 'UNMASK01', license = 'license:UNMASK01',
            firstname = 'Uma', lastname = 'Mask' })
        Env.addPlayer({ source = 9, citizenid = 'MODER001', license = 'license:MODER001',
            firstname = 'Mo', lastname = 'Derate' })
        Env.aces[6] = { ['crimson.admin'] = true }
        Env.aces[8] = { ['crimson.admin'] = true, ['crimson.identity'] = true }
        Env.aces[9] = { ['crimson.moderator'] = true }
        Config.Cooldowns.admin = { per = 10, burst = 1000 }
        Config.Cooldowns.adminWrite = { per = 10, burst = 1000 }
        s.bridges.install(s)
        return s, f
    end

    local function ask(src, op, data)
        Env.clientEvents = {}
        _G.source = src
        local fired, err = pcall(Env.events['crimson-hitman:admin'], { op = op, data = data or {}, __rid = 4 })
        _G.source = nil
        truthy(fired, 'the net event must not raise: ' .. tostring(err))
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:adminResult' then return event.args[1] end
        end
        return nil
    end

    local function lookup(src, subject)
        local reply = ask(src, 'player', { subject = subject })
        truthy(reply and reply.ok, 'looked up: ' .. tostring(reply and reply.message))
        return reply.data.player.ref, reply
    end

    --- Player 2 (Dana Reyes, TARGET01) leaves, and somebody else joins
    --- under the same player id with the same first name.
    local function swapSource2()
        Env.removePlayer(2)
        Env.addPlayer({ source = 2, citizenid = 'INTRUDE1', license = 'license:intr',
            cash = 0, bank = 0, firstname = 'Dana', lastname = 'Reyes' })
    end

    local function wealth(src)
        local m = Env.players[src].PlayerData.money
        return m.cash + m.bank
    end

    it('a lookup hands back an opaque handle, and no citizen id without the identity ACE', function()
        world()
        local ref, reply = lookup(6, 2)
        eq(type(ref), 'string', 'the lookup gives a handle')
        falsy(ref:find('TARGET01', 1, true), 'the handle is not the citizen id')
        eq(reply.data.player.cid, nil, 'not shown the citizen id, as before')
    end)

    it('pays the player looked up by player id, not whoever has that id at the click', function()
        local s = world()
        local ref = lookup(6, 2)
        swapSource2()
        local before = wealth(2)
        local reply = ask(6, 'manualPay', { ref = ref, amount = 500, account = 'cash', reason = 'refund' })
        truthy(reply.ok, tostring(reply.message))
        eq(wealth(2), before, 'the newcomer on player id 2 was paid')
        s.audit.flush()
        local text = json.encode(s.storage.auditByAction('staff_manual_payment', 10) or {})
        truthy(text:find('TARGET01', 1, true), 'paid to the character looked up: ' .. text)
        falsy(text:find('INTRUDE1', 1, true), 'paid to the newcomer: ' .. text)
    end)

    it('freezes, suspends and protects the player looked up by name, after a name clash', function()
        local s = world()
        local ref = lookup(6, 'Dana Reyes')
        swapSource2()
        truthy(ask(6, 'freeze', { ref = ref, reason = 'dispute' }).ok, 'frozen')
        truthy(s.freeze.of('TARGET01'), 'the looked-up player is frozen')
        falsy(s.freeze.of('INTRUDE1'), 'the newcomer is not')
        truthy(ask(6, 'suspend', { ref = ref, days = 1, reason = 'spam' }).ok, 'suspended')
        truthy(s.sanctions.suspended('TARGET01'))
        falsy(s.sanctions.suspended('INTRUDE1'))
        truthy(ask(6, 'protect', { ref = ref, hours = 1, reason = 'rp' }).ok, 'protected')
        truthy(s.sanctions.protected('TARGET01'))
        falsy(s.sanctions.protected('INTRUDE1'))
        truthy(ask(6, 'unsuspend', { ref = ref }).ok)
        truthy(ask(6, 'unprotect', { ref = ref }).ok)
        truthy(ask(6, 'unfreeze', { ref = ref }).ok)
        falsy(s.freeze.of('TARGET01'))
        truthy(ask(6, 'setPlaytime', { ref = ref, hours = 3 }).ok, 'playtime set')
        eq(s.playtime.view('TARGET01').hours, 3)
        eq(s.playtime.view('INTRUDE1').hours or 0, 0)
    end)

    it('never matches a name or a player id again on a write', function()
        local s = world()
        local before = wealth(2)
        for _, op in ipairs({ 'freeze', 'suspend', 'protect', 'manualPay', 'setPlaytime',
                              'unfreeze', 'unsuspend', 'unprotect' }) do
            for _, subject in ipairs({ 2, '2', 'Dana Reyes', 'Dana' }) do
                local reply = ask(6, op, { subject = subject, reason = 'x', days = 1, hours = 1, amount = 10,
                                           account = 'cash' })
                falsy(reply.ok, op .. ' by ' .. tostring(subject))
                local said = tostring(reply.message)
                -- 'Dana' has the shape of a citizen id: taken as one exactly,
                -- which no character has, never matched as a name.
                truthy(said:find('Look the player up', 1, true) or said:find('Nobody in the city', 1, true)
                    or (subject == 'Dana' and said:find('They are not', 1, true)), op .. ': ' .. said)
            end
        end
        eq(wealth(2), before)
        falsy(s.freeze.of('TARGET01'))
        falsy(s.sanctions.suspended('TARGET01'))
    end)

    it('still takes an exact citizen id typed', function()
        local s = world()
        truthy(ask(6, 'freeze', { subject = 'TARGET01', reason = 'typed' }).ok)
        truthy(s.freeze.of('TARGET01'))
    end)

    it('refuses a handle that is stale or another staff member\'s: look them up again', function()
        local s = world()
        local ref = lookup(6, 2)
        local other = ask(9, 'freeze', { ref = ref, reason = 'x' })
        falsy(other.ok, 'another staff member\'s handle')
        truthy(tostring(other.message):find('Look them up again', 1, true), tostring(other.message))
        falsy(s.freeze.of('TARGET01'))
        local made = ask(6, 'freeze', { ref = 'p999_123456', reason = 'x' })
        falsy(made.ok)
        truthy(tostring(made.message):find('Look them up again', 1, true), tostring(made.message))
        Env.advance(601)
        local late = ask(6, 'freeze', { ref = ref, reason = 'x' })
        falsy(late.ok, 'ten minutes on')
        truthy(tostring(late.message):find('Look them up again', 1, true), tostring(late.message))
        falsy(s.freeze.of('TARGET01'))
        -- A new lookup gives a new handle that works.
        truthy(ask(6, 'freeze', { ref = lookup(6, 2), reason = 'x' }).ok)
        truthy(s.freeze.of('TARGET01'))
    end)

    it('reads the card again by its handle, whatever the box says', function()
        world()
        local ref = lookup(8, 2)
        swapSource2()
        local again = ask(8, 'player', { ref = ref })
        truthy(again.ok, tostring(again.message))
        eq(again.data.player.cid, 'TARGET01')
        falsy(again.data.player.online, 'the looked-up player is away now')
    end)
end)
