--- Escrow: validation, atomic take, source-faithful release, double-release
--- guards and the never-destroy-property rule.

describe('escrow validation', function()
    it('accepts a composed reward across every source', function()
        local s = newStack()
        local f = fixture(s)
        local lines, err = s.escrow.validate(f.creator, {
            baseline = {
                cash = 5000, bank = 10000, dirty = 2500,
                items = { { name = 'lockpick', count = 2 } },
                weapons = { { name = 'WEAPON_PISTOL', slot = 3 } },
            },
        })
        truthy(lines, 'expected lines, got err ' .. tostring(err))
        eq(#lines, 5, 'five lines')
    end)

    it('rejects an empty baseline', function()
        local s = newStack()
        local f = fixture(s)
        local lines, err = s.escrow.validate(f.creator, { baseline = {} })
        falsy(lines, 'must not validate')
        eq(err, CH.ERR.INVALID_REWARD)
    end)

    it('rejects more than the creator holds', function()
        local s = newStack()
        local f = fixture(s)
        local lines, err = s.escrow.validate(f.creator, { baseline = { cash = 999999999 } })
        falsy(lines)
        eq(err, CH.ERR.INVALID_REWARD, 'over the per-source cap')

        lines, err = s.escrow.validate(f.creator, { baseline = { cash = 150000 } })
        falsy(lines)
        eq(err, CH.ERR.INSUFFICIENT, 'within cap but more than held')
    end)

    it('rejects negative, fractional and non-numeric amounts', function()
        local s = newStack()
        local f = fixture(s)
        for _, bad in ipairs({ -500, 0.5, 'abc', {}, 1/0 }) do
            local lines = s.escrow.validate(f.creator, { baseline = { cash = bad } })
            falsy(lines, 'accepted a bad amount: ' .. tostring(bad))
        end
    end)

    it('rejects blacklisted items', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1]._inventory[#Env.players[1]._inventory + 1] = { name = 'handcuffs', count = 1 }
        local lines = s.escrow.validate(f.creator, {
            baseline = { items = { { name = 'handcuffs', count = 1 } } },
        })
        falsy(lines, 'handcuffs must never be escrowable')
    end)

    --- On Qbox cash is the ox_inventory item 'money', kept in step with the
    --- balance by the inventory:accounts convar. As an item it went past
    --- Config.Sources.cash, its switch and its ceiling, and onto the board
    --- as goods.
    it('never takes cash as an item, blacklist or no blacklist', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1]._inventory[#Env.players[1]._inventory + 1] =
            { name = 'money', count = 500, slot = 40 }
        withConfig({ { Config, 'EscrowBlacklist', {} } }, function()
            local lines, err = s.escrow.validate(f.creator, {
                baseline = { items = { { name = 'money', count = 100 } } },
            })
            falsy(lines, 'cash went up as goods')
            eq(err, CH.ERR.INVALID_REWARD)
            lines = s.escrow.validate(f.creator, {
                baseline = { items = { { name = 'Money', count = 100 } } },
            })
            falsy(lines, 'nor with a capital letter')
            for _, row in ipairs(s.app.escrowableItems(f.creator)) do
                falsy(row.name == 'money', 'and the picker offered it')
            end
        end)
        withConfig({ { Config.Sources.cash, 'enabled', false } }, function()
            falsy(s.escrow.validate(f.creator, {
                baseline = { items = { { name = 'money', count = 100 } } },
            }), 'a server with cash rewards switched off took cash all the same')
        end)
    end)

    it('refuses every account the server keeps as an item', function()
        local s = newStack()
        local f = fixture(s)
        Natives.convars['inventory:accounts'] = '["money", "casino_chips"]'
        Env.players[1]._inventory[#Env.players[1]._inventory + 1] =
            { name = 'casino_chips', count = 500, slot = 41 }
        falsy(s.escrow.validate(f.creator, {
            baseline = { items = { { name = 'casino_chips', count = 10 } } },
        }), 'an account item named by the convar went up as goods')
        for _, row in ipairs(s.app.escrowableItems(f.creator)) do
            falsy(row.name == 'casino_chips', 'offered: ' .. row.name)
        end
        truthy(s.escrow.validate(f.creator, {
            baseline = { items = { { name = 'lockpick', count = 1 } } },
        }), 'and ordinary goods still go up')
    end)

    it('snapshots weapon metadata rather than referencing a slot', function()
        local s = newStack()
        local f = fixture(s)
        local lines = s.escrow.validate(f.creator, {
            baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } },
        })
        truthy(lines)
        eq(lines[1].metadata.serial, 'ABC123', 'serial captured')
        eq(lines[1].metadata.ammo, 12, 'ammo captured')
    end)

    -- Three payouts, the most Config.Limits.MaxPayoutSlots takes. Ten
    -- stacks on each portion of each is exactly the shipped ceiling of
    -- sixty, so it is brought down to forty here, where the per-payout
    -- limits alone still allow more than it.
    it('caps the total number of escrow lines in one contract', function()
        local s = newStack()
        -- Twenty distinct stacks, enough to build a contract of sixty lines
        -- across three payouts if nothing stopped it.
        local carried = {}
        for i = 1, 20 do
            carried[i] = { name = 'part_' .. i, count = 500, slot = i, label = 'Part ' .. i }
        end
        local f = fixture(s, { creatorInventory = carried })

        local function payoutOf(count)
            local list = {}
            for i = 1, count do list[i] = { name = 'part_' .. i, count = 1 } end
            return { baseline = { items = list } }
        end

        withConfig({ { Config.Limits, 'MaxEscrowLines', 40 } }, function()
            -- Three payouts of ten stacks: thirty lines, inside the ceiling.
            local lines, err = s.escrow.validate(f.creator, {
                slots = { payoutOf(10), payoutOf(10), payoutOf(10) },
            })
            truthy(lines, 'thirty lines should validate, got ' .. tostring(err))
            eq(#lines, 30)

            -- The same again with a bonus portion on each doubles it, and
            -- the per-payout limits alone would allow every one of them.
            local doubled = {}
            for i = 1, 3 do
                doubled[i] = { baseline = payoutOf(10).baseline, bonus = payoutOf(10).baseline }
            end
            lines, err = s.escrow.validate(f.creator, { slots = doubled })
            falsy(lines, 'sixty lines in one contract must be refused over a ceiling of forty')
            eq(err, CH.ERR.INVALID_REWARD)
        end)
    end)

    it('counts a top-up against the lines the contract already holds', function()
        local s = newStack()
        local carried = {}
        for i = 1, 20 do
            carried[i] = { name = 'part_' .. i, count = 500, slot = i, label = 'Part ' .. i }
        end
        local f = fixture(s, { creatorInventory = carried })

        local list = {}
        for i = 1, 10 do list[i] = { name = 'part_' .. i, count = 1 } end
        withConfig({ { Config.Limits, 'MaxEscrowLines', 40 } }, function()
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x',
                reward = { slots = {
                    { baseline = { items = list } }, { baseline = { items = list } },
                    { baseline = { items = list } },
                } },
            })
            truthy(c, 'thirty lines is a legal contract')
            eq(#s.storage.readEscrow(c.id), 30)

            -- Ten more is inside the ceiling; the eleventh set is not.
            truthy(s.amendments.addEscrow(f.creator, c.id, { baseline = { items = list } }),
                'forty lines is still allowed')
            local ok, err = s.amendments.addEscrow(f.creator, c.id,
                { baseline = { items = { { name = 'part_11', count = 1 } } } })
            falsy(ok, 'a top-up must not walk past the ceiling one line at a time')
            eq(err, CH.ERR.INVALID_REWARD)
        end)
    end)

    it('refuses to stage the same physical weapon in two payouts', function()
        local s = newStack()
        local f = fixture(s)
        -- One pistol, named by both payouts. Held-count arithmetic cannot
        -- catch this on its own: the aggregate check counts weapons by name,
        -- and a creator holding two pistols would pass it while both lines
        -- still pointed at the same object.
        local lines, err = s.escrow.validate(f.creator, {
            slots = {
                { baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } } },
                { baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } } },
            },
        })
        falsy(lines, 'one weapon cannot fund two payouts')
        eq(err, CH.ERR.INVALID_REWARD)
    end)

    it('still allows two different weapons across two payouts', function()
        local s = newStack()
        local f = fixture(s, { creatorInventory = {
            { name = 'WEAPON_PISTOL', count = 1, slot = 3, metadata = { serial = 'ABC123' } },
            { name = 'WEAPON_PISTOL', count = 1, slot = 4, metadata = { serial = 'DEF456' } },
        } })
        local lines, err = s.escrow.validate(f.creator, {
            slots = {
                { baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } } },
                { baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 4 } } } },
            },
        })
        truthy(lines, 'expected lines, got err ' .. tostring(err))
        eq(#lines, 2)
        eq(lines[1].inv_slot, 3)
        eq(lines[2].inv_slot, 4)
    end)

    it('rejects funding several slots from one balance', function()
        local s = newStack()
        local f = fixture(s, { creatorCash = 10000 })
        -- Each slot passes on its own; together they exceed the balance.
        local lines, err = s.escrow.validate(f.creator, {
            slots = {
                { baseline = { cash = 6000 } },
                { baseline = { cash = 6000 } },
            },
        })
        falsy(lines, 'aggregate check must catch this')
        eq(err, CH.ERR.INSUFFICIENT)
    end)
end)

describe('escrow take', function()
    it('debits every source and writes the record', function()
        local s = newStack()
        local f = fixture(s)
        local lines = s.escrow.validate(f.creator, {
            baseline = { cash = 5000, bank = 10000, dirty = 2500, items = { { name = 'lockpick', count = 2 } } },
        })
        local ok = s.escrow.take(f.creator, 'ct1', lines)
        truthy(ok)
        eq(Env.players[1].PlayerData.money.cash, 95000, 'cash debited')
        eq(Env.players[1].PlayerData.money.bank, 90000, 'bank debited')
        eq(#s.storage.readEscrow('ct1'), 4, 'four lines stored')
    end)

    it('puts everything back when one debit fails', function()
        local s = newStack()
        local f = fixture(s)
        local lines = {
            { portion = 'baseline', source = 'cash', amount = 5000, slot = 1 },
            { portion = 'baseline', source = 'item', item = 'nonexistent', quantity = 3, slot = 1 },
        }
        local ok, err = s.escrow.take(f.creator, 'ct2', lines)
        falsy(ok, 'must fail')
        eq(err, CH.ERR.INSUFFICIENT)
        eq(Env.players[1].PlayerData.money.cash, 100000, 'cash restored exactly')
        eq(#s.storage.readEscrow('ct2'), 0, 'no partial record')
    end)
end)

describe('escrow release', function()
    local function seed()
        local s = newStack()
        local f = fixture(s)
        local lines = s.escrow.validate(f.creator, {
            baseline = { cash = 5000, items = { { name = 'lockpick', count = 2 } } },
            bonus = { cash = 2500 },
        })
        s.escrow.take(f.creator, 'ct1', lines)
        return s, f
    end

    it('pays the recipient in the sources escrow holds', function()
        local s, f = seed()
        local moved, result = s.escrow.release('ct1', 'HITMAN01', CH.PORTION.BASELINE, 'test')
        truthy(moved)
        eq(result.settled, 2, 'cash line and item line')
        eq(Env.players[3].PlayerData.money.cash, 10000, 'hitman received cash')
    end)

    it('never pays the same line twice', function()
        local s, f = seed()
        s.escrow.release('ct1', 'HITMAN01', CH.PORTION.BASELINE, 'first')
        local moved, result = s.escrow.release('ct1', 'HITMAN01', CH.PORTION.BASELINE, 'second')
        falsy(moved, 'second release must move nothing')
        eq(result.settled, 0)
        eq(Env.players[3].PlayerData.money.cash, 10000, 'balance unchanged by the replay')
    end)

    it('keeps the line owed when delivery fails, rather than destroying it', function()
        local s, f = seed()
        Env.players[3]._inventoryFull = true
        local _, result = s.escrow.release('ct1', 'HITMAN01', CH.PORTION.BASELINE, 'test')
        eq(result.pending, 1, 'the item line could not be delivered')
        eq(result.settled, 1, 'the cash line still settled')

        local line
        for _, l in ipairs(s.storage.readEscrow('ct1')) do
            if l.source == 'item' then line = l end
        end
        eq(line.state, CH.ESCROW_STATE.HELD, 'undelivered line returns to held')
        eq(#s.storage.readPending('HITMAN01'), 1, 'queued for retry')
    end)

    -- ox_inventory's calls are another resource's exports. One that raised
    -- left Escrow.deliver mid-release, so the line sat in `releasing`, owed
    -- to nobody and queued for nobody, until the next restart's recovery.
    it('keeps the line owed when the inventory raises before giving', function()
        local s, f = seed()
        local real = exports.ox_inventory.CanCarryItem
        exports.ox_inventory.CanCarryItem = function() error('CanCarryItem exploded', 0) end
        local ran, moved, result = pcall(s.escrow.release, 'ct1', 'HITMAN01',
            CH.PORTION.BASELINE, 'test')
        exports.ox_inventory.CanCarryItem = real
        truthy(ran, 'a raise in the inventory does not escape the release')
        eq(result.pending, 1, 'nothing was given, so the item line is still owed')

        local line
        for _, l in ipairs(s.storage.readEscrow('ct1')) do
            if l.source == 'item' then line = l end
        end
        eq(line.state, CH.ESCROW_STATE.HELD, 'back in held, not left releasing')
        eq(line.owed_to, 'HITMAN01')
        eq(#s.storage.readPending('HITMAN01'), 1, 'queued for retry')
    end)

    -- An AddItem that raised almost always gave nothing (a hook or a
    -- dependency failing before the item moved). Settled as delivered, the
    -- line was gone for good with nobody owed it; so it stays owed, named.
    it('keeps a line whose give raised owed, and names it', function()
        local s, f = seed()
        local real = exports.ox_inventory.AddItem
        exports.ox_inventory.AddItem = function() error('AddItem exploded', 0) end
        local ran, moved, result = pcall(s.escrow.release, 'ct1', 'HITMAN01',
            CH.PORTION.BASELINE, 'test')
        exports.ox_inventory.AddItem = real
        truthy(ran, 'a raise in the inventory does not escape the release')
        eq(result.pending, 1, 'not delivered: still theirs')

        local line
        for _, l in ipairs(s.storage.readEscrow('ct1')) do
            if l.source == 'item' then line = l end
        end
        eq(line.state, CH.ESCROW_STATE.HELD, 'back in held, neither settled nor left releasing')
        eq(line.owed_to, 'HITMAN01')
        eq(line.deliver_raises, 1, 'the raise is counted on the line')
        eq(#s.storage.readPending('HITMAN01'), 1, 'queued for another try')

        s.audit.flush()
        local named
        for _, row in ipairs(s.storage.readAudit(200)) do
            if row.action == 'escrow_deliver_raised' then named = row end
        end
        truthy(named, 'the line is named for staff')
        eq(named.detail.line, line.id)
        eq(named.detail.raises, 1)
        eq(named.detail.arrived, 0, 'checked: nothing arrived')

        -- The hook recovers: the next try gives it, once.
        eq(s.escrow.retryPending('HITMAN01'), 1, 'delivered on the next try')
        eq(s.storage.readEscrowLine(line.id).state, CH.ESCROW_STATE.SETTLED)
        local picks = 0
        for _, slot in ipairs(Env.players[3]._inventory) do
            if slot.name == 'lockpick' then picks = picks + slot.count end
        end
        eq(picks, 2, 'one lot of lockpicks, not two')
    end)

    --- How many lockpicks the hitman holds, in every slot.
    local function picks()
        local n = 0
        for _, slot in ipairs(Env.players[3]._inventory) do
            if slot.name == 'lockpick' then n = n + slot.count end
        end
        return n
    end

    --- The item line of a contract, as stored.
    local function itemLine(s, contractId)
        for _, l in ipairs(s.storage.readEscrow(contractId)) do
            if l.source == 'item' then return l end
        end
    end

    --- Run fn with ox_inventory's AddItem replaced, put back however fn ends.
    local function withAddItem(give, fn)
        local real = exports.ox_inventory.AddItem
        exports.ox_inventory.AddItem = function(self, ...) return give(real, self, ...) end
        local ok, err = pcall(fn)
        exports.ox_inventory.AddItem = real
        truthy(ok, tostring(err))
    end

    --- ox_inventory places the item and only then syncs, and the sync can
    --- raise. Retried, that gave it again on every try; it is delivered.
    it('delivers a give that raised after the item arrived, once', function()
        local s = seed()
        local calls = 0
        withAddItem(function(real, self, ...)
            calls = calls + 1
            real(self, ...)
            error('sync raised after the give', 0)
        end, function()
            local _, result = s.escrow.release('ct1', 'HITMAN01', CH.PORTION.BASELINE, 'test')
            eq(result.settled, 2, 'the cash line and the item line, both delivered')
            eq(result.pending, 0, 'nothing left owed')
            for _ = 1, 5 do s.escrow.retryPending('HITMAN01') end
        end)
        eq(calls, 1, 'given once and never tried again')
        eq(picks(), 2, 'one lot of lockpicks')
        local line = itemLine(s, 'ct1')
        eq(line.state, CH.ESCROW_STATE.SETTLED, 'settled as delivered')
        falsy(s.escrow.parked(line), 'nothing for staff to do')
        eq(#s.storage.readPending('HITMAN01'), 0)

        s.audit.flush()
        local named
        for _, row in ipairs(s.storage.readAudit(200)) do
            if row.action == 'escrow_deliver_raised' then named = row end
        end
        truthy(named, 'the raise is still written down')
        eq(named.detail.arrived, 2, 'with what arrived')
    end)

    --- Left for staff after raising before the give, then paid by staff
    --- with a give that raises after: given once, by the pay, and settled.
    --- /ch-settle pay starts the count again, which gave a fresh round of
    --- copies while a raise after the give was retried.
    it('leaves a line for staff after its give raised the limit with nothing arriving, '
        .. 'and a staff pay gives it once', function()
        -- A contract id long enough for /ch-settle to take its line ids.
        local s = newStack()
        local f = fixture(s)
        s.escrow.take(f.creator, 'ctparked01', s.escrow.validate(f.creator, {
            baseline = { cash = 5000, items = { { name = 'lockpick', count = 2 } } },
        }))
        local limit = s.escrow.DELIVER_RAISE_LIMIT
        truthy(limit >= 2 and limit <= 5, 'a small constant')
        local before = 0
        withAddItem(function()
            before = before + 1
            error('hook raised before the give', 0)
        end, function()
            s.escrow.release('ctparked01', 'HITMAN01', CH.PORTION.BASELINE, 'test')
            for _ = 1, limit + 5 do s.escrow.retryPending('HITMAN01') end
        end)
        eq(before, limit, 'tried until the limit, then never again')
        eq(picks(), 0, 'nothing arrived')

        local line = itemLine(s, 'ctparked01')
        truthy(s.escrow.parked(line), 'left for staff')
        eq(line.state, CH.ESCROW_STATE.HELD, 'still held, nothing destroyed')
        eq(line.owed_to, 'HITMAN01', 'and still theirs')
        eq(#s.storage.readPending('HITMAN01'), 0, 'off the retry queue')
        -- Nor queued again by the recovery at the next start.
        eq(s.escrow.recoverOwed(s.storage.readEscrow('ctparked01')), 0, 'recovery leaves it for staff')
        eq(#s.storage.readPending('HITMAN01'), 0)

        s.audit.flush()
        local parkedRow
        for _, row in ipairs(s.storage.readAudit(500)) do
            if row.action == 'escrow_deliver_parked' then parkedRow = row end
        end
        truthy(parkedRow, 'a row says it waits for staff')
        eq(parkedRow.detail.line, line.id)

        -- /ch-stuck lists it, with who it is owed to and how often it raised.
        local listed
        for _, row in ipairs(s.admin.interrupted(0)) do
            if row.line == line.id then listed = row end
        end
        truthy(listed, '/ch-stuck shows it')
        eq(listed.raised, limit)
        eq(listed.intended, 'HITMAN01')

        -- Staff checked: it is not there, so they pay it. The give raises
        -- after the item arrives, and the count has just started again.
        local after = 0
        withAddItem(function(real, self, ...)
            after = after + 1
            real(self, ...)
            error('sync raised after the give', 0)
        end, function()
            local settled, why = s.admin.settleLine(0, line.id, 'pay')
            truthy(settled, tostring(why))
            eq(why, nil, 'delivered, not queued')
            for _ = 1, 5 do s.escrow.retryPending('HITMAN01') end
            s.escrow.release('ctparked01', 'HITMAN01', nil, 'sweep')
            local again = s.admin.settleLine(0, line.id, 'pay')
            falsy(again, 'and a second pay finds it settled')
        end)
        eq(after, 1, 'given once by the pay')
        eq(picks(), 2, 'one lot of lockpicks, not one per try')
        eq(s.storage.readEscrowLine(line.id).state, CH.ESCROW_STATE.SETTLED)
        local still = 0
        for _, row in ipairs(s.admin.interrupted(0)) do
            if row.line == line.id then still = still + 1 end
        end
        eq(still, 0, 'and gone from /ch-stuck')
    end)

    --- A raise whose outcome cannot be read: neither delivered nor tried
    --- again, but left for staff at once.
    it('leaves a line for staff at once when whether its give arrived cannot be read', function()
        local s = newStack()
        local f = fixture(s)
        s.escrow.take(f.creator, 'ctunknown1', s.escrow.validate(f.creator, {
            baseline = { cash = 5000, items = { { name = 'lockpick', count = 2 } } },
        }))
        local realCount = exports.ox_inventory.GetItemCount
        local reads, gives = 0, 0
        exports.ox_inventory.GetItemCount = function(...)
            reads = reads + 1
            -- What they held before reads; the check after the raise does not.
            if reads % 2 == 0 then error('GetItemCount raised', 0) end
            return realCount(...)
        end
        withAddItem(function(real, self, ...)
            gives = gives + 1
            real(self, ...)
            error('sync raised after the give', 0)
        end, function()
            local _, result = s.escrow.release('ctunknown1', 'HITMAN01', CH.PORTION.BASELINE, 'test')
            eq(result.pending, 1, 'not delivered: it cannot be told whether it was')
            eq(result.parked, 1, 'and left for staff')
            for _ = 1, 5 do s.escrow.retryPending('HITMAN01') end
        end)
        exports.ox_inventory.GetItemCount = realCount
        eq(gives, 1, 'given once and never tried again blind')

        local line = itemLine(s, 'ctunknown1')
        truthy(s.escrow.parked(line), 'left for staff on the first raise')
        eq(line.state, CH.ESCROW_STATE.HELD)
        eq(line.owed_to, 'HITMAN01')
        eq(#s.storage.readPending('HITMAN01'), 0, 'not queued for another try')

        s.audit.flush()
        local parkedRow
        for _, row in ipairs(s.storage.readAudit(500)) do
            if row.action == 'escrow_deliver_parked' then parkedRow = row end
        end
        truthy(parkedRow and parkedRow.detail.unknown, 'the row says the outcome is unknown')
        local listed
        for _, row in ipairs(s.admin.interrupted(0)) do
            if row.line == line.id then listed = row end
        end
        truthy(listed, '/ch-stuck shows it')
    end)

    it('leaves a line for staff at once when only part of it arrived', function()
        local s = seed()
        local gives = 0
        withAddItem(function(real, self, src, name, count, metadata)
            gives = gives + 1
            real(self, src, name, count - 1, metadata)
            error('raised half-way', 0)
        end, function()
            local _, result = s.escrow.release('ct1', 'HITMAN01', CH.PORTION.BASELINE, 'test')
            eq(result.parked, 1, 'part of it is there, so it cannot be given again')
            for _ = 1, 5 do s.escrow.retryPending('HITMAN01') end
        end)
        eq(gives, 1)
        truthy(s.escrow.parked(itemLine(s, 'ct1')), 'left for staff')
    end)

    --- The part that arrived is kept on the line, and a staff pay gives only
    --- the rest: paying the whole line again gave 3 of 2 lockpicks.
    it('gives only what had not arrived when staff pay a line part of which did', function()
        local s = newStack()
        local f = fixture(s)
        s.escrow.take(f.creator, 'ctpartly01', s.escrow.validate(f.creator, {
            baseline = { cash = 5000, items = { { name = 'lockpick', count = 2 } } },
        }))
        withAddItem(function(real, self, src, name, count, metadata)
            real(self, src, name, count - 1, metadata)
            error('raised half-way', 0)
        end, function()
            s.escrow.release('ctpartly01', 'HITMAN01', CH.PORTION.BASELINE, 'test')
            for _ = 1, 3 do s.escrow.retryPending('HITMAN01') end
        end)
        eq(picks(), 1, 'one of the two arrived')
        local line = itemLine(s, 'ctpartly01')
        truthy(s.escrow.parked(line), 'left for staff')
        eq(tonumber(line.deliver_arrived), 1, 'with the one that arrived')
        eq(tonumber(line.deliver_before), 0, 'and what they held before')

        local gave
        withAddItem(function(real, self, src, name, count, metadata)
            gave = count
            return real(self, src, name, count, metadata)
        end, function()
            truthy(s.admin.settleLine(0, line.id, 'pay'))
        end)
        eq(gave, 1, 'the pay gave the one still owed')
        eq(picks(), 2, 'two lockpicks, not three')
        eq(s.storage.readEscrowLine(line.id).state, CH.ESCROW_STATE.SETTLED)
    end)

    --- A weapon is checked by its serial, so it is the line's own pistol.
    it('delivers a weapon whose give raised after it arrived, once, found by its serial', function()
        local s = newStack()
        local f = fixture(s)
        s.escrow.take(f.creator, 'ct9', s.escrow.validate(f.creator, {
            baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } },
        }))
        -- The hitman already carries another pistol: a count by name alone
        -- is not what decides.
        table.insert(Env.players[3]._inventory,
            { name = 'WEAPON_PISTOL', count = 1, slot = 7, metadata = { serial = 'OTHER9' } })
        local gives = 0
        withAddItem(function(real, self, ...)
            gives = gives + 1
            real(self, ...)
            error('sync raised after the give', 0)
        end, function()
            local _, result = s.escrow.release('ct9', 'HITMAN01', CH.PORTION.BASELINE, 'test')
            eq(result.settled, 1, 'delivered')
            for _ = 1, 5 do s.escrow.retryPending('HITMAN01') end
        end)
        eq(gives, 1, 'given once')
        local serials = {}
        for _, slot in ipairs(Env.players[3]._inventory) do
            if slot.name == 'WEAPON_PISTOL' then
                serials[#serials + 1] = slot.metadata and slot.metadata.serial
            end
        end
        table.sort(serials)
        eq(table.concat(serials, ','), 'ABC123,OTHER9', 'the escrowed pistol once, beside their own')
    end)

    it('delivers queued escrow on the next login', function()
        local s, f = seed()
        Env.players[3]._inventoryFull = true
        s.escrow.release('ct1', 'HITMAN01', CH.PORTION.BASELINE, 'test')
        Env.players[3]._inventoryFull = false

        local delivered = s.escrow.retryPending('HITMAN01')
        eq(delivered, 1, 'the owed item is delivered')
        eq(s.escrow.retryPending('HITMAN01'), 0, 'and not delivered twice')
    end)

    it('restores a weapon with its original metadata', function()
        local s = newStack()
        local f = fixture(s)
        local lines = s.escrow.validate(f.creator, {
            baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } },
        })
        s.escrow.take(f.creator, 'ct9', lines)
        s.escrow.release('ct9', 'CREATOR1', nil, 'refund')

        local restored
        for _, slot in ipairs(Env.players[1]._inventory) do
            if slot.name == 'WEAPON_PISTOL' and slot.metadata then restored = slot end
        end
        truthy(restored, 'weapon returned')
        eq(restored.metadata.serial, 'ABC123', 'serial survived the round trip')
    end)
end)

describe('escrow top-ups', function()
    it('appends to existing escrow instead of overwriting it', function()
        local s = newStack()
        local f = fixture(s)
        local first = s.escrow.validate(f.creator, { baseline = { cash = 5000 } })
        s.escrow.take(f.creator, 'ct1', first)
        eq(s.escrow.moneyValue('ct1'), 5000)

        local second = s.escrow.validate(f.creator, { baseline = { cash = 1000 } })
        s.escrow.take(f.creator, 'ct1', second)
        eq(s.escrow.moneyValue('ct1'), 6000, 'the original line must survive a top-up')
        eq(#s.storage.readEscrow('ct1'), 2, 'two distinct lines')
    end)

    it('refunds a topped-up contract in full', function()
        local s = newStack()
        local f = fixture(s)
        local start = Env.players[1].PlayerData.money.cash
        s.escrow.take(f.creator, 'ct1', s.escrow.validate(f.creator, { baseline = { cash = 5000 } }))
        s.escrow.take(f.creator, 'ct1', s.escrow.validate(f.creator, { baseline = { cash = 1000 } }))
        s.escrow.release('ct1', 'CREATOR1', nil, 'refund')
        eq(Env.players[1].PlayerData.money.cash, start, 'every line returned')
    end)
end)

describe('a form that sends every field still works', function()
    --- A web form sends all of its inputs, blank ones included. Treating a
    --- zero as a rejection rather than as "not selected" made every single
    --- contract creation fail while every unit test passed, because the
    --- tests hand-built payloads containing only the sources they meant.

    it('accepts a submission carrying zeroed sources alongside a funded one', function()
        local s = newStack()
        local f = fixture(s)
        local lines, err = s.escrow.validate(f.creator, {
            slots = { { baseline = { cash = 5000, bank = 0, dirty = 0 } } },
        })
        truthy(lines, 'zeroed fields must not reject the contract: ' .. tostring(err))
        eq(#lines, 1, 'and only the funded source is escrowed')
        eq(lines[1].source, 'cash')
    end)

    it('still rejects a submission where every source is zero', function()
        local s = newStack()
        local f = fixture(s)
        local lines, err = s.escrow.validate(f.creator, {
            slots = { { baseline = { cash = 0, bank = 0, dirty = 0 } } },
        })
        falsy(lines, 'a contract offering nothing is not a contract')
        eq(err, CH.ERR.INVALID_REWARD)
    end)

    it('creates a contract end to end from a form-shaped payload', function()
        local s = newStack()
        local f = fixture(s)
        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.EXCLUSIVE,
            reward = { slots = {
                { baseline = { cash = 5000, bank = 0, dirty = 0 } },
                { baseline = { cash = 0, bank = 2500, dirty = 0 } },
            } },
            bonusPercent = 50, bailoutAmount = 0, penaltyAmount = 0,
        })
        truthy(c, 'the app must be able to place a contract: ' .. tostring(err))
        eq(c.payout_slots, 2)
        -- 7500 baseline plus the 50% live-delivery bonus, escrowed up front.
        eq(s.escrow.moneyValue(c.id), 11250)
        eq(s.escrow.moneyValue(c.id, CH.PORTION.BONUS), 3750)
    end)
end)

describe('money owed to a player is reachable only by them', function()
    local function owedToHitman()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { items = { { name = 'lockpick', count = 2 } } } },
        })
        s.contracts.accept(f.hitman, c.id, false)

        -- The hitman earns it but cannot carry it.
        Env.players[3]._inventoryFull = true
        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        return s, f, c
    end

    it('marks an undeliverable payout as the hitmen', function()
        local s, f, c = owedToHitman()
        local owed
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.owed_to then owed = line end
        end
        truthy(owed, 'the payout should be recorded as owed')
        eq(owed.owed_to, 'HITMAN01')
    end)

    it('does not hand it to the creator when the contract closes', function()
        local s, f, c = owedToHitman()
        eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED,
            'a single-slot contract is finished')

        local creatorHas = 0
        for _, slot in ipairs(Env.players[1]._inventory) do
            if slot.name == 'lockpick' then creatorHas = creatorHas + slot.count end
        end
        eq(creatorHas, 3, 'the creator keeps only the 3 they started with')
    end)

    it('delivers it to the hitman when they can carry it', function()
        local s, f, c = owedToHitman()
        Env.players[3]._inventoryFull = false
        eq(s.escrow.retryPending('HITMAN01'), 1)

        local hitmanHas = 0
        for _, slot in ipairs(Env.players[3]._inventory) do
            if slot.name == 'lockpick' then hitmanHas = hitmanHas + slot.count end
        end
        eq(hitmanHas, 2, 'what they earned arrives when there is room for it')
    end)

    --- A queue that begins with more goods than one pass tries, none of
    --- which fit, and money behind them.
    local function queuedBehindGoods()
        local s = newStack()
        local names = {}
        local inventory = {}
        for i = 1, Config.PendingEscrow.MaxRetriesPerLogin + 1 do
            names[i] = 'goods' .. i
            inventory[i] = { name = names[i], count = 1 }
        end
        local f = fixture(s, { creatorInventory = inventory })
        local items = {}
        for i = 1, #names do items[i] = { name = names[i], count = 1 } end
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { items = items } },
        })
        truthy(c, 'placed')
        s.contracts.accept(f.hitman, c.id, false)
        Env.players[3]._inventoryFull = true
        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        eq(#s.storage.readPending('HITMAN01'), #names, 'every stack owed')
        truthy(s.bailout.owe('HITMAN01', c.id, 4000, 'bank', 'test'))
        return s, f, c
    end

    it('keeps trying, while they are online, what a login could not hand over', function()
        local s = queuedBehindGoods()
        -- A fresh process: nothing it queued, so nothing it is waiting on.
        s.escrow.init(s.storage, s.audit)
        s.escrow.retryPending('HITMAN01')
        Env.players[3]._inventoryFull = false
        local total = 0
        for _ = 1, 4 do
            Env.advance(31)
            for _, n in pairs(s.escrow.retryWaiting(function() return true end)) do
                total = total + n
            end
        end
        eq(#s.storage.readPending('HITMAN01'), 0,
            'made room, stayed online, and nothing arrived until a relog')
        truthy(total > 0)
    end)

    it('refuses to deliver it to anyone else', function()
        local s, f, c = owedToHitman()
        Env.players[1]._inventoryFull = false
        s.escrow.release(c.id, 'CREATOR1', nil, 'a general sweep')
        eq(s.escrow.retryPending('CREATOR1'), 0, 'not the creator\'s to collect')
        eq(#s.storage.readPending('HITMAN01'), 1, 'still owed to the hitman')
    end)
end)


--- Items are not interchangeable because they share a name.
---
--- Exposing items in the reward builder made this reachable: escrow took a
--- worn repair kit and handed back a fresh one, and took a loaded backpack
--- and handed back an empty one with a new container id. The first mints
--- value, the second destroys it, and both break the invariant this whole
--- resource is built on.
describe('item instances', function()
    local function carrying(inventory)
        local s = newStack()
        local f = fixture(s, { creatorInventory = inventory })
        return s, f
    end

    it('snapshots what was actually in the slot', function()
        local s, f = carrying({
            { name = 'repairkit', count = 1, slot = 1, label = 'Repair Kit',
              metadata = { durability = 11 } },
        })
        local lines, err = s.escrow.validate(f.creator, {
            baseline = { items = { { name = 'repairkit', count = 1 } } },
        })
        truthy(lines, tostring(err))
        eq(lines[1].metadata.durability, 11,
            'the worn kit, not the idea of a repair kit')
        eq(lines[1].inv_slot, 1, 'and where it came from')
    end)

    it('gives back the same instance it took', function()
        local s, f = carrying({
            { name = 'repairkit', count = 1, slot = 1, label = 'Repair Kit',
              metadata = { durability = 11 } },
        })
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { items = { { name = 'repairkit', count = 1 } } } },
        })
        truthy(c)

        -- Gone from the creator while it is escrowed.
        eq(exports.ox_inventory:GetItem(1, 'repairkit', nil, true), 0)

        truthy(s.contracts.resolve(c.id, CH.STATE.CANCELLED, f.creator.cid, nil, 'cancelled'))

        local returned
        for _, slot in ipairs(Env.players[1]._inventory) do
            if slot.name == 'repairkit' and slot.count > 0 then returned = slot end
        end
        truthy(returned, 'the kit comes back')
        eq(returned.metadata.durability, 11,
            'at the durability it had — a stage-and-cancel loop must not repair it')
    end)

    it('does not orphan what a container was holding', function()
        local s, f = carrying({
            { name = 'backpack', count = 1, slot = 1, label = 'Backpack',
              metadata = { container = 'bp-1234' } },
        })
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { items = { { name = 'backpack', count = 1 } } } },
        })
        truthy(c)
        truthy(s.contracts.resolve(c.id, CH.STATE.CANCELLED, f.creator.cid, nil, 'cancelled'))

        local returned
        for _, slot in ipairs(Env.players[1]._inventory) do
            if slot.name == 'backpack' and slot.count > 0 then returned = slot end
        end
        truthy(returned, 'the bag comes back')
        eq(returned.metadata.container, 'bp-1234',
            'still the same bag — a new container id orphans everything in it')
    end)

    it('takes the slot it staged, not any stack of the name', function()
        local s, f = carrying({
            { name = 'repairkit', count = 1, slot = 1, metadata = { durability = 11 } },
            { name = 'repairkit', count = 1, slot = 2, metadata = { durability = 96 } },
        })
        local lines = s.escrow.validate(f.creator, {
            baseline = { items = { { name = 'repairkit', count = 1 } } },
        })
        truthy(lines)
        truthy(s.escrow.take(f.creator, 'ct_probe', lines))

        -- The other kit is untouched, whichever one was staged.
        local left = {}
        for _, slot in ipairs(Env.players[1]._inventory) do
            if slot.name == 'repairkit' and slot.count > 0 then
                left[#left + 1] = slot.metadata.durability
            end
        end
        eq(#left, 1, 'one kit left')
        truthy(left[1] ~= lines[1].metadata.durability,
            'and it is the one that was not staked')
    end)

    it('splits a request across the slots it actually draws from', function()
        local s, f = carrying({
            { name = 'bandage', count = 2, slot = 1, metadata = { source = 'ems' } },
            { name = 'bandage', count = 3, slot = 2, metadata = { source = 'store' } },
        })
        local lines, err = s.escrow.validate(f.creator, {
            baseline = { items = { { name = 'bandage', count = 4 } } },
        })
        truthy(lines, tostring(err))
        eq(#lines, 2, 'one line per slot drawn from')
        eq(lines[1].quantity + lines[2].quantity, 4, 'four bandages in total')
        truthy(lines[1].metadata.source ~= lines[2].metadata.source,
            'each remembering its own instance')
    end)

    it('refuses a weapon smuggled through the item list', function()
        local s = newStack()
        local f = fixture(s)
        -- The picker sends weapons separately, so this is a hand-written
        -- payload. Through the item path a weapon is stored as a bare name
        -- and handed back clean: attachments destroyed, serial laundered.
        for _, name in ipairs({ 'WEAPON_PISTOL', 'weapon_pistol', 'Weapon_Pistol' }) do
            local lines, err = s.escrow.validate(f.creator, {
                baseline = { items = { { name = name, count = 1 } } },
            })
            falsy(lines, name .. ' must not escrow as an item')
            eq(err, CH.ERR.INVALID_REWARD)
        end
    end)

    it('still escrows a weapon properly through its own path', function()
        local s = newStack()
        local f = fixture(s)
        local lines = s.escrow.validate(f.creator, {
            baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } },
        })
        truthy(lines, 'the weapon path is unaffected')
        eq(lines[1].metadata.serial, 'ABC123')
    end)

    it('carries the metadata through storage in every backend', function()
        local Exec = require('tests.harness.mysql_exec')
        for _, name in ipairs({ 'memory', 'json', 'mysql' }) do
            local store
            if name == 'mysql' then
                Exec.install(Natives)
                package.loaded['crimson-hitman.server.storage.mysql'] = nil
                store = require('crimson-hitman.server.storage.mysql')
            else
                package.loaded['crimson-hitman.server.storage.' .. name] = nil
                Natives.files = {}
                store = require('crimson-hitman.server.storage.' .. name)
            end
            store.open()

            store.writeEscrow('ct1', { {
                id = 'ct1:1', contract_id = 'ct1', slot = 1, portion = 'baseline',
                source = CH.SOURCE.ITEM, item = 'repairkit', quantity = 1,
                state = CH.ESCROW_STATE.HELD, inv_slot = 1,
                metadata = { durability = 11 },
            } })

            local read = store.readEscrowLine('ct1:1')
            truthy(read, name .. ': line not found')
            truthy(read.metadata, name .. ': metadata must survive the round trip')
            eq(read.metadata.durability, 11, name)
        end
    end)
end)


--- Four bugs review found, each with no test until now.
describe('the authority is the server, not the picker', function()
    it('honours the item kill switch on a hand-written payload', function()
        local s = newStack()
        local f = fixture(s)
        withConfig({ { Config.Sources.item, 'enabled', false } }, function()
            eq(#s.app.escrowableItems(f.creator), 0, 'the picker offers nothing')
            local lines, err, refusal = s.escrow.validate(f.creator, {
                baseline = { items = { { name = 'lockpick', count = 1 } } },
            })
            falsy(lines, 'and a payload sent by hand is refused too')
            -- Said as the source switched off, by name (the page words it).
            eq(err, CH.ERR.SOURCE_DISABLED)
            eq(refusal and refusal.source, 'item')
        end)
    end)

    it('honours the weapon kill switch on a hand-written payload', function()
        local s = newStack()
        local f = fixture(s)
        withConfig({ { Config.Sources.weapon, 'enabled', false } }, function()
            eq(#s.app.escrowableWeapons(f.creator), 0)
            local lines, err, refusal = s.escrow.validate(f.creator, {
                baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } },
            })
            falsy(lines, 'a switch only the UI honours is not a switch')
            eq(err, CH.ERR.SOURCE_DISABLED)
            eq(refusal and refusal.source, 'weapon')
        end)
    end)

    it('stakes the weapon that was picked, not one that shares its name', function()
        local s = newStack()
        local f = fixture(s, { creatorInventory = {
            { name = 'WEAPON_PISTOL', count = 1, slot = 3,
              metadata = { serial = 'PLAIN1' } },
            { name = 'WEAPON_PISTOL', count = 1, slot = 4,
              metadata = { serial = 'KITTED', components = { 'suppressor' } } },
        } })

        local lines = s.escrow.validate(f.creator, {
            baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 4 } } },
        })
        truthy(lines)
        eq(lines[1].metadata.serial, 'KITTED', 'the one they chose')
    end)

    it('refuses a weapon slot the creator does not hold', function()
        local s = newStack()
        local f = fixture(s)
        -- Slot 3 is the pistol; slot 9 is nothing. This used to fall back to
        -- "the first weapon of that name", staking an object the creator
        -- never picked.
        local lines, err = s.escrow.validate(f.creator, {
            baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 9 } } },
        })
        falsy(lines, 'a slot they do not hold is not a near-enough answer')
        eq(err, CH.ERR.INSUFFICIENT)
    end)
end)

describe('ids the rest of the resource will accept', function()
    local Util = require('crimson-hitman.shared.util')

    it('mints ids every handler accepts, whatever the clock says', function()
        local Exec = require('tests.harness.mysql_exec')
        Exec.install(Natives)
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local store = require('crimson-hitman.server.storage.mysql')
        store.open()

        -- The clock component is taken modulo 100000, so it is a single
        -- digit for ten seconds out of every twenty-eight hours. Unpadded,
        -- every contract minted in that window had an id Util.toId refuses
        -- as malformed, and nothing could act on it.
        local realTime = os.time
        for _, moment in ipairs({ 0, 5, 99, 1234, 99999 }) do
            os.time = function() return moment end
            local id = store.nextId('ct')
            os.time = realTime
            truthy(Util.toId(id),
                ('id %q minted at clock %d is rejected by every handler'):format(id, moment))
        end
    end)

    it('agrees with the other backends on what an id looks like', function()
        for _, name in ipairs({ 'memory', 'json' }) do
            package.loaded['crimson-hitman.server.storage.' .. name] = nil
            Natives.files = {}
            local store = require('crimson-hitman.server.storage.' .. name)
            store.open()
            truthy(Util.toId(store.nextId('ct')), name)
        end
    end)
end)

describe('a hitman who cannot afford anonymity', function()
    it('is recorded as named in every backend', function()
        local Exec = require('tests.harness.mysql_exec')
        for _, name in ipairs({ 'memory', 'json', 'mysql' }) do
            local store
            if name == 'mysql' then
                Exec.install(Natives)
                package.loaded['crimson-hitman.server.storage.mysql'] = nil
                store = require('crimson-hitman.server.storage.mysql')
            else
                package.loaded['crimson-hitman.server.storage.' .. name] = nil
                Natives.files = {}
                store = require('crimson-hitman.server.storage.' .. name)
            end
            store.open()

            store.addHitman({ id = 'h1', contract_id = 'ct1', hitman_cid = 'HITMAN01',
                              hitman_name = 'Rook Ash', alias = 'Operative #1',
                              anon = true, state = 'active', accepted_at = 1, claims = 0 })

            -- They could not cover the fee, so they are simply named.
            truthy(store.updateHitman('h1', { anon = false }), name)
            eq(store.readHitman('ct1', 'HITMAN01').anon, false,
                name .. ': a hitman who paid nothing must not stay anonymous')
        end
    end)
end)


--- Two takes on one contract must not collide.
---
--- Escrow line ids are allocated from the lines the contract already has,
--- and reading those yields on a real database. Two takes can therefore
--- allocate the same ids, and the second one's lines are merged into the
--- first's rather than stored — with the money for them already gone.
describe('concurrent escrow takes', function()
    it('refuses rather than charging for escrow that does not exist', function()
        local s = newCopyingStack()
        local f = fixture(s)

        local first = s.escrow.validate(f.creator, { baseline = { cash = 1000 } })
        local second = s.escrow.validate(f.creator, { baseline = { cash = 2000 } })
        truthy(first and second)

        truthy(s.escrow.take(f.creator, 'ct_race', first), 'the first take lands')

        -- The second take reads the contract as it was before the first
        -- wrote, which is exactly what a yielding read gives you when two
        -- of them overlap. It then allocates ids that are already taken.
        local realRead = s.storage.readEscrow
        local stale = true
        s.storage.readEscrow = function(id, ...)
            if stale and id == 'ct_race' then
                stale = false
                return {}
            end
            return realRead(id, ...)
        end

        local before = Env.players[1].PlayerData.money.cash
            + Env.players[1].PlayerData.money.bank
        local ok, err = s.escrow.take(f.creator, 'ct_race', second)
        s.storage.readEscrow = realRead

        falsy(ok, 'a take whose lines did not store must not report success')
        eq(err, CH.ERR.LOCKED)

        local after = Env.players[1].PlayerData.money.cash
            + Env.players[1].PlayerData.money.bank
        eq(after, before, 'and the creator is not charged for it')
    end)

    it('leaves the first take untouched', function()
        local s = newCopyingStack()
        local f = fixture(s)

        local first = s.escrow.validate(f.creator, { baseline = { cash = 1000 } })
        truthy(s.escrow.take(f.creator, 'ct_race', first))

        local second = s.escrow.validate(f.creator, { baseline = { cash = 2000 } })

        local realRead = s.storage.readEscrow
        local stale = true
        s.storage.readEscrow = function(id, ...)
            if stale and id == 'ct_race' then stale = false return {} end
            return realRead(id, ...)
        end
        s.escrow.take(f.creator, 'ct_race', second)
        s.storage.readEscrow = realRead

        local lines = s.storage.readEscrow('ct_race')
        eq(#lines, 1, 'one line, from the take that won')
        eq(lines[1].amount, 1000, 'and it still holds what it held')
    end)

    it('still takes two escrows that do not collide', function()
        local s = newCopyingStack()
        local f = fixture(s)

        local first = s.escrow.validate(f.creator, { baseline = { cash = 1000 } })
        truthy(s.escrow.take(f.creator, 'ct_ok', first))

        local second = s.escrow.validate(f.creator, { baseline = { cash = 2000 } })
        truthy(s.escrow.take(f.creator, 'ct_ok', second),
            'an ordinary top-up must not be caught by the collision guard')
        eq(#s.storage.readEscrow('ct_ok'), 2)
    end)
end)


--- The picker's data is a snapshot, and an inventory moves.
---
--- The wallet is read when the Place tab opens and not again until a
--- contract is placed, so the slot a weapon was picked at can be stale by
--- the time it is submitted. Substituting whatever weapon happens to share
--- the name means the creator loses one they never offered.
describe('a weapon slot that has moved', function()
    it('refuses rather than staking a weapon the creator did not pick', function()
        local s = newStack()
        local f = fixture(s, { creatorInventory = {
            { name = 'WEAPON_PISTOL', count = 1, slot = 3,
              metadata = { serial = 'MODDED', components = { 'suppressor' } } },
            { name = 'WEAPON_PISTOL', count = 1, slot = 9,
              metadata = { serial = 'BEATUP' } },
        } })

        -- They picked the beat-up one at slot 9; by submit it has moved.
        local lines, err = s.escrow.validate(f.creator, {
            baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 4 } } },
        })
        falsy(lines, 'a slot nothing sits in is not an invitation to substitute')
        eq(err, CH.ERR.INSUFFICIENT)

        -- And the modded one is still theirs.
        local held = 0
        for _, slot in ipairs(Env.players[1]._inventory) do
            if slot.name == 'WEAPON_PISTOL' then held = held + 1 end
        end
        eq(held, 2, 'nothing left their pockets')
    end)

    it('takes the one that is still where it was', function()
        local s = newStack()
        local f = fixture(s, { creatorInventory = {
            { name = 'WEAPON_PISTOL', count = 1, slot = 3, metadata = { serial = 'MODDED' } },
            { name = 'WEAPON_PISTOL', count = 1, slot = 9, metadata = { serial = 'BEATUP' } },
        } })
        local lines = s.escrow.validate(f.creator, {
            baseline = { weapons = { { name = 'WEAPON_PISTOL', slot = 9 } } },
        })
        truthy(lines)
        eq(lines[1].metadata.serial, 'BEATUP', 'the one they picked, and only that')
    end)
end)


--- Items are taken from named inventory slots, and validation runs before
--- anything is taken. Weapons already guard against staging one slot twice
--- (a weapon is one physical object); item stacks are the same object with a
--- count on it, and had no such guard.
describe('staging the same item stack twice', function()
    --- Two stacks of one item, distinguishable only by what is in them.
    local function twoStacks(s)
        return fixture(s, { creatorInventory = {
            { name = 'repairkit', count = 10, slot = 5, metadata = { durability = 50 } },
            { name = 'repairkit', count = 10, slot = 9, metadata = { durability = 100 } },
        } })
    end

    it('draws the second payout from the second stack, not the first again', function()
        local s = newStack()
        local f = twoStacks(s)

        local lines, err = s.escrow.validate(f.creator, {
            slots = {
                { baseline = { items = { { name = 'repairkit', count = 10 } } } },
                { baseline = { items = { { name = 'repairkit', count = 10 } } } },
            },
        })
        truthy(lines, 'twenty held and twenty asked for: ' .. tostring(err))
        eq(#lines, 2)

        local from = {}
        for i = 1, #lines do from[#from + 1] = lines[i].inv_slot end
        table.sort(from)
        eq(from[1], 5)
        eq(from[2], 9, 'the second payout must come from the stack the first did not empty')
    end)

    it('snapshots what each stack actually holds', function()
        local s = newStack()
        local f = twoStacks(s)

        local lines = s.escrow.validate(f.creator, {
            slots = {
                { baseline = { items = { { name = 'repairkit', count = 10 } } } },
                { baseline = { items = { { name = 'repairkit', count = 10 } } } },
            },
        })
        truthy(lines)

        local seen = {}
        for i = 1, #lines do seen[lines[i].metadata.durability] = true end
        truthy(seen[50] and seen[100],
            'both stacks were escrowed, so both durabilities must be recorded — '
            .. 'otherwise one of them is handed back as a copy of the other')
    end)

    it('actually takes both stacks rather than rolling the contract back', function()
        local s = newStack()
        local f = twoStacks(s)

        local lines = s.escrow.validate(f.creator, {
            slots = {
                { baseline = { items = { { name = 'repairkit', count = 10 } } } },
                { baseline = { items = { { name = 'repairkit', count = 10 } } } },
            },
        })
        truthy(lines)

        local ok, err = s.escrow.take(f.creator, 'CH-STACKS', lines)
        truthy(ok, 'a fully-funded contract must not be refused: ' .. tostring(err))

        local left = 0
        for _, slot in ipairs(Env.players[1]._inventory) do
            if slot.name == 'repairkit' then left = left + slot.count end
        end
        eq(left, 0, 'both stacks were escrowed, so neither should still be carried')
    end)

    it('is tested against an inventory shaped like the real one', function()
        -- The guard is keyed on the slot number, and ox_inventory numbers
        -- every stack. A harness that left them unnumbered would exercise
        -- the fallback path on every test and never the one production
        -- takes — so the fixture's own default inventory is checked here.
        local s = newStack()
        local f = fixture(s)
        local found = exports.ox_inventory:Search(f.creator.source, 'slots', 'lockpick')
        eq(#found, 1)
        eq(type(found[1].slot), 'number',
            'a stack written without a slot must still arrive with one, because '
            .. 'that is what ox_inventory does')

        -- And a test that means to model a build without them says so.
        local g = fixture(newStack(), { creatorInventory = {
            { name = 'lockpick', count = 1, slot = false },
        } })
        local bare = exports.ox_inventory:Search(g.creator.source, 'slots', 'lockpick')
        eq(#bare, 1)
        eq(bare[1].slot, nil, 'slot = false is an explicit claim, and is honoured')
    end)

    it('still refuses when the stacks together are not enough', function()
        local s = newStack()
        local f = twoStacks(s)

        local lines, err = s.escrow.validate(f.creator, {
            slots = {
                { baseline = { items = { { name = 'repairkit', count = 10 } } } },
                { baseline = { items = { { name = 'repairkit', count = 10 } } } },
                { baseline = { items = { { name = 'repairkit', count = 10 } } } },
            },
        })
        falsy(lines, 'thirty asked for against twenty held')
        eq(err, CH.ERR.INSUFFICIENT)
    end)
end)


--- A percentage bonus is real escrow, so the arithmetic that derives it is
--- financial arithmetic.
describe('a bonus derived from a percentage', function()
    local function bonusFor(percent, baseline)
        local s = newStack()
        local f = fixture(s)
        local lines = s.escrow.validate(f.creator, {
            baseline = { cash = baseline },
        }, percent)
        truthy(lines, 'lines for ' .. percent .. '% of ' .. baseline)
        for i = 1, #lines do
            if lines[i].portion == CH.PORTION.BONUS then return lines[i].amount end
        end
        return nil
    end

    it('pays exactly the percentage promised', function()
        -- amount * (percent / 100) computes a binary fraction first and loses
        -- a whole unit on it: 29% of 50000 came out as 14499. Multiplying
        -- before dividing keeps it in integers.
        eq(bonusFor(29, 50000), 14500)
        eq(bonusFor(57, 10000), 5700)
        eq(bonusFor(58, 50000), 29000)
        eq(bonusFor(69, 10000), 6900)
    end)

    it('is still exact on the percentages that never lost anything', function()
        eq(bonusFor(50, 10000), 5000)
        eq(bonusFor(25, 10000), 2500)
        eq(bonusFor(100, 10000), 10000)
        eq(bonusFor(1, 10000), 100)
    end)

    it('rounds down rather than up when the split is not whole', function()
        -- 33% of 101 is 33.33: the creator is charged 33, not 34. Rounding
        -- the other way would take money they never agreed to.
        eq(bonusFor(33, 101), 33)
        eq(bonusFor(50, 99), 49)
    end)
end)


--- Delivery either happens or the line stays owed. There is no third answer.
describe('a payout the framework refuses', function()
    local function owedLine(s, f)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c)
        return c
    end

    it('does not mark a line settled when AddMoney says no', function()
        -- The item branches ask whether the inventory took the goods; the
        -- cash branch called AddMoney and reported success regardless. A
        -- server with a balance ceiling — or any qbx_core refusal — would
        -- have settled the line with nothing delivered, and the money is
        -- then gone from escrow and never arrived.
        local s = newStack()
        local f = fixture(s)
        local c = owedLine(s, f)

        Env.players[3]._refuseMoney = true
        local before = Env.players[3].PlayerData.money.cash
        eq(before, 5000, 'the hitman starts with their own money and nothing else')

        local ok, result = s.escrow.release(c.id, 'HITMAN01', CH.PORTION.BASELINE, 'test')

        eq(Env.players[3].PlayerData.money.cash, before, 'nothing was actually paid')
        falsy(ok, 'so the release did not settle anything')
        eq(result.settled, 0)
        eq(result.pending, 1, 'and the line is owed, to be retried on next login')
    end)

    it('keeps the line claimable once the framework will take it', function()
        local s = newStack()
        local f = fixture(s)
        local c = owedLine(s, f)

        Env.players[3]._refuseMoney = true
        s.escrow.release(c.id, 'HITMAN01', CH.PORTION.BASELINE, 'test')

        Env.players[3]._refuseMoney = false
        local ok, result = s.escrow.release(c.id, 'HITMAN01', CH.PORTION.BASELINE, 'retry')
        truthy(ok, 'the retry must pay')
        eq(result.settled, 1)
        eq(Env.players[3].PlayerData.money.cash, 10000,
            'and the hitman is paid the 5000 baseline exactly once, on top of their own 5000')
    end)

    it('does not let anyone else collect the line in the meantime', function()
        local s = newStack()
        local f = fixture(s)
        local c = owedLine(s, f)

        Env.players[3]._refuseMoney = true
        s.escrow.release(c.id, 'HITMAN01', CH.PORTION.BASELINE, 'test')
        Env.players[3]._refuseMoney = false

        -- An unfiltered refund to the creator must not sweep up a payout
        -- that is owed to the hitman.
        local before = Env.players[1].PlayerData.money.cash
        s.escrow.release(c.id, 'CREATOR1', nil, 'refund')
        eq(Env.players[1].PlayerData.money.cash, before,
            'the creator must not be handed the hitman money')

        -- And it is still there for the hitman afterwards.
        local ok, result = s.escrow.release(c.id, 'HITMAN01', CH.PORTION.BASELINE, 'retry')
        truthy(ok)
        eq(result.settled, 1)
        eq(Env.players[3].PlayerData.money.cash, 10000)
    end)
end)


describe('a rollback that cannot return what it took', function()
    it('records what the creator is still owed', function()
        -- The end of the line: escrow was taken, the write failed, and the
        -- give-back failed too. There is no escrow record left to hold the
        -- property, so the audit row is the only thing that says who is
        -- owed what.
        local s = newStack()
        local f = fixture(s)

        local realWrite = s.storage.writeEscrow
        s.storage.writeEscrow = function() return false end
        Env.players[1]._refuseMoney = true

        local ok, err = s.escrow.take(f.creator, 'CH-ROLLBACK', {
            { slot = 1, portion = CH.PORTION.BASELINE, source = 'cash', amount = 5000 },
        })

        s.storage.writeEscrow = realWrite
        Env.players[1]._refuseMoney = false

        falsy(ok, 'the take must fail: ' .. tostring(err))
        s.audit.flush()

        local seen = false
        for _, row in ipairs(s.storage.readAudit(200)) do
            if row.action == 'escrow_rollback_failed' then seen = true end
        end
        truthy(seen, 'property that could not be returned must be recorded, not lost quietly')
    end)

    it('says nothing when the rollback works', function()
        local s = newStack()
        local f = fixture(s)

        local realWrite = s.storage.writeEscrow
        s.storage.writeEscrow = function() return false end
        local before = Env.players[1].PlayerData.money.cash

        local ok = s.escrow.take(f.creator, 'CH-ROLLBACK2', {
            { slot = 1, portion = CH.PORTION.BASELINE, source = 'cash', amount = 5000 },
        })
        s.storage.writeEscrow = realWrite

        falsy(ok)
        eq(Env.players[1].PlayerData.money.cash, before, 'the creator is whole again')
        s.audit.flush()
        for _, row in ipairs(s.storage.readAudit(200)) do
            falsy(row.action == 'escrow_rollback_failed',
                'a rollback that worked must not raise an alarm')
        end
    end)
end)


describe('a settle the store will not take', function()
    it('records it, because the money has already gone', function()
        -- Settling is guarded on the line still being the one this release
        -- claimed. If something else took it — restart recovery returning a
        -- stuck line to held, or a second server instance on the same
        -- database — the delivery has already happened and the line is at
        -- risk of being paid again. Nothing here can undo it; the row is
        -- what tells staff to look.
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c)

        local real = s.storage.settleEscrowLine
        s.storage.settleEscrowLine = function() return false end
        local ok, result = s.escrow.release(c.id, 'HITMAN01', CH.PORTION.BASELINE, 'test')
        s.storage.settleEscrowLine = real

        truthy(ok, 'the hitman was paid')
        eq(result.settled, 1)
        eq(Env.players[3].PlayerData.money.cash, 10000, 'and really has the money')

        s.audit.flush()
        local seen = false
        for _, row in ipairs(s.storage.readAudit(200)) do
            if row.action == 'escrow_settle_lost' then seen = true end
        end
        truthy(seen, 'a line that could not be settled after delivery must be recorded')
    end)

    it('says nothing on an ordinary settle', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(s.escrow.release(c.id, 'HITMAN01', CH.PORTION.BASELINE, 'test'))

        s.audit.flush()
        for _, row in ipairs(s.storage.readAudit(200)) do
            falsy(row.action == 'escrow_settle_lost', 'a normal payout raises no alarm')
        end
    end)
end)

describe('the weapons list', function()
    --- It took any name. A lockpick sent as a weapon was escrowed past the
    --- item switch an operator had turned off and past the stack limits, and
    --- shown on the board as a weapon.
    it('takes weapons and nothing else', function()
        local s = newStack()
        local f = fixture(s)
        Config.Sources.item.enabled = false
        local slot
        for _, entry in ipairs(Env.players[1]._inventory) do
            if entry.name == 'lockpick' then slot = entry.slot end
        end
        truthy(slot)
        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 1000, weapons = { { name = 'lockpick', slot = slot } } } },
        })
        falsy(c, 'a lockpick is not a weapon')
        eq(err, CH.ERR.INVALID_REWARD)

        local ok = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 1000, weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } } },
        })
        truthy(ok, 'a pistol still is')
    end)
end)

describe('item names, as the inventory reads them', function()
    --- ox_inventory folds case on every lookup, so a capital letter was the
    --- same item to it and a different one to the blacklist.
    local function withFoldingInventory(s)
        local inv = exports.ox_inventory
        local real = { GetItem = inv.GetItem, RemoveItem = inv.RemoveItem }
        local function fold(name)
            local lower = tostring(name):lower()
            if lower:sub(1, 7) == 'weapon_' then return lower:upper() end
            return lower
        end
        inv.GetItem = function(self, src, name, ...) return real.GetItem(self, src, fold(name), ...) end
        inv.RemoveItem = function(self, src, name, ...) return real.RemoveItem(self, src, fold(name), ...) end
        return function() inv.GetItem, inv.RemoveItem = real.GetItem, real.RemoveItem end
    end

    it('keeps a blacklisted item out however it is capitalised', function()
        local s = newStack()
        local f = fixture(s)
        table.insert(Env.players[1]._inventory, { name = 'handcuffs', count = 1, slot = 20 })
        local restore = withFoldingInventory(s)
        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 1000, items = { { name = 'Handcuffs', count = 1 } } } },
        })
        restore()
        falsy(c, 'handcuffs went into escrow under a capital H')
        eq(err, CH.ERR.INVALID_REWARD)
    end)

    it('keeps black money out of the item list however it is capitalised', function()
        local s = newStack()
        local f = fixture(s)
        local restore = withFoldingInventory(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 1000, items = { { name = 'Black_Money', count = 100 } } } },
        })
        restore()
        falsy(c, 'black money escrowed as an item, past its own cap')
    end)
end)

describe('an item name written in odd case', function()
    --- The inventory folds case; a lookup under the name as sent found no
    --- such item and refused a creator who was holding it.
    it('is taken under the inventory\'s own spelling', function()
        local s = newStack()
        local f = fixture(s)
        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 1000, items = { { name = 'LockPick', count = 1 } } } },
        })
        truthy(c, tostring(err))
        local stored
        for _, l in ipairs(s.storage.readEscrow(c.id)) do
            if l.source == CH.SOURCE.ITEM then stored = l.item end
        end
        eq(stored, 'lockpick')
    end)
end)

--------------------------------------------------------------------------
-- What mysql's columns hold (S04, S05)
--------------------------------------------------------------------------

--- A stack whose store is the mysql backend on the statement executor,
--- which refuses what strict MariaDB refuses.
local function onMysql()
    local s = newStack()
    local Exec = require('tests.harness.mysql_exec')
    Exec.install(Natives)
    package.loaded['crimson-hitman.server.storage.mysql'] = nil
    local store = require('crimson-hitman.server.storage.mysql')
    store.open()
    s.audit.init(store)
    s.review.init({ storage = store, escrow = s.escrow, audit = s.audit })
    s.escrow.init(store, s.audit, s.review)
    s.progression.init({ storage = store, identity = s.identity, audit = s.audit })
    s.contracts.init({ storage = store, escrow = s.escrow, identity = s.identity,
                       audit = s.audit, notify = s.notify, progression = s.progression,
                       death = s.death, review = s.review })
    s.amendments.init({ storage = store, identity = s.identity, contracts = s.contracts,
                        escrow = s.escrow, audit = s.audit, notify = s.notify })
    s.storage = store
    return s
end

local function onJson()
    local s = newStack()
    package.loaded['crimson-hitman.server.storage.json'] = nil
    Natives.files = {}
    local store = require('crimson-hitman.server.storage.json')
    store.open()
    s.audit.init(store)
    s.review.init({ storage = store, escrow = s.escrow, audit = s.audit })
    s.escrow.init(store, s.audit, s.review)
    s.contracts.init({ storage = store, escrow = s.escrow, identity = s.identity,
                       audit = s.audit, notify = s.notify, progression = s.progression,
                       death = s.death, review = s.review })
    s.amendments.init({ storage = store, identity = s.identity, contracts = s.contracts,
                        escrow = s.escrow, audit = s.audit, notify = s.notify })
    s.storage = store
    return s
end

local function carried(src, name)
    local n = 0
    for _, e in ipairs(Env.players[src]._inventory or {}) do
        if e.name == name then n = n + (e.count or 0) end
    end
    return n
end

describe('a give that raised for a player holding more than an INT', function()
    --- deliver_before records their balance before the give; past
    --- 2,147,483,647 the write raised, Escrow.deliver raised with it, and
    --- the raise was never counted, so the bounded retry never engaged.
    it('still counts its raise (mysql)', function()
        local s = onMysql()
        fixture(s)
        local hitman = Env.players[3]
        hitman.PlayerData.money.cash = 3e9
        s.storage.writeEscrow('ct00000031', { {
            id = 'ct00000031:1', slot = 1, portion = CH.PORTION.BASELINE, source = 'cash',
            amount = 500, state = CH.ESCROW_STATE.HELD, owed_to = 'HITMAN01',
        } })
        local line = s.storage.readEscrowLine('ct00000031:1')
        local real = hitman.Functions.AddMoney
        hitman.Functions.AddMoney = function() error('AddMoney hook raised', 0) end
        local ran, delivered = pcall(s.escrow.deliver, 'HITMAN01', line)
        hitman.Functions.AddMoney = real
        truthy(ran, 'the give\'s record raised: ' .. tostring(delivered))
        falsy(delivered, 'nothing arrived')
        local after = s.storage.readEscrowLine('ct00000031:1')
        eq(tonumber(after.deliver_raises), 1, 'the raise is counted')
        eq(tonumber(after.deliver_before), 2147483647, 'with the balance held to the column')
    end)
end)

describe('an item whose metadata a TEXT column cannot hold', function()
    local function bigInventory()
        return { { name = 'lockpick', count = 1, slot = 1,
                   metadata = { note = ('n'):rep(70000) } } }
    end
    local REWARD = { baseline = { cash = 1000, items = { { name = 'lockpick', count = 1 } } } }

    --- S05: refused by the store after the take, rolled back, and answered
    --- bad_state, with the whole 70 KB in the console.
    it('is refused by name before anything is taken (mysql)', function()
        local s = onMysql()
        local f = fixture(s, { creatorInventory = bigInventory() })
        local cash = Env.players[1].PlayerData.money.cash
        local c, err = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = REWARD })
        falsy(c, 'placed')
        eq(err, CH.ERR.ITEM_TOO_LARGE)
        eq(carried(1, 'lockpick'), 1, 'the creator keeps the item')
        eq(Env.players[1].PlayerData.money.cash, cash, 'and their cash')
        local moved = 0
        for _, call in ipairs(Natives.calls.inventory or {}) do
            if call.name == 'lockpick' then moved = moved + 1 end
        end
        eq(moved, 0, 'nothing was taken to be given back')
    end)

    it('is refused the same way as a top-up (mysql)', function()
        local s = onMysql()
        local f = fixture(s, { creatorInventory = bigInventory() })
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 1000 } } })
        truthy(c, 'a cash contract')
        local cash = Env.players[1].PlayerData.money.cash
        local ok, err = s.amendments.addEscrow(f.creator, c.id,
            { baseline = { items = { { name = 'lockpick', count = 1 } } } })
        falsy(ok)
        eq(err, CH.ERR.ITEM_TOO_LARGE)
        eq(carried(1, 'lockpick'), 1)
        eq(Env.players[1].PlayerData.money.cash, cash)
    end)

    it('is placed on json, which keeps it whole', function()
        local s = onJson()
        local f = fixture(s, { creatorInventory = bigInventory() })
        local c, err = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = REWARD })
        truthy(c, tostring(err))
        eq(carried(1, 'lockpick'), 0, 'in escrow')
        local found
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.item == 'lockpick' then found = line end
        end
        eq(#found.metadata.note, 70000, 'metadata and all')
    end)
end)
