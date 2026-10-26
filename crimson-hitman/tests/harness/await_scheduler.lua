--- Two handlers interleaved at every database await, on mysql.
---
--- On a live server every oxmysql await yields its coroutine (OXMYSQL.md
--- §7), and anything else in the resource may run before it resumes: other
--- net events, the tick, a command. The executor in mysql_exec.lua answers
--- at once, so a suite never sees that. This boots the real server/main.lua
--- on it and makes every await a real yield, through the seam mysql.lua
--- already has (MySQLStore.timeWaitsWith, which main points at
--- Timing.await).
---
--- Handler A runs in its own coroutine. At its k-th await it stops, either
--- before the statement runs ('pre') or after it ran and before A sees the
--- answer ('post'), and handler B runs to completion in a coroutine of its
--- own. A Wait inside B yields, and A runs to the end meanwhile, as the
--- engine would run it; then B carries on.
---
--- The oracle: what the money looks like at the end (every purse, money
--- owed to somebody by name counted as theirs, every unsettled line held)
--- must equal one of the four serial outcomes, A;B, B;A, A alone (B
--- refused), B alone (A refused). Anything else lost, minted or misdirected
--- money, or wrote a stale copy over a newer one. And nothing may be left
--- stuck: no line `releasing`, no contract `completing`, no busy key, no
--- line in flight, no claim counted running.
---
--- Ported from the scratchpad probe that found the mysql races
--- (sql/interleave/lib.lua). Nothing in here ships to the server.

local Exec = require('crimson-hitman.tests.harness.mysql_exec')

local Scheduler = { Exec = Exec }

--- The server's modules, forgotten so a boot loads them fresh.
local function forget()
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
            package.loaded[name] = nil
        end
    end
end

--------------------------------------------------------------------------
-- The scheduler
--------------------------------------------------------------------------

--- Which coroutine is A, the await it stops at, and what it has counted.
local S = { A = nil, k = nil, phase = 'pre', count = 0, fired = false, statements = {} }
Scheduler.S = S

--- Every coroutine this made, so Wait knows it may yield there.
local ours = setmetatable({}, { __mode = 'k' })

local function describeStatement(sql)
    if type(sql) == 'table' then return 'TRANSACTION(' .. #sql .. ')' end
    return (tostring(sql or ''):gsub('%s+', ' '):sub(1, 90))
end

--- The wrapper mysql.lua hands every await to: A's k-th one yields.
local function yieldingAwait(inner)
    return function(fn, sql, ...)
        local co = coroutine.running()
        if co == S.A and not S.fired then
            S.count = S.count + 1
            S.statements[S.count] = describeStatement(sql)
            if S.count == S.k then
                S.fired = true
                S.firedAt = S.statements[S.count]
                if S.phase == 'pre' then
                    coroutine.yield('await')
                    return inner(fn, sql, ...)
                end
                local out = table.pack(inner(fn, sql, ...))
                coroutine.yield('await')
                return table.unpack(out, 1, out.n)
            end
        elseif co == S.A then
            S.count = S.count + 1
        end
        return inner(fn, sql, ...)
    end
end

--- Wait yields inside this scheduler's coroutines and nowhere else.
local function yieldingWait()
    local co = coroutine.running()
    if ours[co] and coroutine.isyieldable() then coroutine.yield('wait') end
end

--- Resume `co` until it finishes, yields `stopOn`, or parks on an await
--- nothing will answer (Env.PARKED). Anything else it yields, a Wait while
--- nothing is waiting on it, is resumed straight through.
local function drive(co, stopOn)
    local out
    while coroutine.status(co) == 'suspended' do
        out = table.pack(coroutine.resume(co))
        if not out[1] then return 'error', out[2] end
        if coroutine.status(co) == 'dead' then return 'done', out end
        if out[2] == Env.PARKED then return 'parked', out end
        if stopOn and out[2] == stopOn then return 'stopped', out end
    end
    return 'done', out
end

local function spawn(fn)
    local co = coroutine.create(function() return table.pack(pcall(fn)) end)
    ours[co] = true
    return co
end

--- What a handler answered, from the pcall inside its coroutine.
local function unwrap(out)
    if type(out) ~= 'table' then return nil end
    local inner = out[2]
    if type(inner) == 'table' and inner.n then
        if not inner[1] then return { raised = tostring(inner[2]) } end
        return { inner[2], inner[3], inner[4] }
    end
    return nil
end

--- Run `first` as A, landing `second` at A's k-th await in `phase`.
---@param k integer|nil nil never stops A: its awaits are only counted
---@param phase string 'pre' | 'post'
---@return table record { a, b, aError, bError, fired, firedAt, depth }
function Scheduler.race(k, phase, first, second)
    S.k, S.phase, S.count, S.fired, S.statements, S.firedAt = k, phase or 'pre', 0, false, {}, nil
    local realWait = _G.Wait
    _G.Wait = yieldingWait
    local A = spawn(first)
    S.A = A
    local rec = { k = k, phase = phase }
    local how, out = drive(A, 'await')
    if how == 'error' then rec.aError = tostring(out) end
    if how == 'stopped' then
        rec.fired, rec.firedAt = true, S.firedAt
        if second then
            local B = spawn(second)
            while true do
                local bhow, bout = drive(B, 'wait')
                if bhow == 'stopped' then
                    -- B sleeps: the engine runs A meanwhile.
                    if coroutine.status(A) == 'suspended' then
                        local ahow, aout = drive(A)
                        rec.aOut = aout
                        if ahow == 'error' then rec.aError = tostring(aout) end
                    end
                else
                    if bhow == 'error' then rec.bError = tostring(bout) end
                    if bhow == 'parked' then rec.bError = 'B parked on an await nothing answers' end
                    rec.bOut = bout
                    break
                end
            end
        end
        if coroutine.status(A) == 'suspended' then
            local ahow, aout = drive(A)
            if ahow == 'error' then rec.aError = tostring(aout) end
            if ahow == 'parked' then rec.aError = 'A parked on an await nothing answers' end
            rec.aOut = aout
        end
    else
        if how == 'parked' then rec.aError = 'A parked on an await nothing answers' end
        rec.aOut = out
    end
    S.A = nil
    _G.Wait = realWait
    rec.a, rec.b = unwrap(rec.aOut), unwrap(rec.bOut)
    rec.depth = S.count
    return rec
end

--------------------------------------------------------------------------
-- Booting and restarting
--------------------------------------------------------------------------

--- cid -> player, kept after a drop, so their purse still counts.
Scheduler.everyone = {}

--- Every request bucket wide open, so a pairing is never refused for
--- coming too fast: what is raced is the rule, not the rate limit.
local function generousLimits()
    for _, bucket in pairs(Config.Cooldowns or {}) do
        if type(bucket) == 'table' then bucket.per, bucket.burst = 1, 100000 end
    end
    Config.Cooldowns.admin = { per = 1, burst = 100000 }
    Config.Cooldowns.adminWrite = { per = 1, burst = 100000 }
end

local function wire(main, m)
    Scheduler.main, Scheduler.m = main, m
    m.storage.timeWaitsWith(yieldingAwait(m.timing.await))
    return main, m
end

--- A fresh server on an empty mysql store, as main.lua starts it.
---@param configure function|nil run after the config is reset, before the start
---@param opts table|nil realLimits = true keeps the request buckets as configured
function Scheduler.boot(configure, opts)
    forget()
    Env.reset()
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Natives.resetResourceStates()
    resetConfig()
    Config.Database.Mode = 'mysql'
    if not (opts and opts.realLimits) then generousLimits() end
    if configure then configure() end
    Exec.install(Natives)
    Scheduler.everyone = {}
    local main = require('server.main')
    return wire(main, main.start())
end

--- The process dies and starts again: module state, threads and timers
--- gone, the tables and the players kept.
---@param graceful boolean run onResourceStop first, as a txAdmin restart does
function Scheduler.restart(graceful, configure)
    if graceful and Env.handlers['onResourceStop'] then
        pcall(Env.handlers['onResourceStop'], GetCurrentResourceName())
    end
    forget()
    Env.events, Env.clientEvents, Env.notifications = {}, {}, {}
    Env.handlers, Env.threads, Env.timers, Env.commands = {}, {}, {}, {}
    Env.parked = {}
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Config.Database.Mode = 'mysql'
    if configure then configure() end
    local main = require('server.main')
    return wire(main, main.start())
end

--------------------------------------------------------------------------
-- People
--------------------------------------------------------------------------

function Scheduler.add(opts)
    local p = Env.addPlayer(opts)
    Scheduler.everyone[opts.citizenid] = p
    return p
end

--- A creator, a target, two hitmen and a member of staff, logged in a
--- while ago so no session floor refuses anything.
function Scheduler.fixture(m)
    Scheduler.add({ source = 1, citizenid = 'CREATOR1', license = 'license:aaa',
        cash = 100000, bank = 100000, firstname = 'Vic', lastname = 'Marlowe' })
    Scheduler.add({ source = 2, citizenid = 'TARGET01', license = 'license:bbb',
        cash = 20000, bank = 20000, firstname = 'Dana', lastname = 'Reyes' })
    Scheduler.add({ source = 3, citizenid = 'HITMAN01', license = 'license:ccc',
        cash = 5000, bank = 5000, firstname = 'Rook', lastname = 'Ash' })
    Scheduler.add({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
        cash = 5000, bank = 5000, firstname = 'Sol', lastname = 'Vane' })
    Scheduler.add({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
        firstname = 'Sam', lastname = 'Steward' })
    Env.aces[6] = { ['crimson.admin'] = true, ['crimson.identity'] = true }
    for src = 1, 4 do
        local actor = m.identity.resolve(src)
        if actor and m.identity.confirmSession then pcall(m.identity.confirmSession, actor.cid) end
    end
    Env.advance(3 * 3600)
    return {
        creator = m.identity.resolve(1), target = m.identity.resolve(2),
        hitman = m.identity.resolve(3), hitman2 = m.identity.resolve(4),
    }
end

--------------------------------------------------------------------------
-- What the world looks like
--------------------------------------------------------------------------

local function purseOf(p)
    local dirty = 0
    for _, e in ipairs(p._inventory or {}) do
        if e.name == (Config.Sources.dirty and Config.Sources.dirty.item or 'black_money') then
            dirty = dirty + (e.count or 0)
        end
    end
    return (p.PlayerData.money.cash or 0) + (p.PlayerData.money.bank or 0) + dirty
        - (p._lostAfterDrop or 0)
end

--- Rows straight out of the executor, so the oracle's reads do not go
--- through the yielding store.
local function rows(name)
    local out = {}
    for _, r in pairs(Exec.tables[name] or {}) do out[#out + 1] = r end
    return out
end
Scheduler.rows = rows

--- Every unit of money: purses, unsettled money lines, a buyout paid and
--- queued.
function Scheduler.world()
    local total = 0
    for _, p in pairs(Scheduler.everyone) do total = total + purseOf(p) end
    for _, l in ipairs(rows('crimson_escrow')) do
        if CH.MONEY_SOURCES[l.source] and l.state ~= CH.ESCROW_STATE.SETTLED then
            total = total + (tonumber(l.amount) or 0) - (tonumber(l.deliver_arrived) or 0)
        end
    end
    for _, c in ipairs(rows('crimson_contracts')) do
        if c.bailout_queued_at and c.bailout_paid_amount then
            total = total + (tonumber(c.bailout_paid_amount) or 0)
        end
    end
    return total
end

--- Purses and unsettled money only. Money owed to somebody by name counts
--- as theirs: paid now or at their next login is the same outcome.
function Scheduler.moneySignature()
    local parts, cids, owed, held = {}, {}, {}, {}
    for cid in pairs(Scheduler.everyone) do cids[#cids + 1] = cid end
    table.sort(cids)
    for _, l in ipairs(rows('crimson_escrow')) do
        if l.state ~= CH.ESCROW_STATE.SETTLED then
            local amount = (tonumber(l.amount) or 0) - (tonumber(l.deliver_arrived) or 0)
            if l.owed_to and CH.MONEY_SOURCES[l.source] and Scheduler.everyone[l.owed_to] then
                owed[l.owed_to] = (owed[l.owed_to] or 0) + amount
            else
                held[#held + 1] = ('%s/%s/%s/ow=%s'):format(tostring(l.line_portion),
                    tostring(l.source), tostring(l.amount), tostring(l.owed_to))
            end
        end
    end
    for _, cid in ipairs(cids) do
        parts[#parts + 1] = ('%s=%d'):format(cid, purseOf(Scheduler.everyone[cid]) + (owed[cid] or 0))
    end
    table.sort(held)
    parts[#parts + 1] = table.concat(held, ';')
    for _, c in ipairs(rows('crimson_contracts')) do
        if c.bailout_queued_at then parts[#parts + 1] = 'bq=' .. tostring(c.bailout_paid_amount) end
    end
    return table.concat(parts, '\n')
end

--- The money and each contract: its state, slots, the buyout queue, the
--- lines on it nobody is owed by name, its active hitmen; and the open
--- review items.
function Scheduler.signature()
    local parts = { Scheduler.moneySignature() }
    local descs = {}
    for _, c in ipairs(rows('crimson_contracts')) do
        local here = { ('C:%s slot=%s/%s claimed=%s bq=%s'):format(tostring(c.state),
            tostring(c.next_slot), tostring(c.payout_slots), tostring(c.slots_claimed),
            tostring(c.bailout_queued_at ~= nil and c.bailout_paid_amount or nil)) }
        local lines = {}
        for _, l in ipairs(rows('crimson_escrow')) do
            if l.contract_id == c.id and l.state ~= CH.ESCROW_STATE.SETTLED
                and not (l.owed_to and CH.MONEY_SOURCES[l.source] and Scheduler.everyone[l.owed_to]) then
                lines[#lines + 1] = ('%s/%s/%s/%s/%s/st=%s/ow=%s'):format(tostring(l.line_portion),
                    tostring(l.source), tostring(l.amount), tostring(l.slot), tostring(l.state),
                    tostring(l.staker), tostring(l.owed_to))
            end
        end
        table.sort(lines)
        here[#here + 1] = '  [' .. table.concat(lines, ' ; ') .. ']'
        local hs = {}
        for _, h in ipairs(rows('crimson_hitmen')) do
            if h.contract_id == c.id and h.state == 'active' then hs[#hs + 1] = tostring(h.hitman_cid) end
        end
        table.sort(hs)
        here[#here + 1] = '  H{' .. table.concat(hs, ',') .. '}'
        descs[#descs + 1] = table.concat(here, '\n')
    end
    table.sort(descs)
    for _, d in ipairs(descs) do parts[#parts + 1] = d end
    local open = 0
    for _, r in ipairs(rows('crimson_review')) do
        if r.state == 'open' then open = open + 1 end
    end
    parts[#parts + 1] = 'reviews_open=' .. open
    return table.concat(parts, '\n')
end

--- What is left stuck once both handlers have finished.
---@return string[] problems
function Scheduler.stuck(m)
    local out = {}
    for _, l in ipairs(rows('crimson_escrow')) do
        if l.state == CH.ESCROW_STATE.RELEASING then
            out[#out + 1] = 'line ' .. tostring(l.id) .. ' left releasing'
        end
        if m.escrow.inFlight(l.id) then out[#out + 1] = 'line ' .. tostring(l.id) .. ' still in flight' end
    end
    for _, c in ipairs(rows('crimson_contracts')) do
        if c.state == CH.STATE.COMPLETING then
            out[#out + 1] = 'contract ' .. tostring(c.id) .. ' left completing'
        end
        if m.escrow.claimRunning(c.id) then
            out[#out + 1] = 'contract ' .. tostring(c.id) .. ' still counted claiming'
        end
        for _, key in ipairs({ 'contract:', 'settle:' }) do
            local free = m.contracts.serialized({ key .. tostring(c.id) }, function() return true end)
            if free ~= true then out[#out + 1] = 'key ' .. key .. tostring(c.id) .. ' still busy' end
        end
        -- Held on a closed contract and owed to nobody.
        if CH.TERMINAL[c.state] then
            for _, l in ipairs(rows('crimson_escrow')) do
                if l.contract_id == c.id and l.state ~= CH.ESCROW_STATE.SETTLED and not l.owed_to then
                    out[#out + 1] = ('stranded %s %s %s on %s contract'):format(tostring(l.id),
                        tostring(l.line_portion), tostring(l.amount), tostring(c.state))
                end
            end
        end
    end
    for cid in pairs(Scheduler.everyone) do
        local free = m.contracts.serialized({ 'hitman:' .. cid }, function() return true end)
        if free ~= true then out[#out + 1] = 'key hitman:' .. cid .. ' still busy' end
    end
    return out
end

--------------------------------------------------------------------------
-- Exploring a pairing
--------------------------------------------------------------------------

--- One serial order, from a fresh build.
local function serial(scn, order)
    local main, m, ctx = scn.build()
    local before = Scheduler.world()
    for _, which in ipairs(order) do
        local fn = which == 'A' and scn.first or scn.second
        Scheduler.race(nil, 'pre', function() return fn(m, ctx, main) end)
    end
    if scn.settle then scn.settle(m, ctx, main) end
    return Scheduler.signature(), Scheduler.world() - before, Scheduler.moneySignature()
end

--- Race a pairing at every await of A, before and after each, against
--- its four serial outcomes.
---
--- A scenario is { name, build() -> main, m, ctx; first(m, ctx, main);
--- second(m, ctx, main); settle(m, ctx, main) optional, run after both;
--- mints = true where money may legitimately appear }.
---@return table result { name, depth, runs, findings = { { k, phase, at, problems } } }
function Scheduler.explore(scn)
    local outcomes, moneyOutcomes = {}, {}
    for _, order in ipairs({ { 'A', 'B' }, { 'B', 'A' }, { 'A' }, { 'B' } }) do
        local sig, _, msig = serial(scn, order)
        outcomes[sig] = table.concat(order, ';')
        moneyOutcomes[msig] = table.concat(order, ';')
    end

    -- How many awaits A makes alone.
    local main0, m0, ctx0 = scn.build()
    local depth = Scheduler.race(nil, 'pre', function() return scn.first(m0, ctx0, main0) end).depth
    local statements = {}
    for i = 1, depth do statements[i] = S.statements[i] end

    local findings, runs = {}, 0
    for k = 1, depth do
        for _, phase in ipairs({ 'pre', 'post' }) do
            local main, m, ctx = scn.build()
            local before = Scheduler.world()
            local rec = Scheduler.race(k, phase,
                function() return scn.first(m, ctx, main) end,
                function() return scn.second(m, ctx, main) end)
            runs = runs + 1
            if scn.settle then scn.settle(m, ctx, main) end
            local problems = {}
            if rec.aError then problems[#problems + 1] = 'A raised: ' .. rec.aError end
            if rec.bError then problems[#problems + 1] = 'B raised: ' .. rec.bError end
            if rec.a and rec.a.raised then problems[#problems + 1] = 'A raised: ' .. rec.a.raised end
            if rec.b and rec.b.raised then problems[#problems + 1] = 'B raised: ' .. rec.b.raised end
            local delta = Scheduler.world() - before
            if delta ~= 0 and not scn.mints then
                problems[#problems + 1] = ('money not conserved: %+d'):format(delta)
            end
            if not moneyOutcomes[Scheduler.moneySignature()] then
                problems[#problems + 1] = 'MONEY matches no serial order'
            elseif not outcomes[Scheduler.signature()] then
                problems[#problems + 1] = 'state (not money) matches no serial order'
            end
            for _, s in ipairs(Scheduler.stuck(m)) do problems[#problems + 1] = s end
            if #problems > 0 then
                findings[#findings + 1] = { k = k, phase = phase, at = rec.firedAt or statements[k],
                    problems = problems, a = rec.a, b = rec.b }
            end
        end
    end
    return { name = scn.name, depth = depth, runs = runs, findings = findings,
             statements = statements }
end

--- One line per finding, for a failure message.
function Scheduler.report(res)
    local out = { ('%s: %d awaits, %d runs, %d with problems'):format(res.name, res.depth,
        res.runs, #res.findings) }
    for i, f in ipairs(res.findings) do
        if i > 6 then
            out[#out + 1] = ('... %d more'):format(#res.findings - 6)
            break
        end
        out[#out + 1] = ('#%d %s [%s]: %s'):format(f.k, f.phase, tostring(f.at),
            table.concat(f.problems, '; '))
    end
    return table.concat(out, '\n')
end

return Scheduler
