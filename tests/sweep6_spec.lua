--- Sweep 6 (at 4776ef9): optional features switched mid-contract, paid
--- windows held through holds, the read cost of a freeze, and changing
--- everything before a hitman accepts. Each test here failed on the code
--- before its fix. The UI halves (the Edit sheet's new fields, Cancel and
--- place again, the guard's Protection tab, the buyout's price echo) are in
--- tests/ui/run.js; the statement counts of J-1 and J-2 on mysql are pinned
--- in tests/loops_spec.lua and tests/handlers_spec.lua.
---
---   FE-1  go dark was offered, and charged, after tips were switched off.
---   FE-2  contract decay switched off and on again counted the off stretch
---         (taken time included) as waiting, and charged at once.
---   FE-3  a paid go-dark window and the tips' show and wait ran on the wall
---         clock through a freeze, the restart hold and the restart itself.
---   FE-4  protection switched off mid-job: the target's Move pin refused,
---         and the guard lost the Protection tab.
---   BURNER decayOff, a placer's contract action, did not need the burner.
---   J-1   with anybody frozen, the expiry pass read every live roster again.
---   J-2   the panel's contract list read each row's roster twice.
---   J-3   before acceptance the placer could not change the buyout price,
---         how it is completed, or whether it is anonymous (owner rule 17).

local IMP = require('tests.harness.improvements')

local TARGET_AT = { x = 1200.0, y = -800.0, z = 30.0 }
local TIP = { cost = 25000, account = 'bank' }
local DARK = { cost = 50000, account = 'bank' }

local function deepCopy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = deepCopy(v) end
    return out
end

--- Config.Improvements, Config.Roleplay and the blocks these tests switch
--- put back, whichever way the test ends.
local function it(name, fn)
    IMP.it(name, function(...)
        local saved = {
            tip = deepCopy(Config.Intel.LocationTip), anon = deepCopy(Config.Anonymity),
            bailout = deepCopy(Config.Bailout), completion = deepCopy(Config.Completion),
            informants = Config.Intel.Enabled, white = deepCopy(Config.TargetClasses.whitelisted),
            paused = Config.Holds.AppPaused,
        }
        local out = table.pack(pcall(fn, ...))
        Config.Intel.LocationTip, Config.Anonymity, Config.Bailout = saved.tip, saved.anon, saved.bailout
        Config.Completion, Config.Intel.Enabled = saved.completion, saved.informants
        Config.TargetClasses.whitelisted, Config.Holds.AppPaused = saved.white, saved.paused
        if not out[1] then error(out[2], 0) end
    end)
end

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
                  reward = { baseline = { cash = 10000 } } }
    for k, v in pairs(extra or {}) do req[k] = v end
    local c, err = s.contracts.create(f.creator, req)
    truthy(c, 'placed: ' .. tostring(err))
    return c
end

--- A contract the hitman (source 3) holds, its target (source 2) at
--- TARGET_AT, everybody able to pay.
local function taken()
    local s = newStack()
    Config.Notifications.ParanoidAlertJitter = { min = 0, max = 0 }
    local f = fixture(s)
    local c = place(s, f, { reward = { baseline = { cash = 5000 } } })
    Env.players[1].PlayerData.money.bank = 200000
    Env.players[2].PlayerData.money.bank = 200000
    Env.players[3].PlayerData.money.bank = 200000
    truthy(s.contracts.accept(f.hitman, c.id, false), 'taken')
    Env.players[2]._coords = { x = TARGET_AT.x, y = TARGET_AT.y, z = TARGET_AT.z }
    Env.advance(1)
    return s, f, c
end

--- And a tip bought on it, which the target was told of; go dark on sale.
local function tipped()
    local s, f, c = taken()
    Config.Intel.GoDark.Enabled = true
    Config.Intel.GoDark.Cost = 50000
    Config.Intel.GoDark.Minutes = 30
    local r = call('locationTip', 3, { id = c.id, shown = TIP })
    truthy(r and r.ok, 'tipped: ' .. tostring(r and r.err))
    return s, f, c
end

local function targetCard(s, c)
    return s.projection.contract(s.storage.readContract(c.id), 'TARGET01')
end

--------------------------------------------------------------------------
-- FE-1: go dark with tips switched off
--------------------------------------------------------------------------

describe('sweep 6 FE-1: go dark is sold only while tips are', function()
    it('is not offered, nor charged, once the master switch turns tips off', function()
        local s, _, c = tipped()
        truthy(targetCard(s, c).goDark, 'offered while tips are on')
        truthy(s.settings.set('Intel.Enabled', false, 'ADMIN001', 'ADMIN001'))
        falsy(targetCard(s, c).goDark, 'offered with tips switched off')
        local before = bank(2)
        local r = call('goDark', 2, { id = c.id, shown = DARK })
        falsy(r and r.ok, 'sold with tips switched off')
        eq(r and r.err, CH.ERR.FEATURE_OFF)
        eq(bank(2), before, 'charged for hiding from tips nobody can buy')
    end)

    it('nor once the tip itself is switched off', function()
        local s, _, c = tipped()
        Config.Intel.LocationTip.Enabled = false
        local before = bank(2)
        local r = call('goDark', 2, { id = c.id, shown = DARK })
        eq(r and r.err, CH.ERR.FEATURE_OFF)
        eq(bank(2), before)
    end)

    it('nor on a whitelisted-job target where only their own tip switch is off', function()
        local s, _, c = tipped()
        s.storage.writeContract((function()
            local row = s.storage.readContract(c.id)
            row.target_protected = true
            return row
        end)())
        Config.TargetClasses.whitelisted.LocationTip = false
        falsy(targetCard(s, c).goDark and targetCard(s, c).goDark.cost, 'offered')
        local before = bank(2)
        eq(call('goDark', 2, { id = c.id, shown = DARK }).err, CH.ERR.FEATURE_OFF)
        eq(bank(2), before)
    end)

    it('still shows a window already paid for to its end, with go dark itself switched off', function()
        local s, _, c = tipped()
        truthy(call('goDark', 2, { id = c.id, shown = DARK }).ok)
        Config.Intel.GoDark.Enabled = false
        local card = targetCard(s, c)
        truthy(card.goDark and card.goDark.untilAt, 'the paid window dropped off the card')
        eq(card.goDark.cost, nil, 'and no purchase offered')
    end)
end)

--------------------------------------------------------------------------
-- FE-2: decay switched off and on
--------------------------------------------------------------------------

describe('sweep 6 FE-2: decay off and on again counts only waiting time', function()
    local function decaying()
        local s = newStack()
        local f = fixture(s, { creatorCash = 500000, creatorBank = 500000 })
        Config.Notifications.ParanoidAlert = false
        Config.Improvements.ContractDecay.Enabled = true
        Config.Improvements.ContractDecay.Mode = 'rise'
        Config.Improvements.ContractDecay.Hours = 1
        local c = place(s, f)
        s.impBoard.tick()
        Env.advance(50 * 60); s.impBoard.tick()             -- 50 minutes untaken
        return s, f, c
    end

    it('switched off, taken for 3 h, back on after the walk-away: no step at once', function()
        local s, f, c = decaying()
        local before = bank(1)
        Config.Improvements.ContractDecay.Enabled = false
        s.impBoard.tick()
        truthy(s.contracts.accept(f.hitman, c.id, false), 'taken while decay is off')
        Env.advance(3 * 3600); s.impBoard.tick()
        truthy(s.contracts.abandon(f.hitman, c.id), 'walked away')
        Env.advance(60)
        Config.Improvements.ContractDecay.Enabled = true
        s.impBoard.tick()
        eq(before - bank(1), 0, 'the placer was charged for three hours of nobody waiting')
        -- The 50 minutes before it was switched off still count: the step
        -- falls due 10 minutes on, not an hour.
        Env.advance(9 * 60); s.impBoard.tick()
        eq(before - bank(1), 0, 'stepped before its hour of waiting')
        Env.advance(2 * 60); s.impBoard.tick()
        truthy(before - bank(1) > 0, 'the waiting before the switch was lost')
    end)

    it('switched back on while taken: waits for the walk-away, then counts on', function()
        local s, f, c = decaying()
        local before = bank(1)
        Config.Improvements.ContractDecay.Enabled = false
        s.impBoard.tick()
        truthy(s.contracts.accept(f.hitman, c.id, false), 'taken while decay is off')
        Env.advance(3600); s.impBoard.tick()
        Config.Improvements.ContractDecay.Enabled = true
        s.impBoard.tick()
        Env.advance(3600); s.impBoard.tick()                 -- still taken
        truthy(s.contracts.abandon(f.hitman, c.id), 'walked away')
        Env.advance(60); s.impBoard.tick()
        eq(before - bank(1), 0, 'charged for time it was taken')
        Env.advance(10 * 60); s.impBoard.tick()
        truthy(before - bank(1) > 0, 'the 50 minutes before the switch were lost')
    end)

    it('keeps the switch-off across a restart of the module', function()
        local s, f, c = decaying()
        local before = bank(1)
        Config.Improvements.ContractDecay.Enabled = false
        s.impBoard.tick()
        Env.advance(4 * 3600)
        s.impBoard.init({ storage = s.storage, identity = s.identity, notify = s.notify, audit = s.audit,
            escrow = s.escrow, contracts = s.contracts, amendments = s.amendments,
            projection = s.projection, progression = s.progression, rpConsequences = s.rpConsequences })
        Config.Improvements.ContractDecay.Enabled = true
        s.impBoard.tick()
        eq(before - bank(1), 0, 'four hours switched off charged at once after a restart')
        truthy(f)
    end)
end)

--------------------------------------------------------------------------
-- FE-3: paid windows through holds
--------------------------------------------------------------------------

describe('sweep 6 FE-3: a paid window stands still while its contract is held', function()
    it('go dark: a 40-minute freeze gives back the whole 40 minutes', function()
        local s, _, c = tipped()
        truthy(call('goDark', 2, { id = c.id, shown = DARK }).ok)
        local untilAt = s.intelRules.darkUntil('TARGET01')
        truthy(untilAt)
        truthy(s.holds.freeze('ADMIN001', 'TARGET01', 'probe'))
        Env.advance(35 * 60)
        truthy(s.intelRules.targetDark('TARGET01'), 'the window ran out while on hold by staff')
        Env.advance(5 * 60)
        truthy(s.holds.unfreeze('ADMIN001', 'TARGET01', 'done'))
        eq(s.intelRules.darkUntil('TARGET01'), untilAt + 40 * 60, 'the hold not given back')
        -- And pruned only once it really has run out.
        Env.advance(29 * 60)
        eq(s.intelRules.prune(), 0)
        truthy(s.intelRules.targetDark('TARGET01'))
    end)

    it('the tip: its showing and its wait are given back after the hitman is frozen', function()
        local s, _, c = taken()
        Config.Intel.LocationTip.CooldownMinutes = 30
        Config.Intel.LocationTip.ShowMinutes = 10
        Config.Intel.LocationTip.MaxPurchasesPerContract = 5
        truthy(call('locationTip', 3, { id = c.id, shown = TIP }).ok, 'tipped')
        Env.advance(5 * 60)
        truthy(s.holds.freeze('ADMIN001', 'HITMAN01', 'probe'))
        Env.advance(40 * 60)
        truthy(s.holds.unfreeze('ADMIN001', 'HITMAN01', 'done'))
        local card = s.locationTip.cardFor(s.storage.readContract(c.id), 'HITMAN01')
        eq(card.secondsLeft, 5 * 60, 'the showing ran out while on hold')
        local r = call('locationTip', 3, { id = c.id, shown = TIP })
        falsy(r and r.ok, 'a frozen hitman came back able to buy at once')
        eq(r and r.err, CH.ERR.TIP_COOLDOWN)
        eq(r.data.retryAfter, 25 * 60)
    end)

    it('the tip\'s wait stands still through the restart hold', function()
        local s, _, c = taken()
        Config.Intel.LocationTip.CooldownMinutes = 30
        Config.Intel.LocationTip.MaxPurchasesPerContract = 5
        truthy(call('locationTip', 3, { id = c.id, shown = TIP }).ok, 'tipped')
        Env.advance(10 * 60)
        truthy(s.holds.scheduledRestart({ secondsRemaining = 1800 }))
        Env.advance(25 * 60)
        local r = call('locationTip', 3, { id = c.id, shown = TIP })
        eq(r and r.err, CH.ERR.TIP_COOLDOWN, 'bought inside the hold on the wall clock')
        truthy(s.holds.releaseRestart('skipped'))
        r = call('locationTip', 3, { id = c.id, shown = TIP })
        eq(r and r.err, CH.ERR.TIP_COOLDOWN)
        eq(r.data.retryAfter, 20 * 60)
    end)

    it('go dark: the restart hold and the restart itself are given back at the start', function()
        local s, _, c = tipped()
        truthy(call('goDark', 2, { id = c.id, shown = DARK }).ok)
        local untilAt = s.intelRules.darkUntil('TARGET01')
        Env.advance(10 * 60)
        truthy(s.holds.scheduledRestart({ secondsRemaining = 1800 }))
        Env.advance(45 * 60)                                  -- the hold, the restart, the boot
        -- The start, in main.lua's order: the intel rules loaded, not started, when
        -- the freeze module gives the restart's time back.
        package.loaded['server.intel.rules'] = nil
        local fresh = CrimsonBoot.require('server.intel.rules')
        s.locationTip.init({ storage = s.storage, identity = s.identity, audit = s.audit,
            notify = s.notify, contracts = s.contracts, review = s.review })
        s.holds.init({ storage = s.storage, audit = s.audit, notify = s.notify, kidnap = s.kidnap,
            contracts = s.contracts, death = s.death })
        fresh.init({ storage = s.storage, audit = s.audit, notify = s.notify, contracts = s.contracts,
            locationTip = s.locationTip, informant = s.informant, projection = s.projection,
            bailout = s.bailout })
        eq(fresh.darkUntil('TARGET01'), untilAt + 45 * 60, 'the restart took the paid window')
    end)
end)

--------------------------------------------------------------------------
-- FE-4: protection switched off mid-job
--------------------------------------------------------------------------

describe('sweep 6 FE-4: protection switched off while a guard is on the job', function()
    local function guarded()
        local s, f, c = taken()
        Config.Roleplay.Protection.Enabled = true
        Env.addPlayer({ source = 4, citizenid = 'GUARD001', license = 'license:ddd', cash = 0, bank = 0,
            firstname = 'Gus', lastname = 'Ward' })
        local r = call('protectionPost', 2, { id = c.id, amount = Config.Roleplay.Protection.MinReward,
            account = Config.Roleplay.Protection.Account })
        truthy(r and r.ok, 'posted: ' .. tostring(r and r.err))
        local job = s.rpProtection.all()[1]
        r = call('protectionAccept', 4, { job = job.id, reward = job.amount })
        truthy(r and r.ok, 'guarded: ' .. tostring(r and r.err))
        truthy(s.settings.set('Roleplay.Protection.Enabled', false, 'ADMIN001', 'ADMIN001'))
        return s, f, c, job
    end

    it('the target can still move the meeting pin of their live job', function()
        local _, _, _, job = guarded()
        local r = call('protectionPin', 2, { job = job.id })
        truthy(r and r.ok, 'refused: ' .. tostring(r and r.err))
    end)

    it('but cannot use the pin of a job that is not theirs, and nothing new is offered', function()
        local _, _, c, job = guarded()
        eq(call('protectionPin', 3, { job = job.id }).err, CH.ERR.FEATURE_OFF)
        truthy(c)
    end)

    it('the guard is still sent the Protection tab, and nobody else is', function()
        guarded()
        local listing = call('list', 4, {})
        eq(listing.data.settings.protection, true, 'the guard lost the tab their job is on')
        local other = call('list', 3, {})
        eq(other.data.settings.protection, nil, 'drawn for somebody with no job')
    end)
end)

--------------------------------------------------------------------------
-- The burner phone gate
--------------------------------------------------------------------------

describe('sweep 6: turning decay off needs the burner phone, as every contract action does', function()
    it('lists decayOff among the burner\'s actions', function()
        local s = newStack()
        truthy(s.rpBurner.ACTIONS.decayOff, 'a placer\'s contract action without the burner')
    end)
end)

--------------------------------------------------------------------------
-- J-1 / J-2: what a freeze costs to read
--------------------------------------------------------------------------

--- Store calls by name while `fn` runs: the calls made into the store,
--- not the ones a store function makes of its own (the memory backend's
--- readHitmenMany is readHitmen for each).
local function counted(s, fn)
    local counts, originals, depth = {}, {}, 0
    for name, f in pairs(s.storage) do
        if type(f) == 'function' then
            originals[name] = f
            s.storage[name] = function(...)
                if depth == 0 then counts[name] = (counts[name] or 0) + 1 end
                depth = depth + 1
                local out = table.pack(pcall(f, ...))
                depth = depth - 1
                if not out[1] then error(out[2], 0) end
                return table.unpack(out, 2, out.n)
            end
        end
    end
    local ok, err = pcall(fn)
    for name, f in pairs(originals) do s.storage[name] = f end
    if not ok then error(err, 0) end
    return counts
end

describe('sweep 6 J-1 / J-2: a freeze on anybody reads no roster twice', function()
    --- The resource as main.lua starts it (the expiry pass is main.lua's).
    local function booted()
        for name in pairs(package.loaded) do
            if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
                package.loaded[name] = nil
            end
        end
        Env.reset()
        Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
        Natives.resetResourceStates()
        resetConfig()
        Config.Database.Mode = 'memory'
        local main = require('server.main')
        local s = main.start()
        Config.Limits.MaxActiveContractsPerCreator = 100
        Config.Limits.MaxActiveContractsPerTarget = 100
        Config.Limits.SameCreatorSameTargetCooldownSeconds = 0
        Config.Immunity.MinTargetSessionMinutes = 0
        Config.Immunity.MinTargetPlaytimeHours = 0
        Env.addPlayer({ source = 1, citizenid = 'CREATOR1', license = 'license:aaa', cash = 900000, bank = 900000 })
        Env.addPlayer({ source = 3, citizenid = 'HITMAN01', license = 'license:ccc', cash = 900000, bank = 900000 })
        Env.addPlayer({ source = 9, citizenid = 'BYSTAND1', license = 'license:zzz' })
        local creator, hitman = s.identity.resolve(1), s.identity.resolve(3)
        local made = {}
        for i = 1, 6 do
            Env.addPlayer({ source = 20 + i, citizenid = ('TGTX%04d'):format(i),
                license = ('license:x%d'):format(i), cash = 100, bank = 100 })
            local c = s.contracts.create(creator, { targetCid = ('TGTX%04d'):format(i), reason = 'x',
                reward = { baseline = { cash = 1000 } } })
            truthy(c, 'placed')
            if i % 2 == 0 then truthy(s.contracts.accept(hitman, c.id, false), 'taken') end
            made[#made + 1] = c.id
        end
        main.tick()
        return main, s, made
    end

    it('J-1: the expiry pass reads no roster with an unrelated player frozen', function()
        local main, s = booted()
        truthy(s.holds.freeze('ADMIN001', 'BYSTAND1', 'unrelated'))
        Env.advance(10)
        main.markContractsChanged()
        main.markPresenceChanged()
        main.expire()                                         -- the snapshot read again after the write
        main.markPresenceChanged()
        local counts = counted(s, function() main.expire() end)
        eq(counts.readHitmen or 0, 0, ('the pass read %d rosters one at a time'):format(counts.readHitmen or 0))
    end)

    it('J-1: and the clock check an unfreeze asks reads the roster once', function()
        local _, s, made = booted()
        truthy(s.holds.freeze('ADMIN001', 'BYSTAND1', 'unrelated'))
        local counts = counted(s, function() s.holds.clockMayRun(s.storage.readContract(made[2])) end)
        eq(counts.readHitmen or 0, 1, ('read the roster %d times'):format(counts.readHitmen or 0))
    end)

    it('J-2: the panel\'s contract list reads the page\'s rosters in one go', function()
        local _, s = booted()
        truthy(s.holds.freeze('ADMIN001', 'BYSTAND1', 'unrelated'))
        Env.aces[1] = { ['crimson.admin'] = true }
        local reply
        local counts = counted(s, function()
            reply = s.panel.handle(1, { op = 'contracts', data = { page = 1 } })
        end)
        truthy(reply and reply.ok, 'answered: ' .. tostring(reply and reply.err))
        eq(counts.readHitmen or 0, 0, ('read a roster a row (%d)'):format(counts.readHitmen or 0))
        truthy((counts.readHitmenMany or 0) <= 1)
    end)
end)

--------------------------------------------------------------------------
-- J-3: everything the placer set, before anybody accepts
--------------------------------------------------------------------------

describe('sweep 6 J-3: the placer changes anything before a hitman accepts', function()
    local function untaken(extra)
        local s = newStack()
        Config.Notifications.ParanoidAlertJitter = { min = 0, max = 0 }
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 200000
        local c = place(s, f, extra)
        return s, f, c
    end

    it('the buyout price, clamped as placing clamps it, and audited', function()
        local s, f, c = untaken({ bailoutAmount = 15000 })
        eq(s.storage.readContract(c.id).bailout_amount, 15000)
        truthy(s.contracts.revise(f.creator, c.id, { bailoutAmount = 25000 }))
        eq(s.storage.readContract(c.id).bailout_amount, 25000)
        -- Past the most (3 times the reward here): clamped, not refused.
        truthy(s.contracts.revise(f.creator, c.id, { bailoutAmount = 999999 }))
        eq(s.storage.readContract(c.id).bailout_amount, 30000)
        -- Under the least: brought up to it.
        truthy(s.contracts.revise(f.creator, c.id, { bailoutAmount = 1 }))
        eq(s.storage.readContract(c.id).bailout_amount, 10000)
        -- And 0 for none.
        truthy(s.contracts.revise(f.creator, c.id, { bailoutAmount = 0 }))
        eq(s.storage.readContract(c.id).bailout_amount, 0)
        s.audit.flush()
        local audited = 0
        for _, row in ipairs(s.storage.readAudit() or {}) do
            if row.action == 'bailout_revised' and row.contract_id == c.id then audited = audited + 1 end
        end
        eq(audited, 4, 'each change on the record')
    end)

    it('the buyout through the page\'s request', function()
        local s, _, c = untaken()
        local r = call('revise', 1, { id = c.id, bailoutAmount = 20000 })
        truthy(r and r.ok, tostring(r and r.err))
        eq(s.storage.readContract(c.id).bailout_amount, 20000)
        eq(call('revise', 1, { id = c.id, bailoutAmount = 0 / 0 }).err, CH.ERR.INVALID_INPUT)
        eq(call('revise', 1, { id = c.id, bailoutAmount = math.huge }).err, CH.ERR.INVALID_INPUT)
        eq(call('revise', 1, { id = c.id, bailoutAmount = -5 }).err, CH.ERR.INVALID_INPUT)
        eq(s.storage.readContract(c.id).bailout_amount, 20000)
    end)

    it('a buyout needs cash or bank in it, as placing says (BUYOUT_NEEDS_CLEAN)', function()
        local s, f, c = untaken({ reward = { baseline = { dirty = 10000 } } })
        local ok, err = s.contracts.revise(f.creator, c.id, { bailoutAmount = 20000 })
        falsy(ok)
        eq(err, CH.ERR.BUYOUT_NEEDS_CLEAN)
        eq(s.storage.readContract(c.id).bailout_amount, 0)
    end)

    it('none where the server runs no buyouts', function()
        local s, f, c = untaken()
        Config.Bailout.Enabled = false
        local ok, err = s.contracts.revise(f.creator, c.id, { bailoutAmount = 20000 })
        falsy(ok)
        eq(err, CH.ERR.BAILOUT_OFF)
    end)

    it('nothing once a hitman holds it, nor while it is on hold by staff', function()
        local s, f, c = untaken()
        truthy(s.holds.freeze('ADMIN001', 'TARGET01', 'probe'))
        local _, frozenErr = s.contracts.revise(f.creator, c.id, { bailoutAmount = 20000 })
        eq(frozenErr, CH.ERR.CONTRACT_FROZEN)
        truthy(s.holds.unfreeze('ADMIN001', 'TARGET01', 'done'))
        truthy(s.contracts.accept(f.hitman, c.id, false), 'taken')
        for _, change in ipairs({ { bailoutAmount = 20000 }, { fulfilment = 'alive' }, { anonymous = true } }) do
            local ok, err = s.contracts.revise(f.creator, c.id, change)
            falsy(ok)
            eq(err, CH.ERR.CONTRACT_TAKEN)
        end
        local row = s.storage.readContract(c.id)
        eq(row.bailout_amount, 0)
        eq(row.fulfilment_rule, CH.FULFILMENT_RULE.EITHER)
        eq(row.anon_creator, false)
    end)

    it('one at a time with an acceptance, on the contract\'s own lock', function()
        local s, f, c = untaken()
        local inside
        s.contracts.serialized({ 'contract:' .. c.id }, function()
            inside = table.pack(s.contracts.revise(f.creator, c.id, { bailoutAmount = 20000 }))
        end)
        falsy(inside[1], 'ran beside an acceptance holding the lock')
        eq(inside[2], CH.ERR.BUSY)
    end)

    it('the target is quoted the price they pay: one changed under the dialog is refused', function()
        local s, f, c = untaken({ bailoutAmount = 15000 })
        truthy(s.contracts.revise(f.creator, c.id, { bailoutAmount = 25000 }))
        local before = bank(2)
        local r = call('bailout', 2, { id = c.id, shown = 15000 })
        falsy(r and r.ok, 'charged a price never shown')
        eq(r.err, CH.ERR.TERMS_CHANGED)
        eq(r.data.amount, 25000)
        eq(bank(2), before, 'nothing taken')
    end)

    it('how it is completed: only as the server places contracts now', function()
        local s, f, c = untaken()
        eq(s.storage.readContract(c.id).fulfilment_rule, CH.FULFILMENT_RULE.EITHER)
        truthy(s.contracts.revise(f.creator, c.id, { fulfilment = 'alive' }))
        eq(s.storage.readContract(c.id).fulfilment_rule, CH.FULFILMENT_RULE.ALIVE)
        truthy(s.contracts.revise(f.creator, c.id, { fulfilment = 'either' }))
        eq(s.storage.readContract(c.id).fulfilment_rule, CH.FULFILMENT_RULE.EITHER)
        Config.Completion.Fulfilment = 'alive'
        truthy(s.contracts.revise(f.creator, c.id, { fulfilment = 'alive' }))
        local ok, err = s.contracts.revise(f.creator, c.id, { fulfilment = 'either' })
        falsy(ok, 'a kill allowed on a server that places live handovers only')
        eq(err, CH.ERR.RULE_CHANGED)
        eq(s.storage.readContract(c.id).fulfilment_rule, CH.FULFILMENT_RULE.ALIVE)
        local _, bad = s.contracts.revise(f.creator, c.id, { fulfilment = 'dead' })
        eq(bad, CH.ERR.INVALID_INPUT)
    end)

    it('live handover only is refused while it carries a live-delivery bonus', function()
        local s, f, c = untaken({ bonusPercent = 50 })
        local ok, err = s.contracts.revise(f.creator, c.id, { fulfilment = 'alive' })
        falsy(ok)
        eq(err, CH.ERR.NO_BONUS)
        eq(s.storage.readContract(c.id).fulfilment_rule, CH.FULFILMENT_RULE.EITHER)
    end)

    it('anonymous: where the switches allow it, with the fee charged against the figure shown', function()
        local s, f, c = untaken()
        Config.Anonymity.CreatorFee = 2500
        Config.Anonymity.FeeAccount = 'bank'
        local before = bank(1)
        local r = call('revise', 1, { id = c.id, anonymous = true, shown = { creatorFee = 1000, feeAccount = 'bank' } })
        eq(r and r.err, CH.ERR.TERMS_CHANGED, 'a fee raised under the page charged')
        eq(s.storage.readContract(c.id).anon_creator, false)
        r = call('revise', 1, { id = c.id, anonymous = true, shown = { creatorFee = 2500, feeAccount = 'bank' } })
        truthy(r and r.ok, tostring(r and r.err))
        eq(s.storage.readContract(c.id).anon_creator, true)
        eq(before - bank(1), 2500, 'the fee, once')
        truthy(targetCard(s, c).creatorAnonymous, 'the target is shown it anonymous now')
        -- Back under their name: always allowed, nothing given back.
        Config.TargetClasses.default.AllowAnonymousPlacer = false
        r = call('revise', 1, { id = c.id, anonymous = false })
        truthy(r and r.ok, 'back under their name refused: ' .. tostring(r and r.err))
        eq(s.storage.readContract(c.id).anon_creator, false)
        truthy(f)
        eq(before - bank(1), 2500)
    end)

    it('anonymous refused where the switch is off, and by the whitelisted-target switch', function()
        local s, f, c = untaken()
        Config.TargetClasses.default.AllowAnonymousPlacer = false
        local _, err = s.contracts.revise(f.creator, c.id, { anonymous = true })
        eq(err, CH.ERR.ANONYMITY_OFF)
        Config.TargetClasses.default.AllowAnonymousPlacer = true
        Config.TargetClasses.whitelisted.AllowAnonymousPlacer = false
        local row = s.storage.readContract(c.id)
        row.target_protected = true
        s.storage.writeContract(row)
        local _, white = s.contracts.revise(f.creator, c.id, { anonymous = true })
        eq(white, CH.ERR.ANONYMITY_OFF, 'anonymous on an officer where the server allows none')
        eq(s.storage.readContract(c.id).anon_creator, false)
        local _, typed = s.contracts.revise(f.creator, c.id, { anonymous = 'yes' })
        eq(typed, CH.ERR.INVALID_INPUT)
    end)

    it('the target is not changed in place: nothing a revise sends moves it', function()
        local s, f, c = untaken()
        local ok, err = s.contracts.revise(f.creator, c.id, { targetCid = 'HITMAN01' })
        falsy(ok)
        eq(err, CH.ERR.INVALID_INPUT)
        eq(s.storage.readContract(c.id).target_cid, 'TARGET01')
    end)

    it('cancel and place again: everything comes back, and the new one is checked as any', function()
        local s, f, c = untaken()
        local before = Env.players[1].PlayerData.money.cash
        truthy(s.contracts.cancel(f.creator, c.id))
        eq(Env.players[1].PlayerData.money.cash, before + 10000, 'the reward handed back')
        Env.advance((Config.Amendments.CancelCooldownSeconds or 0) + 1)
        Env.addPlayer({ source = 7, citizenid = 'OTHER001', license = 'license:ooo', cash = 0, bank = 0 })
        local again = s.contracts.create(f.creator, { targetCid = 'OTHER001', reason = 'x',
            reward = { baseline = { cash = 10000 } } })
        truthy(again, 'placed on the new target')
    end)
end)
