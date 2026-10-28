--- The two informants (server/informant.lua): the placer's
--- (Config.PlacerInformant), which lets the person who placed a contract
--- pay for a chance to find out who took it, and the target's
--- (Config.Informant), which lets a target pay for a chance to find out who
--- is after them, an operative or the placer.
---
--- Every roll is forced through the harness's random source
--- (Informant.setRandom): 1 lands under any chance above 0, 100 under none
--- below 100.

local HIT, MISS = 1, 100

--- Force the next rolls, in order; anything after them misses. Answers a
--- function that says how many numbers were drawn.
local function force(s, ...)
    local queue, drawn = { ... }, 0
    s.informant.setRandom(function(lo, hi)
        eq(lo, 1, 'a roll draws from 1')
        eq(hi, 100, 'to 100')
        drawn = drawn + 1
        return table.remove(queue, 1) or MISS
    end)
    return function() return drawn end
end

--- A contract on Dana Reyes, placed by Vic Marlowe (anonymously with
--- `anonCreator`), and taken by Rook Ash (anonymously, unless `namedHitman`).
local function setup(opts)
    opts = opts or {}
    local s = newStack()
    local f = fixture(s)
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 } }, anonymous = opts.anonCreator == true,
    })
    truthy(c, 'placed')
    if opts.accept ~= false then
        truthy(s.contracts.accept(f.hitman, c.id, opts.namedHitman ~= true), 'taken')
    end
    Env.players[1].PlayerData.money.bank = 100000
    Env.players[2].PlayerData.money.bank = 100000
    -- Past the alert's wait, so the contract is on the target's On me.
    Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
    return s, f, c
end

local function secondOperative(s, c, anon)
    Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
        cash = 5000, bank = 5000, firstname = 'Nel', lastname = 'Vey' })
    truthy(s.contracts.accept(s.identity.resolve(4), c.id, anon ~= false), 'a second operative')
    return s.identity.resolve(4)
end

local function view(s, c, cid)
    return s.projection.contract(s.storage.readContract(c.id), cid)
end

local function placerPick(s, c, label)
    for _, p in ipairs(view(s, c, 'CREATOR1').placerInformantPicks or {}) do
        if not label or p.label == label then return p.pick end
    end
    return nil
end

local function targetPick(s, c, label)
    for _, p in ipairs(view(s, c, 'TARGET01').informantPicks or {}) do
        if p.pick ~= 'placer' and (not label or p.label == label
            or p.label:sub(1, #label + 2) == label .. ' (') then return p.pick end
    end
    return nil
end

local function bank(src) return Env.players[src].PlayerData.money.bank end

--- Every player's money together, and what the contracts hold.
local function total(s)
    local sum = 0
    for _, p in pairs(Env.players) do sum = sum + p.PlayerData.money.cash + p.PlayerData.money.bank end
    for _, c in ipairs(s.storage.allContracts()) do sum = sum + s.escrow.moneyValue(c.id) end
    return sum
end

local function placerShown()
    return { cost = Config.PlacerInformant.Cost, account = Config.PlacerInformant.Account }
end

local function targetShown()
    return { cost = Config.Informant.Cost, account = Config.Informant.Account }
end

--- Notices that say a placer found an operative out, and who got them.
local function alerts()
    local out = {}
    for _, n in ipairs(Natives.calls.notifications) do
        if tostring(n.content):find('found out who you are', 1, true) then out[#out + 1] = n end
    end
    return out
end

local function auditRows(s, action)
    s.audit.flush()
    local out = {}
    for _, row in ipairs(s.storage.readAudit()) do
        if row.action == action then out[#out + 1] = row end
    end
    return out
end

--------------------------------------------------------------------------
-- The placer's informant
--------------------------------------------------------------------------

describe('the placer\'s informant', function()
    it('ships with the figures the owner asked for', function()
        local p = Config.PlacerInformant
        eq(p.Enabled, true)
        eq(p.Cost, 25000)
        eq(p.Account, 'bank')
        eq(p.RevealChancePercent, 20)
        eq(p.AlertChancePercent, 20)
        eq(p.RevealMode, 'name')
        eq(p.MaxPurchasesPerContract, 2)
        eq(p.CooldownMinutes, 10)
    end)

    it('names the operative on a reveal, charged once, and keeps it on the card', function()
        local s, f, c = setup()
        force(s, HIT, MISS)
        local before, all = bank(1), total(s)
        local pick = placerPick(s, c)
        truthy(pick, 'the card offers the operative')
        local ok, err, data = s.informant.placerBuy(f.creator, c.id, placerShown(), pick)
        truthy(ok, tostring(err))
        eq(data.found, true)
        eq(data.name, 'Rook Ash')
        eq(data.label, 'Operative #1')
        falsy(data.cid or data.citizenid or data.hitman_cid, 'never a citizen id')
        eq(before - bank(1), 25000, 'charged once')
        eq(all - total(s), 25000, 'and the money went to nobody')
        local card = view(s, c, 'CREATOR1')
        eq(#card.placerInformantFound, 1)
        eq(card.placerInformantFound[1].text, 'Rook Ash', 'kept on the contract view')
        eq(card.placerInformantFound[1].label, 'Operative #1')
        eq(#(card.placerInformantPicks or {}), 0, 'and not offered again')
        eq(card.placerInformantLeft, 1)
    end)

    it('charges once on a miss too, and says so plainly', function()
        local s, f, c = setup()
        force(s, MISS)
        local before, all = bank(1), total(s)
        local ok, err, data = s.informant.placerBuy(f.creator, c.id, placerShown(), placerPick(s, c))
        truthy(ok, tostring(err))
        eq(data.found, false)
        eq(data.message, 'Your informant could not find out who they are.')
        falsy(data.name, 'no name on a miss')
        eq(before - bank(1), 25000, 'the price is paid whatever the roll says')
        eq(all - total(s), 25000, 'to nobody')
        eq(view(s, c, 'CREATOR1').placerInformantFound, nil, 'nothing found, nothing kept')
    end)

    it('rolls the alert only after a reveal, and alerts on a hit', function()
        local s, f, c = setup()
        local drawn = force(s, HIT, HIT)
        Natives.calls.notifications = {}
        truthy(s.informant.placerBuy(f.creator, c.id, placerShown(), placerPick(s, c)))
        eq(drawn(), 2, 'a reveal, then the alert')
        local said = alerts()
        eq(#said, 1, 'the operative is told')
        eq(said[1].content, 'The person who placed one of your contracts has found out who you '
            .. 'are: your contract on Dana Reyes.')
        falsy(said[1].content:find('Vic', 1, true), 'never the placer')
        local rows = auditRows(s, 'placer_informant_bought')
        eq(rows[1].detail.alerted, true)
    end)

    it('says nothing to the operative on a lost alert roll', function()
        local s, f, c = setup()
        local drawn = force(s, HIT, MISS)
        Natives.calls.notifications = {}
        truthy(s.informant.placerBuy(f.creator, c.id, placerShown(), placerPick(s, c)))
        eq(drawn(), 2)
        eq(#alerts(), 0, 'not told')
        eq(#Natives.calls.notifications, 0, 'nothing at all')
    end)

    it('never rolls the alert after a miss, and tells nobody', function()
        local s, f, c = setup()
        local drawn = force(s, MISS, HIT)
        Natives.calls.notifications = {}
        truthy(s.informant.placerBuy(f.creator, c.id, placerShown(), placerPick(s, c)))
        eq(drawn(), 1, 'one roll only')
        eq(#Natives.calls.notifications, 0, 'nothing said to anybody')
    end)

    it('is open to an anonymous placer, whose name the alert never carries', function()
        local s, f, c = setup({ anonCreator = true })
        force(s, HIT, HIT)
        Natives.calls.notifications = {}
        local ok, err, data = s.informant.placerBuy(f.creator, c.id, placerShown(), placerPick(s, c))
        truthy(ok, tostring(err))
        eq(data.name, 'Rook Ash')
        local said = alerts()
        eq(#said, 1)
        falsy(said[1].content:find('Vic', 1, true) or said[1].content:find('Marlowe', 1, true)
            or said[1].content:find('CREATOR1', 1, true), 'the alert never names them')
        falsy(said[1].title:find('Vic', 1, true), 'nor its title')
    end)

    it('lists the operatives anonymously, under stable handles that are not their rows', function()
        local s, f, c = setup()
        secondOperative(s, c)
        local first = view(s, c, 'CREATOR1').placerInformantPicks
        eq(#first, 2)
        eq(first[1].label, 'Operative #1')
        eq(first[2].label, 'Operative #2')
        for _, p in ipairs(first) do
            falsy(p.pick:find('HITMAN', 1, true), 'a handle is not a citizen id')
            falsy(p.name, 'and carries no name')
        end
        local again = view(s, c, 'CREATOR1').placerInformantPicks
        eq(again[1].pick, first[1].pick, 'the same handle on the next read')
        eq(again[2].pick, first[2].pick)
        falsy(first[1].pick == first[2].pick, 'one each')
        local _ = f
    end)

    it('leaves out an operative who took it under their name: already known', function()
        local s, f, c = setup({ namedHitman = true })
        eq(#(view(s, c, 'CREATOR1').placerInformantPicks or {}), 0)
        local _ = f
    end)

    describe('refusals, with nothing charged', function()
        local function refused(s, actor, c, pick, want, shown)
            local before, all = total(s), bank(actor.source)
            local ok, err = s.informant.placerBuy(actor, c.id, shown or placerShown(), pick)
            falsy(ok, 'refused')
            eq(err, want)
            eq(total(s), before, 'nothing moved')
            eq(bank(actor.source), all, 'nothing charged')
        end

        it('a forged handle', function()
            local s, f, c = setup()
            placerPick(s, c)
            refused(s, f.creator, c, 'op_forged_handle', CH.ERR.OPERATIVE_GONE)
            refused(s, f.creator, c, 'HITMAN01', CH.ERR.OPERATIVE_GONE)
        end)

        it('a handle from another contract', function()
            local s, f, c = setup()
            local other = s.contracts.create(f.creator, {
                targetCid = 'HITMAN01', reason = 'x', reward = { baseline = { cash = 5000 } } })
            truthy(other)
            refused(s, f.creator, other, placerPick(s, c), CH.ERR.OPERATIVE_GONE)
        end)

        it('an operative who has left', function()
            local s, f, c = setup()
            local pick = placerPick(s, c)
            truthy(s.contracts.abandon(f.hitman, c.id))
            refused(s, f.creator, c, pick, CH.ERR.OPERATIVE_GONE)
        end)

        it('a stale handle after a restart of the informant', function()
            local s, f, c = setup()
            local pick = placerPick(s, c)
            s.informant.init({ storage = s.storage, identity = s.identity, audit = s.audit,
                contracts = s.contracts, notify = s.notify })
            refused(s, f.creator, c, pick, CH.ERR.OPERATIVE_GONE)
        end)

        it('anybody but the placer: the target, the operative, a stranger', function()
            local s, f, c = setup()
            local pick = placerPick(s, c)
            refused(s, f.target, c, pick, CH.ERR.NOT_PARTICIPANT)
            refused(s, f.hitman, c, pick, CH.ERR.NOT_PARTICIPANT)
            Env.addPlayer({ source = 9, citizenid = 'NOSEY001', license = 'license:n', bank = 99999 })
            refused(s, s.identity.resolve(9), c, pick, CH.ERR.NOT_PARTICIPANT)
        end)

        it('a placer now on a barred job', function()
            local s, f, c = setup()
            local pick = placerPick(s, c)
            Env.players[1].PlayerData.job = { name = 'police', type = 'leo', onduty = true }
            refused(s, s.identity.resolve(1), c, pick, CH.ERR.BLACKLISTED_JOB)
        end)

        it('a price that moved since the dialog showed it, with the price now', function()
            local s, f, c = setup()
            local before = bank(1)
            local ok, err, data = s.informant.placerBuy(f.creator, c.id,
                { cost = 1000, account = 'bank' }, placerPick(s, c))
            falsy(ok)
            eq(err, CH.ERR.TERMS_CHANGED)
            eq(data.cost, 25000)
            eq(data.account, 'bank')
            eq(bank(1), before)
        end)

        it('a placer who cannot pay', function()
            local s, f, c = setup()
            Env.players[1].PlayerData.money.bank = 100
            refused(s, f.creator, c, placerPick(s, c), CH.ERR.INSUFFICIENT)
        end)

        it('a contract that has ended', function()
            local s, f, c = setup()
            local pick = placerPick(s, c)
            truthy(s.contracts.resolve(c.id, CH.STATE.EXPIRED, f.creator.cid, nil, 'expired'))
            refused(s, f.creator, c, pick, CH.ERR.ALREADY_SETTLED)
        end)

        it('the feature switched off, with what was found kept', function()
            local s, f, c = setup()
            force(s, HIT, MISS)
            truthy(s.informant.placerBuy(f.creator, c.id, placerShown(), placerPick(s, c)))
            local other = secondOperative(s, c)
            local pick = placerPick(s, c)
            Config.PlacerInformant.Enabled = false
            refused(s, f.creator, c, pick, CH.ERR.FEATURE_OFF)
            local card = view(s, c, 'CREATOR1')
            eq(card.placerInformantFound[1].text, 'Rook Ash', 'a name already found stays')
            eq(card.placerInformantPicks, nil, 'nothing more is offered')
            eq(card.placerInformantLeft, nil)
            local _ = other
        end)

        it('an operative already found out', function()
            local s, f, c = setup()
            force(s, HIT, MISS)
            local pick = placerPick(s, c)
            truthy(s.informant.placerBuy(f.creator, c.id, placerShown(), pick))
            Env.advance(Config.PlacerInformant.CooldownMinutes * 60 + 1)
            refused(s, f.creator, c, pick, CH.ERR.ALREADY_REVEALED)
        end)

        it('a named operative, who is known already', function()
            local s, f, c = setup()
            secondOperative(s, c, false)
            -- Their handle, minted for the target's card, is still not sold
            -- to the placer, who sees the name on their roster.
            local named = targetPick(s, c, 'Operative #2')
            truthy(named)
            refused(s, f.creator, c, named, CH.ERR.ALREADY_REVEALED)
        end)
    end)

    describe('limits', function()
        it('waits CooldownMinutes between look-ups, and says how long', function()
            local s, f, c = setup()
            secondOperative(s, c)
            force(s, MISS, MISS)
            truthy(s.informant.placerBuy(f.creator, c.id, placerShown(), placerPick(s, c, 'Operative #1')))
            local before = bank(1)
            local ok, err, data = s.informant.placerBuy(f.creator, c.id, placerShown(),
                placerPick(s, c, 'Operative #2'))
            falsy(ok)
            eq(err, CH.ERR.INFORMANT_COOLDOWN)
            eq(data.minutes, 10)
            eq(bank(1), before, 'nothing charged')
            eq(view(s, c, 'CREATOR1').placerInformantWait, 600, 'the card says how long')
            Env.advance(600)
            truthy(s.informant.placerBuy(f.creator, c.id, placerShown(), placerPick(s, c, 'Operative #2')))
        end)

        it('sells at most MaxPurchasesPerContract per placer per contract', function()
            local s, f, c = setup()
            force(s, MISS, MISS, MISS)
            local pick = placerPick(s, c)
            for _ = 1, 2 do
                truthy(s.informant.placerBuy(f.creator, c.id, placerShown(), pick))
                Env.advance(601)
            end
            eq(view(s, c, 'CREATOR1').placerInformantLeft, 0)
            local before = bank(1)
            local ok, err = s.informant.placerBuy(f.creator, c.id, placerShown(), pick)
            falsy(ok)
            eq(err, CH.ERR.LIMIT_REACHED)
            eq(bank(1), before)
        end)
    end)

    it('charges once on a double tap, through the app', function()
        local s, f, c = setup()
        force(s, MISS)
        local pick = placerPick(s, c)
        local replies = {}
        local inner
        -- The second tap lands while the first is being charged.
        local remove = Env.players[1].Functions.RemoveMoney
        Env.players[1].Functions.RemoveMoney = function(...)
            if not inner then
                inner = table.pack(s.informant.placerBuy(f.creator, c.id, placerShown(), pick))
            end
            return remove(...)
        end
        replies[1] = table.pack(s.informant.placerBuy(f.creator, c.id, placerShown(), pick))
        truthy(replies[1][1], 'the first goes through')
        falsy(inner[1], 'the second is refused')
        eq(inner[2], CH.ERR.BUSY)
        eq(100000 - bank(1), 25000, 'charged once')
    end)

    describe('refunds when it goes before the roll', function()
        it('the operative leaving mid-purchase', function()
            local s, f, c = setup()
            local drawn = force(s, HIT, HIT)
            local pick = placerPick(s, c)
            local before, all = bank(1), total(s)
            local remove = Env.players[1].Functions.RemoveMoney
            Env.players[1].Functions.RemoveMoney = function(...)
                local out = table.pack(remove(...))
                truthy(s.contracts.abandon(f.hitman, c.id), 'walked away meanwhile')
                return table.unpack(out, 1, out.n)
            end
            local hitmanBefore = bank(3) + Env.players[3].PlayerData.money.cash
            local ok, err = s.informant.placerBuy(f.creator, c.id, placerShown(), pick)
            falsy(ok)
            eq(err, CH.ERR.OPERATIVE_GONE)
            eq(bank(1), before, 'given back')
            eq(total(s), all, 'nothing lost')
            eq(drawn(), 0, 'no roll was made')
            eq(bank(3) + Env.players[3].PlayerData.money.cash, hitmanBefore, 'the operative paid nothing')
            eq(#auditRows(s, 'placer_informant_refunded'), 1)
            eq(#view(s, c, 'CREATOR1').placerInformantPicks, 0, 'nobody left to offer')
        end)

        it('a read that raised between the charge and the roll', function()
            local s, f, c = setup()
            local drawn = force(s, HIT)
            local pick = placerPick(s, c)
            local before = bank(1)
            local remove, read = Env.players[1].Functions.RemoveMoney, s.storage.readContract
            local armed = false
            Env.players[1].Functions.RemoveMoney = function(...)
                armed = true
                return remove(...)
            end
            s.storage.readContract = function(...)
                if armed then error('the connection dropped', 0) end
                return read(...)
            end
            local ran = pcall(s.informant.placerBuy, f.creator, c.id, placerShown(), pick)
            s.storage.readContract = read
            falsy(ran, 'the raise is the handler\'s to answer')
            eq(bank(1), before, 'and the price came back first')
            eq(drawn(), 0)
        end)

        it('the contract ending mid-purchase', function()
            local s, f, c = setup()
            local drawn = force(s, HIT)
            local pick = placerPick(s, c)
            local before = bank(1)
            local remove = Env.players[1].Functions.RemoveMoney
            Env.players[1].Functions.RemoveMoney = function(...)
                local out = table.pack(remove(...))
                Env.players[1].Functions.RemoveMoney = remove
                truthy(s.contracts.resolve(c.id, CH.STATE.EXPIRED, f.creator.cid, nil, 'expired'))
                return table.unpack(out, 1, out.n)
            end
            local ok, err = s.informant.placerBuy(f.creator, c.id, placerShown(), pick)
            falsy(ok)
            eq(err, CH.ERR.ALREADY_SETTLED)
            eq(drawn(), 0)
            eq(bank(1), before, 'the price back')
        end)
    end)

    it('keeps an audit row, scrubbed for staff without the identity ACE', function()
        local s, f, c = setup({ anonCreator = true })
        force(s, HIT, MISS)
        truthy(s.informant.placerBuy(f.creator, c.id, placerShown(), placerPick(s, c)))
        local rows = auditRows(s, 'placer_informant_bought')
        eq(#rows, 1)
        eq(rows[1].actor_cid, 'CREATOR1')
        eq(rows[1].contract_id, c.id)
        eq(rows[1].detail.amount, 25000)
        eq(rows[1].detail.hitman, 'HITMAN01')
        eq(rows[1].detail.outcome, 'revealed')

        Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001' })
        Env.addPlayer({ source = 8, citizenid = 'UNMASK01', license = 'license:UNMASK01' })
        Env.aces[6] = { ['crimson.admin'] = true }
        Env.aces[8] = { ['crimson.admin'] = true, ['crimson.identity'] = true }
        Config.Cooldowns.admin = { per = 10, burst = 500 }
        s.bridges.install(s)
        local function logs(src)
            Env.clientEvents = {}
            _G.source = src
            Env.events['crimson-hitman:admin']({ op = 'logs',
                data = { action = 'placer_informant_bought', limit = 10 }, __rid = 7 })
            _G.source = nil
            for _, e in ipairs(Env.clientEvents) do
                if e.name == 'crimson-hitman:adminResult' then return e.args[1].data.rows end
            end
        end
        local plain = json.encode(logs(6))
        falsy(plain:find('CREATOR1', 1, true), 'the placer\'s id is scrubbed: ' .. plain)
        falsy(plain:find('HITMAN01', 1, true), 'and the operative\'s')
        truthy(plain:find('25000', 1, true), 'the amount stays')
        local whole = json.encode(logs(8))
        truthy(whole:find('HITMAN01', 1, true), 'whole for staff with the identity ACE')
    end)

    describe('anonymity', function()
        it('goes to the placer alone: not the target, not other operatives, not the board', function()
            local s, f, c = setup()
            local other = secondOperative(s, c)
            force(s, HIT, MISS)
            truthy(s.informant.placerBuy(f.creator, c.id, placerShown(), placerPick(s, c, 'Operative #1')))
            local function says(value) return json.encode(value):find('Rook', 1, true) ~= nil end
            truthy(says(view(s, c, 'CREATOR1')), 'the placer has it')
            falsy(says(s.projection.onMe('TARGET01')), 'the target never learns of it')
            falsy(says(view(s, c, other.cid)), 'nor another operative')
            falsy(says(s.projection.accepted(other.cid)), 'nor on their own tab')
            falsy(says(s.projection.listing('NOSEY001')), 'nor the board')
            falsy(says(s.projection.whitelistedView('TARGET01', { name = 'police', type = 'leo' })),
                'nor the whitelisted-job view')
            local dispatched = json.encode(Natives.calls.dispatch)
            falsy(dispatched:find('Rook', 1, true), 'nor the advisory')
        end)

        it('never tells the operative who the placer is', function()
            local s, f, c = setup()
            force(s, HIT, HIT)
            truthy(s.informant.placerBuy(f.creator, c.id, placerShown(), placerPick(s, c)))
            -- Placed under their name, so the card names them as before; the
            -- alert adds nothing to it.
            local said = alerts()
            eq(#said, 1)
            falsy(json.encode(said):find('Vic', 1, true), 'not in the alert')
            falsy(json.encode(said):find('CREATOR1', 1, true))
            falsy(view(s, c, 'HITMAN01').placerInformantFound, 'the operative sees no informant record')
            falsy(view(s, c, 'HITMAN01').placerInformantPicks)
        end)
    end)

    it('goes through the app, with its own rate-limit bucket', function()
        local s, f, c = setup()
        force(s, MISS)
        Config.Cooldowns.informant = { per = 3600, burst = 1 }
        truthy(s.ratelimit.check(f.target, 'informant'), 'the target\'s bucket spent')
        Env.clientEvents = {}
        _G.source = 1
        Env.events['crimson-hitman:placerInformant']({ id = c.id, shown = placerShown(),
            pick = placerPick(s, c), __rid = 5 })
        _G.source = nil
        local reply
        for _, e in ipairs(Env.clientEvents) do
            if e.target == 1 and type(e.args[1]) == 'table' and e.args[1].rid == 5 then reply = e.args[1] end
        end
        truthy(reply and reply.ok, 'answered: ' .. json.encode(reply))
        eq(reply.data.message, 'Your informant could not find out who they are.')
    end)
end)

--------------------------------------------------------------------------
-- The target's informant
--------------------------------------------------------------------------

describe('the target\'s informant', function()
    it('ships at a 10% chance and two look-ups, with the proximity rule gone', function()
        eq(Config.Informant.RevealChancePercent, 10)
        eq(Config.Informant.MaxPurchasesPerContract, 2)
        eq(Config.Informant.RequireProximity, nil)
        eq(Config.Informant.ProximityWindowMinutes, nil)
    end)

    it('names an operative on a hit, charged once, and keeps it on On me', function()
        local s, f, c = setup()
        force(s, HIT)
        local before, all = bank(2), total(s)
        local ok, err, data = s.informant.buy(f.target, c.id, targetShown(), targetPick(s, c))
        truthy(ok, tostring(err))
        eq(data.found, true)
        eq(data.name, 'Rook Ash')
        eq(before - bank(2), 25000, 'charged once')
        eq(all - total(s), 25000, 'to nobody')
        local onMe = s.projection.onMe('TARGET01')[1]
        eq(onMe.informantFound[1].text, 'Rook Ash', 'kept on their On me view')
        eq(onMe.informantLeft, 1)
    end)

    it('says it could not find out on a miss, charged once all the same', function()
        local s, f, c = setup()
        force(s, MISS)
        local before = bank(2)
        local ok, err, data = s.informant.buy(f.target, c.id, targetShown(), targetPick(s, c))
        truthy(ok, tostring(err))
        eq(data.found, false)
        eq(data.message, 'Your informant could not find out who it is.')
        eq(before - bank(2), 25000)
        eq(s.projection.onMe('TARGET01')[1].informantFound, nil)
    end)

    it('offers an operative never seen near the target', function()
        local s, f, c = setup()
        -- A mile apart, and the sampler has looked.
        Env.players[2]._coords = { x = 0.0, y = 0.0, z = 30.0 }
        Env.players[3]._coords = { x = 3000.0, y = 3000.0, z = 30.0 }
        s.death.watchTargets(s.storage.allContracts())
        force(s, HIT)
        local ok, err, data = s.informant.buy(f.target, c.id, targetShown(), targetPick(s, c))
        truthy(ok, tostring(err))
        eq(data.name, 'Rook Ash')
    end)

    it('offers every active operative and the placer', function()
        local s, f, c = setup({ anonCreator = true })
        secondOperative(s, c)
        local picks = view(s, c, 'TARGET01').informantPicks
        eq(#picks, 3)
        eq(picks[1].label, 'Operative #1')
        eq(picks[2].label, 'Operative #2')
        eq(picks[3].pick, 'placer')
        eq(picks[3].label, 'The person who placed it')
        falsy(picks[3].known)
        local _ = f
    end)

    it('finds out an anonymous placer on a hit', function()
        local s, f, c = setup({ anonCreator = true })
        force(s, HIT)
        local ok, err, data = s.informant.buy(f.target, c.id, targetShown(), 'placer')
        truthy(ok, tostring(err))
        eq(data.name, 'Vic Marlowe')
        eq(data.label, 'The person who placed it')
        local onMe = s.projection.onMe('TARGET01')[1]
        eq(onMe.informantFound[1].text, 'Vic Marlowe')
        eq(onMe.creatorName, nil, 'the card itself still names nobody')
    end)

    it('does not sell a named placer, who is known already', function()
        local s, f, c = setup()
        local before = bank(2)
        local ok, err = s.informant.buy(f.target, c.id, targetShown(), 'placer')
        falsy(ok)
        eq(err, CH.ERR.PLACER_KNOWN)
        eq(bank(2), before, 'nothing charged')
        local placer = view(s, c, 'TARGET01').informantPicks[2]
        eq(placer.pick, 'placer')
        eq(placer.known, true, 'the card says so')
        eq(placer.named, true)
    end)

    it('caps look-ups at two across both kinds', function()
        local s, f, c = setup({ anonCreator = true })
        force(s, MISS, MISS, MISS)
        truthy(s.informant.buy(f.target, c.id, targetShown(), targetPick(s, c)))
        truthy(s.informant.buy(f.target, c.id, targetShown(), 'placer'))
        local before = bank(2)
        Env.advance(Config.Informant.RerollLockMinutes * 60 + 1)
        local ok, err = s.informant.buy(f.target, c.id, targetShown(), targetPick(s, c))
        falsy(ok)
        eq(err, CH.ERR.LIMIT_REACHED)
        eq(bank(2), before)
        eq(view(s, c, 'TARGET01').informantLeft, 0)
    end)

    it('repeats a miss on the same pick inside the reroll lock, free and uncounted', function()
        local s, f, c = setup()
        local drawn = force(s, MISS, HIT)
        local pick = targetPick(s, c)
        truthy(s.informant.buy(f.target, c.id, targetShown(), pick))
        local before = bank(2)
        local ok, _, data = s.informant.buy(f.target, c.id, targetShown(), pick)
        truthy(ok)
        eq(data.found, false)
        eq(data.repeated, true)
        eq(bank(2), before, 'free')
        eq(drawn(), 1, 'no second roll')
        eq(view(s, c, 'TARGET01').informantLeft, 1, 'and no attempt spent')
        Env.advance(Config.Informant.RerollLockMinutes * 60)
        ok, _, data = s.informant.buy(f.target, c.id, targetShown(), pick)
        truthy(ok)
        eq(data.name, 'Rook Ash', 'after the lock, a fresh roll')
    end)

    describe('a member of a whitelisted job', function()
        it('is refused with nothing charged, for operatives and placer alike', function()
            local s, f, c = setup({ anonCreator = true })
            local pick = targetPick(s, c)
            -- The contract recorded them as protected when it was placed.
            s.storage.writeContract((function()
                local row = s.storage.readContract(c.id)
                row.target_protected = true
                return row
            end)())
            local before = bank(2)
            for _, which in ipairs({ pick, 'placer' }) do
                local ok, err = s.informant.buy(f.target, c.id, targetShown(), which)
                falsy(ok)
                eq(err, CH.ERR.INFORMANT_PROTECTED)
            end
            eq(bank(2), before, 'nothing charged')
            local onMe = view(s, c, 'TARGET01')
            eq(onMe.informantPicks, nil, 'the option is not offered')
            eq(onMe.informantLeft, nil)
        end)

        it('is refused while on a barred job now', function()
            local s, _, c = setup()
            local pick = targetPick(s, c)
            Env.players[2].PlayerData.job = { name = 'police', type = 'leo', onduty = true }
            local before = bank(2)
            local ok, err = s.informant.buy(s.identity.resolve(2), c.id, targetShown(), pick)
            falsy(ok)
            eq(err, CH.ERR.INFORMANT_PROTECTED)
            eq(bank(2), before)
        end)
    end)

    describe('refusals, with nothing charged', function()
        it('a forged or stale pick, and anybody but the target', function()
            local s, f, c = setup()
            local pick = targetPick(s, c)
            local before = total(s)
            eq(select(2, s.informant.buy(f.target, c.id, targetShown(), 'op_forged_xx')),
                CH.ERR.OPERATIVE_GONE)
            eq(select(2, s.informant.buy(f.target, c.id, targetShown(), 'HITMAN01')),
                CH.ERR.OPERATIVE_GONE)
            eq(select(2, s.informant.buy(f.creator, c.id, targetShown(), pick)),
                CH.ERR.NOT_PARTICIPANT, 'the placer has their own informant')
            eq(select(2, s.informant.buy(f.hitman, c.id, targetShown(), pick)),
                CH.ERR.NOT_PARTICIPANT)
            eq(select(2, s.informant.buy(f.target, c.id, targetShown(), nil)), CH.ERR.INVALID_INPUT)
            truthy(s.contracts.abandon(f.hitman, c.id))
            eq(select(2, s.informant.buy(f.target, c.id, targetShown(), pick)),
                CH.ERR.OPERATIVE_GONE, 'one who left')
            eq(total(s), before, 'nothing moved')
        end)

        it('a price that moved', function()
            local s, f, c = setup()
            local ok, err, data = s.informant.buy(f.target, c.id,
                { cost = 1, account = 'bank' }, targetPick(s, c))
            falsy(ok)
            eq(err, CH.ERR.TERMS_CHANGED)
            eq(data.cost, 25000)
        end)
    end)

    it('refunds when the operative leaves between the charge and the roll', function()
        local s, f, c = setup()
        local drawn = force(s, HIT)
        local pick = targetPick(s, c)
        local before = bank(2)
        local remove = Env.players[2].Functions.RemoveMoney
        Env.players[2].Functions.RemoveMoney = function(...)
            local out = table.pack(remove(...))
            Env.players[2].Functions.RemoveMoney = remove
            truthy(s.contracts.abandon(f.hitman, c.id))
            return table.unpack(out, 1, out.n)
        end
        local ok, err = s.informant.buy(f.target, c.id, targetShown(), pick)
        falsy(ok)
        eq(err, CH.ERR.OPERATIVE_GONE)
        eq(bank(2), before, 'given back')
        eq(drawn(), 0)
    end)

    it('tells nobody either way: not the operative, not the placer', function()
        local s, f, c = setup({ anonCreator = true })
        force(s, HIT, HIT)
        Natives.calls.notifications = {}
        truthy(s.informant.buy(f.target, c.id, targetShown(), targetPick(s, c)))
        truthy(s.informant.buy(f.target, c.id, targetShown(), 'placer'))
        eq(#Natives.calls.notifications, 0, 'no notice to anybody')
        local creator = view(s, c, 'CREATOR1')
        falsy(creator.informantFound, 'the placer\'s card says nothing')
        falsy(creator.placerInformantFound)
        falsy(view(s, c, 'HITMAN01').informantFound, 'nor the operative\'s')
    end)
end)

--------------------------------------------------------------------------
-- Settings: the admin panel's switch and limits, and the start's checks
--------------------------------------------------------------------------

describe('the informants in the admin panel', function()
    it('offers the placer\'s switch, and every limit the owner asked for', function()
        local s = newStack()
        local keys = {}
        for _, entry in ipairs(s.settings.CATALOGUE) do keys[entry.key] = entry end
        eq(keys['PlacerInformant.Enabled'].section, 'features')
        for _, key in ipairs({ 'PlacerInformant.Cost', 'PlacerInformant.RevealChancePercent',
            'PlacerInformant.AlertChancePercent', 'PlacerInformant.MaxPurchasesPerContract',
            'PlacerInformant.CooldownMinutes', 'Informant.RevealChancePercent' }) do
            truthy(keys[key], key .. ' is in the panel')
            eq(keys[key].section, 'limits', key)
        end
        eq(keys['Informant.RequireProximity'], nil, 'the proximity switch is gone')
        eq(keys['PlacerInformant.RevealChancePercent'].max, 100)
        eq(keys['PlacerInformant.AlertChancePercent'].min, 0)
    end)

    it('keeps the placer\'s settings across a restart', function()
        Env.reset()
        Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
        Natives.resetResourceStates()
        resetConfig()
        Config.Database.Mode = 'json'
        Natives.files = {}
        for name in pairs(package.loaded) do
            if type(name) == 'string' and name:sub(1, 7) == 'server.' then package.loaded[name] = nil end
        end
        local s = require('server.main').start()
        truthy(s.settings.set('PlacerInformant.Enabled', false, 'ADMIN001'))
        truthy(s.settings.set('PlacerInformant.AlertChancePercent', 55, 'ADMIN001'))
        truthy(s.settings.set('Informant.RevealChancePercent', 35, 'ADMIN001'))
        for name in pairs(package.loaded) do
            if type(name) == 'string' and name:sub(1, 7) == 'server.' then package.loaded[name] = nil end
        end
        Env.events, Env.clientEvents, Env.notifications = {}, {}, {}
        Env.handlers, Env.threads, Env.timers, Env.commands = {}, {}, {}, {}
        resetConfig()
        -- Off for whitelisted-job targets too, so none is sold anywhere.
        Config.InformantsWhitelistedTargets.PlacerInformant = false
        Config.Database.Mode = 'json'
        local again = require('server.main').start()
        eq(Config.PlacerInformant.Enabled, false)
        eq(Config.PlacerInformant.AlertChancePercent, 55)
        eq(Config.Informant.RevealChancePercent, 35)
        local f = fixture(again)
        eq(select(2, again.informant.placerBuy(f.creator, 'ct00000001', nil, 'op_x')),
            CH.ERR.FEATURE_OFF)
        eq(again.projection.listing(f.hitman.cid).settings.placerInformant, nil,
            'and the app is told it is off')
        resetConfig()
    end)

    it('holds the chances to whole numbers from 0 to 100 at the start', function()
        local check = require('crimson-hitman.server.main').checkCandidate
        local function copy(t)
            if type(t) ~= 'table' then return t end
            local out = {}
            for k, v in pairs(t) do out[k] = copy(v) end
            return out
        end
        for _, bad in ipairs({ -1, 101, 12.5, 'ten' }) do
            for _, path in ipairs({ { 'Informant', 'RevealChancePercent' },
                { 'PlacerInformant', 'RevealChancePercent' }, { 'PlacerInformant', 'AlertChancePercent' } }) do
                local candidate = copy(Config)
                candidate[path[1]][path[2]] = bad
                local _, _, warn = check(candidate)
                local name = path[1] .. '.' .. path[2]
                truthy(table.concat(warn, '\n'):find(name .. ' is', 1, true),
                    name .. ' = ' .. tostring(bad) .. ' is refused')
            end
        end
        local fine = copy(Config)
        fine.PlacerInformant.AlertChancePercent, fine.Informant.RevealChancePercent = 0, 100
        local _, _, warn = check(fine)
        falsy(table.concat(warn, '\n'):find('ChancePercent', 1, true), '0 and 100 are whole chances')
        local s = newStack()
        eq((select(2, s.settings.check('PlacerInformant.RevealChancePercent', 101))), 'invalid_value',
            'and the panel will not take one either')
    end)

    it('tells the app what the dialogs quote', function()
        local s = newStack()
        local f = fixture(s)
        local settings = s.projection.listing(f.hitman.cid).settings
        eq(settings.placerInformant.cost, 25000)
        eq(settings.placerInformant.chance, 20)
        eq(settings.placerInformant.alertChance, 20)
        eq(settings.placerInformant.maxPerContract, 2)
        eq(settings.placerInformant.cooldownMinutes, 10)
        eq(settings.informant.chance, 10)
        eq(settings.informant.needsProximity, nil)
    end)
end)

--------------------------------------------------------------------------
-- Every informant feature at once (Config.InformantsEnabled)
--------------------------------------------------------------------------

describe('every informant feature switched off at once', function()
    local function notices()
        return #(Natives.calls.notifications or {})
    end

    it('is the first switch of the Informant group, and the three need it', function()
        local s = newStack()
        local first
        for _, entry in ipairs(s.settings.CATALOGUE) do
            if entry.group == 'Informant' and entry.section == 'features' then
                first = first or entry
            end
            if entry.key == 'Informant.Enabled' or entry.key == 'PlacerInformant.Enabled'
                or entry.key == 'LocationTip.Enabled' then
                eq(entry.needs, 'InformantsEnabled', entry.key)
            end
        end
        eq(first and first.key, 'InformantsEnabled')
        eq(first.kind, 'switch')
    end)

    it('refuses all three with nothing charged, offers none on any card, and tells nobody', function()
        local s, f, c = setup()
        local placerAt = placerPick(s, c)
        local targetAt = targetPick(s, c)
        truthy(placerAt and targetAt, 'both offered while on')
        Env.players[3].PlayerData.money.bank = 100000
        truthy(s.settings.set('InformantsEnabled', false, 'ADMIN001'))
        eq(s.storage.readSettings().InformantsEnabled.value, false, 'kept in the store')
        eq(Config.Informant.Enabled, true, 'its own switches untouched')
        local money, told = total(s), notices()
        eq(select(2, s.informant.buy(f.target, c.id, targetShown(), targetAt)), CH.ERR.FEATURE_OFF)
        eq(select(2, s.informant.placerBuy(f.creator, c.id, placerShown(), placerAt)),
            CH.ERR.FEATURE_OFF)
        eq(select(2, s.locationTip.buy(f.hitman, c.id, { cost = Config.LocationTip.Cost,
            account = Config.LocationTip.Account })), CH.ERR.FEATURE_OFF)
        eq(total(s), money, 'nothing charged')
        eq(notices(), told, 'no notice to anybody')
        eq(#alerts(), 0)
        local settings = s.projection.listing(f.hitman.cid).settings
        eq(settings.informant, nil)
        eq(settings.placerInformant, nil)
        eq(settings.locationTip.enabled, false)
        eq(view(s, c, 'TARGET01').informantPicks, nil, 'no picker on the target\'s card')
        eq(view(s, c, 'CREATOR1').placerInformantPicks, nil, 'none on the placer\'s')
        eq(view(s, c, 'HITMAN01').locationTip, nil, 'no tip on the hitman\'s')

        truthy(s.settings.set('InformantsEnabled', true, 'ADMIN001'))
        truthy(targetPick(s, c), 'on again, offered again')
        truthy(s.projection.listing(f.hitman.cid).settings.placerInformant)
    end)

    it('is read as off when it is not true or false, and said so at the start', function()
        local check = require('crimson-hitman.server.main').checkCandidate
        local function copy(t)
            if type(t) ~= 'table' then return t end
            local out = {}
            for k, v in pairs(t) do out[k] = copy(v) end
            return out
        end
        for _, bad in ipairs({ 'yes', 1 }) do
            local candidate = copy(Config)
            candidate.InformantsEnabled = bad
            local _, _, warn = check(candidate)
            truthy(table.concat(warn, '\n'):find('InformantsEnabled is', 1, true), tostring(bad))
        end
        for _, path in ipairs({ { 'Informant', 'Enabled' }, { 'PlacerInformant', 'Enabled' } }) do
            local candidate = copy(Config)
            candidate[path[1]][path[2]] = 'false'
            local _, _, warn = check(candidate)
            truthy(table.concat(warn, '\n'):find(path[1] .. '.Enabled is', 1, true),
                path[1] .. ': a string is not a switch')
        end
    end)
end)

describe('each informant switched off on its own', function()
    it('the target\'s: refused with nothing charged, and no picker on the card', function()
        local s, f, c = setup()
        local pick = targetPick(s, c)
        truthy(s.settings.set('Informant.Enabled', false, 'ADMIN001'))
        local before = bank(2)
        eq(select(2, s.informant.buy(f.target, c.id, targetShown(), pick)), CH.ERR.FEATURE_OFF)
        eq(bank(2), before, 'nothing charged')
        eq(view(s, c, 'TARGET01').informantPicks, nil, 'no picker')
        eq(s.projection.listing(f.target.cid).settings.informant, nil, 'and the page is told')
        truthy(view(s, c, 'CREATOR1').placerInformantPicks, 'the placer\'s is its own switch')
    end)

    it('the placer\'s: refused with nothing charged, and no picker on the card', function()
        local s, f, c = setup()
        local pick = placerPick(s, c)
        truthy(s.settings.set('PlacerInformant.Enabled', false, 'ADMIN001'))
        local before = bank(1)
        eq(select(2, s.informant.placerBuy(f.creator, c.id, placerShown(), pick)),
            CH.ERR.FEATURE_OFF)
        eq(bank(1), before, 'nothing charged')
        eq(#alerts(), 0, 'no operative told')
        eq(view(s, c, 'CREATOR1').placerInformantPicks, nil, 'no picker')
        truthy(view(s, c, 'TARGET01').informantPicks, 'the target\'s is its own switch')
    end)
end)

--------------------------------------------------------------------------
-- Shipped off, and decided per target: Config.Informant / PlacerInformant /
-- LocationTip .Enabled for civilian targets, and
-- Config.InformantsWhitelistedTargets for a target on a whitelisted job
-- (the flag the contract recorded, as the advisory reads it).
--------------------------------------------------------------------------

describe('the informant features, per target', function()
    local Shipped = require('tests.harness.shipped')

    --- A contract taken under a name, on a civilian or (`officer`) on a
    --- target the contract recorded as on a whitelisted job.
    local function on(officer, s)
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c, 'placed')
        if officer then
            local row = s.storage.readContract(c.id)
            row.target_protected = true
            s.storage.writeContract(row)
        end
        -- Anonymously, so the target's informant has somebody to sell.
        Config.Anonymity.AllowAnonymousHitman = true
        Config.Anonymity.WhitelistedTargets.AllowAnonymousHitman = true
        truthy(s.contracts.accept(f.hitman, c.id, true), 'taken')
        for _, src in ipairs({ 1, 2, 3 }) do Env.players[src].PlayerData.money.bank = 100000 end
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        return f, c
    end

    --- The three purchases' refusals, by feature.
    local function tried(s, f, c)
        local out = {}
        local pick = targetPick(s, c) or 'op_none'
        out.Informant = select(2, s.informant.buy(f.target, c.id, targetShown(), pick))
        local placerAt = placerPick(s, c) or 'op_none'
        out.PlacerInformant = select(2, s.informant.placerBuy(f.creator, c.id, placerShown(), placerAt))
        out.LocationTip = select(2, s.locationTip.buy(f.hitman, c.id,
            { cost = Config.LocationTip.Cost, account = Config.LocationTip.Account }))
        return out
    end

    local OFF = { Informant = CH.ERR.FEATURE_OFF, PlacerInformant = CH.ERR.FEATURE_OFF,
                  LocationTip = CH.ERR.FEATURE_OFF }

    it('ships all three off, for every target, with nothing charged and nothing drawn', function()
        for _, officer in ipairs({ false, true }) do
            local s = Shipped.newStack()
            local f, c = on(officer, s)
            local money = total(s)
            local errs = tried(s, f, c)
            eq(errs.Informant, CH.ERR.FEATURE_OFF, 'the target\'s')
            eq(errs.PlacerInformant, CH.ERR.FEATURE_OFF, 'the placer\'s')
            eq(errs.LocationTip, CH.ERR.FEATURE_OFF, 'the tip')
            eq(total(s), money, 'nothing charged')
            local settings = s.projection.listing(f.hitman.cid).settings
            eq(settings.informant, nil)
            eq(settings.placerInformant, nil)
            eq(settings.locationTip.enabled, false)
            eq(view(s, c, 'TARGET01').informantPicks, nil)
            eq(view(s, c, 'CREATOR1').placerInformantPicks, nil)
            eq(view(s, c, 'HITMAN01').locationTip, nil)
            eq(Config.InformantsEnabled, true, 'the master switch ships on')
        end
    end)

    --- Every feature off, then the given switches on.
    local function only(s, switches)
        for _, section in ipairs({ 'Informant', 'PlacerInformant', 'LocationTip' }) do
            Config[section].Enabled = false
            Config.InformantsWhitelistedTargets[section] = false
        end
        for _, path in ipairs(switches) do
            truthy(s.settings.set(path, true, 'ADMIN001'), path)
        end
    end

    it('each general switch on sells it on contracts on civilians only', function()
        for _, section in ipairs({ 'Informant', 'PlacerInformant', 'LocationTip' }) do
            for _, officer in ipairs({ false, true }) do
                local s = newStack()
                only(s, { section .. '.Enabled' })
                local f, c = on(officer, s)
                local money = total(s)
                local err = tried(s, f, c)[section]
                if officer then
                    eq(err, section == 'Informant' and CH.ERR.INFORMANT_PROTECTED or CH.ERR.FEATURE_OFF,
                        section .. ': refused on a whitelisted-job target')
                    eq(total(s), money, section .. ': nothing charged')
                else
                    truthy(err ~= CH.ERR.FEATURE_OFF and err ~= CH.ERR.INFORMANT_PROTECTED,
                        section .. ': sold on a civilian: ' .. tostring(err))
                end
            end
        end
    end)

    it('each whitelisted switch on sells it on contracts on whitelisted-job targets only', function()
        for _, section in ipairs({ 'Informant', 'PlacerInformant', 'LocationTip' }) do
            for _, officer in ipairs({ false, true }) do
                local s = newStack()
                only(s, { 'InformantsWhitelistedTargets.' .. section })
                local f, c = on(officer, s)
                local money = total(s)
                local err = tried(s, f, c)[section]
                if officer then
                    truthy(err ~= CH.ERR.FEATURE_OFF and err ~= CH.ERR.INFORMANT_PROTECTED,
                        section .. ': sold on a whitelisted-job target: ' .. tostring(err))
                else
                    eq(err, CH.ERR.FEATURE_OFF, section .. ': refused on a civilian')
                    eq(total(s), money, section .. ': nothing charged')
                end
            end
        end
    end)

    it('offers an officer target the informant on On me only while theirs is on', function()
        local s = newStack()
        only(s, { 'Informant.Enabled' })
        local _, c = on(true, s)
        eq(view(s, c, 'TARGET01').informantPicks, nil, 'the general switch is not theirs')
        truthy(s.settings.set('InformantsWhitelistedTargets.Informant', true, 'ADMIN001'))
        truthy(view(s, c, 'TARGET01').informantPicks, 'theirs on: offered')
        local before = bank(2)
        force(s, HIT)
        local ok, err = s.informant.buy(s.identity.resolve(2), c.id, targetShown(), targetPick(s, c))
        truthy(ok, tostring(err))
        eq(before - bank(2), Config.Informant.Cost, 'charged as any target is')
    end)

    it('the master switch off beats both', function()
        for _, officer in ipairs({ false, true }) do
            local s = newStack()
            only(s, { 'Informant.Enabled', 'PlacerInformant.Enabled', 'LocationTip.Enabled',
                'InformantsWhitelistedTargets.Informant',
                'InformantsWhitelistedTargets.PlacerInformant',
                'InformantsWhitelistedTargets.LocationTip' })
            truthy(s.settings.set('InformantsEnabled', false, 'ADMIN001'))
            local f, c = on(officer, s)
            local money = total(s)
            local errs = tried(s, f, c)
            for section, err in pairs(OFF) do eq(errs[section], err, section) end
            eq(total(s), money, 'nothing charged')
        end
    end)

    it('draws no tip button on a contract its switch is off for, while others sell', function()
        local s = newStack()
        only(s, { 'LocationTip.Enabled' })
        local _, c = on(true, s)
        eq(s.projection.listing('HITMAN01').settings.locationTip.enabled, true,
            'the server sells tips elsewhere')
        local card = view(s, c, 'HITMAN01').locationTip
        eq(card and card.off, true, 'but not on this one, and the card says so')
        eq(card.left, nil, 'nothing offered')
    end)

    it('is a panel group of three switches that apply at once and are kept', function()
        local s = newStack()
        local found = 0
        for _, entry in ipairs(s.settings.CATALOGUE) do
            if entry.group == 'Informants (whitelisted-job targets)' then
                found = found + 1
                eq(entry.section, 'features')
                eq(entry.kind, 'switch')
                eq(entry.needs, 'InformantsEnabled')
            end
        end
        eq(found, 3)
        for _, section in ipairs({ 'Informant', 'PlacerInformant', 'LocationTip' }) do
            local key = 'InformantsWhitelistedTargets.' .. section
            -- The other way from where it stands, so the change is real.
            local want = Config.InformantsWhitelistedTargets[section] ~= true
            truthy(s.settings.set(key, want, 'ADMIN001'), key)
            eq(Config.InformantsWhitelistedTargets[section], want)
            eq(s.storage.readSettings()[key].value, want, 'kept in the store')
            falsy(s.settings.set(key, 'yes', 'ADMIN001'), 'not a true or false')
        end
    end)
end)
