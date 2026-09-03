--- Storage conformance. The same contract is run against every backend, so
--- json mode cannot quietly behave differently from memory mode (§10.4).

local function backends()
    package.loaded['crimson-bounty.server.storage.memory'] = nil
    package.loaded['crimson-bounty.server.storage.json'] = nil
    Natives.files = {}

    local memory = require('crimson-bounty.server.storage.memory')
    local jsonStore = require('crimson-bounty.server.storage.json')
    memory.open()
    jsonStore.open()

    return { { name = 'memory', store = memory }, { name = 'json', store = jsonStore } }
end

local function contractFixture(id)
    return {
        id = id, creator_cid = 'CREATOR1', target_cid = 'TARGET01',
        mode = CB.MODE.EXCLUSIVE, state = CB.STATE.ACTIVE,
        created_at = os.time(), payout_slots = 1, next_slot = 1,
    }
end

describe('storage conformance', function()
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
