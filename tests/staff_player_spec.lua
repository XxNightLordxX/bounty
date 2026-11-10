--- Staff tools for one player, from Players in the admin panel: suspending
--- them from contracts, protecting them from contracts, their history card,
--- a manual payment, and the moderator level (Config.Admin.ModeratorAce).
---
--- What these hold them to: a suspension refuses placing and accepting with
--- until when and why, and is on the board; a protection refuses a new
--- contract on them with the answer the target rules already give, and the
--- target search lists them as anybody; neither touches a live contract;
--- both end by themselves, are lifted at once, and are kept by all three
--- stores across a restart; the history card attributes nothing anonymous
--- to a player without IdentityAce, not even as a count; a manual payment
--- is capped, paid or owed, audited, and is the only money it adds to the
--- world; and every panel op is walked for every level.

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
    -- A stack booted through main.lua has them installed already.
    if s.bridges and s.bridges.install then s.bridges.install(s) end
end

local function world()
    local s = newStack()
    local f = fixture(s)
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

--- The handle a Players lookup gives (sweep 4 D2): what every write from
--- the card names the player by, never a name or a player id matched again.
local function lookedUp(src, subject)
    local reply = ask(src, 'player', { subject = subject })
    truthy(reply and reply.ok, 'looked up ' .. tostring(subject) .. ': ' .. tostring(reply and reply.message))
    return reply.data.player.ref
end

--- A player's request through the app's net event, and its reply.
local function call(name, src, payload)
    local from = #Env.clientEvents
    _G.source = src
    local fired, err = pcall(Env.events['crimson-hitman:' .. name], payload or {})
    _G.source = nil
    truthy(fired, name .. ' raised: ' .. tostring(err))
    for i = from + 1, #Env.clientEvents do
        local event = Env.clientEvents[i]
        if event.name == 'crimson-hitman:result' and event.target == src then return event.args[1] end
    end
    return nil
end

local function place(s, actor, target, extra)
    local req = { targetCid = target, reason = 'x', mode = CH.MODE.COMPETITIVE,
                  reward = { baseline = { cash = 5000 } } }
    for k, v in pairs(extra or {}) do req[k] = v end
    return s.contracts.create(actor, req)
end

local function wealth(src)
    local m = Env.players[src].PlayerData.money
    return m.cash + m.bank
end

local function rows(s, action)
    s.audit.flush()
    return s.storage.auditByAction(action, 100) or {}
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

--- Every string in a value, keys included, as one text.
local function text(value)
    local seen = {}
    local function walk(v)
        if type(v) == 'string' then seen[#seen + 1] = v
        elseif type(v) == 'number' then seen[#seen + 1] = tostring(v)
        elseif type(v) == 'table' then for k, inner in pairs(v) do walk(k) walk(inner) end end
    end
    walk(value)
    return table.concat(seen, '\n')
end

--------------------------------------------------------------------------
-- Suspensions
--------------------------------------------------------------------------

describe('a suspension from contracts', function()
    it('refuses placing and accepting with until when and why, and charges nothing', function()
        local s, f = world()
        local open = place(s, f.hitman, 'TARGET01')
        truthy(open, 'a contract to take')
        local reply = ask(6, 'suspend', { ref = lookedUp(6, 1), days = 3, reason = 'Contract spam' })
        eq(reply.ok, true, tostring(reply.message))
        truthy(reply.message:find('Their live contracts are not touched', 1, true), reply.message)

        local before = wealth(1)
        local placed, err, refusal = place(s, f.creator, 'TARGET01')
        falsy(placed, 'placed while suspended')
        eq(err, CH.ERR.SUSPENDED)
        eq(refusal.reason, 'Contract spam')
        truthy(math.abs(refusal.untilAt - (os.time() + 3 * 86400)) <= 2, 'until three days from now')
        eq(wealth(1), before, 'nothing taken')

        -- And through the app, as the player sees it.
        local r = call('accept', 1, { id = open.id, penaltyAmount = 0 })
        eq(r.ok, false)
        eq(r.err, 'suspended')
        eq(r.data.reason, 'Contract spam')
        eq(wealth(1), before, 'nothing taken on accept')
    end)

    it('is said on the board, the app\'s home, and in a notice naming no staff member', function()
        local s, f = world()
        Env.clientEvents = {}
        truthy(ask(6, 'suspend', { ref = lookedUp(6, 1), days = 0, reason = 'Pending a ticket' }).ok)
        local board = call('list', 1, { page = 1 })
        eq(board.ok, true)
        eq(board.data.suspended.reason, 'Pending a ticket')
        eq(board.data.suspended.untilAt, nil, 'until lifted')
        local other = call('list', 3, { page = 1 })
        eq(other.data.suspended, nil, 'nobody else\'s board says it')

        truthy(s.sanctions.suspended('CREATOR1'))
        local said = s.sanctions.suspendedText(s.sanctions.suspended('CREATOR1'))
        eq(said, 'You are suspended from contracts until staff lift it: Pending a ticket')
        truthy(ask(6, 'unsuspend', { ref = lookedUp(6, 1) }).ok)
        truthy(ask(6, 'suspend', { ref = lookedUp(6, 1), days = 2, reason = 'Again' }).ok)
        local row = s.sanctions.suspended('CREATOR1')
        eq(s.sanctions.suspendedText(row), ('You are suspended from contracts until %s: Again')
            :format(os.date('%Y-%m-%d %H:%M', row.until_at)))
        local told = table.concat(notices(1), '\n')
        truthy(told:find('You are suspended from contracts until', 1, true), told)
        falsy(told:find('ADMIN001', 1, true), 'no staff citizen id')
        falsy(told:find('Steward', 1, true), 'no staff name')
    end)

    it('leaves their live contracts alone: a hitman suspended mid-contract is still paid', function()
        local s, f = world()
        local c = place(s, f.creator, 'TARGET01')
        truthy(s.contracts.accept(f.hitman, c.id), 'taken before the suspension')
        truthy(ask(6, 'suspend', { ref = lookedUp(6, 3), days = 7, reason = 'x' }).ok)
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'untouched')
        local before = wealth(3)
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.KIDNAPPING))
        eq(wealth(3) - before, 5000, 'paid as usual')
    end)

    it('is lifted at once, and ends by itself when its time runs out', function()
        local s, f = world()
        truthy(ask(6, 'suspend', { ref = lookedUp(6, 1), days = 1, reason = 'x' }).ok)
        eq(ask(6, 'suspend', { ref = lookedUp(6, 1), days = 1, reason = 'y' }).err, 'already')
        truthy(ask(9, 'unsuspend', { ref = lookedUp(9, 1) }).ok, 'a moderator lifts it')
        truthy(place(s, f.creator, 'TARGET01'), 'places again once lifted')
        eq(ask(6, 'unsuspend', { ref = lookedUp(6, 1) }).err, 'not_active')

        truthy(ask(6, 'suspend', { ref = lookedUp(6, 3), days = 1, reason = 'x' }).ok)
        Env.advance(86400 - 5)
        eq(s.sanctions.suspended('HITMAN01') ~= nil, true, 'still in force a moment before')
        Env.advance(10)
        eq(s.sanctions.suspended('HITMAN01'), nil, 'over once its day is up')
        eq(s.sanctions.tick(), 1, 'the tick writes it down')
        local ended = rows(s, 'staff_suspend_expired')
        eq(#ended, 1)
        eq(ended[1].detail.subject, 'HITMAN01')
        local kept = s.sanctions.recordsOf('HITMAN01')
        eq(kept[#kept].ended_why, 'expired')
    end)

    it('is on the record, and refused to a player and to a reader', function()
        local s = world()
        eq(ask(1, 'suspend', { subject = 2, days = 1, reason = 'x' }).err, 'not_allowed')
        eq(ask(7, 'suspend', { subject = 2, days = 1, reason = 'x' }).err, 'not_allowed')
        eq(s.sanctions.suspended('TARGET01'), nil, 'nothing set')
        eq(ask(6, 'suspend', { ref = lookedUp(6, 2), days = 1 }).err, CH.ERR.INVALID_INPUT, 'a reason is required')
        eq(ask(6, 'suspend', { ref = lookedUp(6, 2), days = 400, reason = 'x' }).err, CH.ERR.INVALID_INPUT)
        truthy(ask(6, 'suspend', { ref = lookedUp(6, 2), days = 2, reason = 'Abuse' }).ok)
        local row = rows(s, 'staff_suspend')[1]
        eq(row.actor_cid, 'ADMIN001')
        eq(row.detail.subject, 'TARGET01')
        eq(row.detail.reason, 'Abuse')
        eq(row.detail.seconds, 2 * 86400)
        truthy(ask(6, 'unsuspend', { ref = lookedUp(6, 2) }).ok)
        eq(rows(s, 'staff_suspend_lifted')[1].detail.subject, 'TARGET01')
    end)
end)

--------------------------------------------------------------------------
-- Protections
--------------------------------------------------------------------------

describe('a protection from contracts', function()
    it('refuses a new contract on them as the target rules do, with nothing taken', function()
        local s, f = world()
        truthy(ask(6, 'protect', { ref = lookedUp(6, 2), hours = 48, reason = 'New player' }).ok)
        local before = wealth(1)
        local placed, err = place(s, f.creator, 'TARGET01')
        falsy(placed)
        eq(err, CH.ERR.TARGET_PROTECTED, 'the target rules\' own answer, nothing about staff')
        eq(wealth(1), before, 'nothing taken')
    end)

    it('lists them in the target search exactly as before, as a barred job is listed', function()
        local s = world()
        local function found()
            local r = call('searchTargets', 1, { query = 'Dana' })
            eq(r.ok, true)
            local out = {}
            for _, person in ipairs(r.data) do
                out[#out + 1] = person.name .. ':' .. tostring(person.protected) .. ':'
                    .. tostring(person.protectedAs)
            end
            return table.concat(out, ',')
        end
        local plain = found()
        truthy(ask(6, 'protect', { ref = lookedUp(6, 2), hours = 0, reason = 'RP break' }).ok)
        eq(found(), plain, 'the search says nothing a protection adds')
        local browse = call('browseTargets', 1, { scope = 'all' })
        local names = {}
        for _, p in ipairs(browse.data.people) do names[#names + 1] = p.name end
        truthy(table.concat(names, ','):find('Dana Reyes', 1, true), 'still listed to browse')
    end)

    it('leaves a contract already on them running', function()
        local s, f = world()
        local c = place(s, f.creator, 'TARGET01')
        truthy(s.contracts.accept(f.hitman, c.id))
        truthy(ask(9, 'protect', { ref = lookedUp(9, 2), hours = 0, reason = 'Off duty staff' }).ok, 'a moderator')
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED)
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.KIDNAPPING), 'completed as usual')
    end)

    it('ends by itself after its hours, lasts for good when permanent, and is lifted at once', function()
        local s, f = world()
        Env.addPlayer({ source = 10, citizenid = 'TARGET02', license = 'license:t2',
            firstname = 'Kit', lastname = 'Bell' })
        truthy(ask(6, 'protect', { ref = lookedUp(6, 2), hours = 2, reason = 'x' }).ok)
        truthy(ask(6, 'protect', { ref = lookedUp(6, 10), hours = 0, reason = 'y' }).ok)
        Env.advance(2 * 3600 + 1)
        eq(s.sanctions.protected('TARGET01'), nil, 'over after two hours')
        truthy(s.sanctions.protected('TARGET02'), 'permanent')
        s.sanctions.tick()
        eq(rows(s, 'staff_protect_expired')[1].detail.subject, 'TARGET01')
        Env.advance(400 * 86400)
        truthy(s.sanctions.protected('TARGET02'), 'still, a year on')
        truthy(ask(6, 'unprotect', { ref = lookedUp(6, 10) }).ok)
        eq(s.sanctions.protected('TARGET02'), nil)
        eq(rows(s, 'staff_protect_lifted')[1].detail.subject, 'TARGET02')
        truthy(place(s, f.creator, 'TARGET01'), 'a contract on them once it ended')
    end)

    it('is refused to a player and a reader, and on the record', function()
        local s = world()
        eq(ask(2, 'protect', { subject = 2, hours = 1, reason = 'x' }).err, 'not_allowed')
        eq(ask(7, 'protect', { subject = 2, hours = 1, reason = 'x' }).err, 'not_allowed')
        eq(s.sanctions.protected('TARGET01'), nil)
        truthy(ask(6, 'protect', { ref = lookedUp(6, 2), hours = 5, reason = 'New' }).ok)
        local row = rows(s, 'staff_protect')[1]
        eq(row.actor_cid, 'ADMIN001')
        eq(row.detail.subject, 'TARGET01')
        eq(row.detail.seconds, 5 * 3600)
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

describe('suspensions, protections and payments across a restart', function()
    for _, mode in ipairs({ 'memory', 'json', 'mysql' }) do
        it(mode .. ': kept by the store, and ended ones kept for the history', function()
            local _, s = boot(mode)
            fixture(s)
            staff(s)
            truthy(ask(6, 'suspend', { ref = lookedUp(6, 1), days = 2, reason = 'held' }).ok, mode)
            truthy(ask(6, 'protect', { ref = lookedUp(6, 2), hours = 0, reason = 'kept' }).ok, mode)
            truthy(ask(6, 'protect', { ref = lookedUp(6, 3), hours = 1, reason = 'short' }).ok, mode)
            truthy(ask(6, 'unprotect', { ref = lookedUp(6, 3) }).ok, mode)
            truthy(ask(6, 'manualPay', { ref = lookedUp(6, 3), amount = 100, account = 'bank', reason = 'refund' }).ok, mode)
            if mode == 'memory' then
                -- Nothing outlives the process in memory mode: read back
                -- from the store as a start would.
                s.sanctions.reload()
                truthy(s.sanctions.suspended('CREATOR1'), 'memory: read back')
                return
            end
            local _, after = restart(mode, s)
            local row = after.sanctions.suspended('CREATOR1')
            truthy(row, mode .. ': the suspension was lost to the restart')
            eq(row.reason, 'held', mode)
            truthy(math.abs(row.until_at - (os.time() + 2 * 86400)) <= 2, mode .. ': its end kept')
            truthy(after.sanctions.protected('TARGET01'), mode .. ': the protection was lost')
            eq(after.sanctions.protected('HITMAN01'), nil, mode .. ': a lifted one came back')
            local kinds = {}
            for _, r in ipairs(after.sanctions.recordsOf('HITMAN01')) do kinds[#kinds + 1] = r.kind end
            table.sort(kinds)
            eq(table.concat(kinds, ','), 'payment,protect', mode .. ': the history kept')
            local placed, err = after.contracts.create(after.identity.resolve(1) or {
                cid = 'CREATOR1' }, { targetCid = 'HITMAN01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                reward = { baseline = { cash = 5000 } } })
            falsy(placed, mode)
            eq(err, CH.ERR.SUSPENDED, mode)
        end)
    end
end)

--------------------------------------------------------------------------
-- The history card
--------------------------------------------------------------------------

describe('a player\'s history card', function()
    local function city()
        local s, f = world()
        Config.Anonymity.AllowAnonymousPlacer = true
        Config.Anonymity.CreatorFee = 0
        Env.addPlayer({ source = 10, citizenid = 'TARGET02', license = 'license:t2',
            cash = 1000, bank = 1000, firstname = 'Kit', lastname = 'Bell' })
        -- One named, completed by the hitman; one anonymous, cancelled.
        local named = place(s, f.creator, 'TARGET01')
        truthy(s.contracts.accept(f.hitman, named.id))
        truthy(s.contracts.claimSlot(named.id, 'HITMAN01', CH.FULFILMENT.KIDNAPPING))
        local anon = place(s, f.creator, 'TARGET02', { anonymous = true, reward = { baseline = { cash = 7000 } } })
        truthy(anon, 'the anonymous one')
        truthy(s.contracts.cancel(f.creator, anon.id))
        truthy(ask(6, 'freeze', { ref = lookedUp(6, 1), reason = 'dispute' }).ok)
        truthy(ask(6, 'unfreeze', { ref = lookedUp(6, 1) }).ok)
        truthy(ask(6, 'suspend', { ref = lookedUp(6, 1), days = 1, reason = 'spam' }).ok)
        truthy(ask(6, 'protect', { ref = lookedUp(6, 1), hours = 3, reason = 'rp break' }).ok)
        truthy(ask(6, 'manualPay', { ref = lookedUp(6, 1), amount = 250, account = 'cash', reason = 'bug' }).ok)
        return s, f, named, anon
    end

    it('counts, money by kind and every measure with its dates, with IdentityAce', function()
        local _, _, named, anon = city()
        local reply = ask(8, 'history', { subject = 'CREATOR1' })
        eq(reply.ok, true, tostring(reply.message))
        local h = reply.data
        eq(h.counts.placed, 2)
        eq(h.counts.cancelled, 1)
        eq(h.anonymous, 1, 'one of them anonymous')
        local money = {}
        for _, r in ipairs(h.money.out) do money['out ' .. r.kind] = r.amount end
        for _, r in ipairs(h.money['in']) do money['in ' .. r.kind] = r.amount end
        eq(money['out rewards put up'], 12000)
        eq(money['in rewards returned'], 7000)
        eq(money['in staff payments'], 250)
        local kinds = {}
        for _, m in ipairs(h.measures) do kinds[#kinds + 1] = m.kind .. ':' .. m.state end
        table.sort(kinds)
        eq(table.concat(kinds, ','), 'freeze:lifted,protect:in force,suspend:in force')
        for _, m in ipairs(h.measures) do truthy(m.from, m.kind .. ' has its date') end
        local seen = text(h)
        truthy(seen:find('Kit Bell', 1, true), 'names with IdentityAce')
        truthy(seen:find(anon.id, 1, true) and seen:find(named.id, 1, true), 'both contracts')
    end)

    it('attributes nothing anonymous, not even a count, and names nobody, without IdentityAce', function()
        local _, _, named, anon = city()
        for _, src in ipairs({ 6, 7, 9 }) do
            local reply = ask(src, 'history', { subject = 'CREATOR1' })
            eq(reply.ok, true, src .. ': ' .. tostring(reply.message))
            local h = reply.data
            eq(h.counts.placed, 1, src .. ': the anonymous one is not theirs here')
            eq(h.counts.cancelled, 0, src .. ': nor its cancelling')
            eq(h.anonymous, nil, src .. ': no count of them')
            for _, r in ipairs(h.money.out) do
                if r.kind == 'rewards put up' then eq(r.amount, 5000, src .. ': nor its money') end
            end
            for _, r in ipairs(h.money['in']) do
                falsy(r.kind == 'rewards returned', src .. ': nor its refund')
            end
            local seen = text(h)
            falsy(seen:find(anon.id, 1, true), src .. ': the anonymous contract is not listed')
            truthy(seen:find(named.id, 1, true), src .. ': the named one is')
            for _, needle in ipairs({ 'Kit Bell', 'Dana Reyes', 'Vic Marlowe', 'ADMIN001', 'TARGET02' }) do
                falsy(seen:find(needle, 1, true), src .. ': ' .. needle)
            end
        end
        eq(ask(1, 'history', { subject = 'CREATOR1' }).err, 'not_allowed', 'a player')
    end)

    it('shows the hitman their payout and the target the buyout', function()
        local s, f = world()
        local c = place(s, f.creator, 'TARGET01', { bailoutAmount = 15000 })
        truthy(s.bailout.buy(f.target, c.id), 'bought out')
        local h = ask(6, 'history', { subject = 2 }).data
        eq(h.counts.onThem, 1)
        eq(h.counts.boughtOut, 1)
        eq(h.buyouts.paid, 1)
        eq(h.buyouts.amount, 15000)
        local s2, f2 = world()
        local c2 = place(s2, f2.creator, 'TARGET01')
        truthy(s2.contracts.accept(f2.hitman, c2.id))
        truthy(s2.contracts.claimSlot(c2.id, 'HITMAN01', CH.FULFILMENT.KIDNAPPING))
        local h2 = ask(6, 'history', { subject = 3 }).data
        eq(h2.counts.taken, 1)
        eq(h2.counts.completed, 1)
        eq(h2.money['in'][1].kind, 'payouts')
        eq(h2.money['in'][1].amount, 5000)
    end)
end)

--------------------------------------------------------------------------
-- Manual payments
--------------------------------------------------------------------------

--- Every dollar in the world: every pocket online, `away` for players who
--- are not, and every money line held in escrow, a contract's or owed.
local function worldMoney(s, away)
    local total = away or 0
    for _, p in pairs(Env.players) do
        total = total + (p.PlayerData.money.cash or 0) + (p.PlayerData.money.bank or 0)
    end
    local seen = {}
    for _, c in ipairs(s.storage.allContracts()) do
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            seen[line.id] = true
            if (line.source == 'cash' or line.source == 'bank') and line.state ~= CH.ESCROW_STATE.SETTLED then
                total = total + (line.amount or 0)
            end
        end
    end
    for _, line in ipairs(s.storage.owedHeldEscrow()) do
        if not seen[line.id] and (line.source == 'cash' or line.source == 'bank') then
            total = total + (line.amount or 0)
        end
    end
    return total
end

--- What staff_manual_payment rows say was made: the one money the
--- conservation rule lets into the world, excluded from it by name.
local function staffMade(s)
    local sum = 0
    for _, row in ipairs(rows(s, 'staff_manual_payment')) do
        if not row.detail.failed then sum = sum + row.detail.amount end
    end
    return sum
end

describe('a manual payment', function()
    it('pays a player in the city at once, audited, and adds exactly that to the world', function()
        local s = world()
        local before, cash = worldMoney(s), Env.players[2].PlayerData.money.cash
        local reply = ask(6, 'manualPay', { ref = lookedUp(6, 2), amount = 4000, account = 'cash', reason = 'Lost to a bug' })
        eq(reply.ok, true, tostring(reply.message))
        eq(reply.data.paid, true)
        eq(Env.players[2].PlayerData.money.cash - cash, 4000)
        local row = rows(s, 'staff_manual_payment')[1]
        eq(row.kind, 'financial')
        eq(row.actor_cid, 'ADMIN001')
        eq(row.detail.subject, 'TARGET01')
        eq(row.detail.amount, 4000)
        eq(row.detail.account, 'cash')
        eq(row.detail.reason, 'Lost to a bug')
        eq(worldMoney(s), before + staffMade(s), 'nothing but the payment was made')
        eq(staffMade(s), 4000)
        local told = table.concat(notices(2), '\n')
        truthy(told:find('Staff paid you', 1, true), told)
        falsy(told:find('Steward', 1, true) or told:find('ADMIN001', 1, true), 'no staff member named')
    end)

    it('owes a player who is away, handed over at their next login, made once', function()
        local s = world()
        local cash = Env.players[2].PlayerData.money.cash
        local before = worldMoney(s)
        local away = cash + Env.players[2].PlayerData.money.bank
        Env.removePlayer(2)
        local reply = ask(6, 'manualPay', { subject = 'TARGET01', amount = 3000, account = 'cash', reason = 'Refund' })
        eq(reply.ok, true, tostring(reply.message))
        eq(reply.data.owed, true)
        eq(worldMoney(s, away), before + 3000, 'owed on a line while they are away')
        eq(#s.storage.readPending('TARGET01'), 1, 'queued for their login')

        Env.addPlayer({ source = 2, citizenid = 'TARGET01', license = 'license:bbb',
            cash = cash, bank = 20000, firstname = 'Dana', lastname = 'Reyes' })
        s.escrow.retryPending('TARGET01')
        eq(Env.players[2].PlayerData.money.cash, cash + 3000, 'handed over')
        eq(worldMoney(s), before + staffMade(s), 'and made only once')
        s.escrow.retryPending('TARGET01')
        eq(Env.players[2].PlayerData.money.cash, cash + 3000, 'not again')
    end)

    it('is capped by Config.Staff.ManualPaymentMax, off at 0, and needs a reason and an account', function()
        local s = world()
        eq(Config.Staff.ManualPaymentMax, 100000, 'ships as 100000')
        local before = worldMoney(s)
        eq(ask(6, 'manualPay', { ref = lookedUp(6, 2), amount = 100001, account = 'bank', reason = 'x' }).err, 'over_max')
        eq(ask(6, 'manualPay', { ref = lookedUp(6, 2), amount = 10, account = 'bank' }).err, CH.ERR.INVALID_INPUT)
        eq(ask(6, 'manualPay', { ref = lookedUp(6, 2), amount = 10, account = 'dirty', reason = 'x' }).err,
            CH.ERR.INVALID_INPUT)
        eq(ask(6, 'manualPay', { ref = lookedUp(6, 2), amount = -5, account = 'bank', reason = 'x' }).err,
            CH.ERR.INVALID_INPUT)
        eq(ask(6, 'manualPay', { ref = lookedUp(6, 2), amount = 2.5, account = 'bank', reason = 'x' }).err,
            CH.ERR.INVALID_INPUT)
        truthy(ask(6, 'manualPay', { ref = lookedUp(6, 2), amount = 100000, account = 'bank', reason = 'x' }).ok, 'at the cap')
        truthy(s.settings.set('Staff.ManualPaymentMax', 0, 'ADMIN001', 'ADMIN001'), 'turned off from the panel')
        eq(ask(6, 'manualPay', { ref = lookedUp(6, 2), amount = 1, account = 'bank', reason = 'x' }).err, 'payments_off')
        eq(worldMoney(s), before + 100000)
        eq(staffMade(s), 100000)
    end)

    it('is refused to a player, a reader and a moderator, with nothing paid', function()
        local s = world()
        local before = worldMoney(s)
        for _, src in ipairs({ 1, 7, 9 }) do
            eq(ask(src, 'manualPay', { subject = 2, amount = 10, account = 'cash', reason = 'x' }).err,
                'not_allowed', 'source ' .. src)
        end
        eq(worldMoney(s), before)
        eq(#rows(s, 'staff_manual_payment'), 0)
    end)
end)

--------------------------------------------------------------------------
-- The moderator level, op by op
--------------------------------------------------------------------------

describe('every panel op, for every level', function()
    --- Each op's level, named here so moving one is a change to this table
    --- as well as to panel.lua.
    local EXPECTED = {
        access = 'read', overview = 'read', contracts = 'read', contract = 'read', reviews = 'read',
        logs = 'read', player = 'read', settings = 'read', diag = 'read', stuck = 'read', alerts = 'read',
        frozen = 'read', history = 'read', exportContract = 'read', playerView = 'read',
        void = 'moderate', freeze = 'moderate', unfreeze = 'moderate', adjustDeadline = 'moderate',
        suspend = 'moderate', unsuspend = 'moderate', protect = 'moderate', unprotect = 'moderate',
        settle = 'write', resolve = 'write', setSetting = 'write', resetSetting = 'write',
        resetSettings = 'write', refresh = 'write', flush = 'write', ackAlerts = 'write',
        testAlert = 'write', removePhotos = 'write', setPlaytime = 'write', manualPay = 'write',
        announce = 'write', undoSetting = 'write', settingsHistory = 'read',
        addNote = 'write', removeHitman = 'write', editText = 'write',
        console = 'developer', whois = 'identity',
        -- Target limits.
        targetLimits = 'read', targetStatus = 'read', targetJobCount = 'read', targetContracts = 'read',
        targetJobSet = 'write', targetJobRemove = 'write',
        targetReset = 'moderate', targetExtend = 'moderate', targetCounts = 'moderate',
        targetOverride = 'moderate', targetOverrideClear = 'moderate', targetJobAction = 'moderate',
    }

    it('maps each op to exactly one level, and every op the panel has is mapped here', function()
        local s = world()
        for op, level in pairs(s.panel.OPS) do
            eq(EXPECTED[op], level, op)
        end
        for op in pairs(EXPECTED) do truthy(s.panel.OPS[op], op .. ' is an op') end
    end)

    --- What each level gets for an op of each kind: refused as not allowed,
    --- or past the gate (whatever the op then says about its empty data).
    local GATE = {
        none      = { read = 'not_allowed', moderate = 'not_allowed', write = 'not_allowed',
                      developer = 'not_allowed', identity = 'not_allowed' },
        reader    = { read = true, moderate = 'not_allowed', write = 'not_allowed',
                      developer = 'developer_required', identity = 'identity_required' },
        moderator = { read = true, moderate = true, write = 'not_allowed',
                      developer = 'developer_required', identity = 'identity_required' },
        admin     = { read = true, moderate = true, write = true, developer = true,
                      identity = 'identity_required' },
    }
    local SOURCE = { none = 1, reader = 7, moderator = 9, admin = 6 }
    local GATE_ERRS = { not_allowed = true, developer_required = true, identity_required = true }

    for _, who in ipairs({ 'none', 'reader', 'moderator', 'admin' }) do
        it(who .. ': walks every op', function()
            local s = world()
            local ops = {}
            for op in pairs(s.panel.OPS) do ops[#ops + 1] = op end
            table.sort(ops)
            for _, op in ipairs(ops) do
                local reply = ask(SOURCE[who], op, {})
                truthy(reply, who .. ' ' .. op .. ' is answered')
                local expected = GATE[who][s.panel.OPS[op]]
                if expected == true then
                    falsy(GATE_ERRS[reply.err], who .. ' ' .. op .. ' was refused: ' .. tostring(reply.err))
                else
                    eq(reply.err, expected, who .. ' ' .. op)
                    eq(reply.data, nil, who .. ' ' .. op .. ' carries nothing')
                end
            end
        end)
    end

    it('lets a moderator void, move a deadline and freeze, scrubbed as without IdentityAce', function()
        local s, f = world()
        Config.Anonymity.AllowAnonymousPlacer = true
        Config.Anonymity.CreatorFee = 0
        local c = place(s, f.creator, 'TARGET01', { anonymous = true })
        truthy(s.contracts.accept(f.hitman, c.id))
        local view = ask(9, 'contract', { id = c.id })
        eq(view.ok, true)
        eq(view.data.contract.client.name, 'Anonymous')
        falsy(text(view.data):find('CREATOR1', 1, true), 'no citizen id')
        falsy(text(view.data):find('Marlowe', 1, true), 'no name')
        truthy(ask(9, 'adjustDeadline', { id = c.id, seconds = 1800, reason = 'lag' }).ok, 'deadline')
        truthy(ask(9, 'freeze', { ref = lookedUp(9, 3), reason = 'x' }).ok, 'freeze')
        truthy(ask(9, 'unfreeze', { ref = lookedUp(9, 3) }).ok, 'unfreeze')
        truthy(ask(9, 'void', { id = c.id, reason = 'ticket' }).ok, 'void')
        eq(s.storage.readContract(c.id).state, CH.STATE.VOIDED)
        eq(ask(9, 'setSetting', { key = 'Relay.Enabled', value = false }).err, 'not_allowed', 'no settings')
        eq(ask(9, 'whois', { id = c.id }).err, 'identity_required')
        eq(ask(9, 'console', {}).err, 'developer_required')
        local access = ask(9, 'access', {}).data
        eq(access.canWrite, false)
        eq(access.canModerate, true)
        eq(access.canIdentify, false)
        eq(access.canDevelop, false)
    end)

    it('keeps everything for crimson.admin, and lists the moderator ACE on Permissions', function()
        local s = world()
        local access = ask(6, 'access', {}).data
        eq(access.canWrite, true)
        eq(access.canModerate, true)
        local found
        for _, row in ipairs(access.permissions) do
            if row.ace == 'crimson.moderator' then found = row end
        end
        truthy(found, 'the moderator ACE is listed')
        eq(found.held, false)
        truthy(found.name:find('Config.Admin.ModeratorAce', 1, true), found.name)
        truthy(found.grant:find('crimson.moderator', 1, true), found.grant)
        local mine = ask(9, 'access', {}).data
        for _, row in ipairs(mine.permissions) do
            if row.ace == 'crimson.moderator' then eq(row.held, true, 'the moderator holds it') end
        end
    end)
end)
