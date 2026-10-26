--- What a busy board costs, counted in store calls.
---
--- Several things in this resource walk the whole contract table: the board
--- projection, the death sampler, the expiry pass, the bailout queue. Every
--- one of them is on a path a player or a tick triggers, and on the mysql
--- backend every store call in the list below is a separate awaited query —
--- `readEscrow` is one `SELECT ... WHERE contract_id = ?` per call, and it
--- yields. So the number of store calls an operation makes is not a proxy
--- for its cost on a live server; it *is* its cost.
---
--- These tests therefore count calls rather than time. A wall-clock
--- threshold is a coin toss on a loaded CI box — it fails when the machine
--- is busy and passes when a genuine O(n^2) regression lands on a quiet one.
--- A call count is the same number on every machine.
---
--- The claims made here, all of them measured at ten contracts and again at
--- five hundred:
---
---   * opening the board reads exactly one hitman roster per row it shows,
---     never one per contract on the server;
---   * it reads escrow once per contract it has to price, and a fixed
---     handful per row it renders — so the whole-board cost is linear with
---     slope one, not a scan inside a scan;
---   * a player's own tabs (mine / accepted / onMe) never read the whole
---     contract table at all;
---   * the once-a-second death sampler touches no escrow and no contract
---     rows, only one hitman roster per live contract;
---   * the maintenance tick's whole-table scans are a small constant,
---     whatever is on the board.
---
--- Two things are measured here and deliberately NOT asserted as bounded,
--- because they are not:
---
---   * The board's escrow reads grow one-for-one with the number of
---     contracts visible on it — 70 reads at 10 contracts, 190 at 100, 590
---     at 500, of which only 90 are for the fifteen rows actually shown.
---     That falls out of sorting the board by reward: the sort has to know
---     every reward. It is a straight line rather than a curve, and the
---     test below pins the slope at one so it cannot quietly become two.
---
---   * Bailout.available — the /cleanse command's list of contracts a
---     player may buy out — reads the whole contract table (bailout.lua:52)
---     and filters on target_cid in Lua, when Storage.contractsNaming(cid)
---     answers exactly that question against an index. Projection.onMe asks
---     the same question the indexed way. Asserting zero scans there would
---     fail today, so this spec measures it and says so rather than
---     pretending otherwise.

--------------------------------------------------------------------------
-- Counting harness
--------------------------------------------------------------------------

--- Wrap every function on the store in place, counting calls.
---
--- In place, on the table the modules are already holding, because they each
--- kept their own reference at init(). Handing back a fresh table would count
--- nothing: escrow, contracts, projection and the rest would carry on talking
--- to the store behind the counter's back.
---@param storage table
---@return table counts, function restore, function reset
local function countingStore(storage)
    local counts, originals = {}, {}
    for name, fn in pairs(storage) do
        if type(fn) == 'function' then
            originals[name] = fn
            counts[name] = 0
            storage[name] = function(...)
                counts[name] = counts[name] + 1
                return fn(...)
            end
        end
    end
    return counts,
        function() for name, fn in pairs(originals) do storage[name] = fn end end,
        function() for name in pairs(counts) do counts[name] = 0 end end
end

--- The limits that stop the fixture below being refused.
---
--- A creator may hold three contracts and a target may carry two, which is
--- the right rule for a server and the wrong one for a scale fixture: five
--- hundred contracts would otherwise need two hundred and fifty players.
--- Raising the caps here is not testing a different program — nothing under
--- test reads them — it is the only way to get five hundred rows into the
--- store through the front door rather than by writing them by hand.
local function scaleLimits()
    return {
        { Config.Limits, 'MaxActiveContractsPerCreator', 10000 },
        { Config.Limits, 'MaxActiveContractsPerTarget', 10000 },
        { Config.Limits, 'SameCreatorSameTargetCooldownSeconds', 0 },
        -- Fixture players connect at the harness clock's fixed instant, so
        -- every one of them is inside the new-arrival window.
        { Config.Immunity, 'MinTargetSessionMinutes', 0 },
        { Config.Immunity, 'MinTargetPlaytimeHours', 0 },
    }
end

--- Put `n` live contracts on the board, every one of them created through
--- the real path so the escrow, the hitman rows and the audit trail are the
--- ones a live server would have.
---
--- Two money sources and a derived kidnapping bonus, which is four escrow
--- lines per contract: five hundred contracts is two thousand lines.
---@return table { creators, targets, made, players }
local function loadBoard(stack, n)
    -- Enough people that neither the creator cap nor the target cap is what
    -- the fixture is really measuring, and few enough that the board is a
    -- board rather than a phone book.
    local players = math.max(4, math.ceil(n / 40))
    local creators, targets = {}, {}

    for i = 1, players do
        Env.addPlayer({ source = 1000 + i, citizenid = ('CRE%05d'):format(i),
            license = ('license:cre%d'):format(i),
            cash = 90000000, bank = 90000000 })
        creators[i] = stack.identity.resolve(1000 + i)
        Env.addPlayer({ source = 2000 + i, citizenid = ('TGT%05d'):format(i),
            license = ('license:tgt%d'):format(i), cash = 100, bank = 100 })
        targets[i] = stack.identity.resolve(2000 + i)
    end

    local made = 0
    for i = 1, n do
        local contract = stack.contracts.create(creators[(i % players) + 1], {
            targetCid = targets[((i + 1) % players) + 1].cid,
            reason = 'scale',
            reward = { baseline = { cash = 100, bank = 100 } },
            bonusPercent = 50,
            bailoutAmount = 300,
        })
        if contract then made = made + 1 end
    end

    return { creators = creators, targets = targets, made = made, players = players }
end

--- Open a stack, load it to `n` contracts, and hand both to `fn` with the
--- store counting.
---
--- newStack() resets the whole configuration, so it is opened BEFORE
--- withConfig rather than inside it — otherwise the raised limits would be
--- put back before a single contract was created and the fixture would stop
--- at three.
local function atScale(n, fn)
    local stack = newStack()
    withConfig(scaleLimits(), function()
        local board = loadBoard(stack, n)
        eq(board.made, n, 'the fixture must actually reach the scale it claims')
        local counts, restore, reset = countingStore(stack.storage)
        local ok, err = pcall(fn, stack, board, counts, reset)
        restore()
        if not ok then error(err, 0) end
    end)
end

local PAGE = 15   -- Config.Listing.PageSize as it ships; asserted below.

describe('complexity: opening the board', function()
    it('ships the page size these measurements assume', function()
        newStack()
        eq(Config.Listing.PageSize, PAGE,
            'the counts below are stated in pages of this size')
    end)

    --- The one that matters most, because it is the one a refactor breaks
    --- without changing a single byte of output: projecting every visible
    --- contract and slicing the page out afterwards returns exactly the same
    --- listing, and costs a hitman-roster read per contract on the server
    --- instead of per row on the screen.
    it('reads one hitman roster per row shown, not one per contract', function()
        local small, big
        atScale(10, function(stack, board, counts, reset)
            reset()
            local listing = stack.projection.listing(board.creators[1].cid, 1)
            small = { rows = #listing.contracts, hitmen = counts.readHitmen,
                      hitman = counts.readHitman, escrow = counts.readEscrow,
                      pages = listing.pages }
        end)
        atScale(500, function(stack, board, counts, reset)
            reset()
            local listing = stack.projection.listing(board.creators[1].cid, 1)
            big = { rows = #listing.contracts, hitmen = counts.readHitmen,
                    hitman = counts.readHitman, escrow = counts.readEscrow,
                    pages = listing.pages }
        end)

        eq(small.rows, 10, 'ten contracts fit on one page')
        eq(big.rows, PAGE, 'five hundred do not')

        eq(small.hitmen, small.rows,
            'one roster read per row at ten contracts')
        eq(big.hitmen, big.rows,
            ('one roster read per row at five hundred contracts, got %d for %d rows '
             .. '— the board is projecting contracts it will not show')
            :format(big.hitmen, big.rows))

        -- The role lookup is per row too, and skipped on the viewer's own
        -- contracts, so it can only ever be smaller.
        truthy(big.hitman <= big.rows,
            ('one role lookup per row at most, got %d for %d rows'):format(big.hitman, big.rows))
    end)

    --- The scan itself. Sorting by reward means pricing every contract that
    --- is visible, which is one escrow read each — a straight line. What must
    --- never happen is a second read per contract inside that pass, which is
    --- how a linear board becomes a quadratic one on the backend where every
    --- read is a query.
    it('prices each visible contract exactly once', function()
        local mid, big
        local function open(n, into)
            atScale(n, function(stack, board, counts, reset)
                reset()
                local listing = stack.projection.listing(board.creators[1].cid, 1)
                into[1] = { visible = board.made, rows = #listing.contracts,
                            escrow = counts.readEscrow, all = counts.allContracts,
                            live = counts.liveContracts }
            end)
            return into[1]
        end

        mid = open(100, {})
        big = open(500, {})

        eq(mid.rows, PAGE, 'both scales show a full page')
        eq(big.rows, PAGE, 'both scales show a full page')

        -- Same page, four hundred more contracts to price: four hundred more
        -- escrow reads and not one more than that.
        eq(big.escrow - mid.escrow, big.visible - mid.visible,
            ('the board must read escrow once per contract it prices: %d extra '
             .. 'contracts cost %d extra reads')
            :format(big.visible - mid.visible, big.escrow - mid.escrow))

        -- And the per-row constant is a constant.
        --
        -- It used to be six — baseline money, bonus money, baseline goods,
        -- bonus goods, and the two by-source breakdowns, each a separate
        -- read of the same rows. Projection.listing memoises escrow for the
        -- length of the call now, so a row costs none beyond the one read
        -- that priced it. The ceiling is left where it was rather than
        -- pinned at zero: this test is here to catch a row that starts
        -- costing more, and ceilings_spec pins the exact count.
        local perRow = (big.escrow - big.visible) / big.rows
        truthy(perRow <= 8,
            ('each rendered row costs a fixed handful of escrow reads, got %.1f')
            :format(perRow))

        eq(big.live, 1, 'and the live contracts are read once, not once a page')
        eq(big.all, 0, 'and never the whole table, finished contracts and all')
    end)

    --- A weak secondary check, and labelled as one. It exists to catch the
    --- kind of change that turns a tenth of a second into a minute, not to
    --- police a few milliseconds — a number tight enough to be interesting
    --- is a number that flakes on a busy machine.
    it('opens a five-hundred contract board inside a sane wall clock', function()
        -- The ceiling moves with the instrumentation rather than the test
        -- skipping itself.
        --
        -- A line hook multiplies every wall clock in the process by around a
        -- hundred, so a fixed ceiling turns "somebody is measuring coverage"
        -- into a red suite — which is how a run of the coverage report ended
        -- with one failure that was not a failure. Skipping under a hook
        -- would report as a pass, which is how a check quietly stops
        -- existing; a looser ceiling still catches the tenth-of-a-second
        -- into a minute this is here for.
        local ceiling = debug.gethook() and 60.0 or 2.0

        atScale(500, function(stack, board, counts, reset)
            local started = os.clock()
            stack.projection.listing(board.creators[1].cid, 1)
            local elapsed = os.clock() - started
            truthy(elapsed < ceiling,
                ('opening the board took %.3fs against a ceiling of %.1fs; '
                 .. 'the shape of this is wrong'):format(elapsed, ceiling))
        end)
    end)
end)

describe('complexity: a player looking at their own contracts', function()
    --- These three used to fetch every contract and filter in Lua, which the
    --- comments in projection.lua call out as a full table scan per app
    --- request. Opening the app fires all three at once, so a regression here
    --- is three full scans per player per refresh.
    it('never reads the whole contract table', function()
        atScale(500, function(stack, board, counts, reset)
            local viewerCreator = board.creators[1].cid
            local viewerTarget  = board.targets[1].cid

            reset()
            stack.projection.mine(viewerCreator)
            eq(counts.allContracts, 0, 'the creator tab must not scan the board')
            eq(counts.contractsBy, 1, 'it asks for its own contracts, once')

            reset()
            stack.projection.accepted(viewerCreator)
            eq(counts.allContracts, 0, 'the hitman tab must not scan the board')
            eq(counts.contractsInvolving, 1, 'it asks for the ones it is in, once')

            reset()
            stack.projection.onMe(viewerTarget)
            eq(counts.allContracts, 0, 'the cleanse tab must not scan the board')
            eq(counts.contractsNaming, 1, 'it asks for the ones naming it, once')
        end)
    end)

    --- The point of the indexed lookups: what these cost has to be set by
    --- how many contracts the player is in, not by how many exist. Same
    --- player, same handful of contracts, ten on the board and then five
    --- hundred.
    it('costs the same whether ten contracts exist or five hundred', function()
        local function costOfMine(n)
            local out
            atScale(n, function(stack, board, counts, reset)
                -- One creator, so this player owns every contract at n = 10
                -- and the fixture's share of them at n = 500. What is
                -- compared is the cost PER contract they own, which is what
                -- the board size must not move.
                local own = #stack.storage.contractsBy(board.creators[1].cid)
                reset()
                local mine = stack.projection.mine(board.creators[1].cid)
                out = { own = own, rows = #mine, escrow = counts.readEscrow,
                        hitmen = counts.readHitmen }
            end)
            return out
        end

        local small, big = costOfMine(10), costOfMine(500)
        truthy(small.rows > 0 and big.rows > 0, 'both viewers hold contracts')

        eq(small.escrow / small.rows, big.escrow / big.rows,
            'the escrow reads per contract shown must not move with the board')
        eq(small.hitmen / small.rows, big.hitmen / big.rows,
            'nor the roster reads')
    end)
end)

describe('complexity: the tick and the sampler', function()
    --- The condition sampler runs on its own clock, once a second, over
    --- every live contract. One hitman roster each is what it needs; an
    --- escrow read or a contract re-read in that loop would be a query per
    --- contract per second for the life of the server.
    it('samples conditions without touching escrow or re-reading contracts', function()
        atScale(500, function(stack, board, counts, reset)
            local contracts = stack.storage.allContracts()
            reset()
            local watched = stack.death.watchTargets(contracts)

            eq(watched, board.made, 'every live contract is sampled')
            eq(counts.readHitmen, board.made, 'one roster per live contract')
            eq(counts.readEscrow, 0,
                'the sampler must never price a contract — it runs every second')
            eq(counts.readContract, 0,
                'nor re-read a row it was handed')
            eq(counts.allContracts, 0, 'it is given the list, it does not fetch one')
        end)
    end)

    --- The maintenance tick runs every ten seconds forever. Whatever it does
    --- per contract is paid per contract per ten seconds, so the number of
    --- whole-table scans it makes must be set by the job list, not by the
    --- board.
    it('makes the same number of whole-table scans at ten contracts and at five hundred', function()
        local function scans(n)
            local first, second
            atScale(n, function(stack, board, counts, reset)
                -- The tick lives in main.lua and is wired there; the suite's
                -- own stack does not own it. Running the jobs the tick runs
                -- against the loaded store is the same measurement without
                -- booting a second resource.
                reset()
                stack.bailout.processQueue()
                stack.amendments.expire()
                stack.death.sweep()
                stack.ratelimit.sweep()
                stack.ledger.forgetOldPhotos()
                first = counts.allContracts

                reset()
                stack.bailout.processQueue()
                stack.amendments.expire()
                stack.death.sweep()
                stack.ratelimit.sweep()
                stack.ledger.forgetOldPhotos()
                second = counts.allContracts
            end)
            return first, second
        end

        local smallFirst, smallSecond = scans(10)
        local bigFirst, bigSecond = scans(500)

        eq(bigFirst, smallFirst,
            ('the tick scanned the table %d times at 500 contracts and %d at 10')
            :format(bigFirst, smallFirst))
        eq(bigSecond, smallSecond, 'and the same again on the next tick')

        -- A budget, not a description: between them these jobs may walk the
        -- contract table once. Today exactly one of them does — the bailout
        -- queue, which reads the whole table looking for the queued-buyout
        -- flag. The other scanner in the real tick is the expiry pass, which
        -- skips itself when neither the clock nor anyone's presence has
        -- moved; boot_spec owns that one.
        truthy(bigFirst <= 1,
            ('the ten-second jobs may walk the contract table once between '
             .. 'them, not %d times'):format(bigFirst))
    end)

    --- The amendment expiry keeps its own index of contracts with open
    --- proposals, so a board with none costs it nothing. Without that index
    --- it is a scan plus a per-contract amendment read, every ten seconds.
    it('expires amendments without walking the board', function()
        atScale(500, function(stack, board, counts, reset)
            reset()
            stack.amendments.expire()
            eq(counts.allContracts, 0,
                'nothing has an open proposal, so nothing should be read')
            eq(counts.readOpenAmendments, 0, 'and no proposal read per contract')
        end)
    end)
end)

--------------------------------------------------------------------------
-- What a kill payout writes, in json mode
--------------------------------------------------------------------------

--- json mode ships as the default, and every money write there is a file
--- written before the handler returns, on the main thread. The ledger,
--- pending payouts, stats, reveals and kill photo records were fields of
--- store.json, and every money write rewrote store.json whole: a claim
--- wrote it twelve times, and the ledger in it grows with every character
--- ever party to a finished contract. Counted here in files written, which
--- is the same number on every machine.
describe('json mode: what a kill payout writes', function()
    local function boot()
        for name in pairs(package.loaded) do
            if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
                package.loaded[name] = nil
            end
        end
        Env.reset()
        Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
        Natives.resetResourceStates()
        resetConfig()
        Config.Database.Mode = 'json'
        Natives.files = {}
        local main = require('server.main')
        return main.start()
    end

    --- One contract placed, taken and paid on a server whose ledger already
    --- holds `history` characters' rows. Returns what each step wrote.
    local function payout(history)
        local s = boot()
        local f = fixture(s)
        for p = 1, history do
            s.storage.writeLedger({ cid = ('PAST%04d'):format(p), contract_id = 'ctpast',
                role = 'creator', target_name = 'Somebody Else', reason = 'history',
                resolved_at = 1 })
        end
        s.storage.save(true)

        local steps, current = {}, nil
        Natives.saveFile = function(file, data)
            -- A whole file is written as <file>.new and renamed over it.
            file = file:gsub('%.new$', '')
            local step = steps[current]
            step[file] = step[file] or { writes = 0, bytes = 0 }
            step[file].writes = step[file].writes + 1
            step[file].bytes = step[file].bytes + #data
        end
        local ok, err = pcall(function()
            current = 'create'; steps.create = {}
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
                reward = { slots = { { baseline = { cash = 1000, bank = 2000 } } } },
            })
            truthy(c, 'a contract')
            current = 'accept'; steps.accept = {}
            truthy(s.contracts.accept(f.hitman, c.id), 'taken')
            current = 'claim'; steps.claim = {}
            truthy(s.contracts.claimSlot(c.id, f.hitman.cid, CH.FULFILMENT.ELIMINATION, {}),
                'and paid')
        end)
        Natives.saveFile = nil
        if not ok then error(err, 0) end
        return steps
    end

    local function writes(step, file) return step[file] and step[file].writes or 0 end
    local function bytes(step, file) return step[file] and step[file].bytes or 0 end

    it('rewrites the records at most twice per payout, and the index not once', function()
        local steps = payout(50)
        truthy(writes(steps.claim, 'data/records.json') <= 2,
            ('a claim wrote records.json %d times'):format(writes(steps.claim, 'data/records.json')))
        eq(writes(steps.claim, 'data/store.json'), 0,
            'a claim names no new contract and mints no id the index has to hold')
        truthy(writes(steps.accept, 'data/store.json') <= 1, 'an acceptance at most once')
        truthy(writes(steps.create, 'data/store.json') <= 2, 'and a new contract at most twice')
    end)

    it('writes an index whose size does not grow with the ledger', function()
        local small = payout(5)
        local big = payout(400)
        eq(bytes(big.create, 'data/store.json'), bytes(small.create, 'data/store.json'),
            'what placing a contract writes to the index is the same with 5 characters in the '
            .. 'ledger and with 400')
        eq(bytes(big.claim, 'data/store.json'), 0, 'and a payout writes none of it')
    end)
end)

--------------------------------------------------------------------------
-- Framework lookups, row walks and round trips
--------------------------------------------------------------------------

--- Count every export call by resource and method. Calls go through the
--- global `exports` on every use, so standing a counter in front of it sees
--- all of them.
local function countingExports()
    local real = _G.exports
    local counts = {}
    _G.exports = setmetatable({}, { __index = function(_, resource)
        local inner = real[resource]
        return setmetatable({}, { __index = function(_, method)
            local fn = inner[method]
            return function(...)
                local key = resource .. '.' .. method
                counts[key] = (counts[key] or 0) + 1
                return fn(...)
            end
        end })
    end })
    return counts, function() _G.exports = real end
end

--- Count the steps of every `pairs` walk: the rows a lookup touches.
local function countingPairs()
    local real = _G.pairs
    local steps = 0
    _G.pairs = function(t)
        local f, s, k = real(t)
        return function(tt, kk)
            steps = steps + 1
            return f(tt, kk)
        end, s, k
    end
    return function() return steps end, function() _G.pairs = real end
end

--- The sampler's own loop, one pass at a time: the body startSampler runs
--- every ConditionSampleMs, fetch and all, not watchTargets handed a list.
local function samplerOf(stack)
    stack.death.startSampler()
    local thread = coroutine.wrap(Env.threads[#Env.threads])
    local realWait = _G.Wait
    local function step()
        _G.Wait = coroutine.yield
        local ok, err = pcall(thread)
        _G.Wait = realWait
        if not ok then error(err, 0) end
    end
    step()   -- to its first wait
    return step
end

describe('complexity: what the sampler asks for', function()
    --- The whole contract table holds every finished contract the retention
    --- keeps. On mysql that was SELECT * of all of it, once a second.
    it('reads the running contracts once a pass, never the whole table', function()
        atScale(100, function(stack, board, counts, reset)
            local pass = samplerOf(stack)
            reset()
            pass()
            eq(counts.liveContracts, 1, 'one read of the running contracts a pass')
            eq(counts.allContracts, 0, 'and none of every contract kept')
            -- Every roster in one read too: one each was 1 + N awaited
            -- queries a second on mysql, for as long as the server ran.
            eq(counts.liveHitmen, 1, 'one read of every running contract\'s hitmen')
            eq(counts.readHitmen or 0, 0, 'and no roster read per contract')
            reset()
            pass()
            eq(counts.liveContracts, 1, 'and the same the next second')
        end)
    end)

    --- The death state was read twice per target per pass: once for the
    --- revive watch, once more for isTrulyDead, with nothing in between.
    it('reads each target\'s death state once a pass', function()
        atScale(20, function(stack, board)
            local exportCounts, restore = countingExports()
            local ok, err = pcall(stack.death.watchTargets, stack.storage.liveContracts())
            restore()
            truthy(ok, tostring(err))
            eq(exportCounts['sc-ambulance.IsDead'], board.made, 'one dead read per contract')
            eq(exportCounts['sc-ambulance.IsLaststand'], board.made, 'and one last-stand read')
        end)
    end)
end)

describe('complexity: a party who has logged off', function()
    --- Contracts live up to two days with their clock paused while the
    --- target is away, so a contract on somebody offline is the ordinary
    --- state. Each lookup of them asked qbx_core for every online player, one
    --- export each, carrying that player's whole record: the sampler did it
    --- every second, and every board open and expiry pass again.
    local function offlineCost(online)
        local stack = newStack()
        local out
        withConfig(scaleLimits(), function()
            local board = loadBoard(stack, 12)
            -- A server that has been running: its sampler has looked its
            -- targets up while they were here.
            stack.death.watchTargets(stack.storage.liveContracts())
            for i = 1, board.players do Env.removePlayer(2000 + i) end
            for i = 1, online do
                Env.addPlayer({ source = 5000 + i, citizenid = ('CROWD%04d'):format(i),
                    license = ('license:crowd%d'):format(i), cash = 0, bank = 0 })
            end
            local exportCounts, restore = countingExports()
            local ok, err = pcall(function()
                local function lookups()
                    local n = (exportCounts['qbx_core.GetPlayer'] or 0)
                        + (exportCounts['qbx_core.GetPlayerByCitizenId'] or 0)
                    for key in pairs(exportCounts) do exportCounts[key] = 0 end
                    return n
                end
                lookups()
                stack.death.watchTargets(stack.storage.liveContracts())
                out = { sampler = lookups() }
                stack.projection.listing(board.creators[1].cid, 1)
                out.board = lookups()
                stack.contracts.releaseIdleHolds()
                out.holds = lookups()
                out.offline = stack.identity.byCitizenId('TGT00001')
            end)
            restore()
            if not ok then error(err, 0) end
        end)
        return out
    end

    it('costs the same framework lookups with 10 players online or 150', function()
        local few, many = offlineCost(10), offlineCost(150)
        eq(many.offline, nil, 'they are offline, and found to be')
        eq(many.sampler, few.sampler,
            ('a sampler pass made %d lookups with 150 online and %d with 10')
            :format(many.sampler, few.sampler))
        eq(many.board, few.board,
            ('a board open made %d lookups with 150 online and %d with 10')
            :format(many.board, few.board))
        eq(many.holds, few.holds, 'and so does the idle-hold sweep')
        truthy(many.sampler <= 12 * 2,
            ('one or two lookups per contract, not one per player online: %d'):format(many.sampler))
    end)

    it('still finds somebody when the lookup export does not work on this build', function()
        local stack = newStack()
        fixture(stack)
        local realExports = _G.exports
        _G.exports = setmetatable({}, { __index = function(_, resource)
            local inner = realExports[resource]
            if resource ~= 'qbx_core' then return inner end
            return setmetatable({}, { __index = function(_, method)
                if method == 'GetPlayerByCitizenId' then
                    -- Answers, but never with anybody: a build whose export
                    -- does not take a citizen id this way.
                    return function() return nil end
                end
                return inner[method]
            end })
        end })
        local found = stack.identity.byCitizenId('TARGET01')
        _G.exports = realExports
        truthy(found, 'never seen to work, its nil is not trusted: the scan still runs')
        eq(found.cid, 'TARGET01')
    end)
end)

describe('complexity: what the sampler asks qbx_core for', function()
    --- Every live contract's target and every active hitman on it, once a
    --- second. The sampler asked qbx_core for each one's whole player record
    --- (GetPlayerByCitizenId) only to read the server id out of it, and with
    --- no medical resource answering it asked again (GetPlayer) for two
    --- flags in the metadata. The bridges already keep who is in the city as
    --- whom; the flags can be asked for by name.
    ---@param n integer contracts, each with its own target and one hitman on it
    ---@param opts table|nil { away = targets who have left, hitmenAway = hitmen
    ---   who have left, noMedical = no medical resource running, crowd =
    ---   bystanders online, late = a target in the city the map never heard log in }
    local function sampled(n, opts)
        opts = opts or {}
        local stack = newStack()
        local out
        withConfig(scaleLimits(), function()
            Env.addPlayer({ source = 900, citizenid = 'CLIENT01', license = 'license:client',
                cash = 90000000, bank = 90000000 })
            local creator = stack.identity.resolve(900)
            for i = 1, n do
                Env.addPlayer({ source = 2000 + i, citizenid = ('TGT%05d'):format(i),
                    license = ('license:tgt%d'):format(i) })
                Env.addPlayer({ source = 3000 + i, citizenid = ('HIT%05d'):format(i),
                    license = ('license:hit%d'):format(i) })
                local c = stack.contracts.create(creator, { targetCid = ('TGT%05d'):format(i),
                    reason = 'scale', reward = { baseline = { cash = 100 } } })
                truthy(c, 'contract ' .. i .. ' placed')
                truthy(stack.contracts.accept(stack.identity.resolve(3000 + i), c.id, false),
                    'and taken')
            end
            for i = 1, opts.crowd or 0 do
                Env.addPlayer({ source = 5000 + i, citizenid = ('CROWD%04d'):format(i),
                    license = ('license:crowd%d'):format(i) })
            end
            stack.bridges.install(stack)

            -- A disconnect, the way FXServer reports one.
            local function drop(src)
                _G.source = src
                local ok, err = pcall(Env.events['local:playerDropped'])
                _G.source = nil
                truthy(ok, tostring(err))
                Env.removePlayer(src)
            end
            for i = 1, opts.away or 0 do drop(2000 + i) end
            for i = 1, opts.hitmenAway or 0 do drop(3000 + n + 1 - i) end
            if opts.late then
                -- Logged in, and no login event reached the bridges.
                Env.removePlayer(2000 + n)
                drop(2000 + n)
                Env.addPlayer({ source = 4000, citizenid = ('TGT%05d'):format(n),
                    license = ('license:tgt%d'):format(n) })
            end
            if opts.noMedical then
                Natives.resourceStates['sc-ambulance'] = 'stopped'
                Natives.resourceStates['qbx_medical'] = 'missing'
            end

            local exportCounts, restore = countingExports()
            local ok, watched = pcall(stack.death.watchTargets,
                stack.storage.liveContracts(), stack.storage.liveHitmen())
            restore()
            truthy(ok, tostring(watched))

            local core = 0
            for key, count in pairs(exportCounts) do
                if key:sub(1, 9) == 'qbx_core.' then core = core + count end
            end
            out = {
                watched = watched, core = core,
                getPlayer = exportCounts['qbx_core.GetPlayer'] or 0,
                byCid = exportCounts['qbx_core.GetPlayerByCitizenId'] or 0,
                metadata = exportCounts['qbx_core.GetMetadata'] or 0,
            }
        end)
        return out
    end

    it('asks qbx_core nothing for parties in the city', function()
        local few, many = sampled(4), sampled(16, { crowd = 40 })
        eq(few.watched, 4, 'every target in the city is watched')
        eq(many.watched, 16)
        eq(few.core, 0, ('no framework export in a pass over 4 contracts, made %d'):format(few.core))
        eq(many.core, 0, ('nor over 16 with 40 more online, made %d'):format(many.core))
    end)

    it('reads the death state field by field when no medical resource answers', function()
        local out = sampled(6, { noMedical = true })
        eq(out.watched, 6)
        eq(out.getPlayer, 0, 'never the whole player record for two flags')
        eq(out.byCid, 0, 'nor to find a target the map already has')
        eq(out.metadata, 2 * 6, 'isdead and inlaststand, by name, for each target')
    end)

    it('asks one empty lookup for each party who has left, and carries no record', function()
        local out = sampled(8, { away = 3, hitmenAway = 2 })
        eq(out.watched, 5, 'the three away are not watched')
        eq(out.getPlayer, 0, 'no lookup that hands over a record')
        eq(out.byCid, 3 + 2, 'one lookup for each party the map does not have, answered nil')
        eq(out.core, 5, 'and nothing else')
    end)

    it('still watches a target in the city whose login the map never heard', function()
        local out = sampled(3, { late = true })
        eq(out.watched, 3, 'found through qbx_core\'s lookup, so no hit on them is missed')
        eq(out.byCid, 1, 'the one the map does not have')
    end)

    it('reads the whole record only from a qbx_core without the field export', function()
        local stack = newStack()
        Natives.noGetMetadata = true
        Natives.resourceStates['sc-ambulance'] = 'stopped'
        Env.addPlayer({ source = 7, citizenid = 'OLDCORE1', license = 'license:old' })
        Env.players[7].PlayerData.metadata.isdead = true
        local exportCounts, restore = countingExports()
        local ok, err = pcall(function()
            local dead, last, resolved, by = stack.identity.deathState(7)
            truthy(dead and resolved, 'still read, the old way')
            falsy(last)
            eq(by, 'metadata')
            stack.identity.deathState(7)
        end)
        restore()
        truthy(ok, tostring(err))
        eq(exportCounts['qbx_core.GetMetadata'] or 0, 2,
            'the missing export is asked once, then not again')
        eq(exportCounts['qbx_core.GetPlayer'] or 0, 2)
    end)
end)

describe('complexity: hits on players no contract names', function()
    --- Every hit between any two players went through attribution: both
    --- resolved, a death-state read, a 50 ms poll, and 'rejected' audit rows
    --- mirrored to the staff webhook.
    it('asks the framework nothing and logs nothing for them', function()
        local stack = newStack()
        Env.addPlayer({ source = 31, citizenid = 'GANG0001', license = 'license:g1' })
        Env.addPlayer({ source = 32, citizenid = 'GANG0002', license = 'license:g2' })
        local queued = stack.audit.pending()
        local exportCounts, restore = countingExports()
        local ok, err = pcall(function()
            for i = 1, 40 do
                Env.players[32]._health = 200 - i
                stack.death.recordDamage(31, 32, 123456)
                stack.death.recordDamage(32, 31, 123456)
            end
            Env.advance(5)
        end)
        restore()
        truthy(ok, tostring(err))
        eq(exportCounts['qbx_core.GetPlayer'] or 0, 0, 'no lookup of either player')
        eq(exportCounts['sc-ambulance.IsDead'] or 0, 0, 'no death-state read')
        eq(stack.audit.pending(), queued, 'and no audit row')
        eq(#Env.timers, 0, 'and no poll left running')
    end)

    --- Except somebody the server is watching come back from a death: a
    --- hit that cuts their revive short is what makes it a revive, and the
    --- protection after one is measured from it.
    it('still looks at a hit on somebody the server has seen dead', function()
        local stack = newStack()
        Env.addPlayer({ source = 31, citizenid = 'GANG0001', license = 'license:g1' })
        Env.addPlayer({ source = 32, citizenid = 'GANG0002', license = 'license:g2' })
        Env.players[32].PlayerData.metadata.isdead = true
        stack.death.onVictimReport(32)
        truthy(stack.death.wasSeenDead('GANG0002'))
        local before = stack.audit.pending()
        stack.death.recordDamage(31, 32, 123456)
        eq(stack.audit.pending(), before + 1,
            'looked at: its first hit sets the baseline it is measured from')
    end)

    --- And a target from the moment their contract is accepted, before the
    --- sampler's next pass has seen it.
    it('looks at a hit on a target the moment their contract is taken', function()
        local stack = newStack()
        local f = fixture(stack)
        local c = stack.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 1000 } } })
        truthy(stack.contracts.accept(f.hitman, c.id, false))
        Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
        Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
        Env.players[2]._health = 150
        stack.death.recordDamage(3, 2, 123456)
        truthy(stack.death.lastHit('HITMAN01', 'TARGET01'), 'the hit is on the record')
    end)
end)

describe('complexity: rows a lookup walks', function()
    --- readEscrow and readHitmen walked every row in the store for the one
    --- contract asked about; the board prices every contract with one, and
    --- recovery reads every contract kept.
    it('reads one contract\'s lines and roster in the same steps at 10 contracts or 500', function()
        local function walk(n)
            local out
            atScale(n, function(stack, board)
                local id = stack.storage.liveContracts()[1].id
                local steps, restore = countingPairs()
                local ok, err = pcall(function()
                    stack.storage.readEscrow(id)
                    out = { escrow = steps() }
                    stack.storage.readHitmen(id)
                    out.hitmen = steps() - out.escrow
                end)
                restore()
                if not ok then error(err, 0) end
            end)
            return out
        end
        local small, big = walk(10), walk(500)
        eq(big.escrow, small.escrow, 'an escrow read walks its own contract\'s lines only')
        eq(big.hitmen, small.hitmen, 'and a roster read its own contract\'s rows')
    end)

    --- The prune ran every tick and built its holding and owing sets over
    --- every escrow line and pending row before finding nothing was old
    --- enough, which in steady state is every tick.
    it('prunes nothing without walking escrow when nothing is old enough', function()
        atScale(200, function(stack, board)
            local steps, restore = countingPairs()
            local ok, err = pcall(stack.storage.prune)
            restore()
            truthy(ok, tostring(err))
            truthy(steps() <= board.made + 1,
                ('a prune with nothing due walked %d rows for %d contracts')
                :format(steps(), board.made))
        end)
    end)

    --- One handle per searcher and person shown, thirty minted per browse
    --- page, and minting walked every live handle to look for one.
    it('mints a target handle without walking the ones already live', function()
        local stack = newStack()
        for s = 1, 20 do
            for t = 1, 100 do
                stack.app.mintTargetHandle(('SEARCH%02d'):format(s), ('PERSON%03d'):format(t))
            end
        end
        local steps, restore = countingPairs()
        local again, fresh
        local ok, err = pcall(function()
            again = stack.app.mintTargetHandle('SEARCH01', 'PERSON001')
            fresh = stack.app.mintTargetHandle('SEARCH01', 'PERSON999')
        end)
        restore()
        truthy(ok, tostring(err))
        eq(steps(), 0, 'two thousand live handles, none walked')
        eq(stack.app.resolveTargetHandle('SEARCH01', again), 'PERSON001', 'the same handle again')
        eq(stack.app.resolveTargetHandle('SEARCH01', fresh), 'PERSON999')
        eq(stack.app.resolveTargetHandle('SEARCH02', again), nil, 'and only for its searcher')
        stack.app.clearPlayerHandles('SEARCH01')
        local after = stack.app.mintTargetHandle('SEARCH01', 'PERSON001')
        truthy(after ~= again, 'a searcher who left gets a new one')
        eq(stack.app.resolveTargetHandle('SEARCH01', again), nil)
    end)
end)

describe('complexity: a start', function()
    --- Recovery read escrow twice for every contract kept, and the amendment
    --- index asked each one for its open proposals: on mysql, some four
    --- awaited queries a contract before the app answered anybody.
    local function boot()
        for name in pairs(package.loaded) do
            if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
                package.loaded[name] = nil
            end
        end
        Env.reset()
        Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
        Natives.resetResourceStates()
        resetConfig()
        Config.Database.Mode = 'memory'
        local main = require('server.main')
        return main, main.start()
    end

    local function startCost(finished)
        local out
        local main, s = boot()
        withConfig(scaleLimits(), function()
            local f = fixture(s)
            for i = 1, finished do
                Env.addPlayer({ source = 100 + i, citizenid = ('GONE%04d'):format(i),
                    license = ('license:gone%d'):format(i), cash = 0, bank = 0 })
                local c, why = s.contracts.create(f.creator, { targetCid = ('GONE%04d'):format(i),
                    reason = 'x', reward = { baseline = { cash = 100 } } })
                truthy(c, 'contract ' .. i .. ': ' .. tostring(why))
                truthy(s.contracts.cancel(f.creator, c.id), 'cancelled ' .. i)
                -- Past the wait a creator who cancelled has before placing again.
                Env.time = Env.time + 3600
            end
            local live = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
                reward = { baseline = { cash = 100 } } })
            truthy(live, 'one running contract')
            local counts, restore = countingStore(s.storage)
            local ok, err = pcall(function()
                main.recover()
                s.amendments.reindex()
            end)
            restore()
            if not ok then error(err, 0) end
            out = { escrow = counts.readEscrow, amendments = counts.readOpenAmendments,
                    contract = counts.readContract }
        end)
        return out
    end

    it('reads nothing more for a finished contract whose escrow is all settled', function()
        local few, many = startCost(2), startCost(30)
        eq(many.escrow, few.escrow,
            ('recovery read escrow %d times with 30 finished contracts and %d with 2')
            :format(many.escrow, few.escrow))
        eq(many.contract, few.contract, 'nor re-read their rows')
        eq(many.amendments, 0, 'the amendment index is one read, not one per contract')
    end)
end)

describe('complexity: the audit flush on mysql', function()
    local Exec = require('crimson-hitman.tests.harness.mysql_exec')

    local function mysqlAudit()
        newStack()
        Exec.install(Natives)
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local store = require('crimson-hitman.server.storage.mysql')
        store.open()
        package.loaded['crimson-hitman.server.audit'] = nil
        local audit = require('crimson-hitman.server.audit')
        audit.init(store)
        return audit, store
    end

    local function inserts()
        local n = 0
        for _, sql in ipairs(Exec.statements) do
            if sql:find('^INSERT INTO crimson_audit') then n = n + 1 end
        end
        return n
    end

    local function rows()
        local n, seen = 0, {}
        for _, row in pairs(Exec.tables.crimson_audit or {}) do
            n = n + 1
            seen[row.action] = (seen[row.action] or 0) + 1
        end
        return n, seen
    end

    --- One awaited INSERT a row, and the flush is the first job of the tick:
    --- every job behind it waited on the database a row at a time.
    it('writes a flush in a few statements, not one a row', function()
        local audit = mysqlAudit()
        for i = 1, 450 do audit.financial('row_' .. i, 'CREATOR1', 'ct1', { n = i }) end
        Exec.statements = {}
        eq(audit.flush(), 450)
        eq(inserts(), 3, 'two hundred rows a statement')
        local n, seen = rows()
        eq(n, 450, 'every row written')
        eq(seen.row_1, 1)
        eq(seen.row_450, 1)
    end)

    --- One statement is all or nothing, so a batch the database refuses has
    --- written none of itself: its rows go one by one, and only the one
    --- that will not write is lost.
    it('writes a refused batch row by row, once each', function()
        local audit, store = mysqlAudit()
        for i = 1, 10 do audit.financial('row_' .. i, 'CREATOR1', 'ct1', { n = i }) end
        local realBatch, realOne = store.writeAuditBatch, store.writeAudit
        store.writeAuditBatch = function() error('Data too long for column') end
        store.writeAudit = function(entry)
            if entry.action == 'row_4' then error('Data too long for column') end
            return realOne(entry)
        end
        local written = audit.flush()
        store.writeAuditBatch, store.writeAudit = realBatch, realOne
        eq(written, 9)
        local n, seen = rows()
        local actions = {}
        for action, count in pairs(seen) do
            if action:find('^row_') then actions[#actions + 1] = action .. '=' .. count end
        end
        table.sort(actions)
        eq(#actions, 9, 'nine rows: ' .. table.concat(actions, ' '))
        for _, entry in ipairs(actions) do truthy(entry:find('=1$'), 'once each: ' .. entry) end
        eq(seen.row_4, nil, 'the one it would not take')
        eq(seen.audit_overflow, 1, 'and that one counted as dropped')
        truthy(n == 10)
    end)
end)
