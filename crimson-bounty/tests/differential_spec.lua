--- The three backends, given the same random history, must end up saying
--- the same things.
---
--- The conformance suite checks operations one at a time: write a contract,
--- read it back, in each backend. That cannot see a divergence that only
--- appears after a sequence — a claim that leaves memory and json agreeing
--- and mysql one row behind, an id minted differently once the sequence
--- crosses a boundary, an update that lands on the wrong row only when
--- another row was written first.
---
--- So: generate a history, replay it identically against all three, and
--- compare everything observable afterwards. The seed is printed with any
--- failure, and the generator is deterministic given a seed, so a divergence
--- can be replayed exactly.

local Exec = require('crimson-bounty.tests.harness.mysql_exec')

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

    -- Marked as written to directly.
    --
    -- This spec puts rows into the store by hand to compare backends, so it
    -- deliberately writes combinations the resource would never produce: a
    -- creator who is also the target, escrow on a contract that is already
    -- closed. The invariant monitor checks rules the business layer upholds,
    -- not rules the store enforces, so auditing these stores reports the
    -- fixture rather than a fault.
    for _, store in ipairs({ memory, jsonStore, mysqlStore }) do
        rawset(store, '__rawFixture', true)
    end

    return {
        { name = 'memory', store = memory },
        { name = 'json', store = jsonStore },
        { name = 'mysql', store = mysqlStore },
    }
end

--- A small deterministic generator, so a seed reproduces a history exactly
--- rather than approximately.
local function rng(seed)
    local state = seed
    return function(n)
        state = (1103515245 * state + 12345) % 2147483648
        return (state % n) + 1
    end
end

local SOURCES = { 'cash', 'bank', 'dirty' }
local STATES = { CB.STATE.ACTIVE, CB.STATE.ACCEPTED, CB.STATE.COMPLETED,
                 CB.STATE.CANCELLED, CB.STATE.EXPIRED }

--- One history: a list of operations, each a closure taking a store.
local function history(seed, length)
    local pick = rng(seed)
    local ops, contracts, lines, hunters = {}, {}, {}, {}

    for step = 1, length do
        local choice = pick(9)

        if choice <= 3 or #contracts == 0 then
            local id = ('ct%08d'):format(#contracts + 1)
            contracts[#contracts + 1] = id
            -- Every value is drawn HERE, once, and the closure only reads
            -- what was captured. Drawing inside `run` advances the
            -- generator once per backend, so each replay gets different
            -- data and the comparison reports the fixture rather than the
            -- store: the first version of this "found" eighty divergences,
            -- one of which was two backends disagreeing about who created a
            -- contract, which no storage layer could cause.
            local row = {
                id = id, creator_cid = 'CREATOR' .. pick(3),
                target_cid = 'TARGET' .. pick(3),
                mode = pick(2) == 1 and CB.MODE.EXCLUSIVE or CB.MODE.COMPETITIVE,
                state = STATES[pick(#STATES)], created_at = 1000 + step,
                payout_slots = pick(3), next_slot = 1,
            }
            ops[#ops + 1] = { what = 'writeContract ' .. id .. ' ' .. row.state,
                run = function(store)
                    -- A fresh table per replay: a backend that keeps the
                    -- table it was handed would otherwise be mutating the
                    -- next backend's input.
                    local copy = {}
                    for k, v in pairs(row) do copy[k] = v end
                    return store.writeContract(copy)
                end }

        elseif choice == 4 then
            local contractId = contracts[pick(#contracts)]
            local n = pick(3)
            local batch = {}
            for i = 1, n do
                local id = contractId .. ':' .. (#lines + i)
                lines[#lines + 1] = id
                batch[i] = {
                    id = id, contract_id = contractId, slot = pick(3),
                    portion = pick(2) == 1 and CB.PORTION.BASELINE or CB.PORTION.BONUS,
                    source = SOURCES[pick(#SOURCES)],
                    amount = pick(5000), quantity = 0,
                    state = CB.ESCROW_STATE.HELD,
                    derived = pick(2) == 1 or nil,
                }
            end
            ops[#ops + 1] = { what = 'writeEscrow ' .. contractId .. ' x' .. n,
                run = function(store)
                    local copy = {}
                    for i, line in ipairs(batch) do
                        local one = {}
                        for k, v in pairs(line) do one[k] = v end
                        copy[i] = one
                    end
                    return store.writeEscrow(contractId, copy)
                end }

        elseif choice == 5 and #lines > 0 then
            local id = lines[pick(#lines)]
            ops[#ops + 1] = { what = 'claim ' .. id,
                run = function(store)
                    return store.claimEscrowLine(id, CB.ESCROW_STATE.HELD,
                        CB.ESCROW_STATE.RELEASING)
                end }

        elseif choice == 6 and #lines > 0 then
            local id = lines[pick(#lines)]
            local who = 'HUNTER' .. pick(3)
            ops[#ops + 1] = { what = 'settle ' .. id .. ' -> ' .. who,
                run = function(store) return store.settleEscrowLine(id, who) end }

        elseif choice == 7 and #contracts > 0 then
            local id = contracts[pick(#contracts)]
            local from, to = STATES[pick(#STATES)], STATES[pick(#STATES)]
            ops[#ops + 1] = { what = ('cas %s %s->%s'):format(id, from, to),
                run = function(store) return store.compareSetContractState(id, from, to) end }

        elseif choice == 8 and #contracts > 0 then
            local contractId = contracts[pick(#contracts)]
            local id = 'hn' .. ('%06d'):format(#hunters + 1)
            hunters[#hunters + 1] = id
            local record = {
                id = id, contract_id = contractId, hunter_cid = 'HUNTER' .. pick(3),
                alias = 'Operative #' .. pick(9), anon = pick(2) == 1,
                accepted_at = 2000 + step, state = 'active',
            }
            ops[#ops + 1] = { what = 'addHunter ' .. id,
                run = function(store)
                    local copy = {}
                    for k, v in pairs(record) do copy[k] = v end
                    return store.addHunter(copy)
                end }

        else
            local contractId = contracts[pick(#contracts)]
            ops[#ops + 1] = { what = 'advanceSlot ' .. contractId,
                run = function(store) return store.advanceSlot(contractId, 1) end }
        end
    end

    return ops, contracts, lines
end

--- Everything observable, as a comparable string.
local function snapshot(store, contracts, lines)
    local out = {}

    local all = store.allContracts() or {}
    local ids = {}
    for _, c in ipairs(all) do ids[#ids + 1] = c.id end
    table.sort(ids)
    out[#out + 1] = 'contracts=' .. table.concat(ids, ',')

    for _, id in ipairs(contracts) do
        local c = store.readContract(id)
        if c then
            out[#out + 1] = ('%s state=%s creator=%s target=%s mode=%s slots=%s next=%s')
                :format(id, tostring(c.state), tostring(c.creator_cid),
                        tostring(c.target_cid), tostring(c.mode),
                        tostring(c.payout_slots), tostring(c.next_slot))
        else
            out[#out + 1] = id .. ' absent'
        end

        local escrow = store.readEscrow(id) or {}
        local rows = {}
        for _, l in ipairs(escrow) do
            rows[#rows + 1] = ('%s/%s/%s/%s/%s/%s/%s'):format(
                tostring(l.id), tostring(l.state), tostring(l.source),
                tostring(l.amount), tostring(l.portion), tostring(l.settled_to),
                tostring(l.derived and true or nil))
        end
        table.sort(rows)
        out[#out + 1] = '  escrow ' .. table.concat(rows, ' ')

        local hunters = store.readHunters(id) or {}
        local hs = {}
        for _, h in ipairs(hunters) do
            hs[#hs + 1] = ('%s/%s/%s/%s'):format(tostring(h.id),
                tostring(h.hunter_cid), tostring(h.anon and true or false),
                tostring(h.state))
        end
        table.sort(hs)
        out[#out + 1] = '  hunters ' .. table.concat(hs, ' ')
    end

    for _, id in ipairs(lines) do
        local l = store.readEscrowLine(id)
        out[#out + 1] = ('line %s -> %s'):format(id, l and tostring(l.state) or 'absent')
    end

    return table.concat(out, '\n')
end

describe('the three backends given the same history', function()
    --- Enough runs to cross the interesting boundaries, few enough that the
    --- suite stays quick. Deterministic seeds, so a failure is reproducible
    --- from its number alone.
    local RUNS, LENGTH = 40, 30

    it('agree on everything observable, over ' .. RUNS .. ' random histories', function()
        local diverged = {}

        for seed = 1, RUNS do
            local ops, contracts, lines = history(seed, LENGTH)
            local shots, answers = {}, {}

            for _, b in ipairs(backends()) do
                -- The return value of every operation is part of what the
                -- backends have to agree on: a compare-and-set that says
                -- true on one and false on another is a divergence even
                -- when the rows end up the same.
                local said = {}
                for i, op in ipairs(ops) do
                    local ok, result = pcall(op.run, b.store)
                    said[i] = ok and tostring(result) or ('THREW ' .. tostring(result))
                end
                answers[b.name] = table.concat(said, ',')
                shots[b.name] = snapshot(b.store, contracts, lines)
            end

            for _, name in ipairs({ 'json', 'mysql' }) do
                if answers[name] ~= answers.memory then
                    local at = 1
                    local mine = {}
                    for word in answers[name]:gmatch('[^,]*') do mine[#mine + 1] = word end
                    local theirs = {}
                    for word in answers.memory:gmatch('[^,]*') do theirs[#theirs + 1] = word end
                    for i = 1, math.max(#mine, #theirs) do
                        if mine[i] ~= theirs[i] then at = i break end
                    end
                    diverged[#diverged + 1] = ('seed %d: %s answered %s where memory said %s, at step %d (%s)')
                        :format(seed, name, tostring(mine[at]), tostring(theirs[at]),
                                at, ops[at] and ops[at].what or '?')
                elseif shots[name] ~= shots.memory then
                    local mineLines, theirLines = {}, {}
                    for line in shots[name]:gmatch('[^\n]+') do mineLines[#mineLines + 1] = line end
                    for line in shots.memory:gmatch('[^\n]+') do theirLines[#theirLines + 1] = line end
                    local first = 'identical line counts'
                    for i = 1, math.max(#mineLines, #theirLines) do
                        if mineLines[i] ~= theirLines[i] then
                            first = ('%s has [%s], memory has [%s]'):format(
                                name, tostring(mineLines[i]), tostring(theirLines[i]))
                            break
                        end
                    end
                    diverged[#diverged + 1] = ('seed %d: %s'):format(seed, first)
                end
            end
        end

        eq(#diverged, 0,
            'the backends have to be interchangeable, and a server that '
            .. 'switches between them keeps its contracts:\n  '
            .. table.concat(diverged, '\n  ', 1, math.min(#diverged, 6)))
    end)
end)
