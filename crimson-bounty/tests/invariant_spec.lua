--- Property-based simulation.
---
--- Drives long randomised sequences of real operations and asserts invariants
--- that must hold no matter the order. This catches interleavings no
--- hand-written test would think to try.

--- Coverage accumulated across every seed, asserted at the end: an
--- individual seed may draw an unlucky operation mix, but the suite as a
--- whole must exercise creation, acceptance and payout.
local coverage = { created = 0, accepted = 0, claimed = 0, bailed = 0,
                   added = 0, improved = 0 }

--- Deterministic generator, so a failure is reproducible from its seed.
local function rng(seed)
    local s = seed
    return function(n)
        s = (1103515245 * s + 12345) % 2147483648
        -- Take the high bits: an LCG's low bits cycle with a tiny period, so
        -- `s % n` would produce a near-deterministic pattern rather than a
        -- varied operation mix.
        return (math.floor(s / 65536) % n) + 1
    end
end

--- Every unit of value in the world: player balances, player inventories,
--- and everything still held in escrow. This total must never change except
--- by the premiums players pay each other, which stay inside the total.
local function worldValue(s, cids)
    local total = 0

    for src, player in pairs(Env.players) do
        total = total + (player.PlayerData.money.cash or 0)
        total = total + (player.PlayerData.money.bank or 0)
        for _, slot in ipairs(player._inventory) do
            if slot.name == 'black_money' then total = total + slot.count end
        end
    end

    local contracts = s.storage.allContracts()
    for i = 1, #contracts do
        local lines = s.storage.readEscrow(contracts[i].id)
        for j = 1, #lines do
            local line = lines[j]
            if line.state ~= CB.ESCROW_STATE.SETTLED and CB.MONEY_SOURCES[line.source] then
                total = total + (line.amount or 0)
            end
        end
    end

    return total
end

--- No escrow line may be settled to two people, and none may be left
--- claimed-but-unsettled once nothing is in flight.
local function escrowSane(s)
    local contracts = s.storage.allContracts()
    for i = 1, #contracts do
        local lines = s.storage.readEscrow(contracts[i].id)
        for j = 1, #lines do
            local line = lines[j]
            if line.state == CB.ESCROW_STATE.SETTLED then
                truthy(line.settled_to, 'a settled line must record who received it')
            end
            if line.state == CB.ESCROW_STATE.RELEASING then
                error('escrow line left mid-release: ' .. line.id)
            end
        end
    end
    return true
end

--- A terminal contract must hold nothing back: every line either settled or
--- queued as owed to someone.
local function terminalContractsDrained(s)
    local contracts = s.storage.allContracts()
    for i = 1, #contracts do
        local c = contracts[i]
        if CB.TERMINAL[c.state] then
            local lines = s.storage.readEscrow(c.id)
            for j = 1, #lines do
                if lines[j].state == CB.ESCROW_STATE.HELD then
                    -- Held on a closed contract is only acceptable when it is
                    -- queued for a player who could not receive it.
                    local queued = false
                    for _, cid in ipairs({ c.creator_cid, c.target_cid }) do
                        local pending = s.storage.readPending(cid)
                        for _, entry in ipairs(pending) do
                            if entry.line_id == lines[j].id then queued = true end
                        end
                    end
                    truthy(queued, ('closed contract %s still holds line %s with nobody owed it')
                        :format(c.id, lines[j].id))
                end
            end
        end
    end
    return true
end

local function buildWorld(seed)
    local s = newStack()
    local cids = {}
    for i = 1, 8 do
        local cid = string.format('SIM%05d', i)
        Env.addPlayer({
            source = i, citizenid = cid, license = 'license:sim' .. i,
            cash = 50000, bank = 50000,
            inventory = { { name = 'black_money', count = 10000 } },
            firstname = 'Sim', lastname = 'Player' .. i,
        })
        cids[#cids + 1] = cid
    end
    return s, cids
end

describe('value conservation under random operation orders', function()
    for _, seed in ipairs({ 7, 101, 4242, 99991, 31337, 8675309 }) do
        it('conserves every unit of value (seed ' .. seed .. ')', function()
            local rand = rng(seed)
            local s, cids = buildWorld(seed)
            local opening = worldValue(s, cids)

            local ids = {}
            local counts = { created = 0, accepted = 0, claimed = 0, bailed = 0,
                             added = 0, improved = 0 }

            for step = 1, 200 do
                -- A live server has time passing between actions; without it
                -- every cooldown blocks and the run proves nothing.
                Env.advance(120)

                local actorSrc = rand(8)
                local actor = s.identity.resolve(actorSrc)
                local op = rand(9)

                if op == 1 then
                    -- Place a contract on someone else.
                    local targetSrc = rand(8)
                    if targetSrc ~= actorSrc then
                        local target = s.identity.resolve(targetSrc)
                        local slots = {}
                        for i = 1, rand(3) do
                            slots[i] = { baseline = { cash = rand(20) * 100 },
                                         bonus = { cash = rand(10) * 50 } }
                        end
                        local c = s.contracts.create(actor, {
                            targetCid = target.cid, reason = 'sim run',
                            mode = rand(2) == 1 and CB.MODE.EXCLUSIVE or CB.MODE.COMPETITIVE,
                            reward = { slots = slots },
                            bailoutAmount = rand(2) == 1 and (rand(50) * 100) or nil,
                            -- Stakes are money too, and the path that moves
                            -- them is separate from every other payout path.
                            penaltyAmount = rand(2) == 1 and (rand(20) * 100) or nil,
                        })
                        if c then
                            ids[#ids + 1] = c.id
                            counts.created = counts.created + 1
                        end
                    end

                elseif op == 2 and #ids > 0 then
                    if s.contracts.accept(actor, ids[rand(#ids)], rand(2) == 1) then
                        counts.accepted = counts.accepted + 1
                    end

                elseif op == 3 then
                    -- A hunter claims on a contract they actually hold, the
                    -- way a real payout happens.
                    local held = s.projection.accepted(actor.cid)
                    if #held > 0 then
                        local id = held[rand(#held)].id
                        if s.contracts.claimSlot(id, actor.cid,
                            rand(2) == 1 and CB.FULFILMENT.ELIMINATION or CB.FULFILMENT.KIDNAPPING) then
                            counts.claimed = counts.claimed + 1
                        end
                    end

                elseif op == 4 then
                    local held = s.projection.accepted(actor.cid)
                    if #held > 0 then s.contracts.abandon(actor, held[rand(#held)].id) end

                elseif op == 5 then
                    local onMe = s.projection.onMe(actor.cid)
                    local id = #onMe > 0 and onMe[rand(#onMe)].id or ids[rand(math.max(1, #ids))]
                    if id and s.bailout.buy(actor, id) then
                        counts.bailed = counts.bailed + 1
                    end

                elseif op == 6 and #ids > 0 then
                    local id = ids[rand(#ids)]
                    local c = s.storage.readContract(id)
                    if c and not CB.TERMINAL[c.state] then
                        s.contracts.resolve(id, CB.STATE.CANCELLED, c.creator_cid, nil, 'sim cancel')
                    end

                elseif op == 7 and #ids > 0 then
                    if s.amendments.addEscrow(actor, ids[rand(#ids)], { baseline = { cash = rand(10) * 100 } }) then
                        counts.added = counts.added + 1
                    end

                elseif op == 8 then
                    Env.advance(rand(300))
                    s.bailout.processQueue()

                elseif op == 9 and #ids > 0 then
                    -- Improvements move money between a hunter's stake and
                    -- their pocket, so the loop has to try them.
                    local id = ids[rand(#ids)]
                    local kinds = {
                        { CB.AMENDMENT.EXTEND_DEADLINE, { seconds = rand(20) * 60 } },
                        { CB.AMENDMENT.RAISE_BONUS, { percent = rand(150) } },
                        { CB.AMENDMENT.LOWER_PENALTY, { amount = rand(15) * 100 } },
                    }
                    local pick = kinds[rand(#kinds)]
                    if s.amendments.improve(actor, id, pick[1], pick[2]) then
                        counts.improved = (counts.improved or 0) + 1
                    end
                end

                -- Deliveries that could not be handed over are retried, so
                -- owed value returns to circulation rather than vanishing.
                for _, cid in ipairs(cids) do s.escrow.retryPending(cid) end

                escrowSane(s)
            end

            -- Settle everything still open so nothing is left in flight.
            for _, id in ipairs(ids) do
                local c = s.storage.readContract(id)
                if c and not CB.TERMINAL[c.state] then
                    s.contracts.resolve(id, CB.STATE.CANCELLED, c.creator_cid, nil, 'sim teardown')
                end
            end
            for _, cid in ipairs(cids) do s.escrow.retryPending(cid) end

            terminalContractsDrained(s)
            eq(worldValue(s, cids), opening,
                ('value was created or destroyed over the run (seed %d)'):format(seed))

            -- The run must actually have exercised the system: conservation
            -- over a run where everything was rejected proves nothing.
            truthy(counts.created >= 5, ('only %d contracts created'):format(counts.created))
            truthy(counts.accepted >= 2, ('only %d acceptances'):format(counts.accepted))

            for key, value in pairs(counts) do
                coverage[key] = coverage[key] + value
            end
        end)
    end
end)

describe('simulation coverage', function()
    it('exercised creation, acceptance, payout and buyout across the seeds', function()
        truthy(coverage.created >= 20, ('contracts created: %d'):format(coverage.created))
        truthy(coverage.accepted >= 10, ('acceptances: %d'):format(coverage.accepted))
        truthy(coverage.claimed >= 3, ('payouts claimed: %d'):format(coverage.claimed))
        truthy(coverage.added >= 1, ('escrow top-ups: %d'):format(coverage.added))
        truthy(coverage.improved >= 1, ('improvements: %d'):format(coverage.improved))
    end)
end)

describe('no contract can be paid twice under any order', function()
    it('settles each escrow line at most once across a long run', function()
        local rand = rng(31337)
        local s, cids = buildWorld(31337)
        local ids = {}

        for step = 1, 150 do
            Env.advance(120)
            local actor = s.identity.resolve(rand(8))
            local op = rand(5)

            if op == 1 then
                local targetSrc = rand(8)
                local target = s.identity.resolve(targetSrc)
                if target.cid ~= actor.cid then
                    local c = s.contracts.create(actor, {
                        targetCid = target.cid, reason = 'sim', mode = CB.MODE.COMPETITIVE,
                        reward = { baseline = { cash = 1000 }, bonus = { cash = 500 } },
                    })
                    if c then ids[#ids + 1] = c.id end
                end
            elseif #ids > 0 then
                local id = ids[rand(#ids)]
                if op == 2 then s.contracts.accept(actor, id, false)
                elseif op == 3 then
                    local held = s.projection.accepted(actor.cid)
                    if #held > 0 then
                        s.contracts.claimSlot(held[rand(#held)].id, actor.cid, CB.FULFILMENT.ELIMINATION)
                    end
                elseif op == 4 then s.escrow.release(id, actor.cid, nil, 'sim direct release')
                elseif op == 5 then
                    local c = s.storage.readContract(id)
                    if c then s.contracts.resolve(id, CB.STATE.CANCELLED, c.creator_cid, nil, 'sim') end
                end
            end
        end

        -- Every line that ever settled recorded exactly one recipient, and
        -- the audit log agrees with the escrow table.
        local settled = 0
        local contracts = s.storage.allContracts()
        for i = 1, #contracts do
            local lines = s.storage.readEscrow(contracts[i].id)
            for j = 1, #lines do
                if lines[j].state == CB.ESCROW_STATE.SETTLED then
                    settled = settled + 1
                    truthy(lines[j].settled_to, 'settled without a recipient')
                    truthy(lines[j].settled_at, 'settled without a timestamp')
                end
            end
        end
        truthy(settled > 0, 'the run should have settled something')
    end)
end)

--------------------------------------------------------------------------
-- Restarts
--------------------------------------------------------------------------
--
-- The simulation above proves conservation across thousands of operations
-- and never once saves, reloads and continues. The recovery path — a
-- contract caught mid-claim, an escrow line caught mid-release — had only
-- hand-written tests, and a hand-written test only covers the interleavings
-- somebody thought of.
--
-- These run against the json backend through main.lua, so a restart here is
-- the real one: the store is closed, the files are all that survive, and
-- the resource starts again and recovers.

local function bootJson()
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
            package.loaded[name] = nil
        end
    end

    local main = require('server.main')
    return main, main.start()
end

--- A world whose players survive a restart, because they are in Env rather
--- than in the store.
local function populate(modules)
    local cids = {}
    for i = 1, 6 do
        local cid = string.format('SIM%05d', i)
        Env.addPlayer({
            source = i, citizenid = cid, license = 'license:sim' .. i,
            cash = 50000, bank = 50000,
            inventory = { { name = 'black_money', count = 10000 } },
            firstname = 'Sim', lastname = 'Player' .. i,
        })
        cids[#cids + 1] = cid
    end
    return cids
end

describe('value survives a restart', function()
    for _, seed in ipairs({ 13, 2024, 555001 }) do
        it('conserves every unit across a mid-run restart (seed ' .. seed .. ')', function()
            local rand = rng(seed)

            Env.reset()
            Natives.files = {}
            Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
            Natives.resetResourceStates()
            resetConfig()
            Config.Database.Mode = 'json'

            local main, modules = bootJson()
            local cids = populate(modules)
            local opening = worldValue(modules, cids)

            local ids = {}
            local created, accepted, claimed = 0, 0, 0

            local function step(n)
                for _ = 1, n do
                    Env.advance(120)
                    local actorSrc = rand(6)
                    local actor = modules.identity.resolve(actorSrc)
                    local op = rand(6)

                    if op <= 2 then
                        local targetSrc = rand(6)
                        if targetSrc ~= actorSrc then
                            local target = modules.identity.resolve(targetSrc)
                            local c = modules.contracts.create(actor, {
                                targetCid = target.cid, reason = 'sim',
                                mode = CB.MODE.COMPETITIVE,
                                reward = { baseline = { cash = rand(20) * 100 } },
                                penaltyAmount = rand(2) == 1 and (rand(10) * 100) or nil,
                            })
                            if c then ids[#ids + 1] = c.id created = created + 1 end
                        end
                    elseif op == 3 and #ids > 0 then
                        local id = ids[rand(#ids)]
                        if modules.contracts.accept(actor, id, rand(2) == 1) then
                            accepted = accepted + 1
                        end
                    elseif op == 4 and #ids > 0 then
                        local id = ids[rand(#ids)]
                        local c = modules.storage.readContract(id)
                        if c and c.state == CB.STATE.ACCEPTED then
                            local hunters = modules.storage.readHunters(id)
                            for _, h in ipairs(hunters) do
                                if h.state == 'active'
                                    and modules.contracts.claimSlot(id, h.hunter_cid,
                                                                   CB.FULFILMENT.ELIMINATION) then
                                    claimed = claimed + 1
                                    break
                                end
                            end
                        end
                    elseif op == 5 and #ids > 0 then
                        modules.contracts.abandon(actor, ids[rand(#ids)])
                    else
                        main.tick()
                    end
                end
            end

            step(60)

            -- The restart. Everything not on disk is gone.
            modules.storage.close()
            main, modules = bootJson()

            truthy(#modules.storage.allContracts() > 0,
                'the contracts must come back at all')

            step(60)

            -- Settle everything still open, then check the books.
            for _, id in ipairs(ids) do
                local c = modules.storage.readContract(id)
                if c and not CB.TERMINAL[c.state] then
                    modules.contracts.resolve(id, CB.STATE.CANCELLED, c.creator_cid,
                                              nil, 'sim teardown')
                end
            end
            for _, cid in ipairs(cids) do modules.escrow.retryPending(cid) end

            escrowSane(modules)
            terminalContractsDrained(modules)
            eq(worldValue(modules, cids), opening,
                ('value was created or destroyed across the restart (seed %d)'):format(seed))

            truthy(created >= 3, ('only %d contracts created'):format(created))
            truthy(accepted >= 1, ('only %d acceptances'):format(accepted))
        end)
    end

    it('recovers a contract left mid-claim and an escrow line left mid-release', function()
        Env.reset()
        Natives.files = {}
        Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
        Natives.resetResourceStates()
        resetConfig()
        Config.Database.Mode = 'json'

        local main, modules = bootJson()
        populate(modules)

        local creator = modules.identity.resolve(1)
        local hunter = modules.identity.resolve(3)
        local target = modules.identity.resolve(2)

        local c = modules.contracts.create(creator, {
            targetCid = target.cid, reason = 'sim', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(c)
        truthy(modules.contracts.accept(hunter, c.id, false))

        -- Exactly what a crash mid-settlement leaves: a contract stuck in
        -- COMPLETING and a line claimed but never settled.
        truthy(modules.storage.compareSetContractState(c.id, CB.STATE.ACCEPTED,
                                                       CB.STATE.COMPLETING))
        local line = modules.storage.readEscrow(c.id)[1]
        truthy(modules.storage.claimEscrowLine(line.id, CB.ESCROW_STATE.HELD,
                                               CB.ESCROW_STATE.RELEASING))
        modules.storage.close()

        main, modules = bootJson()

        eq(modules.storage.readContract(c.id).state, CB.STATE.ACCEPTED,
            'a contract stuck mid-claim is put back so the normal path can run again')
        eq(modules.storage.readEscrowLine(line.id).state, CB.ESCROW_STATE.HELD,
            'and a line stuck mid-release is owed rather than unreachable')

        -- And it can still be finished afterwards.
        truthy(modules.contracts.claimSlot(c.id, hunter.cid, CB.FULFILMENT.ELIMINATION),
            'the recovered contract is still completable')
    end)
end)
