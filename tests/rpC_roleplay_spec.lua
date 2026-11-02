--- Roleplay, group rpC (README Roleplay features): proof of intent
--- (server/rp_intent.lua), reputation earned in character
--- (server/rp_reputation.lua), bodyguard contracts and the hit on the hitman
--- (server/rp_protection.lua).
---
--- Every feature ships off, and off changes nothing; on, each does what the
--- README says; a refusal charges nothing; money is conserved through every
--- path (players' cash and bank, plus what the escrow holds, plus what the
--- bodyguard jobs hold); permissions hold; nothing names a hidden party; and
--- each setting changes live from the admin panel.

--- Every test here puts Config.Roleplay back as it found it (the features
--- it turns on live), so no later spec sees them on, whatever the order.
local it = require('tests.harness.roleplay').it

local Exec = require('tests.harness.mysql_exec')

local HIT = 1

--- Every player's money together, what the contracts hold, and what the
--- bodyguard jobs hold.
local function total(s)
    local sum = 0
    for _, p in pairs(Env.players) do sum = sum + p.PlayerData.money.cash + p.PlayerData.money.bank end
    for _, c in ipairs(s.storage.allContracts()) do
        for _, line in ipairs(s.storage.readEscrow(c.id) or {}) do
            if CH.MONEY_SOURCES[line.source] and line.source ~= 'dirty'
                and line.state ~= CH.ESCROW_STATE.SETTLED then
                sum = sum + (line.amount or 0) - (tonumber(line.deliver_arrived) or 0)
            end
        end
    end
    return sum + s.rpProtection.held()
end

local function cash(src) return Env.players[src].PlayerData.money.cash end
local function bank(src) return Env.players[src].PlayerData.money.bank end

--- A contract on Dana Reyes (2), placed by Vic Marlowe (1), shown to her, and
--- taken by Rook Ash (3) unless `accept` is false. `slots` payouts.
local function setup(opts)
    opts = opts or {}
    local s = newStack()
    local f = fixture(s)
    local reward = { baseline = { cash = 5000 } }
    if opts.slots then
        reward = { slots = {} }
        for i = 1, opts.slots do reward.slots[i] = { baseline = { cash = 2000 } } end
    end
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE, reward = reward,
        anonymous = opts.anonCreator == true,
    })
    truthy(c, 'placed')
    if opts.accept ~= false then
        truthy(s.contracts.accept(f.hitman, c.id, opts.namedHitman ~= true), 'taken')
    end
    Env.players[2].PlayerData.money.bank = 100000
    Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
    Env.runTimers()
    return s, f, c
end

local function audits(s, action)
    s.audit.flush()
    local n = 0
    for _, row in ipairs(s.storage.readAudit()) do
        if row.action == action then n = n + 1 end
    end
    return n
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

local function notices(src)
    local out = {}
    for _, n in ipairs(Natives.calls.notifications) do
        if n.source == src or n.target == src or n.src == src then out[#out + 1] = tostring(n.content) end
    end
    return out
end

local function card(s, c, cid)
    return s.projection.contract(s.storage.readContract(c.id), cid)
end

--------------------------------------------------------------------------
-- As shipped
--------------------------------------------------------------------------

describe('rpC as shipped', function()
    it('ships every switch off', function()
        -- Read from the files: another spec may have turned one on live.
        local shipped = require('tests.harness.shipped').fromFile().Roleplay
        for _, name in ipairs({ 'ProofOfIntent', 'Reputation', 'Protection', 'HitOnHitman' }) do
            eq(shipped[name].Enabled, false, name .. ' ships off')
            eq(ConfigDefaults.Roleplay[name].Enabled, false, name .. ' ships off in defaults.lua')
        end
    end)

    it('changes nothing with every switch off: a payout arrives at once, no card key, no tab', function()
        local s, f, c = setup()
        for _, name in ipairs({ 'ProofOfIntent', 'Reputation', 'Protection', 'HitOnHitman' }) do
            Config.Roleplay[name].Enabled = false
        end
        local before = total(s)
        local ok, err, result = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        truthy(ok, tostring(err))
        eq(cash(3), 10000, 'paid at once')
        falsy(result.intentHold, 'nothing held')
        falsy(result.reputation, 'no reputation factor')
        eq(total(s), before, 'conserved')
        eq(s.rpIntent.count(), 0)
        eq(#s.storage.readRpRows('intent'), 0, 'nothing kept')
        local listing = s.projection.listing('BYSTAND1', 1)
        falsy(listing.settings.protection, 'no Protection tab')
        local again = select(1, setup())
        local target = again.projection.onMe('TARGET01')[1]
        falsy(target.protection or target.protectionOffer or target.counterTargets, 'nothing on On me')
    end)

    it('refuses every bodyguard request as feature_off, charging nothing', function()
        local s, f, c = setup()
        s.bridges.install(s)
        local before = bank(2)
        local r = call('protectionPost', 2, { id = c.id, amount = 2000, account = 'bank' })
        falsy(r.ok)
        eq(r.err, CH.ERR.FEATURE_OFF)
        eq(bank(2), before, 'nothing taken')
        eq(call('protectionAccept', 3, { job = 'prot00000001', reward = 2000 }).err, CH.ERR.FEATURE_OFF)
        local board = call('protectionBoard', 3, {})
        truthy(board.ok)
        eq(board.data.enabled, false)
    end)
end)

--------------------------------------------------------------------------
-- Proof of intent
--------------------------------------------------------------------------

describe('proof of intent', function()
    local function on(s)
        Config.Roleplay.ProofOfIntent.Enabled = true
        Config.Roleplay.ProofOfIntent.MinMessages = 3
        Config.Roleplay.ProofOfIntent.HoldMaxMinutes = 60
        return s
    end

    it('holds a payout with no proof, keeps it owed in escrow, and says what is missing', function()
        local s, f, c = setup({ slots = 2 })
        on(s)
        local before = total(s)
        local ok, err, result = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        truthy(ok, tostring(err))
        truthy(result.intentHold, 'held')
        truthy(tostring(result.intentHold.missing):find('3 more messages', 1, true), result.intentHold.missing)
        eq(cash(3), 5000, 'nothing given yet')
        eq(total(s), before, 'conserved: the money is in escrow')
        local owed = 0
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.owed_to == 'HITMAN01' and line.state == CH.ESCROW_STATE.HELD then owed = owed + line.amount end
        end
        eq(owed, 2000, 'owed to the hitman')
        local shown = card(s, c, 'HITMAN01').intentHold
        truthy(shown and shown.missing, 'the card says what is missing')
        falsy(card(s, c, 'CREATOR1').intentHold, 'never on the placer\'s card')
        eq(audits(s, 'intent_hold_started'), 1)
        -- The receipt says it is held, not that pockets are full.
        local _, body = s.notify.hitmanReceipt(s.storage.readContract(c.id), false, result)
        truthy(body:find('held until you show intent', 1, true), body)
        falsy(body:find('make room', 1, true), body)
        -- A retry gives nothing while it holds.
        s.escrow.retryPending('HITMAN01')
        eq(cash(3), 5000)
    end)

    it('releases it once the hitman has written enough to the client', function()
        local s, f, c = setup({ slots = 2 })
        on(s)
        local before = total(s)
        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        for i = 1, 3 do truthy(s.comms.send(f.hitman, c.id, nil, 'Message ' .. i), 'sent') end
        Env.advance(10)
        s.escrow.retryPending('HITMAN01')
        eq(cash(3), 7000, 'handed over')
        eq(total(s), before, 'conserved')
        eq(s.rpIntent.count(), 0)
        eq(audits(s, 'intent_hold_released'), 1)
        eq(#s.storage.readRpRows('intent'), 0, 'the kept row goes')
    end)

    it('releases it anyway after the hold time, at the next try, even while away', function()
        local s, f, c = setup()
        on(s)
        local before = total(s)
        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        eq(cash(3), 5000)
        Env.advance(60 * 60)
        eq(s.rpIntent.sweep(), 1, 'released by the tick')
        s.escrow.retryPending('HITMAN01')
        eq(cash(3), 10000, 'handed over')
        eq(total(s), before, 'conserved')
    end)

    it('holds nothing where proof was shown: messages first, a meeting point, a handover', function()
        local s, f, c = setup({ slots = 3 })
        on(s)
        for i = 1, 3 do s.comms.send(f.hitman, c.id, nil, 'Message ' .. i) end
        local _, _, first = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        falsy(first.intentHold, 'messages first')

        local s2, f2, c2 = setup()
        on(s2)
        s2.storage.setMeeting(c2.id, 10.0, 20.0, os.time(), os.time())
        local _, _, second = s2.contracts.claimSlot(c2.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        falsy(second.intentHold, 'a meeting point')
        eq(cash(3), 10000)

        local s3, f3, c3 = setup()
        on(s3)
        local _, _, third = s3.contracts.claimSlot(c3.id, 'HITMAN01', CH.FULFILMENT.KIDNAPPING)
        falsy(third.intentHold, 'a live handover')
    end)

    it('hands every held payout over once the switch is off', function()
        local s, f, c = setup()
        on(s)
        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        truthy(s.settings.set('Roleplay.ProofOfIntent.Enabled', false, 'ADMIN001', 'ADMIN001'))
        s.escrow.retryPending('HITMAN01')
        eq(cash(3), 10000)
    end)

    it('survives a restart: the hold is read back from the store', function()
        local s, f, c = setup()
        on(s)
        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        eq(#s.storage.readRpRows('intent'), 1)
        s.rpIntent.init({ storage = s.storage, audit = s.audit, notify = s.notify, escrow = s.escrow,
                          contracts = s.contracts, projection = s.projection })
        s.escrow.retryPending('HITMAN01')
        eq(cash(3), 5000, 'still held after the restart')
        eq(s.rpIntent.count(), 1)
    end)

    it('lists a held payout at the top of Mine, by Ref, after the contract is done', function()
        local s, f, c = setup()
        on(s)
        s.bridges.install(s)
        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        local mine = call('mine', 3, {})
        truthy(mine.ok)
        eq(#mine.data.intentHeld, 1)
        eq(mine.data.intentHeld[1].ref, c.id)
    end)
end)

--------------------------------------------------------------------------
-- Reputation
--------------------------------------------------------------------------

describe('reputation earned in character', function()
    local function awarding(fn)
        local awarded = {}
        local realExports = _G.exports
        _G.exports = setmetatable({}, {
            __index = function(_, resource)
                if resource ~= 'sc-blackmarket' then return realExports[resource] end
                return { AddTrust = function(_, cid, amount) awarded[#awarded + 1] = amount end }
            end,
        })
        local ok, err = pcall(fn)
        _G.exports = realExports
        if not ok then error(err, 0) end
        return awarded
    end

    it('off: the trust is what it always was', function()
        local s, f, c = setup()
        local awarded = awarding(function()
            s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        end)
        eq(awarded[1], Config.Progression.TrustPerElimination)
    end)

    it('on: a plain completion earns the base factor, and the breakdown says so', function()
        local s, f, c = setup()
        Config.Roleplay.Reputation.Enabled = true
        -- A bystander beside everybody (all stand at the origin): not witness-free.
        Env.addPlayer({ source = 4, citizenid = 'BYSTAND1', license = 'license:ddd',
            firstname = 'Bea', lastname = 'Stander' })
        local result
        local awarded = awarding(function()
            result = select(3, s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        end)
        eq(awarded[1], 5, '10 x 0.5')
        eq(result.reputation.factor, 0.5)
        local _, body = s.notify.hitmanReceipt(s.storage.readContract(c.id), false, result)
        truthy(body:find('Reputation x0.5 (plain 0.5)', 1, true), body)
    end)

    it('adds a bonus for the thread, a meeting point, a handover and no witnesses, to the cap', function()
        local s, f, c = setup()
        Config.Roleplay.Reputation.Enabled = true
        s.comms.send(f.hitman, c.id, nil, 'On my way')
        s.storage.setMeeting(c.id, 10.0, 20.0, os.time(), os.time())
        Env.players[3]._coords = { x = 5000.0, y = 5000.0, z = 0.0 }
        local result
        local awarded = awarding(function()
            result = select(3, s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.KIDNAPPING))
        end)
        -- 0.5 + 0.2 + 0.2 + 0.3 + 0.2 = 1.4, under the cap of 1.5.
        eq(result.reputation.factor, 1.4)
        eq(awarded[1], 28, '20 x 1.4')
        truthy(result.reputation.text:find('no witnesses +0.2', 1, true), result.reputation.text)

        local s2, f2, c2 = setup()
        Config.Roleplay.Reputation.Enabled = true
        Config.Roleplay.Reputation.MaxFactor = 0.6
        s2.comms.send(f2.hitman, c2.id, nil, 'On my way')
        local capped = select(3, s2.contracts.claimSlot(c2.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        eq(capped.reputation.factor, 0.6, 'capped')
    end)

    it('a witness close by takes the bonus away', function()
        local s, f, c = setup()
        Config.Roleplay.Reputation.Enabled = true
        Env.players[3]._coords = { x = 5000.0, y = 5000.0, z = 0.0 }
        Env.addPlayer({ source = 4, citizenid = 'BYSTAND1', license = 'license:ddd',
            firstname = 'Bea', lastname = 'Stander', coords = { x = 5010.0, y = 5000.0, z = 0.0 } })
        local result = select(3, s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        eq(result.reputation.factor, 0.5)
    end)
end)

--------------------------------------------------------------------------
-- Bodyguards
--------------------------------------------------------------------------

describe('bodyguard contracts', function()
    local function on(s)
        Config.Roleplay.Protection.Enabled = true
        s.bridges.install(s)
        Env.addPlayer({ source = 4, citizenid = 'GUARD001', license = 'license:ddd', cash = 0, bank = 0,
            firstname = 'Gus', lastname = 'Ward' })
        return s
    end

    local function post(src, c, amount, account)
        return call('protectionPost', src, { id = c.id, amount = amount or 2000,
            account = account or Config.Roleplay.Protection.Account })
    end

    it('posts a job: the reward taken at once, the pin where the target stands', function()
        local s, f, c = setup()
        on(s)
        Env.players[2]._coords = { x = 100.0, y = 200.0, z = 30.0 }
        local before = total(s)
        local r = post(2, c)
        truthy(r.ok, tostring(r.err))
        eq(bank(2), 98000, 'taken')
        eq(total(s), before, 'conserved: held by the job')
        eq(s.rpProtection.held(), 2000)
        local job = s.rpProtection.all()[1]
        eq(job.state, 'open')
        eq(job.pin.x, 100.0)
        local onMe = s.projection.onMe('TARGET01')[1]
        eq(onMe.protection.state, 'open')
        falsy(onMe.protectionOffer, 'no second offer')
        eq(audits(s, 'protection_taken'), 1)
    end)

    it('reads no contract on the tick while the job\'s contract is still running (the shared snapshot)', function()
        local s, _, c = setup()
        on(s)
        truthy(post(2, c).ok)
        local reads = 0
        local real = s.storage.readContract
        s.storage.readContract = function(...)
            reads = reads + 1
            return real(...)
        end
        local ok, err = pcall(function()
            for _ = 1, 5 do s.rpProtection.sweep() end
        end)
        s.storage.readContract = real
        truthy(ok, tostring(err))
        -- (Its settling once the contract ends is the tests below.)
        eq(reads, 0, 'its contract is in what is running: not read again')
    end)

    it('refuses, charging nothing: out of bounds, a changed account, short, not theirs, twice', function()
        local s, f, c = setup()
        on(s)
        local before = bank(2)
        eq(post(2, c, 10).err, CH.ERR.PROTECTION_AMOUNT)
        eq(post(2, c, 10 ^ 9).err, CH.ERR.PROTECTION_AMOUNT)
        eq(post(2, c, 2000, 'cash').err, CH.ERR.TERMS_CHANGED)
        eq(post(2, c, 2000.5).err, CH.ERR.INVALID_INPUT)
        eq(post(1, c).err, CH.ERR.NOT_FOUND, 'the placer is not the target')
        eq(post(3, c).err, CH.ERR.NOT_FOUND, 'nor the hitman')
        Env.players[2].PlayerData.money.bank = 100
        eq(post(2, c).err, CH.ERR.INSUFFICIENT)
        eq(bank(2), 100, 'nothing taken')
        eq(#s.storage.readRpRows('protection'), 0, 'no row left behind')
        Env.players[2].PlayerData.money.bank = before
        truthy(post(2, c).ok)
        eq(post(2, c).err, CH.ERR.PROTECTION_EXISTS)
        eq(bank(2), before - 2000, 'charged once')
    end)

    it('lists a job by its reward alone, to nobody on the contract, and lets one guard take it', function()
        local s, f, c = setup()
        on(s)
        local job = post(2, c).data.job
        for _, src in ipairs({ 1, 2, 3 }) do
            eq(#call('protectionBoard', src, {}).data.open, 0, 'not offered to ' .. src)
        end
        local board = call('protectionBoard', 4, {}).data
        eq(#board.open, 1)
        local keys = {}
        for k in pairs(board.open[1]) do keys[#keys + 1] = k end
        table.sort(keys)
        eq(table.concat(keys, ','), 'job,reward', 'the reward and its handle, nothing else')
        eq(call('protectionAccept', 3, { job = job, reward = 2000 }).err, CH.ERR.PROTECTION_PARTY)
        eq(call('protectionAccept', 1, { job = job, reward = 2000 }).err, CH.ERR.PROTECTION_PARTY)
        eq(call('protectionAccept', 2, { job = job, reward = 2000 }).err, CH.ERR.NOT_FOUND)
        eq(call('protectionAccept', 4, { job = job, reward = 9999 }).err, CH.ERR.TERMS_CHANGED)
        local taken = call('protectionAccept', 4, { job = job, reward = 2000 })
        truthy(taken.ok, tostring(taken.err))
        eq(taken.data.mine[1].targetName, 'Dana Reyes', 'the guard learns the target')
        Env.addPlayer({ source = 5, citizenid = 'GUARD002', license = 'license:eee',
            firstname = 'Gil', lastname = 'Two' })
        eq(call('protectionAccept', 5, { job = job, reward = 2000 }).err, CH.ERR.PROTECTION_TAKEN)
        local where = call('protectionWaypoint', 4, { job = job })
        truthy(where.ok and where.data.x, 'the guard gets the pin')
        falsy(call('protectionWaypoint', 5, { job = job }).ok, 'nobody else')
        falsy(call('protectionWaypoint', 3, { job = job }).ok, 'not the hitman')
        eq(call('protectionCancel', 2, { job = job }).err, CH.ERR.CONTRACT_TAKEN, 'taken: it stands')
    end)

    it('holds a guard to MaxJobsPerGuard', function()
        local s, f, c = setup()
        on(s)
        Config.Roleplay.Protection.MaxJobsPerGuard = 1
        local job = post(2, c).data.job
        truthy(call('protectionAccept', 4, { job = job, reward = 2000 }).ok)
        Env.addPlayer({ source = 5, citizenid = 'TARGET02', license = 'license:eee', bank = 100000,
            firstname = 'Tia', lastname = 'Two' })
        local c2 = s.contracts.create(f.creator, { targetCid = 'TARGET02', reason = 'Another debt',
            reward = { baseline = { cash = 5000 } } })
        truthy(c2, 'second contract')
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        local second = call('protectionPost', 5, { id = c2.id, amount = 2000, account = 'bank' })
        truthy(second.ok, tostring(second.err))
        eq(call('protectionAccept', 4, { job = second.data.job, reward = 2000 }).err, CH.ERR.PROTECTION_LIMIT)
    end)

    it('pays the guard all of it when the contract ends without a completion', function()
        local s, f, c = setup()
        on(s)
        local job = post(2, c).data.job
        call('protectionAccept', 4, { job = job, reward = 2000 })
        local before = total(s)
        s.contracts.abandon(f.hitman, c.id)
        truthy(s.contracts.cancel(f.creator, c.id), 'called off')
        s.rpProtection.sweep()
        eq(bank(4), 2000, 'the guard paid')
        eq(s.rpProtection.held(), 0)
        eq(total(s), before, 'conserved')
        eq(audits(s, 'protection_paid'), 1)
    end)

    it('splits it when the contract is carried out anyway', function()
        local s, f, c = setup()
        on(s)
        local job = post(2, c).data.job
        call('protectionAccept', 4, { job = job, reward = 2000 })
        local before = total(s)
        local targetBank = bank(2)
        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        s.rpProtection.sweep()
        eq(bank(4), 500, '25% to the guard')
        eq(bank(2), targetBank + 1500, 'the rest back')
        eq(total(s), before, 'conserved')
    end)

    it('gives it all back when nobody took it, when the target cancels, and when staff void', function()
        local s, f, c = setup()
        on(s)
        local before = bank(2)
        post(2, c)
        s.contracts.abandon(f.hitman, c.id)
        s.contracts.cancel(f.creator, c.id)
        s.rpProtection.sweep()
        eq(bank(2), before, 'nobody took it')

        local s2, f2, c2 = setup()
        on(s2)
        local before2 = bank(2)
        local job = post(2, c2).data.job
        local r = call('protectionCancel', 2, { job = job })
        truthy(r.ok, tostring(r.err))
        eq(bank(2), before2, 'cancelled')
        eq(call('protectionCancel', 2, { job = job }).err, CH.ERR.ALREADY_SETTLED, 'once')
        eq(bank(2), before2, 'not twice')
        falsy(call('protectionCancel', 4, { job = job }).ok, 'nobody else')

        local s3, f3, c3 = setup()
        on(s3)
        local before3 = bank(2)
        local job3 = post(2, c3).data.job
        call('protectionAccept', 4, { job = job3, reward = 2000 })
        s3.storage.compareSetContractState(c3.id, CH.STATE.ACCEPTED, CH.STATE.VOIDED)
        -- Ended by writing the state straight to the store, its escrow left
        -- held: a fixture no release produced, so not the resource's output
        -- for the invariant run (tests/invariants.lua).
        rawset(s3.storage, '__rawFixture', true)
        s3.rpProtection.sweep()
        eq(bank(2), before3, 'voided: back to the target')
        eq(bank(4), 0)
    end)

    it('owes a guard who is away, and pays them once they are back', function()
        local s, f, c = setup()
        on(s)
        local job = post(2, c).data.job
        call('protectionAccept', 4, { job = job, reward = 2000 })
        local before = total(s)
        local guard = Env.players[4]
        Env.players[4] = nil
        s.contracts.abandon(f.hitman, c.id)
        s.contracts.cancel(f.creator, c.id)
        s.rpProtection.sweep()
        eq(s.rpProtection.held(), 2000, 'still held, owed')
        Env.players[4] = guard
        s.rpProtection.sweep()
        eq(bank(4), 2000, 'paid on their return')
        eq(total(s), before - 0, 'conserved')
        eq(s.rpProtection.all()[1].state, 'settled')
    end)

    it('leaves a payment that raised and cannot be checked for staff, never paying twice', function()
        local s, f, c = setup()
        on(s)
        local job = post(2, c).data.job
        call('protectionAccept', 4, { job = job, reward = 2000 })
        local guard = Env.players[4]
        local add = guard.Functions.AddMoney
        guard.Functions.AddMoney = function(account, amount)
            add(account, amount / 2)
            error('half a payment')
        end
        s.contracts.abandon(f.hitman, c.id)
        s.contracts.cancel(f.creator, c.id)
        s.rpProtection.sweep()
        s.rpProtection.sweep()
        eq(bank(4), 1000, 'what arrived, once')
        eq(audits(s, 'protection_payout_unconfirmed'), 1)
        guard.Functions.AddMoney = add
    end)

    it('keeps its jobs across a restart, in every backend', function()
        local s, f, c = setup()
        on(s)
        local job = post(2, c).data.job
        s.rpProtection.init({ storage = s.storage, identity = s.identity, audit = s.audit, notify = s.notify,
                              app = s.app, informant = s.informant, projection = s.projection })
        eq(s.rpProtection.held(), 2000, 'read back')
        eq(s.rpProtection.all()[1].id, job)

        package.loaded['crimson-hitman.server.storage.json'] = nil
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        Natives.files = {}
        local jsonStore = require('crimson-hitman.server.storage.json')
        jsonStore.open()
        Exec.install(Natives)
        local mysqlStore = require('crimson-hitman.server.storage.mysql')
        mysqlStore.open()
        for _, store in ipairs({ s.storage, jsonStore, mysqlStore }) do
            store.writeRpRow({ id = 'prot-x', kind = 'protection', contract_id = 'ct00000001',
                               amount = 1500, state = 'open', pin = { x = 1.5, y = 2.0, z = 3.0 } })
            store.writeRpRow({ id = 'intent:x', kind = 'intent', contract_id = 'ct00000001',
                               hitman_cid = 'HITMAN01', since = 42 })
            local rows = store.readRpRows('protection')
            local found
            for _, row in ipairs(rows) do if row.id == 'prot-x' then found = row end end
            truthy(found, 'written and read')
            eq(found.amount, 1500)
            eq(found.pin.x, 1.5)
            eq(#store.readRpRows('intent') >= 1, true)
            store.deleteRpRow('prot-x')
            for _, row in ipairs(store.readRpRows('protection')) do
                truthy(row.id ~= 'prot-x', 'deleted')
            end
        end
        jsonStore.close()
        package.loaded['crimson-hitman.server.storage.json'] = nil
        local reopened = require('crimson-hitman.server.storage.json')
        reopened.open()
        eq(#reopened.readRpRows('intent'), 1, 'json: kept on disk')
    end)

    it('names neither the placer nor an operative to the guard, on any channel', function()
        local s, f, c = setup({ anonCreator = true })
        on(s)
        Env.clientEvents = {}
        local job = post(2, c).data.job
        call('protectionBoard', 4, {})
        call('protectionAccept', 4, { job = job, reward = 2000 })
        call('protectionWaypoint', 4, { job = job })
        call('mine', 4, {})
        call('list', 4, { page = 1 })
        s.contracts.abandon(f.hitman, c.id)
        s.contracts.cancel(f.creator, c.id)
        s.rpProtection.sweep()
        -- The contract itself is on the public board, which anybody reads;
        -- what a guard must never learn is who placed it or who is on it.
        local forbidden = { 'creator1', 'vic marlowe', 'hitman01', 'rook ash', 'license:aaa', 'license:ccc' }
        local reached = 0
        local function scan(value, out)
            if type(value) == 'string' then out[#out + 1] = value:lower()
            elseif type(value) == 'table' then
                for k, v in pairs(value) do scan(k, out); scan(v, out) end
            end
            return out
        end
        for _, event in ipairs(Env.clientEvents) do
            if event.target == 4 then
                reached = reached + 1
                for _, text in ipairs(scan(event.args, {})) do
                    for _, needle in ipairs(forbidden) do
                        falsy(text:find(needle, 1, true), needle .. ' reached the guard in ' .. text)
                    end
                end
            end
        end
        truthy(reached > 0, 'the guard was told things')
    end)

    it('changes live from the admin panel, held to the start-up checks', function()
        local s = setup()
        truthy(s.settings.set('Roleplay.Protection.Enabled', true, 'ADMIN001', 'ADMIN001'))
        eq(Config.Roleplay.Protection.Enabled, true)
        truthy(s.settings.set('Roleplay.Protection.MaxReward', 5000, 'ADMIN001', 'ADMIN001'))
        eq(Config.Roleplay.Protection.MaxReward, 5000)
        falsy(s.settings.set('Roleplay.Protection.MinReward', 6000, 'ADMIN001', 'ADMIN001'),
            'least above most is refused')
        falsy(s.settings.set('Roleplay.Protection.Account', 'dirty', 'ADMIN001', 'ADMIN001'))
        truthy(s.settings.set('Roleplay.Protection.Account', 'cash', 'ADMIN001', 'ADMIN001'))
        truthy(s.settings.set('Roleplay.ProofOfIntent.HoldMaxMinutes', 5, 'ADMIN001', 'ADMIN001'))
        eq(Config.Roleplay.ProofOfIntent.HoldMaxMinutes, 5)
        falsy(s.settings.set('Roleplay.Reputation.BaseFactor', 3, 'ADMIN001', 'ADMIN001'),
            'base above the cap is refused')
        truthy(s.settings.set('Roleplay.Reputation.MaxFactor', 3, 'ADMIN001', 'ADMIN001'))
        truthy(s.settings.set('Roleplay.HitOnHitman.Enabled', true, 'ADMIN001', 'ADMIN001'))
        for _, key in ipairs({ 'Roleplay.ProofOfIntent.Enabled', 'Roleplay.Reputation.Enabled',
                               'Roleplay.Protection.Enabled', 'Roleplay.HitOnHitman.Enabled' }) do
            local entry = s.settings.entry(key)
            truthy(entry, key .. ' is in the catalogue')
            eq(entry.category, 'features')
            truthy(tostring(entry.group):find('^Roleplay: '), entry.group)
        end
    end)
end)

--------------------------------------------------------------------------
-- The hit on the hitman
--------------------------------------------------------------------------

describe('the hit on the hitman', function()
    local function reveal(s, c)
        s.informant.setRandom(function() return HIT end)
        local pick
        for _, p in ipairs(card(s, c, 'TARGET01').informantPicks or {}) do
            if p.pick ~= 'placer' then pick = p.pick end
        end
        truthy(pick, 'an operative to ask about')
        local ok, err = s.informant.buy(s.identity.resolve(2), c.id,
            { cost = Config.Informant.Cost, account = Config.Informant.Account }, pick)
        truthy(ok, tostring(err))
    end

    it('off: nothing is offered, even with the operative named', function()
        local s, f, c = setup()
        reveal(s, c)
        falsy(card(s, c, 'TARGET01').counterTargets)
    end)

    it('on: offers the named operative, and the normal place flow takes the handle', function()
        local s, f, c = setup()
        Config.Roleplay.HitOnHitman.Enabled = true
        s.bridges.install(s)
        reveal(s, c)
        local offered = card(s, c, 'TARGET01').counterTargets
        truthy(offered and offered[1], 'offered')
        eq(offered[1].name, 'Rook Ash')
        falsy(tostring(offered[1].handle):find('HITMAN01', 1, true), 'a handle, not a citizen id')
        falsy(card(s, c, 'CREATOR1').counterTargets, 'never to anybody else')
        falsy(card(s, c, 'HITMAN01').counterTargets)
        local placed = call('create', 2, { target = offered[1].handle, reason = 'Payback for the hit',
            mode = CH.MODE.EXCLUSIVE, reward = { baseline = { bank = 2000 } }, shown = {} })
        truthy(placed and placed.ok, tostring(placed and placed.err))
        eq(s.storage.readContract(placed.data.id).target_cid, 'HITMAN01', 'on the operative')
    end)

    it('offers nobody found only by description', function()
        local s, f, c = setup()
        Config.Roleplay.HitOnHitman.Enabled = true
        Config.Informant.RevealMode = 'description'
        reveal(s, c)
        falsy(card(s, c, 'TARGET01').counterTargets)
    end)
end)
