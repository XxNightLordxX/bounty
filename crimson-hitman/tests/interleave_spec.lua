--- Two people acting on the same contract at the same moment.
---
--- The scripted race tests pick a moment somebody chose: run this far, then
--- let the other thing happen, then continue. This forces the switch at
--- every point instead — the store is wrapped so that the Nth call it
--- receives is the instant the second actor runs, and N is walked from one
--- to the end.
---
--- What is asserted is not who wins. Which of two simultaneous actions
--- succeeds is a policy question with a different answer per pair. What
--- holds for every interleaving is that exactly one of them takes effect,
--- the loser leaves nothing behind, and no money is created or destroyed.

local function purse(src)
    local p = Env.players[src]
    if not p then return 0 end
    local dirty = 0
    for _, e in ipairs(p._inventory or {}) do
        if e.name == Config.Sources.dirty.item then dirty = dirty + (e.count or 0) end
    end
    return (p.PlayerData.money.cash or 0) + (p.PlayerData.money.bank or 0) + dirty
end

--- Every unit in the world: pockets, escrow, and a buyout that has been
--- paid but not yet settled.
---
--- That last one is the reason this is written out again rather than
--- borrowed. A buyout charges the target immediately and, where a hitman is
--- already engaged, queues the settlement on the contract rather than in
--- escrow — so for the length of that window the money is in neither a
--- pocket nor an escrow line. It is not lost: the settlement pays it out
--- and the fields survive a restart. But an accounting that only knows
--- about pockets and escrow reports twelve thousand destroyed, which is
--- what this test did at three interleavings before the window was
--- counted.
local function world(s)
    local total = 0
    for _, c in ipairs(s.storage.allContracts()) do
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if CH.MONEY_SOURCES[line.source]
                and line.state ~= CH.ESCROW_STATE.SETTLED then
                total = total + (line.amount or 0)
            end
        end
        if c.bailout_paid_amount and not CH.TERMINAL[c.state] then
            total = total + c.bailout_paid_amount
        end
    end
    for src in pairs(Env.players) do total = total + purse(src) end
    return total
end

--- Run `first`, and at its Nth store call, run `second` to completion.
---
--- The store is the seam because every state change in this resource goes
--- through it, so counting its calls counts the points at which another
--- player's action could land.
local function interleaveAt(s, n, first, second)
    local calls, fired = 0, false

    --- Reads as well as writes.
    ---
    --- The interesting moment is usually between the two: an operation
    --- reads a contract, decides what to do, and writes — and the classic
    --- way two players collide is for the second to land in that gap, so
    --- the first acts on a state that is no longer true. Watching writes
    --- alone gave one switch point for an accept, which is no race at all.
    local WATCH = {
        'compareSetContractState', 'claimEscrowLine', 'settleEscrowLine',
        'writeContract', 'writeEscrow', 'addHitman', 'updateHitman',
        'setEscrowAmount', 'advanceSlot',
        'readContract', 'readEscrow', 'readHitmen', 'readEscrowLine',
    }
    local real = {}

    for _, name in ipairs(WATCH) do
        real[name] = s.storage[name]
        s.storage[name] = function(...)
            calls = calls + 1
            if calls == n and not fired then
                fired = true
                -- The other actor runs here, re-entrantly, exactly as a
                -- second player's event would arrive mid-operation.
                pcall(second)
            end
            return real[name](...)
        end
    end

    local ok, err = pcall(first)

    for _, name in ipairs(WATCH) do s.storage[name] = real[name] end
    return ok, err, calls, fired
end

local function seeded(opts)
    opts = opts or {}
    local s = newStack()
    local f = fixture(s)
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt',
        mode = opts.mode or CH.MODE.EXCLUSIVE,
        reward = { baseline = { cash = 5000 } },
        bailoutAmount = opts.bailout,
    })
    return s, f, c
end

--- Every pairing worth racing, as a description plus two actions.
local function pairings()
    return {
        {
            what = 'cancelling while a hitman accepts',
            build = function() return seeded() end,
            first = function(s, f, c) return s.contracts.cancel(f.creator, c.id) end,
            second = function(s, f, c) return s.contracts.accept(f.hitman, c.id, false) end,
        },
        {
            what = 'two hitmen accepting an exclusive contract',
            build = function()
                local s, f, c = seeded()
                Env.addPlayer({ source = 4, citizenid = 'HITMAN02',
                    license = 'license:ddd', cash = 5000, bank = 5000,
                    firstname = 'Sol', lastname = 'Vane' })
                return s, f, c
            end,
            first = function(s, f, c) return s.contracts.accept(f.hitman, c.id, false) end,
            second = function(s, f, c)
                return s.contracts.accept(s.identity.resolve(4), c.id, false)
            end,
        },
        {
            what = 'buying out while a hitman accepts',
            build = function() return seeded({ bailout = 12000 }) end,
            first = function(s, f, c) return s.bailout.buy(f.target, c.id) end,
            second = function(s, f, c) return s.contracts.accept(f.hitman, c.id, false) end,
        },
        {
            -- One of two lines, not both: emptying a funded slot is refused
            -- outright, so withdrawing everything raced nothing.
            what = 'withdrawing part of a reward while a hitman accepts',
            build = function()
                local s = newStack()
                local f = fixture(s)
                local c = s.contracts.create(f.creator, {
                    targetCid = 'TARGET01', reason = 'Unpaid debt',
                    mode = CH.MODE.EXCLUSIVE,
                    reward = { slots = { { baseline = { cash = 5000, bank = 2000 } } } },
                })
                return s, f, c
            end,
            first = function(s, f, c)
                for _, line in ipairs(s.storage.readEscrow(c.id)) do
                    if line.source == 'bank' then
                        return s.contracts.withdrawReward(f.creator, c.id, { line.id })
                    end
                end
            end,
            second = function(s, f, c) return s.contracts.accept(f.hitman, c.id, false) end,
        },
        {
            -- Through claimSlot, which is how a payout actually happens.
            -- Contracts.resolve cannot take a contract straight from
            -- accepted to completed — the state machine routes it through
            -- completing — so calling it directly was refused as locked
            -- after a single store read, and raced nothing at all.
            what = 'paying out while the contract is cancelled',
            build = function()
                local s, f, c = seeded({ mode = CH.MODE.COMPETITIVE })
                s.contracts.accept(f.hitman, c.id, false)
                return s, f, c
            end,
            first = function(s, f, c)
                return s.contracts.claimSlot(c.id, 'HITMAN01', 'elimination')
            end,
            second = function(s, f, c) return s.contracts.cancel(f.creator, c.id) end,
        },
        {
            what = 'the same payout claimed twice',
            build = function()
                local s, f, c = seeded({ mode = CH.MODE.COMPETITIVE })
                s.contracts.accept(f.hitman, c.id, false)
                return s, f, c
            end,
            first = function(s, f, c)
                return s.contracts.claimSlot(c.id, 'HITMAN01', 'elimination')
            end,
            second = function(s, f, c)
                return s.contracts.claimSlot(c.id, 'HITMAN01', 'elimination')
            end,
        },
    }
end

describe('two actions landing on the same contract at once', function()
    --- How many store calls the first action makes when nothing interrupts
    --- it, measured rather than assumed.
    ---
    --- A fixed depth was worse than useless here: operations make between
    --- one and seven store calls, so a depth of twelve meant fifty-eight of
    --- seventy-two runs never reached the switch point at all and asserted
    --- against a sequence where nothing raced. Every n below is a point the
    --- second actor really lands on.
    local function depthOf(pair)
        local s, f, c = pair.build()
        if not c then return 0 end
        local _, _, calls = interleaveAt(s, math.huge,
            function() pair.first(s, f, c) end, function() end)
        return calls
    end

    it('never mints or destroys money, at any interleaving', function()
        local broken, tried = {}, 0

        for _, pair in ipairs(pairings()) do
            local depth = depthOf(pair)
            truthy(depth > 1,
                pair.what .. ' makes ' .. depth .. ' store calls, so there is '
                .. 'no point inside it for anything to race')

            for n = 1, depth do
                local s, f, c = pair.build()
                if c then
                    tried = tried + 1
                    local before = world(s)
                    local _, _, _, fired = interleaveAt(s, n,
                        function() pair.first(s, f, c) end,
                        function() pair.second(s, f, c) end)
                    truthy(fired,
                        ('%s never reached store call %d, so nothing raced')
                            :format(pair.what, n))
                    local after = world(s)
                    if after ~= before then
                        broken[#broken + 1] = ('%s, switching at store call %d: %+d')
                            :format(pair.what, n, after - before)
                    end
                end
            end
        end

        truthy(tried >= 20,
            'only ' .. tried .. ' interleavings ran, which is the loop having '
            .. 'stopped rather than the resource having shrunk')
        eq(#broken, 0,
            ('%d of %d interleavings moved money:\n  %s'):format(#broken, tried,
                table.concat(broken, '\n  ', 1, math.min(#broken, 6))))
    end)

    --- A contract cannot be both closed and open, and cannot be closed
    --- twice with two different reasons: whichever action wins, the other
    --- has to find the door shut.
    it('leaves the contract in exactly one state, at any interleaving', function()
        local broken, tried = {}, 0

        for _, pair in ipairs(pairings()) do
            for n = 1, depthOf(pair) do
                local s, f, c = pair.build()
                if c then
                    tried = tried + 1
                    interleaveAt(s, n,
                        function() pair.first(s, f, c) end,
                        function() pair.second(s, f, c) end)

                    local contract = s.storage.readContract(c.id)
                    if contract then
                        local legal = false
                        for _, state in pairs(CH.STATE) do
                            if contract.state == state then legal = true end
                        end
                        if not legal then
                            broken[#broken + 1] = ('%s at %d left state %s')
                                :format(pair.what, n, tostring(contract.state))
                        end

                        -- Nothing may still be mid-release once both
                        -- actions have finished: that is a settle that
                        -- stopped halfway.
                        for _, line in ipairs(s.storage.readEscrow(c.id)) do
                            if line.state == CH.ESCROW_STATE.RELEASING then
                                broken[#broken + 1] = ('%s at %d left %s mid-release')
                                    :format(pair.what, n, tostring(line.id))
                            end
                        end
                    end
                end
            end
        end

        eq(#broken, 0,
            ('%d of %d interleavings left the contract wrong:\n  %s'):format(
                #broken, tried, table.concat(broken, '\n  ', 1, math.min(#broken, 6))))
    end)

    --- An exclusive contract has one hitman however many people press
    --- accept at the same instant.
    it('never gives an exclusive contract two hitmen', function()
        local broken = {}
        local pair = pairings()[2]

        for n = 1, depthOf(pair) do
            local s, f, c = pair.build()
            if c then
                interleaveAt(s, n,
                    function() pair.first(s, f, c) end,
                    function() pair.second(s, f, c) end)

                local active = 0
                for _, h in ipairs(s.storage.readHitmen(c.id) or {}) do
                    if h.state == 'active' then active = active + 1 end
                end
                if active > 1 then
                    broken[#broken + 1] = ('switching at store call %d left %d hitmen')
                        :format(n, active)
                end
            end
        end

        eq(#broken, 0,
            'an exclusive contract took more than one hitman:\n  '
            .. table.concat(broken, '\n  '))
    end)
end)

--- The same question asked where it is real: on mysql, with every database
--- await a yield (tests/harness/await_scheduler.lua). The store-call seam
--- above runs the second actor re-entrantly from inside a store call;
--- these let it land while the first one waits on the database, before a
--- statement or after it and before its answer, as two net events do.
describe('the await scheduler', function()
    local Scheduler = require('crimson-hitman.tests.harness.await_scheduler')

    --- One hitman accepting two contracts at once, allowed one at a time:
    --- the two acceptances share no contract, so the hitman: key is all
    --- that keeps them apart.
    local function oneHitmanTwoContracts()
        return {
            name = 'accept x accept, one hitman, two contracts',
            build = function()
                local main, m = Scheduler.boot(function()
                    Config.Limits.MaxAcceptedPerHitman = 1
                end)
                local f = Scheduler.fixture(m)
                local function place()
                    local c, err = m.contracts.create(f.creator, {
                        targetCid = 'TARGET01', reason = 'Unpaid debt',
                        mode = CH.MODE.COMPETITIVE,
                        reward = { baseline = { cash = 5000 } }, penaltyAmount = 1000,
                    })
                    assert(c, 'create refused: ' .. tostring(err))
                    return c
                end
                return main, m, { f = f, one = place(), two = place() }
            end,
            first = function(m, x) return m.contracts.accept(x.f.hitman, x.one.id, false) end,
            second = function(m, x) return m.contracts.accept(x.f.hitman, x.two.id, false) end,
        }
    end

    it('finds every interleaving of a serialized pairing at every await serial', function()
        local res = Scheduler.explore(oneHitmanTwoContracts())
        truthy(res.depth >= 3, 'an acceptance waits on the database more than this: ' .. res.depth)
        eq(res.runs, 2 * res.depth, 'before and after every await')
        eq(#res.findings, 0, Scheduler.report(res))
    end)

    it('fails the oracle once the hitman key is taken out of the acceptance', function()
        local scn = oneHitmanTwoContracts()
        local build = scn.build
        scn.build = function()
            local main, m, x = build()
            local real = m.contracts.serialized
            m.contracts.serialized = function(keys, fn, ...)
                local kept = {}
                for _, key in ipairs(keys) do
                    if not key:find('^hitman:') then kept[#kept + 1] = key end
                end
                return real(kept, fn, ...)
            end
            return main, m, x
        end
        local res = Scheduler.explore(scn)
        truthy(#res.findings > 0,
            'two acceptances by one hitman overlapped and the oracle saw nothing: '
            .. Scheduler.report(res))
        local said = Scheduler.report(res)
        truthy(said:find('matches no serial order', 1, true), said)
    end)
end)

--- The money paths raced against each other at every await, on mysql with
--- every database await a yield (tests/harness/await_scheduler.lua): two
--- buyouts, two purchases of informant data, two creates on one target,
--- an abandon against each ending, an acceptance against a buyout, and the
--- two staff writes of the admin panel. Each must end as one of its serial
--- orders, money and state, with nothing left held.
describe('the same races at every await on mysql', function()
    local Scheduler = require('crimson-hitman.tests.harness.await_scheduler')

    --- A request as the page sends it.
    local function tap(name, src, rid, payload)
        payload.__rid = rid
        _G.source = src
        Env.events['crimson-hitman:' .. name](payload)
        _G.source = nil
        return true
    end

    --- A fresh server, its people, and a contract on TARGET01.
    local function seeded(opts, configure, bootOpts)
        local main, m = Scheduler.boot(configure, bootOpts)
        local f = Scheduler.fixture(m)
        local c, err = m.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = opts.mode or CH.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 5000 } },
            penaltyAmount = opts.penalty, bailoutAmount = opts.bailout,
        })
        assert(c, 'create refused: ' .. tostring(err))
        if opts.accepted then assert(m.contracts.accept(f.hitman, c.id, false)) end
        return main, m, { f = f, c = c }
    end

    --- The request buckets as shipped, with the raced one raised to 2 from
    --- the admin panel, as staff may: the rate limiter is not what keeps
    --- the two apart.
    local function raised(m, key)
        local answer = m.panel.handle(6, { op = 'setSetting', data = { key = key, value = 2 } })
        assert(answer and answer.ok, 'the panel raised ' .. key .. ': '
            .. tostring(answer and answer.message))
    end

    local function another(m, x, who)
        return m.contracts.create(who, {
            targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 5000 } },
        })
    end

    local function abandonAgainst(name, build, second)
        return {
            name = name, build = build,
            first = function(m, x) return m.contracts.abandon(x.f.hitman, x.c.id) end,
            second = second,
        }
    end

    local staked = { penalty = 1000, accepted = true }

    local function scenarios()
        return {
            {
                name = 'buyout x buyout, queued, through the app',
                build = function()
                    local main, m, x = seeded({ bailout = 12000, penalty = 1000, accepted = true },
                        nil, { realLimits = true })
                    raised(m, 'Cooldowns.bailout.burst')
                    return main, m, x
                end,
                first = function(_, x) return tap('bailout', 2, 901, { id = x.c.id }) end,
                second = function(_, x) return tap('bailout', 2, 902, { id = x.c.id }) end,
            },
            {
                name = 'buyout x buyout, instant, through the app',
                build = function()
                    local main, m, x = seeded({ bailout = 12000 }, nil, { realLimits = true })
                    raised(m, 'Cooldowns.bailout.burst')
                    return main, m, x
                end,
                first = function(_, x) return tap('bailout', 2, 903, { id = x.c.id }) end,
                second = function(_, x) return tap('bailout', 2, 904, { id = x.c.id }) end,
            },
            {
                -- The fee is a sink: it leaves the world, once.
                name = 'informant x informant, through the app',
                mints = true,
                build = function()
                    local main, m, x = seeded({ accepted = true }, nil, { realLimits = true })
                    raised(m, 'Cooldowns.informant.burst')
                    Env.players[2].PlayerData.money.bank = 100000
                    m.death.watchTargets(m.storage.allContracts())
                    return main, m, x
                end,
                first = function(_, x) return tap('informant', 2, 905, { id = x.c.id }) end,
                second = function(_, x) return tap('informant', 2, 906, { id = x.c.id }) end,
            },
            {
                -- The target already carries one of the two it may.
                name = 'create x create, one target with room for one more',
                build = function() return seeded({}) end,
                first = function(m, x) return another(m, x, x.f.hitman) end,
                second = function(m, x) return another(m, x, x.f.hitman2) end,
            },
            abandonAgainst('abandon x claim', function() return seeded(staked) end,
                function(m, x)
                    return m.contracts.claimSlot(x.c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
                end),
            abandonAgainst('abandon x staff void', function() return seeded(staked) end,
                function(m, x) return m.admin.void(0, x.c.id, 'staff void') end),
            -- The stake is the client's in every serial order: forfeited at
            -- the abandon, or at the expiry. An expiry landing between the
            -- abandon's row and its release gave it back to the walker.
            abandonAgainst('abandon x expire', function()
                local main, m, x = seeded(staked)
                Env.advance(x.c.deadline_at - os.time() + 5)
                return main, m, x
            end, function(_, _, main)
                main.markContractsChanged()
                return main.expire()
            end),
            abandonAgainst('abandon x buyout settle', function()
                local main, m, x = seeded({ bailout = 12000, penalty = 1000, accepted = true })
                assert(m.bailout.buy(x.f.target, x.c.id))
                Env.advance(Config.Bailout.ProcessingDelaySeconds + 1)
                return main, m, x
            end, function(m) return m.bailout.processQueue() end),
            {
                name = 'accept x buyout',
                build = function() return seeded({ bailout = 12000, penalty = 1000 }) end,
                first = function(m, x) return m.contracts.accept(x.f.hitman, x.c.id, false) end,
                second = function(m, x) return m.bailout.buy(x.f.target, x.c.id) end,
            },
            {
                name = 'buyout x accept, instant',
                build = function() return seeded({ bailout = 12000, penalty = 1000 }) end,
                first = function(m, x) return m.bailout.buy(x.f.target, x.c.id) end,
                second = function(m, x) return m.contracts.accept(x.f.hitman, x.c.id, false) end,
            },
            {
                name = 'setSetting x setSetting, from the admin panel',
                build = function()
                    local main, m = Scheduler.boot()
                    Scheduler.fixture(m)
                    return main, m, {}
                end,
                first = function(m)
                    return m.panel.handle(6, { op = 'setSetting',
                        data = { key = 'Cooldowns.bailout.burst', value = 3 } })
                end,
                second = function(m)
                    return m.panel.handle(6, { op = 'setSetting',
                        data = { key = 'Cooldowns.bailout.burst', value = 4 } })
                end,
                -- What is in force and what the store keeps, which must agree.
                extra = function()
                    local stored
                    for _, row in ipairs(Scheduler.rows('crimson_settings')) do
                        if row.setting_key == 'Cooldowns.bailout.burst' then stored = row.setting_value end
                    end
                    return tostring(Config.Cooldowns.bailout.burst) .. '/' .. tostring(stored)
                end,
            },
            {
                -- Staff refunds out of nothing the resource holds: money
                -- appears, once.
                name = 'review resolve x review resolve, from the admin panel',
                mints = true,
                build = function()
                    local main, m = Scheduler.boot()
                    Scheduler.fixture(m)
                    local id = m.review.open({ kind = 'bailout_refund_stranded',
                        contract_id = 'ct00000001', cids = { payer = 'TARGET01' },
                        amount = 5000, account = 'bank' })
                    return main, m, { id = id }
                end,
                first = function(m, x)
                    return m.panel.handle(6, { op = 'resolve', data = { id = x.id,
                        action = 'refund', who = 'payer', amount = 5000 } })
                end,
                second = function(m, x)
                    return m.panel.handle(6, { op = 'resolve', data = { id = x.id,
                        action = 'refund', who = 'payer', amount = 5000 } })
                end,
            },
        }
    end

    for _, scn in ipairs(scenarios()) do
        it(scn.name .. ' ends as a serial order at every await', function()
            local res = Scheduler.explore(scn)
            truthy(res.depth >= 2, scn.name .. ' waits on the database more than this: ' .. res.depth)
            eq(#res.findings, 0, Scheduler.report(res))
        end)
    end

    --- The oracle is not vacuous: with the contract's key taken out of the
    --- buy, a hitman staking inside the buy's awaits is bought out from
    --- under, instantly, holding a row on a closed contract.
    it('fails the oracle once the contract key is taken out of the buyout', function()
        local scn
        for _, s in ipairs(scenarios()) do
            if s.name == 'buyout x accept, instant' then scn = s end
        end
        local build = scn.build
        scn.build = function()
            local main, m, x = build()
            local real = m.contracts.serialized
            m.contracts.serialized = function(keys, fn, ...)
                local buying = false
                for _, key in ipairs(keys) do
                    if key:find('^settle:') then buying = true end
                end
                if not buying then return real(keys, fn, ...) end
                local kept = {}
                for _, key in ipairs(keys) do
                    if not key:find('^contract:') then kept[#kept + 1] = key end
                end
                return real(kept, fn, ...)
            end
            return main, m, x
        end
        local res = Scheduler.explore(scn)
        local said = Scheduler.report(res)
        truthy(#res.findings > 0, 'a buyout and an acceptance overlapped unseen: ' .. said)
        truthy(said:find('matches no serial order', 1, true), said)
    end)
end)
