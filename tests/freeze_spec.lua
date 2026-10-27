--- Staff freezes (server/freeze.lua): a player's contracts put on hold from
--- the admin panel.
---
--- Booted through main.lua, so the expiry pass and the maintenance tick are
--- the real ones. What these hold the freeze to: both clocks stop and the
--- time on hold is given back to the second; every action on a contract on
--- hold is refused as contract_frozen with nothing charged or moved, the
--- placer's cancel and the expiry among them; it survives a restart on json
--- and mysql; nobody is told which party it is about; only staff with the
--- write ACE may freeze; and each freeze and release is on the record.

local Exec = require('tests.harness.mysql_exec')

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
    Config.Database.Mode = mode or 'memory'
    if mode == 'mysql' then Exec.install(Natives) end
    if mode == 'json' then Natives.files = {} end
    Config.Cooldowns.admin = { per = 10, burst = 500 }
    Config.Cooldowns.adminWrite = { per = 10, burst = 500 }
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

--- The usual three players, a second hitman, and three staff: crimson.admin,
--- a read-only extra ACE, and crimson.admin with crimson.identity.
local function people(s)
    local f = fixture(s)
    Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
        cash = 5000, bank = 50000, firstname = 'Kit', lastname = 'Vane' })
    Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
        firstname = 'Sam', lastname = 'Steward' })
    Env.addPlayer({ source = 7, citizenid = 'READER01', license = 'license:READER01',
        firstname = 'Rae', lastname = 'Dent' })
    Env.addPlayer({ source = 8, citizenid = 'UNMASK01', license = 'license:UNMASK01',
        firstname = 'Uma', lastname = 'Mask' })
    Env.aces[6] = { ['crimson.admin'] = true }
    Env.aces[7] = { command = true }
    Env.aces[8] = { ['crimson.admin'] = true, ['crimson.identity'] = true }
    f.hitman2 = s.identity.resolve(4)
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

--- Every player's cash and bank, and every escrow line's state and amount.
local function snapshot(s, ids)
    local out = {}
    for src = 1, 4 do
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

local function place(s, actor, target, extra)
    local req = { targetCid = target, reason = 'x', mode = CH.MODE.COMPETITIVE,
                  reward = { baseline = { cash = 5000 } } }
    for k, v in pairs(extra or {}) do req[k] = v end
    local c, err = s.contracts.create(actor, req)
    truthy(c, 'placed: ' .. tostring(err))
    return c
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

local function has(list, needle)
    for _, text in ipairs(list) do if text:find(needle, 1, true) then return true end end
    return false
end

local function stored(s, action)
    s.audit.flush()
    return s.storage.auditByAction(action, 100) or {}
end

--------------------------------------------------------------------------

describe('a freeze stops both clocks, and gives the time back to the second', function()
    it('deadline and lifetime stand still, nothing expires, and unfreeze restores both', function()
        local main, s = boot('memory')
        local f = people(s)
        local c = place(s, f.creator, 'TARGET01', { penaltyAmount = 500 })
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        main.markPresenceChanged()
        main.expire()

        local row = s.storage.readContract(c.id)
        local now = os.time()
        local deadlineLeft, lifetimeLeft = row.deadline_at - now, row.expires_at - now
        truthy(row.paused_since == nil, 'running before the freeze')

        local reply = ask(6, 'freeze', { subject = 2, reason = 'RP dispute' })
        truthy(reply and reply.ok, 'frozen: ' .. tostring(reply and reply.message))
        local frozenAt = os.time()
        eq(s.storage.readContract(c.id).paused_since, frozenAt, 'the deadline stopped as it was frozen')

        local before = snapshot(s, { c.id })
        -- Past the deadline and the lifetime both.
        local away = math.max(deadlineLeft, lifetimeLeft) + 3600
        Env.advance(away)
        main.markPresenceChanged()
        main.tick()
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'expired while on hold')
        eq(snapshot(s, { c.id }), before, 'something moved while on hold')
        local Util = require('crimson-hitman.shared.util')
        eq(Util.runLeft(s.storage.readContract(c.id)), deadlineLeft, 'the clock ran on while on hold')
        local band = Util.timeBand(deadlineLeft)
        eq(s.projection.contract(s.storage.readContract(c.id), 'HITMAN01').timeLeft, band,
            'the hitman\'s band moved while on hold')
        eq(s.projection.contract(s.storage.readContract(c.id), 'TARGET01').timeLeft, band,
            'the target\'s band moved while on hold')

        reply = ask(6, 'unfreeze', { subject = 2, reason = 'sorted' })
        truthy(reply and reply.ok, 'unfrozen: ' .. tostring(reply and reply.message))
        row = s.storage.readContract(c.id)
        now = os.time()
        eq(row.paused_since, nil, 'the pause was ended')
        eq(row.deadline_at - now, deadlineLeft, 'the deadline did not get its time back to the second')
        eq(row.expires_at - now, lifetimeLeft, 'the lifetime did not get its time back to the second')
        eq(tonumber(row.paused_ms), away * 1000, 'banked as every pause is banked')

        main.markPresenceChanged()
        main.tick()
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'expired the moment it was released')
        eq(snapshot(s, { c.id }), before, 'the release moved something')
    end)

    it('two frozen parties: on hold until the last is released, the lifetime given back once', function()
        local main, s = boot('memory')
        local f = people(s)
        local c = place(s, f.creator, 'TARGET01')
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        local row = s.storage.readContract(c.id)
        local lifetimeLeft = row.expires_at - os.time()
        local deadlineLeft = row.deadline_at - os.time()
        truthy(s.freeze.freeze('ADMIN001', 'TARGET01', 'a'), 'target frozen')
        Env.advance(100)
        truthy(s.freeze.freeze('ADMIN001', 'CREATOR1', 'b'), 'client frozen')
        Env.advance(100)
        truthy(s.freeze.unfreeze('ADMIN001', 'TARGET01'), 'target released')
        truthy(s.freeze.holds(s.storage.readContract(c.id)), 'still on hold through the client')
        Env.advance(100)
        truthy(s.freeze.unfreeze('ADMIN001', 'CREATOR1'), 'client released')
        row = s.storage.readContract(c.id)
        eq(row.expires_at - os.time(), lifetimeLeft, 'the lifetime was given back twice, or short')
        eq(row.deadline_at - os.time(), deadlineLeft, 'the deadline was given back twice, or short')
        main.markPresenceChanged()
        main.expire()
    end)
end)

describe('every action on a contract on hold is refused, with nothing charged', function()
    it('accept, payout, handover, buyout, informants, tip, amendments, cancel, edit, walk away', function()
        local main, s = boot('memory')
        local f = people(s)
        -- The client's contract, taken; and an untaken one of theirs.
        local c = place(s, f.creator, 'TARGET01', { bailoutAmount = 1000 })
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        local c2 = place(s, f.creator, 'HITMAN02')
        -- Somebody else's, which the client might take.
        local c3 = place(s, f.hitman2, 'HITMAN01')
        main.markPresenceChanged()
        main.expire()

        local reply = ask(6, 'freeze', { subject = 1, reason = 'staff situation' })
        truthy(reply and reply.ok, 'frozen: ' .. tostring(reply and reply.message))
        local before = snapshot(s, { c.id, c2.id, c3.id })
        local F = CH.ERR.CONTRACT_FROZEN

        local function refused(label, ok, err)
            falsy(ok, label .. ': went through on a contract on hold')
            eq(err, F, label .. ': refused as ' .. tostring(err))
        end
        refused('a second hitman accepting', s.contracts.accept(f.hitman2, c.id))
        refused('the frozen player taking a contract', s.contracts.accept(f.creator, c3.id))
        refused('the frozen player placing one', s.contracts.create(f.creator,
            { targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
              reward = { baseline = { cash = 100 } } }))
        refused('a contract placed on the frozen player', s.contracts.create(f.hitman2,
            { targetCid = 'CREATOR1', reason = 'x', mode = CH.MODE.COMPETITIVE,
              reward = { baseline = { cash = 100 } } }))
        refused('the payout', s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION, {}))
        refused('arming a handover', s.kidnap.arm(c.id, 'HITMAN01'))
        refused('the buyout', s.bailout.buy(f.target, c.id))
        refused('the target\'s informant', s.informant.buy(f.target, c.id, nil, 'x'))
        refused('the placer\'s informant', s.informant.placerBuy(f.creator, c.id, nil, 'x'))
        refused('the location tip', s.locationTip.buy(f.hitman, c.id, nil))
        refused('a proposed amendment', s.amendments.propose(f.creator, c.id,
            CH.AMENDMENT.CHANGE_REASON, { reason = 'y' }))
        refused('an additive amendment', s.amendments.improve(f.creator, c.id,
            CH.AMENDMENT.RAISE_BONUS, { percent = 10 }))
        refused('more escrow', s.amendments.addEscrow(f.creator, c.id, { baseline = { cash = 100 } }))
        refused('the placer\'s cancel', s.contracts.cancel(f.creator, c2.id))
        refused('an edit', s.contracts.revise(f.creator, c2.id, { reason = 'z' }))
        refused('walking away', s.contracts.abandon(f.hitman, c.id))
        refused('any ending but a void', s.contracts.resolve(c2.id, CH.STATE.CANCELLED, 'CREATOR1', nil, 'x'))

        main.markPresenceChanged()
        main.tick()
        eq(snapshot(s, { c.id, c2.id, c3.id }), before, 'something was charged, refunded or moved')
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED)
        eq(s.storage.readContract(c2.id).state, CH.STATE.ACTIVE)

        -- Released: the same calls work again.
        truthy(ask(6, 'unfreeze', { subject = 1 }).ok, 'unfrozen')
        truthy(s.contracts.cancel(f.creator, c2.id), 'the cancel works once released')
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION, {}),
            'the payout works once released')
    end)

    it('money is conserved across a freeze, the refusals and the release', function()
        local main, s = boot('memory')
        local f = people(s)
        local c = place(s, f.creator, 'TARGET01', { penaltyAmount = 1000, bailoutAmount = 2000 })
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        local function total()
            local sum = 0
            for src = 1, 4 do
                local m = Env.players[src].PlayerData.money
                sum = sum + m.cash + m.bank
            end
            for _, line in ipairs(s.storage.readEscrow(c.id) or {}) do
                if line.state ~= CH.ESCROW_STATE.SETTLED and CH.MONEY_SOURCES[line.source] then
                    sum = sum + (tonumber(line.amount) or 0)
                end
            end
            return sum
        end
        local start = total()
        truthy(s.freeze.freeze('ADMIN001', 'HITMAN01', 'x'), 'the operative frozen')
        s.bailout.buy(f.target, c.id)
        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION, {})
        s.contracts.abandon(f.hitman, c.id)
        Env.advance(10 * 24 * 3600)
        main.markPresenceChanged()
        main.tick()
        eq(total(), start, 'money appeared or vanished while on hold')
        truthy(s.freeze.unfreeze('ADMIN001', 'HITMAN01'), 'released')
        main.markPresenceChanged()
        main.tick()
        eq(total(), start, 'money appeared or vanished on the release')
    end)
end)

describe('a freeze across a restart', function()
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it(mode .. ': is kept, still holds the contract, and is released after', function()
            local _, s = boot(mode)
            local f = people(s)
            local c = place(s, f.creator, 'TARGET01')
            truthy(s.contracts.accept(f.hitman, c.id), 'taken')
            truthy(ask(6, 'freeze', { subject = 2, reason = 'held over' }).ok, 'frozen')

            local main2, after = restart(mode, s)
            local row = after.freeze.of('TARGET01')
            truthy(row, mode .. ': the freeze was lost to the restart')
            eq(row.reason, 'held over', mode)
            eq(after.freeze.count(), 1, mode)
            local ok, err = after.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION, {})
            falsy(ok, mode .. ': paid out after the restart')
            eq(err, CH.ERR.CONTRACT_FROZEN, mode)
            Env.advance(30 * 24 * 3600)
            main2.markPresenceChanged()
            main2.tick()
            eq(after.storage.readContract(c.id).state, CH.STATE.ACCEPTED, mode .. ': expired on hold')

            truthy(ask(6, 'unfreeze', { subject = 2 }).ok, mode .. ': unfrozen')
            eq(after.freeze.of('TARGET01'), nil, mode)
            local _, third = restart(mode, after)
            eq(third.freeze.of('TARGET01'), nil, mode .. ': the release was lost to the restart')
        end)
    end
end)

describe('nobody is told which party is frozen', function()
    it('the cards say On hold and nothing else, and the notices name nobody', function()
        local _, s = boot('memory')
        local f = people(s)
        local c = place(s, f.creator, 'TARGET01', { anonymous = true })
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        local row = s.storage.readContract(c.id)
        local hitmanBefore = s.projection.contract(row, 'HITMAN01')
        local targetBefore = s.projection.contract(row, 'TARGET01')

        Env.clientEvents = {}
        truthy(s.freeze.freeze('ADMIN001', 'CREATOR1', 'dispute'), 'the anonymous placer frozen')
        local toPlacer, toHitman, toTarget = notices(1), notices(3), notices(2)
        truthy(has(toPlacer, 'Staff have put your contracts on hold.'), 'the frozen player was not told')
        falsy(has(toPlacer, 'This contract is on hold by staff.'), 'the frozen player told per contract')
        truthy(has(toHitman, 'This contract is on hold by staff.'), 'the operative was not told')
        falsy(has(toHitman, 'your contracts'), 'the operative was told what the frozen player was')
        for _, said in ipairs(toHitman) do
            falsy(said:find('Vic', 1, true) or said:find('CREATOR1', 1, true)
                or said:lower():find('client', 1, true) or said:lower():find('placer', 1, true),
                'the notice says who: ' .. said)
        end
        for _, said in ipairs(toTarget) do
            falsy(said:find('Vic', 1, true) or said:lower():find('client', 1, true), 'the target told who')
        end

        row = s.storage.readContract(c.id)
        local hitmanView = s.projection.contract(row, 'HITMAN01')
        local targetView = s.projection.contract(row, 'TARGET01')
        eq(hitmanView.onHold, true, 'the operative\'s card does not say On hold')
        eq(targetView.onHold, true, 'the target\'s card does not say On hold')
        eq(targetView.clockStopped, nil, 'the target\'s card says the clock stopped')
        eq(hitmanView.clockStopped, nil, 'the operative\'s card says the clock stopped')
        eq(targetView.timeLeft, targetBefore.timeLeft, 'the target\'s band moved at the hold')
        eq(hitmanView.timeLeft, hitmanBefore.timeLeft, 'the operative\'s band moved at the hold')
        eq(hitmanView.creatorAnonymous, hitmanBefore.creatorAnonymous)
        eq(hitmanView.creatorName, hitmanBefore.creatorName, 'the hold changed how the client is named')
        for key in pairs(targetView) do
            truthy(targetBefore[key] ~= nil or key == 'onHold', 'a new key on the target\'s card: ' .. key)
        end
        for key, value in pairs(hitmanView) do
            truthy(hitmanBefore[key] ~= nil or key == 'onHold',
                'a new key on the operative\'s card: ' .. key)
            if type(value) == 'string' then
                falsy(value:find('CREATOR1', 1, true) or value:find('Marlowe', 1, true), 'names the client')
            end
        end
        for _, role in ipairs({ 'common', 'creator', 'hitman', 'target' }) do
            local allowed = s.projection.ALLOWED_KEYS[role]
            for key in pairs(hitmanView) do
                if role == 'common' and not allowed[key] then
                    truthy(s.projection.ALLOWED_KEYS.hitman[key], 'a key nobody may send: ' .. key)
                end
            end
        end
    end)

    it('staff without the identity ACE are not shown that an anonymous party is the frozen one', function()
        local _, s = boot('memory')
        local f = people(s)
        local c = place(s, f.creator, 'TARGET01', { anonymous = true })
        truthy(s.contracts.accept(f.hitman, c.id), 'taken')
        truthy(ask(6, 'freeze', { subject = 1, reason = 'dispute' }).ok, 'the anonymous placer frozen')

        local function rowOf(src)
            local reply = ask(src, 'contracts', {})
            truthy(reply and reply.ok, 'listed')
            for _, row in ipairs(reply.data.rows) do if row.id == c.id then return row end end
        end
        eq(rowOf(6).frozen, nil, 'the list badged a contract whose only frozen party is anonymous')
        eq(rowOf(8).frozen, true, 'with the identity ACE the badge is there')
        local view = ask(6, 'contract', { id = c.id })
        eq(view.data.frozen, nil, 'the contract view said its anonymous client is frozen')
        local seen = ask(8, 'contract', { id = c.id })
        eq(seen.data.frozen and seen.data.frozen[1], 'the client', 'with the identity ACE, which party')

        -- A visible party frozen is shown to every reader.
        truthy(ask(6, 'freeze', { subject = 2, reason = 'also' }).ok, 'the target frozen')
        eq(rowOf(6).frozen, true, 'the target frozen and no badge')
        local both = ask(6, 'contract', { id = c.id })
        eq(#both.data.frozen, 1, 'the anonymous client listed beside the target')
        eq(both.data.frozen[1], 'the target')

        -- The target's lookup, without the ACE, badges nothing through the client.
        truthy(ask(6, 'unfreeze', { subject = 2 }).ok, 'the target released')
        local lookup = ask(6, 'player', { subject = 2 })
        truthy(lookup and lookup.ok, 'looked up')
        eq(lookup.data.frozen, nil, 'the target read as frozen')
        for _, row in ipairs(lookup.data.contracts) do
            eq(row.frozen, nil, 'the target\'s contract badged through its anonymous client')
        end

        local overview = ask(6, 'overview', {})
        eq(overview.data.frozen.players, 1, 'the overview counts frozen players')
        local list = ask(7, 'frozen', {})
        truthy(list and list.ok, 'a reader may see the list')
        eq(#list.data.rows, 1)
        eq(list.data.rows[1].cid, nil, 'a citizen id shown without the identity ACE')
        eq(list.data.rows[1].name, 'Vic Marlowe')
    end)
end)

describe('who may freeze', function()
    it('a player without the ACE, and a reader, are refused, and nothing is frozen', function()
        local _, s = boot('memory')
        people(s)
        for _, src in ipairs({ 3, 7 }) do
            local reply = ask(src, 'freeze', { subject = 2, reason = 'x' })
            falsy(reply and reply.ok, src .. ': froze without the write ACE')
            eq(reply and reply.err, 'not_allowed', tostring(src))
            local undo = ask(src, 'unfreeze', { subject = 2 })
            eq(undo and undo.err, 'not_allowed', tostring(src))
        end
        eq(s.freeze.count(), 0, 'somebody was frozen')
        eq(#stored(s, 'freeze_player'), 0, 'a refused freeze was recorded as one')
        local noReason = ask(6, 'freeze', { subject = 2 })
        falsy(noReason.ok, 'frozen without a reason')
        eq(s.freeze.count(), 0)
    end)
end)

describe('the record', function()
    it('freeze_player and unfreeze_player, with the staff member, the player and the reason', function()
        local _, s = boot('memory')
        people(s)
        truthy(ask(6, 'freeze', { subject = 'TARGET01', reason = 'RP dispute' }).ok, 'frozen')
        local again = ask(6, 'freeze', { subject = 'TARGET01', reason = 'twice' })
        eq(again.err, 'already_frozen')
        truthy(ask(6, 'unfreeze', { subject = 'TARGET01', reason = 'resolved' }).ok, 'unfrozen')
        local frozenRows, releasedRows = stored(s, 'freeze_player'), stored(s, 'unfreeze_player')
        eq(#frozenRows, 1, 'one freeze recorded')
        eq(#releasedRows, 1, 'one release recorded')
        eq(frozenRows[1].actor_cid, 'ADMIN001')
        eq(frozenRows[1].detail.subject, 'TARGET01')
        eq(frozenRows[1].detail.reason, 'RP dispute')
        eq(releasedRows[1].actor_cid, 'ADMIN001')
        eq(releasedRows[1].detail.subject, 'TARGET01')
        eq(releasedRows[1].detail.reason, 'resolved')
    end)
end)
