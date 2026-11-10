--- Map markers for each step of a contract (server/missionsteps.lua,
--- client/missionsteps.lua, Config.StepMarkers).
---
--- Each marker goes to the one party who acts on the step and to nobody
--- else (never the target, never a bystander, never the page), at a fixed
--- point the server recorded; it comes off on every way its step ends, is
--- drawn again when a player comes back, and nothing runs or is sent while
--- there is none. The client draws, moves and takes off each one, and drops
--- them all at a logout and at the stop.

local RP = require('tests.harness.roleplay')
local Client = require('tests.harness.client')

local STEP_EVENT, CLEAR_EVENT = 'crimson-hitman:client:StepMarker', 'crimson-hitman:client:StepMarkerClear'
local BODY = { x = 101.0, y = 100.0, z = 30.0 }

local function at(src, p) Env.players[src]._coords = { x = p.x, y = p.y, z = p.z } end

--- What each player was sent since the events were emptied.
local function sent()
    local set, cleared = {}, {}
    for _, e in ipairs(Env.clientEvents) do
        if e.name == STEP_EVENT then
            set[e.target] = set[e.target] or {}
            set[e.target][e.args[1].key] = e.args[1]
        elseif e.name == CLEAR_EVENT then
            cleared[e.target] = cleared[e.target] or {}
            cleared[e.target][e.args[1].key] = true
        end
    end
    return set, cleared
end

local function stack()
    local s = newStack()
    local f = fixture(s)
    Env.addPlayer({ source = 4, citizenid = 'BYSTAND1', license = 'license:by', firstname = 'Bea', lastname = 'S' })
    s.bridges.install(s)
    return s, f
end

local function taken(s, f)
    local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 } } })
    truthy(c, 'placed')
    truthy(s.contracts.accept(f.hitman, c.id, false), 'taken')
    return c
end

local function kill(s)
    at(3, { x = 100.0, y = 100.0, z = 30.0 })
    at(2, BODY)
    Env.players[2]._health = 140
    s.death.recordDamage(3, 2, 123456)
    Env.players[2].PlayerData.metadata.isdead = true
    Env.clientEvents = {}
    s.death.onVictimReport(2)
end

local function onlyTo(set, src, key)
    truthy(set[src] and set[src][key], ('%s drawn for %d'):format(key, src))
    for other, keys in pairs(set) do
        if other ~= src then falsy(keys[key], ('%s never sent to %s'):format(key, tostring(other))) end
    end
end

--------------------------------------------------------------------------
-- The kill to verify
--------------------------------------------------------------------------

describe('the kill to verify', function()
    it('is drawn for the hitman alone, at the body the server recorded', function()
        local s, f = stack()
        local c = taken(s, f)
        kill(s)
        local set = sent()
        local key = 'kill:' .. c.id
        onlyTo(set, 3, key)
        eq(set[3][key].kind, 'kill')
        eq(set[3][key].x, BODY.x)
        eq(set[3][key].y, BODY.y)
        falsy(set[1] or set[2] or set[4], 'nothing at all to the placer, the target or a bystander')
    end)

    it('comes off when the kill is verified', function()
        local s, f = stack()
        local c = taken(s, f)
        Config.Completion.KillPhotos = false
        kill(s)
        Env.clientEvents = {}
        truthy(s.photo.verifyAtScene(f.hitman, c.id))
        local _, cleared = sent()
        truthy(cleared[3] and cleared[3]['kill:' .. c.id], 'off the hitman\'s map')
        eq(next(s.missionSteps.shown()), nil, 'nothing drawn')
    end)

    it('comes off when the hitman walks away', function()
        local s, f = stack()
        local c = taken(s, f)
        kill(s)
        Env.clientEvents = {}
        truthy(s.contracts.abandon(f.hitman, c.id))
        local _, cleared = sent()
        truthy(cleared[3] and cleared[3]['kill:' .. c.id])
    end)

    it('comes off when the contract ends', function()
        local s, f = stack()
        local c = taken(s, f)
        kill(s)
        Env.clientEvents = {}
        s.contracts.resolve(c.id, CH.STATE.CANCELLED, 'CREATOR1', nil, 'test')
        local _, cleared = sent()
        truthy(cleared[3] and cleared[3]['kill:' .. c.id])
    end)

    it('comes off when the target is revived', function()
        local s, f = stack()
        local c = taken(s, f)
        kill(s)
        Env.advance((Config.Completion.ProofWindowSeconds or 0) + 5)
        Env.clientEvents = {}
        Env.players[2].PlayerData.metadata.isdead = false
        s.death.onRevived('TARGET01', Env.gameTimer)
        falsy(s.death.getPending(c.id, 'HITMAN01'), 'the kill is gone')
        local _, cleared = sent()
        truthy(cleared[3] and cleared[3]['kill:' .. c.id])
    end)

    it('comes off on the tick once the kill lapses', function()
        local s, f = stack()
        local c = taken(s, f)
        kill(s)
        Env.advance(Config.Completion.PhotoTokenLifetimeSeconds * 2 + 10)
        Env.clientEvents = {}
        truthy(s.missionSteps.tick(), 'the tick looks while one is drawn')
        local _, cleared = sent()
        truthy(cleared[3] and cleared[3]['kill:' .. c.id])
        falsy(s.missionSteps.tick(), 'and then nothing more')
    end)

    it('is not drawn with its switch off, and comes off when the switch is turned', function()
        local s, f = stack()
        Config.StepMarkers.KillScene = false
        local c = taken(s, f)
        kill(s)
        eq(next((sent())), nil, 'nothing sent')
        Config.StepMarkers.KillScene = true
        s.missionSteps.tick()
        truthy(s.missionSteps.shown().HITMAN01['kill:' .. c.id], 'on again: drawn at the tick')
        Env.clientEvents = {}
        Config.StepMarkers.Enabled = false
        s.missionSteps.tick()
        local _, cleared = sent()
        truthy(cleared[3] and cleared[3]['kill:' .. c.id], 'the master switch takes it off')
    end)
end)

--------------------------------------------------------------------------
-- The handover
--------------------------------------------------------------------------

describe('the handover circle', function()
    local AT = { x = 200.0, y = 200.0, z = 30.0 }

    local function armed(configure)
        local s, f = stack()
        if configure then configure() end
        local c = taken(s, f)
        for _, src in ipairs({ 1, 2, 3 }) do at(src, AT) end
        Env.players[2].PlayerData.metadata.ishandcuffed = true
        Env.clientEvents = {}
        truthy(s.kidnap.arm(c.id, 'HITMAN01'), 'armed')
        return s, f, c
    end

    it('is drawn for the placer and the hitman, never the target, at the point it was armed', function()
        local s, f, c = armed()
        local set = sent()
        local key = 'handover:' .. c.id
        truthy(set[1] and set[1][key], 'the placer')
        truthy(set[3] and set[3][key], 'the hitman')
        falsy(set[2] and set[2][key], 'never the target')
        falsy(set[4], 'nor a bystander')
        eq(set[3][key].radius, Config.Kidnap.Radius)
        eq(set[3][key].x, AT.x)
    end)

    it('comes off for both when it is cancelled', function()
        local s, f, c = armed()
        Env.clientEvents = {}
        s.kidnap.cancel(c.id, 'HITMAN01', 'test')
        local _, cleared = sent()
        truthy(cleared[1] and cleared[1]['handover:' .. c.id])
        truthy(cleared[3] and cleared[3]['handover:' .. c.id])
    end)

    it('comes off for both when it finishes and pays', function()
        local s, f, c = armed()
        Env.clientEvents = {}
        local ticks = math.floor((Config.Kidnap.CountdownSeconds * 1000) / Config.Kidnap.TickMs) + 2
        for _ = 1, ticks do s.kidnap.tick(Config.Kidnap.TickMs) end
        eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED, 'paid')
        local _, cleared = sent()
        truthy(cleared[1] and cleared[1]['handover:' .. c.id])
        truthy(cleared[3] and cleared[3]['handover:' .. c.id])
    end)

    it('comes off for both when the placer declines it (Config.Kidnap.PlacerConfirms)', function()
        local s, f, c = armed(function() Config.Kidnap.PlacerConfirms = true end)
        local ticks = math.floor((Config.Kidnap.CountdownSeconds * 1000) / Config.Kidnap.TickMs) + 2
        for _ = 1, ticks do s.kidnap.tick(Config.Kidnap.TickMs) end
        truthy(s.kidnap.placerConfirm(c.id), 'waiting on the placer')
        Env.clientEvents = {}
        truthy(s.kidnap.answer(c.id, f.creator.cid, false), 'declined')
        eq(s.kidnap.activeCount(), 0, 'no countdown left, so no tick after it')
        local _, cleared = sent()
        truthy(cleared[1] and cleared[1]['handover:' .. c.id], 'the placer\'s circle')
        truthy(cleared[3] and cleared[3]['handover:' .. c.id], 'the hitman\'s circle')
    end)

    it('is not drawn with its switch off', function()
        local s, f = stack()
        Config.StepMarkers.Handover = false
        local c = taken(s, f)
        for _, src in ipairs({ 1, 2, 3 }) do at(src, AT) end
        Env.players[2].PlayerData.metadata.ishandcuffed = true
        Env.clientEvents = {}
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        eq(next((sent())), nil)
    end)
end)

--------------------------------------------------------------------------
-- The guard's pin
--------------------------------------------------------------------------

describe('the protection pin', function()
    local function call(name, src, payload)
        local fire = Env.events['crimson-hitman:' .. name]
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

    RP.it('is drawn for the guard alone, moves with the pin, and comes off when the job ends', function()
        local s, f = stack()
        Config.Roleplay.Protection.Enabled = true
        Env.addPlayer({ source = 5, citizenid = 'GUARD001', license = 'license:g', cash = 0, bank = 0,
            firstname = 'Gus', lastname = 'Ward' })
        local c = taken(s, f)
        Env.players[2].PlayerData.money.bank = 100000
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        Env.runTimers()
        at(2, { x = 100.0, y = 200.0, z = 30.0 })
        local posted = call('protectionPost', 2, { id = c.id, amount = 2000,
            account = Config.Roleplay.Protection.Account })
        truthy(posted and posted.ok, 'posted: ' .. tostring(posted and posted.err))
        local job = posted.data.job
        Env.clientEvents = {}
        local took = call('protectionAccept', 5, { job = job, reward = 2000 })
        truthy(took and took.ok, 'taken: ' .. tostring(took and took.err))
        local key = 'guard:' .. job
        local set = sent()
        onlyTo(set, 5, key)
        eq(set[5][key].x, 100.0)
        falsy(set[2], 'never the target')

        Env.clientEvents = {}
        at(2, { x = 150.0, y = 260.0, z = 30.0 })
        truthy(call('protectionPin', 2, { job = job }).ok)
        set = sent()
        eq(set[5] and set[5][key] and set[5][key].x, 150.0, 'moved with the pin')

        Env.clientEvents = {}
        s.contracts.resolve(c.id, CH.STATE.CANCELLED, 'CREATOR1', nil, 'test')
        for _ = 1, 3 do s.rpProtection.sweep() end
        local state = s.rpProtection.all()[1].state
        truthy(state ~= 'taken', 'the job ended: ' .. tostring(state))
        local _, cleared = sent()
        truthy(cleared[5] and cleared[5][key], 'off the guard\'s map')
    end)
end)

--------------------------------------------------------------------------
-- Rejoin, idle
--------------------------------------------------------------------------

describe('the markers across a leave and a return', function()
    it('are forgotten when the player leaves and drawn again when their app asks', function()
        local s, f = stack()
        local c = taken(s, f)
        -- A step that outlives a leave (as body disposal does): the generic
        -- reshow, whatever the step.
        s.missionSteps.addProvider('test', function(add)
            add('HITMAN01', 'kill:' .. c.id, { kind = 'kill', x = BODY.x, y = BODY.y })
        end, function() return true end)
        Env.clientEvents = {}
        s.missionSteps.refresh()
        truthy(sent()[3], 'drawn')
        local saved = Env.players[3]
        s.bridges.onPlayerDropped(s, 'HITMAN01')
        Env.removePlayer(3)
        eq(s.missionSteps.shown().HITMAN01, nil, 'forgotten: their game took them off')
        Env.clientEvents = {}
        s.missionSteps.refresh()
        eq(#Env.clientEvents, 0, 'nothing sent to somebody away')
        Env.players[3] = saved
        Env.byCitizen.HITMAN01 = 3
        _G.source = 3
        Env.events['crimson-hitman:locationTips']({ __rid = 1 })
        _G.source = nil
        local set = sent()
        truthy(set[3] and set[3]['kill:' .. c.id], 'drawn again')
        local reply
        for _, e in ipairs(Env.clientEvents) do
            if e.name == 'crimson-hitman:result' then reply = e.args[1] end
        end
        truthy(reply and reply.ok)
        eq(reply.data.steps, 1, 'the page is told a count')
        for k, v in pairs(reply.data) do
            falsy(type(v) == 'table', 'and never where: ' .. tostring(k))
        end
    end)

    it('a kill to verify goes with a hitman who leaves, and is not drawn again', function()
        local s, f = stack()
        local c = taken(s, f)
        kill(s)
        local saved = Env.players[3]
        s.bridges.onPlayerDropped(s, 'HITMAN01')
        Env.removePlayer(3)
        Env.players[3] = saved
        Env.byCitizen.HITMAN01 = 3
        Env.clientEvents = {}
        _G.source = 3
        Env.events['crimson-hitman:locationTips']({ __rid = 1 })
        _G.source = nil
        falsy(sent()[3], 'the kill went with them (Death.clearPlayer), and its marker')
        falsy(s.death.getPending(c.id, 'HITMAN01'))
    end)
end)

describe('with nothing to draw', function()
    it('sends nothing and does nothing on the tick', function()
        local s = stack()
        Env.clientEvents = {}
        for _ = 1, 5 do falsy(s.missionSteps.tick(), 'nothing to look at') end
        eq(s.missionSteps.refresh(), 0)
        eq(#Env.clientEvents, 0)
    end)

    it('drops a malformed marker from a step rather than send it', function()
        local s = stack()
        s.missionSteps.addProvider('test', function(add)
            add('HITMAN01', 'kill:bad', { kind = 'kill', x = 0 / 0, y = 1 })
            add('HITMAN01', 'kill:bad2', { kind = 'nonsense', x = 1, y = 1 })
            add(nil, 'kill:bad3', { kind = 'kill', x = 1, y = 1 })
            error('and a step that raises')
        end, function() return true end)
        Env.clientEvents = {}
        truthy(pcall(s.missionSteps.refresh))
        eq(#Env.clientEvents, 0)
    end)
end)

--------------------------------------------------------------------------
-- The client
--------------------------------------------------------------------------

describe('the client\'s markers', function()
    local function drawn()
        local out = {}
        for _, blip in pairs(Client.blips) do out[#out + 1] = blip end
        return out
    end

    it('draws a step marker as the server sends it, and takes it off when told', function()
        Env.reset()
        Client.boot()
        truthy(Client.fire(STEP_EVENT, { key = 'kill:ct00000001', kind = 'kill', x = 12.5, y = -40.0 }))
        local blips = drawn()
        eq(#blips, 1)
        eq(blips[1].sprite, 303)
        eq(blips[1].name, 'Kill to verify')
        eq(blips[1].x, 12.5)
        falsy(blips[1].shortRange, 'seen from anywhere on the map')
        eq(#Client.nuiMessages, 0, 'nothing to the page')
        truthy(Client.fire(CLEAR_EVENT, { key = 'kill:ct00000001' }))
        eq(#drawn(), 0)
        truthy(Client.blipsMade[1].removed)
    end)

    it('draws a circle for the handover, and moves a marker sent again', function()
        Env.reset()
        Client.boot()
        Client.fire(STEP_EVENT, { key = 'handover:ct00000001', kind = 'handover', x = 1, y = 2, radius = 10 })
        local kinds = {}
        for _, b in ipairs(drawn()) do kinds[b.kind] = b end
        truthy(kinds.radius and kinds.coord, 'a circle and its centre')
        eq(kinds.radius.radius, 10)
        Client.fire(STEP_EVENT, { key = 'handover:ct00000001', kind = 'handover', x = 5, y = 6, radius = 10 })
        eq(#drawn(), 2, 'replaced, not added')
        for _, b in ipairs(drawn()) do eq(b.x, 5) end
    end)

    it('ignores what the server never sends', function()
        Env.reset()
        Client.boot()
        for _, payload in ipairs({ 'x', 42, {}, { key = 'kill:a', kind = 'kill', x = 0 / 0, y = 1 },
            { key = 'kill:a', kind = 'kill', x = math.huge, y = 1 }, { key = 'kill:a', kind = 'kill', x = 'a', y = 1 },
            { key = 'tip:a', kind = 'tip', x = 1, y = 1, radius = 10, secondsLeft = 60 },
            { key = 'meeting:a', kind = 'meeting', x = 1, y = 1 }, { key = 'x', kind = 'broker', x = 1, y = 1 },
            { key = ('k'):rep(65), kind = 'kill', x = 1, y = 1 }, { key = 'a b', kind = 'kill', x = 1, y = 1 },
            { key = 'handover:a', kind = 'handover', x = 1, y = 1 } }) do
            truthy(Client.fire(STEP_EVENT, payload))
        end
        eq(#drawn(), 0, 'nothing drawn')
        truthy(Client.fire(CLEAR_EVENT, 'x'))
        truthy(Client.fire(CLEAR_EVENT, { key = 'never-drawn' }))
    end)

    it('takes every marker off at a logout, an unload and the stop, not another resource\'s', function()
        for _, event in ipairs({ 'qbx_core:client:playerLoggedOut', 'QBCore:Client:OnPlayerUnload', 'onResourceStop' }) do
            Env.reset()
            Client.boot()
            Client.fire(STEP_EVENT, { key = 'kill:ct00000001', kind = 'kill', x = 1, y = 2 })
            Client.fire('crimson-hitman:meetingBlip', { id = 'ct00000002', x = 3, y = 4 })
            Client.fire('crimson-hitman:locationTip', { id = 'ct00000003', x = 5, y = 6, radius = 50, secondsLeft = 60 })
            eq(#drawn(), 4)
            if event == 'onResourceStop' then
                Client.fire(event, 'some-other-resource')
                eq(#drawn(), 4, 'another resource stopping takes nothing off')
                Client.fire(event, 'crimson-hitman')
            else
                -- The engine runs every handler of a local event; the harness
                -- keeps a net event of the same name apart (client/main.lua
                -- registers its own), so the event handlers are run here.
                local net = Client.netEvents[event]
                Client.netEvents[event] = nil
                Client.fire(event)
                Client.netEvents[event] = net
            end
            eq(#drawn(), 0, event .. ' takes them all off')
        end
    end)

    it('adds the body\'s ox_target option where ox_target runs, and takes it off with the marker', function()
        Env.reset()
        local zones, removed = {}, {}
        Natives.resourceStates['ox_target'] = 'started'
        Natives.exportTables['ox_target'] = {
            addSphereZone = function(_, spec) zones[#zones + 1] = spec return #zones end,
            removeZone = function(_, id) removed[#removed + 1] = id end,
        }
        _G.vector3 = _G.vector3 or function(x, y, z) return { x = x, y = y, z = z } end
        Client.boot()
        Client.fire(STEP_EVENT, { key = 'disposal_body:ct00000001', kind = 'disposal_body', x = 1, y = 2, z = 3,
            act = 'load', ref = 'ct00000001' })
        eq(#zones, 1, 'one zone')
        eq(zones[1].options[1].label, 'Load the body')
        Client.toServer = {}
        zones[1].options[1].onSelect()
        eq(Client.toServer[1].name, 'crimson-hitman:disposalAct')
        eq(Client.toServer[1].args[1].action, 'load')
        eq(Client.toServer[1].args[1].id, 'ct00000001', 'the contract alone: no position')
        falsy(Client.toServer[1].args[1].x)
        Client.fire(CLEAR_EVENT, { key = 'disposal_body:ct00000001' })
        eq(#removed, 1, 'the zone goes with the marker')
        Client.fire(STEP_EVENT, { key = 'disposal_drop:ct00000001', kind = 'disposal_drop', x = 1, y = 2, z = 3,
            act = 'teleport', ref = 'ct00000001' })
        eq(#zones, 1, 'no option for an action the server does not take')
        Natives.exportTables['ox_target'] = nil
        Natives.resourceStates['ox_target'] = nil
    end)

    it('keeps the tip and the meeting point as they were, on the same system', function()
        Env.reset()
        Client.boot()
        Client.fire('crimson-hitman:meetingBlip', { id = 'ct00000002', x = 3, y = 4 })
        local meeting = drawn()[1]
        eq(meeting.sprite, 162)
        eq(meeting.colour, 5)
        eq(meeting.name, 'Meeting point')
        truthy(Client.markers.get('meeting:ct00000002'))
        Client.fire('crimson-hitman:meetingBlipClear', { id = 'ct00000002' })
        eq(#drawn(), 0)
    end)
end)
