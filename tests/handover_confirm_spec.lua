--- The placer's Confirm handover (Config.Kidnap.PlacerConfirms, off as
--- shipped): a live handover held for the whole countdown waits on the
--- placer's word before it pays; a decline, or a window that runs out
--- (Config.Kidnap.ConfirmMissed 'rearm'), pays nothing and leaves the
--- contract open for the hitman to arm again. Only the placer may answer;
--- nobody is named to anybody; a freeze, the restart hold and the app pause
--- are each handled; the meeting point's 'What to do' words follow the
--- option.

local Shipped = require('tests.harness.shipped')

local AT = { x = 200.0, y = 200.0, z = 30.0 }
local REWARD, STAKE = 5000, 1000

local function money(src)
    local m = Env.players[src].PlayerData.money
    return m.cash + m.bank
end

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

local function together()
    for _, src in ipairs({ 1, 2, 3 }) do
        Env.players[src]._coords = { x = AT.x, y = AT.y, z = AT.z }
    end
end

--- A stack as shipped, the option as `on` says, a contract placed and taken.
local function placed(on, configure, anonymous)
    local s = Shipped.newStack()
    Config.Kidnap.PlacerConfirms = on
    if configure then configure() end
    local f = fixture(s)
    local c, err = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
        penaltyAmount = STAKE, reward = { baseline = { cash = REWARD } }, anonymous = anonymous,
    })
    truthy(c, 'placed: ' .. tostring(err))
    truthy(s.contracts.accept(f.hitman, c.id, false), 'taken')
    s.bridges.install(s)
    together()
    return s, f, c
end

local function ticks(s, n)
    for _ = 1, n do s.kidnap.tick(Config.Kidnap.TickMs) end
end

local function full() return math.floor(Config.Kidnap.CountdownSeconds * 1000 / Config.Kidnap.TickMs) end
local function window() return math.floor(Config.Kidnap.ConfirmSeconds * 1000 / Config.Kidnap.TickMs) end

--- The app's request, as the phone sends it.
local function call(name, src, payload)
    local fire = Env.events['crimson-hitman:' .. name]
    assert(fire, 'no handler for ' .. name)
    local mark = #Env.clientEvents
    _G.source = src
    local ok, err = pcall(fire, payload)
    _G.source = nil
    assert(ok, name .. ' raised: ' .. tostring(err))
    for i = #Env.clientEvents, mark + 1, -1 do
        local event = Env.clientEvents[i]
        if event.name == 'crimson-hitman:result' and event.target == src then return event.args[1] end
    end
    return nil
end

local function state(s, c) return s.storage.readContract(c.id).state end

describe('Confirm handover: off, as shipped', function()
    it('ships off, and a handover pays at the end of its hold with nothing to confirm', function()
        eq(Shipped.fromFile().Kidnap.PlacerConfirms, false, 'off in config.lua')
        local s, _, c = placed(false)
        local before = money(3)
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        ticks(s, full())
        eq(state(s, c), CH.STATE.COMPLETED)
        eq(money(3), before + REWARD + STAKE)
        eq(s.projection.contract(s.storage.readContract(c.id), 'CREATOR1').handoverConfirm, nil)
        local reply = call('confirmHandover', 1, { id = c.id })
        eq(reply.err, CH.ERR.NO_HANDOVER, 'nothing waits on a word')
    end)

    it('keeps the meeting point words of a placer with nothing to tap', function()
        Shipped.newStack()
        Config.Kidnap.PlacerConfirms = false
        local steps = require('crimson-hitman.server.meeting').steps('placer')
        truthy(steps:find('you have nothing to tap', 1, true), steps)
    end)
end)

describe('Confirm handover: on', function()
    it('waits on the placer after the hold, and pays once they confirm (two-tap on the card)', function()
        local s, _, c = placed(true)
        local creatorBefore, hitmanBefore = money(1), money(3)
        local mark = #Env.clientEvents + 1
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        truthy(told(1, mark):find('Then tap Confirm handover', 1, true), 'the arm notice says so')
        ticks(s, full())
        eq(state(s, c), CH.STATE.ACCEPTED, 'not paid on the hold alone')
        eq(money(3), hitmanBefore, 'nothing paid yet')
        local card = s.projection.contract(s.storage.readContract(c.id), 'CREATOR1')
        eq(card.handoverConfirm, Config.Kidnap.ConfirmSeconds, 'the placer has the window on their card')
        local progress = s.kidnap.progress(c.id, 'HITMAN01')
        eq(progress.awaitingConfirm, true, 'the hitman is told it waits on the placer')
        truthy(told(1, mark):find('Confirm handover: The hold is done', 1, true), told(1, mark))
        truthy(told(3, mark):find('Handover held', 1, true), told(3, mark))

        local reply = call('confirmHandover', 1, { id = c.id })
        truthy(reply.ok, 'confirmed: ' .. tostring(reply.err))
        eq(reply.data.confirmed, true)
        eq(call('confirmHandover', 1, { id = c.id }).err, CH.ERR.NO_HANDOVER, 'a second tap finds nothing waiting')
        eq(call('confirmHandover', 1, { id = c.id, decline = true }).err, CH.ERR.NO_HANDOVER,
            'nor can a confirm be taken back')
        ticks(s, 1)
        eq(state(s, c), CH.STATE.COMPLETED, 'paid once confirmed')
        eq(money(3), hitmanBefore + REWARD + STAKE, 'the hitman is paid, the stake back')
        eq(money(1), creatorBefore, 'the placer paid once, at placing')
        eq(s.kidnap.outcome(c.id, 'HITMAN01').outcome, 'paid')
    end)

    it('pays nothing on a decline, keeps the contract open, and lets the hitman arm again', function()
        local s, _, c = placed(true)
        local hitmanBefore = money(3)
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        ticks(s, full())
        local mark = #Env.clientEvents + 1
        local reply = call('confirmHandover', 1, { id = c.id, decline = true })
        truthy(reply.ok)
        eq(reply.data.declined, true)
        ticks(s, 3)
        eq(state(s, c), CH.STATE.ACCEPTED, 'still open')
        eq(money(3), hitmanBefore, 'nothing paid')
        eq(s.kidnap.activeCount(), 0)
        eq(s.kidnap.outcome(c.id, 'HITMAN01').reason, 'not_confirmed')
        truthy(told(3, mark):find('did not confirm the handover', 1, true), told(3, mark))
        falsy(told(3, mark):find('declined', 1, true), 'the hitman cannot tell a decline from a timeout')
        local again = s.kidnap.arm(c.id, 'HITMAN01')
        falsy(again, 'the usual re-arm wait')
        Env.advance(Config.Kidnap.RearmCooldownSeconds + 1)
        truthy(s.kidnap.arm(c.id, 'HITMAN01'), 'armed again after the wait')
    end)

    it('pays nothing when the window runs out (ConfirmMissed rearm, the default)', function()
        local s, _, c = placed(true)
        eq(Config.Kidnap.ConfirmMissed, 'rearm')
        local before = money(3)
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        ticks(s, full() + window() + 1)
        eq(state(s, c), CH.STATE.ACCEPTED)
        eq(money(3), before)
        eq(s.kidnap.outcome(c.id, 'HITMAN01').reason, 'not_confirmed')
    end)

    it('pays as confirmed when the window runs out under ConfirmMissed pay', function()
        local s, _, c = placed(true, function() Config.Kidnap.ConfirmMissed = 'pay' end)
        local before = money(3)
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        ticks(s, full() + window() + 2)
        eq(state(s, c), CH.STATE.COMPLETED)
        eq(money(3), before + REWARD + STAKE)
    end)

    it('answers only the placer: the hitman, the target and a stranger are told not found', function()
        local s, _, c = placed(true)
        Env.addPlayer({ source = 9, citizenid = 'PUBLIC01', license = 'license:pub', cash = 0, bank = 0 })
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        ticks(s, full())
        for _, src in ipairs({ 2, 3, 9 }) do
            eq(call('confirmHandover', src, { id = c.id }).err, CH.ERR.NOT_FOUND, 'source ' .. src)
        end
        eq(s.kidnap.activeCount(), 1, 'still waiting on the placer')
        -- Hostile payloads.
        for _, payload in ipairs({ { id = 42 }, { id = string.rep('x', 300) }, { id = c.id, decline = 'yes' },
            'not a table', { id = { c.id } } }) do
            local reply = call('confirmHandover', 1, payload)
            falsy(reply.ok, 'refused: ' .. tostring(type(payload) == 'table' and payload.id or payload))
        end
        eq(s.kidnap.activeCount(), 1, 'nothing hostile ended it')
    end)

    it('is cancelled by a staff freeze, pays nothing, and refuses a confirm meanwhile', function()
        local s, _, c = placed(true)
        local before = money(3)
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        ticks(s, full())
        truthy(s.holds.freeze('ADMIN001', 'TARGET01', 'dispute'))
        eq(s.kidnap.activeCount(), 0, 'the freeze stops it')
        eq(call('confirmHandover', 1, { id = c.id }).err, CH.ERR.NO_HANDOVER)
        ticks(s, 5)
        eq(money(3), before)
        eq(state(s, c), CH.STATE.ACCEPTED)
    end)

    it('stands still on the restart hold and refuses a confirm until it lifts', function()
        local s, _, c = placed(true)
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        ticks(s, full())
        local left = s.kidnap.progress(c.id, 'HITMAN01').confirmLeft
        truthy(s.holds.scheduledRestart({ secondsRemaining = 60 }), 'restart hold on')
        ticks(s, window() + 5)
        eq(s.kidnap.activeCount(), 1, 'the window did not run out on the hold')
        eq(s.kidnap.progress(c.id, 'HITMAN01').confirmLeft, left, 'stood still')
        eq(call('confirmHandover', 1, { id = c.id }).err, CH.ERR.RESTART_HOLD)
    end)

    it('stands still while the app is paused, and a confirm still pays', function()
        local s, _, c = placed(true)
        local before = money(3)
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        ticks(s, full())
        Config.Holds.AppPaused = true
        s.holds.syncAppPause()
        ticks(s, window() + 5)
        eq(s.kidnap.activeCount(), 1, 'the window held while paused')
        Config.Holds.AppPaused = false
        s.holds.syncAppPause()
        truthy(call('confirmHandover', 1, { id = c.id }).ok)
        ticks(s, 1)
        eq(money(3), before + REWARD + STAKE)
    end)

    it('keeps the rule a handover was armed under when the option is switched meanwhile', function()
        local s, _, c = placed(true)
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        Config.Kidnap.PlacerConfirms = false
        ticks(s, full())
        eq(state(s, c), CH.STATE.ACCEPTED, 'still waits on the placer')
        eq(s.kidnap.progress(c.id, 'HITMAN01').awaitingConfirm, true)
    end)

    it('names nobody: an anonymous placer and the hitman are not told of each other', function()
        local s, _, c = placed(true, function() Config.Anonymity.AllowAnonymousPlacer = true end, true)
        local mark = #Env.clientEvents + 1
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))
        ticks(s, full())
        truthy(call('confirmHandover', 1, { id = c.id }).ok)
        ticks(s, 1)
        local placer, hitman = told(1, mark), told(3, mark)
        for _, name in ipairs({ 'Rook', 'Ash', 'Operative #1' }) do
            falsy(placer:find(name, 1, true), 'the placer is not told ' .. name .. ': ' .. placer)
        end
        for _, name in ipairs({ 'Vic', 'Marlowe' }) do
            falsy(hitman:find(name, 1, true), 'the hitman is not told ' .. name .. ': ' .. hitman)
        end
        local card = s.projection.contract(s.storage.readContract(c.id), 'HITMAN01')
        eq(card.handoverConfirm, nil, 'the hitman\'s card carries no confirm')
    end)

    it('says the confirm in the meeting point\'s What to do words, both sides', function()
        Shipped.newStack()
        Config.Kidnap.PlacerConfirms = true
        local Meeting = require('crimson-hitman.server.meeting')
        local placer, hitman = Meeting.steps('placer'), Meeting.steps('hitman')
        truthy(placer:find('tap Confirm handover', 1, true), placer)
        falsy(placer:find('nothing to tap', 1, true), placer)
        truthy(hitman:find('confirms the handover', 1, true), hitman)
        truthy(placer:find(tostring(Config.Kidnap.ConfirmSeconds) .. ' seconds', 1, true), placer)
    end)

    it('corrects a wrong setting at start, said', function()
        Shipped.newStack()
        local HC = require('server.handover_confirm')
        Config.Kidnap.PlacerConfirms, Config.Kidnap.ConfirmSeconds, Config.Kidnap.ConfirmMissed = 'yes', 5, 'x'
        local warn = {}
        HC.validate(warn)
        eq(#warn, 3)
        eq(Config.Kidnap.PlacerConfirms, false)
        eq(Config.Kidnap.ConfirmSeconds, 60)
        eq(Config.Kidnap.ConfirmMissed, 'rearm')
    end)
end)
