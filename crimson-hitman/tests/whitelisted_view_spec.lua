--- The whitelisted-job view (Config.WhitelistedView).
---
--- A player on a job the app bars (police, sheriff, SAST, FIB, EMS, fire,
--- DOJ, lawyers: Config.BlockedJobTypes and BlockedJobNames, jobs held
--- through sc-multijob included, off duty as Config.BlockOffDuty says) can
--- install and open the app, and is shown one read-only screen: the
--- contracts on them, and the contracts on other whitelisted-job members,
--- with no more than the law enforcement advisory carries. On a contract
--- on them, the buyout a civilian target has in On me, through the same
--- server path. Everything else refuses them as it always did (the
--- authorisation matrix has that column: "a player on a whitelisted job").
---
--- Everything here goes through the real net events, the way the page asks.

--------------------------------------------------------------------------
-- The cast
--------------------------------------------------------------------------

local POLICE = { name = 'police', label = 'Police', type = 'leo', onduty = true }
local CIVILIAN = { name = 'unemployed', label = 'Civilian', type = 'none', onduty = false }

--- Fire a handler as a client does and hand back its reply.
local function call(name, src, payload)
    local fire = Env.events['crimson-hitman:' .. name]
    assert(fire, 'no handler for ' .. name)
    Env.clientEvents = {}
    _G.source = src
    local ok, err = pcall(fire, payload or {})
    _G.source = nil
    if not ok then return { ok = false, err = 'THREW: ' .. tostring(err) } end
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:result' then return event.args[1] end
    end
    return nil
end

--- Everyone the view is about. Creator (1), hitman (3) and a stranger with
--- a civilian contract on them (2, TARGET01) from the fixture; an officer
--- who opens the app (11); a colleague with a contract on them (12); an
--- officer who is offline (13, gone after their contract is placed). All
--- three on `opts.job` (police) when their contracts are placed, which is
--- what each contract records and what the view reads of a colleague.
local function world(opts)
    opts = opts or {}
    local s = newStack()
    s.app.init(s)
    s.bridges.install(s)
    local f = fixture(s)
    Env.addPlayer({ source = 11, citizenid = 'OFFICER1', license = 'license:of1',
        cash = 50000, bank = 50000, firstname = 'Olive', lastname = 'Ward' })
    Env.addPlayer({ source = 12, citizenid = 'OFFICER2', license = 'license:of2',
        cash = 50000, bank = 50000, firstname = 'Colin', lastname = 'Hart' })
    Env.addPlayer({ source = 13, citizenid = 'OFFICER3', license = 'license:of3',
        cash = 50000, bank = 50000, firstname = 'Oona', lastname = 'Fell' })

    local function place(target, extra, by)
        local spec = {
            targetCid = target, reason = 'Owes the Lost MC', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5001 } }, bailoutAmount = 15000,
        }
        for k, v in pairs(extra or {}) do spec[k] = v end
        local c, err = s.contracts.create(by or f.creator, spec)
        assert(c, 'placing a contract on ' .. target .. ': ' .. tostring(err))
        return c
    end

    for _, src in ipairs({ 11, 12, 13 }) do
        local job = {}
        for k, v in pairs(opts.job or POLICE) do job[k] = v end
        Env.players[src].PlayerData.job = job
    end

    local w = { s = s, f = f, place = place }
    w.civilian = place('TARGET01', { anonymous = true })
    w.mine = place('OFFICER1')
    w.colleague = place('OFFICER2')
    -- By somebody else: a creator may have three out at once.
    Env.players[3].PlayerData.money.cash = 50000
    w.offline = place('OFFICER3', nil, f.hitman)
    truthy(s.contracts.accept(f.hitman, w.colleague.id, true), 'a hitman on the colleague')
    -- Offline: read by their contract, as everybody on the list is.
    Env.removePlayer(13)

    -- Past the wait before a target is shown a contract, as On me waits.
    Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
    return w
end

local function view(src)
    local reply = call('whitelistedView', src or 11, {})
    truthy(reply and reply.ok, 'the view answers: ' .. tostring(reply and reply.err))
    return reply.data
end

--- Whether a value appears anywhere in a payload, keys included.
local function contains(value, wanted, depth)
    depth = depth or 0
    if depth > 12 then return false end
    if value == wanted then return true end
    if type(value) == 'string' and type(wanted) == 'string' and value:find(wanted, 1, true) then
        return true
    end
    if type(value) ~= 'table' then return false end
    for k, v in pairs(value) do
        if contains(k, wanted, depth + 1) or contains(v, wanted, depth + 1) then return true end
    end
    return false
end

--------------------------------------------------------------------------
-- What the screen shows
--------------------------------------------------------------------------

describe('the whitelisted-job view', function()
    it('lists the contracts on them and on whitelisted-job members, and nothing else', function()
        local w = world()
        local data = view()
        eq(#data.onYou, 1, 'the one contract on them')
        eq(data.onYou[1].id, w.mine.id)
        eq(data.onYou[1].targetName, 'Olive Ward')
        eq(data.onYou[1].targetJob, 'Police', 'by the job on the contract, by its label')

        local names = {}
        for _, entry in ipairs(data.colleagues) do names[#names + 1] = entry.targetName end
        table.sort(names)
        eq(table.concat(names, ','), 'Colin Hart,Oona Fell',
            'an officer in the city and one offline, each by the job on the contract')
        for _, entry in ipairs(data.colleagues) do
            eq(entry.targetJob, 'Police')
            eq(entry.id, nil, 'a colleague\'s contract carries no id: nothing here acts on it')
        end
    end)

    it('says open, or taken by how many hitmen, when posted and when it runs out', function()
        local w = world()
        local data = view()
        local byName = {}
        for _, entry in ipairs(data.colleagues) do byName[entry.targetName] = entry end
        eq(byName['Colin Hart'].state, 'taken')
        eq(byName['Colin Hart'].hitmenActive, 1)
        eq(byName['Oona Fell'].state, 'open')
        eq(byName['Oona Fell'].hitmenActive, 0)
        local posted = w.s.storage.readContract(w.colleague.id).created_at
        eq(byName['Colin Hart'].postedAt, posted - (posted % 300),
            'to the five minutes, as every time about a placement is sent')
        truthy(byName['Colin Hart'].secondsLeft > 0, 'and when it runs out')
    end)

    --- The deadline stops while a named placer is offline and is moved on
    --- by exactly how long they were away when they come back (the expiry
    --- pass: Storage.startPause, then Storage.endPause). Read from it, the
    --- countdown jumped up the second they reconnected, for every officer
    --- and every colleague's contract: the placer is named, when they came
    --- back and how long they were gone.
    it('counts down by wall time alone, with no jump when a named placer comes back', function()
        local w = world()
        local function left()
            local data = view()
            local out = {}
            for _, entry in ipairs(data.colleagues) do out[entry.targetName] = entry.secondsLeft end
            out.own = data.onYou[1].secondsLeft
            return out
        end
        local before = left()
        truthy(before['Colin Hart'] and before['Colin Hart'] > 0, 'a clock to read')

        -- CREATOR1 (named) logs off; the expiry pass stops both clocks.
        local since = os.time()
        for _, id in ipairs({ w.colleague.id, w.mine.id }) do
            truthy(w.s.storage.startPause(id, since))
        end
        Env.advance(600)
        -- Back: the deadline moves on by the 600 s they were away.
        local deadline = w.s.storage.readContract(w.colleague.id).deadline_at
        for _, id in ipairs({ w.colleague.id, w.mine.id }) do
            truthy(w.s.storage.endPause(id, since, 600))
        end
        eq(w.s.storage.readContract(w.colleague.id).deadline_at, deadline + 600, 'the deadline moved')
        Env.advance(70)

        local after = left()
        eq(before['Colin Hart'] - after['Colin Hart'], 670, 'a colleague\'s clock fell by wall time')
        eq(before.own - after.own, 670, 'and their own')
    end)

    it('carries no more than the advisory: no placer, hitman, reason, place, photo or reward', function()
        local w = world()
        -- A named placer and a named hitman on the officer's own contract,
        -- the case with most to leak.
        truthy(w.s.contracts.accept(w.f.hitman, w.mine.id, false))
        local data = view()
        local keys = w.s.projection.WHITELISTED_KEYS
        for _, list in ipairs({ { data.onYou, true }, { data.colleagues, false } }) do
            for _, entry in ipairs(list[1]) do
                for key in pairs(entry) do
                    truthy(keys.entry[key] or (list[2] and keys.own[key]),
                        'a key the view does not send: ' .. key)
                end
            end
        end
        -- And by value, whatever key it might hide under.
        for _, leak in ipairs({ 'Vic Marlowe', 'Rook Ash', 'Operative', 'Owes the Lost MC',
                                 'CREATOR1', 'HITMAN01', 'TARGET01' }) do
            falsy(contains(data, leak), 'the view carries ' .. leak)
        end
        falsy(contains(data, 5001), 'nor the reward figure')
    end)

    it('never shows or counts a contract on anybody else', function()
        local w = world()
        local data = view()
        falsy(contains(data, 'Dana Reyes'), 'a civilian target is not named')
        falsy(contains(data, w.civilian.id), 'nor their contract')
        eq(#data.onYou + #data.colleagues, 3, 'three entries: theirs and two colleagues\'')
        for key in pairs(data) do
            truthy(key == 'onYou' or key == 'colleagues' or key == 'settings',
                'nothing else at the top, a count included: ' .. key)
        end
        local settingKeys = {}
        for key in pairs(data.settings) do settingKeys[#settingKeys + 1] = key end
        table.sort(settingKeys)
        eq(table.concat(settingKeys, ','), 'buyoutDelaySeconds,buyouts',
            'and the settings are what the buyout reads')
    end)

    it('waits, as On me waits, before a new contract is shown to anybody', function()
        local w = world()
        Env.addPlayer({ source = 14, citizenid = 'PLACER02', license = 'license:pl2',
            cash = 50000, bank = 50000, firstname = 'Pia', lastname = 'Lund' })
        local placer = w.s.identity.resolve(14)
        local fresh = w.s.contracts.create(placer, {
            targetCid = 'OFFICER2', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(fresh)
        local count = #view().colleagues
        -- Inside the reveal wait unless the posting bulletin already dated it
        -- for every officer online, which it does for an officer target.
        if w.s.notify.shownToTarget(fresh) then
            eq(count, 3, 'dated by the bulletin already, so shown')
        else
            eq(count, 2, 'not before its target may be shown it')
        end
        Config.Advisory.Enabled = false
        local quiet = w.s.contracts.create(placer, {
            targetCid = 'OFFICER1', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(quiet)
        eq(#view().onYou, 1, 'with no bulletin, not until the target is told')
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        eq(#view().onYou, 2, 'and then it is')
    end)

    it('asks no target\'s game for a headshot', function()
        local w = world()
        Env.clientEvents = {}
        local reply = call('whitelistedView', 11, {})
        truthy(reply.ok)
        for _, event in ipairs(Env.clientEvents) do
            falsy(event.name == 'crimson-hitman:renderMugshot', 'a render was asked of ' ..
                tostring(event.target))
        end
        falsy(w.s.mugshot.handleFor('OFFICER2'), 'and none is minted')
    end)

    it('is rate-limited like the other reads', function()
        world()
        local rule = Config.Cooldowns.load
        truthy(rule, 'the reads share a bucket')
        local refused
        for _ = 1, rule.burst + 2 do
            local reply = call('whitelistedView', 11, {})
            if not reply.ok then refused = reply break end
        end
        truthy(refused, 'the bucket runs out')
        eq(refused.err, CH.ERR.RATE_LIMITED)
    end)

    --- A screen of its own, whose faults went nowhere: the page's report
    --- was refused at the gate like every other request from a barred job.
    it('hears of a fault on its page, as it hears of the app\'s', function()
        local w = world()
        local reply = call('pageError', 11, { what = 'render', where = 'jobview', build = 'test' })
        truthy(reply and reply.ok, tostring(reply and reply.err))
        local newest = w.s.app.recentPageFaults()[1]
        eq(newest and newest.cid, 'OFFICER1', 'kept for the diagnosis')
        eq(newest.where, 'jobview')
        Config.WhitelistedView.Enabled = false
        eq(call('pageError', 11, { what = 'render', where = 'jobview' }).err, CH.ERR.BLACKLISTED_JOB,
            'and not with the view off, when there is no page to report from')
    end)

    it('refuses the players the whole app is open to, and sends them back to it', function()
        world()
        for _, src in ipairs({ 1, 2, 3 }) do
            local reply = call('whitelistedView', src, {})
            eq(reply.ok, false)
            eq(reply.err, CH.ERR.NOT_WHITELISTED)
            falsy(reply.data, 'and the refusal carries nothing')
        end
    end)
end)

--------------------------------------------------------------------------
-- Who is on a whitelisted job
--------------------------------------------------------------------------

describe('who the view is for', function()
    it('is decided exactly as the app bars a player: a held job counts', function()
        local w = world({ job = CIVILIAN })
        -- sc-multijob: police held, a civilian job worked.
        Env.players[11].PlayerData.jobs = { unemployed = 0, police = 2 }
        local data = view(11)
        eq(#data.onYou, 1, 'a held police job puts them in the view')
        eq(data.onYou[1].targetJob, nil, 'placed while they were a civilian: no job on the contract')
        falsy(w.s.identity.gate(11), 'and keeps them out of the app')
        eq(data.colleagues, nil, 'working a civilian job, the advisory does not reach them, '
            .. 'and nor does a colleagues\' list')

        -- And a contract placed on somebody holding police while working
        -- another job records them as an officer, as the advisory names them.
        Env.players[11].PlayerData.job = { name = 'police', label = 'Police', type = 'leo', onduty = true }
        Env.players[12].PlayerData.jobs = { unemployed = 0, police = 1 }
        Env.addPlayer({ source = 14, citizenid = 'PLACER02', license = 'license:pl2',
            cash = 50000, bank = 50000, firstname = 'Pia', lastname = 'Lund' })
        local held = w.place('OFFICER2', nil, w.s.identity.resolve(14))
        eq(w.s.storage.readContract(held.id).target_protected, true, 'an officer by a held job')
        local again = {}
        for _, entry in ipairs(view(11).colleagues) do again[entry.targetName] = entry end
        truthy(again['Colin Hart'], 'a colleague by a held job is one')
        eq(again['Colin Hart'].targetJob, 'Police')
    end)

    --- The advisory names an officer whatever their duty, and so does the
    --- record the list is read from.
    it('lists a colleague by the contract, on duty or off, as the advisory has them', function()
        world({ job = { name = 'police', label = 'Police', type = 'leo', onduty = false } })
        Config.BlockOffDuty = true
        eq(#view(11).onYou, 1, 'off duty, still an officer while off duty counts')
        local names = {}
        for _, entry in ipairs(view(11).colleagues) do names[entry.targetName] = true end
        truthy(names['Colin Hart'], 'and an off-duty colleague is listed')

        Config.BlockOffDuty = false
        local reply = call('whitelistedView', 11, {})
        eq(reply.err, CH.ERR.NOT_WHITELISTED, 'off duty not counting, the whole app is theirs')
        Env.players[11].PlayerData.job.onduty = true
        local shown = {}
        for _, entry in ipairs(view(11).colleagues) do shown[entry.targetName] = true end
        truthy(shown['Colin Hart'], 'an off-duty colleague is still on the list')
        truthy(shown['Oona Fell'], 'and so is one offline')
    end)

    --- Read by their jobs now while they were in the city and by the record
    --- while they were not, a target who had changed job since was listed
    --- or not as they logged in and out: the entry said when they did.
    it('lists a colleague by the contract, never by a lookup of them now, so an entry '
        .. 'never says when they log in or out', function()
        local w = world()
        -- Placed as an officer, since left the police.
        Env.players[12].PlayerData.job = CIVILIAN
        Env.players[12].PlayerData.jobs = { unemployed = 0 }
        -- Placed as a civilian, since joined it.
        Env.addPlayer({ source = 15, citizenid = 'RECRUIT1', license = 'license:rc1',
            cash = 50000, bank = 50000, firstname = 'Rhys', lastname = 'Cole' })
        Env.addPlayer({ source = 14, citizenid = 'PLACER02', license = 'license:pl2',
            cash = 50000, bank = 50000, firstname = 'Pia', lastname = 'Lund' })
        w.place('RECRUIT1', nil, w.s.identity.resolve(14))
        Env.players[15].PlayerData.job = { name = 'police', label = 'Police', type = 'leo', onduty = true }
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)

        local function listed()
            local out = {}
            for _, entry in ipairs(view(11).colleagues) do out[entry.targetName] = true end
            return out
        end
        local online = listed()
        Env.removePlayer(12)
        Env.removePlayer(15)
        local offline = listed()
        for _, name in ipairs({ 'Colin Hart', 'Rhys Cole' }) do
            eq(online[name] == true, offline[name] == true,
                name .. ' is listed the same in the city and away')
        end
        truthy(online['Colin Hart'], 'placed as an officer: listed, as the advisory went out')
        falsy(online['Rhys Cole'], 'placed as a civilian: not, as no advisory did')
    end)
end)

--------------------------------------------------------------------------
-- No more than the advisory says, to nobody it does not reach
--------------------------------------------------------------------------

describe('the colleagues\' list', function()
    local function byName(data)
        local out = {}
        for _, entry in ipairs(data.colleagues or {}) do out[entry.targetName] = entry end
        return out
    end

    it('is not sent to a viewer the advisory does not reach', function()
        for _, job in ipairs({
            { name = 'lawyer', label = 'Lawyer', type = 'none', onduty = true },
            { name = 'ambulance', label = 'EMS', type = 'ems', onduty = true },
        }) do
            local w = world()
            Env.players[11].PlayerData.job = job
            local data = view(11)
            eq(data.colleagues, nil, job.name .. ': no list at all, not an empty one')
            eq(#data.onYou, 1, job.name .. ': their own contract is still theirs')
            falsy(contains(data, 'Colin Hart'), job.name .. ': nor any colleague named')
            falsy(contains(data, w.colleague.target_name), job.name)
        end
    end)

    it('is not sent while the advisory is off, whose bulletins it repeats', function()
        world()
        Config.Advisory.Enabled = false
        local data = view(11)
        eq(data.colleagues, nil)
        eq(#data.onYou, 1)
    end)

    it('says open or taken only where acceptance bulletins go', function()
        world()
        Config.Advisory.OnAccept = false
        local entries = byName(view(11))
        truthy(entries['Colin Hart'], 'still listed: a posting bulletin went')
        eq(entries['Colin Hart'].state, nil, 'but not taken, which no bulletin said')
        eq(entries['Colin Hart'].hitmenActive, nil)
        truthy(entries['Colin Hart'].postedAt, 'posted, which one did')
    end)

    it('lists only what an acceptance bulletin went out for where no posting one goes', function()
        world()
        Config.Advisory.OnCreate = false
        local entries = byName(view(11))
        truthy(entries['Colin Hart'], 'taken, so announced')
        eq(entries['Colin Hart'].hitmenActive, 1)
        eq(entries['Colin Hart'].postedAt, nil, 'but not when it was posted, which nobody said')
        -- The lifetime runs from the end of the five minutes it was placed
        -- in, and is the same for every contract: the time left gave the
        -- posted time back exactly.
        eq(entries['Colin Hart'].secondsLeft, nil, 'nor when it runs out, which would say it')
        falsy(entries['Oona Fell'], 'nobody has taken hers, so nothing was said of it')
    end)

    --- Each operative taking it up is a bulletin with the running count;
    --- one walking away is none.
    it('does not show a hitman walking away, which no bulletin says', function()
        local w = world()
        eq(byName(view(11))['Colin Hart'].hitmenActive, 1)
        truthy(w.s.contracts.abandon(w.f.hitman, w.colleague.id))
        local entry = byName(view(11))['Colin Hart']
        eq(entry.hitmenActive, 1, 'still the count the bulletin said')
        eq(entry.state, 'taken')
    end)

    --- A second hitman, and a second placer, for the cases below.
    local function more(w)
        Env.addPlayer({ source = 14, citizenid = 'PLACER02', license = 'license:pl2',
            cash = 50000, bank = 50000, firstname = 'Pia', lastname = 'Lund' })
        Env.addPlayer({ source = 17, citizenid = 'HITMAN02', license = 'license:hm2',
            cash = 50000, bank = 50000, firstname = 'Kit', lastname = 'Vane' })
        Env.addPlayer({ source = 15, citizenid = 'OFFICER5', license = 'license:of5',
            cash = 50000, bank = 50000, firstname = 'Fay', lastname = 'Lowe',
            job = { name = 'police', label = 'Police', type = 'leo', onduty = true } })
        return w.s.identity.resolve(14), w.s.identity.resolve(17)
    end

    --- The bulletins that reached OFFICER1, by title, with what each said.
    local function bulletins(title)
        local out = {}
        for _, note in ipairs(Natives.calls.notifications) do
            if note.title == title then out[#out + 1] = tostring(note.content) end
        end
        return out
    end

    --- Read from what the bulletins said as each went out, kept on the
    --- contract, never from what the advisory says now: switched off and on
    --- again in the admin panel, a contract placed and taken meanwhile was
    --- listed as posted and taken, which no bulletin had said.
    it('lists nothing no bulletin announced, when the advisory is turned back on', function()
        local w = world()
        local placer, second = more(w)
        Natives.calls.notifications = {}
        Config.Advisory.Enabled = false
        local quiet = w.place('OFFICER5', nil, placer)
        truthy(w.s.contracts.accept(second, quiet.id, true), 'taken while it was off')
        eq(#bulletins('THREAT ADVISORY') + #bulletins('THREAT ADVISORY — ACTIVE'), 0,
            'no bulletin went out')
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        Config.Advisory.Enabled = true
        local entries = byName(view(11))
        falsy(entries['Fay Lowe'], 'so it is not listed now it is back on')
        truthy(entries['Colin Hart'], 'while one announced before is')
    end)

    it('does not say when one was posted that no posting bulletin announced', function()
        local w = world()
        local placer, second = more(w)
        Config.Advisory.OnCreate = false
        local quiet = w.place('OFFICER5', nil, placer)
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        Config.Advisory.OnCreate = true
        falsy(byName(view(11))['Fay Lowe'], 'not listed: nothing was said of it')
        truthy(w.s.contracts.accept(second, quiet.id, true))
        local entry = byName(view(11))['Fay Lowe']
        truthy(entry, 'listed once an acceptance bulletin went out')
        eq(entry.hitmenActive, 1)
        eq(entry.postedAt, nil, 'but not when it was posted')
        eq(entry.secondsLeft, nil, 'nor when it runs out, which would date it as well')
    end)

    it('does not call taken what no acceptance bulletin announced, when they are back on', function()
        local w = world()
        local _, second = more(w)
        Natives.calls.notifications = {}
        Config.Advisory.OnAccept = false
        truthy(w.s.contracts.accept(second, w.offline.id, true), 'taken while they were off')
        Config.Advisory.OnAccept = true
        eq(#bulletins('THREAT ADVISORY — ACTIVE'), 0, 'no acceptance bulletin went out')
        local entry = byName(view(11))['Oona Fell']
        truthy(entry, 'listed: a posting bulletin went')
        falsy(entry.state == 'taken', 'not taken, which no bulletin said')
        eq(entry.hitmenActive, 0, 'posted, and no acceptance announced since')
    end)

    --- Every acceptance bulletin carries the count holding it then. Counted
    --- from the hitmen rows, one who walked away and the one who took it up
    --- after were two, a figure no bulletin ever gave.
    it('says the count the latest acceptance bulletin carried', function()
        local w = world()
        local _, second = more(w)
        Natives.calls.notifications = {}
        truthy(w.s.contracts.abandon(w.f.hitman, w.colleague.id))
        truthy(w.s.contracts.accept(second, w.colleague.id, true), 'another takes it up')
        local said = bulletins('THREAT ADVISORY — ACTIVE')
        truthy(#said > 0, 'a bulletin went out for them')
        for _, text in ipairs(said) do
            truthy(text:find('1 operative is active', 1, true), text)
        end
        local entry = byName(view(11))['Colin Hart']
        eq(entry.hitmenActive, 1, 'as every bulletin said')
        eq(entry.state, 'taken')
    end)

    --- Barred by name with no type qbx_core gives it: the advisory used to
    --- miss them, while the view listed them.
    it('lists a job barred by name, which the advisory covers whatever its type', function()
        local w = world()
        Env.jobDefinitions.bcso = nil
        Env.addPlayer({ source = 14, citizenid = 'PLACER02', license = 'license:pl2',
            cash = 50000, bank = 50000, firstname = 'Pia', lastname = 'Lund' })
        Env.addPlayer({ source = 16, citizenid = 'DEPUTY01', license = 'license:dp1',
            cash = 50000, bank = 50000, firstname = 'Dee', lastname = 'Puty',
            job = { name = 'bcso', onduty = true } })
        local c = w.place('DEPUTY01', nil, w.s.identity.resolve(14))
        eq(w.s.storage.readContract(c.id).target_protected, true, 'an officer to the advisory')
        truthy(byName(view(11))['Dee Puty'], 'and listed')
    end)

    --- A lifetime that is not a whole number of five minutes ran out at a
    --- different moment for two placements in the same five minutes, which
    --- dated each more finely than its posted time does.
    it('runs out at the same moment for every placement in the same five minutes', function()
        local w = world()
        Config.Limits.ContractLifetimeSeconds = 172950
        Env.addPlayer({ source = 14, citizenid = 'PLACER02', license = 'license:pl2',
            cash = 50000, bank = 50000, firstname = 'Pia', lastname = 'Lund' })
        Env.addPlayer({ source = 15, citizenid = 'OFFICER5', license = 'license:of5',
            cash = 50000, bank = 50000, firstname = 'Fay', lastname = 'Lowe',
            job = { name = 'police', label = 'Police', type = 'leo', onduty = true } })
        local placer = w.s.identity.resolve(14)
        Env.time = Env.time - (Env.time % 300) + 300 + 10
        local early = w.place('OFFICER2', nil, placer)
        Env.time = Env.time + 200
        local late = w.place('OFFICER5', nil, placer)
        local a, b = w.s.storage.readContract(early.id), w.s.storage.readContract(late.id)
        eq(a.expires_at, b.expires_at, 'the same moment')
        truthy(a.expires_at >= a.created_at + 172950, 'and never sooner than the lifetime')
        local left = {}
        for _, entry in ipairs(view(11).colleagues) do
            if entry.targetName == 'Fay Lowe' or (entry.targetName == 'Colin Hart'
                and entry.hitmenActive == 0) then
                left[#left + 1] = entry.secondsLeft
            end
        end
        eq(#left, 2)
        eq(left[1], left[2], 'nor does the time left the view sends tell them apart')
    end)
end)

--------------------------------------------------------------------------
-- A job change
--------------------------------------------------------------------------

describe('a job change while the app is open', function()
    --- The pushes a player was sent saying their screen changed.
    local function moved(src)
        local n = 0
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:push' and event.target == src
                and type(event.args[1]) == 'table' and event.args[1].reason == 'access' then
                n = n + 1
            end
        end
        return n
    end

    local function jobUpdate(src, job)
        Env.players[src].PlayerData.job = job
        Env.clientEvents = {}
        Env.events['local:QBCore:Server:OnJobUpdate'](src, job)
    end

    it('moves a civilian who joins a whitelisted job into the view at once', function()
        local w = world({ job = CIVILIAN })
        w.s.bridges.tellAccess(11)
        truthy(call('list', 11, {}).ok, 'a civilian has the board')
        jobUpdate(11, POLICE)
        eq(moved(11), 1, 'their open page is told at once')
        eq(call('list', 11, {}).err, CH.ERR.BLACKLISTED_JOB, 'the board is closed to them')
        eq(#view(11).onYou, 1, 'and the view is theirs')
    end)

    it('gives the whole app back to somebody who leaves it', function()
        world()
        Env.clientEvents = {}
        _G.source = 11
        Env.events['crimson-hitman:whoAmI']({})
        _G.source = nil
        jobUpdate(11, CIVILIAN)
        eq(moved(11), 1, 'told at once')
        eq(call('whitelistedView', 11, {}).err, CH.ERR.NOT_WHITELISTED, 'the view is gone')
        truthy(call('list', 11, {}).ok, 'and the board is back')
    end)

    it('follows an sc-multijob switch, which qbx_core announces as a job update', function()
        world({ job = CIVILIAN })
        Env.players[11].PlayerData.jobs = { unemployed = 0, police = 2 }
        jobUpdate(11, POLICE)
        -- The first answer they are given is not a change.
        eq(moved(11), 0, 'nothing to change from yet')
        jobUpdate(11, CIVILIAN)
        eq(moved(11), 0, 'switching primary to a civilian job keeps police held: still the view')
        Env.players[11].PlayerData.jobs = { unemployed = 0 }
        jobUpdate(11, CIVILIAN)
        eq(moved(11), 1, 'quitting it is the change')
    end)

    it('is caught on the tick when no event comes, and sends nothing when nothing moved', function()
        local w = world({ job = CIVILIAN })
        w.s.bridges.refreshAccess()
        Env.clientEvents = {}
        w.s.bridges.refreshAccess()
        eq(moved(11), 0, 'nothing moved')
        Env.players[11].PlayerData.job = POLICE
        Env.clientEvents = {}
        w.s.bridges.refreshAccess()
        eq(moved(11), 1, 'the tick sees the job and moves them')
    end)

    it('shows the app icon to a whitelisted job only while the view is on', function()
        local w = world()
        local function access(src)
            Env.clientEvents = {}
            w.s.bridges.tellAccess(src)
            for _, event in ipairs(Env.clientEvents) do
                if event.name == 'crimson-hitman:access' and event.target == src then
                    return event.args[1]
                end
            end
        end
        eq(access(11), true, 'on, as shipped: the app, with its one screen')
        Config.WhitelistedView.Enabled = false
        eq(access(11), false, 'off: hidden, as HideAppFromBlockedJobs says')
        Config.HideAppFromBlockedJobs = false
        eq(access(11), true, 'and shown, answering nothing, with hiding off')
    end)

    it('moves an open page when staff switch the view from the panel', function()
        local w = world()
        w.s.bridges.refreshAccess()
        Env.clientEvents = {}
        truthy(w.s.settings.set('WhitelistedView.Enabled', false, 'ADMIN001'))
        eq(moved(11), 1, 'the open view is told at once')
        eq(call('whitelistedView', 11, {}).err, CH.ERR.BLACKLISTED_JOB,
            'off: refused as the app always refused them')
        Env.clientEvents = {}
        truthy(w.s.settings.set('WhitelistedView.Enabled', true, 'ADMIN001'))
        eq(moved(11), 1, 'and back')
        truthy(call('whitelistedView', 11, {}).ok)
    end)

    it('leaves a new officer\'s own contracts as placer and hitman as they were', function()
        local w = world({ job = CIVILIAN })
        local placed = w.s.contracts.create(w.s.identity.resolve(11), {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(placed, 'placed while a civilian')
        truthy(w.s.contracts.accept(w.s.identity.resolve(11), w.offline.id, false),
            'and took one as a hitman')
        jobUpdate(11, POLICE)
        eq(w.s.storage.readContract(placed.id).state, CH.STATE.ACTIVE, 'still out')
        eq(w.s.storage.readHitman(w.offline.id, 'OFFICER1').state, 'active', 'still held')
        eq(call('cancel', 11, { id = placed.id }).err, CH.ERR.BLACKLISTED_JOB,
            'and, as before the view, nothing in the app answers them about it')
        local data = view(11)
        falsy(contains(data, placed.id), 'the view does not show what they placed')
    end)
end)

--------------------------------------------------------------------------
-- The buyout, from the view
--------------------------------------------------------------------------

describe('the buyout on a contract on them', function()
    it('closes it, and pays the placer the escrow and the premium', function()
        local w = world()
        local creatorBefore = Env.players[1].PlayerData.money.cash + Env.players[1].PlayerData.money.bank
        local reply = call('bailout', 11, { id = w.mine.id })
        truthy(reply.ok, tostring(reply.err))
        eq(reply.data.queued, false, 'nobody on it, so at once')
        eq(w.s.storage.readContract(w.mine.id).state, CH.STATE.BAILED_OUT)
        eq(Env.players[11].PlayerData.money.bank, 50000 - 15000, 'the premium, from the bank')
        local creatorAfter = Env.players[1].PlayerData.money.cash + Env.players[1].PlayerData.money.bank
        eq(creatorAfter - creatorBefore, 5001 + 15000, 'escrow back with the premium')
        eq(#view(11).onYou, 0, 'and it is gone from the screen')
    end)

    it('shows the buyout price as On me shows it, and the button only where buyouts run', function()
        local w = world()
        local entry = view(11).onYou[1]
        eq(entry.bailoutAmount, 15000)
        eq(entry.bailoutAvailable, true)
        eq(view(11).settings.buyouts, true)
        local onMe = w.s.projection.onMe('OFFICER1')
        eq(#onMe, 1, 'the same contract On me would list')
        eq(onMe[1].bailoutAmount, entry.bailoutAmount)
        eq(onMe[1].bailoutAvailable, entry.bailoutAvailable)

        Config.Bailout.Enabled = false
        entry = view(11).onYou[1]
        eq(entry.bailoutAvailable, false, 'no button with buyouts off')
        eq(view(11).settings.buyouts, false)
        local reply = call('bailout', 11, { id = w.mine.id })
        eq(reply.err, CH.ERR.BAILOUT_OFF, 'and the server refuses it as it refuses everyone')
        eq(w.s.storage.readContract(w.mine.id).state, CH.STATE.ACTIVE)
    end)

    it('waits out the delay while a hitman is on it, and shows that it is paid', function()
        local w = world()
        truthy(w.s.contracts.accept(w.f.hitman, w.mine.id, false))
        local reply = call('bailout', 11, { id = w.mine.id })
        truthy(reply.ok)
        eq(reply.data.queued, true, 'queued, so the hitman has the delay to finish')
        local entry = view(11).onYou[1]
        eq(entry.bailoutPaid, true, 'the card says it is paid')
        eq(entry.bailoutSecondsLeft, Config.Bailout.ProcessingDelaySeconds,
            'and how long the hitman still has')
        eq(entry.state, 'taken')
        eq(call('bailout', 11, { id = w.mine.id }).err, CH.ERR.RATE_LIMITED,
            'a second press inside the minute is the purchase allowance')
        Env.advance(61)
        eq(call('bailout', 11, { id = w.mine.id }).err, CH.ERR.BUYOUT_PENDING,
            'and once that has passed, already paid')
        Env.advance(Config.Bailout.ProcessingDelaySeconds)
        eq(w.s.bailout.processQueue(), 1)
        eq(w.s.storage.readContract(w.mine.id).state, CH.STATE.BAILED_OUT)
        eq(#view(11).onYou, 0, 'the outcome: it is gone')
    end)

    it('refuses it from the floor, and during a handover, as every buyout is', function()
        local w = world()
        Env.players[11].PlayerData.metadata.inlaststand = true
        eq(call('bailout', 11, { id = w.mine.id }).err, CH.ERR.INCAPACITATED)
        Env.players[11].PlayerData.metadata.inlaststand = false
        Env.players[11].PlayerData.metadata.isdead = true
        eq(call('bailout', 11, { id = w.mine.id }).err, CH.ERR.INCAPACITATED)
        Env.players[11].PlayerData.metadata.isdead = false
        eq(w.s.storage.readContract(w.mine.id).state, CH.STATE.ACTIVE)
        eq(Env.players[11].PlayerData.money.bank, 50000, 'nothing taken')
    end)

    it('refuses a colleague\'s contract and an id they made up', function()
        local w = world()
        eq(call('bailout', 11, { id = w.colleague.id }).err, CH.ERR.NOT_PARTICIPANT)
        eq(call('bailout', 11, { id = 'ctnosuchthing' }).err, CH.ERR.NOT_FOUND)
        eq(w.s.storage.readContract(w.colleague.id).state, CH.STATE.ACCEPTED)
        eq(Env.players[11].PlayerData.money.bank, 50000, 'nothing taken')
    end)

    it('refunds it, as every buyout is refunded, when the hitman finishes first', function()
        local w = world()
        truthy(w.s.contracts.accept(w.f.hitman, w.mine.id, false))
        truthy(call('bailout', 11, { id = w.mine.id }).ok)
        local paid = Env.players[11].PlayerData.money.bank
        truthy(w.s.contracts.claimSlot(w.mine.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        Env.advance(Config.Bailout.ProcessingDelaySeconds + 1)
        w.s.bailout.processQueue()
        eq(Env.players[11].PlayerData.money.bank, paid + 15000, 'the premium comes back')
    end)
end)

--------------------------------------------------------------------------
-- One buyout, three ways in
--------------------------------------------------------------------------
--
-- On me's button (a civilian target), /cleanse (the command), and the
-- view's button (the same target on a whitelisted job). One server path,
-- so the same contract bought out each way has to end the same way, to
-- the dollar, with the same audit rows and the same notices, and with no
-- money made or lost, whether it closes at once, after the delay, or is
-- refunded because the hitman got there first.

describe('a buyout, whichever way it was asked for', function()
    local WAYS = {
        onMe = function(id) return call('bailout', 2, { id = id }) end,
        cleanse = function(id)
            Env.commands[Config.Bailout.Command](2, { id })
            return { ok = true }
        end,
        view = function(id) return call('bailout', 2, { id = id }) end,
    }

    --- Every dollar there is: in pockets, and held in escrow.
    local function total(s)
        local sum = 0
        for _, p in pairs(Env.players) do
            sum = sum + (p.PlayerData.money.cash or 0) + (p.PlayerData.money.bank or 0)
        end
        for _, c in ipairs(s.storage.allContracts()) do
            for _, line in ipairs(s.storage.readEscrow(c.id)) do
                if line.state == CH.ESCROW_STATE.HELD and (line.source == 'cash' or line.source == 'bank') then
                    sum = sum + (line.amount or 0)
                end
            end
        end
        return sum
    end

    local function run(way, ending)
        local s = newStack()
        s.app.init(s)
        s.bridges.install(s)
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } }, bailoutAmount = 15000,
        })
        assert(c)
        if ending ~= 'instant' then assert(s.contracts.accept(f.hitman, c.id, false)) end
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        if way == 'view' then Env.players[2].PlayerData.job = POLICE end

        s.audit.flush()
        local rowsBefore = #s.storage.readAudit()
        local start = total(s)
        local before = {}
        for src, p in pairs(Env.players) do
            before[src] = p.PlayerData.money.cash + p.PlayerData.money.bank
        end
        Env.clientEvents = {}

        local reply = WAYS[way](c.id)
        truthy(reply.ok, way .. ': ' .. tostring(reply.err))
        local told = {}
        local function note()
            for _, event in ipairs(Env.clientEvents) do
                if event.name == 'lb-phone:SendNotification' then
                    told[#told + 1] = tostring(event.target) .. ':' .. tostring(event.args[1].title)
                end
            end
        end
        note()
        if ending == 'refunded' then
            assert(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        end
        Env.clientEvents = {}
        Env.advance(Config.Bailout.ProcessingDelaySeconds + 1)
        s.bailout.processQueue()
        note()

        s.audit.flush()
        local actions = {}
        local rows = s.storage.readAudit()
        for i = rowsBefore + 1, #rows do
            if rows[i].kind == 'financial' and tostring(rows[i].action):find('bailout', 1, true) then
                actions[#actions + 1] = rows[i].action
            end
        end
        local deltas = {}
        for src, p in pairs(Env.players) do
            deltas[#deltas + 1] = ('%d:%d'):format(src,
                p.PlayerData.money.cash + p.PlayerData.money.bank - before[src])
        end
        table.sort(deltas)
        table.sort(told)
        return {
            state = s.storage.readContract(c.id).state,
            deltas = table.concat(deltas, ' '),
            actions = table.concat(actions, ','),
            told = table.concat(told, ','),
            made = total(s) - start,
        }
    end

    for _, ending in ipairs({ 'instant', 'queued', 'refunded' }) do
        it('ends the same way, ' .. ending .. ', with no money made or lost', function()
            local results = {}
            for _, way in ipairs({ 'onMe', 'cleanse', 'view' }) do
                results[way] = run(way, ending)
                eq(results[way].made, 0, way .. ' made or lost money')
            end
            for _, way in ipairs({ 'cleanse', 'view' }) do
                for _, field in ipairs({ 'state', 'deltas', 'actions', 'told' }) do
                    eq(results[way][field], results.onMe[field],
                        ('%s, %s: %s against On me\'s'):format(ending, way, field))
                end
            end
            truthy(results.onMe.actions:find('bailout_paid', 1, true), results.onMe.actions)
            if ending == 'refunded' then
                eq(results.onMe.state, CH.STATE.COMPLETED)
                truthy(results.onMe.actions:find('bailout_refunded', 1, true), results.onMe.actions)
            else
                eq(results.onMe.state, CH.STATE.BAILED_OUT)
                truthy(results.onMe.actions:find('bailout_settled', 1, true), results.onMe.actions)
            end
        end)
    end
end)

--------------------------------------------------------------------------
-- The setting
--------------------------------------------------------------------------

describe('Config.WhitelistedView', function()
    local Main = require('crimson-hitman.server.main')

    --- The start-up checks, run quietly as the panel runs them.
    local function checked(set)
        resetConfig()
        set()
        local ok, fatal, warn = Main.validateConfig(true)
        local result = Config.WhitelistedView and Config.WhitelistedView.Enabled
        resetConfig()
        return ok, result, table.concat(warn or {}, '\n'), table.concat(fatal or {}, '\n')
    end

    it('ships on, in config.lua and in the defaults', function()
        local config = read_file('crimson-hitman/config/config.lua')
        local defaults = read_file('crimson-hitman/config/defaults.lua')
        truthy(config:find('Config.WhitelistedView = {\n    Enabled = true,', 1, true),
            'config.lua ships it on')
        truthy(defaults:find('ConfigDefaults.WhitelistedView = {\n    Enabled = true,', 1, true),
            'and so do the defaults')
        eq(Main.configDefaults.WhitelistedView.Enabled, true,
            'and what the start fills in for a config without it')
    end)

    it('is filled for a config that predates it, whole or by the key', function()
        local ok, result, warned = checked(function() Config.WhitelistedView = nil end)
        truthy(ok, 'a config from before it starts')
        eq(result, true, 'with the view on, as shipped')
        local ok2, result2 = checked(function() Config.WhitelistedView = {} end)
        truthy(ok2)
        eq(result2, true, 'and a section without the key gets it')
        falsy(warned:find('WhitelistedView', 1, true), 'and nothing is wrong with that: ' .. warned)
    end)

    it('takes true and false as they are, saying nothing', function()
        for _, value in ipairs({ true, false }) do
            local ok, result, warned = checked(function() Config.WhitelistedView.Enabled = value end)
            truthy(ok)
            eq(result, value)
            falsy(warned:find('WhitelistedView', 1, true), warned)
        end
    end)

    it('reads anything else as off, and says so', function()
        for _, value in ipairs({ 'true', 1, 'yes' }) do
            local ok, result, warned = checked(function() Config.WhitelistedView.Enabled = value end)
            truthy(ok, 'not a reason to refuse to start')
            eq(result, false, tostring(value) .. ' is not a choice, and off shows least')
            truthy(warned:find('WhitelistedView.Enabled', 1, true), warned)
        end
    end)

    it('warns at start of a job barred by name that the advisory does not cover', function()
        local ok, _, warned = checked(function() Config.Advisory.TriggerJobNames.bcso = nil end)
        truthy(ok, 'not a reason to refuse to start')
        truthy(warned:find('not law enforcement to the advisory: bcso.', 1, true), warned)
        local _, _, shipped = checked(function() end)
        falsy(shipped:find('not law enforcement to the advisory', 1, true),
            'none as shipped, where every barred name triggers one: ' .. shipped)
        for _, set in ipairs({ ConfigDefaults, Main.configDefaults }) do
            for name in pairs(set.BlockedJobNames or Config.BlockedJobNames) do
                truthy(set.Advisory.TriggerJobNames[name], name .. ' is in TriggerJobNames')
            end
        end
    end)

    it('is a switch in the admin panel, under Access', function()
        local s = newStack()
        local entry = s.settings.entry('WhitelistedView.Enabled')
        truthy(entry, 'on the panel\'s list')
        eq(entry.kind, 'switch')
        eq(entry.section, 'features')
        eq(entry.group, 'Access')
        eq(s.settings.entry('HideAppFromBlockedJobs').unless, 'WhitelistedView.Enabled',
            'and hiding the app says it does not apply beside it')
    end)
end)
