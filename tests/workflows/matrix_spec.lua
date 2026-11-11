--- Step 7: the main flows, end to end, in every configuration, on every
--- store, with a restart, a crash and a player leaving injected along the way.
---
--- The flows (tests/workflows/flows.lua): place -> accept -> handover ->
--- payout; place -> accept -> kill -> verify; a buyout; an intel purchase;
--- the organisation's pay day; body disposal; staff freeze, reassign and
--- reward change. Each through the real handlers of a real server/main.lua,
--- asserting what the players see, the money (conserved to the dollar, less
--- what a flow may take out: an intel price; plus what staff add), the audit
--- rows, and that nothing is left half done.
---
--- Configurations: 'shipped' (config.lua as the owner ships it), 'allon'
--- (every switch on but those W.ALL_ON_SKIPPED names), and each integration
--- set to 'none' in turn. Stores: memory, json, the executing mysql harness.
---
--- Faults:
---   * at every step boundary: a graceful restart, a crash (no stop, the
---     audit queue lost), and a player leaving and coming back (the one who
---     leaves rotates: placer, target, hitman). Memory keeps nothing across a
---     restart ('testing only', config.lua), so on memory only the drop runs;
---   * on mysql, inside each step at its database awaits: a crash before the
---     statement or after it ran (the request never resumes, the server
---     starts again, the player tries again if it did not land), and a
---     player leaving there (the request carries on).
---
--- How much runs: by default the 'none' profiles inject at the boundary after
--- the acceptance only, and the per-await faults are sampled (every 4th
--- await, alternating before/after, and a drop at every 6th). With
--- CH_WORKFLOWS_FULL=1 every boundary of every profile and every await in
--- both phases, with a drop at each, runs (about 25 minutes). Under the
--- invariant monitor (tests/invariants.lua) only the shipped profile's
--- boundaries run: the monitor audits the whole store after every write.

local W = require('tests.workflows.lib')
local F = require('tests.workflows.flows')
W.ran.matrix = true

local FULL = os.getenv('CH_WORKFLOWS_FULL') == '1'
local MONITORED = _G.__SKIP_RAW_STORE_SPECS == true

--- Failures that are known bugs, by signature: a test whose failure matches
--- one (its flow, its fault, the step it was cut in, the words of the
--- failure) is counted as an expected failure (step7-bugs.md). A failure
--- matching none is a failure.
local KNOWN_BUGS = {
    { bug = 'BUG-2: a crash between confirming the hitman row and the contract\'s ACTIVE->ACCEPTED leaves an '
          .. 'active hitman on an unaccepted contract that nothing repairs',
      fault = 'crash', step = 'accept', msg = { 'expected completed, got active', 'the kill is the hitman',
          'armed: bad_state', 'got active', 'the new hitman arms the handover: bad_state',
          'op reassignPreview refused', 'a preview: ' } },
    { bug = 'BUG-3: a crash after the tip\'s price was taken and before its row loses the price',
      fault = 'crash', step = 'buy', msg = { 'money not conserved' } },
    { bug = 'BUG-4: a crash inside Funds.debit (bank removed, ledger row not written) loses a salary',
      fault = 'crash', step = 'payday', msg = { 'money not conserved', 'was paid their salary' } },
    { bug = 'BUG-5: a crash inside Funds.credit (ledger row written, bank not credited) loses a deposit',
      fault = 'crash', step = 'fund', msg = { 'money not conserved', 'was paid their salary' } },
}

--- Exact repro tests of the bugs above, that must fail until fixed.
local EXPECTED_FAIL = {
    ['BUG-1: a crash loses the financial audit rows the queue held'] = 'BUG-1',
    ['BUG-2: crash after the hitman row is confirmed, before the contract is accepted'] = 'BUG-2',
    ['BUG-3: crash after the tip price is taken, before the tip row'] = 'BUG-3',
    ['BUG-4: crash after the salary left the bank, before the ledger row'] = 'BUG-4',
    ['BUG-5: crash after a deposit\'s ledger row, before the bank is credited'] = 'BUG-5',
}

W.knownHits = W.knownHits or {}

local function known(meta, err)
    for _, k in ipairs(KNOWN_BUGS) do
        if (k.fault == meta.fault) and (k.step == meta.step) then
            for _, m in ipairs(k.msg) do
                if tostring(err):find(m, 1, true) then return k.bug end
            end
        end
    end
    return nil
end

--- A matrix cell: runs, and a failure matching a known bug is counted as
--- such rather than failing the suite.
local function cell(name, meta, fn)
    W.it(name, function()
        local ok, err = pcall(fn)
        if ok then
            truthy(true)
            return
        end
        local bug = known(meta, err)
        if not bug then error(err, 0) end
        W.knownHits[#W.knownHits + 1] = { test = W.test, bug = bug, err = tostring(err) }
        truthy(bug, 'a known bug')
    end)
end

local WHO = { 'creator', 'target', 'hitman' }

--------------------------------------------------------------------------
-- Every flow, clean and with a fault at its step boundaries
--------------------------------------------------------------------------

local profiles = MONITORED and { 'shipped' } or W.PROFILES

for _, profile in ipairs(profiles) do
    local everyBoundary = FULL or profile == 'shipped' or profile == 'allon'
    describe('workflow matrix: ' .. profile, function()
        for _, mode in ipairs(W.MODES) do
            for _, name in ipairs(F.ORDER) do
                local flow = F[name]
                cell(('%s on %s: clean'):format(name, mode), {}, function()
                    F.run(flow, mode, profile)
                end)
                for at = 0, #flow.steps do
                    if everyBoundary or at == 2 then
                        local stepName = flow.steps[at + 1] and flow.steps[at + 1].name or 'end'
                        if mode ~= 'memory' and not MONITORED then
                            for _, fault in ipairs({ 'restart', 'crash' }) do
                                cell(('%s on %s: %s before %s'):format(name, mode, fault, stepName),
                                    { fault = fault, step = stepName }, function()
                                        F.run(flow, mode, profile, fault, at)
                                    end)
                            end
                        end
                        local who = WHO[(at % #WHO) + 1]
                        cell(('%s on %s: the %s leaves before %s'):format(name, mode, who, stepName),
                            { fault = 'drop', step = stepName }, function()
                                F.run(flow, mode, profile, 'drop', at, who)
                            end)
                    end
                end
            end
        end
    end)
end

--------------------------------------------------------------------------
-- A fault at the database awaits inside each step (mysql)
--------------------------------------------------------------------------

if not MONITORED then
    local awaitProfiles = FULL and { 'shipped', 'allon' } or { 'shipped' }
    for _, profile in ipairs(awaitProfiles) do
        describe('workflow matrix: ' .. profile .. ', a fault at a database await (mysql)', function()
            for _, name in ipairs(F.ORDER) do
                local flow = F[name]
                local depths = F.depths(flow, profile)
                for i, step in ipairs(flow.steps) do
                    for k = 1, depths[i] do
                        local phases
                        if FULL then phases = { 'pre', 'post' }
                        elseif k % 4 == 1 then phases = { (k % 8 == 1) and 'pre' or 'post' }
                        else phases = {} end
                        for _, phase in ipairs(phases) do
                            cell(('%s: crash in %s at await %d (%s)'):format(name, step.name, k, phase),
                                { fault = 'crash', step = step.name }, function()
                                    F.run(flow, 'mysql', profile, 'crash', nil, nil,
                                        { await = { step = i, k = k, phase = phase } })
                                end)
                        end
                        if FULL or k % 6 == 3 then
                            local who = WHO[(k % #WHO) + 1]
                            cell(('%s: the %s leaves in %s at await %d'):format(name, who, step.name, k),
                                { fault = 'drop', step = step.name }, function()
                                    F.run(flow, 'mysql', profile, 'drop', nil, who,
                                        { await = { step = i, k = k, phase = 'pre' } })
                                end)
                        end
                    end
                end
            end
        end)
    end
end

--------------------------------------------------------------------------
-- The bugs, each pinned by an exact repro
--------------------------------------------------------------------------

local function upTo(flow, n)
    W.boot('mysql', 'shipped')
    W.cast(W.s)
    local ctx = { flow = flow.name }
    flow.setup(ctx)
    W.tick(1)
    for i = 1, n do flow.steps[i].run(ctx) end
    return ctx
end

--- Crash step n+1 of a flow at the await whose statement matches `sql`.
local function crashAt(flow, n, sql, phase)
    local ctx = upTo(flow, n)
    local start = W.world()
    local probeCount = 0
    -- Find the await by its statement, so the repro does not drift.
    W.boot('mysql', 'shipped')
    W.cast(W.s)
    local c2 = { flow = flow.name }
    flow.setup(c2)
    W.tick(1)
    for i = 1, n do flow.steps[i].run(c2) end
    local statements = {}
    local inner = W.s.timing.await
    W.s.storage.timeWaitsWith(function(send, s, ...)
        probeCount = probeCount + 1
        statements[probeCount] = type(s) == 'string' and s or 'TRANSACTION'
        return inner(send, s, ...)
    end)
    flow.steps[n + 1].run(c2)
    W.s.storage.timeWaitsWith(inner)
    local k
    for i, text in ipairs(statements) do
        if text:find(sql, 1, true) then k = i break end
    end
    truthy(k, 'the statement ' .. sql .. ' is among the step\'s awaits')
    ctx = upTo(flow, n)
    start = W.world()
    local rec = W.atAwait(k, phase, function() flow.steps[n + 1].run(ctx) end, function() end, true)
    truthy(rec.fired, 'cut at the await')
    W.restart(W.s, false)
    W.tick(3, 60)
    return ctx, start
end

describe('workflow matrix: the bugs, pinned', function()
    W.it('BUG-1: a crash loses the financial audit rows the queue held', function()
        local ctx = upTo(F.contract, 4)
        eq(W.contract(ctx.id).state, CH.STATE.COMPLETED, 'paid')
        W.restart(W.s, false)
        W.tick(1, 15)
        truthy(#W.audit('escrow_released') >= 1,
            'the payout\'s financial rows (escrow_released) survived the crash')
    end, EXPECTED_FAIL)

    W.it('BUG-2: crash after the hitman row is confirmed, before the contract is accepted', function()
        local ctx = crashAt(F.contract, 1, "UPDATE crimson_hitmen SET state = 'active'", 'post')
        local c = W.contract(ctx.id)
        local h = F.hitmanRow(ctx.id)
        truthy(not (h and h.state == 'active') or c.state == CH.STATE.ACCEPTED,
            ('an active hitman on a contract in state %s'):format(tostring(c.state)))
    end, EXPECTED_FAIL)

    W.it('BUG-3: crash after the tip price is taken, before the tip row', function()
        local ctx, start = crashAt(F.intel, 2, 'INSERT INTO crimson_location_tips', 'pre')
        local tips = W.s.storage.readLocationTips(ctx.id) or {}
        eq(W.world() - start, #tips > 0 and -Config.Intel.LocationTip.Cost or 0,
            'the price is kept only with a tip to show for it')
    end, EXPECTED_FAIL)

    W.it('BUG-4: crash after the salary left the bank, before the ledger row', function()
        local _, start = crashAt(F.payroll, 2, 'crimson_org_funds', 'pre')
        W.tick(2, 15)
        eq(W.world() - start, 0, 'the salary is paid or still in the funds')
    end, EXPECTED_FAIL)

    W.it('BUG-5: crash after a deposit\'s ledger row, before the bank is credited', function()
        local _, start = crashAt(F.payroll, 1, 'INSERT INTO crimson_org_funds', 'post')
        local ok, bal = pcall(function() return require('server.org.funds').balance(W.s.org.current()) end)
        eq(ok and bal or 0, 10000, 'the deposit the ledger records is in the funds')
        local _ = start
    end, EXPECTED_FAIL)
end)

return W
