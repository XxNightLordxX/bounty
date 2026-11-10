--- The roleplay groups together: rpB's consequences (server/rp_consequences.lua)
--- and rpC's in-character features (server/rp_intent.lua,
--- server/rp_reputation.lua) hook the same claim and the same give, and
--- each must still do what it says with the other on.
---
---   * proof of intent and dirty money payouts: a held payout stays held
---     (neither the item nor cash is given while it holds), and once the hold
---     lifts, by proof or by time, it is handed over as the dirty money item
---     for exactly the figure; value is conserved throughout;
---   * reputation and witness heat: each counts witnesses by its own radius
---     from the server's positions, so a bystander close by both raises a
---     witness report and takes the witness-free bonus away, one between the
---     two radii raises the report and leaves the bonus, and nobody near
---     gives the bonus and no report;
---   * the burner phone and bodyguards: hiring a bodyguard is the target's
---     own act and is never gated, cancelling and moving the pin neither;
---     taking a guard job is, as any hire is, refused without the item and
---     with nothing changed.
---
--- Every test puts Config.Roleplay back as it found it (RP.it).

local it = require('tests.harness.roleplay').it

local function stack()
    local s = newStack()
    local f = fixture(s)
    Config.Limits.TargetCooldownAfterResolveSeconds = 0
    Config.Limits.SameCreatorSameTargetCooldownSeconds = 0
    Config.Immunity.PostRespawnSeconds = 0
    return s, f
end

--- A contract on Dana Reyes, by Vic Marlowe, taken by Rook Ash. `reward` as
--- contracts.create takes it.
local function place(s, f, reward)
    local c, err = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
        reward = reward,
    })
    truthy(c, 'placed: ' .. tostring(err))
    truthy(s.contracts.accept(f.hitman, c.id, false), 'accepted')
    Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
    Env.runTimers()
    return c
end

local function carried(src, name)
    local n = 0
    for _, e in ipairs(Env.players[src]._inventory or {}) do
        if e.name == name then n = n + (e.count or 0) end
    end
    return n
end

--- Every coin's value: pockets (cash, bank and black money, one a dollar) and
--- everything escrow still holds.
local function value(s)
    local total = 0
    for _, p in pairs(Env.players) do
        total = total + (p.PlayerData.money.cash or 0) + (p.PlayerData.money.bank or 0)
        for _, e in ipairs(p._inventory or {}) do
            if e.name == 'black_money' then total = total + (e.count or 0) end
        end
    end
    for _, c in ipairs(s.storage.allContracts()) do
        for _, line in ipairs(s.storage.readEscrow(c.id) or {}) do
            if CH.MONEY_SOURCES[line.source] and line.state ~= CH.ESCROW_STATE.SETTLED then
                total = total + (line.amount or 0) - (tonumber(line.deliver_arrived) or 0)
            end
        end
    end
    return total
end

local function audits(s, action, contractId)
    s.audit.flush()
    local n = 0
    for _, row in ipairs(s.storage.readAudit()) do
        if row.action == action and (contractId == nil or row.contract_id == contractId) then n = n + 1 end
    end
    return n
end

local function owedTo(s, c, cid)
    local owed = 0
    for _, line in ipairs(s.storage.readEscrow(c.id)) do
        if line.owed_to == cid and line.state == CH.ESCROW_STATE.HELD then owed = owed + line.amount end
    end
    return owed
end

local function witnessReports()
    local out = {}
    for _, sent in ipairs(Natives.calls.dispatch or {}) do
        if sent.caller == 'Witness' then out[#out + 1] = sent end
    end
    return out
end

--------------------------------------------------------------------------
-- Proof of intent with dirty money payouts
--------------------------------------------------------------------------

describe('proof of intent with dirty money payouts', function()
    local function on()
        Config.Roleplay.ProofOfIntent.Enabled = true
        Config.Roleplay.ProofOfIntent.MinMessages = 3
        Config.Roleplay.ProofOfIntent.HoldMaxMinutes = 60
        Config.Roleplay.DirtyPayouts.Enabled = true
        Config.Roleplay.DirtyPayouts.Item = 'black_money'
        Config.Roleplay.DirtyPayouts.Mode = 'count'
        Config.Roleplay.DirtyPayouts.Rate = 1
    end

    it('keeps a held payout held: no item, no cash, owed in escrow, through every retry', function()
        local s, f = stack()
        on()
        local before = value(s)
        local c = place(s, f, { slots = { { baseline = { cash = 2000 } }, { baseline = { cash = 2000 } } } })
        local cash, bank = Env.players[3].PlayerData.money.cash, Env.players[3].PlayerData.money.bank
        local ok, err, result = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        truthy(ok, tostring(err))
        truthy(result.intentHold, 'held for proof of intent')
        eq(carried(3, 'black_money'), 0, 'no dirty money while it holds')
        eq(Env.players[3].PlayerData.money.cash, cash, 'and no cash instead')
        eq(Env.players[3].PlayerData.money.bank, bank, 'nor bank')
        eq(owedTo(s, c, 'HITMAN01'), 2000, 'owed to the hitman in escrow')
        for _ = 1, 3 do
            Env.advance(30)
            s.escrow.retryPending('HITMAN01')
        end
        eq(carried(3, 'black_money'), 0, 'a retry gives nothing while it holds')
        eq(Env.players[3].PlayerData.money.cash, cash)
        eq(audits(s, 'escrow_paid_as_item', c.id), 0, 'nothing paid as the item yet')
        eq(value(s), before, 'value conserved while held')
    end)

    it('once proof is shown, hands it over as the dirty money item for exactly the figure', function()
        local s, f = stack()
        on()
        local before = value(s)
        local c = place(s, f, { slots = { { baseline = { cash = 1500, bank = 500 } },
                                          { baseline = { cash = 2000 } } } })
        local cash, bank = Env.players[3].PlayerData.money.cash, Env.players[3].PlayerData.money.bank
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        eq(carried(3, 'black_money'), 0, 'held')
        for i = 1, 3 do truthy(s.comms.send(f.hitman, c.id, nil, 'Message ' .. i), 'sent') end
        Env.advance(10)
        s.escrow.retryPending('HITMAN01')
        eq(carried(3, 'black_money'), 2000, 'cash and bank lines both paid as the item')
        eq(Env.players[3].PlayerData.money.cash, cash, 'no cash')
        eq(Env.players[3].PlayerData.money.bank, bank, 'no bank')
        eq(owedTo(s, c, 'HITMAN01'), 0, 'nothing owed any more')
        eq(s.rpIntent.count(), 0, 'the hold is gone')
        eq(audits(s, 'intent_hold_released', c.id), 1)
        truthy(audits(s, 'escrow_paid_as_item', c.id) >= 1, 'paid as the item, on the record')
        eq(value(s), before, 'value conserved')
    end)

    it('once the hold times out, hands it over as the item too, at the next try', function()
        local s, f = stack()
        on()
        local before = value(s)
        local c = place(s, f, { baseline = { cash = 3000 } })
        local cash = Env.players[3].PlayerData.money.cash
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        eq(carried(3, 'black_money'), 0, 'held')
        Env.advance(60 * 60)
        eq(s.rpIntent.sweep(), 1, 'released by the tick')
        s.escrow.retryPending('HITMAN01')
        eq(carried(3, 'black_money'), 3000, 'paid as the item')
        eq(Env.players[3].PlayerData.money.cash, cash, 'not as cash')
        eq(value(s), before, 'value conserved')
    end)

    it('turned off while held, it is handed over as the item, not as cash', function()
        local s, f = stack()
        on()
        local c = place(s, f, { baseline = { cash = 2500 } })
        local cash = Env.players[3].PlayerData.money.cash
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        eq(carried(3, 'black_money'), 0, 'held')
        Config.Roleplay.ProofOfIntent.Enabled = false
        s.escrow.retryPending('HITMAN01')
        eq(carried(3, 'black_money'), 2500, 'paid as the item')
        eq(Env.players[3].PlayerData.money.cash, cash, 'not as cash')
    end)
end)

--------------------------------------------------------------------------
-- Reputation with witness heat
--------------------------------------------------------------------------

describe('reputation with witness heat', function()
    --- Both on, every party standing at Legion Square, an officer far away to
    --- be told, and a bystander `at` metres east of the hitman (none if nil).
    local function scene(at)
        local s, f = stack()
        Config.Record.Reputation.Enabled = true
        Config.Record.Reputation.WitnessRadius = 50.0
        Config.Roleplay.WitnessHeat.Enabled = true
        Config.Roleplay.WitnessHeat.WitnessRadius = 60.0
        Config.Roleplay.WitnessHeat.MinWitnesses = 1
        Config.Roleplay.WitnessHeat.AlwaysAlert = false
        Env.players[3]._coords = { x = 195.0, y = -934.0, z = 30.0 }
        Env.players[2]._coords = { x = 196.0, y = -934.0, z = 30.0 }
        Env.players[1]._coords = { x = 194.0, y = -934.0, z = 30.0 }
        Env.addPlayer({ source = 5, citizenid = 'OFFICER1', license = 'license:eee',
            firstname = 'Otto', lastname = 'Beat', job = { name = 'police', type = 'leo', onduty = true },
            coords = { x = 3000.0, y = 3000.0, z = 0.0 } })
        if at then
            Env.addPlayer({ source = 4, citizenid = 'BYSTAND1', license = 'license:ddd',
                firstname = 'Bea', lastname = 'Stander', coords = { x = 195.0 + at, y = -934.0, z = 30.0 } })
        end
        local c = place(s, f, { baseline = { cash = 5000 } })
        Natives.calls.dispatch = {}
        local ok, err, result = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        truthy(ok, tostring(err))
        return s, c, result
    end

    it('a bystander close by raises a witness report and takes the witness-free bonus away', function()
        local _, _, result = scene(10.0)
        eq(#witnessReports(), 1, 'one witness report')
        truthy(result.reputation, 'a reputation factor')
        eq(result.reputation.factor, 0.5, 'the plain factor, no witness-free bonus')
        falsy(tostring(result.reputation.text):find('no witnesses', 1, true), result.reputation.text)
    end)

    it('nobody near: no witness report, and the witness-free bonus is given', function()
        local _, _, result = scene(nil)
        eq(#witnessReports(), 0, 'no witness report')
        eq(result.reputation.factor, 0.7, 'plain 0.5 + no witnesses 0.2')
        truthy(tostring(result.reputation.text):find('no witnesses +0.2', 1, true), result.reputation.text)
    end)

    it('each counts by its own radius: a bystander between the two is a witness to one only', function()
        -- 55 m: within witness heat's 60, outside reputation's 50.
        local _, _, result = scene(55.0)
        eq(#witnessReports(), 1, 'witness heat saw them')
        eq(result.reputation.factor, 0.7, 'reputation did not: the bonus stands')
    end)

    it('neither names the hitman: the report carries no name, the breakdown is the hitman\'s own', function()
        local s, c = scene(10.0)
        for _, report in ipairs(witnessReports()) do
            local text = table.concat({ tostring(report.message or ''), tostring(report.title or ''),
                tostring(report.description or '') }, ' ')
            falsy(text:find('Rook', 1, true), text)
            falsy(text:find('HITMAN01', 1, true), text)
        end
        eq(audits(s, 'rp_witness_alert', c.id), 1, 'the alert on the record, by count')
    end)
end)

--------------------------------------------------------------------------
-- The burner phone with bodyguards
--------------------------------------------------------------------------

describe('the burner phone with bodyguard contracts', function()
    --- Fire a net event as a client does, gate and rate limit and all.
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

    local function scene()
        local s, f = stack()
        local c = place(s, f, { baseline = { cash = 5000 } })
        Config.Roleplay.Protection.Enabled = true
        Config.Roleplay.BurnerPhone.Enabled = true
        Config.Roleplay.BurnerPhone.RequireToOpen = true
        s.bridges.install(s)
        Env.players[2].PlayerData.money.bank = 100000
        Env.addPlayer({ source = 4, citizenid = 'GUARD001', license = 'license:ddd', cash = 0, bank = 0,
            firstname = 'Gus', lastname = 'Ward' })
        -- Nobody carries a burner.
        for _, src in ipairs({ 1, 2, 3, 4 }) do Env.players[src]._inventory = {} end
        return s, f, c
    end

    it('lets a target with no burner hire, move the pin and cancel: their own acts', function()
        local s, _, c = scene()
        local posted = call('protectionPost', 2, { id = c.id, amount = 2000,
            account = Config.Roleplay.Protection.Account })
        truthy(posted and posted.ok, tostring(posted and posted.err))
        eq(Env.players[2].PlayerData.money.bank, 98000, 'the reward taken')
        local pinned = call('protectionPin', 2, { job = posted.data.job })
        truthy(pinned and pinned.ok, tostring(pinned and pinned.err))
        local cancelled = call('protectionCancel', 2, { job = posted.data.job })
        truthy(cancelled and cancelled.ok, tostring(cancelled and cancelled.err))
        eq(Env.players[2].PlayerData.money.bank, 100000, 'refunded')
        eq(audits(s, 'burner_missing'), 0, 'never refused for the burner')
    end)

    it('refuses a guard with no burner, changing nothing, and lets one with a burner take it', function()
        local s, _, c = scene()
        local posted = call('protectionPost', 2, { id = c.id, amount = 2000,
            account = Config.Roleplay.Protection.Account })
        truthy(posted and posted.ok, tostring(posted and posted.err))
        local job = posted.data.job
        local refused = call('protectionAccept', 4, { job = job, reward = 2000 })
        eq(refused and refused.err, CH.ERR.NEED_BURNER, 'taking a guard job needs the burner')
        eq(s.rpProtection.all()[1].state, 'open', 'the job still open')
        eq(audits(s, 'burner_missing'), 1, 'the refusal on the record')
        table.insert(Env.players[4]._inventory, { name = 'burner_phone', count = 1, slot = 40 })
        local taken = call('protectionAccept', 4, { job = job, reward = 2000 })
        truthy(taken and taken.ok, tostring(taken and taken.err))
        eq(s.rpProtection.all()[1].state, 'taken', 'taken once they carry one')
    end)

    it('with the burner off, takes a guard job with no item at all', function()
        local s, _, c = scene()
        Config.Roleplay.BurnerPhone.Enabled = false
        local posted = call('protectionPost', 2, { id = c.id, amount = 2000,
            account = Config.Roleplay.Protection.Account })
        local taken = call('protectionAccept', 4, { job = posted.data.job, reward = 2000 })
        truthy(taken and taken.ok, tostring(taken and taken.err))
        eq(audits(s, 'burner_missing'), 0)
    end)
end)

--------------------------------------------------------------------------
-- One area rule and one parser for both groups' area lists
--------------------------------------------------------------------------

describe('the area lists of witness heat and the rumours', function()
    it('take either form from the panel, and both features read both', function()
        local s = newStack()
        local function turn(key, value)
            local ok, err, why = s.settings.set(key, value, 'ADMIN001', 'ADMIN001')
            truthy(ok, ('%s: %s %s'):format(key, tostring(err), tostring(why)))
        end
        turn('Roleplay.WitnessHeat.Areas', { 'Pier@-1600,-1000', '300, 200, Vinewood' })
        turn('Intel.Rumours.Districts', { '0, 0, Downtown Core', 'Sandy Shores@1850,3700' })
        local Places = require('server.rp_places')
        for _, text in ipairs({ 'Pier@-1600,-1000', '300, 200, Vinewood', 'Sandy Shores@1850,3700' }) do
            truthy(Places.parseArea(text), text .. ' reads')
        end
        eq(s.rpConsequences.areaOf({ x = 290.0, y = 210.0 }), 'Vinewood', 'witness heat reads x, y, name')
        eq(s.rpConsequences.areaOf({ x = -1590.0, y = -990.0 }), 'Pier', 'and Name@x,y')
        for _, bad in ipairs({ 'nowhere', '1, 2', '@1,2', 'Somewhere@x,y', '1, 2, <b>' }) do
            falsy(s.settings.set('Roleplay.WitnessHeat.Areas', { bad }, 'ADMIN001', 'ADMIN001'), bad)
            falsy(s.settings.set('Intel.Rumours.Districts', { bad }, 'ADMIN001', 'ADMIN001'), bad)
        end
    end)
end)
