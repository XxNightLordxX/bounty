--- Sweep 5, the second half: the security, clock and money findings, each
--- held to its fix. Every test here failed on the code before it.
---
---   X1  a staff search of the log by citizen id, without IdentityAce,
---       handed back the store's cursor: it named the next row the search
---       matched, the hidden ones included, so an unfiltered page from it
---       opened on the anonymous contract the player placed.
---   X2  the party view said On hold to staff without IdentityAce, so a
---       freeze of a suspect, then that view, named the anonymous placer.
---   X-  a handover arm refused for the placer not being there could be
---       tried again at once; the roleplay handlers answered a server error
---       where their module is missing.
---   C5-1 a hold's release let go of the hold before it gave the time back:
---       an expiry pass in between ended a contract whose lifetime ran out
---       while it was held.
---   C5-2 an idle release landing in a claim marked the hitman being paid
---       released and gave their stake to the placer.
---   C5-3 a kill made just before the restart hold was lost to it.
---   C5-4 the restart hold's end told nobody.
---   C5-5 answering a lapsed proposal during a freeze closed it.
---   C5-6 the time band ignored the lifetime ceiling.
---   C5-  a claim did not look at the holds again under its lock; a staff
---       adjustment of math.mininteger passed; a boot that could not read
---       the freezes read nobody as frozen.
---   M5-1 withdrawing every clean line kept the whole buyout price.
---   M5-  a give's claim kept no balance to judge an interrupted give by;
---       the tip refunds owed a raised credit blind; a decay step that
---       raised after its charge landed was charged again; the top-up audit
---       row had no amounts.

local Exec = require('tests.harness.mysql_exec')

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

local function bank(src) return Env.players[src].PlayerData.money.bank end

local function place(s, f, extra)
    local req = { targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
                  reward = { baseline = { cash = 5000 } } }
    for k, v in pairs(extra or {}) do req[k] = v end
    local c, err = s.contracts.create(f.creator, req)
    truthy(c, 'placed: ' .. tostring(err))
    return c
end

--- Notices a source was sent since the client events were last cleared.
local function noticesTo(src)
    local out = {}
    for _, event in ipairs(Env.clientEvents) do
        if Natives.isNotice(event) and event.target == src then
            local data = event.args and event.args[1] or {}
            out[#out + 1] = { title = tostring(data.title), content = tostring(data.content) }
        end
    end
    return out
end

local function auditRows(s, action)
    s.audit.flush()
    local out = {}
    for _, row in ipairs(s.storage.readAudit() or {}) do
        if row.action == action then out[#out + 1] = row end
    end
    return out
end

local function detailOf(row)
    local d = row and row.detail
    if type(d) == 'string' then d = json.decode(d) end
    return d or {}
end

--------------------------------------------------------------------------
-- Staff, as the panel asks
--------------------------------------------------------------------------

--- A stack with a staff member (source 6) holding crimson.admin only, no
--- IdentityAce, and anonymity allowed both ways.
local function staffStack()
    local s = newStack()
    local f = fixture(s)
    Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
        firstname = 'Sam', lastname = 'Steward' })
    Env.aces[6] = { ['crimson.admin'] = true }
    Config.Cooldowns.admin = { per = 10, burst = 500 }
    Config.Cooldowns.adminWrite = { per = 10, burst = 500 }
    Config.Anonymity.AllowAnonymousPlacer = true
    Config.Anonymity.AllowAnonymousHitman = true
    s.bridges.install(s)
    return s, f
end

local function ask(src, op, data)
    Env.clientEvents = {}
    _G.source = src
    local fired, err = pcall(Env.events['crimson-hitman:admin'], { op = op, data = data or {}, __rid = 41 })
    _G.source = nil
    truthy(fired, tostring(err))
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:adminResult' then return event.args[1] end
    end
end

--------------------------------------------------------------------------
-- X1: the log search's cursor
--------------------------------------------------------------------------

describe('sweep 5 X1: a log search by citizen id never hands back the store cursor', function()
    --- The creator places one anonymously, then one under their name.
    local function twoContracts()
        local s, f = staffStack()
        Config.Audit.LogAllActions = true
        local anon = place(s, f, { anonymous = true })
        eq(anon.anon_creator, true)
        Env.advance(120)
        local named = place(s, f, { targetCid = 'HITMAN01', reason = 'Another debt', anonymous = false })
        s.audit.flush()
        return s, f, anon, named
    end

    it('no page handle fed to an unfiltered page lands on the anonymous contract', function()
        local _, _, anon = twoContracts()
        local cursor, pages = nil, 0
        repeat
            local r = ask(6, 'logs', { actor = 'CREATOR1', limit = 1, cursor = cursor })
            truthy(r.ok, tostring(r.message))
            for _, row in ipairs(r.data.rows) do
                truthy(row.contract ~= anon.id, 'the search itself hides it')
            end
            if r.data.next then
                local plain = ask(6, 'logs', { cursor = r.data.next, limit = 1 })
                local row = plain.data and plain.data.rows and plain.data.rows[1]
                falsy(row and row.contract == anon.id,
                    'a handle from the search opened an unfiltered page on the anonymous contract')
            end
            cursor = r.data.next
            pages = pages + 1
        until not cursor or pages > 20
        truthy(pages <= 20, 'the search ends')
    end)

    it('says there is more only where a row they may see is left', function()
        local s, f, anon = twoContracts()
        local _ = s
        local _ = f
        -- Their newest row is the named contract's; everything older is the
        -- anonymous one's, which the search hides.
        local first = ask(6, 'logs', { actor = 'CREATOR1', limit = 1 })
        truthy(first.ok)
        eq(#first.data.rows, 1)
        truthy(first.data.rows[1].contract ~= anon.id)
        local seen = { [first.data.rows[1]] = true }
        local cursor, pages = first.data.next, 1
        while cursor and pages < 20 do
            local r = ask(6, 'logs', { actor = 'CREATOR1', limit = 1, cursor = cursor })
            truthy(r.ok, tostring(r.message))
            truthy(#r.data.rows > 0, 'a handle was given for a page with nothing they may see: '
                .. 'it said hidden rows were left')
            for _, row in ipairs(r.data.rows) do
                truthy(row.contract ~= anon.id)
                falsy(seen[row])
                seen[row] = true
            end
            cursor, pages = r.data.next, pages + 1
        end
    end)

    it('pages through every row they may see, once each, as IdentityAce staff see them openly', function()
        local _, _, anon, named = twoContracts()
        Env.aces[7] = { ['crimson.admin'] = true, ['crimson.identity'] = true }
        Env.addPlayer({ source = 7, citizenid = 'ADMIN002', license = 'license:ADMIN002',
            firstname = 'Kim', lastname = 'Ward' })
        local function walk(src, limit)
            local out, cursor, pages = {}, nil, 0
            repeat
                local r = ask(src, 'logs', { actor = 'CREATOR1', limit = limit, cursor = cursor })
                truthy(r.ok, tostring(r.message))
                for _, row in ipairs(r.data.rows) do
                    if row.contract ~= anon.id then out[#out + 1] = (row.action or '') .. '@' .. tostring(row.contract) end
                end
                cursor, pages = r.data.next, pages + 1
            until not cursor or pages > 50
            return table.concat(out, ',')
        end
        local open = walk(6, 1)
        truthy(open:find(named.id, 1, true), 'the named contract is listed')
        eq(open, walk(7, 2), 'the same rows, in the same order')
    end)

    it('a handle is refused to another staff member and to another search', function()
        local s, f = twoContracts()
        Env.addPlayer({ source = 8, citizenid = 'ADMIN003', license = 'license:ADMIN003',
            firstname = 'Lee', lastname = 'Hart' })
        Env.aces[8] = { ['crimson.admin'] = true }
        -- More named rows by them, so the first page has more after it.
        Config.Limits.MaxActiveContractsPerCreator = 10
        Env.addPlayer({ source = 9, citizenid = 'OTHER001', license = 'license:o1',
            firstname = 'Ola', lastname = 'Berg' })
        place(s, f, { targetCid = 'OTHER001', reason = 'A third debt', anonymous = false })
        s.audit.flush()
        local first = ask(6, 'logs', { actor = 'CREATOR1', limit = 1 })
        truthy(first.ok)
        truthy(first.data.next, 'a second page')
        local other = ask(8, 'logs', { actor = 'CREATOR1', limit = 1, cursor = first.data.next })
        falsy(other.ok, 'not this staff member\'s')
        local elsewhere = ask(6, 'logs', { actor = 'TARGET01', limit = 1, cursor = first.data.next })
        falsy(elsewhere.ok, 'not this search\'s')
        truthy(ask(6, 'logs', { actor = 'CREATOR1', limit = 1, cursor = first.data.next }).ok)
    end)
end)

--------------------------------------------------------------------------
-- X2: the party view's On hold
--------------------------------------------------------------------------

describe('sweep 5 X2: the party view says On hold only where the badge would', function()
    local function frozenAnonymous()
        local s, f = staffStack()
        local c = place(s, f, { anonymous = true })
        truthy(c.anon_creator == true)
        local look = ask(6, 'player', { subject = '1' })
        truthy(look.ok, tostring(look.message))
        local fr = ask(6, 'freeze', { ref = look.data.player.ref, reason = 'checking something' })
        truthy(fr.ok, tostring(fr.message))
        return s, f, c
    end

    it('without IdentityAce, no party view of a contract held by its anonymous placer says so', function()
        local _, _, c = frozenAnonymous()
        local cv = ask(6, 'contract', { id = c.id })
        eq(cv.data.frozen, nil, 'the badge is hidden')
        for _, role in ipairs({ 'placer', 'target' }) do
            local pv = ask(6, 'playerView', { id = c.id, role = role })
            truthy(pv.ok, tostring(pv.message))
            falsy(pv.data.view and pv.data.view.onHold,
                ('the %s\'s view said on hold: the suspect is the anonymous placer'):format(role))
        end
    end)

    it('still says so where a party it may name is frozen, and with IdentityAce', function()
        local s, f = staffStack()
        local c = place(s, f, { anonymous = true })
        truthy(s.freeze.freeze('ADMIN001', 'TARGET01', 'the target'))
        local pv = ask(6, 'playerView', { id = c.id, role = 'placer' })
        eq(pv.data.view.onHold, true, 'the target is frozen, which the badge says too')
        truthy(s.freeze.unfreeze('ADMIN001', 'TARGET01', 'done'))
        truthy(s.freeze.freeze('ADMIN001', 'CREATOR1', 'the placer'))
        Env.aces[6]['crimson.identity'] = true
        pv = ask(6, 'playerView', { id = c.id, role = 'placer' })
        eq(pv.data.view.onHold, true, 'staff who may identify them see it')
    end)
end)

--------------------------------------------------------------------------
-- X cheap: the handover arm, the roleplay handlers
--------------------------------------------------------------------------

describe('sweep 5 X: an arm refused for the placer waits before the next', function()
    it('refuses again at once as a cooldown, and tries again after it', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local at = { x = 200.0, y = 200.0, z = 30.0 }
        Env.players[2]._coords = { x = at.x, y = at.y, z = at.z }
        Env.players[3]._coords = { x = at.x, y = at.y, z = at.z }
        Env.players[1]._coords = { x = 9000.0, y = 9000.0, z = 30.0 }
        Env.players[2].PlayerData.metadata.ishandcuffed = true
        local ok, why = s.kidnap.arm(c.id, 'HITMAN01')
        falsy(ok)
        eq(why, 'creator_too_far')
        ok, why = s.kidnap.arm(c.id, 'HITMAN01')
        falsy(ok)
        eq(why, CH.ERR.HANDOVER_COOLDOWN, 'a second arm at once is not another look for the placer')
        Env.advance(16)
        Env.players[1]._coords = { x = at.x, y = at.y, z = at.z }
        truthy(s.kidnap.arm(c.id, 'HITMAN01'), 'armed once the placer is there, after the wait')
    end)
end)

describe('sweep 5 X: the roleplay handlers without their modules', function()
    it('answer feature off, not a server error', function()
        local s = newStack()
        fixture(s)
        local deps
        for i = 1, 60 do
            local name, value = debug.getupvalue(s.app.init, i)
            if not name then break end
            if name == 'deps' then deps = value end
        end
        truthy(type(deps) == 'table', 'the app\'s wiring')
        local rumours, places = deps.rpRumours, deps.rpPlaces
        deps.rpRumours, deps.rpPlaces = nil, nil
        local answers = {
            call('rumourBrief', 3, { id = 'r1' }),
            call('brokerNearby', 3, {}),
            call('brokerBrief', 3, { id = 'r1', who = 1 }),
            call('rpPlaces', 3, {}),
        }
        deps.rpRumours, deps.rpPlaces = rumours, places
        for i, r in ipairs(answers) do
            truthy(r, 'answered ' .. i)
            eq(r.err, CH.ERR.FEATURE_OFF, 'handler ' .. i)
        end
    end)
end)

--------------------------------------------------------------------------
-- C5-1: a hold's release and the expiry pass
--------------------------------------------------------------------------

--- main.lua's own start on memory, as clock_spec boots it.
local function bootMain(configure)
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
            package.loaded[name] = nil
        end
    end
    package.loaded['server.main'] = nil
    Env.reset()
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Natives.resetResourceStates()
    resetConfig()
    Config.Database.Mode = 'memory'
    if configure then configure() end
    local main = require('server.main')
    return main, main.start()
end

describe('sweep 5 C5-1: an expiry pass inside a hold\'s release', function()
    --- A taken contract whose lifetime ends ten minutes from now.
    local function shortLived()
        local main, s = bootMain()
        local f = fixture(s)
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false), 'taken')
        local row = s.storage.readContract(c.id)
        row.expires_at = os.time() + 600
        s.storage.writeContract(row)
        main.markPresenceChanged()
        main.expire()
        return main, s, f, c
    end

    --- Run one expiry pass inside the first call to s.storage[name].
    local function passInside(main, s, name)
        local real, ran = s.storage[name], false
        s.storage[name] = function(...)
            if not ran then
                ran = true
                main.markPresenceChanged()
                main.expire()
            end
            return real(...)
        end
        return function() s.storage[name] = real end
    end

    it('an unfreeze gives the lifetime back before the pass can end it', function()
        local main, s, _, c = shortLived()
        truthy(s.freeze.freeze('ADMIN001', 'TARGET01', 'probe'))
        Env.advance(1200)
        local undo = passInside(main, s, 'contractsInvolving')
        truthy(s.freeze.unfreeze('ADMIN001', 'TARGET01', 'done'))
        undo()
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'ended with its held time not given back')
        main.markPresenceChanged()
        main.expire()
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'and the next pass leaves it, its time back')
    end)

    it('the app pause\'s end gives the lifetime back before the pass can end it', function()
        local main, s, _, c = shortLived()
        Config.Staff.AppPaused = true
        eq(s.freeze.syncAppPause(), 'paused')
        Env.advance(1200)
        Config.Staff.AppPaused = false
        local undo = passInside(main, s, 'writeStaffMeta')
        eq(s.freeze.syncAppPause(), 'resumed')
        undo()
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'ended with its paused time not given back')
    end)

    it('the restart hold\'s end gives the lifetime back before the pass can end it', function()
        local main, s, _, c = shortLived()
        Config.Restart.PauseBeforeSeconds = 1800
        truthy(s.freeze.scheduledRestart({ secondsRemaining = 1800 }))
        Env.advance(1200)
        local undo = passInside(main, s, 'liveContracts')
        truthy(s.freeze.releaseRestart('skipped'))
        undo()
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'ended with its held time not given back')
    end)
end)

--------------------------------------------------------------------------
-- C5-2: an idle release inside a claim
--------------------------------------------------------------------------

describe('sweep 5 C5-2: an idle release that lands in a claim', function()
    it('neither releases the hitman being paid nor hands their stake to the placer', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f, { mode = CH.MODE.EXCLUSIVE, reward = { baseline = { cash = 10000 } },
            penaltyAmount = 2000 })
        truthy(s.contracts.accept(f.hitman, c.id, false), 'taken, staked')
        Env.players[3]._coords = { x = 5000.0, y = 5000.0, z = 0.0 }
        s.contracts.releaseIdleHolds()
        -- One minute short of the release.
        local minutes = math.ceil(Config.Limits.ExclusiveIdleReleaseSeconds / 60)
        for _ = 1, minutes - 1 do
            Env.advance(60)
            s.death.watchTargets(s.storage.allContracts())
            s.contracts.releaseIdleHolds()
        end
        eq(s.storage.readHitman(c.id, 'HITMAN01').state, 'active', 'not released yet')
        -- The claim takes the contract in the release's own reads, as a
        -- claim landing in its awaits does on mysql.
        local readHitman, landed = s.storage.readHitman, false
        s.storage.readHitman = function(...)
            local out = readHitman(...)
            if not landed and debug.traceback():find('releaseIdleHold', 1, true) then
                landed = true
                truthy(s.contracts.transition(c.id, CH.STATE.ACCEPTED, CH.STATE.COMPLETING, 'claiming_slot'))
            end
            return out
        end
        local placerBefore = bank(1) + Env.players[1].PlayerData.money.cash
        for _ = 1, 3 do
            Env.advance(60)
            s.death.watchTargets(s.storage.allContracts())
            s.contracts.releaseIdleHolds()
        end
        s.storage.readHitman = readHitman
        truthy(landed, 'the release ran')
        eq(s.storage.readHitman(c.id, 'HITMAN01').state, 'active', 'the hitman being paid was released')
        eq(bank(1) + Env.players[1].PlayerData.money.cash, placerBefore, 'their stake went to the placer')
        truthy(s.contracts.transition(c.id, CH.STATE.COMPLETING, CH.STATE.ACCEPTED, 'claim_refused'))
    end)
end)

--------------------------------------------------------------------------
-- C5-3 / C5-4: the restart hold's end
--------------------------------------------------------------------------

describe('sweep 5 C5-3 and C5-4: when the restart hold ends without a restart', function()
    local function seeded()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        Config.Completion.KillPhotos = false
        Config.Restart.PauseBeforeSeconds = 1800
        return s, f, c
    end

    local function kill(s)
        Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
        Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
        Env.players[2]._health = 140
        s.death.recordDamage(3, 2, 123456)
        Env.players[2].PlayerData.metadata.isdead = true
        eq(s.death.onVictimReport(2), 1, 'the kill is attributed')
    end

    it('a kill made just before the hold can still be verified once it is skipped', function()
        local s, f, c = seeded()
        kill(s)
        Env.advance(30)
        truthy(s.freeze.scheduledRestart({ secondsRemaining = 1800 }))
        local ok, err = s.photo.verifyAtScene(f.hitman, c.id)
        falsy(ok)
        eq(err, CH.ERR.RESTART_HOLD)
        for _ = 1, 10 do
            Env.advance(60)
            s.death.sweep()
        end
        truthy(s.freeze.releaseRestart('skipped'))
        local before = Env.players[3].PlayerData.money.cash
        ok, err = s.photo.verifyAtScene(f.hitman, c.id)
        truthy(ok, 'the kill was lost to the hold: ' .. tostring(err))
        eq(Env.players[3].PlayerData.money.cash - before, 5000)
    end)

    it('and once the time it had left runs out after the hold, it is gone as ever', function()
        local s, f, c = seeded()
        kill(s)
        Env.advance(30)
        truthy(s.freeze.scheduledRestart({ secondsRemaining = 1800 }))
        Env.advance(600)
        truthy(s.freeze.releaseRestart('skipped'))
        Env.advance(2 * Config.Completion.PhotoTokenLifetimeSeconds + 5)
        s.death.sweep()
        falsy(s.photo.verifyAtScene(f.hitman, c.id), 'not kept for good')
    end)

    it('tells the parties the pause is over, and refreshes their pages', function()
        local s = seeded()
        truthy(s.freeze.scheduledRestart({ secondsRemaining = 1800 }))
        Env.advance(300)
        Env.clientEvents = {}
        local push, pushed = s.notify.push, {}
        s.notify.push = function(cid, ...)
            pushed[cid] = true
            return push(cid, ...)
        end
        local released = s.freeze.releaseRestart('skipped')
        s.notify.push = push
        truthy(released)
        for src, cid in pairs({ [1] = 'CREATOR1', [3] = 'HITMAN01' }) do
            local told = false
            for _, note in ipairs(noticesTo(src)) do
                if note.title == 'Server restart' and note.content:find('no longer paused', 1, true) then
                    told = true
                end
            end
            truthy(told, cid .. ' was told nothing')
            truthy(pushed[cid], cid .. ' had no push')
        end
    end)

    it('says nothing when a new hold takes its place at once', function()
        local s = seeded()
        Config.Restart.MaxHoldMinutes = 20
        truthy(s.freeze.scheduledRestart({ secondsRemaining = 1800 }))
        Env.advance(21 * 60)
        Env.clientEvents = {}
        truthy(s.freeze.scheduledRestart({ secondsRemaining = 600 }))
        for _, note in ipairs(noticesTo(1)) do
            falsy(note.content:find('no longer paused', 1, true), 'told it was over as it began again')
        end
    end)
end)

--------------------------------------------------------------------------
-- C5-5: a lapsed proposal answered during a freeze
--------------------------------------------------------------------------

describe('sweep 5 C5-5: a proposal past its time while its contract is frozen', function()
    it('is refused as on hold and left open, and the unfreeze gives it its time back', function()
        local s = newStack()
        local f = fixture(s)
        Config.Amendments.ProposalExpirySeconds = 600
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        truthy(s.amendments.propose(f.creator, c.id, CH.AMENDMENT.CHANGE_REASON,
            { reason = 'A better reason' }), 'proposed')
        local p = s.storage.readOpenAmendments(c.id)[1]
        truthy(s.freeze.freeze('ADMIN001', 'TARGET01', 'probe'))
        Env.advance(900)
        local ok, err = s.amendments.respond(f.hitman, p.id, true)
        falsy(ok)
        eq(err, CH.ERR.CONTRACT_FROZEN, 'answered as expired')
        Env.addPlayer({ source = 9, citizenid = 'STRANGER', license = 'license:str' })
        local _, strangerErr = s.amendments.respond(s.identity.resolve(9), p.id, true)
        eq(strangerErr, CH.ERR.NOT_PARTICIPANT, 'a stranger learns nothing of the hold')
        eq(s.storage.readAmendment(p.id).outcome, 'open', 'still open')
        truthy(s.freeze.unfreeze('ADMIN001', 'TARGET01', 'done'))
        truthy(s.amendments.respond(f.hitman, p.id, true), 'answered after the unfreeze')
    end)
end)

--------------------------------------------------------------------------
-- C5-6: the time band and the lifetime
--------------------------------------------------------------------------

describe('sweep 5 C5-6: the time band counts the lifetime ceiling', function()
    local function longDeadline()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local row = s.storage.readContract(c.id)
        row.deadline_at = os.time() + 5 * 3600
        row.expires_at = os.time() + 1800
        s.storage.writeContract(row)
        return s, f, c
    end

    it('says under an hour when the lifetime ends in half an hour, however long the run time', function()
        local s, _, c = longDeadline()
        local view = s.projection.contract(s.storage.readContract(c.id), 'HITMAN01')
        eq(view.timeLeft, 'Under 1 hour left')
        local board = s.projection.contract(s.storage.readContract(c.id), 'STRANGER')
        eq(board and board.timeLeft, 'Under 1 hour left', 'the same to everybody')
    end)

    it('stands still while a hold stops the lifetime', function()
        local s, _, c = longDeadline()
        Env.advance(600)
        truthy(s.freeze.freeze('ADMIN001', 'TARGET01', 'probe'))
        Env.advance(1000)
        local view = s.projection.contract(s.storage.readContract(c.id), 'HITMAN01')
        eq(view.timeLeft, 'Under 1 hour left', 'the band moved on while the lifetime stood still')
        Env.advance(600)
        view = s.projection.contract(s.storage.readContract(c.id), 'HITMAN01')
        eq(view.timeLeft, 'Under 1 hour left')
    end)
end)

--------------------------------------------------------------------------
-- C5 cheap: the claim's holds under its lock, mininteger, the boot read
--------------------------------------------------------------------------

describe('sweep 5 C5: a freeze that lands in a claim\'s reads', function()
    it('is seen again under the claim\'s lock, and nothing is paid', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local isImmune, landed = s.contracts.isImmune, false
        s.contracts.isImmune = function(...)
            if not landed then
                landed = true
                truthy(s.freeze.freeze('ADMIN001', 'TARGET01', 'mid-claim'))
            end
            return isImmune(...)
        end
        local before = Env.players[3].PlayerData.money.cash + bank(3)
        local ok, err = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        s.contracts.isImmune = isImmune
        truthy(landed)
        falsy(ok, 'paid while on hold')
        eq(err, CH.ERR.CONTRACT_FROZEN)
        eq(Env.players[3].PlayerData.money.cash + bank(3), before)
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'and back as it was')
    end)
end)

describe('sweep 5 C5: a staff adjustment of the smallest integer', function()
    it('is refused as out of range', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f)
        local ok, err = s.admin.adjustDeadline(0, c.id, math.mininteger, 'probe')
        falsy(ok, 'moved the deadline by -2^63')
        eq(err, 'bad_adjust')
    end)
end)

describe('sweep 5 C5: freezes the start could not read', function()
    it('hold every live contract until a tick reads them', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f)
        local real = s.storage.readFreezes
        s.storage.readFreezes = function() error('Lost connection to server during query', 0) end
        s.freeze.reload()
        local contract = s.storage.readContract(c.id)
        truthy(s.freeze.holds(contract), 'read as nobody frozen')
        falsy(s.contracts.accept(f.hitman, c.id, false), 'taken while the freezes are unknown')
        s.freeze.restartTick()
        truthy(s.freeze.holds(contract), 'still held while the read fails')
        s.storage.readFreezes = real
        s.freeze.restartTick()
        falsy(s.freeze.holds(contract), 'let go once they are read')
        truthy(s.contracts.accept(f.hitman, c.id, false))
    end)
end)

--------------------------------------------------------------------------
-- M5-1: the buyout after the clean money is withdrawn
--------------------------------------------------------------------------

--- main.lua's own start on a backend.
local function bootOn(mode)
    return bootMain(function()
        Config.Database.Mode = mode
        Config.Bailout.Enabled = true
        if mode == 'json' then Natives.files = {} end
        if mode == 'mysql' then Exec.install(Natives) end
    end)
end

describe('sweep 5 M5-1: withdrawing every clean line takes the buyout off', function()
    for _, mode in ipairs({ 'memory', 'json', 'mysql' }) do
        it(mode .. ': a $1,000 dirty contract never charges a $150,000 buyout', function()
            local _, s = bootOn(mode)
            local f = fixture(s, { creatorBank = 200000 })
            local c, err = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
                reward = { baseline = { bank = 50000, dirty = 1000 } }, bailoutAmount = 150000,
            })
            truthy(c, 'placed: ' .. tostring(err))
            eq(s.storage.readContract(c.id).bailout_amount, 150000)
            local ids = {}
            for _, line in ipairs(s.storage.readEscrow(c.id)) do
                if line.source == 'bank' then ids[#ids + 1] = line.id end
            end
            Env.clientEvents = {}
            truthy(s.contracts.withdrawReward(f.creator, c.id, ids), 'withdrawn')
            eq(s.storage.readContract(c.id).bailout_amount, 0, 'the whole price kept')
            Env.players[2].PlayerData.money.bank = 200000
            local ok, berr = s.bailout.buy(f.target, c.id)
            falsy(ok, 'bought out of a contract with no clean money in it')
            eq(berr, CH.ERR.NO_BUYOUT_PRICE)
            eq(Env.players[2].PlayerData.money.bank, 200000, 'nothing charged')
            local row = auditRows(s, 'bailout_reclamped')[1]
            truthy(row, 'on the record')
            eq(detailOf(row).reason, 'no_clean_money')
            local told = false
            for _, note in ipairs(noticesTo(1)) do
                if note.title == 'Buyout removed' then told = true end
            end
            truthy(told, 'the placer is told')
        end)
    end

    it('a withdrawal that leaves clean money still clamps as before', function()
        local _, s = bootOn('memory')
        local f = fixture(s, { creatorBank = 200000 })
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { bank = 50000, cash = 2000 } }, bailoutAmount = 150000,
        })
        truthy(c)
        local ids = {}
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.source == 'bank' then ids[#ids + 1] = line.id end
        end
        truthy(s.contracts.withdrawReward(f.creator, c.id, ids))
        eq(s.storage.readContract(c.id).bailout_amount,
            math.floor(2000 * Config.Bailout.MaxMultiplier))
    end)
end)

--------------------------------------------------------------------------
-- M5 cheap hardening
--------------------------------------------------------------------------

describe('sweep 5 M5: a give cut off part-way', function()
    it('keeps the balance before it with the claim, and the start says it probably arrived', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f, { reward = { baseline = { bank = 5000 } } })
        local bankBefore = bank(1)
        local settle = s.storage.settleEscrowLine
        s.storage.settleEscrowLine = function() error('Lost connection to server during query', 0) end
        pcall(s.escrow.release, c.id, 'CREATOR1', nil, 'probe')
        s.storage.settleEscrowLine = settle
        eq(bank(1), bankBefore + 5000, 'the give itself landed')
        local line
        for _, l in ipairs(s.storage.readEscrow(c.id)) do
            if l.source == 'bank' then line = l end
        end
        truthy(line)
        eq(tonumber(line.deliver_before), bankBefore, 'what they held when it began')
        line.state = CH.ESCROW_STATE.RELEASING
        truthy(s.escrow.parkInterrupted(line))
        local parked = auditRows(s, 'escrow_deliver_parked')
        eq(detailOf(parked[#parked]).probablyDelivered, true)
    end)
end)

describe('sweep 5 M5: a go-dark refund whose credit raises', function()
    it('is owed with the raise counted, as a buyout refund is', function()
        local IMP = require('tests.harness.improvements')
        local _ = IMP
        local s = newStack()
        Config.Notifications.ParanoidAlertJitter = { min = 0, max = 0 }
        local f = fixture(s)
        local c = place(s, f)
        for src = 1, 3 do Env.players[src].PlayerData.money.bank = 200000 end
        truthy(s.contracts.accept(f.hitman, c.id, false))
        Env.players[2]._coords = { x = 1200.0, y = -800.0, z = 30.0 }
        Env.advance(1)
        Config.Improvements.LocationTip = Config.Improvements.LocationTip
        Config.LocationTip.Enabled = true
        Config.Improvements.GoDark.Enabled = true
        Config.Improvements.GoDark.Cost = 50000
        Config.Improvements.GoDark.Minutes = 30
        local tip = call('locationTip', 3, { id = c.id, shown = { cost = Config.LocationTip.Cost or 25000,
            account = Config.LocationTip.Account or 'bank' } })
        truthy(tip and tip.ok, 'tipped: ' .. tostring(tip and tip.err))
        -- The confirm write raises: the price is given back.
        local write, n = s.storage.writeRpRow, 0
        s.storage.writeRpRow = function(row)
            if row.kind == 'imp_dark' then
                n = n + 1
                if n == 2 then error('lock wait timeout exceeded', 0) end
            end
            return write(row)
        end
        -- And the give back raises with nothing arriving.
        local p = Env.players[2]
        local addMoney = p.Functions.AddMoney
        p.Functions.AddMoney = function() error('AddMoney hook raised', 0) end
        local r = call('goDark', 2, { id = c.id, shown = { cost = 50000, account = 'bank' } })
        s.storage.writeRpRow = write
        p.Functions.AddMoney = addMoney
        falsy(r and r.ok)
        local owed
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.portion == CH.PORTION.OWED and line.owed_to == 'TARGET01' then owed = line end
        end
        truthy(owed, 'owed')
        eq(owed.amount, 50000)
        eq(tonumber(owed.deliver_raises), 1, 'owed blind, the raise not counted')
    end)
end)

describe('sweep 5 M5: a decay step whose top-up raises after the charge', function()
    it('counts the step, so the next is not charged past the cap', function()
        local s = newStack()
        local f = fixture(s, { creatorCash = 500000, creatorBank = 200000 })
        Config.Notifications.ParanoidAlert = false
        Config.Improvements.ContractDecay.Enabled = true
        Config.Improvements.ContractDecay.Mode = 'rise'
        Config.Improvements.ContractDecay.MaxIncreasePercent = Config.Improvements.ContractDecay.Percent
        local c = place(s, f, { reward = { baseline = { cash = 10000 } } })
        s.impBoard.tick()
        local before = s.escrow.moneyValue(c.id)
        local addEscrow = s.amendments.addEscrow
        s.amendments.addEscrow = function(...)
            local out = table.pack(addEscrow(...))
            error('Lost connection to server during query', 0)
            return table.unpack(out, 1, out.n)
        end
        Env.advance(3700)
        pcall(s.impBoard.tick)
        s.amendments.addEscrow = addEscrow
        local step = s.escrow.moneyValue(c.id) - before
        truthy(step > 0, 'the top-up landed')
        for _ = 1, 3 do
            Env.advance(3700)
            pcall(s.impBoard.tick)
        end
        eq(s.escrow.moneyValue(c.id) - before, step, 'charged again past MaxIncreasePercent')
    end)
end)

describe('sweep 5 M5: a top-up on the financial record', function()
    it('names each line\'s account and amount', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f)
        truthy(s.amendments.addEscrow(f.creator, c.id, { baseline = { cash = 1500 } }))
        local row = auditRows(s, 'escrow_added')[1]
        truthy(row)
        local added = detailOf(row).added
        truthy(type(added) == 'table' and added[1], 'the lines it took')
        eq(added[1].source, 'cash')
        eq(added[1].amount, 1500)
    end)
end)
