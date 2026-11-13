--- Organisation extras 3 (server/org/extras3.lua, plan R14-R20), each its own
--- switch under Config.Organisation, off as shipped:
---
---   * off: nothing on the tab, nothing held, no vehicle, no territory hold,
---     every request and op refused in words;
---   * R14 reputation: points from members' outcomes, less heat; tiers cap
---     what a member may accept; staff adjust;
---   * R15 dead drops: P4 chooses; a payout waits in escrow until collected
---     at the staff-set drop; unclaimed paid or refunded; nothing made or lost;
---   * R16 territory: held first for the organisation only while a member
---     stands near the target in its zone; nobody told why or where;
---   * R17 garage: staff-approved models, one out per member, the cap, the
---     spot, return, V1, taken away when left;
---   * R18 internal contracts: K8 asks, only staff approve, placed by the boss
---     through the ordinary path with every limit;
---   * R19 the handler: an NPC spot briefs and hands out the oldest waiting;
---   * R20 the activity log: M12 reads it, names only, staff as Staff.

local W = require('tests.harness.org_world')

local BOSS = W.boss(11, 'BOSS0001')
local SWITCHES = { 'Reputation', 'DeadDrops', 'Territory', 'Garage', 'InternalContracts', 'Handler', 'ActivityLog' }
local STAFF = { staff = true, cid = 'ADMIN001', source = 6 }

local function world(on, extra)
    local s, f = W.world({ configure = function()
        Config.Integrations.Banking = 'none'
        Config.Cooldowns.create = { per = 10, burst = 100 }
        for _, key in ipairs(on or {}) do Config.Organisation[key] = true end
        for k, v in pairs(extra or {}) do Config.Organisation[k] = v end
    end })
    W.crew(s)
    return s, f, s.org.current()
end

--- A spot of `kind` placed by staff where (x, y) is.
local function spot(s, kind, x, y, radius)
    W.at(6, x, y, 30.0)
    local ok, err, row = s.org.placeSpot(STAFF, { kind = kind, here = true, radius = radius })
    assert(ok, kind .. ': ' .. tostring(err) .. ' ' .. tostring(row and row.message))
    return row
end

local function handleFor(s, query)
    local found = s.app.handlers.searchTargets(s.identity.resolve(1), { query = query })
    return found and found[1] and found[1].handle
end

local function listed(src, id)
    local reply = W.call('list', src, {})
    for _, c in ipairs(reply and reply.data and reply.data.contracts or {}) do
        if c.id == id then return true end
    end
    return false
end

--- Every notice a citizen is sent from here on: [cid] = { text, ... }.
local function told(s)
    local said = {}
    local real = s.notify.toCitizen
    s.notify.toCitizen = function(cid, title, text, ...)
        said[cid] = said[cid] or {}
        table.insert(said[cid], tostring(text))
        return real(cid, title, text, ...)
    end
    return said
end

local function has(list, needle)
    for _, text in ipairs(list or {}) do if tostring(text):find(needle, 1, true) then return true end end
    return false
end

--- Every string anywhere in a value, joined.
local function strings(v, out)
    out = out or {}
    if type(v) == 'string' then out[#out + 1] = v
    elseif type(v) == 'table' then for k, x in pairs(v) do strings(k, out); strings(x, out) end end
    return out
end

local function vehicles()
    local n = 0
    for _ in pairs(Env.vehicles) do n = n + 1 end
    return n
end

describe('organisation extras 3 switched off (as shipped)', function()
    it('ships every switch off', function()
        resetConfig()
        for _, key in ipairs(SWITCHES) do eq(Config.Organisation[key], false, key) end
        eq(Config.Integrations.Garage, 'auto')
    end)

    it('adds nothing to the tab, holds nothing and refuses every request and op in words', function()
        local s, f, org = world({ 'OrgContracts' })
        local mine = W.call('orgMine', 11, {}).data
        for _, key in ipairs({ 'reputation', 'deadDrops', 'garage', 'internal', 'activity', 'handler' }) do
            eq(mine[key], nil, key .. ' not on the tab')
        end
        eq(W.ask(6, 'orgGet', {}).data.extras3, nil, 'nothing for the panel')
        for _, p in ipairs(require('server.org.powers').LIST) do W.allow(s, 3, p.code) end
        local lieut = s.org.refFor('BOSS0001', 'LIEUT001')
        for _, name in ipairs({ 'orgPayoutMethod', 'orgGarage', 'orgGarageTake', 'orgGarageReturn', 'orgGarageOffer',
            'orgInternalRequest', 'orgActivity' }) do
            local reply = W.call(name, 11, { method = 'deaddrop', model = 'sultan', models = { 'sultan' },
                member = lieut, reason = 'x', amount = 100 })
            falsy(reply.ok, name .. ' refused')
            truthy(reply.data and reply.data.message, name .. ' says why')
        end
        for _, op in ipairs({ 'orgRepAdjust', 'orgPayoutMethod', 'orgDropSettle', 'orgGarageOffer', 'orgGarageRemove',
            'orgInternalDecide', 'orgActivityGet' }) do
            local reply = W.ask(6, op, { points = 5, reason = 'x', method = 'deaddrop', key = 'a:b', how = 'release',
                models = { 'sultan' }, subject = 'LIEUT001', id = 'ic1', approve = true })
            falsy(reply.ok, op .. ' refused')
            truthy(reply.message, op .. ' says why')
        end
        -- A territory, a contract on somebody in it with a member beside them:
        -- nothing held while Territory is off.
        spot(s, 'territory', 0.0, 0.0, 300)
        W.at(2, 10.0, 10.0)
        W.at(13, 12.0, 10.0)
        local reply = W.call('create', 1, { target = handleFor(s, 'Reyes'), reason = 'x',
            reward = { slots = { { baseline = { cash = 1000 } } } }, shown = {} })
        eq(reply.ok, true, tostring(reply.err))
        eq(org.settings.orgContracts[reply.data.id], nil, 'not held')
        -- A payout as always: nothing waits for a drop.
        local hitman = s.identity.resolve(13)
        local c = assert(W.place(s, f.creator, 'READER01'))
        local before = W.wealth(13)
        truthy(s.contracts.accept(hitman, c.id))
        truthy(s.contracts.claimSlot(c.id, 'RECRUIT1', CH.FULFILMENT.KIDNAPPING))
        eq(W.wealth(13) - before, 5000)
        eq(vehicles(), 0, 'no vehicle made')
        eq(#org.settings.activity, 0, 'nothing logged')
    end)
end)

describe('R14: reputation and tiers', function()
    it('counts members\' outcomes, caps accepts by the tier, and staff adjust it', function()
        local s, f, org = world({ 'Reputation' }, { RepTiers = { '0, Unknown, 3000', '20, Known, 0' },
            RepCompletion = 10, RepFailure = 5, RepHeat = 0 })
        local recruit = s.identity.resolve(13)
        local c = W.place(s, f.creator)
        local err = select(2, s.contracts.accept(recruit, c.id))
        eq(err, 'org_tier', 'a $5000 contract above the Unknown tier\'s $3000')
        local mine = W.call('orgMine', 13, {}).data
        eq(mine.reputation.tier, 'Unknown')
        eq(mine.reputation.toNext, 20)
        s.record.onCompleted('RECRUIT1', CH.FULFILMENT.ELIMINATION, nil, { earned = 100 })
        s.record.onCompleted('LIEUT001', CH.FULFILMENT.ELIMINATION, nil, { earned = 100 })
        s.record.onFailed('LIEUT001', CH.FULFILMENT.ELIMINATION, nil, {})
        eq(org.settings.rep.points, 15)
        s.record.onCompleted('HITMAN01', CH.FULFILMENT.ELIMINATION, nil, {})
        eq(org.settings.rep.points, 15, 'a non-member counts for nothing')
        truthy(W.ask(6, 'orgRepAdjust', { points = 5, reason = 'Clean work at the docks' }).ok)
        eq(W.call('orgMine', 13, {}).data.reputation.tier, 'Known')
        truthy(s.contracts.accept(recruit, c.id), 'Known has no cap')
        for _, bad in ipairs({ 0, 1.5, 'x', 200001, -200001, {} }) do
            falsy(W.ask(6, 'orgRepAdjust', { points = bad, reason = 'x' }).ok, 'points ' .. tostring(bad))
        end
        falsy(W.ask(6, 'orgRepAdjust', { points = 5, reason = '<b>x</b>' }).ok, 'no markup')
        falsy(s.org.repAdjust(BOSS, 5, 'mine'), 'staff only')
        eq(#W.audit('org_rep_adjusted'), 1)
    end)

    it('takes the heat members carry off the standing', function()
        local s, _, org = world({ 'Reputation' }, { RepHeat = 3 })
        org.settings.rep.points = 100
        local Heat = require('server.record.heat')
        local real = Heat.of
        Heat.of = function(cid) return cid == 'LIEUT001' and 10 or 0 end
        local standing = s.org.Extras3.standing(org)
        Heat.of = real
        eq(standing.points, 70)
        eq(standing.heat, 30)
    end)
end)

describe('R15: dead drops', function()
    local function setup(extra)
        local s, f, org = world({ 'DeadDrops' }, extra)
        W.allow(s, 3, 'P4')
        return s, f, org
    end

    it('needs a dead drop and P4, then holds a member\'s payout until it is collected there', function()
        local s, f, org = setup()
        local said = told(s)
        local refused = W.call('orgPayoutMethod', 11, { method = 'deaddrop' })
        falsy(refused.ok, 'no drop set')
        truthy(refused.data.message:find('dead drop', 1, true))
        local drop = spot(s, 'deaddrop', 400.0, 400.0)
        falsy(W.call('orgPayoutMethod', 12, { method = 'deaddrop' }).ok, 'the lieutenant has not P4')
        falsy(W.call('orgPayoutMethod', 11, { method = 'cash' }).ok, 'bank or deaddrop')
        eq(W.call('orgPayoutMethod', 11, { method = 'deaddrop' }).ok, true)
        local recruit = s.identity.resolve(13)
        local creatorBefore, before = W.wealth(1), W.wealth(13)
        local c = W.place(s, f.creator)
        truthy(s.contracts.accept(recruit, c.id))
        truthy(s.contracts.claimSlot(c.id, 'RECRUIT1', CH.FULFILMENT.KIDNAPPING))
        eq(W.wealth(13), before, 'held at the drop')
        truthy(org.settings.drops[c.id .. ':RECRUIT1:1'])
        truthy(has(said.RECRUIT1 or {}, 'dead drop'), 'told where')
        eq(W.call('orgMine', 13, {}).data.deadDrops.waiting, 1)
        -- Somewhere else: nothing. At the drop: collected.
        W.at(13, 0.0, 0.0)
        W.call('orgUse', 13, drop.id)
        eq(W.wealth(13), before)
        W.at(13, 400.0, 400.0)
        Env.clientEvents = {}
        _G.source = 13
        Env.events['crimson-hitman:orgUse'](drop.id)
        _G.source = nil
        eq(W.wealth(13) - before, 5000, 'paid at the drop')
        eq(creatorBefore - W.wealth(1), 5000, 'what was escrowed is what was received')
        eq(next(org.settings.drops), nil)
        eq(#W.audit('org_drop_collected'), 1)
    end)

    it('hands an unclaimed one over, or gives it back to the placer, as DeadDropUnclaimed says', function()
        for _, rule in ipairs({ 'pay', 'refund' }) do
            local s, f, org = setup({ DeadDropUnclaimed = rule, DeadDropMinutes = 5 })
            spot(s, 'deaddrop', 400.0, 400.0)
            truthy(W.call('orgPayoutMethod', 11, { method = 'deaddrop' }).ok)
            local recruit = s.identity.resolve(13)
            local creatorBefore, before = W.wealth(1), W.wealth(13)
            local c = W.place(s, f.creator)
            truthy(s.contracts.accept(recruit, c.id))
            truthy(s.contracts.claimSlot(c.id, 'RECRUIT1', CH.FULFILMENT.KIDNAPPING))
            eq(W.wealth(13), before)
            Env.advance(6 * 60)
            s.org.extrasTick(os.time() + 60)
            eq(next(org.settings.drops), nil, rule .. ': ended')
            if rule == 'pay' then
                eq(W.wealth(13) - before, 5000, 'handed over the usual way')
                eq(creatorBefore - W.wealth(1), 5000)
            else
                eq(W.wealth(13), before, 'not to the member')
                eq(W.wealth(1), creatorBefore, 'back to the placer, whole')
            end
            eq(#W.audit('org_drop_expired'), 1)
        end
    end)

    it('lets staff settle one, and refuses hostile keys', function()
        local s, f, org = setup()
        spot(s, 'deaddrop', 400.0, 400.0)
        truthy(W.ask(6, 'orgPayoutMethod', { method = 'deaddrop' }).ok, 'staff choose it too')
        local recruit = s.identity.resolve(13)
        local before = W.wealth(13)
        local c = W.place(s, f.creator)
        truthy(s.contracts.accept(recruit, c.id))
        truthy(s.contracts.claimSlot(c.id, 'RECRUIT1', CH.FULFILMENT.KIDNAPPING))
        -- By the opaque handle orgGet gives, never the drop's own key.
        local rows = W.ask(6, 'orgGet', {}).data.extras3.deadDrops.rows
        eq(#rows, 1)
        local handle = rows[1].handle
        truthy(type(handle) == 'string' and not handle:find('RECRUIT1', 1, true), 'opaque')
        eq(rows[1].key, nil, 'no key')
        for _, bad in ipairs({ 'nope', 42, {}, ('k'):rep(200), c.id .. ':RECRUIT1' }) do
            falsy(W.ask(6, 'orgDropSettle', { handle = bad, how = 'release' }).ok)
        end
        falsy(W.ask(6, 'orgDropSettle', { handle = handle, how = 'burn' }).ok)
        truthy(W.ask(6, 'orgDropSettle', { handle = handle, how = 'release' }).ok)
        eq(W.wealth(13) - before, 5000)
    end)

    it('keeps a drop over a restart', function()
        local s, f, org = setup()
        spot(s, 'deaddrop', 400.0, 400.0)
        truthy(W.call('orgPayoutMethod', 11, { method = 'deaddrop' }).ok)
        local c = W.place(s, f.creator)
        truthy(s.contracts.accept(s.identity.resolve(13), c.id))
        truthy(s.contracts.claimSlot(c.id, 'RECRUIT1', CH.FULFILMENT.KIDNAPPING))
        s.org.boot(false)
        truthy(s.org.current().settings.drops[c.id .. ':RECRUIT1:1'], 'read again')
        local before = W.wealth(13)
        s.escrow.retryPending('RECRUIT1')
        eq(W.wealth(13), before, 'still held after the restart')
        local _ = org
    end)
end)

describe('R16: territory', function()
    local function setup(extra)
        local s, f, org = world({ 'Territory', 'OrgContracts' }, extra)
        spot(s, 'territory', 0.0, 0.0, 300)
        return s, f, org
    end
    local function place(s, who)
        local reply = W.call('create', 1, { target = handleFor(s, who or 'Reyes'), reason = 'x', anonymous = false,
            reward = { slots = { { baseline = { cash = 1000 } } } }, shown = {} })
        eq(reply.ok, true, tostring(reply.err))
        return reply.data.id
    end
    --- Every member far from everybody.
    local function away()
        W.at(11, 3000.0, 3000.0)
        W.at(12, 3100.0, 3000.0)
        W.at(13, 3200.0, 3000.0)
    end

    it('holds it first only where a member stands near the target in the zone, and says nothing of why', function()
        local s, _, org = setup()
        local said = told(s)
        W.allow(s, 3, 'K4')
        away()
        W.at(1, 2000.0, 2000.0)
        W.at(3, 10.0, 10.0)
        local far = place(s, 'Ash')
        eq(org.settings.orgContracts[far], nil, 'no member who can see them: not held')
        W.at(2, 10.0, 10.0)
        W.at(13, 40.0, 10.0)
        local id = place(s)
        local entry = org.settings.orgContracts[id]
        truthy(entry, 'held for the organisation')
        eq(entry.state, 'waiting')
        falsy(listed(7, id), 'off the open board for now')
        local bossWords = table.concat(said.BOSS0001 or {}, '|')
        truthy(bossWords:find('A contract was sent to the organisation', 1, true), 'the words of any sent one')
        falsy(bossWords:lower():find('territor', 1, true), 'never why')
        eq(said.CREATOR1, nil, 'the placer is told nothing')
        -- After TerritoryMinutes: the open board, the placer still told nothing.
        Env.advance(6 * 60)
        s.org.extrasTick(os.time() + 60)
        eq(org.settings.orgContracts[id], nil)
        truthy(listed(7, id), 'on the open board')
        eq(said.CREATOR1, nil, 'and not told then either')
        -- The zone is never sent to any game.
        for _, sp in ipairs(s.org.spotsFor('RECRUIT1')) do falsy(sp.kind == 'territory') end
        -- The staff log has it, with no position.
        local rows = W.audit('org_territory_hold')
        eq(#rows, 1)
        for k in pairs(rows[1].detail or {}) do falsy(k == 'x' or k == 'y' or k == 'z', 'no position: ' .. k) end
    end)

    it('holds nothing outside the zone, in another bucket, or with contracts to the organisation off', function()
        local s, _, org = setup()
        away()
        W.at(2, 1000.0, 1000.0)
        W.at(13, 1001.0, 1000.0)
        eq(org.settings.orgContracts[place(s, 'Reyes')], nil, 'outside')
        away()
        W.at(3, 10.0, 10.0)
        W.at(13, 11.0, 10.0)
        Env.players[13]._bucket = 3
        eq(org.settings.orgContracts[place(s, 'Ash')], nil, 'another routing bucket')
        Env.players[13]._bucket = nil
        Config.Organisation.OrgContracts = false
        W.at(7, 10.0, 10.0)
        eq(org.settings.orgContracts[place(s, 'P7 Org')], nil, 'needs OrgContracts')
    end)
end)

describe('R17: the garage', function()
    local function setup(extra)
        local opts = { GarageVehicles = { 'sultan', 'baller' }, GarageMaxOut = 2 }
        for k, v in pairs(extra or {}) do opts[k] = v end
        local s, f, org = world({ 'Garage' }, opts)
        spot(s, 'garage', 300.0, 300.0)
        return s, f, org
    end

    it('lets a member take an offered model out at the spot, one at a time, and bring it back', function()
        local s, _, org = setup()
        falsy(W.call('orgGarageTake', 13, { model = 'sultan' }).ok, 'not at the spot')
        W.at(13, 300.0, 300.0)
        falsy(W.call('orgGarageTake', 13, { model = 'adder' }).ok, 'not approved')
        local out = W.call('orgGarageTake', 13, { model = 'sultan' })
        eq(out.ok, true, tostring(out.err))
        eq(vehicles(), 1)
        local id, v = next(Env.vehicles)
        eq(v.model, 'sultan')
        eq(v.plate, out.data.plate)
        eq(v.state.crimsonOrgVehicle, true)
        -- Locked where a keys script gives the keys, else left open (R86 F1).
        eq(v.locked, CrimsonBoot.require('server.adapters.init').get('keys') and 2 or 1)
        falsy(W.call('orgGarageTake', 13, { model = 'baller' }).ok, 'one at a time')
        W.at(12, 300.0, 300.0)
        truthy(W.call('orgGarageTake', 12, { model = 'baller' }).ok)
        W.at(11, 300.0, 300.0)
        eq(W.call('orgGarageTake', 11, { model = 'sultan' }).err, 'org_limit', 'GarageMaxOut')
        eq(#W.call('orgGarage', 13, {}).data.out, 2)
        -- Back: only near the spot.
        Env.vehicles[id].x = 900.0
        falsy(W.call('orgGarageReturn', 13, {}).ok, 'too far from the spot')
        Env.vehicles[id].x = 302.0
        truthy(W.call('orgGarageReturn', 13, {}).ok)
        eq(Env.vehicles[id], nil, 'taken away')
        truthy(#W.audit('org_vehicle_out') >= 2)
        local _ = org
    end)

    it('offers only what V1 leaves on, takes away what is left out too long or by one who left', function()
        local s, _, org = setup({ GarageKeepMinutes = 10 })
        falsy(W.call('orgGarageOffer', 11, { models = { 'sultan' } }).ok, 'needs V1')
        W.allow(s, 3, 'V1')
        truthy(W.call('orgGarageOffer', 11, { models = { 'sultan', 'adder' } }).ok)
        local view = W.call('orgGarage', 13, {}).data
        eq(#view.models, 1)
        eq(view.models[1], 'sultan')
        W.at(13, 300.0, 300.0)
        falsy(W.call('orgGarageTake', 13, { model = 'baller' }).ok, 'taken off by the boss')
        truthy(W.call('orgGarageTake', 13, { model = 'sultan' }).ok)
        Env.advance(11 * 60)
        s.org.extrasTick(os.time() + 60)
        eq(vehicles(), 0, 'out too long')
        truthy(W.call('orgGarageTake', 13, { model = 'sultan' }).ok)
        truthy(W.ask(6, 'orgGarageRemove', { subject = 'RECRUIT1' }).ok, 'staff take it away')
        eq(vehicles(), 0)
        Env.advance(60)
        truthy(W.call('orgGarageTake', 13, { model = 'sultan' }).ok)
        truthy(s.org.fire(W.STAFF, 'RECRUIT1', 'gone'))
        Env.advance(60)
        s.org.extrasTick(os.time() + 60)
        eq(vehicles(), 0, 'a member who left')
        local _ = org
    end)

    it('is off in words with the garage adapter set to none', function()
        local s = setup()
        Config.Integrations.Garage = 'none'
        W.at(13, 300.0, 300.0)
        local reply = W.call('orgGarageTake', 13, { model = 'sultan' })
        falsy(reply.ok)
        truthy(reply.data.message:find('Config.Integrations.Garage', 1, true))
        eq(vehicles(), 0)
        local _ = s
    end)
end)

describe('R18: internal contracts on a rogue member', function()
    it('is asked by K8, placed only once staff approve, by the boss and with every limit', function()
        local s, _, org = world({ 'InternalContracts' })
        local ref = s.org.refFor('BOSS0001', 'RECRUIT1')
        falsy(W.call('orgInternalRequest', 11, { member = ref, reason = 'Sold us out', amount = 2000 }).ok, 'needs K8')
        W.allow(s, 3, 'K8')
        for _, bad in ipairs({ { amount = 0 }, { amount = 1.5 }, { amount = 'x' }, { reason = '<b>x</b>' },
            { reason = '' } }) do
            local p = { member = ref, reason = 'Sold us out', amount = 2000 }
            for k, v in pairs(bad) do p[k] = v end
            falsy(W.call('orgInternalRequest', 11, p).ok, 'hostile ' .. tostring(next(bad)))
        end
        local self = s.org.refFor('BOSS0001', 'BOSS0001')
        falsy(W.call('orgInternalRequest', 11, { member = self, reason = 'x', amount = 2000 }).ok, 'never oneself')
        local asked = W.call('orgInternalRequest', 11, { member = ref, reason = 'Sold us out', amount = 2000 })
        eq(asked.ok, true, tostring(asked.err))
        local id = asked.data.id
        local view = W.ask(6, 'orgGet', {}).data.extras3.internal
        eq(view[1].reason, 'Sold us out')
        eq(view[1].state, 'pending')
        -- The boss away: refused, the request kept.
        local bossPlayer = Env.players[11]
        Env.removePlayer(11)
        falsy(W.ask(6, 'orgInternalDecide', { id = id, approve = true }).ok)
        eq(org.settings.internal[id].state, 'pending')
        Env.players[11] = bossPlayer
        Env.byCitizen.BOSS0001 = 11
        -- Normal limits: the boss cannot pay for it.
        local money = Env.players[11].PlayerData.money
        local cash, bank = money.cash, money.bank
        money.cash, money.bank = 0, 0
        local poor = W.ask(6, 'orgInternalDecide', { id = id, approve = true })
        falsy(poor.ok, 'placed as any placement, refused without the money')
        eq(org.settings.internal[id].state, 'pending')
        money.cash, money.bank = cash, bank
        local placed = W.ask(6, 'orgInternalDecide', { id = id, approve = true })
        eq(placed.ok, true, tostring(placed.message))
        local c = s.storage.readContract(org.settings.internal[id].contract)
        eq(c.target_cid, 'RECRUIT1')
        eq(c.creator_cid, 'BOSS0001', 'placed by the boss who asked')
        eq(W.wealth(11), cash + bank - 2000, 'with their own money')
        falsy(W.ask(6, 'orgInternalDecide', { id = id, approve = true }).ok, 'once')
        falsy(s.org.internalDecide(BOSS, id, true), 'only staff decide')
        eq(#W.audit('org_internal_requested'), 1)
    end)

    it('lets staff decline one, and the boss is told', function()
        local s, _, org = world({ 'InternalContracts' })
        W.allow(s, 3, 'K8')
        local said = told(s)
        local id = W.call('orgInternalRequest', 11, { member = s.org.refFor('BOSS0001', 'LIEUT001'),
            reason = 'Talks to the police', amount = 500 }).data.id
        truthy(W.ask(6, 'orgInternalDecide', { id = id, approve = false }).ok)
        eq(org.settings.internal[id].state, 'declined')
        truthy(has(said.BOSS0001 or {}, 'declined'))
    end)
end)

describe('R19: the handler', function()
    it('briefs a member at an NPC spot and hands out the oldest contract waiting', function()
        local s, f, org = world({ 'Handler', 'OrgContracts' })
        local said = told(s)
        local npc = spot(s, 'npc', 500.0, 500.0)
        local older = assert(W.place(s, f.creator, 'READER01'))
        truthy(s.org.receiveContract(older.id, 'CREATOR1'))
        Env.advance(5)
        local newer = assert(W.place(s, f.creator, 'HITMAN01'))
        truthy(s.org.receiveContract(newer.id, 'CREATOR1'))
        W.at(13, 500.0, 500.0)
        s.org.useSpot(13, npc.id)
        eq(org.settings.orgContracts[older.id].state, 'assigned')
        eq(org.settings.orgContracts[older.id].cid, 'RECRUIT1')
        eq(org.settings.orgContracts[newer.id].state, 'waiting')
        truthy(has(said.RECRUIT1 or {}, 'You have a contract assigned'))
        s.org.useSpot(13, npc.id)
        eq(org.settings.orgContracts[newer.id].state, 'waiting', 'one at a time')
        -- Too far: nothing.
        W.at(12, 0.0, 0.0)
        s.org.useSpot(12, npc.id)
        eq(org.settings.orgContracts[newer.id].state, 'waiting')
        -- An outsider: nothing.
        W.at(3, 500.0, 500.0)
        s.org.useSpot(3, npc.id)
        eq(org.settings.orgContracts[newer.id].state, 'waiting')
    end)

    it('does nothing with the switch off', function()
        local s, f, org = world({ 'OrgContracts' })
        local npc = spot(s, 'npc', 500.0, 500.0)
        local c = assert(W.place(s, f.creator, 'READER01'))
        truthy(s.org.receiveContract(c.id, 'CREATOR1'))
        W.at(13, 500.0, 500.0)
        s.org.useSpot(13, npc.id)
        eq(org.settings.orgContracts[c.id].state, 'waiting')
    end)
end)

describe('R20: the activity log', function()
    it('is read with M12: names, never citizen ids, staff as Staff', function()
        local s, f, org = world({ 'ActivityLog' })
        local recruit = s.identity.resolve(13)
        local c = W.place(s, f.creator)
        truthy(s.contracts.accept(recruit, c.id))
        truthy(s.contracts.claimSlot(c.id, 'RECRUIT1', CH.FULFILMENT.KIDNAPPING))
        truthy(s.org.staffDeposit(W.STAFF, 1000, 'seed', 'n1'))
        falsy(W.call('orgActivity', 11, {}).ok, 'needs M12')
        W.allow(s, 3, 'M12')
        local reply = W.call('orgActivity', 11, {})
        eq(reply.ok, true, tostring(reply.err))
        local kinds, text = {}, {}
        for _, r in ipairs(reply.data.rows) do
            kinds[r.action] = r
            text[#text + 1] = tostring(r.by) .. ' ' .. tostring(r.member) .. ' ' .. tostring(r.what)
        end
        truthy(kinds.accepted, 'the accept')
        eq(kinds.accepted.by, 'P13')
        truthy(kinds.completed, 'the outcome')
        truthy(kinds.org_grant, 'staff\'s grant')
        eq(kinds.org_grant.by, 'Staff')
        local all = table.concat(text, '|')
        for _, cid in ipairs({ 'RECRUIT1', 'BOSS0001', 'ADMIN001', 'CREATOR1', 'TARGET01' }) do
            falsy(all:find(cid, 1, true), 'no citizen id: ' .. cid)
        end
        local every = table.concat(strings(reply.data), '|')
        for _, cid in ipairs({ 'RECRUIT1', 'BOSS0001', 'ADMIN001', 'CREATOR1', 'TARGET01' }) do
            falsy(every:find(cid, 1, true), 'nowhere in the reply: ' .. cid)
        end
        local _ = org
    end)
end)
