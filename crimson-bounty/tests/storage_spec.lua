--- Storage conformance. The same contract is run against every backend, so
--- json mode cannot quietly behave differently from memory mode (§10.4).

local Exec = require('crimson-bounty.tests.harness.mysql_exec')

--- Every backend, opened fresh.
---
--- mysql is in here now. It used to be tested by reading it and by a
--- simulator that only checked which columns an INSERT named, so nothing
--- proved a query returned the right rows — on the backend that ships by
--- default. mysql_exec actually executes the statements this file issues,
--- and raises on one it does not understand rather than quietly returning
--- nothing, so a gap in the coverage is visible.
local function backends()
    package.loaded['crimson-bounty.server.storage.memory'] = nil
    package.loaded['crimson-bounty.server.storage.json'] = nil
    package.loaded['crimson-bounty.server.storage.mysql'] = nil
    Natives.files = {}

    local memory = require('crimson-bounty.server.storage.memory')
    local jsonStore = require('crimson-bounty.server.storage.json')
    memory.open()
    jsonStore.open()

    Exec.install(Natives)
    local mysqlStore = require('crimson-bounty.server.storage.mysql')
    mysqlStore.open()

    return {
        { name = 'memory', store = memory },
        { name = 'json', store = jsonStore },
        { name = 'mysql', store = mysqlStore },
    }
end

local function contractFixture(id)
    return {
        id = id, creator_cid = 'CREATOR1', target_cid = 'TARGET01',
        mode = CB.MODE.EXCLUSIVE, state = CB.STATE.ACTIVE,
        created_at = os.time(), payout_slots = 1, next_slot = 1,
    }
end

describe('storage conformance', function()
    --- Every field a live contract carries, written and read back.
    ---
    --- The narrow fixture below proves a contract survives a round trip; it
    --- does not prove each value lands in the column it belongs to. Swapping
    --- two adjacent parameters in the mysql INSERT passed every test until
    --- this existed, and would have written the bailout queue timestamp into
    --- the column holding who paid it.
    it('round-trips every field of a contract in every backend', function()
        local full = {
            id = 'ctfull01', creator_cid = 'CREATOR1', creator_account = 'license:aaa',
            creator_name = 'Vic Marlowe', target_cid = 'TARGET01', target_name = 'Dana Reyes',
            target_protected = true, target_job = 'trooper', reason = 'Unpaid debt',
            mode = CB.MODE.COMPETITIVE, state = CB.STATE.ACTIVE, anon_creator = true,
            bonus_percent = 50, bailout_amount = 15000, penalty_amount = 10000,
            payout_slots = 3, slots_claimed = 1, next_slot = 2,
            created_at = 1700000001, deadline_at = 1700000002, expires_at = 1700000003,
            paused_ms = 4000, paused_since = 1700000004,
            bailout_queued_at = 1700000005, bailout_paid_by = 'TARGET01',
            bailout_paid_amount = 15000, bailout_paid_account = 'bank',
            bailout_attempts = 2,
            resolved_at = 1700000006, resolution = 'bailed_out',
        }

        for _, b in ipairs(backends()) do
            local written = {}
            for key, value in pairs(full) do written[key] = value end
            b.store.writeContract(written)

            local read = b.store.readContract('ctfull01')
            truthy(read, b.name .. ': contract not found')

            for key, value in pairs(full) do
                -- `state` is deliberately not written by writeContract; it
                -- moves only through compareSetContractState, and the row
                -- keeps whatever it already had.
                if key ~= 'state' then
                    eq(read[key], value,
                        ('%s: %s came back wrong'):format(b.name, key))
                end
            end
        end
    end)

    it('round-trips a contract in every backend', function()
        for _, b in ipairs(backends()) do
            b.store.writeContract(contractFixture('ct1'))
            local read = b.store.readContract('ct1')
            truthy(read, b.name .. ': contract not found')
            eq(read.state, CB.STATE.ACTIVE, b.name)
            eq(#b.store.allContracts(), 1, b.name)
        end
    end)

    it('honours the conditional state write in every backend', function()
        for _, b in ipairs(backends()) do
            b.store.writeContract(contractFixture('ct1'))
            truthy(b.store.compareSetContractState('ct1', CB.STATE.ACTIVE, CB.STATE.ACCEPTED), b.name)
            falsy(b.store.compareSetContractState('ct1', CB.STATE.ACTIVE, CB.STATE.ACCEPTED),
                b.name .. ': a stale expectation must not win')
            eq(b.store.readContract('ct1').state, CB.STATE.ACCEPTED, b.name)
        end
    end)

    it('claims an escrow line exactly once in every backend', function()
        for _, b in ipairs(backends()) do
            b.store.writeEscrow('ct1', { {
                id = 'ct1:1', contract_id = 'ct1', slot = 1, portion = 'baseline',
                source = 'cash', amount = 500, state = CB.ESCROW_STATE.HELD,
            } })
            truthy(b.store.claimEscrowLine('ct1:1', CB.ESCROW_STATE.HELD, CB.ESCROW_STATE.RELEASING), b.name)
            falsy(b.store.claimEscrowLine('ct1:1', CB.ESCROW_STATE.HELD, CB.ESCROW_STATE.RELEASING),
                b.name .. ': a second claim must fail')
            b.store.settleEscrowLine('ct1:1', 'HUNTER01')
            eq(b.store.readEscrowLine('ct1:1').state, CB.ESCROW_STATE.SETTLED, b.name)
        end
    end)

    it('settles only the line the caller actually holds, in every backend', function()
        -- Settling was unconditional: `WHERE id = ?`, with no check that
        -- the line was still the one this release had claimed. Both callers
        -- settle only after claiming held -> releasing, so guarding on that
        -- costs nothing and closes the case where something else took the
        -- line in between — restart recovery putting a stuck `releasing`
        -- line back to `held`, or a second server instance on the same
        -- database doing the same. Without the guard that is a line paid
        -- twice and recorded once.
        for _, b in ipairs(backends()) do
            b.store.writeEscrow('ct1', { {
                id = 'ct1:9', contract_id = 'ct1', slot = 1, portion = 'baseline',
                source = 'cash', amount = 500, state = CB.ESCROW_STATE.HELD,
            } })

            falsy(b.store.settleEscrowLine('ct1:9', 'HUNTER01'),
                b.name .. ': a held line was never claimed by this caller')
            eq(b.store.readEscrowLine('ct1:9').state, CB.ESCROW_STATE.HELD,
                b.name .. ': and must be left alone')

            truthy(b.store.claimEscrowLine('ct1:9', CB.ESCROW_STATE.HELD, CB.ESCROW_STATE.RELEASING),
                b.name)
            truthy(b.store.settleEscrowLine('ct1:9', 'HUNTER01'),
                b.name .. ': the holder settles')
            eq(b.store.readEscrowLine('ct1:9').settled_to, 'HUNTER01', b.name)

            falsy(b.store.settleEscrowLine('ct1:9', 'SOMEONE1'),
                b.name .. ': and a settled line cannot be settled again to someone else')
            eq(b.store.readEscrowLine('ct1:9').settled_to, 'HUNTER01',
                b.name .. ': the first recipient stands')
        end
    end)

    it('reads a hunter by its own id in every backend', function()
        for _, b in ipairs(backends()) do
            b.store.addHunter({
                id = 'hn0001', contract_id = 'ct1', hunter_cid = 'HUNTER01',
                hunter_account = 'license:ccc', hunter_name = 'Rook Ash',
                alias = 'Operative #1', anon = false, accepted_at = 1700000000,
                state = 'active', claims = 0,
            })
            local read = b.store.readHunterById('hn0001')
            truthy(read, b.name .. ': hunter not found by id')
            eq(read.hunter_cid, 'HUNTER01', b.name)
            falsy(b.store.readHunterById('hn9999'), b.name .. ': an unused id must read as free')
        end
    end)

    it('caps the ledger at the configured depth in every backend', function()
        for _, b in ipairs(backends()) do
            for i = 1, Config.Ledger.Depth + 5 do
                b.store.writeLedger({ cid = 'CREATOR1', contract_id = 'ct' .. i,
                    role = 'creator', resolved_at = os.time() + i })
            end
            local rows = b.store.readLedger('CREATOR1', Config.Ledger.Depth)
            eq(#rows, Config.Ledger.Depth, b.name .. ': ledger depth')
        end
    end)

    it('keeps pending escrow queryable in every backend', function()
        for _, b in ipairs(backends()) do
            b.store.queuePending('HUNTER01', 'ct1', 'ct1:1')
            eq(#b.store.readPending('HUNTER01'), 1, b.name)
            local entry = b.store.readPending('HUNTER01')[1]
            b.store.clearPending(entry.id)
            eq(#b.store.readPending('HUNTER01'), 0, b.name)
        end
    end)
end)

describe('json durability', function()
    it('survives a restart with escrow intact', function()
        package.loaded['crimson-bounty.server.storage.json'] = nil
        Natives.files = {}
        local store = require('crimson-bounty.server.storage.json')
        store.open()

        store.writeContract(contractFixture('ct1'))
        store.writeEscrow('ct1', { {
            id = 'ct1:1', contract_id = 'ct1', slot = 1, portion = 'baseline',
            source = 'cash', amount = 5000, state = CB.ESCROW_STATE.HELD,
        } })
        store.close()

        -- Reload from the same virtual disk.
        package.loaded['crimson-bounty.server.storage.json'] = nil
        local reopened = require('crimson-bounty.server.storage.json')
        reopened.open()

        truthy(reopened.readContract('ct1'), 'contract survived the restart')
        eq(reopened.readEscrowLine('ct1:1').amount, 5000, 'escrow survived the restart')
        eq(reopened.readEscrowLine('ct1:1').state, CB.ESCROW_STATE.HELD, 'still held, not lost')
    end)

    it('refuses to start on a corrupt store rather than discarding escrow', function()
        package.loaded['crimson-bounty.server.storage.json'] = nil
        Natives.files = { [(Config.Database.Json.Directory or 'data') .. '/store.json'] = '{not json at all' }
        local store = require('crimson-bounty.server.storage.json')
        local ok = pcall(store.open)
        falsy(ok, 'a corrupt store must halt the resource, not start empty')
    end)

    it('starts cleanly when there is no store yet', function()
        package.loaded['crimson-bounty.server.storage.json'] = nil
        Natives.files = {}
        local store = require('crimson-bounty.server.storage.json')
        truthy(pcall(store.open), 'a first start is not a corruption')
        eq(#store.allContracts(), 0)
    end)
end)

describe('copy-on-read semantics', function()
    --- Real databases return fresh rows, not shared tables. Anything that
    --- relies on mutating a record it read earlier breaks against MySQL,
    --- so the whole system is run against a copying backend here.
    local function copyingStack()
        local wrap = require('crimson-bounty.tests.harness.copying_store')
        local stack = newStack()
        local copying = wrap(stack.storage)

        -- Rewire every module onto the copying store.
        stack.audit.init(copying)
        stack.escrow.init(copying, stack.audit)
        stack.contracts.init({ storage = copying, escrow = stack.escrow,
            identity = stack.identity, audit = stack.audit, notify = stack.notify })
        stack.ledger.init(copying)
        stack.projection.init({ storage = copying, identity = stack.identity,
            escrow = stack.escrow, kidnap = stack.kidnap })
        stack.bailout.init({ storage = copying, identity = stack.identity,
            contracts = stack.contracts, escrow = stack.escrow,
            audit = stack.audit, notify = stack.notify })

        stack.raw = stack.storage
        stack.storage = copying
        return stack
    end

    it('does not revert a state transition when a stale copy is written', function()
        local s = copyingStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 5000 } },
        })
        truthy(c)

        -- A copy read before the transition, written after it, must not
        -- carry the old state back into storage.
        local stale = s.storage.readContract(c.id)
        s.storage.compareSetContractState(c.id, CB.STATE.ACTIVE, CB.STATE.ACCEPTED)
        stale.resolution = 'something'
        s.storage.writeContract(stale)

        eq(s.storage.readContract(c.id).state, CB.STATE.ACCEPTED,
            'a stale write must not revert the transition')
    end)

    it('resolves a contract correctly against a copying backend', function()
        local s = copyingStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 5000 } },
        })
        eq(Env.players[1].PlayerData.money.cash, 95000)

        local ok = s.contracts.resolve(c.id, CB.STATE.CANCELLED, 'CREATOR1', nil, 'cancelled')
        truthy(ok)
        eq(s.storage.readContract(c.id).state, CB.STATE.CANCELLED, 'stays cancelled')
        eq(Env.players[1].PlayerData.money.cash, 100000, 'refunded once')

        local again = s.contracts.resolve(c.id, CB.STATE.CANCELLED, 'CREATOR1', nil, 'again')
        falsy(again, 'and cannot be resolved twice')
        eq(Env.players[1].PlayerData.money.cash, 100000)
    end)

    it('claims payout slots correctly against a copying backend', function()
        local s = copyingStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { slots = {
                { baseline = { cash = 1000 } },
                { baseline = { cash = 2000 } },
            } },
        })
        truthy(s.contracts.accept(f.hunter, c.id, false))

        local ok, err, result = s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
        truthy(ok, tostring(err))
        eq(result.slot, 1)
        eq(s.storage.readContract(c.id).state, CB.STATE.ACCEPTED,
            'back to accepted with a slot remaining, not stuck completing')
        eq(s.storage.readContract(c.id).next_slot, 2, 'slot counter advanced')
        eq(Env.players[3].PlayerData.money.cash, 6000)

        Env.advance(Config.Limits.SlotCooldownSeconds + 1)
        local ok2, err2, result2 = s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
        truthy(ok2, tostring(err2))
        truthy(result2.exhausted)
        eq(s.storage.readContract(c.id).state, CB.STATE.COMPLETED)
    end)
end)

describe('the mysql schema holds every field the code writes', function()
    --- The memory and json backends store whole Lua tables, so any field the
    --- MySQL backend forgets to declare survives there for free and no test
    --- notices. These checks compare what the code actually writes against
    --- what the schema can hold, which is the only way to catch a dropped
    --- column without a live database.

    local Sim = require('crimson-bounty.tests.harness.mysql_sim')

    local function schemaFor()
        Sim.install(Natives)
        package.loaded['crimson-bounty.server.storage.mysql'] = nil
        local store = require('crimson-bounty.server.storage.mysql')
        store.open()
        return Sim
    end

    it('declares every column the contract writer names', function()
        local sim = schemaFor()
        package.loaded['crimson-bounty.server.storage.mysql'] = nil
        local store = require('crimson-bounty.server.storage.mysql')
        store.writeContract({ id = 'ct1', creator_cid = 'C', target_cid = 'T',
            mode = 'exclusive', state = 'active', created_at = 1 })
        eq(#sim.rejected, 0, table.concat(sim.rejected, '; '))
    end)

    it('can hold every field a live contract carries', function()
        local sim = schemaFor()

        -- Every field the server sets on a contract anywhere in the codebase.
        local contract = {
            id = 'ct1', creator_cid = 'C', creator_account = 'license:a',
            creator_name = 'A', target_cid = 'T', target_name = 'B',
            target_protected = false, target_job = 'unemployed', reason = 'x',
            mode = 'exclusive', state = 'active', anon_creator = false,
            bonus_percent = 50, bailout_amount = 100, penalty_amount = 100,
            payout_slots = 1, slots_claimed = 0, next_slot = 1,
            created_at = 1, deadline_at = 2, expires_at = 3,
            paused_ms = 0, paused_since = 1,
            bailout_queued_at = 1, bailout_paid_by = 'T',
            bailout_paid_amount = 100, bailout_paid_account = 'bank',
            resolved_at = 4, resolution = 'expired',
        }

        local missing = sim.missingColumns('crimson_contracts', contract)
        eq(#missing, 0, 'crimson_contracts cannot store: ' .. table.concat(missing, ', '))
    end)

    it('can hold every field a live escrow line carries', function()
        local sim = schemaFor()

        local line = {
            id = 'ct1:1', contract_id = 'ct1', slot = 1, portion = 'stake',
            source = 'bank', amount = 100, item = 'x', quantity = 1,
            metadata = {}, staker = 'HUNTER01', inv_slot = 3,
            state = 'held', settled_to = 'HUNTER01', settled_at = 1,
        }

        local missing = sim.missingColumns('crimson_escrow', line)
        eq(#missing, 0, 'crimson_escrow cannot store: ' .. table.concat(missing, ', '))
    end)

    it('can hold every field a hunter record carries', function()
        local sim = schemaFor()

        local hunter = {
            id = 'hn1', contract_id = 'ct1', hunter_cid = 'H',
            hunter_account = 'license:h', hunter_name = 'H', alias = 'Operative #1',
            anon = false, accepted_at = 1, left_at = 2, last_claim_at = 3,
            claims = 1, stake_amount = 100, state = 'active',
        }

        local missing = sim.missingColumns('crimson_hunters', hunter)
        eq(#missing, 0, 'crimson_hunters cannot store: ' .. table.concat(missing, ', '))
    end)
end)

describe('owed escrow survives in every backend', function()
    --- Money owed to a named person is the newest escrow shape, and the one
    --- it would be worst to lose: the player has already been charged.

    local function line(id)
        return {
            id = id, contract_id = 'ct1', slot = 0, portion = CB.PORTION.OWED,
            source = 'bank', amount = 5000, owed_to = 'CREATOR1',
            state = CB.ESCROW_STATE.HELD,
        }
    end

    it('round-trips its owner in memory and json', function()
        package.loaded['crimson-bounty.server.storage.memory'] = nil
        package.loaded['crimson-bounty.server.storage.json'] = nil
        Natives.files = {}

        for _, name in ipairs({ 'memory', 'json' }) do
            local store = require('crimson-bounty.server.storage.' .. name)
            store.open()
            store.writeEscrow('ct1', { line('ct1:owed1') })

            local read = store.readEscrowLine('ct1:owed1')
            truthy(read, name .. ': line not found')
            eq(read.owed_to, 'CREATOR1', name .. ': the owner must survive the round trip')
            eq(read.portion, CB.PORTION.OWED, name)
            eq(read.amount, 5000, name)
        end
    end)

    it('survives a restart in json mode', function()
        package.loaded['crimson-bounty.server.storage.json'] = nil
        Natives.files = {}
        local store = require('crimson-bounty.server.storage.json')
        store.open()
        store.writeEscrow('ct1', { line('ct1:owed1') })
        store.queuePending('CREATOR1', 'ct1', 'ct1:owed1')
        store.close()

        package.loaded['crimson-bounty.server.storage.json'] = nil
        local reopened = require('crimson-bounty.server.storage.json')
        reopened.open()

        local read = reopened.readEscrowLine('ct1:owed1')
        truthy(read, 'money already charged must not vanish on a restart')
        eq(read.owed_to, 'CREATOR1')
        eq(#reopened.readPending('CREATOR1'), 1, 'and the claim on it survives too')
    end)

    it('has a column for it in the mysql schema', function()
        local Sim = require('crimson-bounty.tests.harness.mysql_sim')
        Sim.install(Natives)
        package.loaded['crimson-bounty.server.storage.mysql'] = nil
        local store = require('crimson-bounty.server.storage.mysql')
        store.open()

        local missing = Sim.missingColumns('crimson_escrow', line('ct1:owed1'))
        eq(#missing, 0, 'crimson_escrow cannot store: ' .. table.concat(missing, ', '))
    end)
end)

describe('indexed contract lookups agree across backends', function()
    local function seeded(store)
        store.writeContract({ id = 'ct1', creator_cid = 'A', target_cid = 'B',
            mode = 'exclusive', state = 'active', created_at = 1 })
        store.writeContract({ id = 'ct2', creator_cid = 'C', target_cid = 'A',
            mode = 'exclusive', state = 'active', created_at = 2 })
        store.writeContract({ id = 'ct3', creator_cid = 'C', target_cid = 'D',
            mode = 'exclusive', state = 'active', created_at = 3 })
        store.addHunter({ id = 'hn1', contract_id = 'ct3', hunter_cid = 'A',
            accepted_at = 4, state = 'active' })
    end

    local function ids(rows)
        local out = {}
        for i = 1, #rows do out[#out + 1] = rows[i].id end
        table.sort(out)
        return table.concat(out, ',')
    end

    it('finds every contract a player is involved in, in memory and json', function()
        package.loaded['crimson-bounty.server.storage.memory'] = nil
        package.loaded['crimson-bounty.server.storage.json'] = nil
        Natives.files = {}

        for _, name in ipairs({ 'memory', 'json' }) do
            local store = require('crimson-bounty.server.storage.' .. name)
            store.open()
            seeded(store)

            -- A as creator on ct1, target on ct2, hunter on ct3.
            eq(ids(store.contractsInvolving('A')), 'ct1,ct2,ct3', name .. ': involving')
            eq(ids(store.contractsBy('C')), 'ct2,ct3', name .. ': created by')
            eq(ids(store.contractsNaming('A')), 'ct2', name .. ': naming as target')
            eq(ids(store.contractsInvolving('ZZ')), '', name .. ': nobody')
        end
    end)

    it('does not return a contract twice when a player holds two roles', function()
        package.loaded['crimson-bounty.server.storage.memory'] = nil
        local store = require('crimson-bounty.server.storage.memory')
        store.open()
        store.writeContract({ id = 'ct9', creator_cid = 'A', target_cid = 'B',
            mode = 'exclusive', state = 'active', created_at = 1 })
        store.addHunter({ id = 'hn9', contract_id = 'ct9', hunter_cid = 'A',
            accepted_at = 2, state = 'active' })
        eq(#store.contractsInvolving('A'), 1, 'creator and hunter on one contract is one row')
    end)

    it('has the indexes the mysql queries rely on', function()
        local schema = read_file('crimson-bounty/server/storage/mysql.lua')
        truthy(schema:find('INDEX idx_creator', 1, true), 'creator index')
        truthy(schema:find('INDEX idx_target', 1, true), 'target index')
        truthy(schema:find('INDEX idx_hunter', 1, true), 'hunter index')
    end)
end)


--- Schema migration.
---
--- CREATE TABLE IF NOT EXISTS creates a table and then never touches it
--- again, so a server that ran an earlier version keeps its old columns and
--- silently drops every field added since — which on this build would be the
--- stake owner, the pause marker and the whole bailout queue.
describe('mysql schema migration', function()
    local Sim = require('crimson-bounty.tests.harness.mysql_sim')

    local function opened(existing, indexes)
        Sim.install(Natives)
        if existing then Sim.existingSchema(existing, indexes) end
        package.loaded['crimson-bounty.server.storage.mysql'] = nil
        local store = require('crimson-bounty.server.storage.mysql')
        store.open()
        return store
    end

    local function addedColumns()
        local out = {}
        for _, change in ipairs(Sim.altered) do
            if change.column then out[#out + 1] = change.table_ .. '.' .. change.column end
        end
        table.sort(out)
        return out
    end

    it('adds nothing to a database it just created', function()
        opened(nil)
        eq(#Sim.altered, 0, 'a fresh install needs no migration')
    end)

    it('adds the columns an older version never had', function()
        -- A contracts table as an early build left it: no stake owner, no
        -- pause marker, no bailout queue.
        opened({
            crimson_contracts = {
                id = true, creator_cid = true, target_cid = true,
                mode = true, state = true, created_at = true,
            },
        })

        local added = addedColumns()
        local names = table.concat(added, ' ')
        truthy(names:find('crimson_contracts.paused_since', 1, true),
            'the pause marker: ' .. names)
        truthy(names:find('crimson_contracts.bailout_queued_at', 1, true),
            'the bailout queue: ' .. names)
        truthy(names:find('crimson_contracts.bailout_attempts', 1, true),
            'and the newest column: ' .. names)
    end)

    it('leaves the columns that are already there alone', function()
        opened({
            crimson_contracts = {
                id = true, creator_cid = true, target_cid = true,
                mode = true, state = true, created_at = true,
            },
        })
        for _, name in ipairs(addedColumns()) do
            falsy(name == 'crimson_contracts.id', 'must not re-add id')
            falsy(name == 'crimson_contracts.state', 'must not re-add state')
        end
    end)

    it('never drops or alters a column it does not recognise', function()
        opened({
            crimson_contracts = {
                id = true, creator_cid = true, target_cid = true,
                mode = true, state = true, created_at = true,
                -- Something an operator or an older build added.
                their_own_column = true,
            },
        })
        for _, change in ipairs(Sim.altered) do
            falsy(change.sql:find('DROP', 1, true),
                'an automatic migration that can destroy a column is worse than the '
                .. 'problem it solves: ' .. change.sql)
            falsy(change.sql:find('MODIFY', 1, true), change.sql)
            falsy(change.sql:find('their_own_column', 1, true), change.sql)
        end
    end)

    it('is idempotent — a second run changes nothing', function()
        local store = opened({
            crimson_contracts = {
                id = true, creator_cid = true, target_cid = true,
                mode = true, state = true, created_at = true,
            },
        })
        truthy(#Sim.altered > 0, 'the first run had work to do')

        Sim.altered = {}
        store.migrate()
        eq(#Sim.altered, 0, 'the second run finds nothing left')
    end)

    it('adds an index an older version never had', function()
        opened(
            { crimson_audit = { id = true, ts = true, kind = true, action = true,
                                actor_cid = true, contract_id = true, detail = true } },
            { crimson_audit = { idx_ts = true } })

        local indexes = {}
        for _, change in ipairs(Sim.altered) do
            if change.index then indexes[#indexes + 1] = change.index end
        end
        local names = table.concat(indexes, ' ')
        truthy(names:find('idx_audit_contract', 1, true),
            'the timeline index the admin command needs: ' .. names)
        falsy(names:find('idx_ts', 1, true), 'and not one that already exists')
    end)

    it('migrates every table it declares, not only contracts', function()
        opened({
            crimson_escrow = { id = true, contract_id = true, portion = true,
                               source = true, state = true },
        })
        local names = table.concat(addedColumns(), ' ')
        truthy(names:find('crimson_escrow.staker', 1, true), 'the stake owner: ' .. names)
        truthy(names:find('crimson_escrow.owed_to', 1, true), 'and the owed marker')
    end)
end)


--- The json store writes one file per contract.
---
--- It used to re-serialise and rewrite the whole store on every financial
--- write, which with a few thousand contracts is a multi-megabyte write
--- every time a coin moves.
describe('json sharding', function()
    local function fresh()
        package.loaded['crimson-bounty.server.storage.json'] = nil
        Natives.files = {}
        local store = require('crimson-bounty.server.storage.json')
        store.open()
        return store
    end

    local function contract(id, cid)
        return { id = id, creator_cid = cid or 'CREATOR1', target_cid = 'TARGET01',
                 mode = 'exclusive', state = 'active', created_at = 1 }
    end

    local function writtenFiles()
        local out = {}
        for name in pairs(Natives.files) do
            if not name:find('%.tmp$') then out[#out + 1] = name end
        end
        table.sort(out)
        return out
    end

    it('gives each contract its own file', function()
        local store = fresh()
        store.writeContract(contract('ct1'))
        store.writeContract(contract('ct2'))
        store.close()

        local files = table.concat(writtenFiles(), ' ')
        truthy(files:find('data/contracts/ct1.json', 1, true), 'ct1: ' .. files)
        truthy(files:find('data/contracts/ct2.json', 1, true), 'ct2: ' .. files)
        truthy(files:find('data/store.json', 1, true), 'and an index')
    end)

    it('rewrites only the contract that changed', function()
        local store = fresh()
        store.writeContract(contract('ct1'))
        store.writeContract(contract('ct2'))
        store.close()

        -- Watch what a single write actually touches.
        local touched = {}
        local realSave = Natives.saveFile
        Natives.saveFile = function(file) touched[file] = true end

        store.writeContract(contract('ct1'))
        store.close()
        Natives.saveFile = realSave

        falsy(touched['data/contracts/ct2.json'],
            'an untouched contract must not be rewritten')
        truthy(touched['data/contracts/ct1.json'], 'the changed one is')
    end)

    it('keeps everything a contract owns in its own file', function()
        local store = fresh()
        store.writeContract(contract('ct1'))
        store.writeEscrow('ct1', { { id = 'ct1:1', contract_id = 'ct1', portion = 'baseline',
                                     source = 'cash', amount = 5000, state = 'held', slot = 1 } })
        store.addHunter({ id = 'h1', contract_id = 'ct1', hunter_cid = 'HUNTER01',
                          state = 'active', accepted_at = 1, alias = 'Operative #1' })
        store.writeMessage({ contract_id = 'ct1', thread_id = 't1', body = 'hello' })
        store.close()

        local shard = json.decode(Natives.files['data/contracts/ct1.json'])
        truthy(shard.contract, 'the row')
        truthy(shard.escrow['ct1:1'], 'its escrow')
        truthy(shard.hunters.h1, 'its hunters')
        eq(#shard.messages, 1, 'and its messages')

        -- The index holds what is not per-contract, and no contract bodies.
        local index = json.decode(Natives.files['data/store.json'])
        falsy(index.contracts, 'the index must not carry the contracts too')
        eq(#index.contractIds, 1, 'only which ones exist')
    end)

    it('reads it all back', function()
        local store = fresh()
        store.writeContract(contract('ct1'))
        store.writeEscrow('ct1', { { id = 'ct1:1', contract_id = 'ct1', portion = 'baseline',
                                     source = 'cash', amount = 5000, state = 'held', slot = 1 } })
        store.addHunter({ id = 'h1', contract_id = 'ct1', hunter_cid = 'HUNTER01',
                          state = 'active', accepted_at = 1, alias = 'Operative #1' })
        store.close()

        package.loaded['crimson-bounty.server.storage.json'] = nil
        local reopened = require('crimson-bounty.server.storage.json')
        reopened.open()

        truthy(reopened.readContract('ct1'), 'the contract')
        eq(#reopened.readEscrow('ct1'), 1, 'its escrow')
        eq(reopened.readEscrowLine('ct1:1').amount, 5000)
        eq(#reopened.readHunters('ct1'), 1, 'and its hunters')
    end)

    it('refuses to start when a listed contract file is gone', function()
        local store = fresh()
        store.writeContract(contract('ct1'))
        store.close()

        -- The index says the contract exists and its escrow does not load.
        -- Starting anyway would quietly lose whatever it held.
        Natives.files['data/contracts/ct1.json'] = nil

        package.loaded['crimson-bounty.server.storage.json'] = nil
        local reopened = require('crimson-bounty.server.storage.json')
        local ok, err = pcall(reopened.open)
        falsy(ok, 'a missing contract file must be fatal')
        truthy(tostring(err):find('Refusing to start', 1, true), tostring(err))
    end)

    it('refuses to start on a contract file that will not parse', function()
        local store = fresh()
        store.writeContract(contract('ct1'))
        store.close()
        Natives.files['data/contracts/ct1.json'] = '{ not json'

        package.loaded['crimson-bounty.server.storage.json'] = nil
        local reopened = require('crimson-bounty.server.storage.json')
        falsy(pcall(reopened.open), 'unreadable is not empty')
    end)

    it('migrates a store written by the single-file version', function()
        package.loaded['crimson-bounty.server.storage.json'] = nil
        Natives.files = {
            ['data/store.json'] = json.encode({
                seq = 7,
                contracts = { ct1 = contract('ct1'), ct2 = contract('ct2') },
                escrow = { ['ct1:1'] = { id = 'ct1:1', contract_id = 'ct1',
                                         portion = 'baseline', source = 'cash',
                                         amount = 5000, state = 'held', slot = 1 } },
                hunters = {}, amendments = {}, messages = {},
                ledger = {}, pending = {}, audit = {}, stats = {},
            }),
        }

        local store = require('crimson-bounty.server.storage.json')
        store.open()

        truthy(Natives.files['data/contracts/ct1.json'], 'each contract gets a file')
        truthy(Natives.files['data/contracts/ct2.json'])
        truthy(Natives.files['data/store.json.bak'],
            'and the original is kept: a migration that deletes its only copy of the ' ..
            'data is not one worth having')

        eq(store.readEscrowLine('ct1:1').amount, 5000, 'nothing is lost in the move')

        -- And it reads back from the new layout on the next start.
        package.loaded['crimson-bounty.server.storage.json'] = nil
        local reopened = require('crimson-bounty.server.storage.json')
        reopened.open()
        truthy(reopened.readContract('ct2'))
        eq(reopened.readEscrowLine('ct1:1').amount, 5000)
    end)

    it('does not lose escrow whose contract row is missing', function()
        local store = fresh()
        -- An orphan is exactly the case where money must not vanish.
        store.writeEscrow('ct9', { { id = 'ct9:1', contract_id = 'ct9', portion = 'owed',
                                     owed_to = 'CREATOR1', source = 'bank',
                                     amount = 5000, state = 'held', slot = 0 } })
        store.close()

        package.loaded['crimson-bounty.server.storage.json'] = nil
        local reopened = require('crimson-bounty.server.storage.json')
        reopened.open()
        eq(reopened.readEscrowLine('ct9:1').amount, 5000,
            'money already charged must survive a restart with no contract row')
    end)

    it('bounds an ordinary flush and finishes on close', function()
        local store = fresh()
        withConfig({ { Config.Database.Json, 'MaxDirtyShardsPerFlush', 2 },
                     { Config.Database.Json, 'SyncOnFinancialWrite', false } }, function()
            for i = 1, 6 do store.writeContract(contract('ct' .. i)) end

            store.flush()
            local after = 0
            for i = 1, 6 do
                if Natives.files['data/contracts/ct' .. i .. '.json'] then after = after + 1 end
            end
            eq(after, 2, 'one flush writes at most its budget')

            store.close()
            local final = 0
            for i = 1, 6 do
                if Natives.files['data/contracts/ct' .. i .. '.json'] then final = final + 1 end
            end
            eq(final, 6, 'a shutdown writes everything regardless')
        end)
    end)

    it('will not name a file after something it did not mint', function()
        local store = fresh()
        for _, bogus in ipairs({ '../../etc/passwd', 'ct1/../../x', 'a b', '' }) do
            store.writeEscrow(bogus, { { id = 'x1', contract_id = bogus, portion = 'baseline',
                                         source = 'cash', amount = 1, state = 'held', slot = 1 } })
        end
        store.close()

        for name in pairs(Natives.files) do
            falsy(name:find('%.%.'), 'no path traversal reaches the filesystem: ' .. name)
            falsy(name:find('passwd'), name)
        end
    end)
end)

--- Every function the mysql backend exposes, executed.
---
--- The executing simulator raises on a statement it does not understand, so
--- this is what says the coverage is real: if a query shape is added that
--- the simulator cannot run, this fails by name rather than the conformance
--- suite quietly testing a little less than it did yesterday.
describe('every mysql statement is executable', function()
    it('runs every function this backend exposes', function()
        local Exec = require('crimson-bounty.tests.harness.mysql_exec')
        Exec.install(Natives)
        package.loaded['crimson-bounty.server.storage.mysql'] = nil
        local m = require('crimson-bounty.server.storage.mysql')
        m.open()

        local calls = {
            function() m.writeContract({ id='c1', creator_cid='A', target_cid='B', mode='exclusive', state='active', created_at=1 }) end,
            function() m.readContract('c1') end,
            function() m.allContracts() end,
            function() m.contractsInvolving('A') end,
            function() m.contractsNaming('B') end,
            function() m.contractsBy('A') end,
            function() m.compareSetContractState('c1','active','accepted') end,
            function() m.writeEscrow('c1', { { id='c1:1', contract_id='c1', slot=1, portion='baseline', source='cash', amount=100, state='held' } }) end,
            function() m.readEscrow('c1') end,
            function() m.readEscrowLine('c1:1') end,
            function() m.claimEscrowLine('c1:1','held','releasing') end,
            function() m.setEscrowAmount('c1:1','releasing',50,100) end,
            function() m.settleEscrowLine('c1:1','A') end,
            function() m.addHunter({ id='h1', contract_id='c1', hunter_cid='H', state='active', accepted_at=1, alias='Op' }) end,
            function() m.readHunters('c1') end,
            function() m.readHunter('c1','H') end,
            function() m.updateHunter('h1', { claims = 1 }) end,
            function() m.countHunterContracts('H', { accepted = true }) end,
            function() m.writeAmendment({ id='am1', contract_id='c1', proposer='A', kind='cancel', payload={}, approvals={}, expires_at=1, outcome='open' }) end,
            function() m.readAmendment('am1') end,
            function() m.readOpenAmendments('c1') end,
            function() m.writeMessage({ contract_id='c1', thread_id='t1', sender_cid='A', body='x', sent_at=1 }) end,
            function() m.readMessages('c1','t1') end,
            function() m.writeLedger({ cid='A', contract_id='c1', resolved_at=1 }) end,
            function() m.readLedger('A', 10) end,
            function() m.queuePending('A','c1','c1:1') end,
            function() m.readPending('A') end,
            function() m.clearPending('pnd1') end,
            function() m.bumpStat('A','completed',1) end,
            function() m.readStats('A') end,
            function() m.writeAudit({ ts=1, kind='financial', action='x', actor_cid='A', contract_id='c1', detail={} }) end,
            function() m.readAudit(10) end,
            function() m.auditForContract('c1', 10) end,
            function() m.prune() end,
            function() m.migrate() end,
        }

        local failed = {}
        for i, call in ipairs(calls) do
            local ok, err = pcall(call)
            if not ok then failed[#failed + 1] = i .. ': ' .. tostring(err) end
        end

        eq(#failed, 0,
            'the simulator could not run: ' .. table.concat(failed, ' | '))
    end)
end)


--- The store's directories have to exist before it can use them.
---
--- SaveResourceFile writes a file; it does not create the directories above
--- it. Without data/ and data/contracts/ present, every write fails and
--- returns nothing useful — escrow would be taken from players and never
--- recorded, and the first anyone would know is a restart with the
--- contracts gone.
describe('an unwritable json store', function()
    local function withFileSystem(writable)
        package.loaded['crimson-bounty.server.storage.json'] = nil
        Natives.files = {}
        -- Cleared going in as well as coming out: a blocked path left over
        -- from an earlier test is one test deciding what another measures.
        Natives.blocked = {}

        local realSave = Natives.saveFile
        Natives.saveFile = function(file)
            -- A directory that does not exist: the write goes nowhere, which
            -- is what FiveM does rather than raising.
            if not writable(file) then Natives.blocked[file] = true end
        end

        local store = require('crimson-bounty.server.storage.json')
        return store, function()
            Natives.saveFile = realSave
            Natives.blocked = {}
        end
    end

    it('refuses to start when the store directory cannot be written', function()
        local store, restore = withFileSystem(function() return false end)
        local ok, err = pcall(store.open)
        restore()

        falsy(ok, 'a store that silently drops everything is worse than no store')
        truthy(tostring(err):find('Refusing to start', 1, true), tostring(err))
        truthy(tostring(err):find('data', 1, true),
            'and the message must name the directory to create: ' .. tostring(err))
    end)

    it('refuses to start when only the contracts directory is missing', function()
        local store, restore = withFileSystem(function(file)
            return not file:find('/contracts/', 1, true)
        end)
        local ok, err = pcall(store.open)
        restore()

        falsy(ok, 'the shard directory is just as fatal as the index')
        truthy(tostring(err):find('contracts', 1, true), tostring(err))
    end)

    it('starts normally when both are writable', function()
        package.loaded['crimson-bounty.server.storage.json'] = nil
        Natives.files = {}
        Natives.blocked = {}
        local store = require('crimson-bounty.server.storage.json')
        truthy(pcall(store.open), 'an ordinary install must still start')
    end)

    it('ships the directories it needs', function()
        -- A fresh install has to arrive with them, because the resource
        -- cannot create them itself.
        for _, file in ipairs({ 'crimson-bounty/data/README.md',
                                'crimson-bounty/data/contracts/README.md' }) do
            local handle = io.open(file, 'r')
            truthy(handle, file .. ' is missing, so the directory would not exist')
            if handle then handle:close() end
        end
    end)
end)
