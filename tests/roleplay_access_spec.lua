--- The roleplay features of getting to a contract (server/rp_*.lua,
--- Config.Roleplay): rumours and the broker, the burner phone, the
--- informant in person and reason quality. Each ships off and changes
--- nothing off; on, each does what it says, refuses before anything is
--- taken, is a panel setting that applies at once, and names nobody.

--- Fire a net event as a client does, gate and rate limit and all, and
--- return the reply the page would receive.
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

--- Where the broker NPC stands now (it moves on the clock).
local function brokerAt(s)
    local p = s.rpPlaces.current('broker')
    return { x = p.x, y = p.y, z = p.z }
end
local ELSEWHERE = { x = 500.0, y = 500.0, z = 30.0 }
local TARGET_AT = { x = 210.0, y = -880.0, z = 30.0 } -- Legion Square

local function wealth(src)
    local m = Env.players[src].PlayerData.money
    return m.cash + m.bank
end

--- Every player's money together, and what the contracts hold.
local function total(s)
    local sum = 0
    for _, p in pairs(Env.players) do sum = sum + p.PlayerData.money.cash + p.PlayerData.money.bank end
    for _, c in ipairs(s.storage.allContracts()) do sum = sum + s.escrow.moneyValue(c.id) end
    return sum
end

local function turn(s, key, value)
    local ok, err, why = s.settings.set(key, value, 'ADMIN001', 'ADMIN001')
    truthy(ok, ('%s: %s %s'):format(key, tostring(err), tostring(why)))
end

--- A contract on Dana Reyes by Vic Marlowe, nobody on it, Dana standing in
--- Legion Square and the broker at the first of its shipped places.
local function placed(opts)
    opts = opts or {}
    local s = newStack()
    local f = fixture(s)
    Env.players[2]._coords = TARGET_AT
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = opts.reason or 'Unpaid debt from last week',
        mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 40000 } },
    })
    truthy(c, 'placed')
    return s, f, c
end

local function row(reply, id)
    for _, r in ipairs(reply and reply.data and reply.data.contracts or {}) do
        if r.id == id then return r end
    end
    return nil
end

local function dump(value, out)
    out = out or {}
    if type(value) == 'table' then
        for k, v in pairs(value) do
            out[#out + 1] = tostring(k)
            dump(v, out)
        end
    else
        out[#out + 1] = tostring(value)
    end
    return table.concat(out, ' ')
end

--------------------------------------------------------------------------
-- Off, as shipped
--------------------------------------------------------------------------

describe('the roleplay features of getting to a contract, as shipped', function()
    it('ship off', function()
        for _, name in ipairs({ 'Rumours', 'BurnerPhone', 'InformantNpc', 'ReasonQuality' }) do
            eq(Config.Roleplay[name].Enabled, false, name)
            eq(ConfigDefaults.Roleplay[name].Enabled, false, name .. ' in defaults.lua')
        end
    end)

    it('change nothing off: the full card, Accept without a briefing, no burner, a short reason', function()
        local s, f, c = placed({ reason = 'rdm' })
        local board = call('list', 3, { page = 1 })
        local r = row(board, c.id)
        truthy(r and r.targetName == 'Dana Reyes', 'the full card')
        eq(r.rumour, nil)
        eq(board.data.rumours, nil)
        eq(board.data.burnerMissing, nil)
        local took = call('accept', 3, { id = c.id, penaltyAmount = 0 })
        truthy(took and took.ok, tostring(took and took.err))
        local places = call('rpPlaces', 3, {})
        truthy(places.ok)
        eq(next(places.data), nil, 'no NPC anywhere')
        eq(call('rumourBrief', 3, { id = c.id }).err, CH.ERR.FEATURE_OFF)
        eq(call('brokerNearby', 3, {}).err, CH.ERR.FEATURE_OFF)
        eq(call('brokerBrief', 3, { id = c.id, who = 'x' }).err, CH.ERR.FEATURE_OFF)
        truthy(f)
    end)
end)

--------------------------------------------------------------------------
-- Rumours and the broker
--------------------------------------------------------------------------

describe('rumours and the broker', function()
    local function on(s)
        turn(s, 'Roleplay.Rumours.Enabled', true)
    end

    it('shows a hitman a rumour: an area and a band, no name, face, reason or exact figure', function()
        local s, _, c = placed()
        on(s)
        local board = call('list', 3, { page = 1 })
        local r = row(board, c.id)
        truthy(r and r.rumour, 'a rumour')
        eq(r.rumour.area, 'Legion Square', 'the district the target is in')
        eq(r.rumour.low, 30000)
        eq(r.rumour.high, 50000)
        for _, key in ipairs({ 'targetName', 'targetImageId', 'reason', 'reward', 'creatorName',
            'penaltyAmount', 'targetProtected' }) do
            eq(r[key], nil, key .. ' is not on a rumour')
        end
        falsy(dump(board):find('Dana', 1, true), 'the name crosses nowhere in the reply')
        truthy(board.data.rumours.npc, 'the page is told a broker NPC stands somewhere')
        -- The placer still sees their own card whole.
        local own = row(call('list', 1, { page = 1 }), c.id)
        eq(own.targetName, 'Dana Reyes')
    end)

    it('names a zone in zones mode, the same one every time', function()
        local s, _, c = placed()
        on(s)
        turn(s, 'Roleplay.Rumours.AreaMode', 'zones')
        local area = row(call('list', 3, { page = 1 }), c.id).rumour.area
        local found = false
        for _, z in ipairs(Config.Roleplay.Rumours.Zones) do if z == area then found = true end end
        truthy(found, area .. ' is one of the zones')
        eq(row(call('list', 3, { page = 1 }), c.id).rumour.area, area)
    end)

    it('refuses Accept without a briefing, with nothing taken', function()
        local s, _, c = placed()
        on(s)
        local before, all = wealth(3), total(s)
        local took = call('accept', 3, { id = c.id, penaltyAmount = 0 })
        eq(took.err, CH.ERR.NOT_BRIEFED)
        eq(wealth(3), before)
        eq(total(s), all)
        eq(#s.storage.readHitmen(c.id), 0, 'no hitman row')
    end)

    it('briefs a hitman beside the broker NPC, server-side, and only there', function()
        local s, _, c = placed()
        on(s)
        Env.players[3]._coords = ELSEWHERE
        eq(call('rumourBrief', 3, { id = c.id }).err, CH.ERR.FIND_BROKER)
        Env.players[3]._coords = brokerAt(s)
        local asked = call('rumourBrief', 3, { id = c.id })
        truthy(asked.ok, tostring(asked.err))
        eq(asked.data.contract.targetName, 'Dana Reyes', 'the briefing is the full card')
        local r = row(call('list', 3, { page = 1 }), c.id)
        eq(r.rumour, nil)
        eq(r.targetName, 'Dana Reyes')
        local took = call('accept', 3, { id = c.id, penaltyAmount = 0 })
        truthy(took and took.ok, tostring(took and took.err))
    end)

    it('lets a briefing run out after BriefValidMinutes', function()
        local s, _, c = placed()
        on(s)
        turn(s, 'Roleplay.Rumours.BriefValidMinutes', 5)
        Env.players[3]._coords = brokerAt(s)
        truthy(call('rumourBrief', 3, { id = c.id }).ok)
        Env.time = Env.time + 5 * 60 + 1
        truthy(row(call('list', 3, { page = 1 }), c.id).rumour, 'a rumour again')
        eq(call('accept', 3, { id = c.id, penaltyAmount = 0 }).err, CH.ERR.NOT_BRIEFED)
    end)

    it('refuses the target asking about their own contract as no contract at all', function()
        local s, _, c = placed()
        on(s)
        Env.players[2]._coords = brokerAt(s)
        eq(call('rumourBrief', 2, { id = c.id }).err, CH.ERR.NOT_FOUND)
        eq(call('rumourBrief', 3, { id = 'ct0000000000' }).err, CH.ERR.NOT_FOUND)
    end)

    it('moves the broker between its places on the clock, and tells every game', function()
        local s = placed()
        on(s)
        local places = s.rpPlaces
        Env.time = 0
        local first = places.current('broker')
        Env.time = 4 * 3600
        local second = places.current('broker')
        truthy(first and second and (first.x ~= second.x), 'a new place after RotateHours')
        Env.clientEvents = {}
        truthy(places.announce(), 'told')
        local told = false
        for _, e in ipairs(Env.clientEvents) do
            if e.name == 'crimson-hitman:rpPlacesChanged' and e.target == -1 then told = true end
        end
        truthy(told, 'every game is told to ask again')
        falsy(places.announce(), 'and only once a place moves')
        local reply = call('rpPlaces', 3, {})
        eq(reply.data.broker.x, second.x)
        eq(reply.data.broker.model, 'g_m_m_armboss_01')
        eq(reply.data.informant, nil, 'the informant is off')
    end)

    it('lets a broker player brief somebody standing with them, by a handle that names nobody', function()
        local s, _, c = placed()
        on(s)
        turn(s, 'Roleplay.Rumours.BrokerJobs', { 'broker' })
        Env.addPlayer({ source = 4, citizenid = 'BROKER01', license = 'license:ddd',
            firstname = 'Bo', lastname = 'Ker', job = { name = 'broker', type = 'none' } })
        Env.players[4]._coords = ELSEWHERE
        Env.players[3]._coords = { x = ELSEWHERE.x + 2, y = ELSEWHERE.y, z = ELSEWHERE.z }
        Env.players[1]._coords = { x = 9000, y = 9000, z = 0 }
        Env.players[2]._coords = { x = 9100, y = 9000, z = 0 }
        eq(call('brokerNearby', 3, {}).err, CH.ERR.NOT_BROKER, 'a hitman is no broker')
        local near = call('brokerNearby', 4, {})
        truthy(near.ok, tostring(near.err))
        eq(#near.data.people, 1, 'only the one standing with them')
        local person = near.data.people[1]
        eq(person.metres, 2)
        falsy(dump(near):find('HITMAN01', 1, true) or dump(near):find('Rook', 1, true), 'names nobody')
        for k in pairs(person) do truthy(k == 'handle' or k == 'metres', 'only a handle and metres: ' .. k) end
        truthy(call('list', 4, { page = 1 }).data.rumours.broker, 'the page draws the broker tools')
        -- Walked off: refused, and nothing recorded.
        Env.players[3]._coords = brokerAt(s)
        eq(call('brokerBrief', 4, { id = c.id, who = person.handle }).err, CH.ERR.BROKER_TOO_FAR)
        eq(call('accept', 3, { id = c.id, penaltyAmount = 0 }).err, CH.ERR.NOT_BRIEFED)
        Env.players[3]._coords = { x = ELSEWHERE.x + 2, y = ELSEWHERE.y, z = ELSEWHERE.z }
        eq(call('brokerBrief', 4, { id = c.id, who = 'bpforged' }).err, CH.ERR.NOT_FOUND)
        local briefed = call('brokerBrief', 4, { id = c.id, who = person.handle })
        truthy(briefed.ok, tostring(briefed.err))
        local took = call('accept', 3, { id = c.id, penaltyAmount = 0 })
        truthy(took and took.ok, tostring(took and took.err))
    end)

    it('never names an anonymous placer, and staff see the briefings without names', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[2]._coords = TARGET_AT
        Config.Anonymity.AllowAnonymousPlacer = true
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', anonymous = true,
            reason = 'Unpaid debt from last week', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 40000 } } })
        truthy(c)
        on(s)
        Env.players[3]._coords = brokerAt(s)
        local replies = { call('list', 3, { page = 1 }), call('rumourBrief', 3, { id = c.id }),
            call('list', 3, { page = 1 }), call('rpPlaces', 3, {}) }
        for _, reply in ipairs(replies) do
            local text = dump(reply)
            falsy(text:find('CREATOR1', 1, true) or text:find('Marlowe', 1, true), 'the placer is named')
        end
    end)
end)

--------------------------------------------------------------------------
-- The burner phone
--------------------------------------------------------------------------

describe('the burner phone', function()
    local function give(src, n)
        table.insert(Env.players[src]._inventory, { name = 'burner_phone', count = n or 1, slot = 40 })
    end

    it('refuses placing without one, with nothing taken, and places with one', function()
        local s = newStack()
        local f = fixture(s)
        turn(s, 'Roleplay.BurnerPhone.Enabled', true)
        local before, all = wealth(1), total(s)
        local handle = s.app.mintTargetHandle(f.creator.cid, 'TARGET01')
        local refused = call('create', 1, { target = handle, reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { slots = { { baseline = { cash = 5000 } } } }, shown = {} })
        eq(refused.err, CH.ERR.NEED_BURNER)
        eq(wealth(1), before, 'nothing taken')
        eq(total(s), all)
        eq(#s.storage.liveContracts(), 0)
        give(1)
        turn(s, 'Roleplay.BurnerPhone.ConsumeOnPlace', true)
        local placedOk = call('create', 1, { target = handle, reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { slots = { { baseline = { cash = 5000 } } } }, shown = {} })
        truthy(placedOk.ok, tostring(placedOk.err))
        eq(exports.ox_inventory:GetItemCount(1, 'burner_phone'), 0, 'one used up')
    end)

    it('hides the contract tabs without one, keeps On me, and keeps live contracts', function()
        local s, f, c = placed()
        truthy(s.contracts.accept(f.hitman, c.id, false), 'taken before the rule')
        turn(s, 'Roleplay.BurnerPhone.Enabled', true)
        local board = call('list', 3, { page = 1 })
        truthy(board.ok)
        eq(board.data.burnerMissing, true)
        eq(#board.data.contracts, 0)
        local mine = call('mine', 3, {})
        eq(mine.data.burnerMissing, true)
        eq(#mine.data.accepted, 0)
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        local onMe = call('mine', 2, {})
        truthy(#onMe.data.onMe > 0, 'the target still sees the contract on them')
        eq(s.storage.readHitman(c.id, 'HITMAN01').state, 'active', 'the live contract stays')
        eq(call('abandon', 3, { id = c.id }).err, CH.ERR.NEED_BURNER)
        give(3)
        truthy(#call('list', 3, { page = 1 }).data.contracts > 0, 'back with one')
        turn(s, 'Roleplay.BurnerPhone.RequireToOpen', false)
        Env.players[3]._inventory = {}
        truthy(#call('list', 3, { page = 1 }).data.contracts > 0, 'tabs open without RequireToOpen')
    end)

    it('does nothing when ox_inventory is not started', function()
        local s, _, c = placed()
        turn(s, 'Roleplay.BurnerPhone.Enabled', true)
        Natives.resourceStates['ox_inventory'] = 'stopped'
        local took = call('accept', 3, { id = c.id, penaltyAmount = 0 })
        Natives.resourceStates['ox_inventory'] = 'started'
        truthy(took and took.ok, tostring(took and took.err))
    end)
end)

--------------------------------------------------------------------------
-- The informant in person
--------------------------------------------------------------------------

describe('the informant in person', function()
    local INFORMANT_AT = { x = 374.2, y = -827.4, z = 29.3 }

    it('sells a tip only beside the informant NPC, and charges nothing elsewhere', function()
        local s, f, c = placed()
        truthy(s.contracts.accept(f.hitman, c.id, false))
        turn(s, 'LocationTip.Enabled', true)
        turn(s, 'Roleplay.InformantNpc.Enabled', true)
        Env.time = 3 * 3600 * 2 -- the informant at its first place (offset one)
        local at = s.rpPlaces.current('informant')
        Env.players[3].PlayerData.money.bank = 100000
        Env.players[3]._coords = ELSEWHERE
        local all = total(s)
        local shown = { cost = Config.LocationTip.Cost, account = Config.LocationTip.Account }
        local far = call('locationTip', 3, { id = c.id, shown = shown })
        eq(far.err, CH.ERR.FIND_INFORMANT)
        eq(Env.players[3].PlayerData.money.bank, 100000, 'nothing charged')
        eq(total(s), all)
        Env.players[3]._coords = { x = at.x, y = at.y, z = at.z }
        local near = call('locationTip', 3, { id = c.id, shown = shown })
        truthy(near.ok, tostring(near.err))
        eq(Env.players[3].PlayerData.money.bank, 100000 - Config.LocationTip.Cost)
        truthy(INFORMANT_AT)
    end)

    it('stands in front of the target\'s and the placer\'s look-ups too, and not while they are off', function()
        local s, f, c = placed()
        truthy(s.contracts.accept(f.hitman, c.id, false))
        turn(s, 'Roleplay.InformantNpc.Enabled', true)
        Env.players[1]._coords, Env.players[2]._coords = ELSEWHERE, ELSEWHERE
        -- The informant features themselves off: refused by their own rule.
        Config.Informant.Enabled, Config.InformantsWhitelistedTargets.Informant = false, false
        eq(call('informant', 2, { id = c.id, shown = {} }).err, CH.ERR.FEATURE_OFF)
        turn(s, 'Informant.Enabled', true)
        turn(s, 'PlacerInformant.Enabled', true)
        local all = total(s)
        eq(call('informant', 2, { id = c.id, shown = {} }).err, CH.ERR.FIND_INFORMANT)
        eq(call('placerInformant', 1, { id = c.id, shown = {} }).err, CH.ERR.FIND_INFORMANT)
        eq(total(s), all, 'nothing charged')
    end)
end)

--------------------------------------------------------------------------
-- Reason quality
--------------------------------------------------------------------------

describe('reason quality', function()
    local function place(s, reason)
        local handle = s.app.mintTargetHandle('CREATOR1', 'TARGET01')
        return call('create', 1, { target = handle, reason = reason, mode = CH.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { cash = 5000 } } } }, shown = {} })
    end

    it('refuses a reason too short, of too few words, or low-effort, with nothing taken', function()
        local s = newStack()
        fixture(s)
        turn(s, 'Roleplay.ReasonQuality.Enabled', true)
        local before = wealth(1)
        local short = place(s, 'Debt owed')
        eq(short.err, CH.ERR.REASON_REFUSED)
        eq(short.data.rule, 'short')
        local fewWords = place(s, 'Unforgivablebetrayal')
        eq(fewWords.data.rule, 'words')
        local lazy = place(s, 'idk he was just there')
        eq(lazy.data.rule, 'low_effort')
        eq(place(s, 'NO REASON at all, really').data.rule, 'low_effort', 'a phrase, any case')
        eq(wealth(1), before, 'nothing taken')
        local fine = place(s, 'He sold out the crew to the cops')
        truthy(fine.ok, tostring(fine.err))
        -- 'idkfa' is not 'idk': whole words only.
        local whole = place(s, 'Owes the idkfa gang a lot of money')
        truthy(whole.err ~= CH.ERR.REASON_REFUSED, 'whole words: ' .. tostring(whole.err))
    end)

    it('in review mode places a low-effort one and queues it for staff, once', function()
        local s = newStack()
        fixture(s)
        turn(s, 'Roleplay.ReasonQuality.Enabled', true)
        turn(s, 'Roleplay.ReasonQuality.LowEffortAction', 'review')
        local placedOk = place(s, 'rdm because he looked at me')
        truthy(placedOk.ok, tostring(placedOk.err))
        local items = {}
        for _, item in ipairs(s.review.list(true, 50)) do
            if item.kind == 'low_effort_reason' then items[#items + 1] = item end
        end
        eq(#items, 1)
        eq(items[1].contract_id, placedOk.data.id)
        eq(items[1].known.matched, 'rdm')
        truthy(s.review.KINDS.low_effort_reason, 'staff are told what it is')
        -- The panel's queue names the placer by role to staff without the
        -- identity ACE.
        Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:fff',
            firstname = 'Sam', lastname = 'Steward' })
        Env.aces[6] = { ['crimson.admin'] = true }
        local shown = s.admin.reviews(6, true)
        falsy(dump(shown):find('CREATOR1', 1, true), 'the placer by role only')
    end)

    it('holds Edit to the same rules', function()
        local s = newStack()
        fixture(s)
        local placedOk = place(s, 'He sold out the crew to the cops')
        truthy(placedOk.ok)
        turn(s, 'Roleplay.ReasonQuality.Enabled', true)
        local edited = call('revise', 1, { id = placedOk.data.id, reason = 'test' })
        eq(edited.err, CH.ERR.REASON_REFUSED)
    end)

    it('will not take a least length over the longest reason', function()
        local s = newStack()
        local ok, err = s.settings.set('Roleplay.ReasonQuality.MinLength', 200, 'ADMIN001', 'ADMIN001')
        falsy(ok)
        eq(err, 'invalid_value')
    end)
end)

--------------------------------------------------------------------------
-- The admin panel
--------------------------------------------------------------------------

describe('the roleplay settings in the admin panel', function()
    it('lists every one, each switch under Features in its own group', function()
        local s = newStack()
        local groups = {}
        for _, entry in ipairs(s.settings.CATALOGUE) do
            if entry.key:find('^Roleplay%.') then
                groups[entry.group] = true
                if entry.key:find('%.Enabled$') then
                    eq(entry.category, 'features', entry.key)
                    truthy(entry.about and entry.about ~= '', entry.key .. ' says what it does')
                end
            end
        end
        for _, g in ipairs({ 'Roleplay: Rumours and broker', 'Roleplay: Burner phone',
            'Roleplay: Informant in person', 'Roleplay: Reason quality' }) do
            truthy(groups[g], g)
        end
    end)

    it('takes a place, a phrase and a job list, and refuses one that does not read', function()
        local s = newStack()
        turn(s, 'Roleplay.Rumours.Locations', { '10.5, 20.5, 30.0, 90' })
        eq(Config.Roleplay.Rumours.Locations[1], '10.5, 20.5, 30.0, 90')
        local ok, err = s.settings.set('Roleplay.Rumours.Locations', { '10, 20' }, 'ADMIN001', 'ADMIN001')
        falsy(ok, 'a place needs x, y and z')
        eq(err, 'invalid_value')
        ok = s.settings.set('Roleplay.InformantNpc.Locations', { '1, 2, 99999' }, 'ADMIN001', 'ADMIN001')
        falsy(ok, 'off the map')
        turn(s, 'Roleplay.ReasonQuality.LowEffort', { 'no reason', 'lol' })
        eq(#Config.Roleplay.ReasonQuality.LowEffort, 2)
        turn(s, 'Roleplay.Rumours.BrokerJobs', { 'Broker', 'fixer' })
        eq(Config.Roleplay.Rumours.BrokerJobs.broker, true)
        eq(Config.Roleplay.Rumours.BrokerJobs.fixer, true)
        turn(s, 'Roleplay.Rumours.Districts', { '0, 0, Downtown Core' })
        turn(s, 'Roleplay.BurnerPhone.Item', 'trap_phone')
        eq(Config.Roleplay.BurnerPhone.Item, 'trap_phone')
        local view = s.settings.view()
        local whole
        for _, row in ipairs(view.limits) do
            if row.key == 'Roleplay.Rumours.Locations' then whole = row.whole end
        end
        eq(whole, true, 'the panel adds a place whole')
    end)

    it('tells every game at once when an NPC is moved from the panel', function()
        local s = newStack()
        turn(s, 'Roleplay.InformantNpc.Enabled', true)
        Env.clientEvents = {}
        turn(s, 'Roleplay.InformantNpc.Locations', { '1, 2, 3, 0' })
        local told = 0
        for _, e in ipairs(Env.clientEvents) do
            if e.name == 'crimson-hitman:rpPlacesChanged' then told = told + 1 end
        end
        eq(told, 1)
        eq(s.rpPlaces.current('informant').x, 1.0)
    end)

    it('fills a block config.lua does not have, and puts back a value that does not fit', function()
        local live = Config.Roleplay
        Config.Roleplay = { Rumours = { Enabled = 'yes' } }
        local warn = {}
        require('server.rp_rumours').validate(warn)
        require('server.rp_burner').validate(warn)
        eq(Config.Roleplay.Rumours.Enabled, false)
        eq(Config.Roleplay.BurnerPhone.Item, 'burner_phone', 'the whole block, filled')
        eq(#warn, 1, 'only the value that was wrong is said')
        truthy(warn[1]:find('Roleplay.Rumours.Enabled', 1, true))
        Config.Roleplay = live
    end)
end)
