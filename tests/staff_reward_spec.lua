--- The admin panel's Change reward (rewardPreview, rewardChange) and
--- Reassign (reassignPreview, reassignHitman): server/staff_reward.lua and
--- server/staff_reassign.lua, through the panel's one way in.
---
--- What these hold: a raise is added by staff (taken from nobody, and handed
--- back to staff, never to the placer, by every ending that refunds the
--- placer) or charged to the placer; a cut owes the difference to whoever
--- funded each line, never below the least reward, never what is owed or
--- being paid; refused while a claim runs, a buyout waits or staff hold it;
--- money is conserved on memory, json and mysql (whatever staff add, less
--- whatever went back to them); a reassignment removes the operatives as
--- Remove operative does and puts the new hitman through every check of an
--- Accept, under the contract's key, so nobody takes it in between; the ACE
--- is asked every time; hostile payloads move nothing; nobody is named.

local Exec = require('tests.harness.mysql_exec')
local STAFF = 'staff'

local function money(src)
    local p = Env.players[src]
    if not p then return 0 end
    local m = p.PlayerData.money
    return m.cash + m.bank
end

--- Every dollar: pockets (cash, bank, dirty items) and escrow still held.
local function world(s)
    local total = 0
    for src in pairs(Env.players) do
        total = total + money(src)
        for _, e in ipairs(Env.players[src]._inventory or {}) do
            if e.name == Config.Sources.dirty.item then total = total + (e.count or 0) end
        end
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

--- What staff put in (every line taken from staff, splits included) and
--- what went back to them (settled to staff).
local function staffNet(s)
    local added, back = 0, 0
    for _, c in ipairs(s.storage.allContracts()) do
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.taken_from == STAFF then added = added + (line.amount or 0) end
            if line.state == CH.ESCROW_STATE.SETTLED and line.settled_to == STAFF then
                back = back + (line.amount or 0)
            end
        end
    end
    -- A split of a staff line is counted in `added` beside the line it was
    -- cut from, which holds the rest: the two add to what staff put in.
    return added, back
end

local function conserved(s, before, label)
    local added, back = staffNet(s)
    truthy(back <= added, label .. ': more went back to staff than staff put in')
    eq(world(s), before + added - back, label .. ': money minted or destroyed')
end

local function people()
    Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
        cash = 5000, bank = 50000, firstname = 'Kit', lastname = 'Vane' })
    Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
        firstname = 'Sam', lastname = 'Steward' })
    Env.addPlayer({ source = 7, citizenid = 'READER01', license = 'license:READER01',
        firstname = 'Rae', lastname = 'Dent' })
    Env.addPlayer({ source = 10, citizenid = 'MODER001', license = 'license:MODER001',
        firstname = 'Mo', lastname = 'Derr' })
    Env.aces[6] = { ['crimson.admin'] = true }
    Env.aces[7] = { command = true }
    Env.aces[10] = { ['crimson.moderator'] = true }
    Config.Cooldowns.admin = { per = 10, burst = 500 }
    Config.Cooldowns.adminWrite = { per = 10, burst = 500 }
end

local function stack()
    local s = newStack()
    local f = fixture(s)
    people()
    s.bridges.install(s)
    f.hitman2 = s.identity.resolve(4)
    return s, f
end

local function ask(s, src, op, data)
    return s.panel.handle(src, { op = op, data = data or {}, __rid = 7 })
end

local function place(s, f, extra)
    local req = { targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
                  reward = { baseline = { cash = 5000 } } }
    for k, v in pairs(extra or {}) do req[k] = v end
    local c, err = s.contracts.create(f.creator, req)
    truthy(c, 'placed: ' .. tostring(err))
    return c
end

local function told(src, from)
    local out = {}
    for i = (from or 1), #Env.clientEvents do
        local e = Env.clientEvents[i]
        if (e.name == 'lb-phone:SendNotification' or e.name == 'crimson-hitman:notify')
            and e.target == src then
            local d = e.args and e.args[1] or {}
            out[#out + 1] = tostring(d.title) .. ': ' .. tostring(d.content or d.description)
        end
    end
    return table.concat(out, '\n')
end

local function reward(s, c) return s.escrow.moneyValue(c.id) end

local function lookedUp(s, subject)
    local reply = ask(s, 6, 'player', { subject = subject })
    truthy(reply and reply.ok, 'looked up: ' .. tostring(reply and reply.message))
    return reply.data.player.ref
end

local function claim(s, c, cid)
    return s.contracts.claimSlot(c.id, cid or 'HITMAN01', CH.FULFILMENT.KIDNAPPING,
        { fulfilment = CH.FULFILMENT.KIDNAPPING })
end

describe('Change reward: raising', function()
    it('adds a line by staff, takes nothing from the placer, and tells both sides who did it: staff', function()
        local s, f = stack()
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local before, placerBefore = world(s), money(1)
        local mark = #Env.clientEvents + 1
        local reply = ask(s, 6, 'rewardChange', { id = c.id, by = 2500, reason = 'ticket 7' })
        truthy(reply.ok, tostring(reply.message))
        eq(reward(s, c), 7500)
        eq(money(1), placerBefore, 'the placer paid nothing')
        local staffLines = 0
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.taken_from == STAFF then staffLines = staffLines + 1 end
        end
        eq(staffLines, 1, 'one line added by staff')
        conserved(s, before, 'raise')
        truthy(told(1, mark):find('Reward raised: Staff raised the reward', 1, true), told(1, mark))
        truthy(told(3, mark):find('Reward raised: Staff raised the reward on a contract you hold', 1, true),
            told(3, mark))
        falsy(told(1, mark):find('Sam', 1, true), 'staff are not named')
        falsy(told(3, mark):find('Vic', 1, true), 'the placer is not named to the hitman')
        s.audit.flush()
        eq(#s.storage.auditByAction('staff_reward_changed', 10), 1, 'audited')
    end)

    it('hands what staff added to the hitman who collects', function()
        local s, f = stack()
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local before = world(s)
        truthy(ask(s, 6, 'rewardChange', { id = c.id, by = 1000, reason = 'r' }).ok)
        local hitmanBefore = money(3)
        local ok, err = claim(s, c)
        truthy(ok, 'claimed: ' .. tostring(err))
        eq(money(3), hitmanBefore + 6000, 'reward and staff money paid')
        conserved(s, before, 'payout')
    end)

    it('hands it back to staff, never to the placer, when the placer cancels', function()
        local s, f = stack()
        local c = place(s, f)
        local placerBefore, before = money(1), world(s)
        truthy(ask(s, 6, 'rewardChange', { id = c.id, by = 3000, reason = 'r' }).ok)
        truthy(s.contracts.cancel(f.creator, c.id))
        eq(money(1), placerBefore + 5000, 'the placer gets their own back, and only that')
        local added, back = staffNet(s)
        eq(added, 3000)
        eq(back, 3000, 'it went back to staff')
        conserved(s, before, 'cancel')
    end)

    it('charges the placer when staff choose that, and refunds them on a cancel', function()
        local s, f = stack()
        local c = place(s, f)
        local bank, before = Env.players[1].PlayerData.money.bank, world(s)
        local reply = ask(s, 6, 'rewardChange', { id = c.id, by = 2000, from = 'placer', account = 'bank', reason = 'r' })
        truthy(reply.ok, tostring(reply.message))
        eq(Env.players[1].PlayerData.money.bank, bank - 2000)
        conserved(s, before, 'placer raise')
        truthy(s.contracts.cancel(f.creator, c.id))
        eq(Env.players[1].PlayerData.money.bank, bank, 'theirs came back')
        conserved(s, before, 'placer raise, cancelled')
    end)

    it('refuses to charge a placer who is away or short, taking nothing', function()
        local s, f = stack()
        local c = place(s, f)
        Env.players[1].PlayerData.money.bank = 10
        local before = world(s)
        eq(ask(s, 6, 'rewardChange', { id = c.id, by = 2000, from = 'placer', reason = 'r' }).err,
            CH.ERR.INSUFFICIENT)
        conserved(s, before, 'refused')
        Env.removePlayer(1)
        eq(ask(s, 6, 'rewardChange', { id = c.id, by = 2000, from = 'placer', reason = 'r' }).err, 'placer_away')
        eq(reward(s, c), 5000)
        eq(staffNet(s), 0, 'nothing added')
    end)

    it('keeps under the most a contract may hold and the most one change may move', function()
        local s, f = stack()
        local c = place(s, f)
        Config.MaxContractValue = 6000
        eq(ask(s, 6, 'rewardChange', { id = c.id, by = 2000, reason = 'r' }).err, 'too_much_value')
        Config.MaxContractValue = 1000000
        Config.Staff.RewardChangeMax = 1000
        eq(ask(s, 6, 'rewardChange', { id = c.id, by = 2000, reason = 'r' }).err, 'too_much')
        Config.Staff.RewardChangeMax = 0
        eq(ask(s, 6, 'rewardChange', { id = c.id, by = 10, reason = 'r' }).err, 'reward_change_off')
        eq(reward(s, c), 5000)
    end)
end)

describe('Change reward: lowering', function()
    it('takes what staff added off first, then refunds the placer the rest', function()
        local s, f = stack()
        local c = place(s, f)
        local before = world(s)
        truthy(ask(s, 6, 'rewardChange', { id = c.id, by = 1000, reason = 'r' }).ok)
        local placerBefore = money(1)
        local mark = #Env.clientEvents + 1
        local reply = ask(s, 6, 'rewardChange', { id = c.id, by = -2500, reason = 'too high' })
        truthy(reply.ok, tostring(reply.message))
        eq(reply.data.toStaff, 1000)
        eq(reply.data.toPlacer, 1500)
        eq(reward(s, c), 3500)
        eq(money(1), placerBefore + 1500, 'the placer got their part back')
        conserved(s, before, 'lower')
        truthy(told(1, mark):find('$1500 of what you put up came back to you', 1, true), told(1, mark))
    end)

    it('never goes below the least reward, nor takes the collection to nothing', function()
        local s, f = stack()
        local c = place(s, f)
        Config.Limits.MinContractReward = 1000
        eq(ask(s, 6, 'rewardChange', { id = c.id, by = -4500, reason = 'r' }).err, CH.ERR.REWARD_TOO_SMALL)
        Config.Limits.MinContractReward = 0
        eq(ask(s, 6, 'rewardChange', { id = c.id, by = -5000, reason = 'r' }).err, 'too_low')
        local preview = ask(s, 6, 'rewardPreview', { id = c.id, by = -100 })
        truthy(preview.ok)
        eq(preview.data.mostLower, 4999)
        eq(reward(s, c), 5000)
    end)

    it('re-clamps the stake the next hitman is quoted', function()
        local s, f = stack()
        local c = place(s, f, { penaltyAmount = 2000 })
        truthy(ask(s, 6, 'rewardChange', { id = c.id, by = -4500, reason = 'r' }).ok)
        truthy((s.storage.readContract(c.id).penalty_amount or 0) <= 1000, 'stake re-clamped to what it holds')
    end)

    it('queues the refund for a placer who is away', function()
        local s, f = stack()
        local c = place(s, f)
        Env.removePlayer(1)
        local before = world(s)
        local reply = ask(s, 6, 'rewardChange', { id = c.id, by = -1000, reason = 'r' })
        truthy(reply.ok)
        eq(reply.data.queued, 1000)
        conserved(s, before, 'queued')
        eq(#(s.storage.readPending('CREATOR1') or {}) > 0, true, 'waiting for them')
    end)
end)

describe('Change reward: refusals and races', function()
    it('refuses while a claim is paying it, a buyout waits, staff hold it, or it has ended', function()
        local s, f = stack()
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        s.escrow.holdClaim(c.id)
        eq(ask(s, 6, 'rewardChange', { id = c.id, by = 100, reason = 'r' }).err, 'claim_running')
        s.escrow.letClaim(c.id)
        -- The memory store hands back the stored row itself.
        s.storage.readContract(c.id).bailout_queued_at = os.time()
        eq(ask(s, 6, 'rewardChange', { id = c.id, by = -100, reason = 'r' }).err, 'buyout_queued')
        s.storage.readContract(c.id).bailout_queued_at = nil
        truthy(s.holds.freeze('ADMIN001', 'TARGET01', 'x'))
        eq(ask(s, 6, 'rewardChange', { id = c.id, by = 100, reason = 'r' }).err, CH.ERR.CONTRACT_FROZEN)
        truthy(s.holds.unfreeze('ADMIN001', 'TARGET01', 'x'))
        truthy(claim(s, c))
        eq(ask(s, 6, 'rewardChange', { id = c.id, by = 100, reason = 'r' }).err, CH.ERR.ALREADY_SETTLED)
        eq(ask(s, 6, 'rewardChange', { id = 'ctnothere1', by = 100, reason = 'r' }).err, CH.ERR.NOT_FOUND)
    end)

    it('a claim landing on the very raise pays the staff line with its collection', function()
        local s, f = stack()
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local before, hitmanBefore = world(s), money(3)
        local real = s.escrow.addStaffLine
        s.escrow.addStaffLine = function(...)
            local a, b, ids = real(...)
            truthy(claim(s, c), 'the claim in the await')
            return a, b, ids
        end
        local reply = ask(s, 6, 'rewardChange', { id = c.id, by = 1000, reason = 'r' })
        s.escrow.addStaffLine = real
        truthy(reply.ok, tostring(reply.message))
        eq(money(3), hitmanBefore + 6000, 'paid with its collection')
        conserved(s, before, 'raise vs claim')
    end)

    it('a cut leaves alone a line a claim has taken, and conserves', function()
        local s, f = stack()
        local c = place(s, f)
        local before = world(s)
        truthy(ask(s, 6, 'rewardChange', { id = c.id, by = 1000, reason = 'r' }).ok)
        local staffLine
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.taken_from == STAFF then staffLine = line end
        end
        s.storage.claimEscrowLine(staffLine.id, CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING)
        local reply = ask(s, 6, 'rewardChange', { id = c.id, by = -500, reason = 'r' })
        truthy(reply.ok, tostring(reply.message))
        eq(reply.data.toPlacer, 500, 'off the placer\'s line, the staff line being in a release')
        s.storage.claimEscrowLine(staffLine.id, CH.ESCROW_STATE.RELEASING, CH.ESCROW_STATE.HELD)
        conserved(s, before, 'cut vs claim')
    end)

    it('one change at a time per contract: an acceptance on the key is refused busy', function()
        local s, f = stack()
        local c = place(s, f)
        local real = s.escrow.addStaffLine
        local accepted, acceptErr
        s.escrow.addStaffLine = function(...)
            accepted, acceptErr = s.contracts.accept(f.hitman, c.id, false)
            return real(...)
        end
        truthy(ask(s, 6, 'rewardChange', { id = c.id, by = 1000, reason = 'r' }).ok)
        s.escrow.addStaffLine = real
        falsy(accepted)
        eq(acceptErr, CH.ERR.BUSY)
    end)

    it('asks the staff ACE every time: the moderator and the extra ACEs read and never change it', function()
        local s, f = stack()
        local c = place(s, f)
        for _, src in ipairs({ 7, 10, 3 }) do
            eq(ask(s, src, 'rewardChange', { id = c.id, by = 100, reason = 'r' }).err, 'not_allowed', 'src ' .. src)
        end
        truthy(ask(s, 7, 'rewardPreview', { id = c.id }).ok, 'an extra ACE previews')
        eq(ask(s, 3, 'rewardPreview', { id = c.id }).err, 'not_allowed')
        eq(reward(s, c), 5000)
    end)

    it('moves nothing on a hostile payload', function()
        local s, f = stack()
        local c = place(s, f)
        local before = world(s)
        local bad = {
            { id = c.id, by = 'lots', reason = 'r' }, { id = c.id, by = 1.5, reason = 'r' },
            { id = c.id, by = 0, reason = 'r' }, { id = c.id, by = 0 / 0, reason = 'r' },
            { id = c.id, by = math.huge, reason = 'r' }, { id = c.id, by = -math.huge, reason = 'r' },
            { id = c.id, by = 2 ^ 53, reason = 'r' }, { id = c.id, by = { 100 }, reason = 'r' },
            { id = c.id, by = 100 }, { id = c.id, by = 100, reason = '   ' },
            { id = c.id, by = 100, reason = 'r', from = 'target' },
            { id = c.id, by = 100, reason = 'r', account = 'dirty' },
            { id = 42, by = 100, reason = 'r' }, { id = '../../x', by = 100, reason = 'r' },
            { by = 100, reason = 'r' },
        }
        for i, data in ipairs(bad) do
            local reply = ask(s, 6, 'rewardChange', data)
            falsy(reply.ok, 'hostile payload ' .. i .. ' refused')
        end
        falsy(s.panel.handle(6, 'not a table').ok)
        eq(reward(s, c), 5000)
        eq(world(s), before)
    end)
end)

describe('Reassign', function()
    it('takes the operative off exactly as Remove does, and assigns the hitman looked up, stake waived', function()
        local s, f = stack()
        local c = place(s, f, { mode = CH.MODE.EXCLUSIVE, penaltyAmount = 1000 })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local ref = lookedUp(s, 4)
        local before, placerBefore, newBefore = world(s), money(1), money(4)
        local mark = #Env.clientEvents + 1
        local reply = ask(s, 6, 'reassignHitman', { id = c.id, ref = ref, reason = 'ticket 9' })
        truthy(reply.ok, tostring(reply.message))
        eq(s.storage.readHitman(c.id, 'HITMAN01').state, 'abandoned', 'taken off')
        eq(s.storage.readHitman(c.id, 'HITMAN02').state, 'active', 'assigned')
        eq(money(1), placerBefore + 1000, 'their stake went to the placer, as a walk-away hands it')
        eq(money(4), newBefore, 'no stake taken from the new hitman')
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED)
        conserved(s, before, 'reassign')
        truthy(told(4, mark):find('Contract assigned: Staff assigned you a contract', 1, true), told(4, mark))
        truthy(told(3, mark):find('Taken off a contract', 1, true), told(3, mark))
        truthy(told(1, mark):find('Contract reassigned: Staff gave your contract', 1, true), told(1, mark))
        for _, name in ipairs({ 'Kit', 'Vane', 'Rook', 'Sam' }) do
            falsy(told(1, mark):find(name .. ' ', 1, true) and name ~= 'Kit', 'nobody named ' .. name)
        end
        falsy(told(4, mark):find('Rook', 1, true), 'the new hitman is not told who was taken off')
        falsy(told(3, mark):find('Kit', 1, true), 'the old one is not told who replaced them')
        s.audit.flush()
        eq(#s.storage.auditByAction('staff_reassign_hitman', 10), 1, 'audited')
        eq(s.contracts.accept(f.hitman, c.id, false), false, 'barred from it again')
    end)

    it('charges the stake when Config.Staff.ReassignStake is charge', function()
        local s, f = stack()
        local c = place(s, f, { mode = CH.MODE.EXCLUSIVE, penaltyAmount = 1000 })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        Config.Staff.ReassignStake = 'charge'
        local before, newBefore = world(s), money(4)
        truthy(ask(s, 6, 'reassignHitman', { id = c.id, ref = lookedUp(s, 4), reason = 'r' }).ok)
        eq(money(4), newBefore - 1000, 'staked as on Accept')
        conserved(s, before, 'charged')
    end)

    it('puts the new hitman through every Accept check before anything moves', function()
        local s, f = stack()
        local c = place(s, f, { mode = CH.MODE.EXCLUSIVE, penaltyAmount = 1000 })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local before = world(s)
        eq(ask(s, 6, 'reassignHitman', { id = c.id, ref = lookedUp(s, 2), reason = 'r' }).err, CH.ERR.SELF_TARGET)
        eq(ask(s, 6, 'reassignHitman', { id = c.id, ref = lookedUp(s, 1), reason = 'r' }).err, CH.ERR.SELF_ACCEPT)
        eq(ask(s, 6, 'reassignHitman', { id = c.id, ref = lookedUp(s, 3), reason = 'r' }).err, 'already_on')
        Config.Limits.MaxAcceptedPerHitman = 0
        eq(ask(s, 6, 'reassignHitman', { id = c.id, ref = lookedUp(s, 4), reason = 'r' }).err,
            CH.ERR.LIMIT_REACHED, 'refused by Accept itself, before anybody is taken off (review-x F5)')
        Config.Limits.MaxAcceptedPerHitman = 3
        -- Every Accept check is asked before an exclusive contract is
        -- cleared, so nothing moved for any of these refusals.
        conserved(s, before, 'refusals')
    end)

    it('assigns first where there is room, so a refusal leaves everybody on it', function()
        local s, f = stack()
        local c = place(s, f, { penaltyAmount = 1000 })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        Config.Limits.MaxAcceptedPerHitman = 0
        eq(ask(s, 6, 'reassignHitman', { id = c.id, ref = lookedUp(s, 4), reason = 'r' }).err,
            CH.ERR.LIMIT_REACHED)
        eq(s.storage.readHitman(c.id, 'HITMAN01').state, 'active', 'still on it')
    end)

    it('holds the contract\'s key: nobody accepts it off the board in between', function()
        local s, f = stack()
        Env.addPlayer({ source = 5, citizenid = 'HITMAN03', license = 'license:eee', cash = 5000, bank = 50000 })
        local c = place(s, f, { mode = CH.MODE.EXCLUSIVE })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local real = s.staffContract.removeHitman
        local sneaked, why
        s.staffContract.removeHitman = function(...)
            local a, b, d = real(...)
            sneaked, why = s.contracts.accept(s.identity.resolve(5), c.id, false)
            return a, b, d
        end
        local reply = ask(s, 6, 'reassignHitman', { id = c.id, ref = lookedUp(s, 4), reason = 'r' })
        s.staffContract.removeHitman = real
        truthy(reply.ok, tostring(reply.message))
        falsy(sneaked)
        eq(why, CH.ERR.BUSY)
        eq(s.storage.readHitman(c.id, 'HITMAN02').state, 'active')
        eq(s.storage.readHitman(c.id, 'HITMAN03'), nil)
    end)

    it('refuses a frozen contract, a hitman not looked up, and a bad payload, moving nothing', function()
        local s, f = stack()
        local c = place(s, f, { mode = CH.MODE.EXCLUSIVE })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local ref = lookedUp(s, 4)
        for i, data in ipairs({ { id = c.id, reason = 'r' }, { id = c.id, subject = 'HITMAN02', reason = 'r' },
            { id = c.id, ref = ref }, { id = c.id, ref = ref, reason = 'r', block = 'no' },
            { id = c.id, ref = 'made-up', reason = 'r' }, { id = 1, ref = ref, reason = 'r' } }) do
            falsy(ask(s, 6, 'reassignHitman', data).ok, 'payload ' .. i)
        end
        truthy(s.holds.freeze('ADMIN001', 'TARGET01', 'x'))
        eq(ask(s, 6, 'reassignHitman', { id = c.id, ref = ref, reason = 'r' }).err, CH.ERR.CONTRACT_FROZEN)
        eq(s.storage.readHitman(c.id, 'HITMAN01').state, 'active')
        for _, src in ipairs({ 7, 10 }) do
            eq(ask(s, src, 'reassignHitman', { id = c.id, ref = ref, reason = 'r' }).err, 'not_allowed')
        end
        local preview = ask(s, 7, 'reassignPreview', { id = c.id })
        truthy(preview.ok)
        eq(preview.data.stakeWaived, true)
    end)
end)

--------------------------------------------------------------------------
-- The three backends
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
    Config.Limits.MaxActiveContractsPerTarget = 5
    Config.Limits.MaxActiveContractsPerCreator = 5
    local main = require('server.main')
    return main.start()
end

describe('Change reward and reassign, on every backend', function()
    for _, mode in ipairs({ 'memory', 'json', 'mysql' }) do
        it('conserves money through a raise, a cut, a reassignment, a payout and a cancel on ' .. mode, function()
            local s = boot(mode)
            local f = fixture(s)
            people()
            f.hitman2 = s.identity.resolve(4)
            local a = place(s, f, { mode = CH.MODE.EXCLUSIVE, penaltyAmount = 500 })
            Env.addPlayer({ source = 12, citizenid = 'TARGET02', license = 'license:t2',
                cash = 100, bank = 100, firstname = 'Lee', lastname = 'Hart' })
            local before = world(s)
            local b = place(s, f, { targetCid = 'TARGET02' })
            truthy(s.contracts.accept(f.hitman, a.id, false))
            truthy(ask(s, 6, 'rewardChange', { id = a.id, by = 2000, reason = 'r' }).ok, 'raise a')
            truthy(ask(s, 6, 'rewardChange', { id = a.id, by = -2500, reason = 'r' }).ok, 'cut a')
            truthy(ask(s, 6, 'rewardChange', { id = b.id, by = 1500, reason = 'r' }).ok, 'raise b')
            truthy(ask(s, 6, 'rewardChange', { id = b.id, by = 700, from = 'placer', reason = 'r' }).ok, 'charge b')
            local reply = ask(s, 6, 'reassignHitman', { id = a.id, ref = lookedUp(s, 4), reason = 'r' })
            truthy(reply.ok, tostring(reply.message))
            conserved(s, before, mode .. ' mid-way')
            truthy(claim(s, a, 'HITMAN02'), 'the new hitman collects')
            truthy(s.contracts.cancel(f.creator, b.id), 'b cancelled')
            conserved(s, before, mode .. ' at the end')
            local _, back = staffNet(s)
            eq(back, 3500, 'staff got back what they added to b, and the 2000 cut from a')
            for _, line in ipairs(s.storage.readEscrow(b.id)) do
                if line.taken_from == STAFF then eq(line.settled_to, STAFF, 'never to the placer') end
            end
        end)
    end
end)
