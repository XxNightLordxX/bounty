--- The handover's meeting point (server/meeting.lua, Config.Kidnap.MeetingPoint):
--- who may set it, who is shown it, what never carries it, when it goes,
--- where it may be, and how often it may change.

--- Where the person who placed it stands. Kept as 1234, -568.
local SPOT = { x = 1234.4, y = -567.6, z = 30.0 }

--- Fire a net event as a client does, rate limits and all, and return the
--- reply the page would receive. Env.clientEvents keeps what the call sent.
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

--- Everything in a payload, keys and values, as one string to search.
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

--- Whether anything in a payload says where the meeting point is, or that
--- there is one.
local function carries(value)
    local text = dump(value)
    return text:find('1234', 1, true) ~= nil or text:find('-568', 1, true) ~= nil
        or text:lower():find('meeting', 1, true) ~= nil
end

--- The phone notices one player was sent by the last call: { title, content }.
local function noticesTo(src)
    local out = {}
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'lb-phone:SendNotification' and event.target == src then
            out[#out + 1] = event.args[1]
        elseif event.name == 'crimson-hitman:notify' and event.target == src then
            out[#out + 1] = event.args[1]
        end
    end
    return out
end

local function pushesTo(src)
    local n = 0
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:push' and event.target == src then n = n + 1 end
    end
    return n
end

--- An alive-only contract a hitman holds, its placer standing at SPOT.
local function taken(opts)
    opts = opts or {}
    local s = newStack()
    Config.Completion.Fulfilment = opts.rule or 'alive'
    local f = fixture(s, { targetJob = opts.targetJob })
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt', anonymous = opts.anonymous,
        mode = opts.mode or CH.MODE.COMPETITIVE, bailoutAmount = opts.bailout,
        reward = { baseline = { cash = 5000 } },
    })
    truthy(c, 'placed')
    if opts.taken ~= false then truthy(s.contracts.accept(f.hitman, c.id, false), 'taken') end
    Env.players[1]._coords = { x = SPOT.x, y = SPOT.y, z = SPOT.z }
    return s, f, c
end

--- A second hitman, HITMAN02 at source 4, on the contract.
local function second(s, c)
    Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
        cash = 5000, bank = 5000, firstname = 'Jay', lastname = 'Fox' })
    truthy(s.contracts.accept(s.identity.resolve(4), c.id, false), 'a second hitman')
end

local function setHere(c, src, at)
    at = at or SPOT
    return call('setMeeting', src or 1, { id = c.id, x = at.x, y = at.y, z = at.z })
end

local function stored(s, c)
    local row = s.storage.readContract(c.id)
    return row.meeting_x, row.meeting_y
end

describe('the handover meeting point: who sets it', function()
    it('is set by the person who placed it, where they stand, to the metre', function()
        local s, _, c = taken()
        local reply = setHere(c)
        truthy(reply and reply.ok, 'set: ' .. tostring(reply and reply.err))
        eq(reply.data.moved, false)
        local x, y = stored(s, c)
        eq(x, 1234)
        eq(y, -568)
        s.audit.flush()
        local rows = s.storage.auditForContract(c.id, 50) or {}
        local found
        for _, row in ipairs(rows) do
            if row.action == 'meeting_set' then found = row end
        end
        truthy(found, 'audited')
        falsy(carries(found.detail), 'and the audit row says nothing of where')
    end)

    it('is refused to anybody but the person who placed it', function()
        local s, _, c = taken()
        Env.addPlayer({ source = 9, citizenid = 'STRANGER', license = 'license:s' })
        for _, src in ipairs({ 2, 3, 9 }) do
            Env.players[src]._coords = { x = SPOT.x, y = SPOT.y, z = SPOT.z }
            local reply = setHere(c, src)
            falsy(reply.ok, 'source ' .. src .. ' set it')
            eq(reply.err, CH.ERR.NOT_FOUND, 'source ' .. src .. ' is told there is no such contract')
            eq(call('clearMeeting', src, { id = c.id }).err, CH.ERR.NOT_FOUND)
        end
        eq(stored(s, c), nil, 'nothing was set')
    end)

    it('is only for a contract a live handover completes, while a hitman holds it', function()
        local _, _, either = taken({ rule = 'either' })
        eq(setHere(either).err, CH.ERR.BAD_STATE, 'a kill completes this one')

        local s, _, open = taken({ taken = false })
        eq(setHere(open).err, CH.ERR.MEETING_NO_HITMAN, 'nobody to meet')
        eq(stored(s, open), nil)
    end)
end)

describe('the handover meeting point: who is shown it', function()
    it('is told to the active hitmen alone, and names nobody', function()
        local s, _, c = taken({ anonymous = true })
        second(s, c)
        truthy(s.contracts.abandon(s.identity.resolve(4), c.id), 'the second walks away')
        -- Past the push floor the walk-away's own push started.
        Env.advance(5)

        local reply = setHere(c)
        truthy(reply.ok, tostring(reply.err))
        local told = noticesTo(3)
        eq(#told, 1, 'the hitman on it is told once')
        eq(told[1].title, 'Meeting point set')
        falsy(tostring(told[1].content):find('Vic', 1, true), 'the anonymous placer is not named')
        falsy(tostring(told[1].content):find('Marlowe', 1, true))
        falsy(carries({ told[1].content:gsub('[Mm]eeting point', '') }),
            'nor where it is')
        eq(#noticesTo(4), 0, 'not the one who left')
        eq(#noticesTo(2), 0, 'not the target')
        eq(#noticesTo(1), 0, 'not the placer')
        -- A push held behind the floor goes when it has passed.
        Env.advance(2)
        truthy(pushesTo(3) >= 1, 'the card of the hitman on it is moved on')
        eq(pushesTo(2), 0, 'and the target is not nudged')

        Env.advance(30)
        reply = setHere(c, 1, { x = SPOT.x + 2, y = SPOT.y, z = SPOT.z })
        truthy(reply.ok, tostring(reply.err))
        eq(reply.data.moved, true)
        eq(noticesTo(3)[1].title, 'Meeting point moved')
    end)

    it('is on an active hitman\'s card, and their Set GPS alone gets where', function()
        local s, _, c = taken()
        second(s, c)
        truthy(setHere(c).ok)
        truthy(s.contracts.abandon(s.identity.resolve(4), c.id), 'the second walks away')

        local row = s.projection.contract(s.storage.readContract(c.id), 'HITMAN01')
        eq(row.meetingSet, true, 'the hitman on it is shown one is set')
        falsy(dump(row):find('1234', 1, true), 'but not where')
        eq(s.projection.contract(s.storage.readContract(c.id), 'CREATOR1').meetingSet, true,
            'the placer sees their own is set')
        local gone = s.projection.contract(s.storage.readContract(c.id), 'HITMAN02')
        eq(gone.meetingSet, nil, 'the one who left is not')

        local gps = call('meetingWaypoint', 3, { id = c.id })
        truthy(gps.ok, tostring(gps.err))
        eq(gps.data.x, 1234)
        eq(gps.data.y, -568)
        Env.addPlayer({ source = 9, citizenid = 'STRANGER', license = 'license:s' })
        for _, src in ipairs({ 1, 2, 4, 9 }) do
            local refused = call('meetingWaypoint', src, { id = c.id })
            eq(refused.err, CH.ERR.NOT_FOUND, 'source ' .. src .. ' asked where')
            falsy(carries(refused.data), 'and was told nothing of it')
        end
    end)

    --- The projection test: every payload but an active hitman's card and
    --- the placer's own, searched for the point and for the word.
    it('never reaches the board, the target, the whitelisted view, the advisory or a '
        .. 'staff view without the identity ACE', function()
        local leo = { name = 'police', type = 'leo', onduty = true }
        local s, f, c = taken({ targetJob = leo, bailout = 15000 })
        Env.addPlayer({ source = 20, citizenid = 'OFFICER1', license = 'license:o1',
            job = leo, firstname = 'Ada', lastname = 'Kane' })
        Env.addPlayer({ source = 9, citizenid = 'STRANGER', license = 'license:s' })
        Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
            firstname = 'Sam', lastname = 'Steward' })
        Env.addPlayer({ source = 8, citizenid = 'UNMASK01', license = 'license:UNMASK01',
            firstname = 'Uma', lastname = 'Mask' })
        Env.aces[6] = { ['crimson.admin'] = true }
        Env.aces[8] = { ['crimson.admin'] = true, ['crimson.identity'] = true }
        Config.Cooldowns.admin = { per = 10, burst = 500 }
        s.bridges.install(s)
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        truthy(setHere(c).ok)

        -- An advisory sent after it: a second hitman's acceptance bulletin.
        Natives.calls.dispatch, Natives.calls.notifications = {}, {}
        second(s, c)
        falsy(carries(Natives.calls.dispatch), 'the dispatch advisory')
        for _, note in ipairs(Natives.calls.notifications) do
            falsy(carries(note), 'a bulletin: ' .. tostring(note.title))
        end

        for _, viewer in ipairs({ 'HITMAN01', 'CREATOR1', 'STRANGER', 'OFFICER1' }) do
            falsy(carries(s.projection.listing(viewer)), 'the board, to ' .. viewer)
        end
        falsy(carries(s.projection.onMe('TARGET01')), 'the target\'s On me')
        falsy(carries(s.projection.contract(s.storage.readContract(c.id), 'TARGET01')),
            'the target\'s card')
        falsy(carries(s.projection.contract(s.storage.readContract(c.id), 'STRANGER')),
            'anybody else\'s')
        falsy(carries(s.projection.whitelistedView('TARGET01', leo)), 'the target\'s view')
        falsy(carries(s.projection.whitelistedView('OFFICER1', leo)), 'a colleague\'s view')

        local function panel(src)
            Env.clientEvents = {}
            _G.source = src
            Env.events['crimson-hitman:admin']({ op = 'contract', data = { id = c.id }, __rid = 7 })
            _G.source = nil
            for _, event in ipairs(Env.clientEvents) do
                if event.name == 'crimson-hitman:adminResult' then return event.args[1] end
            end
        end
        local redacted = panel(6)
        truthy(redacted and redacted.ok, 'the contract view answers')
        -- Its timeline names the action, as it names every other the client
        -- takes in the app; never where.
        local text = dump(redacted)
        falsy(text:find('1234', 1, true) or text:find('-568', 1, true),
            'staff without the identity ACE are never told where')
        eq(redacted.data.contract.meeting, nil, 'nor shown a meeting point on the contract')
        local whole = panel(8)
        eq(whole.data.contract.meeting.x, 1234, 'staff with it see where')
        eq(whole.data.contract.meeting.y, -568)
        local _ = f
    end)
end)

describe('the handover meeting point: when it goes', function()
    local function ended(how)
        local s, f, c = taken({ bailout = 15000 })
        truthy(setHere(c).ok)
        how(s, f, c)
        local row = s.storage.readContract(c.id)
        truthy(CH.TERMINAL[row.state], 'it ended: ' .. tostring(row.state))
        eq(row.meeting_x, nil, 'the point outlived the ending')
        eq(row.meeting_y, nil)
        eq(call('meetingWaypoint', 3, { id = c.id }).err, CH.ERR.NOT_FOUND)
    end

    for _, ending in ipairs({ CH.STATE.EXPIRED, CH.STATE.CANCELLED, CH.STATE.BAILED_OUT,
        CH.STATE.VOIDED }) do
        it('with the contract ' .. ending, function()
            ended(function(s, _, c)
                truthy(s.contracts.resolve(c.id, ending, 'CREATOR1', nil, 'test'))
            end)
        end)
    end

    it('with the contract completed by the handover', function()
        ended(function(s, _, c)
            for _, src in ipairs({ 1, 2, 3 }) do
                Env.players[src]._coords = { x = SPOT.x, y = SPOT.y, z = SPOT.z }
            end
            Env.players[2].PlayerData.metadata.ishandcuffed = true
            truthy(s.kidnap.arm(c.id, 'HITMAN01'), 'the handover arms')
            for _ = 1, math.floor(Config.Kidnap.CountdownSeconds * 1000 / Config.Kidnap.TickMs) do
                s.kidnap.tick(Config.Kidnap.TickMs)
            end
        end)
    end)

    it('with an ending a crash stopped part-way, by its recovery', function()
        ended(function(s, _, c)
            -- The state moved and nothing after it ran.
            truthy(s.storage.compareSetContractState(c.id, CH.STATE.ACCEPTED, CH.STATE.VOIDED))
            truthy(s.storage.readContract(c.id).meeting_x, 'still there before recovery')
            s.contracts.recoverEnded(c.id)
        end)
    end)

    it('when the last active hitman walks away, and not before', function()
        local s, _, c = taken()
        second(s, c)
        truthy(setHere(c).ok)
        truthy(s.contracts.abandon(s.identity.resolve(4), c.id))
        eq(stored(s, c), 1234, 'kept while a hitman is still on it')
        truthy(s.contracts.abandon(s.identity.resolve(3), c.id))
        eq(stored(s, c), nil, 'gone with the last one')

        Env.addPlayer({ source = 9, citizenid = 'NEWHIT01', license = 'license:n' })
        truthy(s.contracts.accept(s.identity.resolve(9), c.id, false))
        eq(s.projection.contract(s.storage.readContract(c.id), 'NEWHIT01').meetingSet, nil,
            'the next to take it never sees where the placer stood')
    end)

    it('when the last hitman is taken off for idling', function()
        local s, _, c = taken({ mode = CH.MODE.EXCLUSIVE })
        truthy(setHere(c).ok)
        Env.players[3]._coords = { x = 5000.0, y = 5000.0, z = 0.0 }
        s.contracts.releaseIdleHolds()
        for _ = 1, math.ceil(Config.Limits.ExclusiveIdleReleaseSeconds / 60) + 1 do
            Env.advance(60)
            s.death.watchTargets(s.storage.allContracts())
            s.contracts.releaseIdleHolds()
        end
        eq(s.storage.readHitman(c.id, 'HITMAN01').state, 'released')
        eq(stored(s, c), nil)
    end)

    it('when a walk-away stopped part-way, by the repair the next start runs', function()
        local s, _, c = taken()
        truthy(setHere(c).ok)
        local row = s.storage.readHitman(c.id, 'HITMAN01')
        truthy(s.storage.abandonHitman(row.id, c.id, os.time()), 'the row moved and nothing else')
        eq(stored(s, c), 1234)
        s.contracts.repairHeld(c.id)
        eq(stored(s, c), nil)
    end)

    it('when the placer clears it, and the hitman\'s card is moved on', function()
        local s, _, c = taken()
        truthy(setHere(c).ok)
        -- Past the rule, and the floor of the push the set sent.
        Env.advance(30)
        local reply = call('clearMeeting', 1, { id = c.id })
        truthy(reply.ok, tostring(reply.err))
        eq(stored(s, c), nil)
        eq(#noticesTo(3), 0, 'with no phone notice')
        Env.advance(2)
        truthy(pushesTo(3) >= 1, 'pushed')
        eq(s.projection.contract(s.storage.readContract(c.id), 'CREATOR1').meetingSet, false,
            'the placer\'s controls stay, with none set')
        Env.advance(30)
        eq(call('clearMeeting', 1, { id = c.id }).err, CH.ERR.NO_MEETING)
    end)
end)

describe('the handover meeting point: where it may be', function()
    it('is set only within a few metres of where the server sees the placer', function()
        local s, _, c = taken()
        local reply = setHere(c, 1, { x = SPOT.x + 6, y = SPOT.y, z = SPOT.z })
        eq(reply.err, CH.ERR.MEETING_NOT_HERE, '6 m from their character')
        eq(stored(s, c), nil)
        reply = setHere(c, 1, { x = SPOT.x + 4, y = SPOT.y, z = SPOT.z })
        truthy(reply.ok, '4 m is the same place, a moment apart: ' .. tostring(reply.err))
        eq(stored(s, c), 1238)

        Env.advance(30)
        Env.players[1]._coords = nil
        eq(setHere(c).err, CH.ERR.MEETING_NOT_HERE, 'a character the server cannot place')
    end)

    it('takes finite numbers on the map and nothing else', function()
        local s, _, c = taken()
        for label, bad in pairs({
            nan = { x = 0 / 0, y = SPOT.y, z = SPOT.z },
            infinite = { x = math.huge, y = SPOT.y, z = SPOT.z },
            text = { x = '1234', y = SPOT.y, z = SPOT.z },
            missing = { x = SPOT.x, y = SPOT.y },
        }) do
            bad.id = c.id
            eq(call('setMeeting', 1, bad).err, CH.ERR.INVALID_INPUT, label)
        end
        -- Off the map, standing there all the same.
        Env.players[1]._coords = { x = 9000.0, y = SPOT.y, z = SPOT.z }
        eq(setHere(c, 1, { x = 9000.0, y = SPOT.y, z = SPOT.z }).err, CH.ERR.MEETING_NOT_HERE)
        eq(stored(s, c), nil)
    end)
end)

describe('the handover meeting point: how often it changes', function()
    it('changes at most once every 30 seconds, a clear included', function()
        local s, _, c = taken()
        truthy(setHere(c).ok)
        Env.advance(10)
        local reply = setHere(c)
        eq(reply.err, CH.ERR.MEETING_TOO_SOON)
        eq(reply.data.retryAfter, 20)
        eq(call('clearMeeting', 1, { id = c.id }).err, CH.ERR.MEETING_TOO_SOON)
        Env.advance(20)
        reply = setHere(c, 1, { x = SPOT.x + 3, y = SPOT.y, z = SPOT.z })
        truthy(reply.ok, tostring(reply.err))
        eq(reply.data.moved, true)
        eq(call('clearMeeting', 1, { id = c.id }).err, CH.ERR.MEETING_TOO_SOON)
        Env.advance(30)
        truthy(call('clearMeeting', 1, { id = c.id }).ok)
        eq(setHere(c).err, CH.ERR.MEETING_TOO_SOON, 'and after a clear')
    end)

    it('is kept by the store\'s own write, so two read at once cannot both land', function()
        local s, _, c = taken()
        local now = os.time()
        truthy(s.storage.setMeeting(c.id, 1, 2, now, now - 30))
        falsy(s.storage.setMeeting(c.id, 3, 4, now, now - 30), 'the second, read before the first')
        eq(stored(s, c), 1)
    end)
end)

describe('the handover meeting point: the switch', function()
    it('off hides it and refuses changes, and keeps the point', function()
        local s, _, c = taken()
        truthy(setHere(c).ok)
        Config.Kidnap.MeetingPoint = false
        Env.advance(30)
        eq(setHere(c).err, CH.ERR.FEATURE_OFF)
        eq(call('clearMeeting', 1, { id = c.id }).err, CH.ERR.FEATURE_OFF)
        eq(call('meetingWaypoint', 3, { id = c.id }).err, CH.ERR.FEATURE_OFF)
        eq(s.projection.contract(s.storage.readContract(c.id), 'CREATOR1').meetingSet, nil,
            'no controls')
        eq(s.projection.contract(s.storage.readContract(c.id), 'HITMAN01').meetingSet, nil)
        eq(stored(s, c), 1234, 'the point is kept')

        Config.Kidnap.MeetingPoint = true
        eq(s.projection.contract(s.storage.readContract(c.id), 'HITMAN01').meetingSet, true,
            'and shown again')
    end)

    it('is a Features switch kept across restarts', function()
        local s = taken()
        local entry = s.settings.entry('Kidnap.MeetingPoint')
        truthy(entry, 'in the catalogue')
        eq(entry.section, 'features')
        eq(entry.kind, 'switch')
        local ok, err = s.settings.set('Kidnap.MeetingPoint', false, 'STAFF01')
        truthy(ok, tostring(err))
        eq(Config.Kidnap.MeetingPoint, false)
        eq(s.storage.readSettings()['Kidnap.MeetingPoint'].value, false, 'kept in the store')
    end)
end)
