--- Abuse, anonymity and griefing, driven the way a hostile client would.
---
--- Each block is one hole that was open: a way for one player to make
--- themselves unclaimable, to learn who an anonymous client is, to put text
--- on the board the operator had banned, to skip a creator's waits by
--- switching character, to have their own number shown on a call they paid
--- to keep hidden, or to freeze somebody else's contract.

local AT = { x = 200.0, y = 200.0, z = 30.0 }

local function fire(name, src, ...)
    local handler = Env.events[name]
    if not handler then return nil, 'not registered: ' .. name end
    _G.source = src
    local ok, err = pcall(handler, ...)
    _G.source = nil
    return ok, err
end

--- A net event, the way a client sends it, and the reply it gets.
local function call(name, src, payload)
    local handler = Env.events['crimson-bounty:' .. name]
    if not handler then return { ok = false, err = 'NO SUCH HANDLER' } end
    Env.clientEvents = {}
    _G.source = src
    local fired, err = pcall(handler, payload or {})
    _G.source = nil
    if not fired then return { ok = false, err = 'THREW: ' .. tostring(err) } end
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-bounty:result' then return event.args[1] end
    end
    return nil
end

local function place(s, actor, opts)
    opts = opts or {}
    local c, err = s.contracts.create(actor, {
        targetCid = opts.target or 'TARGET01', reason = opts.reason or 'Unpaid debt',
        mode = opts.mode or CB.MODE.COMPETITIVE,
        reward = { baseline = { cash = opts.cash or 5000 } },
        anonymous = opts.anonymous, penaltyAmount = opts.penalty,
    })
    truthy(c, 'the contract has to exist to be abused: ' .. tostring(err))
    return c
end

--------------------------------------------------------------------------
-- The new-player clock
--------------------------------------------------------------------------

describe('a client-fired login event', function()
    --- QBCore:Server:OnPlayerLoaded is a net event any client can fire. It
    --- restarted the session clock, and immunity is re-checked on every
    --- payout: a target who fired it every nine minutes could never be
    --- claimed on, by a kill or by a handover.
    it('does not make a target who has been here for an hour just-arrived', function()
        local s = newStack()
        local f = fixture(s)
        s.bridges.install(s)
        local c = place(s, f.creator)
        truthy(s.contracts.accept(f.hunter, c.id, false))
        Env.advance(3600)

        for _ = 1, 5 do
            truthy(fire('QBCore:Server:OnPlayerLoaded', 2))
            Env.advance(9 * 60)
            local immune, why = s.contracts.isImmune(s.identity.resolve(2))
            falsy(immune, 'the target made themselves immune: ' .. tostring(why))
        end

        local ok, err = s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION, {})
        truthy(ok, 'and the hunter is paid for the kill: ' .. tostring(err))
    end)

    it('does not restart a session it watched begin', function()
        local s = newStack()
        fixture(s)
        s.bridges.install(s)
        -- A real arrival: the character loads and the framework says so.
        s.identity.endSession('TARGET01')
        truthy(fire('local:qbx_core:server:playerLoaded', nil, { PlayerData = { source = 2 } }))
        eq(s.identity.sessionMinutes('TARGET01'), 0, 'a real login starts the clock')

        Env.advance(15 * 60)
        fire('QBCore:Server:OnPlayerLoaded', 2)
        fire('local:qbx_core:server:playerLoaded', nil, { PlayerData = { source = 2 } })
        eq(s.identity.sessionMinutes('TARGET01'), 15, 'and nothing sent afterwards restarts it')
    end)

    it('still protects somebody who has really just arrived', function()
        local s = newStack()
        local f = fixture(s)
        s.bridges.install(s)
        -- Disconnect and reconnect: the drop ends the session, the arrival
        -- is noticed, and the login event confirms it.
        truthy(fire('local:playerDropped', 2))
        s.identity.resolve(2)
        truthy(fire('QBCore:Server:OnPlayerLoaded', 2))
        local immune, why = s.contracts.isImmune(s.identity.resolve(2))
        truthy(immune, 'a player who has just walked in is not fair game')
        eq(why, CB.ERR.TARGET_JUST_ON)

        Env.advance((Config.Immunity.MinTargetSessionMinutes + 1) * 60)
        falsy(s.contracts.isImmune(s.identity.resolve(2)), 'and then they are')
        local _ = f
    end)
end)

--------------------------------------------------------------------------
-- An anonymous client's presence
--------------------------------------------------------------------------

describe("an anonymous client's presence", function()
    it('is not written on the board (§14.32)', function()
        local s = newStack()
        local f = fixture(s)
        place(s, f.creator, { anonymous = true })
        eq(#s.projection.listing('HUNTER01', 1).contracts, 1)

        Env.removePlayer(1)
        eq(#s.projection.listing('HUNTER01', 1).contracts, 1,
            'the anonymous contract vanished when its creator logged off')
    end)

    it('still hides a named contract whose creator is away (§7.1)', function()
        local s = newStack()
        local f = fixture(s)
        place(s, f.creator)
        Env.removePlayer(1)
        eq(#s.projection.listing('HUNTER01', 1).contracts, 0)
    end)

    it('still hides any contract whose target is away', function()
        local s = newStack()
        local f = fixture(s)
        place(s, f.creator, { anonymous = true })
        Env.removePlayer(2)
        eq(#s.projection.listing('HUNTER01', 1).contracts, 0)
    end)

    it('cannot be asked by pressing Arm', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f.creator, { anonymous = true })
        truthy(s.contracts.accept(f.hunter, c.id, false))
        Env.players[3]._coords = { x = 0.0, y = 0.0, z = 0.0 }
        Env.players[2]._coords = { x = 900.0, y = 900.0, z = 0.0 }
        Env.players[1]._coords = { x = 1500.0, y = 100.0, z = 0.0 }

        local online = call('armKidnap', 3, { id = c.id })
        Env.removePlayer(1)
        local offline = call('armKidnap', 3, { id = c.id })
        falsy(online.ok)
        eq(offline.err, online.err,
            'the refusal said whether the anonymous client was in the city')
    end)

    it('reads as not here, not as offline, with everything else in place', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f.creator, { anonymous = true })
        truthy(s.contracts.accept(f.hunter, c.id, false))
        for _, src in ipairs({ 1, 2, 3 }) do Env.players[src]._coords = { x = AT.x, y = AT.y, z = AT.z } end
        Env.players[2].PlayerData.metadata.ishandcuffed = true
        Env.players[1]._coords = { x = 9000.0, y = 9000.0, z = 30.0 }

        local _, far = s.kidnap.arm(c.id, 'HUNTER01')
        Env.removePlayer(1)
        local _, gone = s.kidnap.arm(c.id, 'HUNTER01')
        eq(far, 'creator_too_far')
        eq(gone, far)
    end)

    it('is not named when a countdown fails for it', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f.creator, { anonymous = true })
        truthy(s.contracts.accept(f.hunter, c.id, false))
        for _, src in ipairs({ 1, 2, 3 }) do Env.players[src]._coords = { x = AT.x, y = AT.y, z = AT.z } end
        Env.players[2].PlayerData.metadata.ishandcuffed = true
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))

        Env.removePlayer(1)
        Env.clientEvents = {}
        for _ = 1, math.ceil((Config.Kidnap.MaxTotalGraceMs + 2000) / Config.Kidnap.TickMs) do
            s.kidnap.tick(Config.Kidnap.TickMs)
        end

        local said
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-bounty:notify' and event.target == 3 then
                said = event.args[1].content
            end
        end
        truthy(said, 'the hunter is told the handover failed')
        falsy(said:find('offline', 1, true), 'and not that their client went offline: ' .. said)
    end)
end)

--------------------------------------------------------------------------
-- The reason on the board
--------------------------------------------------------------------------

describe('a reason changed by agreement', function()
    local function agree(s, c, payload)
        local proposed = call('propose', 1, { id = c.id, kind = 'change_reason', payload = payload })
        if not proposed.ok then return proposed end
        return call('respondAmendment', 1, { id = proposed.data.id, approve = true })
    end

    it('answers to the banned patterns, as a placed or edited one does', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f.creator)
        local r = agree(s, c, { reason = 'join https://discord.gg/abc' })
        falsy(r.ok)
        eq(r.err, CB.ERR.INVALID_INPUT)
        eq(s.storage.readContract(c.id).reason, 'Unpaid debt', 'a link reached the board')
    end)

    it('answers to the phone word list', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f.creator)
        -- The harness phone refuses 'slur'.
        local r = agree(s, c, { reason = 'a slur here' })
        falsy(r.ok)
        eq(s.storage.readContract(c.id).reason, 'Unpaid debt')
    end)

    it('takes only a preset on a preset server', function()
        local s = newStack()
        local f = fixture(s)
        Config.Reason.Mode = 'preset'
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reasonPreset = 1,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c)
        falsy(agree(s, c, { reason = 'anything I like' }).ok,
            'free text on a server that only takes presets')
        eq(s.storage.readContract(c.id).reason, Config.Reason.Presets[1])

        truthy(agree(s, c, { reasonPreset = 2 }).ok, 'a preset is still a change it can make')
        eq(s.storage.readContract(c.id).reason, Config.Reason.Presets[2])
    end)

    it('is not offered on a server that shows no reason', function()
        local s = newStack()
        local f = fixture(s)
        Config.Reason.Mode = 'off'
        local c = place(s, f.creator)
        falsy(agree(s, c, { reason = 'anything' }).ok)
    end)

    it('still goes through when it is an ordinary reason', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f.creator)
        truthy(agree(s, c, { reason = 'Stolen product' }).ok)
        eq(s.storage.readContract(c.id).reason, 'Stolen product')
    end)

    it('is refused, not thrown, when the kind is missing or not a word', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f.creator)
        for _, kind in ipairs({ false, 7, {} }) do
            local r = call('propose', 1, { id = c.id, kind = kind or nil })
            eq(r.err, CB.ERR.INVALID_INPUT, 'kind ' .. tostring(kind))
        end
    end)
end)

--------------------------------------------------------------------------
-- A creator's waits, across characters
--------------------------------------------------------------------------

describe("a creator's limits, on another character", function()
    local function relogAs(cid)
        Env.removePlayer(1)
        Env.addPlayer({ source = 1, citizenid = cid, license = 'license:aaa',
            cash = 100000, bank = 100000, firstname = 'Alt', lastname = 'Ego' })
    end

    it('still waits out naming the same person again', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f.creator)
        truthy(s.contracts.cancel(f.creator, c.id))
        Env.advance(Config.Limits.TargetCooldownAfterResolveSeconds + 60)

        relogAs('CREATOR2')
        local again, err = s.contracts.create(s.identity.resolve(1), {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 5000 } },
        })
        falsy(again, 'a second character on the same licence skipped the two-hour wait')
        eq(err, CB.ERR.SAME_TARGET_TOO_SOON)
    end)

    it('still waits out a cancellation', function()
        local s = newStack()
        local f = fixture(s)
        Env.addPlayer({ source = 7, citizenid = 'TARGET02', license = 'license:t2' })
        local c = place(s, f.creator)
        truthy(s.contracts.cancel(f.creator, c.id))

        relogAs('CREATOR2')
        local _, err = s.contracts.create(s.identity.resolve(1), {
            targetCid = 'TARGET02', reason = 'x', reward = { baseline = { cash = 5000 } },
        })
        eq(err, CB.ERR.CANCELLED_TOO_SOON)
    end)

    it('counts open contracts across every character', function()
        local s = newStack()
        local f = fixture(s)
        for i = 1, Config.Limits.MaxActiveContractsPerCreator do
            local cid = ('TGT%05d'):format(i)
            Env.addPlayer({ source = 20 + i, citizenid = cid, license = 'license:t' .. i })
            place(s, s.identity.resolve(1), { target = cid })
        end

        relogAs('CREATOR2')
        Env.addPlayer({ source = 40, citizenid = 'TGTEXTRA', license = 'license:extra' })
        local _, err = s.contracts.create(s.identity.resolve(1), {
            targetCid = 'TGTEXTRA', reason = 'x', reward = { baseline = { cash = 5000 } },
        })
        eq(err, CB.ERR.LIMIT_REACHED)
        local _ = f
    end)

    it('does not hold one player to another player\'s contracts', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f.creator)
        truthy(s.contracts.cancel(f.creator, c.id))
        Env.advance(Config.Limits.TargetCooldownAfterResolveSeconds + 60)

        Env.addPlayer({ source = 8, citizenid = 'OTHERCR1', license = 'license:other',
            cash = 100000, bank = 100000 })
        truthy(s.contracts.create(s.identity.resolve(8), {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 5000 } },
        }), 'somebody else is not bound by this creator\'s waits')
    end)
end)

--------------------------------------------------------------------------
-- Masked calls
--------------------------------------------------------------------------

describe('a call from somebody who paid to stay anonymous', function()
    local function withPlacer(fn)
        local dialled
        Natives.callExport = function(_, caller, number, anonymous)
            dialled = { caller = caller, number = number, anonymous = anonymous }
            return true
        end
        withConfig({ { Config.Relay, 'CallExport', { resource = 'lb-phone', export = 'StartCall' } } }, function()
            fn(function() return dialled end)
        end)
        Natives.callExport = nil
    end

    it('hides the caller', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f.creator, { anonymous = true })
        truthy(s.contracts.accept(f.hunter, c.id, false))
        local thread = s.comms.threads(f.creator, c.id)[1]

        withPlacer(function(dialled)
            s.comms.resetCallCache()
            local ok, err = s.comms.requestCall(f.creator, c.id, thread.handle)
            truthy(ok, tostring(err))
            eq(dialled().caller, 1)
            eq(dialled().anonymous, true, "the anonymous creator's own number was shown")
        end)
    end)

    it('hides an anonymous operative calling a named client', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f.creator)
        truthy(s.contracts.accept(f.hunter, c.id, true))

        withPlacer(function(dialled)
            s.comms.resetCallCache()
            truthy(s.comms.requestCall(f.hunter, c.id, nil))
            eq(dialled().anonymous, true)
        end)
    end)

    it('is not dialled on a phone that cannot mask, and nothing is refused', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f.creator, { anonymous = true })
        truthy(s.contracts.accept(f.hunter, c.id, false))
        local thread = s.comms.threads(f.creator, c.id)[1]

        withPlacer(function(dialled)
            withConfig({ { Natives, 'phoneConfig', { AnonymousCalls = false } } }, function()
                s.comms.resetCallCache()
                s.comms.resetMaskingCache()
                local ok, err, result = s.comms.requestCall(f.creator, c.id, thread.handle)
                truthy(ok, tostring(err))
                eq(result.placed, false, 'asked to call back instead')
                falsy(dialled(), 'an unmaskable call was placed')
            end)
        end)
        s.comms.resetMaskingCache()
    end)

    it('is still an ordinary call between two named parties', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f.creator)
        truthy(s.contracts.accept(f.hunter, c.id, false))
        withPlacer(function(dialled)
            s.comms.resetCallCache()
            truthy(s.comms.requestCall(f.hunter, c.id, nil))
            eq(dialled().anonymous, false)
        end)
    end)
end)

--------------------------------------------------------------------------
-- Informant data bought by the creator
--------------------------------------------------------------------------

describe('informant data bought by the creator', function()
    --- Both orders of acceptance, because the draw is fixed per contract
    --- and buyer: whichever operative lands on the drawn index is named, so
    --- one of the two orders put the named operative there.
    for _, namedFirst in ipairs({ true, false }) do
        it(('unmasks the anonymous operative, not the named one (%s accepted first)')
            :format(namedFirst and 'named' or 'anonymous'), function()
            local s = newStack()
            local f = fixture(s)
            Env.addPlayer({ source = 5, citizenid = 'HUNTER02', license = 'license:h2',
                cash = 5000, bank = 5000, firstname = 'Kade', lastname = 'Wolfe' })
            local c = place(s, f.creator)
            local named, anon = f.hunter, s.identity.resolve(5)
            if namedFirst then
                truthy(s.contracts.accept(named, c.id, false))
                truthy(s.contracts.accept(anon, c.id, true))
            else
                truthy(s.contracts.accept(anon, c.id, true))
                truthy(s.contracts.accept(named, c.id, false))
            end
            -- Both are on the target.
            s.death.watchTargets(s.storage.allContracts())

            local ok, err, data = s.informant.buy(f.creator, c.id)
            truthy(ok, tostring(err))
            eq(data.name, 'Kade Wolfe',
                'the creator paid for a name already on their own card')
        end)
    end

    it('still names any operative to the target, who sees no roster', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f.creator)
        truthy(s.contracts.accept(f.hunter, c.id, false))
        s.death.watchTargets(s.storage.allContracts())
        Env.players[2].PlayerData.money.bank = Config.Informant.Cost
        local ok, err, data = s.informant.buy(f.target, c.id)
        truthy(ok, tostring(err))
        eq(data.name, 'Rook Ash')
    end)
end)

--------------------------------------------------------------------------
-- An exclusive contract nobody is working
--------------------------------------------------------------------------

describe('an exclusive contract held by somebody who is not working it', function()
    local function held(opts)
        opts = opts or {}
        local s = newStack()
        local f = fixture(s)
        Env.addPlayer({ source = 4, citizenid = 'REALHUNT', license = 'license:real',
            cash = 50000, bank = 50000 })
        local c = place(s, f.creator, { mode = CB.MODE.EXCLUSIVE, cash = 50000,
            penalty = opts.penalty })
        truthy(s.contracts.accept(f.hunter, c.id, false))
        -- Nowhere near the target.
        Env.players[3]._coords = { x = 5000.0, y = 5000.0, z = 0.0 }
        return s, f, c
    end

    --- Minutes of the server running: the condition sampler every second
    --- is folded into one pass a minute, and the maintenance job runs.
    local function run(s, minutes)
        for _ = 1, minutes do
            Env.advance(60)
            s.death.watchTargets(s.storage.allContracts())
            s.contracts.releaseIdleHolds()
        end
    end

    it('goes back on the board', function()
        local s, f, c = held()
        s.contracts.releaseIdleHolds()
        run(s, math.ceil(Config.Limits.ExclusiveIdleReleaseSeconds / 60) + 1)

        eq(s.storage.readContract(c.id).state, CB.STATE.ACTIVE, 'the hold was never released')
        eq(s.storage.readHunter(c.id, 'HUNTER01').state, 'released')
        truthy(s.contracts.accept(s.identity.resolve(4), c.id, false),
            'somebody who will work it can take it')
        local _ = f
    end)

    it('gives the stake back', function()
        local s, f, c = held({ penalty = 2000 })
        truthy((s.storage.readContract(c.id).penalty_amount or 0) > 0)
        local before = Env.players[3].PlayerData.money.bank + Env.players[3].PlayerData.money.cash
        s.contracts.releaseIdleHolds()
        run(s, math.ceil(Config.Limits.ExclusiveIdleReleaseSeconds / 60) + 1)
        local after = Env.players[3].PlayerData.money.bank + Env.players[3].PlayerData.money.cash
        eq(after - before, s.storage.readContract(c.id).penalty_amount,
            'a release is not a fine')
        local _ = f
    end)

    it('is not taken back by the same player, on any character', function()
        local s, f, c = held()
        s.contracts.releaseIdleHolds()
        run(s, math.ceil(Config.Limits.ExclusiveIdleReleaseSeconds / 60) + 1)

        local r = call('accept', 3, { id = c.id, anonymous = false, penaltyAmount = 0 })
        eq(r.err, CB.ERR.HOLD_RELEASED)

        Env.removePlayer(3)
        Env.addPlayer({ source = 3, citizenid = 'HUNTER02', license = 'license:ccc',
            cash = 5000, bank = 5000 })
        local _, err = s.contracts.accept(s.identity.resolve(3), c.id, false)
        eq(err, CB.ERR.HOLD_RELEASED)
        local _ = f
    end)

    it('leaves alone a hunter who is working it', function()
        local s, f, c = held()
        Env.players[3]._coords = { x = 20.0, y = 0.0, z = 0.0 }
        s.contracts.releaseIdleHolds()
        run(s, math.ceil(Config.Limits.ExclusiveIdleReleaseSeconds / 60) * 3)
        eq(s.storage.readHunter(c.id, 'HUNTER01').state, 'active')
        eq(s.storage.readContract(c.id).state, CB.STATE.ACCEPTED)
        local _ = f
    end)

    it('does not count time the target is not in the city', function()
        local s, f, c = held()
        s.contracts.releaseIdleHolds()
        run(s, math.floor(Config.Limits.ExclusiveIdleReleaseSeconds / 60) - 5)

        local target = Env.players[2]
        Env.removePlayer(2)
        run(s, 120)
        eq(s.storage.readHunter(c.id, 'HUNTER01').state, 'active',
            'released for not finding a target who was not there')

        Env.players[2] = target
        Env.byCitizen['TARGET01'] = 2
        run(s, 10)
        eq(s.storage.readHunter(c.id, 'HUNTER01').state, 'released')
        local _ = f
    end)

    it('still sees a hold taken before a restart', function()
        local s, f, c = held()
        -- A fresh process knows nothing of what was accepted before it;
        -- boot rebuilds the index from the store.
        package.loaded['crimson-bounty.server.contracts'] = nil
        local fresh = require('crimson-bounty.server.contracts')
        fresh.init({ storage = s.storage, escrow = s.escrow, identity = s.identity,
                     audit = s.audit, notify = s.notify, progression = s.progression,
                     death = s.death })
        s.contracts = fresh
        eq(fresh.reindexHolds(), 1)
        fresh.releaseIdleHolds()
        run(s, math.ceil(Config.Limits.ExclusiveIdleReleaseSeconds / 60) + 1)
        eq(s.storage.readHunter(c.id, 'HUNTER01').state, 'released')
        local _ = f
    end)

    it('can be switched off', function()
        local s, f, c = held()
        Config.Limits.ExclusiveIdleReleaseSeconds = 0
        s.contracts.releaseIdleHolds()
        run(s, 240)
        eq(s.storage.readHunter(c.id, 'HUNTER01').state, 'active')
        local _ = f
    end)
end)
