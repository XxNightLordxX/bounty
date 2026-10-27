--- The alive handover from end to end, the way the owner's server runs it.
---
--- Every stack in tests/run.lua requires a restrained target
--- (Config.Kidnap.RequireCoercion = true); the resource ships it off, so a
--- handover needs the target alive, conscious, not downed and with the
--- hitman within Config.Kidnap.Radius of the person who placed the contract
--- for Config.Kidnap.CountdownSeconds, and nothing more. These run the whole
--- handover three ways: as shipped, and with the restraint turned back on,
--- once with the target cuffed (QBox metadata 'ishandcuffed') and once
--- riding in the hitman's vehicle. Each covers the arm, the countdown, the
--- payout, the contract closing, who is told what, a target who dies or goes
--- down mid-countdown, the placer walking off, and a restart mid-countdown.

local Shipped = require('crimson-hitman.tests.harness.shipped')

local AT = { x = 200.0, y = 200.0, z = 30.0 }
local REWARD, STAKE = 5000, 1000

local WAYS = {
    { name = 'with no restraint, as shipped', restraint = false },
    { name = 'with the restraint on, the target cuffed', restraint = true, how = 'cuffs' },
    { name = 'with the restraint on, the target a passenger of the hitman', restraint = true,
      how = 'vehicle' },
}

local function money(src)
    local m = Env.players[src].PlayerData.money
    return m.cash + m.bank
end

--- What each player's phone was told since `from` (an index into
--- Env.clientEvents), one notice a line, `title: words`.
local function told(src, from)
    local out = {}
    for i = (from or 1), #Env.clientEvents do
        local e = Env.clientEvents[i]
        if (e.name == 'lb-phone:SendNotification' or e.name == 'crimson-hitman:notify')
            and e.target == src then
            local d = e.args and e.args[1] or {}
            out[#out + 1] = tostring(d.title) .. ': ' .. tostring(d.content or d.description)
        end
    end
    return table.concat(out, '\n')
end

--- The three of them together, the target as `way` holds them.
local function together(way)
    for _, src in ipairs({ 1, 2, 3 }) do
        Env.players[src]._coords = { x = AT.x, y = AT.y, z = AT.z }
    end
    local target = Env.players[2]
    target.PlayerData.metadata.ishandcuffed = way.how == 'cuffs'
    target._vehicle, Env.players[3]._vehicle = nil, nil
    if way.how == 'vehicle' then target._vehicle, Env.players[3]._vehicle = 55, 55 end
end

--- The shipped switches, the restraint as `way` says, and a contract placed
--- and taken with a stake.
local function placed(way, s)
    s = s or Shipped.newStack()
    Config.Kidnap.RequireCoercion = way.restraint
    local f = fixture(s)
    local c, err = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
        penaltyAmount = STAKE, reward = { baseline = { cash = REWARD } },
    })
    truthy(c, 'placed: ' .. tostring(err))
    eq(c.fulfilment_rule, CH.FULFILMENT_RULE.ALIVE, 'alive only, as shipped')
    truthy(s.contracts.accept(f.hitman, c.id, false), 'taken, with the stake')
    return s, f, c
end

local function ticks(s, n)
    for _ = 1, n do s.kidnap.tick(Config.Kidnap.TickMs) end
end

local function full() return math.floor(Config.Kidnap.CountdownSeconds * 1000 / Config.Kidnap.TickMs) end

for _, way in ipairs(WAYS) do
    describe('the alive handover, ' .. way.name, function()
        it('arms only on what the rule asks for', function()
            local s, _, c = placed(way)
            together({ how = nil })
            if way.restraint then
                local ok, why = s.kidnap.arm(c.id, 'HITMAN01')
                falsy(ok, 'a target walking free is not restrained')
                eq(why, 'not_coerced')
                together(way)
            else
                eq(select(2, s.kidnap.isCoerced(3, 2)), 'not_required')
            end
            truthy(s.kidnap.arm(c.id, 'HITMAN01'), 'armed')
            eq(s.kidnap.activeCount(), 1)
        end)

        it('counts down, pays the hitman, closes the contract and tells the placer', function()
            local s, _, c = placed(way)
            together(way)
            local creatorBefore, hitmanBefore, targetBefore = money(1), money(3), money(2)
            local mark = #Env.clientEvents + 1
            truthy(s.kidnap.arm(c.id, 'HITMAN01'))
            truthy(told(1, mark):find('Handover starting: A hitman has brought your target to you '
                .. 'for the handover. Stay where you are, within 12 m of them both, for 30 seconds.',
                1, true), 'the placer is told to stay: ' .. told(1, mark))

            ticks(s, 10)
            local progress = s.kidnap.progress(c.id, 'HITMAN01')
            eq(progress.elapsed, 10, 'ten seconds in')
            eq(progress.required, Config.Kidnap.CountdownSeconds)
            eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'not paid before the end')
            eq(money(3), hitmanBefore, 'nothing paid yet')

            ticks(s, full() - 10)
            eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED, 'the contract closed')
            eq(s.kidnap.activeCount(), 0)
            eq(money(3), hitmanBefore + REWARD + STAKE, 'the hitman is paid, and the stake comes back')
            eq(money(1), creatorBefore, 'the reward was taken from the placer once, at placing')
            eq(money(2), targetBefore, 'the target pays nothing')
            eq(s.kidnap.outcome(c.id, 'HITMAN01').outcome, 'paid', 'the hitman\'s page is told paid')

            local placer, hitman, target = told(1, mark), told(3, mark), told(2, mark)
            truthy(placer:find('Contract fulfilled: Your contract was fulfilled by live delivery',
                1, true), 'the placer is told it was fulfilled: ' .. placer)
            truthy(hitman:find('Handover paid: Delivered alive', 1, true),
                'the hitman has a receipt: ' .. hitman)
            eq(target, '', 'the target is told nothing by the handover: they were there')
            falsy(placer:find('Rook', 1, true), 'the placer is not given the hitman\'s name')
        end)

        for _, down in ipairs({ { 'dies', 'isdead' }, { 'goes into last stand', 'inlaststand' } }) do
            it('fails, pays nothing and keeps the contract open when the target ' .. down[1]
                .. ' mid-countdown', function()
                local s, _, c = placed(way)
                together(way)
                local hitmanBefore = money(3)
                truthy(s.kidnap.arm(c.id, 'HITMAN01'))
                ticks(s, 5)
                Env.players[2].PlayerData.metadata[down[2]] = true
                local mark = #Env.clientEvents + 1
                ticks(s, full())
                eq(s.kidnap.activeCount(), 0, 'the countdown ended')
                eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'still open')
                eq(money(3), hitmanBefore, 'nothing paid')
                local outcome = s.kidnap.outcome(c.id, 'HITMAN01')
                eq(outcome.outcome, 'failed')
                eq(outcome.reason, 'target_not_conscious')
                truthy(told(3, mark):find('Handover failed: The target went down before the '
                    .. 'handover finished.', 1, true), told(3, mark))
                truthy(told(1, mark):find('Handover stopped: The handover did not finish, so your '
                    .. 'contract is still open', 1, true), 'the placer is told: ' .. told(1, mark))
                eq(told(2, mark), '', 'the target is told nothing')

                -- Back on their feet, and past the wait after a failed one,
                -- the handover is armed again and pays.
                Env.players[2].PlayerData.metadata[down[2]] = false
                local again = s.kidnap.arm(c.id, 'HITMAN01')
                falsy(again, 'not straight away')
                Env.time = Env.time + Config.Kidnap.RearmCooldownSeconds
                truthy(s.kidnap.arm(c.id, 'HITMAN01'), 'armed again')
                ticks(s, full())
                eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED)
                eq(money(3), hitmanBefore + REWARD + STAKE, 'paid once')
            end)
        end

        it('fails when the placer walks out of range, and pays nothing', function()
            local s, _, c = placed(way)
            together(way)
            local hitmanBefore = money(3)
            truthy(s.kidnap.arm(c.id, 'HITMAN01'))
            ticks(s, 5)
            Env.players[1]._coords = { x = AT.x + Config.Kidnap.Radius + 1, y = AT.y, z = AT.z }
            local mark = #Env.clientEvents + 1
            ticks(s, full())
            eq(s.kidnap.activeCount(), 0)
            eq(s.kidnap.outcome(c.id, 'HITMAN01').reason, 'creator_too_far')
            eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'still open')
            eq(money(3), hitmanBefore)
            truthy(told(3, mark):find('The person who placed this contract did not arrive in time',
                1, true), told(3, mark))
            truthy(told(1, mark):find('stay within 12 m of them both for the whole 30 seconds', 1, true),
                'the placer is told what it needs: ' .. told(1, mark))
        end)

        it('rides out a step away and back inside the grace', function()
            local s, _, c = placed(way)
            together(way)
            truthy(s.kidnap.arm(c.id, 'HITMAN01'))
            ticks(s, 5)
            Env.players[1]._coords = { x = AT.x + Config.Kidnap.Radius + 1, y = AT.y, z = AT.z }
            ticks(s, 2)
            Env.players[1]._coords = { x = AT.x, y = AT.y, z = AT.z }
            ticks(s, full())
            eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED, 'two seconds out is forgiven')
        end)
    end)
end

--------------------------------------------------------------------------
-- A restart in the middle of a countdown
--------------------------------------------------------------------------

local function forget()
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
            package.loaded[name] = nil
        end
    end
end

--- The real server on the json store, with the shipped switches.
local function boot(way)
    forget()
    Env.reset()
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Natives.resetResourceStates()
    resetConfig()
    Shipped.apply()
    Config.Debug = false
    Config.Kidnap.RequireCoercion = way.restraint
    Config.Database.Mode = 'json'
    Natives.files = {}
    local main = require('server.main')
    return main, main.start()
end

--- The same disk after the process died, mid-countdown: no stop, no flush.
--- The players stay connected, as they do through a resource restart.
local function restart(old)
    if old and old.storage then rawset(old.storage, '__rawFixture', true) end
    forget()
    Env.events, Env.clientEvents, Env.notifications = {}, {}, {}
    Env.handlers, Env.threads, Env.timers, Env.commands = {}, {}, {}, {}
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    local main = require('server.main')
    return main, main.start()
end

for _, way in ipairs(WAYS) do
    describe('a restart in the middle of a handover, ' .. way.name, function()
        it('loses the countdown and nothing else: the contract, the stake and the reward stay, '
            .. 'and the next handover pays once', function()
            local main, s = boot(way)
            local _, f, c = placed(way, s)
            main.tick()
            together(way)
            local creatorBefore, hitmanBefore = money(1), money(3)
            truthy(s.kidnap.arm(c.id, 'HITMAN01'))
            ticks(s, 20)

            Env.advance(5)
            local main2, s2 = restart(s)
            eq(s2.kidnap.activeCount(), 0, 'a countdown is kept in memory, and the restart took it')
            eq(s2.kidnap.progress(c.id, 'HITMAN01'), nil)
            local polled, why = s2.app.handlers.kidnapProgress(s2.identity.resolve(3), { id = c.id })
            eq(polled, false, 'the page is not shown a countdown that is gone')
            eq(why, CH.ERR.NO_HANDOVER, 'it is told none is running, and offers Deliver alive again')
            local after = s2.storage.readContract(c.id)
            eq(after.state, CH.STATE.ACCEPTED, 'still open after the restart')
            eq(money(3), hitmanBefore, 'nothing was paid for the twenty seconds')
            eq(money(1), creatorBefore)
            local held = 0
            for _, line in ipairs(s2.storage.readEscrow(c.id)) do
                if line.state == CH.ESCROW_STATE.HELD then held = held + 1 end
            end
            truthy(held >= 2, 'the reward and the stake are still held: ' .. held)

            -- The parties never left, so the pause the start put on the
            -- contract comes off at the first pass, and the deadline moved
            -- on by the seconds the server was down.
            main2.tick()
            local running = s2.storage.readContract(c.id)
            eq(running.paused_since, nil, 'running again')
            truthy(running.deadline_at >= after.deadline_at, 'never charged for the restart')

            -- No wait after a failed one: the restart was not the hitman's
            -- failure. Armed again, the whole countdown runs, and pays once.
            truthy(s2.kidnap.arm(c.id, 'HITMAN01'), 'armed again at once')
            ticks(s2, full())
            eq(s2.storage.readContract(c.id).state, CH.STATE.COMPLETED)
            eq(money(3), hitmanBefore + REWARD + STAKE, 'paid once, the stake back')
            eq(money(1), creatorBefore, 'and the placer charged once')
            eq(f.creator.cid, 'CREATOR1')
        end)
    end)
end
