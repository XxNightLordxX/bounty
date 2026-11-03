--- Sweep 4 (at f533da3): anonymity leaks, holds on charges, and the decay
--- clock. Each test here failed on the code before its fix.
---
---   A1  a proof handover told a hitman without the card "too far" or
---       "missing" by who stood beside them: a probe for the anonymous placer.
---   A2  a decay rise waited for its placer and landed when they logged in:
---       the board's reward timed an anonymous placer's login.
---   A2+ the heat bulletin left a known hitman with a police job out; the
---       serial scrub handed over a traceable serial for an unreadable contract.
---   B1  go dark charged on a contract staff hold.
---   B2  a freeze landing in a tip's or an informant's awaits still charged.
---   B3  a hold landing in a rise step stopped the rise for good.
---   B4  the decay clock ran through holds, the restart hold and a taking.
---   B5  a staff extension past the lifetime wrote over a give-back.
---   D4  a proof handover under the restart hold or the app pause took the
---       card before the claim refused.
---   the ledger said "ran out" of a contract cancelled by agreement.

local IMP = require('tests.harness.improvements')

local TARGET_AT = { x = 1200.0, y = -800.0, z = 30.0 }
local PRICE = { cost = 25000, account = 'bank' }

local function deepCopy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = deepCopy(v) end
    return out
end

--- Config.Improvements, Config.Roleplay and Config.LocationTip put back.
local function it(name, fn)
    IMP.it(name, function(...)
        local tip = deepCopy(Config.LocationTip)
        local informant = deepCopy(Config.Informant)
        local paused = Config.Staff.AppPaused
        local out = table.pack(pcall(fn, ...))
        Config.LocationTip = tip
        Config.Informant = informant
        Config.Staff.AppPaused = paused
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

local function count(src, name)
    local n = 0
    for _, slot in ipairs(Env.players[src]._inventory) do
        if slot.name == name then n = n + (slot.count or 0) end
    end
    return n
end

local function removes()
    local n = 0
    for _, call_ in ipairs(Natives.calls.inventory or {}) do
        if call_.op == 'remove' then n = n + 1 end
    end
    return n
end

local function card(src, cid)
    local p = Env.players[src]
    p._inventory[#p._inventory + 1] = { name = 'id_card', count = 1, slot = 41,
        metadata = { citizenid = cid, firstname = 'Dana', lastname = 'Reyes' } }
end

--------------------------------------------------------------------------
-- Proof items: A1 and D4
--------------------------------------------------------------------------

describe('sweep 4: the proof handover', function()
    local function held(anonymous)
        local s = newStack()
        local f = fixture(s)
        Config.Anonymity.AllowAnonymousPlacer = true
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt from last week', anonymous = anonymous,
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 40000 } },
        })
        truthy(c, 'placed')
        truthy(s.contracts.accept(f.hitman, c.id, false), 'taken')
        Config.Improvements.ProofItems.Enabled = true
        return s, f, c
    end

    it('A1 tells a hitman without the card the same thing whoever stands beside them', function()
        local _, _, c = held(true)
        -- Beside the anonymous placer (everybody stands at the origin).
        local beside = call('proofItem', 3, { id = c.id })
        -- Beside nobody: walked off to stand by a bystander.
        Env.players[3]._coords = { x = 500.0, y = 0.0, z = 0.0 }
        local away = call('proofItem', 3, { id = c.id })
        eq(beside.err, CH.ERR.PROOF_MISSING)
        eq(away.err, CH.ERR.PROOF_MISSING, 'no card: never "too far", which singles out the placer')
        eq(away.data, beside.data)
    end)

    it('A1 still says too far to a hitman holding the card', function()
        local _, _, c = held(true)
        card(3, 'TARGET01')
        Env.players[3]._coords = { x = 500.0, y = 0.0, z = 0.0 }
        eq(call('proofItem', 3, { id = c.id }).err, CH.ERR.PROOF_TOO_FAR)
        eq(count(3, 'id_card'), 1)
    end)

    it('D4 refuses under the restart hold before the card is taken', function()
        local s, _, c = held(false)
        card(3, 'TARGET01')
        truthy(s.freeze.scheduledRestart({ secondsRemaining = 600 }), 'restart hold on')
        Natives.calls.inventory = {}
        local reply = call('proofItem', 3, { id = c.id })
        eq(reply.err, CH.ERR.RESTART_HOLD)
        eq(removes(), 0, 'the card is never taken out to be put back')
        eq(count(3, 'id_card'), 1)
    end)

    it('D4 refuses under the app pause before the card is taken', function()
        local s, _, c = held(false)
        card(3, 'TARGET01')
        Config.Staff.AppPaused = true
        eq(s.freeze.syncAppPause(), 'paused')
        Natives.calls.inventory = {}
        local reply = call('proofItem', 3, { id = c.id })
        eq(reply.err, CH.ERR.APP_PAUSED)
        eq(removes(), 0, 'the card is never taken out to be put back')
        eq(count(3, 'id_card'), 1)
    end)
end)

--------------------------------------------------------------------------
-- The heat bulletin and the serial scrub
--------------------------------------------------------------------------

describe('sweep 4: the heat bulletin and the serial scrub', function()
    it('tells a known hitman who is an officer the bulletin as every other officer', function()
        local s = newStack()
        local f = fixture(s)
        Config.Notifications.ParanoidAlert = false
        Config.Improvements.HitmanHeat.Enabled = true
        Env.addPlayer({ source = 5, citizenid = 'OFFICER1', firstname = 'Otto', lastname = 'Beat',
            job = { name = 'police', type = 'leo', onduty = true } })
        -- The hitman holds a police job too.
        Env.players[3].PlayerData.job = { name = 'police', type = 'leo', onduty = true }
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 10000 } } })
        truthy(c and s.contracts.accept(f.hitman, c.id, true))
        s.impBoard.heat.add('HITMAN01', 50, 'test')
        Env.clientEvents = {}
        s.impBoard.tick()
        local function told(src)
            local n = 0
            for _, event in ipairs(Env.clientEvents) do
                if event.target == src and Natives.isNotice(event)
                    and tostring((event.args[1] or {}).title) == 'Intelligence bulletin' then n = n + 1 end
            end
            return n
        end
        eq(told(5), 1, 'the officer')
        eq(told(3), 1, 'and the hitman-officer alike: leaving them out names them')
    end)

    it('scrubs the serial of a weapon whose contract cannot be read', function()
        local s = newStack()
        Config.Improvements.SerialScrub.Enabled = true
        local line = { id = 'ln1', contract_id = 'ct-missing', source = CH.SOURCE.WEAPON,
            item = 'WEAPON_PISTOL', taken_from = 'CREATOR1' }
        local out = s.impScrub.scrub('HITMAN01', line, { serial = 'ABC123' })
        truthy(out and out.serial ~= 'ABC123', 'treated as anonymous: a new serial')
        local readContract = s.storage.readContract
        s.storage.readContract = function() error('connection lost') end
        local line2 = { id = 'ln2', contract_id = 'ct-x', source = CH.SOURCE.WEAPON,
            item = 'WEAPON_PISTOL', taken_from = 'CREATOR1' }
        local ran, raised = pcall(s.impScrub.scrub, 'HITMAN01', line2, { serial = 'ABC123' })
        s.storage.readContract = readContract
        truthy(ran and raised and raised.serial ~= 'ABC123', 'a read that raised: scrubbed too')
    end)
end)

--------------------------------------------------------------------------
-- Holds on charges: B1 and B2
--------------------------------------------------------------------------

local function taken()
    local s = newStack()
    Config.Notifications.ParanoidAlertJitter = { min = 0, max = 0 }
    local f = fixture(s)
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 } },
    })
    truthy(c, 'placed')
    Env.players[3].PlayerData.money.bank = 200000
    Env.players[2].PlayerData.money.bank = 200000
    Env.players[1].PlayerData.money.bank = 200000
    truthy(s.contracts.accept(f.hitman, c.id, false), 'taken')
    Env.players[2]._coords = { x = TARGET_AT.x, y = TARGET_AT.y, z = TARGET_AT.z }
    Env.advance(1)
    return s, f, c
end

--- A freeze on the target lands on the nth call to Storage[fnName].
local function freezeOnCall(s, fnName, nth)
    local orig = s.storage[fnName]
    local n, armed = 0, false
    s.storage[fnName] = function(...)
        n = n + 1
        if n == nth and not armed then
            armed = true
            s.freeze.freeze('ADMIN001', 'TARGET01', 'probe')
        end
        return orig(...)
    end
    return function()
        s.storage[fnName] = orig
        return armed
    end
end

describe('sweep 4: no money moves on a contract staff hold', function()
    it('B1 go dark refuses a frozen contract, charging nothing', function()
        local s, _, c = taken()
        Config.Improvements.GoDark.Enabled = true
        Config.Improvements.GoDark.Cost = 50000
        Config.Improvements.GoDark.Minutes = 30
        local t = call('locationTip', 3, { id = c.id, shown = PRICE })
        truthy(t and t.ok, 'tip bought: ' .. tostring(t and t.err))
        truthy(s.freeze.freeze('ADMIN001', 'TARGET01', 'probe'))
        local before = bank(2)
        local r = call('goDark', 2, { id = c.id, shown = { cost = 50000, account = 'bank' } })
        eq(r and r.err, CH.ERR.CONTRACT_FROZEN)
        eq(bank(2), before, 'nothing charged')
    end)

    it('B1 go dark refuses a freeze landing before the charge', function()
        local s, _, c = taken()
        Config.Improvements.GoDark.Enabled = true
        Config.Improvements.GoDark.Cost = 50000
        Config.Improvements.GoDark.Minutes = 30
        truthy(call('locationTip', 3, { id = c.id, shown = PRICE }).ok, 'tip bought')
        local before = bank(2)
        -- The second read of the contract is the one right before the charge.
        local undo = freezeOnCall(s, 'readContract', 2)
        local r = call('goDark', 2, { id = c.id, shown = { cost = 50000, account = 'bank' } })
        truthy(undo(), 'the freeze landed')
        eq(r and r.err, CH.ERR.CONTRACT_FROZEN)
        eq(bank(2), before, 'nothing charged')
    end)

    it('B2 a freeze landing before the tip charge charges nothing', function()
        local s, _, c = taken()
        local before = bank(3)
        -- The second readHitman is stillOn's, right before the charge.
        local undo = freezeOnCall(s, 'readHitman', 2)
        local t = call('locationTip', 3, { id = c.id, shown = PRICE })
        truthy(undo(), 'the freeze landed')
        eq(t and t.err, CH.ERR.CONTRACT_FROZEN)
        eq(bank(3), before, 'nothing charged')
    end)

    it('B2 a freeze landing after the tip charge refunds it', function()
        local s, _, c = taken()
        local before = bank(3)
        local orig = s.storage.writeLocationTip
        s.storage.writeLocationTip = function(...)
            s.freeze.freeze('ADMIN001', 'TARGET01', 'probe')
            return orig(...)
        end
        local t = call('locationTip', 3, { id = c.id, shown = PRICE })
        s.storage.writeLocationTip = orig
        eq(t and t.err, CH.ERR.CONTRACT_FROZEN)
        eq(bank(3), before, 'refunded')
    end)

    --- The informant specs' own way to a pick (tests/informant_spec.lua).
    local function informantScene()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c, 'placed')
        truthy(s.contracts.accept(f.hitman, c.id, true), 'taken')
        Env.players[1].PlayerData.money.bank = 100000
        Env.players[2].PlayerData.money.bank = 100000
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        local function view(cid) return s.projection.contract(s.storage.readContract(c.id), cid) end
        local buys = {
            target = function()
                local pick
                for _, p in ipairs(view('TARGET01').informantPicks or {}) do
                    if p.pick ~= 'placer' then pick = p.pick end
                end
                truthy(pick, 'a target pick')
                return s.informant.buy(f.target, c.id,
                    { cost = Config.Informant.Cost, account = Config.Informant.Account }, pick)
            end,
            placer = function()
                local pick = ((view('CREATOR1').placerInformantPicks or {})[1] or {}).pick
                truthy(pick, 'a placer pick')
                return s.informant.placerBuy(f.creator, c.id,
                    { cost = Config.PlacerInformant.Cost, account = Config.PlacerInformant.Account }, pick)
            end,
        }
        return s, f, c, buys
    end

    for _, which in ipairs({ 'target', 'placer' }) do
        local src = which == 'target' and 2 or 1
        it('B2 a freeze landing before the ' .. which .. '\'s informant charge charges nothing', function()
            local s, _, _, buys = informantScene()
            local before = bank(src)
            -- The second read of the contract is the one right before the charge.
            local undo = freezeOnCall(s, 'readContract', 2)
            local ok, err = buys[which]()
            truthy(undo(), 'the freeze landed')
            falsy(ok)
            eq(err, CH.ERR.CONTRACT_FROZEN)
            eq(bank(src), before, 'nothing charged')
        end)

        it('B2 a freeze landing in the ' .. which .. '\'s informant charge refunds it', function()
            local s, _, _, buys = informantScene()
            local before = bank(src)
            local player = Env.players[src]
            local getMoney = player.Functions.GetMoney
            local armed = false
            player.Functions.GetMoney = function(account)
                if not armed then
                    armed = true
                    s.freeze.freeze('ADMIN001', 'TARGET01', 'probe')
                end
                return getMoney(account)
            end
            local ok, err = buys[which]()
            player.Functions.GetMoney = getMoney
            truthy(armed, 'the freeze landed')
            falsy(ok)
            eq(err, CH.ERR.CONTRACT_FROZEN)
            eq(bank(src), before, 'refunded')
        end)
    end
end)

--------------------------------------------------------------------------
-- Contract decay: A2, B3, B4 and the cheap ones
--------------------------------------------------------------------------

local function decayStack()
    local s = newStack()
    local f = fixture(s, { creatorCash = 500000, creatorBank = 200000 })
    Config.Limits.TargetCooldownAfterResolveSeconds = 0
    Config.Notifications.ParanoidAlert = false
    Config.Anonymity.AllowAnonymousPlacer = true
    Config.Improvements.ContractDecay.Enabled = true
    Config.Improvements.ContractDecay.Mode = 'rise'
    return s, f
end

local function place(s, f, anonymous)
    local c, err = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = 10000 } }, anonymous = anonymous == true,
    })
    truthy(c, 'placed: ' .. tostring(err))
    return c
end

describe('sweep 4: contract decay', function()
    it('A2 never raises an anonymous contract, so a login moves nothing on the board', function()
        local s, f = decayStack()
        local c = place(s, f, true)
        s.impBoard.tick()
        local placer = Env.players[1]
        Env.removePlayer(1)
        Env.advance(5 * 3600)
        s.impBoard.tick()
        local worth = s.escrow.moneyValue(c.id)
        -- They log back in.
        Env.players[1] = placer
        Env.byCitizen['CREATOR1'] = 1
        local bankBefore = bank(1)
        Env.advance(60)
        s.impBoard.tick()
        Env.advance(60)
        s.impBoard.tick()
        eq(s.escrow.moneyValue(c.id), worth, 'the reward does not move at their login')
        eq(bank(1), bankBefore, 'nothing charged')
        Env.advance(3600)
        s.impBoard.tick()
        eq(s.escrow.moneyValue(c.id), 10000, 'never rises at all')
        local d = s.impBoard.decay.cardFor(s.storage.readContract(c.id))
        eq(d and d.anonymous, true, 'the card says why')
    end)

    it('A2 still raises a named placer\'s contract', function()
        local s, f = decayStack()
        local c = place(s, f, false)
        s.impBoard.tick()
        Env.advance(3600)
        s.impBoard.tick()
        eq(s.escrow.moneyValue(c.id), 11000)
    end)

    it('B3 a freeze landing in a rise step does not stop the rise for good', function()
        local s, f = decayStack()
        local c = place(s, f)
        s.impBoard.tick()
        Env.advance(3600)
        local orig = s.storage.readContract
        local armed = false
        s.storage.readContract = function(id, ...)
            if not armed and id == c.id and debug.traceback():find('imp_decay', 1, true) then
                armed = true
                s.freeze.freeze('ADMIN001', 'TARGET01', 'probe')
            end
            return orig(id, ...)
        end
        Env.clientEvents = {}
        s.impBoard.tick()
        s.storage.readContract = orig
        truthy(armed, 'freeze landed in the step')
        for _, event in ipairs(Env.clientEvents) do
            if event.target == 1 and Natives.isNotice(event) then
                falsy(tostring((event.args[1] or {}).content or ''):find('could not rise', 1, true),
                    'no false "could not rise from your bank"')
            end
        end
        truthy(s.freeze.unfreeze('ADMIN001', 'TARGET01', 'done'))
        Env.advance(3600)
        local bankBefore = bank(1)
        s.impBoard.tick()
        Env.advance(3600)
        s.impBoard.tick()
        local rows = s.storage.readRpRows('imp_decay')
        eq(rows[1] and rows[1].stopped, nil, 'not stopped for good by a temporary hold')
        truthy(bank(1) < bankBefore, 'rises again after the hold')
    end)

    it('B4 the clock stands still through a freeze', function()
        local s, f = decayStack()
        local c = place(s, f)
        s.impBoard.tick()
        Env.advance(600)
        truthy(s.freeze.freeze('ADMIN001', 'TARGET01', 'probe'))
        Env.advance(5 * 3600)
        s.impBoard.tick()
        truthy(s.freeze.unfreeze('ADMIN001', 'TARGET01', 'done'))
        local bankBefore = bank(1)
        Env.advance(60)
        s.impBoard.tick()
        eq(bank(1), bankBefore, 'only 11 minutes of unheld waiting: no step yet (escrow '
            .. s.escrow.moneyValue(c.id) .. ')')
        Env.advance(3600 - 660 + 60)
        s.impBoard.tick()
        eq(s.escrow.moneyValue(c.id), 11000, 'the step once an hour of waiting is up')
    end)

    it('B4 charges nothing during the restart hold', function()
        local s, f = decayStack()
        local c = place(s, f)
        s.impBoard.tick()
        Env.advance(3500)
        truthy(s.freeze.scheduledRestart({ secondsRemaining = 600 }), 'restart hold on')
        Env.advance(200)
        local bankBefore = bank(1)
        s.impBoard.tick()
        eq(bank(1), bankBefore, 'no rise during the restart hold (escrow ' .. s.escrow.moneyValue(c.id) .. ')')
    end)

    it('B4 the clock stands still while an operative holds it', function()
        local s, f = decayStack()
        local c = place(s, f)
        s.impBoard.tick()
        Env.advance(600)
        truthy(s.contracts.accept(f.hitman, c.id, false), 'taken')
        Env.advance(3000)
        s.impBoard.tick()
        Env.advance(3500)
        truthy(s.contracts.abandon(f.hitman, c.id), 'walked away')
        eq(s.storage.readContract(c.id).state, CH.STATE.ACTIVE)
        local bankBefore = bank(1)
        Env.advance(100)
        s.impBoard.tick()
        eq(bank(1), bankBefore, 'only 12 minutes untaken: no step yet')
        Env.advance(3100)
        s.impBoard.tick()
        truthy(bank(1) < bankBefore, 'the step once an hour untaken is up')
    end)

    it('keeps the decay row of a contract being paid', function()
        local s, f = decayStack()
        local c = place(s, f)
        s.impBoard.tick()
        Env.advance(3600)
        s.impBoard.tick()
        eq(#s.storage.readRpRows('imp_decay'), 1)
        truthy(s.storage.compareSetContractState(c.id, CH.STATE.ACTIVE, CH.STATE.COMPLETING))
        Env.advance(60)
        s.impBoard.tick()
        eq(#s.storage.readRpRows('imp_decay'), 1, 'a completion that fails goes back with its count')
        truthy(f)
    end)

    it('charges no rise once an operative has taken it, whatever the caller read', function()
        local s, f = decayStack()
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false), 'taken')
        local before = bank(1)
        local ok, err = s.amendments.addEscrow(f.creator, c.id, { baseline = { bank = 1000 } },
            { onlyActive = true })
        falsy(ok)
        eq(err, CH.ERR.BAD_STATE)
        eq(bank(1), before)
    end)
end)

--------------------------------------------------------------------------
-- B5: a staff extension past the lifetime
--------------------------------------------------------------------------

describe('sweep 4: a staff extension and a give-back', function()
    it('B5 keeps a give-back that landed in the extension\'s awaits', function()
        local s, f = decayStack()
        Config.Improvements.ContractDecay.Enabled = false
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false), 'taken')
        local row = s.storage.readContract(c.id)
        s.storage.setContractFields(c.id, { expires_at = row.deadline_at + 100 })
        truthy(s.freeze.freeze('ADMIN001', 'TARGET01', 'probe'))
        Env.advance(3600)
        local setDeadline = s.storage.setDeadline
        local fired = false
        s.storage.setDeadline = function(...)
            local out = table.pack(setDeadline(...))
            if not fired then
                fired = true
                truthy(s.freeze.unfreeze('ADMIN001', 'TARGET01', 'done'))
            end
            return table.unpack(out, 1, out.n)
        end
        local exp0 = s.storage.readContract(c.id).expires_at
        local ok, err = s.admin.adjustDeadline(0, c.id, 7200, 'ticket')
        s.storage.setDeadline = setDeadline
        truthy(ok, tostring(err))
        eq(s.storage.readContract(c.id).expires_at, exp0 + 7200 + 3600,
            'extension (+7200) and the freeze give-back (+3600) both kept')
    end)
end)

--------------------------------------------------------------------------
-- The ledger's words
--------------------------------------------------------------------------

describe('sweep 4: the ledger', function()
    it('writes a contract cancelled by agreement as cancelled, not as one that ran out', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        truthy(c)
        local ok = s.contracts.resolve(c.id, CH.STATE.CANCELLED, 'CREATOR1', nil, 'cancelled_by_agreement')
        truthy(ok, 'cancelled')
        local rows = s.storage.readLedger('CREATOR1', 10)
        eq(rows[1] and rows[1].kind, 'cancelled')
    end)
end)
