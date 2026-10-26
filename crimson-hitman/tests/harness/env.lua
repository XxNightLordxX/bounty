--- Headless test harness.
--- Stubs the FiveM runtime and the three external resources this script talks
--- to, so the real server modules can be loaded and exercised in plain Lua.
--- Nothing in here ships to the server.

local Env = {}

Env.time = 1700000000
Env.gameTimer = 0

--- The accounts qbx_core actually has.
---
--- The harness used to create whatever account it was handed: AddMoney
--- ('dirty', n) invented a `money.dirty` field and returned true. Dirty
--- money is not an account at all — it is an ox_inventory item — so the
--- single most likely money bug in this resource, paying or charging it
--- through the money API, moved nothing on a live server and passed here
--- without a murmur.
---
--- A harness that provides what production does not is not testing this
--- program. An unknown account is refused, exactly as qbx_core refuses it.
Env.MONEY_ACCOUNTS = { cash = true, bank = true, crypto = true }

--- Accounts qbx_core will not take below zero, from its shipped
--- config.money.dontAllowMinus. Bank is not among them.
Env.NO_OVERDRAFT = { cash = true, crypto = true }
Env.players = {}          -- [source] = player record
Env.byCitizen = {}        -- [citizenid] = source
Env.events = {}           -- registered net events
Env.handlers = {}         -- registered local event handlers, by name
Env.clientEvents = {}     -- captured TriggerClientEvent calls
Env.commands = {}         -- [name] = handler, as RegisterCommand saw it
Env.chat = {}             -- lines a command printed back to a player
Env.aces = {}             -- [source] = { ['crimson.admin'] = true }
Env.consoleOut = {}       -- lines a command printed to the console
Env.notifications = {}
Env.threads = {}
Env.timers = {}
Env.clearedTimers = {}    -- [timer id] = true, as ClearTimeout left it
Env.console = {}
--- Coroutines waiting in Citizen.Await, in the order they parked:
--- { co, promise }. Resumed by Env.runTimers once the promise settles.
Env.parked = {}
--- What a parked coroutine yields, so a driver resuming coroutines of its
--- own (tests/harness/await_scheduler.lua) can tell one waiting on the
--- database from one that yielded for any other reason.
Env.PARKED = setmetatable({}, { __tostring = function() return 'parked on an await' end })

--------------------------------------------------------------------------
-- Player fixtures
--------------------------------------------------------------------------

--- Create a player. Everything the modules read lives under PlayerData, in
--- the same shape qbx_core exposes.
--- Every stack a real inventory holds sits in a numbered slot, and
--- ox_inventory's Search returns that number. A fixture written without one
--- would let the escrow code take a path production never takes — and the
--- guard against staging one stack for two payouts is keyed on exactly that
--- number.
---
--- A test that means to model an inventory build which does NOT number its
--- slots writes `slot = false`, which is left unnumbered. Saying so out loud
--- is the point: a missing slot should be a claim about the world, not an
--- omission.
local function numberSlots(inventory)
    local used = {}
    for i = 1, #inventory do
        if inventory[i].slot then used[inventory[i].slot] = true end
    end
    local next_ = 1
    for i = 1, #inventory do
        if inventory[i].slot == false then
            inventory[i].slot = nil
        elseif not inventory[i].slot then
            while used[next_] do next_ = next_ + 1 end
            inventory[i].slot = next_
            used[next_] = true
        end
    end
    return inventory
end

function Env.addPlayer(opts)
    local src = opts.source
    local player = {
        PlayerData = {
            source = src,
            citizenid = opts.citizenid,
            license = opts.license or ('license:' .. opts.citizenid),
            charinfo = { firstname = opts.firstname or 'Test', lastname = opts.lastname or ('P' .. src) },
            job = opts.job or { name = 'unemployed', type = 'none', onduty = false },
            -- Every job held, as qbx_core keeps them: { [name] = grade }.
            jobs = opts.jobs,
            money = { cash = opts.cash or 0, bank = opts.bank or 0 },
            metadata = opts.metadata or {
                isdead = false, inlaststand = false, ishandcuffed = false,
                -- QBox stores playtime in minutes.
                playtime = (opts.playtimeHours or 100) * 60,
            },
        },
        _inventory = numberSlots(opts.inventory or {}),
        _coords = opts.coords or { x = 0.0, y = 0.0, z = 0.0 },
        _health = opts.health or 200,
        -- Playtime lives where the real framework keeps it, so a test can
        -- never pass on a field production does not have.
        _playtimeHours = opts.playtimeHours,
    }

    player.Functions = {
        SetMetaData = function(key, value) player.PlayerData.metadata[key] = value end,
        AddMoney = function(account, amount, reason)
            player._moneyReasons = player._moneyReasons or {}
            player._moneyReasons[#player._moneyReasons + 1] = reason
            -- qbx_core's AddMoney returns a boolean: false for an account it
            -- does not know or an amount it will not take, and servers
            -- commonly patch a balance ceiling into it. A harness that
            -- always succeeded made the one branch that ignores the answer
            -- untestable.
            if player._refuseMoney then return false end
            if not Env.MONEY_ACCOUNTS[account] then return false end
            player.PlayerData.money[account] = (player.PlayerData.money[account] or 0) + amount
            return true
        end,
        --- qbx_core refuses an overdraft only on the accounts its config
        --- lists in dontAllowMinus, which ships as cash and crypto. Bank is
        --- deliberately allowed to go negative — the overdraft behaviour
        --- qbx_core inherited from QBCore — so RemoveMoney('bank', n)
        --- returns true on an empty account and leaves a negative balance.
        ---
        --- A harness that refused every short removal made that return
        --- value an affordability check, which it is not, and any call site
        --- treating it as one passed here and gave the thing away on a
        --- live server.
        RemoveMoney = function(account, amount, reason)
            player._moneyReasons = player._moneyReasons or {}
            player._moneyReasons[#player._moneyReasons + 1] = reason
            if not Env.MONEY_ACCOUNTS[account] then return false end
            local have = player.PlayerData.money[account] or 0
            if Env.NO_OVERDRAFT[account] and have < amount then return false end
            player.PlayerData.money[account] = have - amount
            return true
        end,
        GetMoney = function(account)
            if not Env.MONEY_ACCOUNTS[account] then return 0 end
            return player.PlayerData.money[account] or 0
        end,
    }

    Env.players[src] = player
    Env.byCitizen[opts.citizenid] = src
    return player
end

function Env.removePlayer(src)
    local p = Env.players[src]
    if p then Env.byCitizen[p.PlayerData.citizenid] = nil end
    Env.players[src] = nil
end

--- Every player's client saying whether they wear a mask, as each one does
--- once its character is loaded and the nearby list is on (client/main.lua):
--- what their own game shows, `_masked` on the fixture. The server cannot
--- see clothes, so a player whose client has said nothing is left off the
--- nearby list; `_silent` on the fixture is a client that has not said.
function Env.reportMasks()
    local report = Env.events['crimson-hitman:maskState']
    assert(report, 'no handler for crimson-hitman:maskState')
    local srcs = {}
    for src in pairs(Env.players) do srcs[#srcs + 1] = src end
    table.sort(srcs)
    for _, src in ipairs(srcs) do
        local p = Env.players[src]
        if not p._silent then
            local was = _G.source
            _G.source = src
            report(p._masked == true)
            _G.source = was
        end
    end
end

function Env.reset()
    Env.time = 1700000000
    Env.gameTimer = 0
    Env.players, Env.byCitizen = {}, {}
    Env.events, Env.clientEvents, Env.notifications = {}, {}, {}
    Env.commands, Env.chat, Env.aces, Env.consoleOut = {}, {}, {}, {}
    Env.handlers = {}
    Env.threads, Env.timers, Env.console = {}, {}, {}
    Env.clearedTimers, Env.parked = {}, {}
    Env.eventCanceled = nil
    -- qbx_core's job list, which GetJob answers from. Only the jobs a test
    -- names; a job missing here reads as one the framework does not know.
    Env.jobDefinitions = {
        police = { label = 'Police', type = 'leo' },
        bcso = { label = 'BCSO', type = 'leo' },
        ambulance = { label = 'EMS', type = 'ems' },
        mechanic = { label = 'Mechanic', type = 'mechanic' },
        unemployed = { label = 'Civilian', type = 'none' },
    }
end

--------------------------------------------------------------------------
-- Clock control
--------------------------------------------------------------------------

--- Move both clocks on, firing each timer at its own moment on the way: a
--- timer that sets another sees the clock as it was when it fired, and the
--- one it sets fires in this advance too if it falls due inside it. Jumping
--- to the end first ran a chain of timers one link at a time.
function Env.advance(seconds)
    Env.time = Env.time + seconds
    local target = Env.gameTimer + (seconds * 1000)
    while true do
        local soonest
        for i = 1, #Env.timers do
            local t = Env.timers[i]
            if t.at <= target and (not soonest or t.at < soonest.at
                or (t.at == soonest.at and (t.seq or 0) < (soonest.seq or 0))) then
                soonest = t
            end
        end
        if not soonest then break end
        if soonest.at > Env.gameTimer then Env.gameTimer = soonest.at end
        Env.runTimers()
    end
    Env.gameTimer = target
    Env.runTimers()
end

--- Run every timer that is due, in the order the engine would: soonest
--- first, and in the order they were set among those due together. They
--- used to run last-set first, so a check scheduled after another ran
--- before it — which no server does.
function Env.runTimers()
    local due, keep = {}, {}
    for i = 1, #Env.timers do
        local t = Env.timers[i]
        if t.at <= Env.gameTimer then due[#due + 1] = t else keep[#keep + 1] = t end
    end
    Env.timers = keep
    table.sort(due, function(a, b)
        if a.at ~= b.at then return a.at < b.at end
        return (a.seq or 0) < (b.seq or 0)
    end)
    Env.resumeParked()
    for i = 1, #due do
        if not Env.clearedTimers[due[i].seq] then due[i].fn() end
    end
    Env.resumeParked()
end

--------------------------------------------------------------------------
-- Threads
--------------------------------------------------------------------------

--- Run fn in a coroutine of its own, as the engine runs a net event or a
--- thread, up to its first yield; an await nothing answers parks it there
--- (Env.parked) and the caller carries on. Answers a handle: `done` once
--- fn has returned, `results` what it returned (packed). An error inside
--- is raised from whoever resumed it, here or Env.runTimers, so a test
--- sees it.
---@return table handle { co, done, results }
function Env.spawn(fn, ...)
    local args = table.pack(...)
    local handle = { done = false }
    handle.co = coroutine.create(function()
        handle.results = table.pack(fn(table.unpack(args, 1, args.n)))
        handle.done = true
    end)
    local ok, err = coroutine.resume(handle.co)
    if not ok then error(err, 0) end
    return handle
end

--- Resume every parked coroutine whose promise has settled, in the order
--- they parked. One that parks again goes to the back.
function Env.resumeParked()
    local i = 1
    while i <= #Env.parked do
        local entry = Env.parked[i]
        if entry.promise.state ~= 0 then
            table.remove(Env.parked, i)
            if coroutine.status(entry.co) == 'suspended' then
                local ok, err = coroutine.resume(entry.co)
                if not ok then error(err, 0) end
            end
        else
            i = i + 1
        end
    end
end

return Env
