--- The review queue (server/review.lua): money no rule here can settle by
--- itself, kept until staff resolve it, in every storage mode.
---
--- Before it, each of these events left an audit row and nothing else, and
--- the rows are pruned after Config.Audit.RetentionDays. These hold the
--- queue to keeping what happened until somebody has dealt with it, and to
--- paying at most once whatever is asked and whenever the server stops.

local Exec = require('tests.harness.mysql_exec')

local BACKENDS = { 'memory', 'json', 'mysql' }

--- A store of the named kind, fresh.
local function freshStore(name)
    if name == 'json' then
        package.loaded['crimson-hitman.server.storage.json'] = nil
        Natives.files = {}
        local store = require('crimson-hitman.server.storage.json')
        store.open()
        return store
    elseif name == 'mysql' then
        Exec.install(Natives)
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local store = require('crimson-hitman.server.storage.mysql')
        store.open()
        return store
    end
    package.loaded['crimson-hitman.server.storage.memory'] = nil
    local store = require('crimson-hitman.server.storage.memory')
    store.open()
    return store
end

--- The same store as a new process finds it: json and mysql read back
--- from what they wrote; memory is the same tables, which is all a memory
--- store has.
local function reopened(name, store)
    if name == 'json' then
        package.loaded['crimson-hitman.server.storage.json'] = nil
        local again = require('crimson-hitman.server.storage.json')
        again.open()
        return again
    elseif name == 'mysql' then
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local again = require('crimson-hitman.server.storage.mysql')
        again.open()
        return again
    end
    return store
end

--- Point the money paths of a stack at `store`, as a new process would wire
--- them: the review queue, escrow and the log, each with nothing in flight.
local function wire(s, store)
    s.storage = store
    s.audit.init(store)
    s.review.init({ storage = store, escrow = s.escrow, audit = s.audit })
    s.escrow.init(store, s.audit, s.review)
end

--- A stack on the named backend, with the usual three players.
local function stackOn(name)
    local s = newStack()
    local f = fixture(s)
    wire(s, freshStore(name))
    return s, f
end

local function bankOf(src) return Env.players[src].PlayerData.money.bank end

local function stranded(s, extra)
    local spec = {
        kind = 'bailout_refund_stranded', contract_id = 'ct00000001',
        cids = { payer = 'TARGET01', creator = 'CREATOR1' },
        amount = 5000, account = 'bank', known = { reason = 'test' },
    }
    for k, v in pairs(extra or {}) do spec[k] = v end
    return s.review.open(spec)
end

describe('the review queue in every backend', function()
    for _, name in ipairs(BACKENDS) do
        describe(name, function()
            it('keeps everything an item says, and reads it back after a restart', function()
                local s = stackOn(name)
                local id = s.review.open({
                    kind = 'escrow_take_unverified', contract_id = 'ct00000009',
                    cids = { from = 'CREATOR1' },
                    items = {
                        { id = 'ct00000009:1', source = 'bank', amount = 2500 },
                        { id = 'ct00000009:2', source = 'item', item = 'lockpick', quantity = 3,
                          metadata = { durability = 40 } },
                    },
                    known = { error = 'connection lost' },
                })
                truthy(id, 'opened')
                local store = reopened(name, s.storage)
                local item = store.readReview(id)
                truthy(item, 'there after a restart')
                eq(item.kind, 'escrow_take_unverified')
                eq(item.contract_id, 'ct00000009')
                eq(item.cids.from, 'CREATOR1', 'the parties')
                eq(#item.items, 2, 'the lines')
                eq(item.items[2].metadata.durability, 40, 'goods as they were')
                eq(item.known.error, 'connection lost', 'what was known')
                eq(item.state, 'open')
                truthy(item.created_at, 'and when')
            end)

            it('lists open ones oldest first, and every one newest first', function()
                local s = stackOn(name)
                local first = stranded(s)
                Env.advance(10)
                local second = stranded(s, { amount = 100 })
                local open = s.storage.reviewItems(true, 10)
                eq(#open, 2)
                eq(open[1].id, first, 'oldest first')
                truthy(s.storage.setReviewState(first, 'open', 'resolved',
                    { resolution = { action = 'dismiss', note = 'x' }, resolved_by = 'console',
                      resolved_at = os.time() }))
                open = s.storage.reviewItems(true, 10)
                eq(#open, 1, 'a resolved one is not open')
                eq(open[1].id, second)
                local all = s.storage.reviewItems(false, 10)
                eq(#all, 2, 'all of them')
                eq(all[1].id, second, 'newest first')
                eq(all[2].resolution.note, 'x', 'with how it was resolved')
                eq(all[2].resolved_by, 'console', 'by whom')
            end)

            it('moves an item only from the state it is in', function()
                local s = stackOn(name)
                local id = stranded(s)
                falsy(s.storage.setReviewState(id, 'resolving', 'resolved', { resolved_by = 'x' }),
                    'not from a state it is not in')
                truthy(s.storage.setReviewState(id, 'open', 'resolving', { resolved_by = 'a' }))
                falsy(s.storage.setReviewState(id, 'open', 'resolving', { resolved_by = 'b' }),
                    'a second resolution cannot begin')
                eq(s.storage.readReview(id).resolved_by, 'a')
            end)

            it('never writes over an item, so a resolved one stays resolved', function()
                -- The queue writes an item again when the store refused it,
                -- and a refused write may have landed: written over, an item
                -- resolved meanwhile was open again, to be paid twice.
                local s = stackOn(name)
                local id = stranded(s)
                local original = s.storage.readReview(id)
                local copy = {}
                for k, v in pairs(original) do copy[k] = v end
                truthy(s.review.resolve(id, { action = 'dismiss', note = 'paid by hand' }, 'console'))
                s.storage.writeReview(copy)
                eq(s.storage.readReview(id).state, 'resolved', 'still resolved')
            end)

            it('refunds through escrow, once, and records who and when', function()
                local s = stackOn(name)
                local id = stranded(s)
                local before = bankOf(2)
                local ok, err, result = s.review.resolve(id,
                    { action = 'refund', who = 'payer', amount = 5000 }, 'STAFF01')
                truthy(ok, tostring(err))
                eq(result.settled, 1, 'given now: they are in the city')
                eq(bankOf(2) - before, 5000, 'into the account it was taken from')

                local item = s.storage.readReview(id)
                eq(item.state, 'resolved')
                eq(item.resolution.action, 'refund')
                eq(item.resolution.cid, 'TARGET01', 'to whom the role named')
                eq(item.resolved_by, 'STAFF01')
                truthy(item.resolved_at)
                local line = s.storage.readEscrowLine(id .. ':1')
                eq(line and line.state, CH.ESCROW_STATE.SETTLED, 'through an escrow line')

                local again, why = s.review.resolve(id,
                    { action = 'refund', who = 'payer', amount = 5000 }, 'STAFF02')
                falsy(again, 'resolving twice')
                eq(why, CH.ERR.ALREADY_SETTLED)
                eq(bankOf(2) - before, 5000, 'never pays twice')

                -- Audited, and on the store already: a resolution is money
                -- moved by hand, and the queue is not where it waits.
                local logged = false
                for _, row in ipairs(s.storage.auditByAction('review_resolved', 10) or {}) do
                    if (row.detail or {}).review == id then logged = true end
                end
                truthy(logged, 'the resolution is in the log at once')
            end)

            it('owes it to somebody away, and gives it at their login, once', function()
                local s = stackOn(name)
                local id = stranded(s)
                Env.removePlayer(2)
                local ok, _, result = s.review.resolve(id, { action = 'pay', who = 'payer' }, 'x')
                truthy(ok)
                eq(result.pending, 1, 'owed and queued')
                eq(s.storage.readReview(id).state, 'resolved', 'decided, and owed as any payout is')

                Env.addPlayer({ source = 2, citizenid = 'TARGET01', bank = 0 })
                eq(s.escrow.retryPending('TARGET01'), 1, 'given at the login')
                eq(bankOf(2), 5000)
                eq(s.escrow.retryPending('TARGET01'), 0, 'and not again')
                eq(bankOf(2), 5000)
            end)

            --- The server stops at each step of a resolution. A new process
            --- (reopened store, nothing in flight) finishes it at boot as it
            --- was decided, and the money moves exactly once.
            local function stopDuring(install)
                local s = stackOn(name)
                local id = stranded(s)
                local before = bankOf(2)
                local undo = install(s)
                local co = coroutine.create(function()
                    s.review.resolve(id, { action = 'refund', who = 'payer', amount = 5000 }, 'STAFF01')
                end)
                local ok, err = coroutine.resume(co)
                undo()
                if not ok then error(err, 0) end
                eq(coroutine.status(co), 'suspended', 'stopped where the test said')
                local item = s.storage.readReview(id)
                eq(item and item.state, 'resolving', 'left part-way, with the decision on it')
                wire(s, reopened(name, s.storage))
                return s, id, before
            end

            it('finishes one stopped before its line was written', function()
                local s, id, before = stopDuring(function(stack)
                    local real = stack.storage.writeEscrow
                    stack.storage.writeEscrow = function(...) coroutine.yield() return real(...) end
                    return function() stack.storage.writeEscrow = real end
                end)
                eq(bankOf(2), before, 'nothing moved yet')
                eq(s.review.recover(), 1, 'the next start finishes it')
                eq(bankOf(2) - before, 5000, 'as decided')
                eq(s.storage.readReview(id).state, 'resolved')
                eq(s.storage.readReview(id).resolved_by, 'STAFF01', 'by whom decided it')
                falsy(s.review.resolve(id, { action = 'dismiss', note = 'again' }, 'x'))
                eq(bankOf(2) - before, 5000, 'once')
            end)

            it('finishes one stopped with its line written and not given', function()
                local s, id, before = stopDuring(function(stack)
                    local real = stack.escrow.release
                    stack.escrow.release = function(...) coroutine.yield() return real(...) end
                    return function() stack.escrow.release = real end
                end)
                eq(bankOf(2), before, 'nothing moved yet')
                truthy(s.storage.readEscrowLine(id .. ':1'), 'the line is there, owed')
                -- Asked again by staff rather than by the boot: the decision
                -- on it stands, whatever is asked now.
                local ok, _, result = s.review.resolve(id, { action = 'dismiss', note = 'no' }, 'OTHER')
                truthy(ok)
                truthy(result.continued, 'finished as decided')
                eq(result.action, 'refund', 'not as asked now')
                eq(bankOf(2) - before, 5000)
                eq(s.escrow.retryPending('TARGET01'), 0, 'and the login retry gives nothing more')
                eq(bankOf(2) - before, 5000, 'once')
            end)

            it('never gives again one stopped part-way through its give', function()
                -- The money moved, and the server stopped before the line was
                -- settled. The next start puts the line back as one left for
                -- staff (Recover, Escrow.putBackStuck): whether it arrived
                -- cannot be told from the line, so nothing gives it blind.
                local s, id, before = stopDuring(function()
                    local player = Env.players[2]
                    local real = player.Functions.AddMoney
                    player.Functions.AddMoney = function(...)
                        local done = real(...)
                        coroutine.yield()
                        return done
                    end
                    return function() player.Functions.AddMoney = real end
                end)
                eq(bankOf(2) - before, 5000, 'the give reached them before the stop')
                s.escrow.putBackStuck(id .. ':1')
                s.review.recover()
                eq(s.storage.readReview(id).state, 'resolved')
                eq(s.storage.readReview(id).resolution.result.parked, 1,
                    'its line waits for staff in /ch-stuck')
                eq(s.escrow.retryPending('TARGET01'), 0)
                eq(bankOf(2) - before, 5000, 'and was not given again')
            end)
        end)
    end
end)

describe('what a resolution may give', function()
    it('refuses a refund over what the item records, and one in money it does not', function()
        local s = stackOn('memory')
        local id = stranded(s)
        local ok, why, most = s.review.resolve(id, { action = 'refund', who = 'payer', amount = 5001 }, 'x')
        falsy(ok)
        eq(why, 'over_recorded')
        eq(most, 5000, 'and says the most')
        ok, why = s.review.resolve(id, { action = 'refund', who = 'payer', amount = 10,
            account = 'cash' }, 'x')
        falsy(ok)
        eq(why, 'nothing_recorded')
        eq(s.storage.readReview(id).state, 'open', 'still open')
    end)

    it('wants a note to dismiss, and gives nothing', function()
        local s = stackOn('memory')
        local id = stranded(s)
        local before = bankOf(2)
        local ok, why = s.review.resolve(id, { action = 'dismiss' }, 'x')
        falsy(ok)
        eq(why, 'note_required')
        truthy(s.review.resolve(id, { action = 'dismiss', note = 'refunded in person' }, 'x'))
        eq(bankOf(2), before)
        eq(s.storage.readReview(id).resolution.note, 'refunded in person')
    end)

    it('pays only what is not known to have arrived', function()
        local s = stackOn('memory')
        local id = stranded(s, { known = { arrived = 2000 } })
        local before = bankOf(2)
        truthy(s.review.resolve(id, { action = 'pay', who = 'payer' }, 'x'))
        eq(bankOf(2) - before, 3000)
    end)

    it('gives goods back as they were', function()
        local s = stackOn('memory')
        local id = s.review.open({
            kind = 'escrow_rollback_failed', contract_id = 'ct00000002',
            cids = { from = 'CREATOR1' },
            items = { { source = 'item', item = 'lockpick', quantity = 2, metadata = { durability = 7 } } },
        })
        truthy(s.review.resolve(id, { action = 'refund', who = 'from', goods = true }, 'x'))
        local got
        for _, stack in ipairs(Env.players[1]._inventory) do
            if stack.name == 'lockpick' and stack.metadata and stack.metadata.durability == 7 then
                got = stack
            end
        end
        truthy(got, 'the lockpicks, worn as they were')
    end)

    it('names a party by citizen id as well as by role', function()
        local s = stackOn('memory')
        local id = stranded(s)
        local before = bankOf(3)
        truthy(s.review.resolve(id, { action = 'refund', who = 'HITMAN01', amount = 100 }, 'x'))
        eq(bankOf(3) - before, 100)
        local other = stranded(s)
        local ok, why = s.review.resolve(other, { action = 'pay', who = 'not a cid!' }, 'x')
        falsy(ok)
        eq(why, 'no_party')
    end)
end)

describe('a store that will not take an item', function()
    it('keeps it, lists it, and writes it once the store answers', function()
        local s = stackOn('memory')
        local real = s.storage.writeReview
        s.storage.writeReview = function() error('connection lost', 0) end
        local id = stranded(s)
        local listed = s.review.list()
        s.storage.writeReview = real
        eq(#listed, 1)
        eq(listed[1].id, id)
        truthy(listed[1].unwritten, 'said to be not in the store yet')
        eq(s.storage.readReview(id), nil)
        eq(s.review.retryUnwritten(), 1, 'the tick writes it')
        eq(s.storage.readReview(id).state, 'open')
        eq(s.review.retryUnwritten(), 0, 'once')
    end)
end)

describe('the events that leave money for staff', function()
    local function only(s, kind)
        local found = {}
        for _, item in ipairs(s.storage.reviewItems(false, 50)) do
            if item.kind == kind then found[#found + 1] = item end
        end
        return found
    end

    it('a buyout the store would neither record nor read back', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } }, bailoutAmount = 15000 })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local price = s.storage.readContract(c.id).bailout_amount
        local realQueue, realRead = s.storage.setBailoutQueue, s.storage.readContract
        local down = false
        s.storage.setBailoutQueue = function() down = true error('connection lost', 0) end
        s.storage.readContract = function(...)
            if down then error('connection lost', 0) end
            return realRead(...)
        end
        local ran = pcall(s.bailout.buy, f.target, c.id)
        s.storage.setBailoutQueue, s.storage.readContract = realQueue, realRead
        falsy(ran, 'the raise goes on to the caller, as before')
        local items = only(s, 'bailout_unrecorded')
        eq(#items, 1, 'and the question is kept for staff')
        eq(items[1].cids.payer, 'TARGET01')
        eq(items[1].amount, price)
        eq(items[1].contract_id, c.id)
    end)

    it('a buyout handed back to nobody, as a memory store stops', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } }, bailoutAmount = 15000 })
        local contract = s.storage.readContract(c.id)
        contract.bailout_queued_at, contract.bailout_paid_by = os.time(), 'TARGET01'
        contract.bailout_paid_amount, contract.bailout_paid_account = 12000, 'bank'
        Env.removePlayer(1)
        Env.removePlayer(2)
        falsy(s.bailout.returnQueued(contract, 'resource_stopping'))
        local items = only(s, 'bailout_refund_stranded')
        eq(#items, 1)
        eq(items[1].amount, 12000)
        eq(items[1].cids.payer, 'TARGET01')
    end)

    it('escrow taken that the store would not confirm', function()
        local s = newStack()
        local f = fixture(s)
        local realWrite, realRead = s.storage.writeEscrow, s.storage.readEscrow
        local down = false
        s.storage.writeEscrow = function() down = true error('connection lost', 0) end
        s.storage.readEscrow = function(...)
            if down then error('connection lost', 0) end
            return realRead(...)
        end
        pcall(s.contracts.create, f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { bank = 5000 } } })
        s.storage.writeEscrow, s.storage.readEscrow = realWrite, realRead
        local items = only(s, 'escrow_take_unverified')
        eq(#items, 1)
        eq(items[1].cids.from, 'CREATOR1')
        eq(items[1].items[1].amount, 5000, 'naming what was charged')
        truthy(items[1].items[1].id, 'and the line id, so a listing can say if the store has it')
        local listed = s.review.list()
        eq(listed[1].now.lines.missing, 1, 'which it does not')
    end)

    --- S12 / W152: the contract is placed by the server from the copy the
    --- item carries, its escrow held for it meanwhile, and no anonymity fee
    --- was taken. Before: escrow and fee handed back on the row's absence,
    --- and a fee taken for a contract that might never exist.
    it('a contract the store would neither write nor read back is placed by the server', function()
        local s = newStack()
        local f = fixture(s)
        Config.Anonymity.CreatorFee = 500
        local bank = bankOf(1)
        local realWrite, realRead = s.storage.insertContract, s.storage.readContract
        local down = false
        s.storage.insertContract = function() down = true error('connection lost', 0) end
        s.storage.readContract = function(...)
            if down then down = false error('connection lost', 0) end
            return realRead(...)
        end
        falsy(pcall(s.contracts.create, f.creator, { targetCid = 'TARGET01', reason = 'x',
            anonymous = true, reward = { baseline = { bank = 5000 } } }))
        s.storage.insertContract, s.storage.readContract = realWrite, realRead
        eq(bankOf(1) - bank, -5000, 'the reward is held, and no fee was taken for it')
        local items = only(s, 'contract_unrecorded')
        eq(#items, 1, 'left for staff, and for the server')
        eq(items[1].amount, nil, 'no fee to refund')
        truthy(items[1].known.decide, 'with the whole contract to place it from')
        local id = items[1].contract_id
        -- The record is the server's to settle from, and names the anonymous
        -- client: staff are told the server settles it instead.
        local listed = s.admin.reviews(0)
        eq(#listed, 1)
        truthy(listed[1].settles, 'listed as one the server settles')
        eq(listed[1].known.contract, nil, 'without the copy of the contract')
        for _, text in pairs(listed[1].known) do
            falsy(tostring(text):find('Vic Marlowe', 1, true), 'nor the client\'s name')
        end

        -- Boot keeps its escrow for it: a sweep before the server decides
        -- hands nothing back.
        eq(s.contracts.recoverNeverPlaced(), 0, 'its escrow was handed back before it was decided')
        eq(bankOf(1) - bank, -5000)

        Natives.calls.notifications = {}
        eq(s.review.decide(), 1, 'the server settles it once the store answers')
        local placed = s.storage.readContract(id)
        eq(placed and placed.state, CH.STATE.ACTIVE, 'on the board')
        eq(s.escrow.moneyValue(id), 5000, 'with its escrow')
        eq(bankOf(1) - bank, -5000, 'and still no fee: placed late, not charged')
        local item = s.storage.readReview(items[1].id)
        eq(item.state, 'resolved', 'closed by the server')
        eq(item.resolved_by, 'server')
        falsy(s.escrow.claimRunning(id), 'and its escrow let go')
        local told = false
        for _, n in ipairs(Natives.calls.notifications) do
            if tostring(n.title) == 'Contract placed' then told = true end
        end
        truthy(told, 'the client is told it is on the board')
        s.audit.flush()
        local unpaid = s.storage.auditByAction('anonymity_fee_unpaid', 10)
        eq(#unpaid, 1, 'the fee not charged is on the record')
        eq(unpaid[1].detail.reason, 'placed_late')
        eq(s.review.decide(), 0, 'once')
    end)

    --- W152 / W014: the fee is charged last, so a create that fails takes
    --- none and leaves no fee row. Before: charged first, and refunded with
    --- only the charge in the log, or lost to a restart.
    it('an anonymous create that is not placed takes no fee, and leaves no fee row', function()
        local s = newStack()
        local f = fixture(s)
        Config.Anonymity.CreatorFee = 500
        local bank = bankOf(1)
        local realWrite = s.storage.insertContract
        s.storage.insertContract = function() error('connection lost', 0) end
        local ran, placed, err = pcall(s.contracts.create, f.creator, { targetCid = 'TARGET01',
            reason = 'x', anonymous = true, reward = { baseline = { bank = 5000 } } })
        s.storage.insertContract = realWrite
        truthy(ran, tostring(placed))
        eq(placed, nil)
        eq(err, CH.ERR.BAD_STATE, 'not stored, the read says so')
        eq(bankOf(1), bank, 'the reward back, and no fee taken')
        s.audit.flush()
        eq(#s.storage.auditByAction('anonymity_fee', 10), 0, 'no fee row for a contract that does not exist')
        eq(#only(s, 'anonymity_fee_refund_failed'), 0)
    end)

    it('escrow that could not be given back when a take failed', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1]._refuseMoney = true
        local realRemove = exports.ox_inventory.RemoveItem
        exports.ox_inventory.RemoveItem = function() return false end
        s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { bank = 5000, dirty = 1000 } } })
        exports.ox_inventory.RemoveItem = realRemove
        Env.players[1]._refuseMoney = nil
        local items = only(s, 'escrow_rollback_failed')
        eq(#items, 1)
        eq(items[1].amount, 5000)
        eq(items[1].account, 'bank')
    end)

    it('a payout handed over whose settle was lost', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { bank = 5000 } } })
        local real = s.storage.settleEscrowLine
        s.storage.settleEscrowLine = function() return false end
        s.escrow.release(c.id, 'CREATOR1', nil, 'test')
        s.storage.settleEscrowLine = real
        local items = only(s, 'escrow_settle_lost')
        eq(#items, 1)
        eq(items[1].cids.recipient, 'CREATOR1')
        eq(items[1].known.delivered, true)
    end)
end)

--------------------------------------------------------------------------
-- Payments the store did not confirm, settled by the server (S12, W130)
--------------------------------------------------------------------------

describe('payments the store did not confirm, settled by the server', function()
    local function itemsOf(s, kind)
        local found = {}
        for _, item in ipairs(s.storage.reviewItems(false, 50)) do
            if item.kind == kind then found[#found + 1] = item end
        end
        return found
    end

    --- A create whose escrow write raises (having landed, or not) and whose
    --- read-back raises once.
    local function unconfirmedTake(s, f, landed, req)
        local realInsert, realRead = s.storage.insertEscrow, s.storage.readEscrow
        local down = false
        s.storage.insertEscrow = function(...)
            if landed then realInsert(...) end
            down = true
            error('connection lost', 0)
        end
        s.storage.readEscrow = function(...)
            if down then down = false error('connection lost', 0) end
            return realRead(...)
        end
        local ran = pcall(s.contracts.create, f.creator, req or { targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { bank = 5000 } } })
        s.storage.insertEscrow, s.storage.readEscrow = realInsert, realRead
        falsy(ran, 'the create raised')
        local items = itemsOf(s, 'escrow_take_unverified')
        eq(#items, 1, 'one item for staff, and for the server')
        return items[1]
    end

    it('an escrow write that raised with a read-back that raised is handed back by the server', function()
        local s = newStack()
        local f = fixture(s)
        local before = bankOf(1)
        local item = unconfirmedTake(s, f, false)
        eq(bankOf(1) - before, -5000, 'charged')
        truthy(item.known.decide, 'with the whole record')
        eq(#item.known.lines, 1)
        eq(item.known.lines[1].amount, 5000)

        eq(s.review.decide(), 1, 'the next tick settles it')
        eq(bankOf(1), before, 'every line it took handed back')
        local closed = s.storage.readReview(item.id)
        eq(closed.state, 'resolved')
        eq(closed.resolved_by, 'server')
        local line = s.storage.readEscrowLine(item.known.lines[1].id)
        eq(line and line.state, CH.ESCROW_STATE.SETTLED, 'through the line itself, written by the server')

        s.contracts.retryStuckCreates()
        s.contracts.recoverNeverPlaced()
        eq(s.review.decide(), 0)
        eq(bankOf(1), before, 'once')
    end)

    --- W130: the lines landed, the tick hands them back, and the item said
    --- they were missing: Pay gave them a second time.
    it('a take that landed is handed back by the tick and its item closed, so Pay gives nothing', function()
        local s = newStack()
        local f = fixture(s)
        local before = bankOf(1)
        local item = unconfirmedTake(s, f, true)
        eq(s.contracts.retryStuckCreates(), 1, 'the store answers: handed back')
        eq(bankOf(1), before)
        eq(s.storage.readReview(item.id).state, 'resolved',
            'closed once every line it names is in the store')
        local ok, why = s.review.resolve(item.id, { action = 'pay', who = 'from' }, 'STAFF01')
        falsy(ok)
        eq(why, CH.ERR.ALREADY_SETTLED)
        eq(s.review.decide(), 0)
        eq(bankOf(1), before, 'not paid twice')
    end)

    it('staff Refund on one settles it through its own lines, whatever is typed', function()
        local s = newStack()
        local f = fixture(s)
        local before = bankOf(1)
        local item = unconfirmedTake(s, f, false)
        local ok, why, detail = s.review.resolve(item.id,
            { action = 'refund', who = 'from', amount = 99999 }, 'STAFF01')
        truthy(ok, tostring(why))
        eq(detail.action, 'settled')
        truthy(detail.ignored, 'and says what was typed was not used')
        eq(bankOf(1), before, 'what it took, back')
        eq(s.storage.readEscrowLine(item.id .. ':1'), nil, 'no line of its own minted')
        eq(s.storage.readReview(item.id).resolved_by, 'STAFF01')
        eq(s.review.decide(), 0, 'off the server\'s list')

        -- The take's own write, landing late, meets the line and changes it not.
        s.storage.insertEscrow(item.contract_id, item.known.lines)
        s.contracts.retryStuckCreates()
        s.contracts.recoverNeverPlaced()
        eq(bankOf(1), before, 'once')
    end)

    --- Never on absence (DESIGN O7): the write the caller gave up on lands
    --- after the server settled it, and adds nothing.
    it('mysql: a take that lands after the server settled it adds nothing', function()
        local s = newStack()
        local f = fixture(s)
        local store = freshStore('mysql')
        wire(s, store)
        s.contracts.init({ storage = store, escrow = s.escrow, identity = s.identity, audit = s.audit,
            notify = s.notify, progression = s.progression, death = s.death, review = s.review })
        local before = bankOf(1)
        local realInsert, realRead = store.insertEscrow, store.readEscrow
        local held = false
        store.insertEscrow = function(...)
            store.insertEscrow = realInsert
            Exec.lateNext = 1
            held = true
            return realInsert(...)
        end
        store.readEscrow = function(...)
            if held then held = false error('connection lost', 0) end
            return realRead(...)
        end
        local creating = Env.spawn(function()
            return pcall(s.contracts.create, f.creator, { targetCid = 'TARGET01', reason = 'x',
                reward = { baseline = { bank = 5000 } } })
        end)
        -- Its caller stops waiting, as a bounded await would.
        Exec.late[1].promise:reject('timed out')
        Env.runTimers()
        store.readEscrow = realRead
        truthy(creating.done)
        falsy(creating.results[1], 'the create raised')
        eq(bankOf(1) - before, -5000)
        local item = itemsOf(s, 'escrow_take_unverified')[1]
        truthy(item and item.known.decide)

        eq(s.review.decide(), 1, 'the server writes it again and hands it back')
        eq(bankOf(1), before)
        eq(Exec.releaseLate(), 1, 'the original lands now')
        local rows = 0
        for _, row in pairs(Exec.tables.crimson_escrow or {}) do
            if row.contract_id == item.contract_id then
                rows = rows + 1
                eq(row.state, CH.ESCROW_STATE.SETTLED, 'and leaves the settled line as it is')
            end
        end
        eq(rows, 1, 'one line, not two')
        s.contracts.retryStuckCreates()
        s.contracts.recoverNeverPlaced()
        eq(bankOf(1), before, 'the client whole, once')
    end)

    --- A buyout record the store would neither take nor read back.
    local function unconfirmedBuyout(s, f, landed)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } }, bailoutAmount = 15000 })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local realRecord, realRead = s.storage.recordBailout, s.storage.readContract
        local down = false
        s.storage.recordBailout = function(...)
            if landed then realRecord(...) end
            down = true
            error('connection lost', 0)
        end
        s.storage.readContract = function(...)
            if down then down = false error('connection lost', 0) end
            return realRead(...)
        end
        falsy(pcall(s.bailout.buy, f.target, c.id))
        s.storage.recordBailout, s.storage.readContract = realRecord, realRead
        local item = itemsOf(s, 'bailout_unrecorded')[1]
        truthy(item and item.known.decide, 'with the record it would have written')
        return c, item
    end

    it('an unrecorded buyout waits while its contract is open, and is refunded once it ends without it', function()
        local s = newStack()
        local f = fixture(s)
        local before = bankOf(2) + Env.players[2].PlayerData.money.cash
        local c, item = unconfirmedBuyout(s, f, false)
        local paid = before - bankOf(2) - Env.players[2].PlayerData.money.cash
        truthy(paid > 0, 'charged')
        -- A claim holds the contract: the record may still land.
        truthy(s.storage.compareSetContractState(c.id, CH.STATE.ACCEPTED, CH.STATE.COMPLETING))
        eq(s.review.decide(), 0)
        eq(s.storage.readReview(item.id).state, 'open', 'waits')
        eq(bankOf(2) + Env.players[2].PlayerData.money.cash, before - paid, 'nothing refunded yet')

        -- It ends without the buyout: a closed contract's record never lands.
        -- Ended through the resource, which pays the hitman what it holds:
        -- the state written into the store by hand left its reward held on a
        -- closed contract, owed to nobody (tests/invariants.lua).
        truthy(s.contracts.resolve(c.id, CH.STATE.COMPLETED, f.hitman.cid, nil, 'completed'))
        eq(s.review.decide(), 1)
        eq(bankOf(2) + Env.players[2].PlayerData.money.cash, before, 'refunded')
        eq(s.storage.readReview(item.id).state, 'resolved')
        eq(s.review.decide(), 0)
        eq(bankOf(2) + Env.players[2].PlayerData.money.cash, before, 'once')
    end)

    it('an unrecorded buyout whose record landed and settled is not refunded', function()
        local s = newStack()
        local f = fixture(s)
        local before = bankOf(2) + Env.players[2].PlayerData.money.cash
        local c, item = unconfirmedBuyout(s, f, true)
        Env.advance(Config.Bailout.ProcessingDelaySeconds + 1)
        eq(s.bailout.processQueue(), 1, 'it landed, so it settles as any buyout')
        eq(s.storage.readContract(c.id).state, CH.STATE.BAILED_OUT)
        local premium = s.storage.readEscrowLine(s.bailout.premiumLineId(c.id))
        eq(premium.metadata.queued_at, item.known.fields.bailout_queued_at,
            'the premium says which buyout paid it')

        eq(s.review.decide(), 1)
        eq(s.storage.readReview(item.id).state, 'resolved', 'settled: it was this buyout')
        eq(bankOf(2) + Env.players[2].PlayerData.money.cash, before - 15000,
            'the target paid for the buyout they got, once, and was not refunded it')
    end)

    --- An item from before this version: its record is only what it names.
    it('an older item whose lines are all in the store gives nothing to Pay or Refund', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { bank = 5000 } } })
        local line = s.storage.readEscrow(c.id)[1]
        s.escrow.release(c.id, 'CREATOR1', { line = line.id }, 'test')
        local before = bankOf(1)
        local id = s.review.open({ kind = 'escrow_take_unverified', contract_id = c.id,
            cids = { from = 'CREATOR1' },
            items = { { id = line.id, source = 'bank', amount = 5000 } } })
        local ok, why = s.review.resolve(id, { action = 'pay', who = 'from' }, 'STAFF01')
        falsy(ok)
        eq(why, 'nothing_missing')
        ok, why = s.review.resolve(id, { action = 'refund', who = 'from', amount = 5000 }, 'STAFF01')
        falsy(ok)
        eq(why, 'nothing_missing')
        eq(bankOf(1), before, 'nothing given')
        eq(s.storage.readReview(id).state, 'open', 'left to dismiss')
    end)

    --- W138
    it('an item the store has not taken yet answers that it can be resolved once it has', function()
        local s = stackOn('memory')
        local real = s.storage.writeReview
        s.storage.writeReview = function() error('connection lost', 0) end
        local id = stranded(s)
        local ok, why = s.review.resolve(id, { action = 'refund', who = 'payer', amount = 5000 }, 'x')
        s.storage.writeReview = real
        falsy(ok)
        eq(why, 'unwritten')
        eq(s.review.stateOf(id), 'unwritten')
        eq(s.review.retryUnwritten(), 1)
        truthy(s.review.resolve(id, { action = 'refund', who = 'payer', amount = 5000 }, 'x'),
            'and resolves once the store has it')
    end)

    --- W137 / W131: one left part-way is finished by asking for nothing
    --- else; another action's words are refused rather than carried out.
    it('a strict ask finishes one left being resolved only by asking for nothing else', function()
        local s = stackOn('memory')
        local id = stranded(s)
        truthy(s.storage.setReviewState(id, 'open', 'resolving', {
            resolution = { action = 'refund', cid = 'TARGET01',
                lines = { { id = id .. ':1', source = 'bank', amount = 5000 } } },
            resolved_by = 'STAFF01' }))
        local before = bankOf(2)
        local ok, why, detail = s.review.resolve(id, { action = 'dismiss', note = 'no' }, 'STAFF02',
            { strict = true })
        falsy(ok)
        eq(why, 'being_resolved')
        eq(detail.action, 'refund')
        eq(detail.by, 'STAFF01')
        eq(bankOf(2), before, 'a Dismiss carried out nothing')
        local done, _, result = s.review.resolve(id, nil, 'STAFF02', { strict = true })
        truthy(done)
        truthy(result.continued)
        eq(bankOf(2) - before, 5000, 'finished as decided')
    end)

    --- A record kept on this machine (resource KVP) when the store refused
    --- an item, so a restart before the store answers does not lose it.
    it('json: an item the store refused survives a restart and is written by the first tick', function()
        local s = stackOn('json')
        local real = s.storage.writeReview
        s.storage.writeReview = function() error('disk refused', 0) end
        local id = stranded(s)
        s.storage.writeReview = real
        eq(s.storage.readReview(id), nil, 'not in the store')

        -- A new process on the same machine: nothing in memory.
        wire(s, reopened('json', s.storage))
        local listed = s.review.list()
        eq(#listed, 1, 'kept across the restart')
        eq(listed[1].id, id)
        truthy(listed[1].unwritten)
        truthy(listed[1].known.restored)
        eq(s.review.retryUnwritten(), 1, 'the first tick writes it')
        eq(s.storage.readReview(id).state, 'open')
        wire(s, reopened('json', s.storage))
        eq(#s.review.list(), 1, 'once, from the store')
        falsy(s.review.list()[1].unwritten)
    end)
end)

describe('the staff commands for the review queue', function()
    local function run(name, src, ...)
        Env.chat, Env.consoleOut = {}, {}
        local said = {}
        local realPrint = _G.print
        _G.print = function(line) said[#said + 1] = tostring(line) end
        local ok, err = pcall(Env.commands[name], src, { ... })
        _G.print = realPrint
        if not ok then error(err, 0) end
        return table.concat(said, '\n')
    end

    local function booted()
        local s = newStack()
        fixture(s)
        Env.commands = {}
        s.bridges.installCommands(s)
        return s
    end

    it('/ch-stuck lists what waits, and /ch-review resolves it once', function()
        local s = booted()
        local id = stranded(s)
        local out = run('ch-stuck', 0)
        truthy(out:find(id, 1, true), 'listed: ' .. out)
        truthy(out:find('bailout_refund_stranded', 1, true))
        truthy(out:find('payer TARGET01', 1, true), 'by role and who, at the console')

        local before = bankOf(2)
        out = run('ch-review', 0, id, 'refund', 'payer', '5000')
        truthy(out:find('Resolved', 1, true), out)
        eq(bankOf(2) - before, 5000)
        out = run('ch-review', 0, id, 'refund', 'payer', '5000')
        truthy(out:find('Already resolved', 1, true), out)
        eq(bankOf(2) - before, 5000, 'once')

        out = run('ch-stuck', 0)
        falsy(out:find(id, 1, true), 'gone from the open list')
        out = run('ch-review', 0, 'all')
        truthy(out:find('resolved: refund', 1, true), 'and in the full one, resolved: ' .. out)
    end)

    it('is for crimson.admin alone, as /ch-settle is', function()
        local s = booted()
        local id = stranded(s)
        Env.aces[7] = { command = true }
        Env.addPlayer({ source = 7, citizenid = 'STAFF007' })
        run('ch-review', 7, id, 'dismiss', 'no')
        eq(s.storage.readReview(id).state, 'open', 'refused')
    end)

    it('hides who is behind a party from staff who may not see it', function()
        local s = booted()
        local id = stranded(s)
        Env.aces[7] = { ['crimson.admin'] = true }
        Env.addPlayer({ source = 7, citizenid = 'STAFF007' })
        local rows = s.admin.reviews(7)
        eq(rows[1].id, id)
        for _, party in ipairs(rows[1].parties) do
            falsy(tostring(party.who):find('TARGET01', 1, true), 'no citizen id')
        end
        -- And the role still resolves it.
        local ok = s.admin.resolveReview(7, id, { 'refund', 'payer', '100' })
        truthy(ok)
        eq(s.storage.readReview(id).resolved_by, 'STAFF007')
    end)
end)

--------------------------------------------------------------------------
-- What an item keeps of a database error, and goods too big for a column
--------------------------------------------------------------------------

--- oxmysql's message, as its await raises it: the statement over several
--- lines, every value it was sent, then the server's own words.
local function oxmysqlError(values)
    return 'crimson-hitman/server/timing.lua:41: crimson-hitman was unable to execute a query!\n'
        .. 'Query: \n        INSERT INTO crimson_escrow\n            (id, contract_id, slot, '
        .. 'line_portion, source, amount, item, quantity, metadata)\n        VALUES (?,?,?)\n'
        .. values .. "\nData too long for column 'metadata' at row 1"
end

describe('Util.dbError', function()
    local Util = require('crimson-hitman.shared.util')

    it('keeps the server\'s words and the start of the statement, never the values', function()
        local text = Util.dbError(oxmysqlError('["ct1:1","CREATOR1","Vic Marlowe",{"note":"'
            .. ('n'):rep(100000) .. '"}]'))
        truthy(#text <= 300, 'at most 300 characters: ' .. #text)
        truthy(text:find("Data too long for column 'metadata' at row 1", 1, true), text)
        truthy(text:find('INSERT INTO crimson_escrow (id, contract_id', 1, true), text)
        for _, value in ipairs({ 'CREATOR1', 'Vic Marlowe', 'nnnn' }) do
            falsy(text:find(value, 1, true), 'none of the values it was sent: ' .. value)
        end
    end)

    it('cuts anything else to the same length, on one line', function()
        eq(Util.dbError('connection lost'), 'connection lost')
        eq(Util.dbError(nil), 'nil')
        local long = Util.dbError(('x'):rep(1000) .. '\nmore')
        eq(#long, 300)
        falsy(long:find('\n', 1, true))
    end)
end)

describe('an item for staff that would not fit its column', function()
    for _, name in ipairs(BACKENDS) do
        --- S05: oxmysql's whole message, 100 KB of metadata in its values,
        --- was kept as the item's error, and on mysql that made the item
        --- itself too big to write: kept only in this process until a
        --- restart lost it.
        it(name .. ': keeps a 100 KB error at most 300 characters, with no values', function()
            local s = stackOn(name)
            local id = s.review.open({
                kind = 'escrow_take_unverified', contract_id = 'ct00000041',
                cids = { from = 'CREATOR1' },
                items = { { id = 'ct00000041:1', source = 'cash', amount = 1000 } },
                known = { error = oxmysqlError('["ct00000041:1","CREATOR1","' .. ('v'):rep(100000) .. '"]'),
                          read_error = 'the store did not answer' },
            })
            local item = s.storage.readReview(id)
            truthy(item, 'written to the store')
            truthy(#item.known.error <= 300, 'trimmed: ' .. #item.known.error)
            truthy(item.known.error:find("Data too long for column 'metadata'", 1, true), item.known.error)
            falsy(item.known.error:find('CREATOR1', 1, true), 'none of the values')
            eq(item.known.read_error, 'the store did not answer')
        end)
    end

    it('mysql: is stored without its goods\' metadata, and every id it names', function()
        local s = stackOn('mysql')
        local said, realPrint = {}, _G.print
        _G.print = function(...) said[#said + 1] = tostring((...)) end
        local id = s.review.open({
            kind = 'escrow_take_unverified', contract_id = 'ct00000042',
            cids = { from = 'CREATOR1' },
            items = {
                { id = 'ct00000042:1', source = 'item', item = 'lockpick', quantity = 1,
                  metadata = { note = ('n'):rep(40000) } },
                { id = 'ct00000042:2', source = 'item', item = 'radio', quantity = 1,
                  metadata = { note = ('r'):rep(40000) } },
            },
        })
        _G.print = realPrint
        local item = s.storage.readReview(id)
        truthy(item, 'written, not kept only in this process: ' .. table.concat(said, '\n'))
        eq(#item.items, 2)
        eq(item.items[1].id, 'ct00000042:1')
        eq(item.items[2].item, 'radio')
        eq(item.items[1].metadata, nil)
        eq(item.items[1].metadata_omitted, true, 'and says so')
        eq(s.review.retryUnwritten(), 0, 'nothing left waiting')
    end)

    --- Every good's metadata went once the list was too big, a weapon's
    --- hundred bytes of serial and registration with the 40 KB notes, and
    --- a refund then gave the weapon back as a new one, with nothing said.
    it('mysql: leaves out the biggest metadata only, and says what went back without it', function()
        local s = stackOn('mysql')
        local weapon = { serial = 'SER123', registered = 'Vic Marlowe', durability = 12,
                         components = { 'suppressor' } }
        local id = s.review.open({
            kind = 'escrow_take_unverified', contract_id = 'ct00000044',
            cids = { from = 'CREATOR1' },
            items = {
                { id = 'ct00000044:1', source = 'item', item = 'lockpick', quantity = 1,
                  metadata = { note = ('n'):rep(40000) } },
                { id = 'ct00000044:2', source = 'weapon', item = 'WEAPON_PISTOL', quantity = 1,
                  metadata = weapon },
                { id = 'ct00000044:3', source = 'item', item = 'radio', quantity = 1,
                  metadata = { note = ('r'):rep(40000) } },
            },
        })
        local item = s.storage.readReview(id)
        truthy(item, 'written')
        eq(item.items[1].metadata_omitted, true, 'one of the two big ones left out')
        eq(item.items[2].metadata.serial, 'SER123', 'the weapon\'s own kept')
        eq(item.items[2].metadata_omitted, nil)
        eq(#item.items[3].metadata.note, 40000, 'and the other big one, once the list fits')

        local ok, err, detail = s.review.resolve(id, { action = 'refund', who = 'from', goods = true }, 'x')
        truthy(ok, tostring(err))
        eq(detail.bare, 1, 'one good went back without its metadata')
        local answer = s.admin.reviewAnswer(id, ok, err, detail)
        truthy(answer:find('1 of the goods went without the metadata', 1, true), answer)
        local pistol
        for _, stack in ipairs(Env.players[1]._inventory) do
            if stack.name == 'WEAPON_PISTOL' then pistol = stack end
        end
        truthy(pistol and pistol.metadata and pistol.metadata.serial == 'SER123',
            'the pistol back with its serial')
    end)

    it('json: keeps the metadata whole', function()
        local s = stackOn('json')
        local id = s.review.open({
            kind = 'escrow_take_unverified', contract_id = 'ct00000043',
            items = { { id = 'ct00000043:1', source = 'item', item = 'lockpick', quantity = 1,
                        metadata = { note = ('n'):rep(70000) } } },
        })
        eq(#s.storage.readReview(id).items[1].metadata.note, 70000)
    end)
end)
