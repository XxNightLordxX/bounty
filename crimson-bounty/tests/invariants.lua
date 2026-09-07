--- Every structural rule the store must obey, checked against the whole
--- server suite rather than against scenarios of its own.
---
--- A different question from the one the specs ask. They each assert what
--- one operation should do; this asserts what must be true of the store
--- afterwards, no matter which operation ran — so all 944 of them become
--- probes of rules nothing states test by test.
---
---   lua5.4 crimson-bounty/tests/invariants.lua
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
        for _, state in pairs(CB.STATE) do if c.state == state then legal = true end end
        if not legal then note('unknown contract state', tostring(c.state)) end

        -- 2. A contract always names a creator and a target.
        if not c.creator_cid or c.creator_cid == '' then note('contract with no creator', c.id) end
        if not c.target_cid or c.target_cid == '' then note('contract with no target', c.id) end

        -- 3. Nobody hunts themselves, and nobody is their own target.
        if c.creator_cid == c.target_cid then note('creator is the target', c.id) end
    end

    for _, c in ipairs(contracts) do
        local lines = pcall(store.readEscrow, c.id) and store.readEscrow(c.id) or {}
        for _, l in ipairs(lines) do
            -- 4. Every escrow line is in a state the enum names.
            local legal = false
            for _, state in pairs(CB.ESCROW_STATE) do if l.state == state then legal = true end end
            if not legal then note('unknown escrow state', tostring(l.state)) end

            -- 5. Amounts are never negative.
            if (l.amount or 0) < 0 then note('negative escrow amount', l.id .. '=' .. tostring(l.amount)) end
            if (l.quantity or 0) < 0 then note('negative escrow quantity', tostring(l.id)) end

            -- 6. A settled line names who it settled to.
            if l.state == CB.ESCROW_STATE.SETTLED and not l.settled_to then
                note('settled to nobody', tostring(l.id))
            end

            -- 7. An escrow line always belongs to a contract that exists.
            if l.contract_id and not known[l.contract_id] then
                note('escrow line orphaned from its contract', tostring(l.id))
            end

        end

        -- 9. A hunter row always points at a contract that exists.
        local hunters = pcall(store.readHunters, c.id) and store.readHunters(c.id) or {}
        for _, h in ipairs(hunters) do
            if h.contract_id ~= c.id then note('hunter row on the wrong contract', tostring(h.id)) end
            if h.hunter_cid == c.target_cid then note('the target is hunting themselves', c.id) end
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
        if CB.TERMINAL[c.state] then
            local lines = pcall(store.readEscrow, c.id) and store.readEscrow(c.id) or {}
            for _, l in ipairs(lines) do
                -- Held is legitimate when the line is owed to somebody
                -- named: an undeliverable payout waits for that player's
                -- pockets, and a premium owed to an offline creator waits
                -- for them to come back. What must never happen is a held
                -- line on a closed contract that is owed to nobody — that
                -- is money with no claimant and no way out.
                if l.state == CB.ESCROW_STATE.HELD and not l.owed_to then
                    note('escrow stranded on a closed contract',
                        c.state .. ' ' .. tostring(l.id))
                end
                -- Mid-release at rest is a settle that never finished.
                if l.state == CB.ESCROW_STATE.RELEASING then
                    note('escrow left mid-release on a closed contract',
                        c.state .. ' ' .. tostring(l.id))
                end
            end
        end
    end
end

local watched = {}

--- Wrap every write on every backend, so the monitor runs wherever the
--- suite happens to be pointed.
local WRITES = {
    'writeContract', 'writeEscrow', 'claimEscrowLine', 'settleEscrowLine',
    'setEscrowAmount', 'compareSetContractState', 'advanceSlot', 'addHunter',
    'updateHunter',
}

local function monitor(store, name)
    watched[#watched + 1] = store
    for _, fn in ipairs(WRITES) do
        local real = store[fn]
        if type(real) == 'function' then
            store[fn] = function(...)
                local results = { real(...) }
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
                for _, store in ipairs(watched) do pcall(auditAtRest, store) end
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
    dofile('crimson-bounty/tests/run.lua')
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
