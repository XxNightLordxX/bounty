--- Boundaries, and one step past them.
---
--- Every ceiling in this resource is a promise to two people at once: the
--- player, who has to be told "no" in a way they can act on, and the
--- operator, who set the number because the thing behind it costs
--- something. A ceiling that is off by one refuses a reward that is inside
--- it; a ceiling something walks around is not a ceiling at all.
---
--- So each limit is exercised three times: one below, exactly at, and one
--- past. The one past must be refused AND must leave nothing behind —
--- no money taken, no half-written row.

--------------------------------------------------------------------------
-- Money accounting
--------------------------------------------------------------------------

--- Every pocket on the server.
local function pockets()
    local total = 0
    for _, player in pairs(Env.players) do
        total = total + (player.PlayerData.money.cash or 0)
                      + (player.PlayerData.money.bank or 0)
    end
    return total
end

--- Money the resource is holding rather than destroying: escrow that has
--- not settled, plus a buyout premium already charged and still queued on a
--- contract that has not resolved. Leaving the queued buyout out reports
--- money destroyed that is merely in flight.
local function heldByResource(storage)
    local total = 0
    for _, contract in ipairs(storage.allContracts()) do
        for _, line in ipairs(storage.readEscrow(contract.id)) do
            if line.state ~= CB.ESCROW_STATE.SETTLED and CB.MONEY_SOURCES[line.source] then
                total = total + (line.amount or 0)
            end
        end
        if not CB.TERMINAL[contract.state] then
            total = total + (contract.bailout_paid_amount or 0)
        end
    end
    return total
end

local function accounted(storage) return pockets() + heldByResource(storage) end

--------------------------------------------------------------------------
-- The real boot path, for the passes that only main.lua runs
--------------------------------------------------------------------------

local function boot()
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

    local main = require('server.main')
    return main, main.start()
end

--------------------------------------------------------------------------
-- Escrow lines: Config.Limits.MaxEscrowLines
--------------------------------------------------------------------------

--- Two money sources per payout slot, so the line count is exactly twice
--- the number of slots and the ceiling can be landed on precisely.
local function slotsOf(count, tail)
    local slots = {}
    for i = 1, count do slots[i] = { baseline = { cash = 100, bank = 100 } } end
    if tail then slots[#slots + 1] = { baseline = { cash = 100 } } end
    return { slots = slots }
end

describe('the escrow line ceiling', function()
    it('accepts a contract that lands exactly on it', function()
        local s = newStack()
        local f = fixture(s)
        -- The stack first: newStack() resets the whole config, so an
        -- override made outside it is thrown away before the test runs.
        withConfig({ { Config.Limits, 'MaxEscrowLines', 4 } }, function()
            local c, err = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'Unpaid debt',
                mode = CB.MODE.COMPETITIVE, reward = slotsOf(2),
            })
            truthy(c, 'four lines against a ceiling of four is inside it: ' .. tostring(err))
            eq(#s.storage.readEscrow(c.id), 4, 'and all four are stored')
        end)
    end)

    it('refuses the one line past it without charging for any of them', function()
        local s = newStack()
        local f = fixture(s)
        withConfig({ { Config.Limits, 'MaxEscrowLines', 4 } }, function()
            local before = accounted(s.storage)
            local c, err = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'Unpaid debt',
                mode = CB.MODE.COMPETITIVE, reward = slotsOf(2, true),
            })
            falsy(c, 'five lines against a ceiling of four has to be refused')
            eq(err, CB.ERR.INVALID_REWARD)
            eq(accounted(s.storage), before,
                'a refused contract must not have cost the creator anything')
            eq(#s.storage.allContracts(), 0, 'and must not leave a row behind')
        end)
    end)

    it('lets a top-up reach the ceiling and refuses the step past it', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE, reward = { baseline = { cash = 100 } },
        })
        truthy(c)
        withConfig({ { Config.Limits, 'MaxEscrowLines', 3 } }, function()
            truthy(s.amendments.addEscrow(f.creator, c.id, { baseline = { cash = 50 } }),
                'second line is inside a ceiling of three')
            truthy(s.amendments.addEscrow(f.creator, c.id, { baseline = { cash = 50 } }),
                'third line lands exactly on it')
            eq(#s.storage.readEscrow(c.id), 3)

            local before = accounted(s.storage)
            local ok, err = s.amendments.addEscrow(f.creator, c.id, { baseline = { cash = 50 } })
            falsy(ok, 'the fourth is past the ceiling')
            eq(err, CB.ERR.INVALID_REWARD)
            eq(#s.storage.readEscrow(c.id), 3, 'and nothing was written')
            eq(accounted(s.storage), before, 'and nothing was taken')
        end)
    end)

    --- The ceiling is documented as covering "any later top-up", and
    --- raise_bonus is a later top-up: it builds escrow lines itself rather
    --- than going through Escrow.validate, and the code that does it says
    --- so — "The same ceiling the rest of the escrow answers to. This path
    --- builds its lines itself rather than going through validate, so
    --- nothing else would stop it." It then applies Config.MaxContractValue
    --- and stops. Nothing counts the lines.
    ---
    --- Each raise appends a fresh derived bonus line per unsettled money
    --- baseline, so a creator who walks the percentage up one point at a
    --- time turns one contract into hundreds of escrow rows for a few
    --- hundred dollars — and every board render reads all of them, three
    --- times per contract, for every player looking at the board.
    it('holds when the bonus is raised, not only when escrow is added', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE, reward = slotsOf(2),
        })
        truthy(c)
        eq(#s.storage.readEscrow(c.id), 4, 'four baseline lines to start')

        for percent = 1, Config.Bonus.maxPercent do
            s.amendments.improve(f.creator, c.id, CB.AMENDMENT.RAISE_BONUS, { percent = percent })
        end

        local lines = #s.storage.readEscrow(c.id)
        truthy(lines <= Config.Limits.MaxEscrowLines,
            ('one contract holds %d escrow lines against a ceiling of %d. Every '
             .. 'board render reads them, three times per contract, for every '
             .. 'player on the server.'):format(lines, Config.Limits.MaxEscrowLines))
    end)
end)

--------------------------------------------------------------------------
-- Config.MaxContractValue
--------------------------------------------------------------------------

describe('the contract value ceiling', function()
    it('accepts a reward that lands exactly on it', function()
        local s = newStack()
        local f = fixture(s)
        withConfig({ { Config, 'MaxContractValue', 5000 } }, function()
            local c, err = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'Unpaid debt',
                mode = CB.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } },
            })
            truthy(c, 'the ceiling is inclusive: ' .. tostring(err))
            eq(s.escrow.moneyValue(c.id), 5000)
        end)
    end)

    it('refuses one dollar past it and takes nothing', function()
        local s = newStack()
        local f = fixture(s)
        withConfig({ { Config, 'MaxContractValue', 5000 } }, function()
            local before = accounted(s.storage)
            local c, err = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'Unpaid debt',
                mode = CB.MODE.COMPETITIVE, reward = { baseline = { cash = 5001 } },
            })
            falsy(c)
            eq(err, CB.ERR.INVALID_REWARD)
            eq(accounted(s.storage), before, 'a refusal must not cost anything')
        end)
    end)
end)

--------------------------------------------------------------------------
-- The audit queue at capacity
--------------------------------------------------------------------------

describe('the audit queue at capacity', function()
    it('holds its full size, then evicts the oldest and says so', function()
        local s = newStack()
        withConfig({ { Config.Audit, 'MaxQueueSize', 5 } }, function()
            for i = 1, 5 do s.audit.financial('event' .. i, 'CREATOR1', nil, {}) end
            eq(s.audit.pending(), 5, 'the queue holds exactly what it is sized for')
            eq(s.audit.droppedCount(), 0, 'and has dropped nothing yet')

            s.audit.financial('event6', 'CREATOR1', nil, {})
            eq(s.audit.pending(), 5, 'one past capacity does not grow the queue')
            eq(s.audit.droppedCount(), 1, 'the evicted row is counted, not lost silently')

            eq(s.audit.flush(), 5, 'the flush writes the five it still holds')

            local rows = s.storage.readAudit()
            local actions = {}
            for _, row in ipairs(rows) do actions[row.action] = true end
            falsy(actions['event1'], 'the oldest row is the one that went')
            truthy(actions['event6'], 'and the newest is the one that stayed')
            -- A silent drop is worse than a noisy one: the operator's log
            -- has a hole in it and only this row says so.
            truthy(actions['audit_overflow'], 'the overflow is reported')
        end)
    end)
end)

--------------------------------------------------------------------------
-- The per-recipient notification budget
--------------------------------------------------------------------------

describe('the notification budget', function()
    it('delivers the last one inside the minute and refuses the next', function()
        local s = newStack()
        fixture(s)
        withConfig({ { Config.Notifications, 'MaxPerRecipientPerMinute', 3 },
                     { Config.Notifications, 'MaxPerRecipientPerHour', 100 } }, function()
            truthy(s.notify.toCitizen('TARGET01', 'a', 'x'), 'first')
            truthy(s.notify.toCitizen('TARGET01', 'b', 'x'), 'second')
            truthy(s.notify.toCitizen('TARGET01', 'c', 'x'), 'third is exactly the budget')
            falsy(s.notify.toCitizen('TARGET01', 'd', 'x'), 'fourth is past it')

            Env.time = Env.time + 60
            truthy(s.notify.toCitizen('TARGET01', 'e', 'x'),
                'and the next minute opens the budget again')
        end)
    end)

    it('still binds by the hour once the minutes have rolled', function()
        local s = newStack()
        fixture(s)
        withConfig({ { Config.Notifications, 'MaxPerRecipientPerMinute', 3 },
                     { Config.Notifications, 'MaxPerRecipientPerHour', 5 } }, function()
            local sent = 0
            for _ = 1, 4 do
                for _ = 1, 3 do
                    if s.notify.toCitizen('TARGET01', 'n', 'x') then sent = sent + 1 end
                end
                Env.time = Env.time + 60
            end
            eq(sent, 5, 'the hour ceiling is what stops it, not the minute one')
        end)
    end)
end)

--------------------------------------------------------------------------
-- A contract at exactly its deadline, and at exactly its lifetime
--------------------------------------------------------------------------

describe('a contract sitting exactly on its deadline', function()
    --- The offsets are applied to the clock AFTER the boot, because boot()
    --- resets it: an argument computed from Env.time at the call site is
    --- measured against whatever the previous test left behind, which is
    --- how this pair of tests first passed for the wrong reason.
    local function bootWithContract(offsets)
        local main, modules = boot()
        local f = fixture(modules)
        local c = modules.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c)
        local row = modules.storage.readContract(c.id)
        for key, offset in pairs(offsets) do row[key] = Env.time + offset end
        modules.storage.writeContract(row)
        return main, modules, f, c
    end

    it('is left alone at the deadline and closed one second past it', function()
        local main, modules, f, c = bootWithContract({ deadline_at = 0 })
        eq(main.expire(), 0, 'exactly due is not overdue')
        eq(modules.storage.readContract(c.id).state, CB.STATE.ACTIVE)

        local before = accounted(modules.storage)
        Env.time = Env.time + 1
        eq(main.expire(), 1, 'one second past it, the contract closes')
        eq(modules.storage.readContract(c.id).state, CB.STATE.EXPIRED)
        eq(accounted(modules.storage), before, 'and the escrow came back rather than vanishing')
    end)

    it('is left alone at the absolute lifetime and closed one second past it', function()
        local main, modules, f, c = bootWithContract({ expires_at = 0, deadline_at = 86400 })
        eq(main.expire(), 0, 'exactly at the ceiling is still inside it')
        eq(modules.storage.readContract(c.id).state, CB.STATE.ACTIVE)

        Env.time = Env.time + 1
        eq(main.expire(), 1, 'one second past the lifetime, the contract closes')
        eq(modules.storage.readContract(c.id).state, CB.STATE.EXPIRED)
        eq(modules.storage.readContract(c.id).resolution, 'lifetime_exceeded',
            'and closed for the reason that actually applies')
    end)
end)

--------------------------------------------------------------------------
-- The id sequence, exhausted
--------------------------------------------------------------------------

--- The escrow line id sequence is the one exhaustion path with money
--- already in flight when it gives up.
---
--- Util.mintId exists because ids carry a per-process counter: two server
--- instances sharing one database mint the same sequence, and escrow is
--- written with ON DUPLICATE KEY UPDATE, so an id already in use does not
--- fail — it lands on top of the line that holds it and takes its money
--- with it. Refusing is right. What the refusal must not do is lose the
--- money it was called to protect.
---
--- Contracts.create refuses before it charges anybody, and Contracts.accept
--- gives the stake back; both are covered in contracts_spec. Bailout.owe is
--- the third call site, and it is reached with the target's premium already
--- taken.
describe('the escrow line id sequence with nothing left to mint', function()
    local function boughtOutByAnAbsentCreator(s, f)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE, reward = { baseline = { cash = 10000 } },
            bailoutAmount = 20000,
        })
        truthy(c, 'a contract with a buyout price')
        eq(c.bailout_amount, 20000)
        -- The creator is not here to be paid, so the premium has to be
        -- written as an owed escrow line and delivered on their next login.
        Env.players[1] = nil
        return c
    end

    it('owes the premium when the creator is offline, losing nothing', function()
        local s = newStack()
        local f = fixture(s)
        local c = boughtOutByAnAbsentCreator(s, f)

        local before = accounted(s.storage)
        truthy(s.bailout.buy(f.target, c.id))
        eq(accounted(s.storage), before,
            'the premium is owed rather than lost when the creator is away')
    end)

    it('does not destroy the premium when no owed line can be minted', function()
        local s = newStack()
        local f = fixture(s)
        local c = boughtOutByAnAbsentCreator(s, f)

        -- The exists predicate mintId consults, answering the way it does
        -- when every id the sequence offers already belongs to a line.
        s.storage.readEscrowLine = function() return { id = 'owe00000001' } end

        local before = accounted(s.storage)
        s.bailout.buy(f.target, c.id)
        eq(accounted(s.storage), before,
            'the target paid the premium and it went nowhere: no owed line was '
            .. 'written, the contract closed anyway, and only an audit row says so')
    end)
end)
