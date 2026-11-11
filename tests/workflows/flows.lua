--- The main flows of step 7, each a list of steps a player or staff takes
--- through the real handlers, shared by the matrix spec and the others.
---
--- A flow is { name, setup(ctx), steps = { { name, run(ctx), done(ctx) } },
--- final(ctx), delta(ctx) }:
---   * setup runs once after the boot and the cast (staff turning the
---     feature on from the panel where a profile ships it off);
---   * run takes the step as the player would, and asserts what they see;
---     done says whether its effect is already in the store, so a step cut
---     off by a crash mid-await is taken again only when it did not land
---     (the player trying again);
---   * final asserts the outcome; delta is the money the flow is allowed to
---     take out of (or put into) the world: an intel price, a staff deposit.
---
--- Every step reads the server through W.s, which a restart replaces.

local W = require('tests.workflows.lib')

local F = {}

local REASON = 'Owes the crew forty grand from the dock job and skipped town'

local function cast(role) return W.CAST[role] end
local function src(role) return W.CAST[role].source end
local function cid(role) return W.CAST[role].cid end

local function wealth(role)
    local p = W.everyone[cid(role)]
    return p and W.purse(p) or 0
end
F.wealth = wealth

--- The handle the place form picks the target by.
local function targetHandle(name)
    local data = W.ok(src('creator'), 'searchTargets', { query = name or 'Dana' }, 'search the target')
    for _, row in ipairs(data or {}) do
        if row.name == 'Dana Reyes' or (name and row.name and row.name:find(name, 1, true)) then
            return row.handle
        end
    end
    error('the target is not in the search: ' .. tostring(name))
end

--- What the place form sends.
function F.placePayload(ctx, extra)
    local payload = {
        target = targetHandle(ctx.targetName),
        reason = REASON, mode = 'competitive',
        reward = { slots = { { baseline = { cash = ctx.reward or 5000 } } } },
        bailoutAmount = ctx.bailout or 0, penaltyAmount = 0, anonymous = false,
        shown = { creatorFee = 0, feeAccount = 'bank', fulfilment = Config.Completion.Fulfilment,
                  protectedAck = false },
    }
    for k, v in pairs(extra or {}) do payload[k] = v end
    return payload
end

--- The one contract the creator has, live or ended.
local function theContract()
    local list = W.s.storage.contractsBy(cid('creator')) or {}
    local best
    for _, c in ipairs(list) do
        if not best or (c.created_at or 0) >= (best.created_at or 0) then best = c end
    end
    return best
end
F.theContract = theContract

local function hitmanRow(contractId, who)
    for _, h in ipairs(W.s.storage.readHitmen(contractId) or {}) do
        if h.hitman_cid == cid(who or 'hitman') then return h end
    end
    return nil
end
F.hitmanRow = hitmanRow

--- The audit row a flow must leave. Not asked after a crash: conduct and
--- staff rows are held in memory between flushes (server/audit.lua), and a
--- crash loses what the queue held of them. Financial rows are kept on the
--- machine until written on mysql (step 8a, BUG-1): the matrix spec's
--- pinned tests ask that of them.
function F.audited(ctx, action)
    if ctx.crashed then return end
    truthy(#W.audit(action) >= 1, 'audited ' .. action)
end

--- Staff clearing what a crash left mid-release (/ch-stuck, the panel's
--- Stuck list): a line put back to held and parked for staff, owed to
--- somebody. Staff check whether it arrived, as the hint says
--- (deliver_before, the balance before the give), and settle it:
--- 'delivered' where it did, 'pay' where it did not.
function F.staffClearsStuck()
    local list = W.op(src('staff'), 'stuck', {})
    truthy(list and list.ok, 'the stuck list opens: ' .. tostring(list and list.err))
    -- What the list says of each line: a payout paid as an item (paidAs)
    -- is checked in that item, as the list tells staff to.
    local listed = {}
    local shown = type(list.data) == 'table' and list.data.lines or {}
    for _, e in ipairs(shown) do
        if type(e) == 'table' and e.line then listed[e.line] = e end
    end
    for _, l in ipairs(W.s.storage.unsettledEscrow() or {}) do
        if l.owed_to and W.s.escrow.parked and W.s.escrow.parked(l) then
            local p = W.everyone[l.owed_to]
            local arrived = false
            local before = tonumber(l.deliver_before)
            local as = listed[l.id] and listed[l.id].paidAs
            if p and before and as then
                local held = 0
                for _, e in ipairs(p._inventory or {}) do
                    if e.name == as then held = held + (e.count or 0) end
                end
                arrived = held >= before + (tonumber(l.amount) or 0)
            elseif p and before and (l.source == 'cash' or l.source == 'bank') then
                arrived = (p.PlayerData.money[l.source] or 0) >= before + (tonumber(l.amount) or 0)
            end
            local r = W.op(src('staff'), 'settle', { line = l.id, disposition = arrived and 'delivered' or 'pay' })
            truthy(r and r.ok, 'staff settled the parked line: ' .. tostring(r and r.err) .. ' ' .. tostring(r and r.message))
            W.cleared = (W.cleared or 0) + 1
        end
    end
end

--------------------------------------------------------------------------
-- Common steps
--------------------------------------------------------------------------

local function stepPlace(extra)
    return {
        name = 'place', needsTarget = true,
        run = function(ctx)
            local data = W.ok(src('creator'), 'create', F.placePayload(ctx, extra), 'place')
            ctx.id = data.id
            truthy(ctx.id, 'the reply names the contract')
            eq(data.role, 'creator', 'the placer sees their own card')
            truthy(#W.audit('contract_created') >= 1, 'audited contract_created')
        end,
        done = function(ctx)
            local c = theContract()
            if c then ctx.id = c.id end
            return c ~= nil
        end,
    }
end
F.stepPlace = stepPlace

local function stepAccept(who)
    who = who or 'hitman'
    return {
        name = 'accept', needsTarget = true,
        run = function(ctx)
            -- On the board first, as the hitman finds it.
            local board = W.ok(src(who), 'list', { page = 1 }, 'the board')
            local found
            for _, card in ipairs(board.contracts or {}) do if card.id == ctx.id then found = card end end
            truthy(found, 'the contract is on the hitman\'s board')
            -- Rumours on: the broker briefs the hitman first, where he stands.
            if Config.Intel.Rumours and Config.Intel.Rumours.Enabled then
                W.at(src(who), W.SCENE.x, W.SCENE.y, W.SCENE.z)
                W.ok(src(who), 'rumourBrief', { id = ctx.id }, 'the broker\'s brief')
            end
            -- What the page echoes: the terms as the card showed them.
            local shown = { hitmanFee = 0, feeAccount = 'bank', creatorAnonymous = found.creatorAnonymous == true,
                            fulfilment = found.fulfilment, bailoutAmount = found.bailoutAmount }
            if board.orgTerms and type(board.orgTerms.orgPercent) == 'number' then
                shown.orgCut = board.orgTerms.orgPercent
            end
            local data = W.ok(src(who), 'accept', { id = ctx.id, anonymous = false,
                penaltyAmount = found.penaltyAmount or 0, timeLeft = found.timeLeft, shown = shown }, 'accept')
            eq(data.role, 'hitman', 'the hitman sees their card')
            truthy(hitmanRow(ctx.id, who), 'a hitman row')
        end,
        done = function(ctx)
            local h = ctx.id and hitmanRow(ctx.id, who)
            return h ~= nil and h.state == 'active'
        end,
    }
end
F.stepAccept = stepAccept

--- The handover: everyone at the scene, the target held where the rule
--- says, the countdown armed and run by the shared thread's passes.
local function stepHandover()
    return {
        name = 'handover', needsTarget = true,
        run = function(ctx)
            W.allAt()
            if Config.Kidnap.RequireCoercion then
                Env.players[src('target')].PlayerData.metadata.ishandcuffed = true
            end
            local r = W.phone(src('hitman'), 'armKidnap', { id = ctx.id })
            truthy(r and r.ok, 'armed: ' .. tostring(r and r.err))
            local seen = W.ok(src('hitman'), 'kidnapProgress', { id = ctx.id }, 'the countdown')
            truthy(seen, 'the hitman sees the countdown')
        end,
        done = function(ctx)
            local c = W.contract(ctx.id)
            if c and c.state ~= CH.STATE.ACCEPTED then return true end
            return W.s.kidnap.armedAt(ctx.id, cid('hitman')) ~= nil
        end,
    }
end
F.stepHandover = stepHandover

--- The countdown run to its end, the placer confirming where they must.
local function stepPayout()
    return {
        name = 'payout', needsTarget = true,
        run = function(ctx)
            W.allAt()
            if W.s.kidnap.armedAt(ctx.id, cid('hitman')) == nil
                and W.contract(ctx.id).state == CH.STATE.ACCEPTED then
                -- The countdown did not survive (a restart or a drop): the
                -- hitman arms it again, as they would.
                -- After a failed handover the hitman waits the re-arm
                -- cooldown (Config.Kidnap.RearmCooldownSeconds) first.
                W.tick(1, (tonumber(Config.Kidnap.RearmCooldownSeconds) or 0) + 1)
                W.allAt()
                local r = W.phone(src('hitman'), 'armKidnap', { id = ctx.id })
                truthy(r and r.ok, 'armed again: ' .. tostring(r and r.err))
            end
            local passes = math.ceil((Config.Kidnap.CountdownSeconds + 5) * 1000 / Config.Kidnap.TickMs)
            for _ = 1, passes do W.s.kidnap.tick(Config.Kidnap.TickMs) end
            if Config.Kidnap.PlacerConfirms then
                local r = W.phone(src('creator'), 'confirmHandover', { id = ctx.id })
                truthy(r and r.ok, 'the placer confirmed: ' .. tostring(r and r.err))
                for _ = 1, 5 do W.s.kidnap.tick(Config.Kidnap.TickMs) end
            end
        end,
        done = function(ctx)
            local c = W.contract(ctx.id)
            return c ~= nil and CH.TERMINAL[c.state] == true
        end,
    }
end
F.stepPayout = stepPayout

--- What a paid contract ends as, whatever held the money on the way: the
--- ticks run past every hold (proof of intent, a queued delivery).
function F.settle(minutes)
    for _ = 1, (minutes or 70) do W.tick(1, 60) end
end

--------------------------------------------------------------------------
-- 1. place -> accept -> handover -> payout
--------------------------------------------------------------------------

F.contract = {
    name = 'contract',
    setup = function(ctx)
        ctx.reward = 5000
        ctx.before = { creator = wealth('creator'), hitman = wealth('hitman') }
    end,
    steps = { stepPlace(), stepAccept(), stepHandover(), stepPayout() },
    final = function(ctx)
        F.settle()
        local c = W.contract(ctx.id)
        truthy(c, 'the contract is kept')
        eq(c.state, CH.STATE.COMPLETED, 'the handover completed the contract')
        eq(wealth('hitman') - ctx.before.hitman, ctx.reward, 'the hitman was paid the reward')
        eq(ctx.before.creator - wealth('creator'), ctx.reward, 'the placer paid the reward')
        F.audited(ctx, 'slot_claimed')
        -- The hitman's ledger has the figure, never who.
        local ledger = W.ok(src('hitman'), 'ledger', {}, 'the hitman\'s ledger')
        falsy(W.leaks(ledger, { 'TARGET01', 'CREATOR1' }), 'the ledger names no citizen id')
    end,
}

--------------------------------------------------------------------------
-- 2. place -> accept -> kill -> verify at the scene -> payout
--------------------------------------------------------------------------

local function stepKill()
    return {
        name = 'kill', needsTarget = true,
        run = function(ctx)
            W.at(src('hitman'), 100.0, 100.0, 30.0)
            W.at(src('target'), 101.0, 100.0, 30.0)
            Env.players[src('target')]._health = 120
            local ok = W.event('weaponDamageEvent', src('hitman'),
                { weaponDamage = 50, weaponType = 453432689, hitGlobalIds = { 1000 + src('target') } })
            truthy(ok, 'the engine\'s damage event was heard')
            Env.players[src('target')]._health = 0
            Env.players[src('target')].PlayerData.metadata.isdead = true
            Env.advance(1)
            local fired = W.net(src('target'), 'crimson-hitman:iDied', src('hitman'))
            truthy(fired, 'the target\'s client reported the death')
            Env.advance(2)
            truthy(W.s.death.getPending(ctx.id, cid('hitman')), 'the kill is the hitman\'s to verify')
        end,
        done = function(ctx)
            local c = W.contract(ctx.id)
            if c and CH.TERMINAL[c.state] then return true end
            return W.s.death.getPending(ctx.id, cid('hitman')) ~= nil
        end,
    }
end
F.stepKill = stepKill

local function stepVerify()
    return {
        name = 'verify',
        run = function(ctx)
            W.at(src('hitman'), 100.0, 100.0, 30.0)
            if not W.s.death.getPending(ctx.id, cid('hitman')) then
                -- The pending kill did not survive a restart (documented:
                -- server/completion/death.lua keeps it in memory): Verify
                -- kill says so, and the final check says what it came to.
                local r = W.phone(src('hitman'), 'verifyKill', { id = ctx.id })
                falsy(r and r.ok, 'nothing to verify')
                ctx.killLost = true
                return
            end
            local r = W.phone(src('hitman'), 'verifyKill', { id = ctx.id })
            truthy(r and r.ok, 'verified at the scene: ' .. tostring(r and r.err))
        end,
        done = function(ctx)
            local c = W.contract(ctx.id)
            return c ~= nil and (CH.TERMINAL[c.state] == true or (c.slots_claimed or 0) > 0)
        end,
    }
end
F.stepVerify = stepVerify

F.kill = {
    name = 'kill',
    setup = function(ctx)
        -- Staff choose kills from the panel, as a server that sells them does.
        W.opOk(src('staff'), 'setSetting', { key = 'Completion.Fulfilment', value = 'either' }, 'kills on')
        W.opOk(src('staff'), 'setSetting', { key = 'Completion.KillPhotos', value = false }, 'verify at scene')
        ctx.reward = 5000
        ctx.before = { creator = wealth('creator'), hitman = wealth('hitman') }
    end,
    steps = { stepPlace(), stepAccept(), stepKill(), stepVerify() },
    final = function(ctx)
        -- Revived and back on their feet, as the city carries on.
        Env.players[src('target')].PlayerData.metadata.isdead = false
        Env.players[src('target')]._health = 200
        F.settle()
        local c = W.contract(ctx.id)
        truthy(c, 'kept')
        if not ctx.killLost then
            eq(c.state, CH.STATE.COMPLETED, 'the verified kill completed the contract')
        end
        if c.state == CH.STATE.COMPLETED then
            eq(wealth('hitman') - ctx.before.hitman, ctx.reward, 'the hitman was paid')
            eq(ctx.before.creator - wealth('creator'), ctx.reward, 'the placer paid')
            F.audited(ctx, 'kill_verified_at_scene')
        else
            -- A kill lost to a crash: the contract is still live or ended
            -- without a payout, and nobody was charged for nothing.
            truthy(c.state == CH.STATE.ACCEPTED or c.state == CH.STATE.ACTIVE or CH.TERMINAL[c.state],
                'a state a player can read: ' .. tostring(c.state))
            eq(wealth('hitman') - ctx.before.hitman, 0, 'nothing paid for a kill not verified')
        end
    end,
}

--------------------------------------------------------------------------
-- 3. buyout: placed with a price, the target buys their way out
--------------------------------------------------------------------------

F.buyout = {
    name = 'buyout',
    setup = function(ctx)
        ctx.reward, ctx.bailout = 5000, 15000
        ctx.before = { creator = wealth('creator'), target = wealth('target'), hitman = wealth('hitman') }
    end,
    steps = {
        stepPlace(), stepAccept(),
        {
            name = 'buyout',
            run = function(ctx)
                -- Shown to the target once the alert's jitter has passed.
                Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
                W.tick(1)
                local onme = W.ok(src('target'), 'mine', {}, 'On me')
                truthy(onme, 'the target reads On me')
                local r = W.phone(src('target'), 'bailout', { id = ctx.id })
                truthy(r and r.ok, 'the buyout was taken: ' .. tostring(r and r.err))
            end,
            done = function(ctx)
                local c = W.contract(ctx.id)
                return c ~= nil and (c.bailout_queued_at ~= nil or CH.TERMINAL[c.state] == true)
            end,
        },
        {
            name = 'settle',
            run = function(ctx)
                W.tick(1, (Config.Bailout.DelaySeconds or 120) + 5)
                W.tick(3, 10)
            end,
            done = function(ctx)
                local c = W.contract(ctx.id)
                return c ~= nil and CH.TERMINAL[c.state] == true
            end,
        },
    },
    final = function(ctx)
        F.settle(10)
        local c = W.contract(ctx.id)
        truthy(c and CH.TERMINAL[c.state], 'the buyout ended the contract: ' .. tostring(c and c.state))
        eq(ctx.before.target - wealth('target'), ctx.bailout, 'the target paid the price')
        eq(wealth('hitman') - ctx.before.hitman, 0, 'the hitman is not paid for a bought-out contract')
        F.audited(ctx, 'bailout_paid')
        -- Never who placed it, to the target.
        local onme = W.ok(src('target'), 'mine', {}, 'On me')
        falsy(W.leaks(onme, { 'Vic Marlowe', 'CREATOR1', 'Rook Ash', 'HITMAN01' }),
            'the target is never told who placed or took it')
    end,
}

--------------------------------------------------------------------------
-- 4. intel purchase: staff turn the tip on, the hitman buys one
--------------------------------------------------------------------------

F.intel = {
    name = 'intel',
    setup = function(ctx)
        if not Config.Intel.LocationTip.Enabled then
            W.opOk(src('staff'), 'setSetting', { key = 'Intel.LocationTip.Enabled', value = true }, 'tip on')
        end
        ctx.before = { hitman = wealth('hitman'), target = wealth('target') }
    end,
    steps = {
        stepPlace(), stepAccept(),
        {
            name = 'buy',
            run = function(ctx)
                Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
                W.at(src('target'), 1200.0, -800.0, 30.0)
                W.at(src('hitman'), 0.0, 0.0, 30.0)
                ctx.cost = tonumber(Config.Intel.LocationTip.Cost) or 0
                local r = W.phone(src('hitman'), 'locationTip', { id = ctx.id,
                    shown = { cost = Config.Intel.LocationTip.Cost, account = Config.Intel.LocationTip.Account } })
                if Config.Intel.HoldFirst and Config.Intel.HoldFirst.Enabled and r and not r.ok then
                    ctx.refused = r.err
                    return
                end
                truthy(r and r.ok, 'the tip was sold: ' .. tostring(r and r.err))
                ctx.bought = true
            end,
            done = function(ctx)
                local tips = W.s.storage.readLocationTips(ctx.id) or {}
                if #tips > 0 then ctx.bought = true end
                return #tips > 0
            end,
        },
    },
    final = function(ctx)
        W.tick(2, 10)
        if ctx.refused then
            eq(wealth('hitman'), ctx.before.hitman, 'a tip refused charges nothing (' .. tostring(ctx.refused) .. ')')
            return
        end
        truthy(ctx.bought, 'the tip was bought')
        local spent = ctx.before.hitman - wealth('hitman')
        truthy(spent >= ctx.cost, ('the hitman paid the tip: %d of %d'):format(spent, ctx.cost))
        F.audited(ctx, 'location_tip_bought')
        -- The area goes to the hitman's map alone, never into a reply.
        local tips = W.ok(src('hitman'), 'locationTips', {}, 'the hitman\'s tips')
        truthy(tips ~= nil, 'the hitman\'s tips are put back on the map')
        local onme = W.ok(src('target'), 'mine', {}, 'On me')
        if not Config.TargetClasses.default.ShowOperativeNames then
            falsy(W.leaks(onme, { 'Rook Ash', 'HITMAN01' }), 'the target is not told who bought it')
        end
        falsy(W.leaks(onme, { 'HITMAN01' }), 'no citizen id of the buyer')
    end,
    delta = function(ctx) return ctx.bought and -(ctx.cost or 0) or 0 end,
}

--------------------------------------------------------------------------
-- 5. organisation payroll: set up, hire, fund, pay day
--------------------------------------------------------------------------

F.payroll = {
    name = 'payroll',
    setup = function(ctx)
        local staff = src('staff')
        if not Config.Organisation.Enabled then
            W.opOk(staff, 'setSetting', { key = 'Organisation.Enabled', value = true }, 'org on')
        end
        if not Config.Organisation.Payroll then
            W.opOk(staff, 'setSetting', { key = 'Organisation.Payroll', value = true }, 'payroll on')
        end
        W.opOk(staff, 'orgSetup', {}, 'org setup')
        W.opOk(staff, 'orgMemberHire', { subject = cid('boss'), grade = 3 }, 'hire the boss')
        if not (W.s.org.current().members or {})[cid('hitman2')] then
            W.opOk(staff, 'orgMemberHire', { subject = cid('hitman2'), grade = 0 }, 'hire a recruit')
        end
        ctx.salary = 500
    end,
    steps = {
        {
            name = 'salary',
            run = function(ctx)
                W.opOk(src('staff'), 'orgSalary', { grade = 0, amount = ctx.salary }, 'salary for the recruits')
            end,
            done = function(ctx)
                local org = W.s.org.current()
                local pay = org and org.settings and org.settings.payroll
                return pay ~= nil and pay.salaries ~= nil
                    and tonumber(pay.salaries['0'] or pay.salaries[0]) == ctx.salary
            end,
        },
        {
            name = 'fund',
            run = function(ctx)
                W.opOk(src('staff'), 'orgFundsMove', { direction = 'deposit', amount = 10000,
                    reason = 'seed money for the payroll', nonce = 'seed-1' }, 'staff deposit')
                ctx.deposited = 10000
            end,
            done = function(ctx)
                local ok, bal = pcall(function()
                    return require('server.org.funds').balance(W.s.org.current())
                end)
                if ok and (tonumber(bal) or 0) >= 10000 then ctx.deposited = 10000 return true end
                return false
            end,
        },
        {
            name = 'payday',
            run = function(ctx)
                ctx.recruitBefore = Env.players[src('hitman2')] and Env.players[src('hitman2')].PlayerData.money.bank
                    or W.everyone[cid('hitman2')].PlayerData.money.bank
                local days = tonumber(Config.Organisation.PayrollDays) or 7
                Env.advance(days * 86400 + 60)
                W.tick(2, 15)
            end,
            done = function()
                local org = W.s.org.current()
                return org ~= nil and org.settings.payroll.lastAt ~= nil
            end,
        },
    },
    final = function(ctx)
        W.tick(1, 15)
        local paid = W.everyone[cid('hitman2')].PlayerData.money.bank - (ctx.recruitBefore or 0)
        eq(paid, ctx.salary, 'the recruit was paid their salary on pay day')
        F.audited(ctx, 'org_payroll_run')
    end,
    -- The staff deposit puts money into the funds from nowhere.
    delta = function(ctx) return ctx.deposited or 0 end,
}

--------------------------------------------------------------------------
-- 6. body disposal: a verified kill pays once the body is dropped off
--------------------------------------------------------------------------

local SPAWN, DROP = { x = 200.0, y = 200.0, z = 30.0 }, { x = 500.0, y = 500.0, z = 30.0 }

local function fakeVehicles(s)
    local V = { vehicles = {}, seq = 0 }
    s.disposal.world = {
        spawn = function(model, at)
            V.seq = V.seq + 1
            V.vehicles[7000 + V.seq] = { x = at.x, y = at.y, z = at.z, model = model }
            return 7000 + V.seq
        end,
        exists = function(v) return V.vehicles[v] ~= nil end,
        coords = function(v)
            local c = V.vehicles[v]
            return c and { x = c.x, y = c.y, z = c.z } or nil
        end,
        remove = function(v) V.vehicles[v] = nil end,
        prepare = function(v, plate, holder) V.vehicles[v].plate, V.vehicles[v].keys = plate, holder return true end,
    }
    function V.move(p)
        for _, v in pairs(V.vehicles) do v.x, v.y, v.z = p.x, p.y, p.z end
    end
    W.vehicles = V
    return V
end
F.fakeVehicles = fakeVehicles

local function disposalAct(action, ctx)
    local ok, err = W.net(src('hitman'), 'crimson-hitman:disposalAct', { action = action, id = ctx.id })
    truthy(ok, 'the disposal net event raised: ' .. tostring(err))
end

F.disposal = {
    name = 'disposal',
    setup = function(ctx)
        local staff = src('staff')
        W.opOk(staff, 'setSetting', { key = 'Completion.Fulfilment', value = 'either' }, 'kills on')
        W.opOk(staff, 'setSetting', { key = 'Completion.KillPhotos', value = false }, 'verify at scene')
        if not Config.Disposal.Enabled then
            W.opOk(staff, 'setSetting', { key = 'Disposal.Enabled', value = true }, 'disposal on')
        end
        W.at(staff, SPAWN.x, SPAWN.y, SPAWN.z)
        W.opOk(staff, 'placeMyPosition', {}, 'where staff stand')
        W.opOk(staff, 'placeSet', { kind = 'disposal_vehicle', here = true, label = 'Hearse' }, 'vehicle spot')
        W.at(staff, DROP.x, DROP.y, DROP.z)
        W.opOk(staff, 'placeSet', { kind = 'disposal_drop', here = true, label = 'Crematorium' }, 'drop-off')
        fakeVehicles(W.s)
        ctx.reward = 5000
        ctx.before = { creator = wealth('creator'), hitman = wealth('hitman') }
    end,
    steps = {
        stepPlace(), stepAccept(), stepKill(), stepVerify(),
        {
            name = 'load',
            run = function(ctx)
                if not W.vehicles or W.s.disposal.world == nil then fakeVehicles(W.s) end
                W.tick(1, 2)
                W.vehicles.move({ x = 101.0, y = 100.0, z = 30.0 })
                W.at(src('hitman'), 101.0, 100.5, 30.0)
                disposalAct('load', ctx)
            end,
            done = function()
                local row = W.s.disposal.list()[1]
                return row == nil or row.stage == 'loaded'
            end,
        },
        {
            name = 'drop',
            run = function(ctx)
                if not W.vehicles or W.s.disposal.world == nil then fakeVehicles(W.s) end
                W.vehicles.move(DROP)
                W.at(src('hitman'), DROP.x, DROP.y + 1, DROP.z)
                disposalAct('drop', ctx)
            end,
            done = function() return W.s.disposal.list()[1] == nil end,
        },
    },
    final = function(ctx)
        Env.players[src('target')].PlayerData.metadata.isdead = false
        F.settle()
        local c = W.contract(ctx.id)
        if c.state ~= CH.STATE.COMPLETED and ctx.killLost then
            -- A restart between the kill and its proof loses the kill (kept in
            -- memory only, server/completion/death.lua): the contract runs on.
            eq(wealth('hitman') - ctx.before.hitman, 0, 'nothing paid for a kill the restart lost')
            return
        end
        eq(c.state, CH.STATE.COMPLETED, 'the kill completed the contract')
        eq(wealth('hitman') - ctx.before.hitman, ctx.reward, 'paid once the body is dropped off (or on timeout)')
        F.audited(ctx, 'disposal_started')
    end,
}

--------------------------------------------------------------------------
-- 7. staff: freeze, reassign, change the reward
--------------------------------------------------------------------------

F.staff = {
    name = 'staff',
    setup = function(ctx)
        ctx.reward = 5000
        ctx.before = { creator = wealth('creator'), hitman = wealth('hitman'), hitman2 = wealth('hitman2') }
    end,
    steps = {
        stepPlace(), stepAccept(),
        {
            name = 'freeze',
            run = function(ctx)
                -- Taken again after a crash, the freeze may already stand.
                local r = W.op(src('staff'), 'freeze', { subject = cid('hitman'),
                    reason = 'looking into a report on this contract' })
                truthy(r and (r.ok or r.err == 'already_frozen'), 'frozen: ' .. tostring(r and r.err))
                local r = W.phone(src('hitman'), 'abandon', { id = ctx.id })
                falsy(r and r.ok, 'a frozen contract cannot be put down')
                W.opOk(src('staff'), 'unfreeze', { subject = cid('hitman'), reason = 'report closed' }, 'unfreeze')
                ctx.unfrozen = true
            end,
            done = function(ctx) return ctx.unfrozen == true end,
        },
        {
            name = 'reassign',
            run = function(ctx)
                -- Rumours on: the new hitman hears it from the broker first,
                -- as staff tell them to: a reassign passes every rule their
                -- own Accept would (server/staff_reassign.lua).
                if Config.Intel.Rumours and Config.Intel.Rumours.Enabled then
                    W.at(src('hitman2'), W.SCENE.x, W.SCENE.y, W.SCENE.z)
                    W.ok(src('hitman2'), 'rumourBrief', { id = ctx.id }, 'the broker\'s brief')
                end
                local ref = W.ref(cid('hitman2'))
                local preview = W.opOk(src('staff'), 'reassignPreview', { id = ctx.id, ref = ref }, 'preview')
                truthy(preview and not preview.refused, 'a preview: ' .. tostring(preview and preview.refused))
                W.opOk(src('staff'), 'reassignHitman', { id = ctx.id, ref = W.ref(cid('hitman2')),
                    identity = 'named', reason = 'the first hitman left the city for good' }, 'reassign')
            end,
            done = function(ctx)
                local h = hitmanRow(ctx.id, 'hitman2')
                return h ~= nil and h.state == 'active'
            end,
        },
        {
            name = 'reward',
            run = function(ctx)
                local preview = W.opOk(src('staff'), 'rewardPreview', { id = ctx.id, by = 1000 }, 'preview')
                truthy(preview, 'a preview')
                W.opOk(src('staff'), 'rewardChange', { id = ctx.id, by = 1000,
                    reason = 'agreed with the placer in a ticket' }, 'change')
                ctx.reward = ctx.reward + 1000
            end,
            done = function(ctx)
                local held = 0
                for _, l in ipairs(W.s.storage.readEscrow(ctx.id) or {}) do
                    if CH.MONEY_SOURCES[l.source] and l.portion == CH.PORTION.BASELINE
                        and l.state ~= CH.ESCROW_STATE.SETTLED then
                        held = held + (tonumber(l.amount) or 0)
                    end
                end
                if held >= 6000 then ctx.reward = 6000 return true end
                return false
            end,
        },
        {
            name = 'handover', needsTarget = true,
            run = function(ctx)
                W.allAt()
                if Config.Kidnap.RequireCoercion then
                    Env.players[src('target')].PlayerData.metadata.ishandcuffed = true
                end
                local r = W.phone(src('hitman2'), 'armKidnap', { id = ctx.id })
                truthy(r and r.ok, 'the new hitman arms the handover: ' .. tostring(r and r.err))
                local passes = math.ceil((Config.Kidnap.CountdownSeconds + 5) * 1000 / Config.Kidnap.TickMs)
                for _ = 1, passes do W.s.kidnap.tick(Config.Kidnap.TickMs) end
                if Config.Kidnap.PlacerConfirms then
                    W.phone(src('creator'), 'confirmHandover', { id = ctx.id })
                    for _ = 1, 5 do W.s.kidnap.tick(Config.Kidnap.TickMs) end
                end
            end,
            done = function(ctx)
                local c = W.contract(ctx.id)
                return c ~= nil and CH.TERMINAL[c.state] == true
            end,
        },
    },
    final = function(ctx)
        F.settle()
        local c = W.contract(ctx.id)
        eq(c.state, CH.STATE.COMPLETED, 'the new hitman completed it')
        eq(wealth('hitman2') - ctx.before.hitman2, ctx.reward, 'the new hitman was paid the changed reward')
        eq(wealth('hitman') - ctx.before.hitman, 0, 'the old hitman was not')
        F.audited(ctx, 'staff_reassign_hitman')
        F.audited(ctx, 'staff_reward_changed')
        F.audited(ctx, 'freeze_player')
    end,
    -- The raise is added by staff (from = 'staff', the panel's default).
    delta = function(ctx) return (ctx.reward or 5000) - 5000 end,
}

--- With the organisation on (all-on): staff set it up and hire both hitmen
--- into the role that may take contracts, as a server whose contracts only
--- members take does.
function F.joinOrg()
    local staff = src('staff')
    W.opOk(staff, 'orgSetup', {}, 'org setup')
    W.opOk(staff, 'orgMemberHire', { subject = cid('hitman'), grade = 0 }, 'hire the hitman')
    W.opOk(staff, 'orgMemberHire', { subject = cid('hitman2'), grade = 0 }, 'hire the second hitman')
    W.opOk(staff, 'orgRolePowers', { grade = 0, power = 'TAKE', on = true }, 'members take contracts')
    for _, who in ipairs({ 'hitman', 'hitman2' }) do
        local p = Env.players[src(who)]
        local org = W.s.org.current()
        if p and org then p.PlayerData.job = { name = org.job, type = 'none', onduty = true, grade = { level = 0 } } end
    end
end

F.ORDER = { 'contract', 'kill', 'buyout', 'intel', 'payroll', 'disposal', 'staff' }

--------------------------------------------------------------------------
-- Running a flow
--------------------------------------------------------------------------

--- Run one flow on a fresh server: inject `fault` ('restart' | 'crash' |
--- 'drop') after step `at` (0 = before the first), dropping `who`.
---@return table ctx
--- Run one flow on a fresh server.
---
--- A fault at a step boundary: `fault` ('restart' | 'crash' | 'drop') after
--- step `at` (0 = before the first), dropping `who`.
---
--- Or, with `opts.await = { step, k, phase }`, inside that step at its k-th
--- database await (mysql): 'crash' kills the process there (the request never
--- resumes), the server starts again, and the step is taken again only if
--- it did not land; 'drop' takes `who` out of the city there, the request
--- carries on, and they come back after it.
---@return table ctx
function F.run(flow, mode, profile, fault, at, who, opts)
    opts = opts or {}
    W.boot(mode, profile)
    W.cast(W.s)
    W.targetBackAt = nil
    local ctx = { flow = flow.name, mode = mode, profile = profile }
    if Config.Organisation.Enabled then F.joinOrg() end
    flow.setup(ctx)
    W.tick(1)
    local start = W.world()
    local aw = opts.await
    for i, step in ipairs(flow.steps) do
        if fault and not aw and at == i - 1 then F.inject(fault, who, step) end
        if step.needsTarget and W.targetBackAt then
            local floor = (tonumber(Config.Immunity.MinTargetSessionMinutes) or 0) * 60 + 30
            local waited = os.time() - W.targetBackAt
            if waited < floor then W.tick(1, floor - waited) end
            W.targetBackAt = nil
        end
        if aw and aw.step == i then
            local cut
            if fault == 'crash' then
                local rec = W.atAwait(aw.k, aw.phase, function() step.run(ctx) end,
                    function() cut = true end, true)
                ctx.awaitRec = rec
                if cut then
                    W.restart(W.s, false)
                    W.tick(1, 5)
                    if not (step.done and step.done(ctx)) then step.run(ctx) end
                end
            else
                local ok, err
                local rec = W.atAwait(aw.k, aw.phase, function() ok, err = pcall(step.run, ctx) end,
                    function() cut = true W.drop(src(who or 'target')) end)
                ctx.awaitRec = rec
                if cut then
                    W.tick(1, 30)
                    W.rejoin(src(who or 'target'))
                    if who == 'target' then W.targetBackAt = os.time() end
                end
                if not (step.done and step.done(ctx)) then
                    -- Refused, or undone, because somebody left mid-request
                    -- (a handover needs its placer there): tried again once
                    -- they are back (and past the new-session floor).
                    if W.targetBackAt then
                        W.tick(1, (tonumber(Config.Immunity.MinTargetSessionMinutes) or 0) * 60 + 30)
                        W.targetBackAt = nil
                    end
                    -- And a handover that failed waits its re-arm cooldown.
                    W.tick(1, (tonumber(Config.Kidnap.RearmCooldownSeconds) or 0) + 1)
                    step.run(ctx)
                end
            end
        elseif not (step.done and step.done(ctx)) then
            step.run(ctx)
        end
    end
    if fault and not aw and at == #flow.steps then F.inject(fault, who) end
    if fault == 'crash' then ctx.crashed = true end
    W.tick(3, 60)
    F.staffClearsStuck()
    flow.final(ctx)
    W.rejoinAll()
    W.tick(2, 10)
    local allowed = flow.delta and flow.delta(ctx) or 0
    eq(W.world() - start, allowed, ('%s on %s/%s: money not conserved'):format(flow.name, mode, profile))
    F.noneStuck()
    return ctx
end

--- How many database awaits each step of a flow makes, on mysql.
function F.depths(flow, profile)
    W.boot('mysql', profile)
    W.cast(W.s)
    local ctx = { flow = flow.name }
    if Config.Organisation.Enabled then F.joinOrg() end
    flow.setup(ctx)
    W.tick(1)
    local out = {}
    for i, step in ipairs(flow.steps) do
        local rec = W.atAwait(nil, 'pre', function() step.run(ctx) end)
        out[i] = rec.depth
    end
    return out
end

function W.rejoinAll()
    for s in pairs(W.dropped or {}) do W.rejoin(s) end
end

--- Restart (graceful), crash (no stop), or a player leaving and coming back
--- a minute later.
function F.inject(fault, who, nextStep)
    if fault == 'restart' then
        W.restart(W.s, true)
    elseif fault == 'crash' then
        W.restart(W.s, false)
    elseif fault == 'drop' then
        W.drop(src(who or 'hitman'))
        W.tick(1, 30)
        W.rejoin(src(who or 'hitman'))
        -- A target back in the city is off limits for the new-session floor
        -- (Config.Immunity.MinTargetSessionMinutes): the next step that
        -- needs them as a target waits it out, as the hitman would.
        if who == 'target' then W.targetBackAt = os.time() end
    end
    W.tick(1, 5)
end

--- Nothing left half done once the ticks have run.
function F.noneStuck()
    for _, l in ipairs(W.s.storage.unsettledEscrow() or {}) do
        if l.state == CH.ESCROW_STATE.RELEASING then error('escrow line ' .. tostring(l.id) .. ' left releasing', 2) end
    end
    for _, c in ipairs(W.s.storage.allContracts() or {}) do
        if c.state == CH.STATE.COMPLETING then error('contract ' .. tostring(c.id) .. ' left completing', 2) end
        if CH.TERMINAL[c.state] then
            for _, l in ipairs(W.s.storage.readEscrow(c.id) or {}) do
                if l.state ~= CH.ESCROW_STATE.SETTLED and not l.owed_to and CH.MONEY_SOURCES[l.source] then
                    error(('escrow %s (%s %s) stranded on %s contract'):format(tostring(l.id),
                        tostring(l.source), tostring(l.amount), tostring(c.state)), 2)
                end
            end
        end
    end
end

return F
