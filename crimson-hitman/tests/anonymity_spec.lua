--- Two worlds, one observer.
---
--- Each test here builds the same city twice, differing in one thing the
--- observer is not meant to learn: whether a hidden party is standing near
--- them, who that party is, or whether a contract has just been placed on
--- them. Everything the observer can read is then compared, whole. If the
--- two answers differ in any way at all, the difference is the leak.

--- A value as one string, keys sorted, so two answers compare whole.
local function encode(value)
    if type(value) ~= 'table' then
        return type(value) == 'string' and ('%q'):format(value) or tostring(value)
    end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = tostring(key) .. '=' .. encode(value[key])
    end
    return '{' .. table.concat(parts, ',') .. '}'
end

--- Fire a net event as a player, the way their client does, and read the
--- reply sent back to them. Nothing else in Env.clientEvents is touched, so
--- a test can still read every event a player was ever sent.
local function call(name, source, payload)
    local fire = Env.events['crimson-hitman:' .. name]
    truthy(fire, 'no handler registered for ' .. name)
    local from = #Env.clientEvents
    _G.source = source
    fire(payload or {})
    _G.source = nil
    for i = from + 1, #Env.clientEvents do
        local event = Env.clientEvents[i]
        if event.name == 'crimson-hitman:result' and event.target == source then
            return event.args[1]
        end
    end
    return nil
end

local function at(src, x)
    Env.players[src]._coords = { x = x, y = 0.0, z = 0.0 }
end

--- The nearby list, once everybody's client has said whether they are
--- masked, as each does when its character loads.
local function nearby(source)
    Env.reportMasks()
    local reply = call('browseTargets', source, { scope = 'nearby' })
    truthy(reply and reply.ok, 'the nearby list must answer: ' .. tostring(reply and reply.err))
    return reply.data
end

local function namesIn(data)
    local out = {}
    for _, person in ipairs(data.people or {}) do out[person.name] = person end
    return out
end

local WAIT = function() return Config.Notifications.ParanoidAlertJitter.max + 1 end

--------------------------------------------------------------------------
-- Place -> Nearby
--------------------------------------------------------------------------

describe('the nearby list, two worlds apart', function()
    --- A target whose anonymous hitman is closing in. They were told there is
    --- an operative on them; the list put a name and a distance to the metre
    --- on the person behind them, through walls, every second.
    it('shows a target the same whether their anonymous hitman is beside them or not', function()
        local function hunted(hitmanAt, strangerAt)
            local s = newStack()
            local f = fixture(s)
            local seen
            withConfig({ { Config.Targeting, 'AllowNearby', true } }, function()
                at(1, 2000); at(2, 0); at(3, hitmanAt)
                if strangerAt then
                    Env.addPlayer({ source = 10, citizenid = 'STRANGER', license = 'license:st',
                        firstname = 'Ada', lastname = 'Quill', coords = { x = strangerAt, y = 0, z = 0 } })
                end
                local c = s.contracts.create(f.creator, {
                    targetCid = 'TARGET01', reason = 'x', anonymous = true,
                    reward = { baseline = { cash = 5000 } },
                })
                truthy(c, 'the contract')
                truthy(s.contracts.accept(f.hitman, c.id, true), 'taken anonymously')
                Env.advance(WAIT())
                truthy(#s.projection.onMe('TARGET01') == 1, 'and the target has been shown it')
                seen = nearby(2)
            end)
            return seen
        end

        local beside = hunted(5)
        eq(beside.closed, true, 'closed to a target, whoever is near')
        eq(#beside.people, 0)
        local far = encode(hunted(500))
        eq(encode(beside), far, 'the hitman five metres away changed what the target saw')
        eq(encode(hunted(500, 5)), far,
            'somebody else standing there changed it: the hitman would be the one missing')
    end)

    --- A live handover needs the client within a few metres of the hitman,
    --- inside the list's radius, so the list named an anonymous client to
    --- the hitman at every delivery, mask or no mask.
    it('shows a hitman the same whether the anonymous client is at the handover or not', function()
        local function handover(clientAt)
            local s = newStack()
            local f = fixture(s)
            local seen
            withConfig({ { Config.Targeting, 'AllowNearby', true } }, function()
                at(1, clientAt); at(2, 2); at(3, 0)
                local c = s.contracts.create(f.creator, {
                    targetCid = 'TARGET01', reason = 'x', anonymous = true,
                    reward = { baseline = { cash = 5000 } },
                })
                truthy(s.contracts.accept(f.hitman, c.id, false))
                seen = nearby(3)
            end)
            return encode(seen)
        end
        eq(handover(3), handover(500), 'the client beside the hitman was named to him')
    end)

    --- The handover pays with all three a few metres apart, and the
    --- contract closes in that same moment. The list reopened at once, and
    --- named the anonymous hitman and the anonymous client to the others
    --- still standing there.
    it('stays closed to all three once a handover pays, while they stand together', function()
        local function delivered(afterwards)
            local s = newStack()
            local f = fixture(s)
            local seen = {}
            withConfig({ { Config.Targeting, 'AllowNearby', true } }, function()
                at(1, 900); at(2, 0); at(3, 500)
                local c = s.contracts.create(f.creator, {
                    targetCid = 'TARGET01', reason = 'x', anonymous = true,
                    reward = { baseline = { cash = 5000 } },
                })
                truthy(s.contracts.accept(f.hitman, c.id, true), 'taken anonymously')
                Env.advance(WAIT())
                at(1, 3); at(2, 0); at(3, 2)
                Env.players[2].PlayerData.metadata.ishandcuffed = true
                truthy(s.kidnap.arm(c.id, 'HITMAN01'), 'the handover arms')
                local ticks = math.ceil(Config.Kidnap.CountdownSeconds * 1000 / Config.Kidnap.TickMs)
                for _ = 1, ticks + 1 do s.kidnap.tick(Config.Kidnap.TickMs) end
                eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED, 'it paid')
                Env.players[2].PlayerData.metadata.ishandcuffed = false
                if afterwards then afterwards() end
                for _, src in ipairs({ 1, 2, 3 }) do seen[src] = nearby(src) end
            end)
            return seen
        end

        local together = delivered()
        local apart = delivered(function() at(1, 900); at(2, 0); at(3, 500) end)
        for src, who in pairs({ 'the client', 'the target', 'the hitman' }) do
            eq(together[src].closed, true, 'closed to ' .. who .. ' as the handover pays')
            eq(encode(together[src]), encode(apart[src]),
                'the others standing beside ' .. who .. ' changed what they saw')
        end

        local later = delivered(function()
            Env.advance(Config.Targeting.NearbyClosedAfterSeconds + 1)
        end)
        for src, who in pairs({ 'the client', 'the target', 'the hitman' }) do
            falsy(later[src].closed, 'open again to ' .. who .. ' once the time has passed')
        end
    end)

    --- Closing the list to a target over a contract withdrawn inside the
    --- reveal wait would tell them it had existed.
    it('stays open to the target of a contract withdrawn inside the wait', function()
        local function street(placeAndWithdraw)
            local s = newStack()
            local f = fixture(s)
            local seen
            withConfig({ { Config.Targeting, 'AllowNearby', true } }, function()
                at(1, 900); at(2, 0); at(3, 4)
                if placeAndWithdraw then
                    local c = s.contracts.create(f.creator, {
                        targetCid = 'TARGET01', reason = 'x', anonymous = true,
                        reward = { baseline = { cash = 5000 } },
                    })
                    truthy(c)
                    truthy(s.contracts.cancel(f.creator, c.id), 'withdrawn at once')
                end
                Env.advance(30)
                seen = nearby(2)
            end)
            return encode(seen)
        end
        eq(street(true), street(false), 'the target could tell a contract had come and gone')
    end)

    it('shows a client the same whether their anonymous hitman is beside them or not', function()
        local function waiting(hitmanAt)
            local s = newStack()
            local f = fixture(s)
            local seen
            withConfig({ { Config.Targeting, 'AllowNearby', true } }, function()
                at(1, 0); at(2, 900); at(3, hitmanAt)
                local c = s.contracts.create(f.creator, {
                    targetCid = 'TARGET01', reason = 'x',
                    reward = { baseline = { cash = 5000 } },
                })
                truthy(s.contracts.accept(f.hitman, c.id, true))
                seen = nearby(1)
            end)
            return encode(seen)
        end
        eq(waiting(4), waiting(500), 'an anonymous hitman was named to the client')
    end)

    --- Somebody on no contract at all, with an unmasked bystander beside
    --- them so the list is not empty for the wrong reason.
    local function street(extra)
        local s = newStack()
        fixture(s)
        local seen
        withConfig({ { Config.Targeting, 'AllowNearby', true } }, function()
            at(1, 5000); at(2, 6000); at(3, 7000)
            Env.addPlayer({ source = 10, citizenid = 'WATCHER1', license = 'license:w1',
                firstname = 'Wes', lastname = 'Hale', coords = { x = 0, y = 0, z = 0 } })
            Env.addPlayer({ source = 11, citizenid = 'BYSTAND1', license = 'license:b1',
                firstname = 'Bea', lastname = 'Lowe', coords = { x = 3, y = 0, z = 0 } })
            if extra then extra() end
            seen = nearby(10)
        end)
        return seen
    end

    local function person(name, cid, x, fields)
        local first, last = name:match('(%S+) (%S+)')
        local p = Env.addPlayer({ source = 12, citizenid = cid, license = 'license:' .. cid,
            firstname = first, lastname = last, coords = { x = x, y = 0, z = 0 } })
        for k, v in pairs(fields or {}) do p[k] = v end
    end

    it('never names a masked person, whoever they are, or says that one is there', function()
        local empty = street()
        truthy(namesIn(empty)['Bea Lowe'], 'the bystander is listed: the list works')
        local masked = { _masked = true }
        eq(encode(street(function() person('Mia Vance', 'MASKED01', 6, masked) end)), encode(empty),
            'a masked person six metres away changed the list')
        eq(encode(street(function() person('Lou Park', 'MASKED02', 6, masked) end)), encode(empty),
            'and who is under the mask must not matter either')
        truthy(namesIn(street(function() person('Mia Vance', 'MASKED01', 6) end))['Mia Vance'],
            'the same person, unmasked, is listed')
    end)

    it('names nobody in another routing bucket, or invisible, as if they were not there', function()
        local empty = encode(street())
        eq(encode(street(function() person('Ivy Stone', 'INSTANCE', 2, { _bucket = 7 }) end)), empty,
            'a player in an instance changed the list')
        eq(encode(street(function() person('Ivy Stone', 'NOCLIP01', 2, { _invisible = true }) end)), empty,
            'an invisible player (noclip, spectating staff) changed the list')
    end)

    --- The server cannot see clothes. GetPedDrawableVariation is a client
    --- native, nil on FXServer; read on the server it failed for everyone,
    --- and the list was always empty in game. Each client says instead.
    it('works on a server with no clothing native, from what each client says', function()
        eq(_G.GetPedDrawableVariation, nil, 'FXServer has no GetPedDrawableVariation')
        local seen = street()
        truthy(namesIn(seen)['Bea Lowe'], 'a bystander whose client said bare face is listed')
        eq(#seen.people, 1, 'and only her')
    end)

    it('leaves off anybody whose client has said nothing, as if masked', function()
        eq(encode(street(function() person('Mia Vance', 'SILENT01', 6, { _silent = true }) end)),
            encode(street()), 'a player whose client never said was named')
    end)

    --- A report is the sender's word about the sender. A lie hides them, or
    --- lists them masked, which taking the mask off would do anyway; it
    --- cannot move anybody else.
    it('lets a report move only the player who sent it', function()
        local function told(masked)
            return street(function()
                person('Mia Vance', 'LIAR0001', 6, { _masked = masked })
            end)
        end
        local function others(data)
            local rows = {}
            for _, row in ipairs(data.people) do
                if row.name ~= 'Mia Vance' then
                    rows[#rows + 1] = row.name .. '@' .. tostring(row.metres)
                end
            end
            return table.concat(rows, ',')
        end
        local hidden, shown = told(true), told(false)
        falsy(namesIn(hidden)['Mia Vance'], 'saying masked takes them off')
        truthy(namesIn(shown)['Mia Vance'], 'saying bare-faced lists them, mask or not')
        truthy(others(hidden) ~= '', 'the bystander is there to be moved')
        eq(others(hidden), others(shown), 'what one player said moved somebody else')
    end)

    it('takes nothing but a yes or no, and only about whoever sent it', function()
        local function claims(...)
            local sent = table.pack(...)
            return street(function()
                person('Mia Vance', 'SENDER01', 6, { _silent = true })
                -- The bystander's own client has said nothing either.
                Env.players[11]._silent = true
                _G.source = 12
                for i = 1, sent.n do Env.events['crimson-hitman:maskState'](sent[i]) end
                _G.source = nil
            end)
        end
        local quiet = claims()
        eq(#quiet.people, 0, 'nobody has said anything, so nobody is listed')
        eq(encode(claims({ source = 11, masked = false }, { [11] = false }, 'false', 0, 11, nil)),
            encode(quiet), 'a report that was not a plain yes or no changed the list')
        local own = claims(false)
        truthy(namesIn(own)['Mia Vance'], 'her own word lists her')
        falsy(namesIn(own)['Bea Lowe'], 'and nobody else')
    end)

    --- What a client said was about one character on one connection. The
    --- next to hold the source, or the next character on it, has said
    --- nothing.
    it('forgets what a client said when its player leaves, logs out or switches character', function()
        for how, leave in pairs({
            dropped = function() _G.source = 11; Env.handlers['playerDropped'](); _G.source = nil end,
            unloaded = function() Env.handlers['QBCore:Server:OnPlayerUnload'](11) end,
            loggedOut = function() Env.handlers['qbx_core:server:playerLoggedOut'](11) end,
        }) do
            local s = newStack()
            fixture(s)
            s.bridges.install(s)
            withConfig({ { Config.Targeting, 'AllowNearby', true } }, function()
                at(1, 5000); at(2, 6000); at(3, 7000)
                Env.addPlayer({ source = 10, citizenid = 'WATCHER1', license = 'license:w1',
                    firstname = 'Wes', lastname = 'Hale', coords = { x = 0, y = 0, z = 0 } })
                Env.addPlayer({ source = 11, citizenid = 'BYSTAND1', license = 'license:b1',
                    firstname = 'Bea', lastname = 'Lowe', coords = { x = 3, y = 0, z = 0 } })
                truthy(namesIn(nearby(10))['Bea Lowe'], how .. ': listed while her client has said')
                leave()
                -- Back on the same source, her client not having said yet.
                Env.players[11]._silent = true
                falsy(namesIn(nearby(10))['Bea Lowe'], how .. ': what she said was kept')
            end)
        end
    end)

    --- From a real player with a character loaded, and only while the list
    --- is on (§4). A report sent before a character loaded was kept, and the
    --- character that then loaded on that source was listed on it.
    it('hears a mask only from a loaded character, while the list is on', function()
        local s = newStack()
        fixture(s)
        s.bridges.install(s)
        local function say(src, masked)
            _G.source = src
            local ok, err = pcall(Env.events['crimson-hitman:maskState'], masked)
            _G.source = nil
            truthy(ok, tostring(err))
        end
        local function bea()
            local p = Env.addPlayer({ source = 11, citizenid = 'BYSTAND1', license = 'license:b1',
                firstname = 'Bea', lastname = 'Lowe', coords = { x = 3, y = 0, z = 0 } })
            p._silent = true
        end
        at(1, 5000); at(2, 6000); at(3, 7000)
        Env.addPlayer({ source = 10, citizenid = 'WATCHER1', license = 'license:w1',
            firstname = 'Wes', lastname = 'Hale', coords = { x = 0, y = 0, z = 0 } })
        bea()

        -- Said while the list is off: not kept for when it is turned on.
        say(11, false)
        withConfig({ { Config.Targeting, 'AllowNearby', true } }, function()
            falsy(namesIn(nearby(10))['Bea Lowe'], 'heard while the list was off')

            -- Said with no character on the source, or from no player.
            Env.removePlayer(11)
            say(11, false)
            say(0, false)
            say(-1, false)
            bea()
            falsy(namesIn(nearby(10))['Bea Lowe'], 'kept from before her character loaded')

            say(11, false)
            truthy(namesIn(nearby(10))['Bea Lowe'], 'her own word, once loaded, lists her')
        end)
    end)

    it('forgets what a client said when a character loads on its source', function()
        local s = newStack()
        fixture(s)
        s.bridges.install(s)
        withConfig({ { Config.Targeting, 'AllowNearby', true } }, function()
            at(1, 5000); at(2, 6000); at(3, 7000)
            Env.addPlayer({ source = 10, citizenid = 'WATCHER1', license = 'license:w1',
                firstname = 'Wes', lastname = 'Hale', coords = { x = 0, y = 0, z = 0 } })
            Env.addPlayer({ source = 11, citizenid = 'BYSTAND1', license = 'license:b1',
                firstname = 'Bea', lastname = 'Lowe', coords = { x = 3, y = 0, z = 0 } })
            truthy(namesIn(nearby(10))['Bea Lowe'], 'listed while her client has said')
            -- qbx_core's login, before her client has said anything for it.
            Env.players[11]._silent = true
            Env.handlers['QBCore:Server:PlayerLoaded'](Env.players[11])
            falsy(namesIn(nearby(10))['Bea Lowe'], 'what was said before the login was kept')
        end)
    end)

    it('stops listening to a client that floods it', function()
        local s = newStack()
        fixture(s)
        withConfig({ { Config.Targeting, 'AllowNearby', true } }, function()
            at(1, 5000); at(2, 6000); at(3, 7000)
            Env.addPlayer({ source = 10, citizenid = 'WATCHER1', license = 'license:w1',
                firstname = 'Wes', lastname = 'Hale', coords = { x = 0, y = 0, z = 0 } })
            Env.addPlayer({ source = 11, citizenid = 'FLOODER1', license = 'license:f1',
                firstname = 'Bea', lastname = 'Lowe', coords = { x = 3, y = 0, z = 0 } })
            Env.players[11]._silent = true
            local report = Env.events['crimson-hitman:maskState']
            _G.source = 11
            for _ = 1, 200 do report(true) end
            report(false)
            _G.source = nil
            falsy(namesIn(nearby(10))['Bea Lowe'], 'the flood guard let the two hundred and first through')
            -- A window later she is heard again.
            Env.advance(11)
            _G.source = 11
            report(false)
            _G.source = nil
            truthy(namesIn(nearby(10))['Bea Lowe'], 'and heard again once the window has passed')
        end)
    end)

    it('gives a band, not a distance, and orders inside it by name', function()
        local function pair(adaAt, boAt)
            return street(function()
                Env.players[11]._coords = { x = 900, y = 0, z = 0 }
                Env.addPlayer({ source = 13, citizenid = 'ADA00001', license = 'license:a1',
                    firstname = 'Ada', lastname = 'Quill', coords = { x = adaAt, y = 0, z = 0 } })
                Env.addPlayer({ source = 14, citizenid = 'BO000001', license = 'license:b2',
                    firstname = 'Bo', lastname = 'Renn', coords = { x = boAt, y = 0, z = 0 } })
            end)
        end
        local one = pair(1, 9)
        eq(encode(one), encode(pair(9, 1)),
            'which of two people in the same band is nearer must not show')
        eq(one.people[1].name, 'Ada Quill')
        eq(one.people[1].metres, 10, '"under 10m", not the figure')
        local split = pair(4, 23)
        eq(split.people[1].metres, 10)
        eq(split.people[2].metres, 30, 'twenty-three metres is under thirty')
    end)
end)

--------------------------------------------------------------------------
-- A new contract, before the target is told
--------------------------------------------------------------------------

describe('a contract placed on somebody, two worlds apart', function()
    --- Everything the target's phone can see, at one moment.
    local function whatTheTargetSees(s, f)
        local events = {}
        for _, event in ipairs(Env.clientEvents) do
            if event.target == 2 and event.name ~= 'crimson-hitman:result' then
                events[#events + 1] = { name = event.name, args = event.args }
            end
        end
        local mine = call('mine', 2, {})
        truthy(mine and mine.ok, 'the target can read their own tabs')
        return {
            events = events,
            mine = mine.data,
            cleanse = s.bailout.available(f.target),
            nearby = nearby(2),
        }
    end

    --- The real path: the creator picks the target from the list, places it
    --- anonymously and reads the reply; a hitman reads the board and takes
    --- it, anonymously too; the creator looks at Mine. Every one of those
    --- used to ask the target's own phone for a headshot, at once.
    local function city(placed)
        local s = newStack()
        local f = fixture(s)
        local seen, id
        withConfig({ { Config.Targeting, 'AllowNearby', true } }, function()
            at(1, 3000); at(2, 0); at(3, 5)
            -- The client looks through the list in both worlds: looking is
            -- not the thing being hidden, placing is.
            local list = call('browseTargets', 1, { scope = 'all' })
            local handle
            for _, row in ipairs(list.data.people) do
                if row.name == 'Dana Reyes' then handle = row.handle end
            end
            if placed then
                local made = call('create', 1, {
                    target = handle, reason = 'x', mode = 'exclusive', anonymous = true,
                    reward = { slots = { { baseline = { cash = 5000 } } } },
                    bailoutAmount = 20000,
                })
                truthy(made and made.ok, 'placed: ' .. tostring(made and made.err))
                id = made.data.id
                truthy(call('list', 3, { page = 1 }).ok)
                local took = call('accept', 3, { id = id, anonymous = true, penaltyAmount = 0 })
                truthy(took and took.ok, 'taken: ' .. tostring(took and took.err))
                truthy(call('mine', 1, {}).ok)
            end
            seen = whatTheTargetSees(s, f)
        end)
        return s, f, seen, id
    end

    it('shows the target nothing of it until the wait is over', function()
        local _, _, quiet = city(false)
        local s, f, placed, id = city(true)
        eq(encode(placed), encode(quiet),
            'the target could tell, the moment it happened, that a contract had been placed')
        truthy(namesIn(placed.nearby)['Rook Ash'],
            'the nearby list is open to them as to anybody, hitman included')

        -- And once it is over, all of it at once.
        withConfig({ { Config.Targeting, 'AllowNearby', true } }, function()
            Env.advance(WAIT())
            -- First thing: the next look at the contract asks the target's
            -- phone for a face, which nothing did inside the wait.
            local from = #Env.clientEvents
            truthy(call('list', 3, { page = 1 }).ok)
            local asked = false
            for i = from + 1, #Env.clientEvents do
                local event = Env.clientEvents[i]
                if event.name == 'crimson-hitman:renderMugshot' and event.target == 2 then
                    asked = true
                end
            end
            truthy(asked, 'a board view now asks their phone for a face')

            local after = whatTheTargetSees(s, f)
            eq(#after.mine.onMe, 1, 'On me shows it')
            eq(after.mine.onMe[1].id, id)
            eq(#after.cleanse, 1, '/cleanse lists it')
            eq(after.nearby.closed, true, 'and the nearby list closes')
            local alerted = false
            for _, event in ipairs(after.events) do
                if Natives.isNotice(event)
                    and tostring(event.args[1].content):find('eyes on you', 1, true) then
                    alerted = true
                end
            end
            truthy(alerted, 'the alert arrived with it')
        end)
    end)

    --- Withdrawn inside the wait, it rang the target's phone with a push for
    --- a contract their On me tab never showed.
    it('says nothing to the target of one withdrawn inside the wait', function()
        local function eventsToTarget(placeAndWithdraw)
            local s = newStack()
            local f = fixture(s)
            if placeAndWithdraw then
                local c = s.contracts.create(f.creator, {
                    targetCid = 'TARGET01', reason = 'x', anonymous = true,
                    reward = { baseline = { cash = 5000 } },
                })
                truthy(c)
                truthy(s.contracts.cancel(f.creator, c.id), 'withdrawn at once')
            end
            -- Past the longest wait: the alert drawn for it went off then.
            Env.advance(Config.Notifications.ParanoidAlertJitter.max + 5)
            local seen = {}
            for _, event in ipairs(Env.clientEvents) do
                if event.target == 2 then seen[#seen + 1] = { name = event.name, args = event.args } end
            end
            return encode(seen)
        end
        eq(eventsToTarget(true), eventsToTarget(false),
            'the target was told something happened to a contract they never saw')
    end)

    local function alertsTo(src)
        local n = 0
        for _, event in ipairs(Env.clientEvents) do
            if event.target == src and Natives.isNotice(event)
                and tostring(event.args[1].content):find('eyes on you', 1, true) then
                n = n + 1
            end
        end
        return n
    end

    --- And it used up the target's cooldown, so the next contract placed on
    --- them went unannounced.
    it('gives the cooldown back when the one it was for is withdrawn inside the wait', function()
        local s = newStack()
        local f = fixture(s)
        local first = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', anonymous = true,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(s.contracts.cancel(f.creator, first.id), 'withdrawn at once')
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 5)
        eq(alertsTo(2), 0, 'nothing said of it')

        Env.addPlayer({ source = 10, citizenid = 'CLIENT02', license = 'license:c2',
            firstname = 'Lee', lastname = 'Moss', cash = 50000, bank = 50000 })
        local second, why = s.contracts.create(s.identity.resolve(10), {
            targetCid = 'TARGET01', reason = 'y', anonymous = true,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(second, 'another, placed after by somebody else: ' .. tostring(why))
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 5)
        eq(alertsTo(2), 1, 'and it is announced, as the first never was')
    end)

    --- Two placed inside one wait share its alert. The first withdrawn, the
    --- second still out, the target is still told.
    it('still alerts for a second contract when the first is withdrawn in the wait', function()
        local s = newStack()
        local f = fixture(s)
        local first = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', anonymous = true,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(first)
        Env.addPlayer({ source = 10, citizenid = 'CLIENT02', license = 'license:c2',
            firstname = 'Lee', lastname = 'Moss', cash = 50000, bank = 50000 })
        local other = s.identity.resolve(10)
        local second, why = s.contracts.create(other, {
            targetCid = 'TARGET01', reason = 'y', anonymous = true,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(second, 'a second client: ' .. tostring(why))
        truthy(s.contracts.cancel(f.creator, first.id), 'the first withdrawn')
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 5)
        eq(alertsTo(2), 1, 'the second is still out, and the target is told')
    end)

    it('draws a different wait for each contract, inside the configured window', function()
        local seenAt = {}
        for _ = 1, 6 do
            local s = newStack()
            local f = fixture(s)
            truthy(s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
            }))
            local waited = 0
            while #s.projection.onMe('TARGET01') == 0 and waited < 2000 do
                Env.advance(10)
                waited = waited + 10
            end
            truthy(waited >= Config.Notifications.ParanoidAlertJitter.min,
                'shown before the shortest wait: ' .. waited)
            truthy(waited <= Config.Notifications.ParanoidAlertJitter.max + 10,
                'held back past the longest: ' .. waited)
            seenAt[waited] = true
        end
        local distinct = 0
        for _ in pairs(seenAt) do distinct = distinct + 1 end
        truthy(distinct > 1, 'six contracts, one wait: it is drawn, not fixed')
    end)

    it('tells an officer\'s /cleanse at once, as their department is told', function()
        local s = newStack()
        local f = fixture(s, { targetJob = { name = 'police', type = 'leo', onduty = true } })
        truthy(s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
            bailoutAmount = 5000,
        }))
        eq(#s.bailout.available(f.target), 1,
            'the bulletin dated it for every officer; holding back theirs hides nothing')
    end)

    --- The wait lives in memory. A restart forgets it, and shows what it
    --- held back at once: a restart is not the moment anybody placed one.
    it('shows it at once after a restart', function()
        local function forget()
            for name in pairs(package.loaded) do
                if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
                    package.loaded[name] = nil
                end
            end
        end
        forget()
        Env.reset()
        Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
        Natives.resetResourceStates()
        resetConfig()
        Config.Database.Mode = 'json'
        Natives.files = {}
        local s = require('server.main').start()
        local f = fixture(s)
        truthy(s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', anonymous = true,
            reward = { baseline = { cash = 5000 } },
        }))
        eq(#s.projection.onMe('TARGET01'), 0, 'held back in the process that placed it')

        -- The process dies; the disk and the players stay.
        rawset(s.storage, '__rawFixture', true)
        forget()
        Env.events, Env.clientEvents, Env.notifications = {}, {}, {}
        Env.handlers, Env.threads, Env.timers, Env.commands = {}, {}, {}, {}
        local again = require('server.main').start()
        eq(#again.projection.onMe('TARGET01'), 1, 'shown at once by the one that came back')
        resetConfig()
    end)
end)

--------------------------------------------------------------------------
-- Goods put up by an anonymous client
--------------------------------------------------------------------------

describe('goods from an anonymous client, two worlds apart', function()
    --- The same city, with the client under one name or another. What they
    --- carry is the same in kind and names them in its metadata, as a real
    --- engraved lighter, car key or phone would.
    local function client(first, last, cid)
        local s = newStack()
        local full = first .. ' ' .. last
        Env.addPlayer({
            source = 1, citizenid = cid, license = 'license:' .. cid,
            cash = 100000, bank = 100000, firstname = first, lastname = last,
            inventory = {
                { name = 'lockpick', count = 5, metadata = { durability = 80 } },
                { name = 'lighter', count = 1, metadata = { inscription = 'To ' .. full } },
                { name = 'carkey', count = 1, metadata = { owner = 'somebody', plate = 'ABC 123' } },
                { name = 'phone_green', count = 1, metadata = { lbPhoneNumber = '5550101' } },
                { name = 'identification', count = 1, metadata = { type = full } },
            },
        })
        Env.addPlayer({ source = 2, citizenid = 'TARGET01', license = 'license:bbb',
            cash = 20000, bank = 20000, firstname = 'Dana', lastname = 'Reyes' })
        Env.addPlayer({ source = 3, citizenid = 'HITMAN01', license = 'license:ccc',
            cash = 5000, bank = 5000, firstname = 'Rook', lastname = 'Ash' })
        return s, s.identity.resolve(1)
    end

    local function carrying(name)
        local n = 0
        for _, slot in ipairs(Env.players[1]._inventory) do
            if slot.name == name then n = n + (slot.count or 0) end
        end
        return n
    end

    local function place(s, actor, item, anonymous)
        return s.contracts.create(actor, {
            targetCid = 'TARGET01', reason = 'x', anonymous = anonymous,
            reward = { baseline = { items = { { name = item, count = 1 } } } },
        })
    end

    --- What the hitman would be handed for a contract: every line, as stored.
    local function handedOver(s, contractId)
        local out = {}
        for _, line in ipairs(s.storage.readEscrow(contractId)) do
            out[#out + 1] = { item = line.item, quantity = line.quantity, metadata = line.metadata }
        end
        return out
    end

    local function world(first, last, cid)
        local s, actor = client(first, last, cid)
        local refused = {}
        for _, item in ipairs({ 'lighter', 'carkey', 'phone_green' }) do
            local c, err = place(s, actor, item, true)
            falsy(c, item .. ' named its anonymous client and was taken anyway')
            refused[item] = err
            eq(carrying(item), 1, 'and nothing was taken for it')
        end
        local _, idErr = place(s, actor, 'identification', true)
        refused.identification = idErr
        local c = place(s, actor, 'lockpick', true)
        truthy(c, 'an item that names nobody still goes up')
        return { refused = refused, goods = handedOver(s, c.id) }
    end

    it('hands the hitman the same goods whoever the client is', function()
        local vic = world('Vic', 'Marlowe', 'CREATOR1')
        local ann = world('Ann', 'Other', 'CREATOR9')
        eq(vic.refused.lighter, CH.ERR.ITEM_NAMES_OWNER, 'refused with its own words')
        eq(vic.refused.identification, CH.ERR.INVALID_REWARD,
            'an identity document is never escrowed at all')
        eq(encode(vic), encode(ann), 'what reached the hitman depended on who the client was')
    end)

    it('takes the same item on a contract placed under the client\'s name', function()
        local s, actor = client('Vic', 'Marlowe', 'CREATOR1')
        truthy(place(s, actor, 'lighter', false),
            'a client who chose to be seen gives nothing away by it')
    end)

    it('refuses it as a top-up to an anonymous contract too', function()
        local s, actor = client('Vic', 'Marlowe', 'CREATOR1')
        local c = place(s, actor, 'lockpick', true)
        truthy(c)
        local ok, err = s.amendments.addEscrow(actor, c.id,
            { baseline = { items = { { name = 'lighter', count = 1 } } } })
        falsy(ok)
        eq(err, CH.ERR.ITEM_NAMES_OWNER)
        eq(carrying('lighter'), 1, 'nothing was taken')
    end)

    it('never offers an identity document in the picker', function()
        local s, actor = client('Vic', 'Marlowe', 'CREATOR1')
        for _, row in ipairs(s.app.escrowableItems(actor)) do
            falsy(row.name == 'identification', 'offered: ' .. row.name)
        end
    end)

    --- W102: offered like anything else, then the whole anonymous contract
    --- refused without saying which item. Marked in the picker, so the form
    --- can hold it back, and named in the refusal.
    it('marks a stack that names its owner, and names it when it is refused', function()
        local s, actor = client('Vic', 'Marlowe', 'CREATOR1')
        local marked = {}
        for _, row in ipairs(s.app.escrowableItems(actor)) do marked[row.name] = row.namesOwner end
        eq(marked.carkey, true, 'a key with its owner on it')
        falsy(marked.lockpick, 'a lockpick names nobody')

        local c, err, refusal = place(s, actor, 'carkey', true)
        falsy(c)
        eq(err, CH.ERR.ITEM_NAMES_OWNER)
        eq(refusal and refusal.item, 'carkey', 'the item, by name')
    end)
end)

--------------------------------------------------------------------------
-- Informant data, paid for once
--------------------------------------------------------------------------

describe('informant data the target pays for', function()
    --- A contract on the target with an anonymous operative the sampler
    --- has seen on them, and the informant wired as main.lua wires it.
    local function tracked()
        local s = newStack()
        local f = fixture(s)
        s.informant.init({ storage = s.storage, identity = s.identity, audit = s.audit,
            death = s.death, contracts = s.contracts })
        local c = assert(s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        }))
        truthy(s.contracts.accept(f.hitman, c.id, true))
        s.death.watchTargets(s.storage.allContracts())
        Env.players[2].PlayerData.money.bank = 100000
        return s, f, c
    end

    local function spent() return 100000 - Env.players[2].PlayerData.money.bank end

    --- The fee is taken and never refunded, so the paid answer is given
    --- whatever the store does with the record of it.
    it('answers the name it was paid for when the record of it will not write', function()
        local s, f, c = tracked()
        local real = s.storage.writeReveal
        s.storage.writeReveal = function() error('the connection dropped', 0) end
        local ran, ok, err, data = pcall(s.informant.buy, f.target, c.id)
        s.storage.writeReveal = real
        truthy(ran, 'the purchase raised: ' .. tostring(ok))
        truthy(ok, tostring(err))
        eq(data.name, 'Rook Ash')
        eq(spent(), Config.Informant.Cost, 'charged once')
        s.audit.flush()
        local kept = false
        for _, row in ipairs(s.storage.readAudit()) do
            if row.action == 'informant_unremembered' then kept = true end
        end
        truthy(kept, 'staff are told the purchase was not kept')
    end)

    --- A read that raised after the charge kept the fee with nothing to say
    --- it was paid, and every retry paid it again.
    it('charges once across a read that raised and a retry', function()
        local s, f, c = tracked()
        local real, raised = s.storage.readHitmen, false
        s.storage.readHitmen = function(...)
            if not raised then
                raised = true
                error('the connection dropped', 0)
            end
            return real(...)
        end
        falsy(pcall(s.informant.buy, f.target, c.id), 'the read raised')
        eq(spent(), 0, 'and nothing was taken for it')
        local ok, err, data = s.informant.buy(f.target, c.id)
        s.storage.readHitmen = real
        truthy(ok, tostring(err))
        eq(data.name, 'Rook Ash')
        eq(spent(), Config.Informant.Cost, 'one fee for one answer')
    end)

    --- Checked once, before an await, and only for closed: a contract being
    --- paid out, or one that ended in that await, was still sold.
    it('is refused uncharged on a contract that started paying out inside the purchase', function()
        local s, f, c = tracked()
        local real, moved = s.storage.readHitmen, false
        s.storage.readHitmen = function(...)
            if not moved then
                moved = true
                truthy(s.storage.compareSetContractState(c.id, CH.STATE.ACCEPTED, CH.STATE.COMPLETING))
            end
            return real(...)
        end
        local ok, err = s.informant.buy(f.target, c.id)
        s.storage.readHitmen = real
        truthy(s.storage.compareSetContractState(c.id, CH.STATE.COMPLETING, CH.STATE.ACCEPTED))
        falsy(ok)
        eq(err, CH.ERR.ALREADY_SETTLED)
        eq(spent(), 0, 'nothing taken')
    end)

    --- W061, W143: the price the dialog quoted is the price charged. One
    --- raised from the admin panel while it was open was taken in full, on
    --- the one purchase never refunded.
    it('refuses a price that moved since it was quoted, and takes nothing', function()
        local s, f, c = tracked()
        local quoted, account = Config.Informant.Cost, Config.Informant.Account
        Config.Informant.Cost = quoted * 2
        local reply = call('informant', 2, { id = c.id, shown = { cost = quoted, account = account } })
        eq(reply and reply.err, CH.ERR.TERMS_CHANGED)
        eq(reply.data and reply.data.cost, quoted * 2, 'with the price now')
        eq(spent(), 0, 'nothing taken')

        Env.advance(Config.Cooldowns.informant.per + 1)
        local paid = call('informant', 2, { id = c.id, shown = { cost = quoted * 2, account = account } })
        truthy(paid and paid.ok, tostring(paid and paid.err))
        eq(spent(), quoted * 2, 'the price quoted, once')

        -- Asked again inside the reroll lock: the same answer, free, whatever
        -- the price is now, so nothing is refused for it.
        Config.Informant.Cost = quoted * 3
        Env.advance(Config.Cooldowns.informant.per + 1)
        local again = call('informant', 2, { id = c.id, shown = { cost = quoted * 2, account = account } })
        truthy(again and again.ok, tostring(again and again.err))
        eq(spent(), quoted * 2, 'and the repeat costs nothing')
    end)

    it('needs no quote where nothing is charged', function()
        local s, f, c = tracked()
        Config.Informant.Cost = 0
        local reply = call('informant', 2, { id = c.id })
        truthy(reply and reply.ok, tostring(reply and reply.err))
        eq(spent(), 0)
    end)

    --- Two operatives seen on the target and one of them gone from the city:
    --- whichever it is, the purchase names the one still here. Leaving the
    --- gone one out says nothing new: alone, it is "Unknown operative" too.
    for _, gone in ipairs({ 3, 4 }) do
        it(('names the seen operative still in the city (source %d left)'):format(gone), function()
            local s, f, c = tracked()
            Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
                cash = 5000, bank = 5000, firstname = 'Sol', lastname = 'Vane' })
            truthy(s.contracts.accept(s.identity.resolve(4), c.id, true))
            s.death.watchTargets(s.storage.allContracts())
            Env.removePlayer(gone)
            local ok, err, data = s.informant.buy(f.target, c.id)
            truthy(ok, tostring(err))
            eq(data.name, gone == 3 and 'Sol Vane' or 'Rook Ash')
        end)
    end
end)
