--- Final verification: the two gaps the independent check reproduced.
local rpIt = require('tests.harness.roleplay').it

local function rpSetup()
    local s = newStack()
    local f = fixture(s)
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 } },
    })
    truthy(c, 'placed')
    truthy(s.contracts.accept(f.hitman, c.id, true), 'taken')
    Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
    Env.runTimers()
    return s, f, c
end

local function heldLine(s, c)
    for _, line in ipairs(s.storage.readEscrow(c.id)) do
        if line.owed_to == 'HITMAN01' and line.state == CH.ESCROW_STATE.HELD then return line end
    end
    return nil
end

describe('final verify: the intent hold fails closed when the store cannot be read', function()
    rpIt('keeps the payout held while the store cannot be read', function()
        local s, f, c = rpSetup()
        Config.Roleplay.ProofOfIntent.Enabled = true
        Config.Roleplay.ProofOfIntent.MinMessages = 3
        Config.Roleplay.ProofOfIntent.HoldMaxMinutes = 60
        local ok, err, result = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        truthy(ok, tostring(err))
        truthy(result.intentHold, 'held')
        eq(#s.storage.readRpRows('intent'), 1, 'row written')
        local line = heldLine(s, c)
        truthy(line, 'line owed')
        truthy(s.rpIntent.holds('HITMAN01', line), 'held before restart')
        -- restart the module; the store fails its first read
        s.rpIntent.init({ storage = s.storage, audit = s.audit, notify = s.notify, escrow = s.escrow,
                          contracts = s.contracts, projection = s.projection })
        local read = s.storage.readRpRows
        s.storage.readRpRows = function(kind)
            if kind == 'intent' then error('store down') end
            return read(kind)
        end
        local cashBefore = Env.players[3].PlayerData.money.cash
        s.escrow.retryPending('HITMAN01')
        local cashAfter = Env.players[3].PlayerData.money.cash
        eq(cashAfter, cashBefore, 'nothing paid while the store cannot be read')
        local during = s.rpIntent.holds('HITMAN01', line)
        s.storage.readRpRows = read
        truthy(during, 'a failed load keeps the payout held')
    end)
end)

local function call(name, src, payload)
    local fire = Env.events['crimson-hitman:' .. name]
    if not fire then return { ok = false, err = 'NO SUCH HANDLER' } end
    Env.clientEvents = {}
    _G.source = src
    local fired, err = pcall(fire, payload or {})
    _G.source = nil
    if not fired then return { ok = false, err = 'THREW: ' .. tostring(err) } end
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:result' then return event.args[1] end
    end
    return nil
end

describe('final verify: the broker list leaves out invisible and masked players', function()
    rpIt('does not list an invisible player (noclip / spectating staff) beside the broker', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt from last week',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 40000 } } })
        truthy(c)
        local function turn(k, v) local ok, e, w = s.settings.set(k, v, 'ADMIN001', 'ADMIN001'); truthy(ok, tostring(e)..tostring(w)) end
        turn('Intel.Rumours.Enabled', true)
        turn('Intel.Rumours.BrokerJobs', { 'broker' })
        Env.addPlayer({ source = 4, citizenid = 'BROKER01', license = 'license:ddd',
            firstname = 'Bo', lastname = 'Ker', job = { name = 'broker', type = 'none' } })
        local AT = { x = 500.0, y = 500.0, z = 30.0 }
        Env.players[4]._coords = AT
        Env.players[1]._coords = { x = 9000, y = 9000, z = 0 }
        Env.players[2]._coords = { x = 9100, y = 9000, z = 0 }
        Env.players[3]._coords = { x = AT.x + 2, y = AT.y, z = AT.z }
        Env.players[3]._invisible = true
        local near = call('brokerNearby', 4, {})
        truthy(near and near.ok, tostring(near and near.err))
        eq(#near.data.people, 0, 'an invisible player is not listed')
        Env.players[3]._invisible = nil
        near = call('brokerNearby', 4, {})
        eq(#near.data.people, 1, 'listed once visible')
        local allow = Config.Targeting.AllowNearby
        Config.Targeting.AllowNearby = true
        local maskEvent = Env.events['crimson-hitman:maskState']
        truthy(maskEvent, 'the mask event exists')
        _G.source = 3; pcall(maskEvent, true); _G.source = nil
        near = call('brokerNearby', 4, {})
        Config.Targeting.AllowNearby = allow
        eq(#near.data.people, 0, 'a masked player is not listed')
    end)
end)
