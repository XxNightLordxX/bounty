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
            if CB.MONEY_SOURCES[line.source]
                and line.state ~= CB.ESCROW_STATE.SETTLED then
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
                    mode = CB.MODE.EXCLUSIVE,
                    reward = { baseline = { cash = 5000, bank = 2500 } },
                })
            end,
        },
        {
            what = 'accepting one',
            setup = function(s, f) return s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'Unpaid debt',
                mode = CB.MODE.COMPETITIVE,
                reward = { baseline = { cash = 5000 } },
                penaltyAmount = 1000,
            }) end,
            run = function(s, f, c) return s.contracts.accept(f.hunter, c.id, false) end,
        },
        {
            what = 'paying one out',
            setup = function(s, f)
                local c = s.contracts.create(f.creator, {
                    targetCid = 'TARGET01', reason = 'Unpaid debt',
                    mode = CB.MODE.COMPETITIVE,
                    reward = { baseline = { cash = 5000, bank = 1000 } },
                })
                s.contracts.accept(f.hunter, c.id, false)
                return c
            end,
            run = function(s, f, c)
                return s.contracts.resolve(c.id, CB.STATE.COMPLETED, 'HUNTER01', nil, 'chaos')
            end,
        },
        {
            what = 'cancelling one',
            setup = function(s, f) return s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'Unpaid debt',
                mode = CB.MODE.EXCLUSIVE,
                reward = { baseline = { cash = 5000 } },
            }) end,
            run = function(s, f, c) return s.contracts.cancel(f.creator, c.id) end,
        },
        {
            what = 'buying out',
            setup = function(s, f) return s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'Unpaid debt',
                mode = CB.MODE.EXCLUSIVE,
                reward = { baseline = { cash = 5000 } },
                bailoutAmount = 10000,
            }) end,
            run = function(s, f, c) return s.bailout.buy(f.target, c.id) end,
        },
        {
            what = 'taking part of a reward back',
            setup = function(s, f) return s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'Unpaid debt',
                mode = CB.MODE.EXCLUSIVE,
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
