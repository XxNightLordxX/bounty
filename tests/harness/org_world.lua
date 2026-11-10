--- A stack with the hitman organisation on, for the org_*_spec suites:
--- qbx_core's job exports and Renewed-Banking's (tests/harness/qbx_jobs.lua),
--- staff at 6 (the staff ACE) and 7 (an extra ACE, read only), and three
--- members-to-be: 11 (the boss), 12 and 13, plus the fixture's 1, 2 and 3.

local QbxJobs = require('tests.harness.qbx_jobs')

local W = { QbxJobs = QbxJobs }

W.STAFF = { staff = true, cid = 'ADMIN001' }

function W.player(src, cid, extra)
    local opts = { source = src, citizenid = cid, license = 'license:' .. cid, cash = 50000, bank = 50000,
        firstname = 'P' .. src, lastname = 'Org' }
    for k, v in pairs(extra or {}) do opts[k] = v end
    Env.addPlayer(opts)
    Env.characters = Env.characters or {}
    Env.characters[cid] = true
end

--- The stack. `opts.bank` starts Renewed-Banking; `opts.off` leaves the
--- organisation off; `opts.configure` runs before the boot.
function W.world(opts)
    opts = opts or {}
    local s = newStack()
    local f = fixture(s)
    QbxJobs.install()
    Natives.convars['qbx:max_jobs_per_player'] = '3'
    W.player(6, 'ADMIN001')
    W.player(7, 'READER01')
    W.player(11, 'BOSS0001')
    W.player(12, 'LIEUT001')
    W.player(13, 'RECRUIT1')
    Env.aces[6] = { ['crimson.admin'] = true }
    Env.aces[7] = { command = true }
    Config.Cooldowns.admin = { per = 10, burst = 1000 }
    Config.Cooldowns.adminWrite = { per = 10, burst = 1000 }
    Config.Cooldowns.org = { per = 10, burst = 1000 }
    Config.Cooldowns.orgWrite = { per = 10, burst = 1000 }
    if opts.bank then Natives.resourceStates['Renewed-Banking'] = 'started' end
    if not opts.off then Config.Organisation.Enabled = true end
    if opts.configure then opts.configure(s, f) end
    s.bridges.install(s)
    s.org.boot()
    return s, f
end

--- Hire the three: the boss at 3, the lieutenant at 2, the recruit at 0,
--- by staff (who may do anything).
function W.crew(s)
    local function hire(src, cid, grade)
        local ok, err = s.org.hire(W.STAFF, { cid = cid, name = 'P' .. src, source = src }, grade)
        assert(ok, 'hire ' .. cid .. ': ' .. tostring(err))
    end
    hire(11, 'BOSS0001', 3)
    hire(12, 'LIEUT001', 2)
    hire(13, 'RECRUIT1', 0)
end

--- A boss actor for the org functions.
function W.boss(src, cid)
    return { cid = cid or 'BOSS0001', source = src or 11, name = 'P' .. tostring(src or 11) }
end

--- Allow a power for a role (Boss permissions).
function W.allow(s, grade, code)
    local ok, err = s.org.setCeiling(W.STAFF, 'role', grade, code, 'allow')
    assert(ok, 'allow ' .. code .. ': ' .. tostring(err))
end

--- Ask the panel as staff: the reply.
function W.ask(src, op, data)
    Env.clientEvents = {}
    _G.source = src
    local fired, err = pcall(Env.events['crimson-hitman:admin'], { op = op, data = data or {}, __rid = 7 })
    _G.source = nil
    assert(fired, 'the panel event raised: ' .. tostring(err))
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:adminResult' then return event.args[1] end
    end
    return nil
end

--- Call an app request as a player: the reply.
function W.call(name, src, payload)
    local fire = Env.events['crimson-hitman:' .. name]
    assert(fire, 'no handler for ' .. name)
    Env.clientEvents = {}
    _G.source = src
    local ok, err = pcall(fire, payload)
    _G.source = nil
    assert(ok, name .. ' raised: ' .. tostring(err))
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:result' then return event.args[1] end
    end
    return nil
end

--- Stand a player somewhere.
function W.at(src, x, y, z)
    Env.players[src]._coords = { x = x, y = y, z = z or 30.0 }
end

--- Put the boss office where `src` stands, as staff with Use my position.
function W.office(s, x, y)
    W.at(6, x or 100.0, y or 100.0, 30.0)
    local ok, err = s.org.placeSpot({ staff = true, cid = 'ADMIN001', source = 6 }, { kind = 'office', here = true })
    assert(ok, 'office: ' .. tostring(err))
end

--- Place a contract (competitive, $5000 cash).
function W.place(s, actor, target, extra)
    local req = { targetCid = target or 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 } } }
    for k, v in pairs(extra or {}) do req[k] = v end
    return s.contracts.create(actor, req)
end

function W.wealth(src)
    local m = Env.players[src].PlayerData.money
    return m.cash + m.bank
end

return W
