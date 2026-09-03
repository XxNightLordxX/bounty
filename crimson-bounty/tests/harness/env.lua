--- Headless test harness.
--- Stubs the FiveM runtime and the three external resources this script talks
--- to, so the real server modules can be loaded and exercised in plain Lua.
--- Nothing in here ships to the server.

local Env = {}

Env.time = 1700000000
Env.gameTimer = 0
Env.players = {}          -- [source] = player record
Env.byCitizen = {}        -- [citizenid] = source
Env.events = {}           -- registered net events
Env.handlers = {}         -- registered local event handlers, by name
Env.clientEvents = {}     -- captured TriggerClientEvent calls
Env.notifications = {}
Env.threads = {}
Env.timers = {}
Env.console = {}

--------------------------------------------------------------------------
-- Player fixtures
--------------------------------------------------------------------------

--- Create a player. Everything the modules read lives under PlayerData, in
--- the same shape qbx_core exposes.
function Env.addPlayer(opts)
    local src = opts.source
    local player = {
        PlayerData = {
            source = src,
            citizenid = opts.citizenid,
            license = opts.license or ('license:' .. opts.citizenid),
            charinfo = { firstname = opts.firstname or 'Test', lastname = opts.lastname or ('P' .. src) },
            job = opts.job or { name = 'unemployed', type = 'none', onduty = false },
            money = { cash = opts.cash or 0, bank = opts.bank or 0 },
            metadata = opts.metadata or {
                isdead = false, inlaststand = false, ishandcuffed = false,
                -- QBox stores playtime in minutes.
                playtime = (opts.playtimeHours or 100) * 60,
            },
        },
        _inventory = opts.inventory or {},
        _coords = opts.coords or { x = 0.0, y = 0.0, z = 0.0 },
        _health = opts.health or 200,
        -- Playtime lives where the real framework keeps it, so a test can
        -- never pass on a field production does not have.
        _playtimeHours = opts.playtimeHours,
    }

    player.Functions = {
        SetMetaData = function(key, value) player.PlayerData.metadata[key] = value end,
        AddMoney = function(account, amount)
            player.PlayerData.money[account] = (player.PlayerData.money[account] or 0) + amount
            return true
        end,
        RemoveMoney = function(account, amount)
            local have = player.PlayerData.money[account] or 0
            if have < amount then return false end
            player.PlayerData.money[account] = have - amount
            return true
        end,
        GetMoney = function(account) return player.PlayerData.money[account] or 0 end,
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

function Env.reset()
    Env.time = 1700000000
    Env.gameTimer = 0
    Env.players, Env.byCitizen = {}, {}
    Env.events, Env.clientEvents, Env.notifications = {}, {}, {}
    Env.handlers = {}
    Env.threads, Env.timers, Env.console = {}, {}, {}
end

--------------------------------------------------------------------------
-- Clock control
--------------------------------------------------------------------------

function Env.advance(seconds)
    Env.time = Env.time + seconds
    Env.gameTimer = Env.gameTimer + (seconds * 1000)
    Env.runTimers()
end

function Env.runTimers()
    local due = {}
    for i = #Env.timers, 1, -1 do
        local t = Env.timers[i]
        if t.at <= Env.gameTimer then
            table.insert(due, t)
            table.remove(Env.timers, i)
        end
    end
    for i = 1, #due do due[i].fn() end
end

return Env
