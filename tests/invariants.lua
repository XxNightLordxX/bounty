--- Every structural rule the store must obey, checked against the whole
--- server suite rather than against scenarios of its own.
---
--- A different question from the one the specs ask. They each assert what
--- one operation should do; this asserts what must be true of the store
--- afterwards, no matter which operation ran — so all 944 of them become
--- probes of rules nothing states test by test.
---
---   lua5.4 tests/invariants.lua
---
--- Two things it took to make this say anything true.
---
--- Auditing after every write reports the middle of a transition: the write
--- that closes a contract lands before the write that releases its escrow,
--- and between the two the store is legitimately inconsistent. That was 190
--- "violations", none of them real. Rules that only hold once an operation
--- has finished are checked after each test instead.
---
--- And "a closed contract holds nothing" is not the rule. Held is right
--- when the line is owed to somebody named: an undeliverable payout waits
--- for that player's pockets, a premium owed to an offline creator waits
--- for them to come back. The rule is that nothing is STRANDED — held on a
--- closed contract and owed to nobody, which is money with no claimant and
--- no way out. Getting that wrong is how a monitor reports six failures
--- that are all deliberate behaviour.
---
--- Validated by defect rather than by reading: stopping settleEscrowLine
--- from recording who it paid, and letting a contract reach a state the
--- enum does not name, are both reported.

-- Run the whole existing suite with a monitor that checks structural
-- invariants after every storage write. No new scenarios: each of the 944
-- tests becomes a probe of rules nothing asserts test by test.
local realExit = os.exit
os.exit = function() end

local violations = {}
local checked = 0
local current = '?'

local function note(rule, detail)
    local key = rule .. ' | ' .. detail
    for _, v in ipairs(violations) do if v.key == key then v.n = v.n + 1 return end end
    violations[#violations + 1] = { key = key, n = 1, where = current }
end

--- Everything that must be true of the store at rest.
local function audit(store)
    -- Stores a spec writes rows into directly are not the resource's
    -- output, so the rules below do not describe them. differential_spec
    -- compares backends by writing combinations the business layer would
    -- never produce; auditing those reports its fixture.
    if rawget(store, '__rawFixture') then return end
    checked = checked + 1
    local ok, contracts = pcall(store.allContracts)
    if not ok or type(contracts) ~= 'table' then return end

    local known = {}
    for _, c in ipairs(contracts) do
        known[c.id] = c

        -- 1. Every contract is in a state the enum names.
        local legal = false
        for _, state in pairs(CH.STATE) do if c.state == state then legal = true end end
        if not legal then note('unknown contract state', tostring(c.state)) end

        -- 2. A contract always names a creator and a target.
        if not c.creator_cid or c.creator_cid == '' then note('contract with no creator', c.id) end
        if not c.target_cid or c.target_cid == '' then note('contract with no target', c.id) end

        -- 3. Nobody takes a contract on themselves, and nobody is their own target.
        if c.creator_cid == c.target_cid then note('creator is the target', c.id) end
    end

    for _, c in ipairs(contracts) do
        local lines = pcall(store.readEscrow, c.id) and store.readEscrow(c.id) or {}
        for _, l in ipairs(lines) do
            -- 4. Every escrow line is in a state the enum names.
            local legal = false
            for _, state in pairs(CH.ESCROW_STATE) do if l.state == state then legal = true end end
            if not legal then note('unknown escrow state', tostring(l.state)) end

            -- 5. Amounts are never negative.
            if (l.amount or 0) < 0 then note('negative escrow amount', l.id .. '=' .. tostring(l.amount)) end
            if (l.quantity or 0) < 0 then note('negative escrow quantity', tostring(l.id)) end

            -- 6. A settled line names who it settled to.
            if l.state == CH.ESCROW_STATE.SETTLED and not l.settled_to then
                note('settled to nobody', tostring(l.id))
            end

            -- 7. An escrow line always belongs to a contract that exists.
            if l.contract_id and not known[l.contract_id] then
                note('escrow line orphaned from its contract', tostring(l.id))
            end

            -- 8. Money staff added to a reward (server/staff_reward.lua,
            -- taken_from 'staff') never reaches the contract's placer, and
            -- only money staff added ever goes back to staff: what staff
            -- put in is all that can come out to them.
            if l.taken_from == 'staff' and l.state == CH.ESCROW_STATE.SETTLED
                and l.settled_to == c.creator_cid then
                note('money staff added paid to the placer', tostring(l.id))
            end
            if (l.settled_to == 'staff' or l.owed_to == 'staff' or l.releasing_to == 'staff')
                and l.taken_from ~= 'staff' then
                note('money staff did not add went to staff', tostring(l.id))
            end

            -- 8b. A split owes exactly what it cut from the line it splits
            -- (Escrow.reduceStake, Escrow.reduceLine): a lowered stake or
            -- reward neither mints nor loses the difference.
            local mark = type(l.metadata) == 'table' and l.metadata or nil
            if l.portion == CH.PORTION.OWED and mark and mark.splitFrom
                and tonumber(mark.stakeWas) and tonumber(mark.stakeNow)
                and (l.amount or 0) ~= tonumber(mark.stakeWas) - tonumber(mark.stakeNow)
                -- Emptied: a split voided because its cut never landed.
                and (l.amount or 0) ~= 0 then
                note('a split owes other than what it cut', tostring(l.id))
            end

        end

        -- 9. A hitman row always points at a contract that exists.
        local hitmen = pcall(store.readHitmen, c.id) and store.readHitmen(c.id) or {}
        for _, h in ipairs(hitmen) do
            if h.contract_id ~= c.id then note('hitman row on the wrong contract', tostring(h.id)) end
            if h.hitman_cid == c.target_cid then note('the target is on their own contract', c.id) end
        end
    end
end

--- Rules that are only true once an operation has finished.
---
--- Auditing these after every write reports the middle of a transition:
--- the write that closes a contract lands before the write that releases
--- its escrow, and between the two the store is legitimately inconsistent.
--- 190 "violations" that way, none of them real. Checked at rest instead.
local function auditAtRest(store)
    if rawget(store, '__rawFixture') then return end
    local ok, contracts = pcall(store.allContracts)
    if not ok or type(contracts) ~= 'table' then return end
    for _, c in ipairs(contracts) do
        -- Owed back to staff is settled at once (nobody to queue it for):
        -- held so at rest is money that will never go anywhere.
        for _, l in ipairs(pcall(store.readEscrow, c.id) and store.readEscrow(c.id) or {}) do
            if l.state == CH.ESCROW_STATE.HELD and l.owed_to == 'staff' then
                note('owed back to staff and left held', tostring(l.id))
            end
        end
        if CH.TERMINAL[c.state] then
            local lines = pcall(store.readEscrow, c.id) and store.readEscrow(c.id) or {}
            for _, l in ipairs(lines) do
                -- Held is legitimate when the line is owed to somebody
                -- named: an undeliverable payout waits for that player's
                -- pockets, and a premium owed to an offline creator waits
                -- for them to come back. What must never happen is a held
                -- line on a closed contract that is owed to nobody — that
                -- is money with no claimant and no way out.
                if l.state == CH.ESCROW_STATE.HELD and not l.owed_to then
                    note('escrow stranded on a closed contract',
                        c.state .. ' ' .. tostring(l.id))
                end
                -- Mid-release at rest is a settle that never finished.
                if l.state == CH.ESCROW_STATE.RELEASING then
                    note('escrow left mid-release on a closed contract',
                        c.state .. ' ' .. tostring(l.id))
                end
            end
        end
    end

    -- Body disposal (server/disposal.lua): a step names a contract that
    -- exists and a kill may complete, by the hitman on it; and the payout it
    -- holds is owed to that hitman or, after a timeout's refund, the placer,
    -- never to anybody else and never to nobody.
    if type(store.readRpRows) == 'function' then
        local known = {}
        for _, c in ipairs(contracts) do known[c.id] = c end
        local okD, steps = pcall(store.readRpRows, 'disposal')
        for _, step in ipairs(okD and type(steps) == 'table' and steps or {}) do
            local c = known[step.contract_id]
            if not c then
                note('a disposal step on no contract', tostring(step.id))
            else
                if c.fulfilment_rule == 'alive' then note('a disposal step where no kill counts', tostring(step.id)) end
                if step.hitman_cid == c.target_cid or step.hitman_cid == c.creator_cid then
                    note('a disposal step for the wrong party', tostring(step.id))
                end
                local okL, lines = pcall(store.readEscrow, c.id)
                for _, l in ipairs(okL and lines or {}) do
                    if l.portion == CH.PORTION.BASELINE and tonumber(l.slot) == tonumber(step.slot)
                        and l.state == CH.ESCROW_STATE.HELD and l.owed_to ~= step.hitman_cid
                        and l.owed_to ~= c.creator_cid then
                        note('a disposal payout owed to somebody else', tostring(l.id))
                    end
                end
            end
        end
    end

    -- The hitman organisation (server/org/): a cut is more than nothing and
    -- never more than the escrow line it was taken from, so a member and
    -- the funds between them never received more than was escrowed; and
    -- the internal ledger (its own rows, never the bank's) never holds less
    -- than nothing.
    if type(store.readOrgRows) == 'function' then
        local okF, funds = pcall(store.readOrgRows, 'funds')
        if okF and type(funds) == 'table' then
            local totals = {}
            for _, row in ipairs(funds) do
                local amount = tonumber(row.amount) or 0
                -- The ledger's balance is the sum of its own rows; the
                -- bank's rows are Renewed-Banking's history.
                if row.backend == 'internal' then
                    totals[row.org_id] = (totals[row.org_id] or 0) + amount
                end
                if row.kind == 'cut' then
                    if amount <= 0 then note('an organisation cut of nothing', tostring(row.id)) end
                    local lineId = tostring(row.id):match('^cut:(.+)$')
                    local okL, line = pcall(store.readEscrowLine, lineId)
                    if okL and type(line) == 'table' and line.id == lineId
                        and amount > (tonumber(line.amount) or 0) then
                        note('an organisation cut above its escrow line', tostring(row.id))
                    end
                end
            end
            for org, total in pairs(totals) do
                if total < 0 then note('organisation funds below zero', tostring(org)) end
            end
        end
    end
end

--- Every store the suite has built, held weakly: a store nothing else
--- refers to any more cannot be called again, so it has nothing left to
--- audit. Held strongly, every stack the suite ever built stayed in memory,
--- and the run reached its 3 GB limit about a third of the way in and
--- crawled on through one emergency collection after another: past the
--- half-hour timeout, with console_spec alone taking thirteen minutes of
--- what is four seconds on its own.
local watched = setmetatable({}, { __mode = 'k' })

--- The watched stores anything called since the last at-rest audit.
---
--- Every stack the suite builds is a new store (newStack reloads
--- storage.memory), and each was audited at rest after every test that
--- followed it: thousands of stores no later test touches, read again after
--- each of thousands of tests. That made the run quadratic in the size of
--- the suite: a four-minute suite had not finished in fifteen under the
--- monitor, and takes under seven this way. A store nothing called during
--- a test cannot have changed in it, so only the ones something did call
--- are audited; every function on a store marks it, a read included, so a
--- write this file does not wrap is not missed.
local touched = setmetatable({}, { __mode = 'k' })

--- Wrap every write on every backend, so the monitor runs wherever the
--- suite happens to be pointed.
local WRITES = {
    'writeContract', 'writeEscrow', 'claimEscrowLine', 'settleEscrowLine',
    'setEscrowAmount', 'compareSetContractState', 'advanceSlot', 'addHitman',
    'updateHitman',
}

local function monitor(store, name)
    watched[store] = true
    for key, real in pairs(store) do
        if type(real) == 'function' then
            store[key] = function(...)
                touched[store] = true
                return real(...)
            end
        end
    end
    for _, fn in ipairs(WRITES) do
        local real = store[fn]
        if type(real) == 'function' then
            store[fn] = function(...)
                -- 10. A reward cut (Escrow.reduceLine: a split marked
                -- `reward`) never lands on a line already owed to somebody,
                -- or being given to somebody (review-x F1): a claim marks its
                -- collection for its hitman first, and a cut after the marks
                -- owed the hitman's money to the placer. Body disposal's own
                -- splits of a payout owed to its hitman are not reward cuts.
                local was
                if fn == 'setEscrowAmount' and type(store.readEscrowLine) == 'function' then
                    local okR, line = pcall(store.readEscrowLine, (...))
                    if okR and type(line) == 'table' then
                        was = { amount = line.amount, owed = line.owed_to or line.releasing_to,
                            portion = line.portion, contract = line.contract_id }
                    end
                end
                local results = { real(...) }
                local lowered = select(3, ...)
                if was and results[1] and was.owed and was.portion ~= CH.PORTION.OWED
                    and type(lowered) == 'number' and lowered < (was.amount or 0) then
                    local okE, lines = pcall(store.readEscrow, was.contract)
                    for _, l in ipairs(okE and type(lines) == 'table' and lines or {}) do
                        local mark = type(l.metadata) == 'table' and l.metadata or nil
                        if mark and mark.reward and mark.splitFrom == (...) and mark.stakeNow == lowered then
                            note('a reward cut landed on a line owed to somebody', tostring((...)))
                        end
                    end
                end
                local ok = pcall(audit, store)
                if not ok then note('the monitor itself threw', fn) end
                return table.unpack(results)
            end
        end
    end
    return store
end

-- Installed by wrapping require, so every stack the suite builds is watched.
local realRequire = require
_G.require = function(name)
    local mod = realRequire(name)
    if type(name) == 'string' and name:find('storage%.') and type(mod) == 'table'
        and not rawget(mod, '__monitored') then
        rawset(mod, '__monitored', true)
        monitor(mod, name)
    end
    return mod
end

--- Audited after each test rather than at the end of the run, so a
--- violation names the test that left it. run.lua publishes `it` into the
--- globals as it starts, so the assignment is intercepted here and the
--- real one wrapped.
setmetatable(_G, {
    __newindex = function(t, key, value)
        if key == 'it' and type(value) == 'function' then
            rawset(t, key, function(name, fn)
                current = name
                value(name, fn)
                for store in pairs(watched) do
                    if touched[store] then pcall(auditAtRest, store) end
                end
                -- Cleared after, since the audit's own reads mark them too.
                for store in pairs(touched) do touched[store] = nil end
            end)
            return
        end
        rawset(t, key, value)
    end,
})

--- Specs that write rows into the store by hand are left out.
---
--- differential_spec compares the three backends by putting rows in
--- directly, so it deliberately writes combinations the resource would
--- never produce — a creator who is also the target, escrow on a contract
--- already closed. These rules describe what the business layer upholds,
--- not what the store enforces, so running them over that spec measures
--- its fixture. Two instruments, each meaningful on its own, and meaningless
--- pointed at each other.
_G.__SKIP_RAW_STORE_SPECS = true

local ok, err = pcall(function()
    dofile('tests/run.lua')
end)
setmetatable(_G, nil)
_G.require = realRequire
os.exit = realExit

io.stderr:write(('\n=== invariant monitor: %d store audits ===\n'):format(checked))
if #violations == 0 then
    io.stderr:write('no violations\n')
else
    for _, v in ipairs(violations) do
        io.stderr:write(('  x%-5d %s\n              first left by: %s\n')
            :format(v.n, v.key, tostring(v.where)))
    end
    io.stderr:write(('\n%d distinct violation(s)\n'):format(#violations))
    realExit(1)
end
realExit(0)
