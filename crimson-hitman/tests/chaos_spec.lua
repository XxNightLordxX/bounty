--- Money is conserved even when things fail halfway through.
---
--- The suite exercises failure one cause at a time, at a moment somebody
--- chose. This fails things at moments nobody chose: a random one of the
--- calls an operation depends on refuses, or throws, partway through — and
--- afterwards every coin in the world still has to add up.
---
--- Conservation is the assertion because it is the one that survives not
--- knowing what should have happened. Whether the contract ends up placed
--- or refused depends on which call was broken; that money was neither
--- minted nor destroyed does not.

--- What one player holds, per source. dirty is an ox_inventory item rather
--- than an account, so it is counted out of the inventory.
local function purse(src)
    local p = Env.players[src]
    if not p then return { cash = 0, bank = 0, dirty = 0 } end
    local dirty = 0
    for _, e in ipairs(p._inventory or {}) do
        if e.name == Config.Sources.dirty.item then dirty = dirty + (e.count or 0) end
    end
    return { cash = p.PlayerData.money.cash or 0,
             bank = p.PlayerData.money.bank or 0, dirty = dirty }
end

--- Pockets plus everything escrow still owes somebody.
local function world(s)
    local total = { cash = 0, bank = 0, dirty = 0 }
    for _, c in ipairs(s.storage.allContracts()) do
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if CH.MONEY_SOURCES[line.source]
                and line.state ~= CH.ESCROW_STATE.SETTLED then
                total[line.source] = total[line.source] + (line.amount or 0)
            end
        end
    end
    for src in pairs(Env.players) do
        local p = purse(src)
        total.cash = total.cash + p.cash
        total.bank = total.bank + p.bank
        total.dirty = total.dirty + p.dirty
    end
    return total
end

--- The seams a real server can fail at: the framework's money calls, the
--- inventory, and the store itself. Each entry breaks one of them for the
--- duration of an operation, either by refusing or by throwing — a refusal
--- and a raise are different code paths and only one of them is guarded.
local function seams(s)
    local out = {}

    local function moneySeam(fname, how)
        out[#out + 1] = {
            what = fname .. ' ' .. how,
            apply = function()
                local saved = {}
                for src, p in pairs(Env.players) do
                    saved[src] = p.Functions[fname]
                    p.Functions[fname] = function(...)
                        if how == 'throws' then error(fname .. ' exploded', 0) end
                        return false
                    end
                end
                return function()
                    for src, real in pairs(saved) do
                        if Env.players[src] then Env.players[src].Functions[fname] = real end
                    end
                end
            end,
        }
    end

    for _, fname in ipairs({ 'AddMoney', 'RemoveMoney', 'GetMoney' }) do
        for _, how in ipairs({ 'refuses', 'throws' }) do moneySeam(fname, how) end
    end

    local function inventorySeam(fname, how)
        out[#out + 1] = {
            what = 'ox:' .. fname .. ' ' .. how,
            apply = function()
                local real = exports.ox_inventory[fname]
                exports.ox_inventory[fname] = function(...)
                    if how == 'throws' then error(fname .. ' exploded', 0) end
                    return false
                end
                return function() exports.ox_inventory[fname] = real end
            end,
        }
    end

    for _, fname in ipairs({ 'AddItem', 'RemoveItem', 'CanCarryItem', 'GetItem' }) do
        for _, how in ipairs({ 'refuses', 'throws' }) do inventorySeam(fname, how) end
    end

    local function storeSeam(fname, how)
        out[#out + 1] = {
            what = 'store:' .. fname .. ' ' .. how,
            apply = function()
                local real = s.storage[fname]
                s.storage[fname] = function(...)
                    if how == 'throws' then error(fname .. ' exploded', 0) end
                    return false
                end
                return function() s.storage[fname] = real end
            end,
        }
    end

    for _, fname in ipairs({ 'writeContract', 'writeEscrow', 'claimEscrowLine',
                             'settleEscrowLine', 'writePending' }) do
        for _, how in ipairs({ 'refuses', 'throws' }) do storeSeam(fname, how) end
    end

    return out
end

--- The operations worth breaking: each moves money.
local function journeys()
    return {
        {
            what = 'placing a contract',
            run = function(s, f)
                return s.contracts.create(f.creator, {
                    targetCid = 'TARGET01', reason = 'Unpaid debt',
                    mode = CH.MODE.EXCLUSIVE,
                    reward = { baseline = { cash = 5000, bank = 2500 } },
                })
            end,
        },
        {
            what = 'accepting one',
            setup = function(s, f) return s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'Unpaid debt',
                mode = CH.MODE.COMPETITIVE,
                reward = { baseline = { cash = 5000 } },
                penaltyAmount = 1000,
            }) end,
            run = function(s, f, c) return s.contracts.accept(f.hitman, c.id, false) end,
        },
        {
            what = 'paying one out',
            setup = function(s, f)
                local c = s.contracts.create(f.creator, {
                    targetCid = 'TARGET01', reason = 'Unpaid debt',
                    mode = CH.MODE.COMPETITIVE,
                    reward = { baseline = { cash = 5000, bank = 1000 } },
                })
                s.contracts.accept(f.hitman, c.id, false)
                return c
            end,
            -- Through claimSlot. Contracts.resolve cannot take a contract
            -- straight from accepted to completed — the state machine routes
            -- it through completing — so calling it here was refused as
            -- locked and this journey broke nothing.
            run = function(s, f, c)
                return s.contracts.claimSlot(c.id, 'HITMAN01', 'elimination')
            end,
        },
        {
            what = 'cancelling one',
            setup = function(s, f) return s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'Unpaid debt',
                mode = CH.MODE.EXCLUSIVE,
                reward = { baseline = { cash = 5000 } },
            }) end,
            run = function(s, f, c) return s.contracts.cancel(f.creator, c.id) end,
        },
        {
            what = 'buying out',
            setup = function(s, f) return s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'Unpaid debt',
                mode = CH.MODE.EXCLUSIVE,
                reward = { baseline = { cash = 5000 } },
                bailoutAmount = 10000,
            }) end,
            run = function(s, f, c) return s.bailout.buy(f.target, c.id) end,
        },
        {
            what = 'taking part of a reward back',
            setup = function(s, f) return s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'Unpaid debt',
                mode = CH.MODE.EXCLUSIVE,
                reward = { slots = { { baseline = { cash = 5000, bank = 500 } } } },
            }) end,
            run = function(s, f, c)
                local ids = {}
                for _, line in ipairs(s.storage.readEscrow(c.id)) do
                    if line.source == 'cash' then ids[#ids + 1] = line.id end
                end
                return s.contracts.withdrawReward(f.creator, c.id, ids)
            end,
        },
    }
end

describe('money when something fails partway through', function()
    it('is neither minted nor destroyed, whatever breaks', function()
        local broken, tried = {}, 0

        for _, journey in ipairs(journeys()) do
            local s = newStack()
            local f = fixture(s)
            for _, seam in ipairs(seams(s)) do
                -- A fresh world for each pairing, so a failure is caused by
                -- this seam rather than inherited from the last one.
                local stack = newStack()
                local people = fixture(stack)
                local contract = journey.setup and journey.setup(stack, people) or nil

                -- Only pairings whose setup actually produced something to
                -- break are counted, so the total below means what it says.
                if not journey.setup or contract then
                    tried = tried + 1
                    local before = world(stack)
                    local restore = seam.apply()
                    pcall(journey.run, stack, people, contract)
                    restore()

                    local after = world(stack)
                    for _, source in ipairs({ 'cash', 'bank', 'dirty' }) do
                        if after[source] ~= before[source] then
                            broken[#broken + 1] = ('%s while %s: %s moved %+d')
                                :format(seam.what, journey.what, source,
                                        after[source] - before[source])
                        end
                    end
                end
            end
        end

        truthy(tried > 100,
            'this broke only ' .. tried .. ' pairings, which is the loop '
            .. 'having stopped rather than the resource having shrunk')

        eq(#broken, 0,
            ('%d of %d pairings moved money that was not theirs to move:\n  %s')
                :format(#broken, tried,
                        table.concat(broken, '\n  ', 1, math.min(#broken, 8))))
    end)
end)

--- A raise after part of a reward was already taken.
---
--- The seams above break every call, so on a reward's first line nothing had
--- been taken yet and the rollback had nothing to do. The one shape that
--- destroyed money was a raise on a later line: it left the take through
--- Escrow.take, past the rollback, with nothing written, and the earlier
--- lines were gone. These break only the later call.
describe('a raise after part of a reward was taken', function()
    local function lockpicks(src)
        local n = 0
        for _, e in ipairs(Env.players[src]._inventory or {}) do
            if e.name == 'lockpick' then n = n + (e.count or 0) end
        end
        return n
    end

    --- RemoveMoney that raises on its second call, after taking the money or
    --- before, as the case says.
    local function secondRemoveMoneyRaises(src, afterTaking)
        local p = Env.players[src]
        local real, calls = p.Functions.RemoveMoney, 0
        p.Functions.RemoveMoney = function(...)
            calls = calls + 1
            if calls < 2 then return real(...) end
            if afterTaking then real(...) end
            error('RemoveMoney exploded', 0)
        end
        return function() p.Functions.RemoveMoney = real end
    end

    local function removeItemRaises()
        local real = exports.ox_inventory.RemoveItem
        exports.ox_inventory.RemoveItem = function() error('RemoveItem exploded', 0) end
        return function() exports.ox_inventory.RemoveItem = real end
    end

    local function place(s, f, baseline)
        return s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.EXCLUSIVE, reward = { baseline = baseline },
        })
    end

    local function conserved(s, before, label)
        local after = world(s)
        for _, source in ipairs({ 'cash', 'bank', 'dirty' }) do
            eq(after[source], before[source], ('%s: %s moved %+d'):format(
                label, source, after[source] - before[source]))
        end
    end

    it('gives the cash back when the dirty money after it raises', function()
        local s = newStack()
        local f = fixture(s)
        local before = world(s)
        local restore = removeItemRaises()
        local ran, c = pcall(place, s, f, { cash = 5000, dirty = 1000 })
        restore()
        falsy(ran and c, 'nothing is placed')
        conserved(s, before, 'cash then dirty')

        s.audit.flush()
        local named
        for _, row in ipairs(s.storage.readAudit(200)) do
            if row.action == 'escrow_take_raised' then named = row end
        end
        truthy(named, 'the line that raised is named for staff')
        eq(named.detail.source, 'dirty')
    end)

    it('gives the cash back when an item after it raises', function()
        local s = newStack()
        local f = fixture(s)
        local before = world(s)
        local restore = removeItemRaises()
        local ran, c = pcall(place, s, f,
            { cash = 5000, items = { { name = 'lockpick', count = 2 } } })
        restore()
        falsy(ran and c, 'nothing is placed')
        conserved(s, before, 'cash then an item')
        eq(lockpicks(1), 5, 'the item was never taken')
    end)

    it('gives the cash back when the bank after it raises before moving', function()
        local s = newStack()
        local f = fixture(s)
        local before = world(s)
        local restore = secondRemoveMoneyRaises(1, false)
        local ran, c = pcall(place, s, f, { cash = 5000, bank = 2500 })
        restore()
        falsy(ran and c, 'nothing is placed')
        conserved(s, before, 'cash then bank')
    end)

    it('holds the bank in escrow when it raised after the money moved', function()
        local s = newStack()
        local f = fixture(s)
        local before = world(s)
        local restore = secondRemoveMoneyRaises(1, true)
        local ran, c = pcall(place, s, f, { cash = 5000, bank = 2500 })
        restore()
        truthy(ran and c, 'the balance says it was paid, so the contract stands')
        conserved(s, before, 'bank taken, then a raise')
    end)
end)
