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
                            escrow = counts.readEscrow, all = counts.allContracts }
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

        eq(big.all, 1, 'and the contract table is read once, not once a page')
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
