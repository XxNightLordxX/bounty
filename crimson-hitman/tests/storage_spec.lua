--- Storage conformance. The same contract is run against every backend, so
--- json mode cannot quietly behave differently from memory mode (§10.4).

local Exec = require('crimson-hitman.tests.harness.mysql_exec')
local Util = require('crimson-hitman.shared.util')

--- Every backend, opened fresh.
---
--- mysql is in here now. It used to be tested by reading it and by a
--- simulator that only checked which columns an INSERT named, so nothing
--- proved a query returned the right rows — on the backend that ships by
--- default. mysql_exec actually executes the statements this file issues,
--- and raises on one it does not understand rather than quietly returning
--- nothing, so a gap in the coverage is visible.
local function backends()
    package.loaded['crimson-hitman.server.storage.memory'] = nil
    package.loaded['crimson-hitman.server.storage.json'] = nil
    package.loaded['crimson-hitman.server.storage.mysql'] = nil
    Natives.files = {}

    local memory = require('crimson-hitman.server.storage.memory')
    local jsonStore = require('crimson-hitman.server.storage.json')
    memory.open()
    jsonStore.open()

    Exec.install(Natives)
    local mysqlStore = require('crimson-hitman.server.storage.mysql')
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
        mode = CH.MODE.EXCLUSIVE, state = CH.STATE.ACTIVE,
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
            creator_name = 'Vic Marlowe', target_cid = 'TARGET01', target_account = 'license:bbb',
            target_name = 'Dana Reyes',
            target_protected = true, target_job = 'trooper', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, state = CH.STATE.ACTIVE, anon_creator = true,
            fulfilment_rule = CH.FULFILMENT_RULE.ALIVE,
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

    --- A thread was never trimmed, and every read sends the whole of it to
    --- a phone: a message a second for a contract's life was tens of
    --- megabytes on every read, and the json shard rewrote all of it on
    --- every message.
    it('keeps only the newest messages of a thread in every backend', function()
        withConfig({ { Config.Relay, 'MaxMessagesPerThread', 3 } }, function()
            for _, b in ipairs(backends()) do
                for i = 1, 5 do
                    b.store.writeMessage({ contract_id = 'ct1', thread_id = 't1',
                        from_cid = 'A', from_alias = 'Client', body = 'm' .. i, sent_at = i })
                end
                b.store.writeMessage({ contract_id = 'ct1', thread_id = 't2',
                    from_cid = 'B', from_alias = 'Client', body = 'other', sent_at = 6 })

                local rows = b.store.readMessages('ct1', 't1')
                eq(#rows, 3, b.name .. ': the thread kept every message')
                eq(rows[1].body, 'm3', b.name .. ': the oldest go first')
                eq(rows[3].body, 'm5', b.name .. ': the newest stay, in order')
                eq(#b.store.readMessages('ct1', 't2'), 1,
                    b.name .. ': another thread is not touched')
            end
        end)
    end)

    it('round-trips a contract in every backend', function()
        for _, b in ipairs(backends()) do
            b.store.writeContract(contractFixture('ct1'))
            local read = b.store.readContract('ct1')
            truthy(read, b.name .. ': contract not found')
            eq(read.state, CH.STATE.ACTIVE, b.name)
            eq(#b.store.allContracts(), 1, b.name)
        end
    end)

    --- A flag that decides whether a feature runs at all.
    ---
    --- Escrow.bonusTopUp raises a percentage bonus only on slots this
    --- resource derived the bonus for; a slot where the creator named their
    --- own figure is theirs and must not be recomputed. It reads
    --- line.derived to tell them apart.
    ---
    --- crimson_escrow had no column for it, so on the backend that ships by
    --- default every bonus line read back as one the creator had named,
    --- every slot was skipped, the top-up was always empty, and raise_bonus
    --- was refused as invalid_reward — permanently, on mysql only.
    it('round-trips the derived flag on an escrow line in every backend', function()
        for _, b in ipairs(backends()) do
            b.store.writeEscrow('ct1', {
                { id = 'ct1:1', contract_id = 'ct1', slot = 1, portion = CH.PORTION.BONUS,
                  source = 'cash', amount = 500, state = CH.ESCROW_STATE.HELD,
                  derived = true },
                { id = 'ct1:2', contract_id = 'ct1', slot = 2, portion = CH.PORTION.BONUS,
                  source = 'cash', amount = 500, state = CH.ESCROW_STATE.HELD },
            })

            local derived = b.store.readEscrowLine('ct1:1')
            local named = b.store.readEscrowLine('ct1:2')
            truthy(derived and derived.derived,
                b.name .. ': a bonus this resource worked out came back looking '
                .. 'like one the creator named, so raising it does nothing')
            falsy(named and named.derived,
                b.name .. ': a bonus the creator named came back looking derived, '
                .. 'so raising it would overwrite their figure')
        end
    end)

    --- How often a line's give has raised (Escrow.deliver). It is what stops
    --- a give that raised after the item moved from giving it again on every
    --- try, so it has to survive a restart, and a copy of the line written
    --- back without it must not wipe it.
    it('keeps an escrow line\'s raise count in every backend', function()
        for _, b in ipairs(backends()) do
            local fresh = { id = 'ct1:1', contract_id = 'ct1', slot = 1,
                portion = CH.PORTION.BASELINE, source = 'item', item = 'lockpick',
                quantity = 1, state = CH.ESCROW_STATE.HELD }
            b.store.writeEscrow('ct1', { fresh })
            local counted = Util.copy(b.store.readEscrowLine('ct1:1'))
            counted.deliver_raises = 2
            b.store.writeEscrow('ct1', { counted })
            eq(tonumber(b.store.readEscrowLine('ct1:1').deliver_raises), 2,
                b.name .. ': the count is kept')

            local stale = Util.copy(fresh)
            stale.deliver_raises = nil
            stale.owed_to = 'HITMAN01'
            b.store.writeEscrow('ct1', { stale })
            local line = b.store.readEscrowLine('ct1:1')
            eq(tonumber(line.deliver_raises), 2, b.name .. ': a copy without it leaves it')
            eq(line.owed_to, 'HITMAN01', b.name .. ': while the rest of the copy is written')

            local reset = Util.copy(line)
            reset.deliver_raises = 0
            b.store.writeEscrow('ct1', { reset })
            eq(tonumber(b.store.readEscrowLine('ct1:1').deliver_raises), 0,
                b.name .. ': and staff can start it again')
        end
    end)

    --- What a give that raised part-way left with the player, and what they
    --- held before it (Escrow.deliver). A later give hands over only the
    --- rest, so the part that arrived has to survive a restart, and a copy
    --- written back without it must not wipe it: that gives it twice.
    it('keeps what part of an escrow line arrived in every backend', function()
        for _, b in ipairs(backends()) do
            local fresh = { id = 'ct1:1', contract_id = 'ct1', slot = 1,
                portion = CH.PORTION.BASELINE, source = 'item', item = 'lockpick',
                quantity = 3, state = CH.ESCROW_STATE.HELD }
            b.store.writeEscrow('ct1', { fresh })
            local part = Util.copy(b.store.readEscrowLine('ct1:1'))
            part.deliver_before, part.deliver_arrived = 4, 1
            b.store.writeEscrow('ct1', { part })
            local line = b.store.readEscrowLine('ct1:1')
            eq(tonumber(line.deliver_before), 4, b.name .. ': what they held before is kept')
            eq(tonumber(line.deliver_arrived), 1, b.name .. ': what arrived is kept')

            local stale = Util.copy(fresh)
            stale.owed_to = 'HITMAN01'
            b.store.writeEscrow('ct1', { stale })
            line = b.store.readEscrowLine('ct1:1')
            eq(tonumber(line.deliver_arrived), 1, b.name .. ': a copy without it leaves it')
            eq(tonumber(line.deliver_before), 4, b.name .. ': and what they held')
            eq(line.owed_to, 'HITMAN01', b.name .. ': while the rest of the copy is written')
        end
    end)

    --- The audit detail, as a table rather than the text it is stored in.
    ---
    --- /ch-stuck walks the log for release_interrupted rows and reads
    --- detail.line to find the escrow that was left mid-release. On mysql
    --- the column came back as the JSON string it is stored as, and
    --- indexing a string in Lua is nil rather than an error — so the command
    --- for finding stuck escrow reported "No interrupted releases" every
    --- time, on every server, however much was stuck.
    it('round-trips an audit detail as a table in every backend', function()
        for _, b in ipairs(backends()) do
            b.store.writeContract(contractFixture('ct1'))
            b.store.writeAudit({
                kind = 'financial', action = 'release_interrupted', actor_cid = 'HITMAN01',
                contract_id = 'ct1', ts = os.time(),
                detail = { line = 'ct1:1', reason = 'inventory full' },
            })

            local rows = b.store.auditForContract('ct1', 50) or {}
            local found
            for _, row in ipairs(rows) do
                if row.action == 'release_interrupted' then found = row end
            end
            truthy(found, b.name .. ': the row has to come back at all')
            eq(type(found.detail), 'table',
                b.name .. ': detail came back as ' .. type(found.detail)
                .. ', and indexing a string is nil rather than an error, so '
                .. 'every reader of it silently found nothing')
            eq(found.detail.line, 'ct1:1', b.name)
        end
    end)

    --- A row with no actor (the console) or no contract, in a batch: the nil
    --- was skipped as the values were laid out, and every value after it
    --- landed one column early, the rest of the batch with it. A console
    --- /ch-settle was logged with its action in the actor's column.
    it('writes a batch of audit rows missing an actor or a contract column by column', function()
        for _, b in ipairs(backends()) do
            if b.store.writeAuditBatch then
                b.store.writeAuditBatch({
                    { ts = os.time(), kind = 'financial', action = 'admin_settle_line',
                      detail = { line = 'ct3:1' } },
                    { ts = os.time(), kind = 'financial', action = 'escrow_released',
                      actor_cid = 'HITMAN01', contract_id = 'ct3', detail = { settled = 1 } },
                })
                local rows = b.store.auditByAction('admin_settle_line', 10) or {}
                eq(#rows, 1, b.name .. ': the row is not under its own action')
                eq(rows[1].actor_cid, nil, b.name)
                eq(rows[1].detail.line, 'ct3:1', b.name)
                rows = b.store.auditByAction('escrow_released', 10) or {}
                eq(#rows, 1, b.name .. ': nor the one after it')
                eq(rows[1].actor_cid, 'HITMAN01', b.name)
                eq(rows[1].contract_id, 'ct3', b.name)
            end
        end
    end)

    --- A staff 'delivered' gives nothing, so the line has to say why it is
    --- settled: written by the settle itself, in the same write.
    it('keeps a staff delivered on the settled line in every backend', function()
        for _, b in ipairs(backends()) do
            for _, id in ipairs({ 'ct4:1', 'ct4:2' }) do
                b.store.writeEscrow('ct4', { { id = id, contract_id = 'ct4', slot = 1,
                    portion = CH.PORTION.BASELINE, source = 'cash', amount = 5000,
                    state = CH.ESCROW_STATE.HELD } })
                truthy(b.store.claimEscrowLine(id, CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING))
            end
            truthy(b.store.settleEscrowLine('ct4:1', 'HITMAN01',
                { disposition = 'delivered', by = 'STAFF001' }))
            truthy(b.store.settleEscrowLine('ct4:2', 'HITMAN01'))
            local line = b.store.readEscrowLine('ct4:1')
            eq(line.settled_by_staff, 'delivered', b.name)
            eq(line.settled_staff, 'STAFF001', b.name .. ': and who')
            truthy(tonumber(line.settled_at), b.name .. ': and when')
            eq(b.store.readEscrowLine('ct4:2').settled_by_staff, nil,
                b.name .. ': a line given as usual says nothing of staff')
        end
    end)

    it('round-trips an audit detail through the general read too', function()
        for _, b in ipairs(backends()) do
            b.store.writeAudit({
                kind = 'financial', action = 'release_interrupted', actor_cid = 'HITMAN01',
                contract_id = 'ct2', ts = os.time(),
                detail = { line = 'ct2:1' },
            })
            local rows = b.store.readAudit(50) or {}
            local found
            for _, row in ipairs(rows) do
                if row.contract_id == 'ct2' then found = row end
            end
            truthy(found, b.name .. ': the row has to come back')
            eq(type(found.detail), 'table', b.name .. ': readAudit too')
        end
    end)

    it('honours the conditional state write in every backend', function()
        for _, b in ipairs(backends()) do
            b.store.writeContract(contractFixture('ct1'))
            truthy(b.store.compareSetContractState('ct1', CH.STATE.ACTIVE, CH.STATE.ACCEPTED), b.name)
            falsy(b.store.compareSetContractState('ct1', CH.STATE.ACTIVE, CH.STATE.ACCEPTED),
                b.name .. ': a stale expectation must not win')
            eq(b.store.readContract('ct1').state, CH.STATE.ACCEPTED, b.name)
        end
    end)

    it('claims an escrow line exactly once in every backend', function()
        for _, b in ipairs(backends()) do
            b.store.writeEscrow('ct1', { {
                id = 'ct1:1', contract_id = 'ct1', slot = 1, portion = 'baseline',
                source = 'cash', amount = 500, state = CH.ESCROW_STATE.HELD,
            } })
            truthy(b.store.claimEscrowLine('ct1:1', CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING), b.name)
            falsy(b.store.claimEscrowLine('ct1:1', CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING),
                b.name .. ': a second claim must fail')
            b.store.settleEscrowLine('ct1:1', 'HITMAN01')
            eq(b.store.readEscrowLine('ct1:1').state, CH.ESCROW_STATE.SETTLED, b.name)
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
                source = 'cash', amount = 500, state = CH.ESCROW_STATE.HELD,
            } })

            falsy(b.store.settleEscrowLine('ct1:9', 'HITMAN01'),
                b.name .. ': a held line was never claimed by this caller')
            eq(b.store.readEscrowLine('ct1:9').state, CH.ESCROW_STATE.HELD,
                b.name .. ': and must be left alone')

            truthy(b.store.claimEscrowLine('ct1:9', CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING),
                b.name)
            truthy(b.store.settleEscrowLine('ct1:9', 'HITMAN01'),
                b.name .. ': the holder settles')
            eq(b.store.readEscrowLine('ct1:9').settled_to, 'HITMAN01', b.name)

            falsy(b.store.settleEscrowLine('ct1:9', 'SOMEONE1'),
                b.name .. ': and a settled line cannot be settled again to someone else')
            eq(b.store.readEscrowLine('ct1:9').settled_to, 'HITMAN01',
                b.name .. ': the first recipient stands')
        end
    end)

    it('reads a hitman by its own id in every backend', function()
        for _, b in ipairs(backends()) do
            b.store.addHitman({
                id = 'hn0001', contract_id = 'ct1', hitman_cid = 'HITMAN01',
                hitman_account = 'license:ccc', hitman_name = 'Rook Ash',
                alias = 'Operative #1', anon = false, accepted_at = 1700000000,
                state = 'active', claims = 0,
            })
            local read = b.store.readHitmanById('hn0001')
            truthy(read, b.name .. ': hitman not found by id')
            eq(read.hitman_cid, 'HITMAN01', b.name)
            falsy(b.store.readHitmanById('hn9999'), b.name .. ': an unused id must read as free')
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

    --- A kill photo kept for a contract's client (§14.43): its state moves
    --- only from the state it is expected to be in, and closing it leaves
    --- no link behind, in every backend alike.
    it('keeps a kill photo record and its one view in every backend', function()
        for _, b in ipairs(backends()) do
            local store = b.store
            falsy(store.anyPhoto(), b.name .. ': an empty store holds no photo')
            store.writePhoto({ id = 'ph00000000aa', contract_id = 'ct1', slot = 2,
                owner_cid = 'CREATOR1', kind = 'url', url = 'https://cdn.fivemanage.com/a.png',
                state = CH.PHOTO.PENDING, created_at = 1000 })
            store.writePhoto({ id = 'ph00000000bb', contract_id = 'ct2', slot = 1,
                owner_cid = 'CREATOR2', kind = 'url', url = 'https://cdn.fivemanage.com/b.png',
                state = CH.PHOTO.PENDING, created_at = 2000 })

            truthy(store.anyPhoto(), b.name .. ': and one written is one held')
            local read = store.readPhoto('ph00000000aa')
            truthy(read, b.name .. ': written and read back')
            eq(read.owner_cid, 'CREATOR1', b.name)
            eq(read.slot, 2, b.name)
            eq(read.url, 'https://cdn.fivemanage.com/a.png', b.name)
            falsy(store.readPhoto('ph00000000zz'), b.name .. ': an unknown handle reads as nothing')

            eq(#store.photosOf('CREATOR1'), 1, b.name .. ': by owner')
            eq(#store.photosForContract('ct2'), 1, b.name .. ': by contract')
            eq(#store.photosCreatedBefore(1500, 10), 1, b.name .. ': by age')

            truthy(store.openPhoto('ph00000000aa', 1100), b.name .. ': opened')
            falsy(store.openPhoto('ph00000000aa', 1101), b.name .. ': and only once')
            eq(store.readPhoto('ph00000000aa').state, CH.PHOTO.OPEN, b.name)
            eq(store.readPhoto('ph00000000aa').opened_at, 1100, b.name)
            eq(#store.photosOpenedBefore(1200, 10), 1, b.name .. ': open too long')
            eq(#store.photosOpenedBefore(1050, 10), 0, b.name .. ': not yet')

            falsy(store.closePhoto('ph00000000bb', CH.PHOTO.OPEN, CH.PHOTO.SAVED),
                b.name .. ': a photo nobody opened cannot be closed as seen')
            truthy(store.closePhoto('ph00000000aa', CH.PHOTO.OPEN, CH.PHOTO.SAVED),
                b.name .. ': closed')
            falsy(store.closePhoto('ph00000000aa', CH.PHOTO.OPEN, CH.PHOTO.DELETED),
                b.name .. ': and not closed again the other way')
            local closed = store.readPhoto('ph00000000aa')
            eq(closed.state, CH.PHOTO.SAVED, b.name)
            falsy(closed.url, b.name .. ': no link left behind')
            eq(#store.photosOpenedBefore(5000, 10), 0, b.name .. ': no longer open')

            store.deletePhoto('ph00000000aa')
            falsy(store.readPhoto('ph00000000aa'), b.name .. ': deleted')
            eq(#store.photosOf('CREATOR1'), 0, b.name)
            truthy(store.readPhoto('ph00000000bb'), b.name .. ': and nothing else')
        end
    end)

    --- A kill photo kept on this server ('server' storage) is a record of
    --- what file it is in, of what kind and size. Every backend keeps all
    --- three, and closing it clears the file name in the same step, so no
    --- closed record still points at a picture.
    it('keeps where a photo kept on this server lives, in every backend', function()
        for _, b in ipairs(backends()) do
            local store = b.store
            store.writePhoto({ id = 'ph00000000cc', contract_id = 'ct3', slot = 1,
                owner_cid = 'CREATOR1', kind = 'file', file = 'data/photos/ph00000000cc.webp',
                mime = 'image/webp', size = 183456,
                state = CH.PHOTO.PENDING, created_at = 1000 })

            local read = store.readPhoto('ph00000000cc')
            truthy(read, b.name .. ': written and read back')
            eq(read.kind, 'file', b.name)
            eq(read.file, 'data/photos/ph00000000cc.webp', b.name)
            eq(read.mime, 'image/webp', b.name)
            eq(tonumber(read.size), 183456, b.name)
            falsy(read.url, b.name .. ': and no link')

            truthy(store.openPhoto('ph00000000cc', 1100), b.name)
            truthy(store.closePhoto('ph00000000cc', CH.PHOTO.OPEN, CH.PHOTO.DELETED), b.name)
            local closed = store.readPhoto('ph00000000cc')
            eq(closed.state, CH.PHOTO.DELETED, b.name)
            falsy(closed.file, b.name .. ': no file name left behind')
        end
    end)

    --- A photo kept on this server can be served to its client's phone
    --- under a name of its own, and kept for them in the app. Every
    --- backend finds it by that name, moves its state only from the one
    --- expected, keeps its file through a save by link, and leaves both
    --- kinds out of what the retention may forget.
    it('keeps a served or kept photo, and finds it by its served name, in every backend', function()
        for _, b in ipairs(backends()) do
            local store = b.store
            for i, id in ipairs({ 'ph00000000dd', 'ph00000000ee', 'ph00000000ff' }) do
                store.writePhoto({ id = id, contract_id = 'ct' .. i, slot = 1,
                    owner_cid = 'CREATOR1', kind = 'file', file = 'data/photos/' .. id .. '.webp',
                    mime = 'image/webp', size = 1000 * i,
                    state = CH.PHOTO.PENDING, created_at = 1000 })
                truthy(store.openPhoto(id, 1100), b.name)
            end

            -- Served: a name and a link, state unmoved, then saved by link.
            falsy(store.publishPhoto('ph00000000dd', CH.PHOTO.PENDING, 'Zk3_q-9xWb2LmT0cRf8aNd',
                'https://x.example/p/a.webp', '555-1'), b.name .. ': only from the state expected')
            truthy(store.publishPhoto('ph00000000dd', CH.PHOTO.OPEN, 'Zk3_q-9xWb2LmT0cRf8aNd',
                'https://x.example/p/a.webp', '555-1'), b.name)
            local served = store.readPhotoByPublic('Zk3_q-9xWb2LmT0cRf8aNd')
            truthy(served, b.name .. ': found by its served name')
            eq(served.id, 'ph00000000dd', b.name)
            eq(served.state, CH.PHOTO.OPEN, b.name .. ': still open until the phone has it')
            eq(served.saved_link, 'https://x.example/p/a.webp', b.name)
            eq(served.saved_phone, '555-1', b.name)
            falsy(store.readPhotoByPublic('ph00000000dd'), b.name .. ': not by its handle')
            falsy(store.readPhotoByPublic('nothing-by-this-name'), b.name)
            truthy(store.movePhoto('ph00000000dd', CH.PHOTO.OPEN, CH.PHOTO.SAVED), b.name)
            falsy(store.movePhoto('ph00000000dd', CH.PHOTO.OPEN, CH.PHOTO.DELETED), b.name)
            eq(store.readPhoto('ph00000000dd').file, 'data/photos/ph00000000dd.webp',
                b.name .. ': saved by link, the file stays')

            -- Kept in the app, its file moved.
            truthy(store.keepPhoto('ph00000000ee', CH.PHOTO.OPEN,
                'data/photos/kept/ph00000000ee.webp'), b.name)
            falsy(store.keepPhoto('ph00000000ee', CH.PHOTO.OPEN, nil), b.name .. ': once')
            local kept = store.readPhoto('ph00000000ee')
            eq(kept.state, CH.PHOTO.KEPT, b.name)
            eq(kept.file, 'data/photos/kept/ph00000000ee.webp', b.name)
            eq(#store.photosOpenedBefore(5000, 10, CH.PHOTO.KEPT), 1, b.name .. ': kept, by age')
            eq(#store.photosOpenedBefore(1050, 10, CH.PHOTO.KEPT), 0, b.name)

            -- Neither is the retention's.
            local old = store.photosCreatedBefore(5000, 10)
            eq(#old, 1, b.name .. ': only the photo that is neither kept nor served')
            eq(old[1].id, 'ph00000000ff', b.name)

            local totals = store.photoTotals()
            eq(totals[CH.PHOTO.SAVED].count, 1, b.name)
            eq(totals[CH.PHOTO.SAVED].bytes, 1000, b.name)
            eq(totals[CH.PHOTO.KEPT].bytes, 2000, b.name)
            eq(totals[CH.PHOTO.OPEN].count, 1, b.name)

            -- Closing lets go of the served name with the file.
            truthy(store.closePhoto('ph00000000dd', CH.PHOTO.SAVED, CH.PHOTO.DELETED), b.name)
            local closed = store.readPhoto('ph00000000dd')
            falsy(closed.public_id, b.name .. ': not served again')
            falsy(closed.saved_link or closed.saved_phone or closed.file, b.name)
            falsy(store.readPhotoByPublic('Zk3_q-9xWb2LmT0cRf8aNd'), b.name)
        end
    end)

    --- A thread mute (§11.4): one per thread and person, the same when
    --- written twice, and gone on unmute.
    it('keeps a thread mute per thread and person in every backend', function()
        for _, b in ipairs(backends()) do
            b.store.setMute('ct1', 'ct1|HITMAN01', 'CREATOR1', true, 100)
            b.store.setMute('ct1', 'ct1|HITMAN01', 'CREATOR1', true, 200)
            truthy(b.store.readMute('ct1|HITMAN01', 'CREATOR1'), b.name .. ': muted')
            falsy(b.store.readMute('ct1|HITMAN01', 'HITMAN01'),
                b.name .. ': for the one who muted it, not the other end')
            falsy(b.store.readMute('ct1|HITMAN02', 'CREATOR1'), b.name .. ': and that thread only')
            b.store.setMute('ct1', 'ct1|HITMAN01', 'CREATOR1', false, 300)
            falsy(b.store.readMute('ct1|HITMAN01', 'CREATOR1'), b.name .. ': unmuted')
        end
    end)

    it('json: keeps a thread mute across a restart', function()
        local store
        for _, b in ipairs(backends()) do
            if b.name == 'json' then store = b.store end
        end
        store.writeContract(contractFixture('ct00000041'))
        store.setMute('ct00000041', 'ct00000041|HITMAN01', 'CREATOR1', true, 100)
        store.save(true)

        store.open()
        truthy(store.readMute('ct00000041|HITMAN01', 'CREATOR1'),
            'a restart started the phone ringing again for a muted thread')
    end)

    it('keeps pending escrow queryable in every backend', function()
        for _, b in ipairs(backends()) do
            b.store.queuePending('HITMAN01', 'ct1', 'ct1:1')
            eq(#b.store.readPending('HITMAN01'), 1, b.name)
            local entry = b.store.readPending('HITMAN01')[1]
            b.store.clearPending(entry.id)
            eq(#b.store.readPending('HITMAN01'), 0, b.name)
        end
    end)

    --- The sampler, the expiry pass and the board read these and nothing
    --- else; recovery reads the whole table. A backend that let a finished
    --- contract through, or left a running one out, would differ from the
    --- others on exactly the contracts those passes act on.
    it('lists the running contracts, and only those, in every backend', function()
        for _, b in ipairs(backends()) do
            local states = {
                ct1 = CH.STATE.ACTIVE, ct2 = CH.STATE.ACCEPTED, ct3 = CH.STATE.COMPLETING,
                ct4 = CH.STATE.COMPLETED, ct5 = CH.STATE.EXPIRED, ct6 = CH.STATE.ACCEPTED,
            }
            for id in pairs(states) do b.store.writeContract(contractFixture(id)) end
            for id, state in pairs(states) do
                if state ~= CH.STATE.ACTIVE then
                    b.store.compareSetContractState(id, CH.STATE.ACTIVE, state)
                end
            end
            local live = b.store.liveContracts()
            local ids = {}
            for i = 1, #live do ids[i] = live[i].id end
            eq(table.concat(ids, ','), 'ct1,ct2,ct6', b.name .. ': by id, running only')
            eq(#b.store.allContracts(), 6, b.name .. ': and the whole table still has them all')
        end
    end)

    --- Read once at a start, in place of a read per contract kept.
    it('names the contracts holding unsettled escrow or an open proposal, in every backend', function()
        for _, b in ipairs(backends()) do
            local function line(id, contractId, state)
                return { id = id, contract_id = contractId, slot = 1, portion = 'baseline',
                         source = 'cash', amount = 100, state = state }
            end
            b.store.writeEscrow('ct1', { line('ct1:1', 'ct1', CH.ESCROW_STATE.SETTLED),
                                         line('ct1:2', 'ct1', CH.ESCROW_STATE.HELD) })
            b.store.writeEscrow('ct2', { line('ct2:1', 'ct2', CH.ESCROW_STATE.SETTLED) })
            b.store.writeEscrow('ct3', { line('ct3:1', 'ct3', CH.ESCROW_STATE.HELD) })
            truthy(b.store.claimEscrowLine('ct3:1', CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING))
            local unsettled = b.store.unsettledEscrowContracts()
            truthy(unsettled.ct1, b.name .. ': a held line among settled ones')
            falsy(unsettled.ct2, b.name .. ': every line settled')
            truthy(unsettled.ct3, b.name .. ': a line mid-release')

            b.store.writeAmendment({ id = 'am1', contract_id = 'ct1', proposer = 'CREATOR1',
                kind = 'bonus', payload = {}, approvals = {}, expires_at = os.time() + 60,
                outcome = 'open' })
            b.store.writeAmendment({ id = 'am2', contract_id = 'ct2', proposer = 'CREATOR1',
                kind = 'bonus', payload = {}, approvals = {}, expires_at = os.time() + 60,
                outcome = 'expired' })
            local open = b.store.openAmendmentContracts()
            truthy(open.ct1, b.name)
            falsy(open.ct2, b.name .. ': a closed proposal is not open')
        end
    end)

    --- readEscrow and readHitmen answer from a per-contract index in memory
    --- and json now. A row written again under its id, or a contract's rows
    --- pruned, must read exactly as before.
    it('reads one contract\'s lines and roster exactly, through every rewrite, in every backend', function()
        for _, b in ipairs(backends()) do
            local function line(id, contractId, amount)
                return { id = id, contract_id = contractId, slot = 1, portion = 'baseline',
                         source = 'cash', amount = amount, state = CH.ESCROW_STATE.HELD }
            end
            b.store.writeEscrow('ct1', { line('ct1:2', 'ct1', 200), line('ct1:1', 'ct1', 100) })
            b.store.writeEscrow('ct2', { line('ct2:1', 'ct2', 300) })
            -- The same line again, as a separate copy: only its owed_to moves.
            local again = line('ct1:1', 'ct1', 999)
            again.owed_to = 'CREATOR1'
            b.store.writeEscrow('ct1', { again })

            local lines = b.store.readEscrow('ct1')
            eq(#lines, 2, b.name)
            eq(lines[1].id, 'ct1:1', b.name .. ': sorted by id')
            eq(lines[1].amount, 100, b.name .. ': the amount is not the copy\'s to move')
            eq(lines[1].owed_to, 'CREATOR1', b.name)
            eq(#b.store.readEscrow('ct2'), 1, b.name)
            eq(#b.store.readEscrow('ct9'), 0, b.name)

            b.store.addHitman({ id = 'h1', contract_id = 'ct1', hitman_cid = 'HITMAN01',
                state = 'active', accepted_at = 10 })
            b.store.addHitman({ id = 'h2', contract_id = 'ct1', hitman_cid = 'HITMAN02',
                state = 'active', accepted_at = 5 })
            b.store.addHitman({ id = 'h3', contract_id = 'ct2', hitman_cid = 'HITMAN01',
                state = 'active', accepted_at = 1 })
            local roster = b.store.readHitmen('ct1')
            eq(#roster, 2, b.name)
            eq(roster[1].id, 'h2', b.name .. ': by acceptance')
            eq(b.store.readHitman('ct2', 'HITMAN01').id, 'h3', b.name)
            eq(b.store.readHitman('ct2', 'HITMAN02'), nil, b.name)
        end
    end)
end)

--- Retention, run against every backend, because a store that prunes a
--- little differently from the others is a store that loses somebody's
--- money on one deployment and not another.
---
--- Nothing pruned contracts at all before this, so every full scan in the
--- resource — the board projection per player per board open, the death
--- sampler once a second, the bailout queue every tick — walked the
--- server's whole history rather than its live board, and grew without
--- bound for the life of the database.
describe('finished contracts do not accumulate forever', function()
    local DAY = 86400

    local function settled(store, id, resolvedAt)
        store.writeContract({
            id = id, creator_cid = 'CREATOR1', target_cid = 'TARGET01',
            mode = CH.MODE.EXCLUSIVE, state = CH.STATE.COMPLETED,
            created_at = resolvedAt - DAY, resolved_at = resolvedAt,
            payout_slots = 1, next_slot = 1,
        })
        -- Written held and settled through the guarded call, not written
        -- settled. writeEscrow deliberately does not carry state, settled_to
        -- or settled_at on the mysql backend — those move only through
        -- settleEscrowLine — so a line written settled arrives held there
        -- with nobody named on it. The invariant monitor caught that as
        -- "settled to nobody", which is exactly what it was.
        store.writeEscrow(id, { {
            id = id .. ':1', contract_id = id, slot = 1,
            portion = CH.PORTION.BASELINE, source = 'cash', amount = 5000,
            state = CH.ESCROW_STATE.HELD,
        } })
        store.claimEscrowLine(id .. ':1', CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING)
        store.settleEscrowLine(id .. ':1', 'HITMAN01')
        return id
    end

    it('removes a finished contract past the retention age', function()
        local old = os.time() - (Config.Audit.ContractRetentionDays + 1) * DAY
        for _, backend in ipairs(backends()) do
            settled(backend.store, 'ct00000001', old)
            truthy(backend.store.readContract('ct00000001'),
                backend.name .. ': the fixture must exist')
            backend.store.setMute('ct00000001', 'ct00000001|HITMAN01', 'CREATOR1', true, old)

            backend.store.prune()

            falsy(backend.store.readMute('ct00000001|HITMAN01', 'CREATOR1'),
                backend.name .. ': a mute goes with the thread it silenced')

            falsy(backend.store.readContract('ct00000001'),
                backend.name .. ': a finished contract is not kept forever')
            eq(#backend.store.readEscrow('ct00000001'), 0,
                backend.name .. ': and neither are its escrow rows')
        end
    end)

    -- The death sampler's one roster read a pass, in place of a readHitmen
    -- per running contract: on mysql those were 1 + N awaited queries a
    -- second. It must answer exactly what readHitmen does, for the running
    -- contracts and no others.
    it('reads every running contract\'s hitmen at once, as readHitmen would', function()
        for _, backend in ipairs(backends()) do
            local store = backend.store
            for i, state in ipairs({ CH.STATE.ACTIVE, CH.STATE.ACCEPTED, CH.STATE.COMPLETED }) do
                local c = contractFixture('ctlive0' .. i)
                c.state = state
                store.writeContract(c)
                for j = 2, 1, -1 do
                    store.addHitman({ id = 'h' .. i .. j, contract_id = c.id,
                        hitman_cid = 'HIT' .. i .. j, state = 'active',
                        accepted_at = 100 + j, alias = 'Op' })
                end
            end

            local rosters = store.liveHitmen()
            for i = 1, 2 do
                local id = 'ctlive0' .. i
                local expected = store.readHitmen(id)
                eq(#(rosters[id] or {}), #expected, backend.name .. ': ' .. id)
                for k = 1, #expected do
                    eq(rosters[id][k].hitman_cid, expected[k].hitman_cid,
                        backend.name .. ': in readHitmen order')
                end
            end
            eq(rosters['ctlive03'], nil, backend.name .. ': a finished contract is not running')
        end
    end)

    it('json: deletes the pruned contract\'s file from the resource folder', function()
        -- SaveResourceFile resolves against the resource; os.remove resolves
        -- against the server's working directory. The relative path named a
        -- file that is not there, so no pruned file was ever deleted.
        local old = os.time() - (Config.Audit.ContractRetentionDays + 1) * DAY
        local store
        for _, backend in ipairs(backends()) do
            if backend.name == 'json' then store = backend.store end
        end
        settled(store, 'ct00000009', old)

        local removed = {}
        local realRemove, realPath = os.remove, _G.GetResourcePath
        _G.GetResourcePath = function() return '/srv/resources/crimson-hitman' end
        os.remove = function(path) removed[#removed + 1] = path return true end
        local ok, err = pcall(store.prune)
        os.remove, _G.GetResourcePath = realRemove, realPath
        truthy(ok, tostring(err))

        eq(removed[1], '/srv/resources/crimson-hitman/data/contracts/ct00000009.json',
            'the file is removed where SaveResourceFile wrote it')
    end)

    it('json: has the index without it on disk before the file goes', function()
        local old = os.time() - (Config.Audit.ContractRetentionDays + 1) * DAY
        local store
        for _, backend in ipairs(backends()) do
            if backend.name == 'json' then store = backend.store end
        end
        settled(store, 'ct00000019', old)
        store.save(true)

        local indexAtUnlink
        local realRemove, realPath = os.remove, _G.GetResourcePath
        _G.GetResourcePath = function() return '/srv/resources/crimson-hitman' end
        os.remove = function(path)
            indexAtUnlink = Natives.files and Natives.files['data/store.json'] or ''
            return true
        end
        local ok, err = pcall(store.prune)
        os.remove, _G.GetResourcePath = realRemove, realPath
        truthy(ok, tostring(err))
        truthy(indexAtUnlink, 'nothing was removed')
        falsy(tostring(indexAtUnlink):find('ct00000019', 1, true),
            'the file went while the index on disk still named it')
    end)

    it('json: removes the file on the next flush when the prune could not write the index', function()
        -- Only the prune drained the list, and it returns early when there
        -- is nothing new to prune: one failed index write left the file on
        -- disk for good.
        local old = os.time() - (Config.Audit.ContractRetentionDays + 1) * DAY
        local store
        for _, backend in ipairs(backends()) do
            if backend.name == 'json' then store = backend.store end
        end
        settled(store, 'ct00000029', old)
        store.save(true)

        local removed = {}
        local realRemove, realPath = os.remove, _G.GetResourcePath
        _G.GetResourcePath = function() return '/srv/resources/crimson-hitman' end
        os.remove = function(path) removed[#removed + 1] = path return true end
        Natives.blocked = { ['data/store.json'] = true }
        pcall(store.prune)
        Natives.blocked = {}
        eq(#removed, 0, 'not while the index still names it')
        local ok = pcall(store.save, true)
        os.remove, _G.GetResourcePath = realRemove, realPath
        truthy(ok)
        eq(removed[1], '/srv/resources/crimson-hitman/data/contracts/ct00000029.json',
            'removed once an index without it is on disk')
    end)

    it('keeps one that has only just finished', function()
        local recent = os.time() - DAY
        for _, backend in ipairs(backends()) do
            settled(backend.store, 'ct00000002', recent)
            backend.store.prune()
            truthy(backend.store.readContract('ct00000002'),
                backend.name .. ': the retention window is not optional')
        end
    end)

    it('keeps a live contract however old it is', function()
        for _, backend in ipairs(backends()) do
            local c = contractFixture('ct00000003')
            c.created_at = os.time() - 3650 * DAY
            backend.store.writeContract(c)
            backend.store.prune()
            truthy(backend.store.readContract('ct00000003'),
                backend.name .. ': age is not a reason to delete a live contract')
        end
    end)

    --- The two that matter. A contract whose creator was offline when it
    --- closed holds their money in a `held` OWED line with a pending row
    --- pointing at it, and removing either takes that money with it.
    it('keeps one still holding an unsettled escrow line', function()
        local old = os.time() - (Config.Audit.ContractRetentionDays + 1) * DAY
        for _, backend in ipairs(backends()) do
            settled(backend.store, 'ct00000004', old)
            backend.store.writeEscrow('ct00000004', { {
                id = 'owe00000001', contract_id = 'ct00000004', slot = 0,
                portion = CH.PORTION.OWED, owed_to = 'CREATOR1',
                source = 'bank', amount = 20000,
                state = CH.ESCROW_STATE.HELD,
            } })

            backend.store.prune()

            truthy(backend.store.readContract('ct00000004'),
                backend.name .. ': money is still owed on this one')
            truthy(backend.store.readEscrowLine('owe00000001'),
                backend.name .. ': and the line holding it must survive')
        end
    end)

    it('keeps one somebody is owed money on at their next login', function()
        local old = os.time() - (Config.Audit.ContractRetentionDays + 1) * DAY
        for _, backend in ipairs(backends()) do
            settled(backend.store, 'ct00000005', old)
            backend.store.writeEscrow('ct00000005', { {
                id = 'owe00000005', contract_id = 'ct00000005', slot = 0,
                portion = CH.PORTION.OWED, owed_to = 'CREATOR1',
                source = 'bank', amount = 20000, state = CH.ESCROW_STATE.HELD,
            } })
            backend.store.queuePending('CREATOR1', 'ct00000005', 'owe00000005')

            backend.store.prune()

            truthy(backend.store.readContract('ct00000005'),
                backend.name .. ': a queued payout points at this contract')
            truthy(#backend.store.readPending('CREATOR1') > 0,
                backend.name .. ': and the queue entry must survive')
        end
    end)

    --- A payout handed over at once leaves its queue entry behind until the
    --- player's next login. One who never came back held the contract here
    --- for good, and every mode switch after it, with nothing owed.
    it('does not keep one for a queue entry whose payout was handed over, in every backend', function()
        local old = os.time() - (Config.Audit.ContractRetentionDays + 1) * DAY
        for _, backend in ipairs(backends()) do
            settled(backend.store, 'ct00000015', old)
            backend.store.queuePending('TARGET01', 'ct00000015', 'ct00000015:1')
            backend.store.queuePending('TARGET01', 'ct00000015', 'ct00000015:9')

            backend.store.prune()

            falsy(backend.store.readContract('ct00000015'),
                backend.name .. ': its line is settled and the other is not there; nothing is owed')
        end
    end)

    --- A review item's advice is read against its contract: "if the contract
    --- shows the buyout, dismiss; if not, refund". Pruned under an open one,
    --- the item read "contract none" and staff refunded a buyout that had
    --- already been used.
    it('keeps one an open review item names until it is resolved, in every backend', function()
        local old = os.time() - (Config.Audit.ContractRetentionDays + 1) * DAY
        for _, backend in ipairs(backends()) do
            local store = backend.store
            settled(store, 'ct00000016', old)
            store.writeReview({ id = 'rv00000016', kind = 'bailout_unrecorded',
                contract_id = 'ct00000016', cids = { payer = 'TARGET01' }, amount = 5000,
                account = 'bank', created_at = old, state = 'open' })

            store.prune()
            truthy(store.readContract('ct00000016'), backend.name .. ': open, the item needs it')

            truthy(store.setReviewState('rv00000016', 'open', 'resolving',
                { resolution = { action = 'dismiss' }, resolved_by = 'STAFF01' }))
            store.prune()
            truthy(store.readContract('ct00000016'), backend.name .. ': and while it is resolving')

            truthy(store.setReviewState('rv00000016', 'resolving', 'resolved',
                { resolution = { action = 'dismiss' }, resolved_by = 'STAFF01', resolved_at = os.time() }))
            store.prune()
            falsy(store.readContract('ct00000016'), backend.name .. ': pruned once it is resolved')
        end
    end)

    it('leaves the ledger alone', function()
        -- The player's own record of what they did, with its own copy of
        -- the target name and reason. It outlives the contract.
        local old = os.time() - (Config.Audit.ContractRetentionDays + 1) * DAY
        for _, backend in ipairs(backends()) do
            settled(backend.store, 'ct00000006', old)
            backend.store.writeLedger({
                cid = 'HITMAN01', contract_id = 'ct00000006', role = 'hitman',
                target_name = 'Dana Reyes', reason = 'Unpaid debt',
                fulfilment = 'elimination', slot = 1, resolved_at = old,
            })

            backend.store.prune()

            falsy(backend.store.readContract('ct00000006'))
            eq(#backend.store.readLedger('HITMAN01', 10), 1,
                backend.name .. ': history is the player\'s, not the contract\'s')
        end
    end)

    it('keeps everything when retention is switched off', function()
        local old = os.time() - 3650 * DAY
        local stores = backends()
        for _, backend in ipairs(stores) do settled(backend.store, 'ct00000007', old) end

        withConfig({ { Config.Audit, 'ContractRetentionDays', 0 } }, function()
            for _, backend in ipairs(stores) do
                backend.store.prune()
                truthy(backend.store.readContract('ct00000007'),
                    backend.name .. ': 0 means keep them, which is what this '
                    .. 'did before it was a setting')
            end
        end)
    end)

    it('removes no more than one tick is allowed to', function()
        -- A first prune on a long-lived database has a lot to get through,
        -- and doing it in one tick would stall the server.
        local old = os.time() - 3650 * DAY
        local stores = backends()
        for _, backend in ipairs(stores) do
            for i = 1, 6 do settled(backend.store, ('ct0000%04d'):format(i), old) end
        end

        withConfig({ { Config.Audit, 'ContractsPrunedPerTick', 2 } }, function()
            for _, backend in ipairs(stores) do
                backend.store.prune()
                eq(#backend.store.allContracts(), 4,
                    backend.name .. ': the cap is a cap')
                backend.store.prune()
                eq(#backend.store.allContracts(), 2, backend.name .. ': and it resumes')
            end
        end)
    end)
end)

--- The executor these tests read mysql through has to be loud about a
--- statement shape it does not understand, or every mysql test above it is
--- worth nothing. Its condition reader used to scan for `col = value` pairs
--- and ignore the rest of the clause, so a query whose real filtering lived
--- in a range, an IS NOT NULL, an IN list or a subquery matched every row
--- in the table and the test reading that result could not tell.
describe('the mysql executor refuses a statement it cannot read', function()
    local Exec = require('crimson-hitman.tests.harness.mysql_exec')

    local function loaded()
        Exec.install(Natives)
        Exec.run('CREATE TABLE IF NOT EXISTS t (id VARCHAR(32) PRIMARY KEY, n INT, tag VARCHAR(8))')
        Exec.run('INSERT INTO t (id, n, tag) VALUES (?, ?, ?)', { 'a', 1, 'x' })
        Exec.run('INSERT INTO t (id, n, tag) VALUES (?, ?, ?)', { 'b', 2, 'y' })
        return Exec
    end

    it('raises rather than matching every row', function()
        local exec = loaded()

        local ok, err = pcall(exec.run, 'SELECT * FROM t WHERE n BETWEEN 1 AND 2', {})
        falsy(ok, 'BETWEEN is not a shape this reads, so it must not match silently')
        truthy(tostring(err):find('cannot read', 1, true), tostring(err))

        local orOk, orErr = pcall(exec.run, 'SELECT * FROM t WHERE id = ? OR n = ?', { 'a', 2 })
        falsy(orOk, 'nor is OR, which as a conjunction would narrow the answer')
        truthy(tostring(orErr):find('OR is not supported', 1, true), tostring(orErr))
    end)

    it('reads the shapes the backend actually issues', function()
        local exec = loaded()
        eq(#exec.run('SELECT * FROM t WHERE n < ?', { 2 }), 1, 'a range')
        eq(#exec.run("SELECT * FROM t WHERE tag IN ('x','y')", {}), 2, 'an IN list')
        eq(#exec.run('SELECT * FROM t WHERE tag IS NOT NULL', {}), 2, 'a null check')
        eq(#exec.run("SELECT * FROM t WHERE tag <> 'x'", {}), 1, 'an inequality')
    end)

    it('evaluates a correlated NOT EXISTS against the other table', function()
        local exec = loaded()
        exec.run('CREATE TABLE IF NOT EXISTS u (id VARCHAR(32) PRIMARY KEY, t_id VARCHAR(32), state VARCHAR(8))')
        exec.run('INSERT INTO u (id, t_id, state) VALUES (?, ?, ?)', { 'u1', 'a', 'open' })
        exec.run('INSERT INTO u (id, t_id, state) VALUES (?, ?, ?)', { 'u2', 'b', 'done' })

        local rows = exec.run([[
            SELECT * FROM t
            WHERE NOT EXISTS (SELECT 1 FROM u WHERE u.t_id = t.id AND u.state <> 'done')
        ]], {})
        eq(#rows, 1, 'only the row with nothing open against it')
        eq(rows[1].id, 'b')
    end)
end)

--- MariaDB 10.11 runs oxmysql's connections in strict mode (OXMYSQL.md
--- §5): a value its column cannot hold is refused, not cut or wrapped. The
--- executor stored anything, so a paused_ms past INT, money past INT and
--- item metadata past TEXT never failed a test, and three fixtures above
--- wrote rows a real database refuses (a missing kind, from_cid, role).
describe('the mysql executor refuses what strict MariaDB refuses', function()
    local Exec = require('crimson-hitman.tests.harness.mysql_exec')

    local function loaded()
        Exec.install(Natives)
        Exec.run([[CREATE TABLE IF NOT EXISTS t (
            id VARCHAR(16) PRIMARY KEY,
            n INT DEFAULT 7,
            body TEXT,
            must VARCHAR(8) NOT NULL,
            flag TINYINT(1) DEFAULT 0
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]])
        return Exec
    end

    --- What the store would see: the error oxmysql's await raises.
    local function refused(sql, params)
        local ok, err = pcall(Exec.run, sql, params)
        falsy(ok, 'accepted: ' .. sql)
        return tostring(err)
    end

    local INSERT = 'INSERT INTO t (id, n, body, must) VALUES (?, ?, ?, ?)'

    it('refuses an INT past its range, at either end, and takes its last value', function()
        loaded()
        local err = refused(INSERT, { 'a', 2147483648, 'x', 'm' })
        truthy(err:find("Out of range value for column 'n' at row 1", 1, true), err)
        truthy(err:find('was unable to execute a query!', 1, true), 'in oxmysql\'s words: ' .. err)
        truthy(err:find('2147483648', 1, true), 'with the parameters, as oxmysql sends them: ' .. err)
        err = refused(INSERT, { 'a', -2147483649, 'x', 'm' })
        truthy(err:find("Out of range value for column 'n'", 1, true), err)
        Exec.run(INSERT, { 'a', 2147483647, 'x', 'm' })
        eq(Exec.run('SELECT * FROM t WHERE id = ?', { 'a' })[1].n, 2147483647)
        err = refused('UPDATE t SET n = n + ? WHERE id = ?', { 1, 'a' })
        truthy(err:find("Out of range value for column 'n' at row 1", 1, true), 'an UPDATE too: ' .. err)
        eq(Exec.run('SELECT * FROM t WHERE id = ?', { 'a' })[1].n, 2147483647, 'and left it as it was')
    end)

    it('counts a VARCHAR in characters and a TEXT in bytes', function()
        loaded()
        local err = refused(INSERT, { ('x'):rep(17), 1, 'x', 'm' })
        truthy(err:find("Data too long for column 'id' at row 1", 1, true), err)
        -- Sixteen four-byte characters are sixty-four bytes and fit.
        Exec.run(INSERT, { ('\u{1F600}'):rep(16), 1, 'x', 'm' })
        eq(#Exec.run('SELECT * FROM t', {}), 1, 'sixteen characters of four bytes each fit a VARCHAR(16)')

        Exec.run(INSERT, { 'b', 1, ('y'):rep(65535), 'm' })
        err = refused(INSERT, { 'c', 1, ('y'):rep(65536), 'm' })
        truthy(err:find("Data too long for column 'body' at row 1", 1, true), err)
    end)

    it('refuses NULL in a NOT NULL column, and one left out with no default', function()
        loaded()
        local err = refused(INSERT, { 'a', 1, 'x', nil })
        truthy(err:find("Column 'must' cannot be null", 1, true), err)
        err = refused('INSERT INTO t (id, n) VALUES (?, ?)', { 'a', 1 })
        truthy(err:find("Field 'must' doesn't have a default value", 1, true), err)
        err = refused(INSERT, { nil, 1, 'x', 'm' })
        truthy(err:find("Column 'id' cannot be null", 1, true), 'a primary key is NOT NULL: ' .. err)
        Exec.run(INSERT, { 'a', 1, 'x', 'm' })
        err = refused('UPDATE t SET must = ? WHERE id = ?', { nil, 'a' })
        truthy(err:find("Column 'must' cannot be null", 1, true), 'an UPDATE too: ' .. err)
        eq(Exec.run('SELECT * FROM t WHERE id = ?', { 'a' })[1].must, 'm')
        eq(#Exec.run('SELECT * FROM t', {}), 1, 'and nothing refused was stored')
    end)

    it('gives a column left out its DEFAULT, as MariaDB does', function()
        loaded()
        Exec.run('INSERT INTO t (id, must) VALUES (?, ?)', { 'a', 'm' })
        local row = Exec.run('SELECT * FROM t WHERE id = ?', { 'a' })[1]
        eq(row.n, 7, 'INT DEFAULT 7')
        eq(row.flag, false, 'a TINYINT(1) DEFAULT 0 reads as oxmysql hands it back')
        eq(row.body, nil, 'and a column with none is NULL')

        -- On the store's own tables: a hitman added without a stake, and the
        -- counters a first bump does not name.
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local m = require('crimson-hitman.server.storage.mysql')
        m.open()
        m.addHitman({ id = 'h1', contract_id = 'c1', hitman_cid = 'H', state = 'active',
            accepted_at = 1, alias = 'Op' })
        eq(m.readHitman('c1', 'H').stake_amount, 0, 'stake_amount INT DEFAULT 0')
        m.bumpStat('A', 'completed', 1)
        m.bumpStat('A', 'completed', 1)
        local stats = m.readStats('A')
        eq(stats.failed, 0, 'a counter never bumped is 0, not missing')
        eq(stats.completed, 2, 'and ON DUPLICATE KEY UPDATE completed = completed + VALUES(completed) adds')
    end)

    it('writes none of a statement it refuses one row of', function()
        loaded()
        local err = refused('INSERT INTO t (id, n, body, must) VALUES (?, ?, ?, ?),(?, ?, ?, ?)',
            { 'a', 1, 'x', 'm', 'b', 2147483648, 'x', 'm' })
        truthy(err:find("Out of range value for column 'n' at row 2", 1, true), err)
        eq(#Exec.run('SELECT * FROM t', {}), 0, 'the first row was not kept')

        Exec.run(INSERT, { 'a', 1, 'x', 'm' })
        Exec.run(INSERT, { 'b', 2147483647, 'x', 'm' })
        refused('UPDATE t SET n = n + ? WHERE must = ?', { 1, 'm' })
        eq(Exec.run('SELECT * FROM t WHERE id = ?', { 'a' })[1].n, 1, 'neither row changed')
    end)

    it('answers false for a transaction one statement of fails, and keeps neither', function()
        loaded()
        local answer = MySQL.transaction.await({
            { query = INSERT, values = { 'a', 1, 'x', 'm' } },
            { query = INSERT, values = { 'b', 1, 'x', nil } },
        })
        eq(answer, false, 'oxmysql answers false and rolls back, it does not raise')
        eq(#Exec.run('SELECT * FROM t', {}), 0, 'the first statement was rolled back')
        eq(MySQL.transaction.await({
            { query = INSERT, values = { 'a', 1, 'x', 'm' } },
            { query = INSERT, values = { 'b', 1, 'x', 'm' } },
        }), true)
        eq(#Exec.run('SELECT * FROM t', {}), 2)
    end)

    it('raises nothing for a direct call the database refuses, and never answers it', function()
        loaded()
        local answered = false
        MySQL.query(INSERT, { 'a', 1, 'x', nil }, function() answered = true end)
        falsy(answered, 'oxmysql prints the error and never calls cb without return_callback_errors')
        eq(#Exec.run('SELECT * FROM t', {}), 0)
    end)
end)

--- What the store writes, held to what its INT columns hold (S01, S22,
--- S04). Each was refused by strict mode: the pause never ended and the
--- expiry pass stopped at it, and a give that raised for a rich player was
--- never counted.
describe('the mysql store within its INT columns', function()
    local function mysqlStore()
        Exec.install(Natives)
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local store = require('crimson-hitman.server.storage.mysql')
        store.open()
        return store
    end

    it('ends a 25-day pause, its total held to the column', function()
        local store = mysqlStore()
        local c = contractFixture('ct00000025')
        c.deadline_at = os.time() + 3600
        store.writeContract(c)
        local since = os.time()
        truthy(store.startPause(c.id, since), 'paused')
        local ok, ended = pcall(store.endPause, c.id, since, 25 * 86400)
        truthy(ok, 'the database refused it: ' .. tostring(ended))
        truthy(ended, 'the pause ended')
        local row = store.readContract(c.id)
        eq(row.paused_ms, 2147483647, 'the total stops at what an INT holds')
        eq(row.paused_since, nil)
        eq(row.deadline_at, c.deadline_at + 25 * 86400, 'the deadline moves by the whole pause')
    end)

    it('keeps a balance past INT as the ceiling', function()
        local store = mysqlStore()
        local ok, err = pcall(store.writeEscrow, 'ct00000026', { {
            id = 'ct00000026:1', slot = 1, portion = 'baseline', source = 'cash', amount = 500,
            state = CH.ESCROW_STATE.HELD, owed_to = 'HITMAN01', deliver_raises = 1,
            deliver_before = 3e9,
        } })
        truthy(ok, 'the database refused it: ' .. tostring(err))
        local line = store.readEscrowLine('ct00000026:1')
        eq(tonumber(line.deliver_before), 2147483647)
        eq(tonumber(line.deliver_raises), 1, 'and the raise it records')
    end)
end)

describe('json durability', function()
    it('survives a restart with escrow intact', function()
        package.loaded['crimson-hitman.server.storage.json'] = nil
        Natives.files = {}
        local store = require('crimson-hitman.server.storage.json')
        store.open()

        store.writeContract(contractFixture('ct1'))
        store.writeEscrow('ct1', { {
            id = 'ct1:1', contract_id = 'ct1', slot = 1, portion = 'baseline',
            source = 'cash', amount = 5000, state = CH.ESCROW_STATE.HELD,
        } })
        store.close()

        -- Reload from the same virtual disk.
        package.loaded['crimson-hitman.server.storage.json'] = nil
        local reopened = require('crimson-hitman.server.storage.json')
        reopened.open()

        truthy(reopened.readContract('ct1'), 'contract survived the restart')
        eq(reopened.readEscrowLine('ct1:1').amount, 5000, 'escrow survived the restart')
        eq(reopened.readEscrowLine('ct1:1').state, CH.ESCROW_STATE.HELD, 'still held, not lost')
    end)

    it('refuses to start on a corrupt store rather than discarding escrow', function()
        package.loaded['crimson-hitman.server.storage.json'] = nil
        Natives.files = { [(Config.Database.Json.Directory or 'data') .. '/store.json'] = '{not json at all' }
        local store = require('crimson-hitman.server.storage.json')
        local ok = pcall(store.open)
        falsy(ok, 'a corrupt store must halt the resource, not start empty')
    end)

    it('starts cleanly when there is no store yet', function()
        package.loaded['crimson-hitman.server.storage.json'] = nil
        Natives.files = {}
        local store = require('crimson-hitman.server.storage.json')
        truthy(pcall(store.open), 'a first start is not a corruption')
        eq(#store.allContracts(), 0)
    end)
end)

describe('copy-on-read semantics', function()
    --- Real databases return fresh rows, not shared tables. Anything that
    --- relies on mutating a record it read earlier breaks against MySQL,
    --- so the whole system is run against a copying backend here.
    local function copyingStack()
        local wrap = require('crimson-hitman.tests.harness.copying_store')
        local stack = newStack()
        local copying = wrap(stack.storage)

        -- Rewire every module onto the copying store.
        stack.audit.init(copying)
        stack.escrow.init(copying, stack.audit)
        stack.contracts.init({ storage = copying, escrow = stack.escrow,
            identity = stack.identity, audit = stack.audit, notify = stack.notify })
        stack.photos.init({ storage = copying, audit = stack.audit })
        stack.ledger.init({ storage = copying, photos = stack.photos, notify = stack.notify })
        stack.projection.init({ storage = copying, identity = stack.identity,
            escrow = stack.escrow, kidnap = stack.kidnap, notify = stack.notify })
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
        s.storage.compareSetContractState(c.id, CH.STATE.ACTIVE, CH.STATE.ACCEPTED)
        stale.resolution = 'something'
        s.storage.writeContract(stale)

        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED,
            'a stale write must not revert the transition')
    end)

    it('resolves a contract correctly against a copying backend', function()
        local s = copyingStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 5000 } },
        })
        eq(Env.players[1].PlayerData.money.cash, 95000)

        local ok = s.contracts.resolve(c.id, CH.STATE.CANCELLED, 'CREATOR1', nil, 'cancelled')
        truthy(ok)
        eq(s.storage.readContract(c.id).state, CH.STATE.CANCELLED, 'stays cancelled')
        eq(Env.players[1].PlayerData.money.cash, 100000, 'refunded once')

        local again = s.contracts.resolve(c.id, CH.STATE.CANCELLED, 'CREATOR1', nil, 'again')
        falsy(again, 'and cannot be resolved twice')
        eq(Env.players[1].PlayerData.money.cash, 100000)
    end)

    it('claims payout slots correctly against a copying backend', function()
        local s = copyingStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { slots = {
                { baseline = { cash = 1000 } },
                { baseline = { cash = 2000 } },
            } },
        })
        truthy(s.contracts.accept(f.hitman, c.id, false))

        local ok, err, result = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        truthy(ok, tostring(err))
        eq(result.slot, 1)
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED,
            'back to accepted with a slot remaining, not stuck completing')
        eq(s.storage.readContract(c.id).next_slot, 2, 'slot counter advanced')
        eq(Env.players[3].PlayerData.money.cash, 6000)

        Env.advance(Config.Limits.SlotCooldownSeconds + 1)
        local ok2, err2, result2 = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        truthy(ok2, tostring(err2))
        truthy(result2.exhausted)
        eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED)
    end)
end)

describe('the mysql schema holds every field the code writes', function()
    --- The memory and json backends store whole Lua tables, so any field the
    --- MySQL backend forgets to declare survives there for free and no test
    --- notices. These checks compare what the code actually writes against
    --- what the schema can hold, which is the only way to catch a dropped
    --- column without a live database.

    local Sim = require('crimson-hitman.tests.harness.mysql_sim')

    local function schemaFor()
        Sim.install(Natives)
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local store = require('crimson-hitman.server.storage.mysql')
        store.open()
        return Sim
    end

    it('declares every column the contract writer names', function()
        local sim = schemaFor()
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local store = require('crimson-hitman.server.storage.mysql')
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
            fulfilment_rule = 'either',
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
            metadata = {}, staker = 'HITMAN01', inv_slot = 3,
            state = 'held', settled_to = 'HITMAN01', settled_at = 1,
            taken_from = 'HITMAN01',
        }

        local missing = sim.missingColumns('crimson_escrow', line)
        eq(#missing, 0, 'crimson_escrow cannot store: ' .. table.concat(missing, ', '))
    end)

    it('can hold every field a hitman record carries', function()
        local sim = schemaFor()

        local hitman = {
            id = 'hn1', contract_id = 'ct1', hitman_cid = 'H',
            hitman_account = 'license:h', hitman_name = 'H', alias = 'Operative #1',
            anon = false, accepted_at = 1, left_at = 2, last_claim_at = 3,
            claims = 1, stake_amount = 100, state = 'active',
        }

        local missing = sim.missingColumns('crimson_hitmen', hitman)
        eq(#missing, 0, 'crimson_hitmen cannot store: ' .. table.concat(missing, ', '))
    end)
end)

describe('owed escrow survives in every backend', function()
    --- Money owed to a named person is the newest escrow shape, and the one
    --- it would be worst to lose: the player has already been charged.

    local function line(id)
        return {
            id = id, contract_id = 'ct1', slot = 0, portion = CH.PORTION.OWED,
            source = 'bank', amount = 5000, owed_to = 'CREATOR1',
            state = CH.ESCROW_STATE.HELD,
        }
    end

    it('round-trips its owner in memory and json', function()
        package.loaded['crimson-hitman.server.storage.memory'] = nil
        package.loaded['crimson-hitman.server.storage.json'] = nil
        Natives.files = {}

        for _, name in ipairs({ 'memory', 'json' }) do
            local store = require('crimson-hitman.server.storage.' .. name)
            store.open()
            store.writeEscrow('ct1', { line('ct1:owed1') })

            local read = store.readEscrowLine('ct1:owed1')
            truthy(read, name .. ': line not found')
            eq(read.owed_to, 'CREATOR1', name .. ': the owner must survive the round trip')
            eq(read.portion, CH.PORTION.OWED, name)
            eq(read.amount, 5000, name)
        end
    end)

    it('survives a restart in json mode', function()
        package.loaded['crimson-hitman.server.storage.json'] = nil
        Natives.files = {}
        local store = require('crimson-hitman.server.storage.json')
        store.open()
        store.writeEscrow('ct1', { line('ct1:owed1') })
        store.queuePending('CREATOR1', 'ct1', 'ct1:owed1')
        store.close()

        package.loaded['crimson-hitman.server.storage.json'] = nil
        local reopened = require('crimson-hitman.server.storage.json')
        reopened.open()

        local read = reopened.readEscrowLine('ct1:owed1')
        truthy(read, 'money already charged must not vanish on a restart')
        eq(read.owed_to, 'CREATOR1')
        eq(#reopened.readPending('CREATOR1'), 1, 'and the claim on it survives too')
    end)

    it('has a column for it in the mysql schema', function()
        local Sim = require('crimson-hitman.tests.harness.mysql_sim')
        Sim.install(Natives)
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local store = require('crimson-hitman.server.storage.mysql')
        store.open()

        local missing = Sim.missingColumns('crimson_escrow', line('ct1:owed1'))
        eq(#missing, 0, 'crimson_escrow cannot store: ' .. table.concat(missing, ', '))
    end)
end)

describe('escrow whose contract was never stored', function()
    --- Read once at boot to hand those lines back (Contracts.recoverNeverPlaced).
    it('is found, with whom it came from, in every backend', function()
        for _, b in ipairs(backends()) do
            b.store.writeContract(contractFixture('ct00000001'))
            b.store.writeEscrow('ct00000001', { { id = 'ct00000001:1', contract_id = 'ct00000001',
                slot = 1, portion = 'baseline', source = 'cash', amount = 100, state = 'held',
                taken_from = 'CREATOR1' } })
            b.store.writeEscrow('ct00000009', {
                { id = 'ct00000009:1', contract_id = 'ct00000009', slot = 1, portion = 'baseline',
                  source = 'bank', amount = 700, state = 'held', taken_from = 'CREATOR1' },
                { id = 'ct00000009:2', contract_id = 'ct00000009', slot = 1, portion = 'baseline',
                  source = 'cash', amount = 50, state = 'settled', taken_from = 'CREATOR1' },
            })
            local found = b.store.orphanEscrow()
            eq(#found, 1, b.name .. ': lines of a stored contract, or settled ones, were included')
            eq(found[1].id, 'ct00000009:1', b.name)
            eq(found[1].taken_from, 'CREATOR1', b.name .. ': whom it came from was not kept')
            eq(found[1].amount, 700, b.name)
        end
    end)
end)

describe('escrow left for staff', function()
    --- /ch-stuck lists these from the lines themselves: the audit rows that
    --- used to name them are pruned after Config.Audit.RetentionDays.
    it('is found from the escrow in every backend, and kept through a prune', function()
        for _, b in ipairs(backends()) do
            local old = os.time() - 400 * 86400
            local function closed(id)
                b.store.writeContract(contractFixture(id))
                b.store.compareSetContractState(id, CH.STATE.ACTIVE, CH.STATE.CANCELLED)
                local c = b.store.readContract(id)
                c.resolved_at = old
                b.store.writeContract(c)
            end
            local function line(id, n, raises)
                return { id = id .. ':' .. n, contract_id = id, slot = 1, portion = 'baseline',
                    source = 'item', item = 'lockpick', quantity = 1, state = 'held',
                    owed_to = 'CREATOR1', taken_from = 'CREATOR1', deliver_raises = raises }
            end
            local function settle(id)
                b.store.claimEscrowLine(id, CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING)
                b.store.settleEscrowLine(id, 'CREATOR1')
            end
            closed('ct00000002')
            b.store.writeEscrow('ct00000002', {
                line('ct00000002', 1, 3), line('ct00000002', 2, 2), line('ct00000002', 3, nil),
                line('ct00000002', 4, 3), line('ct00000002', 5, 4),
            })
            settle('ct00000002:4')
            -- Nothing held: the prune is free to take it, which shows it ran.
            closed('ct00000003')
            b.store.writeEscrow('ct00000003', { line('ct00000003', 1, 3) })
            settle('ct00000003:1')

            local function ids()
                local out = {}
                for _, l in ipairs(b.store.parkedEscrow(3)) do out[#out + 1] = l.id end
                return table.concat(out, ',')
            end
            eq(ids(), 'ct00000002:1,ct00000002:5',
                b.name .. ': held lines at the limit or over, and nothing else')
            local first = b.store.parkedEscrow(3)[1]
            eq(first.owed_to, 'CREATOR1', b.name .. ': whom it is owed to')
            eq(tonumber(first.deliver_raises), 3, b.name)

            b.store.prune()
            falsy(b.store.readContract('ct00000003'), b.name .. ': the prune did not run')
            truthy(b.store.readContract('ct00000002'), b.name .. ': pruned with a line held')
            eq(ids(), 'ct00000002:1,ct00000002:5', b.name .. ': and its lines with it')
        end
    end)

    --- A held line owed to somebody that nothing queues, whatever it says of
    --- a give, and a line left `releasing` by a call that raised, are given
    --- or finished by nothing until the next start, so /ch-stuck lists them
    --- from the escrow. Only lines naming a give's recipient were read, and
    --- an owed line whose queue entry was lost was listed by nothing.
    it('finds held owed lines and releasing lines in every backend', function()
        for _, b in ipairs(backends()) do
            b.store.writeContract(contractFixture('ct00000004'))
            local function line(n, fields)
                local out = { id = 'ct00000004:' .. n, contract_id = 'ct00000004', slot = 1,
                    portion = 'baseline', source = 'cash', amount = 100 * n, state = 'held' }
                for k, v in pairs(fields) do out[k] = v end
                return out
            end
            b.store.writeEscrow('ct00000004', {
                line(1, { owed_to = 'HITMAN01', releasing_to = 'HITMAN01' }),
                line(2, { owed_to = 'HITMAN01' }),
                line(3, { releasing_to = 'HITMAN01' }),
                line(4, { owed_to = 'CREATOR1', releasing_to = 'CREATOR1', deliver_raises = 3 }),
                line(5, { owed_to = 'HITMAN01', releasing_to = 'HITMAN01' }),
                line(6, { owed_to = 'HITMAN01', releasing_to = 'HITMAN01' }),
            })
            b.store.claimEscrowLine('ct00000004:5', CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING)
            b.store.claimEscrowLine('ct00000004:6', CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING)
            b.store.settleEscrowLine('ct00000004:6', 'HITMAN01')

            local out = {}
            for _, l in ipairs(b.store.owedHeldEscrow()) do out[#out + 1] = l.id end
            eq(table.concat(out, ','), 'ct00000004:1,ct00000004:2,ct00000004:4',
                b.name .. ': held and owed, naming a recipient or not, and nothing else')
            eq(b.store.owedHeldEscrow()[1].releasing_to, 'HITMAN01', b.name)
            eq(b.store.owedHeldEscrow()[2].owed_to, 'HITMAN01', b.name)
            eq(b.store.owedHeldEscrow()[1].amount, 100, b.name)

            out = {}
            for _, l in ipairs(b.store.releasingEscrow()) do out[#out + 1] = l.id end
            eq(table.concat(out, ','), 'ct00000004:5', b.name .. ': releasing, and nothing else')
            eq(b.store.releasingEscrow()[1].releasing_to, 'HITMAN01', b.name)
        end
    end)

    --- An ending that raised between writing the closed state and handing
    --- the escrow over leaves a closed contract holding lines owed to nobody,
    --- which the maintenance tick finishes (Contracts.finishEndings). Read in
    --- one query, at most `limit` lines; nothing of a contract still live,
    --- nothing owed or naming a give, and nothing of one never stored.
    it('finds held lines of closed contracts owed to nobody in every backend', function()
        for _, b in ipairs(backends()) do
            -- Rows written by hand, as an ending that raised leaves them.
            rawset(b.store, '__rawFixture', true)
            local closed = contractFixture('ct00000005')
            closed.state = CH.STATE.EXPIRED
            b.store.writeContract(closed)
            b.store.writeContract(contractFixture('ct00000006'))
            local function line(contractId, n, fields)
                local out = { id = contractId .. ':' .. n, contract_id = contractId, slot = 1,
                    portion = 'baseline', source = 'cash', amount = 100 * n, state = 'held' }
                for k, v in pairs(fields or {}) do out[k] = v end
                return out
            end
            b.store.writeEscrow('ct00000005', {
                line('ct00000005', 1),
                line('ct00000005', 2, { owed_to = 'CREATOR1' }),
                line('ct00000005', 3, { releasing_to = 'HITMAN01' }),
                line('ct00000005', 4, { portion = 'stake', staker = 'HITMAN01' }),
                line('ct00000005', 5),
                line('ct00000005', 6),
            })
            b.store.claimEscrowLine('ct00000005:5', CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING)
            b.store.claimEscrowLine('ct00000005:6', CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING)
            b.store.settleEscrowLine('ct00000005:6', 'CREATOR1')
            b.store.writeEscrow('ct00000006', { line('ct00000006', 1) })
            b.store.writeEscrow('ct00000007', { line('ct00000007', 1) })

            local function ids(limit)
                local out = {}
                for _, l in ipairs(b.store.strandedEscrow(limit)) do out[#out + 1] = l.id end
                return table.concat(out, ',')
            end
            eq(ids(10), 'ct00000005:1,ct00000005:4',
                b.name .. ': held, owed to nobody, naming no give, of a closed contract')
            eq(ids(1), 'ct00000005:1', b.name .. ': and no more than asked for')
            local stake = b.store.strandedEscrow(10)[2]
            eq(stake.portion, 'stake', b.name)
            eq(stake.staker, 'HITMAN01', b.name)
            eq(stake.amount, 400, b.name)

            -- Settled, so nothing is left stranded for a store opened later
            -- on the same tables.
            for _, n in ipairs({ 1, 3, 4 }) do
                b.store.claimEscrowLine('ct00000005:' .. n, CH.ESCROW_STATE.HELD,
                    CH.ESCROW_STATE.RELEASING)
            end
            for _, n in ipairs({ 1, 3, 4, 5 }) do
                b.store.settleEscrowLine('ct00000005:' .. n, 'CREATOR1')
            end
            eq(ids(10), '', b.name .. ': and none once they are settled')
        end
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
        store.addHitman({ id = 'hn1', contract_id = 'ct3', hitman_cid = 'A',
            accepted_at = 4, state = 'active' })
    end

    local function ids(rows)
        local out = {}
        for i = 1, #rows do out[#out + 1] = rows[i].id end
        table.sort(out)
        return table.concat(out, ',')
    end

    it('finds every contract a player is involved in, in memory and json', function()
        package.loaded['crimson-hitman.server.storage.memory'] = nil
        package.loaded['crimson-hitman.server.storage.json'] = nil
        Natives.files = {}

        for _, name in ipairs({ 'memory', 'json' }) do
            local store = require('crimson-hitman.server.storage.' .. name)
            store.open()
            seeded(store)

            -- A as creator on ct1, target on ct2, hitman on ct3.
            eq(ids(store.contractsInvolving('A')), 'ct1,ct2,ct3', name .. ': involving')
            eq(ids(store.contractsBy('C')), 'ct2,ct3', name .. ': created by')
            eq(ids(store.contractsNaming('A')), 'ct2', name .. ': naming as target')
            eq(ids(store.contractsInvolving('ZZ')), '', name .. ': nobody')
        end
    end)

    it('does not return a contract twice when a player holds two roles', function()
        package.loaded['crimson-hitman.server.storage.memory'] = nil
        local store = require('crimson-hitman.server.storage.memory')
        store.open()
        store.writeContract({ id = 'ct9', creator_cid = 'A', target_cid = 'B',
            mode = 'exclusive', state = 'active', created_at = 1 })
        store.addHitman({ id = 'hn9', contract_id = 'ct9', hitman_cid = 'A',
            accepted_at = 2, state = 'active' })
        eq(#store.contractsInvolving('A'), 1, 'creator and hitman on one contract is one row')
    end)

    it('has the indexes the mysql queries rely on', function()
        local schema = read_file('crimson-hitman/server/storage/mysql.lua')
        truthy(schema:find('INDEX idx_creator', 1, true), 'creator index')
        truthy(schema:find('INDEX idx_target', 1, true), 'target index')
        truthy(schema:find('INDEX idx_hitman', 1, true), 'hitman index')
    end)
end)


--- oxmysql's typeCast reads a TINYINT(1) back as true or false; a driver
--- without it reads 0 or 1. Compared with `== 1`, every flag read false under
--- oxmysql, so an anonymous client or hitman was shown by name, an officer
--- target lost its flag and no bonus line counted as derived.
describe('mysql flags in either shape', function()
    it('reads every TINYINT(1) flag back as it was written', function()
        local ok, err = pcall(function()
            for _, booleans in ipairs({ true, false }) do
                Exec.booleans = booleans
                local shape = booleans and 'true/false' or '0/1'
                package.loaded['crimson-hitman.server.storage.mysql'] = nil
                Exec.install(Natives)
                local store = require('crimson-hitman.server.storage.mysql')
                store.open()

                local c = contractFixture('ctflag01')
                c.target_protected, c.anon_creator = true, true
                store.writeContract(c)
                store.writeEscrow('ctflag01', { {
                    id = 'ctflag01:1', contract_id = 'ctflag01', slot = 1, portion = 'bonus',
                    source = 'cash', amount = 100, state = CH.ESCROW_STATE.HELD, derived = true,
                } })
                store.addHitman({ id = 'hnflag01', contract_id = 'ctflag01',
                    hitman_cid = 'HITMAN01', anon = true, accepted_at = 1, state = 'active' })

                local read = store.readContract('ctflag01')
                eq(read.target_protected, true, shape .. ': officer flag')
                eq(read.anon_creator, true, shape .. ': anonymous client')
                eq(store.readEscrowLine('ctflag01:1').derived, true, shape .. ': derived bonus')
                eq(store.readHitmen('ctflag01')[1].anon, true, shape .. ': anonymous hitman')
            end
        end)
        Exec.booleans = true
        if not ok then error(err, 0) end
    end)
end)


--- Schema migration.
---
--- CREATE TABLE IF NOT EXISTS creates a table and then never touches it
--- again, so a server that ran an earlier version keeps its old columns and
--- silently drops every field added since — which on this build would be the
--- stake owner, the pause marker and the whole bailout queue.
describe('mysql schema migration', function()
    local Sim = require('crimson-hitman.tests.harness.mysql_sim')

    local function opened(existing, indexes, collations, engines)
        Sim.install(Natives)
        if existing then Sim.existingSchema(existing, indexes, collations, engines) end
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local store = require('crimson-hitman.server.storage.mysql')
        store.open()
        return store
    end

    --- The store opened again on the same database, as a later start: the
    --- simulator keeps what the first open made.
    local function reopened()
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local store = require('crimson-hitman.server.storage.mysql')
        local ok, err = pcall(store.open)
        return ok, tostring(err), store
    end

    --- The README says a database user without CREATE or ALTER can start
    --- once install/sql/crimson_hitman.sql has been imported by one with
    --- them. open() sent CREATE TABLE IF NOT EXISTS for every table anyway,
    --- and MySQL and MariaDB check the privilege before they look for the
    --- table: error 1142 on every start, for that user, every time.
    it('starts as a user without CREATE or ALTER on tables already made', function()
        opened(nil)
        Sim.denied = { CREATE = true, ALTER = true }
        Sim.altered = {}
        local ok, err = reopened()
        truthy(ok, 'nothing to make, so nothing is asked: ' .. err)
        eq(#Sim.altered, 0)
    end)

    it('names a missing table, and how to make it, to a user who cannot create it', function()
        opened(nil)
        -- One table nobody imported: dropped, as far as the database knows.
        Sim.schema.crimson_mutes, Sim.tables.crimson_mutes = nil, nil
        Sim.indexes.crimson_mutes, Sim.collations.crimson_mutes = nil, nil
        Sim.engines.crimson_mutes = nil
        Sim.denied = { CREATE = true }
        local ok, err = reopened()
        falsy(ok, 'it cannot start without the table')
        truthy(err:find('table crimson_mutes', 1, true), 'names the table: ' .. err)
        truthy(err:find('1142', 1, true), 'with the database\'s own reason: ' .. err)
        truthy(err:find('install/sql/crimson_hitman.sql', 1, true), 'and the fix: ' .. err)
        falsy(err:find('crimson_contracts', 1, true), 'and nothing that is there: ' .. err)
    end)

    it('names a missing column, with the statement to add it, to a user who cannot alter', function()
        Sim.install(Natives)
        Sim.existingSchema({ crimson_contracts = { id = true, creator_cid = true,
            target_cid = true, mode = true, state = true, created_at = true } })
        Sim.denied = { ALTER = true }
        local ok, err = reopened()
        falsy(ok, 'the code writes columns the table does not have')
        truthy(err:find('column crimson_contracts.paused_since', 1, true), 'names it: ' .. err)
        truthy(err:find('ALTER TABLE crimson_contracts ADD COLUMN paused_since', 1, true),
            'and the statement that adds it: ' .. err)
        truthy(Sim.schema.crimson_escrow, 'the tables it may create are still made')
    end)

    --- Escrow writes go through one transaction, which is all-or-nothing on
    --- InnoDB only. A table an older version or a restored dump left on
    --- MyISAM kept it: CREATE TABLE IF NOT EXISTS never looks at a table it
    --- finds.
    it('moves a table left on another engine to InnoDB, once', function()
        local store = opened(
            { crimson_audit = { id = true, ts = true, kind = true, action = true,
                actor_cid = true, contract_id = true, detail = true } },
            nil, nil, { crimson_audit = 'MyISAM' })
        local moved = {}
        for _, change in ipairs(Sim.altered) do
            if change.engine then moved[#moved + 1] = change.sql end
        end
        eq(#moved, 1, 'one table to move: ' .. table.concat(moved, ' | '))
        eq(moved[1], 'ALTER TABLE crimson_audit ENGINE=InnoDB')
        local first
        for _, change in ipairs(Sim.altered) do
            if change.table_ == 'crimson_audit' then first = first or change end
        end
        truthy(first and first.engine, 'before anything else is changed on it')
        eq(Sim.engines.crimson_audit, 'InnoDB')

        Sim.altered = {}
        store.migrate()
        eq(#Sim.altered, 0, 'and a second run moves nothing')
    end)

    it('leaves a table of the same prefix it does not declare alone', function()
        opened({ crimson_fire_calls = { id = true } }, nil, nil, { crimson_fire_calls = 'MyISAM' })
        for _, change in ipairs(Sim.altered) do
            falsy(change.table_ == 'crimson_fire_calls', 'another resource\'s table: ' .. change.sql)
        end
        eq(Sim.engines.crimson_fire_calls, 'MyISAM')
    end)

    it('names the engine change to a user who cannot make it', function()
        opened(nil)
        Sim.engines.crimson_ledger = 'MyISAM'
        Sim.denied = { ALTER = true }
        local ok, err = reopened()
        falsy(ok, 'escrow on MyISAM is not all-or-nothing')
        truthy(err:find('crimson_ledger on the InnoDB engine (it is MyISAM)', 1, true), err)
        truthy(err:find('ALTER TABLE crimson_ledger ENGINE=InnoDB;', 1, true), err)
    end)

    local function addedColumns()
        local out = {}
        for _, change in ipairs(Sim.altered) do
            if change.column then out[#out + 1] = change.table_ .. '.' .. change.column end
        end
        table.sort(out)
        return out
    end

    it('adds nothing to a database it just created', function()
        -- The sim answers with what CREATE TABLE made, as MySQL does. The
        -- schema's comments read as declarations once produced columns
        -- named `and` and `which` here, and an ALTER oxmysql raised on.
        opened(nil)
        local sql = {}
        for _, change in ipairs(Sim.altered) do sql[#sql + 1] = change.sql end
        eq(#Sim.altered, 0, 'a fresh install needs no migration: ' .. table.concat(sql, ' | '))
    end)

    it('adds an index on two columns whole', function()
        opened({ crimson_ledger = { id = true, cid = true, contract_id = true,
                                    role = true, resolved_at = true } },
               { crimson_ledger = { PRIMARY = true } })
        local sql = {}
        for _, change in ipairs(Sim.altered) do sql[#sql + 1] = change.sql end
        local all = table.concat(sql, ' | ')
        truthy(all:find('ALTER TABLE crimson_ledger ADD INDEX idx_cid (cid, resolved_at)', 1, true),
            'not cut at its comma: ' .. all)
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

    --- Live transfer only added one column, to a table every mysql server
    --- already has. A database from the version before it gets just that,
    --- NULL on every row it holds, which reads as 'either'.
    it('adds the rule column to a contracts table from before it, and nothing else', function()
        opened(nil)
        local previous = {}
        for column in pairs(Sim.schema.crimson_contracts) do
            if column ~= 'fulfilment_rule' then previous[column] = true end
        end
        truthy(next(previous), 'the current table, less the one column')

        opened({ crimson_contracts = previous })
        eq(table.concat(addedColumns(), ' '), 'crimson_contracts.fulfilment_rule')
        local sql
        for _, change in ipairs(Sim.altered) do
            if change.column == 'fulfilment_rule' then sql = change.sql end
        end
        eq(sql, 'ALTER TABLE crimson_contracts ADD COLUMN fulfilment_rule VARCHAR(8)',
            'no default: an older row has no rule, and reads as the one it was taken on')
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

    --- An escrow table an older version made has the column under the name
    --- MariaDB will not take. It is moved, with its values, rather than a
    --- second column added beside it that every row would have empty and
    --- every insert would leave the old NOT NULL one without.
    it('renames the escrow portion column an older version made, keeping its values', function()
        local store = opened({
            crimson_escrow = { id = true, contract_id = true, portion = true,
                               source = true, state = true },
        })
        local renamed
        for _, change in ipairs(Sim.altered) do
            if change.from then renamed = change end
        end
        truthy(renamed, 'the column is renamed')
        eq(renamed.sql, 'ALTER TABLE crimson_escrow CHANGE COLUMN `portion` line_portion '
            .. 'VARCHAR(16) NOT NULL', 'by CHANGE COLUMN, the old name quoted')
        for _, name in ipairs(addedColumns()) do
            falsy(name == 'crimson_escrow.line_portion', 'and not added beside the old one')
        end

        Sim.altered = {}
        store.migrate()
        eq(#Sim.altered, 0, 'a second run finds nothing left to do')
    end)

    --- A user who may not alter tables is told what to run. With the rename
    --- refused, the column was also queued as missing, so the list held the
    --- rename and then ADD COLUMN line_portion: run in order, as the README
    --- says, it stopped at error 1060 before every ADD after it.
    it('prints a refused rename once, without the column it would add', function()
        Sim.install(Natives)
        Sim.existingSchema({
            crimson_escrow = { id = true, contract_id = true, portion = true,
                               source = true, state = true },
        })
        Sim.denied = { ALTER = true }
        local ok, err = reopened()
        falsy(ok, 'the old shape cannot be used as it is')
        truthy(err:find('ALTER TABLE crimson_escrow CHANGE COLUMN `portion` line_portion', 1, true),
            'the rename is printed: ' .. err)
        falsy(err:find('ADD COLUMN line_portion', 1, true), 'and not the column it makes: ' .. err)
        local _, named = err:gsub('crimson_escrow%.line_portion', '')
        eq(named, 1, 'named once among what is missing: ' .. err)
        truthy(err:find('ALTER TABLE crimson_escrow ADD COLUMN taken_from', 1, true),
            'every other missing column is still there: ' .. err)
        truthy(err:find('ALTER TABLE crimson_escrow ADD COLUMN deliver_raises', 1, true), err)
    end)

    --- Three reads the schema had no index for: the audit log by action (the
    --- overview, a contract's page, /ch-stuck, /ch-settle), and the prune's
    --- finished contracts by age and their messages by contract. Each read
    --- the whole table.
    it('adds the audit action, resolved and message contract indexes to an older database', function()
        opened({
            crimson_audit = { id = true, ts = true, kind = true, action = true,
                actor_cid = true, contract_id = true, detail = true },
            crimson_contracts = { id = true, creator_cid = true, target_cid = true,
                mode = true, state = true, created_at = true, resolved_at = true },
            crimson_messages = { id = true, contract_id = true, thread_id = true,
                from_cid = true, from_alias = true, body = true, sent_at = true },
        }, {
            crimson_audit = { PRIMARY = true, idx_ts = true, idx_actor = true,
                idx_audit_contract = true },
            crimson_contracts = { PRIMARY = true, idx_state = true },
            crimson_messages = { PRIMARY = true, idx_thread = true },
        })
        local sql = {}
        for _, change in ipairs(Sim.altered) do
            if change.index then sql[#sql + 1] = change.sql end
        end
        local all = table.concat(sql, ' | ')
        truthy(all:find('ALTER TABLE crimson_audit ADD INDEX idx_audit_action (action)', 1, true), all)
        truthy(all:find('ALTER TABLE crimson_contracts ADD INDEX idx_resolved (resolved_at)', 1, true), all)
        truthy(all:find('ALTER TABLE crimson_messages ADD INDEX idx_message_contract (contract_id)',
            1, true), all)

        -- And a user who may not add them is told the three statements.
        Sim.install(Natives)
        Sim.existingSchema({ crimson_audit = { id = true, ts = true, kind = true, action = true,
            actor_cid = true, contract_id = true, detail = true } },
            { crimson_audit = { PRIMARY = true, idx_ts = true, idx_actor = true,
                idx_audit_contract = true } })
        Sim.denied = { ALTER = true }
        local ok, err = reopened()
        falsy(ok)
        truthy(err:find('ALTER TABLE crimson_audit ADD INDEX idx_audit_action (action);', 1, true), err)
    end)

    --- Another resource's table under one of these generic names was taken
    --- for an older version of this one: moved to InnoDB, rebuilt in
    --- utf8mb4 and given columns, then the start refused on "Multiple primary
    --- key" as a missing grant, the other resource's table changed for good.
    it('leaves a same-named table that is not this resource\'s alone, and refuses', function()
        Sim.install(Natives)
        Sim.existingSchema({ crimson_settings = { id = true, name = 'latin1', value = 'latin1' } },
            { crimson_settings = { PRIMARY = true } }, { crimson_settings = 'latin1_swedish_ci' },
            { crimson_settings = 'MyISAM' })
        local ok, err = reopened()
        falsy(ok, 'it is not this resource\'s table')
        truthy(err:find('table crimson_settings already exists in this database and is not this '
            .. 'resource\'s', 1, true), err)
        truthy(err:find('setting_key primary key', 1, true), 'says why: ' .. err)
        truthy(err:find('Nothing was changed', 1, true), err)
        eq(#Sim.altered, 0, 'nothing altered')
        eq(Sim.engines.crimson_settings, 'MyISAM', 'still on its own engine')
        eq(Sim.schema.crimson_contracts, nil, 'and nothing created either')

        -- migrate() run on its own refuses the same way, before any change.
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local store = require('crimson-hitman.server.storage.mysql')
        local migrated, again = pcall(store.migrate)
        falsy(migrated)
        truthy(tostring(again):find('is not this resource\'s', 1, true), tostring(again))
        eq(#Sim.altered, 0)
    end)

    --- txAdmin makes the database utf8 (utf8mb3), older MariaDB and XAMPP
    --- latin1. A table inheriting either refused an emoji in a contract
    --- reason or a relay message with error 1366, and latin1 a Polish or
    --- Cyrillic character name too.
    it('makes every table utf8mb4, whatever the database defaults to', function()
        opened(nil)
        local tables = 0
        for name, collation in pairs(Sim.collations) do
            tables = tables + 1
            eq(collation, 'utf8mb4_unicode_ci',
                name .. ' must say utf8mb4 rather than take the database default')
        end
        truthy(tables >= 13, 'every table it creates: ' .. tables)
    end)

    it('converts a table an older version made in another character set, once', function()
        local store = opened(
            {
                crimson_messages = { id = true, contract_id = true, thread_id = true,
                    from_cid = true, from_alias = true, body = true, sent_at = true },
                crimson_contracts = { id = true, creator_cid = true, target_cid = true,
                    mode = true, state = true, created_at = true },
                crimson_ledger = { id = true, cid = 'utf8mb4', contract_id = true,
                    role = true, target_name = 'latin1', resolved_at = true },
            },
            nil,
            { crimson_messages = 'utf8mb3_general_ci', crimson_contracts = 'utf8mb4_general_ci',
              crimson_ledger = 'utf8mb4_general_ci' })
        local converted = {}
        for _, change in ipairs(Sim.altered) do
            if change.charset then converted[change.table_] = change.sql end
        end
        eq(converted.crimson_messages, 'ALTER TABLE crimson_messages CONVERT TO CHARACTER SET '
            .. 'utf8mb4 COLLATE utf8mb4_unicode_ci', 'a utf8mb3 table is converted')
        truthy(converted.crimson_ledger, 'and one whose own default is right but a column is not')
        eq(converted.crimson_contracts, 'ALTER TABLE crimson_contracts CONVERT TO CHARACTER SET '
            .. 'utf8mb4 COLLATE utf8mb4_unicode_ci',
            'and one in utf8mb4 but another collation, which no join with the rest survives')

        Sim.altered = {}
        store.migrate()
        eq(#Sim.altered, 0, 'and a second run converts nothing again')
    end)

    --- On MariaDB the previous version made crimson_contracts and then
    --- stopped at crimson_escrow (`portion`), so that one table kept the
    --- database's default collation: utf8mb4_general_ci on Debian's
    --- MariaDB. This version made the rest utf8mb4_unicode_ci. Every join
    --- between them was refused (error 1267), the recovery at start
    --- included, and mysql mode still never started on those servers.
    it('puts a table left in another utf8mb4 collation on the same one as the rest', function()
        local store = opened(
            { crimson_contracts = { id = 'utf8mb4', creator_cid = 'utf8mb4',
                target_cid = 'utf8mb4', mode = 'utf8mb4', state = 'utf8mb4',
                created_at = true } },
            nil,
            { crimson_contracts = 'utf8mb4_general_ci' })

        local converted
        for _, change in ipairs(Sim.altered) do
            if change.charset and change.table_ == 'crimson_contracts' then converted = change end
        end
        truthy(converted, 'a utf8mb4_general_ci table is converted')
        eq(converted and converted.collation, 'utf8mb4_unicode_ci', 'to the collation of the rest')

        for name in pairs(Sim.collations) do
            eq(Sim.collationOf(name), 'utf8mb4_unicode_ci', name .. ' ends on the one collation')
        end

        -- The queries that failed: the recovery at start, the board, every
        -- acceptance and the per-tick prune.
        local ok, err = pcall(store.orphanEscrow)
        truthy(ok, 'the recovery at start joins contracts and escrow: ' .. tostring(err))
        ok, err = pcall(store.contractsInvolving, 'CID1')
        truthy(ok, 'the board joins contracts and hitmen: ' .. tostring(err))
        ok, err = pcall(store.countHitmanContracts, 'CID1', { accepted = true })
        truthy(ok, 'an acceptance counts across both: ' .. tostring(err))
        ok, err = pcall(store.pruneContracts, 0)
        truthy(ok, 'and the prune checks escrow and pending: ' .. tostring(err))

        -- The simulator refuses what the database refuses, or the above
        -- proves nothing.
        Sim.existingCollations.crimson_contracts = 'utf8mb4_general_ci'
        ok, err = pcall(store.orphanEscrow)
        falsy(ok, 'a mix of collations is refused, as MariaDB refuses it')
        truthy(tostring(err):find('1267', 1, true), 'with the error MariaDB gives: ' .. tostring(err))
    end)

    it('converts a table whose own default is right but a column has its own collation', function()
        opened(
            { crimson_ledger = { id = true, cid = 'utf8mb4_general_ci', contract_id = 'utf8mb4',
                role = 'utf8mb4', target_name = 'utf8mb4', resolved_at = true } },
            nil,
            { crimson_ledger = 'utf8mb4_unicode_ci' })
        local converted
        for _, change in ipairs(Sim.altered) do
            if change.charset and change.table_ == 'crimson_ledger' then converted = change end
        end
        truthy(converted, 'a column in utf8mb4_general_ci is converted with its table')
    end)

    --- Each await is handed to Timing.await, so a maintenance job is charged
    --- for the time it holds the thread and not for everything the server
    --- did while it waited on the database. One call made straight to
    --- oxmysql would be charged in full again.
    it('hands every database wait to the job timing', function()
        local store = opened(nil)
        local waits = 0
        store.timeWaitsWith(function(fn, ...) waits = waits + 1 return fn(...) end)
        local ok, err = pcall(function()
            store.liveContracts()
            store.orphanEscrow()
            store.readEscrow('ct00000001')
        end)
        store.timeWaitsWith(nil)
        truthy(ok, tostring(err))
        eq(waits, 3, 'one per query')

        local f = assert(io.open('crimson-hitman/server/storage/mysql.lua', 'r'))
        local src = f:read('*a')
        f:close()
        local straight = {}
        for call in src:gmatch('MySQL%.%a+%.await%b()') do straight[#straight + 1] = call:sub(1, 60) end
        eq(#straight, 0, 'an await made around db: ' .. table.concat(straight, ' | '))
    end)

    --- PORTION is reserved on MariaDB from 10.4 (FOR PORTION OF). The
    --- escrow table named a column that, the CREATE TABLE was a syntax
    --- error, and mysql mode never started on the database most FiveM
    --- servers run. The harness's own simulators know nothing of reserved
    --- words, which is why nothing caught it; this checks every name the
    --- schema uses against the vendors' lists.
    it('names nothing MariaDB or MySQL 8 reserves', function()
        local reserved = {}
        local lists = require('crimson-hitman.tests.harness.reserved_words')
        for list, words in pairs(lists) do
            for _, word in ipairs(words) do
                reserved[word] = reserved[word] or {}
                reserved[word][#reserved[word] + 1] = list
            end
        end
        truthy(reserved.PORTION, 'the list knows the word that broke it')

        opened(nil)
        local clashes, checked = {}, 0
        --- The word itself is what the database parses; the owner is only
        --- for the message.
        local function check(kind, owner, name)
            checked = checked + 1
            local on = reserved[name:upper()]
            if on then
                clashes[#clashes + 1] = ('%s %s%s (reserved on %s)')
                    :format(kind, owner and (owner .. '.') or '', name, table.concat(on, ', '))
            end
        end
        for tableName, columns in pairs(Sim.schema) do
            check('table', nil, tableName)
            for column in pairs(columns) do check('column', tableName, column) end
            for index in pairs(Sim.indexes[tableName] or {}) do
                -- PRIMARY is the key's own keyword, not a name it was given.
                if index ~= 'PRIMARY' then check('index', tableName, index) end
            end
        end
        truthy(checked > 100, 'every name was looked at: ' .. checked)
        eq(#clashes, 0, 'unquoted reserved words in the schema: ' .. table.concat(clashes, '; '))
    end)
end)


--- The json store writes one file per contract.
---
--- It used to re-serialise and rewrite the whole store on every financial
--- write, which with a few thousand contracts is a multi-megabyte write
--- every time a coin moves.
describe('json sharding', function()
    local function fresh()
        package.loaded['crimson-hitman.server.storage.json'] = nil
        Natives.files = {}
        local store = require('crimson-hitman.server.storage.json')
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
        -- Under the name it is written through (<file>.new, renamed over it).
        Natives.saveFile = function(file) touched[(file:gsub('%.new$', ''))] = true end

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
        store.addHitman({ id = 'h1', contract_id = 'ct1', hitman_cid = 'HITMAN01',
                          state = 'active', accepted_at = 1, alias = 'Operative #1' })
        store.writeMessage({ contract_id = 'ct1', thread_id = 't1', body = 'hello' })
        store.close()

        local shard = json.decode(Natives.files['data/contracts/ct1.json'])
        truthy(shard.contract, 'the row')
        truthy(shard.escrow['ct1:1'], 'its escrow')
        truthy(shard.hitmen.h1, 'its hitmen')
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
        store.addHitman({ id = 'h1', contract_id = 'ct1', hitman_cid = 'HITMAN01',
                          state = 'active', accepted_at = 1, alias = 'Operative #1' })
        store.close()

        package.loaded['crimson-hitman.server.storage.json'] = nil
        local reopened = require('crimson-hitman.server.storage.json')
        reopened.open()

        truthy(reopened.readContract('ct1'), 'the contract')
        eq(#reopened.readEscrow('ct1'), 1, 'its escrow')
        eq(reopened.readEscrowLine('ct1:1').amount, 5000)
        eq(#reopened.readHitmen('ct1'), 1, 'and its hitmen')
    end)

    --- apply's own financial write flushes the proposal still open with every
    --- approval in it. With 'applied' left to the debounce, a crash brought
    --- it back open, and one more Agree cut the same deadline twice.
    it('writes an answered proposal at once, not on the next flush', function()
        local store = fresh()
        store.writeContract(contract('ct1'))
        store.writeAmendment({ id = 'am1', contract_id = 'ct1', proposer = 'CREATOR1',
            kind = 'shorten_deadline', approvals = { CREATOR1 = true, HITMAN01 = true },
            outcome = 'open' })
        store.save(true)

        local proposal = store.readAmendment('am1')
        proposal.outcome = 'applied'
        store.writeAmendment(proposal)

        local onDisk = json.decode(Natives.files['data/contracts/ct1.json'])
        eq(onDisk.amendments.am1.outcome, 'applied', 'on disk before any flush')
    end)

    --- A shard the index names but that will not load.
    ---
    --- This used to abort the boot, on the grounds that the contract held
    --- escrow nobody could return. It does — but refusing to start returns
    --- it no better: the shard that recorded the escrow is the thing that is
    --- missing, so the money is equally unreachable either way. All the
    --- refusal added was the whole resource down for everybody, on a server
    --- whose only way out was to hand-edit the store and guess which line to
    --- remove. It happened.
    ---
    --- What the refusal was really buying was the operator's attention.
    --- That is bought by the report instead.
    it('starts without the contract whose file is gone, rather than not at all', function()
        local store = fresh()
        store.writeContract(contract('ct1'))
        store.writeContract(contract('ct2'))
        store.close()

        Natives.files['data/contracts/ct1.json'] = nil

        package.loaded['crimson-hitman.server.storage.json'] = nil
        local reopened = require('crimson-hitman.server.storage.json')
        local ok, err = pcall(reopened.open)
        truthy(ok, 'one broken shard must not take the resource down: ' .. tostring(err))

        truthy(reopened.readContract('ct2'),
            'every contract that IS readable has to survive the one that is not')
        falsy(reopened.readContract('ct1'), 'and the missing one is simply not there')
    end)

    it('names what it could not load, so nobody has to guess', function()
        local store = fresh()
        store.writeContract(contract('ct1'))
        store.close()
        Natives.files['data/contracts/ct1.json'] = nil

        package.loaded['crimson-hitman.server.storage.json'] = nil
        local reopened = require('crimson-hitman.server.storage.json')
        reopened.open()

        local held = reopened.quarantined()
        eq(#held, 1, 'the contract that could not be loaded has to be recorded')
        eq(held[1].id, 'ct1',
            'the id is the only handle anybody has on what was lost, and an '
            .. 'operator restoring a backup needs to know which file to look for')
        truthy(held[1].reason and #held[1].reason > 0, 'and why it could not be read')
    end)

    it('does the same for a file that will not parse', function()
        local store = fresh()
        store.writeContract(contract('ct1'))
        store.close()
        Natives.files['data/contracts/ct1.json'] = '{ not json'

        package.loaded['crimson-hitman.server.storage.json'] = nil
        local reopened = require('crimson-hitman.server.storage.json')
        truthy(pcall(reopened.open), 'unreadable is not a reason to refuse to start')
        eq(#reopened.quarantined(), 1)
        eq(reopened.quarantined()[1].reason, 'unreadable')
    end)

    it('reads a shard twice before believing it is gone', function()
        local store = fresh()
        store.writeContract(contract('ct1'))
        store.close()

        -- A single failed read is as likely to be the file being written, or
        -- a disk hiccup, as a genuinely missing shard. Treating the first
        -- failure as final is how a live contract gets dropped.
        local saved = Natives.files['data/contracts/ct1.json']
        local reads = 0
        local realLoad = _G.LoadResourceFile
        _G.LoadResourceFile = function(res, file)
            if file == 'data/contracts/ct1.json' then
                reads = reads + 1
                if reads == 1 then return nil end
                return saved
            end
            return realLoad(res, file)
        end

        package.loaded['crimson-hitman.server.storage.json'] = nil
        local reopened = require('crimson-hitman.server.storage.json')
        reopened.open()
        _G.LoadResourceFile = realLoad

        truthy(reads >= 2, 'it gave up after one read')
        truthy(reopened.readContract('ct1'),
            'a contract that was there all along was thrown away on one bad read')
        eq(#reopened.quarantined(), 0)
    end)

    --- What the boot banner tells an operator to do, done.
    ---
    --- The banner names the contract and says "Restore those files from a
    --- backup and restart to recover them". That instruction is only
    --- followable while the index still names the id: there is no directory
    --- listing native, so the index is the only record of which shards
    --- exist, and a shard the index does not name is never opened again.
    ---
    --- open() ends by writing the index — assertWritable proves the
    --- directory is writable by writing the real thing — so an id dropped
    --- while loading is erased from disk by the very boot that quarantined
    --- it. The contract, its escrow, and the warning all go with it.
    describe('a shard that could not be read', function()
        local function withOneMissing()
            local store = fresh()
            store.writeContract(contract('ct1'))
            store.writeEscrow('ct1', { { id = 'ct1:1', contract_id = 'ct1',
                slot = 1, source = 'cash', amount = 50000, state = CH.ESCROW_STATE.HELD } })
            store.writeContract(contract('ct2'))
            store.close()

            local backup = Natives.files['data/contracts/ct1.json']
            truthy(backup, 'the fixture has to have written a shard to lose')
            Natives.files['data/contracts/ct1.json'] = nil

            package.loaded['crimson-hitman.server.storage.json'] = nil
            local reopened = require('crimson-hitman.server.storage.json')
            reopened.open()
            return reopened, backup
        end

        local function indexIds()
            local decoded = json.decode(Natives.files['data/store.json'] or '{}')
            local ids = {}
            for _, id in ipairs(decoded.contractIds or {}) do ids[#ids + 1] = id end
            table.sort(ids)
            return ids
        end

        it('is reported', function()
            local reopened = withOneMissing()
            eq(#reopened.quarantined(), 1)
            eq(reopened.quarantined()[1].id, 'ct1')
        end)

        it('keeps its id in the index the same boot reports it', function()
            withOneMissing()
            eq(table.concat(indexIds(), ','), 'ct1,ct2',
                'open() writes the index before anything reports the '
                .. 'quarantine, so an id dropped here is erased from disk by '
                .. 'the boot that found the problem')
        end)

        it('comes back when the backup is restored, as the banner says', function()
            local reopened, backup = withOneMissing()
            reopened.close()
            Natives.files['data/contracts/ct1.json'] = backup

            package.loaded['crimson-hitman.server.storage.json'] = nil
            local recovered = require('crimson-hitman.server.storage.json')
            recovered.open()

            truthy(recovered.readContract('ct1'),
                'the operator did exactly what they were told and the '
                .. 'contract did not come back')
            local lines = recovered.readEscrow('ct1')
            eq(#lines, 1, 'its escrow has to come back with it')
            eq(lines[1].amount, 50000)
            eq(#recovered.quarantined(), 0, 'and the warning has to clear')
        end)

        it('is still reported on the next boot while it is still missing', function()
            local reopened = withOneMissing()
            reopened.close()

            package.loaded['crimson-hitman.server.storage.json'] = nil
            local again = require('crimson-hitman.server.storage.json')
            again.open()
            eq(#again.quarantined(), 1,
                'a warning that fires once and then goes quiet leaves the '
                .. 'operator believing it was dealt with')
        end)

        it('stops being reported once the operator drops the id themselves', function()
            local reopened = withOneMissing()
            reopened.close()

            -- The other half of what the banner allows: give up on it.
            local decoded = json.decode(Natives.files['data/store.json'])
            decoded.contractIds = { 'ct2' }
            Natives.files['data/store.json'] = json.encode(decoded)

            package.loaded['crimson-hitman.server.storage.json'] = nil
            local after = require('crimson-hitman.server.storage.json')
            after.open()
            eq(#after.quarantined(), 0,
                'an id the operator removed must not be put back, or there is '
                .. 'no way to ever silence it')
            truthy(after.readContract('ct2'), 'and the rest of the store is fine')
        end)
    end)

    it('migrates a store written by the single-file version', function()
        package.loaded['crimson-hitman.server.storage.json'] = nil
        Natives.files = {
            ['data/store.json'] = json.encode({
                seq = 7,
                contracts = { ct1 = contract('ct1'), ct2 = contract('ct2') },
                escrow = { ['ct1:1'] = { id = 'ct1:1', contract_id = 'ct1',
                                         portion = 'baseline', source = 'cash',
                                         amount = 5000, state = 'held', slot = 1 } },
                hitmen = {}, amendments = {}, messages = {},
                ledger = {}, pending = {}, audit = {}, stats = {},
            }),
        }

        local store = require('crimson-hitman.server.storage.json')
        store.open()

        truthy(Natives.files['data/contracts/ct1.json'], 'each contract gets a file')
        truthy(Natives.files['data/contracts/ct2.json'])
        truthy(Natives.files['data/store.json.bak'],
            'and the original is kept: a migration that deletes its only copy of the ' ..
            'data is not one worth having')

        eq(store.readEscrowLine('ct1:1').amount, 5000, 'nothing is lost in the move')

        -- And it reads back from the new layout on the next start.
        package.loaded['crimson-hitman.server.storage.json'] = nil
        local reopened = require('crimson-hitman.server.storage.json')
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

        package.loaded['crimson-hitman.server.storage.json'] = nil
        local reopened = require('crimson-hitman.server.storage.json')
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

--- The SQL an owner can import by hand is the SQL mysql mode runs.
---
--- install/sql/crimson_hitman.sql is for a database user that may not
--- create tables. A copy that drifted from server/storage/mysql.lua would
--- make tables this version does not expect, and the first a server heard
--- of it would be a refused write with money in it.
describe('the install SQL', function()
    local function statements(sql)
        local out = {}
        -- Comments off, then one statement per semicolon, whitespace squashed.
        sql = sql:gsub('%-%-[^\n]*', '')
        for stmt in sql:gmatch('([^;]+);') do
            local flat = stmt:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
            if flat ~= '' then out[#out + 1] = flat end
        end
        return out
    end

    it('creates exactly the tables mysql mode creates, word for word', function()
        Exec.install(Natives)
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local m = require('crimson-hitman.server.storage.mysql')
        -- The statements as mysql.lua sends them, before the executor
        -- squashes them.
        local realRun, raw = Exec.run, {}
        Exec.run = function(sql, params)
            if type(sql) == 'string' and sql:find('^%s*CREATE TABLE') then raw[#raw + 1] = sql end
            return realRun(sql, params)
        end
        local ok, err = pcall(m.open)
        Exec.run = realRun
        truthy(ok, tostring(err))
        local ran = statements(table.concat(raw, ';\n') .. ';')

        local handle = io.open('crimson-hitman/install/sql/crimson_hitman.sql', 'r')
        truthy(handle, 'install/sql/crimson_hitman.sql must ship')
        local shipped = statements(handle:read('a'))
        handle:close()

        eq(#ran, 15, 'the fifteen crimson_* tables')
        eq(#shipped, #ran, 'one statement for every table')
        for i = 1, #ran do
            eq(shipped[i], ran[i], 'statement ' .. i .. ' as mysql mode runs it')
            truthy(ran[i]:find('ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci$'),
                'InnoDB and utf8mb4: ' .. ran[i]:sub(1, 60))
        end
    end)
end)

--- Every function the mysql backend exposes, executed.
---
--- The executing simulator raises on a statement it does not understand, so
--- this is what says the coverage is real: if a query shape is added that
--- the simulator cannot run, this fails by name rather than the conformance
--- suite quietly testing a little less than it did yesterday.
describe('a mysql table on another engine', function()
    --- Run against the executing simulator too, which keeps rows: the move
    --- is ALTER TABLE ... ENGINE, which keeps every row it has.
    it('is moved to InnoDB with its rows, once', function()
        Exec.install(Natives)
        Exec.run([[CREATE TABLE IF NOT EXISTS crimson_meta (
            meta_key VARCHAR(32) PRIMARY KEY,
            meta_value INT NOT NULL
        ) ENGINE=MyISAM DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]])
        Exec.run('INSERT INTO crimson_meta (meta_key, meta_value) VALUES (?, ?)', { 'heartbeat', 1234 })
        eq(Exec.engines.crimson_meta, 'MyISAM')

        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local m = require('crimson-hitman.server.storage.mysql')
        m.open()
        eq(Exec.engines.crimson_meta, 'InnoDB', 'moved')
        eq(m.lastHeartbeat(), 1234, 'with its rows')
        local function moves()
            local n = 0
            for _, flat in ipairs(Exec.statements) do
                if flat:find('ENGINE=InnoDB$') and flat:find('^ALTER TABLE') then n = n + 1 end
            end
            return n
        end
        eq(moves(), 1, 'one statement')

        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        require('crimson-hitman.server.storage.mysql').open()
        eq(moves(), 1, 'and none at the next start')
        for name, engine in pairs(Exec.engines) do eq(engine, 'InnoDB', name) end
    end)
end)

describe('every mysql statement is executable', function()
    it('runs every function this backend exposes', function()
        local Exec = require('crimson-hitman.tests.harness.mysql_exec')
        Exec.install(Natives)
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local m = require('crimson-hitman.server.storage.mysql')
        m.open()

        local calls = {
            function() m.writeContract({ id='c1', creator_cid='A', target_cid='B', mode='exclusive', state='active', created_at=1 }) end,
            function() m.readContract('c1') end,
            function() m.allContracts() end,
            function() m.contractsInvolving('A') end,
            function() m.contractsNaming('B') end,
            function() m.contractsBy('A') end,
            function() m.contractsByAccount('license:a') end,
            function() m.compareSetContractState('c1','active','accepted') end,
            function() m.setAdvised('c1', { advised_posted_at = 1 }) end,
            function() m.setAdvised('c1', { advised_hitmen = 2 }) end,
            function() m.writeEscrow('c1', { { id='c1:1', contract_id='c1', slot=1, portion='baseline', source='cash', amount=100, state='held' } }) end,
            function() m.readEscrow('c1') end,
            function() m.readEscrowLine('c1:1') end,
            function() m.orphanEscrow() end,
            function() m.parkedEscrow(3) end,
            function() m.owedHeldEscrow() end,
            function() m.releasingEscrow() end,
            function() m.strandedEscrow(10) end,
            function() m.claimEscrowLine('c1:1','held','releasing') end,
            function() m.setEscrowAmount('c1:1','releasing',50,100) end,
            function() m.settleEscrowLine('c1:1','A') end,
            function() m.addHitman({ id='h1', contract_id='c1', hitman_cid='H', state='active', accepted_at=1, alias='Op' }) end,
            function() m.readHitmen('c1') end,
            function() m.liveHitmen() end,
            function() m.readHitman('c1','H') end,
            function() m.updateHitman('h1', { claims = 1 }) end,
            function() m.countHitmanContracts('H', { accepted = true }) end,
            function() m.writeAmendment({ id='am1', contract_id='c1', proposer='A', kind='cancel', payload={}, approvals={}, expires_at=1, outcome='open' }) end,
            function() m.readAmendment('am1') end,
            function() m.readOpenAmendments('c1') end,
            function() m.writeMessage({ contract_id='c1', thread_id='t1', from_cid='A', from_alias='Op', body='x', sent_at=1 }) end,
            function() m.readMessages('c1','t1') end,
            function() m.writeLedger({ cid='A', contract_id='c1', role='creator', resolved_at=1 }) end,
            function() m.readLedger('A', 10) end,
            function() m.queuePending('A','c1','c1:1') end,
            function() m.readPending('A') end,
            function() m.clearPending('pnd1') end,
            function() m.bumpStat('A','completed',1) end,
            function() m.readStats('A') end,
            function() m.writeAudit({ ts=1, kind='financial', action='x', actor_cid='A', contract_id='c1', detail={} }) end,
            function() m.readAudit(10) end,
            function() m.auditForContract('c1', 10) end,
            function() m.forgetLedgerPhotos(10) end,
            function() m.writePhoto({ id='ph1', contract_id='c1', slot=1, owner_cid='A', kind='url', url='https://x/y.png', state='pending', created_at=1 }) end,
            function() m.readPhoto('ph1') end,
            function() m.photosOf('A') end,
            function() m.photosForContract('c1') end,
            function() m.photosCreatedBefore(10, 5) end,
            function() m.openPhoto('ph1', 2) end,
            function() m.photosOpenedBefore(10, 5) end,
            function() m.closePhoto('ph1', 'open', 'deleted', nil) end,
            function() m.publishPhoto('ph1', 'open', 'Zk3_q-9xWb2LmT0cRf8aNd', 'https://x/p/a.webp', '555-1') end,
            function() m.readPhotoByPublic('Zk3_q-9xWb2LmT0cRf8aNd') end,
            function() m.movePhoto('ph1', 'open', 'saved') end,
            function() m.keepPhoto('ph1', 'open', 'data/photos/kept/ph1.webp') end,
            function() m.keepPhoto('ph1', 'open', nil) end,
            function() m.photosOpenedBefore(10, 5, 'kept') end,
            function() m.photoTotals() end,
            function() m.anyPhoto() end,
            function() m.deletePhoto('ph1') end,
            function() m.writeReview({ id='rv1', kind='bailout_refund_stranded', contract_id='c1', cids={ payer='A' }, amount=100, account='bank', known={ arrived=0 }, created_at=1, state='open' }) end,
            function() m.readReview('rv1') end,
            function() m.reviewItems(true, 10) end,
            function() m.reviewItems(false, 10) end,
            function() m.setReviewState('rv1', 'open', 'resolving', { resolution = { action = 'dismiss' }, resolved_by = 'console' }) end,
            function() m.writeSetting('Bailout.Enabled', false, 'STAFF01', 1) end,
            function() m.writeSetting('Advisory.TriggerJobNames', { 'fib', 'sast' }, 'STAFF01', 2) end,
            function() m.readSettings() end,
            function() m.deleteSetting('Bailout.Enabled') end,
            function() m.clearSettings() end,
            function() m.unsettledEscrow() end,
            function() m.queryAudit({}, nil, 10) end,
            function() m.queryAudit({ contract = 'c1', kind = 'financial', action = 'x' }, 50, 10) end,
            function() m.queryAudit({ actor = 'A', from = 0, to = 10 }, nil, 10) end,
            function() m.prune() end,
            function() m.pruneContracts(os.time()) end,
            function() m.inspect() end,
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
        package.loaded['crimson-hitman.server.storage.json'] = nil
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

        local store = require('crimson-hitman.server.storage.json')
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
        package.loaded['crimson-hitman.server.storage.json'] = nil
        Natives.files = {}
        Natives.blocked = {}
        local store = require('crimson-hitman.server.storage.json')
        truthy(pcall(store.open), 'an ordinary install must still start')
    end)

    it('ships the directories it needs', function()
        -- A fresh install has to arrive with them, because the resource
        -- cannot create them itself.
        for _, file in ipairs({ 'crimson-hitman/data/README.md',
                                'crimson-hitman/data/contracts/README.md' }) do
            local handle = io.open(file, 'r')
            truthy(handle, file .. ' is missing, so the directory would not exist')
            if handle then handle:close() end
        end
    end)
end)

describe('rewriting an amendment', function()
    it('keeps the new expiry in every backend', function()
        for _, b in ipairs(backends()) do
            local proposal = {
                id = 'am000001', contract_id = 'ct1', proposer = 'CREATOR1',
                kind = 'deadline', payload = { seconds = 600 }, approvals = {},
                expires_at = 1700000000, outcome = 'open',
            }
            b.store.writeAmendment(proposal)

            proposal.expires_at = 1700009999
            b.store.writeAmendment(proposal)

            eq(b.store.readAmendment('am000001').expires_at, 1700009999,
                b.name .. ': a re-written expiry was discarded, so anything '
                .. 'that extends a proposal works in memory and not on a server')
        end
    end)
end)

describe('rewriting a contract', function()
    --- Every field the resource changes after a contract exists.
    ---
    --- A column left out of the MySQL upsert's update list is discarded in
    --- silence, and memory and json mode — where the rest of this suite runs
    --- — have no such list, so nothing anywhere failed. Two were missing.
    local MUTABLE = {
        reason = 'renegotiated', mode = CH.MODE.EXCLUSIVE,
        bonus_percent = 35, bailout_amount = 12345, penalty_amount = 6789,
        -- next_slot, slots_claimed and payout_slots are NOT here: they move
        -- only through advanceSlot and reduceSlots, and the tests below hold
        -- every backend to that. Nor is the clock (deadline_at, paused_ms,
        -- paused_since), which moves only through its own narrow writes.
        expires_at = 1800000002,
        -- The five bailout_* fields are NOT here: they move only through
        -- setBailoutQueue, and the test below holds every backend to that.
        resolved_at = 1800000005, resolution = 'completed',
    }

    it('keeps every field the resource can change, in every backend', function()
        for _, b in ipairs(backends()) do
            b.store.writeContract(contractFixture('ctmut01'))

            local contract = b.store.readContract('ctmut01')
            for key, value in pairs(MUTABLE) do contract[key] = value end
            b.store.writeContract(contract)

            local read = b.store.readContract('ctmut01')
            for key, value in pairs(MUTABLE) do
                eq(read[key], value, ('%s: %s was discarded on rewrite'):format(
                    b.name, key))
            end
        end
    end)
end)

describe('the rule a contract was placed under', function()
    --- How it may be completed is a term, written when it is placed and
    --- never after. The mysql upsert leaves it out of its update list on
    --- purpose, so memory and json have to keep it the same way, or a copy
    --- written back would behave differently on each backend.
    it('survives a rewrite unchanged, in every backend', function()
        for _, b in ipairs(backends()) do
            local placed = contractFixture('ctrule01')
            placed.fulfilment_rule = CH.FULFILMENT_RULE.ALIVE
            b.store.writeContract(placed)

            local copy = {}
            for k, v in pairs(b.store.readContract('ctrule01')) do copy[k] = v end
            copy.fulfilment_rule = CH.FULFILMENT_RULE.EITHER
            copy.reason = 'renegotiated'
            b.store.writeContract(copy)

            local read = b.store.readContract('ctrule01')
            eq(read.fulfilment_rule, CH.FULFILMENT_RULE.ALIVE,
                b.name .. ': a rewrite changed the terms it was placed under')
            eq(read.reason, 'renegotiated', b.name .. ': the rewrite itself still lands')
        end
    end)

    it('survives a restart in json mode', function()
        package.loaded['crimson-hitman.server.storage.json'] = nil
        Natives.files = {}
        local store = require('crimson-hitman.server.storage.json')
        store.open()
        local placed = contractFixture('ctrule02')
        placed.fulfilment_rule = CH.FULFILMENT_RULE.ALIVE
        store.writeContract(placed)
        store.close()

        package.loaded['crimson-hitman.server.storage.json'] = nil
        local reopened = require('crimson-hitman.server.storage.json')
        reopened.open()
        eq(reopened.readContract('ctrule02').fulfilment_rule, CH.FULFILMENT_RULE.ALIVE,
            'a live transfer must not come back from a restart as one a kill completes')
    end)

    --- A row from before the rule existed has none, in every backend, and
    --- reads as the terms it was taken on.
    it('is absent on an older row, which reads as either', function()
        for _, b in ipairs(backends()) do
            b.store.writeContract(contractFixture('ctold01'))
            local read = b.store.readContract('ctold01')
            eq(read.fulfilment_rule, nil, b.name .. ': an older row carries no rule')
            eq(Util.fulfilmentRule(read),
                CH.FULFILMENT_RULE.EITHER, b.name)

            -- And a write back of it is not handed one either.
            local copy = {}
            for k, v in pairs(read) do copy[k] = v end
            copy.fulfilment_rule = CH.FULFILMENT_RULE.ALIVE
            b.store.writeContract(copy)
            eq(b.store.readContract('ctold01').fulfilment_rule, nil, b.name)
        end
    end)
end)

describe('the buyout queue', function()
    --- Moves only through setBailoutQueue, never through writeContract.
    ---
    --- A caller that read a contract before a buyout was paid, and writes it
    --- back after, used to erase the buyout: on mysql every read is an await,
    --- so another handler runs in the gap. The premium was charged and there
    --- was nothing left to settle or refund it.
    local QUEUED = {
        bailout_queued_at = 1800000100, bailout_paid_by = 'TARGET01',
        bailout_paid_amount = 12000, bailout_paid_account = 'bank',
        bailout_attempts = 2,
    }

    it('is set and cleared through its own write, in every backend', function()
        for _, b in ipairs(backends()) do
            b.store.writeContract(contractFixture('ctq1'))
            truthy(b.store.setBailoutQueue('ctq1', QUEUED), b.name .. ': set')

            local read = b.store.readContract('ctq1')
            for key, value in pairs(QUEUED) do
                eq(read[key], value, b.name .. ': ' .. key)
            end

            truthy(b.store.setBailoutQueue('ctq1', nil), b.name .. ': clear')
            falsy(b.store.readContract('ctq1').bailout_queued_at,
                b.name .. ': cleared')
        end
    end)

    it('survives a writeContract of a copy read before it was set', function()
        for _, b in ipairs(backends()) do
            b.store.writeContract(contractFixture('ctq2'))

            -- A handler reads the row...
            local stale = {}
            for k, v in pairs(b.store.readContract('ctq2')) do stale[k] = v end

            -- ...the target pays in the gap...
            b.store.setBailoutQueue('ctq2', QUEUED)

            -- ...and the handler writes back what it read.
            stale.reason = 'edited meanwhile'
            b.store.writeContract(stale)

            local read = b.store.readContract('ctq2')
            eq(read.reason, 'edited meanwhile', b.name .. ': the edit landed')
            eq(read.bailout_queued_at, QUEUED.bailout_queued_at,
                b.name .. ': the stale copy erased a buyout the target had '
                .. 'already paid for')
            eq(read.bailout_paid_amount, QUEUED.bailout_paid_amount, b.name)
        end
    end)
end)

describe('what the advisory said of a contract', function()
    --- Kept as each bulletin goes out, and read by the whitelisted-job view
    --- in place of the advisory as it is set now. Moves only through
    --- setAdvised, never through writeContract, so a copy read before a
    --- bulletin and written after it cannot take back what it said.
    it('is kept through its own write, and survives a copy read before it, in every backend', function()
        for _, b in ipairs(backends()) do
            b.store.writeContract(contractFixture('ctadv1'))
            local stale = {}
            for k, v in pairs(b.store.readContract('ctadv1')) do stale[k] = v end

            truthy(b.store.setAdvised('ctadv1', { advised_posted_at = 1800000100 }), b.name .. ': posted')
            truthy(b.store.setAdvised('ctadv1', { advised_hitmen = 2 }), b.name .. ': accepted')
            local read = b.store.readContract('ctadv1')
            eq(read.advised_posted_at, 1800000100, b.name .. ': the posting one is kept')
            eq(read.advised_hitmen, 2, b.name .. ': and the count the acceptance one carried')

            stale.reason = 'edited meanwhile'
            stale.advised_hitmen = 9
            b.store.writeContract(stale)
            read = b.store.readContract('ctadv1')
            eq(read.reason, 'edited meanwhile', b.name .. ': the edit landed')
            eq(read.advised_posted_at, 1800000100, b.name .. ': a stale copy took back a bulletin')
            eq(read.advised_hitmen, 2, b.name .. ': or changed what it said')

            local ok = pcall(b.store.setAdvised, 'ctadv1', { reason = 'x' })
            falsy(ok, b.name .. ': nothing else moves through it')
        end
    end)

    it('is absent where no bulletin went, in every backend', function()
        for _, b in ipairs(backends()) do
            b.store.writeContract(contractFixture('ctadv2'))
            local read = b.store.readContract('ctadv2')
            eq(read.advised_posted_at, nil, b.name)
            eq(read.advised_hitmen, nil, b.name)
        end
    end)

    it('survives a restart in json mode', function()
        package.loaded['crimson-hitman.server.storage.json'] = nil
        Natives.files = {}
        local store = require('crimson-hitman.server.storage.json')
        store.open()
        store.writeContract(contractFixture('ctadv3'))
        store.setAdvised('ctadv3', { advised_posted_at = 1800000200, advised_hitmen = 1 })
        store.close()

        package.loaded['crimson-hitman.server.storage.json'] = nil
        local reopened = require('crimson-hitman.server.storage.json')
        reopened.open()
        local read = reopened.readContract('ctadv3')
        eq(read.advised_posted_at, 1800000200)
        eq(read.advised_hitmen, 1)
    end)
end)

describe('the payout counters', function()
    --- Move only through advanceSlot, never through writeContract.
    ---
    --- Every other writer reads the row, awaits, and writes it back. On mysql
    --- a claim lands in those awaits, and writing next_slot back undid it:
    --- the collection just paid went back on sale, and the next hitman to
    --- kill the target for it was paid out of an empty slot.
    it('survive a writeContract of a copy read before a claim, in every backend', function()
        for _, b in ipairs(backends()) do
            local row = contractFixture('ctslot1')
            row.payout_slots = 3
            b.store.writeContract(row)

            local stale = {}
            for k, v in pairs(b.store.readContract('ctslot1')) do stale[k] = v end

            truthy(b.store.advanceSlot('ctslot1', 1), b.name .. ': the claim')

            stale.reason = 'edited meanwhile'
            b.store.writeContract(stale)

            local read = b.store.readContract('ctslot1')
            eq(read.reason, 'edited meanwhile', b.name .. ': the edit landed')
            eq(read.next_slot, 2, b.name .. ': the stale copy put a paid collection '
                .. 'back on sale')
            eq(read.slots_claimed, 1, b.name .. ': and uncounted the claim')
        end
    end)
end)

describe('the collection count and the clock', function()
    --- Both move only through their own guarded writes. Every other writer
    --- reads the row, awaits and writes it back; on mysql a give-back, an
    --- extension or the expiry pass lands in those awaits, and writing the
    --- copy back undid it.
    it('survive a writeContract of a stale copy, in every backend', function()
        for _, b in ipairs(backends()) do
            local row = contractFixture('ctclock1')
            row.payout_slots, row.deadline_at, row.paused_ms = 3, 1000, 0
            b.store.writeContract(row)

            local stale = {}
            for k, v in pairs(b.store.readContract('ctclock1')) do stale[k] = v end

            truthy(b.store.reduceSlots('ctclock1', 3), b.name .. ': the give-back')
            truthy(b.store.startPause('ctclock1', 500), b.name .. ': a pause')
            truthy(b.store.endPause('ctclock1', 500, 60), b.name .. ': and its end')
            truthy(b.store.setDeadline('ctclock1', 1060, 1200), b.name .. ': an extension')

            stale.reason = 'edited meanwhile'
            b.store.writeContract(stale)

            local read = b.store.readContract('ctclock1')
            eq(read.reason, 'edited meanwhile', b.name .. ': the edit landed')
            eq(read.payout_slots, 2, b.name .. ': a stale copy put the collection back')
            eq(read.deadline_at, 1200, b.name .. ': a stale copy undid the deadline')
            eq(read.paused_ms, 60000, b.name .. ': and the time paused')
            falsy(read.paused_since, b.name .. ': and the pause')
        end
    end)

    it('refuse a guarded write whose guard no longer holds', function()
        for _, b in ipairs(backends()) do
            local row = contractFixture('ctclock2')
            row.payout_slots, row.deadline_at = 2, 1000
            b.store.writeContract(row)
            falsy(b.store.reduceSlots('ctclock2', 3), b.name .. ': the count moved')
            falsy(b.store.setDeadline('ctclock2', 999, 5), b.name .. ': the deadline moved')
            truthy(b.store.startPause('ctclock2', 10))
            falsy(b.store.startPause('ctclock2', 20), b.name .. ': a pause already running')
            falsy(b.store.endPause('ctclock2', 20, 5), b.name .. ': not that pause')
            eq(b.store.readContract('ctclock2').deadline_at, 1000)
        end
    end)
end)

describe('the narrow writes added for the second review', function()
    it('sets a reason and nothing else, in every backend', function()
        for _, b in ipairs(backends()) do
            local row = contractFixture('ctreason1')
            row.reason, row.bailout_amount = 'Old', 900
            b.store.writeContract(row)
            truthy(b.store.setReason('ctreason1', 'New'), b.name)
            local read = b.store.readContract('ctreason1')
            eq(read.reason, 'New', b.name)
            eq(read.bailout_amount, 900, b.name .. ': touched a column it was not asked to')
        end
    end)

    it('confirms an acceptance only while it is still joining, in every backend', function()
        for _, b in ipairs(backends()) do
            b.store.writeContract(contractFixture('ctconfirm'))
            b.store.addHitman({ id = 'hnconfirm1', contract_id = 'ctconfirm', hitman_cid = 'HITMAN01',
                alias = 'Operative #1', anon = false, accepted_at = 10, state = 'joining' })
            truthy(b.store.confirmHitman('hnconfirm1', true, 20), b.name .. ': a joining row')
            local h = b.store.readHitman('ctconfirm', 'HITMAN01')
            eq(h.state, 'active', b.name)
            eq(h.anon == true or h.anon == 1, true, b.name .. ': anonymity written with it')
            eq(h.accepted_at, 20, b.name)

            b.store.updateHitman('hnconfirm1', { state = 'refused' })
            falsy(b.store.confirmHitman('hnconfirm1', false, 30),
                b.name .. ': reversed a row something else had taken back')
            eq(b.store.readHitman('ctconfirm', 'HITMAN01').state, 'refused', b.name)

            b.store.updateHitman('hnconfirm1', { state = 'rejoining' })
            truthy(b.store.confirmHitman('hnconfirm1', false, 40), b.name .. ': a rejoining row')
        end
    end)

    --- Contracts.abandon's compare and set: a claim, a void, an expiry or a
    --- buyout that ended the contract in the abandon's awaits leaves the row
    --- as that ending left it.
    it('abandons only an active row of a live contract, in every backend', function()
        for _, b in ipairs(backends()) do
            local open = contractFixture('ctleave1')
            open.state = CH.STATE.ACCEPTED
            b.store.writeContract(open)
            b.store.addHitman({ id = 'hnleave1', contract_id = 'ctleave1', hitman_cid = 'HITMAN01',
                alias = 'Operative #1', anon = false, accepted_at = 10, state = 'active' })
            truthy(b.store.abandonHitman('hnleave1', 'ctleave1', 50), b.name .. ': an active row')
            local h = b.store.readHitman('ctleave1', 'HITMAN01')
            eq(h.state, 'abandoned', b.name)
            eq(h.left_at, 50, b.name)
            falsy(b.store.abandonHitman('hnleave1', 'ctleave1', 60), b.name .. ': twice')
            eq(b.store.readHitman('ctleave1', 'HITMAN01').left_at, 50, b.name .. ': left as it was')

            for i, state in ipairs({ CH.STATE.COMPLETING, CH.STATE.EXPIRED, CH.STATE.VOIDED }) do
                local id = 'ctleave' .. (i + 1)
                local row = contractFixture(id)
                row.state = state
                b.store.writeContract(row)
                b.store.addHitman({ id = 'hnleave' .. (i + 1), contract_id = id,
                    hitman_cid = 'HITMAN01', alias = 'Operative #1', anon = false,
                    accepted_at = 10, state = 'active' })
                falsy(b.store.abandonHitman('hnleave' .. (i + 1), id, 70),
                    b.name .. ': on a ' .. state .. ' contract')
                eq(b.store.readHitman(id, 'HITMAN01').state, 'active',
                    b.name .. ': the row as the ending left it, on ' .. state)
            end
        end
    end)

    it('counts a hitman mid-acceptance against their cap, in every backend', function()
        for _, b in ipairs(backends()) do
            b.store.writeContract(contractFixture('ctcount1'))
            b.store.addHitman({ id = 'hncount1', contract_id = 'ctcount1', hitman_cid = 'HITMAN01',
                alias = 'Operative #1', anon = false, accepted_at = 10, state = 'joining' })
            eq(b.store.countHitmanContracts('HITMAN01', { active = true }), 1,
                b.name .. ': a second acceptance counted this one as not there')
        end
    end)

    it('gives a collection back only while it is unclaimed and unlocked, in every backend', function()
        for _, b in ipairs(backends()) do
            local row = contractFixture('ctslots9')
            row.payout_slots, row.next_slot = 2, 2
            b.store.writeContract(row)
            falsy(b.store.reduceSlots('ctslots9', 2),
                b.name .. ': removed the collection a claim had just advanced onto')

            local held = contractFixture('ctslots8')
            held.payout_slots, held.next_slot = 2, 1
            b.store.writeContract(held)
            b.store.compareSetContractState('ctslots8', CH.STATE.ACTIVE, CH.STATE.COMPLETING)
            falsy(b.store.reduceSlots('ctslots8', 2), b.name .. ': removed it mid-claim')
            b.store.compareSetContractState('ctslots8', CH.STATE.COMPLETING, CH.STATE.ACCEPTED)
            truthy(b.store.reduceSlots('ctslots8', 2), b.name .. ': and gives it back otherwise')
            eq(b.store.readContract('ctslots8').payout_slots, 1, b.name)
        end
    end)
end)

describe('audit retention', function()
    --- 0 kept a finished contract and a ledger photo forever, and deleted
    --- the audit log: the cutoff became now, and every row older than the
    --- current second went, including what /ch-stuck is built from.
    it('keeps the log when set to 0, and prunes by age otherwise', function()
        -- Memory too: it only ever appended to its log, for the life of the
        -- process.
        for _, backend in ipairs(backends()) do
            local store = backend.store
            do
                local function has(action)
                    for _, row in ipairs(store.readAudit(1000) or {}) do
                        if row.action == action then return true end
                    end
                    return false
                end
                Config.Audit.RetentionDays = 0
                store.writeAudit({ ts = os.time() - 40 * 86400, kind = 'financial',
                    action = 'old_row', detail = {} })
                store.writeAudit({ ts = os.time(), kind = 'financial', action = 'new_row', detail = {} })
                if store.prune then store.prune() end
                truthy(has('old_row'), backend.name .. ': 0 deleted the log')

                Config.Audit.RetentionDays = 30
                store.writeAudit({ ts = os.time(), kind = 'financial', action = 'newer_row', detail = {} })
                if store.prune then store.prune() end
                falsy(has('old_row'), backend.name .. ': a row past the retention age is pruned')
                truthy(has('new_row'), backend.name .. ': and a recent one kept')
            end
        end
    end)

    --- Aged rows left the front of the in-memory log one table.remove at a
    --- time, each shifting the whole log. They go in one move now, and what
    --- stays has to be exactly what stood behind them, in order.
    it('drops every aged row at once and keeps the rest in order, in json and memory', function()
        for _, backend in ipairs(backends()) do
            if backend.name ~= 'mysql' then
                local store = backend.store
                Config.Audit.RetentionDays = 30
                for i = 1, 7 do
                    store.writeAudit({ ts = os.time() - (40 - i) * 86400, kind = 'financial',
                        action = 'aged_' .. i, detail = {} })
                end
                for i = 1, 3 do
                    store.writeAudit({ ts = os.time() - i, kind = 'financial',
                        action = 'kept_' .. i, detail = {} })
                end
                if store.prune then store.prune() end
                local actions = {}
                for _, row in ipairs(store.readAudit(1000) or {}) do actions[#actions + 1] = row.action end
                eq(table.concat(actions, ','), 'kept_1,kept_2,kept_3', backend.name)
            end
        end
        Config.Audit.RetentionDays = 30
    end)

    --- One DELETE took the whole backlog: after a long downtime, or with
    --- retention first switched on, 900,000 rows in twelve seconds with the
    --- tick waiting on it. A batch a tick, oldest first.
    it('mysql: prunes a backlog 5,000 rows a tick, oldest first', function()
        Exec.install(Natives)
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local m = require('crimson-hitman.server.storage.mysql')
        m.open()
        Config.Audit.RetentionDays = 30
        local aged = os.time() - 40 * 86400
        for i = 1, 12000 do
            Exec.tables.crimson_audit[i] = { id = i, ts = aged + i, kind = 'financial',
                action = 'old_row', detail = '{}' }
        end
        Exec.tables.crimson_audit[12001] = { id = 12001, ts = os.time(), kind = 'financial',
            action = 'new_row', detail = '{}' }
        local function rows()
            local n, oldest = 0, nil
            for _, row in pairs(Exec.tables.crimson_audit) do
                if row.action == 'old_row' then
                    n = n + 1
                    if not oldest or row.ts < oldest then oldest = row.ts end
                end
            end
            return n, oldest
        end
        m.prune()
        local left, oldest = rows()
        eq(left, 7000, 'one batch a tick')
        eq(oldest, aged + 5001, 'the oldest went first')
        m.prune()
        eq((rows()), 2000)
        m.prune()
        eq((rows()), 0, 'and the backlog drains')
        truthy(Exec.tables.crimson_audit[12001], 'a row inside the retention age is kept')
    end)
end)

--- The json audit log lives in files of its own, one per day, rather than
--- in the index that every financial write rewrites whole.
describe('the json audit log', function()
    local function reopen()
        package.loaded['crimson-hitman.server.storage.json'] = nil
        local store = require('crimson-hitman.server.storage.json')
        store.open()
        return store
    end

    local function fresh()
        Natives.files = {}
        return reopen()
    end

    local function day(ts) return os.date('!%Y-%m-%d', ts) end
    local function file(ts) return 'data/audit-' .. day(ts) .. '.jsonl' end

    local function actions(rows)
        local out = {}
        for i = 1, #rows do out[i] = rows[i].action end
        return table.concat(out, ',')
    end

    local function row(action, ts, contractId)
        return { ts = ts or os.time(), kind = 'financial', action = action,
                 contract_id = contractId, detail = { line = (contractId or 'x') .. ':1' } }
    end

    it('keeps the log out of the index and reads it back after a restart', function()
        local store = fresh()
        local yesterday = os.time() - 86400
        store.writeAudit(row('first', yesterday, 'ct1'))
        store.writeAudit(row('second', nil, 'ct2'))
        store.writeAudit(row('release_interrupted', nil, 'ct1'))
        store.close()

        local index = json.decode(Natives.files['data/store.json'])
        eq(index.audit, nil, 'the index must not carry the log')
        eq(table.concat(index.auditDays, ','), day(yesterday) .. ',' .. day(os.time()),
            'only which days have a file')
        truthy((Natives.files[file(yesterday)] or ''):find('"first"', 1, true), 'a file per day')
        truthy((Natives.files[file(os.time())] or ''):find('"second"', 1, true))

        local reopened = reopen()
        eq(actions(reopened.readAudit()), 'first,second,release_interrupted',
            'every row back, oldest first')
        eq(actions(reopened.auditForContract('ct1', 10)), 'first,release_interrupted')
        eq(reopened.auditByAction('release_interrupted', 10)[1].detail.line, 'ct1:1',
            'with its detail a table, as /ch-stuck reads it')
    end)

    it('moves a log an older version kept in the index, once', function()
        local old = os.time() - 2 * 86400
        local legacy = {
            seq = 3, contractIds = {}, ledger = {}, pending = {}, stats = {}, reveals = {},
            audit = { row('a', old, 'ct1'), row('b', old + 60, 'ct1'), row('c', nil, 'ct2') },
        }
        Natives.files = { ['data/store.json'] = json.encode(legacy) }

        local store = reopen()
        eq(actions(store.readAudit()), 'a,b,c', 'nothing lost in the move')
        eq(json.decode(Natives.files['data/store.json']).audit, nil, 'and the index is without it')
        truthy(Natives.files[file(old)], 'each day has its file')
        truthy(Natives.files[file(os.time())])

        -- The index this start read, audit and all, is what store.json.prev
        -- holds. Restored, the move runs again and adds nothing twice.
        store.writeAudit(row('d', nil, 'ct2'))
        store.close()
        Natives.files['data/store.json'] = Natives.files['data/store.json.prev']
        eq(actions(reopen().readAudit()), 'a,b,c,d', 'a second move duplicates nothing')
    end)

    it('finishes a move a crash cut short, without doubling anything', function()
        local old = os.time() - 2 * 86400
        local rows = { row('a', old, 'ct1'), row('b', old + 60, 'ct1'), row('c', nil, 'ct2') }
        Natives.files = {
            ['data/store.json'] = json.encode({ seq = 3, contractIds = {}, audit = rows }),
            -- The first day landed whole; today's was cut off mid-line.
            [file(old)] = json.encode(rows[1]) .. '\n' .. json.encode(rows[2]) .. '\n',
            [file(os.time())] = json.encode(rows[3]):sub(1, 12),
        }

        local store = reopen()
        eq(actions(store.readAudit()), 'a,b,c', 'every row exactly once')
        local today = Natives.files[file(os.time())]
        truthy(today:find('"c"', 1, true) and today:sub(-1) == '\n',
            'the torn file is written again whole: ' .. today)
    end)

    it('deletes a whole day past the retention age, and leaves out older rows', function()
        local removed = {}
        local realRemove, realPath = os.remove, _G.GetResourcePath
        _G.GetResourcePath = function() return '/srv/resources/crimson-hitman' end
        os.remove = function(target) removed[#removed + 1] = target return true end

        local savedDays = Config.Audit.RetentionDays
        local ok, err = pcall(function()
            Config.Audit.RetentionDays = 0
            local store = fresh()
            local old = os.time() - 40 * 86400
            store.writeAudit(row('old', old))
            store.writeAudit(row('new'))
            store.flush()
            truthy(Natives.files[file(old)], 'kept while the log is kept forever')

            Config.Audit.RetentionDays = 30
            store.writeAudit(row('newer'))
            store.flush()
            eq(actions(store.readAudit()), 'new,newer', 'the old row is pruned')
            local index = json.decode(Natives.files['data/store.json'])
            eq(table.concat(index.auditDays, ','), day(os.time()), 'its day is off the index')
            eq(removed[1], '/srv/resources/crimson-hitman/' .. file(old),
                'and its file is removed through the resource folder')

            -- A start applies the age too: the day the cutoff falls in keeps
            -- its file, and its rows before the cutoff are not read back.
            local edge = os.time() - 30 * 86400
            store.writeAudit(row('past', edge - 60))
            store.writeAudit(row('inside', edge + 60))
            store.close()
            eq(actions(reopen().readAudit()), 'inside,new,newer', 'read back within the age')
        end)
        os.remove, _G.GetResourcePath = realRemove, realPath
        Config.Audit.RetentionDays = savedDays
        if not ok then error(err, 0) end
    end)
end)
