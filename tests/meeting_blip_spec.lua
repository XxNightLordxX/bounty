--- The meeting point's map marker and its instructions (server/meeting.lua,
--- client/main.lua): who is shown the marker, who never is, every way it
--- comes off, how it comes back after a rejoin, and what each side is told
--- to do to finish the handover.

local Client = require('tests.harness.client')
local Bridges = require('crimson-hitman.server.bridges')

--- Where the person who placed it stands. Kept as 1234, -568.
local SPOT = { x = 1234.4, y = -567.6, z = 30.0 }

--- The one marker event pair (server/lib/markers.lua, client/missionsteps.lua):
--- the meeting point is kind 'meeting', keyed 'meeting:<contract>'.
local BLIP, CLEAR = 'crimson-hitman:client:StepMarker', 'crimson-hitman:client:StepMarkerClear'

--- A meeting point as the server sends it, for the client half: { id, x, y }
--- as a marker. Anything else is sent as it is.
local function meetingMarker(d)
    if type(d) ~= 'table' or type(d.id) ~= 'string' then return d end
    return { key = 'meeting:' .. d.id, kind = 'meeting', x = d.x, y = d.y }
end

--- Fire a net event as a client does and return the reply the page gets.
--- Env.clientEvents keeps what the call sent (emptied first).
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

--- The events of one name sent since Env.clientEvents was last emptied,
--- as { [src] = { payload, ... } }.
local function sent(name)
    local out = {}
    for _, event in ipairs(Env.clientEvents) do
        local key = type(event.args[1]) == 'table' and event.args[1].key
        if event.name == name and type(key) == 'string' and key:sub(1, 8) == 'meeting:' then
            out[event.target] = out[event.target] or {}
            table.insert(out[event.target], event.args[1])
        end
    end
    return out
end

local function count(map)
    local n = 0
    for _ in pairs(map) do n = n + 1 end
    return n
end

--- The phone notices one player was sent since the events were emptied.
local function noticesTo(src)
    local out = {}
    for _, event in ipairs(Env.clientEvents) do
        if (event.name == 'lb-phone:SendNotification' or event.name == 'crimson-hitman:notify')
            and event.target == src then
            out[#out + 1] = event.args[1]
        end
    end
    return out
end

--- Everything in a value, keys and values, as one string to search.
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

--- An alive-only contract HITMAN01 (source 3) holds, its placer (source 1)
--- standing at SPOT, the bridges installed as main.lua installs them.
local function taken(opts)
    opts = opts or {}
    local s = newStack()
    Config.Completion.Fulfilment = 'alive'
    local f = fixture(s)
    s.bridges.install(s)
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt', anonymous = opts.anonymous,
        mode = opts.mode or CH.MODE.COMPETITIVE, bailoutAmount = opts.bailout,
        reward = { baseline = { cash = 5000 } },
    })
    truthy(c, 'placed')
    truthy(s.contracts.accept(f.hitman, c.id, false), 'taken')
    Env.players[1]._coords = { x = SPOT.x, y = SPOT.y, z = SPOT.z }
    -- A bystander and a member of staff, neither a party.
    Env.addPlayer({ source = 9, citizenid = 'STRANGER', license = 'license:s' })
    Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
        firstname = 'Sam', lastname = 'Steward' })
    Env.aces[6] = { ['crimson.admin'] = true, ['crimson.identity'] = true }
    return s, f, c
end

--- A second hitman, HITMAN02 at source 4, on the contract.
local function second(s, c)
    Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
        cash = 5000, bank = 5000, firstname = 'Jay', lastname = 'Fox' })
    Env.clientEvents = {}
    truthy(s.contracts.accept(s.identity.resolve(4), c.id, false), 'a second hitman')
end

local function setHere(c, at)
    at = at or SPOT
    return call('setMeeting', 1, { id = c.id, x = at.x, y = at.y, z = at.z })
end

--- Nobody but the parties named was sent a marker or a clear.
local function onlyTo(map, allowed, what)
    for src in pairs(map) do
        truthy(allowed[src], what .. ' went to source ' .. tostring(src))
    end
end

describe('the meeting point marker: who is shown it', function()
    it('goes to the placer and the active hitman, at the point, and to nobody else', function()
        local s, _, c = taken()
        local reply = setHere(c)
        truthy(reply and reply.ok, tostring(reply and reply.err))
        local blips = sent(BLIP)
        eq(count(blips), 2, 'two parties')
        for _, src in ipairs({ 1, 3 }) do
            truthy(blips[src], 'source ' .. src .. ' shown it')
            eq(#blips[src], 1)
            eq(blips[src][1].key, 'meeting:' .. c.id)
            eq(blips[src][1].x, 1234)
            eq(blips[src][1].y, -568)
        end
        onlyTo(blips, { [1] = true, [3] = true }, 'the marker')
        eq(blips[2], nil, 'never the target')
        eq(blips[9], nil, 'never a bystander')
        eq(blips[6], nil, 'never staff who are not a party')
        -- The page is never sent where: the reply carries no coordinates.
        falsy(dump(reply):find('1234', 1, true), 'the reply to the page says nothing of where')
        local _ = s
    end)

    it('goes to every active hitman, not to one who walked away', function()
        local s, _, c = taken()
        second(s, c)
        truthy(s.contracts.abandon(s.identity.resolve(4), c.id))
        Env.advance(5)
        truthy(setHere(c).ok)
        local blips = sent(BLIP)
        truthy(blips[1] and blips[3], 'the placer and the one on it')
        eq(blips[4], nil, 'not the one who left')
    end)

    it('is drawn for nobody while the feature is off, and comes back when it is on', function()
        local s, _, c = taken()
        truthy(setHere(c).ok)
        Env.clientEvents = {}
        local ok = s.settings.set('Kidnap.MeetingPoint', false, 'STAFF01')
        truthy(ok)
        local cleared = sent(CLEAR)
        truthy(cleared[1] and cleared[3], 'off takes it off both maps')
        onlyTo(cleared, { [1] = true, [3] = true }, 'the clear')
        eq(call('locationTips', 3).ok, true)
        eq(sent(BLIP)[3], nil, 'and a rejoin draws nothing while it is off')

        Env.clientEvents = {}
        truthy(s.settings.set('Kidnap.MeetingPoint', true, 'STAFF01'))
        local back = sent(BLIP)
        truthy(back[1] and back[3], 'on again, it is drawn again')
        eq(back[2], nil)
    end)
end)

describe('the meeting point marker: what each side is told', function()
    it('tells the placer and the hitman what to do, in the app\'s own words', function()
        local _, _, c = taken()
        truthy(setHere(c).ok)
        local placer, hitman = noticesTo(1), noticesTo(3)
        eq(#placer, 1, 'the placer is told once')
        eq(#hitman, 1, 'the hitman is told once')
        eq(placer[1].title, 'Meeting point set')
        eq(hitman[1].title, 'Meeting point set')
        local p, h = tostring(placer[1].content), tostring(hitman[1].content)
        truthy(p:find('marked on your map', 1, true), p)
        truthy(p:find('within 12 m', 1, true), p)
        truthy(p:find('Deliver alive', 1, true), p)
        truthy(p:find('30 seconds', 1, true), p)
        truthy(p:find('Open the app on your phone', 1, true), p)
        truthy(p:find('nothing to tap', 1, true), p)
        truthy(h:find('alive to the meeting point marked on your map', 1, true), h)
        truthy(h:find('within 12 m', 1, true), h)
        truthy(h:find('open the app on your phone', 1, true), h)
        truthy(h:find('tap Deliver alive', 1, true), h)
        truthy(h:find('hold for 30 seconds', 1, true), h)
        eq(#noticesTo(2), 0, 'nothing to the target')
        eq(#noticesTo(9), 0, 'nothing to a bystander')
    end)

    it('says what to do again when the point moves', function()
        local _, _, c = taken()
        truthy(setHere(c).ok)
        Env.advance(30)
        truthy(setHere(c, { x = SPOT.x + 3, y = SPOT.y, z = SPOT.z }).ok)
        eq(noticesTo(1)[1].title, 'Meeting point moved')
        eq(noticesTo(3)[1].title, 'Meeting point moved')
        truthy(tostring(noticesTo(3)[1].content):find('Deliver alive', 1, true))
        local blips = sent(BLIP)
        eq(blips[1][1].x, 1237, 'the placer\'s marker moves')
        eq(blips[3][1].x, 1237, 'and the hitman\'s')
    end)

    it('asks for restraint when the server does', function()
        local _, _, c = taken()
        Config.Kidnap.RequireCoercion = true
        truthy(setHere(c).ok)
        truthy(tostring(noticesTo(3)[1].content):find('cuffed or in your vehicle', 1, true),
            noticesTo(3)[1].content)
    end)

    it('carries the same words on each side\'s card, and on no one else\'s', function()
        local s, _, c = taken()
        truthy(setHere(c).ok)
        local row = s.storage.readContract(c.id)
        local placerCard = s.projection.contract(row, 'CREATOR1')
        local hitmanCard = s.projection.contract(row, 'HITMAN01')
        eq(type(placerCard.meetingSteps), 'string')
        eq(type(hitmanCard.meetingSteps), 'string')
        truthy(tostring(noticesTo(1)[1].content):find(placerCard.meetingSteps, 1, true),
            'the placer\'s notice says what their card says')
        truthy(tostring(noticesTo(3)[1].content):find(hitmanCard.meetingSteps, 1, true),
            'the hitman\'s notice says what their card says')
        eq(s.projection.contract(row, 'TARGET01').meetingSteps, nil, 'not on the target\'s card')
        eq(s.projection.contract(row, 'STRANGER').meetingSteps, nil, 'nor anybody else\'s')
        for _, entry in ipairs(s.projection.listing('HITMAN01').contracts or {}) do
            eq(entry.meetingSteps, nil, 'nor on the board')
        end
        falsy(dump(placerCard):find('1234', 1, true), 'and never where')
    end)

    it('names nobody: no placer to the hitman, no hitman to the placer', function()
        local _, _, c = taken({ anonymous = true })
        truthy(setHere(c).ok)
        local h, p = dump(noticesTo(3)), dump(noticesTo(1))
        for _, word in ipairs({ 'Vic', 'Marlowe', 'CREATOR1', 'license:aaa' }) do
            falsy(h:find(word, 1, true), 'the hitman is not told ' .. word)
        end
        for _, word in ipairs({ 'Rook', 'Ash', 'HITMAN01', 'license:ccc' }) do
            falsy(p:find(word, 1, true), 'the placer is not told ' .. word)
        end
        for _, payload in ipairs(sent(BLIP)[3]) do
            local keys = {}
            for k in pairs(payload) do keys[#keys + 1] = k end
            table.sort(keys)
            eq(table.concat(keys, ','), 'key,kind,x,y', 'the marker carries the point and nothing else')
        end
    end)
end)

describe('the meeting point marker: when it comes off', function()
    --- Set it, empty the events, run `how`, and return who was sent a clear.
    local function after(how, opts)
        local s, f, c = taken(opts)
        truthy(setHere(c).ok)
        Env.clientEvents = {}
        how(s, f, c)
        return sent(CLEAR), s, c
    end

    it('when the placer clears it', function()
        local s, _, c = taken()
        truthy(setHere(c).ok)
        Env.advance(30)
        truthy(call('clearMeeting', 1, { id = c.id }).ok)
        local cleared = sent(CLEAR)
        truthy(cleared[1] and cleared[3], 'off both maps')
        onlyTo(cleared, { [1] = true, [3] = true }, 'the clear')
        local _ = s
    end)

    it('when it moves: replaced on both maps, never a second marker', function()
        local _, _, c = taken()
        truthy(setHere(c).ok)
        Env.advance(30)
        truthy(setHere(c, { x = SPOT.x + 2, y = SPOT.y, z = SPOT.z }).ok)
        local blips = sent(BLIP)
        eq(#blips[1], 1)
        eq(#blips[3], 1)
        -- The client draws one per contract id, so the new one replaces the
        -- old (the client spec below).
        eq(blips[3][1].key, 'meeting:' .. c.id)
    end)

    it('when the handover completes the contract', function()
        local cleared = after(function(s, _, c)
            for _, src in ipairs({ 1, 2, 3 }) do
                Env.players[src]._coords = { x = SPOT.x, y = SPOT.y, z = SPOT.z }
            end
            Env.players[2].PlayerData.metadata.ishandcuffed = true
            local armed, why = s.kidnap.arm(c.id, 'HITMAN01')
            truthy(armed, 'the handover arms: ' .. tostring(why))
            for _ = 1, math.floor(Config.Kidnap.CountdownSeconds * 1000 / Config.Kidnap.TickMs) do
                s.kidnap.tick(Config.Kidnap.TickMs)
            end
            eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED)
        end)
        truthy(cleared[1] and cleared[3], 'off both maps')
        eq(cleared[2], nil)
    end)

    for _, ending in ipairs({ CH.STATE.EXPIRED, CH.STATE.CANCELLED, CH.STATE.BAILED_OUT,
        CH.STATE.VOIDED }) do
        it('when the contract is ' .. ending, function()
            local cleared = after(function(s, _, c)
                truthy(s.contracts.resolve(c.id, ending, 'CREATOR1', nil, 'test'))
            end, { bailout = 15000 })
            truthy(cleared[1] and cleared[3], ending .. ': off both maps')
            onlyTo(cleared, { [1] = true, [3] = true }, 'the clear')
        end)
    end

    it('when the hitman withdraws from the contract in the app', function()
        local cleared = after(function(s, _, c)
            local reply = call('abandon', 3, { id = c.id })
            truthy(reply and reply.ok, tostring(reply and reply.err))
            eq(s.storage.readHitman(c.id, 'HITMAN01').state ~= 'active', true)
        end)
        truthy(cleared[3], 'off the hitman\'s map')
        truthy(cleared[1], 'and the placer\'s, with nobody coming')
        onlyTo(cleared, { [1] = true, [3] = true }, 'the clear')
    end)

    it('when the placer withdraws a contract back on the board', function()
        -- A taken contract cannot be withdrawn (contract_taken): it is the
        -- walk-away that puts it back on the board, and the marker went then.
        local s, _, c = taken()
        truthy(setHere(c).ok)
        local reply = call('cancel', 1, { id = c.id })
        eq(reply.err, CH.ERR.CONTRACT_TAKEN, 'refused while a hitman holds it')
        eq(#(sent(CLEAR)[1] or {}), 0, 'and the marker stays')
        local _ = s
    end)

    it('when the target buys their way out', function()
        local cleared = after(function(s, _, c)
            truthy(s.contracts.resolve(c.id, CH.STATE.BAILED_OUT, 'TARGET01', nil, 'bailout'))
        end, { bailout = 15000 })
        truthy(cleared[1] and cleared[3])
    end)

    it('off a hitman who walks away, while the placer and the other keep it', function()
        local s, _, c = taken()
        second(s, c)
        Env.advance(5)
        truthy(setHere(c).ok)
        Env.clientEvents = {}
        truthy(s.contracts.abandon(s.identity.resolve(4), c.id))
        local cleared = sent(CLEAR)
        truthy(cleared[4], 'off the map of the one who left')
        eq(cleared[1], nil, 'the placer keeps it')
        eq(cleared[3], nil, 'the other hitman keeps it')

        Env.clientEvents = {}
        truthy(s.contracts.abandon(s.identity.resolve(3), c.id))
        cleared = sent(CLEAR)
        truthy(cleared[3], 'the last one loses it')
        truthy(cleared[1], 'and the placer, now nobody is coming')
    end)

    it('off a hitman taken off for idling', function()
        local cleared = after(function(s, _, c)
            Env.players[3]._coords = { x = 5000.0, y = 5000.0, z = 0.0 }
            s.contracts.releaseIdleHolds()
            for _ = 1, math.ceil(Config.Limits.ExclusiveIdleReleaseSeconds / 60) + 1 do
                Env.advance(60)
                s.death.watchTargets(s.storage.allContracts())
                s.contracts.releaseIdleHolds()
            end
            eq(s.storage.readHitman(c.id, 'HITMAN01').state, 'released')
        end, { mode = CH.MODE.EXCLUSIVE })
        truthy(cleared[3] and cleared[1], 'off both maps')
    end)

    it('off a hitman staff remove', function()
        local s, _, c = taken()
        second(s, c)
        Env.advance(5)
        truthy(setHere(c).ok)
        Env.clientEvents = {}
        local row = s.storage.readHitman(c.id, 'HITMAN02')
        local ok, err = s.staffContract.removeHitman({ cid = 'ADMIN001', name = 'Sam' }, c.id,
            row.id, 'test removal')
        truthy(ok, tostring(err))
        local cleared = sent(CLEAR)
        truthy(cleared[4], 'off the removed hitman\'s map')
        eq(cleared[1], nil, 'the placer keeps it while a hitman is on it')
        eq(cleared[3], nil)
        eq(cleared[6], nil, 'staff are sent nothing')
    end)

    it('a walk-away left part-way is put right by the repair, off the placer\'s map too', function()
        local cleared = after(function(s, _, c)
            local row = s.storage.readHitman(c.id, 'HITMAN01')
            truthy(s.storage.abandonHitman(row.id, c.id, os.time()))
            s.contracts.repairHeld(c.id)
        end)
        truthy(cleared[1], 'the placer\'s map')
        truthy(cleared[3], 'the hitman\'s')
    end)

    it('is not sent again to a player who logged out, and is forgotten for them', function()
        local s, _, c = taken()
        truthy(setHere(c).ok)
        Bridges.onPlayerDropped(s, 'HITMAN01')
        Env.removePlayer(3)
        Env.advance(30)
        Env.clientEvents = {}
        truthy(call('clearMeeting', 1, { id = c.id }).ok)
        local cleared = sent(CLEAR)
        truthy(cleared[1], 'the placer still in the city')
        eq(cleared[3], nil, 'nothing to a source nobody is on (the client cleared its own)')
    end)
end)

describe('the meeting point marker: coming back, and coming late', function()
    it('is drawn again for a party who rejoins, and for nobody else', function()
        local s, _, c = taken()
        truthy(setHere(c).ok)
        Bridges.onPlayerDropped(s, 'HITMAN01')
        Env.removePlayer(3)
        Env.addPlayer({ source = 3, citizenid = 'HITMAN01', license = 'license:ccc',
            firstname = 'Rook', lastname = 'Ash' })
        local reply = call('locationTips', 3)
        truthy(reply and reply.ok, tostring(reply and reply.err))
        local blips = sent(BLIP)
        truthy(blips[3], 'the hitman is shown it again')
        eq(blips[3][1].x, 1234)
        falsy(dump(reply):find('1234', 1, true), 'and the page is told nothing of where')

        call('locationTips', 1)
        truthy(sent(BLIP)[1], 'the placer too')
        for _, src in ipairs({ 2, 9, 6 }) do
            call('locationTips', src)
            eq(sent(BLIP)[src], nil, 'source ' .. src .. ' is shown nothing')
        end
    end)

    it('is drawn for a hitman who takes the contract after it was set, and told what to do', function()
        local s, _, c = taken()
        truthy(setHere(c).ok)
        second(s, c)
        local blips = sent(BLIP)
        truthy(blips[4], 'the late hitman is shown it on accepting')
        eq(blips[4][1].x, 1234)
        eq(blips[1], nil, 'the placer is not sent it twice')
        eq(blips[3], nil, 'nor the first hitman')
        local told = noticesTo(4)
        eq(#told, 1)
        eq(told[1].title, 'Meeting point set')
        truthy(tostring(told[1].content):find('Deliver alive', 1, true))
    end)

    it('is not drawn for a hitman who takes a contract with none set', function()
        local s, _, c = taken()
        second(s, c)
        eq(sent(BLIP)[4], nil)
    end)
end)

--------------------------------------------------------------------------
-- The client
--------------------------------------------------------------------------

describe('the meeting point marker on the client', function()
    local function markers()
        local out = {}
        for _, blip in pairs(Client.blips) do out[#out + 1] = blip end
        return out
    end

    it('draws one named, long-range marker per contract, and replaces it when moved', function()
        Env.reset()
        Client.boot()
        truthy(Client.fire(BLIP, meetingMarker({ id = 'ct00000001', x = 1234, y = -568 })))
        local shown = markers()
        eq(#shown, 1)
        eq(shown[1].kind, 'coord')
        eq(shown[1].x, 1234.0)
        eq(shown[1].y, -568.0)
        eq(shown[1].name, 'Meeting point')
        eq(shown[1].shortRange, false, 'seen from anywhere on the map')
        truthy(shown[1].sprite and shown[1].sprite ~= 1, 'its own sprite, not the tip\'s')
        truthy(shown[1].colour and shown[1].colour ~= 1, 'its own colour, not the tip\'s red')

        Client.fire(BLIP, meetingMarker({ id = 'ct00000001', x = 1300, y = -500 }))
        shown = markers()
        eq(#shown, 1, 'moved, not doubled')
        eq(shown[1].x, 1300.0)
        Client.fire(BLIP, meetingMarker({ id = 'ct00000002', x = 1, y = 2 }))
        eq(#markers(), 2, 'one each for two contracts')

        Client.fire(CLEAR, { key = 'meeting:ct00000001' })
        shown = markers()
        eq(#shown, 1, 'cleared one')
        eq(shown[1].x, 1.0, 'the other contract\'s stays')
    end)

    it('ignores what is not a marker', function()
        Env.reset()
        Client.boot()
        Client.fire(BLIP, meetingMarker('nope'))
        Client.fire(BLIP, meetingMarker({ id = 'ct00000001', x = 'a', y = 2 }))
        Client.fire(BLIP, meetingMarker({ id = 5, x = 1, y = 2 }))
        eq(#markers(), 0)
        Client.fire(CLEAR, 'nope')
    end)

    it('takes every marker off on logout and as the resource stops', function()
        for _, event in ipairs({ 'QBCore:Client:OnPlayerUnload', 'qbx_core:client:playerLoggedOut',
            'onResourceStop' }) do
            Env.reset()
            Client.boot()
            Client.fire(BLIP, meetingMarker({ id = 'ct00000001', x = 1, y = 2 }))
            Client.fire(BLIP, meetingMarker({ id = 'ct00000002', x = 3, y = 4 }))
            eq(#markers(), 2)
            -- The engine's handlers for it, not another file's net event of
            -- the same name (Client.fire prefers those).
            local net = Client.netEvents[event]
            Client.netEvents[event] = nil
            truthy(Client.fire(event, 'crimson-hitman'))
            Client.netEvents[event] = net
            eq(#markers(), 0, event .. ' left a marker')
        end
    end)

    it('is never passed to the page', function()
        Env.reset()
        Client.boot()
        Client.fire(BLIP, meetingMarker({ id = 'ct00000001', x = 1234, y = -568 }))
        falsy(dump(Client.nuiMessages):find('1234', 1, true), 'nothing of where to the page')
    end)
end)
