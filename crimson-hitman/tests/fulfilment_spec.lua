--- Live transfer only (Config.Completion.Fulfilment = 'alive'), the rule
--- this resource ships with, and the contracts placed under 'either'
--- before or beside it.
---
--- The runner places contracts under 'either' (tests/run.lua), because
--- nearly every other spec is about a kill. Every stack here that means the
--- shipped default says so.

local AT = { x = 200.0, y = 200.0, z = 30.0 }
local URL = 'https://cdn.fivemanage.com/p.png'

--- A stack placing contracts as this resource ships: live transfer only.
local function shipped()
    local s = newStack()
    Config.Completion.Fulfilment = 'alive'
    local f = fixture(s)
    Config.Completion.ExtraPhotoHosts = { 'cdn.fivemanage.com' }
    s.photo.loadAllowedHosts()
    return s, f
end

local function place(s, f, reward, extra)
    local req = { targetCid = 'TARGET01', reason = 'Unpaid debt',
                  mode = CH.MODE.COMPETITIVE, reward = reward }
    for k, v in pairs(extra or {}) do req[k] = v end
    return s.contracts.create(f.creator, req)
end

--- Placed and taken: the contract every test below starts from.
local function taken(s, f, reward, extra)
    local c, err = place(s, f, reward or { baseline = { cash = 5000 } }, extra)
    truthy(c, 'placing it: ' .. tostring(err))
    truthy(s.contracts.accept(f.hitman, c.id, false), 'taking it')
    return c
end

--- The hitman beside the target, a hit of theirs seen landing, and the
--- target dead by the medical state: a kill as the server knows one.
local function shot(s)
    Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
    Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
    Env.players[2]._health = 140
    s.death.recordDamage(3, 2, 123456)
    Env.players[2].PlayerData.metadata.isdead = true
end

--- A kill the target's own game reports, naming the hitman.
local function killed(s)
    shot(s)
    return s.death.onVictimReport(2, 3)
end

--- Back on their feet, at full health: a respawn.
local function respawned(s)
    Env.players[2].PlayerData.metadata.isdead = false
    Env.players[2].PlayerData.metadata.inlaststand = false
    Env.players[2]._health = 200
    s.death.onRevived('TARGET01')
end

--- All three together, the target restrained.
local function inHand(how)
    for _, src in ipairs({ 1, 2, 3 }) do
        Env.players[src]._coords = { x = AT.x, y = AT.y, z = AT.z }
    end
    if how == 'vehicle' then
        Env.players[2].PlayerData.metadata.ishandcuffed = false
        Env.players[2]._vehicle, Env.players[3]._vehicle = 55, 55
    else
        Env.players[2].PlayerData.metadata.ishandcuffed = true
    end
end

local function delivered(s, contractId)
    truthy(s.kidnap.arm(contractId, 'HITMAN01'), 'the handover arms')
    local done = {}
    for _ = 1, math.floor(Config.Kidnap.CountdownSeconds * 1000 / Config.Kidnap.TickMs) do
        for _, d in ipairs(s.kidnap.tick(Config.Kidnap.TickMs)) do done[#done + 1] = d end
    end
    return done
end

local function audited(s, action)
    s.audit.flush()
    local n = 0
    for _, row in ipairs(s.storage.readAudit(400) or {}) do
        if row.action == action then n = n + 1 end
    end
    return n
end

--- Everything in the city, pockets and escrow, per source, with the
--- creator's lockpicks as goods: what no ending may mint or destroy.
local function world(s)
    local total = { cash = 0, bank = 0, dirty = 0, lockpick = 0 }
    for _, p in pairs(Env.players) do
        total.cash = total.cash + (p.PlayerData.money.cash or 0)
        total.bank = total.bank + (p.PlayerData.money.bank or 0)
        for _, e in ipairs(p._inventory or {}) do
            if e.name == Config.Sources.dirty.item then total.dirty = total.dirty + (e.count or 0) end
            if e.name == 'lockpick' then total.lockpick = total.lockpick + (e.count or 0) end
        end
    end
    for _, c in ipairs(s.storage.allContracts()) do
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.state ~= CH.ESCROW_STATE.SETTLED then
                if CH.MONEY_SOURCES[line.source] then
                    total[line.source] = total[line.source] + (line.amount or 0)
                elseif line.item == 'lockpick' then
                    total.lockpick = total.lockpick + (line.quantity or 0)
                end
            end
        end
    end
    return total
end

local function conserved(s, before, label)
    local after = world(s)
    for _, k in ipairs({ 'cash', 'bank', 'dirty', 'lockpick' }) do
        eq(after[k], before[k], label .. ': ' .. k .. ' minted or destroyed')
    end
end

local function held(s, contractId, portion)
    local n = 0
    for _, line in ipairs(s.storage.readEscrow(contractId)) do
        if line.portion == portion then n = n + 1 end
    end
    return n
end

describe('the rule this resource ships', function()
    it('is live transfer only, in config.lua and in the shipped defaults', function()
        eq(ConfigDefaults.Completion.Fulfilment, 'alive', 'config/defaults.lua')
        eq(read_file('crimson-hitman/config/config.lua'):match("\n%s*Fulfilment%s*=%s*'(%a+)',"),
            'alive', 'config/config.lua')
    end)

    it('is what a contract placed now carries, and keeps', function()
        local s, f = shipped()
        local c = taken(s, f)
        eq(s.storage.readContract(c.id).fulfilment_rule, 'alive')

        Config.Completion.Fulfilment = 'either'
        eq(s.storage.readContract(c.id).fulfilment_rule, 'alive',
            'the setting decides new contracts, not ones already placed')
        eq(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION), false,
            'and a kill still does not complete it')
    end)
end)

describe('placing a contract that pays only for a live delivery', function()
    it('takes no bonus, however much is asked for', function()
        local s, f = shipped()
        local cash = Env.players[1].PlayerData.money.cash
        local c = place(s, f, { baseline = { cash = 5000 } }, { bonusPercent = 50 })
        truthy(c)
        eq(c.bonus_percent, 0, 'the percentage is dropped')
        eq(held(s, c.id, CH.PORTION.BONUS), 0, 'and nothing is escrowed for one')
        eq(cash - Env.players[1].PlayerData.money.cash, 5000, 'only the reward is taken')
    end)

    it('refuses a bonus named on its own, and takes nothing', function()
        local s, f = shipped()
        local before = world(s)
        local purse = Env.players[1].PlayerData.money.cash
        local c, err = place(s, f, { baseline = { cash = 5000 }, bonus = { cash = 2500 } })
        falsy(c)
        eq(err, CH.ERR.NO_BONUS)

        c, err = place(s, f, { baseline = { cash = 5000 },
            bonus = { items = { { name = 'lockpick', count = 2 } } } })
        falsy(c, 'goods marked to pay only if alive are a bonus too')
        eq(err, CH.ERR.NO_BONUS)

        eq(Env.players[1].PlayerData.money.cash, purse, 'nothing was taken')
        eq(#s.storage.allContracts(), 0, 'and nothing was placed')
        conserved(s, before, 'a refused placement')
    end)
end)

describe('a kill on a contract that pays only for a live delivery', function()
    it('opens no kill from the target\'s own report', function()
        local s, f = shipped()
        local c = taken(s, f)
        eq(killed(s), 0, 'nothing opened')
        falsy(s.death.getPending(c.id, 'HITMAN01'))
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'the contract stays open')
        eq(s.storage.readHitman(c.id, 'HITMAN01').state, 'active', 'with the hitman on it')
    end)

    it('opens none from the server\'s own sighting either', function()
        local s, f = shipped()
        local c = taken(s, f)
        shot(s)
        s.death.watchTargets(s.storage.liveContracts())
        Env.advance(math.ceil(s.death.UNREPORTED_WAIT_MS / 1000) + 1)
        falsy(s.death.getPending(c.id, 'HITMAN01'))
        eq(audited(s, 'death_unreported'), 0, 'nothing waited on a report, with no kill to open')
        truthy(s.death.wasSeenDead('TARGET01'),
            'the death is still seen, which the revive after it is measured from')
    end)

    it('refuses Verify kill with its own words, before and after a kill', function()
        local s, f = shipped()
        local c = taken(s, f)
        local token, err = s.photo.issue(f.hitman, c.id)
        falsy(token)
        eq(err, CH.ERR.KILL_NOT_ALLOWED)

        killed(s)
        token, err = s.photo.issue(f.hitman, c.id)
        falsy(token)
        eq(err, CH.ERR.KILL_NOT_ALLOWED, 'not "no kill to verify": finishing them is not the answer')

        -- Somebody not on it is told what they were always told.
        Env.addPlayer({ source = 11, citizenid = 'NOSY0001', license = 'license:nosy',
            cash = 10, bank = 10, firstname = 'Ida', lastname = 'Nkemelu' })
        token, err = s.photo.issue(s.identity.resolve(11), c.id)
        falsy(token)
        eq(err, CH.ERR.NO_KILL_TO_VERIFY, 'an id is not a way to ask about a contract')
    end)

    it('is never paid for a kill, whatever reaches the claim', function()
        local s, f = shipped()
        local c = taken(s, f)
        local before = world(s)
        local ok, err = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        falsy(ok)
        eq(err, CH.ERR.KILL_NOT_ALLOWED)
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'no lock taken, nothing moved')
        eq(s.storage.readContract(c.id).next_slot, 1)
        conserved(s, before, 'a refused claim')
    end)

    it('refuses a photo token for one, and spends it', function()
        -- A token can only be minted for a contract a kill completes, and
        -- the rule never changes once placed: this one is made by hand, to
        -- hold the photo's own refusal to its word.
        local s, f = shipped()
        local c = taken(s, f)
        local row = s.storage.readContract(c.id)
        row.fulfilment_rule = 'either'
        eq(killed(s), 1)
        local token = s.photo.issue(f.hitman, c.id)
        truthy(token)
        row.fulfilment_rule = 'alive'

        local before = world(s)
        local ok, err = s.photo.submit(f.hitman, token, URL)
        falsy(ok)
        eq(err, CH.ERR.KILL_NOT_ALLOWED)
        ok, err = s.photo.submit(f.hitman, token, URL)
        eq(err, CH.ERR.TOKEN_INVALID, 'the token is spent')
        eq(audited(s, 'photo_kill_not_allowed'), 1, 'and staff can see it happened')
        conserved(s, before, 'a refused photo')
    end)

    it('lets the target die and respawn as normal, and they can still be delivered', function()
        local s, f = shipped()
        local c = taken(s, f)
        killed(s)
        respawned(s)
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED)

        local cash = Env.players[3].PlayerData.money.cash
        inHand()
        eq(#delivered(s, c.id), 1, 'a live delivery right after a respawn still counts')
        eq(Env.players[3].PlayerData.money.cash - cash, 5000)
        eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED)
    end)

    -- The alive checks are the operator's to loosen, but not on these: a
    -- handover is the only way one completes, so a body handed over would
    -- be the kill the rule exists to refuse, paid in full.
    for _, case in ipairs({
        { switch = 'RequireConscious', how = 'vehicle' },
        { switch = 'RejectDead',       how = 'restrained' },
    }) do
        it(('is never paid for a body handed over, with Config.Kidnap.%s off'):format(case.switch), function()
            local s, f = shipped()
            Config.Kidnap[case.switch] = false
            local c = taken(s, f)
            killed(s)
            -- Raised where they fell at full health, as the medical
            -- resource leaves a body: over any health floor.
            Env.players[2]._health = 200
            inHand(case.how)

            local before = world(s)
            local ok, err = s.kidnap.arm(c.id, 'HITMAN01')
            falsy(ok, 'a body is not a live delivery')
            eq(err, 'target_not_conscious')
            local done = 0
            for _ = 1, math.floor(Config.Kidnap.CountdownSeconds * 1000 / Config.Kidnap.TickMs) + 1 do
                done = done + #s.kidnap.tick(Config.Kidnap.TickMs)
            end
            eq(done, 0, 'nothing completes')
            eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'the contract stays open')
            conserved(s, before, 'a body handed over')
        end)

        it(('fails a handover whose target dies in it, with Config.Kidnap.%s off'):format(case.switch), function()
            local s, f = shipped()
            Config.Kidnap[case.switch] = false
            local c = taken(s, f)
            Env.players[2]._health = 200
            inHand(case.how)
            truthy(s.kidnap.arm(c.id, 'HITMAN01'), 'armed while they are alive')

            Env.players[2].PlayerData.metadata.isdead = true
            local done = 0
            for _ = 1, math.floor(Config.Kidnap.CountdownSeconds * 1000 / Config.Kidnap.TickMs) + 1 do
                done = done + #s.kidnap.tick(Config.Kidnap.TickMs)
            end
            eq(done, 0, 'a target who dies in the countdown is not delivered')
            eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED)
        end)
    end

    it('leaves those switches loosening a contract a kill completes anyway', function()
        local s, f = shipped()
        Config.Completion.Fulfilment = 'either'
        Config.Kidnap.RejectDead = false
        local c = taken(s, f)
        eq(s.storage.readContract(c.id).fulfilment_rule, 'either')
        Env.players[2].PlayerData.metadata.isdead = true
        Env.players[2]._health = 200
        inHand()
        local ok, err = s.kidnap.arm(c.id, 'HITMAN01')
        truthy(ok, 'the operator\'s setting still holds there: ' .. tostring(err))
    end)
end)

describe('delivering alive on a contract that pays only for it', function()
    for _, how in ipairs({ 'restrained', 'vehicle' }) do
        it(('pays the whole reward, with the target %s, and the money adds up'):format(how), function()
            local s, f = shipped()
            local before = world(s)
            local c = taken(s, f, { baseline = { cash = 5000, bank = 3000,
                items = { { name = 'lockpick', count = 2 } } } }, { bonusPercent = 50 })
            local cash = Env.players[3].PlayerData.money.cash
            local bank = Env.players[3].PlayerData.money.bank

            inHand(how)
            eq(#delivered(s, c.id), 1, 'delivered')
            eq(Env.players[3].PlayerData.money.cash - cash, 5000, 'all the cash')
            eq(Env.players[3].PlayerData.money.bank - bank, 3000, 'all the bank')
            local picks = 0
            for _, e in ipairs(Env.players[3]._inventory or {}) do
                if e.name == 'lockpick' then picks = picks + e.count end
            end
            eq(picks, 2, 'and the goods')
            eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED)
            conserved(s, before, 'a live delivery')
        end)
    end

    it('pays every payout of a multi-payout contract the same way', function()
        local s, f = shipped()
        local before = world(s)
        local c = taken(s, f, { slots = {
            { baseline = { cash = 3000 } }, { baseline = { cash = 2000 } },
        } })
        local cash = Env.players[3].PlayerData.money.cash
        inHand()
        eq(#delivered(s, c.id), 1)
        Env.advance(Config.Limits.SlotCooldownSeconds + 1)
        eq(#delivered(s, c.id), 1)
        eq(Env.players[3].PlayerData.money.cash - cash, 5000, 'both payouts')
        eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED)
        conserved(s, before, 'two live deliveries')
    end)
end)

describe('changing a contract that pays only for a live delivery', function()
    it('refuses to raise a bonus it does not have', function()
        local s, f = shipped()
        local c = taken(s, f)
        local before = world(s)
        local ok, err = s.amendments.improve(f.creator, c.id, CH.AMENDMENT.RAISE_BONUS, { percent = 50 })
        falsy(ok)
        eq(err, CH.ERR.NO_BONUS)
        eq(s.storage.readContract(c.id).bonus_percent, 0)
        conserved(s, before, 'a refused raise')
    end)

    it('refuses a bonus added on its own, and still takes an addition to the reward', function()
        local s, f = shipped()
        local c = taken(s, f)
        local before = world(s)
        local ok, err = s.amendments.addEscrow(f.creator, c.id,
            { baseline = { cash = 500 }, bonus = { cash = 1000 } })
        falsy(ok)
        eq(err, CH.ERR.NO_BONUS)
        eq(held(s, c.id, CH.PORTION.BONUS), 0)
        conserved(s, before, 'a refused top-up')

        truthy(s.amendments.addEscrow(f.creator, c.id, { baseline = { cash = 1000 } }),
            'adding to the reward is how more is offered')
        local cash = Env.players[3].PlayerData.money.cash
        inHand()
        eq(#delivered(s, c.id), 1)
        eq(Env.players[3].PlayerData.money.cash - cash, 6000, 'and it is paid on delivery')
    end)
end)

describe('what every party is shown', function()
    it('names the rule on every card, and the board says how new ones are placed', function()
        local s, f = shipped()
        local c = taken(s, f)
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        Env.addPlayer({ source = 11, citizenid = 'NOSY0001', license = 'license:nosy',
            cash = 10, bank = 10, firstname = 'Ida', lastname = 'Nkemelu' })

        eq(s.projection.mine('CREATOR1')[1].fulfilment, 'alive', 'the client')
        eq(s.projection.accepted('HITMAN01')[1].fulfilment, 'alive', 'the hitman')
        eq(s.projection.onMe('TARGET01')[1].fulfilment, 'alive', 'the target')
        local board = s.projection.listing('NOSY0001', 1)
        eq(board.contracts[1].fulfilment, 'alive', 'anyone on the board')
        eq(board.settings.fulfilment, 'alive', 'and the Place form')

        Config.Completion.Fulfilment = 'either'
        board = s.projection.listing('NOSY0001', 1)
        eq(board.settings.fulfilment, 'either', 'a new one would be either')
        eq(board.contracts[1].fulfilment, 'alive', 'this one is what it was placed as')
    end)

    -- The Place form read the rule off the board alone, so with that read
    -- failed it offered a bonus the server then placed as 0.
    it('says how new ones are placed with the wallet too, which the Place form reads each time', function()
        local s, f = shipped()
        local wallet = s.app.handlers.rewardOptions(f.creator, {})
        eq(wallet.caps.fulfilment, 'alive')
        eq(wallet.caps.bonusPercent, Config.Bonus.maxPercent,
            'the cap is kept: a contract placed under either can still have its bonus raised')

        Config.Completion.Fulfilment = 'either'
        eq(s.app.handlers.rewardOptions(f.creator, {}).caps.fulfilment, 'either')
    end)

    it('answers the percentage it placed, which the confirmation is worded from', function()
        local s, f = shipped()
        local c = place(s, f, { baseline = { cash = 5000 } }, { bonusPercent = 50 })
        eq(s.projection.contract(c, 'CREATOR1').bonusPercent, 0)
    end)
end)

describe('a contract placed before the rule existed', function()
    --- Placed under 'either' and then stripped of the field, as a row stored
    --- by an older version is, on a server now shipping 'alive'.
    local function older(s, f, reward)
        local c = taken(s, f, reward or { baseline = { cash = 5000 }, bonus = { cash = 2500 } })
        s.storage.readContract(c.id).fulfilment_rule = nil
        Config.Completion.Fulfilment = 'alive'
        return c
    end

    it('reads as either, on the card and in the claim', function()
        local s = newStack()
        local f = fixture(s)
        Config.Completion.ExtraPhotoHosts = { 'cdn.fivemanage.com' }
        s.photo.loadAllowedHosts()
        local c = older(s, f)
        eq(s.projection.accepted('HITMAN01')[1].fulfilment, 'either')

        local before = world(s)
        local creatorCash = Env.players[1].PlayerData.money.cash
        local hitmanCash = Env.players[3].PlayerData.money.cash
        eq(killed(s), 1, 'a kill opens on it, as on the terms it was taken on')
        local token = s.photo.issue(f.hitman, c.id)
        truthy(token)
        local ok, err = s.photo.submit(f.hitman, token, URL)
        truthy(ok, tostring(err))
        eq(Env.players[3].PlayerData.money.cash - hitmanCash, 5000, 'the baseline for the kill')
        eq(Env.players[1].PlayerData.money.cash - creatorCash, 2500,
            'and its bonus back to the client, as before')
        conserved(s, before, 'an older contract paid for a kill')
    end)

    it('keeps its bonus working: raised, and paid on a live delivery', function()
        local s = newStack()
        local f = fixture(s)
        local c = older(s, f, { baseline = { cash = 5000 } })
        local before = world(s)
        truthy(s.amendments.improve(f.creator, c.id, CH.AMENDMENT.RAISE_BONUS, { percent = 50 }),
            'its bonus can still be raised')
        local cash = Env.players[3].PlayerData.money.cash
        inHand()
        eq(#delivered(s, c.id), 1)
        eq(Env.players[3].PlayerData.money.cash - cash, 7500, 'baseline and bonus')
        conserved(s, before, 'an older contract delivered alive')
    end)
end)

describe('a target named by a contract of each kind', function()
    --- One placed under 'alive' and one under 'either', both taken by the
    --- same hitman, by two different clients.
    local function both()
        local s, f = shipped()
        local alive = taken(s, f)
        Config.Completion.Fulfilment = 'either'
        Env.addPlayer({ source = 4, citizenid = 'CREATOR2', license = 'license:ddd',
            cash = 100000, bank = 100000, firstname = 'Lou', lastname = 'Fenn' })
        local either = s.contracts.create(s.identity.resolve(4), {
            targetCid = 'TARGET01', reason = 'Another debt', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 4000 } } })
        truthy(either, 'the second contract')
        truthy(s.contracts.accept(f.hitman, either.id, false))
        eq(s.storage.readContract(alive.id).fulfilment_rule, 'alive')
        eq(s.storage.readContract(either.id).fulfilment_rule, 'either')
        return s, f, alive, either
    end

    it('opens a kill only on the one a kill completes', function()
        local s, _, alive, either = both()
        eq(killed(s), 1, 'one kill opened')
        falsy(s.death.getPending(alive.id, 'HITMAN01'))
        truthy(s.death.getPending(either.id, 'HITMAN01'))
    end)

    it('still attributes an unreported death, whichever of them the pass reads first', function()
        local s, _, alive, either = both()
        shot(s)
        -- The live transfer first: the death it marks seen is the same one
        -- the other contract still needs attributed.
        s.death.watchTargets({ s.storage.readContract(alive.id), s.storage.readContract(either.id) })
        Env.advance(math.ceil(s.death.UNREPORTED_WAIT_MS / 1000) + 1)
        truthy(s.death.getPending(either.id, 'HITMAN01'), 'the kill is opened without a report')
        falsy(s.death.getPending(alive.id, 'HITMAN01'), 'and only where a kill counts')
    end)
end)

describe('the words for a live handover', function()
    --- Everything a player was told on this server is now said to whom:
    --- the person who placed the contract, never "the client", with the
    --- distance and the seconds from Config.Kidnap rather than written in.
    local function said(title)
        local out = {}
        for _, note in ipairs(Natives.calls.notifications or {}) do
            if not title or tostring(note.title) == title then out[#out + 1] = tostring(note.content) end
        end
        return table.concat(out, ' | ')
    end

    it('tells the person who placed it that a hitman is coming to them, alive', function()
        local s, f = shipped()
        local c = place(s, f, { baseline = { cash = 5000 } })
        Natives.calls.notifications = {}
        truthy(s.contracts.accept(f.hitman, c.id, true), 'taken anonymously')
        local note = said('Contract accepted')
        truthy(note:find("A hitman took your contract on Dana Reyes. They'll bring the target "
            .. 'to you alive — stay in the city and watch your messages.', 1, true), note)
        falsy(note:find('Rook', 1, true), 'an anonymous hitman is not named: ' .. note)
        falsy(note:lower():find('client', 1, true), note)
        falsy(note:lower():find('photo', 1, true), note)
    end)

    it('names a hitman who took it under their name, and counts a crowd', function()
        local s, f = shipped()
        local c = place(s, f, { baseline = { cash = 5000 } })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
            cash = 5000, bank = 5000, firstname = 'Kade', lastname = 'Wolfe' })
        Natives.calls.notifications = {}
        truthy(s.contracts.accept(s.identity.resolve(4), c.id, false))
        local note = said('Contract accepted')
        truthy(note:find('A hitman (Kade Wolfe) took your contract on Dana Reyes.', 1, true), note)
        truthy(note:find('2 hitmen are on it now.', 1, true), note)
    end)

    it('does not send them to their messages on a server without them', function()
        local s, f = shipped()
        Config.Relay.Enabled = false
        local c = place(s, f, { baseline = { cash = 5000 } })
        Natives.calls.notifications = {}
        truthy(s.contracts.accept(f.hitman, c.id, true))
        local note = said('Contract accepted')
        truthy(note:find('to you alive — stay in the city.', 1, true), note)
        falsy(note:find('messages', 1, true), note)
    end)

    it('keeps the old words on a contract a kill completes too', function()
        local s, f = shipped()
        Config.Completion.Fulfilment = 'either'
        local c = place(s, f, { baseline = { cash = 5000 } })
        Natives.calls.notifications = {}
        truthy(s.contracts.accept(f.hitman, c.id, true))
        local note = said('Contract accepted')
        truthy(note:find('Your contract on Dana Reyes has been accepted by an operative.', 1, true), note)
        falsy(note:find('bring the target to you alive', 1, true), note)
    end)

    it('tells the person who placed it how close to stand, from the config', function()
        local s, f = shipped()
        Config.Kidnap.Radius = 7.0
        Config.Kidnap.CountdownSeconds = 45
        local c = taken(s, f)
        inHand()
        Natives.calls.notifications = {}
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        local note = said('Handover starting')
        truthy(note:find('within 7 m of them both, for 45 seconds', 1, true), note)
        eq(s.kidnap.progress(c.id, 'HITMAN01').radius, 7.0,
            'the page is told the distance this countdown measures against')
    end)

    it('says the person who placed it had to be within the radius when they were not', function()
        local s, f = shipped()
        Config.Kidnap.Radius = 9.0
        local c = taken(s, f)
        inHand()
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        Env.players[1]._coords = { x = 3000.0, y = 3000.0, z = 30.0 }
        Natives.calls.notifications = {}
        for _ = 1, 10 do s.kidnap.tick(Config.Kidnap.MaxTotalGraceMs) end
        local note = said('Handover failed')
        truthy(note:find('The person who placed this contract did not arrive in time. They have '
            .. 'to be online and within 9 m of you and the target', 1, true), note)
        falsy(note:lower():find('client', 1, true), note)
    end)

    it('says what still pays when the target goes down mid-handover', function()
        local s, f = shipped()
        local c = taken(s, f)
        inHand()
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        Env.players[2].PlayerData.metadata.isdead = true
        Natives.calls.notifications = {}
        for _ = 1, 10 do s.kidnap.tick(Config.Kidnap.MaxTotalGraceMs) end
        local note = said('Handover failed')
        truthy(note:find('A handover has to be alive. Killing them does not count: once they '
            .. 'are back on their feet, bring them in alive again.', 1, true), note)
    end)

    it('names the person who placed it to an owner too, and no photograph', function()
        local s = shipped()
        local out = table.concat(s.admin.diagnose(0), '\n')
        truthy(out:find('brought alive to the person who placed it, who has to be there for the '
            .. 'handover', 1, true), out)
        local entry = s.settings.entry('Completion.Fulfilment')
        truthy(entry, 'the panel offers the rule')
        truthy(entry.about:find('brought alive to the person who placed the contract, who has '
            .. 'to be there for the handover', 1, true), entry.about)
        falsy(entry.about:lower():find('photo', 1, true),
            'kill photos ship off, so nothing about a photo: ' .. entry.about)
    end)
end)

--- The switches the owner runs (tests/harness/shipped.lua), all of them at
--- once, through the requests the page sends: what a player on the live
--- server meets from Place to paid. Every other stack here keeps kill
--- photos on and three collections from tests/run.lua.
describe('the shipped switches, from the Place form to paid', function()
    local Shipped = require('crimson-hitman.tests.harness.shipped')

    local function call(name, src, payload)
        local fire = Env.events['crimson-hitman:' .. name]
        if not fire then return { ok = false, err = 'NO SUCH HANDLER ' .. name } end
        Env.clientEvents = {}
        _G.source = src
        local fired, err = pcall(fire, payload or {})
        _G.source = nil
        if not fired then return { ok = false, err = 'THREW: ' .. tostring(err) } end
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:result' then return event.args[1] end
        end
        return { ok = false, err = 'NO REPLY' }
    end

    local function answered(name, src, payload)
        local reply = call(name, src, payload)
        truthy(reply.ok, name .. ' was refused: ' .. tostring(reply.err))
        return reply.data
    end

    local function money(src)
        local m = Env.players[src].PlayerData.money
        return m.cash + m.bank
    end

    it('are what config/config.lua ships', function()
        local file = Shipped.fromFile()
        for _, entry in ipairs(Shipped.VALUES) do
            local section, key, value = entry[1], entry[2], entry[3]
            local shipped = file[key]
            if section then shipped = file[section][key] end
            eq(shipped, value, ('Config.%s%s'):format(section and (section .. '.') or '', key))
        end
    end)

    it('place one collection, hand the target over in person, and pay without a photograph', function()
        local s = Shipped.newStack()
        local f = fixture(s)

        local wallet = answered('rewardOptions', 1, {})
        eq(wallet.caps.slots, 1, 'the form is told one collection')
        eq(wallet.caps.fulfilment, 'alive')
        eq(wallet.caps.minValue, 1000)

        local handle
        for _, row in ipairs(answered('browseTargets', 1, { scope = 'online', page = 1 }).people or {}) do
            if row.name == 'Dana Reyes' then handle = row.handle end
        end
        truthy(handle, 'the target is listed')

        local creatorBefore, hitmanBefore = money(1), money(3)
        local forged = call('create', 1, { target = handle, reason = 'Unpaid debt',
            mode = 'competitive', penaltyAmount = 1000,
            reward = { slots = { { baseline = { cash = 5000 } }, { baseline = { cash = 5000 } } } } })
        eq(forged.err, CH.ERR.INVALID_REWARD, 'a second collection is refused')
        eq(money(1), creatorBefore, 'and nothing was taken for it')

        local placed = answered('create', 1, { target = handle, reason = 'Unpaid debt',
            mode = 'competitive', penaltyAmount = 1000,
            reward = { slots = { { baseline = { cash = 5000 } } } } })
        local id = placed.id
        eq(s.storage.readContract(id).fulfilment_rule, CH.FULFILMENT_RULE.ALIVE)
        eq(money(1), creatorBefore - 5000)

        answered('accept', 3, { id = id, anonymous = false, penaltyAmount = 1000 })
        eq(money(3), hitmanBefore - 1000, 'the stake is taken')

        for _, src in ipairs({ 1, 2, 3 }) do
            Env.players[src]._coords = { x = AT.x, y = AT.y, z = AT.z }
        end
        Env.players[2].PlayerData.metadata.ishandcuffed = true
        Natives.calls.notifications = {}
        answered('armKidnap', 3, { id = id })
        truthy(answered('kidnapProgress', 3, { id = id }).required, 'the countdown is running')
        for _ = 1, math.floor(Config.Kidnap.CountdownSeconds * 1000 / Config.Kidnap.TickMs) + 1 do
            s.kidnap.tick(Config.Kidnap.TickMs)
        end

        eq(s.storage.readContract(id).state, CH.STATE.COMPLETED)
        eq(money(3), hitmanBefore + 5000, 'the hitman is paid, and the stake comes back')
        eq(money(1), creatorBefore - 5000, 'the creator paid the reward once')

        local told = {}
        for _, note in ipairs(Natives.calls.notifications) do
            if note.title ~= 'Handover starting' then
                told[#told + 1] = tostring(note.title) .. ': ' .. tostring(note.content)
            end
        end
        local said = table.concat(told, '\n')
        truthy(said:find('Contract fulfilled: Your contract was fulfilled by live delivery: the '
            .. 'target was handed over in person.', 1, true), said)
        falsy(said:find('Collection', 1, true), 'one collection is the whole contract: ' .. said)
        falsy(said:lower():find('photo', 1, true), 'and no photograph is mentioned: ' .. said)

        for _, src in ipairs({ 1, 3 }) do
            for _, entry in ipairs(answered('ledger', src, {}).entries or {}) do
                falsy(entry.photo, 'no Ledger row offers a photo')
            end
        end
        eq(#s.storage.photosOf('CREATOR1'), 0, 'and none is kept')

        Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
            cash = 50000, bank = 50000, firstname = 'Kade', lastname = 'Wolfe' })
        local again, err = s.contracts.create(s.identity.resolve(4), {
            targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        falsy(again, 'the target was just delivered')
        eq(err, CH.ERR.TARGET_RECENTLY_ON)
    end)

    --- W097, W012: the form said a kill does not complete one, staff
    --- switched the rule to 'either' before the tap, and the contract was
    --- placed so a kill paid its whole reward. Refused, with the rule now,
    --- and nothing taken.
    it('refuses a contract whose rule changed while the form was open', function()
        local s = Shipped.newStack()
        fixture(s)
        local shown = answered('rewardOptions', 1, {}).caps.fulfilment
        eq(shown, 'alive')
        local handle
        for _, row in ipairs(answered('browseTargets', 1, { scope = 'online', page = 1 }).people or {}) do
            if row.name == 'Dana Reyes' then handle = row.handle end
        end
        truthy(handle)

        Config.Completion.Fulfilment = 'either'
        local before = money(1)
        local refused = call('create', 1, { target = handle, reason = 'Unpaid debt',
            reward = { slots = { { baseline = { cash = 5000 } } } }, shown = { fulfilment = shown } })
        eq(refused.err, CH.ERR.RULE_CHANGED)
        eq(refused.data and refused.data.fulfilment, 'either', 'with the rule now')
        eq(money(1), before, 'nothing taken')
        eq(#s.storage.liveContracts(), 0, 'nothing placed')

        local placed = answered('create', 1, { target = handle, reason = 'Unpaid debt',
            reward = { slots = { { baseline = { cash = 5000 } } } }, shown = { fulfilment = 'either' } })
        eq(s.storage.readContract(placed.id).fulfilment_rule, 'either', 'placed under the rule shown')
    end)
end)
