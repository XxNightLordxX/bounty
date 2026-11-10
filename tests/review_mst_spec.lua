--- Review of 0f04d55 / b2e8a41 / a1e7da9 (review-mst): each test here
--- failed on the code before its fix. The UI halves (the accept echo, and
--- Cancel and place again) are in tests/ui/run.js.
---
---   F1  Reset, Exempt and a job-wide Reset wiped the immunity a target paid
---       a buyout for (Config.Immunity.AfterBailoutSeconds).
---   F2  a job override was read off the primary job alone: switching the
---       active job to a second one stepped round it.
---   F3  the day and week caps counted contracts withdrawn, or left to run
---       out, before anybody took them: a free shield.
---   F4  accepting carried no echo of the completion rule, the anonymity
---       flag or the buyout the card showed.
---   F5  /cleanse bought at whatever the price was now, not the one listed.
---   L1  the completion wait's hours were the override's, which said one
---       was there.
---   L2  a plain Reset said "they may be named again now" with a staff
---       extension still holding them.
---   L4  decay counted the time it was off before a contract's first step,
---       and markOn cleared its memory before a write that could fail.

local IMP = require('tests.harness.improvements')

--------------------------------------------------------------------------
-- Shared helpers
--------------------------------------------------------------------------

local function staff(s)
    Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
        firstname = 'Sam', lastname = 'Steward' })
    Env.addPlayer({ source = 9, citizenid = 'MODER001', license = 'license:MODER001',
        firstname = 'Mo', lastname = 'Derate' })
    Env.aces[6] = { ['crimson.admin'] = true }
    Env.aces[9] = { ['crimson.moderator'] = true }
    Config.Cooldowns.admin = { per = 10, burst = 1000 }
    Config.Cooldowns.adminWrite = { per = 10, burst = 1000 }
    if s.bridges and s.bridges.install then s.bridges.install(s) end
end

local function placers()
    Env.addPlayer({ source = 4, citizenid = 'PLACER04', license = 'license:p04', cash = 100000,
        bank = 100000, firstname = 'Pat', lastname = 'Four' })
    Env.addPlayer({ source = 5, citizenid = 'PLACER05', license = 'license:p05', cash = 100000,
        bank = 100000, firstname = 'Pia', lastname = 'Five' })
end

local function world(overrides)
    local s = newStack()
    Config.Notifications.ParanoidAlertJitter = { min = 0, max = 0 }
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

local function call(name, src, payload)
    local handler = Env.events['crimson-hitman:' .. name]
    if not handler then return { ok = false, err = 'NO SUCH HANDLER' } end
    Env.clientEvents = {}
    _G.source = src
    local fired, err = pcall(handler, payload or {})
    _G.source = nil
    if not fired then return { ok = false, err = 'THREW: ' .. tostring(err) } end
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:result' then return event.args[1] end
    end
    return nil
end

local function lookedUp(src, subject)
    local reply = ask(src, 'targetStatus', { subject = subject })
    truthy(reply and reply.ok, 'looked up ' .. tostring(subject) .. ': ' .. tostring(reply and reply.message))
    return reply.data.player.ref, reply.data.status
end

local function place(s, src, extra)
    local req = { targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                  reward = { baseline = { cash = 1000 } } }
    for k, v in pairs(extra or {}) do req[k] = v end
    return s.contracts.create(s.identity.resolve(src), req)
end

local function bank(src) return Env.players[src].PlayerData.money.bank end

--- A contract on the target, bought out by them.
local function boughtOut(s, f)
    Env.players[2].PlayerData.money.bank = 200000
    local c = assert(place(s, 1, { bailoutAmount = 1000 }), 'placed')
    local ok, err = s.bailout.buy(f.target, c.id)
    truthy(ok, 'bought out: ' .. tostring(err))
    eq(s.storage.readContract(c.id).state, CH.STATE.BAILED_OUT)
    return c
end

--------------------------------------------------------------------------
-- F1: a buyout's immunity is the target's, whatever staff reset
--------------------------------------------------------------------------

describe('review-mst F1: the immunity a buyout paid for survives Reset, Exempt and a job Reset', function()
    it('a plain Reset leaves it, and says so', function()
        local s, f = world()
        boughtOut(s, f)
        Env.advance(60)
        local ref = lookedUp(9, 2)
        local reply = ask(9, 'targetReset', { ref = ref, reason = 'ticket' })
        truthy(reply.ok, tostring(reply.message))
        local c, err = place(s, 4)
        eq(c, nil, 'placed on a target 60 s after they paid for an hour')
        eq(err, CH.ERR.TARGET_RECENTLY_ON)
        truthy(tostring(reply.message):find('buyout', 1, true), 'the reply names the buyout: ' .. reply.message)
    end)

    it('Exempt leaves it, and the card still shows it as the rule', function()
        local s, f = world()
        boughtOut(s, f)
        Env.advance(60)
        local ref = lookedUp(9, 2)
        local reply = ask(9, 'targetOverride', { ref = ref, reason = 'event', exempt = true, hours = 1 })
        truthy(reply.ok)
        eq(select(2, place(s, 4)), CH.ERR.TARGET_RECENTLY_ON, 'exempt wiped the buyout immunity')
        truthy(tostring(reply.message):find('buyout', 1, true), reply.message)
        local _, st = lookedUp(9, 2)
        eq(st.cooldownRule, 'Immunity.AfterBailoutSeconds')
        truthy(st.cooldownLeft > 3400, 'the immunity left: ' .. tostring(st.cooldownLeft))
        truthy(st.buyoutLeft and st.buyoutLeft > 3400, 'the card says how long the buyout holds')
    end)

    it('a job-wide Reset, even Reset all, leaves every member\'s', function()
        local s, f = world({ targetJob = { name = 'mechanic', type = 'none' } })
        boughtOut(s, f)
        Env.advance(60)
        local reply = ask(9, 'targetJobAction', { job = 'mechanic', action = 'reset', all = true, reason = 'x' })
        truthy(reply.ok, tostring(reply.message))
        eq(select(2, place(s, 4)), CH.ERR.TARGET_RECENTLY_ON, 'one job action lifted every member\'s immunity')
        truthy(tostring(reply.message):find('buyout', 1, true), reply.message)
    end)

    it('only a staff Reset all on the player lifts it', function()
        local s, f = world()
        boughtOut(s, f)
        Env.advance(60)
        local ref = lookedUp(9, 2)
        local reply = ask(9, 'targetReset', { ref = ref, reason = 'ticket', all = true })
        truthy(reply.ok)
        truthy(place(s, 4), 'Reset all lifts it')
        truthy(tostring(reply.message):find('buyout', 1, true), reply.message)
    end)
end)

--------------------------------------------------------------------------
-- F2: held jobs' overrides apply, the strictest winning
--------------------------------------------------------------------------

describe('review-mst F2: an override on a job they hold applies, the strictest winning', function()
    local function heldPolice()
        local s, f = world({ targetJob = { name = 'mechanic', type = 'none' } })
        Env.players[2].PlayerData.jobs = { mechanic = 0, police = 0 }
        truthy(ask(6, 'targetJobSet', { job = 'police', limits = {
            TargetCooldownAfterResolveSeconds = 86400, MaxActiveContractsPerTarget = 3 } }).ok)
        truthy(ask(6, 'targetJobSet', { job = 'mechanic', limits = {
            TargetCooldownAfterResolveSeconds = 3600, MaxActiveContractsPerTarget = 1 } }).ok)
        return s, f
    end

    it('placing applies the strictest of primary and held jobs, limit by limit', function()
        local s, f = heldPolice()
        local c = assert(place(s, 1))
        eq(select(2, place(s, 4)), CH.ERR.TARGET_HAS_ENOUGH, 'the mechanic cap of 1 is the stricter')
        truthy(s.contracts.accept(f.hitman, c.id, false))
        truthy(s.contracts.resolve(c.id, CH.STATE.EXPIRED, 'CREATOR1', nil, 'expired'))
        Env.advance(3600 + 5)
        local again, err = place(s, 4)
        eq(again, nil, 'the held police wait of 24 h was stepped round by being a mechanic')
        eq(err, CH.ERR.TARGET_RECENTLY_ON)
    end)

    it('the status card reads the same rule', function()
        local s, f = heldPolice()
        local c = assert(place(s, 1))
        truthy(s.contracts.accept(f.hitman, c.id, false))
        truthy(s.contracts.resolve(c.id, CH.STATE.EXPIRED, 'CREATOR1', nil, 'expired'))
        Env.advance(600)
        local _, st = lookedUp(9, 2)
        eq(st.limits.TargetCooldownAfterResolveSeconds, 86400)
        eq(st.limits.MaxActiveContractsPerTarget, 1)
        eq(st.cooldownFrom, 'job')
        eq(st.cooldownLeft, 86400 - 600)
        truthy(st.jobOverride == 'police' or st.jobOverride == 'mechanic', tostring(st.jobOverride))
        local held = false
        for _, j in ipairs(st.jobs or {}) do if j == 'police' then held = true end end
        truthy(held, 'the card lists the held job')
    end)

    it('a job action reaches a member who holds the job as a second one', function()
        heldPolice()
        local reply = ask(9, 'targetJobCount', { job = 'police' })
        truthy(reply.ok)
        eq(reply.data.count, 1, 'the online officer on a second job was left out')
    end)
end)

--------------------------------------------------------------------------
-- F3: untaken withdrawals do not fill the day and week caps
--------------------------------------------------------------------------

describe('review-mst F3: a contract withdrawn or run out untaken is not counted toward the caps', function()
    it('two friends placing and withdrawing at once shield nobody', function()
        local s = world()
        truthy(ask(6, 'setSetting', { key = 'Limits.MaxContractsPerTargetPerDay', value = 2 }).ok)
        for _, src in ipairs({ 4, 5 }) do
            local c = assert(place(s, src))
            truthy(s.contracts.cancel(s.identity.resolve(src), c.id))
        end
        local c, err = place(s, 1)
        truthy(c, 'a real placer was refused: ' .. tostring(err))
        local _, st = lookedUp(9, 2)
        eq(st.day, 1, 'the card counts only the one that holds a place')
    end)

    it('one a hitman took still counts', function()
        local s, f = world()
        truthy(ask(6, 'setSetting', { key = 'Limits.MaxContractsPerTargetPerDay', value = 1 }).ok)
        local c = assert(place(s, 4))
        truthy(s.contracts.accept(f.hitman, c.id, false))
        truthy(s.contracts.resolve(c.id, CH.STATE.CANCELLED, 'PLACER04', nil, 'cancelled'))
        Env.advance(Config.Limits.TargetCooldownAfterResolveSeconds + 1)
        eq(select(2, place(s, 1)), CH.ERR.TARGET_HAS_ENOUGH)
    end)
end)

--------------------------------------------------------------------------
-- F4: accepting echoes the terms the card showed
--------------------------------------------------------------------------

describe('review-mst F4: accept is refused when the rule, anonymity or buyout moved under the card', function()
    local function untaken()
        local s = newStack()
        Config.Notifications.ParanoidAlertJitter = { min = 0, max = 0 }
        Config.Completion.Fulfilment = 'either'
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 200000
        local c = assert(s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 10000 } }, bailoutAmount = 15000 }))
        local card = s.projection.contract(s.storage.readContract(c.id), 'HITMAN01')
        return s, f, c, card
    end

    local function accept(c, card, shown)
        local echo = { hitmanFee = 0, feeAccount = 'bank', fulfilment = card.fulfilment,
                       creatorAnonymous = card.creatorAnonymous == true }
        for k, v in pairs(shown or {}) do echo[k] = v end
        return call('accept', 3, { id = c.id, anonymous = false, penaltyAmount = card.penaltyAmount or 0,
            timeLeft = card.timeLeft, shown = echo })
    end

    it('the rule: either on the card, alive-only now', function()
        local s, f, c, card = untaken()
        eq(card.fulfilment, 'either')
        truthy(s.contracts.revise(f.creator, c.id, { fulfilment = 'alive' }))
        local r = accept(c, card)
        falsy(r and r.ok, 'accepted under a rule the card never showed')
        eq(r.err, CH.ERR.RULE_CHANGED)
        eq(r.data and r.data.fulfilment, 'alive')
        eq(s.storage.readHitman(c.id, 'HITMAN01'), nil, 'nothing written')
    end)

    it('anonymity: under a name on the card, anonymous now', function()
        local s, f, c, card = untaken()
        falsy(card.creatorAnonymous)
        truthy(s.contracts.revise(f.creator, c.id, { anonymous = true }))
        local r = accept(c, card)
        eq(r and r.err, CH.ERR.TERMS_CHANGED)
        eq(r.data and r.data.creatorAnonymous, true)
    end)

    it('the buyout, where the card carried one', function()
        local s, f, c, card = untaken()
        truthy(s.contracts.revise(f.creator, c.id, { bailoutAmount = 25000 }))
        local r = accept(c, card, { bailoutAmount = 15000 })
        eq(r and r.err, CH.ERR.TERMS_CHANGED)
        eq(r.data and r.data.bailoutAmount, 25000)
        -- And nothing about it to a card that never had it.
        local quiet = accept(c, card, { fulfilment = 'alive' })
        truthy(quiet == nil or quiet.data == nil or quiet.data.bailoutAmount == nil)
    end)

    it('the same terms accept as before', function()
        local _, _, c, card = untaken()
        local r = accept(c, card, { bailoutAmount = 15000 })
        truthy(r and r.ok, tostring(r and r.err))
    end)
end)

--------------------------------------------------------------------------
-- F5: /cleanse buys at the listed price
--------------------------------------------------------------------------

describe('review-mst F5: /cleanse charges the price it listed', function()
    local function listed()
        local s = newStack()
        Config.Notifications.ParanoidAlertJitter = { min = 0, max = 0 }
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 200000
        Env.players[2].PlayerData.money.bank = 200000
        local c = assert(s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 10000 } }, bailoutAmount = 10000 }))
        Env.commands = {}
        require('crimson-hitman.server.bridges').installBuyoutCommand(s)
        Env.advance(1)
        return s, f, c
    end
    local function run(args)
        Env.chat = {}
        Env.commands[Config.Bailout.Command](2, args)
        local said = ''
        for _, line in ipairs(Env.chat) do said = said .. line.text .. '\n' end
        return said
    end

    it('a price raised after the listing is not charged, and the new one is said', function()
        local s, f, c = listed()
        local list = run({})
        truthy(list:find('$10,000', 1, true), list)
        truthy(s.contracts.revise(f.creator, c.id, { bailoutAmount = 30000 }))
        local before = bank(2)
        local said = run({ c.id })
        eq(s.storage.readContract(c.id).state, CH.STATE.ACTIVE, 'charged a price never listed')
        eq(bank(2), before, 'nothing taken')
        truthy(said:find('$30,000', 1, true), said)
        -- Told it, they buy it at that figure.
        run({ c.id, '30000' })
        eq(s.storage.readContract(c.id).state, CH.STATE.BAILED_OUT)
        eq(before - bank(2), 30000)
    end)

    it('the price typed is the price charged', function()
        local s, f, c = listed()
        truthy(s.contracts.revise(f.creator, c.id, { bailoutAmount = 30000 }))
        local said = run({ c.id, '10000' })
        eq(s.storage.readContract(c.id).state, CH.STATE.ACTIVE)
        truthy(said:find('$30,000', 1, true), said)
    end)

    it('the listed price, unchanged, buys it as before', function()
        local s, _, c = listed()
        run({})
        run({ c.id })
        eq(s.storage.readContract(c.id).state, CH.STATE.BAILED_OUT)
    end)
end)

--------------------------------------------------------------------------
-- L1: the completion wait says no override's hours
--------------------------------------------------------------------------

describe('review-mst L1: the completion wait\'s hours are the global ones', function()
    it('says the global hours, then none, never the override\'s', function()
        local s, f = world({ targetJob = { name = 'mechanic', type = 'none' } })
        Config.Limits.TargetCooldownAfterCompletionSeconds = 24 * 3600
        truthy(ask(6, 'targetJobSet', { job = 'mechanic', limits = {
            TargetCooldownAfterCompletionSeconds = 47 * 3600 } }).ok)
        local c = assert(place(s, 1))
        truthy(s.contracts.accept(f.hitman, c.id, false))
        -- Completed, as the store records one (the completion path itself
        -- is tests/completion_spec.lua's).
        local row = s.storage.readContract(c.id)
        row.state, row.resolved_at = CH.STATE.COMPLETED, os.time()
        s.storage.writeContract(row)
        Env.advance(60)
        local none, err, refusal = place(s, 4)
        eq(none, nil)
        eq(err, CH.ERR.TARGET_RECENTLY_ON)
        eq(refusal and refusal.hours, 24, 'the hours said the job override')
        Env.advance(25 * 3600)
        local _, err2, refusal2 = place(s, 4)
        eq(err2, CH.ERR.TARGET_RECENTLY_ON)
        eq(refusal2, nil, 'past the global wait nothing more is said')
    end)
end)

--------------------------------------------------------------------------
-- L2: a plain Reset says an extension still holds
--------------------------------------------------------------------------

describe('review-mst L2: Reset says a staff extension still holds', function()
    it('names the extension, and Reset all as the way to clear it', function()
        local s = world()
        local ref = lookedUp(9, 2)
        truthy(ask(9, 'targetExtend', { ref = ref, reason = 'rp', minutes = 60 }).ok)
        local reply = ask(9, 'targetReset', { ref = ref, reason = 'ticket' })
        truthy(reply.ok)
        falsy(tostring(reply.message):find('may be named again now', 1, true), reply.message)
        truthy(tostring(reply.message):find('extension', 1, true), reply.message)
        eq(select(2, place(s, 4)), CH.ERR.TARGET_RECENTLY_ON, 'and it does')
    end)
end)

--------------------------------------------------------------------------
-- L4: decay
--------------------------------------------------------------------------

describe('review-mst L4: decay counts only time it was on, and keeps its marks till stored', function()
    local function setup()
        local s = newStack()
        local f = fixture(s, { creatorCash = 500000, creatorBank = 500000 })
        Config.Notifications.ParanoidAlert = false
        Config.Improvements.ContractDecay.Mode = 'rise'
        Config.Improvements.ContractDecay.Hours = 1
        return s, f
    end

    IMP.it('a contract placed while it was off waits a whole step from when it went on', function()
        local s, f = setup()
        Config.Improvements.ContractDecay.Enabled = false
        s.impBoard.tick()
        local c = assert(s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 10000 } } }))
        Env.advance(40 * 60); s.impBoard.tick()        -- 40 minutes with decay off
        Config.Improvements.ContractDecay.Enabled = true
        local before = bank(1)
        s.impBoard.tick()
        Env.advance(25 * 60); s.impBoard.tick()        -- 65 minutes since placing, 25 on
        eq(before - bank(1), 0, 'the 40 minutes off counted toward its first step')
        Env.advance(36 * 60); s.impBoard.tick()        -- 61 minutes on
        truthy(before - bank(1) > 0, 'a step once a whole hour on')
        truthy(c)
    end)

    IMP.it('markOn keeps a row marked off until the store has its change', function()
        local s, f = setup()
        Config.Improvements.ContractDecay.Enabled = true
        local c = assert(s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 10000 } } }))
        s.impBoard.tick()
        Env.advance(10 * 60); s.impBoard.tick()
        Config.Improvements.ContractDecay.Enabled = false
        s.impBoard.tick()
        local stored = function()
            for _, row in ipairs(s.storage.readRpRows('imp_decay') or {}) do
                if row.contract_id == c.id then return row end
            end
        end
        truthy(stored() and stored().off_since, 'marked off in the store')
        Env.advance(3 * 3600)
        Config.Improvements.ContractDecay.Enabled = true
        local write = s.storage.writeRpRow
        s.storage.writeRpRow = function(row)
            if row.kind == 'imp_decay' then error('store down', 0) end
            return write(row)
        end
        pcall(s.impBoard.tick)
        s.storage.writeRpRow = write
        -- The store still says off; so must memory, or the change is lost
        -- and the stretch is credited again from the store after a restart.
        truthy(stored().off_since, 'the store kept off_since')
        -- What the next pass works from: the module's own rows, read
        -- through the debug library rather than an export nothing else uses.
        local Decay = require('server.imp_decay')
        local kept
        for i = 1, 64 do
            local name, value = debug.getupvalue(Decay.tick, i)
            if not name then break end
            if name == 'rows' then kept = value end
        end
        truthy(kept, 'found the rows')
        truthy(kept[c.id] and kept[c.id].off_since,
            'memory cleared off_since before the write that failed')
        -- The next pass writes it once.
        local before = bank(1)
        s.impBoard.tick()
        falsy(stored().off_since, 'written on the next pass')
        Env.advance(45 * 60); s.impBoard.tick()
        eq(before - bank(1), 0, 'ten minutes before, forty-five after: not yet an hour on')
        Env.advance(6 * 60); s.impBoard.tick()
        truthy(before - bank(1) > 0, 'an hour on in all')
    end)
end)
