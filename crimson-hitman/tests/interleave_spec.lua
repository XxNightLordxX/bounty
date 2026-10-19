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
--- borrowed. A buyout charges the target immediately and, where a hunter is
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
            if CB.MONEY_SOURCES[line.source]
                and line.state ~= CB.ESCROW_STATE.SETTLED then
                total = total + (line.amount or 0)
            end
        end
        if c.bailout_paid_amount and not CB.TERMINAL[c.state] then
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
        'writeContract', 'writeEscrow', 'addHunter', 'updateHunter',
        'setEscrowAmount', 'advanceSlot',
        'readContract', 'readEscrow', 'readHunters', 'readEscrowLine',
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
        mode = opts.mode or CB.MODE.EXCLUSIVE,
        reward = { baseline = { cash = 5000 } },
        bailoutAmount = opts.bailout,
    })
    return s, f, c
end

--- Every pairing worth racing, as a description plus two actions.
local function pairings()
    return {
        {
            what = 'cancelling while a hunter accepts',
            build = function() return seeded() end,
            first = function(s, f, c) return s.contracts.cancel(f.creator, c.id) end,
            second = function(s, f, c) return s.contracts.accept(f.hunter, c.id, false) end,
        },
        {
            what = 'two hunters accepting an exclusive contract',
            build = function()
                local s, f, c = seeded()
                Env.addPlayer({ source = 4, citizenid = 'HUNTER02',
                    license = 'license:ddd', cash = 5000, bank = 5000,
                    firstname = 'Sol', lastname = 'Vane' })
                return s, f, c
            end,
            first = function(s, f, c) return s.contracts.accept(f.hunter, c.id, false) end,
            second = function(s, f, c)
                return s.contracts.accept(s.identity.resolve(4), c.id, false)
            end,
        },
        {
            what = 'buying out while a hunter accepts',
            build = function() return seeded({ bailout = 12000 }) end,
            first = function(s, f, c) return s.bailout.buy(f.target, c.id) end,
            second = function(s, f, c) return s.contracts.accept(f.hunter, c.id, false) end,
        },
        {
            -- One of two lines, not both: emptying a funded slot is refused
            -- outright, so withdrawing everything raced nothing.
            what = 'withdrawing part of a reward while a hunter accepts',
            build = function()
                local s = newStack()
                local f = fixture(s)
                local c = s.contracts.create(f.creator, {
                    targetCid = 'TARGET01', reason = 'Unpaid debt',
                    mode = CB.MODE.EXCLUSIVE,
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
            second = function(s, f, c) return s.contracts.accept(f.hunter, c.id, false) end,
        },
        {
            -- Through claimSlot, which is how a payout actually happens.
            -- Contracts.resolve cannot take a contract straight from
            -- accepted to completed — the state machine routes it through
            -- completing — so calling it directly was refused as locked
            -- after a single store read, and raced nothing at all.
            what = 'paying out while the contract is cancelled',
            build = function()
                local s, f, c = seeded({ mode = CB.MODE.COMPETITIVE })
                s.contracts.accept(f.hunter, c.id, false)
                return s, f, c
            end,
            first = function(s, f, c)
                return s.contracts.claimSlot(c.id, 'HUNTER01', 'elimination')
            end,
            second = function(s, f, c) return s.contracts.cancel(f.creator, c.id) end,
        },
        {
            what = 'the same payout claimed twice',
            build = function()
                local s, f, c = seeded({ mode = CB.MODE.COMPETITIVE })
                s.contracts.accept(f.hunter, c.id, false)
                return s, f, c
            end,
            first = function(s, f, c)
                return s.contracts.claimSlot(c.id, 'HUNTER01', 'elimination')
            end,
            second = function(s, f, c)
                return s.contracts.claimSlot(c.id, 'HUNTER01', 'elimination')
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
                        for _, state in pairs(CB.STATE) do
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
                            if line.state == CB.ESCROW_STATE.RELEASING then
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

    --- An exclusive contract has one hunter however many people press
    --- accept at the same instant.
    it('never gives an exclusive contract two hunters', function()
        local broken = {}
        local pair = pairings()[2]

        for n = 1, depthOf(pair) do
            local s, f, c = pair.build()
            if c then
                interleaveAt(s, n,
                    function() pair.first(s, f, c) end,
                    function() pair.second(s, f, c) end)

                local active = 0
                for _, h in ipairs(s.storage.readHunters(c.id) or {}) do
                    if h.state == 'active' then active = active + 1 end
                end
                if active > 1 then
                    broken[#broken + 1] = ('switching at store call %d left %d hunters')
                        :format(n, active)
                end
            end
        end

        eq(#broken, 0,
            'an exclusive contract took more than one hunter:\n  '
            .. table.concat(broken, '\n  '))
    end)
end)
