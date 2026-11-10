--- Workflow round 3: the server half of each item, held to it.
---
---   W2   a payout held for proof of intent on the payout that closes the
---        contract says only when it is released; while live, the hitman's
---        card states the rule;
---   W4   an acceptance moves the target's On me too, once they are shown it;
---   W7   the Ledger keeps what moved (paid, withdrawn, refunded, bought
---        out), as a figure, never who;
---   W8   a voided contract's notice says "what you put up";
---   W9   a report's review text names no file;
---   S1   the board says what refuses writes: the app paused, the restart
---        hold (with how long at most), a suspension (until when);
---   S4   the placer's card says a handover is running and roughly how long,
---        never who, and their app is moved when one starts;
---   S8   staff look a party up by the contract and the role, never needing
---        a citizen id, and never one anonymous to them; and by name;
---   S11  a rumour names the district to ask around for the broker where
---        the map does not mark them; a missing burner names the item;
---   S12  the hit on the hitman offers an operative already named to the
---        target; and a guard is told on their phone when hired and paid.

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

local function pushesTo(src)
    local out = {}
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:push' and event.target == src then out[#out + 1] = event.args[1] end
    end
    return out
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

--- Staff: 6 crimson.admin, 8 crimson.admin with crimson.identity.
local function staff(s)
    Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
        firstname = 'Sam', lastname = 'Steward' })
    Env.addPlayer({ source = 8, citizenid = 'UNMASK01', license = 'license:UNMASK01',
        firstname = 'Uma', lastname = 'Mask' })
    Env.aces[6] = { ['crimson.admin'] = true }
    Env.aces[8] = { ['crimson.admin'] = true, ['crimson.identity'] = true }
    Config.Cooldowns.admin = { per = 10, burst = 1000 }
    Config.Cooldowns.adminWrite = { per = 10, burst = 1000 }
    if s.bridges and s.bridges.install then s.bridges.install(s) end
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

local function place(s, f, extra)
    local req = { targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
                  reward = { baseline = { cash = 5000 } } }
    for k, v in pairs(extra or {}) do req[k] = v end
    local c, err = s.contracts.create(f.creator, req)
    truthy(c, 'placed: ' .. tostring(err))
    return c
end

local function kill(s, c)
    Env.players[2].PlayerData.metadata.isdead = true
    local ok, err, result = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
    truthy(ok, 'claimed: ' .. tostring(err))
    Env.players[2].PlayerData.metadata.isdead = false
    return result
end

--------------------------------------------------------------------------
-- W2
--------------------------------------------------------------------------

describe('W2: proof of intent on a payout that closes the contract', function()
    local function intentOn()
        Config.Roleplay.ProofOfIntent.Enabled = true
        Config.Roleplay.ProofOfIntent.MinMessages = 3
        Config.Roleplay.ProofOfIntent.HoldMaxMinutes = 30
    end

    it('holds it, and says only when it is released: nothing that can no longer be done', function()
        local s = newStack()
        local f = fixture(s)
        intentOn()
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false), 'accepted')
        local result = kill(s, c)
        truthy(result.intentHold, 'held for proof of intent')
        eq(result.intentHold.closed, true, 'the payout closed the contract')
        eq(result.intentHold.missing, nil, 'no "message the client" on a closed contract')
        -- The hitman's receipt, as the completion sends it.
        Env.clientEvents = {}
        s.notify.contractCompleted(s.storage.readContract(c.id), 'HITMAN01', {}, result,
            { receipt = true })
        local told = notices(3)
        truthy(has(told, 'Payout held: released within 30 minutes.'), table.concat(told, ' || '))
        falsy(has(told, 'message'), 'offered messages to a closed thread: ' .. table.concat(told, ' || '))
        local held = s.rpIntent.heldFor('HITMAN01')
        eq(#held, 1)
        eq(held[1].closed, true)
        eq(held[1].missing, nil)
    end)

    it('still names what is missing while the contract runs on (a later payout to come)', function()
        local s = newStack()
        local f = fixture(s)
        intentOn()
        local c = place(s, f, { reward = { slots = { { baseline = { cash = 5000 } },
                                                    { baseline = { cash = 5000 } } } } })
        truthy(s.contracts.accept(f.hitman, c.id, false), 'accepted')
        local result = kill(s, c)
        truthy(result.intentHold, 'held')
        falsy(result.intentHold.closed)
        truthy(tostring(result.intentHold.missing):find('3 more messages', 1, true),
            tostring(result.intentHold.missing))
    end)

    it('states the rule on the hitman\'s card while the contract is live', function()
        local s = newStack()
        local f = fixture(s)
        intentOn()
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false), 'accepted')
        local card = s.projection.contract(s.storage.readContract(c.id), 'HITMAN01')
        truthy(card.intentRule, 'the rule is on the card')
        eq(card.intentRule.messages, 3)
        local placer = s.projection.contract(s.storage.readContract(c.id), 'CREATOR1')
        eq(placer.intentRule, nil, 'the hitman\'s alone')
        Config.Roleplay.ProofOfIntent.Enabled = false
        eq(s.projection.contract(s.storage.readContract(c.id), 'HITMAN01').intentRule, nil,
            'off, nothing')
    end)
end)

--------------------------------------------------------------------------
-- W4
--------------------------------------------------------------------------

describe('W4: an acceptance moves the target\'s app', function()
    it('pushes the target, naming no contract, once they are shown it', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f)
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        truthy(s.notify.shownToTarget(s.storage.readContract(c.id)), 'shown to the target by now')
        Env.clientEvents = {}
        s.notify.clearPush('TARGET01')
        truthy(s.contracts.accept(f.hitman, c.id, false), 'accepted')
        Env.advance(5)
        local pushes = pushesTo(2)
        truthy(#pushes >= 1, 'the target\'s On me was not moved')
        for _, p in ipairs(pushes) do eq(p.ids, nil, 'a target push names no contract') end
    end)
end)

--------------------------------------------------------------------------
-- W7
--------------------------------------------------------------------------

describe('W7: the Ledger keeps what moved, never who', function()
    local function rows(s, cid)
        local out = s.ledger.entries(cid)
        return out
    end

    it('writes the figure paid on a payout, to the client and the hitman', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false), 'accepted')
        local result = kill(s, c)
        s.ledger.record(s.storage.readContract(c.id), 'HITMAN01', nil, CH.FULFILMENT.ELIMINATION, result)
        local mine = rows(s, 'HITMAN01')
        eq(mine[1].kind, 'paid')
        eq(mine[1].amount, 5000)
        eq(rows(s, 'CREATOR1')[1].amount, 5000)
        eq(rows(s, 'TARGET01')[1].amount, 0, 'nothing of the target\'s moved')
    end)

    it('writes a withdrawn contract on the client\'s Ledger, with what came back', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f)
        truthy(s.contracts.cancel(f.creator, c.id), 'withdrawn')
        local mine = rows(s, 'CREATOR1')
        eq(#mine, 1)
        eq(mine[1].kind, 'withdrawn')
        eq(mine[1].amount, 5000)
        eq(mine[1].role, 'creator')
        eq(#rows(s, 'TARGET01'), 0, 'the target is not told of a contract they may never have seen')
    end)

    it('writes a buyout on the client\'s and the target\'s, the figures alone', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f, { bailoutAmount = 6000 })
        local price = s.storage.readContract(c.id).bailout_amount
        truthy(s.bailout.buy(f.target, c.id), 'bought out')
        local client = rows(s, 'CREATOR1')
        eq(client[1].kind, 'buyout')
        eq(client[1].amount, 5000 + price, 'the escrow back and the premium')
        local target = rows(s, 'TARGET01')
        eq(target[1].kind, 'buyout')
        eq(target[1].amount, price)
        for _, row in ipairs(target) do
            for key, value in pairs(row) do
                falsy(tostring(value):find('Vic', 1, true) or tostring(value):find('CREATOR1', 1, true),
                    'the client named on the target\'s row: ' .. key)
            end
        end
    end)

    it('writes a contract that ran out as refunded', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f)
        local ok = s.contracts.resolve(c.id, CH.STATE.EXPIRED, 'CREATOR1', nil, 'expired')
        truthy(ok, 'expired')
        eq(rows(s, 'CREATOR1')[1].kind, 'refunded')
        eq(rows(s, 'CREATOR1')[1].amount, 5000)
    end)
end)

--------------------------------------------------------------------------
-- W8, W9
--------------------------------------------------------------------------

describe('W8 and W9: words', function()
    it('tells the client of a void what they put up has been returned', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f)
        Env.clientEvents = {}
        local ok = s.admin.void(nil, c.id, 'test')
        truthy(ok, 'voided')
        local told = notices(1)
        truthy(has(told, 'Everything you put up has been returned.'), table.concat(told, ' || '))
        falsy(has(told, 'escrow'), table.concat(told, ' || '))
    end)

    it('names no file in a report\'s review text', function()
        local source = read_file('crimson-hitman/server/review.lua')
        local line = source:match("player_report = (.-)\n    low_effort_reason")
        truthy(line, 'the entry is there')
        falsy(line:find('server/reports.lua', 1, true), line)
    end)
end)

--------------------------------------------------------------------------
-- S1
--------------------------------------------------------------------------

describe('S1: the board says what refuses writes', function()
    it('says nothing while nothing does', function()
        local s = newStack()
        fixture(s)
        local reply = call('list', 3, {})
        eq(reply.ok, true)
        eq(reply.data.holds, nil)
    end)

    it('says staff paused the app', function()
        local s = newStack()
        fixture(s)
        Config.Holds.AppPaused = true
        s.holds.syncAppPause()
        local reply = call('list', 3, {})
        eq(reply.data.holds.appPaused, true)
        Config.Holds.AppPaused = false
        s.holds.syncAppPause()
    end)

    it('says the restart hold is on, and how long it can last at most', function()
        local s = newStack()
        fixture(s)
        Config.Holds.RestartPauseBeforeSeconds = 1800
        Config.Holds.RestartMaxHoldMinutes = 45
        truthy(s.holds.scheduledRestart({ secondsRemaining = 300 }), 'held')
        local ok, err = pcall(function()
            local reply = call('list', 3, {})
            truthy(reply.data.holds.restartHold, 'the restart hold')
            eq(reply.data.holds.restartHold.endsIn, 45 * 60)
        end)
        s.holds.releaseRestart('skipped')
        if not ok then error(err, 0) end
    end)

    it('says a suspension, until when', function()
        local s = newStack()
        fixture(s)
        staff(s)
        local r = ask(6, 'suspend', { subject = 'HITMAN01', days = 1, reason = 'spam' })
        truthy(r and r.ok, 'suspended: ' .. tostring(r and r.message))
        local reply = call('list', 3, {})
        truthy(reply.data.holds and reply.data.holds.suspendedUntil > os.time(), 'until when')
    end)
end)

--------------------------------------------------------------------------
-- S4
--------------------------------------------------------------------------

describe('S4: the placer sees the handover they stand still for', function()
    it('says it is running and roughly how long, on the placer\'s card alone, and moves their app', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f, { mode = CH.MODE.EXCLUSIVE })
        truthy(s.contracts.accept(f.hitman, c.id, false), 'accepted')
        eq(s.projection.contract(s.storage.readContract(c.id), 'CREATOR1').handoverLeft, nil,
            'nothing before one runs')
        Env.players[1]._coords = { x = 200.0, y = 200.0, z = 30.0 }
        Env.players[2]._coords = { x = 200.5, y = 200.0, z = 30.0 }
        Env.players[3]._coords = { x = 201.0, y = 200.0, z = 30.0 }
        Env.players[2].PlayerData.metadata.ishandcuffed = true
        Env.clientEvents = {}
        s.notify.clearPush('CREATOR1')
        local armed, why = s.kidnap.arm(c.id, 'HITMAN01')
        truthy(armed, 'armed: ' .. tostring(why))
        local card = s.projection.contract(s.storage.readContract(c.id), 'CREATOR1')
        eq(card.handoverLeft, math.ceil(Config.Kidnap.CountdownSeconds / 5) * 5,
            'roughly how long, rounded up to five seconds')
        eq(s.projection.contract(s.storage.readContract(c.id), 'TARGET01').handoverLeft, nil,
            'never to the target')
        Env.advance(2)
        truthy(#pushesTo(1) >= 1, 'the placer\'s app moved when it started')
    end)
end)

--------------------------------------------------------------------------
-- S8
--------------------------------------------------------------------------

describe('S8: staff look a party up from the contract', function()
    it('looks the target up by the contract and the role, with no citizen id to send or show', function()
        local s = newStack()
        local f = fixture(s)
        staff(s)
        local c = place(s, f)
        local reply = ask(6, 'player', { subject = 'contract:' .. c.id .. ':target' })
        truthy(reply and reply.ok, tostring(reply and reply.message))
        eq(reply.data.player.name, 'Dana Reyes')
        eq(reply.data.player.cid, nil, 'no citizen id to staff without IdentityAce')
    end)

    it('refuses a client who placed it anonymously to staff without IdentityAce', function()
        local s = newStack()
        local f = fixture(s)
        staff(s)
        local c = place(s, f, { anonymous = true })
        local reply = ask(6, 'player', { subject = 'contract:' .. c.id .. ':client' })
        falsy(reply.ok, 'an anonymous client unmasked')
        falsy(tostring(reply.message):find('Vic', 1, true), tostring(reply.message))
        local unmasked = ask(8, 'player', { subject = 'contract:' .. c.id .. ':client' })
        truthy(unmasked.ok, 'IdentityAce may')
        eq(unmasked.data.player.cid, 'CREATOR1')
    end)

    it('freezes an operative named on it, by the contract and the row', function()
        local s = newStack()
        local f = fixture(s)
        staff(s)
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false), 'accepted under their name')
        local row = s.storage.readHitman(c.id, 'HITMAN01')
        local reply = ask(6, 'freeze', { subject = 'contract:' .. c.id .. ':op:' .. tostring(row.id),
                                         reason = 'checking' })
        truthy(reply and reply.ok, tostring(reply and reply.message))
        truthy(s.holds.of and s.holds.of('HITMAN01') or s.holds.count() == 1, 'frozen')
    end)

    it('takes a name, as Contracts does, and says when several match', function()
        local s = newStack()
        local f = fixture(s)
        staff(s)
        place(s, f)
        local reply = ask(6, 'player', { subject = 'Rook Ash' })
        truthy(reply and reply.ok, tostring(reply and reply.message))
        eq(reply.data.player.name, 'Rook Ash')
        eq(reply.data.player.cid, nil, 'a name looked up shows no citizen id without IdentityAce')
        local many = ask(6, 'player', { subject = 'a' })
        falsy(many.ok)
        truthy(tostring(many.message):find('match', 1, true), tostring(many.message))
    end)
end)

--------------------------------------------------------------------------
-- S11
--------------------------------------------------------------------------

describe('S11: rumours and the burner phone say where and what', function()
    it('names the district to ask around for the broker where the map does not mark them', function()
        local s = newStack()
        local f = fixture(s)
        Env.addPlayer({ source = 4, citizenid = 'BYSTAND1', license = 'license:ddd',
            firstname = 'Bo', lastname = 'Stander' })
        Config.Intel.Rumours.Enabled = true
        Config.Intel.Rumours.Blip = false
        place(s, f)
        local reply = call('list', 4, {})
        truthy(reply and reply.ok, 'the board: ' .. tostring(reply and reply.err))
        truthy(reply.data.rumours, 'rumours on')
        eq(type(reply.data.rumours.brokerArea), 'string', 'a district to ask around')
        local spot = s.rpPlaces.current('broker')
        falsy(tostring(reply.data.rumours.brokerArea):find(tostring(math.floor(spot.x)), 1, true),
            'never the spot')
        Config.Intel.Rumours.Blip = true
        local marked = call('list', 4, {})
        eq(marked.data.rumours.brokerArea, nil, 'marked on the map, the map says it')
        eq(marked.data.rumours.blip, true)
    end)

    it('names the burner phone item', function()
        local s = newStack()
        local f = fixture(s)
        Config.Roleplay.BurnerPhone.Enabled = true
        Config.Roleplay.BurnerPhone.Item = 'burner_phone'
        local board = call('list', 3, {})
        eq(board.data.burnerMissing, true)
        eq(board.data.burnerItem, 'burner_phone')
        local refused = call('accept', 3, { id = 'ct00000001' })
        eq(refused.err, CH.ERR.NEED_BURNER)
        eq(refused.data and refused.data.item, 'burner_phone')
        local _ = f
    end)
end)

--------------------------------------------------------------------------
-- S12 and the guard
--------------------------------------------------------------------------

describe('S12: the hit on the hitman offers an operative already named to the target', function()
    it('offers a named operative with anonymity off, never an anonymous one', function()
        local s = newStack()
        local f = fixture(s)
        Config.Roleplay.HitOnHitman.Enabled = true
        Config.TargetClasses.default.ShowOperativeNames = true
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false), 'accepted under their name')
        local card = s.projection.contract(s.storage.readContract(c.id), 'TARGET01')
        truthy(card.counterTargets and #card.counterTargets == 1, 'offered')
        eq(card.counterTargets[1].name, 'Rook Ash')
        eq(type(card.counterTargets[1].handle), 'string')
        falsy(card.counterTargets[1].cid, 'no citizen id')
        Config.TargetClasses.default.ShowOperativeNames = false
        eq(s.projection.contract(s.storage.readContract(c.id), 'TARGET01').counterTargets, nil,
            'names hidden from the target, nothing offered')
    end)
end)

describe('the guard is told on their phone', function()
    it('when hired, and when paid', function()
        local s = newStack()
        local f = fixture(s)
        Config.Roleplay.Protection.Enabled = true
        Env.addPlayer({ source = 4, citizenid = 'GUARD001', license = 'license:ggg',
            firstname = 'Gil', lastname = 'Guard' })
        local c = place(s, f)
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        Env.players[2].PlayerData.money.bank = 200000
        local posted = s.rpProtection.post(s.identity.resolve(2), { id = c.id,
            amount = Config.Roleplay.Protection.MinReward, account = Config.Roleplay.Protection.Account })
        truthy(posted and posted.job, 'posted')
        Env.clientEvents = {}
        local took = call('protectionAccept', 4, { job = posted.job, reward = Config.Roleplay.Protection.MinReward })
        truthy(took and took.ok, 'taken: ' .. tostring(took and took.err))
        truthy(has(notices(4), 'You are hired to guard Dana Reyes'), table.concat(notices(4), ' || '))
        Env.clientEvents = {}
        truthy(s.contracts.cancel(f.creator, c.id), 'withdrawn: they made it')
        s.rpProtection.sweep()
        truthy(has(notices(4), 'from the protection job is in your'), table.concat(notices(4), ' || '))
    end)
end)
