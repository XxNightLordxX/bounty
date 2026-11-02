--- The roleplay consequences of a completion (server/rp_consequences.lua):
--- witness heat, EMS before re-listing, city news and dirty money payouts.
---
--- What these hold:
---   * off as shipped, each changes nothing: no report, no post, no hold on
---     re-listing, and payouts in the account they were taken from;
---   * witness heat counts only non-parties near the hitman, by the
---     server's positions, and names nobody: a phrase, a direction, an area
---     and, when asked, a position moved by up to FuzzMeters;
---   * EMS before re-listing refuses a new contract on a target killed on
---     one ("They are still recovering."), charging nothing, until they have
---     been up for TreatedMinutes (or a medic's revive, with RequireEMS), and
---     never past MaxHoldMinutes; it reads the kill back from the Ledger
---     after a restart;
---   * city news posts on Birdy, or fires its event, for whitelisted-job
---     targets (every one with AllTargets), naming the job, area and time;
---   * dirty money payouts hand the hitman the item for exactly the figure,
---     owe what does not fit, refund the placer as taken, and conserve the
---     value of every coin;
---   * every setting is changed from the panel, held to its rule, and only
---     by staff who may write.

--- Every test here puts Config.Roleplay back as it found it (the features
--- it turns on live), so no later spec sees them on, whatever the order.
local it = require('tests.harness.roleplay').it

local function stack(opts)
    opts = opts or {}
    local s = newStack()
    local f = fixture(s, { targetJob = opts.targetJob })
    Config.Limits.TargetCooldownAfterResolveSeconds = 0
    Config.Limits.SameCreatorSameTargetCooldownSeconds = 0
    Config.Amendments.CancelCooldownSeconds = 0
    Config.Immunity.PostRespawnSeconds = 0
    return s, f
end

local function place(s, f, reward)
    local c, err = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
        reward = reward or { baseline = { cash = 5000 }, bonus = { cash = 1000 } },
    })
    truthy(c, 'placed: ' .. tostring(err))
    truthy(s.contracts.accept(f.hitman, c.id, false), 'accepted')
    return c
end

local function witnessReports()
    local out = {}
    for _, sent in ipairs(Natives.calls.dispatch or {}) do
        if sent.caller == 'Witness' then out[#out + 1] = sent end
    end
    return out
end

local function carried(src, name)
    local n = 0
    for _, e in ipairs(Env.players[src]._inventory or {}) do
        if e.name == name then n = n + (e.count or 0) end
    end
    return n
end

--- Every coin's value: pockets (cash, bank, black money, and marked bills
--- by their worth) and everything escrow still owes.
local function value(s, rate)
    local total = 0
    for _, p in pairs(Env.players) do
        total = total + (p.PlayerData.money.cash or 0) + (p.PlayerData.money.bank or 0)
        for _, e in ipairs(p._inventory or {}) do
            if e.name == 'black_money' then total = total + (e.count or 0) / (rate or 1) end
            if e.name == 'markedbills' then total = total + (e.metadata and e.metadata.worth or 0) end
        end
    end
    for _, c in ipairs(s.storage.allContracts()) do
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if CH.MONEY_SOURCES[line.source] and line.state ~= CH.ESCROW_STATE.SETTLED then
                total = total + (line.amount or 0) - (tonumber(line.deliver_arrived) or 0)
                    - (tonumber(line.deliver_part) or 0) / (rate or 1)
            end
        end
    end
    return total
end

--- The same, counted in items of black money at `rate` a dollar, so a
--- part of a dollar is a whole number and nothing is compared as a float.
local function units(s, rate)
    local total = 0
    for _, p in pairs(Env.players) do
        total = total + ((p.PlayerData.money.cash or 0) + (p.PlayerData.money.bank or 0)) * rate
        for _, e in ipairs(p._inventory or {}) do
            if e.name == 'black_money' then total = total + (e.count or 0) end
        end
    end
    for _, c in ipairs(s.storage.allContracts()) do
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if CH.MONEY_SOURCES[line.source] and line.state ~= CH.ESCROW_STATE.SETTLED then
                local owed = (line.amount or 0) - (tonumber(line.deliver_arrived) or 0)
                total = total + owed * (line.source == 'dirty' and 1 or rate)
                    - (tonumber(line.deliver_part) or 0)
            end
        end
    end
    return total
end

local function retry(s)
    return s.contracts.create(s.identity.resolve(1), {
        targetCid = 'TARGET01', reason = 'Unpaid debt again', mode = CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = 2000 } },
    })
end

--------------------------------------------------------------------------
-- As shipped
--------------------------------------------------------------------------

describe('the roleplay consequences as shipped', function()
    it('ships every one off', function()
        -- Read from the file: another spec may have turned one on live.
        local shipped = require('tests.harness.shipped').fromFile()
        for _, name in ipairs({ 'WitnessHeat', 'EmsRelisting', 'CityNews', 'DirtyPayouts' }) do
            eq(shipped.Roleplay[name].Enabled, false, name)
            eq(ConfigDefaults.Roleplay[name].Enabled, false, name .. ' in defaults.lua')
        end
    end)

    it('changes nothing at a completion: no report, no post, no hold, paid in cash', function()
        local s, f = stack()
        Env.addPlayer({ source = 4, citizenid = 'BYSTAND1', firstname = 'Bea', lastname = 'Stander',
            coords = { x = 1.0, y = 0.0, z = 0.0 } })
        local c = place(s, f)
        local cash = Env.players[3].PlayerData.money.cash
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        eq(#witnessReports(), 0, 'no witness report')
        eq(#(Natives.calls.birdy or {}), 0, 'no post')
        eq(Env.players[3].PlayerData.money.cash - cash, 5000, 'paid in cash')
        eq(carried(3, 'black_money'), 0, 'no item')
        local again, err = retry(s)
        truthy(again, 'a new contract at once: ' .. tostring(err))
    end)
end)

--------------------------------------------------------------------------
-- Witness heat
--------------------------------------------------------------------------

describe('witness heat', function()
    local function scene(opts)
        opts = opts or {}
        local s, f = stack()
        Config.Roleplay.WitnessHeat.Enabled = true
        for k, v in pairs(opts.config or {}) do Config.Roleplay.WitnessHeat[k] = v end
        Env.players[3]._coords = { x = 195.0, y = -934.0, z = 30.0 }
        Env.players[2]._coords = { x = 196.0, y = -934.0, z = 30.0 }
        Env.players[1]._coords = { x = 194.0, y = -934.0, z = 30.0 }
        Env.addPlayer({ source = 5, citizenid = 'OFFICER1', firstname = 'Otto', lastname = 'Beat',
            job = { name = 'police', type = 'leo', onduty = true },
            coords = { x = 3000.0, y = 3000.0, z = 0.0 } })
        if opts.bystander ~= false then
            Env.addPlayer({ source = 4, citizenid = 'BYSTAND1', firstname = 'Bea', lastname = 'Stander',
                coords = opts.bystanderAt or { x = 205.0, y = -934.0, z = 30.0 } })
        end
        local c = place(s, f)
        return s, f, c
    end

    it('reports a completion seen by a bystander to sc-dispatch and to officers, naming nobody', function()
        local s, _, c = scene()
        Env.players[3]._heading = 90.0
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.KIDNAPPING))
        local reports = witnessReports()
        eq(#reports, 1, 'one report')
        local r = reports[1]
        eq(r.title, 'Witness report')
        eq(r.street, 'Legion Square')
        truthy(r.message:find('west', 1, true), 'facing west: ' .. r.message)
        truthy(r.message:find('Legion Square', 1, true), r.message)
        truthy(r.job_table[1], 'police jobs')
        for _, needle in ipairs({ 'Rook', 'Ash', 'HITMAN01', 'Vic', 'Marlowe', 'CREATOR1', 'Dana', 'Reyes' }) do
            falsy(r.message:find(needle, 1, true), 'names ' .. needle)
        end
        local told = false
        for _, event in ipairs(Env.clientEvents) do
            if event.target == 5 and event.name == 'lb-phone:SendNotification' then
                local data = event.args[1] or {}
                if tostring(data.title) == 'Witness report' then told = true end
            end
        end
        truthy(told, 'the officer was told on the phone')
    end)

    it('says where they ran when moving, and gives a position moved by at most the fuzz', function()
        local s, _, c = scene({ config = { FuzzMeters = 50.0 } })
        Env.players[3]._velocity = { x = 5.0, y = 0.0, z = 0.0 }
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        local r = witnessReports()[1]
        truthy(r and r.message:find('east', 1, true), r and r.message)
        local dx, dy = r.coords.x - 195.0, r.coords.y + 934.0
        truthy(dx * dx + dy * dy <= 50.1 * 50.1, 'within the fuzz')
    end)

    it('gives no position with SendCoords off', function()
        local s, _, c = scene({ config = { SendCoords = false } })
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        eq(witnessReports()[1].coords, nil)
    end)

    it('counts nobody who is a party, nobody out of range, and nobody in another bucket', function()
        local s, _, c = scene({ bystanderAt = { x = 400.0, y = -934.0, z = 30.0 } })
        Env.addPlayer({ source = 6, citizenid = 'INSIDE01', coords = { x = 196.0, y = -935.0, z = 30.0 } })
        Env.players[6]._bucket = 7
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        eq(#witnessReports(), 0, 'the placer and target beside him, and the instanced player, are no witnesses')
    end)

    it('waits for MinWitnesses, and AlwaysAlert reports regardless', function()
        local s, _, c = scene({ config = { MinWitnesses = 2 } })
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        eq(#witnessReports(), 0, 'one witness of two')
        local s2, _, c2 = scene({ bystander = false, config = { AlwaysAlert = true } })
        truthy(s2.contracts.claimSlot(c2.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        eq(#witnessReports(), 1, 'reported with nobody seeing it')
    end)

    it('degrades safely without sc-dispatch: the completion stands, officers are still told', function()
        local s, _, c = scene()
        Natives.resourceStates['sc-dispatch'] = 'missing'
        local cash = Env.players[3].PlayerData.money.cash
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.KIDNAPPING))
        eq(#witnessReports(), 0)
        truthy(Env.players[3].PlayerData.money.cash > cash, 'paid')
    end)
end)

--------------------------------------------------------------------------
-- EMS before re-listing
--------------------------------------------------------------------------

describe('EMS before re-listing', function()
    local function killed(config)
        local s, f = stack()
        Config.Roleplay.EmsRelisting.Enabled = true
        for k, v in pairs(config or {}) do Config.Roleplay.EmsRelisting[k] = v end
        local c = place(s, f)
        Env.players[2].PlayerData.metadata.isdead = true
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        return s, f, c
    end

    it('refuses a new contract on them while they are down, charging nothing', function()
        local s, f = killed()
        local before = Env.players[1].PlayerData.money.cash
        local again, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt again', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 2000 } },
        })
        falsy(again)
        eq(err, CH.ERR.TARGET_RECOVERING)
        eq(Env.players[1].PlayerData.money.cash, before, 'nothing taken')
    end)

    it('says so to the placer in the app\'s words', function()
        local app = read_file('crimson-hitman/ui/app.js')
        truthy(app:find("target_recovering: 'They are still recovering.", 1, true))
    end)

    it('lets them be listed once they have been up for TreatedMinutes', function()
        local s = killed({ TreatedMinutes = 10 })
        Env.players[2].PlayerData.metadata.isdead = false
        s.rpConsequences.tick()
        Env.advance(9 * 60)
        s.rpConsequences.tick()
        falsy(retry(s), 'nine minutes up')
        Env.advance(61)
        truthy(retry(s), 'ten minutes up')
    end)

    it('starts the count again when they go down again', function()
        local s = killed({ TreatedMinutes = 10 })
        Env.players[2].PlayerData.metadata.isdead = false
        s.rpConsequences.tick()
        Env.advance(8 * 60)
        Env.players[2].PlayerData.metadata.inlaststand = true
        s.rpConsequences.tick()
        Env.players[2].PlayerData.metadata.inlaststand = false
        s.rpConsequences.tick()
        Env.advance(5 * 60)
        falsy(retry(s), 'five minutes since they were last down')
    end)

    it('never holds past MaxHoldMinutes after the kill', function()
        local s = killed({ MaxHoldMinutes = 30 })
        Env.advance(31 * 60)
        truthy(retry(s), 'still dead, but the hold has run out')
    end)

    it('with RequireEMS, waits for a medic\'s revive rather than the minutes', function()
        local s = killed({ RequireEMS = true, TreatedMinutes = 1 })
        Env.players[2].PlayerData.metadata.isdead = false
        s.rpConsequences.tick()
        Env.advance(20 * 60)
        falsy(retry(s), 'got up alone')
        s.rpConsequences.noteMedicRevive(2)
        truthy(retry(s), 'a medic brought them back')
    end)

    it('hears the medic through sc-ambulance\'s own event, as the kill logic checks it', function()
        local s = killed({ RequireEMS = true })
        s.bridges.install(s)
        Env.addPlayer({ source = 9, citizenid = 'MEDIC001', job = { name = 'ambulance', type = 'ems', onduty = true },
            inventory = { { name = 'defibrillator', count = 1 } }, coords = { x = 0.5, y = 0.0, z = 0.0 } })
        Env.players[2]._coords = { x = 0.0, y = 0.0, z = 0.0 }
        _G.source = 9
        Env.events['sc-ambulance:server:UseDefib'](2)
        _G.source = nil
        Env.players[2].PlayerData.metadata.isdead = false
        truthy(retry(s), 'revived by an on-duty medic')
    end)

    it('does not hold after a handover', function()
        local s, f = stack()
        Config.Roleplay.EmsRelisting.Enabled = true
        local c = place(s, f)
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.KIDNAPPING))
        truthy(retry(s))
    end)

    it('reads the kill back from the Ledger after a restart', function()
        local s, f = stack()
        Config.Roleplay.EmsRelisting.Enabled = true
        local c = place(s, f)
        s.ledger.record(s.storage.readContract(c.id), 'HITMAN01', nil, CH.FULFILMENT.ELIMINATION)
        -- A restart: everything the module saw is gone.
        s.rpConsequences.init({ storage = s.storage, identity = s.identity, notify = s.notify,
            audit = s.audit, ledger = s.ledger, contracts = s.contracts, escrow = s.escrow })
        falsy(retry(s), 'held from the Ledger row')
    end)
end)

--------------------------------------------------------------------------
-- City news
--------------------------------------------------------------------------

describe('city news', function()
    it('posts on Birdy for a whitelisted-job target: job, area and time, nobody named', function()
        local s, f = stack({ targetJob = { name = 'police', type = 'leo', onduty = true } })
        Config.Roleplay.CityNews.Enabled = true
        Env.players[2]._coords = { x = 300.0, y = 200.0, z = 0.0 }
        local c = place(s, f)
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        local posts = Natives.calls.birdy or {}
        eq(#posts, 1)
        eq(posts[1].username, 'LSNews')
        truthy(posts[1].content:find('Vinewood', 1, true), posts[1].content)
        falsy(posts[1].content:find('{', 1, true), 'every placeholder filled')
        for _, needle in ipairs({ 'Dana', 'Reyes', 'Rook', 'Vic', 'HITMAN01', 'CREATOR1' }) do
            falsy(posts[1].content:find(needle, 1, true), 'names ' .. needle)
        end
    end)

    it('says nothing of a civilian unless AllTargets is on, and names them only with NameTarget', function()
        local s, f = stack()
        Config.Roleplay.CityNews.Enabled = true
        local c = place(s, f)
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        eq(#(Natives.calls.birdy or {}), 0)
        Config.Roleplay.CityNews.AllTargets = true
        Config.Roleplay.CityNews.NameTarget = true
        Config.Roleplay.CityNews.Templates = { '{name}, a {job}, was hit near {zone}.' }
        local c2 = place(s, f)
        truthy(s.contracts.claimSlot(c2.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        local post = (Natives.calls.birdy or {})[1]
        truthy(post and post.content:find('Dana Reyes, a resident', 1, true), post and post.content)
    end)

    it('fires its server event instead with App = event', function()
        local s, f = stack({ targetJob = { name = 'police', type = 'leo', onduty = true } })
        Config.Roleplay.CityNews.Enabled = true
        Config.Roleplay.CityNews.App = 'event'
        local got
        Env.events['local:crimson-hitman:cityNews'] = function(data) got = data end
        local c = place(s, f)
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        truthy(got and got.text and got.account == 'LSNews', 'the event carried the post')
        eq(#(Natives.calls.birdy or {}), 0)
    end)

    it('degrades safely on a phone without PostBirdy: the completion stands', function()
        local s, f = stack({ targetJob = { name = 'police', type = 'leo', onduty = true } })
        Config.Roleplay.CityNews.Enabled = true
        Natives.noBirdy = true
        local c = place(s, f)
        local ok = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        Natives.noBirdy = nil
        truthy(ok)
    end)
end)

--------------------------------------------------------------------------
-- Dirty money payouts
--------------------------------------------------------------------------

describe('dirty money payouts', function()
    it('pays the hitman the item for exactly the figure, and keeps every coin', function()
        local s, f = stack()
        Config.Roleplay.DirtyPayouts.Enabled = true
        local before = value(s)
        local c = place(s, f, { baseline = { cash = 3000, bank = 2000 }, bonus = { cash = 500 } })
        local cash, bank = Env.players[3].PlayerData.money.cash, Env.players[3].PlayerData.money.bank
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.KIDNAPPING))
        eq(carried(3, 'black_money'), 5500, 'baseline and bonus as the item')
        eq(Env.players[3].PlayerData.money.cash, cash, 'no cash')
        eq(Env.players[3].PlayerData.money.bank, bank, 'no bank')
        eq(value(s), before, 'value conserved')
        local audited = false
        s.audit.flush()
        for _, row in ipairs(s.storage.queryAudit({ action = 'escrow_paid_as_item' }, nil, 100) or {}) do
            if row.contract_id == c.id then audited = true end
        end
        truthy(audited, 'on the record')
    end)

    it('returns an unearned bonus, and a refund, as they were taken', function()
        local s, f = stack()
        Config.Roleplay.DirtyPayouts.Enabled = true
        local before = value(s)
        local c = place(s, f, { baseline = { cash = 3000 }, bonus = { bank = 700 } })
        local bank = Env.players[1].PlayerData.money.bank
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        eq(Env.players[1].PlayerData.money.bank - bank, 700, 'bonus back as bank')
        eq(carried(3, 'black_money'), 3000)
        local c2 = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 1000 } } })
        local cash = Env.players[1].PlayerData.money.cash
        truthy(s.contracts.cancel(f.creator, c2.id))
        eq(Env.players[1].PlayerData.money.cash - cash, 1000, 'refund as cash')
        eq(value(s), before, 'value conserved')
    end)

    it('owes what does not fit, and hands it over as the item when they make room', function()
        local s, f = stack()
        Config.Roleplay.DirtyPayouts.Enabled = true
        local before = value(s)
        local c = place(s, f, { baseline = { cash = 4000 } })
        Env.players[3]._inventoryFull = true
        local cash = Env.players[3].PlayerData.money.cash
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        eq(carried(3, 'black_money'), 0, 'nothing given')
        eq(Env.players[3].PlayerData.money.cash, cash, 'and not cash instead')
        eq(value(s), before, 'owed, not lost')
        Env.players[3]._inventoryFull = nil
        s.escrow.retryPending('HITMAN01')
        eq(carried(3, 'black_money'), 4000, 'delivered once there is room')
        eq(value(s), before, 'value conserved')
    end)

    it('pays one marked bill worth the figure in \'worth\' mode, and Rate items a dollar in \'count\'', function()
        local s, f = stack()
        Config.Roleplay.DirtyPayouts.Enabled = true
        Config.Roleplay.DirtyPayouts.Mode = 'worth'
        Config.Roleplay.DirtyPayouts.Item = 'markedbills'
        local before = value(s)
        local c = place(s, f, { baseline = { cash = 2500 } })
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        local bill
        for _, e in ipairs(Env.players[3]._inventory) do if e.name == 'markedbills' then bill = e end end
        truthy(bill and bill.count == 1 and bill.metadata.worth == 2500, 'one bill worth 2500')
        eq(value(s), before, 'value conserved')

        local s2, f2 = stack()
        Config.Roleplay.DirtyPayouts.Enabled = true
        Config.Roleplay.DirtyPayouts.Rate = 3
        local before2 = value(s2, 3)
        local c2 = place(s2, f2, { baseline = { cash = 100 } })
        truthy(s2.contracts.claimSlot(c2.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        eq(carried(3, 'black_money'), 300, 'three items a dollar')
        eq(value(s2, 3), before2, 'value conserved at the rate')
    end)

    --- A give that raised with part of it placed was counted in whole
    --- dollars (arrived // Rate): up to Rate - 1 items that reached the
    --- hitman went uncounted, and the rest was given in full on top of
    --- them. Fewer than Rate items arriving counted as nothing at all, so
    --- the line was not even left for staff: it was given again in full.
    --- Exact now: the items of a dollar not yet whole are kept on the line
    --- (deliver_part), and every later give hands over only the rest.
    for _, arrivedItems in ipairs({ 4, 2, 7 }) do
        it(('conserves every item when a give at Rate 3 raises with %d of them placed'):format(arrivedItems),
            function()
            local s, f = stack()
            Config.Roleplay.DirtyPayouts.Enabled = true
            Config.Roleplay.DirtyPayouts.Rate = 3
            local before = units(s, 3)
            local c = place(s, f, { baseline = { cash = 100 } })
            local real = exports.ox_inventory.AddItem
            exports.ox_inventory.AddItem = function(self, src, name, count, metadata)
                real(self, src, name, arrivedItems, metadata)
                error('sync raised part-way', 0)
            end
            local ok, err = pcall(s.contracts.claimSlot, c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
            exports.ox_inventory.AddItem = real
            truthy(ok, tostring(err))
            eq(carried(3, 'black_money'), arrivedItems, 'the part that was placed')
            local line
            for _, l in ipairs(s.storage.readEscrow(c.id)) do
                if l.portion == CH.PORTION.BASELINE then line = l end
            end
            truthy(s.escrow.parked(line), 'part of it arrived: left for staff at once, never given blind')
            eq(units(s, 3), before, 'value conserved while it waits for staff')

            -- Retries give nothing while it waits; staff pay gives the rest.
            for _ = 1, 3 do s.escrow.retryPending('HITMAN01') end
            eq(carried(3, 'black_money'), arrivedItems, 'not given again by a retry')
            truthy(s.admin.settleLine(0, line.id, 'pay'))
            eq(carried(3, 'black_money'), 300, 'exactly three hundred items, not one more')
            eq(units(s, 3), before, 'value conserved to the item')
        end)
    end
end)

--------------------------------------------------------------------------
-- The admin panel
--------------------------------------------------------------------------

describe('the roleplay settings in the admin panel', function()
    local KEYS = {
        'Roleplay.WitnessHeat.Enabled', 'Roleplay.WitnessHeat.WitnessRadius', 'Roleplay.WitnessHeat.Phrases',
        'Roleplay.WitnessHeat.Areas', 'Roleplay.EmsRelisting.Enabled', 'Roleplay.EmsRelisting.TreatedMinutes',
        'Roleplay.CityNews.Enabled', 'Roleplay.CityNews.App', 'Roleplay.CityNews.Templates',
        'Roleplay.DirtyPayouts.Enabled', 'Roleplay.DirtyPayouts.Item', 'Roleplay.DirtyPayouts.Rate',
    }

    it('lists every one, each switch under Features in its Roleplay group', function()
        local s = stack()
        for _, key in ipairs(KEYS) do
            local entry = s.settings.entry(key)
            truthy(entry, key)
            if entry.kind == 'switch' then eq(entry.category, 'features', key) end
            truthy(entry.group:find('^Roleplay: '), key)
        end
    end)

    it('applies a change at once, and the feature follows it', function()
        local s, f = stack()
        Env.addPlayer({ source = 6, citizenid = 'ADMIN001' })
        truthy(s.settings.set('Roleplay.DirtyPayouts.Enabled', true, 'ADMIN001', 'ADMIN001'))
        eq(Config.Roleplay.DirtyPayouts.Enabled, true)
        local c = place(s, f, { baseline = { cash = 1200 } })
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        eq(carried(3, 'black_money'), 1200)
        truthy(s.settings.set('Roleplay.WitnessHeat.Phrases', { 'a tall man ran {direction}' }, 'ADMIN001', 'ADMIN001'))
        eq(Config.Roleplay.WitnessHeat.Phrases[1], 'a tall man ran {direction}')
        truthy(s.settings.set('Roleplay.WitnessHeat.Areas', { 'Pier@-1600,-1000' }, 'ADMIN001', 'ADMIN001'))
    end)

    it('refuses a value out of its rule, and changes nothing', function()
        local s = stack()
        falsy(s.settings.set('Roleplay.DirtyPayouts.Rate', 0, 'ADMIN001', 'ADMIN001'))
        falsy(s.settings.set('Roleplay.WitnessHeat.Areas', { 'nowhere' }, 'ADMIN001', 'ADMIN001'))
        falsy(s.settings.set('Roleplay.CityNews.App', 'tweeter', 'ADMIN001', 'ADMIN001'))
        falsy(s.settings.set('Roleplay.CityNews.Templates', { '<b>bold</b>' }, 'ADMIN001', 'ADMIN001'))
        eq(Config.Roleplay.DirtyPayouts.Rate, 1)
        eq(Config.Roleplay.CityNews.App, 'birdy')
    end)

    it('puts a broken config.lua value back at the start, and fills a block it lacks', function()
        resetConfig()
        local main = require('crimson-hitman.server.main')
        Config.Roleplay.DirtyPayouts.Rate = -4
        Config.Roleplay.CityNews = nil
        local ok, fatal, warn = main.checkCandidate(Config)
        truthy(ok, table.concat(fatal or {}, '; '))
        local said = false
        for _, line in ipairs(warn) do if line:find('DirtyPayouts.Rate', 1, true) then said = true end end
        truthy(said, 'the correction is said')
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
        Env.events['crimson-hitman:admin']({ op = 'setSetting', data = { key = 'Roleplay.WitnessHeat.Enabled',
            value = true }, __rid = 1 })
        _G.source = nil
        eq(Config.Roleplay.WitnessHeat.Enabled, false, 'unchanged')
        _G.source = 6
        Env.events['crimson-hitman:admin']({ op = 'setSetting', data = { key = 'Roleplay.WitnessHeat.Enabled',
            value = true }, __rid = 2 })
        _G.source = nil
        eq(Config.Roleplay.WitnessHeat.Enabled, true, 'changed by staff')
    end)
end)
